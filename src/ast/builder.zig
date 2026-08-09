//! Builder — bottom-up, allocation-owning construction of an `AST`. Mirrors
//! fig's `src/ast/builder.zig`: this file IS the `Builder` type (re-exported
//! as `AST.Builder`), ids are array indices, siblings link via
//! `next_sibling`, and every string handed to the builder is *copied* into
//! `owned_strings` so a finished `AST` never borrows the caller's buffers.
//!
//! This is the *simple*, batch-children API (give it a kind and an already-
//! built slice of child ids). A source-driven parser typically needs a more
//! incremental, container-stack style of construction instead (open a node
//! before its children exist, attach them one at a time, possibly rewrite
//! its `Kind` once more is known at close time — e.g. a list's `tight` flag).
//! Rather than generalize this API to cover that (and risk making the common
//! case awkward), `languages/djot/parser.zig` manages its own flat node
//! arrays directly during the build and only produces `AST` values at the
//! boundary — the same division of labor fig's `languages/json/parser.zig`
//! uses relative to this file.

const Builder = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Node = AST.Node;
const Span = @import("../span.zig");

allocator: Allocator,
nodes: std.ArrayList(Node) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
attrs: std.ArrayList(AST.Attrs) = .empty,

pub fn init(allocator: Allocator) Builder {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Builder) void {
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    for (self.attrs.items) |a| {
        self.allocator.free(a.entries);
    }
    self.attrs.deinit(self.allocator);
}

/// Add a node with no children (yet) and the given kind, copying any string
/// payload the kind carries into owned storage. Pair with `setChildren` (via
/// `addContainer`, or directly) to give it children afterward.
pub fn addNode(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Id {
    const id: Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = try self.dupeKind(kind),
    });
    return id;
}

/// Add a childless node. An alias for `addNode` — use whichever name reads
/// better at the call site.
pub fn addLeaf(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Id {
    return self.addNode(kind);
}

/// Add a node with the given kind and children (already-built ids, in
/// order). Empty `ids` is fine, yielding a node with no children.
pub fn addContainer(self: *Builder, kind: Node.Kind, ids: []const Node.Id) Allocator.Error!Node.Id {
    const id = try self.addNode(kind);
    self.setChildren(id, ids);
    return id;
}

/// Chain `ids` as `parent`'s children (`parent.first_child = ids[0]`, each
/// linked to the next via `next_sibling`). The ids must already be in
/// `nodes`. Replaces any children `parent` had before.
pub fn setChildren(self: *Builder, parent: Node.Id, ids: []const Node.Id) void {
    self.nodes.items[parent].first_child = if (ids.len == 0) null else ids[0];
    if (ids.len == 0) return;
    for (ids[0 .. ids.len - 1], ids[1..]) |cur, nxt| {
        self.nodes.items[cur].next_sibling = nxt;
    }
    self.nodes.items[ids[ids.len - 1]].next_sibling = null;
}

pub fn setSpan(self: *Builder, id: Node.Id, span: Span) void {
    self.nodes.items[id].span = span;
}

/// Set the interior (between-the-delimiters) span of a container node — see
/// `Node.content_span`'s doc comment for the contract. Left `null` when
/// never called, which is always a correct (if less informative) value.
pub fn setContentSpan(self: *Builder, id: Node.Id, span: Span) void {
    self.nodes.items[id].content_span = span;
}

/// Attach `attrs` to `id` (copying its strings into owned storage),
/// replacing any attributes previously set. Passing an empty `Attrs` clears
/// the attachment (`node.attrs` goes back to `null`) without growing the
/// side-table.
pub fn setAttrs(self: *Builder, id: Node.Id, attrs: AST.Attrs) Allocator.Error!void {
    if (attrs.isEmpty()) {
        self.nodes.items[id].attrs = null;
        return;
    }
    const entries = try self.allocator.alloc(AST.KeyVal, attrs.entries.len);
    errdefer self.allocator.free(entries);
    for (attrs.entries, entries) |src, *dst| {
        dst.* = .{
            .key = try self.dupe(src.key),
            // `null` (a bare attribute, e.g. HTML `disabled`) stays null.
            .value = if (src.value) |v| try self.dupe(v) else null,
        };
    }

    const idx: AST.Attrs.Id = @intCast(self.attrs.items.len);
    try self.attrs.append(self.allocator, .{ .entries = entries });
    self.nodes.items[id].attrs = idx;
}

/// Copy the entire tree of `src` into this builder, shifting every node's
/// `span`/`content_span` right by `offset` source bytes, and return the
/// builder id that now holds `src.root`. Strings and attributes are copied
/// into the builder's owned storage, and the child/sibling linkage is rebuilt
/// against the builder's own ids.
///
/// `offset` is where `src`'s source text sits inside the builder's document,
/// so a subtree parsed from an *extracted slice* — e.g. a Markdown HTML block
/// handed to `languages/html/parser.zig` — ends up addressing the true outer
/// source rather than the slice. Pass `0` when `src` was parsed from the same
/// buffer this builder is spanning.
///
/// The returned id is `src.root` remapped; a caller that wants to drop a
/// synthetic wrapper (an HTML parse's `doc` root) walks its `first_child`
/// chain instead of appending the returned id directly.
pub fn graftAst(self: *Builder, src: *const AST, offset: usize) Allocator.Error!Node.Id {
    // Nodes are cloned in id order, so `src` id `i` lands at `base + i`; every
    // child/sibling reference is therefore just its old id plus `base`.
    const base: Node.Id = @intCast(self.nodes.items.len);
    for (src.nodes) |node| {
        const id = try self.addNode(node.kind);
        const dst = &self.nodes.items[id];
        dst.first_child = if (node.first_child) |c| base + c else null;
        dst.next_sibling = if (node.next_sibling) |s| base + s else null;
        dst.span = .{ .start = node.span.start + offset, .end = node.span.end + offset };
        if (node.content_span) |cs|
            dst.content_span = .{ .start = cs.start + offset, .end = cs.end + offset };
        // `setAttrs` copies the entries' strings; it touches only `attrs`, so
        // the `dst` node pointer stays valid across it.
        if (node.attrs) |ai| try self.setAttrs(id, src.attrs[ai]);
    }
    return base + src.root;
}

/// Freeze the builder into an owned `AST` rooted at `root`. The builder is
/// left empty, so a subsequent `deinit` is harmless.
pub fn finish(self: *Builder, root: Node.Id) Allocator.Error!AST {
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;
    const attrs = try self.attrs.toOwnedSlice(self.allocator);
    self.attrs = .empty;
    return .{
        .allocator = self.allocator,
        .owned_strings = owned_strings,
        .root = root,
        .nodes = nodes,
        .attrs = attrs,
    };
}

/// A non-owning `AST` over the builder's current nodes, rooted at `root`. The
/// returned AST *borrows* the builder's storage (`nodes`, `owned_strings`,
/// `attrs`): it is valid only while the builder lives and stays unmodified, and
/// must NOT be `deinit`ed — the builder owns the memory. Use it to serialize,
/// render, or query an in-progress build without consuming it; use `finish`
/// when you want an owned `AST` instead. Mirrors fig's `Builder.view`.
///
/// `root` must be a valid id (`< nodes.items.len`); callers that accept an id
/// from outside should bounds-check first (the C ABI does).
pub fn view(self: *const Builder, root: Node.Id) AST {
    return .{
        .allocator = self.allocator,
        .owned_strings = self.owned_strings.items,
        .root = root,
        .nodes = self.nodes.items,
        .attrs = self.attrs.items,
    };
}

// ── internals ────────────────────────────────────────────────────────────

/// Take ownership of an already-allocated string. Freed, not leaked, if
/// registration fails.
fn own(self: *Builder, owned: []const u8) Allocator.Error![]const u8 {
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

fn dupe(self: *Builder, s: []const u8) Allocator.Error![]const u8 {
    return self.own(try self.allocator.dupe(u8, s));
}

/// Copy every string payload a `Kind` carries into owned storage, returning
/// the equivalent `Kind` pointing at the copies. Kinds with no string
/// payload (most container kinds) pass through unchanged. This is the single
/// place that needs a new arm whenever `Kind` grows a string-bearing variant.
fn dupeKind(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Kind {
    return switch (kind) {
        .code_block => |v| .{ .code_block = .{
            .lang = if (v.lang) |l| try self.dupe(l) else null,
            .text = try self.dupe(v.text),
        } },
        .raw_block => |v| .{ .raw_block = .{ .format = try self.dupe(v.format), .text = try self.dupe(v.text) } },
        .metadata => |v| .{ .metadata = .{ .lang = try self.dupe(v.lang), .text = try self.dupe(v.text) } },
        .footnote => |v| .{ .footnote = .{ .label = try self.dupe(v.label) } },
        .reference => |v| .{ .reference = .{ .label = try self.dupe(v.label), .destination = try self.dupe(v.destination) } },
        .str => |v| .{ .str = try self.dupe(v) },
        .text_leaf => |v| .{ .text_leaf = .{ .kind = v.kind, .text = try self.dupe(v.text) } },
        .raw_inline => |v| .{ .raw_inline = .{ .format = try self.dupe(v.format), .text = try self.dupe(v.text) } },
        // `smart_punctuation`'s payload is now a bare `SmartPunctuationKind`
        // (no string to copy), so it falls through to `else => kind` below.
        .link => |v| .{ .link = .{
            .destination = if (v.destination) |d| try self.dupe(d) else null,
            .reference = if (v.reference) |r| try self.dupe(r) else null,
        } },
        .image => |v| .{ .image = .{
            .destination = if (v.destination) |d| try self.dupe(d) else null,
            .reference = if (v.reference) |r| try self.dupe(r) else null,
        } },
        .container => |v| .{ .container = .{
            .name = try self.dupe(v.name),
            .form = v.form,
            .argument = if (v.argument) |a| try self.dupe(a) else null,
        } },
        .markup_leaf => |v| .{ .markup_leaf = .{ .kind = v.kind, .text = try self.dupe(v.text) } },
        .processing_instruction => |v| .{ .processing_instruction = .{
            .target = try self.dupe(v.target),
            .data = try self.dupe(v.data),
        } },
        else => kind,
    };
}

test "Builder constructs a small tree bottom-up" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const s1 = try b.addLeaf(.{ .str = "hello " });
    const em_text = try b.addLeaf(.{ .str = "world" });
    const em = try b.addContainer(.{ .inline_mark = .emph }, &.{em_text});
    const para = try b.addContainer(.para, &.{ s1, em });

    var ast = try b.finish(para);
    defer ast.deinit();

    try testing.expectEqual(para, ast.root);
    try testing.expectEqualStrings("hello ", ast.nodes[s1].kind.str);
    try testing.expect(ast.nodes[para].kind == .para);
    try testing.expectEqual(@as(?Node.Id, em), ast.nodes[s1].next_sibling);
}

test "setAttrs copies attribute strings into owned storage" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    var class_buf = [_]u8{ 'w', 'a', 'r', 'n' };
    const id = try b.addLeaf(.{ .str = "x" });
    try b.setAttrs(id, .{ .entries = &.{ .{ .key = "class", .value = class_buf[0..] }, .{ .key = "id", .value = "y" } } });
    class_buf[0] = 'Z'; // mutate the source buffer; the copy must be unaffected

    var ast = try b.finish(id);
    defer ast.deinit();

    const attrs = ast.attrsOf(id);
    try testing.expectEqualStrings("warn", attrs.get("class").?);
    try testing.expectEqualStrings("y", attrs.get("id").?);
}

test "setAttrs keeps a bare (null-value) attribute bare" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const id = try b.addLeaf(.{ .container = .{ .name = "input" } });
    try b.setAttrs(id, .{ .entries = &.{ .{ .key = "disabled", .value = null }, .{ .key = "type", .value = "checkbox" } } });

    var ast = try b.finish(id);
    defer ast.deinit();

    const attrs = ast.attrsOf(id);
    try testing.expectEqual(@as(?[]const u8, null), attrs.find("disabled").?.value);
    try testing.expectEqualStrings("checkbox", attrs.get("type").?);
}

test "dupeKind copies generic-markup string payloads into owned storage" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    // Mutable source buffers: mutating them after `addLeaf` proves the
    // builder copied rather than aliased (same trick as the setAttrs test).
    var name_buf = "svg:rect".*;
    var comment_buf = " todo ".*;
    var doctype_buf = "html".*;
    var target_buf = "xml".*;
    var data_buf = "version=\"1.0\"".*;
    var cdata_buf = "a < b".*;

    const el = try b.addLeaf(.{ .container = .{ .name = name_buf[0..] } });
    const cm = try b.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = comment_buf[0..] } });
    const dt = try b.addLeaf(.{ .markup_leaf = .{ .kind = .doctype, .text = doctype_buf[0..] } });
    const pi = try b.addLeaf(.{ .processing_instruction = .{ .target = target_buf[0..], .data = data_buf[0..] } });
    const cd = try b.addLeaf(.{ .markup_leaf = .{ .kind = .cdata, .text = cdata_buf[0..] } });
    const root = try b.addContainer(.doc, &.{ el, cm, dt, pi, cd });

    name_buf[0] = 'X';
    comment_buf[0] = 'X';
    doctype_buf[0] = 'X';
    target_buf[0] = 'X';
    data_buf[0] = 'X';
    cdata_buf[0] = 'X';

    var ast = try b.finish(root);
    defer ast.deinit();

    try testing.expectEqualStrings("svg:rect", ast.nodes[el].kind.container.name);
    try testing.expectEqualStrings(" todo ", ast.nodes[cm].kind.markup_leaf.text);
    try testing.expectEqualStrings("html", ast.nodes[dt].kind.markup_leaf.text);
    try testing.expectEqualStrings("xml", ast.nodes[pi].kind.processing_instruction.target);
    try testing.expectEqualStrings("version=\"1.0\"", ast.nodes[pi].kind.processing_instruction.data);
    try testing.expectEqualStrings("a < b", ast.nodes[cd].kind.markup_leaf.text);
    // Not aliasing the (now-mutated) inputs also means distinct pointers.
    try testing.expect(ast.nodes[el].kind.container.name.ptr != &name_buf);
}

test "graftAst copies a foreign tree, shifting spans and re-linking children" {
    const testing = std.testing;

    // A donor AST parsed from a slice that sits at offset 100 in some larger
    // document — its spans are slice-relative (0-based).
    var donor = Builder.init(testing.allocator);
    const inner = try donor.addLeaf(.{ .str = "hi" });
    donor.setSpan(inner, Span.init(3, 5));
    const el = try donor.addContainer(.{ .container = .{ .name = "b" } }, &.{inner});
    donor.setSpan(el, Span.init(0, 8));
    try donor.setAttrs(el, .{ .entries = &.{.{ .key = "id", .value = "x" }} });
    var donor_ast = try donor.finish(el);
    defer donor_ast.deinit();

    // Graft it into a host builder as a child of a paragraph, shifted by 100.
    var host = Builder.init(testing.allocator);
    defer host.deinit();
    const grafted = try host.graftAst(&donor_ast, 100);
    const para = try host.addContainer(.para, &.{grafted});

    var ast = try host.finish(para);
    defer ast.deinit();

    // The grafted root is reachable, kept its kind/attrs, and its span shifted.
    const b_el = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("b", ast.nodes[b_el].kind.container.name);
    try testing.expectEqualStrings("x", ast.attrsOf(b_el).get("id").?);
    try testing.expect(ast.nodes[b_el].span.eql(Span.init(100, 108)));
    // Child linkage was rebuilt against host ids, and its span shifted too.
    const str = ast.nodes[b_el].first_child.?;
    try testing.expectEqualStrings("hi", ast.nodes[str].kind.str);
    try testing.expect(ast.nodes[str].span.eql(Span.init(103, 105)));
}

test "view borrows the in-progress build without consuming it" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit(); // `view` does not consume, so the builder must still free.

    const hello = try b.addLeaf(.{ .str = "hi" });
    const para = try b.addContainer(.para, &.{hello});

    // A borrowed view sees the current tree; it must NOT be deinit'd.
    const v = b.view(para);
    try testing.expectEqual(para, v.root);
    try testing.expect(v.nodes[para].kind == .para);
    try testing.expectEqualStrings("hi", v.nodes[hello].kind.str);

    // The builder is still live: we can keep adding, and a fresh view reflects it.
    const world = try b.addLeaf(.{ .str = " world" });
    const doc = try b.addContainer(.doc, &.{ para, world });
    const v2 = b.view(doc);
    try testing.expectEqual(doc, v2.root);
    var it = v2.children(doc);
    try testing.expectEqual(para, it.next().?.id);
    try testing.expectEqual(world, it.next().?.id);
    try testing.expectEqual(@as(?*const Node, null), it.next());
}

test "content_span defaults to null and is set via setContentSpan" {
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const text = try b.addLeaf(.{ .str = "abc" });
    const el = try b.addContainer(.{ .container = .{ .name = "div" } }, &.{text});
    b.setSpan(el, Span.init(0, 24));
    b.setContentSpan(el, Span.init(13, 16));

    var ast = try b.finish(el);
    defer ast.deinit();

    try testing.expectEqual(@as(?Span, null), ast.nodes[text].content_span);
    try testing.expect(ast.nodes[el].content_span.?.eql(Span.init(13, 16)));
}
