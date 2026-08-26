//! Block-level scanner: a line-oriented state machine over an explicit stack
//! of open containers, producing a flat `[]Event`. Ported from djot.js's
//! `src/block.ts` (`EventParser`).
//!
//! Unlike djot.js (a lazy JS generator consumed once via `Array.from`), this
//! runs eagerly to completion (`scan`) since the caller always wants the
//! whole event stream at once.
//!
//! djot.js drives each block type through a `BlockSpec` object of closures
//! (`continue`/`open`/`close`); Zig has no convenient closures capturing
//! `this`, so each spec becomes a named `continueX`/`openX`/`closeX` method
//! on `Parser` dispatched through an exhaustive `switch` on `BlockKind` —
//! the compiler checks every kind is handled, which a JS array of objects
//! can't offer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("event.zig");
const Event = event.Event;
const EventList = event.EventList;
const Annotation = event.Annotation;
const ListMarkerStyle = event.ListMarkerStyle;
const ListStyleCandidates = event.ListStyleCandidates;
const AttributeParser = @import("attributes.zig");
const inline_mod = @import("inline.zig");
const InlineParser = inline_mod.InlineParser;

// ── character classes ──────────────────────────────────────────────────────

fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}
fn isEol(c: u8) bool {
    return c == '\n' or c == '\r';
}
fn isWsAny(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isRomanLower(c: u8) bool {
    return switch (c) {
        'i', 'v', 'x', 'l', 'c', 'd', 'm' => true,
        else => false,
    };
}
fn isRomanUpper(c: u8) bool {
    return switch (c) {
        'I', 'V', 'X', 'L', 'C', 'D', 'M' => true,
        else => false,
    };
}

// ── content/container model ────────────────────────────────────────────────

pub const ContentType = enum { none, inline_, block, text, cells, attributes, list_item };

pub const BlockKind = enum {
    block_quote,
    heading,
    caption,
    footnote,
    reference_definition,
    thematic_break,
    list,
    list_item,
    table,
    attributes,
    fenced_div,
    code_block,
    para,
};

const Slice = struct { start: usize, end: usize };

/// Scratch state for whichever `BlockKind` is open — a "kitchen sink" struct
/// (only the fields relevant to the open container's kind are used) rather
/// than a tagged union, since Zig has no closures to stash per-instance data
/// in the way djot.js's `Container.extra: {[key:string]: any}` does.
const Extra = struct {
    level: u32 = 0, // heading
    indent: usize = 0, // footnote / reference_definition / list / list_item / attributes
    note_label: Slice = .{ .start = 0, .end = 0 }, // footnote
    ref_key: Slice = .{ .start = 0, .end = 0 }, // reference_definition
    styles: ListStyleCandidates = .{}, // list / list_item
    first_marker: ?Slice = null, // list: the very first item's marker text
    checkbox: ?bool = null, // list_item: true=checked, false=unchecked
    is_definition_item: bool = false, // list_item
    // attributes (block-level)
    attr_parser: ?AttributeParser = null,
    attr_status: AttributeParser.Status = .continue_,
    attr_startpos: usize = 0,
    /// Position of the closing `}`, once the attribute parser has reported
    /// `.done`. Only then is the block a single source range a serializer can
    /// re-emit, which is what `parser.zig` builds `Document.attrs_spans` from;
    /// `attr_startpos` doubles as "no end yet" (see `closeAttributes`).
    attr_endpos: usize = 0,
    attr_slices: std.ArrayList(Slice) = .empty,
    // fenced_div
    colons: usize = 0,
    end_fence: ?Slice = null,
    // code_block
    fence_char: u8 = '`',
    fence_len: usize = 0,
};

const Container = struct {
    kind: BlockKind,
    ctype: ContentType, // what type of container THIS is (for parent-content matching)
    content: ContentType, // what content type this container HOLDS
    indent: usize = 0,
    inline_parser: ?InlineParser = null,
    extra: Extra = .{},

    fn deinit(self: *Container, allocator: Allocator) void {
        if (self.inline_parser) |*ip| ip.deinit(allocator);
        if (self.extra.attr_parser) |*ap| ap.deinit(allocator);
        self.extra.attr_slices.deinit(allocator);
    }
};

/// The result of `scan`: the flat event stream plus ownership of everything
/// it borrowed (nothing — events only carry byte offsets into `subject`).
pub const ScanResult = struct {
    events: []Event,

    pub fn deinit(self: *ScanResult, allocator: Allocator) void {
        allocator.free(self.events);
    }
};

pub const Parser = struct {
    allocator: Allocator,
    subject: []const u8,
    owns_subject: bool,
    maxoffset: usize,
    indent: usize = 0,
    startline: usize = 0,
    starteol: usize = 0,
    endeol: usize = 0,
    matches: EventList = .empty,
    containers: std.ArrayList(Container) = .empty,
    pos: usize = 0,
    last_matched_container: isize = -1,
    finished_line: bool = false,

    /// One past the last byte of the most recent line that carried content.
    /// A block-level container closes on the line that *stopped* it, so by
    /// then `pos` is already sitting on somebody else's line — a span built
    /// from it swallows the blank lines that merely separate the two blocks
    /// plus the first byte of the next one. Closers that have no syntax of
    /// their own to end at (no fence, no delimiter) end here instead.
    content_end: usize = 0,

    /// `subject` need not end with `\n`; if it doesn't, a copy is made with
    /// one appended (matching djot.js's constructor).
    pub fn init(allocator: Allocator, subject: []const u8) Allocator.Error!Parser {
        var owns = false;
        var s = subject;
        if (s.len == 0 or s[s.len - 1] != '\n') {
            const buf = try allocator.alloc(u8, s.len + 1);
            @memcpy(buf[0..s.len], s);
            buf[s.len] = '\n';
            s = buf;
            owns = true;
        }
        return .{
            .allocator = allocator,
            .subject = s,
            .owns_subject = owns,
            .maxoffset = s.len - 1,
        };
    }

    pub fn deinit(self: *Parser) void {
        for (self.containers.items) |*c| c.deinit(self.allocator);
        self.containers.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        if (self.owns_subject) self.allocator.free(self.subject);
    }

    fn addMatch(self: *Parser, start: usize, end: usize, annot: Annotation) Allocator.Error!void {
        try self.matches.append(self.allocator, .{
            .start = @intCast(@min(start, self.maxoffset)),
            .end = @intCast(@min(end, self.maxoffset)),
            .annot = annot,
        });
    }

    fn addMatchStyled(self: *Parser, start: usize, end: usize, annot: Annotation, styles: ListStyleCandidates) Allocator.Error!void {
        try self.matches.append(self.allocator, .{
            .start = @intCast(@min(start, self.maxoffset)),
            .end = @intCast(@min(end, self.maxoffset)),
            .annot = annot,
            .list_styles = styles,
        });
    }

    fn tipIndex(self: *const Parser) ?usize {
        return if (self.containers.items.len >= 1) self.containers.items.len - 1 else null;
    }

    fn tip(self: *Parser) ?*Container {
        const i = self.tipIndex() orelse return null;
        return &self.containers.items[i];
    }

    // ── low-level scanning helpers ─────────────────────────────────────

    fn skipSpace(self: *Parser) void {
        var newpos = self.pos;
        while (newpos < self.subject.len and isSpaceOrTab(self.subject[newpos])) newpos += 1;
        self.indent = newpos - self.startline;
        self.pos = newpos;
    }

    fn getEol(self: *Parser) void {
        var i = self.pos;
        while (i < self.subject.len and !isEol(self.subject[i])) i += 1;
        self.starteol = i;
        if (i < self.subject.len and self.subject[i] == '\r' and i + 1 < self.subject.len and self.subject[i + 1] == '\n') {
            self.endeol = i + 1;
        } else {
            self.endeol = i;
        }
    }

    fn byteAt(self: *const Parser, pos: usize) u8 {
        return if (pos < self.subject.len) self.subject[pos] else 0;
    }

    /// Nothing but spaces and tabs between `startline` and the newline.
    fn lineIsBlank(self: *const Parser) bool {
        var i = self.startline;
        while (i < self.starteol) : (i += 1) {
            if (!isSpaceOrTab(self.subject[i])) return false;
        }
        return true;
    }

    /// The `end` a block-level closer should report: the last byte of the
    /// content its container owns. `addMatch` ends are inclusive and the tree
    /// builder adds the 1 back, so this is `content_end - 1`.
    fn contentEndMatch(self: *const Parser) usize {
        return self.content_end -| 1;
    }

    // ── generic container push/close machinery ─────────────────────────

    fn closeContainer(self: *Parser, idx: usize) Allocator.Error!void {
        // Take the container out of the stack first, so `close*` handlers
        // that need `self.tip()` see the PARENT, matching djot.js's
        // `this.containers.pop()` happening at the top of every `close`.
        var c = self.containers.pop().?;
        _ = idx;
        defer c.deinit(self.allocator);
        switch (c.kind) {
            .block_quote => try self.closeBlockQuote(&c),
            .heading => try self.closeHeading(&c),
            .caption => try self.closeCaption(&c),
            .footnote => try self.closeFootnote(&c),
            .reference_definition => try self.closeReferenceDefinition(&c),
            .thematic_break => {},
            .list => try self.closeList(&c),
            .list_item => try self.closeListItem(&c),
            .table => try self.closeTable(&c),
            .attributes => try self.closeAttributes(&c),
            .fenced_div => try self.closeFencedDiv(&c),
            .code_block => try self.closeCodeBlock(&c),
            .para => try self.closePara(&c),
        }
    }

    fn closeUnmatchedContainers(self: *Parser) Allocator.Error!void {
        const last_matched = self.last_matched_container;
        while (self.containers.items.len > 0 and
            @as(isize, @intCast(self.containers.items.len)) - 1 > last_matched)
        {
            try self.closeContainer(self.containers.items.len - 1);
        }
    }

    /// Push `container`, first closing any containers it can't nest inside
    /// (closing unmatched containers from the current line, then closing
    /// containers whose `content` doesn't match `container.ctype`).
    fn addContainer(self: *Parser, container: Container, skip_close_unmatched: bool) Allocator.Error!void {
        if (!skip_close_unmatched) try self.closeUnmatchedContainers();
        while (self.tip()) |t| {
            if (t.content == container.ctype) break;
            try self.closeContainer(self.containers.items.len - 1);
        }
        var c = container;
        if (c.content == .inline_) {
            c.inline_parser = InlineParser.init(self.subject);
        }
        try self.containers.append(self.allocator, c);
    }

    // ── entry point ──────────────────────────────────────────────────────

    /// Run the scanner to completion, returning the whole event stream. The
    /// returned slice is owned by the caller (`allocator.free`); `Parser`
    /// itself should still be `deinit`ed to release scratch state.
    pub fn scan(self: *Parser) Allocator.Error![]Event {
        const subjectlen = self.subject.len;
        while (self.pos < subjectlen) {
            self.indent = 0;
            self.startline = self.pos;
            self.finished_line = false;
            self.getEol();

            // Match open containers against the current line, top-down.
            self.last_matched_container = -1;
            var idx: usize = 0;
            while (idx < self.containers.items.len) {
                self.skipSpace();
                const cont = try self.continueContainer(idx);
                if (cont) {
                    self.last_matched_container = @intCast(idx);
                } else {
                    break;
                }
                idx += 1;
            }

            if (self.finished_line) {
                while (self.containers.items.len > 0 and
                    self.last_matched_container < @as(isize, @intCast(self.containers.items.len)) - 1)
                {
                    try self.closeContainer(self.containers.items.len - 1);
                }
            }

            if (!self.finished_line) {
                self.skipSpace();
                var is_blank = self.pos == self.starteol;
                var new_starts = false;
                var last_match_idx: ?usize = if (self.last_matched_container >= 0) @intCast(self.last_matched_container) else null;

                var check_starts = !is_blank and
                    (last_match_idx == null or
                        self.containers.items[last_match_idx.?].content == .block or
                        self.containers.items[last_match_idx.?].content == .list_item);
                while (check_starts) {
                    check_starts = false;
                    inline for (spec_order) |kind| {
                        const spec_ctype = specCtype(kind);
                        const applies = if (last_match_idx == null)
                            spec_ctype == .block
                        else
                            self.containers.items[last_match_idx.?].content == spec_ctype;
                        if (applies) {
                            if (try self.openSpec(kind)) {
                                if (self.tip() != null) {
                                    self.last_matched_container = @intCast(self.containers.items.len - 1);
                                    last_match_idx = self.containers.items.len - 1;
                                    if (self.finished_line) {
                                        check_starts = false;
                                    } else {
                                        self.skipSpace();
                                        new_starts = true;
                                        const c = self.tip().?.content;
                                        check_starts = (c == .block or c == .list_item);
                                    }
                                }
                                break;
                            }
                        }
                    }
                }

                if (!self.finished_line) {
                    self.skipSpace();
                    is_blank = self.pos == self.starteol;
                    var t = self.tip();
                    const is_lazy = !is_blank and !new_starts and
                        self.last_matched_container < @as(isize, @intCast(self.containers.items.len)) - 1 and
                        t != null and t.?.content == .inline_;

                    if (!is_lazy) try self.closeUnmatchedContainers();
                    t = self.tip();

                    if (t == null or t.?.content == .block) {
                        if (is_blank) {
                            if (!new_starts) try self.addMatch(self.pos, self.endeol, .blankline);
                        } else {
                            try self.openPara();
                            t = self.tip();
                        }
                    }

                    if (t != null and t.?.content == .text) {
                        var startpos = self.pos;
                        if (self.indent > t.?.indent) {
                            startpos -= self.indent - t.?.indent;
                        }
                        try self.addMatch(startpos, self.endeol, .str);
                    } else if (t != null and t.?.content == .inline_ and !is_blank) {
                        if (self.tip().?.inline_parser) |*ip| {
                            try ip.feed(self.allocator, self.pos, self.endeol);
                        }
                    }
                }
            }

            // A blank line at block level is a separator and belongs to
            // neither side of it. Every other line — including a blank line
            // inside a code block, where it is body text — extends the
            // content the open containers own.
            const line_has_content = !self.lineIsBlank() or
                (self.tip() != null and self.tip().?.content == .text);
            self.pos = (if (self.endeol > 0 or self.pos == 0) self.endeol else self.pos) + 1;
            if (line_has_content) self.content_end = @min(self.pos, self.subject.len);
        }

        self.last_matched_container = -1;
        try self.closeUnmatchedContainers();
        return try self.matches.toOwnedSlice(self.allocator);
    }

    // ── spec dispatch ────────────────────────────────────────────────────

    const spec_order = [_]BlockKind{
        .block_quote,    .heading,    .caption,   .footnote, .reference_definition,
        .thematic_break, .list,       .list_item, .table,    .attributes,
        .fenced_div,     .code_block,
    };

    fn specCtype(kind: BlockKind) ContentType {
        return switch (kind) {
            .list_item => .list_item,
            else => .block,
        };
    }

    fn continueContainer(self: *Parser, idx: usize) Allocator.Error!bool {
        const kind = self.containers.items[idx].kind;
        return switch (kind) {
            .block_quote => self.continueBlockQuote(idx),
            .heading => self.continueHeading(idx),
            .caption => self.continueCaption(idx),
            .footnote => self.continueFootnote(idx),
            .reference_definition => self.continueReferenceDefinition(idx),
            .thematic_break => false,
            .list => self.continueList(idx),
            .list_item => self.continueListItem(idx),
            .table => self.continueTable(idx),
            .attributes => self.continueAttributes(idx),
            .fenced_div => self.continueFencedDiv(idx),
            .code_block => self.continueCodeBlock(idx),
            .para => self.continueParaSpec(),
        };
    }

    fn openSpec(self: *Parser, kind: BlockKind) Allocator.Error!bool {
        return switch (kind) {
            .block_quote => self.openBlockQuote(),
            .heading => self.openHeading(),
            .caption => self.openCaption(),
            .footnote => self.openFootnote(),
            .reference_definition => self.openReferenceDefinition(),
            .thematic_break => self.openThematicBreak(),
            .list => self.openList(),
            .list_item => self.openListItem(),
            .table => self.openTable(),
            .attributes => self.openAttributes(),
            .fenced_div => self.openFencedDiv(),
            .code_block => self.openCodeBlock(),
            // `para` is never in `spec_order` (it's the block-level
            // fallback opened directly by `scan`, not tried as a spec) --
            // this arm only exists so the switch stays exhaustive.
            .para => blk: {
                try self.openPara();
                break :blk true;
            },
        };
    }

    // ── para (not part of spec_order; opened as the block-level fallback) ─

    fn continueParaSpec(self: *Parser) bool {
        return self.find(self.pos) == null; // pattWhitespace: no whitespace at pos => continue
    }

    fn find(self: *const Parser, pos: usize) ?void {
        if (pos < self.subject.len and isWsAny(self.subject[pos])) return {};
        return null;
    }

    fn openPara(self: *Parser) Allocator.Error!void {
        try self.addContainer(.{ .kind = .para, .ctype = .block, .content = .inline_ }, false);
        try self.addMatch(self.pos, self.pos, .para_open);
    }

    fn closePara(self: *Parser, c: *Container) Allocator.Error!void {
        try self.getInlineMatchesFor(c);
        const ep = if (self.matches.items.len > 0) self.matches.items[self.matches.items.len - 1].end + 1 else self.pos;
        try self.addMatch(ep, ep, .para_close);
    }

    /// By the time a `close*` handler runs, the container has already been
    /// popped off the stack (see `closeContainer`) — so closers that need
    /// their own inline matches drain them from the popped container
    /// directly, rather than through `self.tip()`.
    fn getInlineMatchesFor(self: *Parser, c: *Container) Allocator.Error!void {
        if (c.inline_parser) |*ip| {
            // Borrowed from `ip` (the just-popped container's still-alive
            // inline parser); drained straight into `self.matches`, so no copy
            // and no free -- `ip` outlives this loop.
            const evs = try ip.finishMatches(self.allocator);
            for (evs) |m| {
                if (self.matches.items.len > 0) {
                    const last = &self.matches.items[self.matches.items.len - 1];
                    if (last.annot == .str and m.annot == .str and m.start == last.end + 1) {
                        last.end = m.end;
                        continue;
                    }
                }
                try self.matches.append(self.allocator, m);
            }
        }
    }

    // ── block_quote ──────────────────────────────────────────────────────

    /// `[>][ \t\r\n]` -- the `>` must be followed by whitespace (or the
    /// caller's line always ends in `\n`, so this never runs past the
    /// buffer).
    fn hasBlockquotePrefix(self: *const Parser) bool {
        return self.pos < self.subject.len and self.subject[self.pos] == '>' and
            self.pos + 1 < self.subject.len and isWsAny(self.subject[self.pos + 1]);
    }

    fn continueBlockQuote(self: *Parser, idx: usize) bool {
        _ = idx;
        if (self.hasBlockquotePrefix()) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn openBlockQuote(self: *Parser) Allocator.Error!bool {
        if (self.hasBlockquotePrefix()) {
            try self.addContainer(.{ .kind = .block_quote, .ctype = .block, .content = .block }, false);
            try self.addMatch(self.pos, self.pos, .block_quote_open);
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn closeBlockQuote(self: *Parser, c: *Container) Allocator.Error!void {
        _ = c;
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .block_quote_close);
    }

    // ── heading ──────────────────────────────────────────────────────────

    fn matchBangs(self: *const Parser, pos: usize) ?usize {
        var p = pos;
        while (p < self.subject.len and self.subject[p] == '#') p += 1;
        return if (p > pos) p else null;
    }

    fn continueHeading(self: *Parser, idx: usize) bool {
        const level = self.containers.items[idx].extra.level;
        if (self.matchBangs(self.pos)) |endp| {
            if (endp - self.pos == level and endp < self.subject.len and isWsAny(self.byteAt(endp))) {
                self.pos = endp;
                return true;
            }
        }
        return false;
    }

    fn openHeading(self: *Parser) Allocator.Error!bool {
        if (self.matchBangs(self.pos)) |endp| {
            if (endp < self.subject.len and isWsAny(self.byteAt(endp))) {
                const level: u32 = @intCast(endp - self.pos);
                try self.addContainer(.{ .kind = .heading, .ctype = .block, .content = .inline_, .extra = .{ .level = level } }, false);
                try self.addMatch(self.pos, endp - 1, .heading_open);
                self.pos = endp;
                return true;
            }
        }
        return false;
    }

    fn closeHeading(self: *Parser, c: *Container) Allocator.Error!void {
        try self.getInlineMatchesFor(c);
        const ep = if (self.matches.items.len > 0) self.matches.items[self.matches.items.len - 1].end + 1 else self.pos;
        try self.addMatch(ep, ep, .heading_close);
    }

    // ── caption ──────────────────────────────────────────────────────────

    fn continueCaption(self: *Parser, idx: usize) bool {
        _ = idx;
        return self.pos < self.subject.len and !isWsAny(self.subject[self.pos]);
    }

    fn openCaption(self: *Parser) Allocator.Error!bool {
        // "^" [ \t]+
        if (self.pos < self.subject.len and self.subject[self.pos] == '^') {
            var p = self.pos + 1;
            const start = p;
            while (p < self.subject.len and isSpaceOrTab(self.subject[p])) p += 1;
            if (p > start) {
                self.pos = p;
                try self.addContainer(.{ .kind = .caption, .ctype = .block, .content = .inline_ }, false);
                try self.addMatch(self.pos, self.pos, .caption_open);
                return true;
            }
        }
        return false;
    }

    fn closeCaption(self: *Parser, c: *Container) Allocator.Error!void {
        try self.getInlineMatchesFor(c);
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .caption_close);
    }

    // ── footnote ─────────────────────────────────────────────────────────

    /// `\[\^([^\]\r\n]*)\]:[ \t\r\n]`
    fn matchFootnoteStart(self: *const Parser, pos: usize) ?struct { end: usize, label: Slice } {
        var p = pos;
        if (self.byteAt(p) != '[') return null;
        p += 1;
        if (self.byteAt(p) != '^') return null;
        p += 1;
        const label_start = p;
        while (p < self.subject.len and self.subject[p] != ']' and self.subject[p] != '\r' and self.subject[p] != '\n') p += 1;
        const label_end = p;
        if (self.byteAt(p) != ']') return null;
        p += 1;
        if (self.byteAt(p) != ':') return null;
        p += 1;
        if (!isWsAny(self.byteAt(p))) return null;
        return .{ .end = p, .label = .{ .start = label_start, .end = label_end } };
    }

    fn continueFootnote(self: *Parser, idx: usize) bool {
        const c = &self.containers.items[idx];
        return self.indent > c.extra.indent or self.pos == self.starteol;
    }

    fn openFootnote(self: *Parser) Allocator.Error!bool {
        if (self.matchFootnoteStart(self.pos)) |m| {
            const sp = self.pos;
            try self.addContainer(.{
                .kind = .footnote,
                .ctype = .block,
                .content = .block,
                .extra = .{ .note_label = m.label, .indent = self.indent },
            }, false);
            try self.addMatch(sp, sp, .footnote_open);
            try self.addMatch(m.label.start, m.label.end -| 1, .note_label);
            self.pos = m.end;
            return true;
        }
        return false;
    }

    fn closeFootnote(self: *Parser, c: *Container) Allocator.Error!void {
        _ = c;
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .footnote_close);
    }

    // ── reference_definition ────────────────────────────────────────────

    /// `\[([^\]\r\n]*)\]:([ \t]+[^ \t\r\n]*|)[\r\n]`
    fn matchReferenceDefinition(self: *const Parser, pos: usize) ?struct { end: usize, label: Slice, value: Slice } {
        var p = pos;
        if (self.byteAt(p) != '[') return null;
        p += 1;
        const label_start = p;
        while (p < self.subject.len and self.subject[p] != ']' and self.subject[p] != '\r' and self.subject[p] != '\n') p += 1;
        const label_end = p;
        if (self.byteAt(p) != ']') return null;
        p += 1;
        if (self.byteAt(p) != ':') return null;
        p += 1;
        var value_start = p;
        var value_end = p;
        if (isSpaceOrTab(self.byteAt(p))) {
            var q = p;
            while (q < self.subject.len and isSpaceOrTab(self.subject[q])) q += 1;
            value_start = q;
            var r = q;
            while (r < self.subject.len and !isWsAny(self.subject[r])) r += 1;
            value_end = r;
            p = r;
        }
        if (!(self.byteAt(p) == '\r' or self.byteAt(p) == '\n')) return null;
        return .{ .end = p, .label = .{ .start = label_start, .end = label_end }, .value = .{ .start = value_start, .end = value_end } };
    }

    fn continueReferenceDefinition(self: *Parser, idx: usize) bool {
        const c = &self.containers.items[idx];
        if (c.extra.indent >= self.indent) return false;
        // pattNonWhitespace, then require it runs to end of line
        if (self.pos >= self.subject.len or isWsAny(self.subject[self.pos])) return false;
        var p = self.pos;
        while (p < self.subject.len and !isWsAny(self.subject[p])) p += 1;
        if (self.pos < self.starteol and p == self.starteol) {
            self.addMatchNoFail(self.pos, self.starteol -| 1, .reference_value);
            self.pos = self.starteol;
            return true;
        }
        return false;
    }

    /// `continue` in djot.js can't fail (it isn't given an allocator error
    /// path in the type signature) but ours can OOM; treat that as "doesn't
    /// continue" rather than threading `!bool` through the whole dispatch
    /// table for this one rare allocation.
    fn addMatchNoFail(self: *Parser, start: usize, end: usize, annot: Annotation) void {
        self.addMatch(start, end, annot) catch {};
    }

    fn openReferenceDefinition(self: *Parser) Allocator.Error!bool {
        if (self.matchReferenceDefinition(self.pos)) |m| {
            const sp = self.pos;
            try self.addContainer(.{
                .kind = .reference_definition,
                .ctype = .block,
                .content = .none,
                .extra = .{ .ref_key = m.label, .indent = self.indent },
            }, false);
            try self.addMatch(sp, sp, .reference_definition_open);
            try self.addMatch(sp, sp + (m.label.end - m.label.start) + 1, .reference_key);
            if (m.value.end > m.value.start) {
                try self.addMatch(self.starteol - (m.value.end - m.value.start), self.starteol -| 1, .reference_value);
            }
            self.pos = self.starteol -| 1;
            return true;
        }
        return false;
    }

    fn closeReferenceDefinition(self: *Parser, c: *Container) Allocator.Error!void {
        _ = c;
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .reference_definition_close);
    }

    // ── thematic_break ───────────────────────────────────────────────────

    /// `[-*][ \t]*[-*][ \t]*[-*][-* \t]*\r?\n`
    fn matchThematicBreak(self: *const Parser, pos: usize) ?usize {
        var p = pos;
        var count: usize = 0;
        while (count < 3) : (count += 1) {
            if (!(self.byteAt(p) == '-' or self.byteAt(p) == '*')) return null;
            p += 1;
            while (isSpaceOrTab(self.byteAt(p))) p += 1;
        }
        while (self.byteAt(p) == '-' or self.byteAt(p) == '*' or isSpaceOrTab(self.byteAt(p))) p += 1;
        if (self.byteAt(p) == '\r') p += 1;
        if (self.byteAt(p) != '\n') return null;
        return p; // position of '\n'
    }

    fn openThematicBreak(self: *Parser) Allocator.Error!bool {
        if (self.matchThematicBreak(self.pos)) |endp| {
            try self.addContainer(.{ .kind = .thematic_break, .ctype = .block, .content = .none }, false);
            try self.addMatch(self.pos, endp, .thematic_break);
            self.pos = endp;
            return true;
        }
        return false;
    }

    // note: thematic_break's own close() in djot.js just pops (no event);
    // handled generically since BlockKind.thematic_break isn't dispatched
    // to a closeX function in the switch above (see closeContainer).

    // ── list / list_item ────────────────────────────────────────────────

    /// Matches djot.js's `getListStyles`. `marker` must be the exact matched
    /// marker text (parens/delimiters included, no surrounding whitespace).
    fn getListStyles(marker: []const u8) ListStyleCandidates {
        if (marker.len == 1) {
            switch (marker[0]) {
                '-' => return .single(.dash),
                '+' => return .single(.plus),
                '*' => return .single(.star),
                ':' => return .single(.colon),
                else => {},
            }
        }
        if (marker.len == 5 and (marker[0] == '+' or marker[0] == '*' or marker[0] == '-') and
            marker[1] == ' ' and marker[2] == '[' and (marker[3] == 'X' or marker[3] == 'x' or marker[3] == ' ') and marker[4] == ']')
        {
            return .single(switch (marker[0]) {
                '+' => .plus_task,
                '-' => .dash_task,
                '*' => .star_task,
                else => unreachable,
            });
        }
        // Strip an optional leading '(' and a trailing '.'/')'/... for
        // classification, matching `[(]?...[).]` in each getListStyles regex.
        var s = marker;
        var has_paren = false;
        if (s.len > 0 and s[0] == '(') {
            has_paren = true;
            s = s[1..];
        }
        if (s.len == 0) return .{};
        const delim = s[s.len - 1];
        if (!(delim == '.' or delim == ')')) return .{};
        const inner = s[0 .. s.len - 1];
        if (inner.len == 0) return .{};

        const delimKind: ListMarkerStyle.Delim = if (has_paren) .paren_both else if (delim == ')') .paren_after else .period;

        if (allDigits(inner)) {
            return .single(.{ .ordered = .{ .numbering = .decimal, .delim = delimKind } });
        }
        if (inner.len == 1 and isRomanLower(inner[0])) {
            return .two(
                .{ .ordered = .{ .numbering = .lower_roman, .delim = delimKind } },
                .{ .ordered = .{ .numbering = .lower_alpha, .delim = delimKind } },
            );
        }
        if (inner.len == 1 and isRomanUpper(inner[0])) {
            return .two(
                .{ .ordered = .{ .numbering = .upper_roman, .delim = delimKind } },
                .{ .ordered = .{ .numbering = .upper_alpha, .delim = delimKind } },
            );
        }
        if (allRomanLower(inner)) {
            return .single(.{ .ordered = .{ .numbering = .lower_roman, .delim = delimKind } });
        }
        if (allRomanUpper(inner)) {
            return .single(.{ .ordered = .{ .numbering = .upper_roman, .delim = delimKind } });
        }
        if (inner.len == 1 and std.ascii.isLower(inner[0])) {
            return .single(.{ .ordered = .{ .numbering = .lower_alpha, .delim = delimKind } });
        }
        if (inner.len == 1 and std.ascii.isUpper(inner[0])) {
            return .single(.{ .ordered = .{ .numbering = .upper_alpha, .delim = delimKind } });
        }
        return .{};
    }

    fn allDigits(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |c| if (!isAsciiDigit(c)) return false;
        return true;
    }
    fn allRomanLower(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |c| if (!isRomanLower(c)) return false;
        return true;
    }
    fn allRomanUpper(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |c| if (!isRomanUpper(c)) return false;
        return true;
    }

    /// The full `pattListMarker` alternation, INCLUDING the required
    /// trailing whitespace character. Returns the marker's `[start,end)`
    /// (excluding the trailing whitespace) or null.
    fn matchListMarker(self: *const Parser, pos: usize) ?Slice {
        const s = self.subject;
        if (pos >= s.len) return null;
        var len: ?usize = null;

        // alt1: `:?[-*+:]` (see block.zig's module doc / getListStyles note
        // on why backtracking here collapses to this simple form).
        if (isMarkerClassChar(s[pos])) {
            if (s[pos] == ':' and pos + 1 < s.len and isMarkerClassChar(s[pos + 1])) {
                len = 2;
            } else {
                len = 1;
            }
        }

        if (len == null and s[pos] == '(') {
            // \([0-9]+\) or \([ivxlcdmIVXLCDM]+\) or \([a-zA-Z]\)
            var p = pos + 1;
            const digit_start = p;
            while (p < s.len and isAsciiDigit(s[p])) p += 1;
            if (p > digit_start and p < s.len and s[p] == ')') {
                len = p + 1 - pos;
            } else {
                p = pos + 1;
                const alpha_start = p;
                while (p < s.len and std.ascii.isAlphabetic(s[p])) p += 1;
                if (p > alpha_start and p < s.len and s[p] == ')') {
                    len = p + 1 - pos;
                }
            }
        }

        if (len == null and isAsciiDigit(s[pos])) {
            var p = pos;
            while (p < s.len and isAsciiDigit(s[p])) p += 1;
            if (p < s.len and (s[p] == '.' or s[p] == ')')) len = p + 1 - pos;
        }

        if (len == null and std.ascii.isAlphabetic(s[pos])) {
            var p = pos;
            while (p < s.len and std.ascii.isAlphabetic(s[p])) p += 1;
            if (p < s.len and (s[p] == '.' or s[p] == ')')) len = p + 1 - pos;
        }

        const l = len orelse return null;
        if (pos + l >= s.len or !isWsAny(s[pos + l])) return null;
        return .{ .start = pos, .end = pos + l };
    }

    fn isMarkerClassChar(c: u8) bool {
        return c == '-' or c == '*' or c == '+' or c == ':';
    }

    /// `[*+-] \[[Xx ]\]` (task marker; must start at the SAME position a
    /// plain list marker would).
    fn matchTaskListMarker(self: *const Parser, pos: usize) ?struct { checked: bool } {
        const s = self.subject;
        if (pos + 4 >= s.len) return null;
        if (!(s[pos] == '*' or s[pos] == '+' or s[pos] == '-')) return null;
        if (s[pos + 1] != ' ') return null;
        if (s[pos + 2] != '[') return null;
        const box = s[pos + 3];
        if (!(box == 'X' or box == 'x' or box == ' ')) return null;
        if (s[pos + 4] != ']') return null;
        if (pos + 5 >= s.len or !isWsAny(s[pos + 5])) return null;
        return .{ .checked = (box == 'X' or box == 'x') };
    }

    fn markerAndStyles(self: *const Parser, pos: usize) ?struct { marker: Slice, styles: ListStyleCandidates, checkbox: ?bool } {
        const m = self.matchListMarker(pos) orelse return null;
        if (self.matchTaskListMarker(pos)) |t| {
            const marker: Slice = .{ .start = pos, .end = pos + 5 };
            const text = self.subject[marker.start..marker.end];
            const styles = getListStyles(text);
            if (styles.isEmpty()) return null;
            return .{ .marker = marker, .styles = styles, .checkbox = t.checked };
        }
        const text = self.subject[m.start..m.end];
        const styles = getListStyles(text);
        if (styles.isEmpty()) return null;
        return .{ .marker = m, .styles = styles, .checkbox = null };
    }

    fn continueList(self: *Parser, idx: usize) bool {
        const c = &self.containers.items[idx];
        if (self.indent > c.extra.indent or self.pos == self.starteol) return true;
        const m = self.markerAndStyles(self.pos) orelse return false;
        const narrowed = c.extra.styles.intersect(m.styles);
        if (!narrowed.isEmpty()) {
            c.extra.styles = narrowed;
            return true;
        }
        return false;
    }

    fn openList(self: *Parser) Allocator.Error!bool {
        const m = self.markerAndStyles(self.pos) orelse return false;
        try self.addContainer(.{
            .kind = .list,
            .ctype = .block,
            .content = .list_item,
            .extra = .{ .styles = m.styles, .indent = self.indent },
        }, false);
        try self.addMatchStyled(m.marker.start, m.marker.end -| 1, .list_open, m.styles);
        return true;
    }

    fn closeList(self: *Parser, c: *Container) Allocator.Error!void {
        _ = c;
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .list_close);
    }

    fn continueListItem(self: *Parser, idx: usize) bool {
        const c = &self.containers.items[idx];
        return self.indent > c.extra.indent or self.pos == self.starteol;
    }

    fn openListItem(self: *Parser) Allocator.Error!bool {
        const m = self.markerAndStyles(self.pos) orelse return false;
        try self.addContainer(.{
            .kind = .list_item,
            .ctype = .list_item,
            .content = .block,
            .extra = .{ .styles = m.styles, .indent = self.indent },
        }, false);
        try self.addMatchStyled(m.marker.start, m.marker.end -| 1, .list_item_open, m.styles);
        self.pos = m.marker.end;
        if (m.checkbox) |checked| {
            try self.addMatch(m.marker.start + 2, m.marker.start + 4, if (checked) .checkbox_checked else .checkbox_unchecked);
            self.pos = m.marker.start + 5;
        }
        return true;
    }

    fn closeListItem(self: *Parser, c: *Container) Allocator.Error!void {
        _ = c;
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .list_item_close);
    }

    // ── table ────────────────────────────────────────────────────────────

    /// `(\|[^\r\n]*\|)[ \t]*\r?\n`
    fn matchTableRow(self: *const Parser, pos: usize) ?Slice {
        const s = self.subject;
        if (pos >= s.len or s[pos] != '|') return null;
        var p = pos + 1;
        var last_bar: ?usize = null;
        while (p < s.len and s[p] != '\r' and s[p] != '\n') : (p += 1) {
            if (s[p] == '|') last_bar = p;
        }
        const bar = last_bar orelse return null;
        var q = bar + 1;
        while (q < s.len and isSpaceOrTab(s[q])) q += 1;
        if (q < s.len and s[q] == '\r') q += 1;
        if (q >= s.len or s[q] != '\n') return null;
        return .{ .start = pos, .end = bar + 1 }; // row text is [start,end)
    }

    fn continueTable(self: *Parser, idx: usize) bool {
        _ = idx;
        const row = self.matchTableRow(self.pos) orelse return false;
        return self.parseTableRow(row.start, row.end -| 1) catch false;
    }

    fn openTable(self: *Parser) Allocator.Error!bool {
        const row = self.matchTableRow(self.pos) orelse return false;
        try self.addContainer(.{ .kind = .table, .ctype = .block, .content = .cells }, false);
        try self.addMatch(row.start, row.start, .table_open);
        if (try self.parseTableRow(row.start, row.end -| 1)) {
            return true;
        } else {
            _ = self.matches.pop();
            var c = self.containers.pop().?;
            c.deinit(self.allocator);
            return false;
        }
    }

    fn closeTable(self: *Parser, c: *Container) Allocator.Error!void {
        _ = c;
        const ep = self.contentEndMatch();
        try self.addMatch(ep, ep, .table_close);
    }

    /// `(:?)--*(:?)([ \t]*\|[ \t]*)` starting at `p`.
    fn matchRowSep(self: *const Parser, p: usize) ?struct { end: usize, left: bool, right: bool } {
        const s = self.subject;
        var q = p;
        var left = false;
        if (q < s.len and s[q] == ':') {
            left = true;
            q += 1;
        }
        const dash_start = q;
        while (q < s.len and s[q] == '-') q += 1;
        if (q == dash_start) return null;
        var right = false;
        if (q < s.len and s[q] == ':') {
            right = true;
            q += 1;
        }
        while (q < s.len and isSpaceOrTab(s[q])) q += 1;
        if (q >= s.len or s[q] != '|') return null;
        q += 1;
        while (q < s.len and isSpaceOrTab(s[q])) q += 1;
        return .{ .end = q, .left = left, .right = right };
    }

    fn parseTableRow(self: *Parser, sp: usize, ep: usize) Allocator.Error!bool {
        const orig_matches = self.matches.items.len;
        const startpos = self.pos;
        try self.addMatch(sp, sp, .row_open);
        self.pos += 1; // skip leading |

        var p = self.pos;
        var sepfound = false;
        var aligns = std.ArrayList(struct { start: usize, end: usize, left: bool, right: bool }).empty;
        defer aligns.deinit(self.allocator);
        while (!sepfound) {
            const m = self.matchRowSep(p) orelse break;
            try aligns.append(self.allocator, .{ .start = p, .end = m.end -| 1, .left = m.left, .right = m.right });
            p = m.end;
            if (p == self.starteol) {
                sepfound = true;
                break;
            }
        }
        if (sepfound) {
            for (aligns.items) |sep| {
                const annot: Annotation = if (sep.left and sep.right) .separator_center else if (sep.right) .separator_right else if (sep.left) .separator_left else .separator_default;
                // trim trailing "[ \t]*|[ \t]*" from the span, matching
                // upstream's `endpos - trailing.length`.
                var end = sep.end;
                while (end >= sep.start and (self.subject[end] == '|' or isSpaceOrTab(self.subject[end]))) {
                    if (end == 0) break;
                    end -= 1;
                }
                try self.addMatch(sep.start, end, annot);
            }
            try self.addMatch(self.starteol -| 1, self.starteol -| 1, .row_close);
            self.pos = self.starteol;
            self.finished_line = true;
            return true;
        }

        while (self.pos <= ep) {
            const cell = try self.parseTableCell() orelse {
                self.pos = startpos;
                self.matches.shrinkRetainingCapacity(orig_matches);
                return false;
            };
            defer self.allocator.free(cell.matches);
            try self.addMatch(cell.start, cell.start, .cell_open);
            for (cell.matches, 0..) |m, i| {
                var e = m.end;
                if (i == cell.matches.len - 1 and m.annot == .str) {
                    while (e >= m.start and e < self.subject.len and self.subject[e] == ' ') {
                        if (e == 0) break;
                        e -= 1;
                    }
                }
                try self.addMatch(m.start, e, m.annot);
            }
            try self.addMatch(cell.end, cell.end, .cell_close);
        }
        try self.addMatch(self.pos, self.pos, .row_close);
        self.pos = self.starteol;
        self.finished_line = true;
        return true;
    }

    /// `[^`|\r\n]*(?:[|]|`+)` -- scan to the next `|` or backtick run.
    fn findNextBarOrTicks(self: *const Parser, pos: usize) ?usize {
        var p = pos;
        const s = self.subject;
        while (p < s.len and s[p] != '`' and s[p] != '|' and s[p] != '\r' and s[p] != '\n') p += 1;
        if (p >= s.len) return null;
        if (s[p] == '|') return p;
        if (s[p] == '`') {
            while (p < s.len and s[p] == '`') p += 1;
            return p -| 1;
        }
        return null;
    }

    fn parseTableCell(self: *Parser) Allocator.Error!?struct { start: usize, end: usize, matches: []Event } {
        var ip = InlineParser.init(self.subject);
        defer ip.deinit(self.allocator);
        var cell_complete = false;
        const sp = self.pos -| 1;
        var ep = sp;
        self.skipSpace();
        while (!cell_complete) {
            const nextbar = self.findNextBarOrTicks(self.pos) orelse return null;
            if (self.subject[nextbar] == '`' or ip.inVerbatim()) {
                try ip.feed(self.allocator, self.pos, nextbar);
            } else if (nextbar > 0 and self.subject[nextbar - 1] == '\\') {
                try ip.feed(self.allocator, self.pos, nextbar);
            } else {
                try ip.feed(self.allocator, self.pos, nextbar -| 1);
                ep = nextbar;
                cell_complete = true;
            }
            self.pos = nextbar + 1;
        }
        const matches = try ip.getMatches(self.allocator);
        return .{ .start = sp, .end = ep, .matches = matches };
    }

    // ── attributes (block-level) ────────────────────────────────────────

    fn continueAttributes(self: *Parser, idx: usize) Allocator.Error!bool {
        const c = &self.containers.items[idx];
        if (c.extra.attr_status == .done) return false;
        if (c.extra.attr_parser != null and self.indent > c.extra.indent) {
            try c.extra.attr_slices.append(self.allocator, .{ .start = self.pos, .end = self.starteol });
            const res = try c.extra.attr_parser.?.feed(self.allocator, self.pos, self.endeol);
            c.extra.attr_status = res.status;
            if (res.status == .done) c.extra.attr_endpos = res.position;
            const fails_and_no_eol = res.status == .fail and !self.matchEndlineAt(res.position + 1);
            if (res.status != .fail or !fails_and_no_eol) {
                // (mirrors `res.status !== "fail" || !find(pattEndline, res.position+1)`)
            }
            if (res.status != .fail or self.matchEndlineAt(res.position + 1) == false) {
                self.pos = self.starteol;
                return true;
            }
        }
        // Attribute parsing failed or indentation ended: fall back to a
        // paragraph re-parsing everything we tried to read as attributes.
        try self.addMatch(c.extra.attr_startpos, c.extra.attr_startpos, .para_open);
        var popped = self.containers.pop().?;
        defer popped.deinit(self.allocator);
        try self.addContainer(.{ .kind = .para, .ctype = .block, .content = .inline_ }, true);
        var para = self.tip().?;
        if (para.inline_parser) |*ip| {
            for (popped.extra.attr_slices.items) |sl| {
                try ip.feed(self.allocator, sl.start, sl.end);
            }
            self.pos = ip.lastpos + 1;
        }
        return true;
    }

    fn matchEndlineAt(self: *const Parser, pos: usize) bool {
        var p = pos;
        while (p < self.subject.len and isSpaceOrTab(self.subject[p])) p += 1;
        if (p < self.subject.len and self.subject[p] == '\r') p += 1;
        return p < self.subject.len and self.subject[p] == '\n';
    }

    fn openAttributes(self: *Parser) Allocator.Error!bool {
        if (self.byteAt(self.pos) != '{') return false;
        var ap = AttributeParser.init(self.subject);
        const res = try ap.feed(self.allocator, self.pos, self.starteol);
        if (res.status == .fail) {
            ap.deinit(self.allocator);
            return false;
        }
        if (res.status == .done and !self.matchEndlineAt(res.position + 1)) {
            ap.deinit(self.allocator);
            return false;
        }
        var slices = std.ArrayList(Slice).empty;
        try slices.append(self.allocator, .{ .start = self.pos, .end = self.starteol });
        try self.addContainer(.{
            .kind = .attributes,
            .ctype = .block,
            .content = .attributes,
            .extra = .{
                .attr_parser = ap,
                .attr_status = res.status,
                .indent = self.indent,
                .attr_startpos = self.pos,
                .attr_endpos = if (res.status == .done) res.position else self.pos,
                .attr_slices = slices,
            },
        }, false);
        self.pos = self.starteol;
        return true;
    }

    fn closeAttributes(self: *Parser, c: *Container) Allocator.Error!void {
        if (c.extra.attr_status == .continue_) {
            try self.addMatch(c.extra.attr_startpos, c.extra.attr_startpos, .para_open);
            try self.addContainer(.{ .kind = .para, .ctype = .block, .content = .inline_ }, true);
            var para_idx = self.containers.items.len - 1;
            if (self.containers.items[para_idx].inline_parser) |*ip| {
                for (c.extra.attr_slices.items) |sl| {
                    try ip.feed(self.allocator, sl.start, sl.end);
                }
            }
            try self.closeContainer(para_idx);
            _ = &para_idx;
        } else {
            try self.addMatch(c.extra.attr_startpos, c.extra.attr_startpos, .block_attributes_open);
            if (c.extra.attr_parser) |*ap| {
                for (ap.matches.items) |m| try self.matches.append(self.allocator, m);
            }
            // The `}`, not `self.pos`: by the time the container closes the
            // parser has moved on, often to the start of the block the
            // attributes attach TO. `parser.zig` reads this position as the
            // block's end, and reads "not after the open" as "never closed".
            try self.addMatch(c.extra.attr_endpos, c.extra.attr_endpos, .block_attributes_close);
        }
    }

    // ── fenced_div ───────────────────────────────────────────────────────

    fn continueFencedDiv(self: *Parser, idx: usize) bool {
        if (self.tip()) |t| {
            if (t.kind == .code_block) return true; // see djot.js issue #109
        }
        const c = &self.containers.items[idx];
        // `(::::*)[ \t]*\r?\n`
        var p = self.pos;
        var colons: usize = 0;
        while (p < self.subject.len and self.subject[p] == ':') {
            p += 1;
            colons += 1;
        }
        if (colons >= 3) {
            var q = p;
            while (q < self.subject.len and isSpaceOrTab(self.subject[q])) q += 1;
            if (q < self.subject.len and self.subject[q] == '\r') q += 1;
            if (q < self.subject.len and self.subject[q] == '\n') {
                if (colons >= c.extra.colons) {
                    c.extra.end_fence = .{ .start = self.pos, .end = p -| 1 };
                    self.pos = q; // before newline
                    return false;
                }
            }
        }
        return true;
    }

    fn openFencedDiv(self: *Parser) Allocator.Error!bool {
        const s = self.subject;
        var p = self.pos;
        var colons: usize = 0;
        while (p < s.len and s[p] == ':') {
            p += 1;
            colons += 1;
        }
        if (colons < 3) return false;
        const fence_start = self.pos;
        const fence_end = p -| 1;
        var q = p;
        while (q < s.len and isSpaceOrTab(s[q])) q += 1;
        const lang_start = q;
        while (q < s.len and (std.ascii.isAlphanumeric(s[q]) or s[q] == '_' or s[q] == '-')) q += 1;
        const lang_end = q;
        var r = q;
        while (r < s.len and isSpaceOrTab(s[r])) r += 1;
        if (r < s.len and s[r] == '\r') r += 1;
        if (r >= s.len or s[r] != '\n') return false;

        try self.addContainer(.{ .kind = .fenced_div, .ctype = .block, .content = .block, .extra = .{ .colons = colons } }, false);
        try self.addMatch(fence_start, fence_end, .div_open);
        if (lang_end > lang_start) try self.addMatch(lang_start, lang_end -| 1, .class);
        self.pos = r;
        self.finished_line = true;
        return true;
    }

    fn closeFencedDiv(self: *Parser, c: *Container) Allocator.Error!void {
        // Unterminated: the div ends at its last content line, not wherever
        // the scan had reached when the enclosing container ran out.
        const sp = if (c.extra.end_fence) |f| f.start else self.contentEndMatch();
        const ep = if (c.extra.end_fence) |f| f.end else self.contentEndMatch();
        try self.addMatch(sp, ep, .div_close);
    }

    // ── code_block ───────────────────────────────────────────────────────

    /// `(~~~~*|` `` ` ``` `*)([ \t]*)([^ \t\r\n` `` `]*)[ \t]*\r?\n`
    fn matchCodeFence(self: *const Parser, pos: usize) ?struct { border: Slice, lang: Slice, is_raw: bool, line_end: usize } {
        const s = self.subject;
        if (pos >= s.len) return null;
        const ch = s[pos];
        if (ch != '~' and ch != '`') return null;
        var p = pos;
        while (p < s.len and s[p] == ch) p += 1;
        const border_len = p - pos;
        if (border_len < 3) return null;
        var q = p;
        while (q < s.len and isSpaceOrTab(s[q])) q += 1;
        const lang_start = q;
        while (q < s.len and s[q] != ' ' and s[q] != '\t' and s[q] != '\r' and s[q] != '\n' and s[q] != '`') q += 1;
        const lang_end = q;
        var r = q;
        while (r < s.len and isSpaceOrTab(s[r])) r += 1;
        if (r < s.len and s[r] == '\r') r += 1;
        if (r >= s.len or s[r] != '\n') return null;
        return .{
            .border = .{ .start = pos, .end = p },
            .lang = .{ .start = lang_start, .end = lang_end },
            .is_raw = lang_end > lang_start and s[lang_start] == '=',
            .line_end = r,
        };
    }

    fn matchCodeFenceClose(self: *const Parser, pos: usize, ch: u8, min_len: usize) ?struct { start: usize, end: usize, line_end: usize } {
        const s = self.subject;
        var p = pos;
        while (p < s.len and s[p] == ch) p += 1;
        const len = p - pos;
        if (len < min_len) return null;
        var q = p;
        while (q < s.len and isSpaceOrTab(s[q])) q += 1;
        if (q >= s.len or !(s[q] == '\r' or s[q] == '\n')) return null;
        return .{ .start = pos, .end = p -| 1, .line_end = q };
    }

    fn continueCodeBlock(self: *Parser, idx: usize) bool {
        const c = &self.containers.items[idx];
        if (self.matchCodeFenceClose(self.pos, c.extra.fence_char, c.extra.fence_len)) |m| {
            c.extra.end_fence = .{ .start = m.start, .end = m.end };
            self.pos = m.line_end;
            self.finished_line = true;
            return false;
        }
        return true;
    }

    fn openCodeBlock(self: *Parser) Allocator.Error!bool {
        const m = self.matchCodeFence(self.pos) orelse return false;
        const border_char = self.subject[m.border.start];
        const border_len = m.border.end - m.border.start;
        var cont = Container{
            .kind = .code_block,
            .ctype = .block,
            .content = .text,
            .extra = .{ .fence_char = border_char, .fence_len = border_len },
        };
        cont.indent = self.indent;
        try self.addContainer(cont, false);
        self.tip().?.indent = self.indent;
        try self.addMatch(m.border.start, m.border.end -| 1, .code_block_open);
        if (m.lang.end > m.lang.start) {
            const annot: Annotation = if (m.is_raw) .raw_format else .code_language;
            const lstart = if (m.is_raw) m.lang.start else m.lang.start;
            _ = lstart;
            try self.addMatch(m.lang.start, m.lang.end -| 1, annot);
        }
        self.pos = m.line_end;
        self.finished_line = true;
        return true;
    }

    fn closeCodeBlock(self: *Parser, c: *Container) Allocator.Error!void {
        // Unterminated: same as `closeFencedDiv` — stop at the last body line.
        const sp = if (c.extra.end_fence) |f| f.start else self.contentEndMatch();
        const ep = if (c.extra.end_fence) |f| f.end else self.contentEndMatch();
        try self.addMatch(sp, ep, .code_block_close);
    }
};

const testing = std.testing;

fn scanAll(allocator: Allocator, subject: []const u8) !struct { parser: Parser, events: []Event } {
    var p = try Parser.init(allocator, subject);
    const events = try p.scan();
    return .{ .parser = p, .events = events };
}

test "paragraph produces +para str -para" {
    var r = try scanAll(testing.allocator, "hello world\n");
    defer testing.allocator.free(r.events);
    defer r.parser.deinit();
    try testing.expect(r.events.len >= 3);
    try testing.expectEqual(Annotation.para_open, r.events[0].annot);
    try testing.expectEqual(Annotation.para_close, r.events[r.events.len - 1].annot);
}

test "heading level and thematic break" {
    var r = try scanAll(testing.allocator, "## Hi\n\n---\n");
    defer testing.allocator.free(r.events);
    defer r.parser.deinit();
    var saw_heading = false;
    var saw_tb = false;
    for (r.events) |e| {
        if (e.annot == .heading_open) saw_heading = true;
        if (e.annot == .thematic_break) saw_tb = true;
    }
    try testing.expect(saw_heading);
    try testing.expect(saw_tb);
}

test "bullet list with two items" {
    var r = try scanAll(testing.allocator, "- a\n- b\n");
    defer testing.allocator.free(r.events);
    defer r.parser.deinit();
    var opens: usize = 0;
    var item_opens: usize = 0;
    for (r.events) |e| {
        if (e.annot == .list_open) opens += 1;
        if (e.annot == .list_item_open) item_opens += 1;
    }
    try testing.expectEqual(@as(usize, 1), opens);
    try testing.expectEqual(@as(usize, 2), item_opens);
}

test "code block with language" {
    var r = try scanAll(testing.allocator, "```zig\nconst x = 1;\n```\n");
    defer testing.allocator.free(r.events);
    defer r.parser.deinit();
    var saw_lang = false;
    for (r.events) |e| {
        if (e.annot == .code_language) {
            saw_lang = true;
            try testing.expectEqualStrings("zig", r.parser.subject[e.start .. e.end + 1]);
        }
    }
    try testing.expect(saw_lang);
}

test "getListStyles classifies markers" {
    const dash = Parser.getListStyles("-");
    try testing.expectEqual(@as(u8, 1), dash.len);
    try testing.expect(dash.items[0].eql(.dash));

    const task = Parser.getListStyles("- [x]");
    try testing.expect(task.items[0].eql(.dash_task));

    const ambiguous = Parser.getListStyles("i.");
    try testing.expectEqual(@as(u8, 2), ambiguous.len);

    const decimal = Parser.getListStyles("12.");
    try testing.expectEqual(@as(u8, 1), decimal.len);
    try testing.expect(decimal.items[0].eql(.{ .ordered = .{ .numbering = .decimal, .delim = .period } }));

    const none = Parser.getListStyles("::");
    try testing.expectEqual(@as(u8, 0), none.len);
}
