---
title: djot writes a reference definition's attributes where the reparse then fails to read the definition
description: '`[label]: dest{#id .c}` is what the djot serializer prints for a `reference` carrying attributes, and djot''s parser does not read the line back as a reference definition at all — so a definition that round-trips bare fails to round-trip attributed.'
author: adammharris
created: 2026-09-18
updated: 2026-09-18
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# djot writes a reference definition's attributes where the reparse then fails to read the definition

**Status: done** on 2026-09-18, in `fix(djot): a reference definition's
attributes are written on the line before it`. The probe records
`.faithful` for `(.djot, .reference)`.

Found by the attribute probe in `diagnostics.zig` (`1bc22e1`), which
records the answer as `attrsFidelity(.djot, .reference) == .degraded` and
notes that the definition itself does not come back. The kind table still
calls a bare `reference` faithful, which it is.

**Repro.** Build a `reference` node (`label`, `destination`) with
`class=x` on it and serialize to djot:

```
[label]: /dest{.x}
```

Reparse: no `reference` node. djot's own spelling for an attributed
reference definition puts the block on the line before —
`{.x}\n[label]: /dest` — as for any block.

**Done when** the definition's attributes are written on the line before
it, the attribute probe records `.faithful` for `(.djot, .reference)`, and
the change carries a `Behavioural-change:` trailer.
