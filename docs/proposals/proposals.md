---
title: Proposals
description: Arguments for a change to twig, one file each — a case that may lose
created: 2026-09-09
updated: 2026-09-20
part_of: '[Twig](/README.md)'
contents:
- '[A twig-native document markup language](twig-native-language.md)'
- '[Editable HTML block elements](editable-html-block-elements.md)'
- '[Proposal: presentation as attributes](presentation-as-attributes.md)'
- '[Proposal: hard line breaks inside table cells](in-cell-line-breaks.md)'
- '[Proposal: format-correct literal text insertion](literal-text-insertion.md)'
- '[Proposal: runtime languages](runtime-languages.md)'
- '[Proposal: the tree gestures a canvas over an SVG needs](tree-gestures-for-a-canvas.md)'
---
# Proposals

A document lands here when it argues for a change rather than describing what
twig already does. It is the place an idea is discussed *before* it is settled
and the record of the argument *after*, so a proposal that lost is still worth
keeping — the reasoning is the value, and the outcome is part of it.

Each carries `status` in its frontmatter — `draft`, `accepted`, `implemented`,
`deferred`, `rejected` — which `dx tasks` reads. The list above holds every
proposal, resolved or not: the index is the spine, and what is unresolved is a
view of it (`dx tasks`); `accepted` and `deferred` are decisions made and not
yet built, and count as unresolved. Closing one is an edit
that names the release or commit that resolved it, with the outcome in a
**Status** section at the top and the body left as argued.

What this is not:

- A commitment to consumers, which is the [CHANGELOG](../CHANGELOG.md)'s
  unreleased region or a `Behavioural-change:` trailer on the commit that
  causes it.
- A description of what shipped, which belongs in the guides and
  [AST-KINDS](../AST-KINDS.md) — never here.
