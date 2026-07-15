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
//!     inline HTML — resolved AT PARSE TIME against the `link_references`
//!     table Phase 1 populates (unlike djot, Markdown has no render-time
//!     reference table: a resolved reference link is emitted as a `link`
//!     node with `destination` already set and `reference == null`). See
//!     `block.zig` and `inline.zig`'s module doc comments for the precise
//!     boundary and documented simplifications/approximations.
//!   - Phase 3 (later): GFM extensions and other options `ParseOptions`
//!     already declares (tables, strikethrough, task lists, footnotes,
//!     definition lists, frontmatter, math), plus GFM's *extended*
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
//! PARSE time, so (unlike djot's `Html.Context.references`) `Document
//! .link_references` never needs to be consulted by the renderer at all.
//! Footnotes (`self.options.footnotes`) are the one exception — like djot's
//! footnotes, they're resolved/numbered/backlinked entirely at RENDER time
//! (see `Document.footnotes`'s doc comment below), which the shared printer
//! only does when handed an `Html.Context` — so `Markdown.parse` output
//! should be rendered via THIS package's own `html.zig` (`Markdown.html
//! .render`/`.renderAlloc`, mirroring `Djot.html`), not the bare generic
//! printer, whenever footnotes might be in play (`cli/format.zig`'s
//! registry does exactly this).
//!
//! ── `Document` ───────────────────────────────────────────────────────────
//! Like djot (and unlike XML, which needs no side tables), Markdown needs a
//! wrapper around the shared `AST`: link reference definitions
//! (`[label]: url "title"`) are parsed and stripped out of the block stream
//! by `block.zig` (see its module doc comment), but their labels only
//! become useful once Phase 2 resolves `link`/`image` nodes against them —
//! so, exactly like djot's `Document.references`, they're carried
//! alongside the `AST` rather than folded into it. Footnote definitions
//! (`Document.footnotes`) are carried the same way, for the render-time
//! reason described above.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block = @import("block.zig");
const inline_mod = @import("inline.zig");

pub const AST = @import("../../ast/ast.zig");
pub const ParseOptions = @import("options.zig");
pub const html = @import("html.zig");
pub const serializer = @import("serializer.zig");

pub const Parser = block.Parser;

/// A parsed Markdown document: the language-neutral `AST` plus the
/// label -> `reference`-node table `inline.zig`'s link/image resolution
/// consults DURING parsing (`block.parse` calls `inline_mod.parseInline`
/// with this same map before `Document` is ever constructed — see
/// `block.zig`'s `resolvePendingInline`). Kept on `Document` after parsing
/// mainly for provenance/introspection (e.g. future editor tooling that
/// wants to see where a definition came from); unlike `Djot.Document
/// .references`, the shared HTML printer never needs to consult it, since
/// every resolvable `link`/`image` node already carries its resolved
/// `destination` by the time parsing finishes. Mirrors `Djot.Document`'s
/// general shape — see that type's doc comment for why side tables live
/// here rather than on the shared `AST` (XML/HTML have nothing like them).
pub const Document = struct {
    ast: AST,

    /// The options this document was parsed with. Retained so RENDERING can
    /// recover the dialect (`ParseOptions.dialect`) without the caller having
    /// to supply the flavor a second time — `html.zig` maps it to the shared
    /// printer's conventions. Every field defaults, so a `Document` assembled
    /// from a bare AST rather than by `parse` (`serializer.zig`'s
    /// `serializeAstAlloc`) simply gets twig's default flavor, which is what
    /// that path wants: it serializes back to Markdown source and never
    /// consults a render convention.
    options: ParseOptions = .{},

    /// Label (normalized: trimmed, internal whitespace collapsed, ASCII
    /// lowercased — see `block.zig`'s `normalizeLabel`) -> the `reference`
    /// node holding that link reference definition's destination (and, as
    /// a `title` attribute when present, its title). These `reference`
    /// nodes are NOT attached anywhere in `ast`'s tree: they're pure
    /// side-table entries that `inline.zig` resolves by label at PARSE
    /// time (never at render time, and never rendered in place).
    ///
    /// This map's KEYS are slices of `ast.owned_strings` (each key is the
    /// same string as its `reference` node's own `.label` field, not a
    /// separate copy — see `block.zig`'s `tryParseLinkRefDef`), so `deinit`
    /// only needs to free the map structure itself.
    link_references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,

    /// Label (normalized, same rule as `link_references`) -> the `footnote`
    /// definition node with that label (`block.zig`'s `[^label]: ...`
    /// handling, gated on `self.options.footnotes`). Unlike
    /// `link_references`, the shared HTML printer DOES need to consult this
    /// one: a `footnote_reference`'s label, like djot's, is resolved,
    /// numbered, and backlinked entirely at RENDER time (djot.js-style),
    /// never at parse time — see `html.zig` (this package's thin adapter
    /// over the shared printer's `Html.Context`, mirroring
    /// `Djot.Document.footnotes`/`djot/html.zig` exactly) and this file's
    /// module doc comment.
    ///
    /// This map's KEYS are slices of `ast.owned_strings` (the same string as
    /// its `footnote` node's own `.label` field), so `deinit` only needs to
    /// free the map structure itself — same story as `link_references`.
    footnotes: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,

    pub fn deinit(self: *Document) void {
        self.link_references.deinit(self.ast.allocator);
        self.footnotes.deinit(self.ast.allocator);
        self.ast.deinit();
    }
};

/// Parse `source` (Markdown/CommonMark text) into a `Document`. The
/// returned document is fully self-contained (its AST owns copies of every
/// string it needs) and must be freed with `doc.deinit()`.
pub fn parse(allocator: Allocator, source: []const u8, options: ParseOptions) Allocator.Error!Document {
    const result = try block.parse(allocator, source, options);
    return .{
        .ast = result.ast,
        .options = options,
        .link_references = result.link_references,
        .footnotes = result.footnotes,
    };
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
