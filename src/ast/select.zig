//! Selectors — a friendly, content-based way to address AST nodes, so callers
//! (and `twig query`/`twig edit`) don't have to speak in raw child indices. A
//! CSS-lite language: a *kind name* plus optional predicates. This is a
//! LIBRARY module — `parse` -> `Selector`, `resolveAll`/`resolveOne` ->
//! nodes — usable programmatically with no CLI in sight (that's the point:
//! Twig is a queryable/editable document AST, and the CLI is a thin skin over
//! this).
//!
//! ── Grammar ──────────────────────────────────────────────────────────────
//!   selector  := step (combinator step)*
//!   combinator := ">"                          direct child
//!              |  (whitespace)                 descendant (any depth)
//!   step      := kind predicate*
//!   kind      := ident        e.g. heading, para, link, item, list, code,
//!                             emph, strong, table, cell, div, section, text;
//!                             friendly aliases (h/p/a/img/em/bold/quote…) and
//!                             any raw `Node.Kind` tag name also work; `*` = any
//!   predicate := "(" str ")"                  text contains (shorthand)
//!              | ":contains(" str ")"          text contains
//!              | ":nth(" N ")"  |  "[" N "]"   the N-th match (1-based)
//!              | "[" key (op value)? "]"       attribute/payload test
//!   op        := "=" "^=" "$=" "*=" "~="       eq / prefix / suffix /
//!                                              substring / whitespace-word
//! Examples: `heading`, `heading[level=2]`, `heading("Status")`, `item[2]`,
//! `link[dest^="http"]`, `code[lang=zig]`, `list[ordered]`, `list > item`,
//! `list:nth(2) > item("dishes")`, `blockquote para`,
//! `directive[name=vis]`, `directive[name=vis][class~=public]`.
//!
//! Each step's `:nth`/`[k]` applies *within that step's scope* — it picks the
//! k-th candidate matched under the current scope, and that pick becomes the
//! scope for the next step. So `list:nth(2) > item` first narrows to the 2nd
//! list in the document, then matches only items that are direct children of
//! *that* list.
//!
//! The `section("Title")` form is deliberately NOT here yet — it needs
//! separate CLI span-wiring and layers on top of this same engine without
//! changing the `parse`/`resolve*` surface. See the module's tests for
//! exactly what's covered today.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Document = @import("../document.zig");
const Node = AST.Node;
const Span = @import("../span.zig");

/// A comparison a `[key op value]` predicate performs against a node's
/// attribute/payload value. `present` is the bare `[key]` form (key exists,
/// value ignored). `word` is CSS's `~=`: the value is one whitespace-separated
/// token of `actual` — the natural test for class membership
/// (`[class~=public]` on a `class="public family"` value).
pub const Op = enum { present, eq, prefix, suffix, substr, word };

pub const AttrPred = struct {
    key: []const u8,
    op: Op = .present,
    value: []const u8 = "",
};

/// The parsed predicate set for one selector step: a kind, plus optional text
/// containment, an ordinal, and attribute tests (all ANDed).
pub const Matcher = struct {
    /// Friendly kind name, a raw `Node.Kind` tag name, or `"*"` for any.
    kind_name: []const u8,
    /// `:contains`/shorthand text — a node matches if its concatenated
    /// descendant text contains this (case-sensitive).
    contains: ?[]const u8 = null,
    /// `:nth(k)`/`[k]` — keep only the k-th match (1-based) in document order.
    nth: ?usize = null,
    attrs: []const AttrPred = &.{},
};

/// How a step relates to the scope established by the previous step.
/// `descendant` (plain whitespace, `a b`) means "anywhere under the prior
/// scope"; `child` (`a > b`) means "an immediate child of the prior scope".
/// The first step's combinator is always `.descendant`, meaning "anywhere
/// under the document root" — reproducing single-step matching.
pub const Combinator = enum { descendant, child };

/// One link in a selector chain: how it's scoped relative to the previous
/// step, plus its own predicate set.
pub const Step = struct {
    combinator: Combinator,
    matcher: Matcher,
};

/// A parsed selector: a chain of one or more `Step`s. Owns all its strings
/// via a private arena; free with `deinit`. Opaque by convention — go
/// through `parse`/`resolve*`.
pub const Selector = struct {
    arena: std.heap.ArenaAllocator,
    steps: []Step,

    pub fn deinit(self: *Selector) void {
        self.arena.deinit();
    }
};

/// A resolved node: its id plus the spans an editor would splice — `span` is
/// the whole node, `content_span` its interior (null when it has none). For
/// plain node matches these are just the node's own spans; the future
/// `section()` form is what will make them diverge.
pub const Match = struct {
    id: Node.Id,
    span: Span,
    content_span: ?Span,
};

pub const ParseError = error{InvalidSelector} || Allocator.Error;
pub const ResolveOneError = error{ NoMatch, AmbiguousMatch } || Allocator.Error;

// ── parsing ────────────────────────────────────────────────────────────────

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    a: Allocator,

    fn skipSpaces(self: *Parser) void {
        while (self.i < self.text.len and self.text[self.i] == ' ') self.i += 1;
    }

    fn ident(self: *Parser) []const u8 {
        const start = self.i;
        while (self.i < self.text.len) : (self.i += 1) {
            const c = self.text[self.i];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '*') continue;
            break;
        }
        return self.text[start..self.i];
    }

    /// Read a `"..."`/`'...'` quoted string (returns the inner bytes) or, when
    /// unquoted, everything up to `stop` (for bare bracket values like `zig`).
    fn value(self: *Parser, stop: u8) ParseError![]const u8 {
        if (self.i < self.text.len and (self.text[self.i] == '"' or self.text[self.i] == '\'')) {
            const q = self.text[self.i];
            self.i += 1;
            const start = self.i;
            while (self.i < self.text.len and self.text[self.i] != q) self.i += 1;
            if (self.i >= self.text.len) return error.InvalidSelector;
            const s = self.text[start..self.i];
            self.i += 1; // closing quote
            return s;
        }
        const start = self.i;
        while (self.i < self.text.len and self.text[self.i] != stop) self.i += 1;
        return self.text[start..self.i];
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.i >= self.text.len or self.text[self.i] != c) return error.InvalidSelector;
        self.i += 1;
    }

    fn parseMatcher(self: *Parser) ParseError!Matcher {
        const name = self.ident();
        if (name.len == 0) return error.InvalidSelector;

        var contains: ?[]const u8 = null;
        var nth: ?usize = null;
        var attrs: std.ArrayList(AttrPred) = .empty;

        while (self.i < self.text.len) {
            switch (self.text[self.i]) {
                '(' => {
                    self.i += 1;
                    contains = try self.a.dupe(u8, try self.value(')'));
                    try self.expect(')');
                },
                ':' => {
                    self.i += 1;
                    const pseudo = self.ident();
                    try self.expect('(');
                    if (std.mem.eql(u8, pseudo, "contains")) {
                        contains = try self.a.dupe(u8, try self.value(')'));
                    } else if (std.mem.eql(u8, pseudo, "nth")) {
                        nth = std.fmt.parseInt(usize, try self.value(')'), 10) catch return error.InvalidSelector;
                    } else return error.InvalidSelector;
                    try self.expect(')');
                },
                '[' => {
                    self.i += 1;
                    const inner_start = self.i;
                    // Peek: an all-digit bracket is an ordinal shorthand (`item[2]`).
                    while (self.i < self.text.len and self.text[self.i] != ']') self.i += 1;
                    const inner = self.text[inner_start..self.i];
                    try self.expect(']');
                    if (inner.len > 0 and allDigits(inner)) {
                        nth = std.fmt.parseInt(usize, inner, 10) catch return error.InvalidSelector;
                    } else {
                        try attrs.append(self.a, try parseAttr(self.a, inner));
                    }
                },
                else => break,
            }
        }

        return .{
            .kind_name = try self.a.dupe(u8, name),
            .contains = contains,
            .nth = nth,
            .attrs = try attrs.toOwnedSlice(self.a),
        };
    }
};

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Parse the inside of a `[...]` attribute predicate (`key`, `key=v`,
/// `key^=v`, `key$=v`, `key*=v`). Quotes around the value are stripped.
fn parseAttr(a: Allocator, inner: []const u8) ParseError!AttrPred {
    // Find the operator (two-char ops first).
    var op: Op = .present;
    var op_at: ?usize = null;
    var op_len: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '=') {
            if (i > 0 and (inner[i - 1] == '^' or inner[i - 1] == '$' or inner[i - 1] == '*' or inner[i - 1] == '~')) {
                op = switch (inner[i - 1]) {
                    '^' => .prefix,
                    '$' => .suffix,
                    '~' => .word,
                    else => .substr,
                };
                op_at = i - 1;
                op_len = 2;
            } else {
                op = .eq;
                op_at = i;
                op_len = 1;
            }
            break;
        }
    }

    if (op_at == null) {
        const key = std.mem.trim(u8, inner, " ");
        if (key.len == 0) return error.InvalidSelector;
        return .{ .key = try a.dupe(u8, key), .op = .present };
    }

    const key = std.mem.trim(u8, inner[0..op_at.?], " ");
    var val = std.mem.trim(u8, inner[op_at.? + op_len ..], " ");
    if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) {
        val = val[1 .. val.len - 1];
    }
    if (key.len == 0) return error.InvalidSelector;
    return .{ .key = try a.dupe(u8, key), .op = op, .value = try a.dupe(u8, val) };
}

/// Parse `text` into a `Selector` (freed with `.deinit()`). A chain of
/// whitespace-separated steps, e.g. `list > item("dishes")`: a `>` between
/// steps (optionally space-padded) means `.child`; plain whitespace means
/// `.descendant`. A single-step selector (no combinator) parses to a
/// one-element chain with `.descendant`, so existing single-step behavior is
/// unchanged.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Selector {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var p = Parser{ .text = text, .a = a };
    var steps: std.ArrayList(Step) = .empty;

    p.skipSpaces();
    const first = try p.parseMatcher();
    try steps.append(a, .{ .combinator = .descendant, .matcher = first });
    p.skipSpaces();

    while (p.i < text.len) {
        var comb: Combinator = .descendant;
        if (text[p.i] == '>') {
            comb = .child;
            p.i += 1;
            p.skipSpaces();
        }
        // A dangling `>` (nothing left to match) or any other trailing junk
        // that isn't a valid step start is an error.
        if (p.i >= text.len) return error.InvalidSelector;
        const m = try p.parseMatcher();
        try steps.append(a, .{ .combinator = comb, .matcher = m });
        p.skipSpaces();
    }

    return .{ .arena = arena, .steps = try steps.toOwnedSlice(a) };
}

// ── resolving ──────────────────────────────────────────────────────────────

/// Every node (in document order) the selector's step chain matches. Caller
/// frees the returned slice.
///
/// Walks the chain one step at a time, scoping each step to the *current
/// set* left by the previous step (seeded with just the root, so the first
/// step — always `.descendant` — matches anywhere under it, reproducing
/// single-step behavior). Each step's `:nth`/`[k]` is applied to that step's
/// document-ordered candidates before the surviving picks become the current
/// set for the next step — so `list:nth(2) > item` narrows to the 2nd list
/// first, then matches only items that are direct children of *that* list.
pub fn resolveAll(gpa: Allocator, doc: *const Document, selector: *const Selector) Allocator.Error![]Match {
    const ast = &doc.ast;
    // Membership in the "current set" established by the previous step.
    // Sized by node id since ids are build order, not source order.
    const current = try gpa.alloc(bool, ast.nodes.len);
    defer gpa.free(current);
    @memset(current, false);
    current[ast.root] = true;

    // Document-ordered candidates of the step currently being resolved;
    // after the loop this holds the final step's surviving (nth-filtered)
    // matches, already in document order.
    var ordered: std.ArrayList(Node.Id) = .empty;
    defer ordered.deinit(gpa);

    for (selector.steps) |step| {
        ordered.clearRetainingCapacity();
        // Document order = pre-order DFS (node ids are build order, not
        // source order, so we must traverse rather than sort by id).
        try collectStep(gpa, ast, ast.root, false, current, &step, &ordered);

        // Apply this step's `:nth`/`[k]` over its document-ordered
        // candidates, before they become the scope for the next step.
        if (step.matcher.nth) |k| {
            if (k >= 1 and k <= ordered.items.len) {
                const picked = ordered.items[k - 1];
                ordered.clearRetainingCapacity();
                try ordered.append(gpa, picked);
            } else {
                ordered.clearRetainingCapacity();
            }
        }

        @memset(current, false);
        for (ordered.items) |id| current[id] = true;
    }

    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(gpa);
    for (ordered.items) |id| {
        const node = ast.nodes[id];
        _ = node;
        try out.append(gpa, .{ .id = id, .span = doc.span(id), .content_span = doc.contentSpan(id) });
    }
    return out.toOwnedSlice(gpa);
}

/// Pre-order DFS that walks `id`'s subtree looking for candidates of `step`.
/// `ancestor_in_current` is true when some strict ancestor of `id` is in
/// `current` (the previous step's surviving set); together with `current`
/// itself this gives, for each child `cid` of `id`, both flags the spec
/// needs: `parent_in_current` is just `current[id]` (`id` *is* `cid`'s
/// parent), and `ancestor_in_current` for `cid` is `ancestor_in_current(id)
/// or current[id]`. A child is a candidate iff its scope flag — the parent
/// one for `.child`, the ancestor one for `.descendant` — is true and it
/// matches `step.matcher`. Only children are ever tested, so the root `doc`
/// node (passed as the initial `id`) is a scope but never itself a
/// candidate.
fn collectStep(
    gpa: Allocator,
    ast: *const AST,
    id: Node.Id,
    ancestor_in_current: bool,
    current: []const bool,
    step: *const Step,
    out: *std.ArrayList(Node.Id),
) Allocator.Error!void {
    const parent_in_current = current[id];
    const child_ancestor_in_current = ancestor_in_current or parent_in_current;
    var c = ast.nodes[id].first_child;
    while (c) |cid| {
        const scoped = switch (step.combinator) {
            .child => parent_in_current,
            .descendant => child_ancestor_in_current,
        };
        if (scoped and try matches(gpa, ast, cid, &step.matcher)) {
            try out.append(gpa, cid);
        }
        try collectStep(gpa, ast, cid, child_ancestor_in_current, current, step, out);
        c = ast.nodes[cid].next_sibling;
    }
}

fn matches(gpa: Allocator, ast: *const AST, id: Node.Id, m: *const Matcher) Allocator.Error!bool {
    if (!kindNameMatches(m.kind_name, ast.nodes[id].kind)) return false;
    for (m.attrs) |pred| if (!attrMatches(ast, id, pred)) return false;
    if (m.contains) |needle| {
        const text = try textOf(gpa, ast, id);
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, needle) == null) return false;
    }
    return true;
}

/// The single node the selector matches, or `NoMatch`/`AmbiguousMatch`. The
/// CLI uses `resolveAll` directly so it can list the candidates on ambiguity;
/// this is the library convenience for callers that want exactly one.
pub fn resolveOne(gpa: Allocator, doc: *const Document, selector: *const Selector) ResolveOneError!Node.Id {
    const all = try resolveAll(gpa, doc, selector);
    defer gpa.free(all);
    if (all.len == 0) return error.NoMatch;
    if (all.len > 1) return error.AmbiguousMatch;
    return all[0].id;
}

// ── kind names, attributes, text ───────────────────────────────────────────

fn eqAny(name: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, name, o)) return true;
    return false;
}

/// Takes a whole `Kind`, not just its tag: since `div`, `span`, `element` and
/// `directive` collapsed into one `container` kind, the selector names that
/// used to BE tags (`div`, `span`) are now tag-plus-name tests, and only the
/// payload can answer them.
fn kindNameMatches(name: []const u8, kind: Node.Kind) bool {
    const tag = std.meta.activeTag(kind);
    if (std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, "any")) return true;
    if (eqAny(name, &.{ "heading", "h" })) return tag == .heading;
    if (eqAny(name, &.{ "para", "paragraph", "p" })) return tag == .para;
    if (eqAny(name, &.{ "link", "a" })) return tag == .link;
    if (eqAny(name, &.{ "image", "img" })) return tag == .image;
    if (eqAny(name, &.{"list"})) return tag == .bullet_list or tag == .ordered_list or tag == .task_list or tag == .definition_list;
    if (eqAny(name, &.{"item"})) return tag == .list_item or tag == .task_list_item or tag == .definition_list_item;
    if (eqAny(name, &.{"code"})) return tag == .code_block;
    if (eqAny(name, &.{ "metadata", "meta", "frontmatter" })) return tag == .metadata;
    // The nine marks share one tag now, so their names test the family member.
    if (eqAny(name, &.{ "emph", "em", "emphasis", "italic" })) return kind == .inline_mark and kind.inline_mark == .emph;
    if (eqAny(name, &.{ "strong", "bold", "b" })) return kind == .inline_mark and kind.inline_mark == .strong;
    if (eqAny(name, &.{ "quote", "blockquote" })) return tag == .block_quote;
    if (eqAny(name, &.{"table"})) return tag == .table;
    if (eqAny(name, &.{"cell"})) return tag == .cell;
    if (eqAny(name, &.{"row"})) return tag == .row;
    if (eqAny(name, &.{"section"})) return tag == .section;
    if (eqAny(name, &.{ "text", "str" })) return tag == .str;
    // `div` and `span` used to be their own kinds; they are now a `container`
    // named "div"/"span", so the shorthand that addressed them has to match on
    // the name. `element` and `directive` stay addressable as spellings of
    // `container` so existing selectors (`directive[name=vis]`) keep working —
    // but they no longer DISCRIMINATE, since one kind now serves both.
    if (eqAny(name, &.{ "div", "span" })) {
        return tag == .container and std.mem.eql(u8, kind.container.name, name);
    }
    if (eqAny(name, &.{ "container", "element", "directive" })) return tag == .container;
    // Power-user escape hatch: the exact kind name — which for a mark is the
    // MARK's name (`superscript`, `insert`, …), matching what `-o ast` prints.
    return std.mem.eql(u8, name, kind.kindName());
}

fn opMatch(op: Op, actual: []const u8, want: []const u8) bool {
    return switch (op) {
        .present => true,
        .eq => std.mem.eql(u8, actual, want),
        .prefix => std.mem.startsWith(u8, actual, want),
        .suffix => std.mem.endsWith(u8, actual, want),
        .substr => std.mem.indexOf(u8, actual, want) != null,
        .word => blk: {
            if (want.len == 0) break :blk false;
            var it = std.mem.tokenizeAny(u8, actual, " \t\r\n");
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, want)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn attrMatches(ast: *const AST, id: Node.Id, pred: AttrPred) bool {
    const node = ast.nodes[id];
    if (std.mem.eql(u8, pred.key, "level")) {
        if (std.meta.activeTag(node.kind) != .heading) return false;
        if (pred.op == .present) return true;
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{node.kind.heading.level}) catch return false;
        return opMatch(pred.op, s, pred.value);
    }
    if (eqAny(pred.key, &.{ "dest", "href", "src", "destination" })) {
        const d: ?[]const u8 = switch (node.kind) {
            .link => |l| l.destination,
            .image => |im| im.destination,
            else => null,
        };
        return if (d) |dd| opMatch(pred.op, dd, pred.value) else false;
    }
    if (std.mem.eql(u8, pred.key, "lang")) {
        const l: ?[]const u8 = switch (node.kind) {
            .code_block => |c| c.lang,
            .metadata => |m| m.lang,
            else => null,
        };
        return if (l) |ll| opMatch(pred.op, ll, pred.value) else false;
    }
    // `name` addresses the named kinds — a directive's type (`directive
    // [name=vis]`) or a generic element's tag (`element[name=video]`).
    if (std.mem.eql(u8, pred.key, "name")) {
        const nm: ?[]const u8 = switch (node.kind) {
            .container => |c| c.name,
            else => null,
        };
        if (nm) |n| return if (pred.op == .present) true else opMatch(pred.op, n, pred.value);
        return false;
    }
    if (std.mem.eql(u8, pred.key, "ordered")) return std.meta.activeTag(node.kind) == .ordered_list;
    if (std.mem.eql(u8, pred.key, "checked")) return switch (node.kind) {
        .task_list_item => |t| t.checked,
        else => false,
    };
    // Fall back to the generic `{...}` attribute side-table.
    if (pred.op == .present) return ast.attrsOf(id).find(pred.key) != null;
    return if (ast.attrsOf(id).get(pred.key)) |v| opMatch(pred.op, v, pred.value) else false;
}

/// A node's text content: every descendant text payload concatenated (what
/// `:contains` tests against, and how a `query` preview is built). Caller
/// frees. Mirrors the alt-text extraction the HTML renderer already does.
pub fn textOf(gpa: Allocator, ast: *const AST, id: Node.Id) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try textInto(gpa, ast, id, &buf);
    return buf.toOwnedSlice(gpa);
}

fn textInto(gpa: Allocator, ast: *const AST, id: Node.Id, buf: *std.ArrayList(u8)) Allocator.Error!void {
    switch (ast.nodes[id].kind) {
        .str => |s| try buf.appendSlice(gpa, s),
        .text_leaf => |l| try buf.appendSlice(gpa, l.text),
        .smart_punctuation => |v| try buf.appendSlice(gpa, v.ascii()),
        .raw_inline => |v| try buf.appendSlice(gpa, v.text),
        .code_block => |v| try buf.appendSlice(gpa, v.text),
        .raw_block => |v| try buf.appendSlice(gpa, v.text),
        .non_breaking_space, .soft_break, .hard_break => try buf.append(gpa, ' '),
        else => {
            var c = ast.nodes[id].first_child;
            while (c) |cid| {
                try textInto(gpa, ast, cid, buf);
                c = ast.nodes[cid].next_sibling;
            }
        },
    }
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseMd(a: Allocator, src: []const u8) !Document {
    const Markdown = @import("../languages/markdown/markdown.zig");
    var doc = try Markdown.parse(a, src, .{});
    doc.link_references.deinit(a);
    doc.footnotes.deinit(a);
    return .{ .source = doc.source, .ast = doc.ast, .node_spans = doc.node_spans, .node_content_spans = doc.node_content_spans };
}

test "parse: kind, contains shorthand, :nth, and attribute predicates" {
    // Single-step selectors parse to a one-element chain with `.descendant`
    // — the shape existing (pre-combinator) callers rely on.
    var s1 = try parse(testing.allocator, "heading");
    defer s1.deinit();
    try testing.expectEqual(@as(usize, 1), s1.steps.len);
    try testing.expectEqual(Combinator.descendant, s1.steps[0].combinator);
    try testing.expectEqualStrings("heading", s1.steps[0].matcher.kind_name);

    var s2 = try parse(testing.allocator, "heading[level=2]");
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 1), s2.steps[0].matcher.attrs.len);
    try testing.expectEqualStrings("level", s2.steps[0].matcher.attrs[0].key);
    try testing.expectEqual(Op.eq, s2.steps[0].matcher.attrs[0].op);
    try testing.expectEqualStrings("2", s2.steps[0].matcher.attrs[0].value);

    var s3 = try parse(testing.allocator, "item[2]");
    defer s3.deinit();
    try testing.expectEqual(@as(?usize, 2), s3.steps[0].matcher.nth);

    var s4 = try parse(testing.allocator, "link[dest^=\"http\"]");
    defer s4.deinit();
    try testing.expectEqual(Op.prefix, s4.steps[0].matcher.attrs[0].op);
    try testing.expectEqualStrings("http", s4.steps[0].matcher.attrs[0].value);

    var s5 = try parse(testing.allocator, "heading(\"Status\")");
    defer s5.deinit();
    try testing.expectEqualStrings("Status", s5.steps[0].matcher.contains.?);

    try testing.expectError(error.InvalidSelector, parse(testing.allocator, ""));
}

test "parse: multi-step chains distinguish descendant and child combinators" {
    var s1 = try parse(testing.allocator, "list > item");
    defer s1.deinit();
    try testing.expectEqual(@as(usize, 2), s1.steps.len);
    try testing.expectEqual(Combinator.descendant, s1.steps[0].combinator);
    try testing.expectEqual(Combinator.child, s1.steps[1].combinator);
    try testing.expectEqualStrings("list", s1.steps[0].matcher.kind_name);
    try testing.expectEqualStrings("item", s1.steps[1].matcher.kind_name);

    var s2 = try parse(testing.allocator, "blockquote para");
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 2), s2.steps.len);
    try testing.expectEqual(Combinator.descendant, s2.steps[1].combinator);

    // `>` needs no surrounding spaces.
    var s3 = try parse(testing.allocator, "list>item");
    defer s3.deinit();
    try testing.expectEqual(@as(usize, 2), s3.steps.len);
    try testing.expectEqual(Combinator.child, s3.steps[1].combinator);

    // Per-step predicates still parse inside a chain.
    var s4 = try parse(testing.allocator, "list:nth(2) > item(\"dishes\")");
    defer s4.deinit();
    try testing.expectEqual(@as(?usize, 2), s4.steps[0].matcher.nth);
    try testing.expectEqualStrings("dishes", s4.steps[1].matcher.contains.?);
}

test "parse: dangling '>' and trailing junk are rejected" {
    try testing.expectError(error.InvalidSelector, parse(testing.allocator, "list >"));
    try testing.expectError(error.InvalidSelector, parse(testing.allocator, "list > "));
    try testing.expectError(error.InvalidSelector, parse(testing.allocator, "list !bad"));
}

test "resolveAll: a directive node is addressable by its kind name" {
    const Markdown = @import("../languages/markdown/markdown.zig");
    var doc = try Markdown.parse(testing.allocator, ":::note\nhi\n:::\n\n::leaf\n", .{ .directives = true });
    doc.link_references.deinit(testing.allocator);
    doc.footnotes.deinit(testing.allocator);
    var ast = doc.document();
    defer ast.deinit();

    var sel = try parse(testing.allocator, "directive");
    defer sel.deinit();
    const ms = try resolveAll(testing.allocator, &ast, &sel);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expect(ast.ast.nodes[ms[0].id].kind == .container);
}

test "resolveAll: directive[name=...] and [class~=...] audience filtering" {
    const Markdown = @import("../languages/markdown/markdown.zig");
    const src =
        ":::vis{.public}\npublic stuff\n:::\n\n" ++
        ":::vis{.adam .family}\nprivate stuff\n:::\n\n" ++
        ":::note{.public}\nnot a vis block\n:::\n";
    var doc = try Markdown.parse(testing.allocator, src, .{ .directives = true });
    doc.link_references.deinit(testing.allocator);
    doc.footnotes.deinit(testing.allocator);
    var ast = doc.document();
    defer ast.deinit();

    // All vis directives, regardless of audience.
    var vis = try parse(testing.allocator, "directive[name=vis]");
    defer vis.deinit();
    const all_vis = try resolveAll(testing.allocator, &ast, &vis);
    defer testing.allocator.free(all_vis);
    try testing.expectEqual(@as(usize, 2), all_vis.len);

    // Only vis directives whose class set contains `public`.
    var pub_vis = try parse(testing.allocator, "directive[name=vis][class~=public]");
    defer pub_vis.deinit();
    const public = try resolveAll(testing.allocator, &ast, &pub_vis);
    defer testing.allocator.free(public);
    try testing.expectEqual(@as(usize, 1), public.len);
    try testing.expectEqualStrings("vis", ast.ast.nodes[public[0].id].kind.container.name);

    // `~=` is word-membership, not substring: `publi` matches nothing.
    var partial = try parse(testing.allocator, "directive[class~=publi]");
    defer partial.deinit();
    const none = try resolveAll(testing.allocator, &ast, &partial);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "resolveAll: matches by kind across a real markdown tree" {
    var ast = try parseMd(testing.allocator, "# One\n\n## Two\n\n- a\n- b\n");
    defer ast.deinit();

    var sel = try parse(testing.allocator, "heading");
    defer sel.deinit();
    const hs = try resolveAll(testing.allocator, &ast, &sel);
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 2), hs.len);

    var items = try parse(testing.allocator, "item");
    defer items.deinit();
    const its = try resolveAll(testing.allocator, &ast, &items);
    defer testing.allocator.free(its);
    try testing.expectEqual(@as(usize, 2), its.len);
}

test "resolveAll: attribute predicate on heading level, and :nth" {
    var ast = try parseMd(testing.allocator, "# One\n\n## Two\n\n### Three\n");
    defer ast.deinit();

    var lvl2 = try parse(testing.allocator, "heading[level=2]");
    defer lvl2.deinit();
    const m2 = try resolveAll(testing.allocator, &ast, &lvl2);
    defer testing.allocator.free(m2);
    try testing.expectEqual(@as(usize, 1), m2.len);
    try testing.expectEqual(@as(u32, 2), ast.ast.nodes[m2[0].id].kind.heading.level);

    var third = try parse(testing.allocator, "heading:nth(3)");
    defer third.deinit();
    const m3 = try resolveAll(testing.allocator, &ast, &third);
    defer testing.allocator.free(m3);
    try testing.expectEqual(@as(usize, 1), m3.len);
    try testing.expectEqual(@as(u32, 3), ast.ast.nodes[m3[0].id].kind.heading.level);
}

test "resolveAll: :contains matches on descendant text; resolveOne enforces uniqueness" {
    var ast = try parseMd(testing.allocator, "# Shopping\n\n# Status\n");
    defer ast.deinit();

    var sel = try parse(testing.allocator, "heading(\"Status\")");
    defer sel.deinit();
    const one = try resolveOne(testing.allocator, &ast, &sel);
    const txt = try textOf(testing.allocator, &ast.ast, one);
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings("Status", txt);

    var any = try parse(testing.allocator, "heading");
    defer any.deinit();
    try testing.expectError(error.AmbiguousMatch, resolveOne(testing.allocator, &ast, &any));

    var none = try parse(testing.allocator, "heading(\"Nope\")");
    defer none.deinit();
    try testing.expectError(error.NoMatch, resolveOne(testing.allocator, &ast, &none));
}

test "resolveAll: link destination prefix predicate" {
    var ast = try parseMd(testing.allocator, "[a](http://x.com) and [b](./rel)\n");
    defer ast.deinit();

    var sel = try parse(testing.allocator, "link[dest^=\"http\"]");
    defer sel.deinit();
    const ms = try resolveAll(testing.allocator, &ast, &sel);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    try testing.expect(ast.ast.nodes[ms[0].id].kind == .link);
}

test "resolveAll: descendant chain matches items nested at any depth under a list" {
    // A list item can itself contain a nested list — `list item` must reach
    // through that nesting, not just the outer list's direct children.
    var ast = try parseMd(testing.allocator, "- a\n  - b\n- c\n");
    defer ast.deinit();

    var sel = try parse(testing.allocator, "list item");
    defer sel.deinit();
    const ms = try resolveAll(testing.allocator, &ast, &sel);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 3), ms.len);

    var texts: [3][]u8 = undefined;
    for (ms, 0..) |m, i| texts[i] = try textOf(testing.allocator, &ast.ast, m.id);
    defer for (texts) |t| testing.allocator.free(t);
    // `textOf` concatenates ALL descendant text, so item "a" (which contains
    // the nested item "b") reads "ab"; only "b" and "c" are their own leaf.
    try testing.expectEqualStrings("ab", texts[0]);
    try testing.expectEqualStrings("b", texts[1]);
    try testing.expectEqualStrings("c", texts[2]);
}

test "resolveAll: child combinator requires the immediate parent, unlike descendant" {
    // `> - x` is a blockquote containing a list containing an item
    // containing a paragraph: the paragraph's immediate parent is the list
    // item, not the blockquote, so only the descendant form should reach it.
    var ast = try parseMd(testing.allocator, "> - x\n");
    defer ast.deinit();

    var child_sel = try parse(testing.allocator, "blockquote > para");
    defer child_sel.deinit();
    const child_ms = try resolveAll(testing.allocator, &ast, &child_sel);
    defer testing.allocator.free(child_ms);
    try testing.expectEqual(@as(usize, 0), child_ms.len);

    var desc_sel = try parse(testing.allocator, "blockquote para");
    defer desc_sel.deinit();
    const desc_ms = try resolveAll(testing.allocator, &ast, &desc_sel);
    defer testing.allocator.free(desc_ms);
    try testing.expectEqual(@as(usize, 1), desc_ms.len);
    const txt = try textOf(testing.allocator, &ast.ast, desc_ms[0].id);
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings("x", txt);
}

test "resolveAll: per-step :nth scopes a later step to one specific ancestor" {
    // Two lists; `list:nth(2) > item("dishes")` must pick "dishes" out of
    // the SECOND list only, even though the word also could only appear once
    // — the point is that step 1's nth narrows the scope step 2 searches in.
    var ast = try parseMd(testing.allocator, "# Groceries\n\n- milk\n- eggs\n\n# Chores\n\n- dishes\n- laundry\n");
    defer ast.deinit();

    var sel = try parse(testing.allocator, "list:nth(2) > item(\"dishes\")");
    defer sel.deinit();
    const ms = try resolveAll(testing.allocator, &ast, &sel);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
    const txt = try textOf(testing.allocator, &ast.ast, ms[0].id);
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings("dishes", txt);

    // Scoping to the FIRST list instead means "dishes" isn't there to find.
    var none_sel = try parse(testing.allocator, "list:nth(1) > item(\"dishes\")");
    defer none_sel.deinit();
    const none_ms = try resolveAll(testing.allocator, &ast, &none_sel);
    defer testing.allocator.free(none_ms);
    try testing.expectEqual(@as(usize, 0), none_ms.len);

    // Unscoped (no nth on step 1) still finds it via either list.
    var any_sel = try parse(testing.allocator, "list > item(\"dishes\")");
    defer any_sel.deinit();
    const any_ms = try resolveAll(testing.allocator, &ast, &any_sel);
    defer testing.allocator.free(any_ms);
    try testing.expectEqual(@as(usize, 1), any_ms.len);
}
