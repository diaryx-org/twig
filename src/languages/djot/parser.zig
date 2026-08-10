//! Event stream -> AST: a generic container-stack tree builder keyed by a
//! `switch` on `Annotation` (mirrors djot.js's `parse.ts` flat `annot ->
//! handler` dispatch table). This is also where section-nesting-by-heading-
//! level, tight/loose list finalization, and attribute-attachment-to-the-
//! preceding-node all happen — none of that lives in the scanners.
//!
//! Like fig's per-format parsers (e.g. `languages/json/parser.zig`), this
//! manages its own flat, mutable node array directly rather than going
//! through `ast/builder.zig`'s batch-children API: djot.js's tree builder
//! needs to *mutate an already-emitted node* in a few places (a table
//! caption patches the table sibling emitted before it; a heading's
//! attributes may migrate onto the section wrapping it), which doesn't fit
//! `Builder`'s bottom-up, each-node-final-once shape.
//!
//! References and footnotes are never resolved here — `Link`/`Image` nodes
//! carry a label string, and `Document.references`/`.footnotes` are label ->
//! node maps consulted at render time (see djot.js's `parse.ts`/`html.ts`
//! split, documented on `Document.references` in `djot.zig`), which is why
//! `build` produces a `Document` (AST + side tables) rather than a bare
//! `AST`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("../../ast/ast.zig");
const AST = ast_mod;
const Node = AST.Node;
const Document = @import("djot.zig").Document;
const Span = @import("../../span.zig");
const event = @import("event.zig");
const Event = event.Event;
const Annotation = event.Annotation;
const ListMarkerStyle = event.ListMarkerStyle;

// ── small text helpers ──────────────────────────────────────────────────

fn normalizeLabel(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_ws = false;
    for (trimmed) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!in_ws) try out.append(allocator, ' ');
            in_ws = true;
        } else {
            try out.append(allocator, c);
            in_ws = false;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Trim one space adjacent to a backtick at the start/end of verbatim text.
fn trimVerbatim(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    var start: usize = 0;
    var end: usize = s.len;
    if (s.len >= 2 and s[0] == ' ' and s[1] == '`') start = 1;
    if (end >= 2 and s[end - 1] == ' ' and s[end - 2] == '`') end -= 1;
    return allocator.dupe(u8, s[start..end]);
}

fn romanDigit(c: u8) ?u32 {
    return switch (c) {
        'i', 'I' => 1,
        'v', 'V' => 5,
        'x', 'X' => 10,
        'l', 'L' => 50,
        'c', 'C' => 100,
        'd', 'D' => 500,
        'm', 'M' => 1000,
        else => null,
    };
}

fn romanToNumber(s: []const u8) ?u32 {
    var total: i64 = 0;
    var prev: i64 = 0;
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        const n: i64 = romanDigit(s[i]) orelse return null;
        if (n < prev) total -= n else total += n;
        prev = n;
    }
    return if (total < 0) 0 else @intCast(total);
}

/// `event.ListMarkerStyle` and `AST.OrderedListStyle` declare identically-
/// named `Numbering`/`Delim` enums independently (the former is scanning-
/// only scratch state that also needs task/colon/etc. variants the AST has
/// no business knowing about) -- convert explicitly at the one place a
/// scanned marker style becomes a permanent AST node.
fn toAstNumbering(n: ListMarkerStyle.Numbering) AST.OrderedListStyle.Numbering {
    return switch (n) {
        .decimal => .decimal,
        .lower_alpha => .lower_alpha,
        .upper_alpha => .upper_alpha,
        .lower_roman => .lower_roman,
        .upper_roman => .upper_roman,
    };
}

fn toAstDelim(d: ListMarkerStyle.Delim) AST.OrderedListStyle.Delim {
    return switch (d) {
        .period => .period,
        .paren_after => .paren_after,
        .paren_both => .paren_both,
    };
}

fn getListStart(marker: []const u8, numbering: ListMarkerStyle.Numbering) ?u32 {
    // Strip a leading '(' and trailing '.'/')' to get the bare numeral text.
    var s = marker;
    if (s.len > 0 and s[0] == '(') s = s[1..];
    if (s.len > 0 and (s[s.len - 1] == '.' or s[s.len - 1] == ')')) s = s[0 .. s.len - 1];
    if (s.len == 0) return null;
    return switch (numbering) {
        .decimal => std.fmt.parseInt(u32, s, 10) catch null,
        .upper_alpha, .lower_alpha => @as(u32, s[0]) - (if (numbering == .upper_alpha) @as(u32, 'A') else @as(u32, 'a')) + 1,
        .upper_roman, .lower_roman => romanToNumber(s),
    };
}

// ── attribute accumulation (mutable scratch; frozen into AST.Attrs later) ──

/// Mutable, order-preserving attribute accumulator. Mirrors djot.js storing
/// attributes as one plain object: `class`/`id`/arbitrary keys all live in
/// ONE ordered `entries` list (see `AST.Attrs`'s doc comment for why order
/// must survive interleaving, e.g. `{key1=val1 .foo key2=val2}`).
///
/// `owned_bufs` tracks scratch allocations this accumulator itself made
/// (concatenated `class` values, concatenated multi-part quoted attribute
/// values) so they can be freed once, at `deinit` — entries otherwise borrow
/// either source spans or another `PendingAttrs`'s already-owned buffers
/// (safe to reference indefinitely; only `commitAttrs` ever copies into the
/// AST's permanent `owned_strings`).
const PendingAttrs = struct {
    /// Like `AST.KeyVal` but with a NON-optional value: djot attribute
    /// syntax cannot express a bare (valueless) attribute, so keeping the
    /// accumulator's value required saves unwrapping at every use below —
    /// optionality only enters at the `AST.KeyVal` boundary (`commitAttrs`).
    const Entry = struct { key: []const u8, value: []const u8 };

    entries: std.ArrayList(Entry) = .empty,
    owned_bufs: std.ArrayList([]const u8) = .empty,
    pending_key: ?[]const u8 = null,

    fn isEmpty(self: *const PendingAttrs) bool {
        return self.entries.items.len == 0;
    }

    fn deinit(self: *PendingAttrs, allocator: Allocator) void {
        for (self.owned_bufs.items) |b| allocator.free(b);
        self.owned_bufs.deinit(allocator);
        self.entries.deinit(allocator);
    }

    fn indexOf(self: *const PendingAttrs, key: []const u8) ?usize {
        for (self.entries.items, 0..) |kv, i| {
            if (std.mem.eql(u8, kv.key, key)) return i;
        }
        return null;
    }

    fn get(self: *const PendingAttrs, key: []const u8) ?[]const u8 {
        const i = self.indexOf(key) orelse return null;
        return self.entries.items[i].value;
    }

    /// Set (or overwrite) `key`'s value, preserving its first-occurrence
    /// position if it already exists (matches JS object-property mutation
    /// not affecting iteration order).
    fn setKeyval(self: *PendingAttrs, allocator: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        if (self.indexOf(key)) |i| {
            self.entries.items[i].value = value;
            return;
        }
        try self.entries.append(allocator, .{ .key = key, .value = value });
    }

    /// Remove `key` entirely (used when an id migrates from a heading onto
    /// its wrapping section).
    fn remove(self: *PendingAttrs, key: []const u8) void {
        if (self.indexOf(key)) |i| _ = self.entries.orderedRemove(i);
    }

    /// Drop every entry (used to reset the pending block-attributes
    /// accumulator: on a blank line, or once its contents have been drained
    /// into a freshly-pushed container).
    fn clear(self: *PendingAttrs, allocator: Allocator) void {
        for (self.owned_bufs.items) |b| allocator.free(b);
        self.owned_bufs.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
    }

    /// Add one `.class` token: if `class` is already present, its value
    /// grows in place (space-joined) at its FIRST position; else a new
    /// `class` entry is appended wherever this occurs in source order.
    ///
    /// `token` is always copied into `self.owned_bufs`, even on the
    /// fresh-insert path where it might look unnecessary (the common case —
    /// a `.class` event's span is source-backed and would survive without
    /// copying). It's NOT optional in general: `mergeFrom` also calls this
    /// with a `token` that may itself live in the SOURCE `PendingAttrs`'s
    /// `owned_bufs` (e.g. an already-concatenated `"foo bar"` class value),
    /// which gets freed once that source is cleared/deinited — without this
    /// copy, `self` would be left holding a dangling slice.
    fn addClass(self: *PendingAttrs, allocator: Allocator, token: []const u8) Allocator.Error!void {
        if (self.indexOf("class")) |i| {
            const combined = try std.mem.concat(allocator, u8, &.{ self.entries.items[i].value, " ", token });
            try self.owned_bufs.append(allocator, combined);
            self.entries.items[i].value = combined;
        } else {
            const owned = try allocator.dupe(u8, token);
            try self.owned_bufs.append(allocator, owned);
            try self.entries.append(allocator, .{ .key = "class", .value = owned });
        }
    }

    /// Merge `src` into `self` (djot.js's attribute-merge rule: `class`
    /// values accumulate space-joined; everything else -- including `id` --
    /// overwrites, keeping its first-seen position in `self`). Every value
    /// merged in is copied into `self.owned_bufs` (see `addClass`'s doc
    /// comment) since `src` is typically a short-lived container about to
    /// be cleared or deinited by the caller. Keys are never copied: every
    /// key ultimately traces back to a source-text span (attribute keys are
    /// never rewritten, only values accumulate), which outlives everything.
    fn mergeFrom(self: *PendingAttrs, allocator: Allocator, src: *const PendingAttrs) Allocator.Error!void {
        for (src.entries.items) |kv| {
            if (std.mem.eql(u8, kv.key, "class")) {
                try self.addClass(allocator, kv.value);
            } else {
                const owned_val = try allocator.dupe(u8, kv.value);
                try self.owned_bufs.append(allocator, owned_val);
                try self.setKeyval(allocator, kv.key, owned_val);
            }
        }
    }
};

// ── container scratch state ─────────────────────────────────────────────

const ContainerData = struct {
    level: u32 = 0,
    heading_level: ?u32 = null,
    styles: event.ListStyleCandidates = .{},
    tight: bool = true,
    blanklines: bool = false,
    first_marker: ?[]const u8 = null,
    checkbox: ?bool = null,
    is_definition_item: bool = false,
    ref_key: ?[]const u8 = null,
    ref_value: std.ArrayList(u8) = .empty,
    label: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    format: ?[]const u8 = null,
    is_image: bool = false,
    aligns: std.ArrayList(AST.Alignment) = .empty,

    fn deinit(self: *ContainerData, allocator: Allocator) void {
        self.ref_value.deinit(allocator);
        self.aligns.deinit(allocator);
    }
};

const TreeContainer = struct {
    first_child: ?Node.Id = null,
    last_child: ?Node.Id = null,
    attrs: PendingAttrs = .{},
    data: ContainerData = .{},
    start: usize = 0,
    /// For a framed *leaf* built from an `_open`/`_close` pair (inline
    /// `verbatim`/math, `<...>` url/email autolink): the byte offset just
    /// past the opening delimiter — i.e. where the raw interior begins. The
    /// interior ends at the closing event's `start`. `null` when the
    /// container isn't such a leaf. See `leafInteriorSpan`.
    content_start: ?usize = null,
    /// For a `code_block`/`raw_block`: the byte range of its body — the first
    /// body line's start to the last body line's end, both fence lines
    /// excluded — accumulated from the `.str` events between the fences.
    /// `body_start` stays `null` for an empty (bodyless) fenced block, so it
    /// correctly gets no `content_span`.
    body_start: ?usize = null,
    body_end: usize = 0,

    fn deinit(self: *TreeContainer, allocator: Allocator) void {
        self.attrs.deinit(allocator);
        self.data.deinit(allocator);
    }

    fn addChild(self: *TreeContainer, nodes: []Node, id: Node.Id) void {
        if (self.last_child) |lc| {
            nodes[lc].next_sibling = id;
        } else {
            self.first_child = id;
        }
        self.last_child = id;
    }
};

const Context = enum { normal, verbatim, literal };

pub const TreeBuilder = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    /// Parallel to `nodes` — node `id`'s source span. Positions live beside
    /// the arena rather than on the node, matching `ast/builder.zig` and
    /// `src/document.zig`; `addNode` is the only place ids are minted, so the
    /// arrays cannot drift.
    spans: std.ArrayList(Span) = .empty,
    /// Parallel to `nodes` — node `id`'s interior span. See
    /// `Document.node_content_spans`.
    content_spans: std.ArrayList(?Span) = .empty,
    owned_strings: std.ArrayList([]const u8) = .empty,
    attrs_table: std.ArrayList(AST.Attrs) = .empty,
    containers: std.ArrayList(TreeContainer) = .empty,
    context: Context = .normal,
    accumulated_text: std.ArrayList(u8) = .empty,
    references: std.StringHashMapUnmanaged(Node.Id) = .empty,
    auto_references: std.StringHashMapUnmanaged(Node.Id) = .empty,
    footnotes: std.StringHashMapUnmanaged(Node.Id) = .empty,
    identifiers: std.StringHashMapUnmanaged(void) = .empty,
    pending_block_attrs: PendingAttrs = .{},
    list_depth: usize = 0,

    pub fn init(allocator: Allocator, source: []const u8) TreeBuilder {
        return .{ .allocator = allocator, .source = source };
    }

    fn deinitScratch(self: *TreeBuilder) void {
        for (self.containers.items) |*c| c.deinit(self.allocator);
        self.containers.deinit(self.allocator);
        self.accumulated_text.deinit(self.allocator);
        self.pending_block_attrs.deinit(self.allocator);
        self.identifiers.deinit(self.allocator);
    }

    // ── owned-string / node helpers (mirrors ast/builder.zig's discipline:
    // every string is copied so the finished AST never borrows `source`) ──

    fn own(self: *TreeBuilder, s: []const u8) Allocator.Error![]const u8 {
        const copy = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(copy);
        try self.owned_strings.append(self.allocator, copy);
        return copy;
    }

    fn ownMove(self: *TreeBuilder, s: []u8) Allocator.Error![]const u8 {
        errdefer self.allocator.free(s);
        try self.owned_strings.append(self.allocator, s);
        return s;
    }

    fn addNode(self: *TreeBuilder, kind: Node.Kind, span: Span) Allocator.Error!Node.Id {
        const id: Node.Id = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .id = id, .kind = try self.dupeKind(kind) });
        try self.spans.append(self.allocator, span);
        try self.content_spans.append(self.allocator, null);
        return id;
    }

    /// Set node `id`'s interior span. Named to read like `Builder`'s
    /// `setContentSpan`, since it now does the same thing to a parallel array
    /// rather than mutating a field on the node.
    fn setContentSpan(self: *TreeBuilder, id: Node.Id, span: ?Span) void {
        self.content_spans.items[id] = span;
    }

    /// Mirrors `ast/builder.zig`'s `dupeKind` (copy every string payload a
    /// `Kind` carries). Kept separate rather than sharing code with that
    /// file since this parser doesn't otherwise touch `Builder` at all.
    fn dupeKind(self: *TreeBuilder, kind: Node.Kind) Allocator.Error!Node.Kind {
        return switch (kind) {
            .code_block => |v| .{ .code_block = .{ .lang = if (v.lang) |l| try self.own(l) else null, .text = try self.own(v.text) } },
            .raw_block => |v| .{ .raw_block = .{ .format = try self.own(v.format), .text = try self.own(v.text) } },
            .metadata => |v| .{ .metadata = .{ .lang = try self.own(v.lang), .text = try self.own(v.text) } },
            .footnote => |v| .{ .footnote = .{ .label = try self.own(v.label) } },
            .reference => |v| .{ .reference = .{ .label = try self.own(v.label), .destination = try self.own(v.destination) } },
            .str => |v| .{ .str = try self.own(v) },
            .text_leaf => |v| .{ .text_leaf = .{ .kind = v.kind, .text = try self.own(v.text) } },
            .raw_inline => |v| .{ .raw_inline = .{ .format = try self.own(v.format), .text = try self.own(v.text) } },
            // `smart_punctuation`'s payload is now a bare `SmartPunctuationKind`
            // (no string to copy), so it falls through to `else => kind` below.
            .link => |v| .{ .link = .{
                .destination = if (v.destination) |d| try self.own(d) else null,
                .reference = if (v.reference) |r| try self.own(r) else null,
            } },
            .image => |v| .{ .image = .{
                .destination = if (v.destination) |d| try self.own(d) else null,
                .reference = if (v.reference) |r| try self.own(r) else null,
            } },
            else => kind,
        };
    }

    fn commitAttrs(self: *TreeBuilder, id: Node.Id, pending: *const PendingAttrs) Allocator.Error!void {
        if (pending.isEmpty()) return;
        const entries = try self.allocator.alloc(AST.KeyVal, pending.entries.items.len);
        for (pending.entries.items, entries) |src, *dst| {
            dst.* = .{ .key = try self.own(src.key), .value = try self.own(src.value) };
        }
        const idx: u32 = @intCast(self.attrs_table.items.len);
        try self.attrs_table.append(self.allocator, .{ .entries = entries });
        self.nodes.items[id].attrs = idx;
    }

    // ── container stack ──────────────────────────────────────────────────

    fn pushContainer(self: *TreeBuilder, start: usize) Allocator.Error!void {
        var c: TreeContainer = .{ .start = start };
        if (!self.pending_block_attrs.isEmpty()) {
            try c.attrs.mergeFrom(self.allocator, &self.pending_block_attrs);
            self.pending_block_attrs.clear(self.allocator);
        }
        try self.containers.append(self.allocator, c);
    }

    fn popContainer(self: *TreeBuilder) TreeContainer {
        return self.containers.pop().?;
    }

    fn topContainer(self: *TreeBuilder) *TreeContainer {
        return &self.containers.items[self.containers.items.len - 1];
    }

    /// The last child added to the top container, or `null` if it has none
    /// yet (djot.js's `getTip`, which returns the container itself in that
    /// case -- callers here just branch on `null` instead).
    fn getTip(self: *TreeBuilder) ?Node.Id {
        return self.topContainer().last_child;
    }

    fn addChildToTip(self: *TreeBuilder, id: Node.Id) void {
        if (self.containers.items.len == 0) return;
        self.topContainer().addChild(self.nodes.items, id);
    }

    /// For a container node whose children are already linked via
    /// `first_child`/`next_sibling`: its `content_span` is the byte range
    /// from the first child's span start to the last child's span end --
    /// the same "interior = extent of the child content" convention the
    /// XML parser uses for tag interiors (see `ast/ast.zig`'s
    /// `content_span` doc comment and `xml/parser.zig`'s `parseElement`).
    /// `null` for an empty container (`first_child == null`): djot has no
    /// equivalent of XML's explicit open/close tag positions to derive a
    /// zero-width interior from, and reconstructing one would need
    /// delimiter-length bookkeeping this parser doesn't otherwise track --
    /// `null` (unknown/not meaningful) is the honest answer per the
    /// field's contract, not a guessed offset.
    fn contentSpanFromChildren(self: *const TreeBuilder, first_child: ?Node.Id) ?Span {
        const first = first_child orelse return null;
        var last = first;
        while (self.nodes.items[last].next_sibling) |next| last = next;
        return Span.init(self.spans.items[first].start, self.spans.items[last].end);
    }

    /// The `content_span` of a framed *leaf* (inline `verbatim`/math, `<...>`
    /// url/email autolink): the raw source interior `[content_start, close)`,
    /// where `content_start` was recorded just past the opening delimiter and
    /// `close` is the closing event's start. `null` for an empty interior
    /// (`content_start == close`) — an empty frame carries no `content_span`,
    /// matching the `code_block`/container conventions. Note this is the RAW
    /// source between the delimiters and need NOT byte-equal the node's
    /// (space-trimmed) text payload — see `ast.zig`'s `content_span` doc.
    fn leafInteriorSpan(content_start: ?usize, close: usize) ?Span {
        const cs = content_start orelse return null;
        if (cs >= close) return null;
        return Span.init(cs, close);
    }

    fn textOf(self: *const TreeBuilder, ev: Event) []const u8 {
        return self.source[ev.start .. ev.end + 1];
    }

    // ── the big dispatch ─────────────────────────────────────────────────

    pub fn build(self: *TreeBuilder, events: []const Event) Allocator.Error!Document {
        try self.pushContainer(0);
        self.topContainer().data.heading_level = 0;

        for (events) |ev| {
            try self.handleEvent(ev);
        }

        // Close any still-open sections.
        var pnode = self.topContainer();
        while (pnode.data.heading_level != null and pnode.data.heading_level.? > 0) {
            const closed = self.popContainer();
            var c = closed;
            const sec_id = try self.addNode(.section, Span.init(c.start, self.source.len));
            self.nodes.items[sec_id].first_child = c.first_child;
            self.setContentSpan(sec_id, self.contentSpanFromChildren(c.first_child));
            try self.commitAttrs(sec_id, &c.attrs);
            self.addChildToTip(sec_id);
            c.deinit(self.allocator);
            pnode = self.topContainer();
        }

        var root = self.popContainer();
        defer root.deinit(self.allocator);
        const doc_id = try self.addNode(.doc, Span.init(0, self.source.len));
        self.nodes.items[doc_id].first_child = root.first_child;
        self.setContentSpan(doc_id, self.contentSpanFromChildren(root.first_child));
        try self.commitAttrs(doc_id, &root.attrs);

        self.deinitScratch();

        return .{
            .ast = .{
                .allocator = self.allocator,
                .owned_strings = try self.owned_strings.toOwnedSlice(self.allocator),
                .root = doc_id,
                .nodes = try self.nodes.toOwnedSlice(self.allocator),
                .attrs = try self.attrs_table.toOwnedSlice(self.allocator),
            },
            // Positions travel beside the tree, not inside it — see
            // `djot.zig`'s `Document` and `src/document.zig`.
            .source = self.source,
            .node_spans = try self.spans.toOwnedSlice(self.allocator),
            .node_content_spans = try self.content_spans.toOwnedSlice(self.allocator),
            .references = self.references,
            .auto_references = self.auto_references,
            .footnotes = self.footnotes,
        };
    }

    fn handleEvent(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        // Attributes must immediately precede a block; reset on blank lines.
        if (ev.annot == .blankline) {
            self.pending_block_attrs.clear(self.allocator);
        }

        // Tight/loose determination: if blank lines were seen and we're
        // about to process anything other than a blankline or a list
        // boundary, the enclosing list is loose. The "blankline" annotation
        // itself is handled separately below (in the main switch) since it
        // needs to unconditionally SET `blanklines`, whereas this pass only
        // ever reads it / clears it.
        if (self.list_depth > 0 and ev.annot != .blankline) {
            if (self.findListNode()) |ln| {
                // Mirrors djot.js's `/^[+-]list/` prefix test, which matches
                // all four of list_open/list_close/list_item_open/
                // list_item_close (a bare "list"/"list_item" boundary event
                // never itself makes the list loose).
                const is_list_boundary = switch (ev.annot) {
                    .list_open, .list_close, .list_item_open, .list_item_close => true,
                    else => false,
                };
                if (!is_list_boundary and ln.data.blanklines) ln.data.tight = false;
                // NOTE: this is a NARROWER exclusion than `is_list_boundary`
                // above -- djot.js uses two different tests here (an EXACT
                // match on `list_item_open`/`_close` for this reset, vs. a
                // PREFIX match covering bare `list_open`/`_close` too for the
                // `tight` gate above). A bare list boundary (opening/closing
                // the list itself, as opposed to one of its items) DOES
                // reset `blanklines` -- only crossing an item boundary
                // preserves it, so a blank line between two items can still
                // be seen by the next item's content.
                const is_list_item_boundary = switch (ev.annot) {
                    .list_item_open, .list_item_close => true,
                    else => false,
                };
                if (!is_list_item_boundary) ln.data.blanklines = false;
            }
        }

        switch (ev.annot) {
            .str => {
                const txt = self.textOf(ev);
                if (self.context == .normal) {
                    const id = try self.addNode(.{ .str = txt }, Span.init(ev.start, ev.end + 1));
                    self.addChildToTip(id);
                } else {
                    // Record the raw body extent so a `code_block`/`raw_block`
                    // can report it as `content_span`. Harmless for other
                    // opaque-text containers (verbatim/math/url/email), which
                    // derive their interior from delimiters instead and never
                    // read `body_*`.
                    const top = self.topContainer();
                    if (top.body_start == null) top.body_start = ev.start;
                    top.body_end = ev.end + 1;
                    try self.accumulated_text.appendSlice(self.allocator, txt);
                }
            },
            .soft_break => {
                if (self.context == .normal) {
                    const id = try self.addNode(.soft_break, Span.init(ev.start, ev.end + 1));
                    self.addChildToTip(id);
                } else {
                    try self.accumulated_text.append(self.allocator, '\n');
                }
            },
            .escape => {
                if (self.context == .verbatim) try self.accumulated_text.append(self.allocator, '\\');
            },
            .hard_break => {
                if (self.context == .normal) {
                    const id = try self.addNode(.hard_break, Span.init(ev.start, ev.end + 1));
                    self.addChildToTip(id);
                } else {
                    try self.accumulated_text.append(self.allocator, '\n');
                }
            },
            .non_breaking_space => {
                if (self.context == .verbatim) {
                    try self.accumulated_text.appendSlice(self.allocator, "\\ ");
                } else {
                    const id = try self.addNode(.non_breaking_space, Span.init(ev.start, ev.end + 1));
                    self.addChildToTip(id);
                }
            },
            .symb => {
                if (self.context == .normal) {
                    const alias = self.source[ev.start + 1 .. ev.end];
                    const id = try self.addNode(.{ .text_leaf = .{ .kind = .symb, .text = alias } }, Span.init(ev.start, ev.end + 1));
                    // Interior between the framing colons (`:name:` → `name`).
                    self.setContentSpan(id, leafInteriorSpan(ev.start + 1, ev.end));
                    self.addChildToTip(id);
                } else {
                    try self.accumulated_text.appendSlice(self.allocator, self.textOf(ev));
                }
            },
            .footnote_reference => {
                const raw = self.source[ev.start + 2 .. ev.end];
                const lab = try normalizeLabel(self.allocator, raw);
                const id = try self.addNode(.{ .text_leaf = .{ .kind = .footnote_reference, .text = lab } }, Span.init(ev.start, ev.end + 1));
                // Interior between the `[^` and `]` framing (raw label, which
                // need not equal the normalized `.footnote_reference` payload).
                self.setContentSpan(id, leafInteriorSpan(ev.start + 2, ev.end));
                self.allocator.free(lab);
                self.addChildToTip(id);
            },

            .reference_definition_open => try self.pushContainer(ev.start),
            .reference_definition_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const key = c.data.ref_key orelse "";
                if (key.len > 0) {
                    const lab = try normalizeLabel(self.allocator, key);
                    defer self.allocator.free(lab);
                    const dest = c.data.ref_value.items;
                    const id = try self.addNode(.{ .reference = .{ .label = lab, .destination = dest } }, Span.init(c.start, ev.end + 1));
                    try self.commitAttrs(id, &c.attrs);
                    const owned_lab = try self.own(lab);
                    if (!self.references.contains(owned_lab)) try self.references.put(self.allocator, owned_lab, id);
                }
            },
            .reference_key => self.topContainer().data.ref_key = self.source[ev.start + 1 .. ev.end],
            .reference_value => try self.topContainer().data.ref_value.appendSlice(self.allocator, self.textOf(ev)),

            inline .emph_open, .strong_open, .span_open, .mark_open, .superscript_open, .subscript_open, .delete_open, .insert_open, .double_quoted_open, .single_quoted_open => try self.pushContainer(ev.start),

            .emph_close => try self.closeSimpleInline(ev, .{ .inline_mark = .emph }),
            .strong_close => try self.closeSimpleInline(ev, .{ .inline_mark = .strong }),
            .span_close => try self.closeSimpleInline(ev, .{ .container = .{ .name = "", .form = .inline_text } }),
            .mark_close => try self.closeSimpleInline(ev, .{ .inline_mark = .mark }),
            .superscript_close => try self.closeSimpleInline(ev, .{ .inline_mark = .superscript }),
            .subscript_close => try self.closeSimpleInline(ev, .{ .inline_mark = .subscript }),
            .delete_close => try self.closeSimpleInline(ev, .{ .inline_mark = .delete }),
            .insert_close => try self.closeSimpleInline(ev, .{ .inline_mark = .insert }),
            .double_quoted_close => try self.closeSimpleInline(ev, .{ .inline_mark = .double_quoted }),
            .single_quoted_close => try self.closeSimpleInline(ev, .{ .inline_mark = .single_quoted }),

            .attributes_open => try self.pushContainer(ev.start),
            .attributes_close => try self.closeInlineAttributes(ev),
            .block_attributes_open => try self.pushContainer(ev.start),
            .block_attributes_close => try self.closeBlockAttributes(),

            .class => {
                const cl = self.textOf(ev);
                try self.topContainer().attrs.addClass(self.allocator, cl);
            },
            .id => {
                const idtext = self.textOf(ev);
                try self.topContainer().attrs.setKeyval(self.allocator, "id", idtext);
            },
            .key => {
                const k = self.textOf(ev);
                self.topContainer().attrs.pending_key = k;
                try self.topContainer().attrs.setKeyval(self.allocator, k, "");
            },
            .value => {
                const collapsed = try collapseAndUnescape(self.allocator, self.textOf(ev));
                defer self.allocator.free(collapsed);
                const top = self.topContainer();
                const key = top.attrs.pending_key orelse return;
                const existing = top.attrs.get(key) orelse return;
                const combined = try std.mem.concat(self.allocator, u8, &.{ existing, collapsed });
                try top.attrs.owned_bufs.append(self.allocator, combined);
                try top.attrs.setKeyval(self.allocator, key, combined);
            },

            .linktext_open => {
                try self.pushContainer(ev.start);
                self.topContainer().data.is_image = false;
            },
            .linktext_close => {},
            .imagetext_open => {
                try self.pushContainer(ev.start);
                self.topContainer().data.is_image = true;
            },
            .imagetext_close => {},
            .destination_open => self.context = .literal,
            .destination_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const dest = try stripNewlines(self.allocator, self.accumulated_text.items);
                defer self.allocator.free(dest);
                const kind: Node.Kind = if (c.data.is_image) .{ .image = .{ .destination = dest, .reference = null } } else .{ .link = .{ .destination = dest, .reference = null } };
                // An image's `!` sits one byte before its `[` (guaranteed by
                // the `is_image` test in inline.zig), and it's part of the
                // node's source — include it so `edit --delete` doesn't orphan
                // a stray `!`. `c.start >= 1` whenever `is_image`.
                const span_start = if (c.data.is_image) c.start - 1 else c.start;
                const id = try self.addNode(kind, Span.init(span_start, ev.end + 1));
                self.nodes.items[id].first_child = c.first_child;
                self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
                self.context = .normal;
                self.accumulated_text.clearRetainingCapacity();
            },
            .reference_open => self.context = .literal,
            .reference_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                var ref = self.accumulated_text.items;
                var owned_ref: ?[]u8 = null;
                if (ref.len == 0) {
                    owned_ref = try getStringContent(self.allocator, self, c.first_child);
                    ref = owned_ref.?;
                }
                defer if (owned_ref) |o| self.allocator.free(o);
                const lab = try normalizeLabel(self.allocator, ref);
                defer self.allocator.free(lab);
                const kind: Node.Kind = if (c.data.is_image) .{ .image = .{ .destination = null, .reference = lab } } else .{ .link = .{ .destination = null, .reference = lab } };
                // Include the leading `!` in an image's span (see destination_close).
                const span_start = if (c.data.is_image) c.start - 1 else c.start;
                const id = try self.addNode(kind, Span.init(span_start, ev.end + 1));
                self.nodes.items[id].first_child = c.first_child;
                self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
                self.context = .normal;
                self.accumulated_text.clearRetainingCapacity();
            },

            .verbatim_open => {
                self.context = .verbatim;
                try self.pushContainer(ev.start);
                self.topContainer().content_start = ev.end + 1;
            },
            .verbatim_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const text = try trimVerbatim(self.allocator, self.accumulated_text.items);
                defer self.allocator.free(text);
                const id = try self.addNode(.{ .text_leaf = .{ .kind = .verbatim, .text = text } }, Span.init(c.start, ev.end + 1));
                // Raw interior between the backticks (a later `raw_format`
                // event may retype this node to `raw_inline`, keeping the same
                // interior). `source[content_span]` is the raw, untrimmed text.
                self.setContentSpan(id, leafInteriorSpan(c.content_start, ev.start));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
                self.context = .normal;
                self.accumulated_text.clearRetainingCapacity();
            },
            .raw_format => try self.handleRawFormat(ev),

            .display_math_open, .inline_math_open => {
                self.context = .verbatim;
                try self.pushContainer(ev.start);
                self.topContainer().content_start = ev.end + 1;
            },
            .display_math_close => try self.closeMath(ev, true),
            .inline_math_close => try self.closeMath(ev, false),

            .url_open => {
                self.context = .literal;
                try self.pushContainer(ev.start);
                self.topContainer().content_start = ev.end + 1;
            },
            .url_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const text = try stripNewlines(self.allocator, self.accumulated_text.items);
                defer self.allocator.free(text);
                const id = try self.addNode(.{ .text_leaf = .{ .kind = .url, .text = text } }, Span.init(c.start, ev.end + 1));
                // Interior between the `<` and `>` autolink delimiters.
                self.setContentSpan(id, leafInteriorSpan(c.content_start, ev.start));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
                self.context = .normal;
                self.accumulated_text.clearRetainingCapacity();
            },
            .email_open => {
                self.context = .literal;
                try self.pushContainer(ev.start);
                self.topContainer().content_start = ev.end + 1;
            },
            .email_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const text = try stripNewlines(self.allocator, self.accumulated_text.items);
                defer self.allocator.free(text);
                const id = try self.addNode(.{ .text_leaf = .{ .kind = .email, .text = text } }, Span.init(c.start, ev.end + 1));
                // Interior between the `<` and `>` autolink delimiters.
                self.setContentSpan(id, leafInteriorSpan(c.content_start, ev.start));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
                self.context = .normal;
                self.accumulated_text.clearRetainingCapacity();
            },

            .para_open => try self.pushContainer(ev.start),
            .para_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const id = try self.addNode(.para, Span.init(c.start, ev.end + 1));
                self.nodes.items[id].first_child = c.first_child;
                self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
            },

            .heading_open => {
                try self.pushContainer(ev.start);
                self.topContainer().data.level = @intCast(ev.end - ev.start + 1);
            },
            .heading_close => try self.closeHeading(ev),

            .list_open => {
                try self.pushContainer(ev.start);
                self.topContainer().data.styles = ev.list_styles;
                self.topContainer().data.blanklines = false;
                self.topContainer().data.tight = true;
                self.list_depth += 1;
            },
            .list_close => try self.closeList(ev),

            .list_item_open => {
                const top = self.topContainer();
                const narrowed = ev.list_styles;
                if (narrowed.len < top.data.styles.len) top.data.styles = narrowed;
                if (top.data.first_marker == null) top.data.first_marker = self.textOf(ev);
                try self.pushContainer(ev.start);
                if (narrowed.len == 1 and narrowed.items[0].eql(.colon)) {
                    self.topContainer().data.is_definition_item = true;
                }
            },
            .list_item_close => try self.closeListItem(ev),

            .checkbox_checked => self.topContainer().data.checkbox = true,
            .checkbox_unchecked => self.topContainer().data.checkbox = false,

            .block_quote_open => try self.pushContainer(ev.start),
            .block_quote_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const id = try self.addNode(.block_quote, Span.init(c.start, ev.end + 1));
                self.nodes.items[id].first_child = c.first_child;
                self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
            },

            .table_open => try self.pushContainer(ev.start),
            .table_close => try self.closeTable(ev),
            .row_open => try self.pushContainer(ev.start),
            .row_close => try self.closeRow(ev),
            .separator_default => try self.topContainer().data.aligns.append(self.allocator, .default),
            .separator_left => try self.topContainer().data.aligns.append(self.allocator, .left),
            .separator_right => try self.topContainer().data.aligns.append(self.allocator, .right),
            .separator_center => try self.topContainer().data.aligns.append(self.allocator, .center),
            .cell_open => try self.pushContainer(ev.start),
            .cell_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const id = try self.addNode(.{ .cell = .{ .head = false, .alignment = .default } }, Span.init(c.start, ev.end + 1));
                self.nodes.items[id].first_child = c.first_child;
                self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
            },

            .caption_open => try self.pushContainer(ev.start),
            .caption_close => try self.closeCaption(ev),

            .footnote_open => try self.pushContainer(ev.start),
            .footnote_close => try self.closeFootnote(ev),
            .note_label => self.topContainer().data.label = self.textOf(ev),

            .code_block_open => {
                try self.pushContainer(ev.start);
                self.context = .verbatim;
            },
            .code_block_close => try self.closeCodeBlock(ev),
            .code_language => self.topContainer().data.lang = self.textOf(ev),

            .div_open => try self.pushContainer(ev.start),
            .div_close => {
                var c = self.popContainer();
                defer c.deinit(self.allocator);
                const id = try self.addNode(.{ .container = .{ .name = "", .form = .block_fenced } }, Span.init(c.start, ev.end + 1));
                self.nodes.items[id].first_child = c.first_child;
                self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
                try self.commitAttrs(id, &c.attrs);
                self.addChildToTip(id);
            },

            .thematic_break => {
                const id = try self.addNode(.thematic_break, Span.init(ev.start, ev.end + 1));
                try self.commitAttrs(id, &self.pending_block_attrs);
                self.pending_block_attrs.clear(self.allocator);
                self.addChildToTip(id);
            },

            .left_single_quote => try self.addSmartPunct(ev, .left_single_quote),
            .right_single_quote => try self.addSmartPunct(ev, .right_single_quote),
            .left_double_quote => try self.addSmartPunct(ev, .left_double_quote),
            .right_double_quote => try self.addSmartPunct(ev, .right_double_quote),
            .ellipses => try self.addSmartPunct(ev, .ellipses),
            .en_dash => try self.addSmartPunct(ev, .en_dash),
            .em_dash => try self.addSmartPunct(ev, .em_dash),

            // Record that a blank line was seen, for the ENCLOSING list to
            // pick up (see `findListNode`/the tight/loose bookkeeping
            // above): the very next non-blankline, non-list-boundary event
            // downgrades that list to loose. This can't live in the generic
            // bookkeeping pass above since that pass explicitly skips
            // `.blankline` events (it only ever reads/clears the flag this
            // sets).
            .blankline => {
                if (self.findListNode()) |ln| ln.data.blanklines = true;
            },

            // No tree-building meaning; consumed only during scanning.
            .open_marker, .comment, .attr_space, .attr_id_marker, .attr_class_marker, .attr_equal_marker, .attr_quote_marker, .image_marker => {},
        }
    }

    fn isListDataInit(c: *const TreeContainer) bool {
        // djot.js checks `"tight" in top.data`; every container's `tight`
        // defaults to `true`, so instead check the one field only a `list`
        // container ever sets: `styles`.
        return !c.data.styles.isEmpty();
    }

    /// The nearest enclosing `list` container, checked at the current top
    /// of the stack or one level down (a `list` is always either the
    /// current container or the parent of the current one -- e.g. while a
    /// list_item is open but no block inside it has pushed its own
    /// container yet, `list_item` is on top and `list` is one below it).
    fn findListNode(self: *TreeBuilder) ?*TreeContainer {
        if (self.containers.items.len == 0) return null;
        const top = self.topContainer();
        if (isListDataInit(top)) return top;
        if (self.containers.items.len >= 2) {
            const under = &self.containers.items[self.containers.items.len - 2];
            if (isListDataInit(under)) return under;
        }
        return null;
    }

    /// Takes a whole `Node.Kind` rather than a tag: djot's `[…]{…}` span is no
    /// longer a kind of its own but a `container` named "span", so the closer
    /// has to carry a payload and a bare tag can no longer name it.
    fn closeSimpleInline(self: *TreeBuilder, ev: Event, kind: Node.Kind) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const id = try self.addNode(kind, Span.init(c.start, ev.end + 1));
        self.nodes.items[id].first_child = c.first_child;
        self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
        self.addChildToTip(id);
    }

    fn addSmartPunct(self: *TreeBuilder, ev: Event, kind: AST.SmartPunctuationKind) Allocator.Error!void {
        const id = try self.addNode(.{ .smart_punctuation = kind }, Span.init(ev.start, ev.end + 1));
        self.addChildToTip(id);
    }

    fn handleRawFormat(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        const raw = self.textOf(ev);
        const format = stripRawFormatDelims(raw);
        if (self.context == .verbatim) {
            self.topContainer().data.format = format;
        } else {
            const tip_id = self.getTip() orelse return;
            if (self.nodes.items[tip_id].kind == .text_leaf and self.nodes.items[tip_id].kind.text_leaf.kind == .verbatim) {
                const text = self.nodes.items[tip_id].kind.text_leaf.text;
                self.nodes.items[tip_id].kind = .{ .raw_inline = .{ .format = format, .text = text } };
            }
        }
    }

    fn stripRawFormatDelims(s: []const u8) []const u8 {
        var r = s;
        if (r.len > 0 and r[0] == '{') r = r[1..];
        if (r.len > 0 and r[0] == '=') r = r[1..];
        if (r.len > 0 and r[r.len - 1] == '}') r = r[0 .. r.len - 1];
        return r;
    }

    fn closeMath(self: *TreeBuilder, ev: Event, display: bool) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const text = try trimVerbatim(self.allocator, self.accumulated_text.items);
        defer self.allocator.free(text);
        const kind: Node.Kind = if (display) .{ .text_leaf = .{ .kind = .display_math, .text = text } } else .{ .text_leaf = .{ .kind = .inline_math, .text = text } };
        const id = try self.addNode(kind, Span.init(c.start, ev.end + 1));
        // Raw interior between the `$`/`$$` + backtick opener and the closing
        // backticks; `source[content_span]` is untrimmed, unlike `text`.
        self.setContentSpan(id, leafInteriorSpan(c.content_start, ev.start));
        try self.commitAttrs(id, &c.attrs);
        self.addChildToTip(id);
        self.context = .normal;
        self.accumulated_text.clearRetainingCapacity();
    }

    fn closeInlineAttributes(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        _ = ev;
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        if (c.attrs.isEmpty() or self.containers.items.len == 0) return;
        if (c.attrs.get("id")) |i| try self.identifiers.put(self.allocator, try self.own(i), {});

        var tip_id = self.getTip();
        if (tip_id == null) return; // no inline sibling to attach to

        var ends_with_space = false;
        if (self.nodes.items[tip_id.?].kind == .str) {
            const text = self.nodes.items[tip_id.?].kind.str;
            if (lastWord(text)) |word_start| {
                const whole = text;
                const word = whole[word_start..];
                self.nodes.items[tip_id.?].kind = .{ .str = whole[0..word_start] };
                const word_id = try self.addNode(.{ .str = word }, self.spans.items[tip_id.?]);
                self.addChildToTip(word_id);
                tip_id = word_id;
            } else {
                ends_with_space = true;
            }
        }
        if (ends_with_space) return;
        try self.mergeAttrsOntoNode(tip_id.?, &c.attrs);
    }

    fn mergeAttrsOntoNode(self: *TreeBuilder, id: Node.Id, src: *const PendingAttrs) Allocator.Error!void {
        var existing: PendingAttrs = .{};
        defer existing.deinit(self.allocator);
        if (self.nodes.items[id].attrs) |idx| {
            const a = self.attrs_table.items[idx];
            // Every committed entry came from a `PendingAttrs` (whose values
            // are non-optional — djot can't write a bare attribute), so
            // unwrapping here can't fail.
            for (a.entries) |kv| try existing.setKeyval(self.allocator, kv.key, kv.value.?);
        }
        try existing.mergeFrom(self.allocator, src);
        try self.commitAttrs(id, &existing);
    }

    /// The last whitespace-delimited word of `s`, as a start offset -- or
    /// `null` if `s` is entirely whitespace (or empty).
    fn lastWord(s: []const u8) ?usize {
        var i = s.len;
        while (i > 0 and !isSpaceByte(s[i - 1])) i -= 1;
        return if (i == s.len) null else i;
    }
    fn isSpaceByte(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }

    fn closeBlockAttributes(self: *TreeBuilder) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        if (c.attrs.isEmpty() or self.containers.items.len == 0) return;
        if (c.attrs.get("id")) |i| try self.identifiers.put(self.allocator, try self.own(i), {});
        try self.pending_block_attrs.mergeFrom(self.allocator, &c.attrs);
    }

    fn closeHeading(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        const level = c.data.level;

        const heading_str_owned = try getStringContent(self.allocator, self, c.first_child);
        defer self.allocator.free(heading_str_owned);
        const heading_str = std.mem.trim(u8, heading_str_owned, " \t\r\n");

        // djot.js keeps an explicit `#id` and an auto-generated one in
        // separate objects (`attributes` vs `autoAttributes`) specifically
        // so that when the id migrates onto the wrapping section (below),
        // an EXPLICIT id takes its whole attribute set along, while an
        // AUTO-generated one moves alone, leaving any other explicit
        // (id-less) attributes on the heading itself.
        const had_explicit_id = c.attrs.get("id") != null;
        var owned_auto_id: ?[]const u8 = null;
        if (!had_explicit_id) {
            const slug = try self.getUniqueIdentifier(heading_str);
            defer self.allocator.free(slug);
            owned_auto_id = try self.own(slug);
            try self.identifiers.put(self.allocator, owned_auto_id.?, {});
            // Attach it to the heading itself for now; if section-wrapping
            // applies (below), it migrates onto the section instead. If it
            // doesn't apply (e.g. a heading inside a block quote, which
            // never gets a section wrapper), it simply stays here.
            try c.attrs.setKeyval(self.allocator, "id", owned_auto_id.?);
        }
        const effective_id = if (had_explicit_id) c.attrs.get("id").? else owned_auto_id.?;

        const lab = try normalizeLabel(self.allocator, heading_str);
        defer self.allocator.free(lab);
        if (!self.references.contains(lab) and !self.auto_references.contains(lab)) {
            const dest = try std.fmt.allocPrint(self.allocator, "#{s}", .{effective_id});
            defer self.allocator.free(dest);
            const ref_id = try self.addNode(.{ .reference = .{ .label = lab, .destination = dest } }, Span.init(ev.start, ev.end + 1));
            const owned_lab = try self.own(lab);
            try self.auto_references.put(self.allocator, owned_lab, ref_id);
        }

        // Section nesting: close sections at >= this heading's level, then
        // open a fresh one.
        var pnode = self.topContainer();
        if (pnode.data.heading_level != null) {
            while (pnode.data.heading_level != null and pnode.data.heading_level.? >= level) {
                var closed = self.popContainer();
                const sec_id = try self.addNode(.section, Span.init(closed.start, ev.end + 1));
                self.nodes.items[sec_id].first_child = closed.first_child;
                self.setContentSpan(sec_id, self.contentSpanFromChildren(closed.first_child));
                try self.commitAttrs(sec_id, &closed.attrs);
                self.addChildToTip(sec_id);
                closed.deinit(self.allocator);
                pnode = self.topContainer();
            }
            try self.pushContainer(c.start);
            self.topContainer().data.heading_level = level;
            if (had_explicit_id) {
                self.topContainer().attrs = c.attrs;
                c.attrs = .{};
            } else {
                try self.topContainer().attrs.setKeyval(self.allocator, "id", owned_auto_id.?);
                c.attrs.remove("id");
            }
        }

        const id = try self.addNode(.{ .heading = .{ .level = level } }, Span.init(c.start, ev.end + 1));
        self.nodes.items[id].first_child = c.first_child;
        self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
        try self.commitAttrs(id, &c.attrs);
        self.addChildToTip(id);
        c.deinit(self.allocator);
    }

    fn closeList(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        self.list_depth -= 1;
        if (c.data.styles.isEmpty()) return; // matches upstream's thrown error path; degrade to dropping
        const style = c.data.styles.items[0];
        const marker = c.data.first_marker orelse "";
        const s = Span.init(c.start, ev.end + 1);

        const kind: Node.Kind = switch (style) {
            .colon => .definition_list,
            .dash_task, .plus_task, .star_task => .{ .task_list = .{ .tight = c.data.tight } },
            .dash => .{ .bullet_list = .{ .style = .dash, .tight = c.data.tight } },
            .plus => .{ .bullet_list = .{ .style = .plus, .tight = c.data.tight } },
            .star => .{ .bullet_list = .{ .style = .star, .tight = c.data.tight } },
            .ordered => |o| .{ .ordered_list = .{ .style = .{ .numbering = toAstNumbering(o.numbering), .delim = toAstDelim(o.delim) }, .tight = c.data.tight, .start = getListStart(marker, o.numbering) } },
        };
        const id = try self.addNode(kind, s);
        self.nodes.items[id].first_child = c.first_child;
        self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
        try self.commitAttrs(id, &c.attrs);
        self.addChildToTip(id);
    }

    fn closeListItem(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const s = Span.init(c.start, ev.end + 1);
        if (c.data.is_definition_item) {
            var term_children: ?Node.Id = null;
            var def_first = c.first_child;
            if (c.first_child) |fc| {
                if (self.nodes.items[fc].kind == .para) {
                    term_children = self.nodes.items[fc].first_child;
                    def_first = self.nodes.items[fc].next_sibling;
                }
            }
            const term_id = try self.addNode(.term, s);
            self.nodes.items[term_id].first_child = term_children;
            self.setContentSpan(term_id, self.contentSpanFromChildren(term_children));
            const def_id = try self.addNode(.definition, s);
            self.nodes.items[def_id].first_child = def_first;
            self.setContentSpan(def_id, self.contentSpanFromChildren(def_first));
            self.nodes.items[term_id].next_sibling = def_id;
            const item_id = try self.addNode(.definition_list_item, s);
            self.nodes.items[item_id].first_child = term_id;
            self.setContentSpan(item_id, self.contentSpanFromChildren(term_id));
            try self.commitAttrs(item_id, &c.attrs);
            self.addChildToTip(item_id);
        } else if (c.data.checkbox) |checked| {
            const id = try self.addNode(.{ .task_list_item = .{ .checked = checked } }, s);
            self.nodes.items[id].first_child = c.first_child;
            self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
            try self.commitAttrs(id, &c.attrs);
            self.addChildToTip(id);
        } else {
            const id = try self.addNode(.list_item, s);
            self.nodes.items[id].first_child = c.first_child;
            self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
            try self.commitAttrs(id, &c.attrs);
            self.addChildToTip(id);
        }
    }

    fn closeTable(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const s = Span.init(c.start, ev.end + 1);
        const caption_id = try self.addNode(.caption, s);
        var first_row = c.first_child;
        if (c.first_child) |fc| {
            if (self.nodes.items[fc].kind == .caption) {
                self.nodes.items[caption_id] = self.nodes.items[fc];
                first_row = self.nodes.items[fc].next_sibling;
            }
        }
        self.nodes.items[caption_id].next_sibling = first_row;
        const id = try self.addNode(.table, s);
        self.nodes.items[id].first_child = caption_id;
        self.setContentSpan(id, self.contentSpanFromChildren(caption_id));
        try self.commitAttrs(id, &c.attrs);
        self.addChildToTip(id);
    }

    fn closeRow(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        if (c.first_child == null) {
            // A separator line: propagate aligns to the table and mark the
            // previous row (and its cells) as a header row.
            if (self.containers.items.len > 0) {
                self.topContainer().data.aligns.clearRetainingCapacity();
                try self.topContainer().data.aligns.appendSlice(self.allocator, c.data.aligns.items);
            }
            if (self.getTip()) |prev_row| {
                if (self.nodes.items[prev_row].kind == .row) {
                    self.nodes.items[prev_row].kind = .{ .row = .{ .head = true } };
                    var child = self.nodes.items[prev_row].first_child;
                    var i: usize = 0;
                    while (child) |cid| : (i += 1) {
                        const al = if (i < c.data.aligns.items.len) c.data.aligns.items[i] else .default;
                        self.nodes.items[cid].kind = .{ .cell = .{ .head = true, .alignment = al } };
                        child = self.nodes.items[cid].next_sibling;
                    }
                }
            }
            return;
        }
        const aligns = if (self.containers.items.len > 0) self.topContainer().data.aligns.items else &[_]AST.Alignment{};
        var child = c.first_child;
        var i: usize = 0;
        while (child) |cid| : (i += 1) {
            const al = if (i < aligns.len) aligns[i] else .default;
            self.nodes.items[cid].kind = .{ .cell = .{ .head = false, .alignment = al } };
            child = self.nodes.items[cid].next_sibling;
        }
        const id = try self.addNode(.{ .row = .{ .head = false } }, Span.init(c.start, ev.end + 1));
        self.nodes.items[id].first_child = c.first_child;
        self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
        try self.commitAttrs(id, &c.attrs);
        self.addChildToTip(id);
    }

    fn closeCaption(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const tip_id = self.getTip() orelse return;
        if (self.nodes.items[tip_id].kind != .table) return;
        const capt_id = try self.addNode(.caption, Span.init(c.start, ev.end + 1));
        self.nodes.items[capt_id].first_child = c.first_child;
        self.setContentSpan(capt_id, self.contentSpanFromChildren(c.first_child));
        try self.commitAttrs(capt_id, &c.attrs);
        if (self.nodes.items[tip_id].first_child) |old_capt| {
            if (self.nodes.items[old_capt].kind == .caption) {
                self.nodes.items[capt_id].next_sibling = self.nodes.items[old_capt].next_sibling;
                self.nodes.items[tip_id].first_child = capt_id;
                // The table's own content_span was derived from its OLD
                // first child (the placeholder/earlier caption); re-derive
                // now that the caption swap changed where its interior
                // starts.
                self.setContentSpan(tip_id, self.contentSpanFromChildren(capt_id));
            }
        }
    }

    fn closeFootnote(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const label = c.data.label orelse return;
        const lab = try normalizeLabel(self.allocator, label);
        defer self.allocator.free(lab);
        const id = try self.addNode(.{ .footnote = .{ .label = lab } }, Span.init(c.start, ev.end + 1));
        self.nodes.items[id].first_child = c.first_child;
        self.setContentSpan(id, self.contentSpanFromChildren(c.first_child));
        try self.commitAttrs(id, &c.attrs);
        const owned_lab = try self.own(lab);
        if (!self.footnotes.contains(owned_lab)) try self.footnotes.put(self.allocator, owned_lab, id);
    }

    fn closeCodeBlock(self: *TreeBuilder, ev: Event) Allocator.Error!void {
        var c = self.popContainer();
        defer c.deinit(self.allocator);
        const s = Span.init(c.start, ev.end + 1);
        const id = if (c.data.format) |fmt|
            try self.addNode(.{ .raw_block = .{ .format = fmt, .text = self.accumulated_text.items } }, s)
        else
            try self.addNode(.{ .code_block = .{ .lang = c.data.lang, .text = self.accumulated_text.items } }, s);
        // Body interior with both fence lines excluded (see `body_*` on
        // `TreeContainer`). `null` for an empty fenced block (no body line
        // seen). `source[content_span]` is the raw body, whereas `.text` is
        // dedented/newline-normalized — they need not byte-match.
        if (c.body_start) |bs| self.setContentSpan(id, Span.init(bs, c.body_end));
        try self.commitAttrs(id, &c.attrs);
        self.addChildToTip(id);
        self.context = .normal;
        self.accumulated_text.clearRetainingCapacity();
    }

    const getUniqueIdentifier = TreeBuilderGetUniqueIdentifier;
};

fn collapseAndUnescape(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var in_ws = false;
    while (i < s.len) {
        const c = s[i];
        if (c == ' ' or c == '\r' or c == '\n') {
            if (!in_ws) try out.append(allocator, ' ');
            in_ws = true;
            i += 1;
        } else if (c == '\\' and i + 1 < s.len and isEscapablePunct(s[i + 1])) {
            try out.append(allocator, s[i + 1]);
            in_ws = false;
            i += 2;
        } else {
            try out.append(allocator, c);
            in_ws = false;
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isEscapablePunct(c: u8) bool {
    return switch (c) {
        '.', ',', '\\', '/', '#', '!', '$', '%', '^', '&', '*', ';', ':', '{', '}', '=', '-', '_', '`', '~', '+', '[', ']', '(', ')', '\'', '"', '?', '|' => true,
        else => false,
    };
}

fn stripNewlines(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c != '\r' and c != '\n') try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// The plain-text content of a not-yet-finalized child chain (used for
/// heading auto-ids and reference-link labels-from-content). Excludes
/// footnote references, matching djot.js's `getStringContent`.
fn getStringContent(allocator: Allocator, tb: *TreeBuilder, first: ?Node.Id) Allocator.Error![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try addStringContent(allocator, tb, first, &buf);
    return buf.toOwnedSlice(allocator);
}

fn addStringContent(allocator: Allocator, tb: *TreeBuilder, first: ?Node.Id, buf: *std.ArrayList(u8)) Allocator.Error!void {
    var cur = first;
    while (cur) |id| : (cur = tb.nodes.items[id].next_sibling) {
        const node = &tb.nodes.items[id];
        switch (node.kind) {
            .text_leaf => |l| if (l.kind != .footnote_reference) try buf.appendSlice(allocator, l.text),
            .str => |t| try buf.appendSlice(allocator, t),
            .raw_inline => |v| try buf.appendSlice(allocator, v.text),
            .code_block => |v| try buf.appendSlice(allocator, v.text),
            .raw_block => |v| try buf.appendSlice(allocator, v.text),
            .smart_punctuation => |v| try buf.appendSlice(allocator, v.ascii()),
            .soft_break, .hard_break => try buf.append(allocator, '\n'),
            else => try addStringContent(allocator, tb, node.first_child, buf),
        }
    }
}

// ── heading auto-id slugification ───────────────────────────────────────

fn TreeBuilderGetUniqueIdentifier(self: *TreeBuilder, s: []const u8) Allocator.Error![]u8 {
    var base = std.ArrayList(u8).empty;
    defer base.deinit(self.allocator);
    var last_was_sep = false;
    for (s) |c| {
        if (isIdentifierExcluded(c) or isSpaceByteFree(c)) {
            if (!last_was_sep and base.items.len > 0) {
                try base.append(self.allocator, '-');
                last_was_sep = true;
            }
        } else {
            try base.append(self.allocator, c);
            last_was_sep = false;
        }
    }
    while (base.items.len > 0 and base.items[base.items.len - 1] == '-') _ = base.pop();
    var start: usize = 0;
    while (start < base.items.len and base.items[start] == '-') start += 1;
    const trimmed = try self.allocator.dupe(u8, base.items[start..]);
    defer self.allocator.free(trimmed);

    if (trimmed.len > 0 and !self.identifiers.contains(trimmed)) {
        return self.allocator.dupe(u8, trimmed);
    }
    var i: usize = 0;
    while (true) {
        i += 1;
        const base_text = if (trimmed.len > 0) trimmed else "s";
        const candidate = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base_text, i });
        if (!self.identifiers.contains(candidate)) return candidate;
        self.allocator.free(candidate);
    }
}

fn isSpaceByteFree(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isIdentifierExcluded(c: u8) bool {
    return switch (c) {
        ']', '[', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '{', '}', '`', ',', '.', '<', '>', '\\', '|', '=', '+', '/', '?' => true,
        else => false,
    };
}

// ── content_span tests ──────────────────────────────────────────────────
// `TreeBuilder.contentSpanFromChildren` is the one place `content_span`
// gets populated; these exercise it end-to-end (source -> events -> tree)
// rather than unit-testing the helper in isolation, since what matters is
// that each container-close site wires it up correctly. Mirrors
// `djot.zig`'s own `pub fn parse`, just without going through that file
// (which imports this one) to avoid a needless round trip.

const testing = std.testing;
const block = @import("block.zig");

fn parseDoc(allocator: Allocator, source: []const u8) Allocator.Error!Document {
    var block_parser = try block.Parser.init(allocator, source);
    defer block_parser.deinit();
    const events = try block_parser.scan();
    defer allocator.free(events);

    var tree_builder = TreeBuilder.init(allocator, block_parser.subject);
    return tree_builder.build(events);
}

test "content_span: div's interior covers its child paragraph" {
    const src = ":::\nabc\n:::\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const div_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("", ast.nodes[div_id].kind.container.name);
    const cs = doc.contentSpan(div_id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("abc", std.mem.trim(u8, src[cs.start..cs.end], " \t\r\n"));

    // The interior is exactly the extent of the div's one child (the
    // paragraph), matching the XML parser's tag-interior convention.
    const para_id = ast.nodes[div_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(cs.eql(doc.span(para_id)));
}

test "content_span: inline emphasis covers its text" {
    const src = "_abc_\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    const emph_id = ast.nodes[para_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[emph_id].kind == .inline_mark and ast.nodes[emph_id].kind.inline_mark == .emph);
    const cs = doc.contentSpan(emph_id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("abc", src[cs.start..cs.end]);
}

test "content_span: a leaf str node stays null" {
    const src = "hello\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    const str_id = ast.nodes[para_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[str_id].kind == .str);
    try testing.expectEqual(@as(?Span, null), doc.contentSpan(str_id));
}

test "span: an inline image includes its leading `!`" {
    const src = "![alt](img.png)\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    const img_id = ast.nodes[para_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[img_id].kind == .image);
    const sp = doc.span(img_id);
    // The span must start at the `!` (offset 0), not the `[` — otherwise an
    // `edit --delete` of the image orphans a stray `!`.
    try testing.expectEqualStrings("![alt](img.png)", src[sp.start..sp.end]);
}

test "span: a reference image includes its leading `!`" {
    const src = "![alt][id]\n\n[id]: img.png\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const para_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    const img_id = ast.nodes[para_id].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[img_id].kind == .image);
    const sp = doc.span(img_id);
    try testing.expectEqualStrings("![alt][id]", src[sp.start..sp.end]);
}

test "content_span: an empty div (no children) stays null" {
    const src = ":::\n:::\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const div_id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("", ast.nodes[div_id].kind.container.name);
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[div_id].first_child);
    try testing.expectEqual(@as(?Span, null), doc.contentSpan(div_id));
}

// djot.js records source positions as line:col:byte triples; Twig records the
// byte range directly. This is the native equivalent of the corpus's
// `sourcepos.test` AST-dump case (options `ap`): every node gets a
// byte-accurate span. See conformance.zig for why that case is skipped there.
test "span: a bullet list and its items carry byte-accurate spans (sourcepos parity)" {
    const src = " - a\n - b\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const list = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[list].kind == .bullet_list);
    try testing.expectEqual(@as(usize, 1), doc.span(list).start);
    try testing.expectEqual(@as(usize, 10), doc.span(list).end);

    const item1 = ast.nodes[list].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[item1].kind == .list_item);
    try testing.expectEqual(@as(usize, 1), doc.span(item1).start);
    try testing.expectEqual(@as(usize, 6), doc.span(item1).end);

    const item2 = ast.nodes[item1].next_sibling orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[item2].kind == .list_item);
    try testing.expectEqual(@as(usize, 6), doc.span(item2).start);
    try testing.expectEqual(@as(usize, 10), doc.span(item2).end);

    // The leaf `str` spans exactly its single character.
    const para1 = ast.nodes[item1].first_child orelse return error.TestExpectedNonNull;
    const str1 = ast.nodes[para1].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[str1].kind == .str);
    try testing.expectEqualStrings("a", src[doc.span(str1).start..doc.span(str1).end]);
}

// ── content_span on framed *leaves* ─────────────────────────────────────
// Beyond containers, the opaque-text leaves that carry syntactic framing
// (delimiters/fences/markers) report their raw source *interior* as
// `content_span`, mirroring the Markdown parser. Each test asserts (a) the
// node kind, (b) that `span` covers the framing, (c) that `content_span` is
// the exact interior, and — where the payload is normalized/trimmed and so
// differs from the raw interior — asserts BOTH to document the distinction.

/// Reach the first inline leaf: root → first paragraph → its first child.
fn firstInlineLeaf(ast: AST) ?Node.Id {
    const para = ast.nodes[ast.root].first_child orelse return null;
    return ast.nodes[para].first_child;
}

test "content_span: inline verbatim is the interior between the backticks" {
    const src = "`code`\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .verbatim);
    const sp = doc.span(id);
    try testing.expectEqualStrings("`code`", src[sp.start..sp.end]);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("code", src[cs.start..cs.end]);
}

test "content_span: verbatim raw interior differs from the space-trimmed text" {
    // `` `x` `` -> the payload trims one adjacent space at each end, but the
    // raw interior (content_span) keeps those spaces.
    const src = "`` `x` ``\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .verbatim);
    try testing.expectEqualStrings("`x`", ast.nodes[id].kind.text_leaf.text);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    // Raw interior INCLUDES the framing spaces: content_span != text.
    try testing.expectEqualStrings(" `x` ", src[cs.start..cs.end]);
}

test "content_span: inline and display math interiors exclude their delimiters" {
    {
        const src = "$`x+y`\n";
        var doc = try parseDoc(testing.allocator, src);
        defer doc.deinit();
        const ast = doc.ast;
        const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
        try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .inline_math);
        const sp = doc.span(id);
        try testing.expectEqualStrings("$`x+y`", src[sp.start..sp.end]);
        const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
        try testing.expectEqualStrings("x+y", src[cs.start..cs.end]);
    }
    {
        const src = "$$`x+y`\n";
        var doc = try parseDoc(testing.allocator, src);
        defer doc.deinit();
        const ast = doc.ast;
        const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
        try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .display_math);
        const sp = doc.span(id);
        try testing.expectEqualStrings("$$`x+y`", src[sp.start..sp.end]);
        const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
        try testing.expectEqualStrings("x+y", src[cs.start..cs.end]);
    }
}

test "content_span: raw inline keeps the backtick interior (not the {=fmt})" {
    const src = "`raw`{=html}\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .raw_inline);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("raw", src[cs.start..cs.end]);
}

test "content_span: url autolink interior excludes the angle brackets" {
    const src = "<https://x.dev>\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .url);
    const sp = doc.span(id);
    try testing.expectEqualStrings("<https://x.dev>", src[sp.start..sp.end]);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("https://x.dev", src[cs.start..cs.end]);
}

test "content_span: email autolink interior excludes the angle brackets" {
    const src = "<a@b.dev>\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .email);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("a@b.dev", src[cs.start..cs.end]);
}

test "content_span: symbol interior excludes the framing colons" {
    const src = ":smile:\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = firstInlineLeaf(ast) orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .symb);
    const sp = doc.span(id);
    try testing.expectEqualStrings(":smile:", src[sp.start..sp.end]);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("smile", src[cs.start..cs.end]);
}

test "content_span: footnote reference interior excludes the [^ and ]" {
    const src = "x[^note]\n\n[^note]: body\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const para = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    // Skip the leading `x` str to reach the footnote_reference.
    const str_x = ast.nodes[para].first_child orelse return error.TestExpectedNonNull;
    const id = ast.nodes[str_x].next_sibling orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .text_leaf and ast.nodes[id].kind.text_leaf.kind == .footnote_reference);
    const sp = doc.span(id);
    try testing.expectEqualStrings("[^note]", src[sp.start..sp.end]);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("note", src[cs.start..cs.end]);
}

test "content_span: fenced code block body excludes both fence lines" {
    const src = "```lua\nx=1\ny=2\n```\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .code_block);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    // Raw source body — the fence lines (```lua and ```) are excluded.
    try testing.expectEqualStrings("x=1\ny=2\n", src[cs.start..cs.end]);
    // The payload matches here, but the guarantee is only that the span
    // addresses the raw body — see the space-trim/verbatim test for a case
    // where source[content_span] deliberately differs from the payload.
    try testing.expectEqualStrings("x=1\ny=2\n", ast.nodes[id].kind.code_block.text);
}

test "content_span: raw block body excludes both fence lines" {
    const src = "```=html\n<b>hi</b>\n```\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .raw_block);
    const cs = doc.contentSpan(id) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("<b>hi</b>\n", src[cs.start..cs.end]);
}

test "content_span: an empty fenced code block (no body) stays null" {
    const src = "```\n```\n";
    var doc = try parseDoc(testing.allocator, src);
    defer doc.deinit();
    const ast = doc.ast;

    const id = ast.nodes[ast.root].first_child orelse return error.TestExpectedNonNull;
    try testing.expect(ast.nodes[id].kind == .code_block);
    try testing.expectEqual(@as(?Span, null), doc.contentSpan(id));
}
