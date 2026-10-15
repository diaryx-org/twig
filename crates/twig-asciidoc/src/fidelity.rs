//! How a tree survives a conversion into AsciiDoc: the table core's
//! diagnostics read.

#![allow(clippy::match_like_matches_macro)]

use twig_kit::ast::{Ast, Form, InlineMark, Kind, MarkupLeafKind, NodeId, TextLeafKind};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
#[allow(unused_imports)]
use twig_kit::fidelity::{section_heading, worst};

use Fidelity::{Degraded as D, Dropped as X, Faithful as F};

pub fn asciidoc_fidelity(kind: &Kind) -> Fidelity {
    match kind {
        Kind::MarkupLeaf { kind, .. } => match kind {
            MarkupLeafKind::Comment | MarkupLeafKind::Doctype => X,
            MarkupLeafKind::Cdata => D,
        },
        Kind::ProcessingInstruction { .. } => X,
        Kind::Substitution { .. } => F,
        Kind::Column => X,
        Kind::Metadata { .. } => F,
        Kind::Citation { .. } => D,
        Kind::Container(c) => {
            if is_native_container(&c.name) {
                F
            } else {
                D
            }
        }
        Kind::InlineMark(m) => match m {
            InlineMark::Insert | InlineMark::Delete => D,
            _ => F,
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::DisplayMath | TextLeafKind::Symb | TextLeafKind::CitationReference => D,
            _ => F,
        },
        Kind::Reference { .. } => D,
        _ => F,
    }
}

pub fn is_native_container(name: &[u8]) -> bool {
    const NATIVE: [&[u8]; 12] = [
        b"note",
        b"tip",
        b"important",
        b"warning",
        b"caution",
        b"example",
        b"sidebar",
        b"open",
        b"page-break",
        b"kbd",
        b"abstract",
        b"partintro",
    ];
    NATIVE.contains(&name)
}

pub fn asciidoc_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para
        | Kind::ThematicBreak
        | Kind::CodeBlock { .. }
        | Kind::RawBlock { .. }
        | Kind::BlockQuote
        | Kind::BulletList { .. }
        | Kind::OrderedList { .. }
        | Kind::TaskList { .. }
        | Kind::DefinitionList
        | Kind::LineBlock => AttrsFidelity::all(F),
        Kind::Container(c) => {
            if c.form == Some(Form::InlineText) {
                AttrsFidelity::icot(D, D, X)
            } else {
                AttrsFidelity::all(F)
            }
        }
        Kind::Table => AttrsFidelity { id: F, class: F, other: F, title: Some(D) },
        Kind::Heading { .. } => AttrsFidelity::all(D),
        Kind::Image(_) => AttrsFidelity::all(D),
        Kind::InlineMark(m) => match m {
            InlineMark::Emph | InlineMark::Strong | InlineMark::Superscript | InlineMark::Subscript => {
                AttrsFidelity::icot(F, F, X)
            }
            _ => AttrsFidelity::icot(D, D, X),
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim => AttrsFidelity::icot(F, F, X),
            _ => AttrsFidelity::all(X),
        },
        Kind::Link(_) => AttrsFidelity::icot(X, F, X),
        _ => AttrsFidelity::all(X),
    }
}


/// Metadata is a header only as the document's first block; a section opens
/// with a heading, and a level-1 one reads back as the document title.
pub fn node_fidelity(ast: &Ast, id: NodeId) -> Fidelity {
    let kind = &ast.nodes[id as usize].kind;
    let base = asciidoc_fidelity(kind);
    match kind {
        Kind::Metadata { .. } => {
            worst(base, if ast.nodes[ast.root as usize].first_child == Some(id) { F } else { D })
        }
        Kind::Section => worst(
            base,
            match section_heading(ast, id) {
                None | Some(1) => D,
                Some(_) => F,
            },
        ),
        _ => base,
    }
}
