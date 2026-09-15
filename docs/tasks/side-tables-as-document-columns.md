---
title: References and footnotes become `Document` columns, so `ParsedDoc` can stop being a union
description: Djot's and Markdown's `references`/`auto_references`/`footnotes` maps are the last per-format side tables; they are why `ParsedDoc` is a union, why `parseToAst` discards fidelity for the splicer, and why `serializeCanonical` sits on the input row
author: adammharris
created: 2026-09-15
updated: 2026-09-15
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# References and footnotes become `Document` columns, so `ParsedDoc` can stop being a union

**Where.** `Djot.Document` (`src/languages/djot/djot.zig`) carries
`references`, `auto_references` and `footnotes` — label → node id — beside
the position tables it shares with `src/document.zig`. Markdown's `Document`
is the same shape. Every other side table a language once kept to itself
(`node_marker_spans`, `node_spelling`, `attrs_spans`) has already moved onto
the shared `Document` as an id-indexed column; these three maps are what is
left.

**Why it matters.** The cost is visible in `src/format.zig`:

- `ParsedDoc` is a `union(Format)` *because* two variants carry maps the
  shared `Document` does not, so every consumer holds a tagged union to reach
  one `AST`.
- `parseToAst` "discards any `Document` side tables" so the `Splicer` can
  reparse; an edited document is re-read from bytes to get its fidelity back.
- `serializeCanonical` stays on the input row, apart from
  `TargetEntry.serializeFromAst`, only because it needs the variant's maps.

Fig's derived-regions and runtime-languages work is the argument in full:
every fact a parser keeps to itself is one the engine — or a wire — will
eventually need, so it is named once as a column of the shared table. Twig
has done this three times already; this is the fourth and last.

**Done when** the label tables are columns of `src/document.zig` (or one
`labels` table keyed by kind), djot's and Markdown's parsers fill them the
way they fill `node_marker_spans`, `ParsedDoc` is one `Document` or a thin
wrapper over one, and the two serializers on `Entry`/`TargetEntry` either
merge or the comment explaining why they cannot no longer cites the maps.
No C ABI change is expected; `twig_document_ast_json` output is unchanged.

Sequenced first: [the harness](/docs/tasks/per-format-harness.md) wants a
single `Document` to round-trip, and
[runtime languages](/docs/tasks/runtime-languages.md) needs the node table
to have a shape that can be written down.
