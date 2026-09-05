---
title: Twig
author: adammharris
created: 2026-07-08T22:39:41-07:00
updated: 2026-08-13T15:50:04-07:00
contents: ['[DESIGN](/docs/DESIGN.md)', '[AST-KINDS](/docs/AST-KINDS.md)', '[COOKBOOK](/docs/COOKBOOK.md)', '[CHANGELOG](/docs/CHANGELOG.md)', '[AGENTS](/docs/CONTRIBUTING.md)', '[RELEASING](/docs/RELEASING.md)']
config: .config/prov.yaml
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
- Markdown (fully CommonMark 0.31.2 conformant — 652/652 spec examples passing)
- HTML (generic-markup parser + serializer; forgiving document-oriented tree construction)
- AsciiDoc — every block and inline shape the official ASG schema (draft-01) enumerates, plus tables, footnotes, superscript and the other constructs the schema does not model yet; the vendored AsciiDoc TCK passes 13/13 and twig's own schema-validated corpus 137/137. Parses, renders, serializes (`-o asciidoc`) and authors.

# License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](docs/LICENSE-APACHE))
- MIT license ([LICENSE-MIT](docs/LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
