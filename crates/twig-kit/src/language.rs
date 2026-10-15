//! What a compiled language hands twig's core: the [`Language`] trait. A
//! language crate (`twig-markdown`, `twig-djot`, …) implements it on the kit
//! alone, and a program registers it with `twig-doc`'s registry, which
//! starts empty. `docs/proposals/language-crates.md` is the argument.
//!
//! A language owns one or more ROWS. Row 0 is the language itself; any
//! further row is a dialect of it (`commonmark` and `gfm` over Markdown,
//! `svg` over XML): a format of its own, parsed by the same language, that
//! writes back as the language's own target. Every call names the row it is
//! made through and the FEATURES in force over it — bit `i` of the mask is
//! [`Language::features`]`[i]`, already closed under `requires`.

use crate::ast::{Ast, Kind, NodeId};
use crate::fidelity::{AttrsFidelity, Fidelity};
use crate::document::Document;
use crate::syntax::Syntax;

/// One row of a language: a format with a name of its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Row {
    /// The name the row answers to (`"markdown"`, `"gfm"`).
    pub name: &'static str,
    /// The row's wire code, when twig has given it one: the `TWIG_FORMAT_*`
    /// value it keeps across processes. `None` for any other language, whose
    /// rows the registry numbers as it registers them.
    pub code: Option<u16>,
    /// File extensions, lowercase and dot-less, that select this row.
    pub extensions: &'static [&'static str],
    /// Further names the row answers to (`"md"`).
    pub aliases: &'static [&'static str],
}

/// A named switch the language's parser reads, as Markdown's extensions are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Feature {
    pub name: &'static str,
    /// Features that come on with this one.
    pub requires: &'static [&'static str],
}

/// Why printing failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrintFailure {
    /// The row has no printer for this direction.
    UnsupportedFormat,
    /// The HTML printer refused a metadata block containing `</script`.
    UnsafeMetadata,
    /// The printer met a kind it has no spelling for.
    UnsupportedNode,
    /// The language refused, with its reason.
    Language(String),
}

impl PrintFailure {
    /// The error name a message prints.
    pub fn name(&self) -> String {
        match self {
            PrintFailure::UnsupportedFormat => "UnsupportedFormat".into(),
            PrintFailure::UnsafeMetadata => "UnsafeMetadata".into(),
            PrintFailure::UnsupportedNode => "UnsupportedNode".into(),
            PrintFailure::Language(why) => why.clone(),
        }
    }
}

impl From<crate::html::RenderError> for PrintFailure {
    fn from(e: crate::html::RenderError) -> PrintFailure {
        match e {
            crate::html::RenderError::UnsafeMetadata => PrintFailure::UnsafeMetadata,
        }
    }
}

/// A compiled language: its rows, its parser, its printers and the table
/// its editor gestures write with.
pub trait Language: Send + Sync + 'static {
    /// The language's rows; row 0 is the language itself, and names it.
    fn rows(&self) -> &'static [Row];

    /// The features its parser reads, in bit order. None by default.
    fn features(&self) -> &'static [Feature] {
        &[]
    }

    /// The features `row` has on before a caller lays any over it.
    fn row_features(&self, row: usize) -> u32 {
        let _ = row;
        0
    }

    /// Small documents the contract holds `row` to.
    fn samples(&self, row: usize) -> Vec<Vec<u8>>;

    /// Parse `source` through `row`. The error is why, for a message.
    fn parse(&self, row: usize, features: u32, source: &[u8]) -> Result<Document, String>;

    /// Render a parse to HTML with the row's conventions. By default the
    /// kit's generic printer, without the document's labels.
    fn render_html(&self, row: usize, features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        let _ = (row, features);
        Ok(crate::html::serialize_alloc(&doc.ast, None)?)
    }

    /// Write a parse back in its own syntax (`-o canonical`).
    fn serialize(&self, row: usize, features: u32, doc: &Document) -> Result<Vec<u8>, PrintFailure>;

    /// Whether [`Language::serialize_ast`] can write a bare tree.
    fn serializes_from_ast(&self) -> bool {
        true
    }

    /// Write a bare tree in this language — a conversion into it.
    fn serialize_ast(&self, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
        let _ = ast;
        Err(PrintFailure::UnsupportedFormat)
    }

    /// Write a `Document` in this language, keeping what only the document
    /// carries (spelling, labels). Unsupported by default.
    fn serialize_document(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        let _ = doc;
        Err(PrintFailure::UnsupportedFormat)
    }

    /// Write a tree a builder made, with the spelling it recorded. By
    /// default [`Language::serialize_ast`].
    fn serialize_built(&self, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
        self.serialize_ast(&doc.ast)
    }

    /// The table the row's editor gestures write, under `features`.
    fn syntax(&self, row: usize, features: u32) -> &'static Syntax;

    /// How `kind` survives a conversion into this language. `None` — the
    /// default — has core measure the language with its probes instead.
    fn fidelity(&self, kind: &Kind) -> Option<Fidelity> {
        let _ = kind;
        None
    }

    /// [`Language::fidelity`] for one node: the kind's answer, downgraded by
    /// whatever only the node's own contents can say.
    fn node_fidelity(&self, ast: &Ast, id: NodeId) -> Option<Fidelity> {
        self.fidelity(&ast.nodes[id as usize].kind)
    }

    /// How a `kind` node's attributes survive, by key class. `None` with
    /// [`Language::fidelity`].
    fn attrs_fidelity(&self, kind: &Kind) -> Option<AttrsFidelity> {
        let _ = kind;
        None
    }

    /// [`Language::attrs_fidelity`] for one node, before core lays the
    /// node's own fidelity over it.
    fn node_attrs_fidelity(&self, ast: &Ast, id: NodeId) -> Option<AttrsFidelity> {
        self.attrs_fidelity(&ast.nodes[id as usize].kind)
    }
}
