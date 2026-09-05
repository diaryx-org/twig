//! The AsciiDoc TCK's ASG (Abstract Semantic Graph) codec — `decode` turns one
//! expected ASG (a corpus case's `asg`, JSON straight from the AsciiDoc
//! Language Working Group's TCK or from twig's own authored corpus) into
//! twig's shared `Document`; `encode` turns a `Document` — decoded or parsed —
//! back. The conformance harness (`conformance.zig`) asserts
//! `encode(decode(x)) == x` and `encode(parse(x.adoc)) == x`, structurally
//! (`jsonValueEql`), exactly as `languages/rst/doctree.zig` does for docutils'
//! pformat.
//!
//! ── Why structural comparison, not byte-for-byte ────────────────────────────
//! rST's pformat is a bespoke text grammar with no whitespace freedom, so
//! `doctree.zig` compares bytes. The TCK's ASG is JSON — a format with no
//! canonical key order or spacing — so pinning `encode` to the TCK's own
//! pretty-printer would be testing a formatting accident. `encode` writes
//! ASG-shaped JSON and the harness parses both sides back into
//! `std.json.Value` and compares with `jsonValueEql`, which treats objects as
//! unordered key sets and arrays as ordered.
//!
//! ── Location, and why this codec doesn't dodge it ───────────────────────────
//! `ast/ast.zig`'s rule is "this file holds MEANING, not POSITION" — position
//! belongs in `Document`'s span side-tables. The ASG carries a location on
//! EVERY node, as an inclusive `[{line,col},{line,col}]` pair (1-based), so
//! `decode` converts each to a byte `Span` against the case's own `.adoc`
//! source (`offsetOfLineCol`) and `encode` converts back (`lineColOfOffset`).
//!
//! ── Everything ASG-only is DERIVED from source, never stored ────────────────
//! The ASG says more about a block than twig's tree does: its `form` and
//! `delimiter`, a span's `form`, a list's `marker`, and the whole `metadata`
//! object (`$1`-style positionals, roles, options, the attribute line's own
//! location). None of it is stored on the tree, because `AST.Attrs` is the
//! channel a document's REAL attributes travel in and
//! `languages/html/serializer.zig` renders every entry it finds there —
//! parking codec bookkeeping in `attrs` put `<pre name="listing"
//! form="delimited">` into rendered HTML. Instead `encode` re-reads each
//! block's own source: its leading metadata lines through `parser.zig`'s
//! `matchMetaLine`/`AttrIter` (the very scanners that parsed them), its
//! delimiter off its first body line, a span's form off its own first two
//! bytes. That works because a block's span STARTS AT ITS FIRST METADATA LINE
//! (see `parser.zig`'s doc comment), which every case in twig's authored
//! corpus also asserts.
//!
//! ── The shape mapping ──────────────────────────────────────────────────────
//! `listing`/`literal`/`stem` -> `code_block`; `pass` -> `raw_block`;
//! `verse` -> `line_block`; `paragraph` -> `para`, or `para` > `image` for an
//! `image::` macro; `quote` -> `block_quote`; `admonition` -> the container
//! NAMED by its variant (`note`, `tip`, …, the node a Markdown `:::note` also
//! produces); `example`/`sidebar`/`open` -> `container` of that name;
//! `audio`/`video`/`toc` -> a leaf `container` whose `argument` is the
//! target; `heading` (discrete) -> a bare `heading`; `list` -> `bullet_list`
//! (or `task_list` when every item carries a checkbox) / `ordered_list`
//! (callouts included); `dlist` -> `definition_list`; `break` -> a
//! `thematic_break` or the `page-break` container; the document's
//! `attributes` map -> a synthetic `document-attributes` marker whose mere
//! presence signals the key. Inlines: `text` -> `str`; `span` -> an
//! `inline_mark` (`code` -> a `verbatim` leaf); `ref` -> `link`; `charref` ->
//! a `str` of the decoded character; `raw` -> `raw_inline`.
//!
//! ── What draft-01 has no shape for, and what `encode` writes instead ───────
//! AsciiDoc has constructs the schema does not model yet — tables,
//! superscript/subscript, curved quotes, inline images, footnotes, anchors,
//! attribute references, hard breaks, role spans, body attribute entries,
//! front matter, and the paragraph and Markdown-style forms of a quote or
//! admonition. `encode` writes each as an object of the same SHAPE as its
//! nearest schema neighbour under a name the schema does not use (`table`,
//! `footnote`, `attributeReference`, `linebreak`, …), so a tree the parser can
//! produce always encodes rather than crashing, and the extension is visible
//! as such. No corpus case carries one: the corpus is validated against the
//! schema, and these are covered by unit tests on the parser instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Document = @import("../../document.zig");
const Span = @import("../../span.zig");
const parser = @import("parser.zig");

/// Which JSON shape a case's `asg` field holds — the TCK's two test levels.
pub const Root = enum { document, inlines };

/// Vocabulary coverage, tallied by `decode`: `semantic` instances decoded to
/// a kind with real meaning in twig's model, `generic` instances fell to
/// `Kind.container`, and `text_nodes` is `semantic`'s `str` subset.
pub const Coverage = struct {
    semantic: u32 = 0,
    generic: u32 = 0,
    text_nodes: u32 = 0,
};

fn bump(coverage: ?*Coverage, comptime field: []const u8) void {
    if (coverage) |c| @field(c, field) += 1;
}

/// A decode failure: an ASG shape the codec has no reading for (a twig
/// extension, a verse whose lines carry markup). Surfaced as a normal error
/// rather than `unreachable` so a corpus refresh fails the harness loudly.
pub const DecodeError = error{UnsupportedAsgNode} || Allocator.Error;

const LineCol = struct { line: u32, col: u32 };

fn offsetOfLineCol(source: []const u8, line: u32, col: u32) usize {
    var l: u32 = 1;
    var i: usize = 0;
    while (l < line) : (l += 1) {
        i = (std.mem.indexOfScalarPos(u8, source, i, '\n') orelse unreachable) + 1;
    }
    return i + (col - 1);
}

fn lineColOfOffset(source: []const u8, offset: usize) LineCol {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..offset], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(offset - line_start + 1) };
}

fn spanFromLoc(source: []const u8, loc: std.json.Value) Span {
    const start = loc.array.items[0].object;
    const end = loc.array.items[1].object;
    const s = offsetOfLineCol(source, @intCast(start.get("line").?.integer), @intCast(start.get("col").?.integer));
    const e = offsetOfLineCol(source, @intCast(end.get("line").?.integer), @intCast(end.get("col").?.integer));
    return Span.init(s, e + 1);
}

fn obj(v: std.json.Value) std.json.ObjectMap {
    return v.object;
}
fn arr(v: std.json.Value) []const std.json.Value {
    return v.array.items;
}
fn str(v: std.json.Value) []const u8 {
    return v.string;
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── decode ──────────────────────────────────────────────────────────────────

/// Decode `value` (a case's `asg` field, shaped by `root`) against its own
/// `.adoc` source into an owned `Document`. `source` is BORROWED by the
/// returned `Document`, exactly like every other parser's contract.
pub fn decode(
    allocator: Allocator,
    source: []const u8,
    root: Root,
    value: std.json.Value,
    coverage: ?*Coverage,
) DecodeError!Document {
    var d = Decoder{ .b = AST.Builder.init(allocator), .source = source, .coverage = coverage };
    errdefer d.b.deinit();
    const root_id = switch (root) {
        .document => try d.document(value),
        .inlines => blk: {
            const ids = try d.inlineList(arr(value));
            defer allocator.free(ids);
            break :blk try d.b.addContainer(.doc, ids);
        },
    };
    return d.b.finishDocument(source, root_id);
}

const Decoder = struct {
    b: AST.Builder,
    source: []const u8,
    coverage: ?*Coverage,

    fn alloc(self: *Decoder) Allocator {
        return self.b.allocator;
    }

    fn loc(self: *Decoder, o: std.json.ObjectMap) ?Span {
        const v = o.get("location") orelse return null;
        return spanFromLoc(self.source, v);
    }

    fn setLoc(self: *Decoder, id: Node.Id, o: std.json.ObjectMap) void {
        if (self.loc(o)) |s| self.b.setSpan(id, s);
    }

    fn document(self: *Decoder, value: std.json.Value) DecodeError!Node.Id {
        const o = obj(value);
        var children = std.ArrayList(Node.Id).empty;
        defer children.deinit(self.alloc());

        if (o.get("attributes")) |attrs_val| {
            const marker = try self.b.addNode(.{ .container = .{ .name = "document-attributes" } });
            self.b.setSpelling(marker, .{ .container_origin = .directive });
            var entries = std.ArrayList(AST.KeyVal).empty;
            defer entries.deinit(self.alloc());
            var it = obj(attrs_val).iterator();
            while (it.next()) |e| {
                try entries.append(self.alloc(), .{
                    .key = e.key_ptr.*,
                    .value = switch (e.value_ptr.*) {
                        .null => null,
                        .string => |s| s,
                        else => return error.UnsupportedAsgNode,
                    },
                });
            }
            try self.b.setAttrs(marker, .{ .entries = entries.items });
            bump(self.coverage, "generic");
            try children.append(self.alloc(), marker);
        }

        if (o.get("header")) |header_val| {
            const ho = obj(header_val);
            const title_ids = try self.inlineList(arr(ho.get("title").?));
            defer self.alloc().free(title_ids);
            const heading = try self.b.addContainer(.{ .heading = .{ .level = 1 } }, title_ids);
            self.setLoc(heading, ho);
            bump(self.coverage, "semantic");
            try children.append(self.alloc(), heading);
        }

        if (o.get("blocks")) |blocks_val| {
            for (arr(blocks_val)) |bv| try children.append(self.alloc(), try self.block(bv));
        }

        const id = try self.b.addContainer(.doc, children.items);
        self.setLoc(id, o);
        bump(self.coverage, "semantic");
        return id;
    }

    fn blocks(self: *Decoder, o: std.json.ObjectMap, out: *std.ArrayList(Node.Id)) DecodeError!void {
        if (o.get("blocks")) |bv| {
            for (arr(bv)) |v| try out.append(self.alloc(), try self.block(v));
        }
    }

    fn block(self: *Decoder, value: std.json.Value) DecodeError!Node.Id {
        const o = obj(value);
        const name = str(o.get("name").?);
        const source_span = self.loc(o);

        if (eql(name, "paragraph")) {
            const inlines = try self.inlineList(arr(o.get("inlines").?));
            defer self.alloc().free(inlines);
            const id = try self.b.addContainer(.para, inlines);
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        if (eql(name, "list")) {
            const variant = str(o.get("variant").?);
            var items = std.ArrayList(Node.Id).empty;
            defer items.deinit(self.alloc());
            for (arr(o.get("items").?)) |item| try items.append(self.alloc(), try self.listItem(item));
            const marker = str(o.get("marker").?);
            const kind: Node.Kind = if (eql(variant, "unordered"))
                .{ .bullet_list = .{ .tight = true } }
            else if (eql(variant, "ordered")) blk: {
                const m = parser.classifyMarker(marker) orelse return error.UnsupportedAsgNode;
                if (m.kind != .ordered) return error.UnsupportedAsgNode;
                break :blk .{ .ordered_list = .{ .numbering = m.numbering, .tight = true, .start = m.start } };
            } else if (eql(variant, "callout"))
                .{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = null } }
            else
                return error.UnsupportedAsgNode;
            const id = try self.b.addContainer(kind, items.items);
            self.setLoc(id, o);
            if (kind == .bullet_list) self.b.setSpelling(id, .{ .bullet = try bulletFromMarker(marker) });
            bump(self.coverage, "semantic");
            return id;
        }

        if (eql(name, "dlist")) {
            var items = std.ArrayList(Node.Id).empty;
            defer items.deinit(self.alloc());
            for (arr(o.get("items").?)) |item| try items.append(self.alloc(), try self.dlistItem(item));
            const id = try self.b.addContainer(.definition_list, items.items);
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        if (eql(name, "heading")) {
            const level: u32 = @intCast(o.get("level").?.integer);
            const title_ids = try self.inlineList(arr(o.get("title").?));
            defer self.alloc().free(title_ids);
            const id = try self.b.addContainer(.{ .heading = .{ .level = level + 1 } }, title_ids);
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        if (isLeafName(name)) return self.leafBlock(o, name, source_span);

        if (eql(name, "break")) {
            const variant = str(o.get("variant").?);
            const id = if (eql(variant, "thematic"))
                try self.b.addNode(.thematic_break)
            else if (eql(variant, "page")) blk: {
                const pb = try self.b.addNode(.{ .container = .{ .name = "page-break" } });
                self.b.setSpelling(pb, .{ .container_origin = .directive });
                break :blk pb;
            } else return error.UnsupportedAsgNode;
            self.setLoc(id, o);
            if (eql(variant, "thematic")) bump(self.coverage, "semantic") else bump(self.coverage, "generic");
            return id;
        }

        if (isMacroName(name)) return self.blockMacro(o, name, source_span);

        if (isCompoundBlock(name)) {
            var children = std.ArrayList(Node.Id).empty;
            defer children.deinit(self.alloc());
            try self.blocks(o, &children);
            var kind: Node.Kind = undefined;
            var semantic = false;
            if (eql(name, "quote")) {
                kind = .block_quote;
                semantic = true;
            } else if (eql(name, "admonition")) {
                const variant = str(o.get("variant").?);
                kind = .{ .container = .{ .name = variant, .form = .block_fenced } };
            } else {
                kind = .{ .container = .{ .name = name, .form = .block_fenced } };
            }
            const id = try self.b.addContainer(kind, children.items);
            if (kind == .container) self.b.setSpelling(id, .{ .container_origin = .directive });
            self.setLoc(id, o);
            if (semantic) bump(self.coverage, "semantic") else bump(self.coverage, "generic");
            return id;
        }

        if (eql(name, "section")) {
            const level: u32 = @intCast(o.get("level").?.integer);
            const title_ids = try self.inlineList(arr(o.get("title").?));
            defer self.alloc().free(title_ids);
            const heading = try self.b.addContainer(.{ .heading = .{ .level = level + 1 } }, title_ids);
            // The heading's own extent is the title line — the line the
            // title's first inline sits on, or the section's first line.
            if (title_ids.len > 0) {
                const first = self.b.spans.items[title_ids[0]];
                const line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..first.start], '\n')) |nl| nl + 1 else 0;
                const line_end = std.mem.indexOfScalarPos(u8, self.source, first.start, '\n') orelse self.source.len;
                self.b.setSpan(heading, Span.init(line_start, std.mem.trimEnd(u8, self.source[0..line_end], " \t").len));
            }
            bump(self.coverage, "semantic");
            var children = std.ArrayList(Node.Id).empty;
            defer children.deinit(self.alloc());
            try children.append(self.alloc(), heading);
            try self.blocks(o, &children);
            const id = try self.b.addContainer(.section, children.items);
            self.setLoc(id, o);
            if (o.get("id")) |sid| try self.b.setAttrs(id, .{ .entries = &.{.{ .key = "id", .value = str(sid) }} });
            bump(self.coverage, "semantic");
            return id;
        }

        return error.UnsupportedAsgNode;
    }

    /// `listing`, `literal`, `stem` -> `code_block`; `pass` -> `raw_block`;
    /// `verse` -> `line_block`. An empty block has no `inlines` key; its
    /// content span stays unset, which is what `encode` reads back.
    fn leafBlock(self: *Decoder, o: std.json.ObjectMap, name: []const u8, source_span: ?Span) DecodeError!Node.Id {
        const inlines = if (o.get("inlines")) |v| arr(v) else &[_]std.json.Value{};
        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.alloc());
        var inner: ?Span = null;
        for (inlines) |inl| {
            const io = obj(inl);
            if (!eql(str(io.get("name").?), "text")) return error.UnsupportedAsgNode;
            try text.appendSlice(self.alloc(), str(io.get("value").?));
            const sp = spanFromLoc(self.source, io.get("location").?);
            inner = if (inner) |s| Span.init(s.start, sp.end) else sp;
        }
        if (eql(name, "verse")) {
            const id = try self.verse(inner);
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }
        var id: Node.Id = undefined;
        if (eql(name, "pass")) {
            id = try self.b.addLeaf(.{ .raw_block = .{ .format = "html", .text = text.items } });
        } else {
            // The language: from a `[source,lang]` line in the block's own source.
            const lang = if (source_span) |ss| sourceLanguage(self.source[ss.start..ss.end], name) else null;
            id = try self.b.addLeaf(.{ .code_block = .{ .lang = lang, .text = text.items } });
        }
        self.setLoc(id, o);
        if (inner) |sp| self.b.setContentSpan(id, sp);
        bump(self.coverage, "semantic");
        return id;
    }

    /// A verse's lines, split out of its content span's source. Markup inside
    /// a verse is not decodable this way (the TCK has none), so a verse whose
    /// inlines are anything but text is refused above.
    fn verse(self: *Decoder, content: ?Span) DecodeError!Node.Id {
        var lines = std.ArrayList(Node.Id).empty;
        defer lines.deinit(self.alloc());
        if (content) |c| {
            const text = self.source[c.start..c.end];
            var widths = std.ArrayList(usize).empty;
            defer widths.deinit(self.alloc());
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |l| {
                const w = l.len - std.mem.trimStart(u8, l, " \t").len;
                if (l.len == w) continue;
                if (std.mem.indexOfScalar(usize, widths.items, w) == null) try widths.append(self.alloc(), w);
            }
            std.mem.sort(usize, widths.items, {}, std.sort.asc(usize));
            var offset = c.start;
            var it2 = std.mem.splitScalar(u8, text, '\n');
            while (it2.next()) |l| {
                const w = l.len - std.mem.trimStart(u8, l, " \t").len;
                const body = l[w..];
                const depth: u32 = if (body.len == 0) 0 else @intCast(std.mem.indexOfScalar(usize, widths.items, w).?);
                var kids: [1]Node.Id = undefined;
                var n: usize = 0;
                if (body.len > 0) {
                    kids[0] = try self.b.addLeaf(.{ .str = body });
                    self.b.setSpan(kids[0], Span.init(offset + w, offset + l.len));
                    n = 1;
                }
                const line_id = try self.b.addContainer(.{ .line = .{ .indent = depth } }, kids[0..n]);
                self.b.setSpan(line_id, Span.init(offset, offset + l.len));
                try lines.append(self.alloc(), line_id);
                offset += l.len + 1;
            }
        }
        const id = try self.b.addContainer(.line_block, lines.items);
        if (content) |c| self.b.setContentSpan(id, c);
        return id;
    }

    /// `image::` -> `para` > `image`; `audio::`/`video::`/`toc::` -> a leaf
    /// container carrying the target as its argument. The image's alt text
    /// and size come from the macro's own source, as they do for the parser.
    fn blockMacro(self: *Decoder, o: std.json.ObjectMap, name: []const u8, source_span: ?Span) DecodeError!Node.Id {
        const target: ?[]const u8 = if (o.get("target")) |t| str(t) else null;
        if (eql(name, "image")) {
            const t = target orelse return error.UnsupportedAsgNode;
            var kids: [1]Node.Id = undefined;
            var n: usize = 0;
            var attrs: [2]AST.KeyVal = undefined;
            var na: usize = 0;
            if (source_span) |ss| {
                const line = lastLine(self.source[ss.start..ss.end]);
                if (parser.matchBlockMacroText(line)) |m| {
                    var it = parser.AttrIter.init(m.attrs);
                    while (it.next()) |e| {
                        const key = e.key orelse switch (e.index) {
                            1 => "alt",
                            2 => "width",
                            3 => "height",
                            else => continue,
                        };
                        if (eql(key, "alt")) {
                            if (e.value.len > 0) {
                                kids[0] = try self.b.addLeaf(.{ .str = e.value });
                                const line_start = ss.end - line.len;
                                const at = line_start + (std.mem.indexOf(u8, line, e.value) orelse 0);
                                self.b.setSpan(kids[0], Span.init(at, at + e.value.len));
                                n = 1;
                            }
                        } else if ((eql(key, "width") or eql(key, "height")) and na < 2) {
                            attrs[na] = .{ .key = key, .value = e.value };
                            na += 1;
                        }
                    }
                }
            }
            const img = try self.b.addContainer(.{ .image = .{ .destination = t, .reference = null } }, kids[0..n]);
            if (source_span) |ss| self.b.setSpan(img, Span.init(ss.end - lastLine(self.source[ss.start..ss.end]).len, ss.end));
            if (na > 0) try self.b.setAttrs(img, .{ .entries = attrs[0..na] });
            const id = try self.b.addContainer(.para, &.{img});
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }
        const id = try self.b.addNode(.{ .container = .{ .name = name, .form = .block_leaf, .argument = if (target) |t| (if (t.len > 0) t else null) else null } });
        self.b.setSpelling(id, .{ .container_origin = .directive });
        self.setLoc(id, o);
        bump(self.coverage, "generic");
        return id;
    }

    fn listItem(self: *Decoder, value: std.json.Value) DecodeError!Node.Id {
        const o = obj(value);
        var kids = std.ArrayList(Node.Id).empty;
        defer kids.deinit(self.alloc());
        const principal = try self.inlineList(arr(o.get("principal").?));
        defer self.alloc().free(principal);
        try kids.appendSlice(self.alloc(), principal);
        try self.blocks(o, &kids);
        const id = try self.b.addContainer(.list_item, kids.items);
        self.setLoc(id, o);
        const marker = str(o.get("marker").?);
        if (marker[0] == '*' or marker[0] == '-') self.b.setSpelling(id, .{ .bullet = try bulletFromMarker(marker) });
        bump(self.coverage, "semantic");
        return id;
    }

    fn dlistItem(self: *Decoder, value: std.json.Value) DecodeError!Node.Id {
        const o = obj(value);
        var kids = std.ArrayList(Node.Id).empty;
        defer kids.deinit(self.alloc());
        for (arr(o.get("terms").?)) |term_val| {
            const ids = try self.inlineList(arr(term_val));
            defer self.alloc().free(ids);
            const term = try self.b.addContainer(.term, ids);
            if (ids.len > 0) self.b.setSpan(term, Span.init(self.b.spans.items[ids[0]].start, self.b.spans.items[ids[ids.len - 1]].end));
            try kids.append(self.alloc(), term);
            bump(self.coverage, "semantic");
        }
        var def_kids = std.ArrayList(Node.Id).empty;
        defer def_kids.deinit(self.alloc());
        if (o.get("principal")) |p| {
            const ids = try self.inlineList(arr(p));
            defer self.alloc().free(ids);
            try def_kids.appendSlice(self.alloc(), ids);
        }
        try self.blocks(o, &def_kids);
        if (def_kids.items.len > 0) {
            const def = try self.b.addContainer(.definition, def_kids.items);
            self.b.setSpan(def, Span.init(self.b.spans.items[def_kids.items[0]].start, self.b.spans.items[def_kids.items[def_kids.items.len - 1]].end));
            try kids.append(self.alloc(), def);
            bump(self.coverage, "semantic");
        }
        const id = try self.b.addContainer(.definition_list_item, kids.items);
        self.setLoc(id, o);
        bump(self.coverage, "semantic");
        return id;
    }

    fn inlineList(self: *Decoder, items: []const std.json.Value) DecodeError![]Node.Id {
        var ids = std.ArrayList(Node.Id).empty;
        errdefer ids.deinit(self.alloc());
        for (items) |item| try ids.append(self.alloc(), try self.inlineNode(item));
        return ids.toOwnedSlice(self.alloc());
    }

    fn inlineNode(self: *Decoder, value: std.json.Value) DecodeError!Node.Id {
        const o = obj(value);
        const name = str(o.get("name").?);

        if (eql(name, "text")) {
            const id = try self.b.addLeaf(.{ .str = str(o.get("value").?) });
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            bump(self.coverage, "text_nodes");
            return id;
        }

        if (eql(name, "charref")) {
            var buf: [4]u8 = undefined;
            const decoded = parser.decodeCharref(str(o.get("value").?), &buf) orelse return error.UnsupportedAsgNode;
            const id = try self.b.addLeaf(.{ .str = decoded });
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        if (eql(name, "raw")) {
            const id = try self.b.addLeaf(.{ .raw_inline = .{ .format = "html", .text = str(o.get("value").?) } });
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        if (eql(name, "span")) {
            const variant = str(o.get("variant").?);
            if (eql(variant, "code")) {
                const inlines = arr(o.get("inlines").?);
                if (inlines.len != 1) return error.UnsupportedAsgNode;
                const inner = obj(inlines[0]);
                if (!eql(str(inner.get("name").?), "text")) return error.UnsupportedAsgNode;
                const id = try self.b.addLeaf(.{ .text_leaf = .{ .kind = .verbatim, .text = str(inner.get("value").?) } });
                self.setLoc(id, o);
                self.b.setContentSpan(id, spanFromLoc(self.source, inner.get("location").?));
                bump(self.coverage, "semantic");
                return id;
            }
            const mark = markFromVariant(variant) orelse return error.UnsupportedAsgNode;
            const inlines = try self.inlineList(arr(o.get("inlines").?));
            defer self.alloc().free(inlines);
            const id = try self.b.addContainer(.{ .inline_mark = mark }, inlines);
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        if (eql(name, "ref")) {
            const variant = str(o.get("variant").?);
            const target = str(o.get("target").?);
            const inlines = try self.inlineList(arr(o.get("inlines").?));
            defer self.alloc().free(inlines);
            var dest: []const u8 = target;
            var owned: ?[]u8 = null;
            defer if (owned) |s| self.alloc().free(s);
            if (eql(variant, "xref")) {
                if (std.mem.indexOfScalar(u8, target, '#') == null) {
                    owned = try std.fmt.allocPrint(self.alloc(), "#{s}", .{target});
                    dest = owned.?;
                }
            } else if (!eql(variant, "link")) return error.UnsupportedAsgNode;
            const id = try self.b.addContainer(.{ .link = .{ .destination = dest, .reference = null } }, inlines);
            self.setLoc(id, o);
            bump(self.coverage, "semantic");
            return id;
        }

        return error.UnsupportedAsgNode;
    }
};

fn isLeafName(name: []const u8) bool {
    inline for (.{ "listing", "literal", "pass", "stem", "verse" }) |n| {
        if (eql(name, n)) return true;
    }
    return false;
}

fn isCompoundBlock(name: []const u8) bool {
    inline for (.{ "example", "sidebar", "open", "quote", "admonition" }) |n| {
        if (eql(name, n)) return true;
    }
    return false;
}

fn isMacroName(name: []const u8) bool {
    inline for (.{ "image", "audio", "video", "toc" }) |n| {
        if (eql(name, n)) return true;
    }
    return false;
}

fn bulletFromMarker(marker: []const u8) DecodeError!Document.Spelling.Bullet {
    if (marker.len == 0) return error.UnsupportedAsgNode;
    return switch (marker[0]) {
        '*' => .star,
        '-' => .dash,
        '+' => .plus,
        else => error.UnsupportedAsgNode,
    };
}

fn lastLine(text: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, text, "\n");
    const nl = std.mem.lastIndexOfScalar(u8, t, '\n') orelse return t;
    return t[nl + 1 ..];
}

/// The `lang` a leaf block's own source names: `[source,ruby]`, `[,ruby]`,
/// a backtick fence's info string, or the stem style itself.
fn sourceLanguage(text: []const u8, name: []const u8) ?[]const u8 {
    if (eql(name, "stem")) return "stem";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const m = parser.matchMetaLine(line) orelse {
            if (parser.matchFenceLine(std.mem.trimEnd(u8, line, " \t"))) |f| return if (f.info.len > 0) f.info else null;
            return null;
        };
        switch (m) {
            .attrs => |interior| {
                var ait = parser.AttrIter.init(interior);
                while (ait.next()) |e| {
                    if (e.key) |k| {
                        if (eql(k, "language")) return e.value;
                    } else if (e.index == 2 and e.value.len > 0) return e.value;
                }
            },
            else => {},
        }
    }
    return null;
}

/// The ASG `span` variants that become an `AST.InlineMark`.
fn markFromVariant(variant: []const u8) ?AST.InlineMark {
    if (eql(variant, "strong")) return .strong;
    if (eql(variant, "emphasis")) return .emph;
    if (eql(variant, "mark")) return .mark;
    return null;
}

/// The inverse of `markFromVariant`, plus the names `encode` gives the marks
/// the schema has no variant for.
fn variantFromMark(mark: AST.InlineMark) []const u8 {
    return switch (mark) {
        .strong => "strong",
        .emph => "emphasis",
        .mark => "mark",
        .superscript => "superscript",
        .subscript => "subscript",
        .insert => "insert",
        .delete => "delete",
        .double_quoted => "double_quoted",
        .single_quoted => "single_quoted",
    };
}

// ── source-derived facts ───────────────────────────────────────────────────

/// A block's leading metadata lines, re-read from its own source. See this
/// file's doc comment for why nothing here is stored on the tree.
const Meta = struct {
    /// Offset of the block's first body line (after the metadata lines).
    body_start: usize,
    title: ?[]const u8 = null,
    title_at: usize = 0,
    id: ?[]const u8 = null,
    reftext: ?[]const u8 = null,
    reftext_at: usize = 0,
    style: ?[]const u8 = null,
    /// The `[…]` attribute lines' extent, when there is at least one.
    attr_lines: ?Span = null,
};

fn scanMeta(doc: *const Document, id: Node.Id) Meta {
    const span = doc.span(id);
    var meta: Meta = .{ .body_start = span.start };
    // Only a block that starts on a line of its own can carry metadata.
    if (span.start > 0 and doc.source[span.start - 1] != '\n') return meta;
    var pos = span.start;
    while (pos < span.end) {
        const nl = std.mem.indexOfScalarPos(u8, doc.source, pos, '\n') orelse doc.source.len;
        const line_end = @min(nl, span.end);
        const line = doc.source[pos..line_end];
        const m = parser.matchMetaLine(line) orelse break;
        switch (m) {
            .title => |t| {
                meta.title = t;
                meta.title_at = pos + 1;
            },
            .anchor => |a| {
                meta.id = a.id;
                if (a.reftext) |r| {
                    meta.reftext = r;
                    meta.reftext_at = pos + (std.mem.indexOf(u8, line, r) orelse 0);
                }
                meta.attr_lines = if (meta.attr_lines) |al| Span.init(al.start, line_end) else Span.init(pos, line_end);
            },
            .attrs => |interior| {
                meta.attr_lines = if (meta.attr_lines) |al| Span.init(al.start, line_end) else Span.init(pos, line_end);
                var it = parser.AttrIter.init(interior);
                while (it.next()) |e| {
                    if (e.key) |k| {
                        if (eql(k, "id")) meta.id = e.value;
                    } else if (e.index == 1) {
                        var sit = parser.ShorthandIter.init(e.value);
                        while (sit.next()) |p| switch (p.kind) {
                            .style => meta.style = p.text,
                            .id => meta.id = p.text,
                            else => {},
                        };
                    }
                }
            },
        }
        pos = nl + 1;
        if (nl >= span.end) break;
    }
    meta.body_start = @min(pos, span.end);
    return meta;
}

/// The block's source after its metadata lines.
fn bodyText(doc: *const Document, id: Node.Id, meta: Meta) []const u8 {
    return doc.source[meta.body_start..doc.span(id).end];
}

/// The first body line, which for a delimited block IS the delimiter.
fn firstLine(text: []const u8) []const u8 {
    const t = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return std.mem.trimEnd(u8, t, " \t");
}

/// The delimiter a body's first line spells, or null: a run of four or more
/// of one delimiter byte, `--`, `|===`, or a backtick fence (whose info
/// string is not part of the delimiter).
fn delimiterOf(line: []const u8) ?[]const u8 {
    if (parser.matchFenceLine(line)) |f| return f.fence;
    return if (isDelimiterLine(line)) line else null;
}

/// Whether `line` is a block delimiter (a run of four or more of one
/// delimiter byte, `--`, a backtick fence, or `|===`).
fn isDelimiterLine(line: []const u8) bool {
    if (eql(line, "--")) return true;
    if (parser.matchFenceLine(line) != null) return true;
    if (parser.isTableDelimiterLine(line)) return true;
    if (line.len < 4) return false;
    if (std.mem.indexOfScalar(u8, "-.+=_*/", line[0]) == null) return false;
    for (line[1..]) |c| if (c != line[0]) return false;
    return true;
}

/// A span's ASG `form`, read off its source: the unconstrained spelling is
/// exactly `DD` + at least one byte + `DD`. BOTH ends are checked, since a
/// CONSTRAINED span whose interior begins with the delimiter opens with two
/// delimiter bytes too (`**bold*`).
fn spanForm(doc: *const Document, id: Node.Id) []const u8 {
    var s = doc.text(id);
    // A `[.role]` prefix is part of the span's extent but not of its form.
    if (s.len > 0 and s[0] == '[') {
        if (std.mem.indexOfScalar(u8, s, ']')) |close| s = s[close + 1 ..];
    }
    const unconstrained = s.len >= 5 and s[0] == s[1] and s[s.len - 1] == s[s.len - 2] and s[0] == s[s.len - 1] and
        std.mem.indexOfScalar(u8, "*_`#", s[0]) != null;
    return if (unconstrained) "unconstrained" else "constrained";
}

/// A `str` that the parser made from a character reference: its source is
/// `&…;` and reads as something else.
fn charrefSource(doc: *const Document, id: Node.Id) ?[]const u8 {
    const s = doc.text(id);
    var buf: [4]u8 = undefined;
    const decoded = parser.decodeCharref(s, &buf) orelse return null;
    return if (eql(decoded, doc.ast.nodes[id].kind.str)) s else null;
}

// ── encode ──────────────────────────────────────────────────────────────────

/// Write `doc` back out as ASG-shaped JSON, `root`-dependent at the top level
/// exactly as `decode` was. Handles every shape `parser.zig` produces — the
/// schema's, and the extensions this file's doc comment lists.
pub fn encode(allocator: Allocator, doc: *const Document, root: Root, writer: *Writer) (Writer.Error || Allocator.Error)!void {
    var w: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    var e = Encoder{ .allocator = allocator, .w = &w, .doc = doc };
    switch (root) {
        .document => try e.document(doc.ast.root),
        .inlines => {
            try w.beginArray();
            try e.inlinesOf(doc.ast.root);
            try w.endArray();
        },
    }
}

pub fn encodeAlloc(allocator: Allocator, doc: *const Document, root: Root) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    encode(allocator, doc, root, &out.writer) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

const EncodeError = Writer.Error || Allocator.Error;

const Encoder = struct {
    allocator: Allocator,
    w: *std.json.Stringify,
    doc: *const Document,

    fn kindOf(self: *const Encoder, id: Node.Id) Node.Kind {
        return self.doc.ast.nodes[id].kind;
    }

    fn field(self: *Encoder, name: []const u8, value: anytype) EncodeError!void {
        try self.w.objectField(name);
        try self.w.write(value);
    }

    fn nameType(self: *Encoder, name: []const u8, ty: []const u8) EncodeError!void {
        try self.field("name", name);
        try self.field("type", ty);
    }

    fn point(self: *Encoder, offset: usize) EncodeError!void {
        const lc = lineColOfOffset(self.doc.source, offset);
        try self.w.beginObject();
        try self.field("line", lc.line);
        try self.field("col", lc.col);
        try self.w.endObject();
    }

    /// `"location": [...]` for a half-open span, converted back to the ASG's
    /// inclusive pair. An EMPTY span has no location the ASG can spell, so
    /// none is written — `location` is optional throughout the schema.
    fn locOf(self: *Encoder, span: Span) EncodeError!void {
        if (span.end <= span.start) return;
        try self.w.objectField("location");
        try self.w.beginArray();
        try self.point(span.start);
        try self.point(span.end - 1);
        try self.w.endArray();
    }

    fn loc(self: *Encoder, id: Node.Id) EncodeError!void {
        try self.locOf(self.doc.span(id));
    }

    /// One `text` node with an explicit value and extent.
    fn textNode(self: *Encoder, value: []const u8, span: Span) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("text", "string");
        try self.field("value", value);
        try self.locOf(span);
        try self.w.endObject();
    }

    // ── document ─────────────────────────────────────────────────────────

    fn document(self: *Encoder, id: Node.Id) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("document", "block");

        var attrs_id: ?Node.Id = null;
        var header_id: ?Node.Id = null;
        var has_body = false;
        {
            var it = self.doc.children(id);
            while (it.next()) |c| {
                switch (self.kindOf(c.id)) {
                    .container => |cnt| if (eql(cnt.name, "document-attributes")) {
                        attrs_id = c.id;
                        continue;
                    },
                    // The document title: a level-1 heading directly under
                    // the root (a section's own title hangs off the section).
                    .heading => |h| if (h.level == 1 and header_id == null and attrs_id != null) {
                        header_id = c.id;
                        continue;
                    },
                    else => {},
                }
                has_body = true;
            }
        }

        if (attrs_id != null) {
            // The explicit `:name: value` entries, re-read from the header's
            // own lines; the author line's implicit attributes are not among
            // them, and the header's `authors` array carries those instead.
            try self.w.objectField("attributes");
            try self.w.beginObject();
            if (header_id) |hid| {
                const header = self.doc.text(hid);
                var it = std.mem.splitScalar(u8, header, '\n');
                _ = it.next(); // the title line
                while (it.next()) |line| {
                    const entry = parser.matchAttrEntry(line) orelse continue;
                    try self.w.objectField(entry.key);
                    try self.w.write(entry.value);
                }
            }
            try self.w.endObject();
        }

        if (header_id) |hid| {
            try self.w.objectField("header");
            try self.w.beginObject();
            try self.w.objectField("title");
            try self.w.beginArray();
            try self.inlinesOf(hid);
            try self.w.endArray();
            try self.authors(hid);
            try self.loc(hid);
            try self.w.endObject();
        }

        if (has_body) {
            try self.w.objectField("blocks");
            try self.w.beginArray();
            var it = self.doc.children(id);
            while (it.next()) |c| {
                if (c.id == attrs_id or c.id == header_id) continue;
                try self.block(c.id);
            }
            try self.w.endArray();
        }

        try self.loc(id);
        try self.w.endObject();
    }

    /// `header.authors`, from the line after the title when it is one.
    fn authors(self: *Encoder, hid: Node.Id) EncodeError!void {
        const header = self.doc.text(hid);
        var it = std.mem.splitScalar(u8, header, '\n');
        _ = it.next();
        const line = it.next() orelse return;
        if (!parser.isAuthorLine(line) or parser.matchAttrEntry(line) != null) return;
        var ait = parser.AuthorIter.init(line);
        var any = false;
        while (ait.next()) |a| {
            if (!any) {
                try self.w.objectField("authors");
                try self.w.beginArray();
                any = true;
            }
            try self.w.beginObject();
            try self.field("fullname", a.fullname);
            var ibuf: [3]u8 = undefined;
            try self.field("initials", a.initials(&ibuf));
            try self.field("firstname", a.firstname);
            if (a.middlename) |m| try self.field("middlename", m);
            if (a.lastname) |l| try self.field("lastname", l);
            if (a.email) |e| try self.field("address", e);
            try self.w.endObject();
        }
        if (any) try self.w.endArray();
    }

    // ── blocks ───────────────────────────────────────────────────────────

    /// `id`, `title`, `reftext` and `metadata`, from the block's own leading
    /// lines. Written into an already-open object.
    fn blockMeta(self: *Encoder, meta: Meta) EncodeError!void {
        if (meta.id) |i| try self.field("id", i);
        if (meta.title) |t| {
            try self.w.objectField("title");
            try self.w.beginArray();
            try self.textNode(t, Span.init(meta.title_at, meta.title_at + t.len));
            try self.w.endArray();
        }
        if (meta.reftext) |r| {
            try self.w.objectField("reftext");
            try self.w.beginArray();
            try self.textNode(r, Span.init(meta.reftext_at, meta.reftext_at + r.len));
            try self.w.endArray();
        }
        const lines = meta.attr_lines orelse return;
        // Anything but a bare anchor line gets a `metadata` object.
        var any_attr_line = false;
        var it = std.mem.splitScalar(u8, self.doc.source[lines.start..lines.end], '\n');
        while (it.next()) |line| {
            if (parser.matchMetaLine(line)) |m| if (m == .attrs) {
                any_attr_line = true;
            };
        }
        if (!any_attr_line) return;
        try self.w.objectField("metadata");
        try self.w.beginObject();
        // Three passes over the same lines, one per array — cheaper to read
        // than buffering, and the lines are a handful at most.
        inline for (.{ "attributes", "roles", "options" }) |which| {
            var wrote = false;
            var lit = std.mem.splitScalar(u8, self.doc.source[lines.start..lines.end], '\n');
            while (lit.next()) |line| {
                const m = parser.matchMetaLine(line) orelse continue;
                const interior = switch (m) {
                    .attrs => |i| i,
                    else => continue,
                };
                var ait = parser.AttrIter.init(interior);
                while (ait.next()) |e| {
                    if (comptime eql(which, "attributes")) {
                        if (e.key) |k| {
                            if (eql(k, "id") or eql(k, "role") or eql(k, "options") or eql(k, "opts") or eql(k, "title")) continue;
                            try self.openMetaField(&wrote, which, .object);
                            try self.field(k, e.value);
                        } else if (e.index == 1) {
                            var sit = parser.ShorthandIter.init(e.value);
                            while (sit.next()) |p| if (p.kind == .style) {
                                try self.openMetaField(&wrote, which, .object);
                                try self.field("$1", p.text);
                            };
                        } else {
                            try self.openMetaField(&wrote, which, .object);
                            var kbuf: [16]u8 = undefined;
                            try self.field(std.fmt.bufPrint(&kbuf, "${d}", .{e.index}) catch unreachable, e.value);
                        }
                    } else if (comptime eql(which, "roles")) {
                        if (e.key) |k| {
                            if (!eql(k, "role")) continue;
                            var rit = std.mem.tokenizeScalar(u8, e.value, ' ');
                            while (rit.next()) |r| {
                                try self.openMetaField(&wrote, which, .array);
                                try self.w.write(r);
                            }
                        } else if (e.index == 1) {
                            var sit = parser.ShorthandIter.init(e.value);
                            while (sit.next()) |p| if (p.kind == .role) {
                                try self.openMetaField(&wrote, which, .array);
                                try self.w.write(p.text);
                            };
                        }
                    } else {
                        if (e.key) |k| {
                            if (!eql(k, "options") and !eql(k, "opts")) continue;
                            var oit = std.mem.tokenizeAny(u8, e.value, ", ");
                            while (oit.next()) |o| {
                                try self.openMetaField(&wrote, which, .array);
                                try self.w.write(o);
                            }
                        } else if (e.index == 1) {
                            var sit = parser.ShorthandIter.init(e.value);
                            while (sit.next()) |p| if (p.kind == .option) {
                                try self.openMetaField(&wrote, which, .array);
                                try self.w.write(p.text);
                            };
                        }
                    }
                }
            }
            if (wrote) {
                if (comptime eql(which, "attributes")) try self.w.endObject() else try self.w.endArray();
            }
        }
        try self.locOf(lines);
        try self.w.endObject();
    }

    fn openMetaField(self: *Encoder, wrote: *bool, name: []const u8, shape: enum { object, array }) EncodeError!void {
        if (wrote.*) return;
        wrote.* = true;
        try self.w.objectField(name);
        switch (shape) {
            .object => try self.w.beginObject(),
            .array => try self.w.beginArray(),
        }
    }

    fn block(self: *Encoder, id: Node.Id) EncodeError!void {
        const meta = scanMeta(self.doc, id);
        const body = bodyText(self.doc, id, meta);
        switch (self.kindOf(id)) {
            .para => {
                // A paragraph holding only an `image::` macro IS the macro.
                if (std.mem.startsWith(u8, body, "image::")) {
                    if (self.doc.ast.nodes[id].first_child) |img| if (self.kindOf(img) == .image) {
                        try self.w.beginObject();
                        try self.nameType("image", "block");
                        try self.field("form", "macro");
                        if (self.kindOf(img).image.destination) |d| try self.field("target", d);
                        try self.blockMeta(meta);
                        try self.loc(id);
                        try self.w.endObject();
                        return;
                    };
                }
                try self.w.beginObject();
                try self.nameType("paragraph", "block");
                try self.w.objectField("inlines");
                try self.w.beginArray();
                try self.inlinesOf(id);
                try self.w.endArray();
                try self.blockMeta(meta);
                try self.loc(id);
                try self.w.endObject();
            },
            .code_block => |cb| try self.leafBlock(id, meta, body, leafNameOf(meta, body, "listing"), cb.text),
            .raw_block => |rb| try self.leafBlock(id, meta, body, "pass", rb.text),
            .line_block => try self.verseBlock(id, meta, body),
            .block_quote => try self.parentBlock(id, meta, body, "quote", null),
            .container => |c| {
                if (eql(c.name, "page-break")) {
                    try self.w.beginObject();
                    try self.nameType("break", "block");
                    try self.field("variant", "page");
                    try self.blockMeta(meta);
                    try self.loc(id);
                    try self.w.endObject();
                } else if (c.form == .block_leaf and isMacroName(c.name)) {
                    try self.w.beginObject();
                    try self.nameType(c.name, "block");
                    try self.field("form", "macro");
                    if (c.argument) |a| try self.field("target", a);
                    try self.blockMeta(meta);
                    try self.loc(id);
                    try self.w.endObject();
                } else if (parser.admonitionName(upperName(c.name))) |_| {
                    try self.parentBlock(id, meta, body, "admonition", c.name);
                } else {
                    try self.parentBlock(id, meta, body, c.name, null);
                }
            },
            .bullet_list, .task_list => try self.list(id, meta, "unordered"),
            .ordered_list => {
                const marker = itemMarker(self.doc, self.doc.ast.nodes[id].first_child);
                try self.list(id, meta, if (marker.len > 0 and marker[0] == '<') "callout" else "ordered");
            },
            .definition_list => try self.dlist(id, meta),
            .heading => |h| {
                try self.w.beginObject();
                try self.nameType("heading", "block");
                try self.w.objectField("title");
                try self.w.beginArray();
                try self.inlinesOf(id);
                try self.w.endArray();
                try self.field("level", h.level - 1);
                try self.blockMeta(meta);
                try self.loc(id);
                try self.w.endObject();
            },
            .section => {
                try self.w.beginObject();
                try self.nameType("section", "block");
                var it = self.doc.children(id);
                const heading_id = it.next().?.id;
                try self.w.objectField("title");
                try self.w.beginArray();
                try self.inlinesOf(heading_id);
                try self.w.endArray();
                try self.field("level", self.kindOf(heading_id).heading.level - 1);
                var m = meta;
                if (m.id == null) m.id = headingAnchor(self.doc.text(heading_id));
                try self.blockMeta(m);
                try self.loc(id);
                var probe = it;
                if (probe.next() != null) {
                    try self.w.objectField("blocks");
                    try self.w.beginArray();
                    while (it.next()) |c| try self.block(c.id);
                    try self.w.endArray();
                }
                try self.w.endObject();
            },
            .thematic_break => {
                try self.w.beginObject();
                try self.nameType("break", "block");
                try self.field("variant", "thematic");
                try self.blockMeta(meta);
                try self.loc(id);
                try self.w.endObject();
            },
            .table => try self.table(id, meta),
            // ── extensions ──
            .substitution => |s| {
                try self.w.beginObject();
                try self.nameType("attributeEntry", "block");
                try self.field("attribute", s.label);
                if (self.doc.ast.attrsOf(id).find("unset") != null) {
                    try self.field("value", null);
                } else {
                    try self.w.objectField("inlines");
                    try self.w.beginArray();
                    try self.inlinesOf(id);
                    try self.w.endArray();
                }
                try self.loc(id);
                try self.w.endObject();
            },
            .metadata => |m| {
                try self.w.beginObject();
                try self.nameType("frontmatter", "block");
                try self.field("lang", m.lang);
                try self.w.objectField("inlines");
                try self.w.beginArray();
                if (self.doc.contentSpan(id)) |cs| try self.textNode(m.text, cs);
                try self.w.endArray();
                try self.loc(id);
                try self.w.endObject();
            },
            // A footnote definition is written at its reference.
            .footnote => {},
            else => unreachable,
        }
    }

    fn leafBlock(self: *Encoder, id: Node.Id, meta: Meta, body: []const u8, name: []const u8, text: []const u8) EncodeError!void {
        try self.w.beginObject();
        try self.nameType(name, "block");
        try self.leafForm(body);
        if (text.len > 0) {
            try self.w.objectField("inlines");
            try self.w.beginArray();
            try self.textNode(text, self.doc.contentSpan(id).?);
            try self.w.endArray();
        }
        try self.blockMeta(meta);
        try self.loc(id);
        try self.w.endObject();
    }

    /// `form` (and `delimiter`) from the body's first line.
    fn leafForm(self: *Encoder, body: []const u8) EncodeError!void {
        const first = firstLine(body);
        if (delimiterOf(first)) |d| {
            try self.field("form", "delimited");
            try self.field("delimiter", d);
        } else if (body.len > 0 and (body[0] == ' ' or body[0] == '\t')) {
            try self.field("form", "indented");
        } else {
            try self.field("form", "paragraph");
        }
    }

    fn verseBlock(self: *Encoder, id: Node.Id, meta: Meta, body: []const u8) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("verse", "block");
        try self.leafForm(body);
        if (self.doc.ast.nodes[id].first_child != null) {
            try self.w.objectField("inlines");
            try self.w.beginArray();
            var fuser = Fuser{ .e = self };
            defer fuser.deinit();
            var it = self.doc.children(id);
            var first = true;
            while (it.next()) |line| {
                const sp = self.doc.span(line.id);
                if (!first) try fuser.text("\n", Span.init(sp.start - 1, sp.start));
                first = false;
                // The indentation the tree records as depth is real source
                // text in the ASG's value.
                var kit = self.doc.children(line.id);
                const body_start = if (self.doc.ast.nodes[line.id].first_child) |fc| self.doc.span(fc).start else sp.end;
                if (body_start > sp.start) try fuser.text(self.doc.source[sp.start..body_start], Span.init(sp.start, body_start));
                while (kit.next()) |c| try fuser.feed(c.id);
            }
            try fuser.flush();
            try self.w.endArray();
        }
        try self.blockMeta(meta);
        try self.loc(id);
        try self.w.endObject();
    }

    /// A parent block. `variant` is set for an admonition.
    fn parentBlock(self: *Encoder, id: Node.Id, meta: Meta, body: []const u8, name: []const u8, variant: ?[]const u8) EncodeError!void {
        try self.w.beginObject();
        try self.nameType(name, "block");
        if (variant) |v| try self.field("variant", v);
        const first = firstLine(body);
        if (delimiterOf(first)) |d| {
            try self.field("form", "delimited");
            try self.field("delimiter", d);
        } else if (body.len > 0 and body[0] == '>') {
            try self.field("form", "delimited");
            try self.field("delimiter", ">");
        } else {
            try self.field("form", "paragraph");
        }
        if (self.doc.ast.nodes[id].first_child != null) {
            try self.w.objectField("blocks");
            try self.w.beginArray();
            var it = self.doc.children(id);
            while (it.next()) |c| try self.block(c.id);
            try self.w.endArray();
        }
        try self.blockMeta(meta);
        try self.loc(id);
        try self.w.endObject();
    }

    fn list(self: *Encoder, id: Node.Id, meta: Meta, variant: []const u8) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("list", "block");
        try self.field("variant", variant);
        try self.field("marker", itemMarker(self.doc, self.doc.ast.nodes[id].first_child));
        try self.w.objectField("items");
        try self.w.beginArray();
        var it = self.doc.children(id);
        while (it.next()) |c| try self.listItem(c.id);
        try self.w.endArray();
        try self.blockMeta(meta);
        try self.loc(id);
        try self.w.endObject();
    }

    fn listItem(self: *Encoder, id: Node.Id) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("listItem", "block");
        try self.field("marker", itemMarker(self.doc, id));
        try self.w.objectField("principal");
        try self.w.beginArray();
        var fuser = Fuser{ .e = self };
        defer fuser.deinit();
        // A checklist item's box is text to a reader of the ASG, which has no
        // checkbox: `[x] ` is written back where the parser found it.
        switch (self.kindOf(id)) {
            .task_list_item => {
                const m = self.doc.markerSpan(id).?;
                const box_end = @min(m.end + 4, self.doc.span(id).end);
                var end = box_end;
                while (end < self.doc.span(id).end and self.doc.source[end] == ' ') end += 1;
                try fuser.text(self.doc.source[m.end..end], Span.init(m.end, end));
            },
            else => {},
        }
        var it = self.doc.children(id);
        var first_block: ?Node.Id = null;
        while (it.next()) |c| {
            if (self.kindOf(c.id).level() == .block) {
                first_block = c.id;
                break;
            }
            try fuser.feed(c.id);
        }
        try fuser.flush();
        try self.w.endArray();
        if (first_block) |fb| {
            try self.w.objectField("blocks");
            try self.w.beginArray();
            var bid: ?Node.Id = fb;
            while (bid) |b| : (bid = self.doc.ast.nodes[b].next_sibling) try self.block(b);
            try self.w.endArray();
        }
        try self.loc(id);
        try self.w.endObject();
    }

    fn dlist(self: *Encoder, id: Node.Id, meta: Meta) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("dlist", "block");
        try self.field("marker", dlistMarker(self.doc, self.doc.ast.nodes[id].first_child));
        try self.w.objectField("items");
        try self.w.beginArray();
        var it = self.doc.children(id);
        while (it.next()) |c| try self.dlistItem(c.id);
        try self.w.endArray();
        try self.blockMeta(meta);
        try self.loc(id);
        try self.w.endObject();
    }

    fn dlistItem(self: *Encoder, id: Node.Id) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("dlistItem", "block");
        try self.field("marker", dlistMarker(self.doc, id));
        try self.w.objectField("terms");
        try self.w.beginArray();
        var definition: ?Node.Id = null;
        var it = self.doc.children(id);
        while (it.next()) |c| switch (self.kindOf(c.id)) {
            .term => {
                try self.w.beginArray();
                try self.inlinesOf(c.id);
                try self.w.endArray();
            },
            .definition => definition = c.id,
            else => {},
        };
        try self.w.endArray();
        if (definition) |def| {
            var dit = self.doc.children(def);
            var first_block: ?Node.Id = null;
            var any_inline = false;
            var fuser = Fuser{ .e = self };
            defer fuser.deinit();
            while (dit.next()) |c| {
                if (self.kindOf(c.id).level() == .block) {
                    first_block = c.id;
                    break;
                }
                if (!any_inline) {
                    try self.w.objectField("principal");
                    try self.w.beginArray();
                    any_inline = true;
                }
                try fuser.feed(c.id);
            }
            try fuser.flush();
            if (any_inline) try self.w.endArray();
            if (first_block) |fb| {
                try self.w.objectField("blocks");
                try self.w.beginArray();
                var bid: ?Node.Id = fb;
                while (bid) |b| : (bid = self.doc.ast.nodes[b].next_sibling) try self.block(b);
                try self.w.endArray();
            }
        }
        try self.loc(id);
        try self.w.endObject();
    }

    /// A table — a twig extension; the ASG (draft-01) does not model tables.
    fn table(self: *Encoder, id: Node.Id, meta: Meta) EncodeError!void {
        try self.w.beginObject();
        try self.nameType("table", "block");
        try self.w.objectField("rows");
        try self.w.beginArray();
        var it = self.doc.children(id);
        while (it.next()) |c| switch (self.kindOf(c.id)) {
            .row => |r| {
                try self.w.beginObject();
                try self.nameType("row", "block");
                if (r.head) try self.field("header", true);
                try self.w.objectField("cells");
                try self.w.beginArray();
                var cit = self.doc.children(c.id);
                while (cit.next()) |cell| {
                    const ck = self.kindOf(cell.id).cell;
                    try self.w.beginObject();
                    try self.nameType("cell", "block");
                    if (ck.colspan != 1) try self.field("colspan", ck.colspan);
                    if (ck.rowspan != 1) try self.field("rowspan", ck.rowspan);
                    if (ck.alignment != .default) try self.field("align", @tagName(ck.alignment));
                    try self.w.objectField("inlines");
                    try self.w.beginArray();
                    try self.inlinesOf(cell.id);
                    try self.w.endArray();
                    try self.loc(cell.id);
                    try self.w.endObject();
                }
                try self.w.endArray();
                try self.loc(c.id);
                try self.w.endObject();
            },
            else => {},
        };
        try self.w.endArray();
        try self.blockMeta(meta);
        try self.loc(id);
        try self.w.endObject();
    }

    // ── inlines ──────────────────────────────────────────────────────────

    /// The children of `id` as an inline list, adjacent text fused.
    fn inlinesOf(self: *Encoder, id: Node.Id) EncodeError!void {
        var fuser = Fuser{ .e = self };
        defer fuser.deinit();
        var it = self.doc.children(id);
        while (it.next()) |c| try fuser.feed(c.id);
        try fuser.flush();
    }

    fn inlineNode(self: *Encoder, id: Node.Id) EncodeError!void {
        switch (self.kindOf(id)) {
            .str => |s| try self.textNode(s, self.doc.span(id)),
            .smart_punctuation => |sp| try self.textNode(glyph(sp), self.doc.span(id)),
            .inline_mark => |m| {
                try self.w.beginObject();
                try self.nameType("span", "inline");
                try self.field("variant", variantFromMark(m));
                try self.field("form", spanForm(self.doc, id));
                try self.inlineAttrs(id);
                try self.w.objectField("inlines");
                try self.w.beginArray();
                try self.inlinesOf(id);
                try self.w.endArray();
                try self.loc(id);
                try self.w.endObject();
            },
            .text_leaf => |leaf| switch (leaf.kind) {
                .verbatim => {
                    try self.w.beginObject();
                    try self.nameType("span", "inline");
                    try self.field("variant", "code");
                    try self.field("form", spanForm(self.doc, id));
                    try self.inlineAttrs(id);
                    try self.w.objectField("inlines");
                    try self.w.beginArray();
                    try self.textNode(leaf.text, self.doc.contentSpan(id).?);
                    try self.w.endArray();
                    try self.loc(id);
                    try self.w.endObject();
                },
                .url, .email => {
                    try self.w.beginObject();
                    try self.nameType("ref", "inline");
                    try self.field("variant", "link");
                    if (leaf.kind == .email) {
                        var buf: [512]u8 = undefined;
                        try self.field("target", std.fmt.bufPrint(&buf, "mailto:{s}", .{leaf.text}) catch leaf.text);
                    } else try self.field("target", leaf.text);
                    try self.w.objectField("inlines");
                    try self.w.beginArray();
                    try self.textNode(leaf.text, self.doc.contentSpan(id) orelse self.doc.span(id));
                    try self.w.endArray();
                    try self.loc(id);
                    try self.w.endObject();
                },
                .inline_math => {
                    try self.w.beginObject();
                    try self.nameType("stem", "inline");
                    try self.w.objectField("inlines");
                    try self.w.beginArray();
                    if (self.doc.contentSpan(id)) |cs| try self.textNode(leaf.text, cs);
                    try self.w.endArray();
                    try self.loc(id);
                    try self.w.endObject();
                },
                .footnote_reference => {
                    try self.w.beginObject();
                    try self.nameType("footnote", "inline");
                    try self.field("target", leaf.text);
                    try self.w.objectField("inlines");
                    try self.w.beginArray();
                    if (self.footnoteDefinition(leaf.text)) |def| {
                        // The definition holds one paragraph of the note's inlines.
                        if (self.doc.ast.nodes[def].first_child) |para| try self.inlinesOf(para);
                    }
                    try self.w.endArray();
                    try self.loc(id);
                    try self.w.endObject();
                },
                .substitution_reference => {
                    try self.w.beginObject();
                    try self.nameType("attributeReference", "inline");
                    try self.field("target", leaf.text);
                    try self.loc(id);
                    try self.w.endObject();
                },
                .symb, .display_math, .citation_reference => unreachable,
            },
            .link => |l| {
                const src = self.doc.text(id);
                const xref = std.mem.startsWith(u8, src, "<<") or std.mem.startsWith(u8, src, "xref:");
                try self.w.beginObject();
                try self.nameType("ref", "inline");
                try self.field("variant", if (xref) "xref" else "link");
                const dest = l.destination orelse "";
                try self.field("target", if (xref and dest.len > 0 and dest[0] == '#') dest[1..] else dest);
                try self.w.objectField("inlines");
                try self.w.beginArray();
                try self.inlinesOf(id);
                try self.w.endArray();
                try self.loc(id);
                try self.w.endObject();
            },
            .image => |im| {
                try self.w.beginObject();
                try self.nameType("image", "inline");
                if (im.destination) |d| try self.field("target", d);
                try self.w.objectField("inlines");
                try self.w.beginArray();
                try self.inlinesOf(id);
                try self.w.endArray();
                try self.loc(id);
                try self.w.endObject();
            },
            .raw_inline => |r| {
                try self.w.beginObject();
                try self.nameType("raw", "string");
                try self.field("value", r.text);
                try self.loc(id);
                try self.w.endObject();
            },
            .non_breaking_space => {
                try self.w.beginObject();
                try self.nameType("charref", "string");
                try self.field("value", "&#160;");
                try self.loc(id);
                try self.w.endObject();
            },
            .hard_break => {
                try self.w.beginObject();
                try self.nameType("linebreak", "inline");
                try self.loc(id);
                try self.w.endObject();
            },
            .container => |c| {
                try self.w.beginObject();
                try self.nameType(if (c.name.len > 0) c.name else "span", "inline");
                if (c.name.len == 0) try self.field("variant", "styled");
                try self.inlineAttrs(id);
                try self.w.objectField("inlines");
                try self.w.beginArray();
                try self.inlinesOf(id);
                try self.w.endArray();
                try self.loc(id);
                try self.w.endObject();
            },
            else => unreachable,
        }
    }

    /// `id` / `roles` on an inline that carries attributes (a `[.role]` span,
    /// an anchor) — an extension the schema's spans have no field for.
    fn inlineAttrs(self: *Encoder, id: Node.Id) EncodeError!void {
        const attrs = self.doc.ast.attrsOf(id);
        if (attrs.get("id")) |i| try self.field("id", i);
        if (attrs.get("class")) |cls| {
            try self.w.objectField("roles");
            try self.w.beginArray();
            var it = std.mem.tokenizeScalar(u8, cls, ' ');
            while (it.next()) |r| try self.w.write(r);
            try self.w.endArray();
        }
    }

    fn footnoteDefinition(self: *const Encoder, label: []const u8) ?Node.Id {
        for (self.doc.ast.nodes) |n| switch (n.kind) {
            .footnote => |f| if (eql(f.label, label)) return n.id,
            else => {},
        };
        return null;
    }
};

/// Fuses runs of adjacent text-bearing inlines (`str`, the replacements the
/// parser reads as `smart_punctuation`, verse line boundaries) into one ASG
/// `text` node whose location spans them all — the ASG has one text node
/// where twig's tree may have several (a `\*` escape, an `--` em dash).
const Fuser = struct {
    e: *Encoder,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,
    end: usize = 0,

    fn deinit(self: *Fuser) void {
        self.buf.deinit(self.e.allocator);
    }

    fn text(self: *Fuser, value: []const u8, span: Span) EncodeError!void {
        if (self.buf.items.len == 0) self.start = span.start;
        try self.buf.appendSlice(self.e.allocator, value);
        self.end = span.end;
    }

    fn feed(self: *Fuser, id: Node.Id) EncodeError!void {
        switch (self.e.kindOf(id)) {
            .str => |s| {
                if (charrefSource(self.e.doc, id)) |raw| {
                    try self.flush();
                    try self.e.w.beginObject();
                    try self.e.nameType("charref", "string");
                    try self.e.field("value", raw);
                    try self.e.loc(id);
                    try self.e.w.endObject();
                    return;
                }
                try self.text(s, self.e.doc.span(id));
            },
            .smart_punctuation => |sp| try self.text(glyph(sp), self.e.doc.span(id)),
            else => {
                try self.flush();
                try self.e.inlineNode(id);
            },
        }
    }

    fn flush(self: *Fuser) EncodeError!void {
        if (self.buf.items.len == 0) return;
        try self.e.textNode(self.buf.items, Span.init(self.start, self.end));
        self.buf.clearRetainingCapacity();
    }
};

/// The character a replacement resolved to — what a processor writes for it.
fn glyph(sp: AST.SmartPunctuationKind) []const u8 {
    return switch (sp) {
        .em_dash => "\u{2014}",
        .en_dash => "\u{2013}",
        .ellipses => "\u{2026}",
        .left_single_quote => "\u{2018}",
        .right_single_quote => "\u{2019}",
        .left_double_quote => "\u{201c}",
        .right_double_quote => "\u{201d}",
    };
}

/// An item's marker as written: the item's source up to its first space.
/// The list's marker is its first item's.
fn itemMarker(doc: *const Document, id: ?Node.Id) []const u8 {
    const i = id orelse return "";
    const s = doc.text(i);
    return s[0 .. std.mem.indexOfScalar(u8, s, ' ') orelse s.len];
}

/// A description list's marker (`::`, `:::`, `;;`), from its first item's
/// source.
fn dlistMarker(doc: *const Document, id: ?Node.Id) []const u8 {
    const i = id orelse return "::";
    const s = doc.text(i);
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    const m = parser.matchListMarkerText(line) orelse return "::";
    return if (m.kind == .description) m.text else "::";
}

/// The leaf-block name for a `code_block`: the style when it names a leaf
/// block, else the delimiter's, else `fallback`.
fn leafNameOf(meta: Meta, body: []const u8, fallback: []const u8) []const u8 {
    if (meta.style) |s| if (parser.isLeafStyle(s)) return parser.leafNameForStyle(s);
    const first = firstLine(body);
    if (isDelimiterLine(first)) {
        return switch (first[0]) {
            '-', '`' => "listing",
            '.' => "literal",
            '+' => "pass",
            else => fallback,
        };
    }
    if (body.len > 0 and (body[0] == ' ' or body[0] == '\t')) return "literal";
    return fallback;
}

/// `note` -> `NOTE`, for `admonitionName`'s label-shaped question.
fn upperName(name: []const u8) []const u8 {
    inline for (.{ "note", "tip", "important", "warning", "caution" }, parser.ADMONITIONS) |lower, upper| {
        if (eql(name, lower)) return upper;
    }
    return name;
}

/// The trailing ` [[id]]` of a heading line, if it carries one.
fn headingAnchor(heading_text: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, heading_text, " \t");
    if (!std.mem.endsWith(u8, t, "]]")) return null;
    const at = std.mem.lastIndexOf(u8, t, " [[") orelse return null;
    const inner = t[at + 3 .. t.len - 2];
    if (inner.len == 0) return null;
    return if (std.mem.indexOfScalar(u8, inner, ',')) |c| inner[0..c] else inner;
}

// ── comparison ──────────────────────────────────────────────────────────────

/// Structural equality over `std.json.Value` trees: objects compare as
/// unordered key sets, arrays compare element-by-element in order.
pub fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| arr_blk: {
            const y = b.array;
            if (x.items.len != y.items.len) break :arr_blk false;
            for (x.items, y.items) |ea, eb| {
                if (!jsonValueEql(ea, eb)) break :arr_blk false;
            }
            break :arr_blk true;
        },
        .object => |x| obj_blk: {
            const y = b.object;
            if (x.count() != y.count()) break :obj_blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = y.get(e.key_ptr.*) orelse break :obj_blk false;
                if (!jsonValueEql(e.value_ptr.*, other)) break :obj_blk false;
            }
            break :obj_blk true;
        },
    };
}
