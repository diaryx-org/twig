# twig

Rust bindings for [Twig](https://github.com/diaryx-org/twig), a document
parser and lossless AST editor for Djot, Markdown, HTML, and XML.

Twig treats a document the way `jq` treats JSON: parse it into a shared AST,
then **query**, **edit**, **filter**, and **serialize** it with the same
selector language across every format — round-tripping the original source
byte-for-byte.

## Install

The crate is published as **`twig-doc`** (the `twig` name was already taken),
but the library is imported as `twig`:

```toml
[dependencies]
twig-doc = "1"
```

```rust
use twig::{Document, Format};
```

```rust
use twig::{Document, Format};

let mut doc = Document::parse_str("# Title\n\nHello *world*.\n", Format::Markdown)?;

// Render to HTML.
let html = doc.render_html()?;

// Query the tree with CSS-lite selectors.
for m in doc.query("heading[level=1]")? {
    println!("{:?}", m.span);
}

// Cross-convert (Markdown -> Djot).
let djot = doc.serialize(Format::Djot)?;
# Ok::<(), twig::Error>(())
```

An `Editor` adds lossless, in-place span-splice edits (by index path or
selector, plus offset-addressed rich-text ops and undo/redo), and a `Builder`
constructs documents programmatically.

## Build requirements

The bindings compile Twig's Zig implementation into a static library at build
time, so **a [Zig](https://ziglang.org) 0.17.0 compiler must be on `PATH`**.
The Zig source is vendored into the published crate; nothing is downloaded at
build time. Cross-compilation is supported for any target Zig can emit (the
`build.rs` maps the Cargo target triple to a Zig target).

## License

Licensed under either of Apache-2.0 or MIT at your option.
