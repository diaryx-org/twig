const std = @import("std");
const testing = std.testing;

const twig = @import("twig");
const meta = @import("meta.zig");

fn edited(host: []const u8, comptime edit: fn (*meta.Embed) anyerror!void) ![]u8 {
    var parsed = try meta.parseHost(testing.allocator, host, .markdown);
    defer parsed.deinit();
    const block = meta.find(&parsed.doc, host, .front) orelse return error.NoMetadata;
    var e = try meta.Embed.open(testing.allocator, host, block);
    defer e.deinit();
    try edit(&e);
    return e.render(testing.allocator);
}

test "find: frontmatter's fences, body and language" {
    const host = "---\ntitle: Hi # kept\n---\n# Body\n";
    var parsed = try meta.parseHost(testing.allocator, host, .markdown);
    defer parsed.deinit();
    const block = meta.find(&parsed.doc, host, .front).?;
    try testing.expectEqualStrings("yaml", block.lang);
    try testing.expectEqualStrings("title: Hi # kept\n", host[block.body.start..block.body.end]);
    try testing.expectEqualStrings("---\ntitle: Hi # kept\n---", host[block.span.start..block.span.end]);
    try testing.expect(meta.find(&parsed.doc, host, .end) == null);
}

test "find: endmatter is the trailing block, and not frontmatter" {
    const host = "# Body\n\ntext\n\n---toml\nx = 1\n---\n";
    var parsed = try meta.parseHost(testing.allocator, host, .markdown);
    defer parsed.deinit();
    try testing.expect(meta.find(&parsed.doc, host, .front) == null);
    const block = meta.find(&parsed.doc, host, .end).?;
    try testing.expectEqualStrings("toml", block.lang);
    try testing.expectEqualStrings("x = 1\n", host[block.body.start..block.body.end]);
}

test "find: a document with no metadata has none" {
    const host = "# Body\n";
    var parsed = try meta.parseHost(testing.allocator, host, .markdown);
    defer parsed.deinit();
    try testing.expect(meta.find(&parsed.doc, host, .front) == null);
    try testing.expect(meta.find(&parsed.doc, host, .end) == null);
}

test "Embed: a YAML edit moves only its value; the comment, fences and body stay" {
    const out = try edited("---\ntitle: Hi # kept\ntags: [a]\n---\n# Body\n", struct {
        fn f(e: *meta.Embed) !void {
            try e.editor.set(&.{.{ .key = "title" }}, "Hello");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("---\ntitle: Hello # kept\ntags: [a]\n---\n# Body\n", out);
}

test "Embed: a new key lands inside the fences" {
    const out = try edited("---\ntitle: Hi\n---\nbody\n", struct {
        fn f(e: *meta.Embed) !void {
            try e.editor.set(&.{.{ .key = "draft" }}, "true");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("---\ntitle: Hi\ndraft: true\n---\nbody\n", out);
}

test "Embed: TOML frontmatter is edited as TOML" {
    const out = try edited("+++\ntitle = \"Hi\"\n+++\nbody\n", struct {
        fn f(e: *meta.Embed) !void {
            try e.editor.set(&.{.{ .key = "title" }}, "\"Hello\"");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("+++\ntitle = \"Hello\"\n+++\nbody\n", out);
}

test "Embed: `---fig` is read as figl" {
    const out = try edited("---fig\ntitle = Hi\n---\nbody\n", struct {
        fn f(e: *meta.Embed) !void {
            try e.editor.set(&.{.{ .key = "title" }}, "Hello");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("---fig\ntitle = Hello\n---\nbody\n", out);
}

test "Embed: a block in a language fig does not know is refused" {
    const host = "---edn\n{:title \"Hi\"}\n---\nbody\n";
    var parsed = try meta.parseHost(testing.allocator, host, .markdown);
    defer parsed.deinit();
    const block = meta.find(&parsed.doc, host, .front).?;
    try testing.expectError(error.UnsupportedLanguage, meta.Embed.open(testing.allocator, host, block));
}

test "Embed.openOrInit: a host with no frontmatter gains a block above its first line" {
    var e = try meta.Embed.openOrInit(testing.allocator, "# Body\n", .markdown, "yaml");
    defer e.deinit();
    try e.editor.set(&.{.{ .key = "title" }}, "Hi");
    const out = try e.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("---\ntitle: Hi\n---\n# Body\n", out);
}

test "Embed.openOrInit: a host with frontmatter opens it, whatever language was asked" {
    var e = try meta.Embed.openOrInit(testing.allocator, "+++\nx = 1\n+++\nbody\n", .markdown, "yaml");
    defer e.deinit();
    try testing.expectEqualStrings("toml", e.lang);
    try e.editor.set(&.{.{ .key = "x" }}, "2");
    const out = try e.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("+++\nx = 2\n+++\nbody\n", out);
}

test "resolve: frontmatter's twig settings turn on features and pick the dialect" {
    const host =
        \\---
        \\title: Notes
        \\twig:
        \\  dialect: gfm
        \\  features: [math, highlight]
        \\---
        \\$x$ and ==marked==
        \\
    ;
    var r = try meta.resolve(testing.allocator, host, .markdown, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(twig.Format.gfm, r.format);
    try testing.expect(r.config.markdown.math);
    try testing.expect(r.config.markdown.highlight);
    try testing.expect(!r.config.markdown.directives);
    try testing.expectEqual(@as(usize, 0), r.ignored.len);
}

test "resolve: the caller's config stays under the document's settings" {
    const host = "---\ntwig:\n  features: math\n---\nbody\n";
    var r = try meta.resolve(testing.allocator, host, .markdown, .{ .markdown = .{ .directives = true } });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(twig.Format.markdown, r.format);
    try testing.expect(r.config.markdown.math);
    try testing.expect(r.config.markdown.directives);
}

test "resolve: unknown names are reported, not refused" {
    const host = "---\ntwig:\n  dialect: djot\n  features: [math, sparkles]\n  colour: red\n---\nbody\n";
    var r = try meta.resolve(testing.allocator, host, .markdown, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(twig.Format.markdown, r.format);
    try testing.expect(r.config.markdown.math);
    try testing.expectEqual(@as(usize, 3), r.ignored.len);
    try testing.expectEqualStrings("dialect", r.ignored[0]);
    try testing.expectEqualStrings("colour", r.ignored[1]);
    try testing.expectEqualStrings("sparkles", r.ignored[2]);
}

test "resolve: no frontmatter, or frontmatter that does not parse, reads as asked" {
    inline for (.{ "# Body\n", "---\ntwig: [unclosed\n---\nbody\n" }) |host| {
        var r = try meta.resolve(testing.allocator, host, .markdown, .{});
        defer r.deinit(testing.allocator);
        try testing.expectEqual(twig.Format.markdown, r.format);
        try testing.expect(!r.config.markdown.math);
    }
}
