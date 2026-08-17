//! Acceptance test: runs the SAME vendored djot.js conformance corpus
//! `languages/djot/conformance.zig` uses, but through THIS module's generic
//! `serialize` instead of `djot/html.zig`'s bespoke renderer — proving the
//! shared printer is a drop-in replacement (byte-for-byte identical output)
//! before `djot/html.zig` is ever touched.
//!
//! The fixture format and file list are identical to
//! `languages/djot/conformance.zig`; both the format-parsing helpers and the
//! file list are duplicated here rather than imported because
//! `djot/conformance.zig` keeps them private (this module has no business
//! reaching into djot's internals for anything beyond the public `Document`
//! fields `references`/`auto_references`/`footnotes`, which is exactly the
//! shape `Context` mirrors). See that file's doc comment for the fixture
//! syntax itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const djot = @import("../djot/djot.zig");
const html = @import("html.zig");

/// Mirrors `djot/conformance.zig`'s `TestFile`: the fixtures are embedded at
/// compile time, so this suite is indifferent to the working directory too.
/// The files live next to the djot parser that vendored them; this module
/// only reads them.
const TestFile = struct { name: []const u8, content: []const u8 };

const testfiles = [_]TestFile{
    .{ .name = "attributes.test", .content = @embedFile("../djot/testdata/attributes.test") },
    .{ .name = "block_quote.test", .content = @embedFile("../djot/testdata/block_quote.test") },
    .{ .name = "code_blocks.test", .content = @embedFile("../djot/testdata/code_blocks.test") },
    .{ .name = "definition_lists.test", .content = @embedFile("../djot/testdata/definition_lists.test") },
    .{ .name = "symb.test", .content = @embedFile("../djot/testdata/symb.test") },
    .{ .name = "emphasis.test", .content = @embedFile("../djot/testdata/emphasis.test") },
    .{ .name = "escapes.test", .content = @embedFile("../djot/testdata/escapes.test") },
    .{ .name = "fenced_divs.test", .content = @embedFile("../djot/testdata/fenced_divs.test") },
    .{ .name = "footnotes.test", .content = @embedFile("../djot/testdata/footnotes.test") },
    .{ .name = "headings.test", .content = @embedFile("../djot/testdata/headings.test") },
    .{ .name = "insert_delete_mark.test", .content = @embedFile("../djot/testdata/insert_delete_mark.test") },
    .{ .name = "links_and_images.test", .content = @embedFile("../djot/testdata/links_and_images.test") },
    .{ .name = "lists.test", .content = @embedFile("../djot/testdata/lists.test") },
    .{ .name = "math.test", .content = @embedFile("../djot/testdata/math.test") },
    .{ .name = "para.test", .content = @embedFile("../djot/testdata/para.test") },
    .{ .name = "raw.test", .content = @embedFile("../djot/testdata/raw.test") },
    .{ .name = "regression.test", .content = @embedFile("../djot/testdata/regression.test") },
    .{ .name = "smart.test", .content = @embedFile("../djot/testdata/smart.test") },
    .{ .name = "spans.test", .content = @embedFile("../djot/testdata/spans.test") },
    .{ .name = "sourcepos.test", .content = @embedFile("../djot/testdata/sourcepos.test") },
    .{ .name = "super_subscript.test", .content = @embedFile("../djot/testdata/super_subscript.test") },
    .{ .name = "tables.test", .content = @embedFile("../djot/testdata/tables.test") },
    .{ .name = "task_lists.test", .content = @embedFile("../djot/testdata/task_lists.test") },
    .{ .name = "thematic_breaks.test", .content = @embedFile("../djot/testdata/thematic_breaks.test") },
    .{ .name = "verbatim.test", .content = @embedFile("../djot/testdata/verbatim.test") },
};

const TestCase = struct {
    line: usize,
    options: []const u8,
    input: []const u8,
    expected: []const u8,
};

fn startsWithFence(line: []const u8) bool {
    return line.len >= 3 and line[0] == '`' and line[1] == '`' and line[2] == '`';
}

fn isCloseFence(line: []const u8, tick_len: usize) bool {
    if (line.len < tick_len) return false;
    for (line[0..tick_len]) |c| {
        if (c != '`') return false;
    }
    return true;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// Parse every fenced test case out of `content`. Identical logic to
/// `djot/conformance.zig`'s `parseTests`.
fn parseTests(allocator: Allocator, content: []const u8, out: *std.ArrayList(TestCase)) !void {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(allocator, stripCr(line));

    var idx: usize = 0;
    while (true) {
        var open_line: ?[]const u8 = null;
        while (idx < lines.items.len) {
            const l = lines.items[idx];
            idx += 1;
            if (startsWithFence(l)) {
                open_line = l;
                break;
            }
        }
        const line = open_line orelse break;
        const testlinenum = idx;

        var tick_len: usize = 0;
        while (tick_len < line.len and line[tick_len] == '`') tick_len += 1;
        const options = std.mem.trim(u8, line[tick_len..], " \t");

        var input = std.ArrayList(u8).empty;
        errdefer input.deinit(allocator);
        while (idx < lines.items.len) {
            const l = lines.items[idx];
            idx += 1;
            if (std.mem.eql(u8, l, ".") or std.mem.eql(u8, l, "!")) break;
            try input.appendSlice(allocator, l);
            try input.append(allocator, '\n');
        }

        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        while (idx < lines.items.len) {
            const l = lines.items[idx];
            idx += 1;
            if (isCloseFence(l, tick_len)) break;
            try output.appendSlice(allocator, l);
            try output.append(allocator, '\n');
        }

        try out.append(allocator, .{
            .line = testlinenum,
            .options = options,
            .input = try input.toOwnedSlice(allocator),
            .expected = try output.toOwnedSlice(allocator),
        });
    }
}

pub const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

pub const Failure = struct {
    file: []const u8,
    line: usize,
    input: []const u8,
    expected: []const u8,
    actual: []const u8,

    fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.file);
        allocator.free(self.input);
        allocator.free(self.expected);
        allocator.free(self.actual);
    }
};

/// Run every fixture, rendering each parsed `Document` through THIS module's
/// `html.serialize` (via a `Context` built from the `Document`'s side
/// tables) rather than `djot/html.zig`. Structurally identical to
/// `djot/conformance.zig`'s `run`.
pub fn run(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !Summary {
    var summary: Summary = .{};
    for (testfiles) |file| {
        var cases = std.ArrayList(TestCase).empty;
        defer {
            for (cases.items) |c| {
                allocator.free(c.input);
                allocator.free(c.expected);
            }
            cases.deinit(allocator);
        }
        try parseTests(allocator, file.content, &cases);

        for (cases.items) |c| {
            summary.total += 1;
            if (std.mem.indexOfScalar(u8, c.options, 'a') != null) {
                // AST-pretty-print mode: neither renderer implements it, so
                // `djot/conformance.zig` skips these ~6 cases too.
                summary.skipped += 1;
                continue;
            }
            var doc = djot.parse(allocator, c.input) catch {
                summary.failed += 1;
                if (failures.items.len < max_failures) {
                    try failures.append(allocator, .{
                        .file = try allocator.dupe(u8, file.name),
                        .line = c.line,
                        .input = try allocator.dupe(u8, c.input),
                        .expected = try allocator.dupe(u8, c.expected),
                        .actual = try allocator.dupe(u8, "<parse error>"),
                    });
                }
                continue;
            };
            defer doc.deinit();

            // Build a `Context` straight from the `Document`'s public side
            // tables -- a test-only use of djot internals; `serializer.zig`
            // itself never imports djot (see this file's module doc comment
            // and `serializer.zig`'s module doc comment).
            const ctx: html.Context = .{
                .references = doc.references,
                .auto_references = doc.auto_references,
                .footnotes = doc.footnotes,
            };
            const rendered = try html.serializeAlloc(allocator, &doc.ast, &ctx);
            if (std.mem.eql(u8, rendered, c.expected)) {
                summary.passed += 1;
                allocator.free(rendered);
            } else {
                summary.failed += 1;
                if (failures.items.len < max_failures) {
                    try failures.append(allocator, .{
                        .file = try allocator.dupe(u8, file.name),
                        .line = c.line,
                        .input = try allocator.dupe(u8, c.input),
                        .expected = try allocator.dupe(u8, c.expected),
                        .actual = rendered,
                    });
                } else {
                    allocator.free(rendered);
                }
            }
        }
    }
    return summary;
}

test "shared HTML printer matches djot.js conformance corpus exactly like djot/html.zig does" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer {
        for (failures.items) |f| f.deinit(allocator);
        failures.deinit(allocator);
    }
    const summary = try run(allocator, 40, &failures);

    // Report to stderr only on failure. A passing run stays silent on purpose:
    // under `zig build test` the child's stderr carries the build runner's
    // `std.Progress` IPC, so a raw `std.debug.print` can corrupt that protocol
    // and surface as a confusing `failed command` even when every test passed.
    // On failure the build is already red, so the detail earns its noise; run
    // the test binary directly if you want a summary of a green run.
    if (summary.failed > 0) {
        std.debug.print(
            "\nhtml printer conformance: {d}/{d} HTML cases passed, {d} failed ({d} djot.js AST-dump cases skipped; behaviours covered by native AST tests)\n",
            .{ summary.passed, summary.total - summary.skipped, summary.failed, summary.skipped },
        );
        for (failures.items) |f| {
            std.debug.print(
                "\n-- {s}:{d} --\ninput:\n{s}\nexpected:\n{s}\nactual:\n{s}\n",
                .{ f.file, f.line, f.input, f.expected, f.actual },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
}
