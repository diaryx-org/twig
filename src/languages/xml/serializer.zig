//! `AST` -> XML text. The inverse of `parser.zig`, used both as a genuinely
//! useful output path and to prove the parse/serialize loop round-trips (see
//! `xml.zig`'s tests). Byte-perfect fidelity to the *original* source is an
//! explicit non-goal here — that will eventually come from span-splicing
//! edits directly into the original text, per Twig's overall design — so
//! this instead re-derives generic, always-valid XML from the tree alone,
//! which happens to be byte-identical to the source for already-canonical
//! input (double-quoted attributes, explicit close tags, no unusual entity
//! usage): nothing here inserts, removes, or reformats whitespace beyond
//! what's already present as `str` nodes in the tree.
//!
//! Self-closing vs. open/close-pair form: the `AST` has no dedicated flag
//! for "this element was written as `<a/>`", so this renderer uses
//! `Node.content_span == null` as that signal (exactly what the parser
//! leaves it as for a self-closing tag, and only for one — see
//! `parser.zig`'s `parseElement`). An element with a non-null `content_span`
//! always renders as an explicit `<a>...</a>` pair, even if it has no
//! children (the zero-width-`content_span` case, `<a></a>`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;

fn writeEscapedText(writer: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        else => try writer.writeByte(c),
    };
}

fn writeEscapedAttrValue(writer: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(c),
    };
}

fn writeAttrs(ast: *const AST, id: Node.Id, writer: *Writer) Writer.Error!void {
    for (ast.attrsOf(id).entries) |kv| {
        try writer.writeByte(' ');
        try writer.writeAll(kv.key);
        try writer.writeAll("=\"");
        // XML attribute values are never bare (see `AST.KeyVal`'s doc
        // comment); `parser.zig` never produces a null one, but fall back to
        // an empty value rather than crash if a hand-built tree does.
        try writeEscapedAttrValue(writer, kv.value orelse "");
        try writer.writeByte('"');
    }
}

/// Write `id` (and its descendants) as XML text to `writer`.
pub fn serializeNode(ast: *const AST, id: Node.Id, writer: *Writer) Writer.Error!void {
    const node = ast.nodes[id];
    switch (node.kind) {
        .doc => {
            var it = ast.children(id);
            while (it.next()) |child| try serializeNode(ast, child.id, writer);
        },
        .container => |e| {
            try writer.writeByte('<');
            try writer.writeAll(e.name);
            try writeAttrs(ast, id, writer);
            if (node.content_span == null) {
                try writer.writeAll("/>");
                return;
            }
            try writer.writeByte('>');
            var it = ast.children(id);
            while (it.next()) |child| try serializeNode(ast, child.id, writer);
            try writer.writeAll("</");
            try writer.writeAll(e.name);
            try writer.writeByte('>');
        },
        .str => |s| try writeEscapedText(writer, s),
        .comment => |text| {
            try writer.writeAll("<!--");
            try writer.writeAll(text);
            try writer.writeAll("-->");
        },
        .doctype => |guts| {
            try writer.writeAll("<!DOCTYPE");
            try writer.writeAll(guts);
            try writer.writeByte('>');
        },
        .processing_instruction => |pi| {
            try writer.writeAll("<?");
            try writer.writeAll(pi.target);
            if (pi.data.len > 0) {
                try writer.writeByte(' ');
                try writer.writeAll(pi.data);
            }
            try writer.writeAll("?>");
        },
        .cdata => |text| {
            try writer.writeAll("<![CDATA[");
            try writer.writeAll(text);
            try writer.writeAll("]]>");
        },
        // `parser.zig` (and any well-behaved XML parser) never produces
        // anything outside these generic-markup kinds.
        else => unreachable,
    }
}

/// Serialize the whole tree (from `ast.root`) to `writer`.
pub fn serialize(ast: *const AST, writer: *Writer) Writer.Error!void {
    try serializeNode(ast, ast.root, writer);
}

/// Convenience wrapper: serialize to an owned string.
pub fn serializeAlloc(allocator: Allocator, ast: *const AST) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    // `Writer.Allocating` only fails via `error.WriteFailed` when its own
    // backing allocation fails (mirrors `html.zig`'s `renderAlloc`).
    serialize(ast, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

const testing = std.testing;
const parser = @import("parser.zig");

test "serializes a self-closing element with attributes" {
    var p = parser.Parser.init(testing.allocator, "<a x=\"1\" y=\"2\"/>");
    defer p.deinit();
    var ast = try p.parse();
    defer ast.deinit();

    const out = try serializeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<a x=\"1\" y=\"2\"/>", out);
}

test "serializes an explicit open/close pair even when empty" {
    var p = parser.Parser.init(testing.allocator, "<a></a>");
    defer p.deinit();
    var ast = try p.parse();
    defer ast.deinit();

    const out = try serializeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<a></a>", out);
}

test "escapes text and attribute values" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const text = try b.addLeaf(.{ .str = "a < b & c > d" });
    const el = try b.addContainer(.{ .container = .{ .name = "p" } }, &.{text});
    b.setContentSpan(el, .{ .start = 0, .end = 0 });
    try b.setAttrs(el, .{ .entries = &.{.{ .key = "title", .value = "x \"y\" & z" }} });
    const doc_id = try b.addContainer(.doc, &.{el});

    var ast = try b.finish(doc_id);
    defer ast.deinit();

    const out = try serializeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<p title=\"x &quot;y&quot; &amp; z\">a &lt; b &amp; c &gt; d</p>",
        out,
    );
}
