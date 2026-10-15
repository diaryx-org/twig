//! A small JSON reader and a writer that reproduces Zig's `std.json.Stringify`
//! byte for byte (compact and 2-space-indented), so every JSON surface Twig
//! publishes — `-o ast`, `-o table`, the syntax tables, the wire protocol —
//! prints exactly what the Zig implementation printed.
//!
//! Strings are bytes: a document need not be valid UTF-8, and neither need the
//! text a node carries. The writer passes bytes `>= 0x20` through unescaped
//! (as Zig's does with `escape_unicode` off).

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

impl Parser<'_> {
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
        self.i += 1; // opening quote
        let mut out = Vec::new();
        loop {
            let Some(c) = self.peek() else { return Err(self.err("unterminated string")) };
            self.i += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let Some(e) = self.peek() else { return Err(self.err("unterminated string")) };
                    self.i += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'b' => out.push(8),
                        b'f' => out.push(12),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
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
                            let ch = char::from_u32(cp).unwrap_or('\u{FFFD}');
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return Err(self.err("bad escape")),
                    }
                }
                0x00..=0x1F => return Err(self.err("control character in string")),
                _ => out.push(c),
            }
        }
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
