//! The engine contract: what `Editor`, the serializers and the node table
//! assume of a format, as checks that report rather than assert.
//!
//! ── Why a library ──────────────────────────────────────────────────────────
//! A compiled format has its test suite, and the suite's registry-wide half —
//! `languages/harness.zig` — is the list of promises the engine rests on:
//! every sample parses, prints and reparses; a declared renderer's print
//! reparses to what it was given; a claim a table makes is kept; a block moves
//! across containers the way a person would have typed it. A runtime language
//! has no test suite. It has registration, and registration has to hold it to
//! the same list. So the list lives here, as functions that return
//! `error.ContractBroken` with a `Report` saying which promise and over which
//! source, and the harness is a thin loop over the registry calling them.
//! Compiled and runtime formats are held to literally the same checks.
//!
//! ── What is not here ───────────────────────────────────────────────────────
//! The node table's identity (`ast/table.zig`'s `expectIdentity`) is a
//! property of core's encoder over a compiled parse, not of a format: a
//! runtime language writes its own table, so there is no encoding of its to
//! hold to one. The harness runs it beside these.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const format = @import("format.zig");
const Document = @import("document.zig");
const Span = @import("span.zig");
const Editor = @import("ast/editor.zig").Editor;
const AST = @import("ast/ast.zig");
const select = @import("ast/select.zig");
const syntax_mod = @import("syntax.zig");
const Syntax = syntax_mod.Syntax;
const node_table = @import("ast/table.zig");
const runtime = @import("runtime.zig");

pub const Error = error{ ContractBroken, OutOfMemory };

/// Why a check failed: one message, naming the promise, the format and the
/// source it was broken over. Truncated, never allocated, so a check that
/// fails for lack of memory can still say so.
pub const Report = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    /// Where `gestures` logs every broken promise and carries on, rather
    /// than stopping at the first — for a person triaging a new format, or
    /// a new check. Each message ends in a zero byte; `found` counts them.
    log: ?*std.ArrayList(u8) = null,
    found: usize = 0,

    pub fn message(self: *const Report) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn fail(self: *Report, comptime fmt: []const u8, args: anytype) error{ContractBroken} {
        var w: Writer = .fixed(&self.buf);
        w.print(fmt, args) catch {};
        self.len = w.end;
        return error.ContractBroken;
    }

    /// `fail`, for a call that returned `err`: out of memory stays that, and
    /// anything else is the contract broken — with the language's own reason
    /// where a runtime language gave one.
    fn broke(self: *Report, entry: *const format.Entry, err: anyerror, comptime fmt: []const u8, args: anytype) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var w: Writer = .fixed(&self.buf);
        w.print(fmt, args) catch {};
        // By value rather than `isRegistered`: registration runs these
        // checks over a row it has filled and not yet published.
        if (@intFromEnum(entry.id) >= runtime.base and runtime.lastFailure().len != 0) {
            w.print(": {s}", .{runtime.lastFailure()}) catch {};
        } else {
            w.print(": {t}", .{err}) catch {};
        }
        self.len = w.end;
        return error.ContractBroken;
    }
};

/// Every check that applies to `entry`: its samples, its renderers and the
/// claims each of its tables makes, and — where it can be authored — a block
/// moved across its containers and every gesture run everywhere it applies.
pub fn all(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    try samples(gpa, entry, r);
    try renderers(gpa, entry, r);
    if (entry.syntax.authorable()) {
        try moveBlock(gpa, entry, r);
        try gestures(gpa, entry, r);
    }
}

// ── Samples ─────────────────────────────────────────────────────────────────

/// Every declared sample meets `sample`; a format that declares none is
/// refused, since the samples are the whole of what holds a format that has
/// no test suite.
pub fn samples(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    if (entry.samples.len == 0) return r.fail("{s}: no samples are declared", .{entry.id.name()});
    for (entry.samples, 0..) |source, i| try sample(gpa, entry, i, source, r);
}

/// One sample: it parses to a document holding exactly its source, whose
/// columns meet `node_table.checkColumns`; where the format prints, the print
/// reparses to an equal tree; where it can be authored, an `Editor` opens over
/// it with the same tree, and a zero-length splice is the identity.
pub fn sample(gpa: Allocator, entry: *const format.Entry, index: usize, source: []const u8, r: *Report) Error!void {
    const name = entry.id.name();
    const config: format.ParseConfig = .{};
    var first = entry.parse(&config, gpa, source) catch |err|
        return r.broke(entry, err, "{s}: sample {d} does not parse", .{ name, index });
    defer first.deinit();
    if (!std.mem.eql(u8, source, first.doc.source))
        return r.fail("{s}: sample {d}'s parse does not hold its source", .{ name, index });
    try columns(&first.doc, r, name, "sample", index);

    if (entry.serializeCanonical) |serialize| {
        const printed = serialize(gpa, &first) catch |err|
            return r.broke(entry, err, "{s}: sample {d} does not print", .{ name, index });
        defer gpa.free(printed);
        var second = entry.parse(&config, gpa, printed) catch |err|
            return r.broke(entry, err, "{s}: sample {d}'s print does not reparse", .{ name, index });
        defer second.deinit();
        try columns(&second.doc, r, name, "the print of sample", index);
        if (!first.doc.ast.eql(second.doc.ast))
            return r.fail("{s}: sample {d} prints to source that reparses to a different tree:\n{s}", .{ name, index, printed });
    }

    if (entry.syntax.authorable()) {
        var editor = Editor.init(gpa, source, &config, entry.parseToAst, entry.syntax) catch |err|
            return r.broke(entry, err, "{s}: no editor opens over sample {d}", .{ name, index });
        defer editor.deinit();
        if (!first.doc.ast.eql(editor.astView().*))
            return r.fail("{s}: an editor over sample {d} reads a different tree from a parse", .{ name, index });
        try columns(&editor.splicer.doc, r, name, "the editor's view of sample", index);
        editor.splicer.replaceAtSpan(Span.init(0, 0), "") catch |err|
            return r.broke(entry, err, "{s}: a zero-length splice at the head of sample {d} is refused", .{ name, index });
        if (!std.mem.eql(u8, source, editor.sourceBytes()) or !std.mem.eql(u8, source, editor.splicer.doc.source))
            return r.fail("{s}: a zero-length splice changed sample {d}", .{ name, index });
        if (!first.doc.ast.eql(editor.astView().*))
            return r.fail("{s}: a zero-length splice changed sample {d}'s tree", .{ name, index });
        try columns(&editor.splicer.doc, r, name, "sample, after a zero-length splice,", index);
    }
}

fn columns(doc: *const Document, r: *Report, name: []const u8, what: []const u8, index: usize) Error!void {
    var problem: node_table.Problem = .{};
    node_table.checkColumns(doc, &problem) catch {
        var w: Writer = .fixed(&r.buf);
        w.print("{s}: {s} {d}: the columns are refused: ", .{ name, what, index }) catch {};
        problem.render(&w) catch {};
        r.len = w.end;
        return error.ContractBroken;
    };
}

// ── Renderers and claims ────────────────────────────────────────────────────

/// The parse configs a per-table claim — `names_leaf_containers`,
/// `block_attrs`, `inline_attrs`, `node_attrs` — can be made under. A claim is
/// a claim about a TABLE, and Markdown has one table per option combination —
/// `::name` is a paragraph of colons without `ParseOptions.directives`, a
/// `<div>` a raw block without `html_elements` — so every table the row can
/// produce for these is asked, and parsed with the very config it came from.
/// Every other row answers the same table for all four, and is checked once.
const claim_configs = [_]format.ParseConfig{
    .{},
    .{ .markdown = .{ .directives = true } },
    .{ .markdown = .{ .html_elements = true } },
    .{ .markdown = .{ .directives = true, .html_elements = true } },
};

/// Every renderer `entry` declares keeps the engine's promise, and every
/// claim each of its tables makes is kept.
pub fn renderers(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    if (entry.syntax.renderText != null) try renderText(gpa, entry, r);
    if (entry.syntax.renderBlock != null) try renderBlock(gpa, entry, r);

    // Per table rather than per row — and each table only once, since a row
    // whose spelling does not move with the config answers the same address
    // for every entry in the list.
    var seen: [claim_configs.len]*const Syntax = undefined;
    var n: usize = 0;
    next: for (&claim_configs) |*cfg| {
        const t = tableFor(entry, cfg);
        for (seen[0..n]) |s| {
            if (s == t) continue :next;
        }
        seen[n] = t;
        n += 1;
        if (t.names_leaf_containers) try namedLeafContainer(gpa, entry, cfg, r);
        if (t.block_attrs) |shape| try blockAttrs(gpa, entry, cfg, shape, r);
        if (t.inline_attrs) try inlineAttrs(gpa, entry, cfg, r);
        if (t.node_attrs != null) try nodeAttrs(gpa, entry, cfg, r);
    }
}

/// The table `entry` holds for `cfg` — `format.syntaxForConfig` without the
/// `Format` round trip, since the row is already in hand.
fn tableFor(entry: *const format.Entry, cfg: *const format.ParseConfig) *const Syntax {
    const pick = entry.syntaxFor orelse return entry.syntax;
    return pick(cfg);
}

/// A specials run every format's literal renderer must carry across a
/// reparse: the inline metacharacters, a block opener at column zero, HTML's
/// three, and a backslash.
pub const literal_specials = "# *a* _b_ `c` [d] <e> & \\ ~f~";

/// What `Editor` assumes of a declared `renderText`: a run inserted through it
/// at the head of an empty document reparses to visible text equal to the
/// run, with no markup minted — the promise `insertLiteral` makes over every
/// format that carries the renderer.
pub fn renderText(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    const name = entry.id.name();
    const config: format.ParseConfig = .{};
    var editor = Editor.init(gpa, "", &config, entry.parseToAst, entry.syntax) catch |err|
        return r.broke(entry, err, "{s}: no editor opens over an empty document", .{name});
    defer editor.deinit();
    editor.insertLiteral(0, literal_specials) catch |err|
        return r.broke(entry, err, "{s}: renderText: inserting a literal is refused", .{name});
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(gpa);
    for (editor.astView().nodes) |n| switch (n.kind) {
        .str => |t| try visible.appendSlice(gpa, t),
        .inline_mark, .text_leaf, .link, .image, .raw_inline, .heading => return r.fail(
            "{s}: renderText: a literal reparses with markup in it:\n{s}",
            .{ name, editor.sourceBytes() },
        ),
        else => {},
    };
    if (!std.mem.eql(u8, literal_specials, visible.items))
        return r.fail("{s}: renderText: a literal reparses as \"{s}\":\n{s}", .{ name, visible.items, editor.sourceBytes() });
}

/// What `Editor` assumes of a declared `renderBlock`: a heading fragment it
/// builds — a `heading` over a `str` — prints as source the format parses
/// back to a heading of that level over that text, which is what lets
/// `setBlock` splice the print in. And the same of every other fragment a
/// gesture builds where its alphabet is missing: a quote and a list over
/// paragraphs, a code block, a link and an image over text — each reparses
/// to its kind with its text intact.
pub fn renderBlock(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    const name = entry.id.name();
    {
        var b = AST.Builder.init(gpa);
        defer b.deinit();
        const text = try b.addLeaf(.{ .str = "title" });
        const heading = try b.addContainer(.{ .heading = .{ .level = 2 } }, &.{text});
        const printed = try print(gpa, entry, &b, heading, r, "heading");
        defer gpa.free(printed);
        const config: format.ParseConfig = .{};
        var parsed = entry.parse(&config, gpa, printed) catch |err|
            return r.broke(entry, err, "{s}: renderBlock: a heading's print does not reparse", .{name});
        defer parsed.deinit();
        const nodes = parsed.doc.ast.nodes;
        const found = for (nodes) |n| switch (n.kind) {
            .heading => |h| {
                const child = n.first_child orelse break false;
                const ok = h.level == 2 and nodes[child].kind == .str and
                    std.mem.eql(u8, "title", nodes[child].kind.str) and nodes[child].next_sibling == null;
                break ok;
            },
            else => {},
        } else false;
        if (!found) return r.fail("{s}: renderBlock: a level-2 heading over \"title\" reparses as something else:\n{s}", .{ name, printed });
    }

    // The gesture fragments, each built the way its gesture builds it.
    var q = AST.Builder.init(gpa);
    defer q.deinit();
    const quote = try q.addContainer(.block_quote, &.{
        try q.addContainer(.para, &.{try q.addLeaf(.{ .str = "one" })}),
        try q.addContainer(.para, &.{try q.addLeaf(.{ .str = "two" })}),
    });
    try fragmentReparses(gpa, entry, &q, quote, .block_quote, "onetwo", r);

    var l = AST.Builder.init(gpa);
    defer l.deinit();
    const list = try l.addContainer(.{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = null } }, &.{
        try l.addContainer(.list_item, &.{try l.addContainer(.para, &.{try l.addLeaf(.{ .str = "one" })})}),
        try l.addContainer(.list_item, &.{try l.addContainer(.para, &.{try l.addLeaf(.{ .str = "two" })})}),
    });
    try fragmentReparses(gpa, entry, &l, list, .ordered_list, "onetwo", r);

    var c = AST.Builder.init(gpa);
    defer c.deinit();
    const code = try c.addLeaf(.{ .code_block = .{ .lang = "zig", .text = "a < b\n" } });
    try fragmentReparses(gpa, entry, &c, code, .code_block, "a < b\n", r);

    var k = AST.Builder.init(gpa);
    defer k.deinit();
    const link = try k.addContainer(.{ .link = .{ .destination = "https://x.dev/?a=1&b=2", .reference = null } }, &.{try k.addLeaf(.{ .str = "here" })});
    try fragmentReparses(gpa, entry, &k, link, .link, "here", r);

    var m = AST.Builder.init(gpa);
    defer m.deinit();
    const image = try m.addContainer(.{ .image = .{ .destination = "cat.png", .reference = null } }, &.{try m.addLeaf(.{ .str = "a cat" })});
    try fragmentReparses(gpa, entry, &m, image, .image, "a cat", r);
}

/// `root` of `b` printed through `entry`'s `renderBlock`.
fn print(gpa: Allocator, entry: *const format.Entry, b: *const AST.Builder, root: AST.Node.Id, r: *Report, what: []const u8) Error![]u8 {
    return printWith(gpa, entry, entry.syntax, b, root, r, what);
}

fn printWith(gpa: Allocator, entry: *const format.Entry, table: *const Syntax, b: *const AST.Builder, root: AST.Node.Id, r: *Report, what: []const u8) Error![]u8 {
    const render = table.renderBlock.?;
    const view = b.view(root);
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    render(gpa, &view, root, &out.writer) catch |err|
        return r.broke(entry, err, "{s}: renderBlock: a {s} fragment does not print", .{ entry.id.name(), what });
    return out.toOwnedSlice();
}

/// Print `root` of `b` through `renderBlock`, parse the print, and find a node
/// of `tag` whose text is `text` — the reparse promise each gesture fragment
/// rests on. A link or image also has to read its destination back, and a
/// code block its language.
fn fragmentReparses(
    gpa: Allocator,
    entry: *const format.Entry,
    b: *const AST.Builder,
    root: AST.Node.Id,
    tag: std.meta.Tag(AST.Node.Kind),
    text: []const u8,
    r: *Report,
) Error!void {
    const name = entry.id.name();
    const printed = try print(gpa, entry, b, root, r, @tagName(tag));
    defer gpa.free(printed);
    const config: format.ParseConfig = .{};
    var parsed = entry.parse(&config, gpa, printed) catch |err|
        return r.broke(entry, err, "{s}: renderBlock: a {t} fragment's print does not reparse", .{ name, tag });
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        if (std.meta.activeTag(n.kind) != tag) continue;
        const got = try select.textOf(gpa, ast, @intCast(i));
        defer gpa.free(got);
        // Whether a listing's payload ends in a line end is the format's
        // convention (AsciiDoc's does not), not part of the promise.
        const intact = std.mem.eql(u8, std.mem.trimEnd(u8, text, "\n"), std.mem.trimEnd(u8, got, "\n")) and switch (n.kind) {
            .link => |v| v.destination != null and std.mem.eql(u8, "https://x.dev/?a=1&b=2", v.destination.?),
            .image => |v| v.destination != null and std.mem.eql(u8, "cat.png", v.destination.?),
            .code_block => |v| v.lang != null and std.mem.eql(u8, "zig", v.lang.?),
            else => true,
        };
        if (!intact) return r.fail("{s}: renderBlock: a {t} fragment reparses with its text or target changed:\n{s}", .{ name, tag, printed });
        return;
    }
    return r.fail("{s}: renderBlock: a {t} fragment does not reparse as one:\n{s}", .{ name, tag, printed });
}

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
fn hasClaimAttrs(ast: *const AST, id: AST.Node.Id) bool {
    const a = ast.attrsOf(id);
    for (claim_attrs.entries) |kv| {
        const v = a.get(kv.key) orelse return false;
        const ok = if (std.mem.eql(u8, kv.key, "class"))
            std.mem.indexOf(u8, v, kv.value.?) != null
        else
            std.mem.eql(u8, kv.value.?, v);
        if (!ok) return false;
    }
    return true;
}

/// What `Editor.setBlockAttrs` assumes of a table claiming
/// `Syntax.block_attrs`: a paragraph carrying `claim_attrs`, printed through
/// `renderBlock`, reparses to a paragraph carrying them (`native`), or to a
/// container whose SOLE CHILD is that paragraph and which carries them
/// (`wrapped`) — and the claim says which.
pub fn blockAttrs(gpa: Allocator, entry: *const format.Entry, cfg: *const format.ParseConfig, shape: syntax_mod.BlockAttrs, r: *Report) Error!void {
    const name = entry.id.name();
    var b = AST.Builder.init(gpa);
    defer b.deinit();
    const para = try b.addContainer(.para, &.{try b.addLeaf(.{ .str = "text" })});
    try b.setAttrs(para, claim_attrs);
    const printed = try printWith(gpa, entry, tableFor(entry, cfg), &b, para, r, "attributed block");
    defer gpa.free(printed);

    var parsed = entry.parse(cfg, gpa, printed) catch |err|
        return r.broke(entry, err, "{s}: block_attrs: an attributed block's print does not reparse", .{name});
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        if (n.kind != .para) continue;
        const id: AST.Node.Id = @intCast(i);
        const kept = switch (shape) {
            .native => hasClaimAttrs(ast, id),
            .wrapped => n.next_sibling == null and for (ast.nodes, 0..) |p, j| {
                if (p.kind != .container or p.first_child != id) continue;
                break p.kind.container.form == .block_fenced and hasClaimAttrs(ast, @intCast(j));
            } else false,
        };
        if (!kept) return r.fail("{s}: block_attrs = {t}: the attributes do not come back that way:\n{s}", .{ name, shape, printed });
        return;
    }
    return r.fail("{s}: block_attrs: an attributed paragraph does not reparse as one:\n{s}", .{ name, printed });
}

/// The first element-origin container of `doc` — what a parser made of a
/// tag, as opposed to a directive or a fenced div — or null when there is
/// none.
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
pub fn nodeAttrs(gpa: Allocator, entry: *const format.Entry, cfg: *const format.ParseConfig, r: *Report) Error!void {
    const name = entry.id.name();
    const table = tableFor(entry, cfg);
    for (entry.samples, 0..) |source, index| {
        var editor = Editor.init(gpa, source, cfg, entry.parseToAst, table) catch |err|
            return r.broke(entry, err, "{s}: no editor opens over sample {d}", .{ name, index });
        defer editor.deinit();
        const first = firstElement(&editor.splicer.doc) orelse continue;
        editor.setNodeAttrs(first, claim_attrs.entries) catch |err|
            return r.broke(entry, err, "{s}: node_attrs: setting attributes on sample {d}'s first element is refused", .{ name, index });
        const set = firstElement(&editor.splicer.doc) orelse
            return r.fail("{s}: node_attrs: sample {d} lost its element:\n{s}", .{ name, index, editor.sourceBytes() });
        if (!hasClaimAttrs(editor.astView(), set))
            return r.fail("{s}: node_attrs: sample {d}'s element does not carry what was set:\n{s}", .{ name, index, editor.sourceBytes() });
        editor.setNodeAttrs(set, &.{}) catch |err|
            return r.broke(entry, err, "{s}: node_attrs: clearing sample {d}'s element is refused", .{ name, index });
        const cleared = firstElement(&editor.splicer.doc) orelse
            return r.fail("{s}: node_attrs: sample {d} lost its element:\n{s}", .{ name, index, editor.sourceBytes() });
        if (!editor.astView().attrsOf(cleared).isEmpty())
            return r.fail("{s}: node_attrs: sample {d}'s element keeps attributes once cleared:\n{s}", .{ name, index, editor.sourceBytes() });
    }
}

/// What `Editor.wrapRangeAttrs` assumes of a table claiming
/// `Syntax.inline_attrs`: an ANONYMOUS inline container carrying
/// `claim_attrs`, printed through `renderBlock` as the fragment root — which
/// is how the gesture prints it, spliced into a line of the document —
/// reparses to an inline container, anonymous or named `span`, carrying them.
pub fn inlineAttrs(gpa: Allocator, entry: *const format.Entry, cfg: *const format.ParseConfig, r: *Report) Error!void {
    const name = entry.id.name();
    var b = AST.Builder.init(gpa);
    defer b.deinit();
    const span = try b.addContainer(.{ .container = .{ .name = "", .form = .inline_text } }, &.{try b.addLeaf(.{ .str = "text" })});
    try b.setAttrs(span, claim_attrs);
    const printed = try printWith(gpa, entry, tableFor(entry, cfg), &b, span, r, "attributed span");
    defer gpa.free(printed);

    var parsed = entry.parse(cfg, gpa, printed) catch |err|
        return r.broke(entry, err, "{s}: inline_attrs: an attributed span's print does not reparse", .{name});
    defer parsed.deinit();
    const ast = &parsed.doc.ast;
    for (ast.nodes, 0..) |n, i| {
        const c = switch (n.kind) {
            .container => |c| c,
            else => continue,
        };
        if (c.form != .inline_text) continue;
        if (c.name.len != 0 and !std.mem.eql(u8, c.name, "span")) continue;
        const child = n.first_child;
        const kept = hasClaimAttrs(ast, @intCast(i)) and child != null and
            ast.nodes[child.?].kind == .str and std.mem.eql(u8, "text", ast.nodes[child.?].kind.str);
        if (!kept) return r.fail("{s}: inline_attrs: the span comes back without its attributes or text:\n{s}", .{ name, printed });
        return;
    }
    return r.fail("{s}: inline_attrs: an attributed span does not reparse as one:\n{s}", .{ name, printed });
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
pub fn namedLeafContainer(gpa: Allocator, entry: *const format.Entry, cfg: *const format.ParseConfig, r: *Report) Error!void {
    const name = entry.id.name();
    var b = AST.Builder.init(gpa);
    defer b.deinit();
    const label = try b.addLeaf(.{ .str = "Contents" });
    const root = try b.addContainer(
        .{ .container = .{ .name = "x-embed", .form = .block_leaf } },
        &.{label},
    );
    try b.setAttrs(root, .{ .entries = &.{.{ .key = "src", .value = "x.html" }} });
    const printed = try printWith(gpa, entry, tableFor(entry, cfg), &b, root, r, "directive");
    defer gpa.free(printed);

    var parsed = entry.parse(cfg, gpa, printed) catch |err|
        return r.broke(entry, err, "{s}: names_leaf_containers: a directive's print does not reparse", .{name});
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
        const src = ast.attrsOf(@intCast(i)).get("src");
        if (src == null or !std.mem.eql(u8, "x.html", src.?))
            return r.fail("{s}: names_leaf_containers: the directive comes back without its attributes:\n{s}", .{ name, printed });
        return;
    }
    return r.fail("{s}: names_leaf_containers: a named leaf container does not come back named:\n{s}", .{ name, printed });
}

// ── Moving a block ──────────────────────────────────────────────────────────

/// Where `Editor.moveBlock` puts the block in a `MoveCase`, named by the
/// text of the block it lands beside so the offset can be found in any
/// format's spelling of the same tree — or the document's two ends, which
/// are offsets in every spelling.
const MoveTo = union(enum) { after: []const u8, before: []const u8, doc_start, doc_end };

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
    /// Both documents without their final line end: the source's length is
    /// then the last block's own end, and still the document's end.
    unterminated: bool = false,
};

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
    // The three boundaries `docs/tasks/closed/move-block-boundary-gaps.md` found
    // read as a place the block already is, or as inside a container it is
    // not: each is one a caret can name, and each moves the block out.
    .{
        .name = "past its own end, out of the quote it closes",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{ try paraOf(b, "a"), try paraOf(b, "y") });
                return b.addContainer(.doc, &.{ quote, try paraOf(b, "b") });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{try paraOf(b, "a")});
                return b.addContainer(.doc, &.{ quote, try paraOf(b, "y"), try paraOf(b, "b") });
            }
        }.f,
        .block = "y",
        .to = .{ .after = "y" },
    },
    .{
        .name = "above a quote that opens the document",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{try paraOf(b, "a")});
                return b.addContainer(.doc, &.{ quote, try paraOf(b, "y") });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const quote = try b.addContainer(.block_quote, &.{try paraOf(b, "a")});
                return b.addContainer(.doc, &.{ try paraOf(b, "y"), quote });
            }
        }.f,
        .block = "y",
        .to = .doc_start,
    },
    .{
        .name = "to the unterminated end, behind a trailing list",
        .start = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const l = try listOf(b, true, &.{ try itemOf(b, &.{try paraOf(b, "a")}), try itemOf(b, &.{try paraOf(b, "b")}) });
                return b.addContainer(.doc, &.{ try paraOf(b, "y"), l });
            }
        }.f,
        .expected = struct {
            fn f(b: *AST.Builder) Allocator.Error!AST.Node.Id {
                const l = try listOf(b, true, &.{ try itemOf(b, &.{try paraOf(b, "a")}), try itemOf(b, &.{try paraOf(b, "b")}) });
                return b.addContainer(.doc, &.{ l, try paraOf(b, "y") });
            }
        }.f,
        .block = "y",
        .to = .doc_end,
        .unterminated = true,
    },
};

/// `build` printed as `entry`'s own syntax — the canonical spelling of a
/// tree, which is what a move must leave behind.
fn printTree(gpa: Allocator, entry: *const format.Entry, build: *const fn (*AST.Builder) Allocator.Error!AST.Node.Id, r: *Report) Error![]u8 {
    var b = AST.Builder.init(gpa);
    defer b.deinit();
    const root = try build(&b);
    const view = b.view(root);
    const serialize = format.targetEntryFor(format.targetFor(entry.id)).serializeFromAst orelse
        return r.fail("{s}: moveBlock: an authorable format prints from a tree, and this one does not", .{entry.id.name()});
    return serialize(gpa, &view) catch |err|
        r.broke(entry, err, "{s}: moveBlock: a tree does not print", .{entry.id.name()});
}

/// The span of the `str` reading `text` in `doc` — where a block's text is,
/// whatever the format put around it.
fn textSpan(doc: *const Document, text: []const u8) ?Span {
    for (doc.ast.nodes, 0..) |n, i| {
        switch (n.kind) {
            .str => |t| if (std.mem.eql(u8, t, text)) return doc.span(@intCast(i)),
            else => {},
        }
    }
    return null;
}

/// What `Editor.moveBlock` assumes of every authorable format: over each of
/// `move_cases`, the start tree printed as the format's own syntax, the block
/// moved by offset, comes out as the format's own print of the expected tree
/// — byte for byte, which is both "what a person would have typed" and, by
/// the canonical round trip `sample` checks, "reparses to the expected tree".
pub fn moveBlock(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    const name = entry.id.name();
    const config: format.ParseConfig = .{};
    for (&move_cases) |*c| {
        const start_print = try printTree(gpa, entry, c.start, r);
        defer gpa.free(start_print);
        const expected_print = try printTree(gpa, entry, c.expected, r);
        defer gpa.free(expected_print);
        const start = if (c.unterminated) std.mem.trimEnd(u8, start_print, "\n") else start_print;
        const expected = if (c.unterminated) std.mem.trimEnd(u8, expected_print, "\n") else expected_print;
        var editor = Editor.init(gpa, start, &config, entry.parseToAst, entry.syntax) catch |err|
            return r.broke(entry, err, "{s}: moveBlock {s}: no editor opens over the start", .{ name, c.name });
        defer editor.deinit();
        const doc = &editor.splicer.doc;
        const missing = "{s}: moveBlock {s}: the start does not hold its text:\n{s}";
        const from = (textSpan(doc, c.block) orelse return r.fail(missing, .{ name, c.name, start })).start;
        const to: usize = switch (c.to) {
            .after => |t| (textSpan(doc, t) orelse return r.fail(missing, .{ name, c.name, start })).end,
            .before => |t| (textSpan(doc, t) orelse return r.fail(missing, .{ name, c.name, start })).start,
            .doc_start => 0,
            .doc_end => start.len,
        };
        editor.moveBlock(from, to) catch |err|
            return r.broke(entry, err, "{s}: moveBlock {s}: from {d} to {d} is refused over:\n{s}", .{ name, c.name, from, to, start });
        if (!std.mem.eql(u8, expected, editor.sourceBytes()))
            return r.fail("{s}: moveBlock {s}: from {d} to {d} over\n{s}\n--- gave ---\n{s}\n--- not ---\n{s}", .{ name, c.name, from, to, start, editor.sourceBytes(), expected });
    }
}

// ── Every gesture, everywhere ───────────────────────────────────────────────
//
// The checks above hold a format to one fragment per gesture family. This one
// holds it to every gesture `Editor.supports` answers yes for, at every place
// in every document it can reach: the format's samples, and a richer
// document — a heading, prose, a quote, both lists, a code block, and a
// table and a task list where the table spells them — printed in the
// format's own syntax. Each run either refuses cleanly, leaving the source as
// it was and with some reason other than "unsupported", or succeeds and
//
//   * leaves a document whose tree is a fresh parse of its source;
//   * changes nothing outside the bytes it wrote: every top-level block wholly
//     before or after the changed region reads as it did — the check that
//     sees a paragraph turned into a heading by a `---` written under it;
//   * has the shape the gesture promised: a mark over the word it wrapped, a
//     heading of the level asked for, one more rule, one more row, the
//     literal's text and nothing else — and, where the gesture is a toggle,
//     the second toggle gives back the tree it started from.
//
// The traps recorded in `Syntax`'s doc comments were each a gesture that
// reported success over a document it had broken somewhere its own check did
// not look. This is the general form of looking.

/// The richer document, as a tree every authorable format can spell; a table
/// and a task list join it where `table` spells them.
fn buildRich(b: *AST.Builder, table: *const Syntax) Allocator.Error!AST.Node.Id {
    var blocks: std.ArrayList(AST.Node.Id) = .empty;
    defer blocks.deinit(b.allocator);
    const a = b.allocator;
    try blocks.append(a, try b.addContainer(.{ .heading = .{ .level = 1 } }, &.{try b.addLeaf(.{ .str = "Title here" })}));
    try blocks.append(a, try paraOf(b, "alpha beta gamma"));
    try blocks.append(a, try b.addContainer(.block_quote, &.{ try paraOf(b, "quoted words"), try paraOf(b, "more quoted") }));
    try blocks.append(a, try listOf(b, true, &.{ try itemOf(b, &.{try paraOf(b, "one item")}), try itemOf(b, &.{try paraOf(b, "two item")}) }));
    try blocks.append(a, try b.addContainer(.{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = null } }, &.{
        try itemOf(b, &.{try paraOf(b, "first step")}),
        try itemOf(b, &.{try paraOf(b, "second step")}),
    }));
    try blocks.append(a, try b.addLeaf(.{ .code_block = .{ .lang = "zig", .text = "const x = 1;\n" } }));
    if (table.task_marker != null) {
        try blocks.append(a, try b.addContainer(.{ .task_list = .{ .tight = true } }, &.{
            try b.addContainer(.{ .task_list_item = .{ .checked = true } }, &.{try paraOf(b, "done task")}),
            try b.addContainer(.{ .task_list_item = .{ .checked = false } }, &.{try paraOf(b, "open task")}),
        }));
    }
    if (table.table_spelling != null) {
        const cell = struct {
            fn f(bb: *AST.Builder, head: bool, text: []const u8) Allocator.Error!AST.Node.Id {
                return bb.addContainer(.{ .cell = .{ .head = head, .alignment = .default } }, &.{try bb.addLeaf(.{ .str = text })});
            }
        }.f;
        try blocks.append(a, try b.addContainer(.table, &.{
            try b.addContainer(.{ .row = .{ .head = true } }, &.{ try cell(b, true, "ha"), try cell(b, true, "hb") }),
            try b.addContainer(.{ .row = .{ .head = false } }, &.{ try cell(b, false, "c1"), try cell(b, false, "c2") }),
            try b.addContainer(.{ .row = .{ .head = false } }, &.{ try cell(b, false, "c3"), try cell(b, false, "c4") }),
        }));
    }
    try blocks.append(a, try paraOf(b, "closing words here"));
    return b.addContainer(.doc, blocks.items);
}

/// Every gesture `entry`'s table supports, run at every place it applies in
/// every document the format reaches. See the section comment.
pub fn gestures(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    if (!entry.syntax.authorable()) return;
    for (entry.samples, 0..) |source, i| {
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "sample {d}", .{i}) catch unreachable;
        try gesturesOver(gpa, entry, source, label, r);
    }
    const serialize = format.targetEntryFor(format.targetFor(entry.id)).serializeFromAst orelse return;
    var b = AST.Builder.init(gpa);
    defer b.deinit();
    const root = try buildRich(&b, entry.syntax);
    const view = b.view(root);
    const rich = serialize(gpa, &view) catch |err|
        return r.broke(entry, err, "{s}: gestures: the richer document does not print", .{entry.id.name()});
    defer gpa.free(rich);
    try gesturesOver(gpa, entry, rich, "the richer document", r);
    if (r.found != 0) return r.fail("{s}: gestures: {d} broken promises, logged", .{ entry.id.name(), r.found });
}

/// Where a gesture runs: a word's span inside a `str`, or a block by id.
const Site = union(enum) { word: Span, block: AST.Node.Id };

const Trial = struct {
    gpa: Allocator,
    entry: *const format.Entry,
    source: []const u8,
    label: []const u8,
    before: *const Document,
    r: *Report,
    config: format.ParseConfig = .{},
    /// The block a block probe aims at, whose own change is the point.
    target: ?AST.Node.Id = null,
    /// The probe joins its target into the block before it, which changes
    /// that block too.
    joins: bool = false,

    /// One probe's outcome: a broken promise is the check's answer, unless
    /// the report is collecting every one, in which case it is logged and
    /// the next probe runs.
    fn keep(t: *Trial, result: Error!void) Error!void {
        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ContractBroken => {
                const log = t.r.log orelse return error.ContractBroken;
                try log.appendSlice(t.gpa, t.r.message());
                try log.append(t.gpa, 0);
                t.r.found += 1;
            },
        };
    }

    fn open(t: *Trial) Error!Editor {
        return Editor.init(t.gpa, t.source, &t.config, t.entry.parseToAst, t.entry.syntax) catch |err|
            t.r.broke(t.entry, err, "{s}: gestures: no editor opens over {s}", .{ t.entry.id.name(), t.label });
    }

    /// A refusal: the source is as it was, and the reason is not one
    /// `Editor.supports` promised away.
    fn refused(t: *Trial, e: *const Editor, what: []const u8, err: anyerror) Error!void {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.UnsupportedFormat)
            return t.r.fail("{s}: {s} over {s}: supports() answers yes and the gesture answers unsupported:\n{s}", .{ t.entry.id.name(), what, t.label, t.source });
        if (!std.mem.eql(u8, t.source, e.sourceBytes()))
            return t.r.fail("{s}: {s} over {s}: refused ({t}) and changed the source anyway:\n{s}", .{ t.entry.id.name(), what, t.label, err, e.sourceBytes() });
    }

    fn broken(t: *Trial, e: *const Editor, what: []const u8, comptime why: []const u8, args: anytype) error{ContractBroken} {
        var w: Writer = .fixed(&t.r.buf);
        w.print("{s}: {s} over {s}: ", .{ t.entry.id.name(), what, t.label }) catch {};
        w.print(why, args) catch {};
        w.print("\n--- before ---\n{s}\n--- after ---\n{s}", .{ t.source, e.sourceBytes() }) catch {};
        t.r.len = w.end;
        return error.ContractBroken;
    }

    /// What every success owes: a tree that is a parse of its source, and
    /// every top-level block outside the changed bytes as it was.
    fn succeeded(t: *Trial, e: *const Editor, what: []const u8) Error!void {
        const after = e.sourceBytes();
        var fresh = t.entry.parseToAst(&t.config, t.gpa, after) catch |err|
            return t.r.broke(t.entry, err, "{s}: {s} over {s}: the result does not parse", .{ t.entry.id.name(), what, t.label });
        defer fresh.deinit();
        if (!fresh.ast.eql(e.astView().*)) return t.broken(e, what, "the editor's tree is not a parse of its source", .{});
        var problem: node_table.Problem = .{};
        node_table.checkColumns(&e.splicer.doc, &problem) catch
            return t.broken(e, what, "the columns are refused: {s} {s}", .{ problem.field, problem.what });

        // The changed region, as the bytes say it: whatever is outside the
        // longest common prefix and suffix.
        const old = t.source;
        var p: usize = 0;
        while (p < old.len and p < after.len and old[p] == after[p]) p += 1;
        var s: usize = 0;
        while (s < old.len - p and s < after.len - p and old[old.len - 1 - s] == after[after.len - 1 - s]) s += 1;
        const old_ast = &t.before.ast;
        const new_ast = e.astView();
        var olds: [512]Leaf = undefined;
        var news: [512]Leaf = undefined;
        const ol = leaves(t.before, &olds);
        const nl = leaves(&e.splicer.doc, &news);
        // Before: leaf blocks ending inside the common prefix, paired by
        // position — the bytes before them are the same, so the same blocks
        // come first. Not by span: a block's span takes in the line end a
        // gesture may have added after it. A leaf block is compared with the
        // kinds of the containers it sits in, so a paragraph that turns into
        // a heading or falls out of its quote is seen, and a container that
        // gains a block after it is not.
        var i: usize = 0;
        while (i < ol.len and ol[i].span.end < p) : (i += 1) {
            if (t.target != null and ol[i].id == t.target.?) continue;
            // A join's other half is the block before its target.
            if (t.joins and i + 1 < ol.len and t.target != null and ol[i + 1].id == t.target.?) continue;
            if (i >= nl.len or !leafEql(old_ast, ol[i], new_ast, nl[i]))
                return t.broken(e, what, "the block before every byte it wrote, \"{s}\", reads differently", .{t.before.source[ol[i].span.start..ol[i].span.end]});
        }
        // After: leaf blocks starting strictly inside the common suffix —
        // bytes written at a block's first byte are written into it — paired
        // from the end.
        var j: usize = 0;
        while (j < ol.len and ol[ol.len - 1 - j].span.start > old.len - s) : (j += 1) {
            const ob = ol[ol.len - 1 - j];
            if (t.target != null and ob.id == t.target.?) continue;
            if (j >= nl.len or !leafEql(old_ast, ob, new_ast, nl[nl.len - 1 - j]))
                return t.broken(e, what, "the block after every byte it wrote, \"{s}\", reads differently", .{t.before.source[ob.span.start..ob.span.end]});
        }
    }
};

/// A leaf block, and the chain of containers it sits in.
const Leaf = struct {
    id: AST.Node.Id,
    span: Span,
    /// Ancestors, innermost first, without sections (see `leaves`).
    chain: [16]AST.Node.Id = undefined,
    depth: usize = 0,
};

fn isLeafBlock(k: AST.Node.Kind) bool {
    return switch (k) {
        .para, .heading, .code_block, .raw_block, .thematic_break, .table, .metadata => true,
        else => false,
    };
}

/// The document's leaf blocks in order, each with its containers. Sections
/// are left out of the chain: djot and AsciiDoc derive one from each heading,
/// running to the next, so a block inserted after a heading lands inside its
/// section while no block in it changes.
fn leaves(doc: *const Document, buf: []Leaf) []Leaf {
    var n: usize = 0;
    var chain: [16]AST.Node.Id = undefined;
    walkLeaves(doc, doc.ast.root, &chain, 0, buf, &n);
    return buf[0..n];
}

fn walkLeaves(doc: *const Document, parent: AST.Node.Id, chain: *[16]AST.Node.Id, depth: usize, buf: []Leaf, n: *usize) void {
    const ast = &doc.ast;
    var c = ast.nodes[parent].first_child;
    while (c) |id| : (c = ast.nodes[id].next_sibling) {
        const k = ast.nodes[id].kind;
        if (isLeafBlock(k)) {
            if (n.* == buf.len) return;
            var leaf: Leaf = .{ .id = id, .span = doc.span(id), .depth = depth };
            for (0..depth) |d| leaf.chain[d] = chain[depth - 1 - d];
            buf[n.*] = leaf;
            n.* += 1;
        } else if (k == .section or k == .doc) {
            walkLeaves(doc, id, chain, depth, buf, n);
        } else if (depth < chain.len) {
            chain[depth] = id;
            walkLeaves(doc, id, chain, depth + 1, buf, n);
        }
    }
}

/// A node's kind for the container comparison. A bullet list whose items
/// carry boxes is a task list, and one box added to one item makes the list
/// one — the siblings' container changes name, not shape.
fn listKind(k: AST.Node.Kind) std.meta.Tag(AST.Node.Kind) {
    return switch (k) {
        .task_list => .bullet_list,
        .task_list_item => .list_item,
        else => std.meta.activeTag(k),
    };
}

fn leafEql(a: *const AST, x: Leaf, b: *const AST, y: Leaf) bool {
    if (x.depth != y.depth) return false;
    if (!subtreeEql(a, x.id, b, y.id)) return false;
    // By kind, not payload: a block written between two list items splits
    // the list, and the second half takes a `start` to keep its numbers —
    // the block is still in an ordered list's item, which is the claim.
    for (x.chain[0..x.depth], y.chain[0..y.depth]) |p, q| {
        if (listKind(a.nodes[p].kind) != listKind(b.nodes[q].kind)) return false;
    }
    return true;
}

fn subtreeEql(a: *const AST, ai: AST.Node.Id, b: *const AST, bi: AST.Node.Id) bool {
    if (!a.nodes[ai].kind.eql(b.nodes[bi].kind)) return false;
    const x = a.attrsOf(ai).entries;
    const y = b.attrsOf(bi).entries;
    if (x.len != y.len) return false;
    for (x, y) |kx, ky| {
        if (!std.mem.eql(u8, kx.key, ky.key)) return false;
        if ((kx.value == null) != (ky.value == null)) return false;
        if (kx.value) |v| if (!std.mem.eql(u8, v, ky.value.?)) return false;
    }
    var ca = a.nodes[ai].first_child;
    var cb = b.nodes[bi].first_child;
    while (ca != null and cb != null) : ({
        ca = a.nodes[ca.?].next_sibling;
        cb = b.nodes[cb.?].next_sibling;
    }) {
        if (!subtreeEql(a, ca.?, b, cb.?)) return false;
    }
    return ca == null and cb == null;
}

fn count(ast: *const AST, comptime pred: fn (AST.Node.Kind) bool) usize {
    var n: usize = 0;
    for (ast.nodes) |node| {
        if (pred(node.kind)) n += 1;
    }
    return n;
}

fn isRule(k: AST.Node.Kind) bool {
    return k == .thematic_break;
}
fn isPara(k: AST.Node.Kind) bool {
    return k == .para;
}
fn isTable(k: AST.Node.Kind) bool {
    return k == .table;
}
fn isMarkup(k: AST.Node.Kind) bool {
    return switch (k) {
        .inline_mark, .text_leaf, .link, .image, .raw_inline => true,
        else => false,
    };
}

/// Whether `id` sits inside a node for which `pred` holds.
fn within(ast: *const AST, id: AST.Node.Id, comptime pred: fn (AST.Node.Kind) bool) bool {
    var parents: [512]?AST.Node.Id = undefined;
    const n = @min(ast.nodes.len, parents.len);
    @memset(parents[0..n], null);
    for (ast.nodes[0..n], 0..) |node, i| {
        var c = node.first_child;
        while (c) |ch| : (c = ast.nodes[ch].next_sibling) {
            if (ch < n) parents[ch] = @intCast(i);
        }
    }
    var at: ?AST.Node.Id = if (id < n) parents[id] else null;
    while (at) |p| : (at = parents[p]) {
        if (pred(ast.nodes[p].kind)) return true;
    }
    return false;
}

fn isVerbatimish(k: AST.Node.Kind) bool {
    return switch (k) {
        .code_block, .raw_block, .raw_inline, .text_leaf, .link, .image, .table, .cell, .heading => true,
        else => false,
    };
}
fn isCell(k: AST.Node.Kind) bool {
    return k == .cell;
}
fn isListy(k: AST.Node.Kind) bool {
    return switch (k) {
        .bullet_list, .ordered_list, .task_list, .block_quote, .table => true,
        else => false,
    };
}

/// The node of `ast` matching `pred` whose text is `text`, if any.
fn findText(gpa: Allocator, ast: *const AST, comptime pred: fn (AST.Node.Kind) bool, text: []const u8) Allocator.Error!?AST.Node.Id {
    for (ast.nodes, 0..) |n, i| {
        if (!pred(n.kind)) continue;
        const got = try select.textOf(gpa, ast, @intCast(i));
        defer gpa.free(got);
        if (std.mem.eql(u8, std.mem.trim(u8, got, " \n"), std.mem.trim(u8, text, " \n"))) return @intCast(i);
    }
    return null;
}

/// The word sites: the first word of every `str` outside anything that reads
/// its text verbatim or is a construct of its own, and every block leaf.
fn sitesOf(gpa: Allocator, doc: *const Document, words: *std.ArrayList(Span), blocks: *std.ArrayList(AST.Node.Id)) Allocator.Error!void {
    const ast = &doc.ast;
    for (ast.nodes, 0..) |n, i| {
        const id: AST.Node.Id = @intCast(i);
        switch (n.kind) {
            .str => |text| {
                if (within(ast, id, isVerbatimish) or within(ast, id, isMarkupNode)) continue;
                const sp = doc.span(id);
                if (sp.end - sp.start != text.len) continue; // escaped or entity-spelled: not a plain run
                var start: usize = 0;
                while (start < text.len and text[start] == ' ') start += 1;
                var end = start;
                while (end < text.len and std.ascii.isAlphanumeric(text[end])) end += 1;
                if (end > start) try words.append(gpa, Span.init(sp.start + start, sp.start + end));
            },
            .para, .heading, .code_block => try blocks.append(gpa, id),
            else => {},
        }
    }
}

fn isMarkupNode(k: AST.Node.Kind) bool {
    return switch (k) {
        .inline_mark, .container => true,
        else => false,
    };
}

/// The first text offset inside `id` — where a caret in that block sits.
fn caretIn(doc: *const Document, id: AST.Node.Id) usize {
    const ast = &doc.ast;
    for (ast.nodes[id..], id..) |n, i| {
        if (n.kind == .str and (i == id or isDescendant(ast, id, @intCast(i)))) return doc.span(@intCast(i)).start;
    }
    return (doc.contentSpan(id) orelse doc.span(id)).start;
}

fn isDescendant(ast: *const AST, ancestor: AST.Node.Id, id: AST.Node.Id) bool {
    var c = ast.nodes[ancestor].first_child;
    while (c) |ch| : (c = ast.nodes[ch].next_sibling) {
        if (ch == id or isDescendant(ast, ch, id)) return true;
    }
    return false;
}

const InlineKind = syntax_mod.InlineKind;
const ContainerKind = syntax_mod.ContainerKind;

fn markOf(k: InlineKind) AST.KindRef {
    if (k == .verbatim) return .{ .text_leaf = .verbatim };
    return .{ .mark = std.meta.stringToEnum(AST.InlineMark, @tagName(k)).? };
}

/// The node `ref` names whose text is `text`.
fn findRef(gpa: Allocator, ast: *const AST, ref: AST.KindRef, text: []const u8) Allocator.Error!?AST.Node.Id {
    for (ast.nodes, 0..) |n, i| {
        const matches = switch (ref) {
            .mark => |m| n.kind == .inline_mark and n.kind.inline_mark == m,
            .text_leaf => |l| n.kind == .text_leaf and n.kind.text_leaf.kind == l,
            else => false,
        };
        if (!matches) continue;
        const got = try select.textOf(gpa, ast, @intCast(i));
        defer gpa.free(got);
        if (std.mem.eql(u8, got, text)) return @intCast(i);
    }
    return null;
}

fn containerTag(k: ContainerKind) std.meta.Tag(AST.Node.Kind) {
    return switch (k) {
        .block_quote => .block_quote,
        .bullet_list => .bullet_list,
        .ordered_list => .ordered_list,
    };
}

fn gesturesOver(gpa: Allocator, entry: *const format.Entry, source: []const u8, label: []const u8, r: *Report) Error!void {
    const table = entry.syntax;
    const config: format.ParseConfig = .{};
    var before = entry.parseToAst(&config, gpa, source) catch |err|
        return r.broke(entry, err, "{s}: gestures: {s} does not parse", .{ entry.id.name(), label });
    defer before.deinit();
    var t: Trial = .{ .gpa = gpa, .entry = entry, .source = source, .label = label, .before = &before, .r = r };

    var words: std.ArrayList(Span) = .empty;
    defer words.deinit(gpa);
    var blocks: std.ArrayList(AST.Node.Id) = .empty;
    defer blocks.deinit(gpa);
    try sitesOf(gpa, &before, &words, &blocks);
    const ast = &before.ast;

    for (words.items) |w| {
        for (std.enums.values(InlineKind)) |k| {
            if (!Editor.supports(table, .{ .toggle_inline = k })) continue;
            try t.keep(probeInline(&t, w, k, true));
            try t.keep(probeInline(&t, w, k, false));
        }
        if (Editor.supports(table, .insert_link)) try t.keep(probeLink(&t, w));
        if (Editor.supports(table, .insert_image)) try t.keep(probeImage(&t, w));
        if (Editor.supports(table, .insert_footnote)) try t.keep(probeFootnote(&t, w));
        if (Editor.supports(table, .insert_inline_math)) try t.keep(probeInlineMath(&t, w));
        if (Editor.supports(table, .insert_literal)) try t.keep(probeLiteral(&t, w));
        if (Editor.supports(table, .split_block) and w.end - w.start >= 2) try t.keep(probeSplit(&t, w));
        if (Editor.supports(table, .wrap_range_attrs)) try t.keep(probeWrapAttrs(&t, w));
    }

    for (blocks.items) |id| {
        const text = try select.textOf(gpa, ast, id);
        defer gpa.free(text);
        const b: BlockSite = .{
            .id = id,
            .kind = ast.nodes[id].kind,
            .caret = caretIn(&before, id),
            .span = before.span(id),
            .in_cell = within(ast, id, isCell),
            .text = text,
        };
        t.target = id;
        defer t.target = null;
        if (b.in_cell) {
            if (b.kind == .para) try tableGestures(&t, b.caret);
            continue;
        }
        if (b.kind == .para) {
            if (Editor.supports(table, .set_block)) try t.keep(probeSetBlock(&t, b));
            for (std.enums.values(ContainerKind)) |k| {
                if (Editor.supports(table, .{ .toggle_block_container = k })) try t.keep(probeContainer(&t, b, k));
            }
            if (Editor.supports(table, .toggle_code_block)) try t.keep(probeCodeBlock(&t, b));
            const in_item = withinTag(ast, id, .list_item) or withinTag(ast, id, .task_list_item);
            if (Editor.supports(table, .toggle_task_item) and in_item) try t.keep(probeTaskItem(&t, b));
            if (Editor.supports(table, .toggle_task_checked) and withinTag(ast, id, .task_list_item)) try t.keep(probeTaskChecked(&t, b));
        }
        if (b.kind == .code_block and Editor.supports(table, .set_code_language)) try t.keep(probeCodeLanguage(&t, b));
        if (Editor.supports(table, .insert_thematic_break)) try t.keep(probeRule(&t, b));
        if (Editor.supports(table, .join_blocks) and b.span.start > 0) try t.keep(probeJoin(&t, b));
        if (Editor.supports(table, .insert_table)) try t.keep(probeInsertTable(&t, b));
        if (Editor.supports(table, .insert_directive)) try t.keep(probeDirective(&t, b));
        if (Editor.supports(table, .insert_display_math)) try t.keep(probeDisplayMath(&t, b));
        if (Editor.supports(table, .set_block_attrs)) try t.keep(probeBlockAttrs(&t, b));
        if (Editor.supports(table, .move_block)) try t.keep(probeMove(&t, b));
    }

    if (Editor.supports(table, .renumber_ordered_lists)) for (ast.nodes, 0..) |n, i| {
        if (n.kind != .ordered_list) continue;
        try t.keep(probeRenumber(&t, caretIn(&before, @intCast(i))));
    };

    // Cells whose text is a direct `str` rather than a paragraph.
    for (ast.nodes) |n| {
        if (n.kind != .cell) continue;
        const first = n.first_child orelse continue;
        if (ast.nodes[first].kind != .str) continue;
        try tableGestures(&t, before.span(first).start);
    }
}

/// A block a gesture runs at, with what the probes read about it.
const BlockSite = struct {
    id: AST.Node.Id,
    kind: AST.Node.Kind,
    /// The first text offset inside it.
    caret: usize,
    span: Span,
    in_cell: bool,
    text: []const u8,
};

fn probeInline(t: *Trial, w: Span, k: InlineKind, toggle: bool) Error!void {
    const word = t.source[w.start..w.end];
    const what = if (toggle) "toggle_inline" else "wrap_range";
    var e = try t.open();
    defer e.deinit();
    const result = if (toggle) e.toggleInline(w, k) else e.wrapRange(w, k);
    result catch |err| return t.refused(&e, what, err);
    try t.succeeded(&e, what);
    const got = try findRef(t.gpa, e.astView(), markOf(k), word) orelse
        return t.broken(&e, what, "no {t} over \"{s}\" came back", .{ k, word });
    if (!toggle) return;
    const inner = e.splicer.doc.contentSpan(got) orelse e.splicer.doc.span(got);
    e.toggleInline(inner, k) catch |err| return t.broken(&e, what, "toggling {t} off again is refused: {t}", .{ k, err });
    if (!std.mem.eql(u8, t.source, e.sourceBytes()))
        return t.broken(&e, what, "toggling {t} over \"{s}\" twice does not give the source back", .{ k, word });
}

fn probeLink(t: *Trial, w: Span) Error!void {
    const word = t.source[w.start..w.end];
    var e = try t.open();
    defer e.deinit();
    e.insertLink(w, "https://x.dev/a") catch |err| return t.refused(&e, "insert_link", err);
    try t.succeeded(&e, "insert_link");
    const id = try findText(t.gpa, e.astView(), isLink, word) orelse
        return t.broken(&e, "insert_link", "no link over \"{s}\" came back", .{word});
    const dest = e.astView().nodes[id].kind.link.destination;
    if (dest == null or !std.mem.eql(u8, dest.?, "https://x.dev/a"))
        return t.broken(&e, "insert_link", "the link over \"{s}\" lost its destination", .{word});
}

fn probeImage(t: *Trial, w: Span) Error!void {
    const word = t.source[w.start..w.end];
    var e = try t.open();
    defer e.deinit();
    e.insertImage(w, "cat.png") catch |err| return t.refused(&e, "insert_image", err);
    try t.succeeded(&e, "insert_image");
    _ = try findText(t.gpa, e.astView(), isImage, word) orelse
        return t.broken(&e, "insert_image", "no image over \"{s}\" came back", .{word});
}

fn probeFootnote(t: *Trial, w: Span) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.insertFootnote(w.end, "n1") catch |err| return t.refused(&e, "insert_footnote", err);
    try t.succeeded(&e, "insert_footnote");
    for (e.astView().nodes) |n| switch (n.kind) {
        .footnote => |f| if (std.mem.eql(u8, f.label, "n1")) return,
        else => {},
    };
    return t.broken(&e, "insert_footnote", "no definition labelled n1 came back", .{});
}

/// The formula both math probes write: an operator and a backslash, so a
/// table that escaped the body, or cut it at a byte it treats as markup, is
/// caught by the text not coming back.
const probe_formula = "\\alpha+1";

fn probeInlineMath(t: *Trial, w: Span) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.insertInlineMath(w.end, probe_formula) catch |err| return t.refused(&e, "insert_inline_math", err);
    try t.succeeded(&e, "insert_inline_math");
    if (!holdsFormula(e.astView(), .inline_math))
        return t.broken(&e, "insert_inline_math", "no inline formula holding {s} came back", .{probe_formula});
}

fn probeDisplayMath(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.insertDisplayMath(b.caret, probe_formula) catch |err| return t.refused(&e, "insert_display_math", err);
    try t.succeeded(&e, "insert_display_math");
    if (!holdsFormula(e.astView(), .display_math))
        return t.broken(&e, "insert_display_math", "no display formula holding {s} came back", .{probe_formula});
}

fn holdsFormula(ast: *const AST, kind: AST.TextLeafKind) bool {
    for (ast.nodes) |n| switch (n.kind) {
        .text_leaf => |l| if (l.kind == kind and std.mem.eql(u8, l.text, probe_formula)) return true,
        else => {},
    };
    return false;
}

fn probeLiteral(t: *Trial, w: Span) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    e.insertLiteral(w.end, literal_specials) catch |err| return t.refused(&e, "insert_literal", err);
    try t.succeeded(&e, "insert_literal");
    if (count(e.astView(), isMarkup) != count(ast, isMarkup))
        return t.broken(&e, "insert_literal", "a literal minted markup", .{});
    const was = try select.textOf(t.gpa, ast, ast.root);
    defer t.gpa.free(was);
    const now = try select.textOf(t.gpa, e.astView(), e.astView().root);
    defer t.gpa.free(now);
    const at = std.mem.indexOf(u8, now, literal_specials);
    const kept = at != null and now.len == was.len + literal_specials.len and
        std.mem.eql(u8, now[0..at.?], was[0..at.?]) and std.mem.eql(u8, now[at.? + literal_specials.len ..], was[at.?..]);
    if (!kept) return t.broken(&e, "insert_literal", "the text is not the old text with the literal in it", .{});
}

fn probeSplit(t: *Trial, w: Span) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    const mid = w.start + 1;
    e.splitBlock(mid) catch |err| return t.refused(&e, "split_block", err);
    try t.succeeded(&e, "split_block");
    const was = try select.textOf(t.gpa, ast, ast.root);
    defer t.gpa.free(was);
    const now = try select.textOf(t.gpa, e.astView(), e.astView().root);
    defer t.gpa.free(now);
    if (countNonSpace(was) != countNonSpace(now)) return t.broken(&e, "split_block", "the text changed", .{});
    if (!Editor.supports(t.entry.syntax, .join_blocks)) return;
    // The second half starts where the first ended, past the separator.
    const second = std.mem.indexOfPos(u8, e.sourceBytes(), mid, t.source[mid..w.end]) orelse
        return t.broken(&e, "split_block", "the second half is not in the source", .{});
    e.joinBlocks(second) catch |err| return t.broken(&e, "split_block", "joining the halves back is refused: {t}", .{err});
    // A join continues the block onto its next line — a soft break where the
    // split was, not the bytes it started from — so what comes back is one
    // block holding the text.
    try t.succeeded(&e, "split_block, then join_blocks");
    if (count(e.astView(), isPara) != count(ast, isPara))
        return t.broken(&e, "split_block", "joining the halves back does not give one block", .{});
    const joined = try select.textOf(t.gpa, e.astView(), e.astView().root);
    defer t.gpa.free(joined);
    if (countNonSpace(joined) != countNonSpace(was))
        return t.broken(&e, "split_block", "joining the halves back changed the text", .{});
}

fn probeWrapAttrs(t: *Trial, w: Span) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.wrapRangeAttrs(w, claim_attrs.entries) catch |err| return t.refused(&e, "wrap_range_attrs", err);
    try t.succeeded(&e, "wrap_range_attrs");
}

fn probeSetBlock(t: *Trial, b: BlockSite) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    e.setBlock(b.caret, .heading, 2) catch |err| return t.refused(&e, "set_block heading", err);
    try t.succeeded(&e, "set_block heading");
    const h = try findText(t.gpa, e.astView(), isHeading, b.text) orelse
        return t.broken(&e, "set_block heading", "no heading over \"{s}\" came back", .{b.text});
    if (e.astView().nodes[h].kind.heading.level != 2)
        return t.broken(&e, "set_block heading", "the heading is not level 2", .{});
    // The block changes kind where it stands: every container it was in, it
    // is still in.
    if (count(e.astView(), isContainerBlock) != count(ast, isContainerBlock))
        return t.broken(&e, "set_block heading", "a container around the block was lost", .{});
    e.setBlock(caretIn(&e.splicer.doc, h), .paragraph, 0) catch |err|
        return t.broken(&e, "set_block heading", "setting it back to a paragraph is refused: {t}", .{err});
    if (!e.astView().eql(ast.*))
        return t.broken(&e, "set_block heading", "setting it back to a paragraph does not give the tree back", .{});
}

fn probeContainer(t: *Trial, b: BlockSite, k: ContainerKind) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.toggleBlockContainer(b.span, k) catch |err| return t.refused(&e, "toggle_block_container", err);
    try t.succeeded(&e, "toggle_block_container");
    const p = try findText(t.gpa, e.astView(), isPara, b.text) orelse
        try findText(t.gpa, e.astView(), isParaOrItem, b.text) orelse
        return t.broken(&e, "toggle_block_container", "the paragraph \"{s}\" is gone", .{b.text});
    // A bullet list whose items carry boxes is a task list.
    const inside = withinTag(e.astView(), p, containerTag(k)) or
        (k == .bullet_list and withinTag(e.astView(), p, .task_list));
    if (!inside and !withinTag(&t.before.ast, b.id, containerTag(k)))
        return t.broken(&e, "toggle_block_container", "\"{s}\" is not inside a {t}", .{ b.text, k });
}

fn probeCodeBlock(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.toggleCodeBlock(b.span, "zig") catch |err| return t.refused(&e, "toggle_code_block", err);
    try t.succeeded(&e, "toggle_code_block");
    // The paragraph's bytes where the format fences them as they are, its
    // text where a renderer prints a fresh block (HTML's `<pre>`).
    const bytes = std.mem.trim(u8, t.source[b.span.start..b.span.end], "\n");
    for (e.astView().nodes) |n| switch (n.kind) {
        .code_block => |c| if (c.lang != null and std.mem.eql(u8, c.lang.?, "zig")) {
            const body = std.mem.trim(u8, c.text, "\n");
            if (std.mem.eql(u8, body, bytes) or std.mem.eql(u8, body, b.text)) return;
        },
        else => {},
    };
    return t.broken(&e, "toggle_code_block", "no zig code block holding the paragraph came back", .{});
}

fn probeCodeLanguage(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.setCodeLanguage(b.span.start, "py") catch |err| return t.refused(&e, "set_code_language", err);
    try t.succeeded(&e, "set_code_language");
    for (e.astView().nodes) |n| switch (n.kind) {
        .code_block => |c| if (c.lang != null and std.mem.eql(u8, c.lang.?, "py") and std.mem.eql(u8, c.text, b.kind.code_block.text)) return,
        else => {},
    };
    return t.broken(&e, "set_code_language", "no py code block with the same text came back", .{});
}

fn probeTaskItem(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.toggleTaskItem(b.caret) catch |err| return t.refused(&e, "toggle_task_item", err);
    try t.succeeded(&e, "toggle_task_item");
    const moved = std.mem.indexOf(u8, e.sourceBytes(), b.text) orelse
        return t.broken(&e, "toggle_task_item", "the item's text is gone", .{});
    e.toggleTaskItem(moved) catch |err| return t.broken(&e, "toggle_task_item", "toggling it back is refused: {t}", .{err});
    // A box is added unchecked, so a ticked one comes back unticked: the
    // round trip is the identity from a plain item or an open box.
    if (tickedItem(&t.before.ast, b.id)) return;
    if (!e.astView().eql(t.before.ast)) return t.broken(&e, "toggle_task_item", "toggling twice does not give the tree back", .{});
}

fn probeTaskChecked(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.toggleTaskChecked(b.caret) catch |err| return t.refused(&e, "toggle_task_checked", err);
    try t.succeeded(&e, "toggle_task_checked");
    e.toggleTaskChecked(b.caret) catch |err| return t.broken(&e, "toggle_task_checked", "toggling it back is refused: {t}", .{err});
    if (!std.mem.eql(u8, t.source, e.sourceBytes())) return t.broken(&e, "toggle_task_checked", "toggling twice does not give the source back", .{});
}

fn probeRule(t: *Trial, b: BlockSite) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    e.insertThematicBreak(b.caret) catch |err| return t.refused(&e, "insert_thematic_break", err);
    try t.succeeded(&e, "insert_thematic_break");
    if (count(e.astView(), isRule) != count(ast, isRule) + 1)
        return t.broken(&e, "insert_thematic_break", "there is not one rule more", .{});
    if (count(e.astView(), isPara) != count(ast, isPara))
        return t.broken(&e, "insert_thematic_break", "a paragraph became something else", .{});
}

fn probeJoin(t: *Trial, b: BlockSite) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    e.joinBlocks(b.caret) catch |err| return t.refused(&e, "join_blocks", err);
    t.joins = true;
    defer t.joins = false;
    try t.succeeded(&e, "join_blocks");
    const was = try select.textOf(t.gpa, ast, ast.root);
    defer t.gpa.free(was);
    const now = try select.textOf(t.gpa, e.astView(), e.astView().root);
    defer t.gpa.free(now);
    if (countNonSpace(was) != countNonSpace(now)) return t.broken(&e, "join_blocks", "the text changed", .{});
}

fn probeInsertTable(t: *Trial, b: BlockSite) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    e.insertTable(b.caret, 2, 2) catch |err| return t.refused(&e, "insert_table", err);
    try t.succeeded(&e, "insert_table");
    if (count(e.astView(), isTable) != count(ast, isTable) + 1)
        return t.broken(&e, "insert_table", "there is not one table more", .{});
    if (count(e.astView(), isPara) != count(ast, isPara))
        return t.broken(&e, "insert_table", "a paragraph became something else", .{});
}

fn probeDirective(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.insertDirective(b.caret, "x-embed", null, &.{.{ .key = "src", .value = "x.html" }}) catch |err|
        return t.refused(&e, "insert_directive", err);
    try t.succeeded(&e, "insert_directive");
}

fn probeBlockAttrs(t: *Trial, b: BlockSite) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.setBlockAttrs(b.caret, claim_attrs.entries) catch |err| return t.refused(&e, "set_block_attrs", err);
    try t.succeeded(&e, "set_block_attrs");
}

fn probeMove(t: *Trial, b: BlockSite) Error!void {
    const ast = &t.before.ast;
    var e = try t.open();
    defer e.deinit();
    e.moveBlock(b.caret, t.source.len) catch |err| return t.refused(&e, "move_block", err);
    try t.succeeded(&e, "move_block");
    const was = try select.textOf(t.gpa, ast, ast.root);
    defer t.gpa.free(was);
    const now = try select.textOf(t.gpa, e.astView(), e.astView().root);
    defer t.gpa.free(now);
    if (countNonSpace(was) != countNonSpace(now)) return t.broken(&e, "move_block", "text was lost or gained", .{});
}

fn probeRenumber(t: *Trial, caret: usize) Error!void {
    var e = try t.open();
    defer e.deinit();
    e.renumberOrderedLists(caret) catch |err| return t.refused(&e, "renumber_ordered_lists", err);
    try t.succeeded(&e, "renumber_ordered_lists");
}

fn countNonSpace(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) n += 1;
    }
    return n;
}

/// A paragraph, or a list item whose text stands in one's place: AsciiDoc's
/// item holds its principal text directly.
/// Whether `id` sits in a task item whose box is ticked.
fn tickedItem(ast: *const AST, id: AST.Node.Id) bool {
    for (ast.nodes, 0..) |n, i| switch (n.kind) {
        .task_list_item => |item| if (item.checked and isDescendant(ast, @intCast(i), id)) return true,
        else => {},
    };
    return false;
}

fn isContainerBlock(k: AST.Node.Kind) bool {
    return switch (k) {
        .block_quote, .bullet_list, .ordered_list, .task_list, .list_item, .task_list_item => true,
        else => false,
    };
}

fn isParaOrItem(k: AST.Node.Kind) bool {
    return k == .para or k == .list_item;
}

fn isLink(k: AST.Node.Kind) bool {
    return k == .link;
}
fn isImage(k: AST.Node.Kind) bool {
    return k == .image;
}
fn isHeading(k: AST.Node.Kind) bool {
    return k == .heading;
}

fn withinTag(ast: *const AST, id: AST.Node.Id, tag: std.meta.Tag(AST.Node.Kind)) bool {
    for (ast.nodes, 0..) |n, i| {
        if (std.meta.activeTag(n.kind) == tag and isDescendant(ast, @intCast(i), id)) return true;
    }
    return false;
}

/// A table's shape: its rows, and its first row's cells.
const Shape = struct { rows: usize, cols: usize };

fn shapeOf(ast: *const AST, id: AST.Node.Id) Shape {
    var rows: usize = 0;
    var cols: usize = 0;
    var row = ast.nodes[id].first_child;
    while (row) |rid| : (row = ast.nodes[rid].next_sibling) {
        if (ast.nodes[rid].kind != .row) continue;
        if (rows == 0) {
            var c = ast.nodes[rid].first_child;
            while (c) |cid| : (c = ast.nodes[cid].next_sibling) cols += 1;
        }
        rows += 1;
    }
    return .{ .rows = rows, .cols = cols };
}

/// The table holding `offset`, or — after an edit that moved its end — the
/// one starting where it did.
fn tableAt(doc: *const Document, offset: usize) ?AST.Node.Id {
    for (doc.ast.nodes, 0..) |n, i| {
        if (n.kind != .table) continue;
        const sp = doc.span(@intCast(i));
        if (offset >= sp.start and offset <= sp.end) return @intCast(i);
    }
    return null;
}

fn tableStartingAt(doc: *const Document, start: usize) ?AST.Node.Id {
    for (doc.ast.nodes, 0..) |n, i| {
        if (n.kind == .table and doc.span(@intCast(i)).start == start) return @intCast(i);
    }
    return null;
}

fn tableGestures(t: *Trial, caret: usize) Error!void {
    if (!Editor.supports(t.entry.syntax, .table_insert_row)) return;
    inline for (0..8) |n| try t.keep(probeTable(t, caret, n));
}

fn probeTable(t: *Trial, caret: usize, comptime n: usize) Error!void {
    const table = t.entry.syntax;
    const id = tableAt(t.before, caret) orelse return;
    const shape = shapeOf(&t.before.ast, id);
    const start = t.before.span(id).start;
    const names = [_][]const u8{
        "table_insert_row",    "table_delete_row", "table_insert_column", "table_delete_column",
        "table_set_alignment", "table_move_row",   "table_move_column",   "insert_line_break",
    };
    const drows = [_]isize{ 1, -1, 0, 0, 0, 0, 0, 0 };
    const dcols = [_]isize{ 0, 0, 1, -1, 0, 0, 0, 0 };
    const what = names[n];
    if (n == 7 and !Editor.supports(table, .insert_line_break)) return;
    // The table is the target: its own bytes are the ones a table edit
    // rewrites.
    const was_target = t.target;
    t.target = id;
    defer t.target = was_target;
    var e = try t.open();
    defer e.deinit();
    const result = switch (n) {
        0 => e.tableInsertRow(caret, true),
        1 => e.tableDeleteRow(caret),
        2 => e.tableInsertColumn(caret, true),
        3 => e.tableDeleteColumn(caret),
        4 => e.tableSetAlignment(caret, .center),
        5 => e.tableMoveRow(caret, true),
        6 => e.tableMoveColumn(caret, true),
        7 => e.insertLineBreak(caret),
        else => unreachable,
    };
    result catch |err| return t.refused(&e, what, err);
    try t.succeeded(&e, what);
    const now = tableStartingAt(&e.splicer.doc, start) orelse
        return t.broken(&e, what, "the table is gone", .{});
    const after = shapeOf(e.astView(), now);
    if (@as(isize, @intCast(after.rows)) != @as(isize, @intCast(shape.rows)) + drows[n] or
        @as(isize, @intCast(after.cols)) != @as(isize, @intCast(shape.cols)) + dcols[n])
        return t.broken(&e, what, "the table is {d}x{d}, from {d}x{d}", .{ after.rows, after.cols, shape.rows, shape.cols });
}

test "contract: the traps recorded in Syntax's doc comments are caught" {
    const gpa = std.testing.allocator;
    // HTML with a pipe-table spelling: its parser lowers `<table>` to the
    // same nodes a pipe table produces, so a table edit extracts the grid
    // and splices pipes over the elements — which reparse as a paragraph.
    {
        var table = format.syntaxFor(.html).*;
        table.table_spelling = format.syntaxFor(.markdown).table_spelling;
        var entry = format.entryFor(.html).*;
        entry.syntax = &table;
        entry.syntaxFor = null;
        var log: std.ArrayList(u8) = .empty;
        defer log.deinit(gpa);
        var report: Report = .{ .log = &log };
        try std.testing.expectError(error.ContractBroken, gestures(gpa, &entry, &report));
        // Both halves of the trap: a table the gesture mints, and a table
        // edit that leaves none behind.
        try std.testing.expect(std.mem.indexOf(u8, log.items, "insert_table over sample 1: there is not one table more") != null);
        try std.testing.expect(std.mem.indexOf(u8, log.items, "table_insert_row over the richer document: the table is gone") != null);
    }
    // A rule spelled in bytes the parser does not read back as one: the
    // gesture reports success, and the document holds a paragraph.
    {
        var table = format.syntaxFor(.djot).*;
        table.thematic_break = "~ ~ ~";
        var entry = format.entryFor(.djot).*;
        entry.syntax = &table;
        var report: Report = .{};
        try std.testing.expectError(error.ContractBroken, gestures(gpa, &entry, &report));
        try std.testing.expect(std.mem.indexOf(u8, report.message(), "insert_thematic_break") != null);
    }
}
