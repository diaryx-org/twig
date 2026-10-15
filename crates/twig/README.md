# twig-doc

Parse, query, edit, and losslessly round-trip documents — in pure Rust, with
no `-sys` crate and no native toolchain. This crate is twig's core: the
editor, the registry, the conversions and the diagnostics. It carries no
language. Each language is a crate of its own, and a program depends on the
ones it reads and writes:

| Crate | Formats |
|---|---|
| [`twig-markdown`](https://crates.io/crates/twig-markdown) | `markdown` (CommonMark plus the common extensions), `commonmark`, `gfm` |
| [`twig-djot`](https://crates.io/crates/twig-djot) | `djot` |
| [`twig-html`](https://crates.io/crates/twig-html) | `html` |
| [`twig-xml`](https://crates.io/crates/twig-xml) | `xml`, `svg` |
| [`twig-asciidoc`](https://crates.io/crates/twig-asciidoc) | `asciidoc` |

```toml
[dependencies]
twig-doc = "6"
twig-markdown = "6"
twig-djot = "6"
```

```rust
use twig::{Document, Editor};

let markdown = twig_markdown::format(); // registers Markdown the first time
let djot = twig_djot::format();

let mut doc = Document::parse_str("# Hi *there*\n", markdown)?;
assert_eq!(doc.render_html()?, b"<h1>Hi <em>there</em></h1>\n");
assert_eq!(doc.serialize_to(djot.target())?, b"# Hi _there_\n");

let mut ed = Editor::new_str("# Hi\n", markdown)?;
ed.replace("heading", "## Hello")?; // a heading's span stops before its newline
assert_eq!(ed.source_str()?, "## Hello\n");
# Ok::<(), twig::Error>(())
```

## fig

`twig-doc`'s one feature, `fig`, is on by default. With it, a document's
frontmatter is read and edited in place through
[fig](https://crates.io/crates/fig) (`twig::meta`), and every parse reads a
document as its frontmatter's `twig` settings ask — a dialect of its own
language, and features laid over the caller's:

```rust
let markdown = twig_markdown::format();
let src = "---\ntwig:\n  features: [math]\n---\n$x$\n";
let mut doc = twig::Document::parse_str(src, markdown)?;
assert_eq!(doc.query("inline_math")?.len(), 1);
# Ok::<(), twig::Error>(())
```

With `default-features = false`, twig depends on nothing but `twig-kit` and
parses exactly as the caller asks.

A `Format` is a handle to a row of the registry. A name finds one too
(`Format::by_name("gfm")`), once its language is registered. A language is
anything implementing [`twig_kit::Language`](https://docs.rs/twig-kit): a
crate on the kit alone, registered with `twig::register`. A language
written in another process or another runtime speaks the node-table
contract instead (`TableLanguage`, `register_table`, `serve`,
`helper::spawn`).

The `twig` command-line tool is its own crate,
[`twig-doc-cli`](https://crates.io/crates/twig-doc-cli), with every language
registered: `cargo install twig-doc-cli`.

Licensed under either of Apache-2.0 or MIT, at your option.
