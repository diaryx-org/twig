//! Port of `src/ast/splicer.zig`'s tests. XML is the main vehicle: it has real
//! spans and `content_span`, and can fail to parse — which exercises the
//! rollback path. Markdown and djot cover the line-shaped formats.

use super::*;
use {twig_djot as djot, twig_markdown as markdown, twig_xml as xml};

fn parse_xml() -> ParseFn {
    Box::new(|s: &[u8]| xml::parse(s).map_err(|e| ParseError::new(e.name())))
}

fn parse_markdown() -> ParseFn {
    Box::new(|s: &[u8]| Ok(markdown::parse(s, markdown::ParseOptions::default())))
}

fn parse_djot() -> ParseFn {
    Box::new(|s: &[u8]| Ok(djot::parse(s)))
}

fn xml_ed(src: &str) -> Splicer {
    Splicer::new(src.as_bytes(), parse_xml()).unwrap()
}

fn md_ed(src: &str) -> Splicer {
    Splicer::new(src.as_bytes(), parse_markdown()).unwrap()
}

fn dj_ed(src: &str) -> Splicer {
    Splicer::new(src.as_bytes(), parse_djot()).unwrap()
}

fn text(ed: &Splicer) -> &str {
    std::str::from_utf8(ed.source_bytes()).unwrap()
}

fn mismatched() -> Error {
    Error::Parse(ParseError::new("MismatchedCloseTag"))
}

#[test]
fn replace_content_rewrites_an_element_interior_losslessly() {
    let mut ed = xml_ed("<a><b>hi</b></a>");
    ed.replace_content(&[0, 0], b"bye").unwrap();
    assert_eq!(text(&ed), "<a><b>bye</b></a>");
}

#[test]
fn insert_child_appends_and_inserts_by_index() {
    let mut ed = xml_ed("<r><a/><c/></r>");
    ed.insert_child(&[0], 1, b"<b/>").unwrap();
    assert_eq!(text(&ed), "<r><a/><b/><c/></r>");
    ed.insert_child(&[0], 99, b"<d/>").unwrap();
    assert_eq!(text(&ed), "<r><a/><b/><c/><d/></r>");
    ed.insert_child(&[0], 0, b"<z/>").unwrap();
    assert_eq!(text(&ed), "<r><z/><a/><b/><c/><d/></r>");
}

#[test]
fn insert_child_appends_a_block_child_onto_its_own_line() {
    let mut ed = md_ed("- a\n- b\n");
    ed.insert_child(&[0], 99, b"- c\n").unwrap();
    assert_eq!(text(&ed), "- a\n- b\n- c\n");
}

#[test]
fn insert_child_append_injects_a_separator_when_the_last_line_lacks_a_newline() {
    let mut ed = md_ed("- a\n- b");
    ed.insert_child(&[0], 99, b"- c\n").unwrap();
    assert_eq!(text(&ed), "- a\n- b\n- c\n");
}

#[test]
fn insert_before_insert_after_delete_node() {
    let mut ed = xml_ed("<r><a/><b/></r>");
    ed.insert_after(&[0, 0], b"<x/>").unwrap();
    assert_eq!(text(&ed), "<r><a/><x/><b/></r>");
    ed.delete_node(&[0, 0]).unwrap();
    assert_eq!(text(&ed), "<r><x/><b/></r>");
    ed.insert_before(&[0, 0], b"<y/>").unwrap();
    assert_eq!(text(&ed), "<r><y/><x/><b/></r>");
}

#[test]
fn move_node_reorders_siblings_in_one_splice_carrying_the_whitespace_ahead() {
    let mut ed = xml_ed("<g>\n  <a/>\n  <b/>\n  <c/>\n</g>");
    ed.move_node(&[0, 1], &[0, 5], Placement::After).unwrap();
    assert_eq!(text(&ed), "<g>\n  <b/>\n  <c/>\n  <a/>\n</g>");
    assert_eq!(ed.undo_stack.len(), 1);
    ed.move_node(&[0, 5], &[0, 1], Placement::Before).unwrap();
    assert_eq!(text(&ed), "<g>\n  <a/>\n  <b/>\n  <c/>\n</g>");
    ed.move_node(&[0, 1], &[0, 3], Placement::After).unwrap();
    assert_eq!(text(&ed), "<g>\n  <b/>\n  <a/>\n  <c/>\n</g>");
    ed.move_node(&[0, 3], &[0, 1], Placement::Before).unwrap();
    assert_eq!(text(&ed), "<g>\n  <a/>\n  <b/>\n  <c/>\n</g>");
    ed.undo().unwrap();
    assert_eq!(text(&ed), "<g>\n  <b/>\n  <a/>\n  <c/>\n</g>");
}

#[test]
fn move_node_with_no_whitespace_to_carry_and_across_containers() {
    let mut ed = xml_ed("<r><a/><b/><p><c/></p></r>");
    ed.move_node(&[0, 0], &[0, 1], Placement::After).unwrap();
    assert_eq!(text(&ed), "<r><b/><a/><p><c/></p></r>");
    ed.move_node(&[0, 1], &[0, 2, 0], Placement::Before).unwrap();
    assert_eq!(text(&ed), "<r><b/><p><a/><c/></p></r>");
    let mut t = xml_ed("<r>hi <a/><b/></r>");
    t.move_node(&[0, 1], &[0, 2], Placement::After).unwrap();
    assert_eq!(text(&t), "<r>hi <b/><a/></r>");
}

#[test]
fn move_node_carries_a_lightweight_formats_blank_line_separator_too() {
    let mut ed = md_ed("A\n\nB\n\nC\n");
    ed.move_node(&[1], &[2], Placement::After).unwrap();
    assert_eq!(text(&ed), "A\n\nC\n\nB\n");
    ed.move_node(&[2], &[0], Placement::Before).unwrap();
    assert_eq!(text(&ed), "B\n\nA\n\nC\n");
}

#[test]
fn move_node_refuses_a_node_and_its_own_ancestor_or_itself() {
    let mut ed = xml_ed("<r><a><b/></a></r>");
    assert_eq!(ed.move_node(&[0, 0, 0], &[0, 0], Placement::After), Err(Error::OverlappingNodes));
    assert_eq!(ed.move_node(&[0, 0], &[0, 0, 0], Placement::Before), Err(Error::OverlappingNodes));
    assert_eq!(ed.move_node(&[0, 0], &[0, 0], Placement::After), Err(Error::OverlappingNodes));
    assert_eq!(text(&ed), "<r><a><b/></a></r>");
    assert_eq!(ed.undo_stack.len(), 0);
}

#[test]
fn delete_node_on_a_quote_takes_its_own_trailing_marker_lines_with_it() {
    let mut ed = md_ed("> a\n>\n> \n\nafter\n");
    ed.delete_node_smart(&[0]).unwrap();
    assert_eq!(text(&ed), "after\n");
}

#[test]
fn delete_node_smart_takes_the_blocks_own_attribute_line_with_it() {
    let mut ed = dj_ed("public\n\n{.vis}\nheld back\n\nmore public\n");
    ed.delete_node_smart(&[1]).unwrap();
    assert_eq!(text(&ed), "public\n\nmore public\n");
}

#[test]
fn delete_node_smart_leaves_an_unrelated_attribute_line_alone() {
    let mut ed = dj_ed("{.k}\nkept\n\ngoing\n");
    ed.delete_node_smart(&[1]).unwrap();
    assert_eq!(text(&ed), "{.k}\nkept\n");
}

#[test]
fn unwrap_node_drops_the_wrappers_attribute_line_keeps_the_interior() {
    let mut ed = dj_ed("{.vis}\n:::\ninside\n:::\n");
    ed.unwrap_node(&[0]).unwrap();
    assert_eq!(text(&ed), "inside\n\n");
}

#[test]
fn unwrap_node_keeps_a_containers_children_drops_the_wrapper() {
    let mut ed = xml_ed("<r><box><b/><c/></box></r>");
    ed.unwrap_node(&[0, 0]).unwrap();
    assert_eq!(text(&ed), "<r><b/><c/></r>");
}

#[test]
fn unwrap_node_on_an_empty_container_degrades_to_delete() {
    let mut ed = xml_ed("<r><box/></r>");
    ed.unwrap_node(&[0, 0]).unwrap();
    assert_eq!(text(&ed), "<r></r>");
}

#[test]
fn a_reparse_breaking_edit_rolls_back_and_leaves_the_document_untouched() {
    let mut ed = xml_ed("<a>ok</a>");
    assert_eq!(ed.replace_content(&[0], b"<b>"), Err(mismatched()));
    assert_eq!(text(&ed), "<a>ok</a>");
    ed.ast_view().id_by_path(&[0]).unwrap();
}

#[test]
fn last_change_records_the_byte_effect_of_the_last_successful_edit() {
    let mut ed = xml_ed("<a>hi</a>");
    assert_eq!(ed.last_change, None);
    ed.replace_content(&[0], b"bye").unwrap();
    let c = ed.last_change.unwrap();
    assert_eq!((c.old.start, c.old.end, c.new.start, c.new.end), (3, 5, 3, 6));
    assert_eq!(ed.replace_content(&[0], b"<b>"), Err(mismatched()));
    assert_eq!(ed.last_change.unwrap().new.end, 6);
}

#[test]
fn wrap_range_bolds_a_selection_toggle_inline_removes_it() {
    let mut ed = md_ed("a word b\n");
    ed.wrap_range(Span::new(2, 6), b"**", b"**").unwrap();
    assert_eq!(text(&ed), "a **word** b\n");
    ed.toggle_inline(Span::new(4, 8), &KindRef::Mark(crate::ast::InlineMark::Strong), b"**", b"**").unwrap();
    assert_eq!(text(&ed), "a word b\n");
}

#[test]
fn toggle_inline_wraps_when_the_range_isnt_already_marked() {
    let mut ed = md_ed("a word b\n");
    ed.toggle_inline(Span::new(2, 6), &KindRef::Mark(crate::ast::InlineMark::Emph), b"*", b"*").unwrap();
    assert_eq!(text(&ed), "a *word* b\n");
}

#[test]
fn toggle_inline_strips_a_verbatim_run_via_its_content_span() {
    let mut ed = md_ed("a `code` b\n");
    ed.toggle_inline(Span::new(2, 8), &KindRef::TextLeaf(crate::ast::TextLeafKind::Verbatim), b"`", b"`").unwrap();
    assert_eq!(text(&ed), "a code b\n");
}

#[test]
fn toggle_inline_strips_a_multi_backtick_verbatim() {
    let mut ed = md_ed("a ``x`` b\n");
    ed.toggle_inline(Span::new(2, 7), &KindRef::TextLeaf(crate::ast::TextLeafKind::Verbatim), b"`", b"`").unwrap();
    assert_eq!(text(&ed), "a x b\n");
}

#[test]
fn replace_content_on_a_leaf_yields_no_content_span() {
    let mut ed = xml_ed("<a>hi</a>");
    assert_eq!(ed.replace_content(&[0, 0], b"x"), Err(Error::NoContentSpan));
}

#[test]
fn replace_content_on_a_code_block_replaces_the_body_fences_intact() {
    let mut ed = md_ed("```\nold\n```\n");
    ed.replace_content(&[0], b"new").unwrap();
    assert_eq!(text(&ed), "```\nnew\n```\n");
}

#[test]
fn insert_child_on_a_code_block_is_rejected() {
    let mut ed = md_ed("```\ncode\n```\n");
    assert_eq!(ed.insert_child(&[0], 0, b"x"), Err(Error::NotAContainer));
}

#[test]
fn path_navigation_reports_out_of_bounds() {
    let ed = xml_ed("<a><b/></a>");
    assert!(ed.ast_view().id_by_path(&[0, 5]).is_err());
    assert!(ed.ast_view().id_by_path(&[0, 0, 0]).is_err());
}

// ── smart-delete (tidy_deletion_span) ─────────────────────────────────────────

fn expect_tidy(src: &str, start: usize, end: usize, want: &str) {
    let s = src.as_bytes();
    let del = tidy_deletion_span(s, Span::new(start, end));
    let mut got = s[..del.start].to_vec();
    got.extend_from_slice(&s[del.end..]);
    assert_eq!(String::from_utf8(got).unwrap(), want);
}

#[test]
fn tidy_deletion_span_cases() {
    expect_tidy("A\n\nB\n\nC\n", 3, 4, "A\n\nC\n");
    expect_tidy("A\n\nB\n\nC\n", 0, 1, "B\n\nC\n");
    expect_tidy("A\n\nB\n\nC\n", 6, 7, "A\n\nB\n");
    expect_tidy("# A\n# B\n# C\n", 4, 7, "# A\n# C\n");
    expect_tidy("top\n\n:::x\nbody\n:::\n\nbottom\n", 5, 18, "top\n\nbottom\n");
    expect_tidy("A\n", 0, 1, "");
    expect_tidy("a *b* c\n", 2, 5, "a  c\n");
    expect_tidy("<r>\n  <a/>\n  <b/>\n</r>\n", 6, 10, "<r>\n  <b/>\n</r>\n");
    expect_tidy("<r>\n  <a/> \t\n  <b/>\n</r>\n", 6, 10, "<r>\n  <b/>\n</r>\n");
    expect_tidy("<r>\n  <a/><b/>\n</r>\n", 6, 10, "<r>\n  <b/>\n</r>\n");
    expect_tidy("<r>\n  x <a/>\n</r>\n", 8, 12, "<r>\n  x \n</r>\n");
}

#[test]
fn delete_node_smart_takes_an_xml_elements_line_indentation_and_all() {
    let src = "<svg>\n  <!-- keep me -->\n  <rect/>\n  <g data-id=\"s2\"/>\n</svg>\n";
    let mut ed = xml_ed(src);
    ed.delete_node_smart(&[0, 3]).unwrap();
    assert_eq!(text(&ed), "<svg>\n  <!-- keep me -->\n  <g data-id=\"s2\"/>\n</svg>\n");
    ed.undo().unwrap();
    assert_eq!(text(&ed), src);
    ed.delete_node_smart(&[0, 5]).unwrap();
    assert_eq!(text(&ed), "<svg>\n  <!-- keep me -->\n  <rect/>\n</svg>\n");
}

// ── undo / redo ──────────────────────────────────────────────────────────────

#[test]
fn undo_restores_the_pre_edit_source_redo_reapplies_it() {
    let mut ed = md_ed("hello\n");
    ed.replace_at_span(Span::new(5, 5), b"!").unwrap();
    assert_eq!(text(&ed), "hello!\n");
    let undone = ed.undo().unwrap().unwrap();
    assert_eq!(text(&ed), "hello\n");
    assert_eq!(undone.new.end, 5);
    let redone = ed.redo().unwrap().unwrap();
    assert_eq!(text(&ed), "hello!\n");
    assert_eq!(redone.new.end, 6);
}

#[test]
fn undo_and_redo_are_no_ops_at_the_ends_of_history() {
    let mut ed = md_ed("x\n");
    assert_eq!(ed.undo().unwrap(), None);
    ed.replace_at_span(Span::new(1, 1), b"y").unwrap();
    ed.undo().unwrap();
    assert_eq!(ed.undo().unwrap(), None);
    ed.redo().unwrap();
    assert_eq!(ed.redo().unwrap(), None);
}

#[test]
fn coalesce_last_undo_folds_a_keystroke_run_into_one_undo_step() {
    let mut ed = md_ed("\n");
    ed.replace_at_span(Span::new(0, 0), b"a").unwrap();
    ed.replace_at_span(Span::new(1, 1), b"b").unwrap();
    ed.coalesce_last_undo();
    ed.replace_at_span(Span::new(2, 2), b"c").unwrap();
    ed.coalesce_last_undo();
    assert_eq!(text(&ed), "abc\n");
    ed.undo().unwrap();
    assert_eq!(text(&ed), "\n");
    assert_eq!(ed.undo().unwrap(), None);
}

#[test]
fn a_fresh_edit_invalidates_the_redo_stack() {
    let mut ed = md_ed("\n");
    ed.replace_at_span(Span::new(0, 0), b"a").unwrap();
    ed.undo().unwrap();
    ed.replace_at_span(Span::new(0, 0), b"b").unwrap();
    assert_eq!(ed.redo().unwrap(), None);
    assert_eq!(text(&ed), "b\n");
}

#[test]
fn revision_starts_at_0_and_bumps_once_per_successful_mutation() {
    let mut ed = md_ed("x\n");
    assert_eq!(ed.revision, 0);
    ed.replace_at_span(Span::new(1, 1), b"y").unwrap();
    assert_eq!(ed.revision, 1);
    let mut x = xml_ed("<a>ok</a>");
    assert_eq!(x.replace_content(&[0], b"<b>"), Err(mismatched()));
    assert_eq!(x.revision, 0);
    ed.undo().unwrap();
    assert_eq!(ed.revision, 2);
    ed.redo().unwrap();
    assert_eq!(ed.revision, 3);
    ed.undo().unwrap();
    let r = ed.revision;
    assert_eq!(ed.undo().unwrap(), None);
    assert_eq!(r, ed.revision);
}

#[test]
fn dirty_range_is_none_on_a_fresh_editor_and_after_clear_dirty() {
    let mut ed = md_ed("abc\n");
    assert_eq!(ed.dirty_range(), None);
    ed.replace_at_span(Span::new(1, 1), b"X").unwrap();
    assert!(ed.dirty_range().is_some());
    ed.clear_dirty();
    assert_eq!(ed.dirty_range(), None);
    let rev = ed.revision;
    ed.clear_dirty();
    assert_eq!(rev, ed.revision);
}

#[test]
fn a_single_edits_dirty_range_is_exactly_its_inserted_bytes() {
    let mut ed = md_ed("abcd\n");
    ed.replace_at_span(Span::new(2, 2), b"XY").unwrap();
    assert_eq!(ed.dirty_range(), Some(Span::new(2, 4)));
    assert_eq!(text(&ed), "abXYcd\n");
}

#[test]
fn dirty_range_accumulates_conservatively_across_disjoint_edits() {
    let mut ed = md_ed("abcdefgh\n");
    ed.replace_at_span(Span::new(6, 6), b"Z").unwrap();
    assert_eq!(ed.dirty_range(), Some(Span::new(6, 7)));
    ed.replace_at_span(Span::new(1, 1), b"Y").unwrap();
    assert_eq!(ed.dirty_range(), Some(Span::new(1, 8)));
}

#[test]
fn a_deletion_shifts_a_later_dirty_region_left() {
    let mut ed = md_ed("abcdefgh\n");
    ed.replace_at_span(Span::new(6, 6), b"Z").unwrap();
    ed.replace_at_span(Span::new(1, 3), b"").unwrap();
    assert_eq!(ed.dirty_range(), Some(Span::new(1, 5)));
    assert_eq!(text(&ed), "adefZgh\n");
    assert_eq!(ed.source_bytes()[4], b'Z');
}

#[test]
fn undo_and_redo_dirty_the_range_they_touch() {
    let mut ed = md_ed("abc\n");
    ed.replace_at_span(Span::new(3, 3), b"d").unwrap();
    ed.clear_dirty();
    ed.undo().unwrap();
    assert!(ed.dirty_range().is_some());
    ed.clear_dirty();
    ed.redo().unwrap();
    assert_eq!(ed.dirty_range(), Some(Span::new(3, 4)));
}

#[test]
fn a_failed_edit_leaves_the_dirty_range_untouched() {
    let mut x = xml_ed("<a>ok</a>");
    assert_eq!(x.replace_content(&[0], b"<b>"), Err(mismatched()));
    assert_eq!(x.dirty_range(), None);
}

#[test]
fn set_caret_caret_blob_round_trips_an_opaque_host_blob() {
    let mut ed = md_ed("x\n");
    assert_eq!(ed.caret_blob(), b"");
    ed.set_caret(b"caret@3");
    assert_eq!(ed.caret_blob(), b"caret@3");
    let mut buf = *b"zz";
    ed.set_caret(&buf);
    buf[0] = b'q';
    let _ = buf;
    assert_eq!(ed.caret_blob(), b"zz");
    ed.set_caret(b"");
    assert_eq!(ed.caret_blob(), b"");
}

#[test]
fn undo_restores_the_pre_edit_caret_redo_restores_the_post_edit_caret() {
    let mut ed = md_ed("hello\n");
    ed.set_caret(b"before");
    ed.replace_at_span(Span::new(5, 5), b"!").unwrap();
    assert_eq!(ed.caret_blob(), b"");
    ed.set_caret(b"after");
    ed.undo().unwrap();
    assert_eq!(text(&ed), "hello\n");
    assert_eq!(ed.caret_blob(), b"before");
    ed.redo().unwrap();
    assert_eq!(text(&ed), "hello!\n");
    assert_eq!(ed.caret_blob(), b"after");
}

#[test]
fn coalesced_run_keeps_the_caret_from_before_the_run_began() {
    let mut ed = md_ed("\n");
    ed.set_caret(b"c0");
    ed.replace_at_span(Span::new(0, 0), b"a").unwrap();
    ed.set_caret(b"c1");
    ed.replace_at_span(Span::new(1, 1), b"b").unwrap();
    ed.coalesce_last_undo();
    ed.set_caret(b"c2");
    ed.replace_at_span(Span::new(2, 2), b"c").unwrap();
    ed.coalesce_last_undo();
    ed.set_caret(b"c3");
    ed.undo().unwrap();
    assert_eq!(text(&ed), "\n");
    assert_eq!(ed.caret_blob(), b"c0");
    ed.redo().unwrap();
    assert_eq!(text(&ed), "abc\n");
    assert_eq!(ed.caret_blob(), b"c3");
}

#[test]
fn caret_blobs_are_evicted_with_their_step_past_max_undo() {
    let mut ed = md_ed("\n");
    for _ in 0..MAX_UNDO + 10 {
        ed.set_caret(b"caret-blob-payload");
        ed.replace_at_span(Span::new(0, 0), b"x").unwrap();
    }
    assert_eq!(ed.undo_stack.len(), MAX_UNDO);
}
