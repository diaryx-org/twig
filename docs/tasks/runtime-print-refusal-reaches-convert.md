---
title: "`twig convert` drops a runtime language's reason for refusing a print"
description: "When a runtime language's print fails, `twig convert` reports only `LanguageFailed`, though `runtime.lastFailure` holds the language's message and `lang check` shows it."
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# `twig convert` drops a runtime language's reason for refusing a print

When a runtime language's print fails, `twig convert` reports only `LanguageFailed`, though `runtime.lastFailure` holds the language's message and `lang check` shows it.

## Done when

`twig convert -o <runtime row>` that the language refuses prints the
language's own message (`runtime.lastFailure`), as `lang check` does, and
a CLI test holds it.
