---
title: The workspace's views are not read, and its docs have three bad links
part_of: '[Tasks](/docs/tasks/tasks.md)'
status: open
author: adammharris
created: 2026-10-21
updated: 2026-10-21
description: '`prov check` reports six findings in twig: the three views in `.config/prov.yaml` use retired keys and are not read, so `prov views open-tasks` answers that there is no such view; two body links do not resolve; and the proposals index lists one proposal twice.'
---

# The workspace's views are not read, and its docs have three bad links

## Repro

```sh
prov check          # 6 finding(s), exit 1
prov views open-tasks
# prov: no view named `open-tasks` — this workspace declares none
```

[Tasks](/docs/tasks/tasks.md) points readers at `prov views open-tasks`,
which gives them that answer.

## The findings

- **Three views are not read.** `open-tasks`, `proposals` and `work` in
  `.config/prov.yaml` are written with `group`, `under` and a `where:`
  mapping, which prov has retired. prov skips them and says so. `prov check`
  prints the CEL spelling of each:

  ```yaml
  views:
    open-tasks:
      label: "Open tasks"
      where: "under('[[Tasks]]') && present(status) && !('done' in field('status') || 'dropped' in field('status'))"
      key: "status"
    proposals:
      label: "Proposals"
      where: "under('[[Proposals]]') && present(status)"
      key: "status"
    work:
      label: "All work"
      where: "present(status)"
      key: "status"
  ```

- **`docs/proposals/proposals.md` lists `fig-in-twig.md` twice** in its
  `contents`, so prov reads the second entry as a second parent.
- **`docs/AST-KINDS.md` line 49** links to `/#when-a-family-gets-nested`.
  With `path_style: root` that is the README's anchor, and the heading is in
  `AST-KINDS.md` itself (line 170). The link should be
  `#when-a-family-gets-nested`.
- **`docs/proposals/twig-native-language.md` line 23** links to
  `/proposals/twig-attributes.md`. No file by that name is in twig's history.
  Either the link means `docs/proposals/presentation-as-attributes.md` or a
  document in another workspace, which would be written `id:<name>/<id>`.
  Whoever wrote the proposal knows which.

## What is left

Five of the six are fixed: the views are written in CEL, `fig-in-twig.md`
is listed once, and the `AST-KINDS.md` anchor is local. `prov check` now
reports only the `twig-attributes.md` link, which stays open until its author
says what it meant. No file by that name is in any diaryx-org repository
either; plates' `docs/proposals/templating.md` notes the same gap.

thorn's `.config/prov.yaml` has the same three retired views. That belongs in
a thorn task.

## Done when

`prov check` in twig reports no findings, and `prov views open-tasks` lists
the open tasks.
