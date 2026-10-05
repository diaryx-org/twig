---
title: "`twig convert` drops a runtime language's reason for refusing a print"
description: "When a runtime language's print fails, `twig convert` reports only `LanguageFailed`, though `runtime.lastFailure` holds the language's message and `lang check` shows it."
author: adammharris
created: 2026-10-02
updated: 2026-10-05
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# `twig convert` drops a runtime language's reason for refusing a print

When a runtime language's print fails, `twig convert` reports only `LanguageFailed`, though `runtime.lastFailure` holds the language's message and `lang check` shows it.

## Done when

`twig convert -o <runtime row>` that the language refuses prints the
language's own message (`runtime.lastFailure`), as `lang check` does, and
a CLI test holds it.

## Resolution

Done on 2026-10-05, in `fix(cli): convert reports a runtime language's reason for refusing a print`.
`convertSource` reports a failed print through `printFailure`, which gives
`runtime.lastFailure` for a `LanguageFailed` — only a runtime row's
functions fail with it, and the registry records why before returning it —
and the error's name for anything else, as `parseFailure` already did for
a parse. Both print paths take it: the canonical print of a runtime row,
and a conversion into one. A CLI test registers a language that refuses
block quotes and holds both to its message.
