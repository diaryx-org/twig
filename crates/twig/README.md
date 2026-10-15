# twig-doc

Parse, query, edit, and losslessly round-trip Djot, Markdown (CommonMark, GFM
and Twig's default flavour), HTML, XML/SVG and AsciiDoc documents — in pure
Rust, with no `-sys` crate and no native toolchain.

```toml
[dependencies]
twig-doc = "5"
```

```rust
use twig::{Document, Editor, Format, Target};

let mut doc = Document::parse_str("# Hi *there*\n", Format::Markdown)?;
assert_eq!(doc.render_html()?, b"<h1>Hi <em>there</em></h1>\n");
assert_eq!(doc.serialize_to(Target::Djot)?, b"# Hi _there_\n");

let mut ed = Editor::new_str("# Hi\n", Format::Markdown)?;
ed.replace("heading", "## Hello")?; // a heading's span stops before its newline
assert_eq!(ed.source_str()?, "## Hello\n");
# Ok::<(), twig::Error>(())
```

The crate root is API-compatible with `twig-doc` 4.x (the FFI binding over
the Zig library): `Document`, `Editor`, `Builder`, `Format`, `Gesture`,
`Kind`, `FlatNode`, runtime languages (`Language`, `register`, `serve`,
`helper::spawn`) and the rest keep their names and signatures. The engine
underneath is public too: `twig::ast`, `twig::document`, `twig::languages`,
`twig::format`.

The crate also builds the `twig` command-line tool (`cargo install twig-doc`),
byte-for-byte compatible with the Zig one.

Licensed under either of Apache-2.0 or MIT, at your option.
