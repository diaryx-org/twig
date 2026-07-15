//! `AST` -> HTML text. A GENERIC printer: unlike
//! `languages/djot/html.zig` (which renders a djot `Document` and is wired
//! tightly to djot's block/inline dichotomy), this renders the shared `AST`
//! alone and covers the ENTIRE shared kind vocabulary — both the semantic
//! core (`para`, `heading`, `emph`, ...) and the generic-markup escape hatch
//! (`element`, `comment`, `doctype`, `processing_instruction`, `cdata`) that
//! `djot/html.zig` never has to handle because djot never produces those
//! kinds.
//!
//! This module is the first step toward retiring `djot/html.zig`: the goal
//! is for `serialize` to reproduce, byte-for-byte, everything
//! `djot/html.zig` renders for a djot parse (see `conformance.zig` in this
//! directory, which proves that against the same djot.js corpus
//! `languages/djot/conformance.zig` uses). Until that migration happens,
//! `djot/html.zig` remains the shipped renderer; this one is proven
//! equivalent but not yet load-bearing.
//!
//! ── Reference/footnote resolution without importing djot ──────────────────
//! Djot defers `link`/`image`/`footnote_reference` resolution to render time
//! against side tables that live on djot's `Document`, not on the shared
//! `AST` (see `djot.zig`'s `Document` doc comment: XML/HTML have nothing
//! like them, so they don't belong on `AST` itself). This module can't
//! import djot — that would invert the shared-vocabulary/language-module
//! layering — so instead it defines its own `Context`, shaped identically to
//! `Document`'s three tables, that a caller (djot, or anyone else with
//! label/footnote side tables) fills in from whatever source it has. `ctx ==
//! null` means "no side tables" — the natural shape for a future plain
//! HTML/XML parse, where `link`/`image` nodes carry a literal `destination`
//! and never a `reference` label, and `footnote_reference` simply doesn't
//! occur. See `renderLinkOrImage`/`renderNotes` for how the render degrades
//! gracefully in that case (unresolved references warn and fall back to no
//! `href`/`src`; an empty footnote table yields an empty, but structurally
//! valid, endnotes section for any stray `footnote_reference`).
//!
//! ── Generic markup kinds (new here; not in `djot/html.zig`) ────────────────
//! `element`/`comment`/`doctype`/`processing_instruction`/`cdata` come from
//! XML/HTML parses, which djot never produces. Decisions, each documented at
//! its render site below:
//!   - `element`: HTML **void elements** (`br`, `img`, ...) are looked up by
//!     NAME and always render as `<name attrs>` with no children and no
//!     close tag, regardless of `content_span` — the void-element name list
//!     is authoritative for HTML output, unlike `xml/serializer.zig` where
//!     `content_span == null` is the self-closing signal. A non-void element
//!     always renders as an explicit `<name>...</name>` pair (even if
//!     `content_span == null`, e.g. an XML-style `<video/>` parse) because
//!     HTML has no self-closing syntax for ordinary elements — a browser's
//!     HTML5 parser ignores the trailing `/` and treats it as an unclosed
//!     start tag, which would silently swallow following siblings; an
//!     explicit close tag is the unambiguous choice for a printer.
//!   - `comment`: `<!--text-->`, payload written verbatim (unescaped, same
//!     as `xml/serializer.zig` — HTML comments have no escaping mechanism).
//!   - `doctype`: `<!DOCTYPE` + payload (as parsed, already including its
//!     leading space/content) + `>`. Same shape as `xml/serializer.zig`;
//!     "HTML doctype casing" is a property of the payload as written by
//!     whatever parser produced it; this printer doesn't re-case it.
//!   - `processing_instruction`: HTML has no PI syntax. Rendered as the
//!     WHATWG HTML5 tokenizer's "bogus comment" shape for a `<?` it
//!     encounters — `<?target data>` (terminated by `>`, not `?>`) — since
//!     that's what re-parsing this output as HTML actually produces (a
//!     comment node), making the choice at least round-trip-legible rather
//!     than inventing new syntax.
//!   - `cdata`: HTML has no CDATA sections outside foreign (SVG/MathML)
//!     content, where this printer doesn't track namespace context. Emitting
//!     `<![CDATA[...]]>` literally would either be mishandled by an HTML5
//!     parser (parsed as a bogus comment outside foreign content) or leak
//!     raw syntax to a reader; rendering the contents as escaped TEXT is the
//!     choice that preserves the data's meaning as ordinary HTML output.
//!   - Attributes: a `KeyVal.value == null` entry (a *bare* attribute, e.g.
//!     HTML `disabled`) renders as just its key — no `=`, no value — which
//!     is exactly what `disabled` (vs. `disabled=""`) means in HTML. This
//!     reuses the exact same attribute-rendering path `djot/html.zig` uses
//!     for semantic kinds (`renderAttributes` already had to get this right
//!     for hand-built/foreign trees), so generic elements get it for free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;

pub const RenderOptions = struct {
    warn: ?*const fn (message: []const u8) void = null,
    /// Emit void elements (`br`/`img`/`hr`/...) XHTML-style, with a ` />`
    /// self-close, instead of the bare `>` of HTML5. CommonMark's reference
    /// output is XHTML (`<br />`); djot's is HTML (`<br>`), so this defaults
    /// off and the markdown path opts in. Only affects void elements — an
    /// ordinary element's closer is unchanged.
    xhtml_void: bool = false,
    /// Emit an image's synthesized attributes in CommonMark order
    /// (`src`, `alt`, `title`) rather than djot's (`alt`, `src`, `title`).
    /// The two formats' reference renderers disagree on this ordering; the
    /// nodes are identical, only the print order differs. Defaults to djot's
    /// order; the markdown path opts in.
    commonmark_image_attrs: bool = false,
    /// Percent-encode link/image destinations (and autolink URLs) the way
    /// CommonMark's reference `houdini_escape_href` does: pass through
    /// alphanumerics, `-_.~` and the URL-reserved set `!#$%&'()*+,/:;=?@`
    /// (so an already-`%`-encoded byte survives), and `%XX`-encode everything
    /// else, including spaces, `"`, `\`, `[`, `]`, and every non-ASCII byte
    /// (UTF-8, one `%XX` per byte). djot emits destinations verbatim, so this
    /// defaults off and the markdown path opts in. (HTML attribute escaping
    /// still runs afterward, turning a passed-through `&` into `&amp;`.)
    percent_encode_urls: bool = false,
    /// Escape `"` to `&quot;` in text content, not just in attribute values.
    /// CommonMark's reference `escape_html` escapes `&<>"` everywhere; djot
    /// escapes only `&<>` in text (a literal `"` stays bare). Defaults to
    /// djot's behavior; the markdown path opts in.
    escape_text_quotes: bool = false,
    /// Render list items the CommonMark way: a *tight* item hugs its content
    /// (`<li>one</li>`, first paragraph inline with no wrapping `<p>` and no
    /// surrounding newlines), a following block (a nested list) gets a single
    /// separating newline only when the cursor isn't already at line start,
    /// and a *loose* item is `<li>\n<p>…</p>\n…</li>`. djot instead always
    /// frames items as `<li>\n…\n</li>` regardless of tightness, so this
    /// defaults off and the markdown path opts in. (`<p>` suppression in
    /// tight lists is independent of this flag — see the `para` branch.)
    commonmark_lists: bool = false,
    /// Group a table's rows into `<thead>`/`<tbody>` sections rather than
    /// emitting bare `<tr>`s directly under `<table>`. Sections follow each
    /// `row`'s own `head` flag, so a header-only table closes right after
    /// `</thead>` with no empty `<tbody>`.
    ///
    /// Unlike this struct's other flags, this one isn't a format's arbitrary
    /// house style — it's just well-formed HTML, and BOTH markdown dialects
    /// opt in. Only djot stays out, because djot.js's reference output
    /// genuinely omits the sections and its conformance suite is byte-exact
    /// against it.
    table_sections: bool = false,
    /// Render a cell's alignment as GFM's presentational `align="center"`
    /// attribute rather than the `style="text-align: center;"` that djot and
    /// twig-markdown both use. Purely a spelling disagreement between
    /// reference renderers; the `alignment` value is identical either way.
    /// The GFM path opts in.
    gfm_cell_align_attr: bool = false,
    /// Render task list items GFM's way: a plain `<ul>` (no `class="task-list"`),
    /// and an `<input>` spelled exactly as cmark-gfm's tasklist extension emits
    /// it — attributes in alphabetical order, NOT self-closed even under
    /// `xhtml_void` (the extension writes a literal string rather than going
    /// through cmark's void-element path), followed by one space before the
    /// item's content. Items otherwise hug their content like
    /// `commonmark_lists`. Defaults to djot's shape; the GFM path opts in.
    gfm_task_list_items: bool = false,
    /// GFM's "Disallowed Raw HTML" extension: in raw HTML output, escape the
    /// leading `<` of a blacklisted tag (`title`, `textarea`, `style`, `xmp`,
    /// `iframe`, `noembed`, `noframes`, `script`, `plaintext`) to `&lt;`, so
    /// it renders as text instead of taking effect. Off by default (djot and
    /// strict CommonMark both pass raw HTML through verbatim); the GFM path
    /// opts in. See `writeRawHtml`.
    tagfilter: bool = false,
};

/// Djot-shaped render-time side tables, supplied by whatever language module
/// has them (djot's `Document`, today) so this printer can resolve
/// `link`/`image` reference labels and number `footnote_reference`s without
/// importing that module. See this file's module doc comment for the
/// layering rationale and the `ctx == null` degrade-gracefully behavior.
pub const Context = struct {
    /// Label (normalized) -> the `reference` definition node with that
    /// label. Mirrors `Djot.Document.references`.
    references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,
    /// Mirrors `Djot.Document.auto_references`.
    auto_references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,
    /// Label -> the `footnote` definition node with that label. Mirrors
    /// `Djot.Document.footnotes`.
    footnotes: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,
};

/// One `key="value"` pair to render ahead of a node's own attributes (used
/// for e.g. `href`/`src`/`class="task-list"` that a tag contributes itself).
/// Identical in shape and purpose to `djot/html.zig`'s `KV`.
pub const KV = struct { key: []const u8, value: []const u8 };

/// Most render functions can both write and allocate (footnote index/id
/// tracking, `alt`-text extraction), so they share this combined error set —
/// same reasoning as `djot/html.zig`'s `RenderError`.
///
/// `error.UnsafeMetadata`: a `metadata` node's body contains `</script`, which
/// cannot be represented in a raw-text `<script>` data island — it would
/// terminate the element early, corrupting the document and opening a
/// script-injection vector. Raw text has no escape mechanism, so the printer
/// refuses rather than emit unsafe HTML (see the `.metadata` arm).
pub const RenderError = Writer.Error || Allocator.Error || error{UnsafeMetadata};

/// Error set of the `…Alloc` wrappers: an in-memory `Writer.Allocating` only
/// fails on allocation, so `error.WriteFailed` collapses into
/// `error.OutOfMemory` — but `error.UnsafeMetadata` is a genuine content
/// refusal that must reach the caller (see `RenderError`).
pub const RenderAllocError = Allocator.Error || error{UnsafeMetadata};

/// HTML5 void elements (https://html.spec.whatwg.org/#void-elements):
/// looked up by tag NAME alone, taking precedence over `content_span` for
/// deciding whether an `element` node gets a close tag. Names are matched
/// exactly as stored on the node (i.e. expected lowercase, as an HTML
/// parser would produce; a foreign-cased name like `BR` from a hand-built
/// tree won't match and will render as if it were an ordinary element).
const void_elements = std.StaticStringMap(void).initComptime(.{
    .{"area"},  .{"base"},   .{"br"},    .{"col"},  .{"embed"},
    .{"hr"},    .{"img"},    .{"input"}, .{"link"}, .{"meta"},
    .{"param"}, .{"source"}, .{"track"}, .{"wbr"},
});

fn isVoidElement(name: []const u8) bool {
    return void_elements.has(name);
}

/// Bytes passed through literally by `percentEncodeHref` — CommonMark's
/// `houdini_escape_href` "safe" set: ASCII alphanumerics, `-_.~`, and the
/// URL-reserved punctuation `!#$%&'()*+,/:;=?@`. Every other byte (spaces,
/// `"`, `<`, `>`, `\`, `[`, `]`, controls, and all non-ASCII) is `%XX`-encoded.
fn hrefSafeByte(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '_', '.', '~' => true,
        '!', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '/', ':', ';', '=', '?', '@' => true,
        else => false,
    };
}

/// Percent-encode a URL destination the way CommonMark's reference renderer
/// does (see `hrefSafeByte`). Returns a freshly allocated buffer owned by the
/// caller. Note an existing `%` passes through (it's "safe"), so a
/// pre-encoded destination is not double-encoded.
fn percentEncodeHref(allocator: Allocator, url: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (url) |c| {
        if (hrefSafeByte(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Elements whose content is *raw text*: it has no character-reference
/// escaping mechanism, so on serialization the text is emitted literally.
/// (RCDATA elements — `textarea`/`title` — are deliberately absent: their
/// content *is* escaped, the normal path.) Mirrors the parser's `isRawText`.
const raw_text_elements = std.StaticStringMap(void).initComptime(.{
    .{"script"},    .{"style"},   .{"xmp"},
    .{"iframe"},    .{"noembed"}, .{"noframes"},
    .{"plaintext"},
});

fn isRawTextElement(name: []const u8) bool {
    return raw_text_elements.has(name);
}

pub const Renderer = struct {
    allocator: Allocator,
    ast: *const AST,
    writer: *Writer,
    /// Borrowed from `ctx` at `init` time (or left at the empty default when
    /// `ctx == null`) so the rest of this struct can read `self.references`
    /// etc. directly, exactly as `djot/html.zig`'s `Renderer` reads
    /// `self.doc.references` — see this file's module doc comment.
    references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,
    auto_references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,
    footnotes: std.StringHashMapUnmanaged(AST.Node.Id) = .empty,
    tight: bool = false,
    footnote_index: std.StringHashMapUnmanaged(usize) = .empty,
    next_footnote_index: usize = 1,
    fnref_id_emitted: std.StringHashMapUnmanaged(void) = .empty,
    options: RenderOptions = .{},

    pub fn init(allocator: Allocator, ast: *const AST, writer: *Writer, ctx: ?*const Context, options: RenderOptions) Renderer {
        return .{
            .allocator = allocator,
            .ast = ast,
            .writer = writer,
            .references = if (ctx) |c| c.references else .empty,
            .auto_references = if (ctx) |c| c.auto_references else .empty,
            .footnotes = if (ctx) |c| c.footnotes else .empty,
            .options = options,
        };
    }

    /// Only frees render-owned scratch state (footnote index/id tracking);
    /// `references`/`auto_references`/`footnotes` are borrowed from `ctx`
    /// and stay owned by whoever built it.
    pub fn deinit(self: *Renderer) void {
        self.footnote_index.deinit(self.allocator);
        self.fnref_id_emitted.deinit(self.allocator);
    }

    fn warn(self: *Renderer, msg: []const u8) void {
        if (self.options.warn) |f| f(msg);
    }

    // ── escaping ─────────────────────────────────────────────────────────
    // Two contexts, two escape sets — text content only needs to protect
    // `&`/`<`/`>` from being read as markup, while an attribute value
    // (delimited by `"`) additionally needs `"` escaped. Identical to
    // `djot/html.zig`'s pair of helpers.

    fn writeEscaped(self: *Renderer, s: []const u8) Writer.Error!void {
        for (s) |c| {
            switch (c) {
                '&' => try self.writer.writeAll("&amp;"),
                '<' => try self.writer.writeAll("&lt;"),
                '>' => try self.writer.writeAll("&gt;"),
                '"' => if (self.options.escape_text_quotes)
                    try self.writer.writeAll("&quot;")
                else
                    try self.writer.writeByte(c),
                else => try self.writer.writeByte(c),
            }
        }
    }

    fn writeEscapedAttr(self: *Renderer, s: []const u8) Writer.Error!void {
        for (s) |c| {
            switch (c) {
                '&' => try self.writer.writeAll("&amp;"),
                '<' => try self.writer.writeAll("&lt;"),
                '>' => try self.writer.writeAll("&gt;"),
                '"' => try self.writer.writeAll("&quot;"),
                else => try self.writer.writeByte(c),
            }
        }
    }

    fn smartPunct(kind: AST.SmartPunctuationKind) []const u8 {
        return switch (kind) {
            .right_single_quote => "\u{2019}",
            .left_single_quote => "\u{2018}",
            .right_double_quote => "\u{201D}",
            .left_double_quote => "\u{201C}",
            .ellipses => "\u{2026}",
            .em_dash => "\u{2014}",
            .en_dash => "\u{2013}",
        };
    }

    // ── attribute / tag rendering ────────────────────────────────────────

    /// Render `id`'s attributes (plus `extra`, written first) as
    /// ` key="value"` pairs. `class` is special: if both `extra` and the
    /// node supply one, they're space-joined (extra's value first) into a
    /// single `class` attribute. A bare (`value == null`) entry — HTML
    /// `disabled` — renders as just its key. Identical logic to
    /// `djot/html.zig`'s `renderAttributes`; generic `element` nodes reuse
    /// this same path (with `extra` empty) rather than a bespoke one, so the
    /// bare-attribute and class-merging behavior is shared for free.
    fn renderAttributes(self: *Renderer, id: Node.Id, extra: []const KV) Writer.Error!void {
        const attrs = self.ast.attrsOf(id);
        const node_class = attrs.get("class");
        for (extra) |kv| {
            if (std.mem.eql(u8, kv.key, "class")) {
                try self.writer.writeAll(" class=\"");
                try self.writeEscapedAttr(kv.value);
                if (node_class) |nc| {
                    try self.writer.writeByte(' ');
                    try self.writeEscapedAttr(nc);
                }
                try self.writer.writeByte('"');
            } else {
                try self.writer.print(" {s}=\"", .{kv.key});
                try self.writeEscapedAttr(kv.value);
                try self.writer.writeByte('"');
            }
        }
        for (attrs.entries) |kv| {
            // An `extra` value takes precedence: `class` was merged above, and
            // any other key an `extra` already emitted (e.g. `href`/`src`/
            // `start` synthesized from a semantic field) must not be repeated —
            // duplicate attribute keys are malformed HTML. Parser-produced
            // nodes preserve the original attribute alongside the field, so
            // this dedup is what keeps the two from both reaching the output.
            if (hasKey(extra, kv.key)) continue;
            if (kv.value) |value| {
                try self.writer.print(" {s}=\"", .{kv.key});
                try self.writeEscapedAttr(value);
                try self.writer.writeByte('"');
            } else {
                try self.writer.print(" {s}", .{kv.key});
            }
        }
    }

    fn hasKey(kvs: []const KV, key: []const u8) bool {
        for (kvs) |kv| if (std.mem.eql(u8, kv.key, key)) return true;
        return false;
    }

    fn hasAttrsOrExtra(self: *const Renderer, id: Node.Id, extra: []const KV) bool {
        return extra.len > 0 or !self.ast.attrsOf(id).isEmpty();
    }

    fn renderTag(self: *Renderer, tag: []const u8, id: Node.Id, extra: []const KV) Writer.Error!void {
        try self.writer.print("<{s}", .{tag});
        if (self.hasAttrsOrExtra(id, extra)) try self.renderAttributes(id, extra);
        if (self.options.xhtml_void and isVoidElement(tag)) {
            try self.writer.writeAll(" />");
        } else {
            try self.writer.writeByte('>');
        }
    }

    fn renderCloseTag(self: *Renderer, tag: []const u8) Writer.Error!void {
        try self.writer.print("</{s}>", .{tag});
    }

    /// `newlines`: 2 = newline after the open tag AND after the close tag; 1
    /// = only after the close tag; 0 = none.
    fn inTags(self: *Renderer, tag: []const u8, id: Node.Id, newlines: u8, extra: []const KV) RenderError!void {
        try self.renderTag(tag, id, extra);
        if (newlines >= 2) try self.writer.writeByte('\n');
        try self.renderChildren(id);
        try self.renderCloseTag(tag);
        if (newlines >= 1) try self.writer.writeByte('\n');
    }

    // ── children / tight-list tracking ──────────────────────────────────

    fn renderChildren(self: *Renderer, id: Node.Id) RenderError!void {
        const old_tight = self.tight;
        switch (self.ast.nodes[id].kind) {
            .bullet_list => |v| self.tight = v.tight,
            .ordered_list => |v| self.tight = v.tight,
            .task_list => |v| self.tight = v.tight,
            // Tightness is a property of a list item's *direct* paragraph
            // children only; a paragraph nested inside another block container
            // (a blockquote/div/section within the item) is never tight. Reset
            // so `self.tight` doesn't leak past such a boundary — otherwise the
            // container's paragraphs would lose their `<p>` wrapping. `list_item`
            // is deliberately absent: it must preserve the enclosing list's
            // tightness for its own paragraphs to consume.
            .block_quote, .div, .section => self.tight = false,
            // A container directive's block children are never tight (same as
            // div/blockquote); text/leaf forms have inline children, so the
            // reset is harmless for them.
            .directive => self.tight = false,
            else => {},
        }
        var it = self.ast.children(id);
        while (it.next()) |child| try self.renderNode(child.id);
        self.tight = old_tight;
    }

    /// Render one `<li>` the CommonMark way (see `RenderOptions.commonmark_lists`).
    fn renderCommonMarkListItem(self: *Renderer, id: Node.Id) RenderError!void {
        return self.renderCommonMarkListItemPrefixed(id, "");
    }

    /// Render one `<li>` the CommonMark way, writing `prefix` immediately after
    /// the `<li>` and before the item's own content.
    ///
    /// `self.tight` is the enclosing list's tightness, set by the parent list's
    /// `renderChildren` before this item is reached. A tight paragraph hugs the
    /// content (rendered inline, no `<p>`, no surrounding newline); every other
    /// child is a block that self-terminates with a newline, and is preceded by
    /// a single separating newline only when the cursor isn't already at line
    /// start — mirroring cmark's `cr()`. This tracks line-start structurally
    /// (from child kinds) rather than by inspecting the output buffer.
    ///
    /// `prefix` exists for GFM task list items (`gfm_task_list_items`), whose
    /// rendering is precisely a CommonMark list item with a checkbox `<input>`
    /// spliced in at the front — including the tight-paragraph hug and the
    /// single newline before a nested list, which is why it's a parameter here
    /// rather than a second, near-duplicate renderer.
    fn renderCommonMarkListItemPrefixed(self: *Renderer, id: Node.Id, prefix: []const u8) RenderError!void {
        try self.writer.writeAll("<li>");
        try self.writer.writeAll(prefix);
        var at_line_start = false;
        var it = self.ast.children(id);
        while (it.next()) |child| {
            const kind = self.ast.nodes[child.id].kind;
            if (self.tight and kind == .para) {
                // Tight paragraph: just its inline content, no `<p>`, no newline.
                try self.renderChildren(child.id);
                at_line_start = false;
            } else {
                if (!at_line_start) try self.writer.writeByte('\n');
                try self.renderNode(child.id);
                at_line_start = true;
            }
        }
        try self.writer.writeAll("</li>\n");
    }

    /// The tag names GFM's "Disallowed Raw HTML" extension refuses to let
    /// through as live markup (`tagfilter`). Verbatim from cmark-gfm's
    /// `extensions/tagfilter.c`; matched case-insensitively.
    const tagfilter_blacklist = [_][]const u8{
        "title",   "textarea", "style",  "xmp",       "iframe",
        "noembed", "noframes", "script", "plaintext",
    };

    /// Whether `text[at] == '<'` opens a blacklisted tag: an optional `/`,
    /// one of `tagfilter_blacklist` (case-insensitive), then a delimiter
    /// (`>`, `/`, whitespace, or end of text). The delimiter check is what
    /// keeps `<titlepage>` — merely a blacklisted name as a PREFIX — live.
    fn isFilteredTag(text: []const u8, at: usize) bool {
        var i = at + 1;
        if (i < text.len and text[i] == '/') i += 1;
        for (tagfilter_blacklist) |name| {
            if (text.len - i < name.len) continue;
            if (!std.ascii.eqlIgnoreCase(text[i .. i + name.len], name)) continue;
            const j = i + name.len;
            if (j == text.len or text[j] == '>' or text[j] == '/' or std.ascii.isWhitespace(text[j])) return true;
        }
        return false;
    }

    /// Write raw HTML through, applying GFM's tagfilter when it's on. Only the
    /// leading `<` of a blacklisted tag becomes `&lt;` — the rest of the tag
    /// (including its `>`) stays as-is, which is exactly what GFM's reference
    /// output shows (`<title>` -> `&lt;title>`, not `&lt;title&gt;`).
    fn writeRawHtml(self: *Renderer, text: []const u8) RenderError!void {
        if (!self.options.tagfilter) return self.writer.writeAll(text);
        var i: usize = 0;
        var flushed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, i, '<')) |lt| {
            if (isFilteredTag(text, lt)) {
                try self.writer.writeAll(text[flushed..lt]);
                try self.writer.writeAll("&lt;");
                flushed = lt + 1;
            }
            i = lt + 1;
        }
        try self.writer.writeAll(text[flushed..]);
    }

    /// A table's rows grouped into `<thead>`/`<tbody>` sections
    /// (`table_sections`). Each section opens at the first `row` whose `head`
    /// flag differs from the previous one's and closes when that run ends, so
    /// a header-only table emits no empty `<tbody>` — matching GFM's
    /// reference output for `| abc | def |` / `| --- | --- |`. Grouping by run
    /// rather than assuming "exactly one head row, then the rest" keeps this
    /// honest for any table the AST can hold, not just the one shape GFM's
    /// own parser produces. Non-`row` children (the `caption`) render in
    /// place, outside any section.
    fn renderSectionedTable(self: *Renderer, id: Node.Id) RenderError!void {
        try self.renderTag("table", id, &.{});
        try self.writer.writeByte('\n');
        var section: Section = .none;
        var it = self.ast.children(id);
        while (it.next()) |child| {
            switch (self.ast.nodes[child.id].kind) {
                .row => |v| {
                    const want: Section = if (v.head) .head else .body;
                    if (section != want) {
                        try self.closeTableSection(section);
                        try self.writer.writeAll(if (want == .head) "<thead>\n" else "<tbody>\n");
                        section = want;
                    }
                    try self.renderNode(child.id);
                },
                else => try self.renderNode(child.id),
            }
        }
        try self.closeTableSection(section);
        try self.renderCloseTag("table");
        try self.writer.writeByte('\n');
    }

    /// Which `<thead>`/`<tbody>` run `renderSectionedTable` currently has open
    /// (`.none` before the first row, and for a table of only non-`row`
    /// children).
    const Section = enum { none, head, body };

    fn closeTableSection(self: *Renderer, section: Section) RenderError!void {
        switch (section) {
            .none => {},
            .head => try self.writer.writeAll("</thead>\n"),
            .body => try self.writer.writeAll("</tbody>\n"),
        }
    }

    /// Write a raw-text element's children literally (no escaping). The parser
    /// yields such content as a single `str`/`verbatim` node; any other child
    /// kind falls back to normal rendering so nothing is silently dropped.
    fn renderRawTextChildren(self: *Renderer, id: Node.Id) RenderError!void {
        var it = self.ast.children(id);
        while (it.next()) |child| {
            switch (self.ast.nodes[child.id].kind) {
                .str, .verbatim => |t| try self.writer.writeAll(t),
                else => try self.renderNode(child.id),
            }
        }
    }

    // ── footnotes ────────────────────────────────────────────────────────

    fn addBacklink(self: *Renderer, note: []const u8, ident: usize) Writer.Error!void {
        // If `note` ends with `</p>` (optionally followed by trailing
        // newlines), splice the backlink just before that closing tag;
        // otherwise append a new `<p>` holding just the backlink.
        const trimmed_end = std.mem.trimEnd(u8, note, "\r\n");
        if (std.mem.endsWith(u8, trimmed_end, "</p>")) {
            try self.writer.writeAll(trimmed_end[0 .. trimmed_end.len - 4]);
            try self.writeBacklinkAnchor(ident);
            try self.writer.writeAll("</p>");
            try self.writer.writeAll(note[trimmed_end.len..]);
        } else {
            try self.writer.writeAll(note);
            try self.writer.writeAll("<p>");
            try self.writeBacklinkAnchor(ident);
            try self.writer.writeAll("</p>\n");
        }
    }

    fn writeBacklinkAnchor(self: *Renderer, ident: usize) Writer.Error!void {
        try self.writer.print("<a href=\"#fnref{d}\" role=\"doc-backlink\">\u{21A9}\u{FE0E}</a>", .{ident});
    }

    fn renderNotes(self: *Renderer) RenderError!void {
        // Render every footnote's children into a scratch buffer first, so
        // out-of-order-defined notes still render in REFERENCE order,
        // driven by `footnote_index`, not definition order.
        var rendered = std.StringHashMapUnmanaged([]u8){};
        defer {
            var it = rendered.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            rendered.deinit(self.allocator);
        }

        // `footnotes` is a hash map, so its iteration order is unspecified,
        // but a footnote can forward- or self-reference another footnote,
        // and whichever occurrence renders FIRST claims that footnote's
        // `id="fnrefN"` (see `fnref_id_emitted`) — so rendering must proceed
        // in a deterministic order. Node ids are assigned in creation order
        // by every producer this printer expects (the djot parser creates
        // footnote nodes in definition order), so sorting by node id
        // recovers definition order without needing a separate ordered
        // side-list. Mirrors `djot/html.zig`'s `renderNotes`.
        const Entry = struct { key: []const u8, id: Node.Id };
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(self.allocator);
        var kit = self.footnotes.iterator();
        while (kit.next()) |entry| try entries.append(self.allocator, .{ .key = entry.key_ptr.*, .id = entry.value_ptr.* });
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.id < b.id;
            }
        }.lessThan);

        for (entries.items) |entry| {
            var buf: Writer.Allocating = .init(self.allocator);
            defer buf.deinit();
            // Render with `self` itself (not a fresh `Renderer`) so
            // `footnote_index`/`next_footnote_index`/`fnref_id_emitted`
            // stay shared across every footnote's content -- a footnote can
            // itself reference another footnote (or itself), and that
            // reference must get a consistent, monotonically-assigned index
            // regardless of which footnote's content it's encountered in.
            // Only the destination is swapped, temporarily, to capture this
            // one footnote's rendered HTML separately.
            const saved_writer = self.writer;
            self.writer = &buf.writer;
            try self.renderChildren(entry.id);
            self.writer = saved_writer;
            const owned = try buf.toOwnedSlice();
            try rendered.put(self.allocator, entry.key, owned);
        }

        try self.writer.writeAll("<section role=\"doc-endnotes\">\n<hr>\n<ol>\n");
        // Build an index -> label ordering table sized to next_footnote_index.
        const n = self.next_footnote_index;
        if (n > 1) {
            const order = try self.allocator.alloc(?[]const u8, n);
            defer self.allocator.free(order);
            @memset(order, null);
            var it = self.footnote_index.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* < n) order[entry.value_ptr.*] = entry.key_ptr.*;
            }
            var i: usize = 1;
            while (i < n) : (i += 1) {
                try self.writer.print("<li id=\"fn{d}\">\n", .{i});
                // A `footnote_reference` whose label has no matching
                // definition in `footnotes` (possible when `ctx == null`, or
                // a genuinely dangling label) still gets numbered and still
                // gets an `<li>` here, just with empty content — the same
                // graceful degrade `djot/html.zig` exhibits for an unresolved
                // label.
                const note = if (order[i]) |lab| (rendered.get(lab) orelse "") else "";
                try self.addBacklink(note, i);
                try self.writer.writeAll("</li>\n");
            }
        }
        try self.writer.writeAll("</ol>\n</section>\n");
    }

    // ── the big dispatch ─────────────────────────────────────────────────

    pub fn renderNode(self: *Renderer, id: Node.Id) RenderError!void {
        const node = &self.ast.nodes[id];
        switch (node.kind) {
            .doc => {
                try self.renderChildren(id);
                if (self.next_footnote_index > 1) try self.renderNotes();
            },
            .para => {
                if (self.tight) {
                    try self.renderChildren(id);
                    try self.writer.writeByte('\n');
                } else {
                    try self.inTags("p", id, 1, &.{});
                }
            },
            .block_quote => try self.inTags("blockquote", id, 2, &.{}),
            .div => try self.inTags("div", id, 2, &.{}),
            .section => try self.inTags("section", id, 2, &.{}),
            .list_item => if (self.options.commonmark_lists)
                try self.renderCommonMarkListItem(id)
            else
                try self.inTags("li", id, 2, &.{}),
            .task_list_item => |v| if (self.options.gfm_task_list_items)
                // cmark-gfm's tasklist extension writes this `<input>` as a
                // literal string: attributes alphabetical, and NOT self-closed
                // even though the rest of GFM's output is XHTML-ish under
                // `xhtml_void` (it never goes through cmark's void-element
                // path). Reproduce it verbatim rather than deriving it.
                try self.renderCommonMarkListItemPrefixed(id, if (v.checked)
                    "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "
                else
                    "<input disabled=\"\" type=\"checkbox\"> ")
            else {
                try self.writer.writeAll("<li>\n");
                if (v.checked) {
                    try self.writer.writeAll("<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\n");
                } else {
                    try self.writer.writeAll("<input disabled=\"\" type=\"checkbox\"/>\n");
                }
                try self.renderChildren(id);
                try self.renderCloseTag("li");
                try self.writer.writeByte('\n');
            },
            .definition_list_item => try self.renderChildren(id),
            .definition => try self.inTags("dd", id, 2, &.{}),
            .term => try self.inTags("dt", id, 1, &.{}),
            .definition_list => try self.inTags("dl", id, 2, &.{}),
            .bullet_list => try self.inTags("ul", id, 2, &.{}),
            .task_list => {
                // GFM's own output is a plain `<ul>`; djot marks it up with a
                // `task-list` class.
                const extra: []const KV = if (self.options.gfm_task_list_items)
                    &.{}
                else
                    &.{.{ .key = "class", .value = "task-list" }};
                try self.inTags("ul", id, 2, extra);
            },
            .ordered_list => |v| {
                var buf: [16]u8 = undefined;
                var extra: [2]KV = undefined;
                var n: usize = 0;
                if (v.start) |s| {
                    if (s != 1) {
                        const text = std.fmt.bufPrint(&buf, "{d}", .{s}) catch "1";
                        extra[n] = .{ .key = "start", .value = text };
                        n += 1;
                    }
                }
                if (v.style.numbering != .decimal) {
                    extra[n] = .{ .key = "type", .value = orderedListType(v.style.numbering) };
                    n += 1;
                }
                try self.inTags("ol", id, 2, extra[0..n]);
            },
            .heading => |v| {
                var buf: [4]u8 = undefined;
                const tag = std.fmt.bufPrint(&buf, "h{d}", .{v.level}) catch "h1";
                try self.inTags(tag, id, 1, &.{});
            },
            .footnote_reference => |label| {
                const idx = try self.footnoteIndexFor(label);
                var extra_buf: [3]KV = undefined;
                var n: usize = 0;
                var id_buf: [24]u8 = undefined;
                if (!self.fnref_id_emitted.contains(label)) {
                    const id_text = std.fmt.bufPrint(&id_buf, "fnref{d}", .{idx}) catch "fnref";
                    extra_buf[n] = .{ .key = "id", .value = id_text };
                    n += 1;
                    try self.fnref_id_emitted.put(self.allocator, label, {});
                }
                var href_buf: [24]u8 = undefined;
                const href_text = std.fmt.bufPrint(&href_buf, "#fn{d}", .{idx}) catch "#fn";
                extra_buf[n] = .{ .key = "href", .value = href_text };
                n += 1;
                extra_buf[n] = .{ .key = "role", .value = "doc-noteref" };
                n += 1;
                try self.renderTag("a", id, extra_buf[0..n]);
                try self.writer.writeAll("<sup>");
                try self.writer.print("{d}", .{idx});
                try self.writer.writeAll("</sup></a>");
            },
            .table => if (self.options.table_sections)
                try self.renderSectionedTable(id)
            else
                try self.inTags("table", id, 2, &.{}),
            .caption => {
                var it = self.ast.children(id);
                if (it.next() != null) try self.inTags("caption", id, 1, &.{});
            },
            .row => try self.inTags("tr", id, 2, &.{}),
            .cell => |v| {
                var extra: [1]KV = undefined;
                var n: usize = 0;
                if (v.alignment != .default) {
                    extra[0] = if (self.options.gfm_cell_align_attr)
                        .{ .key = "align", .value = alignName(v.alignment) }
                    else
                        .{ .key = "style", .value = alignStyle(v.alignment) };
                    n = 1;
                }
                try self.inTags(if (v.head) "th" else "td", id, 1, extra[0..n]);
            },
            .thematic_break => {
                try self.renderTag("hr", id, &.{});
                try self.writer.writeByte('\n');
            },
            .code_block => |v| {
                try self.renderTag("pre", id, &.{});
                try self.writer.writeAll("<code");
                if (v.lang) |lang| {
                    try self.writer.writeAll(" class=\"language-");
                    try self.writeEscapedAttr(lang);
                    try self.writer.writeByte('"');
                }
                try self.writer.writeByte('>');
                try self.writeEscaped(v.text);
                try self.renderCloseTag("code");
                try self.renderCloseTag("pre");
                try self.writer.writeByte('\n');
            },
            .raw_block => |v| {
                if (std.mem.eql(u8, v.format, "html")) try self.writeRawHtml(v.text);
            },
            .metadata => |v| {
                // Raw-text refusal guard. `<script>` content is verbatim with
                // NO escape mechanism, so a `</script` in the body would end
                // the element early — corrupting the doc and opening a script-
                // injection vector. There's no fidelity-preserving escape for
                // raw text, so refuse rather than emit unsafe HTML. Deliberately
                // conservative (any `</script`, case-insensitive); legitimate
                // frontmatter never contains it. (The obscurer `<!--`+`<script`
                // double-escape can only *swallow* trailing markup, not inject —
                // a lesser, non-injection corruption left to the Stage-2 pass.)
                if (std.ascii.indexOfIgnoreCase(v.text, "</script") != null)
                    return error.UnsafeMetadata;
                // Inert, self-describing data island: a `<script>` whose type
                // isn't a JS MIME is neither executed nor displayed by the
                // browser, so document metadata stays in the file without
                // rendering into the body. The MIME is derived mechanically as
                // `application/<lang>` — already correct for toml/json/yaml/
                // ld+json and general to any config language. `lang` is an
                // `isLangTag`, hence a legal MIME subtype. (Future: hoist into
                // `<head>`.)
                try self.writer.writeAll("<script type=\"application/");
                try self.writeEscapedAttr(v.lang);
                try self.writer.writeAll("\">\n");
                try self.writer.writeAll(v.text);
                try self.writer.writeAll("</script>\n");
            },
            .str => |text| {
                if (!self.ast.attrsOf(id).isEmpty()) {
                    try self.renderTag("span", id, &.{});
                    try self.writeEscaped(text);
                    try self.writer.writeAll("</span>");
                } else {
                    try self.writeEscaped(text);
                }
            },
            .smart_punctuation => |v| try self.writer.writeAll(smartPunct(v.kind)),
            .double_quoted => {
                try self.writer.writeAll(smartPunct(.left_double_quote));
                try self.renderChildren(id);
                try self.writer.writeAll(smartPunct(.right_double_quote));
            },
            .single_quoted => {
                try self.writer.writeAll(smartPunct(.left_single_quote));
                try self.renderChildren(id);
                try self.writer.writeAll(smartPunct(.right_single_quote));
            },
            .symb => |alias| {
                try self.writer.writeByte(':');
                try self.writeEscaped(alias);
                try self.writer.writeByte(':');
            },
            .inline_math => |text| {
                try self.renderTag("span", id, &.{.{ .key = "class", .value = "math inline" }});
                try self.writer.writeAll("\\(");
                try self.writeEscaped(text);
                try self.writer.writeAll("\\)");
                try self.renderCloseTag("span");
            },
            .display_math => |text| {
                try self.renderTag("span", id, &.{.{ .key = "class", .value = "math display" }});
                try self.writer.writeAll("\\[");
                try self.writeEscaped(text);
                try self.writer.writeAll("\\]");
                try self.renderCloseTag("span");
            },
            .verbatim => |text| {
                try self.renderTag("code", id, &.{});
                try self.writeEscaped(text);
                try self.renderCloseTag("code");
            },
            .raw_inline => |v| {
                if (std.mem.eql(u8, v.format, "html")) try self.writeRawHtml(v.text);
            },
            .soft_break => try self.writer.writeByte('\n'),
            .hard_break => try self.writer.writeAll(if (self.options.xhtml_void) "<br />\n" else "<br>\n"),
            .non_breaking_space => try self.writer.writeAll("&nbsp;"),
            .link => |v| try self.renderLinkOrImage(id, v, false),
            .image => |v| try self.renderLinkOrImage(id, v, true),
            .url => |text| try self.renderUrlOrEmail(id, text, false),
            .email => |text| try self.renderUrlOrEmail(id, text, true),
            .strong => try self.inTags("strong", id, 0, &.{}),
            .emph => try self.inTags("em", id, 0, &.{}),
            .span => try self.inTags("span", id, 0, &.{}),
            .mark => try self.inTags("mark", id, 0, &.{}),
            .insert => try self.inTags("ins", id, 0, &.{}),
            .delete => try self.inTags("del", id, 0, &.{}),
            .superscript => try self.inTags("sup", id, 0, &.{}),
            .subscript => try self.inTags("sub", id, 0, &.{}),

            // Generic directives render like an element whose tag name is the
            // directive name, with the `{#id .class k=v}` shorthand applied as
            // attributes — the documented default of remark-directive /
            // `mdast-util-directive` (`:::main{#x}` -> `<main id="x">…</main>`).
            // `text` is inline (no surrounding newlines); `leaf`/`container`
            // are block-level.
            .directive => |d| switch (d.form) {
                .text => try self.inTags(d.name, id, 0, &.{}),
                .leaf => try self.inTags(d.name, id, 1, &.{}),
                .container => try self.inTags(d.name, id, 2, &.{}),
            },

            // ── generic markup (net-new relative to djot/html.zig) ────────
            // See this file's module doc comment for the rationale behind
            // each of these.
            .element => |e| {
                try self.renderTag(e.name, id, &.{});
                if (isVoidElement(e.name)) return;
                if (isRawTextElement(e.name)) {
                    // Raw-text content (script/style/…) has no escaping
                    // mechanism in HTML: it must be written verbatim. Escaping
                    // it would corrupt the JS/CSS and double-escape on
                    // re-parse (`<` → `&lt;` → `&amp;lt;`).
                    try self.renderRawTextChildren(id);
                } else {
                    try self.renderChildren(id);
                }
                try self.renderCloseTag(e.name);
            },
            .comment => |text| {
                try self.writer.writeAll("<!--");
                try self.writer.writeAll(text);
                try self.writer.writeAll("-->");
            },
            .doctype => |guts| {
                try self.writer.writeAll("<!DOCTYPE");
                try self.writer.writeAll(guts);
                try self.writer.writeByte('>');
            },
            .processing_instruction => |pi| {
                try self.writer.writeAll("<?");
                try self.writer.writeAll(pi.target);
                if (pi.data.len > 0) {
                    try self.writer.writeByte(' ');
                    try self.writer.writeAll(pi.data);
                }
                try self.writer.writeByte('>');
            },
            .cdata => |text| try self.writeEscaped(text),

            // `footnote`/`reference` definitions: rendered via the side
            // tables (`renderNotes`/`renderLinkOrImage`), never in place —
            // same as `djot/html.zig`.
            else => {},
        }
    }

    fn footnoteIndexFor(self: *Renderer, label: []const u8) Allocator.Error!usize {
        if (self.footnote_index.get(label)) |i| return i;
        const idx = self.next_footnote_index;
        try self.footnote_index.put(self.allocator, label, idx);
        self.next_footnote_index += 1;
        return idx;
    }

    fn orderedListType(numbering: AST.OrderedListStyle.Numbering) []const u8 {
        return switch (numbering) {
            .decimal => "1",
            .lower_alpha => "a",
            .upper_alpha => "A",
            .lower_roman => "i",
            .upper_roman => "I",
        };
    }

    fn alignStyle(a: AST.Alignment) []const u8 {
        return switch (a) {
            .left => "text-align: left;",
            .right => "text-align: right;",
            .center => "text-align: center;",
            .default => "",
        };
    }

    /// The bare alignment keyword GFM's presentational `align` attribute
    /// takes (`gfm_cell_align_attr`), as opposed to `alignStyle`'s CSS.
    fn alignName(a: AST.Alignment) []const u8 {
        return switch (a) {
            .left => "left",
            .right => "right",
            .center => "center",
            .default => "",
        };
    }

    /// The plain-text content of a node's children (used for an image's
    /// `alt` text) -- excludes footnote references, matching djot.js's
    /// `getStringContent`. Returned buffer is owned by the caller.
    fn stringContent(self: *Renderer, id: Node.Id) Allocator.Error![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try self.addStringContent(id, &buf);
        return buf.toOwnedSlice(self.allocator);
    }

    fn addStringContent(self: *Renderer, id: Node.Id, buf: *std.ArrayList(u8)) Allocator.Error!void {
        var it = self.ast.children(id);
        while (it.next()) |child| {
            switch (child.kind) {
                .footnote_reference => {},
                .str, .verbatim, .symb, .url, .email, .inline_math, .display_math => |t| try buf.appendSlice(self.allocator, t),
                .raw_inline => |v| try buf.appendSlice(self.allocator, v.text),
                .code_block => |v| try buf.appendSlice(self.allocator, v.text),
                .raw_block => |v| try buf.appendSlice(self.allocator, v.text),
                .smart_punctuation => |v| try buf.appendSlice(self.allocator, v.text),
                .soft_break, .hard_break => try buf.append(self.allocator, '\n'),
                else => try self.addStringContent(child.id, buf),
            }
        }
    }

    /// Percent-encode a URL per `RenderOptions.percent_encode_urls`. Passes
    /// the raw slice through unchanged when the option is off; otherwise
    /// returns an owned buffer stashed in `slot` (freed by the caller) so the
    /// returned slice outlives this call's tag emission. Only one URL is
    /// emitted per link/image, so a single slot suffices.
    fn hrefValue(self: *Renderer, raw: []const u8, slot: *?[]u8) Allocator.Error![]const u8 {
        if (!self.options.percent_encode_urls) return raw;
        const enc = try percentEncodeHref(self.allocator, raw);
        slot.* = enc;
        return enc;
    }

    fn renderLinkOrImage(self: *Renderer, id: Node.Id, v: anytype, is_image: bool) RenderError!void {
        var dest: ?[]const u8 = v.destination;
        var extra = std.ArrayList(KV).empty;
        defer extra.deinit(self.allocator);
        var alt: ?[]u8 = null;
        defer if (alt) |a| self.allocator.free(a);
        var href_buf: ?[]u8 = null;
        defer if (href_buf) |b| self.allocator.free(b);

        if (v.reference) |ref| {
            const resolved = self.references.get(ref) orelse self.auto_references.get(ref);
            if (resolved) |ref_id| {
                const ref_attrs = self.ast.attrsOf(ref_id);
                dest = self.ast.nodes[ref_id].kind.reference.destination;
                const src_val = try self.hrefValue(dest.?, &href_buf);
                if (is_image) {
                    alt = try self.stringContent(id);
                    if (self.options.commonmark_image_attrs) {
                        try extra.append(self.allocator, .{ .key = "src", .value = src_val });
                        try extra.append(self.allocator, .{ .key = "alt", .value = alt.? });
                    } else {
                        try extra.append(self.allocator, .{ .key = "alt", .value = alt.? });
                        try extra.append(self.allocator, .{ .key = "src", .value = src_val });
                    }
                } else {
                    try extra.append(self.allocator, .{ .key = "href", .value = src_val });
                }
                const own_attrs = self.ast.attrsOf(id);
                for (ref_attrs.entries) |kv| {
                    // Reference-definition attrs come from djot syntax,
                    // which can't express a bare (null-value) attribute, so
                    // unwrapping can't fail.
                    if (own_attrs.get(kv.key) == null) try extra.append(self.allocator, .{ .key = kv.key, .value = kv.value.? });
                }
            } else {
                self.warn("reference not found");
            }
        } else {
            if (is_image) {
                alt = try self.stringContent(id);
                if (self.options.commonmark_image_attrs and dest != null) {
                    try extra.append(self.allocator, .{ .key = "src", .value = try self.hrefValue(dest.?, &href_buf) });
                    try extra.append(self.allocator, .{ .key = "alt", .value = alt.? });
                } else {
                    try extra.append(self.allocator, .{ .key = "alt", .value = alt.? });
                    if (dest) |d| try extra.append(self.allocator, .{ .key = "src", .value = try self.hrefValue(d, &href_buf) });
                }
            } else if (dest) |d| {
                try extra.append(self.allocator, .{ .key = "href", .value = try self.hrefValue(d, &href_buf) });
            }
        }

        if (is_image) {
            try self.renderTag("img", id, extra.items);
        } else {
            try self.inTags("a", id, 0, extra.items);
        }
    }

    fn renderUrlOrEmail(self: *Renderer, id: Node.Id, text: []const u8, is_email: bool) RenderError!void {
        var buf: [512]u8 = undefined;
        const raw_href = if (is_email)
            std.fmt.bufPrint(&buf, "mailto:{s}", .{text}) catch text
        else
            text;
        var href_buf: ?[]u8 = null;
        defer if (href_buf) |b| self.allocator.free(b);
        const href = try self.hrefValue(raw_href, &href_buf);
        try self.renderTag("a", id, &.{.{ .key = "href", .value = href }});
        try self.writeEscaped(text);
        try self.renderCloseTag("a");
    }
};

/// Write `id` (and its descendants) as HTML text to `writer`. `ctx`
/// supplies djot-style reference/footnote side tables when the tree needs
/// them (pass `null` for a tree that has none — see this file's module doc
/// comment).
pub fn serializeNode(allocator: Allocator, ast: *const AST, id: Node.Id, writer: *Writer, ctx: ?*const Context) RenderError!void {
    try serializeNodeOpts(allocator, ast, id, writer, ctx, .{});
}

/// Like `serializeNode`, but with explicit render-convention `options`
/// (void self-close, image attribute order). The bare `serializeNode`
/// delegates here with djot-default options.
pub fn serializeNodeOpts(allocator: Allocator, ast: *const AST, id: Node.Id, writer: *Writer, ctx: ?*const Context, options: RenderOptions) RenderError!void {
    var r = Renderer.init(allocator, ast, writer, ctx, options);
    defer r.deinit();
    try r.renderNode(id);
}

/// Serialize the whole tree (from `ast.root`) to `writer`.
pub fn serialize(allocator: Allocator, ast: *const AST, writer: *Writer, ctx: ?*const Context) RenderError!void {
    try serializeNodeOpts(allocator, ast, ast.root, writer, ctx, .{});
}

/// Like `serialize`, but with explicit render-convention `options`.
pub fn serializeOpts(allocator: Allocator, ast: *const AST, writer: *Writer, ctx: ?*const Context, options: RenderOptions) RenderError!void {
    try serializeNodeOpts(allocator, ast, ast.root, writer, ctx, options);
}

/// Convenience wrapper: serialize to an owned string.
pub fn serializeAlloc(allocator: Allocator, ast: *const AST, ctx: ?*const Context) RenderAllocError![]u8 {
    return serializeAllocOpts(allocator, ast, ctx, .{});
}

/// Like `serializeAlloc`, but with explicit render-convention `options`.
pub fn serializeAllocOpts(allocator: Allocator, ast: *const AST, ctx: ?*const Context, options: RenderOptions) RenderAllocError![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    // `Writer.Allocating` only ever fails (`error.WriteFailed`) when its own
    // backing allocation fails, so it collapses to `error.OutOfMemory`;
    // `error.UnsafeMetadata` propagates as a real content refusal.
    serializeOpts(allocator, ast, &out.writer, ctx, options) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.UnsafeMetadata => return error.UnsafeMetadata,
    };
    return out.toOwnedSlice();
}

const testing = std.testing;
const Builder = AST.Builder;

test "renders a simple paragraph with emphasis (no Context needed)" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const s1 = try b.addLeaf(.{ .str = "hello " });
    const em_text = try b.addLeaf(.{ .str = "world" });
    const em = try b.addContainer(.emph, &.{em_text});
    const para = try b.addContainer(.para, &.{ s1, em });
    const root = try b.addContainer(.doc, &.{para});

    var ast = try b.finish(root);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>hello <em>world</em></p>\n", html);
}

test "element with children round-trips as an open/close pair" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const text = try b.addLeaf(.{ .str = "hi" });
    const el = try b.addContainer(.{ .element = .{ .name = "video" } }, &.{text});
    b.setContentSpan(el, .{ .start = 0, .end = 2 });

    var ast = try b.finish(el);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<video>hi</video>", html);
}

test "a self-closing (XML-style) non-void element still gets an explicit close tag" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const el = try b.addLeaf(.{ .element = .{ .name = "video" } });
    // `content_span == null`: an XML-style `<video/>` parse.

    var ast = try b.finish(el);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<video></video>", html);
}

test "a void element renders with no close tag regardless of content_span" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const el = try b.addLeaf(.{ .element = .{ .name = "br" } });

    var ast = try b.finish(el);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<br>", html);
}

test "a bare (null-value) attribute on a generic element renders as just its key" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const el = try b.addLeaf(.{ .element = .{ .name = "input" } });
    try b.setAttrs(el, .{ .entries = &.{ .{ .key = "disabled", .value = null }, .{ .key = "type", .value = "checkbox" } } });

    var ast = try b.finish(el);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<input disabled type=\"checkbox\">", html);
}

test "a comment renders its text verbatim, unescaped" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const c = try b.addLeaf(.{ .comment = " a <b> & c " });

    var ast = try b.finish(c);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<!-- a <b> & c -->", html);
}

test "a doctype renders as <!DOCTYPE payload>" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const dt = try b.addLeaf(.{ .doctype = " html" });

    var ast = try b.finish(dt);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<!DOCTYPE html>", html);
}

test "a processing instruction renders as a bogus-comment-shaped <?target data>" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const pi = try b.addLeaf(.{ .processing_instruction = .{ .target = "xml-stylesheet", .data = "href=\"x.xsl\"" } });

    var ast = try b.finish(pi);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<?xml-stylesheet href=\"x.xsl\">", html);
}

test "cdata renders its contents as escaped text" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const cd = try b.addLeaf(.{ .cdata = "a < b & c" });

    var ast = try b.finish(cd);
    defer ast.deinit();

    const html = try serializeAlloc(testing.allocator, &ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("a &lt; b &amp; c", html);
}
