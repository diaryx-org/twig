---
title: djot writes a heading's attributes after its text, where its parser reads them as the text's
description: '`## x{#id .c}` is what the djot serializer prints for a heading carrying attributes; djot reads a `{…}` after inline content as that content''s attribute block, so the heading comes back bare and the `str` carries the set. The block spelling is the line before, as the serializer already writes for a paragraph.'
author: adammharris
created: 2026-09-18
updated: 2026-09-18
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# djot writes a heading's attributes after its text, where its parser reads them as the text's

Found by the attribute probe in `diagnostics.zig` (`1bc22e1`), which
records the answer as `attrsFidelity(.djot, .heading) == .degraded`: written,
not read back as the heading's.

**Repro.** Convert `<h2 class="x">t</h2>` from HTML to djot:

```
## t{.x}
```

Reparse it: the `heading` has no attributes, and the `str` `t` has
`class=x`. djot's block attribute spelling is a `{…}` line *before* the
block, which `djot/serializer.zig`'s `.para` arm already writes; the
`.heading` arm writes `writeDjotAttrs` after `renderInlineChildren` instead.

**Done when** the heading arm writes the block before the `#` line, the
attribute probe records `.faithful` for `(.djot, .heading)`, and a
`Behavioural-change:` trailer says a converted heading's attributes moved
from the end of its line to the line above.
