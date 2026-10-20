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

Done on 2026-10-20, by keeping the admonition. When a container above the
covered blocks spells itself on the first block's own first line
(`labelled_parent` in `src/ast/editor.rs`, which in twig's formats is only
AsciiDoc's paragraph admonition), both gestures rebuild that container with
the new block inside it and print it through the format's renderer
(`rewrap_labelled`), so `NOTE: An admonition.` becomes `[NOTE]` over `====`
holding `* An admonition.` or a `[source,zig]` listing. The admonition's
title and id come with it, a code block takes the paragraph's source as its
text, and a quote around the admonition keeps its prefix on every line. The
delimited form puts its label on a line of its own, and the gestures run
inside it as before. The entries left `KNOWN_FINDINGS` in `src/contract.rs`,
and `a_gesture_over_an_asciidoc_paragraph_admonition_keeps_it_in_the_delimited_form`
in `src/ast/editor_test.rs` holds it.
