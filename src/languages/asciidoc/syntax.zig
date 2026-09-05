//! AsciiDoc's surface spelling — the table `Editor`'s authoring gestures
//! consult, and the one `serializer.zig` reads its inline delimiters from.
//! See `src/syntax.zig` for the model.
//!
//! ── The doubled forms, and why ─────────────────────────────────────────────
//! AsciiDoc spells every span twice: a CONSTRAINED form (`*bold*`) that only
//! opens and closes on word boundaries, and an UNCONSTRAINED one (`**bold**`)
//! that works anywhere, including mid-word. A gesture wraps whatever range
//! the caret gave it — `sub|str|ing` as readily as a whole word — so the
//! table holds the unconstrained forms: they are the ones that reparse
//! wherever they land. The serializer derives the constrained spelling from
//! the same entry (halving a doubled delimiter) when the boundaries allow,
//! which is what keeps `convert -o asciidoc` idiomatic without giving the
//! two a second, drifting copy of the alphabet.
//!
//! ── What stays null, and why ───────────────────────────────────────────────
//! Everything left `null` below has a spelling in AsciiDoc whose SHAPE the
//! gesture algorithms in `ast/editor.zig` cannot write:
//!
//!   * `link_text_escapes`/`link_dest_escapes`: the algorithm writes
//!     `[text](dest)`, and AsciiDoc's link is `dest[text]` — the halves are
//!     in the other order. Same for `insertImage`'s `![alt](dest)`.
//!   * `footnote`: the algorithm pairs a `[^label]` reference with a
//!     `[^label]: body` definition line; an AsciiDoc footnote is one macro,
//!     `footnote:[body]`, with no definition line to write.
//!   * `table_spelling`: the algorithm re-spells a PIPE table, whose header
//!     is a delimiter row of dashes under the first row; an AsciiDoc table is
//!     fenced by `|===` and has no delimiter row.
//!   * `cell_line_break`: no table spelling, so no in-cell break either.
//!
//! Lifting any of those is a change to `syntax.zig` and `editor.zig`, not to
//! this file — the same line `html/syntax.zig` draws.
//!
//! The container spellings are the ones Asciidoctor reads that ALSO fit the
//! per-line-prefix model: `> ` quotes (Markdown-style, which Asciidoctor
//! accepts alongside `____`), `* ` bullets with indented continuations, and
//! `1. ` ordered items — the numbered form rather than the idiomatic bare
//! `.`, because the renumber gesture rewrites a numeric marker and the bare
//! dot has none. The code fence is likewise the Markdown-style backtick
//! fence Asciidoctor reads, since a `----` listing carries its language on a
//! separate `[source,lang]` line where `CodeFence` has no place for it. The
//! serializer still writes the idiomatic forms; both spellings parse.

const std = @import("std");
pub const syntax = @import("../../syntax.zig");
const parser = @import("parser.zig");

/// `<https://…>` autolinks in AsciiDoc when the interior is a URL of a scheme
/// the parser knows; a bare word in angle brackets is text.
fn spellsAutolink(angled: []const u8) bool {
    if (angled.len < 3 or angled[0] != '<' or angled[angled.len - 1] != '>') return false;
    const inner = angled[1 .. angled.len - 1];
    if (std.mem.indexOfAny(u8, inner, " \t\n<>") != null) return false;
    inline for (.{ "https://", "http://", "ftp://", "irc://", "file://" }) |scheme| {
        if (std.mem.startsWith(u8, inner, scheme) and inner.len > scheme.len) return true;
    }
    return false;
}

pub const table: syntax.Syntax = .{
    .inline_delims = .init(.{
        .strong = .{ .open = "**", .close = "**" },
        .emph = .{ .open = "__", .close = "__" },
        .mark = .{ .open = "##", .close = "##" },
        // Superscript and subscript have only the one, unconstrained form.
        .superscript = .{ .open = "^", .close = "^" },
        .subscript = .{ .open = "~", .close = "~" },
        // No insert/delete marks: Asciidoctor's convention is a role its
        // stylesheet knows, which reads back as a styled span, not a mark.
        .insert = .{ .open = "[.underline]#", .close = "#", .authorable = false },
        .delete = .{ .open = "[.line-through]#", .close = "#", .authorable = false },
        // Asciidoctor's curved quotes. Emit-only: a gesture asked for a quote
        // would want typographic quotes around a selection, and these reparse
        // as a quoted CONTAINER, which is not the same edit.
        .double_quoted = .{ .open = "\"`", .close = "`\"", .authorable = false },
        .single_quoted = .{ .open = "'`", .close = "`'", .authorable = false },
    }),
    .text_leaf_delims = .init(.{
        .verbatim = .{ .open = "``", .close = "``" },
        .inline_math = .{ .open = "stem:[", .close = "]", .authorable = false },
        .display_math = .{ .open = "stem:[", .close = "]", .authorable = false },
        // No shortcodes; a bare URL or address needs no delimiters at all.
        .symb = null,
        .url = null,
        .email = null,
        .footnote_reference = .{ .open = "footnote:", .close = "[]", .authorable = false },
        // A citation reference is a cross reference to the citation's anchor.
        .citation_reference = .{ .open = "<<", .close = ">>", .authorable = false },
        // An attribute reference IS a substitution reference.
        .substitution_reference = .{ .open = "{", .close = "}", .authorable = false },
    }),
    .container_spelling = .init(.{
        .block_quote = .{ .marker = "> ", .cont = "> ", .blank = ">" },
        // A blank line between items keeps them in one list, so nothing is
        // written on it; a `+` there would attach the next block to the item
        // instead of starting the next one.
        .bullet_list = .{ .marker = "* ", .cont = "  ", .blank = "" },
        .ordered_list = .{ .marker = "", .cont = "  ", .blank = "", .numbered = true },
    }),
    .heading_marker = '=',
    .thematic_break = "'''",
    .code_fence = .{ .char = '`', .info_forbids = " \t" },
    .task_marker = .{ .unchecked = "[ ]", .checked = "[x]" },
    // A blank line separates blocks here as it does everywhere.
    .block_separator = "\n",
    // Body-text literals: the span delimiters, `+` (a passthrough), `{`
    // (an attribute reference), `[` (an attribute list or anchor), `<` (a
    // cross reference or autolink), `&` (a character reference) and the
    // backslash itself. Every one reads back as itself after a backslash.
    .text_escapes = "\\*_`#^~+{[<&",
    // Line-start openers: `=` a heading, `.` a title or ordered item, `>` a
    // quote, `|` a table, `/` a comment, `'` a thematic break, `:` an
    // attribute entry, `-` a bullet or listing. `*`, `+` and `[` open blocks
    // too but are escaped everywhere by `text_escapes` already.
    .block_start_escapes = "=.>|/':-",
    .spellsAutolink = spellsAutolink,

    // ── Deliberately absent ────────────────────────────────────────────────
    // `link_text_escapes`, `link_dest_escapes`, `footnote`, `table_spelling`,
    // `cell_line_break`: the shape mismatches in this file's doc comment.
    // `attr_spelling`: the serializer writes AsciiDoc's `[#id.role,key=val]`
    // line itself, since the shorthand does not separate its pieces the way
    // `AttrSpelling`'s single `between` would.
};

test "asciidoc spells every mark, and authors the five that reparse anywhere" {
    const AST = @import("../../ast/ast.zig");
    for (std.enums.values(AST.InlineMark)) |m| {
        try std.testing.expect(table.inline_delims.get(m) != null);
    }
    const authorable_marks = [_]AST.InlineMark{ .strong, .emph, .mark, .superscript, .subscript };
    for (std.enums.values(AST.InlineMark)) |m| {
        const want = std.mem.indexOfScalar(AST.InlineMark, &authorable_marks, m) != null;
        try std.testing.expectEqual(want, table.inline_delims.get(m).?.authorable);
    }
    try std.testing.expect(table.text_leaf_delims.get(.verbatim).?.authorable);
    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "the authorable delimiters are the unconstrained forms" {
    // The property the doc comment argues for: what a gesture writes must
    // reparse wherever the caret put it, and only the doubled forms do.
    for ([_][]const u8{ "**", "__", "##" }) |d| {
        var found = false;
        const AST = @import("../../ast/ast.zig");
        for (std.enums.values(AST.InlineMark)) |m| {
            const delims = table.inline_delims.get(m) orelse continue;
            if (std.mem.eql(u8, delims.open, d)) found = true;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqualStrings("``", table.text_leaf_delims.get(.verbatim).?.open);
}

test "the escape alphabets are disjoint and every byte reads back after a backslash" {
    const te = table.text_escapes.?;
    const bse = table.block_start_escapes.?;
    for (te) |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) == null);
    // Each escaped byte parses as itself: `\X` yields a `str` "X".
    const all = te ++ bse;
    for (all) |c| {
        if (c == '\\') continue;
        const src = [_]u8{ '\\', c, '\n' };
        var doc = try parser.parseInlineList(std.testing.allocator, &src);
        defer doc.deinit();
        const first = doc.ast.nodes[doc.ast.root].first_child.?;
        try std.testing.expect(doc.ast.nodes[first].kind == .str);
        try std.testing.expectEqualStrings(&[_]u8{c}, doc.ast.nodes[first].kind.str);
    }
    table.assertCoherent();
}

test "asciidoc autolinks a URL in angle brackets and nothing else" {
    try std.testing.expect(spellsAutolink("<https://x.dev>"));
    try std.testing.expect(!spellsAutolink("<foo>"));
    try std.testing.expect(!spellsAutolink("<https://x.dev y>"));
    try std.testing.expect(!spellsAutolink("<a@b.dev>"));
}

test "the shapes the gesture algorithms cannot write stay null" {
    try std.testing.expect(table.link_text_escapes == null);
    try std.testing.expect(table.link_dest_escapes == null);
    try std.testing.expect(table.footnote == null);
    try std.testing.expect(table.table_spelling == null);
    try std.testing.expect(table.cell_line_break == null);
    try std.testing.expect(table.attr_spelling == null);
    // And the block gestures it CAN spell.
    try std.testing.expect(table.heading_marker.? == '=');
    try std.testing.expect(table.container_spelling.get(.block_quote) != null);
    try std.testing.expect(table.container_spelling.get(.ordered_list).?.numbered);
    try std.testing.expect(table.task_marker != null);
    try std.testing.expect(table.code_fence != null);
}
