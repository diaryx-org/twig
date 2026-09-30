---
title: A djot directive written with a bare attribute or a label does not read back as one
description: '`insert_directive` in djot writes a bare attribute as `{wide}` and a label as the fence''s body; the first reads back as a paragraph and the second as a container holding one, so a success is reported over a document with no directive of that shape.'
author: adammharris
created: 2026-09-30
updated: 2026-09-30
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# A djot directive written with a bare attribute or a label does not read back as one

Found by leaf, generalising its page break into an insert gesture for any
directive name. leaf now works around both halves: it writes a bare attribute
as `key=""`, and it refuses a non-empty label in djot before calling twig.

## Repro

Djot, an empty document, `insert_directive(0, "x-card", …)`:

- **A bare attribute.** With `attrs = [("wide", None)]`, twig writes `{wide}`
  on the line above the `::: x-card` fence. Djot's attribute syntax has no
  bare key (`{wide}` is not an attribute block), so the line is a paragraph
  and the fence under it is a container with no attributes. Markdown's
  `::x-card{wide}` reads the same attribute back as `wide` with an empty
  value, so the two formats disagree about the same call.
- **A label.** With `label = Some("Title")`, twig writes the label as the
  fence's body. That reads back as a container holding a paragraph, not as a
  leaf directive with a label, so the directive's name survives and its label
  becomes content.

Both calls return `Ok`.

## Done when

Each call either writes a document that reads back with the name,
attributes and label it was given, or refuses with `UnsupportedFormat` /
`InvalidArgument` before writing anything. The gesture check covers both.
Which of the two is right for a label is the open question: djot has no
leaf-directive label, so refusing it may be the honest answer.
