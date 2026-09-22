---
title: Tasks
description: Deferred work with a done state — a bug is a task with a repro
author: adammharris
created: 2026-09-15
updated: 2026-09-22
part_of: '[Twig](/README.md)'
contents:
- '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# Tasks

Work that is committed to and deferred, one file each. A task has a done
state; a bug is a task with a repro. What is open is a view
(`prov views open-tasks`, `dx tasks`); the `contents` above lists what is
live, and a closed task moves to [Closed tasks](/docs/tasks/closed/closed.md)
(`dx shelve`), which is part of this index, so every task is still reached
from here.

`status` is `open`, `in-progress`, `done`, or `dropped`
([vocabulary](/vocab/task-statuses.yaml)); `prov check` refuses anything
else. Closing is an edit, not a delete: set `status: done` and name the
commit or release that resolved it.

What this is not:

- An argument for a change that may lose. That is a
  [proposal](/docs/proposals/proposals.md).
- A commitment to consumers, which is the [CHANGELOG](/docs/CHANGELOG.md)'s
  unreleased region or a `Behavioural-change:` trailer.

The first five were filed together on 2026-09-15, from reading fig's 3.0
epoch against twig: fig retired its per-format hooks for data the parser
already knew, added a `render` verb for fragments, wrote its parse result
down as a node table with declared side columns, and carried that contract
over a wire. Twig arrived at fig's 2.x shape — one registry, `Syntax` as
data, an editor that names no format — from the start, so these are the 3.0
moves, in the order fig found they had to land.
