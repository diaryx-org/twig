//! reStructuredText parse diagnostics — twig's OWN record of what went wrong,
//! kept out of the tree.
//!
//! docutils reports parse problems by building `<system_message>` nodes into
//! the doctree, 299 of them across 219 of the corpus's 713 cases. Twig does not:
//! the tree stays markup, and problems are collected in a `Report` sidecar,
//! following fig's model (`fig/src/languages/fig/parser.zig`). A record is a
//! typed `code` plus a byte span plus whatever arguments the message
//! interpolates — the shape an editor or a language server wants, since LSP
//! diagnostics are ranges, not tree positions.
//!
//! ── What is deliberately NOT here ──────────────────────────────────────────
//! Two things a reader might expect, both of which live in
//! `system_message.zig` instead, because both are facts about DOCUTILS' OUTPUT
//! FORMAT rather than about the error:
//!
//!   - **docutils' exact message wording.** Matching it byte-for-byte is a
//!     conformance requirement; twig's own message quality is a separate
//!     concern and should not be hostage to it. `describe`/`shortLabel` below
//!     are twig's, written to fig's name-the-fix contract; docutils' phrasing
//!     is a projection-side table.
//!   - **Where the message sits in the tree.** docutils places a message at
//!     whatever container was current when its parser noticed, which is not
//!     derivable from the byte offset — for `Unexpected indentation.` the
//!     message lands at document level BEFORE the block quote, while the
//!     offending offset is INSIDE that block quote's source range. That rule is
//!     per-code knowledge about a docutils message, so it belongs beside the
//!     wording, not on this record.
//!
//! ── Scope: Tier A ──────────────────────────────────────────────────────────
//! The codes here cover the corpus's CORE PARSER messages — 158 of 299
//! instances, and 107 of the 219 error-asserting cases have NO other tier in
//! them (one unclaimed message blocks a whole case, so that is the number that
//! moves the corpus ceiling). Two further tiers are
//! deliberately absent (see `rst.zig`'s scope statement for the full
//! accounting):
//!
//!   - **Tier B, directive/role machinery** (107 messages, 80 cases). Not
//!     deferred because it is verbose but because its messages are GENERATED
//!     FROM A SCHEMA twig does not have: `%d argument(s) required, %d supplied`,
//!     `unknown option: "%s"`, and `not a positive measure of one of the
//!     following units` are all readouts of a directive's registered arity,
//!     option names, and per-option converter. Twig has no directive registry at
//!     all today (Markdown's `:::note` accepts any name and validates nothing),
//!     and it needs one for PARSING regardless. So Tier B belongs with the
//!     directive milestone, where the messages fall out of the schema for free.
//!   - **Tier C, implementation leakage** (34 messages, 32 cases). Python module
//!     paths, `repr` output, and errno text. Out of scope permanently.
//!
//! One wording fact worth recording, because it is invisible to any survey that
//! reads a doctree line-wise and rejoins with spaces: docutils separates a
//! two-sentence message with a NEWLINE, not a space (`Possible incomplete
//! section title.\nTreating the overline as…`, and every `Malformed table.`
//! detail). The corpus round-trip in `conformance.zig` is what caught it.

const std = @import("std");
const Span = @import("../../span.zig");
const parse_diagnostic = @import("../../parse_diagnostic.zig");

pub const Location = parse_diagnostic.Location;
pub const Rendered = parse_diagnostic.Rendered;

/// How bad a problem is. Four levels rather than fig's two (error/warning)
/// because rST needs four: docutils' reporter grades every message 1–4, and the
/// corpus exercises all of them (57 INFO, 113 WARNING, 113 ERROR, 16 SEVERE).
/// Folding INFO into WARNING or SEVERE into ERROR would make those cases
/// unrepresentable.
pub const Severity = enum {
    info,
    warning,
    err,
    severe,

    /// docutils' numeric `level` attribute.
    pub fn level(self: Severity) u8 {
        return switch (self) {
            .info => 1,
            .warning => 2,
            .err => 3,
            .severe => 4,
        };
    }

    pub fn fromLevel(n: u8) ?Severity {
        return switch (n) {
            1 => .info,
            2 => .warning,
            3 => .err,
            4 => .severe,
            else => null,
        };
    }

    /// docutils' `type` attribute — the uppercase name.
    pub fn typeName(self: Severity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .warning => "WARNING",
            .err => "ERROR",
            .severe => "SEVERE",
        };
    }
};

/// An inline construct whose start-string never found its end-string. One enum
/// rather than six codes because docutils generates all six from one template
/// (`'Inline %s start-string without end-string.'`) and every consumer treats
/// them identically.
pub const InlineConstruct = enum {
    emphasis,
    strong,
    literal,
    /// `` `x` `` / `` :role:`x` `` — docutils calls this "interpreted text or
    /// phrase reference", covering both spellings in one message.
    interpreted_text,
    target,
    substitution_reference,
};

/// A block construct that ended by dedenting instead of by a blank line. Same
/// one-enum-not-N-codes argument as `InlineConstruct`.
pub const BlockConstruct = enum {
    explicit_markup,
    bullet_list,
    enumerated_list,
    definition_list,
    field_list,
    block_quote,
    literal_block,
};

/// Which way a grid/simple table was malformed. docutils composes these as a
/// detail string appended to a bare `Malformed table.`, so they are one code
/// with a detail rather than eight codes.
pub const TableDefect = enum {
    /// No detail — a bare `Malformed table.`
    unspecified,
    parse_incomplete,
    no_bottom_border,
    no_bottom_border_or_blank_line,
    bottom_header_border_mismatch,
    /// These three carry the offending table-relative line number.
    text_in_column_margin,
    column_span_alignment,
    column_span_incomplete,

    /// Whether the defect interpolates a line number.
    pub fn hasLine(self: TableDefect) bool {
        return switch (self) {
            .text_in_column_margin, .column_span_alignment, .column_span_incomplete => true,
            else => false,
        };
    }
};

/// What a code interpolates. A tagged union rather than a bag of optional
/// fields so that a code and its arguments cannot disagree — `Args.none` is a
/// real state, not an empty struct.
///
/// String members BORROW the source (or, in the harness, the message text they
/// were recognized from). Nothing here owns memory.
pub const Args = union(enum) {
    none,
    inline_construct: InlineConstruct,
    block_construct: BlockConstruct,
    /// A hyperlink target name, or the `::` spelling in the literal-block hint.
    name: []const u8,
    /// `Enumerated list start value not ordinal-1: "b" (ordinal 2)`.
    ordinal: struct { expected: u32, text: []const u8, actual: u32 },
    table: struct { defect: TableDefect, line: u32 = 0 },
    /// `"widths" widths do not match the number of columns in table (2).`
    widths: struct { value: []const u8, columns: u32 },
};

/// Tier A: the core-parser problems twig's rST parser reports. Grouped by the
/// construct that failed, which is also how docutils' own reporter is
/// organized.
pub const Code = enum {
    // ── inline markup ──────────────────────────────────────────────────────
    inline_start_string_without_end_string,

    // ── block structure ────────────────────────────────────────────────────
    unexpected_unindent,
    line_block_without_blank_line,
    unexpected_indentation,
    blank_line_required_after_table,
    literal_block_expected,
    inconsistent_literal_block_quoting,
    literal_block_hint_after_definition,

    // ── section titles and transitions ─────────────────────────────────────
    unexpected_section_title,
    unexpected_section_title_or_transition,
    incomplete_section_title,
    possible_incomplete_section_title,
    title_underline_too_short,
    possible_title_underline_too_short,
    title_overline_too_short,
    title_overline_underline_mismatch,
    missing_matching_underline_for_overline,
    invalid_section_title_or_transition_marker,
    title_level_inconsistent,
    possible_title_overline_or_transition,

    // ── enumerated lists ───────────────────────────────────────────────────
    enumerated_list_start_not_ordinal,

    // ── hyperlink targets ──────────────────────────────────────────────────
    duplicate_explicit_target_name,
    duplicate_implicit_target_name,
    malformed_hyperlink_target,

    // ── tables and figures ─────────────────────────────────────────────────
    malformed_table,
    table_widths_mismatch,
    figure_caption_must_be_paragraph,

    /// The severity a code carries unless the parser overrides it. Most codes
    /// have exactly one in the whole corpus; `duplicate_explicit_target_name`
    /// is the exception (docutils grades it WARNING for external targets and
    /// INFO for internal ones), which is why `Diagnostic.severity` is a stored
    /// field rather than derived from the code.
    pub fn defaultSeverity(self: Code) Severity {
        return switch (self) {
            .possible_incomplete_section_title,
            .possible_title_underline_too_short,
            .possible_title_overline_or_transition,
            .enumerated_list_start_not_ordinal,
            .duplicate_implicit_target_name,
            .literal_block_hint_after_definition,
            => .info,

            .inline_start_string_without_end_string,
            .unexpected_unindent,
            .line_block_without_blank_line,
            .blank_line_required_after_table,
            .literal_block_expected,
            .title_underline_too_short,
            .title_overline_too_short,
            .malformed_hyperlink_target,
            .duplicate_explicit_target_name,
            => .warning,

            .unexpected_indentation,
            .inconsistent_literal_block_quoting,
            .invalid_section_title_or_transition_marker,
            .malformed_table,
            .table_widths_mismatch,
            .figure_caption_must_be_paragraph,
            => .err,

            .unexpected_section_title,
            .unexpected_section_title_or_transition,
            .incomplete_section_title,
            .title_overline_underline_mismatch,
            .missing_matching_underline_for_overline,
            .title_level_inconsistent,
            => .severe,
        };
    }
};

/// TWIG's teaching message for a code — not docutils'. Same name-the-fix
/// contract fig's `describe` follows: say what happened AND what to write
/// instead. Argument-free on purpose; the interpolated detail is available on
/// the record for a caller that wants to compose a richer string.
///
/// docutils' phrasing lives in `system_message.zig` and is used only to project
/// a doctree for conformance. Keeping the two apart is what stops the corpus
/// from dictating what twig says to a user.
pub fn describe(code: Code) []const u8 {
    return switch (code) {
        .inline_start_string_without_end_string => "this inline markup was opened but never closed, so it stays literal text; add the matching end-string, or escape the opener with a backslash if you meant it literally",
        .unexpected_unindent => "this block ended by dedenting rather than with a blank line; insert a blank line before the following text",
        .line_block_without_blank_line => "a line block must be followed by a blank line; insert one before the following text",
        .unexpected_indentation => "this line is indented but nothing opened an indented block, so it was read as a block quote; remove the indentation, or add a blank line before it to make the block quote deliberate",
        .blank_line_required_after_table => "a table must be followed by a blank line; insert one before the following text",
        .literal_block_expected => "a paragraph ended with `::` but no indented block followed; indent the literal block, or remove the `::`",
        .inconsistent_literal_block_quoting => "a quoted literal block must use one quoting character throughout; make every line's leading character match the first",
        .literal_block_hint_after_definition => "this looks like a literal block introduced by `::`, but with no blank line it was read as a definition list item; add a blank line if you meant a literal block",
        .unexpected_section_title => "a section title appeared where the enclosing construct cannot contain one; move it to the document body",
        .unexpected_section_title_or_transition => "a section title or transition appeared where the enclosing construct cannot contain one; move it to the document body",
        .incomplete_section_title => "a section title's overline or underline is missing its other half; supply both, or drop the overline",
        .possible_incomplete_section_title => "this overline is shorter than the title text, so it was read as ordinary text rather than a section title; extend it to at least the title's width",
        .title_underline_too_short => "a section title's underline is shorter than the title; extend it to at least the title's width",
        .possible_title_underline_too_short => "this looks like a section underline but is too short for the title, so it was read as ordinary text; extend it to at least the title's width",
        .title_overline_too_short => "a section title's overline is shorter than the title; extend it to at least the title's width",
        .title_overline_underline_mismatch => "a section title's overline and underline use different characters or lengths; make them match",
        .missing_matching_underline_for_overline => "a section title has an overline but no underline; add an underline of the same character and length",
        .invalid_section_title_or_transition_marker => "this punctuation run is neither a valid section underline nor a valid transition; a transition needs at least four repeated characters on its own line",
        .title_level_inconsistent => "this title's underline character implies a section level that does not follow from the preceding sections; reuse the character that already marks this level",
        .possible_title_overline_or_transition => "this punctuation run is too short to be a title overline or a transition, so it was read as ordinary text; use at least four characters",
        .enumerated_list_start_not_ordinal => "this list's first item is not the first ordinal, so it was read as ordinary text; start the list at the first ordinal, or use `#` for auto-numbering",
        .duplicate_explicit_target_name => "two explicit hyperlink targets share a name, so references to it are ambiguous; rename one",
        .duplicate_implicit_target_name => "two section titles produce the same implicit target name, so references to it are ambiguous; add an explicit target to disambiguate",
        .malformed_hyperlink_target => "this explicit markup starts like a hyperlink target but does not parse as one; check the `.. _name: link` form",
        .malformed_table => "this table's borders do not form a consistent grid; check that every row's `+` and `|` line up with the column borders",
        .table_widths_mismatch => "the `:widths:` option lists a different number of entries than the table has columns; supply one width per column",
        .figure_caption_must_be_paragraph => "a figure's first body element must be a paragraph (the caption) or an empty comment; make it one",
    };
}

/// A short noun phrase for a caret annotation, rustc-style — distinct from
/// `describe`'s full teaching sentence, and for the same reason fig keeps both.
pub fn shortLabel(code: Code) []const u8 {
    return switch (code) {
        .inline_start_string_without_end_string => "unclosed inline markup",
        .unexpected_unindent => "unexpected unindent",
        .line_block_without_blank_line => "missing blank line",
        .unexpected_indentation => "unexpected indentation",
        .blank_line_required_after_table => "missing blank line",
        .literal_block_expected => "no literal block",
        .inconsistent_literal_block_quoting => "inconsistent quoting",
        .literal_block_hint_after_definition => "read as a definition",
        .unexpected_section_title => "unexpected section title",
        .unexpected_section_title_or_transition => "unexpected title or transition",
        .incomplete_section_title => "incomplete section title",
        .possible_incomplete_section_title => "overline too short",
        .title_underline_too_short => "underline too short",
        .possible_title_underline_too_short => "underline too short",
        .title_overline_too_short => "overline too short",
        .title_overline_underline_mismatch => "overline/underline mismatch",
        .missing_matching_underline_for_overline => "missing underline",
        .invalid_section_title_or_transition_marker => "invalid marker",
        .title_level_inconsistent => "inconsistent title level",
        .possible_title_overline_or_transition => "too short for a transition",
        .enumerated_list_start_not_ordinal => "not the first ordinal",
        .duplicate_explicit_target_name => "duplicate target name",
        .duplicate_implicit_target_name => "duplicate implicit name",
        .malformed_hyperlink_target => "malformed target",
        .malformed_table => "malformed table",
        .table_widths_mismatch => "widths/columns mismatch",
        .figure_caption_must_be_paragraph => "caption must be a paragraph",
    };
}

/// One reported problem. `span` is the offending source range — the caret
/// anchor, the LSP range, and the source of both docutils' `line` attribute and
/// the quoted excerpt it attaches (132 of the corpus's messages carry a
/// `<literal_block>` of the offending text, which is exactly `source[span]`).
/// That is why the span is on the record rather than a bare offset.
pub const Diagnostic = struct {
    code: Code,
    span: Span,
    /// Stored rather than derived from `code`: docutils grades one code two
    /// ways (see `Code.defaultSeverity`). Construct with `init` to take the
    /// default.
    severity: Severity,
    args: Args = .none,

    pub fn init(code: Code, span: Span, args: Args) Diagnostic {
        return .{ .code = code, .span = span, .severity = code.defaultSeverity(), .args = args };
    }

    /// 1-based line/column of the span's start, plus the offending line.
    pub fn locate(self: Diagnostic, source: []const u8) Location {
        return parse_diagnostic.locateOffset(source, self.span.start);
    }

    /// The offending source text — what docutils quotes into a message's
    /// `<literal_block>` child.
    pub fn excerpt(self: Diagnostic, source: []const u8) []const u8 {
        return Span.of(u8, self.span, source);
    }

    /// Render `file:line:col: <severity>: <twig's message>` + source line +
    /// caret.
    pub fn renderAlloc(
        self: Diagnostic,
        allocator: std.mem.Allocator,
        source: []const u8,
        file: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        const label = switch (self.severity) {
            .info => "info",
            .warning => "warning",
            .err => "error",
            .severe => "error",
        };
        return parse_diagnostic.renderReportAlloc(
            allocator,
            source,
            self.span.start,
            file,
            label,
            describe(self.code),
        );
    }
};

/// Everything a parse reports besides the tree.
///
/// One list, not fig's `errors`/`warnings` split: rST has four severities
/// rather than two, and — unlike fig, where an error stops the parse — docutils'
/// parser RECOVERS from every one of these and keeps going, so there is no
/// "the diagnostic that ended the parse" to single out. Severity is a field to
/// filter on, and source order is the order they were reported in.
pub const Report = struct {
    diagnostics: []const Diagnostic = &.{},

    pub fn count(self: Report, severity: Severity) usize {
        var n: usize = 0;
        for (self.diagnostics) |d| {
            if (d.severity == severity) n += 1;
        }
        return n;
    }

    /// Whether anything at or above `severity` was reported — the question a
    /// `--strict` flag asks.
    pub fn hasAtLeast(self: Report, severity: Severity) bool {
        for (self.diagnostics) |d| {
            if (@intFromEnum(d.severity) >= @intFromEnum(severity)) return true;
        }
        return false;
    }
};

const testing = std.testing;

test "every code has a describe and a shortLabel, and they are distinct" {
    // Exhaustive switches mean a new code cannot compile without both; this
    // catches the other failure, a copy-pasted duplicate.
    for (std.enums.values(Code)) |a| {
        try testing.expect(describe(a).len > 0);
        try testing.expect(shortLabel(a).len > 0);
        for (std.enums.values(Code)) |b| {
            if (a == b) continue;
            try testing.expect(!std.mem.eql(u8, describe(a), describe(b)));
        }
    }
}

test "severity maps to docutils levels and back" {
    for (std.enums.values(Severity)) |s| {
        try testing.expectEqual(s, Severity.fromLevel(s.level()).?);
    }
    try testing.expectEqualStrings("SEVERE", Severity.severe.typeName());
    try testing.expect(Severity.fromLevel(0) == null);
}

test "init takes the code's default severity, which stays overridable" {
    const span = Span.init(4, 9);
    var d = Diagnostic.init(.duplicate_explicit_target_name, span, .{ .name = "target" });
    try testing.expectEqual(Severity.warning, d.severity);
    // docutils grades the same code INFO for an internal target — the reason
    // severity is stored rather than derived.
    d.severity = .info;
    try testing.expectEqual(Severity.info, d.severity);
}

test "a diagnostic's excerpt is the offending source, which is what docutils quotes" {
    const src = "Line 1.\n    Indented.\n";
    const d = Diagnostic.init(.unexpected_indentation, Span.init(8, 21), .none);
    try testing.expectEqualStrings("    Indented.", d.excerpt(src));
    try testing.expectEqual(@as(usize, 2), d.locate(src).line);
}

test "Report filters by severity" {
    const r: Report = .{ .diagnostics = &.{
        Diagnostic.init(.unexpected_indentation, Span.init(0, 1), .none), // err
        Diagnostic.init(.duplicate_implicit_target_name, Span.init(2, 3), .{ .name = "x" }), // info
    } };
    try testing.expectEqual(@as(usize, 1), r.count(.err));
    try testing.expectEqual(@as(usize, 1), r.count(.info));
    try testing.expect(r.hasAtLeast(.err));
    try testing.expect(!r.hasAtLeast(.severe));
}

test "renderAlloc uses twig's wording, not docutils'" {
    const src = "Line 1.\n    Indented.\n";
    const d = Diagnostic.init(.unexpected_indentation, Span.init(8, 21), .none);
    const out = try d.renderAlloc(testing.allocator, src, "test.rst");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "test.rst:2:1: error:") != null);
    // docutils would say exactly "Unexpected indentation."; twig names the fix.
    try testing.expect(std.mem.indexOf(u8, out, "add a blank line") != null);
}
