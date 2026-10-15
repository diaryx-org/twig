//! Block-level scanner: a line-oriented state machine over an explicit stack
//! of open containers, producing a flat `Vec<Event>`. Ported from djot.js's
//! `src/block.ts` (`EventParser`).
//!
//! Each djot.js `BlockSpec` (`continue`/`open`/`close` closures) becomes a
//! named `continue_x`/`open_x`/`close_x` method dispatched through an
//! exhaustive `match` on `BlockKind`.

use super::attributes::{AttributeParser, Status};
use super::event::{Annotation, Delim, Event, EventList, ListMarkerStyle, ListStyleCandidates, Numbering};
use super::inline::InlineParser;

fn is_space_or_tab(c: u8) -> bool {
    c == b' ' || c == b'\t'
}
fn is_eol(c: u8) -> bool {
    c == b'\n' || c == b'\r'
}
fn is_ws_any(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}
fn is_roman_lower(c: u8) -> bool {
    matches!(c, b'i' | b'v' | b'x' | b'l' | b'c' | b'd' | b'm')
}
fn is_roman_upper(c: u8) -> bool {
    matches!(c, b'I' | b'V' | b'X' | b'L' | b'C' | b'D' | b'M')
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContentType {
    None,
    Inline,
    Block,
    Text,
    Cells,
    Attributes,
    ListItem,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockKind {
    BlockQuote,
    Heading,
    Caption,
    Footnote,
    ReferenceDefinition,
    ThematicBreak,
    List,
    ListItem,
    Table,
    Attributes,
    FencedDiv,
    CodeBlock,
    Para,
}

#[derive(Clone, Copy, Debug, Default)]
struct Slice {
    start: usize,
    end: usize,
}

/// Scratch state for whichever `BlockKind` is open (only the fields relevant
/// to the open container's kind are used).
struct Extra<'s> {
    level: u32,
    indent: usize,
    styles: ListStyleCandidates,
    attr_parser: Option<AttributeParser<'s>>,
    attr_status: Status,
    attr_startpos: usize,
    /// Position of the closing `}`, once the attribute parser has reported
    /// `Done`. `attr_startpos` doubles as "no end yet".
    attr_endpos: usize,
    attr_slices: Vec<Slice>,
    colons: usize,
    end_fence: Option<Slice>,
    fence_char: u8,
    fence_len: usize,
}

impl Default for Extra<'_> {
    fn default() -> Self {
        Extra {
            level: 0,
            indent: 0,
            styles: ListStyleCandidates::default(),
            attr_parser: None,
            attr_status: Status::Continue,
            attr_startpos: 0,
            attr_endpos: 0,
            attr_slices: Vec::new(),
            colons: 0,
            end_fence: None,
            fence_char: b'`',
            fence_len: 0,
        }
    }
}

struct Container<'s> {
    kind: BlockKind,
    /// What type of container THIS is (for parent-content matching).
    ctype: ContentType,
    /// What content type this container HOLDS.
    content: ContentType,
    indent: usize,
    inline_parser: Option<InlineParser<'s>>,
    extra: Extra<'s>,
}

impl<'s> Container<'s> {
    fn new(kind: BlockKind, ctype: ContentType, content: ContentType) -> Self {
        Container { kind, ctype, content, indent: 0, inline_parser: None, extra: Extra::default() }
    }
    fn with_extra(kind: BlockKind, ctype: ContentType, content: ContentType, extra: Extra<'s>) -> Self {
        Container { kind, ctype, content, indent: 0, inline_parser: None, extra }
    }
}

const SPEC_ORDER: [BlockKind; 12] = [
    BlockKind::BlockQuote,
    BlockKind::Heading,
    BlockKind::Caption,
    BlockKind::Footnote,
    BlockKind::ReferenceDefinition,
    BlockKind::ThematicBreak,
    BlockKind::List,
    BlockKind::ListItem,
    BlockKind::Table,
    BlockKind::Attributes,
    BlockKind::FencedDiv,
    BlockKind::CodeBlock,
];

fn spec_ctype(kind: BlockKind) -> ContentType {
    match kind {
        BlockKind::ListItem => ContentType::ListItem,
        _ => ContentType::Block,
    }
}

/// Matches djot.js's `getListStyles`. `marker` is the exact matched marker
/// text (parens/delimiters included, no surrounding whitespace).
pub fn get_list_styles(marker: &[u8]) -> ListStyleCandidates {
    use ListMarkerStyle as S;
    if marker.len() == 1 {
        match marker[0] {
            b'-' => return ListStyleCandidates::single(S::Dash),
            b'+' => return ListStyleCandidates::single(S::Plus),
            b'*' => return ListStyleCandidates::single(S::Star),
            b':' => return ListStyleCandidates::single(S::Colon),
            _ => {}
        }
    }
    if marker.len() == 5
        && matches!(marker[0], b'+' | b'*' | b'-')
        && marker[1] == b' '
        && marker[2] == b'['
        && matches!(marker[3], b'X' | b'x' | b' ')
        && marker[4] == b']'
    {
        return ListStyleCandidates::single(match marker[0] {
            b'+' => S::PlusTask,
            b'-' => S::DashTask,
            _ => S::StarTask,
        });
    }
    let mut s = marker;
    let mut has_paren = false;
    if !s.is_empty() && s[0] == b'(' {
        has_paren = true;
        s = &s[1..];
    }
    if s.is_empty() {
        return ListStyleCandidates::default();
    }
    let delim = s[s.len() - 1];
    if !(delim == b'.' || delim == b')') {
        return ListStyleCandidates::default();
    }
    let inner = &s[..s.len() - 1];
    if inner.is_empty() {
        return ListStyleCandidates::default();
    }
    let dk = if has_paren {
        Delim::ParenBoth
    } else if delim == b')' {
        Delim::ParenAfter
    } else {
        Delim::Period
    };
    let ord = |numbering: Numbering| S::Ordered { numbering, delim: dk };

    if inner.iter().all(|c| c.is_ascii_digit()) {
        return ListStyleCandidates::single(ord(Numbering::Decimal));
    }
    if inner.len() == 1 && is_roman_lower(inner[0]) {
        return ListStyleCandidates::two(ord(Numbering::LowerRoman), ord(Numbering::LowerAlpha));
    }
    if inner.len() == 1 && is_roman_upper(inner[0]) {
        return ListStyleCandidates::two(ord(Numbering::UpperRoman), ord(Numbering::UpperAlpha));
    }
    if inner.iter().all(|&c| is_roman_lower(c)) {
        return ListStyleCandidates::single(ord(Numbering::LowerRoman));
    }
    if inner.iter().all(|&c| is_roman_upper(c)) {
        return ListStyleCandidates::single(ord(Numbering::UpperRoman));
    }
    if inner.len() == 1 && inner[0].is_ascii_lowercase() {
        return ListStyleCandidates::single(ord(Numbering::LowerAlpha));
    }
    if inner.len() == 1 && inner[0].is_ascii_uppercase() {
        return ListStyleCandidates::single(ord(Numbering::UpperAlpha));
    }
    ListStyleCandidates::default()
}

fn is_marker_class_char(c: u8) -> bool {
    c == b'-' || c == b'*' || c == b'+' || c == b':'
}

struct MarkerStyles {
    marker: Slice,
    styles: ListStyleCandidates,
    checkbox: Option<bool>,
}

struct RowSep {
    end: usize,
    left: bool,
    right: bool,
}

struct CodeFence {
    border: Slice,
    lang: Slice,
    is_raw: bool,
    line_end: usize,
}

struct Cell {
    start: usize,
    end: usize,
    matches: Vec<Event>,
}

pub struct Parser<'s> {
    pub subject: &'s [u8],
    maxoffset: usize,
    indent: usize,
    startline: usize,
    starteol: usize,
    endeol: usize,
    matches: EventList,
    containers: Vec<Container<'s>>,
    pos: usize,
    last_matched_container: isize,
    finished_line: bool,
    /// One past the last byte of the most recent line that carried content.
    /// Closers that have no syntax of their own to end at end here instead.
    content_end: usize,
}

impl<'s> Parser<'s> {
    /// `subject` MUST end with `\n` (the caller appends one, matching djot.js's
    /// constructor; see `super::parse`).
    pub fn new(subject: &'s [u8]) -> Self {
        debug_assert!(subject.last() == Some(&b'\n'));
        Parser {
            subject,
            maxoffset: subject.len() - 1,
            indent: 0,
            startline: 0,
            starteol: 0,
            endeol: 0,
            matches: Vec::new(),
            containers: Vec::new(),
            pos: 0,
            last_matched_container: -1,
            finished_line: false,
            content_end: 0,
        }
    }

    fn add_match(&mut self, start: usize, end: usize, annot: Annotation) {
        self.matches.push(Event::new(start.min(self.maxoffset) as u32, end.min(self.maxoffset) as u32, annot));
    }

    fn add_match_styled(&mut self, start: usize, end: usize, annot: Annotation, styles: ListStyleCandidates) {
        let mut e = Event::new(start.min(self.maxoffset) as u32, end.min(self.maxoffset) as u32, annot);
        e.list_styles = styles;
        self.matches.push(e);
    }

    fn tip(&self) -> Option<&Container<'s>> {
        self.containers.last()
    }

    // ── low-level scanning helpers ──

    fn skip_space(&mut self) {
        let mut newpos = self.pos;
        while newpos < self.subject.len() && is_space_or_tab(self.subject[newpos]) {
            newpos += 1;
        }
        self.indent = newpos - self.startline;
        self.pos = newpos;
    }

    fn get_eol(&mut self) {
        let mut i = self.pos;
        let s = self.subject;
        while i < s.len() && !is_eol(s[i]) {
            i += 1;
        }
        self.starteol = i;
        if i < s.len() && s[i] == b'\r' && i + 1 < s.len() && s[i + 1] == b'\n' {
            self.endeol = i + 1;
        } else {
            self.endeol = i;
        }
    }

    fn byte_at(&self, pos: usize) -> u8 {
        if pos < self.subject.len() { self.subject[pos] } else { 0 }
    }

    /// Nothing but spaces and tabs between `startline` and the newline.
    fn line_is_blank(&self) -> bool {
        (self.startline..self.starteol).all(|i| is_space_or_tab(self.subject[i]))
    }

    /// The inclusive `end` a block-level closer should report.
    fn content_end_match(&self) -> usize {
        self.content_end.saturating_sub(1)
    }

    // ── generic container push/close machinery ──

    fn close_container(&mut self) {
        // Pop first, so closers that need `self.tip()` see the PARENT.
        let mut c = self.containers.pop().unwrap();
        match c.kind {
            BlockKind::BlockQuote => self.close_simple(Annotation::BlockQuoteClose),
            BlockKind::Heading => self.close_inline_container(&mut c, Annotation::HeadingClose),
            BlockKind::Caption => {
                self.get_inline_matches_for(&mut c);
                self.close_simple(Annotation::CaptionClose);
            }
            BlockKind::Footnote => self.close_simple(Annotation::FootnoteClose),
            BlockKind::ReferenceDefinition => self.close_simple(Annotation::ReferenceDefinitionClose),
            BlockKind::ThematicBreak => {}
            BlockKind::List => self.close_simple(Annotation::ListClose),
            BlockKind::ListItem => self.close_simple(Annotation::ListItemClose),
            BlockKind::Table => self.close_simple(Annotation::TableClose),
            BlockKind::Attributes => self.close_attributes(&mut c),
            BlockKind::FencedDiv => self.close_fenced(&c, Annotation::DivClose),
            BlockKind::CodeBlock => self.close_fenced(&c, Annotation::CodeBlockClose),
            BlockKind::Para => self.close_inline_container(&mut c, Annotation::ParaClose),
        }
    }

    fn close_simple(&mut self, annot: Annotation) {
        let ep = self.content_end_match();
        self.add_match(ep, ep, annot);
    }

    fn close_inline_container(&mut self, c: &mut Container<'s>, annot: Annotation) {
        self.get_inline_matches_for(c);
        let ep = match self.matches.last() {
            Some(m) => m.end as usize + 1,
            None => self.pos,
        };
        self.add_match(ep, ep, annot);
    }

    /// Unterminated: the div/code block ends at its last content line.
    fn close_fenced(&mut self, c: &Container<'s>, annot: Annotation) {
        let (sp, ep) = match c.extra.end_fence {
            Some(f) => (f.start, f.end),
            None => (self.content_end_match(), self.content_end_match()),
        };
        self.add_match(sp, ep, annot);
    }

    fn close_unmatched_containers(&mut self) {
        let last_matched = self.last_matched_container;
        while !self.containers.is_empty() && self.containers.len() as isize - 1 > last_matched {
            self.close_container();
        }
    }

    /// Push `container`, first closing any containers it can't nest inside.
    fn add_container(&mut self, container: Container<'s>, skip_close_unmatched: bool) {
        if !skip_close_unmatched {
            self.close_unmatched_containers();
        }
        while let Some(t) = self.tip() {
            if t.content == container.ctype {
                break;
            }
            self.close_container();
        }
        let mut c = container;
        if c.content == ContentType::Inline {
            c.inline_parser = Some(InlineParser::new(self.subject));
        }
        self.containers.push(c);
    }

    // ── entry point ──

    /// Run the scanner to completion, returning the whole event stream.
    pub fn scan(mut self) -> Vec<Event> {
        let subjectlen = self.subject.len();
        while self.pos < subjectlen {
            self.indent = 0;
            self.startline = self.pos;
            self.finished_line = false;
            self.get_eol();

            // Match open containers against the current line, top-down.
            self.last_matched_container = -1;
            let mut idx = 0;
            while idx < self.containers.len() {
                self.skip_space();
                if self.continue_container(idx) {
                    self.last_matched_container = idx as isize;
                } else {
                    break;
                }
                idx += 1;
            }

            if self.finished_line {
                while !self.containers.is_empty()
                    && self.last_matched_container < self.containers.len() as isize - 1
                {
                    self.close_container();
                }
            }

            if !self.finished_line {
                self.skip_space();
                let mut is_blank = self.pos == self.starteol;
                let mut new_starts = false;
                let mut last_match_idx: Option<usize> =
                    if self.last_matched_container >= 0 { Some(self.last_matched_container as usize) } else { None };

                let mut check_starts = !is_blank
                    && match last_match_idx {
                        None => true,
                        Some(i) => matches!(self.containers[i].content, ContentType::Block | ContentType::ListItem),
                    };
                while check_starts {
                    check_starts = false;
                    for kind in SPEC_ORDER {
                        let sc = spec_ctype(kind);
                        let applies = match last_match_idx {
                            None => sc == ContentType::Block,
                            Some(i) => self.containers[i].content == sc,
                        };
                        if applies && self.open_spec(kind) {
                            if !self.containers.is_empty() {
                                self.last_matched_container = self.containers.len() as isize - 1;
                                last_match_idx = Some(self.containers.len() - 1);
                                if self.finished_line {
                                    check_starts = false;
                                } else {
                                    self.skip_space();
                                    new_starts = true;
                                    let c = self.tip().unwrap().content;
                                    check_starts = c == ContentType::Block || c == ContentType::ListItem;
                                }
                            }
                            break;
                        }
                    }
                }

                if !self.finished_line {
                    self.skip_space();
                    is_blank = self.pos == self.starteol;
                    let is_lazy = !is_blank
                        && !new_starts
                        && self.last_matched_container < self.containers.len() as isize - 1
                        && self.tip().is_some_and(|t| t.content == ContentType::Inline);

                    if !is_lazy {
                        self.close_unmatched_containers();
                    }

                    if self.tip().is_none_or(|t| t.content == ContentType::Block) {
                        if is_blank {
                            if !new_starts {
                                self.add_match(self.pos, self.endeol, Annotation::Blankline);
                            }
                        } else {
                            self.open_para();
                        }
                    }

                    let tip_content = self.tip().map(|t| (t.content, t.indent));
                    if let Some((ContentType::Text, tindent)) = tip_content {
                        let mut startpos = self.pos;
                        if self.indent > tindent {
                            startpos -= self.indent - tindent;
                        }
                        self.add_match(startpos, self.endeol, Annotation::Str);
                    } else if let Some((ContentType::Inline, _)) = tip_content {
                        if !is_blank {
                            let (pos, endeol) = (self.pos, self.endeol);
                            if let Some(ip) = self.containers.last_mut().unwrap().inline_parser.as_mut() {
                                ip.feed(pos, endeol);
                            }
                        }
                    }
                }
            }

            // A blank line at block level is a separator and belongs to
            // neither side of it. Every other line — including a blank line
            // inside a code block — extends the content the open containers own.
            let line_has_content = !self.line_is_blank() || self.tip().is_some_and(|t| t.content == ContentType::Text);
            self.pos = (if self.endeol > 0 || self.pos == 0 { self.endeol } else { self.pos }) + 1;
            if line_has_content {
                self.content_end = self.pos.min(self.subject.len());
            }
        }

        self.last_matched_container = -1;
        self.close_unmatched_containers();
        self.matches
    }

    // ── spec dispatch ──

    fn continue_container(&mut self, idx: usize) -> bool {
        match self.containers[idx].kind {
            BlockKind::BlockQuote => self.continue_block_quote(),
            BlockKind::Heading => self.continue_heading(idx),
            BlockKind::Caption => self.continue_caption(),
            BlockKind::Footnote | BlockKind::ListItem => self.continue_indented(idx),
            BlockKind::ReferenceDefinition => self.continue_reference_definition(idx),
            BlockKind::ThematicBreak => false,
            BlockKind::List => self.continue_list(idx),
            BlockKind::Table => self.continue_table(),
            BlockKind::Attributes => self.continue_attributes(idx),
            BlockKind::FencedDiv => self.continue_fenced_div(idx),
            BlockKind::CodeBlock => self.continue_code_block(idx),
            BlockKind::Para => self.continue_para_spec(),
        }
    }

    fn open_spec(&mut self, kind: BlockKind) -> bool {
        match kind {
            BlockKind::BlockQuote => self.open_block_quote(),
            BlockKind::Heading => self.open_heading(),
            BlockKind::Caption => self.open_caption(),
            BlockKind::Footnote => self.open_footnote(),
            BlockKind::ReferenceDefinition => self.open_reference_definition(),
            BlockKind::ThematicBreak => self.open_thematic_break(),
            BlockKind::List => self.open_list(),
            BlockKind::ListItem => self.open_list_item(),
            BlockKind::Table => self.open_table(),
            BlockKind::Attributes => self.open_attributes(),
            BlockKind::FencedDiv => self.open_fenced_div(),
            BlockKind::CodeBlock => self.open_code_block(),
            BlockKind::Para => {
                self.open_para();
                true
            }
        }
    }

    // ── para ──

    fn continue_para_spec(&self) -> bool {
        !(self.pos < self.subject.len() && is_ws_any(self.subject[self.pos]))
    }

    fn open_para(&mut self) {
        self.add_container(Container::new(BlockKind::Para, ContentType::Block, ContentType::Inline), false);
        self.add_match(self.pos, self.pos, Annotation::ParaOpen);
    }

    /// Drain the popped container's inline matches into `self.matches`,
    /// merging adjacent `str` runs.
    fn get_inline_matches_for(&mut self, c: &mut Container<'s>) {
        if let Some(ip) = c.inline_parser.as_mut() {
            let evs = ip.finish_matches();
            for m in evs {
                if let Some(last) = self.matches.last_mut() {
                    if last.annot == Annotation::Str && m.annot == Annotation::Str && m.start == last.end + 1 {
                        last.end = m.end;
                        continue;
                    }
                }
                self.matches.push(*m);
            }
        }
    }

    // ── block_quote ──

    /// `[>][ \t\r\n]`
    fn has_blockquote_prefix(&self) -> bool {
        self.pos < self.subject.len()
            && self.subject[self.pos] == b'>'
            && self.pos + 1 < self.subject.len()
            && is_ws_any(self.subject[self.pos + 1])
    }

    fn continue_block_quote(&mut self) -> bool {
        if self.has_blockquote_prefix() {
            self.pos += 1;
            return true;
        }
        false
    }

    fn open_block_quote(&mut self) -> bool {
        if self.has_blockquote_prefix() {
            self.add_container(Container::new(BlockKind::BlockQuote, ContentType::Block, ContentType::Block), false);
            self.add_match(self.pos, self.pos, Annotation::BlockQuoteOpen);
            self.pos += 1;
            return true;
        }
        false
    }

    // ── heading ──

    fn match_bangs(&self, pos: usize) -> Option<usize> {
        let mut p = pos;
        while p < self.subject.len() && self.subject[p] == b'#' {
            p += 1;
        }
        if p > pos { Some(p) } else { None }
    }

    fn continue_heading(&mut self, idx: usize) -> bool {
        let level = self.containers[idx].extra.level as usize;
        if let Some(endp) = self.match_bangs(self.pos) {
            if endp - self.pos == level && endp < self.subject.len() && is_ws_any(self.byte_at(endp)) {
                self.pos = endp;
                return true;
            }
        }
        false
    }

    fn open_heading(&mut self) -> bool {
        if let Some(endp) = self.match_bangs(self.pos) {
            if endp < self.subject.len() && is_ws_any(self.byte_at(endp)) {
                let level = (endp - self.pos) as u32;
                let extra = Extra { level, ..Default::default() };
                self.add_container(
                    Container::with_extra(BlockKind::Heading, ContentType::Block, ContentType::Inline, extra),
                    false,
                );
                self.add_match(self.pos, endp - 1, Annotation::HeadingOpen);
                self.pos = endp;
                return true;
            }
        }
        false
    }

    // ── caption ──

    fn continue_caption(&self) -> bool {
        self.pos < self.subject.len() && !is_ws_any(self.subject[self.pos])
    }

    fn open_caption(&mut self) -> bool {
        // "^" [ \t]+
        if self.pos < self.subject.len() && self.subject[self.pos] == b'^' {
            let mut p = self.pos + 1;
            let start = p;
            while p < self.subject.len() && is_space_or_tab(self.subject[p]) {
                p += 1;
            }
            if p > start {
                self.pos = p;
                self.add_container(Container::new(BlockKind::Caption, ContentType::Block, ContentType::Inline), false);
                self.add_match(self.pos, self.pos, Annotation::CaptionOpen);
                return true;
            }
        }
        false
    }

    // ── footnote ──

    /// `\[\^([^\]\r\n]*)\]:[ \t\r\n]` — returns (end, label).
    fn match_footnote_start(&self, pos: usize) -> Option<(usize, Slice)> {
        let mut p = pos;
        if self.byte_at(p) != b'[' {
            return None;
        }
        p += 1;
        if self.byte_at(p) != b'^' {
            return None;
        }
        p += 1;
        let label_start = p;
        let s = self.subject;
        while p < s.len() && s[p] != b']' && s[p] != b'\r' && s[p] != b'\n' {
            p += 1;
        }
        let label_end = p;
        if self.byte_at(p) != b']' {
            return None;
        }
        p += 1;
        if self.byte_at(p) != b':' {
            return None;
        }
        p += 1;
        if !is_ws_any(self.byte_at(p)) {
            return None;
        }
        Some((p, Slice { start: label_start, end: label_end }))
    }

    /// footnote / list_item continuation: more indented, or a blank line.
    fn continue_indented(&self, idx: usize) -> bool {
        self.indent > self.containers[idx].extra.indent || self.pos == self.starteol
    }

    fn open_footnote(&mut self) -> bool {
        if let Some((end, label)) = self.match_footnote_start(self.pos) {
            let sp = self.pos;
            let extra = Extra { indent: self.indent, ..Default::default() };
            self.add_container(
                Container::with_extra(BlockKind::Footnote, ContentType::Block, ContentType::Block, extra),
                false,
            );
            self.add_match(sp, sp, Annotation::FootnoteOpen);
            self.add_match(label.start, label.end.saturating_sub(1), Annotation::NoteLabel);
            self.pos = end;
            return true;
        }
        false
    }

    // ── reference_definition ──

    /// `\[([^\]\r\n]*)\]:([ \t]+[^ \t\r\n]*|)[\r\n]` — returns (end, label, value).
    fn match_reference_definition(&self, pos: usize) -> Option<(usize, Slice, Slice)> {
        let s = self.subject;
        let mut p = pos;
        if self.byte_at(p) != b'[' {
            return None;
        }
        p += 1;
        let label_start = p;
        while p < s.len() && s[p] != b']' && s[p] != b'\r' && s[p] != b'\n' {
            p += 1;
        }
        let label_end = p;
        if self.byte_at(p) != b']' {
            return None;
        }
        p += 1;
        if self.byte_at(p) != b':' {
            return None;
        }
        p += 1;
        let mut value_start = p;
        let mut value_end = p;
        if is_space_or_tab(self.byte_at(p)) {
            let mut q = p;
            while q < s.len() && is_space_or_tab(s[q]) {
                q += 1;
            }
            value_start = q;
            let mut r = q;
            while r < s.len() && !is_ws_any(s[r]) {
                r += 1;
            }
            value_end = r;
            p = r;
        }
        if !(self.byte_at(p) == b'\r' || self.byte_at(p) == b'\n') {
            return None;
        }
        Some((p, Slice { start: label_start, end: label_end }, Slice { start: value_start, end: value_end }))
    }

    fn continue_reference_definition(&mut self, idx: usize) -> bool {
        if self.containers[idx].extra.indent >= self.indent {
            return false;
        }
        if self.pos >= self.subject.len() || is_ws_any(self.subject[self.pos]) {
            return false;
        }
        let mut p = self.pos;
        while p < self.subject.len() && !is_ws_any(self.subject[p]) {
            p += 1;
        }
        if self.pos < self.starteol && p == self.starteol {
            self.add_match(self.pos, self.starteol.saturating_sub(1), Annotation::ReferenceValue);
            self.pos = self.starteol;
            return true;
        }
        false
    }

    fn open_reference_definition(&mut self) -> bool {
        if let Some((_end, label, value)) = self.match_reference_definition(self.pos) {
            let sp = self.pos;
            let extra = Extra { indent: self.indent, ..Default::default() };
            self.add_container(
                Container::with_extra(BlockKind::ReferenceDefinition, ContentType::Block, ContentType::None, extra),
                false,
            );
            self.add_match(sp, sp, Annotation::ReferenceDefinitionOpen);
            self.add_match(sp, sp + (label.end - label.start) + 1, Annotation::ReferenceKey);
            if value.end > value.start {
                self.add_match(
                    self.starteol - (value.end - value.start),
                    self.starteol.saturating_sub(1),
                    Annotation::ReferenceValue,
                );
            }
            self.pos = self.starteol.saturating_sub(1);
            return true;
        }
        false
    }

    // ── thematic_break ──

    /// `[-*][ \t]*[-*][ \t]*[-*][-* \t]*\r?\n` — returns the `\n` position.
    fn match_thematic_break(&self, pos: usize) -> Option<usize> {
        let mut p = pos;
        for _ in 0..3 {
            if !(self.byte_at(p) == b'-' || self.byte_at(p) == b'*') {
                return None;
            }
            p += 1;
            while is_space_or_tab(self.byte_at(p)) {
                p += 1;
            }
        }
        while self.byte_at(p) == b'-' || self.byte_at(p) == b'*' || is_space_or_tab(self.byte_at(p)) {
            p += 1;
        }
        if self.byte_at(p) == b'\r' {
            p += 1;
        }
        if self.byte_at(p) != b'\n' {
            return None;
        }
        Some(p)
    }

    fn open_thematic_break(&mut self) -> bool {
        if let Some(endp) = self.match_thematic_break(self.pos) {
            self.add_container(Container::new(BlockKind::ThematicBreak, ContentType::Block, ContentType::None), false);
            self.add_match(self.pos, endp, Annotation::ThematicBreak);
            self.pos = endp;
            return true;
        }
        false
    }

    // ── list / list_item ──

    /// The full `pattListMarker` alternation, INCLUDING the required trailing
    /// whitespace character. Returns the marker's `[start,end)`.
    fn match_list_marker(&self, pos: usize) -> Option<Slice> {
        let s = self.subject;
        if pos >= s.len() {
            return None;
        }
        let mut len: Option<usize> = None;

        if is_marker_class_char(s[pos]) {
            if s[pos] == b':' && pos + 1 < s.len() && is_marker_class_char(s[pos + 1]) {
                len = Some(2);
            } else {
                len = Some(1);
            }
        }

        if len.is_none() && s[pos] == b'(' {
            let mut p = pos + 1;
            let digit_start = p;
            while p < s.len() && s[p].is_ascii_digit() {
                p += 1;
            }
            if p > digit_start && p < s.len() && s[p] == b')' {
                len = Some(p + 1 - pos);
            } else {
                p = pos + 1;
                let alpha_start = p;
                while p < s.len() && s[p].is_ascii_alphabetic() {
                    p += 1;
                }
                if p > alpha_start && p < s.len() && s[p] == b')' {
                    len = Some(p + 1 - pos);
                }
            }
        }

        if len.is_none() && s[pos].is_ascii_digit() {
            let mut p = pos;
            while p < s.len() && s[p].is_ascii_digit() {
                p += 1;
            }
            if p < s.len() && (s[p] == b'.' || s[p] == b')') {
                len = Some(p + 1 - pos);
            }
        }

        if len.is_none() && s[pos].is_ascii_alphabetic() {
            let mut p = pos;
            while p < s.len() && s[p].is_ascii_alphabetic() {
                p += 1;
            }
            if p < s.len() && (s[p] == b'.' || s[p] == b')') {
                len = Some(p + 1 - pos);
            }
        }

        let l = len?;
        if pos + l >= s.len() || !is_ws_any(s[pos + l]) {
            return None;
        }
        Some(Slice { start: pos, end: pos + l })
    }

    /// `[*+-] \[[Xx ]\]` — returns `checked`.
    fn match_task_list_marker(&self, pos: usize) -> Option<bool> {
        let s = self.subject;
        if pos + 4 >= s.len() {
            return None;
        }
        if !matches!(s[pos], b'*' | b'+' | b'-') || s[pos + 1] != b' ' || s[pos + 2] != b'[' {
            return None;
        }
        let bx = s[pos + 3];
        if !matches!(bx, b'X' | b'x' | b' ') || s[pos + 4] != b']' {
            return None;
        }
        if pos + 5 >= s.len() || !is_ws_any(s[pos + 5]) {
            return None;
        }
        Some(bx == b'X' || bx == b'x')
    }

    fn marker_and_styles(&self, pos: usize) -> Option<MarkerStyles> {
        let m = self.match_list_marker(pos)?;
        if let Some(checked) = self.match_task_list_marker(pos) {
            let marker = Slice { start: pos, end: pos + 5 };
            let styles = get_list_styles(&self.subject[marker.start..marker.end]);
            if styles.is_empty() {
                return None;
            }
            return Some(MarkerStyles { marker, styles, checkbox: Some(checked) });
        }
        let styles = get_list_styles(&self.subject[m.start..m.end]);
        if styles.is_empty() {
            return None;
        }
        Some(MarkerStyles { marker: m, styles, checkbox: None })
    }

    fn continue_list(&mut self, idx: usize) -> bool {
        if self.indent > self.containers[idx].extra.indent || self.pos == self.starteol {
            return true;
        }
        let Some(m) = self.marker_and_styles(self.pos) else { return false };
        let narrowed = self.containers[idx].extra.styles.intersect(&m.styles);
        if !narrowed.is_empty() {
            self.containers[idx].extra.styles = narrowed;
            return true;
        }
        false
    }

    fn open_list(&mut self) -> bool {
        let Some(m) = self.marker_and_styles(self.pos) else { return false };
        let extra = Extra { styles: m.styles, indent: self.indent, ..Default::default() };
        self.add_container(Container::with_extra(BlockKind::List, ContentType::Block, ContentType::ListItem, extra), false);
        self.add_match_styled(m.marker.start, m.marker.end.saturating_sub(1), Annotation::ListOpen, m.styles);
        true
    }

    fn open_list_item(&mut self) -> bool {
        let Some(m) = self.marker_and_styles(self.pos) else { return false };
        let extra = Extra { styles: m.styles, indent: self.indent, ..Default::default() };
        self.add_container(
            Container::with_extra(BlockKind::ListItem, ContentType::ListItem, ContentType::Block, extra),
            false,
        );
        self.add_match_styled(m.marker.start, m.marker.end.saturating_sub(1), Annotation::ListItemOpen, m.styles);
        self.pos = m.marker.end;
        if let Some(checked) = m.checkbox {
            let a = if checked { Annotation::CheckboxChecked } else { Annotation::CheckboxUnchecked };
            self.add_match(m.marker.start + 2, m.marker.start + 4, a);
            self.pos = m.marker.start + 5;
        }
        true
    }

    // ── table ──

    /// `(\|[^\r\n]*\|)[ \t]*\r?\n` — row text is `[start,end)`.
    fn match_table_row(&self, pos: usize) -> Option<Slice> {
        let s = self.subject;
        if pos >= s.len() || s[pos] != b'|' {
            return None;
        }
        let mut p = pos + 1;
        let mut last_bar = None;
        while p < s.len() && s[p] != b'\r' && s[p] != b'\n' {
            if s[p] == b'|' {
                last_bar = Some(p);
            }
            p += 1;
        }
        let bar = last_bar?;
        let mut q = bar + 1;
        while q < s.len() && is_space_or_tab(s[q]) {
            q += 1;
        }
        if q < s.len() && s[q] == b'\r' {
            q += 1;
        }
        if q >= s.len() || s[q] != b'\n' {
            return None;
        }
        Some(Slice { start: pos, end: bar + 1 })
    }

    fn continue_table(&mut self) -> bool {
        let Some(row) = self.match_table_row(self.pos) else { return false };
        self.parse_table_row(row.start, row.end.saturating_sub(1))
    }

    fn open_table(&mut self) -> bool {
        let Some(row) = self.match_table_row(self.pos) else { return false };
        self.add_container(Container::new(BlockKind::Table, ContentType::Block, ContentType::Cells), false);
        self.add_match(row.start, row.start, Annotation::TableOpen);
        if self.parse_table_row(row.start, row.end.saturating_sub(1)) {
            true
        } else {
            self.matches.pop();
            self.containers.pop();
            false
        }
    }

    /// `(:?)--*(:?)([ \t]*\|[ \t]*)` starting at `p`.
    fn match_row_sep(&self, p: usize) -> Option<RowSep> {
        let s = self.subject;
        let mut q = p;
        let mut left = false;
        if q < s.len() && s[q] == b':' {
            left = true;
            q += 1;
        }
        let dash_start = q;
        while q < s.len() && s[q] == b'-' {
            q += 1;
        }
        if q == dash_start {
            return None;
        }
        let mut right = false;
        if q < s.len() && s[q] == b':' {
            right = true;
            q += 1;
        }
        while q < s.len() && is_space_or_tab(s[q]) {
            q += 1;
        }
        if q >= s.len() || s[q] != b'|' {
            return None;
        }
        q += 1;
        while q < s.len() && is_space_or_tab(s[q]) {
            q += 1;
        }
        Some(RowSep { end: q, left, right })
    }

    fn parse_table_row(&mut self, sp: usize, ep: usize) -> bool {
        let orig_matches = self.matches.len();
        let startpos = self.pos;
        self.add_match(sp, sp, Annotation::RowOpen);
        self.pos += 1; // skip leading |

        let mut p = self.pos;
        let mut sepfound = false;
        let mut aligns: Vec<(usize, usize, bool, bool)> = Vec::new();
        while !sepfound {
            let Some(m) = self.match_row_sep(p) else { break };
            aligns.push((p, m.end.saturating_sub(1), m.left, m.right));
            p = m.end;
            if p == self.starteol {
                sepfound = true;
                break;
            }
        }
        if sepfound {
            for &(start, send, left, right) in &aligns {
                let annot = if left && right {
                    Annotation::SeparatorCenter
                } else if right {
                    Annotation::SeparatorRight
                } else if left {
                    Annotation::SeparatorLeft
                } else {
                    Annotation::SeparatorDefault
                };
                // trim trailing "[ \t]*|[ \t]*" from the span
                let mut end = send;
                while end >= start && (self.subject[end] == b'|' || is_space_or_tab(self.subject[end])) {
                    if end == 0 {
                        break;
                    }
                    end -= 1;
                }
                self.add_match(start, end, annot);
            }
            let e = self.starteol.saturating_sub(1);
            self.add_match(e, e, Annotation::RowClose);
            self.pos = self.starteol;
            self.finished_line = true;
            return true;
        }

        while self.pos <= ep {
            let Some(cell) = self.parse_table_cell() else {
                self.pos = startpos;
                self.matches.truncate(orig_matches);
                return false;
            };
            self.add_match(cell.start, cell.start, Annotation::CellOpen);
            let n = cell.matches.len();
            for (i, m) in cell.matches.iter().enumerate() {
                let mut e = m.end as usize;
                if i == n - 1 && m.annot == Annotation::Str {
                    while e >= m.start as usize && e < self.subject.len() && self.subject[e] == b' ' {
                        if e == 0 {
                            break;
                        }
                        e -= 1;
                    }
                }
                self.add_match(m.start as usize, e, m.annot);
            }
            self.add_match(cell.end, cell.end, Annotation::CellClose);
        }
        self.add_match(self.pos, self.pos, Annotation::RowClose);
        self.pos = self.starteol;
        self.finished_line = true;
        true
    }

    /// `[^`|\r\n]*(?:[|]|`+)` -- scan to the next `|` or backtick run.
    fn find_next_bar_or_ticks(&self, pos: usize) -> Option<usize> {
        let s = self.subject;
        let mut p = pos;
        while p < s.len() && s[p] != b'`' && s[p] != b'|' && s[p] != b'\r' && s[p] != b'\n' {
            p += 1;
        }
        if p >= s.len() {
            return None;
        }
        if s[p] == b'|' {
            return Some(p);
        }
        if s[p] == b'`' {
            while p < s.len() && s[p] == b'`' {
                p += 1;
            }
            return Some(p.saturating_sub(1));
        }
        None
    }

    fn parse_table_cell(&mut self) -> Option<Cell> {
        let mut ip = InlineParser::new(self.subject);
        let mut cell_complete = false;
        let sp = self.pos.saturating_sub(1);
        let mut ep = sp;
        self.skip_space();
        while !cell_complete {
            let nextbar = self.find_next_bar_or_ticks(self.pos)?;
            if self.subject[nextbar] == b'`' || ip.in_verbatim() {
                ip.feed(self.pos, nextbar);
            } else if nextbar > 0 && self.subject[nextbar - 1] == b'\\' {
                ip.feed(self.pos, nextbar);
            } else {
                ip.feed(self.pos, nextbar.saturating_sub(1));
                ep = nextbar;
                cell_complete = true;
            }
            self.pos = nextbar + 1;
        }
        let matches = ip.get_matches();
        Some(Cell { start: sp, end: ep, matches })
    }

    // ── attributes (block-level) ──

    fn continue_attributes(&mut self, idx: usize) -> bool {
        let (pos, starteol, endeol, indent) = (self.pos, self.starteol, self.endeol, self.indent);
        {
            let c = &mut self.containers[idx];
            if c.extra.attr_status == Status::Done {
                return false;
            }
            if c.extra.attr_parser.is_some() && indent > c.extra.indent {
                c.extra.attr_slices.push(Slice { start: pos, end: starteol });
                let res = c.extra.attr_parser.as_mut().unwrap().feed(pos, endeol);
                c.extra.attr_status = res.status;
                if res.status == Status::Done {
                    c.extra.attr_endpos = res.position;
                }
                if res.status != Status::Fail || !self.match_endline_at(res.position + 1) {
                    self.pos = self.starteol;
                    return true;
                }
            }
        }
        // Attribute parsing failed or indentation ended: fall back to a
        // paragraph re-parsing everything we tried to read as attributes.
        let start = self.containers[idx].extra.attr_startpos;
        self.add_match(start, start, Annotation::ParaOpen);
        let popped = self.containers.pop().unwrap();
        self.add_container(Container::new(BlockKind::Para, ContentType::Block, ContentType::Inline), true);
        let mut newpos = None;
        if let Some(ip) = self.containers.last_mut().unwrap().inline_parser.as_mut() {
            for sl in &popped.extra.attr_slices {
                ip.feed(sl.start, sl.end);
            }
            newpos = Some(ip.lastpos() + 1);
        }
        if let Some(p) = newpos {
            self.pos = p;
        }
        true
    }

    fn match_endline_at(&self, pos: usize) -> bool {
        let s = self.subject;
        let mut p = pos;
        while p < s.len() && is_space_or_tab(s[p]) {
            p += 1;
        }
        if p < s.len() && s[p] == b'\r' {
            p += 1;
        }
        p < s.len() && s[p] == b'\n'
    }

    fn open_attributes(&mut self) -> bool {
        if self.byte_at(self.pos) != b'{' {
            return false;
        }
        let mut ap = AttributeParser::new(self.subject);
        let res = ap.feed(self.pos, self.starteol);
        if res.status == Status::Fail {
            return false;
        }
        if res.status == Status::Done && !self.match_endline_at(res.position + 1) {
            return false;
        }
        let extra = Extra {
            attr_parser: Some(ap),
            attr_status: res.status,
            indent: self.indent,
            attr_startpos: self.pos,
            attr_endpos: if res.status == Status::Done { res.position } else { self.pos },
            attr_slices: vec![Slice { start: self.pos, end: self.starteol }],
            ..Default::default()
        };
        self.add_container(
            Container::with_extra(BlockKind::Attributes, ContentType::Block, ContentType::Attributes, extra),
            false,
        );
        self.pos = self.starteol;
        true
    }

    fn close_attributes(&mut self, c: &mut Container<'s>) {
        if c.extra.attr_status == Status::Continue {
            self.add_match(c.extra.attr_startpos, c.extra.attr_startpos, Annotation::ParaOpen);
            self.add_container(Container::new(BlockKind::Para, ContentType::Block, ContentType::Inline), true);
            if let Some(ip) = self.containers.last_mut().unwrap().inline_parser.as_mut() {
                for sl in &c.extra.attr_slices {
                    ip.feed(sl.start, sl.end);
                }
            }
            self.close_container();
        } else {
            self.add_match(c.extra.attr_startpos, c.extra.attr_startpos, Annotation::BlockAttributesOpen);
            if let Some(ap) = &c.extra.attr_parser {
                self.matches.extend_from_slice(&ap.matches);
            }
            // The `}`, not `self.pos`: `parser.rs` reads this position as the
            // block's end, and reads "not after the open" as "never closed".
            self.add_match(c.extra.attr_endpos, c.extra.attr_endpos, Annotation::BlockAttributesClose);
        }
    }

    // ── fenced_div ──

    fn continue_fenced_div(&mut self, idx: usize) -> bool {
        if self.tip().is_some_and(|t| t.kind == BlockKind::CodeBlock) {
            return true; // see djot.js issue #109
        }
        let s = self.subject;
        // `(::::*)[ \t]*\r?\n`
        let mut p = self.pos;
        let mut colons = 0;
        while p < s.len() && s[p] == b':' {
            p += 1;
            colons += 1;
        }
        if colons >= 3 {
            let mut q = p;
            while q < s.len() && is_space_or_tab(s[q]) {
                q += 1;
            }
            if q < s.len() && s[q] == b'\r' {
                q += 1;
            }
            if q < s.len() && s[q] == b'\n' && colons >= self.containers[idx].extra.colons {
                self.containers[idx].extra.end_fence = Some(Slice { start: self.pos, end: p.saturating_sub(1) });
                self.pos = q; // before newline
                return false;
            }
        }
        true
    }

    fn open_fenced_div(&mut self) -> bool {
        let s = self.subject;
        let mut p = self.pos;
        let mut colons = 0;
        while p < s.len() && s[p] == b':' {
            p += 1;
            colons += 1;
        }
        if colons < 3 {
            return false;
        }
        let fence_start = self.pos;
        let fence_end = p.saturating_sub(1);
        let mut q = p;
        while q < s.len() && is_space_or_tab(s[q]) {
            q += 1;
        }
        let lang_start = q;
        while q < s.len() && (s[q].is_ascii_alphanumeric() || s[q] == b'_' || s[q] == b'-') {
            q += 1;
        }
        let lang_end = q;
        let mut r = q;
        while r < s.len() && is_space_or_tab(s[r]) {
            r += 1;
        }
        if r < s.len() && s[r] == b'\r' {
            r += 1;
        }
        if r >= s.len() || s[r] != b'\n' {
            return false;
        }
        let extra = Extra { colons, ..Default::default() };
        self.add_container(Container::with_extra(BlockKind::FencedDiv, ContentType::Block, ContentType::Block, extra), false);
        self.add_match(fence_start, fence_end, Annotation::DivOpen);
        if lang_end > lang_start {
            self.add_match(lang_start, lang_end.saturating_sub(1), Annotation::Class);
        }
        self.pos = r;
        self.finished_line = true;
        true
    }

    // ── code_block ──

    fn match_code_fence(&self, pos: usize) -> Option<CodeFence> {
        let s = self.subject;
        if pos >= s.len() {
            return None;
        }
        let ch = s[pos];
        if ch != b'~' && ch != b'`' {
            return None;
        }
        let mut p = pos;
        while p < s.len() && s[p] == ch {
            p += 1;
        }
        if p - pos < 3 {
            return None;
        }
        let mut q = p;
        while q < s.len() && is_space_or_tab(s[q]) {
            q += 1;
        }
        let lang_start = q;
        while q < s.len() && !matches!(s[q], b' ' | b'\t' | b'\r' | b'\n' | b'`') {
            q += 1;
        }
        let lang_end = q;
        let mut r = q;
        while r < s.len() && is_space_or_tab(s[r]) {
            r += 1;
        }
        if r < s.len() && s[r] == b'\r' {
            r += 1;
        }
        if r >= s.len() || s[r] != b'\n' {
            return None;
        }
        Some(CodeFence {
            border: Slice { start: pos, end: p },
            lang: Slice { start: lang_start, end: lang_end },
            is_raw: lang_end > lang_start && s[lang_start] == b'=',
            line_end: r,
        })
    }

    /// Returns (start, end, line_end).
    fn match_code_fence_close(&self, pos: usize, ch: u8, min_len: usize) -> Option<(usize, usize, usize)> {
        let s = self.subject;
        let mut p = pos;
        while p < s.len() && s[p] == ch {
            p += 1;
        }
        if p - pos < min_len {
            return None;
        }
        let mut q = p;
        while q < s.len() && is_space_or_tab(s[q]) {
            q += 1;
        }
        if q >= s.len() || !(s[q] == b'\r' || s[q] == b'\n') {
            return None;
        }
        Some((pos, p.saturating_sub(1), q))
    }

    fn continue_code_block(&mut self, idx: usize) -> bool {
        let (ch, len) = (self.containers[idx].extra.fence_char, self.containers[idx].extra.fence_len);
        if let Some((start, end, line_end)) = self.match_code_fence_close(self.pos, ch, len) {
            self.containers[idx].extra.end_fence = Some(Slice { start, end });
            self.pos = line_end;
            self.finished_line = true;
            return false;
        }
        true
    }

    fn open_code_block(&mut self) -> bool {
        let Some(m) = self.match_code_fence(self.pos) else { return false };
        let border_char = self.subject[m.border.start];
        let border_len = m.border.end - m.border.start;
        let extra = Extra { fence_char: border_char, fence_len: border_len, ..Default::default() };
        let mut cont = Container::with_extra(BlockKind::CodeBlock, ContentType::Block, ContentType::Text, extra);
        cont.indent = self.indent;
        self.add_container(cont, false);
        let indent = self.indent;
        self.containers.last_mut().unwrap().indent = indent;
        self.add_match(m.border.start, m.border.end.saturating_sub(1), Annotation::CodeBlockOpen);
        if m.lang.end > m.lang.start {
            let annot = if m.is_raw { Annotation::RawFormat } else { Annotation::CodeLanguage };
            self.add_match(m.lang.start, m.lang.end.saturating_sub(1), annot);
        }
        self.pos = m.line_end;
        self.finished_line = true;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan_all(subject: &[u8]) -> Vec<Event> {
        Parser::new(subject).scan()
    }

    #[test]
    fn paragraph_produces_para_str_para() {
        let e = scan_all(b"hello world\n");
        assert!(e.len() >= 3);
        assert_eq!(e[0].annot, Annotation::ParaOpen);
        assert_eq!(e.last().unwrap().annot, Annotation::ParaClose);
    }

    #[test]
    fn heading_level_and_thematic_break() {
        let e = scan_all(b"## Hi\n\n---\n");
        assert!(e.iter().any(|e| e.annot == Annotation::HeadingOpen));
        assert!(e.iter().any(|e| e.annot == Annotation::ThematicBreak));
    }

    #[test]
    fn bullet_list_with_two_items() {
        let e = scan_all(b"- a\n- b\n");
        assert_eq!(e.iter().filter(|e| e.annot == Annotation::ListOpen).count(), 1);
        assert_eq!(e.iter().filter(|e| e.annot == Annotation::ListItemOpen).count(), 2);
    }

    #[test]
    fn code_block_with_language() {
        let s = b"```zig\nconst x = 1;\n```\n";
        let e = scan_all(s);
        let lang = e.iter().find(|e| e.annot == Annotation::CodeLanguage).unwrap();
        assert_eq!(&s[lang.start as usize..lang.end as usize + 1], b"zig");
    }

    #[test]
    fn get_list_styles_classifies_markers() {
        let dash = get_list_styles(b"-");
        assert_eq!(dash.len, 1);
        assert_eq!(dash.items[0], ListMarkerStyle::Dash);
        assert_eq!(get_list_styles(b"- [x]").items[0], ListMarkerStyle::DashTask);
        assert_eq!(get_list_styles(b"i.").len, 2);
        let d = get_list_styles(b"12.");
        assert_eq!(d.len, 1);
        assert_eq!(d.items[0], ListMarkerStyle::Ordered { numbering: Numbering::Decimal, delim: Delim::Period });
        assert_eq!(get_list_styles(b"::").len, 0);
    }
}
