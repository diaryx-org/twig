//! Bottom-up construction of an [`Ast`] / [`Document`].

use crate::ast::{Ast, Attrs, Kind, Node, NodeId};
use crate::document::{Document, Spelling};
use crate::span::Span;

#[derive(Clone, Debug, Default)]
pub struct Builder {
    pub nodes: Vec<Node>,
    pub attrs: Vec<Attrs>,
    pub attrs_spans: Vec<Option<Span>>,
    pub spans: Vec<Span>,
    pub content_spans: Vec<Option<Span>>,
    pub spellings: Vec<Option<Spelling>>,
    pub marker_spans: Vec<Option<Span>>,
}

impl Builder {
    pub fn new() -> Builder {
        Builder::default()
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    pub fn add_node(&mut self, kind: Kind) -> NodeId {
        let id = self.nodes.len() as NodeId;
        self.nodes.push(Node { id, kind, first_child: None, next_sibling: None, attrs: None });
        self.spans.push(Span::new(0, 0));
        self.content_spans.push(None);
        self.spellings.push(None);
        self.marker_spans.push(None);
        id
    }

    pub fn add_leaf(&mut self, kind: Kind) -> NodeId {
        self.add_node(kind)
    }

    pub fn add_container(&mut self, kind: Kind, ids: &[NodeId]) -> NodeId {
        let id = self.add_node(kind);
        self.set_children(id, ids);
        id
    }

    pub fn set_children(&mut self, parent: NodeId, ids: &[NodeId]) {
        self.nodes[parent as usize].first_child = ids.first().copied();
        if ids.is_empty() {
            return;
        }
        for w in ids.windows(2) {
            self.nodes[w[0] as usize].next_sibling = Some(w[1]);
        }
        self.nodes[*ids.last().unwrap() as usize].next_sibling = None;
    }

    pub fn kind(&self, id: NodeId) -> &Kind {
        &self.nodes[id as usize].kind
    }

    pub fn kind_mut(&mut self, id: NodeId) -> &mut Kind {
        &mut self.nodes[id as usize].kind
    }

    pub fn set_span(&mut self, id: NodeId, span: Span) {
        self.spans[id as usize] = span;
    }

    pub fn span(&self, id: NodeId) -> Span {
        self.spans[id as usize]
    }

    pub fn set_content_span(&mut self, id: NodeId, span: Span) {
        self.content_spans[id as usize] = Some(span);
    }

    pub fn clear_content_span(&mut self, id: NodeId) {
        self.content_spans[id as usize] = None;
    }

    pub fn set_spelling(&mut self, id: NodeId, sp: Spelling) {
        self.spellings[id as usize] = Some(sp);
    }

    pub fn set_marker_span(&mut self, id: NodeId, span: Span) {
        self.marker_spans[id as usize] = Some(span);
    }

    /// Attach `attrs` to `id`. An empty set clears the node's attributes.
    pub fn set_attrs(&mut self, id: NodeId, attrs: Attrs) {
        if attrs.is_empty() {
            self.nodes[id as usize].attrs = None;
            return;
        }
        let idx = self.attrs.len() as u32;
        self.attrs.push(attrs);
        self.attrs_spans.push(None);
        self.nodes[id as usize].attrs = Some(idx);
    }

    pub fn set_attrs_span(&mut self, id: NodeId, span: Span) {
        if let Some(idx) = self.nodes[id as usize].attrs {
            self.attrs_spans[idx as usize] = Some(span);
        }
    }

    pub fn attrs_of(&self, id: NodeId) -> Option<&Attrs> {
        self.nodes[id as usize].attrs.map(|i| &self.attrs[i as usize])
    }

    /// Copy every node of `src` into this builder, shifting its positions by
    /// `offset`. Returns the grafted root.
    pub fn graft_document(&mut self, src: &Document, offset: usize) -> NodeId {
        let base = self.nodes.len() as NodeId;
        for node in &src.ast.nodes {
            let id = self.add_node(node.kind.clone());
            let dst = &mut self.nodes[id as usize];
            dst.first_child = node.first_child.map(|c| base + c);
            dst.next_sibling = node.next_sibling.map(|s| base + s);
            let s = src.node_spans[node.id as usize];
            self.spans[id as usize] = Span::new(s.start + offset, s.end + offset);
            if let Some(cs) = src.node_content_spans[node.id as usize] {
                self.content_spans[id as usize] = Some(Span::new(cs.start + offset, cs.end + offset));
            }
            if let Some(ms) = src.marker_span(node.id) {
                self.marker_spans[id as usize] = Some(Span::new(ms.start + offset, ms.end + offset));
            }
            self.spellings[id as usize] = src.spelling(node.id);
            if let Some(ai) = node.attrs {
                self.set_attrs(id, src.ast.attrs[ai as usize].clone());
                if let Some(a) = src.attrs_span(node.id) {
                    self.set_attrs_span(id, Span::new(a.start + offset, a.end + offset));
                }
            }
        }
        base + src.ast.root
    }

    /// Deep-copy the subtree rooted at `id` of a bare tree (no positions).
    pub fn graft_subtree(&mut self, src: &Ast, id: NodeId) -> NodeId {
        let node = &src.nodes[id as usize];
        let out = self.add_node(node.kind.clone());
        if let Some(ai) = node.attrs {
            self.set_attrs(out, src.attrs[ai as usize].clone());
        }
        let mut prev: Option<NodeId> = None;
        let mut child = node.first_child;
        while let Some(c) = child {
            let cloned = self.graft_subtree(src, c);
            match prev {
                Some(p) => self.nodes[p as usize].next_sibling = Some(cloned),
                None => self.nodes[out as usize].first_child = Some(cloned),
            }
            prev = Some(cloned);
            child = src.nodes[c as usize].next_sibling;
        }
        out
    }

    /// The bare tree, positions discarded.
    pub fn finish(self, root: NodeId) -> Ast {
        Ast { root, nodes: self.nodes, attrs: self.attrs }
    }

    pub fn finish_document(self, source: &[u8], root: NodeId) -> Document {
        Document {
            source: source.to_vec(),
            ast: Ast { root, nodes: self.nodes, attrs: self.attrs },
            node_spans: self.spans,
            node_content_spans: self.content_spans,
            node_spelling: self.spellings,
            node_marker_spans: self.marker_spans,
            attrs_spans: self.attrs_spans,
            labels: Default::default(),
        }
    }

    /// A borrowed view of the in-progress tree (cloned — Rust has no cheap
    /// borrowed `Ast`; use sparingly).
    pub fn view(&self, root: NodeId) -> Ast {
        Ast { root, nodes: self.nodes.clone(), attrs: self.attrs.clone() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{InlineMark, KeyVal};

    #[test]
    fn constructs_small_tree() {
        let mut b = Builder::new();
        let s1 = b.add_leaf(Kind::Str(b"hello ".to_vec()));
        let t = b.add_leaf(Kind::Str(b"world".to_vec()));
        let em = b.add_container(Kind::InlineMark(InlineMark::Emph), &[t]);
        let para = b.add_container(Kind::Para, &[s1, em]);
        let ast = b.finish(para);
        assert_eq!(ast.root, para);
        assert_eq!(ast.nodes[s1 as usize].next_sibling, Some(em));
    }

    #[test]
    fn graft_document_shifts_spans() {
        let mut donor = Builder::new();
        let inner = donor.add_leaf(Kind::Str(b"hi".to_vec()));
        donor.set_span(inner, Span::new(3, 5));
        let el = donor.add_container(Kind::Container(crate::ast::Container::named(b"b")), &[inner]);
        donor.set_span(el, Span::new(0, 8));
        donor.set_attrs(el, Attrs { entries: vec![KeyVal::new(b"id", Some(b"x"))] });
        let d = donor.finish_document(b"<b id=x>hi</b>", el);
        let mut host = Builder::new();
        let g = host.graft_document(&d, 100);
        let para = host.add_container(Kind::Para, &[g]);
        let doc = host.finish_document(b"", para);
        let b_el = doc.ast.nodes[doc.ast.root as usize].first_child.unwrap();
        assert_eq!(doc.ast.attrs_of(b_el).get(b"id"), Some(&b"x"[..]));
        assert_eq!(doc.span(b_el), Span::new(100, 108));
    }
}
