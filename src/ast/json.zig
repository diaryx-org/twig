//! A stable, inspectable JSON encoding of the shared `AST`, for debugging
//! parsers and diffing tree shapes across runs. This is a LIBRARY module
//! (exported from `root.zig` as `twig.ast_json`) so every surface can reach
//! it: `twig convert -o ast` (`cli/actions.zig`) and the C ABI's
//! `twig_document_ast_json` (`c_abi.zig`) both call `encode`/`encodeAlloc`
//! here rather than each carrying their own encoder.
//!
//! Every node becomes an object with a `"kind"` tag (the `Node.Kind` union's
//! tag name, e.g. `"heading"`, `"str"`), a `"span"` byte range, that kind's
//! own payload fields inlined (switching exhaustively over `AST.Node.Kind` —
//! see `writeKindPayload`), and `"attrs"`/`"children"` when non-empty.
//!
//! Escaping correctness comes for free from `std.json.Stringify.write`,
//! which is used for every leaf value (strings, ints, bools, `?T`, and even
//! the payload enums like `ListNumbering`/`Alignment`, which `write`
//! renders as their tag name — no manual `@tagName` calls needed for those).
//! Only the *shape* (which fields a kind gets, in what order) is decided by
//! hand below, via `writeNode`'s explicit `beginObject`/`objectField`/
//! `endObject` calls walking the `first_child`/`next_sibling` tree — `write`
//! alone can't do that part since `AST` is a linked structure, not a
//! `[]node`-shaped value `write`'s reflection could walk on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

const AST = @import("ast.zig");
const Document = @import("../document.zig");
const Node = AST.Node;

/// Encode `ast` (rooted at `ast.root`) as pretty-printed (2-space indent)
/// JSON, writing to `writer`. Emits a trailing newline so piping straight to
/// a terminal or a file looks like any other well-behaved text tool's
/// output.
pub fn encode(doc: *const Document, writer: *Writer) Writer.Error!void {
    var w: Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try writeNode(&w, doc, doc.ast.root);
    try writer.writeByte('\n');
}

/// `encode` into a freshly allocated, caller-owned buffer. The underlying
/// `Writer.Allocating` only ever fails on allocation, so the encoder's
/// `Writer.Error` collapses to `Allocator.Error` here.
pub fn encodeAlloc(allocator: Allocator, doc: *const Document) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    encode(doc, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn writeNode(w: *Stringify, doc: *const Document, id: Node.Id) Writer.Error!void {
    const node = doc.ast.nodes[id];

    try w.beginObject();

    try w.objectField("kind");
    try w.write(node.kind.kindName());

    try w.objectField("span");
    try w.beginArray();
    try w.write(doc.span(id).start);
    try w.write(doc.span(id).end);
    try w.endArray();

    if (doc.contentSpan(id)) |cs| {
        try w.objectField("content_span");
        try w.beginArray();
        try w.write(cs.start);
        try w.write(cs.end);
        try w.endArray();
    }

    try writeKindPayload(w, node.kind);

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
    }

    if (node.first_child != null) {
        try w.objectField("children");
        try w.beginArray();
        var it = doc.children(id);
        while (it.next()) |child| try writeNode(w, doc, child.id);
        try w.endArray();
    }

    try w.endObject();
}

/// Write the fields specific to `kind`'s payload — the part of each node
/// that isn't `kind`/`span`/`content_span`/`attrs`/`children`. Switches
/// exhaustively over `AST.Node.Kind` (see `ast.zig`'s doc comment for the
/// full vocabulary) so adding a new `Kind` variant fails this file's build
/// until it's given a field mapping here.
fn writeKindPayload(w: *Stringify, kind: Node.Kind) Writer.Error!void {
    switch (kind) {
        // Payload-free kinds: nothing beyond kind/span/attrs/children.
        .doc,
        .para,
        .thematic_break,
        .section,
        .block_quote,
        .definition_list,
        .table,
        .list_item,
        .definition_list_item,
        .term,
        .definition,
        .caption,
        .soft_break,
        .hard_break,
        .non_breaking_space,
        // `inline_mark`'s family member is already reported as the node's
        // `kind` name (see `Kind.kindName`), so it needs no payload field.
        .inline_mark,
        => {},

        .heading => |h| {
            try w.objectField("level");
            try w.write(h.level);
        },
        .code_block => |c| {
            try w.objectField("lang");
            try w.write(c.lang);
            try w.objectField("text");
            try w.write(c.text);
        },
        .raw_block => |r| {
            try w.objectField("format");
            try w.write(r.format);
            try w.objectField("text");
            try w.write(r.text);
        },
        .metadata => |m| {
            try w.objectField("lang");
            try w.write(m.lang);
            try w.objectField("text");
            try w.write(m.text);
        },
        .bullet_list => |b| {
            try w.objectField("tight");
            try w.write(b.tight);
        },
        .ordered_list => |o| {
            try w.objectField("numbering");
            try w.write(o.numbering);
            try w.objectField("tight");
            try w.write(o.tight);
            try w.objectField("start");
            try w.write(o.start);
        },
        .task_list => |t| {
            try w.objectField("tight");
            try w.write(t.tight);
        },
        .task_list_item => |t| {
            try w.objectField("checked");
            try w.write(t.checked);
        },
        .row => |r| {
            try w.objectField("head");
            try w.write(r.head);
        },
        .cell => |c| {
            try w.objectField("head");
            try w.write(c.head);
            try w.objectField("alignment");
            try w.write(c.alignment);
            try w.objectField("colspan");
            try w.write(c.colspan);
            try w.objectField("rowspan");
            try w.write(c.rowspan);
        },
        .footnote => |f| {
            try w.objectField("label");
            try w.write(f.label);
        },
        .reference => |r| {
            try w.objectField("label");
            try w.write(r.label);
            try w.objectField("destination");
            try w.write(r.destination);
        },
        .str => |s| {
            try w.objectField("text");
            try w.write(s);
        },
        // The seven text leaves report their family member as the node's
        // `kind` name (see `Kind.kindName`), so one arm serves all of them.
        .text_leaf => |l| {
            try w.objectField("text");
            try w.write(l.text);
        },
        .raw_inline => |r| {
            try w.objectField("format");
            try w.write(r.format);
            try w.objectField("text");
            try w.write(r.text);
        },
        .smart_punctuation => |sp| {
            try w.objectField("punctuation_kind");
            try w.write(sp);
            // No stored spelling to report anymore (see `Kind.smart_punctuation`'s
            // doc) — `text` is derived so the published JSON vocabulary is
            // unchanged for existing consumers.
            try w.objectField("text");
            try w.write(sp.ascii());
        },
        .link => |l| {
            try w.objectField("destination");
            try w.write(l.destination);
            try w.objectField("reference");
            try w.write(l.reference);
        },
        .image => |l| {
            try w.objectField("destination");
            try w.write(l.destination);
            try w.objectField("reference");
            try w.write(l.reference);
        },
        .container => |c| {
            try w.objectField("name");
            try w.write(c.name);
            try w.objectField("form");
            try w.write(c.form);
            try w.objectField("argument");
            try w.write(c.argument);
        },
        // The three markup leaves report their family member as the node's
        // `kind` name (see `Kind.kindName`), so one arm serves all of them.
        .markup_leaf => |l| {
            try w.objectField("text");
            try w.write(l.text);
        },
        .processing_instruction => |p| {
            try w.objectField("target");
            try w.write(p.target);
            try w.objectField("data");
            try w.write(p.data);
        },
    }
}

const testing = std.testing;

test "encode: leaf node gets kind/span, omits content_span/attrs/children when absent" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const leaf = try b.addLeaf(.{ .str = "hi" });
    b.setSpan(leaf, .init(0, 2));

    var ast = try b.finishDocument("", leaf);
    defer ast.deinit();

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("str", obj.get("kind").?.string);
    try testing.expectEqualStrings("hi", obj.get("text").?.string);
    const span = obj.get("span").?.array;
    try testing.expectEqual(@as(usize, 2), span.items.len);
    try testing.expectEqual(@as(i64, 0), span.items[0].integer);
    try testing.expectEqual(@as(i64, 2), span.items[1].integer);
    try testing.expectEqual(@as(?std.json.Value, null), obj.get("content_span"));
    try testing.expectEqual(@as(?std.json.Value, null), obj.get("attrs"));
    try testing.expectEqual(@as(?std.json.Value, null), obj.get("children"));
}

test "encode: container node nests children in source order" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const a = try b.addLeaf(.{ .str = "a" });
    const em_text = try b.addLeaf(.{ .str = "b" });
    const em = try b.addContainer(.{ .inline_mark = .emph }, &.{em_text});
    const para = try b.addContainer(.para, &.{ a, em });

    var ast = try b.finishDocument("", para);
    defer ast.deinit();

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("para", obj.get("kind").?.string);
    const children = obj.get("children").?.array;
    try testing.expectEqual(@as(usize, 2), children.items.len);
    try testing.expectEqualStrings("str", children.items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("a", children.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("emph", children.items[1].object.get("kind").?.string);
    const em_children = children.items[1].object.get("children").?.array;
    try testing.expectEqualStrings("b", em_children.items[0].object.get("text").?.string);
}

test "encode: attrs render as ordered key/value pairs, bare attrs get a null value" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const el = try b.addLeaf(.{ .container = .{ .name = "input" } });
    try b.setAttrs(el, .{ .entries = &.{
        .{ .key = "disabled", .value = null },
        .{ .key = "type", .value = "checkbox" },
    } });

    var ast = try b.finishDocument("", el);
    defer ast.deinit();

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("container", obj.get("kind").?.string);
    try testing.expectEqualStrings("input", obj.get("name").?.string);
    const attrs = obj.get("attrs").?.array;
    try testing.expectEqual(@as(usize, 2), attrs.items.len);
    try testing.expectEqualStrings("disabled", attrs.items[0].object.get("key").?.string);
    try testing.expectEqual(std.json.Value.null, attrs.items[0].object.get("value").?);
    try testing.expectEqualStrings("type", attrs.items[1].object.get("key").?.string);
    try testing.expectEqualStrings("checkbox", attrs.items[1].object.get("value").?.string);
}

test "encode: content_span is emitted only when set, and enum payloads render as tag-name strings" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const list = try b.addContainer(.{ .ordered_list = .{ .numbering = .lower_alpha, .tight = true, .start = null } }, &.{});
    b.setContentSpan(list, .init(1, 5));

    var ast = try b.finishDocument("", list);
    defer ast.deinit();

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("ordered_list", obj.get("kind").?.string);
    try testing.expectEqualStrings("lower_alpha", obj.get("numbering").?.string);
    try testing.expectEqual(true, obj.get("tight").?.bool);
    // The marker spelling (`- ` vs `* `, `1.` vs `1)`) left the AST for the
    // Document's spelling table, so the encoding no longer carries it.
    try testing.expectEqual(@as(?std.json.Value, null), obj.get("style"));
    try testing.expectEqual(@as(?std.json.Value, null), obj.get("delim"));
    const cs = obj.get("content_span").?.array;
    try testing.expectEqual(@as(i64, 1), cs.items[0].integer);
    try testing.expectEqual(@as(i64, 5), cs.items[1].integer);
}

test "encode is pretty-printed with 2-space indentation" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const leaf = try b.addLeaf(.{ .str = "x" });
    const root = try b.addContainer(.para, &.{leaf});

    var ast = try b.finishDocument("", root);
    defer ast.deinit();

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\n  \"kind\"") != null);
}
