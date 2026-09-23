//! Markdown's surface spelling — the table `Editor`'s authoring gestures
//! consult. See `src/syntax.zig` for the model.
//!
//! Markdown spells strictly LESS than djot: three inline marks against djot's
//! eight. That gap is the whole reason `Syntax.inline_delims` is a table of
//! optionals — `Editor.toggleInline(.superscript)` has to be a clean
//! `error.UnsupportedFormat` here while it works one file over.
//!
//! And it is the reason this file holds a SET of tables rather than one.
//! Markdown's authorable subset is not a property of the format: `~~x~~` reads
//! back as a `delete` under `ParseOptions.strikethrough` and as literal tildes
//! without it, `==x==` as a `mark` under `highlight` and as text without it. A
//! gesture may only mint bytes the editor's own reparse reads back the same
//! way, so the answer has to come from the parse config. `forOptions` at the
//! foot of the file is that choice, and `format.zig`'s `syntaxForConfig` makes
//! it from the very config the editor reparses with.
//!
//! `base` below is the literal, and it states no extension-gated answer at all;
//! `derive` fills those in. That is deliberate: the flags default differently
//! (`strikethrough` on, `highlight` off), so a literal that stated one of them
//! would read as a claim about Markdown when it is only a claim about a
//! default.

const std = @import("std");
const syntax = @import("../../syntax.zig");
const markdown = @import("markdown.zig");
const serializer = @import("serializer.zig");
const highlight = @import("highlight.zig");
const Options = @import("options.zig");
const AST = @import("../../ast/ast.zig");

/// Defers to the parser's own autolink scanner: Markdown wants an absolute URI
/// or a CommonMark email and silently reads anything else as RAW HTML, so a
/// re-derived rule here could turn `<foo>` into a tag.
fn spellsAutolink(angled: []const u8) bool {
    return markdown.spellsAutolink(angled);
}

/// Markdown's spelling before the parse config has its say: every delimiter,
/// every escape alphabet, and the authorable flags for what means the same
/// thing under any options. The EXTENSION-gated answers are left at their
/// pessimistic value here and set by `derive`, so no reader of this literal can
/// mistake a default for a property of the format.
const base: syntax.Syntax = .{
    // Only `strong`/`emph` are unconditionally AUTHORABLE. The rest carry the
    // spelling the serializer uses when converting a djot document down to
    // Markdown — `^sup^` and friends are extension syntax nothing here parses
    // back, so writing them is acceptable (better than dropping the node)
    // while an editor gesture minting them is not. See `Delims.authorable`.
    .inline_delims = .init(.{
        .strong = .{ .open = "**", .close = "**" },
        .emph = .{ .open = "*", .close = "*" },
        // `==mark==` and `~~delete~~` are the two whose answer MOVES: each is
        // read back only with its extension on (`ParseOptions.highlight`, off
        // by default; `ParseOptions.strikethrough`, on by default), so neither
        // is stated here and `derive` sets both.
        .mark = .{ .open = "==", .close = "==", .authorable = false },
        .superscript = .{ .open = "^", .close = "^", .authorable = false },
        .subscript = .{ .open = "~", .close = "~", .authorable = false },
        // Underline, as raw HTML: it renders as one under any options, and
        // `ParseOptions.html_elements` pairs it back into an `insert`, so
        // `derive` makes it authorable exactly there.
        .insert = .{ .open = "<u>", .close = "</u>", .authorable = false },
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
    // A bare line end continues one: a paragraph's second line is a soft break,
    // not a second block.
    .line_join = "\n",
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
    // ── Renderers ──────────────────────────────────────────────────────────
    // A literal is a backslash before a byte from the two alphabets above —
    // the shared renderer, not a Markdown one. A fragment is the serializer
    // over it; `setBlock` never reaches it here because `heading_marker` is
    // the preferred path, but it is the same answer every serializing format
    // gives (see `Syntax.renderBlock`).
    .renderText = syntax.renderTextByAlphabet,
    .renderBlock = syntax.renderBlockVia(serializer.serializeAstAlloc),
    .spellsAutolink = spellsAutolink,
    // GFM's only in-cell break: a table row is one source line, and raw HTML is
    // valid inside a GFM cell, so `<br>` is the one spelling that fits. The
    // inline parser promotes it back to a `hard_break` in cell context, so the
    // token round-trips (`<br/>`/`<br />` normalize to this on the way out).
    .cell_line_break = "<br>",
};

// ── One table per parse config ─────────────────────────────────────────────
//
// Markdown is the only format whose AUTHORABLE subset moves with how the
// document is being read, and it moves in both directions from the defaults:
// `~~x~~` is a `delete` unless `ParseOptions.strikethrough` is turned OFF (it
// defaults on), `==x==` is a `mark` only once `highlight` is turned ON (it
// defaults off). "May a toggle write it?" therefore has as many answers as
// there are relevant flags, and none of them is wrong.
//
// The tables below are those answers, one apiece, and `format.zig`'s
// `syntaxForConfig` picks between them from the very `ParseConfig` the editor
// reparses with — so the spelling an editor may write and the spelling its own
// reparse reads back cannot disagree.
//
// They are DERIVED from `base` rather than written out. Twelve near-copies of
// one two-hundred-line literal is where the twelfth quietly differs in an
// escape alphabet, and the difference between them is a handful of fields.
//
// What is NOT keyed here is the serializer's question. Converting a djot
// `mark` down to Markdown spells `==x==` whatever the parse config said,
// because the alternative is dropping the node; that reads `delimsFor`, which
// ignores `authorable` entirely. See `Delims.authorable` for that asymmetry,
// which is the reason these are extra tables rather than an edit to one.

/// Every colour `highlight.zig` knows, as an editor's palette: the attribute
/// value beside the bytes that spell it. Derived from that enum rather than
/// re-listed, so a colour added there is offered here without a second edit.
const color_spellings = blk: {
    const values = std.enums.values(highlight.Color);
    var out: [values.len]syntax.MarkColors.Color = undefined;
    for (values, 0..) |c, i| out[i] = .{ .name = c.name(), .prefix = c.emoji() };
    const frozen = out;
    break :blk frozen;
};

/// How far the highlight extensions reach — `ParseOptions.highlight` and
/// `highlight_colors` as the one ordered axis they actually are, since a
/// colour is inert without a highlight to colour. A nested pair of booleans
/// would give the table set a combination the parser cannot produce.
const Highlights = enum(u2) { none, marks, colors };

/// The flags that move an ANSWER, as one key — the address of a table in
/// the set. Small on purpose: a flag that adds nodes no gesture authors is not
/// here. `directives` is a key because `Editor.insertDirective` authors one,
/// and `html_elements` because `setBlockAttrs`, `wrapRangeAttrs` and
/// `toggleInline(.insert)` mint a `<div>`, a `<span>` and a `<u>` only that
/// flag reads back. `math` authors nothing,
/// but it makes `$` a byte that opens markup, so it moves the escape
/// alphabets — a literal typed under it must not mint a formula. At four
/// flags the nested arrays this used to be gave way to an index; the fifth
/// added a factor to it.
const Key = struct {
    strikethrough: bool,
    highlights: Highlights,
    directives: bool,
    html_elements: bool,
    math: bool,

    const count = 2 * 3 * 2 * 2 * 2;

    fn index(k: Key) usize {
        var i: usize = @intFromBool(k.strikethrough);
        i = i * 3 + @intFromEnum(k.highlights);
        i = i * 2 + @intFromBool(k.directives);
        i = i * 2 + @intFromBool(k.html_elements);
        i = i * 2 + @intFromBool(k.math);
        return i;
    }

    fn fromIndex(i: usize) Key {
        var rest = i;
        const math = rest % 2 == 1;
        rest /= 2;
        const html_elements = rest % 2 == 1;
        rest /= 2;
        const directives = rest % 2 == 1;
        rest /= 2;
        const highlights: Highlights = @enumFromInt(rest % 3);
        rest /= 3;
        return .{ .strikethrough = rest == 1, .highlights = highlights, .directives = directives, .html_elements = html_elements, .math = math };
    }

    fn of(opts: Options) Key {
        // Colours are inert without a highlight to colour, exactly as in the
        // parser: `highlight_colors` alone leaves `==` literal, so there is
        // nothing for a palette to sit inside.
        const h: Highlights = if (!opts.highlight)
            .none
        else if (opts.highlight_colors)
            .colors
        else
            .marks;
        return .{
            .strikethrough = opts.strikethrough,
            .highlights = h,
            .directives = opts.directives,
            .html_elements = opts.html_elements,
            .math = opts.math,
        };
    }
};

/// `base` with the extension-gated answers filled in — the whole difference
/// between one table here and the next.
fn derive(comptime k: Key) syntax.Syntax {
    var t = base;
    setAuthorable(&t, .delete, k.strikethrough);
    setAuthorable(&t, .mark, k.highlights != .none);
    setAuthorable(&t, .insert, k.html_elements);
    if (k.highlights == .colors) {
        t.mark_colors = .{ .attr_key = highlight.attr_key, .colors = &color_spellings };
    }
    // The serializer prints `::name[label]{attrs}` under any options — that is
    // how a djot div converts down — but only `ParseOptions.directives` reads
    // it back as a container. Without the flag it is a paragraph of literal
    // colons, so `insertDirective` may not mint it, exactly as `toggleInline`
    // may not mint `==x==` without `highlight`.
    t.names_leaf_containers = k.directives;
    // The same shape again: the serializer writes an attributed block inside
    // a `<div>` and an attributed run inside a `<span>` under any options,
    // and only `html_elements` pairs the tags back into the container the
    // gesture built. A block's attributes come back on that container — the
    // `wrapped` shape — rather than on the block.
    t.block_attrs = if (k.html_elements) .wrapped else null;
    t.inline_attrs = k.html_elements;
    // `$…$` is inline math and `$$…$$` display math only under `math`, so
    // only there is `$` a byte a literal has to escape — in body text and in
    // link text alike. Without the flag a bare `$` is text and stays bare.
    if (k.math) {
        t.text_escapes = base.text_escapes.? ++ "$";
        t.link_text_escapes = base.link_text_escapes.? ++ "$";
    }
    return t;
}

fn setAuthorable(t: *syntax.Syntax, comptime m: AST.InlineMark, yes: bool) void {
    var d = t.inline_delims.get(m).?;
    d.authorable = yes;
    t.inline_delims.set(m, d);
}

/// Every table Markdown is authored by, one per `Key`. See `Key` for why the
/// set is exactly this big.
const tables: [Key.count]syntax.Syntax = blk: {
    var out: [Key.count]syntax.Syntax = undefined;
    for (0..Key.count) |i| out[i] = derive(Key.fromIndex(i));
    const frozen = out;
    break :blk frozen;
};

/// The table for DEFAULT parse options: what `format.zig`'s registry row points
/// at, what the serializer reads, and what `twig_format_supports` — which
/// answers without a document — reports.
///
/// A POINTER into `tables`, not a copy, so the registry row and `forOptions`
/// under a default config are the same address and cannot drift into two
/// answers. Twig's Markdown defaults have `strikethrough` on, so `~~x~~` is
/// authorable here; strict CommonMark is `forOptions(.commonmark)`, and is not
/// this.
pub const table: *const syntax.Syntax = forOptions(.{});

/// The table an editor over a document parsed with `opts` should consult.
pub fn forOptions(opts: Options) *const syntax.Syntax {
    return &tables[Key.of(opts).index()];
}

test "markdown SPELLS every mark and AUTHORS the ones its parse config reads back" {
    // The distinction `Delims.authorable` exists for. The serializer needs a
    // spelling for every mark so a djot document converts without losing
    // nodes; the editor must refuse the ones that would not reparse as the
    // mark they were meant to be — and which those are is a question about the
    // parse config, not about Markdown.
    for (std.enums.values(AST.InlineMark)) |m| {
        try std.testing.expect(table.inline_delims.get(m) != null);
    }

    // Under DEFAULTS: `**`/`*`, plus `~~` because `strikethrough` is on.
    const default_marks = [_]AST.InlineMark{ .strong, .emph, .delete };
    for (std.enums.values(AST.InlineMark)) |m| {
        const want = std.mem.indexOfScalar(AST.InlineMark, &default_marks, m) != null;
        try std.testing.expectEqual(want, table.inline_delims.get(m).?.authorable);
    }

    // Under strict CommonMark: the two the spec itself spells, and no more.
    const strict = forOptions(Options.commonmark);
    const strict_marks = [_]AST.InlineMark{ .strong, .emph };
    for (std.enums.values(AST.InlineMark)) |m| {
        const want = std.mem.indexOfScalar(AST.InlineMark, &strict_marks, m) != null;
        try std.testing.expectEqual(want, strict.inline_delims.get(m).?.authorable);
    }

    // `verbatim` moved to the text-leaf table with the rest of its family, and
    // is the one leaf an editor may toggle. No extension gates it.
    try std.testing.expect(table.text_leaf_delims.get(.verbatim).?.authorable);
    try std.testing.expect(!table.text_leaf_delims.get(.url).?.authorable);

    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "every derived table differs from base in the authorable flags and nothing else" {
    // The claim that makes deriving safe: `derive` touches only the gated
    // fields, so a future edit to it cannot quietly change an escape alphabet
    // or a marker in one table out of forty-eight. The one alphabet that
    // moves, moves by exactly `$`, and only under `math`.
    for (&tables) |*t| {
        {
            t.assertCoherent();
            for (std.enums.values(AST.InlineMark)) |m| {
                const b = base.inline_delims.get(m).?;
                const d = t.inline_delims.get(m).?;
                try std.testing.expectEqualStrings(b.open, d.open);
                try std.testing.expectEqualStrings(b.close, d.close);
                // Only these three move; the rest keep `base`'s answer.
                if (m != .mark and m != .delete and m != .insert) {
                    try std.testing.expectEqual(b.authorable, d.authorable);
                }
            }
            try std.testing.expectEqual(base.heading_marker, t.heading_marker);
            const k = Key.fromIndex(t - &tables[0]);
            try std.testing.expectEqual(k.html_elements, t.inline_delims.get(.insert).?.authorable);
            const text_escapes = if (k.math) base.text_escapes.? ++ "$" else base.text_escapes.?;
            const link_text_escapes = if (k.math) base.link_text_escapes.? ++ "$" else base.link_text_escapes.?;
            try std.testing.expectEqualStrings(text_escapes, t.text_escapes.?);
            try std.testing.expectEqualStrings(link_text_escapes, t.link_text_escapes.?);
            try std.testing.expectEqualStrings(base.block_start_escapes.?, t.block_start_escapes.?);
            try std.testing.expectEqualStrings(base.thematic_break.?, t.thematic_break.?);
            // A palette only ever rides on an authorable mark, which
            // `assertCoherent` also pins from the other side.
            if (t.mark_colors != null) try std.testing.expect(t.inline_delims.get(.mark).?.authorable);
            // And the directive and attribute claims only ever ride on the
            // renderer that prints one — the other implication
            // `assertCoherent` pins.
            if (t.names_leaf_containers) try std.testing.expect(t.renderBlock != null);
            if (t.block_attrs != null or t.inline_attrs) try std.testing.expect(t.renderBlock != null);
        }
    }
    // `base` itself is nobody's answer: it states no gated flag at all.
    try std.testing.expect(!base.inline_delims.get(.mark).?.authorable);
    try std.testing.expect(!base.inline_delims.get(.delete).?.authorable);
    try std.testing.expect(base.mark_colors == null);
    try std.testing.expect(!base.names_leaf_containers);
    try std.testing.expect(base.block_attrs == null);
    try std.testing.expect(!base.inline_attrs);
}

test "the key is a bijection onto the set" {
    for (0..Key.count) |i| try std.testing.expectEqual(i, Key.fromIndex(i).index());
}

test "the colour palette offers every circle highlight.zig knows" {
    const colors = forOptions(.{ .highlight = true, .highlight_colors = true });
    const mc = colors.mark_colors.?;
    try std.testing.expectEqualStrings(highlight.attr_key, mc.attr_key);
    try std.testing.expectEqual(std.enums.values(highlight.Color).len, mc.colors.len);
    for (std.enums.values(highlight.Color)) |c| {
        try std.testing.expectEqualStrings(c.emoji(), mc.prefixFor(c.name()).?);
        try std.testing.expectEqualStrings(c.name(), mc.prefixAt(c.emoji()).?.name);
    }
    // A colour the parser would not read back is not one the editor may write.
    try std.testing.expect(mc.prefixFor("pink") == null);
    try std.testing.expect(mc.prefixAt("x") == null);
}

test "forOptions: each flag moves exactly its own mark" {
    // Defaults: strikethrough on, highlight off — and `table` IS that answer,
    // by address, so the registry row cannot drift from the picker.
    try std.testing.expectEqual(table, forOptions(.{}));
    try std.testing.expect(table.inline_delims.get(.delete).?.authorable);
    try std.testing.expect(!table.inline_delims.get(.mark).?.authorable);
    try std.testing.expect(table.mark_colors == null);

    // Strikethrough off is a real configuration and a real answer: strict
    // CommonMark has no `~~`, so a toggle there would write literal tildes.
    const strict = forOptions(Options.commonmark);
    try std.testing.expect(!strict.inline_delims.get(.delete).?.authorable);
    try std.testing.expectEqual(strict, forOptions(.{ .strikethrough = false }));

    // GFM: strikethrough on, no highlight — the same answer as the defaults.
    try std.testing.expectEqual(table, forOptions(Options.gfm));

    // Highlights, with and without colours, and both with strikethrough still
    // answering for itself.
    const hi = forOptions(.{ .highlight = true });
    try std.testing.expect(hi.inline_delims.get(.mark).?.authorable);
    try std.testing.expect(hi.inline_delims.get(.delete).?.authorable);
    try std.testing.expect(hi.mark_colors == null);

    const colors = forOptions(.{ .highlight = true, .highlight_colors = true });
    try std.testing.expect(colors.mark_colors != null);
    try std.testing.expect(colors != hi);

    const colors_no_strike = forOptions(.{
        .strikethrough = false,
        .highlight = true,
        .highlight_colors = true,
    });
    try std.testing.expect(colors_no_strike.mark_colors != null);
    try std.testing.expect(!colors_no_strike.inline_delims.get(.delete).?.authorable);
    try std.testing.expect(colors_no_strike != colors);

    // Colours are inert without a highlight to colour, as in the parser.
    try std.testing.expectEqual(table, forOptions(.{ .highlight_colors = true }));

    // Directives are the third axis, and they move only their own answer:
    // `::name` is a paragraph of colons under the defaults and a container
    // with the flag on, so a gesture may mint one only on the right.
    try std.testing.expect(!table.names_leaf_containers);
    const dir = forOptions(.{ .directives = true });
    try std.testing.expect(dir.names_leaf_containers);
    try std.testing.expect(dir != table);
    try std.testing.expect(dir.inline_delims.get(.delete).?.authorable);
    try std.testing.expect(!dir.inline_delims.get(.mark).?.authorable);
    // A flag that keys no table still changes nothing about which one is
    // returned — the point of the set being small.
    try std.testing.expectEqual(table, forOptions(.{ .footnotes = false }));

    // Math is the fifth, and it moves only the escape alphabets: `$` opens
    // a formula with the flag on and is text without it.
    const math = forOptions(.{ .math = true });
    try std.testing.expect(math != table);
    try std.testing.expect(std.mem.indexOfScalar(u8, math.text_escapes.?, '$') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, math.link_text_escapes.?, '$') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, table.text_escapes.?, '$') == null);
    try std.testing.expect(forOptions(.{ .directives = true, .math = true }).names_leaf_containers);

    // HTML elements are the fourth axis, and they move only the two attribute
    // claims: a `<div>` around a block and a `<span>` around a run are raw
    // HTML under the defaults and a container with the flag on.
    try std.testing.expect(table.block_attrs == null);
    try std.testing.expect(!table.inline_attrs);
    const html = forOptions(.{ .html_elements = true });
    try std.testing.expectEqual(syntax.BlockAttrs.wrapped, html.block_attrs.?);
    try std.testing.expect(html.inline_attrs);
    try std.testing.expect(html != table);
    try std.testing.expect(!html.names_leaf_containers);
    try std.testing.expect(html.inline_delims.get(.delete).?.authorable);
    const both = forOptions(.{ .html_elements = true, .directives = true });
    try std.testing.expect(both.names_leaf_containers and both.inline_attrs);

    // Forty-eight configurations, forty-eight distinct tables — the set has
    // no duplicate a caller could reach two ways.
    var all: [Key.count]*const syntax.Syntax = undefined;
    var n: usize = 0;
    for ([_]bool{ false, true }) |st| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ true, true } }) |h| {
            for ([_]bool{ false, true }) |d| {
                for ([_]bool{ false, true }) |e| {
                    for ([_]bool{ false, true }) |m| {
                        all[n] = forOptions(.{
                            .strikethrough = st,
                            .highlight = h[0],
                            .highlight_colors = h[1],
                            .directives = d,
                            .html_elements = e,
                            .math = m,
                        });
                        n += 1;
                    }
                }
            }
        }
    }
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
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
