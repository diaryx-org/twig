---
title: 'A runtime target reports every kind its fidelity probe did not reach as degraded'
description: '`twig convert --warn -o <runtime row>` warns on every `str`, because `doc`, `str`, `row`, `cell`, `caption` and `task_list_item` have no probe and default to degraded for a runtime target.'
author: adammharris
created: 2026-10-02
updated: 2026-10-05
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# A runtime target reports every kind its fidelity probe did not reach as degraded

`twig convert --warn -o <runtime row>` warns on every `str`, because `doc`, `str`, `row`, `cell`, `caption` and `task_list_item` have no probe and default to degraded for a runtime target.

## Done when

A kind the load-time probe cannot build is reported as unmeasured, or
measured some other way, rather than degraded; `--warn` into a faithful
runtime twin (`twig-quickjs`'s djot) prints nothing for a plain
paragraph.

## Resolution

Done on 2026-10-05, in `fix(diagnostics): a runtime target measures the kinds that ride along with their parent`,
by measuring them. The load-time probe gains a probe for each kind it
never built — `doc`, `str`, `row`, `cell`, `caption`, `task_list_item`,
and, found by the test below, `list_item`, `term`, `definition`,
`definition_list_item` and `soft_break` — each inside its parent's shape,
so a runtime target reports one only when the round trip loses it, and
its attributes from what came back. A test in `diagnostics.zig` holds
that every `Kind` tag has a measured probe, and the twin's runtime test
analyzes a paragraph, a captioned table and a task list into the twin
with no warning.
