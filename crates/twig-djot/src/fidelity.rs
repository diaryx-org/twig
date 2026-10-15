//! How a tree survives a conversion into Djot: the table core's
//! diagnostics read.

#![allow(clippy::match_like_matches_macro)]

use twig_kit::ast::{Ast, Form, Kind, NodeId, TextLeafKind};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
#[allow(unused_imports)]
use twig_kit::fidelity::{section_heading, worst};

use Fidelity::{Degraded as D, Dropped as X, Faithful as F};

pub fn djot_fidelity(kind: &Kind) -> Fidelity {
    match kind {
        Kind::MarkupLeaf { .. } | Kind::ProcessingInstruction { .. } => X,
        Kind::Substitution { .. } => X,
        Kind::Column => X,
        Kind::Metadata { .. } => D,
        Kind::DefinitionList => D,
        Kind::LineBlock | Kind::Line { .. } => F,
        Kind::Citation { .. } => D,
        Kind::Container(c) => {
            if c.name.is_empty() {
                F
            } else {
                D
            }
        }
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::CitationReference | TextLeafKind::SubstitutionReference => D,
            _ => F,
        },
        _ => F,
    }
}

pub fn djot_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para | Kind::Container(_) | Kind::Reference { .. } | Kind::Section => AttrsFidelity::all(F),
        Kind::Heading { .. } => AttrsFidelity::all(D),
        Kind::LineBlock => AttrsFidelity::all(F),
        _ => AttrsFidelity::all(X),
    }
}


/// A section that opens with no heading cannot be spelled; an anonymous
/// inline container spells only with attributes.
pub fn node_fidelity(ast: &Ast, id: NodeId) -> Fidelity {
    let kind = &ast.nodes[id as usize].kind;
    let base = djot_fidelity(kind);
    match kind {
        Kind::Section => worst(base, if section_heading(ast, id).is_none() { D } else { F }),
        Kind::Container(c) => {
            if c.form != Some(Form::InlineText) || !c.name.is_empty() || !ast.attrs_of(id).is_empty() {
                base
            } else {
                worst(base, X)
            }
        }
        _ => base,
    }
}

pub fn node_attrs_fidelity(ast: &Ast, id: NodeId) -> AttrsFidelity {
    let kind = &ast.nodes[id as usize].kind;
    match kind {
        Kind::Section if section_heading(ast, id).is_none() => AttrsFidelity::all(X),
        _ => djot_attrs_fidelity(kind),
    }
}
