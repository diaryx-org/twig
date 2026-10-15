//! What twig's languages share: the node vocabulary and tree ([`ast`]), a
//! parse's [`document`], byte [`span`]s, the spelling table an editor writes
//! with ([`syntax`]), the generic [`html`] printer, and the [`Language`]
//! trait a language crate implements. Port of fig's `fig-kit` shape: the
//! kit names no language, and depends on nothing but `std`.

pub mod ast;
pub mod attrs_writer;
pub mod document;
pub mod entities;
pub mod error;
pub mod fidelity;
pub mod html;
pub mod json;
pub mod language;
pub mod parse_diagnostic;
pub mod span;
pub mod syntax;
pub mod syntax_json;

pub use error::Error;
pub use language::{Feature, Language, PrintFailure, Row};
