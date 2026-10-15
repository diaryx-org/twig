//! CSS-lite selectors over the shared AST (`twig query`). Port of
//! `src/ast/select.zig`.
//!
//! `text_of` is here first because the serializers need it; the selector
//! parser and resolver are ported with the editor layer.

use crate::ast::{Ast, Kind, NodeId};

/// The plain-text projection of a subtree.
pub fn text_of(ast: &Ast, id: NodeId) -> Vec<u8> {
    let mut buf = Vec::new();
    text_into(ast, id, &mut buf);
    buf
}

fn text_into(ast: &Ast, id: NodeId, buf: &mut Vec<u8>) {
    match &ast.nodes[id as usize].kind {
        Kind::Str(s) => buf.extend_from_slice(s),
        Kind::TextLeaf { text, .. } => buf.extend_from_slice(text),
        Kind::SmartPunctuation(v) => buf.extend_from_slice(v.ascii().as_bytes()),
        Kind::RawInline { text, .. } => buf.extend_from_slice(text),
        Kind::CodeBlock { text, .. } => buf.extend_from_slice(text),
        Kind::RawBlock { text, .. } => buf.extend_from_slice(text),
        Kind::NonBreakingSpace | Kind::SoftBreak | Kind::HardBreak => buf.push(b' '),
        _ => {
            let mut c = ast.nodes[id as usize].first_child;
            while let Some(cid) = c {
                text_into(ast, cid, buf);
                c = ast.nodes[cid as usize].next_sibling;
            }
        }
    }
}
