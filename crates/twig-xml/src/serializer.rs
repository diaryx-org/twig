//! `Document` -> XML text. Port of `src/languages/xml/serializer.zig`.
//!
//! Re-derives generic, always-valid XML from the tree alone, which happens to
//! be byte-identical to the source for already-canonical input
//! (double-quoted attributes, explicit close tags, no unusual entity usage).
//!
//! Self-closing vs. open/close-pair form: the tree has no dedicated flag for
//! "this element was written as `<a/>`", so this renderer uses an ABSENT
//! interior span as that signal (exactly what the parser leaves for a
//! self-closing tag, and only for one). An element with an interior always
//! renders as an explicit `<a>...</a>` pair, even when empty. That is why
//! this is the one printer taking a `Document` rather than a bare `Ast`.

use crate::ast::{Attrs, Kind, MarkupLeafKind, NodeId};
use crate::document::Document;

fn write_escaped_text(out: &mut Vec<u8>, s: &[u8]) {
    for &c in s {
        match c {
            b'&' => out.extend_from_slice(b"&amp;"),
            b'<' => out.extend_from_slice(b"&lt;"),
            b'>' => out.extend_from_slice(b"&gt;"),
            _ => out.push(c),
        }
    }
}

fn write_escaped_attr_value(out: &mut Vec<u8>, s: &[u8]) {
    for &c in s {
        match c {
            b'&' => out.extend_from_slice(b"&amp;"),
            b'<' => out.extend_from_slice(b"&lt;"),
            b'"' => out.extend_from_slice(b"&quot;"),
            _ => out.push(c),
        }
    }
}

fn write_attrs(attrs: &Attrs, out: &mut Vec<u8>) {
    for kv in &attrs.entries {
        out.push(b' ');
        out.extend_from_slice(&kv.key);
        out.extend_from_slice(b"=\"");
        // XML attribute values are never bare; fall back to an empty value
        // rather than crash if a hand-built tree carries one.
        write_escaped_attr_value(out, kv.value.as_deref().unwrap_or(b""));
        out.push(b'"');
    }
}

/// The tree holds a kind XML has no spelling for — a semantic one (`heading`,
/// `link`, ...) that only a built or converted tree, never this parser's, can
/// contain. Zig's `error.UnsupportedNode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UnsupportedNode;

impl std::fmt::Display for UnsupportedNode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("UnsupportedNode")
    }
}

impl std::error::Error for UnsupportedNode {}

/// Write `id` (and its descendants) as XML text to `out`.
pub fn serialize_node(doc: &Document, id: NodeId, out: &mut Vec<u8>) -> Result<(), UnsupportedNode> {
    match doc.ast.kind(id) {
        Kind::Doc => {
            for child in doc.children(id) {
                serialize_node(doc, child.id, out)?;
            }
        }
        Kind::Container(e) => {
            out.push(b'<');
            out.extend_from_slice(&e.name);
            write_attrs(doc.ast.attrs_of(id), out);
            if doc.content_span(id).is_none() {
                out.extend_from_slice(b"/>");
                return Ok(());
            }
            out.push(b'>');
            // XML has no raw-text elements, so a text body that came from
            // HTML's tokenizer is written as the character data it is.
            if let Some(text) = &e.text {
                write_escaped_text(out, text);
            } else {
                for child in doc.children(id) {
                    serialize_node(doc, child.id, out)?;
                }
            }
            out.extend_from_slice(b"</");
            out.extend_from_slice(&e.name);
            out.push(b'>');
        }
        Kind::Str(s) => write_escaped_text(out, s),
        Kind::MarkupLeaf { kind, text } => match kind {
            MarkupLeafKind::Comment => {
                out.extend_from_slice(b"<!--");
                out.extend_from_slice(text);
                out.extend_from_slice(b"-->");
            }
            MarkupLeafKind::Doctype => {
                out.extend_from_slice(b"<!DOCTYPE");
                out.extend_from_slice(text);
                out.push(b'>');
            }
            MarkupLeafKind::Cdata => {
                out.extend_from_slice(b"<![CDATA[");
                out.extend_from_slice(text);
                out.extend_from_slice(b"]]>");
            }
        },
        Kind::ProcessingInstruction { target, data } => {
            out.extend_from_slice(b"<?");
            out.extend_from_slice(target);
            if !data.is_empty() {
                out.push(b' ');
                out.extend_from_slice(data);
            }
            out.extend_from_slice(b"?>");
        }
        // The XML parser never produces anything outside generic markup; a
        // built or converted tree can, and XML has no spelling for it.
        _ => return Err(UnsupportedNode),
    }
    Ok(())
}

/// Serialize the whole tree (from the root) to `out`.
pub fn serialize_into(doc: &Document, out: &mut Vec<u8>) -> Result<(), UnsupportedNode> {
    serialize_node(doc, doc.ast.root, out)
}

/// Serialize the whole tree to an owned buffer (Zig's `serializeAlloc`).
pub fn serialize(doc: &Document) -> Result<Vec<u8>, UnsupportedNode> {
    let mut out = Vec::new();
    serialize_into(doc, &mut out)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Builder, Container, KeyVal};
    use crate::parser::Parser;
    use crate::span::Span;

    #[test]
    fn serializes_a_self_closing_element_with_attributes() {
        let doc = Parser::new(b"<a x=\"1\" y=\"2\"/>").parse().unwrap();
        assert_eq!(serialize(&doc).unwrap(), b"<a x=\"1\" y=\"2\"/>");
    }

    #[test]
    fn serializes_an_explicit_open_close_pair_even_when_empty() {
        let doc = Parser::new(b"<a></a>").parse().unwrap();
        assert_eq!(serialize(&doc).unwrap(), b"<a></a>");
    }

    #[test]
    fn a_kind_xml_cannot_spell_is_refused_not_reached() {
        let mut b = Builder::new();
        let x = b.add_leaf(Kind::Str(b"x".to_vec()));
        let h = b.add_container(Kind::Heading { level: 1 }, &[x]);
        let root = b.add_container(Kind::Doc, &[h]);
        let doc = b.finish_document(b"", root);
        assert_eq!(serialize(&doc), Err(UnsupportedNode));
    }

    #[test]
    fn escapes_text_and_attribute_values() {
        let mut b = Builder::new();
        let text = b.add_leaf(Kind::Str(b"a < b & c > d".to_vec()));
        let el = b.add_container(Kind::Container(Container::named(b"p")), &[text]);
        b.set_content_span(el, Span::new(0, 0));
        b.set_attrs(el, Attrs { entries: vec![KeyVal::new(b"title", Some(b"x \"y\" & z"))] });
        let doc_id = b.add_container(Kind::Doc, &[el]);
        let doc = b.finish_document(b"", doc_id);
        assert_eq!(
            String::from_utf8(serialize(&doc).unwrap()).unwrap(),
            "<p title=\"x &quot;y&quot; &amp; z\">a &lt; b &amp; c &gt; d</p>"
        );
    }
}
