//! Document -> HTML renderer, mirroring `languages/djot/html.zig` exactly
//! (see that file's module doc comment for the full rationale — this is the
//! same "thin adapter over the shared, language-neutral printer at
//! `languages/html/serializer.zig`" split, for the same reason).
//!
//! Markdown resolves `link`/`image` references at PARSE time (Phase 2), so
//! — unlike djot — this adapter's `Html.Context` always has EMPTY
//! `references`/`auto_references`: there is nothing for the shared printer
//! to look up for those. Footnotes are the one Markdown construct that
//! (like djot's) resolves at RENDER time instead (see `markdown.zig`'s
//! module doc comment and `Document.footnotes`'s doc comment), so
//! `Context.footnotes` is the only side table this adapter actually
//! populates from `doc`.
//!
//! This is the module `cli/format.zig`'s markdown registry entry renders
//! through (`renderHtmlMarkdown`) instead of the bare generic
//! `Html.serialize`, precisely so footnotes resolve when converting via the
//! CLI — using the generic printer directly (`ctx = null`) would silently
//! drop every footnote reference/definition (an unresolved
//! `footnote_reference` renders as if its definition were simply missing —
//! see `languages/html/serializer.zig`'s module doc comment).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");
const Document = markdown.Document;
const Html = @import("../html/html.zig");

pub const RenderOptions = struct {
    warn: ?*const fn (message: []const u8) void = null,
};

/// Same error set `Html`'s printer returns: write failures from `writer`
/// merged with allocation failures (footnote index/id tracking needs to
/// allocate).
pub const RenderError = Html.RenderError;

/// Build the shared printer's reference/footnote side tables from `doc`'s
/// public fields. `references`/`auto_references` stay at their `.empty`
/// default -- Markdown has no render-time reference table (see this file's
/// module doc comment) -- so only `footnotes` is ever non-empty here.
fn contextFor(doc: *const Document) Html.Context {
    return .{ .footnotes = doc.footnotes };
}

/// Render `doc` (rooted at `doc.ast.root`, normally a `doc` node) to HTML,
/// writing to `writer`. Delegates to `Html.Renderer` directly (rather than
/// `Html.serialize`) so `options.warn` can be threaded through to the
/// printer's own `RenderOptions` -- mirrors `Djot.html.render` exactly.
pub fn render(allocator: Allocator, doc: *const Document, writer: *Writer, options: RenderOptions) RenderError!void {
    const ctx = contextFor(doc);
    // Route through the shared printer with this dialect's conventions plus
    // this call's `warn` hook. The dialect comes from the document itself
    // (`doc.options.dialect`, recorded at parse time) rather than from this
    // call, so a caller can't render a GFM document with CommonMark's
    // conventions by forgetting to say so twice. See `ParseOptions.dialect`
    // and `Html.commonmark_render_options`/`Html.gfm_render_options`.
    var render_opts = switch (doc.options.dialect) {
        .commonmark => Html.commonmark_render_options,
        .gfm => Html.gfm_render_options,
    };
    render_opts.warn = options.warn;
    var r = Html.Renderer.init(allocator, &doc.ast, writer, &ctx, render_opts);
    defer r.deinit();
    try r.renderNode(doc.ast.root);
}

/// Convenience wrapper: render to an owned string.
pub fn renderAlloc(allocator: Allocator, doc: *const Document, options: RenderOptions) Html.RenderAllocError![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    // `Writer.Allocating` only ever fails (`error.WriteFailed`) when its own
    // backing allocation fails, so it collapses to `error.OutOfMemory`;
    // `error.UnsafeMetadata` propagates as a real content refusal (a `metadata`
    // node whose body contains `</script`).
    render(allocator, doc, &out.writer, options) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.UnsafeMetadata => return error.UnsafeMetadata,
    };
    return out.toOwnedSlice();
}

const testing = std.testing;

test "dialect: the same table prints twig-markdown-shaped by default and GFM-shaped under .gfm" {
    // The contract this file exists to enforce: twig prints djot, markdown,
    // and GFM DISTINCTLY. Both dialects parse this to the same
    // `table`/`row`/`cell` nodes; only the printing differs, and the dialect
    // rides along on the Document rather than being re-supplied at render
    // time. (Djot's third spelling — bare `<tr>`, no sections — is pinned by
    // `languages/djot/conformance.zig`.)
    const src = "| a |\n| :-: |\n| 1 |\n";

    var md_doc = try markdown.parse(testing.allocator, src, .{ .tables = true });
    defer md_doc.deinit();
    const md_out = try renderAlloc(testing.allocator, &md_doc, .{});
    defer testing.allocator.free(md_out);

    var gfm_doc = try markdown.parse(testing.allocator, src, markdown.ParseOptions.gfm);
    defer gfm_doc.deinit();
    const gfm_out = try renderAlloc(testing.allocator, &gfm_doc, .{});
    defer testing.allocator.free(gfm_out);

    // Both section their rows — that's well-formed HTML, not a GFM quirk.
    try testing.expect(std.mem.indexOf(u8, md_out, "<thead>") != null);
    try testing.expect(std.mem.indexOf(u8, gfm_out, "<thead>") != null);
    // They disagree only on how a cell's alignment is spelled.
    try testing.expect(std.mem.indexOf(u8, md_out, "<th style=\"text-align: center;\">a</th>") != null);
    try testing.expect(std.mem.indexOf(u8, gfm_out, "<th align=\"center\">a</th>") != null);
    try testing.expect(std.mem.indexOf(u8, md_out, "align=\"center\"") == null);
    try testing.expect(std.mem.indexOf(u8, gfm_out, "text-align") == null);
}

test "dialect: tagfilter is GFM-only, so default markdown passes raw <title> through" {
    // Unlike the table spellings above, the tagfilter changes what the HTML
    // DOES rather than how it's spelled, so it stays scoped to the dialect
    // that actually specifies it.
    const src = "<strong> <title>\n";

    var md_doc = try markdown.parse(testing.allocator, src, .{});
    defer md_doc.deinit();
    const md_out = try renderAlloc(testing.allocator, &md_doc, .{});
    defer testing.allocator.free(md_out);
    try testing.expect(std.mem.indexOf(u8, md_out, "<title>") != null);

    var gfm_doc = try markdown.parse(testing.allocator, src, markdown.ParseOptions.gfm);
    defer gfm_doc.deinit();
    const gfm_out = try renderAlloc(testing.allocator, &gfm_doc, .{});
    defer testing.allocator.free(gfm_out);
    try testing.expect(std.mem.indexOf(u8, gfm_out, "&lt;title>") != null);
    // `<strong>` isn't blacklisted, so it stays live in both.
    try testing.expect(std.mem.indexOf(u8, gfm_out, "<strong>") != null);
}

test "renders a simple paragraph with emphasis" {
    var doc = try markdown.parse(testing.allocator, "hello *world*\n", .{});
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>hello <em>world</em></p>\n", html);
}

test "footnote: a reference + definition render the noteref, sup, and endnotes section" {
    var doc = try markdown.parse(testing.allocator,
        \\text[^a] more
        \\
        \\[^a]: the note
        \\
    , .{ .footnotes = true });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "role=\"doc-noteref\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<sup>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "role=\"doc-endnotes\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fn1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "the note") != null);
    // A backlink from the note back to its reference.
    try testing.expect(std.mem.indexOf(u8, html, "href=\"#fnref1\"") != null);
}

test "footnote: a forward reference (used before its definition) still resolves" {
    var doc = try markdown.parse(testing.allocator,
        \\see[^a]
        \\
        \\[^a]: later
        \\
    , .{ .footnotes = true });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "later") != null);
}

test "footnote: multiple footnotes are numbered in reference order" {
    var doc = try markdown.parse(testing.allocator,
        \\one[^b] two[^a]
        \\
        \\[^a]: A
        \\[^b]: B
        \\
    , .{ .footnotes = true });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    // `[^b]` is referenced first in the text, so it claims footnote 1.
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"fnref2\"") != null);
    const fn1 = std.mem.indexOf(u8, html, "id=\"fn1\"").?;
    const fn2 = std.mem.indexOf(u8, html, "id=\"fn2\"").?;
    try testing.expect(fn1 < fn2);
    try testing.expect(std.mem.indexOf(u8, html[fn1..fn2], "B") != null);
}

test "footnotes OFF: '[^a]' with no definition falls back to ordinary CommonMark link parsing" {
    // With `footnotes = false`, `'['` never special-cases `^` at all -- this
    // is ordinary shortcut-reference-link syntax with an unresolved label
    // ("^a", no matching `link_references` entry), which CommonMark falls
    // back to literal bracket text for (same as any other undefined
    // `[label]` -- see `block.zig`'s own "unresolved reference falls back
    // to literal brackets" coverage).
    var doc = try markdown.parse(testing.allocator, "see [^a]\n", .{ .footnotes = false });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "doc-endnotes") == null);
    try testing.expect(std.mem.indexOf(u8, html, "doc-noteref") == null);
    try testing.expect(std.mem.indexOf(u8, html, "[^a]") != null);
}

test "footnotes OFF: '[^a]: note' is an ordinary link reference definition (the '^' has no special meaning)" {
    // Confirms the flag genuinely gates the `^`-prefixed grammar rather than
    // just suppressing rendering: with it off, `[^a]: note` is valid,
    // ordinary CommonMark link reference definition syntax (labels may
    // contain `^`), so a shortcut reference to it resolves as a normal
    // link, NOT a footnote noteref.
    var doc = try markdown.parse(testing.allocator, "see[^a]\n\n[^a]: /note\n", .{ .footnotes = false });
    defer doc.deinit();
    const html = try renderAlloc(testing.allocator, &doc, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "doc-endnotes") == null);
    try testing.expect(std.mem.indexOf(u8, html, "doc-noteref") == null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/note\"") != null);
}
