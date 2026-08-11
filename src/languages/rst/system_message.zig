//! The docutils `<system_message>` projection — everything about matching
//! docutils' ERROR OUTPUT FORMAT, kept apart from twig's own diagnostics.
//!
//! `diagnostic.zig` holds twig's record of a parse problem: a typed `Code`, a
//! byte span, and arguments. This file holds the two things that are facts
//! about docutils rather than about the error, and would contaminate that
//! record if they lived on it:
//!
//!   1. **docutils' exact message wording** (`write`). Conformance needs it
//!      byte-for-byte; twig's user-facing phrasing (`diagnostic.describe`) is a
//!      separate concern that should not be dictated by a corpus.
//!   2. **Tree placement** — see "Placement" below.
//!
//! ── How this is validated before a parser exists ───────────────────────────
//! The same trick that validated the doctree codec, one layer up. There is no
//! parser, so there are no diagnostics to project; but the corpus contains 299
//! real docutils messages, so `recognize` goes the other way — it parses
//! docutils' wording back into a `(Code, Args)` pair — and the test asserts
//! `write(recognize(m)) == m` for every one it claims. That makes the `Code`
//! enum's completeness and the wording's exactness both corpus-driven rather
//! than transcribed, and a message twig cannot yet account for simply stays
//! unrecognized and counted.
//!
//! `recognize` is a HARNESS direction, not a parser one: nothing in twig will
//! ever need to read a docutils message at runtime. It exists so that `write`
//! has an inverse to be checked against.
//!
//! ── Placement is not implemented yet, on purpose ───────────────────────────
//! Projecting a diagnostic all the way into a doctree needs one more thing: an
//! insertion point. docutils appends a message to whatever container its parser
//! had open when it noticed, which is NOT derivable from the byte offset — for
//! `Unexpected indentation.` the message lands at document level BEFORE the
//! block quote, while the offending offset falls INSIDE that block quote's
//! source range. 249 of 299 sit at document level and 50 nest (section 14,
//! definition 12, topic 5, block_quote 5, footnote 3, and eight more with one
//! or two each).
//!
//! That rule is per-code knowledge about a docutils message, so it belongs
//! here beside the wording rather than on `Diagnostic`. It is deferred rather
//! than guessed: with no parser there is no tree to insert into, so any rule
//! written now would be untestable. `subtree` below builds the message NODE,
//! which is the half that can be checked today; choosing its parent is the half
//! that waits.
//!
//! ── Two attributes that are not ours to invent ─────────────────────────────
//! 50 of the corpus's messages carry `backrefs` and 35 carry `ids`: docutils
//! links a message to the `<problematic>` node that points back at it. Those
//! are outputs of name/id resolution, not of the diagnostic, so `Extras` below
//! carries them verbatim from a recognized message rather than deriving them.
//! Reproducing them for a real parse is part of the id-generation work that
//! `target`/`problematic` mapping will need anyway.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("../../ast/ast.zig");
const diagnostic = @import("diagnostic.zig");
const Code = diagnostic.Code;
const Args = diagnostic.Args;
const Severity = diagnostic.Severity;

// ── docutils' wording ──────────────────────────────────────────────────────

/// docutils' spelling of an inline construct inside
/// `Inline %s start-string without end-string.`
fn inlineName(c: diagnostic.InlineConstruct) []const u8 {
    return switch (c) {
        .emphasis => "emphasis",
        .strong => "strong",
        .literal => "literal",
        .interpreted_text => "interpreted text or phrase reference",
        .target => "target",
        // Spelled with the underscore — it is the node name, not prose.
        .substitution_reference => "substitution_reference",
    };
}

/// docutils' spelling of a block construct inside
/// `%s ends without a blank line; unexpected unindent.` — sentence-cased,
/// because it opens the sentence.
fn blockName(c: diagnostic.BlockConstruct) []const u8 {
    return switch (c) {
        .explicit_markup => "Explicit markup",
        .bullet_list => "Bullet list",
        .enumerated_list => "Enumerated list",
        .definition_list => "Definition list",
        .field_list => "Field list",
        .block_quote => "Block quote",
        .literal_block => "Literal block",
    };
}

/// The detail docutils appends after a bare `Malformed table.`
fn tableDetail(d: diagnostic.TableDefect) []const u8 {
    return switch (d) {
        .unspecified => "",
        // Not a typo: docutils prefixes every detail with `Malformed table.`
        // and this particular detail repeats the phrase.
        .parse_incomplete => "Malformed table; parse incomplete.",
        .no_bottom_border => "No bottom table border found.",
        .no_bottom_border_or_blank_line => "No bottom table border found or no blank line after table bottom.",
        .bottom_header_border_mismatch => "Bottom/header table border does not match top border.",
        .text_in_column_margin => "Text in column margin in table line {d}.",
        .column_span_alignment => "Column span alignment problem in table line {d}.",
        .column_span_incomplete => "Column span incomplete in table line {d}.",
    };
}

/// Write docutils' exact message text for `code`/`args` — what goes in the
/// `<system_message>`'s first `<paragraph>`.
///
/// Several of these end without a period (`Enumerated list start value not
/// ordinal-1: "b" (ordinal 2)`) or begin lowercase (`malformed hyperlink
/// target.`). Those are docutils' own inconsistencies, reproduced deliberately:
/// this function's contract is byte-exactness, not house style.
pub fn write(w: *Writer, code: Code, args: Args) Writer.Error!void {
    switch (code) {
        .inline_start_string_without_end_string => try w.print(
            "Inline {s} start-string without end-string.",
            .{inlineName(args.inline_construct)},
        ),
        .unexpected_unindent => try w.print(
            "{s} ends without a blank line; unexpected unindent.",
            .{blockName(args.block_construct)},
        ),
        .line_block_without_blank_line => try w.writeAll("Line block ends without a blank line."),
        .unexpected_indentation => try w.writeAll("Unexpected indentation."),
        .blank_line_required_after_table => try w.writeAll("Blank line required after table."),
        .literal_block_expected => try w.writeAll("Literal block expected; none found."),
        .inconsistent_literal_block_quoting => try w.writeAll("Inconsistent literal block quoting."),
        .literal_block_hint_after_definition => try w.print(
            "Blank line missing before literal block (after the \"{s}\")? Interpreted as a definition list item.",
            .{args.name},
        ),

        .unexpected_section_title => try w.writeAll("Unexpected section title."),
        .unexpected_section_title_or_transition => try w.writeAll("Unexpected section title or transition."),
        .incomplete_section_title => try w.writeAll("Incomplete section title."),
        .possible_incomplete_section_title => try w.writeAll(
            "Possible incomplete section title.\nTreating the overline as ordinary text because it's so short.",
        ),
        .title_underline_too_short => try w.writeAll("Title underline too short."),
        .possible_title_underline_too_short => try w.writeAll(
            "Possible title underline, too short for the title.\nTreating it as ordinary text because it's so short.",
        ),
        .title_overline_too_short => try w.writeAll("Title overline too short."),
        .title_overline_underline_mismatch => try w.writeAll("Title overline & underline mismatch."),
        .missing_matching_underline_for_overline => try w.writeAll(
            "Missing matching underline for section title overline.",
        ),
        .invalid_section_title_or_transition_marker => try w.writeAll("Invalid section title or transition marker."),
        // No period; docutils follows it with the offending literal block.
        .title_level_inconsistent => try w.writeAll("Title level inconsistent:"),
        .possible_title_overline_or_transition => try w.writeAll(
            "Unexpected possible title overline or transition.\nTreating it as ordinary text because it's so short.",
        ),

        // No trailing period, and the parenthetical is docutils' own.
        .enumerated_list_start_not_ordinal => try w.print(
            "Enumerated list start value not ordinal-{d}: \"{s}\" (ordinal {d})",
            .{ args.ordinal.expected, args.ordinal.text, args.ordinal.actual },
        ),

        .duplicate_explicit_target_name => try w.print("Duplicate explicit target name: \"{s}\".", .{args.name}),
        .duplicate_implicit_target_name => try w.print("Duplicate implicit target name: \"{s}\".", .{args.name}),
        // Lowercase in docutils, unlike every sibling message.
        .malformed_hyperlink_target => try w.writeAll("malformed hyperlink target."),

        .malformed_table => {
            try w.writeAll("Malformed table.");
            const detail = tableDetail(args.table.defect);
            if (detail.len == 0) return;
            try w.writeByte('\n');
            if (args.table.defect.hasLine()) {
                // The three line-bearing details share one shape: everything up
                // to `{d}`, the number, then everything after.
                const at = std.mem.indexOf(u8, detail, "{d}").?;
                try w.writeAll(detail[0..at]);
                try w.print("{d}", .{args.table.line});
                try w.writeAll(detail[at + 3 ..]);
            } else {
                try w.writeAll(detail);
            }
        },
        .table_widths_mismatch => try w.print(
            "\"{s}\" widths do not match the number of columns in table ({d}).",
            .{ args.widths.value, args.widths.columns },
        ),
        .figure_caption_must_be_paragraph => try w.writeAll("Figure caption must be a paragraph or empty comment."),
    }
}

/// `write` into an owned buffer.
pub fn writeAlloc(allocator: Allocator, code: Code, args: Args) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(&out.writer, code, args) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ── the inverse, for validation ────────────────────────────────────────────

/// A message parsed back out of docutils' wording. `Args`' string members
/// BORROW `text`.
pub const Recognized = struct { code: Code, args: Args };

/// Messages with no interpolation: an exact-match table. Kept as data rather
/// than a `switch` so `recognize` and `write` cannot drift — the test below
/// walks every `Code` and checks the two agree.
const literals = [_]struct { code: Code, text: []const u8 }{
    .{ .code = .line_block_without_blank_line, .text = "Line block ends without a blank line." },
    .{ .code = .unexpected_indentation, .text = "Unexpected indentation." },
    .{ .code = .blank_line_required_after_table, .text = "Blank line required after table." },
    .{ .code = .literal_block_expected, .text = "Literal block expected; none found." },
    .{ .code = .inconsistent_literal_block_quoting, .text = "Inconsistent literal block quoting." },
    .{ .code = .unexpected_section_title, .text = "Unexpected section title." },
    .{ .code = .unexpected_section_title_or_transition, .text = "Unexpected section title or transition." },
    .{ .code = .incomplete_section_title, .text = "Incomplete section title." },
    .{ .code = .possible_incomplete_section_title, .text = "Possible incomplete section title.\nTreating the overline as ordinary text because it's so short." },
    .{ .code = .title_underline_too_short, .text = "Title underline too short." },
    .{ .code = .possible_title_underline_too_short, .text = "Possible title underline, too short for the title.\nTreating it as ordinary text because it's so short." },
    .{ .code = .title_overline_too_short, .text = "Title overline too short." },
    .{ .code = .title_overline_underline_mismatch, .text = "Title overline & underline mismatch." },
    .{ .code = .missing_matching_underline_for_overline, .text = "Missing matching underline for section title overline." },
    .{ .code = .invalid_section_title_or_transition_marker, .text = "Invalid section title or transition marker." },
    .{ .code = .title_level_inconsistent, .text = "Title level inconsistent:" },
    .{ .code = .possible_title_overline_or_transition, .text = "Unexpected possible title overline or transition.\nTreating it as ordinary text because it's so short." },
    .{ .code = .malformed_hyperlink_target, .text = "malformed hyperlink target." },
    .{ .code = .figure_caption_must_be_paragraph, .text = "Figure caption must be a paragraph or empty comment." },
};

/// Everything between `prefix` and `suffix`, or null if `text` isn't that shape.
fn between(text: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (text.len < prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    if (!std.mem.endsWith(u8, text, suffix)) return null;
    return text[prefix.len .. text.len - suffix.len];
}

/// Parse docutils' wording back into a code and its arguments. `null` means
/// twig has no Tier A code for this message — a Tier B/C message, or a new one.
pub fn recognize(text: []const u8) ?Recognized {
    for (literals) |lit| {
        if (std.mem.eql(u8, text, lit.text)) return .{ .code = lit.code, .args = .none };
    }

    if (between(text, "Inline ", " start-string without end-string.")) |name| {
        inline for (std.enums.values(diagnostic.InlineConstruct)) |c| {
            if (std.mem.eql(u8, name, inlineName(c)))
                return .{ .code = .inline_start_string_without_end_string, .args = .{ .inline_construct = c } };
        }
        return null;
    }

    if (between(text, "", " ends without a blank line; unexpected unindent.")) |name| {
        inline for (std.enums.values(diagnostic.BlockConstruct)) |c| {
            if (std.mem.eql(u8, name, blockName(c)))
                return .{ .code = .unexpected_unindent, .args = .{ .block_construct = c } };
        }
        return null;
    }

    if (between(text, "Duplicate explicit target name: \"", "\".")) |name|
        return .{ .code = .duplicate_explicit_target_name, .args = .{ .name = name } };
    if (between(text, "Duplicate implicit target name: \"", "\".")) |name|
        return .{ .code = .duplicate_implicit_target_name, .args = .{ .name = name } };
    if (between(text, "Blank line missing before literal block (after the \"", "\")? Interpreted as a definition list item.")) |name|
        return .{ .code = .literal_block_hint_after_definition, .args = .{ .name = name } };

    if (between(text, "Enumerated list start value not ordinal-", ")")) |rest| {
        // `<expected>: "<text>" (ordinal <actual>`
        const colon = std.mem.indexOf(u8, rest, ": \"") orelse return null;
        const expected = std.fmt.parseInt(u32, rest[0..colon], 10) catch return null;
        const tail = rest[colon + 3 ..];
        const close = std.mem.lastIndexOf(u8, tail, "\" (ordinal ") orelse return null;
        const actual = std.fmt.parseInt(u32, tail[close + 11 ..], 10) catch return null;
        return .{ .code = .enumerated_list_start_not_ordinal, .args = .{ .ordinal = .{
            .expected = expected,
            .text = tail[0..close],
            .actual = actual,
        } } };
    }

    // Spelled as a named constant rather than a literal offset: the arithmetic
    // is `at + <length of the middle>`, and hand-counting that is exactly the
    // off-by-one this recognizer shipped with the first time.
    const widths_mid = "\" widths do not match the number of columns in table (";
    if (between(text, "\"", ").")) |rest| {
        if (std.mem.indexOf(u8, rest, widths_mid)) |at| {
            const columns = std.fmt.parseInt(u32, rest[at + widths_mid.len ..], 10) catch return null;
            return .{ .code = .table_widths_mismatch, .args = .{ .widths = .{
                .value = rest[0..at],
                .columns = columns,
            } } };
        }
    }

    if (std.mem.startsWith(u8, text, "Malformed table.")) {
        const rest = text["Malformed table.".len..];
        if (rest.len == 0)
            return .{ .code = .malformed_table, .args = .{ .table = .{ .defect = .unspecified } } };
        if (rest.len < 2 or rest[0] != '\n') return null;
        const detail = rest[1..];
        inline for (std.enums.values(diagnostic.TableDefect)) |d| {
            const pattern = tableDetail(d);
            if (pattern.len > 0) {
                if (d.hasLine()) {
                    const at = std.mem.indexOf(u8, pattern, "{d}").?;
                    if (between(detail, pattern[0..at], pattern[at + 3 ..])) |num| {
                        const line = std.fmt.parseInt(u32, num, 10) catch return null;
                        return .{ .code = .malformed_table, .args = .{ .table = .{ .defect = d, .line = line } } };
                    }
                } else if (std.mem.eql(u8, detail, pattern)) {
                    return .{ .code = .malformed_table, .args = .{ .table = .{ .defect = d } } };
                }
            }
        }
        return null;
    }

    return null;
}

// ── the doctree node ───────────────────────────────────────────────────────

/// The doctree-only facts a `<system_message>` carries that a `Diagnostic` does
/// not — see this file's header. Carried verbatim rather than derived.
pub const Extras = struct {
    /// docutils' `line` attribute (1-based). Derivable from a diagnostic's span
    /// via `parse_diagnostic.lineOf` once there is a source to measure against.
    line: u32,
    /// docutils' `source` attribute — the document name, `"test data"`
    /// throughout the corpus.
    source: []const u8,
    /// Space-joined id lists linking the message to its `<problematic>` node.
    /// Empty when absent.
    ids: []const u8 = "",
    backrefs: []const u8 = "",
    /// The quoted offending source docutils attaches as a `<literal_block>`
    /// child. Empty when the message has none (167 of 299 do not).
    excerpt: []const u8 = "",
};

/// Build the `<system_message>` subtree for one diagnostic, returning its id in
/// `b`. The caller chooses the parent — see "Placement" in this file's header
/// for why that choice is not made here.
pub fn subtree(
    b: *AST.Builder,
    code: Code,
    severity: Severity,
    args: Args,
    extras: Extras,
) !AST.Node.Id {
    const message = try writeAlloc(b.allocator, code, args);
    defer b.allocator.free(message);

    const text = try b.addLeaf(.{ .str = message });
    const para = try b.addContainer(.para, &.{text});

    var kids: [2]AST.Node.Id = undefined;
    var n: usize = 1;
    kids[0] = para;
    if (extras.excerpt.len > 0) {
        const block = try b.addContainer(.{ .code_block = .{ .lang = null, .text = extras.excerpt } }, &.{});
        try b.setAttrs(block, .{ .entries = &.{.{ .key = "xml:space", .value = "preserve" }} });
        kids[1] = block;
        n = 2;
    }

    const id = try b.addContainer(.{ .container = .{ .name = "system_message" } }, kids[0..n]);

    // Written in docutils' sorted order; `doctree.encode` sorts anyway, so this
    // is for readability rather than correctness.
    var entries = std.ArrayList(AST.KeyVal).empty;
    defer entries.deinit(b.allocator);
    if (extras.backrefs.len > 0) try entries.append(b.allocator, .{ .key = "backrefs", .value = extras.backrefs });
    if (extras.ids.len > 0) try entries.append(b.allocator, .{ .key = "ids", .value = extras.ids });
    var level_buf: [4]u8 = undefined;
    var line_buf: [16]u8 = undefined;
    try entries.append(b.allocator, .{
        .key = "level",
        .value = std.fmt.bufPrint(&level_buf, "{d}", .{severity.level()}) catch unreachable,
    });
    try entries.append(b.allocator, .{
        .key = "line",
        .value = std.fmt.bufPrint(&line_buf, "{d}", .{extras.line}) catch unreachable,
    });
    try entries.append(b.allocator, .{ .key = "source", .value = extras.source });
    try entries.append(b.allocator, .{ .key = "type", .value = severity.typeName() });
    try b.setAttrs(id, .{ .entries = entries.items });
    return id;
}

const testing = std.testing;

test "write and recognize agree for every code" {
    // One representative `Args` per code, so the round-trip covers the whole
    // enum rather than whichever codes the corpus happens to exercise.
    const samples = [_]struct { code: Code, args: Args }{
        .{ .code = .inline_start_string_without_end_string, .args = .{ .inline_construct = .interpreted_text } },
        .{ .code = .unexpected_unindent, .args = .{ .block_construct = .block_quote } },
        .{ .code = .literal_block_hint_after_definition, .args = .{ .name = "::" } },
        .{ .code = .enumerated_list_start_not_ordinal, .args = .{ .ordinal = .{ .expected = 1, .text = "b", .actual = 2 } } },
        .{ .code = .duplicate_explicit_target_name, .args = .{ .name = "target" } },
        .{ .code = .duplicate_implicit_target_name, .args = .{ .name = "title" } },
        .{ .code = .malformed_table, .args = .{ .table = .{ .defect = .unspecified } } },
        .{ .code = .malformed_table, .args = .{ .table = .{ .defect = .no_bottom_border } } },
        .{ .code = .malformed_table, .args = .{ .table = .{ .defect = .column_span_alignment, .line = 4 } } },
        .{ .code = .table_widths_mismatch, .args = .{ .widths = .{ .value = "widths", .columns = 2 } } },
    };
    inline for (samples) |s| {
        const text = try writeAlloc(testing.allocator, s.code, s.args);
        defer testing.allocator.free(text);
        const back = recognize(text) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(s.code, back.code);
        const again = try writeAlloc(testing.allocator, back.code, back.args);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(text, again);
    }
    // ...and every argument-free code, from the literals table itself.
    for (literals) |lit| {
        const text = try writeAlloc(testing.allocator, lit.code, .none);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(lit.text, text);
        try testing.expectEqual(lit.code, recognize(text).?.code);
    }
}

test "docutils' inconsistencies are reproduced, not tidied" {
    // Three places where matching docutils means NOT applying house style.
    const lower = try writeAlloc(testing.allocator, .malformed_hyperlink_target, .none);
    defer testing.allocator.free(lower);
    try testing.expectEqualStrings("malformed hyperlink target.", lower);

    const no_period = try writeAlloc(testing.allocator, .enumerated_list_start_not_ordinal, .{
        .ordinal = .{ .expected = 1, .text = "b", .actual = 2 },
    });
    defer testing.allocator.free(no_period);
    try testing.expectEqualStrings("Enumerated list start value not ordinal-1: \"b\" (ordinal 2)", no_period);

    const doubled = try writeAlloc(testing.allocator, .malformed_table, .{
        .table = .{ .defect = .parse_incomplete },
    });
    defer testing.allocator.free(doubled);
    // ...and the detail is separated by a NEWLINE, not a space — the corpus
    // round-trip caught this; a survey that joined the message's lines with a
    // space had hidden it.
    try testing.expectEqualStrings("Malformed table.\nMalformed table; parse incomplete.", doubled);
}

test "recognize declines a Tier B message rather than guessing" {
    try testing.expect(recognize("Unknown directive type \"foo\".") == null);
    try testing.expect(recognize("Content block expected for the \"note\" directive; none found.") == null);
}

test "subtree builds a system_message node that encodes as docutils writes it" {
    const doctree = @import("doctree.zig");
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    const msg = try subtree(&b, .unexpected_indentation, .err, .none, .{
        .line = 3,
        .source = "test data",
    });
    const root = try b.addContainer(.doc, &.{msg});
    try b.setAttrs(root, .{ .entries = &.{.{ .key = "source", .value = "test data" }} });

    var ast = try b.finish(root);
    defer ast.deinit();
    const out = try doctree.encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\<document source="test data">
        \\    <system_message level="3" line="3" source="test data" type="ERROR">
        \\        <paragraph>
        \\            Unexpected indentation.
        \\
    , out);
}

test "an excerpt becomes the literal_block docutils quotes" {
    const doctree = @import("doctree.zig");
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();

    const msg = try subtree(&b, .title_level_inconsistent, .severe, .none, .{
        .line = 5,
        .source = "test data",
        .excerpt = "Title\n-----",
    });
    var ast = try b.finish(msg);
    defer ast.deinit();
    const out = try doctree.encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\<system_message level="4" line="5" source="test data" type="SEVERE">
        \\    <paragraph>
        \\        Title level inconsistent:
        \\    <literal_block xml:space="preserve">
        \\        Title
        \\        -----
        \\
    , out);
}
