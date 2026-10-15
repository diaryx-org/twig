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
