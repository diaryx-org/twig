//! `Markdown.Document` -> canonical-ish Markdown text.
//!
//! This is a structural printer from the shared `AST`, not a source-preserving
//! re-emitter: it writes one stable representation for each node kind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");
const md_syntax = @import("syntax.zig");
const attrs_writer = @import("../../attrs_writer.zig");
const Document = markdown.Document;
const TwigDocument = @import("../../document.zig");
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
        const p = node orelse return;
        try self.writePrefixNode(p.parent);
        try self.writer.writeAll(p.segment);
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
            if (!is_first and blank_between) try self.writer.writeByte('\n');
            try self.renderBlock(child.id, ctx);
            is_first = false;
        }
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
            const id = self.doc.link_references.get(lab) orelse continue;
            if (id != n.id) continue;
            if (!saw_any) saw_any = true else try self.writer.writeByte('\n');
            try self.writer.print("[{s}]: {s}", .{ lab, n.kind.reference.destination });
            if (self.ast.attrsOf(id).get("title")) |title| {
                try self.writer.print(" \"{s}\"", .{title});
            }
            try self.writer.writeByte('\n');
        }
    }

    fn renderFootnoteDefs(self: *Renderer) Writer.Error!void {
        var saw_any = false;
        for (self.ast.nodes) |n| {
            if (n.kind != .footnote) continue;
            const lab = n.kind.footnote.label;
            const id = self.doc.footnotes.get(lab) orelse continue;
            if (id != n.id) continue;
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

    fn renderBlock(self: *Renderer, id: Node.Id, ctx: Ctx) Writer.Error!void {
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
                var row_it = self.ast.children(id);
                var saw_header = false;
                while (row_it.next()) |row| {
                    if (self.ast.nodes[row.id].kind == .caption) continue;
                    try self.writePrefix(ctx);
                    try self.writer.writeByte('|');
                    var cell_it = self.ast.children(row.id);
                    // Inside a cell a `hard_break` must spell as `<br>`, not a
                    // row-breaking newline — flag the descent so the break arm
                    // knows (see `Ctx.in_cell`).
                    var cell_ctx = ctx;
                    cell_ctx.in_cell = true;
                    while (cell_it.next()) |cell| {
                        try self.writer.writeByte(' ');
                        try self.renderInlineChildren(cell.id, cell_ctx);
                        try self.writer.writeAll(" |");
                    }
                    try self.writer.writeByte('\n');

                    if (!saw_header and self.ast.nodes[row.id].kind.row.head) {
                        saw_header = true;
                        try self.writePrefix(ctx);
                        try self.writer.writeByte('|');
                        var ac_it = self.ast.children(row.id);
                        while (ac_it.next()) |cell| {
                            const al = self.ast.nodes[cell.id].kind.cell.alignment;
                            const delim: []const u8 = switch (al) {
                                .left => ":---",
                                .right => "---:",
                                .center => ":---:",
                                .default => "---",
                            };
                            try self.writer.print(" {s} |", .{delim});
                        }
                        try self.writer.writeByte('\n');
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
                    // Unclassified: an HTML/XML element passing through.
                    try self.writePrefix(ctx);
                    try self.writer.print("<{s}>", .{c.name});
                    try self.renderBlocks(id, ctx, false);
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
                        try self.writePrefix(ctx);
                        // djot's fenced div is anonymous — it carries its
                        // identity as a class, so the fence takes no name.
                        if (c.name.len == 0) {
                            try self.writer.writeAll("::: \n");
                            const p = Prefix{ .parent = ctx.prefix, .segment = "  " };
                            try self.renderBlocks(id, .{ .prefix = &p }, true);
                        } else {
                            try self.writer.print(":::{s}", .{c.name});
                            try self.writeDirectiveAttrs(id);
                            try self.writer.writeByte('\n');
                            try self.renderBlocks(id, ctx, true);
                        }
                        try self.writePrefix(ctx);
                        try self.writer.writeAll(":::\n");
                    },
                }
            },
            .reference => {},
            .footnote => {},
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
                .footnote_reference => {
                    const lab = leaf.text;
                    try self.writer.print("[^{s}]", .{lab});
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
                // djot's bracketed span carries its identity in `attrs`, so
                // Markdown — which has no `[…]{…}` — drops the wrapper and
                // keeps the text. Anything else is an inline directive
                // `:name[label]{attrs}`; a stray block form reaching the
                // inline path emits the single-colon spelling as a safe lossy
                // fallback, as it always has.
                if (c.name.len == 0) {
                    try self.renderInlineChildren(id, ctx);
                    return;
                }
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
fn bulletOf(sp: ?TwigDocument.Spelling) TwigDocument.Spelling.Bullet {
    const s = sp orelse return .dash;
    return switch (s) {
        .bullet => |b| b,
        else => .dash,
    };
}

/// An `ordered_list`'s recorded marker punctuation, canonical `1.` when the
/// spelling table has nothing (or something else) for the node.
fn delimOf(sp: ?TwigDocument.Spelling) TwigDocument.Spelling.OrderedDelim {
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
/// `serializeAstAlloc`: no `Document` with Markdown's side tables to
/// consult, so this builds a throwaway one by scanning `ast` directly for
/// `reference`/`footnote`-kind nodes and keying them by their own `.label`
/// payload. `ast` is only shallow-copied into the temporary `Document`
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
    node_spelling: []const ?TwigDocument.Spelling,
) Allocator.Error![]u8 {
    var link_references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty;
    defer link_references.deinit(allocator);
    var footnotes: std.StringHashMapUnmanaged(AST.Node.Id) = .empty;
    defer footnotes.deinit(allocator);

    for (ast.nodes) |n| {
        switch (n.kind) {
            .reference => |r| try link_references.put(allocator, r.label, n.id),
            .footnote => |f| try footnotes.put(allocator, f.label, n.id),
            else => {},
        }
    }

    const doc: Document = .{
        .ast = ast.*,
        .node_spelling = node_spelling,
        .link_references = link_references,
        .footnotes = footnotes,
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

// ── generic directives ──────────────────────────────────────────────────

const directives_on: markdown.ParseOptions = .{ .directives = true };

fn serializeWith(source: []const u8, options: markdown.ParseOptions) ![]u8 {
    var doc = try markdown.parse(testing.allocator, source, options);
    defer doc.deinit();
    return serializeAlloc(testing.allocator, &doc);
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
