//! A deliberately small, forgiving HTML tokenizer and tree builder. Port of
//! `src/languages/html/parser.zig`.
//!
//! Not a browser-grade implementation of the HTML parsing algorithm, but it
//! does the useful, unsurprising parts for document conversion: HTML syntax,
//! character references, void elements, raw-text/RCDATA elements, and the
//! common optional end tags. Malformed input is recovered into a best-effort
//! tree instead of being rejected.

use crate::ast::{compact, Alignment, Builder, Container, Form, InlineMark, Kind, KeyVal, Link, ListNumbering, NodeId, TextLeafKind, Attrs, Cell};
use crate::document::{ContainerOrigin, Document, Spelling};
use crate::span::Span;

pub struct Parser<'s> {
    source: &'s [u8],
    pos: usize,
    builder: Builder,
}

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' || c == 0x0C
}

fn is_name_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b':' || c == b'_' || c == b'-'
}

fn is_void(name: &[u8]) -> bool {
    super::serializer::is_void_element(name)
}

fn is_raw_text(name: &[u8]) -> bool {
    matches!(name, b"script" | b"style" | b"xmp" | b"iframe" | b"noembed" | b"noframes" | b"plaintext")
}

fn is_rcdata(name: &[u8]) -> bool {
    name == b"textarea" || name == b"title"
}

/// Enough of HTML's optional-end-tag rules to make ordinary hand-authored
/// HTML tree correctly.
fn implicitly_closes(parent: &[u8], child: &[u8]) -> bool {
    match parent {
        b"li" => child == b"li",
        b"dt" | b"dd" => child == b"dt" || child == b"dd",
        b"p" => is_block_start(child),
        b"rt" | b"rp" => child == b"rt" || child == b"rp",
        b"option" => child == b"option" || child == b"optgroup",
        b"optgroup" => child == b"optgroup",
        b"thead" | b"tbody" => child == b"tbody" || child == b"tfoot",
        b"tr" => child == b"tr",
        b"td" | b"th" => child == b"td" || child == b"th",
        _ => false,
    }
}

fn is_block_start(name: &[u8]) -> bool {
    const NAMES: [&[u8]; 26] = [
        b"address", b"article", b"aside", b"blockquote", b"div", b"dl", b"fieldset", b"footer", b"form", b"h1", b"h2",
        b"h3", b"h4", b"h5", b"h6", b"header", b"hr", b"main", b"menu", b"nav", b"ol", b"p", b"pre", b"section",
        b"table", b"ul",
    ];
    NAMES.contains(&name)
}

fn trim_start<'t>(s: &'t [u8], set: &[u8]) -> &'t [u8] {
    let n = s.iter().take_while(|c| set.contains(c)).count();
    &s[n..]
}

fn trim_end<'t>(s: &'t [u8], set: &[u8]) -> &'t [u8] {
    let n = s.iter().rev().take_while(|c| set.contains(c)).count();
    &s[..s.len() - n]
}

fn trim<'t>(s: &'t [u8], set: &[u8]) -> &'t [u8] {
    trim_end(trim_start(s, set), set)
}

/// Zig's `std.fmt.parseInt` for an unsigned type whose maximum is `max`: an
/// optional `+`/`-` sign, `_` digit separators (not first or last), and a
/// negative value only when it is zero.
pub(crate) fn zig_parse_uint(buf: &[u8], base: u32, max: u64) -> Option<u64> {
    let (neg, digits) = match buf.first()? {
        b'+' => (false, &buf[1..]),
        b'-' => (true, &buf[1..]),
        _ => (false, buf),
    };
    if digits.is_empty() || digits[0] == b'_' || digits[digits.len() - 1] == b'_' {
        return None;
    }
    let mut acc: u64 = 0;
    for &c in digits {
        if c == b'_' {
            continue;
        }
        let d = (c as char).to_digit(36)?;
        if d >= base {
            return None;
        }
        if acc != 0 {
            acc = acc.checked_mul(base as u64).filter(|&v| v <= max)?;
        } else if neg {
            if d != 0 {
                return None;
            }
            continue;
        }
        acc = acc.checked_add(d as u64).filter(|&v| v <= max)?;
    }
    Some(acc)
}

fn attr_value<'a>(attrs: &'a [KeyVal], key: &[u8]) -> Option<&'a [u8]> {
    attrs.iter().find(|a| a.key == key)?.value.as_deref()
}

/// Twig's HTML renderer spells alignment `style="text-align: left;"`;
/// `align="left"` is read too.
fn cell_alignment(attrs: &[KeyVal]) -> Alignment {
    if let Some(style) = attr_value(attrs, b"style") {
        if let Some(at) = style.windows(10).position(|w| w == b"text-align") {
            let rest = trim_start(&style[at + 10..], b" \t");
            if !rest.is_empty() && rest[0] == b':' {
                let rest = trim_start(&rest[1..], b" \t");
                let end = rest.iter().position(|c| b"; \t".contains(c)).unwrap_or(rest.len());
                if let Some(a) = alignment_from_name(&rest[..end]) {
                    return a;
                }
            }
        }
    }
    if let Some(value) = attr_value(attrs, b"align") {
        if let Some(a) = alignment_from_name(value) {
            return a;
        }
    }
    Alignment::Default
}

/// A cell's `colspan`/`rowspan` as the shared model's grid extent: at least
/// 1, and 1 for anything that isn't a positive integer.
fn cell_extent(attrs: &[KeyVal], key: &[u8]) -> u32 {
    let Some(value) = attr_value(attrs, key) else { return 1 };
    match zig_parse_uint(trim(value, b" \t\r\n"), 10, u32::MAX as u64) {
        Some(0) | None => 1,
        Some(n) => n as u32,
    }
}

fn alignment_from_name(name: &[u8]) -> Option<Alignment> {
    if name.eq_ignore_ascii_case(b"left") {
        Some(Alignment::Left)
    } else if name.eq_ignore_ascii_case(b"right") {
        Some(Alignment::Right)
    } else if name.eq_ignore_ascii_case(b"center") {
        Some(Alignment::Center)
    } else {
        None
    }
}

fn language_from_class(class: &[u8]) -> Option<&[u8]> {
    for item in class.split(|&c| c == b' ').filter(|t| !t.is_empty()) {
        if item.starts_with(b"language-") && item.len() > 9 {
            return Some(&item[9..]);
        }
    }
    None
}

fn append_entity(out: &mut Vec<u8>, body: &[u8]) -> bool {
    if body.len() > 1 && body[0] == b'#' {
        let cp = if body.len() > 2 && (body[1] == b'x' || body[1] == b'X') {
            zig_parse_uint(&body[2..], 16, 0x1F_FFFF)
        } else {
            zig_parse_uint(&body[1..], 10, 0x1F_FFFF)
        };
        let Some(cp) = cp else { return false };
        let Some(ch) = char::from_u32(cp as u32) else { return false };
        let mut buf = [0u8; 4];
        out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
        return true;
    }
    let replacement: &[u8] = match body {
        b"amp" => b"&",
        b"lt" => b"<",
        b"gt" => b">",
        b"quot" => b"\"",
        b"apos" => b"'",
        b"nbsp" => b"\xc2\xa0",
        b"copy" => b"\xc2\xa9",
        b"reg" => b"\xc2\xae",
        b"hellip" => b"\xe2\x80\xa6",
        b"ndash" => b"\xe2\x80\x93",
        b"mdash" => b"\xe2\x80\x94",
        b"lsquo" => b"\xe2\x80\x98",
        b"rsquo" => b"\xe2\x80\x99",
        b"ldquo" => b"\xe2\x80\x9c",
        b"rdquo" => b"\xe2\x80\x9d",
        _ => return false,
    };
    out.extend_from_slice(replacement);
    true
}

/// Decode the character references this parser knows. An `&` with a later
/// `;` that does not name one is copied through verbatim up to that `;`.
fn decode_text(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] != b'&' {
            out.push(text[i]);
            i += 1;
            continue;
        }
        let Some(semi) = text[i + 1..].iter().position(|&c| c == b';').map(|p| p + i + 1) else {
            out.push(b'&');
            i += 1;
            continue;
        };
        let body = &text[i + 1..semi];
        if !append_entity(&mut out, body) {
            out.extend_from_slice(&text[i..semi + 1]);
        }
        i = semi + 1;
    }
    out
}

fn find_from(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if from > hay.len() {
        return None;
    }
    hay[from..].windows(needle.len()).position(|w| w == needle).map(|p| p + from)
}

#[derive(Clone, Copy)]
enum Side {
    Leading,
    Trailing,
}

impl<'s> Parser<'s> {
    pub fn new(source: &'s [u8]) -> Parser<'s> {
        Parser { source, pos: 0, builder: Builder::new() }
    }

    pub fn parse(mut self) -> Document {
        let mut children = self.parse_children(None);
        self.drop_formatting_whitespace(&mut children);
        let doc = self.builder.add_container(Kind::Doc, &children);
        self.builder.set_span(doc, Span::new(0, self.source.len()));
        // What `drop_formatting_whitespace`, `flatten_row_groups` and the
        // `<code>` absorption leave unreferenced is collected here.
        compact::run(self.builder.finish_document(self.source, doc))
    }

    fn skip_space(&mut self) {
        while self.pos < self.source.len() && is_space(self.source[self.pos]) {
            self.pos += 1;
        }
    }

    fn at_ignore_case(&self, needle: &[u8]) -> bool {
        self.pos + needle.len() <= self.source.len()
            && self.source[self.pos..self.pos + needle.len()].eq_ignore_ascii_case(needle)
    }

    fn read_name_lower(&mut self) -> Vec<u8> {
        let start = self.pos;
        while self.pos < self.source.len() && is_name_byte(self.source[self.pos]) {
            self.pos += 1;
        }
        self.source[start..self.pos].to_ascii_lowercase()
    }

    fn end_tag_matches(&self, name: &[u8]) -> bool {
        let s = self.source;
        if self.pos + 3 > s.len() || s[self.pos] != b'<' || s[self.pos + 1] != b'/' {
            return false;
        }
        let start = self.pos + 2;
        let mut i = start;
        while i < s.len() && is_name_byte(s[i]) {
            i += 1;
        }
        i > start && s[start..i].eq_ignore_ascii_case(name) && (i == s.len() || is_space(s[i]) || s[i] == b'>')
    }

    fn consume_end_tag(&mut self) {
        let s = self.source;
        self.pos += 2;
        while self.pos < s.len() && is_name_byte(s[self.pos]) {
            self.pos += 1;
        }
        while self.pos < s.len() && s[self.pos] != b'>' {
            self.pos += 1;
        }
        if self.pos < s.len() {
            self.pos += 1;
        }
    }

    fn parse_children(&mut self, parent: Option<&[u8]>) -> Vec<NodeId> {
        let s = self.source;
        let mut children = Vec::new();
        while self.pos < s.len() {
            if s[self.pos] != b'<' {
                if let Some(id) = self.parse_text_until(s.len(), true) {
                    children.push(id);
                }
                continue;
            }
            let next = s.get(self.pos + 1).copied();
            if self.at_ignore_case(b"<!--") {
                children.push(self.parse_comment());
            } else if self.at_ignore_case(b"<!doctype") {
                children.push(self.parse_doctype());
            } else if next == Some(b'?') {
                children.push(self.parse_processing_instruction());
            } else if next == Some(b'/') {
                // Let every nested parser see a close tag; the matching
                // ancestor consumes it.
                if parent.is_some() {
                    break;
                }
                // A stray close tag is ignored; consume it so recovery
                // always makes progress.
                self.consume_end_tag();
            } else if next.is_some_and(is_name_byte) {
                let start = self.pos + 1;
                let mut end = start;
                while end < s.len() && is_name_byte(s[end]) {
                    end += 1;
                }
                if let Some(name) = parent {
                    if implicitly_closes(name, &s[start..end]) {
                        break;
                    }
                }
                children.push(self.parse_element());
            } else if next == Some(b'!') {
                // HTML calls unknown declarations "bogus comments".
                children.push(self.parse_bogus_comment());
            } else {
                let start = self.pos;
                self.pos += 1;
                let id = self.builder.add_leaf(Kind::Str(s[start..self.pos].to_vec()));
                self.builder.set_span(id, Span::new(start, self.pos));
                children.push(id);
            }
        }
        children
    }

    fn parse_element(&mut self) -> NodeId {
        let s = self.source;
        let start = self.pos;
        self.pos += 1;
        let name = self.read_name_lower();
        let attrs = self.parse_attributes();

        let mut self_closing = false;
        if self.pos < s.len() && s[self.pos] == b'/' {
            self_closing = true;
            self.pos += 1;
            self.skip_space();
        }
        if self.pos < s.len() && s[self.pos] == b'>' {
            self.pos += 1;
        }
        let content_start = self.pos;

        if self_closing || is_void(&name) {
            let mut no_children: Vec<NodeId> = Vec::new();
            let kind = self.semantic_kind(&name, &attrs, &mut no_children);
            let id = self.builder.add_container(kind, &no_children);
            self.builder.set_span(id, Span::new(start, self.pos));
            self.mark_element_origin(id);
            self.set_element_attrs(id, &attrs);
            return id;
        }

        // A raw-text or rcdata element's body is one run of TEXT, carried as
        // the node's payload (`Container.text`). The rcdata run is
        // entity-decoded; a raw one is the bytes.
        if is_raw_text(&name) || is_rcdata(&name) {
            let raw_start = self.pos;
            let end = self.raw_text_end(&name);
            self.pos = end;
            let raw = &s[raw_start..end];
            let text = if is_rcdata(&name) { decode_text(raw) } else { raw.to_vec() };
            if self.pos < s.len() && self.end_tag_matches(&name) {
                self.consume_end_tag();
            }
            let id = self.builder.add_leaf(Kind::Container(Container { name: name.clone(), text: Some(text), ..Default::default() }));
            self.builder.set_span(id, Span::new(start, self.pos));
            self.builder.set_content_span(id, Span::new(raw_start, end));
            self.mark_element_origin(id);
            self.builder.set_attrs(id, Attrs { entries: attrs });
            return id;
        }

        let mut children = self.parse_children(Some(&name));
        let content_end = self.pos;
        if self.pos < s.len() && self.end_tag_matches(&name) {
            self.consume_end_tag();
        }
        let kind = self.semantic_kind(&name, &attrs, &mut children);
        let id = self.builder.add_container(kind, &children);
        self.builder.set_span(id, Span::new(start, self.pos));
        self.builder.set_content_span(id, Span::new(content_start, content_end));
        self.mark_element_origin(id);
        self.set_element_attrs(id, &attrs);
        id
    }

    /// Give an element's node the attributes its kind does not already own:
    /// `href` of a link, `src`/`alt` of an image, `start` of an ordered list.
    fn set_element_attrs(&mut self, id: NodeId, attrs: &[KeyVal]) {
        let owned: &[&[u8]] = match self.builder.kind(id) {
            Kind::Link(v) if v.destination.is_some() => &[b"href"],
            Kind::Image(v) if v.destination.is_some() => &[b"src", b"alt"],
            Kind::OrderedList { start: Some(_), .. } => &[b"start"],
            _ => &[],
        };
        let kept: Vec<KeyVal> = attrs.iter().filter(|kv| !owned.contains(&kv.key.as_slice())).cloned().collect();
        self.builder.set_attrs(id, Attrs { entries: kept });
    }

    /// Record that a generic container came from a TAG.
    fn mark_element_origin(&mut self, id: NodeId) {
        if matches!(self.builder.kind(id), Kind::Container(_)) {
            self.builder.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Element));
        }
    }

    /// Map the subset of HTML that Twig's own HTML renderer emits back to the
    /// shared semantic vocabulary. Unknown elements remain generic markup.
    fn semantic_kind(&mut self, name: &[u8], attrs: &[KeyVal], children: &mut Vec<NodeId>) -> Kind {
        match name {
            b"p" => return Kind::Para,
            b"h1" => return Kind::Heading { level: 1 },
            b"h2" => return Kind::Heading { level: 2 },
            b"h3" => return Kind::Heading { level: 3 },
            b"h4" => return Kind::Heading { level: 4 },
            b"h5" => return Kind::Heading { level: 5 },
            b"h6" => return Kind::Heading { level: 6 },
            b"hr" => return Kind::ThematicBreak,
            b"br" => return Kind::HardBreak,
            b"blockquote" => {
                self.drop_formatting_whitespace(children);
                return Kind::BlockQuote;
            }
            b"div" => {
                self.drop_formatting_whitespace(children);
                return Kind::Container(Container::with_form(b"div", Form::BlockFenced));
            }
            b"html" | b"body" | b"main" | b"section" => {
                self.drop_formatting_whitespace(children);
                return Kind::Section;
            }
            b"ul" => {
                self.drop_formatting_whitespace(children);
                return Kind::BulletList { tight: self.list_is_tight(children) };
            }
            b"ol" => {
                self.drop_formatting_whitespace(children);
                let start = attr_value(attrs, b"start")
                    .and_then(|v| zig_parse_uint(v, 10, u32::MAX as u64))
                    .map(|n| n as u32);
                return Kind::OrderedList { numbering: ListNumbering::Decimal, tight: self.list_is_tight(children), start };
            }
            b"li" => {
                self.drop_formatting_whitespace(children);
                self.wrap_list_item_in_paragraph(children);
                return Kind::ListItem;
            }
            b"table" => {
                self.drop_formatting_whitespace(children);
                self.flatten_row_groups(children);
                return Kind::Table;
            }
            b"caption" => {
                self.drop_formatting_whitespace(children);
                return Kind::Caption;
            }
            b"tr" => {
                self.drop_formatting_whitespace(children);
                return Kind::Row { head: self.row_is_head(children) };
            }
            b"th" | b"td" => {
                self.drop_formatting_whitespace(children);
                return Kind::Cell(Cell {
                    head: name == b"th",
                    alignment: cell_alignment(attrs),
                    colspan: cell_extent(attrs, b"colspan"),
                    rowspan: cell_extent(attrs, b"rowspan"),
                });
            }
            b"em" | b"i" => return Kind::InlineMark(InlineMark::Emph),
            b"strong" | b"b" => return Kind::InlineMark(InlineMark::Strong),
            b"mark" => return Kind::InlineMark(InlineMark::Mark),
            b"ins" | b"u" => return Kind::InlineMark(InlineMark::Insert),
            b"del" | b"s" => return Kind::InlineMark(InlineMark::Delete),
            b"sup" => return Kind::InlineMark(InlineMark::Superscript),
            b"sub" => return Kind::InlineMark(InlineMark::Subscript),
            b"span" => return Kind::Container(Container::with_form(b"span", Form::InlineText)),
            _ => {}
        }
        if name == b"a" {
            if let Some(destination) = attr_value(attrs, b"href") {
                return Kind::Link(Link { destination: Some(destination.to_vec()), reference: None });
            }
        }
        if name == b"img" {
            if let Some(destination) = attr_value(attrs, b"src") {
                // The shared `image` model carries alt text as child content.
                if let Some(alt) = attr_value(attrs, b"alt") {
                    let child = self.builder.add_leaf(Kind::Str(alt.to_vec()));
                    *children = vec![child];
                }
                return Kind::Image(Link { destination: Some(destination.to_vec()), reference: None });
            }
        }
        // Both of the next two mappings ABSORB their child into an opaque text
        // payload; the child is left unreferenced for compaction.
        if name == b"code" && children.len() == 1 {
            if let Kind::Str(text) = self.builder.kind(children[0]) {
                let text = text.clone();
                children.clear();
                return Kind::TextLeaf { kind: TextLeafKind::Verbatim, text };
            }
        }
        if name == b"pre" && children.len() == 1 {
            let child = children[0];
            if let Kind::TextLeaf { kind: TextLeafKind::Verbatim, text } = self.builder.kind(child) {
                let text = text.clone();
                let class = self.builder.attrs_of(child).and_then(|a| a.get(b"class")).unwrap_or(b"");
                let lang = language_from_class(class).map(|l| l.to_vec());
                children.clear();
                return Kind::CodeBlock { lang, text };
            }
        }
        Kind::Container(Container::named(name))
    }

    /// `<thead>`/`<tbody>`/`<tfoot>` have no counterpart in the shared table
    /// model: splice each group's rows into the table and drop the wrapper.
    fn flatten_row_groups(&mut self, children: &mut Vec<NodeId>) {
        if !children.iter().any(|&id| self.is_row_group(id)) {
            return;
        }
        let mut out = Vec::new();
        for &id in children.iter() {
            if !self.is_row_group(id) {
                out.push(id);
                continue;
            }
            let mut child = self.builder.nodes[id as usize].first_child;
            while let Some(cid) = child {
                out.push(cid);
                child = self.builder.nodes[cid as usize].next_sibling;
            }
        }
        // The wrapper is a generic element, so the layout whitespace INSIDE
        // it was never dropped.
        self.drop_formatting_whitespace(&mut out);
        *children = out;
    }

    fn is_row_group(&self, id: NodeId) -> bool {
        match self.builder.kind(id) {
            Kind::Container(c) => c.name == b"thead" || c.name == b"tbody" || c.name == b"tfoot",
            _ => false,
        }
    }

    fn row_is_head(&self, children: &[NodeId]) -> bool {
        let mut saw_cell = false;
        for &id in children {
            if let Kind::Cell(c) = self.builder.kind(id) {
                if !c.head {
                    return false;
                }
                saw_cell = true;
            }
        }
        saw_cell
    }

    fn is_formatting_whitespace(&self, id: NodeId) -> bool {
        match self.builder.kind(id) {
            Kind::Str(text) => trim(text, b" \t\r\n").is_empty(),
            _ => false,
        }
    }

    /// The shared HTML printer puts newlines between block tags. Those are
    /// layout, not document text: drop whitespace-only text, and trim the
    /// block-facing edges of the text runs that remain.
    fn drop_formatting_whitespace(&mut self, children: &mut Vec<NodeId>) {
        children.retain(|&id| !self.is_formatting_whitespace(id));
        let kept = children.as_slice();
        for (i, &id) in kept.iter().enumerate() {
            if !matches!(self.builder.kind(id), Kind::Str(_)) {
                continue;
            }
            if i == 0 || self.is_block_kind(kept[i - 1]) {
                self.trim_text_edge(id, Side::Leading);
            }
            if i + 1 == kept.len() || self.is_block_kind(kept[i + 1]) {
                self.trim_text_edge(id, Side::Trailing);
            }
        }
    }

    fn is_block_kind(&self, id: NodeId) -> bool {
        matches!(
            self.builder.kind(id),
            Kind::Para
                | Kind::Heading { .. }
                | Kind::ThematicBreak
                | Kind::Section
                | Kind::Container(_)
                | Kind::CodeBlock { .. }
                | Kind::BlockQuote
                | Kind::BulletList { .. }
                | Kind::OrderedList { .. }
                | Kind::TaskList { .. }
                | Kind::DefinitionList
                | Kind::Table
                | Kind::ListItem
                | Kind::TaskListItem { .. }
                | Kind::DefinitionListItem
                | Kind::Term
                | Kind::Definition
        )
    }

    fn trim_text_edge(&mut self, id: NodeId, side: Side) {
        let Kind::Str(text) = self.builder.kind(id) else { return };
        const WS: &[u8] = b" \t\r\n\x0c";
        let trimmed = match side {
            Side::Leading => trim_start(text, WS),
            Side::Trailing => trim_end(text, WS),
        };
        if trimmed.len() == text.len() {
            return;
        }
        // Whitespace is never part of a character reference, so the trimmed
        // byte count maps 1:1 onto source bytes at this edge.
        let removed = text.len() - trimmed.len();
        let trimmed = trimmed.to_vec();
        *self.builder.kind_mut(id) = Kind::Str(trimmed);
        let mut sp = self.builder.span(id);
        match side {
            Side::Leading => sp.start += removed,
            Side::Trailing => sp.end -= removed,
        }
        self.builder.set_span(id, sp);
    }

    /// Wrap each maximal run of inline content in a list item into a
    /// paragraph, leaving block-level children as siblings.
    fn wrap_list_item_in_paragraph(&mut self, children: &mut Vec<NodeId>) {
        let items = std::mem::take(children);
        let mut out = Vec::with_capacity(items.len());
        let mut i = 0;
        while i < items.len() {
            if self.is_block_kind(items[i]) {
                out.push(items[i]);
                i += 1;
                continue;
            }
            let run_start = i;
            while i < items.len() && !self.is_block_kind(items[i]) {
                i += 1;
            }
            let run = &items[run_start..i];
            let span_start = self.builder.span(run[0]).start;
            let span_end = self.builder.span(run[run.len() - 1]).end;
            let para = self.builder.add_container(Kind::Para, run);
            self.builder.set_span(para, Span::new(span_start, span_end));
            self.builder.set_content_span(para, Span::new(span_start, span_end));
            out.push(para);
        }
        *children = out;
    }

    fn list_is_tight(&self, children: &[NodeId]) -> bool {
        for &item in children {
            if *self.builder.kind(item) != Kind::ListItem {
                continue;
            }
            let Some(first) = self.builder.nodes[item as usize].first_child else { continue };
            let para_start = self.builder.span(first).start;
            if *self.builder.kind(first) != Kind::Para
                || para_start >= self.source.len()
                || !self.source[para_start..].starts_with(b"<p")
            {
                return true;
            }
        }
        false
    }

    fn raw_text_end(&self, name: &[u8]) -> usize {
        let s = self.source;
        if name == b"plaintext" {
            return s.len();
        }
        let mut i = self.pos;
        while i + 2 < s.len() {
            if s[i] == b'<' && s[i + 1] == b'/' {
                let mut j = i + 2;
                while j < s.len() && is_name_byte(s[j]) {
                    j += 1;
                }
                if j > i + 2 && s[i + 2..j].eq_ignore_ascii_case(name) && (j == s.len() || is_space(s[j]) || s[j] == b'>')
                {
                    return i;
                }
            }
            i += 1;
        }
        s.len()
    }

    fn parse_attributes(&mut self) -> Vec<KeyVal> {
        let s = self.source;
        let mut attrs = Vec::new();
        while self.pos < s.len() {
            self.skip_space();
            if self.pos >= s.len() || s[self.pos] == b'>' || s[self.pos] == b'/' {
                break;
            }
            if !is_name_byte(s[self.pos]) {
                self.pos += 1;
                continue;
            }
            let key = self.read_name_lower();
            let mut value = None;
            self.skip_space();
            if self.pos < s.len() && s[self.pos] == b'=' {
                self.pos += 1;
                self.skip_space();
                value = Some(self.read_attribute_value());
            }
            attrs.push(KeyVal { key, value });
        }
        attrs
    }

    fn read_attribute_value(&mut self) -> Vec<u8> {
        let s = self.source;
        let start = self.pos;
        if self.pos < s.len() && (s[self.pos] == b'\'' || s[self.pos] == b'"') {
            let quote = s[self.pos];
            self.pos += 1;
            let quoted_start = self.pos;
            while self.pos < s.len() && s[self.pos] != quote {
                self.pos += 1;
            }
            let end = self.pos;
            if self.pos < s.len() {
                self.pos += 1;
            }
            return decode_text(&s[quoted_start..end]);
        }
        while self.pos < s.len() && !is_space(s[self.pos]) && s[self.pos] != b'>' && s[self.pos] != b'/' {
            self.pos += 1;
        }
        decode_text(&s[start..self.pos])
    }

    fn parse_text_until(&mut self, limit: usize, decode_entities: bool) -> Option<NodeId> {
        let start = self.pos;
        while self.pos < limit && self.source[self.pos] != b'<' {
            self.pos += 1;
        }
        self.parse_text_range(start, self.pos, decode_entities)
    }

    fn parse_text_range(&mut self, start: usize, end: usize, decode_entities: bool) -> Option<NodeId> {
        if end == start {
            return None;
        }
        let raw = &self.source[start..end];
        let text = if decode_entities { decode_text(raw) } else { raw.to_vec() };
        let id = self.builder.add_leaf(Kind::Str(text));
        self.builder.set_span(id, Span::new(start, end));
        Some(id)
    }

    fn markup_leaf(&mut self, kind: crate::ast::MarkupLeafKind, start: usize, content: Span) -> NodeId {
        let id = self.builder.add_leaf(Kind::MarkupLeaf { kind, text: content.of(self.source).to_vec() });
        self.builder.set_span(id, Span::new(start, self.pos));
        self.builder.set_content_span(id, content);
        id
    }

    fn parse_comment(&mut self) -> NodeId {
        let start = self.pos;
        self.pos += 4;
        let content_start = self.pos;
        let end = find_from(self.source, self.pos, b"-->").unwrap_or(self.source.len());
        self.pos = if end < self.source.len() { end + 3 } else { end };
        self.markup_leaf(crate::ast::MarkupLeafKind::Comment, start, Span::new(content_start, end))
    }

    fn parse_bogus_comment(&mut self) -> NodeId {
        let start = self.pos;
        self.pos += 2;
        let content_start = self.pos;
        while self.pos < self.source.len() && self.source[self.pos] != b'>' {
            self.pos += 1;
        }
        let end = self.pos;
        if self.pos < self.source.len() {
            self.pos += 1;
        }
        self.markup_leaf(crate::ast::MarkupLeafKind::Comment, start, Span::new(content_start, end))
    }

    fn parse_doctype(&mut self) -> NodeId {
        let start = self.pos;
        self.pos += b"<!doctype".len();
        let content_start = self.pos;
        while self.pos < self.source.len() && self.source[self.pos] != b'>' {
            self.pos += 1;
        }
        let end = self.pos;
        if self.pos < self.source.len() {
            self.pos += 1;
        }
        self.markup_leaf(crate::ast::MarkupLeafKind::Doctype, start, Span::new(content_start, end))
    }

    fn parse_processing_instruction(&mut self) -> NodeId {
        let s = self.source;
        let start = self.pos;
        self.pos += 2;
        let target_start = self.pos;
        while self.pos < s.len() && is_name_byte(s[self.pos]) {
            self.pos += 1;
        }
        let target = s[target_start..self.pos].to_vec();
        self.skip_space();
        let data_start = self.pos;
        let end = find_from(s, self.pos, b"?>").unwrap_or(s.len());
        self.pos = if end < s.len() { end + 2 } else { end };
        let id = self.builder.add_leaf(Kind::ProcessingInstruction { target, data: s[data_start..end].to_vec() });
        self.builder.set_span(id, Span::new(start, self.pos));
        // `content_span` stays `None`: a PI's payload is split across two
        // fields, so there is no single interior to point at.
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::MarkupLeafKind;
    use crate::languages::html::serializer::serialize_alloc;

    fn parse(src: &str) -> Document {
        Parser::new(src.as_bytes()).parse()
    }

    fn first(doc: &Document, id: NodeId) -> NodeId {
        doc.ast.node(id).first_child.unwrap()
    }

    fn next(doc: &Document, id: NodeId) -> NodeId {
        doc.ast.node(id).next_sibling.unwrap()
    }

    fn parse_to_html(src: &[u8]) -> Vec<u8> {
        let doc = Parser::new(src).parse();
        serialize_alloc(&doc.ast, None).unwrap()
    }

    #[test]
    fn maps_block_markup_and_decodes_character_references() {
        let doc = parse("<!doctype html><DIV class=x disabled>Hi &amp; &#x1f642;</DIV>");
        let doctype = first(&doc, doc.ast.root);
        let div = next(&doc, doctype);
        let text = first(&doc, div);
        assert_eq!(doc.ast.kind(doctype), &Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: b" html".to_vec() });
        assert_eq!(doc.ast.kind(div).container().unwrap().name, b"div");
        assert_eq!(doc.ast.attrs_of(div).get(b"class"), Some(&b"x"[..]));
        assert_eq!(doc.ast.attrs_of(div).find(b"disabled").unwrap().value, None);
        assert_eq!(doc.ast.kind(text), &Kind::Str("Hi & 🙂".as_bytes().to_vec()));
    }

    #[test]
    fn maps_tables_to_the_shared_table_vocabulary() {
        let doc = parse("<table><caption>C</caption><tr><th>a</th></tr><tr><td>1</td></tr></table>");
        let table = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(table), &Kind::Table);
        let caption = first(&doc, table);
        assert_eq!(doc.ast.kind(caption), &Kind::Caption);
        let head_row = next(&doc, caption);
        let body_row = next(&doc, head_row);
        assert_eq!(doc.ast.kind(head_row), &Kind::Row { head: true });
        assert_eq!(doc.ast.kind(body_row), &Kind::Row { head: false });
        assert!(matches!(doc.ast.kind(first(&doc, head_row)), Kind::Cell(c) if c.head));
        assert!(matches!(doc.ast.kind(first(&doc, body_row)), Kind::Cell(c) if !c.head));
    }

    #[test]
    fn splices_row_groups_into_the_table() {
        let doc = parse("<table>\n<thead>\n<tr>\n<th>a</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>1</td>\n</tr>\n</tbody>\n</table>");
        let table = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(table), &Kind::Table);
        let rows: Vec<_> = doc.ast.children(table).collect();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|n| matches!(n.kind, Kind::Row { .. })));
    }

    #[test]
    fn reads_cell_alignment_from_style_and_legacy_attribute() {
        let doc = parse("<table><tr><td style=\"text-align: right;\">a</td><td align=\"CENTER\">b</td><td style=\"color: red\">c</td></tr></table>");
        let row = first(&doc, first(&doc, doc.ast.root));
        let a = first(&doc, row);
        let b = next(&doc, a);
        let c = next(&doc, b);
        let al = |id| match doc.ast.kind(id) {
            Kind::Cell(c) => c.alignment,
            _ => panic!(),
        };
        assert_eq!(al(a), Alignment::Right);
        assert_eq!(al(b), Alignment::Center);
        assert_eq!(al(c), Alignment::Default);
    }

    #[test]
    fn reads_cell_colspan_and_rowspan() {
        let doc = parse("<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td>b</td><td rowspan=\"0\">c</td><td colspan=\"nope\">d</td></tr></table>");
        let row = first(&doc, first(&doc, doc.ast.root));
        let a = first(&doc, row);
        let b = next(&doc, a);
        let c = next(&doc, b);
        let d = next(&doc, c);
        let cell = |id| match doc.ast.kind(id) {
            Kind::Cell(c) => *c,
            _ => panic!(),
        };
        assert_eq!((cell(a).colspan, cell(a).rowspan), (2, 3));
        assert_eq!((cell(b).colspan, cell(b).rowspan), (1, 1));
        assert_eq!(cell(c).rowspan, 1);
        assert_eq!(doc.ast.attrs_of(c).get(b"rowspan"), Some(&b"0"[..]));
        assert_eq!(cell(d).colspan, 1);
    }

    #[test]
    fn closes_li_and_p_implicitly_and_keeps_script_raw() {
        let doc = parse("<ul><li>one<li>two</ul><p>a<div>b</div><script>a < b &amp;</script>");
        let ul = first(&doc, doc.ast.root);
        let li1 = first(&doc, ul);
        let li2 = next(&doc, li1);
        let p = next(&doc, ul);
        let div = next(&doc, p);
        let script = next(&doc, div);
        assert_eq!(doc.ast.kind(li1), &Kind::ListItem);
        assert_eq!(doc.ast.kind(li2), &Kind::ListItem);
        assert_eq!(doc.ast.kind(p), &Kind::Para);
        assert_eq!(doc.ast.kind(div).container().unwrap().name, b"div");
        assert!(doc.ast.node(script).first_child.is_none());
        assert_eq!(doc.ast.kind(script).container().unwrap().text.as_deref(), Some(&b"a < b &amp;"[..]));
        assert!(doc.ast.kind(script).holds_opaque_text());
        assert_eq!(doc.content_span(script), Some(Span::new(47, 58)));
    }

    #[test]
    fn rcdata_body_is_decoded_text_markup_body_is_children() {
        let doc = parse("<title>a &amp; b</title><textarea><b>x</b></textarea><span>a &amp; b</span>");
        let title = first(&doc, doc.ast.root);
        let textarea = next(&doc, title);
        let span = next(&doc, textarea);
        assert_eq!(doc.ast.kind(title).container().unwrap().text.as_deref(), Some(&b"a & b"[..]));
        assert_eq!(doc.ast.kind(textarea).container().unwrap().text.as_deref(), Some(&b"<b>x</b>"[..]));
        assert!(doc.ast.node(textarea).first_child.is_none());
        assert!(doc.ast.kind(span).container().unwrap().text.is_none());
        assert!(doc.ast.node(span).first_child.is_some());
        assert!(!doc.ast.kind(span).holds_opaque_text());
        assert_eq!(doc.container_origin(title), Some(ContainerOrigin::Element));
    }

    #[test]
    fn restores_twig_printer_semantics_and_ignores_layout_whitespace() {
        let src = "<h1>Title</h1>\n<p>hello <a href=\"/u\"><em>world</em></a></p>\n<ul>\n<li>\n<p>one</p>\n</li>\n<li>\n<p>two</p>\n</li>\n</ul>\n<pre><code class=\"language-zig\">const x = 1;\n</code></pre>";
        let doc = parse(src);
        let heading = first(&doc, doc.ast.root);
        let para = next(&doc, heading);
        let list = next(&doc, para);
        let code = next(&doc, list);
        assert_eq!(doc.ast.kind(heading), &Kind::Heading { level: 1 });
        assert_eq!(doc.ast.kind(para), &Kind::Para);
        let link = next(&doc, first(&doc, para));
        assert_eq!(doc.ast.kind(link), &Kind::Link(Link { destination: Some(b"/u".to_vec()), reference: None }));
        assert_eq!(doc.ast.kind(list), &Kind::BulletList { tight: false });
        let item = first(&doc, list);
        assert_eq!(doc.ast.kind(item), &Kind::ListItem);
        assert_eq!(doc.ast.kind(first(&doc, item)), &Kind::Para);
        assert_eq!(
            doc.ast.kind(code),
            &Kind::CodeBlock { lang: Some(b"zig".to_vec()), text: b"const x = 1;\n".to_vec() }
        );
    }

    #[test]
    fn round_trip_does_not_duplicate_promoted_attributes() {
        let cases: [(&str, &str); 3] = [
            ("<a href=\"/x\" class=\"c\">hi</a>", "<a href=\"/x\" class=\"c\">hi</a>"),
            ("<img src=\"/p.png\" alt=\"pic\" class=\"t\">", "<img alt=\"pic\" src=\"/p.png\" class=\"t\">"),
            ("<ol start=\"3\"><li>x</ol>", "<ol start=\"3\">\n<li>\nx\n</li>\n</ol>\n"),
        ];
        for (i, o) in cases {
            assert_eq!(String::from_utf8(parse_to_html(i.as_bytes())).unwrap(), o);
        }
    }

    #[test]
    fn an_attribute_the_model_owns_is_not_kept_in_its_bag() {
        let cases: [(&str, &[&str]); 5] = [
            ("<a href=\"/x\" class=\"c\">hi</a>", &["class"]),
            ("<img src=\"/p.png\" alt=\"pic\" class=\"t\">", &["class"]),
            ("<ol start=\"3\" class=\"l\"><li>x</ol>", &["class"]),
            ("<ol start=\"iii\"><li>x</ol>", &["start"]),
            ("<a name=\"top\">hi</a>", &["name"]),
        ];
        for (src, kept) in cases {
            let doc = parse(src);
            let mut found = false;
            for i in 0..doc.ast.nodes.len() {
                let attrs = doc.ast.attrs_of(i as NodeId);
                if attrs.is_empty() {
                    continue;
                }
                found = true;
                let keys: Vec<&[u8]> = attrs.entries.iter().map(|kv| kv.key.as_slice()).collect();
                let want: Vec<&[u8]> = kept.iter().map(|k| k.as_bytes()).collect();
                assert_eq!(keys, want);
            }
            assert!(found);
        }
    }

    #[test]
    fn cell_spans_survive_parse_serialize() {
        let html = parse_to_html(b"<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td rowspan=\"0\">b</td></tr></table>");
        assert_eq!(
            String::from_utf8(html).unwrap(),
            "<table>\n<tr>\n<td colspan=\"2\" rowspan=\"3\">a</td>\n<td rowspan=\"0\">b</td>\n</tr>\n</table>\n"
        );
    }

    #[test]
    fn raw_text_elements_are_serialized_literally() {
        let src = b"<script>if (a < b && c) x();</script><style>.a>.b{x:1}</style>";
        assert_eq!(parse_to_html(src), src.to_vec());
    }

    #[test]
    fn parse_serialize_is_a_fixpoint() {
        for src in [
            "<ul><li>one<li>two</ul>",
            "<blockquote><p>q</p></blockquote>",
            "<p>a<b>bold</b></p>trailing",
            "<ul><li>a<ul><li>b</li></ul></li></ul>",
            "<div>hello <em>there</em> world</div>",
        ] {
            let pass1 = parse_to_html(src.as_bytes());
            let pass2 = parse_to_html(&pass1);
            assert_eq!(pass1, pass2);
        }
    }

    #[test]
    fn block_level_child_of_a_list_item_is_not_wrapped() {
        let doc = parse("<ul><li>text<blockquote>quoted</blockquote></li></ul>");
        let list = first(&doc, doc.ast.root);
        let item = first(&doc, list);
        let para = first(&doc, item);
        assert_eq!(doc.ast.kind(para), &Kind::Para);
        let pc = first(&doc, para);
        assert!(matches!(doc.ast.kind(pc), Kind::Str(_)));
        assert!(doc.ast.node(pc).next_sibling.is_none());
        assert_eq!(doc.ast.kind(next(&doc, para)), &Kind::BlockQuote);
    }

    // TODO(port): "HTML tight-list item text stays on the marker's line through
    // djot/markdown" and "HTML soft-wrapped list-item paragraph keeps
    // continuation indent" need the djot/Markdown serializers' `serialize_ast`.

    #[test]
    fn framed_leaves_carry_an_interior_content_span() {
        let src = "<!doctype html><!-- hi --><!bogus><?pi go?>";
        let s = src.as_bytes();
        let doc = parse(src);
        let doctype = first(&doc, doc.ast.root);
        let comment = next(&doc, doctype);
        let bogus = next(&doc, comment);
        let pi = next(&doc, bogus);
        assert!(matches!(doc.ast.kind(doctype), Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, .. }));
        assert_eq!(doc.span(doctype).of(s), b"<!doctype html>");
        assert_eq!(doc.content_span(doctype).unwrap().of(s), b" html");
        assert!(matches!(doc.ast.kind(comment), Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, .. }));
        assert_eq!(doc.span(comment).of(s), b"<!-- hi -->");
        assert_eq!(doc.content_span(comment).unwrap().of(s), b" hi ");
        assert!(matches!(doc.ast.kind(bogus), Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, .. }));
        assert_eq!(doc.span(bogus).of(s), b"<!bogus>");
        assert_eq!(doc.content_span(bogus).unwrap().of(s), b"bogus");
        assert!(matches!(doc.ast.kind(pi), Kind::ProcessingInstruction { .. }));
        assert_eq!(doc.content_span(pi), None);
    }

    #[test]
    fn empty_comment_interior_gets_an_empty_content_span() {
        let doc = parse("<!---->");
        let comment = first(&doc, doc.ast.root);
        assert!(matches!(doc.ast.kind(comment), Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, .. }));
        let cs = doc.content_span(comment).unwrap();
        assert_eq!(cs.len(), 0);
        assert_eq!(cs.start, doc.span(comment).start + 4);
    }

    #[test]
    fn zig_parse_uint_matches_std_fmt() {
        assert_eq!(zig_parse_uint(b"+10", 10, u32::MAX as u64), Some(10));
        assert_eq!(zig_parse_uint(b"-0", 10, u32::MAX as u64), Some(0));
        assert_eq!(zig_parse_uint(b"-1", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"1_000", 10, u32::MAX as u64), Some(1000));
        assert_eq!(zig_parse_uint(b"_1", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"4294967296", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"1F642", 16, 0x1F_FFFF), Some(0x1F642));
        assert_eq!(zig_parse_uint(b"", 10, 10), None);
        assert_eq!(zig_parse_uint(b"+", 10, 10), None);
    }
}
