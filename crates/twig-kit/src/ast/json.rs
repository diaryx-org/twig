//! A stable, inspectable JSON encoding of the shared AST (`twig convert -o
//! ast`). Every node becomes an object with its `kind`, `span`, optional
//! `content_span`/`marker_span`, its payload fields, and `attrs`/`children`
//! when non-empty. Mirrors `ast/json.zig` byte for byte.

use crate::ast::{
    Alignment, Cell, Container, Form, Kind, KindRef, Link, ListNumbering, NodeId, SmartPunctuationKind, Tag,
};
use crate::document::Document;
use crate::json::{Stringify, Value};

/// Pretty-printed (2-space) JSON for `doc`, with a trailing newline.
pub fn encode(doc: &Document) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut w = Stringify::pretty(&mut out);
        write_node(&mut w, doc, doc.ast.root);
    }
    out.push(b'\n');
    out
}

fn write_span(w: &mut Stringify, s: crate::span::Span) {
    w.begin_array();
    w.int(s.start as u64);
    w.int(s.end as u64);
    w.end_array();
}

fn write_node(w: &mut Stringify, doc: &Document, id: NodeId) {
    let node = &doc.ast.nodes[id as usize];
    w.begin_object();
    w.field("kind");
    w.str(node.kind.kind_name().as_bytes());
    w.field("span");
    write_span(w, doc.span(id));
    if let Some(cs) = doc.content_span(id) {
        w.field("content_span");
        write_span(w, cs);
    }
    if let Some(ms) = doc.marker_span(id) {
        w.field("marker_span");
        write_span(w, ms);
    }
    write_kind_payload(w, &node.kind);
    let attrs = doc.ast.attrs_of(id);
    if !attrs.is_empty() {
        w.field("attrs");
        write_attrs(w, attrs);
    }
    if node.first_child.is_some() {
        w.field("children");
        w.begin_array();
        for c in doc.ast.child_ids(id) {
            write_node(w, doc, c);
        }
        w.end_array();
    }
    w.end_object();
}

pub fn write_attrs(w: &mut Stringify, attrs: &crate::ast::Attrs) {
    w.begin_array();
    for kv in &attrs.entries {
        w.begin_object();
        w.field("key");
        w.str(&kv.key);
        w.field("value");
        w.opt_str(kv.value.as_deref());
        w.end_object();
    }
    w.end_array();
}

/// The fields specific to `kind`'s payload. Also the payload half of the node
/// table (`ast/table.rs`).
pub fn write_kind_payload(w: &mut Stringify, kind: &Kind) {
    match kind {
        Kind::Doc
        | Kind::Para
        | Kind::ThematicBreak
        | Kind::Section
        | Kind::BlockQuote
        | Kind::DefinitionList
        | Kind::LineBlock
        | Kind::Table
        | Kind::ListItem
        | Kind::DefinitionListItem
        | Kind::Term
        | Kind::Definition
        | Kind::Column
        | Kind::Caption
        | Kind::SoftBreak
        | Kind::HardBreak
        | Kind::NonBreakingSpace
        | Kind::InlineMark(_) => {}
        Kind::Heading { level } => {
            w.field("level");
            w.int(*level);
        }
        Kind::CodeBlock { lang, text } => {
            w.field("lang");
            w.opt_str(lang.as_deref());
            w.field("text");
            w.str(text);
        }
        Kind::RawBlock { format, text } | Kind::RawInline { format, text } => {
            w.field("format");
            w.str(format);
            w.field("text");
            w.str(text);
        }
        Kind::Metadata { lang, text } => {
            w.field("lang");
            w.str(lang);
            w.field("text");
            w.str(text);
        }
        Kind::BulletList { tight } | Kind::TaskList { tight } => {
            w.field("tight");
            w.bool(*tight);
        }
        Kind::OrderedList { numbering, tight, start } => {
            w.field("numbering");
            w.str(numbering.name().as_bytes());
            w.field("tight");
            w.bool(*tight);
            w.field("start");
            w.opt_int(*start);
        }
        Kind::TaskListItem { checked } => {
            w.field("checked");
            w.bool(*checked);
        }
        Kind::Line { indent } => {
            w.field("indent");
            w.int(*indent);
        }
        Kind::Row { head } => {
            w.field("head");
            w.bool(*head);
        }
        Kind::Cell(c) => {
            w.field("head");
            w.bool(c.head);
            w.field("alignment");
            w.str(c.alignment.name().as_bytes());
            w.field("colspan");
            w.int(c.colspan);
            w.field("rowspan");
            w.int(c.rowspan);
        }
        Kind::Footnote { label } | Kind::Citation { label } | Kind::Substitution { label } => {
            w.field("label");
            w.str(label);
        }
        Kind::Reference { label, destination } => {
            w.field("label");
            w.str(label);
            w.field("destination");
            w.str(destination);
        }
        Kind::Str(s) => {
            w.field("text");
            w.str(s);
        }
        Kind::TextLeaf { text, .. } | Kind::MarkupLeaf { text, .. } => {
            w.field("text");
            w.str(text);
        }
        Kind::SmartPunctuation(sp) => {
            w.field("punctuation_kind");
            w.str(sp.name().as_bytes());
            w.field("text");
            w.str(sp.ascii().as_bytes());
        }
        Kind::Link(l) | Kind::Image(l) => {
            w.field("destination");
            w.opt_str(l.destination.as_deref());
            w.field("reference");
            w.opt_str(l.reference.as_deref());
        }
        Kind::Container(c) => {
            w.field("name");
            w.str(&c.name);
            w.field("form");
            w.opt_str(c.form.map(|f| f.name().as_bytes()));
            w.field("argument");
            w.opt_str(c.argument.as_deref());
            if let Some(t) = &c.text {
                w.field("text");
                w.str(t);
            }
        }
        Kind::ProcessingInstruction { target, data } => {
            w.field("target");
            w.str(target);
            w.field("data");
            w.str(data);
        }
    }
}

/// Why `read_kind` refused an object: which field, and what was wrong.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FieldProblem {
    pub field: String,
    pub what: String,
}

struct Reader<'a> {
    obj: &'a Value,
}

impl Reader<'_> {
    fn fail<T>(&self, field: &str, what: &str) -> Result<T, FieldProblem> {
        Err(FieldProblem { field: field.to_string(), what: what.to_string() })
    }
    fn get(&self, field: &str) -> Option<&Value> {
        match self.obj.get(field) {
            Some(Value::Null) | None => None,
            Some(v) => Some(v),
        }
    }
    fn opt_str(&self, field: &str) -> Result<Option<Vec<u8>>, FieldProblem> {
        match self.get(field) {
            None => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.clone())),
            Some(_) => self.fail(field, "expected a string"),
        }
    }
    fn str(&self, field: &str) -> Result<Vec<u8>, FieldProblem> {
        match self.opt_str(field)? {
            Some(s) => Ok(s),
            None => self.fail(field, "required string is missing"),
        }
    }
    fn opt_int(&self, field: &str) -> Result<Option<u32>, FieldProblem> {
        match self.get(field) {
            None => Ok(None),
            Some(Value::Int(i)) => match u32::try_from(*i) {
                Ok(v) => Ok(Some(v)),
                Err(_) => self.fail(field, "integer out of range"),
            },
            Some(_) => self.fail(field, "expected an integer"),
        }
    }
    fn int(&self, field: &str) -> Result<u32, FieldProblem> {
        match self.opt_int(field)? {
            Some(v) => Ok(v),
            None => self.fail(field, "required integer is missing"),
        }
    }
    fn boolean(&self, field: &str) -> Result<bool, FieldProblem> {
        match self.get(field) {
            None => self.fail(field, "required boolean is missing"),
            Some(Value::Bool(b)) => Ok(*b),
            Some(_) => self.fail(field, "expected a boolean"),
        }
    }
    fn opt_enum<T>(&self, field: &str, f: impl Fn(&str) -> Option<T>) -> Result<Option<T>, FieldProblem> {
        match self.opt_str(field)? {
            None => Ok(None),
            Some(s) => match f(&String::from_utf8_lossy(&s)) {
                Some(v) => Ok(Some(v)),
                None => self.fail(field, "not one of the names this field takes"),
            },
        }
    }
    fn enumeration<T>(&self, field: &str, f: impl Fn(&str) -> Option<T>) -> Result<T, FieldProblem> {
        match self.opt_enum(field, f)? {
            Some(v) => Ok(v),
            None => self.fail(field, "required name is missing"),
        }
    }
}

/// The kind `r` names, with its payload read from `obj` — the inverse of
/// [`write_kind_payload`].
pub fn read_kind(r: &KindRef, obj: &Value) -> Result<Kind, FieldProblem> {
    let rd = Reader { obj };
    Ok(match r {
        KindRef::Mark(m) => Kind::InlineMark(*m),
        KindRef::TextLeaf(k) => Kind::TextLeaf { kind: *k, text: rd.str("text")? },
        KindRef::MarkupLeaf(k) => Kind::MarkupLeaf { kind: *k, text: rd.str("text")? },
        KindRef::ContainerNamed(_) => return rd.fail("kind", "not a published kind name"),
        KindRef::Tag(tag) => match tag {
            Tag::InlineMark | Tag::TextLeaf | Tag::MarkupLeaf => {
                return rd.fail("kind", "a family is not a published kind name");
            }
            Tag::Doc => Kind::Doc,
            Tag::Para => Kind::Para,
            Tag::ThematicBreak => Kind::ThematicBreak,
            Tag::Section => Kind::Section,
            Tag::BlockQuote => Kind::BlockQuote,
            Tag::DefinitionList => Kind::DefinitionList,
            Tag::LineBlock => Kind::LineBlock,
            Tag::Table => Kind::Table,
            Tag::ListItem => Kind::ListItem,
            Tag::DefinitionListItem => Kind::DefinitionListItem,
            Tag::Term => Kind::Term,
            Tag::Definition => Kind::Definition,
            Tag::Column => Kind::Column,
            Tag::Caption => Kind::Caption,
            Tag::SoftBreak => Kind::SoftBreak,
            Tag::HardBreak => Kind::HardBreak,
            Tag::NonBreakingSpace => Kind::NonBreakingSpace,
            Tag::Heading => Kind::Heading { level: rd.int("level")? },
            Tag::CodeBlock => Kind::CodeBlock { lang: rd.opt_str("lang")?, text: rd.str("text")? },
            Tag::RawBlock => Kind::RawBlock { format: rd.str("format")?, text: rd.str("text")? },
            Tag::Metadata => Kind::Metadata { lang: rd.str("lang")?, text: rd.str("text")? },
            Tag::BulletList => Kind::BulletList { tight: rd.boolean("tight")? },
            Tag::OrderedList => Kind::OrderedList {
                numbering: rd.enumeration("numbering", ListNumbering::from_name)?,
                tight: rd.boolean("tight")?,
                start: rd.opt_int("start")?,
            },
            Tag::TaskList => Kind::TaskList { tight: rd.boolean("tight")? },
            Tag::TaskListItem => Kind::TaskListItem { checked: rd.boolean("checked")? },
            Tag::Line => Kind::Line { indent: rd.opt_int("indent")?.unwrap_or(0) },
            Tag::Row => Kind::Row { head: rd.boolean("head")? },
            Tag::Cell => Kind::Cell(Cell {
                head: rd.boolean("head")?,
                alignment: rd.enumeration("alignment", Alignment::from_name)?,
                colspan: rd.opt_int("colspan")?.unwrap_or(1),
                rowspan: rd.opt_int("rowspan")?.unwrap_or(1),
            }),
            Tag::Footnote => Kind::Footnote { label: rd.str("label")? },
            Tag::Citation => Kind::Citation { label: rd.str("label")? },
            Tag::Substitution => Kind::Substitution { label: rd.str("label")? },
            Tag::Reference => Kind::Reference { label: rd.str("label")?, destination: rd.str("destination")? },
            Tag::Str => Kind::Str(rd.str("text")?),
            Tag::RawInline => Kind::RawInline { format: rd.str("format")?, text: rd.str("text")? },
            Tag::SmartPunctuation => {
                Kind::SmartPunctuation(rd.enumeration("punctuation_kind", SmartPunctuationKind::from_name)?)
            }
            Tag::Link => Kind::Link(Link { destination: rd.opt_str("destination")?, reference: rd.opt_str("reference")? }),
            Tag::Image => {
                Kind::Image(Link { destination: rd.opt_str("destination")?, reference: rd.opt_str("reference")? })
            }
            Tag::Container => Kind::Container(Container {
                name: rd.str("name")?,
                form: rd.opt_enum("form", Form::from_name)?,
                argument: rd.opt_str("argument")?,
                text: rd.opt_str("text")?,
            }),
            Tag::ProcessingInstruction => {
                Kind::ProcessingInstruction { target: rd.str("target")?, data: rd.str("data")? }
            }
        },
    })
}
