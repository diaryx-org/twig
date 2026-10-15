//! Markdown: CommonMark 0.31.2 plus extensions. Port of
//! `src/languages/markdown/`.
//!
//! Ownership while porting: the PARSER owner owns this file and
//! `block.rs`, `inline.rs`, `entities.rs`, `attributes.rs`, `highlight.rs`,
//! `options.rs`; the PRINTING owner owns `serializer.rs`, `html.rs`,
//! `conformance.rs`, `gfm_conformance.rs`. Keep every `mod` line below.

pub mod attributes;
pub mod block;
pub mod entities;
pub mod highlight;
pub mod html;
pub mod inline;
pub mod options;
pub mod serializer;

#[cfg(test)]
mod conformance;
#[cfg(test)]
mod gfm_conformance;

pub use options::{Dialect, Extensions, ParseOptions};

use crate::document::Document;

/// Parse `source` (Markdown/CommonMark text) into a `Document`.
///
/// `options` decides what parses; it is not recorded on the result.
pub fn parse(source: &[u8], options: ParseOptions) -> Document {
    // TODO(port): block parser in progress.
    let _ = options;
    let mut b = crate::ast::Builder::new();
    let root = b.add_container(crate::ast::Kind::Doc, &[]);
    b.set_span(root, crate::span::Span::new(0, source.len()));
    crate::ast::compact::run(b.finish_document(source, root))
}

/// Small documents exercising the shared engine contract; not a conformance
/// corpus. These are the default flavor's.
pub const SAMPLES: &[&[u8]] = &[
    b"",
    b"A paragraph with *emphasis* and **strong** text.\n",
    b"# Heading\n\n> Quote\n\n- first\n- second\n",
    b"- [x] done\n- [ ] pending\n",
    b"``` zig\nconst x = 1;\n```\n",
    b"A paragraph that runs\nover two lines.\n\n> A quote that runs\n> over two lines.\n",
];

/// Strict CommonMark's harness samples.
pub const COMMONMARK_SAMPLES: &[&[u8]] = &[
    b"",
    b"A paragraph with *emphasis* and **strong** text.\n",
    b"# Heading\n\n> Quote\n\n- first\n- second\n",
    b"Setext\n======\n\n    indented code\n",
];

/// GFM's harness samples.
pub const GFM_SAMPLES: &[&[u8]] = &[
    b"",
    b"A paragraph with ~~struck~~ and **strong** text.\n",
    b"| a | b |\n| --- | ---: |\n| 1 | 2 |\n",
    b"- [x] done\n- [ ] pending\n\nSee https://example.com now.\n",
];
