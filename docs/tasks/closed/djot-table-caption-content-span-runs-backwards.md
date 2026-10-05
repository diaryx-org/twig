---
title: 'A djot table with a caption gets a `content_span` that runs backwards'
description: "`closeTable` builds the table's `content_span` from the caption to the rows, so it ends before it starts, and the caption lies outside the table's own `span`; twig's table decoder refuses the result."
author: adammharris
created: 2026-10-02
updated: 2026-10-05
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# A djot table with a caption gets a `content_span` that runs backwards

`closeTable` builds the table's `content_span` from the caption to the rows, so it ends before it starts, and the caption lies outside the table's own `span`; twig's table decoder refuses the result.

## Repro

`printf '| a | b |\n\n^ cap\n' | twig lang table -i djot -` gives
`{"kind":"table","span":[0,10],"content_span":[13,10]}` with the caption
child at `[13,17]`. `ast/table.zig`'s `decode` refuses that table, so a
runtime twin cannot hand it back. Found by `twig-quickjs`'s djot twin
(djot.js `tables.test:35`, `regression.test:46`).

## Done when

A captioned table's `span` and `content_span` cover its caption, start
before they end, and survive `lang table` → `decode`; djot's samples gain a
captioned table so the harness holds it.

## Resolution

Done on 2026-10-05, in `fix(djot): a captioned table's span and interior run to its caption`.
`closeCaption`, which swaps the caption in as the table's first child,
now extends the table's `span` to the caption's end and sets its
`content_span` from the first row's start to the same end, rather than
from the first child to the last, which ran from the caption back to the
rows. The repro gives `"span":[0,17],"content_span":[0,17]` with the
caption at `[13,17]` inside both. An earlier caption a later one replaces
lies inside the table's span, as its bytes do. djot's samples gain a
captioned table, so the harness's table identity and decode hold it, and
a `span:` test in `parser.zig` slices the source with both spans.
