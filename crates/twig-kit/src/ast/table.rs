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

// ── decode ──────────────────────────────────────────────────────────────────

/// Why a table was refused. `row` is the node id, `None` for a problem with the
/// table as a whole; `field` is the key at fault, empty when none is.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Problem {
    pub row: Option<usize>,
    pub field: String,
    pub what: String,
}

impl Problem {
    pub fn render(&self) -> String {
        let mut s = String::new();
        if let Some(r) = self.row {
            s.push_str(&format!("row {r}: "));
        }
        if !self.field.is_empty() {
            s.push_str(&format!("{}: ", self.field));
        }
        s.push_str(&self.what);
        s
    }
}

impl std::fmt::Display for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.render())
    }
}

fn fail<T>(row: Option<usize>, field: &str, what: &str) -> Result<T, Problem> {
    Err(Problem { row, field: field.to_string(), what: what.to_string() })
}

use crate::json::Value;
use crate::span::Span;
use crate::ast::{Attrs, KeyVal, KindRef};
use crate::document::Spelling;

/// Read a table from its JSON text into a `Document` over `source`.
pub fn decode(source: &[u8], text: &[u8]) -> Result<Document, Problem> {
    let Ok(value) = crate::json::parse(text) else { return fail(None, "", "not a JSON document") };
    from_value(source, &value)
}

/// Read a table written without positions — what a print receives. Its root
/// may be any kind.
pub fn decode_bare(text: &[u8]) -> Result<Document, Problem> {
    let Ok(value) = crate::json::parse(text) else { return fail(None, "", "not a JSON document") };
    read(b"", &value, false)
}

/// `decode` over an already-parsed JSON value.
pub fn from_value(source: &[u8], value: &Value) -> Result<Document, Problem> {
    read(source, value, true)
}

fn read(source: &[u8], top: &Value, positions: bool) -> Result<Document, Problem> {
    if top.as_object().is_none() {
        return fail(None, "", "a table is an object with a \"nodes\" array");
    }
    let rows = match top.get("nodes") {
        None => return fail(None, "nodes", "missing"),
        Some(Value::Array(a)) => a,
        Some(_) => return fail(None, "nodes", "expected an array"),
    };
    if rows.is_empty() {
        return fail(None, "nodes", "a table has at least its root");
    }
    if rows.len() > u32::MAX as usize {
        return fail(None, "nodes", "too many rows");
    }

    let mut b = Builder::new();
    let mut parents: Vec<Option<NodeId>> = Vec::with_capacity(rows.len());
    for (i, row) in rows.iter().enumerate() {
        if row.as_object().is_none() {
            return fail(Some(i), "", "a row is an object");
        }
        let name = match row.get("kind") {
            None => return fail(Some(i), "kind", "missing"),
            Some(Value::String(s)) => String::from_utf8_lossy(s).into_owned(),
            Some(_) => return fail(Some(i), "kind", "expected a published kind name"),
        };
        let Some(r) = KindRef::from_name(&name) else { return fail(Some(i), "kind", "not a published kind name") };
        let kind = match crate::ast::json::read_kind(&r, row) {
            Ok(k) => k,
            Err(fp) => return fail(Some(i), &fp.field, &fp.what),
        };
        let id = b.add_node(kind);
        parents.push(opt_index(i, row, "parent", rows.len())?);
        if positions {
            match opt_span(i, row, "span")? {
                Some(s) => b.set_span(id, s),
                None => return fail(Some(i), "span", "missing"),
            }
            if let Some(s) = opt_span(i, row, "content_span")? {
                b.set_content_span(id, s);
            }
            if let Some(s) = opt_span(i, row, "marker_span")? {
                b.set_marker_span(id, s);
            }
        }
        if let Some(sp) = read_spelling(i, row)? {
            b.set_spelling(id, sp);
        }
        read_attrs(i, row, &mut b, id, positions)?;
    }

    check_order(&b, &parents, positions)?;

    let mut firsts: Vec<Vec<NodeId>> = vec![Vec::new(); rows.len()];
    for (i, parent) in parents.iter().enumerate() {
        if let Some(p) = parent {
            firsts[*p as usize].push(i as NodeId);
        }
    }
    for (i, list) in firsts.iter().enumerate() {
        b.set_children(i as NodeId, list);
    }

    let mut doc = b.finish_document(source, 0);
    doc.labels = match top.get("labels") {
        None | Some(Value::Null) => Labels::index(&doc.ast),
        Some(Value::Array(a)) => read_labels(&doc.ast, a)?,
        Some(_) => return fail(None, "labels", "expected an array"),
    };
    check_columns(&doc)?;
    Ok(doc)
}

fn opt_index(i: usize, row: &Value, field: &str, len: usize) -> Result<Option<NodeId>, Problem> {
    match row.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Int(n)) => {
            if *n >= 0 && (*n as usize) < len {
                Ok(Some(*n as NodeId))
            } else {
                fail(Some(i), field, "not a row of this table")
            }
        }
        Some(_) => fail(Some(i), field, "expected a row index or null"),
    }
}

fn opt_span(i: usize, row: &Value, field: &str) -> Result<Option<Span>, Problem> {
    let pair = match row.get(field) {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Array(a)) => a,
        Some(_) => return fail(Some(i), field, "expected [start, end]"),
    };
    if pair.len() != 2 {
        return fail(Some(i), field, "expected [start, end]");
    }
    let mut ends = [0usize; 2];
    for (x, e) in pair.iter().zip(ends.iter_mut()) {
        *e = match x {
            Value::Int(n) if *n >= 0 => *n as usize,
            Value::Int(_) => return fail(Some(i), field, "a byte offset is not negative"),
            _ => return fail(Some(i), field, "expected [start, end]"),
        };
    }
    Ok(Some(Span::new(ends[0], ends[1])))
}

fn read_spelling(i: usize, row: &Value) -> Result<Option<Spelling>, Problem> {
    let obj = match row.get("spelling") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(o)) => o,
        Some(_) => return fail(Some(i), "spelling", "expected an object of one key"),
    };
    if obj.len() != 1 {
        return fail(Some(i), "spelling", "expected an object of one key");
    }
    let key = String::from_utf8_lossy(&obj[0].0).into_owned();
    let name = match &obj[0].1 {
        Value::String(s) => String::from_utf8_lossy(s).into_owned(),
        _ => return fail(Some(i), "spelling", "expected a name"),
    };
    if !matches!(key.as_str(), "bullet" | "ordered_delim" | "container_origin" | "highlight_prefix") {
        return fail(Some(i), "spelling", "not a spelling");
    }
    match Spelling::from_names(&key, &name) {
        Some(s) => Ok(Some(s)),
        None => fail(Some(i), "spelling", "not one of the names this spelling takes"),
    }
}

fn read_attrs(i: usize, row: &Value, b: &mut Builder, id: NodeId, positions: bool) -> Result<(), Problem> {
    let items: &[Value] = match row.get("attrs") {
        None | Some(Value::Null) => &[],
        Some(Value::Array(a)) => a,
        Some(_) => return fail(Some(i), "attrs", "expected an array of {key, value}"),
    };
    let mut entries = Vec::with_capacity(items.len());
    for item in items {
        if item.as_object().is_none() {
            return fail(Some(i), "attrs", "expected an array of {key, value}");
        }
        let key = match item.get("key") {
            Some(Value::String(s)) => s.clone(),
            _ => return fail(Some(i), "attrs", "an entry's key is a string"),
        };
        let value = match item.get("value") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            Some(_) => return fail(Some(i), "attrs", "an entry's value is a string or null"),
        };
        entries.push(KeyVal { key, value });
    }
    let n = entries.len();
    b.set_attrs(id, Attrs { entries });
    if !positions {
        return Ok(());
    }
    if let Some(s) = opt_span(i, row, "attrs_span")? {
        if n == 0 {
            return fail(Some(i), "attrs_span", "a node with no attrs has no attrs span");
        }
        b.set_attrs_span(id, s);
    }
    Ok(())
}

fn check_order(b: &Builder, parents: &[Option<NodeId>], parsed: bool) -> Result<(), Problem> {
    if parents[0].is_some() {
        return fail(Some(0), "parent", "the first row is the root and has no parent");
    }
    if parsed && b.nodes[0].kind != Kind::Doc {
        return fail(Some(0), "kind", "the root of a parse is a doc");
    }
    let mut path: Vec<NodeId> = vec![0];
    for (i, parent) in parents.iter().enumerate().skip(1) {
        match parent {
            Some(par) => {
                while path.last().is_some_and(|l| l != par) {
                    path.pop();
                }
                if path.is_empty() {
                    return fail(
                        Some(i),
                        "parent",
                        "rows are in pre-order: a parent comes before its children, and a sibling's subtree before the next sibling",
                    );
                }
            }
            None => {
                if !matches!(
                    b.nodes[i].kind,
                    Kind::Reference { .. } | Kind::Footnote { .. } | Kind::Citation { .. } | Kind::Substitution { .. }
                ) {
                    return fail(Some(i), "parent", "only a definition stands outside the root's tree");
                }
                path.clear();
            }
        }
        path.push(i as NodeId);
    }
    Ok(())
}

fn read_labels(ast: &Ast, items: &[Value]) -> Result<Labels, Problem> {
    let mut labels = Labels::default();
    for item in items {
        if item.as_object().is_none() {
            return fail(None, "labels", "expected an array of {registry, label, node}");
        }
        let registry = match item.get("registry").and_then(|v| v.as_str()) {
            Some(b"reference") => Registry::Reference,
            Some(b"auto_reference") => Registry::AutoReference,
            Some(b"footnote") => Registry::Footnote,
            _ => return fail(None, "labels", "registry is reference, auto_reference or footnote"),
        };
        let node = match item.get("node") {
            Some(Value::Int(n)) => {
                if *n >= 0 && (*n as usize) < ast.nodes.len() {
                    *n as NodeId
                } else {
                    return fail(None, "labels", "node is not a row of this table");
                }
            }
            _ => return fail(None, "labels", "node is a row index"),
        };
        let row = Some(node as usize);
        let own: Vec<u8> = match &ast.nodes[node as usize].kind {
            Kind::Reference { label, .. } => {
                if registry != Registry::Footnote {
                    label.clone()
                } else {
                    return fail(row, "labels", "a reference is labelled in the reference registries");
                }
            }
            Kind::Footnote { label } => {
                if registry == Registry::Footnote {
                    label.clone()
                } else {
                    return fail(row, "labels", "a footnote is labelled in the footnote registry");
                }
            }
            _ => return fail(row, "labels", "only a reference or a footnote is labelled"),
        };
        let label = match item.get("label") {
            Some(Value::String(s)) => s,
            _ => return fail(row, "labels", "label is a string"),
        };
        if *label != own {
            return fail(row, "labels", "label differs from the definition's own");
        }
        let map = match registry {
            Registry::Reference => &mut labels.references,
            Registry::AutoReference => &mut labels.auto_references,
            Registry::Footnote => &mut labels.footnotes,
        };
        map.insert(own, node);
    }
    Ok(labels)
}

/// The shape every `Document` the engine receives must have, whoever built it.
pub fn check_columns(doc: &Document) -> Result<(), Problem> {
    let n = doc.ast.nodes.len();
    if doc.node_spans.len() != n {
        return fail(None, "span", "one per node");
    }
    if doc.node_content_spans.len() != n {
        return fail(None, "content_span", "one per node");
    }
    if doc.node_spelling.len() > n {
        return fail(None, "spelling", "at most one per node");
    }
    if doc.node_marker_spans.len() > n {
        return fail(None, "marker_span", "at most one per node");
    }
    if doc.attrs_spans.len() > doc.ast.attrs.len() {
        return fail(None, "attrs_span", "at most one per attribute set");
    }
    let len = doc.source.len();
    for (i, s) in doc.node_spans.iter().enumerate() {
        check_span(i, "span", *s, len)?;
    }
    for (i, s) in doc.node_content_spans.iter().enumerate() {
        if let Some(s) = s {
            check_span(i, "content_span", *s, len)?;
        }
    }
    for (i, s) in doc.node_marker_spans.iter().enumerate() {
        let Some(s) = s else { continue };
        check_span(i, "marker_span", *s, len)?;
        // A leading marker: a list or task item's, a heading's `#`s, a quote's
        // `>`, an AsciiDoc admonition's label, a coloured Markdown highlight's
        // emoji (`==🔴 x==` — spelling a rich view hides).
        let allowed = match &doc.ast.nodes[i].kind {
            Kind::ListItem | Kind::TaskListItem { .. } | Kind::DefinitionListItem | Kind::Heading { .. } | Kind::BlockQuote => {
                true
            }
            Kind::InlineMark(m) => *m == crate::ast::InlineMark::Mark,
            Kind::Container(c) => {
                c.form == Some(crate::ast::Form::BlockFenced)
                    && doc.container_origin(i as NodeId) == Some(crate::document::ContainerOrigin::Directive)
            }
            _ => false,
        };
        if !allowed {
            return fail(Some(i), "marker_span", "this kind carries no leading marker");
        }
    }
    for (ai, s) in doc.attrs_spans.iter().enumerate() {
        let Some(s) = s else { continue };
        let Some(owner) = doc.ast.nodes.iter().find(|nd| nd.attrs == Some(ai as u32)).map(|nd| nd.id) else {
            return fail(None, "attrs_span", "an attrs span with no node holding its attrs");
        };
        check_span(owner as usize, "attrs_span", *s, len)?;
    }
    Ok(())
}

fn check_span(i: usize, field: &str, s: Span, len: usize) -> Result<(), Problem> {
    if s.start > s.end {
        return fail(Some(i), field, "start is after end");
    }
    if s.end > len {
        return fail(Some(i), field, "ends past the source");
    }
    Ok(())
}

/// Every column `decode(encode(doc))` must give back. A test helper the
/// language harnesses share.
pub fn expect_identity(doc: &Document) {
    let text = encode(doc, Options { pretty: false, positions: true });
    let back = decode(&doc.source, &text).unwrap_or_else(|p| panic!("table refused: {p}"));
    assert!(doc.ast.eql(&back.ast), "tree differs after a table round trip");
    assert!(doc.spelling_eql(&back), "spelling differs after a table round trip");
    for i in 0..doc.ast.nodes.len() as NodeId {
        assert_eq!(doc.span(i), back.span(i));
        assert_eq!(doc.content_span(i), back.content_span(i));
        assert_eq!(doc.marker_span(i), back.marker_span(i));
        assert_eq!(doc.attrs_span(i), back.attrs_span(i));
    }
    for (x, y) in doc.labels.maps().into_iter().zip(back.labels.maps()) {
        assert_eq!(x, y);
    }
    let again = encode(&back, Options { pretty: false, positions: true });
    assert_eq!(text, again);
    let pretty = encode(&back, Options::default());
    let reread = decode(&doc.source, &pretty).expect("pretty table decodes");
    assert!(doc.ast.eql(&reread.ast));
    let bare = encode(doc, Options { pretty: true, positions: false });
    let tree = decode_bare(&bare).expect("bare table decodes");
    assert!(doc.ast.eql(&tree.ast));
    assert!(doc.spelling_eql(&tree));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{InlineMark, compact};
    use crate::document::Bullet;

    #[test]
    fn built_document_crosses_and_comes_back() {
        let src = b"- *a* b";
        let mut b = Builder::new();
        let a = b.add_leaf(Kind::Str(b"a".to_vec()));
        b.set_span(a, Span::new(3, 4));
        let em = b.add_container(Kind::InlineMark(InlineMark::Strong), &[a]);
        b.set_span(em, Span::new(2, 5));
        b.set_content_span(em, Span::new(3, 4));
        let t = b.add_leaf(Kind::Str(b" b".to_vec()));
        b.set_span(t, Span::new(5, 7));
        let para = b.add_container(Kind::Para, &[em, t]);
        b.set_span(para, Span::new(2, 7));
        let item = b.add_container(Kind::ListItem, &[para]);
        b.set_span(item, Span::new(0, 7));
        b.set_marker_span(item, Span::new(0, 2));
        let list = b.add_container(Kind::BulletList { tight: true }, &[item]);
        b.set_span(list, Span::new(0, 7));
        b.set_spelling(list, Spelling::Bullet(Bullet::Dash));
        b.set_attrs(list, Attrs { entries: vec![KeyVal::new(b"class", Some(b"x")), KeyVal::new(b"hidden", None)] });
        let doc_id = b.add_container(Kind::Doc, &[list]);
        b.set_span(doc_id, Span::new(0, 7));
        let doc = compact::run(b.finish_document(src, doc_id));
        expect_identity(&doc);
    }


    fn refused(src: &[u8], text: &str, row: Option<usize>, field: &str) {
        let p = decode(src, text.as_bytes()).expect_err("table should be refused");
        assert_eq!(p.row, row, "{text}: {p}");
        assert_eq!(p.field, field, "{text}: {p}");
    }

    #[test]
    fn decode_names_what_it_refuses() {
        refused(b"", "[", None, "");
        refused(b"", "{}", None, "nodes");
        refused(b"", "{\"nodes\":[]}", None, "nodes");
        refused(b"", "{\"nodes\":[{\"kind\":\"para\",\"span\":[0,0]}]}", Some(0), "kind");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\"}]}", Some(0), "span");
        refused(b"ab", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,3]}]}", Some(0), "span");
        refused(b"ab", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[2,1]}]}", Some(0), "span");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"paragraph\",\"parent\":0,\"span\":[0,0]}]}", Some(1), "kind");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"heading\",\"parent\":0,\"span\":[0,0]}]}", Some(1), "level");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"para\",\"span\":[0,0]}]}", Some(1), "parent");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"para\",\"parent\":5,\"span\":[0,0]}]}", Some(1), "parent");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"para\",\"parent\":0,\"span\":[0,0],\"marker_span\":[0,0]}]}", Some(1), "marker_span");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0],\"attrs_span\":[0,0]}]}", Some(0), "attrs_span");
        refused(b"", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"bullet_list\",\"tight\":true,\"parent\":0,\"span\":[0,0],\"spelling\":{\"bullet\":\"tilde\"}}]}", Some(1), "spelling");
        refused(
            b"",
            "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},\n {\"kind\":\"para\",\"parent\":0,\"span\":[0,0]},\n {\"kind\":\"para\",\"parent\":0,\"span\":[0,0]},\n {\"kind\":\"str\",\"text\":\"x\",\"parent\":1,\"span\":[0,0]}]}",
            Some(3),
            "parent",
        );
        refused(
            b"",
            "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},\n {\"kind\":\"footnote\",\"label\":\"a\",\"span\":[0,0]}],\n \"labels\":[{\"registry\":\"footnote\",\"label\":\"b\",\"node\":1}]}",
            Some(1),
            "labels",
        );
    }

    #[test]
    fn author_may_leave_out_what_is_absent() {
        let doc = decode(
            b"x",
            b"{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,1]},{\"kind\":\"line_block\",\"parent\":0,\"span\":[0,1]},{\"kind\":\"line\",\"parent\":1,\"span\":[0,1]},{\"kind\":\"str\",\"text\":\"x\",\"parent\":2,\"span\":[0,1]},{\"kind\":\"reference\",\"label\":\"r\",\"destination\":\"/\",\"span\":[0,0]}]}",
        )
        .unwrap();
        assert_eq!(doc.ast.nodes[2].kind, Kind::Line { indent: 0 });
        assert_eq!(doc.labels.reference(b"r"), Some(4));
    }

    #[test]
    fn bare_tree_in_build_order_writes_as_preorder_rows() {
        let mut b = Builder::new();
        b.add_leaf(Kind::Str(b"abandoned".to_vec()));
        let x = b.add_leaf(Kind::Str(b"x".to_vec()));
        let para = b.add_container(Kind::Para, &[x]);
        b.add_leaf(Kind::Reference { label: b"r".to_vec(), destination: b"/".to_vec() });
        let root = b.add_container(Kind::Doc, &[para]);
        let ast = b.finish(root);
        let text = encode_ast(&ast, Options { pretty: false, positions: true });
        let doc = decode_bare(&text).unwrap();
        assert_eq!(doc.ast.nodes.len(), 4);
        assert_eq!(doc.ast.nodes[0].kind, Kind::Doc);
        assert_eq!(doc.ast.nodes[2].kind, Kind::Str(b"x".to_vec()));
        assert_eq!(doc.labels.reference(b"r"), Some(3));
    }
}
