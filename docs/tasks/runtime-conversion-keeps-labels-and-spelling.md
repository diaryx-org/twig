---
title: "Converting from a runtime row to its compiled sibling ignores the table's labels and spelling"
description: '`twig convert -i js-djot -o djot` writes `[Heading]: #Heading` and `-`/`1.` markers where `-i djot -o djot` omits the implicit reference and keeps `+`/`1)`, though the two tables are identical.'
author: adammharris
created: 2026-10-02
updated: 2026-10-05
status: done
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

## Resolution

Done on 2026-10-05, in `fix(runtime): converting from a runtime row keeps the labels and spelling its table carried`.
The cross-format path handed every target the bare `AST`, so djot's
serializer re-indexed the labels (losing which reference was implicit)
and spelled every list canonically. `TargetEntry` gains
`serializeFromDocument` — the `Document`-aware serializer, for djot,
Markdown and AsciiDoc — and `format.serializeConvertedAlloc`, which the
CLI's `convert` and the C ABI's `twig_document_serialize` now share,
takes it for a document a runtime row parsed. A compiled row's document
still crosses bare, as before: its labels and spelling are its own
parser's, and no conversion between compiled formats changes. A runtime
test holds the twin's conversion to the compiled row's canonical print.
