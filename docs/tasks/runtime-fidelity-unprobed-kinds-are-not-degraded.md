---
title: 'A runtime target reports every kind its fidelity probe did not reach as degraded'
description: '`twig convert --warn -o <runtime row>` warns on every `str`, because `doc`, `str`, `row`, `cell`, `caption` and `task_list_item` have no probe and default to degraded for a runtime target.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# A runtime target reports every kind its fidelity probe did not reach as degraded

`twig convert --warn -o <runtime row>` warns on every `str`, because `doc`, `str`, `row`, `cell`, `caption` and `task_list_item` have no probe and default to degraded for a runtime target.

## Done when

A kind the load-time probe cannot build is reported as unmeasured, or
measured some other way, rather than degraded; `--warn` into a faithful
runtime twin (`twig-quickjs`'s djot) prints nothing for a plain
paragraph.
