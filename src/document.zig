//! Document = a parsed `AST` plus the source it was parsed from and the
//! byte positions tying the two together.
//!
//! ── Why this file exists ───────────────────────────────────────────────────
//! `AST` answers *what a document means*; `Document` answers *where it was
//! written*. Those are different questions, and fusing them (a `span` field on
//! every `Node`) had a specific cost: it made source fidelity visible to every
//! consumer of the tree, so a printer that has no business knowing byte offsets
//! could read them, and no test could assert that two documents in different
//! formats carry the same meaning — because their spans always differ.
//!
//! Splitting them makes the boundary enforceable rather than conventional. A
//! serializer takes `*const AST` and *cannot* reach a span. The edit layer
//! (`ast/splicer.zig`, `ast/editor.zig`, `ast/locate.zig`) takes a
//! `*const Document`, because splicing bytes is exactly the job that needs
//! both halves. And `AST.eql` becomes writable: two parses compare equal when
//! they mean the same thing, with `Document.spansEql` as the separate,
//! opt-in layer for "…and were written the same way".
//!
//! This is fig's `src/document.zig` applied to documents rather than config
//! (see `DESIGN.md`'s "Relationship to `fig`"), including its ownership
//! discipline: `source` is BORROWED, everything else here is owned and freed
//! by `deinit`.
//!
//! ── The criterion for what lives here ──────────────────────────────────────
//! A fact belongs in `Document` iff two documents differing only in that fact
//! render identically. Byte positions pass trivially — they are not rendered
//! at all. A list's bullet character (`-` vs `*`) passes too, and is the next
//! thing scheduled to move. A list's `tight` flag does NOT pass: it elides the
//! `<p>` in `languages/html/serializer.zig`, so it is meaning, and it stays on
//! `Kind`. Apply this test before adding a field here.

const Document = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast/ast.zig");
const Span = @import("span.zig");

/// The bytes this document was parsed from. BORROWED — the caller owns them
/// and must keep them alive for the `Document`'s lifetime. (`AST` itself
/// copies every string it carries, so the `AST` alone never depends on this.)
source: []const u8,

/// The parsed tree. Owned; `deinit` frees it.
ast: AST,

/// Indexed by node id: `node_spans[id]` is the byte range `[start, end)` of
/// the source that produced that node.
///
/// Always exactly `ast.nodes.len` long — every node has a position, even if a
/// parser only knows a degenerate one. A synthesized node (`AST.Builder` with
/// no `setSpan` call) gets `Span.init(0, 0)`, which is the same "unknown"
/// value the old `Node.span` default carried.
node_spans: []const Span,

/// Indexed by node id: the byte range of the node's *interior* — the region an
/// editor may splice, sitting inside the node's own delimiters. For a
/// container this is where its children live (for `<div class=x>abc</div>`,
/// the span of `abc`; for a djot `::: div`, the lines between the fences). A
/// *framed text leaf* carries one too — its payload interior with the
/// delimiters, fences, or markers peeled off: a `code_block`'s / `metadata`'s
/// body between its fences, an inline `verbatim`'s or math node's interior
/// between its `` ` ``/`$`, a `symb`'s name between its colons, a `<…>`
/// autolink's URL, an XML `comment`'s or `cdata`'s text. See
/// `AST.Node.Kind.holdsOpaqueText` for the leaf kinds that can hold interior
/// text.
///
/// `source[content_span]` is the raw source interior and need NOT equal a
/// normalized text field: an `emph`'s interior is the raw bytes between its
/// `*`s, not "rendered" emphasis, and a `code_block`'s interior is the
/// original indented source, whereas its `.text` payload is dedented and
/// newline-normalized — `source[contentSpan] != code_block.text` by design.
/// This is *where the body is*, not *a copy of it*.
///
/// `null` = unknown or not meaningful: a FRAMELESS node whose span already IS
/// its content (a bare `str`; a bare `http://…` GFM autolink); a synthesized
/// node; an EMPTY container or frame with no interior. Parsers should populate
/// it when it is cheap to compute; a parser that leaves it `null` is still
/// correct, just less useful to editors. Because a framed text leaf can carry
/// one, "has a content span" does not imply "accepts child nodes" — see
/// `holdsOpaqueText`.
///
/// `languages/xml/serializer.zig` additionally reads `null` here as the
/// SELF-CLOSING signal (`<video/>` rather than `<video></video>`), which is
/// why that one serializer takes a `*const Document` while every other printer
/// takes a `*const AST`.
node_content_spans: []const ?Span,

pub fn deinit(self: *Document) void {
    const allocator = self.ast.allocator;
    self.ast.deinit();
    allocator.free(self.node_spans);
    allocator.free(self.node_content_spans);
}

/// The source span of `id`. Panics on an out-of-range id, like `ast.nodes[id]`
/// itself — the tables are built together and are always the same length.
pub fn span(self: *const Document, id: AST.Node.Id) Span {
    return self.node_spans[id];
}

/// The interior span of `id`, or `null` when the node is frameless, empty, or
/// synthesized. See `node_content_spans`.
pub fn contentSpan(self: *const Document, id: AST.Node.Id) ?Span {
    return self.node_content_spans[id];
}

/// Iterate `id`'s children — a pass-through to the tree, so a caller holding a
/// `Document` needn't reach through `.ast` for the most common read.
pub fn children(self: *const Document, id: AST.Node.Id) AST.ChildIterator {
    return self.ast.children(id);
}

/// The raw source bytes `id` was parsed from.
pub fn text(self: *const Document, id: AST.Node.Id) []const u8 {
    return Span.of(u8, self.span(id), self.source);
}

/// The raw source bytes of `id`'s interior, or `null` when it has none.
pub fn contentText(self: *const Document, id: AST.Node.Id) ?[]const u8 {
    const cs = self.contentSpan(id) orelse return null;
    return Span.of(u8, cs, self.source);
}

/// Compare two documents' span layers. Separate from `AST.eql` (which ignores
/// positions entirely) so a round-trip test can assert that *where* the nodes
/// sit survived, not just what they mean. Mirrors fig's `commentsEql`/`tagsEql`
/// split.
pub fn spansEql(self: Document, other: Document) bool {
    if (self.node_spans.len != other.node_spans.len) return false;
    for (self.node_spans, other.node_spans) |a, b| {
        if (!a.eql(b)) return false;
    }
    if (self.node_content_spans.len != other.node_content_spans.len) return false;
    for (self.node_content_spans, other.node_content_spans) |a, b| {
        if ((a == null) != (b == null)) return false;
        if (a) |x| if (!x.eql(b.?)) return false;
    }
    return true;
}

test {
    _ = AST;
}

test "accessors read the side-tables and slice the source" {
    const testing = std.testing;
    const src = "<b>hi</b>";

    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const inner = try b.addLeaf(.{ .str = "hi" });
    b.setSpan(inner, Span.init(3, 5));
    const el = try b.addContainer(.{ .container = .{ .name = "b" } }, &.{inner});
    b.setSpan(el, Span.init(0, 9));
    b.setContentSpan(el, Span.init(3, 5));

    var doc = try b.finishDocument(src, el);
    defer doc.deinit();

    try testing.expectEqualStrings("<b>hi</b>", doc.text(el));
    try testing.expectEqualStrings("hi", doc.contentText(el).?);
    try testing.expectEqual(@as(?Span, null), doc.contentSpan(inner));
    try testing.expectEqualStrings("hi", doc.text(inner));
}

test "spansEql is a separate layer from AST.eql" {
    const testing = std.testing;

    // Two builds with identical trees but different positions.
    var b1 = AST.Builder.init(testing.allocator);
    defer b1.deinit();
    const t1 = try b1.addLeaf(.{ .str = "x" });
    b1.setSpan(t1, Span.init(0, 1));
    const p1 = try b1.addContainer(.para, &.{t1});
    var d1 = try b1.finishDocument("x", p1);
    defer d1.deinit();

    var b2 = AST.Builder.init(testing.allocator);
    defer b2.deinit();
    const t2 = try b2.addLeaf(.{ .str = "x" });
    b2.setSpan(t2, Span.init(4, 5));
    const p2 = try b2.addContainer(.para, &.{t2});
    var d2 = try b2.finishDocument("    x", p2);
    defer d2.deinit();

    // Same meaning, different placement — which is exactly the distinction
    // the split exists to make expressible.
    try testing.expect(d1.ast.eql(d2.ast));
    try testing.expect(!d1.spansEql(d2));
}

// ── The payoff ─────────────────────────────────────────────────────────────
// The reason `AST` and `Document` are two types: with positions out of the
// tree, "do these two documents mean the same thing?" becomes a question a
// test can ask. It could not be asked before — every node carried a span, and
// two parses of differently-spelled sources never agree on spans.

test "the same document in two formats has the same AST but different spans" {
    const testing = std.testing;
    const Djot = @import("languages/djot/djot.zig");
    const Markdown = @import("languages/markdown/markdown.zig");

    // Same document, two surfaces: djot spells emphasis with `_`, Markdown
    // with `*`, and Markdown's source carries two extra bytes of indent.
    const dj_src = "a _b_ c\n";
    const md_src = "a *b* c\n";

    var dj = try Djot.parse(testing.allocator, dj_src);
    defer dj.deinit();
    var md = try Markdown.parse(testing.allocator, md_src, .{});
    defer md.deinit();

    const dj_doc = dj.document();
    const md_doc = md.document();

    // Same meaning...
    try testing.expect(dj_doc.ast.eql(md_doc.ast));
    // ...written differently. `spansEql` is the separate layer, so a test can
    // assert either half without the other.
    try testing.expect(!std.mem.eql(u8, dj_doc.source, md_doc.source));
}

test "a spelling difference alone does not change the AST" {
    const testing = std.testing;
    const Markdown = @import("languages/markdown/markdown.zig");

    // `**x**` and `__x__` are the same strong emphasis, spelled two ways.
    var a = try Markdown.parse(testing.allocator, "**x**\n", .{});
    defer a.deinit();
    var b = try Markdown.parse(testing.allocator, "__x__\n", .{});
    defer b.deinit();

    try testing.expect(a.ast.eql(b.ast));
}
