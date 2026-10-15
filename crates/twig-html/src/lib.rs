//! HTML: port of `src/languages/html/html.zig`. A forgiving HTML parser
//! (`parser`) and a generic `Ast` -> HTML text renderer (`serializer`). The
//! parser feeds generic markup into the shared AST; the serializer also
//! covers the full semantic vocabulary (it is what the djot and Markdown HTML
//! renderers drive).

pub(crate) use twig_kit::{ast, document, span};
pub(crate) use twig_kit::Error;

pub mod fidelity;
pub mod language;
pub mod syntax_table;

pub use language::Html;

/// Register Html with twig's registry and return its format — the first
/// call registers it; every later one hands back the same format.
#[cfg(feature = "twig")]
pub fn register() -> twig::Format {
    twig::register(Html).expect("html's names and codes are free")
}

/// HTML's format, registered on first use.
#[cfg(feature = "twig")]
pub fn format() -> twig::Format {
    register()
}

pub mod parser;


use crate::document::Document;
pub use parser::Parser;

pub use twig_kit::html::{
    COMMONMARK_RENDER_OPTIONS, GFM_RENDER_OPTIONS,
    is_void_element, serialize, serialize_alloc, serialize_alloc_opts, serialize_node, serialize_node_opts,
    serialize_opts, write_element_text, Context, RenderAllocError, RenderError, RenderOptions, Renderer, KV,
};

/// Parse forgiving HTML into the shared generic-markup AST. A
/// document-oriented parser rather than a browser DOM implementation: it never
/// fails, recognizes normal HTML token forms and common optional end tags, and
/// preserves unknown markup in the generic AST vocabulary.
pub fn parse(source: &[u8]) -> Document {
    Parser::new(source).parse()
}

/// Small documents exercising the shared engine contract; not a conformance corpus.
pub const SAMPLES: &[&[u8]] = &[
    b"",
    b"<p>A paragraph with <em>emphasis</em> and <strong>strong</strong> text.</p>\n",
    b"<h1>Heading</h1>\n",
    b"<p id=\"intro\" class=\"note\">Text &amp; more.</p>\n",
];
