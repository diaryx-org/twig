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

/// The one parse config these tests do vary, and the reason it has to exist:
/// Markdown's `==x==` is authorable only where the reparse behind the editor
/// reads it back as a `mark`, so a highlight test needs the extension ON in the
/// very config the splicer reparses with. Two of them, because colours are a
/// second, narrower gate on top of highlights.
var highlight_cfg: format.ParseConfig = .{ .markdown = .{ .highlight = true } };
/// The other direction — strict CommonMark, where `~~x~~` is two literal
/// tildes — is not a config at all: it is the `.commonmark` ROW, and the
/// fixtures below name it as the format.
var highlight_colors_cfg: format.ParseConfig = .{
    .markdown = .{ .highlight = true, .highlight_colors = true },
};
/// The third of them, for the same reason as the first two: Markdown reads
/// `::name` back as a container only under `ParseOptions.directives`, so a
/// gesture that mints one has to run against an editor whose own reparse sees
/// it. Without the flag those bytes are a paragraph of colons, which is what
/// `insertDirective`'s refusal below asserts.
var directives_cfg: format.ParseConfig = .{ .markdown = .{ .directives = true } };
/// And the fourth: a `<div>` around a block and a `<span>` around a run are
/// raw HTML to Markdown's default parser and a container under
/// `ParseOptions.html_elements`, so the two attribute gestures run against an
/// editor whose reparse pairs the tags.
var html_elements_cfg: format.ParseConfig = .{ .markdown = .{ .html_elements = true } };
/// And the fifth: under `ParseOptions.math` a `$` opens a formula, so the
/// math gestures may write one and a literal typed there has to escape one.
var math_cfg: format.ParseConfig = .{ .markdown = .{ .math = true } };

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

    /// `init` for a document parsed with something other than the defaults.
    /// The spelling comes from `syntaxForConfig` rather than the row's default
    /// table — the same pairing `twig_editor_create_ext` makes, so what these
    /// tests exercise is what a C caller gets.
    fn initWith(source: []const u8, fmt: format.Format, cfg: *format.ParseConfig) !Fixture {
        const entry = format.entryFor(fmt);
        return .{ .ed = try Editor.init(
            testing.allocator,
            source,
            cfg,
            entry.parseToAst,
            format.syntaxForConfig(fmt, cfg),
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

test "toggleInline: a selection that reaches into a mark's delimiters is still that mark" {
    // A rich view draws no delimiters, so a drag that ends after the `d` of
    // `**bold**` ends before its closing `**` or after it — both are the
    // bold, and the second used to be wrapped again as `****bold****`.
    var md = try Fixture.init("**bold** plain\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(2, 8), .strong);
    try md.expectSource("bold plain\n");

    var md2 = try Fixture.init("**bold** plain\n", .markdown);
    defer md2.deinit();
    try md2.ed.toggleInline(Span.init(0, 6), .strong);
    try md2.expectSource("bold plain\n");

    // Short of the interior is not the mark: `bol` alone is a new selection.
    var md3 = try Fixture.init("**bold** plain\n", .markdown);
    defer md3.deinit();
    try md3.ed.toggleInline(Span.init(2, 5), .strong);
    try md3.expectSource("****bol**d** plain\n");
}

test "toggleInline: bold over emphasis toggles off again from the whole span" {
    // `***word***` is an emph whose whole interior is a strong. The second
    // press over the same span is the strong coming off, not a third pair.
    var md = try Fixture.init("*word*\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(0, 6), .strong);
    try md.expectSource("***word***\n");
    try md.ed.toggleInline(Span.init(0, 10), .strong);
    try md.expectSource("*word*\n");
    // The same from the interior alone, and from the strong's own span.
    try md.ed.toggleInline(Span.init(1, 5), .strong);
    try md.expectSource("***word***\n");
    try md.ed.toggleInline(Span.init(1, 9), .strong);
    try md.expectSource("*word*\n");
}

test "toggleInline: a whole paragraph that is one mark is that mark" {
    var md = try Fixture.init("**bold**\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(0, 8), .strong);
    try md.expectSource("bold\n");
}

test "toggleInline: a selection inside a code span marks the whole code span" {
    // `**` inside the backticks is code; the mark closes around them, and
    // comes off again from the span it left selected.
    var md = try Fixture.init("a `word` b\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(3, 7), .strong);
    try md.expectSource("a **`word`** b\n");
    try md.ed.toggleInline(Span.init(2, 12), .strong);
    try md.expectSource("a `word` b\n");
    // A selection that cuts into the code span from outside takes it whole.
    try md.ed.toggleInline(Span.init(0, 4), .emph);
    try md.expectSource("*a `word`* b\n");
    // Toggling code itself from inside the span strips it.
    var md2 = try Fixture.init("a `word` b\n", .markdown);
    defer md2.deinit();
    try md2.ed.toggleInline(Span.init(3, 7), .verbatim);
    try md2.expectSource("a word b\n");
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

test "toggleInline: underline is <u> in Markdown, authorable only under html_elements" {
    // Only `html_elements` pairs `<u>…</u>` back into an `insert`; without it
    // the tags reparse as two raw inlines, so the gesture is refused.
    var plain = try Fixture.init("a word b\n", .markdown);
    defer plain.deinit();
    try testing.expectError(error.UnsupportedFormat, plain.ed.toggleInline(Span.init(2, 6), .insert));
    try plain.expectSource("a word b\n");

    var fx = try Fixture.initWith("a word b\n", .markdown, &html_elements_cfg);
    defer fx.deinit();
    try fx.ed.toggleInline(Span.init(2, 6), .insert);
    try fx.expectSource("a <u>word</u> b\n");
    try fx.ed.toggleInline(Span.init(5, 9), .insert);
    try fx.expectSource("a word b\n");
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

test "toggleInline: html's raggedness stops at what has no native spelling" {
    // The gestures whose construct HTML has no element for (a task box is a
    // form control, a footnote is a convention). All refused through the one
    // uniform path, none of them with a hand-written HTML arm. A heading, a
    // literal, the containers, the code block and the link used to be on this
    // list; they go through the renderers now — see the `… html` tests of
    // each gesture.
    var fx = try Fixture.init("<p>ab</p>\n", .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.toggleTaskItem(3));
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertFootnote(3, "a"));
    try fx.expectSource("<p>ab</p>\n");
}

test "wrapRange always adds, even over an existing mark" {
    var fx = try Fixture.init("a *word* b\n", .djot);
    defer fx.deinit();
    try fx.ed.wrapRange(Span.init(3, 7), .emph);
    try fx.expectSource("a *_word_* b\n");
}

// ── inline marks across block boundaries ───────────────────────────────────

test "toggleInline: a range crossing a blank line marks each block, not the gap" {
    // The bug this replaced: one pair around the whole range put the opener in
    // the first paragraph and the closer in the second, which reparses fine —
    // as two paragraphs carrying four literal asterisks and no mark at all.
    var md = try Fixture.init("one two\n\nthree four\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(0, 19), .strong);
    try md.expectSource("**one two**\n\n**three four**\n");

    // Two marks, not one — and the pin is the reparsed tree, because the point
    // is what the parser reads back rather than what the bytes look like.
    var strongs: usize = 0;
    for (md.ed.astView().nodes) |n| {
        if ((AST.KindRef{ .mark = .strong }).matches(n.kind)) strongs += 1;
    }
    try testing.expectEqual(@as(usize, 2), strongs);

    // And the second press removes BOTH, because each piece is decided on its
    // own: it finds a mark around each and strips it, rather than nesting a
    // second pair around the first.
    try md.ed.toggleInline(Span.init(0, 27), .strong);
    try md.expectSource("one two\n\nthree four\n");
}

test "toggleInline: djot cuts at the same boundaries with its own delimiters" {
    var dj = try Fixture.init("one two\n\nthree four\n", .djot);
    defer dj.deinit();
    try dj.ed.toggleInline(Span.init(0, 19), .emph);
    try dj.expectSource("_one two_\n\n_three four_\n");
    try dj.ed.toggleInline(Span.init(0, 23), .emph);
    try dj.expectSource("one two\n\nthree four\n");
}

test "toggleInline: each list item is its own block, and its marker is not in it" {
    // The bytes between the pieces — the newline and the next item's `- ` — are
    // copied through untouched, which is what keeps this a list rather than one
    // paragraph with a stray bullet in the middle of a bold run.
    var md = try Fixture.init("- alpha\n- beta\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(2, 14), .strong);
    try md.expectSource("- **alpha**\n- **beta**\n");
    try testing.expect(md.find(.{ .tag = .bullet_list }) != null);
}

test "toggleInline: out of a quote and into the paragraph after it" {
    // Djot and Markdown disagree about where a quoted block STARTS (Djot at its
    // text, Markdown at column zero), which is exactly the kind of span
    // difference a rule derived from one format gets wrong on the other. Both
    // are pinned because the piece comes from the paragraph's interior, which
    // is the one thing they agree on.
    var md = try Fixture.init("> one\n\ntwo\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(2, 10), .strong);
    try md.expectSource("> **one**\n\n**two**\n");
    try testing.expect(md.find(.{ .tag = .block_quote }) != null);

    var dj = try Fixture.init("> one\n\ntwo\n", .djot);
    defer dj.deinit();
    try dj.ed.toggleInline(Span.init(2, 10), .emph);
    try dj.expectSource("> _one_\n\n_two_\n");
    try testing.expect(dj.find(.{ .tag = .block_quote }) != null);
}

test "toggleInline: a heading's marker stays outside the mark" {
    // The selection is the whole line, `# ` included. The piece is the
    // heading's `content_span`, so the marker is not what gets wrapped —
    // `**# Title**` is a bold paragraph, not a bold heading.
    var md = try Fixture.init("# Title\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(0, 7), .strong);
    try md.expectSource("# **Title**\n");
    try testing.expect(md.find(.{ .tag = .heading }) != null);
}

test "toggleInline: a code block inside the range is stepped over, not marked" {
    var md = try Fixture.init("a\n\n```\nx\n```\n\nb\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(0, 15), .emph);
    try md.expectSource("*a*\n\n```\nx\n```\n\n*b*\n");
    // Still a fence, and its body is byte-for-byte what it was: an asterisk
    // in a program is an asterisk.
    const fence = md.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
    try testing.expectEqualStrings("x\n", md.ed.astView().nodes[fence].kind.code_block.text);
}

test "toggleInline: a range with nowhere to put a mark is refused, not mis-spelled" {
    // Wholly inside the fence. There is no inline host in the range, so there
    // is no honest place for a delimiter — and reporting success after writing
    // two asterisks into someone's program is the failure `NotEditable` exists
    // to prevent.
    var md = try Fixture.init("```\nx y\n```\n", .markdown);
    defer md.deinit();
    try testing.expectError(error.NotEditable, md.ed.toggleInline(Span.init(4, 7), .strong));
    try testing.expectError(error.NotEditable, md.ed.wrapRange(Span.init(4, 7), .strong));
    try md.expectSource("```\nx y\n```\n");
}

test "wrapRange: a caret is not a range, and still opens an empty pair" {
    // Zero-width: it crosses no boundary, and clipping it to a host would find
    // a zero-width share and drop it. "Turn bold on, then type" survives.
    var md = try Fixture.init("ab\n", .markdown);
    defer md.deinit();
    try md.ed.wrapRange(Span.init(1, 1), .strong);
    try md.expectSource("a****b\n");
}

test "wrapRange: a crossing range gets one pair per block too" {
    // `wrapRange` always adds — but "adds" still has to mean a mark, so it cuts
    // at the same boundaries the toggle does.
    var md = try Fixture.init("one\n\ntwo\n", .markdown);
    defer md.deinit();
    try md.ed.wrapRange(Span.init(0, 8), .emph);
    try md.expectSource("*one*\n\n*two*\n");
}

test "toggleInline: one splice, so one undo step, however many blocks it touched" {
    // The reason the pieces are assembled into a single buffer rather than
    // spliced one at a time: a three-paragraph selection is one Cmd-Z, not
    // three, and one `Change` for the host to re-anchor its caret against.
    var md = try Fixture.init("a\n\nb\n\nc\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(0, 7), .strong);
    try md.expectSource("**a**\n\n**b**\n\n**c**\n");
    _ = try md.ed.splicer.undo();
    try md.expectSource("a\n\nb\n\nc\n");
}

test "a range past the source is refused before it can reach the splicer's assert" {
    var fx = try Fixture.init("ab\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.InvalidRange, fx.ed.toggleInline(Span.init(0, 99), .strong));
    try testing.expectError(error.InvalidRange, fx.ed.wrapRange(Span.init(2, 1), .strong));
    try testing.expectError(error.InvalidRange, toggleContainer(&fx, 0, 99, .block_quote));
}

test "toggleInline: GFM strikethrough is authorable under Twig's defaults" {
    // `~~x~~` reads back as a `delete` because `ParseOptions.strikethrough`
    // defaults ON — so unlike `==x==`, the DEFAULT editor is the one that can
    // write it, and turning the extension off is what takes it away.
    var md = try Fixture.init("a word b\n", .markdown);
    defer md.deinit();
    try md.ed.toggleInline(Span.init(2, 6), .delete);
    try md.expectSource("a ~~word~~ b\n");
    try testing.expect(md.find(.{ .mark = .delete }) != null);
    try md.ed.toggleInline(Span.init(4, 8), .delete);
    try md.expectSource("a word b\n");

    // Strict CommonMark has no strikethrough, so the same gesture over a
    // document parsed as that dialect would mint two literal tildes. Refused.
    var strict = try Fixture.init("a word b\n", .commonmark);
    defer strict.deinit();
    try testing.expectError(error.UnsupportedFormat, strict.ed.toggleInline(Span.init(2, 6), .delete));
    try testing.expectError(error.UnsupportedFormat, strict.ed.wrapRange(Span.init(2, 6), .delete));
    try strict.expectSource("a word b\n");

    // The two axes are independent: the CommonMark row with the highlight
    // extension laid over it authors `==x==` and still refuses `~~x~~`.
    var mixed = try Fixture.initWith("a word b\n", .commonmark, &highlight_cfg);
    defer mixed.deinit();
    try testing.expectError(error.UnsupportedFormat, mixed.ed.toggleInline(Span.init(2, 6), .delete));
    try mixed.ed.toggleInline(Span.init(2, 6), .mark);
    try mixed.expectSource("a ==word== b\n");
}

// ── highlights and their colours ───────────────────────────────────────────
//
// The pair of gestures whose availability is a fact about the PARSE CONFIG
// rather than about the format: `==x==` is literal text under default options
// (so a toggle that wrote it could not unwrite it) and a `mark` under
// `ParseOptions.highlight`, and the colour prefix is content until
// `highlight_colors` says otherwise. Every fixture here therefore goes through
// `initWith`, and the assertions are on the reparsed KIND — the only thing that
// proves the bytes came back as what they were meant to be.

/// The `data-color` of the first `mark` in the reparsed tree, or null.
fn markColor(fx: *Fixture) ?[]const u8 {
    const id = fx.find(.{ .mark = .mark }) orelse return null;
    return fx.ed.astView().attrsOf(id).get("data-color");
}

test "toggleInline: a highlight is authorable exactly where the reparse reads it back" {
    // Default options: `==x==` is emit-only, and the toggle refuses rather than
    // minting bytes that come back as a `str`.
    var off = try Fixture.init("a word b\n", .markdown);
    defer off.deinit();
    try testing.expectError(error.UnsupportedFormat, off.ed.toggleInline(Span.init(2, 6), .mark));
    try off.expectSource("a word b\n");

    // Same format, same gesture, `highlight` on: written, reparsed as a mark,
    // and reversible — which is the whole of what `authorable` claims.
    var on = try Fixture.initWith("a word b\n", .markdown, &highlight_cfg);
    defer on.deinit();
    try on.ed.toggleInline(Span.init(2, 6), .mark);
    try on.expectSource("a ==word== b\n");
    try testing.expect(on.find(.{ .mark = .mark }) != null);
    try on.ed.toggleInline(Span.init(4, 8), .mark);
    try on.expectSource("a word b\n");
}

test "setMarkColor: colours a highlight, recolours it, and clears it" {
    var fx = try Fixture.initWith("a ==word== b\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    try testing.expect(markColor(&fx) == null);

    // A first colour is written spaced, and lands INSIDE the delimiters.
    try fx.ed.setMarkColor(6, "red");
    try fx.expectSource("a ==\u{1F534} word== b\n");
    try testing.expectEqualStrings("red", markColor(&fx).?);

    // Recolouring replaces the prefix rather than stacking a second one.
    try fx.ed.setMarkColor(9, "blue");
    try fx.expectSource("a ==\u{1F535} word== b\n");
    try testing.expectEqualStrings("blue", markColor(&fx).?);

    // Clearing takes the space the prefix absorbed with it: it was spelling.
    try fx.ed.setMarkColor(9, null);
    try fx.expectSource("a ==word== b\n");
    try testing.expect(fx.find(.{ .mark = .mark }) != null);
    try testing.expect(markColor(&fx) == null);
}

test "setMarkColor: a tight prefix stays tight, because that spacing is the author's" {
    var fx = try Fixture.initWith("==\u{1F534}word==\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    try testing.expectEqualStrings("red", markColor(&fx).?);
    try fx.ed.setMarkColor(7, "green");
    try fx.expectSource("==\u{1F7E2}word==\n");
    try testing.expectEqualStrings("green", markColor(&fx).?);

    // And clearing a tight one leaves the text alone.
    try fx.ed.setMarkColor(7, null);
    try fx.expectSource("==word==\n");
}

test "setMarkColor: clearing a colourless highlight is a no-op that succeeds" {
    var fx = try Fixture.initWith("==word==\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    try fx.ed.setMarkColor(3, null);
    try fx.expectSource("==word==\n");
    // Nothing was spliced, so there is no change to report.
    try testing.expect(fx.ed.lastChange() == null);
}

test "setMarkColor: the caret picks the INNERMOST highlight" {
    var fx = try Fixture.initWith("*a ==b== c*\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    // Inside the emphasis but outside the mark: nothing to colour.
    try testing.expectError(error.NotEditable, fx.ed.setMarkColor(2, "red"));
    try fx.ed.setMarkColor(6, "red");
    try fx.expectSource("*a ==\u{1F534} b== c*\n");
    try testing.expectEqualStrings("red", markColor(&fx).?);
}

test "setMarkColor: a colour the format cannot spell is refused, not written" {
    var fx = try Fixture.initWith("==word==\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    // Obsidian's palette is the circle emoji, and `pink` is not one of them —
    // writing something for it would edit the highlighted TEXT.
    try testing.expectError(error.InvalidColor, fx.ed.setMarkColor(3, "pink"));
    try fx.expectSource("==word==\n");
    try testing.expectError(error.InvalidColor, fx.ed.setMarkColor(3, ""));
    try fx.expectSource("==word==\n");
}

test "a highlight across two blocks becomes two highlights the palette can reach" {
    // The observation this whole per-block cut came from. A selection crossing
    // a blank line used to produce `==one two\n\nthree four==`, which is not a
    // highlight — so `setMarkColor` correctly refused, because there was no
    // mark for it to colour. Now there are two, and each one is a caret away.
    var fx = try Fixture.initWith("one two\n\nthree four\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    try fx.ed.toggleInline(Span.init(0, 19), .mark);
    try fx.expectSource("==one two==\n\n==three four==\n");

    // Inside the first: `start + 2`, the `==` being two bytes.
    try fx.ed.setMarkColor(2, "red");
    try fx.expectSource("==\u{1F534} one two==\n\n==three four==\n");

    // And inside the second, whose start the first colour has moved along by
    // the four-byte emoji and its space.
    try fx.ed.setMarkColor(20, "purple");
    try fx.expectSource("==\u{1F534} one two==\n\n==\u{1F7E3} three four==\n");
}

test "setMarkColor: unsupported where the config spells no colour, or the format doesn't" {
    // `highlight` alone: the mark is authorable, the colour is not — the emoji
    // would be the first character of the highlighted text.
    var hi = try Fixture.initWith("==word==\n", .markdown, &highlight_cfg);
    defer hi.deinit();
    try testing.expectError(error.UnsupportedFormat, hi.ed.setMarkColor(3, "red"));
    try hi.expectSource("==word==\n");

    // Djot authors a mark but spells its colour as an attribute, not a prefix.
    var dj = try Fixture.init("{=word=}\n", .djot);
    defer dj.deinit();
    try testing.expectError(error.UnsupportedFormat, dj.ed.setMarkColor(3, "red"));

    // And clearing is refused the same way: an unsupported format is not a
    // format where the answer happens to be "no colour".
    try testing.expectError(error.UnsupportedFormat, dj.ed.setMarkColor(3, null));
}

test "setMarkColor: a caret outside any highlight edits nothing" {
    var fx = try Fixture.initWith("a ==b== c\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.setMarkColor(0, "red"));
    try testing.expectError(error.NotEditable, fx.ed.setMarkColor(9, "red"));
    try fx.expectSource("a ==b== c\n");
    // Past the end is a range error, as everywhere else.
    try testing.expectError(error.InvalidRange, fx.ed.setMarkColor(99, "red"));
}

test "authoring a coloured highlight is the two gestures in order" {
    // The composition the API promises instead of a colour parameter on
    // `toggleInline`: wrap, then colour at an offset inside the new mark —
    // `start + 2`, the `==` being two bytes.
    var fx = try Fixture.initWith("a word b\n", .markdown, &highlight_colors_cfg);
    defer fx.deinit();
    try fx.ed.toggleInline(Span.init(2, 6), .mark);
    try fx.expectSource("a ==word== b\n");
    try fx.ed.setMarkColor(4, "purple");
    try fx.expectSource("a ==\u{1F7E3} word== b\n");
    try testing.expectEqualStrings("purple", markColor(&fx).?);

    // And un-highlighting takes the colour with it: the emoji was never text.
    // The interior now starts after the prefix — `a ` + `==` + the four-byte
    // emoji + its space — which is where the reparse reports the content.
    try fx.ed.toggleInline(Span.init(9, 13), .mark);
    try fx.expectSource("a word b\n");
    try testing.expect(fx.find(.{ .mark = .mark }) == null);
}

test "Editor.supports: the inline gates move with the parse config, in both directions" {
    const plain = format.syntaxFor(.markdown);
    const hi = format.syntaxForConfig(.markdown, &highlight_cfg);
    const colors = format.syntaxForConfig(.markdown, &highlight_colors_cfg);
    const strict = format.syntaxFor(.commonmark);

    // Strikethrough defaults ON, so the DEFAULT answer is yes and turning the
    // extension off is what makes it no — the opposite direction from the
    // highlight below, and the reason this is a table per config rather than a
    // list of opt-in extras.
    try testing.expect(Editor.supports(plain, .{ .toggle_inline = .delete }));
    try testing.expect(Editor.supports(plain, .{ .wrap_range = .delete }));
    try testing.expect(!Editor.supports(strict, .{ .toggle_inline = .delete }));
    try testing.expect(!Editor.supports(strict, .{ .wrap_range = .delete }));
    // And what neither flag touches is untouched.
    try testing.expect(Editor.supports(strict, .{ .toggle_inline = .strong }));
    try testing.expect(!Editor.supports(strict, .{ .toggle_inline = .superscript }));
    try testing.expect(!Editor.supports(plain, .{ .toggle_inline = .superscript }));

    try testing.expect(!Editor.supports(plain, .{ .toggle_inline = .mark }));
    try testing.expect(Editor.supports(hi, .{ .toggle_inline = .mark }));
    try testing.expect(Editor.supports(colors, .{ .toggle_inline = .mark }));

    // The palette is the narrower gate: a toolbar grays it while the highlight
    // button beside it stays live.
    try testing.expect(!Editor.supports(plain, .set_mark_color));
    try testing.expect(!Editor.supports(hi, .set_mark_color));
    try testing.expect(Editor.supports(colors, .set_mark_color));

    // No other format spells a colour prefix, including the one that spells
    // every mark.
    try testing.expect(!Editor.supports(format.syntaxFor(.djot), .set_mark_color));
    try testing.expect(!Editor.supports(format.syntaxFor(.html), .set_mark_color));
    try testing.expect(!Editor.supports(format.syntaxFor(.asciidoc), .set_mark_color));
    try testing.expect(!Editor.supports(format.syntaxFor(.xml), .set_mark_color));
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

test "setBlock: a block keeps the quote it is in, and the attribute line above it" {
    // Markdown's span for a paragraph in a quote begins at its `> `, which
    // is the quote's, not the paragraph's to rewrite. Found by the gesture
    // check (`contract.gestures`): the quote was lost on the way to a heading.
    var md = try Fixture.init("> Quote\n", .markdown);
    defer md.deinit();
    try md.ed.setBlock(2, .heading, 2);
    try md.expectSource("> ## Quote\n");
    try md.ed.setBlock(5, .paragraph, 0);
    try md.expectSource("> Quote\n");
    try testing.expectEqual(@as(usize, 1), countKind(&md, .block_quote));

    // Nor anything else outside its own marker and text: a djot attribute
    // line above the block stays where it is.
    var dj = try Fixture.init("{.note}\nA paragraph.\n", .djot);
    defer dj.deinit();
    try dj.ed.setBlock(8, .heading, 2);
    try dj.expectSource("{.note}\n## A paragraph.\n");
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

test "toggle_block_container: html wraps the covered blocks in a quote the parser reads back" {
    // No line prefix to write — `<blockquote>` wraps — so the covered blocks
    // go under a fresh `block_quote` node and `renderBlock` prints it. Both
    // paragraphs, with the mark re-spelled from the tree.
    var fx = try Fixture.init("<p>a <em>b</em></p>\n<p>c</p>\n<p>d</p>\n", .html);
    defer fx.deinit();
    try toggleContainer(&fx, 3, 21, .block_quote);
    try fx.expectSource("<blockquote>\n<p>a <em>b</em></p>\n<p>c</p>\n</blockquote>\n<p>d</p>\n");
    const q = fx.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
    const ast = fx.ed.astView();
    var n: usize = 0;
    var c = ast.nodes[q].first_child;
    while (c) |id| : (c = ast.nodes[id].next_sibling) n += 1;
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(fx.find(.{ .mark = .emph }) != null);
}

test "toggle_block_container: html quote on, then off, round-trips" {
    var fx = try Fixture.init("<p>a</p>\n<p>b</p>\n", .html);
    defer fx.deinit();
    try toggleContainer(&fx, 3, 12, .block_quote);
    try fx.expectSource("<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n");
    // Off: the range reaches both of the quote's blocks, so they are printed
    // in its place.
    const src = fx.ed.sourceBytes();
    const a = std.mem.indexOf(u8, src, "a</p>").?;
    const b = std.mem.indexOf(u8, src, "b</p>").?;
    try toggleContainer(&fx, a, b + 1, .block_quote);
    try fx.expectSource("<p>a</p>\n<p>b</p>\n");
    try fx.expectNoNodeOfKind(.{ .tag = .block_quote });
}

test "toggle_block_container: html quoting part of a quote nests, and off peels one level" {
    var fx = try Fixture.init("<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n", .html);
    defer fx.deinit();
    const a = std.mem.indexOf(u8, fx.ed.sourceBytes(), "a</p>").?;
    try toggleContainer(&fx, a, a + 1, .block_quote);
    try fx.expectSource("<blockquote>\n<blockquote>\n<p>a</p>\n</blockquote>\n<p>b</p>\n</blockquote>\n");
    const a2 = std.mem.indexOf(u8, fx.ed.sourceBytes(), "a</p>").?;
    try toggleContainer(&fx, a2, a2 + 1, .block_quote);
    try fx.expectSource("<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n");
}

test "toggle_block_container: html makes each covered block an item, tight when they are paragraphs" {
    var fx = try Fixture.init("<p>a</p>\n<p>b</p>\n", .html);
    defer fx.deinit();
    try toggleContainer(&fx, 3, 12, .bullet_list);
    try fx.expectSource("<ul>\n<li>\na\n</li>\n<li>\nb\n</li>\n</ul>\n");
    const l = fx.find(.{ .tag = .bullet_list }) orelse return error.NoList;
    try testing.expect(fx.ed.astView().nodes[l].kind.bullet_list.tight);
    // Off: each item's blocks, as paragraphs again.
    const src = fx.ed.sourceBytes();
    const a = std.mem.indexOf(u8, src, "a\n").?;
    const b = std.mem.indexOf(u8, src, "b\n").?;
    try toggleContainer(&fx, a, b + 1, .bullet_list);
    try fx.expectSource("<p>a</p>\n<p>b</p>\n");
    try fx.expectNoNodeOfKind(.{ .tag = .list_item });
}

test "toggle_block_container: html converts between the list kinds in place, tightness kept" {
    var fx = try Fixture.init("<ul class=\"x\">\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n", .html);
    defer fx.deinit();
    const src = fx.ed.sourceBytes();
    const a = std.mem.indexOf(u8, src, "a</p>").?;
    const b = std.mem.indexOf(u8, src, "b</p>").?;
    try toggleContainer(&fx, a, b + 1, .ordered_list);
    try fx.expectSource("<ol class=\"x\">\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ol>\n");
    const l = fx.find(.{ .tag = .ordered_list }) orelse return error.NoList;
    try testing.expect(!fx.ed.astView().nodes[l].kind.ordered_list.tight);
    try fx.expectNoNodeOfKind(.{ .tag = .bullet_list });
    // A range reaching only one item nests a list inside it instead.
    const a2 = std.mem.indexOf(u8, fx.ed.sourceBytes(), "a</p>").?;
    try toggleContainer(&fx, a2, a2 + 1, .bullet_list);
    try testing.expect(fx.find(.{ .tag = .bullet_list }) != null);
    try testing.expect(fx.find(.{ .tag = .ordered_list }) != null);
}

test "toggle_block_container: html opens a container over an empty paragraph on a blank line" {
    var fx = try Fixture.init("<p>a</p>\n\n<p>b</p>\n", .html);
    defer fx.deinit();
    try toggleContainer(&fx, 9, 9, .ordered_list);
    try fx.expectSource("<p>a</p>\n<ol>\n<li>\n<p></p>\n</li>\n</ol>\n<p>b</p>\n");
    // The press that made it un-makes it, through the ordinary toggle-off.
    const p = std.mem.indexOf(u8, fx.ed.sourceBytes(), "<p></p>").? + 3;
    try toggleContainer(&fx, p, p, .ordered_list);
    try fx.expectSource("<p>a</p>\n<p></p>\n<p>b</p>\n");
    // And a quote, over a blank line at the end.
    var q = try Fixture.init("<p>a</p>\n\n", .html);
    defer q.deinit();
    try toggleContainer(&q, 9, 9, .block_quote);
    try q.expectSource("<p>a</p>\n<blockquote>\n<p></p>\n</blockquote>\n");
    // Inside a `<pre>` body a blank line is the listing's, not a gap: the
    // caret resolves to the code block, which is wrapped whole — the marker
    // path's rule for the same caret.
    var pre = try Fixture.init("<pre><code>x\n\ny</code></pre>\n", .html);
    defer pre.deinit();
    const inner = std.mem.indexOf(u8, pre.ed.sourceBytes(), "\n\n").? + 1;
    try toggleContainer(&pre, inner, inner, .block_quote);
    try pre.expectSource("<blockquote>\n<pre><code>x\n\ny</code></pre>\n</blockquote>\n");
}

test "toggle_block_container: html takes an empty container back off" {
    var fx = try Fixture.init("<p>a</p>\n<blockquote></blockquote>\n", .html);
    defer fx.deinit();
    const inner = std.mem.indexOf(u8, fx.ed.sourceBytes(), "</blockquote>").?;
    try toggleContainer(&fx, inner, inner, .block_quote);
    try fx.expectSource("<p>a</p>\n\n");
    var li = try Fixture.init("<ul><li></li></ul>\n", .html);
    defer li.deinit();
    try toggleContainer(&li, 8, 8, .bullet_list);
    try li.expectSource("\n");
    // The other kind on that line is a press with nothing to do.
    var other = try Fixture.init("<ul><li></li></ul>\n", .html);
    defer other.deinit();
    try testing.expectError(error.NotEditable, toggleContainer(&other, 8, 8, .block_quote));
}

test "setBlock: html builds the heading and prints it, inline content and attributes along" {
    // No marker to rewrite — `<h2>` carries its level in both ends — so the
    // paragraph's children go under a fresh heading node and `renderBlock`
    // spells it. The `<em>` survives because it is re-spelled from the tree,
    // and the `class` because the node's attributes ride along.
    var fx = try Fixture.init("<p class=\"lead\">hello <em>x</em></p>\n<p>two</p>\n", .html);
    defer fx.deinit();
    try fx.ed.setBlock(20, .heading, 2);
    try fx.expectSource("<h2 class=\"lead\">hello <em>x</em></h2>\n<p>two</p>\n");
    const h = fx.find(.{ .tag = .heading }) orelse return error.NoHeading;
    try testing.expectEqual(@as(u32, 2), fx.ed.astView().nodes[h].kind.heading.level);
    try testing.expect(fx.find(.{ .mark = .emph }) != null);
    // And back: the same path, printing a paragraph.
    try fx.ed.setBlock(20, .paragraph, 0);
    try fx.expectSource("<p class=\"lead\">hello <em>x</em></p>\n<p>two</p>\n");
    try fx.expectNoNodeOfKind(.{ .tag = .heading });
}

test "setBlock: html re-levels a heading in place" {
    var fx = try Fixture.init("<h1>t</h1>\n", .html);
    defer fx.deinit();
    try fx.ed.setBlock(5, .heading, 3);
    try fx.expectSource("<h3>t</h3>\n");
    try testing.expectError(error.InvalidLevel, fx.ed.setBlock(5, .heading, 7));
    try testing.expectError(error.InvalidRange, fx.ed.setBlock(99, .heading, 1));
}

test "setBlock: html opens an empty heading on a blank line, and nothing inside a leaf" {
    var fx = try Fixture.init("<p>a</p>\n\n<p>b</p>\n", .html);
    defer fx.deinit();
    try fx.ed.setBlock(9, .heading, 2);
    try fx.expectSource("<p>a</p>\n<h2></h2>\n<p>b</p>\n");
    try testing.expect(fx.find(.{ .tag = .heading }) != null);
    // A paragraph on a blank line is the state it is already in.
    var blank = try Fixture.init("<p>a</p>\n\n", .html);
    defer blank.deinit();
    try blank.ed.setBlock(9, .paragraph, 0);
    try blank.expectSource("<p>a</p>\n\n");
    // A blank line inside a `<pre>` body is inside the listing, not between
    // blocks.
    var pre = try Fixture.init("<pre><code>x\n\ny</code></pre>\n", .html);
    defer pre.deinit();
    const inner = std.mem.indexOf(u8, pre.ed.sourceBytes(), "\n\n").? + 1;
    try testing.expectError(error.NotEditable, pre.ed.setBlock(inner, .heading, 1));
    try pre.expectSource("<pre><code>x\n\ny</code></pre>\n");
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

test "insertTable: a header, `rows` empty body rows and `cols` columns, after the caret's block" {
    var fx = try Fixture.init("a\n\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(0, 2, 3);
    try fx.expectSource("a\n\n|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n\nb\n");
    // A table the parser reads as one, with its header — not a paragraph of
    // pipes. That is what the delimiter row and the blank above it buy.
    try testing.expect(fx.find(.{ .tag = .table }) != null);
    const head = fx.find(.{ .tag = .row }) orelse return error.NoRow;
    try testing.expect(fx.ed.astView().nodes[head].kind.row.head);
}

test "insertTable: the blank line above keeps the header out of the paragraph" {
    // GFM reads a delimiter row against the paragraph line above it, so a table
    // written flush under `a` would take `a` for its header. The reparsed shape
    // is the assertion: `a` is still a paragraph, and the table's header is the
    // empty row this wrote.
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(0, 1, 2);
    try fx.expectSource("a\n\n|  |  |\n| --- | --- |\n|  |  |\n");
    try testing.expect(fx.find(.{ .tag = .para }) != null);
    try testing.expect(fx.find(.{ .tag = .table }) != null);
}

test "insertTable: an unterminated last line is ended before the blank above" {
    // The same line-ending as the rule's, and it matters more here: GFM reads
    // a header row out of the paragraph a table is written flush under, so
    // `a` followed directly by the delimiter row is a table whose header is
    // the paragraph.
    var fx = try Fixture.init("a", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(1, 1, 1);
    try fx.expectSource("a\n\n|  |\n| --- |\n|  |\n");
    try testing.expect(fx.find(.{ .tag = .table }) != null);
    try testing.expect(fx.find(.{ .tag = .para }) != null);
}

test "insertTable: spelled in the format's own dialect" {
    // Djot's delimiter row is unpadded; see `table edits re-spell in the
    // format's OWN dialect` for why that is a fact and not a style.
    var fx = try Fixture.init("a\n", .djot);
    defer fx.deinit();
    try fx.ed.insertTable(0, 1, 2);
    try fx.expectSource("a\n\n|  |  |\n|---|---|\n|  |  |\n");
    const head = fx.find(.{ .tag = .row }) orelse return error.NoRow;
    try testing.expect(fx.ed.astView().nodes[head].kind.row.head);
}

test "insertTable: inside a quote every line carries the marker" {
    // A rule is one line and inherits the prefix once; a table is several, and
    // a marker on the first alone would end the quote after the header.
    var fx = try Fixture.init("> a\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(2, 1, 1);
    try fx.expectSource("> a\n>\n> |  |\n> | --- |\n> |  |\n");
    try testing.expect(fx.find(.{ .tag = .table }) != null);
    // One quote, and the table is a child of it rather than a block after it.
    const quote = fx.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
    const ast = fx.ed.astView();
    var inside = false;
    var c = ast.nodes[quote].first_child;
    while (c) |id| : (c = ast.nodes[id].next_sibling) {
        if (std.meta.activeTag(ast.nodes[id].kind) == .table) inside = true;
    }
    try testing.expect(inside);
}

test "insertTable: a caret on a blank line between blocks puts the table on that line" {
    // The shared placement, so the same correction: one blank each side.
    var fx = try Fixture.init("a\n\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(2, 1, 1);
    try fx.expectSource("a\n\n|  |\n| --- |\n|  |\n\nb\n");
    try testing.expect(fx.find(.{ .tag = .table }) != null);
}

test "insertTable: an empty document is a legitimate place for one" {
    var fx = try Fixture.init("", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(0, 1, 1);
    try fx.expectSource("|  |\n| --- |\n|  |\n");
    try testing.expect(fx.find(.{ .tag = .table }) != null);
}

test "insertTable: the table it writes is one the table ops can edit" {
    // The point of going through `table_edit.emit`: what is minted is what
    // `extract` reads back, so a row can go in without a hand-typed table.
    var fx = try Fixture.init("", .markdown);
    defer fx.deinit();
    try fx.ed.insertTable(0, 1, 2);
    try fx.ed.tableInsertRow(2, true); // caret in the first header cell
    try fx.expectSource("|  |  |\n| --- | --- |\n|  |  |\n|  |  |\n");
}

test "insertTable: zero rows or zero columns is InvalidShape, and touches nothing" {
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.InvalidShape, fx.ed.insertTable(0, 0, 2));
    try testing.expectError(error.InvalidShape, fx.ed.insertTable(0, 2, 0));
    try fx.expectSource("a\n");
}

test "insertTable: a format with no table spelling refuses before it reads anything" {
    var fx = try Fixture.init("<p>ab</p>\n", .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertTable(4, 1, 1));
    try fx.expectSource("<p>ab</p>\n");
}

/// The name a reparsed container carries, wherever the format put it: its own
/// `name`, or the `class` that holds it where the format has no other place
/// (djot's fence is anonymous, AsciiDoc's open block carries a style). The
/// disjunction `Syntax.names_leaf_containers` claims, asked of a real tree.
fn expectContainerCarrying(fx: *Fixture, name: []const u8) !void {
    const ast = fx.ed.astView();
    for (ast.nodes, 0..) |n, i| {
        if (std.meta.activeTag(n.kind) != .container) continue;
        if (std.mem.eql(u8, n.kind.container.name, name)) return;
        const class = ast.attrsOf(@intCast(i)).get("class") orelse continue;
        if (std.mem.indexOf(u8, class, name) != null) return;
    }
    return error.NoContainerCarryingTheName;
}

test "insertDirective: a named leaf container of its own, after the caret's block" {
    var fx = try Fixture.initWith("a\n\nb\n", .markdown, &directives_cfg);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{});
    try fx.expectSource("a\n\n::page-break\n\nb\n");
    // A directive to the parser, not a paragraph that starts with two colons —
    // which is what the same bytes are without the extension, and the whole
    // reason the gate exists.
    const id = fx.find(.{ .container_named = "page-break" }) orelse return error.NoDirective;
    try testing.expectEqual(AST.Form.block_leaf, fx.ed.astView().nodes[id].kind.container.form.?);
}

test "insertDirective: a caret on the blank line between blocks adds no second blank" {
    // The separator that is already there is the one the block gets; the
    // gesture writes what is missing and nothing more (`insertBlockAfter`).
    var fx = try Fixture.initWith("a\n\nb\n", .markdown, &directives_cfg);
    defer fx.deinit();
    try fx.ed.insertDirective(2, "page-break", null, &.{});
    try fx.expectSource("a\n\n::page-break\n\nb\n");
    try testing.expect(fx.find(.{ .container_named = "page-break" }) != null);
}

test "insertDirective: an unterminated last line is ended before the blank" {
    var fx = try Fixture.initWith("a", .markdown, &directives_cfg);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{});
    try fx.expectSource("a\n\n::page-break\n");
    try testing.expect(fx.find(.{ .container_named = "page-break" }) != null);
}

test "insertDirective: inside a quote every line carries the marker" {
    var md = try Fixture.initWith("> a\n", .markdown, &directives_cfg);
    defer md.deinit();
    try md.ed.insertDirective(2, "page-break", null, &.{});
    try md.expectSource("> a\n>\n> ::page-break\n");
    try testing.expect(md.find(.{ .container_named = "page-break" }) != null);

    // Djot's spelling is TWO lines, which is the case a prefix written once
    // would get wrong: a marker on the opener alone ends the quote before the
    // closing fence, leaving `:::` outside it as a block of its own.
    var dj = try Fixture.init("> a\n", .djot);
    defer dj.deinit();
    try dj.ed.insertDirective(2, "page-break", null, &.{});
    try dj.expectSource("> a\n>\n> ::: page-break\n> :::\n");
    const quote = dj.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
    const ast = dj.ed.astView();
    var inside = false;
    var c = ast.nodes[quote].first_child;
    while (c) |id| : (c = ast.nodes[id].next_sibling) {
        if (std.meta.activeTag(ast.nodes[id].kind) == .container) inside = true;
    }
    try testing.expect(inside);
}

test "insertDirective: an empty document is a legitimate place for one" {
    var fx = try Fixture.initWith("", .markdown, &directives_cfg);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{});
    try fx.expectSource("::page-break\n");
    try testing.expect(fx.find(.{ .container_named = "page-break" }) != null);
}

test "insertDirective: a label and attributes ride into the format's own spelling" {
    var fx = try Fixture.initWith("a\n", .markdown, &directives_cfg);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "embed", "Contents", &.{.{ .key = "src", .value = "x.html" }});
    // The serializer quotes a value it cannot read back bare; the assertion is
    // its spelling, not a second guess at one.
    try fx.expectSource("a\n\n::embed[Contents]{src=\"x.html\"}\n");
    const id = fx.find(.{ .container_named = "embed" }) orelse return error.NoDirective;
    const ast = fx.ed.astView();
    try testing.expectEqualStrings("x.html", ast.attrsOf(id).get("src").?);
    // The label is the container's inline children, which is where the
    // brackets printed it from.
    const child = ast.nodes[id].first_child orelse return error.NoLabel;
    try testing.expectEqualStrings("Contents", ast.nodes[child].kind.str);
}

test "insertDirective: without the directives extension Markdown refuses, and touches nothing" {
    // The gate's whole point: these bytes reparse as a paragraph of colons
    // there, so writing them would be a gesture the document cannot hold.
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertDirective(0, "page-break", null, &.{}));
    try fx.expectSource("a\n");

    var cm = try Fixture.init("a\n", .commonmark);
    defer cm.deinit();
    try testing.expectError(error.UnsupportedFormat, cm.ed.insertDirective(0, "page-break", null, &.{}));
    try cm.expectSource("a\n");
}

test "insertDirective: djot spells an empty fence, whose name comes back as a class" {
    var fx = try Fixture.init("a\n", .djot);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{});
    try fx.expectSource("a\n\n::: page-break\n:::\n");
    // Djot's div is ANONYMOUS — it carries its identity as a class — so the
    // reparsed container is nameless and the class is where the name is. That
    // is the caveat `Syntax.names_leaf_containers` states.
    try expectContainerCarrying(&fx, "page-break");
    const id = fx.find(.{ .tag = .container }) orelse return error.NoContainer;
    try testing.expectEqualStrings("", fx.ed.astView().nodes[id].kind.container.name);
}

test "insertDirective: HTML spells a tag pair its parser names" {
    var fx = try Fixture.init("<p>a</p>\n", .html);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{});
    try fx.expectSource("<p>a</p>\n\n<page-break></page-break>\n");
    // An unknown element is a container named for its tag — no table needed,
    // which is why HTML claims the field while spelling no directive syntax.
    try testing.expect(fx.find(.{ .container_named = "page-break" }) != null);
}

test "insertDirective: AsciiDoc writes the spelling it has, and an open block where it has none" {
    // `page-break` is a name AsciiDoc spells natively — `<<<` — and the
    // serializer writes that rather than a generic block. The gesture does not
    // know or care: it hands the node over and splices what comes back.
    var fx = try Fixture.init("a\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{});
    try fx.expectSource("a\n\n<<<\n");
    try testing.expect(fx.find(.{ .container_named = "page-break" }) != null);

    // A name it has no spelling for becomes an open block carrying the name as
    // its STYLE, which reparses as a class — djot's caveat in AsciiDoc's
    // spelling.
    var em = try Fixture.init("a\n", .asciidoc);
    defer em.deinit();
    try em.ed.insertDirective(0, "embed", null, &.{.{ .key = "src", .value = "x.html" }});
    try em.expectSource("a\n\n[embed,src=x.html]\n--\n--\n");
    try expectContainerCarrying(&em, "embed");
    const id = em.find(.{ .tag = .container }) orelse return error.NoContainer;
    try testing.expectEqualStrings("x.html", em.ed.astView().attrsOf(id).get("src").?);
}

test "insertDirective: a name outside the directive grammar is refused, and touches nothing" {
    var fx = try Fixture.initWith("a\n", .markdown, &directives_cfg);
    defer fx.deinit();
    // There is no `::` without a name, so an empty one is the caller's error
    // rather than a nameless directive.
    try testing.expectError(error.InvalidName, fx.ed.insertDirective(0, "", null, &.{}));
    // A line end would end the block inside its own opener, leaving the tail as
    // ordinary text — the same reason `insertLink` refuses one in a destination.
    try testing.expectError(error.InvalidName, fx.ed.insertDirective(0, "a\nb", null, &.{}));
    // And the three that look harmless and are not. Each one is a DIFFERENT
    // wrong document per format, which is why the grammar is checked in the
    // editor rather than left to the serializer: `::a b` is a paragraph
    // holding an INLINE directive named `a`, `::]{` is no container at all,
    // and `::1x` is a paragraph (a name starts with a letter, which is what
    // keeps `:30` from being one).
    try testing.expectError(error.InvalidName, fx.ed.insertDirective(0, "a b", null, &.{}));
    try testing.expectError(error.InvalidName, fx.ed.insertDirective(0, "]{", null, &.{}));
    try testing.expectError(error.InvalidName, fx.ed.insertDirective(0, "1x", null, &.{}));
    // A colon is the one Markdown's own `scanName` would take and djot would
    // not — `::: a:b` reparses as a paragraph — so a format-neutral gesture
    // refuses it too.
    try testing.expectError(error.InvalidName, fx.ed.insertDirective(0, "a:b", null, &.{}));
    try testing.expectError(error.InvalidRange, fx.ed.insertDirective(9, "a", null, &.{}));
    try fx.expectSource("a\n");

    // What the grammar DOES admit, in every claiming format: letters, digits,
    // `-` and `_` after a leading letter.
    for ([_]format.Format{ .djot, .html, .asciidoc }) |fmt| {
        var ok = try Fixture.init(if (fmt == .html) "<p>a</p>\n" else "a\n", fmt);
        defer ok.deinit();
        try ok.ed.insertDirective(0, "x_embed-9", null, &.{});
        try expectContainerCarrying(&ok, "x_embed-9");
    }
}

test "insertDirective: a label the brackets cannot hold is refused, and touches nothing" {
    var fx = try Fixture.initWith("a\n", .markdown, &directives_cfg);
    defer fx.deinit();
    try testing.expectError(error.InvalidLabel, fx.ed.insertDirective(0, "a", "x\ny", &.{}));
    // A bracket closes the `[…]` early: `::page-break[]]` reparses as an
    // INLINE directive with a stray `]` beside it, not as the block that was
    // asked for. Same reasoning as `insertFootnote`'s reference brackets.
    try testing.expectError(error.InvalidLabel, fx.ed.insertDirective(0, "page-break", "]", &.{}));
    try testing.expectError(error.InvalidLabel, fx.ed.insertDirective(0, "page-break", "[x", &.{}));
    try fx.expectSource("a\n");

    // An EMPTY label is legitimate, and is a different document from no label.
    try fx.ed.insertDirective(0, "note", "", &.{});
    try fx.expectSource("a\n\n::note[]\n");
    try testing.expect(fx.find(.{ .container_named = "note" }) != null);
}

test "insertDirective: AsciiDoc's native spelling keeps the name and drops the attributes" {
    // `<<<` is three characters with nowhere to hang a `src`, so the claim
    // `Syntax.names_leaf_containers` makes is the NAME's and not the
    // attributes'. Pinned here so the loss is stated rather than discovered:
    // the same name written as an open block (`insertDirective: AsciiDoc
    // writes the spelling it has`) carries them fine.
    var fx = try Fixture.init("a\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.insertDirective(0, "page-break", null, &.{.{ .key = "src", .value = "x.html" }});
    try fx.expectSource("a\n\n<<<\n");
    const id = fx.find(.{ .container_named = "page-break" }) orelse return error.NoDirective;
    try testing.expect(fx.ed.astView().attrsOf(id).get("src") == null);
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

test "insert_link: html builds the link over the selection and prints it" {
    // No `[text](dest)` alphabet — the destination lives in an attribute — so
    // the covered inline nodes go under a `link` node and `renderBlock` prints
    // it. The mark is re-spelled from the tree and the destination is read
    // back out of the attribute.
    var fx = try Fixture.init("<p>see <em>this</em> now</p>\n", .html);
    defer fx.deinit();
    const start = std.mem.indexOf(u8, fx.ed.sourceBytes(), "<em>").?;
    try insertLink(&fx, start, start + 13, "https://x.dev/a?b=c&d");
    try fx.expectSource("<p>see <a href=\"https://x.dev/a?b=c&amp;d\"><em>this</em></a> now</p>\n");
    try fx.expectLinkDest("https://x.dev/a?b=c&d");
    try testing.expect(fx.find(.{ .mark = .emph }) != null);
}

test "insert_link: html takes the covered part of a text run, and refuses a cut through anything else" {
    var fx = try Fixture.init("<p>a word b</p>\n", .html);
    defer fx.deinit();
    try insertLink(&fx, 5, 9, "d");
    try fx.expectSource("<p>a <a href=\"d\">word</a> b</p>\n");
    // Into the middle of a mark: the mark's text cannot be half a link.
    var em = try Fixture.init("<p>a <em>word</em> b</p>\n", .html);
    defer em.deinit();
    try testing.expectError(error.NotEditable, insertLink(&em, 3, 11, "d"));
    try em.expectSource("<p>a <em>word</em> b</p>\n");
    // Into a run spelling a character as an entity: a byte offset names no
    // character there, so the slice is refused rather than guessed.
    var ent = try Fixture.init("<p>a &amp; b</p>\n", .html);
    defer ent.deinit();
    try testing.expectError(error.NotEditable, insertLink(&ent, 3, 4, "d"));
    // Whole, the same run links fine.
    try insertLink(&ent, 3, 12, "d");
    try ent.expectSource("<p><a href=\"d\">a &amp; b</a></p>\n");
    // Across two paragraphs there is no inline to cover.
    var two = try Fixture.init("<p>a</p>\n<p>b</p>\n", .html);
    defer two.deinit();
    try testing.expectError(error.NotEditable, insertLink(&two, 3, 12, "d"));
}

test "insert_link: html re-points an existing link, its text and attributes kept" {
    var fx = try Fixture.init("<p><a class=\"x\" href=\"old\">t <em>e</em></a></p>\n", .html);
    defer fx.deinit();
    const t = std.mem.indexOf(u8, fx.ed.sourceBytes(), "t <em>").?;
    try insertLink(&fx, t, t + 1, "new");
    // The destination is printed first: it is the node's, and `class` an
    // attribute that rode along.
    try fx.expectSource("<p><a href=\"new\" class=\"x\">t <em>e</em></a></p>\n");
    try fx.expectLinkDest("new");
    try testing.expectEqualStrings("x", fx.ed.astView().attrsOf(fx.find(.{ .tag = .link }).?).get("class").?);
}

test "insert_link: html spells an empty selection as a link whose text is the destination" {
    var fx = try Fixture.init("<p>ab</p>\n", .html);
    defer fx.deinit();
    try insertLink(&fx, 4, 4, "https://x.dev");
    try fx.expectSource("<p>a<a href=\"https://x.dev\">https://x.dev</a>b</p>\n");
    try fx.expectLinkDest("https://x.dev");
    try testing.expectError(error.InvalidDestination, insertLink(&fx, 4, 4, "a\nb"));
}

test "insert_image: html spells the selection as alt text, the destination as src" {
    var fx = try Fixture.init("<p>a cat b</p>\n", .html);
    defer fx.deinit();
    try insertImage(&fx, 5, 8, "cat & dog.png");
    try fx.expectSource("<p>a <img alt=\"cat\" src=\"cat &amp; dog.png\"> b</p>\n");
    try fx.expectSpelled(.{ .tag = .image }, "cat & dog.png");
    var empty = try Fixture.init("<p>ab</p>\n", .html);
    defer empty.deinit();
    try insertImage(&empty, 4, 4, "c.png");
    try empty.expectSource("<p>a<img alt=\"\" src=\"c.png\">b</p>\n");
}

test "insert_link: asciidoc prints `dest[text]` through its renderer, and reads it back" {
    // The alphabet path writes `[text](dest)`, which is not AsciiDoc's shape —
    // but the serializer's is, and the render path asks it.
    var fx = try Fixture.init("see *this* now\n", .asciidoc);
    defer fx.deinit();
    try insertLink(&fx, 4, 10, "https://x.dev");
    try fx.expectLinkDest("https://x.dev");
    try testing.expect(fx.find(.{ .mark = .strong }) != null);
    var img = try Fixture.init("a cat b\n", .asciidoc);
    defer img.deinit();
    try insertImage(&img, 2, 5, "cat.png");
    try img.expectSpelled(.{ .tag = .image }, "cat.png");
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

test "insert_literal: a typed dollar stays literal under the math extension, and bare without it" {
    const typed = "$x$ and $$y$$";
    var fx = try Fixture.initWith("a \n", .markdown, &math_cfg);
    defer fx.deinit();
    try insertLiteral(&fx, 2, typed);
    try fx.expectSource("a \\$x\\$ and \\$\\$y\\$\\$\n");
    try expectVisibleText(&fx, "a " ++ typed);
    try fx.expectNoNodeOfKind(.{ .text_leaf = .inline_math });
    try fx.expectNoNodeOfKind(.{ .text_leaf = .display_math });

    // Without the extension a `$` is text, and a backslash before it would
    // only be noise in the source.
    var plain = try Fixture.init("a \n", .markdown);
    defer plain.deinit();
    try insertLiteral(&plain, 2, typed);
    try plain.expectSource("a $x$ and $$y$$\n");
    try expectVisibleText(&plain, "a " ++ typed);
}

test "insert_link: a destination shown as text keeps its dollars literal under math" {
    var fx = try Fixture.initWith("a \n", .markdown, &math_cfg);
    defer fx.deinit();
    try insertLink(&fx, 2, 2, "u$x$");
    try fx.expectLinkText("u$x$");
    try fx.expectLinkDest("u$x$");
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

test "insert_literal: html spells a literal with entities, and reads it back" {
    // No backslash to spell a literal with, so `renderText` is HTML's own:
    // the reparse decodes the entities back to the bytes that went in, and no
    // tag was minted on the way.
    // (No trailing newline: HTML's parser keeps inter-block whitespace as a
    // `str`, which would join the visible text below.)
    var fx = try Fixture.init("<p>ab</p>", .html);
    defer fx.deinit();
    const typed = "<em>x</em> & 1 < 2 \\ # *y*";
    try insertLiteral(&fx, 4, typed);
    try fx.expectSource("<p>a&lt;em&gt;x&lt;/em&gt; &amp; 1 &lt; 2 \\ # *y*b</p>");
    try expectVisibleText(&fx, "a" ++ typed ++ "b");
    try fx.expectNoNodeOfKind(.{ .mark = .emph });
}

test "insert_literal: a parse-only format spells no literal" {
    var fx = try Fixture.init("<r>ab</r>", .xml);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, insertLiteral(&fx, 3, "x"));
}

test "insert_literal: inside a code span the bytes are written as they are" {
    // A backslash inside a code span is a backslash — an escape there would
    // SHOW. The engine reports `verbatim` and the alphabet renderer writes the
    // run raw; the reparse proves the `*` is the code's text, not emphasis.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("a `cd` e\n", fmt);
        defer fx.deinit();
        try insertLiteral(&fx, 4, "*_");
        try fx.expectSource("a `c*_d` e\n");
        try fx.expectNoNodeOfKind(.{ .mark = .emph });
        const id = fx.find(.{ .text_leaf = .verbatim }) orelse return error.NoCode;
        try testing.expectEqualStrings("c*_d", fx.ed.astView().nodes[id].kind.text_leaf.text);
    }
    // A fenced body likewise, block markers included: `#` at column zero of a
    // listing is a `#`.
    var md = try Fixture.init("```\nx\n```\n", .markdown);
    defer md.deinit();
    try insertLiteral(&md, 4, "# ");
    try md.expectSource("```\n# x\n```\n");
    try md.expectNoNodeOfKind(.{ .tag = .heading });
    // And HTML still escapes there, because `<pre>` decodes entities too.
    var html = try Fixture.init("<pre><code>x</code></pre>\n", .html);
    defer html.deinit();
    try insertLiteral(&html, 11, "<b>");
    try html.expectSource("<pre><code>&lt;b&gt;x</code></pre>\n");
}

test "insert_literal: flush against a code span's delimiter is still outside it" {
    // `offset` at the opening backtick is BEFORE the span, so the `*` needs its
    // escape; the content span is what decides, not the node span.
    var fx = try Fixture.init("a `c` e\n", .markdown);
    defer fx.deinit();
    try insertLiteral(&fx, 2, "*");
    try fx.expectSource("a \\*`c` e\n");
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

test "thematic_break: an unterminated last line is ended before the blank above" {
    // A document being typed has no newline after its last line yet. The blank
    // above was written as a bare `\n`, which on such a line only terminates
    // it: `a` gained `\n---\n` flush underneath and became a setext heading —
    // the failure the previous test exists to prevent, reachable from the
    // commonest caret of all, the end of what was just typed.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("a", fmt);
        defer fx.deinit();
        try fx.ed.insertThematicBreak(1);
        const rule = if (fmt == .markdown) "---" else "* * *";
        var buf: [64]u8 = undefined;
        try fx.expectSource(try std.fmt.bufPrint(&buf, "a\n\n{s}\n", .{rule}));
        try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
        try testing.expect(fx.find(.{ .tag = .para }) != null);
        try fx.expectNoNodeOfKind(.{ .tag = .heading });
    }
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
    // this is allowed rather than refused.
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
    // and the delimiter row stops the table being a table. A node is lost.
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

test "thematic_break: a caret on a blank line between blocks puts the rule on that line" {
    // With no block owning a blank line, the rule used to go after it and
    // then add its own blank above — two blanks over the rule, one under.
    // The blank the caret sits on is a separator, and the rule takes its
    // place: one blank each side, in whichever format.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("a\n\nb\n", fmt);
        defer fx.deinit();
        try fx.ed.insertThematicBreak(2);
        const rule = if (fmt == .markdown) "---" else "* * *";
        var buf: [64]u8 = undefined;
        try fx.expectSource(try std.fmt.bufPrint(&buf, "a\n\n{s}\n\nb\n", .{rule}));
        try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
    }
}

test "thematic_break: a blank line the document ends on stays below the rule" {
    // The rule is written at the blank's start, so the blank becomes the
    // separator under it and the document still ends the way its author left
    // it. Eating the line to end on the rule would be the fold this gesture
    // does not do.
    var fx = try Fixture.init("a\n\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(2);
    try fx.expectSource("a\n\n---\n\n");
}

test "thematic_break: a blank first line takes the rule with no blank above it" {
    // What a split at a paragraph's start leaves — `\npara` with the caret on
    // the new blank — and where a consumer aiming "before the paragraph"
    // through a gesture that only knows "after" ends up. Before, `\n\n---`.
    var fx = try Fixture.init("\npara\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(0);
    try fx.expectSource("---\n\npara\n");
    try testing.expect(fx.find(.{ .tag = .thematic_break }) != null);
    try testing.expect(fx.find(.{ .tag = .para }) != null);
}

test "thematic_break: a run of blank lines is not folded, only not added to" {
    // The gesture writes what is missing and nothing more: an author's extra
    // blank lines are theirs. On the middle of three blanks the rule takes
    // that line's start, nothing is added because both neighbours are already
    // separators, and the two blanks that were below the caret are still
    // below it.
    var fx = try Fixture.init("a\n\n\n\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.insertThematicBreak(3);
    try fx.expectSource("a\n\n---\n\n\nb\n");
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

// ── join blocks ──────────────────────────────────────────────────────────────
// The inverse of the split. Every case asserts the EXACT BYTES, because what
// this gesture gets right or wrong is markup a rendering assertion cannot see —
// a `</div>` that moved, a list item's continuation indent, a heading's closing
// `#` run — and then asserts the REPARSE, because the whole claim is that two
// text blocks became one.

/// How many nodes of `tag` the reparsed tree holds. The join's claim is a claim
/// about the count: two paragraphs where there was one, one heading where there
/// was a heading and a paragraph.
fn countKind(fx: *Fixture, tag: KindTag) usize {
    var n: usize = 0;
    for (fx.ed.astView().nodes) |node| {
        if (std.meta.activeTag(node.kind) == tag) n += 1;
    }
    return n;
}

test "join_blocks: two paragraphs become one, in every format that has them" {
    var md = try Fixture.init("above\n\nbelow\n", .markdown);
    defer md.deinit();
    try md.ed.joinBlocks(7);
    try md.expectSource("above\nbelow\n");
    try testing.expectEqual(@as(usize, 1), countKind(&md, .para));

    // Djot's paragraph span covers its own trailing newline and Markdown's does
    // not, which is exactly the asymmetry the removal has to survive.
    var dj = try Fixture.init("above\n\nbelow\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(7);
    try dj.expectSource("above\nbelow\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .para));

    // AsciiDoc records no content span at all; the marker is what reconstructs
    // one, and a paragraph has none, so the block IS its content.
    var adoc = try Fixture.init("above\n\nbelow\n", .asciidoc);
    defer adoc.deinit();
    try adoc.ed.joinBlocks(7);
    try adoc.expectSource("above\nbelow\n");
    try testing.expectEqual(@as(usize, 1), countKind(&adoc, .para));
}

test "join_blocks: a marker heading is one line, so what continues it is a space" {
    var fx = try Fixture.init("# Title\n\nbelow\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(9);
    try fx.expectSource("# Title below\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&fx, .para));

    // The closing `#` run is A's TAIL: it travels past the joined text rather
    // than being left in the middle of it.
    var closed = try Fixture.init("# Title #\n\nbelow\n", .markdown);
    defer closed.deinit();
    try closed.ed.joinBlocks(11);
    try closed.expectSource("# Title below #\n");
    try testing.expectEqual(@as(usize, 1), countKind(&closed, .heading));

    var adoc = try Fixture.init("== Title\n\nbelow\n", .asciidoc);
    defer adoc.deinit();
    try adoc.ed.joinBlocks(10);
    try adoc.expectSource("== Title below\n");
    try testing.expectEqual(@as(usize, 1), countKind(&adoc, .heading));

    // Djot puts the heading in a `section`, so the two blocks' lowest common
    // ancestor is that section rather than the document — and the answer is the
    // same, which is what the LCA is for.
    var dj = try Fixture.init("# Title\n\nbelow\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(9);
    try dj.expectSource("# Title below\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&dj, .para));
}

test "join_blocks: a multi-line B joined into a marker heading becomes one line" {
    // A marker heading is ONE LINE by its own spelling, so B's own line ends
    // cannot survive into it: `# T` + `xx`/`yy` wrote `# T xx`/`yy` — a
    // heading and a paragraph, two blocks, from a gesture reporting it had
    // made one.
    var fx = try Fixture.init("# T\n\nxx\nyy\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(6);
    try fx.expectSource("# T xx yy\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&fx, .para));

    var adoc = try Fixture.init("== T\n\naa\nbb\n", .asciidoc);
    defer adoc.deinit();
    try adoc.ed.joinBlocks(7);
    try adoc.expectSource("== T aa bb\n");
    try testing.expectEqual(@as(usize, 1), countKind(&adoc, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&adoc, .para));

    // The CONTINUATION PREFIX each of B's lines sits behind goes with the line
    // end it follows — the heading's line carries its own prefix already.
    var quoted = try Fixture.init("# T\n\n> xx\n> yy\n", .markdown);
    defer quoted.deinit();
    try quoted.ed.joinBlocks(8);
    try quoted.expectSource("# T xx yy\n");
    try testing.expectEqual(@as(usize, 1), countKind(&quoted, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&quoted, .block_quote));
}

test "join_blocks: B's first line may not become A's setext underline" {
    // The one line-start construct that rewrites the block ABOVE it instead of
    // opening one of its own. `above` + `===` wrote `above\n===\n`, which
    // reparses as a heading and no paragraph at all — B's text became A's
    // spelling, and the caller's two paragraphs became one heading.
    var fx = try Fixture.init("above\n\n===\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(8);
    try fx.expectSource("above\n\\===\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .para));
    try testing.expectEqual(@as(usize, 0), countKind(&fx, .heading));

    // The level-two spelling is the same trap, and `-` is also a thematic
    // break, so the escape is on the run rather than on the byte.
    var dashes = try Fixture.init("above\n\n--\n", .markdown);
    defer dashes.deinit();
    try dashes.ed.joinBlocks(8);
    try dashes.expectSource("above\n\\--\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dashes, .para));
    try testing.expectEqual(@as(usize, 0), countKind(&dashes, .heading));

    // It is B's CONTENT that lands on the new line, so a heading B whose text
    // is a run of `=` is the same trap wearing a `# ` that goes with the rest
    // of B's markup.
    var heading = try Fixture.init("above\n\n# ===\n", .markdown);
    defer heading.deinit();
    try heading.ed.joinBlocks(9);
    try heading.expectSource("above\n\\===\n");
    try testing.expectEqual(@as(usize, 1), countKind(&heading, .para));
    try testing.expectEqual(@as(usize, 0), countKind(&heading, .heading));

    // And nothing wider than that: the run is the whole test, so text that
    // merely holds an `=` keeps the bytes the caller typed.
    var ordinary = try Fixture.init("above\n\na = b\n", .markdown);
    defer ordinary.deinit();
    try ordinary.ed.joinBlocks(7);
    try ordinary.expectSource("above\na = b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&ordinary, .para));
}

test "join_blocks: A's tail carries closing markup, never separator lines" {
    // A Markdown `block_quote`'s span covers its own trailing marker lines, so
    // the tail of `a` in `> a\n>\n` is `"\n>\n"` — which is not closing markup
    // at all. Written past the joined text it left a stray `>` line below it,
    // and a second join piled up another.
    var fx = try Fixture.init("> a\n>\n\n> b\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(8);
    try fx.expectSource("> a\n> b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .block_quote));
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .para));

    // Several of them, and one with trailing space: every trailing line that
    // only separates goes, and the whole LINE goes — a byte-wise trim over the
    // same alphabet would eat the `>` that closes a `</div>`.
    var several = try Fixture.init("> a\n>\n> \n\nb\n", .markdown);
    defer several.deinit();
    try several.ed.joinBlocks(10);
    try several.expectSource("> a\n> b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&several, .para));

    // djot's `section` ends at its last child, so A's tail there is the line
    // end of its own last line and nothing more. Two blocks under ONE section,
    // where the heading that was B used to be copied out past the joined text
    // as well as left where it stood.
    var dj = try Fixture.init("# H\n\npara\n\n# H2\n\nx\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(13);
    try dj.expectSource("# H\n\npara\nH2\n\nx\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .section));
    try testing.expectEqual(@as(usize, 2), countKind(&dj, .para));
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .heading));

    // And the same two sections with nothing between the headings.
    var headings = try Fixture.init("# alpha\n\n# beta\n", .djot);
    defer headings.deinit();
    try headings.ed.joinBlocks(9);
    try headings.expectSource("# alpha beta\n");
    try testing.expectEqual(@as(usize, 1), countKind(&headings, .section));
    try testing.expectEqual(@as(usize, 1), countKind(&headings, .heading));
}

test "join_blocks: a setext heading A carries its underline past the joined text" {
    // Its content may already span lines, so it takes the line end like a
    // paragraph — and the `===` is tail, which is what keeps the result a
    // heading instead of leaving the underline over the wrong half.
    var fx = try Fixture.init("Title\n===\n\nbelow\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(11);
    try fx.expectSource("Title\nbelow\n===\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&fx, .para));
}

test "join_blocks: B's markers go, and the joined text takes A's presentation" {
    // A heading joined UPWARD into a paragraph is a paragraph: the marker is
    // B's own opening markup, and everything between A's block and B's content
    // vanishes.
    var fx = try Fixture.init("above\n\n# Title\n\nafter\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(9);
    try fx.expectSource("above\nTitle\n\nafter\n");
    try testing.expectEqual(@as(usize, 0), countKind(&fx, .heading));
    try testing.expectEqual(@as(usize, 2), countKind(&fx, .para));

    // Djot's attribute line is B's markup too, so it goes with the marker it
    // would otherwise re-attach to A's text.
    var dj = try Fixture.init("above\n\n{.center}\nhello\n\nbelow\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(17);
    try dj.expectSource("above\nhello\n\nbelow\n");
    try testing.expectEqual(@as(usize, 2), countKind(&dj, .para));

    // The other direction: B is the plain one, and A KEEPS its attributes.
    var into = try Fixture.init("above\n\n{.center}\nhello\n\nbelow\n", .djot);
    defer into.deinit();
    try into.ed.joinBlocks(24);
    try into.expectSource("above\n\n{.center}\nhello\nbelow\n");
    try testing.expectEqual(@as(usize, 2), countKind(&into, .para));

    // AsciiDoc puts B's metadata INSIDE B's own span and records no content
    // span to divide it from the text, so the whole span came through as
    // content and `[.lead]` landed in the joined paragraph as literal text.
    // The inline children are where the text is when no span table says.
    var attr = try Fixture.init("above\n\n[.lead]\nbelow\n", .asciidoc);
    defer attr.deinit();
    try attr.ed.joinBlocks(15);
    try attr.expectSource("above\nbelow\n");
    try testing.expectEqual(@as(usize, 1), countKind(&attr, .para));

    // A block TITLE is the same shape and the same answer.
    var title = try Fixture.init("above\n\n.Cap\nbelow\n", .asciidoc);
    defer title.deinit();
    try title.ed.joinBlocks(12);
    try title.expectSource("above\nbelow\n");
    try testing.expectEqual(@as(usize, 1), countKind(&title, .para));
}

test "join_blocks: the container prefix is what keeps the joined line inside" {
    // A quote repeats its marker; there is no lazy continuation in djot, and
    // Markdown's would end the quote at the joined line in the general case.
    var quote = try Fixture.init("> a\n\n> b\n", .markdown);
    defer quote.deinit();
    try quote.ed.joinBlocks(7);
    try quote.expectSource("> a\n> b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&quote, .block_quote));
    try testing.expectEqual(@as(usize, 1), countKind(&quote, .para));

    // Two paragraphs of ONE quote: the LCA is the quote itself, so nothing of
    // its markup travels.
    var inside = try Fixture.init("> a\n>\n> b\n", .markdown);
    defer inside.deinit();
    try inside.ed.joinBlocks(8);
    try inside.expectSource("> a\n> b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&inside, .para));

    // A list item's marker is NOT repeated — repeating it would open a second
    // item — so what the continuation carries is the marker's width in spaces.
    var bullet = try Fixture.init("- a\n- b\n", .markdown);
    defer bullet.deinit();
    try bullet.ed.joinBlocks(6);
    try bullet.expectSource("- a\n  b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&bullet, .list_item));

    var dj = try Fixture.init("- a\n- b\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(6);
    try dj.expectSource("- a\n  b\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .list_item));

    // A paragraph joined INTO a one-item list lands inside the item, indented
    // to the item's content column — three for `1. `, two for `- `.
    var after_bullet = try Fixture.init("- a\n\nbelow\n", .markdown);
    defer after_bullet.deinit();
    try after_bullet.ed.joinBlocks(5);
    try after_bullet.expectSource("- a\n  below\n");
    try testing.expectEqual(@as(usize, 1), countKind(&after_bullet, .list_item));

    var after_ordered = try Fixture.init("1. a\n\nbelow\n", .markdown);
    defer after_ordered.deinit();
    try after_ordered.ed.joinBlocks(6);
    try after_ordered.expectSource("1. a\n   below\n");
    try testing.expectEqual(@as(usize, 1), countKind(&after_ordered, .list_item));
}

test "join_blocks: a delimited container's closers travel, in both directions" {
    // The case the gesture exists for. A host that joined by deleting one
    // newline here would eat the blank line the `<div>` needs and break it.
    //
    // Joining `below` UP into the div's last paragraph: A is `hello`, three
    // levels down and not a sibling of B at all, and the `</div>` A sits
    // behind is carried past the text that was pulled in.
    var into = try Fixture.initWith(
        "above\n\n<div class=\"center\">\n\nhello\n\n</div>\n\nbelow\n",
        .markdown,
        &html_elements_cfg,
    );
    defer into.deinit();
    try into.ed.joinBlocks(44);
    try into.expectSource("above\n\n<div class=\"center\">\n\nhello\nbelow\n\n</div>\n");
    try testing.expectEqual(@as(usize, 1), countKind(&into, .container));
    try testing.expectEqual(@as(usize, 2), countKind(&into, .para));

    // And out of it: B leaves the div, so the div's own closers go with B's
    // markup — B was the only thing in it.
    var out_of = try Fixture.initWith(
        "above\n\n<div class=\"center\">\n\nhello\n\n</div>\n\nbelow\n",
        .markdown,
        &html_elements_cfg,
    );
    defer out_of.deinit();
    try out_of.ed.joinBlocks(29);
    try out_of.expectSource("above\nhello\n\nbelow\n");
    try testing.expectEqual(@as(usize, 0), countKind(&out_of, .container));
    try testing.expectEqual(@as(usize, 2), countKind(&out_of, .para));

    // Djot spells the same shape with a fence. Its `:::` line is A's tail here,
    // and the document keeps the line terminator B's removal took with it.
    var dj = try Fixture.init("::: note\nhello\n:::\n\nbelow\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(20);
    try dj.expectSource("::: note\nhello\nbelow\n:::\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .container));
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .para));
}

test "join_blocks: inside a delimited container, only the last block may leave" {
    const src = "above\n\n<div class=\"center\">\n\nhello\n\nworld\n\n</div>\n";

    // `hello` is the FIRST of two: pulling it out would have to move the div's
    // closers up past `world`, which is still inside. The one shape the gesture
    // refuses rather than guesses at.
    var first = try Fixture.initWith(src, .markdown, &html_elements_cfg);
    defer first.deinit();
    try testing.expectError(error.NotEditable, first.ed.joinBlocks(29));
    try first.expectSource(src);

    // `world` is the last, so it joins into `hello` and the div stays whole —
    // the LCA is the div itself, so none of its markup travels at all.
    var last = try Fixture.initWith(src, .markdown, &html_elements_cfg);
    defer last.deinit();
    try last.ed.joinBlocks(36);
    try last.expectSource("above\n\n<div class=\"center\">\n\nhello\nworld\n\n</div>\n");
    try testing.expectEqual(@as(usize, 1), countKind(&last, .container));
    try testing.expectEqual(@as(usize, 2), countKind(&last, .para));
}

test "join_blocks: a gap it cannot see across is refused, not destroyed" {
    // Everything between A and B that is on neither chain is destroyed by the
    // splice, and neither walk that finds them can see all of it.
    //
    // A Markdown LINK REFERENCE DEFINITION is not a node — the parser keeps it
    // as a lookup table — so no tree walk could be written that sees one. This
    // joined to `alpha\nbeta\n` and took the definition, and every link that
    // resolved through it, with it.
    const ref = "alpha\n\n[ref]: /zed\n\nbeta\n";
    var ref_fx = try Fixture.init(ref, .markdown);
    defer ref_fx.deinit();
    try testing.expectError(error.NotEditable, ref_fx.ed.joinBlocks(20));
    try ref_fx.expectSource(ref);

    const note = "alpha\n\n[^n]: note\n\nbeta\n";
    var note_fx = try Fixture.init(note, .markdown);
    defer note_fx.deinit();
    try testing.expectError(error.NotEditable, note_fx.ed.joinBlocks(19));
    try note_fx.expectSource(note);

    // A djot CAPTION is dropped by the parser rather than recorded, which is
    // the same position from the other side: bytes with no node over them.
    const caption = "alpha\n\n^ caption\n\nbeta\n";
    var caption_fx = try Fixture.init(caption, .djot);
    defer caption_fx.deinit();
    try testing.expectError(error.NotEditable, caption_fx.ed.joinBlocks(18));
    try caption_fx.expectSource(caption);

    // The other half: a container HOLDING NO LEAF BLOCK is in the tree, and
    // `precedingLeafBlock` steps straight over it looking for text.
    const div = "alpha\n\n<div>\n\n</div>\n\nbeta\n";
    var div_fx = try Fixture.initWith(div, .markdown, &html_elements_cfg);
    defer div_fx.deinit();
    try testing.expectError(error.NotEditable, div_fx.ed.joinBlocks(22));
    try div_fx.expectSource(div);

    const fence = "alpha\n\n:::\n:::\n\nbeta\n";
    var fence_fx = try Fixture.init(fence, .djot);
    defer fence_fx.deinit();
    try testing.expectError(error.NotEditable, fence_fx.ed.joinBlocks(16));
    try fence_fx.expectSource(fence);

    // An empty QUOTE is why the guard is not bytes alone: `>` is exactly what
    // a quote holding both blocks puts between its own paragraphs, so these
    // gap bytes are indistinguishable from the ones the test above joins
    // across. The tree tells them apart.
    const quote = "alpha\n\n>\n\nbeta\n";
    var quote_fx = try Fixture.init(quote, .markdown);
    defer quote_fx.deinit();
    try testing.expectError(error.NotEditable, quote_fx.ed.joinBlocks(10));
    try quote_fx.expectSource(quote);

    const bullet = "alpha\n\n-\n\nbeta\n";
    var bullet_fx = try Fixture.init(bullet, .markdown);
    defer bullet_fx.deinit();
    try testing.expectError(error.NotEditable, bullet_fx.ed.joinBlocks(10));
    try bullet_fx.expectSource(bullet);
}

test "join_blocks: a prefix container leaves what follows B where it is" {
    // A list has no closing bytes, so joining the first item's text out of it
    // does not drag the rest along — the remaining items are still a list. Two
    // items in, one item out, and the second item's text is now the first's.
    var fx = try Fixture.init("- a\n- b\n- c\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(6);
    try fx.expectSource("- a\n  b\n- c\n");
    try testing.expectEqual(@as(usize, 2), countKind(&fx, .list_item));
}

test "join_blocks: a container closed by tags keeps B unless B is all that is in it" {
    // HTML's `<blockquote>` and `<ul>` are spelled as tag pairs, not as a
    // `container`, and a join that took B out of one with more after it
    // deleted the opening tag and left the closer. Found by the gesture check.
    var quote = try Fixture.init("<p>a</p>\n<blockquote>\n<p>b</p>\n<p>c</p>\n</blockquote>\n", .html);
    defer quote.deinit();
    try testing.expectError(error.NotEditable, quote.ed.joinBlocks(25));

    var list = try Fixture.init("<p>a</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", .html);
    defer list.deinit();
    try testing.expectError(error.NotEditable, list.ed.joinBlocks(18));
}

test "join_blocks: the rest of a prefix container is kept apart from A by a blank line" {
    // B leaves a quote that goes on after it. The quote's blank line that
    // separated B from the rest separates A from it now, and A is outside
    // the quote — so it is written at A's level, or djot's paragraph runs on
    // into the quote's lines. Found by the gesture check.
    var dj = try Fixture.init("alpha\n\n> quoted\n>\n> more\n", .djot);
    defer dj.deinit();
    try dj.ed.joinBlocks(9);
    try dj.expectSource("alpha\nquoted\n\n> more\n");
    try testing.expectEqual(@as(usize, 1), countKind(&dj, .block_quote));
    try testing.expectEqual(@as(usize, 2), countKind(&dj, .para));
}

test "join_blocks: HTML joins where it cannot split" {
    // The gate's whole point. A blank line between two `<p>`s is not what
    // separates them, so `splitBlock` refuses; a newline INSIDE a `<p>` is
    // exactly the break a join needs, and the reparse gives back one paragraph.
    var fx = try Fixture.init("<p>a</p>\n<p class=\"x\">b</p>\n", .html);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.splitBlock(4));
    try fx.ed.joinBlocks(22);
    try fx.expectSource("<p>a\nb</p>\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .para));

    // An `<h1>` records no marker, so it takes the line end rather than the
    // space a `#` heading takes — and `<h1>a\nb</h1>` is the one heading it
    // should be. This is why the space case keys on the MARKER and not on the
    // kind.
    var heading = try Fixture.init("<h1>a</h1>\n<p>b</p>\n", .html);
    defer heading.deinit();
    try heading.ed.joinBlocks(14);
    try heading.expectSource("<h1>a\nb</h1>\n");
    try testing.expectEqual(@as(usize, 1), countKind(&heading, .heading));
    try testing.expectEqual(@as(usize, 0), countKind(&heading, .para));

    // And the nesting case: `c` joins into the `<div>`'s last paragraph, so the
    // `</p>` and the `</div>` both travel past it.
    var nested = try Fixture.init("<div>\n<p>a</p>\n<p>b</p>\n</div>\n<p>c</p>\n", .html);
    defer nested.deinit();
    try nested.ed.joinBlocks(34);
    try nested.expectSource("<div>\n<p>a</p>\n<p>b\nc</p>\n</div>\n");
    try testing.expectEqual(@as(usize, 1), countKind(&nested, .container));
    try testing.expectEqual(@as(usize, 2), countKind(&nested, .para));
}

test "join_blocks: A is the leaf block above in DOCUMENT order, not the sibling" {
    // AsciiDoc puts each heading and the blocks under it in a `section`, so the
    // block above `x` is the `== Two` heading, inside the section B is in —
    // while the sibling above B's section is the FIRST section. Joining into
    // that one would pull `x` up past a heading it belongs under.
    var fx = try Fixture.init("== Title\n\nbelow\n\n== Two\n\nx\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.joinBlocks(25);
    try fx.expectSource("== Title\n\nbelow\n\n== Two x\n");
    try testing.expectEqual(@as(usize, 2), countKind(&fx, .section));
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .para));
}

test "join_blocks: a block with no text to join into is NotEditable" {
    // A code block, a rule, a table: each is a leaf block above B, and none is
    // a `para` or a `heading`. Pulling B's prose into a fence would change what
    // the fence holds; into a rule there is nowhere to put it at all.
    var code = try Fixture.init("```\nx\n```\n\nbelow\n", .markdown);
    defer code.deinit();
    try testing.expectError(error.NotEditable, code.ed.joinBlocks(11));
    try code.expectSource("```\nx\n```\n\nbelow\n");

    var rule = try Fixture.init("above\n\n***\n\nbelow\n", .markdown);
    defer rule.deinit();
    try testing.expectError(error.NotEditable, rule.ed.joinBlocks(12));
    try rule.expectSource("above\n\n***\n\nbelow\n");

    // A paragraph under a TABLE is this same refusal and not the table rule:
    // the leaf block above it is the last cell's `str`, and a `str` is neither
    // a `para` nor a `heading`. What the table rules answer is a caret INSIDE
    // one, which is the test below.
    const after_table = "| a | b |\n|---|---|\n| c | d |\n\nbelow\n";
    var below = try Fixture.init(after_table, .markdown);
    defer below.deinit();
    try testing.expectError(error.NotEditable, below.ed.joinBlocks(31));
    try below.expectSource(after_table);
}

test "join_blocks: a caret in a table is NotEditable, not NoBlock" {
    // A cell's blocks are not the document's lines. The refusal is checked on
    // the POSITION rather than on the block, because a pipe table's cell holds
    // its text with no `para` under it — so "the innermost block here" is null,
    // and the honest answer is still that this is a table.
    const src = "| a | b |\n|---|---|\n| c | d |\n";
    var fx = try Fixture.init(src, .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.joinBlocks(22));
    try fx.expectSource(src);

    // Every row of it, header included, and whichever cell: the position
    // answer does not depend on where in the grid the caret is.
    var header = try Fixture.init(src, .markdown);
    defer header.deinit();
    try testing.expectError(error.NotEditable, header.ed.joinBlocks(2));
    try testing.expectError(error.NotEditable, header.ed.joinBlocks(26));
    try header.expectSource(src);

    // And in the other format that has a grid, whose cells are spelled
    // differently and answer the same. `passesThroughTable` sits behind this
    // as a chain test rather than a position one, for a format whose cells
    // hold a `para`: none here does, so the position rule is what fires, and
    // the chain rule is the backstop that keeps the answer right if one ever
    // does.
    const adoc = "|===\na| para here\n|===\n\nbelow\n";
    var cell = try Fixture.init(adoc, .asciidoc);
    defer cell.deinit();
    try testing.expectError(error.NotEditable, cell.ed.joinBlocks(10));
    try testing.expectError(error.NotEditable, cell.ed.joinBlocks(25));
    try cell.expectSource(adoc);
}

test "join_blocks: a setext heading B is NotEditable, not silently unwritten" {
    // Its underline is how it is spelled at all, and dropping it is a rewrite
    // of the half the caller didn't point at. `setBlock` normalises one to ATX,
    // which makes this work — the same escape hatch `splitBlock` documents.
    const src = "above\n\nTitle\n===\n";
    var fx = try Fixture.init(src, .markdown);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.joinBlocks(7));
    try fx.expectSource(src);
}

test "join_blocks: the first block of a document has nothing above it" {
    var fx = try Fixture.init("above\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.joinBlocks(0));
    try fx.expectSource("above\n");

    // Including when it is nested: the div's first paragraph is the document's
    // first leaf block, so there is nothing above it to join into.
    const nested = "<div class=\"center\">\n\nhello\n\nworld\n\n</div>\n";
    var inside = try Fixture.initWith(nested, .markdown, &html_elements_cfg);
    defer inside.deinit();
    try testing.expectError(error.NoBlock, inside.ed.joinBlocks(22));
    try inside.expectSource(nested);

    // And a position no block covers at all.
    var empty = try Fixture.init("", .markdown);
    defer empty.deinit();
    try testing.expectError(error.NoBlock, empty.ed.joinBlocks(0));
}

test "join_blocks: an offset past the source is InvalidRange" {
    var fx = try Fixture.init("a\n\nb\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.InvalidRange, fx.ed.joinBlocks(99));
    try fx.expectSource("a\n\nb\n");
}

test "join_blocks: a format with no line join refuses before it reads a byte" {
    // XML spells nothing: it is parse-and-render only, and the refusal is a
    // property of the format rather than of the caret, so it holds at a
    // position with no block at all.
    const src = "<r>ab</r>";
    var fx = try Fixture.init(src, .xml);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.joinBlocks(4));
    try testing.expectError(error.UnsupportedFormat, fx.ed.joinBlocks(0));
    try fx.expectSource(src);
}

test "join_blocks: the split's inverse, round-tripped" {
    // Split a paragraph and join it back: the source is what it was. Not a
    // property the gesture promises in general (a split writes a blank line, a
    // join writes a line break, and only one of those is what the other
    // removes) but it is the shape a caret editor's Enter/Backspace pair has to
    // have for the commonest case of all.
    var fx = try Fixture.init("one two\n", .markdown);
    defer fx.deinit();
    try fx.ed.splitBlock(3);
    try fx.expectSource("one\n\ntwo\n");
    try testing.expectEqual(@as(usize, 2), countKind(&fx, .para));
    try fx.ed.joinBlocks(5);
    try fx.expectSource("one\ntwo\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .para));
}

test "join_blocks: one splice, so one undo" {
    // The whole edit is a single `commitSplice` over `[A.ce, R_end)`, which is
    // what makes it one entry in the undo stack rather than a delete and an
    // insert a caller would have to undo twice.
    var fx = try Fixture.init("above\n\nbelow\n", .markdown);
    defer fx.deinit();
    try fx.ed.joinBlocks(7);
    try fx.expectSource("above\nbelow\n");
    _ = try fx.ed.splicer.undo();
    try fx.expectSource("above\n\nbelow\n");
}

// ── move block ───────────────────────────────────────────────────────────────
// The offset-addressed move. Every case asserts the EXACT BYTES, because what
// this gesture exists for is the markup a byte move gets wrong — a `> ` that
// has to be dropped or written, a list item's continuation indent, the blank
// line that keeps a block apart from its new neighbour — and the four moves
// the harness makes over every authorable format are not repeated here.

test "move_block: a block leaves a quote and its prefixes stay behind" {
    // The paragraph, its `> `, and the `>` blank line that separated it all
    // go; what lands at the end is the paragraph alone, blank-separated.
    var fx = try Fixture.init("> a\n>\n> y\n\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.moveBlock(8, 13);
    try fx.expectSource("> a\n\nb\n\ny\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .block_quote));

    // A quote whose only paragraph leaves goes with it, however deep — the
    // inner quote here has no lines of its own once `a` is out of it.
    var sole = try Fixture.init("> > a\n>\n> b\n\nc\n", .markdown);
    defer sole.deinit();
    try sole.ed.moveBlock(4, 13);
    try sole.expectSource("> b\n\na\n\nc\n");
    try testing.expectEqual(@as(usize, 1), countKind(&sole, .block_quote));

    // A lazy continuation line carried no prefix and sheds none; the block
    // still comes out whole.
    var lazy = try Fixture.init("> a\nb\n\nc\n", .markdown);
    defer lazy.deinit();
    try lazy.ed.moveBlock(2, 9);
    try lazy.expectSource("c\n\na\nb\n");
}

test "move_block: a block entering a quote takes its prefix on every line" {
    // A fenced code block with a blank line inside: the blank is `>` and
    // every other line `> `, which is the spelling `toggleBlockContainer`
    // writes for the same block.
    var fx = try Fixture.init("```\nx\n\ny\n```\n\n> q\n", .markdown);
    defer fx.deinit();
    try fx.ed.moveBlock(4, 17);
    try fx.expectSource("> q\n>\n> ```\n> x\n>\n> y\n> ```\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .code_block));

    // `to` at the start of the quote's first paragraph is INSIDE the quote —
    // the innermost container holding the boundary — so the heading is quoted
    // and keeps its own marker behind the quote's.
    var head = try Fixture.init("# T\n\n> q\n", .markdown);
    defer head.deinit();
    try head.ed.moveBlock(2, 7);
    try head.expectSource("> # T\n>\n> q\n");
    try testing.expectEqual(@as(usize, 1), countKind(&head, .heading));
}

test "move_block: a list item's first block is the item, and an item is always a sibling" {
    // Dragging a bullet's text drags the bullet, children and all; between
    // two items of a tight list no blank is written.
    var reorder = try Fixture.init("- a\n  - b\n- c\n", .markdown);
    defer reorder.deinit();
    try reorder.ed.moveBlock(12, 0);
    try reorder.expectSource("- c\n- a\n  - b\n");

    // A nested item dropped at a sibling's boundary joins that list at that
    // level: its own indent went with the parent's prefix.
    var up = try Fixture.init("- a\n  - b\n\nc\n", .markdown);
    defer up.deinit();
    try up.ed.moveBlock(8, 0);
    try up.expectSource("- b\n- a\n\nc\n");

    // Out of its list altogether it is a one-item list, blank-separated —
    // and into a quote it is a quoted bullet.
    var out = try Fixture.init("- a\n  - b\n\nc\n", .markdown);
    defer out.deinit();
    try out.ed.moveBlock(8, 12);
    try out.expectSource("- a\n\nc\n\n- b\n");
    var quoted = try Fixture.init("- [ ] a\n\n> q\n", .markdown);
    defer quoted.deinit();
    try quoted.ed.moveBlock(6, 12);
    try quoted.expectSource("> q\n>\n> - [ ] a\n");
    try testing.expectEqual(@as(usize, 1), countKind(&quoted, .task_list_item));

    // A loose list's items stay blank-separated where a tight list's did not.
    var loose = try Fixture.init("- b\n- c\n\n- d\n", .markdown);
    defer loose.deinit();
    try loose.ed.moveBlock(10, 0);
    try loose.expectSource("- d\n\n- b\n- c\n");
}

test "move_block: a block beside an item's text is beside the item; after it, in its tail" {
    // Before an item's first block is before the ITEM, at the list's level:
    // between two items that splits the list, which is what the bytes say
    // and what a person who typed a paragraph there would get.
    var split = try Fixture.init("- x\n- z\n\ny\n", .markdown);
    defer split.deinit();
    try split.ed.moveBlock(9, 4);
    try split.expectSource("- x\n\ny\n\n- z\n");
    try testing.expectEqual(@as(usize, 2), countKind(&split, .bullet_list));

    // After the item's text is the item's tail: the continuation indent and
    // the blank line that makes it a second block of the item.
    var tail = try Fixture.init("- x\n- z\n\ny\n", .markdown);
    defer tail.deinit();
    try tail.ed.moveBlock(9, 3);
    try tail.expectSource("- x\n\n  y\n- z\n");
    try testing.expectEqual(@as(usize, 1), countKind(&tail, .bullet_list));

    // Nested: the indent composes, a quote's prefix inside it composes too.
    var nested = try Fixture.init("- a\n  - b\n\nc\n", .markdown);
    defer nested.deinit();
    try nested.ed.moveBlock(12, 9);
    try nested.expectSource("- a\n  - b\n\n    c\n");
    var in_quote = try Fixture.init("- x\n\n  > q\n\nc\n", .markdown);
    defer in_quote.deinit();
    try in_quote.ed.moveBlock(12, 9);
    try in_quote.expectSource("- x\n\n  > c\n  >\n  > q\n");

    // A table is a block like any other, and goes in whole.
    var table = try Fixture.init("- x\n\n| a |\n|---|\n| b |\n", .markdown);
    defer table.deinit();
    try table.ed.moveBlock(6, 3);
    try table.expectSource("- x\n\n  | a |\n  |---|\n  | b |\n");
    try testing.expectEqual(@as(usize, 1), countKind(&table, .table));

    // Before the first item of a list is before the list — where the block
    // already is, here, which is a move of nothing.
    var already = try Fixture.init("a\n\n- b\n", .markdown);
    defer already.deinit();
    try testing.expectError(error.InvalidArgument, already.ed.moveBlock(0, 5));
}

test "move_block: within one container it is what moveNode writes" {
    // Same lines, same order, same separators — the prefix path is a no-op
    // at the top level, and the byte move is the whole answer.
    var gesture = try Fixture.init("a\n\nb\n\nc\n", .markdown);
    defer gesture.deinit();
    try gesture.ed.moveBlock(6, 3);
    var node = try Fixture.init("a\n\nb\n\nc\n", .markdown);
    defer node.deinit();
    try node.ed.splicer.moveNodeById(node.find(.{ .tag = .para }).? + 4, node.find(.{ .tag = .para }).?, .after);
    try gesture.expectSource(node.ed.sourceBytes());
    try gesture.expectSource("a\n\nc\n\nb\n");

    // To the document's end, and to its start.
    var end = try Fixture.init("a\n\nb\n\nc\n", .markdown);
    defer end.deinit();
    try end.ed.moveBlock(0, 8);
    try end.expectSource("b\n\nc\n\na\n");
    var start = try Fixture.init("a\n\nb\n\nc\n", .markdown);
    defer start.deinit();
    try start.ed.moveBlock(6, 0);
    try start.expectSource("c\n\na\n\nb\n");

    // A document with no final line end does not gain one for a block
    // landing at its end, nor for one leaving it.
    var bare = try Fixture.init("a\n\nb", .markdown);
    defer bare.deinit();
    try bare.ed.moveBlock(0, 4);
    try bare.expectSource("b\n\na");
    try bare.ed.moveBlock(3, 0);
    try bare.expectSource("a\n\nb");
}

test "move_block: the boundary is between blocks, or the move is refused" {
    var fx = try Fixture.init("a\n\nbb cc\n\n```\ncode\n```\n", .markdown);
    defer fx.deinit();
    // Inside a paragraph's text, inside a fence's body.
    try testing.expectError(error.NotEditable, fx.ed.moveBlock(0, 5));
    try testing.expectError(error.NotEditable, fx.ed.moveBlock(0, 16));
    // Inside the block being moved, and at the boundary it already sits on —
    // before the next block, after the previous one, on the blank line.
    try testing.expectError(error.InvalidArgument, fx.ed.moveBlock(3, 4));
    try testing.expectError(error.InvalidArgument, fx.ed.moveBlock(3, 10));
    try testing.expectError(error.InvalidArgument, fx.ed.moveBlock(3, 1));
    try testing.expectError(error.InvalidArgument, fx.ed.moveBlock(3, 2));
    // Nothing on a blank line to move; nothing past the source.
    try testing.expectError(error.NoBlock, fx.ed.moveBlock(2, 0));
    try testing.expectError(error.InvalidRange, fx.ed.moveBlock(0, 99));
    try testing.expectError(error.InvalidRange, fx.ed.moveBlock(99, 0));
    try fx.expectSource("a\n\nbb cc\n\n```\ncode\n```\n");

    // A block that shares a line with another is not a run of lines.
    var shared = try Fixture.init("<p>a</p><p>b</p>\n<p>c</p>\n", .html);
    defer shared.deinit();
    try testing.expectError(error.NotEditable, shared.ed.moveBlock(12, 26));
    // A parse-only format has no blocks a caret could name.
    var xml = try Fixture.init("<r><a/><b/></r>", .xml);
    defer xml.deinit();
    try testing.expectError(error.UnsupportedFormat, xml.ed.moveBlock(3, 11));
}

test "move_block: a delimited container takes a block by its lines, and stands when emptied" {
    // A djot fence and an HTML blockquote have lines of their own; a block
    // landing inside gets no prefix and a blank line only where the format
    // has one, and a block leaving does not take the container with it — it
    // may carry attributes the move has no business dropping.
    var dj = try Fixture.init("::: note\nx\n:::\n\nb\n", .djot);
    defer dj.deinit();
    try dj.ed.moveBlock(16, 10);
    try dj.expectSource("::: note\nx\n\nb\n:::\n");
    try dj.ed.moveBlock(9, 18);
    try dj.expectSource("::: note\nb\n:::\n\nx\n");

    var html = try Fixture.init("<blockquote>\n<p>a</p>\n</blockquote>\n<p>c</p>\n", .html);
    defer html.deinit();
    try html.ed.moveBlock(40, 20);
    try html.expectSource("<blockquote>\n<p>a</p>\n<p>c</p>\n</blockquote>\n");
    try html.ed.moveBlock(17, 45);
    try html.expectSource("<blockquote>\n<p>c</p>\n</blockquote>\n<p>a</p>\n");
}

test "move_block: an HTML item carries its list's tags, and a tight item's text gains its <p>" {
    // The `<ul>`/`</ul>` are the item's spelling: an only item moved out of
    // its list takes them along rather than leaving an empty pair behind and
    // arriving as a bare `<li>`.
    var only = try Fixture.init("<ul>\n<li>\n<p>x</p>\n</li>\n</ul>\n<p>y</p>\n", .html);
    defer only.deinit();
    try only.ed.moveBlock(15, 39);
    try only.expectSource("<p>y</p>\n<ul>\n<li>\n<p>x</p>\n</li>\n</ul>\n");

    // A tight `<li>` holds its text without a `<p>`; a block joining it makes
    // the item loose, which HTML spells by wrapping the text.
    var tight = try Fixture.init("<ul>\n<li>\nx\n</li>\n<li>\nz\n</li>\n</ul>\n<p>y</p>\n", .html);
    defer tight.deinit();
    try tight.ed.moveBlock(40, 11);
    try tight.expectSource("<ul>\n<li>\n<p>x</p>\n<p>y</p>\n</li>\n<li>\nz\n</li>\n</ul>\n");
    try testing.expectEqual(@as(usize, 2), countKind(&tight, .list_item));

    // `<li>x</li>` on one line has no line after its text inside the item.
    var one_line = try Fixture.init("<ul>\n<li>x</li>\n</ul>\n<p>y</p>\n", .html);
    defer one_line.deinit();
    try testing.expectError(error.NotEditable, one_line.ed.moveBlock(26, 10));
}

test "move_block: AsciiDoc attaches a block to an item by its `+` line" {
    // In an item's tail the block sits at column zero under a `+`, not
    // behind an indent — an indented line after a blank is a literal
    // paragraph there. The `+` is a separator line, so it travels with the
    // block and is written between it and an already-attached one.
    var fx = try Fixture.init("* x\n\ny\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.moveBlock(5, 3);
    try fx.expectSource("* x\n+\ny\n");
    try testing.expectEqual(@as(usize, 1), countKind(&fx, .list_item));
    try fx.ed.moveBlock(6, 8);
    try fx.expectSource("* x\n\ny\n");

    var two = try Fixture.init("* x\n+\ny\n\nc\n", .asciidoc);
    defer two.deinit();
    try two.ed.moveBlock(10, 6);
    try two.expectSource("* x\n+\nc\n+\ny\n");

    // Its `> ` quote is a prefix container like Markdown's.
    var quote = try Fixture.init("> a\n\nc\n", .asciidoc);
    defer quote.deinit();
    try quote.ed.moveBlock(5, 2);
    try quote.expectSource("> c\n>\n> a\n");
}

test "move_block: one splice, so one undo" {
    var fx = try Fixture.init("> a\n>\n> y\n\nb\n", .markdown);
    defer fx.deinit();
    try fx.ed.moveBlock(8, 13);
    try fx.expectSource("> a\n\nb\n\ny\n");
    _ = try fx.ed.splicer.undo();
    try fx.expectSource("> a\n>\n> y\n\nb\n");
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

/// Whether the (first) code block in the reparsed tree sits inside a node of
/// `tag` — the proof a fence stayed in its container rather than ending it.
fn expectCodeWithin(fx: *Fixture, tag: KindTag, text: ?[]const u8) !void {
    const ast = fx.ed.astView();
    const cb = fx.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
    if (text) |t| try testing.expectEqualStrings(t, ast.nodes[cb].kind.code_block.text);
    const doc = &fx.ed.splicer.doc;
    const inner = doc.span(cb);
    for (ast.nodes[0..cb], 0..) |n, i| {
        if (std.meta.activeTag(n.kind) != tag) continue;
        const outer = doc.span(@intCast(i));
        if (outer.start <= inner.start and inner.end <= outer.end) return;
    }
    return error.CodeBlockOutsideContainer;
}

fn countOf(fx: *Fixture, tag: KindTag) usize {
    var n: usize = 0;
    for (fx.ed.astView().nodes) |node| {
        if (std.meta.activeTag(node.kind) == tag) n += 1;
    }
    return n;
}

/// Toggle a code block on at `on` and expect `fenced`, holding `text` inside
/// a `within`; toggle it off again at `off` and expect `source` back.
fn expectCodeRoundTrip(
    fmt: format.Format,
    source: []const u8,
    on: usize,
    fenced: []const u8,
    within: KindTag,
    text: ?[]const u8,
    off: usize,
) !void {
    errdefer std.debug.print("\n{t}: {s}", .{ fmt, source });
    var fx = try Fixture.init(source, fmt);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(on, on), null);
    try fx.expectSource(fenced);
    try expectCodeWithin(&fx, within, text);
    try fx.ed.toggleCodeBlock(Span.init(off, off), null);
    try fx.expectSource(source);
    try fx.expectNoNodeOfKind(.{ .tag = .code_block });
    // One splice each way, so one undo step each way.
    _ = try fx.ed.splicer.undo();
    try fx.expectSource(fenced);
    _ = try fx.ed.splicer.undo();
    try fx.expectSource(source);
}

test "toggleCodeBlock: inside a list item the fence sits at the item's content column" {
    // A fence at column zero would pull the item's `- ` into the code body and
    // the document would lose the item. The marker stays on the opening fence's
    // line instead, and every other line takes the item's continuation — the
    // same shape `toggleBlockContainer` writes when it wraps a list around a
    // code block.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        try expectCodeRoundTrip(fmt, "- hello\n", 4, "- ```\n  hello\n  ```\n", .list_item, "hello\n", 9);
        // Only the item the caret is in; its siblings keep their markers.
        var fx = try Fixture.init("- a\n- b\n- c\n", fmt);
        defer fx.deinit();
        try fx.ed.toggleCodeBlock(Span.init(6, 7), "zig");
        try fx.expectSource("- a\n- ```zig\n  b\n  ```\n- c\n");
        try expectCodeLang(&fx, "zig");
        try testing.expectEqual(@as(usize, 3), countOf(&fx, .list_item));
        try testing.expectEqual(@as(usize, 1), countOf(&fx, .bullet_list));
    }
}

test "toggleCodeBlock: a code block already in a list item unfences into it" {
    // The other direction from a document that arrived with one — the shape
    // wrapping a list around a code block leaves — at the offset of its text.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("- ```\n  hello\n  ```\n", fmt);
        defer fx.deinit();
        try fx.ed.toggleCodeBlock(Span.init(9, 9), null);
        try fx.expectSource("- hello\n");
        try testing.expect(fx.find(.{ .tag = .list_item }) != null);
        try fx.expectNoNodeOfKind(.{ .tag = .code_block });
    }
    // Wrap a list around a code block, then take the code block out of it.
    var fx = try Fixture.init("```\nhello\n```\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleBlockContainer(Span.init(4, 9), .bullet_list);
    try fx.expectSource("- ```\n  hello\n  ```\n");
    try fx.ed.toggleCodeBlock(Span.init(9, 9), null);
    try fx.expectSource("- hello\n");
}

test "toggleCodeBlock: ordered, nested, task and quoted items keep their columns" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        // An ordered marker is wider, and so is the continuation.
        try expectCodeRoundTrip(fmt, "1. hello\n", 4, "1. ```\n   hello\n   ```\n", .list_item, "hello\n", 10);
        try expectCodeRoundTrip(fmt, "10. hello\n", 5, "10. ```\n    hello\n    ```\n", .list_item, "hello\n", 12);
        // A nested item: both markers' columns. Djot opens a sublist only
        // after a blank line.
        if (fmt == .markdown) {
            try expectCodeRoundTrip(fmt, "- a\n  - b\n", 8, "- a\n  - ```\n    b\n    ```\n", .list_item, "b\n", 16);
        } else {
            try expectCodeRoundTrip(fmt, "- a\n\n  - b\n", 9, "- a\n\n  - ```\n    b\n    ```\n", .list_item, "b\n", 17);
        }
        try expectCodeRoundTrip(fmt, "- a\n\n  1. b\n", 10, "- a\n\n  1. ```\n     b\n     ```\n", .list_item, "b\n", 19);
        // A task item keeps its box on the fence line; the body is at the
        // item's content column, not the box's.
        try expectCodeRoundTrip(fmt, "- [ ] hello\n", 8, "- [ ] ```\n  hello\n  ```\n", .task_list_item, "hello\n", 12);
        // An item in a quote, and a quote in an item.
        try expectCodeRoundTrip(fmt, "> - a\n", 4, "> - ```\n>   a\n>   ```\n", .list_item, "a\n", 12);
        try expectCodeRoundTrip(fmt, "- > a\n", 4, "- > ```\n  > a\n  > ```\n", .block_quote, "a\n", 12);
    }
    // The task item is still one, with the code block as its child.
    var fx = try Fixture.init("- [x] hello\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(8, 8), null);
    try fx.expectSource("- [x] ```\n  hello\n  ```\n");
    const item = fx.find(.{ .tag = .task_list_item }) orelse return error.NoTaskItem;
    try testing.expect(fx.ed.astView().nodes[item].kind.task_list_item.checked);
    try expectCodeWithin(&fx, .task_list_item, "hello\n");
}

test "toggleCodeBlock: an item's later block, and a lazy line, stay in the item" {
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        // Not the item's first block: no marker on its line, so the fence
        // takes the continuation both ends.
        try expectCodeRoundTrip(fmt, "- a\n\n  b\n", 7, "- a\n\n  ```\n  b\n  ```\n", .list_item, "b\n", 12);
    }
    // A paragraph may leave its container's prefix off a continuation line; a
    // code body may not, so the lazy line is given it.
    var lazy = try Fixture.init("- a\nb\n", .markdown);
    defer lazy.deinit();
    try lazy.ed.toggleCodeBlock(Span.init(2, 2), null);
    try lazy.expectSource("- ```\n  a\n  b\n  ```\n");
    try expectCodeWithin(&lazy, .list_item, "a\nb\n");
    var quoted = try Fixture.init("> a\nb\n", .markdown);
    defer quoted.deinit();
    try quoted.ed.toggleCodeBlock(Span.init(2, 2), null);
    try quoted.expectSource("> ```\n> a\n> b\n> ```\n");
    try expectCodeWithin(&quoted, .block_quote, "a\nb\n");
}

test "toggleCodeBlock: a selection across items fences the whole list" {
    // The blocks two items share are the list's, so the list is what is
    // fenced — at its own column, where it sits whole — and comes back whole.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        var fx = try Fixture.init("- a\n- b\n\nc\n", fmt);
        defer fx.deinit();
        try fx.ed.toggleCodeBlock(Span.init(2, 7), null);
        try fx.expectSource("```\n- a\n- b\n```\n\nc\n");
        try fx.expectNoNodeOfKind(.{ .tag = .list_item });
        try fx.ed.toggleCodeBlock(Span.init(4, 4), null);
        try fx.expectSource("- a\n- b\n\nc\n");
    }
}

test "toggleCodeBlock: an indented code block in a quote dedents inside it" {
    // Its four columns are counted after the quote's own marker.
    var fx = try Fixture.init(">     code\n>     more\n", .markdown);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(6, 6), null);
    try fx.expectSource("> code\n> more\n");
    try fx.expectNoNodeOfKind(.{ .tag = .code_block });
    try testing.expect(fx.find(.{ .tag = .block_quote }) != null);
}

test "toggleCodeBlock: unfencing an item's first block never leaves its first line blank" {
    // An item whose first line is blank holds nothing past a blank line after
    // it, so what would be left on that line is taken from further down.
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        // An empty body keeps the item, empty.
        var empty = try Fixture.init("- ```\n  ```\n- b\n", fmt);
        defer empty.deinit();
        try empty.ed.toggleCodeBlock(Span.init(2, 2), null);
        try empty.expectSource("-\n- b\n");
        try testing.expectEqual(@as(usize, 2), countOf(&empty, .list_item));
        // ...and brings a block after it in the item up under the marker.
        var next = try Fixture.init("- ```\n  ```\n\n  b\n", fmt);
        defer next.deinit();
        try next.ed.toggleCodeBlock(Span.init(2, 2), null);
        try next.expectSource("-\n  b\n");
        try testing.expectEqual(@as(usize, 1), countOf(&next, .list_item));
        try testing.expect(next.find(.{ .tag = .para }).? > next.find(.{ .tag = .list_item }).?);
        // A body's leading blank lines are passed over to its first content.
        var blanks = try Fixture.init("- ```\n\n\n  a\n  ```\n", fmt);
        defer blanks.deinit();
        try blanks.ed.toggleCodeBlock(Span.init(2, 2), null);
        try blanks.expectSource("- a\n");
    }
}

test "toggleCodeBlock: a tab at an item's content column is the column, not past it" {
    // The tab reaches column four, past the item's two: the fence is written
    // at the item's column and the tab's line is left as it was. (How much of
    // the tab the body keeps is the parser's to say, not this gesture's.)
    for ([_]format.Format{ .markdown, .djot }) |fmt| {
        try expectCodeRoundTrip(fmt, "- a\n\n\tb\n", 6, "- a\n\n  ```\n\tb\n  ```\n", .list_item, null, 13);
    }
}

test "toggleCodeBlock: an asciidoc admonition's label is not a container prefix" {
    // `NOTE: ` is the paragraph's own marker, not a prefix its lines carry, so
    // the fence goes round the whole line — as it always has.
    var fx = try Fixture.init("NOTE: a\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(6, 6), null);
    try fx.expectSource("```\nNOTE: a\n```\n");
    try fx.ed.toggleCodeBlock(Span.init(4, 4), null);
    try fx.expectSource("NOTE: a\n");
}

test "toggleCodeBlock: asciidoc fences an item's attached block, not its principal text" {
    // AsciiDoc attaches a block to an item by a `+` line, at column zero; the
    // item's own first line is its principal text, where a fence is text too.
    var fx = try Fixture.init("* a\n+\nb\n", .asciidoc);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.toggleCodeBlock(Span.init(2, 2), null));
    try fx.expectSource("* a\n+\nb\n");
    try fx.ed.toggleCodeBlock(Span.init(6, 6), null);
    try fx.expectSource("* a\n+\n```\nb\n```\n");
    try expectCodeWithin(&fx, .list_item, "b");
    try fx.ed.toggleCodeBlock(Span.init(10, 10), null);
    try fx.expectSource("* a\n+\nb\n");
    try fx.expectNoNodeOfKind(.{ .tag = .code_block });
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
    var off = try Fixture.init("<p>a</p>\n<pre><code>x</code></pre>\n", .html);
    defer off.deinit();
    try testing.expectError(error.NoBlock, off.ed.setCodeLanguage(3, "zig"));
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

test "toggleCodeBlock: html makes a listing of the covered text, and a paragraph of a listing" {
    // No fence to measure — `<pre><code>` entity-escapes a body — so the
    // covered blocks' TEXT becomes a `code_block` node's payload and
    // `renderBlock` prints it. Marks are dropped, which is what a listing
    // means; the entity is decoded on the way in and re-spelled on the way
    // out.
    var fx = try Fixture.init("<p>a &lt; <em>b</em></p>\n<p>c</p>\n<p>d</p>\n", .html);
    defer fx.deinit();
    try fx.ed.toggleCodeBlock(Span.init(3, 27), "zig");
    try fx.expectSource("<pre><code class=\"language-zig\">a &lt; b\nc</code></pre>\n<p>d</p>\n");
    const cb = fx.find(.{ .tag = .code_block }) orelse return error.NoCodeBlock;
    const code = fx.ed.astView().nodes[cb].kind.code_block;
    try testing.expectEqualStrings("zig", code.lang.?);
    try testing.expectEqualStrings("a < b\nc", code.text);
    // Off: the listing's text under a paragraph, `<` and all, minting nothing.
    try fx.ed.toggleCodeBlock(Span.init(12, 12), null);
    try fx.expectSource("<p>a &lt; b\nc</p>\n<p>d</p>\n");
    try fx.expectNoNodeOfKind(.{ .tag = .code_block });
    // Plain prose toggled twice is the document it was.
    var plain = try Fixture.init("<p>x &amp; y</p>\n", .html);
    defer plain.deinit();
    try plain.ed.toggleCodeBlock(Span.init(3, 4), null);
    try plain.expectSource("<pre><code>x &amp; y</code></pre>\n");
    try plain.ed.toggleCodeBlock(Span.init(12, 12), null);
    try plain.expectSource("<p>x &amp; y</p>\n");
}

test "toggleCodeBlock: html works inside a list item, where a fence could not" {
    var fx = try Fixture.init("<ul>\n<li>\n<p>a</p>\n</li>\n</ul>\n", .html);
    defer fx.deinit();
    const a = std.mem.indexOf(u8, fx.ed.sourceBytes(), "a</p>").?;
    try fx.ed.toggleCodeBlock(Span.init(a, a + 1), null);
    try fx.expectSource("<ul>\n<li>\n<pre><code>a</code></pre>\n</li>\n</ul>\n");
    try testing.expect(fx.find(.{ .tag = .list_item }) != null);
}

test "setCodeLanguage: html retags and clears the class, attributes kept" {
    var fx = try Fixture.init("<pre id=\"x\"><code class=\"language-zig\">a &lt; b</code></pre>\n", .html);
    defer fx.deinit();
    try fx.ed.setCodeLanguage(20, "rust");
    try fx.expectSource("<pre id=\"x\"><code class=\"language-rust\">a &lt; b</code></pre>\n");
    try fx.ed.setCodeLanguage(20, null);
    try fx.expectSource("<pre id=\"x\"><code>a &lt; b</code></pre>\n");
    try testing.expect(fx.ed.astView().nodes[fx.find(.{ .tag = .code_block }).?].kind.code_block.lang == null);
    // A language is one token in every format: whitespace would split the class.
    try testing.expectError(error.InvalidLanguage, fx.ed.setCodeLanguage(20, "a b"));
    try testing.expectError(error.InvalidLanguage, fx.ed.toggleCodeBlock(Span.init(20, 20), "a\nb"));
    var off = try Fixture.init("<p>a</p>\n<pre><code>x</code></pre>\n", .html);
    defer off.deinit();
    try testing.expectError(error.NoBlock, off.ed.setCodeLanguage(3, "zig"));
}

test "code blocks: a parse-only format spells no fence and prints no fragment" {
    var fx = try Fixture.init("<r>ab</r>", .xml);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.toggleCodeBlock(Span.init(3, 5), null));
    try testing.expectError(error.UnsupportedFormat, fx.ed.setCodeLanguage(3, "zig"));
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

// ── Math ────────────────────────────────────────────────────────────────────

/// The formula of `kind` the reparse holds, or an error when there is none.
fn expectFormula(fx: *Fixture, kind: AST.TextLeafKind, formula: []const u8) !void {
    const id = fx.find(.{ .text_leaf = kind }) orelse return error.NoFormula;
    try testing.expectEqualStrings(formula, fx.ed.astView().nodes[id].kind.text_leaf.text);
}

test "insertInlineMath: Markdown under math writes $…$ at the caret" {
    var fx = try Fixture.initWith("a  b\n", .markdown, &math_cfg);
    defer fx.deinit();
    try fx.ed.insertInlineMath(2, "x^2");
    try fx.expectSource("a $x^2$ b\n");
    try expectFormula(&fx, .inline_math, "x^2");
}

test "insertInlineMath: the formula is written as it is, backslashes and all" {
    // A math body is read literally, so `insertLiteral`'s escapes would be
    // bytes of TeX: `\frac` must not become `\\frac`.
    var fx = try Fixture.initWith("a  b\n", .markdown, &math_cfg);
    defer fx.deinit();
    try fx.ed.insertInlineMath(2, "\\frac{1}{2}");
    try fx.expectSource("a $\\frac{1}{2}$ b\n");
    try expectFormula(&fx, .inline_math, "\\frac{1}{2}");
}

test "insertInlineMath: djot's run widens around a backtick in the formula" {
    var fx = try Fixture.init("a  b\n", .djot);
    defer fx.deinit();
    try fx.ed.insertInlineMath(2, "x^2");
    try fx.expectSource("a $`x^2` b\n");
    try expectFormula(&fx, .inline_math, "x^2");

    var tick = try Fixture.init("a  b\n", .djot);
    defer tick.deinit();
    try tick.ed.insertInlineMath(2, "a`b");
    try tick.expectSource("a $``a`b`` b\n");
    try expectFormula(&tick, .inline_math, "a`b");
}

test "insertInlineMath: AsciiDoc writes the stem macro" {
    var fx = try Fixture.init("a  b\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.insertInlineMath(2, "x^2");
    try fx.expectSource("a stem:[x^2] b\n");
    try expectFormula(&fx, .inline_math, "x^2");
}

test "insertInlineMath: without the math extension Markdown refuses, and touches nothing" {
    // `$x$` is four characters of text there, which is the gate's reason.
    var fx = try Fixture.init("a\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertInlineMath(0, "x"));
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertDisplayMath(0, "x"));
    try fx.expectSource("a\n");

    var html = try Fixture.init("<p>a</p>", .html);
    defer html.deinit();
    try testing.expectError(error.UnsupportedFormat, html.ed.insertInlineMath(3, "x"));
    try testing.expectError(error.UnsupportedFormat, html.ed.insertDisplayMath(3, "x"));
}

test "insertInlineMath: a formula Markdown's dollars cannot hold is refused, and touches nothing" {
    var fx = try Fixture.initWith("a  b\n", .markdown, &math_cfg);
    defer fx.deinit();
    // No empty formula, no space against either dollar, no dollar inside, no
    // line end: each prints bytes that come back as something else.
    for ([_][]const u8{ "", " x", "x ", "a$b", "a\nb" }) |f| {
        try testing.expectError(error.InvalidFormula, fx.ed.insertInlineMath(2, f));
        try fx.expectSource("a  b\n");
    }
    // Djot's run holds the same formulas as themselves.
    var dj = try Fixture.init("a  b\n", .djot);
    defer dj.deinit();
    try dj.ed.insertInlineMath(2, "a$b");
    try expectFormula(&dj, .inline_math, "a$b");
}

test "insertInlineMath: in a code span the bytes are code, so it refuses and touches nothing" {
    var fx = try Fixture.initWith("`code`\n", .markdown, &math_cfg);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.insertInlineMath(3, "x"));
    try fx.expectSource("`code`\n");

    var block = try Fixture.init("```\ncode\n```\n", .djot);
    defer block.deinit();
    try testing.expectError(error.NotEditable, block.ed.insertInlineMath(6, "x"));
    try block.expectSource("```\ncode\n```\n");
}

test "insertInlineMath: flush against a dollar Markdown pairs differently, it refuses" {
    // `$5` then the formula: the first `$` would open against the formula's
    // own, which is not the formula the gesture wrote.
    var fx = try Fixture.initWith("costs $5\n", .markdown, &math_cfg);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.insertInlineMath(8, "x"));
    try fx.expectSource("costs $5\n");
}

test "insertInlineMath: it is one edit, so one undo takes it back" {
    var fx = try Fixture.init("a  b\n", .djot);
    defer fx.deinit();
    try fx.ed.insertInlineMath(2, "x");
    _ = try fx.ed.splicer.undo();
    try fx.expectSource("a  b\n");
}

test "insertDisplayMath: a paragraph of its own after the caret's block" {
    var md = try Fixture.initWith("a\n\nb\n", .markdown, &math_cfg);
    defer md.deinit();
    try md.ed.insertDisplayMath(0, "x^2");
    try md.expectSource("a\n\n$$x^2$$\n\nb\n");
    try expectFormula(&md, .display_math, "x^2");

    var dj = try Fixture.init("a\n", .djot);
    defer dj.deinit();
    try dj.ed.insertDisplayMath(0, "x^2");
    try dj.expectSource("a\n\n$$`x^2`\n");
    try expectFormula(&dj, .display_math, "x^2");
}

test "insertDisplayMath: inside a quote every line of the formula carries the marker" {
    var fx = try Fixture.initWith("> a\n", .markdown, &math_cfg);
    defer fx.deinit();
    try fx.ed.insertDisplayMath(2, "a \\\\\nb");
    try fx.expectSource("> a\n>\n> $$a \\\\\n> b$$\n");
    try expectFormula(&fx, .display_math, "a \\\\\nb");
    // One quote, holding both paragraphs: the formula did not end it.
    const quote = fx.find(.{ .tag = .block_quote }) orelse return error.NoQuote;
    const q = fx.ed.splicer.doc.span(quote);
    try testing.expectEqual(@as(usize, 0), q.start);
    try testing.expect(q.end >= fx.ed.sourceBytes().len - 1);
}

test "insertDisplayMath: an empty document is a legitimate place for one" {
    var fx = try Fixture.initWith("", .markdown, &math_cfg);
    defer fx.deinit();
    try fx.ed.insertDisplayMath(0, "x");
    try fx.expectSource("$$x$$\n");
    try expectFormula(&fx, .display_math, "x");
}

test "insertDisplayMath: AsciiDoc reads its one spelling back inline, so it authors only that" {
    var fx = try Fixture.init("a\n", .asciidoc);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.insertDisplayMath(0, "x"));
    try fx.expectSource("a\n");
    try testing.expect(Editor.supports(format.syntaxFor(.asciidoc), .insert_inline_math));
    try testing.expect(!Editor.supports(format.syntaxFor(.asciidoc), .insert_display_math));
}

test "insertDisplayMath: a formula Markdown cannot hold is refused, and touches nothing" {
    var fx = try Fixture.initWith("a\n", .markdown, &math_cfg);
    defer fx.deinit();
    // A blank line ends the paragraph the formula sits in.
    for ([_][]const u8{ "", "a\n\nb", "a$$b" }) |f| {
        try testing.expectError(error.InvalidFormula, fx.ed.insertDisplayMath(0, f));
        try fx.expectSource("a\n");
    }
}

test "math gestures: supports follows Markdown's math flag" {
    const md = format.syntaxFor(.markdown);
    try testing.expect(!Editor.supports(md, .insert_inline_math));
    try testing.expect(!Editor.supports(md, .insert_display_math));
    const with = format.syntaxForConfig(.markdown, &math_cfg);
    try testing.expect(Editor.supports(with, .insert_inline_math));
    try testing.expect(Editor.supports(with, .insert_display_math));
    try testing.expect(Editor.supports(format.syntaxFor(.djot), .insert_display_math));
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
        .xml, .svg, .html => "<r>ab</r>",
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
        .set_mark_color,
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
        .join_blocks,
        .renumber_ordered_lists,
        .table_insert_row,
        .table_delete_row,
        .table_insert_column,
        .table_delete_column,
        .table_set_alignment,
        .table_move_row,
        .table_move_column,
        .insert_table,
        .insert_directive,
        .set_block_attrs,
        .wrap_range_attrs,
        .set_node_attrs,
        .move_block,
        .insert_inline_math,
        .insert_display_math,
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
        .set_mark_color => ed.setMarkColor(0, "red"),
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
        .join_blocks => ed.joinBlocks(0),
        .renumber_ordered_lists => ed.renumberOrderedLists(0),
        .table_insert_row => ed.tableInsertRow(0, true),
        .table_delete_row => ed.tableDeleteRow(0),
        .table_insert_column => ed.tableInsertColumn(0, true),
        .table_delete_column => ed.tableDeleteColumn(0),
        .table_set_alignment => ed.tableSetAlignment(0, .center),
        .table_move_row => ed.tableMoveRow(0, true),
        .table_move_column => ed.tableMoveColumn(0, true),
        .insert_table => ed.insertTable(0, 1, 1),
        .insert_directive => ed.insertDirective(0, "page-break", null, &.{}),
        .set_block_attrs => ed.setBlockAttrs(0, &.{.{ .key = "class", .value = "c" }}),
        .wrap_range_attrs => ed.wrapRangeAttrs(whole, &.{.{ .key = "class", .value = "c" }}),
        .set_node_attrs => ed.setNodeAttrs(0, &.{.{ .key = "class", .value = "c" }}),
        .move_block => ed.moveBlock(0, ed.sourceBytes().len),
        .insert_inline_math => ed.insertInlineMath(0, "x"),
        .insert_display_math => ed.insertDisplayMath(0, "x"),
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
    // The two that moved from refused to supported when the renderers landed:
    // a heading through `renderBlock`, a literal through `renderText`.
    try testing.expect(Editor.supports(html, .set_block));
    try testing.expect(Editor.supports(html, .insert_literal));
    // And the five that followed them through `renderBlock`, once the HTML
    // block-elements proposal admitted every block the parser reads back.
    try testing.expect(Editor.supports(html, .{ .toggle_block_container = .block_quote }));
    try testing.expect(Editor.supports(html, .{ .toggle_block_container = .ordered_list }));
    try testing.expect(Editor.supports(html, .toggle_code_block));
    try testing.expect(Editor.supports(html, .set_code_language));
    try testing.expect(Editor.supports(html, .insert_link));
    try testing.expect(Editor.supports(html, .insert_image));
    // What has no native HTML spelling stays refused.
    try testing.expect(!Editor.supports(html, .toggle_task_item));
    try testing.expect(!Editor.supports(html, .insert_footnote));
    // The three that used to answer nothing at all, because they consulted no
    // `Syntax` field: HTML has a table its parser reads and no table spelling to
    // write one back with, no blank-line block separation, and no numbered list
    // marker. A toolbar can gray all nine out now instead of offering an edit
    // that destroyed the table it was aimed at.
    try testing.expect(!Editor.supports(html, .table_insert_row));
    try testing.expect(!Editor.supports(html, .table_set_alignment));
    try testing.expect(!Editor.supports(html, .split_block));
    // And the one that goes the OTHER way, which is why `line_join` is a field
    // of its own rather than a second reading of `block_separator`: HTML
    // cannot be split at a blank line and CAN be joined at a newline inside a
    // `<p>`. A toolbar grays out Enter-splits-the-block here and leaves
    // Backspace-joins-it live.
    try testing.expect(Editor.supports(html, .join_blocks));
    try testing.expect(!Editor.supports(html, .renumber_ordered_lists));

    // A format that spells no prose answers false to every caret gesture, so
    // `authorable()` and `supports` agree there — the coarse predicate is only
    // ever misleading in the middle of the range. The one gesture XML does
    // support is the node-addressed one, which no caret ever asks for and
    // which `authorable()` deliberately does not count: a tree editor asks
    // `supports` for it, and a prose editor still opens XML read-only.
    try testing.expect(!format.syntaxFor(.xml).authorable());
    for (all_gestures) |g| {
        try testing.expectEqual(g == .set_node_attrs, Editor.supports(format.syntaxFor(.xml), g));
    }

    // AsciiDoc sits in the middle of the range the other way round from
    // HTML: every block gesture works, a link and an image print through its
    // renderer (`dest[text]` is no alphabet's shape, but it is a serializer's),
    // and it is the two whose shape neither can write — a footnote (one
    // macro), a table (`|===`-fenced, no delimiter row) — that a toolbar
    // grays out.
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
    try testing.expect(Editor.supports(adoc, .join_blocks));
    try testing.expect(Editor.supports(adoc, .renumber_ordered_lists));
    try testing.expect(Editor.supports(adoc, .insert_link));
    try testing.expect(Editor.supports(adoc, .insert_image));
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

// ── setBlockAttrs ──────────────────────────────────────────────────────────

const class_c = [_]AST.KeyVal{.{ .key = "class", .value = "c" }};
const size_large = [_]AST.KeyVal{.{ .key = "data-size", .value = "large" }};

test "setBlockAttrs: djot writes the attribute line before the block, rewrites it, and removes it" {
    var fx = try Fixture.init("hello _em_\n", .djot);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(0, &class_c);
    try fx.expectSource("{.c}\nhello _em_\n");
    const para = fx.find(.{ .tag = .para }).?;
    try testing.expectEqualStrings("c", fx.ed.astView().attrsOf(para).get("class").?);

    // Replace, not merge: the class goes, the size arrives; the block's own
    // bytes are untouched throughout.
    try fx.ed.setBlockAttrs(6, &size_large);
    try fx.expectSource("{data-size=\"large\"}\nhello _em_\n");
    try fx.ed.setBlockAttrs(22, &.{});
    try fx.expectSource("hello _em_\n");
    // Clearing what is already clear is a no-op.
    try fx.ed.setBlockAttrs(0, &.{});
    try fx.expectSource("hello _em_\n");
}

test "setBlockAttrs: djot carries a quote's marker onto the line, and takes it away with it" {
    var fx = try Fixture.init("> hello\n", .djot);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(3, &class_c);
    try fx.expectSource("> {.c}\n> hello\n");
    try fx.ed.setBlockAttrs(10, &.{});
    try fx.expectSource("> hello\n");
}

test "setBlockAttrs: djot refuses a block that starts on a list item's marker line" {
    // The line above is the list's, not the paragraph's: a `{…}` written
    // there would attach to the list.
    var fx = try Fixture.init("- hello\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.setBlockAttrs(3, &class_c));
    try fx.expectSource("- hello\n");
}

test "setBlockAttrs: djot refuses attributes assembled from more than one block" {
    var fx = try Fixture.init("{.a}\n{.b}\nhello\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.setBlockAttrs(12, &class_c));
}

test "setNodeAttrs: XML rewrites the start tag's interior and nothing else" {
    // The children — a nested element, a comment, the whitespace text runs
    // that hold the indentation — are not re-printed: only the bytes between
    // the name and the closer move.
    var fx = try Fixture.init("<svg>\n  <g  id=\"a\"  fill='red' >\n    <rect x=\"1\"/><!-- c -->\n  </g>\n</svg>\n", .xml);
    defer fx.deinit();
    const g = fx.find(.{ .container_named = "g" }).?;
    try fx.ed.setNodeAttrs(g, &.{ .{ .key = "id", .value = "a" }, .{ .key = "transform", .value = "translate(2 3)" } });
    try fx.expectSource("<svg>\n  <g id=\"a\" transform=\"translate(2 3)\">\n    <rect x=\"1\"/><!-- c -->\n  </g>\n</svg>\n");
    const g2 = fx.find(.{ .container_named = "g" }).?;
    try testing.expectEqualStrings("translate(2 3)", fx.ed.astView().attrsOf(g2).get("transform").?);
    try testing.expect(fx.ed.astView().attrsOf(g2).get("fill") == null);

    // A self-closing element keeps its closer; a value's specials come back
    // as entities and reparse to the bytes that were asked for.
    const rect = fx.find(.{ .container_named = "rect" }).?;
    try fx.ed.setNodeAttrs(rect, &.{.{ .key = "data-note", .value = "a < b & c" }});
    try fx.expectSource("<svg>\n  <g id=\"a\" transform=\"translate(2 3)\">\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
    const rect2 = fx.find(.{ .container_named = "rect" }).?;
    try testing.expectEqualStrings("a < b & c", fx.ed.astView().attrsOf(rect2).get("data-note").?);

    // An empty set removes the run, whitespace and all; clearing an element
    // that has none is a no-op; and a first attribute lands after the name.
    try fx.ed.setNodeAttrs(fx.find(.{ .container_named = "g" }).?, &.{});
    try fx.expectSource("<svg>\n  <g>\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
    try fx.ed.setNodeAttrs(fx.find(.{ .container_named = "svg" }).?, &.{});
    try fx.expectSource("<svg>\n  <g>\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
    try fx.ed.setNodeAttrs(fx.find(.{ .container_named = "svg" }).?, &.{.{ .key = "viewBox", .value = "0 0 10 10" }});
    try fx.expectSource("<svg viewBox=\"0 0 10 10\">\n  <g>\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
}

test "setNodeAttrs: refuses what is not an element, an unknown id, and an attribute no format reads back" {
    var fx = try Fixture.init("<r>text<!-- c --></r>", .xml);
    defer fx.deinit();
    const text = fx.find(.{ .tag = .str }).?;
    try testing.expectError(error.NotEditable, fx.ed.setNodeAttrs(text, &class_c));
    const comment = fx.find(.{ .markup_leaf = .comment }).?;
    try testing.expectError(error.NotEditable, fx.ed.setNodeAttrs(comment, &class_c));
    const past: AST.Node.Id = @intCast(fx.ed.astView().nodes.len);
    try testing.expectError(error.InvalidRange, fx.ed.setNodeAttrs(past, &class_c));
    const r = fx.find(.{ .container_named = "r" }).?;
    try testing.expectError(error.InvalidAttribute, fx.ed.setNodeAttrs(r, &.{.{ .key = "1x", .value = "v" }}));
    try testing.expectError(error.InvalidAttribute, fx.ed.setNodeAttrs(r, &.{.{ .key = "x", .value = null }}));
    try fx.expectSource("<r>text<!-- c --></r>");
    // A prose format spells a block's attributes and not a node's: the gate
    // answers before an id is looked at.
    var md = try Fixture.init("hello\n", .djot);
    defer md.deinit();
    try testing.expectError(error.UnsupportedFormat, md.ed.setNodeAttrs(0, &class_c));
}

test "setBlockAttrs: HTML re-prints the element with the new set" {
    var fx = try Fixture.init("<p>a <em>b</em></p>\n", .html);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(4, &class_c);
    try fx.expectSource("<p class=\"c\">a <em>b</em></p>\n");
    try fx.ed.setBlockAttrs(4, &.{});
    try fx.expectSource("<p>a <em>b</em></p>\n");
}

test "setBlockAttrs: AsciiDoc writes its attribute line, and a heading keeps its level" {
    var fx = try Fixture.init("hello\n", .asciidoc);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(0, &class_c);
    try fx.expectSource("[.c]\nhello\n");
    const para = fx.find(.{ .tag = .para }).?;
    try testing.expectEqualStrings("c", fx.ed.astView().attrsOf(para).get("class").?);
    try fx.ed.setBlockAttrs(6, &.{});
    try fx.expectSource("hello\n");
}

test "setBlockAttrs: Markdown wraps the block in a div, rewrites the div, and unwraps it" {
    var fx = try Fixture.initWith("hello\n", .markdown, &html_elements_cfg);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(0, &class_c);
    try fx.expectSource("<div class=\"c\">\n\nhello\n\n</div>\n");
    // The reparse pairs the tags: a div whose sole child is the paragraph.
    const div = fx.find(.{ .container_named = "div" }).?;
    try testing.expectEqualStrings("c", fx.ed.astView().attrsOf(div).get("class").?);
    const para = fx.ed.astView().nodes[div].first_child.?;
    try testing.expect(fx.ed.astView().nodes[para].kind == .para);
    try testing.expect(fx.ed.astView().nodes[para].next_sibling == null);

    // A second call from inside the paragraph rewrites the wrapper, and
    // does not nest a second one.
    try fx.ed.setBlockAttrs(20, &size_large);
    try fx.expectSource("<div data-size=\"large\">\n\nhello\n\n</div>\n");
    try fx.ed.setBlockAttrs(26, &.{});
    try fx.expectSource("hello\n");
}

test "setBlockAttrs: Markdown's wrap carries a quote's marker on every line, the blanks included" {
    var fx = try Fixture.initWith("> hello\n", .markdown, &html_elements_cfg);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(3, &class_c);
    try fx.expectSource("> <div class=\"c\">\n>\n> hello\n>\n> </div>\n");
    try fx.ed.setBlockAttrs(22, &.{});
    try fx.expectSource("> hello\n");
}

test "setBlockAttrs: a directive-origin div is not the wrapper a block sits in" {
    // `:::div{.c}` is the author's directive; a block inside it gets a div of
    // its own rather than the directive's attributes rewritten.
    var cfg: format.ParseConfig = .{ .markdown = .{ .directives = true, .html_elements = true } };
    var fx = try Fixture.initWith(":::div{.c}\nhello\n:::\n", .markdown, &cfg);
    defer fx.deinit();
    try fx.ed.setBlockAttrs(12, &size_large);
    try fx.expectSource(":::div{.c}\n<div data-size=\"large\">\n\nhello\n\n</div>\n:::\n");
}

test "setBlockAttrs: without html_elements Markdown refuses, and touches nothing" {
    var fx = try Fixture.init("hello\n", .markdown);
    defer fx.deinit();
    try testing.expectError(error.UnsupportedFormat, fx.ed.setBlockAttrs(0, &class_c));
    try fx.expectSource("hello\n");
}

test "setBlockAttrs: the caret must be in a paragraph or heading, and the attributes must be readable" {
    var fx = try Fixture.init("", .djot);
    defer fx.deinit();
    try testing.expectError(error.NoBlock, fx.ed.setBlockAttrs(0, &class_c));
    try testing.expectError(error.InvalidRange, fx.ed.setBlockAttrs(1, &class_c));

    var dj = try Fixture.init("hello\n", .djot);
    defer dj.deinit();
    try testing.expectError(error.InvalidAttribute, dj.ed.setBlockAttrs(0, &.{.{ .key = "a b", .value = "x" }}));
    try testing.expectError(error.InvalidAttribute, dj.ed.setBlockAttrs(0, &.{.{ .key = "", .value = "x" }}));
    try testing.expectError(error.InvalidAttribute, dj.ed.setBlockAttrs(0, &.{.{ .key = "k", .value = null }}));
    try testing.expectError(error.InvalidAttribute, dj.ed.setBlockAttrs(0, &.{.{ .key = "k", .value = "a\nb" }}));
    try testing.expectError(error.InvalidAttribute, dj.ed.setBlockAttrs(0, &.{.{ .key = "k", .value = "a\"b" }}));
    try dj.expectSource("hello\n");
}

// ── wrapRangeAttrs ─────────────────────────────────────────────────────────

const class_l = [_]AST.KeyVal{.{ .key = "class", .value = "large" }};
const class_s = [_]AST.KeyVal{.{ .key = "class", .value = "small" }};

test "wrapRangeAttrs: djot brackets the range, re-styles it from inside, and unwraps it" {
    var fx = try Fixture.init("a big _text_ b\n", .djot);
    defer fx.deinit();
    try fx.ed.wrapRangeAttrs(Span.init(2, 12), &class_l);
    try fx.expectSource("a [big _text_]{.large} b\n");
    const span = fx.find(.{ .tag = .container }).?;
    try testing.expectEqualStrings("large", fx.ed.astView().attrsOf(span).get("class").?);
    // Replace, not nest: a range inside the span re-styles the span.
    try fx.ed.wrapRangeAttrs(Span.init(4, 6), &class_s);
    try fx.expectSource("a [big _text_]{.small} b\n");
    // Unwrapping keeps the content bytes as they are.
    try fx.ed.wrapRangeAttrs(Span.init(4, 6), &.{});
    try fx.expectSource("a big _text_ b\n");
}

test "wrapRangeAttrs: HTML and Markdown spell a span, and read the name back as the same node" {
    var h = try Fixture.init("<p>a big b</p>\n", .html);
    defer h.deinit();
    try h.ed.wrapRangeAttrs(Span.init(5, 8), &class_l);
    try h.expectSource("<p>a <span class=\"large\">big</span> b</p>\n");
    try h.ed.wrapRangeAttrs(Span.init(25, 28), &class_s);
    try h.expectSource("<p>a <span class=\"small\">big</span> b</p>\n");
    try h.ed.wrapRangeAttrs(Span.init(25, 28), &.{});
    try h.expectSource("<p>a big b</p>\n");

    var md = try Fixture.initWith("a *big* b\n", .markdown, &html_elements_cfg);
    defer md.deinit();
    try md.ed.wrapRangeAttrs(Span.init(2, 7), &class_l);
    try md.expectSource("a <span class=\"large\">*big*</span> b\n");
    const span = md.find(.{ .container_named = "span" }).?;
    try testing.expectEqualStrings("large", md.ed.astView().attrsOf(span).get("class").?);
    // The mark inside rode along.
    const em = md.ed.astView().nodes[span].first_child.?;
    try testing.expect(md.ed.astView().nodes[em].kind == .inline_mark);
    try md.ed.wrapRangeAttrs(Span.init(23, 26), &class_s);
    try md.expectSource("a <span class=\"small\">*big*</span> b\n");
    try md.ed.wrapRangeAttrs(Span.init(23, 26), &.{});
    try md.expectSource("a *big* b\n");
}

test "wrapRangeAttrs: a directive-origin :span is not the span a range re-styles" {
    var cfg: format.ParseConfig = .{ .markdown = .{ .directives = true, .html_elements = true } };
    var fx = try Fixture.initWith("a :span[big]{.a} b\n", .markdown, &cfg);
    defer fx.deinit();
    try fx.ed.wrapRangeAttrs(Span.init(8, 11), &class_l);
    try fx.expectSource("a :span[<span class=\"large\">big</span>]{.a} b\n");
}

test "wrapRangeAttrs: refused where the format does not read the span back, and touches nothing" {
    var md = try Fixture.init("a big b\n", .markdown);
    defer md.deinit();
    try testing.expectError(error.UnsupportedFormat, md.ed.wrapRangeAttrs(Span.init(2, 5), &class_l));
    try md.expectSource("a big b\n");
    var adoc = try Fixture.init("a big b\n", .asciidoc);
    defer adoc.deinit();
    try testing.expectError(error.UnsupportedFormat, adoc.ed.wrapRangeAttrs(Span.init(2, 5), &class_l));
}

test "wrapRangeAttrs: an empty range with no span to re-style, a bad range, a bad attribute" {
    var fx = try Fixture.init("a big b\n", .djot);
    defer fx.deinit();
    try testing.expectError(error.NotEditable, fx.ed.wrapRangeAttrs(Span.init(2, 2), &class_l));
    try testing.expectError(error.InvalidRange, fx.ed.wrapRangeAttrs(Span.init(5, 2), &class_l));
    try testing.expectError(error.InvalidRange, fx.ed.wrapRangeAttrs(Span.init(0, 99), &class_l));
    try testing.expectError(error.InvalidAttribute, fx.ed.wrapRangeAttrs(Span.init(2, 5), &.{.{ .key = "k", .value = null }}));
    try fx.expectSource("a big b\n");
}

test "move_block: a boundary that closes a container is read outside it for the block that closes it" {
    // The last block of a quote dropped at its own end — the one offset that
    // is both after it and after the quote — leaves the quote; and dropped
    // on the blank line after a quote it was the only content of, where the
    // lines that go with it include that blank.
    var last = try Fixture.init("x\n\n> a\n>\n> b\n\ny\n", .markdown);
    defer last.deinit();
    try last.ed.moveBlock(11, 12);
    try last.expectSource("x\n\n> a\n\nb\n\ny\n");
    var sole = try Fixture.init("> b\n\ny\n", .markdown);
    defer sole.deinit();
    try sole.ed.moveBlock(2, 4);
    try sole.expectSource("b\n\ny\n");
    try testing.expectEqual(@as(usize, 0), countKind(&sole, .block_quote));

    // The same for a nested quote's first block at its own start, and for
    // the last block of an item's tail and the last item of a list — a
    // sibling, so a one-item list of its own.
    var first = try Fixture.init("> > a\n", .markdown);
    defer first.deinit();
    try first.ed.moveBlock(4, 4);
    try first.expectSource("> a\n");
    var tail = try Fixture.init("- a\n\n  c\n", .markdown);
    defer tail.deinit();
    try tail.ed.moveBlock(7, 8);
    try tail.expectSource("- a\n\nc\n");
    var item = try Fixture.init("- a\n- b\n", .markdown);
    defer item.deinit();
    try item.ed.moveBlock(6, 7);
    try item.expectSource("- a\n\n- b\n");

    // A block that does not close its container sits on nothing but its own
    // boundary there: before the second of two, after the first of two.
    var mid = try Fixture.init("x\n\n> a\n>\n> b\n", .markdown);
    defer mid.deinit();
    try testing.expectError(error.InvalidArgument, mid.ed.moveBlock(11, 9));
    try testing.expectError(error.InvalidArgument, mid.ed.moveBlock(11, 11));
    try testing.expectError(error.InvalidArgument, mid.ed.moveBlock(5, 6));
    var items = try Fixture.init("- a\n- b\n", .markdown);
    defer items.deinit();
    try testing.expectError(error.InvalidArgument, items.ed.moveBlock(2, 3));
}

test "move_block: a container's marker is before the container; its first content byte is inside" {
    // Above a quote that opens the document, which no other offset names.
    var opens = try Fixture.init("> a\n\ny\n", .markdown);
    defer opens.deinit();
    try opens.ed.moveBlock(5, 0);
    try opens.expectSource("y\n\n> a\n");

    // The marker byte and the content byte, one offset apart, are the two
    // boundaries: the block lands before the quote or in it.
    var marker = try Fixture.init("x\n\n> a\n", .markdown);
    defer marker.deinit();
    try testing.expectError(error.InvalidArgument, marker.ed.moveBlock(0, 3));
    try marker.ed.moveBlock(0, 5);
    try marker.expectSource("> x\n>\n> a\n");
    var out = try Fixture.init("x\n\n> a\n>\n> b\n", .markdown);
    defer out.deinit();
    try out.ed.moveBlock(11, 3);
    try out.expectSource("x\n\nb\n\n> a\n");

    // Nested: the outermost container opening at the offset, so `> > a` at
    // 0 is before both quotes and at 2 before the inner one alone.
    var both = try Fixture.init("> > a\n", .markdown);
    defer both.deinit();
    try both.ed.moveBlock(4, 0);
    try both.expectSource("a\n");
    var inner = try Fixture.init("> > a\n", .markdown);
    defer inner.deinit();
    try inner.ed.moveBlock(4, 2);
    try inner.expectSource("> a\n");

    // A delimited container opens at its first byte, and stands emptied.
    var html = try Fixture.init("<blockquote>\n<p>a</p>\n</blockquote>\n<p>c</p>\n", .html);
    defer html.deinit();
    try html.ed.moveBlock(17, 0);
    try html.expectSource("<p>a</p>\n<blockquote>\n</blockquote>\n<p>c</p>\n");
}

test "move_block: the source's length is the document's end, terminated or not" {
    // Behind a trailing list with no final line end, the length is the last
    // item's last byte too; it still names the end of the document.
    var bare = try Fixture.init("p\n\n- a\n- b", .markdown);
    defer bare.deinit();
    try bare.ed.moveBlock(0, 10);
    try bare.expectSource("- a\n- b\n\np");
    var quote = try Fixture.init("x\n\n> a", .markdown);
    defer quote.deinit();
    try quote.ed.moveBlock(0, 6);
    try quote.expectSource("> a\n\nx");
}
