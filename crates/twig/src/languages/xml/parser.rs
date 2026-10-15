//! Source -> `Ast`, recursive-descent over well-formed XML 1.0 (no external
//! DTD processing — internal subsets are skipped over as opaque bytes, never
//! interpreted, so no custom entities beyond the five predefined ones plus
//! numeric character references). Port of `src/languages/xml/parser.zig`.
//!
//! XML's nesting is fully explicit in the source, so a plain recursive
//! descent whose call stack mirrors the element nesting can hand children to
//! the builder's batch `add_container` the moment a close tag is found. Each
//! `parse_x` function returns a finished `NodeId` with its children attached.
//!
//! XML is strict: anything that doesn't fit the grammar is a hard parse
//! error ([`Error`]), not a best-effort recovery — paired with a
//! [`Diagnostic`] (a byte offset plus a static message) so callers can point
//! an editor at the exact failure. Construct a [`Parser`] directly (rather
//! than only going through `xml::parse`) to read `.diagnostic` after a failed
//! `.parse()`.

use std::fmt;

use crate::ast::{compact, Attrs, Builder, Container, KeyVal, Kind, MarkupLeafKind, NodeId};
use crate::document::{ContainerOrigin, Document, Spelling};
use crate::span::Span;

/// A parse failure's location and a static explanation. `offset` is a byte
/// index into the source the failing `Parser` was constructed with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub offset: usize,
    pub message: &'static str,
}

/// `MalformedXml` is the catch-all for the many single-occurrence grammar
/// violations (bad name syntax, missing `=`, unquoted attribute value, ...);
/// the rest are pulled out because callers plausibly want to distinguish them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    MalformedXml,
    MismatchedCloseTag,
    UnclosedElement,
    DuplicateAttribute,
    UnknownEntity,
    TextOutsideRoot,
    MultipleRoots,
    MissingRoot,
}

impl Error {
    /// The Zig error name (`@errorName`).
    pub fn name(self) -> &'static str {
        match self {
            Error::MalformedXml => "MalformedXml",
            Error::MismatchedCloseTag => "MismatchedCloseTag",
            Error::UnclosedElement => "UnclosedElement",
            Error::DuplicateAttribute => "DuplicateAttribute",
            Error::UnknownEntity => "UnknownEntity",
            Error::TextOutsideRoot => "TextOutsideRoot",
            Error::MultipleRoots => "MultipleRoots",
            Error::MissingRoot => "MissingRoot",
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl std::error::Error for Error {}

impl From<Error> for crate::Error {
    fn from(_: Error) -> crate::Error {
        crate::Error::ParseError
    }
}

/// Zig's `ParseError = Error || Allocator.Error`; allocation is infallible
/// here, so it is the same set.
pub type ParseError = Error;

type R<T> = Result<T, Error>;

pub struct Parser<'s> {
    source: &'s [u8],
    pos: usize,
    builder: Builder,
    /// Set the moment any `Error` is returned. Only meaningful after
    /// `.parse()` has returned an error.
    pub diagnostic: Option<Diagnostic>,
}

impl<'s> Parser<'s> {
    pub fn new(source: &'s [u8]) -> Parser<'s> {
        Parser { source, pos: 0, builder: Builder::new(), diagnostic: None }
    }

    /// Parse the whole document into a fresh, self-contained tree rooted at
    /// a `doc` node.
    pub fn parse(&mut self) -> R<Document> {
        let doc_id = self.parse_document()?;
        // The builder mints a parent after its children, so the root comes
        // last; compaction renumbers into pre-order.
        let builder = std::mem::take(&mut self.builder);
        Ok(compact::run(builder.finish_document(self.source, doc_id)))
    }

    // ── diagnostics ──────────────────────────────────────────────────────

    fn fail<T>(&mut self, offset: usize, message: &'static str, e: Error) -> R<T> {
        self.diagnostic = Some(Diagnostic { offset, message });
        Err(e)
    }

    // ── low-level cursor helpers ─────────────────────────────────────────

    fn peek(&self) -> Option<u8> {
        self.source.get(self.pos).copied()
    }

    fn at(&self, needle: &[u8]) -> bool {
        self.source[self.pos..].starts_with(needle)
    }

    fn skip_whitespace(&mut self) {
        while self.pos < self.source.len() {
            match self.source[self.pos] {
                b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn read_name(&mut self) -> R<&'s [u8]> {
        let start = self.pos;
        if self.pos >= self.source.len() || !is_name_start_byte(self.source[self.pos]) {
            return self.fail(start, "expected a name", Error::MalformedXml);
        }
        self.pos += 1;
        while self.pos < self.source.len() && is_name_byte(self.source[self.pos]) {
            self.pos += 1;
        }
        Ok(&self.source[start..self.pos])
    }

    // ── entity / character reference decoding ───────────────────────────

    /// `self.source[self.pos] == '&'` on entry. Decodes one entity or
    /// character reference and appends its replacement text to `out`.
    fn decode_entity_into(&mut self, out: &mut Vec<u8>) -> R<()> {
        let amp_pos = self.pos;
        self.pos += 1;
        let Some(semi) = find_byte(self.source, self.pos, b';') else {
            return self.fail(
                amp_pos,
                "'&' must be escaped as &amp; or begin a valid entity/character reference",
                Error::MalformedXml,
            );
        };
        // A '<' before the ';' means this was never a real reference.
        if let Some(lt) = find_byte(self.source, self.pos, b'<') {
            if lt < semi {
                return self.fail(amp_pos, "'&' must be escaped as &amp;", Error::MalformedXml);
            }
        }
        let name = &self.source[self.pos..semi];
        self.pos = semi + 1;

        if !name.is_empty() && name[0] == b'#' {
            let cp = if name.len() > 1 && (name[1] == b'x' || name[1] == b'X') {
                match parse_int_u21(&name[2..], 16) {
                    Some(v) => v,
                    None => {
                        return self.fail(amp_pos, "invalid hexadecimal character reference", Error::MalformedXml)
                    }
                }
            } else {
                match parse_int_u21(&name[1..], 10) {
                    Some(v) => v,
                    None => return self.fail(amp_pos, "invalid decimal character reference", Error::MalformedXml),
                }
            };
            let Some(ch) = char::from_u32(cp) else {
                return self.fail(
                    amp_pos,
                    "character reference is not a valid Unicode scalar value",
                    Error::MalformedXml,
                );
            };
            let mut buf = [0u8; 4];
            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
            return Ok(());
        }

        let replacement: &[u8] = match name {
            b"amp" => b"&",
            b"lt" => b"<",
            b"gt" => b">",
            b"apos" => b"'",
            b"quot" => b"\"",
            _ => {
                return self.fail(
                    amp_pos,
                    "unknown entity reference (no DTD, so no custom entities)",
                    Error::UnknownEntity,
                )
            }
        };
        out.extend_from_slice(replacement);
        Ok(())
    }

    /// Read a run of character data up to (not including) the next `<` or
    /// EOF, decoding entities as it goes.
    fn read_text(&mut self) -> R<Vec<u8>> {
        let mut out = Vec::new();
        while self.pos < self.source.len() && self.source[self.pos] != b'<' {
            if self.source[self.pos] == b'&' {
                self.decode_entity_into(&mut out)?;
            } else {
                out.push(self.source[self.pos]);
                self.pos += 1;
            }
        }
        Ok(out)
    }

    /// Read a quoted (`"` or `'`) attribute value, decoding entities. A
    /// literal `<` inside the value is a well-formedness error.
    fn read_attr_value(&mut self) -> R<Vec<u8>> {
        let Some(quote) = self.peek() else {
            return self.fail(self.pos, "attribute value must be quoted", Error::MalformedXml);
        };
        if quote != b'"' && quote != b'\'' {
            return self.fail(self.pos, "attribute value must be quoted", Error::MalformedXml);
        }
        self.pos += 1;
        let mut out = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return self.fail(self.pos, "unterminated attribute value", Error::MalformedXml);
            };
            if c == quote {
                self.pos += 1;
                break;
            }
            if c == b'<' {
                return self.fail(self.pos, "'<' is not allowed in an attribute value", Error::MalformedXml);
            }
            if c == b'&' {
                self.decode_entity_into(&mut out)?;
                continue;
            }
            out.push(c);
            self.pos += 1;
        }
        Ok(out)
    }

    /// Parse `Name '=' AttValue` pairs up to (not including) the tag's
    /// closing `>` or `/>`.
    fn parse_attributes(&mut self) -> R<Vec<KeyVal>> {
        let mut list: Vec<KeyVal> = Vec::new();
        loop {
            self.skip_whitespace();
            let Some(c) = self.peek() else {
                return self.fail(self.pos, "tag was never closed", Error::MalformedXml);
            };
            if c == b'>' || c == b'/' {
                break;
            }
            let name_start = self.pos;
            let name = self.read_name()?;
            if list.iter().any(|kv| kv.key == name) {
                return self.fail(name_start, "duplicate attribute", Error::DuplicateAttribute);
            }
            self.skip_whitespace();
            if self.peek().unwrap_or(0) != b'=' {
                return self.fail(self.pos, "expected '=' after attribute name", Error::MalformedXml);
            }
            self.pos += 1;
            self.skip_whitespace();
            let value = self.read_attr_value()?;
            list.push(KeyVal { key: name.to_vec(), value: Some(value) });
        }
        Ok(list)
    }

    // ── generic-markup leaves ────────────────────────────────────────────

    fn parse_comment(&mut self) -> R<NodeId> {
        let start = self.pos;
        self.pos += b"<!--".len();
        let text_start = self.pos;
        let Some(dash) = find_slice(self.source, self.pos, b"--") else {
            return self.fail(start, "unterminated comment", Error::MalformedXml);
        };
        if dash + 2 >= self.source.len() {
            return self.fail(start, "unterminated comment", Error::MalformedXml);
        }
        if self.source[dash + 2] != b'>' {
            // A bare double hyphen, which XML forbids inside comment content.
            return self.fail(dash, "'--' is not allowed inside a comment", Error::MalformedXml);
        }
        let text = self.source[text_start..dash].to_vec();
        self.pos = dash + 3;
        let id = self.builder.add_leaf(Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text });
        self.builder.set_span(id, Span::new(start, self.pos));
        self.builder.set_content_span(id, Span::new(text_start, dash));
        Ok(id)
    }

    fn parse_cdata(&mut self) -> R<NodeId> {
        let start = self.pos;
        self.pos += b"<![CDATA[".len();
        let text_start = self.pos;
        let Some(end) = find_slice(self.source, self.pos, b"]]>") else {
            return self.fail(start, "unterminated CDATA section", Error::MalformedXml);
        };
        self.pos = end + 3;
        let id = self.builder.add_leaf(Kind::MarkupLeaf {
            kind: MarkupLeafKind::Cdata,
            text: self.source[text_start..end].to_vec(),
        });
        self.builder.set_span(id, Span::new(start, self.pos));
        self.builder.set_content_span(id, Span::new(text_start, end));
        Ok(id)
    }

    /// Also used for the XML declaration (`<?xml version="1.0"?>`): it
    /// round-trips perfectly as a PI with target `xml`.
    fn parse_processing_instruction(&mut self) -> R<NodeId> {
        let start = self.pos;
        self.pos += b"<?".len();
        let target = self.read_name()?;
        self.skip_whitespace();
        let data_start = self.pos;
        let Some(end) = find_slice(self.source, self.pos, b"?>") else {
            return self.fail(start, "unterminated processing instruction", Error::MalformedXml);
        };
        let data = self.source[data_start..end].to_vec();
        self.pos = end + 2;
        let id = self.builder.add_leaf(Kind::ProcessingInstruction { target: target.to_vec(), data });
        self.builder.set_span(id, Span::new(start, self.pos));
        // `content_span` stays `None`: a PI's payload is split across two
        // fields, so there is no single unambiguous interior.
        Ok(id)
    }

    /// Payload is the raw bytes from just after `<!DOCTYPE` to just before
    /// the terminating `>`, verbatim. Quoted strings and a bracketed internal
    /// subset may both contain `>`, so both are scanned over.
    fn parse_doctype(&mut self) -> R<NodeId> {
        let start = self.pos;
        self.pos += b"<!DOCTYPE".len();
        let guts_start = self.pos;
        let mut bracket_depth: usize = 0;
        loop {
            let Some(c) = self.peek() else {
                return self.fail(start, "unterminated DOCTYPE declaration", Error::MalformedXml);
            };
            match c {
                b'"' | b'\'' => {
                    let quote = c;
                    self.pos += 1;
                    loop {
                        let Some(q) = self.peek() else {
                            return self.fail(
                                start,
                                "unterminated quoted string in DOCTYPE declaration",
                                Error::MalformedXml,
                            );
                        };
                        self.pos += 1;
                        if q == quote {
                            break;
                        }
                    }
                }
                b'[' => {
                    bracket_depth += 1;
                    self.pos += 1;
                }
                b']' => {
                    if bracket_depth > 0 {
                        bracket_depth -= 1;
                    }
                    self.pos += 1;
                }
                b'>' => {
                    if bracket_depth == 0 {
                        let guts_end = self.pos;
                        let guts = self.source[guts_start..self.pos].to_vec();
                        self.pos += 1;
                        let id = self.builder.add_leaf(Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: guts });
                        self.builder.set_span(id, Span::new(start, self.pos));
                        self.builder.set_content_span(id, Span::new(guts_start, guts_end));
                        return Ok(id);
                    }
                    self.pos += 1;
                }
                _ => self.pos += 1,
            }
        }
    }

    // ── elements ─────────────────────────────────────────────────────────

    /// `self.source[self.pos] == '<'` followed by a non-special byte on
    /// entry. Recurses into itself for nested elements.
    fn parse_element(&mut self) -> R<NodeId> {
        let start = self.pos;
        self.pos += 1;
        let name = self.read_name()?;

        // The start tag's interior after the name — every attribute, with
        // the whitespace on both sides of the run — is the element's
        // attribute span (the one range an attribute edit splices). An
        // element with no attributes records none.
        let attrs_start = self.pos;
        let attrs = self.parse_attributes()?;
        let attrs_span = Span::new(attrs_start, self.pos);

        let Some(c) = self.peek() else {
            return self.fail(self.pos, "tag was never closed", Error::MalformedXml);
        };
        if c == b'/' {
            self.pos += 1;
            if self.peek().unwrap_or(0) != b'>' {
                return self.fail(self.pos, "expected '>' to close a self-closing tag", Error::MalformedXml);
            }
            self.pos += 1;
            let id = self.builder.add_container(Kind::Container(Container::named(name)), &[]);
            self.builder.set_span(id, Span::new(start, self.pos));
            self.builder.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Element));
            self.builder.set_attrs(id, Attrs { entries: attrs });
            self.builder.set_attrs_span(id, attrs_span);
            // `content_span` stays `None`: the serializer's self-closing signal.
            return Ok(id);
        }
        debug_assert!(c == b'>');
        self.pos += 1;
        let content_start = self.pos;

        let mut children: Vec<NodeId> = Vec::new();
        loop {
            if self.pos >= self.source.len() {
                return self.fail(start, "element was never closed", Error::UnclosedElement);
            }
            if self.source[self.pos] == b'<' {
                if self.at(b"</") {
                    break;
                }
                let child = if self.at(b"<!--") {
                    self.parse_comment()?
                } else if self.at(b"<![CDATA[") {
                    self.parse_cdata()?
                } else if self.at(b"<?") {
                    self.parse_processing_instruction()?
                } else if self.at(b"<!") {
                    return self.fail(
                        self.pos,
                        "declarations are not allowed inside element content",
                        Error::MalformedXml,
                    );
                } else {
                    self.parse_element()?
                };
                children.push(child);
                continue;
            }
            let text_start = self.pos;
            let text = self.read_text()?;
            let id = self.builder.add_leaf(Kind::Str(text));
            self.builder.set_span(id, Span::new(text_start, self.pos));
            children.push(id);
        }

        let content_end = self.pos; // the '<' of "</"
        self.pos += b"</".len();
        let close_name_start = self.pos;
        let close_name = self.read_name()?;
        if close_name != name {
            return self.fail(
                close_name_start,
                "close tag name does not match the open tag",
                Error::MismatchedCloseTag,
            );
        }
        self.skip_whitespace();
        if self.peek().unwrap_or(0) != b'>' {
            return self.fail(self.pos, "expected '>' to close the end tag", Error::MalformedXml);
        }
        self.pos += 1;

        let id = self.builder.add_container(Kind::Container(Container::named(name)), &children);
        self.builder.set_span(id, Span::new(start, self.pos));
        self.builder.set_content_span(id, Span::new(content_start, content_end));
        self.builder.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Element));
        self.builder.set_attrs(id, Attrs { entries: attrs });
        self.builder.set_attrs_span(id, attrs_span);
        Ok(id)
    }

    // ── document ─────────────────────────────────────────────────────────

    /// The root: prolog items, the single root element, and epilog items,
    /// all as direct children of a `doc` node, in source order. Whitespace
    /// between them is kept as `str` children.
    fn parse_document(&mut self) -> R<NodeId> {
        let mut children: Vec<NodeId> = Vec::new();
        let mut root_seen = false;

        while self.pos < self.source.len() {
            if self.source[self.pos] == b'<' {
                if self.at(b"<!--") {
                    let id = self.parse_comment()?;
                    children.push(id);
                } else if self.at(b"<![CDATA[") {
                    return self.fail(
                        self.pos,
                        "a CDATA section is not allowed outside the root element",
                        Error::MalformedXml,
                    );
                } else if self.at(b"<!DOCTYPE") {
                    if root_seen {
                        return self.fail(self.pos, "DOCTYPE must precede the root element", Error::MalformedXml);
                    }
                    let id = self.parse_doctype()?;
                    children.push(id);
                } else if self.at(b"<?") {
                    let id = self.parse_processing_instruction()?;
                    children.push(id);
                } else if self.at(b"</") {
                    return self.fail(
                        self.pos,
                        "unexpected end tag (no matching open element)",
                        Error::MalformedXml,
                    );
                } else if self.at(b"<!") {
                    return self.fail(self.pos, "unrecognized declaration", Error::MalformedXml);
                } else {
                    if root_seen {
                        return self.fail(
                            self.pos,
                            "a document can only have one root element",
                            Error::MultipleRoots,
                        );
                    }
                    let id = self.parse_element()?;
                    children.push(id);
                    root_seen = true;
                }
                continue;
            }
            let text_start = self.pos;
            let text = self.read_text()?;
            if !trim_ws(&text).is_empty() {
                return self.fail(text_start, "text is not allowed outside the root element", Error::TextOutsideRoot);
            }
            if !text.is_empty() {
                let id = self.builder.add_leaf(Kind::Str(text));
                self.builder.set_span(id, Span::new(text_start, self.pos));
                children.push(id);
            }
        }
        if !root_seen {
            return self.fail(self.source.len(), "document has no root element", Error::MissingRoot);
        }

        let doc_id = self.builder.add_container(Kind::Doc, &children);
        self.builder.set_span(doc_id, Span::new(0, self.source.len()));
        Ok(doc_id)
    }
}

// Name production, simplified to ASCII letters/digits/`_`/`-`/`.`/`:` plus
// "anything non-ASCII" (a deliberate simplification; see `xml::mod`).
fn is_name_start_byte(c: u8) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_uppercase() || c == b'_' || c == b':' || c >= 0x80
}

fn is_name_byte(c: u8) -> bool {
    is_name_start_byte(c) || c.is_ascii_digit() || c == b'-' || c == b'.'
}

fn find_byte(hay: &[u8], from: usize, b: u8) -> Option<usize> {
    hay.get(from..)?.iter().position(|&c| c == b).map(|i| i + from)
}

fn find_slice(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    let rest = hay.get(from..)?;
    if rest.len() < needle.len() {
        return None;
    }
    rest.windows(needle.len()).position(|w| w == needle).map(|i| i + from)
}

fn trim_ws(s: &[u8]) -> &[u8] {
    let is_ws = |c: &u8| matches!(c, b' ' | b'\t' | b'\r' | b'\n');
    let start = s.iter().position(|c| !is_ws(c)).unwrap_or(s.len());
    let end = s.iter().rposition(|c| !is_ws(c)).map_or(start, |i| i + 1);
    &s[start..end]
}

/// Zig's `std.fmt.parseInt(u21, buf, base)`: an optional `+`/`-` sign, `_`
/// digit separators (not leading or trailing), overflow past 21 bits fails;
/// a negative value is accepted only when it is zero.
fn parse_int_u21(buf: &[u8], base: u32) -> Option<u32> {
    if buf.is_empty() {
        return None;
    }
    let (digits, neg) = match buf[0] {
        b'+' => (&buf[1..], false),
        b'-' => (&buf[1..], true),
        _ => (buf, false),
    };
    if digits.is_empty() {
        return None;
    }
    if digits[0] == b'_' || digits[digits.len() - 1] == b'_' {
        return None;
    }
    const MAX: u32 = (1 << 21) - 1;
    let mut acc: u32 = 0;
    for &c in digits {
        if c == b'_' {
            continue;
        }
        let d = (c as char).to_digit(36)?;
        if d >= base {
            return None;
        }
        if acc != 0 {
            acc = acc.checked_mul(base).filter(|&v| v <= MAX)?;
        } else if neg {
            if d != 0 {
                return None;
            }
            continue;
        }
        if neg {
            acc = acc.checked_sub(d)?;
        } else {
            acc = acc.checked_add(d).filter(|&v| v <= MAX)?;
        }
    }
    Some(acc)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(src: &[u8]) -> Document {
        Parser::new(src).parse().unwrap()
    }

    #[test]
    fn parses_a_minimal_document() {
        let ast = parse(b"<a/>");
        assert_eq!(ast.ast.kind(ast.ast.root), &Kind::Doc);
        let root_el = ast.ast.node(ast.ast.root).first_child.unwrap();
        assert_eq!(ast.ast.kind(root_el).container().unwrap().name, b"a");
        assert_eq!(ast.content_span(root_el), None);
    }

    #[test]
    fn framed_leaves_carry_an_interior_content_span() {
        let source: &[u8] = b"<!DOCTYPE html><root><!-- hi --><![CDATA[x<y]]><?pi go?></root>";
        let ast = parse(source);
        let doctype = ast.ast.node(ast.ast.root).first_child.unwrap();
        let root_el = ast.ast.node(doctype).next_sibling.unwrap();
        let comment = ast.ast.node(root_el).first_child.unwrap();
        let cdata = ast.ast.node(comment).next_sibling.unwrap();
        let pi = ast.ast.node(cdata).next_sibling.unwrap();

        assert!(matches!(ast.ast.kind(doctype), Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, .. }));
        assert_eq!(ast.span(doctype).of(source), b"<!DOCTYPE html>");
        assert_eq!(ast.content_span(doctype).unwrap().of(source), b" html");

        assert!(matches!(ast.ast.kind(comment), Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, .. }));
        assert_eq!(ast.span(comment).of(source), b"<!-- hi -->");
        assert_eq!(ast.content_span(comment).unwrap().of(source), b" hi ");

        assert!(matches!(ast.ast.kind(cdata), Kind::MarkupLeaf { kind: MarkupLeafKind::Cdata, .. }));
        assert_eq!(ast.span(cdata).of(source), b"<![CDATA[x<y]]>");
        assert_eq!(ast.content_span(cdata).unwrap().of(source), b"x<y");

        assert!(matches!(ast.ast.kind(pi), Kind::ProcessingInstruction { .. }));
        assert_eq!(ast.content_span(pi), None);
    }

    #[test]
    fn empty_framed_leaf_interiors_get_an_empty_content_span_at_the_boundary() {
        let ast = parse(b"<root><!----><![CDATA[]]></root>");
        let root_el = ast.ast.node(ast.ast.root).first_child.unwrap();
        let comment = ast.ast.node(root_el).first_child.unwrap();
        let cdata = ast.ast.node(comment).next_sibling.unwrap();
        let ccs = ast.content_span(comment).unwrap();
        assert_eq!(ccs.len(), 0);
        assert_eq!(ccs.start, ast.span(comment).start + 4);
        let dcs = ast.content_span(cdata).unwrap();
        assert_eq!(dcs.len(), 0);
        assert_eq!(dcs.start, ast.span(cdata).start + 9);
    }

    #[test]
    fn duplicate_attribute_is_a_parse_error_with_a_diagnostic() {
        let mut p = Parser::new(b"<a x=\"1\" x=\"2\"/>");
        assert_eq!(p.parse().unwrap_err(), Error::DuplicateAttribute);
        assert_eq!(p.diagnostic.unwrap().offset, 9);
    }

    #[test]
    fn unknown_entity_is_a_parse_error_pointing_at_the_amp() {
        let mut p = Parser::new(b"<a>&bogus;</a>");
        assert_eq!(p.parse().unwrap_err(), Error::UnknownEntity);
        assert_eq!(p.diagnostic.unwrap().offset, 3);
    }

    #[test]
    fn simple_errors() {
        let cases: [(&[u8], Error); 5] = [
            (b"<a></b>", Error::MismatchedCloseTag),
            (b"<a><b></b>", Error::UnclosedElement),
            (b"<a/>stray", Error::TextOutsideRoot),
            (b"<a/><b/>", Error::MultipleRoots),
            (b"<!-- just a comment -->", Error::MissingRoot),
        ];
        for (src, e) in cases {
            assert_eq!(Parser::new(src).parse().unwrap_err(), e);
        }
    }

    #[test]
    fn an_elements_attribute_span_covers_the_start_tags_interior_after_the_name() {
        let src: &[u8] = b"<r><a  x=\"1\" y='2' ><b/></a><c z=\"3\"/><d></d></r>";
        let doc = parse(src);
        let root = doc.ast.node(doc.ast.root).first_child.unwrap();
        assert_eq!(doc.attrs_span(root), None);
        let a = doc.ast.node(root).first_child.unwrap();
        assert_eq!(doc.attrs_span(a).unwrap().of(src), b"  x=\"1\" y='2' ");
        assert_eq!(doc.attrs_span(doc.ast.node(a).first_child.unwrap()), None);
        let c = doc.ast.node(a).next_sibling.unwrap();
        assert_eq!(doc.attrs_span(c).unwrap().of(src), b" z=\"3\"");
        assert_eq!(doc.attrs_span(doc.ast.node(c).next_sibling.unwrap()), None);
    }

    #[test]
    fn parse_int_matches_zig() {
        assert_eq!(parse_int_u21(b"41", 16), Some(0x41));
        assert_eq!(parse_int_u21(b"+65", 10), Some(65));
        assert_eq!(parse_int_u21(b"-0", 10), Some(0));
        assert_eq!(parse_int_u21(b"-1", 10), None);
        assert_eq!(parse_int_u21(b"6_5", 10), Some(65));
        assert_eq!(parse_int_u21(b"_65", 10), None);
        assert_eq!(parse_int_u21(b"", 10), None);
        assert_eq!(parse_int_u21(b"1FFFFF", 16), Some(0x1FFFFF));
        assert_eq!(parse_int_u21(b"200000", 16), None);
    }
}
