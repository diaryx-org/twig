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

use crate::json::{Json, Object, Value};
use crate::span::Span;
use crate::ast::{Attrs, KeyVal, KindRef};
use crate::document::Spelling;

/// Read a table from its JSON text into a `Document` over `source`. The text
/// is read where it lies: no [`Value`] is built for it.
pub fn decode(source: &[u8], text: &[u8]) -> Result<Document, Problem> {
    let Ok(t) = crate::json::check_rows(text, "nodes") else { return fail(None, "", "not a JSON document") };
    read(source, t.top.as_ref(), |_| t.rows(), true)
}

/// Read a table written without positions — what a print receives. Its root
/// may be any kind.
pub fn decode_bare(text: &[u8]) -> Result<Document, Problem> {
    let Ok(t) = crate::json::check_rows(text, "nodes") else { return fail(None, "", "not a JSON document") };
    read(b"", t.top.as_ref(), |_| t.rows(), false)
}

/// `decode` over an already-parsed JSON value.
pub fn from_value(source: &[u8], value: &Value) -> Result<Document, Problem> {
    read_value(source, value, true)
}

fn read_value(source: &[u8], value: &Value, positions: bool) -> Result<Document, Problem> {
    let top = value.object();
    read(source, top.as_ref(), |_| Some(Object::get(&top?, "nodes")?.items()?.map(|row| row.object())), positions)
}

/// Read the table whose top object is `top` and whose rows `rows` finds in
/// it — `None` when its `nodes` is not an array.
fn read<'a, T: Object<'a>, R: Object<'a>, I: Iterator<Item = Option<R>> + Clone>(
    source: &[u8],
    top: Option<&T>,
    rows: impl FnOnce(&T) -> Option<I>,
    positions: bool,
) -> Result<Document, Problem> {
    let Some(top) = top else {
        return fail(None, "", "a table is an object with a \"nodes\" array");
    };
    if top.get("nodes").is_none() {
        return fail(None, "nodes", "missing");
    }
    let Some(rows) = rows(top) else { return fail(None, "nodes", "expected an array") };
    // How many rows there are matters only to a row naming a parent at or
    // after itself, which is refused either way; so it is counted then.
    let all = rows.clone();
    let len = || all.clone().count();
    if all.clone().next().is_none() {
        return fail(None, "nodes", "a table has at least its root");
    }

    let mut b = Builder::new();
    let mut parents: Vec<Option<NodeId>> = Vec::new();
    for (i, row) in rows.enumerate() {
        if i > u32::MAX as usize {
            return fail(None, "nodes", "too many rows");
        }
        let Some(row) = row else { return fail(Some(i), "", "a row is an object") };
        let name = match row.get("kind") {
            None => return fail(Some(i), "kind", "missing"),
            Some(v) => match v.as_str() {
                Some(s) => s,
                None => return fail(Some(i), "kind", "expected a published kind name"),
            },
        };
        let Some(r) = KindRef::from_name(&String::from_utf8_lossy(&name)) else {
            return fail(Some(i), "kind", "not a published kind name");
        };
        let kind = match crate::ast::json::read_kind_in(&r, &row) {
            Ok(k) => k,
            Err(fp) => return fail(Some(i), &fp.field, &fp.what),
        };
        let id = b.add_node(kind);
        parents.push(opt_index(i, &row, "parent", len)?);
        if positions {
            match opt_span(i, &row, "span")? {
                Some(s) => b.set_span(id, s),
                None => return fail(Some(i), "span", "missing"),
            }
            if let Some(s) = opt_span(i, &row, "content_span")? {
                b.set_content_span(id, s);
            }
            if let Some(s) = opt_span(i, &row, "marker_span")? {
                b.set_marker_span(id, s);
            }
        }
        if let Some(sp) = read_spelling(i, &row)? {
            b.set_spelling(id, sp);
        }
        read_attrs(i, &row, &mut b, id, positions)?;
    }

    check_order(&b, &parents, positions)?;

    let mut firsts: Vec<Vec<NodeId>> = vec![Vec::new(); parents.len()];
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
        None => Labels::index(&doc.ast),
        Some(v) if v.is_null() => Labels::index(&doc.ast),
        Some(v) => match v.items() {
            Some(items) => read_labels(&doc.ast, items)?,
            None => return fail(None, "labels", "expected an array"),
        },
    };
    check_columns(&doc)?;
    Ok(doc)
}

/// A member that is absent or `null`, as `None`.
fn present<'a, O: Object<'a>>(row: &O, field: &str) -> Option<O::Json> {
    row.get(field).filter(|v| !v.is_null())
}

fn opt_index<'a, O: Object<'a>>(
    i: usize,
    row: &O,
    field: &str,
    len: impl FnOnce() -> usize,
) -> Result<Option<NodeId>, Problem> {
    let Some(v) = present(row, field) else { return Ok(None) };
    match v.as_int() {
        Some(n) if n >= 0 && ((n as usize) < i || (n as usize) < len()) => Ok(Some(n as NodeId)),
        Some(_) => fail(Some(i), field, "not a row of this table"),
        None => fail(Some(i), field, "expected a row index or null"),
    }
}

fn opt_span<'a, O: Object<'a>>(i: usize, row: &O, field: &str) -> Result<Option<Span>, Problem> {
    let Some(v) = present(row, field) else { return Ok(None) };
    let Some(mut pair) = v.items() else { return fail(Some(i), field, "expected [start, end]") };
    let mut ends = [0usize; 2];
    let mut n = 0;
    let mut bad = None;
    for x in pair.by_ref() {
        if n < 2 && bad.is_none() {
            bad = match x.as_int() {
                Some(v) if v >= 0 => {
                    ends[n] = v as usize;
                    None
                }
                Some(_) => Some("a byte offset is not negative"),
                None => Some("expected [start, end]"),
            };
        }
        n += 1;
    }
    if n != 2 {
        return fail(Some(i), field, "expected [start, end]");
    }
    if let Some(what) = bad {
        return fail(Some(i), field, what);
    }
    Ok(Some(Span::new(ends[0], ends[1])))
}

fn read_spelling<'a, O: Object<'a>>(i: usize, row: &O) -> Result<Option<Spelling>, Problem> {
    let Some(v) = present(row, "spelling") else { return Ok(None) };
    let Some(obj) = v.object() else { return fail(Some(i), "spelling", "expected an object of one key") };
    if obj.len() != 1 {
        return fail(Some(i), "spelling", "expected an object of one key");
    }
    let (key, value) = obj.member(0);
    let key = String::from_utf8_lossy(&key).into_owned();
    let Some(name) = value.as_str() else { return fail(Some(i), "spelling", "expected a name") };
    let name = String::from_utf8_lossy(&name).into_owned();
    if !matches!(key.as_str(), "bullet" | "ordered_delim" | "container_origin" | "highlight_prefix") {
        return fail(Some(i), "spelling", "not a spelling");
    }
    match Spelling::from_names(&key, &name) {
        Some(s) => Ok(Some(s)),
        None => fail(Some(i), "spelling", "not one of the names this spelling takes"),
    }
}

fn read_attrs<'a, O: Object<'a>>(i: usize, row: &O, b: &mut Builder, id: NodeId, positions: bool) -> Result<(), Problem> {
    let mut entries = Vec::new();
    if let Some(v) = present(row, "attrs") {
        let Some(items) = v.items() else { return fail(Some(i), "attrs", "expected an array of {key, value}") };
        for item in items {
            let Some(item) = item.object() else { return fail(Some(i), "attrs", "expected an array of {key, value}") };
            let key = match item.get("key").and_then(|k| k.as_str()) {
                Some(s) => s.into_owned(),
                None => return fail(Some(i), "attrs", "an entry's key is a string"),
            };
            let value = match present(&item, "value") {
                None => None,
                Some(v) => match v.as_str() {
                    Some(s) => Some(s.into_owned()),
                    None => return fail(Some(i), "attrs", "an entry's value is a string or null"),
                },
            };
            entries.push(KeyVal { key, value });
        }
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

fn read_labels<'a, J: Json<'a>>(ast: &Ast, items: impl Iterator<Item = J>) -> Result<Labels, Problem> {
    let mut labels = Labels::default();
    for item in items {
        let Some(item) = item.object() else {
            return fail(None, "labels", "expected an array of {registry, label, node}");
        };
        let registry = match item.get("registry").and_then(|v| v.as_str()).as_deref() {
            Some(b"reference") => Registry::Reference,
            Some(b"auto_reference") => Registry::AutoReference,
            Some(b"footnote") => Registry::Footnote,
            _ => return fail(None, "labels", "registry is reference, auto_reference or footnote"),
        };
        let node = match item.get("node").and_then(|v| v.as_int()) {
            Some(n) if n >= 0 && (n as usize) < ast.nodes.len() => n as NodeId,
            Some(_) => return fail(None, "labels", "node is not a row of this table"),
            None => return fail(None, "labels", "node is a row index"),
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
        let Some(label) = item.get("label").and_then(|v| v.as_str()) else {
            return fail(row, "labels", "label is a string");
        };
        if *label != *own {
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

    /// `decode` reads the text where it lies; `from_value` reads a parsed
    /// [`Value`]. Over any text the two take or refuse it alike, with the same
    /// `Problem`.
    fn agree(src: &[u8], text: &[u8]) {
        let flat = |d: Document| encode(&d, Options { pretty: false, positions: true });
        let tree = |positions: bool| match crate::json::parse(text) {
            Ok(v) => read_value(src, &v, positions).map(flat),
            Err(_) => fail(None, "", "not a JSON document"),
        };
        let shown = String::from_utf8_lossy(text);
        assert_eq!(decode(src, text).map(flat), tree(true), "{shown}");
        assert_eq!(decode_bare(text).map(flat), tree(false), "bare: {shown}");
    }

    #[test]
    fn decode_in_place_agrees_with_the_parsed_value() {
        let doc = r#"{"kind":"doc","span":[0,2]}"#;
        for text in [
            "",
            "  ",
            "[",
            "{}",
            "{} x",
            "[1,]",
            "{\"nodes\":[]} ",
            "nul",
            "\"a",
            "\"\\x\"",
            "\"\\u12\"",
            "\"\\u+041\"",
            "\"\\ud800\\u00zz\"",
            "\"a\u{1}\"",
            "1.2.3",
            "-",
            "01",
            "{\"nodes\":7}",
            "{\"nodes\":null}",
            "{\"nodes\":[1]}",
            r#"{"nodes":[{"kind":null,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":7,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0.0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[-1,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,1e0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":{"0":0}}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"parent":0.0}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"parent":99999999999999999999}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"heading","level":-1,"parent":0,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"heading","level":4294967296,"parent":0,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"heading","level":"1","parent":0,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"bullet_list","tight":1,"parent":0,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"str","text":"a\"\\\/\b\f\n\r\t\u00e9\ud83d\ude00\ud800x","parent":0,"span":[0,2]}]}"#,
            "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,2]},{\"kind\":\"str\",\"text\":\"\u{e9}\u{1F600}\",\"parent\":0,\"span\":[0,2]}]}",
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"str","text":[97],"parent":0,"span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"str","parent":0,"span":[0,2]}]}"#,
            r#"{"nodes":[{"k\u0069nd":"doc","span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"para","kind":"doc","span":[9,9],"span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]}],"nodes":[]}"#,
            r#"{"nodes":[],"nodes":[{"kind":"doc","span":[0,2]}]}"#,
            r#"{"labels":[],"nodes":[{"kind":"doc","span":[0,2]}],"extra":{"a":[1,{"b":null}],"c":-2.5e3}}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"unknown":[[[]]],"content_span":null}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"ordered_list","numbering":"decimal","tight":false,"start":3,"parent":0,"span":[0,2],"spelling":{"ordered_delim":"period"}}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"ordered_list","numbering":"roman","tight":false,"parent":0,"span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"bullet_list","tight":true,"parent":0,"span":[0,2],"spelling":{"bullet":"dash","bullet":"star"}}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"bullet_list","tight":true,"parent":0,"span":[0,2],"spelling":{"colour":"dash"}}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"bullet_list","tight":true,"parent":0,"span":[0,2],"spelling":{"bullet":7}}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"bullet_list","tight":true,"parent":0,"span":[0,2],"spelling":"dash"}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"attrs":[{"key":"id","value":"x"},{"key":"hidden","value":null},{"key":"k"}],"attrs_span":[0,1]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"attrs":[{"key":1}]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"attrs":[{"key":"a","value":1}]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"attrs":["a"]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2],"attrs":{}}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"container","name":"div","form":"fenced","argument":null,"parent":0,"span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"container","name":"div","form":"nonsense","parent":0,"span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"reference","label":"r","destination":"/","span":[0,0]}],"labels":[{"registry":"reference","label":"r","node":1}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"reference","label":"r","destination":"/","span":[0,0]}],"labels":[{"registry":"footnote","label":"r","node":1}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"reference","label":"r","destination":"/","span":[0,0]}],"labels":[{"registry":"reference","label":"r","node":2}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]}],"labels":[{"registry":"elsewhere","label":"r","node":0}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]}],"labels":[7]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]}],"labels":{}}"#,
            r#"{"nodes":[{"kind":"para","span":[0,2]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"para","parent":2,"span":[0,0]},{"kind":"para","parent":0,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"para","parent":1,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},{"kind":"para","parent":2,"span":[0,0]},{"kind":"heading","parent":0,"span":[0,0]}]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]},3]}"#,
            r#"{"nodes":[{"kind":"doc","span":[0,2]}],"nodes":7}"#,
            r#"{"nodes":7,"nodes":[{"kind":"doc","span":[0,2]}]}"#,
            r#"{"labels":[],"nodes":[{"kind":"doc","span":[0,2]}],"labels":null}"#,
            doc,
        ] {
            agree(b"ab", text.as_bytes());
        }
        for depth in [511, 512] {
            let deep = format!("{{\"nodes\":[{doc}],\"x\":{}{}}}", "[".repeat(depth), "]".repeat(depth));
            agree(b"ab", deep.as_bytes());
        }
        agree(b"ab", b"{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,2]},{\"kind\":\"str\",\"text\":\"\xff\xfe\",\"parent\":0,\"span\":[0,2]}]}");
    }

    /// Every way of breaking a real table by a byte or two, read both ways.
    #[test]
    fn decode_in_place_agrees_on_damaged_tables() {
        let src = b"- *a* b";
        let mut b = Builder::new();
        let a = b.add_leaf(Kind::Str(b"a\"\n".to_vec()));
        b.set_span(a, Span::new(3, 4));
        let em = b.add_container(Kind::InlineMark(InlineMark::Strong), &[a]);
        b.set_span(em, Span::new(2, 5));
        let para = b.add_container(Kind::Para, &[em]);
        b.set_span(para, Span::new(2, 7));
        let item = b.add_container(Kind::ListItem, &[para]);
        b.set_span(item, Span::new(0, 7));
        let list = b.add_container(Kind::BulletList { tight: true }, &[item]);
        b.set_span(list, Span::new(0, 7));
        b.set_spelling(list, Spelling::Bullet(Bullet::Dash));
        b.set_attrs(list, Attrs { entries: vec![KeyVal::new(b"class", Some(b"x")), KeyVal::new(b"hidden", None)] });
        b.set_attrs_span(list, Span::new(0, 1));
        let r = b.add_leaf(Kind::Reference { label: b"r".to_vec(), destination: b"/".to_vec() });
        b.set_span(r, Span::new(0, 0));
        let doc_id = b.add_container(Kind::Doc, &[list]);
        b.set_span(doc_id, Span::new(0, 7));
        let doc = compact::run(b.finish_document(src, doc_id));
        let text = encode(&doc, Options { pretty: false, positions: true });
        agree(src, &text);
        let bytes = b"{}[],:\"\\0-9.enul ";
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed as usize
        };
        for _ in 0..4000 {
            let mut t = text.clone();
            for _ in 0..1 + next() % 2 {
                let at = next() % t.len();
                match next() % 3 {
                    0 => {
                        t.remove(at);
                    }
                    1 => t.insert(at, bytes[next() % bytes.len()]),
                    _ => t[at] = bytes[next() % bytes.len()],
                }
            }
            agree(src, &t);
        }
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
