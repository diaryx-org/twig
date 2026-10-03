---
title: 'Every CLI invocation that loads an authoring helper re-runs the whole gesture check'
description: "Registering `twig-quickjs`'s djot twin at the author tier takes about 2 s in-process and 4 s per `twig` command over the wire, against about 40 ms for read and write: the load check runs every gesture under every feature combination each time."
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
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
