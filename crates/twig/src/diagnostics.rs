//! What a conversion loses: per kind and per node, how much of the tree
//! survives a round trip through a target format. Port of
//! `src/diagnostics.zig` — see its header for the argument.

use std::sync::OnceLock;

use crate::ast::{
    Ast, Attrs, Builder, Cell, Container, Form, InlineMark, Kind, KindRef, KeyVal, Link, ListNumbering, MarkupLeafKind,
    NodeId, SmartPunctuationKind, Tag, TextLeafKind,
};
use crate::document::Document;
use crate::format::Target;
use crate::runtime;

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
fn worst(a: Fidelity, b: Fidelity) -> Fidelity {
    a.max(b)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Subject {
    Node,
    Attrs,
}

/// One thing a conversion to a given format would lose.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Warning {
    pub fidelity: Fidelity,
    /// Slash-separated child-index trail from the analyzed root (`"1/0/2"`);
    /// empty means the root itself.
    pub path: String,
    /// The node's published kind name.
    pub kind: &'static str,
    pub subject: Subject,
    /// For `Subject::Attrs`: the keys that do not survive, in node order.
    pub attrs: Vec<Vec<u8>>,
}

impl Warning {
    /// The default human-readable message, no trailing newline.
    pub fn render(&self, target: Target) -> String {
        let mut out = format!("`{}` at ", self.kind);
        if self.path.is_empty() {
            out.push_str("the document root");
        } else {
            out.push('`');
            out.push_str(&self.path);
            out.push('`');
        }
        let t = target.name();
        match self.subject {
            Subject::Node => match self.fidelity {
                Fidelity::Faithful => {}
                Fidelity::Degraded => out.push_str(&format!(" is not spelled by {t} and will reparse as something else")),
                Fidelity::Dropped => out.push_str(&format!(" is dropped entirely ({t} cannot write it)")),
            },
            Subject::Attrs => {
                out.push_str(" carries attributes (");
                for (i, k) in self.attrs.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    out.push_str(&String::from_utf8_lossy(k));
                }
                match self.fidelity {
                    Fidelity::Faithful => {}
                    Fidelity::Degraded => {
                        out.push_str(&format!(") that {t} writes where its parser does not read them back"))
                    }
                    Fidelity::Dropped => out.push_str(&format!(") that {t} cannot write; they are dropped")),
                }
            }
        }
        out
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnalyzeError {
    /// The target has no bare-tree serializer at all.
    UnsupportedFormat,
}

/// Walk the subtree at `root` as `target`'s serializer would and collect one
/// warning per lossy node (and per node with lossy attributes).
pub fn analyze(ast: &Ast, root: NodeId, target: Target) -> Result<Vec<Warning>, AnalyzeError> {
    if !crate::format::target_serializes_from_ast(target) {
        return Err(AnalyzeError::UnsupportedFormat);
    }
    let mut out = Vec::new();
    walk(ast, target, root, String::new(), &mut out);
    Ok(out)
}

fn walk(ast: &Ast, target: Target, id: NodeId, path: String, out: &mut Vec<Warning>) {
    let kind = &ast.nodes[id as usize].kind;
    let f = node_fidelity(target, ast, id);
    if f.is_lossy() {
        out.push(Warning { fidelity: f, path: path.clone(), kind: kind.kind_name(), subject: Subject::Node, attrs: vec![] });
    }
    if f != Fidelity::Dropped {
        note_attrs(ast, target, id, &path, f, out);
    }
    for (i, c) in ast.child_ids(id).into_iter().enumerate() {
        let p = if path.is_empty() { format!("{i}") } else { format!("{path}/{i}") };
        walk(ast, target, c, p, out);
    }
}

fn note_attrs(ast: &Ast, target: Target, id: NodeId, path: &str, node: Fidelity, out: &mut Vec<Warning>) {
    let attrs = ast.attrs_of(id);
    if attrs.is_empty() {
        return;
    }
    let table = node_attrs_fidelity(target, ast, id, node);
    let mut lost = Vec::new();
    let mut f = Fidelity::Faithful;
    for kv in &attrs.entries {
        let kf = table.for_key(&kv.key);
        if !kf.is_lossy() {
            continue;
        }
        lost.push(kv.key.clone());
        f = worst(f, kf);
    }
    if lost.is_empty() {
        return;
    }
    out.push(Warning {
        fidelity: f,
        path: path.to_string(),
        kind: ast.nodes[id as usize].kind.kind_name(),
        subject: Subject::Attrs,
        attrs: lost,
    });
}

// ── the capability table ────────────────────────────────────────────────────

/// How `kind` survives a conversion to `target` — the kind-level answer.
pub fn fidelity(target: Target, kind: &Kind) -> Fidelity {
    match target {
        Target::Xml => Fidelity::Dropped,
        Target::Djot => djot_fidelity(kind),
        Target::Markdown => markdown_fidelity(kind),
        Target::Html => html_fidelity(kind),
        Target::Asciidoc => asciidoc_fidelity(kind),
        Target::Runtime(_) => match runtime::measured(target) {
            Some(m) => m.for_kind(kind),
            None => Fidelity::Dropped,
        },
    }
}

/// `fidelity` for one NODE — the kind's answer, downgraded by whatever only
/// the node's own contents can say.
pub fn node_fidelity(target: Target, ast: &Ast, id: NodeId) -> Fidelity {
    if let Some(m) = runtime::measured(target) {
        return m.for_node(ast, id);
    }
    let kind = &ast.nodes[id as usize].kind;
    let base = fidelity(target, kind);
    match kind {
        Kind::Table => worst(base, table_fidelity(target, ast, id)),
        Kind::Container(_) => worst(base, container_fidelity(target, ast, id)),
        Kind::Section => worst(base, section_fidelity(target, ast, id)),
        Kind::Metadata { .. } => worst(base, metadata_fidelity(target, ast, id)),
        _ => base,
    }
}

fn metadata_fidelity(target: Target, ast: &Ast, id: NodeId) -> Fidelity {
    if target != Target::Asciidoc {
        return Fidelity::Faithful;
    }
    if ast.nodes[ast.root as usize].first_child == Some(id) { Fidelity::Faithful } else { Fidelity::Degraded }
}

fn section_fidelity(target: Target, ast: &Ast, id: NodeId) -> Fidelity {
    match target {
        Target::Djot | Target::Asciidoc => {}
        _ => return Fidelity::Faithful,
    }
    let Some(level) = section_heading(ast, id) else { return Fidelity::Degraded };
    if target == Target::Asciidoc && level == 1 {
        return Fidelity::Degraded;
    }
    Fidelity::Faithful
}

/// The level of the heading a section opens with, if it opens with one.
fn section_heading(ast: &Ast, id: NodeId) -> Option<u32> {
    let first = ast.nodes[id as usize].first_child?;
    match ast.nodes[first as usize].kind {
        Kind::Heading { level } => Some(level),
        _ => None,
    }
}

fn table_fidelity(target: Target, ast: &Ast, id: NodeId) -> Fidelity {
    if target != Target::Markdown {
        return Fidelity::Faithful;
    }
    match ast.table_rows(id).next() {
        None => Fidelity::Faithful,
        Some(r) => {
            if r.head {
                Fidelity::Faithful
            } else {
                Fidelity::Degraded
            }
        }
    }
}

fn container_fidelity(target: Target, ast: &Ast, id: NodeId) -> Fidelity {
    let Kind::Container(c) = &ast.nodes[id as usize].kind else { return Fidelity::Faithful };
    if target != Target::Djot {
        return Fidelity::Faithful;
    }
    if c.form != Some(Form::InlineText) || !c.name.is_empty() {
        return Fidelity::Faithful;
    }
    if ast.attrs_of(id).is_empty() { Fidelity::Dropped } else { Fidelity::Faithful }
}

use Fidelity::{Degraded as D, Dropped as X, Faithful as F};

fn djot_fidelity(kind: &Kind) -> Fidelity {
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

fn markdown_fidelity(kind: &Kind) -> Fidelity {
    match kind {
        Kind::Section => D,
        Kind::RawBlock { .. } => D,
        Kind::Container(_) => D,
        Kind::MarkupLeaf { .. } | Kind::ProcessingInstruction { .. } | Kind::RawInline { .. } => D,
        Kind::SmartPunctuation(_) => D,
        Kind::NonBreakingSpace => D,
        Kind::InlineMark(m) => match m {
            InlineMark::Strong | InlineMark::Emph | InlineMark::Delete => F,
            _ => D,
        },
        Kind::Citation { .. } => D,
        Kind::Substitution { .. } => X,
        Kind::LineBlock | Kind::Line { .. } => D,
        Kind::Column => X,
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim | TextLeafKind::Url | TextLeafKind::Email | TextLeafKind::FootnoteReference => F,
            _ => D,
        },
        _ => F,
    }
}

fn asciidoc_fidelity(kind: &Kind) -> Fidelity {
    match kind {
        Kind::MarkupLeaf { kind, .. } => match kind {
            MarkupLeafKind::Comment | MarkupLeafKind::Doctype => X,
            MarkupLeafKind::Cdata => D,
        },
        Kind::ProcessingInstruction { .. } => X,
        Kind::Substitution { .. } => F,
        Kind::Column => X,
        Kind::Metadata { .. } => F,
        Kind::Citation { .. } => D,
        Kind::Container(c) => {
            if is_native_container(&c.name) {
                F
            } else {
                D
            }
        }
        Kind::InlineMark(m) => match m {
            InlineMark::Insert | InlineMark::Delete => D,
            _ => F,
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::DisplayMath | TextLeafKind::Symb | TextLeafKind::CitationReference => D,
            _ => F,
        },
        Kind::Reference { .. } => D,
        _ => F,
    }
}

fn is_native_container(name: &[u8]) -> bool {
    const NATIVE: [&[u8]; 12] = [
        b"note",
        b"tip",
        b"important",
        b"warning",
        b"caution",
        b"example",
        b"sidebar",
        b"open",
        b"page-break",
        b"kbd",
        b"abstract",
        b"partintro",
    ];
    NATIVE.contains(&name)
}

fn html_fidelity(kind: &Kind) -> Fidelity {
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

// ── attributes ──────────────────────────────────────────────────────────────

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

    const fn icot(id: Fidelity, class: Fidelity, other: Fidelity) -> AttrsFidelity {
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

pub fn attrs_fidelity(target: Target, kind: &Kind) -> AttrsFidelity {
    match target {
        Target::Xml => AttrsFidelity::all(X),
        Target::Djot => djot_attrs_fidelity(kind),
        Target::Markdown => markdown_attrs_fidelity(kind),
        Target::Html => html_attrs_fidelity(kind),
        Target::Asciidoc => asciidoc_attrs_fidelity(kind),
        Target::Runtime(_) => match runtime::measured(target) {
            Some(m) => m.attrs_for_kind(kind),
            None => AttrsFidelity::all(X),
        },
    }
}

pub fn node_attrs_fidelity(target: Target, ast: &Ast, id: NodeId, node: Fidelity) -> AttrsFidelity {
    if let Some(m) = runtime::measured(target) {
        return m.attrs_for_node(ast, id).under(node);
    }
    let kind = &ast.nodes[id as usize].kind;
    let table = match kind {
        Kind::Section if target == Target::Djot && section_heading(ast, id).is_none() => AttrsFidelity::all(X),
        _ => attrs_fidelity(target, kind),
    };
    table.under(node)
}

fn djot_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para | Kind::Container(_) | Kind::Reference { .. } | Kind::Section => AttrsFidelity::all(F),
        Kind::Heading { .. } => AttrsFidelity::all(D),
        Kind::LineBlock => AttrsFidelity::all(F),
        _ => AttrsFidelity::all(X),
    }
}

fn markdown_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para
        | Kind::Heading { .. }
        | Kind::ThematicBreak
        | Kind::Section
        | Kind::CodeBlock { .. }
        | Kind::RawBlock { .. }
        | Kind::BlockQuote
        | Kind::BulletList { .. }
        | Kind::OrderedList { .. }
        | Kind::TaskList { .. }
        | Kind::DefinitionList
        | Kind::LineBlock
        | Kind::Table => AttrsFidelity::all(D),
        Kind::Reference { .. } => AttrsFidelity { id: X, class: X, other: X, title: Some(F) },
        Kind::Container(_) => AttrsFidelity::all(D),
        _ => AttrsFidelity::all(X),
    }
}

fn html_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
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

fn asciidoc_attrs_fidelity(kind: &Kind) -> AttrsFidelity {
    match kind {
        Kind::Para
        | Kind::ThematicBreak
        | Kind::CodeBlock { .. }
        | Kind::RawBlock { .. }
        | Kind::BlockQuote
        | Kind::BulletList { .. }
        | Kind::OrderedList { .. }
        | Kind::TaskList { .. }
        | Kind::DefinitionList
        | Kind::LineBlock => AttrsFidelity::all(F),
        Kind::Container(c) => {
            if c.form == Some(Form::InlineText) {
                AttrsFidelity::icot(D, D, X)
            } else {
                AttrsFidelity::all(F)
            }
        }
        Kind::Table => AttrsFidelity { id: F, class: F, other: F, title: Some(D) },
        Kind::Heading { .. } => AttrsFidelity::all(D),
        Kind::Image(_) => AttrsFidelity::all(D),
        Kind::InlineMark(m) => match m {
            InlineMark::Emph | InlineMark::Strong | InlineMark::Superscript | InlineMark::Subscript => {
                AttrsFidelity::icot(F, F, X)
            }
            _ => AttrsFidelity::icot(D, D, X),
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim => AttrsFidelity::icot(F, F, X),
            _ => AttrsFidelity::all(X),
        },
        Kind::Link(_) => AttrsFidelity::icot(X, F, X),
        _ => AttrsFidelity::all(X),
    }
}

// ── probes ──────────────────────────────────────────────────────────────────

/// A minimal document around one kind, built so a round trip can be observed.
#[derive(Clone)]
pub struct Probe {
    pub label: &'static str,
    pub want: KindRef,
    pub kind: Kind,
    pub build: fn(&mut Builder) -> NodeId,
    pub intact: Option<fn(&Ast) -> bool>,
}

fn s(b: &mut Builder, t: &str) -> NodeId {
    b.add_leaf(Kind::Str(t.as_bytes().to_vec()))
}

fn block_doc(b: &mut Builder, kind: Kind, children: &[NodeId]) -> NodeId {
    let n = b.add_container(kind, children);
    b.add_container(Kind::Doc, &[n])
}

fn inline_doc(b: &mut Builder, kind: Kind, children: &[NodeId]) -> NodeId {
    let n = b.add_container(kind, children);
    let p = b.add_container(Kind::Para, &[n]);
    b.add_container(Kind::Doc, &[p])
}

fn para(b: &mut Builder, t: &str) -> NodeId {
    let x = s(b, t);
    b.add_container(Kind::Para, &[x])
}

fn build_line_block(b: &mut Builder) -> NodeId {
    let one = s(b, "one");
    let l1 = b.add_container(Kind::Line { indent: 0 }, &[one]);
    let two = s(b, "two");
    let l2 = b.add_container(Kind::Line { indent: 1 }, &[two]);
    block_doc(b, Kind::LineBlock, &[l1, l2])
}

fn build_definition_list(b: &mut Builder) -> NodeId {
    let tt = s(b, "t");
    let t = b.add_container(Kind::Term, &[tt]);
    let p = para(b, "d");
    let d = b.add_container(Kind::Definition, &[p]);
    let item = b.add_container(Kind::DefinitionListItem, &[t, d]);
    block_doc(b, Kind::DefinitionList, &[item])
}

fn build_plain_para(b: &mut Builder) -> NodeId {
    let x = s(b, "x");
    block_doc(b, Kind::Para, &[x])
}

fn build_captioned_table(b: &mut Builder) -> NodeId {
    let c = s(b, "c");
    let cap = b.add_container(Kind::Caption, &[c]);
    let a = s(b, "a");
    let c1 = b.add_container(Kind::Cell(Cell::new(true, Default::default())), &[a]);
    let r1 = b.add_container(Kind::Row { head: true }, &[c1]);
    let one = s(b, "1");
    let c2 = b.add_container(Kind::Cell(Cell::new(false, Default::default())), &[one]);
    let r2 = b.add_container(Kind::Row { head: false }, &[c2]);
    block_doc(b, Kind::Table, &[cap, r1, r2])
}

fn build_bullet_list(b: &mut Builder) -> NodeId {
    let p = para(b, "x");
    let li = b.add_container(Kind::ListItem, &[p]);
    block_doc(b, Kind::BulletList { tight: true }, &[li])
}

fn build_task_list(b: &mut Builder) -> NodeId {
    let p = para(b, "x");
    let li = b.add_container(Kind::TaskListItem { checked: true }, &[p]);
    block_doc(b, Kind::TaskList { tight: true }, &[li])
}

fn bytes(s: &str) -> Vec<u8> {
    s.as_bytes().to_vec()
}

fn leaf_probe_text(k: TextLeafKind) -> &'static str {
    match k {
        TextLeafKind::Symb => "name",
        TextLeafKind::Verbatim => "c",
        TextLeafKind::InlineMath | TextLeafKind::DisplayMath => "a+b",
        TextLeafKind::Url => "https://e.com",
        TextLeafKind::Email => "a@e.com",
        TextLeafKind::FootnoteReference => "1",
        TextLeafKind::CitationReference => "CIT1",
        TextLeafKind::SubstitutionReference => "RST",
    }
}

/// The probes the fidelity table is tested against.
pub fn probes() -> Vec<Probe> {
    fn p(label: &'static str, want: KindRef, kind: Kind, build: fn(&mut Builder) -> NodeId) -> Probe {
        Probe { label, want, kind, build, intact: None }
    }
    let t = KindRef::Tag;
    vec![
        p("heading", t(Tag::Heading), Kind::Heading { level: 2 }, |b| {
            let x = s(b, "x");
            block_doc(b, Kind::Heading { level: 2 }, &[x])
        }),
        p("section", t(Tag::Section), Kind::Section, |b| {
            let tt = s(b, "t");
            let h = b.add_container(Kind::Heading { level: 1 }, &[tt]);
            let pp = para(b, "x");
            block_doc(b, Kind::Section, &[h, pp])
        }),
        p("section(headless)", t(Tag::Section), Kind::Section, |b| {
            let pp = para(b, "x");
            block_doc(b, Kind::Section, &[pp])
        }),
        p("block_quote", t(Tag::BlockQuote), Kind::BlockQuote, |b| {
            let pp = para(b, "x");
            block_doc(b, Kind::BlockQuote, &[pp])
        }),
        p("thematic_break", t(Tag::ThematicBreak), Kind::ThematicBreak, |b| block_doc(b, Kind::ThematicBreak, &[])),
        p("code_block", t(Tag::CodeBlock), Kind::CodeBlock { lang: None, text: vec![] }, |b| {
            block_doc(b, Kind::CodeBlock { lang: Some(bytes("zig")), text: bytes("x\n") }, &[])
        }),
        p("raw_block", t(Tag::RawBlock), Kind::RawBlock { format: vec![], text: vec![] }, |b| {
            block_doc(b, Kind::RawBlock { format: bytes("html"), text: bytes("<x>\n") }, &[])
        }),
        p("metadata", t(Tag::Metadata), Kind::Metadata { lang: vec![], text: vec![] }, |b| {
            block_doc(b, Kind::Metadata { lang: bytes("yaml"), text: bytes("a: 1\n") }, &[])
        }),
        p("bullet_list", t(Tag::BulletList), Kind::BulletList { tight: true }, build_bullet_list),
        p(
            "ordered_list",
            t(Tag::OrderedList),
            Kind::OrderedList { numbering: ListNumbering::Decimal, tight: true, start: Some(1) },
            |b| {
                let pp = para(b, "x");
                let li = b.add_container(Kind::ListItem, &[pp]);
                block_doc(b, Kind::OrderedList { numbering: ListNumbering::Decimal, tight: true, start: Some(1) }, &[li])
            },
        ),
        p("task_list", t(Tag::TaskList), Kind::TaskList { tight: true }, build_task_list),
        p("definition_list", t(Tag::DefinitionList), Kind::DefinitionList, build_definition_list),
        p("line_block", t(Tag::LineBlock), Kind::LineBlock, build_line_block),
        p("line", t(Tag::Line), Kind::Line { indent: 0 }, build_line_block),
        p("table", t(Tag::Table), Kind::Table, |b| {
            let cap = b.add_container(Kind::Caption, &[]);
            let a = s(b, "a");
            let c1 = b.add_container(Kind::Cell(Cell::new(true, Default::default())), &[a]);
            let r1 = b.add_container(Kind::Row { head: true }, &[c1]);
            let one = s(b, "1");
            let c2 = b.add_container(Kind::Cell(Cell::new(false, Default::default())), &[one]);
            let r2 = b.add_container(Kind::Row { head: false }, &[c2]);
            block_doc(b, Kind::Table, &[cap, r1, r2])
        }),
        Probe {
            label: "table(header-less)",
            want: t(Tag::Table),
            kind: Kind::Table,
            build: |b| {
                let a = s(b, "a");
                let c = b.add_container(Kind::Cell(Cell::new(false, Default::default())), &[a]);
                let r = b.add_container(Kind::Row { head: false }, &[c]);
                block_doc(b, Kind::Table, &[r])
            },
            intact: Some(|back| !back.nodes.iter().any(|n| matches!(n.kind, Kind::Row { head: true }))),
        },
        p("column", t(Tag::Column), Kind::Column, |b| {
            let col = b.add_container(Kind::Column, &[]);
            let one = s(b, "1");
            let c = b.add_container(Kind::Cell(Cell::new(false, Default::default())), &[one]);
            let r = b.add_container(Kind::Row { head: false }, &[c]);
            block_doc(b, Kind::Table, &[col, r])
        }),
        p("footnote", t(Tag::Footnote), Kind::Footnote { label: vec![] }, |b| {
            let pp = para(b, "note");
            let def = b.add_container(Kind::Footnote { label: bytes("1") }, &[pp]);
            let r = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::FootnoteReference, text: bytes("1") });
            let x = s(b, "x");
            let body = b.add_container(Kind::Para, &[x, r]);
            b.add_container(Kind::Doc, &[body, def])
        }),
        p("reference", t(Tag::Reference), Kind::Reference { label: vec![], destination: vec![] }, |b| {
            let def = b.add_leaf(Kind::Reference { label: bytes("r"), destination: bytes("/u") });
            let tt = s(b, "t");
            let l = b.add_container(Kind::Link(Link { destination: None, reference: Some(bytes("r")) }), &[tt]);
            let pp = b.add_container(Kind::Para, &[l]);
            b.add_container(Kind::Doc, &[pp, def])
        }),
        p("citation", t(Tag::Citation), Kind::Citation { label: vec![] }, |b| {
            let pp = para(b, "Deep Thought.");
            let def = b.add_container(Kind::Citation { label: bytes("CIT2002") }, &[pp]);
            let r = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::CitationReference, text: bytes("CIT2002") });
            let see = s(b, "see ");
            let body = b.add_container(Kind::Para, &[see, r]);
            b.add_container(Kind::Doc, &[body, def])
        }),
        p("substitution", t(Tag::Substitution), Kind::Substitution { label: vec![] }, |b| {
            let x = s(b, "reStructuredText");
            let def = b.add_container(Kind::Substitution { label: bytes("RST") }, &[x]);
            let r = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::SubstitutionReference, text: bytes("RST") });
            let rules = s(b, " rules");
            let body = b.add_container(Kind::Para, &[r, rules]);
            b.add_container(Kind::Doc, &[body, def])
        }),
        p(
            "container(block)",
            KindRef::ContainerNamed(bytes("note")),
            Kind::Container(Container::with_form(b"note", Form::BlockFenced)),
            |b| {
                let pp = para(b, "x");
                block_doc(b, Kind::Container(Container::with_form(b"note", Form::BlockFenced)), &[pp])
            },
        ),
        p(
            "container(inline)",
            KindRef::ContainerNamed(bytes("span")),
            Kind::Container(Container::with_form(b"span", Form::InlineText)),
            |b| {
                let x = s(b, "x");
                inline_doc(b, Kind::Container(Container::with_form(b"span", Form::InlineText)), &[x])
            },
        ),
        p(
            "container(anonymous)",
            KindRef::ContainerNamed(vec![]),
            Kind::Container(Container::with_form(b"", Form::BlockFenced)),
            |b| {
                let pp = para(b, "x");
                block_doc(b, Kind::Container(Container::with_form(b"", Form::BlockFenced)), &[pp])
            },
        ),
        p(
            "comment",
            KindRef::MarkupLeaf(MarkupLeafKind::Comment),
            Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text: vec![] },
            |b| block_doc(b, Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text: bytes(" hi ") }, &[]),
        ),
        p(
            "doctype",
            KindRef::MarkupLeaf(MarkupLeafKind::Doctype),
            Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: vec![] },
            |b| block_doc(b, Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: bytes("html") }, &[]),
        ),
        p(
            "cdata",
            KindRef::MarkupLeaf(MarkupLeafKind::Cdata),
            Kind::MarkupLeaf { kind: MarkupLeafKind::Cdata, text: vec![] },
            |b| block_doc(b, Kind::MarkupLeaf { kind: MarkupLeafKind::Cdata, text: bytes("raw") }, &[]),
        ),
        p(
            "processing_instruction",
            t(Tag::ProcessingInstruction),
            Kind::ProcessingInstruction { target: vec![], data: vec![] },
            |b| block_doc(b, Kind::ProcessingInstruction { target: bytes("php"), data: bytes("echo") }, &[]),
        ),
        p("link", t(Tag::Link), Kind::Link(Link::default()), |b| {
            let tt = s(b, "t");
            inline_doc(b, Kind::Link(Link { destination: Some(bytes("/u")), reference: None }), &[tt])
        }),
        p("image", t(Tag::Image), Kind::Image(Link::default()), |b| {
            let alt = s(b, "alt");
            inline_doc(b, Kind::Image(Link { destination: Some(bytes("/u.png")), reference: None }), &[alt])
        }),
        p("raw_inline", t(Tag::RawInline), Kind::RawInline { format: vec![], text: vec![] }, |b| {
            let n = b.add_leaf(Kind::RawInline { format: bytes("html"), text: bytes("<b>") });
            let pp = b.add_container(Kind::Para, &[n]);
            b.add_container(Kind::Doc, &[pp])
        }),
        p("hard_break", t(Tag::HardBreak), Kind::HardBreak, |b| {
            let a = s(b, "a");
            let n = b.add_leaf(Kind::HardBreak);
            let bb = s(b, "b");
            let pp = b.add_container(Kind::Para, &[a, n, bb]);
            b.add_container(Kind::Doc, &[pp])
        }),
        p("non_breaking_space", t(Tag::NonBreakingSpace), Kind::NonBreakingSpace, |b| {
            let a = s(b, "a");
            let n = b.add_leaf(Kind::NonBreakingSpace);
            let bb = s(b, "b");
            let pp = b.add_container(Kind::Para, &[a, n, bb]);
            b.add_container(Kind::Doc, &[pp])
        }),
        p(
            "smart_punctuation",
            t(Tag::SmartPunctuation),
            Kind::SmartPunctuation(SmartPunctuationKind::Ellipses),
            |b| {
                let n = b.add_leaf(Kind::SmartPunctuation(SmartPunctuationKind::Ellipses));
                let pp = b.add_container(Kind::Para, &[n]);
                b.add_container(Kind::Doc, &[pp])
            },
        ),
    ]
}

/// The probe list a runtime target is measured over: `para`, every probe
/// above, one per inline mark and text leaf, and the structural children.
pub fn measured_probes() -> &'static [Probe] {
    static PROBES: OnceLock<Vec<Probe>> = OnceLock::new();
    PROBES.get_or_init(|| {
        let mut out = vec![Probe {
            label: "para",
            want: KindRef::Tag(Tag::Para),
            kind: Kind::Para,
            build: build_plain_para,
            intact: None,
        }];
        out.extend(probes());
        // Inline marks and text leaves: the probe builds the kind it names, so
        // each needs its own `fn` — a closure cannot capture in a fn pointer.
        macro_rules! mark {
            ($m:expr, $label:expr) => {
                Probe {
                    label: $label,
                    want: KindRef::Mark($m),
                    kind: Kind::InlineMark($m),
                    build: |b| {
                        let x = s(b, "x");
                        inline_doc(b, Kind::InlineMark($m), &[x])
                    },
                    intact: None,
                }
            };
        }
        out.push(mark!(InlineMark::Emph, "emph"));
        out.push(mark!(InlineMark::Strong, "strong"));
        out.push(mark!(InlineMark::Mark, "mark"));
        out.push(mark!(InlineMark::Superscript, "superscript"));
        out.push(mark!(InlineMark::Subscript, "subscript"));
        out.push(mark!(InlineMark::Insert, "insert"));
        out.push(mark!(InlineMark::Delete, "delete"));
        out.push(mark!(InlineMark::DoubleQuoted, "double_quoted"));
        out.push(mark!(InlineMark::SingleQuoted, "single_quoted"));
        macro_rules! leaf {
            ($k:expr, $label:expr) => {
                Probe {
                    label: $label,
                    want: KindRef::TextLeaf($k),
                    kind: Kind::TextLeaf { kind: $k, text: bytes(leaf_probe_text($k)) },
                    build: |b| inline_doc(b, Kind::TextLeaf { kind: $k, text: bytes(leaf_probe_text($k)) }, &[]),
                    intact: None,
                }
            };
        }
        out.push(leaf!(TextLeafKind::Symb, "symb"));
        out.push(leaf!(TextLeafKind::Verbatim, "verbatim"));
        out.push(leaf!(TextLeafKind::InlineMath, "inline_math"));
        out.push(leaf!(TextLeafKind::DisplayMath, "display_math"));
        out.push(leaf!(TextLeafKind::Url, "url"));
        out.push(leaf!(TextLeafKind::Email, "email"));
        out.push(leaf!(TextLeafKind::FootnoteReference, "footnote_reference"));
        out.push(leaf!(TextLeafKind::CitationReference, "citation_reference"));
        out.push(leaf!(TextLeafKind::SubstitutionReference, "substitution_reference"));
        let st = |label, tag, kind, build| Probe { label, want: KindRef::Tag(tag), kind, build, intact: None };
        out.push(st("doc", Tag::Doc, Kind::Doc, build_plain_para as fn(&mut Builder) -> NodeId));
        out.push(st("str", Tag::Str, Kind::Str(bytes("x")), build_plain_para));
        out.push(st("row", Tag::Row, Kind::Row { head: true }, build_captioned_table));
        out.push(st("cell", Tag::Cell, Kind::Cell(Cell::new(true, Default::default())), build_captioned_table));
        out.push(st("caption", Tag::Caption, Kind::Caption, build_captioned_table));
        out.push(st("list_item", Tag::ListItem, Kind::ListItem, build_bullet_list));
        out.push(st("definition_list_item", Tag::DefinitionListItem, Kind::DefinitionListItem, build_definition_list));
        out.push(st("term", Tag::Term, Kind::Term, build_definition_list));
        out.push(st("definition", Tag::Definition, Kind::Definition, build_definition_list));
        out.push(st("soft_break", Tag::SoftBreak, Kind::SoftBreak, |b| {
            let x = s(b, "x");
            let sb = b.add_leaf(Kind::SoftBreak);
            let y = s(b, "y");
            block_doc(b, Kind::Para, &[x, sb, y])
        }));
        out.push(st("task_list_item", Tag::TaskListItem, Kind::TaskListItem { checked: true }, build_task_list));
        out
    })
}

/// What the probe measured for one runtime target.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Measured {
    pub node: Vec<Fidelity>,
    pub attrs: Vec<AttrsFidelity>,
}

fn by_label(label: &str) -> usize {
    measured_probes().iter().position(|p| p.label == label).expect("a probe label")
}

fn index_for(kind: &Kind) -> Option<usize> {
    let ps = measured_probes();
    ps.iter().position(|p| p.want.matches(kind)).or_else(|| ps.iter().position(|p| p.kind.tag() == kind.tag()))
}

fn index_for_node(ast: &Ast, id: NodeId) -> Option<usize> {
    match &ast.nodes[id as usize].kind {
        Kind::Section => Some(by_label(if section_heading(ast, id).is_none() { "section(headless)" } else { "section" })),
        Kind::Table => Some(match ast.table_rows(id).next() {
            None => by_label("table"),
            Some(r) => by_label(if r.head { "table" } else { "table(header-less)" }),
        }),
        Kind::Container(c) => Some(by_label(if c.name.is_empty() && c.form == Some(Form::InlineText) {
            "container(anonymous)"
        } else if c.form == Some(Form::InlineText) {
            "container(inline)"
        } else {
            "container(block)"
        })),
        k => index_for(k),
    }
}

impl Measured {
    pub fn for_kind(&self, kind: &Kind) -> Fidelity {
        index_for(kind).map(|i| self.node[i]).unwrap_or(D)
    }
    pub fn for_node(&self, ast: &Ast, id: NodeId) -> Fidelity {
        index_for_node(ast, id).map(|i| self.node[i]).unwrap_or(D)
    }
    pub fn attrs_for_kind(&self, kind: &Kind) -> AttrsFidelity {
        index_for(kind).map(|i| self.attrs[i]).unwrap_or(AttrsFidelity::all(D))
    }
    pub fn attrs_for_node(&self, ast: &Ast, id: NodeId) -> AttrsFidelity {
        index_for_node(ast, id).map(|i| self.attrs[i]).unwrap_or(AttrsFidelity::all(D))
    }
}

/// Serialize a bare tree into a target's bytes; `Err` = the printer refused.
pub type SerializeFn<'a> = &'a dyn Fn(&Ast) -> Result<Vec<u8>, ()>;
/// Parse a target's bytes back; `Err` = the parser refused.
pub type ParseFn<'a> = &'a dyn Fn(&[u8]) -> Result<Document, ()>;

/// Measure a target by round-tripping every probe through it.
pub fn measure(serialize: SerializeFn, parse: ParseFn) -> Measured {
    let mut node = Vec::new();
    let mut attrs = Vec::new();
    for p in measured_probes() {
        let f = measure_node(p, serialize, parse);
        node.push(f);
        attrs.push(if f == X { AttrsFidelity::all(X) } else { measure_attrs(p, serialize, parse) });
    }
    Measured { node, attrs }
}

fn build_probe(p: &Probe, attrs: Option<Attrs>) -> Ast {
    let mut b = Builder::new();
    let root = (p.build)(&mut b);
    if let Some(a) = attrs {
        let id = probed_builder_node(&b, &p.kind).expect("the probe builds its kind");
        b.set_attrs(id, a);
    }
    b.finish(root)
}

fn measure_node(p: &Probe, serialize: SerializeFn, parse: ParseFn) -> Fidelity {
    let ast = build_probe(p, None);
    let Ok(src) = serialize(&ast) else { return X };
    let written = if src.iter().all(|c| matches!(c, b' ' | b'\t' | b'\r' | b'\n')) { X } else { D };
    let Ok(back) = parse(&src) else { return written };
    for n in &back.ast.nodes {
        if !p.want.matches(&n.kind) {
            continue;
        }
        let Some(check) = p.intact else { return F };
        return if check(&back.ast) { F } else { D };
    }
    written
}

fn attr_probe_keys() -> Vec<KeyVal> {
    vec![
        KeyVal::new(b"id", Some(b"idv")),
        KeyVal::new(b"class", Some(b"clsv")),
        KeyVal::new(b"data-k", Some(b"datav")),
        KeyVal::new(b"title", Some(b"titlev")),
    ]
}

fn measure_attrs(p: &Probe, serialize: SerializeFn, parse: ParseFn) -> AttrsFidelity {
    let keys = attr_probe_keys();
    let ast = build_probe(p, Some(Attrs { entries: keys.clone() }));
    let Ok(src) = serialize(&ast) else { return AttrsFidelity::all(X) };
    let Ok(back) = parse(&src) else { return AttrsFidelity::all(D) };
    let found = back.ast.nodes.iter().position(|n| p.want.matches(&n.kind)).map(|i| i as NodeId);
    let seen: Vec<Fidelity> = keys.iter().map(|kv| observed_attr_fidelity(&back.ast, found, &src, kv)).collect();
    AttrsFidelity { id: seen[0], class: seen[1], other: seen[2], title: if seen[3] != seen[2] { Some(seen[3]) } else { None } }
}

fn probed_builder_node(b: &Builder, kind: &Kind) -> Option<NodeId> {
    b.nodes.iter().position(|n| n.kind.tag() == kind.tag()).map(|i| i as NodeId)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    needle.is_empty() || hay.windows(needle.len()).any(|w| w == needle)
}

fn observed_attr_fidelity(back: &Ast, node: Option<NodeId>, src: &[u8], kv: &KeyVal) -> Fidelity {
    let value = kv.value.as_deref().unwrap_or_default();
    if let Some(id) = node {
        if let Some(v) = back.attrs_of(id).get(&kv.key) {
            let kept = if kv.key == b"class" { contains(v, value) } else { v == value };
            if kept {
                return F;
            }
        }
    }
    if contains(src, value) { D } else { X }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_has_a_measured_probe() {
        for tag in Tag::ALL {
            assert!(measured_probes().iter().any(|p| p.kind.tag() == tag), "no measured probe builds a `{}`", tag.name());
        }
    }

    #[test]
    fn analyze_refuses_xml() {
        let mut b = Builder::new();
        let r = build_plain_para(&mut b);
        let ast = b.finish(r);
        assert_eq!(analyze(&ast, ast.root, Target::Xml), Err(AnalyzeError::UnsupportedFormat));
    }

    #[test]
    fn header_less_table_is_reported_only_in_markdown() {
        for p in probes() {
            if p.label != "table(header-less)" && p.label != "table" {
                continue;
            }
            let mut b = Builder::new();
            let root = (p.build)(&mut b);
            let ast = b.finish(root);
            let w = analyze(&ast, ast.root, Target::Markdown).unwrap();
            let tables: Vec<_> = w.iter().filter(|w| w.kind == "table").collect();
            assert_eq!(tables.len(), (p.label == "table(header-less)") as usize);
        }
    }

    #[test]
    fn warning_renders() {
        let w = Warning { fidelity: D, path: "1/0".into(), kind: "superscript", subject: Subject::Node, attrs: vec![] };
        assert_eq!(w.render(Target::Markdown), "`superscript` at `1/0` is not spelled by markdown and will reparse as something else");
        let w = Warning { fidelity: X, path: String::new(), kind: "para", subject: Subject::Attrs, attrs: vec![b"class".to_vec(), b"id".to_vec()] };
        assert_eq!(w.render(Target::Markdown), "`para` at the document root carries attributes (class, id) that markdown cannot write; they are dropped");
    }
}
