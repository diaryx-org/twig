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
pub fn childContaining(ast: *const AST, id: AST.Node.Id, offset: usize, source_len: usize) ?AST.Node.Id {
    var found: ?AST.Node.Id = null;
    var it = ast.children(id);
    while (it.next()) |child| {
        if (spanContains(child.span, offset, source_len)) found = child.id;
    }
    return found;
}

/// The deepest node containing `offset`, descending from the root. The root's
/// own span may be unset `(0,0)` (some parsers don't span the `doc` node); when
/// so, entry is the root's child that owns the offset, and descent continues
/// fully from there. `null` if no node covers the offset at all.
pub fn deepestContaining(ast: *const AST, offset: usize, source_len: usize) ?AST.Node.Id {
    var cur = ast.root;
    if (!spanContains(ast.nodes[cur].span, offset, source_len)) {
        cur = childContaining(ast, cur, offset, source_len) orelse return null;
    }
    while (childContaining(ast, cur, offset, source_len)) |child| cur = child;
    return cur;
}

/// The chain of node ids from the root down to the deepest node containing
/// `offset` — the ancestor walk the container gestures detect enclosing
/// containers with. Appends to `out`; the caller owns it.
pub fn ancestorChain(
    allocator: Allocator,
    ast: *const AST,
    offset: usize,
    source_len: usize,
    out: *std.ArrayList(AST.Node.Id),
) Allocator.Error!void {
    var cur = ast.root;
    try out.append(allocator, cur);
    while (childContaining(ast, cur, offset, source_len)) |child| {
        cur = child;
        try out.append(allocator, cur);
    }
}

/// The innermost `heading`/`para` on the descent to `offset`, or `null` — the
/// block `Editor.setBlock` rewrites the marker of.
pub fn innermostBlock(ast: *const AST, offset: usize, source_len: usize) ?AST.Node.Id {
    var result: ?AST.Node.Id = null;
    var cur = ast.root;
    while (true) {
        switch (std.meta.activeTag(ast.nodes[cur].kind)) {
            .heading, .para => result = cur,
            else => {},
        }
        cur = childContaining(ast, cur, offset, source_len) orelse break;
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
pub fn innermostOfKind(ast: *const AST, chain: []const AST.Node.Id, tag: KindTag) ?AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        if (std.meta.activeTag(ast.nodes[chain[i]].kind) == tag) return chain[i];
    }
    return null;
}

/// The innermost node on `chain` of any kind in `tags` that wholly contains
/// `[start, end)`, or `null`. The containment test is what distinguishes this
/// from `innermostOfKind`: a node merely on the chain touches `start`, which is
/// not the same as covering the whole range.
pub fn innermostCovering(
    ast: *const AST,
    chain: []const AST.Node.Id,
    tags: []const KindTag,
    start: usize,
    end: usize,
) ?AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const node = ast.nodes[chain[i]];
        const tag = std.meta.activeTag(node.kind);
        for (tags) |want| {
            if (tag == want and node.span.start <= start and node.span.end >= end) return chain[i];
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
    const deep = deepestContaining(&ast, at, src.len).?;

    var chain: std.ArrayList(AST.Node.Id) = .empty;
    defer chain.deinit(gpa);
    try ancestorChain(gpa, &ast, at, src.len, &chain);

    // The chain ends at the deepest node and starts at the root.
    try std.testing.expectEqual(deep, chain.items[chain.items.len - 1]);
    try std.testing.expectEqual(ast.root, chain.items[0]);
    try std.testing.expect(chain.items.len >= 2);
}

test "an offset past every span resolves to nothing" {
    const Xml = @import("../languages/xml/xml.zig");
    const gpa = std.testing.allocator;
    var ast = try Xml.parse(gpa, "<r/>");
    defer ast.deinit();
    // Well past the source: no node can cover it.
    try std.testing.expect(deepestContaining(&ast, 999, 4) == null);
}
