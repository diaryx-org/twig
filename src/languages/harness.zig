//! Registry-wide engine contracts. Corpora belong to conformance readers.
const std = @import("std");
const testing = std.testing;
const format = @import("../format.zig");
const Document = @import("../document.zig");
const Span = @import("../span.zig");
const Editor = @import("../ast/editor.zig").Editor;

fn expectSpan(span: Span, len: usize) !void {
    try testing.expect(span.start <= span.end);
    try testing.expect(span.end <= len);
}

fn expectColumns(doc: Document) !void {
    try testing.expectEqual(doc.ast.nodes.len, doc.node_spans.len);
    try testing.expectEqual(doc.ast.nodes.len, doc.node_content_spans.len);
    try testing.expect(doc.node_spelling.len <= doc.ast.nodes.len);
    try testing.expect(doc.node_marker_spans.len <= doc.ast.nodes.len);
    try testing.expect(doc.attrs_spans.len <= doc.ast.attrs.len);
    for (doc.node_spans) |span| try expectSpan(span, doc.source.len);
    for (doc.node_content_spans) |maybe| {
        if (maybe) |span| try expectSpan(span, doc.source.len);
    }
    for (doc.node_marker_spans, 0..) |maybe, id| {
        if (maybe) |span| {
            try expectSpan(span, doc.source.len);
            // Leading markers also cover headings, quotes, and AsciiDoc admonitions.
            try testing.expect(switch (doc.ast.nodes[id].kind) {
                .list_item, .task_list_item, .definition_list_item, .heading, .block_quote => true,
                .container => |c| c.form == .block_fenced and doc.containerOrigin(@intCast(id)) == .directive,
                else => false,
            });
        }
    }
    for (doc.attrs_spans, 0..) |maybe, id| {
        if (maybe) |span| {
            try expectSpan(span, doc.source.len);
            var referenced = false;
            for (doc.ast.nodes) |node| {
                if (node.attrs) |attrs_id| {
                    if (attrs_id == id) referenced = true;
                }
            }
            try testing.expect(referenced);
        }
    }
}

fn expectSample(entry: format.Entry, sample: []const u8) !void {
    const config: format.ParseConfig = .{};
    var first = try entry.parse(&config, testing.allocator, sample);
    defer first.deinit();
    try testing.expectEqualStrings(sample, first.doc.source);
    try expectColumns(first.doc);
    if (entry.serializeCanonical) |serialize| {
        const printed = try serialize(testing.allocator, &first);
        defer testing.allocator.free(printed);
        errdefer std.debug.print("\n--- canonical output ---\n{s}\n", .{printed});
        var second = try entry.parse(&config, testing.allocator, printed);
        defer second.deinit();
        try expectColumns(second.doc);
        try testing.expect(first.doc.ast.eql(second.doc.ast));
    }
    if (entry.syntax.authorable()) {
        var editor = try Editor.init(testing.allocator, sample, &config, entry.parseToAst, entry.syntax);
        defer editor.deinit();
        try testing.expect(first.doc.ast.eql(editor.astView().*));
        try expectColumns(editor.splicer.doc);
        try editor.splicer.replaceAtSpan(Span.init(0, 0), "");
        try testing.expectEqualStrings(sample, editor.sourceBytes());
        try testing.expectEqualStrings(sample, editor.splicer.doc.source);
        try testing.expect(first.doc.ast.eql(editor.astView().*));
        try expectColumns(editor.splicer.doc);
    }
}

test "harness: every format declares samples and satisfies the engine contract" {
    for (format.registry) |entry| {
        if (entry.samples.len == 0) {
            std.debug.print("\n{s}: no harness samples declared\n", .{@tagName(entry.id)});
            return error.MissingSamples;
        }
        for (entry.samples, 0..) |sample, index| {
            errdefer std.debug.print("\n{s}: harness sample {d}\n--- source ---\n{s}\n", .{ @tagName(entry.id), index, sample });
            try expectSample(entry, sample);
        }
    }
}
