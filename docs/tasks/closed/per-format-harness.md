---
title: A per-format harness states what the engine assumes of every format
description: The registry's tests check the tables are coherent; nothing checks, once and over every format, that a declared sample parses, serializes, and reparses to an equal tree, that an `Editor` constructs over it, and that a no-op splice is the identity
author: adammharris
created: 2026-09-15
updated: 2026-09-15
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# A per-format harness states what the engine assumes of every format

## Resolution

Completed in the commit `fix(languages): enforce per-format engine contracts`.
Every registry row declares samples in its language module; the shared harness
checks parsing, canonical `AST.eql` round trips, editor no-op splices, and
Document column bounds and ownership. Missing samples fail the test.

The marker criterion below predates heading, quote, and AsciiDoc admonition
markers; the harness checks those current supported kinds as well as list items.
HTML samples include canonical block whitespace, which its parser preserves.
The samples also caught and now guard Djot's borrowed-source lifetime without a
final newline, duplicate serialized automatic references, and paragraph attrs
being serialized as inline attrs.

**Where.** `src/format.zig`'s tests walk `registry` to check the *tables*:
every `Syntax` is coherent, a config-varying row agrees with its default
table, every `Format` is a `Target`. Each language has its own tests and,
where a corpus is vendored, a conformance scorer (djot.js, CommonMark
0.31.2, the AsciiDoc TCK). What none of that states is the set of properties
the *engine* relies on every format having, which today lives in prose and
is checked by whichever language's tests happen to exercise it.

Fig's `src/languages/harness.zig` is the shape: a format opts in by
declaring `samples` — a few small documents in its own grammar — and one
file runs the engine's assumptions over every row.

**Done when** there is a `src/languages/harness.zig` (or a test block in
`format.zig`) that, for every `registry` row:

- parses each declared sample;
- where the row has `serializeCanonical`, serializes and reparses each
  sample and finds the trees equal under `AST.eql` — which `ast/compact.zig`
  exists to make sound;
- where the row's `syntax.authorable()`, constructs an `Editor` over each
  sample and checks a zero-length splice at offset 0 leaves the source
  byte-identical and the document parsed;
- checks the shared `Document` columns are well-formed: every span inside
  the source, `node_marker_spans` only on list items, `attrs_spans` only
  where the node has attrs.

A format with no samples declared is a test failure, not a skip, so a new
`registry` row cannot join without stating what it round-trips. The corpora
under each language's `testdata/` are deliberately not walked here; their
`conformance.zig` is the reader that knows each one's shape.

This is the precondition for
[fragment renderers](/docs/tasks/closed/fragment-renderers.md) — a renderer's
output has to reparse to the node it was asked for — and for any
[runtime twin](/docs/tasks/closed/runtime-languages.md) of a compiled format,
which is checked against the harness and not against prose.
