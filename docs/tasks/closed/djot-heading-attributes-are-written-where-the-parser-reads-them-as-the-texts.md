---
title: djot writes a heading's attributes after its text, where its parser reads them as the text's
description: '`## x{#id .c}` is what the djot serializer prints for a heading carrying attributes; djot reads a `{…}` after inline content as that content''s attribute block, so the heading comes back bare and the `str` carries the set. The block spelling is the line before, as the serializer already writes for a paragraph.'
author: adammharris
created: 2026-09-18
updated: 2026-09-18
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# djot writes a heading's attributes after its text, where its parser reads them as the text's

**Status: done** on 2026-09-18, in `fix(djot): a heading's attributes are
written on the line before it, and a section's with them`. The probe does
not record `.faithful` after all: the block it writes names an id, and djot
reads a heading's block that names an id as the *section's* — the parser
moves the whole set, after djot.js — so the heading comes back bare and the
table's honest answer is `.degraded`, for the reason AsciiDoc's already was.
What the fix reaches is the round-trip: the section's set is written on the
same line before the heading, minus the id the parser derived from the
title, so `{#h .x}\n## t` is `{#h .x}\n## t` again, where it had been
`## t` — the section's attributes were dropped outright before this.

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
