# Porting Twig from Zig to Rust — conventions

This crate (`crates/twig`, package `twig-doc`, lib `twig`) is a faithful,
pure-Rust port of the Zig implementation in `src/`. The Zig code stays in the
repository as the reference until the port is complete. **Behaviour must be
byte-identical**: the same parse trees (kinds, spans, content/marker spans,
spellings, attrs, labels), the same HTML, the same serializer output, the same
CLI output.

## The oracle

The Zig build is installed: `/home/user/twig/zig-out/bin/twig` (built from
`src/` at this commit). Use it to generate expected output:

    zig-out/bin/twig convert -i djot -o table file.dj      # flat node table (spans, spellings, labels)
    zig-out/bin/twig convert -i djot -o ast file.dj        # nested AST JSON
    zig-out/bin/twig convert -i djot file.dj               # HTML
    zig-out/bin/twig convert -i djot -o canonical file.dj  # round-trip serialize
    zig-out/bin/twig convert -i djot -o markdown file.dj   # cross-format serialize
    zig-out/bin/twig convert -i markdown --math -o table -   # stdin needs -i

Formats: `djot`, `markdown`, `commonmark`, `gfm`, `html`, `xml`, `svg`,
`asciidoc`. Markdown extension flags: `--directives --math --highlight
--highlight-colors` and `--feature <name>` for the rest (see
`src/languages/markdown/options.zig`).

The Rust side of that comparison is `twig::ast::table::encode(&doc,
Default::default())` (byte-identical to `-o table`) and
`twig::ast::json::encode(&doc)` (byte-identical to `-o ast`). Write
differential tests that run both over a corpus and compare bytes. The Zig unit
tests (`test "..." {}` blocks) are the specification too: port them as Rust
`#[test]`s alongside the code.

`zig build test` runs the Zig suite if you want to see an expectation execute.

## Shared core (already ported — read before you start)

- `src/span.rs` — `Span { start, end }`.
- `src/ast/mod.rs` — `Kind` (Zig's `Node.Kind` union), `Tag` (its bare tag),
  `Node`, `Ast`, `Attrs`/`KeyVal`, `InlineMark`, `TextLeafKind`,
  `MarkupLeafKind`, `Form`, `ListNumbering`, `Alignment`,
  `SmartPunctuationKind`, `Cell`, `Link`, `Container`, `KindRef`, and the
  classifiers `level()`, `content_model()`, `structural_children()`,
  `admits_child()`, `kind_name()`.
- `src/ast/builder.rs` — `Builder` (Zig's `AST.Builder`): `add_node`,
  `add_leaf`, `add_container`, `set_children`, `set_span`, `set_content_span`,
  `set_spelling`, `set_marker_span`, `set_attrs`, `set_attrs_span`,
  `graft_document`, `graft_subtree`, `finish`, `finish_document`.
- `src/ast/reader.rs` — `children`, `child_ids`, `table_rows`, `id_by_path`,
  `path_of`, `subtree_ids`, `definition_roots`, `parents`, `parent_of`.
- `src/ast/compact.rs` — `compact::run(doc) -> Document` (every parser ends
  with it, as in Zig).
- `src/document.rs` — `Document` (owns `source: Vec<u8>`), `Labels`,
  `Spelling` (+ `Bullet`, `OrderedDelim`, `ContainerOrigin`,
  `HighlightPrefix`).
- `src/ast/json.rs`, `src/ast/table.rs` — the `-o ast` / `-o table` encoders.
- `src/json.rs` — `Stringify` (Zig's `std.json.Stringify`, compact and
  pretty), `write_string`, and a reader (`json::parse` → `json::Value`).
- `src/ast/select.rs` — `text_of(ast, id)` (the rest of select is ported by
  the editor-layer owner).
- `src/error.rs` — `twig::Error`, the public error vocabulary.

### Type mapping

| Zig | Rust |
|-----|------|
| `[]const u8` (text) | `&[u8]` / `Vec<u8>` (`ast::Bytes`) — strings are BYTES, never `String`, inside the engine |
| `Node.Id` | `ast::NodeId` (`u32`) |
| `?T` | `Option<T>` |
| `.{ .heading = .{ .level = 2 } }` | `Kind::Heading { level: 2 }` |
| `.{ .inline_mark = .emph }` | `Kind::InlineMark(InlineMark::Emph)` |
| `.{ .str = "x" }` | `Kind::Str(b"x".to_vec())` |
| `.{ .container = .{ .name = "div", .form = .block_fenced } }` | `Kind::Container(Container::with_form(b"div", Form::BlockFenced))` |
| `std.Io.Writer` output | `&mut Vec<u8>` |
| `Allocator.Error` | (gone — allocation is infallible) |
| `std.mem.eql(u8, a, b)` | `a == b` |
| `std.StringHashMap` | `std::collections::HashMap<Vec<u8>, _>` |

Port **logic faithfully**, function by function, keeping names (snake_case)
and the doc comments that explain *why* (trim the rest). Do not "improve"
behaviour — a divergence from the Zig output is a bug, even if the Zig
behaviour looks odd. Iteration order matters wherever Zig iterates a hash map
and the order reaches output: check how Zig orders it (usually sorted).

## Rules for working in the shared tree

Several agents port different modules **in this same working tree at the same
time**.

1. **Touch only the files you own** (your brief lists them). If you need
   something from a module another agent owns that does not exist yet, write
   a small private helper in your own module and leave a `// TODO(port):`
   note, or wait for it. Never edit another owner's files. `lib.rs`,
   `languages/mod.rs`, `ast/mod.rs` already declare every module.
2. **Keep the crate compiling.** Everyone builds the same crate. Keep a file
   out of the module tree (no `mod x;` line yet) until it compiles, and fix
   your own errors immediately. If the build breaks in a file you do NOT own,
   another agent is mid-edit: wait a minute and retry; do not touch it.
3. **Use your own target dir** to avoid lock contention:
   `CARGO_TARGET_DIR=/home/user/twig/target/<your-name> cargo test --lib <filter>`.
   The machine has 4 cores shared by everyone: run focused tests
   (`cargo test --lib languages::djot`), not the whole suite in a loop.
4. **No dependencies.** Pure `std` only. No `unsafe`.
5. **Commit your own files only**, often, with a conventional message and NO
   attribution trailer:
   `git add <your paths> && git commit -m "feat(rust/djot): …" -- <your paths>`.
   If git reports `index.lock` exists, wait a few seconds and retry. Never
   commit other agents' files, never `git add -A`, never push, never rebase,
   never reset or checkout files.
6. Large data tables (HTML entities, …) should be generated from the Zig
   source with a script rather than typed by hand.
7. Test data in `src/languages/*/testdata/` is shared; read it from there
   (`env!("CARGO_MANIFEST_DIR")/../../src/languages/...`). Do not copy it.
