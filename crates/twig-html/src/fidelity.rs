//! How a tree survives a conversion into HTML: the table core's
//! diagnostics read.

#![allow(clippy::match_like_matches_macro)]

use twig_kit::ast::{InlineMark, Kind, MarkupLeafKind, TextLeafKind};
use twig_kit::fidelity::{AttrsFidelity, Fidelity};
#[allow(unused_imports)]
use twig_kit::fidelity::{section_heading, worst};

use Fidelity::{Degraded as D, Dropped as X, Faithful as F};

pub fn html_fidelity(kind: &Kind) -> Fidelity {
    match kind {
        Kind::ProcessingInstruction { .. } => F,
        Kind::MarkupLeaf { kind, .. } => match kind {
            MarkupLeafKind::Comment | MarkupLeafKind::Doctype => F,
            MarkupLeafKind::Cdata => D,
        },
        Kind::RawBlock { .. } | Kind::RawInline { .. } => D,
        Kind::Metadata { .. } => D,
        Kind::TaskList { .. } | Kind::TaskListItem { .. } => D,
        Kind::DefinitionList | Kind::DefinitionListItem | Kind::Term | Kind::Definition => D,
        Kind::LineBlock | Kind::Line { .. } => D,
        Kind::Footnote { .. } | Kind::Reference { .. } => D,
        Kind::Citation { .. } => D,
        Kind::Substitution { .. } => X,
        Kind::Column => X,
        Kind::Container(c) => {
            if c.name.is_empty() {
                D
            } else {
                F
            }
        }
        Kind::SmartPunctuation(_) | Kind::NonBreakingSpace => D,
        Kind::InlineMark(m) => match m {
            InlineMark::DoubleQuoted | InlineMark::SingleQuoted => D,
            _ => F,
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim => F,
            _ => D,
        },
        _ => F,
    }
}

pub fn html_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para
        | Kind::Heading { .. }
        | Kind::ThematicBreak
        | Kind::Section
        | Kind::CodeBlock { .. }
        | Kind::BlockQuote
        | Kind::BulletList { .. }
        | Kind::OrderedList { .. }
        | Kind::Table
        | Kind::ListItem
        | Kind::Row { .. }
        | Kind::Cell(_)
        | Kind::Caption
        | Kind::Link(_)
        | Kind::Image(_)
        | Kind::Container(_) => AttrsFidelity::all(F),
        Kind::InlineMark(m) => match m {
            InlineMark::DoubleQuoted | InlineMark::SingleQuoted => AttrsFidelity::all(X),
            _ => AttrsFidelity::all(F),
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim
            | TextLeafKind::InlineMath
            | TextLeafKind::DisplayMath
            | TextLeafKind::Url
            | TextLeafKind::Email
            | TextLeafKind::CitationReference => AttrsFidelity::all(F),
            TextLeafKind::FootnoteReference => AttrsFidelity::icot(X, F, F),
            TextLeafKind::Symb | TextLeafKind::SubstitutionReference => AttrsFidelity::all(X),
        },
        Kind::TaskList { .. } | Kind::DefinitionList | Kind::LineBlock => AttrsFidelity::all(D),
        Kind::HardBreak => AttrsFidelity::all(X),
        _ => AttrsFidelity::all(X),
    }
}

