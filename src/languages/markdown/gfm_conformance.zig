//! Acceptance test: runs `parse` + the shared `Html` printer against the
//! GitHub-Flavored Markdown spec's EXTENSION examples
//! (`testdata/gfm-spec-0.29-extensions.json`) and reports a pass/total tally
//! broken down by spec section. Sibling of `conformance.zig` (CommonMark
//! 0.31.2) and `languages/djot/conformance.zig`; like both, it asserts zero
//! failures.
//!
//! ── Why only the extensions ────────────────────────────────────────────
//!
//! The vendored suite holds 24 of the GFM spec's ~649 examples: the whole of
//! its five extension sections (Tables, Task list items, Strikethrough,
//! Autolinks, Disallowed Raw HTML) and nothing else. That is deliberate, and
//! it is the single most important thing to know before "completing" this
//! file by vendoring the rest.
//!
//! GFM 0.29 is defined against CommonMark **0.29**. Twig's `conformance.zig`
//! already passes CommonMark **0.31.2**, in full. Those two specs disagree
//! with each other in the core — 0.30 and 0.31 changed real behavior — so
//! importing GFM's core examples would import ~649 assertions pinned to a
//! spec twig has deliberately moved PAST. Every resulting failure would be
//! upstream spec drift rather than a twig bug, and the ratchet below would be
//! measuring the wrong thing while looking rigorous. Core is already covered,
//! at a newer spec, by the sibling suite; the extensions are the part no
//! other suite in this repo can reach — CommonMark has no tables, task lists,
//! or strikethrough at all.
//!
//! If you want the core examples too, the honest move is to bump the whole
//! markdown path to whatever GFM rebases onto (it tracks CommonMark slowly),
//! not to vendor 0.29's core alongside 0.31.2's.
//!
//! ── What this suite pins that no other one can ─────────────────────────
//!
//! It renders through `Markdown.html.renderAlloc` — the real, user-facing
//! path — rather than calling the shared printer with `gfm_render_options`
//! hardcoded. So it covers the DIALECT PLUMBING end to end (`Options.gfm` ->
//! `Document.options.dialect` -> `Html.gfm_render_options`), not just the
//! printer's behavior once it's handed the right flags. A refactor that
//! silently renders GFM documents with CommonMark's conventions fails here,
//! which is precisely the bug class this suite exists to prevent: twig prints
//! djot, markdown, and GFM DISTINCTLY (see `languages/html/html.zig`'s
//! preset block), and only an end-to-end assertion can hold that line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");
const md_html = @import("html.zig");
const options_mod = @import("options.zig");

/// The GFM spec's five extension sections, extracted from cmark-gfm's
/// `test/spec.txt` (version 0.29, dated 2019-04-06) at
/// `https://raw.githubusercontent.com/github/cmark-gfm/master/test/spec.txt`
/// — see this file's git log for the exact vendoring commit if the upstream
/// URL ever moves. Same field shape as the CommonMark suite's JSON, and
/// `example` keeps the spec's OWN numbering (tables are 198-205, and so on),
/// so a failure here can be looked up directly at
/// `https://github.github.com/gfm/#example-198`.
const spec_json = @embedFile("testdata/gfm-spec-0.29-extensions.json");

/// Ratchet floor, mirroring `conformance.zig`'s: the whole vendored suite, so
/// `passed >= BASELINE` is equivalent to zero failures. Keep it at 24 — a
/// drop means a real regression in a construct that used to work.
///
/// The climb to 24/24 from the 11/24 this scored when first written:
///   - Autolinks (8 -> 11): the `ftp://` scheme; GFM's `&entity;`-shaped
///     trailing-suffix carve-out (`...&hl;` links `...` and leaves `&hl;`);
///     and GFM's own email-domain grammar, under which a domain ending in
///     `-`/`_` disqualifies the autolink outright instead of being trimmed
///     back to (`inline.zig`'s `scanExtEmailDomain`).
///   - Tables (1 -> 8): `<thead>`/`<tbody>` sectioning and `align=` cell
///     attributes (`Html`'s two markdown presets), plus unescaping `\|` in a
///     cell before inline parsing, so `` `\|` `` yields `<code>|</code>`
///     rather than `<code>\|</code>` (`block.zig`'s `unescapeCellPipes` —
///     a code span's content is verbatim, so the ordinary inline
///     backslash-escape path cannot reach inside it).
///   - Task list items (0 -> 2) and Disallowed Raw HTML (0 -> 1): GFM's
///     `<input>` spelling and the tagfilter (`RenderOptions`).
pub const BASELINE: usize = 24;

const SpecExample = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    start_line: u32,
    end_line: u32,
    section: []const u8,
};

pub const SectionStat = struct {
    name: []const u8,
    passed: usize = 0,
    total: usize = 0,
};

pub const Summary = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

/// A fully owned record of one failing case — `section`/`markdown`/`expected`
/// are duped rather than borrowed from the `std.json`-parsed spec, which is
/// freed before `run` returns; `actual` is already an owned `renderAlloc`
/// result. Mirrors `conformance.zig`'s `Failure`.
pub const Failure = struct {
    example: u32,
    section: []const u8,
    markdown: []const u8,
    expected: []const u8,
    actual: []const u8,

    pub fn deinit(self: Failure, allocator: Allocator) void {
        allocator.free(self.section);
        allocator.free(self.markdown);
        allocator.free(self.expected);
        allocator.free(self.actual);
    }
};

pub const RunResult = struct {
    summary: Summary,
    sections: std.ArrayList(SectionStat),

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        for (self.sections.items) |s| allocator.free(s.name);
        self.sections.deinit(allocator);
    }
};

/// Run the vendored suite, appending up to `max_failures` `Failure` records
/// to `failures` (pass 0 to just tally). Caller owns `failures`' entries and
/// the returned `RunResult`.
pub fn run(allocator: Allocator, max_failures: usize, failures: *std.ArrayList(Failure)) !RunResult {
    var parsed = try std.json.parseFromSlice([]const SpecExample, allocator, spec_json, .{});
    defer parsed.deinit();

    var summary: Summary = .{};
    var sections = std.ArrayList(SectionStat).empty;
    errdefer {
        for (sections.items) |s| allocator.free(s.name);
        sections.deinit(allocator);
    }

    for (parsed.value) |ex| {
        summary.total += 1;

        var section_idx: ?usize = null;
        for (sections.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, ex.section)) {
                section_idx = i;
                break;
            }
        }
        if (section_idx == null) {
            section_idx = sections.items.len;
            // `ex.section` is a slice of the `std.json`-parsed spec, which
            // `run` frees before returning — dupe it so `RunResult.sections`
            // stays valid for the caller.
            try sections.append(allocator, .{ .name = try allocator.dupe(u8, ex.section) });
        }
        const sec = &sections.items[section_idx.?];
        sec.total += 1;

        var doc = markdown.parse(allocator, ex.markdown, options_mod.gfm) catch {
            summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .example = ex.example,
                    .section = try allocator.dupe(u8, ex.section),
                    .markdown = try allocator.dupe(u8, ex.markdown),
                    .expected = try allocator.dupe(u8, ex.html),
                    .actual = try allocator.dupe(u8, "<parse error>"),
                });
            }
            continue;
        };
        defer doc.deinit();

        // Deliberately the real render path, NOT `Html.serializeAllocOpts`
        // with `gfm_render_options` passed by hand: the dialect mapping is
        // part of what this suite pins. See the module doc comment.
        const rendered = try md_html.renderAlloc(allocator, &doc, .{});
        if (std.mem.eql(u8, rendered, ex.html)) {
            summary.passed += 1;
            sec.passed += 1;
            allocator.free(rendered);
        } else {
            summary.failed += 1;
            if (failures.items.len < max_failures) {
                try failures.append(allocator, .{
                    .example = ex.example,
                    .section = try allocator.dupe(u8, ex.section),
                    .markdown = try allocator.dupe(u8, ex.markdown),
                    .expected = try allocator.dupe(u8, ex.html),
                    .actual = rendered,
                });
            } else {
                allocator.free(rendered);
            }
        }
    }

    return .{ .summary = summary, .sections = sections };
}

test "GFM 0.29 extension conformance (full)" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(Failure).empty;
    defer {
        for (failures.items) |f| f.deinit(allocator);
        failures.deinit(allocator);
    }
    var result = try run(allocator, 8, &failures);
    defer result.deinit(allocator);

    // Report to stderr only on failure. A passing run stays silent on
    // purpose: under `zig build test` the child's stderr carries the build
    // runner's `std.Progress` IPC, so a raw `std.debug.print` can corrupt
    // that protocol and surface as a confusing `failed command` even when
    // every test passed. On failure the build is already red, so the detail
    // earns its noise. (Same rationale as `conformance.zig`'s.)
    if (result.summary.failed > 0) {
        std.debug.print(
            "\nGFM extension conformance: {d}/{d} passed ({d} failed)\n",
            .{ result.summary.passed, result.summary.total, result.summary.failed },
        );
        std.debug.print("  by section:\n", .{});
        for (result.sections.items) |s| {
            std.debug.print("    {s:<34} {d}/{d}\n", .{ s.name, s.passed, s.total });
        }
        for (failures.items) |f| {
            std.debug.print(
                "\n  --- example {d} ({s}) — https://github.github.com/gfm/#example-{d}\n",
                .{ f.example, f.section, f.example },
            );
            std.debug.print("  markdown: {s}\n", .{f.markdown});
            std.debug.print("  expected: {s}\n", .{f.expected});
            std.debug.print("  actual:   {s}\n", .{f.actual});
        }
    }

    try std.testing.expect(result.summary.passed >= BASELINE);
    try std.testing.expectEqual(@as(usize, 0), result.summary.failed);
}
