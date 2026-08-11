//! AsciiDoc — the parser. Source bytes to twig's shared `AST`, judged by
//! `conformance.zig`'s corpus comparison (`asg.encode(parse(source)) ==
//! case.asg`, structurally) against the vendored TCK corpus, exactly the
//! shapes `asg.zig`'s `decode` already proved have somewhere to live.
//!
//! ── Scope of THIS file, today ───────────────────────────────────────────────
//! The first vertical slice, sized to the 13-case TCK rather than to the full
//! (still-being-written) AsciiDoc spec: the document header (title + the
//! attribute entries directly below it, before the first blank line),
//! paragraphs (single-line, hard-wrapped, and blank-line-separated), section
//! titles nested by their `=` count (untested past one level by the corpus,
//! but the nesting itself falls out of the level number for free — see
//! below), unordered lists (one marker character, one level, one line per
//! item), delimited listing blocks (` ---- `), sidebars (` **** `, a generic
//! container — see `asg.zig`'s doc comment for why it has no semantic
//! `Kind`), and constrained `*strong*` spans. Everything else — ordered
//! lists, links, images, tables, admonitions, cross references, any other
//! inline formatting — is unimplemented and deliberately out of this file.
//!
//! ── Why this shape ───────────────────────────────────────────────────────
//! Bottom-up onto `AST.Builder`, the same posture `languages/rst/parser.zig`
//! took for reStructuredText. Section nesting is simpler here than rST's: an
//! AsciiDoc section's level is spelled directly in the source as the marker's
//! `=` count minus one, so there is no need for rST's order-of-first-use
//! style stack — `parseSection` just recurses, and `parseSectionsLoop` closes
//! back to a parent by comparing level numbers directly.
//!
//! ── Position matters here in a way it didn't for rST's first slice ────────
//! `doctree.zig`'s docutils pformat carries no source positions at all, so
//! rST's parser could set best-effort spans and let the corpus comparison
//! ignore them. The TCK's ASG carries a `location` on every node, and the
//! conformance harness compares through `asg.encode`, which writes it back —
//! so every span this file sets is load-bearing, not cosmetic. Where the
//! corpus doesn't exercise a shape (an unclosed listing block, a document
//! with leading blank lines), spans are still computed by the same rules,
//! just unverified.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const Span = @import("../../span.zig");
const Document = @import("../../document.zig");

pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!Document {
    var p = try Parser.init(allocator, source);
    defer p.deinit();
    const root = try p.parseDocument();
    return p.b.finishDocument(source, root);
}

/// The TCK's `inline`-level entry point: `source` (a single line, e.g.
/// `"*s*\n"`) is scanned for inline markup directly, with no document/block
/// structure at all, and the resulting nodes are wrapped in a synthetic
/// `.doc` root — mirroring `asg.decode`'s own `.inlines` case exactly, so
/// `asg.encode(&doc, .inlines, ...)` (which reads straight through that
/// wrapper) can print it back.
pub fn parseInlineList(allocator: Allocator, source: []const u8) Allocator.Error!Document {
    var b = Builder.init(allocator);
    errdefer b.deinit();
    const text = std.mem.trimEnd(u8, source, "\n");
    const ids = try parseInlines(&b, text, 0);
    defer allocator.free(ids);
    const root = try b.addContainer(.doc, ids);
    return b.finishDocument(source, root);
}

/// One line of source, as a byte range excluding its terminating `\n`.
const LineInfo = struct { start: usize, end: usize };

/// A recognized `=`-prefixed title line — a document title (`level == 0`,
/// only matched at line 0) or a section title (`level >= 1`, matched
/// anywhere at column 0).
const HeadingMatch = struct {
    level: u32,
    text: []const u8,
    text_span: Span,
    /// Start of the marker itself (`=`'s own column), which is also the
    /// start of the construct the marker introduces (a header or a section).
    span_start: usize,
    next_line: usize,
};

const FlatResult = struct { items: []Node.Id, stopped_at: usize, last_end: usize = 0 };
const SectionsResult = struct { items: []Node.Id, stopped_at: usize, last_end: usize = 0 };

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    lines: []const LineInfo,
    b: Builder,

    fn init(allocator: Allocator, source: []const u8) Allocator.Error!Parser {
        return .{ .allocator = allocator, .source = source, .lines = try computeLines(allocator, source), .b = Builder.init(allocator) };
    }

    fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
        self.b.deinit();
    }

    // ── line helpers ─────────────────────────────────────────────────────

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

    // ── title / heading recognition ─────────────────────────────────────

    /// Any `=`-run + space + text line at column 0 — level `n - 1` for `n`
    /// leading `=` characters. Callers filter by level: `matchDocTitle` wants
    /// exactly 0 (and only at line 0), `matchSectionHeading` wants >= 1.
    fn matchHeadingLineRaw(self: *const Parser, i: usize) ?HeadingMatch {
        if (i >= self.lines.len) return null;
        if (self.leadingSpaces(i) != 0) return null;
        const t = self.lineText(i);
        var n: usize = 0;
        while (n < t.len and t[n] == '=') : (n += 1) {}
        if (n == 0 or n >= t.len or t[n] != ' ') return null;
        const text = std.mem.trimEnd(u8, t[n + 1 ..], " \t");
        if (text.len == 0) return null;
        const text_start = self.lines[i].start + n + 1;
        return .{
            .level = @intCast(n - 1),
            .text = text,
            .text_span = Span.init(text_start, text_start + text.len),
            .span_start = self.lines[i].start,
            .next_line = i + 1,
        };
    }

    fn matchDocTitle(self: *const Parser) ?HeadingMatch {
        const hm = self.matchHeadingLineRaw(0) orelse return null;
        if (hm.level != 0) return null;
        return hm;
    }

    fn matchSectionHeading(self: *const Parser, i: usize) ?HeadingMatch {
        const hm = self.matchHeadingLineRaw(i) orelse return null;
        if (hm.level == 0) return null;
        return hm;
    }

    /// `:name: value` — the document-header attribute entry syntax. `value`
    /// is trimmed of surrounding whitespace; a bare `:name:` (nothing after
    /// the second colon) yields an empty, non-null value, matching the TCK's
    /// own `{"toc": ""}`.
    fn matchAttrEntry(self: *const Parser, i: usize) ?struct { key: []const u8, value: []const u8 } {
        const t = self.lineText(i);
        if (t.len < 2 or t[0] != ':') return null;
        var j: usize = 1;
        while (j < t.len and t[j] != ':') : (j += 1) {}
        if (j >= t.len or j == 1) return null;
        return .{ .key = t[1..j], .value = std.mem.trim(u8, t[j + 1 ..], " \t") };
    }

    // ── delimited-block / list-item recognition ─────────────────────────

    fn isDelimLine(self: *const Parser, i: usize, ch: u8) bool {
        if (self.leadingSpaces(i) != 0) return false;
        const t = std.mem.trimEnd(u8, self.lineText(i), " \t");
        if (t.len < 4) return false;
        for (t) |c| {
            if (c != ch) return false;
        }
        return true;
    }

    fn isListingDelim(self: *const Parser, i: usize) bool {
        return self.isDelimLine(i, '-');
    }

    fn isSidebarDelim(self: *const Parser, i: usize) bool {
        return self.isDelimLine(i, '*');
    }

    fn matchesDelim(self: *const Parser, i: usize, opening: []const u8) bool {
        if (self.leadingSpaces(i) != 0) return false;
        return std.mem.eql(u8, std.mem.trimEnd(u8, self.lineText(i), " \t"), opening);
    }

    fn isListItem(self: *const Parser, i: usize) bool {
        if (self.leadingSpaces(i) != 0) return false;
        const t = self.lineText(i);
        if (t.len < 2) return false;
        return (t[0] == '*' or t[0] == '-' or t[0] == '+') and t[1] == ' ';
    }

    fn isBlockStart(self: *const Parser, i: usize) bool {
        return self.matchSectionHeading(i) != null or self.isListingDelim(i) or self.isSidebarDelim(i) or self.isListItem(i);
    }

    // ── the top-level document scan ─────────────────────────────────────

    fn parseDocument(self: *Parser) Allocator.Error!Node.Id {
        var header_id: ?Node.Id = null;
        var attrs_id: ?Node.Id = null;
        var start_offset: usize = if (self.lines.len > 0) self.lines[0].start else 0;
        var header_end_offset: usize = start_offset;
        var body_start_line: usize = 0;

        if (self.matchDocTitle()) |dt| {
            var header_end_line = dt.next_line;
            var attr_entries: std.ArrayList(AST.KeyVal) = .empty;
            defer attr_entries.deinit(self.allocator);
            header_end_offset = self.lines[0].end;
            while (header_end_line < self.lines.len and !self.isBlankLine(header_end_line)) {
                const ae = self.matchAttrEntry(header_end_line) orelse break;
                try attr_entries.append(self.allocator, .{ .key = ae.key, .value = ae.value });
                header_end_offset = self.lines[header_end_line].end;
                header_end_line += 1;
            }

            const title_str = try self.b.addLeaf(.{ .str = dt.text });
            self.b.setSpan(title_str, dt.text_span);
            const heading_id = try self.b.addContainer(.{ .heading = .{ .level = 0 } }, &.{title_str});
            self.b.setSpan(heading_id, Span.init(dt.span_start, header_end_offset));
            header_id = heading_id;
            start_offset = dt.span_start;

            // The attributes marker is present whenever a header is, even
            // with zero entries — see `asg.zig`'s doc comment: its mere
            // presence as a child (not whether `setAttrs` ran) is what
            // signals `encode` to write the `"attributes"` key at all.
            const attrs_marker = try self.b.addNode(.{ .container = .{ .name = "document-attributes" } });
            if (attr_entries.items.len > 0) try self.b.setAttrs(attrs_marker, .{ .entries = attr_entries.items });
            attrs_id = attrs_marker;

            body_start_line = header_end_line;
        }

        const body = try self.parseSectionsLoop(body_start_line, self.lines.len, 0);
        defer self.allocator.free(body.items);

        var children: std.ArrayList(Node.Id) = .empty;
        defer children.deinit(self.allocator);
        if (attrs_id) |aid| try children.append(self.allocator, aid);
        if (header_id) |hid| try children.append(self.allocator, hid);
        try children.appendSlice(self.allocator, body.items);

        const end_offset = if (body.items.len > 0) body.last_end else header_end_offset;
        const root = try self.b.addContainer(.doc, children.items);
        self.b.setSpan(root, Span.init(start_offset, end_offset));
        return root;
    }

    // ── section nesting ───────────────────────────────────────────────────

    /// Parses the flat block run starting at `lo`, opening nested sections
    /// (and their whole subtrees) as their headings are found, until a
    /// heading at or above `current_level` closes this level back to its
    /// caller — the base case being `current_level == 0` at the document
    /// root, which no real section level is `<=` to.
    fn parseSectionsLoop(self: *Parser, lo: usize, hi: usize, current_level: u32) Allocator.Error!SectionsResult {
        var children: std.ArrayList(Node.Id) = .empty;
        errdefer children.deinit(self.allocator);
        var i = lo;
        var last_end: usize = 0;
        while (true) {
            const flat = try self.parseFlatBlocks(i, hi);
            try children.appendSlice(self.allocator, flat.items);
            if (flat.items.len > 0) last_end = flat.last_end;
            self.allocator.free(flat.items);
            i = flat.stopped_at;
            if (i >= hi) break;

            const hm = self.matchSectionHeading(i).?; // `parseFlatBlocks` only stops early for this
            if (hm.level <= current_level) break;
            const r = try self.parseSection(hm, hi);
            try children.append(self.allocator, r.id);
            last_end = r.end_offset;
            i = r.next;
        }
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = i, .last_end = last_end };
    }

    fn parseSection(self: *Parser, hm: HeadingMatch, hi: usize) Allocator.Error!struct { id: Node.Id, next: usize, end_offset: usize } {
        const title_str = try self.b.addLeaf(.{ .str = hm.text });
        self.b.setSpan(title_str, hm.text_span);
        const heading_id = try self.b.addContainer(.{ .heading = .{ .level = hm.level } }, &.{title_str});
        self.b.setSpan(heading_id, hm.text_span);

        const inner = try self.parseSectionsLoop(hm.next_line, hi, hm.level);
        defer self.allocator.free(inner.items);

        const all = try self.allocator.alloc(Node.Id, 1 + inner.items.len);
        defer self.allocator.free(all);
        all[0] = heading_id;
        @memcpy(all[1..], inner.items);

        const id = try self.b.addContainer(.section, all);
        const end_offset = if (inner.items.len > 0) inner.last_end else hm.text_span.end;
        self.b.setSpan(id, Span.init(hm.span_start, end_offset));
        return .{ .id = id, .next = inner.stopped_at, .end_offset = end_offset };
    }

    // ── the flat block scan ────────────────────────────────────────────

    /// Parses blocks in `[lo, hi)`, stopping at `hi` or at the first section
    /// heading (any level) — the only construct a caller (`parseSectionsLoop`)
    /// needs to inspect rather than have consumed outright.
    fn parseFlatBlocks(self: *Parser, lo: usize, hi: usize) Allocator.Error!FlatResult {
        var children: std.ArrayList(Node.Id) = .empty;
        errdefer children.deinit(self.allocator);
        var i = lo;
        var last_end: usize = 0;
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            if (self.matchSectionHeading(i) != null) break;

            if (self.isListingDelim(i)) {
                const r = try self.parseListing(i, hi);
                try children.append(self.allocator, r.id);
                last_end = r.end_offset;
                i = r.next;
                continue;
            }
            if (self.isSidebarDelim(i)) {
                const r = try self.parseSidebar(i, hi);
                try children.append(self.allocator, r.id);
                last_end = r.end_offset;
                i = r.next;
                continue;
            }
            if (self.isListItem(i)) {
                const r = try self.parseList(i, hi);
                try children.append(self.allocator, r.id);
                last_end = r.end_offset;
                i = r.next;
                continue;
            }

            const end = self.paragraphEnd(i, hi);
            const p = try self.parseParagraph(i, end);
            try children.append(self.allocator, p.id);
            last_end = p.end_offset;
            i = end;
        }
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = i, .last_end = last_end };
    }

    fn paragraphEnd(self: *const Parser, lo: usize, hi: usize) usize {
        var i = lo + 1;
        while (i < hi) {
            if (self.isBlankLine(i) or self.isBlockStart(i)) break;
            i += 1;
        }
        return i;
    }

    /// A paragraph's text is exactly `source[lines[lo].start..lines[end_ex-1].end]`
    /// — a hard-wrapped paragraph's embedded `\n`s are real source bytes, not
    /// synthesized, so no line-by-line reassembly is needed the way rST's
    /// indent-stripping `assembleText` requires.
    fn parseParagraph(self: *Parser, lo: usize, end_ex: usize) Allocator.Error!struct { id: Node.Id, end_offset: usize } {
        const span = Span.init(self.lines[lo].start, self.lines[end_ex - 1].end);
        const text = self.source[span.start..span.end];
        const ids = try parseInlines(&self.b, text, span.start);
        defer self.allocator.free(ids);
        const id = try self.b.addContainer(.para, ids);
        self.b.setSpan(id, span);
        return .{ .id = id, .end_offset = span.end };
    }

    fn parseListing(self: *Parser, delim_line: usize, hi: usize) Allocator.Error!struct { id: Node.Id, next: usize, end_offset: usize } {
        const opening = std.mem.trimEnd(u8, self.lineText(delim_line), " \t");
        var close_line = delim_line + 1;
        while (close_line < hi and !self.matchesDelim(close_line, opening)) close_line += 1;
        const closed = close_line < hi;
        const content_lo = delim_line + 1;
        const content_hi = close_line;

        var text: []const u8 = "";
        var content_span = Span.init(self.lines[delim_line].end, self.lines[delim_line].end);
        if (content_hi > content_lo) {
            content_span = Span.init(self.lines[content_lo].start, self.lines[content_hi - 1].end);
            text = self.source[content_span.start..content_span.end];
        }

        const id = try self.b.addLeaf(.{ .code_block = .{ .lang = null, .text = text } });
        self.b.setContentSpan(id, content_span);
        const end_offset = if (closed)
            self.lines[close_line].end
        else if (content_hi > content_lo)
            self.lines[content_hi - 1].end
        else
            self.lines[delim_line].end;
        self.b.setSpan(id, Span.init(self.lines[delim_line].start, end_offset));
        try self.b.setAttrs(id, .{ .entries = &.{
            .{ .key = "form", .value = "delimited" },
            .{ .key = "delimiter", .value = opening },
        } });
        return .{ .id = id, .next = if (closed) close_line + 1 else content_hi, .end_offset = end_offset };
    }

    fn parseSidebar(self: *Parser, delim_line: usize, hi: usize) Allocator.Error!struct { id: Node.Id, next: usize, end_offset: usize } {
        const opening = std.mem.trimEnd(u8, self.lineText(delim_line), " \t");
        var close_line = delim_line + 1;
        while (close_line < hi and !self.matchesDelim(close_line, opening)) close_line += 1;
        const closed = close_line < hi;
        const content_lo = delim_line + 1;
        const content_hi = close_line;

        const inner = try self.parseFlatBlocks(content_lo, content_hi);
        defer self.allocator.free(inner.items);

        const id = try self.b.addContainer(.{ .container = .{ .name = "sidebar" } }, inner.items);
        const end_offset = if (closed)
            self.lines[close_line].end
        else if (inner.items.len > 0)
            inner.last_end
        else
            self.lines[delim_line].end;
        self.b.setSpan(id, Span.init(self.lines[delim_line].start, end_offset));
        try self.b.setAttrs(id, .{ .entries = &.{
            .{ .key = "form", .value = "delimited" },
            .{ .key = "delimiter", .value = opening },
        } });
        return .{ .id = id, .next = if (closed) close_line + 1 else content_hi, .end_offset = end_offset };
    }

    fn parseList(self: *Parser, lo: usize, hi: usize) Allocator.Error!struct { id: Node.Id, next: usize, end_offset: usize } {
        const marker_char = self.lineText(lo)[0];
        var items: std.ArrayList(Node.Id) = .empty;
        errdefer items.deinit(self.allocator);
        var i = lo;
        var last_end: usize = self.lines[lo].end;
        while (i < hi) {
            if (self.isBlankLine(i)) break;
            const t = self.lineText(i);
            if (self.leadingSpaces(i) != 0 or t.len < 2 or t[0] != marker_char or t[1] != ' ') break;

            const text = std.mem.trimEnd(u8, t[2..], " \t");
            const text_start = self.lines[i].start + 2;
            const inline_ids = try parseInlines(&self.b, text, text_start);
            defer self.allocator.free(inline_ids);
            const item_id = try self.b.addContainer(.list_item, inline_ids);
            const item_end = text_start + text.len;
            self.b.setSpan(item_id, Span.init(self.lines[i].start, item_end));
            self.b.setSpelling(item_id, .{ .bullet = bulletFromChar(marker_char) });
            try items.append(self.allocator, item_id);
            last_end = item_end;
            i += 1;
        }

        const id = try self.b.addContainer(.{ .bullet_list = .{ .tight = true } }, items.items);
        items.deinit(self.allocator);
        self.b.setSpan(id, Span.init(self.lines[lo].start, last_end));
        self.b.setSpelling(id, .{ .bullet = bulletFromChar(marker_char) });
        return .{ .id = id, .next = i, .end_offset = last_end };
    }
};

fn bulletFromChar(ch: u8) Document.Spelling.Bullet {
    return switch (ch) {
        '*' => .star,
        '-' => .dash,
        '+' => .plus,
        else => unreachable, // only called after `isListItem` validated `ch`
    };
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn emitText(b: *Builder, s: []const u8, offset: usize) Allocator.Error!Node.Id {
    const id = try b.addLeaf(.{ .str = s });
    b.setSpan(id, Span.init(offset, offset + s.len));
    return id;
}

/// Scan `text` (a slice of `source` starting at byte offset `base`) for
/// constrained `*strong*` spans, returning the resulting run of `str` and
/// `inline_mark{.strong}` nodes. An opening `*` cannot be preceded by a word
/// character or followed by whitespace; a closing `*` cannot be preceded by
/// whitespace or followed by a word character — AsciiDoc's constrained-span
/// word-boundary rule, checked on both delimiters independently.
fn parseInlines(b: *Builder, text: []const u8, base: usize) Allocator.Error![]Node.Id {
    var ids: std.ArrayList(Node.Id) = .empty;
    errdefer ids.deinit(b.allocator);
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '*') open: {
            const prev_word = i > 0 and isWordByte(text[i - 1]);
            if (prev_word or i + 1 >= text.len) break :open;
            const next = text[i + 1];
            if (next == ' ' or next == '\t' or next == '\n') break :open;

            var j = i + 1;
            const close_idx = while (j < text.len) : (j += 1) {
                if (text[j] != '*') continue;
                const before_space = text[j - 1] == ' ' or text[j - 1] == '\t' or text[j - 1] == '\n';
                const after_word = j + 1 < text.len and isWordByte(text[j + 1]);
                if (!before_space and !after_word) break j;
            } else break :open;

            if (i > plain_start) try ids.append(b.allocator, try emitText(b, text[plain_start..i], base + plain_start));
            const inner = try parseInlines(b, text[i + 1 .. close_idx], base + i + 1);
            defer b.allocator.free(inner);
            const span_id = try b.addContainer(.{ .inline_mark = .strong }, inner);
            b.setSpan(span_id, Span.init(base + i, base + close_idx + 1));
            try ids.append(b.allocator, span_id);
            i = close_idx + 1;
            plain_start = i;
            continue;
        }
        i += 1;
    }
    if (plain_start < text.len) try ids.append(b.allocator, try emitText(b, text[plain_start..], base + plain_start));
    return ids.toOwnedSlice(b.allocator);
}

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

const testing = std.testing;

test "a single paragraph" {
    var doc = try parse(testing.allocator, "A paragraph that consists of a single line.\n");
    defer doc.deinit();
    const ast = doc.ast;
    const para = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[para].kind == .para);
    const str = ast.nodes[para].first_child.?;
    try testing.expectEqualStrings("A paragraph that consists of a single line.", ast.nodes[str].kind.str);
}

test "a document title becomes a level-0 heading, attribute entries attach to the document" {
    var doc = try parse(testing.allocator, "= Document Title\n:icons: font\n:toc:\n");
    defer doc.deinit();
    const ast = doc.ast;
    const attrs_marker = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("document-attributes", ast.nodes[attrs_marker].kind.container.name);
    try testing.expectEqualStrings("font", ast.attrsOf(attrs_marker).get("icons").?);
    try testing.expectEqualStrings("", ast.attrsOf(attrs_marker).get("toc").?);
    const heading = ast.nodes[attrs_marker].next_sibling.?;
    try testing.expectEqual(@as(u32, 0), ast.nodes[heading].kind.heading.level);
}

test "a section nests a paragraph inside it" {
    var doc = try parse(testing.allocator, "== Section Title\n\nparagraph\n");
    defer doc.deinit();
    const ast = doc.ast;
    const section = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[section].kind == .section);
    const heading = ast.nodes[section].first_child.?;
    try testing.expectEqual(@as(u32, 1), ast.nodes[heading].kind.heading.level);
    const body = ast.nodes[heading].next_sibling.?;
    try testing.expect(ast.nodes[body].kind == .para);
}

test "a deeper heading nests inside a shallower one; a same-level heading closes it" {
    var doc = try parse(testing.allocator, "== One\n\n=== Two\n\npar\n\n== Three\n");
    defer doc.deinit();
    const ast = doc.ast;
    const sec_one = ast.nodes[ast.root].first_child.?;
    const sec_three = ast.nodes[sec_one].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[sec_three].next_sibling);
    const heading_one = ast.nodes[sec_one].first_child.?;
    const sec_two = ast.nodes[heading_one].next_sibling.?;
    try testing.expect(ast.nodes[sec_two].kind == .section);
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[sec_two].next_sibling);
}

test "an unordered list item carries its bullet spelling" {
    var doc = try parse(testing.allocator, "* water\n");
    defer doc.deinit();
    const ast = doc.ast;
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind == .bullet_list);
    const item = ast.nodes[list].first_child.?;
    try testing.expectEqual(Document.Spelling.Bullet.star, doc.spelling(item).?.bullet);
    const str = ast.nodes[item].first_child.?;
    try testing.expectEqualStrings("water", ast.nodes[str].kind.str);
}

test "a delimited listing block keeps its interior verbatim" {
    var doc = try parse(testing.allocator, "----\ndef main\n  puts 'hello'\nend\n----\n");
    defer doc.deinit();
    const ast = doc.ast;
    const listing = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("def main\n  puts 'hello'\nend", ast.nodes[listing].kind.code_block.text);
}

test "a sidebar is a generic container holding its blocks" {
    var doc = try parse(testing.allocator, "****\n* phone\n* wallet\n* keys\n****\n");
    defer doc.deinit();
    const ast = doc.ast;
    const sidebar = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("sidebar", ast.nodes[sidebar].kind.container.name);
    const list = ast.nodes[sidebar].first_child.?;
    try testing.expect(ast.nodes[list].kind == .bullet_list);
}

test "a constrained strong span" {
    var doc = try parseInlineList(testing.allocator, "*s*\n");
    defer doc.deinit();
    const ast = doc.ast;
    const span = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[span].kind.inline_mark == .strong);
    const str = ast.nodes[span].first_child.?;
    try testing.expectEqualStrings("s", ast.nodes[str].kind.str);
}
