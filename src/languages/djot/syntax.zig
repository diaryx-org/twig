//! Djot's surface spelling — the table `Editor`'s authoring gestures consult.
//! See `src/syntax.zig` for the model and why this is data rather than a
//! `switch (format)` at some boundary.
//!
//! This lives beside djot's parser on purpose: every value here is a claim
//! about what `djot/parser.zig` will read back and what `djot/serializer.zig`
//! emits, so it belongs where a change to either would be noticed.

const std = @import("std");
const syntax = @import("../../syntax.zig");
const inline_mod = @import("inline.zig");

/// Djot classifies an autolink on content alone, so this defers to the parser's
/// own scanner rather than re-deriving the rule. `angled` arrives with its
/// brackets, which `autolinkKindOf` doesn't want.
fn spellsAutolink(angled: []const u8) bool {
    if (angled.len < 2) return false;
    return inline_mod.InlineParser.autolinkKindOf(angled[1 .. angled.len - 1]) != null;
}

/// Djot spells every inline mark — which is why `AST.InlineMark` has the
/// variants it does.
pub const table: syntax.Syntax = .{
    .inline_delims = .init(.{
        .strong = .{ .open = "*", .close = "*" },
        .emph = .{ .open = "_", .close = "_" },
        .mark = .{ .open = "{=", .close = "=}" },
        .superscript = .{ .open = "^", .close = "^" },
        .subscript = .{ .open = "~", .close = "~" },
        .insert = .{ .open = "{+", .close = "+}" },
        .delete = .{ .open = "{-", .close = "-}" },
        // Djot's smart-quote containers are produced by the PARSER from bare
        // `"`/`'`; an editor toggling them would write the same bytes the
        // parser turns into curly quotes, so they are emit-only.
        .double_quoted = .{ .open = "\"", .close = "\"", .authorable = false },
        .single_quoted = .{ .open = "'", .close = "'", .authorable = false },
    }),
    .text_leaf_delims = .init(.{
        .verbatim = .{ .open = "`", .close = "`" },
        // `$`code`` — the dollar sits OUTSIDE the verbatim run that carries the
        // formula, so the opener is two bytes and the closer one.
        .inline_math = .{ .open = "$`", .close = "`", .authorable = false },
        .display_math = .{ .open = "$$`", .close = "`", .authorable = false },
        .symb = .{ .open = ":", .close = ":", .authorable = false },
        .url = .{ .open = "<", .close = ">", .authorable = false },
        .email = .{ .open = "<", .close = ">", .authorable = false },
        .footnote_reference = .{ .open = "[^", .close = "]", .authorable = false },
    }),
    .container_spelling = .init(.{
        .block_quote = .{ .marker = "> ", .cont = "> ", .blank = ">" },
        .bullet_list = .{ .marker = "- ", .cont = "  ", .blank = "" },
        .ordered_list = .{ .marker = "", .cont = "", .blank = "", .numbered = true },
    }),
    .heading_marker = '#',
    // Djot has attributes (`{…}`) and smart punctuation (`"`/`'`/`-`/`.`/`:`)
    // where Markdown has entities and raw HTML — hence the divergence from
    // `markdown/syntax.zig`'s set.
    .link_text_escapes = "\\[]*_^`~\"'-.:{}",
    .link_dest_escapes = .{
        // No angle form: djot strips a newline and has no `<…>` destination
        // spelling, so a space is escaped in place.
        .plain = "\\()[`",
    },
    // Djot's inline metacharacters: its marks (`*_^~` and `` ` ``), its bracket
    // and brace constructs (`[]`, `{}`), the smart punctuation that would
    // transform (`"'-.:`), and — crucially — the delimiters INSIDE the braces
    // that a `{…}` span keys on, `=` (highlight) and `+` (insert). Escaping the
    // braces alone is not enough: djot reads `\{=m=\}` back as a `mark`, so the
    // `=`/`+` must go too. `<` guards the `<url>` autolink form. A superset of
    // `link_text_escapes`, which predates this and never needed the brace-inner
    // delimiters.
    .text_escapes = "\\[]*_^`~\"'-.:{}=+<",
    // `#` heading, `>` quote, `|` table row. The bullet openers (`-`/`+`/`*`),
    // the div `:` and the code fences (`` ` ``/`~`) are already escaped on every
    // line by `text_escapes`, so they need no line-start entry.
    .block_start_escapes = "#>|",
    .spellsAutolink = spellsAutolink,
    // No `cell_line_break`: djot has no native in-cell hard break, and spelling
    // one as `<br>` would emit non-idiomatic djot that any other djot reader
    // renders as literal `<br>` text. So it stays `null` — `insertLineBreak`
    // inside a djot cell is a clean `error.UnsupportedFormat`. See
    // `syntax.zig`'s field doc for the full rationale.
};

test "djot spells every inline kind" {
    inline for (std.meta.fields(syntax.InlineKind)) |f| {
        try std.testing.expect(table.inline_delims.get(@enumFromInt(f.value)) != null);
    }
    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "djot has no in-cell break spelling (deliberately null)" {
    try std.testing.expect(table.cell_line_break == null);
}

test "djot body-text literals extend the link-text alphabet with brace delimiters" {
    const te = table.text_escapes.?;
    // A superset of link text: every link-text escape, plus the brace-inner
    // delimiters (`=`/`+`) and the autolink `<` that body text also needs.
    for (table.link_text_escapes.?) |c| try std.testing.expect(std.mem.indexOfScalar(u8, te, c) != null);
    for ("=+<") |c| try std.testing.expect(std.mem.indexOfScalar(u8, te, c) != null);
    const bse = table.block_start_escapes.?;
    for ("#>|") |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) != null);
    // Disjoint from the always-on set.
    for (te) |c| try std.testing.expect(std.mem.indexOfScalar(u8, bse, c) == null);
    table.assertCoherent();
}

test "djot autolinks by content, so a bare mailto: is an email" {
    try std.testing.expect(spellsAutolink("<https://x.dev>"));
    try std.testing.expect(spellsAutolink("<a@b.dev>"));
    try std.testing.expect(spellsAutolink("<mailto:a@b.dev>"));
    // A relative path is not an autolink in either format.
    try std.testing.expect(!spellsAutolink("<foo/bar>"));
    try std.testing.expect(!spellsAutolink("<>"));
}
