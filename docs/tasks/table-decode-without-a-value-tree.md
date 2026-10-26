---
title: Read a node table without building a JSON value tree first
description: 'Every reparse through a runtime row decodes the language''s table with `std.json.parseFromSlice(std.json.Value, …)`, a map per row, before reading a field; that is three quarters of what a keystroke costs through the contract.'
author: adammharris
created: 2026-10-02
updated: 2026-10-24
status: in-progress
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Read a node table without building a JSON value tree first

## What is there now

`ast/table.zig`'s `decode` and `decodeBare` parse the whole table into a
`std.json.Value` — an `ObjectMap` for every row — and then `read` walks it.
A runtime row's every parse and an editor's every keystroke over one go
through it.

`zig build bench-edit -- <file.dj>` measures it against a djot twin whose
language parse is djot's own (`docs/proposals/runtime-languages.md`, step
6). On a 34 KB document a keystroke is 0.33 ms compiled and 2.36 ms through
the runtime row, of which the decode is 1.78 ms, against 0.38 ms for the
parse and 0.41 ms for writing the table out. The ratio holds at 8 KB and
at 135 KB, where a keystroke is 9.45 ms, more than half a frame.

## In Rust

The port read the table the same way: `json::parse` into a `json::Value`, an
owned `Vec` for every key, string and container, then `read` over that.
`cargo run --release -p twig-doc --example bench_edit -- <file.dj>`
(2026-10-24, an i5-8279U, documents cut from this repository's own docs, so
not the 34 KB document above) put a keystroke at 0.73 ms compiled and
4.19 ms through the runtime row, 5.8x, of which the decode was 2.30 ms
against 0.71 ms of parse and 1.03 ms of encode. At 135 KB: 2.64 ms against
16.17 ms, 6.1x, decode 9.63 ms.

`decode` and `decode_bare` now read the text where it lies.
`json::check_rows` checks it in one pass, refusing exactly what
`json::parse` refuses, and gathers as it goes the top object's members and
each row's as borrowed slices of the text. `read` then walks those lists,
and allocates only for what the `Document` keeps. `from_value` goes through
the same `read`, so the two cannot drift. `decode_in_place_agrees_with_the_parsed_value`
and `decode_in_place_agrees_on_damaged_tables` hold `decode` to the same
answer and the same `Problem` as `from_value(json::parse(…))`, and
`table.rs`'s and `runtime.rs`'s own tests pass unchanged. Same machine and
documents:

| document | compiled key | runtime key | ratio | decode |
|---|---|---|---|---|
| 34 KB, before | 0.73 ms | 4.19 ms | 5.8x | 2.30 ms |
| 34 KB, after | 0.73 ms | 3.04 ms | 4.2x | 1.30 ms |
| 135 KB, before | 2.64 ms | 16.17 ms | 6.1x | 9.63 ms |
| 135 KB, after | 2.69 ms | 11.36 ms | 4.2x | 4.90 ms |

## What is left

3x is not reachable by the decode alone. On the 34 KB document 3x the
compiled keystroke is 2.2 ms, and the parse and encode already take 1.7 ms
of it, which leaves about 0.5 ms to decode a 220 KB table. Of the 1.30 ms
the decode now takes, building the `Document` from rows already in hand
costs 0.44 ms (timed through `from_value` over a parsed `Value`), and one
checking pass over the text about 0.4 ms. Reaching 3x needs a cheaper
encode too, or a table that is smaller than 6.5x its source. Which of those
to do, or whether to settle for 4x, is a decision this task does not make.

## Done when

`decode` reads the table straight into the `Builder` (done, above), refusing
what it refuses today with the same `Problem` paths, so `table.rs`'s and
`runtime.rs`'s tests pass unchanged; and `bench_edit` on the 34 KB document
puts the runtime row's keystroke within 3x of the compiled row's, with the
new numbers recorded under step 6 of the proposal.
