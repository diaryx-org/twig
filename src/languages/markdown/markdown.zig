//! Markdown: the entry point for this language module, mirroring
//! `languages/djot/djot.zig`'s / `languages/xml/xml.zig`'s role for their
//! formats. Wires the block parser (`block.zig`, which delegates inline
//! content to `inline.zig`) into one `parse` call, and aggregates every
//! sibling file's `test {}` blocks (the fig/djot/xml convention).
//!
//! ── Scope: this is Phase 2 of 3 ─────────────────────────────────────────
//! Twig's Markdown support targets CommonMark 0.31.2
//! (https://spec.commonmark.org/0.31.2/), built in three phases:
//!   - Phase 1 (done): block structure (headings, lists, block quotes, code
//!     blocks, HTML blocks, thematic breaks, link reference definitions)
//!     plus a minimal inline subset (plain text, backslash escapes, entity/
//!     numeric character references, code spans, soft/hard breaks).
//!   - Phase 2 (this): the rest of CommonMark's inline grammar — emphasis/
//!     strong (the delimiter-run algorithm), links, images, autolinks, raw
//!     inline HTML — resolved AT PARSE TIME against the `labels.references`
//!     table Phase 1 populates (unlike djot, Markdown has no render-time
//!     reference table: a resolved reference link is emitted as a `link`
//!     node with `destination` already set and `reference == null`). See
//!     `block.zig` and `inline.zig`'s module doc comments for the precise
//!     boundary and documented simplifications/approximations.
//!   - Phase 3 (later): GFM extensions and other options `ParseOptions`
//!     already declares (tables, strikethrough, task lists, footnotes,
//!     definition lists, frontmatter, math, highlight), plus GFM's *extended*
//!     autolinks (bare `www.`/`http` URLs in text, as opposed to Phase 2's
//!     CommonMark-core `<scheme:...>` form).
//! Do not read the presence of `ParseOptions` fields as "already
//! implemented" — see that file's doc comment.
//!
//! ── Rendering ────────────────────────────────────────────────────────────
//! `Markdown.parse` targets the same shared `AST` every other language
//! module does. For everything EXCEPT footnotes, that means MD->HTML can go
//! straight through the generic printer, `Html.serialize`/`Html.serializeAlloc`
//! (`languages/html/serializer.zig`), the same way `languages/html/conformance.zig`
//! proves it works for djot: Phase 2 resolves every reference link/image at
//! PARSE time, so (unlike djot) `Document.labels.references` never needs to
//! be consulted by the renderer at all. Footnotes (`ParseOptions.footnotes`)
//! are the one exception — like djot's footnotes, they're
//! resolved/numbered/backlinked entirely at RENDER time against
//! `Document.labels.footnotes`, which the shared printer only does when
//! handed an `Html.Context` — so `Markdown.parse` output should be rendered
//! via THIS package's own `html.zig` (`Markdown.html.render`/`.renderAlloc`,
//! mirroring `Djot.html`), not the bare generic printer, whenever footnotes
//! might be in play (`format.zig`'s registry does exactly this).
//!
//! ── `Document` ───────────────────────────────────────────────────────────
//! `parse` returns the shared `Document` (`src/document.zig`). Link reference
//! definitions (`[label]: url "title"`) are parsed and stripped out of the
//! block stream by `block.zig` (see its module doc comment), and their labels
//! land in `Document.labels.references`, where Phase 2 resolves `link`/`image`
//! nodes against them; footnote definitions land in `labels.footnotes` for the
//! render-time reason above. Neither kind of definition is attached in the
//! tree — they are resolved by label, never rendered in place.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block = @import("block.zig");
const inline_mod = @import("inline.zig");

pub const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
pub const ParseOptions = @import("options.zig");
pub const highlight = @import("highlight.zig");
pub const html = @import("html.zig");
pub const serializer = @import("serializer.zig");

pub const Parser = block.Parser;

/// Parse `source` (Markdown/CommonMark text) into a `Document`. The returned
/// document borrows `source` and owns everything else (its AST holds copies
/// of every string it needs); free it with `doc.deinit()`.
///
/// `options` decides what parses; it is not recorded on the result. The one
/// option rendering needs — `options.dialect`, for GFM's HTML conventions —
/// is passed to `html.render` by whoever holds the preset (`format.zig`'s
/// registry, where each Markdown dialect is a row and `ParsedDoc.format`
/// says which).
pub fn parse(allocator: Allocator, source: []const u8, options: ParseOptions) Allocator.Error!Document {
    return block.parse(allocator, source, options);
}

/// Whether `angled` — a whole `<…>` run, brackets included — spells a
/// CommonMark autolink (an absolute URI or an email) rather than raw HTML or
/// literal text. The inline scanner's own two recognizers, asked in the order
/// the scanner itself dispatches them, so a caller choosing how to spell a
/// destination gets the answer a reparse will give. Unlike djot's classifier
/// this needs the brackets: CommonMark's grammar is defined over the whole
/// `<…>` run, and the recognizers report where it ends.
///
/// Nothing this accepts can be misread as an HTML block when it lands alone in
/// a paragraph: every accepted form has a `:` or `@` inside the first token,
/// and no HTML block start condition admits either in a tag name.
pub fn spellsAutolink(angled: []const u8) bool {
    if (angled.len < 2 or angled[0] != '<') return false;
    if (inline_mod.scanAutolinkUri(angled, 0)) |end| if (end == angled.len) return true;
    if (inline_mod.scanAutolinkEmail(angled, 0)) |end| if (end == angled.len) return true;
    return false;
}

test {
    _ = @import("entities.zig");
    _ = @import("attributes.zig");
    _ = inline_mod;
    _ = block;
    _ = @import("html.zig");
    _ = @import("highlight.zig");
    _ = @import("conformance.zig");
    _ = @import("gfm_conformance.zig");
}

const testing = std.testing;

test "parse produces a doc with a paragraph" {
    var doc = try parse(testing.allocator, "hello world\n", .{});
    defer doc.deinit();

    const ast = doc.ast;
    try testing.expect(ast.nodes[ast.root].kind == .doc);
    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[para_id].kind == .para);
}

test "headings are flat -- no section wrapper, no auto id (unlike djot)" {
    var doc = try parse(testing.allocator, "# Hello World\n\npara\n", .{});
    defer doc.deinit();

    const ast = doc.ast;
    const heading_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[heading_id].kind == .heading);
    try testing.expectEqual(@as(u32, 1), ast.nodes[heading_id].kind.heading.level);
    try testing.expect(ast.attrsOf(heading_id).isEmpty());

    const para_id = ast.nodes[heading_id].next_sibling orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[para_id].kind == .para);
}

/// Small documents exercising the shared engine contract; not a conformance corpus.
/// These are the default flavor's; each dialect row declares its own below,
/// in the grammar it actually reads.
pub const samples: []const []const u8 = &.{
    "",
    "A paragraph with *emphasis* and **strong** text.\n",
    "# Heading\n\n> Quote\n\n- first\n- second\n",
    "- [x] done\n- [ ] pending\n",
    "``` zig\nconst x = 1;\n```\n",
};

/// Strict CommonMark's harness samples: only what the spec itself spells, so
/// the row round-trips without leaning on an extension it does not read.
pub const commonmark_samples: []const []const u8 = &.{
    "",
    "A paragraph with *emphasis* and **strong** text.\n",
    "# Heading\n\n> Quote\n\n- first\n- second\n",
    "Setext\n======\n\n    indented code\n",
};

/// GFM's harness samples: the spec's constructs plus the four GFM
/// extensions, so a table and a strikethrough have to survive the row's own
/// reparse.
pub const gfm_samples: []const []const u8 = &.{
    "",
    "A paragraph with ~~struck~~ and **strong** text.\n",
    "| a | b |\n| --- | ---: |\n| 1 | 2 |\n",
    "- [x] done\n- [ ] pending\n\nSee https://example.com now.\n",
};
