//! Parser for the `{#id .class key=val key="value"}` attribute shorthand that
//! trails a generic directive (`inline.rs`'s text directives, `block.rs`'s
//! leaf/container directives). Port of `attributes.zig`. This is the Markdown
//! module's OWN parser — it deliberately does NOT reuse djot's. A directive's
//! attributes always sit on a single line, so this is a plain one-shot scan.
//!
//! ```text
//! attributes <- '{' (ws* attribute)* ws* '}'
//! attribute  <- '#' name          # id
//!             | '.' name           # class (accumulates, space-joined)
//!             | name ('=' value)?  # key, or key=value ("" if bare)
//! name       <- (alnum | '-' | '_' | ':')+
//! value      <- '"' (! '"' | '\\"')* '"' | (! ws | '}' | '"')+
//! ```
//!
//! Results follow the shared `Attrs` convention: ORDER-PRESERVING, `class`
//! accumulates at its first occurrence and `id`/other keys are
//! last-write-wins.

use crate::ast::KeyVal;

/// A successfully-parsed attribute block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parsed {
    pub entries: Vec<KeyVal>,
    /// Byte index of the opening `{` (relative to the `text` handed to
    /// `parse`, NOT to the whole source).
    pub start: usize,
    /// Byte index just past the closing `}`.
    pub end: usize,
}

fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b':'
}

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

/// A directive name: an ASCII letter followed by name characters. Returns the
/// index just past the name, or `None` if `text[start]` can't begin one.
pub fn scan_name(text: &[u8], start: usize) -> Option<usize> {
    if start >= text.len() || !text[start].is_ascii_alphabetic() {
        return None;
    }
    let mut i = start + 1;
    while i < text.len() && is_name_char(text[i]) {
        i += 1;
    }
    Some(i)
}

#[derive(Default)]
struct Accumulator {
    entries: Vec<KeyVal>,
}

impl Accumulator {
    fn find(&self, key: &[u8]) -> Option<usize> {
        self.entries.iter().position(|kv| kv.key == key)
    }

    /// Set `key` to `value`, last-write-wins if the key already exists.
    fn set(&mut self, key: &[u8], value: Option<&[u8]>) {
        if let Some(idx) = self.find(key) {
            self.entries[idx].value = value.map(|v| v.to_vec());
            return;
        }
        self.entries.push(KeyVal::new(key, value));
    }

    /// Append `cls` to the `class` entry (space-joined at its first
    /// occurrence), creating it if absent.
    fn add_class(&mut self, cls: &[u8]) {
        if let Some(idx) = self.find(b"class") {
            let old = self.entries[idx].value.clone().unwrap_or_default();
            let mut joined = old;
            joined.push(b' ');
            joined.extend_from_slice(cls);
            self.entries[idx].value = Some(joined);
            return;
        }
        self.set(b"class", Some(cls));
    }
}

/// Parse an attribute block whose opening `{` is at `text[start]`. Returns
/// `None` if `text[start]` is not `{` or the block is malformed /
/// unterminated — the caller then treats the `{` as literal text.
pub fn parse(text: &[u8], start: usize) -> Option<Parsed> {
    if start >= text.len() || text[start] != b'{' {
        return None;
    }
    let mut acc = Accumulator::default();
    let mut i = start + 1;
    while i < text.len() {
        let c = text[i];
        if is_space(c) {
            i += 1;
            continue;
        }
        if c == b'}' {
            return Some(Parsed { entries: acc.entries, start, end: i + 1 });
        }
        if c == b'#' {
            let name_end = scan_name_loose(text, i + 1);
            if name_end == i + 1 {
                return None;
            }
            acc.set(b"id", Some(&text[i + 1..name_end]));
            i = name_end;
            continue;
        }
        if c == b'.' {
            let name_end = scan_name_loose(text, i + 1);
            if name_end == i + 1 {
                return None;
            }
            acc.add_class(&text[i + 1..name_end]);
            i = name_end;
            continue;
        }
        if is_name_char(c) {
            let key_end = scan_name_loose(text, i);
            let key = &text[i..key_end];
            i = key_end;
            if i < text.len() && text[i] == b'=' {
                i += 1;
                let (v, end) = scan_value(text, i)?;
                acc.set(key, Some(&v));
                i = end;
            } else {
                // Bare key (`{disabled}`): value "" (matches remark).
                acc.set(key, Some(b""));
            }
            continue;
        }
        return None;
    }
    None
}

/// An id/class/key name run (possibly empty), no leading-letter requirement.
fn scan_name_loose(text: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < text.len() && is_name_char(text[i]) {
        i += 1;
    }
    i
}

/// A value after `=`: a `"`-quoted string (with `\"`/`\\` escapes decoded) or
/// a bare run up to whitespace/`}`/`"`. `None` if a quoted value is
/// unterminated.
fn scan_value(text: &[u8], start: usize) -> Option<(Vec<u8>, usize)> {
    if start < text.len() && text[start] == b'"' {
        let mut out = Vec::new();
        let mut i = start + 1;
        while i < text.len() {
            let c = text[i];
            if c == b'"' {
                return Some((out, i + 1));
            }
            if c == b'\\' && i + 1 < text.len() && (text[i + 1] == b'"' || text[i + 1] == b'\\') {
                out.push(text[i + 1]);
                i += 2;
                continue;
            }
            out.push(c);
            i += 1;
        }
        return None;
    }
    let mut i = start;
    while i < text.len() && !is_space(text[i]) && text[i] != b'}' && text[i] != b'"' {
        i += 1;
    }
    Some((text[start..i].to_vec(), i))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attr<'a>(p: &'a Parsed, key: &[u8]) -> Option<&'a [u8]> {
        p.entries.iter().find(|kv| kv.key == key).and_then(|kv| kv.value.as_deref())
    }

    #[test]
    fn id_classes_keyvals_classes_accumulate() {
        let subject = b"{#hero .a .b key=val other=\"a b\"}";
        let p = parse(subject, 0).unwrap();
        assert_eq!(p.end, subject.len());
        assert_eq!(attr(&p, b"id"), Some(&b"hero"[..]));
        assert_eq!(attr(&p, b"class"), Some(&b"a b"[..]));
        assert_eq!(attr(&p, b"key"), Some(&b"val"[..]));
        assert_eq!(attr(&p, b"other"), Some(&b"a b"[..]));
    }

    #[test]
    fn shorthand_chaining() {
        let p = parse(b"{#x.a.b}", 0).unwrap();
        assert_eq!(attr(&p, b"id"), Some(&b"x"[..]));
        assert_eq!(attr(&p, b"class"), Some(&b"a b"[..]));
    }

    #[test]
    fn bare_key_is_empty_string() {
        let p = parse(b"{disabled}", 0).unwrap();
        assert_eq!(attr(&p, b"disabled"), Some(&b""[..]));
    }

    #[test]
    fn quoted_value_with_escaped_quote() {
        let p = parse(b"{title=\"a \\\"b\\\" c\"}", 0).unwrap();
        assert_eq!(attr(&p, b"title"), Some(&b"a \"b\" c"[..]));
    }

    #[test]
    fn last_write_wins() {
        let p = parse(b"{#a #b k=1 k=2}", 0).unwrap();
        assert_eq!(attr(&p, b"id"), Some(&b"b"[..]));
        assert_eq!(attr(&p, b"k"), Some(&b"2"[..]));
    }

    #[test]
    fn unterminated_fail_cleanly() {
        assert_eq!(parse(b"{#a .b", 0), None);
        assert_eq!(parse(b"{k=\"oops}", 0), None);
        assert_eq!(parse(b"not an attr", 0), None);
    }

    #[test]
    fn empty_block() {
        let p = parse(b"{}", 0).unwrap();
        assert!(p.entries.is_empty());
        assert_eq!(p.end, 2);
    }
}
