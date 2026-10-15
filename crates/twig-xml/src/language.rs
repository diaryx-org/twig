//! XML as registry rows: the [`Language`] twig's core is handed.

use twig_kit::ast::Kind;
use twig_kit::document::Document;
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
use twig_kit::language::{Language, PrintFailure, Row};
use twig_kit::syntax::Syntax;

/// XML, for `twig::format::register`: `xml` (`TWIG_FORMAT_XML`) and its
/// dialect `svg` (`TWIG_FORMAT_SVG`). Parse-only for editing; its printer
/// needs the `Document` it parsed, so it writes no bare tree.
#[derive(Clone, Copy, Debug, Default)]
pub struct Xml;

const ROWS: &[Row] = &[
    Row { name: "xml", code: Some(3), extensions: &["xml"], aliases: &[] },
    Row { name: "svg", code: Some(8), extensions: &["svg"], aliases: &[] },
];

impl Language for Xml {
    fn rows(&self) -> &'static [Row] {
        ROWS
    }

    fn samples(&self, row: usize) -> Vec<Vec<u8>> {
        let s = if row == 1 { crate::SVG_SAMPLES } else { crate::SAMPLES };
        s.iter().map(|s| s.as_bytes().to_vec()).collect()
    }

    fn parse(&self, _row: usize, _features: u32, source: &[u8]) -> Result<Document, String> {
        crate::parse(source).map_err(|e| e.name().to_string())
    }

    fn serialize(&self, _row: usize, _features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        crate::serialize(doc).map_err(|_| PrintFailure::UnsupportedNode)
    }

    fn serializes_from_ast(&self) -> bool {
        false
    }

    /// XML's printer spells only the generic-markup kinds its own parser
    /// produces, so a built tree holding a semantic kind is refused.
    fn serialize_built(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        crate::serialize(doc).map_err(|_| PrintFailure::UnsupportedFormat)
    }

    fn syntax(&self, _row: usize, _features: u32) -> &'static Syntax {
        crate::syntax_table::table()
    }

    /// XML writes only its own parse, so a converted tree keeps nothing.
    fn fidelity(&self, _kind: &Kind) -> Option<Fidelity> {
        Some(Fidelity::Dropped)
    }

    fn attrs_fidelity(&self, _kind: &Kind) -> Option<AttrsFidelity> {
        Some(AttrsFidelity::all(Fidelity::Dropped))
    }
}
