//! Djot as a registry row: the [`Language`] twig's core is handed.

use twig_kit::ast::{Ast, Kind, NodeId};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
use twig_kit::document::Document;
use twig_kit::language::{Language, PrintFailure, Row};
use twig_kit::syntax::Syntax;

/// Djot, for [`twig::format::register`](https://docs.rs/twig-doc). One row,
/// `TWIG_FORMAT_DJOT`.
#[derive(Clone, Copy, Debug, Default)]
pub struct Djot;

const ROWS: &[Row] = &[Row { name: "djot", code: Some(1), extensions: &["dj", "djot"], aliases: &["dj"] }];

impl Language for Djot {
    fn rows(&self) -> &'static [Row] {
        ROWS
    }

    fn samples(&self, _row: usize) -> Vec<Vec<u8>> {
        crate::SAMPLES.iter().map(|s| s.to_vec()).collect()
    }

    fn parse(&self, _row: usize, _features: u32, source: &[u8]) -> Result<Document, String> {
        Ok(crate::parse(source))
    }

    /// Djot resolves no reference or footnote while it parses, and nothing
    /// in it reads ahead past the next block, so a fragment reads the same
    /// on its own as inside its document — unless it names an identifier.
    fn parse_fragment(
        &self,
        _row: usize,
        _features: u32,
        source: &[u8],
        range: std::ops::Range<usize>,
        doc: &Document,
    ) -> Option<Document> {
        let old_end = (range.end + doc.source.len()).checked_sub(source.len())?;
        crate::parse_fragment(&source[range.clone()], doc.source.get(range.start..old_end)?)
    }

    fn render_html(&self, _row: usize, _features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::html::render(doc, &Default::default())?)
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
        Ok(crate::serializer::serialize_ast_spelled(&doc.ast, &doc.node_spelling))
    }

    fn syntax(&self, _row: usize, _features: u32) -> &'static Syntax {
        crate::syntax_table::table()
    }

    fn fidelity(&self, kind: &Kind) -> Option<Fidelity> {
        Some(crate::fidelity::djot_fidelity(kind))
    }

    fn attrs_fidelity(&self, kind: &Kind) -> Option<AttrsFidelity> {
        Some(crate::fidelity::djot_attrs_fidelity(kind))
    }

    fn node_fidelity(&self, ast: &Ast, id: NodeId) -> Option<Fidelity> {
        Some(crate::fidelity::node_fidelity(ast, id))
    }

    fn node_attrs_fidelity(&self, ast: &Ast, id: NodeId) -> Option<AttrsFidelity> {
        Some(crate::fidelity::node_attrs_fidelity(ast, id))
    }
}
