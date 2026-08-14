//! reStructuredText — the parser. Source bytes to twig's shared `AST`, judged
//! by `conformance.zig`'s corpus comparison (`encode(parse(source)) ==
//! case.doctree`) rather than by the doctree codec `doctree.zig` already
//! passes through.
//!
//! ── Scope of THIS file, today ───────────────────────────────────────────────
//! The first vertical slice, chosen by corpus weight and structural
//! simplicity rather than by docutils' own test-file order (see the "Bottom-up
//! by corpus weight" call in the session this landed in): paragraphs, section
//! titles/nesting, transitions, block quotes, and comments — plus, added
//! since, bullet lists (`test_bullet_lists.py`, 7/7), enumerated lists
//! (`test_enumerated_lists.py`, 15/15), definition lists
//! (`test_definition_lists.py`, 7/11) and field lists
//! (`test_field_lists.py`, 6/11). No inline markup parsing yet —
//! a paragraph's whole text becomes ONE `.str` child, so any case whose
//! expected doctree contains `emphasis`/`strong`/`reference`/etc. inside a
//! paragraph will not compare equal yet, and no backslash ESCAPE is removed
//! anywhere (docutils strips those during inline parsing). Everything else
//! (option lists, literal blocks, directives, the hyperlink/footnote/
//! citation/substitution clusters, tables) is unimplemented and deliberately
//! out of this file for now.
//!
//! ── Lists ────────────────────────────────────────────────────────────────
//! Both list constructs share `parseListItem`, which is docutils' own
//! arrangement — one `list_item` method serves its bullet and enumerated
//! states alike, and the two differ only in how a marker is recognized. An
//! item's body reuses `findElevatedExtent`, the same function block quotes
//! use, since "everything indented at least to the item's content column,
//! blank-tolerant" is the same question either way.
//!
//! The one thing block quotes don't need and items do: the marker line's OWN
//! remainder is the first paragraph's first line, but it isn't indented to
//! the content column IN THE SOURCE (the marker sits where the indent would
//! be), so it can't be handed to the generic `parseBody`/`findParagraphEnd`
//! path — `parseListItem` merges it with any immediately-following
//! continuation lines by hand, then hands the rest of the item to `parseBody`
//! same as always. An item with NOTHING after its marker takes the other
//! branch, docutils' `get_first_known_indented`: its content column is not
//! the marker's reserved width but the minimum indent of whatever follows.
//!
//! A same-column BULLET with a different character ends the list without
//! special-casing: the loop just stops and `parseBody`'s own dispatch loop
//! sees that line fresh, starting a new list — which is exactly what the
//! corpus's "different bullets" case (asserts_error, so not asserted on the
//! tree, but the shape still matters) wants: back-to-back `<bullet_list>`
//! siblings, not one list refusing a foreign bullet. Enumerated lists end the
//! same way, on a richer test (format, sequence and ordinal must all
//! continue) spelled out at `parseEnumeratedList`.
//!
//! Enumerators bring one rule nothing else in the parser has: an enumerator
//! is not self-evidently a list marker. `1.` at the head of a line is a list
//! only if the line BELOW it is blank, indented, or carries the next
//! enumerator in the sequence — otherwise the two lines are one paragraph.
//! See `isEnumeratedListItem`; it is what keeps prose like `(LCD) is an
//! acronym` out of the list machinery, together with the strict roman-numeral
//! validation in `fromRoman`.
//!
//! A definition list's term is stranger still: it looks like nothing at all,
//! and its evidence is entirely BELOW it — a plain line with a deeper line
//! immediately under it. `classify` is where that ordering lives, and having
//! it in one function is what lets `parseDefinitionList` decide when to stop
//! by asking the same question `parseBody` asks to start.
//!
//! ── Why this shape ───────────────────────────────────────────────────────
//! Bottom-up onto `AST.Builder` (a container's children are fully known
//! before the container is minted), the same shape `languages/markdown
//! /block.zig`'s doc comment describes and contrasts with djot's own
//! flat-event/manual-array approach — rST's indentation-driven block
//! structure is much closer to Markdown's than to djot's paired open/close
//! event stream. The one place this deviates from pure bottom-up-only-once is
//! section nesting (see `parseDocument`'s frame stack below), which needs a
//! node (the wrapping `<section>`) finalized only once ALL of its nested
//! subsections have closed — handled with an explicit stack of pending
//! `Frame`s rather than `Builder`'s batch-children call, mirroring the same
//! "close upward while a new item's level is <= what's open" algorithm
//! `languages/djot/parser.zig`'s `closeHeading` uses for its own (numeric,
//! `#`-counted) heading levels — except rST's levels are not a number in the
//! source at all, but the ORDER two adornment characters are first used in,
//! which is why a level here is resolved from a document-wide `Style` stack
//! rather than read directly off the line.
//!
//! ── What's NOT tracked because the corpus doesn't check it ─────────────────
//! `doctree.decode` produces a bare `AST` with no source positions (its own
//! doc comment says so), so `conformance.zig`'s comparison never looks at a
//! span. This file still sets spans (best-effort line-covering ranges) because
//! a real `Document` should have them for editing/diagnostics use elsewhere,
//! but getting one slightly wrong does not fail the corpus ratchet the way a
//! wrong `Kind` or a wrong `attrs` entry does.
//!
//! ── Section id/name generation ──────────────────────────────────────────────
//! docutils derives `ids`/`names` from the title text via `make_id`
//! (lowercase, transliterate, NFKD-strip to ASCII, non-id runs -> `-`, trim)
//! and `fully_normalize_name` (collapse whitespace, lowercase, escape internal
//! spaces as `\ ` when serialized). `makeSlug`/`makeNormalizedName` below are
//! an ASCII-only approximation: multi-byte UTF-8 sequences are dropped from
//! the id slug entirely (rather than NFKD-decomposed to their base letter) and
//! passed through unchanged in the name. That is a known, narrow gap — it
//! only matters for titles with non-ASCII letters — rather than a full
//! Unicode normalization implementation, which nothing in this slice's target
//! groups needs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const Span = @import("../../span.zig");
const TwigDocument = @import("../../document.zig");
const diagnostic_mod = @import("diagnostic.zig");

pub const Options = struct {
    /// Fed into the root `<document source="...">` attribute the corpus's
    /// doctrees carry — docutils takes it from the source path it was
    /// invoked with; the vendored corpus was always generated with the
    /// literal string `"test data"` (see `scripts/extract-rst-corpus.py`).
    /// Left empty to omit the attribute, which is the right default for a
    /// real caller that has no filename to fake.
    source_name: []const u8 = "",
};

pub const ParseResult = struct {
    document: TwigDocument,
    diagnostics: []const diagnostic_mod.Diagnostic,

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        self.document.deinit();
        allocator.free(self.diagnostics);
    }
};

pub fn parse(allocator: Allocator, source: []const u8, options: Options) Allocator.Error!ParseResult {
    var p = try Parser.init(allocator, source);
    defer p.deinit();
    const root = try p.parseDocument(options);
    const diagnostics = try p.diagnostics.toOwnedSlice(allocator);
    errdefer allocator.free(diagnostics);
    const document = try p.b.finishDocument(source, root);
    return .{ .document = document, .diagnostics = diagnostics };
}

/// One line of source, as a byte range excluding its terminating `\n`.
const LineInfo = struct { start: usize, end: usize };

/// An adornment character plus whether it appeared as an OVERLINE-and-
/// underline pair rather than underline-only — docutils treats those as two
/// distinct "styles" even for the same character, so a document using both
/// `====`-underline and `====`-over-and-underline titles nests them as
/// different levels. Equality on both fields is what `parseDocument`'s style
/// stack searches by.
const Style = struct { ch: u8, double: bool };

/// A section whose title is known but whose body is still being collected —
/// its own `<section>` node cannot be minted until every subsection nested
/// inside it has closed, since `Builder.addContainer` wants all children
/// up front. `ids`/`names` are owned (freed by `finishFrame`).
const Frame = struct {
    title_id: Node.Id,
    children: std.ArrayList(Node.Id) = .empty,
    span_start: usize,
    ids: []const u8,
    names: []const u8,
};

const TitleMatch = struct {
    style: Style,
    text: []const u8,
    text_span: Span,
    /// Start of the whole title construct — the overline's line when present,
    /// otherwise the title text's own line.
    span_start: usize,
    /// Line index right after the construct (the text line, or the
    /// underline, whichever is last).
    next_line: usize,
};

const BodyResult = struct { items: []Node.Id, stopped_at: usize };

/// The block construct a line opens — `Parser.classify`'s answer, and the one
/// place `parseBody`'s dispatch precedence is written down.
const BlockStart = union(enum) {
    title: TitleMatch,
    transition,
    comment,
    bullet: BulletMatch,
    enumerator: EnumMatch,
    field_marker,
    definition_term,
    paragraph,
};

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    lines: []const LineInfo,
    b: Builder,
    diagnostics: std.ArrayList(diagnostic_mod.Diagnostic) = .empty,
    /// Ids already handed out to a section in this document, so a repeated
    /// title text gets `-1`, `-2`, ... appended rather than colliding.
    /// Keys are owned copies.
    used_ids: std.StringHashMapUnmanaged(void) = .{},

    fn init(allocator: Allocator, source: []const u8) Allocator.Error!Parser {
        return .{ .allocator = allocator, .source = source, .lines = try computeLines(allocator, source), .b = Builder.init(allocator) };
    }

    fn deinit(self: *Parser) void {
        var it = self.used_ids.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.used_ids.deinit(self.allocator);
        self.allocator.free(self.lines);
        self.diagnostics.deinit(self.allocator);
        self.b.deinit();
    }

    // ── line helpers ────────────────────────────────────────────────────

    fn lineText(self: *const Parser, i: usize) []const u8 {
        return self.source[self.lines[i].start..self.lines[i].end];
    }

    fn leadingSpaces(self: *const Parser, i: usize) usize {
        const t = self.lineText(i);
        var n: usize = 0;
        while (n < t.len and t[n] == ' ') n += 1;
        return n;
    }

    fn isBlankLine(self: *const Parser, i: usize) bool {
        for (self.lineText(i)) |c| {
            if (c != ' ' and c != '\t') return false;
        }
        return true;
    }

    /// `lineText(i)` with `indent` columns stripped from the front and
    /// trailing whitespace trimmed from the back.
    fn trimmedContent(self: *const Parser, i: usize, indent: usize) []const u8 {
        const t = self.lineText(i);
        const c = if (t.len > indent) t[indent..] else "";
        return std.mem.trimEnd(u8, c, " \t");
    }

    // ── title / adornment recognition ──────────────────────────────────

    /// Only ever called at document top level (`indent == 0` in
    /// `parseBody`), so `i`'s own indentation is checked here rather than
    /// assumed.
    fn matchTitle(self: *const Parser, i: usize) ?TitleMatch {
        if (i >= self.lines.len) return null;
        if (self.leadingSpaces(i) != 0) return null;
        const cur = self.trimmedContent(i, 0);
        if (cur.len == 0) return null;

        if (isAdornmentLine(cur)) {
            // Overline + title + underline. The title text may be INSET
            // relative to its markers (docutils' "overline title with
            // inset" case) — only the markers themselves must sit at
            // column 0, so the text line's own indentation isn't checked.
            if (i + 2 >= self.lines.len) return null;
            if (self.isBlankLine(i + 1)) return null;
            const text = std.mem.trim(u8, self.lineText(i + 1), " \t");
            if (self.leadingSpaces(i + 2) != 0 or self.isBlankLine(i + 2)) return null;
            const under = self.trimmedContent(i + 2, 0);
            if (!isAdornmentLine(under) or under.len != cur.len or under[0] != cur[0]) return null;
            return .{
                .style = .{ .ch = cur[0], .double = true },
                .text = text,
                .text_span = Span.init(self.lines[i + 1].start, self.lines[i + 1].end),
                .span_start = self.lines[i].start,
                .next_line = i + 3,
            };
        }

        // Title + underline only.
        if (i + 1 >= self.lines.len) return null;
        if (self.leadingSpaces(i + 1) != 0 or self.isBlankLine(i + 1)) return null;
        const under = self.trimmedContent(i + 1, 0);
        if (!isAdornmentLine(under)) return null;
        return .{
            .style = .{ .ch = under[0], .double = false },
            .text = cur,
            .text_span = Span.init(self.lines[i].start, self.lines[i].end),
            .span_start = self.lines[i].start,
            .next_line = i + 2,
        };
    }

    // ── section id / name generation (see module doc comment) ──────────

    fn makeSlug(self: *Parser, title: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var last_sep = true;
        var i: usize = 0;
        while (i < title.len) {
            const c = title[i];
            if (c < 0x80) {
                if (std.ascii.isAlphanumeric(c)) {
                    try out.append(self.allocator, std.ascii.toLower(c));
                    last_sep = false;
                } else if (!last_sep) {
                    try out.append(self.allocator, '-');
                    last_sep = true;
                }
                i += 1;
            } else {
                i += utf8SeqLen(c);
                if (!last_sep) {
                    try out.append(self.allocator, '-');
                    last_sep = true;
                }
            }
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
        return out.toOwnedSlice(self.allocator);
    }

    fn makeNormalizedName(self: *Parser, title: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var pending_space = false;
        var started = false;
        var i: usize = 0;
        while (i < title.len) {
            const c = title[i];
            if (c == ' ' or c == '\t') {
                if (started) pending_space = true;
                i += 1;
                continue;
            }
            if (pending_space) {
                try out.appendSlice(self.allocator, "\\ ");
                pending_space = false;
            }
            if (c < 0x80) {
                try out.append(self.allocator, std.ascii.toLower(c));
                i += 1;
            } else {
                const n = utf8SeqLen(c);
                try out.appendSlice(self.allocator, title[i..@min(i + n, title.len)]);
                i += n;
            }
            started = true;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Takes ownership of `base` (frees it); returns the final owned,
    /// document-unique id, registering it in `used_ids`.
    fn uniquify(self: *Parser, base: []u8) Allocator.Error![]u8 {
        defer self.allocator.free(base);
        if (!self.used_ids.contains(base)) {
            const owned = try self.allocator.dupe(u8, base);
            try self.used_ids.put(self.allocator, owned, {});
            return self.allocator.dupe(u8, base);
        }
        var n: usize = 1;
        while (true) : (n += 1) {
            const cand = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base, n });
            if (self.used_ids.contains(cand)) {
                self.allocator.free(cand);
                continue;
            }
            try self.used_ids.put(self.allocator, cand, {});
            return self.allocator.dupe(u8, cand);
        }
    }

    // ── section frame open/close ────────────────────────────────────────

    fn openSection(
        self: *Parser,
        style_stack: *std.ArrayList(Style),
        frames: *std.ArrayList(Frame),
        root_children: *std.ArrayList(Node.Id),
        tm: TitleMatch,
    ) !void {
        var level_idx: ?usize = null;
        for (style_stack.items, 0..) |s, k| {
            if (s.ch == tm.style.ch and s.double == tm.style.double) {
                level_idx = k;
                break;
            }
        }
        const new_level = (level_idx orelse style_stack.items.len) + 1;
        while (frames.items.len >= new_level) {
            var f = frames.pop().?;
            const sec_id = try self.finishFrame(&f, tm.span_start);
            const target = if (frames.items.len > 0) &frames.items[frames.items.len - 1].children else root_children;
            try target.append(self.allocator, sec_id);
        }
        if (level_idx == null) {
            try style_stack.append(self.allocator, tm.style);
        } else {
            style_stack.shrinkRetainingCapacity(new_level);
        }

        const title_str = try self.b.addLeaf(.{ .str = tm.text });
        self.b.setSpan(title_str, tm.text_span);
        const title_id = try self.b.addContainer(.{ .container = .{ .name = "title" } }, &.{title_str});
        self.b.setSpelling(title_id, .{ .container_origin = .directive });
        self.b.setSpan(title_id, tm.text_span);

        const slug = try self.makeSlug(tm.text);
        const ids = try self.uniquify(slug);
        errdefer self.allocator.free(ids);
        const names = try self.makeNormalizedName(tm.text);
        errdefer self.allocator.free(names);

        try frames.append(self.allocator, .{
            .title_id = title_id,
            .span_start = tm.span_start,
            .ids = ids,
            .names = names,
        });
    }

    fn finishFrame(self: *Parser, frame: *Frame, end_offset: usize) Allocator.Error!Node.Id {
        defer self.allocator.free(frame.ids);
        defer self.allocator.free(frame.names);
        const body = try frame.children.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);
        const all = try self.allocator.alloc(Node.Id, 1 + body.len);
        defer self.allocator.free(all);
        all[0] = frame.title_id;
        @memcpy(all[1..], body);

        const id = try self.b.addContainer(.section, all);
        self.b.setSpan(id, Span.init(frame.span_start, end_offset));
        try self.b.setAttrs(id, .{ .entries = &.{
            .{ .key = "ids", .value = frame.ids },
            .{ .key = "names", .value = frame.names },
        } });
        return id;
    }

    // ── the top-level document scan ─────────────────────────────────────

    fn parseDocument(self: *Parser, options: Options) !Node.Id {
        var root_children: std.ArrayList(Node.Id) = .empty;
        errdefer root_children.deinit(self.allocator);
        var style_stack: std.ArrayList(Style) = .empty;
        defer style_stack.deinit(self.allocator);
        var frames: std.ArrayList(Frame) = .empty;
        defer {
            for (frames.items) |*f| f.children.deinit(self.allocator);
            frames.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < self.lines.len) {
            const r = try self.parseBody(i, self.lines.len, 0);
            defer self.allocator.free(r.items);
            const target = if (frames.items.len > 0) &frames.items[frames.items.len - 1].children else &root_children;
            try target.appendSlice(self.allocator, r.items);
            i = r.stopped_at;
            if (i >= self.lines.len) break;

            // `parseBody` only ever stops early (before its `hi`) at
            // top level (`indent == 0`) when it found a title — see its
            // own doc comment.
            const tm = self.matchTitle(i) orelse break;
            try self.openSection(&style_stack, &frames, &root_children, tm);
            i = tm.next_line;
        }

        while (frames.items.len > 0) {
            var f = frames.pop().?;
            const sec_id = try self.finishFrame(&f, self.source.len);
            const target = if (frames.items.len > 0) &frames.items[frames.items.len - 1].children else &root_children;
            try target.append(self.allocator, sec_id);
        }

        const children = try root_children.toOwnedSlice(self.allocator);
        defer self.allocator.free(children);
        const root = try self.b.addContainer(.doc, children);
        if (options.source_name.len > 0) {
            try self.b.setAttrs(root, .{ .entries = &.{.{ .key = "source", .value = options.source_name }} });
        }
        return root;
    }

    // ── the indentation-scoped body scan ────────────────────────────────

    /// Parses the sequence of blocks in lines `[lo, hi)`, all of which are
    /// blank OR indented at least to `indent` (the caller's job to have
    /// sliced correctly). Stops at `hi`, UNLESS `indent == 0` and a title is
    /// found first (`parseDocument` is the only caller passing `indent == 0`,
    /// and the only one that inspects `stopped_at`) — titles are recognized
    /// only at document top level, never inside a block quote's recursive
    /// call, matching docutils (a title indented inside a block quote is a
    /// parse error there, out of this slice's scope).
    fn parseBody(self: *Parser, lo: usize, hi: usize, indent: usize) Allocator.Error!BodyResult {
        var children: std.ArrayList(Node.Id) = .empty;
        errdefer children.deinit(self.allocator);
        var i = lo;
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            const line_indent = self.leadingSpaces(i);
            if (line_indent > indent) {
                const ext = self.findElevatedExtent(i, hi, indent);
                const inner = try self.parseBody(i, ext.end, ext.min_indent);
                const bq_id = try self.b.addContainer(.block_quote, inner.items);
                self.allocator.free(inner.items);
                self.b.setSpan(bq_id, Span.init(self.lines[i].start, self.lines[ext.end - 1].end));
                try children.append(self.allocator, bq_id);
                i = ext.end;
                continue;
            }
            if (line_indent < indent) break; // defensive; callers should not slice across a dedent

            switch (self.classify(i, hi, indent)) {
                // The one early stop: `parseDocument` takes the title over,
                // since a section wraps everything after it.
                .title => break,
                .transition => {
                    const id = try self.b.addLeaf(.thematic_break);
                    self.b.setSpan(id, Span.init(self.lines[i].start, self.lines[i].end));
                    try children.append(self.allocator, id);
                    i += 1;
                },
                .comment => {
                    const cm = try self.parseComment(i, hi, indent);
                    try children.append(self.allocator, cm.id);
                    i = cm.next;
                },
                .bullet => |bm| {
                    const bl = try self.parseBulletList(i, hi, indent, bm.marker);
                    try children.append(self.allocator, bl.id);
                    i = bl.next;
                },
                .enumerator => |em| {
                    const el = try self.parseEnumeratedList(i, hi, indent, em);
                    try children.append(self.allocator, el.id);
                    i = el.next;
                },
                .field_marker => {
                    const fl = try self.parseFieldList(i, hi, indent);
                    try children.append(self.allocator, fl.id);
                    i = fl.next;
                },
                .definition_term => {
                    const dl = try self.parseDefinitionList(i, hi, indent);
                    try children.append(self.allocator, dl.id);
                    i = dl.next;
                },
                .paragraph => {
                    const para_end = self.findParagraphEnd(i, hi, indent);
                    const text = try self.assembleText(i, para_end, indent);
                    const str_id = try self.b.addLeaf(.{ .str = text });
                    self.allocator.free(text);
                    self.b.setSpan(str_id, Span.init(self.lines[i].start, self.lines[para_end - 1].end));
                    const para_id = try self.b.addContainer(.para, &.{str_id});
                    self.b.setSpan(para_id, Span.init(self.lines[i].start, self.lines[para_end - 1].end));
                    try children.append(self.allocator, para_id);
                    i = para_end;
                },
            }
        }
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = i };
    }

    /// What block line `i` opens, given that it is non-blank and sits at
    /// exactly `indent`. Docutils spells this as an ordered transition list on
    /// its `Body` state, and the ORDER is the content: a bullet beats a term,
    /// explicit markup beats both, and plain text is the last resort.
    ///
    /// It is a function rather than a chain inlined into `parseBody` because
    /// `parseDefinitionList` has to ask the identical question. A definition
    /// list continues only across lines that would otherwise have started a
    /// PARAGRAPH — which is docutils' `SpecializedBody` rule, where every
    /// transition except `text` aborts the specialized state and hands the
    /// line back to `Body`.
    fn classify(self: *const Parser, i: usize, hi: usize, indent: usize) BlockStart {
        // Titles are recognized only at document top level, never inside a
        // block quote's or a list item's recursive call, matching docutils (a
        // title indented inside a block quote is a parse error there, out of
        // this slice's scope).
        if (indent == 0) {
            if (self.matchTitle(i)) |tm| return .{ .title = tm };
        }
        const content = self.trimmedContent(i, indent);
        if (isTransitionLine(content)) return .transition;
        if (isCommentStart(content)) return .comment;
        if (matchBulletMarker(content)) |bm| return .{ .bullet = bm };
        // No overlap with the bullet check above: a bullet marker is one of
        // `-+*` or a Unicode bullet, while an enumerator starts with an
        // alphanumeric, `#` or `(`. Order between the two is therefore free.
        if (self.matchEnumeratorStart(i, hi, indent)) |em| return .{ .enumerator = em };
        if (matchFieldMarker(content) != null) return .field_marker;
        // A term is a line whose evidence is entirely BELOW it: docutils
        // reaches its `Text` state first and only then sees the indent. So a
        // line that looks like nothing else, followed immediately (no blank
        // line) by a deeper one, is a term over its definition.
        if (i + 1 < hi and !self.isBlankLine(i + 1) and self.leadingSpaces(i + 1) > indent) return .definition_term;
        return .paragraph;
    }

    fn findParagraphEnd(self: *const Parser, lo: usize, hi: usize, indent: usize) usize {
        var i = lo + 1;
        while (i < hi) {
            if (self.isBlankLine(i)) break;
            if (self.leadingSpaces(i) != indent) break;
            i += 1;
        }
        return i;
    }

    fn assembleText(self: *Parser, lo: usize, end_ex: usize, indent: usize) Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        var ln = lo;
        while (ln < end_ex) : (ln += 1) {
            if (ln > lo) try buf.append(self.allocator, '\n');
            const t = self.lineText(ln);
            const c = if (t.len > indent) t[indent..] else "";
            try buf.appendSlice(self.allocator, c);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// The maximal contiguous (blank-tolerant) run of lines from `lo`, each
    /// indented MORE than `above` — a block quote's raw extent — plus the
    /// minimum indent seen in it, which is the quote's OWN indent (its
    /// content is re-parsed dedented to that minimum, not to the first
    /// line's indent, so that a run mixing two indent depths becomes one
    /// quote with a nested quote inside it rather than two siblings; see the
    /// module doc comment's block-quote example).
    fn findElevatedExtent(self: *const Parser, lo: usize, hi: usize, above: usize) struct { end: usize, min_indent: usize } {
        var i = lo;
        var last_content_end = lo;
        var min_indent: usize = std.math.maxInt(usize);
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            const ind = self.leadingSpaces(i);
            if (ind <= above) break;
            if (ind < min_indent) min_indent = ind;
            i += 1;
            last_content_end = i;
        }
        return .{ .end = last_content_end, .min_indent = if (min_indent == std.math.maxInt(usize)) above + 1 else min_indent };
    }

    /// The run of lines from `lo`, each indented at least `min_indent`,
    /// stopping at the FIRST blank line — unlike `findElevatedExtent`, this
    /// is not blank-tolerant. An explicit markup construct's body (a
    /// comment's, here) is only what sits directly, contiguously under its
    /// marker; a blank line closes it (possibly leaving it empty) rather
    /// than merely pausing it, so that whatever indented content follows a
    /// blank line is free to be its own construct (e.g. a block quote) —
    /// pinned by the corpus's "prevents the following block quote being
    /// swallowed up" case.
    fn findContiguousIndentedRun(self: *const Parser, lo: usize, hi: usize, min_indent: usize) usize {
        var i = lo;
        while (i < hi and !self.isBlankLine(i) and self.leadingSpaces(i) >= min_indent) i += 1;
        return i;
    }

    fn parseComment(self: *Parser, i: usize, hi: usize, indent: usize) Allocator.Error!struct { id: Node.Id, next: usize } {
        const content = self.trimmedContent(i, indent);
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        var first = true;
        if (content.len > 2) {
            try text.appendSlice(self.allocator, content[3..]);
            first = false;
        }
        const body_col = indent + 3;
        const end = self.findContiguousIndentedRun(i + 1, hi, body_col);
        var ln = i + 1;
        while (ln < end) : (ln += 1) {
            const t = self.lineText(ln);
            const piece = if (t.len > body_col) t[body_col..] else "";
            if (!first) try text.append(self.allocator, '\n');
            try text.appendSlice(self.allocator, piece);
            first = false;
        }
        const comment_text = try text.toOwnedSlice(self.allocator);
        defer self.allocator.free(comment_text);
        const next = if (end > i + 1) end else i + 1;
        // A genuinely empty comment (bare `..` with no body at all) has no
        // `Text` child in docutils' doctree, and `doctree.zig`'s `soleStr`
        // requires exactly one to decode `Kind.markup_leaf` — a comment with
        // zero children instead decodes (and must therefore be built) as a
        // generic, childless `container`, or `encode` would write a spurious
        // blank text line `markup_leaf`'s payload always contributes one of.
        const id = if (comment_text.len == 0) blk: {
            const cid = try self.b.addLeaf(.{ .container = .{ .name = "comment" } });
            self.b.setSpelling(cid, .{ .container_origin = .directive });
            break :blk cid;
        } else try self.b.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = comment_text } });
        self.b.setSpan(id, Span.init(self.lines[i].start, self.lines[next - 1].end));
        // docutils marks every text-preserving element this way; it is a
        // fixed invariant of the construct, not a reading of anything in the
        // rST source, so it is set here rather than derived.
        try self.b.setAttrs(id, .{ .entries = &.{.{ .key = "xml:space", .value = "preserve" }} });
        return .{ .id = id, .next = next };
    }

    /// A maximal run of consecutive bullet-list items sharing `marker`, all
    /// at column `indent` — `lo` is the FIRST item's marker line, already
    /// matched by the caller (`parseBody`'s dispatch). A different-character
    /// marker at the same column ends the list without being consumed (the
    /// corpus's "different bullets" case makes each a separate `<bullet_list>`
    /// back to back, no intervening paragraph), which falls out for free here:
    /// the loop simply stops and hands the line back to `parseBody`, which
    /// dispatches it fresh and starts a new list.
    fn parseBulletList(self: *Parser, lo: usize, hi: usize, indent: usize, marker: []const u8) Allocator.Error!struct { id: Node.Id, next: usize } {
        var items: std.ArrayList(Node.Id) = .empty;
        errdefer items.deinit(self.allocator);
        var i = lo;
        var list_end = self.lines[lo].end;
        while (i < hi) {
            // Blank lines between items don't end the list — only reaching
            // `hi`, or a non-blank line that doesn't match `marker`, does.
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            const content = self.trimmedContent(i, indent);
            const bm = matchBulletMarker(content) orelse break;
            if (!std.mem.eql(u8, bm.marker, marker)) break;

            const it = try self.parseListItem(i, hi, indent, content, bm.rel_start, bm.has_content);
            try items.append(self.allocator, it.id);
            list_end = self.lines[it.next - 1].end;
            i = it.next;
        }

        const item_ids = try items.toOwnedSlice(self.allocator);
        const list_id = try self.b.addContainer(.{ .bullet_list = .{ .tight = false } }, item_ids);
        self.allocator.free(item_ids);
        self.b.setSpan(list_id, Span.init(self.lines[lo].start, list_end));
        try self.b.setAttrs(list_id, .{ .entries = &.{.{ .key = "bullet", .value = marker }} });
        return .{ .id = list_id, .next = i };
    }

    /// One `<list_item>`, shared by bullet and enumerated lists — the two
    /// differ only in how their marker is recognized, never in what follows
    /// it, which is docutils' own arrangement (a single `list_item` method
    /// serves both states).
    fn parseListItem(
        self: *Parser,
        item_line: usize,
        hi: usize,
        indent: usize,
        content: []const u8,
        rel_start: usize,
        has_content: bool,
    ) Allocator.Error!struct { id: Node.Id, next: usize } {
        const body = try self.parseMarkedBody(item_line, hi, indent, content, rel_start, has_content, .marker_width);
        defer self.allocator.free(body.items);
        const item_id = try self.b.addContainer(.list_item, body.items);
        self.b.setSpan(item_id, Span.init(self.lines[item_line].start, self.lines[body.stopped_at - 1].end));
        return .{ .id = item_id, .next = body.stopped_at };
    }

    /// Where a marked construct's body sits — docutils' choice between
    /// `get_known_indented` and `get_first_known_indented`. It is genuinely
    /// per-construct rather than a threshold, and the corpus is emphatic
    /// about it: `:Authors: Me,` continued at column 2 is ONE paragraph,
    /// while `- Me,` continued at column 2 is not.
    ///
    /// `marker_width` — a list item with text after its marker knows its
    /// column (that text's own), and a continuation line has to reach it.
    ///
    /// `own_minimum` — a field's body never knows its column: docutils takes
    /// the first line from the marker's remainder and the REST from their own
    /// minimum indent, however shallow. A marker with NOTHING after it falls
    /// here too whatever the construct, which is why `1.` over a
    /// one-space-indented `foo` is an item holding `foo` rather than an empty
    /// one (corpus: the enumerated-list "0/1/2/3-space indent" case walks all
    /// four widths).
    const ColumnRule = enum { marker_width, own_minimum };

    /// The blocks introduced by a MARKER line — one whose own remainder is the
    /// body's first line but which is not indented to the body's column in the
    /// source, the marker sitting where that indent would be.
    ///
    /// That remainder therefore can't go through `parseBody`/`findParagraphEnd`
    /// and is merged into a first paragraph by hand. The cost is that the
    /// remainder can only ever BE a paragraph: `:field1: :field2: body`, whose
    /// remainder is a nested field list, is out of reach until the parser can
    /// address a line from a column other than zero. That is the corpus's
    /// "Nested field lists on one line" case, and the one field-list failure
    /// that is not about inline markup.
    fn parseMarkedBody(
        self: *Parser,
        marker_line: usize,
        hi: usize,
        indent: usize,
        content: []const u8,
        rel_start: usize,
        has_content: bool,
        column: ColumnRule,
    ) Allocator.Error!BodyResult {
        var children: std.ArrayList(Node.Id) = .empty;
        errdefer children.deinit(self.allocator);

        const known_column = has_content and column == .marker_width;
        const content_col = indent + rel_start;
        const ext = self.findElevatedExtent(marker_line + 1, hi, if (known_column) content_col - 1 else indent);
        const body_col = if (known_column) content_col else ext.min_indent;

        var body_start = marker_line + 1;
        if (has_content) {
            // Merge in any immediately-following (no blank line between)
            // continuation at `body_col`, the same rule `findParagraphEnd`
            // uses for an ordinary paragraph.
            var para_end = marker_line + 1;
            while (para_end < ext.end and !self.isBlankLine(para_end) and self.leadingSpaces(para_end) == body_col) para_end += 1;

            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, content[rel_start..]);
            var ln = marker_line + 1;
            while (ln < para_end) : (ln += 1) {
                try buf.append(self.allocator, '\n');
                try buf.appendSlice(self.allocator, self.trimmedContent(ln, body_col));
            }
            const text = try buf.toOwnedSlice(self.allocator);
            const str_id = try self.b.addLeaf(.{ .str = text });
            self.allocator.free(text);
            self.b.setSpan(str_id, Span.init(self.lines[marker_line].start, self.lines[para_end - 1].end));
            const para_id = try self.b.addContainer(.para, &.{str_id});
            self.b.setSpan(para_id, Span.init(self.lines[marker_line].start, self.lines[para_end - 1].end));
            try children.append(self.allocator, para_id);
            body_start = para_end;
        }

        const rest = try self.parseBody(body_start, ext.end, body_col);
        defer self.allocator.free(rest.items);
        try children.appendSlice(self.allocator, rest.items);
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = rest.stopped_at };
    }

    // ── enumerated lists ────────────────────────────────────────────────

    /// Does line `i` START an enumerated list? Called from `parseBody`'s
    /// dispatch with no expected sequence, which is what lets `i.`/`I.` be
    /// read as roman rather than as the alphabetic letters they also are.
    fn matchEnumeratorStart(self: *const Parser, i: usize, hi: usize, indent: usize) ?EnumMatch {
        const em = matchEnumerator(self.trimmedContent(i, indent), null) orelse return null;
        if (!self.isEnumeratedListItem(i, hi, indent, em)) return null;
        return em;
    }

    /// docutils' `is_enumerated_list_item`, and the reason `1.` over an
    /// unindented `foo` is a two-line PARAGRAPH while `1.` over an indented
    /// one is a list: an enumerator alone proves nothing, so a second piece of
    /// evidence is required from the line below it — either that line is blank
    /// or indented (so the enumerator owns it), or it carries the NEXT
    /// enumerator in the sequence (so the two are siblings).
    ///
    /// The trailing space docutils puts on the enumerator it looks for is
    /// load-bearing and kept here: a bare `2.` under `1. foo` fails the test,
    /// because docutils rstrips every input line, so an enumerator with
    /// nothing after it can never match a `"2. "` prefix.
    fn isEnumeratedListItem(self: *const Parser, i: usize, hi: usize, indent: usize, em: EnumMatch) bool {
        const ordinal = em.ordinal orelse return false;
        // End of the enclosing block is docutils' EOFError arm: nothing below
        // to contradict the enumerator, so it stands.
        if (i + 1 >= hi) return true;
        if (self.isBlankLine(i + 1)) return true;
        if (self.leadingSpaces(i + 1) > indent) return true;

        const next = self.trimmedContent(i + 1, indent);
        var buf: [40]u8 = undefined;
        if (makeEnumerator(&buf, ordinal + 1, em.sequence, em.format)) |e| {
            if (std.mem.startsWith(u8, next, e)) return true;
        }
        // `#` may take over from a numbered enumerator at any point, so the
        // auto form is always an acceptable successor.
        if (makeEnumerator(&buf, 1, .auto, em.format)) |e| {
            if (std.mem.startsWith(u8, next, e)) return true;
        }
        return false;
    }

    /// A maximal run of enumerated items, `lo` being the first — already
    /// matched and validated by `matchEnumeratorStart`.
    ///
    /// What ends the list is docutils' `EnumeratedList.enumerator` test, and
    /// every clause of it earns its place in the corpus: a different FORMAT
    /// (`1.` then `1)`) starts a new list, a different SEQUENCE (`3.` then
    /// `A.`) starts a new list, and an ordinal that isn't the last plus one
    /// starts a new list — which is what keeps `C.` / `I.` apart as an
    /// upper-alpha list followed by an upper-roman one (`I` reads as ordinal
    /// 9 in the open list, and 9 != 4). Once `#` has appeared, `auto` bars
    /// any further explicit enumerator from continuing the same list.
    fn parseEnumeratedList(self: *Parser, lo: usize, hi: usize, indent: usize, first: EnumMatch) Allocator.Error!struct { id: Node.Id, next: usize } {
        var items: std.ArrayList(Node.Id) = .empty;
        errdefer items.deinit(self.allocator);

        // docutils writes `enumtype="arabic"` for a list that opens with `#`.
        const enumtype: Sequence = if (first.sequence == .auto) .arabic else first.sequence;
        var auto = first.sequence == .auto;
        var last_ordinal: u32 = first.ordinal.?;

        var i = lo;
        var list_end = self.lines[lo].end;
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            const content = self.trimmedContent(i, indent);
            const em = if (i == lo) first else blk: {
                const cand = matchEnumerator(content, enumtype) orelse break;
                if (cand.format != first.format) break;
                if (cand.sequence != .auto) {
                    if (auto or cand.sequence != enumtype) break;
                    const ord = cand.ordinal orelse break;
                    if (ord != last_ordinal + 1) break;
                }
                if (!self.isEnumeratedListItem(i, hi, indent, cand)) break;
                break :blk cand;
            };

            const it = try self.parseListItem(i, hi, indent, content, em.rel_start, em.has_content);
            try items.append(self.allocator, it.id);
            list_end = self.lines[it.next - 1].end;
            i = it.next;

            if (em.sequence == .auto) auto = true else last_ordinal = em.ordinal.?;
        }

        const item_ids = try items.toOwnedSlice(self.allocator);
        const list_id = try self.b.addContainer(.{ .ordered_list = .{
            .numbering = enumtype.numbering(),
            .tight = false,
            .start = if (first.ordinal.? != 1) first.ordinal.? else null,
        } }, item_ids);
        self.allocator.free(item_ids);
        self.b.setSpan(list_id, Span.init(self.lines[lo].start, list_end));

        // All four attributes are written even where the kind holds the same
        // fact, because `doctree.zig`'s encoder takes attributes from `attrs`
        // and only from `attrs` (see the comment on `writeNode`) — the payload
        // there is a reading, and this is the record it was read from.
        var start_buf: [12]u8 = undefined;
        const fi = first.format.info();
        var entries: [4]AST.KeyVal = undefined;
        entries[0] = .{ .key = "enumtype", .value = enumtype.doctreeName() };
        entries[1] = .{ .key = "prefix", .value = fi.prefix };
        entries[2] = .{ .key = "suffix", .value = fi.suffix };
        var n: usize = 3;
        if (first.ordinal.? != 1) {
            entries[3] = .{ .key = "start", .value = std.fmt.bufPrint(&start_buf, "{d}", .{first.ordinal.?}) catch unreachable };
            n = 4;
        }
        try self.b.setAttrs(list_id, .{ .entries = entries[0..n] });
        return .{ .id = list_id, .next = i };
    }

    // ── field lists ─────────────────────────────────────────────────────

    /// A maximal run of `:name: body` fields at `indent`.
    ///
    /// All four docutils elements stay GENERIC containers, and deliberately.
    /// The option-list absorption worked because a term holding an `<option>`
    /// is a total discriminator; a `<field_name>` holds ordinary text, so
    /// absorbing these four into the definition-list four would leave
    /// `encodeTag` no way to tell the three constructs apart on the way out.
    /// A generic container names its own element and round-trips exactly, so
    /// the corpus is served with no vocabulary committed to a construct only
    /// rST has and no serializer handed a node it cannot spell.
    fn parseFieldList(self: *Parser, lo: usize, hi: usize, indent: usize) Allocator.Error!struct { id: Node.Id, next: usize } {
        var fields: std.ArrayList(Node.Id) = .empty;
        errdefer fields.deinit(self.allocator);
        var i = lo;
        var list_end = self.lines[lo].end;
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            if (self.leadingSpaces(i) != indent) break;
            const content = self.trimmedContent(i, indent);
            const fm = matchFieldMarker(content) orelse break;

            const marker_span = Span.init(self.lines[i].start, self.lines[i].end);
            const name_str = try self.b.addLeaf(.{ .str = fm.name });
            self.b.setSpan(name_str, marker_span);
            const name_id = try self.b.addContainer(.{ .container = .{ .name = "field_name" } }, &.{name_str});
            self.b.setSpelling(name_id, .{ .container_origin = .directive });
            self.b.setSpan(name_id, marker_span);

            const body = try self.parseMarkedBody(i, hi, indent, content, fm.rel_start, fm.has_content, .own_minimum);
            defer self.allocator.free(body.items);
            // docutils appends the `field_body` unconditionally, so a field
            // with nothing after its marker still has an (empty) one.
            const body_id = try self.b.addContainer(.{ .container = .{ .name = "field_body" } }, body.items);
            self.b.setSpelling(body_id, .{ .container_origin = .directive });
            self.b.setSpan(body_id, Span.init(self.lines[i].start, self.lines[body.stopped_at - 1].end));

            const field_id = try self.b.addContainer(.{ .container = .{ .name = "field" } }, &.{ name_id, body_id });
            self.b.setSpelling(field_id, .{ .container_origin = .directive });
            self.b.setSpan(field_id, Span.init(self.lines[i].start, self.lines[body.stopped_at - 1].end));
            try fields.append(self.allocator, field_id);

            list_end = self.lines[body.stopped_at - 1].end;
            i = body.stopped_at;
        }

        const field_ids = try fields.toOwnedSlice(self.allocator);
        const list_id = try self.b.addContainer(.{ .container = .{ .name = "field_list" } }, field_ids);
        self.b.setSpelling(list_id, .{ .container_origin = .directive });
        self.allocator.free(field_ids);
        self.b.setSpan(list_id, Span.init(self.lines[lo].start, list_end));
        return .{ .id = list_id, .next = i };
    }

    // ── definition lists ────────────────────────────────────────────────

    /// A maximal run of `term` / indented-`definition` pairs at `indent`.
    ///
    /// The definition's extent is `findElevatedExtent` — blank-tolerant, and
    /// dedented to the run's own minimum, exactly a block quote's — which is
    /// what makes a definition list nested inside a definition fall out for
    /// free: the corpus's `term 1a` sits two columns in, so it is simply part
    /// of `definition 1`'s block and gets classified afresh down there.
    ///
    /// The list continues only while `classify` keeps answering
    /// `definition_term`; a bullet, an enumerator, explicit markup or a term
    /// with nothing indented under it all end it, and `parseBody` then sees
    /// that line fresh. That is docutils' `SpecializedBody.invalid_input`.
    fn parseDefinitionList(self: *Parser, lo: usize, hi: usize, indent: usize) Allocator.Error!struct { id: Node.Id, next: usize } {
        var items: std.ArrayList(Node.Id) = .empty;
        errdefer items.deinit(self.allocator);
        var i = lo;
        var list_end = self.lines[lo].end;
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            if (self.leadingSpaces(i) != indent) break;
            if (i != lo and self.classify(i, hi, indent) != .definition_term) break;

            const term_line = i;
            const term_span = Span.init(self.lines[term_line].start, self.lines[term_line].end);
            var item_children: std.ArrayList(Node.Id) = .empty;
            errdefer item_children.deinit(self.allocator);

            var parts = TermParts{ .line = self.trimmedContent(term_line, indent) };
            const term_text = parts.next().?;
            const term_str = try self.b.addLeaf(.{ .str = term_text });
            self.b.setSpan(term_str, term_span);
            const term_id = try self.b.addContainer(.term, &.{term_str});
            self.b.setSpan(term_id, term_span);
            try item_children.append(self.allocator, term_id);
            while (parts.next()) |classifier| {
                const c_str = try self.b.addLeaf(.{ .str = classifier });
                self.b.setSpan(c_str, term_span);
                const c_id = try self.b.addContainer(.{ .container = .{ .name = "classifier" } }, &.{c_str});
                self.b.setSpelling(c_id, .{ .container_origin = .directive });
                self.b.setSpan(c_id, term_span);
                try item_children.append(self.allocator, c_id);
            }

            const ext = self.findElevatedExtent(term_line + 1, hi, indent);
            const body = try self.parseBody(term_line + 1, ext.end, ext.min_indent);
            defer self.allocator.free(body.items);
            const def_id = try self.b.addContainer(.definition, body.items);
            self.b.setSpan(def_id, Span.init(self.lines[term_line + 1].start, self.lines[ext.end - 1].end));
            try item_children.append(self.allocator, def_id);

            const parts_ids = try item_children.toOwnedSlice(self.allocator);
            const item_id = try self.b.addContainer(.definition_list_item, parts_ids);
            self.allocator.free(parts_ids);
            self.b.setSpan(item_id, Span.init(self.lines[term_line].start, self.lines[ext.end - 1].end));
            try items.append(self.allocator, item_id);

            list_end = self.lines[ext.end - 1].end;
            i = ext.end;
        }

        const item_ids = try items.toOwnedSlice(self.allocator);
        const list_id = try self.b.addContainer(.definition_list, item_ids);
        self.allocator.free(item_ids);
        self.b.setSpan(list_id, Span.init(self.lines[lo].start, list_end));
        return .{ .id = list_id, .next = i };
    }
};

/// A term line split on docutils' `classifier_delimiter`, ` +: +`. The first
/// piece is the term; every later one is a `<classifier>`. Always yields at
/// least one piece, so the first `next()` never returns null.
///
/// A backslash-escaped colon needs no special handling, and pleasingly so:
/// docutils avoids splitting `Term \: x` because its inline pass has already
/// replaced the backslash with a null byte, leaving no SPACE immediately
/// before the colon — and requiring that space verbatim, as here, reaches the
/// same answer without an escape pass existing yet. What is still missing is
/// the other half, removing the backslash from the term's text; that belongs
/// to the inline pass with every other escape, so the corpus's "escaped
/// colon" case stays one item short.
const TermParts = struct {
    line: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn next(self: *TermParts) ?[]const u8 {
        if (self.done) return null;
        var k = self.pos;
        while (k < self.line.len) : (k += 1) {
            if (self.line[k] != ':') continue;
            if (k == 0 or self.line[k - 1] != ' ') continue;
            if (k + 1 >= self.line.len or self.line[k + 1] != ' ') continue;
            var start = k;
            while (start > self.pos and self.line[start - 1] == ' ') start -= 1;
            var end = k + 1;
            while (end < self.line.len and self.line[end] == ' ') end += 1;
            const piece = self.line[self.pos..start];
            self.pos = end;
            return piece;
        }
        self.done = true;
        return self.line[self.pos..];
    }
};

fn computeLines(allocator: Allocator, source: []const u8) Allocator.Error![]LineInfo {
    var list: std.ArrayList(LineInfo) = .empty;
    errdefer list.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            try list.append(allocator, .{ .start = start, .end = i });
            start = i + 1;
        }
    }
    try list.append(allocator, .{ .start = start, .end = source.len });
    return list.toOwnedSlice(allocator);
}

fn utf8SeqLen(byte0: u8) usize {
    if (byte0 & 0xE0 == 0xC0) return 2;
    if (byte0 & 0xF0 == 0xE0) return 3;
    if (byte0 & 0xF8 == 0xF0) return 4;
    return 1;
}

/// docutils' adornment character set for section titles/transitions — ASCII
/// punctuation. (docutils additionally accepts a range of Unicode punctuation;
/// out of scope for this ASCII-only slice.)
const adornment_chars = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

fn isAdornmentChar(c: u8) bool {
    return std.mem.indexOfScalar(u8, adornment_chars, c) != null;
}

/// A line consisting of one repeated adornment character, with no minimum
/// length — a title's underline can be as short as one character (docutils
/// merely WARNS "underline too short", it doesn't refuse to parse). A
/// standalone TRANSITION additionally requires 4+ (see `isTransitionLine`);
/// the corpus's "Short transition marker" case pins that a 3-character run on
/// its own is plain text, not a transition.
fn isAdornmentLine(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!isAdornmentChar(s[0])) return false;
    for (s) |c| {
        if (c != s[0]) return false;
    }
    return true;
}

fn isTransitionLine(s: []const u8) bool {
    return s.len >= 4 and isAdornmentLine(s);
}

/// `..` alone, or `..` followed by a space — docutils' explicit markup start.
/// Every explicit-markup construct this slice doesn't yet parse (directives,
/// targets, footnotes, citations, substitution definitions) therefore falls
/// back to a comment, which is docutils' own fallback for markup it doesn't
/// recognize either.
fn isCommentStart(content: []const u8) bool {
    if (content.len < 2 or content[0] != '.' or content[1] != '.') return false;
    return content.len == 2 or content[2] == ' ';
}

/// Byte length of a bullet-list marker character at the start of `s`, or
/// `null` if `s` doesn't start with one. docutils' bullet set is `-+*` plus
/// three Unicode marks (corpus-pinned by the "Unicode bullets" case): BULLET
/// U+2022 `•`, TRIANGULAR BULLET U+2023 `‣`, HYPHEN BULLET U+2043 `⁃` — all
/// three encode to 3 UTF-8 bytes starting `0xE2`.
fn bulletMarkerLen(s: []const u8) ?usize {
    if (s.len == 0) return null;
    if (s[0] == '-' or s[0] == '*' or s[0] == '+') return 1;
    if (s.len >= 3 and s[0] == 0xE2) {
        if (s[1] == 0x80 and (s[2] == 0xA2 or s[2] == 0xA3)) return 3; // • ‣
        if (s[1] == 0x81 and s[2] == 0x83) return 3; // ⁃
    }
    return null;
}

const BulletMatch = struct {
    marker: []const u8,
    /// Byte offset within `content` (already indent-stripped and
    /// trailing-trimmed by `trimmedContent`) where the item's own text
    /// starts. Only read when `has_content`: an empty item's column comes
    /// from the lines below it instead — see `parseListItem`.
    rel_start: usize,
    has_content: bool,
};

/// A bullet marker: one marker character, then either end-of-content or a
/// space and more text. `content` has already had trailing whitespace
/// trimmed (`trimmedContent`), so "a space with nothing real after it" and
/// "nothing after it at all" collapse to the same `has_content = false` case.
fn matchBulletMarker(content: []const u8) ?BulletMatch {
    const mlen = bulletMarkerLen(content) orelse return null;
    if (content.len == mlen) return .{ .marker = content[0..mlen], .rel_start = mlen + 1, .has_content = false };
    if (content[mlen] != ' ') return null;
    var k = mlen;
    while (k < content.len and content[k] == ' ') k += 1;
    if (k == content.len) return .{ .marker = content[0..mlen], .rel_start = mlen + 1, .has_content = false };
    return .{ .marker = content[0..mlen], .rel_start = k, .has_content = true };
}

const FieldMatch = struct {
    /// The name between the colons, verbatim — escapes NOT removed, since
    /// docutils removes those in `inline_text` and this parser has no inline
    /// pass yet.
    name: []const u8,
    /// Byte offset within the indent-stripped line where the body's first
    /// line starts, mirroring `BulletMatch.rel_start`.
    rel_start: usize,
    has_content: bool,
};

/// docutils' `field_marker` pattern:
///
///     :(?![: ])([^:\\]|\\.|:(?!([ `]|$)))*(?<! ):( +|$)
///
/// which is a left-to-right scan once its backtracking is unwound. The name
/// may not contain a colon followed by a space, a backtick, or the end of the
/// line, so no colon after the first such one could ever close the name: the
/// closer is simply the FIRST colon followed by a space or the line's end, and
/// a colon followed by a backtick before that point kills the match outright.
/// That last clause is what keeps `:code:`not a field name`: text` a plain
/// paragraph, which the corpus tests directly.
fn matchFieldMarker(content: []const u8) ?FieldMatch {
    // `:(?![: ])`: `::` opens a literal block and `: ` is just text.
    if (content.len < 2 or content[0] != ':') return null;
    if (content[1] == ':' or content[1] == ' ') return null;

    var k: usize = 1;
    while (k < content.len) {
        if (content[k] == '\\') {
            // `\\.` — a backslash takes the next character with it, whatever
            // it is, so an escaped colon can neither close nor break a name.
            k += 2;
            continue;
        }
        if (content[k] != ':') {
            k += 1;
            continue;
        }
        const after: ?u8 = if (k + 1 < content.len) content[k + 1] else null;
        if (after != null and after.? != ' ' and after.? != '`') {
            k += 1;
            continue;
        }
        // `(?<! )` — a name may not end in a space, and a colon that neither
        // closes nor belongs to the name ends the whole match.
        if (after != null and after.? == '`') return null;
        if (content[k - 1] == ' ') return null;
        const name = content[1..k];
        if (name.len == 0) return null;
        var rest = k + 1;
        while (rest < content.len and content[rest] == ' ') rest += 1;
        // `content` is trailing-trimmed, so "spaces then nothing" is the same
        // as "nothing", and both mean the body starts on the next line.
        return .{ .name = name, .rel_start = rest, .has_content = rest < content.len };
    }
    return null;
}

// ── enumerators ──────────────────────────────────────────────────────────
//
// docutils spells all of this as one regex plus `parse_enumerator`; it is
// unrolled here because the pieces are needed separately — `makeEnumerator`
// runs the same table BACKWARDS to synthesize the successor enumerator
// `isEnumeratedListItem` looks for.

/// How an enumerator is punctuated. Three forms, and they are part of a list's
/// identity: `1.` and `1)` never continue each other.
const Format = enum {
    parens,
    rparen,
    period,

    fn info(self: Format) struct { prefix: []const u8, suffix: []const u8 } {
        return switch (self) {
            .parens => .{ .prefix = "(", .suffix = ")" },
            .rparen => .{ .prefix = "", .suffix = ")" },
            .period => .{ .prefix = "", .suffix = "." },
        };
    }
};

/// The counting system an enumerator is written in. `auto` is rST's `#`, which
/// has no sequence of its own — it continues whatever list it lands in, and a
/// list that OPENS with it is recorded as arabic.
const Sequence = enum {
    arabic,
    loweralpha,
    upperalpha,
    lowerroman,
    upperroman,
    auto,

    /// Every candidate `parse_enumerator`'s fallback loop tries, in docutils'
    /// order — which matters, since `[a-z]` and `[ivxlcdm]+` both accept `i`.
    const ordered = [_]Sequence{ .arabic, .loweralpha, .upperalpha, .lowerroman, .upperroman };

    fn doctreeName(self: Sequence) []const u8 {
        return switch (self) {
            .arabic, .auto => "arabic",
            .loweralpha => "loweralpha",
            .upperalpha => "upperalpha",
            .lowerroman => "lowerroman",
            .upperroman => "upperroman",
        };
    }

    fn numbering(self: Sequence) AST.ListNumbering {
        return switch (self) {
            .arabic, .auto => .decimal,
            .loweralpha => .lower_alpha,
            .upperalpha => .upper_alpha,
            .lowerroman => .lower_roman,
            .upperroman => .upper_roman,
        };
    }

    /// docutils' `sequenceregexps` — a CHARACTER-SET test only. Roman validity
    /// is deliberately not checked here: `iiii` is a well-formed lowerroman
    /// enumerator whose ORDINAL is undefined, and that distinction is what
    /// makes `iiii. iiii` fall out of the list and into a definition list
    /// rather than being rejected as unrecognized text.
    fn accepts(self: Sequence, text: []const u8) bool {
        return switch (self) {
            .auto => std.mem.eql(u8, text, "#"),
            .arabic => allOf(text, std.ascii.isDigit),
            .loweralpha => text.len == 1 and text[0] >= 'a' and text[0] <= 'z',
            .upperalpha => text.len == 1 and text[0] >= 'A' and text[0] <= 'Z',
            .lowerroman => allOf(text, isLowerRomanDigit),
            .upperroman => allOf(text, isUpperRomanDigit),
        };
    }
};

fn allOf(text: []const u8, pred: fn (u8) bool) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!pred(c)) return false;
    }
    return true;
}

fn isLowerRomanDigit(c: u8) bool {
    return std.mem.indexOfScalar(u8, "ivxlcdm", c) != null;
}

fn isUpperRomanDigit(c: u8) bool {
    return std.mem.indexOfScalar(u8, "IVXLCDM", c) != null;
}

const EnumMatch = struct {
    format: Format,
    sequence: Sequence,
    /// `null` when the enumerator is well-formed but names no number — the
    /// only source is a roman numeral that isn't one (`iiii`, `LCD`).
    ordinal: ?u32,
    /// Byte offset within the indent-stripped line where the item's own text
    /// starts, mirroring `BulletMatch.rel_start`.
    rel_start: usize,
    has_content: bool,
};

/// Split `content` into an enumerator and its remainder, or `null` when it
/// doesn't open with one. This is docutils' `enumerator` regex: an optional
/// `(`, a run of enumerator characters, a `)` or `.`, then a space or the end
/// of the line.
///
/// Scanning to the punctuation instead of alternating over the five sequence
/// patterns is equivalent because none of the five accepts `.` or `)`, so the
/// regex's backtracking has exactly one place to stop; `accepts` then does the
/// validation the alternation would have done.
fn matchEnumerator(content: []const u8, expected: ?Sequence) ?EnumMatch {
    if (content.len == 0) return null;
    const parens = content[0] == '(';
    const text_start: usize = if (parens) 1 else 0;
    var k = text_start;
    while (k < content.len and (std.ascii.isAlphanumeric(content[k]) or content[k] == '#')) k += 1;
    if (k == text_start or k >= content.len) return null;
    const format: Format = if (parens)
        (if (content[k] == ')') .parens else return null)
    else if (content[k] == ')')
        .rparen
    else if (content[k] == '.')
        .period
    else
        return null;

    const text = content[text_start..k];
    const sequence = resolveSequence(text, expected) orelse return null;

    var rest = k + 1;
    if (rest == content.len) {
        return .{ .format = format, .sequence = sequence, .ordinal = ordinalOf(text, sequence), .rel_start = rest + 1, .has_content = false };
    }
    if (content[rest] != ' ') return null;
    while (rest < content.len and content[rest] == ' ') rest += 1;
    // `content` is already trailing-trimmed, so "spaces then nothing" cannot
    // occur; a marker line ending in whitespace arrives here as the case above.
    return .{ .format = format, .sequence = sequence, .ordinal = ordinalOf(text, sequence), .rel_start = rest, .has_content = true };
}

/// docutils' `parse_enumerator` sequence resolution. `expected` is the open
/// list's `enumtype` when there is one, and giving it priority is what lets a
/// loweralpha list absorb `i` as its ninth item instead of restarting as roman.
///
/// The `i`/`I` special case applies ONLY when there is no expectation — a bare
/// `i.` opens a lowerroman list even though `[a-z]` would accept it first.
fn resolveSequence(text: []const u8, expected: ?Sequence) ?Sequence {
    if (std.mem.eql(u8, text, "#")) return .auto;
    if (expected) |e| {
        if (e.accepts(text)) return e;
    } else {
        if (std.mem.eql(u8, text, "i")) return .lowerroman;
        if (std.mem.eql(u8, text, "I")) return .upperroman;
    }
    for (Sequence.ordered) |s| {
        if (s.accepts(text)) return s;
    }
    // Reachable where docutils' version is not: the scan above accepts any
    // alphanumeric run, so `1a.` gets here and is correctly not an enumerator.
    return null;
}

fn ordinalOf(text: []const u8, sequence: Sequence) ?u32 {
    return switch (sequence) {
        .auto => 1,
        .arabic => std.fmt.parseInt(u32, text, 10) catch null,
        .loweralpha => text[0] - 'a' + 1,
        .upperalpha => text[0] - 'A' + 1,
        .lowerroman, .upperroman => fromRoman(text),
    };
}

/// The enumerator that would follow `ordinal - 1` in this sequence and format,
/// with docutils' trailing space, written into `buf`. `null` for an ordinal the
/// sequence cannot spell (past `z`, or outside roman's 1..4999).
fn makeEnumerator(buf: []u8, ordinal: u32, sequence: Sequence, format: Format) ?[]const u8 {
    var body_buf: [16]u8 = undefined;
    const body: []const u8 = switch (sequence) {
        .auto => "#",
        .arabic => std.fmt.bufPrint(&body_buf, "{d}", .{ordinal}) catch return null,
        .loweralpha, .upperalpha => blk: {
            if (ordinal == 0 or ordinal > 26) return null;
            const base: u8 = if (sequence == .loweralpha) 'a' else 'A';
            body_buf[0] = base + @as(u8, @intCast(ordinal - 1));
            break :blk body_buf[0..1];
        },
        .lowerroman, .upperroman => blk: {
            const roman = toRoman(&body_buf, ordinal) orelse return null;
            if (sequence == .lowerroman) {
                for (roman) |*c| c.* = std.ascii.toLower(c.*);
            }
            break :blk roman;
        },
    };
    const fi = format.info();
    return std.fmt.bufPrint(buf, "{s}{s}{s} ", .{ fi.prefix, body, fi.suffix }) catch null;
}

const roman_values = [_]u32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
const roman_symbols = [_][]const u8{ "M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I" };

fn toRoman(buf: []u8, n: u32) ?[]u8 {
    // docutils' `roman.toRoman` range; `M{0,4}`-through-`IX` is 4999.
    if (n == 0 or n > 4999) return null;
    var rem = n;
    var len: usize = 0;
    for (roman_values, roman_symbols) |v, s| {
        while (rem >= v) : (rem -= v) {
            @memcpy(buf[len..][0..s.len], s);
            len += s.len;
        }
    }
    return buf[0..len];
}

/// docutils' `roman.fromRoman`, whose validity rule is a regex accepting only
/// the CANONICAL spelling of each number. Rather than transcribe the regex,
/// this evaluates the numeral by the ordinary subtractive rule and then checks
/// that `toRoman` writes it back the same way — the two are equivalent, since
/// the regex describes exactly `toRoman`'s output.
///
/// This is what separates `iii` (a third list item) from `iiii` (not a numeral,
/// so not an enumerator, so the start of a definition list).
fn fromRoman(text: []const u8) ?u32 {
    var total: i64 = 0;
    for (text, 0..) |c, k| {
        const v = romanDigit(c) orelse return null;
        const next: u32 = if (k + 1 < text.len) (romanDigit(text[k + 1]) orelse return null) else 0;
        total += if (v < next) -@as(i64, v) else @as(i64, v);
    }
    if (total < 1 or total > 4999) return null;
    const n: u32 = @intCast(total);
    var buf: [16]u8 = undefined;
    const canonical = toRoman(&buf, n) orelse return null;
    if (canonical.len != text.len) return null;
    for (canonical, text) |a, b| {
        if (a != std.ascii.toUpper(b)) return null;
    }
    return n;
}

fn romanDigit(c: u8) ?u32 {
    return switch (std.ascii.toUpper(c)) {
        'I' => 1,
        'V' => 5,
        'X' => 10,
        'L' => 50,
        'C' => 100,
        'D' => 500,
        'M' => 1000,
        else => null,
    };
}

const testing = std.testing;

test "a single paragraph" {
    var result = try parse(testing.allocator, "Hello world.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    try testing.expect(ast.nodes[ast.root].kind == .doc);
    const para = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[para].kind == .para);
    const str = ast.nodes[para].first_child.?;
    try testing.expectEqualStrings("Hello world.", ast.nodes[str].kind.str);
}

test "a section wraps its title and body" {
    var result = try parse(testing.allocator, "Title\n=====\n\nBody.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const section = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[section].kind == .section);
    try testing.expectEqualStrings("title", ast.attrsOf(section).get("ids").?);
    try testing.expectEqualStrings("title", ast.attrsOf(section).get("names").?);
    const title = ast.nodes[section].first_child.?;
    try testing.expectEqualStrings("title", ast.nodes[title].kind.container.name);
    const body = ast.nodes[title].next_sibling.?;
    try testing.expect(ast.nodes[body].kind == .para);
}

test "reused adornment style nests a subsection, a new style stays deeper" {
    var result = try parse(testing.allocator,
        \\Section 1
        \\=========
        \\
        \\Section 2
        \\---------
        \\Paragraph.
        \\
    , .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const sec1 = ast.nodes[ast.root].first_child.?;
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[sec1].next_sibling);
    const title1 = ast.nodes[sec1].first_child.?;
    const sec2 = ast.nodes[title1].next_sibling.?;
    try testing.expect(ast.nodes[sec2].kind == .section);
    try testing.expectEqualStrings("section-2", ast.attrsOf(sec2).get("ids").?);
}

test "a transition needs 4+ adornment characters" {
    var result = try parse(testing.allocator, "Short.\n\n---\n\nPara.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const first = ast.nodes[ast.root].first_child.?;
    const second = ast.nodes[first].next_sibling.?;
    // "---" (3 chars) is plain text, not a <transition>.
    try testing.expect(ast.nodes[second].kind == .para);
}

test "a block quote dedents to the run's minimum indent, nesting deeper runs" {
    var result = try parse(testing.allocator, "Para.\n\n        Eight.\n\n    Four.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const para = ast.nodes[ast.root].first_child.?;
    const bq = ast.nodes[para].next_sibling.?;
    try testing.expect(ast.nodes[bq].kind == .block_quote);
    const nested_bq = ast.nodes[bq].first_child.?;
    try testing.expect(ast.nodes[nested_bq].kind == .block_quote);
    const four = ast.nodes[nested_bq].next_sibling.?;
    try testing.expect(ast.nodes[four].kind == .para);
}

test "a comment absorbs its indented continuation" {
    var result = try parse(testing.allocator, ".. A comment\n   block.\n\nPara.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const comment = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("A comment\nblock.", ast.nodes[comment].kind.markup_leaf.text);
}

test "a bullet list item merges its marker line with its unindented continuation" {
    var result = try parse(testing.allocator, "- item 1, line 1\n  item 1, line 2\n- item 2\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind.bullet_list.tight == false);
    try testing.expectEqualStrings("-", ast.attrsOf(list).get("bullet").?);
    const item1 = ast.nodes[list].first_child.?;
    const para1 = ast.nodes[item1].first_child.?;
    try testing.expectEqualStrings("item 1, line 1\nitem 1, line 2", ast.nodes[ast.nodes[para1].first_child.?].kind.str);
    const item2 = ast.nodes[item1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[item2].next_sibling);
}

test "an empty bullet list item has no children, and a dedented line after it is a sibling" {
    var result = try parse(testing.allocator, "-\n\nempty item above\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    const item = ast.nodes[list].first_child.?;
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[item].first_child);
    const after = ast.nodes[list].next_sibling.?;
    try testing.expect(ast.nodes[after].kind == .para);
}

test "an enumerated list records enumtype, prefix and suffix" {
    var result = try parse(testing.allocator, "(a) Item a.\n(b) Item b.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind.ordered_list.numbering == .lower_alpha);
    try testing.expectEqual(@as(?u32, null), ast.nodes[list].kind.ordered_list.start);
    try testing.expectEqualStrings("loweralpha", ast.attrsOf(list).get("enumtype").?);
    try testing.expectEqualStrings("(", ast.attrsOf(list).get("prefix").?);
    try testing.expectEqualStrings(")", ast.attrsOf(list).get("suffix").?);
    try testing.expectEqual(@as(?[]const u8, null), ast.attrsOf(list).get("start"));
    const item = ast.nodes[list].first_child.?;
    try testing.expect(ast.nodes[ast.nodes[item].next_sibling.?].next_sibling == null);
}

test "a first enumerator that is not ordinal-1 sets start" {
    var result = try parse(testing.allocator, "3. Item three.\n4. Item four.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expectEqual(@as(?u32, 3), ast.nodes[list].kind.ordered_list.start);
    try testing.expectEqualStrings("3", ast.attrsOf(list).get("start").?);
}

test "a bare enumerator over an unindented line is a paragraph, over an indented one a list" {
    // docutils' `is_enumerated_list_item`: the line below is the only evidence
    // that `1.` is a marker rather than the first word of a sentence.
    {
        var result = try parse(testing.allocator, "1.\nempty item above, no blank line\n", .{});
        defer result.deinit(testing.allocator);
        const ast = result.document.ast;
        const first = ast.nodes[ast.root].first_child.?;
        try testing.expect(ast.nodes[first].kind == .para);
        try testing.expectEqualStrings("1.\nempty item above, no blank line", ast.nodes[ast.nodes[first].first_child.?].kind.str);
    }
    {
        // One space is enough, and the item's content column is that one
        // space — not the three the enumerator's width would reserve.
        var result = try parse(testing.allocator, "1.\n foo\n", .{});
        defer result.deinit(testing.allocator);
        const ast = result.document.ast;
        const list = ast.nodes[ast.root].first_child.?;
        try testing.expect(ast.nodes[list].kind == .ordered_list);
        const item = ast.nodes[list].first_child.?;
        const para = ast.nodes[item].first_child.?;
        try testing.expectEqualStrings("foo", ast.nodes[ast.nodes[para].first_child.?].kind.str);
    }
}

test "an ambiguous alpha/roman enumerator splits the list on the ordinal, not the letter" {
    // `I` continues an open upperalpha list only when it is the NEXT ordinal.
    // After `C.` (3) it reads as 9, so it opens an upperroman list instead —
    // the corpus's "Potentially ambiguous cases".
    var result = try parse(testing.allocator, "A. Item A.\nB. Item B.\nC. Item C.\n\nI. Item I.\nII. Item II.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const alpha = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[alpha].kind.ordered_list.numbering == .upper_alpha);
    const roman = ast.nodes[alpha].next_sibling.?;
    try testing.expect(ast.nodes[roman].kind.ordered_list.numbering == .upper_roman);
    try testing.expectEqual(@as(?u32, null), ast.nodes[roman].kind.ordered_list.start);
}

test "`#` continues whatever list it lands in and reports that list's own enumtype" {
    var result = try parse(testing.allocator, "i. Item one.\nii. Item two.\n#. Item three.\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("lowerroman", ast.attrsOf(list).get("enumtype").?);
    var count: usize = 0;
    var child = ast.nodes[list].first_child;
    while (child) |c| : (child = ast.nodes[c].next_sibling) count += 1;
    try testing.expectEqual(@as(usize, 3), count);
}

test "a malformed roman numeral is not an enumerator at all" {
    // `iiii` fails docutils' canonical-spelling rule, so this is prose. Same
    // reason `(LCD) is an acronym...` stays a paragraph.
    var result = try parse(testing.allocator, "iiii. iiii\n\n(LCD) is an acronym\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const first = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[first].kind == .para);
    const second = ast.nodes[first].next_sibling.?;
    try testing.expect(ast.nodes[second].kind == .para);
}

test "a different enumerator format ends the list" {
    var result = try parse(testing.allocator, "1. Item 1.\n\n1) Item 1).\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const first = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings(".", ast.attrsOf(first).get("suffix").?);
    const second = ast.nodes[first].next_sibling.?;
    try testing.expect(ast.nodes[second].kind == .ordered_list);
    try testing.expectEqualStrings(")", ast.attrsOf(second).get("suffix").?);
}

test "a term over an indented line makes a definition list, and a nested one nests" {
    var result = try parse(testing.allocator,
        \\term 1
        \\  definition 1
        \\
        \\  term 1a
        \\    definition 1a
        \\
        \\term 2
        \\  definition 2
        \\
    , .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind == .definition_list);

    const item1 = ast.nodes[list].first_child.?;
    const term1 = ast.nodes[item1].first_child.?;
    try testing.expect(ast.nodes[term1].kind == .term);
    try testing.expectEqualStrings("term 1", ast.nodes[ast.nodes[term1].first_child.?].kind.str);

    // The nested list is inside definition 1's own block, not a sibling: it
    // is simply indented content that `classify` met again further down.
    const def1 = ast.nodes[term1].next_sibling.?;
    try testing.expect(ast.nodes[def1].kind == .definition);
    const nested = ast.nodes[ast.nodes[def1].first_child.?].next_sibling.?;
    try testing.expect(ast.nodes[nested].kind == .definition_list);

    const item2 = ast.nodes[item1].next_sibling.?;
    try testing.expect(ast.nodes[item2].kind == .definition_list_item);
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[item2].next_sibling);
}

test "items with no blank line between them stay one definition list" {
    var result = try parse(testing.allocator, "term 1\n  definition 1\nterm 2\n  definition 2\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[list].next_sibling);
    const item1 = ast.nodes[list].first_child.?;
    try testing.expect(ast.nodes[item1].next_sibling != null);
}

test "` : ` splits a term into classifiers, and only with a space on both sides" {
    var result = try parse(testing.allocator,
        \\Term : one : two
        \\    definition
        \\Term: not a classifier
        \\    definition
        \\Term :not a classifier
        \\    definition
        \\
    , .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;

    const item1 = ast.nodes[list].first_child.?;
    const term = ast.nodes[item1].first_child.?;
    try testing.expectEqualStrings("Term", ast.nodes[ast.nodes[term].first_child.?].kind.str);
    const c1 = ast.nodes[term].next_sibling.?;
    try testing.expectEqualStrings("classifier", ast.nodes[c1].kind.container.name);
    try testing.expectEqualStrings("one", ast.nodes[ast.nodes[c1].first_child.?].kind.str);
    const c2 = ast.nodes[c1].next_sibling.?;
    try testing.expectEqualStrings("two", ast.nodes[ast.nodes[c2].first_child.?].kind.str);
    try testing.expect(ast.nodes[ast.nodes[c2].next_sibling.?].kind == .definition);

    for ([_]?Node.Id{ ast.nodes[item1].next_sibling, ast.nodes[ast.nodes[item1].next_sibling.?].next_sibling }, 0..) |maybe, k| {
        const item = maybe.?;
        const t = ast.nodes[item].first_child.?;
        // No classifier: the definition follows the term directly.
        try testing.expect(ast.nodes[ast.nodes[t].next_sibling.?].kind == .definition);
        const want: []const u8 = if (k == 0) "Term: not a classifier" else "Term :not a classifier";
        try testing.expectEqualStrings(want, ast.nodes[ast.nodes[t].first_child.?].kind.str);
    }
}

test "an escaped colon does not split a term" {
    // The backslash itself survives, which is the documented inline-pass gap:
    // docutils removes it while parsing the term's inline text.
    var result = try parse(testing.allocator, "Term \\: not a classifier\n    definition\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const item = ast.nodes[ast.nodes[ast.nodes[ast.root].first_child.?].first_child.?];
    const term = item.first_child.?;
    try testing.expect(ast.nodes[ast.nodes[term].next_sibling.?].kind == .definition);
    try testing.expectEqualStrings("Term \\: not a classifier", ast.nodes[ast.nodes[term].first_child.?].kind.str);
}

test "a field list keeps all four docutils elements as generic containers" {
    var result = try parse(testing.allocator, ":Author: Me\n:Version: 1\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("field_list", ast.nodes[list].kind.container.name);
    const field = ast.nodes[list].first_child.?;
    try testing.expectEqualStrings("field", ast.nodes[field].kind.container.name);
    const name = ast.nodes[field].first_child.?;
    try testing.expectEqualStrings("field_name", ast.nodes[name].kind.container.name);
    try testing.expectEqualStrings("Author", ast.nodes[ast.nodes[name].first_child.?].kind.str);
    const body = ast.nodes[name].next_sibling.?;
    try testing.expectEqualStrings("field_body", ast.nodes[body].kind.container.name);
    try testing.expect(ast.nodes[ast.nodes[body].first_child.?].kind == .para);
    try testing.expect(ast.nodes[ast.nodes[field].next_sibling.?].next_sibling == null);
}

test "a field body takes its column from the continuation lines, not the marker" {
    // The `own_minimum` rule: a two-space continuation joins `:Authors: Me,`
    // even though the marker reserves ten columns. A list item would not.
    var result = try parse(testing.allocator, ":Authors: Me,\n  Myself\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const body = ast.nodes[ast.nodes[ast.nodes[ast.nodes[ast.root].first_child.?].first_child.?].first_child.?].next_sibling.?;
    const para = ast.nodes[body].first_child.?;
    try testing.expectEqualStrings("Me,\nMyself", ast.nodes[ast.nodes[para].first_child.?].kind.str);
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[para].next_sibling);
}

test "a field body may start on the line below its marker" {
    var result = try parse(testing.allocator, ":Author:\n  Me\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const field = ast.nodes[ast.nodes[ast.root].first_child.?].first_child.?;
    const body = ast.nodes[ast.nodes[field].first_child.?].next_sibling.?;
    const para = ast.nodes[body].first_child.?;
    try testing.expectEqualStrings("Me", ast.nodes[ast.nodes[para].first_child.?].kind.str);
}

test "field names admit embedded colons but not a colon before a backtick" {
    try testing.expectEqualStrings("field:name:with:colons", matchFieldMarker(":field:name:with:colons: body").?.name);
    try testing.expectEqualStrings("field::name", matchFieldMarker(":field::name: double colons").?.name);
    try testing.expectEqualStrings("Parameter i j k", matchFieldMarker(":Parameter i j k: multiple").?.name);
    // No body at all, and the marker still matches (`( +|$)`).
    try testing.expect(!matchFieldMarker(":Author:").?.has_content);
    // `:code:` followed by a backtick is interpreted text, not a field name.
    try testing.expectEqual(@as(?FieldMatch, null), matchFieldMarker(":code:`not a field name`: text"));
    // `::` cannot open one, and a name may not end in a space.
    try testing.expectEqual(@as(?FieldMatch, null), matchFieldMarker("::code:`x`: text"));
    try testing.expectEqual(@as(?FieldMatch, null), matchFieldMarker(":name : body"));
    // An escaped colon is carried along by the `\\.` alternative.
    try testing.expectEqualStrings("field\\:name", matchFieldMarker(":field\\:name: body").?.name);
}

test "a bullet beats a term at the same column" {
    // `classify`'s precedence: docutils' `bullet` transition is ahead of its
    // `text` one, so an indented line under `- foo` is the item's body rather
    // than a definition.
    var result = try parse(testing.allocator, "- foo\n  bar\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind == .bullet_list);
}

test "roman numerals accept only their canonical spelling" {
    try testing.expectEqual(@as(?u32, 1), fromRoman("I"));
    try testing.expectEqual(@as(?u32, 3), fromRoman("iii"));
    try testing.expectEqual(@as(?u32, 4), fromRoman("IV"));
    try testing.expectEqual(@as(?u32, 1990), fromRoman("MCMXC"));
    try testing.expectEqual(@as(?u32, null), fromRoman("iiii"));
    try testing.expectEqual(@as(?u32, null), fromRoman("LCD"));
    try testing.expectEqual(@as(?u32, null), fromRoman("CIVIL"));
    try testing.expectEqual(@as(?u32, null), fromRoman("IVXLCDM"));
    try testing.expectEqual(@as(?u32, null), fromRoman(""));
}

test "a different bullet character at the same column starts a new list" {
    var result = try parse(testing.allocator, "- item 1\n\n+ item 1\n", .{});
    defer result.deinit(testing.allocator);
    const ast = result.document.ast;
    const first = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("-", ast.attrsOf(first).get("bullet").?);
    const second = ast.nodes[first].next_sibling.?;
    try testing.expect(ast.nodes[second].kind == .bullet_list);
    try testing.expectEqualStrings("+", ast.attrsOf(second).get("bullet").?);
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[second].next_sibling);
}
