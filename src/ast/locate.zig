//! Hit-testing: byte offset -> node, plus the line scanning the block gestures
//! are built on.
//!
//! The AST addresses nodes three ways — an index path, a `Node.Id`, and a
//! `Select` match — and a caret speaks none of them. It speaks a byte offset.
//! This is the missing fourth: `deepestContaining(ast, offset)` and the
//! `ancestorChain` down to it.
//!
//! All of it is pure `AST` traversal and pure byte scanning: no format, no
//! allocation beyond the caller's chain buffer, nothing to do with any ABI. It
//! lived in `c_abi.zig` only because `twig_editor_node_at` was the first caller
//! that needed it.
//!
//! `Node` carries no parent link (the arena is index-based and children are a
//! sibling chain — see `ast.zig`), so an ancestor chain can't be walked upward;
//! it is rebuilt by descending from the root. Every walk here is therefore
//! top-down.

const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Document = @import("../document.zig");
const Span = @import("../span.zig");

/// A `Node.Kind` tag without its payload — the language-agnostic way to name a
/// kind. Re-exported from the splicer so callers of this module needn't import
/// both.
pub const KindTag = @import("splicer.zig").Splicer.KindTag;

/// True if `offset` falls in node span `s` (half-open), treating a whole-source
/// end position as inside, and an unset `(0,0)` span as containing nothing.
///
/// The `(0,0)` guard matters: some parsers leave a node's span unset (notably
/// Markdown's inline nodes, and the `doc` root), and without it every such node
/// would claim to contain offset 0.
pub fn spanContains(s: Span, offset: usize, source_len: usize) bool {
    if (s.start == 0 and s.end == 0) return false;
    if (offset == source_len) return offset >= s.start and s.end >= source_len;
    return offset >= s.start and offset < s.end;
}

/// The child of `id` whose span contains `offset` — the LAST such child, so an
/// offset on a boundary resolves into the later sibling. `null` if none.
pub fn childContaining(doc: *const Document, id: AST.Node.Id, offset: usize) ?AST.Node.Id {
    var found: ?AST.Node.Id = null;
    var it = doc.children(id);
    while (it.next()) |child| {
        if (spanContains(doc.span(child.id), offset, doc.source.len)) found = child.id;
    }
    return found;
}

/// The deepest node containing `offset`, descending from the root. The root's
/// own span may be unset `(0,0)` (some parsers don't span the `doc` node); when
/// so, entry is the root's child that owns the offset, and descent continues
/// fully from there. `null` if no node covers the offset at all.
pub fn deepestContaining(doc: *const Document, offset: usize) ?AST.Node.Id {
    var cur = doc.ast.root;
    if (!spanContains(doc.span(cur), offset, doc.source.len)) {
        cur = childContaining(doc, cur, offset) orelse return null;
    }
    while (childContaining(doc, cur, offset)) |child| cur = child;
    return cur;
}

/// The chain of node ids from the root down to the deepest node containing
/// `offset` — the ancestor walk the container gestures detect enclosing
/// containers with. Appends to `out`; the caller owns it.
pub fn ancestorChain(
    allocator: Allocator,
    doc: *const Document,
    offset: usize,
    out: *std.ArrayList(AST.Node.Id),
) Allocator.Error!void {
    var cur = doc.ast.root;
    try out.append(allocator, cur);
    while (childContaining(doc, cur, offset)) |child| {
        cur = child;
        try out.append(allocator, cur);
    }
}

// ── Caret hit-testing ──────────────────────────────────────────────────────
// The same descent, under the containment rule an EDITING CARET needs rather
// than the one a byte range needs. Kept as its own pair of entry points rather
// than a flag on the ones above, because the two rules disagree and both are
// right for their own caller.

/// True if a CARET at `offset` sits in node span `s`, whose source is `src`.
///
/// Two differences from `spanContains`, and both exist because a caret is a
/// position BETWEEN bytes while a span is a range OF bytes:
///
///  1. **End-inclusive.** A caret at a block's end is in that block — it is
///     where you stand to type the rest of the paragraph. Half-open containment
///     puts it outside, which is why an editor probing `ancestors_at` had to
///     guess at contrived offsets (`content_start`, `caret - 1`, the marker's
///     own byte) to find the block it was plainly inside of.
///
///  2. **A trailing line terminator is not part of the block.** This is what
///     makes the two authorable formats agree. Djot ends a paragraph's span
///     AFTER its newline and Markdown BEFORE it, so on `"a\n\nb\n"` the caret
///     at offset 1 read as `para` in djot and as `doc` in Markdown, and the
///     caret at end-of-source read as `para` in djot and `doc` in Markdown —
///     the same caret, two answers, decided by which parser happened to
///     produce the tree. Trimming the terminator normalises both ends: the
///     caret after `a` is in `a`'s paragraph in both, and the caret on the
///     blank line after it is in neither.
///
/// Note that end-inclusive does NOT make an inline mark sticky, which was the
/// reason not to simply relax `spanContains` itself: `caretChildContaining`
/// keeps the LAST matching child, so a caret on the boundary between an `emph`
/// and the text after it resolves into the text, exactly as before.
pub fn caretContains(src: []const u8, s: Span, offset: usize) bool {
    if (s.start == 0 and s.end == 0) return false;
    if (offset < s.start) return false;
    var end = @min(s.end, src.len);
    if (end > s.start and src[end - 1] == '\n') end -= 1;
    if (end > s.start and src[end - 1] == '\r') end -= 1;
    return offset <= end;
}

/// `childContaining` under `caretContains` — the LAST matching child again, so
/// a caret on a boundary resolves into the later sibling.
pub fn caretChildContaining(doc: *const Document, id: AST.Node.Id, offset: usize) ?AST.Node.Id {
    var found: ?AST.Node.Id = null;
    var it = doc.children(id);
    while (it.next()) |child| {
        if (caretContains(doc.source, doc.span(child.id), offset)) found = child.id;
    }
    return found;
}

/// The deepest node a CARET at `offset` is in — `deepestContaining`'s answer to
/// the question an editor is actually asking. See `caretContains`.
///
/// Unlike `deepestContaining` this never returns `null` for a non-empty tree:
/// the descent starts AT the root and stops where no child matches, so a caret
/// in the gap between two blocks (or past the last one) reports the container
/// that holds the gap rather than nothing at all. The root's own span is never
/// tested, which is what lets this work for the parsers that leave it unset.
pub fn deepestContainingForCaret(doc: *const Document, offset: usize) ?AST.Node.Id {
    if (doc.ast.nodes.len == 0) return null;
    var cur = doc.ast.root;
    while (caretChildContaining(doc, cur, offset)) |child| cur = child;
    return cur;
}

/// `ancestorChain` under caret containment — root first, deepest last. See
/// `caretContains`.
pub fn caretChain(
    allocator: Allocator,
    doc: *const Document,
    offset: usize,
    out: *std.ArrayList(AST.Node.Id),
) Allocator.Error!void {
    if (doc.ast.nodes.len == 0) return;
    var cur = doc.ast.root;
    try out.append(allocator, cur);
    while (caretChildContaining(doc, cur, offset)) |child| {
        cur = child;
        try out.append(allocator, cur);
    }
}

// ── Line prefixes ──────────────────────────────────────────────────────────

/// Everything HIDDEN before the content on the line `offset` sits on: every
/// marker a node OPENS that line with, and the indentation between them, as one
/// span from the line start.
///
/// This is the assembled form of `Document.node_marker_spans`, which records
/// each node's own marker alone. A nested construct's prefix is the union of
/// its ancestors' — `>   1. [ ] ` is four nodes' markers plus the spaces
/// between them — and the union is contiguous from the line start, so this
/// walks the descent to `offset` and takes the LAST marker opening on that
/// line. Reaching back to the line start rather than concatenating the spans is
/// what picks up a nested item's INDENT, which is real hidden width that no
/// node claims as its own marker.
///
/// `null` when nothing opens on this line — a CONTINUATION line, the second
/// line of a wrapped paragraph or of a quote. That is deliberate and not an
/// oversight: what a continuation line is prefixed with is a different question
/// with a different answer (a quote repeats `> `, a list item repeats spaces),
/// and answering it from marker spans alone would be a guess. A caller that
/// wants it should ask for a continuation prefix, not read this and hope.
pub fn linePrefixSpan(doc: *const Document, offset: usize) ?Span {
    if (doc.ast.nodes.len == 0) return null;
    const line_start = lineStartAt(doc.source, offset);
    const line_end = lineEndAt(doc.source, offset);

    var end: ?usize = null;
    var cur = doc.ast.root;
    while (true) {
        if (doc.markerSpan(cur)) |m| {
            // On THIS line: an ancestor whose marker opened an earlier line
            // contributes its indent (via the reach back to `line_start`), not
            // its marker.
            if (m.start >= line_start and m.start < line_end) {
                if (end == null or m.end > end.?) end = m.end;
            }
        }
        cur = caretChildContaining(doc, cur, offset) orelse break;
    }
    const e = end orelse return null;
    return Span.init(line_start, e);
}

/// The raw source bytes `linePrefixSpan` covers, or `null` when it has none —
/// what a rich view hides at the head of this line.
pub fn linePrefixText(doc: *const Document, offset: usize) ?[]const u8 {
    const s = linePrefixSpan(doc, offset) orelse return null;
    return Span.of(u8, s, doc.source);
}

/// How wide a tab is. CommonMark's column model, which djot shares: a tab
/// advances to the next multiple of this, it does not contribute a fixed width.
const tab_stop = 4;

/// The COLUMN of `offset` on its own line — not `offset - line_start`, because a
/// tab in a marker or an indent advances to a tab stop rather than by one.
fn columnOf(src: []const u8, offset: usize) usize {
    const at = @min(offset, src.len);
    var i = lineStartAt(src, at);
    var col: usize = 0;
    while (i < at) : (i += 1) {
        col = if (src[i] == '\t') col + (tab_stop - col % tab_stop) else col + 1;
    }
    return col;
}

/// True for a container that holds its children behind a PER-LINE PREFIX — the
/// kinds a continuation line has to re-open, and exactly the kinds that report
/// `content_span == span` for the same underlying reason (see
/// `Document.node_content_spans`).
///
/// Hand-kept rather than derived from `contentModel`, for the reason
/// `isBlockParent` is: "may hold blocks" does not imply "prefixes every line of
/// them". A `cell` holds blocks and prefixes nothing.
fn isMarkerPrefixed(kind: AST.Node.Kind) bool {
    return switch (kind) {
        .block_quote,
        .list_item,
        .task_list_item,
        .definition_list_item,
        .definition,
        .footnote,
        => true,
        else => false,
    };
}

/// Whether a container's prefix is REPRODUCED on a continuation line or merely
/// INDENTED past. A quote's `> ` must reappear on every line it holds; a list
/// item's marker must NOT — repeating `- ` would open a second item, so what the
/// continuation carries is the marker's WIDTH IN SPACES instead.
fn repeatsVerbatim(kind: AST.Node.Kind) bool {
    return kind == .block_quote;
}

/// What a CONTINUATION LINE at `offset` must open with to stay inside every
/// container holding it — appended to `out`. Returns the prefix's width in
/// COLUMNS, which is the other half of the answer (Tab's step, a caret's
/// horizontal home, an outdent's width) and is not `out.items.len` once a tab is
/// involved.
///
/// ── Why this is not `linePrefixSpan` ───────────────────────────────────────
/// They answer opposite questions and neither can be derived from the other.
/// `linePrefixSpan` reports the bytes ALREADY THERE on a line something opens —
/// contiguous source, so it hands back a span. This one reports the bytes that
/// WOULD HAVE TO BE WRITTEN on a line nothing opens, which is not source at all:
/// a list item's continuation is spaces where the marker was, so there is
/// nothing to point at and the answer has to be built.
///
/// That is why `linePrefixSpan` returns `null` on a continuation line rather
/// than guessing — the guess an editor makes there (re-read the previous line's
/// bytes and copy what looks like a marker) is what turns `- a` plus Enter into
/// two items in a format where it should be one.
///
/// ── How it composes ────────────────────────────────────────────────────────
/// Each marker-prefixed ancestor on the caret's chain contributes the COLUMNS
/// ITS OWN MARKER OCCUPIES, on its own opening line — which may be a different
/// line for each of them, and is the reason this walks the tree instead of
/// reading one line's bytes:
///
///     > - a          quote `> ` (cols 0-2) + item `- ` (cols 2-4)  ->  ">   "
///     - a            outer item (cols 0-2)
///       - b          inner item (cols 2-4)                         ->  "    "
///
/// The widths compose because a nested container's marker STARTS where its
/// parent's content does, so each contribution picks up where the last left off.
/// A gap (a parent that recorded no marker) is padded with spaces rather than
/// silently closed, so the columns still line up.
///
/// Appends nothing and returns 0 at the top level, which is the correct prefix
/// there: none.
pub fn continuationPrefix(
    allocator: Allocator,
    doc: *const Document,
    offset: usize,
    out: *std.ArrayList(u8),
) Allocator.Error!usize {
    if (doc.ast.nodes.len == 0) return 0;
    const src = doc.source;
    var col: usize = 0;
    var cur = doc.ast.root;

    while (true) {
        if (isMarkerPrefixed(doc.ast.nodes[cur].kind)) {
            if (doc.markerSpan(cur)) |m| {
                const start_col = columnOf(src, m.start);
                const end_col = columnOf(src, m.end);
                // Pad any gap, then lay down this container's own columns. A
                // marker already behind us (a malformed or unrecorded chain)
                // contributes nothing rather than reaching backwards.
                while (col < start_col) : (col += 1) try out.append(allocator, ' ');
                if (end_col > col) {
                    if (repeatsVerbatim(doc.ast.nodes[cur].kind)) {
                        try out.appendSlice(allocator, src[m.start..m.end]);
                    } else {
                        try out.appendNTimes(allocator, ' ', end_col - col);
                    }
                    col = end_col;
                }
            }
        }
        cur = caretChildContaining(doc, cur, offset) orelse break;
    }
    return col;
}

/// What a BLANK line inside the containers at `offset` must carry — appended to
/// `out`, returning its width in columns.
///
/// A quote's blank line still has to carry its `>` or the quote ENDS there; a
/// list item's blank line must carry nothing, because a blank line between two
/// of an item's blocks is what makes its whole list loose and re-indenting it
/// changes nothing about that. So this is `continuationPrefix` with the trailing
/// spaces cut back — which drops a list item's indent entirely while leaving a
/// quote marker standing, exactly as `Syntax.ContainerSpelling.blank` states the
/// rule for the toggle gestures.
///
/// The one subtlety is that a quote's blank form is `>` and not `> `: the space
/// after the marker is content indentation, and a blank line has no content.
/// Trimming trailing spaces produces that for free.
pub fn blankLinePrefix(
    allocator: Allocator,
    doc: *const Document,
    offset: usize,
    out: *std.ArrayList(u8),
) Allocator.Error!usize {
    const base = out.items.len;
    _ = try continuationPrefix(allocator, doc, offset, out);
    const trimmed = std.mem.trimEnd(u8, out.items[base..], " \t");
    out.items.len = base + trimmed.len;
    return columnsIn(out.items[base..]);
}

/// The column width of an already-built prefix — `len` unless it holds a tab.
fn columnsIn(prefix: []const u8) usize {
    var col: usize = 0;
    for (prefix) |c| {
        col = if (c == '\t') col + (tab_stop - col % tab_stop) else col + 1;
    }
    return col;
}

/// The LINE-OWNING BLOCK holding `offset`: the child of the innermost
/// block-parent container on the descent, or `null` when no node covers the
/// offset at all (an empty document, or one whose root spans nothing).
///
/// This is what a gesture placing a NEW BLOCK BESIDE the caret's block needs,
/// and it is deliberately not `innermostBlock`. That one answers a narrower
/// question — which `para`/`heading`'s marker to rewrite — and returns `null`
/// for a caret in a code block or a table, because `setBlock` has nothing to do
/// there. A gesture that reads that `null` as "there is no block here" and
/// falls back to the caret's own line writes its block INTO the fence or
/// BETWEEN a table's header and its delimiter row, which loses the table.
///
/// `isBlockParent` is the right hinge because of what it already asserts: a
/// kind belongs to it only if its children EACH START ON THEIR OWN LINE. So the
/// child on the descent path is, by that list's own contract, a block owning
/// whole lines — and stopping there is what escapes a table (a `cell` is
/// deliberately not a block parent, so the walk stops at the `table` rather
/// than at a `para` inside a cell) while still descending into a quote or a
/// list item, whose contents genuinely do start their own lines.
/// `block` is the block itself; `parent` is the container holding it — which
/// `Editor.splitBlock` needs, because what a split writes between the halves is
/// the parent's business (a `list_item` parent means repeat the item's marker,
/// so the second half is an item and not a stray paragraph).
pub const LineBlock = struct { parent: AST.Node.Id, block: AST.Node.Id };

pub fn lineOwningBlock(doc: *const Document, offset: usize) ?LineBlock {
    var result: ?LineBlock = null;
    var cur = doc.ast.root;
    while (childContaining(doc, cur, offset)) |child| {
        if (isBlockParent(doc.ast.nodes[cur].kind)) result = .{ .parent = cur, .block = child };
        cur = child;
    }
    return result;
}

/// The innermost `heading`/`para` on the descent to `offset`, or `null` — the
/// block `Editor.setBlock` rewrites the marker of. For "the block the caret is
/// in" in the general sense, including code blocks and tables, see
/// `lineOwningBlock`.
pub fn innermostBlock(doc: *const Document, offset: usize) ?AST.Node.Id {
    var result: ?AST.Node.Id = null;
    var cur = doc.ast.root;
    while (true) {
        switch (std.meta.activeTag(doc.ast.nodes[cur].kind)) {
            .heading, .para => result = cur,
            else => {},
        }
        cur = childContaining(doc, cur, offset) orelse break;
    }
    return result;
}

/// True for a node whose children are blocks — the level a container op works
/// at. Everything else (a `para`, a `heading`) holds inlines.
///
/// ── Why this is NOT `kind.contentModel() == .blocks` ───────────────────────
/// It looks like it should be, and it was written that way first. It is not,
/// because a container gesture prefixes whole LINES, and "may hold blocks" does
/// not imply "its children each own their lines". A table `cell` may hold
/// blocks — HTML's `<td><p>x</p></td>` does — but a row's cells SHARE one line,
/// so treating a cell as a block parent makes the quote gesture wrap the header
/// row and not the separator under it:
///
///     | c | d |          > | c | d |
///     |---|---|    ->    |---|---|      <- broken table, not a quoted one
///
/// against the correct whole-table wrap the list below produces. The full test
/// suite passes either way, so this is deliberately a hand-kept list of the
/// LINE-OWNING containers, not a derivation. Adding a kind here means asserting
/// its children each start on their own line.
pub fn isBlockParent(kind: AST.Node.Kind) bool {
    return switch (kind) {
        .doc, .block_quote, .list_item, .task_list_item, .section => true,
        .container => |c| if (c.form) |f| f.isBlockForm() else false,
        else => false,
    };
}

/// True for the three container kinds a toggle targets.
pub fn isBlockContainer(tag: KindTag) bool {
    return switch (tag) {
        .block_quote, .bullet_list, .ordered_list => true,
        else => false,
    };
}

/// The innermost node on `chain` whose kind is `tag`, or `null`.
pub fn innermostOfKind(doc: *const Document, chain: []const AST.Node.Id, tag: KindTag) ?AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        if (std.meta.activeTag(doc.ast.nodes[chain[i]].kind) == tag) return chain[i];
    }
    return null;
}

/// The innermost node on `chain` of any kind in `tags` that wholly contains
/// `[start, end)`, or `null`. The containment test is what distinguishes this
/// from `innermostOfKind`: a node merely on the chain touches `start`, which is
/// not the same as covering the whole range.
pub fn innermostCovering(
    doc: *const Document,
    chain: []const AST.Node.Id,
    tags: []const KindTag,
    start: usize,
    end: usize,
) ?AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const node = doc.ast.nodes[chain[i]];
        const tag = std.meta.activeTag(node.kind);
        const sp = doc.span(chain[i]);
        for (tags) |want| {
            if (tag == want and sp.start <= start and sp.end >= end) return chain[i];
        }
    }
    return null;
}

// ── Line scanning ──────────────────────────────────────────────────────────
// A block container prefixes every LINE it covers, so its gestures work in
// lines rather than spans. Pure byte scanning over the source.

/// The start of the line `at` sits on.
pub fn lineStartAt(src: []const u8, at: usize) usize {
    var i = @min(at, src.len);
    while (i > 0 and src[i - 1] != '\n') i -= 1;
    return i;
}

/// One past the newline terminating the line `at` sits on (or `src.len` at an
/// unterminated last line).
pub fn lineEndAt(src: []const u8, at: usize) usize {
    var i = @min(at, src.len);
    while (i < src.len and src[i] != '\n') i += 1;
    return if (i < src.len) i + 1 else i;
}

/// `line` without its trailing `\r\n` / `\n`.
pub fn lineBody(line: []const u8) []const u8 {
    var e = line.len;
    if (e > 0 and line[e - 1] == '\n') e -= 1;
    if (e > 0 and line[e - 1] == '\r') e -= 1;
    return line[0..e];
}

/// Only spaces/tabs (or nothing) — a line that separates blocks.
pub fn isBlankLine(body: []const u8) bool {
    for (body) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

test "spanContains treats an unset span as containing nothing" {
    try std.testing.expect(!spanContains(Span.init(0, 0), 0, 10));
    try std.testing.expect(spanContains(Span.init(0, 5), 0, 10));
    try std.testing.expect(!spanContains(Span.init(0, 5), 5, 10));
    // A whole-source end position reads as inside the node that reaches the end.
    try std.testing.expect(spanContains(Span.init(5, 10), 10, 10));
    try std.testing.expect(!spanContains(Span.init(0, 5), 10, 10));
}

test "line scanning" {
    const src = "ab\ncd\n\nef";
    try std.testing.expectEqual(@as(usize, 0), lineStartAt(src, 1));
    try std.testing.expectEqual(@as(usize, 3), lineStartAt(src, 4));
    try std.testing.expectEqual(@as(usize, 3), lineEndAt(src, 1));
    try std.testing.expectEqual(@as(usize, 9), lineEndAt(src, 7));
    try std.testing.expectEqualStrings("ab", lineBody("ab\n"));
    try std.testing.expectEqualStrings("ab", lineBody("ab\r\n"));
    try std.testing.expectEqualStrings("ab", lineBody("ab"));
    try std.testing.expect(isBlankLine(""));
    try std.testing.expect(isBlankLine("  \t"));
    try std.testing.expect(!isBlankLine(" x"));
}

test "deepestContaining descends to the innermost node and chains to it" {
    const Xml = @import("../languages/xml/xml.zig");
    const gpa = std.testing.allocator;
    const src = "<r><a>hi</a></r>";
    var ast = try Xml.parse(gpa, src);
    defer ast.deinit();

    // The offset of `hi` lands inside <a>, which is deeper than <r>.
    const at = std.mem.indexOf(u8, src, "hi").?;
    const deep = deepestContaining(&ast, at).?;

    var chain: std.ArrayList(AST.Node.Id) = .empty;
    defer chain.deinit(gpa);
    try ancestorChain(gpa, &ast, at, &chain);

    // The chain ends at the deepest node and starts at the root.
    try std.testing.expectEqual(deep, chain.items[chain.items.len - 1]);
    try std.testing.expectEqual(ast.ast.root, chain.items[0]);
    try std.testing.expect(chain.items.len >= 2);
}

// ── Caret / prefix tests ───────────────────────────────────────────────────
// Every one of these runs BOTH authorable formats over the same source and
// asserts the same answer. That is the whole point of the two entry points: the
// spans underneath genuinely differ (djot ends a block after its newline,
// Markdown before it), and a consumer must not be able to tell which parser
// produced the tree it is holding.

const Markdown = @import("../languages/markdown/markdown.zig");
const Djot = @import("../languages/djot/djot.zig");

/// Parse `src` as both authorable formats and hand each `Document` to `check`.
fn forBothFormats(src: []const u8, check: fn (doc: *const Document, src: []const u8) anyerror!void) !void {
    const gpa = std.testing.allocator;

    var md = try Markdown.parse(gpa, src, .{});
    defer md.deinit();
    const md_doc = md.document();
    check(&md_doc, src) catch |e| {
        std.debug.print("  (markdown)\n", .{});
        return e;
    };

    var dj = try Djot.parse(gpa, src);
    defer dj.deinit();
    const dj_doc = dj.document();
    check(&dj_doc, src) catch |e| {
        std.debug.print("  (djot)\n", .{});
        return e;
    };
}

fn kindAt(doc: *const Document, offset: usize) ?AST.Node.Kind {
    const id = deepestContainingForCaret(doc, offset) orelse return null;
    return doc.ast.nodes[id].kind;
}

test "caret: a block's end is inside it, and a blank line between blocks is not" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            _ = src;
            // "a\n\nb\n" — offsets: 0 'a', 1 '\n', 2 '\n' (the blank line),
            // 3 'b', 4 '\n', 5 end-of-source.
            //
            // Half-open containment put 1 and 4 — the end of each paragraph,
            // and the commonest caret position there is — outside every block
            // in Markdown while djot reported the paragraph. Both now agree.
            try std.testing.expect(kindAt(doc, 0).? == .str);
            try std.testing.expect(kindAt(doc, 1).? == .str);
            try std.testing.expect(kindAt(doc, 3).? == .str);
            try std.testing.expect(kindAt(doc, 4).? == .str);
            // The blank line separating them belongs to no block, and neither
            // does the empty line after the final newline.
            try std.testing.expect(kindAt(doc, 2).? == .doc);
            try std.testing.expect(kindAt(doc, 5).? == .doc);
        }
    };
    try forBothFormats("a\n\nb\n", S.check);
}

test "caret: the chain from a caret at a paragraph's end reaches the paragraph" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            var chain: std.ArrayList(AST.Node.Id) = .empty;
            defer chain.deinit(std.testing.allocator);
            try caretChain(std.testing.allocator, doc, src.len - 1, &chain);

            var saw_para = false;
            var saw_item = false;
            for (chain.items) |id| {
                switch (std.meta.activeTag(doc.ast.nodes[id].kind)) {
                    .para => saw_para = true,
                    .list_item => saw_item = true,
                    else => {},
                }
            }
            try std.testing.expect(saw_para);
            try std.testing.expect(saw_item);
        }
    };
    // The caret sits after `b`, at the end of the nested item — the position
    // Enter and Backspace are pressed from.
    try forBothFormats("- a\n  - b\n", S.check);
}

test "linePrefixSpan: a nested item's prefix includes the indent it sits behind" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            // Caret in `b`, on the inner item's line. That item's own marker is
            // `- `, but the two spaces before it are hidden width too — they
            // are the OUTER item's content indent, which no node records as a
            // marker of its own. Reaching back to the line start is what picks
            // them up.
            const at = std.mem.indexOfScalar(u8, src, 'b').?;
            try std.testing.expectEqualStrings("  - ", linePrefixText(doc, at).?);
            // The outer item's own line is indent-free.
            const a = std.mem.indexOfScalar(u8, src, 'a').?;
            try std.testing.expectEqualStrings("- ", linePrefixText(doc, a).?);
        }
    };
    // Blank-line separated on purpose: `- a\n  - b` is a NESTED LIST in
    // Markdown and a paragraph holding the literal text `- b` in djot, because
    // djot does not let a list marker interrupt a paragraph. Sharing a source
    // whose STRUCTURE differs would be testing the parsers, not this walk — the
    // divergence has its own test below.
    try forBothFormats("- a\n\n  - b\n", S.check);
}

test "linePrefixSpan: no marker where the format read no item" {
    // The same bytes, the two formats genuinely disagreeing. In Markdown line
    // two opens a nested item and has a marker; in djot it is literal text
    // inside item `a`'s paragraph, and there is nothing hidden on it at all.
    //
    // Reporting `  - ` for djot here is exactly the bug this table exists to
    // stop: an editor that "outdents" that line restructures a document that
    // never had a nested item in it.
    const gpa = std.testing.allocator;
    const src = "- a\n  - b\n";

    var md = try Markdown.parse(gpa, src, .{});
    defer md.deinit();
    const md_doc = md.document();
    try std.testing.expectEqualStrings("  - ", linePrefixText(&md_doc, src.len - 2).?);

    var dj = try Djot.parse(gpa, src);
    defer dj.deinit();
    const dj_doc = dj.document();
    try std.testing.expect(linePrefixText(&dj_doc, src.len - 2) == null);
}

test "linePrefixSpan: every marker on the line, from quote to checkbox" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            const at = std.mem.indexOfScalar(u8, src, 'x').?;
            try std.testing.expectEqualStrings("> - [ ] ", linePrefixText(doc, at).?);
        }
    };
    try forBothFormats("> - [ ] x\n", S.check);
}

test "linePrefixSpan: a heading's marker, and none on a continuation line" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            try std.testing.expectEqualStrings("## ", linePrefixText(doc, 4).?);
            // Line three continues the quote but OPENS nothing, so there is no
            // marker to report. What a continuation line repeats is a separate
            // question — see `linePrefixSpan`'s doc comment.
            const at = std.mem.indexOfScalar(u8, src, 'd').?;
            try std.testing.expect(linePrefixText(doc, at) == null);
        }
    };
    try forBothFormats("## h\n\n> c\n> d\n", S.check);
}

/// `continuationPrefix` as an owned string, for the tests below.
fn contPrefix(doc: *const Document, offset: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    const cols = try continuationPrefix(std.testing.allocator, doc, offset, &out);
    // Every prefix these tests build is space/`>`-only, so columns and bytes
    // agree; a tab case asserts the divergence separately.
    try std.testing.expectEqual(out.items.len, cols);
    return out.toOwnedSlice(std.testing.allocator);
}

test "continuationPrefix: a quote repeats its marker, an item indents past it" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            const at = std.mem.indexOfScalar(u8, src, 'a').?;
            const p = try contPrefix(doc, at);
            defer std.testing.allocator.free(p);
            // The quote's `> ` REPRODUCED (dropping it would end the quote) and
            // the item's `- ` as WIDTH (repeating it would open a second item).
            try std.testing.expectEqualStrings(">   ", p);
        }
    };
    try forBothFormats("> - a\n", S.check);
}

test "continuationPrefix: nesting accumulates across different lines" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            const at = std.mem.indexOfScalar(u8, src, 'b').?;
            const p = try contPrefix(doc, at);
            defer std.testing.allocator.free(p);
            // The outer item's marker is on line one and the inner item's on
            // line two — two different lines, which is why this walks the tree
            // rather than reading the caret's own line.
            try std.testing.expectEqualStrings("    ", p);
        }
    };
    try forBothFormats("- a\n\n  - b\n", S.check);
}

test "continuationPrefix: an ordered marker's own width, not a fixed indent" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            const at = std.mem.indexOfScalar(u8, src, 'x').?;
            const p = try contPrefix(doc, at);
            defer std.testing.allocator.free(p);
            // `10. ` is four columns where `1. ` is three. A fixed indent is
            // the assumption that makes Tab wrong on the tenth item.
            try std.testing.expectEqualStrings("    ", p);
        }
    };
    try forBothFormats("10. x\n", S.check);
}

test "continuationPrefix: a continuation line answers for the line it is on" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            // The caret is on line two, which OPENS nothing — the case
            // `linePrefixSpan` declines. Each ancestor still answers from its
            // own opening line, so the quote's marker is found on line one.
            const at = std.mem.indexOfScalar(u8, src, 'd').?;
            try std.testing.expect(linePrefixText(doc, at) == null);
            const p = try contPrefix(doc, at);
            defer std.testing.allocator.free(p);
            try std.testing.expectEqualStrings("> ", p);
        }
    };
    try forBothFormats("> c\n> d\n", S.check);
}

test "continuationPrefix: nothing at the top level" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            const p = try contPrefix(doc, src.len - 1);
            defer std.testing.allocator.free(p);
            try std.testing.expectEqualStrings("", p);
        }
    };
    try forBothFormats("plain\n", S.check);
}

test "blankLinePrefix: a quote keeps its marker, an item keeps nothing" {
    const S = struct {
        fn check(doc: *const Document, src: []const u8) anyerror!void {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(std.testing.allocator);
            const at = std.mem.indexOfScalar(u8, src, 'a').?;
            const cols = try blankLinePrefix(std.testing.allocator, doc, at, &out);
            // `>` and not `> `: the space after the marker is content indent,
            // and a blank line has no content. The item's indent goes entirely.
            try std.testing.expectEqualStrings(">", out.items);
            try std.testing.expectEqual(@as(usize, 1), cols);
        }
    };
    try forBothFormats("> - a\n", S.check);
}

test "continuationPrefix: a tab in a marker advances to a tab stop" {
    // Columns and bytes diverge here, which is why the width is returned rather
    // than left to the caller to take as `prefix.len`.
    const gpa = std.testing.allocator;
    var md = try Markdown.parse(gpa, "-\tx\n", .{});
    defer md.deinit();
    const doc = md.document();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const at = std.mem.indexOfScalar(u8, doc.source, 'x').?;
    const cols = try continuationPrefix(gpa, &doc, at, &out);
    // `-` then a tab to column 4, so the content sits at column 4 and a
    // continuation line needs four columns of indent — not the two bytes a
    // naive `marker.len` would report.
    try std.testing.expectEqual(@as(usize, 4), cols);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
}

test "an offset past every span resolves to nothing" {
    const Xml = @import("../languages/xml/xml.zig");
    const gpa = std.testing.allocator;
    var ast = try Xml.parse(gpa, "<r/>");
    defer ast.deinit();
    // Well past the source: no node can cover it.
    try std.testing.expect(deepestContaining(&ast, 999) == null);
}
