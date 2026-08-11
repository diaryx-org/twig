//! The AsciiDoc TCK conformance harness: runs the vendored TCK corpus
//! (`testdata/asciidoc-tck-corpus.json`, 13 cases hand-vendored from the
//! AsciiDoc Language Working Group's `asciidoc-tck` — see the corpus file's
//! own `provenance` for exactly where from) through `asg.zig`'s codec and,
//! now, `parser.zig`.
//!
//! ── The codec round-trip (`run`/`SEMANTIC_BASELINE`) ────────────────────────
//! `encode(decode(x)) == x` (structurally — see `asg.zig`'s doc comment) over
//! every case, plus `Coverage`: how much of the TCK's element vocabulary maps
//! to a semantic `Kind` versus the `container` escape hatch. Landed before a
//! parser existed, same posture as `languages/rst/conformance.zig`'s own
//! `run`/`SEMANTIC_BASELINE`, and kept afterward as the codec's own regression
//! test, independent of the parser.
//!
//! The TCK itself is young (`1.0.0-alpha.0`, 13 cases against a
//! still-being-written spec) — small enough that, unlike rST's 713-case
//! docutils corpus, there is no meaningful sub-baseline to track per
//! construct. `SEMANTIC_BASELINE` is still a ratchet for the same reason
//! rST's is: it climbs whenever `asg.zig` maps a new ASG shape, and a
//! regression fails the build.
//!
//! ── The parse comparison (`runParse`/`PARSE_BASELINE`) ───────────────────────
//! `parser.parse`/`parser.parseInlineList` (chosen by `case.level`) ->
//! `asg.encode` -> compare against `case.asg`, structurally, over all 13
//! cases — small enough that, unlike rST's 494-case split, there is no
//! subset excluded from this comparison; the TCK has no error-asserting cases
//! at all yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const asg = @import("asg.zig");
const asciidoc_parser = @import("parser.zig");

const corpus_json = @embedFile("testdata/asciidoc-tck-corpus.json");

/// Ratchet floor (see this file's module doc comment): `Coverage.semantic`
/// summed across all 13 cases — 50, against 3 generic (the `sidebar` case's
/// container, plus the document-attributes marker in both `header-body` and
/// `attribute-entries-below-title`) and 18 text nodes. Raise it whenever
/// `asg.zig`'s decode table grows a new mapped shape; never lower it.
pub const SEMANTIC_BASELINE: u32 = 50;

/// One vendored TCK case. Mirrors the JSON emitted alongside
/// `testdata/asciidoc-tck-corpus.json`; the corpus's top-level `provenance`
/// is skipped via `ignore_unknown_fields`.
pub const Case = struct {
    /// The case's path within the TCK's `tests/` tree, minus the
    /// `-input`/`-output` suffix — e.g. `block/paragraph/single-line`.
    id: []const u8,
    /// `"block"` (an `asg` shaped as a `document`) or `"inline"` (an `asg`
    /// shaped as a bare array of inline nodes).
    level: []const u8,
    /// The AsciiDoc source, exactly as the TCK's `-input.adoc` file has it.
    adoc: []const u8,
    /// The TCK's `-config.json`, when the case has one (a human-readable
    /// description in this corpus, not adapter configuration) — unused by
    /// this harness today, carried for provenance.
    config: ?std.json.Value = null,
    /// The expected ASG, exactly as the TCK's `-output.json` has it.
    asg: std.json.Value,
};

const Corpus = struct { cases: []const Case };

pub const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

/// A fully owned record of one failing case. `expected`/`actual` are the raw
/// JSON text of each side (or a `<decode error: ...>` placeholder), for a
/// human to diff — the pass/fail decision itself was already made
/// structurally via `asg.jsonValueEql`, not on this text.
pub const Failure = struct {
    id: []const u8,
    adoc: []const u8,
    expected: []const u8,
    actual: []const u8,

    pub fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.adoc);
        allocator.free(self.expected);
        allocator.free(self.actual);
    }
};

pub const RunResult = struct {
    summary: Summary = .{},
    coverage: asg.Coverage = .{},
};

pub fn run(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !RunResult {
    var parsed = try std.json.parseFromSlice(Corpus, allocator, corpus_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var result: RunResult = .{};

    for (parsed.value.cases) |case| {
        result.summary.total += 1;
        const root: asg.Root = if (std.mem.eql(u8, case.level, "block")) .document else .inlines;

        var doc = asg.decode(allocator, case.adoc, root, case.asg, &result.coverage) catch |err| {
            result.summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .id = try allocator.dupe(u8, case.id),
                    .adoc = try allocator.dupe(u8, case.adoc),
                    .expected = try expectedText(allocator, case.asg),
                    .actual = try std.fmt.allocPrint(allocator, "<decode error: {s}>", .{@errorName(err)}),
                });
            }
            continue;
        };
        defer doc.deinit();

        const actual_json = try asg.encodeAlloc(allocator, &doc, root);
        defer allocator.free(actual_json);
        var actual_parsed = try std.json.parseFromSlice(std.json.Value, allocator, actual_json, .{});
        defer actual_parsed.deinit();

        if (asg.jsonValueEql(actual_parsed.value, case.asg)) {
            result.summary.passed += 1;
        } else {
            result.summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .id = try allocator.dupe(u8, case.id),
                    .adoc = try allocator.dupe(u8, case.adoc),
                    .expected = try expectedText(allocator, case.asg),
                    .actual = try allocator.dupe(u8, actual_json),
                });
            }
        }
    }
    return result;
}

/// Ratchet floor for `runParse`: of the 13 corpus cases, how many does
/// `parser.parse`/`parseInlineList` -> `asg.encode` reproduce structurally
/// against `case.asg`. Raise it whenever the parser's coverage grows; never
/// lower it.
pub const PARSE_BASELINE: u32 = 13;

/// Parse every case's `.adoc` and encode it straight back through `asg.zig`,
/// collecting the pass/fail tally and (up to `max_failures`) detailed failure
/// records — `runParse`'s counterpart to `run`, comparing the PARSER's output
/// instead of the codec's own round-trip.
pub fn runParse(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !RunResult {
    var parsed = try std.json.parseFromSlice(Corpus, allocator, corpus_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var result: RunResult = .{};

    for (parsed.value.cases) |case| {
        result.summary.total += 1;
        const root: asg.Root = if (std.mem.eql(u8, case.level, "block")) .document else .inlines;

        var doc = switch (root) {
            .document => asciidoc_parser.parse(allocator, case.adoc),
            .inlines => asciidoc_parser.parseInlineList(allocator, case.adoc),
        } catch |err| {
            result.summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .id = try allocator.dupe(u8, case.id),
                    .adoc = try allocator.dupe(u8, case.adoc),
                    .expected = try expectedText(allocator, case.asg),
                    .actual = try std.fmt.allocPrint(allocator, "<parse error: {s}>", .{@errorName(err)}),
                });
            }
            continue;
        };
        defer doc.deinit();

        const actual_json = try asg.encodeAlloc(allocator, &doc, root);
        defer allocator.free(actual_json);
        var actual_parsed = try std.json.parseFromSlice(std.json.Value, allocator, actual_json, .{});
        defer actual_parsed.deinit();

        if (asg.jsonValueEql(actual_parsed.value, case.asg)) {
            result.summary.passed += 1;
        } else {
            result.summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .id = try allocator.dupe(u8, case.id),
                    .adoc = try allocator.dupe(u8, case.adoc),
                    .expected = try expectedText(allocator, case.asg),
                    .actual = try allocator.dupe(u8, actual_json),
                });
            }
        }
    }
    return result;
}

fn expectedText(allocator: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    w.write(value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

test "AsciiDoc TCK corpus round-trips through the ASG codec" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer {
        for (failures.items) |f| f.deinit(allocator);
        failures.deinit(allocator);
    }
    const result = try run(allocator, 10, &failures);

    // Silent on a passing run, for the same reason `rst/conformance.zig` is:
    // the build runner's `std.Progress` IPC shares the child's stderr.
    if (result.summary.failed > 0 or result.coverage.semantic != SEMANTIC_BASELINE) {
        std.debug.print(
            "\nAsciiDoc TCK round-trip: {d}/{d} cases ({d} failed)\n" ++
                "  vocabulary: {d} semantic instances, {d} generic (container fallback), {d} text nodes\n",
            .{
                result.summary.passed,    result.summary.total,    result.summary.failed,
                result.coverage.semantic, result.coverage.generic, result.coverage.text_nodes,
            },
        );
        for (failures.items) |f| {
            std.debug.print(
                "\n-- {s} --\nadoc:\n{s}\nexpected:\n{s}\nactual:\n{s}\n",
                .{ f.id, f.adoc, f.expected, f.actual },
            );
        }
    }

    try std.testing.expectEqual(@as(usize, 0), result.summary.failed);
    try std.testing.expectEqual(@as(usize, 13), result.summary.total);

    // The ratchet. `>=`, not `==`: mapping a new ASG shape in `asg.zig` should
    // pass here and then raise `SEMANTIC_BASELINE`, exactly as rST's does.
    try std.testing.expect(result.coverage.semantic >= SEMANTIC_BASELINE);
}

test "AsciiDoc parser reproduces expected ASGs for the TCK corpus" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer {
        for (failures.items) |f| f.deinit(allocator);
        failures.deinit(allocator);
    }
    const result = try runParse(allocator, 10, &failures);

    if (result.summary.passed != PARSE_BASELINE) {
        std.debug.print(
            "\nAsciiDoc parse: {d}/{d} cases match ({d} failed)\n",
            .{ result.summary.passed, result.summary.total, result.summary.failed },
        );
        for (failures.items) |f| {
            std.debug.print(
                "\n-- {s} --\nadoc:\n{s}\nexpected:\n{s}\nactual:\n{s}\n",
                .{ f.id, f.adoc, f.expected, f.actual },
            );
        }
    }

    // `>=`, not `==`: the ratchet climbs as the parser's coverage grows.
    try std.testing.expect(result.summary.passed >= PARSE_BASELINE);
}
