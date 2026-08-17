---
part_of: '[Twig](/twig.md)'
---
# Twig — design notes

This document is the home for the design rationale, scope roadmap, and
vocabulary that Twig's source comments refer to. If you are reading a comment in
`src/` that mentions a *principle*, a *phase*, or a *priority tier*, this is
where those terms are defined.

Twig is published independently ([crates.io](https://crates.io/crates/twig-doc),
[docs.rs](https://docs.rs/twig-doc)), so everything a reader needs travels
with the repo. This file is deliberately self-contained.

One topic has its own file. The rationale behind the shared AST's kind
vocabulary — why it is one flat union rather than a nesting, what the three
classifiers (`level`, `contentModel`, `structuralChildren`) are for, and why
each kind exists rather than a cheaper alternative — lives in
[AST-KINDS.md](/AST-KINDS.md). `src/ast/ast.zig`'s comments say what a kind
*is* and point there for why.

---

## Relationship to `fig`

Twig is a sister project to [`fig`](https://github.com/diaryx-org/fig).
`fig` parses **configuration** files (JSON, YAML, TOML) and edits them in
place; Twig applies the same architecture to **document** files (Djot,
Markdown, HTML, XML). Twig was built by carrying `fig`'s module layout and
conventions over to documents, so many source comments note where a Twig
module mirrors its `fig` counterpart (e.g. `cli/args.zig`, `ast/reader.zig`,
`span.zig`).

Those "mirrors `fig`'s …" notes are lineage/rationale, not required reading:
`fig` is a public repository, and the comparison is there for anyone curious
why a module is shaped the way it is. Shared conventions worth naming once:

- **Per-language modules.** Each format lives under `src/languages/<name>/`
  with the same internal shape (a scanner/parser, a serializer, an
  `<name>.zig` entry point that aggregates every sibling file's `test {}`
  blocks). Comments call this "the fig/djot/xml convention."
- **Thin CLI.** `main.zig` turns argv into a config and dispatches; the verb
  implementations live in `cli/`. Diagnostics are printed at the site that
  detects the problem, then a sentinel error unwinds to `main`.
- **Byte-span AST.** Every node carries a `Span` into the original source, and
  edits are byte-span splices, never re-serialization of the whole tree.

---

## Design principles ("the mission")

Some comments cite "the mission" — Twig's design charter. The principles it
refers to are:

- **Lossless by default.** An edit rewrites only the bytes inside the target
  span; everything outside it is copied verbatim and never reflows. Twig
  never reformats what it didn't edit. (See `ast/splicer.zig`.)
- **Modest, clean CLI.** The CLI is plain `stdout`/`stderr` writers — no
  `std.log`, no terminal-color / `NO_COLOR` machinery. Keep it small.
  (See `main.zig`.)
- **`convert` is the workhorse.** `twig convert file.dj` with no other
  arguments renders HTML; HTML is the default output mode. (See `cli/args.zig`.)
- **Extensions off by default.** Non-CommonMark / non-GFM features (math,
  and other `ParseOptions` toggles) are opt-in; with everything off, output
  matches strict CommonMark. (See `languages/markdown/options.zig`.)
- **The correctness bar is the real source.** Span tests slice the *original*
  source with a resolved node's span and check the bytes — parsing must
  produce spans that address the true input, not a re-emitted approximation.
  (See `languages/markdown/block.zig`'s span tests.)

---

## Markdown scope: the three phases

Twig's Markdown support targets CommonMark 0.31.2 and was built in three
phases. This roadmap is documented in full in
`src/languages/markdown/markdown.zig`'s module doc comment; the short version:

- **Phase 1** — block structure (headings, lists, block quotes, code blocks,
  HTML blocks, thematic breaks, link reference definitions) plus a minimal
  inline subset.
- **Phase 2** — the rest of CommonMark's inline grammar (emphasis/strong,
  links, images, autolinks, raw inline HTML), resolved at parse time.
- **Phase 3** — GFM and other `ParseOptions` extensions (tables,
  strikethrough, task lists, footnotes, definition lists, frontmatter, math)
  plus GFM's extended autolinks.

Comments across `languages/markdown/` reference these phase numbers; they are
all anchored by the `markdown.zig` doc comment above.

---

## The two format axes: `Format` and `Target`

Twig has two format vocabularies, not one, and `src/format.zig` holds a table
for each:

| Axis | Type | Table | Question it answers |
|------|------|-------|---------------------|
| Input | `Format` | `registry` | What can Twig **parse**? |
| Output | `Target` | `targets` | What can Twig **write**? |

Every `Format` is also a `Target`, so today the two lists have the same five
names. They are separate types because only one of them can grow freely. A
`Format` variant is `ParsedDoc`'s tag: it must have a parser, a bare-AST reparse
adapter for the `Splicer`, and a document type to hold. A `Target` needs none of
that — it needs somewhere for bytes to go.

That difference is what makes an **export-only target** expressible: a format
Twig can write and no parser can read back. PDF is the motivating case. Such a
target appends to `Target` and gets a `targets` row with `reads_back_as = null`;
it gets no `Format` variant, no `registry` row, no `ParsedDoc` variant and no
`Syntax`, none of which it could honestly fill in. Before the split there was
nowhere to put one that did not also claim Twig could parse it.

Two consequences worth knowing before adding a target:

- **`serializeFromAst` belongs to the output row.** It is keyed by where the
  bytes are going, not by what parsed them. `serializeCanonical` stayed on the
  input row, because it takes a `ParsedDoc` variant and so can only serialize a
  document that very entry parsed.
- **`Fidelity` is defined by a round-trip**, so it cannot describe an
  export-only target. `diagnostics.zig`'s probe derives the targets it measures
  from the `targets` table (`serializeFromAst != null` and `reads_back_as !=
  null`), so such a target drops out by construction rather than by a stale
  hardcoded list — and `fidelity`'s exhaustive switch will still demand an
  answer for it. The honest answer there is a second axis, not a guess on this
  one: PDF loses no content and all structure, which is the inverse of what
  every current entry measures.

The split was latent before it was made. `diagnostics.fidelity(target, kind)`
had always indexed its capability table on an output axis while spelling the
parameter `Format`, and `cli/format.zig` had already named its `-i` re-export
`InputFormat` to distinguish it from what `-o` accepts.

---

## Editor surface: priority tiers (P0, P1, …)

The C-ABI `twig_editor_*` functions expose an **embeddable rich-text editor**
where a caret speaks byte offsets rather than selector strings. The tiers
(P-numbers in `c_abi.zig`) order the build-out of that surface by priority:

| Tier | Capability        | C-ABI entry points                          |
|------|-------------------|---------------------------------------------|
| P0   | Raw offset splice | `twig_editor_edit_range` (the keystroke primitive: insert, backspace, selection-replace) |
| P1   | Hit-test          | `twig_editor_node_at` (offset → deepest containing node) |
| P2   | Tree read-back    | `twig_editor_nodes` (whole tree as a flat array, so a renderer needn't parse JSON) |
| P3   | Ancestor chain    | `twig_editor_nodes_at` (root→deepest path, for breadcrumbs / context-scoped edits) |
| P5   | Toolbar           | `twig_editor_wrap_range` / `_toggle_inline` / `_set_block` (Bold / Italic / Code buttons, H1 / Body switch) |

Intermediate/edit-history capabilities (undo, redo, coalescing, caret
persistence) fill in around these — see the individual `twig_editor_*` doc
comments in `c_abi.zig`. The tier numbers are only a priority label; they
don't imply anything beyond "what got built in what order."

**A toolbar needs the answer before the call.** Twig's formats are ragged —
djot spells all eight inline marks, Markdown three, HTML spells marks and
nothing block-level, XML and AsciiDoc nothing — and every gesture already
reports that, as `TWIG_STATUS_UNSUPPORTED_FORMAT`. But that arrives *after* the
call, which is too late to gray a button out rather than let it fail. So
`twig_format_supports(format, gesture, kind)` asks the same question earlier:
a pure function of the format code, no handle and no document, since an editor
building its toolbar has a format and not yet a tree. It is a second reading of
the very `Syntax` fields the gestures gate on, and a test pins it against every
gesture's real refusal in every format, so it cannot drift into promising a
button that would be refused. `twig_format_is_authorable` is the coarser
open-read-only question beside it — deliberately *not* the per-button one, for
the reason its doc comment gives: HTML answers yes on its inline marks alone.

That query is one of three neighbouring questions this codebase keeps
separate on purpose, because conflating them gives wrong answers in both
directions:

| Question | Where it lives | What it is for |
|----------|----------------|----------------|
| May an editor gesture *mint* this spelling? | `Syntax`'s per-gesture fields, read by `Editor.supports` | Toolbar enable/disable |
| Is there any door into this format at all? | `Syntax.authorable()` | Open read-only, hide the toolbar |
| What survives a *conversion* to this target? | `diagnostics.zig`'s measured `fidelity` table | Save-as / convert warnings |

The first two are asserted from the spelling tables; the third is **measured** —
a test builds a document around every kind, serializes it, and reparses with the
target's own parser. They genuinely disagree: a smart-quote container is
`authorable = false` in both djot and Markdown, yet round-trips djot faithfully
and Markdown not at all.

**The reads are not editor-specific.** P1–P3 above (plus `_child_spans` and
`_subtree`) answer questions about a *tree*, not about an editing session, so
they live on `TwigDocument` as `twig_document_nodes` / `_children` / `_subtree`
/ `_node_at` / `_nodes_at`. A parse-only consumer calls them on a `twig_parse`
handle — no editor needed just to walk flat nodes — and an editor reaches them
through `twig_editor_document`, a borrowed `TwigDocument` over its live tree.
The `twig_editor_*` spellings remain as aliases onto exactly that code and
those buffers. The two document functions the borrowed view cannot serve are
`twig_document_render_html` and `twig_document_serialize`: both are chosen by
the document's own format and read its language side tables, and an editor
holds a bare-AST reparse with neither. That asymmetry is the reason the split
is a *view* rather than one merged handle type.
