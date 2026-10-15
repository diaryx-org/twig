---
title: 'Proposal: a document as data'
part_of: '[Proposals](/docs/proposals/proposals.md)'
status: draft
author: adammharris
created: 2026-10-15
updated: 2026-10-15
---

# A document as data

## Status

`draft`. The direction is set — read a document the way nushell's `from md`
does, as a table of elements — and nothing is built. It follows
[one crate per language](language-crates.md), which gives it a place to
live.

## The question

fig reads config and twig reads documents, and the two meet only at a
document's frontmatter (`twig::meta`). The interop this proposal is after is
wider: Markdown into JSON (or YAML, or TOML) and back, with fig's whole
toolchain — `get`, `set`, `convert`, its lossless editor — working on a
document, and a config's data written out as a document.

twig can already write a document as JSON: `-o ast` and `-o table`, and the
table reads back losslessly. That JSON describes the *syntax tree*. It is the
right answer for a tool, and the wrong one for a person asking a document a
question: fig would see rows of nodes, not what the document says.

## What nushell does

nushell 0.112 added `from md`, which turns Markdown into structured data; 0.113
made its default a reduced mode and moved the full tree behind `--verbose`.
The reduced mode is a **flat table of elements**, one row per block, each with
its `element` (`text`, `code`, `yaml` for frontmatter, …), its `content`, and
where it came from (`content_span`); child rows are promoted, so a heading's
text is a row's content rather than a subtree. `to md` goes the other way for
the case data has a natural document shape: a table becomes a Markdown table.

What that gets right:

- **The shape does not depend on the content.** A document is always a list
  of rows, so adding a paragraph never changes the type of anything — the
  failure of any mapping that guesses "this section is a list, so it is an
  array".
- **Spans come with every row**, so a row is an address back into the source.
- **Two levels**, concise by default and the full tree on request, the same
  split twig already has between a reader and `-o ast`.

## The proposal

Under `twig-doc`'s `fig` feature, beside `twig::meta`, an adapter that
makes every registered twig language a fig `Language`:

1. **Read.** `parse_table` maps a twig `Document` onto fig's node table as a
   sequence of element records, nushell's reduced mode: `element` (the kind
   name twig already publishes), `content` (the element's source text), and
   its span. Headings carry `level`; lists and tables keep their items and
   rows as nested sequences, because those are data already; a table's rows
   are records keyed by its header row. Frontmatter is the parsed fig value
   itself, through `twig::meta`, not a string. `--verbose`'s equivalent is the
   node table twig already writes.
2. **Write.** fig's printer over that shape writes Markdown (or any target
   twig prints): a sequence of records becomes the blocks they name, and a
   sequence of uniform records a table, as nushell's `to md` does.
3. **Edit.** fig's editor splices by span, so `fig set doc.md '3.content'
   …` rewrites one block and nothing else; fig's fragment renderers
   (`render_item`, `render_entry`) are twig's `Syntax`, which already knows
   how to spell a block it inserts.

Because the mapping reads the shared tree, Djot, AsciiDoc and HTML get it
with no work of their own.

## Open questions

- **Element names.** twig's kind names (`para`, `heading`, `code_block`) or
  nushell's (`text`, `h1`, `code`)? twig's are already a published contract.
- **Inline content.** Is a paragraph's `content` its source (markup kept, so
  it round-trips) or its text (what a reader wants)? nushell gives the text.
- **A view keyed by headings.** Some documents are records (`## Install`
  then steps). A second, opt-in view — headings as keys — would make
  `get Install.steps` work, at the cost of the stable shape. Only as a view,
  never the default.
- **Types.** Markdown only has strings. fig's lossless envelope (`$fig`)
  already carries types through string-only formats; whether a document
  should declare that it takes one is fig's `Caps` question.
- **Where it lives.** In twig's `fig` feature (it follows twig's tree, which
  changes more) or in fig (as `fig-markdown`)? This draft says twig.
