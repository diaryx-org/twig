//! Navigation helpers — the read-path surface of `AST` (the mirror of the
//! write path in `builder.zig`). Every public function here is re-exported as
//! an `AST` method from `ast.zig`, and — like `AST` itself — is language-
//! neutral: anything that encodes one language's node taxonomy (e.g. djot's
//! block/inline dichotomy, `Djot.isBlock`/`isInline`) belongs in that
//! language's module instead. Mirrors fig's `src/ast/reader.zig`, minus the
//! YAML-specific alias/merge-key resolution (no analogue here).

const std = @import("std");
const AST = @import("ast.zig");
const Node = AST.Node;

/// Iterate a node's children in source order via `first_child`/`next_sibling`.
pub const ChildIterator = struct {
    ast: *const AST,
    next_id: ?Node.Id,

    pub fn next(self: *ChildIterator) ?*const Node {
        const id = self.next_id orelse return null;
        const node = &self.ast.nodes[id];
        self.next_id = node.next_sibling;
        return node;
    }
};

/// Iterate `id`'s children in source order. Works uniformly for every kind
/// (leaves simply yield an iterator that returns `null` immediately) since
/// `first_child`/`next_sibling` are plain `Node` fields, not folded into the
/// `Kind` payload — see `ast.zig`'s module doc comment.
pub fn children(self: *const AST, id: Node.Id) ChildIterator {
    return .{ .ast = self, .next_id = self.nodes[id].first_child };
}

/// One row yielded by `tableRows`, with `head` lifted off the `Kind.Row`
/// payload so a caller never has to re-open the union to ask the only question
/// it wants answered.
pub const TableRow = struct {
    /// The row node, spelled as a field rather than reached through `node` so a
    /// call site reads exactly as it did under `ChildIterator`.
    id: Node.Id,
    node: *const Node,
    /// True for a header row — `Kind.Row.head`.
    head: bool,
};

/// Iterate a `table`'s ROW children, skipping everything else it may hold.
///
/// This exists because "a table's children are `[caption?, column*, row*]`, and
/// only a `row` carries `head`" is a fact three serializers and the table editor
/// each used to rediscover on their own — and two of them got it wrong the same
/// way, filtering out the `caption` by name and then reading `kind.row.head` off
/// whatever else turned up. That was harmless only while `caption` was the sole
/// non-row child; adding `Kind.column` (which every reStructuredText table has)
/// turned it into a crash in one serializer and a spurious empty row in another.
/// One iterator that yields rows and nothing else is what stops the next child
/// kind from doing it again.
pub const TableRowIterator = struct {
    inner: ChildIterator,

    pub fn next(self: *TableRowIterator) ?TableRow {
        while (self.inner.next()) |node| switch (node.kind) {
            .row => |r| return .{ .id = node.id, .node = node, .head = r.head },
            else => {},
        };
        return null;
    }
};

/// Iterate `table`'s rows in source order. `table` need not actually be a
/// `table` node — the filter is on the CHILDREN's kind — which keeps this
/// usable on a subtree whose root a caller has not yet classified.
pub fn tableRows(self: *const AST, table: Node.Id) TableRowIterator {
    return .{ .inner = children(self, table) };
}

/// The `Attrs` attached to `id`, or the empty value if it has none.
pub fn attrsOf(self: *const AST, id: Node.Id) AST.Attrs {
    const idx = self.nodes[id].attrs orelse return .{};
    return self.attrs[idx];
}

/// Error from index-path navigation (`getIdByPath`/`getNodeByPath`).
pub const PathError = error{
    /// A path segment asked for a child index the node doesn't have — either
    /// the node has fewer children than the index, or none at all (a leaf).
    PathOutOfBounds,
};

/// Navigate from the root to a node by a pure *index path*: `path[i]` selects
/// the `path[i]`-th child (0-based, source order) of the node reached so far.
/// An empty path returns the root. This is the document analogue of fig's
/// `getIdByPath`, but with only an index segment — documents have no keys to
/// address by (see `editor.zig`). The returned id is valid only against the
/// `AST` it was resolved from; after an edit + reparse, paths must be
/// recomputed against the new tree.
pub fn getIdByPath(self: *const AST, path: []const usize) PathError!Node.Id {
    var id = self.root;
    for (path) |idx| {
        var child = self.nodes[id].first_child orelse return error.PathOutOfBounds;
        var i: usize = 0;
        while (i < idx) : (i += 1) {
            child = self.nodes[child].next_sibling orelse return error.PathOutOfBounds;
        }
        id = child;
    }
    return id;
}

/// Like `getIdByPath`, but returns a pointer to the node itself.
pub fn getNodeByPath(self: *const AST, path: []const usize) PathError!*const Node {
    return &self.nodes[try getIdByPath(self, path)];
}

/// The inverse of `getIdByPath`: the index path from the root to `target`
/// (empty for the root itself), or `null` if `target` isn't in this tree.
/// Caller frees the returned slice. Used to show a selector match's path
/// (bridging content-based addressing back to raw index paths).
pub fn pathOf(self: *const AST, gpa: std.mem.Allocator, target: Node.Id) std.mem.Allocator.Error!?[]usize {
    var acc: std.ArrayList(usize) = .empty;
    errdefer acc.deinit(gpa);
    if (try findPath(self, gpa, self.root, target, &acc)) return try acc.toOwnedSlice(gpa);
    acc.deinit(gpa);
    return null;
}

/// The ids of the subtree rooted at `root`, `root` first — the traversal a
/// caller uses to copy or re-marshal one subtree in isolation (the C ABI's
/// `twig_editor_subtree` re-indexes this into a local id space; a future
/// `twig` selector could reuse it). A breadth-first walk over an explicit
/// worklist, so a deep document can't overflow the stack. Caller frees the
/// slice. Ids are valid only against the `AST` they were read from.
///
/// `root` landing at index 0 is part of the contract: a consumer assigning
/// dense local ids by position (`local[ids[i]] = i`) needs the subtree root to
/// be local id 0 so a walker started there stays inside the subtree.
pub fn subtreeIds(self: *const AST, gpa: std.mem.Allocator, root: Node.Id) std.mem.Allocator.Error![]Node.Id {
    var order: std.ArrayList(Node.Id) = .empty;
    errdefer order.deinit(gpa);
    try order.append(gpa, root);
    var i: usize = 0;
    while (i < order.items.len) : (i += 1) {
        var c = self.nodes[order.items[i]].first_child;
        while (c) |cid| {
            try order.append(gpa, cid);
            c = self.nodes[cid].next_sibling;
        }
    }
    return order.toOwnedSlice(gpa);
}

/// Every node in the arena that hangs off NO parent and is not `root` — the
/// document-level DEFINITIONS, in arena order. Caller frees the slice.
///
/// A parsed document is not one tree. Footnote definitions and link-reference
/// definitions are resolved by LABEL rather than by position, so the parsers
/// attach them to nothing and leave them in the arena as extra roots (see
/// `languages/markdown/block.zig`'s `finish`). A walk from `root` therefore
/// does not reach them, and a consumer that wants them has no choice but to
/// scan the whole arena for parentless nodes — which is what this is, done
/// once and named, rather than re-derived by every caller.
///
/// Deliberately not filtered to a kind list. What ends up detached is a
/// property of how a format resolves its definitions, not of the kind: djot
/// and Markdown put `footnote` and `reference` here, rST adds `citation` and
/// `substitution`, and a format that resolves something else this way should
/// not need this function edited.
pub fn definitionRoots(self: *const AST, gpa: std.mem.Allocator) std.mem.Allocator.Error![]Node.Id {
    // One linear pass to mark every node that is somebody's child; whatever is
    // left unmarked has no parent. Cheaper than asking `pathOf` per node, and
    // it does not care whether the arena is compacted.
    const parented = try gpa.alloc(bool, self.nodes.len);
    defer gpa.free(parented);
    @memset(parented, false);
    for (self.nodes) |node| {
        var c = node.first_child;
        while (c) |cid| {
            parented[cid] = true;
            c = self.nodes[cid].next_sibling;
        }
    }

    var out: std.ArrayList(Node.Id) = .empty;
    errdefer out.deinit(gpa);
    for (parented, 0..) |has_parent, i| {
        const id: Node.Id = @intCast(i);
        if (has_parent or id == self.root) continue;
        try out.append(gpa, id);
    }
    return out.toOwnedSlice(gpa);
}

fn findPath(self: *const AST, gpa: std.mem.Allocator, id: Node.Id, target: Node.Id, acc: *std.ArrayList(usize)) std.mem.Allocator.Error!bool {
    if (id == target) return true;
    var idx: usize = 0;
    var c = self.nodes[id].first_child;
    while (c) |cid| {
        try acc.append(gpa, idx);
        if (try findPath(self, gpa, cid, target, acc)) return true;
        _ = acc.pop();
        c = self.nodes[cid].next_sibling;
        idx += 1;
    }
    return false;
}

test "subtreeIds returns the root first, then every descendant" {
    const testing = std.testing;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    // doc → [ para(a, b), heading(c) ] — subtree of `para` is {para, a, b}, and
    // the subtree of `doc` is the whole tree.
    const a = try b.addLeaf(.{ .str = "a" });
    const bb = try b.addLeaf(.{ .str = "b" });
    const para = try b.addContainer(.para, &.{ a, bb });
    const c = try b.addLeaf(.{ .str = "c" });
    const heading = try b.addContainer(.{ .heading = .{ .level = 1 } }, &.{c});
    const doc = try b.addContainer(.doc, &.{ para, heading });

    var ast = try b.finish(doc);
    defer ast.deinit();

    // A container subtree: root first, then its children. Order past the root is
    // unspecified beyond "every descendant once", so compare as a set.
    const sub = try ast.subtreeIds(testing.allocator, para);
    defer testing.allocator.free(sub);
    try testing.expectEqual(para, sub[0]); // root is always index 0
    try testing.expectEqual(@as(usize, 3), sub.len);
    for ([_]AST.Node.Id{ para, a, bb }) |want| {
        try testing.expect(std.mem.indexOfScalar(AST.Node.Id, sub, want) != null);
    }
    // A node outside this subtree is absent.
    try testing.expect(std.mem.indexOfScalar(AST.Node.Id, sub, heading) == null);

    // A leaf's subtree is just itself.
    const leaf = try ast.subtreeIds(testing.allocator, a);
    defer testing.allocator.free(leaf);
    try testing.expectEqualSlices(AST.Node.Id, &.{a}, leaf);

    // The whole tree from the doc root.
    const all = try ast.subtreeIds(testing.allocator, doc);
    defer testing.allocator.free(all);
    try testing.expectEqual(ast.nodes.len, all.len);
}

test "definitionRoots finds the definitions a walk from the root cannot reach" {
    const testing = std.testing;
    const Markdown = @import("../languages/markdown/markdown.zig");

    // Both a footnote definition and a link-reference definition are resolved
    // by LABEL, so neither is anybody's child. A consumer walking from `doc`
    // sees the paragraph and nothing else.
    var doc = try Markdown.parse(testing.allocator, "text[^1] [x][a]\n\n[^1]: note\n\n[a]: /u\n", .{});
    defer doc.deinit();

    const reachable = try doc.ast.subtreeIds(testing.allocator, doc.ast.root);
    defer testing.allocator.free(reachable);

    const roots = try doc.ast.definitionRoots(testing.allocator);
    defer testing.allocator.free(roots);
    try testing.expect(roots.len >= 2);

    var saw_footnote = false;
    var saw_reference = false;
    for (roots) |id| {
        // Every one of them is genuinely unreachable from the document root —
        // which is the property that made a whole-arena rescan the only way to
        // find them.
        try testing.expect(std.mem.indexOfScalar(AST.Node.Id, reachable, id) == null);
        switch (doc.ast.nodes[id].kind) {
            .footnote => saw_footnote = true,
            .reference => saw_reference = true,
            else => {},
        }
    }
    try testing.expect(saw_footnote);
    try testing.expect(saw_reference);

    // The document root is never among them: it has no parent either, and it
    // is the one parentless node that is not a detached definition.
    try testing.expect(std.mem.indexOfScalar(AST.Node.Id, roots, doc.ast.root) == null);
}

test "tableRows yields only rows, skipping a caption and a column axis" {
    const testing = std.testing;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    // The child list that broke two serializers: a caption AND a column run
    // ahead of the rows. A filter that only knows to skip the caption reads the
    // wrong union field on the columns.
    const cap = try b.addContainer(.caption, &.{});
    const c1 = try b.addContainer(.column, &.{});
    const c2 = try b.addContainer(.column, &.{});
    const head = try b.addContainer(.{ .row = .{ .head = true } }, &.{});
    const body = try b.addContainer(.{ .row = .{ .head = false } }, &.{});
    const table = try b.addContainer(.table, &.{ cap, c1, c2, head, body });

    var ast = try b.finish(table);
    defer ast.deinit();

    var it = ast.tableRows(table);
    const first = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(head, first.id);
    try testing.expect(first.head);
    const second = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(body, second.id);
    try testing.expect(!second.head);
    try testing.expectEqual(@as(?AST.TableRow, null), it.next());

    // A table with a column axis and no rows at all yields nothing, rather than
    // falling back to the columns.
    var b2 = AST.Builder.init(testing.allocator);
    defer b2.deinit();
    const only_cols = try b2.addContainer(.table, &.{try b2.addContainer(.column, &.{})});
    var ast2 = try b2.finish(only_cols);
    defer ast2.deinit();
    var it2 = ast2.tableRows(only_cols);
    try testing.expectEqual(@as(?AST.TableRow, null), it2.next());
}

test "children walks first_child/next_sibling in order" {
    const testing = std.testing;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    const a = try b.addLeaf(.{ .str = "a" });
    const c = try b.addLeaf(.{ .str = "b" });
    const para = try b.addContainer(.para, &.{ a, c });

    var ast = try b.finish(para);
    defer ast.deinit();

    var it = ast.children(para);
    const first = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("a", first.kind.str);
    const second = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("b", second.kind.str);
    try testing.expectEqual(@as(?*const AST.Node, null), it.next());
}
