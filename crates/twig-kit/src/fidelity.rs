//! What a conversion keeps: how much of a node, and of its attributes,
//! survives a round trip through a language. A language states it as a
//! table (`Language::fidelity` and its siblings); one that states none is
//! measured by core's probes.

use crate::ast::{Ast, Kind, NodeId};

/// How much of a node survives a round trip through a target format.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Fidelity {
    /// The target spells the kind, and reparses that spelling back to it.
    Faithful,
    /// Something is emitted, but it reads back as a DIFFERENT kind.
    Degraded,
    /// Nothing is emitted at all.
    Dropped,
}

impl Fidelity {
    pub fn is_lossy(self) -> bool {
        self != Fidelity::Faithful
    }
    pub fn name(self) -> &'static str {
        match self {
            Fidelity::Faithful => "faithful",
            Fidelity::Degraded => "degraded",
            Fidelity::Dropped => "dropped",
        }
    }
}

/// The more severe of two answers.
pub fn worst(a: Fidelity, b: Fidelity) -> Fidelity {
    a.max(b)
}


/// How a node's attributes survive, by key class.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AttrsFidelity {
    pub id: Fidelity,
    pub class: Fidelity,
    pub other: Fidelity,
    /// `title`, where it differs from `other`.
    pub title: Option<Fidelity>,
}

impl AttrsFidelity {
    pub const fn all(f: Fidelity) -> AttrsFidelity {
        AttrsFidelity { id: f, class: f, other: f, title: None }
    }

    pub const fn icot(id: Fidelity, class: Fidelity, other: Fidelity) -> AttrsFidelity {
        AttrsFidelity { id, class, other, title: None }
    }

    pub fn under(self, node: Fidelity) -> AttrsFidelity {
        if node == F {
            return self;
        }
        AttrsFidelity {
            id: worst(self.id, node),
            class: worst(self.class, node),
            other: worst(self.other, node),
            title: self.title.map(|t| worst(t, node)),
        }
    }

    pub fn for_key(&self, key: &[u8]) -> Fidelity {
        match key {
            b"id" => self.id,
            b"class" => self.class,
            b"title" => self.title.unwrap_or(self.other),
            _ => self.other,
        }
    }
}


use Fidelity::Faithful as F;

/// The level of the heading a section opens with, if it opens with one.
pub fn section_heading(ast: &Ast, id: NodeId) -> Option<u32> {
    let first = ast.nodes[id as usize].first_child?;
    match ast.nodes[first as usize].kind {
        Kind::Heading { level } => Some(level),
        _ => None,
    }
}
