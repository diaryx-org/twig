//! Canonicalize a document's arena: renumber the nodes reachable from the root
//! (and from the label tables) into pre-order, dropping everything else.

use crate::ast::{Node, NodeId};
use crate::document::Document;

pub fn run(mut doc: Document) -> Document {
    let old = std::mem::take(&mut doc.ast.nodes);
    let n = old.len();
    let mut map: Vec<Option<NodeId>> = vec![None; n];

    let mut nodes: Vec<Node> = Vec::with_capacity(n);
    let mut spans = Vec::with_capacity(n);
    let mut content_spans = Vec::with_capacity(n);
    let mut spellings = Vec::with_capacity(n);
    let mut marker_spans = Vec::with_capacity(n);

    let mut extra: Vec<NodeId> = Vec::new();
    for m in doc.labels.maps() {
        extra.extend(m.values().copied());
    }
    extra.sort_unstable();

    let mut stack: Vec<NodeId> = Vec::new();
    let mut visit = |root: NodeId,
                     map: &mut Vec<Option<NodeId>>,
                     nodes: &mut Vec<Node>,
                     stack: &mut Vec<NodeId>| {
        stack.clear();
        stack.push(root);
        while let Some(id) = stack.pop() {
            if map[id as usize].is_some() {
                continue;
            }
            let new_id = nodes.len() as NodeId;
            map[id as usize] = Some(new_id);
            let mut node = old[id as usize].clone();
            node.id = new_id;
            nodes.push(node);
            spans.push(doc.node_spans[id as usize]);
            content_spans.push(doc.node_content_spans[id as usize]);
            spellings.push(doc.spelling(id));
            marker_spans.push(doc.marker_span(id));

            let mut kids = Vec::new();
            let mut c = old[id as usize].first_child;
            while let Some(cid) = c {
                kids.push(cid);
                c = old[cid as usize].next_sibling;
            }
            for &k in kids.iter().rev() {
                stack.push(k);
            }
        }
    };

    let root = doc.ast.root;
    visit(root, &mut map, &mut nodes, &mut stack);
    for r in extra {
        if (r as usize) >= n || map[r as usize].is_some() {
            continue;
        }
        visit(r, &mut map, &mut nodes, &mut stack);
    }

    for m in doc.labels.maps_mut() {
        for v in m.values_mut() {
            *v = map[*v as usize].expect("label points at a live node");
        }
    }
    for node in nodes.iter_mut() {
        if let Some(c) = node.first_child {
            node.first_child = map[c as usize];
        }
        if let Some(s) = node.next_sibling {
            node.next_sibling = map[s as usize];
        }
    }

    doc.ast.nodes = nodes;
    doc.ast.root = map[root as usize].unwrap();
    doc.node_spans = spans;
    doc.node_content_spans = content_spans;
    doc.node_spelling = spellings;
    doc.node_marker_spans = marker_spans;
    doc
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Builder, InlineMark, Kind};
    use crate::span::Span;

    #[test]
    fn drops_orphans_and_renumbers() {
        let mut b = Builder::new();
        let kept = b.add_leaf(Kind::Str(b"x".to_vec()));
        b.set_span(kept, Span::new(2, 3));
        let _orphan = b.add_leaf(Kind::Str(b"**".to_vec()));
        let para = b.add_container(Kind::Para, &[kept]);
        let out = run(b.finish_document(b"**x", para));
        assert_eq!(out.ast.nodes.len(), 2);
        assert_eq!(out.ast.root, 0);
        assert_eq!(out.span(1), Span::new(2, 3));
    }

    #[test]
    fn document_order() {
        let mut b = Builder::new();
        let a = b.add_leaf(Kind::Str(b"a".to_vec()));
        let c1 = b.add_leaf(Kind::Str(b"c".to_vec()));
        let em = b.add_container(Kind::InlineMark(InlineMark::Emph), &[c1]);
        let para = b.add_container(Kind::Para, &[a, em]);
        let root = b.add_container(Kind::Doc, &[para]);
        let out = run(b.finish_document(b"a _c_", root));
        assert_eq!(out.ast.nodes[1].kind, Kind::Para);
        assert_eq!(out.ast.nodes[4].kind, Kind::Str(b"c".to_vec()));
    }

    #[test]
    fn labelled_definition_survives() {
        let mut b = Builder::new();
        b.add_leaf(Kind::Str(b"__".to_vec()));
        let para = b.add_container(Kind::Para, &[]);
        let def = b.add_leaf(Kind::Reference { label: b"ref".to_vec(), destination: b"/url".to_vec() });
        let mut doc = b.finish_document(b"", para);
        doc.labels.references.insert(b"ref".to_vec(), def);
        let out = run(doc);
        assert_eq!(out.ast.nodes.len(), 2);
        assert_eq!(out.labels.reference(b"ref"), Some(1));
    }
}
