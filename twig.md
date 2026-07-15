```figl
title = Twig
author = adammharris
created = 2026-07-08T22:39:41-07:00
updated = 2026-07-08T22:40:04-07:00
```

# Twig

[![CI](https://img.shields.io/github/actions/workflow/status/adammharris/twig/ci.yml?branch=main)](https://github.com/adammharris/twig/actions/workflows/ci.yml)
[![crates.io](https://img.shields.io/crates/v/twig-doc.svg)](https://crates.io/crates/twig-doc)
[![docs.rs](https://img.shields.io/docsrs/twig-doc)](https://docs.rs/twig-doc)
[![license](https://img.shields.io/crates/l/twig-doc.svg)](#license)

A sister project to [`fig`](https://github.com/adammharris/fig).
While `fig` parses configuration files like JSON, YAML, and TOML,
Twig parses **document** files, like HTML, Markdown, and Djot.

In this way, Twig is comparable to [Pandoc](https://pandoc.org),
but Twig has different design goals:

- In Twig, the goal isn't just to be a converter,
  but to expose the abstract syntax tree of a document,
  so that precise operations can be performed on it,
  similarly to how `fig` allows editing of config files.

- Twig doesn't plan to support citations or bibliographies,
  at least not directly.

- Twig intends to primarily support "round-trippable" formats,
  which excludes not-editable documents such as PDF.

# Status

The following languages are implemented:

- Djot — 100% conformant with the djot.js corpus: all 265 cases that define an HTML expectation pass. The 6 remaining cases assert against djot.js's internal AST-dump debug format (not HTML); their parser behaviours are covered directly by native AST unit tests instead.
- Markdown (fully CommonMark 0.31.2 conformant — 652/652 spec examples passing)
- HTML (generic-markup parser + serializer; forgiving document-oriented tree construction)

# License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
