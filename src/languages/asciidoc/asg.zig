//! The AsciiDoc TCK's ASG (Abstract Semantic Graph) codec — `decode` turns one
//! expected ASG (`testdata/asciidoc-tck-corpus.json`'s `cases[].asg`, JSON
//! straight from the AsciiDoc Language Working Group's TCK) into twig's shared
//! `Document`; `encode` turns it back. The conformance harness
//! (`conformance.zig`) asserts `encode(decode(x)) == x` (structurally, via
//! `jsonValueEql` — see below for why not byte-for-byte) over the whole vendored
//! corpus, exactly as `languages/rst/doctree.zig` does for docutils' pformat.
//! There is no AsciiDoc parser yet, so this is what earns the harness its keep
//! before one exists: it proves the ASG's shapes have somewhere to live in
//! twig's vocabulary, and tallies how much of it maps to a semantic `Kind`
//! (`Coverage`) versus the `container` escape hatch.
//!
//! ── Why structural comparison, not byte-for-byte ────────────────────────────
//! rST's pformat is a bespoke text grammar with no whitespace freedom, so
//! `doctree.zig` compares bytes. The TCK's ASG is already JSON — a format with
//! no canonical key order or spacing — so pinning this codec's `encode` to the
//! TCK's own pretty-printer choices would be testing a formatting accident, not
//! the tree. `encode` instead writes ASG-shaped JSON (via the same
//! `std.json.Stringify` writer style as `ast/json.zig`), and the harness parses
//! both sides back into `std.json.Value` and compares with `jsonValueEql`,
//! which treats objects as unordered key sets and arrays as ordered.
//!
//! ── Location, and why this codec doesn't dodge it ───────────────────────────
//! `ast/ast.zig`'s rule is "this file holds MEANING, not POSITION" — position
//! belongs in `Document`'s span side-tables. rST never had to populate them
//! (`pformat` carries no positions at all); the ASG carries one on EVERY node,
//! as an inclusive `[{line,col},{line,col}]` pair (1-based). Dropping it would
//! make this codec lossy for no reason, so `decode` converts each location to a
//! byte `Span` against the case's own `.adoc` source (`offsetOfLineCol`) and
//! `encode` converts back (`lineColOfOffset`) — real use of the position half
//! of twig's architecture, not a hack bolted on for this one format.
//!
//! ── What doesn't have a semantic `Kind` yet ─────────────────────────────────
//! Two constructs in the 13-case corpus fall to the generic escape hatch,
//! exactly as `doctree.zig`'s unmapped docutils elements do:
//!   - `sidebar` -> `Kind.container{.name="sidebar"}`, its `form`/`delimiter`
//!     riding in `attrs` (the precedent `doctree.zig`'s `column` comment
//!     documents: un-normalized source values belong in `attrs`, not `Kind`).
//!   - the document's `attributes` dict (`:name: value` entries) -> a
//!     synthetic `Kind.container{.name="document-attributes"}` marker, first
//!     child of `doc` when the key was present in the source (even empty —
//!     `{}`), so its mere presence (not its `Attrs` table, which collapses
//!     empty-vs-absent to the same `null`, see `Builder.setAttrs`) is the
//!     round-trip signal for whether to emit the JSON key at all.
//! Both count `.generic` in `Coverage`, same convention as `doctree.zig`.
//!
//! A document's title (`header.title`) DOES get a semantic `Kind.heading`
//! (`level = 0`, distinguishing it from a real section's `level >= 1`) since
//! that's exactly what it is; only the two constructs above lack one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Document = @import("../../document.zig");
const Span = @import("../../span.zig");

/// Which JSON shape a case's `asg` field holds — the TCK's two test levels.
/// Named to dodge the `inline` keyword, not for any deeper reason.
pub const Root = enum { document, inlines };

/// Vocabulary coverage, tallied by `decode`. Mirrors `doctree.Coverage`'s
/// purpose at 1/500th its vocabulary: `semantic` instances decoded to a kind
/// with real meaning in twig's model, `generic` instances fell to
/// `Kind.container` (see this file's doc comment for which two constructs),
/// and `text_nodes` is `semantic`'s `str` subset, broken out the same way
/// `doctree.Coverage.text_nodes` is.
pub const Coverage = struct {
    semantic: u32 = 0,
    generic: u32 = 0,
    text_nodes: u32 = 0,
};

fn bump(coverage: ?*Coverage, comptime field: []const u8) void {
    if (coverage) |c| @field(c, field) += 1;
}

/// A decode failure: an ASG shape the 13-case corpus doesn't yet exercise
/// (an ordered list, a `span` variant other than `strong`, ...). Surfaced as a
/// normal error rather than `unreachable` so a TCK refresh that adds coverage
/// fails the harness loudly instead of crashing the test binary — the same
/// posture `rst/doctree.zig`'s `DecodeError` takes.
pub const DecodeError = error{UnsupportedAsgNode} || Allocator.Error;

const LineCol = struct { line: u32, col: u32 };

/// Convert a 1-based `(line, col)` to a 0-based byte offset into `source`.
/// `col` counts bytes, matching the corpus (pure ASCII throughout).
fn offsetOfLineCol(source: []const u8, line: u32, col: u32) usize {
    var l: u32 = 1;
    var i: usize = 0;
    while (l < line) : (l += 1) {
        i = (std.mem.indexOfScalarPos(u8, source, i, '\n') orelse unreachable) + 1;
    }
    return i + (col - 1);
}

/// The inverse of `offsetOfLineCol`.
fn lineColOfOffset(source: []const u8, offset: usize) LineCol {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..offset], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(offset - line_start + 1) };
}

/// An ASG `"location": [{line,col},{line,col}]` value, both endpoints
/// inclusive, converted to a half-open byte `Span`.
fn spanFromLoc(source: []const u8, loc: std.json.Value) Span {
    const start = loc.array.items[0].object;
    const end = loc.array.items[1].object;
    const s = offsetOfLineCol(source, @intCast(start.get("line").?.integer), @intCast(start.get("col").?.integer));
    const e = offsetOfLineCol(source, @intCast(end.get("line").?.integer), @intCast(end.get("col").?.integer));
    return Span.init(s, e + 1);
}

fn obj(v: std.json.Value) std.json.ObjectMap {
    return v.object;
}
fn arr(v: std.json.Value) []const std.json.Value {
    return v.array.items;
}
fn str(v: std.json.Value) []const u8 {
    return v.string;
}

// ── decode ──────────────────────────────────────────────────────────────────

/// Decode `value` (a case's `asg` field, shaped by `root`) against its own
/// `.adoc` source into an owned `Document`. `source` is COPIED nowhere further
/// than `Document.source` borrows it — keep it alive as long as the returned
/// `Document`, exactly like every other parser's `Document` contract.
pub fn decode(
    allocator: Allocator,
    source: []const u8,
    root: Root,
    value: std.json.Value,
    coverage: ?*Coverage,
) DecodeError!Document {
    var b = AST.Builder.init(allocator);
    errdefer b.deinit();
    const root_id = switch (root) {
        .document => try decodeDocument(&b, source, value, coverage),
        .inlines => blk: {
            const ids = try decodeInlineList(&b, source, arr(value), coverage);
            defer allocator.free(ids);
            break :blk try b.addContainer(.doc, ids);
        },
    };
    return b.finishDocument(source, root_id);
}

fn decodeDocument(b: *AST.Builder, source: []const u8, value: std.json.Value, coverage: ?*Coverage) DecodeError!Node.Id {
    const o = obj(value);
    var children = std.ArrayList(Node.Id).empty;
    defer children.deinit(b.allocator);

    if (o.get("attributes")) |attrs_val| {
        const marker = try b.addNode(.{ .container = .{ .name = "document-attributes" } });
        var entries = std.ArrayList(AST.KeyVal).empty;
        defer entries.deinit(b.allocator);
        var it = obj(attrs_val).iterator();
        while (it.next()) |e| {
            // A null value is an UNSET attribute (`:!name:`), which is not the
            // same document as `:name:` with an empty value — `Attrs` already
            // draws exactly that distinction, so it carries straight over.
            try entries.append(b.allocator, .{
                .key = e.key_ptr.*,
                .value = switch (e.value_ptr.*) {
                    .null => null,
                    .string => |s| s,
                    else => return error.UnsupportedAsgNode,
                },
            });
        }
        try b.setAttrs(marker, .{ .entries = entries.items });
        bump(coverage, "generic");
        try children.append(b.allocator, marker);
    }

    if (o.get("header")) |header_val| {
        const ho = obj(header_val);
        const title_ids = try decodeInlineList(b, source, arr(ho.get("title").?), coverage);
        defer b.allocator.free(title_ids);
        const heading = try b.addContainer(.{ .heading = .{ .level = 0 } }, title_ids);
        b.setSpan(heading, spanFromLoc(source, ho.get("location").?));
        bump(coverage, "semantic");
        try children.append(b.allocator, heading);
    }

    if (o.get("blocks")) |blocks_val| {
        for (arr(blocks_val)) |block_val| {
            try children.append(b.allocator, try decodeBlock(b, source, block_val, coverage));
        }
    }

    const id = try b.addContainer(.doc, children.items);
    b.setSpan(id, spanFromLoc(source, o.get("location").?));
    bump(coverage, "semantic");
    return id;
}

fn decodeBlock(b: *AST.Builder, source: []const u8, value: std.json.Value, coverage: ?*Coverage) DecodeError!Node.Id {
    const o = obj(value);
    const name = str(o.get("name").?);

    if (std.mem.eql(u8, name, "paragraph")) {
        const inlines = try decodeInlineList(b, source, arr(o.get("inlines").?), coverage);
        defer b.allocator.free(inlines);
        const id = try b.addContainer(.para, inlines);
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        bump(coverage, "semantic");
        return id;
    }

    if (std.mem.eql(u8, name, "list")) {
        if (!std.mem.eql(u8, str(o.get("variant").?), "unordered")) return error.UnsupportedAsgNode;
        var items = std.ArrayList(Node.Id).empty;
        defer items.deinit(b.allocator);
        for (arr(o.get("items").?)) |item| try items.append(b.allocator, try decodeListItem(b, source, item, coverage));
        const id = try b.addContainer(.{ .bullet_list = .{ .tight = true } }, items.items);
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        if (o.get("marker")) |m| b.setSpelling(id, .{ .bullet = try bulletFromMarker(str(m)) });
        bump(coverage, "semantic");
        return id;
    }

    if (std.mem.eql(u8, name, "listing")) {
        // An empty delimited block has NO `inlines` key (the schema's own
        // `defaults` block spells the absent value as `[]`, and the TCK's
        // output files always take the absent spelling). Its content span
        // stays unset, which is what `encode` reads back to decide the same.
        const inlines = if (o.get("inlines")) |v| arr(v) else &[_]std.json.Value{};
        var text = std.ArrayList(u8).empty;
        defer text.deinit(b.allocator);
        var inner: ?Span = null;
        for (inlines) |inl| {
            const io = obj(inl);
            try text.appendSlice(b.allocator, str(io.get("value").?));
            const sp = spanFromLoc(source, io.get("location").?);
            inner = if (inner) |s| Span.init(s.start, sp.end) else sp;
        }
        const id = try b.addLeaf(.{ .code_block = .{ .lang = null, .text = text.items } });
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        if (inner) |sp| b.setContentSpan(id, sp);
        try b.setAttrs(id, .{ .entries = &.{
            .{ .key = "form", .value = str(o.get("form").?) },
            .{ .key = "delimiter", .value = str(o.get("delimiter").?) },
        } });
        bump(coverage, "semantic");
        return id;
    }

    if (std.mem.eql(u8, name, "section")) {
        const level: u32 = @intCast(o.get("level").?.integer);
        const title_ids = try decodeInlineList(b, source, arr(o.get("title").?), coverage);
        defer b.allocator.free(title_ids);
        const heading = try b.addContainer(.{ .heading = .{ .level = level } }, title_ids);
        bump(coverage, "semantic");

        var children = std.ArrayList(Node.Id).empty;
        defer children.deinit(b.allocator);
        try children.append(b.allocator, heading);
        if (o.get("blocks")) |blocks_val| {
            for (arr(blocks_val)) |block_val| {
                try children.append(b.allocator, try decodeBlock(b, source, block_val, coverage));
            }
        }
        const id = try b.addContainer(.section, children.items);
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        bump(coverage, "semantic");
        return id;
    }

    if (std.mem.eql(u8, name, "sidebar")) {
        var children = std.ArrayList(Node.Id).empty;
        defer children.deinit(b.allocator);
        if (o.get("blocks")) |blocks_val| {
            for (arr(blocks_val)) |block_val| {
                try children.append(b.allocator, try decodeBlock(b, source, block_val, coverage));
            }
        }
        const id = try b.addContainer(.{ .container = .{ .name = "sidebar" } }, children.items);
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        try b.setAttrs(id, .{ .entries = &.{
            .{ .key = "form", .value = str(o.get("form").?) },
            .{ .key = "delimiter", .value = str(o.get("delimiter").?) },
        } });
        bump(coverage, "generic");
        return id;
    }

    return error.UnsupportedAsgNode;
}

fn decodeListItem(b: *AST.Builder, source: []const u8, value: std.json.Value, coverage: ?*Coverage) DecodeError!Node.Id {
    const o = obj(value);
    const principal = try decodeInlineList(b, source, arr(o.get("principal").?), coverage);
    defer b.allocator.free(principal);
    const id = try b.addContainer(.list_item, principal);
    b.setSpan(id, spanFromLoc(source, o.get("location").?));
    if (o.get("marker")) |m| b.setSpelling(id, .{ .bullet = try bulletFromMarker(str(m)) });
    bump(coverage, "semantic");
    return id;
}

fn bulletFromMarker(marker: []const u8) DecodeError!Document.Spelling.Bullet {
    if (std.mem.eql(u8, marker, "*")) return .star;
    if (std.mem.eql(u8, marker, "-")) return .dash;
    if (std.mem.eql(u8, marker, "+")) return .plus;
    return error.UnsupportedAsgNode;
}

fn decodeInlineList(b: *AST.Builder, source: []const u8, items: []const std.json.Value, coverage: ?*Coverage) DecodeError![]Node.Id {
    var ids = std.ArrayList(Node.Id).empty;
    errdefer ids.deinit(b.allocator);
    for (items) |item| try ids.append(b.allocator, try decodeInline(b, source, item, coverage));
    return ids.toOwnedSlice(b.allocator);
}

fn decodeInline(b: *AST.Builder, source: []const u8, value: std.json.Value, coverage: ?*Coverage) DecodeError!Node.Id {
    const o = obj(value);
    const name = str(o.get("name").?);

    if (std.mem.eql(u8, name, "text")) {
        const id = try b.addLeaf(.{ .str = str(o.get("value").?) });
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        bump(coverage, "semantic");
        bump(coverage, "text_nodes");
        return id;
    }

    if (std.mem.eql(u8, name, "span")) {
        if (!std.mem.eql(u8, str(o.get("variant").?), "strong")) return error.UnsupportedAsgNode;
        const inlines = try decodeInlineList(b, source, arr(o.get("inlines").?), coverage);
        defer b.allocator.free(inlines);
        const id = try b.addContainer(.{ .inline_mark = .strong }, inlines);
        b.setSpan(id, spanFromLoc(source, o.get("location").?));
        if (o.get("form")) |f| try b.setAttrs(id, .{ .entries = &.{.{ .key = "form", .value = str(f) }} });
        bump(coverage, "semantic");
        return id;
    }

    return error.UnsupportedAsgNode;
}

// ── encode ──────────────────────────────────────────────────────────────────

/// Write `doc` back out as ASG-shaped JSON, `root`-dependent at the top level
/// exactly as `decode` was. This is `decode`'s exact inverse, not a general
/// AST-to-ASG printer — it switches only over the shapes `decode` itself
/// produces (see this file's doc comment), and hitting anything else is a bug
/// in this file rather than a document twig legitimately can't print.
pub fn encode(doc: *const Document, root: Root, writer: *Writer) Writer.Error!void {
    var w: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    switch (root) {
        .document => try writeDocument(&w, doc, doc.ast.root),
        .inlines => {
            try w.beginArray();
            var it = doc.children(doc.ast.root);
            while (it.next()) |c| try writeInline(&w, doc, c.id);
            try w.endArray();
        },
    }
}

pub fn encodeAlloc(allocator: Allocator, doc: *const Document, root: Root) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    encode(doc, root, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn writePoint(w: *std.json.Stringify, source: []const u8, offset: usize) Writer.Error!void {
    const lc = lineColOfOffset(source, offset);
    try w.beginObject();
    try w.objectField("line");
    try w.write(lc.line);
    try w.objectField("col");
    try w.write(lc.col);
    try w.endObject();
}

/// Write `"location": [...]` from `id`'s span, converting the half-open byte
/// `Span` back to the ASG's inclusive `(line, col)` pair.
fn writeLoc(w: *std.json.Stringify, doc: *const Document, id: Node.Id) Writer.Error!void {
    const span = doc.span(id);
    // An EMPTY span has no location to write: the ASG's endpoints are both
    // inclusive, so a zero-width extent cannot be spelled at all. This is the
    // degenerate case only — an empty document, or a document of nothing but
    // blank lines — and `location` is optional throughout the schema, so
    // omitting it is legal rather than a dodge.
    if (span.end <= span.start) return;
    try w.objectField("location");
    try w.beginArray();
    try writePoint(w, doc.source, span.start);
    try writePoint(w, doc.source, span.end - 1);
    try w.endArray();
}

fn attrGet(attrs: AST.Attrs, key: []const u8) ?[]const u8 {
    const kv = attrs.find(key) orelse return null;
    return kv.value;
}

fn bulletMarker(sp: ?Document.Spelling) []const u8 {
    return switch (sp.?.bullet) {
        .dash => "-",
        .plus => "+",
        .star => "*",
    };
}

fn writeDocument(w: *std.json.Stringify, doc: *const Document, id: Node.Id) Writer.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write("document");
    try w.objectField("type");
    try w.write("block");

    var attrs_id: ?Node.Id = null;
    var header_id: ?Node.Id = null;
    var has_body = false;
    {
        var it = doc.children(id);
        while (it.next()) |c| {
            switch (doc.ast.nodes[c.id].kind) {
                .container => |cnt| if (std.mem.eql(u8, cnt.name, "document-attributes")) {
                    attrs_id = c.id;
                    continue;
                },
                .heading => |h| if (h.level == 0) {
                    header_id = c.id;
                    continue;
                },
                else => {},
            }
            has_body = true;
        }
    }

    if (attrs_id) |aid| {
        try w.objectField("attributes");
        try w.beginObject();
        for (doc.ast.attrsOf(aid).entries) |kv| {
            try w.objectField(kv.key);
            try w.write(kv.value); // null — an unset attribute — writes as JSON null
        }
        try w.endObject();
    }

    if (header_id) |hid| {
        try w.objectField("header");
        try w.beginObject();
        try w.objectField("title");
        try w.beginArray();
        var it = doc.children(hid);
        while (it.next()) |c| try writeInline(w, doc, c.id);
        try w.endArray();
        try writeLoc(w, doc, hid);
        try w.endObject();
    }

    if (has_body) {
        try w.objectField("blocks");
        try w.beginArray();
        var it = doc.children(id);
        if (attrs_id != null) _ = it.next();
        if (header_id != null) _ = it.next();
        while (it.next()) |c| try writeBlock(w, doc, c.id);
        try w.endArray();
    }

    try writeLoc(w, doc, id);
    try w.endObject();
}

fn writeBlock(w: *std.json.Stringify, doc: *const Document, id: Node.Id) Writer.Error!void {
    switch (doc.ast.nodes[id].kind) {
        .para => {
            try w.beginObject();
            try w.objectField("name");
            try w.write("paragraph");
            try w.objectField("type");
            try w.write("block");
            try w.objectField("inlines");
            try w.beginArray();
            var it = doc.children(id);
            while (it.next()) |c| try writeInline(w, doc, c.id);
            try w.endArray();
            try writeLoc(w, doc, id);
            try w.endObject();
        },
        .bullet_list => {
            try w.beginObject();
            try w.objectField("name");
            try w.write("list");
            try w.objectField("type");
            try w.write("block");
            try w.objectField("variant");
            try w.write("unordered");
            try w.objectField("marker");
            try w.write(bulletMarker(doc.spelling(id)));
            try w.objectField("items");
            try w.beginArray();
            var it = doc.children(id);
            while (it.next()) |c| try writeListItem(w, doc, c.id);
            try w.endArray();
            try writeLoc(w, doc, id);
            try w.endObject();
        },
        .code_block => |cb| {
            try w.beginObject();
            try w.objectField("name");
            try w.write("listing");
            try w.objectField("type");
            try w.write("block");
            const attrs = doc.ast.attrsOf(id);
            try w.objectField("form");
            try w.write(attrGet(attrs, "form").?);
            try w.objectField("delimiter");
            try w.write(attrGet(attrs, "delimiter").?);
            if (cb.text.len > 0) {
                try w.objectField("inlines");
                try w.beginArray();
                try w.beginObject();
                try w.objectField("type");
                try w.write("string");
                try w.objectField("name");
                try w.write("text");
                try w.objectField("value");
                try w.write(cb.text);
                const cs = doc.contentSpan(id).?;
                try w.objectField("location");
                try w.beginArray();
                try writePoint(w, doc.source, cs.start);
                try writePoint(w, doc.source, cs.end - 1);
                try w.endArray();
                try w.endObject();
                try w.endArray();
            }
            try writeLoc(w, doc, id);
            try w.endObject();
        },
        .section => {
            try w.beginObject();
            try w.objectField("name");
            try w.write("section");
            try w.objectField("type");
            try w.write("block");
            var it = doc.children(id);
            const heading_id = it.next().?.id;
            try w.objectField("title");
            try w.beginArray();
            var hit = doc.children(heading_id);
            while (hit.next()) |c| try writeInline(w, doc, c.id);
            try w.endArray();
            try w.objectField("level");
            try w.write(doc.ast.nodes[heading_id].kind.heading.level);
            try writeLoc(w, doc, id);
            var probe = it;
            if (probe.next() != null) {
                try w.objectField("blocks");
                try w.beginArray();
                while (it.next()) |c| try writeBlock(w, doc, c.id);
                try w.endArray();
            }
            try w.endObject();
        },
        .container => |cnt| {
            try w.beginObject();
            try w.objectField("name");
            try w.write(cnt.name);
            try w.objectField("type");
            try w.write("block");
            const attrs = doc.ast.attrsOf(id);
            try w.objectField("form");
            try w.write(attrGet(attrs, "form").?);
            try w.objectField("delimiter");
            try w.write(attrGet(attrs, "delimiter").?);
            var it = doc.children(id);
            if (doc.ast.nodes[id].first_child != null) {
                try w.objectField("blocks");
                try w.beginArray();
                while (it.next()) |c| try writeBlock(w, doc, c.id);
                try w.endArray();
            }
            try writeLoc(w, doc, id);
            try w.endObject();
        },
        else => unreachable,
    }
}

fn writeListItem(w: *std.json.Stringify, doc: *const Document, id: Node.Id) Writer.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write("listItem");
    try w.objectField("type");
    try w.write("block");
    try w.objectField("marker");
    try w.write(bulletMarker(doc.spelling(id)));
    try w.objectField("principal");
    try w.beginArray();
    var it = doc.children(id);
    while (it.next()) |c| try writeInline(w, doc, c.id);
    try w.endArray();
    try writeLoc(w, doc, id);
    try w.endObject();
}

fn writeInline(w: *std.json.Stringify, doc: *const Document, id: Node.Id) Writer.Error!void {
    switch (doc.ast.nodes[id].kind) {
        .str => |s| {
            try w.beginObject();
            try w.objectField("name");
            try w.write("text");
            try w.objectField("type");
            try w.write("string");
            try w.objectField("value");
            try w.write(s);
            try writeLoc(w, doc, id);
            try w.endObject();
        },
        .inline_mark => |m| {
            try w.beginObject();
            try w.objectField("name");
            try w.write("span");
            try w.objectField("type");
            try w.write("inline");
            try w.objectField("variant");
            try w.write(@tagName(m));
            const attrs = doc.ast.attrsOf(id);
            try w.objectField("form");
            try w.write(attrGet(attrs, "form") orelse "constrained");
            try w.objectField("inlines");
            try w.beginArray();
            var it = doc.children(id);
            while (it.next()) |c| try writeInline(w, doc, c.id);
            try w.endArray();
            try writeLoc(w, doc, id);
            try w.endObject();
        },
        else => unreachable,
    }
}

// ── comparison ──────────────────────────────────────────────────────────────

/// Structural equality over `std.json.Value` trees: objects compare as
/// unordered key sets, arrays compare element-by-element in order. See this
/// file's doc comment for why the harness compares this way rather than bytes.
pub fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| arr_blk: {
            const y = b.array;
            if (x.items.len != y.items.len) break :arr_blk false;
            for (x.items, y.items) |ea, eb| {
                if (!jsonValueEql(ea, eb)) break :arr_blk false;
            }
            break :arr_blk true;
        },
        .object => |x| obj_blk: {
            const y = b.object;
            if (x.count() != y.count()) break :obj_blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = y.get(e.key_ptr.*) orelse break :obj_blk false;
                if (!jsonValueEql(e.value_ptr.*, other)) break :obj_blk false;
            }
            break :obj_blk true;
        },
    };
}
