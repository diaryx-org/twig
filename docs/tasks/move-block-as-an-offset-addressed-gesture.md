---
title: "`move_block` — a block moves between containers and the destination's prefixes are twig's to spell"
description: "`move_before`/`move_after` move bytes, so a paragraph dragged into a quote or a list item lands without the `> ` or the indent its new container spells; the gesture family already says leaf names where and twig spells the rest"
author: adammharris
created: 2026-09-21
updated: 2026-09-21
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# `move_block` — a block moves between containers and the destination's prefixes are twig's to spell

## Resolution

Done on 2026-09-21, in the commit `add(editor): move a block to a boundary,
spelling the destination's prefixes`. `Editor.moveBlock(from, to)`, gesture
code 31 on the C ABI as `twig_editor_move_block`, `Editor::move_block` in
the Rust crate; `Syntax.list_attach` for AsciiDoc's `+`, and its `> ` quote
now records a marker span like Markdown's. The harness moves a paragraph out
of a quote, into a quote, into a list item's tail and between two
paragraphs over every authorable format, each against the format's own
print of the expected tree. Two things the argument below did not settle:
a moved list item is always a sibling (nesting stays
`toggle_block_container`'s), and a delimited container emptied by a move
stands, since it may carry attributes — where a `>` quote or a list whose
only content leaves goes with it. leaf's half is
[leaf/docs/tasks/move-a-block.md](https://github.com/diaryx-org/leaf/blob/main/docs/tasks/move-a-block.md),
and reaches it once this is released and the pin moves.

**Where.** The gesture family beside `set_block`, `toggle_block_container`,
`split_block` and `join_blocks`: offset-addressed, one `Change`, one undo
step, format-aware.

**What.** leaf is growing block drag-and-drop and a keyboard move
(`leaf/docs/tasks/move-a-block.md`). For a block moved *within* one
container the two node ops from
[the canvas proposal](/docs/proposals/tree-gestures-for-a-canvas.md) —
`move_before` and `move_after`, shipped in 3.8.1 — already do it in one
splice. Their rule, stated in their own doc, is what stops there: *the rule
is about bytes, not structure — a block quote's `> ` prefixes do not
travel.* So the drops that make restructuring worth having are the ones
they cannot spell:

- a paragraph dragged **out of** a `> ` quote keeps its `> ` and is still a
  quote, now split from the one it left;
- a paragraph dragged **into** a list item, under its text, lands without the
  continuation indent and closes the list instead of joining the item;
- the same into a Djot `:::` container is fine and into an HTML `<div>` is
  fine, into a Markdown quote is not — which is exactly the per-format
  knowledge `toggle_block_container` and `line_prefix`/`continuation_prefix`
  already hold.

A caller can only work around it by stripping and re-adding prefixes itself,
which is the experiment the canvas proposal names as already run and lost:
leaf's clipboard once carried three heuristics re-deriving what twig could
measure, and all three were deleted once twig measured it.

**Shape.** `move_block(from: usize, to: usize) -> Result<Change, Error>`.
`from` names the block the offset sits in (the deepest node that is neither
inline nor a multi-block container, the same block `set_block` acts on);
`to` names a *boundary* — the start of the block it lands before, or the
document's end — and the block takes the line prefixes of the container that
boundary is inside, dropping the ones it carried. Within one container it is
`move_before`/`move_after` and should produce byte-identical results to
them. `NotEditable` when `to` is interior to a block rather than between
blocks — inside a fence, a table, or a raw container — as `set_block` already
answers for a blank line there; `InvalidArgument` when `to` is inside the
block being moved. The gesture gets a `Gesture` variant and a
`twig_format_supports` row, answered per format like every other. Whether a
list item as a whole (not its text block) is a movable block is part of the
design: dragging a bullet with its children is the obvious reading, and the
walk up from `from` to the item is one rule to state.

**Done when** the harness has, for every authorable format, a paragraph
moved out of a quote to top level, into a quote, into a list item's tail, and
between two top-level paragraphs, each serializing to what a person would
have typed and reparsing to the expected tree; and leaf's `Doc::move_block`
calls this and its cross-container cases are enabled.
