//! Twig: parse, query, edit, and losslessly round-trip Djot, Markdown, HTML,
//! XML, and AsciiDoc documents — in pure Rust.
//!
//! The crate is organised like the Zig implementation it replaces:
//!
//! - [`ast`] — the shared node vocabulary and the tree-level operations
//!   (selectors, the splicer, the editor).
//! - [`document`] — a tree plus the source and byte positions tying them.
//! - [`format`] — the registry tying formats to their parsers and printers.
//!   It starts empty: a program registers the language crates it uses
//!   (`twig-markdown`, `twig-djot`, …).

#[doc = include_str!("../README.md")]
#[cfg(doctest)]
pub struct ReadmeDoctests;

pub mod api;
pub mod ast;
pub mod contract;
pub mod diagnostics;
pub mod format;
pub mod helper;
pub mod language;
pub mod runtime;
pub mod wire;

#[cfg(test)]
pub(crate) mod test_languages;

pub use twig_kit as kit;
pub use twig_kit::{attrs_writer, document, entities, error, html, json, parse_diagnostic, span, syntax, syntax_json};

pub use api::*;
pub use error::Error;
pub use format::{register, Format, NativeRegisterError, Target};
pub use language::{register_table, serve, Call, Description, Feature, RegisterError, Sample, Server, Set, TableLanguage};
pub use twig_kit::Language;
