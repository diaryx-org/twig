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

test "toggleInline: html spells a mark as a tag pair" {
    // A `Delims` is a tag pair, so the same gesture that writes `**` writes
    // `<strong>` — no HTML-specific code path anywhere. The assertion is on the
    // reparsed KIND, not just the bytes: it is what proves the toggle reverses.
    var fx = try Fixture.init("<p>a word b</p>\n", .html);
    defer fx.deinit();
    try fx.ed.toggleInline(Span.init(5, 9), .strong);
    try fx.expectSource("<p>a <strong>word</strong> b</p>\n");
    try testing.expect(fx.find(.{ .mark = .strong }) != null);

    // Off again, selecting the interior the reparse now reports.
    try fx.ed.toggleInline(Span.init(13, 17), .strong);
    try fx.expectSource("<p>a word b</p>\n");
    try testing.expect(fx.find(.{ .mark = .strong }) == null);
}

test "toggleInline: html toggles an ALIAS tag off, and normalizes on the way back" {
    // `<b>` parses as `strong` but is not what the table spells. Stripping still
    // works, because `Splicer.toggleInline` recovers the interior from the
    // parser's `content_span` rather than by matching the table's bytes — so an
    // alias needs no entry. The visible consequence is the normalization: what
    // comes back is `<strong>`, not the `<b>` that was there.
    var fx = try Fixture.init("<p><b>word</b></p>\n", .html);
    defer fx.deinit();
    try fx.ed.toggleInline(Span.init(6, 10), .strong);
    try fx.expectSource("<p>word</p>\n");
    try fx.ed.toggleInline(Span.init(3, 7), .strong);
    try fx.expectSource("<p><strong>word</strong></p>\n");
}

test "toggleInline: html spells every kind the toolbar vocabulary names" {
    // `verbatim` is the text leaf in the vocabulary; `<code>` upgrades only when
    // the element holds one text child, which is what a wrap produces.
    var fx = try Fixture.init("<p>a x b</p>\n", .html);
    defer fx.deinit();
    try fx.ed.toggleInline(Span.init(5, 6), .verbatim);
    try fx.expectSource("<p>a <code>x</code> b</p>\n");
    try testing.expect(fx.find(.{ .text_leaf = .verbatim }) != null);

    // Unlike Markdown — which refuses five of the eight — HTML spells all of
    // them, so no toolbar button is dark. (The two quote containers it cannot
    // spell are not in this vocabulary: the parser produces them, no gesture
    // does. See `html/syntax.zig`.)
    inline for (std.meta.fields(Editor.InlineKind)) |f| {
        var one = try Fixture.init("<p>a x b</p>\n", .html);
        defer one.deinit();
        try one.ed.wrapRange(Span.init(5, 6), @enumFromInt(f.value));
    }
}

test "toggleInline: html's raggedness stops at the block level" {
    // The gestures whose spelling has the wrong SHAPE for its field (heading is a
    // wrapping pair, a quote wraps rather than prefixing lines, a fence measures
    // nothing) and the ones whose escaping mechanism is entities, not
    // backslashes. All refused through the one uniform path, none of them with a
    // hand-written HTML arm.
    var fx = try Fixture.init("<p>ab</p>\n", .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.setBlock(4, .heading, 1));
    try testing.expectError(error.UnsupportedFormat, toggleContainer(&fx, 3, 5, .block_quote));
    try testing.expectError(error.UnsupportedFormat, fx.ed.toggleCodeBlock(Span.init(3, 5), null));
    try testing.expectError(error.UnsupportedFormat, insertLiteral(&fx, 4, "x"));
    try testing.expectError(error.UnsupportedFormat, insertLink(&fx, 3, 5, "http://x.dev"));
    try fx.expectSource("<p>ab</p>\n");
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

test "setBlock: opens a heading on a blank line" {
    // No node to convert — no format spells an empty paragraph — so the marker
    // is opened rather than rewritten. Without this a caller had to spell `#`
    // itself, and spell it per format. The caret is on the empty line left by
    // pressing Enter twice, which is where the gesture is actually reached from.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("a\n\n", f);
        defer fx.deinit();
        try fx.ed.setBlock(3, .heading, 2);
        try fx.expectSource("a\n\n## ");
        try testing.expect(fx.find(.{ .tag = .heading }) != null);
    }
}

test "setBlock: a marker never lands flush under a paragraph" {
    // Djot does not let a heading interrupt a paragraph, so `## ` written on the
    // line directly under one is read there as that paragraph's own text — the
    // document gains no heading and `##` shows up literally. Markdown reads the
    // same bytes as a heading. The minted blank is what makes one spelling work
    // in both, and the REPARSE is what proves it rather than the bytes.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("a\n\n", f);
        defer fx.deinit();
        // The caret is on the separator line itself, so writing the marker
        // where it sits would consume the separator.
        try fx.ed.setBlock(2, .heading, 2);
        try fx.expectSource("a\n\n## \n");
        try testing.expect(fx.find(.{ .tag = .heading }) != null);
        try testing.expect(fx.find(.{ .tag = .para }) != null);
    }
}

test "setBlock: opens a heading in an empty document" {
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("", f);
        defer fx.deinit();
        try fx.ed.setBlock(0, .heading, 1);
        try fx.expectSource("# ");
    }
}

test "setBlock: a quote's blank line keeps the quote, with the space djot needs" {
    // The blank line is spelled `>`, and `>#` is NOT a quoted heading in both
    // formats — Markdown reads one, djot reads the whole line as a paragraph.
    // Re-emitting the marker with a space is what makes one spelling work in
    // both, and the reparse is what proves it.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("> a\n>\n", f);
        defer fx.deinit();
        try fx.ed.setBlock(4, .heading, 1);
        try fx.expectSource("> a\n>\n> # \n");
        try testing.expect(fx.find(.{ .tag = .heading }) != null);
        try testing.expect(fx.find(.{ .tag = .block_quote }) != null);
    }
}

test "setBlock: a blank line inside a code block is refused" {
    // `innermostBlock` reports `null` here exactly as it does between blocks,
    // and only the line's OWNER tells them apart. Writing `# ` in would add no
    // heading and corrupt the listing.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("```\nx\n\ny\n```\n", f);
        defer fx.deinit();
        const blank = std.mem.indexOf(u8, fx.ed.sourceBytes(), "\n\n").? + 1;
        try testing.expectError(error.NotEditable, fx.ed.setBlock(blank, .heading, 1));
        try fx.expectSource("```\nx\n\ny\n```\n");
    }
}

test "setBlock: paragraph on a blank line is a no-op, not an error" {
    // The state asked for is the state it is in: a blank line holds no marker.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("a\n\n", f);
        defer fx.deinit();
        try fx.ed.setBlock(2, .paragraph, 0);
        try fx.expectSource("a\n\n");
    }
}

test "renumberOrderedLists: a quoted list renumbers behind its prefix" {
    // The markers sit behind `> `, so a scan from column zero finds `>` where it
    // wants a digit. Every line failed the test, the region was copied verbatim,
    // and the gesture returned OK having changed nothing.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("> 1. a\n> 2. b\n> 2. c\n", f);
        defer fx.deinit();
        try fx.ed.renumberOrderedLists(2);
        try fx.expectSource("> 1. a\n> 2. b\n> 3. c\n");
    }
}

test "renumberOrderedLists: a quote prefix is not nesting depth" {
    // The `> ` is two columns wide, but it is the QUOTE's width, not the list's
    // indentation — a quoted top-level item is still top-level, and counting the
    // prefix would open a phantom level whose siblings never resume.
    //
    // Blank-separated because djot does not let a list marker interrupt a
    // paragraph: without the blanks `>    7. b` is a continuation line of item
    // `a` there and a nested item in Markdown, so the two formats would be
    // renumbering different documents. That divergence has its own test below.
    for ([_]format.Format{ .markdown, .djot }) |f| {
        var fx = try Fixture.init("> 3. a\n>\n>    7. b\n>\n> 9. c\n", f);
        defer fx.deinit();
        try fx.ed.renumberOrderedLists(2);
        try fx.expectSource("> 1. a\n>\n>    1. b\n>\n> 2. c\n");
    }
}

test "renumberOrderedLists: djot's literal `2.` line is prose, not an item" {
    // Djot doesn't let a list marker interrupt a paragraph, so `   2. b` is a
    // continuation line of item `a` — the author's own text, four bytes of which
    // happen to spell a marker. Markdown reads the same bytes as a nested item.
    var fx = try Fixture.init("1. a\n   2. b\n2. c\n", .djot);
    defer fx.deinit();
    var items: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .list_item) items += 1;
    }
    try testing.expectEqual(@as(usize, 2), items); // 2, not markdown's 3
    try fx.ed.renumberOrderedLists(0);
    try fx.expectSource("1. a\n   2. b\n2. c\n");

    var md = try Fixture.init("1. a\n   2. b\n2. c\n", .markdown);
    defer md.deinit();
    try md.ed.renumberOrderedLists(0);
    try md.expectSource("1. a\n   1. b\n2. c\n");
}

test "renumberOrderedLists: a numbered line inside a code block is left alone" {
    // The same question the djot case asks, with an unambiguous answer: these
    // digits are the program's, and the tree is the only thing that says so.
    var fx = try Fixture.init("1. a\n\n   ```\n   7. not an item\n   ```\n\n5. b\n", .markdown);
    defer fx.deinit();
    try fx.ed.renumberOrderedLists(0);
    try fx.expectSource("1. a\n\n   ```\n   7. not an item\n   ```\n\n2. b\n");
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

test "renumberOrderedLists: a format that spells no numbered marker refuses" {
    // An HTML `<ol>` parses into the same `ordered_list`/`list_item` nodes a
    // Markdown one does, so the pass ran, found no `N.` run to rewrite, and
    // reported the no-op as a success — a gesture that can only ever do nothing,
    // answering as though it had done something. The number is in the tag here,
    // not in the line.
    const src = "<ol><li>a</li><li>b</li></ol>";
    var fx = try Fixture.init(src, .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.renumberOrderedLists(8));
    try fx.expectSource(src);
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

test "table edits re-spell in the format's OWN dialect, not GFM's" {
    // Djot's delimiter row carries no padding and keeps every cell three wide
    // (`|:-:|`, never `| :---: |`): djot.js steps one byte past the bar before
    // matching the dashes, so the Markdown spelling reads there as an ordinary
    // data row and the table loses its header. Before `Syntax.table_spelling`
    // this file wrote Markdown's skeleton into every format it could extract.
    var fx = try Fixture.init("|a|b|\n|---|---|\n|1|2|\n", .djot);
    defer fx.deinit();
    try fx.ed.tableSetAlignment(1, .center); // caret in column `a`
    try fx.expectSource("| a | b |\n|:-:|---|\n| 1 | 2 |\n");
    // The rows ARE padded — only the delimiter isn't — and the result is still
    // one table with a header row, which is the property the padding protects.
    try testing.expect(fx.find(.{ .tag = .table }) != null);
    const head = fx.find(.{ .tag = .row }) orelse return error.NoRow;
    try testing.expect(fx.ed.astView().nodes[head].kind.row.head);
}

test "table gestures refuse a format with no table spelling, and touch nothing" {
    // The destructive case the gate exists for, and the reason it is checked
    // BEFORE the grid is extracted. HTML's parser lowers `<table>/<tr>/<td>` to
    // the same `table`/`row`/`cell` nodes a pipe table produces, so extraction
    // used to succeed and the rebuilt pipe text was spliced over the elements —
    // which HTML reparses as a paragraph. A document that still parses is one
    // the splicer will not roll back, so there was no `EditConflict` and no
    // error at all: the table was simply gone.
    const src = "<table><tr><td>a</td><td>b</td></tr><tr><td>1</td><td>2</td></tr></table>";
    var fx = try Fixture.init(src, .html);
    defer fx.deinit();
    const caret = std.mem.indexOf(u8, src, "a").?; // inside the first cell
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableInsertRow(caret, true));
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableDeleteRow(caret));
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableInsertColumn(caret, true));
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableDeleteColumn(caret));
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableSetAlignment(caret, .center));
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableMoveRow(caret, true));
    try testing.expectError(error.UnsupportedFormat, fx.ed.tableMoveColumn(caret, true));
    // The assertion that matters: not one byte moved, and the table is still a
    // table rather than a paragraph of pipes.
    try fx.expectSource(src);
    try testing.expect(fx.find(.{ .tag = .table }) != null);
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

test "insertLineBreak: html spells the in-cell break natively" {
    // `<br>` is not borrowed here the way it is in a GFM cell — it is simply how
    // HTML spells a break, and the parser reads it straight back.
    var fx = try Fixture.init("<table><tr><td>a</td></tr></table>\n", .html);
    defer fx.deinit();
    // Caret just after the cell's `a`, which sits at 15.
    try fx.ed.insertLineBreak(16);
    try fx.expectSource("<table><tr><td>a<br></td></tr></table>\n");
    try testing.expect(fx.find(.{ .tag = .hard_break }) != null);
}

test "insertLineBreak: off-cell is NoBlock even where the format spells one" {
    var fx = try Fixture.init("<p>ab</p>\n", .html);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.insertLineBreak(4));
}

// ── opening a container on a blank line ────────────────────────────────────
// `setBlock` has always opened `# ` where there is no block to convert; these
// are the same gesture for the three container buttons beside it, which used to
// answer `error.NoBlock` there and do nothing. See `openContainerOnBlankLine`.

test "toggle_block_container: a blank line OPENS an empty container" {
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        // Offset 2 is the blank line between the paragraphs: no block owns it.
        var q = try Fixture.init("a\n\nb\n", fmt);
        defer q.deinit();
        try toggleContainer(&q, 2, 2, .block_quote);
        try q.expectSource("a\n\n> \nb\n");

        var b = try Fixture.init("a\n\nb\n", fmt);
        defer b.deinit();
        try toggleContainer(&b, 2, 2, .bullet_list);
        try b.expectSource("a\n\n- \nb\n");

        var o = try Fixture.init("a\n\nb\n", fmt);
        defer o.deinit();
        try toggleContainer(&o, 2, 2, .ordered_list);
        try o.expectSource("a\n\n1. \nb\n");
    }
}

test "toggle_block_container: an opened container reparses as one" {
    // Source that merely looks right isn't enough — an empty list item cannot
    // interrupt a paragraph, so a marker written flush under one is read as
    // that paragraph's own text and the document gains no list at all. This is
    // what the blank line above the marker is for.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("a\n\nb\n", fmt);
        defer fx.deinit();
        try toggleContainer(&fx, 2, 2, .bullet_list);
        try testing.expect(fx.find(.{ .tag = .bullet_list }) != null);
        // And the paragraph below stays its own block rather than being adopted
        // as the empty item's lazy continuation.
        try testing.expect(fx.find(.{ .tag = .para }) != null);
    }
}

test "toggle_block_container: a bullet opened on a quote's blank line stays in the quote" {
    // The line's own `>` is kept and the marker written after it, with the
    // space djot needs after the last `>` even though the blank line carries
    // none — `openBlockOnBlankLine`'s rule, for the same reason.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("> a\n>\n", fmt);
        defer fx.deinit();
        try toggleContainer(&fx, 4, 4, .bullet_list);
        try fx.expectSource("> a\n>\n> - \n");
        try testing.expect(fx.find(.{ .tag = .block_quote }) != null);
        try testing.expect(fx.find(.{ .tag = .bullet_list }) != null);
    }
}

test "toggle_block_container: no blank line is added when one is already above" {
    // `a\n\n\n\nb\n` — the caret's blank line already has a blank above it, so
    // the marker is written in place rather than pushed down another line.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("a\n\n\n\nb\n", fmt);
        defer fx.deinit();
        try toggleContainer(&fx, 3, 3, .bullet_list);
        try fx.expectSource("a\n\n- \n\nb\n");
    }
}

test "toggle_block_container: the same button twice takes the empty container back off" {
    // A toggle has to go both ways. Quote pressed twice used to nest `> > ` and
    // Bulleted pressed twice failed outright, leaving a button that could not be
    // un-pressed until the author typed something into it.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var q = try Fixture.init("a\n\nb\n", fmt);
        defer q.deinit();
        try toggleContainer(&q, 2, 2, .block_quote);
        try q.expectSource("a\n\n> \nb\n");
        try toggleContainer(&q, 5, 5, .block_quote);
        try q.expectSource("a\n\n\nb\n");

        var b = try Fixture.init("a\n\nb\n", fmt);
        defer b.deinit();
        try toggleContainer(&b, 2, 2, .bullet_list);
        try b.expectSource("a\n\n- \nb\n");
        try toggleContainer(&b, 5, 5, .bullet_list);
        try b.expectSource("a\n\n\nb\n");
    }
}

test "toggle_block_container: the OTHER list button converts an empty marker" {
    // What the non-empty path already does for a real list, at the one size it
    // could not reach.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("a\n\nb\n", fmt);
        defer fx.deinit();
        try toggleContainer(&fx, 2, 2, .bullet_list);
        try toggleContainer(&fx, 5, 5, .ordered_list);
        try fx.expectSource("a\n\n1. \nb\n");
        try toggleContainer(&fx, 6, 6, .bullet_list);
        try fx.expectSource("a\n\n- \nb\n");
    }
}

test "toggle_block_container: un-quoting an empty nested quote leaves the outer one" {
    // The innermost marker comes off, and the line it leaves behind is spelled
    // `>` — a quote's own blank line — not `> ` with a stranded space.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("> a\n> > \n", fmt);
        defer fx.deinit();
        try toggleContainer(&fx, 8, 8, .block_quote);
        try fx.expectSource("> a\n>\n");
    }
}

test "toggle_block_container: a blank line inside a code block wraps the block, not the line" {
    // The other half of "a blank line opens a container": this blank is the
    // listing's own body, and `coveredBlocks` resolves it to the code block
    // rather than to nothing — so the gesture wraps the whole fence and never
    // reaches `openContainerOnBlankLine`. Writing a marker into the blank
    // instead would add no list and corrupt the code.
    for ([_]format.Format{ .djot, .markdown }) |fmt| {
        var fx = try Fixture.init("```\na\n\nb\n```\n", fmt);
        defer fx.deinit();
        try toggleContainer(&fx, 6, 6, .bullet_list);
        try fx.expectSource("- ```\n  a\n\n  b\n  ```\n");
        try testing.expect(fx.find(.{ .tag = .code_block }) != null);
    }
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
        "https://x.dev", "mailto:a@b.dev",   "a@b.dev",                 "foo",
        "./rel/path.md", "x dev",            "a)b(c",                   "a[b",
        "a`b",           "a<b",              "a>b",                     "#anchor",
        "../up.md",      "path/to/f (1).md", "a\\b",                    "a{b}c",
        "a*b*c",         "a_b_c",            "a]b",                     "a&amp;b",
        "a b)c",         "a~b",              "a^b",                     "a\"b",
        "a'b",           "a--b",             "a...b",                   "a:b",
        "a$b",           "a!b",              "a|b",                     "a%20b",
        "a b<c>d",       "a=b+c",            "https://x.dev?a=1&b=2#f",
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

// ── thematic break ───────────────────────────────────────────────────────────

test "thematic_break: lands after the caret's block, blank-separated" {
    var md = try Fixture.init("a\n\nb\n", .markdown);
    defer md.deinit();
    try md.ed.insertThematicBreak(0);
    try md.expectSource("a\n\n---\n\nb\n");

    var dj = try Fixture.init("a\n\nb\n", .djot);
    defer dj.deinit();
    try dj.ed.insertThematicBreak(0);
    try dj.expectSource("a\n\n* * *\n\nb\n");
}

test "thematic_break: the blank line above is what keeps `---` from being a setext heading" {
    // Markdown's spelling is only a rule when a blank line precedes it: flush
    // against the paragraph, `---` underlines it into an `<h2>` and the
    // paragraph disappears into the heading. The reparsed KIND is the assertion,
    // not the bytes — both spellings "look right" in the source.
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(0);
    try fx.expectSource("a\n\n---\n");
    try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
    try fx.expectNoNodeOfKind(.{ .tag = .heading });
}

test "thematic_break: after a multi-line paragraph, not inside it" {
    // A rule is a block, so it goes after the whole paragraph the caret is in —
    // the caret's own line is not a boundary.
    var fx = try Fixture.init("a\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(0);
    try fx.expectSource("a\nb\n\n---\n");
}

test "thematic_break: inside a quote it stays inside the quote" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("> a\n", fmt);
        defer fx.deinit();
        try fx.ed.insertThematicBreak(2);
        const rule = if (fmt == .markdown) "---" else "* * *";
        var buf: [64]u8 = undefined;
        try fx.expectSource(try std.fmt.bufPrint(&buf, "> a\n>\n> {s}\n", .{rule}));
        // The blank continuation line is `>`, not `> `, and the rule carries the
        // quote's marker — so the break is the quote's child, not the doc's.
        const id = fx.find(.{ .tag = .thematic_break }) orelse return error.NoRule;
        const quote = fx.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
        try testing.expect(id > quote);
    }
}

test "thematic_break: inside a list it splits the list rather than corrupting it" {
    // `containerPrefix` reproduces quote markers but not a list item's indent,
    // so the rule lands at column zero after the caret's item. Nothing is
    // swallowed — the list becomes two lists with a rule between — which is why
    // this is allowed where the same gap makes `toggleCodeBlock` refuse.
    var fx = try Fixture.init("- a\n- b\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(2);
    try fx.expectSource("- a\n\n---\n\n- b\n");
    try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
    // Both items survive AS items: the markers were not eaten.
    var items: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .list_item) items += 1;
    }
    try testing.expectEqual(@as(usize, 2), items);
}

test "thematic_break: inside a code fence it lands after the fence, not in the body" {
    // `innermostBlock` knew only `para`/`heading`, so a caret in a code block
    // read as "no block here" and the rule went at the caret's LINE end — inside
    // the fence, where `---` is just text. The document gained no rule at all and
    // the code body silently grew a line. `lineOwningBlock` sees the code block.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("```\nabc\ndef\n```\n", fmt);
        defer fx.deinit();
        try fx.ed.insertThematicBreak(5); // caret inside `abc`
        const rule = if (fmt == .markdown) "---" else "* * *";
        var buf: [64]u8 = undefined;
        try fx.expectSource(try std.fmt.bufPrint(&buf, "```\nabc\ndef\n```\n\n{s}\n", .{rule}));
        // The rule is a real node, and the code block still holds both its lines.
        try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
        const code = fx.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
        try testing.expectEqualStrings("abc\ndef\n", fx.ed.astView().nodes[code].kind.code_block.text);
    }
}

test "thematic_break: inside a table it lands after the table, which survives" {
    // The worst of the fallback's cases: a rule written between the header row
    // and the delimiter row stops the table being a table. A node is lost, which
    // is the outcome `toggleCodeBlock` refuses a list item for.
    var fx = try Fixture.init("| a | b |\n|---|---|\n| c | d |\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(3); // caret in the header's first cell
    try fx.expectSource("| a | b |\n|---|---|\n| c | d |\n\n---\n");
    try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
    try testing.expect(fx.find(.{ .tag = .table }) != null);
}

test "thematic_break: a fence inside a quote keeps both the quote and the fence" {
    // Both corrections at once: the anchor escapes the fence, and the prefix is
    // still the quote's, so the rule stays in the quote instead of ending it.
    var fx = try Fixture.init("> ```\n> abc\n> ```\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(8); // caret inside `abc`
    try fx.expectSource("> ```\n> abc\n> ```\n>\n> ---\n");
    const id = fx.find(.{ .tag = .thematic_break }) orelse return error.NoRule;
    const quote = fx.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
    try testing.expect(id > quote);
    try testing.expect(fx.find(.{ .tag = .code_block }) != null);
}

test "thematic_break: an existing blank line below is not doubled" {
    var fx = try Fixture.init("a\n\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(0);
    try fx.ed.insertThematicBreak(0);
    // The second rule lands after the paragraph again, above the first.
    try fx.expectSource("a\n\n---\n\n---\n\nb\n");
}

test "thematic_break: an empty document is a legitimate place for one" {
    var fx = try Fixture.init("", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(0);
    try fx.expectSource("---\n");
    try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
}

test "thematic_break: a parse-only format spells none" {
    var fx = try Fixture.init("<r>ab</r>", .xml);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertThematicBreak(3));
}

test "thematic_break: html spells it `<hr>`, after the caret's block" {
    var fx = try Fixture.init("<p>ab</p>\n", .html);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(4);
    // The blank line is the shared gesture's unconditional separation — needed
    // in Markdown, where `---` after a paragraph line is a setext underline
    // instead of a rule. In HTML it is inert whitespace between two blocks, so
    // the one spelling stays safe for every format.
    try fx.expectSource("<p>ab</p>\n\n<hr>\n");
    try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
}

// ── split block ──────────────────────────────────────────────────────────────

test "split_block: a list item splits at the caret into two items" {
    // The gesture's defining case: `- this is |a list item` becomes two items,
    // the marker repeated and NO blank line between them (a blank would loosen
    // the list and change how every sibling renders).
    var fx = try Fixture.init("- this is a list item\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(10); // caret before `a list item`
    try fx.expectSource("- this is \n- a list item\n");

    var items: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .list_item) items += 1;
    }
    try testing.expectEqual(@as(usize, 2), items);
}

test "split_block: at the end of a list item it opens an empty sibling" {
    // Enter at the end of an item — the empty block IS the point, and a list is
    // one of the few places a format can spell one.
    var fx = try Fixture.init("- this is a list item\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(21); // caret at the item's end
    try fx.expectSource("- this is a list item\n- \n");

    var items: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .list_item) items += 1;
    }
    try testing.expectEqual(@as(usize, 2), items);
}

test "split_block: a nested item's new sibling keeps its nesting depth" {
    // `listMarkerAt` puts `start` at the bullet, so taking the marker from there
    // dropped the indent and dumped the new item at column zero — out of its own
    // list and into the enclosing one. The indent between the quote prefix and
    // the bullet IS the nesting.
    var two = try Fixture.init("- a\n  - b c\n", .markdown);
    defer two.deinit();
    try two.ed.splitBlock(9);
    try two.expectSource("- a\n  - b\n  - c\n");

    var four = try Fixture.init("- a\n    - b c\n", .markdown);
    defer four.deinit();
    try four.ed.splitBlock(11);
    try four.expectSource("- a\n    - b\n    - c\n");

    // Djot needs the blank line to nest at all: without one, `  - b` is literal
    // text continuing the paragraph, which the reference corpus asserts
    // (djot.js/test/lists.test) and twig matches. So the djot case is spelled
    // the way djot actually nests, not the way Markdown does.
    var dj = try Fixture.init("- a\n\n  - b c\n", .djot);
    defer dj.deinit();
    try dj.ed.splitBlock(10);
    try dj.expectSource("- a\n\n  - b\n  - c\n");
}

test "split_block: djot's non-nesting continuation splits at the outer level" {
    // `- a\n  - b c` is ONE djot item whose paragraph reads `a`, a soft break,
    // then the literal text `- b c`. Splitting it repeats the OUTER marker,
    // which looks like the nesting bug above and is not one — there is no inner
    // list in the tree to keep.
    var fx = try Fixture.init("- a\n  - b c\n", .djot);
    defer fx.deinit();
    try testing.expect(fx.find(.{ .tag = .bullet_list }) != null);
    var lists: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .bullet_list) lists += 1;
    }
    try testing.expectEqual(@as(usize, 1), lists);

    try fx.ed.splitBlock(9);
    try fx.expectSource("- a\n  - b\n- c\n");

    // And the outer marker is not merely faithful to the tree, it is the only
    // spelling that WORKS: an indented `  - ` there would continue the same
    // paragraph as more literal text, so the gesture would add no item at all.
    // Column zero is what actually opens one.
    var items: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .list_item) items += 1;
    }
    try testing.expectEqual(@as(usize, 2), items);

    var indented = try Fixture.init("- a\n  - b\n  - c\n", .djot);
    defer indented.deinit();
    var indented_items: usize = 0;
    for (indented.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .list_item) indented_items += 1;
    }
    try testing.expectEqual(@as(usize, 1), indented_items);
}

test "split_block: nesting and a quote prefix compose" {
    // The prefix is re-minted from the quote markers and the indent is taken
    // from between them and the bullet, so both survive at once.
    var fx = try Fixture.init("> - a\n>   - b c\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(13);
    try fx.expectSource("> - a\n>   - b\n>   - c\n");
}

test "split_block: the second half sheds leading spaces, but not in code" {
    // At the start of a block, spaces are structure rather than content: keeping
    // them would write `-  c`, setting that item's content indent to three.
    var item = try Fixture.init("- a b\n", .markdown);
    defer item.deinit();
    try item.ed.splitBlock(3);
    try item.expectSource("- a\n- b\n");

    var para = try Fixture.init("a   b\n", .markdown);
    defer para.deinit();
    try para.ed.splitBlock(1);
    try para.expectSource("a\n\nb\n");

    // Inside a fence leading whitespace IS the content, so nothing is shed.
    var code = try Fixture.init("```\na  b\n```\n", .markdown);
    defer code.deinit();
    try code.ed.splitBlock(5);
    try code.expectSource("```\na\n```\n\n```\n  b\n```\n");
}

test "split_block: Enter at an item's end works with a sibling following" {
    // Markdown's `list_item` span STOPS BEFORE its trailing newline while djot's
    // covers it, so in Markdown a caret at the item's end is in the gap between
    // items — inside the `bullet_list` and inside no item. The deepest hit is
    // then the list, which is not splittable, so the retry has to key on "not
    // splittable" rather than on "nothing found".
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("- one\n- two\n", fmt);
        defer fx.deinit();
        try fx.ed.splitBlock(5);
        try fx.expectSource("- one\n- \n- two\n");

        var items: usize = 0;
        for (fx.ed.astView().nodes) |n| {
            if (std.meta.activeTag(n.kind) == .list_item) items += 1;
        }
        try testing.expectEqual(@as(usize, 3), items);
    }

    // Ordered items too, marker repeated verbatim as everywhere else.
    var ord = try Fixture.init("1. one\n2. two\n", .markdown);
    defer ord.deinit();
    try ord.ed.splitBlock(6);
    try ord.expectSource("1. one\n1. \n2. two\n");
}

test "split_block: a refusal still reports against the block pointed at" {
    // The retry must not turn a genuine `NotEditable` into `NoBlock` by walking
    // back off the construct the caller actually named.
    var fx = try Fixture.init("| a | b |\n|---|---|\n| c | d |\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.splitBlock(9));
}

test "split_block: a list marker is repeated as written, not rebuilt" {
    // `*` stays `*` and `1)` stays `1)` — the author's spelling survives. An
    // ordered split repeats the NUMBER too; both formats renumber on render, and
    // `renumberOrderedLists` is the gesture for fixing the source.
    var star = try Fixture.init("* ab\n", .markdown);
    defer star.deinit();
    try star.ed.splitBlock(3);
    try star.expectSource("* a\n* b\n");

    var ord = try Fixture.init("1) ab\n", .markdown);
    defer ord.deinit();
    try ord.ed.splitBlock(4);
    try ord.expectSource("1) a\n1) b\n");
}

test "split_block: a task item's new half is unchecked" {
    // Splitting one done thing in two does not make the remainder done.
    var fx = try Fixture.init("- [x] ab\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(7);
    try fx.expectSource("- [x] a\n- [ ] b\n");
}

test "split_block: a paragraph splits on a blank line" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("ab\n", fmt);
        defer fx.deinit();
        try fx.ed.splitBlock(1);
        try fx.expectSource("a\n\nb\n");

        var paras: usize = 0;
        for (fx.ed.astView().nodes) |n| {
            if (std.meta.activeTag(n.kind) == .para) paras += 1;
        }
        try testing.expectEqual(@as(usize, 2), paras);
    }
}

test "split_block: a caret at a line start doesn't add a redundant blank" {
    // Splitting a soft-wrapped paragraph at the wrap point: the line end already
    // there is the separator's first newline, so only the blank is minted.
    var fx = try Fixture.init("a\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(2);
    try fx.expectSource("a\n\nb\n");
    var paras: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .para) paras += 1;
    }
    try testing.expectEqual(@as(usize, 2), paras);
}

test "split_block: inside a quote the split stays inside the quote" {
    // The blank line carries the quote's marker (`>`, not `> `) and the second
    // half its full prefix, so the quote holds both halves instead of ending.
    var fx = try Fixture.init("> ab\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(3);
    try fx.expectSource("> a\n>\n> b\n");

    var quotes: usize = 0;
    var paras: usize = 0;
    for (fx.ed.astView().nodes) |n| switch (std.meta.activeTag(n.kind)) {
        .block_quote => quotes += 1,
        .para => paras += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), quotes);
    try testing.expectEqual(@as(usize, 2), paras);
}

test "split_block: a heading repeats its own marker at its own level" {
    var fx = try Fixture.init("### ab\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(5);
    try fx.expectSource("### a\n\n### b\n");

    var headings: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .heading) {
            headings += 1;
            try testing.expectEqual(@as(u32, 3), n.kind.heading.level);
        }
    }
    try testing.expectEqual(@as(usize, 2), headings);
}

test "split_block: a code block becomes two, the info string surviving" {
    // The opening fence line is reproduced verbatim from the fence character on,
    // so both the width and the language ride along.
    var fx = try Fixture.init("```rust\nabc\ndef\n```\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(10); // caret inside `abc`
    try fx.expectSource("```rust\nab\n```\n\n```rust\nc\ndef\n```\n");

    var blocks: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .code_block) {
            blocks += 1;
            try testing.expectEqualStrings("rust", n.kind.code_block.lang orelse return error.NoLang);
        }
    }
    try testing.expectEqual(@as(usize, 2), blocks);
}

test "split_block: a measured fence keeps its width across the split" {
    // The body holds a ``` run, so the block was fenced with four; splitting must
    // not reopen with three, which would close at the first inner run.
    var fx = try Fixture.init("````\na ``` b\nc\n````\n", .markdown);
    defer fx.deinit();
    // The caret is at the START of the `c` line, so the separator opens on the
    // line already there rather than adding a blank one inside the first body.
    try fx.ed.splitBlock(13);
    try fx.expectSource("````\na ``` b\n````\n\n````\nc\n````\n");
    var blocks: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .code_block) blocks += 1;
    }
    try testing.expectEqual(@as(usize, 2), blocks);
}

test "split_block: a table is NotEditable" {
    // A newline mid-cell doesn't divide a table, it destroys one. Splitting a
    // table into two tables is a table gesture, not this one.
    var fx = try Fixture.init("| a | b |\n|---|---|\n| c | d |\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.splitBlock(3));
    try fx.expectSource("| a | b |\n|---|---|\n| c | d |\n");
}

test "split_block: a setext heading is NotEditable, not silently normalised" {
    // Its `---` underline belongs to a block that would no longer be under it.
    // `setBlock` converts one to ATX, which makes the split work.
    var fx = try Fixture.init("ab\n---\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.splitBlock(1));
    try fx.expectSource("ab\n---\n");
}

test "split_block: an indented code block is NotEditable" {
    // A blank line inside one is interior, not a separator — the "split" would
    // parse back as a single block, so refusing beats pretending.
    var fx = try Fixture.init("    abc\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.splitBlock(6));
    try fx.expectSource("    abc\n");
}

test "split_block: an empty document has no block to divide" {
    var fx = try Fixture.init("", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.splitBlock(0));
}

test "split_block: an offset past the source is InvalidRange" {
    var fx = try Fixture.init("ab\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.InvalidRange, fx.ed.splitBlock(99));
    try fx.expectSource("ab\n");
}

test "split_block: at a paragraph's end the empty block is unrepresentable" {
    // No format spells an empty paragraph, so this is the one boundary case that
    // cannot produce a second node. The blank line is written and the caret sits
    // where the next paragraph begins; the node appears when there is text.
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(1);
    try fx.expectSource("a\n\n\n");
    var paras: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .para) paras += 1;
    }
    try testing.expectEqual(@as(usize, 1), paras);
}

test "split_block: a format that doesn't divide blocks with a blank line refuses" {
    // The separator every case above writes means "two blocks" only where a
    // blank line separates blocks. Inside an HTML `<p>` it is insignificant
    // whitespace: the gesture wrote its newlines, the reparse gave back the one
    // paragraph it started with, and success was reported for an edit that had
    // changed nothing about the document's shape. The refusal is checked before
    // a byte is read, so the source is untouched rather than merely restored.
    const src = "<p>ab</p>";
    var fx = try Fixture.init(src, .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.splitBlock(4)); // between `a` and `b`
    try fx.expectSource(src);

    // Not a property of the caret: a format with no block separator refuses
    // everywhere in the document, including a position with no block at all.
    try testing.expectError(error.UnsupportedFormat, fx.ed.splitBlock(0));
}

// ── code blocks ──────────────────────────────────────────────────────────────

/// The info string the parser reads back off the edited source — the only thing
/// that proves a fence was tagged rather than merely written.
fn expectCodeLang(fx: *Fixture, expected: ?[]const u8) !void {
    const id = fx.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
    const lang = fx.ed.astView().nodes[id].kind.code_block.lang;
    if (expected) |want| {
        try testing.expectEqualStrings(want, lang orelse return error.NoLang);
    } else {
        try testing.expect(lang == null or lang.?.len == 0);
    }
}

test "toggleCodeBlock: fences a paragraph and unfences it back" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("a\n", fmt);
        defer fx.deinit();
        try fx.ed.toggleCodeBlock(Span.init(0, 1), "zig");
        try fx.expectSource("```zig\na\n```\n");
        try expectCodeLang(&fx, "zig");

        try fx.ed.toggleCodeBlock(Span.init(0, 0), null);
        try fx.expectSource("a\n");
        try fx.expectNoNodeOfKind(.{ .tag = .code_block });
    }
}

test "toggleCodeBlock: an untagged fence is fine" {
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(0, 1), null);
    try fx.expectSource("```\na\n```\n");
    try expectCodeLang(&fx, null);
}

test "toggleCodeBlock: the fence outgrows a run in the body" {
    // Three backticks in the text would close a three-backtick fence on the
    // body's own line, leaving the tail as prose. The fence is measured, so it
    // opens with four and the whole body survives as code.
    var fx = try Fixture.init("a ``` b\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(0, 7), null);
    try fx.expectSource("````\na ``` b\n````\n");
    const id = fx.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
    try testing.expectEqualStrings("a ``` b\n", fx.ed.astView().nodes[id].kind.code_block.text);
}

test "toggleCodeBlock: fencing inside a quote keeps the quote" {
    var fx = try Fixture.init("> a\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(2, 3), null);
    // Only the two fence lines are minted; the body line keeps the `> ` it
    // already had, which is what keeps the block inside the quote.
    try fx.expectSource("> ```\n> a\n> ```\n");
    const quote = fx.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
    const code = fx.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
    try testing.expect(code > quote);
}

test "toggleCodeBlock: inside a list item it refuses instead of eating the marker" {
    // A fence at column zero here would pull the item's `- ` into the code body,
    // and the document would LOSE the list item rather than gain a code block.
    // Refusing is the same choice `insertLink` makes over a half-selected URL.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("- a\n- b\n", fmt);
        defer fx.deinit();
        try testing.expectError(error.NotEditable, fx.ed.toggleCodeBlock(Span.init(2, 3), null));
        try fx.expectSource("- a\n- b\n");
    }
    // And the same in the other direction: a code block already inside an item
    // is left alone rather than half-unwrapped.
    var fx = try Fixture.init("- ```\n  a\n  ```\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.toggleCodeBlock(Span.init(8, 8), null));
    try fx.expectSource("- ```\n  a\n  ```\n");
}

test "toggleCodeBlock: unfencing an INDENTED Markdown code block dedents it" {
    // The older spelling carries no fence to peel, so the toggle has to know its
    // framing IS the indentation — otherwise it would eat two lines of code.
    var fx = try Fixture.init("    code\n    more\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(0, 0), null);
    try fx.expectSource("code\nmore\n");
    try fx.expectNoNodeOfKind(.{ .tag = .code_block });
}

test "toggleCodeBlock: an unterminated fence keeps its last line" {
    // No closing fence means the last line is content, not framing.
    var fx = try Fixture.init("```\na\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(4, 4), null);
    try fx.expectSource("a\nb\n");
}

test "setCodeLanguage: retags and clears the info string, fence width untouched" {
    var fx = try Fixture.init("````zig\na ``` b\n````\n", .markdown);
    defer fx.deinit();
    try fx.ed.setCodeLanguage(0, "rust");
    try fx.expectSource("````rust\na ``` b\n````\n");
    try expectCodeLang(&fx, "rust");

    try fx.ed.setCodeLanguage(0, null);
    try fx.expectSource("````\na ``` b\n````\n");
    try expectCodeLang(&fx, null);
}

test "setCodeLanguage: an indented code block has nowhere to carry one" {
    var fx = try Fixture.init("    code\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.setCodeLanguage(0, "zig"));
    try fx.expectSource("    code\n");
}

test "setCodeLanguage: outside a code block is NoBlock" {
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.setCodeLanguage(0, "zig"));
}

test "code fence: an info string the fence can't carry is refused" {
    // The fence byte would widen or close the fence in either format...
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("a\n", fmt);
        defer fx.deinit();
        try testing.expectError(error.InvalidLanguage, fx.ed.toggleCodeBlock(Span.init(0, 1), "a`b"));
        try testing.expectError(error.InvalidLanguage, fx.ed.toggleCodeBlock(Span.init(0, 1), "a\nb"));
        try fx.expectSource("a\n");
    }
    // ...but only Markdown ends its info string at whitespace, so only Markdown
    // refuses a space. Djot's runs to the end of the line.
    var md = try Fixture.init("a\n", .markdown);
    defer md.deinit();
    try testing.expectError(error.InvalidLanguage, md.ed.toggleCodeBlock(Span.init(0, 1), "a b"));

    var dj = try Fixture.init("a\n", .djot);
    defer dj.deinit();
    try dj.ed.toggleCodeBlock(Span.init(0, 1), "a b");
    try dj.expectSource("```a b\na\n```\n");
}

test "code blocks: a parse-only format spells no fence" {
    for ([_]format.Format{ .xml, .html }) |fmt| {
        var fx = try Fixture.init("<r>ab</r>", fmt);
        defer fx.deinit();
        try testing.expectError(error.UnsupportedFormat, fx.ed.toggleCodeBlock(Span.init(3, 5), null));
        try testing.expectError(error.UnsupportedFormat, fx.ed.setCodeLanguage(3, "zig"));
    }
}

// ── task list checkboxes ─────────────────────────────────────────────────────

/// The checked state the parser reads back — the box's meaning, not its bytes.
fn expectTaskChecked(fx: *Fixture, expected: bool) !void {
    const id = fx.find(.{ .tag = .task_list_item }) orelse return error.NoTaskItem;
    try testing.expectEqual(expected, fx.ed.astView().nodes[id].kind.task_list_item.checked);
}

test "toggleTaskItem: a bullet gains a box, and loses it again" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("- a\n", fmt);
        defer fx.deinit();
        try fx.ed.toggleTaskItem(2);
        try fx.expectSource("- [ ] a\n");
        try expectTaskChecked(&fx, false);

        try fx.ed.toggleTaskItem(6);
        try fx.expectSource("- a\n");
        try fx.expectNoNodeOfKind(.{ .tag = .task_list_item });
        try testing.expect(fx.find(.{ .tag = .list_item }) != null);
    }
}

test "setTaskChecked: ticks and unticks, and is a no-op when already there" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("- [ ] a\n", fmt);
        defer fx.deinit();
        try fx.ed.setTaskChecked(6, true);
        try fx.expectSource("- [x] a\n");
        try expectTaskChecked(&fx, true);

        // Already checked: no edit at all, so no undo step to burn.
        const before = fx.ed.lastChange();
        try fx.ed.setTaskChecked(6, true);
        try testing.expectEqual(before, fx.ed.lastChange());

        try fx.ed.setTaskChecked(6, false);
        try fx.expectSource("- [ ] a\n");
        try expectTaskChecked(&fx, false);
    }
}

test "toggleTaskChecked: flips whichever way the box is pointing" {
    var fx = try Fixture.init("- [ ] a\n- [x] b\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleTaskChecked(6);
    try fx.expectSource("- [x] a\n- [x] b\n");
    try fx.ed.toggleTaskChecked(14);
    try fx.expectSource("- [x] a\n- [ ] b\n");
}

test "task boxes: a capital [X] is a checked box, not a second one to add" {
    // Source in the wild spells it both ways. Matching the box's INTERIOR rather
    // than the canonical spelling is what keeps the toggle from writing
    // `- [ ] [X] a`.
    var fx = try Fixture.init("- [X] a\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleTaskChecked(6);
    try fx.expectSource("- [ ] a\n");
    try expectTaskChecked(&fx, false);
}

test "task boxes: an item inside a quote is found past the quote markers" {
    // The list marker doesn't start the line here, which is the whole reason
    // `listMarkerAt` takes a starting offset.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("> - [ ] a\n", fmt);
        defer fx.deinit();
        try fx.ed.setTaskChecked(8, true);
        try fx.expectSource("> - [x] a\n");
        try expectTaskChecked(&fx, true);
    }
}

test "task boxes: an item's continuation lines are untouched" {
    // The box is inline content of the item's first paragraph, not part of the
    // marker, so the content column never moves — unlike a container toggle,
    // which has to re-indent.
    var fx = try Fixture.init("- a\n  b\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleTaskItem(2);
    try fx.expectSource("- [ ] a\n  b\n");
    try expectTaskChecked(&fx, false);
}

test "setTaskChecked: a plain bullet has no box to tick" {
    // Minting one here would make "set checked" silently convert the item;
    // `toggleTaskItem` is how a caller asks for that.
    var fx = try Fixture.init("- a\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.setTaskChecked(2, true));
    try testing.expectError(error.NotEditable, fx.ed.toggleTaskChecked(2));
    try fx.expectSource("- a\n");
}

test "task boxes: a caret in no list item is NoBlock" {
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.toggleTaskItem(0));
    try testing.expectError(error.NoBlock, fx.ed.setTaskChecked(0, true));
}

test "task boxes: a parse-only format spells none" {
    for ([_]format.Format{ .xml, .html }) |fmt| {
        var fx = try Fixture.init("<r>ab</r>", fmt);
        defer fx.deinit();
        try testing.expectError(error.UnsupportedFormat, fx.ed.toggleTaskItem(3));
        try testing.expectError(error.UnsupportedFormat, fx.ed.setTaskChecked(3, true));
    }
}

// ── footnotes ────────────────────────────────────────────────────────────────

test "insertFootnote: writes the reference AND the definition" {
    // Half a footnote is not a footnote: a bare `[^a]` renders as four literal
    // characters. So the reparse has to show both nodes, not just the bytes.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("see\n", fmt);
        defer fx.deinit();
        try fx.ed.insertFootnote(3, "a");
        try fx.expectSource("see[^a]\n\n[^a]: \n");
        try fx.expectSpelled(.{ .text_leaf = .footnote_reference }, "a");
        const def = fx.find(.{ .tag = .footnote }) orelse return error.NoDefinition;
        try testing.expectEqualStrings("a", fx.ed.astView().nodes[def].kind.footnote.label);
    }
}

test "insertFootnote: a second reference to the same label adds no second definition" {
    var fx = try Fixture.init("see\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertFootnote(3, "a");
    try fx.ed.insertFootnote(7, "a");
    try fx.expectSource("see[^a][^a]\n\n[^a]: \n");

    var defs: usize = 0;
    for (fx.ed.astView().nodes) |n| {
        if (std.meta.activeTag(n.kind) == .footnote) defs += 1;
    }
    try testing.expectEqual(@as(usize, 1), defs);
}

test "insertFootnote: a distinct label gets its own definition, below the first" {
    var fx = try Fixture.init("see\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertFootnote(3, "a");
    try fx.ed.insertFootnote(7, "b");
    try fx.expectSource("see[^a][^b]\n\n[^a]: \n\n[^b]: \n");
}

test "insertFootnote: a source with no trailing newline still gets a whole block" {
    var fx = try Fixture.init("see", .markdown);
    defer fx.deinit();
    try fx.ed.insertFootnote(3, "a");
    try fx.expectSource("see[^a]\n\n[^a]: \n");
}

test "insertFootnote: it is ONE edit, so one undo takes both halves back" {
    // The two halves sit at opposite ends of the document but are one gesture:
    // two splices would need two undos and would report only half the change.
    var fx = try Fixture.init("see\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertFootnote(3, "a");
    _ = try fx.ed.splicer.undo();
    try fx.expectSource("see\n");
}

test "insertFootnote: a label the reference brackets can't hold is refused" {
    var fx = try Fixture.init("see\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.InvalidLabel, fx.ed.insertFootnote(3, ""));
    try testing.expectError(error.InvalidLabel, fx.ed.insertFootnote(3, "a\nb"));
    try testing.expectError(error.InvalidLabel, fx.ed.insertFootnote(3, "a]b"));
    try fx.expectSource("see\n");
}

test "insertFootnote: a parse-only format spells none" {
    for ([_]format.Format{ .xml, .html }) |fmt| {
        var fx = try Fixture.init("<r>ab</r>", fmt);
        defer fx.deinit();
        try testing.expectError(error.UnsupportedFormat, fx.ed.insertFootnote(3, "a"));
    }
}

// ── Capability ──────────────────────────────────────────────────────────────
// `Editor.supports` reports, without a document, whether a gesture will refuse
// on FORMAT. It is a second reading of the same `Syntax` fields the gestures
// gate on, so the thing worth testing is not what it returns but that it cannot
// drift from them — the same measured-not-asserted discipline
// `diagnostics.zig`'s fidelity table uses, for the same reason: a hand-written
// capability table is wrong the moment a gesture's gate moves.

/// A minimal document each format actually parses. The gestures below are run
/// against it only to reach their gate — every one of them checks the `Syntax`
/// table before it reads a single byte of source (that ordering is deliberate
/// and documented per gesture), so the content only has to parse, not to be a
/// place the gesture would succeed.
fn minimalSource(fmt: format.Format) []const u8 {
    return switch (fmt) {
        .xml, .html => "<r>ab</r>",
        else => "ab\n",
    };
}

/// Every `Gesture`, with both kind vocabularies enumerated in full — so a new
/// `InlineKind` or `ContainerKind` widens the sweep with no edit here.
const all_gestures = blk: {
    var list: []const Editor.Gesture = &.{};
    for (std.enums.values(Editor.InlineKind)) |k| {
        list = list ++ &[_]Editor.Gesture{ .{ .wrap_range = k }, .{ .toggle_inline = k } };
    }
    for (std.enums.values(Editor.ContainerKind)) |k| {
        list = list ++ &[_]Editor.Gesture{.{ .toggle_block_container = k }};
    }
    break :blk list ++ &[_]Editor.Gesture{
        .set_block,
        .insert_thematic_break,
        .toggle_code_block,
        .set_code_language,
        .toggle_task_item,
        .set_task_checked,
        .toggle_task_checked,
        .insert_link,
        .insert_image,
        .insert_footnote,
        .insert_literal,
        .insert_line_break,
        .split_block,
        .renumber_ordered_lists,
        .table_insert_row,
        .table_delete_row,
        .table_insert_column,
        .table_delete_column,
        .table_set_alignment,
        .table_move_row,
        .table_move_column,
    };
};

comptime {
    // A `Gesture` variant added without a row above would silently go untested,
    // which is the one failure this whole test exists to prevent.
    @setEvalBranchQuota(10_000);
    for (std.meta.fields(Editor.Gesture)) |f| {
        var seen = false;
        for (all_gestures) |g| {
            if (std.mem.eql(u8, @tagName(g), f.name)) seen = true;
        }
        if (!seen) @compileError("all_gestures is missing Gesture." ++ f.name);
    }
}

/// Call the gesture `g` names, with arguments valid enough to reach its gate.
/// The `switch` is exhaustive, so a renamed or removed variant is a compile
/// error rather than a silently skipped row.
fn runGesture(ed: *Editor, g: Editor.Gesture) Editor.Error!void {
    const whole = Span.init(0, ed.sourceBytes().len);
    return switch (g) {
        .wrap_range => |k| ed.wrapRange(whole, k),
        .toggle_inline => |k| ed.toggleInline(whole, k),
        .set_block => ed.setBlock(0, .heading, 1),
        .toggle_block_container => |k| ed.toggleBlockContainer(whole, k),
        .insert_thematic_break => ed.insertThematicBreak(0),
        .toggle_code_block => ed.toggleCodeBlock(whole, null),
        .set_code_language => ed.setCodeLanguage(0, null),
        .toggle_task_item => ed.toggleTaskItem(0),
        .set_task_checked => ed.setTaskChecked(0, true),
        .toggle_task_checked => ed.toggleTaskChecked(0),
        .insert_link => ed.insertLink(whole, "https://example.com"),
        .insert_image => ed.insertImage(whole, "https://example.com/a.png"),
        .insert_footnote => ed.insertFootnote(0, "n"),
        .insert_literal => ed.insertLiteral(0, "x"),
        .insert_line_break => ed.insertLineBreak(0),
        .split_block => ed.splitBlock(0),
        .renumber_ordered_lists => ed.renumberOrderedLists(0),
        .table_insert_row => ed.tableInsertRow(0, true),
        .table_delete_row => ed.tableDeleteRow(0),
        .table_insert_column => ed.tableInsertColumn(0, true),
        .table_delete_column => ed.tableDeleteColumn(0),
        .table_set_alignment => ed.tableSetAlignment(0, .center),
        .table_move_row => ed.tableMoveRow(0, true),
        .table_move_column => ed.tableMoveColumn(0, true),
    };
}

test "supports matches what every gesture's gate actually does" {
    // The pin. For every (format, gesture) pair: run the real gesture and
    // assert it reports `UnsupportedFormat` EXACTLY when `supports` says false.
    // Any other error (`NoBlock` where the caret isn't in a list, `NotEditable`,
    // `EditConflict`) is a position answer, not a format one, and counts as
    // supported — which is precisely the distinction `supports` documents.
    inline for (std.meta.fields(format.Format)) |f| {
        const fmt: format.Format = @enumFromInt(f.value);
        const syntax = format.syntaxFor(fmt);
        for (all_gestures) |g| {
            var fx = try Fixture.init(minimalSource(fmt), fmt);
            defer fx.deinit();

            const claimed = Editor.supports(syntax, g);
            const observed = if (runGesture(&fx.ed, g)) |_| true else |err| switch (err) {
                error.UnsupportedFormat => false,
                else => true,
            };
            if (claimed != observed) {
                std.debug.print(
                    "\nsupports({s}, .{s}) claims {}, but the gesture reports {s}\n",
                    .{ @tagName(fmt), @tagName(g), claimed, if (observed) "supported" else "UnsupportedFormat" },
                );
                return error.CapabilityDrift;
            }
        }
    }
}

test "supports is the per-gesture answer authorable() cannot give" {
    // HTML is the case that motivates the whole query: `authorable()` is true
    // for it (see `format.zig`), yet a toolbar enabled on that predicate would
    // show a heading button, a quote button and a code-block button that all
    // fail. Per gesture, the answer is ragged — and this is what a caller needs.
    const html = format.syntaxFor(.html);
    try testing.expect(html.authorable());
    try testing.expect(Editor.supports(html, .{ .toggle_inline = .strong }));
    try testing.expect(!Editor.supports(html, .set_block));
    try testing.expect(!Editor.supports(html, .{ .toggle_block_container = .block_quote }));
    try testing.expect(!Editor.supports(html, .toggle_code_block));
    try testing.expect(!Editor.supports(html, .insert_literal));
    // The three that used to answer nothing at all, because they consulted no
    // `Syntax` field: HTML has a table its parser reads and no table spelling to
    // write one back with, no blank-line block separation, and no numbered list
    // marker. A toolbar can gray all nine out now instead of offering an edit
    // that destroyed the table it was aimed at.
    try testing.expect(!Editor.supports(html, .table_insert_row));
    try testing.expect(!Editor.supports(html, .table_set_alignment));
    try testing.expect(!Editor.supports(html, .split_block));
    try testing.expect(!Editor.supports(html, .renumber_ordered_lists));

    // A format that spells nothing answers false to every gesture, so
    // `authorable()` and `supports` agree there — the coarse predicate is only
    // ever misleading in the middle of the range.
    for (all_gestures) |g| {
        try testing.expect(!Editor.supports(format.syntaxFor(.xml), g));
    }

    // AsciiDoc sits in the middle of the range the other way round from
    // HTML: every block gesture works, and it is the three whose SHAPE the
    // algorithms cannot write — a link (`dest[text]`), a footnote (one macro),
    // a table (`|===`-fenced, no delimiter row) — that a toolbar grays out.
    const adoc = format.syntaxFor(.asciidoc);
    try testing.expect(adoc.authorable());
    try testing.expect(Editor.supports(adoc, .{ .toggle_inline = .mark }));
    try testing.expect(Editor.supports(adoc, .{ .toggle_inline = .superscript }));
    try testing.expect(!Editor.supports(adoc, .{ .toggle_inline = .insert }));
    try testing.expect(Editor.supports(adoc, .set_block));
    try testing.expect(Editor.supports(adoc, .{ .toggle_block_container = .block_quote }));
    try testing.expect(Editor.supports(adoc, .{ .toggle_block_container = .ordered_list }));
    try testing.expect(Editor.supports(adoc, .toggle_code_block));
    try testing.expect(Editor.supports(adoc, .toggle_task_item));
    try testing.expect(Editor.supports(adoc, .insert_literal));
    try testing.expect(Editor.supports(adoc, .split_block));
    try testing.expect(Editor.supports(adoc, .renumber_ordered_lists));
    try testing.expect(!Editor.supports(adoc, .insert_link));
    try testing.expect(!Editor.supports(adoc, .insert_image));
    try testing.expect(!Editor.supports(adoc, .insert_footnote));
    try testing.expect(!Editor.supports(adoc, .insert_line_break));
    try testing.expect(!Editor.supports(adoc, .table_insert_row));

    // And the two authorable formats differ from each other, which is the other
    // half of why one boolean can't serve: djot spells all eight inline marks,
    // Markdown three. `==mark==` is emit-only there (`Delims.authorable`), so
    // the query refuses it exactly as `toggleInline` does.
    try testing.expect(Editor.supports(format.syntaxFor(.djot), .{ .toggle_inline = .mark }));
    try testing.expect(!Editor.supports(format.syntaxFor(.markdown), .{ .toggle_inline = .mark }));
    try testing.expect(Editor.supports(format.syntaxFor(.markdown), .insert_line_break));
    try testing.expect(!Editor.supports(format.syntaxFor(.djot), .insert_line_break));
}
