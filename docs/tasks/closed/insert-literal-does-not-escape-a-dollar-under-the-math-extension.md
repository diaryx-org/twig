---
title: insert_literal does not escape a dollar under the math extension
description: 'With `MarkdownExtensions.math` on, `$…$` opens inline math and `$$…$$` display math, but `insert_literal` leaves a typed `$` as it is — so a WYSIWYG surface that escapes every byte the format reads as markup still mints a formula when the author types one.'
author: adammharris
created: 2026-09-19
updated: 2026-09-22
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# insert_literal does not escape a dollar under the math extension

## Resolution

Done on 2026-09-22, in the commit `fix(markdown): a literal typed under the
math extension escapes its dollars`. `math` is now a fifth axis of the key
that picks Markdown's syntax table, and the tables with it on add `$` to
`text_escapes` — and to `link_text_escapes`, since a destination shown as a
link's text reparses the same way. Every `$` is escaped rather than only one
that would open a formula, as every `*` is: the alphabet is per byte, and
`\$` reparses as `$` whether or not it would have opened anything. A document
parsed without the extension keeps its table, and a bare `$`.

`insert_literal`'s contract is that every byte the format reads as markup is
escaped the format's way, so a run inserted through it reparses as exactly
the text typed. That holds for `*`, `` ` ``, `[`, `<` and the block markers.
It does not hold for `$` once the `math` extension is on: leaf now parses
every Markdown document with it (`leaf-core`'s `parse_extensions`, from
0.4.0), and an author typing `$x$` in leaf's `MarkupMode::None` — the mode
whose whole promise is that typed syntax stays literal — gets an
`inline_math` node.

Found writing leaf's test for exactly that promise
(`a_dollar_typed_in_shortcuts_authors_math` in `leaf-core/src/doc.rs`
carries the note). Leaf does not work around it: the escaping is positional
and per-format, and the docs on `insert_literal` say it is not the caller's
to reproduce.

**Repro.**

```rust
let exts = MarkdownExtensions { math: true, ..Default::default() };
let mut ed = Editor::new_ext(b"a \n", Format::Markdown, exts)?;
ed.insert_literal(2, "$x$ and $$y$$")?;
assert_eq!(ed.source_str()?, "a \\$x\\$ and \\$\\$y\\$\\$\n"); // is "a $x$ and $$y$$\n"
```

djot needs nothing: its math is `$` followed by a verbatim span, and the
backtick is already escaped, so `$\`x\`` never opens one.

**Done when** `insert_literal` escapes a `$` that would open inline or
display math under the `math` extension — and only then; a document parsed
without the extension keeps a bare `$` — and the run reparses as the text
typed.
