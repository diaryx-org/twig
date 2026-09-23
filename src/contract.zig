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
/// moved across its containers.
pub fn all(gpa: Allocator, entry: *const format.Entry, r: *Report) Error!void {
    try samples(gpa, entry, r);
    try renderers(gpa, entry, r);
    if (entry.syntax.authorable()) try moveBlock(gpa, entry, r);
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
