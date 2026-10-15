//! reStructuredText — the parser. Source bytes to twig's shared `Ast`, judged
//! by `conformance`'s corpus comparison (`encode(parse(source)) ==
//! case.doctree`). Port of `src/languages/rst/parser.zig`.
//!
//! ── Scope of THIS file, today ───────────────────────────────────────────────
//! Paragraphs, section titles/nesting, transitions, block quotes and comments,
//! plus bullet lists, enumerated lists, definition lists and field lists. No
//! inline markup parsing yet — a paragraph's whole text becomes ONE `Str`
//! child — and no backslash escape is removed anywhere. Option lists, literal
//! blocks, directives, the hyperlink/footnote/citation/substitution clusters
//! and tables are unimplemented.
//!
//! ── Lists ────────────────────────────────────────────────────────────────
//! Both list constructs share `parse_list_item` (docutils' own arrangement).
//! The marker line's own remainder is the first paragraph's first line but is
//! not indented to the content column in the source, so `parse_marked_body`
//! merges it with any immediately-following continuation lines by hand. An
//! item with NOTHING after its marker takes its content column from the
//! minimum indent of whatever follows (`get_first_known_indented`).
//!
//! An enumerator is not self-evidently a list marker: `1.` is a list only if
//! the line BELOW it is blank, indented, or carries the next enumerator in the
//! sequence (`is_enumerated_list_item`). A definition list's term has its
//! evidence entirely BELOW it; `classify` is where that ordering lives.
//!
//! ── Why this shape ───────────────────────────────────────────────────────
//! Bottom-up onto `Builder` (a container's children are fully known before the
//! container is minted). Section nesting uses an explicit stack of pending
//! `Frame`s, since a `<section>` can only be minted once all its nested
//! subsections have closed; rST's levels are the ORDER adornment styles are
//! first used in, resolved from a document-wide `Style` stack.
//!
//! ── Section id/name generation ──────────────────────────────────────────────
//! docutils derives `ids`/`names` via `make_id`/`fully_normalize_name`.
//! `make_slug`/`make_normalized_name` are an ASCII-only approximation:
//! multi-byte UTF-8 sequences are dropped from the id slug and passed through
//! unchanged in the name.
//!
//! Spans are best-effort line-covering ranges; the corpus never checks them.
//! As in Zig, the parse does NOT end with `compact::run`.

use std::collections::HashSet;

use crate::ast::{Attrs, Builder, Container, KeyVal, Kind, ListNumbering, MarkupLeafKind, NodeId};
use crate::document::{ContainerOrigin, Document, Spelling};
use crate::span::Span;

use super::diagnostic::Diagnostic;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// Fed into the root `<document source="...">` attribute the corpus's
    /// doctrees carry (`"test data"` throughout). Empty omits the attribute.
    pub source_name: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct ParseResult {
    pub document: Document,
    pub diagnostics: Vec<Diagnostic>,
}

pub fn parse(source: &[u8], options: &Options) -> ParseResult {
    let mut p = Parser::new(source);
    let root = p.parse_document(options);
    let diagnostics = std::mem::take(&mut p.diagnostics);
    let document = p.b.finish_document(source, root);
    ParseResult { document, diagnostics }
}

/// One line of source, as a byte range excluding its terminating `\n`.
#[derive(Clone, Copy, Debug)]
struct LineInfo {
    start: usize,
    end: usize,
}

/// An adornment character plus whether it appeared as an OVERLINE-and-
/// underline pair — docutils treats those as distinct styles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Style {
    ch: u8,
    double: bool,
}

/// A section whose title is known but whose body is still being collected.
struct Frame {
    title_id: NodeId,
    children: Vec<NodeId>,
    span_start: usize,
    ids: Vec<u8>,
    names: Vec<u8>,
}

#[derive(Clone, Copy, Debug)]
struct TitleMatch<'a> {
    style: Style,
    text: &'a [u8],
    text_span: Span,
    /// Start of the whole title construct.
    span_start: usize,
    /// Line index right after the construct.
    next_line: usize,
}

struct BodyResult {
    items: Vec<NodeId>,
    stopped_at: usize,
}

/// The block construct a line opens — `Parser::classify`'s answer.
#[derive(Clone, Copy, Debug)]
enum BlockStart<'a> {
    // Carried as in Zig; `parse_document` re-matches the title itself.
    #[allow(dead_code)]
    Title(TitleMatch<'a>),
    Transition,
    Comment,
    Bullet(BulletMatch<'a>),
    Enumerator(EnumMatch),
    FieldMarker,
    DefinitionTerm,
    Paragraph,
}

/// Where a marked construct's body sits — docutils' choice between
/// `get_known_indented` and `get_first_known_indented`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ColumnRule {
    /// A list item with text after its marker knows its column.
    MarkerWidth,
    /// A field's body takes the REST from its own minimum indent.
    OwnMinimum,
}

struct Parser<'a> {
    source: &'a [u8],
    lines: Vec<LineInfo>,
    b: Builder,
    diagnostics: Vec<Diagnostic>,
    /// Ids already handed out to a section in this document.
    used_ids: HashSet<Vec<u8>>,
}

struct Extent {
    end: usize,
    min_indent: usize,
}

impl<'a> Parser<'a> {
    fn new(source: &'a [u8]) -> Parser<'a> {
        Parser {
            source,
            lines: compute_lines(source),
            b: Builder::new(),
            diagnostics: Vec::new(),
            used_ids: HashSet::new(),
        }
    }

    // ── line helpers ────────────────────────────────────────────────────

    fn line_text(&self, i: usize) -> &'a [u8] {
        let src: &'a [u8] = self.source;
        &src[self.lines[i].start..self.lines[i].end]
    }

    fn leading_spaces(&self, i: usize) -> usize {
        self.line_text(i).iter().take_while(|&&c| c == b' ').count()
    }

    fn is_blank_line(&self, i: usize) -> bool {
        self.line_text(i).iter().all(|&c| c == b' ' || c == b'\t')
    }

    /// `line_text(i)` with `indent` columns stripped from the front and
    /// trailing whitespace trimmed from the back.
    fn trimmed_content(&self, i: usize, indent: usize) -> &'a [u8] {
        let t = self.line_text(i);
        let c: &'a [u8] = if t.len() > indent { &t[indent..] } else { b"" };
        trim_end(c)
    }

    // ── title / adornment recognition ──────────────────────────────────

    fn match_title(&self, i: usize) -> Option<TitleMatch<'a>> {
        if i >= self.lines.len() {
            return None;
        }
        if self.leading_spaces(i) != 0 {
            return None;
        }
        let cur = self.trimmed_content(i, 0);
        if cur.is_empty() {
            return None;
        }

        if is_adornment_line(cur) {
            // Overline + title + underline; the text may be INSET.
            if i + 2 >= self.lines.len() {
                return None;
            }
            if self.is_blank_line(i + 1) {
                return None;
            }
            let text = trim(self.line_text(i + 1));
            if self.leading_spaces(i + 2) != 0 || self.is_blank_line(i + 2) {
                return None;
            }
            let under = self.trimmed_content(i + 2, 0);
            if !is_adornment_line(under) || under.len() != cur.len() || under[0] != cur[0] {
                return None;
            }
            return Some(TitleMatch {
                style: Style { ch: cur[0], double: true },
                text,
                text_span: Span::new(self.lines[i + 1].start, self.lines[i + 1].end),
                span_start: self.lines[i].start,
                next_line: i + 3,
            });
        }

        // Title + underline only.
        if i + 1 >= self.lines.len() {
            return None;
        }
        if self.leading_spaces(i + 1) != 0 || self.is_blank_line(i + 1) {
            return None;
        }
        let under = self.trimmed_content(i + 1, 0);
        if !is_adornment_line(under) {
            return None;
        }
        Some(TitleMatch {
            style: Style { ch: under[0], double: false },
            text: cur,
            text_span: Span::new(self.lines[i].start, self.lines[i].end),
            span_start: self.lines[i].start,
            next_line: i + 2,
        })
    }

    // ── section id / name generation ───────────────────────────────────

    fn make_slug(title: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut last_sep = true;
        let mut i = 0;
        while i < title.len() {
            let c = title[i];
            if c < 0x80 {
                if c.is_ascii_alphanumeric() {
                    out.push(c.to_ascii_lowercase());
                    last_sep = false;
                } else if !last_sep {
                    out.push(b'-');
                    last_sep = true;
                }
                i += 1;
            } else {
                i += utf8_seq_len(c);
                if !last_sep {
                    out.push(b'-');
                    last_sep = true;
                }
            }
        }
        while out.last() == Some(&b'-') {
            out.pop();
        }
        out
    }

    fn make_normalized_name(title: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut pending_space = false;
        let mut started = false;
        let mut i = 0;
        while i < title.len() {
            let c = title[i];
            if c == b' ' || c == b'\t' {
                if started {
                    pending_space = true;
                }
                i += 1;
                continue;
            }
            if pending_space {
                out.extend_from_slice(b"\\ ");
                pending_space = false;
            }
            if c < 0x80 {
                out.push(c.to_ascii_lowercase());
                i += 1;
            } else {
                let n = utf8_seq_len(c);
                out.extend_from_slice(&title[i..(i + n).min(title.len())]);
                i += n;
            }
            started = true;
        }
        out
    }

    /// The final document-unique id for `base`, registering it.
    fn uniquify(&mut self, base: Vec<u8>) -> Vec<u8> {
        if !self.used_ids.contains(&base) {
            self.used_ids.insert(base.clone());
            return base;
        }
        let mut n: usize = 1;
        loop {
            let mut cand = base.clone();
            cand.extend_from_slice(format!("-{n}").as_bytes());
            if self.used_ids.contains(&cand) {
                n += 1;
                continue;
            }
            self.used_ids.insert(cand.clone());
            return cand;
        }
    }

    // ── section frame open/close ────────────────────────────────────────

    fn open_section(
        &mut self,
        style_stack: &mut Vec<Style>,
        frames: &mut Vec<Frame>,
        root_children: &mut Vec<NodeId>,
        tm: TitleMatch<'a>,
    ) {
        let level_idx = style_stack.iter().position(|s| s.ch == tm.style.ch && s.double == tm.style.double);
        let new_level = level_idx.unwrap_or(style_stack.len()) + 1;
        while frames.len() >= new_level {
            let f = frames.pop().unwrap();
            let sec_id = self.finish_frame(f, tm.span_start);
            match frames.last_mut() {
                Some(top) => top.children.push(sec_id),
                None => root_children.push(sec_id),
            }
        }
        if level_idx.is_none() {
            style_stack.push(tm.style);
        } else {
            style_stack.truncate(new_level);
        }

        let title_str = self.b.add_leaf(Kind::Str(tm.text.to_vec()));
        self.b.set_span(title_str, tm.text_span);
        let title_id = self.b.add_container(Kind::Container(Container::named(b"title")), &[title_str]);
        self.b.set_spelling(title_id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
        self.b.set_span(title_id, tm.text_span);

        let slug = Self::make_slug(tm.text);
        let ids = self.uniquify(slug);
        let names = Self::make_normalized_name(tm.text);

        frames.push(Frame { title_id, children: Vec::new(), span_start: tm.span_start, ids, names });
    }

    fn finish_frame(&mut self, frame: Frame, end_offset: usize) -> NodeId {
        let mut all = Vec::with_capacity(1 + frame.children.len());
        all.push(frame.title_id);
        all.extend_from_slice(&frame.children);

        let id = self.b.add_container(Kind::Section, &all);
        self.b.set_span(id, Span::new(frame.span_start, end_offset));
        self.b.set_attrs(
            id,
            Attrs { entries: vec![KeyVal::new(b"ids", Some(&frame.ids)), KeyVal::new(b"names", Some(&frame.names))] },
        );
        id
    }

    // ── the top-level document scan ─────────────────────────────────────

    fn parse_document(&mut self, options: &Options) -> NodeId {
        let mut root_children: Vec<NodeId> = Vec::new();
        let mut style_stack: Vec<Style> = Vec::new();
        let mut frames: Vec<Frame> = Vec::new();

        let mut i = 0;
        while i < self.lines.len() {
            let r = self.parse_body(i, self.lines.len(), 0);
            match frames.last_mut() {
                Some(top) => top.children.extend_from_slice(&r.items),
                None => root_children.extend_from_slice(&r.items),
            }
            i = r.stopped_at;
            if i >= self.lines.len() {
                break;
            }

            // `parse_body` only stops early at top level when it found a title.
            let Some(tm) = self.match_title(i) else { break };
            self.open_section(&mut style_stack, &mut frames, &mut root_children, tm);
            i = tm.next_line;
        }

        while let Some(f) = frames.pop() {
            let sec_id = self.finish_frame(f, self.source.len());
            match frames.last_mut() {
                Some(top) => top.children.push(sec_id),
                None => root_children.push(sec_id),
            }
        }

        let root = self.b.add_container(Kind::Doc, &root_children);
        if !options.source_name.is_empty() {
            self.b.set_attrs(root, Attrs { entries: vec![KeyVal::new(b"source", Some(&options.source_name))] });
        }
        root
    }

    // ── the indentation-scoped body scan ────────────────────────────────

    /// Parses the blocks in lines `[lo, hi)`, all blank OR indented at least
    /// to `indent`. Stops at `hi`, UNLESS `indent == 0` and a title is found
    /// first (titles are recognized only at document top level).
    fn parse_body(&mut self, lo: usize, hi: usize, indent: usize) -> BodyResult {
        let mut children: Vec<NodeId> = Vec::new();
        let mut i = lo;
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            let line_indent = self.leading_spaces(i);
            if line_indent > indent {
                let ext = self.find_elevated_extent(i, hi, indent);
                let inner = self.parse_body(i, ext.end, ext.min_indent);
                let bq_id = self.b.add_container(Kind::BlockQuote, &inner.items);
                self.b.set_span(bq_id, Span::new(self.lines[i].start, self.lines[ext.end - 1].end));
                children.push(bq_id);
                i = ext.end;
                continue;
            }
            if line_indent < indent {
                break; // defensive; callers should not slice across a dedent
            }

            match self.classify(i, hi, indent) {
                // The one early stop: `parse_document` takes the title over.
                BlockStart::Title(_) => break,
                BlockStart::Transition => {
                    let id = self.b.add_leaf(Kind::ThematicBreak);
                    self.b.set_span(id, Span::new(self.lines[i].start, self.lines[i].end));
                    children.push(id);
                    i += 1;
                }
                BlockStart::Comment => {
                    let (id, next) = self.parse_comment(i, hi, indent);
                    children.push(id);
                    i = next;
                }
                BlockStart::Bullet(bm) => {
                    let (id, next) = self.parse_bullet_list(i, hi, indent, bm.marker);
                    children.push(id);
                    i = next;
                }
                BlockStart::Enumerator(em) => {
                    let (id, next) = self.parse_enumerated_list(i, hi, indent, em);
                    children.push(id);
                    i = next;
                }
                BlockStart::FieldMarker => {
                    let (id, next) = self.parse_field_list(i, hi, indent);
                    children.push(id);
                    i = next;
                }
                BlockStart::DefinitionTerm => {
                    let (id, next) = self.parse_definition_list(i, hi, indent);
                    children.push(id);
                    i = next;
                }
                BlockStart::Paragraph => {
                    let para_end = self.find_paragraph_end(i, hi, indent);
                    let text = self.assemble_text(i, para_end, indent);
                    let str_id = self.b.add_leaf(Kind::Str(text));
                    let span = Span::new(self.lines[i].start, self.lines[para_end - 1].end);
                    self.b.set_span(str_id, span);
                    let para_id = self.b.add_container(Kind::Para, &[str_id]);
                    self.b.set_span(para_id, span);
                    children.push(para_id);
                    i = para_end;
                }
            }
        }
        BodyResult { items: children, stopped_at: i }
    }

    /// What block line `i` opens, given that it is non-blank and sits at
    /// exactly `indent`. The ORDER is docutils' `Body` transition order.
    fn classify(&self, i: usize, hi: usize, indent: usize) -> BlockStart<'a> {
        if indent == 0 {
            if let Some(tm) = self.match_title(i) {
                return BlockStart::Title(tm);
            }
        }
        let content = self.trimmed_content(i, indent);
        if is_transition_line(content) {
            return BlockStart::Transition;
        }
        if is_comment_start(content) {
            return BlockStart::Comment;
        }
        if let Some(bm) = match_bullet_marker(content) {
            return BlockStart::Bullet(bm);
        }
        if let Some(em) = self.match_enumerator_start(i, hi, indent) {
            return BlockStart::Enumerator(em);
        }
        if match_field_marker(content).is_some() {
            return BlockStart::FieldMarker;
        }
        // A term: a line that looks like nothing else, followed immediately
        // (no blank line) by a deeper one.
        if i + 1 < hi && !self.is_blank_line(i + 1) && self.leading_spaces(i + 1) > indent {
            return BlockStart::DefinitionTerm;
        }
        BlockStart::Paragraph
    }

    fn find_paragraph_end(&self, lo: usize, hi: usize, indent: usize) -> usize {
        let mut i = lo + 1;
        while i < hi {
            if self.is_blank_line(i) {
                break;
            }
            if self.leading_spaces(i) != indent {
                break;
            }
            i += 1;
        }
        i
    }

    fn assemble_text(&self, lo: usize, end_ex: usize, indent: usize) -> Vec<u8> {
        let mut buf = Vec::new();
        for ln in lo..end_ex {
            if ln > lo {
                buf.push(b'\n');
            }
            let t = self.line_text(ln);
            if t.len() > indent {
                buf.extend_from_slice(&t[indent..]);
            }
        }
        buf
    }

    /// The maximal contiguous (blank-tolerant) run of lines from `lo`, each
    /// indented MORE than `above`, plus the minimum indent seen in it.
    fn find_elevated_extent(&self, lo: usize, hi: usize, above: usize) -> Extent {
        let mut i = lo;
        let mut last_content_end = lo;
        let mut min_indent = usize::MAX;
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            let ind = self.leading_spaces(i);
            if ind <= above {
                break;
            }
            if ind < min_indent {
                min_indent = ind;
            }
            i += 1;
            last_content_end = i;
        }
        Extent { end: last_content_end, min_indent: if min_indent == usize::MAX { above + 1 } else { min_indent } }
    }

    /// The run of lines from `lo`, each indented at least `min_indent`,
    /// stopping at the FIRST blank line (an explicit markup body).
    fn find_contiguous_indented_run(&self, lo: usize, hi: usize, min_indent: usize) -> usize {
        let mut i = lo;
        while i < hi && !self.is_blank_line(i) && self.leading_spaces(i) >= min_indent {
            i += 1;
        }
        i
    }

    fn parse_comment(&mut self, i: usize, hi: usize, indent: usize) -> (NodeId, usize) {
        let content = self.trimmed_content(i, indent);
        let mut text: Vec<u8> = Vec::new();
        let mut first = true;
        if content.len() > 2 {
            text.extend_from_slice(&content[3..]);
            first = false;
        }
        let body_col = indent + 3;
        let end = self.find_contiguous_indented_run(i + 1, hi, body_col);
        for ln in i + 1..end {
            let t = self.line_text(ln);
            let piece: &[u8] = if t.len() > body_col { &t[body_col..] } else { b"" };
            if !first {
                text.push(b'\n');
            }
            text.extend_from_slice(piece);
            first = false;
        }
        let next = if end > i + 1 { end } else { i + 1 };
        // A genuinely empty comment has no `Text` child in docutils' doctree,
        // so it is built as a generic, childless `container`.
        let id = if text.is_empty() {
            let cid = self.b.add_leaf(Kind::Container(Container::named(b"comment")));
            self.b.set_spelling(cid, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            cid
        } else {
            self.b.add_leaf(Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text })
        };
        self.b.set_span(id, Span::new(self.lines[i].start, self.lines[next - 1].end));
        // docutils marks every text-preserving element this way.
        self.b.set_attrs(id, Attrs { entries: vec![KeyVal::new(b"xml:space", Some(b"preserve"))] });
        (id, next)
    }

    /// A maximal run of consecutive bullet-list items sharing `marker`, all at
    /// column `indent`. A different marker ends the list unconsumed.
    fn parse_bullet_list(&mut self, lo: usize, hi: usize, indent: usize, marker: &'a [u8]) -> (NodeId, usize) {
        let mut items: Vec<NodeId> = Vec::new();
        let mut i = lo;
        let mut list_end = self.lines[lo].end;
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            let content = self.trimmed_content(i, indent);
            let Some(bm) = match_bullet_marker(content) else { break };
            if bm.marker != marker {
                break;
            }

            let (id, next) = self.parse_list_item(i, hi, indent, content, bm.rel_start, bm.has_content);
            items.push(id);
            list_end = self.lines[next - 1].end;
            i = next;
        }

        let list_id = self.b.add_container(Kind::BulletList { tight: false }, &items);
        self.b.set_span(list_id, Span::new(self.lines[lo].start, list_end));
        self.b.set_attrs(list_id, Attrs { entries: vec![KeyVal::new(b"bullet", Some(marker))] });
        (list_id, i)
    }

    /// One `<list_item>`, shared by bullet and enumerated lists.
    fn parse_list_item(
        &mut self,
        item_line: usize,
        hi: usize,
        indent: usize,
        content: &'a [u8],
        rel_start: usize,
        has_content: bool,
    ) -> (NodeId, usize) {
        let body =
            self.parse_marked_body(item_line, hi, indent, content, rel_start, has_content, ColumnRule::MarkerWidth);
        let item_id = self.b.add_container(Kind::ListItem, &body.items);
        self.b.set_span(item_id, Span::new(self.lines[item_line].start, self.lines[body.stopped_at - 1].end));
        (item_id, body.stopped_at)
    }

    /// The blocks introduced by a MARKER line. Its remainder can only ever be
    /// a paragraph (`:field1: :field2: body` is out of reach until the parser
    /// can address a line from a column other than zero).
    #[allow(clippy::too_many_arguments)]
    fn parse_marked_body(
        &mut self,
        marker_line: usize,
        hi: usize,
        indent: usize,
        content: &'a [u8],
        rel_start: usize,
        has_content: bool,
        column: ColumnRule,
    ) -> BodyResult {
        let mut children: Vec<NodeId> = Vec::new();

        let known_column = has_content && column == ColumnRule::MarkerWidth;
        let content_col = indent + rel_start;
        let ext = self.find_elevated_extent(marker_line + 1, hi, if known_column { content_col - 1 } else { indent });
        let body_col = if known_column { content_col } else { ext.min_indent };

        let mut body_start = marker_line + 1;
        if has_content {
            let mut para_end = marker_line + 1;
            while para_end < ext.end && !self.is_blank_line(para_end) && self.leading_spaces(para_end) == body_col {
                para_end += 1;
            }

            let mut buf: Vec<u8> = content[rel_start..].to_vec();
            for ln in marker_line + 1..para_end {
                buf.push(b'\n');
                buf.extend_from_slice(self.trimmed_content(ln, body_col));
            }
            let str_id = self.b.add_leaf(Kind::Str(buf));
            let span = Span::new(self.lines[marker_line].start, self.lines[para_end - 1].end);
            self.b.set_span(str_id, span);
            let para_id = self.b.add_container(Kind::Para, &[str_id]);
            self.b.set_span(para_id, span);
            children.push(para_id);
            body_start = para_end;
        }

        let rest = self.parse_body(body_start, ext.end, body_col);
        children.extend_from_slice(&rest.items);
        BodyResult { items: children, stopped_at: rest.stopped_at }
    }

    // ── enumerated lists ────────────────────────────────────────────────

    /// Does line `i` START an enumerated list?
    fn match_enumerator_start(&self, i: usize, hi: usize, indent: usize) -> Option<EnumMatch> {
        let em = match_enumerator(self.trimmed_content(i, indent), None)?;
        if !self.is_enumerated_list_item(i, hi, indent, em) {
            return None;
        }
        Some(em)
    }

    /// docutils' `is_enumerated_list_item`: an enumerator needs a second piece
    /// of evidence from the line below it.
    fn is_enumerated_list_item(&self, i: usize, hi: usize, indent: usize, em: EnumMatch) -> bool {
        let Some(ordinal) = em.ordinal else { return false };
        if i + 1 >= hi {
            return true;
        }
        if self.is_blank_line(i + 1) {
            return true;
        }
        if self.leading_spaces(i + 1) > indent {
            return true;
        }

        let next = self.trimmed_content(i + 1, indent);
        if let Some(e) = make_enumerator(ordinal.wrapping_add(1), em.sequence, em.format) {
            if next.starts_with(&e) {
                return true;
            }
        }
        // `#` may take over from a numbered enumerator at any point.
        if let Some(e) = make_enumerator(1, Sequence::Auto, em.format) {
            if next.starts_with(&e) {
                return true;
            }
        }
        false
    }

    /// A maximal run of enumerated items, `lo` being the first.
    fn parse_enumerated_list(&mut self, lo: usize, hi: usize, indent: usize, first: EnumMatch) -> (NodeId, usize) {
        let mut items: Vec<NodeId> = Vec::new();

        // docutils writes `enumtype="arabic"` for a list that opens with `#`.
        let enumtype = if first.sequence == Sequence::Auto { Sequence::Arabic } else { first.sequence };
        let mut auto = first.sequence == Sequence::Auto;
        let first_ordinal = first.ordinal.expect("validated enumerator has an ordinal");
        let mut last_ordinal = first_ordinal;

        let mut i = lo;
        let mut list_end = self.lines[lo].end;
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            let content = self.trimmed_content(i, indent);
            let em = if i == lo {
                first
            } else {
                let Some(cand) = match_enumerator(content, Some(enumtype)) else { break };
                if cand.format != first.format {
                    break;
                }
                if cand.sequence != Sequence::Auto {
                    if auto || cand.sequence != enumtype {
                        break;
                    }
                    let Some(ord) = cand.ordinal else { break };
                    if ord != last_ordinal.wrapping_add(1) {
                        break;
                    }
                }
                if !self.is_enumerated_list_item(i, hi, indent, cand) {
                    break;
                }
                cand
            };

            let (id, next) = self.parse_list_item(i, hi, indent, content, em.rel_start, em.has_content);
            items.push(id);
            list_end = self.lines[next - 1].end;
            i = next;

            if em.sequence == Sequence::Auto {
                auto = true;
            } else {
                last_ordinal = em.ordinal.expect("validated enumerator has an ordinal");
            }
        }

        let list_id = self.b.add_container(
            Kind::OrderedList {
                numbering: enumtype.numbering(),
                tight: false,
                start: if first_ordinal != 1 { Some(first_ordinal) } else { None },
            },
            &items,
        );
        self.b.set_span(list_id, Span::new(self.lines[lo].start, list_end));

        // All four attributes are written even where the kind holds the same
        // fact: `doctree`'s encoder takes attributes from `attrs` only.
        let (prefix, suffix) = first.format.info();
        let mut entries = vec![
            KeyVal::new(b"enumtype", Some(enumtype.doctree_name().as_bytes())),
            KeyVal::new(b"prefix", Some(prefix.as_bytes())),
            KeyVal::new(b"suffix", Some(suffix.as_bytes())),
        ];
        if first_ordinal != 1 {
            entries.push(KeyVal::new(b"start", Some(first_ordinal.to_string().as_bytes())));
        }
        self.b.set_attrs(list_id, Attrs { entries });
        (list_id, i)
    }

    // ── field lists ─────────────────────────────────────────────────────

    /// A maximal run of `:name: body` fields at `indent`. All four docutils
    /// elements stay GENERIC containers.
    fn parse_field_list(&mut self, lo: usize, hi: usize, indent: usize) -> (NodeId, usize) {
        let mut fields: Vec<NodeId> = Vec::new();
        let mut i = lo;
        let mut list_end = self.lines[lo].end;
        let directive = Spelling::ContainerOrigin(ContainerOrigin::Directive);
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            if self.leading_spaces(i) != indent {
                break;
            }
            let content = self.trimmed_content(i, indent);
            let Some(fm) = match_field_marker(content) else { break };

            let marker_span = Span::new(self.lines[i].start, self.lines[i].end);
            let name_str = self.b.add_leaf(Kind::Str(fm.name.to_vec()));
            self.b.set_span(name_str, marker_span);
            let name_id = self.b.add_container(Kind::Container(Container::named(b"field_name")), &[name_str]);
            self.b.set_spelling(name_id, directive);
            self.b.set_span(name_id, marker_span);

            let body =
                self.parse_marked_body(i, hi, indent, content, fm.rel_start, fm.has_content, ColumnRule::OwnMinimum);
            // docutils appends the `field_body` unconditionally.
            let body_id = self.b.add_container(Kind::Container(Container::named(b"field_body")), &body.items);
            self.b.set_spelling(body_id, directive);
            let field_span = Span::new(self.lines[i].start, self.lines[body.stopped_at - 1].end);
            self.b.set_span(body_id, field_span);

            let field_id = self.b.add_container(Kind::Container(Container::named(b"field")), &[name_id, body_id]);
            self.b.set_spelling(field_id, directive);
            self.b.set_span(field_id, field_span);
            fields.push(field_id);

            list_end = self.lines[body.stopped_at - 1].end;
            i = body.stopped_at;
        }

        let list_id = self.b.add_container(Kind::Container(Container::named(b"field_list")), &fields);
        self.b.set_spelling(list_id, directive);
        self.b.set_span(list_id, Span::new(self.lines[lo].start, list_end));
        (list_id, i)
    }

    // ── definition lists ────────────────────────────────────────────────

    /// A maximal run of `term` / indented-`definition` pairs at `indent`. The
    /// list continues only while `classify` keeps answering `DefinitionTerm`.
    fn parse_definition_list(&mut self, lo: usize, hi: usize, indent: usize) -> (NodeId, usize) {
        let mut items: Vec<NodeId> = Vec::new();
        let mut i = lo;
        let mut list_end = self.lines[lo].end;
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            if self.leading_spaces(i) != indent {
                break;
            }
            if i != lo && !matches!(self.classify(i, hi, indent), BlockStart::DefinitionTerm) {
                break;
            }

            let term_line = i;
            let term_span = Span::new(self.lines[term_line].start, self.lines[term_line].end);
            let mut item_children: Vec<NodeId> = Vec::new();

            let mut parts = TermParts { line: self.trimmed_content(term_line, indent), pos: 0, done: false };
            let term_text = parts.next().expect("a term line always yields one piece");
            let term_str = self.b.add_leaf(Kind::Str(term_text.to_vec()));
            self.b.set_span(term_str, term_span);
            let term_id = self.b.add_container(Kind::Term, &[term_str]);
            self.b.set_span(term_id, term_span);
            item_children.push(term_id);
            while let Some(classifier) = parts.next() {
                let c_str = self.b.add_leaf(Kind::Str(classifier.to_vec()));
                self.b.set_span(c_str, term_span);
                let c_id = self.b.add_container(Kind::Container(Container::named(b"classifier")), &[c_str]);
                self.b.set_spelling(c_id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
                self.b.set_span(c_id, term_span);
                item_children.push(c_id);
            }

            let ext = self.find_elevated_extent(term_line + 1, hi, indent);
            let body = self.parse_body(term_line + 1, ext.end, ext.min_indent);
            let def_id = self.b.add_container(Kind::Definition, &body.items);
            self.b.set_span(def_id, Span::new(self.lines[term_line + 1].start, self.lines[ext.end - 1].end));
            item_children.push(def_id);

            let item_id = self.b.add_container(Kind::DefinitionListItem, &item_children);
            self.b.set_span(item_id, Span::new(self.lines[term_line].start, self.lines[ext.end - 1].end));
            items.push(item_id);

            list_end = self.lines[ext.end - 1].end;
            i = ext.end;
        }

        let list_id = self.b.add_container(Kind::DefinitionList, &items);
        self.b.set_span(list_id, Span::new(self.lines[lo].start, list_end));
        (list_id, i)
    }
}

/// A term line split on docutils' `classifier_delimiter`, ` +: +`. The first
/// piece is the term; every later one is a `<classifier>`. A backslash-escaped
/// colon has no space immediately before it, so it never splits.
struct TermParts<'a> {
    line: &'a [u8],
    pos: usize,
    done: bool,
}

impl<'a> TermParts<'a> {
    fn next(&mut self) -> Option<&'a [u8]> {
        if self.done {
            return None;
        }
        let line = self.line;
        let mut k = self.pos;
        while k < line.len() {
            if line[k] != b':' || k == 0 || line[k - 1] != b' ' || k + 1 >= line.len() || line[k + 1] != b' ' {
                k += 1;
                continue;
            }
            let mut start = k;
            while start > self.pos && line[start - 1] == b' ' {
                start -= 1;
            }
            let mut end = k + 1;
            while end < line.len() && line[end] == b' ' {
                end += 1;
            }
            let piece = &line[self.pos..start];
            self.pos = end;
            return Some(piece);
        }
        self.done = true;
        Some(&line[self.pos..])
    }
}

fn compute_lines(source: &[u8]) -> Vec<LineInfo> {
    let mut list = Vec::new();
    let mut start = 0;
    for (i, &c) in source.iter().enumerate() {
        if c == b'\n' {
            list.push(LineInfo { start, end: i });
            start = i + 1;
        }
    }
    list.push(LineInfo { start, end: source.len() });
    list
}

fn utf8_seq_len(byte0: u8) -> usize {
    if byte0 & 0xE0 == 0xC0 {
        return 2;
    }
    if byte0 & 0xF0 == 0xE0 {
        return 3;
    }
    if byte0 & 0xF8 == 0xF0 {
        return 4;
    }
    1
}

fn is_ws(c: u8) -> bool {
    c == b' ' || c == b'\t'
}

/// Zig's `std.mem.trimEnd(u8, s, " \t")`.
fn trim_end(s: &[u8]) -> &[u8] {
    let mut e = s.len();
    while e > 0 && is_ws(s[e - 1]) {
        e -= 1;
    }
    &s[..e]
}

/// Zig's `std.mem.trim(u8, s, " \t")`.
fn trim(s: &[u8]) -> &[u8] {
    let s = trim_end(s);
    let mut b = 0;
    while b < s.len() && is_ws(s[b]) {
        b += 1;
    }
    &s[b..]
}

/// docutils' adornment character set — ASCII punctuation.
const ADORNMENT_CHARS: &[u8] = b"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

fn is_adornment_char(c: u8) -> bool {
    ADORNMENT_CHARS.contains(&c)
}

/// A line of one repeated adornment character, any length (an underline may
/// be as short as one character; a TRANSITION needs 4+).
fn is_adornment_line(s: &[u8]) -> bool {
    if s.is_empty() || !is_adornment_char(s[0]) {
        return false;
    }
    s.iter().all(|&c| c == s[0])
}

fn is_transition_line(s: &[u8]) -> bool {
    s.len() >= 4 && is_adornment_line(s)
}

/// `..` alone, or `..` followed by a space — docutils' explicit markup start.
/// Every explicit-markup construct this slice doesn't yet parse falls back to
/// a comment.
fn is_comment_start(content: &[u8]) -> bool {
    if content.len() < 2 || content[0] != b'.' || content[1] != b'.' {
        return false;
    }
    content.len() == 2 || content[2] == b' '
}

/// Byte length of a bullet-list marker at the start of `s`: `-+*` plus
/// U+2022 `•`, U+2023 `‣`, U+2043 `⁃`.
fn bullet_marker_len(s: &[u8]) -> Option<usize> {
    if s.is_empty() {
        return None;
    }
    if s[0] == b'-' || s[0] == b'*' || s[0] == b'+' {
        return Some(1);
    }
    if s.len() >= 3 && s[0] == 0xE2 {
        if s[1] == 0x80 && (s[2] == 0xA2 || s[2] == 0xA3) {
            return Some(3);
        }
        if s[1] == 0x81 && s[2] == 0x83 {
            return Some(3);
        }
    }
    None
}

#[derive(Clone, Copy, Debug)]
struct BulletMatch<'a> {
    marker: &'a [u8],
    /// Byte offset within `content` where the item's own text starts. Only
    /// read when `has_content`.
    rel_start: usize,
    has_content: bool,
}

/// A bullet marker: one marker character, then either end-of-content or a
/// space and more text.
fn match_bullet_marker(content: &[u8]) -> Option<BulletMatch<'_>> {
    let mlen = bullet_marker_len(content)?;
    let marker = &content[..mlen];
    if content.len() == mlen {
        return Some(BulletMatch { marker, rel_start: mlen + 1, has_content: false });
    }
    if content[mlen] != b' ' {
        return None;
    }
    let mut k = mlen;
    while k < content.len() && content[k] == b' ' {
        k += 1;
    }
    if k == content.len() {
        return Some(BulletMatch { marker, rel_start: mlen + 1, has_content: false });
    }
    Some(BulletMatch { marker, rel_start: k, has_content: true })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FieldMatch<'a> {
    /// The name between the colons, verbatim — escapes NOT removed.
    name: &'a [u8],
    rel_start: usize,
    has_content: bool,
}

/// docutils' `field_marker` pattern
/// `:(?![: ])([^:\\]|\\.|:(?!([ `]|$)))*(?<! ):( +|$)`, unwound into a
/// left-to-right scan: the closer is the FIRST colon followed by a space or
/// the line's end, and a colon followed by a backtick before that point kills
/// the match.
fn match_field_marker(content: &[u8]) -> Option<FieldMatch<'_>> {
    if content.len() < 2 || content[0] != b':' {
        return None;
    }
    if content[1] == b':' || content[1] == b' ' {
        return None;
    }

    let mut k = 1;
    while k < content.len() {
        if content[k] == b'\\' {
            k += 2;
            continue;
        }
        if content[k] != b':' {
            k += 1;
            continue;
        }
        let after = content.get(k + 1).copied();
        if let Some(a) = after {
            if a != b' ' && a != b'`' {
                k += 1;
                continue;
            }
        }
        if after == Some(b'`') {
            return None;
        }
        if content[k - 1] == b' ' {
            return None;
        }
        let name = &content[1..k];
        if name.is_empty() {
            return None;
        }
        let mut rest = k + 1;
        while rest < content.len() && content[rest] == b' ' {
            rest += 1;
        }
        return Some(FieldMatch { name, rel_start: rest, has_content: rest < content.len() });
    }
    None
}

// ── enumerators ──────────────────────────────────────────────────────────

/// How an enumerator is punctuated; part of a list's identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Format {
    Parens,
    Rparen,
    Period,
}

impl Format {
    /// `(prefix, suffix)`.
    fn info(self) -> (&'static str, &'static str) {
        match self {
            Format::Parens => ("(", ")"),
            Format::Rparen => ("", ")"),
            Format::Period => ("", "."),
        }
    }
}

/// The counting system an enumerator is written in. `Auto` is rST's `#`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Sequence {
    Arabic,
    Loweralpha,
    Upperalpha,
    Lowerroman,
    Upperroman,
    Auto,
}

impl Sequence {
    /// Every candidate `parse_enumerator`'s fallback loop tries, in docutils'
    /// order.
    const ORDERED: [Sequence; 5] =
        [Sequence::Arabic, Sequence::Loweralpha, Sequence::Upperalpha, Sequence::Lowerroman, Sequence::Upperroman];

    fn doctree_name(self) -> &'static str {
        match self {
            Sequence::Arabic | Sequence::Auto => "arabic",
            Sequence::Loweralpha => "loweralpha",
            Sequence::Upperalpha => "upperalpha",
            Sequence::Lowerroman => "lowerroman",
            Sequence::Upperroman => "upperroman",
        }
    }

    fn numbering(self) -> ListNumbering {
        match self {
            Sequence::Arabic | Sequence::Auto => ListNumbering::Decimal,
            Sequence::Loweralpha => ListNumbering::LowerAlpha,
            Sequence::Upperalpha => ListNumbering::UpperAlpha,
            Sequence::Lowerroman => ListNumbering::LowerRoman,
            Sequence::Upperroman => ListNumbering::UpperRoman,
        }
    }

    /// docutils' `sequenceregexps` — a CHARACTER-SET test only.
    fn accepts(self, text: &[u8]) -> bool {
        match self {
            Sequence::Auto => text == b"#",
            Sequence::Arabic => all_of(text, |c| c.is_ascii_digit()),
            Sequence::Loweralpha => text.len() == 1 && text[0].is_ascii_lowercase(),
            Sequence::Upperalpha => text.len() == 1 && text[0].is_ascii_uppercase(),
            Sequence::Lowerroman => all_of(text, |c| b"ivxlcdm".contains(&c)),
            Sequence::Upperroman => all_of(text, |c| b"IVXLCDM".contains(&c)),
        }
    }
}

fn all_of(text: &[u8], pred: impl Fn(u8) -> bool) -> bool {
    !text.is_empty() && text.iter().all(|&c| pred(c))
}

#[derive(Clone, Copy, Debug)]
struct EnumMatch {
    format: Format,
    sequence: Sequence,
    /// `None` when well-formed but names no number (`iiii`, `LCD`).
    ordinal: Option<u32>,
    rel_start: usize,
    has_content: bool,
}

/// Split `content` into an enumerator and its remainder — docutils'
/// `enumerator` regex: an optional `(`, a run of enumerator characters, a `)`
/// or `.`, then a space or the end of the line.
fn match_enumerator(content: &[u8], expected: Option<Sequence>) -> Option<EnumMatch> {
    if content.is_empty() {
        return None;
    }
    let parens = content[0] == b'(';
    let text_start = if parens { 1 } else { 0 };
    let mut k = text_start;
    while k < content.len() && (content[k].is_ascii_alphanumeric() || content[k] == b'#') {
        k += 1;
    }
    if k == text_start || k >= content.len() {
        return None;
    }
    let format = if parens {
        if content[k] == b')' {
            Format::Parens
        } else {
            return None;
        }
    } else if content[k] == b')' {
        Format::Rparen
    } else if content[k] == b'.' {
        Format::Period
    } else {
        return None;
    };

    let text = &content[text_start..k];
    let sequence = resolve_sequence(text, expected)?;

    let mut rest = k + 1;
    if rest == content.len() {
        return Some(EnumMatch {
            format,
            sequence,
            ordinal: ordinal_of(text, sequence),
            rel_start: rest + 1,
            has_content: false,
        });
    }
    if content[rest] != b' ' {
        return None;
    }
    while rest < content.len() && content[rest] == b' ' {
        rest += 1;
    }
    Some(EnumMatch { format, sequence, ordinal: ordinal_of(text, sequence), rel_start: rest, has_content: true })
}

/// docutils' `parse_enumerator` sequence resolution; `expected` (the open
/// list's `enumtype`) has priority, and the `i`/`I` special case applies only
/// without one.
fn resolve_sequence(text: &[u8], expected: Option<Sequence>) -> Option<Sequence> {
    if text == b"#" {
        return Some(Sequence::Auto);
    }
    match expected {
        Some(e) => {
            if e.accepts(text) {
                return Some(e);
            }
        }
        None => {
            if text == b"i" {
                return Some(Sequence::Lowerroman);
            }
            if text == b"I" {
                return Some(Sequence::Upperroman);
            }
        }
    }
    Sequence::ORDERED.into_iter().find(|s| s.accepts(text))
}

fn ordinal_of(text: &[u8], sequence: Sequence) -> Option<u32> {
    match sequence {
        Sequence::Auto => Some(1),
        Sequence::Arabic => super::doctree::parse_u32_zig(text),
        Sequence::Loweralpha => Some((text[0] - b'a' + 1) as u32),
        Sequence::Upperalpha => Some((text[0] - b'A' + 1) as u32),
        Sequence::Lowerroman | Sequence::Upperroman => from_roman(text),
    }
}

/// The enumerator that would carry `ordinal` in this sequence and format,
/// with docutils' trailing space. `None` for an ordinal the sequence cannot
/// spell.
fn make_enumerator(ordinal: u32, sequence: Sequence, format: Format) -> Option<Vec<u8>> {
    let body: Vec<u8> = match sequence {
        Sequence::Auto => b"#".to_vec(),
        Sequence::Arabic => ordinal.to_string().into_bytes(),
        Sequence::Loweralpha | Sequence::Upperalpha => {
            if ordinal == 0 || ordinal > 26 {
                return None;
            }
            let base = if sequence == Sequence::Loweralpha { b'a' } else { b'A' };
            vec![base + (ordinal - 1) as u8]
        }
        Sequence::Lowerroman | Sequence::Upperroman => {
            let mut roman = to_roman(ordinal)?;
            if sequence == Sequence::Lowerroman {
                roman.make_ascii_lowercase();
            }
            roman
        }
    };
    let (prefix, suffix) = format.info();
    let mut out = Vec::with_capacity(body.len() + 3);
    out.extend_from_slice(prefix.as_bytes());
    out.extend_from_slice(&body);
    out.extend_from_slice(suffix.as_bytes());
    out.push(b' ');
    Some(out)
}

const ROMAN_VALUES: [u32; 13] = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
const ROMAN_SYMBOLS: [&str; 13] = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"];

/// docutils' `roman.toRoman`, range 1..=4999.
fn to_roman(n: u32) -> Option<Vec<u8>> {
    if n == 0 || n > 4999 {
        return None;
    }
    let mut rem = n;
    let mut out = Vec::new();
    for (v, s) in ROMAN_VALUES.iter().zip(ROMAN_SYMBOLS) {
        while rem >= *v {
            out.extend_from_slice(s.as_bytes());
            rem -= v;
        }
    }
    Some(out)
}

/// docutils' `roman.fromRoman`, accepting only the CANONICAL spelling:
/// evaluate subtractively, then check `to_roman` writes it back the same way.
fn from_roman(text: &[u8]) -> Option<u32> {
    let mut total: i64 = 0;
    for (k, &c) in text.iter().enumerate() {
        let v = roman_digit(c)?;
        let next = if k + 1 < text.len() { roman_digit(text[k + 1])? } else { 0 };
        total += if v < next { -(v as i64) } else { v as i64 };
    }
    if !(1..=4999).contains(&total) {
        return None;
    }
    let n = total as u32;
    let canonical = to_roman(n)?;
    if canonical.len() != text.len() {
        return None;
    }
    for (a, b) in canonical.iter().zip(text) {
        if *a != b.to_ascii_uppercase() {
            return None;
        }
    }
    Some(n)
}

fn roman_digit(c: u8) -> Option<u32> {
    match c.to_ascii_uppercase() {
        b'I' => Some(1),
        b'V' => Some(5),
        b'X' => Some(10),
        b'L' => Some(50),
        b'C' => Some(100),
        b'D' => Some(500),
        b'M' => Some(1000),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Ast;

    fn p(src: &str) -> Ast {
        parse(src.as_bytes(), &Options::default()).document.ast
    }

    fn fc(ast: &Ast, id: NodeId) -> NodeId {
        ast.node(id).first_child.unwrap()
    }

    fn ns(ast: &Ast, id: NodeId) -> NodeId {
        ast.node(id).next_sibling.unwrap()
    }

    fn s(ast: &Ast, id: NodeId) -> &[u8] {
        ast.kind(id).str_text().unwrap()
    }

    fn cname(ast: &Ast, id: NodeId) -> &[u8] {
        &ast.kind(id).container().unwrap().name
    }

    fn attr<'x>(ast: &'x Ast, id: NodeId, key: &[u8]) -> Option<&'x [u8]> {
        ast.attrs_of(id).get(key)
    }

    #[test]
    fn a_single_paragraph() {
        let ast = p("Hello world.\n");
        assert_eq!(ast.kind(ast.root), &Kind::Doc);
        let para = fc(&ast, ast.root);
        assert_eq!(ast.kind(para), &Kind::Para);
        assert_eq!(s(&ast, fc(&ast, para)), b"Hello world.");
    }

    #[test]
    fn a_section_wraps_its_title_and_body() {
        let ast = p("Title\n=====\n\nBody.\n");
        let section = fc(&ast, ast.root);
        assert_eq!(ast.kind(section), &Kind::Section);
        assert_eq!(attr(&ast, section, b"ids"), Some(&b"title"[..]));
        assert_eq!(attr(&ast, section, b"names"), Some(&b"title"[..]));
        let title = fc(&ast, section);
        assert_eq!(cname(&ast, title), b"title");
        assert_eq!(ast.kind(ns(&ast, title)), &Kind::Para);
    }

    #[test]
    fn reused_adornment_style_nests_a_subsection_a_new_style_stays_deeper() {
        let ast = p("Section 1\n=========\n\nSection 2\n---------\nParagraph.\n");
        let sec1 = fc(&ast, ast.root);
        assert_eq!(ast.node(sec1).next_sibling, None);
        let title1 = fc(&ast, sec1);
        let sec2 = ns(&ast, title1);
        assert_eq!(ast.kind(sec2), &Kind::Section);
        assert_eq!(attr(&ast, sec2, b"ids"), Some(&b"section-2"[..]));
    }

    #[test]
    fn a_transition_needs_4_plus_adornment_characters() {
        let ast = p("Short.\n\n---\n\nPara.\n");
        let first = fc(&ast, ast.root);
        assert_eq!(ast.kind(ns(&ast, first)), &Kind::Para);
    }

    #[test]
    fn a_block_quote_dedents_to_the_runs_minimum_indent_nesting_deeper_runs() {
        let ast = p("Para.\n\n        Eight.\n\n    Four.\n");
        let para = fc(&ast, ast.root);
        let bq = ns(&ast, para);
        assert_eq!(ast.kind(bq), &Kind::BlockQuote);
        let nested = fc(&ast, bq);
        assert_eq!(ast.kind(nested), &Kind::BlockQuote);
        assert_eq!(ast.kind(ns(&ast, nested)), &Kind::Para);
    }

    #[test]
    fn a_comment_absorbs_its_indented_continuation() {
        let ast = p(".. A comment\n   block.\n\nPara.\n");
        let comment = fc(&ast, ast.root);
        assert_eq!(
            ast.kind(comment),
            &Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text: b"A comment\nblock.".to_vec() }
        );
    }

    #[test]
    fn a_bullet_list_item_merges_its_marker_line_with_its_unindented_continuation() {
        let ast = p("- item 1, line 1\n  item 1, line 2\n- item 2\n");
        let list = fc(&ast, ast.root);
        assert_eq!(ast.kind(list), &Kind::BulletList { tight: false });
        assert_eq!(attr(&ast, list, b"bullet"), Some(&b"-"[..]));
        let item1 = fc(&ast, list);
        let para1 = fc(&ast, item1);
        assert_eq!(s(&ast, fc(&ast, para1)), b"item 1, line 1\nitem 1, line 2");
        let item2 = ns(&ast, item1);
        assert_eq!(ast.node(item2).next_sibling, None);
    }

    #[test]
    fn an_empty_bullet_list_item_has_no_children_and_a_dedented_line_after_it_is_a_sibling() {
        let ast = p("-\n\nempty item above\n");
        let list = fc(&ast, ast.root);
        let item = fc(&ast, list);
        assert_eq!(ast.node(item).first_child, None);
        assert_eq!(ast.kind(ns(&ast, list)), &Kind::Para);
    }

    #[test]
    fn an_enumerated_list_records_enumtype_prefix_and_suffix() {
        let ast = p("(a) Item a.\n(b) Item b.\n");
        let list = fc(&ast, ast.root);
        assert_eq!(
            ast.kind(list),
            &Kind::OrderedList { numbering: ListNumbering::LowerAlpha, tight: false, start: None }
        );
        assert_eq!(attr(&ast, list, b"enumtype"), Some(&b"loweralpha"[..]));
        assert_eq!(attr(&ast, list, b"prefix"), Some(&b"("[..]));
        assert_eq!(attr(&ast, list, b"suffix"), Some(&b")"[..]));
        assert_eq!(attr(&ast, list, b"start"), None);
        let item = fc(&ast, list);
        assert_eq!(ast.node(ns(&ast, item)).next_sibling, None);
    }

    #[test]
    fn a_first_enumerator_that_is_not_ordinal_1_sets_start() {
        let ast = p("3. Item three.\n4. Item four.\n");
        let list = fc(&ast, ast.root);
        assert!(matches!(ast.kind(list), Kind::OrderedList { start: Some(3), .. }));
        assert_eq!(attr(&ast, list, b"start"), Some(&b"3"[..]));
    }

    #[test]
    fn a_bare_enumerator_over_an_unindented_line_is_a_paragraph_over_an_indented_one_a_list() {
        let ast = p("1.\nempty item above, no blank line\n");
        let first = fc(&ast, ast.root);
        assert_eq!(ast.kind(first), &Kind::Para);
        assert_eq!(s(&ast, fc(&ast, first)), b"1.\nempty item above, no blank line");

        let ast = p("1.\n foo\n");
        let list = fc(&ast, ast.root);
        assert_eq!(ast.kind(list).tag(), crate::ast::Tag::OrderedList);
        let item = fc(&ast, list);
        let para = fc(&ast, item);
        assert_eq!(s(&ast, fc(&ast, para)), b"foo");
    }

    #[test]
    fn an_ambiguous_alpha_roman_enumerator_splits_the_list_on_the_ordinal_not_the_letter() {
        let ast = p("A. Item A.\nB. Item B.\nC. Item C.\n\nI. Item I.\nII. Item II.\n");
        let alpha = fc(&ast, ast.root);
        assert!(matches!(ast.kind(alpha), Kind::OrderedList { numbering: ListNumbering::UpperAlpha, .. }));
        let roman = ns(&ast, alpha);
        assert!(matches!(ast.kind(roman), Kind::OrderedList { numbering: ListNumbering::UpperRoman, start: None, .. }));
    }

    #[test]
    fn hash_continues_whatever_list_it_lands_in_and_reports_that_lists_own_enumtype() {
        let ast = p("i. Item one.\nii. Item two.\n#. Item three.\n");
        let list = fc(&ast, ast.root);
        assert_eq!(attr(&ast, list, b"enumtype"), Some(&b"lowerroman"[..]));
        assert_eq!(ast.children(list).count(), 3);
    }

    #[test]
    fn a_malformed_roman_numeral_is_not_an_enumerator_at_all() {
        let ast = p("iiii. iiii\n\n(LCD) is an acronym\n");
        let first = fc(&ast, ast.root);
        assert_eq!(ast.kind(first), &Kind::Para);
        assert_eq!(ast.kind(ns(&ast, first)), &Kind::Para);
    }

    #[test]
    fn a_different_enumerator_format_ends_the_list() {
        let ast = p("1. Item 1.\n\n1) Item 1).\n");
        let first = fc(&ast, ast.root);
        assert_eq!(attr(&ast, first, b"suffix"), Some(&b"."[..]));
        let second = ns(&ast, first);
        assert_eq!(ast.kind(second).tag(), crate::ast::Tag::OrderedList);
        assert_eq!(attr(&ast, second, b"suffix"), Some(&b")"[..]));
    }

    #[test]
    fn a_term_over_an_indented_line_makes_a_definition_list_and_a_nested_one_nests() {
        let ast = p("term 1\n  definition 1\n\n  term 1a\n    definition 1a\n\nterm 2\n  definition 2\n");
        let list = fc(&ast, ast.root);
        assert_eq!(ast.kind(list), &Kind::DefinitionList);
        let item1 = fc(&ast, list);
        let term1 = fc(&ast, item1);
        assert_eq!(ast.kind(term1), &Kind::Term);
        assert_eq!(s(&ast, fc(&ast, term1)), b"term 1");
        let def1 = ns(&ast, term1);
        assert_eq!(ast.kind(def1), &Kind::Definition);
        let nested = ns(&ast, fc(&ast, def1));
        assert_eq!(ast.kind(nested), &Kind::DefinitionList);
        let item2 = ns(&ast, item1);
        assert_eq!(ast.kind(item2), &Kind::DefinitionListItem);
        assert_eq!(ast.node(item2).next_sibling, None);
    }

    #[test]
    fn items_with_no_blank_line_between_them_stay_one_definition_list() {
        let ast = p("term 1\n  definition 1\nterm 2\n  definition 2\n");
        let list = fc(&ast, ast.root);
        assert_eq!(ast.node(list).next_sibling, None);
        assert!(ast.node(fc(&ast, list)).next_sibling.is_some());
    }

    #[test]
    fn colon_splits_a_term_into_classifiers_only_with_a_space_on_both_sides() {
        let ast = p(
            "Term : one : two\n    definition\nTerm: not a classifier\n    definition\nTerm :not a classifier\n    definition\n",
        );
        let list = fc(&ast, ast.root);
        let item1 = fc(&ast, list);
        let term = fc(&ast, item1);
        assert_eq!(s(&ast, fc(&ast, term)), b"Term");
        let c1 = ns(&ast, term);
        assert_eq!(cname(&ast, c1), b"classifier");
        assert_eq!(s(&ast, fc(&ast, c1)), b"one");
        let c2 = ns(&ast, c1);
        assert_eq!(s(&ast, fc(&ast, c2)), b"two");
        assert_eq!(ast.kind(ns(&ast, c2)), &Kind::Definition);

        let item2 = ns(&ast, item1);
        let item3 = ns(&ast, item2);
        for (item, want) in [(item2, &b"Term: not a classifier"[..]), (item3, &b"Term :not a classifier"[..])] {
            let t = fc(&ast, item);
            assert_eq!(ast.kind(ns(&ast, t)), &Kind::Definition);
            assert_eq!(s(&ast, fc(&ast, t)), want);
        }
    }

    #[test]
    fn an_escaped_colon_does_not_split_a_term() {
        let ast = p("Term \\: not a classifier\n    definition\n");
        let item = fc(&ast, fc(&ast, ast.root));
        let term = fc(&ast, item);
        assert_eq!(ast.kind(ns(&ast, term)), &Kind::Definition);
        assert_eq!(s(&ast, fc(&ast, term)), b"Term \\: not a classifier");
    }

    #[test]
    fn a_field_list_keeps_all_four_docutils_elements_as_generic_containers() {
        let ast = p(":Author: Me\n:Version: 1\n");
        let list = fc(&ast, ast.root);
        assert_eq!(cname(&ast, list), b"field_list");
        let field = fc(&ast, list);
        assert_eq!(cname(&ast, field), b"field");
        let name = fc(&ast, field);
        assert_eq!(cname(&ast, name), b"field_name");
        assert_eq!(s(&ast, fc(&ast, name)), b"Author");
        let body = ns(&ast, name);
        assert_eq!(cname(&ast, body), b"field_body");
        assert_eq!(ast.kind(fc(&ast, body)), &Kind::Para);
        assert_eq!(ast.node(ns(&ast, field)).next_sibling, None);
    }

    #[test]
    fn a_field_body_takes_its_column_from_the_continuation_lines_not_the_marker() {
        let ast = p(":Authors: Me,\n  Myself\n");
        let body = ns(&ast, fc(&ast, fc(&ast, fc(&ast, ast.root))));
        let para = fc(&ast, body);
        assert_eq!(s(&ast, fc(&ast, para)), b"Me,\nMyself");
        assert_eq!(ast.node(para).next_sibling, None);
    }

    #[test]
    fn a_field_body_may_start_on_the_line_below_its_marker() {
        let ast = p(":Author:\n  Me\n");
        let field = fc(&ast, fc(&ast, ast.root));
        let body = ns(&ast, fc(&ast, field));
        let para = fc(&ast, body);
        assert_eq!(s(&ast, fc(&ast, para)), b"Me");
    }

    #[test]
    fn field_names_admit_embedded_colons_but_not_a_colon_before_a_backtick() {
        assert_eq!(match_field_marker(b":field:name:with:colons: body").unwrap().name, b"field:name:with:colons");
        assert_eq!(match_field_marker(b":field::name: double colons").unwrap().name, b"field::name");
        assert_eq!(match_field_marker(b":Parameter i j k: multiple").unwrap().name, b"Parameter i j k");
        assert!(!match_field_marker(b":Author:").unwrap().has_content);
        assert_eq!(match_field_marker(b":code:`not a field name`: text"), None);
        assert_eq!(match_field_marker(b"::code:`x`: text"), None);
        assert_eq!(match_field_marker(b":name : body"), None);
        assert_eq!(match_field_marker(b":field\\:name: body").unwrap().name, b"field\\:name");
    }

    #[test]
    fn a_bullet_beats_a_term_at_the_same_column() {
        let ast = p("- foo\n  bar\n");
        assert_eq!(ast.kind(fc(&ast, ast.root)), &Kind::BulletList { tight: false });
    }

    #[test]
    fn roman_numerals_accept_only_their_canonical_spelling() {
        assert_eq!(from_roman(b"I"), Some(1));
        assert_eq!(from_roman(b"iii"), Some(3));
        assert_eq!(from_roman(b"IV"), Some(4));
        assert_eq!(from_roman(b"MCMXC"), Some(1990));
        assert_eq!(from_roman(b"iiii"), None);
        assert_eq!(from_roman(b"LCD"), None);
        assert_eq!(from_roman(b"CIVIL"), None);
        assert_eq!(from_roman(b"IVXLCDM"), None);
        assert_eq!(from_roman(b""), None);
    }

    #[test]
    fn a_different_bullet_character_at_the_same_column_starts_a_new_list() {
        let ast = p("- item 1\n\n+ item 1\n");
        let first = fc(&ast, ast.root);
        assert_eq!(attr(&ast, first, b"bullet"), Some(&b"-"[..]));
        let second = ns(&ast, first);
        assert_eq!(ast.kind(second), &Kind::BulletList { tight: false });
        assert_eq!(attr(&ast, second, b"bullet"), Some(&b"+"[..]));
        assert_eq!(ast.node(second).next_sibling, None);
    }
}
