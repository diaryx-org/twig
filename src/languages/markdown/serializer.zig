//! `Document` (a Markdown parse) -> canonical-ish Markdown text.
//!
//! This is a structural printer from the shared `AST`, not a source-preserving
//! re-emitter: it writes one stable representation for each node kind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");
const md_syntax = @import("syntax.zig");
const attrs_writer = @import("../../attrs_writer.zig");
const html_lang = @import("../html/html.zig");
const Document = @import("../../document.zig");
const AST = markdown.AST;
const Node = AST.Node;

/// One segment of a block's continuation prefix: `"> "` for a block quote, or
/// the spaces that indent a list item / definition / div body. Chained
/// parent→child on the call stack so the prefix is emitted in *nesting order*.
/// A flat indent+quote-depth pair can't express that order — a block quote
/// inside a list item needs `  > `, a list inside a block quote needs `> ` —
/// so the two must be interleaved as encountered, not summed.
const Prefix = struct {
    parent: ?*const Prefix,
    segment: []const u8,
};

const Ctx = struct {
    prefix: ?*const Prefix = null,
    /// True while rendering the inline children of a table `cell`. A row is a
    /// single source line, so a `hard_break` here must be spelled as the
    /// format's in-cell break (`Syntax.cell_line_break`, `<br>`) rather than the
    /// ordinary `  \n`, which would break the row in two.
    in_cell: bool = false,
};

const Renderer = struct {
    allocator: Allocator,
    doc: *const Document,
    ast: *const AST,
    writer: *Writer,

    fn writePrefix(self: *Renderer, ctx: Ctx) Writer.Error!void {
        try self.writePrefixNode(ctx.prefix);
    }

    /// Emit prefix segments outermost-first by recursing to the root before
    /// writing, so nesting order is preserved (`  > `, not `>   `).
    fn writePrefixNode(self: *Renderer, node: ?*const Prefix) Writer.Error!void {
        try writePrefixNodeTo(node, self.writer);
    }

    fn writePrefixNodeTo(node: ?*const Prefix, w: *Writer) Writer.Error!void {
        const p = node orelse return;
        try writePrefixNodeTo(p.parent, w);
        try w.writeAll(p.segment);
    }

    fn renderBlocks(self: *Renderer, parent: Node.Id, ctx: Ctx, blank_between: bool) Writer.Error!void {
        var it = self.ast.children(parent);
        try self.renderBlocksFrom(&it, ctx, blank_between, true);
    }

    /// Like `renderBlocks`, but driven by an already-positioned iterator
    /// (e.g. one seeded past a list item's first child — see
    /// `renderListItem`) rather than always starting from a parent's first
    /// child. `first` marks whether the NEXT node `it` yields is the first
    /// block of the item/container overall: when it isn't (the list-item
    /// case, where a leading paragraph was already written on the marker's
    /// line), `blank_between` still puts a blank line before it, matching a
    /// loose list's spacing.
    fn renderBlocksFrom(self: *Renderer, it: *AST.ChildIterator, ctx: Ctx, blank_between: bool, first: bool) Writer.Error!void {
        var is_first = first;
        while (it.next()) |child| {
            if (!is_first and blank_between) try self.writeBlankLine(ctx);
            try self.renderBlock(child.id, ctx);
            is_first = false;
        }
    }

    /// A blank line between two blocks of the same container, which inside a
    /// quote is spelled `>` and not nothing: a bare blank line ENDS the quote,
    /// so `> one\n\n> two` is two quotes where one was meant. The prefix is
    /// written with its trailing space trimmed — a list item's indentation
    /// trims to nothing, which is the bare blank line it always had.
    fn writeBlankLine(self: *Renderer, ctx: Ctx) Writer.Error!void {
        var line: Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        writePrefixNodeTo(ctx.prefix, &line.writer) catch return error.WriteFailed;
        try self.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
        try self.writer.writeByte('\n');
    }

    fn renderInlineChildren(self: *Renderer, parent: Node.Id, ctx: Ctx) Writer.Error!void {
        var it = self.ast.children(parent);
        while (it.next()) |child| try self.renderInline(child.id, ctx);
    }

    /// Write inline text, re-emitting `ctx`'s block prefix after each embedded
    /// newline so a soft-wrapped line stays inside its list item / block quote.
    /// A trailing newline gets no prefix (it would be trailing whitespace on an
    /// otherwise-blank line).
    fn writeInlineText(self: *Renderer, s: []const u8, ctx: Ctx) Writer.Error!void {
        var rest = s;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try self.writer.writeAll(rest[0 .. nl + 1]);
            rest = rest[nl + 1 ..];
            if (rest.len > 0) try self.writePrefix(ctx);
        }
        try self.writer.writeAll(rest);
    }

    /// Re-emit a directive's `{#id .class key=val}` attribute shorthand from
    /// the node's `attrs` side-table (nothing if it has none).
    ///
    /// The walk is `attrs_writer.zig`'s, shared with djot: `id` -> `#id`,
    /// `class` -> `.a .b` (its space-joined value split back apart), every other
    /// key -> `key=value` in the side-table's stored order, so a round-trip
    /// preserves how the attributes were written. Markdown's alphabet — bare
    /// values where `attributes.zig`'s grammar can read them back, quoted
    /// otherwise — is the table entry in `markdown/syntax.zig`.
    fn writeDirectiveAttrs(self: *Renderer, id: Node.Id) Writer.Error!void {
        const sp = md_syntax.table.attr_spelling orelse return;
        try attrs_writer.write(self.writer, self.ast.attrsOf(id), sp, "");
    }

    /// One `| a | b |` line for `row`'s cells.
    fn writeTableRow(self: *Renderer, ctx: Ctx, row: Node.Id) Writer.Error!void {
        try self.writePrefix(ctx);
        try self.writer.writeByte('|');
        // Inside a cell a `hard_break` must spell as `<br>`, not a
        // row-breaking newline — flag the descent so the break arm knows
        // (see `Ctx.in_cell`).
        var cell_ctx = ctx;
        cell_ctx.in_cell = true;
        var it = self.ast.children(row);
        while (it.next()) |cell| {
            try self.writer.writeByte(' ');
            try self.renderInlineChildren(cell.id, cell_ctx);
            try self.writer.writeAll(" |");
        }
        try self.writer.writeByte('\n');
    }

    /// The `|:---|---:|` line, one entry per cell of `row`, carrying that
    /// cell's alignment — the only place a column's alignment can be written,
    /// since the delimiter row is consumed by the parser and has no node.
    fn writeTableDelimiter(self: *Renderer, ctx: Ctx, row: Node.Id) Writer.Error!void {
        try self.writePrefix(ctx);
        try self.writer.writeByte('|');
        var it = self.ast.children(row);
        while (it.next()) |cell| {
            const delim: []const u8 = switch (self.ast.nodes[cell.id].kind.cell.alignment) {
                .left => ":---",
                .right => "---:",
                .center => ":---:",
                .default => "---",
            };
            try self.writer.print(" {s} |", .{delim});
        }
        try self.writer.writeByte('\n');
    }

    /// A `|  |  |` line as wide as `row` — the synthesized header a headerless
    /// table needs to stay a table. See the `.table` arm for why an empty
    /// header beats promoting the first data row.
    fn writeTableEmptyHeader(self: *Renderer, ctx: Ctx, row: Node.Id) Writer.Error!void {
        try self.writePrefix(ctx);
        try self.writer.writeByte('|');
        var it = self.ast.children(row);
        while (it.next()) |_| try self.writer.writeAll("  |");
        try self.writer.writeByte('\n');
    }

    fn fenceTicks(text: []const u8, min: usize) usize {
        var best = min;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '`') continue;
            var j = i;
            while (j < text.len and text[j] == '`') : (j += 1) {}
            const run = j - i;
            if (run >= best) best = run + 1;
            i = j;
        }
        return best;
    }

    fn writeCodeFence(self: *Renderer, ctx: Ctx, info: ?[]const u8, text: []const u8) Writer.Error!void {
        const ticks = fenceTicks(text, 3);
        try self.writePrefix(ctx);
        var i: usize = 0;
        while (i < ticks) : (i += 1) try self.writer.writeByte('`');
        // The info string directly abuts the fence (` ```fig`, not ` ``` fig`):
        // CommonMark strips leading info-string whitespace, and no-space is the
        // canonical/idiomatic spelling the reference implementation emits.
        if (info) |s| {
            if (s.len > 0) try self.writer.writeAll(s);
        }
        try self.writer.writeByte('\n');
        if (text.len > 0) try self.writer.writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try self.writer.writeByte('\n');
        try self.writePrefix(ctx);
        i = 0;
        while (i < ticks) : (i += 1) try self.writer.writeByte('`');
        try self.writer.writeByte('\n');
    }

    /// Front/end matter: `---<lang>` … `---`. A bare `---` fence (no tag) is
    /// emitted for `yaml`, matching the ecosystem-standard YAML frontmatter
    /// spelling; every other language carries its self-describing tag.
    fn writeMetadata(self: *Renderer, ctx: Ctx, lang: []const u8, text: []const u8) Writer.Error!void {
        try self.writePrefix(ctx);
        if (std.mem.eql(u8, lang, "yaml"))
            try self.writer.writeAll("---\n")
        else
            try self.writer.print("---{s}\n", .{lang});
        if (text.len > 0) try self.writer.writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try self.writer.writeByte('\n');
        try self.writePrefix(ctx);
        try self.writer.writeAll("---\n");
    }

    fn renderListItem(self: *Renderer, item_id: Node.Id, marker: []const u8, ctx: Ctx, tight: bool) Writer.Error!void {
        try self.writePrefix(ctx);
        try self.writer.writeAll(marker);

        const first = self.ast.nodes[item_id].first_child orelse {
            try self.writer.writeByte('\n');
            return;
        };
        const item_prefix = Prefix{ .parent = ctx.prefix, .segment = "  " };
        const item_ctx: Ctx = .{ .prefix = &item_prefix };
        // A leading paragraph always starts on the marker's own line (`- text`,
        // never `- \n  text`), whether the list is tight or loose. Tight
        // lists with exactly that one paragraph stop right there; everything
        // else (a loose list's first paragraph, or any later sibling block)
        // falls through to `renderBlocksFrom`.
        if (self.ast.nodes[first].kind == .para) {
            try self.renderInlineChildren(first, item_ctx);
            try self.writer.writeByte('\n');
            if (tight and self.ast.nodes[first].next_sibling == null) return;
            var it: AST.ChildIterator = .{ .ast = self.ast, .next_id = self.ast.nodes[first].next_sibling };
            try self.renderBlocksFrom(&it, item_ctx, !tight, false);
            return;
        }

        try self.writer.writeByte('\n');
        try self.renderBlocks(item_id, item_ctx, !tight);
    }

    fn renderReferenceDefs(self: *Renderer) Writer.Error!void {
        var saw_any = false;
        for (self.ast.nodes) |n| {
            if (n.kind != .reference) continue;
            const lab = n.kind.reference.label;
            const id = self.doc.labels.references.get(lab) orelse continue;
            if (id != n.id) continue;
            if (!saw_any) saw_any = true else try self.writer.writeByte('\n');
            try self.writer.print("[{s}]: {s}", .{ lab, n.kind.reference.destination });
            if (self.ast.attrsOf(id).get("title")) |title| {
                try self.writer.print(" \"{s}\"", .{title});
            }
            try self.writer.writeByte('\n');
        }
    }

    /// Footnote definitions, and citations flattened into them — Markdown has
    /// the one registry, so an rST citation is written as a footnote here for
    /// the same reason and with the same consequence as in `djot/serializer.zig`
    /// (`degraded`, matching the `.citation_reference` inline arm so the pair
    /// still resolves). A `.substitution` writes nothing at all; see
    /// `diagnostics.zig`'s `dropped` entry for it.
    fn renderFootnoteDefs(self: *Renderer) Writer.Error!void {
        var saw_any = false;
        for (self.ast.nodes) |n| {
            const lab = switch (n.kind) {
                .footnote => |f| lab: {
                    // Picks ONE definition when several share a label; built
                    // from `.footnote` nodes, so citations are not in it.
                    const id = self.doc.labels.footnote(f.label) orelse continue;
                    if (id != n.id) continue;
                    break :lab f.label;
                },
                .citation => |c| c.label,
                else => continue,
            };
            if (!saw_any) saw_any = true else try self.writer.writeByte('\n');
            try self.writer.print("[^{s}]: ", .{lab});
            const first = n.first_child;
            if (first) |_| {
                // Keep definitions parseable while staying simple.
                var out: Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                var inner = Renderer{
                    .allocator = self.allocator,
                    .doc = self.doc,
                    .ast = self.ast,
                    .writer = &out.writer,
                };
                try inner.renderBlocks(n.id, .{}, false);
                const body = out.written();
                const trimmed = std.mem.trimEnd(u8, body, "\n");
                try self.writer.writeAll(trimmed);
            }
            try self.writer.writeByte('\n');
        }
    }

    /// Whether a `div`- or `span`-named container, or an anonymous one, is
    /// written as its HTML tag. The two names are HTML's own, and a tag is
    /// the one Markdown spelling every reader agrees on for a wrapper with
    /// attributes — so a tree with no recorded origin (a conversion from
    /// another format, a built tree) takes it. The exception is a container
    /// the Markdown parser itself read as a DIRECTIVE, `:::div{…}` or
    /// `:span[…]{…}`, which the canonical serializer writes back as it found
    /// it: an author's spelling is theirs, and `Document.containerOrigin` is
    /// what records it.
    fn spellsAsTag(self: *Renderer, id: Node.Id, c: Node.Kind.Container) bool {
        const form = c.form orelse return false;
        const html_name = switch (form) {
            .block_fenced => c.name.len == 0 or std.mem.eql(u8, c.name, "div"),
            .inline_text => c.name.len == 0 or std.mem.eql(u8, c.name, "span"),
            .block_leaf => false,
        };
        if (!html_name) return false;
        return self.doc.containerOrigin(id) != .directive;
    }

    /// Whether `kind`'s attributes have to ride on a `<div>` around it: every
    /// block Markdown spells natively, since none of those spellings has a
    /// place for an attribute. A `container` carries its own (on the fence or
    /// the tag); `metadata` must stay the first block and is never wrapped;
    /// the definitions are written elsewhere.
    fn wrapsForAttrs(kind: Node.Kind) bool {
        return switch (kind) {
            .para,
            .heading,
            .thematic_break,
            .section,
            .code_block,
            .raw_block,
            .block_quote,
            .bullet_list,
            .ordered_list,
            .task_list,
            .definition_list,
            .line_block,
            .table,
            => true,
            else => false,
        };
    }

    /// `<tag attrs>`, on its own line under the prefix, or `</tag>`.
    fn writeTagLine(self: *Renderer, ctx: Ctx, tag: []const u8, attrs: ?Node.Id) Writer.Error!void {
        try self.writePrefix(ctx);
        if (attrs) |id| {
            try self.writer.print("<{s}", .{tag});
            try attrs_writer.writeHtmlAttrs(self.writer, self.ast.attrsOf(id));
            try self.writer.writeAll(">\n");
        } else {
            try self.writer.print("</{s}>\n", .{tag});
        }
    }

    /// A block that carries attributes Markdown has no spelling for is written
    /// inside a `<div>` that carries them — an HTML block, blank-separated
    /// from its content so the content stays Markdown, which every renderer
    /// that passes raw HTML through reads as a div around the block and every
    /// renderer that strips it reads as the block alone. The reparse under
    /// `html_elements` pairs the two tags into a container whose sole child is
    /// the block; under the default options they are two raw blocks, which is
    /// what `diagnostics.zig` reports as `degraded`.
    fn renderBlock(self: *Renderer, id: Node.Id, ctx: Ctx) Writer.Error!void {
        const kind = self.ast.nodes[id].kind;
        if (!wrapsForAttrs(kind) or self.ast.attrsOf(id).isEmpty()) return self.renderBlockBare(id, ctx);
        try self.writeTagLine(ctx, "div", id);
        try self.writeBlankLine(ctx);
        try self.renderBlockBare(id, ctx);
        try self.writeBlankLine(ctx);
        try self.writeTagLine(ctx, "div", null);
    }

    fn renderBlockBare(self: *Renderer, id: Node.Id, ctx: Ctx) Writer.Error!void {
        const node = self.ast.nodes[id];
        switch (node.kind) {
            .doc => try self.renderBlocks(id, ctx, true),
            .section => try self.renderBlocks(id, ctx, true),
            .para => {
                try self.writePrefix(ctx);
                try self.renderInlineChildren(id, ctx);
                try self.writer.writeByte('\n');
            },
            .heading => |h| {
                try self.writePrefix(ctx);
                var i: u32 = 0;
                while (i < h.level) : (i += 1) try self.writer.writeByte('#');
                try self.writer.writeByte(' ');
                try self.renderInlineChildren(id, ctx);
                try self.writer.writeByte('\n');
            },
            .thematic_break => {
                try self.writePrefix(ctx);
                try self.writer.writeAll("---\n");
            },
            .block_quote => {
                const p = Prefix{ .parent = ctx.prefix, .segment = "> " };
                try self.renderBlocks(id, .{ .prefix = &p }, true);
            },
            .bullet_list => |bl| {
                // The marker character is spelling, not meaning: recorded in
                // the Document's side-table when the source is known, canonical
                // `- ` otherwise (a bare-AST serialize has an empty table).
                const marker: []const u8 = switch (bulletOf(self.doc.spelling(id))) {
                    .dash => "- ",
                    .plus => "+ ",
                    .star => "* ",
                };
                var it = self.ast.children(id);
                var first = true;
                while (it.next()) |item| {
                    if (!first and !bl.tight) try self.writer.writeByte('\n');
                    try self.renderListItem(item.id, marker, ctx, bl.tight);
                    first = false;
                }
            },
            .ordered_list => |ol| {
                var n: u32 = ol.start orelse 1;
                var it = self.ast.children(id);
                var first = true;
                while (it.next()) |item| {
                    if (!first and !ol.tight) try self.writer.writeByte('\n');
                    var buf: [24]u8 = undefined;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
                    var marker_buf: [32]u8 = undefined;
                    const marker = switch (delimOf(self.doc.spelling(id))) {
                        .period => std.fmt.bufPrint(&marker_buf, "{s}. ", .{num}) catch unreachable,
                        .paren_after => std.fmt.bufPrint(&marker_buf, "{s}) ", .{num}) catch unreachable,
                        .paren_both => std.fmt.bufPrint(&marker_buf, "({s}) ", .{num}) catch unreachable,
                    };
                    try self.renderListItem(item.id, marker, ctx, ol.tight);
                    n += 1;
                    first = false;
                }
            },
            .task_list => |tl| {
                var it = self.ast.children(id);
                var first = true;
                while (it.next()) |item| {
                    if (!first and !tl.tight) try self.writer.writeByte('\n');
                    const checked = switch (self.ast.nodes[item.id].kind) {
                        .task_list_item => |v| v.checked,
                        else => false,
                    };
                    const marker = if (checked) "- [x] " else "- [ ] ";
                    try self.renderListItem(item.id, marker, ctx, tl.tight);
                    first = false;
                }
            },
            // As in the djot serializer: one paragraph, hard breaks between the
            // lines, the block identity and every `indent` lost (CommonMark
            // strips a continuation line's leading space too).
            //
            // The break is spelled `\` rather than the two trailing spaces this
            // serializer uses everywhere else, and the reason is the STANZA
            // BREAK: an empty line is real content here (7 of the docutils
            // corpus's 47 lines are one), and a line holding only two spaces is
            // a BLANK line to CommonMark, which would end the paragraph and
            // split the poem in two. `\` is a hard break the parser reads back
            // (`markdown/inline.zig`'s backslash-before-newline arm) and is not
            // whitespace-only, so the block survives as one.
            .line_block => {
                var it = self.ast.children(id);
                var first = true;
                while (it.next()) |line| {
                    if (!first) try self.writer.writeAll("\\\n");
                    try self.writePrefix(ctx);
                    try self.renderInlineChildren(line.id, ctx);
                    first = false;
                }
                if (!first) try self.writer.writeByte('\n');
            },
            .definition_list => {
                var it = self.ast.children(id);
                while (it.next()) |dli| {
                    var kid = self.ast.nodes[dli.id].first_child;
                    while (kid) |cid| : (kid = self.ast.nodes[cid].next_sibling) {
                        switch (self.ast.nodes[cid].kind) {
                            .term => {
                                try self.writePrefix(ctx);
                                try self.renderInlineChildren(cid, ctx);
                                try self.writer.writeByte('\n');
                            },
                            .definition => {
                                try self.writePrefix(ctx);
                                try self.writer.writeAll(": ");
                                const first = self.ast.nodes[cid].first_child;
                                if (first) |f| {
                                    if (self.ast.nodes[f].kind == .para and self.ast.nodes[f].next_sibling == null) {
                                        try self.renderInlineChildren(f, ctx);
                                        try self.writer.writeByte('\n');
                                    } else {
                                        try self.writer.writeByte('\n');
                                        const p = Prefix{ .parent = ctx.prefix, .segment = "  " };
                                        try self.renderBlocks(cid, .{ .prefix = &p }, true);
                                    }
                                } else try self.writer.writeByte('\n');
                            },
                            else => {},
                        }
                    }
                }
            },
            .table => {
                // Only rows produce a pipe line; `tableRows` skips the caption
                // and any `column` children, and hands over `head` without
                // reopening the union.
                //
                // GFM's delimiter row is what MAKES a run of pipe lines a
                // table, and its position is fixed: it must follow the first
                // row and nothing else. Both halves are load-bearing here, and
                // writing it from `row.head` alone got both wrong. A table
                // with no header row emitted no delimiter at all and reparsed
                // as a PARAGRAPH — every cell boundary gone, silently. A table
                // whose header was not its first row emitted the delimiter
                // mid-table, which ends the table there.
                //
                // So the delimiter is written after the first row
                // unconditionally, and a first row that is not a header gets a
                // synthesized empty header above it. The empty header is a
                // lie, but the smallest available one: promoting the first
                // data row instead would re-tag its cells as `<th>` — a claim
                // that those values are labels — while an empty header row is
                // visibly empty and leaves every original row a data row, in
                // its original position. `diagnostics.zig` reports the
                // difference as `degraded` either way.
                var probe = self.ast.tableRows(id);
                const first = probe.next() orelse return;
                var wrote_delim = false;
                if (!first.head) {
                    try self.writeTableEmptyHeader(ctx, first.id);
                    try self.writeTableDelimiter(ctx, first.id);
                    wrote_delim = true;
                }
                var row_it = self.ast.tableRows(id);
                while (row_it.next()) |row| {
                    try self.writeTableRow(ctx, row.id);
                    if (!wrote_delim) {
                        wrote_delim = true;
                        try self.writeTableDelimiter(ctx, row.id);
                    }
                }
            },
            .code_block => |cb| try self.writeCodeFence(ctx, cb.lang, cb.text),
            .raw_block => |rb| try self.writeCodeFence(ctx, rb.format, rb.text),
            .metadata => |m| try self.writeMetadata(ctx, m.lang, m.text),
            // One arm for what used to be three (`div`, `directive`,
            // `element`). The branches below are exactly the disambiguation the
            // separate kinds used to do implicitly: `form` says which spelling,
            // and an anonymous djot div is the container NAMED "div".
            .container => |c| {
                const form = c.form orelse {
                    // Unclassified: an HTML/XML element passing through. Its
                    // ATTRIBUTES pass through with it — writing the bare tag
                    // dropped `controls` and `src` off a `<video>` with no
                    // warning, which is the same silent corruption as
                    // inventing a directive, one field down.
                    try self.writePrefix(ctx);
                    try self.writer.print("<{s}", .{c.name});
                    try attrs_writer.writeHtmlAttrs(self.writer, self.ast.attrsOf(id));
                    try self.writer.writeByte('>');
                    // A text body (a `<script>`'s, a `<title>`'s) is the
                    // tag's to spell, raw or escaped — it is HTML either way.
                    if (c.text) |text| try html_lang.writeElementText(self.writer, c.name, text) else try self.renderBlocks(id, ctx, false);
                    try self.writer.print("</{s}>\n", .{c.name});
                    return;
                };
                switch (form) {
                    // A `text` container only appears inline; route a stray one
                    // there defensively rather than emitting a broken block.
                    .inline_text => {
                        try self.writePrefix(ctx);
                        try self.renderInline(id, ctx);
                        try self.writer.writeByte('\n');
                    },
                    .block_leaf => {
                        try self.writePrefix(ctx);
                        try self.writer.print("::{s}", .{c.name});
                        if (self.ast.nodes[id].first_child != null) {
                            try self.writer.writeByte('[');
                            try self.renderInlineChildren(id, ctx);
                            try self.writer.writeByte(']');
                        }
                        try self.writeDirectiveAttrs(id);
                        try self.writer.writeByte('\n');
                    },
                    .block_fenced => {
                        // A div — HTML's, or djot's anonymous fenced div,
                        // which used to be written as a nameless `::: ` that
                        // dropped its attributes — is the tag, blank-separated
                        // from its content as `renderBlock`'s wrap is. See
                        // `spellsAsTag` for the one case that is not.
                        if (self.spellsAsTag(id, c)) {
                            try self.writeTagLine(ctx, "div", id);
                            if (c.text) |text| {
                                try html_lang.writeElementText(self.writer, "div", text);
                            } else if (self.ast.nodes[id].first_child != null) {
                                try self.writeBlankLine(ctx);
                                try self.renderBlocks(id, ctx, true);
                                try self.writeBlankLine(ctx);
                            }
                            try self.writeTagLine(ctx, "div", null);
                            return;
                        }
                        try self.writePrefix(ctx);
                        try self.writer.print(":::{s}", .{c.name});
                        try self.writeDirectiveAttrs(id);
                        try self.writer.writeByte('\n');
                        try self.renderBlocks(id, ctx, true);
                        try self.writePrefix(ctx);
                        try self.writer.writeAll(":::\n");
                    },
                }
            },
            // The named definitions are written once, together, by
            // `renderReferenceDefs`/`renderFootnoteDefs`.
            .reference => {},
            .footnote => {},
            .citation => {},
            .substitution => {},
            // One arm, still exhaustive over `MarkupLeafKind`: a fourth
            // markup leaf fails THIS build (where spelling lives) and no
            // other.
            .markup_leaf => |l| {
                try self.writePrefix(ctx);
                switch (l.kind) {
                    .comment => try self.writer.print("<!--{s}-->\n", .{l.text}),
                    .doctype => try self.writer.print("<!DOCTYPE{s}>\n", .{l.text}),
                    .cdata => try self.writer.print("<![CDATA[{s}]]>\n", .{l.text}),
                }
            },
            .processing_instruction => |pi| {
                try self.writePrefix(ctx);
                if (pi.data.len == 0) try self.writer.print("<?{s}?>\n", .{pi.target}) else try self.writer.print("<?{s} {s}?>\n", .{ pi.target, pi.data });
            },
            .list_item, .task_list_item, .definition_list_item, .term, .definition, .row, .cell, .caption => {
                try self.renderBlocks(id, ctx, false);
            },
            else => {
                try self.writePrefix(ctx);
                try self.renderInline(id, ctx);
                try self.writer.writeByte('\n');
            },
        }
    }

    fn renderInline(self: *Renderer, id: Node.Id, ctx: Ctx) Writer.Error!void {
        const node = self.ast.nodes[id];
        switch (node.kind) {
            // Text may carry embedded newlines (an HTML-parsed paragraph keeps
            // its soft-wrapped lines as one `str`, where native Markdown would
            // split them into `str`/`soft_break`). Re-emit the block prefix on
            // each continuation line so it doesn't dedent out of its container.
            .str => |s| try self.writeInlineText(s, ctx),
            // A break inside a block that carries an indent/quote prefix (a
            // list item's paragraph, a block quote) must re-emit that prefix on
            // the continuation line, or the wrapped text dedents out of its
            // container. At the top level the prefix is empty, so this is a
            // no-op there.
            .soft_break => {
                try self.writer.writeByte('\n');
                try self.writePrefix(ctx);
            },
            .hard_break => if (ctx.in_cell) {
                // A row is one source line: spell the break as `<br>` (no
                // newline) so the row stays intact. The parser reads this back as
                // a `hard_break` in cell context, closing the round-trip.
                // Markdown always has this spelling (asserted coherent), so the
                // unwrap is safe.
                try self.writer.writeAll(md_syntax.table.cell_line_break.?);
            } else {
                try self.writer.writeAll("  \n");
                try self.writePrefix(ctx);
            },
            .non_breaking_space => try self.writer.writeAll("&nbsp;"),
            // Delimiters come from `md_syntax.table`, NOT from a switch here. The
            // hand-written copy this replaces had DRIFTED: it spelled `mark` as
            // `=x=` while the table said `{=`/`=}`, so a djot mark did not
            // survive a round-trip. One table, one answer.
            //
            // `text_leaf` is deliberately NOT folded in with it: a verbatim's
            // fence WIDENS to clear backticks in its own content (`` ` `` needs
            // `` `` ` `` ``), and djot's math wraps a verbatim that widens with
            // it. `Delims` is a fixed byte pair and cannot say that, so those
            // keep the arm below — the table is necessary but not sufficient
            // for them, and pretending otherwise silently corrupted output.
            .inline_mark => |m| {
                const d = md_syntax.table.delimsFor(.{ .mark = m }) orelse return;
                try self.writer.writeAll(d.open);
                // A coloured highlight (`highlight.zig`): the colour attribute
                // spells back as its circle emoji right after the opening
                // `==`, with the space the source had (`Spelling
                // .highlight_prefix`; a node with no recorded spelling —
                // converted from another format — prints tight). A colour
                // name the table doesn't know prints nothing, exactly as every
                // other attribute on a mark always has.
                if (m == .mark) {
                    if (self.ast.attrsOf(id).get(markdown.highlight.attr_key)) |name| {
                        if (markdown.highlight.Color.fromName(name)) |c| {
                            try self.writer.writeAll(c.emoji());
                            if (highlightPrefixOf(self.doc.spelling(id)) == .spaced) try self.writer.writeByte(' ');
                        }
                    }
                }
                try self.renderInlineChildren(id, ctx);
                try self.writer.writeAll(d.close);
            },
            .text_leaf => |leaf| switch (leaf.kind) {
                .symb => {
                    const s = leaf.text;
                    try self.writer.print(":{s}:", .{s});
                },
                .verbatim => {
                    const v = leaf.text;
                    const ticks = fenceTicks(v, 1);
                    var i: usize = 0;
                    while (i < ticks) : (i += 1) try self.writer.writeByte('`');
                    try self.writer.writeAll(v);
                    i = 0;
                    while (i < ticks) : (i += 1) try self.writer.writeByte('`');
                },
                .inline_math => {
                    const m = leaf.text;
                    try self.writer.print("${s}$", .{m});
                },
                .display_math => {
                    const m = leaf.text;
                    try self.writer.print("$$\n{s}\n$$", .{m});
                },
                .url => {
                    const u = leaf.text;
                    try self.writer.print("<{s}>", .{u});
                },
                .email => {
                    const e = leaf.text;
                    try self.writer.print("<{s}>", .{e});
                },
                // A citation reference goes into Markdown's one footnote
                // registry, and a substitution reference keeps its rST spelling
                // and reads as text — the same two degradations, for the same
                // two reasons, as `djot/serializer.zig`.
                .footnote_reference, .citation_reference => {
                    const lab = leaf.text;
                    try self.writer.print("[^{s}]", .{lab});
                },
                .substitution_reference => {
                    const name = leaf.text;
                    try self.writer.print("|{s}|", .{name});
                },
            },
            .raw_inline => |r| try self.writer.writeAll(r.text),
            .smart_punctuation => |sp| try self.writer.writeAll(sp.ascii()),
            // One arm, still exhaustive over `InlineMark`: a tenth mark fails
            // THIS build (where spelling lives) and no other.
            .link => |l| {
                try self.writer.writeByte('[');
                try self.renderInlineChildren(id, ctx);
                try self.writer.writeByte(']');
                if (l.destination) |dest| try self.writer.print("({s})", .{dest}) else if (l.reference) |lab| try self.writer.print("[{s}]", .{lab});
            },
            .image => |im| {
                try self.writer.writeAll("![");
                try self.renderInlineChildren(id, ctx);
                try self.writer.writeByte(']');
                if (im.destination) |dest| try self.writer.print("({s})", .{dest}) else if (im.reference) |lab| try self.writer.print("[{s}]", .{lab});
            },
            .container => |c| {
                // A span — HTML's, or djot's bracketed span, whose identity is
                // its `{…}` — is the tag, the one inline wrapper every Markdown
                // reader renders with the Markdown inside it intact. An
                // anonymous one with NO attributes has nothing to say and
                // yields its text, as it always did. See `spellsAsTag`.
                if (self.spellsAsTag(id, c)) {
                    if (c.name.len == 0 and self.ast.attrsOf(id).isEmpty()) {
                        try self.renderInlineChildren(id, ctx);
                        return;
                    }
                    try self.writer.writeAll("<span");
                    try attrs_writer.writeHtmlAttrs(self.writer, self.ast.attrsOf(id));
                    try self.writer.writeByte('>');
                    if (c.text) |text| try html_lang.writeElementText(self.writer, "span", text) else try self.renderInlineChildren(id, ctx);
                    try self.writer.writeAll("</span>");
                    return;
                }
                // An UNCLASSIFIED container is an HTML/XML element, and the
                // directive spelling is not available to it: `<my-widget>`
                // written as `:my-widget` reparses as a DIRECTIVE named
                // my-widget with the extension on, and as the literal text
                // `:my-widget[…]` without it. Either way the output claims the
                // author wrote something they did not. The block arm above has
                // always passed such a node through as a tag; this is the same
                // answer on the inline path, where the tag comes back as
                // `raw_inline` rather than as itself — degraded, but every
                // byte the author wrote is still their own.
                if (c.form == null) {
                    try self.writer.print("<{s}", .{c.name});
                    try attrs_writer.writeHtmlAttrs(self.writer, self.ast.attrsOf(id));
                    try self.writer.writeByte('>');
                    if (c.text) |text| try html_lang.writeElementText(self.writer, c.name, text) else try self.renderInlineChildren(id, ctx);
                    try self.writer.print("</{s}>", .{c.name});
                    return;
                }
                // A real inline directive `:name[label]{attrs}`; a stray block
                // form reaching the inline path emits the single-colon
                // spelling as a safe lossy fallback, as it always has.
                try self.writer.print(":{s}", .{c.name});
                if (node.first_child != null) {
                    try self.writer.writeByte('[');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte(']');
                }
                try self.writeDirectiveAttrs(id);
            },
            else => try self.renderInlineChildren(id, ctx),
        }
    }
};

/// A `bullet_list`'s recorded marker character, canonical `-` when the
/// spelling table has nothing (or something else) for the node.
/// A coloured highlight's recorded prefix form, `tight` when the spelling
/// table has nothing (or something else) for the node.
fn highlightPrefixOf(sp: ?Document.Spelling) Document.Spelling.HighlightPrefix {
    const s = sp orelse return .tight;
    return switch (s) {
        .highlight_prefix => |p| p,
        else => .tight,
    };
}

fn bulletOf(sp: ?Document.Spelling) Document.Spelling.Bullet {
    const s = sp orelse return .dash;
    return switch (s) {
        .bullet => |b| b,
        else => .dash,
    };
}

/// An `ordered_list`'s recorded marker punctuation, canonical `1.` when the
/// spelling table has nothing (or something else) for the node.
fn delimOf(sp: ?Document.Spelling) Document.Spelling.OrderedDelim {
    const s = sp orelse return .period;
    return switch (s) {
        .ordered_delim => |d| d,
        else => .period,
    };
}

pub fn serialize(allocator: Allocator, doc: *const Document, writer: *Writer) Writer.Error!void {
    var r = Renderer{ .allocator = allocator, .doc = doc, .ast = &doc.ast, .writer = writer };
    try r.renderBlock(doc.ast.root, .{});

    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var defs = Renderer{ .allocator = allocator, .doc = doc, .ast = &doc.ast, .writer = &out.writer };
    try defs.renderReferenceDefs();
    try defs.renderFootnoteDefs();
    const tail = out.written();
    if (tail.len != 0) {
        if (doc.ast.nodes[doc.ast.root].first_child != null) try writer.writeByte('\n');
        try writer.writeAll(tail);
    }
}

pub fn serializeAlloc(allocator: Allocator, doc: *const Document) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    serialize(allocator, doc, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

/// Serialize a bare, language-agnostic `AST` (e.g. one produced by a
/// DIFFERENT format's parser, for `twig convert -o markdown` cross-format
/// conversion) as Markdown text. Mirrors `djot/serializer.zig`'s
/// `serializeAstAlloc`: no parsed `Document` whose `labels` name the winning
/// definitions, so this builds a throwaway one over `Document.Labels.index`
/// — every `reference`/`footnote` node in the arena keyed by its own
/// `.label`. `ast` is only shallow-copied into the temporary `Document`
/// (never `deinit`'d through it) — the caller keeps owning it.
pub fn serializeAstAlloc(allocator: Allocator, ast: *const AST) Allocator.Error![]u8 {
    return serializeAstSpelledAlloc(allocator, ast, &.{});
}

/// `serializeAstAlloc` plus a spelling table: the same throwaway-`Document`
/// wrapper, but with `node_spelling` carried in so a caller that DOES know how
/// its lists were spelled (the C ABI's builder, whose tree has no source but
/// does have caller-declared spellings) round-trips them. `serializeAstAlloc`
/// is this with an empty table — the canonical spelling everywhere.
pub fn serializeAstSpelledAlloc(
    allocator: Allocator,
    ast: *const AST,
    node_spelling: []const ?Document.Spelling,
) Allocator.Error![]u8 {
    var labels = try Document.Labels.index(allocator, ast);
    defer labels.deinit(allocator);

    const doc: Document = .{
        .source = "",
        .ast = ast.*,
        .node_spans = &.{},
        .node_content_spans = &.{},
        .node_spelling = node_spelling,
        .labels = labels,
    };
    return serializeAlloc(allocator, &doc);
}

const testing = std.testing;

test "serializeAlloc renders basic markdown blocks" {
    var doc = try markdown.parse(testing.allocator, "# hi\n\ntext\n", .commonmark);
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "text") != null);
}

test "non-canonical list markers survive the Document path, canonicalize on the AST path" {
    // `*` bullets and `1)` delimiters render identically to `-`/`1.`, so they
    // live in the Document's spelling table, not the AST. The Document path
    // reads the table back; the bare-AST path has no table and writes the
    // canonical spelling — the same lossless-vs-canonical split the content
    // spans already follow.
    const src = "* a\n* b\n\n1) x\n";
    var doc = try markdown.parse(testing.allocator, src, .commonmark);
    defer doc.deinit();

    const spelled = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(spelled);
    try testing.expect(std.mem.indexOf(u8, spelled, "* a") != null);
    try testing.expect(std.mem.indexOf(u8, spelled, "1) x") != null);

    const canonical = try serializeAstAlloc(testing.allocator, &doc.ast);
    defer testing.allocator.free(canonical);
    try testing.expect(std.mem.indexOf(u8, canonical, "- a") != null);
    try testing.expect(std.mem.indexOf(u8, canonical, "1. x") != null);
    try testing.expect(std.mem.indexOf(u8, canonical, "* a") == null);
}

test "a line block's stanza break survives as a break, not as a paragraph split" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const l0 = try b.addContainer(.{ .line = .{} }, &.{try b.addLeaf(.{ .str = "Roses are red," })});
    const gap = try b.addContainer(.{ .line = .{} }, &.{});
    const l1 = try b.addContainer(.{ .line = .{ .indent = 1 } }, &.{try b.addLeaf(.{ .str = "violets are blue." })});
    const block = try b.addContainer(.line_block, &.{ l0, gap, l1 });
    var ast = try b.finish(try b.addContainer(.doc, &.{block}));
    defer ast.deinit();

    const out = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Roses are red,\\\n\\\nviolets are blue.\n", out);

    // The reason the break is spelled `\` here and `  ` everywhere else: two
    // trailing spaces on the empty line would make it a BLANK line, which ends
    // the paragraph and splits the poem in two. Re-parsed, this is one.
    var back = try markdown.parse(testing.allocator, out, .commonmark);
    defer back.deinit();
    const first = back.ast.nodes[back.ast.root].first_child.?;
    try testing.expect(back.ast.nodes[first].kind == .para);
    try testing.expectEqual(@as(?Node.Id, null), back.ast.nodes[first].next_sibling);
}

test "serializeAlloc: fenced code info string abuts the fence, no space" {
    var doc = try markdown.parse(testing.allocator, "```fig\nx = 1\n```\n", .commonmark);
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "```fig\n"));
    try testing.expect(std.mem.indexOf(u8, out, "``` fig") == null);
}

test "serializeAlloc: nested block prefixes are emitted in nesting order" {
    // A block quote inside a list item needs `  > ` (indent then marker); a
    // list inside a block quote needs `> ` — flat indent/quote counts can't
    // express the order, so both interleavings are checked.
    {
        var doc = try markdown.parse(testing.allocator, "- > q one\n  > q two\n", .commonmark);
        defer doc.deinit();
        const out = try serializeAlloc(testing.allocator, &doc);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "  > q one") != null);
        try testing.expect(std.mem.indexOf(u8, out, ">   q one") == null);
    }
    {
        var doc = try markdown.parse(testing.allocator, "> - item one\n> - item two\n", .commonmark);
        defer doc.deinit();
        const out = try serializeAlloc(testing.allocator, &doc);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "> - item one") != null);
    }
}

test "serializeAlloc: a quote's blank line between paragraphs keeps its marker" {
    // `> one\n\n> two` is two quotes — a bare blank line ends one — so the
    // blank between a quote's own blocks has to be `>`. A loose list item's
    // blank line is still bare: its prefix is indentation, which trims away.
    var doc = try markdown.parse(testing.allocator, "> one\n>\n> two\n", .commonmark);
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("> one\n>\n> two\n", out);
    var back = try markdown.parse(testing.allocator, out, .commonmark);
    defer back.deinit();
    try testing.expect(doc.ast.eql(back.ast));

    var loose = try markdown.parse(testing.allocator, "- one\n\n  two\n", .commonmark);
    defer loose.deinit();
    const loose_out = try serializeAlloc(testing.allocator, &loose);
    defer testing.allocator.free(loose_out);
    try testing.expectEqualStrings("- one\n\n  two\n", loose_out);
}

test "serializeAlloc includes detached link-reference definitions" {
    var doc = try markdown.parse(testing.allocator, "[x][a]\n\n[a]: /u \"t\"\n", .commonmark);
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "[a]: /u") != null);
}

test "serializeAlloc: a loose bullet list's first paragraph starts on the marker's line, not a bare marker + newline" {
    var doc = try markdown.parse(testing.allocator, "- one\n  two\n\n- three\n", .commonmark);
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    // The soft-wrapped continuation line is indented to align under the list
    // marker (`  two`), a byte-identical round-trip of the input — not dedented
    // to column 0.
    try testing.expect(std.mem.indexOf(u8, out, "- one\n  two\n\n- three\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- \n") == null);
}

// ── what the output must READ BACK as ───────────────────────────────────
//
// Every test below asserts on the REPARSE, not on the bytes. The bugs they
// pin all produced plausible-looking output — `| a | b |`, `:my-widget[y]` —
// that a byte assertion would have accepted while the document silently
// changed shape underneath it.

test "a header-less table reparses as a TABLE, not a paragraph" {
    // `<table><tr><td>a</td><td>b</td></tr></table>` — HTML needs no header
    // row, GFM's delimiter row is mandatory, and the serializer used to write
    // the delimiter only when it saw a `head` row. The output was `| a | b |`,
    // which is a PARAGRAPH: every cell boundary in the document, gone, with
    // nothing reporting it.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const c1 = try b.addContainer(.{ .cell = .{ .head = false, .alignment = .default } }, &.{try b.addLeaf(.{ .str = "a" })});
    const c2 = try b.addContainer(.{ .cell = .{ .head = false, .alignment = .default } }, &.{try b.addLeaf(.{ .str = "b" })});
    const row = try b.addContainer(.{ .row = .{ .head = false } }, &.{ c1, c2 });
    const table = try b.addContainer(.table, &.{row});
    var ast = try b.finish(try b.addContainer(.doc, &.{table}));
    defer ast.deinit();

    const src = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(src);
    // Tables are off in the strict-CommonMark preset; the default set is the
    // one that can read a pipe table back at all.
    var back = try markdown.parse(testing.allocator, src, .{});
    defer back.deinit();

    var found_table = false;
    var body_cells: usize = 0;
    for (back.ast.nodes) |n| switch (n.kind) {
        .table => found_table = true,
        // The synthesized header is a real header row on the way back, so the
        // original row must still be the one that is NOT a header — the data
        // stayed data rather than being promoted to labels.
        .cell => |c| if (!c.head) {
            body_cells += 1;
        },
        else => {},
    };
    try testing.expect(found_table);
    try testing.expectEqual(@as(usize, 2), body_cells);
}

test "an unclassified container passes through as a tag, and never as a directive" {
    // An HTML `<my-widget>` is a container with NO form. Markdown has no
    // spelling for it, and the inline arm used to reach for the directive one
    // anyway: `:my-widget[y]`, which reparses as a DIRECTIVE named my-widget
    // with the extension on and as literal text without it. Either way the
    // output claims the author wrote a directive. The block arm had always
    // passed such a node through as a tag; this is the same answer inline.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const el = try b.addContainer(
        .{ .container = .{ .name = "my-widget", .form = null } },
        &.{try b.addLeaf(.{ .str = "y" })},
    );
    const para = try b.addContainer(.para, &.{ try b.addLeaf(.{ .str = "x " }), el });
    var ast = try b.finish(try b.addContainer(.doc, &.{para}));
    defer ast.deinit();

    const src = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "<my-widget>y</my-widget>") != null);
    try testing.expect(std.mem.indexOf(u8, src, ":my-widget") == null);

    // Even with directives ENABLED — the reading under which the old output
    // was most wrong — nothing in the reparse is a container.
    var doc = try markdown.parse(testing.allocator, src, directives_on);
    defer doc.deinit();
    for (doc.ast.nodes) |n| try testing.expect(n.kind != .container);
}

test "an unclassified container keeps its attributes" {
    // `<video controls src="a.mp4">` went out as a bare `<video>`: the tag
    // survived and every attribute on it was dropped in silence.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const p = try b.addContainer(.para, &.{try b.addLeaf(.{ .str = "hi" })});
    const el = try b.addContainer(.{ .container = .{ .name = "video", .form = null } }, &.{p});
    try b.setAttrs(el, .{ .entries = &.{
        .{ .key = "controls", .value = null },
        .{ .key = "src", .value = "a.mp4" },
    } });
    var ast = try b.finish(try b.addContainer(.doc, &.{el}));
    defer ast.deinit();

    const src = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "<video controls src=\"a.mp4\">") != null);
}

// ── generic directives ──────────────────────────────────────────────────

const directives_on: markdown.ParseOptions = .{ .directives = true };

fn serializeWith(source: []const u8, options: markdown.ParseOptions) ![]u8 {
    var doc = try markdown.parse(testing.allocator, source, options);
    defer doc.deinit();
    return serializeAlloc(testing.allocator, &doc);
}

test "highlight round-trips: ==text== parses to a mark and prints back as ==text==" {
    const out = try serializeWith("some ==lit== *and ==more==*\n", .{ .highlight = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("some ==lit== *and ==more==*\n", out);
}

test "underline round-trips under html_elements: <u>text</u> is an insert and prints back as <u>" {
    const src = "some <u>lit</u> *and <u>more</u>*\n";
    const out = try serializeWith(src, .{ .html_elements = true });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an insert converted from elsewhere prints as <u>" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const x = try b.addLeaf(.{ .str = "x" });
    const ins = try b.addContainer(.{ .inline_mark = .insert }, &.{x});
    const para = try b.addContainer(.para, &.{ins});
    const root = try b.addContainer(.doc, &.{para});
    var ast = try b.finish(root);
    defer ast.deinit();
    const out = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<u>x</u>\n", out);
}

test "highlight colors round-trip: the emoji and its spacing come back as written" {
    const colors_on: markdown.ParseOptions = .{ .highlight = true, .highlight_colors = true };
    const cases = [_][]const u8{
        "a ==\u{1F534} red== b\n",
        "a ==\u{1F7E2}green== b\n",
        "==\u{1F535} *blue* and ==\u{1F7E3}purple==\n",
    };
    for (cases) |src| {
        const out = try serializeWith(src, colors_on);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(src, out);
    }
}

test "highlight colors: a mark converted from elsewhere with data-color prints tight" {
    // Build the tree by hand: a `mark` with `data-color=blue` and no spelling
    // record, as a djot `{=x=}{data-color=blue}` would arrive.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const x = try b.addLeaf(.{ .str = "x" });
    const mark = try b.addContainer(.{ .inline_mark = .mark }, &.{x});
    try b.setAttrs(mark, .{ .entries = &.{.{ .key = "data-color", .value = "blue" }} });
    const para = try b.addContainer(.para, &.{mark});
    const root = try b.addContainer(.doc, &.{para});
    var ast = try b.finish(root);
    defer ast.deinit();
    const out = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("==\u{1F535}x==\n", out);
}

test "container directive serializes back to :::name{attrs}" {
    const out = try serializeWith(":::note{#n .box}\nHello\n:::\n", directives_on);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(":::note{#n .box}\nHello\n:::\n", out);
}

test "leaf directive serializes back to ::name[label]{attrs}" {
    const out = try serializeWith("::youtube[A caption]{#v}\n", directives_on);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("::youtube[A caption]{#v}\n", out);
}

test "text directive serializes back to :name[label]{attrs}" {
    // An all-alphanumeric value needs no quotes, so it canonicalizes bare.
    const out = try serializeWith("See :abbr[HTML]{title=HyperText} ok.\n", directives_on);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("See :abbr[HTML]{title=HyperText} ok.\n", out);
}

test "attribute value with a space is quoted on the way out" {
    const out = try serializeWith(":span[x]{title=\"a b\"}\n", directives_on);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(":span[x]{title=\"a b\"}\n", out);
}

test "directive round-trips are stable (parse->print->parse->print)" {
    const cases = [_][]const u8{
        ":::warning\ntext\n:::\n",
        "::hr\n",
        ":here\n",
        ":::box{.a .b key=val}\n- x\n- y\n:::\n",
    };
    for (cases) |src| {
        const first = try serializeWith(src, directives_on);
        defer testing.allocator.free(first);
        const second = try serializeWith(first, directives_on);
        defer testing.allocator.free(second);
        try testing.expectEqualStrings(first, second);
    }
}

// ── attributes: the div and the span ───────────────────────────────────

const Djot = @import("../djot/djot.zig");

fn djotToMarkdown(src: []const u8) ![]u8 {
    var doc = try Djot.parse(testing.allocator, src);
    defer doc.deinit();
    return serializeAstAlloc(testing.allocator, &doc.ast);
}

fn htmlToMarkdown(src: []const u8) ![]u8 {
    var doc = try html_lang.parse(testing.allocator, src);
    defer doc.deinit();
    return serializeAstAlloc(testing.allocator, &doc.ast);
}

test "an attributed paragraph is written inside a div that carries the attributes" {
    // The class used to be dropped with no warning. Now it rides on a `<div>`
    // around the paragraph, blank-separated so the paragraph stays Markdown.
    const out = try djotToMarkdown("{.center data-size=\"large\"}\nhello\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<div class=\"center\" data-size=\"large\">\n\nhello\n\n</div>\n", out);
}

test "every natively spelled block wraps the same way, a fence and a list included" {
    const out = try djotToMarkdown("{.note}\n```\nx\n```\n\n{.steps}\n- one\n- two\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<div class=\"note\">\n\n```\nx\n```\n\n</div>\n\n<div class=\"steps\">\n\n- one\n- two\n\n</div>\n",
        out,
    );
    // djot gives a heading's attribute block to the SECTION it opens, so the
    // section is what wraps, and a block inside it wraps within.
    const sec = try djotToMarkdown("{#top}\n## Title\n\n{.steps}\n- one\n");
    defer testing.allocator.free(sec);
    try testing.expect(std.mem.startsWith(u8, sec, "<div id=\"top\">\n\n## Title\n\n<div class=\"steps\">\n\n- one\n\n</div>\n\n</div>\n"));
}

test "the wrap carries a quote's prefix on every line, the blanks included" {
    const out = try djotToMarkdown("> {.c}\n> hello\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("> <div class=\"c\">\n>\n> hello\n>\n> </div>\n", out);
}

test "a block with no attributes is not wrapped" {
    const out = try djotToMarkdown("hello\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\n", out);
}

test "djot's anonymous div is a <div> carrying its class, not a nameless fence" {
    // `::: center` used to come out as `::: ` — a fence with nothing on it,
    // the class gone.
    const out = try djotToMarkdown("::: center\ninside\n:::\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<div class=\"center\">\n\ninside\n\n</div>\n", out);
}

test "an HTML div is a <div> in Markdown, not a directive named div" {
    const out = try htmlToMarkdown("<div class=\"c\"><p>x</p><p>y</p></div>");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<div class=\"c\">\n\nx\n\ny\n\n</div>\n", out);
}

test "djot's bracketed span and HTML's span are both a <span> carrying the attributes" {
    const dj = try djotToMarkdown("a [big _text_]{.large} b\n");
    defer testing.allocator.free(dj);
    try testing.expectEqualStrings("a <span class=\"large\">big *text*</span> b\n", dj);

    const h = try htmlToMarkdown("<p>a <span class=\"large\">big</span> b</p>");
    defer testing.allocator.free(h);
    try testing.expectEqualStrings("a <span class=\"large\">big</span> b\n", h);
}

test "an anonymous span with nothing to say still yields its text" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const span = try b.addContainer(.{ .container = .{ .name = "", .form = .inline_text } }, &.{try b.addLeaf(.{ .str = "x" })});
    const para = try b.addContainer(.para, &.{span});
    var ast = try b.finish(try b.addContainer(.doc, &.{para}));
    defer ast.deinit();
    const out = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x\n", out);
}

test "a div or span the Markdown parser read as a directive is written back as one" {
    // The author's spelling is theirs: `Document.containerOrigin` says the
    // container came from `:::div`, so the canonical serializer keeps it,
    // where a conversion (no origin) takes the tag.
    const div = try serializeWith(":::div{.c}\nx\n:::\n", directives_on);
    defer testing.allocator.free(div);
    try testing.expectEqualStrings(":::div{.c}\nx\n:::\n", div);
    const span = try serializeWith("a :span[x]{.l} b\n", directives_on);
    defer testing.allocator.free(span);
    try testing.expectEqualStrings("a :span[x]{.l} b\n", span);
}

test "every other name keeps the directive spelling" {
    const out = try djotToMarkdown("::: note\ninside\n:::\n");
    defer testing.allocator.free(out);
    // djot's own div is anonymous and classed, so this is the anonymous
    // case; a NAMED container from HTML is the one that keeps `:::`.
    try testing.expectEqualStrings("<div class=\"note\">\n\ninside\n\n</div>\n", out);
    // An unclassified element passes through as its tag, as it always did,
    // its content written as Markdown inside.
    const aside = try htmlToMarkdown("<aside class=\"n\"><p>x</p></aside>");
    defer testing.allocator.free(aside);
    try testing.expectEqualStrings("<aside class=\"n\">x\n</aside>\n", aside);
    // And a NAMED fenced container that is not a div keeps the fence.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const p = try b.addContainer(.para, &.{try b.addLeaf(.{ .str = "x" })});
    const box = try b.addContainer(.{ .container = .{ .name = "box", .form = .block_fenced } }, &.{p});
    try b.setAttrs(box, .{ .entries = &.{.{ .key = "class", .value = "c" }} });
    var ast = try b.finish(try b.addContainer(.doc, &.{box}));
    defer ast.deinit();
    const fence = try serializeAstAlloc(testing.allocator, &ast);
    defer testing.allocator.free(fence);
    try testing.expectEqualStrings(":::box{.c}\nx\n:::\n", fence);
}
