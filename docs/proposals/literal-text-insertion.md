---
title: "Proposal: format-correct literal text insertion"
status: implemented
author: adammharris
created: 2026-07-19
---

# Format-correct literal text insertion

## Summary

Twig can wrap, toggle, and convert markup, but it has **no way to insert a run of
literal text and guarantee it stays literal**. When an editor built on twig wants
a typed `*`, `#`, or `` ` `` to be *the character*, not the start of markup, it
has to escape that text itself — reinventing, per frontend, the per-format escape
rules twig already owns everywhere else.

Leaf needs exactly this for its **Hidden reveal mode** (the WYSIWYG surface for
users who don't write Markdown — the Diaryx audience). In that mode, formatting
comes only from commands (⌘B/⌘I/toolbar); a typed `*` must render and round-trip
as a `*`, never silently become emphasis. The only round-trip-safe way to hold
that guarantee is a real escape in the source (`\*`), spelled the way *this
format* spells a literal — which is a twig decision, not a leaf one.

Twig is one field and one op away from providing it. It already carries a
positional escape alphabet for link text (`Syntax.link_text_escapes`,
`src/syntax.zig:128`) and link destinations (`link_dest_escapes`); this proposal
adds the sibling alphabet for **ordinary text position** and the editor op that
uses it.

## The concrete gap

Twig's inline-text serializer writes text **verbatim** — no escaping at all
(`src/languages/markdown/serializer.zig:78`):

```zig
fn writeInlineText(self: *Renderer, s: []const u8, ctx: Ctx) Writer.Error!void {
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        try self.writer.writeAll(rest[0 .. nl + 1]);   // ← writes '*', '#', '`' raw
        rest = rest[nl + 1 ..];
        if (rest.len > 0) try self.writePrefix(ctx);
    }
    try self.writer.writeAll(rest);
}
```

This is correct for serializing a *parsed* AST: a `str` node holding `*` came from
a `*` that already failed to open emphasis in that position, so re-emitting it raw
is stable. But there is no operation an editor can call to go the other way —
take an arbitrary user-typed string and splice it so it *stays* that string. The
escaping machinery that exists is positional and scoped to links:

```
$ grep link_text_escapes src/languages/*/syntax.zig
markdown:  .link_text_escapes = "\\[]*_^`~<>&",
djot:      .link_text_escapes = "\\[]*_^`~\"'-.:{}",
```

`Editor.insertLink` uses that alphabet (`src/ast/editor.zig:485`) to guard the
link-text position. Nothing does the equivalent for the **body text** position,
so leaf has no format-correct way to insert a literal `*`.

## Goals

- One editor op inserts a run of text that round-trips as **that exact text**,
  escaped the way the current format spells a literal — Markdown `\*`, Djot's
  alphabet, and `error.UnsupportedFormat` for a parse-only format (HTML/XML).
- The escape decision is **positional**: a `#`/`-`/`>` only needs escaping at a
  line start (where it opens a block); `*`/`_`/`` ` ``/`[` matter anywhere inline.
- Conformance is untouched — this is an additive spelling table + op, no parser
  change.
- Leaf routes Hidden-mode typed input through it and deletes any interim
  Markdown-only escaping it does in the meantime.

## Non-goals

- Changing how a *parsed* `str` serializes. `writeInlineText` stays verbatim for
  round-tripping existing content; the new escaping is for text entering the doc
  through the op, not text already in the AST.
- Deciding leaf's *policy* (when to escape). That an editor escapes typed syntax
  in one mode and passes it through in another is leaf's call; twig only provides
  the format-correct *mechanism*. See "Layering" below.
- Auto-unescaping on the way out for display — the rendered view dropping a `\`
  is a leaf rendering concern (its VisualMap already hides delimiters).

## Design

Three additive changes, each at the layer that owns the decision.

### 1. Spelling — a `text_escapes` alphabet in `Syntax`

Symmetric with the link alphabets already there (`src/syntax.zig:128`):

```zig
pub const Syntax = struct {
    // …existing fields…

    /// The bytes that must be backslash-escaped for a literal run to reparse as
    /// itself in ordinary *body text* position — the alphabet `insertLiteral`
    /// guards. Distinct from `link_text_escapes` (which also escapes `<`/`&`/`>`
    /// that only matter next to a link) and narrower than it: this is the set a
    /// paragraph's text can't hold uninterpreted. `null` = a parse-only format,
    /// so `insertLiteral` is `error.UnsupportedFormat`.
    text_escapes: ?[]const u8 = null,

    /// The subset of `text_escapes` that only opens a construct at a LINE START
    /// (block markers: `#`, `-`, `+`, `*` as a bullet, `>`, `=`…). Escaped only
    /// when the insertion point is at column zero of its line; mid-line they are
    /// ordinary text and left alone, so a sentence's "5 * 3" keeps its `*`.
    block_start_escapes: ?[]const u8 = null,
};
```

Per-format literals (`src/languages/{markdown,djot}/syntax.zig`):

| Format   | `text_escapes` | `block_start_escapes` | Rationale |
|----------|----------------|-----------------------|-----------|
| Markdown | `` "\\*_`[]~" `` | `"#->+"` (+ `=` for setext) | CommonMark inline + block openers. |
| Djot     | open question — its `link_text_escapes` is `` "\\[]*_^`~\"'-.:{}" `` | open question | Djot's inline alphabet is wider; needs its own audit. |
| HTML/XML | `null`         | `null`                | Parse-only; already unauthorable. |

(The exact Markdown alphabet wants the same care `link_text_escapes` got — this
table is the shape, not the final byte set; see open questions.)

### 2. The op — `insertLiteral`

```zig
/// Insert `text` at `offset` as a literal run: every byte in `Syntax.text_escapes`
/// is backslash-escaped so the run reparses as exactly `text`, and a
/// `block_start_escapes` byte is escaped only when `offset` sits at the start of
/// its line. `error.UnsupportedFormat` when the format can't spell a literal
/// (`text_escapes == null`), `error.InvalidRange` when `offset` is out of range.
///
/// Reuses the same splice+reparse+rollback path as every other gesture, so an
/// insertion that would corrupt the doc yields `error.EditConflict` and changes
/// nothing.
pub fn insertLiteral(self: *Editor, offset: usize, text: []const u8) Error!void
```

It resolves the line-start position for `offset` once (twig already has
`locate.lineStartAt`, used by the list/table ops), walks `text` escaping per the
two alphabets, and splices. Position-awareness only matters for the *first* line
of `text`; an embedded newline resets "at line start" for the bytes after it.

### 3. Binding

```rust
// bindings/rust/twig
pub fn insert_literal(&mut self, offset: usize, text: &str) -> Result<(), Error>
```

Mirrors `insert_link`'s shape; leaf calls it from `Doc` the way it calls
`edit_range` today.

## Layering — why twig owns the mechanism, leaf owns the policy

The split mirrors the in-cell-break proposal:

- **twig owns "how a literal is spelled in format X."** It's format-specific
  (Markdown `\*`, Djot's set, HTML nothing) and parse-context-sensitive (a `#` is
  only special at a line start). Both facts already live in twig — the `Syntax`
  table and the parser — and nowhere else. A frontend that escaped by hand would
  hardcode one format's rules and drift the moment the doc is Djot.

- **leaf owns "when to escape."** Its Hidden mode routes typed specials through
  `insertLiteral`; its CaretLine mode passes them through `edit_range` as live
  syntax. That toggle is a product decision about a reveal mode, which twig has no
  business knowing. Same shape as leaf owning `break_glyph` while twig owns the
  `hard_break`.

## What leaf does with it

- Hidden mode's text-input path calls `editor.insert_literal(caret, typed)`
  instead of `edit_range(caret, caret, typed)`, so a typed `*`/`#`/`` ` `` lands
  as `\*`/`\#`/`` \` `` and can never mint markup by keyboard. Commands
  (`toggle_inline`, `set_block`) still emit *real* markup — that's the sanctioned
  way to format in Hidden mode.
- CaretLine mode is unchanged: typed syntax stays live (that's its whole point),
  handled by the optimistic-render layer, which is pure leaf.
- Loaded/pasted markup is untouched by any of this — it's already-parsed content,
  rendered per the AST. The escaping only governs *new* text typed in Hidden mode.

Until this lands, leaf can ship a **Markdown-only** interim escaper in `Doc`
(hardcoding `\*_#…`) so Hidden mode works for the default format, then delete it
and call `insert_literal` once the op exists — the same "leaf hack now, twig op
later" path the in-cell-break proposal takes.

## API surface (additions only)

```zig
// src/syntax.zig
Syntax.text_escapes: ?[]const u8 = null
Syntax.block_start_escapes: ?[]const u8 = null

// src/ast/editor.zig
pub fn insertLiteral(self: *Editor, offset: usize, text: []const u8) Error!void

// bindings/rust/twig
pub fn insert_literal(&mut self, offset: usize, text: &str) -> Result<(), Error>
```

No breaking changes: two defaulted `Syntax` fields, one additive op, no parser or
`FlatNode` change. `assertCoherent` (`src/syntax.zig:163`) could optionally gain
`(text_escapes == null) == (block_start_escapes == null)` to keep the pair
consistent, matching the existing `link_text`/`link_dest` invariant.

## Open questions

1. **The exact Markdown alphabet.** Minimal-but-safe: which bytes genuinely need
   escaping in body position vs. which are harmless (intraword `_`, a lone `~`)?
   Over-escaping is *safe* (valid, just noisier source) — is `foo\_bar` acceptable
   for a mode whose users never see the source, or worth the context-sensitivity
   to avoid?
2. **Context-sensitivity depth.** `block_start_escapes` handles the line-start
   case. Is that enough, or do we want finer rules (a `.`/`)` only matters after
   a digit run for ordered lists; a `-` only as a bullet with a trailing space)?
   The fixed-alphabet approach `link_text_escapes` takes suggests "keep it simple,
   over-escape a little" — worth confirming for body text.
3. **Djot and its wider alphabet** — needs the same audit `link_text_escapes` got.
4. **Round-trip corpus.** For each format, `canonical(insertLiteral(s))` must
   reparse to a single `str` equal to `s` for a fuzz set of s full of specials —
   add to the conformance harness.
