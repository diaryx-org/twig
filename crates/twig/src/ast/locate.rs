//! Hit-testing: byte offset -> node, plus the line scanning the block gestures
//! are built on. Port of `src/ast/locate.zig`.
//!
//! A caret speaks a byte offset; this is the missing fourth way to address a
//! node: `deepest_containing(doc, offset)` and the `ancestor_chain` down to it.
//! `Node` carries no parent link, so every walk here is top-down.

use crate::ast::{ContentModel, Kind, Level, NodeId, Tag, TextLeafKind};
use crate::document::Document;
use crate::span::Span;

/// A `Kind` tag without its payload.
pub type KindTag = Tag;

/// True if `offset` falls in node span `s` (half-open), treating a
/// whole-source end position as inside, and an unset `(0,0)` span as
/// containing nothing.
pub fn span_contains(s: Span, offset: usize, source_len: usize) -> bool {
    if s.start == 0 && s.end == 0 {
        return false;
    }
    if offset == source_len {
        return offset >= s.start && s.end >= source_len;
    }
    offset >= s.start && offset < s.end
}

/// The child of `id` whose span contains `offset` — the LAST such child.
pub fn child_containing(doc: &Document, id: NodeId, offset: usize) -> Option<NodeId> {
    let mut found = None;
    for child in doc.children(id) {
        if span_contains(doc.span(child.id), offset, doc.source.len()) {
            found = Some(child.id);
        }
    }
    found
}

/// The deepest node containing `offset`, descending from the root.
pub fn deepest_containing(doc: &Document, offset: usize) -> Option<NodeId> {
    let mut cur = doc.ast.root;
    if !span_contains(doc.span(cur), offset, doc.source.len()) {
        cur = child_containing(doc, cur, offset)?;
    }
    while let Some(child) = child_containing(doc, cur, offset) {
        cur = child;
    }
    Some(cur)
}

/// The chain of node ids from the root down to the deepest node containing
/// `offset`. Appends to `out`.
pub fn ancestor_chain(doc: &Document, offset: usize, out: &mut Vec<NodeId>) {
    let mut cur = doc.ast.root;
    out.push(cur);
    while let Some(child) = child_containing(doc, cur, offset) {
        cur = child;
        out.push(cur);
    }
}

// ── Caret hit-testing ──────────────────────────────────────────────────────

/// True if a CARET at `offset` sits in node span `s`: end-inclusive, and a
/// trailing line terminator is not part of the block — which makes djot (a
/// block ends after its newline) and Markdown (before it) agree.
pub fn caret_contains(src: &[u8], s: Span, offset: usize) -> bool {
    if s.start == 0 && s.end == 0 {
        return false;
    }
    if offset < s.start {
        return false;
    }
    let mut end = s.end.min(src.len());
    if end > s.start && src[end - 1] == b'\n' {
        end -= 1;
    }
    if end > s.start && src[end - 1] == b'\r' {
        end -= 1;
    }
    offset <= end
}

/// `child_containing` under `caret_contains` — the LAST matching child.
pub fn caret_child_containing(doc: &Document, id: NodeId, offset: usize) -> Option<NodeId> {
    let mut found = None;
    for child in doc.children(id) {
        if caret_contains(&doc.source, doc.span(child.id), offset) {
            found = Some(child.id);
        }
    }
    found
}

/// The deepest node a CARET at `offset` is in. Never `None` for a non-empty
/// tree: a caret in a gap reports the container that holds the gap.
pub fn deepest_containing_for_caret(doc: &Document, offset: usize) -> Option<NodeId> {
    if doc.ast.nodes.is_empty() {
        return None;
    }
    let mut cur = doc.ast.root;
    while let Some(child) = caret_child_containing(doc, cur, offset) {
        cur = child;
    }
    Some(cur)
}

/// `ancestor_chain` under caret containment — root first, deepest last.
pub fn caret_chain(doc: &Document, offset: usize, out: &mut Vec<NodeId>) {
    if doc.ast.nodes.is_empty() {
        return;
    }
    let mut cur = doc.ast.root;
    out.push(cur);
    while let Some(child) = caret_child_containing(doc, cur, offset) {
        cur = child;
        out.push(cur);
    }
}

/// `caret_chain` as a fresh vector.
pub fn caret_chain_vec(doc: &Document, offset: usize) -> Vec<NodeId> {
    let mut out = Vec::new();
    caret_chain(doc, offset, &mut out);
    out
}

/// `ancestor_chain` as a fresh vector.
pub fn ancestor_chain_vec(doc: &Document, offset: usize) -> Vec<NodeId> {
    let mut out = Vec::new();
    ancestor_chain(doc, offset, &mut out);
    out
}

// ── Line prefixes ──────────────────────────────────────────────────────────

/// Everything HIDDEN before the content on the line `offset` sits on: every
/// marker a node OPENS that line with, and the indentation between them, as
/// one span from the line start. `None` on a CONTINUATION line.
pub fn line_prefix_span(doc: &Document, offset: usize) -> Option<Span> {
    if doc.ast.nodes.is_empty() {
        return None;
    }
    let line_start = line_start_at(&doc.source, offset);
    let line_end = line_end_at(&doc.source, offset);
    let mut end: Option<usize> = None;
    let mut cur = doc.ast.root;
    loop {
        if let Some(m) = doc.marker_span(cur) {
            if m.start >= line_start && m.start < line_end && end.is_none_or(|e| m.end > e) {
                end = Some(m.end);
            }
        }
        match caret_child_containing(doc, cur, offset) {
            Some(c) => cur = c,
            None => break,
        }
    }
    Some(Span::new(line_start, end?))
}

/// The raw source bytes `line_prefix_span` covers.
pub fn line_prefix_text(doc: &Document, offset: usize) -> Option<&[u8]> {
    let s = line_prefix_span(doc, offset)?;
    Some(s.of(&doc.source))
}

/// How wide a tab is (CommonMark's column model).
const TAB_STOP: usize = 4;

/// The COLUMN of `offset` on its own line — a tab advances to a tab stop.
pub fn column_of(src: &[u8], offset: usize) -> usize {
    let at = offset.min(src.len());
    let mut col = 0;
    for &c in &src[line_start_at(src, at)..at] {
        col = if c == b'\t' { col + (TAB_STOP - col % TAB_STOP) } else { col + 1 };
    }
    col
}

/// True for a container that holds its children behind a PER-LINE PREFIX.
fn is_marker_prefixed(kind: &Kind) -> bool {
    matches!(
        kind,
        Kind::BlockQuote
            | Kind::ListItem
            | Kind::TaskListItem { .. }
            | Kind::DefinitionListItem
            | Kind::Definition
            | Kind::Footnote { .. }
    )
}

/// Whether a container's prefix is REPRODUCED on a continuation line (a
/// quote's `> `) or merely INDENTED past (a list item's marker width).
fn repeats_verbatim(kind: &Kind) -> bool {
    matches!(kind, Kind::BlockQuote)
}

/// What a CONTINUATION LINE at `offset` must open with to stay inside every
/// container holding it — appended to `out`. Returns the prefix's width in
/// COLUMNS.
pub fn continuation_prefix(doc: &Document, offset: usize, out: &mut Vec<u8>) -> usize {
    if doc.ast.nodes.is_empty() {
        return 0;
    }
    let chain = caret_chain_vec(doc, offset);
    continuation_prefix_along(doc, &chain, out)
}

/// `continuation_prefix` over an explicit ancestor chain.
pub fn continuation_prefix_along(doc: &Document, chain: &[NodeId], out: &mut Vec<u8>) -> usize {
    let src = &doc.source;
    let mut col = 0;
    for &cur in chain {
        let kind = &doc.ast.nodes[cur as usize].kind;
        if !is_marker_prefixed(kind) {
            continue;
        }
        let Some(m) = doc.marker_span(cur) else { continue };
        let start_col = column_of(src, m.start);
        let end_col = column_of(src, m.end);
        while col < start_col {
            out.push(b' ');
            col += 1;
        }
        if end_col > col {
            if repeats_verbatim(kind) {
                out.extend_from_slice(&src[m.start..m.end]);
            } else {
                out.extend(std::iter::repeat_n(b' ', end_col - col));
            }
            col = end_col;
        }
    }
    col
}

/// What a BLANK line inside the containers at `offset` must carry — appended
/// to `out`, returning its width in columns: `continuation_prefix` with the
/// trailing spaces cut back.
pub fn blank_line_prefix(doc: &Document, offset: usize, out: &mut Vec<u8>) -> usize {
    let base = out.len();
    continuation_prefix(doc, offset, out);
    while out.len() > base && matches!(out[out.len() - 1], b' ' | b'\t') {
        out.pop();
    }
    columns_in(&out[base..])
}

/// The column width of an already-built prefix.
fn columns_in(prefix: &[u8]) -> usize {
    let mut col = 0;
    for &c in prefix {
        col = if c == b'\t' { col + (TAB_STOP - col % TAB_STOP) } else { col + 1 };
    }
    col
}

/// The LINE-OWNING BLOCK holding `offset` and the container holding it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineBlock {
    pub parent: NodeId,
    pub block: NodeId,
}

/// The child of the innermost block-parent container on the descent to
/// `offset`, or `None` when no node covers the offset at all.
pub fn line_owning_block(doc: &Document, offset: usize) -> Option<LineBlock> {
    let mut result = None;
    let mut cur = doc.ast.root;
    while let Some(child) = child_containing(doc, cur, offset) {
        if is_block_parent(&doc.ast.nodes[cur as usize].kind) {
            result = Some(LineBlock { parent: cur, block: child });
        }
        cur = child;
    }
    result
}

/// The innermost `heading`/`para` on the descent to `offset`.
pub fn innermost_block(doc: &Document, offset: usize) -> Option<NodeId> {
    let mut result = None;
    let mut cur = doc.ast.root;
    loop {
        if matches!(doc.ast.nodes[cur as usize].kind, Kind::Heading { .. } | Kind::Para) {
            result = Some(cur);
        }
        match child_containing(doc, cur, offset) {
            Some(c) => cur = c,
            None => break,
        }
    }
    result
}

/// True for a node whose children are blocks that each OWN THEIR LINES — a
/// hand-kept list, deliberately not `content_model() == Blocks` (a table cell
/// holds blocks but shares its line with its row).
pub fn is_block_parent(kind: &Kind) -> bool {
    match kind {
        Kind::Doc | Kind::BlockQuote | Kind::ListItem | Kind::TaskListItem { .. } | Kind::Section => true,
        Kind::Container(c) => c.form.is_some_and(|f| f.is_block_form()),
        _ => false,
    }
}

/// True for the three container kinds a toggle targets.
pub fn is_block_container(tag: KindTag) -> bool {
    matches!(tag, Tag::BlockQuote | Tag::BulletList | Tag::OrderedList)
}

/// The innermost node on `chain` whose kind is `tag`.
pub fn innermost_of_kind(doc: &Document, chain: &[NodeId], tag: KindTag) -> Option<NodeId> {
    chain.iter().rev().copied().find(|&id| doc.ast.nodes[id as usize].kind.tag() == tag)
}

/// The innermost node on `chain` of any kind in `tags` that wholly contains
/// `[start, end)`.
pub fn innermost_covering(doc: &Document, chain: &[NodeId], tags: &[KindTag], start: usize, end: usize) -> Option<NodeId> {
    for &id in chain.iter().rev() {
        let tag = doc.ast.nodes[id as usize].kind.tag();
        let sp = doc.span(id);
        if tags.iter().any(|&want| tag == want && sp.start <= start && sp.end >= end) {
            return Some(id);
        }
    }
    None
}

// ── Inline hosts ───────────────────────────────────────────────────────────

/// The source range inside `id` where inline content lives, or `None` when
/// `id` is not a place an inline mark may be written.
pub fn inline_host_region(doc: &Document, id: NodeId) -> Option<Span> {
    let kind = &doc.ast.nodes[id as usize].kind;
    if kind.level() == Level::Inline {
        return None;
    }
    let holds = match kind.content_model() {
        ContentModel::Inlines => true,
        ContentModel::Blocks => holds_inlines_directly(doc, id),
        ContentModel::Text | ContentModel::Empty => false,
    };
    if !holds {
        return None;
    }
    let region = doc.content_span(id).unwrap_or_else(|| doc.span(id));
    if region.is_empty() { None } else { Some(region) }
}

/// True when `id` has children and every one of them is inline.
fn holds_inlines_directly(doc: &Document, id: NodeId) -> bool {
    let mut any = false;
    for child in doc.children(id) {
        if child.kind.level() != Level::Inline {
            return false;
        }
        any = true;
    }
    any
}

/// `span` cut into the share of it belonging to each inline host it touches —
/// ascending, disjoint. Appends to `out`.
pub fn inline_host_pieces(doc: &Document, span: Span, out: &mut Vec<Span>) {
    let base = out.len();
    for i in 0..doc.ast.nodes.len() {
        let Some(region) = inline_host_region(doc, i as NodeId) else { continue };
        let start = region.start.max(span.start);
        let end = region.end.min(span.end);
        if start >= end {
            continue;
        }
        out.push(Span::new(start, end));
    }
    // Zig's `std.mem.sort` is a stable block sort; `sort_by_key` is stable.
    out[base..].sort_by_key(|s| s.start);
    let mut kept = base;
    for i in base..out.len() {
        let p = out[i];
        if kept > base && p.start < out[kept - 1].end {
            continue;
        }
        out[kept] = p;
        kept += 1;
    }
    out.truncate(kept);
}

/// Grow `piece` to take in every code span (`verbatim`, `inline_math`) it
/// cuts into.
pub fn widen_over_verbatim(doc: &Document, piece: &mut Span) {
    for node in &doc.ast.nodes {
        let Kind::TextLeaf { kind, .. } = &node.kind else { continue };
        if *kind != TextLeafKind::Verbatim && *kind != TextLeafKind::InlineMath {
            continue;
        }
        let s = doc.span(node.id);
        if s.is_empty() {
            continue;
        }
        if s.end <= piece.start || piece.end <= s.start {
            continue;
        }
        piece.start = piece.start.min(s.start);
        piece.end = piece.end.max(s.end);
    }
}

// ── Line scanning ──────────────────────────────────────────────────────────

/// The start of the line `at` sits on.
pub fn line_start_at(src: &[u8], at: usize) -> usize {
    let mut i = at.min(src.len());
    while i > 0 && src[i - 1] != b'\n' {
        i -= 1;
    }
    i
}

/// One past the newline terminating the line `at` sits on (or `src.len()`).
pub fn line_end_at(src: &[u8], at: usize) -> usize {
    let mut i = at.min(src.len());
    while i < src.len() && src[i] != b'\n' {
        i += 1;
    }
    if i < src.len() { i + 1 } else { i }
}

/// `line` without its trailing `\r\n` / `\n`.
pub fn line_body(line: &[u8]) -> &[u8] {
    let mut e = line.len();
    if e > 0 && line[e - 1] == b'\n' {
        e -= 1;
    }
    if e > 0 && line[e - 1] == b'\r' {
        e -= 1;
    }
    &line[..e]
}

/// Only spaces/tabs (or nothing) — a line that separates blocks.
pub fn is_blank_line(body: &[u8]) -> bool {
    body.iter().all(|&c| c == b' ' || c == b'\t')
}

#[cfg(test)]
mod tests {
    use super::*;
    use {twig_djot as djot, twig_markdown as markdown, twig_xml as xml};

    fn find(hay: &[u8], needle: &[u8]) -> usize {
        hay.windows(needle.len()).position(|w| w == needle).unwrap()
    }

    #[test]
    fn span_contains_treats_an_unset_span_as_containing_nothing() {
        assert!(!span_contains(Span::new(0, 0), 0, 10));
        assert!(span_contains(Span::new(0, 5), 0, 10));
        assert!(!span_contains(Span::new(0, 5), 5, 10));
        assert!(span_contains(Span::new(5, 10), 10, 10));
        assert!(!span_contains(Span::new(0, 5), 10, 10));
    }

    #[test]
    fn line_scanning() {
        let src = b"ab\ncd\n\nef";
        assert_eq!(line_start_at(src, 1), 0);
        assert_eq!(line_start_at(src, 4), 3);
        assert_eq!(line_end_at(src, 1), 3);
        assert_eq!(line_end_at(src, 7), 9);
        assert_eq!(line_body(b"ab\n"), b"ab");
        assert_eq!(line_body(b"ab\r\n"), b"ab");
        assert_eq!(line_body(b"ab"), b"ab");
        assert!(is_blank_line(b""));
        assert!(is_blank_line(b"  \t"));
        assert!(!is_blank_line(b" x"));
    }

    #[test]
    fn deepest_containing_descends_to_the_innermost_node_and_chains_to_it() {
        let src = b"<r><a>hi</a></r>";
        let doc = xml::parse(src).unwrap();
        let at = find(src, b"hi");
        let deep = deepest_containing(&doc, at).unwrap();
        let chain = ancestor_chain_vec(&doc, at);
        assert_eq!(deep, *chain.last().unwrap());
        assert_eq!(doc.ast.root, chain[0]);
        assert!(chain.len() >= 2);
    }

    #[test]
    fn deepest_containing_reaches_a_mark_in_the_first_cell_of_a_two_column_markdown_row() {
        let src = b"| A | B |\n| --- | --- |\n| **bold** | other |\n";
        let doc = markdown::parse(src, Default::default());
        let at = find(src, b"bold") + 1;
        let deep = deepest_containing(&doc, at).unwrap();
        assert!(matches!(doc.ast.kind(deep), Kind::Str(_)));
        let chain = ancestor_chain_vec(&doc, at);
        assert!(chain.iter().any(|&id| doc.ast.kind(id).is_inline_mark(crate::ast::InlineMark::Strong)));
        let other = find(src, b"other");
        let cell = deepest_containing(&doc, other - 2).unwrap();
        assert!(matches!(doc.ast.kind(cell), Kind::Cell(_)));
        assert_eq!(doc.span(cell).of(src), b"| other ");
    }

    /// Parse `src` as both authorable formats and hand each `Document` to
    /// `check`.
    fn for_both_formats(src: &[u8], check: impl Fn(&Document, &[u8])) {
        let md = markdown::parse(src, Default::default());
        check(&md, src);
        let dj = djot::parse(src);
        check(&dj, src);
    }

    fn kind_at(doc: &Document, offset: usize) -> Tag {
        doc.ast.kind(deepest_containing_for_caret(doc, offset).unwrap()).tag()
    }

    #[test]
    fn caret_a_blocks_end_is_inside_it_and_a_blank_line_between_blocks_is_not() {
        for_both_formats(b"a\n\nb\n", |doc, _| {
            assert_eq!(kind_at(doc, 0), Tag::Str);
            assert_eq!(kind_at(doc, 1), Tag::Str);
            assert_eq!(kind_at(doc, 3), Tag::Str);
            assert_eq!(kind_at(doc, 4), Tag::Str);
            assert_eq!(kind_at(doc, 2), Tag::Doc);
            assert_eq!(kind_at(doc, 5), Tag::Doc);
        });
    }

    #[test]
    fn caret_the_chain_from_a_caret_at_a_paragraphs_end_reaches_the_paragraph() {
        for_both_formats(b"- a\n  - b\n", |doc, src| {
            let chain = caret_chain_vec(doc, src.len() - 1);
            assert!(chain.iter().any(|&id| doc.ast.kind(id).tag() == Tag::Para));
            assert!(chain.iter().any(|&id| doc.ast.kind(id).tag() == Tag::ListItem));
        });
    }

    #[test]
    fn line_prefix_span_a_nested_items_prefix_includes_the_indent() {
        for_both_formats(b"- a\n\n  - b\n", |doc, src| {
            let at = find(src, b"b");
            assert_eq!(line_prefix_text(doc, at).unwrap(), b"  - ");
            let a = find(src, b"a");
            assert_eq!(line_prefix_text(doc, a).unwrap(), b"- ");
        });
    }

    #[test]
    fn line_prefix_span_no_marker_where_the_format_read_no_item() {
        let src = b"- a\n  - b\n";
        let md = markdown::parse(src, Default::default());
        assert_eq!(line_prefix_text(&md, src.len() - 2).unwrap(), b"  - ");
        let dj = djot::parse(src);
        assert_eq!(line_prefix_text(&dj, src.len() - 2), None);
    }

    #[test]
    fn line_prefix_span_every_marker_on_the_line_from_quote_to_checkbox() {
        for_both_formats(b"> - [ ] x\n", |doc, src| {
            let at = find(src, b"x");
            assert_eq!(line_prefix_text(doc, at).unwrap(), b"> - [ ] ");
        });
    }

    #[test]
    fn line_prefix_span_a_headings_marker_and_none_on_a_continuation_line() {
        for_both_formats(b"## h\n\n> c\n> d\n", |doc, src| {
            assert_eq!(line_prefix_text(doc, 4).unwrap(), b"## ");
            let at = find(src, b"d");
            assert_eq!(line_prefix_text(doc, at), None);
        });
    }

    fn cont_prefix(doc: &Document, offset: usize) -> Vec<u8> {
        let mut out = Vec::new();
        let cols = continuation_prefix(doc, offset, &mut out);
        assert_eq!(out.len(), cols);
        out
    }

    #[test]
    fn continuation_prefix_a_quote_repeats_its_marker_an_item_indents_past_it() {
        for_both_formats(b"> - a\n", |doc, src| {
            assert_eq!(cont_prefix(doc, find(src, b"a")), b">   ");
        });
    }

    #[test]
    fn continuation_prefix_nesting_accumulates_across_different_lines() {
        for_both_formats(b"- a\n\n  - b\n", |doc, src| {
            assert_eq!(cont_prefix(doc, find(src, b"b")), b"    ");
        });
    }

    #[test]
    fn continuation_prefix_an_ordered_markers_own_width() {
        for_both_formats(b"10. x\n", |doc, src| {
            assert_eq!(cont_prefix(doc, find(src, b"x")), b"    ");
        });
    }

    #[test]
    fn continuation_prefix_a_continuation_line_answers_for_the_line_it_is_on() {
        for_both_formats(b"> c\n> d\n", |doc, src| {
            let at = find(src, b"d");
            assert_eq!(line_prefix_text(doc, at), None);
            assert_eq!(cont_prefix(doc, at), b"> ");
        });
    }

    #[test]
    fn continuation_prefix_nothing_at_the_top_level() {
        for_both_formats(b"plain\n", |doc, src| {
            assert_eq!(cont_prefix(doc, src.len() - 1), b"");
        });
    }

    #[test]
    fn blank_line_prefix_a_quote_keeps_its_marker_an_item_keeps_nothing() {
        for_both_formats(b"> - a\n", |doc, src| {
            let mut out = Vec::new();
            let cols = blank_line_prefix(doc, find(src, b"a"), &mut out);
            assert_eq!(out, b">");
            assert_eq!(cols, 1);
        });
    }

    #[test]
    fn continuation_prefix_a_tab_in_a_marker_advances_to_a_tab_stop() {
        let doc = markdown::parse(b"-\tx\n", Default::default());
        let mut out = Vec::new();
        let at = find(&doc.source, b"x");
        let cols = continuation_prefix(&doc, at, &mut out);
        assert_eq!(cols, 4);
        assert_eq!(out.len(), 4);
    }

    #[test]
    fn an_offset_past_every_span_resolves_to_nothing() {
        let doc = xml::parse(b"<r/>").unwrap();
        assert_eq!(deepest_containing(&doc, 999), None);
    }
}
