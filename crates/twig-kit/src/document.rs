//! Document = a parsed [`Ast`] plus the source it was parsed from and the byte
//! positions tying the two together. See `document.zig` for the criterion of
//! what lives here: a fact belongs in `Document` iff two documents differing
//! only in that fact render identically.

use std::collections::HashMap;

use crate::ast::{Ast, NodeId};
use crate::span::Span;

/// Label -> definition node, for the constructs a document resolves BY NAME.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Labels {
    /// Normalized label -> the author-written `reference` node, first wins.
    pub references: HashMap<Vec<u8>, NodeId>,
    /// The same for references the PARSER synthesized (djot's implicit heading
    /// targets). An explicit definition always beats one of these.
    pub auto_references: HashMap<Vec<u8>, NodeId>,
    /// Normalized label -> the `footnote` definition node.
    pub footnotes: HashMap<Vec<u8>, NodeId>,
}

impl Labels {
    pub fn reference(&self, label: &[u8]) -> Option<NodeId> {
        self.references.get(label).or_else(|| self.auto_references.get(label)).copied()
    }

    pub fn footnote(&self, label: &[u8]) -> Option<NodeId> {
        self.footnotes.get(label).copied()
    }

    /// Index a BARE tree: every `reference` and `footnote` node in the arena,
    /// by its own label. Where several share a label the HIGHEST id wins.
    pub fn index(ast: &Ast) -> Labels {
        let mut out = Labels::default();
        for n in &ast.nodes {
            match &n.kind {
                crate::ast::Kind::Reference { label, .. } => {
                    out.references.insert(label.clone(), n.id);
                }
                crate::ast::Kind::Footnote { label } => {
                    out.footnotes.insert(label.clone(), n.id);
                }
                _ => {}
            }
        }
        out
    }

    pub fn maps_mut(&mut self) -> [&mut HashMap<Vec<u8>, NodeId>; 3] {
        [&mut self.references, &mut self.auto_references, &mut self.footnotes]
    }

    pub fn maps(&self) -> [&HashMap<Vec<u8>, NodeId>; 3] {
        [&self.references, &self.auto_references, &self.footnotes]
    }

    pub fn is_empty(&self) -> bool {
        self.references.is_empty() && self.auto_references.is_empty() && self.footnotes.is_empty()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Bullet {
    Dash,
    Plus,
    Star,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HighlightPrefix {
    Tight,
    Spaced,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OrderedDelim {
    Period,
    ParenAfter,
    ParenBoth,
}

/// Whether a `container` was written as a TAG or as a DIRECTIVE.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ContainerOrigin {
    Element,
    Directive,
}

/// One recorded spelling.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Spelling {
    Bullet(Bullet),
    OrderedDelim(OrderedDelim),
    ContainerOrigin(ContainerOrigin),
    HighlightPrefix(HighlightPrefix),
}

impl Spelling {
    /// `(field, value)` as the node table writes it.
    pub fn names(self) -> (&'static str, &'static str) {
        match self {
            Spelling::Bullet(b) => (
                "bullet",
                match b {
                    Bullet::Dash => "dash",
                    Bullet::Plus => "plus",
                    Bullet::Star => "star",
                },
            ),
            Spelling::OrderedDelim(d) => (
                "ordered_delim",
                match d {
                    OrderedDelim::Period => "period",
                    OrderedDelim::ParenAfter => "paren_after",
                    OrderedDelim::ParenBoth => "paren_both",
                },
            ),
            Spelling::ContainerOrigin(o) => (
                "container_origin",
                match o {
                    ContainerOrigin::Element => "element",
                    ContainerOrigin::Directive => "directive",
                },
            ),
            Spelling::HighlightPrefix(h) => (
                "highlight_prefix",
                match h {
                    HighlightPrefix::Tight => "tight",
                    HighlightPrefix::Spaced => "spaced",
                },
            ),
        }
    }

    pub fn from_names(field: &str, value: &str) -> Option<Spelling> {
        Some(match (field, value) {
            ("bullet", "dash") => Spelling::Bullet(Bullet::Dash),
            ("bullet", "plus") => Spelling::Bullet(Bullet::Plus),
            ("bullet", "star") => Spelling::Bullet(Bullet::Star),
            ("ordered_delim", "period") => Spelling::OrderedDelim(OrderedDelim::Period),
            ("ordered_delim", "paren_after") => Spelling::OrderedDelim(OrderedDelim::ParenAfter),
            ("ordered_delim", "paren_both") => Spelling::OrderedDelim(OrderedDelim::ParenBoth),
            ("container_origin", "element") => Spelling::ContainerOrigin(ContainerOrigin::Element),
            ("container_origin", "directive") => Spelling::ContainerOrigin(ContainerOrigin::Directive),
            ("highlight_prefix", "tight") => Spelling::HighlightPrefix(HighlightPrefix::Tight),
            ("highlight_prefix", "spaced") => Spelling::HighlightPrefix(HighlightPrefix::Spaced),
            _ => return None,
        })
    }
}

/// A parsed tree, the source it came from, and the position side tables.
#[derive(Clone, Debug, Default)]
pub struct Document {
    /// The bytes this document was parsed from.
    pub source: Vec<u8>,
    pub ast: Ast,
    /// `node_spans[id]`: the byte range of the source that produced `id`.
    /// Always exactly `ast.nodes.len()` long.
    pub node_spans: Vec<Span>,
    /// `node_content_spans[id]`: the node's interior, or `None`.
    pub node_content_spans: Vec<Option<Span>>,
    /// May be SHORTER than `ast.nodes`; read through [`Document::spelling`].
    pub node_spelling: Vec<Option<Spelling>>,
    /// May be SHORTER than `ast.nodes`; read through [`Document::marker_span`].
    pub node_marker_spans: Vec<Option<Span>>,
    /// Indexed by attrs id (NOT node id). May be short.
    pub attrs_spans: Vec<Option<Span>>,
    pub labels: Labels,
}

impl Document {
    /// A document around a bare tree: no positions recorded.
    pub fn from_ast(source: &[u8], ast: Ast) -> Document {
        let n = ast.nodes.len();
        Document {
            source: source.to_vec(),
            ast,
            node_spans: vec![Span::new(0, 0); n],
            node_content_spans: vec![None; n],
            ..Default::default()
        }
    }

    pub fn span(&self, id: NodeId) -> Span {
        self.node_spans[id as usize]
    }

    pub fn content_span(&self, id: NodeId) -> Option<Span> {
        self.node_content_spans[id as usize]
    }

    pub fn spelling(&self, id: NodeId) -> Option<Spelling> {
        self.node_spelling.get(id as usize).copied().flatten()
    }

    pub fn marker_span(&self, id: NodeId) -> Option<Span> {
        self.node_marker_spans.get(id as usize).copied().flatten()
    }

    pub fn marker_text(&self, id: NodeId) -> Option<&[u8]> {
        Some(self.marker_span(id)?.of(&self.source))
    }

    pub fn container_origin(&self, id: NodeId) -> Option<ContainerOrigin> {
        match self.spelling(id)? {
            Spelling::ContainerOrigin(o) => Some(o),
            _ => None,
        }
    }

    /// The source span of the attribute block attached to NODE `id`.
    pub fn attrs_span(&self, id: NodeId) -> Option<Span> {
        let idx = self.ast.nodes[id as usize].attrs?;
        self.attrs_spans.get(idx as usize).copied().flatten()
    }

    pub fn attrs_text(&self, id: NodeId) -> Option<&[u8]> {
        Some(self.attrs_span(id)?.of(&self.source))
    }

    pub fn text(&self, id: NodeId) -> &[u8] {
        self.span(id).of(&self.source)
    }

    pub fn content_text(&self, id: NodeId) -> Option<&[u8]> {
        Some(self.content_span(id)?.of(&self.source))
    }

    pub fn children(&self, id: NodeId) -> crate::ast::reader::Children<'_> {
        self.ast.children(id)
    }

    /// Compare the span layers (separate from `Ast::eql`).
    pub fn spans_eql(&self, other: &Document) -> bool {
        if self.node_spans != other.node_spans || self.node_content_spans != other.node_content_spans {
            return false;
        }
        let n = self.attrs_spans.len().max(other.attrs_spans.len());
        for i in 0..n {
            let a = self.attrs_spans.get(i).copied().flatten();
            let b = other.attrs_spans.get(i).copied().flatten();
            if a != b {
                return false;
            }
        }
        let m = self.node_marker_spans.len().max(other.node_marker_spans.len());
        for i in 0..m {
            if self.marker_span(i as NodeId) != other.marker_span(i as NodeId) {
                return false;
            }
        }
        true
    }

    pub fn spelling_eql(&self, other: &Document) -> bool {
        let n = self.node_spelling.len().max(other.node_spelling.len());
        (0..n).all(|i| self.spelling(i as NodeId) == other.spelling(i as NodeId))
    }
}
