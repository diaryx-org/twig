//! AsciiDoc: the parser, the conformance harness that judges it, and the ASG
//! codec both compare through. Port of `src/languages/asciidoc/asciidoc.zig`.

pub(crate) use twig_kit::{ast, document, span};
pub(crate) use twig_kit::Error;

pub mod fidelity;
pub mod language;
pub mod syntax_table;

pub use language::Asciidoc;

/// Register Asciidoc with twig's registry and return its format — the first
/// call registers it; every later one hands back the same format.
#[cfg(feature = "twig")]
pub fn register() -> twig::Format {
    twig::register(Asciidoc).expect("asciidoc's names and codes are free")
}

/// AsciiDoc's format, registered on first use.
#[cfg(feature = "twig")]
pub fn format() -> twig::Format {
    register()
}

pub mod asg;
pub mod conformance;
pub mod parser;
pub mod serializer;


pub use parser::{parse, parse_inline_list};
pub use serializer::{serialize, serialize_ast, serialize_ast_spelled};

/// Small documents exercising the shared engine contract; not a conformance corpus.
pub const SAMPLES: &[&[u8]] = &[
    b"NOTE: An admonition.\n",
    b"",
    b"A paragraph with _emphasis_ and *strong* text.\n",
    b"== Heading\n\n* first\n* second\n",
    b"[source,zig]\n----\nconst x = 1;\n----\n",
];
