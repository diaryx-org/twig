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

#[cfg(test)]
mod block_tests;

pub use options::{Dialect, Extensions, ParseOptions};

use crate::document::Document;

/// Parse `source` (Markdown/CommonMark text) into a `Document`.
///
/// `options` decides what parses; it is not recorded on the result. The one
/// option rendering needs — `options.dialect`, for GFM's HTML conventions —
/// is passed to the HTML renderer by whoever holds the preset.
pub fn parse(source: &[u8], options: ParseOptions) -> Document {
    block::parse(source, options)
}

/// Whether `angled` — a whole `<…>` run, brackets included — spells a
/// CommonMark autolink (an absolute URI or an email) rather than raw HTML or
/// literal text. The inline scanner's own two recognizers, asked in the order
/// the scanner itself dispatches them.
pub fn spells_autolink(angled: &[u8]) -> bool {
    if angled.len() < 2 || angled[0] != b'<' {
        return false;
    }
    if inline::scan_autolink_uri(angled, 0) == Some(angled.len()) {
        return true;
    }
    if inline::scan_autolink_email(angled, 0) == Some(angled.len()) {
        return true;
    }
    false
}

pub use block::Parser;

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
