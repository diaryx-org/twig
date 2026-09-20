---
title: "Proposal: the tree gestures a canvas over an SVG needs"
status: implemented
author: adammharris
created: 2026-09-20
updated: 2026-09-20
part_of: '[Proposals](/docs/proposals/proposals.md)'
---

# The tree gestures a canvas over an SVG needs

## Status

`implemented` on 2026-09-20, in four commits: the XML parser records every
element's attribute span; `Editor.setNodeAttrs` and the `Syntax.node_attrs`
claim behind it, with XML's first spelling table; `Splicer.moveNode`; and
the `svg` dialect row. Each reached the C ABI, the Rust crate and the
header in the same commit. Two things the argument below did not foresee.
The move carries the whitespace run ahead of the node rather than moving
the node's bytes alone, because the first test over a pretty-printed
document put two shapes on one line and left a blank one behind, and
"reorder" does not mean that to anyone. And `authorable()` was left false
for XML on purpose: it is the read-only question a prose editor asks, and a
format whose one gesture no caret can reach should keep answering no to it.

## The picture

Diaryx wants drawings — the Excalidraw and tldraw kind — stored as a file
anyone can open without the app. That file is SVG: viewable in a browser, a
file manager's preview and a git forge, and already rendered by leaf on
every one of its frontends through one parser. What is not settled is what
edits it. A drawing editor is a *tree* editor: the user drags a `<rect>` and
the edit is its `x` and `y`; brings a shape forward and the edit is sibling
order; deletes a stroke and the edit is a `<path>` gone. Nothing in it is a
caret.

Twig already holds most of the lossless layer such an editor needs and
would otherwise rebuild. The XML parser keeps everything — elements with
attributes, comments, processing instructions, CDATA — with a byte span on
every node. The splicer's one mutator is a span splice under a reparse that
rolls back on failure, with undo on top, and its node ops (`insertBefore`,
`insertAfter`, `insertChild`, `deleteNode`, `unwrapNode`) are language
agnostic and already on the wire. What was missing was small, and none of
it is about drawings.

## What was missing

**A recorded attribute span on an XML element.** `Document.attrs_spans` is
the column an attribute edit splices, and djot and Markdown filled it; the
XML parser did not. Without it a change to one attribute of a `<g>` holding
a thousand paths re-prints the `<g>` — every path, every comment, every run
of indentation — through a serializer that cannot promise to spell them as
they were. With it the edit is the start tag's interior and nothing else.

**A gesture addressed by node, not by offset.** `Editor.setBlockAttrs`
finds a *block* by byte offset, which is the right question for a caret
over prose and the wrong one for a canvas: a shape has an id in the tree
and no byte position stands for it, and an SVG has no blocks. So a sibling
gesture, `setNodeAttrs(id, attrs)`, which takes the id `twig_editor_nodes`
handed out and splices the recorded span, or inserts after the name when
the element has none. Its gate is a new `Syntax` claim, `node_attrs`,
because *where a node's attributes are spelled* is format knowledge — on
the node's own tag in XML, on a line above the block in djot, in a `<div>`
around it in Markdown — and the harness measures the claim the way it
measures every other: an element of every sample, given the attributes,
reparses carrying them.

**Reordering.** Delete-then-insert is two reparses, two undo steps, and an
intermediate document with the node missing. A z-order change is one
gesture and should be one splice: `moveNode` rewrites the range covering
both nodes with the bytes between them copied verbatim in their new order.

**A name for the file.** `-i svg`, `TWIG_FORMAT_SVG`, `Format::Svg`: a
dialect row over the xml language, the way `gfm` is over `markdown`, so a
`.svg` file is recognised on sight and a document records what it was
opened as. Twig learns nothing about what a `<rect>` means from it, and
should not.

## Why twig, and not the drawing editor

Each of the four could have been built above twig, on the raw splice and
the span reads, by the editor that wants them. They are here because none
needs to know what a shape is, and each needs to know what a format spells.
Where a node's attributes go is the first kind of knowledge; that a moved
XML element carries its indentation is the second. The org has run the
other experiment: leaf's clipboard code once carried three heuristics
re-deriving what twig could measure, and when twig exposed the measured
answer all three were deleted. Knowledge about a format migrates into the
format's library.

The line that stays: twig never learns that an element is a rectangle. The
profile a drawing editor writes, its shape model, hit-testing, transforms,
and rendering are the editor's, exactly as leaf's visual map is leaf's.

## What this changes for a consumer

Additive at the ABI: two node ops (`twig_editor_move_before`,
`twig_editor_move_after`), one gesture (`twig_editor_set_node_attrs`, code
`TWIG_GESTURE_SET_NODE_ATTRS`), one format code (`TWIG_FORMAT_SVG`). One
observable difference for an existing caller: `twig_document_attrs_span`
over an XML element now reports a span where it reported `not_found`,
which the commit carries as a behavioural change. `twig_format_supports`
answers 1 for XML on the new gesture and 0 on every other, and
`twig_format_is_authorable` still answers 0 there.

The Rust crate's `Format` and `Gesture` enums grow a variant each, which a
caller matching exhaustively will have to name — the cost every dialect
row and every gesture has paid before this one.
