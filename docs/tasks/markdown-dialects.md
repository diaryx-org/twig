---
title: Name Markdown's configurations as dialects
description: Markdown's variants are a `ParseOptions` struct in Zig and a flag bitmask through the C ABI; `syntaxFor(config)` answers the editor's question well, but nothing on the CLI or the wire can say "commonmark" or "gfm" and mean one row
author: adammharris
created: 2026-09-15
updated: 2026-09-15
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Name Markdown's configurations as dialects

## Resolution

Completed in the commit `feat(format): Markdown's dialects are Format rows,
as json/jsonc/json5 are in fig`, which also sets this status. The answer to
the design question below is the `Format` variant, fig's shape: `commonmark`
and `gfm` are registry rows beside `markdown`, each a `MarkdownDialect`
instantiation over the one parser under its preset, and `Entry.dialect_of`
says whose they are. `Target` did not grow — `targetFor(.gfm)` is `.markdown`,
and `writesOwnSyntax` is the round-trip question both `-o canonical` and
`twig_document_serialize` now ask, so a GFM document serialized as Markdown
keeps its spelling.

- `parseFormatName` accepts `gfm` and `commonmark`; `-i gfm` works, and the
  CLI's `--gfm`/`--commonmark` are now spellings of `-i` rather than
  rewrites of the parse options, so `--math --gfm` composes in either order.
  `identify` reports the dialect; the supported-formats list says which
  language each dialect belongs to.
- `ParsedDoc.format` records the row, and the HTML render reads its
  conventions from there.
- The C ABI takes `TWIG_FORMAT_COMMONMARK` (6) and `TWIG_FORMAT_GFM` (7)
  everywhere a format code goes; on the write side both mean Markdown. The
  `TWIG_MD_*` flag bits stay and lay over the named dialect. The Rust crate
  has `Format::Commonmark`, `Format::Gfm` and `Format::dialect_of`.
- `ParseConfig.markdown` is now `Markdown.ParseOptions.Extensions` — the
  five opt-in flags — rather than the whole `ParseOptions`. The preset is
  the row's, so no caller states the dialect twice, and the Zig-side
  `ParseConfig{ .markdown = .commonmark }` spelling is gone: that is
  `Format.commonmark`.
- Each dialect row declares its own harness samples in its own grammar, so
  a GFM table and a strikethrough round-trip under the GFM row and the
  CommonMark row is checked without either.

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
