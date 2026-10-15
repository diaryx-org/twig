//! HTML as a registry row: the [`Language`] twig's core is handed.

use twig_kit::ast::{Ast, Kind};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
use twig_kit::document::Document;
use twig_kit::language::{Language, PrintFailure, Row};
use twig_kit::syntax::Syntax;

/// HTML, for `twig::format::register`. One row, `TWIG_FORMAT_HTML`.
#[derive(Clone, Copy, Debug, Default)]
pub struct Html;

const ROWS: &[Row] = &[Row { name: "html", code: Some(4), extensions: &["html", "htm"], aliases: &[] }];

impl Language for Html {
    fn rows(&self) -> &'static [Row] {
        ROWS
    }

    fn samples(&self, _row: usize) -> Vec<Vec<u8>> {
        crate::SAMPLES.iter().map(|s| s.to_vec()).collect()
    }

    fn parse(&self, _row: usize, _features: u32, source: &[u8]) -> Result<Document, String> {
        Ok(crate::parse(source))
    }

    fn serialize(&self, _row: usize, _features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        self.serialize_ast(&doc.ast)
    }

    fn serialize_ast(&self, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
        crate::serialize_alloc(ast, None).map_err(|_| PrintFailure::UnsafeMetadata)
    }

    fn syntax(&self, _row: usize, _features: u32) -> &'static Syntax {
        crate::syntax_table::table()
    }

    fn fidelity(&self, kind: &Kind) -> Option<Fidelity> {
        Some(crate::fidelity::html_fidelity(kind))
    }

    fn attrs_fidelity(&self, kind: &Kind) -> Option<AttrsFidelity> {
        Some(crate::fidelity::html_attrs_fidelity(kind))
    }
}
