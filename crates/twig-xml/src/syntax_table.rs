//! XML's surface spelling. Port of `src/languages/xml/syntax.zig`.
//!
//! XML authors nothing a caret editor makes — `authorable()` is false — but a
//! tree-shaped editor (a canvas over an SVG) needs exactly one thing: the
//! spelling of an element's own attributes, so a change to them splices the
//! start tag and nothing else. That is the one claim this table makes, and
//! `Editor::set_node_attrs` is the one gesture it opens. Inserting, deleting
//! and reordering an element need no spelling: the splicer's node ops take
//! the bytes the caller hands them, and an XML fragment is its own spelling.

use twig_kit::syntax::{NodeAttrs, Syntax};

pub static TABLE: Syntax = Syntax { node_attrs: Some(NodeAttrs { open: b"<" }), ..Syntax::NONE };

pub fn table() -> &'static Syntax {
    &TABLE
}

#[cfg(test)]
mod tests {
    #[test]
    fn xml_spells_only_node_attrs() {
        let t = super::table();
        assert!(!t.authorable());
        assert!(t.node_attrs.is_some());
        t.assert_coherent();
    }
}
