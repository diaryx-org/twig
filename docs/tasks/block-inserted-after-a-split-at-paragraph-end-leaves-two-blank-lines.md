---
title: A block inserted after a split at a paragraph's end leaves two blank lines behind it
description: '`splitBlock` at the end of a paragraph writes a blank line and an empty slot for the paragraph to come; a rule or a table then inserted after the first half lands above that slot, and the document ends in two blank lines that nothing fills'
author: adammharris
created: 2026-09-18
updated: 2026-09-18
status: dropped
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# A block inserted after a split at a paragraph's end leaves two blank lines behind it

**Status: dropped** on 2026-09-18, in favour of (2). The fold is not
written; twig's `insertBlockAfter` keeps leaving spacing it did not write
alone. The fix is leaf's, as
[rule-and-table-at-a-paragraph-end-split-nothing-and-leave-blank-lines](https://github.com/diaryx-org/leaf/blob/main/docs/tasks/rule-and-table-at-a-paragraph-end-split-nothing-and-leave-blank-lines.md):
do not split when the caret sits at the paragraph's end, since there is
nothing to part.

One twig change did come out of checking that (2) is safe, and it is a
prerequisite of the leaf task rather than this one: with the split gone,
the caret at the end of a document whose last line has no newline yet —
`"para"` at 4, the commonest caret while typing — reached `insertBlockAfter`
directly, and it wrote its blank line above as a bare `\n` that only
terminated the line: `"para\n---\n"`, a setext heading. The no-op split had
been masking it. Fixed in `a08bcf3`, with its `Behavioural-change:` trailer;
leaf's task waits on the release that carries it.

**Repro.** Markdown and djot alike:

```
source        "para\n"
splitBlock(4)                 → "para\n\n\n"
insertThematicBreak(4)        → "para\n\n---\n\n\n"
insertTable(4, 1, 1)          → "para\n\n|  |\n| --- |\n|  |\n\n\n"
```

The same two gestures at the end of a paragraph *without* the split give
`"para\n\n---\n"` and `"para\n\n|  |\n| --- |\n|  |\n"` — one trailing
newline, the document a rule or a table was asked for.

**Why it happens.** Each half is doing what it says. `splitBlock` at a
paragraph's end cannot mint a second paragraph, because no format spells an
empty one; it writes the separator and leaves the caret where the next
paragraph will begin, and its test (`split_block: at a paragraph's end the
empty block is unrepresentable`) pins that as the intended shape — Enter at
the end of a paragraph, then type. `insertBlockAfter` — the placement the
rule and the table share — writes a blank line above the block and one
below *only when the next line is not already blank*, which it is, so it
adds nothing; the empty slot the split left is simply carried past the new
block. Neither is wrong on its own. Composed, they leave a paragraph slot
that nothing will ever fill, because the caller's next act was the block
and not the text the split was making room for.

**Who composes them.** leaf. Its `Doc::insert_thematic_break` and
`Doc::insert_table` part a bare paragraph around the caret first (so the
block lands *at* the caret rather than after the whole paragraph) and aim
the block at the first half — the pattern leaf's own doc comment describes.
At the caret's paragraph end the part is a no-op that still writes bytes.

**Two places it could be fixed, and a call to make.**

1. In twig, `insertBlockAfter` could fold a *run* of blank lines below the
   block to one — reading "the next line is already blank" as "there is
   already a separator, and one is all a separator is". That is a change
   in what an existing call returns for a document that already carries
   two blank lines under the caret's block, so it would need a
   `Behavioural-change:` trailer, and it edits bytes an author wrote that
   the gesture was not asked to touch.
2. In leaf, do not split when the caret sits at the paragraph's start or
   end: there is nothing to part, and `insertBlockAfter` already answers
   "after the block" correctly on its own. This is the narrower fix and
   touches no twig contract; it is a leaf task once the call is made.

The thing to decide is whether a block gesture should ever normalise blank
lines it did not write. The rule's own doc comment argues for leaving a
document's spacing alone ("the blank below is added only when the next line
isn't already blank, so repeating the gesture doesn't accumulate them"),
which leans toward (2), with twig unchanged.

**Done when** either the twig-side fold lands with its trailer, or this is
closed as `dropped` in favour of the leaf task, which then links back here.
