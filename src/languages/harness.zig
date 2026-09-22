//! Registry-wide engine contracts. Corpora belong to conformance readers.
const std = @import("std");
const testing = std.testing;
const format = @import("../format.zig");
const Document = @import("../document.zig");
const Span = @import("../span.zig");
const Editor = @import("../ast/editor.zig").Editor;
const AST = @import("../ast/ast.zig");
const select = @import("../ast/select.zig");
const Syntax = @import("../syntax.zig").Syntax;

fn expectSpan(span: Span, len: usize) !void {
    try testing.expect(span.start <= span.end);
    try testing.expect(span.end <= len);
}

fn expectColumns(doc: Document) !void {
    try testing.expectEqual(doc.ast.nodes.len, doc.node_spans.len);
    try testing.expectEqual(doc.ast.nodes.len, doc.node_content_spans.len);
    try testing.expect(doc.node_spelling.len <= doc.ast.nodes.len);
    try testing.expect(doc.node_marker_spans.len <= doc.ast.nodes.len);
    try testing.expect(doc.attrs_spans.len <= doc.ast.attrs.len);
    for (doc.node_spans) |span| try expectSpan(span, doc.source.len);
    for (doc.node_content_spans) |maybe| {
        if (maybe) |span| try expectSpan(span, doc.source.len);
    }
    for (doc.node_marker_spans, 0..) |maybe, id| {
        if (maybe) |span| {
            try expectSpan(span, doc.source.len);
            // Leading markers also cover headings, quotes, and AsciiDoc admonitions.
            try testing.expect(switch (doc.ast.nodes[id].kind) {
                .list_item, .task_list_item, .definition_list_item, .heading, .block_quote => true,
                .container => |c| c.form == .block_fenced and doc.containerOrigin(@intCast(id)) == .directive,
                else => false,
            });
        }
    }
    for (doc.attrs_spans, 0..) |maybe, id| {
        if (maybe) |span| {
            try expectSpan(span, doc.source.len);
            var referenced = false;
            for (doc.ast.nodes) |node| {
                if (node.attrs) |attrs_id| {
                    if (attrs_id == id) referenced = true;
                }
            }
            try testing.expect(referenced);
        }
    }
}

fn expectSample(entry: format.Entry, sample: []const u8) !void {
    const config: format.ParseConfig = .{};
    var first = try entry.parse(&config, testing.allocator, sample);
    defer first.deinit();
    try testing.expectEqualStrings(sample, first.doc.source);
    try expectColumns(first.doc);
    if (entry.serializeCanonical) |serialize| {
        const printed = try serialize(testing.allocator, &first);
        defer testing.allocator.free(printed);
        errdefer std.debug.print("\n--- canonical output ---\n{s}\n", .{printed});
        var second = try entry.parse(&config, testing.allocator, printed);
        defer second.deinit();
        try expectColumns(second.doc);
        try testing.expect(first.doc.ast.eql(second.doc.ast));
    }
    if (entry.syntax.authorable()) {
        var editor = try Editor.init(testing.allocator, sample, &config, entry.parseToAst, entry.syntax);
        defer editor.deinit();
        try testing.expect(first.doc.ast.eql(editor.astView().*));
        try expectColumns(editor.splicer.doc);
        try editor.splicer.replaceAtSpan(Span.init(0, 0), "");
        try testing.expectEqualStrings(sample, editor.sourceBytes());
        try testing.expectEqualStrings(sample, editor.splicer.doc.source);
        try testing.expect(first.doc.ast.eql(editor.astView().*));
        try expectColumns(editor.splicer.doc);
    }
}

/// A specials run every format's literal renderer must carry across a
/// reparse: the inline metacharacters, a block opener at column zero, HTML's
/// three, and a backslash.
const literal_specials = "# *a* _b_ `c` [d] <e> & \\ ~f~";

/// What `Editor` assumes of a declared `renderText`: a run inserted through it
/// at the head of an empty document reparses to visible text equal to the
/// run, with no markup minted — the promise `insertLiteral` makes over every
/// format that carries the renderer.
fn expectRenderText(entry: format.Entry) !void {
    const config: format.ParseConfig = .{};
    var editor = try Editor.init(testing.allocator, "", &config, entry.parseToAst, entry.syntax);
    defer editor.deinit();
    try editor.insertLiteral(0, literal_specials);
    errdefer std.debug.print("\n--- literal source ---\n{s}\n", .{editor.sourceBytes()});
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(testing.allocator);
    for (editor.astView().nodes) |n| switch (n.kind) {
        .str => |t| try visible.appendSlice(testing.allocator, t),
        .inline_mark, .text_leaf, .link, .image, .raw_inline, .heading => return error.LiteralMintedMarkup,
        else => {},
    };
    try testing.expectEqualStrings(literal_specials, visible.items);
}

/// What `Editor` assumes of a declared `renderBlock`: a heading fragment it
/// builds — a `heading` over a `str` — prints as source the format parses
/// back to a heading of that level over that text, which is what lets
/// `setBlock` splice the print in. And the same of every other fragment a
/// gesture builds where its alphabet is missing: a quote and a list over
/// paragraphs, a code block, a link and an image over text — each reparses
/// to its kind with its text intact.
fn expectRenderBlock(entry: format.Entry) !void {
    const render = entry.syntax.renderBlock.?;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const text = try b.addLeaf(.{ .str = "title" });
    const heading = try b.addContainer(.{ .heading = .{ .level = 2 } }, &.{text});
    const view = b.view(heading);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(testing.allocator, &view, heading, &out.writer);
    errdefer std.debug.print("\n--- fragment source ---\n{s}\n", .{out.written()});
    const config: format.ParseConfig = .{};
    var parsed = try entry.parse(&config, testing.allocator, out.written());
    defer parsed.deinit();
    const nodes = parsed.doc.ast.nodes;
    var found = false;
    for (nodes) |n| switch (n.kind) {
        .heading => |h| {
            try testing.expectEqual(@as(u32, 2), h.level);
            const child = n.first_child orelse return error.EmptyHeading;
            try testing.expectEqualStrings("title", nodes[child].kind.str);
            try testing.expect(nodes[child].next_sibling == null);
            found = true;
        },
        else => {},
    };
    try testing.expect(found);

    // The gesture fragments, each built the way its gesture builds it.
    var q = AST.Builder.init(testing.allocator);
    defer q.deinit();
    const quote = try q.addContainer(.block_quote, &.{
        try q.addContainer(.para, &.{try q.addLeaf(.{ .str = "one" })}),
        try q.addContainer(.para, &.{try q.addLeaf(.{ .str = "two" })}),
    });
    try expectFragmentReparses(entry, render, &q, quote, .block_quote, "onetwo");

    var l = AST.Builder.init(testing.allocator);
    defer l.deinit();
    const list = try l.addContainer(.{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = null } }, &.{
        try l.addContainer(.list_item, &.{try l.addContainer(.para, &.{try l.addLeaf(.{ .str = "one" })})}),
        try l.addContainer(.list_item, &.{try l.addContainer(.para, &.{try l.addLeaf(.{ .str = "two" })})}),
    });
    try expectFragmentReparses(entry, render, &l, list, .ordered_list, "onetwo");

    var c = AST.Builder.init(testing.allocator);
    defer c.deinit();
    const code = try c.addLeaf(.{ .code_block = .{ .lang = "zig", .text = "a < b\n" } });
    try expectFragmentReparses(entry, render, &c, code, .code_block, "a < b\n");

    var k = AST.Builder.init(testing.allocator);
    defer k.deinit();
    const link = try k.addContainer(.{ .link = .{ .destination = "https://x.dev/?a=1&b=2", .reference = null } }, &.{try k.addLeaf(.{ .str = "here" })});
    try expectFragmentReparses(entry, render, &k, link, .link, "here");

    var m = AST.Builder.init(testing.allocator);
    defer m.deinit();
    const image = try m.addContainer(.{ .image = .{ .destination = "cat.png", .reference = null } }, &.{try m.addLeaf(.{ .str = "a cat" })});
    try expectFragmentReparses(entry, render, &m, image, .image, "a cat");
}

/// The parse configs a per-table claim — `names_leaf_containers`,
/// `block_attrs`, `inline_attrs` — can be made under. A claim is a claim about
/// a TABLE, and Markdown has one table per option combination — `::name` is a
/// paragraph of colons without `ParseOptions.directives`, a `<div>` a raw
/// block without `html_elements` — so the check below asks every table the
/// registry row can produce for these, and parses each with the very config
/// that table came from. Every other row answers the same table for all
/// four, and is checked once.
const claim_configs = [_]format.ParseConfig{
    .{},
    .{ .markdown = .{ .directives = true } },
    .{ .markdown = .{ .html_elements = true } },
    .{ .markdown = .{ .directives = true, .html_elements = true } },
};

/// The three attributes every attribute claim is measured with: one per key
/// class the spellings distinguish, and a `data-` key for the rest.
const claim_attrs: AST.Attrs = .{ .entries = &.{
    .{ .key = "id", .value = "intro" },
    .{ .key = "class", .value = "lead" },
    .{ .key = "data-size", .value = "large" },
} };

/// Every key of `claim_attrs` is on `id`, values intact. A class is looked
/// for rather than compared, since a format may merge one it adds (a name
/// carried as a class) into the same value.
fn expectClaimAttrs(ast: *const AST, id: AST.Node.Id) !void {
    const a = ast.attrsOf(id);
    for (claim_attrs.entries) |kv| {
        const v = a.get(kv.key) orelse return error.AttrsLost;
        if (std.mem.eql(u8, kv.key, "class")) {
            try testing.expect(std.mem.indexOf(u8, v, kv.value.?) != null);
        } else {
            try testing.expectEqualStrings(kv.value.?, v);
        }
    }
}

/// What `Editor.setBlockAttrs` assumes of a table claiming
/// `Syntax.block_attrs`: a paragraph carrying `claim_attrs`, printed through
/// `renderBlock`, reparses to a paragraph carrying them (`native`), or to a
/// container whose SOLE CHILD is that paragraph and which carries them
/// (`wrapped`) — and the claim says which.
fn expectBlockAttrs(entry: format.Entry, cfg: *const format.ParseConfig, shape: @import("../syntax.zig").BlockAttrs) !void {
    const render = tableFor(entry, cfg).renderBlock.?;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const para = try b.addContainer(.para, &.{try b.addLeaf(.{ .str = "text" })});
    try b.setAttrs(para, claim_attrs);
    const view = b.view(para);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(testing.allocator, &view, para, &out.writer);
    errdefer std.debug.print("\n--- attributed block source ---\n{s}\n", .{out.written()});

    var parsed = try entry.parse(cfg, testing.allocator, out.written());
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        if (n.kind != .para) continue;
        const id: AST.Node.Id = @intCast(i);
        switch (shape) {
            .native => return expectClaimAttrs(ast, id),
            .wrapped => {
                try testing.expect(n.next_sibling == null);
                for (ast.nodes, 0..) |p, j| {
                    if (p.kind != .container or p.first_child != id) continue;
                    try testing.expect(p.kind.container.form == .block_fenced);
                    return expectClaimAttrs(ast, @intCast(j));
                }
                return error.BlockNotWrapped;
            },
        }
    }
    return error.BlockDidNotReparse;
}

/// The first element-origin container of `doc` — what a parser made of a
/// tag, as opposed to a directive or a fenced div — or null when the sample
/// has none.
fn firstElement(doc: *const Document) ?AST.Node.Id {
    for (doc.ast.nodes, 0..) |n, i| {
        const id: AST.Node.Id = @intCast(i);
        if (n.kind == .container and doc.containerOrigin(id) == .element) return id;
    }
    return null;
}

/// What `Editor.setNodeAttrs` assumes of a table claiming `Syntax.node_attrs`:
/// over every sample, the first element given `claim_attrs` reparses
/// carrying them, and given none reparses carrying none. A sample whose
/// first element has no attributes covers the insertion after the name; one
/// whose element has some covers the rewrite of the recorded span — which is
/// why a claiming format's samples should hold both.
fn expectNodeAttrs(entry: format.Entry, cfg: *const format.ParseConfig) !void {
    const table = tableFor(entry, cfg);
    for (entry.samples) |sample| {
        var editor = try Editor.init(testing.allocator, sample, cfg, entry.parseToAst, table);
        defer editor.deinit();
        const first = firstElement(&editor.splicer.doc) orelse continue;
        try editor.setNodeAttrs(first, claim_attrs.entries);
        errdefer std.debug.print("\n--- attributed source ---\n{s}\n", .{editor.sourceBytes()});
        try expectClaimAttrs(editor.astView(), firstElement(&editor.splicer.doc).?);
        try editor.setNodeAttrs(firstElement(&editor.splicer.doc).?, &.{});
        try testing.expect(editor.astView().attrsOf(firstElement(&editor.splicer.doc).?).isEmpty());
    }
}

/// What `Editor.wrapRangeAttrs` assumes of a table claiming
/// `Syntax.inline_attrs`: an ANONYMOUS inline container carrying
/// `claim_attrs`, printed through `renderBlock` as the fragment root — which
/// is how the gesture prints it, spliced into a line of the document —
/// reparses to an inline container, anonymous or named `span`, carrying them.
fn expectInlineAttrs(entry: format.Entry, cfg: *const format.ParseConfig) !void {
    const render = tableFor(entry, cfg).renderBlock.?;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const span = try b.addContainer(.{ .container = .{ .name = "", .form = .inline_text } }, &.{try b.addLeaf(.{ .str = "text" })});
    try b.setAttrs(span, claim_attrs);
    const view = b.view(span);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(testing.allocator, &view, span, &out.writer);
    errdefer std.debug.print("\n--- attributed span source ---\n{s}\n", .{out.written()});

    var parsed = try entry.parse(cfg, testing.allocator, out.written());
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        const c = switch (n.kind) {
            .container => |c| c,
            else => continue,
        };
        if (c.form != .inline_text) continue;
        if (c.name.len != 0 and !std.mem.eql(u8, c.name, "span")) continue;
        try expectClaimAttrs(ast, @intCast(i));
        const child = n.first_child orelse return error.SpanLostItsText;
        try testing.expectEqualStrings("text", ast.nodes[child].kind.str);
        return;
    }
    return error.SpanDidNotReparse;
}

/// The table `entry` holds for `cfg` — `format.syntaxForConfig` without the
/// `Format` round trip, since the harness already has the row in hand.
fn tableFor(entry: format.Entry, cfg: *const format.ParseConfig) *const Syntax {
    const pick = entry.syntaxFor orelse return entry.syntax;
    return pick(cfg);
}

/// What `Editor.insertDirective` assumes of a table claiming
/// `Syntax.names_leaf_containers`: a named LEAF CONTAINER carrying an
/// attribute, printed through `renderBlock`, reparses to a container that
/// still carries the name — as its own `name`, or as a `class` where the
/// format has nowhere else to put one (djot's fence is anonymous; AsciiDoc's
/// open block carries the name as its style) — with its attributes intact.
///
/// The name is `x-embed` and not the obvious `embed`, because `embed` is a
/// VOID element in HTML: the serializer writes `<embed src="…">` with no
/// closing tag, so the contract would pass without ever exercising the
/// `<name></name>` tag pair the gesture actually mints. A name no format
/// spells natively is what makes this a test of the generic path.
///
/// The name and the attributes are the whole claim, and the attributes only
/// where the spelling has room — see the field's doc, and AsciiDoc's `<<<`.
/// The reparsed `form` is not part of it: HTML leaves an unknown element
/// unclassified (`form = null`), which is the honest answer there and no
/// obstacle to the gesture. Nor is the label, which only Markdown and djot
/// keep.
fn expectNamedLeafContainer(entry: format.Entry, cfg: *const format.ParseConfig) !void {
    const render = tableFor(entry, cfg).renderBlock.?;
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const label = try b.addLeaf(.{ .str = "Contents" });
    const root = try b.addContainer(
        .{ .container = .{ .name = "x-embed", .form = .block_leaf } },
        &.{label},
    );
    try b.setAttrs(root, .{ .entries = &.{.{ .key = "src", .value = "x.html" }} });
    const view = b.view(root);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(testing.allocator, &view, root, &out.writer);
    errdefer std.debug.print("\n--- directive fragment source ---\n{s}\n", .{out.written()});

    var parsed = try entry.parse(cfg, testing.allocator, out.written());
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        const c = switch (n.kind) {
            .container => |c| c,
            else => continue,
        };
        const named = std.mem.eql(u8, c.name, "x-embed") or blk: {
            const class = ast.attrsOf(@intCast(i)).get("class") orelse break :blk false;
            break :blk std.mem.indexOf(u8, class, "x-embed") != null;
        };
        if (!named) continue;
        const src = ast.attrsOf(@intCast(i)).get("src") orelse return error.DirectiveLostItsAttrs;
        try testing.expectEqualStrings("x.html", src);
        return;
    }
    return error.DirectiveDidNotReparse;
}

/// Print `root` of `b` through `render`, parse the print, and find a node of
/// `tag` whose text is `text` — the reparse promise each gesture fragment
/// rests on. A link or image also has to read its destination back.
fn expectFragmentReparses(
    entry: format.Entry,
    render: @typeInfo(@FieldType(Syntax, "renderBlock")).optional.child,
    b: *const AST.Builder,
    root: AST.Node.Id,
    tag: std.meta.Tag(AST.Node.Kind),
    text: []const u8,
) !void {
    const view = b.view(root);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(testing.allocator, &view, root, &out.writer);
    errdefer std.debug.print("\n--- {s} fragment source ---\n{s}\n", .{ @tagName(tag), out.written() });
    const config: format.ParseConfig = .{};
    var parsed = try entry.parse(&config, testing.allocator, out.written());
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        if (std.meta.activeTag(n.kind) != tag) continue;
        const got = try select.textOf(testing.allocator, ast, @intCast(i));
        defer testing.allocator.free(got);
        // Whether a listing's payload ends in a line end is the format's
        // convention (AsciiDoc's does not), not part of the promise.
        try testing.expectEqualStrings(std.mem.trimEnd(u8, text, "\n"), std.mem.trimEnd(u8, got, "\n"));
        switch (n.kind) {
            .link => |v| try testing.expectEqualStrings("https://x.dev/?a=1&b=2", v.destination.?),
            .image => |v| try testing.expectEqualStrings("cat.png", v.destination.?),
            .code_block => |v| try testing.expectEqualStrings("zig", v.lang.?),
            else => {},
        }
        return;
    }
    return error.FragmentDidNotReparse;
}

/// Where `Editor.moveBlock` puts the block in a `MoveCase`, named by the
/// text of the block it lands beside so the offset can be found in any
/// format's spelling of the same tree.
const MoveTo = union(enum) { after: []const u8, before: []const u8, doc_end };

/// One move over a tree every authorable format can spell: the document as
/// built, the block to move (by its text), where it goes, and the document
/// that should result. Both trees are printed through the format's own
/// serializer, so "what a person would have typed" is the format's canonical
/// form and no case carries a per-format string.
const MoveCase = struct {
    name: []const u8,
    start: *const fn (*AST.Builder) Allocator.Error!AST.Node.Id,
    expected: *const fn (*AST.Builder) Allocator.Error!AST.Node.Id,
    block: []const u8,
    to: MoveTo,
};

const Allocator = std.mem.Allocator;

fn paraOf(b: *AST.Builder, text: []const u8) Allocator.Error!AST.Node.Id {
    return b.addContainer(.para, &.{try b.addLeaf(.{ .str = text })});
}

fn itemOf(b: *AST.Builder, blocks: []const AST.Node.Id) Allocator.Error!AST.Node.Id {
    return b.addContainer(.list_item, blocks);
}

fn listOf(b: *AST.Builder, tight: bool, items: []const AST.Node.Id) Allocator.Error!AST.Node.Id {
    return b.addContainer(.{ .bullet_list = .{ .tight = tight } }, items);
}

const move_cases = [_]MoveCase{
    .{
        .name = "out of a quote, to the top level",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{ try paraOf(b, "a"), try paraOf(b, "y") });
                return b.addContainer(.doc, &.{ quote, try paraOf(b, "b") });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{try paraOf(b, "a")});
                return b.addContainer(.doc, &.{ quote, try paraOf(b, "b"), try paraOf(b, "y") });
            }
        }.f,
        .block = "y",
        .to = .doc_end,
    },
    .{
        .name = "into a quote",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{try paraOf(b, "a")});
                return b.addContainer(.doc, &.{ quote, try paraOf(b, "y") });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{ try paraOf(b, "a"), try paraOf(b, "y") });
                return b.addContainer(.doc, &.{quote});
            }
        }.f,
        .block = "y",
        .to = .{ .after = "a" },
    },
    .{
        .name = "into a list item's tail",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const l = try listOf(b, true, &.{try itemOf(b, &.{try paraOf(b, "x")})});
                return b.addContainer(.doc, &.{ l, try paraOf(b, "y") });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const l = try listOf(b, false, &.{try itemOf(b, &.{ try paraOf(b, "x"), try paraOf(b, "y") })});
                return b.addContainer(.doc, &.{l});
            }
        }.f,
        .block = "y",
        .to = .{ .after = "x" },
    },
    .{
        .name = "between two top-level paragraphs",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                return b.addContainer(.doc, &.{ try paraOf(b, "a"), try paraOf(b, "b"), try paraOf(b, "y") });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                return b.addContainer(.doc, &.{ try paraOf(b, "a"), try paraOf(b, "y"), try paraOf(b, "b") });
            }
        }.f,
        .block = "y",
        .to = .{ .before = "b" },
    },
};

/// `build` printed as `entry`'s own syntax — the canonical spelling of a
/// tree, which is what a move must leave behind.
fn printTree(entry: format.Entry, build: *const fn (*AST.Builder) Allocator.Error!AST.Node.Id) ![]u8 {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const root = try build(&b);
    const view = b.view(root);
    const print = format.targetEntryFor(format.targetFor(entry.id)).serializeFromAst orelse return error.NoSerializer;
    return print(testing.allocator, &view);
}

/// The span of the `str` reading `text` in `doc` — where a block's text is,
/// whatever the format put around it.
fn textSpan(doc: *const Document, text: []const u8) !Span {
    for (doc.ast.nodes, 0..) |n, i| {
        switch (n.kind) {
            .str => |t| if (std.mem.eql(u8, t, text)) return doc.span(@intCast(i)),
            else => {},
        }
    }
    return error.TextNotFound;
}

/// What `Editor.moveBlock` assumes of every authorable format: over each of
/// `move_cases`, the start tree printed as the format's own syntax, the block
/// moved by offset, comes out as the format's own print of the expected tree
/// — byte for byte, which is both "what a person would have typed" and, by
/// the canonical round trip `expectSample` checks, "reparses to the expected
/// tree".
fn expectMoveBlock(entry: format.Entry) !void {
    const config: format.ParseConfig = .{};
    for (&move_cases) |*c| {
        errdefer std.debug.print("\n{s}: move_block {s}\n", .{ @tagName(entry.id), c.name });
        const start = try printTree(entry, c.start);
        defer testing.allocator.free(start);
        const expected = try printTree(entry, c.expected);
        defer testing.allocator.free(expected);
        var editor = try Editor.init(testing.allocator, start, &config, entry.parseToAst, entry.syntax);
        defer editor.deinit();
        const from = (try textSpan(&editor.splicer.doc, c.block)).start;
        const to: usize = switch (c.to) {
            .after => |t| (try textSpan(&editor.splicer.doc, t)).end,
            .before => |t| (try textSpan(&editor.splicer.doc, t)).start,
            .doc_end => start.len,
        };
        errdefer std.debug.print("--- start ---\n{s}\n--- from {d} to {d} ---\n", .{ start, from, to });
        try editor.moveBlock(from, to);
        try testing.expectEqualStrings(expected, editor.sourceBytes());
    }
}

test "harness: every authorable format moves a block across its containers" {
    for (format.registry) |entry| {
        if (!entry.syntax.authorable()) continue;
        try expectMoveBlock(entry);
    }
}

test "harness: every declared renderer keeps the engine's promise" {
    for (format.registry) |entry| {
        errdefer std.debug.print("\n{s}: renderer contract\n", .{@tagName(entry.id)});
        if (entry.syntax.renderText != null) try expectRenderText(entry);
        if (entry.syntax.renderBlock != null) try expectRenderBlock(entry);

        // The per-table claims, per table rather than per row — and each
        // table only once, since a row whose spelling does not move with the
        // config answers the same address for every entry in the list.
        var seen: [claim_configs.len]*const Syntax = undefined;
        var n: usize = 0;
        next: for (&claim_configs) |*cfg| {
            const t = tableFor(entry, cfg);
            for (seen[0..n]) |s| {
                if (s == t) continue :next;
            }
            seen[n] = t;
            n += 1;
            if (t.names_leaf_containers) try expectNamedLeafContainer(entry, cfg);
            if (t.block_attrs) |shape| try expectBlockAttrs(entry, cfg, shape);
            if (t.inline_attrs) try expectInlineAttrs(entry, cfg);
            if (t.node_attrs != null) try expectNodeAttrs(entry, cfg);
        }
    }
}

test "harness: every format declares samples and satisfies the engine contract" {
    for (format.registry) |entry| {
        if (entry.samples.len == 0) {
            std.debug.print("\n{s}: no harness samples declared\n", .{@tagName(entry.id)});
            return error.MissingSamples;
        }
        for (entry.samples, 0..) |sample, index| {
            errdefer std.debug.print("\n{s}: harness sample {d}\n--- source ---\n{s}\n", .{ @tagName(entry.id), index, sample });
            try expectSample(entry, sample);
        }
    }
}
