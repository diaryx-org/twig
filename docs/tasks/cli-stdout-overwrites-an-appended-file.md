---
title: 'The CLI writes stdout from offset 0, so `>>` overwrites what the file held'
description: '`twig … >> out` replaces the start of `out` instead of appending, and two runs into one file overwrite each other: the stdout writer writes positionally.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# The CLI writes stdout from offset 0, so `>>` overwrites what the file held

`twig … >> out` replaces the start of `out` instead of appending, and two runs into one file overwrite each other: the stdout writer writes positionally.

## Repro

`echo old > f; twig convert a.dj >> f` leaves the converted text over the
start of `old` rather than after it. Seen while smoke-testing the runtime
CLI and again by `twig-quickjs`'s corpus run.

## Done when

The CLI's stdout writer streams (`writerStreaming`, as the helper pipes
already do) or honours the descriptor's offset, so `>>` appends and
pipes and terminals behave as before.
