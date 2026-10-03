---
title: "Converting from a runtime row to its compiled sibling ignores the table's labels and spelling"
description: '`twig convert -i js-djot -o djot` writes `[Heading]: #Heading` and `-`/`1.` markers where `-i djot -o djot` omits the implicit reference and keeps `+`/`1)`, though the two tables are identical.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Converting from a runtime row to its compiled sibling ignores the table's labels and spelling

`twig convert -i js-djot -o djot` writes `[Heading]: #Heading` and `-`/`1.` markers where `-i djot -o djot` omits the implicit reference and keeps `+`/`1)`, though the two tables are identical.

## Repro

Reported by `twig-quickjs`: with its djot twin configured as `js-djot`,
the two conversions above differ over a document with a heading and a `+`
list, while `twig lang check js-djot --against djot` says their tables are
the same. The runtime row's parse decodes the table's labels and spelling;
the cross-format serialize path from a runtime row appears not to use them.

## Done when

A document converted to djot reads the same whether it was parsed by the
compiled row or by a twin whose table is identical, and a runtime test in
`src/runtime.zig` holds it with the in-process `DjotTwin`.
