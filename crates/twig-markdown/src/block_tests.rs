//! `block.zig`'s and `markdown.zig`'s unit tests, ported. They run the full
//! pipeline (`parse`), so ids are compacted.

use super::*;
use crate::ast::{Alignment, Ast, InlineMark, Kind, NodeId, Tag, TextLeafKind};
use crate::document::{ContainerOrigin, Document};
use twig_kit::html;

fn opts() -> ParseOptions {
    ParseOptions::default()
}
fn pr(src: &str) -> Document {
    parse(src.as_bytes(), opts())
}
fn pro(src: &str, o: ParseOptions) -> Document {
    parse(src.as_bytes(), o)
}
fn render_html(src: &str, o: ParseOptions) -> String {
    let d = pro(src, o);
    String::from_utf8(html::serialize_alloc(&d.ast, None).unwrap()).unwrap()
}
fn fc(d: &Document, id: NodeId) -> NodeId {
    d.ast.nodes[id as usize].first_child.expect("first child")
}
fn first(d: &Document) -> NodeId {
    fc(d, d.ast.root)
}
fn ns(d: &Document, id: NodeId) -> NodeId {
    d.ast.nodes[id as usize].next_sibling.expect("next sibling")
}
fn no_next(d: &Document, id: NodeId) -> bool {
    d.ast.nodes[id as usize].next_sibling.is_none()
}
fn no_child(d: &Document, id: NodeId) -> bool {
    d.ast.nodes[id as usize].first_child.is_none()
}
fn last(d: &Document) -> NodeId {
    let mut l = first(d);
    while let Some(n) = d.ast.nodes[l as usize].next_sibling {
        l = n;
    }
    l
}
fn k(d: &Document, id: NodeId) -> &Kind {
    &d.ast.nodes[id as usize].kind
}
fn tag(d: &Document, id: NodeId) -> Tag {
    k(d, id).tag()
}
fn s(d: &Document, id: NodeId) -> &str {
    std::str::from_utf8(k(d, id).str_text().expect("str")).unwrap()
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
fn code_text(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::CodeBlock { text, .. } => std::str::from_utf8(text).unwrap(),
        other => panic!("{other:?}"),
    }
}
fn meta(d: &Document, id: NodeId) -> (&str, &str) {
    match k(d, id) {
        Kind::Metadata { lang, text } => (std::str::from_utf8(lang).unwrap(), std::str::from_utf8(text).unwrap()),
        other => panic!("{other:?}"),
    }
}
fn dest(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::Link(l) | Kind::Image(l) => std::str::from_utf8(l.destination.as_deref().unwrap()).unwrap(),
        other => panic!("{other:?}"),
    }
}
fn container_name(d: &Document, id: NodeId) -> &str {
    match k(d, id) {
        Kind::Container(c) => std::str::from_utf8(&c.name).unwrap(),
        other => panic!("{other:?}"),
    }
}
fn find_first_kind(ast: &Ast, id: NodeId, t: Tag) -> Option<NodeId> {
    if ast.nodes[id as usize].kind.tag() == t {
        return Some(id);
    }
    for c in ast.children(id) {
        if let Some(f) = find_first_kind(ast, c.id, t) {
            return Some(f);
        }
    }
    None
}
fn find_element_named(ast: &Ast, id: NodeId, name: &str) -> Option<NodeId> {
    for c in ast.children(id) {
        if matches!(&c.kind, Kind::Container(cc) if cc.name == name.as_bytes()) {
            return Some(c.id);
        }
        if let Some(f) = find_element_named(ast, c.id, name) {
            return Some(f);
        }
    }
    None
}
fn directives_on() -> ParseOptions {
    ParseOptions { directives: true, ..opts() }
}
fn html_on() -> ParseOptions {
    ParseOptions { html_elements: true, ..opts() }
}

// ── markdown.zig ─────────────────────────────────────────────────────────

#[test]
fn parse_produces_a_doc_with_a_paragraph() {
    let d = pr("hello world\n");
    assert_eq!(*k(&d, d.ast.root), Kind::Doc);
    assert_eq!(tag(&d, first(&d)), Tag::Para);
}

#[test]
fn headings_are_flat() {
    let d = pr("# Hello World\n\npara\n");
    let h = first(&d);
    assert_eq!(*k(&d, h), Kind::Heading { level: 1 });
    assert!(d.ast.attrs_of(h).is_empty());
    assert_eq!(tag(&d, ns(&d, h)), Tag::Para);
}

#[test]
fn spells_autolink_matches_the_scanner() {
    assert!(spells_autolink(b"<http://a.b>"));
    assert!(spells_autolink(b"<a@b.co>"));
    assert!(!spells_autolink(b"<span>"));
    assert!(!spells_autolink(b"<http://a.b> x"));
    assert!(!spells_autolink(b"x"));
}

#[test]
fn samples_parse() {
    for s in SAMPLES.iter().chain(COMMONMARK_SAMPLES).chain(GFM_SAMPLES) {
        let d = parse(s, opts());
        assert_eq!(d.span(d.ast.root).end, s.len());
    }
}

// ── block.zig ────────────────────────────────────────────────────────────

#[test]
fn atx_heading() {
    let d = pr("## Hello\n");
    let h = first(&d);
    assert_eq!(*k(&d, h), Kind::Heading { level: 2 });
    assert_eq!(s(&d, fc(&d, h)), "Hello");
}

#[test]
fn span_link_in_single_line_paragraph() {
    let src = "see [x](http://a.co) now\n";
    let d = pr(src);
    let link = ns(&d, fc(&d, first(&d)));
    assert_eq!(tag(&d, link), Tag::Link);
    assert_eq!(sp(&d, link, src), "[x](http://a.co)");
    assert_eq!(csp(&d, link, src), "x");
}

#[test]
fn span_link_inside_heading() {
    let src = "## see [x](http://a.co) now\n";
    let d = pr(src);
    let link = ns(&d, fc(&d, first(&d)));
    assert_eq!(sp(&d, link, src), "[x](http://a.co)");
}

#[test]
fn span_emphasis_in_paragraph() {
    let src = "hi *abc* there\n";
    let d = pr(src);
    let em = ns(&d, fc(&d, first(&d)));
    assert!(k(&d, em).is_inline_mark(InlineMark::Emph));
    assert_eq!(sp(&d, em, src), "*abc*");
    assert_eq!(csp(&d, em, src), "abc");
}

#[test]
fn span_code_span_backticks() {
    let src = "x `code` y\n";
    let d = pr(src);
    let code = ns(&d, fc(&d, first(&d)));
    assert!(k(&d, code).is_text_leaf(TextLeafKind::Verbatim));
    assert_eq!(sp(&d, code, src), "`code`");
}

#[test]
fn span_str_in_block_quote() {
    let src = "> hello world\n";
    let d = pr(src);
    let st = fc(&d, fc(&d, first(&d)));
    assert_eq!(sp(&d, st, src), "hello world");
}

#[test]
fn span_inline_straddling_line_join() {
    let src = "a *b\nc* d\n";
    let d = pr(src);
    let f = fc(&d, first(&d));
    assert_eq!(sp(&d, f, src), "a ");
    let em = ns(&d, f);
    assert!(k(&d, em).is_inline_mark(InlineMark::Emph));
    assert_eq!(sp(&d, em, src), "*b\nc*");
}

#[test]
fn span_text_directive_label_straddling_line_join() {
    let src = "x :abbr[a *b*\nc] y\n";
    let d = pro(src, directives_on());
    let dir = ns(&d, fc(&d, first(&d)));
    assert_eq!(tag(&d, dir), Tag::Container);
    let f = fc(&d, dir);
    assert_eq!(sp(&d, f, src), "a ");
    let em = ns(&d, f);
    assert!(k(&d, em).is_inline_mark(InlineMark::Emph));
    assert_eq!(sp(&d, em, src), "*b*");
    let brk = ns(&d, em);
    assert_eq!(*k(&d, brk), Kind::SoftBreak);
    assert_eq!(sp(&d, ns(&d, brk), src), "c");
}

#[test]
fn span_verbatim_across_two_lines() {
    let src = "x `a\nb` y\n";
    let d = pr(src);
    let v = ns(&d, fc(&d, first(&d)));
    assert!(k(&d, v).is_text_leaf(TextLeafKind::Verbatim));
    assert_eq!(sp(&d, v, src), "`a\nb`");
    assert_eq!(csp(&d, v, src), "a\nb");
}

#[test]
fn fenced_code_with_language() {
    let d = pr("```zig\nconst x = 1;\n```\n");
    let cb = first(&d);
    assert_eq!(*k(&d, cb), Kind::CodeBlock { lang: Some(b"zig".to_vec()), text: b"const x = 1;\n".to_vec() });
}

#[test]
fn content_span_fenced_code_interior() {
    let src = "```zig\nconst x = 1;\n```\n";
    let d = pr(src);
    let cb = first(&d);
    assert_eq!(sp(&d, cb, src), "```zig\nconst x = 1;\n```");
    assert_eq!(csp(&d, cb, src), "const x = 1;");
    assert_eq!(code_text(&d, cb), "const x = 1;\n");
}

#[test]
fn content_span_multi_line_fenced_body() {
    let src = "```\nline1\nline2\n```\n";
    let d = pr(src);
    assert_eq!(csp(&d, first(&d), src), "line1\nline2");
}

#[test]
fn content_span_empty_fenced_block() {
    let d = pr("```\n```\n");
    let cb = first(&d);
    assert_eq!(tag(&d, cb), Tag::CodeBlock);
    assert!(d.content_span(cb).is_none());
}

#[test]
fn content_span_frontmatter_interior() {
    let src = "---\ntitle: Hi\nx: 1\n---\n\nbody\n";
    let d = pro(src, ParseOptions { frontmatter: true, ..opts() });
    let fm = first(&d);
    assert_eq!(csp(&d, fm, src), "title: Hi\nx: 1");
    assert_eq!(meta(&d, fm).1, "title: Hi\nx: 1\n");
}

#[test]
fn content_span_empty_frontmatter() {
    let d = pro("---\n---\nbody\n", ParseOptions { frontmatter: true, ..opts() });
    let fm = first(&d);
    assert_eq!(tag(&d, fm), Tag::Metadata);
    assert!(d.content_span(fm).is_none());
}

#[test]
fn content_span_endmatter_interior() {
    let src = "body\n\n---toml\nx = 1\n---\n";
    let d = pro(src, ParseOptions { frontmatter: true, ..opts() });
    let l = last(&d);
    assert_eq!(tag(&d, l), Tag::Metadata);
    assert_eq!(csp(&d, l, src), "x = 1");
}

#[test]
fn content_span_unterminated_fence() {
    let src = "```\ncode\n";
    let d = pr(src);
    assert_eq!(csp(&d, first(&d), src), "code");
}

#[test]
fn content_span_indented_code_is_whole_block() {
    let src = "    abc\n";
    let d = pr(src);
    let cb = first(&d);
    assert_eq!(csp(&d, cb, src), "    abc");
    assert_eq!(code_text(&d, cb), "abc\n");
}

#[test]
fn span_indented_code_stops_at_last_content_line() {
    let src = "    code\n\n\n\nafter\n";
    let d = pr(src);
    let cb = first(&d);
    assert_eq!(sp(&d, cb, src), "    code");
    assert_eq!(csp(&d, cb, src), "    code");
    assert_eq!(code_text(&d, cb), "code\n");
}

#[test]
fn span_indented_code_keeps_inner_blank() {
    let src = "    a\n\n    b\n\nafter\n";
    let d = pr(src);
    let cb = first(&d);
    assert_eq!(sp(&d, cb, src), "    a\n\n    b");
    assert_eq!(code_text(&d, cb), "a\n\nb\n");
}

#[test]
fn span_indented_code_in_list_item() {
    let src = "- a\n\n      code\n\nafter\n";
    let d = pr(src);
    let item = fc(&d, first(&d));
    assert_eq!(tag(&d, item), Tag::ListItem);
    assert_eq!(sp(&d, item, src), "- a\n\n      code");
}

#[test]
fn tight_bullet_list_two_items() {
    let d = pr("- a\n- b\n");
    let list = first(&d);
    assert_eq!(*k(&d, list), Kind::BulletList { tight: true });
    let i2 = ns(&d, fc(&d, list));
    assert!(no_next(&d, i2));
}

#[test]
fn block_quote() {
    let d = pr("> foo\n> bar\n");
    let bq = first(&d);
    assert_eq!(tag(&d, bq), Tag::BlockQuote);
    assert_eq!(tag(&d, fc(&d, bq)), Tag::Para);
}

#[test]
fn html_block() {
    let d = pr("<div>\n  <p>hi</p>\n</div>\n");
    match k(&d, first(&d)) {
        Kind::RawBlock { format, .. } => assert_eq!(format, b"html"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn html_elements_off_html_block_stays_raw() {
    let d = pr("<img src=\"a.svg\" alt=\"x\">\n");
    assert_eq!(tag(&d, first(&d)), Tag::RawBlock);
}

#[test]
fn html_elements_img_block_promotes() {
    let d = pro("<img src=\"a.svg\" alt=\"x\">\n", html_on());
    assert!(find_first_kind(&d.ast, d.ast.root, Tag::RawBlock).is_none());
    let img = find_first_kind(&d.ast, d.ast.root, Tag::Image).unwrap();
    assert_eq!(dest(&d, img), "a.svg");
}

#[test]
fn html_elements_promoted_img_span() {
    let src = "intro\n\n<img src=\"assets/fig-banner.svg\" width=\"220\" alt=\"fig\">\n";
    let d = pro(src, html_on());
    let img = find_first_kind(&d.ast, d.ast.root, Tag::Image).unwrap();
    assert_eq!(sp(&d, img, src), "<img src=\"assets/fig-banner.svg\" width=\"220\" alt=\"fig\">");
}

#[test]
fn html_elements_picture_block() {
    let src = "<h1 align=\"center\">\n  <picture>\n    <source media=\"(prefers-color-scheme: dark)\" srcset=\"assets/fig-banner-dark.svg\">\n    <img src=\"assets/fig-banner.svg\" width=\"220\" alt=\"fig\">\n  </picture>\n</h1>\n";
    let d = pro(src, html_on());
    let heading = first(&d);
    assert_eq!(*k(&d, heading), Kind::Heading { level: 1 });
    let picture = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert_eq!(container_name(&d, picture), "picture");
    let source = find_element_named(&d.ast, picture, "source").unwrap();
    assert_eq!(attr(&d, source, "srcset"), "assets/fig-banner-dark.svg");
    let img = find_first_kind(&d.ast, picture, Tag::Image).unwrap();
    assert_eq!(dest(&d, img), "assets/fig-banner.svg");
}

#[test]
fn html_elements_one_line_video_is_block() {
    let d = pro("<video src=\"clip.mp4\" poster=\"still.png\" controls></video>\n", html_on());
    let v = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert_eq!(container_name(&d, v), "video");
    assert_eq!(attr(&d, v, "src"), "clip.mp4");
    assert_eq!(attr(&d, v, "poster"), "still.png");
}

#[test]
fn html_elements_one_line_audio_is_block() {
    let d = pro("<audio src=\"take.mp3\" controls></audio>\n", html_on());
    let a = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert_eq!(container_name(&d, a), "audio");
    assert_eq!(attr(&d, a, "src"), "take.mp3");
}

#[test]
fn html_elements_one_line_picture_is_block() {
    let src = "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"d.svg\"><img src=\"l.svg\" alt=\"banner\"></picture>\n";
    let d = pro(src, html_on());
    let p = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert_eq!(container_name(&d, p), "picture");
    let source = find_element_named(&d.ast, p, "source").unwrap();
    assert_eq!(attr(&d, source, "srcset"), "d.svg");
    let img = find_first_kind(&d.ast, p, Tag::Image).unwrap();
    assert_eq!(dest(&d, img), "l.svg");
}

#[test]
fn html_elements_off_one_line_video_is_paragraph() {
    let d = pr("<video src=\"clip.mp4\" controls></video>\n");
    assert_eq!(tag(&d, first(&d)), Tag::Para);
    assert!(find_first_kind(&d.ast, d.ast.root, Tag::Container).is_none());
}

#[test]
fn html_elements_img_amid_prose_stays_inline() {
    let d = pro("see <img src=\"a.svg\" alt=\"x\"> here\n", html_on());
    let p = first(&d);
    assert_eq!(tag(&d, p), Tag::Para);
    assert!(find_first_kind(&d.ast, p, Tag::Image).is_some());
}

#[test]
fn paragraph_with_code_span_and_hard_break() {
    let d = pr("foo `bar`  \nbaz\n");
    let para = first(&d);
    let code = ns(&d, fc(&d, para));
    assert_eq!(*k(&d, code), Kind::TextLeaf { kind: TextLeafKind::Verbatim, text: b"bar".to_vec() });
    assert_eq!(*k(&d, ns(&d, code)), Kind::HardBreak);
}

#[test]
fn link_reference_definition_is_stripped_and_recorded() {
    let d = pr("[foo]: /url \"title\"\n");
    assert!(no_child(&d, d.ast.root));
    let r = d.labels.reference(b"foo").unwrap();
    assert!(matches!(k(&d, r), Kind::Reference { destination, .. } if destination == b"/url"));
    assert_eq!(attr(&d, r, "title"), "title");
}

#[test]
fn span_link_reference_definition_covers_its_line() {
    let src = "intro\n\n[a]: /a\n[b]: /b \"bee\"\n\n[c]: /c\ntext\n\n[d]: /d\n  \"dee\"\n";
    let d = pr(src);
    let g = |l: &str| d.labels.reference(l.as_bytes()).unwrap();
    assert_eq!(sp(&d, g("a"), src), "[a]: /a");
    assert_eq!(sp(&d, g("b"), src), "[b]: /b \"bee\"");
    assert_eq!(sp(&d, g("c"), src), "[c]: /c");
    assert_eq!(sp(&d, g("d"), src), "[d]: /d\n  \"dee\"");
}

fn tables() -> ParseOptions {
    ParseOptions { tables: true, ..opts() }
}

#[test]
fn table_header_delimiter_body() {
    let d = pro("| a | b | c |\n|---|:--:|--:|\n| 1 | 2 | 3 |\n", tables());
    let table = first(&d);
    assert_eq!(tag(&d, table), Tag::Table);
    let caption = fc(&d, table);
    assert_eq!(tag(&d, caption), Tag::Caption);
    assert!(no_child(&d, caption));
    let head = ns(&d, caption);
    assert_eq!(*k(&d, head), Kind::Row { head: true });
    let c1 = fc(&d, head);
    let Kind::Cell(cell) = k(&d, c1) else { panic!() };
    assert!(cell.head);
    assert_eq!(cell.alignment, Alignment::Default);
    let c2 = ns(&d, c1);
    assert!(matches!(k(&d, c2), Kind::Cell(c) if c.alignment == Alignment::Center));
    let c3 = ns(&d, c2);
    assert!(matches!(k(&d, c3), Kind::Cell(c) if c.alignment == Alignment::Right));
    let body = ns(&d, head);
    assert_eq!(*k(&d, body), Kind::Row { head: false });
    assert!(no_next(&d, body));
}

#[test]
fn span_table_cells_pipe_to_pipe() {
    let src = "| a | **b** |\n|---|---|\n| 1 | 2 \\| 3 |\nno | pipes\n";
    let d = pro(src, tables());
    let table = first(&d);
    let head = ns(&d, fc(&d, table));
    let c1 = fc(&d, head);
    let c2 = ns(&d, c1);
    assert_eq!(sp(&d, c1, src), "| a ");
    assert_eq!(sp(&d, c2, src), "| **b** ");
    assert_eq!(csp(&d, c2, src), "**b**");
    let body = ns(&d, head);
    let b2 = ns(&d, fc(&d, body));
    assert_eq!(sp(&d, b2, src), "| 2 \\| 3 ");
    let last_row = ns(&d, body);
    let n1 = fc(&d, last_row);
    assert_eq!(sp(&d, n1, src), "no ");
    assert_eq!(sp(&d, ns(&d, n1), src), "| pipes");
    assert_eq!(sp(&d, head, src), "| a | **b** |");
}

#[test]
fn span_ragged_row_missing_cell() {
    let src = "| a | b |\n|---|---|\n| 1 |\n";
    let d = pro(src, tables());
    let head = ns(&d, fc(&d, first(&d)));
    let body = ns(&d, head);
    let b1 = fc(&d, body);
    let b2 = ns(&d, b1);
    assert_eq!(sp(&d, b1, src), "| 1 ");
    let s2 = d.span(b2);
    assert_eq!(s2.start, s2.end);
    assert_eq!(d.span(b1).end, s2.start);
}

#[test]
fn table_ragged_rows_padded_and_truncated() {
    let d = pro("| a | b |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |\n", tables());
    let head = ns(&d, fc(&d, first(&d)));
    let short = ns(&d, head);
    assert!(no_next(&d, ns(&d, fc(&d, short))));
    let long = ns(&d, short);
    assert!(no_next(&d, ns(&d, fc(&d, long))));
}

#[test]
fn table_renders_with_empty_caption() {
    assert_eq!(
        render_html("| a | b |\n| - | - |\n| 1 | 2 |\n", tables()),
        "<table>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</table>\n"
    );
}

#[test]
fn table_off_is_paragraph() {
    let d = pro("| a | b |\n| - | - |\n", ParseOptions { tables: false, ..opts() });
    let p = first(&d);
    assert_eq!(tag(&d, p), Tag::Para);
    assert!(no_next(&d, p));
}

#[test]
fn task_list_items() {
    let d = pro("- [ ] todo\n- [x] done\n- [X] also done\n", ParseOptions { task_lists: true, ..opts() });
    let list = first(&d);
    assert_eq!(tag(&d, list), Tag::TaskList);
    let i1 = fc(&d, list);
    assert_eq!(*k(&d, i1), Kind::TaskListItem { checked: false });
    assert_eq!(s(&d, fc(&d, fc(&d, i1))), "todo");
    let i2 = ns(&d, i1);
    assert_eq!(*k(&d, i2), Kind::TaskListItem { checked: true });
    assert_eq!(*k(&d, ns(&d, i2)), Kind::TaskListItem { checked: true });
}

#[test]
fn task_list_renders_checkbox() {
    assert_eq!(
        render_html("- [x] done\n", ParseOptions { task_lists: true, ..opts() }),
        "<ul class=\"task-list\">\n<li>\n<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\ndone\n</li>\n</ul>\n"
    );
}

#[test]
fn task_lists_off_plain_item() {
    let d = pro("- [ ] x\n", ParseOptions { task_lists: false, ..opts() });
    let list = first(&d);
    assert_eq!(tag(&d, list), Tag::BulletList);
    let item = fc(&d, list);
    assert_eq!(tag(&d, item), Tag::ListItem);
    let para = fc(&d, item);
    let text: String = d.ast.children(para).map(|n| std::str::from_utf8(n.kind.str_text().unwrap()).unwrap()).collect();
    assert_eq!(text, "[ ] x");
}

#[test]
fn extended_autolinks_render() {
    assert_eq!(
        render_html("visit www.example.com today\n", ParseOptions { autolinks: true, ..opts() }),
        "<p>visit <a href=\"http://www.example.com\">www.example.com</a> today</p>\n"
    );
}

#[test]
fn math_renders() {
    assert_eq!(
        render_html("$x$ and $$y$$\n", ParseOptions { math: true, ..opts() }),
        "<p><span class=\"math inline\">\\(x\\)</span> and <span class=\"math display\">\\[y\\]</span></p>\n"
    );
}

fn dl() -> ParseOptions {
    ParseOptions { definition_lists: true, ..opts() }
}

#[test]
fn definition_list_term_with_two_definitions() {
    let d = pro("Term\n: First definition\n: Second definition\n", dl());
    let list = first(&d);
    assert_eq!(tag(&d, list), Tag::DefinitionList);
    let item = fc(&d, list);
    assert_eq!(tag(&d, item), Tag::DefinitionListItem);
    assert!(no_next(&d, item));
    let term = fc(&d, item);
    assert_eq!(tag(&d, term), Tag::Term);
    assert_eq!(s(&d, fc(&d, term)), "Term");
    let d1 = ns(&d, term);
    assert_eq!(tag(&d, d1), Tag::Definition);
    assert_eq!(s(&d, fc(&d, d1)), "First definition");
    let d2 = ns(&d, d1);
    assert_eq!(s(&d, fc(&d, d2)), "Second definition");
    assert!(no_next(&d, d2));
}

#[test]
fn definition_list_groups_merge() {
    let d = pro("Term A\n: def a\n\nTerm B\n: def b\n", dl());
    let list = first(&d);
    assert!(no_next(&d, list));
    let i2 = ns(&d, fc(&d, list));
    assert!(no_next(&d, i2));
    assert_eq!(s(&d, fc(&d, fc(&d, i2))), "Term B");
}

#[test]
fn span_definition_list_contains_first_term() {
    let src = "Term\n: def\n\nafter\n";
    let d = pro(src, dl());
    let list = first(&d);
    assert_eq!(sp(&d, list, src), "Term\n: def");
    let item = fc(&d, list);
    assert!(d.span(list).start <= d.span(item).start);
    assert!(d.span(list).end >= d.span(item).end);
}

#[test]
fn span_multi_term_definition_list() {
    let src = "A\n: one\n\nB\n: two\n\nafter\n";
    let d = pro(src, dl());
    assert_eq!(sp(&d, first(&d), src), "A\n: one\n\nB\n: two");
}

#[test]
fn definition_list_renders() {
    assert_eq!(render_html("Term\n: def\n", dl()), "<dl>\n<dt>Term</dt>\n<dd>\ndef</dd>\n</dl>\n");
}

#[test]
fn definition_lists_off_lazy_paragraph() {
    let d = pro("Term\n: def\n", ParseOptions { definition_lists: false, ..opts() });
    let p = first(&d);
    assert_eq!(tag(&d, p), Tag::Para);
    assert!(no_next(&d, p));
}

fn fns() -> ParseOptions {
    ParseOptions { footnotes: true, ..opts() }
}

#[test]
fn footnote_definition_collected_not_emitted() {
    let d = pro("para\n\n[^a]: the note\n", fns());
    let p = first(&d);
    assert_eq!(tag(&d, p), Tag::Para);
    assert!(no_next(&d, p));
    let f = d.labels.footnote(b"a").unwrap();
    assert_eq!(*k(&d, f), Kind::Footnote { label: b"a".to_vec() });
    assert_eq!(tag(&d, fc(&d, f)), Tag::Para);
}

#[test]
fn footnote_definition_label_normalized() {
    let d = pro("[^ A  B ]: note\n", fns());
    assert!(d.labels.footnote(b"a b").is_some());
}

#[test]
fn footnote_continuation_line_joins_body() {
    let d = pro("[^a]: first line\n      second line\n", fns());
    let f = d.labels.footnote(b"a").unwrap();
    let body = fc(&d, f);
    assert_eq!(tag(&d, body), Tag::Para);
    assert!(no_next(&d, body));
    let s1 = fc(&d, body);
    assert_eq!(s(&d, s1), "first line");
    let brk = ns(&d, s1);
    assert_eq!(*k(&d, brk), Kind::SoftBreak);
    let s2 = ns(&d, brk);
    assert_eq!(s(&d, s2), "second line");
    assert!(no_next(&d, s2));
}

#[test]
fn footnote_definitions_back_to_back() {
    let d = pro("[^a]: first\n[^b]: second\n", fns());
    let a = d.labels.footnote(b"a").unwrap();
    let b = d.labels.footnote(b"b").unwrap();
    assert_eq!(s(&d, fc(&d, fc(&d, a))), "first");
    assert_eq!(s(&d, fc(&d, fc(&d, b))), "second");
    assert!(no_child(&d, d.ast.root));
}

#[test]
fn footnotes_off_is_link_reference_definition() {
    let d = pro("[^a]: /url\n", ParseOptions { footnotes: false, ..opts() });
    assert!(d.labels.footnotes.is_empty());
    assert!(d.labels.references.contains_key(&b"^a"[..]));
}

fn fm() -> ParseOptions {
    ParseOptions { frontmatter: true, ..opts() }
}

#[test]
fn frontmatter_yaml_block() {
    let d = pro("---\ntitle: Hi\n---\n# Heading\n", fm());
    let f = first(&d);
    assert_eq!(meta(&d, f), ("yaml", "title: Hi\n"));
    assert_eq!(tag(&d, ns(&d, f)), Tag::Heading);
    let html = String::from_utf8(html::serialize_alloc(&d.ast, None).unwrap()).unwrap();
    assert_eq!(html, "<script type=\"application/yaml\">\ntitle: Hi\n</script>\n<h1>Heading</h1>\n");
}

#[test]
fn frontmatter_toml_block() {
    let d = pro("+++\ntitle = \"Hi\"\n+++\nbody\n", fm());
    assert_eq!(meta(&d, first(&d)), ("toml", "title = \"Hi\"\n"));
}

#[test]
fn frontmatter_language_tag_as_written() {
    let d = pro("---fig\ntitle = Twig\n---\n# Twig\n", fm());
    assert_eq!(meta(&d, first(&d)), ("fig", "title = Twig\n"));
    // BEGIN serializer-tests
    let md = crate::serializer::serialize_ast(&d.ast);
    assert!(md.starts_with(b"---fig\ntitle = Twig\n---\n"));
    // END serializer-tests
    let html = html::serialize_alloc(&d.ast, None).unwrap();
    assert!(html.starts_with(b"<script type=\"application/fig\">\n"));
}

#[test]
fn frontmatter_arbitrary_config_language() {
    let d = pro("---edn\n{:title \"Hi\"}\n---\nbody\n", fm());
    assert_eq!(meta(&d, first(&d)).0, "edn");
    let html = html::serialize_alloc(&d.ast, None).unwrap();
    assert!(html.starts_with(b"<script type=\"application/edn\">\n"));
}

#[test]
fn frontmatter_html_printer_refuses_script_close() {
    let d = pro("---figl\nx = \"</script><img src=x onerror=alert(1)>\"\n---\n# Body\n", fm());
    assert!(html::serialize_alloc(&d.ast, None).is_err());
    // BEGIN serializer-tests
    let md = crate::serializer::serialize_ast(&d.ast);
    assert!(inline::index_of(&md, 0, b"</script>").is_some());
    // END serializer-tests
}

#[test]
fn frontmatter_script_guard_case_insensitive() {
    let d = pro("---figl\nx = \"a </SCRIPT b\"\n---\n", fm());
    assert!(html::serialize_alloc(&d.ast, None).is_err());
}

#[test]
fn frontmatter_lone_script_open_renders() {
    let d = pro("---figl\nx = \"see <script src=x>\"\n---\n", fm());
    let html = html::serialize_alloc(&d.ast, None).unwrap();
    assert!(html.starts_with(b"<script type=\"application/figl\">\n"));
}

#[test]
fn endmatter_is_last_child() {
    let d = pro("# Body\n\ntext\n\n---toml\nisbn = \"1-2-3\"\n---\n", fm());
    let l = last(&d);
    assert_eq!(meta(&d, l), ("toml", "isbn = \"1-2-3\"\n"));
    assert_eq!(tag(&d, first(&d)), Tag::Heading);
}

#[test]
fn front_and_end_matter_coexist() {
    let d = pro("---figl\ntitle = Twig\n---\n\n# Body\n\n---toml\nisbn = \"x\"\n---\n", fm());
    let f = first(&d);
    assert_eq!(meta(&d, f).0, "figl");
    let l = last(&d);
    assert_eq!(meta(&d, l).0, "toml");
    assert_ne!(f, l);
}

// BEGIN serializer-tests
#[test]
fn endmatter_round_trips_through_serializer() {
    let d = pro("# Body\n\n---toml\nisbn = \"x\"\n---\n", fm());
    let md = crate::serializer::serialize_ast(&d.ast);
    assert!(inline::index_of(&md, 0, b"---toml\nisbn = \"x\"\n---\n").is_some());
}
// END serializer-tests

#[test]
fn endmatter_untagged_is_not_endmatter() {
    let d = pro("text\n\n---\nk = v\n---\n", fm());
    assert_ne!(tag(&d, last(&d)), Tag::Metadata);
}

#[test]
fn endmatter_without_blank_separator_is_not_endmatter() {
    let d = pro("text\n---toml\nk = v\n---\n", fm());
    assert_ne!(tag(&d, last(&d)), Tag::Metadata);
}

#[test]
fn frontmatter_four_dashes_is_thematic_break() {
    let d = pro("----\nfoo\n", fm());
    assert_eq!(tag(&d, first(&d)), Tag::ThematicBreak);
}

#[test]
fn frontmatter_unterminated_falls_back() {
    let d = pro("---\ntitle: Hi\n", fm());
    assert_eq!(tag(&d, first(&d)), Tag::ThematicBreak);
}

#[test]
fn frontmatter_off_thematic_break() {
    let d = pro("---\nfoo\n", ParseOptions { frontmatter: false, ..opts() });
    let f = first(&d);
    assert_eq!(tag(&d, f), Tag::ThematicBreak);
    assert_eq!(tag(&d, ns(&d, f)), Tag::Para);
}

#[test]
fn container_directive_renders_named_element() {
    assert_eq!(
        render_html(":::note{#n .box}\nHello *world*\n:::\n", directives_on()),
        "<note id=\"n\" class=\"box\">\n<p>Hello <em>world</em></p>\n</note>\n"
    );
}

#[test]
fn container_directive_ast() {
    let d = pro(":::warning\ncontent\n:::\n", directives_on());
    let dir = first(&d);
    let Kind::Container(c) = k(&d, dir) else { panic!() };
    assert_eq!(c.form, Some(crate::ast::Form::BlockFenced));
    assert_eq!(c.name, b"warning");
    assert_eq!(tag(&d, fc(&d, dir)), Tag::Para);
}

#[test]
fn container_directive_nested_list() {
    let d = pro(":::box\n- a\n- b\n:::\n", directives_on());
    assert_eq!(tag(&d, fc(&d, first(&d))), Tag::BulletList);
}

#[test]
fn nested_container_directives() {
    assert_eq!(
        render_html("::::outer\n:::inner\nhi\n:::\n::::\n", directives_on()),
        "<outer>\n<inner>\n<p>hi</p>\n</inner>\n</outer>\n"
    );
}

#[test]
fn leaf_directive_label_is_inline() {
    assert_eq!(render_html("::youtube[A caption]{#v}\n", directives_on()), "<youtube id=\"v\">A caption</youtube>\n");
}

#[test]
fn leaf_directive_no_label() {
    let d = pro("::hr\n", directives_on());
    let dir = first(&d);
    let Kind::Container(c) = k(&d, dir) else { panic!() };
    assert_eq!(c.form, Some(crate::ast::Form::BlockLeaf));
    assert!(no_child(&d, dir));
}

#[test]
fn leaf_directive_label_holds_directive() {
    assert_eq!(
        render_html("::vis[a :vis[b]{.x} c]{.y}\n", directives_on()),
        "<vis class=\"y\">a <vis class=\"x\">b</vis> c</vis>\n"
    );
}

#[test]
fn container_directive_nested_bracket_label_dropped() {
    assert_eq!(
        render_html(":::box[see [docs](/d)]{.k}\nhi\n:::\n", directives_on()),
        "<box class=\"k\">\n<p>hi</p>\n</box>\n"
    );
}

#[test]
fn container_directive_interrupts_paragraph() {
    let d = pro("text\n:::box\nin\n:::\n", directives_on());
    let p = first(&d);
    assert_eq!(tag(&d, p), Tag::Para);
    assert_eq!(tag(&d, ns(&d, p)), Tag::Container);
}

#[test]
fn unterminated_container_directive_stays_open() {
    assert_eq!(render_html(":::box\nhi\n", directives_on()), "<box>\n<p>hi</p>\n</box>\n");
}

#[test]
fn directives_off_colon_fences_are_paragraphs() {
    let d = pr(":::note\nhi\n:::\n");
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::Container));
}

#[test]
fn container_directive_inside_block_quote() {
    assert_eq!(
        render_html("> :::box\n> hi\n> :::\n", directives_on()),
        "<blockquote>\n<box>\n<p>hi</p>\n</box>\n</blockquote>\n"
    );
}

#[test]
fn text_directive_renders_inline() {
    assert_eq!(
        render_html("See :abbr[HTML]{title=\"HyperText\"} here.\n", directives_on()),
        "<p>See <abbr title=\"HyperText\">HTML</abbr> here.</p>\n"
    );
}

#[test]
fn span_fenced_code_covers_closing_fence() {
    let src = "```zig\nconst x = 1;\n```\n";
    let d = pr(src);
    assert_eq!(sp(&d, first(&d), src), "```zig\nconst x = 1;\n```");
}

#[test]
fn span_unterminated_fenced_code() {
    let src = "```zig\nconst x = 1;\n";
    let d = pr(src);
    assert_eq!(sp(&d, first(&d), src), "```zig\nconst x = 1;");
}

#[test]
fn span_list_covers_all_items() {
    let src = "- a\n- b\n- c\n";
    let d = pr(src);
    assert_eq!(sp(&d, first(&d), src), "- a\n- b\n- c");
}

#[test]
fn span_multi_line_list_item() {
    let src = "- first\n  continued\n- second\n";
    let d = pr(src);
    assert_eq!(sp(&d, fc(&d, first(&d)), src), "- first\n  continued");
}

#[test]
fn span_block_quote_all_lines() {
    let src = "> line one\n> line two\n";
    let d = pr(src);
    assert_eq!(sp(&d, first(&d), src), "> line one\n> line two");
}

#[test]
fn span_block_quote_trailing_marker_lines() {
    let src = "> a\n>\n> \n";
    let d = pr(src);
    let bq = first(&d);
    assert_eq!(sp(&d, bq, src), "> a\n>\n> ");
    assert_eq!(csp(&d, bq, src), "> a");
}

#[test]
fn span_quote_marker_lines_stop_at_blank() {
    let src = "> a\n> \n\nafter\n";
    let d = pr(src);
    assert_eq!(sp(&d, first(&d), src), "> a\n> ");
}

#[test]
fn span_nested_quotes_cover_marker_lines() {
    let src = "> > a\n> >\n> > \n";
    let d = pr(src);
    let outer = first(&d);
    assert_eq!(sp(&d, outer, src), "> > a\n> >\n> > ");
    let inner = fc(&d, outer);
    assert_eq!(tag(&d, inner), Tag::BlockQuote);
    assert_eq!(sp(&d, inner, src), "> > a\n> >\n> > ");
}

#[test]
fn span_lazy_continuation_does_not_extend_quote() {
    let src = "> a\nb\n";
    let d = pr(src);
    assert_eq!(sp(&d, first(&d), src), "> a\nb");
}

#[test]
fn span_list_item_not_extended_by_blanks() {
    let src = "- item\n\n[link]: /url\n";
    let d = pr(src);
    assert_eq!(sp(&d, fc(&d, first(&d)), src), "- item");
}

#[test]
fn html_elements_div_pair_is_container() {
    let src = "<div class=\"center\" data-k=\"v\">\n\nhello *there*\n\n- one\n\n</div>\n\nafter\n";
    let d = pro(src, html_on());
    let div = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    let Kind::Container(c) = k(&d, div) else { panic!() };
    assert_eq!(c.name, b"div");
    assert_eq!(c.form, Some(crate::ast::Form::BlockFenced));
    assert_eq!(d.container_origin(div), Some(ContainerOrigin::Element));
    assert_eq!(attr(&d, div, "class"), "center");
    assert_eq!(attr(&d, div, "data-k"), "v");
    let f = fc(&d, div);
    assert_eq!(tag(&d, f), Tag::Para);
    let second = ns(&d, f);
    assert_eq!(tag(&d, second), Tag::BulletList);
    assert!(no_next(&d, second));
    assert_eq!(tag(&d, ns(&d, div)), Tag::Para);
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::RawBlock));
    assert_eq!(sp(&d, div, src), "<div class=\"center\" data-k=\"v\">\n\nhello *there*\n\n- one\n\n</div>");
}

#[test]
fn html_elements_serializer_wrap_reads_back() {
    let d = pro("<div class=\"c\">\n\nhello\n\n</div>\n", html_on());
    let div = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    let p = fc(&d, div);
    assert_eq!(tag(&d, p), Tag::Para);
    assert!(no_next(&d, p));
    assert!(no_next(&d, div));
}

#[test]
fn html_elements_divs_nest() {
    let d = pro("<div class=\"a\">\n\n<div class=\"b\">\n\nx\n\n</div>\n\ny\n\n</div>\n", html_on());
    let outer = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert_eq!(attr(&d, outer, "class"), "a");
    let inner = fc(&d, outer);
    assert_eq!(attr(&d, inner, "class"), "b");
    let y = ns(&d, inner);
    assert_eq!(tag(&d, y), Tag::Para);
    assert!(no_next(&d, y));
}

#[test]
fn html_elements_div_inside_quote() {
    let d = pro("> <div class=\"c\">\n>\n> hello\n>\n> </div>\n", html_on());
    let quote = find_first_kind(&d.ast, d.ast.root, Tag::BlockQuote).unwrap();
    let div = fc(&d, quote);
    assert_eq!(tag(&d, div), Tag::Container);
    assert_eq!(attr(&d, div, "class"), "c");
    assert_eq!(tag(&d, fc(&d, div)), Tag::Para);
    assert!(no_next(&d, div));
}

#[test]
fn html_elements_div_with_content_next_line_is_raw_block() {
    let d = pro("<div class=\"c\">\nhello\n</div>\n", html_on());
    let containers = d.ast.nodes.iter().filter(|n| n.kind.tag() == Tag::Container).count();
    let paras = d.ast.nodes.iter().filter(|n| n.kind.tag() == Tag::Para).count();
    assert_eq!(containers, 1);
    assert_eq!(paras, 0);
}

#[test]
fn html_elements_opener_without_closer_opens_nothing() {
    let d = pro("<div class=\"c\">\n\nhello\n\nmore\n", html_on());
    let div = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert!(no_child(&d, div));
    assert!(!no_next(&d, div));
}

#[test]
fn html_elements_closer_with_line_after_is_not_bare() {
    let d = pro("<div>\n\nhello\n\n</div>\ntail\n", html_on());
    let div = find_first_kind(&d.ast, d.ast.root, Tag::Container).unwrap();
    assert!(no_child(&d, div));
}

#[test]
fn html_elements_off_div_bytes_are_two_raw_blocks() {
    let d = pr("<div class=\"c\">\n\nhello\n\n</div>\n");
    assert!(d.ast.nodes.iter().all(|n| n.kind.tag() != Tag::Container));
    assert_eq!(d.ast.nodes.iter().filter(|n| n.kind.tag() == Tag::RawBlock).count(), 2);
}

#[test]
fn html_elements_self_closing_or_non_div_is_not_a_fence() {
    for src in ["<div/>\n\nhello\n\n</div>\n", "<aside>\n\nhello\n\n</aside>\n"] {
        let d = pro(src, html_on());
        for n in &d.ast.nodes {
            if n.kind.tag() == Tag::Container {
                assert!(n.first_child.is_none(), "{src}");
            }
        }
    }
}
