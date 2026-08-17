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
//! ── Why it stops where it does ─────────────────────────────────────────────
//! Everything left `null` below is null because HTML's spelling has a different
//! SHAPE, not because nobody filled it in. Three shapes are missing:
//!
//!   * `heading_marker` is a byte repeated `level` times then a space. HTML's
//!     `<h1>…</h1>` is a wrapping pair carrying the level in BOTH ends.
//!   * `ContainerSpelling` prefixes every LINE. `<blockquote>` wraps a range,
//!     and a list needs a per-item `<li>` — a different algorithm, not a
//!     different alphabet, which is the premise `syntax.zig` is built on.
//!   * `CodeFence` measures the longest run of its fence byte. `<pre><code>`
//!     doesn't measure anything; it entity-escapes a body instead.
//!
//! And one mechanism is missing: the escape fields (`text_escapes`,
//! `link_text_escapes`, `link_dest_escapes`) all feed routines in
//! `ast/editor.zig` that emit a literal BACKSLASH before a byte from the
//! alphabet. HTML escapes with entities, and a link's destination lives in a
//! quoted `href` attribute rather than in `(…)`. Filling those fields with
//! `&<>` would make `insertLiteral` write `\&`, which is two literal characters
//! in HTML and not an escape at all. They stay `null`, and every gesture that
//! reads them stays a clean `error.UnsupportedFormat`.
//!
//! Lifting those four is a change to `syntax.zig` and `editor.zig`, not to this
//! file — which is the point of keeping this file inert.

const std = @import("std");
const syntax = @import("../../syntax.zig");

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

    // ── Deliberately absent ────────────────────────────────────────────────
    // `heading_marker`, `container_spelling`, `code_fence`, `task_marker`,
    // `footnote`, `link_*_escapes`, `text_escapes`/`block_start_escapes`: the
    // shape and mechanism mismatches in this file's doc comment.
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
    const AST = @import("../../ast/ast.zig");
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
    const AST = @import("../../ast/ast.zig");
    for (std.enums.values(AST.TextLeafKind)) |l| {
        try std.testing.expectEqual(l == .verbatim, table.text_leaf_delims.get(l) != null);
    }
    try std.testing.expect(table.text_leaf_delims.get(.verbatim).?.authorable);
}

test "html spells no block structure and no escape alphabet" {
    // The four shape/mechanism mismatches, pinned so lifting one is a
    // deliberate edit here rather than a silent drift in `syntax.zig`.
    try std.testing.expect(table.heading_marker == null);
    try std.testing.expect(table.container_spelling.get(.block_quote) == null);
    try std.testing.expect(table.container_spelling.get(.bullet_list) == null);
    try std.testing.expect(table.container_spelling.get(.ordered_list) == null);
    try std.testing.expect(table.code_fence == null);
    // Backslash escaping is the mechanism HTML does not have; `assertCoherent`
    // only pairs their nullness, so the fact that BOTH pairs are null — rather
    // than half-filled with `&<>` — is stated here.
    try std.testing.expect(table.text_escapes == null);
    try std.testing.expect(table.block_start_escapes == null);
    try std.testing.expect(table.link_text_escapes == null);
    try std.testing.expect(table.link_dest_escapes == null);
    // No footnotes, no task boxes, no autolink form, no attribute spelling.
    try std.testing.expect(table.footnote == null);
    try std.testing.expect(table.task_marker == null);
    try std.testing.expect(table.spellsAutolink == null);
    try std.testing.expect(table.attr_spelling == null);
    table.assertCoherent();
}

test "html spells the rule and the break as void tags" {
    try std.testing.expectEqualStrings("<hr>", table.thematic_break.?);
    try std.testing.expectEqualStrings("<br>", table.cell_line_break.?);
}
