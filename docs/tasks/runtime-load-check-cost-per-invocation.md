---
title: 'Every CLI invocation that loads an authoring helper re-runs the whole gesture check'
description: "Registering `twig-quickjs`'s djot twin at the author tier takes about 2 s in-process and 4 s per `twig` command over the wire, against about 40 ms for read and write: the load check runs every gesture under every feature combination each time."
author: adammharris
created: 2026-10-02
updated: 2026-10-05
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Every CLI invocation that loads an authoring helper re-runs the whole gesture check

Registering `twig-quickjs`'s djot twin at the author tier takes about 2 s in-process and 4 s per `twig` command over the wire, against about 40 ms for read and write: the load check runs every gesture under every feature combination each time.

## What is there now

`runtime.register` is the validation moment
(`docs/proposals/runtime-languages.md`, "Load is the validation moment"),
and the CLI registers every helper it spawns, so `twig convert` over an
authoring helper pays `lang check`'s full price on every run.

## Done when

An invocation that does not author (convert, query, identify) registers
without running the gestures it will not use, or the result of a passed
check is cached against the helper's description and samples, so that
loading `twig-quickjs`'s djot twin for a `twig convert` costs what a
read/write helper does; `lang check` still runs everything. The choice
and its numbers go in the proposal's Status.

## Resolution

Done on 2026-10-05, in `fix(cli): a helper is registered at the author tier only by lang check and lang list`,
on the first of the two choices. No CLI command authors — the edit
commands splice bytes and never write through a `Syntax` — so the CLI
registers a helper with its `author` cap, its `syntax` and its features'
patches set aside, and the load check runs what a read/write language's
does. No unchecked table is bound, because no table is bound at all.
`lang check` and `lang list`, which report what a language authors,
register it whole and run everything. Caching a passed check was not
needed: nothing in a single invocation would have read the cache's
answer.

`twig convert -i js-djot -o djot tests/documents/crlf.dj` through
`twig-quickjs`'s release build (ReleaseFast twig, Linux x86-64): 5.5–5.9 s
before, 0.13–0.14 s after; `lang check js-djot` is unchanged at 5.5 s.
