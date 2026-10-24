---
title: "The Rust crate cannot write a document's node table, or read its list spelling"
description: 'A Rust twin test cannot compare tables the way `twig lang table` and `lang check --against` do: the crate exposes no node-table encoder and no `spelling` column.'
author: adammharris
created: 2026-10-02
updated: 2026-10-23
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# The Rust crate cannot write a document's node table, or read its list spelling

A Rust twin test cannot compare tables the way `twig lang table` and `lang check --against` do: the crate exposes no node-table encoder and no `spelling` column.

## Done when

`Document::node_table()` (over a `twig_document_node_table` in the C ABI)
returns the JSON `lang table` prints, `spelling` included, and
`twig-quickjs`'s `tests/twins.rs` can compare whole tables with it.

## Resolution

Done on 2026-10-23. Twig's engine is Rust now, so the encoder `twig lang
table` prints through, `twig::ast::table::encode`, was already in the crate;
nothing reached it from a parsed `Document`. `Document::node_table()` returns
that encoding with `lang table`'s options, pretty and with positions, so the
`spelling` column is in it, and `twig_document_node_table` returns the same
bytes over the C ABI. `node_table_is_what_lang_table_prints_spelling_included`
in `crates/twig/tests/binding.rs` pins a bullet list's table byte for byte
against `twig lang table`'s, and `node_table_is_what_lang_table_prints` in
`crates/twig-capi/src/tests.rs` holds the C ABI to it. Moving
`twig-quickjs`'s `tests/twins.rs` onto it is that repository's change.
