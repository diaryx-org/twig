---
title: A gesture over an AsciiDoc paragraph admonition takes its label into the new block
description: '`toggleBlockContainer` and `toggleCodeBlock` over the paragraph of `NOTE: An admonition.` rewrite the whole line, so the `NOTE:` label becomes text of a list item or a code block and the admonition is lost — a success reported over a document whose admonition is gone.'
author: adammharris
created: 2026-09-23
updated: 2026-10-20
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# A gesture over an AsciiDoc paragraph admonition takes its label into the new block

Found by the gesture check (`contract.gestures`), which lists it in
`known_findings` in `src/languages/harness.zig` until it is fixed.

## Repro

AsciiDoc, the source `NOTE: An admonition.\n`. Its tree is an admonition
container holding a paragraph whose text is `An admonition.` — the label is
the container's spelling, on the paragraph's own first line.

- `toggleBlockContainer(<the paragraph's span>, .bullet_list)` writes
  `* NOTE: An admonition.`: a list item whose text is `NOTE: An admonition.`.
  The same with `.ordered_list`.
- `toggleCodeBlock(<the paragraph's span>, "zig")` writes a fence around
  `NOTE: An admonition.`.

Both report success. The admonition is gone and its label is content.

## Why

Both gestures take the block's LINES, and a paragraph admonition is the one
container in twig's formats whose spelling shares its child's first line
without being a line prefix the line model states (`ContainerSpelling`): it
is neither a quote's `> ` nor a list marker, so nothing strips it and
nothing writes it back.

## Done when

The two gestures either keep the admonition — the list or the fence inside
it, which AsciiDoc spells only in the delimited form (`[NOTE]` over `====`) —
or refuse with `error.NotEditable` over a paragraph admonition. The first is
the better answer and a larger change; either closes this, and the entry
leaves `known_findings` in the same commit.

## Resolution

Done on 2026-10-20, by refusing. Both gestures now answer `NotEditable`
when a container above the covered blocks spells itself on the first
block's own first line (`label_on_first_line` in `src/ast/editor.rs`),
which in twig's formats is only AsciiDoc's paragraph admonition, and the
source is left as it was. The delimited form (`[NOTE]` over `====`) puts its
label on a line of its own and the gestures run inside it as before. The
entries left `KNOWN_FINDINGS` in `src/contract.rs`, and
`a_gesture_over_an_asciidoc_paragraph_admonition_is_refused_not_spelled_into_its_label`
in `src/ast/editor_test.rs` holds it. Keeping the admonition by rewriting it
to the delimited form, the better answer above, is still open to whoever
wants it.
