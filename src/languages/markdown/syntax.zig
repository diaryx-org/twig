//! Markdown's surface spelling — the table `Editor`'s authoring gestures
//! consult. See `src/syntax.zig` for the model.
//!
//! Markdown spells strictly LESS than djot: three inline marks against djot's
//! eight. That gap is the whole reason `Syntax.inline_delims` is a table of
//! optionals — `Editor.toggleInline(.mark)` has to be a clean
//! `error.UnsupportedFormat` here while it works one file over.

const std = @import("std");
const syntax = @import("../../syntax.zig");
const markdown = @import("markdown.zig");

/// Defers to the parser's own autolink scanner: Markdown wants an absolute URI
/// or a CommonMark email and silently reads anything else as RAW HTML, so a
/// re-derived rule here could turn `<foo>` into a tag.
fn spellsAutolink(angled: []const u8) bool {
    return markdown.spellsAutolink(angled);
}

pub const table: syntax.Syntax = .{
    // Only `strong`/`emph` are AUTHORABLE. The rest carry the spelling the
    // serializer uses when converting a djot document down to Markdown —
    // `==mark==` and friends are extension syntax that CommonMark won't parse
    // back, so writing them is acceptable (better than dropping the node) while
    // an editor gesture minting them is not. See `Delims.authorable`.
    .inline_delims = .init(.{
        .strong = .{ .open = "**", .close = "**" },
        .emph = .{ .open = "*", .close = "*" },
        .mark = .{ .open = "==", .close = "==", .authorable = false },
        .superscript = .{ .open = "^", .close = "^", .authorable = false },
        .subscript = .{ .open = "~", .close = "~", .authorable = false },
        .insert = .{ .open = "{+", .close = "+}", .authorable = false },
        // GFM strikethrough: parsed back, but only with the extension on, so
        // still not something a toggle may assume.
        .delete = .{ .open = "~~", .close = "~~", .authorable = false },
        .double_quoted = .{ .open = "\"", .close = "\"", .authorable = false },
        .single_quoted = .{ .open = "'", .close = "'", .authorable = false },
    }),
    .text_leaf_delims = .init(.{
        .verbatim = .{ .open = "`", .close = "`" },
        .inline_math = .{ .open = "$", .close = "$", .authorable = false },
        .display_math = .{ .open = "$$", .close = "$$", .authorable = false },
        .symb = .{ .open = ":", .close = ":", .authorable = false },
        .url = .{ .open = "<", .close = ">", .authorable = false },
        .email = .{ .open = "<", .close = ">", .authorable = false },
        .footnote_reference = .{ .open = "[^", .close = "]", .authorable = false },
        // No citation registry and no substitutions in Markdown either; see the
        // matching entries in `djot/syntax.zig`.
        .citation_reference = null,
        .substitution_reference = null,
    }),
    .container_spelling = .init(.{
        .block_quote = .{ .marker = "> ", .cont = "> ", .blank = ">" },
        .bullet_list = .{ .marker = "- ", .cont = "  ", .blank = "" },
        .ordered_list = .{ .marker = "", .cont = "", .blank = "", .numbered = true },
    }),
    .heading_marker = '#',
    // What the serializer emits. `---` is only a break when a blank line comes
    // first — after a paragraph line it is a setext `<h2>` underline — which is
    // why `Editor.insertThematicBreak` blank-separates rather than trusting the
    // spelling alone.
    .thematic_break = "---",
    // Backticks, not tildes: `~~~` is valid CommonMark but the serializer emits
    // backticks, and a toggle that writes one form must recognize the same one.
    // An info string ends at whitespace, so a `lang` holding a space would come
    // back truncated — refused rather than silently clipped.
    .code_fence = .{ .char = '`', .info_forbids = " \t" },
    // GFM task list items.
    .task_marker = .{ .unchecked = "[ ]", .checked = "[x]" },
    // GFM footnotes.
    .footnote = .{ .ref_open = "[^", .ref_close = "]", .def_suffix = ": " },
    // GFM pipe tables. Padded on both sides of every cell, the delimiter row
    // included — GFM matches the dashes after skipping whitespace, so `| --- |`
    // is a delimiter here even though the same line is a data row in djot. The
    // aligned forms ADD their colon to the three-dash run rather than replacing
    // a dash, which is the other half of what makes the two spellings distinct
    // tables rather than one shared constant.
    .table_spelling = .{
        .bar = "|",
        .delim_pad = " ",
        .delim = .init(.{
            .default = "---",
            .left = ":---",
            .right = "---:",
            .center = ":---:",
        }),
    },
    // A blank line, as everywhere in CommonMark: it is what ends a paragraph and
    // opens the next.
    .block_separator = "\n",
    // A generic directive's `{#id .class key=val}` shorthand. Unlike djot, a
    // value is left bare when `attributes.zig`'s `isNameChar` grammar can read
    // it back, and quoted (escaping `"`/`\`) otherwise.
    .attr_spelling = .{
        .open = "{",
        .close = "}",
        .quoting = .when_needed,
        .quote_escapes = "\"\\",
        .id_sigil = "#",
        .class_sigil = ".",
    },
    // `<` and `&` where djot has `{`/`}` and smart punctuation: Markdown reads
    // `<…>` as raw HTML and `&…;` as an entity.
    .link_text_escapes = "\\[]*_^`~<>&",
    .link_dest_escapes = .{
        .plain = "\\()<&",
        // Markdown's `<dest>` form carries a destination containing whitespace.
        // Inside it the brackets are what must be escaped, not the parens — and
        // `&` still is, because Markdown DECODES entity references in a
        // destination in both forms (an `a&amp;b` handed in would come back out
        // as `a&b`, corrupting the URL rather than breaking the link).
        .angle = .{ .escapes = "\\<>&" },
    },
    // Body-text literals. Narrower than `link_text_escapes` in reasoning but
    // reaching the same specials: `\` (escape), the emphasis/strike/code runs,
    // the link brackets, and — unlike link TEXT, which is already bounded by its
    // `[…]` — the two that mint markup out in the open, `<` (autolink / raw HTML)
    // and `&` (entity). Block openers that only bite at column zero are in
    // `block_start_escapes`, not here.
    .text_escapes = "\\*_`[]~<&",
    // `#` heading, `>` quote, `-`/`+` bullets (and `-` a thematic break or setext
    // underline), `=` a setext underline. `*`/`_` also open bullets/breaks but are
    // already escaped everywhere by `text_escapes`, so they need no entry here.
    .block_start_escapes = "#>-+=",
    .spellsAutolink = spellsAutolink,
    // GFM's only in-cell break: a table row is one source line, and raw HTML is
    // valid inside a GFM cell, so `<br>` is the one spelling that fits. The
    // inline parser promotes it back to a `hard_break` in cell context, so the
    // token round-trips (`<br/>`/`<br />` normalize to this on the way out).
    .cell_line_break = "<br>",
};

test "markdown SPELLS every mark but AUTHORS only three" {
    // The distinction `Delims.authorable` exists for. The serializer needs a
    // spelling for every mark so a djot document converts without losing
    // nodes; the editor must refuse all but the CommonMark three, because the
    // rest would not reparse as the mark they were meant to be.
    const AST = @import("../../ast/ast.zig");
    for (std.enums.values(AST.InlineMark)) |m| {
        try std.testing.expect(table.inline_delims.get(m) != null);
    }
    const authorable_marks = [_]AST.InlineMark{ .strong, .emph };
    for (std.enums.values(AST.InlineMark)) |m| {
        const want = std.mem.indexOfScalar(AST.InlineMark, &authorable_marks, m) != null;
        try std.testing.expectEqual(want, table.inline_delims.get(m).?.authorable);
    }
    // `verbatim` moved to the text-leaf table with the rest of its family, and
    // is the one leaf an editor may toggle.
    try std.testing.expect(table.text_leaf_delims.get(.verbatim).?.authorable);
    try std.testing.expect(!table.text_leaf_delims.get(.url).?.authorable);

    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "markdown pads its delimiter row and grows the dash run for alignment" {
    // The half of the pipe-table spelling that differs from djot's, stated
    // beside the parser that has to read it back. GFM skips whitespace before
    // matching the dashes, so the padding is free here and is what the
    // serializer emits; the colon is ADDED to the three-dash run.
    const ts = table.table_spelling.?;
    try std.testing.expectEqualStrings(" ", ts.delim_pad);
    try std.testing.expectEqualStrings(" ", ts.pad);
    try std.testing.expectEqualStrings("---", ts.delim.get(.default));
    try std.testing.expectEqualStrings(":---", ts.delim.get(.left));
    try std.testing.expectEqualStrings("---:", ts.delim.get(.right));
    try std.testing.expectEqualStrings(":---:", ts.delim.get(.center));
    table.assertCoherent();
}

test "markdown spells the in-cell break as <br>" {
    try std.testing.expectEqualStrings("<br>", table.cell_line_break.?);
}

test "markdown spells body-text and line-start literals" {
    const te = table.text_escapes.?;
    // The always-on inline specials.
    for ("\\*_`[]~<&") |c| try std.testing.expect(std.mem.indexOfScalar(u8, te, c) != null);
    const bse = table.block_start_escapes.?;
    for ("#>-+=") |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) != null);
    // The two sets are disjoint: a byte escaped everywhere needs no line-start
    // entry, and `assertCoherent` pairs their nullness.
    for (te) |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) == null);
    table.assertCoherent();
}

test "markdown autolinks by scheme, so a bare word would be raw HTML" {
    try std.testing.expect(spellsAutolink("<https://x.dev>"));
    try std.testing.expect(spellsAutolink("<a@b.dev>"));
    // `<foo>` is a TAG, not an autolink — the reason this asks the parser.
    try std.testing.expect(!spellsAutolink("<foo>"));
    try std.testing.expect(!spellsAutolink("<foo/bar>"));
}
