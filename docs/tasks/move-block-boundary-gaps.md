---
title: "`move_block` reads three boundaries as places the block already is, or as inside a container it is not"
description: "The last block of a quote cannot be dropped on the blank line after the quote, a paragraph cannot be moved above a quote that opens the document, and a `to` at the source's length behind a trailing list lands in the last item's tail — each a `to` a caret can name and a drop indicator can draw"
author: adammharris
created: 2026-09-21
updated: 2026-09-21
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# `move_block` reads three boundaries as places the block already is, or as inside a container it is not

**Where.** `move_block`'s resolution of `to` — the rule that a boundary is
inside the innermost container it touches, and the check that a boundary is
one the block already sits on.

**What.** leaf's `Doc::move_block_up`/`down` and its drop target
(`leaf/docs/tasks/move-a-block.md`) name a boundary from the tree and hand
it over, and three boundaries a person would point at come back refused or
land somewhere else. Each is Markdown, twig-doc 3.9.0, `Editor::new` then
`move_block(from, to)`:

1. **Out of a quote, downward.** `"x\n\n> a\n>\n> b\n\ny\n"`, `from` on `b`
   (10), `to` on the blank line after the quote (12): `InvalidArgument`.
   The mirror works — `from` on `a` (5) to the blank line *before* the quote
   (2) gives `"x\n\na\n\n> b\n\ny\n"` — and so does the same drop aimed at
   `y`'s first byte (13), which is the same boundary at the top level:
   `"x\n\n> a\n\nb\n\ny\n"`. The blank line after a container reads as the
   boundary after its last block, which is where the block is; it is also
   the boundary after the *container*, which is not. A one-block quote has
   the same shape: `"> b\n\ny\n"`, 2 → 4 is `InvalidArgument`, 2 → 5 works.

2. **Above a quote that opens the document.** `"> a\n\ny\n"`, `from` on `y`
   (5), `to` 0: `"> y\n>\n> a\n"` — `y` joins the quote rather than going
   above it, because offset 0 is inside the quote, and no other offset names
   "before the quote" when nothing precedes it. leaf refuses the step with
   "nothing above" rather than move the paragraph into the quote.

3. **The source's length behind a trailing list.** `"p\n\n- a\n- b"`, 0 → 10
   (the length): `"- a\n- b\n\n  p"`, the paragraph in `b`'s tail. With a
   trailing newline, `"p\n\n- a\n- b\n"` 0 → 12 is `InvalidArgument`, while
   0 → 11 (the list's end) gives `"- a\n- b\n\np\n"`. The docs name the
   source's length as "the document's end", which after a paragraph it is.

**Shape.** A boundary that closes a container is two boundaries — after the
container's last block, and after the container — and which one `to` means
is decidable: a `to` on a line *outside* the container (a blank line with
no `>`, the source's length) is the outer one. Under that reading (1) and
(3) move the block out and (2) needs a spelling for "before the first
container of the document", which the blank line rule does not give;
`to == 0` when the document opens with a prefix container could be read as
outside it, since a boundary inside it is reachable at its first content
byte. leaf's `boundary_above`/`boundary_below` (`leaf-core/src/doc.rs`)
carry the per-kind reading today and can drop it once this lands.

**Done when** the three cases above move the block out of the container,
the harness has them for every authorable format, and leaf's `before`/
`after` collapse to `span.start`/`span.end`.
