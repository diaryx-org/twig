//! Markdown as registry rows: the [`Language`] twig's core is handed.

use twig_kit::ast::{Ast, Kind, NodeId};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
use twig_kit::document::Document;
use twig_kit::language::{Feature, Language, PrintFailure, Row};
use twig_kit::syntax::Syntax;

use crate::{Extensions, ParseOptions};

/// Markdown, for `twig::format::register`: `markdown`
/// (`TWIG_FORMAT_MARKDOWN`, CommonMark plus the common extensions) and its
/// dialects `commonmark` (strict, `TWIG_FORMAT_COMMONMARK`) and `gfm`
/// (`TWIG_FORMAT_GFM`). Its opt-in extensions are features, in `TWIG_MD_*`
/// order.
#[derive(Clone, Copy, Debug, Default)]
pub struct Markdown;

const ROWS: &[Row] = &[
    Row { name: "markdown", code: Some(2), extensions: &["md", "markdown"], aliases: &["md"] },
    Row { name: "commonmark", code: Some(6), extensions: &[], aliases: &[] },
    Row { name: "gfm", code: Some(7), extensions: &[], aliases: &[] },
];

const FEATURES: &[Feature] = &[
    Feature { name: "directives", requires: &[] },
    Feature { name: "math", requires: &[] },
    Feature { name: "html_elements", requires: &[] },
    Feature { name: "highlight", requires: &[] },
    Feature { name: "highlight_colors", requires: &["highlight"] },
];

/// The extensions a feature mask turns on, bit `i` the `i`th feature.
pub fn extensions_from_mask(mask: u32) -> Extensions {
    let bit = |i: u32| mask & (1 << i) != 0;
    Extensions { directives: bit(0), math: bit(1), html_elements: bit(2), highlight: bit(3), highlight_colors: bit(4) }
}

/// The feature mask that turns `e` on.
pub fn mask_from_extensions(e: Extensions) -> u32 {
    (e.directives as u32) | (e.math as u32) << 1 | (e.html_elements as u32) << 2 | (e.highlight as u32) << 3
        | (e.highlight_colors as u32) << 4
}

/// The parse options row `row` reads with `features` on.
pub fn options(row: usize, features: u32) -> ParseOptions {
    let preset = match row {
        1 => ParseOptions::COMMONMARK,
        2 => ParseOptions::GFM,
        _ => ParseOptions::default(),
    };
    preset.with_extensions(extensions_from_mask(features))
}

impl Language for Markdown {
    fn rows(&self) -> &'static [Row] {
        ROWS
    }

    fn features(&self) -> &'static [Feature] {
        FEATURES
    }

    fn samples(&self, row: usize) -> Vec<Vec<u8>> {
        let s = match row {
            1 => crate::COMMONMARK_SAMPLES,
            2 => crate::GFM_SAMPLES,
            _ => crate::SAMPLES,
        };
        s.iter().map(|s| s.to_vec()).collect()
    }

    fn parse(&self, row: usize, features: u32, source: &[u8]) -> Result<Document, String> {
        Ok(crate::parse(source, options(row, features)))
    }

    fn parse_fragment(
        &self,
        row: usize,
        features: u32,
        source: &[u8],
        range: std::ops::Range<usize>,
        doc: &Document,
    ) -> Option<Document> {
        crate::block::parse_fragment(source, range, options(row, features), doc)
    }

    fn render_html(&self, row: usize, features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        let dialect = options(row, features).dialect;
        let opts = crate::html::RenderOptions { dialect, ..Default::default() };
        Ok(crate::html::render_alloc(doc, opts)?)
    }

    fn serialize(&self, _row: usize, _features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serializer::serialize(doc))
    }

    fn serialize_ast(&self, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serializer::serialize_ast(ast))
    }

    fn serialize_document(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serializer::serialize(doc))
    }

    fn serialize_built(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        Ok(crate::serializer::serialize_ast_spelled(&doc.ast, &doc.node_spelling))
    }

    fn syntax(&self, row: usize, features: u32) -> &'static Syntax {
        crate::syntax_table::for_options(&options(row, features))
    }

    fn fidelity(&self, kind: &Kind) -> Option<Fidelity> {
        Some(crate::fidelity::markdown_fidelity(kind))
    }

    fn attrs_fidelity(&self, kind: &Kind) -> Option<AttrsFidelity> {
        Some(crate::fidelity::markdown_attrs_fidelity(kind))
    }

    fn node_fidelity(&self, ast: &Ast, id: NodeId) -> Option<Fidelity> {
        Some(crate::fidelity::node_fidelity(ast, id))
    }
}
