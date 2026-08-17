//! Runs the vendored djot.js conformance corpus (`testdata/*.test`, copied
//! verbatim from `djot.js/test/*.test`) against `parse` + `html`.
//!
//! Fixture format (reverse-engineered from djot.js's own test runner,
//! `src/functional.spec.ts`, since there's no spec document for it): each
//! file is prose with embedded fenced blocks,
//!
//! ```` ```<options>
//! <djot input, one or more lines>
//! .
//! <expected HTML output>
//! ```` ````
//!
//! opened by a line of 3+ backticks optionally followed by an "options"
//! string, closed by a line starting with AT LEAST as many backticks as the
//! opener (so input containing its own ``` fences can be wrapped in a
//! longer run, e.g. four backticks). `options` containing `a` means "compare
//! against the AST pretty-printer, not HTML" — a debug dump format
//! (`renderAST` in djot.js's `parse.ts`). That format is a djot.js-internal
//! debug serialization, not something Twig users need, so this port doesn't
//! reproduce it: those 6 of 271 cases are skipped *here* and their parser
//! behaviours (symb shortcodes, multi-line/escaped attribute values, table
//! captions, byte-accurate source spans) are asserted directly against Twig's
//! own AST in native unit tests instead — see `djot.zig` and `parser.zig`. So
//! every case that defines an HTML expectation passes (100%), and nothing the
//! AST-dump cases check goes untested. `options` containing `p` enables
//! source-position tracking, which doesn't change HTML output and needs no
//! special handling here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const djot = @import("djot.zig");
const html = @import("html.zig");

/// One vendored fixture file: `name` for failure reports, `content` embedded
/// at compile time. Embedded rather than read from disk so the corpus travels
/// with the module and the suite doesn't care what directory it runs from —
/// the same way `markdown/conformance.zig` and `rst/conformance.zig` carry
/// theirs.
const TestFile = struct { name: []const u8, content: []const u8 };

const testfiles = [_]TestFile{
    .{ .name = "attributes.test", .content = @embedFile("testdata/attributes.test") },
    .{ .name = "block_quote.test", .content = @embedFile("testdata/block_quote.test") },
    .{ .name = "code_blocks.test", .content = @embedFile("testdata/code_blocks.test") },
    .{ .name = "definition_lists.test", .content = @embedFile("testdata/definition_lists.test") },
    .{ .name = "symb.test", .content = @embedFile("testdata/symb.test") },
    .{ .name = "emphasis.test", .content = @embedFile("testdata/emphasis.test") },
    .{ .name = "escapes.test", .content = @embedFile("testdata/escapes.test") },
    .{ .name = "fenced_divs.test", .content = @embedFile("testdata/fenced_divs.test") },
    .{ .name = "footnotes.test", .content = @embedFile("testdata/footnotes.test") },
    .{ .name = "headings.test", .content = @embedFile("testdata/headings.test") },
    .{ .name = "insert_delete_mark.test", .content = @embedFile("testdata/insert_delete_mark.test") },
    .{ .name = "links_and_images.test", .content = @embedFile("testdata/links_and_images.test") },
    .{ .name = "lists.test", .content = @embedFile("testdata/lists.test") },
    .{ .name = "math.test", .content = @embedFile("testdata/math.test") },
    .{ .name = "para.test", .content = @embedFile("testdata/para.test") },
    .{ .name = "raw.test", .content = @embedFile("testdata/raw.test") },
    .{ .name = "regression.test", .content = @embedFile("testdata/regression.test") },
    .{ .name = "smart.test", .content = @embedFile("testdata/smart.test") },
    .{ .name = "spans.test", .content = @embedFile("testdata/spans.test") },
    .{ .name = "sourcepos.test", .content = @embedFile("testdata/sourcepos.test") },
    .{ .name = "super_subscript.test", .content = @embedFile("testdata/super_subscript.test") },
    .{ .name = "tables.test", .content = @embedFile("testdata/tables.test") },
    .{ .name = "task_lists.test", .content = @embedFile("testdata/task_lists.test") },
    .{ .name = "thematic_breaks.test", .content = @embedFile("testdata/thematic_breaks.test") },
    .{ .name = "verbatim.test", .content = @embedFile("testdata/verbatim.test") },
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

/// Parse every fenced test case out of `content`. Returned `TestCase`s
/// borrow slices of `content`'s lines (joined with '\n' into freshly
/// allocated buffers, since a case spans many lines) -- `input`/`expected`
/// are owned and must be freed by the caller.
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

/// A fully owned record of one failing case: `input`/`expected`/`actual`
/// are all copied (never borrowed from the per-file `cases` list in `run`,
/// which is freed before the whole corpus finishes), so a `Failure` outlives
/// the run and the caller frees it via `Failure.deinit`.
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

/// Run every fixture in every vendored file, collecting a summary and (up
/// to `max_failures`) detailed failure records.
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
            const rendered = try html.renderAlloc(allocator, &doc, .{});
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

test "djot.js conformance corpus" {
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
            "\ndjot conformance: {d}/{d} HTML cases passed, {d} failed ({d} djot.js AST-dump cases skipped; behaviours covered by native AST tests)\n",
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
