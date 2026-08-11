//! reStructuredText — the parser. Source bytes to twig's shared `AST`, judged
//! by `conformance.zig`'s corpus comparison (`encode(parse(source)) ==
//! case.doctree`) rather than by the doctree codec `doctree.zig` already
//! passes through.
//!
//! ── Scope of THIS file, today ───────────────────────────────────────────────
//! The first vertical slice, chosen by corpus weight and structural
//! simplicity rather than by docutils' own test-file order (see the "Bottom-up
//! by corpus weight" call in the session this landed in): paragraphs, section
//! titles/nesting, transitions, block quotes, and comments. No inline markup
//! parsing yet — a paragraph's whole text becomes ONE `.str` child, so any
//! case whose expected doctree contains `emphasis`/`strong`/`reference`/etc.
//! inside a paragraph will not compare equal yet. Everything else
//! (bullet/enumerated/definition lists, literal blocks, directives, the
//! hyperlink/footnote/citation/substitution clusters, tables) is unimplemented
//! and deliberately out of this file for now.
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
            if (indent == 0 and self.matchTitle(i) != null) break;

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

            const content = self.trimmedContent(i, indent);
            if (isTransitionLine(content)) {
                const id = try self.b.addLeaf(.thematic_break);
                self.b.setSpan(id, Span.init(self.lines[i].start, self.lines[i].end));
                try children.append(self.allocator, id);
                i += 1;
                continue;
            }
            if (isCommentStart(content)) {
                const cm = try self.parseComment(i, hi, indent);
                try children.append(self.allocator, cm.id);
                i = cm.next;
                continue;
            }

            const para_end = self.findParagraphEnd(i, hi, indent);
            const text = try self.assembleText(i, para_end, indent);
            const str_id = try self.b.addLeaf(.{ .str = text });
            self.allocator.free(text);
            self.b.setSpan(str_id, Span.init(self.lines[i].start, self.lines[para_end - 1].end));
            const para_id = try self.b.addContainer(.para, &.{str_id});
            self.b.setSpan(para_id, Span.init(self.lines[i].start, self.lines[para_end - 1].end));
            try children.append(self.allocator, para_id);
            i = para_end;
        }
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = i };
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
        const id = if (comment_text.len == 0)
            try self.b.addLeaf(.{ .container = .{ .name = "comment" } })
        else
            try self.b.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = comment_text } });
        self.b.setSpan(id, Span.init(self.lines[i].start, self.lines[next - 1].end));
        // docutils marks every text-preserving element this way; it is a
        // fixed invariant of the construct, not a reading of anything in the
        // rST source, so it is set here rather than derived.
        try self.b.setAttrs(id, .{ .entries = &.{.{ .key = "xml:space", .value = "preserve" }} });
        return .{ .id = id, .next = next };
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
