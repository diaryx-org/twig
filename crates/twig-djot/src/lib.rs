//! Djot: the entry point for this language module. Port of
//! `src/languages/djot/djot.zig`. Wires the block scanner, inline scanner,
//! and event-stream-to-AST builder together into one `parse` call.
//!
//! Djot's block and inline levels are mutually interleaved (each
//! paragraph/heading gets its own inline scan as the block scanner reaches its
//! content) — see `event.rs` for how the pieces fit together.
//!
//! `parse` returns the shared `Document`: the tree, the position tables, and —
//! in `Document.labels` — the label -> definition-node maps djot's render-time
//! reference resolution reads.

pub(crate) use twig_kit::{ast, attrs_writer, document, span};
pub(crate) use twig_kit::Error;

pub mod fidelity;
pub mod language;
pub mod syntax_table;

pub use language::Djot;

/// Register Djot with twig's registry and return its format — the first
/// call registers it; every later one hands back the same format.
#[cfg(feature = "twig")]
pub fn register() -> twig::Format {
    twig::register(Djot).expect("djot's names and codes are free")
}

/// Djot's format, registered on first use.
#[cfg(feature = "twig")]
pub fn format() -> twig::Format {
    register()
}
#[cfg(test)]
mod html_conformance;

pub mod attributes;
pub mod block;
pub mod conformance;
pub mod event;
pub mod html;
pub mod inline;
pub mod parser;
pub mod serializer;


use crate::ast::{Kind, Level};
use crate::document::Document;
use crate::span::Span;

pub use inline::{autolink_kind_of, AutolinkKind};
pub use serializer::{serialize, serialize_ast};

/// Parse `source` (Djot markup) into a `Document`.
pub fn parse(source: &[u8]) -> Document {
    // The scanner needs a trailing newline (djot.js's constructor appends
    // one). Positions must not include that synthetic byte.
    let owned;
    let subject: &[u8] = if source.last() == Some(&b'\n') {
        source
    } else {
        let mut v = Vec::with_capacity(source.len() + 1);
        v.extend_from_slice(source);
        v.push(b'\n');
        owned = v;
        &owned
    };
    let owns_subject = subject.len() != source.len();

    let events = block::Parser::new(subject).scan();
    let tree_builder = parser::TreeBuilder::new(subject);
    let mut doc = tree_builder.build(&events);
    doc.source = source.to_vec();
    if owns_subject {
        let len = source.len();
        let clamp = |s: &mut Span| {
            s.start = s.start.min(len);
            s.end = s.end.min(len);
        };
        doc.node_spans.iter_mut().for_each(clamp);
        doc.node_content_spans.iter_mut().flatten().for_each(clamp);
        doc.node_marker_spans.iter_mut().flatten().for_each(clamp);
        doc.attrs_spans.iter_mut().flatten().for_each(clamp);
    }
    doc
}

/// Mirrors djot.js `ast.ts`'s `isBlock`, as a reading of `Kind::level`.
pub fn is_block(kind: &Kind) -> bool {
    kind.level() == Level::Block
}

/// Mirrors djot.js `ast.ts`'s `isInline`.
pub fn is_inline(kind: &Kind) -> bool {
    kind.level() == Level::Inline
}

/// Small documents exercising the shared engine contract; not a conformance
/// corpus.
pub const SAMPLES: &[&[u8]] = &[
    b"# Heading without a final newline",
    b"A paragraph without a final newline",
    b"",
    b"A paragraph with _emphasis_ and *strong* text.\n",
    b"# Heading\n\n> Quote\n\n- first\n- second\n",
    b"{#intro .note}\nA paragraph.\n",
    b"``` zig\nconst x = 1;\n```\n",
    // A paragraph of several lines, which a djot heading continues over.
    b"A paragraph that runs\nover two lines.\n",
    // A caption written after the rows it names, which the table's span and
    // interior run to.
    b"| a | b |\n\n^ A _caption_\n",
];

/// `samples` in djot.zig.
pub fn samples() -> &'static [&'static [u8]] {
    SAMPLES
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Container, InlineMark, TextLeafKind};

    fn first(doc: &Document, id: u32) -> u32 {
        doc.ast.nodes[id as usize].first_child.unwrap()
    }
    fn next(doc: &Document, id: u32) -> u32 {
        doc.ast.nodes[id as usize].next_sibling.unwrap()
    }

    #[test]
    fn parse_produces_a_doc_with_a_paragraph() {
        let doc = parse(b"hello *world*\n");
        assert_eq!(doc.ast.kind(doc.ast.root), &Kind::Doc);
        let para = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(para), &Kind::Para);
        let st = first(&doc, para);
        assert_eq!(doc.ast.kind(st), &Kind::Str(b"hello ".to_vec()));
        let strong = next(&doc, st);
        assert_eq!(doc.ast.kind(strong), &Kind::InlineMark(InlineMark::Strong));
    }

    #[test]
    fn heading_gets_an_auto_id_and_wraps_a_section() {
        let doc = parse(b"# Hello World\n\npara\n");
        let sec = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(sec), &Kind::Section);
        assert_eq!(doc.ast.attrs_of(sec).get(b"id"), Some(&b"Hello-World"[..]));
        let h = first(&doc, sec);
        assert_eq!(doc.ast.kind(h), &Kind::Heading { level: 1 });
    }

    #[test]
    fn reference_link_resolves_via_labels() {
        let doc = parse(b"[foo][bar]\n\n[bar]: http://example.com\n");
        assert!(doc.labels.reference(b"bar").is_some());
    }

    #[test]
    fn bullet_list_is_tight() {
        let doc = parse(b"- a\n- b\n");
        let list = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(list), &Kind::BulletList { tight: true });
        let _ = parse(b"orange\n\n: a citrus fruit\n");
    }

    #[test]
    fn is_block_is_inline_classify_kinds() {
        assert!(is_block(&Kind::Heading { level: 1 }));
        assert!(!is_inline(&Kind::Heading { level: 1 }));
        assert!(is_inline(&Kind::Str(b"x".to_vec())));
        assert!(!is_block(&Kind::Str(b"x".to_vec())));
        assert!(!is_block(&Kind::Container(Container::named(b"video"))));
        assert!(!is_inline(&Kind::Container(Container::named(b"video"))));
    }

    #[test]
    fn symb_shortcodes() {
        let doc = parse(b":+1: :scream:\n");
        let para = first(&doc, doc.ast.root);
        let a = first(&doc, para);
        assert_eq!(doc.ast.kind(a), &Kind::TextLeaf { kind: TextLeafKind::Symb, text: b"+1".to_vec() });
        let sp = next(&doc, a);
        assert!(matches!(doc.ast.kind(sp), Kind::Str(_)));
        let b = next(&doc, sp);
        assert_eq!(doc.ast.kind(b), &Kind::TextLeaf { kind: TextLeafKind::Symb, text: b"scream".to_vec() });
    }

    #[test]
    fn symb_consumes_only_through_closing_colon() {
        let doc = parse(b":ice:scream:\n");
        let para = first(&doc, doc.ast.root);
        let a = first(&doc, para);
        assert_eq!(doc.ast.kind(a), &Kind::TextLeaf { kind: TextLeafKind::Symb, text: b"ice".to_vec() });
        let rest = next(&doc, a);
        assert_eq!(doc.ast.kind(rest), &Kind::Str(b"scream:".to_vec()));
    }

    #[test]
    fn attributes_multi_line_quoted_value_collapses() {
        let doc = parse(b"{\n attr=\"long\n value\n spanning\n multiple\n lines\"\n }\n> a\n");
        let bq = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(bq), &Kind::BlockQuote);
        assert_eq!(doc.ast.attrs_of(bq).get(b"attr"), Some(&b"long value spanning multiple lines"[..]));
    }

    #[test]
    fn attributes_backslash_escapes_resolve() {
        let doc = parse(b"> {key=\"bar\n>    a\\$bim\"}\n> ou\n");
        let bq = first(&doc, doc.ast.root);
        let para = first(&doc, bq);
        assert_eq!(doc.ast.kind(para), &Kind::Para);
        assert_eq!(doc.ast.attrs_of(para).get(b"key"), Some(&b"bar a$bim"[..]));
    }

    #[test]
    fn table_later_caption_replaces_earlier() {
        let doc = parse(b"| 1 | 2 |\n\n ^ cap1\n\n ^ cap2\n");
        let table = first(&doc, doc.ast.root);
        assert_eq!(doc.ast.kind(table), &Kind::Table);
        let cap = first(&doc, table);
        assert_eq!(doc.ast.kind(cap), &Kind::Caption);
        let st = first(&doc, cap);
        assert_eq!(doc.ast.kind(st), &Kind::Str(b"cap2".to_vec()));
    }

    #[test]
    fn samples_parse() {
        for s in samples() {
            let _ = parse(s);
        }
    }
}
