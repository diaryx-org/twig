//! Shared parse-diagnostic machinery — the language-agnostic half of a
//! diagnostic system: locating a byte offset in source text, and rendering the
//! compiler-style `file:line:col: label: message` report with a caret.
//!
//! Ported from fig's `src/parse_diagnostic.zig`, and it keeps fig's division of
//! labor deliberately: each language keeps its OWN `Code` enums and
//! `describe()`/`shortLabel()` teaching messages (the failure modes differ per
//! format) and its own `Diagnostic`/`Report` shapes. Duplicating a three-field
//! struct per language costs nothing; duplicating the caret-rendering BEHAVIOR
//! would. Only the offset-independent-of-code machinery lives here, so there is
//! exactly one implementation of "find line/col for a byte offset" in twig
//! rather than one per language.
//!
//! ── What this is NOT ───────────────────────────────────────────────────────
//! This is PARSE-time: the input is malformed or suspicious. It is not
//! conversion-time lossiness ("djot's multi-line heading has no Markdown
//! spelling"), which is a different system with a different shape — fig keeps
//! that in a separate `diagnostics.zig`, and twig should too when it grows one.
//! The distinction is not stylistic:
//!
//!   - **Different anchor.** A parse diagnostic points at a byte span in the
//!     SOURCE. A conversion warning has no source offset to point at, because
//!     the output text does not exist yet — fig's version carries a node PATH.
//!   - **Different arity.** A parse diagnostic is a fact about one document, so
//!     it can be produced alongside it. A conversion warning is a fact about a
//!     (document, target format, options) triple, so it cannot be stored on a
//!     `Document` at all; it is computed on demand by a read-only pass.
//!
//! Twig already has evidence it wants the second one: `format.zig`'s
//! cross-format round-trip tests exist precisely because a construct the target
//! serializer cannot spell is written as something that reparses into a
//! DIFFERENT node, silently. Those tests are a hand-rolled, per-case stand-in
//! for that pass.
//!
//! ── Twig's existing XML diagnostic ─────────────────────────────────────────
//! `languages/xml/parser.zig` has a `Diagnostic { offset, message }` carrying
//! FREE TEXT rather than a typed code — the opposite of the model here. It is
//! deliberately left alone for now: the halves this module provides (locate,
//! render) are code-agnostic, so XML can adopt them later without changing its
//! message model, and retrofitting it is not on rST's critical path.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 1-based line/column plus the full offending source line.
pub const Location = struct { line: usize, column: usize, line_text: []const u8 };

/// Locate `offset` in `source`. A cursor resting exactly past a newline is
/// ambiguous from the offset alone: it could mean "the problem was noticed
/// while finishing the previous line" (an unclosed construct discovered only at
/// EOF) — report end-of-that-line, not column 1 of an empty next one — OR it
/// could be a token that genuinely STARTS at column 1 of a real next line,
/// which in rST is the common case (a section underline, a `.. ` explicit
/// markup start, and a transition all begin at column 1). Only backtrack in the
/// FORMER case, when there is nothing at `at` to point at instead (EOF, or
/// another blank line); a real token at column 1 must be attributed to ITS OWN
/// line, never silently reattributed to the one before it.
pub fn locateOffset(source: []const u8, offset: usize) Location {
    var at = @min(offset, source.len);
    if (at > 0 and source[at - 1] == '\n' and
        (at >= source.len or source[at] == '\n' or source[at] == '\r'))
    {
        at -= 1;
    }
    var line: usize = 1;
    var line_start: usize = 0;
    for (source[0..at], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    return .{ .line = line, .column = at - line_start + 1, .line_text = source[line_start..line_end] };
}

/// The 1-based line number `offset` falls on — `locateOffset(...).line` without
/// the line-text scan, for callers that only need the number.
///
/// docutils records exactly this on every `<system_message>` (`line="3"`), so
/// the rST projection needs it; nothing else about a diagnostic's presentation
/// does.
pub fn lineOf(source: []const u8, offset: usize) usize {
    return locateOffset(source, offset).line;
}

/// The compiler-style report every language shares: `file:line:col: <label>:
/// <message>`, then the offending source line and a caret marking the column.
pub fn renderReport(
    w: *std.Io.Writer,
    loc: Location,
    file: []const u8,
    label: []const u8,
    message: []const u8,
) std.Io.Writer.Error!void {
    try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file, loc.line, loc.column, label, message });
    // The offending line, capped so a pathological line can't flood the
    // terminal. The caret line mirrors tabs so it stays aligned under them.
    const max_shown = 160;
    const shown = loc.line_text[0..@min(loc.line_text.len, max_shown)];
    if (shown.len == 0) return; // EOF/blank line: nothing to point into
    try w.print("    {s}{s}\n", .{ shown, if (shown.len < loc.line_text.len) "…" else "" });
    if (loc.column - 1 <= shown.len) {
        try w.writeAll("    ");
        for (shown[0 .. loc.column - 1]) |c| try w.writeByte(if (c == '\t') '\t' else ' ');
        try w.writeAll("^\n");
    }
}

/// `renderReport`, allocating the result. Caller owns the returned bytes.
pub fn renderReportAlloc(
    allocator: Allocator,
    source: []const u8,
    offset: usize,
    file: []const u8,
    label: []const u8,
    message: []const u8,
) Allocator.Error![]u8 {
    const loc = locateOffset(source, offset);
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    renderReport(&aw.writer, loc, file, label, message) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// A fully-resolved diagnostic ready for CLI/LSP rendering — language-agnostic.
/// Pairs a parse-time `[offset, end)` span with the language's own
/// `describe(code)` (long teaching message) and `shortLabel(code)` (a few words,
/// for a caret annotation) strings, computed once right after parsing. Any
/// generic consumer then needs no per-language knowledge at all.
pub const Rendered = struct {
    offset: usize,
    end: ?usize = null,
    message: []const u8,
    short_label: []const u8,
};

const testing = std.testing;

test "locateOffset finds line/column and backtracks past a trailing newline" {
    const src = "abc\ndef\nghi";
    var loc = locateOffset(src, 5); // 'e' on line 2
    try testing.expectEqual(@as(usize, 2), loc.line);
    try testing.expectEqual(@as(usize, 2), loc.column);
    try testing.expectEqualStrings("def", loc.line_text);

    // Resting exactly past a newline at true EOF reports the end of the
    // PREVIOUS line, not column 1 of an empty next one.
    loc = locateOffset("abc\n", 4);
    try testing.expectEqual(@as(usize, 1), loc.line);
    try testing.expectEqual(@as(usize, 4), loc.column);

    // But an offset right after a newline that starts a line with REAL content
    // must NOT be backtracked — in rST this is the common case, since section
    // underlines and explicit markup both begin at column 1.
    loc = locateOffset("Title\n=====\n", 6);
    try testing.expectEqual(@as(usize, 2), loc.line);
    try testing.expectEqual(@as(usize, 1), loc.column);
    try testing.expectEqualStrings("=====", loc.line_text);
}

test "lineOf is locateOffset's line number" {
    try testing.expectEqual(@as(usize, 3), lineOf("a\nb\nc\n", 4));
}

test "renderReportAlloc renders file:line:col plus the source line and caret" {
    const rendered = try renderReportAlloc(
        testing.allocator,
        "Line 1.\n    Indented.\n",
        8,
        "test.rst",
        "error",
        "Unexpected indentation.",
    );
    defer testing.allocator.free(rendered);
    // The caret sits at column 1 — on the indentation itself, which is what
    // `Unexpected indentation.` is actually complaining about.
    try testing.expectEqualStrings(
        "test.rst:2:1: error: Unexpected indentation.\n" ++
            "        Indented.\n" ++
            "    ^\n",
        rendered,
    );
}
