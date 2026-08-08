//! `Djot.Document` -> canonical-ish Djot text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const djot = @import("djot.zig");
const Document = djot.Document;
const AST = djot.AST;
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
};

/// Djot strips one space adjacent to a backtick at each end of verbatim text
/// (`parser.zig`'s `trimVerbatim`), so text that starts or ends with a backtick
/// has to be padded on that side to survive a reparse: a lone backtick would
/// otherwise be written as three in a row, which reads back as an unterminated
/// opener rather than as a one-backtick span.
fn verbatimPad(text: []const u8) struct { left: bool, right: bool } {
    return .{
        .left = text.len > 0 and text[0] == '`',
        .right = text.len > 0 and text[text.len - 1] == '`',
    };
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

    fn writeDjotAttrs(self: *Renderer, id: Node.Id) Writer.Error!void {
        const attrs = self.ast.attrsOf(id).entries;
        if (attrs.len == 0) return;
        try self.writer.writeAll("{");
        var first = true;
        for (attrs) |kv| {
            if (!first) try self.writer.writeByte(' ');
            first = false;
            if (std.mem.eql(u8, kv.key, "id")) {
                try self.writer.print("#{s}", .{kv.value orelse ""});
            } else if (std.mem.eql(u8, kv.key, "class")) {
                const classes = kv.value orelse "";
                var it = std.mem.tokenizeScalar(u8, classes, ' ');
                var wrote = false;
                while (it.next()) |c| {
                    if (c.len == 0) continue;
                    try self.writer.print(".{s}", .{c});
                    wrote = true;
                }
                if (!wrote) try self.writer.writeAll("."); // impossible from parser, keeps syntax valid.
            } else if (kv.value) |v| {
                try self.writer.print("{s}=\"{s}\"", .{ kv.key, v });
            } else {
                try self.writer.writeAll(kv.key);
            }
        }
        try self.writer.writeAll("}");
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

    /// A backtick-delimited inline span: verbatim text, and the `` `…` `` half
    /// of a raw inline (`` `<br>`{=html} ``). The run is widened past any
    /// backtick run in `text` and padded per `verbatimPad`.
    fn writeTickFenced(self: *Renderer, text: []const u8) Writer.Error!void {
        const ticks = fenceTicks(text, 1);
        const pad = verbatimPad(text);
        var i: usize = 0;
        while (i < ticks) : (i += 1) try self.writer.writeByte('`');
        if (pad.left) try self.writer.writeByte(' ');
        try self.writer.writeAll(text);
        if (pad.right) try self.writer.writeByte(' ');
        i = 0;
        while (i < ticks) : (i += 1) try self.writer.writeByte('`');
    }

    /// `info` is the fence's info string; `raw` writes it as djot's raw-block
    /// form (`` ```=html ``) rather than a language (`` ```html ``). The two
    /// are different nodes on the way back in — a raw block spelled as a
    /// language reparses as a `code_block` and gets HTML-escaped.
    fn writeCodeFence(self: *Renderer, ctx: Ctx, info: ?[]const u8, text: []const u8, raw: bool) Writer.Error!void {
        const ticks = fenceTicks(text, 3);
        try self.writePrefix(ctx);
        var i: usize = 0;
        while (i < ticks) : (i += 1) try self.writer.writeByte('`');
        // The info string directly abuts the fence (` ```fig`, not ` ``` fig`) —
        // the canonical form, and a byte-identical round-trip of the usual
        // hand-written spelling. (djot strips a leading space either way.)
        if (raw) try self.writer.writeByte('=');
        if (info) |lang| {
            if (lang.len > 0) try self.writer.writeAll(lang);
        }
        try self.writer.writeByte('\n');
        if (text.len > 0) try self.writer.writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try self.writer.writeByte('\n');
        try self.writePrefix(ctx);
        i = 0;
        while (i < ticks) : (i += 1) try self.writer.writeByte('`');
        try self.writer.writeByte('\n');
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
        // never `- \n  text`), whether the list is tight or loose — djot's
        // (and Markdown's) list-item syntax has no other way to write a
        // paragraph that starts immediately after the marker. Tight lists
        // with exactly that one paragraph stop right there; everything else
        // (a loose list's first paragraph, or any later sibling block) falls
        // through to `renderBlocksFrom`.
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

    fn rowHasAlignment(self: *Renderer, row_id: Node.Id) bool {
        var it = self.ast.children(row_id);
        while (it.next()) |cell| {
            switch (self.ast.nodes[cell.id].kind) {
                .cell => |c| if (c.alignment != .default) return true,
                else => {},
            }
        }
        return false;
    }

    /// `|---|:--|` — the separator line that marks the row above it as a header
    /// and sets the alignment of the columns below it.
    ///
    /// Written without padding spaces (`|---|`, not `| --- |`) because djot.js
    /// — the reference implementation — only recognises dashes that abut the
    /// bar: its `parseTableRow` steps a single byte past the `|` before
    /// matching, so `| --- |` is read as an ordinary data row. The unspaced
    /// spelling is the one every implementation reads back as a separator.
    fn writeTableSeparator(self: *Renderer, row_id: Node.Id, ctx: Ctx) Writer.Error!void {
        if (self.ast.nodes[row_id].first_child == null) return; // `|` alone isn't a row
        try self.writePrefix(ctx);
        try self.writer.writeByte('|');
        var it = self.ast.children(row_id);
        while (it.next()) |cell| {
            const alignment = switch (self.ast.nodes[cell.id].kind) {
                .cell => |c| c.alignment,
                else => .default,
            };
            try self.writer.writeAll(switch (alignment) {
                .default => "---",
                .left => ":--",
                .right => "--:",
                .center => ":-:",
            });
            try self.writer.writeByte('|');
        }
        try self.writer.writeByte('\n');
    }

    fn renderDetachedDefinitions(self: *Renderer) Writer.Error!void {
        var wrote_any = false;
        for (self.ast.nodes) |n| {
            switch (n.kind) {
                .reference => |r| {
                    const in_refs = if (self.doc.references.get(r.label)) |id| id == n.id else false;
                    const in_auto = if (self.doc.auto_references.get(r.label)) |id| id == n.id else false;
                    if (!in_refs and !in_auto) continue;
                    if (wrote_any) try self.writer.writeByte('\n');
                    try self.writer.print("[{s}]: {s}", .{ r.label, r.destination });
                    try self.writeDjotAttrs(n.id);
                    try self.writer.writeByte('\n');
                    wrote_any = true;
                },
                .footnote => |f| {
                    const id = self.doc.footnotes.get(f.label) orelse continue;
                    if (id != n.id) continue;
                    if (wrote_any) try self.writer.writeByte('\n');
                    try self.writer.print("[^{s}]: ", .{f.label});
                    const first = n.first_child;
                    if (first) |_| {
                        var out: Writer.Allocating = .init(self.allocator);
                        defer out.deinit();
                        var inner = Renderer{
                            .allocator = self.allocator,
                            .doc = self.doc,
                            .ast = self.ast,
                            .writer = &out.writer,
                        };
                        try inner.renderBlocks(n.id, .{}, false);
                        const body = std.mem.trimEnd(u8, out.written(), "\n");
                        try self.writer.writeAll(body);
                    }
                    try self.writer.writeByte('\n');
                    wrote_any = true;
                },
                else => {},
            }
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
                try self.writeDjotAttrs(id);
                try self.writer.writeByte('\n');
            },
            .heading => |h| {
                try self.writePrefix(ctx);
                var i: u32 = 0;
                while (i < h.level) : (i += 1) try self.writer.writeByte('#');
                try self.writer.writeByte(' ');
                try self.renderInlineChildren(id, ctx);
                try self.writeDjotAttrs(id);
                try self.writer.writeByte('\n');
            },
            .thematic_break => {
                try self.writePrefix(ctx);
                try self.writer.writeAll("* * *\n");
            },
            .block_quote => {
                const p = Prefix{ .parent = ctx.prefix, .segment = "> " };
                try self.renderBlocks(id, .{ .prefix = &p }, true);
            },
            .container => {
                try self.writePrefix(ctx);
                try self.writer.writeAll(":::");
                if (self.ast.attrsOf(id).entries.len > 0) {
                    try self.writer.writeByte(' ');
                    try self.writeDjotAttrs(id);
                }
                try self.writer.writeByte('\n');
                const p = Prefix{ .parent = ctx.prefix, .segment = "  " };
                try self.renderBlocks(id, .{ .prefix = &p }, true);
                try self.writePrefix(ctx);
                try self.writer.writeAll(":::\n");
            },
            .code_block => |cb| try self.writeCodeFence(ctx, cb.lang, cb.text, false),
            // A formatless raw block has no `=`-form to write, so it falls
            // back to a bare fence rather than emitting an empty `` ```= ``.
            .raw_block => |rb| try self.writeCodeFence(ctx, rb.format, rb.text, rb.format.len > 0),
            .metadata => |m| {
                // Front/end matter: `---<lang>` … `---` (bare `---` for yaml).
                try self.writePrefix(ctx);
                if (std.mem.eql(u8, m.lang, "yaml"))
                    try self.writer.writeAll("---\n")
                else
                    try self.writer.print("---{s}\n", .{m.lang});
                if (m.text.len > 0) try self.writer.writeAll(m.text);
                if (m.text.len == 0 or m.text[m.text.len - 1] != '\n') try self.writer.writeByte('\n');
                try self.writePrefix(ctx);
                try self.writer.writeAll("---\n");
            },
            .bullet_list => |bl| {
                const marker: []const u8 = switch (bl.style) {
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
                    var buf: [32]u8 = undefined;
                    const marker = switch (ol.style.delim) {
                        .period => std.fmt.bufPrint(&buf, "{d}. ", .{n}) catch unreachable,
                        .paren_after => std.fmt.bufPrint(&buf, "{d}) ", .{n}) catch unreachable,
                        .paren_both => std.fmt.bufPrint(&buf, "({d}) ", .{n}) catch unreachable,
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
                    try self.renderListItem(item.id, if (checked) "- [x] " else "- [ ] ", ctx, tl.tight);
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
                // Djot writes the caption as a `^ ` block AFTER the table, so
                // it has to be found before the rows are walked. The parser
                // hoists it to the front of the children and leaves an empty
                // one behind when there is no caption, so an emptied node here
                // means "no caption" rather than "an empty one".
                var caption_id: ?Node.Id = null;
                var cap_it = self.ast.children(id);
                while (cap_it.next()) |child| {
                    if (self.ast.nodes[child.id].kind == .caption and self.ast.nodes[child.id].first_child != null) {
                        caption_id = child.id;
                        break;
                    }
                }
                var row_it = self.ast.children(id);
                var is_first = true;
                while (row_it.next()) |row| {
                    if (self.ast.nodes[row.id].kind == .caption) continue;
                    const head = switch (self.ast.nodes[row.id].kind) {
                        .row => |r| r.head,
                        else => false,
                    };
                    // Alignment on a table that opens with a body row can only
                    // be spelled as a leading separator — one with no row above
                    // it sets the columns for the rows that follow without
                    // making any of them a header.
                    if (is_first and !head and self.rowHasAlignment(row.id))
                        try self.writeTableSeparator(row.id, ctx);
                    is_first = false;
                    try self.writePrefix(ctx);
                    try self.writer.writeByte('|');
                    var cell_it = self.ast.children(row.id);
                    while (cell_it.next()) |cell| {
                        try self.writer.writeByte(' ');
                        try self.renderInlineChildren(cell.id, ctx);
                        try self.writer.writeAll(" |");
                    }
                    try self.writer.writeByte('\n');
                    // Djot has no per-row header marker: a row is a header
                    // because a separator line follows it. Without this the
                    // `head` flag is dropped on the way out and every cell
                    // reparses as a body cell.
                    if (head) try self.writeTableSeparator(row.id, ctx);
                }
                if (caption_id) |cid| {
                    // Directly after the last row, with no blank line between.
                    // A caption opens on `^ ` alone (djot.js gates it on
                    // nothing else), and the blank line the corpus examples
                    // happen to show would have to carry the block prefix to
                    // stay inside a quote or list item — an unprefixed one ends
                    // the container, stranding the caption in a block of its
                    // own.
                    try self.writePrefix(ctx);
                    try self.writer.writeAll("^ ");
                    try self.renderInlineChildren(cid, ctx);
                    try self.writer.writeByte('\n');
                }
            },
            .reference => {},
            .footnote => {},
            .list_item, .task_list_item, .definition_list_item, .term, .definition, .row, .cell, .caption => try self.renderBlocks(id, ctx, false),
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
            // its soft-wrapped lines as one `str`); re-emit the block prefix on
            // each continuation line so it stays inside its container.
            .str => |s| try self.writeInlineText(s, ctx),
            .soft_break => {
                try self.writer.writeByte('\n');
                try self.writePrefix(ctx);
            },
            .hard_break => {
                try self.writer.writeAll("\\\n");
                try self.writePrefix(ctx);
            },
            .non_breaking_space => try self.writer.writeAll("\\ "),
            // One arm, still exhaustive over `TextLeafKind`: an eighth leaf
            // fails THIS build (where delimiters live) and no other.
            .text_leaf => |leaf| switch (leaf.kind) {
                .symb => {
                    const s = leaf.text;
                    try self.writer.print(":{s}:", .{s});
                },
                .verbatim => {
                    const v = leaf.text;
                    try self.writeTickFenced(v);
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
            // Djot spells raw inline content `` `<br>`{=html} ``. Writing the
            // bare text instead loses the raw-ness silently: it reparses as
            // ordinary characters and comes back HTML-escaped. A formatless
            // raw inline has no `{=…}` to write, so it degrades to verbatim.
            .raw_inline => |r| {
                try self.writeTickFenced(r.text);
                if (r.format.len > 0) try self.writer.print("{{={s}}}", .{r.format});
            },
            .smart_punctuation => |sp| try self.writer.writeAll(sp.text),
            // One arm, still exhaustive over `InlineMark`: a tenth mark fails
            // THIS build (where spelling lives) and no other.
            .inline_mark => |m| switch (m) {
                .emph => {
                    try self.writer.writeByte('_');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('_');
                },
                .strong => {
                    try self.writer.writeByte('*');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('*');
                },
                .mark => {
                    try self.writer.writeByte('=');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('=');
                },
                .superscript => {
                    try self.writer.writeByte('^');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('^');
                },
                .subscript => {
                    try self.writer.writeByte('~');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('~');
                },
                .insert => {
                    try self.writer.writeAll("{+");
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeAll("+}");
                },
                .delete => {
                    try self.writer.writeAll("{-");
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeAll("-}");
                },
                .double_quoted => {
                    try self.writer.writeByte('"');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('"');
                },
                .single_quoted => {
                    try self.writer.writeByte('\'');
                    try self.renderInlineChildren(id, ctx);
                    try self.writer.writeByte('\'');
                },
            },
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
            .container => {
                try self.writer.writeByte('[');
                try self.renderInlineChildren(id, ctx);
                try self.writer.writeByte(']');
                try self.writeDjotAttrs(id);
            },
            else => try self.renderInlineChildren(id, ctx),
        }
    }
};

pub fn serialize(allocator: Allocator, doc: *const Document, writer: *Writer) Writer.Error!void {
    var r = Renderer{ .allocator = allocator, .doc = doc, .ast = &doc.ast, .writer = writer };
    try r.renderBlock(doc.ast.root, .{});

    var tail_buf: Writer.Allocating = .init(allocator);
    defer tail_buf.deinit();
    var tail = Renderer{ .allocator = allocator, .doc = doc, .ast = &doc.ast, .writer = &tail_buf.writer };
    try tail.renderDetachedDefinitions();
    const defs = tail_buf.written();
    if (defs.len != 0) {
        if (doc.ast.nodes[doc.ast.root].first_child != null) try writer.writeByte('\n');
        try writer.writeAll(defs);
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
/// DIFFERENT format's parser, for `twig convert -o djot` cross-format
/// conversion) as Djot text. Unlike `serializeAlloc`, there is no `Document`
/// with djot's reference/footnote side tables to consult, so this builds a
/// throwaway one by scanning `ast` directly for `reference`/`footnote`-kind
/// nodes and keying them by their own `.label` payload — the same label ->
/// id shape `Djot.parse` would have produced, just without djot's
/// auto-reference bookkeeping (irrelevant here: `renderDetachedDefinitions`
/// only needs SOME map that contains a definition node to print it, and
/// `references`/`auto_references` are checked with `or`). `ast` itself is
/// only shallow-copied into the temporary `Document` (never `deinit`'d
/// through it) — the caller keeps owning it.
pub fn serializeAstAlloc(allocator: Allocator, ast: *const AST) Allocator.Error![]u8 {
    var references: std.StringHashMapUnmanaged(AST.Node.Id) = .empty;
    defer references.deinit(allocator);
    var footnotes: std.StringHashMapUnmanaged(AST.Node.Id) = .empty;
    defer footnotes.deinit(allocator);

    for (ast.nodes) |n| {
        switch (n.kind) {
            .reference => |r| try references.put(allocator, r.label, n.id),
            .footnote => |f| try footnotes.put(allocator, f.label, n.id),
            else => {},
        }
    }

    const doc: Document = .{ .ast = ast.*, .references = references, .footnotes = footnotes };
    return serializeAlloc(allocator, &doc);
}

const testing = std.testing;

test "serializeAlloc renders basic djot content" {
    var doc = try djot.parse(testing.allocator, "# Title\n\nhello *world*\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# Title") != null);
    try testing.expect(std.mem.indexOf(u8, out, "*world*") != null);
}

test "serializeAlloc: fenced code language abuts the fence, no space" {
    var doc = try djot.parse(testing.allocator, "```fig\nx = 1\n```\n");
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
        var doc = try djot.parse(testing.allocator, "- > q one\n  > q two\n");
        defer doc.deinit();
        const out = try serializeAlloc(testing.allocator, &doc);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "  > q one") != null);
        try testing.expect(std.mem.indexOf(u8, out, ">   q one") == null);
    }
    {
        var doc = try djot.parse(testing.allocator, "> - item one\n> - item two\n");
        defer doc.deinit();
        const out = try serializeAlloc(testing.allocator, &doc);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "> - item one") != null);
    }
}

test "serializeAlloc includes detached reference definitions" {
    var doc = try djot.parse(testing.allocator, "[x][a]\n\n[a]: /u\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "[a]: /u") != null);
}

test "serializeAlloc: a header row is written back with the separator line that makes it one" {
    var doc = try djot.parse(testing.allocator, "|a|b|\n|---|---|\n|c|d|\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("| a | b |\n|---|---|\n| c | d |\n", out);
}

test "serializeAlloc: each header in a multi-header table gets its own separator" {
    // Djot allows a table to switch headers mid-way; every `head` row needs its
    // own separator, not just the first.
    var doc = try djot.parse(testing.allocator, "|a|b|\n|:-|---:|\n|c|d|\n|cc|dd|\n|-:|:-:|\n|e|f|\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "| a | b |\n|:--|--:|\n| c | d |\n| cc | dd |\n|--:|:-:|\n| e | f |\n",
        out,
    );
}

test "serializeAlloc: a table caption is written back after the table" {
    var doc = try djot.parse(testing.allocator, "| a |\n|---|\n\n^ With a _caption_\nand another line.\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("| a |\n|---|\n^ With a _caption_\nand another line.\n", out);
}

test "serializeAlloc: a captionless table gets no stray `^` line" {
    // The parser leaves an empty `caption` child on every table, so emitting
    // one unconditionally would append a bare `^ ` to every table in existence.
    var doc = try djot.parse(testing.allocator, "| a |\n|---|\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("| a |\n|---|\n", out);
}

test "serializeAlloc: a nested table's caption keeps its block prefix" {
    var doc = try djot.parse(testing.allocator, "> | a |\n> |---|\n>\n> ^ Cap\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("> | a |\n> |---|\n> ^ Cap\n", out);

    // The shape matters more than the bytes: an unprefixed line between the
    // table and the `^` would end the quote, leaving the caption in a block
    // quote of its own attached to no table at all — which still LOOKS like
    // reasonable djot, so only the reparse catches it.
    var again = try djot.parse(testing.allocator, out);
    defer again.deinit();
    const rendered = try @import("html.zig").renderAlloc(testing.allocator, &again, .{});
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "<caption>Cap</caption>") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "<blockquote>\n</blockquote>") == null);
}

test "serializeAlloc: a table that opens with a separator keeps its alignment" {
    // No header here — a leading separator sets the columns for the rows below
    // it, and is the only way to spell that alignment in djot.
    var doc = try djot.parse(testing.allocator, "|:--|---:|\n| x | 2 |\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("|:--|--:|\n| x | 2 |\n", out);
}

test "serializeAlloc: raw inline keeps djot's raw spelling, not bare text" {
    var doc = try djot.parse(testing.allocator, "x `<sub>`{=html}y`</sub>`{=html} z\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x `<sub>`{=html}y`</sub>`{=html} z\n", out);
}

test "serializeAlloc: a raw block keeps its `=` form and doesn't decay to a code block" {
    var doc = try djot.parse(testing.allocator, "``` =html\n<hr>\n```\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    // The info string abuts the fence, as it does for a code block's language.
    try testing.expectEqualStrings("```=html\n<hr>\n```\n", out);
}

test "serializeAlloc: backtick-edged verbatim and raw text are space-padded" {
    // Djot strips one space next to a backtick at each end, so content that
    // starts or ends with one must be padded — otherwise the delimiters and the
    // content run together into a single unterminated backtick run.
    {
        var doc = try djot.parse(testing.allocator, "`` ` ``\n");
        defer doc.deinit();
        const out = try serializeAlloc(testing.allocator, &doc);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("`` ` ``\n", out);
    }
    {
        var doc = try djot.parse(testing.allocator, "`` `x` ``{=html}\n");
        defer doc.deinit();
        const out = try serializeAlloc(testing.allocator, &doc);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("`` `x` ``{=html}\n", out);
    }
}

test "serializeAlloc: a loose bullet list's first paragraph starts on the marker's line, not a bare marker + newline" {
    var doc = try djot.parse(testing.allocator, "- one\n  two\n\n- three\n");
    defer doc.deinit();
    const out = try serializeAlloc(testing.allocator, &doc);
    defer testing.allocator.free(out);
    // The soft-wrapped continuation line is indented to align under the list
    // marker (`  two`), a byte-identical round-trip of the input — not dedented
    // to column 0.
    try testing.expect(std.mem.indexOf(u8, out, "- one\n  two\n\n- three\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- \n") == null);
}
