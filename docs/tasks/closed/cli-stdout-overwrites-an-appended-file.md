---
title: 'The CLI writes stdout from offset 0, so `>>` overwrites what the file held'
description: '`twig … >> out` replaces the start of `out` instead of appending, and two runs into one file overwrite each other: the stdout writer writes positionally.'
author: adammharris
created: 2026-10-02
updated: 2026-10-19
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
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

## Resolution

Done on 2026-10-19. The Rust rewrite fixed it: the CLI writes through
`std::io::stdout()`, which streams through the descriptor it inherits, so
`>>` appends. `echo old > f; twig convert a.dj >> f` run twice leaves `old`
followed by both conversions. `crates/twig-cli/tests/stdout_append.rs` holds
it: it runs `twig convert` twice with stdout opened for appending and checks
that the file keeps what it held.
