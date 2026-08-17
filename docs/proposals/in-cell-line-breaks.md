---
title: "Proposal: hard line breaks inside table cells"
status: implemented
author: adammharris
created: 2026-07-19
---

# Hard line breaks inside table cells

## Update (2026-07-20): decisions & scope

The open questions below are resolved for the first landing. Scope: **Markdown
and HTML supported, djot deliberately not.**

- **Djot → `cell_line_break = null` (open question 1: option A, *not* the draft's
  recommended B).** Option B (`<br>` for djot too) buys shallow uniformity at a
  real fidelity cost: a bare `<br>` isn't idiomatic djot, and the moment the
  document leaves twig it renders as the literal text `<br>` in any other djot
  implementation — a silent data-loss bug, strictly worse than an honest "this
  format can't spell it." Option A is also the reversible choice: if djot ever
  standardizes an in-cell break we fill in the real spelling with zero migration,
  whereas B leaves twig-only documents in the wild that can't be walked back. So
  `insertLineBreak` in a djot cell is `error.UnsupportedFormat`, and the frontend
  degrades (disable / space-substitute), exactly as it already must for other
  ragged gestures. A house-dialect escape hatch (option C) stays available later
  as an *explicit* `options.dialect` opt-in — never the silent default.

- **HTML is supported and needed no new machinery.** The HTML parser already
  maps `<br>` → `hard_break` (`html/parser.zig:247`) and the HTML serializer
  already emits `<br>` for `hard_break` (`html/serializer.zig:909`); an HTML cell
  break already round-trips HTML → AST → HTML unchanged (the trailing newline the
  serializer adds is insignificant HTML whitespace). HTML carries no `Syntax`
  table (it is parse-only / unauthorable), so the editor op correctly reports
  `error.UnsupportedFormat` for it — authoring is not the point, round-trip is.

  Scope caveat, verified on the CLI: twig's HTML parser lowers `<table>`/`<tr>`/
  `<td>` to **generic `element` nodes**, not the semantic `table`/`row`/`cell`
  nodes the Markdown pipe-table path keys on. So HTML → Markdown does *not*
  reconstruct a pipe table (the table passes through as raw HTML, and its
  `hard_break` serializes via the ordinary arm) — that is a separate, pre-existing
  limitation this proposal does not address. "HTML supported" here means the
  HTML → AST → HTML round-trip of a cell break, not HTML → Markdown table
  reconstruction. The Markdown serializer's `in_cell` branch only fires for a
  `hard_break` that is a child of a real `cell` node.

- **Round-trip goal is *canonicalizing*, not byte-preserving (open question 3).**
  The narrow cell promotion accepts `<br>`, `<br/>`, and `<br />` and the
  serializer emits the single spelling `<br>`, so the self-closing forms
  normalize to `<br>`. The conformance assertion is "`canonical` output is
  byte-stable and idempotent," not "input survives unchanged."

- **The editor op is scoped to the in-cell gesture (open question 2).** `<br>`
  → `hard_break` promotion fires **only** in table-cell context; headings and
  other single-line inline contexts are unchanged for now. `insertLineBreak`
  likewise only spells the *in-cell* break; a general (non-cell) hard-break
  authoring gesture — which twig does not have today — is left as future work,
  and the op reports `error.UnsupportedFormat` outside a cell.

Everything from here down is the original draft, preserved for rationale.

## Summary

Twig can build every table structure a document needs (`tableInsertRow`,
`tableInsertColumn`, `tableSetAlignment`, moves…), but it has **no way to put a
line break *inside* a cell** and round-trip it. A table row is one source line,
so the break every format normally spells with a newline can't appear there —
and the one spelling that can (an inline `<br>`) is neither produced by an editor
op nor read back as a break.

Leaf works around this today with two opinionated hacks in `leaf-core`:

1. **Insertion** (`Doc::cell_line_break`) splices a literal `<br>` into the cell
   source — Markdown-shaped, regardless of the document's actual format.
2. **Rendering** (`wysiwyg.rs`) sniffs a `raw_inline` whose text is `<br>` and
   treats it as a line break when laying out a cell.

Both belong in twig: the first is a spelling decision (which token means "in-cell
break" in *this* format), the second is a parse decision (what a `<br>` in a cell
*is*). This proposal moves both into the engine and adds the editor op leaf is
missing.

## The concrete gap

Two observations against the current engine (twig `2.2.x`, verified on the CLI):

**Parsing.** In a Markdown table cell, `<br>` becomes a `raw_inline`, not a
`hard_break` — CommonMark specifies raw HTML as pass-through, so this is correct
by the spec but leaves the break unaddressable as a semantic node:

```
$ printf '| a<br>b | c |\n|---|---|\n| d | e |\n' | twig convert -i md -o ast
... "kind": "cell"
      "kind": "str"          # "a"
      "kind": "raw_inline"   # "<br>"   ← not hard_break
      "kind": "str"          # "b"
```

**Serialization.** If a `hard_break` node *did* live in a cell, the serializer
would corrupt the table. `renderInlineChildren` runs cell content through the
ordinary inline path (`src/languages/markdown/serializer.zig:382`), and the
`hard_break` arm there emits a newline:

```zig
// src/languages/markdown/serializer.zig:500
.hard_break => {
    try self.writer.writeAll("  \n");   // two spaces + NEWLINE → breaks the row
    try self.writePrefix(ctx);
},
```

Djot is the same shape (`\` + newline, `src/languages/djot/serializer.zig:384`).
So a cell can neither *hold* a hard break in the AST nor *emit* one as valid
markup. The `<br>` spelling is the only thing that fits a single source line, and
twig currently treats it as opaque HTML on the way in and can't produce it on the
way out.

## Goals

- A `hard_break` node **inside a cell** round-trips: parse → AST → serialize
  produces the same table.
- One editor op inserts it, format-correctly, via the existing `Syntax` table.
- CommonMark / GFM / djot conformance is untouched outside table cells.
- Leaf deletes both hacks and calls the op + reads the semantic node.

## Non-goals

- Promoting `<br>` to `hard_break` *everywhere* (that's the broad
  `html_elements` option; it reshapes `<img>`/`<h1>`/… and changes conformance).
  This proposal scopes the promotion to table-cell context only.
- Multi-line cells in the *box-glyph picture* renderers beyond what already
  works — this is about the AST/round-trip, not the terminal picture.

## Design

Three coupled changes, each at the layer that owns the decision.

### 1. Spelling — a new `Syntax` field

`Syntax` (`src/syntax.zig:101`) is the per-format spelling table; a `null` entry
already means "this format can't spell this gesture" → `error.UnsupportedFormat`.
Add the in-cell break spelling there:

```zig
pub const Syntax = struct {
    // …existing fields…

    /// How a hard break is spelled *inside a table cell*, where a row is a
    /// single source line and the normal newline spelling can't appear. `null`
    /// = this format has no in-cell break, so `insertLineBreak` inside a cell is
    /// `error.UnsupportedFormat` (and a `hard_break` that reaches the serializer
    /// inside a cell is `error.NotEditable` rather than emitted as a row-breaker).
    cell_line_break: ?[]const u8 = null,
};
```

Per-format literals (`src/languages/{markdown,djot}/syntax.zig:39`):

| Format   | `cell_line_break` | Rationale |
|----------|-------------------|-----------|
| Markdown | `"<br>"`          | GFM's only in-cell break; raw HTML is valid in a GFM cell. |
| Djot     | **open question** | Djot has no native in-cell break — see below. |
| HTML/XML | `null`            | Parse-only; already unauthorable. |

### 2. Serialization — cell context

Give the serializer's `Ctx` (`src/languages/markdown/serializer.zig:25`) a flag
so the `hard_break` arm knows it's inside a cell:

```zig
const Ctx = struct {
    prefix: ?*const Prefix = null,
    in_cell: bool = false,     // set true when descending into a `cell`
};
```

Set it where the table walker descends into cells (…serializer.zig:382,
`renderInlineChildren(cell.id, ctx)` → pass `ctx` with `in_cell = true`), and
branch the break arm:

```zig
.hard_break => if (ctx.in_cell) {
    const spelling = self.syntax.cell_line_break orelse return error.NotEditable;
    try self.writer.writeAll(spelling);        // "<br>" — no newline, row stays intact
} else {
    try self.writer.writeAll("  \n");
    try self.writePrefix(ctx);
},
```

(Djot serializer gets the same branch against the same field.)

### 3. Parsing — `<br>` in a cell is a `hard_break`

So the token round-trips, the inline parser must read the in-cell `<br>` back as
a `hard_break`. Twig already has the promotion machinery (`promoteInlineHtml`,
`src/languages/markdown/inline.zig:805`) — today gated behind the broad
`html_elements` option. Scope a *narrow* form to cell context:

- When parsing inline content **that belongs to a table cell**, promote a
  `<br>` / `<br/>` / `<br />` raw inline to `hard_break` unconditionally (it is
  unambiguously a break; the spelling round-trips 1:1 via change #2).
- Everywhere else, behavior is unchanged — `<br>` in a paragraph stays a
  `raw_inline` under CommonMark/GFM, exactly as now.

This keeps the 652 CommonMark + GFM spec examples green (none put `<br>` in a
cell expecting a `hard_break`) while making the cell case structural.

### 4. Editor op

```zig
/// Insert a hard line break at `offset`. Inside a table cell this is the
/// format's in-cell spelling (`Syntax.cell_line_break`); elsewhere it is the
/// ordinary hard break. `error.UnsupportedFormat` when the format has no
/// spelling for the context, `error.NoBlock` when `offset` is in no block.
pub fn insertLineBreak(self: *Editor, offset: usize) Error!void
```

It resolves the block at `offset`, checks whether that block is a `cell`, and
splices the appropriate spelling — reusing the same splice+reparse+rollback path
every other gesture uses (so a break that would corrupt the doc yields
`error.EditConflict` and changes nothing, per the existing contract).

## The djot question (where leaf/twig must be opinionated)

Djot genuinely has no native in-cell hard break: a pipe-table row is one line,
and djot's hard break (`\` at end of line) needs a line end that a cell doesn't
have. The honest options:

- **A. `cell_line_break = null` for djot.** `insertLineBreak` inside a djot cell
  is `error.UnsupportedFormat`; the frontend disables/space-substitutes. Most
  faithful to djot, least capable.
- **B. `cell_line_break = "<br>"` for djot too.** Djot passes an inline `<br>`
  through as raw HTML (`` `<br>`{=html} `` is the "proper" inline-raw form, but a
  bare `<br>` also survives as raw inline). Uniform with Markdown, mildly
  non-idiomatic djot.
- **C. A twig house convention.** Define twig-djot as spelling it `<br>` and
  document it as a deliberate dialect choice (twig already tracks `dialect` as a
  render-time fact, `options.zig`).

Recommendation: **B for now** (uniform, unblocks leaf), revisited if a cleaner
djot idiom emerges. This is exactly the "leaf may need to be opinionated" call —
made once, in twig, instead of per frontend.

## API surface (additions only)

```zig
// src/syntax.zig
Syntax.cell_line_break: ?[]const u8 = null

// src/languages/markdown/serializer.zig (+ djot peer)
Ctx.in_cell: bool = false

// src/ast/editor.zig
pub fn insertLineBreak(self: *Editor, offset: usize) Error!void

// bindings/rust/twig — mirror as:
pub fn insert_line_break(&mut self, offset: usize) -> Result<(), Error>
```

No breaking changes: `FlatNode` already surfaces `hard_break`; `Syntax`/`Ctx`
gain defaulted fields; the op is additive. `assertCoherent` gains no new
invariant (a `null` in-cell spelling is a valid, complete state).

## What leaf deletes once this lands

- `Doc::cell_line_break` stops splicing a literal `<br>`; it calls
  `editor.insert_line_break(caret)`.
- `wysiwyg.rs` stops sniffing `raw_inline == "<br>"`; the cell's inline children
  now contain a real `hard_break`, handled by the existing break arm. (The
  `break_glyph` newline mechanism stays — it's a *rendering* concern, correctly
  in leaf.)
- The FFI cell-line split (`cell_lines`) is unchanged — it already keys on the
  `\n` render glyph, which the `hard_break` still produces.

## Open questions

1. Djot spelling — A, B, or C above.
2. Should the narrow cell-context `<br>`→`hard_break` promotion also apply to
   `<br>` in a **heading** or other single-line-ish inline context, or stay
   strictly table cells?
3. Round-trip test matrix: `canonical` output of `| a<br>b |` must byte-equal a
   normalized input across both formats — add to the conformance corpus.
