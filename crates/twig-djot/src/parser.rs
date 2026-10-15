//! Event stream -> AST: a generic container-stack tree builder keyed by a
//! `match` on `Annotation` (mirrors djot.js's `parse.ts` flat `annot ->
//! handler` dispatch table). This is also where section-nesting-by-heading-
//! level, tight/loose list finalization, and attribute-attachment-to-the-
//! preceding-node all happen.
//!
//! This manages its own flat, mutable node array directly rather than going
//! through `ast::Builder`: djot.js's tree builder needs to *mutate an
//! already-emitted node* in a few places (a table caption patches the table
//! sibling emitted before it; a heading's attributes may migrate onto the
//! section wrapping it).
//!
//! References and footnotes are never resolved here — `Link`/`Image` nodes
//! carry a label string, and `Document.labels` holds the label -> node maps
//! consulted at render time.

use std::collections::{HashMap, HashSet};

use super::event::{Annotation, Delim, Event, ListMarkerStyle, ListStyleCandidates, Numbering};
use crate::ast::{
    compact, verse, Alignment, Ast, Attrs, Cell, Container, Form, InlineMark, KeyVal, Kind, Link, ListNumbering,
    Node, NodeId, SmartPunctuationKind, TextLeafKind,
};
use crate::document::{Bullet, ContainerOrigin, Document, Labels, OrderedDelim, Spelling};
use crate::span::Span;

// ── small text helpers ──

fn is_ws(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

fn trim_ws(s: &[u8]) -> &[u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && is_ws(s[a]) {
        a += 1;
    }
    while b > a && is_ws(s[b - 1]) {
        b -= 1;
    }
    &s[a..b]
}

pub(crate) fn normalize_label(s: &[u8]) -> Vec<u8> {
    let trimmed = trim_ws(s);
    let mut out = Vec::with_capacity(trimmed.len());
    let mut in_ws = false;
    for &c in trimmed {
        if is_ws(c) {
            if !in_ws {
                out.push(b' ');
            }
            in_ws = true;
        } else {
            out.push(c);
            in_ws = false;
        }
    }
    out
}

/// Trim one space adjacent to a backtick at the start/end of verbatim text.
fn trim_verbatim(s: &[u8]) -> Vec<u8> {
    let mut start = 0;
    let mut end = s.len();
    if s.len() >= 2 && s[0] == b' ' && s[1] == b'`' {
        start = 1;
    }
    if end >= 2 && s[end - 1] == b' ' && s[end - 2] == b'`' {
        end -= 1;
    }
    if start > end {
        // Zig would slice `s[1..0]` here (a panic); only reachable for " `"
        // whose two trims overlap. Keep the empty result.
        return Vec::new();
    }
    s[start..end].to_vec()
}

fn roman_digit(c: u8) -> Option<i64> {
    Some(match c {
        b'i' | b'I' => 1,
        b'v' | b'V' => 5,
        b'x' | b'X' => 10,
        b'l' | b'L' => 50,
        b'c' | b'C' => 100,
        b'd' | b'D' => 500,
        b'm' | b'M' => 1000,
        _ => return None,
    })
}

fn roman_to_number(s: &[u8]) -> Option<u32> {
    let mut total: i64 = 0;
    let mut prev: i64 = 0;
    for &c in s.iter().rev() {
        let n = roman_digit(c)?;
        if n < prev {
            total -= n
        } else {
            total += n
        }
        prev = n;
    }
    Some(if total < 0 { 0 } else { total as u32 })
}

fn to_ast_numbering(n: Numbering) -> ListNumbering {
    match n {
        Numbering::Decimal => ListNumbering::Decimal,
        Numbering::LowerAlpha => ListNumbering::LowerAlpha,
        Numbering::UpperAlpha => ListNumbering::UpperAlpha,
        Numbering::LowerRoman => ListNumbering::LowerRoman,
        Numbering::UpperRoman => ListNumbering::UpperRoman,
    }
}

fn to_ast_delim(d: Delim) -> OrderedDelim {
    match d {
        Delim::Period => OrderedDelim::Period,
        Delim::ParenAfter => OrderedDelim::ParenAfter,
        Delim::ParenBoth => OrderedDelim::ParenBoth,
    }
}

fn get_list_start(marker: &[u8], numbering: Numbering) -> Option<u32> {
    let mut s = marker;
    if !s.is_empty() && s[0] == b'(' {
        s = &s[1..];
    }
    if !s.is_empty() && (s[s.len() - 1] == b'.' || s[s.len() - 1] == b')') {
        s = &s[..s.len() - 1];
    }
    if s.is_empty() {
        return None;
    }
    match numbering {
        Numbering::Decimal => parse_u32(s),
        Numbering::UpperAlpha => Some((s[0] as u32).wrapping_sub(b'A' as u32).wrapping_add(1)),
        Numbering::LowerAlpha => Some((s[0] as u32).wrapping_sub(b'a' as u32).wrapping_add(1)),
        Numbering::UpperRoman | Numbering::LowerRoman => roman_to_number(s),
    }
}

/// Zig's `std.fmt.parseInt(u32, s, 10)` over a run of digits.
fn parse_u32(s: &[u8]) -> Option<u32> {
    let mut v: u32 = 0;
    if s.is_empty() {
        return None;
    }
    for &c in s {
        if !c.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((c - b'0') as u32)?;
    }
    Some(v)
}

// ── attribute accumulation ──

/// Where these entries were WRITTEN, when that is one place.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum Origin {
    /// Nothing source-backed yet.
    #[default]
    None,
    /// Exactly one `{...}` block, at this range.
    One(Span),
    /// Two or more blocks.
    Many,
}

/// Mutable, order-preserving attribute accumulator. `class`/`id`/arbitrary
/// keys all live in ONE ordered list.
#[derive(Clone, Debug, Default)]
struct PendingAttrs {
    entries: Vec<(Vec<u8>, Vec<u8>)>,
    pending_key: Option<Vec<u8>>,
    origin: Origin,
}

impl PendingAttrs {
    /// Once two blocks have contributed, the answer is `Many` forever.
    fn add_origin(&mut self, incoming: Origin) {
        if incoming == Origin::None {
            return;
        }
        self.origin = if self.origin == Origin::None { incoming } else { Origin::Many };
    }

    fn origin_span(&self) -> Option<Span> {
        match self.origin {
            Origin::One(sp) => Some(sp),
            _ => None,
        }
    }

    fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn index_of(&self, key: &[u8]) -> Option<usize> {
        self.entries.iter().position(|(k, _)| k == key)
    }

    fn get(&self, key: &[u8]) -> Option<&[u8]> {
        self.index_of(key).map(|i| &self.entries[i].1[..])
    }

    /// Set (or overwrite) `key`'s value, preserving its first position.
    fn set_keyval(&mut self, key: &[u8], value: &[u8]) {
        if let Some(i) = self.index_of(key) {
            self.entries[i].1 = value.to_vec();
            return;
        }
        self.entries.push((key.to_vec(), value.to_vec()));
    }

    fn remove(&mut self, key: &[u8]) {
        if let Some(i) = self.index_of(key) {
            self.entries.remove(i);
        }
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.origin = Origin::None;
    }

    /// Add one `.class` token: if `class` is already present its value grows
    /// in place (space-joined); else a new `class` entry is appended.
    fn add_class(&mut self, token: &[u8]) {
        if let Some(i) = self.index_of(b"class") {
            let v = &mut self.entries[i].1;
            v.push(b' ');
            v.extend_from_slice(token);
        } else {
            self.entries.push((b"class".to_vec(), token.to_vec()));
        }
    }

    /// djot.js's attribute-merge rule: `class` values accumulate; everything
    /// else overwrites, keeping its first-seen position.
    fn merge_from(&mut self, src: &PendingAttrs) {
        for (k, v) in &src.entries {
            if k == b"class" {
                self.add_class(v);
            } else {
                self.set_keyval(k, v);
            }
        }
        self.add_origin(src.origin);
    }
}

// ── container scratch state ──

#[derive(Debug)]
struct ContainerData {
    level: u32,
    heading_level: Option<u32>,
    styles: ListStyleCandidates,
    tight: bool,
    blanklines: bool,
    first_marker: Option<Vec<u8>>,
    checkbox: Option<bool>,
    is_definition_item: bool,
    ref_key: Option<Vec<u8>>,
    ref_value: Vec<u8>,
    label: Option<Vec<u8>>,
    lang: Option<Vec<u8>>,
    format: Option<Vec<u8>>,
    is_image: bool,
    aligns: Vec<Alignment>,
}

impl Default for ContainerData {
    fn default() -> Self {
        ContainerData {
            level: 0,
            heading_level: None,
            styles: ListStyleCandidates::default(),
            tight: true,
            blanklines: false,
            first_marker: None,
            checkbox: None,
            is_definition_item: false,
            ref_key: None,
            ref_value: Vec::new(),
            label: None,
            lang: None,
            format: None,
            is_image: false,
            aligns: Vec::new(),
        }
    }
}

#[derive(Debug, Default)]
struct TreeContainer {
    first_child: Option<NodeId>,
    last_child: Option<NodeId>,
    attrs: PendingAttrs,
    data: ContainerData,
    start: usize,
    /// For a framed *leaf* built from an open/close pair: the byte offset just
    /// past the opening delimiter.
    content_start: Option<usize>,
    /// For a `code_block`/`raw_block`: the body's byte range.
    body_start: Option<usize>,
    body_end: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Context {
    Normal,
    Verbatim,
    Literal,
}

pub struct TreeBuilder<'a> {
    source: &'a [u8],
    nodes: Vec<Node>,
    spans: Vec<Span>,
    content_spans: Vec<Option<Span>>,
    spellings: Vec<Option<Spelling>>,
    marker_spans: Vec<Option<Span>>,
    attrs_table: Vec<Attrs>,
    attrs_span_table: Vec<Option<Span>>,
    containers: Vec<TreeContainer>,
    context: Context,
    accumulated_text: Vec<u8>,
    references: HashMap<Vec<u8>, NodeId>,
    auto_references: HashMap<Vec<u8>, NodeId>,
    footnotes: HashMap<Vec<u8>, NodeId>,
    identifiers: HashSet<Vec<u8>>,
    pending_block_attrs: PendingAttrs,
    list_depth: usize,
}

/// Record node `id`'s marker; a zero-width or reversed range is dropped.
fn leaf_interior_span(content_start: Option<usize>, close: usize) -> Option<Span> {
    let cs = content_start?;
    if cs >= close {
        return None;
    }
    Some(Span::new(cs, close))
}

/// Where an attribute block was written; `None` when the close carries no
/// `}` (the block never closed).
fn attrs_block_origin(start: usize, ev: &Event) -> Origin {
    if (ev.end as usize) <= start {
        return Origin::None;
    }
    Origin::One(Span::new(start, ev.end as usize + 1))
}

/// The last whitespace-delimited word of `s`, as a start offset.
fn last_word(s: &[u8]) -> Option<usize> {
    let mut i = s.len();
    while i > 0 && !is_ws(s[i - 1]) {
        i -= 1;
    }
    if i == s.len() { None } else { Some(i) }
}

fn strip_raw_format_delims(s: &[u8]) -> &[u8] {
    let mut r = s;
    if !r.is_empty() && r[0] == b'{' {
        r = &r[1..];
    }
    if !r.is_empty() && r[0] == b'=' {
        r = &r[1..];
    }
    if !r.is_empty() && r[r.len() - 1] == b'}' {
        r = &r[..r.len() - 1];
    }
    r
}

impl<'a> TreeBuilder<'a> {
    pub fn new(source: &'a [u8]) -> Self {
        TreeBuilder {
            source,
            nodes: Vec::new(),
            spans: Vec::new(),
            content_spans: Vec::new(),
            spellings: Vec::new(),
            marker_spans: Vec::new(),
            attrs_table: Vec::new(),
            attrs_span_table: Vec::new(),
            containers: Vec::new(),
            context: Context::Normal,
            accumulated_text: Vec::new(),
            references: HashMap::new(),
            auto_references: HashMap::new(),
            footnotes: HashMap::new(),
            identifiers: HashSet::new(),
            pending_block_attrs: PendingAttrs::default(),
            list_depth: 0,
        }
    }

    fn add_node(&mut self, kind: Kind, span: Span) -> NodeId {
        let id = self.nodes.len() as NodeId;
        self.nodes.push(Node { id, kind, first_child: None, next_sibling: None, attrs: None });
        self.spans.push(span);
        self.content_spans.push(None);
        self.spellings.push(None);
        self.marker_spans.push(None);
        id
    }

    fn set_content_span(&mut self, id: NodeId, span: Option<Span>) {
        self.content_spans[id as usize] = span;
    }

    fn set_first_child(&mut self, id: NodeId, first: Option<NodeId>) {
        self.nodes[id as usize].first_child = first;
    }

    fn commit_attrs(&mut self, id: NodeId, pending: &PendingAttrs) {
        if pending.is_empty() {
            return;
        }
        let entries = pending.entries.iter().map(|(k, v)| KeyVal { key: k.clone(), value: Some(v.clone()) }).collect();
        let idx = self.attrs_table.len() as u32;
        self.attrs_table.push(Attrs { entries });
        self.attrs_span_table.push(pending.origin_span());
        self.nodes[id as usize].attrs = Some(idx);
    }

    // ── container stack ──

    fn push_container(&mut self, start: usize) {
        let mut c = TreeContainer { start, ..Default::default() };
        if !self.pending_block_attrs.is_empty() {
            c.attrs.merge_from(&self.pending_block_attrs);
            self.pending_block_attrs.clear();
        }
        self.containers.push(c);
    }

    fn pop_container(&mut self) -> TreeContainer {
        self.containers.pop().unwrap()
    }

    fn top(&mut self) -> &mut TreeContainer {
        self.containers.last_mut().unwrap()
    }

    /// The last child added to the top container (djot.js's `getTip`).
    fn get_tip(&self) -> Option<NodeId> {
        self.containers.last().unwrap().last_child
    }

    fn add_child_to_tip(&mut self, id: NodeId) {
        let Some(top) = self.containers.last_mut() else { return };
        match top.last_child {
            Some(lc) => self.nodes[lc as usize].next_sibling = Some(id),
            None => top.first_child = Some(id),
        }
        top.last_child = Some(id);
    }

    /// The extent from the first child's span start to the last child's end.
    fn content_span_from_children(&self, first_child: Option<NodeId>) -> Option<Span> {
        let first = first_child?;
        let mut last = first;
        while let Some(next) = self.nodes[last as usize].next_sibling {
            last = next;
        }
        Some(Span::new(self.spans[first as usize].start, self.spans[last as usize].end))
    }

    /// The `content_span` of a MARKER-PREFIXED container — a block quote, a
    /// list item, a footnote — which is its own whole extent: no contiguous
    /// range is its interior, since the prefix repeats on every line.
    fn marker_prefixed_content_span(span: Span) -> Option<Span> {
        Some(span)
    }

    fn set_marker_span(&mut self, id: NodeId, start: usize, end: usize) {
        if end > start {
            self.marker_spans[id as usize] = Some(Span::new(start, end));
        }
    }

    fn past_spaces(&self, i: usize) -> usize {
        let mut j = i;
        while j < self.source.len() && (self.source[j] == b' ' || self.source[j] == b'\t') {
            j += 1;
        }
        j
    }

    fn atx_marker_end(&self, start: usize) -> usize {
        let mut j = start;
        while j < self.source.len() && self.source[j] == b'#' {
            j += 1;
        }
        if j == start {
            return start;
        }
        self.past_spaces(j)
    }

    fn quote_marker_end(&self, start: usize) -> usize {
        if start >= self.source.len() || self.source[start] != b'>' {
            return start;
        }
        self.past_spaces(start + 1)
    }

    /// The end of a list item's marker at `start` — bullet or ordered number,
    /// its spaces, and a task item's `[x]` box and ITS spaces.
    fn list_marker_end(&self, start: usize, is_task: bool) -> usize {
        let src = self.source;
        let mut j = start;
        if j >= src.len() {
            return start;
        }
        if src[j] == b'-' || src[j] == b'+' || src[j] == b'*' {
            j += 1;
        } else {
            if src[j] == b'(' {
                j += 1;
            }
            let digits_from = j;
            while j < src.len() && src[j].is_ascii_digit() {
                j += 1;
            }
            if j == digits_from {
                return start;
            }
            if j >= src.len() || (src[j] != b'.' && src[j] != b')') {
                return start;
            }
            j += 1;
        }
        j = self.past_spaces(j);
        if !is_task {
            return j;
        }
        if j + 2 >= src.len() || src[j] != b'[' || src[j + 2] != b']' {
            return j;
        }
        self.past_spaces(j + 3)
    }

    fn text_of(&self, ev: &Event) -> &'a [u8] {
        &self.source[ev.start as usize..ev.end as usize + 1]
    }

    // ── the big dispatch ──

    pub fn build(mut self, events: &[Event]) -> Document {
        self.push_container(0);
        self.top().data.heading_level = Some(0);

        for ev in events {
            self.handle_event(ev);
        }

        // Close any still-open sections.
        while self.containers.last().unwrap().data.heading_level.is_some_and(|l| l > 0) {
            let c = self.pop_container();
            let sec_id = self.add_node(Kind::Section, Span::new(c.start, self.source.len()));
            self.set_first_child(sec_id, c.first_child);
            let cs = self.content_span_from_children(c.first_child);
            self.set_content_span(sec_id, cs);
            self.commit_attrs(sec_id, &c.attrs);
            self.add_child_to_tip(sec_id);
        }

        let root = self.pop_container();
        let doc_id = self.add_node(Kind::Doc, Span::new(0, self.source.len()));
        self.set_first_child(doc_id, root.first_child);
        let cs = self.content_span_from_children(root.first_child);
        self.set_content_span(doc_id, cs);
        self.commit_attrs(doc_id, &root.attrs);

        let raw = Document {
            source: self.source.to_vec(),
            ast: Ast { root: doc_id, nodes: self.nodes, attrs: self.attrs_table },
            node_spans: self.spans,
            node_content_spans: self.content_spans,
            node_spelling: self.spellings,
            node_marker_spans: self.marker_spans,
            attrs_spans: self.attrs_span_table,
            labels: Labels {
                references: self.references,
                auto_references: self.auto_references,
                footnotes: self.footnotes,
            },
        };

        // A `::: verse` div of paragraphs is a `line_block`. Before
        // compaction, which sweeps what it leaves.
        let versed = verse::run(raw);
        compact::run(versed)
    }

    fn find_list_node(&mut self) -> Option<&mut TreeContainer> {
        let n = self.containers.len();
        if n == 0 {
            return None;
        }
        if !self.containers[n - 1].data.styles.is_empty() {
            return Some(&mut self.containers[n - 1]);
        }
        if n >= 2 && !self.containers[n - 2].data.styles.is_empty() {
            return Some(&mut self.containers[n - 2]);
        }
        None
    }

    fn handle_event(&mut self, ev: &Event) {
        use Annotation as A;
        // Attributes must immediately precede a block; reset on blank lines.
        if ev.annot == A::Blankline {
            self.pending_block_attrs.clear();
        }

        // Tight/loose determination.
        if self.list_depth > 0 && ev.annot != A::Blankline {
            let annot = ev.annot;
            if let Some(ln) = self.find_list_node() {
                let is_list_boundary =
                    matches!(annot, A::ListOpen | A::ListClose | A::ListItemOpen | A::ListItemClose);
                if !is_list_boundary && ln.data.blanklines {
                    ln.data.tight = false;
                }
                let is_list_item_boundary = matches!(annot, A::ListItemOpen | A::ListItemClose);
                if !is_list_item_boundary {
                    ln.data.blanklines = false;
                }
            }
        }

        let span = Span::new(ev.start as usize, ev.end as usize + 1);
        match ev.annot {
            A::Str => {
                let txt = self.text_of(ev);
                if self.context == Context::Normal {
                    let id = self.add_node(Kind::Str(txt.to_vec()), span);
                    self.add_child_to_tip(id);
                } else {
                    let top = self.top();
                    if top.body_start.is_none() {
                        top.body_start = Some(ev.start as usize);
                    }
                    top.body_end = ev.end as usize + 1;
                    self.accumulated_text.extend_from_slice(txt);
                }
            }
            A::SoftBreak => {
                if self.context == Context::Normal {
                    let id = self.add_node(Kind::SoftBreak, span);
                    self.add_child_to_tip(id);
                } else {
                    self.accumulated_text.push(b'\n');
                }
            }
            A::Escape => {
                if self.context == Context::Verbatim {
                    self.accumulated_text.push(b'\\');
                }
            }
            A::HardBreak => {
                if self.context == Context::Normal {
                    let id = self.add_node(Kind::HardBreak, span);
                    self.add_child_to_tip(id);
                } else {
                    self.accumulated_text.push(b'\n');
                }
            }
            A::NonBreakingSpace => {
                if self.context == Context::Verbatim {
                    self.accumulated_text.extend_from_slice(b"\\ ");
                } else {
                    let id = self.add_node(Kind::NonBreakingSpace, span);
                    self.add_child_to_tip(id);
                }
            }
            A::Symb => {
                if self.context == Context::Normal {
                    let alias = self.source[ev.start as usize + 1..ev.end as usize].to_vec();
                    let id = self.add_node(Kind::TextLeaf { kind: TextLeafKind::Symb, text: alias }, span);
                    self.set_content_span(id, leaf_interior_span(Some(ev.start as usize + 1), ev.end as usize));
                    self.add_child_to_tip(id);
                } else {
                    let t = self.text_of(ev);
                    self.accumulated_text.extend_from_slice(t);
                }
            }
            A::FootnoteReference => {
                let raw = &self.source[ev.start as usize + 2..ev.end as usize];
                let lab = normalize_label(raw);
                let id = self.add_node(Kind::TextLeaf { kind: TextLeafKind::FootnoteReference, text: lab }, span);
                self.set_content_span(id, leaf_interior_span(Some(ev.start as usize + 2), ev.end as usize));
                self.add_child_to_tip(id);
            }

            A::ReferenceDefinitionOpen => self.push_container(ev.start as usize),
            A::ReferenceDefinitionClose => {
                let c = self.pop_container();
                let key = c.data.ref_key.clone().unwrap_or_default();
                if !key.is_empty() {
                    let lab = normalize_label(&key);
                    let dest = c.data.ref_value.clone();
                    let id = self.add_node(
                        Kind::Reference { label: lab.clone(), destination: dest },
                        Span::new(c.start, ev.end as usize + 1),
                    );
                    self.commit_attrs(id, &c.attrs);
                    self.references.entry(lab).or_insert(id);
                }
            }
            A::ReferenceKey => {
                let k = self.source[ev.start as usize + 1..ev.end as usize].to_vec();
                self.top().data.ref_key = Some(k);
            }
            A::ReferenceValue => {
                let t = self.text_of(ev);
                self.top().data.ref_value.extend_from_slice(t);
            }

            A::EmphOpen
            | A::StrongOpen
            | A::SpanOpen
            | A::MarkOpen
            | A::SuperscriptOpen
            | A::SubscriptOpen
            | A::DeleteOpen
            | A::InsertOpen
            | A::DoubleQuotedOpen
            | A::SingleQuotedOpen => self.push_container(ev.start as usize),

            A::EmphClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Emph));
            }
            A::StrongClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Strong));
            }
            // Djot's own generic containers: origin is `directive`.
            A::SpanClose => {
                let id = self.close_simple_inline(ev, Kind::Container(Container::with_form(b"", Form::InlineText)));
                self.spellings[id as usize] = Some(Spelling::ContainerOrigin(ContainerOrigin::Directive));
            }
            A::MarkClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Mark));
            }
            A::SuperscriptClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Superscript));
            }
            A::SubscriptClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Subscript));
            }
            A::DeleteClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Delete));
            }
            A::InsertClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::Insert));
            }
            A::DoubleQuotedClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::DoubleQuoted));
            }
            A::SingleQuotedClose => {
                self.close_simple_inline(ev, Kind::InlineMark(InlineMark::SingleQuoted));
            }

            A::AttributesOpen => self.push_container(ev.start as usize),
            A::AttributesClose => self.close_inline_attributes(ev),
            A::BlockAttributesOpen => self.push_container(ev.start as usize),
            A::BlockAttributesClose => self.close_block_attributes(ev),

            A::Class => {
                let cl = self.text_of(ev);
                self.top().attrs.add_class(cl);
            }
            A::Id => {
                let idtext = self.text_of(ev);
                self.top().attrs.set_keyval(b"id", idtext);
            }
            A::Key => {
                let k = self.text_of(ev);
                let top = self.top();
                top.attrs.pending_key = Some(k.to_vec());
                top.attrs.set_keyval(k, b"");
            }
            A::Value => {
                let collapsed = collapse_and_unescape(self.text_of(ev));
                let top = self.top();
                let Some(key) = top.attrs.pending_key.clone() else { return };
                let Some(existing) = top.attrs.get(&key) else { return };
                let mut combined = existing.to_vec();
                combined.extend_from_slice(&collapsed);
                top.attrs.set_keyval(&key, &combined);
            }

            A::LinktextOpen => {
                self.push_container(ev.start as usize);
                self.top().data.is_image = false;
            }
            A::LinktextClose => {}
            A::ImagetextOpen => {
                self.push_container(ev.start as usize);
                self.top().data.is_image = true;
            }
            A::ImagetextClose => {}
            A::DestinationOpen => self.context = Context::Literal,
            A::DestinationClose => {
                let c = self.pop_container();
                let dest = strip_newlines(&self.accumulated_text);
                let link = Link { destination: Some(dest), reference: None };
                let kind = if c.data.is_image { Kind::Image(link) } else { Kind::Link(link) };
                // An image's `!` sits one byte before its `[`; include it.
                let span_start = if c.data.is_image { c.start - 1 } else { c.start };
                self.finish_link(c, kind, span_start, ev);
            }
            A::ReferenceOpen => self.context = Context::Literal,
            A::ReferenceClose => {
                let c = self.pop_container();
                let r = if self.accumulated_text.is_empty() {
                    self.get_string_content(c.first_child)
                } else {
                    self.accumulated_text.clone()
                };
                let lab = normalize_label(&r);
                let link = Link { destination: None, reference: Some(lab) };
                let kind = if c.data.is_image { Kind::Image(link) } else { Kind::Link(link) };
                let span_start = if c.data.is_image { c.start - 1 } else { c.start };
                self.finish_link(c, kind, span_start, ev);
            }

            A::VerbatimOpen | A::DisplayMathOpen | A::InlineMathOpen => {
                self.context = Context::Verbatim;
                self.push_container(ev.start as usize);
                self.top().content_start = Some(ev.end as usize + 1);
            }
            A::VerbatimClose => self.close_text_leaf(ev, TextLeafKind::Verbatim, true),
            A::RawFormat => self.handle_raw_format(ev),
            A::DisplayMathClose => self.close_text_leaf(ev, TextLeafKind::DisplayMath, true),
            A::InlineMathClose => self.close_text_leaf(ev, TextLeafKind::InlineMath, true),

            A::UrlOpen | A::EmailOpen => {
                self.context = Context::Literal;
                self.push_container(ev.start as usize);
                self.top().content_start = Some(ev.end as usize + 1);
            }
            A::UrlClose => self.close_text_leaf(ev, TextLeafKind::Url, false),
            A::EmailClose => self.close_text_leaf(ev, TextLeafKind::Email, false),

            A::ParaOpen => self.push_container(ev.start as usize),
            A::ParaClose => {
                let c = self.pop_container();
                self.close_generic(c, Kind::Para, ev);
            }

            A::HeadingOpen => {
                self.push_container(ev.start as usize);
                self.top().data.level = ev.end - ev.start + 1;
            }
            A::HeadingClose => self.close_heading(ev),

            A::ListOpen => {
                self.push_container(ev.start as usize);
                let top = self.top();
                top.data.styles = ev.list_styles;
                top.data.blanklines = false;
                top.data.tight = true;
                self.list_depth += 1;
            }
            A::ListClose => self.close_list(ev),

            A::ListItemOpen => {
                let text = self.text_of(ev);
                let top = self.top();
                let narrowed = ev.list_styles;
                if narrowed.len < top.data.styles.len {
                    top.data.styles = narrowed;
                }
                if top.data.first_marker.is_none() {
                    top.data.first_marker = Some(text.to_vec());
                }
                self.push_container(ev.start as usize);
                if narrowed.len == 1 && narrowed.items[0] == ListMarkerStyle::Colon {
                    self.top().data.is_definition_item = true;
                }
            }
            A::ListItemClose => self.close_list_item(ev),

            A::CheckboxChecked => self.top().data.checkbox = Some(true),
            A::CheckboxUnchecked => self.top().data.checkbox = Some(false),

            A::BlockQuoteOpen => self.push_container(ev.start as usize),
            A::BlockQuoteClose => {
                let c = self.pop_container();
                let s = Span::new(c.start, ev.end as usize + 1);
                let id = self.add_node(Kind::BlockQuote, s);
                self.set_first_child(id, c.first_child);
                self.set_content_span(id, Self::marker_prefixed_content_span(s));
                let me = self.quote_marker_end(s.start);
                self.set_marker_span(id, s.start, me);
                self.commit_attrs(id, &c.attrs);
                self.add_child_to_tip(id);
            }

            A::TableOpen => self.push_container(ev.start as usize),
            A::TableClose => self.close_table(ev),
            A::RowOpen => self.push_container(ev.start as usize),
            A::RowClose => self.close_row(ev),
            A::SeparatorDefault => self.top().data.aligns.push(Alignment::Default),
            A::SeparatorLeft => self.top().data.aligns.push(Alignment::Left),
            A::SeparatorRight => self.top().data.aligns.push(Alignment::Right),
            A::SeparatorCenter => self.top().data.aligns.push(Alignment::Center),
            A::CellOpen => self.push_container(ev.start as usize),
            A::CellClose => {
                let c = self.pop_container();
                self.close_generic(c, Kind::Cell(Cell::new(false, Alignment::Default)), ev);
            }

            A::CaptionOpen => self.push_container(ev.start as usize),
            A::CaptionClose => self.close_caption(ev),

            A::FootnoteOpen => self.push_container(ev.start as usize),
            A::FootnoteClose => self.close_footnote(ev),
            A::NoteLabel => {
                let t = self.text_of(ev);
                self.top().data.label = Some(t.to_vec());
            }

            A::CodeBlockOpen => {
                self.push_container(ev.start as usize);
                self.context = Context::Verbatim;
            }
            A::CodeBlockClose => self.close_code_block(ev),
            A::CodeLanguage => {
                let t = self.text_of(ev);
                self.top().data.lang = Some(t.to_vec());
            }

            A::DivOpen => self.push_container(ev.start as usize),
            A::DivClose => {
                let c = self.pop_container();
                let id = self.add_node(
                    Kind::Container(Container::with_form(b"", Form::BlockFenced)),
                    Span::new(c.start, ev.end as usize + 1),
                );
                self.spellings[id as usize] = Some(Spelling::ContainerOrigin(ContainerOrigin::Directive));
                self.set_first_child(id, c.first_child);
                let cs = self.content_span_from_children(c.first_child);
                self.set_content_span(id, cs);
                self.commit_attrs(id, &c.attrs);
                self.add_child_to_tip(id);
            }

            A::ThematicBreak => {
                let id = self.add_node(Kind::ThematicBreak, span);
                let pending = std::mem::take(&mut self.pending_block_attrs);
                self.commit_attrs(id, &pending);
                self.add_child_to_tip(id);
            }

            A::LeftSingleQuote => self.add_smart_punct(span, SmartPunctuationKind::LeftSingleQuote),
            A::RightSingleQuote => self.add_smart_punct(span, SmartPunctuationKind::RightSingleQuote),
            A::LeftDoubleQuote => self.add_smart_punct(span, SmartPunctuationKind::LeftDoubleQuote),
            A::RightDoubleQuote => self.add_smart_punct(span, SmartPunctuationKind::RightDoubleQuote),
            A::Ellipses => self.add_smart_punct(span, SmartPunctuationKind::Ellipses),
            A::EnDash => self.add_smart_punct(span, SmartPunctuationKind::EnDash),
            A::EmDash => self.add_smart_punct(span, SmartPunctuationKind::EmDash),

            // Record that a blank line was seen, for the ENCLOSING list.
            A::Blankline => {
                if let Some(ln) = self.find_list_node() {
                    ln.data.blanklines = true;
                }
            }

            A::OpenMarker
            | A::Comment
            | A::AttrSpace
            | A::AttrIdMarker
            | A::AttrClassMarker
            | A::AttrEqualMarker
            | A::AttrQuoteMarker
            | A::ImageMarker => {}
        }
    }

    /// A container whose content span is its children's extent.
    fn close_generic(&mut self, c: TreeContainer, kind: Kind, ev: &Event) -> NodeId {
        let id = self.add_node(kind, Span::new(c.start, ev.end as usize + 1));
        self.set_first_child(id, c.first_child);
        let cs = self.content_span_from_children(c.first_child);
        self.set_content_span(id, cs);
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
        id
    }

    fn finish_link(&mut self, c: TreeContainer, kind: Kind, span_start: usize, ev: &Event) {
        let id = self.add_node(kind, Span::new(span_start, ev.end as usize + 1));
        self.set_first_child(id, c.first_child);
        let cs = self.content_span_from_children(c.first_child);
        self.set_content_span(id, cs);
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
        self.context = Context::Normal;
        self.accumulated_text.clear();
    }

    /// verbatim / math (`trim` = space-trimmed text) and url / email
    /// (newlines stripped).
    fn close_text_leaf(&mut self, ev: &Event, kind: TextLeafKind, trim: bool) {
        let c = self.pop_container();
        let text = if trim { trim_verbatim(&self.accumulated_text) } else { strip_newlines(&self.accumulated_text) };
        let id = self.add_node(Kind::TextLeaf { kind, text }, Span::new(c.start, ev.end as usize + 1));
        self.set_content_span(id, leaf_interior_span(c.content_start, ev.start as usize));
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
        self.context = Context::Normal;
        self.accumulated_text.clear();
    }

    /// Takes a whole `Kind` (djot's `[…]{…}` span is a `container`). Returns
    /// the new node's id.
    fn close_simple_inline(&mut self, ev: &Event, kind: Kind) -> NodeId {
        let c = self.pop_container();
        let id = self.add_node(kind, Span::new(c.start, ev.end as usize + 1));
        self.set_first_child(id, c.first_child);
        let cs = self.content_span_from_children(c.first_child);
        self.set_content_span(id, cs);
        self.add_child_to_tip(id);
        id
    }

    fn add_smart_punct(&mut self, span: Span, kind: SmartPunctuationKind) {
        let id = self.add_node(Kind::SmartPunctuation(kind), span);
        self.add_child_to_tip(id);
    }

    fn handle_raw_format(&mut self, ev: &Event) {
        let raw = self.text_of(ev);
        let format = strip_raw_format_delims(raw).to_vec();
        if self.context == Context::Verbatim {
            self.top().data.format = Some(format);
        } else {
            let Some(tip_id) = self.get_tip() else { return };
            if let Kind::TextLeaf { kind: TextLeafKind::Verbatim, text } = &self.nodes[tip_id as usize].kind {
                let text = text.clone();
                self.nodes[tip_id as usize].kind = Kind::RawInline { format, text };
            }
        }
    }

    fn close_inline_attributes(&mut self, ev: &Event) {
        let mut c = self.pop_container();
        if c.attrs.is_empty() || self.containers.is_empty() {
            return;
        }
        c.attrs.add_origin(attrs_block_origin(c.start, ev));
        if let Some(i) = c.attrs.get(b"id") {
            self.identifiers.insert(i.to_vec());
        }

        let Some(mut tip_id) = self.get_tip() else { return };

        if let Kind::Str(text) = &self.nodes[tip_id as usize].kind {
            let text = text.clone();
            // Nothing but whitespace: the attributes attach to nothing.
            let Some(word_start) = last_word(&text) else { return };
            // A word that starts the `str` is the whole `str`.
            if word_start > 0 {
                self.nodes[tip_id as usize].kind = Kind::Str(text[..word_start].to_vec());
                let sp = self.spans[tip_id as usize];
                let word_id = self.add_node(Kind::Str(text[word_start..].to_vec()), sp);
                self.add_child_to_tip(word_id);
                tip_id = word_id;
            }
        }
        self.merge_attrs_onto_node(tip_id, &c.attrs);
    }

    fn merge_attrs_onto_node(&mut self, id: NodeId, src: &PendingAttrs) {
        let mut existing = PendingAttrs::default();
        if let Some(idx) = self.nodes[id as usize].attrs {
            for kv in &self.attrs_table[idx as usize].entries {
                existing.set_keyval(&kv.key, kv.value.as_deref().unwrap_or(b""));
            }
            existing.origin = match self.attrs_span_table[idx as usize] {
                Some(sp) => Origin::One(sp),
                None => Origin::Many,
            };
        }
        existing.merge_from(src);
        self.commit_attrs(id, &existing);
    }

    fn close_block_attributes(&mut self, ev: &Event) {
        let mut c = self.pop_container();
        if c.attrs.is_empty() || self.containers.is_empty() {
            return;
        }
        if let Some(i) = c.attrs.get(b"id") {
            self.identifiers.insert(i.to_vec());
        }
        c.attrs.add_origin(attrs_block_origin(c.start, ev));
        self.pending_block_attrs.merge_from(&c.attrs);
    }

    fn close_heading(&mut self, ev: &Event) {
        let mut c = self.pop_container();
        let level = c.data.level;

        let heading_str_owned = self.get_string_content(c.first_child);
        let heading_str = trim_ws(&heading_str_owned);

        // An EXPLICIT id takes its whole attribute set along onto the section;
        // an AUTO-generated one moves alone.
        let had_explicit_id = c.attrs.get(b"id").is_some();
        let mut auto_id: Option<Vec<u8>> = None;
        if !had_explicit_id {
            let slug = self.get_unique_identifier(heading_str);
            self.identifiers.insert(slug.clone());
            c.attrs.set_keyval(b"id", &slug);
            auto_id = Some(slug);
        }
        let effective_id: Vec<u8> = if had_explicit_id {
            c.attrs.get(b"id").unwrap().to_vec()
        } else {
            auto_id.clone().unwrap()
        };

        let lab = normalize_label(heading_str);
        if !self.references.contains_key(&lab) && !self.auto_references.contains_key(&lab) {
            let mut dest = b"#".to_vec();
            dest.extend_from_slice(&effective_id);
            let ref_id = self.add_node(
                Kind::Reference { label: lab.clone(), destination: dest },
                Span::new(ev.start as usize, ev.end as usize + 1),
            );
            self.auto_references.insert(lab, ref_id);
        }

        // Section nesting: close sections at >= this heading's level, then
        // open a fresh one.
        if self.containers.last().unwrap().data.heading_level.is_some() {
            while self.containers.last().unwrap().data.heading_level.is_some_and(|l| l >= level) {
                let closed = self.pop_container();
                // A section ends where its LAST CHILD does.
                let closed_content = self.content_span_from_children(closed.first_child);
                let sec_end = match closed_content {
                    Some(cs) => cs.end,
                    None => closed.start,
                };
                let sec_id = self.add_node(Kind::Section, Span::new(closed.start, sec_end));
                self.set_first_child(sec_id, closed.first_child);
                self.set_content_span(sec_id, closed_content);
                self.commit_attrs(sec_id, &closed.attrs);
                self.add_child_to_tip(sec_id);
            }
            self.push_container(c.start);
            self.top().data.heading_level = Some(level);
            if had_explicit_id {
                self.top().attrs = std::mem::take(&mut c.attrs);
            } else {
                let aid = auto_id.clone().unwrap();
                self.top().attrs.set_keyval(b"id", &aid);
                c.attrs.remove(b"id");
            }
        }

        let id = self.add_node(Kind::Heading { level }, Span::new(c.start, ev.end as usize + 1));
        self.set_first_child(id, c.first_child);
        let cs = self.content_span_from_children(c.first_child);
        self.set_content_span(id, cs);
        let me = self.atx_marker_end(c.start);
        self.set_marker_span(id, c.start, me);
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
    }

    fn close_list(&mut self, ev: &Event) {
        let c = self.pop_container();
        self.list_depth -= 1;
        if c.data.styles.is_empty() {
            return;
        }
        let style = c.data.styles.items[0];
        let marker = c.data.first_marker.clone().unwrap_or_default();
        let s = Span::new(c.start, ev.end as usize + 1);
        let tight = c.data.tight;
        let kind = match style {
            ListMarkerStyle::Colon => Kind::DefinitionList,
            ListMarkerStyle::DashTask | ListMarkerStyle::PlusTask | ListMarkerStyle::StarTask => {
                Kind::TaskList { tight }
            }
            ListMarkerStyle::Dash | ListMarkerStyle::Plus | ListMarkerStyle::Star => Kind::BulletList { tight },
            ListMarkerStyle::Ordered { numbering, .. } => Kind::OrderedList {
                numbering: to_ast_numbering(numbering),
                tight,
                start: get_list_start(&marker, numbering),
            },
        };
        let id = self.add_node(kind, s);
        self.spellings[id as usize] = match style {
            ListMarkerStyle::Dash => Some(Spelling::Bullet(Bullet::Dash)),
            ListMarkerStyle::Plus => Some(Spelling::Bullet(Bullet::Plus)),
            ListMarkerStyle::Star => Some(Spelling::Bullet(Bullet::Star)),
            ListMarkerStyle::Ordered { delim, .. } => Some(Spelling::OrderedDelim(to_ast_delim(delim))),
            _ => None,
        };
        self.set_first_child(id, c.first_child);
        let cs = self.content_span_from_children(c.first_child);
        self.set_content_span(id, cs);
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
    }

    fn close_list_item(&mut self, ev: &Event) {
        let c = self.pop_container();
        let s = Span::new(c.start, ev.end as usize + 1);
        if c.data.is_definition_item {
            let mut term_children: Option<NodeId> = None;
            let mut def_first = c.first_child;
            if let Some(fc) = c.first_child {
                if self.nodes[fc as usize].kind == Kind::Para {
                    term_children = self.nodes[fc as usize].first_child;
                    def_first = self.nodes[fc as usize].next_sibling;
                }
            }
            let term_id = self.add_node(Kind::Term, s);
            self.set_first_child(term_id, term_children);
            let cs = self.content_span_from_children(term_children);
            self.set_content_span(term_id, cs);
            let def_id = self.add_node(Kind::Definition, s);
            self.set_first_child(def_id, def_first);
            self.set_content_span(def_id, Self::marker_prefixed_content_span(s));
            self.nodes[term_id as usize].next_sibling = Some(def_id);
            let item_id = self.add_node(Kind::DefinitionListItem, s);
            self.set_first_child(item_id, Some(term_id));
            self.set_content_span(item_id, Self::marker_prefixed_content_span(s));
            self.commit_attrs(item_id, &c.attrs);
            self.add_child_to_tip(item_id);
        } else if let Some(checked) = c.data.checkbox {
            let id = self.add_node(Kind::TaskListItem { checked }, s);
            self.set_first_child(id, c.first_child);
            self.set_content_span(id, Self::marker_prefixed_content_span(s));
            let me = self.list_marker_end(s.start, true);
            self.set_marker_span(id, s.start, me);
            self.commit_attrs(id, &c.attrs);
            self.add_child_to_tip(id);
        } else {
            let id = self.add_node(Kind::ListItem, s);
            self.set_first_child(id, c.first_child);
            self.set_content_span(id, Self::marker_prefixed_content_span(s));
            let me = self.list_marker_end(s.start, false);
            self.set_marker_span(id, s.start, me);
            self.commit_attrs(id, &c.attrs);
            self.add_child_to_tip(id);
        }
    }

    fn close_table(&mut self, ev: &Event) {
        let c = self.pop_container();
        let s = Span::new(c.start, ev.end as usize + 1);
        let caption_id = self.add_node(Kind::Caption, s);
        let mut first_row = c.first_child;
        if let Some(fc) = c.first_child {
            if self.nodes[fc as usize].kind == Kind::Caption {
                // The whole node is copied, id field included (as in Zig).
                self.nodes[caption_id as usize] = self.nodes[fc as usize].clone();
                first_row = self.nodes[fc as usize].next_sibling;
            }
        }
        self.nodes[caption_id as usize].next_sibling = first_row;
        let id = self.add_node(Kind::Table, s);
        self.set_first_child(id, Some(caption_id));
        let cs = self.content_span_from_children(Some(caption_id));
        self.set_content_span(id, cs);
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
    }

    fn close_row(&mut self, ev: &Event) {
        let c = self.pop_container();
        if c.first_child.is_none() {
            // A separator line: propagate aligns to the table and mark the
            // previous row (and its cells) as a header row.
            if !self.containers.is_empty() {
                self.top().data.aligns = c.data.aligns.clone();
            }
            if let Some(prev_row) = self.get_tip() {
                if matches!(self.nodes[prev_row as usize].kind, Kind::Row { .. }) {
                    self.nodes[prev_row as usize].kind = Kind::Row { head: true };
                    let mut child = self.nodes[prev_row as usize].first_child;
                    let mut i = 0;
                    while let Some(cid) = child {
                        let al = c.data.aligns.get(i).copied().unwrap_or(Alignment::Default);
                        self.nodes[cid as usize].kind = Kind::Cell(Cell::new(true, al));
                        child = self.nodes[cid as usize].next_sibling;
                        i += 1;
                    }
                }
            }
            return;
        }
        let aligns: Vec<Alignment> = match self.containers.last() {
            Some(t) => t.data.aligns.clone(),
            None => Vec::new(),
        };
        let mut child = c.first_child;
        let mut i = 0;
        while let Some(cid) = child {
            let al = aligns.get(i).copied().unwrap_or(Alignment::Default);
            self.nodes[cid as usize].kind = Kind::Cell(Cell::new(false, al));
            child = self.nodes[cid as usize].next_sibling;
            i += 1;
        }
        self.close_generic(c, Kind::Row { head: false }, ev);
    }

    fn close_caption(&mut self, ev: &Event) {
        let c = self.pop_container();
        let Some(tip_id) = self.get_tip() else { return };
        if self.nodes[tip_id as usize].kind != Kind::Table {
            return;
        }
        let capt_id = self.add_node(Kind::Caption, Span::new(c.start, ev.end as usize + 1));
        self.set_first_child(capt_id, c.first_child);
        let cs = self.content_span_from_children(c.first_child);
        self.set_content_span(capt_id, cs);
        self.commit_attrs(capt_id, &c.attrs);
        if let Some(old_capt) = self.nodes[tip_id as usize].first_child {
            if self.nodes[old_capt as usize].kind == Kind::Caption {
                self.nodes[capt_id as usize].next_sibling = self.nodes[old_capt as usize].next_sibling;
                self.nodes[tip_id as usize].first_child = Some(capt_id);
                // A caption is written after the rows it names but is the
                // table's first child: both the table's span and interior run
                // from the rows' start to the caption's end.
                let table_span = &mut self.spans[tip_id as usize];
                table_span.end = table_span.end.max(ev.end as usize + 1);
                let ts = *table_span;
                let rows_start = match self.nodes[capt_id as usize].next_sibling {
                    Some(row) => self.spans[row as usize].start,
                    None => ts.start,
                };
                self.set_content_span(tip_id, Some(Span::new(rows_start, ts.end)));
            }
        }
    }

    fn close_footnote(&mut self, ev: &Event) {
        let c = self.pop_container();
        let Some(label) = &c.data.label else { return };
        let lab = normalize_label(label);
        let s = Span::new(c.start, ev.end as usize + 1);
        let id = self.add_node(Kind::Footnote { label: lab.clone() }, s);
        self.set_first_child(id, c.first_child);
        self.set_content_span(id, Self::marker_prefixed_content_span(s));
        self.commit_attrs(id, &c.attrs);
        self.footnotes.entry(lab).or_insert(id);
    }

    fn close_code_block(&mut self, ev: &Event) {
        let c = self.pop_container();
        let s = Span::new(c.start, ev.end as usize + 1);
        let text = self.accumulated_text.clone();
        let id = match &c.data.format {
            Some(fmt) => self.add_node(Kind::RawBlock { format: fmt.clone(), text }, s),
            None => self.add_node(Kind::CodeBlock { lang: c.data.lang.clone(), text }, s),
        };
        if let Some(bs) = c.body_start {
            self.set_content_span(id, Some(Span::new(bs, c.body_end)));
        }
        self.commit_attrs(id, &c.attrs);
        self.add_child_to_tip(id);
        self.context = Context::Normal;
        self.accumulated_text.clear();
    }

    /// The plain-text content of a not-yet-finalized child chain. Excludes
    /// footnote references, matching djot.js's `getStringContent`.
    fn get_string_content(&self, first: Option<NodeId>) -> Vec<u8> {
        let mut buf = Vec::new();
        self.add_string_content(first, &mut buf);
        buf
    }

    fn add_string_content(&self, first: Option<NodeId>, buf: &mut Vec<u8>) {
        let mut cur = first;
        while let Some(id) = cur {
            let node = &self.nodes[id as usize];
            match &node.kind {
                Kind::TextLeaf { kind, text } => {
                    if *kind != TextLeafKind::FootnoteReference {
                        buf.extend_from_slice(text)
                    }
                }
                Kind::Str(t) => buf.extend_from_slice(t),
                Kind::RawInline { text, .. } => buf.extend_from_slice(text),
                Kind::CodeBlock { text, .. } => buf.extend_from_slice(text),
                Kind::RawBlock { text, .. } => buf.extend_from_slice(text),
                Kind::SmartPunctuation(v) => buf.extend_from_slice(v.ascii().as_bytes()),
                Kind::SoftBreak | Kind::HardBreak => buf.push(b'\n'),
                _ => self.add_string_content(node.first_child, buf),
            }
            cur = node.next_sibling;
        }
    }

    fn get_unique_identifier(&self, s: &[u8]) -> Vec<u8> {
        let trimmed = slugify(s);
        if !trimmed.is_empty() && !self.identifiers.contains(&trimmed) {
            return trimmed;
        }
        let base: &[u8] = if trimmed.is_empty() { b"s" } else { &trimmed };
        let mut i: usize = 0;
        loop {
            i += 1;
            let mut candidate = base.to_vec();
            candidate.push(b'-');
            candidate.extend_from_slice(i.to_string().as_bytes());
            if !self.identifiers.contains(&candidate) {
                return candidate;
            }
        }
    }
}

fn collapse_and_unescape(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    let mut in_ws = false;
    while i < s.len() {
        let c = s[i];
        if c == b' ' || c == b'\r' || c == b'\n' {
            if !in_ws {
                out.push(b' ');
            }
            in_ws = true;
            i += 1;
        } else if c == b'\\' && i + 1 < s.len() && is_escapable_punct(s[i + 1]) {
            out.push(s[i + 1]);
            in_ws = false;
            i += 2;
        } else {
            out.push(c);
            in_ws = false;
            i += 1;
        }
    }
    out
}

fn is_escapable_punct(c: u8) -> bool {
    matches!(
        c,
        b'.' | b',' | b'\\' | b'/' | b'#' | b'!' | b'$' | b'%' | b'^' | b'&' | b'*' | b';' | b':' | b'{' | b'}' | b'='
            | b'-' | b'_' | b'`' | b'~' | b'+' | b'[' | b']' | b'(' | b')' | b'\'' | b'"' | b'?' | b'|'
    )
}

fn strip_newlines(s: &[u8]) -> Vec<u8> {
    s.iter().copied().filter(|&c| c != b'\r' && c != b'\n').collect()
}

fn is_identifier_excluded(c: u8) -> bool {
    matches!(
        c,
        b']' | b'[' | b'~' | b'!' | b'@' | b'#' | b'$' | b'%' | b'^' | b'&' | b'*' | b'(' | b')' | b'{' | b'}' | b'`'
            | b',' | b'.' | b'<' | b'>' | b'\\' | b'|' | b'=' | b'+' | b'/' | b'?'
    )
}

/// The identifier djot derives from a heading's text before any uniquifying
/// suffix: punctuation and whitespace runs become one `-`, and the ends are
/// trimmed of it. Public so the serializer can tell a section id the parser
/// generated from one an author wrote.
pub fn slugify(s: &[u8]) -> Vec<u8> {
    let mut base = Vec::with_capacity(s.len());
    let mut last_was_sep = false;
    for &c in s {
        if is_identifier_excluded(c) || is_ws(c) {
            if !last_was_sep && !base.is_empty() {
                base.push(b'-');
                last_was_sep = true;
            }
        } else {
            base.push(c);
            last_was_sep = false;
        }
    }
    while base.last() == Some(&b'-') {
        base.pop();
    }
    let start = base.iter().position(|&c| c != b'-').unwrap_or(base.len());
    base[start..].to_vec()
}

#[cfg(test)]
mod tests {
    use super::super::parse;
    use super::*;

    fn s<'d>(doc: &'d Document, id: NodeId) -> &'d [u8] {
        doc.text(id)
    }

    fn first(doc: &Document, id: NodeId) -> NodeId {
        doc.ast.nodes[id as usize].first_child.unwrap()
    }

    fn next(doc: &Document, id: NodeId) -> NodeId {
        doc.ast.nodes[id as usize].next_sibling.unwrap()
    }

    #[test]
    fn content_span_div_interior_covers_child_paragraph() {
        let src = b":::\nabc\n:::\n";
        let doc = parse(src);
        let div = first(&doc, doc.ast.root);
        assert!(matches!(&doc.ast.nodes[div as usize].kind, Kind::Container(c) if c.name.is_empty()));
        let cs = doc.content_span(div).unwrap();
        assert_eq!(trim_ws(cs.of(src)), b"abc");
        let para = first(&doc, div);
        assert_eq!(cs, doc.span(para));
    }

    #[test]
    fn content_span_marker_prefixed_container_is_whole_extent() {
        let doc = parse(b"> a\n> b\n");
        let bq = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(bq), &Kind::BlockQuote);
        let cs = doc.content_span(bq).unwrap();
        assert_eq!(cs, doc.span(bq));
        let para = first(&doc, bq);
        assert_ne!(cs, doc.span(para));
    }

    #[test]
    fn content_span_list_item_is_whole_extent() {
        let doc = parse(b"- a\n  b\n");
        let list = first(&doc, doc.ast.root);
        let item = first(&doc, list);
        assert_eq!(doc.ast.kind(item), &Kind::ListItem);
        assert_eq!(doc.content_span(item).unwrap(), doc.span(item));
    }

    #[test]
    fn content_span_inline_emphasis_covers_text() {
        let src = b"_abc_\n";
        let doc = parse(src);
        let para = first(&doc, doc.ast.root);
        let emph = first(&doc, para);
        assert_eq!(doc.ast.kind(emph), &Kind::InlineMark(InlineMark::Emph));
        assert_eq!(doc.content_span(emph).unwrap().of(src), b"abc");
    }

    #[test]
    fn content_span_leaf_str_stays_null() {
        let doc = parse(b"hello\n");
        let para = first(&doc, doc.ast.root);
        let st = first(&doc, para);
        assert!(matches!(doc.ast.kind(st), Kind::Str(_)));
        assert_eq!(doc.content_span(st), None);
    }

    #[test]
    fn span_inline_image_includes_bang() {
        let doc = parse(b"![alt](img.png)\n");
        let para = first(&doc, doc.ast.root);
        let img = first(&doc, para);
        assert!(matches!(doc.ast.kind(img), Kind::Image(_)));
        assert_eq!(s(&doc, img), b"![alt](img.png)");
    }

    #[test]
    fn span_reference_image_includes_bang() {
        let doc = parse(b"![alt][id]\n\n[id]: img.png\n");
        let para = first(&doc, doc.ast.root);
        let img = first(&doc, para);
        assert!(matches!(doc.ast.kind(img), Kind::Image(_)));
        assert_eq!(s(&doc, img), b"![alt][id]");
    }

    #[test]
    fn content_span_empty_div_stays_null() {
        let doc = parse(b":::\n:::\n");
        let div = first(&doc, doc.ast.root);
        assert!(doc.ast.nodes[div as usize].first_child.is_none());
        assert_eq!(doc.content_span(div), None);
    }

    #[test]
    fn span_bullet_list_sourcepos_parity() {
        let src = b" - a\n - b\n";
        let doc = parse(src);
        let list = first(&doc, doc.ast.root);
        assert!(matches!(doc.ast.kind(list), Kind::BulletList { .. }));
        assert_eq!(doc.span(list), Span::new(1, 10));
        let item1 = first(&doc, list);
        assert_eq!(doc.span(item1), Span::new(1, 5));
        assert_eq!(s(&doc, item1), b"- a\n");
        let item2 = next(&doc, item1);
        assert_eq!(doc.span(item2), Span::new(6, 10));
        let para1 = first(&doc, item1);
        let str1 = first(&doc, para1);
        assert_eq!(s(&doc, str1), b"a");
    }

    #[test]
    fn span_footnote_definition_stops_at_last_line() {
        let doc = parse(b"Text[^fn]\n\n[^fn]: a note.\n\n[link]: /url\n");
        let note = doc.labels.footnote(b"fn").unwrap();
        assert_eq!(s(&doc, note), b"[^fn]: a note.\n");
    }

    #[test]
    fn span_footnote_keeps_blank_line_between_paragraphs() {
        let doc = parse(b"[^fn]: one\n\n    two\n\nafter\n");
        let note = doc.labels.footnote(b"fn").unwrap();
        assert_eq!(s(&doc, note), b"[^fn]: one\n\n    two\n");
    }

    #[test]
    fn span_reference_definition_stops_before_next() {
        let doc = parse(b"[a]: /u\n\n[b]: /v\n");
        let r = doc.labels.reference(b"a").unwrap();
        assert_eq!(s(&doc, r), b"[a]: /u\n");
    }

    #[test]
    fn span_block_quote_does_not_swallow_blank_line() {
        let doc = parse(b"> quote\n\n[link]: /url\n");
        let bq = first(&doc, doc.ast.root);
        assert_eq!(s(&doc, bq), b"> quote\n");
    }

    #[test]
    fn span_list_and_last_item_stop_at_last_line() {
        let doc = parse(b"- item\n\n[link]: /url\n");
        let list = first(&doc, doc.ast.root);
        assert_eq!(s(&doc, list), b"- item\n");
        let item = first(&doc, list);
        assert_eq!(s(&doc, item), b"- item\n");
    }

    #[test]
    fn span_section_stops_at_last_child() {
        let doc = parse(b"# H\n\npara\n\n# H2\n\nx\n");
        let f = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(f), &Kind::Section);
        assert_eq!(s(&doc, f), b"# H\n\npara\n");
        let sec = next(&doc, f);
        assert_eq!(s(&doc, sec), b"# H2\n\nx\n");
        assert!(doc.span(f).end <= doc.span(sec).start);
    }

    #[test]
    fn span_table_stops_at_last_row() {
        let doc = parse(b"| a |\n| b |\n\nafter\n");
        let t = first(&doc, doc.ast.root);
        assert_eq!(s(&doc, t), b"| a |\n| b |\n");
    }

    #[test]
    fn span_captioned_table_runs_to_caption() {
        let src = b"| a | b |\n\n^ With a _caption_\nand another line.\n\nafter\n";
        let doc = parse(src);
        let t = first(&doc, doc.ast.root);
        let whole: &[u8] = b"| a | b |\n\n^ With a _caption_\nand another line.\n";
        assert_eq!(s(&doc, t), whole);
        assert_eq!(doc.content_span(t).unwrap().of(src), whole);
        let cap = first(&doc, t);
        assert_eq!(doc.ast.kind(cap), &Kind::Caption);
        let caps = doc.span(cap);
        let sp = doc.span(t);
        assert!(sp.start <= caps.start && caps.end <= sp.end);
    }

    #[test]
    fn span_trailing_blank_lines_belong_to_no_block() {
        let doc = parse(b"> q\n\n\n\n");
        let bq = first(&doc, doc.ast.root);
        assert_eq!(s(&doc, bq), b"> q\n");
    }

    #[test]
    fn attrs_span_block_attribute_line() {
        let src = b"{.vis .family}\nheld back\n";
        let doc = parse(src);
        let para = first(&doc, doc.ast.root);
        let a = doc.attrs_span(para).unwrap();
        assert_eq!(a.of(src), b"{.vis .family}");
        assert!(a.end <= doc.span(para).start);
    }

    #[test]
    fn attrs_span_multi_line_block() {
        let src = b"{.vis\n .family}\nheld back\n";
        let doc = parse(src);
        let para = first(&doc, doc.ast.root);
        assert_eq!(doc.attrs_span(para).unwrap().of(src), b"{.vis\n .family}");
    }

    #[test]
    fn attrs_span_inline_attributes() {
        let src = b"a [b]{.x} c\n";
        let doc = parse(src);
        let para = first(&doc, doc.ast.root);
        let n = doc.ast.children(para).find(|n| n.attrs.is_some()).unwrap().id;
        assert_eq!(doc.attrs_span(n).unwrap().of(src), b"{.x}");
    }

    #[test]
    fn attributes_word_with_nothing_before_takes_them_whole() {
        let doc = parse(b"hi{key=\"x\"}\n");
        let para = first(&doc, doc.ast.root);
        let st = first(&doc, para);
        assert_eq!(doc.ast.kind(st), &Kind::Str(b"hi".to_vec()));
        assert_eq!(doc.ast.attrs_of(st).get(b"key"), Some(&b"x"[..]));
        assert!(doc.ast.nodes[st as usize].next_sibling.is_none());
    }

    #[test]
    fn attributes_word_after_text_is_split_off() {
        let doc = parse(b"x word{.a}\n");
        let para = first(&doc, doc.ast.root);
        let before = first(&doc, para);
        assert_eq!(doc.ast.kind(before), &Kind::Str(b"x ".to_vec()));
        assert!(doc.ast.nodes[before as usize].attrs.is_none());
        let word = next(&doc, before);
        assert_eq!(doc.ast.kind(word), &Kind::Str(b"word".to_vec()));
        assert_eq!(doc.ast.attrs_of(word).get(b"class"), Some(&b"a"[..]));
    }

    #[test]
    fn attrs_span_two_blocks_merged_report_no_range() {
        let doc = parse(b"{.a}\n{.b}\npara\n");
        let para = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.attrs_of(para).get(b"class"), Some(&b"a b"[..]));
        assert_eq!(doc.attrs_span(para), None);
    }

    #[test]
    fn attrs_span_synthesized_set_reports_no_range() {
        let doc = parse(b"# Title\n");
        let sec = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(sec), &Kind::Section);
        assert!(doc.ast.attrs_of(sec).get(b"id").is_some());
        assert_eq!(doc.attrs_span(sec), None);
    }

    fn first_inline_leaf(doc: &Document) -> NodeId {
        let para = first(doc, doc.ast.root);
        first(doc, para)
    }

    #[test]
    fn content_span_inline_verbatim() {
        let src = b"`code`\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::Verbatim));
        assert_eq!(s(&doc, id), b"`code`");
        assert_eq!(doc.content_span(id).unwrap().of(src), b"code");
    }

    #[test]
    fn content_span_verbatim_raw_interior_differs() {
        let src = b"`` `x` ``\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert_eq!(doc.ast.kind(id), &Kind::TextLeaf { kind: TextLeafKind::Verbatim, text: b"`x`".to_vec() });
        assert_eq!(doc.content_span(id).unwrap().of(src), b" `x` ");
    }

    #[test]
    fn content_span_math() {
        let src = b"$`x+y`\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::InlineMath));
        assert_eq!(s(&doc, id), b"$`x+y`");
        assert_eq!(doc.content_span(id).unwrap().of(src), b"x+y");
        let src = b"$$`x+y`\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::DisplayMath));
        assert_eq!(s(&doc, id), b"$$`x+y`");
        assert_eq!(doc.content_span(id).unwrap().of(src), b"x+y");
    }

    #[test]
    fn content_span_raw_inline() {
        let src = b"`raw`{=html}\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(matches!(doc.ast.kind(id), Kind::RawInline { .. }));
        assert_eq!(doc.content_span(id).unwrap().of(src), b"raw");
    }

    #[test]
    fn content_span_url_and_email() {
        let src = b"<https://x.dev>\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::Url));
        assert_eq!(s(&doc, id), b"<https://x.dev>");
        assert_eq!(doc.content_span(id).unwrap().of(src), b"https://x.dev");
        let src = b"<a@b.dev>\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::Email));
        assert_eq!(doc.content_span(id).unwrap().of(src), b"a@b.dev");
    }

    #[test]
    fn content_span_symbol() {
        let src = b":smile:\n";
        let doc = parse(src);
        let id = first_inline_leaf(&doc);
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::Symb));
        assert_eq!(s(&doc, id), b":smile:");
        assert_eq!(doc.content_span(id).unwrap().of(src), b"smile");
    }

    #[test]
    fn content_span_footnote_reference() {
        let src = b"x[^note]\n\n[^note]: body\n";
        let doc = parse(src);
        let para = first(&doc, doc.ast.root);
        let id = next(&doc, first(&doc, para));
        assert!(doc.ast.kind(id).is_text_leaf(TextLeafKind::FootnoteReference));
        assert_eq!(s(&doc, id), b"[^note]");
        assert_eq!(doc.content_span(id).unwrap().of(src), b"note");
    }

    #[test]
    fn content_span_code_and_raw_block_bodies() {
        let src = b"```lua\nx=1\ny=2\n```\n";
        let doc = parse(src);
        let id = first(&doc, doc.ast.root);
        assert_eq!(doc.content_span(id).unwrap().of(src), b"x=1\ny=2\n");
        assert_eq!(doc.ast.kind(id), &Kind::CodeBlock { lang: Some(b"lua".to_vec()), text: b"x=1\ny=2\n".to_vec() });
        let src = b"```=html\n<b>hi</b>\n```\n";
        let doc = parse(src);
        let id = first(&doc, doc.ast.root);
        assert!(matches!(doc.ast.kind(id), Kind::RawBlock { .. }));
        assert_eq!(doc.content_span(id).unwrap().of(src), b"<b>hi</b>\n");
        let doc = parse(b"```\n```\n");
        let id = first(&doc, doc.ast.root);
        assert!(matches!(doc.ast.kind(id), Kind::CodeBlock { .. }));
        assert_eq!(doc.content_span(id), None);
    }
}
