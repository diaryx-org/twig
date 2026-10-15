//! `inline.zig`'s unit tests, ported. The scanner runs over a bare `text`
//! (no block parse, no compaction) with the nodes hung under a `para`, as the
//! Zig helpers do.

use super::*;
use crate::ast::{Cell, Kind, NodeId, TextLeafKind};
use crate::document::{Document, HighlightPrefix, Spelling};

fn opts() -> ParseOptions {
    ParseOptions::default()
}

fn run(text: &[u8], options: ParseOptions, mapped: bool) -> Document {
    let mut b = Builder::new();
    let refs = LinkRefs::new();
    let segs = if mapped { vec![Segment { buf_offset: 0, src_offset: 0, len: text.len() }] } else { vec![] };
    let kids = parse_inline(&mut b, text, &segs, &refs, options);
    let root = b.add_container(Kind::Para, &kids);
    b.finish_document(text, root)
}

/// `parseAndFinish` / `parseAndFinishWithOptions(Doc)`.
fn p(text: &str) -> Document {
    run(text.as_bytes(), opts(), false)
}
fn po(text: &str, o: ParseOptions) -> Document {
    run(text.as_bytes(), o, false)
}
/// `parseAndFinishMappedDoc`.
fn pm(text: &str, o: ParseOptions) -> Document {
    run(text.as_bytes(), o, true)
}

fn parse_cell(text: &str) -> Document {
    let mut b = Builder::new();
    let refs = LinkRefs::new();
    let kids = {
        let mut sc = init_scanner(&mut b, &refs, opts());
        sc.in_cell = true;
        scan_reuse(&mut sc, text.as_bytes(), &[])
    };
    let root = b.add_container(Kind::Cell(Cell::new(false, crate::ast::Alignment::Default)), &kids);
    b.finish_document(text.as_bytes(), root)
}

fn root(d: &Document) -> NodeId {
    d.ast.root
}
fn fc(d: &Document, id: NodeId) -> NodeId {
    d.ast.nodes[id as usize].first_child.expect("first child")
}
fn ns(d: &Document, id: NodeId) -> NodeId {
    d.ast.nodes[id as usize].next_sibling.expect("next sibling")
}
fn no_next(d: &Document, id: NodeId) -> bool {
    d.ast.nodes[id as usize].next_sibling.is_none()
}
fn k(d: &Document, id: NodeId) -> &Kind {
    &d.ast.nodes[id as usize].kind
}
fn s(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::Str(t) => std::str::from_utf8(t).unwrap(),
        other => panic!("not a str: {other:?}"),
    }
}
fn leaf_text(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::TextLeaf { text, .. } => std::str::from_utf8(text).unwrap(),
        other => panic!("not a text_leaf: {other:?}"),
    }
}
fn is_mark(d: &Document, id: NodeId, m: InlineMark) -> bool {
    k(d, id).is_inline_mark(m)
}
fn is_leaf(d: &Document, id: NodeId, t: TextLeafKind) -> bool {
    k(d, id).is_text_leaf(t)
}
fn nth_tag(d: &Document, n: usize) -> Option<crate::ast::Tag> {
    d.ast.children(root(d)).nth(n).map(|c| c.kind.tag())
}
fn first_of_tag(d: &Document, tag: crate::ast::Tag) -> Option<NodeId> {
    d.ast.nodes.iter().position(|n| n.kind.tag() == tag).map(|i| i as NodeId)
}
fn sp<'a>(d: &Document, id: NodeId, src: &'a str) -> &'a str {
    let s = d.span(id);
    &src[s.start..s.end]
}
fn csp<'a>(d: &Document, id: NodeId, src: &'a str) -> &'a str {
    let s = d.content_span(id).expect("content span");
    &src[s.start..s.end]
}
fn attr<'a>(d: &'a Document, id: NodeId, key: &str) -> &'a str {
    std::str::from_utf8(d.ast.attrs_of(id).get(key.as_bytes()).expect("attr")).unwrap()
}
fn dest(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::Link(l) | Kind::Image(l) => std::str::from_utf8(l.destination.as_deref().unwrap()).unwrap(),
        other => panic!("not a link: {other:?}"),
    }
}
fn concat_str_children(d: &Document, parent: NodeId) -> String {
    d.ast.children(parent).map(|n| std::str::from_utf8(n.kind.str_text().expect("str")).unwrap()).collect()
}
fn inline_text_of(d: &Document, parent: NodeId, out: &mut String) {
    for n in d.ast.children(parent) {
        match &n.kind {
            Kind::Str(t) => out.push_str(std::str::from_utf8(t).unwrap()),
            _ => inline_text_of(d, n.id, out),
        }
    }
}
fn flat(d: &Document) -> String {
    let mut s = String::new();
    inline_text_of(d, root(d), &mut s);
    s
}
fn all_str(d: &Document, parent: NodeId) -> bool {
    d.ast.children(parent).all(|n| matches!(n.kind, Kind::Str(_)))
}
fn container_name(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::Container(c) => std::str::from_utf8(&c.name).unwrap(),
        other => panic!("not a container: {other:?}"),
    }
}

fn html_on() -> ParseOptions {
    ParseOptions { html_elements: true, ..opts() }
}
fn directives_on() -> ParseOptions {
    ParseOptions { directives: true, ..opts() }
}
fn colors_on() -> ParseOptions {
    ParseOptions { highlight: true, highlight_colors: true, ..opts() }
}

use crate::ast::Tag;

#[test]
fn in_cell_br_promotes_to_hard_break() {
    let d = parse_cell("a<br>b");
    assert_eq!(nth_tag(&d, 0), Some(Tag::Str));
    assert_eq!(nth_tag(&d, 1), Some(Tag::HardBreak));
    assert_eq!(nth_tag(&d, 2), Some(Tag::Str));
}

#[test]
fn in_cell_self_closing_spellings_all_promote() {
    for src in ["a<br/>b", "a<br />b", "a<br >b", "a<BR>b"] {
        assert_eq!(nth_tag(&parse_cell(src), 1), Some(Tag::HardBreak));
    }
}

#[test]
fn in_cell_only_br_promotes() {
    assert_eq!(nth_tag(&parse_cell("a<img src=x>b"), 1), Some(Tag::RawInline));
}

#[test]
fn out_of_cell_br_stays_raw_inline() {
    assert_eq!(nth_tag(&p("a<br>b"), 1), Some(Tag::RawInline));
}

#[test]
fn is_br_tag_accepts_plain_spellings() {
    for t in ["<br>", "<br/>", "<br />", "<br >", "<BR>", "<Br/>"] {
        assert!(is_br_tag(t.as_bytes()), "{t}");
    }
    for t in ["<br class=x>", "<brr>", "<b>", "<img>", "<br", "br>", "<x/>"] {
        assert!(!is_br_tag(t.as_bytes()), "{t}");
    }
}

#[test]
fn plain_text_becomes_single_str() {
    let d = p("hello world");
    assert_eq!(s(&d, fc(&d, root(&d))), "hello world");
}

#[test]
fn html_elements_off_img_stays_raw_inline() {
    let d = p("a <img src=\"x.png\"> b");
    let tag = ns(&d, fc(&d, root(&d)));
    match k(&d, tag) {
        Kind::RawInline { format, .. } => assert_eq!(format, b"html"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn html_elements_img_promotes_to_image() {
    let d = po("a <img src=\"x.png\" alt=\"cat\"> b", html_on());
    let first = fc(&d, root(&d));
    assert_eq!(s(&d, first), "a ");
    let img = ns(&d, first);
    assert_eq!(dest(&d, img), "x.png");
    assert_eq!(s(&d, fc(&d, img)), "cat");
    assert_eq!(s(&d, ns(&d, img)), " b");
}

#[test]
fn html_elements_promoted_img_span_addresses_source() {
    let src = "a <img src=\"x.png\" alt=\"cat\"> b";
    let d = pm(src, html_on());
    let img = ns(&d, fc(&d, root(&d)));
    assert_eq!(sp(&d, img, src), "<img src=\"x.png\" alt=\"cat\">");
}

#[test]
fn html_elements_br_promotes_to_hard_break() {
    let d = po("a<br>b", html_on());
    assert_eq!(*k(&d, ns(&d, fc(&d, root(&d)))), Kind::HardBreak);
}

#[test]
fn html_elements_paired_span_is_a_container() {
    let d = po("a <span class=\"l\" data-k=\"v\">big *text*</span> b", html_on());
    let span = first_of_tag(&d, Tag::Container).unwrap();
    let Kind::Container(c) = k(&d, span) else { panic!() };
    assert_eq!(c.name, b"span");
    assert_eq!(c.form, Some(Form::InlineText));
    assert_eq!(attr(&d, span, "class"), "l");
    assert_eq!(attr(&d, span, "data-k"), "v");
    let first = fc(&d, span);
    assert_eq!(s(&d, first), "big ");
    let em = ns(&d, first);
    assert!(is_mark(&d, em, InlineMark::Emph));
    assert!(no_next(&d, em));
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::RawInline));
}

#[test]
fn html_elements_spans_nest() {
    let d = po("<span class=\"a\">x <span class=\"b\">y</span> z</span>", html_on());
    let outer = fc(&d, root(&d));
    assert_eq!(k(&d, outer).tag(), Tag::Container);
    assert_eq!(attr(&d, outer, "class"), "a");
    let x = fc(&d, outer);
    let inner = ns(&d, x);
    assert_eq!(attr(&d, inner, "class"), "b");
    let z = ns(&d, inner);
    assert_eq!(s(&d, z), " z");
    assert!(no_next(&d, z));
}

#[test]
fn html_elements_unpaired_spans_stay_raw() {
    let open = po("a <span class=\"x\"> b", html_on());
    assert!(first_of_tag(&open, Tag::Container).is_none());
    assert!(first_of_tag(&open, Tag::RawInline).is_some());
    let closed = po("a <span/> b", html_on());
    assert!(first_of_tag(&closed, Tag::Container).is_none());
    let bold = po("a <b>hi</b> b", html_on());
    assert!(first_of_tag(&bold, Tag::Container).is_none());
    assert!(first_of_tag(&bold, Tag::RawInline).is_some());
}

#[test]
fn html_elements_paired_u_is_insert() {
    let src = "a <U>big *text*</u> b";
    let d = pm(src, html_on());
    let ins = ns(&d, fc(&d, root(&d)));
    assert!(is_mark(&d, ins, InlineMark::Insert));
    assert_eq!(sp(&d, ins, src), "<U>big *text*</u>");
    assert_eq!(csp(&d, ins, src), "big *text*");
    let first = fc(&d, ins);
    assert_eq!(s(&d, first), "big ");
    assert!(is_mark(&d, ns(&d, first), InlineMark::Emph));
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::RawInline));
}

#[test]
fn html_elements_u_with_attrs_unclosed_or_self_closing_stays_raw() {
    for src in ["a <u class=\"x\">hi</u> b", "a <u>hi b", "a <u/> b", "a <ul>hi</ul> b"] {
        let d = po(src, html_on());
        assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::InlineMark), "{src}");
        assert!(first_of_tag(&d, Tag::RawInline).is_some(), "{src}");
    }
}

#[test]
fn html_elements_off_paired_u_is_two_raw_inlines() {
    assert!(first_of_tag(&p("a <u>hi</u> b"), Tag::InlineMark).is_none());
}

#[test]
fn span_paired_span_and_children_address_source() {
    let src = "x <span class=\"l\">a *b* c</span> y";
    let d = pm(src, html_on());
    let span = ns(&d, fc(&d, root(&d)));
    assert_eq!(k(&d, span).tag(), Tag::Container);
    assert_eq!(sp(&d, span, src), "<span class=\"l\">a *b* c</span>");
    assert_eq!(csp(&d, span, src), "a *b* c");
    let first = fc(&d, span);
    assert_eq!(sp(&d, first, src), "a ");
    assert_eq!(sp(&d, ns(&d, first), src), "*b*");
}

#[test]
fn html_elements_off_paired_span_is_two_raw_inlines() {
    let d = p("a <span class=\"l\">hi</span> b");
    assert!(first_of_tag(&d, Tag::Container).is_none());
    assert_eq!(d.ast.nodes.iter().filter(|n| n.kind.tag() == Tag::RawInline).count(), 2);
}

#[test]
fn text_directive_with_label_and_attrs() {
    let d = po(":abbr[HTML]{title=\"HyperText\" .up}", directives_on());
    let dir = fc(&d, root(&d));
    let Kind::Container(c) = k(&d, dir) else { panic!() };
    assert_eq!(c.form, Some(Form::InlineText));
    assert_eq!(c.name, b"abbr");
    assert_eq!(s(&d, fc(&d, dir)), "HTML");
    assert_eq!(attr(&d, dir, "title"), "HyperText");
    assert_eq!(attr(&d, dir, "class"), "up");
}

#[test]
fn bare_text_directive() {
    let d = po(":here", directives_on());
    let dir = fc(&d, root(&d));
    assert_eq!(container_name(&d, dir), "here");
    assert!(d.ast.nodes[dir as usize].first_child.is_none());
}

#[test]
fn text_directive_label_parses_nested_inline() {
    let d = po(":span[a *b* c]", directives_on());
    let dir = fc(&d, root(&d));
    let first = fc(&d, dir);
    assert_eq!(s(&d, first), "a ");
    assert!(is_mark(&d, ns(&d, first), InlineMark::Emph));
}

#[test]
fn text_directive_label_nests_another_directive() {
    let d = po(":vis[a :vis[b]{.x} c]{.y}", directives_on());
    let outer = fc(&d, root(&d));
    assert_eq!(container_name(&d, outer), "vis");
    assert_eq!(attr(&d, outer, "class"), "y");
    assert!(no_next(&d, outer));
    let first = fc(&d, outer);
    assert_eq!(s(&d, first), "a ");
    let inner = ns(&d, first);
    assert_eq!(container_name(&d, inner), "vis");
    assert_eq!(attr(&d, inner, "class"), "x");
    assert_eq!(s(&d, fc(&d, inner)), "b");
    assert_eq!(s(&d, ns(&d, inner)), " c");
}

#[test]
fn text_directive_label_keeps_link_brackets() {
    let d = po(":vis[see [docs](/d) now]", directives_on());
    let dir = fc(&d, root(&d));
    assert_eq!(container_name(&d, dir), "vis");
    let link = ns(&d, fc(&d, dir));
    assert_eq!(k(&d, link).tag(), Tag::Link);
    assert_eq!(dest(&d, link), "/d");
}

#[test]
fn unterminated_directive_label_is_not_a_directive() {
    let d = po(":vis[a [b c]{.y}", directives_on());
    assert_eq!(s(&d, fc(&d, root(&d))), ":vis");
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::Container));
}

#[test]
fn directive_nesting_past_the_cap_stays_literal() {
    let over = MAX_DIRECTIVE_NESTING as usize + 3;
    let mut src = ":v[".repeat(over);
    src.push('x');
    src.push_str(&"]".repeat(over));
    let d = po(&src, directives_on());
    let mut depth = 0;
    let mut node = fc(&d, root(&d));
    while k(&d, node).tag() == Tag::Container {
        node = fc(&d, node);
        depth += 1;
    }
    assert_eq!(depth, MAX_DIRECTIVE_NESTING as usize);
    assert_eq!(s(&d, node), ":v");
}

#[test]
fn colon_not_starting_a_directive_stays_literal() {
    let d = po("ratio 3:4 mix", directives_on());
    assert_eq!(s(&d, fc(&d, root(&d))), "ratio 3:4 mix");
}

#[test]
fn directives_disabled_no_directive_node() {
    let d = po(":abbr[HTML]", opts());
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::Container));
    assert_eq!(s(&d, fc(&d, root(&d))), ":abbr");
}

#[test]
fn backslash_escape_yields_literal_punct() {
    let d = p("\\*not emphasis\\*");
    assert_eq!(s(&d, fc(&d, root(&d))), "*not emphasis*");
}

#[test]
fn backslash_before_non_punct_is_literal() {
    let d = p("\\a");
    assert_eq!(s(&d, fc(&d, root(&d))), "\\a");
}

#[test]
fn entities_decode() {
    let d = p("&amp; &#65; &#x41;");
    assert_eq!(s(&d, fc(&d, root(&d))), "& A A");
}

#[test]
fn unknown_entity_stays_literal() {
    let d = p("&nosuchentity;");
    assert_eq!(s(&d, fc(&d, root(&d))), "&nosuchentity;");
}

#[test]
fn code_span_strips_one_space_and_converts_newlines() {
    let d = p("a `` `foo` `` b");
    let s1 = fc(&d, root(&d));
    assert_eq!(s(&d, s1), "a ");
    let code = ns(&d, s1);
    assert_eq!(leaf_text(&d, code), "`foo`");
    assert_eq!(s(&d, ns(&d, code)), " b");
}

#[test]
fn two_trailing_spaces_hard_break() {
    let d = p("foo  \nbar");
    let s1 = fc(&d, root(&d));
    assert_eq!(s(&d, s1), "foo");
    let brk = ns(&d, s1);
    assert_eq!(*k(&d, brk), Kind::HardBreak);
    assert_eq!(s(&d, ns(&d, brk)), "bar");
}

#[test]
fn backslash_newline_hard_break() {
    let d = p("foo\\\nbar");
    assert_eq!(*k(&d, ns(&d, fc(&d, root(&d)))), Kind::HardBreak);
}

#[test]
fn plain_newline_soft_break() {
    let d = p("foo\nbar");
    assert_eq!(*k(&d, ns(&d, fc(&d, root(&d)))), Kind::SoftBreak);
}

#[test]
fn simple_emphasis_and_strong() {
    let d = p("*em* and **strong**");
    let em = fc(&d, root(&d));
    assert!(is_mark(&d, em, InlineMark::Emph));
    assert_eq!(s(&d, fc(&d, em)), "em");
    let strong = ns(&d, ns(&d, em));
    assert!(is_mark(&d, strong, InlineMark::Strong));
    assert_eq!(s(&d, fc(&d, strong)), "strong");
}

#[test]
fn nested_emphasis_inside_strong_inside_emphasis() {
    let d = p("*a **b** c*");
    let em = fc(&d, root(&d));
    assert!(is_mark(&d, em, InlineMark::Emph));
    let t1 = fc(&d, em);
    assert_eq!(s(&d, t1), "a ");
    let strong = ns(&d, t1);
    assert!(is_mark(&d, strong, InlineMark::Strong));
    assert_eq!(s(&d, fc(&d, strong)), "b");
    assert_eq!(s(&d, ns(&d, strong)), " c");
}

#[test]
fn underscore_emphasis_and_asterisk_strong() {
    let d = p("**a** and _b_");
    let strong = fc(&d, root(&d));
    assert!(is_mark(&d, strong, InlineMark::Strong));
    let em = ns(&d, ns(&d, strong));
    assert!(is_mark(&d, em, InlineMark::Emph));
    assert_eq!(s(&d, fc(&d, em)), "b");
}

#[test]
fn intraword_underscore_does_not_open() {
    let d = p("a_b_c");
    assert_eq!(s(&d, fc(&d, root(&d))), "a_b_c");
}

#[test]
fn asterisk_strong_intraword() {
    let d = p("foo**bar**baz");
    let t1 = fc(&d, root(&d));
    assert_eq!(s(&d, t1), "foo");
    let strong = ns(&d, t1);
    assert!(is_mark(&d, strong, InlineMark::Strong));
    assert_eq!(s(&d, fc(&d, strong)), "bar");
    assert_eq!(s(&d, ns(&d, strong)), "baz");
}

#[test]
fn inline_link_with_title() {
    let d = p("[foo](/url \"title\")");
    let link = fc(&d, root(&d));
    let Kind::Link(l) = k(&d, link) else { panic!() };
    assert_eq!(l.destination.as_deref(), Some(&b"/url"[..]));
    assert_eq!(l.reference, None);
    assert_eq!(attr(&d, link, "title"), "title");
    assert_eq!(s(&d, fc(&d, link)), "foo");
}

#[test]
fn inline_image() {
    let d = p("![alt text](/img.png)");
    let img = fc(&d, root(&d));
    assert_eq!(k(&d, img).tag(), Tag::Image);
    assert_eq!(dest(&d, img), "/img.png");
    assert_eq!(s(&d, fc(&d, img)), "alt text");
}

#[test]
fn autolink_uri_and_email() {
    let d = p("<https://example.com> <foo@bar.com>");
    let url = fc(&d, root(&d));
    assert!(is_leaf(&d, url, TextLeafKind::Url));
    assert_eq!(leaf_text(&d, url), "https://example.com");
    let email = ns(&d, ns(&d, url));
    assert!(is_leaf(&d, email, TextLeafKind::Email));
    assert_eq!(leaf_text(&d, email), "foo@bar.com");
}

#[test]
fn raw_inline_html_passes_through() {
    let d = p("a <span class=\"x\"> b");
    let raw = ns(&d, fc(&d, root(&d)));
    match k(&d, raw) {
        Kind::RawInline { format, text } => {
            assert_eq!(format, b"html");
            assert_eq!(text, b"<span class=\"x\">");
        }
        other => panic!("{other:?}"),
    }
}

fn parse_with_one_reference(text: &str, label: &str, dest: &str) -> Document {
    let mut b = Builder::new();
    let ref_id =
        b.add_leaf(Kind::Reference { label: label.as_bytes().to_vec(), destination: dest.as_bytes().to_vec() });
    let mut refs = LinkRefs::new();
    refs.insert(label.as_bytes().to_vec(), ref_id);
    let kids = parse_inline(&mut b, text.as_bytes(), &[], &refs, opts());
    let root = b.add_container(Kind::Para, &kids);
    b.finish_document(text.as_bytes(), root)
}

#[test]
fn full_reference_link_resolves() {
    let d = parse_with_one_reference("[foo][bar]", "bar", "/url");
    let link = fc(&d, root(&d));
    assert_eq!(k(&d, link).tag(), Tag::Link);
    assert_eq!(dest(&d, link), "/url");
    assert_eq!(s(&d, fc(&d, link)), "foo");
}

#[test]
fn collapsed_reference_link_resolves() {
    let d = parse_with_one_reference("[foo][]", "foo", "/url");
    assert_eq!(dest(&d, fc(&d, root(&d))), "/url");
}

#[test]
fn shortcut_reference_link_resolves() {
    let d = parse_with_one_reference("[foo]", "foo", "/url");
    assert_eq!(dest(&d, fc(&d, root(&d))), "/url");
}

#[test]
fn unresolved_reference_falls_back_to_literal() {
    let d = parse_with_one_reference("[foo][nope]", "bar", "/url");
    assert_eq!(concat_str_children(&d, root(&d)), "[foo][nope]");
}

#[test]
fn inline_link_without_refs_resolves() {
    let d = p("[link](url)");
    assert_eq!(k(&d, fc(&d, root(&d))).tag(), Tag::Link);
}

#[test]
fn span_str_leaf_exact_bytes() {
    let src = "hello world";
    let d = pm(src, opts());
    assert_eq!(sp(&d, fc(&d, root(&d)), src), src);
}

#[test]
fn span_emphasis_covers_delimiters() {
    let src = "*abc*";
    let d = pm(src, opts());
    let em = fc(&d, root(&d));
    assert!(is_mark(&d, em, InlineMark::Emph));
    assert_eq!(sp(&d, em, src), "*abc*");
    assert_eq!(csp(&d, em, src), "abc");
}

#[test]
fn span_text_directive_label_children() {
    let src = "x :abbr[a *b* c] y";
    let d = pm(src, directives_on());
    let dir = ns(&d, fc(&d, root(&d)));
    assert_eq!(k(&d, dir).tag(), Tag::Container);
    assert_eq!(sp(&d, dir, src), ":abbr[a *b* c]");
    assert_eq!(csp(&d, dir, src), "a *b* c");
    let first = fc(&d, dir);
    assert_eq!(sp(&d, first, src), "a ");
    let emph = ns(&d, first);
    assert!(is_mark(&d, emph, InlineMark::Emph));
    assert_eq!(sp(&d, emph, src), "*b*");
    assert_eq!(csp(&d, emph, src), "b");
    assert_eq!(sp(&d, ns(&d, emph), src), " c");
}

#[test]
fn span_nested_text_directive() {
    let src = "x :vis[a :vis[b]{.x} c]{.y} y";
    let d = pm(src, directives_on());
    let outer = ns(&d, fc(&d, root(&d)));
    assert_eq!(sp(&d, outer, src), ":vis[a :vis[b]{.x} c]{.y}");
    assert_eq!(csp(&d, outer, src), "a :vis[b]{.x} c");
    let inner = ns(&d, fc(&d, outer));
    assert_eq!(sp(&d, inner, src), ":vis[b]{.x}");
    assert_eq!(csp(&d, inner, src), "b");
}

#[test]
fn span_strong_covers_delimiters() {
    let src = "**abc**";
    let d = pm(src, opts());
    let strong = fc(&d, root(&d));
    assert!(is_mark(&d, strong, InlineMark::Strong));
    assert_eq!(sp(&d, strong, src), "**abc**");
    assert_eq!(csp(&d, strong, src), "abc");
}

#[test]
fn span_verbatim() {
    let src = "`code`";
    let d = pm(src, opts());
    let v = fc(&d, root(&d));
    assert!(is_leaf(&d, v, TextLeafKind::Verbatim));
    assert_eq!(sp(&d, v, src), "`code`");
    assert_eq!(csp(&d, v, src), "code");
}

#[test]
fn span_multi_backtick_verbatim() {
    let src = "``x``";
    let d = pm(src, opts());
    assert_eq!(csp(&d, fc(&d, root(&d)), src), "x");
}

#[test]
fn span_verbatim_content_span_is_raw() {
    let src = "`` `foo` ``";
    let d = pm(src, opts());
    let v = fc(&d, root(&d));
    assert_eq!(leaf_text(&d, v), "`foo`");
    assert_eq!(csp(&d, v, src), " `foo` ");
}

#[test]
fn span_math_content_spans() {
    let math = ParseOptions { math: true, ..opts() };
    let s1 = "$x$";
    let d = pm(s1, math);
    let n = fc(&d, root(&d));
    assert!(is_leaf(&d, n, TextLeafKind::InlineMath));
    assert_eq!(sp(&d, n, s1), "$x$");
    assert_eq!(csp(&d, n, s1), "x");
    let s2 = "$$x$$";
    let d = pm(s2, math);
    let n = fc(&d, root(&d));
    assert!(is_leaf(&d, n, TextLeafKind::DisplayMath));
    assert_eq!(sp(&d, n, s2), "$$x$$");
    assert_eq!(csp(&d, n, s2), "x");
}

#[test]
fn span_footnote_reference_content_span_is_raw_label() {
    let src = "see[^ A B ]";
    let d = pm(src, ParseOptions { footnotes: true, ..opts() });
    let r = ns(&d, fc(&d, root(&d)));
    assert!(is_leaf(&d, r, TextLeafKind::FootnoteReference));
    assert_eq!(sp(&d, r, src), "[^ A B ]");
    assert_eq!(leaf_text(&d, r), "a b");
    assert_eq!(csp(&d, r, src), " A B ");
}

#[test]
fn span_core_autolink_content_span() {
    let s1 = "<http://x.dev>";
    let d = pm(s1, opts());
    let url = fc(&d, root(&d));
    assert!(is_leaf(&d, url, TextLeafKind::Url));
    assert_eq!(sp(&d, url, s1), s1);
    assert_eq!(csp(&d, url, s1), "http://x.dev");
    let s2 = "<a@b.com>";
    let d = pm(s2, opts());
    let mail = fc(&d, root(&d));
    assert!(is_leaf(&d, mail, TextLeafKind::Email));
    assert_eq!(csp(&d, mail, s2), "a@b.com");
    let d = pm("https://x.dev", ParseOptions { autolinks: true, ..opts() });
    let url2 = fc(&d, root(&d));
    assert!(is_leaf(&d, url2, TextLeafKind::Url));
    assert!(d.content_span(url2).is_none());
}

#[test]
fn span_partially_consumed_delimiter_run() {
    let src = "*a **b***";
    let d = pm(src, opts());
    let emph = fc(&d, root(&d));
    assert!(is_mark(&d, emph, InlineMark::Emph));
    assert_eq!(sp(&d, emph, src), "*a **b***");
    assert_eq!(csp(&d, emph, src), "a **b**");
    assert!(no_next(&d, emph));
    let a_space = fc(&d, emph);
    assert_eq!(sp(&d, a_space, src), "a ");
    let strong = ns(&d, a_space);
    assert!(is_mark(&d, strong, InlineMark::Strong));
    assert_eq!(sp(&d, strong, src), "**b**");
    assert_eq!(csp(&d, strong, src), "b");
    assert!(no_next(&d, strong));
}

#[test]
fn span_inline_link() {
    let src = "[x](http://a.co)";
    let d = pm(src, opts());
    let link = fc(&d, root(&d));
    assert_eq!(sp(&d, link, src), src);
    assert_eq!(csp(&d, link, src), "x");
}

#[test]
fn span_inline_image() {
    let src = "![alt](/a.png)";
    let d = pm(src, opts());
    let img = fc(&d, root(&d));
    assert_eq!(sp(&d, img, src), src);
    assert_eq!(csp(&d, img, src), "alt");
}

#[test]
fn span_code_span_backticks() {
    let src = "a `bc` d";
    let d = pm(src, opts());
    let code = ns(&d, fc(&d, root(&d)));
    assert!(is_leaf(&d, code, TextLeafKind::Verbatim));
    assert_eq!(sp(&d, code, src), "`bc`");
}

#[test]
fn span_strikethrough() {
    let src = "~~gone~~";
    let d = pm(src, ParseOptions { strikethrough: true, ..opts() });
    let del = fc(&d, root(&d));
    assert!(is_mark(&d, del, InlineMark::Delete));
    assert_eq!(sp(&d, del, src), src);
    assert_eq!(csp(&d, del, src), "gone");
}

#[test]
fn span_autolink_brackets() {
    let src = "<http://a.co>";
    let d = pm(src, opts());
    assert_eq!(sp(&d, fc(&d, root(&d)), src), src);
}

#[test]
fn span_unmapped_left_unset() {
    let d = p("*abc*");
    let em = fc(&d, root(&d));
    assert_eq!(d.span(em), Span::new(0, 0));
}

#[test]
fn footnote_reference_when_flag_on() {
    let d = po("see[^a]", ParseOptions { footnotes: true, ..opts() });
    let text = fc(&d, root(&d));
    assert_eq!(s(&d, text), "see");
    let r = ns(&d, text);
    assert!(is_leaf(&d, r, TextLeafKind::FootnoteReference));
    assert_eq!(leaf_text(&d, r), "a");
    assert!(no_next(&d, r));
}

#[test]
fn footnote_reference_label_normalized() {
    let d = po("[^ A  B ]", ParseOptions { footnotes: true, ..opts() });
    let r = fc(&d, root(&d));
    assert_eq!(leaf_text(&d, r), "a b");
}

#[test]
fn footnote_reference_off_is_literal() {
    let d = po("[^a]", ParseOptions { footnotes: false, ..opts() });
    assert_eq!(concat_str_children(&d, root(&d)), "[^a]");
}

#[test]
fn strikethrough_double() {
    let d = po("~~gone~~", ParseOptions { strikethrough: true, ..opts() });
    let del = fc(&d, root(&d));
    assert!(is_mark(&d, del, InlineMark::Delete));
    assert_eq!(s(&d, fc(&d, del)), "gone");
}

#[test]
fn strikethrough_single() {
    let d = po("~gone~", ParseOptions { strikethrough: true, ..opts() });
    let del = fc(&d, root(&d));
    assert!(is_mark(&d, del, InlineMark::Delete));
    assert_eq!(s(&d, fc(&d, del)), "gone");
}

#[test]
fn strikethrough_three_tildes_literal() {
    let d = po("~~~not~~~", ParseOptions { strikethrough: true, ..opts() });
    assert_eq!(s(&d, fc(&d, root(&d))), "~~~not~~~");
}

#[test]
fn strikethrough_off_literal() {
    let d = po("~~gone~~", ParseOptions { strikethrough: false, ..opts() });
    assert_eq!(s(&d, fc(&d, root(&d))), "~~gone~~");
}

#[test]
fn strikethrough_nests_inside_emphasis() {
    let d = po("*a ~~b~~ c*", ParseOptions { strikethrough: true, ..opts() });
    let emph = fc(&d, root(&d));
    assert!(is_mark(&d, emph, InlineMark::Emph));
    assert!(no_next(&d, emph));
    let a = fc(&d, emph);
    assert_eq!(s(&d, a), "a ");
    let del = ns(&d, a);
    assert!(is_mark(&d, del, InlineMark::Delete));
    assert_eq!(s(&d, fc(&d, del)), "b");
    assert_eq!(s(&d, ns(&d, del)), " c");
    assert_eq!(flat(&d), "a b c");
}

#[test]
fn strikethrough_wraps_emphasis() {
    let d = po("~~*a*~~", ParseOptions { strikethrough: true, ..opts() });
    let del = fc(&d, root(&d));
    assert!(is_mark(&d, del, InlineMark::Delete));
    let emph = fc(&d, del);
    assert!(is_mark(&d, emph, InlineMark::Emph));
    assert_eq!(s(&d, fc(&d, emph)), "a");
}

#[test]
fn strikethrough_interleaved_with_emphasis() {
    let d = po("~~a *b~~ c*", ParseOptions { strikethrough: true, ..opts() });
    let del = fc(&d, root(&d));
    assert!(is_mark(&d, del, InlineMark::Delete));
    let mut buf = String::new();
    inline_text_of(&d, del, &mut buf);
    assert_eq!(buf, "a *b");
    assert_eq!(k(&d, fc(&d, del)).tag(), Tag::Str);
    let mut rest = String::new();
    let mut kid = d.ast.nodes[del as usize].next_sibling;
    while let Some(id) = kid {
        rest.push_str(s(&d, id));
        kid = d.ast.nodes[id as usize].next_sibling;
    }
    assert_eq!(rest, " c*");
}

#[test]
fn strikethrough_inside_link_text() {
    let d = po("[x ~~y~~](/u)", ParseOptions { strikethrough: true, ..opts() });
    let link = fc(&d, root(&d));
    assert_eq!(k(&d, link).tag(), Tag::Link);
    assert!(is_mark(&d, ns(&d, fc(&d, link)), InlineMark::Delete));
}

fn hl() -> ParseOptions {
    ParseOptions { highlight: true, ..opts() }
}

#[test]
fn highlight_mark_when_on() {
    let d = po("==lit==", hl());
    let mark = fc(&d, root(&d));
    assert!(is_mark(&d, mark, InlineMark::Mark));
    assert_eq!(s(&d, fc(&d, mark)), "lit");
    assert!(no_next(&d, mark));
}

#[test]
fn highlight_off_literal() {
    let d = po("==lit==", opts());
    let c = fc(&d, root(&d));
    assert_eq!(s(&d, c), "==lit==");
    assert!(no_next(&d, c));
}

#[test]
fn highlight_single_equals_never_delimits() {
    let d = po("=a= and x = y", hl());
    let c = fc(&d, root(&d));
    assert_eq!(s(&d, c), "=a= and x = y");
    assert!(no_next(&d, c));
}

#[test]
fn highlight_three_equals_literal() {
    let d = po("===not===", hl());
    let c = fc(&d, root(&d));
    assert_eq!(s(&d, c), "===not===");
    assert!(no_next(&d, c));
}

#[test]
fn highlight_unclosed_literal() {
    let d = po("==open and done", hl());
    assert!(all_str(&d, root(&d)));
    assert_eq!(flat(&d), "==open and done");
}

#[test]
fn highlight_escaped_literal() {
    let d = po("\\==not==", hl());
    assert!(all_str(&d, root(&d)));
    assert_eq!(flat(&d), "==not==");
}

#[test]
fn highlight_nests_inside_and_wraps_emphasis() {
    let d = po("*a ==b== c* ==*d*==", hl());
    let emph = fc(&d, root(&d));
    assert!(is_mark(&d, emph, InlineMark::Emph));
    let a = fc(&d, emph);
    assert_eq!(s(&d, a), "a ");
    let inner = ns(&d, a);
    assert!(is_mark(&d, inner, InlineMark::Mark));
    assert_eq!(s(&d, fc(&d, inner)), "b");
    assert_eq!(s(&d, ns(&d, inner)), " c");
    let space = ns(&d, emph);
    assert_eq!(s(&d, space), " ");
    let outer = ns(&d, space);
    assert!(is_mark(&d, outer, InlineMark::Mark));
    assert!(is_mark(&d, fc(&d, outer), InlineMark::Emph));
    assert!(no_next(&d, outer));
}

#[test]
fn highlight_and_strikethrough_never_cross_close() {
    let d = po("==a~~ ~~b== ~~c~~", ParseOptions { highlight: true, strikethrough: true, ..opts() });
    let mark = fc(&d, root(&d));
    assert!(is_mark(&d, mark, InlineMark::Mark));
    assert!(all_str(&d, mark));
    let mut buf = String::new();
    inline_text_of(&d, mark, &mut buf);
    assert_eq!(buf, "a~~ ~~b");
    let del = ns(&d, ns(&d, mark));
    assert!(is_mark(&d, del, InlineMark::Delete));
    assert_eq!(s(&d, fc(&d, del)), "c");
}

#[test]
fn highlight_inside_link_text() {
    let d = po("[x ==y==](/u)", hl());
    let link = fc(&d, root(&d));
    assert_eq!(k(&d, link).tag(), Tag::Link);
    assert!(is_mark(&d, ns(&d, fc(&d, link)), InlineMark::Mark));
}

#[test]
fn highlight_intraword() {
    let d = po("foo==bar==baz", hl());
    let foo = fc(&d, root(&d));
    assert_eq!(s(&d, foo), "foo");
    let mark = ns(&d, foo);
    assert!(is_mark(&d, mark, InlineMark::Mark));
    assert_eq!(s(&d, fc(&d, mark)), "bar");
    assert_eq!(s(&d, ns(&d, mark)), "baz");
}

fn expect_colored_mark(d: &Document, id: NodeId, color: &str, inner: &str) {
    assert!(is_mark(d, id, InlineMark::Mark));
    assert_eq!(attr(d, id, highlight::ATTR_KEY), color);
    let c = fc(d, id);
    assert_eq!(s(d, c), inner);
    assert!(no_next(d, c));
}

#[test]
fn highlight_colors_red_spaced() {
    let d = po("==\u{1F534} lit==", colors_on());
    let mark = fc(&d, root(&d));
    expect_colored_mark(&d, mark, "red", "lit");
    assert!(no_next(&d, mark));
    assert_eq!(d.spelling(mark), Some(Spelling::HighlightPrefix(HighlightPrefix::Spaced)));
}

#[test]
fn highlight_colors_tight() {
    let d = po("==\u{1F534}lit==", colors_on());
    let mark = fc(&d, root(&d));
    expect_colored_mark(&d, mark, "red", "lit");
    assert_eq!(d.spelling(mark), Some(Spelling::HighlightPrefix(HighlightPrefix::Tight)));
}

#[test]
fn highlight_colors_every_circle() {
    for c in highlight::Color::ALL {
        let src = format!("=={} x==", c.emoji());
        let d = po(&src, colors_on());
        expect_colored_mark(&d, fc(&d, root(&d)), c.name(), "x");
    }
}

#[test]
fn highlight_colors_off_emoji_is_text() {
    let d = po("==\u{1F534} lit==", hl());
    let mark = fc(&d, root(&d));
    assert!(is_mark(&d, mark, InlineMark::Mark));
    assert!(d.ast.nodes[mark as usize].attrs.is_none());
    assert_eq!(s(&d, fc(&d, mark)), "\u{1F534} lit");
    assert!(d.spelling(mark).is_none());
}

#[test]
fn highlight_colors_without_highlight_inert() {
    let d = po("==\u{1F534} lit==", ParseOptions { highlight_colors: true, ..opts() });
    let c = fc(&d, root(&d));
    assert_eq!(s(&d, c), "==\u{1F534} lit==");
    assert!(no_next(&d, c));
}

#[test]
fn highlight_colors_non_circle_emoji_stays_content() {
    let d = po("==\u{1F34E} lit==", colors_on());
    let mark = fc(&d, root(&d));
    assert!(is_mark(&d, mark, InlineMark::Mark));
    assert!(d.ast.nodes[mark as usize].attrs.is_none());
    assert_eq!(s(&d, fc(&d, mark)), "\u{1F34E} lit");
}

#[test]
fn highlight_colors_only_start_takes_colour() {
    let d = po("==lit \u{1F534}==", colors_on());
    let mark = fc(&d, root(&d));
    assert!(d.ast.nodes[mark as usize].attrs.is_none());
    assert_eq!(s(&d, fc(&d, mark)), "lit \u{1F534}");
}

#[test]
fn highlight_colors_prefix_on_closing_run_stays_literal() {
    let d = po("==a==\u{1F534} b==", colors_on());
    let mark = fc(&d, root(&d));
    assert!(is_mark(&d, mark, InlineMark::Mark));
    assert!(d.ast.nodes[mark as usize].attrs.is_none());
    let mut rest = String::new();
    let mut kid = d.ast.nodes[mark as usize].next_sibling;
    while let Some(id) = kid {
        rest.push_str(s(&d, id));
        kid = d.ast.nodes[id as usize].next_sibling;
    }
    assert_eq!(rest, "\u{1F534} b==");
}

#[test]
fn highlight_colors_unclosed_opener_literal() {
    let d = po("==\u{1F534} open", colors_on());
    assert!(all_str(&d, root(&d)));
    assert_eq!(flat(&d), "==\u{1F534} open");
}

#[test]
fn highlight_colors_survive_nesting() {
    let d = po("*a ==\u{1F7E2} b== c*", colors_on());
    let emph = fc(&d, root(&d));
    expect_colored_mark(&d, ns(&d, fc(&d, emph)), "green", "b");
}

#[test]
fn span_coloured_highlight() {
    let src = "==\u{1F534} lit==";
    let d = pm(src, colors_on());
    let mark = fc(&d, root(&d));
    expect_colored_mark(&d, mark, "red", "lit");
    assert_eq!(sp(&d, mark, src), src);
    assert_eq!(csp(&d, mark, src), "lit");
    let m = d.marker_span(mark).unwrap();
    assert_eq!(&src[m.start..m.end], "\u{1F534} ");
    assert_eq!(sp(&d, fc(&d, mark), src), "lit");
}

#[test]
fn span_highlight_mark() {
    let src = "==lit==";
    let d = pm(src, hl());
    let mark = fc(&d, root(&d));
    assert_eq!(sp(&d, mark, src), src);
    assert_eq!(csp(&d, mark, src), "lit");
}

#[test]
fn inline_math_on() {
    let d = po("$x^2$", ParseOptions { math: true, ..opts() });
    let c = fc(&d, root(&d));
    assert!(is_leaf(&d, c, TextLeafKind::InlineMath));
    assert_eq!(leaf_text(&d, c), "x^2");
}

#[test]
fn display_math_on() {
    let d = po("$$x^2$$", ParseOptions { math: true, ..opts() });
    let c = fc(&d, root(&d));
    assert!(is_leaf(&d, c, TextLeafKind::DisplayMath));
    assert_eq!(leaf_text(&d, c), "x^2");
}

#[test]
fn math_off_literal() {
    let d = p("$x$");
    assert_eq!(s(&d, fc(&d, root(&d))), "$x$");
}

#[test]
fn math_dollar_then_space_never_opens() {
    let d = po("costs $5 and $10 total", ParseOptions { math: true, ..opts() });
    assert_eq!(s(&d, fc(&d, root(&d))), "costs $5 and $10 total");
}

fn al() -> ParseOptions {
    ParseOptions { autolinks: true, ..opts() }
}

#[test]
fn ext_autolink_bare_https() {
    let d = po("see https://example.com/x for more", al());
    let s1 = fc(&d, root(&d));
    assert_eq!(s(&d, s1), "see ");
    let url = ns(&d, s1);
    assert!(is_leaf(&d, url, TextLeafKind::Url));
    assert_eq!(leaf_text(&d, url), "https://example.com/x");
}

#[test]
fn ext_autolink_www_prefix() {
    let d = po("visit www.example.com now", al());
    let link = ns(&d, fc(&d, root(&d)));
    assert_eq!(dest(&d, link), "http://www.example.com");
    assert_eq!(s(&d, fc(&d, link)), "www.example.com");
}

#[test]
fn ext_autolink_trailing_punct_trimmed() {
    let d = po("Check https://example.com.", al());
    let url = ns(&d, fc(&d, root(&d)));
    assert_eq!(leaf_text(&d, url), "https://example.com");
    assert_eq!(s(&d, ns(&d, url)), ".");
}

#[test]
fn ext_autolink_balanced_paren_kept() {
    let d = po("(see https://en.wikipedia.org/wiki/Foo_(bar))", al());
    let url = ns(&d, fc(&d, root(&d)));
    assert_eq!(leaf_text(&d, url), "https://en.wikipedia.org/wiki/Foo_(bar)");
    assert_eq!(s(&d, ns(&d, url)), ")");
}

#[test]
fn ext_autolink_bare_email() {
    let d = po("contact foo@bar.example.com today", al());
    let s1 = fc(&d, root(&d));
    assert_eq!(s(&d, s1), "contact ");
    let email = ns(&d, s1);
    assert!(is_leaf(&d, email, TextLeafKind::Email));
    assert_eq!(leaf_text(&d, email), "foo@bar.example.com");
}

#[test]
fn ext_autolinks_off_literal() {
    let d = po("see www.example.com and https://x.com", ParseOptions { autolinks: false, ..opts() });
    assert_eq!(concat_str_children(&d, root(&d)), "see www.example.com and https://x.com");
}

#[test]
fn ext_autolink_word_internal_does_not_link() {
    let d = po("xhttp://example.com", al());
    assert_eq!(s(&d, fc(&d, root(&d))), "xhttp://example.com");
}

#[test]
fn ext_autolink_open_bracket_suppresses_url() {
    let d = po("[a https://x.dev](d)", al());
    let link = fc(&d, root(&d));
    assert_eq!(dest(&d, link), "d");
    let mut it = d.ast.children(link);
    assert_eq!(it.next().unwrap().kind, Kind::Str(b"a https://x.dev".to_vec()));
    assert!(it.next().is_none());
}

#[test]
fn ext_autolink_unmatched_bracket_suppresses_rest() {
    let d = po("[a https://x.dev", al());
    for n in d.ast.children(root(&d)) {
        assert!(!n.kind.is_text_leaf(TextLeafKind::Url) && n.kind.tag() != Tag::Link);
    }
}

#[test]
fn ext_autolink_closed_bracket_releases() {
    let d = po("[a] https://x.dev", al());
    let found = d
        .ast
        .children(root(&d))
        .filter(|n| n.kind.is_text_leaf(TextLeafKind::Url))
        .inspect(|n| assert_eq!(n.kind, Kind::TextLeaf { kind: TextLeafKind::Url, text: b"https://x.dev".to_vec() }))
        .count();
    assert_eq!(found, 1);
}

#[test]
fn ext_autolink_close_bracket_is_url_byte() {
    let d = po("www.example.com/a]b", al());
    assert_eq!(dest(&d, fc(&d, root(&d))), "http://www.example.com/a]b");
}

#[test]
fn ext_autolink_email_in_resolved_link_demoted() {
    let d = po("[a b@c.de](d)", al());
    let link = fc(&d, root(&d));
    assert_eq!(k(&d, link).tag(), Tag::Link);
    let a = fc(&d, link);
    assert_eq!(s(&d, a), "a ");
    assert_eq!(s(&d, ns(&d, a)), "b@c.de");
}

#[test]
fn ext_autolink_email_in_unresolved_bracket_links() {
    let d = po("[a b@c.de]", al());
    let n = d.ast.children(root(&d)).filter(|n| n.kind.is_text_leaf(TextLeafKind::Email)).count();
    assert_eq!(n, 1);
}

#[test]
fn ext_autolink_demotion_reaches_nested_email() {
    let d = po("[a *b@c.de*](d)", al());
    let link = fc(&d, root(&d));
    let em = ns(&d, fc(&d, link));
    assert!(is_mark(&d, em, InlineMark::Emph));
    assert_eq!(s(&d, fc(&d, em)), "b@c.de");
}

#[test]
fn ext_autolink_demotion_scoped_to_link() {
    let d = po("[a b@c.de](d) and e@f.gh", al());
    let emails: Vec<_> = d.ast.children(root(&d)).filter(|n| n.kind.is_text_leaf(TextLeafKind::Email)).collect();
    assert_eq!(emails.len(), 1);
    assert_eq!(emails[0].kind, Kind::TextLeaf { kind: TextLeafKind::Email, text: b"e@f.gh".to_vec() });
}

#[test]
fn ext_autolink_core_email_in_link_not_demoted() {
    let d = po("[a <b@c.de>](d)", al());
    let link = fc(&d, root(&d));
    let inner = ns(&d, fc(&d, link));
    assert!(is_leaf(&d, inner, TextLeafKind::Email));
    assert_eq!(leaf_text(&d, inner), "b@c.de");
}

#[test]
fn ext_autolink_email_in_image_not_demoted() {
    let d = po("![a b@c.de](i)", al());
    let img = fc(&d, root(&d));
    assert_eq!(k(&d, img).tag(), Tag::Image);
    assert!(is_leaf(&d, ns(&d, fc(&d, img)), TextLeafKind::Email));
}
