---
title: "Proposal: editable HTML block elements"
status: draft
author: adammharris
created: 2026-09-09
updated: 2026-09-15
part_of: '[Proposals](/docs/proposals/proposals.md)'
---

# Editable HTML block elements

## Status

Still `draft`; the MECHANISM half closed on 2026-09-15 with
[Fragment renderers on the format](/docs/tasks/fragment-renderers.md).
`Syntax.renderBlock` lets a gesture build a node and have the format print it,
and `Editor.setBlock` takes that path where there is no heading marker — so a
leaf editor over an HTML document can now make a line a heading, and
`insertLiteral` there writes entities through `Syntax.renderText`. What
remains is exactly the question below: which of the other block elements — a
quote, a list and its items, a code block, a link — should be exposed the
same way, and how an element-origin `container` is described to an editor.

**Placeholder.** This records that the question is open, ahead of the review
that would answer it. It argues nothing yet.

## The question

`Format::Html` carries a `Syntax` table: seven of the nine inline marks as
tag pairs, `<code>` for verbatim, `<hr>` for a thematic break, `<br>` for the
in-cell break, and — since the renderers — a heading. Every other block
construct an editor would insert, a list and its items, a block quote, a code
fence, a link, is unspellable in HTML today, so a leaf editor over an HTML
document can mark a word bold and make a line a heading, and cannot quote it
or list it.

Whether that gap should close, and how far, is what needs deciding:

- Which block elements twig should let an editor author in HTML, and whether
  the answer is "the ones with a Markdown or Djot equivalent" or something
  wider.
- How an element-origin `container` should be described to an editor. leaf
  has a proposal to fold the ones it does not author into labelled panels and
  atoms, keyed on the tag name twig already threads through `FlatNode::name`.
  If twig can say more about an element, whether it is sectioning, whether
  its content is prose, whether it is chrome, the editor's list of tags
  becomes twig's classification instead.
- What `diagnostics` should say about a block an editor inserts into HTML
  that the other serializers cannot spell, given a paste already reads the
  `Section` kind as the one loss that is not a loss.

## Not yet

No survey of `languages/html/syntax.zig` or the serializer has been done for
this document. The review that produces the argument should start there and
with `docs/AST-KINDS.md`, and replace this body when it does.
