//! Inline-level scanner: dispatches on "special" bytes and resolves
//! emphasis/strong/quotes/insert/delete/mark via a delimiter stack and
//! links/images/spans via a bracket stack. Ported from djot.js's
//! `src/inline.ts`.
//!
//! Parse without backtracking by keeping a stack of potential "openers". When
//! a potential closer is found, scan the matching opener stack; on a match,
//! rewrite the placeholder event already sitting at the opener's position into
//! the real `*Open` annotation and append the `*Close` annotation.

use super::attributes::{AttributeParser, Status};
use super::event::{Annotation, Event, EventList};

#[derive(Clone, Copy, Debug)]
struct Slice {
    start: usize,
    end: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(usize)]
enum OpenerKind {
    Tilde,
    Caret,
    Underscore,
    Asterisk,
    Plus,
    Equals,
    Hyphen,
    Squote,
    Dquote,
    BraceTilde,
    BraceCaret,
    BraceUnderscore,
    BraceAsterisk,
    BracePlus,
    BraceEquals,
    BraceHyphen,
    BraceSquote,
    BraceDquote,
    Bracket,
    Paren,
}

impl OpenerKind {
    fn plain(c: u8) -> OpenerKind {
        match c {
            b'~' => OpenerKind::Tilde,
            b'^' => OpenerKind::Caret,
            b'_' => OpenerKind::Underscore,
            b'*' => OpenerKind::Asterisk,
            b'+' => OpenerKind::Plus,
            b'=' => OpenerKind::Equals,
            b'-' => OpenerKind::Hyphen,
            b'\'' => OpenerKind::Squote,
            b'"' => OpenerKind::Dquote,
            _ => unreachable!(),
        }
    }

    fn braced(c: u8) -> OpenerKind {
        match c {
            b'~' => OpenerKind::BraceTilde,
            b'^' => OpenerKind::BraceCaret,
            b'_' => OpenerKind::BraceUnderscore,
            b'*' => OpenerKind::BraceAsterisk,
            b'+' => OpenerKind::BracePlus,
            b'=' => OpenerKind::BraceEquals,
            b'-' => OpenerKind::BraceHyphen,
            b'\'' => OpenerKind::BraceSquote,
            b'"' => OpenerKind::BraceDquote,
            _ => unreachable!(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LinkState {
    None,
    ReferenceLink,
    ExplicitLink,
}

#[derive(Clone, Copy, Debug)]
struct Opener {
    match_index: usize,
    startpos: usize,
    endpos: usize,
    link_state: LinkState,
    sub_match_index: usize,
    substartpos: Option<usize>,
    subendpos: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum VerbatimKind {
    Verbatim,
    InlineMath,
    DisplayMath,
}

impl VerbatimKind {
    fn close_annot(self) -> Annotation {
        match self {
            VerbatimKind::Verbatim => Annotation::VerbatimClose,
            VerbatimKind::InlineMath => Annotation::InlineMathClose,
            VerbatimKind::DisplayMath => Annotation::DisplayMathClose,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OpenTest {
    Always,
    HasBrace,
    QuoteOpen,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutolinkKind {
    Url,
    Email,
}

pub struct InlineParser<'s> {
    subject: &'s [u8],
    pub matches: EventList,
    openers: [Vec<Opener>; 20],
    verbatim: usize,
    verbatim_type: VerbatimKind,
    destination: bool,
    firstpos: Option<usize>,
    lastpos: usize,
    allow_attributes: bool,
    attribute_parser: Option<AttributeParser<'s>>,
    attribute_start: Option<usize>,
    attribute_slices: Option<Vec<Slice>>,
}

fn is_special(c: u8) -> bool {
    matches!(
        c,
        b'\r' | b'\n' | b'"' | b'\'' | b'(' | b')' | b'*' | b'+' | b'.' | b':' | b'<' | b'=' | b'[' | b'\\' | b']'
            | b'^' | b'_' | b'`' | b'$' | b'{' | b'}' | b'~' | b'-'
    )
}

fn find_special(s: &[u8], pos: usize, endpos: usize) -> Option<usize> {
    let mut p = pos;
    while p <= endpos && p < s.len() {
        if is_special(s[p]) {
            return Some(p);
        }
        p += 1;
    }
    None
}

fn is_nonspace(c: u8) -> bool {
    !(c == b' ' || c == b'\t' || c == b'\r' || c == b'\n')
}

fn is_punctuation_byte(c: u8) -> bool {
    matches!(
        c,
        b'!' | b'"' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'(' | b')' | b'*' | b'+' | b',' | b'-' | b'.' | b'/'
            | b':' | b';' | b'<' | b'=' | b'>' | b'?' | b'@' | b'[' | b']' | b'\\' | b'^' | b'_' | b'`' | b'{'
            | b'|' | b'}' | b'~'
    )
}

fn is_ws_byte(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

/// `/[^:]@/` -- any `@` not immediately preceded by `:`.
fn contains_non_colon_at(s: &[u8]) -> bool {
    s.iter().enumerate().any(|(i, &c)| c == b'@' && i > 0 && s[i - 1] != b':')
}

/// `/[a-zA-Z]:/` -- a letter immediately followed by `:`, anywhere.
fn contains_scheme_colon(s: &[u8]) -> bool {
    if s.len() < 2 {
        return false;
    }
    (0..s.len() - 1).any(|i| s[i].is_ascii_alphabetic() && s[i + 1] == b':')
}

/// What `<content>` spells: an `@` not preceded by `:` makes it an email, else
/// a `letter:` anywhere makes it a url. Anything else is not an autolink.
pub fn autolink_kind_of(content: &[u8]) -> Option<AutolinkKind> {
    if content.is_empty() {
        return None;
    }
    if content.iter().any(|&c| c == b'<' || c == b'>' || is_ws_byte(c)) {
        return None;
    }
    if contains_non_colon_at(content) {
        return Some(AutolinkKind::Email);
    }
    if contains_scheme_colon(content) {
        return Some(AutolinkKind::Url);
    }
    None
}

/// `\{=[^\s{}`]+\}`
fn match_raw_attribute(s: &[u8], pos: usize, endpos: usize) -> Option<Slice> {
    let mut p = pos;
    if p > endpos || p + 1 >= s.len() || s[p] != b'{' || s[p + 1] != b'=' {
        return None;
    }
    p += 2;
    let start = p;
    while p <= endpos && p < s.len() {
        let ch = s[p];
        if ch == b' ' || ch == b'\t' || ch == b'\r' || ch == b'\n' || ch == b'{' || ch == b'}' || ch == b'`' {
            break;
        }
        p += 1;
    }
    if p == start {
        return None;
    }
    if p > endpos || p >= s.len() || s[p] != b'}' {
        return None;
    }
    Some(Slice { start: pos, end: p })
}

fn match_line_end_at(s: &[u8], pos: usize, endpos: usize) -> Option<usize> {
    let mut p = pos;
    while p <= endpos && p < s.len() && (s[p] == b' ' || s[p] == b'\t') {
        p += 1;
    }
    if p <= endpos && p < s.len() && s[p] == b'\r' {
        p += 1;
    }
    if p <= endpos && p < s.len() && s[p] == b'\n' {
        return Some(p);
    }
    None
}

/// `[_*~^+='"-]` -- single char class, sticky at exactly `pos`.
fn matches_delim_at(s: &[u8], pos: usize, endpos: usize) -> bool {
    if pos > endpos || pos >= s.len() {
        return false;
    }
    matches!(s[pos], b'_' | b'*' | b'~' | b'^' | b'+' | b'=' | b'\'' | b'"' | b'-')
}

fn is_symbol_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'+' || c == b'-'
}

fn flip_default_annot(a: Annotation, has_open_marker: bool, has_close_marker: bool) -> Annotation {
    if has_open_marker {
        match a {
            Annotation::RightSingleQuote => Annotation::LeftSingleQuote,
            Annotation::RightDoubleQuote => Annotation::LeftDoubleQuote,
            _ => a,
        }
    } else if has_close_marker {
        match a {
            Annotation::LeftSingleQuote => Annotation::RightSingleQuote,
            Annotation::LeftDoubleQuote => Annotation::RightDoubleQuote,
            _ => a,
        }
    } else {
        a
    }
}

impl<'s> InlineParser<'s> {
    pub fn new(subject: &'s [u8]) -> Self {
        InlineParser {
            subject,
            matches: Vec::new(),
            openers: Default::default(),
            verbatim: 0,
            verbatim_type: VerbatimKind::Verbatim,
            destination: false,
            firstpos: None,
            lastpos: 0,
            allow_attributes: true,
            attribute_parser: None,
            attribute_start: None,
            attribute_slices: None,
        }
    }

    pub fn lastpos(&self) -> usize {
        self.lastpos
    }

    pub fn in_verbatim(&self) -> bool {
        self.verbatim > 0
    }

    fn ops(&mut self, k: OpenerKind) -> &mut Vec<Opener> {
        &mut self.openers[k as usize]
    }

    fn add_match(&mut self, start: usize, end: usize, annot: Annotation) {
        self.matches.push(Event::new(start as u32, end as u32, annot));
    }

    fn replace_match(&mut self, index: usize, start: usize, end: usize, annot: Annotation) {
        self.matches[index] = Event::new(start as u32, end as u32, annot);
    }

    fn add_opener(&mut self, kind: OpenerKind, startpos: usize, endpos: usize, default_annot: Annotation) {
        let n = self.matches.len();
        self.ops(kind).push(Opener {
            match_index: n,
            startpos,
            endpos,
            link_state: LinkState::None,
            sub_match_index: n,
            substartpos: None,
            subendpos: None,
        });
        self.add_match(startpos, endpos, default_annot);
    }

    fn clear_openers(&mut self, startpos: usize, endpos: usize) {
        for stack in self.openers.iter_mut() {
            let mut i = stack.len() as isize - 1;
            while i >= 0 {
                let idx = i as usize;
                let o = &mut stack[idx];
                if o.startpos >= startpos && o.endpos <= endpos {
                    stack.remove(idx);
                } else if o.substartpos.is_some_and(|s| s >= startpos) && o.subendpos.is_some_and(|e| e <= endpos) {
                    o.substartpos = None;
                    o.subendpos = None;
                    o.link_state = LinkState::None;
                } else {
                    break;
                }
                i -= 1;
            }
        }
    }

    fn str_matches(&mut self, startpos: usize, endpos: usize) {
        let mut i = self.matches.len() as isize - 1;
        while i > 0 && self.matches[i as usize].start as usize >= startpos {
            i -= 1;
        }
        if (self.matches[i as usize].start as usize) < startpos {
            i += 1;
        }
        while i >= 0 && (i as usize) < self.matches.len() && self.matches[i as usize].end as usize <= endpos {
            let m = &mut self.matches[i as usize];
            if m.annot != Annotation::Escape && m.annot != Annotation::Str {
                m.annot = Annotation::Str;
            }
            i += 1;
        }
    }

    /// `opener_idx` indexes the bracket opener stack.
    fn add_image_marker(&mut self, opener_idx: usize) {
        let opener = self.openers[OpenerKind::Bracket as usize][opener_idx];
        let prev_idx_i = opener.match_index as isize - 1;
        if prev_idx_i >= 0 {
            let prev_idx = prev_idx_i as usize;
            let prev = self.matches[prev_idx];
            if prev.annot == Annotation::Str && (prev.start as usize) < opener.startpos - 1 {
                self.matches[prev_idx].end = (opener.startpos - 2) as u32;
                self.matches.insert(
                    prev_idx + 1,
                    Event::new((opener.startpos - 1) as u32, (opener.startpos - 1) as u32, Annotation::ImageMarker),
                );
                let o = &mut self.openers[OpenerKind::Bracket as usize][opener_idx];
                o.match_index += 1;
                o.sub_match_index += 1;
                return;
            }
        }
        self.replace_match(prev_idx_i as usize, opener.startpos - 1, opener.startpos - 1, Annotation::ImageMarker);
    }

    fn single_char(&mut self, pos: usize) -> usize {
        self.add_match(pos, pos, Annotation::Str);
        pos + 1
    }

    fn reparse_attributes(&mut self) {
        let Some(slices) = self.attribute_slices.take() else { return };
        self.allow_attributes = false;
        self.attribute_parser = None;
        self.attribute_start = None;
        for sl in &slices {
            self.feed(sl.start, sl.end);
        }
        self.allow_attributes = true;
        self.attribute_slices = None;
    }

    /// Finalize the parser's events: drop a trailing soft break (and any space
    /// it left on the preceding `str`), and close a still-open verbatim run.
    pub fn finish_matches(&mut self) -> &[Event] {
        if self.attribute_parser.is_some() {
            self.reparse_attributes();
        }

        if self.matches.last().is_some_and(|m| m.annot == Annotation::SoftBreak) {
            self.matches.pop();
            let subject = self.subject;
            if let Some(m) = self.matches.last_mut() {
                if m.annot == Annotation::Str && (m.end as usize) < subject.len() && subject[m.end as usize] == b' ' {
                    let mut underflow = false;
                    while m.end >= m.start && subject[m.end as usize] == b' ' {
                        if m.end == 0 {
                            break;
                        }
                        m.end -= 1;
                    }
                    if m.end < m.start {
                        underflow = true;
                    }
                    if underflow {
                        self.matches.pop();
                    }
                }
            }
        }
        if !self.matches.is_empty() && self.verbatim > 0 {
            let last = *self.matches.last().unwrap();
            self.add_match(last.end as usize, last.end as usize, self.verbatim_type.close_annot());
        }
        &self.matches
    }

    /// Owned copy of `finish_matches`.
    pub fn get_matches(&mut self) -> Vec<Event> {
        self.finish_matches().to_vec()
    }

    fn byte_at(&self, pos: usize) -> u8 {
        if pos < self.subject.len() { self.subject[pos] } else { 0 }
    }

    fn has_nonspace_at(&self, pos: usize) -> bool {
        pos < self.subject.len() && is_nonspace(self.subject[pos])
    }

    fn has_brace(&self, pos: usize) -> bool {
        (pos > 0 && self.byte_at(pos - 1) == b'{') || self.byte_at(pos + 1) == b'}'
    }

    fn quote_open_test(&self, pos: usize) -> bool {
        if pos == 0 {
            return true;
        }
        matches!(self.byte_at(pos - 1), b' ' | b'\t' | b'\r' | b'\n' | b'"' | b'\'' | b'-' | b'(' | b'[')
    }

    fn open_test(&self, t: OpenTest, pos: usize) -> bool {
        match t {
            OpenTest::Always => true,
            OpenTest::HasBrace => self.has_brace(pos),
            OpenTest::QuoteOpen => self.quote_open_test(pos),
        }
    }

    // ── betweenMatched: the shared delimiter-stack matcher ──

    #[allow(clippy::too_many_arguments)]
    fn between_matched(
        &mut self,
        c: u8,
        open_annot: Annotation,
        close_annot: Annotation,
        default_annot: Annotation,
        opentest: OpenTest,
        pos: usize,
        endpos: usize,
    ) -> usize {
        let mut can_open = self.has_nonspace_at(pos + 1) && self.open_test(opentest, pos);
        let mut can_close = pos > 0 && self.has_nonspace_at(pos - 1);
        let has_open_marker = self.matches.last().is_some_and(|m| m.annot == Annotation::OpenMarker);
        let has_close_marker = pos < endpos && self.byte_at(pos + 1) == b'}';
        let mut endcloser = pos;
        let mut startopener = pos;

        if has_open_marker {
            can_open = true;
            can_close = false;
            startopener = pos.saturating_sub(1);
        }
        if !has_open_marker && has_close_marker {
            can_close = true;
            can_open = false;
            endcloser = pos + 1;
        }

        let default_a = flip_default_annot(default_annot, has_open_marker, has_close_marker);

        let opener_kind = if has_close_marker { OpenerKind::braced(c) } else { OpenerKind::plain(c) };

        if can_close && !self.ops(opener_kind).is_empty() {
            let opener = *self.ops(opener_kind).last().unwrap();
            if opener.endpos != pos.saturating_sub(1) || pos == 0 {
                if self.destination {
                    if let Some(link_opener) = self.ops(OpenerKind::Bracket).last().copied() {
                        if link_opener.link_state == LinkState::ExplicitLink && opener.startpos < link_opener.startpos {
                            self.add_match(pos, endcloser, default_a);
                            return endcloser + 1;
                        }
                    }
                }
                self.clear_openers(opener.startpos, pos);
                self.replace_match(opener.match_index, opener.startpos, opener.endpos, open_annot);
                self.add_match(pos, endcloser, close_annot);
                return endcloser + 1;
            }
        }

        if can_open {
            let e = if has_open_marker { OpenerKind::braced(c) } else { OpenerKind::plain(c) };
            self.add_opener(e, startopener, pos, default_a);
            pos + 1
        } else {
            self.add_match(pos, endcloser, default_a);
            endcloser + 1
        }
    }

    // ── the main feed loop ──

    pub fn feed(&mut self, startpos: usize, endpos: usize) {
        if self.firstpos.is_none_or(|f| startpos < f) {
            self.firstpos = Some(startpos);
        }
        if self.lastpos == 0 || endpos > self.lastpos {
            self.lastpos = endpos;
        }

        let mut pos = startpos;
        while pos <= endpos {
            if self.attribute_parser.is_some() {
                let sp = pos;
                let ep2 = find_special(self.subject, pos, endpos).unwrap_or(endpos);
                let result = self.attribute_parser.as_mut().unwrap().feed(sp, ep2);
                let ep = result.position;
                match result.status {
                    Status::Done => {
                        if let Some(astart) = self.attribute_start {
                            self.add_match(astart, astart, Annotation::AttributesOpen);
                        }
                        let ap = self.attribute_parser.take().unwrap();
                        self.matches.extend_from_slice(&ap.matches);
                        self.add_match(ep, ep, Annotation::AttributesClose);
                        self.attribute_start = None;
                        self.attribute_slices = None;
                        pos = ep + 1;
                    }
                    Status::Fail => {
                        self.reparse_attributes();
                        pos = sp;
                    }
                    Status::Continue => {
                        self.attribute_slices.get_or_insert_with(Vec::new).push(Slice { start: sp, end: ep });
                        pos = ep + 1;
                    }
                }
                continue;
            }

            let next_special = find_special(self.subject, pos, endpos);
            let newpos = next_special.unwrap_or(endpos + 1);
            if newpos > pos {
                self.add_match(pos, newpos - 1, Annotation::Str);
                pos = newpos;
                if pos > endpos {
                    break;
                }
            }

            let c = self.subject[pos];
            if c == b'\r' || c == b'\n' {
                if c == b'\r' && pos < endpos && self.byte_at(pos + 1) == b'\n' {
                    self.add_match(pos, pos + 1, Annotation::SoftBreak);
                    pos += 2;
                } else {
                    self.add_match(pos, pos, Annotation::SoftBreak);
                    pos += 1;
                }
            } else if self.verbatim > 0 {
                pos = self.feed_verbatim_byte(pos, endpos, c);
            } else {
                pos = self.dispatch(c, pos, endpos);
            }
        }
    }

    fn feed_verbatim_byte(&mut self, pos: usize, endpos: usize, c: u8) -> usize {
        if c == b'`' {
            let mut p = pos;
            while p <= endpos && self.byte_at(p) == b'`' {
                p += 1;
            }
            let endchar = p.saturating_sub(1);
            if p - pos == self.verbatim {
                if let Some(raw) = match_raw_attribute(self.subject, endchar + 1, endpos) {
                    if self.verbatim_type == VerbatimKind::Verbatim {
                        self.add_match(pos, endchar, self.verbatim_type.close_annot());
                        self.add_match(raw.start, raw.end, Annotation::RawFormat);
                        self.verbatim = 0;
                        self.verbatim_type = VerbatimKind::Verbatim;
                        return raw.end + 1;
                    }
                }
                self.add_match(pos, endchar, self.verbatim_type.close_annot());
                self.verbatim = 0;
                self.verbatim_type = VerbatimKind::Verbatim;
                endchar + 1
            } else {
                self.add_match(pos, endchar, Annotation::Str);
                endchar + 1
            }
        } else {
            self.add_match(pos, pos, Annotation::Str);
            pos + 1
        }
    }

    fn dispatch(&mut self, c: u8, pos: usize, endpos: usize) -> usize {
        use Annotation as A;
        match c {
            b'`' => self.match_backtick(pos, endpos),
            b'\\' => self.match_backslash(pos, endpos),
            b'<' => self.match_autolink(pos, endpos).unwrap_or_else(|| self.single_char(pos)),
            b'~' => self.between_matched(b'~', A::SubscriptOpen, A::SubscriptClose, A::Str, OpenTest::Always, pos, endpos),
            b'^' => {
                self.between_matched(b'^', A::SuperscriptOpen, A::SuperscriptClose, A::Str, OpenTest::Always, pos, endpos)
            }
            b'_' => self.between_matched(b'_', A::EmphOpen, A::EmphClose, A::Str, OpenTest::Always, pos, endpos),
            b'*' => self.between_matched(b'*', A::StrongOpen, A::StrongClose, A::Str, OpenTest::Always, pos, endpos),
            b'+' => self.between_matched(b'+', A::InsertOpen, A::InsertClose, A::Str, OpenTest::HasBrace, pos, endpos),
            b'=' => self.between_matched(b'=', A::MarkOpen, A::MarkClose, A::Str, OpenTest::HasBrace, pos, endpos),
            b'\'' => self.between_matched(
                b'\'',
                A::SingleQuotedOpen,
                A::SingleQuotedClose,
                A::RightSingleQuote,
                OpenTest::QuoteOpen,
                pos,
                endpos,
            ),
            b'"' => self.between_matched(
                b'"',
                A::DoubleQuotedOpen,
                A::DoubleQuotedClose,
                A::LeftDoubleQuote,
                OpenTest::Always,
                pos,
                endpos,
            ),
            b'{' => self.match_left_brace(pos, endpos),
            b':' => self.match_colon(pos, endpos),
            b'.' => self.match_period(pos, endpos).unwrap_or_else(|| self.single_char(pos)),
            b'[' => {
                self.add_opener(OpenerKind::Bracket, pos, pos, A::Str);
                pos + 1
            }
            b']' => self.match_right_bracket(pos, endpos).unwrap_or_else(|| self.single_char(pos)),
            b'(' => self.match_left_paren(pos).unwrap_or_else(|| self.single_char(pos)),
            b')' => self.match_right_paren(pos).unwrap_or_else(|| self.single_char(pos)),
            b'-' => self.match_hyphen(pos, endpos),
            _ => self.single_char(pos),
        }
    }

    fn match_backtick(&mut self, pos: usize, endpos: usize) -> usize {
        let mut p = pos;
        while p <= endpos && self.byte_at(p) == b'`' {
            p += 1;
        }
        let endchar = p.saturating_sub(1);

        let mut dollar_escaped = false;
        if self.matches.len() >= 2 {
            let prev = self.matches[self.matches.len() - 2];
            dollar_escaped = prev.annot == Annotation::Escape && pos >= 2 && prev.end as usize == pos - 2;
        }

        let s = self.subject;
        if pos >= 2 && s[pos - 2] == b'$' && s[pos - 1] == b'$' && !(pos >= 3 && s[pos - 3] == b'\\') {
            self.matches.pop();
            self.matches.pop();
            self.add_match(pos - 2, endchar, Annotation::DisplayMathOpen);
            self.verbatim_type = VerbatimKind::DisplayMath;
        } else if pos >= 1 && s[pos - 1] == b'$' && !dollar_escaped {
            self.matches.pop();
            self.add_match(pos - 1, endchar, Annotation::InlineMathOpen);
            self.verbatim_type = VerbatimKind::InlineMath;
        } else {
            self.add_match(pos, endchar, Annotation::VerbatimOpen);
            self.verbatim_type = VerbatimKind::Verbatim;
        }
        self.verbatim = endchar - pos + 1;
        endchar + 1
    }

    fn match_backslash(&mut self, pos: usize, endpos: usize) -> usize {
        if let Some(line_end) = match_line_end_at(self.subject, pos + 1, endpos) {
            let subject = self.subject;
            if let Some(last) = self.matches.last_mut() {
                if last.annot == Annotation::Str {
                    let mut ep = last.end as isize;
                    let sp = last.start as isize;
                    while ep >= sp && (subject[ep as usize] == b' ' || subject[ep as usize] == b'\t') {
                        ep -= 1;
                    }
                    if ep < sp {
                        self.matches.pop();
                    } else {
                        last.end = ep as u32;
                    }
                }
            }
            self.add_match(pos, pos, Annotation::Escape);
            self.add_match(pos + 1, line_end, Annotation::HardBreak);
            line_end + 1
        } else if pos < endpos && self.byte_at(pos + 1) < 0x80 && is_punctuation_byte(self.byte_at(pos + 1)) {
            self.add_match(pos, pos, Annotation::Escape);
            self.add_match(pos + 1, pos + 1, Annotation::Str);
            pos + 2
        } else if pos < endpos && self.byte_at(pos + 1) == b' ' {
            self.add_match(pos, pos, Annotation::Escape);
            self.add_match(pos + 1, pos + 1, Annotation::NonBreakingSpace);
            pos + 2
        } else {
            self.add_match(pos, pos, Annotation::Str);
            pos + 1
        }
    }

    fn match_autolink(&mut self, pos: usize, endpos: usize) -> Option<usize> {
        let s = self.subject;
        if self.byte_at(pos) != b'<' {
            return None;
        }
        let mut p = pos + 1;
        let start = p;
        while p <= endpos && p < s.len() && s[p] != b'<' && s[p] != b'>' && !is_ws_byte(s[p]) {
            p += 1;
        }
        if p == start {
            return None;
        }
        if p > endpos || p >= s.len() || s[p] != b'>' {
            return None;
        }
        let content = &s[start..p];
        let endurl = p;
        let starturl = pos;
        let (o, c) = match autolink_kind_of(content)? {
            AutolinkKind::Email => (Annotation::EmailOpen, Annotation::EmailClose),
            AutolinkKind::Url => (Annotation::UrlOpen, Annotation::UrlClose),
        };
        self.add_match(starturl, starturl, o);
        self.add_match(starturl + 1, endurl.saturating_sub(1), Annotation::Str);
        self.add_match(endurl, endurl, c);
        Some(endurl + 1)
    }

    fn match_left_brace(&mut self, pos: usize, endpos: usize) -> usize {
        if matches_delim_at(self.subject, pos + 1, endpos) {
            self.add_match(pos, pos, Annotation::OpenMarker);
            pos + 1
        } else if self.allow_attributes {
            self.attribute_parser = Some(AttributeParser::new(self.subject));
            self.attribute_start = Some(pos);
            self.attribute_slices = Some(Vec::new());
            pos
        } else {
            self.add_match(pos, pos, Annotation::Str);
            pos + 1
        }
    }

    fn match_colon(&mut self, pos: usize, endpos: usize) -> usize {
        // `:[\w_+-]+:`
        let s = self.subject;
        let mut p = pos + 1;
        let start = p;
        while p <= endpos && p < s.len() && is_symbol_char(s[p]) {
            p += 1;
        }
        if p > start && p <= endpos && p < s.len() && s[p] == b':' {
            self.add_match(pos, p, Annotation::Symb);
            return p + 1;
        }
        self.add_match(pos, pos, Annotation::Str);
        pos + 1
    }

    fn match_period(&mut self, pos: usize, endpos: usize) -> Option<usize> {
        if pos + 2 <= endpos && self.byte_at(pos + 1) == b'.' && self.byte_at(pos + 2) == b'.' {
            self.add_match(pos, pos + 2, Annotation::Ellipses);
            return Some(pos + 3);
        }
        None
    }

    fn is_image_opener(&self, o: &Opener) -> bool {
        o.startpos >= 1 && self.byte_at(o.startpos - 1) == b'!' && !(o.startpos >= 2 && self.byte_at(o.startpos - 2) == b'\\')
    }

    /// Shared tail of a reference link `[..][..]` and an explicit link
    /// `[..](..)`: turn the bracket opener into link/image text.
    fn close_link_text(&mut self, sub_open: Annotation) {
        let bi = OpenerKind::Bracket as usize;
        let oi = self.openers[bi].len() - 1;
        let opener = self.openers[bi][oi];
        let is_image = self.is_image_opener(&opener);
        let o_substartpos = opener.substartpos.unwrap_or(opener.startpos);
        if is_image {
            self.add_image_marker(oi);
            let opener = self.openers[bi][oi];
            self.replace_match(opener.match_index, opener.startpos, opener.endpos, Annotation::ImagetextOpen);
            self.replace_match(opener.sub_match_index, o_substartpos, o_substartpos, Annotation::ImagetextClose);
        } else {
            self.replace_match(opener.match_index, opener.startpos, opener.endpos, Annotation::LinktextOpen);
            self.replace_match(opener.sub_match_index, o_substartpos, o_substartpos, Annotation::LinktextClose);
        }
        let opener = self.openers[bi][oi];
        let subendpos = opener.subendpos.unwrap_or(opener.endpos);
        // Overwrites the second bracket's / the `(`'s "str" placeholder.
        self.replace_match(opener.sub_match_index + 1, subendpos, subendpos, sub_open);
    }

    fn match_right_bracket(&mut self, pos: usize, endpos: usize) -> Option<usize> {
        let bi = OpenerKind::Bracket as usize;
        if self.openers[bi].is_empty() {
            return None;
        }
        let oi = self.openers[bi].len() - 1;
        let opener = self.openers[bi][oi];
        let is_note_ref = self.byte_at(opener.startpos + 1) == b'^';
        if is_note_ref {
            let mut i = self.matches.len() as isize - 1;
            while i > 0 && self.matches[i as usize].start as usize > opener.startpos {
                self.matches.pop();
                i -= 1;
            }
            self.clear_openers(opener.startpos, pos);
            self.matches[i as usize].annot = Annotation::FootnoteReference;
            self.matches[i as usize].end = pos as u32;
            Some(pos + 1)
        } else if opener.link_state == LinkState::ReferenceLink {
            self.str_matches(opener.subendpos.unwrap_or(opener.endpos) + 1, pos.saturating_sub(1));
            self.close_link_text(Annotation::ReferenceOpen);
            self.add_match(pos, pos, Annotation::ReferenceClose);
            let startpos = self.openers[bi][oi].startpos;
            self.clear_openers(startpos, pos);
            Some(pos + 1)
        } else if pos < endpos && self.byte_at(pos + 1) == b'[' {
            self.add_match(pos, pos, Annotation::Str);
            let smi = self.matches.len() - 1;
            self.add_match(pos + 1, pos + 1, Annotation::Str);
            let o = &mut self.openers[bi][oi];
            o.link_state = LinkState::ReferenceLink;
            o.sub_match_index = smi;
            o.substartpos = Some(pos);
            o.subendpos = Some(pos + 1);
            self.clear_openers(opener.startpos + 1, pos.saturating_sub(1));
            Some(pos + 2)
        } else if pos < endpos && self.byte_at(pos + 1) == b'(' {
            self.ops(OpenerKind::Paren).clear();
            self.add_match(pos, pos, Annotation::Str);
            let smi = self.matches.len() - 1;
            self.add_match(pos + 1, pos + 1, Annotation::Str);
            let o = &mut self.openers[bi][oi];
            o.link_state = LinkState::ExplicitLink;
            o.sub_match_index = smi;
            o.substartpos = Some(pos);
            o.subendpos = Some(pos + 1);
            self.destination = true;
            self.clear_openers(opener.startpos + 1, pos.saturating_sub(1));
            Some(pos + 2)
        } else if pos < endpos && self.byte_at(pos + 1) == b'{' {
            // Overwrites the `[`'s "str" placeholder rather than appending.
            self.replace_match(opener.match_index, opener.startpos, opener.endpos, Annotation::SpanOpen);
            self.add_match(pos, pos, Annotation::SpanClose);
            self.clear_openers(opener.startpos, pos);
            Some(pos + 1)
        } else {
            None
        }
    }

    fn match_left_paren(&mut self, pos: usize) -> Option<usize> {
        if !self.destination {
            return None;
        }
        self.add_opener(OpenerKind::Paren, pos, pos, Annotation::Str);
        Some(pos + 1)
    }

    fn match_right_paren(&mut self, pos: usize) -> Option<usize> {
        if !self.destination {
            return None;
        }
        if self.ops(OpenerKind::Paren).pop().is_some() {
            self.add_match(pos, pos, Annotation::Str);
            return Some(pos + 1);
        }
        let bi = OpenerKind::Bracket as usize;
        let opener = *self.openers[bi].last()?;
        if opener.link_state != LinkState::ExplicitLink {
            return None;
        }
        self.str_matches(opener.subendpos.unwrap_or(opener.endpos) + 1, pos.saturating_sub(1));
        self.close_link_text(Annotation::DestinationOpen);
        self.add_match(pos, pos, Annotation::DestinationClose);
        self.destination = false;
        let startpos = self.openers[bi].last().unwrap().startpos;
        self.clear_openers(startpos, pos);
        Some(pos + 1)
    }

    fn match_hyphen(&mut self, pos: usize, endpos: usize) -> usize {
        if self.has_brace(pos) {
            return self.between_matched(
                b'-',
                Annotation::DeleteOpen,
                Annotation::DeleteClose,
                Annotation::Str,
                OpenTest::HasBrace,
                pos,
                endpos,
            );
        }
        let mut ep = pos;
        let mut hyphens: usize = 0;
        while ep <= endpos && self.byte_at(ep) == b'-' {
            ep += 1;
            hyphens += 1;
        }
        if self.byte_at(ep) == b'}' {
            hyphens -= 1;
        }
        if hyphens == 0 {
            self.add_match(pos, pos + 1, Annotation::Str);
            return pos + 2;
        }
        let all_em = hyphens % 3 == 0;
        let all_en = hyphens % 2 == 0;
        let mut p = pos;
        let mut remaining = hyphens;
        while remaining > 0 {
            if all_em {
                self.add_match(p, p + 2, Annotation::EmDash);
                p += 3;
                remaining -= 3;
            } else if all_en {
                self.add_match(p, p + 1, Annotation::EnDash);
                p += 2;
                remaining -= 2;
            } else if remaining >= 3 && (remaining % 2 != 0 || remaining > 4) {
                self.add_match(p, p + 2, Annotation::EmDash);
                p += 3;
                remaining -= 3;
            } else if remaining >= 2 {
                self.add_match(p, p + 1, Annotation::EnDash);
                p += 2;
                remaining -= 2;
            } else {
                self.add_match(p, p, Annotation::Str);
                p += 1;
                remaining -= 1;
            }
        }
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_all(subject: &[u8]) -> Vec<Event> {
        let mut ip = InlineParser::new(subject);
        ip.feed(0, subject.len() - 1);
        ip.get_matches()
    }

    #[test]
    fn plain_text_becomes_one_str_event() {
        let e = feed_all(b"hello");
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].annot, Annotation::Str);
    }

    #[test]
    fn emphasis_and_strong() {
        let e = feed_all(b"*foo bar*");
        assert_eq!(e[0].annot, Annotation::StrongOpen);
        assert_eq!(e.last().unwrap().annot, Annotation::StrongClose);
        let e = feed_all(b"_foo bar_");
        assert_eq!(e[0].annot, Annotation::EmphOpen);
        assert_eq!(e.last().unwrap().annot, Annotation::EmphClose);
    }

    #[test]
    fn verbatim_span() {
        let e = feed_all(b"`code`");
        assert_eq!(e[0].annot, Annotation::VerbatimOpen);
        assert_eq!(e.last().unwrap().annot, Annotation::VerbatimClose);
    }

    #[test]
    fn em_dash_and_en_dash() {
        let e = feed_all(b"a---b--c");
        assert!(e.iter().any(|e| e.annot == Annotation::EmDash));
        assert!(e.iter().any(|e| e.annot == Annotation::EnDash));
    }

    #[test]
    fn explicit_link() {
        let e = feed_all(b"[text](http://example.com)");
        assert!(e.iter().any(|e| e.annot == Annotation::LinktextOpen));
        assert!(e.iter().any(|e| e.annot == Annotation::DestinationOpen));
    }
}
