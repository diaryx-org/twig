//! The kit's checks that need a real parse: each reads a document through a
//! language crate, which the kit itself cannot depend on.

use twig_kit::ast::select::{parse, resolve_all, resolve_one, text_of, ResolveOneError, Selector};
use twig_kit::ast::{Kind, NodeId};
use twig_kit::document::Document;
use twig_kit::syntax::Syntax;
use twig_kit::syntax_json::{decode, encode_alloc, eql, Options, Renderers};
use twig_markdown::{self as markdown, ParseOptions};

fn sel(s: &str) -> Selector {
    parse(s.as_bytes()).unwrap()
}

// ── select ──

#[test]
fn resolve_all_a_directive_node_is_addressable_by_its_kind_name() {
    let doc = markdown::parse(b":::note\nhi\n:::\n\n::leaf\n", ParseOptions { directives: true, ..Default::default() });
    let ms = resolve_all(&doc, &sel("directive"));
    assert_eq!(ms.len(), 2);
    assert!(matches!(doc.ast.kind(ms[0].id), Kind::Container(_)));
}
#[test]
fn resolve_all_directive_name_and_class_word_audience_filtering() {
    let src = b":::vis{.public}\npublic stuff\n:::\n\n:::vis{.adam .family}\nprivate stuff\n:::\n\n:::note{.public}\nnot a vis block\n:::\n";
    let doc = markdown::parse(src, ParseOptions { directives: true, ..Default::default() });
    assert_eq!(resolve_all(&doc, &sel("directive[name=vis]")).len(), 2);
    let public = resolve_all(&doc, &sel("directive[name=vis][class~=public]"));
    assert_eq!(public.len(), 1);
    assert_eq!(doc.ast.kind(public[0].id).container().unwrap().name, b"vis");
    assert_eq!(resolve_all(&doc, &sel("directive[class~=publi]")).len(), 0);
}
#[test]
fn resolve_all_matches_by_kind_across_a_real_markdown_tree() {
    let doc = parse_md(b"# One\n\n## Two\n\n- a\n- b\n");
    assert_eq!(resolve_all(&doc, &sel("heading")).len(), 2);
    assert_eq!(resolve_all(&doc, &sel("item")).len(), 2);
}
#[test]
fn resolve_all_attribute_predicate_on_heading_level_and_nth() {
    let doc = parse_md(b"# One\n\n## Two\n\n### Three\n");
    let m2 = resolve_all(&doc, &sel("heading[level=2]"));
    assert_eq!(m2.len(), 1);
    assert_eq!(doc.ast.kind(m2[0].id), &Kind::Heading { level: 2 });
    let m3 = resolve_all(&doc, &sel("heading:nth(3)"));
    assert_eq!(m3.len(), 1);
    assert_eq!(doc.ast.kind(m3[0].id), &Kind::Heading { level: 3 });
}
#[test]
fn resolve_all_contains_and_resolve_one_enforces_uniqueness() {
    let doc = parse_md(b"# Shopping\n\n# Status\n");
    let one = resolve_one(&doc, &sel("heading(\"Status\")")).unwrap();
    assert_eq!(text_of(&doc.ast, one), b"Status");
    assert_eq!(resolve_one(&doc, &sel("heading")), Err(ResolveOneError::AmbiguousMatch));
    assert_eq!(resolve_one(&doc, &sel("heading(\"Nope\")")), Err(ResolveOneError::NoMatch));
}
#[test]
fn resolve_all_link_destination_prefix_predicate() {
    let doc = parse_md(b"[a](http://x.com) and [b](./rel)\n");
    let ms = resolve_all(&doc, &sel("link[dest^=\"http\"]"));
    assert_eq!(ms.len(), 1);
    assert!(matches!(doc.ast.kind(ms[0].id), Kind::Link(_)));
}
#[test]
fn resolve_all_descendant_chain_matches_items_nested_at_any_depth() {
    let doc = parse_md(b"- a\n  - b\n- c\n");
    let ms = resolve_all(&doc, &sel("list item"));
    assert_eq!(ms.len(), 3);
    let texts: Vec<Vec<u8>> = ms.iter().map(|m| text_of(&doc.ast, m.id)).collect();
    assert_eq!(texts, [b"ab".to_vec(), b"b".to_vec(), b"c".to_vec()]);
}
#[test]
fn resolve_all_child_combinator_requires_the_immediate_parent() {
    let doc = parse_md(b"> - x\n");
    assert_eq!(resolve_all(&doc, &sel("blockquote > para")).len(), 0);
    let desc = resolve_all(&doc, &sel("blockquote para"));
    assert_eq!(desc.len(), 1);
    assert_eq!(text_of(&doc.ast, desc[0].id), b"x");
}
#[test]
fn resolve_all_per_step_nth_scopes_a_later_step_to_one_ancestor() {
    let doc = parse_md(b"# Groceries\n\n- milk\n- eggs\n\n# Chores\n\n- dishes\n- laundry\n");
    let ms = resolve_all(&doc, &sel("list:nth(2) > item(\"dishes\")"));
    assert_eq!(ms.len(), 1);
    assert_eq!(text_of(&doc.ast, ms[0].id), b"dishes");
    assert_eq!(resolve_all(&doc, &sel("list:nth(1) > item(\"dishes\")")).len(), 0);
    assert_eq!(resolve_all(&doc, &sel("list > item(\"dishes\")")).len(), 1);
}
fn parse_md(src: &[u8]) -> Document {
    markdown::parse(src, ParseOptions::default())
}

// ── verse ──

/// Each line's source text, from its first child to its last.
fn line_texts(doc: &Document, block: NodeId) -> Vec<&[u8]> {
    doc.ast
        .children(block)
        .map(|line| {
            let kids = doc.ast.child_ids(line.id);
            match (kids.first(), kids.last()) {
                (Some(&f), Some(&l)) => &doc.source[doc.span(f).start..doc.span(l).end],
                _ => &b""[..],
            }
        })
        .collect()
}
#[test]
fn markdown_every_line_break_is_a_line_and_a_blank_line_a_stanza() {
    let src = b"<div class=\"verse\">\n\nOne line\nsoft-broken\\\nhard-broken\n\nstanza two\n\n</div>\n";
    let doc = markdown::parse(src, html_elements());
    let block = doc.ast.node(doc.ast.root).first_child.unwrap();
    assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
    assert!(doc.ast.attrs_of(block).is_empty());
    let texts = line_texts(&doc, block);
    let want: [&[u8]; 5] = [b"One line", b"soft-broken", b"hard-broken", b"", b"stanza two"];
    assert_eq!(texts, want);
    let gap = doc.ast.child_ids(block)[3];
    let at = src.windows(8).position(|w| w == b"\n\nstanza").unwrap() + 1;
    assert_eq!(doc.span(gap).start, at);
}
#[test]
fn markdown_em_spaces_are_the_indent_raw_or_as_an_entity() {
    let src = "<div class=\"verse center\">\n\nzero\n\u{2003}one\n&emsp;&#8195;two\n\n</div>\n";
    let s = src.as_bytes();
    let doc = markdown::parse(s, html_elements());
    let block = doc.ast.node(doc.ast.root).first_child.unwrap();
    assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
    assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"center"[..]));
    let lines = doc.ast.child_ids(block);
    assert_eq!(lines.len(), 3);
    let want_text: [&[u8]; 3] = [b"zero", b"one", b"two"];
    let want_start: [&[u8]; 3] = [b"zero", "\u{2003}".as_bytes(), b"&emsp;"];
    for (i, &line) in lines.iter().enumerate() {
        assert_eq!(doc.ast.kind(line), &Kind::Line { indent: i as u32 });
        let str_id = doc.ast.node(line).first_child.unwrap();
        assert_eq!(doc.ast.kind(str_id), &Kind::Str(want_text[i].to_vec()));
        assert_eq!(doc.span(str_id).of(s), want_text[i]);
        assert!(s[doc.span(line).start..].starts_with(want_start[i]));
    }
}
#[test]
fn markdown_a_div_holding_more_than_paragraphs_or_without_html_elements_is_not_a_verse() {
    let mixed = b"<div class=\"verse\">\n\n# A heading\n\nA line\n\n</div>\n";
    let doc = markdown::parse(mixed, html_elements());
    let block = doc.ast.node(doc.ast.root).first_child.unwrap();
    assert!(matches!(doc.ast.kind(block), Kind::Container(_)));
    assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"verse"[..]));

    let plain = b"<div class=\"verse\">\n\nA line\n\n</div>\n";
    let raw = markdown::parse(plain, ParseOptions::COMMONMARK);
    assert!(raw.ast.nodes.iter().all(|n| n.kind != Kind::LineBlock));
}
#[test]
fn djot_a_verse_div_is_a_line_block_its_other_classes_kept() {
    let src = "{.center}\n::: verse\nOne\\\n\u{2003}two\n\nthree\n:::\n";
    let doc = twig_djot::parse(src.as_bytes());
    let block = doc.ast.node(doc.ast.root).first_child.unwrap();
    assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
    assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"center"[..]));
    let want: [&[u8]; 4] = [b"One", b"two", b"", b"three"];
    assert_eq!(line_texts(&doc, block), want);
}
#[test]
fn the_rewrite_leaves_nothing_behind_for_compaction_to_miss() {
    let doc = markdown::parse(b"<div class=\"verse\">\n\na\nb\n\nc\n\n</div>\n", html_elements());
    let mut seen = vec![false; doc.ast.nodes.len()];
    let mut stack = vec![doc.ast.root];
    while let Some(id) = stack.pop() {
        seen[id as usize] = true;
        stack.extend(doc.ast.child_ids(id));
    }
    assert!(seen.iter().all(|&s| s));
    assert!(doc.ast.nodes.iter().all(|n| n.kind != Kind::Para && n.kind != Kind::SoftBreak));
}
fn html_elements() -> ParseOptions {
    ParseOptions { html_elements: true, ..ParseOptions::default() }
}

// ── node table ──

#[test]
fn a_coloured_highlights_marker_crosses_and_comes_back() {
    let opts = twig_markdown::ParseOptions { highlight: true, highlight_colors: true, ..Default::default() };
    let doc = twig_markdown::parse("==\u{1F534} red== text\n".as_bytes(), opts);
    assert!(doc.node_marker_spans.iter().any(Option::is_some));
    twig_kit::ast::table::expect_identity(&doc);
}

// ── syntax tables as JSON ──

/// `s` encoded, decoded, and given back its own renderers is `s`.
fn expect_syntax_identity(s: &Syntax) {
    let text = encode_alloc(s, Options { pretty: false });
    let mut decoded = decode(&text).unwrap_or_else(|p| panic!("refused: {}: {}", p.path, p.what));
    assert_eq!(Renderers::of(s), decoded.renderers);
    if decoded.renderers.render_text {
        decoded.syntax.render_text = s.render_text;
    }
    if decoded.renderers.render_block {
        decoded.syntax.render_block = s.render_block;
    }
    if decoded.renderers.spells_autolink {
        decoded.syntax.spells_autolink = s.spells_autolink;
    }
    assert!(eql(s, &decoded.syntax), "{}", String::from_utf8_lossy(&text));
    decoded.syntax.validate().unwrap();
    let again = encode_alloc(&decoded.syntax, Options { pretty: false });
    assert_eq!(text, again);
}
#[test]
fn every_compiled_table_is_its_own_encoding() {
    for t in [twig_djot::syntax_table::table(), twig_markdown::syntax_table::table(), twig_html::syntax_table::table(), twig_xml::syntax_table::table(), twig_asciidoc::syntax_table::table(), twig_kit::syntax::none()] {
        expect_syntax_identity(t);
    }
    for t in twig_markdown::syntax_table::every() {
        expect_syntax_identity(t);
    }
}
