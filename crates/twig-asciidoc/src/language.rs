//! AsciiDoc as a registry row: the [`Language`] twig's core is handed.

use twig_kit::ast::{Ast, Kind, NodeId};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
use twig_kit::document::Document;
use twig_kit::language::{Language, PrintFailure, Row};
use twig_kit::syntax::Syntax;

/// AsciiDoc, for `twig::format::register`. One row, `TWIG_FORMAT_ASCIIDOC`.
#[derive(Clone, Copy, Debug, Default)]
pub struct Asciidoc;

const ROWS: &[Row] = &[Row { name: "asciidoc", code: Some(5), extensions: &["adoc", "asciidoc"], aliases: &["adoc"] }];

impl Language for Asciidoc {
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
        Ok(crate::serialize(doc))
    }

    fn serialize_ast(&self, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serialize_ast(ast))
    }

    fn serialize_document(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serialize(doc))
    }

    fn serialize_built(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serialize_ast_spelled(&doc.ast, &doc.node_spelling))
    }

    fn syntax(&self, _row: usize, _features: u32) -> &'static Syntax {
        crate::syntax_table::table()
    }

    fn fidelity(&self, kind: &Kind) -> Option<Fidelity> {
        Some(crate::fidelity::asciidoc_fidelity(kind))
    }

    fn attrs_fidelity(&self, kind: &Kind) -> Option<AttrsFidelity> {
        Some(crate::fidelity::asciidoc_attrs_fidelity(kind))
    }

    fn node_fidelity(&self, ast: &Ast, id: NodeId) -> Option<Fidelity> {
        Some(crate::fidelity::node_fidelity(ast, id))
    }
}
