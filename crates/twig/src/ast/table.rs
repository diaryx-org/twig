//! The node table: a `Document` written down as flat pre-order rows (`twig
//! convert -o table`), and read back. See `ast/table.zig`.

use crate::ast::json::write_kind_payload;
use crate::ast::{Ast, Builder, Kind, NodeId};
use crate::document::{Document, Labels};
use crate::json::Stringify;

#[derive(Clone, Copy, Debug)]
pub struct Options {
    /// One row to a line. Off, the whole table is one line.
    pub pretty: bool,
    /// Whether rows carry their spans.
    pub positions: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options { pretty: true, positions: true }
    }
}

/// Which of `Labels`' three maps a label row belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Registry {
    Reference,
    AutoReference,
    Footnote,
}

impl Registry {
    pub fn name(self) -> &'static str {
        match self {
            Registry::Reference => "reference",
            Registry::AutoReference => "auto_reference",
            Registry::Footnote => "footnote",
        }
    }
}

pub fn encode(doc: &Document, options: Options) -> Vec<u8> {
    let mut out = Vec::new();
    let row_sep: &[u8] = if options.pretty { b"\n    " } else { b"" };
    let parents = doc.ast.parents();

    out.extend_from_slice(if options.pretty { b"{\n  \"nodes\": [" } else { b"{\"nodes\":[" });
    for (i, n) in doc.ast.nodes.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.extend_from_slice(row_sep);
        let mut w = Stringify::compact(&mut out);
        write_row(&mut w, doc, n.id, parents[i], options.positions);
    }
    out.extend_from_slice(if options.pretty { b"\n  ],\n  \"labels\": [" } else { b"],\"labels\":[" });

    let mut labels: Vec<(Registry, &[u8], NodeId)> = Vec::new();
    for (map, reg) in doc.labels.maps().into_iter().zip([Registry::Reference, Registry::AutoReference, Registry::Footnote]) {
        for (k, v) in map {
            labels.push((reg, k.as_slice(), *v));
        }
    }
    // Sorted by node, then registry. Ties (same node, same registry) cannot
    // occur within one map except by distinct labels, which sort by label for
    // determinism.
    labels.sort_by(|a, b| a.2.cmp(&b.2).then(a.0.cmp(&b.0)).then(a.1.cmp(b.1)));
    for (i, (reg, label, node)) in labels.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.extend_from_slice(row_sep);
        let mut w = Stringify::compact(&mut out);
        w.begin_object();
        w.field("registry");
        w.str(reg.name().as_bytes());
        w.field("label");
        w.str(label);
        w.field("node");
        w.int(*node);
        w.end_object();
    }
    if options.pretty && !labels.is_empty() {
        out.extend_from_slice(b"\n  ");
    }
    out.extend_from_slice(if options.pretty { b"]\n}\n" } else { b"]}" });
    out
}

fn write_span(w: &mut Stringify, s: crate::span::Span) {
    w.begin_array();
    w.int(s.start as u64);
    w.int(s.end as u64);
    w.end_array();
}

fn write_row(w: &mut Stringify, doc: &Document, id: NodeId, parent: Option<NodeId>, positions: bool) {
    let n = &doc.ast.nodes[id as usize];
    w.begin_object();
    w.field("kind");
    w.str(n.kind.kind_name().as_bytes());
    w.field("parent");
    w.opt_int(parent);
    if positions {
        w.field("span");
        write_span(w, doc.span(id));
        if let Some(s) = doc.content_span(id) {
            w.field("content_span");
            write_span(w, s);
        }
        if let Some(s) = doc.marker_span(id) {
            w.field("marker_span");
            write_span(w, s);
        }
    }
    if let Some(sp) = doc.spelling(id) {
        let (f, v) = sp.names();
        w.field("spelling");
        w.begin_object();
        w.field(f);
        w.str(v.as_bytes());
        w.end_object();
    }
    write_kind_payload(w, &n.kind);
    let attrs = doc.ast.attrs_of(id);
    if !attrs.is_empty() {
        w.field("attrs");
        crate::ast::json::write_attrs(w, attrs);
        if positions {
            if let Some(s) = doc.attrs_span(id) {
                w.field("attrs_span");
                write_span(w, s);
            }
        }
    }
    w.end_object();
}

/// The table of a bare `Ast` — no positions, no spelling, labels rebuilt by
/// `Labels::index`. Rows are the tree renumbered into pre-order (the root's,
/// then each detached definition's).
pub fn encode_ast(ast: &Ast, options: Options) -> Vec<u8> {
    let mut b = Builder::new();
    let root = b.graft_subtree(ast, ast.root);
    for id in ast.definition_roots() {
        if matches!(
            ast.nodes[id as usize].kind,
            Kind::Reference { .. } | Kind::Footnote { .. } | Kind::Citation { .. } | Kind::Substitution { .. }
        ) {
            b.graft_subtree(ast, id);
        }
    }
    let tree = b.finish(root);
    let labels = Labels::index(&tree);
    let mut doc = Document::from_ast(b"", tree);
    doc.labels = labels;
    encode(&doc, Options { positions: false, ..options })
}
