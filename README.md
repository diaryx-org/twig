---
part_of: id:org/kv2bv2m
title: Twig
author: adammharris
created: 2026-07-08T22:39:41-07:00
updated: 2026-08-13T15:50:04-07:00
contents: ['[DESIGN](/docs/DESIGN.md)', '[AST-KINDS](/docs/AST-KINDS.md)', '[COOKBOOK](/docs/COOKBOOK.md)', '[CHANGELOG](/docs/CHANGELOG.md)', '[AGENTS](/docs/CONTRIBUTING.md)', '[RELEASING](/docs/RELEASING.md)', '[Proposals](/docs/proposals/proposals.md)', '[Tasks](/docs/tasks/tasks.md)', '[twig on diaryx.org](/www/index.md)', '[Audiences](/vocab/audiences.md)']
config: .config/prov.yaml
registry: registry.yaml
id: 9tz497d
---

# Twig

[![CI](https://img.shields.io/github/actions/workflow/status/diaryx-org/twig/ci.yml?branch=main)](https://github.com/diaryx-org/twig/actions/workflows/ci.yml)
[![crates.io](https://img.shields.io/crates/v/twig-doc.svg)](https://crates.io/crates/twig-doc)
[![docs.rs](https://img.shields.io/docsrs/twig-doc)](https://docs.rs/twig-doc)
[![license](https://img.shields.io/crates/l/twig-doc.svg)](#license)

A sister project to [`fig`](https://github.com/diaryx-org/fig).
While `fig` parses configuration files like JSON, YAML, and TOML,
Twig parses **document** files, like HTML, Markdown, and Djot.

In this way, Twig is comparable to [Pandoc](https://pandoc.org),
but Twig has different design goals:

- In Twig, the goal isn't just to be a converter,
  but to expose the abstract syntax tree of a document,
  so that precise operations can be performed on it,
  similarly to how `fig` allows editing of config files.

- Twig intends to primarily support "round-trippable" formats.
  This means no first-class support for for "presentation" formats,
  such as PDF. And no special handling for bibliographies/citations.

# Status

The following languages are implemented:

- Djot — 100% conformant with the djot.js corpus: all 265 cases that define an HTML expectation pass. The 6 remaining cases assert against djot.js's internal AST-dump debug format (not HTML); their parser behaviours are covered directly by native AST unit tests instead.
- Markdown (fully CommonMark 0.31.2 conformant — 652/652 spec examples passing), in three named dialects: `markdown` (twig's default, CommonMark plus the common extensions), `commonmark` (strict), and `gfm` (GitHub-Flavored, with its HTML conventions)
- HTML (generic-markup parser + serializer; forgiving document-oriented tree construction)
- XML (generic-markup parser + serializer, strict; every element's attribute region is recorded, so an element's attributes can be rewritten in place by node id — the one gesture a tree-shaped editor needs, and the one XML supports), with `svg` as a named dialect so a `.svg` file is recognised on sight
- AsciiDoc — every block and inline shape the official ASG schema (draft-01) enumerates, plus tables, footnotes, superscript and the other constructs the schema does not model yet; the vendored AsciiDoc TCK passes 13/13 and twig's own schema-validated corpus 137/137. Parses, renders, serializes (`-o asciidoc`) and authors.

# Crates

Twig is written in Rust, with no `-sys` crate and no native toolchain, and is
laid out as [fig](https://github.com/diaryx-org/fig) is: a kit, a core that
names no language, and one crate per language
([proposal](docs/proposals/language-crates.md)).

- [`crates/twig-kit`](crates/twig-kit) is `twig-kit`: what languages share
  (the tree, spans, the spelling table, the generic HTML printer and the
  `Language` trait). It depends on nothing.
- [`crates/twig`](crates/twig) is [`twig-doc`](crates/twig/README.md), the
  core (library `twig`): the editor, the registry, conversion and
  diagnostics. Its registry starts empty, and it has no language features.
- One crate per language, each on the kit alone, with a default `twig`
  feature that adds `register()` and `format()`:
  [`twig-markdown`](crates/twig-markdown) (`markdown`, `commonmark`, `gfm`),
  [`twig-djot`](crates/twig-djot), [`twig-html`](crates/twig-html),
  [`twig-xml`](crates/twig-xml) (`xml`, `svg`) and
  [`twig-asciidoc`](crates/twig-asciidoc). [`twig-rst`](crates/twig-rst) is a
  parser and its conformance harness, not yet a registered format.
- [`crates/twig-cli`](crates/twig-cli) is [`twig-doc-cli`](crates/twig-cli/README.md),
  the `twig` command-line tool (`cargo install twig-doc-cli`), with every
  language registered.
- [`crates/twig-capi`](crates/twig-capi) builds the C ABI declared in
  [`bindings/c/include/twig.h`](bindings/c/include/twig.h), with every
  language registered under its `TWIG_FORMAT_*` code.
- [`crates/twig-meta`](crates/twig-meta) reads and edits a document's
  frontmatter and endmatter through [fig](https://github.com/diaryx-org/fig)
  7, in place, with comments and fences kept, and reads the render settings a
  document names under its `twig` key ([proposal](docs/proposals/fig-in-twig.md)).

```
cargo build --release        # target/release/twig
cargo test --workspace
```

# License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](docs/LICENSE-APACHE))
- MIT license ([LICENSE-MIT](docs/LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
