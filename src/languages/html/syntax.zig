//! HTML's surface spelling — the table `Editor`'s authoring gestures consult.
//! See `src/syntax.zig` for the model.
//!
//! ── Why HTML has a table at all ────────────────────────────────────────────
//! It used to carry `Syntax.none` on the reasoning that authoring gestures
//! spell lightweight markup and HTML has none. Half of that is right. HTML has
//! no `**`, no `> ` prefix, no fence — but it spells seven of the nine inline
//! marks with a plain element pair, and `html/parser.zig` reads every one of
//! them back (`semanticKind`'s `em`/`strong`/`mark`/`ins`/`del`/`sup`/`sub`
//! arms). A `Delims{open, close}` is exactly a tag pair. So Cmd-B over HTML
//! needs no new code — only the bytes, which is what this file is.
//!
//! ── Where a tag pair is not enough: the renderers ──────────────────────────
//! The rest of HTML's spellings have no table shape at all, and they are why
//! `Syntax` grew its renderer family (see its module doc comment):
//!
//!   * A literal is spelled with ENTITIES. Every alphabet field in `Syntax`
//!     feeds a routine that writes a backslash before a byte, and filling
//!     `text_escapes` with `&<>` would make `insertLiteral` write `\&` — two
//!     literal characters here, not an escape. So the alphabets stay `null`
//!     and `renderText` below writes `&amp;`/`&lt;`/`&gt;` instead, in every
//!     position alike: `<pre>` reads `&lt;` the same way `<p>` does.
//!   * Every block is a WRAPPING PAIR. A heading carries its level in both
//!     ends, so there is no `heading_marker` to rewrite; `ContainerSpelling`
//!     prefixes every LINE where `<blockquote>` wraps a range and a list needs
//!     a per-item `<li>`; `CodeFence` measures the longest run of its fence
//!     byte where `<pre><code>` entity-escapes a body; and
//!     `link_text_escapes`/`link_dest_escapes` feed `[text](dest)` where a
//!     destination here lives in a quoted `href`. Each is a different
//!     ALGORITHM, not a different alphabet — the premise `syntax.zig` is built
//!     on — so those fields stay `null` and `renderBlock` is the serializer
//!     over a fragment: the editor builds the node (`Editor.setBlock`,
//!     `toggleBlockContainer`, `toggleCodeBlock`, `setCodeLanguage`,
//!     `insertLink`, `insertImage`) and the tag pair falls out of the tree.
//!
//! ── What still stops, and why ──────────────────────────────────────────────
//! A task box, a footnote and a table edit. HTML has no native spelling for
//! the first two — `<input type="checkbox">` is a form control the parser
//! reads as a container, and a footnote is a convention of `<sup><a>` and an
//! `<li>` somewhere else — and a table is already authored over a parsed one
//! by `table_edit.zig`, whose pipe spelling this format cannot write back.
//! `docs/proposals/editable-html-block-elements.md` is where that line was
//! drawn: what the parser reads back to a semantic kind is authorable, and
//! nothing else is.

const std = @import("std");
const syntax = @import("../../syntax.zig");
const Writer = std.Io.Writer;
const AST = @import("../../ast/ast.zig");
const serializer = @import("serializer.zig");

/// HTML's literal: the three bytes that open markup become entities, in every
/// position — there is no line-start alphabet because no HTML byte opens a
/// block at column zero, and no verbatim exemption because a `<pre>` body
/// decodes entities exactly as a `<p>` does. Mirrors `serializer.zig`'s
/// `writeEscaped` for text content, and stays byte-for-byte what its
/// `parser.zig` decodes back, so an inserted `str` reparses as itself.
fn renderText(_: *const syntax.Syntax, text: []const u8, _: syntax.TextPosition, out: *Writer) Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => try out.writeByte(c),
        }
    }
}

/// The serializer over one node — HTML's printer takes a node id directly, so
/// no re-rooting adapter is needed. Label-free (`ctx = null`): a fragment the
/// editor builds resolves nothing by label.
fn renderBlock(allocator: std.mem.Allocator, ast: *const AST, root: AST.Node.Id, out: *Writer) anyerror!void {
    try serializer.serializeNode(allocator, ast, root, out, null);
}

pub const table: syntax.Syntax = .{
    // Seven of nine. Each is the tag `html/serializer.zig` emits AND the tag
    // `html/parser.zig` maps back to this very mark, so a toggle reverses.
    //
    // The aliases are deliberately absent: `<b>`, `<i>` and `<s>` parse back as
    // strong/emph/delete too, so a document can hold them, but a gesture has to
    // pick ONE spelling to author and the semantic tag is the one the serializer
    // already emits. Toggling an existing `<b>` OFF still works — `Splicer`
    // strips via the parser's `content_span` rather than by matching these bytes
    // (see `splicer.zig`'s `toggleInline`), so the alias needs no entry here.
    // The one visible consequence: toggling `<b>x</b>` off and on again yields
    // `<strong>x</strong>`. Normalizing, not byte-identical.
    .inline_delims = .init(.{
        .emph = .{ .open = "<em>", .close = "</em>" },
        .strong = .{ .open = "<strong>", .close = "</strong>" },
        .mark = .{ .open = "<mark>", .close = "</mark>" },
        .superscript = .{ .open = "<sup>", .close = "</sup>" },
        .subscript = .{ .open = "<sub>", .close = "</sub>" },
        .insert = .{ .open = "<ins>", .close = "</ins>" },
        .delete = .{ .open = "<del>", .close = "</del>" },
        // The two the serializer renders as CHARACTERS — curly quotes, not a
        // tag pair (see its `double_quoted`/`single_quoted` arms). The parser
        // has no rule turning a curly quote back into a quoted container, so
        // there is no spelling here to author OR to emit: `null`, not a `<q>`
        // the round trip would lose. This is where HTML differs from djot and
        // Markdown, which both spell all nine.
        .double_quoted = null,
        .single_quoted = null,
    }),
    // `<code>` is the one text leaf HTML spells as a pair the parser reads back
    // — and only when the element holds exactly one text child, which is what a
    // wrap over a plain selection produces (`html/parser.zig`'s `code` arm).
    //
    // The rest are `null` for the reason `verbatim` is not: HTML spells them,
    // but not as a SYMMETRIC PAIR. A url or email is `<a href="…">text</a>`,
    // where the payload sits in an attribute; a footnote is a `<sup><a>` pair
    // plus a matching `<li>` elsewhere in the document. `Delims` cannot describe
    // either, and inventing one that drops the destination would make a toggle
    // lossy in a way `error.UnsupportedFormat` isn't.
    .text_leaf_delims = .init(.{
        .verbatim = .{ .open = "<code>", .close = "</code>" },
        .symb = null,
        .inline_math = null,
        .display_math = null,
        .url = null,
        .email = null,
        .footnote_reference = null,
        .citation_reference = null,
        .substitution_reference = null,
    }),
    // What the serializer emits (its `thematic_break` arm renders an `hr` tag).
    // The void spelling, not the XHTML `<hr />` the `xhtml_void` option can
    // produce: both parse back to `.thematic_break`, and a gesture that writes
    // one form must be the form a round trip reproduces by default.
    .thematic_break = "<hr>",
    // `<br>` — `html/parser.zig` maps it to `.hard_break` and the serializer
    // emits it, so the token round-trips the way `Syntax.cell_line_break`
    // requires. Unlike Markdown, where `<br>` is borrowed raw HTML admitted only
    // because a GFM row is one source line, here it is simply how HTML spells a
    // break. The gesture is still cell-only (`Editor.insertLineBreak` checks for
    // an enclosing `.cell`), so this understates what HTML can do — a general
    // hard break is the same future work it is for every other format.
    .cell_line_break = "<br>",
    // A newline inside a `<p>` — insignificant whitespace to the renderer, and
    // exactly the line break a join needs: `<p>a\nb</p>` reparses as the ONE
    // paragraph the gesture claims to have made. This is the field that does
    // not move with `block_separator`, which is `null` here for the mirror
    // reason: a blank line between two `<p>`s is not what separates them, so
    // `splitBlock` refuses while `joinBlocks` does not.
    .line_join = "\n",

    // ── Renderers ──────────────────────────────────────────────────────────
    // The spellings no table can hold — see this file's doc comment.
    .renderText = renderText,
    .renderBlock = renderBlock,
    // An unknown element is the one HTML shape that needs no table at all: the
    // parser reads `<page-break></page-break>` back as a container whose
    // `name` is the tag, attributes and all, so a named leaf container printed
    // through `renderBlock` reparses carrying its name. (The reparsed `form`
    // is `null` — this parser classifies only `div` and `span`, because
    // whether any other tag is a block is a property of the stylesheet — which
    // is outside what `Syntax.names_leaf_containers` claims.)
    .names_leaf_containers = true,
    // Every attribute goes into the element's tag and comes back from it; an
    // anonymous inline container prints as `<span>` and returns named so.
    .block_attrs = .native,
    .inline_attrs = true,

    // ── Deliberately absent ────────────────────────────────────────────────
    // `heading_marker`, `container_spelling`, `code_fence`, `link_*_escapes`:
    // every one a wrapping pair, spelled through `renderBlock` instead.
    // `task_marker`, `footnote`: no native spelling — this file's doc comment.
    // `text_escapes`/`block_start_escapes`: `renderText` is not the alphabet
    // renderer, so it carries no alphabet — `assertCoherent` pins that.
    //
    // `spellsAutolink`: HTML has no autolink form at all — a bare `<https://x>`
    // is a tag with a nonsense name, never a link.
    //
    // `attr_spelling`: HTML is deliberately not a client of it. Its serializer's
    // `renderAttributes` merges a synthesized `extra` list, dedups against it and
    // escapes for a tag's interior — output machinery, not surface spelling. See
    // `syntax.zig`'s `AttrSpelling` doc.
};

test "html authors the seven marks it can read back, and neither quote" {
    const paired = [_]AST.InlineMark{ .emph, .strong, .mark, .superscript, .subscript, .insert, .delete };
    for (std.enums.values(AST.InlineMark)) |m| {
        const want = std.mem.indexOfScalar(AST.InlineMark, &paired, m) != null;
        const d = table.inline_delims.get(m);
        try std.testing.expectEqual(want, d != null);
        if (d) |dd| try std.testing.expect(dd.authorable);
    }
    // Every opener is a start tag and every closer its matching end tag — the
    // property that makes a wrap reparse as the mark it was meant to be.
    for (std.enums.values(AST.InlineMark)) |m| {
        const d = table.inline_delims.get(m) orelse continue;
        try std.testing.expect(std.mem.startsWith(u8, d.open, "<"));
        try std.testing.expect(std.mem.startsWith(u8, d.close, "</"));
        try std.testing.expectEqualStrings(d.open[1..], d.close[2..]);
    }
    table.assertCoherent();
    try std.testing.expect(table.authorable());
}

test "html spells `code` and no other text leaf" {
    for (std.enums.values(AST.TextLeafKind)) |l| {
        try std.testing.expectEqual(l == .verbatim, table.text_leaf_delims.get(l) != null);
    }
    try std.testing.expect(table.text_leaf_delims.get(.verbatim).?.authorable);
}

test "html spells no line-prefixed block structure and no backslash alphabet" {
    // The shape mismatches, pinned so that filling one in is a deliberate
    // edit here rather than a silent drift in `syntax.zig` — and pinned
    // BESIDE the renderer that answers each, because a null alphabet with no
    // renderer would be a gesture refused, and these are gestures that work.
    try std.testing.expect(table.renderBlock != null);
    try std.testing.expect(table.heading_marker == null);
    try std.testing.expect(table.container_spelling.get(.block_quote) == null);
    try std.testing.expect(table.container_spelling.get(.bullet_list) == null);
    try std.testing.expect(table.container_spelling.get(.ordered_list) == null);
    try std.testing.expect(table.code_fence == null);
    try std.testing.expect(table.link_text_escapes == null);
    try std.testing.expect(table.link_dest_escapes == null);
    // Backslash escaping is the mechanism HTML does not have: the alphabets
    // are null rather than half-filled with `&<>`, and the literal is spelled
    // by a renderer of HTML's own instead of the shared alphabet one.
    try std.testing.expect(table.text_escapes == null);
    try std.testing.expect(table.block_start_escapes == null);
    try std.testing.expect(table.renderText != null);
    try std.testing.expect(table.renderText != &syntax.renderTextByAlphabet);
    // No footnotes, no task boxes, no autolink form, no attribute spelling —
    // and no renderer answers these: they are the gestures HTML refuses.
    try std.testing.expect(table.footnote == null);
    try std.testing.expect(table.task_marker == null);
    try std.testing.expect(table.spellsAutolink == null);
    try std.testing.expect(table.attr_spelling == null);
    table.assertCoherent();
}

test "html spells a literal with entities, in every position" {
    for (std.enums.values(syntax.TextPosition)) |pos| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try table.renderText.?(&table, "a <b> & \\c", pos, &out.writer);
        // The backslash is content: it is not HTML's escape and is written as is.
        try std.testing.expectEqualStrings("a &lt;b&gt; &amp; \\c", out.written());
    }
}

test "html prints a fragment as the tag pair its parser reads back" {
    var b = AST.Builder.init(std.testing.allocator);
    defer b.deinit();
    const text = try b.addLeaf(.{ .str = "hi" });
    const em = try b.addContainer(.{ .inline_mark = .emph }, &.{text});
    const h = try b.addContainer(.{ .heading = .{ .level = 2 } }, &.{em});
    const view = b.view(h);
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try table.renderBlock.?(std.testing.allocator, &view, h, &out.writer);
    try std.testing.expectEqualStrings("<h2><em>hi</em></h2>\n", out.written());

    // The other shapes the editor builds where the alphabet is null, each
    // the element `html/parser.zig` reads back to the same kind. The
    // reparse itself is `languages/harness.zig`'s contract over every format
    // with a renderer; this pins HTML's bytes.
    var c = AST.Builder.init(std.testing.allocator);
    defer c.deinit();
    const p1 = try c.addContainer(.para, &.{try c.addLeaf(.{ .str = "a" })});
    const p2 = try c.addContainer(.para, &.{try c.addLeaf(.{ .str = "b" })});
    const list = try c.addContainer(.{ .bullet_list = .{ .tight = true } }, &.{
        try c.addContainer(.list_item, &.{p1}),
        try c.addContainer(.list_item, &.{p2}),
    });
    const code = try c.addLeaf(.{ .code_block = .{ .lang = "zig", .text = "a < b" } });
    const link = try c.addContainer(.{ .link = .{ .destination = "x?a=1&b=2", .reference = null } }, &.{try c.addLeaf(.{ .str = "t" })});
    const q = try c.addContainer(.block_quote, &.{ list, code, try c.addContainer(.para, &.{link}) });
    const qv = c.view(q);
    var qout: Writer.Allocating = .init(std.testing.allocator);
    defer qout.deinit();
    try table.renderBlock.?(std.testing.allocator, &qv, q, &qout.writer);
    try std.testing.expectEqualStrings(
        "<blockquote>\n<ul>\n<li>\na\n</li>\n<li>\nb\n</li>\n</ul>\n" ++
            "<pre><code class=\"language-zig\">a &lt; b</code></pre>\n" ++
            "<p><a href=\"x?a=1&amp;b=2\">t</a></p>\n</blockquote>\n",
        qout.written(),
    );
}

test "html spells the rule and the break as void tags" {
    try std.testing.expectEqualStrings("<hr>", table.thematic_break.?);
    try std.testing.expectEqualStrings("<br>", table.cell_line_break.?);
}
