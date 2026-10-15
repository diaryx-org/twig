//! The AsciiDoc TCK's ASG (Abstract Semantic Graph) codec — port of
//! `src/languages/asciidoc/asg.zig`. `decode` turns one expected ASG (a corpus
//! case's `asg`) into twig's shared `Document`; `encode` turns a `Document` —
//! decoded or parsed — back. The conformance harness asserts
//! `encode(decode(x)) == x` and `encode(parse(x.adoc)) == x`, structurally
//! (`json_value_eql`): JSON has no canonical key order, so objects compare as
//! unordered key sets.
//!
//! ── Location ────────────────────────────────────────────────────────────────
//! The ASG carries a location on EVERY node, as an inclusive
//! `[{line,col},{line,col}]` pair (1-based); `decode` converts each to a byte
//! `Span` against the case's own source and `encode` converts back.
//!
//! ── Everything ASG-only is DERIVED from source, never stored ────────────────
//! A block's `form`, `delimiter`, `metadata`, a span's `form`, a list's
//! `marker` are re-read from the node's own source by `encode` (through
//! `parser.rs`'s own scanners), because `Attrs` is the channel a document's
//! REAL attributes travel in and the HTML renderer prints every entry.
//!
//! ── What draft-01 has no shape for ──────────────────────────────────────────
//! Tables, superscript/subscript, curved quotes, inline images, footnotes,
//! anchors, attribute references, hard breaks, role spans, body attribute
//! entries and front matter are written as objects of the same SHAPE as their
//! nearest schema neighbour under a name the schema does not use.

use crate::ast::{Builder, Container, Form, InlineMark, KeyVal, Kind, Level, Link, ListNumbering, NodeId, SmartPunctuationKind, TextLeafKind, Attrs, Alignment};
use crate::document::{Bullet, ContainerOrigin, Document, Spelling};
use crate::json::{Stringify, Value};
use crate::span::Span;

use super::parser::{self, index_of, index_of_scalar, index_of_scalar_pos, last_index_of, last_index_of_scalar, tokenize, trim_end, MetaLine, ShorthandKind};

/// Which JSON shape a case's `asg` field holds — the TCK's two test levels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Root {
    Document,
    Inlines,
}

/// Vocabulary coverage, tallied by `decode`: `semantic` instances decoded to
/// a kind with real meaning in twig's model, `generic` instances fell to
/// `Kind::Container`, and `text_nodes` is `semantic`'s `str` subset.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Coverage {
    pub semantic: u32,
    pub generic: u32,
    pub text_nodes: u32,
}

/// A decode failure: an ASG shape the codec has no reading for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UnsupportedAsgNode;

impl std::fmt::Display for UnsupportedAsgNode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("UnsupportedAsgNode")
    }
}

impl std::error::Error for UnsupportedAsgNode {}

type DResult<T> = Result<T, UnsupportedAsgNode>;

fn offset_of_line_col(source: &[u8], line: i64, col: i64) -> usize {
    let mut l = 1;
    let mut i = 0usize;
    while l < line {
        i = match index_of_scalar_pos(source, i, b'\n') {
            Some(nl) => nl + 1,
            None => source.len(),
        };
        l += 1;
    }
    (i as i64 + (col - 1)).max(0) as usize
}

struct LineCol {
    line: u32,
    col: u32,
}

fn line_col_of_offset(source: &[u8], offset: usize) -> LineCol {
    let mut line = 1;
    let mut line_start = 0;
    for (i, &ch) in source[..offset.min(source.len())].iter().enumerate() {
        if ch == b'\n' {
            line += 1;
            line_start = i + 1;
        }
    }
    LineCol { line, col: (offset - line_start + 1) as u32 }
}

fn span_from_loc(source: &[u8], loc: &Value) -> DResult<Span> {
    let a = loc.as_array().ok_or(UnsupportedAsgNode)?;
    if a.len() < 2 {
        return Err(UnsupportedAsgNode);
    }
    let pt = |v: &Value| -> DResult<usize> {
        let line = v.get("line").and_then(|x| x.as_int()).ok_or(UnsupportedAsgNode)?;
        let col = v.get("col").and_then(|x| x.as_int()).ok_or(UnsupportedAsgNode)?;
        Ok(offset_of_line_col(source, line, col))
    };
    let s = pt(&a[0])?;
    let e = pt(&a[1])?;
    Ok(Span::new(s, e + 1))
}

fn get<'v>(o: &'v Value, key: &str) -> DResult<&'v Value> {
    o.get(key).ok_or(UnsupportedAsgNode)
}

fn get_str<'v>(o: &'v Value, key: &str) -> DResult<&'v [u8]> {
    get(o, key)?.as_str().ok_or(UnsupportedAsgNode)
}

fn get_arr<'v>(o: &'v Value, key: &str) -> DResult<&'v [Value]> {
    get(o, key)?.as_array().ok_or(UnsupportedAsgNode)
}

// ── decode ──────────────────────────────────────────────────────────────────

/// Decode `value` (a case's `asg` field, shaped by `root`) against its own
/// `.adoc` source into a `Document`, adding the vocabulary tally into
/// `coverage` when one is given.
pub fn decode(source: &[u8], root: Root, value: &Value, coverage: Option<&mut Coverage>) -> DResult<Document> {
    let mut d = Decoder { b: Builder::new(), source, coverage: Coverage::default() };
    let root_id = match root {
        Root::Document => d.document(value)?,
        Root::Inlines => {
            let items = value.as_array().ok_or(UnsupportedAsgNode)?;
            let ids = d.inline_list(items)?;
            d.b.add_container(Kind::Doc, &ids)
        }
    };
    if let Some(c) = coverage {
        c.semantic += d.coverage.semantic;
        c.generic += d.coverage.generic;
        c.text_nodes += d.coverage.text_nodes;
    }
    Ok(d.b.finish_document(source, root_id))
}

#[derive(Clone, Copy)]
enum Bump {
    Semantic,
    Generic,
    TextNodes,
}

struct Decoder<'s> {
    b: Builder,
    source: &'s [u8],
    coverage: Coverage,
}

impl<'s> Decoder<'s> {
    fn bump(&mut self, which: Bump) {
        let c = &mut self.coverage;
        match which {
            Bump::Semantic => c.semantic += 1,
            Bump::Generic => c.generic += 1,
            Bump::TextNodes => c.text_nodes += 1,
        }
    }

    fn loc(&self, o: &Value) -> DResult<Option<Span>> {
        match o.get("location") {
            Some(v) => Ok(Some(span_from_loc(self.source, v)?)),
            None => Ok(None),
        }
    }

    fn set_loc(&mut self, id: NodeId, o: &Value) -> DResult<()> {
        if let Some(s) = self.loc(o)? {
            self.b.set_span(id, s);
        }
        Ok(())
    }

    fn document(&mut self, value: &Value) -> DResult<NodeId> {
        let o = value;
        let mut children = Vec::new();

        if let Some(attrs_val) = o.get("attributes") {
            let marker = self.b.add_node(Kind::Container(Container::named(b"document-attributes")));
            self.b.set_spelling(marker, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            let mut entries = Vec::new();
            for (k, v) in attrs_val.as_object().ok_or(UnsupportedAsgNode)? {
                let value = match v {
                    Value::Null => None,
                    Value::String(s) => Some(s.as_slice()),
                    _ => return Err(UnsupportedAsgNode),
                };
                entries.push(KeyVal::new(k, value));
            }
            self.b.set_attrs(marker, Attrs { entries });
            self.bump(Bump::Generic);
            children.push(marker);
        }

        if let Some(ho) = o.get("header") {
            let title_ids = self.inline_list(get_arr(ho, "title")?)?;
            let heading = self.b.add_container(Kind::Heading { level: 1 }, &title_ids);
            self.set_loc(heading, ho)?;
            self.bump(Bump::Semantic);
            children.push(heading);
        }

        if let Some(blocks_val) = o.get("blocks") {
            for bv in blocks_val.as_array().ok_or(UnsupportedAsgNode)? {
                let id = self.block(bv)?;
                children.push(id);
            }
        }

        let id = self.b.add_container(Kind::Doc, &children);
        self.set_loc(id, o)?;
        self.bump(Bump::Semantic);
        Ok(id)
    }

    fn blocks(&mut self, o: &Value, out: &mut Vec<NodeId>) -> DResult<()> {
        if let Some(bv) = o.get("blocks") {
            for v in bv.as_array().ok_or(UnsupportedAsgNode)? {
                let id = self.block(v)?;
                out.push(id);
            }
        }
        Ok(())
    }

    fn block(&mut self, o: &Value) -> DResult<NodeId> {
        let name = get_str(o, "name")?;
        let source_span = self.loc(o)?;

        if name == b"paragraph" {
            let inlines = self.inline_list(get_arr(o, "inlines")?)?;
            let id = self.b.add_container(Kind::Para, &inlines);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if name == b"list" {
            let variant = get_str(o, "variant")?;
            let mut items = Vec::new();
            for item in get_arr(o, "items")? {
                let id = self.list_item(item)?;
                items.push(id);
            }
            let marker = get_str(o, "marker")?;
            let kind = if variant == b"unordered" {
                Kind::BulletList { tight: true }
            } else if variant == b"ordered" {
                let m = parser::classify_marker(marker).ok_or(UnsupportedAsgNode)?;
                if m.kind != parser::ListMarkerKind::Ordered {
                    return Err(UnsupportedAsgNode);
                }
                Kind::OrderedList { numbering: m.numbering, tight: true, start: m.start }
            } else if variant == b"callout" {
                Kind::OrderedList { numbering: ListNumbering::Decimal, tight: true, start: None }
            } else {
                return Err(UnsupportedAsgNode);
            };
            let is_bullet = matches!(kind, Kind::BulletList { .. });
            let id = self.b.add_container(kind, &items);
            self.set_loc(id, o)?;
            if is_bullet {
                self.b.set_spelling(id, Spelling::Bullet(bullet_from_marker(marker)?));
            }
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if name == b"dlist" {
            let mut items = Vec::new();
            for item in get_arr(o, "items")? {
                let id = self.dlist_item(item)?;
                items.push(id);
            }
            let id = self.b.add_container(Kind::DefinitionList, &items);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if name == b"heading" {
            let level = get(o, "level")?.as_int().ok_or(UnsupportedAsgNode)? as u32;
            let title_ids = self.inline_list(get_arr(o, "title")?)?;
            let id = self.b.add_container(Kind::Heading { level: level + 1 }, &title_ids);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if is_leaf_name(name) {
            return self.leaf_block(o, name, source_span);
        }

        if name == b"break" {
            let variant = get_str(o, "variant")?;
            let id = if variant == b"thematic" {
                self.b.add_node(Kind::ThematicBreak)
            } else if variant == b"page" {
                let pb = self.b.add_node(Kind::Container(Container::named(b"page-break")));
                self.b.set_spelling(pb, Spelling::ContainerOrigin(ContainerOrigin::Directive));
                pb
            } else {
                return Err(UnsupportedAsgNode);
            };
            self.set_loc(id, o)?;
            self.bump(if variant == b"thematic" { Bump::Semantic } else { Bump::Generic });
            return Ok(id);
        }

        if is_macro_name(name) {
            return self.block_macro(o, name, source_span);
        }

        if is_compound_block(name) {
            let mut children = Vec::new();
            self.blocks(o, &mut children)?;
            let mut semantic = false;
            let kind = if name == b"quote" {
                semantic = true;
                Kind::BlockQuote
            } else if name == b"admonition" {
                let variant = get_str(o, "variant")?;
                Kind::Container(Container::with_form(variant, Form::BlockFenced))
            } else {
                Kind::Container(Container::with_form(name, Form::BlockFenced))
            };
            let is_container = matches!(kind, Kind::Container(_));
            let id = self.b.add_container(kind, &children);
            if is_container {
                self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            }
            self.set_loc(id, o)?;
            self.bump(if semantic { Bump::Semantic } else { Bump::Generic });
            return Ok(id);
        }

        if name == b"section" {
            let level = get(o, "level")?.as_int().ok_or(UnsupportedAsgNode)? as u32;
            let title_ids = self.inline_list(get_arr(o, "title")?)?;
            let heading = self.b.add_container(Kind::Heading { level: level + 1 }, &title_ids);
            // The heading's own extent is the title line.
            if !title_ids.is_empty() {
                let first = self.b.spans[title_ids[0] as usize];
                let src = self.source;
                let line_start = match last_index_of_scalar(&src[..first.start.min(src.len())], b'\n') {
                    Some(nl) => nl + 1,
                    None => 0,
                };
                let line_end = index_of_scalar_pos(src, first.start, b'\n').unwrap_or(src.len());
                self.b.set_span(heading, Span::new(line_start, trim_end(&src[..line_end], b" \t").len()));
            }
            self.bump(Bump::Semantic);
            let mut children = vec![heading];
            self.blocks(o, &mut children)?;
            let id = self.b.add_container(Kind::Section, &children);
            self.set_loc(id, o)?;
            if let Some(sid) = o.get("id") {
                let sid = sid.as_str().ok_or(UnsupportedAsgNode)?;
                self.b.set_attrs(id, Attrs { entries: vec![KeyVal::new(b"id", Some(sid))] });
            }
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        Err(UnsupportedAsgNode)
    }

    /// `listing`, `literal`, `stem` -> `code_block`; `pass` -> `raw_block`;
    /// `verse` -> `line_block`.
    fn leaf_block(&mut self, o: &Value, name: &[u8], source_span: Option<Span>) -> DResult<NodeId> {
        let inlines: &[Value] = match o.get("inlines") {
            Some(v) => v.as_array().ok_or(UnsupportedAsgNode)?,
            None => &[],
        };
        let mut text = Vec::new();
        let mut inner: Option<Span> = None;
        for inl in inlines {
            if get_str(inl, "name")? != b"text" {
                return Err(UnsupportedAsgNode);
            }
            text.extend_from_slice(get_str(inl, "value")?);
            let sp = span_from_loc(self.source, get(inl, "location")?)?;
            inner = Some(match inner {
                Some(s) => Span::new(s.start, sp.end),
                None => sp,
            });
        }
        if name == b"verse" {
            let id = self.verse(inner);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }
        let id = if name == b"pass" {
            self.b.add_leaf(Kind::RawBlock { format: b"html".to_vec(), text })
        } else {
            // The language: from a `[source,lang]` line in the block's own source.
            let lang = source_span.and_then(|ss| source_language(&self.source[ss.start..ss.end], name)).map(|l| l.to_vec());
            self.b.add_leaf(Kind::CodeBlock { lang, text })
        };
        self.set_loc(id, o)?;
        if let Some(sp) = inner {
            self.b.set_content_span(id, sp);
        }
        self.bump(Bump::Semantic);
        Ok(id)
    }

    /// A verse's lines, split out of its content span's source.
    fn verse(&mut self, content: Option<Span>) -> NodeId {
        let mut lines = Vec::new();
        if let Some(c) = content {
            let src = self.source;
            let text = &src[c.start..c.end];
            let widths = parser::indent_widths(text);
            let mut offset = c.start;
            for l in text.split(|&ch| ch == b'\n') {
                let w = l.len() - parser::trim_start(l, b" \t").len();
                let body = &l[w..];
                let depth = if body.is_empty() { 0 } else { widths.iter().position(|&x| x == w).unwrap() as u32 };
                let mut kids = Vec::new();
                if !body.is_empty() {
                    let k = self.b.add_leaf(Kind::Str(body.to_vec()));
                    self.b.set_span(k, Span::new(offset + w, offset + l.len()));
                    kids.push(k);
                }
                let line_id = self.b.add_container(Kind::Line { indent: depth }, &kids);
                self.b.set_span(line_id, Span::new(offset, offset + l.len()));
                lines.push(line_id);
                offset += l.len() + 1;
            }
        }
        let id = self.b.add_container(Kind::LineBlock, &lines);
        if let Some(c) = content {
            self.b.set_content_span(id, c);
        }
        id
    }

    /// `image::` -> `para` > `image`; `audio::`/`video::`/`toc::` -> a leaf
    /// container carrying the target as its argument.
    fn block_macro(&mut self, o: &Value, name: &[u8], source_span: Option<Span>) -> DResult<NodeId> {
        let target: Option<&[u8]> = match o.get("target") {
            Some(t) => Some(t.as_str().ok_or(UnsupportedAsgNode)?),
            None => None,
        };
        if name == b"image" {
            let t = target.ok_or(UnsupportedAsgNode)?;
            let mut kids = Vec::new();
            let mut attrs: Vec<KeyVal> = Vec::new();
            if let Some(ss) = source_span {
                let src = self.source;
                let line = last_line(&src[ss.start..ss.end]);
                if let Some(m) = parser::match_block_macro_text(line) {
                    for e in parser::AttrIter::new(m.attrs) {
                        let key: &[u8] = match e.key {
                            Some(k) => k,
                            None => match e.index {
                                1 => b"alt",
                                2 => b"width",
                                3 => b"height",
                                _ => continue,
                            },
                        };
                        if key == b"alt" {
                            if !e.value.is_empty() {
                                let k = self.b.add_leaf(Kind::Str(e.value.to_vec()));
                                let line_start = ss.end - line.len();
                                let at = line_start + index_of(line, e.value).unwrap_or(0);
                                self.b.set_span(k, Span::new(at, at + e.value.len()));
                                kids = vec![k];
                            }
                        } else if (key == b"width" || key == b"height") && attrs.len() < 2 {
                            attrs.push(KeyVal::new(key, Some(e.value)));
                        }
                    }
                }
            }
            let img = self.b.add_container(Kind::Image(Link { destination: Some(t.to_vec()), reference: None }), &kids);
            if let Some(ss) = source_span {
                let ll = last_line(&self.source[ss.start..ss.end]).len();
                self.b.set_span(img, Span::new(ss.end - ll, ss.end));
            }
            if !attrs.is_empty() {
                self.b.set_attrs(img, Attrs { entries: attrs });
            }
            let id = self.b.add_container(Kind::Para, &[img]);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }
        let id = self.b.add_node(Kind::Container(Container {
            name: name.to_vec(),
            form: Some(Form::BlockLeaf),
            argument: target.filter(|t| !t.is_empty()).map(|t| t.to_vec()),
            text: None,
        }));
        self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
        self.set_loc(id, o)?;
        self.bump(Bump::Generic);
        Ok(id)
    }

    fn list_item(&mut self, o: &Value) -> DResult<NodeId> {
        let mut kids = self.inline_list(get_arr(o, "principal")?)?;
        self.blocks(o, &mut kids)?;
        let id = self.b.add_container(Kind::ListItem, &kids);
        self.set_loc(id, o)?;
        let marker = get_str(o, "marker")?;
        if !marker.is_empty() && (marker[0] == b'*' || marker[0] == b'-') {
            self.b.set_spelling(id, Spelling::Bullet(bullet_from_marker(marker)?));
        }
        self.bump(Bump::Semantic);
        Ok(id)
    }

    fn dlist_item(&mut self, o: &Value) -> DResult<NodeId> {
        let mut kids = Vec::new();
        for term_val in get_arr(o, "terms")? {
            let ids = self.inline_list(term_val.as_array().ok_or(UnsupportedAsgNode)?)?;
            let term = self.b.add_container(Kind::Term, &ids);
            if !ids.is_empty() {
                let s = self.b.spans[ids[0] as usize].start;
                let e = self.b.spans[*ids.last().unwrap() as usize].end;
                self.b.set_span(term, Span::new(s, e));
            }
            kids.push(term);
            self.bump(Bump::Semantic);
        }
        let mut def_kids = Vec::new();
        if let Some(p) = o.get("principal") {
            let ids = self.inline_list(p.as_array().ok_or(UnsupportedAsgNode)?)?;
            def_kids.extend_from_slice(&ids);
        }
        self.blocks(o, &mut def_kids)?;
        if !def_kids.is_empty() {
            let def = self.b.add_container(Kind::Definition, &def_kids);
            let s = self.b.spans[def_kids[0] as usize].start;
            let e = self.b.spans[*def_kids.last().unwrap() as usize].end;
            self.b.set_span(def, Span::new(s, e));
            kids.push(def);
            self.bump(Bump::Semantic);
        }
        let id = self.b.add_container(Kind::DefinitionListItem, &kids);
        self.set_loc(id, o)?;
        self.bump(Bump::Semantic);
        Ok(id)
    }

    fn inline_list(&mut self, items: &[Value]) -> DResult<Vec<NodeId>> {
        let mut ids = Vec::new();
        for item in items {
            let id = self.inline_node(item)?;
            ids.push(id);
        }
        Ok(ids)
    }

    fn inline_node(&mut self, o: &Value) -> DResult<NodeId> {
        let name = get_str(o, "name")?;

        if name == b"text" {
            let id = self.b.add_leaf(Kind::Str(get_str(o, "value")?.to_vec()));
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            self.bump(Bump::TextNodes);
            return Ok(id);
        }

        if name == b"charref" {
            let decoded = parser::decode_charref(get_str(o, "value")?).ok_or(UnsupportedAsgNode)?;
            let id = self.b.add_leaf(Kind::Str(decoded));
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if name == b"raw" {
            let id = self.b.add_leaf(Kind::RawInline { format: b"html".to_vec(), text: get_str(o, "value")?.to_vec() });
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if name == b"span" {
            let variant = get_str(o, "variant")?;
            if variant == b"code" {
                let inlines = get_arr(o, "inlines")?;
                if inlines.len() != 1 {
                    return Err(UnsupportedAsgNode);
                }
                let inner = &inlines[0];
                if get_str(inner, "name")? != b"text" {
                    return Err(UnsupportedAsgNode);
                }
                let id = self.b.add_leaf(Kind::TextLeaf {
                    kind: TextLeafKind::Verbatim,
                    text: get_str(inner, "value")?.to_vec(),
                });
                self.set_loc(id, o)?;
                let cs = span_from_loc(self.source, get(inner, "location")?)?;
                self.b.set_content_span(id, cs);
                self.bump(Bump::Semantic);
                return Ok(id);
            }
            let mark = mark_from_variant(variant).ok_or(UnsupportedAsgNode)?;
            let inlines = self.inline_list(get_arr(o, "inlines")?)?;
            let id = self.b.add_container(Kind::InlineMark(mark), &inlines);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        if name == b"ref" {
            let variant = get_str(o, "variant")?;
            let target = get_str(o, "target")?;
            let inlines = self.inline_list(get_arr(o, "inlines")?)?;
            let mut dest = target.to_vec();
            if variant == b"xref" {
                if index_of_scalar(target, b'#').is_none() {
                    dest = b"#".to_vec();
                    dest.extend_from_slice(target);
                }
            } else if variant != b"link" {
                return Err(UnsupportedAsgNode);
            }
            let id = self.b.add_container(Kind::Link(Link { destination: Some(dest), reference: None }), &inlines);
            self.set_loc(id, o)?;
            self.bump(Bump::Semantic);
            return Ok(id);
        }

        Err(UnsupportedAsgNode)
    }
}

fn is_leaf_name(name: &[u8]) -> bool {
    [&b"listing"[..], b"literal", b"pass", b"stem", b"verse"].contains(&name)
}

fn is_compound_block(name: &[u8]) -> bool {
    [&b"example"[..], b"sidebar", b"open", b"quote", b"admonition"].contains(&name)
}

fn is_macro_name(name: &[u8]) -> bool {
    [&b"image"[..], b"audio", b"video", b"toc"].contains(&name)
}

fn bullet_from_marker(marker: &[u8]) -> DResult<Bullet> {
    match marker.first() {
        Some(b'*') => Ok(Bullet::Star),
        Some(b'-') => Ok(Bullet::Dash),
        Some(b'+') => Ok(Bullet::Plus),
        _ => Err(UnsupportedAsgNode),
    }
}

fn last_line(text: &[u8]) -> &[u8] {
    let t = trim_end(text, b"\n");
    match last_index_of_scalar(t, b'\n') {
        Some(nl) => &t[nl + 1..],
        None => t,
    }
}

/// The `lang` a leaf block's own source names: `[source,ruby]`, `[,ruby]`,
/// a backtick fence's info string, or the stem style itself.
fn source_language<'a>(text: &'a [u8], name: &[u8]) -> Option<&'a [u8]> {
    if name == b"stem" {
        return Some(b"stem");
    }
    for line in text.split(|&c| c == b'\n') {
        let Some(m) = parser::match_meta_line(line) else {
            if let Some(f) = parser::match_fence_line(trim_end(line, b" \t")) {
                return if !f.info.is_empty() { Some(f.info) } else { None };
            }
            return None;
        };
        if let MetaLine::Attrs(interior) = m {
            for e in parser::AttrIter::new(interior) {
                if let Some(k) = e.key {
                    if k == b"language" {
                        return Some(e.value);
                    }
                } else if e.index == 2 && !e.value.is_empty() {
                    return Some(e.value);
                }
            }
        }
    }
    None
}

/// The ASG `span` variants that become an `InlineMark`.
fn mark_from_variant(variant: &[u8]) -> Option<InlineMark> {
    match variant {
        b"strong" => Some(InlineMark::Strong),
        b"emphasis" => Some(InlineMark::Emph),
        b"mark" => Some(InlineMark::Mark),
        _ => None,
    }
}

/// The inverse of `mark_from_variant`, plus the names `encode` gives the
/// marks the schema has no variant for.
fn variant_from_mark(mark: InlineMark) -> &'static [u8] {
    match mark {
        InlineMark::Strong => b"strong",
        InlineMark::Emph => b"emphasis",
        InlineMark::Mark => b"mark",
        InlineMark::Superscript => b"superscript",
        InlineMark::Subscript => b"subscript",
        InlineMark::Insert => b"insert",
        InlineMark::Delete => b"delete",
        InlineMark::DoubleQuoted => b"double_quoted",
        InlineMark::SingleQuoted => b"single_quoted",
    }
}

// ── source-derived facts ───────────────────────────────────────────────────

/// A block's leading metadata lines, re-read from its own source.
#[derive(Clone, Copy, Debug)]
struct Meta<'a> {
    /// Offset of the block's first body line (after the metadata lines).
    body_start: usize,
    title: Option<&'a [u8]>,
    title_at: usize,
    id: Option<&'a [u8]>,
    reftext: Option<&'a [u8]>,
    reftext_at: usize,
    style: Option<&'a [u8]>,
    /// The `[…]` attribute lines' extent, when there is at least one.
    attr_lines: Option<Span>,
}

fn scan_meta(doc: &Document, id: NodeId) -> Meta<'_> {
    let span = doc.span(id);
    let mut meta = Meta {
        body_start: span.start,
        title: None,
        title_at: 0,
        id: None,
        reftext: None,
        reftext_at: 0,
        style: None,
        attr_lines: None,
    };
    let src = &doc.source[..];
    // Only a block that starts on a line of its own can carry metadata.
    if span.start > 0 && src[span.start - 1] != b'\n' {
        return meta;
    }
    let mut pos = span.start;
    while pos < span.end {
        let nl = index_of_scalar_pos(src, pos, b'\n').unwrap_or(src.len());
        let line_end = nl.min(span.end);
        let line = &src[pos..line_end];
        let Some(m) = parser::match_meta_line(line) else { break };
        match m {
            MetaLine::Title(t) => {
                meta.title = Some(t);
                meta.title_at = pos + 1;
            }
            MetaLine::Anchor { id: aid, reftext } => {
                meta.id = Some(aid);
                if let Some(r) = reftext {
                    meta.reftext = Some(r);
                    meta.reftext_at = pos + index_of(line, r).unwrap_or(0);
                }
                meta.attr_lines = Some(match meta.attr_lines {
                    Some(al) => Span::new(al.start, line_end),
                    None => Span::new(pos, line_end),
                });
            }
            MetaLine::Attrs(interior) => {
                meta.attr_lines = Some(match meta.attr_lines {
                    Some(al) => Span::new(al.start, line_end),
                    None => Span::new(pos, line_end),
                });
                for e in parser::AttrIter::new(interior) {
                    if let Some(k) = e.key {
                        if k == b"id" {
                            meta.id = Some(e.value);
                        }
                    } else if e.index == 1 {
                        for p in parser::ShorthandIter::new(e.value) {
                            match p.kind {
                                ShorthandKind::Style => meta.style = Some(p.text),
                                ShorthandKind::Id => meta.id = Some(p.text),
                                _ => {}
                            }
                        }
                    }
                }
            }
        }
        pos = nl + 1;
        if nl >= span.end {
            break;
        }
    }
    meta.body_start = pos.min(span.end);
    meta
}

/// The block's source after its metadata lines.
fn body_text<'d>(doc: &'d Document, id: NodeId, meta: &Meta) -> &'d [u8] {
    &doc.source[meta.body_start..doc.span(id).end]
}

/// The first body line, which for a delimited block IS the delimiter.
fn first_line(text: &[u8]) -> &[u8] {
    let t = &text[..index_of_scalar(text, b'\n').unwrap_or(text.len())];
    trim_end(t, b" \t")
}

/// The delimiter a body's first line spells, or `None`.
fn delimiter_of(line: &[u8]) -> Option<&[u8]> {
    if let Some(f) = parser::match_fence_line(line) {
        return Some(f.fence);
    }
    if is_delimiter_line(line) {
        Some(line)
    } else {
        None
    }
}

/// Whether `line` is a block delimiter (a run of four or more of one
/// delimiter byte, `--`, a backtick fence, or `|===`).
fn is_delimiter_line(line: &[u8]) -> bool {
    if line == b"--" {
        return true;
    }
    if parser::match_fence_line(line).is_some() {
        return true;
    }
    if parser::is_table_delimiter_line(line) {
        return true;
    }
    if line.len() < 4 {
        return false;
    }
    if !b"-.+=_*/".contains(&line[0]) {
        return false;
    }
    line[1..].iter().all(|&c| c == line[0])
}

/// A span's ASG `form`, read off its source: the unconstrained spelling is
/// exactly `DD` + at least one byte + `DD`.
fn span_form(doc: &Document, id: NodeId) -> &'static [u8] {
    let mut s = doc.text(id);
    // A `[.role]` prefix is part of the span's extent but not of its form.
    if !s.is_empty() && s[0] == b'[' {
        if let Some(close) = index_of_scalar(s, b']') {
            s = &s[close + 1..];
        }
    }
    let unconstrained = s.len() >= 5
        && s[0] == s[1]
        && s[s.len() - 1] == s[s.len() - 2]
        && s[0] == s[s.len() - 1]
        && b"*_`#".contains(&s[0]);
    if unconstrained {
        b"unconstrained"
    } else {
        b"constrained"
    }
}

/// A `str` that the parser made from a character reference: its source is
/// `&…;` and reads as something else.
fn charref_source(doc: &Document, id: NodeId) -> Option<&[u8]> {
    let s = doc.text(id);
    let decoded = parser::decode_charref(s)?;
    match &doc.ast.nodes[id as usize].kind {
        Kind::Str(t) if *t == decoded => Some(s),
        _ => None,
    }
}

// ── encode ──────────────────────────────────────────────────────────────────

/// Write `doc` back out as ASG-shaped JSON (2-space indented), `root`-
/// dependent at the top level exactly as `decode` was.
pub fn encode(doc: &Document, root: Root) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let w = Stringify::pretty(&mut out);
        let mut e = Encoder { w, doc };
        match root {
            Root::Document => e.document(doc.ast.root),
            Root::Inlines => {
                e.w.begin_array();
                e.inlines_of(doc.ast.root);
                e.w.end_array();
            }
        }
    }
    out
}

struct Encoder<'d, 'o> {
    w: Stringify<'o>,
    doc: &'d Document,
}

fn key(name: &[u8]) -> String {
    String::from_utf8_lossy(name).into_owned()
}

impl<'d, 'o> Encoder<'d, 'o> {
    fn kind_of(&self, id: NodeId) -> &'d Kind {
        &self.doc.ast.nodes[id as usize].kind
    }

    fn first_child(&self, id: NodeId) -> Option<NodeId> {
        self.doc.ast.nodes[id as usize].first_child
    }

    fn field_str(&mut self, name: &str, value: &[u8]) {
        self.w.field(name);
        self.w.str(value);
    }

    fn field_int(&mut self, name: &str, value: i64) {
        self.w.field(name);
        self.w.int(value);
    }

    fn name_type(&mut self, name: &[u8], ty: &[u8]) {
        self.field_str("name", name);
        self.field_str("type", ty);
    }

    fn point(&mut self, offset: usize) {
        let lc = line_col_of_offset(&self.doc.source, offset);
        self.w.begin_object();
        self.field_int("line", lc.line as i64);
        self.field_int("col", lc.col as i64);
        self.w.end_object();
    }

    /// `"location": [...]` for a half-open span, converted back to the ASG's
    /// inclusive pair. An EMPTY span has no location the ASG can spell.
    fn loc_of(&mut self, span: Span) {
        if span.end <= span.start {
            return;
        }
        self.w.field("location");
        self.w.begin_array();
        self.point(span.start);
        self.point(span.end - 1);
        self.w.end_array();
    }

    fn loc(&mut self, id: NodeId) {
        let sp = self.doc.span(id);
        self.loc_of(sp);
    }

    /// One `text` node with an explicit value and extent.
    fn text_node(&mut self, value: &[u8], span: Span) {
        self.w.begin_object();
        self.name_type(b"text", b"string");
        self.field_str("value", value);
        self.loc_of(span);
        self.w.end_object();
    }

    // ── document ─────────────────────────────────────────────────────────

    fn document(&mut self, id: NodeId) {
        self.w.begin_object();
        self.name_type(b"document", b"block");

        let mut attrs_id: Option<NodeId> = None;
        let mut header_id: Option<NodeId> = None;
        let mut has_body = false;
        for c in self.doc.ast.child_ids(id) {
            match self.kind_of(c) {
                Kind::Container(cnt) if cnt.name == b"document-attributes" => {
                    attrs_id = Some(c);
                    continue;
                }
                // The document title: a level-1 heading directly under the
                // root (a section's own title hangs off the section).
                Kind::Heading { level: 1 } if header_id.is_none() && attrs_id.is_some() => {
                    header_id = Some(c);
                    continue;
                }
                _ => {}
            }
            has_body = true;
        }

        if attrs_id.is_some() {
            // The explicit `:name: value` entries, re-read from the header's
            // own lines.
            self.w.field("attributes");
            self.w.begin_object();
            if let Some(hid) = header_id {
                let header = self.doc.text(hid);
                for line in header.split(|&c| c == b'\n').skip(1) {
                    let Some(entry) = parser::match_attr_entry(line) else { continue };
                    self.w.field(&key(entry.key));
                    self.w.opt_str(entry.value);
                }
            }
            self.w.end_object();
        }

        if let Some(hid) = header_id {
            self.w.field("header");
            self.w.begin_object();
            self.w.field("title");
            self.w.begin_array();
            self.inlines_of(hid);
            self.w.end_array();
            self.authors(hid);
            self.loc(hid);
            self.w.end_object();
        }

        if has_body {
            self.w.field("blocks");
            self.w.begin_array();
            for c in self.doc.ast.child_ids(id) {
                if Some(c) == attrs_id || Some(c) == header_id {
                    continue;
                }
                self.block(c);
            }
            self.w.end_array();
        }

        self.loc(id);
        self.w.end_object();
    }

    /// `header.authors`, from the line after the title when it is one.
    fn authors(&mut self, hid: NodeId) {
        let header = self.doc.text(hid);
        let mut it = header.split(|&c| c == b'\n');
        it.next();
        let Some(line) = it.next() else { return };
        if !parser::is_author_line(line) || parser::match_attr_entry(line).is_some() {
            return;
        }
        let mut any = false;
        for a in parser::AuthorIter::new(line) {
            if !any {
                self.w.field("authors");
                self.w.begin_array();
                any = true;
            }
            self.w.begin_object();
            self.field_str("fullname", a.fullname);
            self.field_str("initials", &a.initials());
            self.field_str("firstname", a.firstname);
            if let Some(m) = a.middlename {
                self.field_str("middlename", m);
            }
            if let Some(l) = a.lastname {
                self.field_str("lastname", l);
            }
            if let Some(e) = a.email {
                self.field_str("address", e);
            }
            self.w.end_object();
        }
        if any {
            self.w.end_array();
        }
    }

    // ── blocks ───────────────────────────────────────────────────────────

    /// `id`, `title`, `reftext` and `metadata`, from the block's own leading
    /// lines. Written into an already-open object.
    fn block_meta(&mut self, meta: &Meta) {
        if let Some(i) = meta.id {
            self.field_str("id", i);
        }
        if let Some(t) = meta.title {
            self.w.field("title");
            self.w.begin_array();
            self.text_node(t, Span::new(meta.title_at, meta.title_at + t.len()));
            self.w.end_array();
        }
        if let Some(r) = meta.reftext {
            self.w.field("reftext");
            self.w.begin_array();
            self.text_node(r, Span::new(meta.reftext_at, meta.reftext_at + r.len()));
            self.w.end_array();
        }
        let Some(lines) = meta.attr_lines else { return };
        let doc = self.doc;
        let region = &doc.source[lines.start..lines.end];
        // Anything but a bare anchor line gets a `metadata` object.
        let any_attr_line =
            region.split(|&c| c == b'\n').any(|line| matches!(parser::match_meta_line(line), Some(MetaLine::Attrs(_))));
        if !any_attr_line {
            return;
        }
        self.w.field("metadata");
        self.w.begin_object();
        for which in [0u8, 1, 2] {
            let mut wrote = false;
            for line in region.split(|&c| c == b'\n') {
                let Some(MetaLine::Attrs(interior)) = parser::match_meta_line(line) else { continue };
                for e in parser::AttrIter::new(interior) {
                    match which {
                        0 => {
                            if let Some(k) = e.key {
                                if [&b"id"[..], b"role", b"options", b"opts", b"title"].contains(&k) {
                                    continue;
                                }
                                self.open_meta_field(&mut wrote, "attributes", true);
                                self.w.field(&key(k));
                                self.w.str(e.value);
                            } else if e.index == 1 {
                                for p in parser::ShorthandIter::new(e.value) {
                                    if p.kind == ShorthandKind::Style {
                                        self.open_meta_field(&mut wrote, "attributes", true);
                                        self.field_str("$1", p.text);
                                    }
                                }
                            } else {
                                self.open_meta_field(&mut wrote, "attributes", true);
                                self.w.field(&format!("${}", e.index));
                                self.w.str(e.value);
                            }
                        }
                        1 => {
                            if let Some(k) = e.key {
                                if k != b"role" {
                                    continue;
                                }
                                for r in tokenize(e.value, b" ") {
                                    self.open_meta_field(&mut wrote, "roles", false);
                                    self.w.str(r);
                                }
                            } else if e.index == 1 {
                                for p in parser::ShorthandIter::new(e.value) {
                                    if p.kind == ShorthandKind::Role {
                                        self.open_meta_field(&mut wrote, "roles", false);
                                        self.w.str(p.text);
                                    }
                                }
                            }
                        }
                        _ => {
                            if let Some(k) = e.key {
                                if k != b"options" && k != b"opts" {
                                    continue;
                                }
                                for o in tokenize(e.value, b", ") {
                                    self.open_meta_field(&mut wrote, "options", false);
                                    self.w.str(o);
                                }
                            } else if e.index == 1 {
                                for p in parser::ShorthandIter::new(e.value) {
                                    if p.kind == ShorthandKind::Option {
                                        self.open_meta_field(&mut wrote, "options", false);
                                        self.w.str(p.text);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if wrote {
                if which == 0 {
                    self.w.end_object();
                } else {
                    self.w.end_array();
                }
            }
        }
        self.loc_of(lines);
        self.w.end_object();
    }

    fn open_meta_field(&mut self, wrote: &mut bool, name: &str, object: bool) {
        if *wrote {
            return;
        }
        *wrote = true;
        self.w.field(name);
        if object {
            self.w.begin_object();
        } else {
            self.w.begin_array();
        }
    }

    fn block(&mut self, id: NodeId) {
        let doc = self.doc;
        let meta = scan_meta(doc, id);
        let body = body_text(doc, id, &meta);
        match self.kind_of(id) {
            Kind::Para => {
                // A paragraph holding only an `image::` macro IS the macro.
                if body.starts_with(b"image::") {
                    if let Some(img) = self.first_child(id) {
                        if let Kind::Image(im) = self.kind_of(img) {
                            self.w.begin_object();
                            self.name_type(b"image", b"block");
                            self.field_str("form", b"macro");
                            if let Some(d) = &im.destination {
                                self.field_str("target", d);
                            }
                            self.block_meta(&meta);
                            self.loc(id);
                            self.w.end_object();
                            return;
                        }
                    }
                }
                self.w.begin_object();
                self.name_type(b"paragraph", b"block");
                self.w.field("inlines");
                self.w.begin_array();
                self.inlines_of(id);
                self.w.end_array();
                self.block_meta(&meta);
                self.loc(id);
                self.w.end_object();
            }
            Kind::CodeBlock { text, .. } => {
                let name = leaf_name_of(&meta, body, b"listing");
                self.leaf_block(id, &meta, body, name, text);
            }
            Kind::RawBlock { text, .. } => self.leaf_block(id, &meta, body, b"pass", text),
            Kind::LineBlock => self.verse_block(id, &meta, body),
            Kind::BlockQuote => self.parent_block(id, &meta, body, b"quote", None),
            Kind::Container(c) => {
                if c.name == b"page-break" {
                    self.w.begin_object();
                    self.name_type(b"break", b"block");
                    self.field_str("variant", b"page");
                    self.block_meta(&meta);
                    self.loc(id);
                    self.w.end_object();
                } else if c.form == Some(Form::BlockLeaf) && is_macro_name(&c.name) {
                    self.w.begin_object();
                    self.name_type(&c.name, b"block");
                    self.field_str("form", b"macro");
                    if let Some(a) = &c.argument {
                        self.field_str("target", a);
                    }
                    self.block_meta(&meta);
                    self.loc(id);
                    self.w.end_object();
                } else if parser::admonition_name(parser::upper_label(&c.name)).is_some() {
                    self.parent_block(id, &meta, body, b"admonition", Some(&c.name));
                } else {
                    self.parent_block(id, &meta, body, &c.name, None);
                }
            }
            Kind::BulletList { .. } | Kind::TaskList { .. } => self.list(id, &meta, b"unordered"),
            Kind::OrderedList { .. } => {
                let marker = item_marker(doc, self.first_child(id));
                let variant: &[u8] = if !marker.is_empty() && marker[0] == b'<' { b"callout" } else { b"ordered" };
                self.list(id, &meta, variant);
            }
            Kind::DefinitionList => self.dlist(id, &meta),
            Kind::Heading { level } => {
                self.w.begin_object();
                self.name_type(b"heading", b"block");
                self.w.field("title");
                self.w.begin_array();
                self.inlines_of(id);
                self.w.end_array();
                self.field_int("level", *level as i64 - 1);
                self.block_meta(&meta);
                self.loc(id);
                self.w.end_object();
            }
            Kind::Section => {
                self.w.begin_object();
                self.name_type(b"section", b"block");
                let kids = doc.ast.child_ids(id);
                let heading_id = kids[0];
                self.w.field("title");
                self.w.begin_array();
                self.inlines_of(heading_id);
                self.w.end_array();
                let level = match self.kind_of(heading_id) {
                    Kind::Heading { level } => *level as i64,
                    _ => 1,
                };
                self.field_int("level", level - 1);
                let mut m = meta;
                if m.id.is_none() {
                    m.id = heading_anchor(doc.text(heading_id));
                }
                self.block_meta(&m);
                self.loc(id);
                if kids.len() > 1 {
                    self.w.field("blocks");
                    self.w.begin_array();
                    for &c in &kids[1..] {
                        self.block(c);
                    }
                    self.w.end_array();
                }
                self.w.end_object();
            }
            Kind::ThematicBreak => {
                self.w.begin_object();
                self.name_type(b"break", b"block");
                self.field_str("variant", b"thematic");
                self.block_meta(&meta);
                self.loc(id);
                self.w.end_object();
            }
            Kind::Table => self.table(id, &meta),
            // ── extensions ──
            Kind::Substitution { label } => {
                self.w.begin_object();
                self.name_type(b"attributeEntry", b"block");
                self.field_str("attribute", label);
                if doc.ast.attrs_of(id).find(b"unset").is_some() {
                    self.w.field("value");
                    self.w.null();
                } else {
                    self.w.field("inlines");
                    self.w.begin_array();
                    self.inlines_of(id);
                    self.w.end_array();
                }
                self.loc(id);
                self.w.end_object();
            }
            Kind::Metadata { lang, text } => {
                self.w.begin_object();
                self.name_type(b"frontmatter", b"block");
                self.field_str("lang", lang);
                self.w.field("inlines");
                self.w.begin_array();
                if let Some(cs) = doc.content_span(id) {
                    self.text_node(text, cs);
                }
                self.w.end_array();
                self.loc(id);
                self.w.end_object();
            }
            // A footnote definition is written at its reference; anything
            // else has no ASG reading (`unreachable` in the Zig).
            _ => {}
        }
    }

    fn leaf_block(&mut self, id: NodeId, meta: &Meta, body: &[u8], name: &[u8], text: &[u8]) {
        self.w.begin_object();
        self.name_type(name, b"block");
        self.leaf_form(body);
        if !text.is_empty() {
            self.w.field("inlines");
            self.w.begin_array();
            let cs = self.doc.content_span(id).unwrap_or_else(|| self.doc.span(id));
            self.text_node(text, cs);
            self.w.end_array();
        }
        self.block_meta(meta);
        self.loc(id);
        self.w.end_object();
    }

    /// `form` (and `delimiter`) from the body's first line.
    fn leaf_form(&mut self, body: &[u8]) {
        let first = first_line(body);
        if let Some(d) = delimiter_of(first) {
            self.field_str("form", b"delimited");
            self.field_str("delimiter", d);
        } else if !body.is_empty() && (body[0] == b' ' || body[0] == b'\t') {
            self.field_str("form", b"indented");
        } else {
            self.field_str("form", b"paragraph");
        }
    }

    fn verse_block(&mut self, id: NodeId, meta: &Meta, body: &[u8]) {
        self.w.begin_object();
        self.name_type(b"verse", b"block");
        self.leaf_form(body);
        let doc = self.doc;
        if self.first_child(id).is_some() {
            self.w.field("inlines");
            self.w.begin_array();
            let mut fuser = Fuser::default();
            let mut first = true;
            for line in doc.ast.child_ids(id) {
                let sp = doc.span(line);
                if !first {
                    fuser.text(b"\n", Span::new(sp.start - 1, sp.start));
                }
                first = false;
                // The indentation the tree records as depth is real source
                // text in the ASG's value.
                let body_start = match self.first_child(line) {
                    Some(fc) => doc.span(fc).start,
                    None => sp.end,
                };
                if body_start > sp.start {
                    fuser.text(&doc.source[sp.start..body_start], Span::new(sp.start, body_start));
                }
                for c in doc.ast.child_ids(line) {
                    fuser.feed(self, c);
                }
            }
            fuser.flush(self);
            self.w.end_array();
        }
        self.block_meta(meta);
        self.loc(id);
        self.w.end_object();
    }

    /// A parent block. `variant` is set for an admonition.
    fn parent_block(&mut self, id: NodeId, meta: &Meta, body: &[u8], name: &[u8], variant: Option<&[u8]>) {
        self.w.begin_object();
        self.name_type(name, b"block");
        if let Some(v) = variant {
            self.field_str("variant", v);
        }
        let first = first_line(body);
        if let Some(d) = delimiter_of(first) {
            self.field_str("form", b"delimited");
            self.field_str("delimiter", d);
        } else if !body.is_empty() && body[0] == b'>' {
            self.field_str("form", b"delimited");
            self.field_str("delimiter", b">");
        } else {
            self.field_str("form", b"paragraph");
        }
        if self.first_child(id).is_some() {
            self.w.field("blocks");
            self.w.begin_array();
            for c in self.doc.ast.child_ids(id) {
                self.block(c);
            }
            self.w.end_array();
        }
        self.block_meta(meta);
        self.loc(id);
        self.w.end_object();
    }

    fn list(&mut self, id: NodeId, meta: &Meta, variant: &[u8]) {
        self.w.begin_object();
        self.name_type(b"list", b"block");
        self.field_str("variant", variant);
        let marker = item_marker(self.doc, self.first_child(id));
        self.field_str("marker", marker);
        self.w.field("items");
        self.w.begin_array();
        for c in self.doc.ast.child_ids(id) {
            self.list_item(c);
        }
        self.w.end_array();
        self.block_meta(meta);
        self.loc(id);
        self.w.end_object();
    }

    fn list_item(&mut self, id: NodeId) {
        let doc = self.doc;
        self.w.begin_object();
        self.name_type(b"listItem", b"block");
        self.field_str("marker", item_marker(doc, Some(id)));
        self.w.field("principal");
        self.w.begin_array();
        let mut fuser = Fuser::default();
        // A checklist item's box is text to a reader of the ASG, which has no
        // checkbox: `[x] ` is written back where the parser found it.
        if let Kind::TaskListItem { .. } = self.kind_of(id) {
            if let Some(m) = doc.marker_span(id) {
                let item_end = doc.span(id).end;
                let box_end = (m.end + 4).min(item_end);
                let mut end = box_end;
                while end < item_end && doc.source[end] == b' ' {
                    end += 1;
                }
                fuser.text(&doc.source[m.end..end], Span::new(m.end, end));
            }
        }
        let kids = doc.ast.child_ids(id);
        let mut first_block: Option<usize> = None;
        for (k, &c) in kids.iter().enumerate() {
            if self.kind_of(c).level() == Level::Block {
                first_block = Some(k);
                break;
            }
            fuser.feed(self, c);
        }
        fuser.flush(self);
        self.w.end_array();
        if let Some(fb) = first_block {
            self.w.field("blocks");
            self.w.begin_array();
            for &b in &kids[fb..] {
                self.block(b);
            }
            self.w.end_array();
        }
        self.loc(id);
        self.w.end_object();
    }

    fn dlist(&mut self, id: NodeId, meta: &Meta) {
        self.w.begin_object();
        self.name_type(b"dlist", b"block");
        let marker = dlist_marker(self.doc, self.first_child(id));
        self.field_str("marker", marker);
        self.w.field("items");
        self.w.begin_array();
        for c in self.doc.ast.child_ids(id) {
            self.dlist_item(c);
        }
        self.w.end_array();
        self.block_meta(meta);
        self.loc(id);
        self.w.end_object();
    }

    fn dlist_item(&mut self, id: NodeId) {
        let doc = self.doc;
        self.w.begin_object();
        self.name_type(b"dlistItem", b"block");
        self.field_str("marker", dlist_marker(doc, Some(id)));
        self.w.field("terms");
        self.w.begin_array();
        let mut definition: Option<NodeId> = None;
        for c in doc.ast.child_ids(id) {
            match self.kind_of(c) {
                Kind::Term => {
                    self.w.begin_array();
                    self.inlines_of(c);
                    self.w.end_array();
                }
                Kind::Definition => definition = Some(c),
                _ => {}
            }
        }
        self.w.end_array();
        if let Some(def) = definition {
            let kids = doc.ast.child_ids(def);
            let mut first_block: Option<usize> = None;
            let mut any_inline = false;
            let mut fuser = Fuser::default();
            for (k, &c) in kids.iter().enumerate() {
                if self.kind_of(c).level() == Level::Block {
                    first_block = Some(k);
                    break;
                }
                if !any_inline {
                    self.w.field("principal");
                    self.w.begin_array();
                    any_inline = true;
                }
                fuser.feed(self, c);
            }
            fuser.flush(self);
            if any_inline {
                self.w.end_array();
            }
            if let Some(fb) = first_block {
                self.w.field("blocks");
                self.w.begin_array();
                for &b in &kids[fb..] {
                    self.block(b);
                }
                self.w.end_array();
            }
        }
        self.loc(id);
        self.w.end_object();
    }

    /// A table — a twig extension; the ASG (draft-01) does not model tables.
    fn table(&mut self, id: NodeId, meta: &Meta) {
        let doc = self.doc;
        self.w.begin_object();
        self.name_type(b"table", b"block");
        self.w.field("rows");
        self.w.begin_array();
        for c in doc.ast.child_ids(id) {
            let Kind::Row { head } = self.kind_of(c) else { continue };
            self.w.begin_object();
            self.name_type(b"row", b"block");
            if *head {
                self.w.field("header");
                self.w.bool(true);
            }
            self.w.field("cells");
            self.w.begin_array();
            for cell in doc.ast.child_ids(c) {
                let Kind::Cell(ck) = self.kind_of(cell) else { continue };
                self.w.begin_object();
                self.name_type(b"cell", b"block");
                if ck.colspan != 1 {
                    self.field_int("colspan", ck.colspan as i64);
                }
                if ck.rowspan != 1 {
                    self.field_int("rowspan", ck.rowspan as i64);
                }
                if ck.alignment != Alignment::Default {
                    self.field_str("align", ck.alignment.name().as_bytes());
                }
                self.w.field("inlines");
                self.w.begin_array();
                self.inlines_of(cell);
                self.w.end_array();
                self.loc(cell);
                self.w.end_object();
            }
            self.w.end_array();
            self.loc(c);
            self.w.end_object();
        }
        self.w.end_array();
        self.block_meta(meta);
        self.loc(id);
        self.w.end_object();
    }

    // ── inlines ──────────────────────────────────────────────────────────

    /// The children of `id` as an inline list, adjacent text fused.
    fn inlines_of(&mut self, id: NodeId) {
        let mut fuser = Fuser::default();
        for c in self.doc.ast.child_ids(id) {
            fuser.feed(self, c);
        }
        fuser.flush(self);
    }

    fn inline_node(&mut self, id: NodeId) {
        let doc = self.doc;
        match self.kind_of(id) {
            Kind::Str(s) => self.text_node(s, doc.span(id)),
            Kind::SmartPunctuation(sp) => self.text_node(glyph(*sp), doc.span(id)),
            Kind::InlineMark(m) => {
                self.w.begin_object();
                self.name_type(b"span", b"inline");
                self.field_str("variant", variant_from_mark(*m));
                self.field_str("form", span_form(doc, id));
                self.inline_attrs(id);
                self.w.field("inlines");
                self.w.begin_array();
                self.inlines_of(id);
                self.w.end_array();
                self.loc(id);
                self.w.end_object();
            }
            Kind::TextLeaf { kind: lk, text } => match lk {
                TextLeafKind::Verbatim => {
                    self.w.begin_object();
                    self.name_type(b"span", b"inline");
                    self.field_str("variant", b"code");
                    self.field_str("form", span_form(doc, id));
                    self.inline_attrs(id);
                    self.w.field("inlines");
                    self.w.begin_array();
                    let cs = doc.content_span(id).unwrap_or_else(|| doc.span(id));
                    self.text_node(text, cs);
                    self.w.end_array();
                    self.loc(id);
                    self.w.end_object();
                }
                TextLeafKind::Url | TextLeafKind::Email => {
                    self.w.begin_object();
                    self.name_type(b"ref", b"inline");
                    self.field_str("variant", b"link");
                    if *lk == TextLeafKind::Email {
                        let mut t = b"mailto:".to_vec();
                        t.extend_from_slice(text);
                        // The Zig formats into a 512-byte buffer and falls
                        // back to the bare address when it does not fit.
                        if t.len() > 512 {
                            t = text.clone();
                        }
                        self.field_str("target", &t);
                    } else {
                        self.field_str("target", text);
                    }
                    self.w.field("inlines");
                    self.w.begin_array();
                    let cs = doc.content_span(id).unwrap_or_else(|| doc.span(id));
                    self.text_node(text, cs);
                    self.w.end_array();
                    self.loc(id);
                    self.w.end_object();
                }
                TextLeafKind::InlineMath => {
                    self.w.begin_object();
                    self.name_type(b"stem", b"inline");
                    self.w.field("inlines");
                    self.w.begin_array();
                    if let Some(cs) = doc.content_span(id) {
                        self.text_node(text, cs);
                    }
                    self.w.end_array();
                    self.loc(id);
                    self.w.end_object();
                }
                TextLeafKind::FootnoteReference => {
                    self.w.begin_object();
                    self.name_type(b"footnote", b"inline");
                    self.field_str("target", text);
                    self.w.field("inlines");
                    self.w.begin_array();
                    if let Some(def) = self.footnote_definition(text) {
                        // The definition holds one paragraph of the note's inlines.
                        if let Some(para) = self.first_child(def) {
                            self.inlines_of(para);
                        }
                    }
                    self.w.end_array();
                    self.loc(id);
                    self.w.end_object();
                }
                TextLeafKind::SubstitutionReference => {
                    self.w.begin_object();
                    self.name_type(b"attributeReference", b"inline");
                    self.field_str("target", text);
                    self.loc(id);
                    self.w.end_object();
                }
                // No ASG reading (`unreachable` in the Zig).
                TextLeafKind::Symb | TextLeafKind::DisplayMath | TextLeafKind::CitationReference => {}
            },
            Kind::Link(l) => {
                let src = doc.text(id);
                let xref = src.starts_with(b"<<") || src.starts_with(b"xref:");
                self.w.begin_object();
                self.name_type(b"ref", b"inline");
                self.field_str("variant", if xref { b"xref" } else { b"link" });
                let dest: &[u8] = l.destination.as_deref().unwrap_or(b"");
                let target = if xref && !dest.is_empty() && dest[0] == b'#' { &dest[1..] } else { dest };
                self.field_str("target", target);
                self.w.field("inlines");
                self.w.begin_array();
                self.inlines_of(id);
                self.w.end_array();
                self.loc(id);
                self.w.end_object();
            }
            Kind::Image(im) => {
                self.w.begin_object();
                self.name_type(b"image", b"inline");
                if let Some(d) = &im.destination {
                    self.field_str("target", d);
                }
                self.w.field("inlines");
                self.w.begin_array();
                self.inlines_of(id);
                self.w.end_array();
                self.loc(id);
                self.w.end_object();
            }
            Kind::RawInline { text, .. } => {
                self.w.begin_object();
                self.name_type(b"raw", b"string");
                self.field_str("value", text);
                self.loc(id);
                self.w.end_object();
            }
            Kind::NonBreakingSpace => {
                self.w.begin_object();
                self.name_type(b"charref", b"string");
                self.field_str("value", b"&#160;");
                self.loc(id);
                self.w.end_object();
            }
            Kind::HardBreak => {
                self.w.begin_object();
                self.name_type(b"linebreak", b"inline");
                self.loc(id);
                self.w.end_object();
            }
            Kind::Container(c) => {
                self.w.begin_object();
                self.name_type(if !c.name.is_empty() { &c.name } else { b"span" }, b"inline");
                if c.name.is_empty() {
                    self.field_str("variant", b"styled");
                }
                self.inline_attrs(id);
                self.w.field("inlines");
                self.w.begin_array();
                self.inlines_of(id);
                self.w.end_array();
                self.loc(id);
                self.w.end_object();
            }
            _ => {}
        }
    }

    /// `id` / `roles` on an inline that carries attributes — an extension
    /// the schema's spans have no field for.
    fn inline_attrs(&mut self, id: NodeId) {
        let attrs = self.doc.ast.attrs_of(id);
        if let Some(i) = attrs.get(b"id") {
            self.field_str("id", i);
        }
        if let Some(cls) = attrs.get(b"class") {
            self.w.field("roles");
            self.w.begin_array();
            for r in tokenize(cls, b" ") {
                self.w.str(r);
            }
            self.w.end_array();
        }
    }

    fn footnote_definition(&self, label: &[u8]) -> Option<NodeId> {
        self.doc.ast.nodes.iter().find(|n| matches!(&n.kind, Kind::Footnote { label: l } if l == label)).map(|n| n.id)
    }
}

/// Fuses runs of adjacent text-bearing inlines into one ASG `text` node
/// whose location spans them all.
#[derive(Default)]
struct Fuser {
    buf: Vec<u8>,
    start: usize,
    end: usize,
}

impl Fuser {
    fn text(&mut self, value: &[u8], span: Span) {
        if self.buf.is_empty() {
            self.start = span.start;
        }
        self.buf.extend_from_slice(value);
        self.end = span.end;
    }

    fn feed(&mut self, e: &mut Encoder, id: NodeId) {
        let doc = e.doc;
        match e.kind_of(id) {
            Kind::Str(s) => {
                if let Some(raw) = charref_source(doc, id) {
                    self.flush(e);
                    e.w.begin_object();
                    e.name_type(b"charref", b"string");
                    e.field_str("value", raw);
                    e.loc(id);
                    e.w.end_object();
                    return;
                }
                self.text(s, doc.span(id));
            }
            Kind::SmartPunctuation(sp) => self.text(glyph(*sp), doc.span(id)),
            _ => {
                self.flush(e);
                e.inline_node(id);
            }
        }
    }

    fn flush(&mut self, e: &mut Encoder) {
        if self.buf.is_empty() {
            return;
        }
        e.text_node(&self.buf, Span::new(self.start, self.end));
        self.buf.clear();
    }
}

/// The character a replacement resolved to — what a processor writes for it.
fn glyph(sp: SmartPunctuationKind) -> &'static [u8] {
    match sp {
        SmartPunctuationKind::EmDash => "\u{2014}".as_bytes(),
        SmartPunctuationKind::EnDash => "\u{2013}".as_bytes(),
        SmartPunctuationKind::Ellipses => "\u{2026}".as_bytes(),
        SmartPunctuationKind::LeftSingleQuote => "\u{2018}".as_bytes(),
        SmartPunctuationKind::RightSingleQuote => "\u{2019}".as_bytes(),
        SmartPunctuationKind::LeftDoubleQuote => "\u{201c}".as_bytes(),
        SmartPunctuationKind::RightDoubleQuote => "\u{201d}".as_bytes(),
    }
}

/// An item's marker as written: the item's source up to its first space.
fn item_marker(doc: &Document, id: Option<NodeId>) -> &[u8] {
    let Some(i) = id else { return b"" };
    let s = doc.text(i);
    &s[..index_of_scalar(s, b' ').unwrap_or(s.len())]
}

/// A description list's marker (`::`, `:::`, `;;`), from its first item's
/// source.
fn dlist_marker(doc: &Document, id: Option<NodeId>) -> &[u8] {
    let Some(i) = id else { return b"::" };
    let s = doc.text(i);
    let line = &s[..index_of_scalar(s, b'\n').unwrap_or(s.len())];
    match parser::match_list_marker_text(line) {
        Some(m) if m.kind == parser::ListMarkerKind::Description => m.text,
        _ => b"::",
    }
}

/// The leaf-block name for a `code_block`: the style when it names a leaf
/// block, else the delimiter's, else `fallback`.
fn leaf_name_of<'a>(meta: &Meta<'a>, body: &[u8], fallback: &'a [u8]) -> &'a [u8] {
    if let Some(s) = meta.style {
        if parser::is_leaf_style(s) {
            return parser::leaf_name_for_style(s);
        }
    }
    let first = first_line(body);
    if is_delimiter_line(first) {
        return match first[0] {
            b'-' | b'`' => b"listing",
            b'.' => b"literal",
            b'+' => b"pass",
            _ => fallback,
        };
    }
    if !body.is_empty() && (body[0] == b' ' || body[0] == b'\t') {
        return b"literal";
    }
    fallback
}

/// The trailing ` [[id]]` of a heading line, if it carries one.
fn heading_anchor(heading_text: &[u8]) -> Option<&[u8]> {
    let t = trim_end(heading_text, b" \t");
    if !t.ends_with(b"]]") {
        return None;
    }
    let at = last_index_of(t, b" [[")?;
    let inner = &t[at + 3..t.len() - 2];
    if inner.is_empty() {
        return None;
    }
    Some(match index_of_scalar(inner, b',') {
        Some(c) => &inner[..c],
        None => inner,
    })
}

// ── comparison ──────────────────────────────────────────────────────────────

/// Structural equality over JSON value trees: objects compare as unordered
/// key sets, arrays compare element-by-element in order.
pub fn json_value_eql(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) => true,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        (Value::Int(x), Value::Int(y)) => x == y,
        (Value::Float(x), Value::Float(y)) => x == y,
        (Value::String(x), Value::String(y)) => x == y,
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(p, q)| json_value_eql(p, q)),
        (Value::Object(x), Value::Object(y)) => {
            if x.len() != y.len() {
                return false;
            }
            for (k, v) in x {
                let Some((_, other)) = y.iter().rev().find(|(k2, _)| k2 == k) else { return false };
                if !json_value_eql(v, other) {
                    return false;
                }
            }
            true
        }
        _ => false,
    }
}
