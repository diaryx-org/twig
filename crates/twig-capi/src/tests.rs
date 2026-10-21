//! Tests over the extern fns, called as a C host calls them: raw pointers in,
//! statuses and borrowed buffers out. Ports of the `test` blocks in
//! `src/c_abi.zig` (the C header test, `bindings/c/test/header_test.c`, runs
//! against the staticlib separately).

use std::ffi::{c_char, c_int, c_void, CStr};
use std::ptr::{null, null_mut};

use crate::*;

fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } }
}

fn kind_of(p: *const c_char) -> &'static str {
    unsafe { CStr::from_ptr(p) }.to_str().unwrap()
}

fn parse(src: &str, format: c_int, flags: u32) -> *mut TwigDocument {
    let mut doc = null_mut();
    assert_eq!(unsafe { twig_parse_ext(src.as_ptr(), src.len(), format, flags, &mut doc) }, TWIG_STATUS_OK);
    doc
}

/// An editor and its teardown.
struct Ed(*mut TwigEditor);

impl Ed {
    fn new(src: &str, format: c_int) -> Ed {
        Ed::ext(src, format, 0)
    }

    fn ext(src: &str, format: c_int, flags: u32) -> Ed {
        let mut ed = null_mut();
        assert_eq!(unsafe { twig_editor_create_ext(src.as_ptr(), src.len(), format, flags, &mut ed) }, TWIG_STATUS_OK);
        Ed(ed)
    }

    fn source(&self) -> String {
        let (mut p, mut n) = (null(), 0);
        assert_eq!(unsafe { twig_editor_source(self.0, &mut p, &mut n) }, TWIG_STATUS_OK);
        String::from_utf8(bytes(p, n).to_vec()).unwrap()
    }
}

impl Drop for Ed {
    fn drop(&mut self) {
        unsafe { twig_editor_destroy(self.0) };
    }
}

fn loc(s: &str) -> (*const u8, usize) {
    (s.as_ptr(), s.len())
}

#[test]
fn version_surface() {
    assert_eq!(twig_abi_version(), 6);
    let s = unsafe { CStr::from_ptr(twig_version_string()) }.to_str().unwrap();
    let v = twig_version();
    assert_eq!(s, format!("{}.{}.{}", v >> 16, (v >> 8) & 0xff, v & 0xff));
}

#[test]
fn parse_render_serialize_and_ast_json() {
    let doc = parse("# hi\n", TWIG_FORMAT_MARKDOWN, 0);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_render_html(doc, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"<h1>hi</h1>\n");
    assert_eq!(unsafe { twig_document_serialize(doc, TWIG_FORMAT_MARKDOWN, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"# hi\n");
    assert_eq!(unsafe { twig_document_serialize(doc, TWIG_FORMAT_DJOT, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"# hi\n");
    // Converting INTO XML has no serializer.
    assert_eq!(unsafe { twig_document_serialize(doc, TWIG_FORMAT_XML, &mut p, &mut n) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    assert_eq!(unsafe { twig_document_ast_json(doc, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert!(bytes(p, n).starts_with(b"{"));
    unsafe { twig_document_destroy(doc) };
}

#[test]
fn parse_refuses_unknown_codes_and_bad_arguments() {
    let src = "x";
    let mut doc = null_mut();
    assert_eq!(unsafe { twig_parse(src.as_ptr(), 1, 99, &mut doc) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    assert!(doc.is_null());
    // A runtime code no registration holds is just as unknown.
    let code = TWIG_FORMAT_RUNTIME_BASE + twig::runtime::CAPACITY as c_int - 1;
    assert_eq!(unsafe { twig_parse(src.as_ptr(), 1, code, &mut doc) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    let (mut name, mut len) = (null(), 0);
    assert_eq!(unsafe { twig_format_name(code, &mut name, &mut len) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    assert_eq!(unsafe { twig_parse(null(), 3, TWIG_FORMAT_DJOT, &mut doc) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_parse(src.as_ptr(), 1, TWIG_FORMAT_DJOT, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    // NULL with a zero length is the empty document.
    assert_eq!(unsafe { twig_parse(null(), 0, TWIG_FORMAT_DJOT, &mut doc) }, TWIG_STATUS_OK);
    unsafe { twig_document_destroy(doc) };
    // Strict XML can reject its input.
    let bad = "<a>";
    assert_eq!(unsafe { twig_parse(bad.as_ptr(), bad.len(), TWIG_FORMAT_XML, &mut doc) }, TWIG_STATUS_PARSE_ERROR);
}

#[test]
fn query_reports_kind_and_spans_and_rejects_a_bad_selector() {
    let doc = parse("# a\n\n## b\n", TWIG_FORMAT_MARKDOWN, 0);
    let (mut m, mut n) = (null(), 0);
    let sel = "heading[level=2]";
    assert_eq!(unsafe { twig_document_query(doc, sel.as_ptr(), sel.len(), &mut m, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(n, 1);
    let hit = unsafe { *m };
    assert_eq!(kind_of(hit.kind), "heading");
    assert_eq!((hit.span.start, hit.span.end), (5, 9));
    assert_eq!(hit.has_content_span, 1);
    let bad = "heading[";
    assert_eq!(
        unsafe { twig_document_query(doc, bad.as_ptr(), bad.len(), &mut m, &mut n) },
        TWIG_STATUS_INVALID_ARGUMENT
    );
    // The accessors agree with the match.
    let mut span = TwigSpan::default();
    assert_eq!(unsafe { twig_document_node_span(doc, hit.node_id, &mut span) }, TWIG_STATUS_OK);
    assert_eq!(span, hit.span);
    assert_eq!(unsafe { twig_document_node_span(doc, 9999, &mut span) }, TWIG_STATUS_INVALID_ARGUMENT);
    unsafe { twig_document_destroy(doc) };
}

#[test]
fn flat_nodes_link_up_and_carry_names_and_attributes() {
    let doc = parse("<p><img src=\"a.png\" alt></p>", TWIG_FORMAT_HTML, 0);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_nodes(doc, &mut p, &mut n) }, TWIG_STATUS_OK);
    let nodes = unsafe { std::slice::from_raw_parts(p, n) };
    for (i, node) in nodes.iter().enumerate() {
        assert_eq!(node.id as usize, i);
        let mut c = node.first_child;
        while c != TWIG_NO_NODE {
            assert_eq!(nodes[c as usize].parent, node.id);
            c = nodes[c as usize].next_sibling;
        }
    }
    let img = nodes.iter().find(|n| kind_of(n.kind) == "image").expect("an image");
    assert_eq!(bytes(img.destination_ptr, img.destination_len), b"a.png");
    let doc_node = &nodes[0];
    assert_eq!(doc_node.alignment, TWIG_ALIGN_NONE);
    assert_eq!(doc_node.head, TWIG_HEAD_NONE);
    assert_eq!(doc_node.checked, TWIG_TASK_CHECKED_NONE);
    assert_eq!(doc_node.directive_form, TWIG_DIRECTIVE_NONE);
    unsafe { twig_document_destroy(doc) };

    let doc = parse("<video controls src=\"v.mp4\"></video>", TWIG_FORMAT_HTML, 0);
    assert_eq!(unsafe { twig_document_nodes(doc, &mut p, &mut n) }, TWIG_STATUS_OK);
    let nodes = unsafe { std::slice::from_raw_parts(p, n) };
    let video = nodes.iter().find(|n| bytes(n.name_ptr, n.name_len) == b"video").expect("a video");
    assert_eq!(kind_of(video.kind), "container");
    assert_eq!(video.container_origin, TWIG_CONTAINER_ORIGIN_ELEMENT);
    let attrs = unsafe { std::slice::from_raw_parts(video.attrs_ptr, video.attrs_len) };
    assert_eq!(attrs.len(), 2);
    assert_eq!(bytes(attrs[0].key, attrs[0].key_len), b"controls");
    assert!(attrs[0].value.is_null(), "a bare attribute has a NULL value");
    assert_eq!(bytes(attrs[1].value, attrs[1].value_len), b"v.mp4");
    // A subtree is self-contained, with local ids and absolute spans.
    let (mut sp, mut sn) = (null(), 0);
    assert_eq!(unsafe { twig_document_subtree(doc, video.id, &mut sp, &mut sn) }, TWIG_STATUS_OK);
    let sub = unsafe { std::slice::from_raw_parts(sp, sn) };
    assert_eq!(sub[0].id, 0);
    assert_eq!(sub[0].parent, TWIG_NO_NODE);
    assert_eq!(sub[0].next_sibling, TWIG_NO_NODE);
    assert_eq!(sub[0].span, video.span);
    assert_eq!(sub[0].attrs_len, 2);
    unsafe { twig_document_destroy(doc) };
}

#[test]
fn hit_testing_and_children() {
    let doc = parse("a\n\nb *c*\n", TWIG_FORMAT_DJOT, 0);
    let (mut m, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_children(doc, TWIG_NO_NODE, &mut m, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(n, 2);
    assert_eq!(unsafe { twig_document_children(doc, 1 << 30, &mut m, &mut n) }, TWIG_STATUS_INVALID_ARGUMENT);
    let mut hit = unsafe { std::mem::zeroed::<TwigQueryMatch>() };
    assert_eq!(unsafe { twig_document_node_at(doc, 6, &mut hit) }, TWIG_STATUS_OK);
    assert_eq!(kind_of(hit.kind), "str");
    assert_eq!(unsafe { twig_document_nodes_at(doc, 6, &mut m, &mut n) }, TWIG_STATUS_OK);
    let chain = unsafe { std::slice::from_raw_parts(m, n) };
    assert_eq!(kind_of(chain[0].kind), "doc");
    assert_eq!(chain.last().unwrap().node_id, hit.node_id);
    assert_eq!(unsafe { twig_document_node_at(doc, 100, &mut hit) }, TWIG_STATUS_INVALID_ARGUMENT);
    // The caret walk is its own buffer: reading it leaves the other intact.
    let (mut cm, mut cn) = (null(), 0);
    assert_eq!(unsafe { twig_document_nodes_at_caret(doc, 1, &mut cm, &mut cn) }, TWIG_STATUS_OK);
    assert_eq!(kind_of(unsafe { (*cm.add(cn - 1)).kind }), "str");
    assert_eq!(chain.last().unwrap().node_id, hit.node_id);
    unsafe { twig_document_destroy(doc) };
}

#[test]
fn borrowed_view_cannot_render_and_destroy_is_a_no_op() {
    let ed = Ed::new("# a\n", TWIG_FORMAT_MARKDOWN);
    let mut view = null_mut();
    assert_eq!(unsafe { twig_editor_document(ed.0, &mut view) }, TWIG_STATUS_OK);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_render_html(view, &mut p, &mut n) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    assert_eq!(
        unsafe { twig_document_serialize(view, TWIG_FORMAT_MARKDOWN, &mut p, &mut n) },
        TWIG_STATUS_UNSUPPORTED_FORMAT
    );
    unsafe { twig_document_destroy(view) };
    // Still alive, and following the editor.
    let (l, ln) = loc("0");
    let t = "## b";
    assert_eq!(unsafe { twig_editor_replace(ed.0, l, ln, t.as_ptr(), t.len()) }, TWIG_STATUS_OK);
    let (mut m, mut mn) = (null(), 0);
    assert_eq!(unsafe { twig_document_children(view, TWIG_NO_NODE, &mut m, &mut mn) }, TWIG_STATUS_OK);
    assert_eq!(unsafe { (*m).span.end }, 4);
}

#[test]
fn locator_ops_and_their_statuses() {
    let ed = Ed::new("<r><a/><a/></r>", TWIG_FORMAT_XML);
    let t = "x";
    let call = |l: &str| unsafe { twig_editor_replace(ed.0, l.as_ptr(), l.len(), t.as_ptr(), t.len()) };
    assert_eq!(call("0.9"), TWIG_STATUS_NOT_FOUND);
    assert_eq!(call("element"), TWIG_STATUS_AMBIGUOUS);
    assert_eq!(call("element("), TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(ed.source(), "<r><a/><a/></r>");

    let ed = Ed::new("<a>ok</a>", TWIG_FORMAT_XML);
    let (l, n) = loc("0");
    let broken = "<b>";
    assert_eq!(
        unsafe { twig_editor_replace_content(ed.0, l, n, broken.as_ptr(), broken.len()) },
        TWIG_STATUS_EDIT_CONFLICT
    );
    assert_eq!(ed.source(), "<a>ok</a>");
    let (l, n) = loc("0.0");
    assert_eq!(unsafe { twig_editor_replace_content(ed.0, l, n, t.as_ptr(), 1) }, TWIG_STATUS_NOT_EDITABLE);

    let ed = Ed::new("<r><a/></r>", TWIG_FORMAT_XML);
    let (l, n) = loc("0");
    let c = "<b/>";
    assert_eq!(unsafe { twig_editor_insert_child(ed.0, l, n, 99, c.as_ptr(), c.len()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "<r><a/><b/></r>");
    let (l, n) = loc("0.0");
    assert_eq!(unsafe { twig_editor_delete(ed.0, l, n) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "<r><b/></r>");
    let (l, n) = loc("0.0");
    let before = "<z/>";
    assert_eq!(unsafe { twig_editor_insert_before(ed.0, l, n, before.as_ptr(), before.len()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "<r><z/><b/></r>");
    // The locator ops report their change too, and undo/redo walk them.
    let mut ch = TwigChange::default();
    assert_eq!(unsafe { twig_editor_last_change(ed.0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!((ch.old_span.start, ch.old_span.end, ch.new_span.end), (3, 3, 7));
    assert_eq!(unsafe { twig_editor_undo(ed.0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "<r><b/></r>");
    assert_eq!(unsafe { twig_editor_redo(ed.0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "<r><z/><b/></r>");
    assert_eq!(unsafe { twig_editor_redo(ed.0, &mut ch) }, TWIG_STATUS_NOT_FOUND);
}

#[test]
fn filter_prunes_and_rejects_a_bad_selector() {
    let ed = Ed::new("<r><a/><b/><a/></r>", TWIG_FORMAT_XML);
    let drop = "element[name=a]";
    assert_eq!(unsafe { twig_editor_filter(ed.0, drop.as_ptr(), drop.len(), null(), 0, 0) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "<r><b/></r>");
    let bad = "element(";
    assert_eq!(
        unsafe { twig_editor_filter(ed.0, bad.as_ptr(), bad.len(), null(), 0, 0) },
        TWIG_STATUS_INVALID_ARGUMENT
    );
}

#[test]
fn edit_range_history_revision_dirty_and_caret() {
    let ed = Ed::new("ab\n", TWIG_FORMAT_MARKDOWN);
    let mut ch = TwigChange::default();
    assert_eq!(unsafe { twig_editor_last_change(ed.0, &mut ch) }, TWIG_STATUS_NOT_FOUND);
    assert_eq!(unsafe { twig_editor_revision(ed.0) }, 0);
    let mut dirty = TwigSpan::default();
    assert_eq!(unsafe { twig_editor_dirty_range(ed.0, &mut dirty) }, TWIG_STATUS_NOT_FOUND);

    let caret = b"c1";
    assert_eq!(unsafe { twig_editor_set_caret_blob(ed.0, caret.as_ptr(), caret.len()) }, TWIG_STATUS_OK);
    let x = "x";
    assert_eq!(unsafe { twig_editor_edit_range(ed.0, 1, 1, x.as_ptr(), 1, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "axb\n");
    assert_eq!((ch.old_span.start, ch.old_span.end, ch.new_span.start, ch.new_span.end), (1, 1, 1, 2));
    assert_eq!(unsafe { twig_editor_revision(ed.0) }, 1);
    assert_eq!(unsafe { twig_editor_dirty_range(ed.0, &mut dirty) }, TWIG_STATUS_OK);
    assert_eq!((dirty.start, dirty.end), (1, 2));
    assert_eq!(unsafe { twig_editor_clear_dirty(ed.0) }, TWIG_STATUS_OK);
    assert_eq!(unsafe { twig_editor_dirty_range(ed.0, &mut dirty) }, TWIG_STATUS_NOT_FOUND);
    // After an edit the current caret is empty until set.
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_editor_caret_blob(ed.0, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert!(p.is_null() && n == 0);

    assert_eq!(unsafe { twig_editor_edit_range(ed.0, 2, 2, x.as_ptr(), 1, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(unsafe { twig_editor_coalesce_last(ed.0) }, TWIG_STATUS_OK);
    assert_eq!(unsafe { twig_editor_undo(ed.0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "ab\n");
    assert_eq!(unsafe { twig_editor_caret_blob(ed.0, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"c1");
    assert_eq!(unsafe { twig_editor_undo(ed.0, &mut ch) }, TWIG_STATUS_NOT_FOUND);
    assert_eq!(unsafe { twig_editor_revision(ed.0) }, 3);

    assert_eq!(unsafe { twig_editor_edit_range(ed.0, 2, 1, x.as_ptr(), 1, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_editor_edit_range(ed.0, 0, 99, x.as_ptr(), 1, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_editor_revision(null_mut()) }, 0);
}

#[test]
fn toolbar_wire_codes_reach_their_gestures() {
    let ed = Ed::new("one two\n", TWIG_FORMAT_MARKDOWN);
    let mut ch = TwigChange::default();
    assert_eq!(unsafe { twig_editor_toggle_inline(ed.0, 0, 3, 0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "**one** two\n");
    assert_eq!((ch.old_span.start, ch.old_span.end, ch.new_span.end), (0, 3, 7));
    assert_eq!(unsafe { twig_editor_toggle_inline(ed.0, 2, 5, 0, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "one two\n");
    assert_eq!(unsafe { twig_editor_wrap_range(ed.0, 0, 3, 1, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "*one* two\n");
    assert_eq!(unsafe { twig_editor_wrap_range(ed.0, 0, 3, 99, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_editor_set_block(ed.0, 0, 1, 2, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "## *one* two\n");
    assert_eq!(unsafe { twig_editor_set_block(ed.0, 0, 1, 9, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_editor_set_block(ed.0, 0, 5, 1, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_editor_set_block(ed.0, 0, 0, 0, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "*one* two\n");
    assert_eq!(unsafe { twig_editor_toggle_block_container(ed.0, 0, 1, 0, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "> *one* two\n");
    assert_eq!(unsafe { twig_editor_toggle_block_container(ed.0, 0, 1, 3, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    let lit = "*";
    assert_eq!(unsafe { twig_editor_insert_literal(ed.0, 11, lit.as_ptr(), 1, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "> *one* two\\*\n");
    assert_eq!(unsafe { twig_editor_insert_literal(ed.0, 999, lit.as_ptr(), 1, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
}

#[test]
fn link_image_footnote_table_and_code() {
    let ed = Ed::new("see here\n", TWIG_FORMAT_MARKDOWN);
    let dest = "a b";
    assert_eq!(unsafe { twig_editor_insert_link(ed.0, 4, 8, dest.as_ptr(), dest.len(), null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "see [here](<a b>)\n");
    let nl = "a\nb";
    assert_eq!(
        unsafe { twig_editor_insert_link(ed.0, 0, 3, nl.as_ptr(), nl.len(), null_mut()) },
        TWIG_STATUS_INVALID_ARGUMENT
    );
    assert_eq!(unsafe { twig_editor_insert_link(ed.0, 0, 3, null(), 2, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);

    let ed = Ed::new("x\n", TWIG_FORMAT_DJOT);
    let img = "p.png";
    assert_eq!(unsafe { twig_editor_insert_image(ed.0, 0, 1, img.as_ptr(), img.len(), null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "![x](p.png)\n");

    let ed = Ed::new("| a |\n|---|\n| b |\n", TWIG_FORMAT_MARKDOWN);
    assert_eq!(unsafe { twig_editor_table_edit(ed.0, 2, 2, 1, null_mut()) }, TWIG_STATUS_OK);
    assert!(ed.source().lines().next().unwrap().matches('|').count() == 3);
    assert_eq!(unsafe { twig_editor_table_edit(ed.0, 2, 4, 9, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    assert_eq!(unsafe { twig_editor_table_edit(ed.0, 2, 42, 0, null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    let ed = Ed::new("text\n", TWIG_FORMAT_MARKDOWN);
    assert_eq!(unsafe { twig_editor_table_edit(ed.0, 1, 0, 1, null_mut()) }, TWIG_STATUS_NOT_FOUND);

    let ed = Ed::new("- a\n", TWIG_FORMAT_MARKDOWN);
    let lang = "rust";
    assert_eq!(unsafe { twig_editor_toggle_code_block(ed.0, 2, 3, lang.as_ptr(), 4, 1, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "- ```rust\n  a\n  ```\n");
    let ed = Ed::new("```rust\na\n```\n", TWIG_FORMAT_MARKDOWN);
    assert_eq!(unsafe { twig_editor_set_code_language(ed.0, 8, null(), 0, 0, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "```\na\n```\n");
    assert_eq!(
        unsafe { twig_editor_set_code_language(ed.0, 4, null(), 3, 1, null_mut()) },
        TWIG_STATUS_INVALID_ARGUMENT
    );

    let ed = Ed::new("a\n", TWIG_FORMAT_DJOT);
    let label = "n";
    assert_eq!(unsafe { twig_editor_insert_footnote(ed.0, 1, label.as_ptr(), 1, null_mut()) }, TWIG_STATUS_OK);
    assert!(ed.source().starts_with("a[^n]\n"));
    let mut ch = TwigChange::default();
    assert_eq!(unsafe { twig_editor_undo(ed.0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "a\n");
}

#[test]
fn task_items_and_renumbering_report_their_no_ops() {
    let ed = Ed::new("1. a\n1. b\n", TWIG_FORMAT_MARKDOWN);
    let mut ch = TwigChange { old_span: TwigSpan { start: 77, end: 77 }, new_span: TwigSpan { start: 77, end: 77 } };
    assert_eq!(unsafe { twig_editor_renumber_ordered_lists(ed.0, 0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "1. a\n2. b\n");
    // A second press is the documented no-op: OK, and the prior change.
    let prior = ch;
    assert_eq!(unsafe { twig_editor_renumber_ordered_lists(ed.0, 0, &mut ch) }, TWIG_STATUS_OK);
    assert_eq!(ch, prior);

    let ed = Ed::new("- a\n", TWIG_FORMAT_MARKDOWN);
    assert_eq!(unsafe { twig_editor_set_task_checked(ed.0, 2, 1, null_mut()) }, TWIG_STATUS_NOT_EDITABLE);
    assert_eq!(unsafe { twig_editor_toggle_task_item(ed.0, 2, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(unsafe { twig_editor_toggle_task_checked(ed.0, 6, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "- [x] a\n");
    let ed = Ed::new("text\n", TWIG_FORMAT_MARKDOWN);
    assert_eq!(unsafe { twig_editor_toggle_task_item(ed.0, 1, null_mut()) }, TWIG_STATUS_NOT_FOUND);
}

#[test]
fn mark_colour_needs_its_flags() {
    let ed = Ed::new("ab\n", TWIG_FORMAT_MARKDOWN);
    let red = "red";
    assert_eq!(
        unsafe { twig_editor_set_mark_color(ed.0, 1, red.as_ptr(), 3, 1, null_mut()) },
        TWIG_STATUS_UNSUPPORTED_FORMAT
    );
    let ed = Ed::ext("ab\n", TWIG_FORMAT_MARKDOWN, TWIG_MD_HIGHLIGHT_COLORS);
    assert_eq!(unsafe { twig_editor_toggle_inline(ed.0, 0, 2, 3, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "==ab==\n");
    assert_eq!(unsafe { twig_editor_set_mark_color(ed.0, 2, red.as_ptr(), 3, 1, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "==🔴 ab==\n");
    let pink = "pink";
    assert_eq!(
        unsafe { twig_editor_set_mark_color(ed.0, 2, pink.as_ptr(), 4, 1, null_mut()) },
        TWIG_STATUS_INVALID_ARGUMENT
    );
    assert_eq!(unsafe { twig_editor_set_mark_color(ed.0, 2, null(), 0, 0, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), "==ab==\n");
    // And the parse path reads the colour as an attribute.
    let doc = parse("==🔴 x==\n", TWIG_FORMAT_MARKDOWN, TWIG_MD_HIGHLIGHT_COLORS);
    let sel = "mark[data-color=red]";
    let (mut m, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_query(doc, sel.as_ptr(), sel.len(), &mut m, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(n, 1);
    unsafe { twig_document_destroy(doc) };
}

#[test]
fn a_null_editor_is_invalid_argument_on_every_gesture() {
    let e = null_mut();
    let x = "x";
    unsafe {
        assert_eq!(twig_editor_wrap_range(e, 0, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_toggle_inline(e, 0, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_set_block(e, 0, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_toggle_block_container(e, 0, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_insert_link(e, 0, 0, x.as_ptr(), 1, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_split_block(e, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_join_blocks(e, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_move_block(e, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_table_edit(e, 0, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_set_node_attrs(e, 0, null(), 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_toggle_line_block(e, 0, 0, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_source(e, &mut null(), &mut 0), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_document(e, &mut null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_nodes(e, &mut null(), &mut 0), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_editor_undo(e, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        twig_editor_destroy(e);
        twig_document_destroy(null_mut());
        twig_builder_destroy(null_mut());
        twig_server_destroy(null_mut());
    }
}

#[test]
fn verse_reports_its_indent_as_level() {
    let src = "a\\\n\u{2003}b\n";
    let ed = Ed::ext(src, TWIG_FORMAT_MARKDOWN, 0);
    assert_eq!(unsafe { twig_editor_toggle_line_block(ed.0, 0, 1, null_mut()) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    let ed = Ed::ext(src, TWIG_FORMAT_MARKDOWN, TWIG_MD_HTML_ELEMENTS);
    assert_eq!(unsafe { twig_editor_toggle_line_block(ed.0, 0, 1, null_mut()) }, TWIG_STATUS_OK);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_editor_nodes(ed.0, &mut p, &mut n) }, TWIG_STATUS_OK);
    let nodes = unsafe { std::slice::from_raw_parts(p, n) };
    let levels: Vec<u32> = nodes.iter().filter(|n| kind_of(n.kind) == "line").map(|n| n.level).collect();
    assert_eq!(levels, vec![0, 1]);
}

#[test]
fn capability_queries() {
    let mut yes = -1;
    unsafe {
        assert_eq!(twig_format_supports(TWIG_FORMAT_DJOT, 1, 3, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 1);
        assert_eq!(twig_format_supports(TWIG_FORMAT_MARKDOWN, 1, 3, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 0);
        assert_eq!(twig_format_supports_ext(TWIG_FORMAT_MARKDOWN, TWIG_MD_HIGHLIGHT, 1, 3, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 1);
        assert_eq!(twig_format_supports(TWIG_FORMAT_MARKDOWN, 24, 0, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 0);
        assert_eq!(twig_format_supports_ext(TWIG_FORMAT_MARKDOWN, TWIG_MD_HIGHLIGHT_COLORS, 24, 0, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 1);
        assert_eq!(twig_format_supports(TWIG_FORMAT_MARKDOWN, 10, 3, &mut yes), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_format_supports(TWIG_FORMAT_MARKDOWN, 35, 0, &mut yes), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_format_supports(0, 0, 0, &mut yes), TWIG_STATUS_UNSUPPORTED_FORMAT);
        assert_eq!(twig_format_is_authorable(TWIG_FORMAT_SVG, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 0);
        assert_eq!(twig_format_is_authorable(TWIG_FORMAT_ASCIIDOC, &mut yes), TWIG_STATUS_OK);
        assert_eq!(yes, 1);
    }
}

#[test]
fn format_names_dialects_and_feature_bits() {
    let mut code = 0;
    let name = "md";
    assert_eq!(unsafe { twig_format_by_name(name.as_ptr(), 2, &mut code) }, TWIG_STATUS_OK);
    assert_eq!(code, TWIG_FORMAT_MARKDOWN);
    let nope = "nope";
    assert_eq!(unsafe { twig_format_by_name(nope.as_ptr(), 4, &mut code) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_format_name(TWIG_FORMAT_SVG, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"svg");
    let mut parent = 0;
    assert_eq!(unsafe { twig_format_dialect_of(TWIG_FORMAT_SVG, &mut parent) }, TWIG_STATUS_OK);
    assert_eq!(parent, TWIG_FORMAT_XML);
    assert_eq!(unsafe { twig_format_dialect_of(TWIG_FORMAT_GFM, &mut parent) }, TWIG_STATUS_OK);
    assert_eq!(parent, TWIG_FORMAT_MARKDOWN);
    assert_eq!(unsafe { twig_format_dialect_of(TWIG_FORMAT_DJOT, &mut parent) }, TWIG_STATUS_NOT_FOUND);
    let mut bit = 0;
    for (name, want) in [
        ("directives", TWIG_MD_DIRECTIVES),
        ("math", TWIG_MD_MATH),
        ("html_elements", TWIG_MD_HTML_ELEMENTS),
        ("highlight", TWIG_MD_HIGHLIGHT),
        ("highlight_colors", TWIG_MD_HIGHLIGHT_COLORS),
    ] {
        assert_eq!(unsafe { twig_format_feature_bit(TWIG_FORMAT_COMMONMARK, name.as_ptr(), name.len(), &mut bit) }, TWIG_STATUS_OK);
        assert_eq!(bit, want);
    }
    let math = "math";
    assert_eq!(
        unsafe { twig_format_feature_bit(TWIG_FORMAT_DJOT, math.as_ptr(), 4, &mut bit) },
        TWIG_STATUS_UNSUPPORTED_FORMAT
    );
}

#[test]
fn builder_builds_renders_serializes_and_queries() {
    let mut b = null_mut();
    assert_eq!(unsafe { twig_builder_create(&mut b) }, TWIG_STATUS_OK);
    let id = |f: &dyn Fn(*mut u32) -> TwigStatus| {
        let mut out = TWIG_NO_NODE;
        assert_eq!(f(&mut out), TWIG_STATUS_OK);
        out
    };
    let hello = "hello";
    let s = id(&|o| unsafe { twig_builder_add_text(b, 25, hello.as_ptr(), hello.len(), o) });
    let strong = id(&|o| unsafe { twig_builder_add(b, 39, o) });
    let h = id(&|o| unsafe { twig_builder_add_heading(b, 2, o) });
    let doc = id(&|o| unsafe { twig_builder_add(b, 0, o) });
    let item_text = "x";
    let it = id(&|o| unsafe { twig_builder_add_text(b, 25, item_text.as_ptr(), 1, o) });
    let para = id(&|o| unsafe { twig_builder_add(b, 1, o) });
    let item = id(&|o| unsafe { twig_builder_add(b, 15, o) });
    let list = id(&|o| unsafe { twig_builder_add_bullet_list(b, 2, 1, o) });
    unsafe {
        assert_eq!(twig_builder_set_children(b, strong, &s, 1), TWIG_STATUS_OK);
        assert_eq!(twig_builder_set_children(b, h, &strong, 1), TWIG_STATUS_OK);
        assert_eq!(twig_builder_set_children(b, para, &it, 1), TWIG_STATUS_OK);
        assert_eq!(twig_builder_set_children(b, item, &para, 1), TWIG_STATUS_OK);
        assert_eq!(twig_builder_set_children(b, list, &item, 1), TWIG_STATUS_OK);
        let kids = [h, list];
        assert_eq!(twig_builder_set_children(b, doc, kids.as_ptr(), 2), TWIG_STATUS_OK);
        let attrs = [TwigKeyVal { key: b"id".as_ptr(), key_len: 2, value: b"t".as_ptr(), value_len: 1 }];
        assert_eq!(twig_builder_set_attrs(b, h, attrs.as_ptr(), 1), TWIG_STATUS_OK);

        let (mut p, mut n) = (null(), 0);
        assert_eq!(twig_builder_render_html(b, doc, &mut p, &mut n), TWIG_STATUS_OK);
        assert_eq!(
            std::str::from_utf8(bytes(p, n)).unwrap(),
            "<h2 id=\"t\"><strong>hello</strong></h2>\n<ul>\n<li>\nx\n</li>\n</ul>\n"
        );
        assert_eq!(twig_builder_serialize(b, doc, TWIG_FORMAT_MARKDOWN, &mut p, &mut n), TWIG_STATUS_OK);
        assert!(bytes(p, n).ends_with(b"* x\n"), "the bullet style is spelling: {:?}", std::str::from_utf8(bytes(p, n)));
        assert_eq!(twig_builder_serialize(b, doc, TWIG_FORMAT_XML, &mut p, &mut n), TWIG_STATUS_UNSUPPORTED_FORMAT);
        assert_eq!(twig_builder_serialize(b, doc, 77, &mut p, &mut n), TWIG_STATUS_UNSUPPORTED_FORMAT);
        assert_eq!(twig_builder_ast_json(b, h, &mut p, &mut n), TWIG_STATUS_OK);
        assert!(n > 0);
        let (mut m, mut mn) = (null(), 0);
        let sel = "strong";
        assert_eq!(twig_builder_query(b, doc, sel.as_ptr(), sel.len(), &mut m, &mut mn), TWIG_STATUS_OK);
        assert_eq!(mn, 1);
        assert_eq!((*m).node_id, strong);

        // Bad codes and ids.
        let mut out = 0;
        assert_eq!(twig_builder_add(b, 25, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add(b, 999, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add_text(b, 1, hello.as_ptr(), 5, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add_cell_spanning(b, 0, 0, 0, 1, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add_cell(b, 0, 9, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add_bullet_list(b, 9, 0, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add_ordered_list(b, 0, 9, 0, 0, 0, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add_smart_punctuation(b, 7, null(), 0, &mut out), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_add(b, 1, null_mut()), TWIG_STATUS_INVALID_ARGUMENT);
        let bad = [9999u32];
        assert_eq!(twig_builder_set_children(b, doc, bad.as_ptr(), 1), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_set_children(b, 9999, null(), 0), TWIG_STATUS_INVALID_ARGUMENT);
        assert_eq!(twig_builder_render_html(b, 9999, &mut p, &mut n), TWIG_STATUS_INVALID_ARGUMENT);

        // A spanning cell reads back through a parse-free document? No: the
        // builder's cell extent shows in its JSON.
        assert_eq!(twig_builder_add_cell_spanning(b, 1, 3, 2, 3, &mut out), TWIG_STATUS_OK);
        assert_eq!(twig_builder_ast_json(b, out, &mut p, &mut n), TWIG_STATUS_OK);
        twig_builder_destroy(b);
    }
}

#[test]
fn diagnostics_are_per_target() {
    let doc = parse("a^b^ c\n", TWIG_FORMAT_DJOT, 0);
    let (mut w, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_diagnostics(doc, TWIG_FORMAT_GFM, &mut w, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(n, 1);
    let warning = unsafe { *w };
    assert_eq!(warning.fidelity, TWIG_FIDELITY_DEGRADED);
    assert_eq!(bytes(warning.path_ptr, warning.path_len), b"0/1");
    assert_eq!(kind_of(warning.kind), "superscript");
    assert_eq!(unsafe { twig_document_diagnostics(doc, TWIG_FORMAT_DJOT, &mut w, &mut n) }, TWIG_STATUS_OK);
    assert!(w.is_null() && n == 0);
    assert_eq!(unsafe { twig_document_diagnostics(doc, TWIG_FORMAT_SVG, &mut w, &mut n) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    unsafe { twig_document_destroy(doc) };
}

// ── runtime languages ───────────────────────────────────────────────────────

/// "lines": every line a paragraph of one `str`, printed back one per line.
fn lines_table(src: &[u8]) -> Vec<u8> {
    let mut nodes = vec![format!("{{\"kind\":\"doc\",\"span\":[0,{}]}}", src.len())];
    let mut start = 0;
    for line in src.split_inclusive(|&b| b == b'\n') {
        let text = line.strip_suffix(b"\n").unwrap_or(line);
        if !text.is_empty() {
            let end = start + text.len();
            let para = nodes.len();
            nodes.push(format!("{{\"kind\":\"para\",\"parent\":0,\"span\":[{start},{end}]}}"));
            nodes.push(format!(
                "{{\"kind\":\"str\",\"parent\":{para},\"span\":[{start},{end}],\"text\":\"{}\"}}",
                String::from_utf8_lossy(text)
            ));
        }
        start += line.len();
    }
    format!("{{\"nodes\":[{}]}}", nodes.join(",")).into_bytes()
}

/// Print a table back: every `"text":"…"` on a line of its own.
fn lines_print(table: &[u8]) -> Vec<u8> {
    let s = String::from_utf8_lossy(table);
    let mut out = String::new();
    for part in s.split("\"text\":\"").skip(1) {
        out.push_str(&part[..part.find('"').unwrap()]);
        out.push('\n');
    }
    out.into_bytes()
}

fn give(bytes: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let boxed = bytes.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
    }
}

unsafe extern "C" fn lines_free(_: *mut c_void, ptr: *mut u8, len: usize) {
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
}

unsafe extern "C" fn lines_parse(_: *mut c_void, call: *const TwigLanguageCall, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    let c = unsafe { &*call };
    give(lines_table(bytes(c.input, c.input_len)), out, out_len);
    0
}

unsafe extern "C" fn lines_print_fn(_: *mut c_void, call: *const TwigLanguageCall, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    let c = unsafe { &*call };
    give(lines_print(bytes(c.input, c.input_len)), out, out_len);
    0
}

unsafe extern "C" fn lines_parse_v1(
    _: *mut c_void,
    _row: *const u8,
    _row_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    give(lines_table(bytes(input, input_len)), out, out_len);
    0
}

unsafe extern "C" fn refusing_parse(_: *mut c_void, _: *const TwigLanguageCall, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    give(b"no thanks".to_vec(), out, out_len);
    1
}

fn table(description: &'static str) -> TwigLanguageVTable {
    TwigLanguageVTable {
        version: TWIG_LANGUAGE_VTABLE_VERSION,
        user_data: null_mut(),
        description: description.as_ptr(),
        description_len: description.len(),
        parse: Some(lines_parse),
        print: Some(lines_print_fn),
        render: None,
        free: Some(lines_free),
    }
}

fn err_text(err: &[c_char]) -> String {
    unsafe { CStr::from_ptr(err.as_ptr()) }.to_string_lossy().into_owned()
}

#[test]
fn a_registered_language_is_a_format_every_entry_point_takes() {
    let vt = table(r#"{"name":"capi-lines","extensions":["capilines"],"caps":{"write":true},"samples":["a\nb\n"]}"#);
    let mut code = 0;
    let mut err = [0 as c_char; 256];
    let status = unsafe { twig_language_register(&vt, &mut code, err.as_mut_ptr(), err.len()) };
    assert_eq!(status, TWIG_STATUS_OK, "{}", err_text(&err));
    assert!(code >= TWIG_FORMAT_RUNTIME_BASE);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_format_name(code, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"capi-lines");

    let doc = parse("one\ntwo\n", code, 0);
    assert_eq!(unsafe { twig_document_render_html(doc, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"<p>one</p>\n<p>two</p>\n");
    assert_eq!(unsafe { twig_document_serialize(doc, code, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"one\ntwo\n");
    unsafe { twig_document_destroy(doc) };

    // Converting a compiled format into it prints through the host.
    let md = parse("x\n\ny\n", TWIG_FORMAT_MARKDOWN, 0);
    assert_eq!(unsafe { twig_document_serialize(md, code, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"x\ny\n");
    unsafe { twig_document_destroy(md) };

    let ed = Ed::new("a\n", code);
    assert_eq!(ed.source(), "a\n");
}

#[test]
fn a_version_1_table_reads_and_is_refused_what_it_cannot_carry() {
    let d = r#"{"name":"capi-v1","samples":["a\n"]}"#;
    let v1 = TwigLanguageVTableV1 {
        version: 1,
        user_data: null_mut(),
        description: d.as_ptr(),
        description_len: d.len(),
        parse: Some(lines_parse_v1),
        print: None,
        free: Some(lines_free),
    };
    let mut code = 0;
    let mut err = [0 as c_char; 256];
    let vt = &v1 as *const TwigLanguageVTableV1 as *const TwigLanguageVTable;
    assert_eq!(unsafe { twig_language_register(vt, &mut code, err.as_mut_ptr(), err.len()) }, TWIG_STATUS_OK);
    let doc = parse("q\n", code, 0);
    unsafe { twig_document_destroy(doc) };

    let d2 = r#"{"name":"capi-v1-feat","features":[{"name":"f"}],"samples":["a\n"]}"#;
    let v1b = TwigLanguageVTableV1 { description: d2.as_ptr(), description_len: d2.len(), ..v1 };
    let vt = &v1b as *const TwigLanguageVTableV1 as *const TwigLanguageVTable;
    assert_eq!(
        unsafe { twig_language_register(vt, &mut code, err.as_mut_ptr(), err.len()) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
    assert!(err_text(&err).contains("version 1"));
}

#[test]
fn a_refusal_says_why_and_registers_nothing() {
    let vt = table(r#"{"name":"markdown","samples":["x"]}"#);
    let mut code = 0;
    let mut err = [0 as c_char; 256];
    assert_eq!(
        unsafe { twig_language_register(&vt, &mut code, err.as_mut_ptr(), err.len()) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
    assert!(err_text(&err).contains("already a format's"), "{}", err_text(&err));
    let bad_version = TwigLanguageVTable { version: 99, ..table(r#"{"name":"capi-x","samples":["x"]}"#) };
    assert_eq!(
        unsafe { twig_language_register(&bad_version, &mut code, err.as_mut_ptr(), 1) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
    assert_eq!(err[0], 0, "a one-byte buffer still gets its terminator");
    let no_free = TwigLanguageVTable { free: None, ..table(r#"{"name":"capi-y","samples":["x"]}"#) };
    assert_eq!(unsafe { twig_language_register(&no_free, &mut code, null_mut(), 0) }, TWIG_STATUS_INVALID_LANGUAGE);
    let refusing = TwigLanguageVTable { parse: Some(refusing_parse), ..table(r#"{"name":"capi-z","samples":["x"]}"#) };
    assert_eq!(
        unsafe { twig_language_register(&refusing, &mut code, err.as_mut_ptr(), err.len()) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
    let name = "capi-z";
    assert_eq!(unsafe { twig_format_by_name(name.as_ptr(), name.len(), &mut code) }, TWIG_STATUS_UNSUPPORTED_FORMAT);
    assert_eq!(unsafe { twig_language_register(null(), &mut code, null_mut(), 0) }, TWIG_STATUS_INVALID_ARGUMENT);
}

#[test]
fn the_server_answers_the_wire() {
    let vt = table(r#"{"name":"capi-served","caps":{"write":true},"samples":["a\n"]}"#);
    let mut server = null_mut();
    assert_eq!(unsafe { twig_server_create(&vt, &mut server, null_mut(), 0) }, TWIG_STATUS_OK);
    let (mut p, mut n) = (null(), 0);
    let describe = r#"{"op":"describe"}"#;
    assert_eq!(unsafe { twig_server_handle(server, describe.as_ptr(), describe.len(), &mut p, &mut n) }, TWIG_STATUS_OK);
    assert!(bytes(p, n).starts_with(br#"{"ok":true,"description":{"#));
    let junk = "not json";
    assert_eq!(unsafe { twig_server_handle(server, junk.as_ptr(), junk.len(), &mut p, &mut n) }, TWIG_STATUS_OK);
    assert!(bytes(p, n).starts_with(br#"{"ok":false,"message":"#));
    unsafe { twig_server_destroy(server) };

    let bad = table("not a description");
    let mut err = [0 as c_char; 128];
    assert_eq!(
        unsafe { twig_server_create(&bad, &mut server, err.as_mut_ptr(), err.len()) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
    assert!(server.is_null());
    assert!(!err_text(&err).is_empty());
}

/// The transport's other end: a server over the "lines" table, in-process.
unsafe extern "C" fn wired_exchange(
    user_data: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let server = user_data as *mut TwigServer;
    let (mut p, mut n) = (null(), 0);
    if unsafe { twig_server_handle(server, request, request_len, &mut p, &mut n) } != TWIG_STATUS_OK {
        return 1;
    }
    give(bytes(p, n).to_vec(), out, out_len);
    0
}

#[test]
fn a_language_registers_over_a_transport() {
    let vt = table(r#"{"name":"capi-wired","caps":{"write":true},"samples":["a\nb\n"]}"#);
    let mut server = null_mut();
    assert_eq!(unsafe { twig_server_create(&vt, &mut server, null_mut(), 0) }, TWIG_STATUS_OK);
    // The server lives for the process, as a transport's user_data must.
    let transport = TwigTransport {
        version: TWIG_TRANSPORT_VERSION,
        user_data: server as *mut c_void,
        exchange: Some(wired_exchange),
        free: Some(lines_free),
    };
    let mut code = 0;
    let mut err = [0 as c_char; 256];
    let status = unsafe { twig_language_register_transport(&transport, &mut code, err.as_mut_ptr(), err.len()) };
    assert_eq!(status, TWIG_STATUS_OK, "{}", err_text(&err));
    let doc = parse("one\ntwo\n", code, 0);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_serialize(doc, code, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"one\ntwo\n");
    unsafe { twig_document_destroy(doc) };

    let bad = TwigTransport { version: 7, ..transport };
    assert_eq!(
        unsafe { twig_language_register_transport(&bad, &mut code, err.as_mut_ptr(), err.len()) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
    let no_exchange = TwigTransport { exchange: None, ..transport };
    assert_eq!(
        unsafe { twig_language_register_transport(&no_exchange, &mut code, null_mut(), 0) },
        TWIG_STATUS_INVALID_LANGUAGE
    );
}

#[test]
fn metadata_is_located_read_as_json_and_replaced() {
    let src = "---\ntitle: Hi # kept\ntags: [a, b]\n---\n# Body\n";
    let doc = parse(src, TWIG_FORMAT_MARKDOWN, 0);
    let (mut span, mut body) = (TwigSpan::default(), TwigSpan::default());
    let (mut lp, mut ln) = (null(), 0);
    assert_eq!(unsafe { twig_document_metadata(doc, TWIG_META_FRONT, &mut span, &mut body, &mut lp, &mut ln) }, TWIG_STATUS_OK);
    assert_eq!((span.start, span.end), (0, 37));
    assert_eq!(&src[body.start..body.end], "title: Hi # kept\ntags: [a, b]\n");
    assert_eq!(bytes(lp, ln), b"yaml");
    assert_eq!(unsafe { twig_document_metadata(doc, TWIG_META_END, null_mut(), null_mut(), null_mut(), null_mut()) }, TWIG_STATUS_NOT_FOUND);
    assert_eq!(unsafe { twig_document_metadata(doc, 7, null_mut(), null_mut(), null_mut(), null_mut()) }, TWIG_STATUS_INVALID_ARGUMENT);
    let (mut p, mut n) = (null(), 0);
    assert_eq!(unsafe { twig_document_metadata_json(doc, TWIG_META_FRONT, &mut p, &mut n) }, TWIG_STATUS_OK);
    assert_eq!(bytes(p, n), b"{\"title\":\"Hi\",\"tags\":[\"a\",\"b\"]}\n");
    unsafe { twig_document_destroy(doc) };

    let ed = Ed::new(src, TWIG_FORMAT_MARKDOWN);
    let body = "title: Hello # kept\n";
    let mut change = TwigChange::default();
    assert_eq!(
        unsafe { twig_editor_set_metadata(ed.0, TWIG_META_FRONT, null(), 0, body.as_ptr(), body.len(), &mut change) },
        TWIG_STATUS_OK
    );
    assert_eq!(ed.source(), "---\ntitle: Hello # kept\n---\n# Body\n");
    // The change is the body's, not the document's.
    assert_eq!(change.old_span.start, 12);
    // A body that is not YAML changes nothing.
    let bad = "a: [\n";
    assert_eq!(
        unsafe { twig_editor_set_metadata(ed.0, TWIG_META_FRONT, null(), 0, bad.as_ptr(), bad.len(), null_mut()) },
        TWIG_STATUS_PARSE_ERROR
    );
    assert_eq!(ed.source(), "---\ntitle: Hello # kept\n---\n# Body\n");
    assert_eq!(unsafe { twig_editor_undo(ed.0, null_mut()) }, TWIG_STATUS_OK);
    assert_eq!(ed.source(), src);
}

#[test]
fn set_metadata_writes_a_new_block_and_refuses_an_unsafe_island() {
    let ed = Ed::new("# Body\n", TWIG_FORMAT_MARKDOWN);
    let (lang, body) = ("toml", "title = \"Hi\"");
    assert_eq!(
        unsafe { twig_editor_set_metadata(ed.0, TWIG_META_FRONT, lang.as_ptr(), lang.len(), body.as_ptr(), body.len(), null_mut()) },
        TWIG_STATUS_OK
    );
    assert_eq!(ed.source(), "+++\ntitle = \"Hi\"\n+++\n# Body\n");
    assert_eq!(
        unsafe { twig_editor_set_metadata(ed.0, TWIG_META_END, null(), 0, body.as_ptr(), body.len(), null_mut()) },
        TWIG_STATUS_NOT_FOUND
    );

    let page = "<!doctype html>\n<html><head>\n<title>x</title>\n</head><body></body></html>\n";
    let ed = Ed::new(page, TWIG_FORMAT_HTML);
    let (lang, body) = ("json", "{\"a\": 1}\n");
    assert_eq!(
        unsafe { twig_editor_set_metadata(ed.0, TWIG_META_FRONT, lang.as_ptr(), lang.len(), body.as_ptr(), body.len(), null_mut()) },
        TWIG_STATUS_OK
    );
    assert!(ed.source().contains("<script type=\"application/json\">\n{\"a\": 1}\n</script>\n"), "{}", ed.source());
    let unsafe_body = "{\"a\": \"</script>\"}\n";
    assert_eq!(
        unsafe { twig_editor_set_metadata(ed.0, TWIG_META_FRONT, null(), 0, unsafe_body.as_ptr(), unsafe_body.len(), null_mut()) },
        TWIG_STATUS_UNSAFE_METADATA
    );
}

#[test]
fn alloc_and_free_round_trip() {
    assert!(twig_alloc(0).is_null());
    let p = twig_alloc(16);
    assert!(!p.is_null());
    unsafe {
        p.write_bytes(7, 16);
        twig_free(p, 16);
        twig_free(null_mut(), 0);
    }
}
