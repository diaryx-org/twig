---
title: Markdown's extensions as named features, the way a runtime language declares them
description: 'A runtime language now declares features and sets, and a caller turns a feature on by name. Compiled Markdown still spells the same idea as `ParseConfig.markdown` and the `TWIG_MD_*` bitmask, so a host asks two different questions of two kinds of row for one concept.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# Markdown's extensions as named features, the way a runtime language declares them

## What is there now

A runtime language declares *features* — switches its parser reads, each
optionally requiring others — and *sets*, each a name for a list of them
registered as a row (`docs/proposals/runtime-languages.md`, Status,
2026-10-02). A caller turns one on by name: `twig_format_feature_bit` in C,
`Format::feature_flags` and `Document::parse_with_features` in Rust.

Compiled Markdown has the same shape and spells it otherwise. Its
extensions are `ParseOptions` fields; the opt-in five cross as
`ParseConfig.markdown` and the `TWIG_MD_*` bitmask; `commonmark` and `gfm`
are its sets, as rows; `highlight_colors` requires `highlight` by a rule in
the CLI and a sentence in the header. The flags argument of `twig_parse_ext`
already carries either, by which kind of row it meets.

So a host offering a "math" toggle asks `TWIG_MD_MATH` of a Markdown row
and `twig_format_feature_bit(code, "math")` of a runtime one.

## Done when

- `twig_format_feature_bit` answers for a compiled Markdown row with the
  `TWIG_MD_*` bit of each opt-in extension, by the name its CLI flag uses
  (`math`, `directives`, `html_elements`, `highlight`, `highlight_colors`),
  and `NOT_FOUND` for the rest; the bits stay what they are, so no caller's
  flags change meaning.
- `highlight_colors` requiring `highlight` is stated where the runtime
  model states a requirement, and applied wherever the flags are read
  rather than only on the command line.
- The Rust `Format::feature_flags` and `Document::parse_with_features` work
  for `Format::Markdown`, `Gfm` and `Commonmark`, and `MarkdownExtensions`
  is documented as the typed spelling of the same flags.
- `twig lang list` shows Markdown's features as it shows a runtime
  language's.

## Done

In `add(format): Markdown's extensions are features, and the CLI turns
features on`. `twig.format.features` is the one list for both kinds of
row; a C caller's `TWIG_MD_HIGHLIGHT_COLORS` now brings
`TWIG_MD_HIGHLIGHT` with it, which is the behavioural change. The typed
`Markdown.ParseOptions.Extensions` in Zig is unchanged, and colours stay
inert without a highlight there, since it is the parser's own options.
