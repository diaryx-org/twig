//! Twig's shared `AST` -> AsciiDoc text — `convert -o asciidoc`, and
//! `-o canonical` for a document that came from AsciiDoc.
//!
//! A structural printer, like `markdown/serializer.zig` and
//! `djot/serializer.zig`: one stable spelling per node kind, never a
//! source-preserving re-emit. It reads only MEANING (`*const AST`) plus the
//! `Document`'s spelling table; never a span, so a bare tree built by another
//! parser — or the C ABI's builder — serializes exactly as a parsed one does.
//!
//! ── The spellings, and where they come from ─────────────────────────────────
//! Inline delimiters come from `syntax.zig`'s table, not from a switch here,
//! so the serializer and the editor's gestures cannot drift apart. The table
//! holds the UNCONSTRAINED forms (`**`, `__`, `##`, ` `` `), because those
//! are the ones that reparse wherever a gesture puts them; this file writes
//! the constrained single-delimiter form instead whenever the span sits on
//! word boundaries — the idiomatic spelling, derived from the same table
//! entry by halving it — and falls back to the doubled form mid-word.
//!
//! Blocks take AsciiDoc's own delimited forms: `====` for an example or an
//! admonition (with its `[NOTE]` line), `____` for a quote or a `[verse]`,
//! `****` for a sidebar, `----` for a listing (widened past any run of dashes
//! in its content, the way a Markdown fence widens past backticks), `++++`
//! for a pass block, `|===` for a table, `--` for an open block. Lists use
//! marker DEPTH for nesting (`*`, `**`; `.`, `..`) and `+` continuation for a
//! block attached to an item, since indentation means nothing here.
//!
//! ── What degrades, and how ──────────────────────────────────────────────────
//! `diagnostics.zig`'s fidelity table is the measured statement of what
//! survives a round-trip; the summary is that AsciiDoc holds nearly the whole
//! vocabulary. An `insert`/`delete` mark becomes a role span
//! (`[.underline]#x#`), a citation an anchor plus `<<xref>>`, a line block a
//! `[verse]`, generic markup (HTML comments, doctypes, processing
//! instructions) a comment block or nothing, a `column` nothing at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Document = @import("../../document.zig");
const adoc_syntax = @import("syntax.zig");
const parser = @import("parser.zig");

const Renderer = struct {
    allocator: Allocator,
    doc: *const Document,
    ast: *const AST,
    w: *Writer,
    /// The last byte written — what decides whether a constrained span may
    /// open here (not after a word character).
    last: u8 = '\n',
    bullet_depth: u32 = 0,
    ordered_depth: u32 = 0,
    dlist_depth: u32 = 0,
    /// Enclosing delimited blocks per delimiter byte, so a nested block of
    /// the same kind gets a longer delimiter.
    delim_depth: [256]u8 = [_]u8{0} ** 256,
    /// Footnote labels whose body has been written at a reference already;
    /// a later reference to the same label is `footnote:label[]`.
    footnotes_written: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Renderer) void {
        self.footnotes_written.deinit(self.allocator);
    }

    fn emit(self: *Renderer, s: []const u8) Writer.Error!void {
        if (s.len == 0) return;
        try self.w.writeAll(s);
        self.last = s[s.len - 1];
    }

    fn emitByte(self: *Renderer, c: u8) Writer.Error!void {
        try self.w.writeByte(c);
        self.last = c;
    }

    fn emitRepeat(self: *Renderer, c: u8, n: usize) Writer.Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.emitByte(c);
    }

    fn emitInt(self: *Renderer, n: u32) Writer.Error!void {
        var buf: [12]u8 = undefined;
        try self.emit(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
    }

    fn attrs(self: *const Renderer, id: Node.Id) AST.Attrs {
        return self.ast.attrsOf(id);
    }

    // ── blocks ───────────────────────────────────────────────────────────

    fn renderBlocks(self: *Renderer, parent: Node.Id) anyerror!void {
        var it = self.ast.children(parent);
        var prev: ?Node.Id = null;
        while (it.next()) |c| {
            if (prev) |p| try self.separate(p, c.id);
            try self.renderBlock(c.id);
            prev = c.id;
        }
    }

    /// The blank line between two blocks — and, between two lists, the empty
    /// attribute line that keeps them apart: two lists in a row would read
    /// back as one (same marker) or as nested (different markers).
    fn separate(self: *Renderer, prev: Node.Id, cur: Node.Id) Writer.Error!void {
        try self.emitByte('\n');
        if (isList(self.ast.nodes[prev].kind) and isList(self.ast.nodes[cur].kind)) try self.emit("[]\n");
    }

    fn isList(kind: Node.Kind) bool {
        return switch (kind) {
            .bullet_list, .ordered_list, .task_list, .definition_list => true,
            else => false,
        };
    }

    /// The document: a title with its attribute entries directly under it,
    /// then the body.
    fn renderDocument(self: *Renderer, id: Node.Id) anyerror!void {
        var it = self.ast.children(id);
        var pending_attrs: ?Node.Id = null;
        var prev: ?Node.Id = null;
        while (it.next()) |c| {
            const kind = self.ast.nodes[c.id].kind;
            if (kind == .container and std.mem.eql(u8, kind.container.name, "document-attributes")) {
                pending_attrs = c.id;
                continue;
            }
            if (prev) |p| try self.separate(p, c.id);
            prev = c.id;
            if (kind == .heading and kind.heading.level == 1 and pending_attrs != null) {
                try self.renderBlock(c.id);
                try self.writeAttrEntries(pending_attrs.?);
                pending_attrs = null;
                continue;
            }
            if (pending_attrs) |pa| {
                // Entries with no title to sit under: body attribute entries.
                try self.writeAttrEntries(pa);
                pending_attrs = null;
                try self.emitByte('\n');
            }
            try self.renderBlock(c.id);
        }
        if (pending_attrs) |pa| {
            if (prev != null) try self.emitByte('\n');
            try self.writeAttrEntries(pa);
        }
    }

    fn writeAttrEntries(self: *Renderer, marker: Node.Id) anyerror!void {
        for (self.attrs(marker).entries) |kv| {
            // The author line's implicit attributes are written back as
            // entries too: Asciidoctor accepts `:author:` and friends.
            try self.emitByte(':');
            if (kv.value == null) try self.emitByte('!');
            try self.emit(kv.key);
            try self.emitByte(':');
            if (kv.value) |v| if (v.len > 0) {
                try self.emitByte(' ');
                try self.emit(v);
            };
            try self.emitByte('\n');
        }
    }

    /// The keys every block's attribute line spells through the shorthand
    /// rather than as `key=value`.
    const shorthand_keys = [_][]const u8{ "id", "class", "options", "title" };

    fn isSkipped(key: []const u8, skip: []const []const u8) bool {
        for (shorthand_keys) |k| if (std.mem.eql(u8, k, key)) return true;
        for (skip) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    /// `.Title` and `[style#id.role%opt,pos2,pos3,key=value]` for `id`, from
    /// its attributes. `style` is the block's own style word (`source`,
    /// `NOTE`, `verse`), `positional` its second and later positionals
    /// (`attribution`, a language); `skip` names attributes the caller has
    /// spelled elsewhere.
    fn writeBlockAttrs(self: *Renderer, id: Node.Id, style: ?[]const u8, positional: []const ?[]const u8, skip: []const []const u8) anyerror!void {
        return self.writeBlockAttrsWith(id, style, positional, skip, &.{});
    }

    /// `writeBlockAttrs` plus named entries of the caller's own (`start=3`).
    fn writeBlockAttrsWith(self: *Renderer, id: Node.Id, style: ?[]const u8, positional: []const ?[]const u8, skip: []const []const u8, extra: []const AST.KeyVal) anyerror!void {
        const a = self.attrs(id);
        if (a.get("title")) |t| {
            try self.emitByte('.');
            try self.emit(t);
            try self.emitByte('\n');
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        const al = self.allocator;
        if (style) |s| try line.appendSlice(al, s);
        if (a.get("id")) |i| {
            try line.append(al, '#');
            try line.appendSlice(al, i);
        }
        if (a.get("class")) |cls| {
            var it = std.mem.tokenizeScalar(u8, cls, ' ');
            while (it.next()) |r| {
                try line.append(al, '.');
                try line.appendSlice(al, r);
            }
        }
        if (a.get("options")) |opts| {
            var it = std.mem.tokenizeAny(u8, opts, ", ");
            while (it.next()) |o| {
                try line.append(al, '%');
                try line.appendSlice(al, o);
            }
        }
        // Positional slots two onward: the caller's, then any `$N` the parser kept.
        var slots: std.ArrayList(?[]const u8) = .empty;
        defer slots.deinit(al);
        try slots.appendSlice(al, positional);
        for (a.entries) |kv| {
            if (kv.key.len < 2 or kv.key[0] != '$') continue;
            const n = std.fmt.parseInt(usize, kv.key[1..], 10) catch continue;
            if (n < 2) continue;
            while (slots.items.len < n - 1) try slots.append(al, null);
            if (slots.items[n - 2] == null) slots.items[n - 2] = kv.value;
        }
        // Trailing empty slots are dropped; interior ones stay as `,,`.
        var used = slots.items.len;
        while (used > 0 and slots.items[used - 1] == null) used -= 1;
        for (slots.items[0..used]) |slot| {
            try line.append(al, ',');
            if (slot) |v| try appendAttrValue(&line, al, v);
        }
        for (extra) |kv| {
            if (line.items.len > 0) try line.append(al, ',');
            try line.appendSlice(al, kv.key);
            if (kv.value) |v| {
                try line.append(al, '=');
                try appendAttrValue(&line, al, v);
            }
        }
        for (a.entries) |kv| {
            if (kv.key.len > 0 and kv.key[0] == '$') continue;
            if (isSkipped(kv.key, skip)) continue;
            if (line.items.len > 0) try line.append(al, ',');
            try line.appendSlice(al, kv.key);
            if (kv.value) |v| {
                try line.append(al, '=');
                try appendAttrValue(&line, al, v);
            }
        }
        if (line.items.len == 0) return;
        try self.emitByte('[');
        try self.emit(line.items);
        try self.emit("]\n");
    }

    fn appendAttrValue(line: *std.ArrayList(u8), al: Allocator, v: []const u8) Allocator.Error!void {
        const needs_quotes = std.mem.indexOfAny(u8, v, ", ]\"") != null or v.len == 0;
        if (!needs_quotes) return line.appendSlice(al, v);
        try line.append(al, '"');
        for (v) |c| {
            if (c == '"') try line.append(al, '\\');
            try line.append(al, c);
        }
        try line.append(al, '"');
    }

    /// A delimiter line of `c`, one longer per enclosing block of the same
    /// byte, and — for a listing — longer than any run of `c` in `body`.
    fn delimiter(self: *Renderer, c: u8, body: ?[]const u8) Writer.Error!void {
        var n: usize = 4 + self.delim_depth[c];
        if (body) |b| {
            var i: usize = 0;
            while (i < b.len) : (i += 1) {
                if (b[i] != c) continue;
                const at_line_start = i == 0 or b[i - 1] == '\n';
                var j = i;
                while (j < b.len and b[j] == c) : (j += 1) {}
                if (at_line_start and j - i >= n) n = j - i + 1;
                i = j;
            }
        }
        try self.emitRepeat(c, n);
        try self.emitByte('\n');
    }

    /// `[style]` line, opening delimiter, the children as blocks, closing
    /// delimiter.
    fn delimitedParent(self: *Renderer, id: Node.Id, c: u8, style: ?[]const u8, positional: []const ?[]const u8, skip: []const []const u8) anyerror!void {
        try self.writeBlockAttrs(id, style, positional, skip);
        try self.delimiter(c, null);
        self.delim_depth[c] += 1;
        try self.renderBlocks(id);
        self.delim_depth[c] -= 1;
        try self.delimiter(c, null);
    }

    fn delimitedLeaf(self: *Renderer, id: Node.Id, c: u8, style: ?[]const u8, positional: []const ?[]const u8, text: []const u8) anyerror!void {
        try self.writeBlockAttrs(id, style, positional, &.{});
        try self.delimiter(c, text);
        if (text.len > 0) try self.emit(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try self.emitByte('\n');
        try self.delimiter(c, text);
    }

    fn renderBlock(self: *Renderer, id: Node.Id) anyerror!void {
        const node = self.ast.nodes[id];
        switch (node.kind) {
            .doc => try self.renderDocument(id),
            .section => try self.renderBlocks(id),
            .para => {
                // A paragraph holding one image is the block macro.
                if (node.first_child) |only| if (self.ast.nodes[only].next_sibling == null and self.ast.nodes[only].kind == .image) {
                    try self.writeBlockAttrs(id, null, &.{}, &.{});
                    try self.emit("image::");
                    try self.imageMacro(only);
                    try self.emitByte('\n');
                    return;
                };
                try self.writeBlockAttrs(id, null, &.{}, &.{});
                try self.renderInlineChildren(id);
                try self.emitByte('\n');
            },
            .heading => |h| {
                try self.writeBlockAttrs(id, null, &.{}, &.{});
                try self.emitRepeat('=', h.level);
                try self.emitByte(' ');
                try self.renderInlineChildren(id);
                try self.emitByte('\n');
            },
            .thematic_break => {
                try self.writeBlockAttrs(id, null, &.{}, &.{});
                try self.emit(adoc_syntax.table.thematic_break.?);
                try self.emitByte('\n');
            },
            .block_quote => {
                // `____` already means a quote; the style word is only needed
                // to position an attribution after it.
                const a = self.attrs(id);
                const cited = a.get("attribution") != null or a.get("citetitle") != null;
                try self.delimitedParent(id, '_', if (cited) "quote" else null, &.{ a.get("attribution"), a.get("citetitle") }, &.{ "attribution", "citetitle" });
            },
            .bullet_list => try self.renderList(id, .bullet),
            .task_list => try self.renderList(id, .task),
            .ordered_list => try self.renderList(id, .ordered),
            .definition_list => {
                try self.writeBlockAttrs(id, null, &.{}, &.{});
                self.dlist_depth += 1;
                var it = self.ast.children(id);
                while (it.next()) |item| try self.renderDefinitionItem(item.id);
                self.dlist_depth -= 1;
            },
            .line_block => {
                const a = self.attrs(id);
                try self.writeBlockAttrs(id, "verse", &.{ a.get("attribution"), a.get("citetitle") }, &.{ "attribution", "citetitle" });
                try self.delimiter('_', null);
                var it = self.ast.children(id);
                while (it.next()) |line| {
                    const indent = switch (self.ast.nodes[line.id].kind) {
                        .line => |l| l.indent,
                        else => 0,
                    };
                    try self.emitRepeat(' ', indent * 2);
                    try self.renderInlineChildren(line.id);
                    try self.emitByte('\n');
                }
                try self.delimiter('_', null);
            },
            .table => try self.renderTable(id),
            .code_block => |cb| {
                if (cb.lang) |lang| {
                    if (isStemLang(lang)) {
                        try self.delimitedLeaf(id, '+', lang, &.{}, cb.text);
                    } else {
                        try self.delimitedLeaf(id, '-', "source", &.{lang}, cb.text);
                    }
                } else try self.delimitedLeaf(id, '-', null, &.{}, cb.text);
            },
            .raw_block => |rb| try self.delimitedLeaf(id, '+', null, &.{}, rb.text),
            .metadata => |m| {
                // Front matter, in the one spelling Asciidoctor skips over.
                try self.emit("---\n");
                if (m.text.len > 0) try self.emit(m.text);
                if (m.text.len == 0 or m.text[m.text.len - 1] != '\n') try self.emitByte('\n');
                try self.emit("---\n");
            },
            .container => |c| try self.renderContainerBlock(id, c),
            // Written at their uses (footnotes) or resolved into them
            // (references); a citation is an anchor over its body.
            .footnote, .reference => {},
            .citation => |cit| {
                try self.emit("[[");
                try self.emit(cit.label);
                try self.emit("]]\n");
                try self.renderBlocks(id);
            },
            .substitution => |s| {
                try self.emitByte(':');
                if (self.attrs(id).find("unset") != null) try self.emitByte('!');
                try self.emit(s.label);
                try self.emitByte(':');
                if (node.first_child != null) {
                    try self.emitByte(' ');
                    try self.renderInlineChildren(id);
                }
                try self.emitByte('\n');
            },
            .markup_leaf => |l| switch (l.kind) {
                .comment => {
                    try self.emit("////\n");
                    try self.emit(std.mem.trim(u8, l.text, "\n"));
                    try self.emit("\n////\n");
                },
                // No AsciiDoc spelling: the text of a CDATA section is kept,
                // a doctype is not.
                .cdata => {
                    try self.emit(l.text);
                    try self.emitByte('\n');
                },
                .doctype => {},
            },
            .processing_instruction => {},
            .column => {},
            .list_item, .task_list_item, .definition_list_item, .term, .definition, .row, .cell, .caption, .line => {
                try self.renderBlocks(id);
            },
            else => {
                try self.renderInline(id);
                try self.emitByte('\n');
            },
        }
    }

    fn isStemLang(lang: []const u8) bool {
        return std.mem.eql(u8, lang, "stem") or std.mem.eql(u8, lang, "latexmath") or std.mem.eql(u8, lang, "asciimath");
    }

    fn renderContainerBlock(self: *Renderer, id: Node.Id, c: Node.Kind.Container) anyerror!void {
        const name = c.name;
        if (std.mem.eql(u8, name, "page-break")) {
            try self.emit("<<<\n");
            return;
        }
        if (std.mem.eql(u8, name, "document-attributes")) {
            try self.writeAttrEntries(id);
            return;
        }
        if (c.form == null) {
            // An HTML/XML element passing through: written as a tag, as the
            // other lightweight serializers do, rather than inventing a block.
            try self.emitByte('<');
            try self.emit(name);
            try self.writeHtmlAttrs(id);
            try self.emit(">\n");
            try self.renderBlocks(id);
            try self.emit("</");
            try self.emit(name);
            try self.emit(">\n");
            return;
        }
        if (c.form == .inline_text) {
            try self.renderInline(id);
            try self.emitByte('\n');
            return;
        }
        // Admonitions: the container named by its variant.
        if (parser.admonitionName(upperLabel(name))) |_| {
            try self.delimitedParent(id, '=', upperLabel(name), &.{}, &.{});
            return;
        }
        if (std.mem.eql(u8, name, "example")) return self.delimitedParent(id, '=', null, &.{}, &.{});
        if (std.mem.eql(u8, name, "sidebar")) return self.delimitedParent(id, '*', null, &.{}, &.{});
        if (std.mem.eql(u8, name, "open")) return self.openBlock(id, null);
        if (c.form == .block_leaf and (std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "video") or std.mem.eql(u8, name, "toc"))) {
            try self.writeBlockAttrs(id, null, &.{}, &.{ "poster", "width", "height" });
            try self.emit(name);
            try self.emit("::");
            if (c.argument) |arg| try self.emit(arg);
            try self.emitByte('[');
            const a = self.attrs(id);
            if (std.mem.eql(u8, name, "video")) {
                try self.emitPositional(&.{ a.get("poster"), a.get("width"), a.get("height") });
            }
            try self.emit("]\n");
            return;
        }
        // Anything else: an open block carrying the name as its style, so the
        // name survives as a class if not as itself.
        if (c.form == .block_leaf) {
            try self.writeBlockAttrs(id, name, &.{}, &.{});
            try self.emit("--\n--\n");
            return;
        }
        try self.openBlock(id, name);
    }

    fn openBlock(self: *Renderer, id: Node.Id, style: ?[]const u8) anyerror!void {
        try self.writeBlockAttrs(id, style, &.{}, &.{});
        try self.emit("--\n");
        try self.renderBlocks(id);
        try self.emit("--\n");
    }

    fn writeHtmlAttrs(self: *Renderer, id: Node.Id) Writer.Error!void {
        for (self.attrs(id).entries) |kv| {
            try self.emitByte(' ');
            try self.emit(kv.key);
            if (kv.value) |v| {
                try self.emit("=\"");
                try self.emit(v);
                try self.emitByte('"');
            }
        }
    }

    /// Positional macro attributes, trailing empties dropped.
    fn emitPositional(self: *Renderer, slots: []const ?[]const u8) Writer.Error!void {
        var used = slots.len;
        while (used > 0 and slots[used - 1] == null) used -= 1;
        for (slots[0..used], 0..) |slot, i| {
            if (i > 0) try self.emitByte(',');
            if (slot) |v| try self.emit(v);
        }
    }

    // ── lists ────────────────────────────────────────────────────────────

    const ListKind = enum { bullet, task, ordered };

    fn renderList(self: *Renderer, id: Node.Id, kind: ListKind) anyerror!void {
        var style: ?[]const u8 = null;
        var start_buf: [16]u8 = undefined;
        var extra: [1]AST.KeyVal = undefined;
        var n_extra: usize = 0;
        if (kind == .ordered) {
            const ol = self.ast.nodes[id].kind.ordered_list;
            style = switch (ol.numbering) {
                .decimal => null,
                .lower_alpha => "loweralpha",
                .upper_alpha => "upperalpha",
                .lower_roman => "lowerroman",
                .upper_roman => "upperroman",
            };
            if (ol.start) |st| if (st != 1) {
                // A named attribute rather than an ordinal marker, so nesting
                // by dot depth keeps working.
                extra[0] = .{ .key = "start", .value = std.fmt.bufPrint(&start_buf, "{d}", .{st}) catch unreachable };
                n_extra = 1;
            };
        }
        try self.writeBlockAttrsWith(id, style, &.{}, &.{"start"}, extra[0..n_extra]);
        const depth_ptr = if (kind == .ordered) &self.ordered_depth else &self.bullet_depth;
        depth_ptr.* += 1;
        defer depth_ptr.* -= 1;
        var it = self.ast.children(id);
        while (it.next()) |item| {
            // The marker: `*`/`-` at depth one (the spelling, if recorded),
            // `**`… deeper, since only `*` and `.` nest by repetition.
            if (kind == .ordered) {
                try self.emitRepeat('.', self.ordered_depth);
            } else if (self.bullet_depth == 1 and bulletOf(self.doc.spelling(id)) == .dash) {
                try self.emitByte('-');
            } else {
                try self.emitRepeat('*', self.bullet_depth);
            }
            try self.emitByte(' ');
            if (kind == .task) {
                const checked = switch (self.ast.nodes[item.id].kind) {
                    .task_list_item => |t| t.checked,
                    else => false,
                };
                try self.emit(if (checked) "[x] " else "[ ] ");
            }
            try self.renderItemBody(item.id);
        }
    }

    /// An item's principal (its leading inlines, or its first paragraph's) on
    /// the marker line, then each further block: a nested list directly, any
    /// other block after a `+` continuation line.
    fn renderItemBody(self: *Renderer, item: Node.Id) anyerror!void {
        var child = self.ast.nodes[item].first_child;
        var wrote_principal = false;
        // Leading inlines.
        while (child) |cid| : (child = self.ast.nodes[cid].next_sibling) {
            if (self.ast.nodes[cid].kind.level() == .block) break;
            try self.renderInline(cid);
            wrote_principal = true;
        }
        if (!wrote_principal) {
            if (child) |cid| if (self.ast.nodes[cid].kind == .para) {
                try self.renderInlineChildren(cid);
                wrote_principal = true;
                child = self.ast.nodes[cid].next_sibling;
            };
        }
        try self.emitByte('\n');
        while (child) |cid| : (child = self.ast.nodes[cid].next_sibling) {
            switch (self.ast.nodes[cid].kind) {
                .bullet_list, .ordered_list, .task_list, .definition_list => try self.renderBlock(cid),
                else => {
                    try self.emit("+\n");
                    try self.renderBlock(cid);
                },
            }
        }
    }

    fn renderDefinitionItem(self: *Renderer, item: Node.Id) anyerror!void {
        var definition: ?Node.Id = null;
        var it = self.ast.children(item);
        var terms: usize = 0;
        while (it.next()) |c| switch (self.ast.nodes[c.id].kind) {
            .term => {
                if (terms > 0) try self.emitByte('\n');
                try self.renderInlineChildren(c.id);
                try self.emitRepeat(':', @min(2 + self.dlist_depth - 1, 4));
                terms += 1;
            },
            .definition => definition = c.id,
            else => {},
        };
        if (terms == 0) try self.emitRepeat(':', @min(2 + self.dlist_depth - 1, 4));
        const def = definition orelse {
            try self.emitByte('\n');
            return;
        };
        if (self.ast.nodes[def].first_child == null) {
            try self.emitByte('\n');
            return;
        }
        try self.emitByte(' ');
        try self.renderItemBody(def);
    }

    // ── tables ───────────────────────────────────────────────────────────

    fn renderTable(self: *Renderer, id: Node.Id) anyerror!void {
        // Width: the widest row in columns.
        var ncols: u32 = 0;
        var header = false;
        var it = self.ast.tableRows(id);
        var first = true;
        while (it.next()) |row| {
            var n: u32 = 0;
            var cit = self.ast.children(row.id);
            while (cit.next()) |cell| n += switch (self.ast.nodes[cell.id].kind) {
                .cell => |c| c.colspan,
                else => 1,
            };
            ncols = @max(ncols, n);
            if (first and row.head) header = true;
            first = false;
        }
        if (ncols == 0) ncols = 1;
        // The caption is the table's title — when it says anything (a GFM
        // table carries an empty one).
        var kids = self.ast.children(id);
        while (kids.next()) |c| if (self.ast.nodes[c.id].kind == .caption) {
            const e = try self.edges(c.id);
            defer self.allocator.free(e.text);
            if (e.text.len == 0) continue;
            try self.emitByte('.');
            try self.emit(e.text);
            try self.emitByte('\n');
        };
        var cols_buf: [24]u8 = undefined;
        const cols = std.fmt.bufPrint(&cols_buf, "cols={d}", .{ncols}) catch unreachable;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        if (header) try line.appendSlice(self.allocator, "%header");
        // The table's own attributes, minus what is spelled here.
        const a = self.attrs(id);
        if (a.get("id")) |i| {
            try line.append(self.allocator, '#');
            try line.appendSlice(self.allocator, i);
        }
        if (a.get("class")) |cls| {
            var rit = std.mem.tokenizeScalar(u8, cls, ' ');
            while (rit.next()) |r| {
                try line.append(self.allocator, '.');
                try line.appendSlice(self.allocator, r);
            }
        }
        if (line.items.len > 0) try line.append(self.allocator, ',');
        try line.appendSlice(self.allocator, cols);
        for (a.entries) |kv| {
            if (isSkipped(kv.key, &.{ "cols", "options" })) continue;
            if (kv.key.len > 0 and kv.key[0] == '$') continue;
            try line.append(self.allocator, ',');
            try line.appendSlice(self.allocator, kv.key);
            if (kv.value) |v| {
                try line.append(self.allocator, '=');
                try appendAttrValue(&line, self.allocator, v);
            }
        }
        try self.emitByte('[');
        try self.emit(line.items);
        try self.emit("]\n");
        try self.emit("|===\n");
        var rows = self.ast.tableRows(id);
        var first_row = true;
        while (rows.next()) |row| {
            if (!first_row) try self.emitByte('\n');
            first_row = false;
            var cit = self.ast.children(row.id);
            while (cit.next()) |cell| {
                switch (self.ast.nodes[cell.id].kind) {
                    .cell => |c| {
                        if (c.colspan > 1) {
                            try self.emitInt(c.colspan);
                            try self.emitByte('+');
                        }
                        if (c.rowspan > 1) {
                            try self.emitByte('.');
                            try self.emitInt(c.rowspan);
                            try self.emitByte('+');
                        }
                        switch (c.alignment) {
                            .left => try self.emitByte('<'),
                            .center => try self.emitByte('^'),
                            .right => try self.emitByte('>'),
                            .default => {},
                        }
                    },
                    else => {},
                }
                try self.emitByte('|');
                try self.renderCellContent(cell.id);
                try self.emitByte('\n');
            }
        }
        try self.emit("|===\n");
    }

    /// A cell's inlines, with a bar escaped so it cannot end the cell. A cell
    /// holding blocks (an HTML `<td><p>`) has them flattened to their inlines.
    fn renderCellContent(self: *Renderer, cell: Node.Id) anyerror!void {
        var it = self.ast.children(cell);
        while (it.next()) |c| {
            if (self.ast.nodes[c.id].kind.level() == .block) {
                try self.renderInlineChildren(c.id);
            } else try self.renderInline(c.id);
        }
    }

    // ── inlines ──────────────────────────────────────────────────────────

    fn renderInlineChildren(self: *Renderer, parent: Node.Id) anyerror!void {
        var it = self.ast.children(parent);
        while (it.next()) |c| try self.renderInline(c.id);
    }

    /// The first byte the next sibling of `id` will write, or null at the end
    /// of the run — what decides whether a constrained span may CLOSE here.
    fn nextByte(self: *const Renderer, id: Node.Id) ?u8 {
        const next = self.ast.nodes[id].next_sibling orelse return null;
        return switch (self.ast.nodes[next].kind) {
            .str => |s| if (s.len > 0) s[0] else null,
            .soft_break, .hard_break => '\n',
            .smart_punctuation => |sp| sp.ascii()[0],
            else => '<',
        };
    }

    /// First and last bytes of the text an inline run would produce.
    fn edges(self: *Renderer, id: Node.Id) anyerror!struct { first: ?u8, last: ?u8, text: []u8 } {
        var out: Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        var inner = Renderer{ .allocator = self.allocator, .doc = self.doc, .ast = self.ast, .w = &out.writer, .last = self.last, .bullet_depth = self.bullet_depth, .ordered_depth = self.ordered_depth, .dlist_depth = self.dlist_depth, .delim_depth = self.delim_depth };
        defer inner.deinit();
        try inner.renderInlineChildren(id);
        const text = try out.toOwnedSlice();
        return .{ .first = if (text.len > 0) text[0] else null, .last = if (text.len > 0) text[text.len - 1] else null, .text = text };
    }

    /// Wrap `id`'s rendered children in `d`, constrained where the boundaries
    /// allow and the table entry has a constrained half (a doubled
    /// delimiter), unconstrained otherwise.
    fn wrapSpan(self: *Renderer, id: Node.Id, d: adoc_syntax.syntax.Delims, attrs_prefix: bool) anyerror!void {
        const e = try self.edges(id);
        defer self.allocator.free(e.text);
        const doubled = d.open.len == 2 and d.open[0] == d.open[1] and std.mem.eql(u8, d.open, d.close);
        // A `[.role]` prefix, when one is written, is what precedes the opener.
        const a = self.attrs(id);
        const has_prefix = attrs_prefix and (a.get("class") != null or a.get("id") != null);
        var constrained = false;
        if (doubled and e.first != null and e.last != null) {
            const prev_ok = !isWordByte(self.last) or has_prefix;
            const next = self.nextByte(id);
            const next_ok = next == null or !isWordByte(next.?);
            constrained = prev_ok and next_ok and !isSpaceByte(e.first.?) and !isSpaceByte(e.last.?) and
                std.mem.indexOfScalar(u8, e.text, d.open[0]) == null;
        }
        if (attrs_prefix) try self.writeInlineAttrs(id);
        if (e.text.len == 0) {
            try self.emit(d.open);
            try self.emit(d.close);
            return;
        }
        if (constrained) {
            try self.emit(d.open[0..1]);
            try self.emit(e.text);
            try self.emit(d.close[0..1]);
        } else {
            try self.emit(d.open);
            try self.emit(e.text);
            try self.emit(d.close);
        }
    }

    /// `[#id.role]` before a styled span.
    fn writeInlineAttrs(self: *Renderer, id: Node.Id) Writer.Error!void {
        const a = self.attrs(id);
        const cls = a.get("class");
        const anchor = a.get("id");
        if (cls == null and anchor == null) return;
        try self.emitByte('[');
        if (anchor) |i| {
            try self.emitByte('#');
            try self.emit(i);
        }
        if (cls) |c| {
            var it = std.mem.tokenizeScalar(u8, c, ' ');
            while (it.next()) |r| {
                try self.emitByte('.');
                try self.emit(r);
            }
        }
        try self.emitByte(']');
    }

    fn imageMacro(self: *Renderer, id: Node.Id) anyerror!void {
        const im = self.ast.nodes[id].kind.image;
        const dest = im.destination orelse (if (im.reference) |r| self.resolveReference(r) else null) orelse "";
        try self.emit(dest);
        try self.emitByte('[');
        const a = self.attrs(id);
        var alt: Writer.Allocating = .init(self.allocator);
        defer alt.deinit();
        var inner = Renderer{ .allocator = self.allocator, .doc = self.doc, .ast = self.ast, .w = &alt.writer };
        defer inner.deinit();
        try inner.renderInlineChildren(id);
        try self.emitPositional(&.{ if (alt.written().len > 0) alt.written() else null, a.get("width"), a.get("height") });
        var any = alt.written().len > 0 or a.get("width") != null or a.get("height") != null;
        for (a.entries) |kv| {
            if (std.mem.eql(u8, kv.key, "width") or std.mem.eql(u8, kv.key, "height")) continue;
            if (any) try self.emitByte(',');
            any = true;
            try self.emit(kv.key);
            try self.emitByte('=');
            if (kv.value) |v| try self.emit(v);
        }
        try self.emitByte(']');
    }

    fn resolveReference(self: *const Renderer, label: []const u8) ?[]const u8 {
        for (self.ast.nodes) |n| switch (n.kind) {
            .reference => |r| if (std.mem.eql(u8, r.label, label)) return r.destination,
            else => {},
        };
        return null;
    }

    fn footnoteDefinition(self: *const Renderer, label: []const u8) ?Node.Id {
        for (self.ast.nodes) |n| switch (n.kind) {
            .footnote => |f| if (std.mem.eql(u8, f.label, label)) return n.id,
            else => {},
        };
        return null;
    }

    fn renderInline(self: *Renderer, id: Node.Id) anyerror!void {
        const node = self.ast.nodes[id];
        const table = &adoc_syntax.table;
        switch (node.kind) {
            .str => |s| try self.emit(s),
            .soft_break => try self.emitByte('\n'),
            .hard_break => try self.emit(" +\n"),
            .non_breaking_space => try self.emit("{nbsp}"),
            .smart_punctuation => |sp| try self.emit(switch (sp) {
                .em_dash => "--",
                .en_dash => "&#8211;",
                .ellipses => "...",
                .left_single_quote, .right_single_quote => "'",
                .left_double_quote, .right_double_quote => "\"",
            }),
            .inline_mark => |m| {
                const d = table.delimsFor(.{ .mark = m }).?;
                try self.wrapSpan(id, d, true);
            },
            .text_leaf => |leaf| switch (leaf.kind) {
                .verbatim => {
                    // A backtick pair cannot hold a doubled backtick; the pass
                    // macro can hold anything.
                    if (std.mem.indexOf(u8, leaf.text, "``") != null) {
                        try self.emit("pass:c[<code>");
                        try self.emit(leaf.text);
                        try self.emit("</code>]");
                        return;
                    }
                    try self.writeInlineAttrs(id);
                    const d = table.delimsFor(.{ .text_leaf = .verbatim }).?;
                    const prev_ok = !isWordByte(self.last);
                    const next = self.nextByte(id);
                    const next_ok = next == null or !isWordByte(next.?);
                    const t = leaf.text;
                    const constrained = t.len > 0 and prev_ok and next_ok and !isSpaceByte(t[0]) and !isSpaceByte(t[t.len - 1]) and std.mem.indexOfScalar(u8, t, '`') == null;
                    if (constrained) {
                        try self.emit(d.open[0..1]);
                        try self.emit(t);
                        try self.emit(d.close[0..1]);
                    } else {
                        try self.emit(d.open);
                        try self.emit(t);
                        try self.emit(d.close);
                    }
                },
                .inline_math, .display_math => {
                    try self.emit("stem:[");
                    try self.emit(leaf.text);
                    try self.emitByte(']');
                },
                .url => {
                    // A bare URL autolinks only from a scheme the parser
                    // knows; anything else needs the macro.
                    if (isAutolinkable(leaf.text)) try self.emit(leaf.text) else {
                        try self.emit("link:");
                        try self.emit(leaf.text);
                        try self.emit("[]");
                    }
                },
                .email => try self.emit(leaf.text),
                .symb => {
                    try self.emitByte(':');
                    try self.emit(leaf.text);
                    try self.emitByte(':');
                },
                .footnote_reference => {
                    try self.emit("footnote:");
                    const auto = isAllDigits(leaf.text);
                    if (!auto) try self.emit(leaf.text);
                    try self.emitByte('[');
                    const written = self.footnotes_written.contains(leaf.text);
                    if (!written) {
                        if (self.footnoteDefinition(leaf.text)) |def| {
                            try self.footnotes_written.put(self.allocator, leaf.text, {});
                            // The body: one paragraph's inlines, or blocks flattened.
                            var it = self.ast.children(def);
                            var first = true;
                            while (it.next()) |c| {
                                if (!first) try self.emitByte(' ');
                                first = false;
                                if (self.ast.nodes[c.id].kind.level() == .block) try self.renderInlineChildren(c.id) else try self.renderInline(c.id);
                            }
                        }
                    }
                    try self.emitByte(']');
                },
                .citation_reference => {
                    try self.emit("<<");
                    try self.emit(leaf.text);
                    try self.emit(">>");
                },
                .substitution_reference => {
                    try self.emitByte('{');
                    try self.emit(leaf.text);
                    try self.emitByte('}');
                },
            },
            .raw_inline => |r| {
                if (std.mem.indexOf(u8, r.text, "+++") != null) {
                    try self.emit("pass:[");
                    try self.emit(r.text);
                    try self.emitByte(']');
                } else {
                    try self.emit("+++");
                    try self.emit(r.text);
                    try self.emit("+++");
                }
            },
            .link => |l| try self.renderLink(id, l),
            .image => {
                try self.emit("image:");
                try self.imageMacro(id);
            },
            .container => |c| {
                if (c.form == null) {
                    try self.emitByte('<');
                    try self.emit(c.name);
                    try self.writeHtmlAttrs(id);
                    try self.emitByte('>');
                    try self.renderInlineChildren(id);
                    try self.emit("</");
                    try self.emit(c.name);
                    try self.emitByte('>');
                    return;
                }
                const a = self.attrs(id);
                if (std.mem.eql(u8, c.name, "kbd")) {
                    try self.emit("kbd:[");
                    try self.renderInlineChildren(id);
                    try self.emitByte(']');
                    return;
                }
                if (std.mem.eql(u8, c.name, "b") and a.get("class") != null and std.mem.eql(u8, a.get("class").?, "button")) {
                    try self.emit("btn:[");
                    try self.renderInlineChildren(id);
                    try self.emitByte(']');
                    return;
                }
                // An anchor: an anonymous span with an id and nothing inside.
                if (c.name.len == 0 and node.first_child == null and a.get("id") != null) {
                    try self.emit("[[");
                    try self.emit(a.get("id").?);
                    try self.emit("]]");
                    return;
                }
                // A styled span: `[.role]#text#`, the name as a role.
                try self.emitByte('[');
                if (a.get("id")) |i| {
                    try self.emitByte('#');
                    try self.emit(i);
                }
                if (c.name.len > 0) {
                    try self.emitByte('.');
                    try self.emit(c.name);
                }
                if (a.get("class")) |cls| {
                    var it = std.mem.tokenizeScalar(u8, cls, ' ');
                    while (it.next()) |r| {
                        try self.emitByte('.');
                        try self.emit(r);
                    }
                }
                try self.emit("]##");
                try self.renderInlineChildren(id);
                try self.emit("##");
            },
            // A block reaching the inline path: its inlines, flattened.
            else => try self.renderInlineChildren(id),
        }
    }

    fn renderLink(self: *Renderer, id: Node.Id, l: Node.Kind.Link) anyerror!void {
        const dest = l.destination orelse (if (l.reference) |r| self.resolveReference(r) else null) orelse {
            // Unresolvable: the text alone.
            try self.renderInlineChildren(id);
            return;
        };
        const a = self.attrs(id);
        var text: Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        var inner = Renderer{ .allocator = self.allocator, .doc = self.doc, .ast = self.ast, .w = &text.writer };
        defer inner.deinit();
        try inner.renderInlineChildren(id);
        const t = text.written();
        const same = std.mem.eql(u8, t, dest);
        if (dest.len > 1 and dest[0] == '#') {
            // A fragment: a cross reference.
            try self.emit("<<");
            try self.emit(dest[1..]);
            if (!same and t.len > 0 and !std.mem.eql(u8, t, dest[1..])) {
                try self.emitByte(',');
                try self.emit(t);
            }
            try self.emit(">>");
            return;
        }
        if (std.mem.startsWith(u8, dest, "mailto:")) {
            try self.emit(dest);
        } else if (isAutolinkable(dest)) {
            try self.emit(dest);
        } else {
            try self.emit("link:");
            try self.emit(dest);
        }
        try self.emitByte('[');
        if (!same and !(std.mem.startsWith(u8, dest, "mailto:") and std.mem.eql(u8, t, dest[7..]))) try self.emit(t);
        var any = !same;
        if (a.get("window")) |w| {
            if (std.mem.eql(u8, w, "_blank") and !any) {
                try self.emitByte('^');
            } else {
                if (any) try self.emitByte(',');
                try self.emit("window=");
                try self.emit(w);
                any = true;
            }
        }
        if (a.get("class")) |c| {
            if (any) try self.emitByte(',');
            try self.emit("role=");
            try self.emit(c);
        }
        try self.emitByte(']');
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Whether the parser would read `dest` back as a bare URL.
fn isAutolinkable(dest: []const u8) bool {
    inline for (.{ "https://", "http://", "ftp://", "irc://", "file://" }) |scheme| {
        if (std.mem.startsWith(u8, dest, scheme) and dest.len > scheme.len and std.mem.indexOfAny(u8, dest, " \t\n[]<>") == null) return true;
    }
    return false;
}

/// `note` -> `NOTE`; anything else unchanged.
fn upperLabel(name: []const u8) []const u8 {
    inline for (.{ "note", "tip", "important", "warning", "caution" }, parser.ADMONITIONS) |lower, upper| {
        if (std.mem.eql(u8, name, lower)) return upper;
    }
    return name;
}

/// A `bullet_list`'s recorded marker character, canonical `*` when the
/// spelling table has nothing for the node.
fn bulletOf(sp: ?Document.Spelling) Document.Spelling.Bullet {
    const s = sp orelse return .star;
    return switch (s) {
        .bullet => |b| b,
        else => .star,
    };
}

pub fn serialize(allocator: Allocator, doc: *const Document, writer: *Writer) (Writer.Error || Allocator.Error)!void {
    var r = Renderer{ .allocator = allocator, .doc = doc, .ast = &doc.ast, .w = writer };
    defer r.deinit();
    r.renderBlock(doc.ast.root) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn serializeAlloc(allocator: Allocator, doc: *const Document) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    serialize(allocator, doc, &out.writer) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

/// Serialize a bare, language-agnostic `AST` (one produced by a DIFFERENT
/// format's parser, for `twig convert -o asciidoc`) as AsciiDoc text. No
/// `Document` and no spellings: every list takes the canonical marker.
pub fn serializeAstAlloc(allocator: Allocator, ast: *const AST) Allocator.Error![]u8 {
    return serializeAstSpelledAlloc(allocator, ast, &.{});
}

/// `serializeAstAlloc` plus a spelling table — the C ABI's builder path,
/// whose tree has no source but does have caller-declared spellings.
pub fn serializeAstSpelledAlloc(allocator: Allocator, ast: *const AST, node_spelling: []const ?Document.Spelling) Allocator.Error![]u8 {
    const doc: Document = .{
        .source = "",
        .ast = ast.*,
        .node_spans = &.{},
        .node_content_spans = &.{},
        .node_spelling = node_spelling,
    };
    return serializeAlloc(allocator, &doc);
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// Every test asserts on the REPARSE as well as the bytes where the two could
// disagree: output that looks like AsciiDoc but reads back as something else
// is the failure mode a byte assertion cannot see.

const testing = std.testing;

fn roundTrip(src: []const u8) ![]u8 {
    var doc = try parser.parse(testing.allocator, src);
    defer doc.deinit();
    return serializeAlloc(testing.allocator, &doc);
}

test "a document with a title, entries, sections and paragraphs is stable" {
    const src = "= Title\n:toc:\n:icons: font\n\nIntro *bold* and _em_.\n\n== Section\n\nBody.\n";
    const out = try roundTrip(src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
    const again = try roundTrip(out);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "spans are constrained on word boundaries and unconstrained inside a word" {
    const out = try roundTrip("a **b** c sub**str**ing `m` x``y``z ##h## ^s^ ~t~\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a *b* c sub**str**ing `m` x``y``z #h# ^s^ ~t~\n", out);
}

test "lists nest by marker depth, attach blocks with a continuation, and keep their spelling" {
    // `[]` lines keep the three lists apart, in the source and in the
    // output: without one, a list of another marker nests in the item above.
    const src = "- one\n- two\n** deep\n+\nattached\n\n[]\n. first\n.. inner\n\n[]\nterm:: desc\nother::: nested\n";
    const out = try roundTrip(src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a checklist, a numbered start and a letter numbering survive" {
    const out = try roundTrip("* [x] done\n* [ ] todo\n\n[loweralpha,start=3]\n. c\n. d\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("* [x] done\n* [ ] todo\n\n[]\n[loweralpha,start=3]\n. c\n. d\n", out);
    var back = try parser.parse(testing.allocator, out);
    defer back.deinit();
    const list = back.ast.nodes[back.ast.nodes[back.ast.root].first_child.?].next_sibling.?;
    try testing.expectEqual(AST.ListNumbering.lower_alpha, back.ast.nodes[list].kind.ordered_list.numbering);
    try testing.expectEqual(@as(?u32, 3), back.ast.nodes[list].kind.ordered_list.start);
}

test "delimited blocks: listing with language, admonition, quote with attribution, verse, table" {
    const src =
        \\[source,ruby]
        \\----
        \\puts 1
        \\----
        \\
        \\[NOTE]
        \\====
        \\careful
        \\====
        \\
        \\[quote,Someone,Somewhere]
        \\____
        \\words
        \\____
        \\
        \\[verse]
        \\____
        \\Roses
        \\  red
        \\____
        \\
        \\.Fruit
        \\[%header,cols=2]
        \\|===
        \\|Name
        \\|Count
        \\
        \\|Apple
        \\^|3
        \\|===
        \\
    ;
    const out = try roundTrip(src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "block metadata round-trips: title, id, roles, options and named attributes" {
    const src = ".A title\n[#the-id.a.b%opt,key=val]\ntext\n";
    const out = try roundTrip(src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "links, xrefs, images, footnotes, anchors, math and passthroughs" {
    const src = "See https://x.org[X] and <<sec,There>> and image:i.png[Alt,50] and footnote:[note] and [[a]] and stem:[x] and +++<b>+++ and {name}.\n";
    const out = try roundTrip(src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a listing widens its delimiter past a run of dashes in its content" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const cb = try b.addLeaf(.{ .code_block = .{ .lang = null, .text = "----\nx\n" } });
    var ast = try b.finish(try b.addContainer(.doc, &.{cb}));
    defer ast.deinit();
    const out = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("-----\n----\nx\n-----\n", out);
    var back = try parser.parse(testing.allocator, out);
    defer back.deinit();
    try testing.expectEqualStrings("----\nx", back.ast.nodes[back.ast.nodes[back.ast.root].first_child.?].kind.code_block.text);
}

test "a Markdown tree converts: headings, marks, a fenced code block, a task list, a table" {
    const Markdown = @import("../markdown/markdown.zig");
    var md = try Markdown.parse(testing.allocator, "# T\n\nsome **bold** `code` [link](https://x.org)\n\n```py\nx\n```\n\n- [x] a\n\n| h |\n|---|\n| c |\n", .{});
    defer md.deinit();
    const out = try serializeAstAlloc(testing.allocator, &md.ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("= T\n\nsome *bold* `code` https://x.org[link]\n\n[source,py]\n----\nx\n----\n\n* [x] a\n\n[%header,cols=1]\n|===\n|h\n\n|c\n|===\n", out);
}

test "a mark next to a word falls back to the unconstrained form so it still reparses" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const s1 = try b.addLeaf(.{ .str = "pre" });
    const strong = try b.addContainer(.{ .inline_mark = .strong }, &.{try b.addLeaf(.{ .str = "fix" })});
    const p = try b.addContainer(.para, &.{ s1, strong });
    var ast = try b.finish(try b.addContainer(.doc, &.{p}));
    defer ast.deinit();
    const out = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("pre**fix**\n", out);
    var back = try parser.parse(testing.allocator, out);
    defer back.deinit();
    var found = false;
    for (back.ast.nodes) |n| if (n.kind == .inline_mark and n.kind.inline_mark == .strong) {
        found = true;
    };
    try testing.expect(found);
}
