---
title: Decide whether twig carries a runtime-language contract
description: Fig's 3.0 carries its format contract as a vtable in-process and a JSON helper protocol out-of-process, so a format can live outside the tree; twig's `ast_json` is already that node table minus the side columns, and the deferred twig-native language would be the first format to prototype as a script — but it is a proposal-sized decision, and the task is to write it
author: adammharris
created: 2026-09-15
updated: 2026-09-19
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Decide whether twig carries a runtime-language contract

**Done** — `docs(proposals): accept runtime languages, with the range
reserved and the carriers sequenced`, the commit that also sets this status.
[The proposal](/docs/proposals/runtime-languages.md) is `accepted`: twig
carries the contract two ways, in-process and over a helper wire, links no
engine, and crosses the contract with its compiled formats first. The three
questions below were answered from the code as it stands — the table is
`TwigFlatNode` plus two columns, the render half is three string functions
the harness already holds, and the process question splits by consumer, the
helper for the CLI and the in-process carrier for an editor. The one thing
cheaper now than later, `TWIG_FORMAT_RUNTIME_BASE`, landed alongside in
`add(c-abi): reserve the runtime format range`. The three tasks sequenced
ahead of it were already done when the decision was taken; the build is the
proposal's own sequence.

**What fig did.** Fig 3.0 ("Texas Everbearing") restated its `Language`
contract as values: a flat node table with spans and declared side columns,
a `syntax` record, and fragment renderers. Core carries that contract two
ways — a struct of function pointers in-process, and a JSON protocol to a
helper process — and links no engine. The engines are their own repositories
(`fig-lua`, `fig-quickjs`), a `languages.figl` names them, and every entry
point that takes a format takes a runtime one. The compiled formats were made
to pass through the same contract *before* the first outside format landed,
so the contract was crossed before it was tagged.

**Where twig stands.** `src/ast/json.zig` already emits kind, span, payload,
attrs and children per node — a node table on the wire, minus the columns
[side-tables-as-document-columns](/docs/tasks/side-tables-as-document-columns.md)
names. The editor names no format and has no hooks to retire. The C ABI
addresses formats by a frozen integer. The prebuilt-archive bindings are the
same shape as fig's, so a `twig-quickjs` over the Rust crate would be built
the way `fig-quickjs` was.

**Why it might fit.** The deferred
[twig-native language](/docs/proposals/twig-native-language.md) proposal is
the natural first runtime format: prototype the surface syntax as a script,
iterate it against [the harness](/docs/tasks/per-format-harness.md), and
compile it into `src/languages/` only once it settles — fig's "same format
three times" pattern in the other direction. rST is "not a parser yet";
Org, Typst, Textile and every wiki dialect are the tail.

**Why it might not.** Document formats are fewer than config formats, and
each is larger. A document parser's inline grammar is where the work is, and
the wire pays a process round-trip per parse — fig measured ~6 ms per
command. Whether a wiki dialect is worth a helper process, and whether the
`render` half (a runtime format spelling a heading) is tractable over a wire
at document granularity, are open questions. Also: twig does not depend on
fig, and a `languages.figl` would be the first fig-format file in the repo.

**Done when** `docs/proposals/runtime-languages.md` exists and carries a
status other than `draft` — `accepted`, `deferred`, or `rejected` — with the
three tasks above sequenced ahead of it if accepted. This task is the
decision, not the build; the build, if it comes, is its own tasks.
