//! Arena compaction — drop the nodes a parse built and then abandoned, so the
//! node arena IS the document rather than the document plus the parser's
//! discarded hypotheses.
//!
//! ── Why this pass exists ───────────────────────────────────────────────────
//! Twig's inline grammars are not decidable left to right. Whether `**` opens
//! strong emphasis depends on what appears later and on the flanking rules
//! around it, so `languages/markdown/inline.zig` (and djot's equivalent) emits
//! each delimiter run as a literal-text `str` up front — the reading that is
//! correct if the run never finds a partner — and, when the run *does* resolve
//! into a mark, builds the mark and leaves those `str`s unreferenced.
//!
//! The result is an arena that records the parser's SEARCH rather than its
//! conclusion, and the abandoned nodes hold surface syntax: parsing `**x**`
//! and `__x__` leaves orphaned `str "**"` and `str "__"` respectively. That is
//! format-specific spelling sitting in a structure whose entire purpose is to
//! be format-generic. Nothing reads those nodes — but they are in `ast.nodes`,
//! and they are visible to any consumer that iterates the arena instead of
//! walking the tree.
//!
//! `AST.eql` is exactly such a consumer, and deliberately so: comparing the
//! arena is what lets it see the unattached definitions a tree walk cannot
//! reach (see its doc comment, and the tests at the foot of this file). This
//! pass is what makes that comparison sound — without it, `**x**` and `__x__`
//! would compare unequal on the strength of two abandoned `str`s.
//!
//! fig needs no such pass: its config grammars are decidable (`{` means a
//! mapping, `- ` means a sequence element), so its parsers never speculate and
//! its arena is already exactly the reachable tree. This file is what buys
//! Twig the same invariant against a harder class of grammar.
//!
//! ── Roots, plural ──────────────────────────────────────────────────────────
//! Reachability from `ast.root` is NOT the liveness rule. A Markdown link
//! reference definition and a djot/Markdown footnote definition are live nodes
//! that are deliberately not attached anywhere in the tree — they are pure
//! side-table entries, resolved by label rather than by position (see
//! `languages/markdown/markdown.zig`'s `Document.link_references`). Sweeping
//! by tree reachability alone would delete every one of them.
//!
//! So `extra_roots` exists, and every caller with a side table must pass its
//! node ids. `run` returns the old→new id `map` precisely so those tables can
//! be repointed afterward; forgetting to apply it leaves a table indexing the
//! wrong nodes, which is why the map is a required return rather than an
//! optional out-parameter.

const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Node = AST.Node;
const Span = @import("../span.zig");
const Document = @import("../document.zig");

/// A compacted parse plus the id remapping that produced it.
pub const Compacted = struct {
    doc: Document,
    /// Indexed by OLD node id: the node's new id, or `null` if it was dropped.
    /// A caller holding node ids across the pass (a language `Document`'s
    /// label -> definition-node tables) must rewrite them through this.
    /// Owned by the caller; free with `freeMap`.
    map: []const ?Node.Id,

    pub fn freeMap(self: Compacted, allocator: Allocator) void {
        allocator.free(self.map);
    }
};

/// Compact `doc`, keeping everything reachable from its root or from any of
/// `extra_roots`, and dropping the rest.
///
/// CONSUMES `doc`: its `nodes` and position tables are freed here and replaced
/// by fresh, tightly-sized ones. `owned_strings` and the `attrs` side-table
/// pass through untouched — a dropped node's string stays in `owned_strings`
/// until `deinit` (it is a few bytes per abandoned delimiter run, and freeing
/// it would mean scanning for aliases), and `Node.attrs` indices stay valid
/// because the attrs table is not renumbered.
///
/// New ids are assigned in PRE-ORDER from the root, so id order is document
/// order — a stronger and more useful invariant than the build order it
/// replaces. `extra_roots` are swept afterward in ascending old-id order, so
/// the result does not depend on a caller's hash-map iteration order.
pub fn run(
    allocator: Allocator,
    doc: Document,
    extra_roots: []const Node.Id,
) Allocator.Error!Compacted {
    const old = doc.ast;
    const n = old.nodes.len;

    const map = try allocator.alloc(?Node.Id, n);
    errdefer allocator.free(map);
    @memset(map, null);

    var nodes = try std.ArrayList(Node).initCapacity(allocator, n);
    errdefer nodes.deinit(allocator);
    var spans = try std.ArrayList(Span).initCapacity(allocator, n);
    errdefer spans.deinit(allocator);
    var content_spans = try std.ArrayList(?Span).initCapacity(allocator, n);
    errdefer content_spans.deinit(allocator);
    var spellings = try std.ArrayList(?Document.Spelling).initCapacity(allocator, n);
    errdefer spellings.deinit(allocator);
    var marker_spans = try std.ArrayList(?Span).initCapacity(allocator, n);
    errdefer marker_spans.deinit(allocator);

    // Two scratch buffers, allocated once and reused for every node visited.
    var stack: std.ArrayList(Node.Id) = .empty;
    defer stack.deinit(allocator);
    var kids: std.ArrayList(Node.Id) = .empty;
    defer kids.deinit(allocator);

    // The tree proper, then each unattached side-table definition. Sorting the
    // extra roots keeps the output canonical no matter what order the caller's
    // map iterated in.
    const sorted_extra = try allocator.dupe(Node.Id, extra_roots);
    defer allocator.free(sorted_extra);
    std.mem.sort(Node.Id, sorted_extra, {}, std.sort.asc(Node.Id));

    try visit(allocator, old, old.root, map, &nodes, &spans, &content_spans, &spellings, &marker_spans, &stack, &kids, doc);
    for (sorted_extra) |r| {
        if (r >= n or map[r] != null) continue;
        try visit(allocator, old, r, map, &nodes, &spans, &content_spans, &spellings, &marker_spans, &stack, &kids, doc);
    }

    // Second pass: every child/sibling link still points into the OLD id space.
    // Both endpoints are guaranteed mapped — a node is only emitted by `visit`,
    // which emits its whole child chain — so the `.?` cannot fire.
    for (nodes.items) |*node| {
        if (node.first_child) |c| node.first_child = map[c].?;
        if (node.next_sibling) |s| node.next_sibling = map[s].?;
    }

    var new_ast = old;
    new_ast.nodes = try nodes.toOwnedSlice(allocator);
    new_ast.root = map[old.root].?;

    allocator.free(old.nodes);
    allocator.free(doc.node_spans);
    allocator.free(doc.node_content_spans);
    allocator.free(doc.node_spelling);
    allocator.free(doc.node_marker_spans);

    return .{
        .doc = .{
            .source = doc.source,
            .ast = new_ast,
            .node_spans = try spans.toOwnedSlice(allocator),
            .node_content_spans = try content_spans.toOwnedSlice(allocator),
            .node_spelling = try spellings.toOwnedSlice(allocator),
            .node_marker_spans = try marker_spans.toOwnedSlice(allocator),
            // Keyed by `Attrs.Id`, not by node id, and the attrs table is not
            // renumbered here (see this function's doc) — so unlike every
            // table above, this one needs no rebuild and is simply carried
            // over. Ownership moves with it; the caller's `doc` is consumed.
            .attrs_spans = doc.attrs_spans,
        },
        .map = map,
    };
}

/// Emit `root`'s subtree in pre-order, assigning new ids as it goes. Children
/// are pushed in reverse so they pop in document order.
fn visit(
    allocator: Allocator,
    old: AST,
    root: Node.Id,
    map: []?Node.Id,
    nodes: *std.ArrayList(Node),
    spans: *std.ArrayList(Span),
    content_spans: *std.ArrayList(?Span),
    spellings: *std.ArrayList(?Document.Spelling),
    marker_spans: *std.ArrayList(?Span),
    stack: *std.ArrayList(Node.Id),
    kids: *std.ArrayList(Node.Id),
    doc: Document,
) Allocator.Error!void {
    stack.clearRetainingCapacity();
    try stack.append(allocator, root);
    while (stack.pop()) |id| {
        // A malformed tree (a cycle, or two parents sharing a child) would
        // otherwise loop or duplicate; skipping an already-emitted id makes
        // this pass total rather than a crash site.
        if (map[id] != null) continue;

        const new_id: Node.Id = @intCast(nodes.items.len);
        map[id] = new_id;
        var node = old.nodes[id];
        node.id = new_id;
        try nodes.append(allocator, node);
        try spans.append(allocator, doc.node_spans[id]);
        try content_spans.append(allocator, doc.node_content_spans[id]);
        try spellings.append(allocator, doc.spelling(id));
        try marker_spans.append(allocator, doc.markerSpan(id));

        // Children must go onto the stack in REVERSE so they pop in document
        // order, and the sibling chain is singly linked — so they are gathered
        // first. `kids` is a caller-owned scratch buffer reused across every
        // node rather than a fresh list per node: allocating per node made
        // compaction cost more in allocator traffic than the whole rest of the
        // parse.
        kids.clearRetainingCapacity();
        var it = old.children(id);
        while (it.next()) |c| try kids.append(allocator, c.id);
        var i = kids.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(allocator, kids.items[i]);
        }
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "drops an unreferenced node and renumbers the survivors" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    const kept = try b.addLeaf(.{ .str = "x" });
    b.setSpan(kept, Span.init(2, 3));
    // An abandoned delimiter run, exactly what the inline parsers leave behind.
    const orphan = try b.addLeaf(.{ .str = "**" });
    b.setSpan(orphan, Span.init(0, 2));
    const para = try b.addContainer(.para, &.{kept});

    const doc = try b.finishDocument("**x", para);
    const c = try run(testing.allocator, doc, &.{});
    defer c.freeMap(testing.allocator);
    var out = c.doc;
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.ast.nodes.len);
    // Pre-order from the root: the paragraph, then its child.
    try testing.expectEqual(@as(Node.Id, 0), out.ast.root);
    try testing.expect(out.ast.nodes[0].kind == .para);
    try testing.expectEqualStrings("x", out.ast.nodes[1].kind.str);
    // Positions travelled with their nodes.
    try testing.expect(out.span(1).eql(Span.init(2, 3)));
    // The map reports both the survivor's new id and the casualty.
    try testing.expectEqual(@as(?Node.Id, 1), c.map[kept]);
    try testing.expectEqual(@as(?Node.Id, null), c.map[orphan]);
}

test "an extra root keeps a node that hangs off no tree" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    const para = try b.addContainer(.para, &.{});
    // A link reference definition: live, but deliberately unattached.
    const def = try b.addLeaf(.{ .reference = .{ .label = "ref", .destination = "/url" } });
    const orphan = try b.addLeaf(.{ .str = "__" });

    const doc = try b.finishDocument("", para);
    const c = try run(testing.allocator, doc, &.{def});
    defer c.freeMap(testing.allocator);
    var out = c.doc;
    defer out.deinit();

    // The definition survived; the abandoned delimiter run did not.
    try testing.expectEqual(@as(usize, 2), out.ast.nodes.len);
    try testing.expectEqual(@as(?Node.Id, null), c.map[orphan]);
    const new_def = c.map[def] orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("ref", out.ast.nodes[new_def].kind.reference.label);
}

test "ids come out in document order, not build order" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    // Built bottom-up, so the leaves get LOWER ids than their parents.
    const a = try b.addLeaf(.{ .str = "a" });
    const c1 = try b.addLeaf(.{ .str = "c" });
    const em = try b.addContainer(.{ .inline_mark = .emph }, &.{c1});
    const para = try b.addContainer(.para, &.{ a, em });
    const root = try b.addContainer(.doc, &.{para});

    const doc = try b.finishDocument("a _c_", root);
    const c = try run(testing.allocator, doc, &.{});
    defer c.freeMap(testing.allocator);
    var out = c.doc;
    defer out.deinit();

    // doc, para, "a", emph, "c" — a pre-order walk of the tree.
    try testing.expectEqual(@as(usize, 5), out.ast.nodes.len);
    try testing.expectEqual(@as(Node.Id, 0), out.ast.root);
    try testing.expect(out.ast.nodes[1].kind == .para);
    try testing.expectEqualStrings("a", out.ast.nodes[2].kind.str);
    try testing.expect(out.ast.nodes[3].kind == .inline_mark);
    try testing.expectEqualStrings("c", out.ast.nodes[4].kind.str);
}

test "compaction preserves meaning" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const t = try b.addLeaf(.{ .str = "x" });
    _ = try b.addLeaf(.{ .str = "**" }); // orphan
    const em = try b.addContainer(.{ .inline_mark = .strong }, &.{t});
    const para = try b.addContainer(.para, &.{em});
    const doc = try b.finishDocument("**x**", para);

    // The same tree, built without the orphan. It goes through the pass too:
    // `AST.eql` compares arenas slot by slot, and only a compacted arena is in
    // the canonical pre-order that makes that comparison meaningful. Both
    // builders here emit bottom-up, so uncompacted they would disagree on ids
    // while agreeing on the document.
    var b2 = AST.Builder.init(testing.allocator);
    defer b2.deinit();
    const t2 = try b2.addLeaf(.{ .str = "x" });
    const em2 = try b2.addContainer(.{ .inline_mark = .strong }, &.{t2});
    const para2 = try b2.addContainer(.para, &.{em2});
    const clean_raw = try b2.finishDocument("**x**", para2);
    const c2 = try run(testing.allocator, clean_raw, &.{});
    defer c2.freeMap(testing.allocator);
    var clean = c2.doc;
    defer clean.deinit();

    const c = try run(testing.allocator, doc, &.{});
    defer c.freeMap(testing.allocator);
    var out = c.doc;
    defer out.deinit();

    try testing.expect(out.ast.eql(clean.ast));
    try testing.expectEqual(clean.ast.nodes.len, out.ast.nodes.len);
}

// ── the invariant, per language ────────────────────────────────────────────

/// Count nodes reachable from `root`, plus any of `extra` not already counted.
fn liveCount(allocator: Allocator, ast: AST, extra: []const Node.Id) !usize {
    const seen = try allocator.alloc(bool, ast.nodes.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var stack: std.ArrayList(Node.Id) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, ast.root);
    for (extra) |e| try stack.append(allocator, e);
    while (stack.pop()) |id| {
        if (seen[id]) continue;
        seen[id] = true;
        var it = ast.children(id);
        while (it.next()) |c| try stack.append(allocator, c.id);
    }
    var n: usize = 0;
    for (seen) |b| {
        if (b) n += 1;
    }
    return n;
}

test "every parser leaves an arena that is exactly the live document" {
    const Markdown = @import("../languages/markdown/markdown.zig");
    const Djot = @import("../languages/djot/djot.zig");
    const Xml = @import("../languages/xml/xml.zig");
    const Html = @import("../languages/html/html.zig");
    const a = testing.allocator;

    // Sources chosen to exercise the speculative paths: emphasis (abandoned
    // delimiter runs), link reference definitions and footnote definitions
    // (live but unattached), and ordinary block structure.
    const md_cases = [_][]const u8{
        "**x**\n",
        "__x__\n",
        "a [b][ref] c\n\n[ref]: /url \"T\"\n",
        "see[^a]\n\n[^a]: note\n",
        "# H\n\n- a\n- b\n\n> q\n\n`c` and *e* and [l](/u)\n",
    };
    for (md_cases) |src| {
        var d = try Markdown.parse(a, src, .{ .footnotes = true, .tables = true });
        defer d.deinit();

        var extra: std.ArrayList(Node.Id) = .empty;
        defer extra.deinit(a);
        var it = d.link_references.valueIterator();
        while (it.next()) |v| try extra.append(a, v.*);
        var fit = d.footnotes.valueIterator();
        while (fit.next()) |v| try extra.append(a, v.*);

        try testing.expectEqual(d.ast.nodes.len, try liveCount(a, d.ast, extra.items));
    }

    {
        var d = try Djot.parse(a, "a _b_ c\n\n[ref]: /u\n\nsee[^a]\n\n[^a]: note\n\n::: note\nx\n:::\n");
        defer d.deinit();

        var extra: std.ArrayList(Node.Id) = .empty;
        defer extra.deinit(a);
        for ([_]*const std.StringHashMapUnmanaged(Node.Id){
            &d.references, &d.auto_references, &d.footnotes,
        }) |t| {
            var it = t.valueIterator();
            while (it.next()) |v| try extra.append(a, v.*);
        }

        try testing.expectEqual(d.ast.nodes.len, try liveCount(a, d.ast, extra.items));
    }

    // XML and HTML never speculated (their grammars are decidable the way
    // fig's are), so this asserts a property they already had rather than one
    // compaction gave them.
    {
        var d = try Xml.parse(a, "<a x=\"1\"><b/>hi<!--c--></a>");
        defer d.deinit();
        try testing.expectEqual(d.ast.nodes.len, try liveCount(a, d.ast, &.{}));
    }
    {
        var d = try Html.parse(a, "<p>a <b>c</b></p><ul><li>x</li></ul>");
        defer d.deinit();
        try testing.expectEqual(d.ast.nodes.len, try liveCount(a, d.ast, &.{}));
    }
}

test "the abandoned spelling is gone from the arena" {
    const Markdown = @import("../languages/markdown/markdown.zig");
    const a = testing.allocator;

    // Before compaction these arenas held orphaned `str "**"` / `str "__"` —
    // format-specific spelling sitting in the format-generic structure. Now
    // the two parses are indistinguishable node for node.
    var s1 = try Markdown.parse(a, "**x**\n", .{});
    defer s1.deinit();
    var s2 = try Markdown.parse(a, "__x__\n", .{});
    defer s2.deinit();

    try testing.expectEqual(s1.ast.nodes.len, s2.ast.nodes.len);
    for (s1.ast.nodes, s2.ast.nodes) |x, y| {
        try testing.expect(x.kind.eql(y.kind));
        try testing.expectEqual(x.id, y.id);
        try testing.expectEqual(x.first_child, y.first_child);
        try testing.expectEqual(x.next_sibling, y.next_sibling);
    }
}

test "eql sees a difference that lives only on an unattached definition" {
    const Djot = @import("../languages/djot/djot.zig");
    const a = testing.allocator;

    // Djot resolves reference labels at RENDER time, so a `link`'s destination
    // lives solely on the `reference` definition — a node attached to no
    // parent. These two documents render to different HTML, and every node
    // reachable from the root is identical between them, so a tree walk calls
    // them equal. Comparing the compacted arena does not.
    var x = try Djot.parse(a, "[a][r]\n\n[r]: /XXX\n");
    defer x.deinit();
    var y = try Djot.parse(a, "[a][r]\n\n[r]: /YYY\n");
    defer y.deinit();

    try testing.expect(!x.ast.eql(y.ast));

    const hx = try Djot.html.renderAlloc(a, &x, .{});
    defer a.free(hx);
    const hy = try Djot.html.renderAlloc(a, &y, .{});
    defer a.free(hy);
    try testing.expect(!std.mem.eql(u8, hx, hy));

    // ...and the same document twice still compares equal, so the check above
    // is not just "unattached nodes always differ".
    var z = try Djot.parse(a, "[a][r]\n\n[r]: /XXX\n");
    defer z.deinit();
    try testing.expect(x.ast.eql(z.ast));
}

test "eql tells a merged cell from a plain one" {
    const Html = @import("../languages/html/html.zig");
    const a = testing.allocator;

    // A cell's grid extent is semantic, not spelling: these two lay out
    // differently, so they are not the same document. That is the whole reason
    // colspan/rowspan live on `Kind.Cell` rather than in a `Document` side
    // table the way a bullet's `-`-vs-`*` does.
    var merged = try Html.parse(a, "<table><tr><td colspan=\"2\">a</td></tr></table>");
    defer merged.deinit();
    var plain = try Html.parse(a, "<table><tr><td>a</td></tr></table>");
    defer plain.deinit();
    try testing.expect(!merged.ast.eql(plain.ast));

    // `rowspan="0"` is not a count, so it does NOT reach the extent — the two
    // trees differ only in the raw attribute `attrsEql` compares.
    var zero = try Html.parse(a, "<table><tr><td rowspan=\"0\">a</td></tr></table>");
    defer zero.deinit();
    try testing.expect(!zero.ast.eql(plain.ast));
    try testing.expect(firstCellKind(zero.ast).eql(firstCellKind(plain.ast)));
}

fn firstCellKind(ast: AST) AST.Node.Kind {
    for (ast.nodes) |n| if (n.kind == .cell) return n.kind;
    unreachable;
}

test "an unused link reference definition is part of the document" {
    const Markdown = @import("../languages/markdown/markdown.zig");
    const a = testing.allocator;

    // Renders identically to plain `hi`, but the definition is real content a
    // lossless converter must carry, and it survives compaction as an extra
    // root. Tree-walk equality could not see it at all.
    var bare = try Markdown.parse(a, "hi\n", .{});
    defer bare.deinit();
    var with_def = try Markdown.parse(a, "hi\n\n[unused]: /x\n", .{});
    defer with_def.deinit();

    try testing.expect(!bare.ast.eql(with_def.ast));
    try testing.expectEqual(bare.ast.nodes.len + 1, with_def.ast.nodes.len);
}
