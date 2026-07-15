//! HTML: the entry point for this language module, mirroring
//! `languages/xml/xml.zig`'s role for XML. It provides a forgiving HTML
//! parser (`parser.zig`) and a generic `AST` -> HTML text renderer
//! (`serializer.zig`). The parser feeds generic markup (`element`/`comment`/
//! `doctype`/...) into the shared AST; the serializer also covers the full
//! semantic vocabulary, proving it can reproduce `languages/djot/html.zig`'s
//! output exactly (see `conformance.zig`).
//!
//! Aggregates every sibling file's `test {}` blocks (the fig/djot/xml
//! convention).

const std = @import("std");

pub const AST = @import("../../ast/ast.zig");

const serializer_mod = @import("serializer.zig");
const parser_mod = @import("parser.zig");

pub const RenderOptions = serializer_mod.RenderOptions;
pub const Context = serializer_mod.Context;
pub const KV = serializer_mod.KV;
pub const RenderError = serializer_mod.RenderError;
pub const RenderAllocError = serializer_mod.RenderAllocError;
pub const Renderer = serializer_mod.Renderer;
pub const Parser = parser_mod.Parser;
pub const ParseError = parser_mod.ParseError;

pub const serialize = serializer_mod.serialize;
pub const serializeOpts = serializer_mod.serializeOpts;
pub const serializeNode = serializer_mod.serializeNode;
pub const serializeNodeOpts = serializer_mod.serializeNodeOpts;
pub const serializeAlloc = serializer_mod.serializeAlloc;
pub const serializeAllocOpts = serializer_mod.serializeAllocOpts;

// Twig prints three markdown-family dialects DISTINCTLY, and these two presets
// (plus this struct's bare defaults, which are djot's) are where that lives:
//
//   djot       — djot.js's conventions: bare `<tr>`, `style="text-align:"`,
//                `<ul class="task-list">`. The defaults; see `RenderOptions`.
//   markdown   — `commonmark_render_options`: CommonMark's core conventions,
//                plus well-formed `<thead>`/`<tbody>` tables.
//   GFM        — `gfm_render_options`: the above, plus cmark-gfm's own
//                extension spellings.
//
// The split matters because strict CommonMark has NO tables, task lists, or
// strikethrough — they exist only as extensions — so its spec says nothing
// about printing them, and its 652-example suite never renders one. Anything
// those constructs need is therefore a deliberate choice here rather than
// something the CommonMark suite can pin down. `languages/markdown/html.zig`
// maps a document's `ParseOptions.dialect` onto these.

/// The HTML render conventions twig-markdown uses: CommonMark's reference
/// output (XHTML void self-close + `src`-before-`alt` image attributes,
/// `"`-escaping, percent-encoded destinations, CommonMark list framing), plus
/// `<thead>`/`<tbody>` table sectioning. Both markdown dialects render with
/// these as a base; djot keeps the defaults. See `RenderOptions`.
///
/// `table_sections` being on here is safe for the CommonMark conformance
/// suite by construction, not by luck: that suite's 652 examples produce zero
/// parsed tables (its five `<table>`s are raw HTML the spec author typed
/// literally), so this flag can never change a byte of its output.
pub const commonmark_render_options: RenderOptions = .{
    .xhtml_void = true,
    .commonmark_image_attrs = true,
    .commonmark_lists = true,
    .escape_text_quotes = true,
    .percent_encode_urls = true,
    .table_sections = true,
};

/// GFM's render conventions: everything twig-markdown's are (GFM is defined
/// as CommonMark plus extensions, and cmark-gfm renders the core identically),
/// plus the three spellings its extensions insist on — presentational `align=`
/// cell attributes, cmark-gfm's own task-list `<input>`, and the Disallowed
/// Raw HTML tagfilter.
///
/// Kept as a SUPERSET of `commonmark_render_options` rather than a hand-copied
/// literal so the two can't drift: a future CommonMark render-convention fix
/// lands in GFM automatically, which is exactly right, since GFM *is*
/// CommonMark plus extensions. See `languages/markdown/gfm_conformance.zig`.
pub const gfm_render_options: RenderOptions = blk: {
    var o = commonmark_render_options;
    o.gfm_cell_align_attr = true;
    o.gfm_task_list_items = true;
    o.tagfilter = true;
    break :blk o;
};

/// Parse forgiving HTML into the shared generic-markup AST.  This is a
/// document-oriented parser rather than a browser DOM implementation: it
/// recognizes normal HTML token forms and common optional end tags, while
/// preserving unknown markup in the generic AST vocabulary.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!AST {
    var parser = Parser.init(allocator, source);
    defer parser.deinit();
    return parser.parse();
}

test {
    _ = serializer_mod;
    _ = parser_mod;
    _ = @import("conformance.zig");
}
