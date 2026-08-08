//! The authoring gestures' tests.
//!
//! These used to live in `c_abi.zig`, driving `TwigEditor*` handles and asserting
//! on `TwigStatus` codes — not because any of it is about the C ABI, but because
//! that was the only door into the logic. Nothing here mentions `extern`, a
//! status code, or a pointer/length pair now; the assertions are the same ones,
//! against a Zig API.
//!
//! ── What these check, and why they check it that way ───────────────────────
//! Mostly: THE REPARSED TREE, not the source bytes. Source that merely looks
//! right can still have ended a link early, leaving the tail as literal text —
//! and `<foo>` and `[foo](foo)` both "look like" a link while reparsing as raw
//! HTML and a link respectively. So the link tests ask what the parser reads back
//! out of the edited source.
//!
//! Djot and Markdown both, nearly everywhere, because their spans differ in
//! exactly the places these gestures read them: Djot starts a quoted block AT its
//! text (`> a` -> para at 2) and a nested quote at its own `>`, Markdown starts
//! both at column 0 — so a rule derived from one format's spans silently breaks
//! on the other.

const std = @import("std");
const testing = std.testing;

const AST = @import("ast.zig");
const Span = @import("../span.zig");
const format = @import("../format.zig");
const editor = @import("editor.zig");
const Editor = editor.Editor;

/// Stable storage for the parse context: the splicer holds `parse_ctx` as an
/// opaque pointer across every reparse, so it must outlive the editor. Tests
/// never vary it, so one file-scope value serves them all.
var test_cfg: format.ParseConfig = .{};

const KindTag = std.meta.Tag(AST.Node.Kind);

const Fixture = struct {
    ed: Editor,

    fn init(source: []const u8, fmt: format.Format) !Fixture {
        const entry = format.entryFor(fmt);
        return .{ .ed = try Editor.init(
            testing.allocator,
            source,
            &test_cfg,
            entry.parseToAst,
            entry.syntax,
        ) };
    }

    fn deinit(self: *Fixture) void {
        self.ed.deinit();
    }

    fn expectSource(self: *Fixture, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.ed.sourceBytes());
    }

    /// The first node of `kind` in the reparsed tree, or null.
    fn find(self: *Fixture, kind: AST.KindRef) ?AST.Node.Id {
        const ast = self.ed.astView();
        for (ast.nodes, 0..) |n, i| {
            if (kind.matches(n.kind)) return @intCast(i);
        }
        return null;
    }

    /// The destination the parser reads back out of the EDITED source — the only
    /// thing that proves an escape worked.
    fn expectLinkDest(self: *Fixture, expected: []const u8) !void {
        const id = self.find(.{ .tag = .link }) orelse return error.NoLink;
        const dest = self.ed.astView().nodes[id].kind.link.destination orelse return error.NoDestination;
        try testing.expectEqualStrings(expected, dest);
    }

    /// The reparsed KIND with its payload (a `link`'s destination, an autolink's
    /// text). Kind is the whole point: `<foo>` and `[foo](foo)` both look like a
    /// link in the source but reparse as raw HTML and a link respectively.
    fn expectSpelled(self: *Fixture, kind: AST.KindRef, payload: []const u8) !void {
        const id = self.find(kind) orelse return error.KindNotFound;
        const got: []const u8 = switch (self.ed.astView().nodes[id].kind) {
            // `link` and `image` carry distinct anonymous payload structs, so
            // they can't share a capture even though the field is the same.
            .link => |l| l.destination orelse return error.NoPayload,
            .image => |i| i.destination orelse return error.NoPayload,
            .str => |t| t,
            .text_leaf => |l| l.text,
            else => return error.NoPayload,
        };
        try testing.expectEqualStrings(payload, got);
    }

    fn expectNoNodeOfKind(self: *Fixture, kind: AST.KindRef) !void {
        if (self.find(kind) != null) return error.UnexpectedKind;
    }

    /// The destination read back off whichever node the op chose to spell —
    /// `link`, `url` or `email`. The round-trip property doesn't care which
    /// spelling landed, only that the destination survived it.
    fn expectDestRoundTrip(self: *Fixture, expected: []const u8) !void {
        const ast = self.ed.astView();
        for (ast.nodes) |n| {
            const got: []const u8 = switch (n.kind) {
                .link => |l| l.destination orelse return error.NoDestination,
                .text_leaf => |l| l.text,
                else => continue,
            };
            try testing.expectEqualStrings(expected, got);
            return;
        }
        return error.NoLinkOfAnyKind;
    }

    /// A `link`'s VISIBLE text: its `str` children joined. Djot splits an escaped
    /// run into several `str` nodes, so a single-child check would miss. Anything
    /// other than a `str` under the text means the destination grew emphasis /
    /// raw HTML / an entity on the way through.
    fn expectLinkText(self: *Fixture, expected: []const u8) !void {
        const ast = self.ed.astView();
        const link = self.find(.{ .tag = .link }) orelse return error.NoLink;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var it = ast.children(link);
        while (it.next()) |child| {
            switch (child.kind) {
                .str => |s| try buf.appendSlice(testing.allocator, s),
                else => return error.TextNotLiteral,
            }
        }
        try testing.expectEqualStrings(expected, buf.items);
    }
};

fn toggleContainer(fx: *Fixture, start: usize, end: usize, kind: Editor.ContainerKind) !void {
    return fx.ed.toggleBlockContainer(Span.init(start, end), kind);
}

fn insertLink(fx: *Fixture, start: usize, end: usize, dest: []const u8) !void {
    return fx.ed.insertLink(Span.init(start, end), dest);
}

fn insertImage(fx: *Fixture, start: usize, end: usize, dest: []const u8) !void {
    return fx.ed.insertImage(Span.init(start, end), dest);
}

fn insertLiteral(fx: *Fixture, offset: usize, text: []const u8) !void {
    return fx.ed.insertLiteral(offset, text);
}

/// The document's VISIBLE text: every `str` payload joined, in node order. If a
/// typed special slipped through as markup, its delimiter would parse into an
/// emphasis/link/raw node instead of a `str`, so the join no longer equals the
/// text that went in — which is exactly the round-trip `insertLiteral` promises.
fn expectVisibleText(fx: *Fixture, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (fx.ed.astView().nodes) |n| switch (n.kind) {
        .str => |s| try buf.appendSlice(testing.allocator, s),
        else => {},
    };
    try testing.expectEqualStrings(expected, buf.items);
}

// ── inline marks ───────────────────────────────────────────────────────────

test "toggleInline: bold on, then off, round-trips in both formats" {
    // The delimiters differ (`**` vs `*`) — the whole reason the table exists.
    var md = try Fixture.init("a word b\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(2, 6), .strong);
    try md.expectSource("a **word** b\n");
    try md.ed.toggleInline(Span.init(4, 8), .strong);
    try md.expectSource("a word b\n");

    var dj = try Fixture.init("a word b\n", .djot);
    defer dj.deinit();
    try dj.ed.toggleInline(Span.init(2, 6), .strong);
    try dj.expectSource("a *word* b\n");
    try dj.ed.toggleInline(Span.init(3, 7), .strong);
    try dj.expectSource("a word b\n");
}

test "toggleInline: a kind the format can't spell is refused, not mis-spelled" {
    // Djot spells `{=mark=}`; Markdown has no mark at all. This is the raggedness
    // `Syntax`'s optional table exists to carry.
    var dj = try Fixture.init("a word b\n", .djot);
    defer dj.deinit();
    try dj.ed.toggleInline(Span.init(2, 6), .mark);
    try dj.expectSource("a {=word=} b\n");

    var md = try Fixture.init("a word b\n", .markdown);
    defer md.deinit();
    try testing.expectError(error.UnsupportedFormat, md.ed.toggleInline(Span.init(2, 6), .mark));
    try md.expectSource("a word b\n");
}

test "toggleInline: a parse-only format spells no inline mark at all" {
    var fx = try Fixture.init("<r>ab</r>", .xml);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.toggleInline(Span.init(3, 5), .strong));
    try testing.expectError(error.UnsupportedFormat, fx.ed.wrapRange(Span.init(3, 5), .emph));
}

test "wrapRange always adds, even over an existing mark" {
    var fx = try Fixture.init("a *word* b\n", .djot);
    defer fx.deinit();
    try fx.ed.wrapRange(Span.init(3, 7), .emph);
    try fx.expectSource("a *_word_* b\n");
}

test "a range past the source is refused before it can reach the splicer's assert" {
    var fx = try Fixture.init("ab\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.InvalidRange, fx.ed.toggleInline(Span.init(0, 99), .strong));
    try testing.expectError(error.InvalidRange, fx.ed.wrapRange(Span.init(2, 1), .strong));
    try testing.expectError(error.InvalidRange, toggleContainer(&fx, 0, 99, .block_quote));
}

// ── block kind ─────────────────────────────────────────────────────────────

test "setBlock: paragraph to heading and back, both formats" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("hello\n", fmt);
        defer fx.deinit();
        try fx.ed.setBlock(0, .heading, 2);
        try fx.expectSource("## hello\n");
        try fx.ed.setBlock(4, .paragraph, 0);
        try fx.expectSource("hello\n");
    }
}

test "setBlock: a setext heading's underline collapses away" {
    // Rebuilding from `content_span` drops the `===` line for free.
    var fx = try Fixture.init("hello\n=====\n", .markdown);
    defer fx.deinit();
    try fx.ed.setBlock(0, .heading, 3);
    try fx.expectSource("### hello\n");
}

test "setBlock: an out-of-range level is refused, and a parse-only format too" {
    var fx = try Fixture.init("hello\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.InvalidLevel, fx.ed.setBlock(0, .heading, 0));
    try testing.expectError(error.InvalidLevel, fx.ed.setBlock(0, .heading, 7));
    try testing.expectError(error.InvalidRange, fx.ed.setBlock(99, .heading, 1));

    var xml = try Fixture.init("<r>ab</r>", .xml);
    defer xml.deinit();
    try testing.expectError(error.UnsupportedFormat, xml.ed.setBlock(3, .heading, 1));
}

// ── block containers ───────────────────────────────────────────────────────

test "toggle_block_container: quote on, then off, round-trips (djot)" {
    var fx = try Fixture.init("a\n", .djot);
    defer fx.deinit();

    try toggleContainer(&fx, 0, 1, .block_quote);
    try fx.expectSource("> a\n");

    // "a" now sits at [2,3); the range covers the whole quote -> toggle off.
    try toggleContainer(&fx, 2, 3, .block_quote);
    try fx.expectSource("a\n");
}

test "toggle_block_container: quote on, then off, round-trips (markdown)" {
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();

    try toggleContainer(&fx, 0, 1, .block_quote);
    try fx.expectSource("> a\n");
    try toggleContainer(&fx, 2, 3, .block_quote);
    try fx.expectSource("a\n");
}

test "toggle_block_container: a multi-block range becomes one quote, blanks marked" {
    var fx = try Fixture.init("a\n\nb\n", .djot);
    defer fx.deinit();

    // The blank line between the paragraphs must carry a `>` too, or the result
    // is two quotes instead of one.
    try toggleContainer(&fx, 0, 4, .block_quote);
    try fx.expectSource("> a\n>\n> b\n");

    try toggleContainer(&fx, 2, 9, .block_quote);
    try fx.expectSource("a\n\nb\n");
}

test "toggle_block_container: quoting inside a quote nests, and off peels one level" {
    var fx = try Fixture.init("> a\n>\n> b\n", .djot);
    defer fx.deinit();

    // Only the first paragraph is selected, so the enclosing quote is NOT fully
    // covered: the toggle nests rather than unquoting `b` along with it.
    try toggleContainer(&fx, 2, 3, .block_quote);
    try fx.expectSource("> > a\n>\n> b\n");

    // "a" is now at [4,5); toggling again peels the inner level only.
    try toggleContainer(&fx, 4, 5, .block_quote);
    try fx.expectSource("> a\n>\n> b\n");
}

test "toggle_block_container: each covered block becomes its own list item" {
    var fx = try Fixture.init("a\n\nb\n", .djot);
    defer fx.deinit();
    try toggleContainer(&fx, 0, 4, .bullet_list);
    try fx.expectSource("- a\n\n- b\n");
}

test "toggle_block_container: an ordered list numbers a multi-item range" {
    var fx = try Fixture.init("a\n\nb\n", .djot);
    defer fx.deinit();
    try toggleContainer(&fx, 0, 4, .ordered_list);
    try fx.expectSource("1. a\n\n2. b\n");
}

test "toggle_block_container: unlisting keeps the items as separate blocks" {
    // A tight `- a\n- b\n` stripped naively is `a\nb\n` — ONE two-line paragraph,
    // not two. The blank line is what preserves the structure.
    var fx = try Fixture.init("- a\n- b\n", .djot);
    defer fx.deinit();
    try toggleContainer(&fx, 2, 7, .bullet_list);
    try fx.expectSource("a\n\nb\n");
}

test "toggle_block_container: toggling the other list kind converts in place" {
    var fx = try Fixture.init("- a\n- b\n", .djot);
    defer fx.deinit();
    try toggleContainer(&fx, 2, 7, .ordered_list);
    try fx.expectSource("1. a\n2. b\n");
}

test "toggle_block_container: a nested quote peels one level (markdown)" {
    var fx = try Fixture.init("> > a\n", .markdown);
    defer fx.deinit();
    try toggleContainer(&fx, 4, 5, .block_quote);
    try fx.expectSource("> a\n");
}

test "toggle_block_container: a list's continuation lines follow the new marker width" {
    var fx = try Fixture.init("- a\n  b\n", .djot);
    defer fx.deinit();
    // `1. ` is a byte wider than `- `, so the second line has to re-indent or it
    // falls out of the item.
    try toggleContainer(&fx, 2, 7, .ordered_list);
    try fx.expectSource("1. a\n   b\n");
}

test "renumberOrderedLists: makes a drifted sequence sequential" {
    // The `1. 2. 2. 3.` a caret editor leaves after inserting an item mid-list.
    var fx = try Fixture.init("1. a\n2. x\n2. b\n3. c\n", .markdown);
    defer fx.deinit();
    try fx.ed.renumberOrderedLists(0);
    try fx.expectSource("1. a\n2. x\n3. b\n4. c\n");
}

test "renumberOrderedLists: each nesting level restarts at 1" {
    var fx = try Fixture.init("1. a\n   5. b\n   9. c\n3. d\n", .markdown);
    defer fx.deinit();
    try fx.ed.renumberOrderedLists(0);
    try fx.expectSource("1. a\n   1. b\n   2. c\n2. d\n");
}

test "renumberOrderedLists: leaves bullets and already-sequential lists alone" {
    var fx = try Fixture.init("- a\n- b\n", .markdown);
    defer fx.deinit();
    // A bullet list at the offset isn't an ordered list: nothing to do.
    try testing.expectError(error.NoBlock, fx.ed.renumberOrderedLists(0));
}

test "renumberOrderedLists: not inside an ordered list is NoBlock" {
    var fx = try Fixture.init("just a paragraph\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.renumberOrderedLists(3));
}

// ── Tables ───────────────────────────────────────────────────────────────────

const table_src = "| a | b |\n| --- | --- |\n| 1 | 2 |\n";

test "tableInsertRow: adds an empty body row below the caret's row" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try fx.ed.tableInsertRow(2, true); // caret in header cell `a`
    try fx.expectSource("| a | b |\n| --- | --- |\n|  |  |\n| 1 | 2 |\n");
}

test "tableDeleteRow: removes the caret's body row" {
    var fx = try Fixture.init("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n", .markdown);
    defer fx.deinit();
    try fx.ed.tableDeleteRow(24); // caret in the `1` cell (first body row)
    try fx.expectSource("| a | b |\n| --- | --- |\n| 3 | 4 |\n");
}

test "tableDeleteRow: refuses the header row" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.tableDeleteRow(2));
}

test "tableInsertColumn: adds an empty column to every row and the delimiter" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try fx.ed.tableInsertColumn(2, true); // right of column `a`
    try fx.expectSource("| a |  | b |\n| --- | --- | --- |\n| 1 |  | 2 |\n");
}

test "tableDeleteColumn: drops the caret's column from every row" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try fx.ed.tableDeleteColumn(6); // caret in column `b`
    try fx.expectSource("| a |\n| --- |\n| 1 |\n");
}

test "tableDeleteColumn: refuses the last column" {
    var fx = try Fixture.init("| a |\n| --- |\n| 1 |\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.tableDeleteColumn(2));
}

test "tableSetAlignment: respells the delimiter for the caret's column" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try fx.ed.tableSetAlignment(6, .center); // column `b`
    try fx.expectSource("| a | b |\n| --- | :---: |\n| 1 | 2 |\n");
}

test "tableMoveColumn: swaps two columns, content and alignment together" {
    var fx = try Fixture.init("| a | b |\n| :--- | ---: |\n| 1 | 2 |\n", .markdown);
    defer fx.deinit();
    try fx.ed.tableMoveColumn(2, true); // move `a` right
    try fx.expectSource("| b | a |\n| ---: | :--- |\n| 2 | 1 |\n");
}

test "tableMoveRow: swaps two body rows" {
    var fx = try Fixture.init("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n", .markdown);
    defer fx.deinit();
    try fx.ed.tableMoveRow(24, true); // move first body row down
    try fx.expectSource("| a | b |\n| --- | --- |\n| 3 | 4 |\n| 1 | 2 |\n");
}

test "table ops off a table are NoBlock" {
    var fx = try Fixture.init("just a paragraph\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.tableInsertRow(3, true));
}

test "insertLineBreak: splices an in-cell <br> that reparses as a hard_break (markdown)" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try fx.ed.insertLineBreak(3); // caret just after `a` in the header cell
    try fx.expectSource("| a<br> | b |\n| --- | --- |\n| 1 | 2 |\n");
    // The point of the whole feature: a semantic break, not opaque raw HTML.
    try testing.expect(fx.find(.{ .tag = .hard_break }) != null);
    try fx.expectNoNodeOfKind(.{ .tag = .raw_inline });
}

test "insertLineBreak: the spliced break round-trips (the source re-serializes byte-for-byte)" {
    var fx = try Fixture.init(table_src, .markdown);
    defer fx.deinit();
    try fx.ed.insertLineBreak(3);
    // A second identical op is refused only by geometry, not spelling; here we
    // just assert the edited source is itself a fixed point of a reparse — the
    // `<br>` the serializer would emit for the hard_break equals what we spliced.
    try fx.expectSource("| a<br> | b |\n| --- | --- |\n| 1 | 2 |\n");
}

test "insertLineBreak: outside a table cell is NoBlock" {
    var fx = try Fixture.init("just a paragraph\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.insertLineBreak(3));
}

test "insertLineBreak: a format with no in-cell break spelling is refused (djot)" {
    // Djot's `cell_line_break` is deliberately null — it has no idiomatic in-cell
    // break, so the gesture is a clean UnsupportedFormat regardless of the caret.
    var fx = try Fixture.init("| a | b |\n| --- | --- |\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertLineBreak(3));
}

test "insertLineBreak: a parse-only format spells no in-cell break (html)" {
    var fx = try Fixture.init("<table><tr><td>a</td></tr></table>\n", .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertLineBreak(15));
}

test "toggle_block_container: a range covering no block is NoBlock" {
    var fx = try Fixture.init("a\n\nb\n", .djot);
    defer fx.deinit();
    // Offset 2 is the blank line between the paragraphs: no block owns it.
    try testing.expectError(error.NoBlock, toggleContainer(&fx, 2, 2, .block_quote));
}

test "toggle_block_container: a `>` inside a code block is not a quote" {
    // The AST has no block_quote here — the `> a` is code_block TEXT. Detection
    // by string-matching the line prefix would "toggle off" a quote that was
    // never there and corrupt the code; the AST walk quotes the block instead.
    var fx = try Fixture.init("```\n> a\n```\n", .djot);
    defer fx.deinit();
    try toggleContainer(&fx, 4, 7, .block_quote);
    try fx.expectSource("> ```\n> > a\n> ```\n");
}

test "toggle_block_container: rejects a format with no line-marker spelling" {
    var fx = try Fixture.init("<r>ab</r>", .xml);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, toggleContainer(&fx, 3, 5, .block_quote));
}

// ── links ──────────────────────────────────────────────────────────────────

test "insert_link wraps a range as link text" {
    var fx = try Fixture.init("a word b\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 2, 6, "http://x.dev");
    try fx.expectSource("a [word](http://x.dev) b\n");
}

// The autolinkable/not split, across both formats. A childless `[](dest)` has no
// text to render or put a caret in, so an empty range spells the destination
// canonically instead — and only the reparsed KIND proves which spelling landed.

test "insert_link: an empty range autolinks an absolute URL (both formats)" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 1, 1, "https://x.dev");
        try fx.expectSource("a<https://x.dev>b\n");
        try fx.expectSpelled(.{ .text_leaf = .url }, "https://x.dev");
        try fx.expectNoNodeOfKind(.{ .tag = .link });
    }
}

test "insert_link: an empty range autolinks a bare email (both formats)" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 1, 1, "a@b.dev");
        try fx.expectSource("a<a@b.dev>b\n");
        try fx.expectSpelled(.{ .text_leaf = .email }, "a@b.dev");
        try fx.expectNoNodeOfKind(.{ .tag = .link });
    }
}

test "insert_link: the formats disagree on what a `mailto:` autolink IS" {
    // Markdown reads `mailto:a@b.dev` as a URI (it has a scheme); djot classifies
    // on content and sees the `@` first. Both autolink it — as different kinds.
    // This is why `autolinkCovering` matches url AND email in both formats.
    var md = try Fixture.init("ab\n", .markdown);
    defer md.deinit();
    try insertLink(&md, 1, 1, "mailto:a@b.dev");
    try md.expectSource("a<mailto:a@b.dev>b\n");
    try md.expectSpelled(.{ .text_leaf = .url }, "mailto:a@b.dev");

    var dj = try Fixture.init("ab\n", .djot);
    defer dj.deinit();
    try insertLink(&dj, 1, 1, "mailto:a@b.dev");
    try dj.expectSource("a<mailto:a@b.dev>b\n");
    try dj.expectSpelled(.{ .text_leaf = .email }, "mailto:a@b.dev");
}

test "insert_link: a bare word is NOT autolinkable — `<foo>` would be raw HTML" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 1, 1, "foo");
        // Falls back to the doubled spelling, destination as text.
        try fx.expectSource("a[foo](foo)b\n");
        try fx.expectLinkDest("foo");
    }
}

test "insert_link: a relative path is NOT autolinkable — it would go literal" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 1, 1, "foo/bar");
        try fx.expectSource("a[foo/bar](foo/bar)b\n");
        try fx.expectLinkDest("foo/bar");
    }
}

test "insert_link: a destination with a space falls back, escaped per format" {
    // `<x dev>` is an autolink in neither format (the space ends the scan), so
    // this lands on `[dest](dest)` — where Markdown still needs its angle form
    // for the destination itself.
    var dj = try Fixture.init("ab\n", .djot);
    defer dj.deinit();
    try insertLink(&dj, 1, 1, "x dev");
    try dj.expectSource("a[x dev](x dev)b\n");
    try dj.expectSpelled(.{ .tag = .link }, "x dev");
    try dj.expectLinkText("x dev");

    var md = try Fixture.init("ab\n", .markdown);
    defer md.deinit();
    try insertLink(&md, 1, 1, "x dev");
    try md.expectSource("a[x dev](<x dev>)b\n");
    try md.expectSpelled(.{ .tag = .link }, "x dev");
    try md.expectLinkText("x dev");
}

test "insert_link: re-pointing a text-less link also gets the canonical spelling" {
    // Keyed on the TEXT being empty, not the range — a `[](old)` left by an
    // older twig has the same childless-link problem a bare caret does.
    var fx = try Fixture.init("a [](old) b\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 3, 3, "https://x.dev");
    try fx.expectSource("a <https://x.dev> b\n");
    try fx.expectSpelled(.{ .text_leaf = .url }, "https://x.dev");
}

test "insert_link: an `email` autolink re-points like a `url` one" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("see <a@b.dev> ok\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 8, 8, "c@d.dev");
        try fx.expectSource("see <c@d.dev> ok\n");
        try fx.expectSpelled(.{ .text_leaf = .email }, "c@d.dev");
    }
}

test "insert_link: a `mailto:` autolink re-points though the formats disagree on its kind" {
    // The node kind is not a property of the destination: djot calls this an
    // `email`, Markdown a `url`. Matching one kind per format would leave the
    // other format's `<mailto:…>` to be corrupted exactly as before.
    var dj = try Fixture.init("see <mailto:a@b.dev> ok\n", .djot);
    defer dj.deinit();
    try insertLink(&dj, 10, 10, "mailto:c@d.dev");
    try dj.expectSource("see <mailto:c@d.dev> ok\n");
    try dj.expectSpelled(.{ .text_leaf = .email }, "mailto:c@d.dev");

    var md = try Fixture.init("see <mailto:a@b.dev> ok\n", .markdown);
    defer md.deinit();
    try insertLink(&md, 10, 10, "mailto:c@d.dev");
    try md.expectSource("see <mailto:c@d.dev> ok\n");
    try md.expectSpelled(.{ .text_leaf = .url }, "mailto:c@d.dev");
}

test "insert_link: an autolink's boundaries read like a link's — start in, end out" {
    // The chain's own half-open rule, so both re-point paths agree: a caret AT
    // `span.start` is inside the node, one at `span.end` belongs to the next
    // sibling and means "a new link here".
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var at_start = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer at_start.deinit();
        try insertLink(&at_start, 4, 4, "https://y.dev");
        try at_start.expectSource("see <https://y.dev> ok\n");

        var at_end = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer at_end.deinit();
        try insertLink(&at_end, 19, 19, "https://y.dev");
        try at_end.expectSource("see <https://x.dev><https://y.dev> ok\n");
    }
}

test "insert_link: a SELECTION over HALF an autolink's URL re-points it, never splices into it" {
    // The repro: selecting the back half of the URL used to splice a link into
    // the middle of it — `see <https://x[.dev](https://y.dev)> ok`. The `<…>`
    // still closes, so that reparsed as ONE `url` whose destination was the
    // garbage in between: the caller's link silently gone, replaced by a URL
    // pointing somewhere nobody asked for, with the autolink intact to hide it.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        // bytes 14..18 are `.dev`, inside the URL.
        var back = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer back.deinit();
        try insertLink(&back, 14, 18, "https://y.dev");
        try back.expectSource("see <https://y.dev> ok\n");

        // …and the front half (`https://x`, 5..14), which mangled the autolink
        // into literal text instead.
        var front = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer front.deinit();
        try insertLink(&front, 5, 14, "https://y.dev");
        try front.expectSource("see <https://y.dev> ok\n");
    }
}

test "insert_link: a SELECTION containing an autolink whole still wraps" {
    // The boundary case of the refusal: this splices at the autolink's EDGES, so
    // nothing is corrupted and the autolink stays as the link's text. The
    // refusal must not swallow ordinary selections that happen to contain a URL.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 0, 22, "https://y.dev");
        try fx.expectSource("[see <https://x.dev> ok](https://y.dev)\n");
    }
}

test "insert_link re-points an existing link instead of nesting one" {
    var fx = try Fixture.init("a [word](old) b\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 3, 7, "new");
    try fx.expectSource("a [word](new) b\n");
    try fx.expectLinkDest("new");
}

test "insert_link: a caret in an autolink re-points it, not its URL text" {
    // Without the autolink path this splices into the middle of the URL:
    // `see <https<https://y.dev>://x.dev> ok`.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 10, 10, "https://y.dev");
        try fx.expectSource("see <https://y.dev> ok\n");
        try fx.expectSpelled(.{ .text_leaf = .url }, "https://y.dev");
    }
}

test "insert_link: re-pointing an autolink RESPELLS it for the new destination" {
    // The new destination isn't autolinkable, so the node has to become a link —
    // a `<foo/bar>` would go literal.
    var fx = try Fixture.init("see <https://x.dev> ok\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 10, 10, "foo/bar");
    try fx.expectSource("see [foo/bar](foo/bar) ok\n");
    try fx.expectLinkDest("foo/bar");
}

test "insert_link: a SELECTION of a whole autolink re-points it, like a caret" {
    var fx = try Fixture.init("see <https://x.dev> ok\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 4, 19, "https://y.dev");
    try fx.expectSource("see <https://y.dev> ok\n");
    try fx.expectSpelled(.{ .text_leaf = .url }, "https://y.dev");
}

test "insert_link: a SELECTION running from text into the middle of a URL is refused" {
    // Not contained, so there is nothing to re-point — half the selection is real
    // text — and no spelling that leaves the URL intact. Both ends are checked:
    // the offset landing inside can be either one, and only `start` is on the
    // caller's own ancestor chain.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        // `[see <https` — ends strictly inside the URL.
        var left = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer left.deinit();
        try testing.expectError(error.NotEditable, insertLink(&left, 0, 10, "https://y.dev"));
        try left.expectSource("see <https://x.dev> ok\n");

        // `.dev> ok` — starts strictly inside the URL.
        var right = try Fixture.init("see <https://x.dev> ok\n", fmt);
        defer right.deinit();
        try testing.expectError(error.NotEditable, insertLink(&right, 14, 22, "https://y.dev"));
        try right.expectSource("see <https://x.dev> ok\n");
    }
}

test "insert_link: a caret in an autolink INSIDE a link re-points the link" {
    // A link's text is separable from its destination, so re-pointing it keeps
    // text that re-pointing the autolink would discard.
    var fx = try Fixture.init("a [<https://x.dev>](d) b\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 10, 10, "new");
    try fx.expectLinkDest("new");
    // The autolink survives as the link's text.
    try fx.expectSpelled(.{ .text_leaf = .url }, "https://x.dev");
}

// The escaping tests. Each asserts on the DESTINATION THE PARSER READS BACK, not
// the bytes: an unescaped `)` ends the link early and leaves the tail as literal
// text, which source-only assertions cheerfully miss.

test "insert_link escapes parens so the destination survives (djot)" {
    var fx = try Fixture.init("ab\n", .djot);
    defer fx.deinit();
    try insertLink(&fx, 0, 2, "http://x.dev/a(b)c");
    try fx.expectLinkDest("http://x.dev/a(b)c");
}

test "insert_link escapes parens so the destination survives (markdown)" {
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try insertLink(&fx, 0, 2, "http://x.dev/a(b)c");
    try fx.expectLinkDest("http://x.dev/a(b)c");
}

test "insert_link carries whitespace per format: djot literal, markdown angled" {
    // Markdown ends a destination at the first space, so it must move into the
    // `<…>` form. Djot gives `<…>` no meaning there, so wrapping would corrupt
    // the URL — it escapes in place instead. Same input, two right answers.
    var md = try Fixture.init("ab\n", .markdown);
    defer md.deinit();
    try insertLink(&md, 0, 2, "a b");
    try md.expectSource("[ab](<a b>)\n");
    try md.expectLinkDest("a b");

    var dj = try Fixture.init("ab\n", .djot);
    defer dj.deinit();
    try insertLink(&dj, 0, 2, "a b");
    try dj.expectLinkDest("a b");
}

test "insert_link escapes the angle form's own delimiters (markdown)" {
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try insertLink(&fx, 0, 2, "a <b> c");
    try fx.expectLinkDest("a <b> c");
}

test "insert_link handles whitespace and a paren together (markdown)" {
    // Inside the angle form the parens need NO escape — the destination ends at
    // the `>` — so escaping them there would put a literal backslash in the URL.
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try insertLink(&fx, 0, 2, "a (b) c");
    try fx.expectLinkDest("a (b) c");
}

test "insert_link escapes the non-paren bytes that also end a destination" {
    // Markdown reads a `<` as the START of the angle form even mid-destination;
    // djot's destination is still scanned for inline openers, so a `[` or a
    // backtick there swallows the `)`.
    var md = try Fixture.init("ab\n", .markdown);
    defer md.deinit();
    try insertLink(&md, 0, 2, "http://x.dev/a<b");
    try md.expectLinkDest("http://x.dev/a<b");

    var dj = try Fixture.init("ab\n", .djot);
    defer dj.deinit();
    try insertLink(&dj, 0, 2, "http://x.dev/a[b`c");
    try dj.expectLinkDest("http://x.dev/a[b`c");
}

test "insert_link escapes an entity so markdown can't decode the destination" {
    // `a&amp;b` handed in would come back out as `a&b` — corrupting the URL
    // rather than breaking the link, the quieter of the two failures. Djot has no
    // entities and leaves `&` alone.
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try insertLink(&fx, 0, 2, "http://x.dev/?a=1&amp;b=2");
    try fx.expectLinkDest("http://x.dev/?a=1&amp;b=2");
}

test "insert_link round-trips a backslash in the destination" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 0, 2, "http://x.dev/a\\b");
        try fx.expectLinkDest("http://x.dev/a\\b");
    }
}

test "insert_link: the doubled destination is escaped for the TEXT position too" {
    // `dest` repurposed as text needs the TEXT alphabet, not the destination one
    // — an unescaped `*` there would open emphasis and eat the link's text.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try insertLink(&fx, 1, 1, "a*b*c");
        try fx.expectLinkDest("a*b*c");
        try fx.expectLinkText("a*b*c");
    }
}

test "insert_link: an empty range round-trips any destination, both formats" {
    // The property both escape sets exist to hold: whichever spelling the op
    // picks, the destination the parser reads back is the one handed in. Every
    // ASCII metacharacter either format has an opinion about is in here.
    const dests = [_][]const u8{
        "https://x.dev",  "mailto:a@b.dev",   "a@b.dev", "foo",
        "./rel/path.md",  "x dev",            "a)b(c",   "a[b",
        "a`b",            "a<b",              "a>b",     "#anchor",
        "../up.md",       "path/to/f (1).md", "a\\b",    "a{b}c",
        "a*b*c",          "a_b_c",            "a]b",     "a&amp;b",
        "a b)c",          "a~b",              "a^b",     "a\"b",
        "a'b",            "a--b",             "a...b",   "a:b",
        "a$b",            "a!b",              "a|b",     "a%20b",
        "a b<c>d",        "a=b+c",            "https://x.dev?a=1&b=2#f",
    };
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        for (dests) |d| {
            var fx = try Fixture.init("ab\n", fmt);
            defer fx.deinit();
            try insertLink(&fx, 1, 1, d);
            fx.expectDestRoundTrip(d) catch |err| {
                std.debug.print("\nfmt={s} dest=\"{s}\": {s}\n", .{ @tagName(fmt), d, @errorName(err) });
                return err;
            };
        }
    }
}

test "insert_link rejects a newline in the destination and an unspellable format" {
    var fx = try Fixture.init("ab\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.InvalidDestination, insertLink(&fx, 0, 2, "a\nb"));
    try testing.expectError(error.InvalidDestination, insertLink(&fx, 0, 2, "a\rb"));
    try fx.expectSource("ab\n");

    var xml = try Fixture.init("<r>ab</r>", .xml);
    defer xml.deinit();
    try testing.expectError(error.UnsupportedFormat, insertLink(&xml, 3, 5, "http://x.dev"));
}

// ── images ─────────────────────────────────────────────────────────────────
// An image destination is the same grammar production as a link's, so these
// mirror the link-destination cases above. The point of the op existing at all is
// that a caller cannot spell them: the correct answer differs per format, and
// getting it wrong yields text rather than an image.

test "insert_image spells an image with the selection as alt text" {
    var fx = try Fixture.init("a word b\n", .djot);
    defer fx.deinit();
    try insertImage(&fx, 2, 6, "cat.png");
    try fx.expectSource("a ![word](cat.png) b\n");
    try fx.expectSpelled(.{ .tag = .image }, "cat.png");
}

test "insert_image: an empty range is a perfectly good image" {
    // Unlike a link, where `[](dest)` has nothing to click and `insert_link`
    // therefore spells an autolink instead.
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try insertImage(&fx, 1, 1, "cat.png");
    try fx.expectSource("a![](cat.png)b\n");
    try fx.expectSpelled(.{ .tag = .image }, "cat.png");
}

test "insert_image: whitespace in the destination takes the format's spelling" {
    // The bug this op exists to make impossible. Markdown ends a destination at
    // the first space, so `![](my cat.png)` is not an image at all; djot gives
    // `<…>` no meaning, so wrapping there would point at the literal characters.
    var md = try Fixture.init("w\n", .markdown);
    defer md.deinit();
    try insertImage(&md, 0, 1, "my cat.png");
    try md.expectSource("![w](<my cat.png>)\n");
    try md.expectSpelled(.{ .tag = .image }, "my cat.png");

    var dj = try Fixture.init("w\n", .djot);
    defer dj.deinit();
    try insertImage(&dj, 0, 1, "my cat.png");
    try dj.expectSource("![w](my cat.png)\n");
    try dj.expectSpelled(.{ .tag = .image }, "my cat.png");
}

test "insert_image: a paren in the destination is escaped, not left to close early" {
    var fx = try Fixture.init("w\n", .djot);
    defer fx.deinit();
    try insertImage(&fx, 0, 1, "a)b.png");
    try fx.expectSource("![w](a\\)b.png)\n");
    try fx.expectSpelled(.{ .tag = .image }, "a)b.png");
}

test "insert_image refuses a newline destination and a parse-only format" {
    var fx = try Fixture.init("ab\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.InvalidDestination, insertImage(&fx, 0, 2, "a\nb.png"));
    try testing.expectError(error.InvalidDestination, insertImage(&fx, 0, 2, "a\rb.png"));
    try fx.expectSource("ab\n");

    var xml = try Fixture.init("<r>ab</r>", .xml);
    defer xml.deinit();
    try testing.expectError(error.UnsupportedFormat, insertImage(&xml, 3, 5, "cat.png"));
}

// ── literal text ─────────────────────────────────────────────────────────────
// The assertions read the REPARSED tree (via `expectVisibleText`), not the
// spelled source: source that merely holds a `\*` still has to prove it reparses
// to a literal `*` and not to emphasis. Both formats, because their inline
// alphabets diverge in exactly the bytes these escape.

test "insert_literal: typed markdown specials all stay literal" {
    var fx = try Fixture.init("z\n", .markdown);
    defer fx.deinit();
    // Balanced emphasis, a code span, a full link, raw HTML and an entity — every
    // one would mint markup unescaped.
    const typed = "*b* _i_ `c` [t](u) <x> &amp;";
    try insertLiteral(&fx, 0, typed);
    try expectVisibleText(&fx, typed ++ "z");
    for ([_]AST.KindRef{ .{ .mark = .emph }, .{ .mark = .strong }, .{ .text_leaf = .verbatim }, .{ .tag = .link }, .{ .tag = .image }, .{ .tag = .raw_inline } }) |k|
        try fx.expectNoNodeOfKind(k);
}

test "insert_literal: typed djot specials all stay literal" {
    var fx = try Fixture.init("z\n", .djot);
    defer fx.deinit();
    // Djot's own marks plus its attribute braces and smart punctuation.
    const typed = "*b* _i_ `c` ^s^ ~t~ {=m=} \"q\" ...";
    try insertLiteral(&fx, 0, typed);
    try expectVisibleText(&fx, typed ++ "z");
    for ([_]AST.KindRef{ .{ .mark = .emph }, .{ .mark = .strong }, .{ .text_leaf = .verbatim }, .{ .mark = .superscript }, .{ .mark = .subscript }, .{ .mark = .mark } }) |k|
        try fx.expectNoNodeOfKind(k);
}

test "insert_literal: a block marker escapes at a line start, in both formats" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("z\n", fmt);
        defer fx.deinit();
        try insertLiteral(&fx, 0, "# ");
        try fx.expectSource("\\# z\n");
        try fx.expectNoNodeOfKind(.{ .tag = .heading });
    }
}

test "insert_literal: the same marker mid-line is ordinary text, left unescaped" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("az\n", fmt);
        defer fx.deinit();
        try insertLiteral(&fx, 1, "# ");
        // No backslash: a `#` after other text on the line opens nothing.
        try fx.expectSource("a# z\n");
        try fx.expectNoNodeOfKind(.{ .tag = .heading });
    }
}

test "insert_literal: leading whitespace still counts as a line start" {
    // Markdown lets up to three spaces precede a block marker, so an insertion
    // sitting in that indent is still at a line start.
    var fx = try Fixture.init("  z\n", .markdown);
    defer fx.deinit();
    try insertLiteral(&fx, 2, "# ");
    try fx.expectSource("  \\# z\n");
    try fx.expectNoNodeOfKind(.{ .tag = .heading });
}

test "insert_literal: an embedded newline re-enters the line-start zone" {
    var fx = try Fixture.init("z\n", .markdown);
    defer fx.deinit();
    // The first `#` is mid-line (after "a"); the second opens its own line.
    try insertLiteral(&fx, 0, "a # b\n# c");
    try fx.expectSource("a # b\n\\# cz\n");
    try fx.expectNoNodeOfKind(.{ .tag = .heading });
}

test "insert_literal: a lone backslash round-trips as a backslash" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("z\n", fmt);
        defer fx.deinit();
        try insertLiteral(&fx, 0, "a\\b");
        try fx.expectSource("a\\\\bz\n");
        try expectVisibleText(&fx, "a\\bz");
    }
}

test "insert_literal: a parse-only format spells no literal" {
    for ([_]format.Format{ .xml, .html }) |fmt| {
        var fx = try Fixture.init("<r>ab</r>", fmt);
        defer fx.deinit();
        try testing.expectError(error.UnsupportedFormat, insertLiteral(&fx, 3, "x"));
    }
}

test "insert_literal: an offset past the source is InvalidRange" {
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.InvalidRange, insertLiteral(&fx, 99, "x"));
    try fx.expectSource("ab\n");
}

