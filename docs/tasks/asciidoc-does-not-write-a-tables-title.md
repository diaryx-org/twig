---
title: AsciiDoc does not write a table's title
description: 'Every other block''s `title` attribute becomes a `.Title` line above its `[…]` attribute line in the AsciiDoc serializer; a table''s is not written, so a titled table converted to AsciiDoc loses the title with only the attribute probe to say so.'
author: adammharris
created: 2026-09-18
updated: 2026-09-18
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# AsciiDoc does not write a table's title

Found by the attribute probe in `diagnostics.zig` (`1bc22e1`), which
records it as `attrsFidelity(.asciidoc, .table).title == .dropped` beside
`.faithful` for every other key on a table.

**Repro.** Build a `table` with a header row and set `title=Figures` on it;
serialize to AsciiDoc:

```
[%header,cols=1]
|===
|a
|===
```

No `.Figures` line. `asciidoc/serializer.zig`'s `writeBlockAttrs` writes
one for a paragraph, a listing, a quote; the table arm reaches it with
`title` in its `skip` list, or not at all.

**Done when** a table's `title` is written as its `.Title` line, the
AsciiDoc parser reads it back onto the table, and the probe records
`.faithful`.
