---
title: Read a node table without building a JSON value tree first
description: 'Every reparse through a runtime row decodes the language''s table with `std.json.parseFromSlice(std.json.Value, …)`, a map per row, before reading a field; that is three quarters of what a keystroke costs through the contract.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
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

## Done when

`decode` reads the table with `std.json.Scanner` (or a reader of the same
cost) straight into the `AST.Builder`, refusing what it refuses today with
the same `Problem` paths, so `table.zig`'s and `runtime.zig`'s tests pass
unchanged; and `zig build bench-edit` on the 34 KB document puts the
runtime row's keystroke within 3x of the compiled row's, with the new
numbers recorded under step 6 of the proposal.
