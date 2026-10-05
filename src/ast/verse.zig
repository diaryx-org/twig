//! Verse — read a div classed `verse` as the `line_block` it spells.
//!
//! Markdown and djot have no verse construct of their own, and both already
//! carry a fenced div with a class: Markdown's `<div class="verse">` under
//! `html_elements`, djot's `::: verse`. This pass is what makes that div MEAN
//! verse: a div whose class names `verse` and whose children are all
//! paragraphs is rewritten, in place, into the `line_block` AsciiDoc's
//! `[verse]` and rST's `| ` already parse to, so every consumer — an editor
//! drawing lines, a serializer, a converter — sees one node and never has to
//! know which spelling it came from.
//!
//! ── The reading ────────────────────────────────────────────────────────────
//!   * Each paragraph is a STANZA. Every break inside it — hard (`\`, two
//!     spaces) or soft (a plain newline) — ends a `line`, because in verse a
//!     line break is the content: a poet who types one newline meant one.
//!   * Between two paragraphs an EMPTY `line` is the stanza break, which is
//!     what `line_block` already says an empty line is (see `AST-KINDS.md`).
//!   * A line's leading EM SPACES (U+2003, written raw or as `&emsp;`,
//!     `&#8195;`, `&#x2003;`) are its `indent`, one step each, and are taken
//!     out of its text. An em space, because CommonMark and djot both strip a
//!     paragraph line's leading ASCII spaces and keep every other character —
//!     so it is the one indentation either format hands back.
//!   * `verse` leaves the div's class; any other class and attribute stays on
//!     the `line_block`, so `<div class="verse center">` is a centred verse.
//!
//! A div that holds anything but paragraphs — a heading, a list — is left a
//! div: a verse is lines, and a structure inside it is not one.
//!
//! ── Mechanics ──────────────────────────────────────────────────────────────
//! Runs on a raw parse, BEFORE `compact.zig`. The div's node is rewritten to
//! `line_block` (keeping its id, span and interior), the `line` nodes are
//! appended to the arena, and a line's first `str` is replaced by a trimmed
//! copy when its indent is taken off. The paragraphs and break nodes it no
//! longer reaches are left unattached, which is exactly the garbage
//! compaction exists to sweep.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Node = AST.Node;
const Span = @import("../span.zig");
const Document = @import("../document.zig");

/// The class token that makes a div a verse.
pub const class_token = "verse";

/// U+2003 EM SPACE — one step of a verse line's indent.
pub const em_space = "\u{2003}";

/// Every source spelling of one em space a Markdown or djot inline parser
/// decodes to `em_space`, longest first so a prefix never shadows a longer one.
const em_space_spellings = [_][]const u8{ "&#x2003;", "&#X2003;", "&#8195;", "&emsp;", em_space };

/// Rewrite every verse div in `doc` into a `line_block`. Consumes `doc` and
/// returns the rewritten document; a document with no verse div comes back
/// with no allocation beyond the scan.
pub fn run(allocator: Allocator, doc: Document) Allocator.Error!Document {
    const original_len = doc.ast.nodes.len;
    var first: ?Node.Id = null;
    for (0..original_len) |i| {
        if (isVerseDiv(&doc, @intCast(i))) {
            first = @intCast(i);
            break;
        }
    }
    const start = first orelse return doc;

    var w: Rewriter = try .init(allocator, doc);
    errdefer w.deinit();
    for (start..original_len) |i| {
        const id: Node.Id = @intCast(i);
        if (!isVerseDiv(&w.doc, id)) continue;
        try w.rewrite(id);
    }
    return w.finish();
}

/// Whether `id` is a fenced div, classed `verse`, whose children are one or
/// more paragraphs and nothing else.
fn isVerseDiv(doc: *const Document, id: Node.Id) bool {
    const node = doc.ast.nodes[id];
    const c = switch (node.kind) {
        .container => |c| c,
        else => return false,
    };
    if (c.form != .block_fenced) return false;
    if (c.name.len != 0 and !std.mem.eql(u8, c.name, "div")) return false;
    if (c.text != null) return false;
    const class = doc.ast.attrsOf(id).get("class") orelse return false;
    if (!hasToken(class, class_token)) return false;
    var child = node.first_child orelse return false;
    while (true) {
        if (doc.ast.nodes[child].kind != .para) return false;
        child = doc.ast.nodes[child].next_sibling orelse return true;
    }
}

fn hasToken(list: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |t| if (std.mem.eql(u8, t, token)) return true;
    return false;
}

/// The arena and its parallel tables, made growable for the rewrite and
/// frozen back into a `Document` at the end.
const Rewriter = struct {
    allocator: Allocator,
    doc: Document,
    nodes: std.ArrayList(Node),
    spans: std.ArrayList(Span),
    content_spans: std.ArrayList(?Span),
    owned_strings: std.ArrayList([]const u8),
    lines: std.ArrayList(Node.Id) = .empty,
    kids: std.ArrayList(Node.Id) = .empty,
    /// The tables `doc` arrived with, freed once the copies replace them.
    original_nodes: []const Node,
    original_spans: []const Span,
    original_content_spans: []const ?Span,
    original_owned: []const []const u8,

    fn init(allocator: Allocator, doc: Document) Allocator.Error!Rewriter {
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(allocator);
        try nodes.appendSlice(allocator, doc.ast.nodes);
        var spans: std.ArrayList(Span) = .empty;
        errdefer spans.deinit(allocator);
        try spans.appendSlice(allocator, doc.node_spans);
        var content_spans: std.ArrayList(?Span) = .empty;
        errdefer content_spans.deinit(allocator);
        try content_spans.appendSlice(allocator, doc.node_content_spans);
        var owned: std.ArrayList([]const u8) = .empty;
        errdefer owned.deinit(allocator);
        try owned.appendSlice(allocator, doc.ast.owned_strings);
        var w: Rewriter = .{
            .allocator = allocator,
            .doc = doc,
            .nodes = nodes,
            .spans = spans,
            .content_spans = content_spans,
            .owned_strings = owned,
            .original_nodes = doc.ast.nodes,
            .original_spans = doc.node_spans,
            .original_content_spans = doc.node_content_spans,
            .original_owned = doc.ast.owned_strings,
        };
        // Reads during the rewrite go through `doc`, so point it at the
        // growable copies from the start.
        w.sync();
        return w;
    }

    /// Free the growable copies only — `doc`'s own tables are still the
    /// caller's until `finish` swaps them.
    fn deinit(self: *Rewriter) void {
        self.nodes.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.content_spans.deinit(self.allocator);
        self.owned_strings.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.kids.deinit(self.allocator);
    }

    /// Point `doc`'s views at the current copies, so `ast.nodes[id]`,
    /// `span(id)` and `attrsOf(id)` read what has been written so far.
    fn sync(self: *Rewriter) void {
        self.doc.ast.nodes = self.nodes.items;
        self.doc.node_spans = self.spans.items;
        self.doc.node_content_spans = self.content_spans.items;
    }

    fn addNode(self: *Rewriter, kind: Node.Kind, span: Span) Allocator.Error!Node.Id {
        const id: Node.Id = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .id = id, .kind = kind });
        try self.spans.append(self.allocator, span);
        try self.content_spans.append(self.allocator, null);
        self.sync();
        return id;
    }

    fn setChildren(self: *Rewriter, parent: Node.Id, ids: []const Node.Id) void {
        self.nodes.items[parent].first_child = if (ids.len == 0) null else ids[0];
        if (ids.len == 0) return;
        for (ids[0 .. ids.len - 1], ids[1..]) |cur, nxt| self.nodes.items[cur].next_sibling = nxt;
        self.nodes.items[ids[ids.len - 1]].next_sibling = null;
    }

    fn rewrite(self: *Rewriter, div: Node.Id) Allocator.Error!void {
        self.lines.clearRetainingCapacity();
        const src = self.doc.source;
        var prev_para: ?Node.Id = null;
        var para_it = self.nodes.items[div].first_child;
        while (para_it) |para| : (para_it = self.nodes.items[para].next_sibling) {
            if (prev_para) |p| {
                // The stanza break, placed on the blank line between the two
                // paragraphs: just past the newline that ends the first's last
                // line. Measured from that line rather than the paragraph,
                // whose span djot runs past its own newline.
                const end = if (self.lines.items.len != 0)
                    self.spans.items[self.lines.items[self.lines.items.len - 1]].end
                else
                    self.spans.items[p].end;
                const next_start = self.spans.items[para].start;
                const nl = std.mem.indexOfScalarPos(u8, src, end, '\n') orelse end;
                const at = @min(@max(nl + 1, end), @max(next_start, end));
                try self.lines.append(self.allocator, try self.addNode(.{ .line = .{} }, Span.init(at, at)));
            }
            prev_para = para;

            self.kids.clearRetainingCapacity();
            var child = self.nodes.items[para].first_child;
            while (child) |c| : (child = self.nodes.items[c].next_sibling) {
                switch (self.nodes.items[c].kind) {
                    .soft_break, .hard_break => {
                        try self.closeLine();
                    },
                    else => try self.kids.append(self.allocator, c),
                }
            }
            try self.closeLine();
        }

        // The div becomes the block: same id, span and interior, so a caret
        // inside it and every offset around it still point where they did.
        self.nodes.items[div].kind = .line_block;
        self.setChildren(div, self.lines.items);
        if (div < self.doc.node_spelling.len) @constCast(self.doc.node_spelling)[div] = null;
        try self.dropClassToken(div);
    }

    /// End the line `kids` holds, taking its indent off its first text.
    fn closeLine(self: *Rewriter) Allocator.Error!void {
        defer self.kids.clearRetainingCapacity();
        if (self.kids.items.len == 0) return;
        const src = self.doc.source;
        const line_start = self.spans.items[self.kids.items[0]].start;
        const line_end = self.spans.items[self.kids.items[self.kids.items.len - 1]].end;

        // The indent is counted in the DECODED text and located in the
        // source: `&emsp;` is one step and six bytes.
        var indent: u32 = 0;
        var src_pos = line_start;
        while (self.kids.items.len > 0) {
            const first = self.kids.items[0];
            const text = switch (self.nodes.items[first].kind) {
                .str => |s| s,
                else => break,
            };
            var n: usize = 0;
            while (std.mem.startsWith(u8, text[n * em_space.len ..], em_space)) n += 1;
            if (n == 0) break;
            var advanced: usize = 0;
            var pos = src_pos;
            while (advanced < n) : (advanced += 1) {
                const step = spellingAt(src, pos) orelse break;
                pos += step;
            }
            if (advanced != n) break; // the source disagrees; leave it alone
            indent += @intCast(n);
            src_pos = pos;
            const rest = text[n * em_space.len ..];
            if (rest.len == 0) {
                _ = self.kids.orderedRemove(0);
                continue;
            }
            // A trimmed copy: `rest` borrows the original's owned bytes,
            // which live as long as the AST does.
            const trimmed = try self.addNode(.{ .str = rest }, Span.init(src_pos, self.spans.items[first].end));
            self.kids.items[0] = trimmed;
            break;
        }

        const id = try self.addNode(.{ .line = .{ .indent = indent } }, Span.init(line_start, @max(line_start, line_end)));
        self.setChildren(id, self.kids.items);
        try self.lines.append(self.allocator, id);
    }

    /// Take `verse` out of `div`'s class, dropping the class (and the whole
    /// attribute set) when nothing else is left.
    fn dropClassToken(self: *Rewriter, div: Node.Id) Allocator.Error!void {
        const aid = self.nodes.items[div].attrs orelse return;
        const attrs = self.doc.ast.attrs[aid];
        var entries: std.ArrayList(AST.KeyVal) = .empty;
        defer entries.deinit(self.allocator);
        for (attrs.entries) |kv| {
            if (!std.mem.eql(u8, kv.key, "class") or kv.value == null) {
                try entries.append(self.allocator, kv);
                continue;
            }
            var rest: std.ArrayList(u8) = .empty;
            defer rest.deinit(self.allocator);
            var it = std.mem.tokenizeAny(u8, kv.value.?, " \t\r\n\x0c");
            while (it.next()) |t| {
                if (std.mem.eql(u8, t, class_token)) continue;
                if (rest.items.len != 0) try rest.append(self.allocator, ' ');
                try rest.appendSlice(self.allocator, t);
            }
            if (rest.items.len == 0) continue;
            const owned = try self.allocator.dupe(u8, rest.items);
            errdefer self.allocator.free(owned);
            try self.owned_strings.append(self.allocator, owned);
            try entries.append(self.allocator, .{ .key = kv.key, .value = owned });
        }
        const new_entries = try entries.toOwnedSlice(self.allocator);
        self.allocator.free(attrs.entries);
        @constCast(self.doc.ast.attrs)[aid] = .{ .entries = new_entries };
        if (new_entries.len == 0) self.nodes.items[div].attrs = null;
    }

    /// Freeze the copies back into the document, freeing the tables they
    /// replace.
    fn finish(self: *Rewriter) Allocator.Error!Document {
        var out = self.doc;
        const nodes = try self.nodes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(nodes);
        const spans = try self.spans.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(spans);
        const content_spans = try self.content_spans.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(content_spans);
        const owned = try self.owned_strings.toOwnedSlice(self.allocator);
        self.lines.deinit(self.allocator);
        self.kids.deinit(self.allocator);
        self.allocator.free(self.original_nodes);
        self.allocator.free(self.original_spans);
        self.allocator.free(self.original_content_spans);
        self.allocator.free(self.original_owned);
        out.ast.nodes = nodes;
        out.node_spans = spans;
        out.node_content_spans = content_spans;
        out.ast.owned_strings = owned;
        return out;
    }
};

/// The byte length of the em-space spelling `src` holds at `pos`, or `null`.
fn spellingAt(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len) return null;
    for (em_space_spellings) |s| {
        if (std.mem.startsWith(u8, src[pos..], s)) return s.len;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────
// The languages are imported inside the test bodies, as `splicer.zig` does,
// so a non-test build of this file carries no dependency on them.

const testing = std.testing;

fn lineTexts(doc: *const Document, block: Node.Id, out: *std.ArrayList([]const u8)) !void {
    var it = doc.ast.children(block);
    while (it.next()) |line| {
        const kids = doc.ast.nodes[line.id].first_child;
        if (kids == null) {
            try out.append(testing.allocator, "");
            continue;
        }
        const first = kids.?;
        const last = blk: {
            var l = first;
            while (doc.ast.nodes[l].next_sibling) |n| l = n;
            break :blk l;
        };
        try out.append(testing.allocator, doc.source[doc.span(first).start..doc.span(last).end]);
    }
}

test "Markdown: a verse div's every line break is a line, and a blank line a stanza" {
    const markdown = @import("../languages/markdown/markdown.zig");
    const src = "<div class=\"verse\">\n\nOne line\nsoft-broken\\\nhard-broken\n\nstanza two\n\n</div>\n";
    var doc = try markdown.parse(testing.allocator, src, .{ .html_elements = true });
    defer doc.deinit();
    const block = doc.ast.nodes[doc.ast.root].first_child.?;
    try testing.expect(doc.ast.nodes[block].kind == .line_block);
    // The class was `verse` alone, so the block carries no attributes at all.
    try testing.expect(doc.ast.attrsOf(block).isEmpty());
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(testing.allocator);
    try lineTexts(&doc, block, &texts);
    try testing.expectEqual(@as(usize, 5), texts.items.len);
    try testing.expectEqualStrings("One line", texts.items[0]);
    try testing.expectEqualStrings("soft-broken", texts.items[1]);
    try testing.expectEqualStrings("hard-broken", texts.items[2]);
    try testing.expectEqualStrings("", texts.items[3]);
    try testing.expectEqualStrings("stanza two", texts.items[4]);
    // The stanza break sits on the blank line between the two paragraphs.
    var it = doc.ast.children(block);
    var gap: Node.Id = undefined;
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == 3) gap = line.id;
    }
    try testing.expectEqual(std.mem.indexOf(u8, src, "\n\nstanza").? + 1, doc.span(gap).start);
}

test "Markdown: em spaces are the indent, raw or as an entity, and leave the text" {
    const markdown = @import("../languages/markdown/markdown.zig");
    const src = "<div class=\"verse center\">\n\nzero\n\u{2003}one\n&emsp;&#8195;two\n\n</div>\n";
    var doc = try markdown.parse(testing.allocator, src, .{ .html_elements = true });
    defer doc.deinit();
    const block = doc.ast.nodes[doc.ast.root].first_child.?;
    try testing.expect(doc.ast.nodes[block].kind == .line_block);
    try testing.expectEqualStrings("center", doc.ast.attrsOf(block).get("class").?);
    var it = doc.ast.children(block);
    const want_indent = [_]u32{ 0, 1, 2 };
    const want_text = [_][]const u8{ "zero", "one", "two" };
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        try testing.expectEqual(want_indent[i], doc.ast.nodes[line.id].kind.line.indent);
        const str = doc.ast.nodes[line.id].first_child.?;
        try testing.expectEqualStrings(want_text[i], doc.ast.nodes[str].kind.str);
        // The span still addresses the true source: the text, not its indent.
        try testing.expectEqualStrings(want_text[i], src[doc.span(str).start..doc.span(str).end]);
        // And the line's own span starts at the margin, indent included.
        try testing.expect(std.mem.startsWith(u8, src[doc.span(line.id).start..], if (i == 2) "&emsp;" else if (i == 1) "\u{2003}" else "zero"));
    }
    try testing.expectEqual(@as(usize, 3), i);
}

test "Markdown: a div holding more than paragraphs, or without html_elements, is not a verse" {
    const markdown = @import("../languages/markdown/markdown.zig");
    const mixed = "<div class=\"verse\">\n\n# A heading\n\nA line\n\n</div>\n";
    var doc = try markdown.parse(testing.allocator, mixed, .{ .html_elements = true });
    defer doc.deinit();
    const block = doc.ast.nodes[doc.ast.root].first_child.?;
    try testing.expect(doc.ast.nodes[block].kind == .container);
    try testing.expectEqualStrings("verse", doc.ast.attrsOf(block).get("class").?);

    const plain = "<div class=\"verse\">\n\nA line\n\n</div>\n";
    var raw = try markdown.parse(testing.allocator, plain, .commonmark);
    defer raw.deinit();
    for (raw.ast.nodes) |node| try testing.expect(node.kind != .line_block);
}

test "djot: a `::: verse` div is a line block, its other classes kept" {
    const djot = @import("../languages/djot/djot.zig");
    const src = "{.center}\n::: verse\nOne\\\n\u{2003}two\n\nthree\n:::\n";
    var doc = try djot.parse(testing.allocator, src);
    defer doc.deinit();
    const block = doc.ast.nodes[doc.ast.root].first_child.?;
    try testing.expect(doc.ast.nodes[block].kind == .line_block);
    try testing.expectEqualStrings("center", doc.ast.attrsOf(block).get("class").?);
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(testing.allocator);
    try lineTexts(&doc, block, &texts);
    try testing.expectEqual(@as(usize, 4), texts.items.len);
    try testing.expectEqualStrings("One", texts.items[0]);
    try testing.expectEqualStrings("two", texts.items[1]);
    try testing.expectEqualStrings("", texts.items[2]);
    try testing.expectEqualStrings("three", texts.items[3]);
}

test "the rewrite leaves nothing behind for compaction to miss" {
    const markdown = @import("../languages/markdown/markdown.zig");
    const src = "<div class=\"verse\">\n\na\nb\n\nc\n\n</div>\n";
    var doc = try markdown.parse(testing.allocator, src, .{ .html_elements = true });
    defer doc.deinit();
    // Every node in the arena is reachable from the root: the paragraphs and
    // breaks the pass abandoned were swept.
    var seen = try testing.allocator.alloc(bool, doc.ast.nodes.len);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(Node.Id) = .empty;
    defer stack.deinit(testing.allocator);
    try stack.append(testing.allocator, doc.ast.root);
    while (stack.pop()) |id| {
        seen[id] = true;
        var it = doc.ast.children(id);
        while (it.next()) |c| try stack.append(testing.allocator, c.id);
    }
    for (seen) |s| try testing.expect(s);
    for (doc.ast.nodes) |node| {
        try testing.expect(node.kind != .para);
        try testing.expect(node.kind != .soft_break);
    }
}
