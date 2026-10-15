//! XML: the entry point for this language module. Port of
//! `src/languages/xml/xml.zig`. Wires the recursive-descent parser
//! (`parser.rs`) and the serializer (`serializer.rs`) together.
//!
//! XML is entirely generic markup from the shared vocabulary's point of
//! view — `container`/`comment`/`doctype`/`processing_instruction`/`cdata`/
//! `str` are the whole output alphabet.
//!
//! Documented deviations from strict XML 1.0 well-formedness (each is a
//! deliberate simplification, not an oversight):
//!   - `Name` is approximated as ASCII letter/`_`/`:` start, plus
//!     alnum/`-`/`.`/`:`/any non-ASCII byte to continue.
//!   - `]]>` occurring in ordinary text is not flagged.
//!   - The `PITarget` "xml" reservation outside the declaration is not
//!     enforced.
//!   - No external DTD subset is fetched, and an internal subset's contents
//!     are skipped as opaque bytes, so referencing anything but the five
//!     predefined entities is always `Error::UnknownEntity`.

pub mod parser;
pub mod serializer;


pub use parser::{Diagnostic, Error, ParseError, Parser};
pub use serializer::{serialize, serialize_into, serialize_node};

use crate::document::Document;

/// Parse `source` (an XML 1.0 document) into a fresh tree rooted at a `doc`
/// node. Discards the failure's [`Diagnostic`] — construct a [`Parser`]
/// directly when that detail matters.
pub fn parse(source: &[u8]) -> Result<Document, Error> {
    Parser::new(source).parse()
}

/// Small documents exercising the shared engine contract; not a conformance
/// corpus.
pub const SAMPLES: &[&str] = &[
    "<root/>",
    "<root key=\"value\">Text <child>inside</child>.</root>",
    "<?xml version=\"1.0\"?><root><!-- comment --><![CDATA[a < b]]></root>",
];

/// The `svg` dialect row's samples: the same engine contract, over documents
/// shaped the way a drawing tool writes them.
pub const SVG_SAMPLES: &[&str] = &[
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect x=\"1\" y=\"1\" width=\"3\" height=\"3\" fill=\"#f00\"/></svg>",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\">\n  <g id=\"layer\" transform=\"translate(1 2)\">\n    <path d=\"M 0 0 L 5 5\" stroke=\"black\"/>\n    <text x=\"1\" y=\"9\">a &amp; b</text>\n  </g>\n</svg>\n",
    "<svg/>",
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Attrs, Kind, MarkupLeafKind, NodeId};
    use crate::span::Span;

    // ── tree-equality helper (round-trip tests) ─────────────────────────
    // Structural comparison, ignoring spans but NOT content_span's
    // null-ness (the self-closing signal).

    fn kinds_equal(a: &Kind, b: &Kind) -> bool {
        match (a, b) {
            (Kind::Doc, Kind::Doc) => true,
            (Kind::Container(x), Kind::Container(y)) => x.name == y.name,
            (Kind::Str(x), Kind::Str(y)) => x == y,
            (Kind::MarkupLeaf { kind: k1, text: t1 }, Kind::MarkupLeaf { kind: k2, text: t2 }) => k1 == k2 && t1 == t2,
            (
                Kind::ProcessingInstruction { target: t1, data: d1 },
                Kind::ProcessingInstruction { target: t2, data: d2 },
            ) => t1 == t2 && d1 == d2,
            _ => false,
        }
    }

    fn attrs_equal(a: &Attrs, b: &Attrs) -> bool {
        a.entries == b.entries
    }

    fn trees_equal(a: &Document, a_id: NodeId, b: &Document, b_id: NodeId) -> bool {
        if !kinds_equal(a.ast.kind(a_id), b.ast.kind(b_id)) {
            return false;
        }
        if !attrs_equal(a.ast.attrs_of(a_id), b.ast.attrs_of(b_id)) {
            return false;
        }
        if a.content_span(a_id).is_none() != b.content_span(b_id).is_none() {
            return false;
        }
        let ca = a.ast.child_ids(a_id);
        let cb = b.ast.child_ids(b_id);
        ca.len() == cb.len() && ca.iter().zip(cb.iter()).all(|(&x, &y)| trees_equal(a, x, b, y))
    }

    fn str_of(k: &Kind) -> &[u8] {
        match k {
            Kind::Str(s) => s,
            _ => panic!("not a str"),
        }
    }

    #[test]
    fn tree_shape() {
        let src = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE root>\n<root xmlns:x=\"http://example.com/x\" id=\"r1\">\n  <!-- a comment -->\n  <child x:attr=\"v\">text &amp; more<?pi data?></child>\n  <![CDATA[<raw> stuff]]>\n</root>";
        let ast = parse(src.as_bytes()).unwrap();
        assert_eq!(ast.ast.kind(ast.ast.root), &Kind::Doc);
        let doc_kids = ast.ast.child_ids(ast.ast.root);
        assert_eq!(doc_kids.len(), 5);
        assert_eq!(
            ast.ast.kind(doc_kids[0]),
            &Kind::ProcessingInstruction {
                target: b"xml".to_vec(),
                data: b"version=\"1.0\" encoding=\"UTF-8\"".to_vec()
            }
        );
        assert!(matches!(ast.ast.kind(doc_kids[1]), Kind::Str(_)));
        assert_eq!(
            ast.ast.kind(doc_kids[2]),
            &Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: b" root".to_vec() }
        );
        assert!(matches!(ast.ast.kind(doc_kids[3]), Kind::Str(_)));
        let root = doc_kids[4];
        assert_eq!(ast.ast.kind(root).container().unwrap().name, b"root");
        let ra = ast.ast.attrs_of(root);
        assert_eq!(ra.get(b"xmlns:x"), Some(&b"http://example.com/x"[..]));
        assert_eq!(ra.get(b"id"), Some(&b"r1"[..]));

        let rk = ast.ast.child_ids(root);
        assert_eq!(rk.len(), 7);
        assert!(matches!(ast.ast.kind(rk[0]), Kind::Str(_)));
        assert_eq!(
            ast.ast.kind(rk[1]),
            &Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text: b" a comment ".to_vec() }
        );
        let child = rk[3];
        assert_eq!(ast.ast.kind(child).container().unwrap().name, b"child");
        assert_eq!(ast.ast.attrs_of(child).get(b"x:attr"), Some(&b"v"[..]));
        let ck = ast.ast.child_ids(child);
        assert_eq!(ck.len(), 2);
        assert_eq!(str_of(ast.ast.kind(ck[0])), b"text & more");
        assert_eq!(
            ast.ast.kind(ck[1]),
            &Kind::ProcessingInstruction { target: b"pi".to_vec(), data: b"data".to_vec() }
        );
        assert_eq!(
            ast.ast.kind(rk[5]),
            &Kind::MarkupLeaf { kind: MarkupLeafKind::Cdata, text: b"<raw> stuff".to_vec() }
        );
        assert!(matches!(ast.ast.kind(rk[6]), Kind::Str(_)));
    }

    #[test]
    fn spans() {
        let ast = parse(b"<a></a>").unwrap();
        let el = ast.ast.node(ast.ast.root).first_child.unwrap();
        assert_eq!(ast.span(el), Span::new(0, 7));
        assert_eq!(ast.content_span(el), Some(Span::new(3, 3)));

        let ast = parse(b"<a/>").unwrap();
        let el = ast.ast.node(ast.ast.root).first_child.unwrap();
        assert_eq!(ast.span(el), Span::new(0, 4));
        assert_eq!(ast.content_span(el), None);

        let ast = parse(b"<a b=\"1\">x</a>").unwrap();
        let el = ast.ast.node(ast.ast.root).first_child.unwrap();
        assert_eq!(ast.span(el), Span::new(0, 14));
        assert_eq!(ast.content_span(el), Some(Span::new(9, 10)));
        let text = ast.ast.node(el).first_child.unwrap();
        assert_eq!(ast.span(text), Span::new(9, 10));
        assert_eq!(str_of(ast.ast.kind(text)), b"x");
    }

    #[test]
    fn entities_decode_in_both_text_and_attribute_values() {
        let ast = parse(b"<a b=\"x &amp; y &#65; z\">t &lt;&gt; &apos;&quot; &#x41;</a>").unwrap();
        let el = ast.ast.node(ast.ast.root).first_child.unwrap();
        assert_eq!(ast.ast.attrs_of(el).get(b"b"), Some(&b"x & y A z"[..]));
        let text = ast.ast.node(el).first_child.unwrap();
        assert_eq!(str_of(ast.ast.kind(text)), b"t <> '\" A");
    }

    #[test]
    fn unknown_entity_errors_with_a_diagnostic_offset_at_the_amp() {
        let mut p = Parser::new(b"<a>x &nope; y</a>");
        assert_eq!(p.parse().unwrap_err(), Error::UnknownEntity);
        assert_eq!(p.diagnostic.unwrap().offset, 5);
    }

    #[test]
    fn errors() {
        let cases: [(&[u8], Error); 4] = [
            (b"<a><b></a></b>", Error::MismatchedCloseTag),
            (b"<a><b></b>", Error::UnclosedElement),
            (b"<a x=\"1\" x=\"2\"></a>", Error::DuplicateAttribute),
            (b"<a></a>trailing", Error::TextOutsideRoot),
        ];
        for (src, e) in cases {
            let mut p = Parser::new(src);
            assert_eq!(p.parse().unwrap_err(), e);
            assert!(p.diagnostic.is_some());
        }
    }

    const RSS_SAMPLE: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<rss version=\"2.0\">
  <channel>
    <title>Example Feed</title>
    <link>http://example.com/</link>
    <description>An example RSS feed for testing.</description>
    <language>en-us</language>
    <item>
      <title>First Post</title>
      <link>http://example.com/first</link>
      <guid isPermaLink=\"true\">http://example.com/first</guid>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
      <description><![CDATA[<p>Hello &amp; welcome!</p>]]></description>
    </item>
    <item>
      <title>Second Post</title>
      <link>http://example.com/second</link>
      <guid isPermaLink=\"true\">http://example.com/second</guid>
      <pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate>
      <description>Just some text, no markup.</description>
    </item>
  </channel>
</rss>";

    #[test]
    fn round_trip_tree_level() {
        let cases = [
            "<a/>",
            "<a x=\"1\"><b/><c>text</c></a>",
            "<root xmlns=\"urn:x\"><!-- c --><![CDATA[raw]]><?pi d?></root>",
            RSS_SAMPLE,
        ];
        for src in cases {
            let a1 = parse(src.as_bytes()).unwrap();
            let out = serialize(&a1).unwrap();
            let a2 = parse(&out).unwrap();
            assert!(trees_equal(&a1, a1.ast.root, &a2, a2.ast.root), "{src}");
        }
    }

    #[test]
    fn round_trip_byte_level() {
        let cases = [
            "<a/>",
            "<a b=\"1\" c=\"two\"></a>",
            "<root><child>hello world</child><child2 x=\"y\"/></root>",
            "<a>less &lt; than, amp &amp; amp</a>",
            "<root>\n  <child/>\n</root>",
            RSS_SAMPLE,
        ];
        for src in cases {
            let ast = parse(src.as_bytes()).unwrap();
            assert_eq!(String::from_utf8(serialize(&ast).unwrap()).unwrap(), src);
        }
    }

    #[test]
    fn samples_parse_and_round_trip() {
        for src in SAMPLES.iter().chain(SVG_SAMPLES) {
            let ast = parse(src.as_bytes()).unwrap();
            let again = parse(&serialize(&ast).unwrap()).unwrap();
            assert!(trees_equal(&ast, ast.ast.root, &again, again.ast.root));
        }
    }
}
