//! Twig: parse, query, edit, and losslessly round-trip Djot, Markdown, HTML,
//! XML, and AsciiDoc documents — in pure Rust.
//!
//! The crate is organised like the Zig implementation it replaces:
//!
//! - [`ast`] — the shared node vocabulary and the tree-level operations
//!   (selectors, the splicer, the editor).
//! - [`document`] — a tree plus the source and byte positions tying them.
//! - [`languages`] — one module per format: a parser, an HTML renderer and a
//!   serializer.
//! - [`format`] — the registry tying formats to their parsers and printers.

pub mod ast;
pub mod attrs_writer;
pub mod contract;
pub mod diagnostics;
pub mod document;
pub mod error;
pub mod format;
pub mod helper;
pub mod language;
pub mod json;
pub mod languages;
pub mod parse_diagnostic;
pub mod runtime;
pub mod span;
pub mod syntax;
pub mod syntax_json;
pub mod wire;

pub mod cli;

pub use error::Error;
