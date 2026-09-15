---
title: Name Markdown's configurations as dialects
description: Markdown's variants are a `ParseOptions` struct in Zig and a flag bitmask through the C ABI; `syntaxFor(config)` answers the editor's question well, but nothing on the CLI or the wire can say "commonmark" or "gfm" and mean one row
author: adammharris
created: 2026-09-15
updated: 2026-09-15
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Name Markdown's configurations as dialects

**Where.** `Markdown.ParseOptions` (`src/languages/markdown/options.zig`)
is a struct of toggles with a `.commonmark` preset; `src/format.zig`'s
`ParseConfig` threads it through the registry adapters, and `Entry.syntaxFor`
picks the `Syntax` table that matches, so an editor over a strict-CommonMark
document cannot mint `~~x~~`. Through the C ABI the same facts travel as
`TWIG_MD_*` flag bits on `twig_parse_ext` / `twig_editor_create_ext`.

That is a good answer to the editor's question and no answer to the CLI's:
`-i markdown` is one format however it was configured, and nothing can name
"the GFM row" or "the diaryx row" as a thing.

Fig's registry has dialects as rows — `json`, `jsonc`, `json5` share a
parser and differ in what they accept — each with a name, extensions, a
sniff rank, and a permanent ABI value, and `--lang` and `lang check` reach
every dialect of a language.

**Done when** the bundles that matter — at least `commonmark`, `gfm`, and the
default — have names that `parseFormatName` accepts (`-i gfm`), that
`ParsedDoc` records, and that the C ABI can take as a format integer beside
the flag bits, with the flags kept for the combinations that are not a named
dialect. The flag bits stay: a dialect is a name for a configuration, not a
replacement for one. Whether a dialect is a `Format` variant or a field on
one is the design question; `Target` should not grow with it.

Filed because [runtime languages](/docs/tasks/runtime-languages.md) would
want to address a dialect by name from a `languages.figl`-style file;
worth doing on its own for `-i gfm`.
