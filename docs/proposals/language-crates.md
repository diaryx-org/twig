---
title: 'Proposal: one crate per language'
part_of: '[Proposals](/docs/proposals/proposals.md)'
status: accepted
author: adammharris
created: 2026-10-15
updated: 2026-10-15
---

# One crate per language

## Status

`accepted` on 2026-10-15, and built on the branch that adds this file: the
crates below exist, `twig-doc` names no language, and the next release is the
major that carries it. It becomes `implemented` with that release's tag.

## The question

twig's languages lived in one crate, `twig-doc`, under `src/languages/`, and
the format layer dispatched over a closed `Format` enum: about two dozen
`match` arms in `format.rs`, a sample table in `contract.rs`, a builder
printer in `api/builder.rs`, a fidelity table per target in `diagnostics.rs`,
and Markdown's extensions in core's own types (`ParseConfig::markdown`,
`MarkdownExtensions`, `Editor::new_ext`). A program that read only Markdown
compiled all five languages; a language outside the tree could only come in
through the runtime contract, never as a peer of the compiled ones.

fig answered the same question in its 3.0 epoch and its Rust port (fig 7):
`fig-kit` holds what languages share, `fig-core` carries no language and its
registry starts empty, and every language is a crate on the kit that a
program registers. This proposal moves twig to the same shape, with one
difference fig does not have: `twig-doc` has **no features at all**, no
language behind a flag. A program depends on the language crates it wants.

## The shape

| Crate | What it holds | Depends on |
|---|---|---|
| `twig-kit` | The tree (`ast`), `Document`, spans, the spelling table (`Syntax`) and its JSON, the node table, the generic HTML printer and its presets, the HTML entity table, the fidelity types, and the `Language` trait | nothing |
| `twig-doc` (`twig`) | The editor and splicer, the registry, conversion, the contract, diagnostics, the runtime and helper carriers, the public API | `twig-kit` |
| `twig-markdown` | `markdown`, `commonmark`, `gfm` | `twig-kit`, `twig-html` |
| `twig-djot` | `djot` | `twig-kit` |
| `twig-html` | `html` (the parser; the printer is the kit's) | `twig-kit` |
| `twig-xml` | `xml`, `svg` | `twig-kit` |
| `twig-asciidoc` | `asciidoc` | `twig-kit` |
| `twig-rst` | The rST parser and its conformance harness; not a registered format yet, not published | `twig-kit` |

Each language crate has a default `twig` feature that depends on `twig-doc`
and adds `register()` and `format()` (and a function per dialect:
`twig_markdown::gfm()`, `twig_xml::svg()`). With `default-features = false`
the crate is the language alone, on the kit, for a program — or `twig-doc`'s
own tests — that registers its value (`twig::register(twig_markdown::Markdown)`).

## The contract

`twig_kit::Language` is what a compiled language hands core:

- **rows** — row 0 is the language, any further row a dialect of it, each
  with its name, aliases, extensions and, for twig's own crates, the
  `TWIG_FORMAT_*` code it has always had;
- **features** — named switches in bit order (Markdown's five extensions),
  each with what it requires;
- **parse**, **render_html**, **serialize** (canonical), **serialize_ast**,
  **serialize_document**, **serialize_built** — each told the row and the
  features in force;
- **syntax** — the table its gestures write, per row and features;
- **fidelity** — how a kind, a node and its attributes survive a conversion
  into it. A language that states no table is measured by core's probes, as
  a runtime language already was.

The node-table contract for languages in another process or runtime stays,
renamed to say what it is: `TableLanguage`, `register_table`.

## What breaks

This is the major release's break, and `docs/CHANGELOG.md` carries it.

- `Format` and `Target` are handles to registry rows, not enums:
  `Format::Markdown` is `twig_markdown::format()`, `Format::Gfm` is
  `twig_markdown::gfm()` or `Format::by_name("gfm")`. `RuntimeId` is gone;
  every format is a code. `Format::code()` and `Target::code()` return
  `u16`.
- `MarkdownExtensions`, `Document::parse_with`, `Document::parse_str_with`,
  `Editor::new_ext` and `Format::supports_with` are gone: features are a mask
  (`Format::feature_flags`, `Document::parse_with_flags`,
  `Editor::new_with_flags`, `Format::supports_flags`) or names
  (`parse_with_features`, `new_with_features`). `twig_markdown::Extensions`
  and `twig_markdown::language::mask_from_extensions` convert.
- `twig::languages` is gone: a language's modules are its crate's.
- `twig::Language` is the kit's compiled-language trait; the node-table
  trait is `TableLanguage`, registered with `register_table`.
- `format::ParseFailure` is a reason string; `ParseConfig` is a feature mask.
- `twig_meta::Resolved::markdown_extensions` is gone: `Resolved::features`
  names them.

What does not change: the C ABI (`twig-capi` registers every shipped language
under its `TWIG_FORMAT_*` code before its first entry point answers), the
CLI's every output, and the tree, spans and kind names. The CLI was held to
the previous release over 1,840 command lines — every output mode, all five
input languages, the help and the errors — and printed the same bytes.

## The tests

A crate's unit tests cannot depend on a crate that depends on it, so the
tests that read a real document moved to where the languages are visible:

- `twig-doc`'s unit tests take the language crates as dev-dependencies, by
  path, and register each crate's language value with the registry under
  test (`src/test_languages.rs`);
- the kit's checks that parse Markdown or Djot are integration tests,
  `crates/twig-kit/tests/with_languages.rs`;
- a language's tests that read another language take it as a
  dev-dependency (Markdown's serializer tests parse Djot).

## Publishing

Path-only dev-dependencies are dropped by `cargo publish`, so the order is
the dependency order: `twig-kit`, `twig-doc`, `twig-html`, `twig-markdown`,
`twig-djot`, `twig-xml`, `twig-asciidoc`, `twig-meta`, `twig-doc-cli`
(`release.yml`). `twig-meta` publishes now that fig 7 is on crates.io.

## What this is not

- A kit fig and twig share. The two kits are the same shape and different
  types; whether a document's node table and a config's could be one is the
  question [document as data](document-as-data.md) leads to, not this one.
- Runtime languages changed. They are rows of the same registry, numbered
  from `TWIG_FORMAT_RUNTIME_BASE` as before; a native language without a
  `TWIG_FORMAT_*` code is numbered from 2048.
