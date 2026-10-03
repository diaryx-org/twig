---
title: "The Rust crate cannot write a document's node table, or read its list spelling"
description: 'A Rust twin test cannot compare tables the way `twig lang table` and `lang check --against` do: the crate exposes no node-table encoder and no `spelling` column.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# The Rust crate cannot write a document's node table, or read its list spelling

A Rust twin test cannot compare tables the way `twig lang table` and `lang check --against` do: the crate exposes no node-table encoder and no `spelling` column.

## Done when

`Document::node_table()` (over a `twig_document_node_table` in the C ABI)
returns the JSON `lang table` prints, `spelling` included, and
`twig-quickjs`'s `tests/twins.rs` can compare whole tables with it.
