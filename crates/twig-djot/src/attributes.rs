//! Parser for `{...}` attribute blocks, implemented as an incremental state
//! machine. Ported from djot.js's `src/attributes.ts`.
//!
//! ```text
//! attributes <- '{' whitespace* attribute (whitespace attribute)* whitespace* '}'
//! attribute  <- identifier | class | keyval
//! identifier <- '#' name
//! class      <- '.' name
//! keyval     <- key '=' val
//! val        <- bareval | quotedval
//! ```
//!
//! `feed` is incremental: it may be called with successive slices of the
//! subject (one per continuation line of a multi-line block attribute, or one
//! per chunk from the inline scanner) and picks up state across calls.

use super::event::{Annotation, Event, EventList};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Done,
    Fail,
    Continue,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FeedResult {
    pub status: Status,
    pub position: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Start,
    Scanning,
    ScanningId,
    ScanningClass,
    ScanningKey,
    ScanningValue,
    ScanningBareValue,
    ScanningQuotedValue,
    ScanningQuotedValueContinuation,
    ScanningEscaped,
    ScanningEscapedInContinuation,
    ScanningComment,
    Fail,
    Done,
}

pub struct AttributeParser<'s> {
    pub subject: &'s [u8],
    state: State,
    begin: Option<usize>,
    lastpos: Option<usize>,
    pub matches: EventList,
}

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

fn is_key_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b':' || c == b'-'
}

/// SCANNING_ID's allowed char set: anything but `][~!@#$%^&*(){}`,.<>\|=+/?`
/// or whitespace.
fn is_id_char(c: u8) -> bool {
    if is_space(c) {
        return false;
    }
    !matches!(
        c,
        b']' | b'[' | b'~' | b'!' | b'@' | b'#' | b'$' | b'%' | b'^' | b'&' | b'*' | b'(' | b')' | b'{' | b'}'
            | b'`' | b',' | b'.' | b'<' | b'>' | b'\\' | b'|' | b'=' | b'+' | b'/' | b'?'
    )
}

fn is_class_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'-' || c == b':'
}

impl<'s> AttributeParser<'s> {
    pub fn new(subject: &'s [u8]) -> Self {
        AttributeParser { subject, state: State::Start, begin: None, lastpos: None, matches: Vec::new() }
    }

    fn byte_at(&self, pos: usize) -> u8 {
        if pos < self.subject.len() { self.subject[pos] } else { 0 }
    }

    fn add_event(&mut self, start: usize, end: usize, annot: Annotation) {
        self.matches.push(Event::new(start as u32, end as u32, annot));
    }

    /// Feed the parser `[start, end]` inclusive. For `Done`, the position of
    /// the closing `}`; for `Fail`, the first unparseable position; for
    /// `Continue`, `end`.
    pub fn feed(&mut self, start: usize, end: usize) -> FeedResult {
        let mut pos = start;
        while pos <= end {
            self.state = self.step(pos);
            match self.state {
                State::Done => return FeedResult { status: Status::Done, position: pos },
                State::Fail => {
                    self.lastpos = Some(pos);
                    return FeedResult { status: Status::Fail, position: pos };
                }
                _ => {
                    self.lastpos = Some(pos);
                    pos += 1;
                }
            }
        }
        FeedResult { status: Status::Continue, position: end }
    }

    fn step(&mut self, pos: usize) -> State {
        let c = self.byte_at(pos);
        match self.state {
            State::Start => {
                if c == b'{' {
                    State::Scanning
                } else {
                    State::Fail
                }
            }
            State::Fail => State::Fail,
            State::Done => State::Done,

            State::Scanning => {
                if c == b'\n' || c == b'\r' {
                    State::Scanning
                } else if c == b' ' || c == b'\t' {
                    self.add_event(pos, pos, Annotation::AttrSpace);
                    State::Scanning
                } else if c == b'}' {
                    State::Done
                } else if c == b'#' {
                    self.begin = Some(pos);
                    self.add_event(pos, pos, Annotation::AttrIdMarker);
                    State::ScanningId
                } else if c == b'%' {
                    self.begin = Some(pos);
                    State::ScanningComment
                } else if c == b'.' {
                    self.begin = Some(pos);
                    self.add_event(pos, pos, Annotation::AttrClassMarker);
                    State::ScanningClass
                } else if is_key_char(c) {
                    self.begin = Some(pos);
                    State::ScanningKey
                } else {
                    State::Fail
                }
            }

            State::ScanningComment => {
                if c == b'%' {
                    if let Some(b) = self.begin {
                        if pos > b {
                            self.add_event(b, pos, Annotation::Comment);
                        }
                    }
                    State::Scanning
                } else if c == b'}' {
                    State::Done
                } else {
                    State::ScanningComment
                }
            }

            State::ScanningId | State::ScanningClass => {
                let (ok, annot) = if self.state == State::ScanningId {
                    (is_id_char(c), Annotation::Id)
                } else {
                    (is_class_char(c), Annotation::Class)
                };
                if ok {
                    self.state
                } else if c == b'}' {
                    self.emit_name(annot);
                    self.begin = None;
                    State::Done
                } else if is_space(c) {
                    self.emit_name(annot);
                    if !(c == b'\r' || c == b'\n') {
                        self.add_event(pos, pos, Annotation::AttrSpace);
                    }
                    self.begin = None;
                    State::Scanning
                } else {
                    State::Fail
                }
            }

            State::ScanningKey => {
                if c == b'=' && self.begin.is_some() && self.lastpos.is_some() {
                    self.add_event(self.begin.unwrap(), self.lastpos.unwrap(), Annotation::Key);
                    self.add_event(pos, pos, Annotation::AttrEqualMarker);
                    self.begin = None;
                    State::ScanningValue
                } else if is_key_char(c) {
                    State::ScanningKey
                } else {
                    State::Fail
                }
            }

            State::ScanningValue => {
                if c == b'"' {
                    self.begin = Some(pos);
                    self.add_event(pos, pos, Annotation::AttrQuoteMarker);
                    State::ScanningQuotedValue
                } else if is_key_char(c) {
                    self.begin = Some(pos);
                    State::ScanningBareValue
                } else {
                    State::Fail
                }
            }

            State::ScanningBareValue => {
                if is_key_char(c) {
                    State::ScanningBareValue
                } else if c == b'}' && self.begin.is_some() && self.lastpos.is_some() {
                    self.add_event(self.begin.unwrap(), self.lastpos.unwrap(), Annotation::Value);
                    self.begin = None;
                    State::Done
                } else if is_space(c) && self.begin.is_some() && self.lastpos.is_some() {
                    self.add_event(self.begin.unwrap(), self.lastpos.unwrap(), Annotation::Value);
                    if !(c == b'\r' || c == b'\n') {
                        self.add_event(pos, pos, Annotation::AttrSpace);
                    }
                    self.begin = None;
                    State::Scanning
                } else {
                    State::Fail
                }
            }

            State::ScanningEscaped => State::ScanningQuotedValue,
            State::ScanningEscapedInContinuation => State::ScanningQuotedValueContinuation,

            State::ScanningQuotedValue => {
                if c == b'"' && self.begin.is_some() && self.lastpos.is_some() {
                    self.add_event(self.begin.unwrap() + 1, self.lastpos.unwrap(), Annotation::Value);
                    self.add_event(pos, pos, Annotation::AttrQuoteMarker);
                    self.begin = None;
                    State::Scanning
                } else if c == b'\n' && self.begin.is_some() {
                    self.add_event(self.begin.unwrap() + 1, pos, Annotation::Value);
                    self.begin = None;
                    State::ScanningQuotedValueContinuation
                } else if c == b'\\' {
                    State::ScanningEscaped
                } else {
                    State::ScanningQuotedValue
                }
            }

            State::ScanningQuotedValueContinuation => {
                if self.begin.is_none() {
                    self.begin = Some(pos);
                }
                let begin = self.begin.unwrap();
                if c == b'"' && self.lastpos.is_some() {
                    self.add_event(pos, pos, Annotation::AttrQuoteMarker);
                    self.add_event(begin, self.lastpos.unwrap(), Annotation::Value);
                    self.begin = None;
                    State::Scanning
                } else if c == b'\n' && self.lastpos.is_some() {
                    self.add_event(begin, pos, Annotation::Value);
                    self.begin = None;
                    State::ScanningQuotedValueContinuation
                } else if c == b'\\' {
                    State::ScanningEscapedInContinuation
                } else {
                    State::ScanningQuotedValueContinuation
                }
            }
        }
    }

    fn emit_name(&mut self, annot: Annotation) {
        if let (Some(b), Some(lp)) = (self.begin, self.lastpos) {
            if lp > b {
                self.add_event(b + 1, lp, annot);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_all(subject: &[u8]) -> AttributeParser<'_> {
        let mut p = AttributeParser::new(subject);
        let res = p.feed(0, subject.len() - 1);
        assert_eq!(res.status, Status::Done);
        p
    }

    #[test]
    fn parses_classes_id_and_bare_quoted_keyvals() {
        let p = parse_all(b"{.foo #bar key=\"val\" other=baz}");
        let (mut fc, mut fi, mut fk, mut fo) = (false, false, false, false);
        for m in &p.matches {
            let text = &p.subject[m.start as usize..m.end as usize + 1];
            match m.annot {
                Annotation::Class => {
                    assert_eq!(text, b"foo");
                    fc = true;
                }
                Annotation::Id => {
                    assert_eq!(text, b"bar");
                    fi = true;
                }
                Annotation::Key => {
                    if text == b"key" {
                        fk = true;
                    }
                    if text == b"other" {
                        fo = true;
                    }
                }
                _ => {}
            }
        }
        assert!(fc && fi && fk && fo);
    }

    #[test]
    fn multi_line_quoted_value_continuation() {
        let subject = b"{key=\"a\nb\"}";
        let mut p = AttributeParser::new(subject);
        let res = p.feed(0, subject.len() - 1);
        assert_eq!(res.status, Status::Done);
        let values: Vec<&[u8]> = p
            .matches
            .iter()
            .filter(|m| m.annot == Annotation::Value)
            .map(|m| &subject[m.start as usize..m.end as usize + 1])
            .collect();
        assert_eq!(values, vec![&b"a\n"[..], &b"b"[..]]);
    }

    #[test]
    fn empty_id_dropped_malformed_fails() {
        let subject = b"{.foo #}";
        let mut p = AttributeParser::new(subject);
        assert_eq!(p.feed(0, subject.len() - 1).status, Status::Done);
        let subject2 = b"{.foo )bar}";
        let mut p2 = AttributeParser::new(subject2);
        assert_eq!(p2.feed(0, subject2.len() - 1).status, Status::Fail);
    }

    #[test]
    fn incremental_feed_across_chunk_boundaries() {
        let subject = b"{.a\n.b}";
        let mut p = AttributeParser::new(subject);
        assert_eq!(p.feed(0, 2).status, Status::Continue);
        assert_eq!(p.feed(3, 3).status, Status::Continue);
        assert_eq!(p.feed(4, subject.len() - 1).status, Status::Done);
        assert_eq!(p.matches.iter().filter(|m| m.annot == Annotation::Class).count(), 2);
    }
}
