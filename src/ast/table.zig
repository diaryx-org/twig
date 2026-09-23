//! The node table: a `Document` written down as flat rows, and read back.
//!
//! ── Why a second encoding ──────────────────────────────────────────────────
//! `ast/json.zig` is nested — a node holds its `children` — because a person
//! diffing two parses reads a tree. A parser that lives OUTSIDE this library
//! (`docs/proposals/runtime-languages.md`) does not want to build nested
//! objects, and core does not want to trust a nesting it did not make. So the
//! same information crosses the boundary flat: one row per node, in pre-order,
//! the row index being the node id, each row naming its `parent`. Core
//! rebuilds `first_child`/`next_sibling` from the parents and never takes a
//! sibling link on faith.
//!
//! A row is the node's `kind` (the published name, `Kind.kindName`), its
//! `parent`, every column `Document` carries for it — `span`,
//! `content_span`, `marker_span`, `spelling`, `attrs`, `attrs_span` — and the
//! kind's payload, under exactly the field names `json.writeKindPayload`
//! writes. That switch is the specification of the payload, and
//! `json.readKind` is the same switch read the other way, so a new kind fails
//! both until it is mapped. Optional columns are omitted when absent, and read
//! as absent when omitted or `null`.
//!
//! `labels` is a side table beside the rows: `(registry, label, node)`, for a
//! parser that wants its say on which of two same-labelled definitions wins.
//! Omitted, core rebuilds it with `Document.Labels.index`, which is what a
//! bare `AST` gets everywhere else. The encoder always writes it, because a
//! compiled parser always has an answer.
//!
//! ── The identity ───────────────────────────────────────────────────────────
//! `decode(encode(doc))` is `doc`: an equal tree under `AST.eql`, equal spans
//! under `Document.spansEql`, equal spelling, marker, attrs-span and label
//! columns. The language harness holds every compiled format's samples to
//! that, which is how the compiled formats cross the contract before any
//! runtime one exists.
//!
//! ── What decode checks ─────────────────────────────────────────────────────
//! Everything a table from outside could get wrong that the engine assumes:
//! the rows are pre-order with the root first and a `doc`; a row with no
//! parent past the root is a definition, the only kind the arena keeps
//! detached; every span lies inside the source; a marker sits only on the
//! kinds that carry one; an attrs span only where there are attrs; a label
//! names a definition of its own registry, by that definition's own label.
//! The column rules are `checkColumns`, which the harness runs over every
//! compiled parse too, so a runtime table and a compiled parse are held to one
//! list. A refusal fills a `Problem` naming the row and field.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

const AST = @import("ast.zig");
const Node = AST.Node;
const Document = @import("../document.zig");
const Span = @import("../span.zig");
const json = @import("json.zig");

/// Why a table was refused. `row` is the node id, `null` for a problem with
/// the table as a whole; `field` is the key at fault, empty when none is.
pub const Problem = struct {
    row: ?usize = null,
    field: []const u8 = "",
    what: []const u8 = "",

    pub fn render(self: Problem, w: *Writer) Writer.Error!void {
        if (self.row) |r| try w.print("row {d}: ", .{r});
        if (self.field.len != 0) try w.print("{s}: ", .{self.field});
        try w.writeAll(self.what);
    }
};

pub const Error = error{ InvalidTable, OutOfMemory };

pub const Options = struct {
    /// One row to a line, for a person reading a table as a table. Off, the
    /// whole table is one line — a wire message, where a newline ends it.
    pretty: bool = true,
};

// ── encode ──────────────────────────────────────────────────────────────────

pub fn encode(allocator: Allocator, doc: *const Document, writer: *Writer, options: Options) (Writer.Error || Allocator.Error)!void {
    const row_sep = if (options.pretty) "\n    " else "";
    const nodes = doc.ast.nodes;
    const parents = try allocator.alloc(?Node.Id, nodes.len);
    defer allocator.free(parents);
    @memset(parents, null);
    for (nodes) |n| {
        var c = n.first_child;
        while (c) |id| : (c = nodes[id].next_sibling) parents[id] = n.id;
    }

    try writer.writeAll(if (options.pretty) "{\n  \"nodes\": [" else "{\"nodes\":[");
    for (nodes, 0..) |n, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(row_sep);
        var w: Stringify = .{ .writer = writer };
        try writeRow(&w, doc, n, parents[i]);
    }
    try writer.writeAll(if (options.pretty) "\n  ],\n  \"labels\": [" else "],\"labels\":[");

    // Sorted by node, then registry: the maps iterate in hash order, and a
    // table two runs disagree on is no oracle.
    var labels: std.ArrayList(LabelRow) = .empty;
    defer labels.deinit(allocator);
    var maps = doc.labels;
    for (maps.maps(), [_]Registry{ .reference, .auto_reference, .footnote }) |map, registry| {
        var it = map.iterator();
        while (it.next()) |e| try labels.append(allocator, .{ .registry = registry, .label = e.key_ptr.*, .node = e.value_ptr.* });
    }
    std.mem.sort(LabelRow, labels.items, {}, LabelRow.lessThan);
    for (labels.items, 0..) |l, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(row_sep);
        var w: Stringify = .{ .writer = writer };
        try w.write(.{ .registry = @tagName(l.registry), .label = l.label, .node = l.node });
    }
    if (options.pretty and labels.items.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll(if (options.pretty) "]\n}\n" else "]}");
}

pub fn encodeAlloc(allocator: Allocator, doc: *const Document, options: Options) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    encode(allocator, doc, &out.writer, options) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn writeRow(w: *Stringify, doc: *const Document, n: Node, parent: ?Node.Id) Writer.Error!void {
    const id = n.id;
    try w.beginObject();
    try w.objectField("kind");
    try w.write(n.kind.kindName());
    try w.objectField("parent");
    try w.write(parent);
    try w.objectField("span");
    try writeSpan(w, doc.span(id));
    if (doc.contentSpan(id)) |s| {
        try w.objectField("content_span");
        try writeSpan(w, s);
    }
    if (doc.markerSpan(id)) |s| {
        try w.objectField("marker_span");
        try writeSpan(w, s);
    }
    if (doc.spelling(id)) |sp| {
        try w.objectField("spelling");
        try w.beginObject();
        switch (sp) {
            inline else => |v, tag| {
                try w.objectField(@tagName(tag));
                try w.write(@tagName(v));
            },
        }
        try w.endObject();
    }
    try json.writeKindPayload(w, n.kind);
    const attrs = doc.ast.attrsOf(id);
    if (!attrs.isEmpty()) {
        try w.objectField("attrs");
        try w.beginArray();
        for (attrs.entries) |kv| {
            try w.beginObject();
            try w.objectField("key");
            try w.write(kv.key);
            try w.objectField("value");
            try w.write(kv.value);
            try w.endObject();
        }
        try w.endArray();
        if (doc.attrsSpan(id)) |s| {
            try w.objectField("attrs_span");
            try writeSpan(w, s);
        }
    }
    try w.endObject();
}

/// Which of `Document.Labels`' three maps a label row belongs to.
const Registry = enum { reference, auto_reference, footnote };

const LabelRow = struct {
    registry: Registry,
    label: []const u8,
    node: Node.Id,

    fn lessThan(_: void, a: LabelRow, b: LabelRow) bool {
        if (a.node != b.node) return a.node < b.node;
        return @intFromEnum(a.registry) < @intFromEnum(b.registry);
    }
};

fn writeSpan(w: *Stringify, s: Span) Writer.Error!void {
    try w.beginArray();
    try w.write(s.start);
    try w.write(s.end);
    try w.endArray();
}

// ── decode ──────────────────────────────────────────────────────────────────

/// Read a table from its JSON text into a `Document` over `source`, which is
/// BORROWED as `Document.source` always is. `problem`, when given, says why a
/// table was refused.
pub fn decode(allocator: Allocator, source: []const u8, text: []const u8, problem: ?*Problem) Error!Document {
    var scratch: Problem = .{};
    const p = problem orelse &scratch;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(p, null, "", "not a JSON document"),
    };
    defer parsed.deinit();
    return fromValue(allocator, source, parsed.value, p);
}

/// `decode` over an already-parsed JSON value — the table as it sits inside
/// a wire message.
pub fn fromValue(allocator: Allocator, source: []const u8, value: std.json.Value, problem: ?*Problem) Error!Document {
    var scratch: Problem = .{};
    const p = problem orelse &scratch;
    const top = switch (value) {
        .object => |o| o,
        else => return fail(p, null, "", "a table is an object with a \"nodes\" array"),
    };
    const rows = switch (top.get("nodes") orelse return fail(p, null, "nodes", "missing")) {
        .array => |a| a.items,
        else => return fail(p, null, "nodes", "expected an array"),
    };
    if (rows.len == 0) return fail(p, null, "nodes", "a table has at least its root");
    if (rows.len > std.math.maxInt(Node.Id)) return fail(p, null, "nodes", "too many rows");

    var b = AST.Builder.init(allocator);
    defer b.deinit();

    // Pass one: every node, its payload and its columns. Children wait for
    // pass two, which needs every id to exist.
    const parents = try allocator.alloc(?Node.Id, rows.len);
    defer allocator.free(parents);
    for (rows, 0..) |row_value, i| {
        const row = switch (row_value) {
            .object => |o| o,
            else => return fail(p, i, "", "a row is an object"),
        };
        const name = switch (row.get("kind") orelse return fail(p, i, "kind", "missing")) {
            .string => |s| s,
            else => return fail(p, i, "kind", "expected a published kind name"),
        };
        const ref = AST.KindRef.fromName(name) orelse return fail(p, i, "kind", "not a published kind name");
        var field: json.FieldProblem = .{};
        const kind = json.readKind(ref, row, &field) catch return fail(p, i, field.field, field.what);
        const id = try b.addNode(kind);

        parents[i] = try optIndex(p, i, row, "parent", rows.len);
        b.setSpan(id, try optSpan(p, i, row, "span") orelse return fail(p, i, "span", "missing"));
        if (try optSpan(p, i, row, "content_span")) |s| b.setContentSpan(id, s);
        if (try optSpan(p, i, row, "marker_span")) |s| b.setMarkerSpan(id, s);
        if (try readSpelling(p, i, row)) |sp| b.setSpelling(id, sp);
        try readAttrs(allocator, p, i, row, &b, id);
    }

    try checkOrder(p, &b, parents);

    // Pass two: children, in row order. Pre-order makes row order document
    // order, so this is the order every sibling chain had when it was written.
    const firsts = try allocator.alloc(std.ArrayList(Node.Id), rows.len);
    defer {
        for (firsts) |*l| l.deinit(allocator);
        allocator.free(firsts);
    }
    @memset(firsts, .empty);
    for (parents, 0..) |parent, i| {
        if (parent) |par| try firsts[par].append(allocator, @intCast(i));
    }
    for (firsts, 0..) |list, i| b.setChildren(@intCast(i), list.items);

    var doc = try b.finishDocument(source, 0);
    errdefer doc.deinit();

    doc.labels = switch (top.get("labels") orelse .null) {
        .null => try Document.Labels.index(allocator, &doc.ast),
        .array => |a| try readLabels(allocator, p, &doc.ast, a.items),
        else => return fail(p, null, "labels", "expected an array"),
    };

    try checkColumns(&doc, p);
    return doc;
}

fn fail(p: *Problem, row: ?usize, field: []const u8, what: []const u8) error{InvalidTable} {
    p.* = .{ .row = row, .field = field, .what = what };
    return error.InvalidTable;
}

/// A row index in `field`, or `null` when it is absent or JSON `null`.
fn optIndex(p: *Problem, i: usize, row: std.json.ObjectMap, field: []const u8, len: usize) error{InvalidTable}!?Node.Id {
    const v = row.get(field) orelse return null;
    return switch (v) {
        .null => null,
        .integer => |n| if (n >= 0 and n < len) @intCast(n) else fail(p, i, field, "not a row of this table"),
        else => fail(p, i, field, "expected a row index or null"),
    };
}

fn optSpan(p: *Problem, i: usize, row: std.json.ObjectMap, field: []const u8) error{InvalidTable}!?Span {
    const v = row.get(field) orelse return null;
    const pair = switch (v) {
        .null => return null,
        .array => |a| a.items,
        else => return fail(p, i, field, "expected [start, end]"),
    };
    if (pair.len != 2) return fail(p, i, field, "expected [start, end]");
    var ends: [2]usize = undefined;
    for (pair, &ends) |x, *e| e.* = switch (x) {
        .integer => |n| std.math.cast(usize, n) orelse return fail(p, i, field, "a byte offset is not negative"),
        else => return fail(p, i, field, "expected [start, end]"),
    };
    return Span.init(ends[0], ends[1]);
}

fn readSpelling(p: *Problem, i: usize, row: std.json.ObjectMap) error{InvalidTable}!?Document.Spelling {
    const obj = switch (row.get("spelling") orelse return null) {
        .null => return null,
        .object => |o| o,
        else => return fail(p, i, "spelling", "expected an object of one key"),
    };
    if (obj.count() != 1) return fail(p, i, "spelling", "expected an object of one key");
    const key = obj.keys()[0];
    const name = switch (obj.values()[0]) {
        .string => |s| s,
        else => return fail(p, i, "spelling", "expected a name"),
    };
    inline for (std.meta.fields(Document.Spelling)) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            const v = std.meta.stringToEnum(f.type, name) orelse return fail(p, i, "spelling", "not one of the names this spelling takes");
            return @unionInit(Document.Spelling, f.name, v);
        }
    }
    return fail(p, i, "spelling", "not a spelling");
}

fn readAttrs(allocator: Allocator, p: *Problem, i: usize, row: std.json.ObjectMap, b: *AST.Builder, id: Node.Id) Error!void {
    const items = switch (row.get("attrs") orelse .null) {
        .null => &[_]std.json.Value{},
        .array => |a| a.items,
        else => return fail(p, i, "attrs", "expected an array of {key, value}"),
    };
    const entries = try allocator.alloc(AST.KeyVal, items.len);
    defer allocator.free(entries);
    for (items, entries) |item, *e| {
        const obj = switch (item) {
            .object => |o| o,
            else => return fail(p, i, "attrs", "expected an array of {key, value}"),
        };
        const key = switch (obj.get("key") orelse .null) {
            .string => |s| s,
            else => return fail(p, i, "attrs", "an entry's key is a string"),
        };
        const value: ?[]const u8 = switch (obj.get("value") orelse .null) {
            .null => null,
            .string => |s| s,
            else => return fail(p, i, "attrs", "an entry's value is a string or null"),
        };
        e.* = .{ .key = key, .value = value };
    }
    try b.setAttrs(id, .{ .entries = entries });
    if (try optSpan(p, i, row, "attrs_span")) |s| {
        if (items.len == 0) return fail(p, i, "attrs_span", "a node with no attrs has no attrs span");
        b.setAttrsSpan(id, s);
    }
}

/// Pre-order, checked rather than assumed: every row's parent is on the path
/// from its tree's root to the row before it. A row with no parent past row 0
/// starts a detached tree — a definition, the only kind the arena keeps
/// outside the root's reach (see `ast/compact.zig`) — and every row after it
/// belongs to it or to a later one, which is the order compaction writes.
fn checkOrder(p: *Problem, b: *const AST.Builder, parents: []const ?Node.Id) error{ InvalidTable, OutOfMemory }!void {
    const nodes = b.nodes.items;
    if (parents[0] != null) return fail(p, 0, "parent", "the first row is the root and has no parent");
    if (nodes[0].kind != .doc) return fail(p, 0, "kind", "the root is a doc");
    var path: std.ArrayList(Node.Id) = .empty;
    defer path.deinit(b.allocator);
    try path.append(b.allocator, 0);
    for (parents[1..], 1..) |parent, i| {
        const id: Node.Id = @intCast(i);
        if (parent) |par| {
            while (path.items.len > 0 and path.items[path.items.len - 1] != par) _ = path.pop();
            if (path.items.len == 0) return fail(p, i, "parent", "rows are in pre-order: a parent comes before its children, and a sibling's subtree before the next sibling");
        } else {
            switch (nodes[i].kind) {
                .reference, .footnote, .citation, .substitution => {},
                else => return fail(p, i, "parent", "only a definition stands outside the root's tree"),
            }
            path.clearRetainingCapacity();
        }
        try path.append(b.allocator, id);
    }
}

fn readLabels(allocator: Allocator, p: *Problem, ast: *const AST, items: []const std.json.Value) Error!Document.Labels {
    var labels: Document.Labels = .{};
    errdefer labels.deinit(allocator);
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return fail(p, null, "labels", "expected an array of {registry, label, node}"),
        };
        const registry = switch (obj.get("registry") orelse .null) {
            .string => |s| std.meta.stringToEnum(Registry, s) orelse return fail(p, null, "labels", "registry is reference, auto_reference or footnote"),
            else => return fail(p, null, "labels", "registry is reference, auto_reference or footnote"),
        };
        const node: Node.Id = switch (obj.get("node") orelse .null) {
            .integer => |n| if (n >= 0 and n < ast.nodes.len) @intCast(n) else return fail(p, null, "labels", "node is not a row of this table"),
            else => return fail(p, null, "labels", "node is a row index"),
        };
        // The key is the definition's own label string, which is what
        // `Labels` promises its keys are; the row's copy has to agree.
        const own: []const u8 = switch (ast.nodes[node].kind) {
            .reference => |r| if (registry != .footnote) r.label else return fail(p, node, "labels", "a reference is labelled in the reference registries"),
            .footnote => |f| if (registry == .footnote) f.label else return fail(p, node, "labels", "a footnote is labelled in the footnote registry"),
            else => return fail(p, node, "labels", "only a reference or a footnote is labelled"),
        };
        const label = switch (obj.get("label") orelse .null) {
            .string => |s| s,
            else => return fail(p, node, "labels", "label is a string"),
        };
        if (!std.mem.eql(u8, label, own)) return fail(p, node, "labels", "label differs from the definition's own");
        const map = labels.maps()[@intFromEnum(registry)];
        try map.put(allocator, own, node);
    }
    return labels;
}

// ── the column rules ────────────────────────────────────────────────────────

/// The shape every `Document` the engine receives must have, whoever built
/// it: the side tables are the lengths they promise, every span lies inside
/// the source, a marker sits only where a rich view can hide one, and an attrs
/// span only where there are attrs. `decode` runs it over every table; the
/// language harness runs it over every compiled parse.
pub fn checkColumns(doc: *const Document, problem: ?*Problem) error{InvalidTable}!void {
    var scratch: Problem = .{};
    const p = problem orelse &scratch;
    const n = doc.ast.nodes.len;
    if (doc.node_spans.len != n) return fail(p, null, "span", "one per node");
    if (doc.node_content_spans.len != n) return fail(p, null, "content_span", "one per node");
    if (doc.node_spelling.len > n) return fail(p, null, "spelling", "at most one per node");
    if (doc.node_marker_spans.len > n) return fail(p, null, "marker_span", "at most one per node");
    if (doc.attrs_spans.len > doc.ast.attrs.len) return fail(p, null, "attrs_span", "at most one per attribute set");
    const len = doc.source.len;
    for (doc.node_spans, 0..) |s, i| try checkSpan(p, i, "span", s, len);
    for (doc.node_content_spans, 0..) |maybe, i| if (maybe) |s| try checkSpan(p, i, "content_span", s, len);
    for (doc.node_marker_spans, 0..) |maybe, i| {
        const s = maybe orelse continue;
        try checkSpan(p, i, "marker_span", s, len);
        // A leading marker: a list or task item's, a heading's `#`s, a
        // quote's `>`, an AsciiDoc admonition's label.
        const allowed = switch (doc.ast.nodes[i].kind) {
            .list_item, .task_list_item, .definition_list_item, .heading, .block_quote => true,
            .container => |c| c.form == .block_fenced and doc.containerOrigin(@intCast(i)) == .directive,
            else => false,
        };
        if (!allowed) return fail(p, i, "marker_span", "this kind carries no leading marker");
    }
    for (doc.attrs_spans, 0..) |maybe, ai| {
        const s = maybe orelse continue;
        const owner = for (doc.ast.nodes) |node| {
            if (node.attrs) |held| if (held == ai) break node.id;
        } else return fail(p, null, "attrs_span", "an attrs span with no node holding its attrs");
        try checkSpan(p, owner, "attrs_span", s, len);
    }
}

fn checkSpan(p: *Problem, i: usize, field: []const u8, s: Span, len: usize) error{InvalidTable}!void {
    if (s.start > s.end) return fail(p, i, field, "start is after end");
    if (s.end > len) return fail(p, i, field, "ends past the source");
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Every column `decode(encode(doc))` must give back.
pub fn expectIdentity(allocator: Allocator, doc: *const Document) !void {
    const text = try encodeAlloc(allocator, doc, .{ .pretty = false });
    defer allocator.free(text);
    var problem: Problem = .{};
    var back = decode(allocator, doc.source, text, &problem) catch |err| {
        std.debug.print("\ntable refused: row {?d} {s}: {s}\n", .{ problem.row, problem.field, problem.what });
        return err;
    };
    defer back.deinit();
    try testing.expect(doc.ast.eql(back.ast));
    try testing.expect(doc.spellingEql(back));
    // Per node rather than `spansEql`, which compares attrs spans by
    // `Attrs.Id`: compaction leaves that index as the parser minted it, a
    // table mints it in row order, and only the node it hangs off is a fact.
    for (0..doc.ast.nodes.len) |i| {
        const id: Node.Id = @intCast(i);
        try testing.expectEqual(doc.span(id), back.span(id));
        try testing.expectEqual(doc.contentSpan(id), back.contentSpan(id));
        try testing.expectEqual(doc.markerSpan(id), back.markerSpan(id));
        try testing.expectEqual(doc.attrsSpan(id), back.attrsSpan(id));
    }
    var a = doc.labels;
    var b = back.labels;
    for (a.maps(), b.maps()) |x, y| {
        try testing.expectEqual(x.count(), y.count());
        var it = x.iterator();
        while (it.next()) |e| try testing.expectEqual(e.value_ptr.*, y.get(e.key_ptr.*).?);
    }
    // And the print is stable: the same document writes the same table, and
    // the one-row-a-line print is the same JSON value.
    const again = try encodeAlloc(allocator, &back, .{ .pretty = false });
    defer allocator.free(again);
    try testing.expectEqualStrings(text, again);
    const pretty = try encodeAlloc(allocator, &back, .{});
    defer allocator.free(pretty);
    var reread = try decode(allocator, doc.source, pretty, null);
    defer reread.deinit();
    try testing.expect(doc.ast.eql(reread.ast));
}

test "table: a built document crosses and comes back" {
    const src = "- *a* b";
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const a = try b.addLeaf(.{ .str = "a" });
    b.setSpan(a, Span.init(3, 4));
    const em = try b.addContainer(.{ .inline_mark = .strong }, &.{a});
    b.setSpan(em, Span.init(2, 5));
    b.setContentSpan(em, Span.init(3, 4));
    const t = try b.addLeaf(.{ .str = " b" });
    b.setSpan(t, Span.init(5, 7));
    const para = try b.addContainer(.para, &.{ em, t });
    b.setSpan(para, Span.init(2, 7));
    const item = try b.addContainer(.list_item, &.{para});
    b.setSpan(item, Span.init(0, 7));
    b.setMarkerSpan(item, Span.init(0, 2));
    const list = try b.addContainer(.{ .bullet_list = .{ .tight = true } }, &.{item});
    b.setSpan(list, Span.init(0, 7));
    b.setSpelling(list, .{ .bullet = .dash });
    try b.setAttrs(list, .{ .entries = &.{ .{ .key = "class", .value = "x" }, .{ .key = "hidden", .value = null } } });
    const doc_id = try b.addContainer(.doc, &.{list});
    b.setSpan(doc_id, Span.init(0, 7));
    // The builder minted the root last; a table's root is row 0, so the
    // round-trip goes through a compaction the way every parse does, which
    // consumes what the builder finished.
    var doc = try @import("compact.zig").run(testing.allocator, try b.finishDocument(src, doc_id));
    defer doc.deinit();
    try expectIdentity(testing.allocator, &doc);
}

test "table: every probe document crosses and comes back" {
    // The fidelity probe builds a document around every kind, which makes it
    // the exhaustive case for the payload switch in both directions.
    const diagnostics = @import("../diagnostics.zig");
    for (diagnostics.probes) |probe| {
        var b = AST.Builder.init(testing.allocator);
        defer b.deinit();
        const root = try probe.build(&b);
        const built = try b.finishDocument("", root);
        var doc = try @import("compact.zig").run(testing.allocator, built);
        defer doc.deinit();
        expectIdentity(testing.allocator, &doc) catch |err| {
            std.debug.print("\nprobe {s}\n", .{probe.label});
            return err;
        };
    }
}

fn expectRefused(src: []const u8, text: []const u8, row: ?usize, field: []const u8) !void {
    var problem: Problem = .{};
    try testing.expectError(error.InvalidTable, decode(testing.allocator, src, text, &problem));
    try testing.expectEqual(row, problem.row);
    try testing.expectEqualStrings(field, problem.field);
}

test "table: decode names what it refuses" {
    try expectRefused("", "[", null, "");
    try expectRefused("", "{}", null, "nodes");
    try expectRefused("", "{\"nodes\":[]}", null, "nodes");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"para\",\"span\":[0,0]}]}", 0, "kind");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\"}]}", 0, "span");
    try expectRefused("ab", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,3]}]}", 0, "span");
    try expectRefused("ab", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[2,1]}]}", 0, "span");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"paragraph\",\"parent\":0,\"span\":[0,0]}]}", 1, "kind");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"heading\",\"parent\":0,\"span\":[0,0]}]}", 1, "level");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"para\",\"span\":[0,0]}]}", 1, "parent");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"para\",\"parent\":5,\"span\":[0,0]}]}", 1, "parent");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"para\",\"parent\":0,\"span\":[0,0],\"marker_span\":[0,0]}]}", 1, "marker_span");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0],\"attrs_span\":[0,0]}]}", 0, "attrs_span");
    try expectRefused("", "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,0]},{\"kind\":\"bullet_list\",\"tight\":true,\"parent\":0,\"span\":[0,0],\"spelling\":{\"bullet\":\"tilde\"}}]}", 1, "spelling");
    // Not pre-order: the second paragraph's child is written after it.
    try expectRefused("",
        \\{"nodes":[{"kind":"doc","span":[0,0]},
        \\ {"kind":"para","parent":0,"span":[0,0]},
        \\ {"kind":"para","parent":0,"span":[0,0]},
        \\ {"kind":"str","text":"x","parent":1,"span":[0,0]}]}
    , 3, "parent");
    try expectRefused("",
        \\{"nodes":[{"kind":"doc","span":[0,0]},
        \\ {"kind":"footnote","label":"a","span":[0,0]}],
        \\ "labels":[{"registry":"footnote","label":"b","node":1}]}
    , 1, "labels");
}

test "table: an author may leave out what is absent" {
    // No labels, no optional columns, no parent on the root, defaults taken:
    // the least a runtime parser has to write.
    const src = "x";
    var doc = try decode(testing.allocator, src,
        \\{"nodes":[{"kind":"doc","span":[0,1]},
        \\ {"kind":"line_block","parent":0,"span":[0,1]},
        \\ {"kind":"line","parent":1,"span":[0,1]},
        \\ {"kind":"str","text":"x","parent":2,"span":[0,1]},
        \\ {"kind":"reference","label":"r","destination":"/","span":[0,0]}]}
    , null);
    defer doc.deinit();
    try testing.expectEqual(@as(u32, 0), doc.ast.nodes[2].kind.line.indent);
    // Labels were indexed from the tree, detached definition included.
    try testing.expectEqual(@as(?Node.Id, 4), doc.labels.reference("r"));
}
