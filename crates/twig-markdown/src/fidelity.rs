//! How a tree survives a conversion into Markdown: the table core's
//! diagnostics read.

#![allow(clippy::match_like_matches_macro)]

use twig_kit::ast::{Ast, InlineMark, Kind, NodeId, TextLeafKind};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
#[allow(unused_imports)]
use twig_kit::fidelity::{section_heading, worst};

use Fidelity::{Degraded as D, Dropped as X, Faithful as F};

pub fn markdown_fidelity(kind: &Kind) -> Fidelity {
    match kind {
        Kind::Section => D,
        Kind::RawBlock { .. } => D,
        Kind::Container(_) => D,
        Kind::MarkupLeaf { .. } | Kind::ProcessingInstruction { .. } | Kind::RawInline { .. } => D,
        Kind::SmartPunctuation(_) => D,
        Kind::NonBreakingSpace => D,
        Kind::InlineMark(m) => match m {
            InlineMark::Strong | InlineMark::Emph | InlineMark::Delete => F,
            _ => D,
        },
        Kind::Citation { .. } => D,
        Kind::Substitution { .. } => X,
        Kind::LineBlock | Kind::Line { .. } => D,
        Kind::Column => X,
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim | TextLeafKind::Url | TextLeafKind::Email | TextLeafKind::FootnoteReference => F,
            _ => D,
        },
        _ => F,
    }
}

pub fn markdown_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para
        | Kind::Heading { .. }
        | Kind::ThematicBreak
        | Kind::Section
        | Kind::CodeBlock { .. }
        | Kind::RawBlock { .. }
        | Kind::BlockQuote
        | Kind::BulletList { .. }
        | Kind::OrderedList { .. }
        | Kind::TaskList { .. }
        | Kind::DefinitionList
        | Kind::LineBlock
        | Kind::Table => AttrsFidelity::all(D),
        Kind::Reference { .. } => AttrsFidelity { id: X, class: X, other: X, title: Some(F) },
        Kind::Container(_) => AttrsFidelity::all(D),
        _ => AttrsFidelity::all(X),
    }
}


/// A table with no header row reads back with its first row as the header.
pub fn node_fidelity(ast: &Ast, id: NodeId) -> Fidelity {
    let kind = &ast.nodes[id as usize].kind;
    let base = markdown_fidelity(kind);
    match kind {
        Kind::Table => match ast.table_rows(id).next() {
            Some(r) if !r.head => worst(base, D),
            _ => base,
        },
        _ => base,
    }
}
