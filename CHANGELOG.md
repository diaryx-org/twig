---
part_of: '[Twig](/twig.md)'
---
# Twig — changelog

One entry per released version, newest first, plus an `Unreleased` section for
work that has landed on `main` and not yet been tagged.

Release notes used to live only in the annotated tag message
(`git tag -n20`). Those are kept, but a one-line summary cannot carry the
section this file exists for.

## Behavioural changes are their own section

Every entry has an **Added** list and, when it applies, a **Behavioural
changes** list. A behavioural change is one that alters *what an existing call
returns* without altering any type, signature, or ABI code — the class of
change that compiles clean against the previous version and fails at runtime.

The section is mandatory rather than a courtesy, because nothing else catches
this class for Twig's consumers. `TwigFlatNode.kind` is a `const char *` and
the Rust binding surfaces it as a `String`, so a renamed kind is not a compile
error in any language that binds Twig — it is a test failure, or a silently
wrong render, in whatever consumes the name. The same holds for a span whose
extent changes, a node that moves to a different parent, and a field that
starts reporting `NONE` where it used to report a value.

The rule for whether something belongs here: **if a caller who upgrades
without editing a line of their own code would observe a difference, it goes in
this section** — even when the change is a bug fix, and even when the previous
behaviour was plainly wrong.

## Unreleased

Nothing yet.

## 2.9.0 — editor gestures

### Added

- Seven caret gestures, each driven by `Syntax` spelling data rather than a
  format switch, and wired through the C ABI and both Rust crates:
  `insertThematicBreak`, `toggleCodeBlock`, `setCodeLanguage`, `toggleTaskItem`,
  `setTaskChecked`, `toggleTaskChecked`, `insertFootnote`.
  `toggleTaskItem` / `setTaskChecked` / `toggleTaskChecked` are what a rendered
  checkbox needs to become a clickable one.
- `Syntax` grows `thematic_break`, `code_fence`, `task_marker` and `footnote`.
- Two error codes, `InvalidLanguage` and `InvalidLabel`, both mapping to
  `TWIG_STATUS_INVALID_ARGUMENT`.

ABI additions only, so `TWIG_ABI_VERSION` stays at 4.

### Behavioural changes

- None.

### Fixed

- `twig.h` documented `TWIG_STATUS_INVALID_DESTINATION`, which has never been
  in the enum. `insert_link` / `insert_image` return
  `TWIG_STATUS_INVALID_ARGUMENT` in that position.

## 2.8.0 — AST slimming, AsciiDoc and rST parsers, the diagnostic layer

### Added

- An AsciiDoc parser covering a slice of the language — header, paragraphs,
  sections, lists, delimited blocks, and the inline spans — reachable as
  `TWIG_FORMAT_ASCIIDOC` (5). It parses and renders; it does not serialize.
- A reStructuredText parser (bullet, enumerated, definition, field and option
  lists; line blocks; tables with a column axis; the citation and substitution
  namespaces; Tier A parse diagnostics). Not yet registered as an input format
  — there is no `Format.rst`, so it is not reachable from the CLI or the C ABI.
- `src/diagnostics.zig`: a read-only pass reporting what serializing a given
  AST to a given target would silently lose. Zig-library only in this release.
- The document tree read surface on the C ABI, for parse-only consumers:
  `twig_document_nodes` / `_children` / `_subtree` / `_node_at` / `_nodes_at`,
  and `twig_editor_document` to borrow an editor's live tree.
- Document span accessors, and recorded source spans for attribute blocks.
- Table cell spanning (`colspan` / `rowspan`), and a table column axis
  (`TWIG_KIND_COLUMN`).
- List spelling (bullet character, ordered delimiter) recorded per node in
  `Document.node_spelling`.

### Behavioural changes

- **The four generic container kinds collapsed into one.** `div`, `span`,
  `directive` and `element` became a single `container` kind carrying
  `{name, form, argument}`. The break is on the **read path only**:
  `TwigFlatNode.kind` and `-o ast` JSON now report `"container"` everywhere
  they previously reported one of the four names. Every input code still
  works — `TWIG_KIND_DIV` / `TWIG_KIND_SPAN` build the anonymous container, and
  `twig_builder_add_directive` / `_add_element` construct the trees they always
  did — and struct layouts are unchanged, so `TWIG_ABI_VERSION` stays at 4.

  Selectors accept `container`, `element` and `directive` as names for the one
  kind, so existing selector strings keep matching.

- **Node spans moved out of the AST** into `Document`'s id-indexed side tables.
  This is a Zig API change only; the C ABI still exposes spans on its node
  structs, filled from the side tables.

## 2.7.2

Maintenance release.

## 2.7.1

### Added

- WASI support.

## 2.7.0 — Djot tables and raw content survive serialization
