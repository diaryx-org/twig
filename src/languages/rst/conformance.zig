//! The reStructuredText conformance harness: runs the vendored docutils corpus
//! (`testdata/docutils-rst-corpus.json`, 713 cases from docutils 0.21.2's own
//! `test/test_parsers/test_rst` — see `scripts/extract-rst-corpus.py` for how it
//! was lifted out of Python source) against `doctree.zig`'s codec.
//!
//! ── What it asserts TODAY, before a parser exists ──────────────────────────
//! There is no rST parser yet, so there is nothing to compare a parse against.
//! What there IS to check is the comparison format itself, and that turns out
//! to be most of the risk: the corpus's expectations are docutils DOCTREES, and
//! a harness that mishandles them would report green against a parser that is
//! wrong. So the assertion is the codec round-trip —
//! `encode(decode(expected)) == expected` over all 713 — which pins the pformat
//! grammar against every shape real docutils output takes, and, through
//! `Coverage`, measures how much of docutils' element vocabulary twig's shared
//! `AST` can hold semantically rather than behind the `container` escape hatch.
//!
//! That second number is the point. It is the input the parser work needs
//! ("which docutils elements have nowhere to live in twig's `Kind` today?"),
//! and it is a RATCHET: `SEMANTIC_BASELINE` pins it, so mapping a new element
//! in `doctree.zig` moves the number up and a regression fails the build. The
//! CommonMark harness climbed the same way (`markdown/conformance.zig`'s
//! `BASELINE`), from 496 to the full 652.
//!
//! ── What it will assert once the parser lands ──────────────────────────────
//! `rst.parse(source)` → `encode` → compare against `case.doctree`, with the
//! round-trip check retained as the codec's own regression test. `asserts_error`
//! marks the 219 cases whose expectation contains a `<system_message>`; those
//! need the diagnostics projection described in `rst.zig`'s scope statement
//! before they can be compared, and are counted separately here so the two
//! populations never blur together.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const doctree = @import("doctree.zig");
const system_message = @import("system_message.zig");

const corpus_json = @embedFile("testdata/docutils-rst-corpus.json");

/// Ratchet floor: docutils element instances across the whole corpus that
/// decode to a twig SEMANTIC kind rather than a generic `container` — 4075 of
/// 5682 (72%), against 2989 text nodes, up from 3185 at the initial harness,
/// 3378 after the free half of the hyperlink cluster, and 3450 after the
/// citation and substitution vocabulary.
///
/// The last +625 is the table subtree, the biggest single mapping the corpus
/// has to give and the only one that had to move as a unit: `entry` 266,
/// `colspec` 142, `row` 124, `table` 65, and the 18 `title` elements that are a
/// table's caption. A further 142 (`tgroup` 65, `tbody` 65, `thead` 12) are
/// DISSOLVED rather than mapped — they produce no twig node, so they count in
/// neither total; see `doctree.Coverage.dissolved`. The last 10 are docutils'
/// OTHER caption element, `<caption>`, which is a figure's — mapped alongside
/// because it lands on the same twig kind from the other direction.
///
/// See this file's module doc comment. Raise it whenever `doctree.zig`'s decode
/// table grows a row; never lower it.
///
/// The test prints the full per-element coverage table whenever the live count
/// DIFFERS from this floor in either direction, so mapping a new element both
/// shows you what moved and tells you the number to put here.
pub const SEMANTIC_BASELINE: u32 = 4142;

/// Tag-shaped text lines whose name is not a docutils element, corpus-wide.
/// This is EXACTLY one — an option list documenting `--source-url=<URL>`, whose
/// `<option_argument>` has the text child `<URL>` (see `doctree.zig`'s "one
/// genuine ambiguity"). Pinned rather than merely reported: the decoder resolves
/// the ambiguity by consulting a closed element vocabulary, so if a corpus
/// refresh introduces an element missing from `doctree.Tag`, every instance of
/// it silently becomes text — and this count is what notices.
pub const UNKNOWN_TAG_SHAPED_TEXT: u32 = 1;

/// One extracted docutils test case. Mirrors the JSON emitted by
/// `scripts/extract-rst-corpus.py`; `provenance` is skipped via
/// `ignore_unknown_fields`.
pub const Case = struct {
    /// Path of the docutils test module, relative to `test/test_parsers/test_rst`.
    file: []const u8,
    /// The `totest` key the case was listed under.
    group: []const u8,
    /// Index within that group.
    index: u32,
    /// Line in the docutils source the case starts at — for locating a failure
    /// upstream.
    line: u32,
    /// The reStructuredText input.
    rst: []const u8,
    /// The expected doctree, as `document.pformat()` writes it.
    doctree: []const u8,
    /// Whether the expectation contains a `<system_message>` — i.e. docutils
    /// reports a problem for this input. 219 of 713.
    asserts_error: bool,
};

const Corpus = struct { cases: []const Case };

pub const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    /// Of `total`, how many expectations contain a `<system_message>`.
    asserts_error: usize = 0,
};

/// Per-`totest`-group tallies — the breakdown that says WHICH constructs a
/// regression landed in, rather than just how many cases moved.
pub const GroupStat = struct {
    file: []const u8,
    group: []const u8,
    passed: usize = 0,
    total: usize = 0,
};

/// A fully owned record of one failing case. Everything is duped rather than
/// borrowed from the `std.json` parse (which `run` frees before returning), so
/// a `Failure` outlives the run — the same contract
/// `djot/conformance.zig`'s `Failure` has.
pub const Failure = struct {
    file: []const u8,
    group: []const u8,
    index: u32,
    line: u32,
    rst: []const u8,
    expected: []const u8,
    actual: []const u8,

    pub fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.file);
        allocator.free(self.group);
        allocator.free(self.rst);
        allocator.free(self.expected);
        allocator.free(self.actual);
    }
};

pub const RunResult = struct {
    summary: Summary = .{},
    coverage: doctree.Coverage = .{},
    groups: std.ArrayList(GroupStat) = .empty,

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        for (self.groups.items) |g| {
            allocator.free(g.file);
            allocator.free(g.group);
        }
        self.groups.deinit(allocator);
    }
};

/// Decode every expected doctree and encode it straight back, collecting the
/// round-trip tally, the vocabulary coverage, and (up to `max_failures`)
/// detailed failure records.
pub fn run(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !RunResult {
    var parsed = try std.json.parseFromSlice(Corpus, allocator, corpus_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var result: RunResult = .{};
    errdefer result.deinit(allocator);

    for (parsed.value.cases) |case| {
        result.summary.total += 1;
        if (case.asserts_error) result.summary.asserts_error += 1;
        const stat = try groupStat(allocator, &result.groups, case);
        stat.total += 1;

        const actual = roundTrip(allocator, case.doctree, &result.coverage) catch |err|
            try std.fmt.allocPrint(allocator, "<decode error: {s}>", .{@errorName(err)});
        // `groupStat` may have grown (and thus reallocated) `result.groups`
        // before this point, but not since — `stat` is still live here.
        if (std.mem.eql(u8, actual, case.doctree)) {
            result.summary.passed += 1;
            stat.passed += 1;
            allocator.free(actual);
        } else {
            result.summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .file = try allocator.dupe(u8, case.file),
                    .group = try allocator.dupe(u8, case.group),
                    .index = case.index,
                    .line = case.line,
                    .rst = try allocator.dupe(u8, case.rst),
                    .expected = try allocator.dupe(u8, case.doctree),
                    .actual = actual,
                });
            } else {
                allocator.free(actual);
            }
        }
    }
    return result;
}

fn roundTrip(allocator: Allocator, expected: []const u8, coverage: *doctree.Coverage) ![]u8 {
    var ast = try doctree.decode(allocator, expected, coverage);
    defer ast.deinit();
    return doctree.encodeAlloc(allocator, &ast);
}

/// The stat row for `case`'s group, appending one if this is its first case.
fn groupStat(allocator: Allocator, groups: *std.ArrayList(GroupStat), case: Case) !*GroupStat {
    for (groups.items) |*g| {
        if (std.mem.eql(u8, g.file, case.file) and std.mem.eql(u8, g.group, case.group)) return g;
    }
    // Duped because `case` borrows the JSON parse, which `run` frees.
    try groups.append(allocator, .{
        .file = try allocator.dupe(u8, case.file),
        .group = try allocator.dupe(u8, case.group),
    });
    return &groups.items[groups.items.len - 1];
}

/// Write the vocabulary coverage table: per docutils element, how many
/// instances decoded to a semantic twig kind versus the `container` fallback.
/// This is the harness's real product for the parser work, so it is a public
/// helper rather than something buried in the test's failure path.
pub fn writeCoverage(w: *std.Io.Writer, coverage: doctree.Coverage) std.Io.Writer.Error!void {
    try w.print(
        "  vocabulary: {d}/{d} element instances decode to a semantic kind " ++
            "({d} generic containers, {d} dissolved), {d} text nodes\n",
        .{
            coverage.semanticTotal(),
            coverage.elementTotal(),
            coverage.genericTotal(),
            coverage.dissolvedTotal(),
            coverage.text_nodes,
        },
    );
    try w.writeAll("  unmapped elements, by instance count:\n");
    // A simple selection sort over ~95 slots — this only runs on failure.
    var printed = std.EnumSet(doctree.Tag).initEmpty();
    while (true) {
        var best: ?doctree.Tag = null;
        var best_n: u32 = 0;
        for (std.enums.values(doctree.Tag)) |tag| {
            if (printed.contains(tag)) continue;
            const n = coverage.generic[@intFromEnum(tag)];
            if (n > best_n) {
                best = tag;
                best_n = n;
            }
        }
        const tag = best orelse break;
        printed.insert(tag);
        try w.print("    {d:>5}  {s}\n", .{ best_n, tag.name() });
    }
}

/// Tier A message instances in the corpus that `system_message.recognize`
/// claims and `system_message.write` reproduces byte-for-byte: 158 of the 299
/// messages, clearing 107 of the 219 error-asserting cases outright. Ratchets
/// like `SEMANTIC_BASELINE`. The remainder are Tier B (107 messages, 80 cases —
/// directive/role machinery, deferred to the directive milestone) and Tier C
/// (34 messages, 32 cases — Python implementation leakage, out of scope). See
/// `diagnostic.zig` for that split and why it falls where it does.
pub const MESSAGE_BASELINE: u32 = 158;

/// Every `<system_message>` in the corpus, tallied by whether twig can account
/// for its wording.
pub const MessageStats = struct {
    total: u32 = 0,
    recognized: u32 = 0,
    /// Recognized but re-written differently — always a bug, never a scope gap.
    mismatched: u32 = 0,
    /// A message whose paragraph is not a lone text run (an inline element
    /// inside it, or no paragraph at all). Counted rather than assumed absent.
    unreadable: u32 = 0,
    /// Cases in which EVERY message is recognized — the number that matters for
    /// the corpus ceiling, since one unclaimed message blocks a whole case.
    cases_fully_recognized: u32 = 0,
    /// Cases with at least one message, i.e. `Case.asserts_error`.
    cases_with_messages: u32 = 0,
};

/// Walk every decoded case for `<system_message>` nodes and check each one's
/// wording against `system_message.write` ∘ `recognize`. `unclaimed`, when
/// non-null, collects the messages twig has no code for — the worklist for the
/// next tier.
pub fn runMessages(
    allocator: Allocator,
    unclaimed: ?*std.ArrayList([]const u8),
) !MessageStats {
    var parsed = try std.json.parseFromSlice(Corpus, allocator, corpus_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var stats: MessageStats = .{};
    for (parsed.value.cases) |case| {
        if (!case.asserts_error) continue;
        stats.cases_with_messages += 1;
        var ast = try doctree.decode(allocator, case.doctree, null);
        defer ast.deinit();

        var all_claimed = true;
        for (ast.nodes) |node| {
            switch (node.kind) {
                .container => |c| if (!std.mem.eql(u8, c.name, "system_message")) continue,
                else => continue,
            }
            stats.total += 1;

            const text = messageTextOf(&ast, node.id) orelse {
                stats.unreadable += 1;
                all_claimed = false;
                continue;
            };
            const found = system_message.recognize(text) orelse {
                all_claimed = false;
                if (unclaimed) |list| try list.append(allocator, try allocator.dupe(u8, text));
                continue;
            };
            stats.recognized += 1;
            const again = try system_message.writeAlloc(allocator, found.code, found.args);
            defer allocator.free(again);
            if (!std.mem.eql(u8, again, text)) stats.mismatched += 1;
        }
        if (all_claimed) stats.cases_fully_recognized += 1;
    }
    return stats;
}

/// The message text of a `system_message`: its first child is a `<paragraph>`
/// (decoded to `.para`) holding one text run. `null` when it is shaped
/// otherwise.
fn messageTextOf(ast: *const AST, id: AST.Node.Id) ?[]const u8 {
    const para = ast.nodes[id].first_child orelse return null;
    if (ast.nodes[para].kind != .para) return null;
    const text = ast.nodes[para].first_child orelse return null;
    // A lone text run, and nothing after it — an inline element in the message
    // means twig cannot compare it as a flat string.
    if (ast.nodes[text].next_sibling != null) return null;
    return switch (ast.nodes[text].kind) {
        .str => |s| s,
        else => null,
    };
}

test "docutils system_message wording round-trips for every Tier A code" {
    const allocator = std.testing.allocator;
    var unclaimed = std.ArrayList([]const u8).empty;
    defer {
        for (unclaimed.items) |m| allocator.free(m);
        unclaimed.deinit(allocator);
    }
    const stats = try runMessages(allocator, &unclaimed);

    if (stats.mismatched > 0 or stats.recognized != MESSAGE_BASELINE) {
        std.debug.print(
            "\nrST system_message wording: {d}/{d} messages recognized ({d} mismatched, {d} unreadable); " ++
                "{d}/{d} error-asserting cases fully accounted for\n",
            .{
                stats.recognized,      stats.total,
                stats.mismatched,      stats.unreadable,
                stats.cases_fully_recognized, stats.cases_with_messages,
            },
        );
        // Deduplicated, so the worklist reads as distinct messages rather than
        // instances.
        var seen = std.ArrayList([]const u8).empty;
        defer seen.deinit(allocator);
        outer: for (unclaimed.items) |m| {
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, m)) continue :outer;
            }
            seen.append(allocator, m) catch {};
            std.debug.print("    unclaimed: {s}\n", .{m});
        }
    }

    // A recognized message that does not re-write identically is a bug in the
    // wording table, never a scope gap — so this is zero, not a ratchet.
    try std.testing.expectEqual(@as(u32, 0), stats.mismatched);
    try std.testing.expectEqual(@as(u32, 299), stats.total);
    try std.testing.expect(stats.recognized >= MESSAGE_BASELINE);
}

test "docutils doctree corpus round-trips through the codec" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer {
        for (failures.items) |f| f.deinit(allocator);
        failures.deinit(allocator);
    }
    var result = try run(allocator, 10, &failures);
    defer result.deinit(allocator);

    // Report to stderr only on failure. A passing run stays silent on purpose:
    // under `zig build test` the child's stderr carries the build runner's
    // `std.Progress` IPC, so a raw `std.debug.print` can corrupt that protocol
    // and surface as a confusing `failed command` even when every test passed.
    // On failure the build is already red, so the detail earns its noise.
    //
    // Coverage prints on `!=` rather than `<` so that an IMPROVEMENT is loud
    // too: the ratchet assertion below is `>=` and would otherwise pass in
    // silence, leaving `SEMANTIC_BASELINE` stale and the new number unseen. The
    // table is this harness's product, and this is when you want to read it.
    if (result.summary.failed > 0 or result.coverage.semanticTotal() != SEMANTIC_BASELINE) {
        std.debug.print(
            "\nrST doctree round-trip: {d}/{d} cases ({d} failed; {d} of the corpus expects a system_message)\n",
            .{ result.summary.passed, result.summary.total, result.summary.failed, result.summary.asserts_error },
        );
        var report: std.Io.Writer.Allocating = .init(allocator);
        defer report.deinit();
        writeCoverage(&report.writer, result.coverage) catch {};
        std.debug.print("{s}", .{report.written()});
        for (result.groups.items) |g| {
            if (g.passed == g.total) continue;
            std.debug.print("    {s}::{s}  {d}/{d}\n", .{ g.file, g.group, g.passed, g.total });
        }
        for (failures.items) |f| {
            std.debug.print(
                "\n-- {s}::{s}[{d}] (docutils source line {d}) --\nrST:\n{s}\nexpected:\n{s}\nactual:\n{s}\n",
                .{ f.file, f.group, f.index, f.line, f.rst, f.expected, f.actual },
            );
        }
    }

    // The whole corpus must survive the codec: this is the format-handling
    // guarantee the eventual parser comparison rests on.
    try std.testing.expectEqual(@as(usize, 0), result.summary.failed);
    try std.testing.expectEqual(@as(usize, 713), result.summary.total);

    // The ambiguity heuristic fired exactly where it is known to.
    try std.testing.expectEqual(UNKNOWN_TAG_SHAPED_TEXT, result.coverage.unknown_tag_shaped_text);

    // The ratchet. `>=`, not `==`: mapping a new element in `doctree.zig` should
    // pass here and then raise the floor, exactly as the CommonMark harness's
    // BASELINE climbed.
    try std.testing.expect(result.coverage.semanticTotal() >= SEMANTIC_BASELINE);
}
