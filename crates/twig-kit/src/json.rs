//! A small JSON reader and a writer that reproduces Zig's `std.json.Stringify`
//! byte for byte (compact and 2-space-indented), so every JSON surface Twig
//! publishes — `-o ast`, `-o table`, the syntax tables, the wire protocol —
//! prints exactly what the Zig implementation printed.
//!
//! Strings are bytes: a document need not be valid UTF-8, and neither need the
//! text a node carries. The writer passes bytes `>= 0x20` through unescaped
//! (as Zig's does with `escape_unicode` off).

use std::borrow::Cow;
use std::fmt::Write as _;

// ── Writer ──────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Frame {
    Object { any: bool },
    Array { any: bool },
}

/// A streaming JSON writer with Zig's whitespace rules.
pub struct Stringify<'a> {
    pub out: &'a mut Vec<u8>,
    pretty: bool,
    stack: Vec<Frame>,
    /// Set after `field`, so the next value is not preceded by a separator.
    after_field: bool,
}

impl<'a> Stringify<'a> {
    pub fn compact(out: &'a mut Vec<u8>) -> Self {
        Stringify { out, pretty: false, stack: Vec::new(), after_field: false }
    }

    pub fn pretty(out: &'a mut Vec<u8>) -> Self {
        Stringify { out, pretty: true, stack: Vec::new(), after_field: false }
    }

    fn indent(&mut self) {
        if self.pretty {
            self.out.push(b'\n');
            for _ in 0..self.stack.len() {
                self.out.extend_from_slice(b"  ");
            }
        }
    }

    /// Separator before a value inside an array (or top level).
    fn value_start(&mut self) {
        if self.after_field {
            self.after_field = false;
            return;
        }
        if let Some(Frame::Array { any }) = self.stack.last().copied() {
            if any {
                self.out.push(b',');
            }
            *self.stack.last_mut().unwrap() = Frame::Array { any: true };
            self.indent();
        }
    }

    pub fn begin_object(&mut self) {
        self.value_start();
        self.out.push(b'{');
        self.stack.push(Frame::Object { any: false });
    }

    pub fn end_object(&mut self) {
        let f = self.stack.pop();
        if let Some(Frame::Object { any: true }) = f {
            self.indent();
        }
        self.out.push(b'}');
    }

    pub fn begin_array(&mut self) {
        self.value_start();
        self.out.push(b'[');
        self.stack.push(Frame::Array { any: false });
    }

    pub fn end_array(&mut self) {
        let f = self.stack.pop();
        if let Some(Frame::Array { any: true }) = f {
            self.indent();
        }
        self.out.push(b']');
    }

    pub fn field(&mut self, name: &str) {
        if let Some(Frame::Object { any }) = self.stack.last().copied() {
            if any {
                self.out.push(b',');
            }
            *self.stack.last_mut().unwrap() = Frame::Object { any: true };
        }
        self.indent();
        write_string(self.out, name.as_bytes());
        self.out.push(b':');
        if self.pretty {
            self.out.push(b' ');
        }
        self.after_field = true;
    }

    /// A byte string. Valid UTF-8 is written as a JSON string; anything else
    /// as an array of byte values, which is what Zig's `Stringify.write` does
    /// with a `[]const u8` that does not validate.
    pub fn str(&mut self, s: &[u8]) {
        if std::str::from_utf8(s).is_err() {
            self.begin_array();
            for &b in s {
                self.int(b);
            }
            self.end_array();
            return;
        }
        self.value_start();
        write_string(self.out, s);
    }

    pub fn opt_str(&mut self, s: Option<&[u8]>) {
        match s {
            Some(s) => self.str(s),
            None => self.null(),
        }
    }

    pub fn int(&mut self, v: impl Into<i128>) {
        self.value_start();
        let mut s = String::new();
        let _ = write!(s, "{}", v.into());
        self.out.extend_from_slice(s.as_bytes());
    }

    pub fn opt_int(&mut self, v: Option<u32>) {
        match v {
            Some(v) => self.int(v),
            None => self.null(),
        }
    }

    pub fn bool(&mut self, b: bool) {
        self.value_start();
        self.out.extend_from_slice(if b { b"true" } else { b"false" });
    }

    pub fn null(&mut self) {
        self.value_start();
        self.out.extend_from_slice(b"null");
    }

    /// Write an already-encoded JSON value verbatim.
    pub fn raw(&mut self, encoded: &[u8]) {
        self.value_start();
        self.out.extend_from_slice(encoded);
    }

    pub fn value(&mut self, v: &Value) {
        match v {
            Value::Null => self.null(),
            Value::Bool(b) => self.bool(*b),
            Value::Int(i) => self.int(*i),
            Value::Float(f) => {
                self.value_start();
                let mut s = String::new();
                let _ = write!(s, "{}", f);
                self.out.extend_from_slice(s.as_bytes());
            }
            Value::String(s) => self.str(s),
            Value::Array(a) => {
                self.begin_array();
                for x in a {
                    self.value(x);
                }
                self.end_array();
            }
            Value::Object(o) => {
                self.begin_object();
                for (k, x) in o {
                    self.field(&String::from_utf8_lossy(k));
                    self.value(x);
                }
                self.end_object();
            }
        }
    }
}

/// Write `s` as a JSON string literal, Zig's escaping rules.
pub fn write_string(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
    for &c in s {
        match c {
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'"' => out.extend_from_slice(b"\\\""),
            0x08 => out.extend_from_slice(b"\\b"),
            0x0C => out.extend_from_slice(b"\\f"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            0x00..=0x1F => {
                let _ = write!(StrSink(out), "\\u{:04x}", c);
            }
            _ => out.push(c),
        }
    }
    out.push(b'"');
}

struct StrSink<'a>(&'a mut Vec<u8>);
impl std::fmt::Write for StrSink<'_> {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        self.0.extend_from_slice(s.as_bytes());
        Ok(())
    }
}

// ── Reader ──────────────────────────────────────────────────────────────────

/// A parsed JSON value. Object keys keep their order.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(Vec<u8>),
    Array(Vec<Value>),
    Object(Vec<(Vec<u8>, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(o) => o.iter().rev().find(|(k, _)| k == key.as_bytes()).map(|(_, v)| v),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&[u8]> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_str_lossy(&self) -> Option<String> {
        self.as_str().map(|s| String::from_utf8_lossy(s).into_owned())
    }
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(i) => Some(*i),
            _ => None,
        }
    }
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }
    pub fn as_object(&self) -> Option<&[(Vec<u8>, Value)]> {
        match self {
            Value::Object(o) => Some(o),
            _ => None,
        }
    }
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    pub fn to_compact(&self) -> Vec<u8> {
        let mut out = Vec::new();
        Stringify::compact(&mut out).value(self);
        out
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    pub offset: usize,
    pub what: &'static str,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} at byte {}", self.what, self.offset)
    }
}

impl std::error::Error for ParseError {}

/// Check that `text` is one JSON value, refusing exactly what [`parse`]
/// refuses, and hand it back as a [`Raw`] to be read where it lies.
pub fn check(text: &[u8]) -> Result<Raw<'_>, ParseError> {
    let mut p = Parser { s: text, i: 0, depth: 0 };
    p.ws();
    let start = p.i;
    p.skip_value(Gather::Nothing)?;
    let end = p.i;
    p.finish()?;
    Ok(Raw(&text[start..end]))
}

/// [`check`] a text that should be an object whose `key` member is an
/// array of objects — a node table and its `nodes` — gathering as it goes the
/// top object's members and every element's, so that reading it is a walk
/// down two lists rather than another pass over the text.
pub fn check_rows<'a>(text: &'a [u8], key: &str) -> Result<Rows<'a>, ParseError> {
    let mut p = Parser { s: text, i: 0, depth: 0 };
    p.ws();
    let object = p.peek() == Some(b'{');
    let mut top = Vec::new();
    let mut index = RowIndex { key, array: false, members: Vec::new(), rows: Vec::new() };
    p.skip_value(Gather::Table(&mut top, &mut index))?;
    p.finish()?;
    Ok(Rows { top: object.then_some(RawObject { members: top }), array: index.array, members: index.members, rows: index.rows })
}

pub fn parse(text: &[u8]) -> Result<Value, ParseError> {
    let mut p = Parser { s: text, i: 0, depth: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err(p.err("trailing characters after the value"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
    depth: usize,
}

impl<'a> Parser<'a> {
    fn err(&self, what: &'static str) -> ParseError {
        ParseError { offset: self.i, what }
    }
    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }
    fn lit(&mut self, word: &[u8], v: Value) -> Result<Value, ParseError> {
        if self.s[self.i..].starts_with(word) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(self.err("invalid literal"))
        }
    }
    fn value(&mut self) -> Result<Value, ParseError> {
        match self.peek() {
            None => Err(self.err("unexpected end of input")),
            Some(b'n') => self.lit(b"null", Value::Null),
            Some(b't') => self.lit(b"true", Value::Bool(true)),
            Some(b'f') => self.lit(b"false", Value::Bool(false)),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b'[') => {
                self.depth += 1;
                if self.depth > 512 {
                    return Err(self.err("nesting too deep"));
                }
                self.i += 1;
                let mut out = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.i += 1;
                    self.depth -= 1;
                    return Ok(Value::Array(out));
                }
                loop {
                    self.ws();
                    out.push(self.value()?);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(b']') => {
                            self.i += 1;
                            break;
                        }
                        _ => return Err(self.err("expected ',' or ']'")),
                    }
                }
                self.depth -= 1;
                Ok(Value::Array(out))
            }
            Some(b'{') => {
                self.depth += 1;
                if self.depth > 512 {
                    return Err(self.err("nesting too deep"));
                }
                self.i += 1;
                let mut out = Vec::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.i += 1;
                    self.depth -= 1;
                    return Ok(Value::Object(out));
                }
                loop {
                    self.ws();
                    if self.peek() != Some(b'"') {
                        return Err(self.err("expected a string key"));
                    }
                    let k = self.string()?;
                    self.ws();
                    if self.peek() != Some(b':') {
                        return Err(self.err("expected ':'"));
                    }
                    self.i += 1;
                    self.ws();
                    let v = self.value()?;
                    out.push((k, v));
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(b'}') => {
                            self.i += 1;
                            break;
                        }
                        _ => return Err(self.err("expected ',' or '}'")),
                    }
                }
                self.depth -= 1;
                Ok(Value::Object(out))
            }
            Some(c) if c == b'-' || c.is_ascii_digit() => self.number(),
            _ => Err(self.err("unexpected character")),
        }
    }
    fn finish(&mut self) -> Result<(), ParseError> {
        self.ws();
        if self.i != self.s.len() {
            return Err(self.err("trailing characters after the value"));
        }
        Ok(())
    }
    /// [`value`](Self::value)'s twin that builds nothing: it accepts and
    /// refuses the same texts, with the same errors. What it keeps of what it
    /// steps over is `gather`'s to say.
    fn skip_value(&mut self, mut gather: Gather<'_, '_, 'a>) -> Result<(), ParseError> {
        match self.peek() {
            None => Err(self.err("unexpected end of input")),
            Some(b'n') => self.lit(b"null", Value::Null).map(drop),
            Some(b't') => self.lit(b"true", Value::Null).map(drop),
            Some(b'f') => self.lit(b"false", Value::Null).map(drop),
            Some(b'"') => self.string_into::<false>(&mut Vec::new()),
            Some(open @ (b'[' | b'{')) => {
                let close = if open == b'[' { b']' } else { b'}' };
                self.depth += 1;
                if self.depth > 512 {
                    return Err(self.err("nesting too deep"));
                }
                self.i += 1;
                self.ws();
                if self.peek() == Some(close) {
                    self.i += 1;
                    self.depth -= 1;
                    return Ok(());
                }
                loop {
                    self.ws();
                    let mut key = Cow::Borrowed(&b""[..]);
                    if open == b'{' {
                        if self.peek() != Some(b'"') {
                            return Err(self.err("expected a string key"));
                        }
                        let start = self.i;
                        self.string_into::<false>(&mut Vec::new())?;
                        if !matches!(gather, Gather::Nothing) {
                            key = Raw(&self.s[start..self.i]).as_str().unwrap_or_default();
                        }
                        self.ws();
                        if self.peek() != Some(b':') {
                            return Err(self.err("expected ':'"));
                        }
                        self.i += 1;
                        self.ws();
                    }
                    let start = self.i;
                    match (&mut gather, open) {
                        (Gather::Rows(index), b'[') => {
                            if self.peek() == Some(b'{') {
                                let first = index.members.len();
                                self.skip_value(Gather::Members(&mut index.members))?;
                                index.rows.push(Some(first..index.members.len()));
                            } else {
                                self.skip_value(Gather::Nothing)?;
                                index.rows.push(None);
                            }
                        }
                        (Gather::Table(top, index), b'{') if *key == *index.key.as_bytes() => {
                            index.members.clear();
                            index.rows.clear();
                            index.array = self.peek() == Some(b'[');
                            self.skip_value(if index.array { Gather::Rows(index) } else { Gather::Nothing })?;
                            top.push((key, Raw(&self.s[start..self.i])));
                        }
                        (Gather::Members(top) | Gather::Table(top, _), b'{') => {
                            self.skip_value(Gather::Nothing)?;
                            top.push((key, Raw(&self.s[start..self.i])));
                        }
                        _ => self.skip_value(Gather::Nothing)?,
                    }
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(c) if c == close => {
                            self.i += 1;
                            break;
                        }
                        _ if open == b'[' => return Err(self.err("expected ',' or ']'")),
                        _ => return Err(self.err("expected ',' or '}'")),
                    }
                }
                self.depth -= 1;
                Ok(())
            }
            Some(c) if c == b'-' || c.is_ascii_digit() => self.skip_number(),
            _ => Err(self.err("unexpected character")),
        }
    }
    /// [`number`](Self::number) without the conversion where the text is
    /// plainly an integer, which every integer is: a digit string always
    /// reads, as an `i64` or else as an `f64`.
    fn skip_number(&mut self) -> Result<(), ParseError> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let digits = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.i += 1;
        }
        if self.i > digits && !matches!(self.peek(), Some(b'.' | b'e' | b'E' | b'+' | b'-')) {
            return Ok(());
        }
        self.i = start;
        self.number().map(drop)
    }
    fn number(&mut self) -> Result<Value, ParseError> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let mut float = false;
        while let Some(c) = self.peek() {
            match c {
                b'0'..=b'9' => self.i += 1,
                b'.' | b'e' | b'E' | b'+' | b'-' => {
                    float = true;
                    self.i += 1
                }
                _ => break,
            }
        }
        let text = std::str::from_utf8(&self.s[start..self.i]).map_err(|_| self.err("bad number"))?;
        if !float {
            if let Ok(i) = text.parse::<i64>() {
                return Ok(Value::Int(i));
            }
        }
        text.parse::<f64>().map(Value::Float).map_err(|_| self.err("bad number"))
    }
    fn hex4(&mut self) -> Result<u32, ParseError> {
        if self.i + 4 > self.s.len() {
            return Err(self.err("short unicode escape"));
        }
        let t = std::str::from_utf8(&self.s[self.i..self.i + 4]).map_err(|_| self.err("bad unicode escape"))?;
        let v = u32::from_str_radix(t, 16).map_err(|_| self.err("bad unicode escape"))?;
        self.i += 4;
        Ok(v)
    }
    fn string(&mut self) -> Result<Vec<u8>, ParseError> {
        let mut out = Vec::new();
        self.string_into::<true>(&mut out)?;
        Ok(out)
    }
    /// Read a string literal, unescaped onto `out` when `KEEP`; without, only
    /// checked.
    fn string_into<const KEEP: bool>(&mut self, out: &mut Vec<u8>) -> Result<(), ParseError> {
        self.i += 1; // opening quote
        loop {
            let run = self.i;
            while self.s.get(self.i).is_some_and(|&c| c != b'"' && c != b'\\' && c >= 0x20) {
                self.i += 1;
            }
            if KEEP {
                out.extend_from_slice(&self.s[run..self.i]);
            }
            let Some(c) = self.peek() else { return Err(self.err("unterminated string")) };
            self.i += 1;
            let unescaped = match c {
                b'"' => return Ok(()),
                b'\\' => {
                    let Some(e) = self.peek() else { return Err(self.err("unterminated string")) };
                    self.i += 1;
                    match e {
                        b'"' => b'"',
                        b'\\' => b'\\',
                        b'/' => b'/',
                        b'b' => 8,
                        b'f' => 12,
                        b'n' => b'\n',
                        b'r' => b'\r',
                        b't' => b'\t',
                        b'u' => {
                            let mut cp = self.hex4()?;
                            if (0xD800..0xDC00).contains(&cp) && self.s[self.i..].starts_with(b"\\u") {
                                let save = self.i;
                                self.i += 2;
                                let lo = self.hex4()?;
                                if (0xDC00..0xE000).contains(&lo) {
                                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                } else {
                                    self.i = save;
                                }
                            }
                            if KEEP {
                                let ch = char::from_u32(cp).unwrap_or('\u{FFFD}');
                                let mut buf = [0u8; 4];
                                out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                            }
                            continue;
                        }
                        _ => return Err(self.err("bad escape")),
                    }
                }
                0x00..=0x1F => return Err(self.err("control character in string")),
                _ => c,
            };
            if KEEP {
                out.push(unescaped);
            }
        }
    }
}

type Member<'a> = (Cow<'a, [u8]>, Raw<'a>);

/// What [`Parser::skip_value`] keeps of the value it steps over.
enum Gather<'g, 'k, 'a> {
    Nothing,
    /// An object's members.
    Members(&'g mut Vec<Member<'a>>),
    /// An array's elements, each object's members.
    Rows(&'g mut RowIndex<'k, 'a>),
    /// An object's members, and its `key` member's elements as `Rows` does.
    Table(&'g mut Vec<Member<'a>>, &'g mut RowIndex<'k, 'a>),
}

struct RowIndex<'k, 'a> {
    key: &'k str,
    array: bool,
    members: Vec<Member<'a>>,
    rows: Vec<Option<std::ops::Range<usize>>>,
}

/// What [`check_rows`] gathered.
pub struct Rows<'a> {
    /// The top object's members; `None` when the text is not an object.
    pub top: Option<RawObject<'a>>,
    array: bool,
    members: Vec<Member<'a>>,
    rows: Vec<Option<std::ops::Range<usize>>>,
}

impl<'a> Rows<'a> {
    /// Each element of the last `key` member, as an object when it is one;
    /// `None` when that member is not an array.
    pub fn rows(&self) -> Option<impl Iterator<Item = Option<&[Member<'a>]>> + Clone> {
        self.array.then(|| self.rows.iter().map(|r| r.clone().map(|r| &self.members[r])))
    }
}

// ── Reading in place ────────────────────────────────────────────────────────

/// One value of a text [`check`] accepted, still as its bytes. It is read
/// where it lies, so reading a table out of it allocates for what the table
/// keeps and nothing else; a [`Value`] is an allocation per string, key and
/// container before anything is read.
#[derive(Clone, Copy, Debug)]
pub struct Raw<'a>(&'a [u8]);

/// A cursor over bytes [`check`] has accepted. Nothing it reads can be
/// malformed, so nothing it does fails.
#[derive(Clone)]
struct Cursor<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Cursor<'a> {
    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    /// Step over the value at the cursor and return its bytes.
    fn value(&mut self) -> Raw<'a> {
        let start = self.i;
        match self.s[self.i] {
            b'"' => self.skip_string(),
            b'[' | b'{' => {
                let mut depth = 0usize;
                loop {
                    match self.s[self.i] {
                        b'"' => {
                            self.skip_string();
                            continue;
                        }
                        b'[' | b'{' => depth += 1,
                        b']' | b'}' => {
                            depth -= 1;
                            if depth == 0 {
                                self.i += 1;
                                break;
                            }
                        }
                        _ => {}
                    }
                    self.i += 1;
                }
            }
            _ => {
                let rest = &self.s[self.i..];
                self.i += rest
                    .iter()
                    .position(|c| matches!(c, b',' | b']' | b'}' | b' ' | b'\t' | b'\n' | b'\r'))
                    .unwrap_or(rest.len());
            }
        }
        Raw(&self.s[start..self.i])
    }
    fn skip_string(&mut self) {
        self.i += 1;
        loop {
            self.i += self.s[self.i..].iter().position(|&c| c == b'"' || c == b'\\').unwrap_or(0);
            if self.s[self.i] == b'"' {
                break;
            }
            self.i += 2;
        }
        self.i += 1;
    }
    /// After an opening bracket or a value inside one: whether another
    /// element follows, the cursor left on it.
    fn more(&mut self) -> bool {
        self.ws();
        match self.s.get(self.i) {
            Some(b',') => {
                self.i += 1;
                self.ws();
                true
            }
            Some(b'[' | b'{') => {
                self.i += 1;
                self.ws();
                !matches!(self.s[self.i], b']' | b'}')
            }
            _ => false,
        }
    }
    /// The members of the object at the cursor, which is left after it.
    fn members(&mut self) -> RawObject<'a> {
        let mut members = Vec::new();
        let mut open = self.more();
        while open {
            let key = self.value().as_str().unwrap_or_default();
            self.ws();
            self.i += 1; // ':'
            self.ws();
            members.push((key, self.value()));
            open = self.more();
        }
        self.i += 1; // '}'
        RawObject { members }
    }
}

impl<'a> Raw<'a> {
    pub fn is_null(self) -> bool {
        self.0 == b"null"
    }
    pub fn as_bool(self) -> Option<bool> {
        match self.0 {
            b"true" => Some(true),
            b"false" => Some(false),
            _ => None,
        }
    }
    /// What [`Value::as_int`] answers for the same text.
    pub fn as_int(self) -> Option<i64> {
        // Up to 18 digits cannot overflow, and are all a table's numbers.
        let (neg, digits) = match self.0 {
            [b'-', rest @ ..] => (true, rest),
            all => (false, all),
        };
        if !digits.is_empty() && digits.len() <= 18 && digits.iter().all(u8::is_ascii_digit) {
            let n = digits.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0'));
            return Some(if neg { -n } else { n });
        }
        match self.0.first() {
            Some(c) if *c == b'-' || c.is_ascii_digit() => {
                match (Parser { s: self.0, i: 0, depth: 0 }).number() {
                    Ok(Value::Int(i)) => Some(i),
                    _ => None,
                }
            }
            _ => None,
        }
    }
    /// The string's bytes, unescaped: borrowed from the text unless it has an
    /// escape to undo.
    pub fn as_str(self) -> Option<Cow<'a, [u8]>> {
        if self.0.first() != Some(&b'"') {
            return None;
        }
        let inner = &self.0[1..self.0.len() - 1];
        if !inner.contains(&b'\\') {
            return Some(Cow::Borrowed(inner));
        }
        let mut out = Vec::with_capacity(inner.len());
        let _ = (Parser { s: self.0, i: 0, depth: 0 }).string_into::<true>(&mut out);
        Some(Cow::Owned(out))
    }
    /// An array's elements, in order.
    pub fn items(self) -> Option<Items<'a>> {
        if self.0.first() != Some(&b'[') {
            return None;
        }
        let mut c = Cursor { s: self.0, i: 0 };
        let open = c.more();
        Some(Items { c, open })
    }
    /// An object's members, in order, duplicates kept.
    pub fn object(self) -> Option<RawObject<'a>> {
        if self.0.first() != Some(&b'{') {
            return None;
        }
        Some(Cursor { s: self.0, i: 0 }.members())
    }
}

#[derive(Clone)]
pub struct Items<'a> {
    c: Cursor<'a>,
    open: bool,
}

impl<'a> Iterator for Items<'a> {
    type Item = Raw<'a>;
    fn next(&mut self) -> Option<Raw<'a>> {
        if !self.open {
            return None;
        }
        let v = self.c.value();
        self.open = self.c.more();
        Some(v)
    }
}

/// What a reader of JSON asks of a value, answered alike by a parsed
/// [`Value`] and by a [`Raw`] text, so one reader serves both.
pub trait Json<'a>: Copy {
    type Object: Object<'a, Json = Self>;
    type Items: Iterator<Item = Self> + Clone;
    fn object(self) -> Option<Self::Object>;
    fn items(self) -> Option<Self::Items>;
    fn is_null(self) -> bool;
    fn as_int(self) -> Option<i64>;
    fn as_bool(self) -> Option<bool>;
    fn as_str(self) -> Option<Cow<'a, [u8]>>;
}

/// An object's members, as [`Value::get`] reads them: of two members with
/// one key, the later.
pub trait Object<'a> {
    type Json: Json<'a>;
    fn get(&self, key: &str) -> Option<Self::Json>;
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    /// The `i`th member, in the order written.
    fn member(&self, i: usize) -> (Cow<'a, [u8]>, Self::Json);
}

impl<'a> Json<'a> for &'a Value {
    type Object = &'a [(Vec<u8>, Value)];
    type Items = std::slice::Iter<'a, Value>;
    fn object(self) -> Option<Self::Object> {
        self.as_object()
    }
    fn items(self) -> Option<Self::Items> {
        self.as_array().map(|a| a.iter())
    }
    fn is_null(self) -> bool {
        Value::is_null(self)
    }
    fn as_int(self) -> Option<i64> {
        Value::as_int(self)
    }
    fn as_bool(self) -> Option<bool> {
        Value::as_bool(self)
    }
    fn as_str(self) -> Option<Cow<'a, [u8]>> {
        Value::as_str(self).map(Cow::Borrowed)
    }
}

impl<'a> Object<'a> for &'a [(Vec<u8>, Value)] {
    type Json = &'a Value;
    fn get(&self, key: &str) -> Option<&'a Value> {
        self.iter().rev().find(|(k, _)| k == key.as_bytes()).map(|(_, v)| v)
    }
    fn len(&self) -> usize {
        <[_]>::len(self)
    }
    fn member(&self, i: usize) -> (Cow<'a, [u8]>, &'a Value) {
        let (k, v) = &self[i];
        (Cow::Borrowed(k), v)
    }
}

/// A [`Raw`] object's members, gathered once so that each `get` is a look
/// down a short list rather than a scan of the text.
pub struct RawObject<'a> {
    members: Vec<(Cow<'a, [u8]>, Raw<'a>)>,
}

impl<'a> Json<'a> for Raw<'a> {
    type Object = RawObject<'a>;
    type Items = Items<'a>;
    fn object(self) -> Option<RawObject<'a>> {
        Raw::object(self)
    }
    fn items(self) -> Option<Items<'a>> {
        Raw::items(self)
    }
    fn is_null(self) -> bool {
        Raw::is_null(self)
    }
    fn as_int(self) -> Option<i64> {
        Raw::as_int(self)
    }
    fn as_bool(self) -> Option<bool> {
        Raw::as_bool(self)
    }
    fn as_str(self) -> Option<Cow<'a, [u8]>> {
        Raw::as_str(self)
    }
}

impl<'a> Object<'a> for RawObject<'a> {
    type Json = Raw<'a>;
    fn get(&self, key: &str) -> Option<Raw<'a>> {
        Object::get(&self.members.as_slice(), key)
    }
    fn len(&self) -> usize {
        self.members.len()
    }
    fn member(&self, i: usize) -> (Cow<'a, [u8]>, Raw<'a>) {
        self.members[i].clone()
    }
}

impl<'a> Object<'a> for &[Member<'a>] {
    type Json = Raw<'a>;
    fn get(&self, key: &str) -> Option<Raw<'a>> {
        self.iter().rev().find(|(k, _)| **k == *key.as_bytes()).map(|(_, v)| *v)
    }
    fn len(&self) -> usize {
        <[_]>::len(self)
    }
    fn member(&self, i: usize) -> (Cow<'a, [u8]>, Raw<'a>) {
        self[i].clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pretty_matches_zig_shape() {
        let mut out = Vec::new();
        let mut w = Stringify::pretty(&mut out);
        w.begin_object();
        w.field("kind");
        w.str(b"doc");
        w.field("span");
        w.begin_array();
        w.int(0);
        w.int(27);
        w.end_array();
        w.field("e");
        w.begin_array();
        w.end_array();
        w.end_object();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "{\n  \"kind\": \"doc\",\n  \"span\": [\n    0,\n    27\n  ],\n  \"e\": []\n}"
        );
    }

    #[test]
    fn compact_and_escapes() {
        let mut out = Vec::new();
        let mut w = Stringify::compact(&mut out);
        w.begin_object();
        w.field("a");
        w.str(b"x\"\n\x01\xc3\xa9");
        w.field("b");
        w.null();
        w.end_object();
        assert_eq!(out, b"{\"a\":\"x\\\"\\n\\u0001\xc3\xa9\",\"b\":null}");
    }

    #[test]
    fn invalid_utf8_is_an_array() {
        let mut out = Vec::new();
        let mut w = Stringify::compact(&mut out);
        w.str(b"a\xff");
        assert_eq!(out, b"[97,255]");
    }

    #[test]
    fn parse_roundtrip() {
        let input = "{\"a\":[1,2,{\"b\":null}],\"c\":\"\\u00e9\\ud83d\\ude00\",\"d\":true}";
        let v = parse(input.as_bytes()).unwrap();
        assert_eq!(v.get("c").unwrap().as_str().unwrap(), "é😀".as_bytes());
        assert_eq!(v.to_compact(), "{\"a\":[1,2,{\"b\":null}],\"c\":\"é😀\",\"d\":true}".as_bytes());
    }
}
