//! Inline-level scanner: dispatches on "special" bytes and resolves
//! emphasis/strong/quotes/insert/delete/mark via a delimiter stack and
//! links/images/spans via a bracket stack. Ported from djot.js's
//! `src/inline.ts`.
//!
//! General strategy (from the upstream source comment): parse without
//! backtracking by keeping a stack of potential "openers" for links, images,
//! emphasis, and other inline containers. When a potential closer is found,
//! scan the matching opener stack; on a match, rewrite the placeholder event
//! already sitting at the opener's position into the real `_open` annotation
//! and append the `_close` annotation — no re-scanning needed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("event.zig");
const Event = event.Event;
const EventList = event.EventList;
const Annotation = event.Annotation;
const AttributeParser = @import("attributes.zig");

const Slice = struct { start: usize, end: usize };

const OpenerKind = enum {
    tilde,
    caret,
    underscore,
    asterisk,
    plus,
    equals,
    hyphen,
    squote,
    dquote,
    brace_tilde,
    brace_caret,
    brace_underscore,
    brace_asterisk,
    brace_plus,
    brace_equals,
    brace_hyphen,
    brace_squote,
    brace_dquote,
    bracket,
    paren,

    fn plain(c: u8) OpenerKind {
        return switch (c) {
            '~' => .tilde,
            '^' => .caret,
            '_' => .underscore,
            '*' => .asterisk,
            '+' => .plus,
            '=' => .equals,
            '-' => .hyphen,
            '\'' => .squote,
            '"' => .dquote,
            else => unreachable,
        };
    }

    fn braced(c: u8) OpenerKind {
        return switch (c) {
            '~' => .brace_tilde,
            '^' => .brace_caret,
            '_' => .brace_underscore,
            '*' => .brace_asterisk,
            '+' => .brace_plus,
            '=' => .brace_equals,
            '-' => .brace_hyphen,
            '\'' => .brace_squote,
            '"' => .brace_dquote,
            else => unreachable,
        };
    }
};

const LinkState = enum { none, reference_link, explicit_link };

const Opener = struct {
    match_index: usize,
    startpos: usize,
    endpos: usize,
    link_state: LinkState = .none,
    sub_match_index: usize = 0,
    substartpos: ?usize = null,
    subendpos: ?usize = null,
};

const VerbatimKind = enum {
    verbatim,
    inline_math,
    display_math,

    fn openAnnot(self: VerbatimKind) Annotation {
        return switch (self) {
            .verbatim => .verbatim_open,
            .inline_math => .inline_math_open,
            .display_math => .display_math_open,
        };
    }
    fn closeAnnot(self: VerbatimKind) Annotation {
        return switch (self) {
            .verbatim => .verbatim_close,
            .inline_math => .inline_math_close,
            .display_math => .display_math_close,
        };
    }
};

pub const InlineParser = struct {
    subject: []const u8,
    matches: EventList = .empty,
    openers: [20]std.ArrayList(Opener) = [_]std.ArrayList(Opener){.empty} ** 20,
    verbatim: usize = 0,
    verbatim_type: VerbatimKind = .verbatim,
    destination: bool = false,
    firstpos: ?usize = null,
    lastpos: usize = 0,
    allow_attributes: bool = true,
    attribute_parser: ?AttributeParser = null,
    attribute_start: ?usize = null,
    attribute_slices: ?std.ArrayList(Slice) = null,

    pub fn init(subject: []const u8) InlineParser {
        return .{ .subject = subject };
    }

    pub fn deinit(self: *InlineParser, allocator: Allocator) void {
        self.matches.deinit(allocator);
        for (&self.openers) |*stack| stack.deinit(allocator);
        if (self.attribute_parser) |*ap| ap.deinit(allocator);
        if (self.attribute_slices) |*sl| sl.deinit(allocator);
    }

    pub fn inVerbatim(self: *const InlineParser) bool {
        return self.verbatim > 0;
    }

    fn openers_(self: *InlineParser, k: OpenerKind) *std.ArrayList(Opener) {
        return &self.openers[@intFromEnum(k)];
    }

    fn addMatch(self: *InlineParser, allocator: Allocator, start: usize, end: usize, annot: Annotation) Allocator.Error!void {
        try self.matches.append(allocator, .{ .start = @intCast(start), .end = @intCast(end), .annot = annot });
    }

    fn replaceMatch(self: *InlineParser, index: usize, start: usize, end: usize, annot: Annotation) void {
        self.matches.items[index] = .{ .start = @intCast(start), .end = @intCast(end), .annot = annot };
    }

    fn addOpener(self: *InlineParser, allocator: Allocator, kind: OpenerKind, startpos: usize, endpos: usize, default_annot: Annotation) Allocator.Error!void {
        try self.openers_(kind).append(allocator, .{
            .match_index = self.matches.items.len,
            .startpos = startpos,
            .endpos = endpos,
            .sub_match_index = self.matches.items.len,
        });
        try self.addMatch(allocator, startpos, endpos, default_annot);
    }

    fn clearOpeners(self: *InlineParser, startpos: usize, endpos: usize) void {
        for (&self.openers) |*stack| {
            var i: isize = @as(isize, @intCast(stack.items.len)) - 1;
            while (i >= 0) : (i -= 1) {
                const idx: usize = @intCast(i);
                const o = &stack.items[idx];
                if (o.startpos >= startpos and o.endpos <= endpos) {
                    _ = stack.orderedRemove(idx);
                } else if (o.substartpos != null and o.substartpos.? >= startpos and o.subendpos != null and o.subendpos.? <= endpos) {
                    o.substartpos = null;
                    o.subendpos = null;
                    o.link_state = .none;
                } else break;
            }
        }
    }

    fn strMatches(self: *InlineParser, startpos: usize, endpos: usize) void {
        var i: isize = @as(isize, @intCast(self.matches.items.len)) - 1;
        while (i > 0 and self.matches.items[@intCast(i)].start >= startpos) : (i -= 1) {}
        if (self.matches.items[@intCast(i)].start < startpos) i += 1;
        while (i >= 0 and @as(usize, @intCast(i)) < self.matches.items.len and self.matches.items[@intCast(i)].end <= endpos) : (i += 1) {
            const m = &self.matches.items[@intCast(i)];
            if (m.annot != .escape and m.annot != .str) m.annot = .str;
        }
    }

    fn addImageMarker(self: *InlineParser, allocator: Allocator, opener: *Opener) Allocator.Error!void {
        const prev_idx_i: isize = @as(isize, @intCast(opener.match_index)) - 1;
        if (prev_idx_i >= 0) {
            const prev_idx: usize = @intCast(prev_idx_i);
            const prev = self.matches.items[prev_idx];
            if (prev.annot == .str and prev.start < opener.startpos - 1) {
                self.matches.items[prev_idx].end = @intCast(opener.startpos - 2);
                try self.matches.insert(allocator, prev_idx + 1, .{
                    .start = @intCast(opener.startpos - 1),
                    .end = @intCast(opener.startpos - 1),
                    .annot = .image_marker,
                });
                opener.match_index += 1;
                opener.sub_match_index += 1;
                return;
            }
        }
        self.replaceMatch(@intCast(prev_idx_i), opener.startpos - 1, opener.startpos - 1, .image_marker);
    }

    fn singleChar(self: *InlineParser, allocator: Allocator, pos: usize) Allocator.Error!usize {
        try self.addMatch(allocator, pos, pos, .str);
        return pos + 1;
    }

    fn reparseAttributes(self: *InlineParser, allocator: Allocator) Allocator.Error!void {
        var slices = self.attribute_slices orelse return;
        self.allow_attributes = false;
        if (self.attribute_parser) |*ap| ap.deinit(allocator);
        self.attribute_parser = null;
        self.attribute_start = null;
        for (slices.items) |sl| try self.feed(allocator, sl.start, sl.end);
        self.allow_attributes = true;
        slices.deinit(allocator);
        self.attribute_slices = null;
    }

    /// Finalize the match stream (trim a trailing soft break + spaces, close
    /// an unclosed verbatim span) and return an OWNED copy the caller must
    /// free. A copy (rather than borrowing `self.matches.items`) keeps
    /// lifetime simple: this `InlineParser` is typically `deinit`ed right
    /// after its container closes, before the caller is done with the
    /// events.
    /// Finalize the parser's events and return them as a BORROWED slice of
    /// the parser's own storage (valid until the parser is next mutated or
    /// deinited). The end-of-input fixups mutate `self.matches` in place: drop
    /// a trailing soft break (and any space it left on the preceding `str`),
    /// and close a still-open verbatim run. The block parser drains these
    /// immediately into its own event list, so it borrows rather than copies.
    pub fn finishMatches(self: *InlineParser, allocator: Allocator) Allocator.Error![]const Event {
        if (self.attribute_parser != null) try self.reparseAttributes(allocator);

        if (self.matches.items.len > 0 and self.matches.items[self.matches.items.len - 1].annot == .soft_break) {
            _ = self.matches.pop();
            if (self.matches.items.len > 0) {
                const m = &self.matches.items[self.matches.items.len - 1];
                if (m.annot == .str and m.end < self.subject.len and self.subject[m.end] == ' ') {
                    while (m.end >= m.start and self.subject[m.end] == ' ') {
                        if (m.end == 0) break;
                        m.end -= 1;
                    }
                    if (m.end < m.start) _ = self.matches.pop();
                }
            }
        }
        if (self.matches.items.len > 0 and self.verbatim > 0) {
            const last = self.matches.items[self.matches.items.len - 1];
            try self.addMatch(allocator, last.end, last.end, self.verbatim_type.closeAnnot());
        }
        return self.matches.items;
    }

    /// Owned copy of `finishMatches`, for callers (e.g. tests) that keep the
    /// events past the parser's lifetime.
    pub fn getMatches(self: *InlineParser, allocator: Allocator) Allocator.Error![]Event {
        return allocator.dupe(Event, try self.finishMatches(allocator));
    }

    // ── character classes / small matchers ─────────────────────────────

    fn isSpecial(c: u8) bool {
        return switch (c) {
            '\r', '\n', '"', '\'', '(', ')', '*', '+', '.', ':', '<', '=', '[', '\\', ']', '^', '_', '`', '$', '{', '}', '~', '-' => true,
            else => false,
        };
    }

    fn findSpecial(s: []const u8, pos: usize, endpos: usize) ?usize {
        var p = pos;
        while (p <= endpos and p < s.len) : (p += 1) {
            if (isSpecial(s[p])) return p;
        }
        return null;
    }

    fn isNonspace(c: u8) bool {
        return !(c == ' ' or c == '\t' or c == '\r' or c == '\n');
    }

    fn byteAt(self: *const InlineParser, pos: usize) u8 {
        return if (pos < self.subject.len) self.subject[pos] else 0;
    }

    fn hasNonspaceAt(self: *const InlineParser, pos: usize) bool {
        return pos < self.subject.len and isNonspace(self.subject[pos]);
    }

    fn isPunctuationByte(c: u8) bool {
        return switch (c) {
            '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', ']', '\\', '^', '_', '`', '{', '|', '}', '~' => true,
            else => false,
        };
    }

    fn hasBrace(self: *const InlineParser, pos: usize) bool {
        return (pos > 0 and self.byteAt(pos - 1) == '{') or self.byteAt(pos + 1) == '}';
    }

    fn alwaysTrue(self: *const InlineParser, pos: usize) bool {
        _ = self;
        _ = pos;
        return true;
    }

    fn quoteOpenTest(self: *const InlineParser, pos: usize) bool {
        if (pos == 0) return true;
        return switch (self.byteAt(pos - 1)) {
            ' ', '\t', '\r', '\n', '"', '\'', '-', '(', '[' => true,
            else => false,
        };
    }

    // ── betweenMatched: the shared delimiter-stack matcher ─────────────

    const OpenTest = *const fn (self: *const InlineParser, pos: usize) bool;

    fn betweenMatched(
        self: *InlineParser,
        allocator: Allocator,
        c: u8,
        open_annot: Annotation,
        close_annot: Annotation,
        default_annot: Annotation,
        opentest: OpenTest,
        pos: usize,
        endpos: usize,
    ) Allocator.Error!usize {
        var can_open = self.hasNonspaceAt(pos + 1) and opentest(self, pos);
        var can_close = pos > 0 and self.hasNonspaceAt(pos - 1);
        const has_open_marker = self.matches.items.len > 0 and self.matches.items[self.matches.items.len - 1].annot == .open_marker;
        const has_close_marker = pos + 1 <= endpos and self.byteAt(pos + 1) == '}';
        var endcloser = pos;
        var startopener = pos;
        var default_a = default_annot;

        if (has_open_marker) {
            can_open = true;
            can_close = false;
            startopener = pos -| 1;
        }
        if (!has_open_marker and has_close_marker) {
            can_close = true;
            can_open = false;
            endcloser = pos + 1;
        }

        default_a = flipDefaultAnnot(default_a, has_open_marker, has_close_marker);

        const opener_kind = if (has_close_marker) OpenerKind.braced(c) else OpenerKind.plain(c);
        const openers = self.openers_(opener_kind);

        if (can_close and openers.items.len > 0) {
            const opener = &openers.items[openers.items.len - 1];
            if (opener.endpos != pos -| 1 or pos == 0) {
                if (self.destination) {
                    const link_openers = self.openers_(.bracket);
                    if (link_openers.items.len > 0) {
                        const link_opener = link_openers.items[link_openers.items.len - 1];
                        if (link_opener.link_state == .explicit_link and opener.startpos < link_opener.startpos) {
                            try self.addMatch(allocator, pos, endcloser, default_a);
                            return endcloser + 1;
                        }
                    }
                }
                const opener_startpos = opener.startpos;
                const opener_endpos = opener.endpos;
                const opener_match_index = opener.match_index;
                self.clearOpeners(opener_startpos, pos);
                self.replaceMatch(opener_match_index, opener_startpos, opener_endpos, open_annot);
                try self.addMatch(allocator, pos, endcloser, close_annot);
                return endcloser + 1;
            }
        }

        if (can_open) {
            const e = if (has_open_marker) OpenerKind.braced(c) else OpenerKind.plain(c);
            try self.addOpener(allocator, e, startopener, pos, default_a);
            return pos + 1;
        } else {
            try self.addMatch(allocator, pos, endcloser, default_a);
            return endcloser + 1;
        }
    }

    fn flipDefaultAnnot(a: Annotation, has_open_marker: bool, has_close_marker: bool) Annotation {
        if (has_open_marker) {
            return switch (a) {
                .right_single_quote => .left_single_quote,
                .right_double_quote => .left_double_quote,
                else => a,
            };
        } else if (has_close_marker) {
            return switch (a) {
                .left_single_quote => .right_single_quote,
                .left_double_quote => .right_double_quote,
                else => a,
            };
        }
        return a;
    }

    // ── the main feed loop ──────────────────────────────────────────────

    pub fn feed(self: *InlineParser, allocator: Allocator, startpos: usize, endpos: usize) Allocator.Error!void {
        if (self.firstpos == null or startpos < self.firstpos.?) self.firstpos = startpos;
        if (self.lastpos == 0 or endpos > self.lastpos) self.lastpos = endpos;

        var pos = startpos;
        while (pos <= endpos) {
            if (self.attribute_parser != null) {
                const sp = pos;
                const ep2 = findSpecial(self.subject, pos, endpos) orelse endpos;
                const result = try self.attribute_parser.?.feed(allocator, sp, ep2);
                const ep = result.position;
                switch (result.status) {
                    .done => {
                        if (self.attribute_start) |astart| try self.addMatch(allocator, astart, astart, .attributes_open);
                        for (self.attribute_parser.?.matches.items) |m| {
                            try self.matches.append(allocator, m);
                        }
                        try self.addMatch(allocator, ep, ep, .attributes_close);
                        self.attribute_parser.?.deinit(allocator);
                        self.attribute_parser = null;
                        self.attribute_start = null;
                        if (self.attribute_slices) |*sl| sl.deinit(allocator);
                        self.attribute_slices = null;
                        pos = ep + 1;
                    },
                    .fail => {
                        try self.reparseAttributes(allocator);
                        pos = sp;
                    },
                    .continue_ => {
                        if (self.attribute_slices == null) self.attribute_slices = .empty;
                        try self.attribute_slices.?.append(allocator, .{ .start = sp, .end = ep });
                        pos = ep + 1;
                    },
                }
                continue;
            }

            const next_special = findSpecial(self.subject, pos, endpos);
            const newpos = next_special orelse endpos + 1;
            if (newpos > pos) {
                try self.addMatch(allocator, pos, newpos - 1, .str);
                pos = newpos;
                if (pos > endpos) break;
            }

            const c = self.subject[pos];
            if (c == '\r' or c == '\n') {
                if (c == '\r' and pos + 1 <= endpos and self.byteAt(pos + 1) == '\n') {
                    try self.addMatch(allocator, pos, pos + 1, .soft_break);
                    pos += 2;
                } else {
                    try self.addMatch(allocator, pos, pos, .soft_break);
                    pos += 1;
                }
            } else if (self.verbatim > 0) {
                pos = try self.feedVerbatimByte(allocator, pos, endpos, c);
            } else {
                pos = try self.dispatch(allocator, c, pos, endpos);
            }
        }
    }

    fn feedVerbatimByte(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize, c: u8) Allocator.Error!usize {
        if (c == '`') {
            var p = pos;
            while (p <= endpos and self.byteAt(p) == '`') p += 1;
            const endchar = p -| 1;
            if (p - pos == self.verbatim) {
                // check for a raw-attribute suffix `{=format}`
                if (matchRawAttribute(self.subject, endchar + 1, endpos)) |raw| {
                    if (self.verbatim_type == .verbatim) {
                        try self.addMatch(allocator, pos, endchar, self.verbatim_type.closeAnnot());
                        try self.addMatch(allocator, raw.start, raw.end, .raw_format);
                        self.verbatim = 0;
                        self.verbatim_type = .verbatim;
                        return raw.end + 1;
                    }
                }
                try self.addMatch(allocator, pos, endchar, self.verbatim_type.closeAnnot());
                self.verbatim = 0;
                self.verbatim_type = .verbatim;
                return endchar + 1;
            } else {
                try self.addMatch(allocator, pos, endchar, .str);
                return endchar + 1;
            }
        } else {
            try self.addMatch(allocator, pos, pos, .str);
            return pos + 1;
        }
    }

    /// `\{=[^\s{}` + "`" + `]+\}`
    fn matchRawAttribute(s: []const u8, pos: usize, endpos: usize) ?Slice {
        var p = pos;
        if (p > endpos or p + 1 >= s.len or s[p] != '{' or s[p + 1] != '=') return null;
        p += 2;
        const start = p;
        while (p <= endpos and p < s.len) : (p += 1) {
            const ch = s[p];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '{' or ch == '}' or ch == '`') break;
        }
        if (p == start) return null;
        if (p > endpos or p >= s.len or s[p] != '}') return null;
        return .{ .start = pos, .end = p };
    }

    fn dispatch(self: *InlineParser, allocator: Allocator, c: u8, pos: usize, endpos: usize) Allocator.Error!usize {
        return switch (c) {
            '`' => try self.matchBacktick(allocator, pos, endpos) orelse try self.singleChar(allocator, pos),
            '\\' => try self.matchBackslash(allocator, pos, endpos),
            '<' => try self.matchAutolink(allocator, pos, endpos) orelse try self.singleChar(allocator, pos),
            '~' => try self.betweenMatched(allocator, '~', .subscript_open, .subscript_close, .str, alwaysTrue, pos, endpos),
            '^' => try self.betweenMatched(allocator, '^', .superscript_open, .superscript_close, .str, alwaysTrue, pos, endpos),
            '_' => try self.betweenMatched(allocator, '_', .emph_open, .emph_close, .str, alwaysTrue, pos, endpos),
            '*' => try self.betweenMatched(allocator, '*', .strong_open, .strong_close, .str, alwaysTrue, pos, endpos),
            '+' => try self.betweenMatched(allocator, '+', .insert_open, .insert_close, .str, hasBrace, pos, endpos),
            '=' => try self.betweenMatched(allocator, '=', .mark_open, .mark_close, .str, hasBrace, pos, endpos),
            '\'' => try self.betweenMatched(allocator, '\'', .single_quoted_open, .single_quoted_close, .right_single_quote, quoteOpenTest, pos, endpos),
            '"' => try self.betweenMatched(allocator, '"', .double_quoted_open, .double_quoted_close, .left_double_quote, alwaysTrue, pos, endpos),
            '{' => try self.matchLeftBrace(allocator, pos, endpos),
            ':' => try self.matchColon(allocator, pos, endpos),
            '.' => try self.matchPeriod(allocator, pos, endpos) orelse try self.singleChar(allocator, pos),
            '[' => blk: {
                try self.addOpener(allocator, .bracket, pos, pos, .str);
                break :blk pos + 1;
            },
            ']' => try self.matchRightBracket(allocator, pos, endpos) orelse try self.singleChar(allocator, pos),
            '(' => try self.matchLeftParen(allocator, pos) orelse try self.singleChar(allocator, pos),
            ')' => try self.matchRightParen(allocator, pos, endpos) orelse try self.singleChar(allocator, pos),
            '-' => try self.matchHyphen(allocator, pos, endpos),
            '$' => try self.singleChar(allocator, pos),
            else => try self.singleChar(allocator, pos),
        };
    }

    fn matchBacktick(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!?usize {
        var p = pos;
        while (p <= endpos and self.byteAt(p) == '`') p += 1;
        const endchar = p -| 1;

        var dollar_escaped = false;
        if (self.matches.items.len >= 2) {
            const prev = self.matches.items[self.matches.items.len - 2];
            dollar_escaped = prev.annot == .escape and pos >= 2 and prev.end == pos - 2;
        }

        if (pos >= 2 and self.subject[pos - 2] == '$' and self.subject[pos - 1] == '$' and !(pos >= 3 and self.subject[pos - 3] == '\\')) {
            _ = self.matches.pop();
            _ = self.matches.pop();
            try self.addMatch(allocator, pos - 2, endchar, .display_math_open);
            self.verbatim_type = .display_math;
        } else if (pos >= 1 and self.subject[pos - 1] == '$' and !dollar_escaped) {
            _ = self.matches.pop();
            try self.addMatch(allocator, pos - 1, endchar, .inline_math_open);
            self.verbatim_type = .inline_math;
        } else {
            try self.addMatch(allocator, pos, endchar, .verbatim_open);
            self.verbatim_type = .verbatim;
        }
        self.verbatim = endchar - pos + 1;
        return endchar + 1;
    }

    fn matchBackslash(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!usize {
        if (matchLineEndAt(self.subject, pos + 1, endpos)) |line_end| {
            if (self.matches.items.len > 0) {
                const last = &self.matches.items[self.matches.items.len - 1];
                if (last.annot == .str) {
                    var ep: isize = @intCast(last.end);
                    const sp: isize = @intCast(last.start);
                    while (ep >= sp and (self.subject[@intCast(ep)] == ' ' or self.subject[@intCast(ep)] == '\t')) ep -= 1;
                    if (ep < sp) {
                        _ = self.matches.pop();
                    } else {
                        last.end = @intCast(ep);
                    }
                }
            }
            try self.addMatch(allocator, pos, pos, .escape);
            try self.addMatch(allocator, pos + 1, line_end, .hard_break);
            return line_end + 1;
        } else if (pos + 1 <= endpos and self.byteAt(pos + 1) < 0x80 and isPunctuationByte(self.byteAt(pos + 1))) {
            try self.addMatch(allocator, pos, pos, .escape);
            try self.addMatch(allocator, pos + 1, pos + 1, .str);
            return pos + 2;
        } else if (pos + 1 <= endpos and self.byteAt(pos + 1) == ' ') {
            try self.addMatch(allocator, pos, pos, .escape);
            try self.addMatch(allocator, pos + 1, pos + 1, .non_breaking_space);
            return pos + 2;
        } else {
            try self.addMatch(allocator, pos, pos, .str);
            return pos + 1;
        }
    }

    fn matchLineEndAt(s: []const u8, pos: usize, endpos: usize) ?usize {
        var p = pos;
        while (p <= endpos and p < s.len and (s[p] == ' ' or s[p] == '\t')) p += 1;
        if (p <= endpos and p < s.len and s[p] == '\r') p += 1;
        if (p <= endpos and p < s.len and s[p] == '\n') return p;
        return null;
    }

    pub const AutolinkKind = enum { url, email };

    /// What `<content>` spells, per djot's rule that an autolink is classified
    /// by its content alone: an `@` not preceded by `:` makes it an email (so
    /// `<mailto:a@b.dev>` is an *email*, not a url — the `mailto:` is part of
    /// the address), else a `letter:` anywhere makes it a url. Anything else is
    /// not an autolink at all and stays literal text.
    ///
    /// Split out of `matchAutolink` so a caller needing to know whether a string
    /// *would* spell an autolink — the C ABI's `insert_link`, choosing how to
    /// spell a link with no text — asks the scanner itself rather than
    /// re-deriving the rule and drifting from it.
    pub fn autolinkKindOf(content: []const u8) ?AutolinkKind {
        if (content.len == 0) return null;
        // The delimiters and any whitespace would have ended the scan below
        // before the classification ran, so they can't appear in a content
        // `matchAutolink` would accept.
        for (content) |c| if (c == '<' or c == '>' or isWsByte(c)) return null;
        if (containsNonColonAt(content)) return .email;
        if (containsSchemeColon(content)) return .url;
        return null;
    }

    fn matchAutolink(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!?usize {
        const s = self.subject;
        if (self.byteAt(pos) != '<') return null;
        var p = pos + 1;
        const start = p;
        while (p <= endpos and p < s.len and s[p] != '<' and s[p] != '>' and !isWsByte(s[p])) p += 1;
        if (p == start) return null;
        if (p > endpos or p >= s.len or s[p] != '>') return null;
        const content = s[start..p];
        const endurl = p;
        const starturl = pos;

        switch (autolinkKindOf(content) orelse return null) {
            .email => {
                try self.addMatch(allocator, starturl, starturl, .email_open);
                try self.addMatch(allocator, starturl + 1, endurl -| 1, .str);
                try self.addMatch(allocator, endurl, endurl, .email_close);
            },
            .url => {
                try self.addMatch(allocator, starturl, starturl, .url_open);
                try self.addMatch(allocator, starturl + 1, endurl -| 1, .str);
                try self.addMatch(allocator, endurl, endurl, .url_close);
            },
        }
        return endurl + 1;
    }

    fn isWsByte(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }

    /// `/[^:]@/` -- any `@` not immediately preceded by `:`.
    fn containsNonColonAt(s: []const u8) bool {
        for (s, 0..) |c, i| {
            if (c == '@' and i > 0 and s[i - 1] != ':') return true;
        }
        return false;
    }

    /// `/[a-zA-Z]:/` -- a letter immediately followed by `:`, anywhere.
    fn containsSchemeColon(s: []const u8) bool {
        if (s.len < 2) return false;
        for (0..s.len - 1) |i| {
            if (std.ascii.isAlphabetic(s[i]) and s[i + 1] == ':') return true;
        }
        return false;
    }

    fn matchLeftBrace(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!usize {
        if (matchesDelimAt(self.subject, pos + 1, endpos)) {
            try self.addMatch(allocator, pos, pos, .open_marker);
            return pos + 1;
        } else if (self.allow_attributes) {
            self.attribute_parser = AttributeParser.init(self.subject);
            self.attribute_start = pos;
            self.attribute_slices = .empty;
            return pos;
        } else {
            try self.addMatch(allocator, pos, pos, .str);
            return pos + 1;
        }
    }

    /// `[_*~^+='"-]` -- single char class, sticky at exactly `pos`.
    fn matchesDelimAt(s: []const u8, pos: usize, endpos: usize) bool {
        if (pos > endpos or pos >= s.len) return false;
        return switch (s[pos]) {
            '_', '*', '~', '^', '+', '=', '\'', '"', '-' => true,
            else => false,
        };
    }

    fn matchColon(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!usize {
        // `:[\w_+-]+:`
        const s = self.subject;
        var p = pos + 1;
        const start = p;
        while (p <= endpos and p < s.len and isSymbolChar(s[p])) p += 1;
        if (p > start and p <= endpos and p < s.len and s[p] == ':') {
            try self.addMatch(allocator, pos, p, .symb);
            return p + 1;
        }
        try self.addMatch(allocator, pos, pos, .str);
        return pos + 1;
    }

    fn isSymbolChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-';
    }

    fn matchPeriod(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!?usize {
        if (pos + 2 <= endpos and self.byteAt(pos + 1) == '.' and self.byteAt(pos + 2) == '.') {
            try self.addMatch(allocator, pos, pos + 2, .ellipses);
            return pos + 3;
        }
        return null;
    }

    fn matchRightBracket(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!?usize {
        const openers = self.openers_(.bracket);
        if (openers.items.len == 0) return null;
        var opener = &openers.items[openers.items.len - 1];
        const is_note_ref = self.byteAt(opener.startpos + 1) == '^';
        if (is_note_ref) {
            var i: isize = @as(isize, @intCast(self.matches.items.len)) - 1;
            while (i > 0 and self.matches.items[@intCast(i)].start > opener.startpos) {
                _ = self.matches.pop();
                i -= 1;
            }
            const opener_startpos = opener.startpos;
            self.clearOpeners(opener_startpos, pos);
            self.matches.items[@intCast(i)].annot = .footnote_reference;
            self.matches.items[@intCast(i)].end = @intCast(pos);
            return pos + 1;
        } else if (opener.link_state == .reference_link) {
            self.strMatches((if (opener.subendpos) |v| v else opener.endpos) + 1, pos -| 1);
            const is_image = opener.startpos >= 1 and self.byteAt(opener.startpos - 1) == '!' and
                !(opener.startpos >= 2 and self.byteAt(opener.startpos - 2) == '\\');
            const o_startpos = opener.startpos;
            const o_endpos = opener.endpos;
            const o_match_index = opener.match_index;
            const o_sub_match_index = opener.sub_match_index;
            const o_substartpos = opener.substartpos orelse opener.startpos;
            if (is_image) {
                try self.addImageMarker(allocator, opener);
                opener = &openers.items[openers.items.len - 1];
                self.replaceMatch(opener.match_index, o_startpos, o_endpos, .imagetext_open);
                self.replaceMatch(opener.sub_match_index, o_substartpos, o_substartpos, .imagetext_close);
            } else {
                self.replaceMatch(o_match_index, o_startpos, o_endpos, .linktext_open);
                self.replaceMatch(o_sub_match_index, o_substartpos, o_substartpos, .linktext_close);
            }
            const subendpos = opener.subendpos orelse opener.endpos;
            // Overwrites the second bracket's "str" placeholder (pushed
            // right after the first bracket's, hence `+ 1`) rather than
            // appending -- matches djot.js's `addMatch(..., "+reference",
            // opener.subMatchIndex + 1)`.
            self.replaceMatch(opener.sub_match_index + 1, subendpos, subendpos, .reference_open);
            try self.addMatch(allocator, pos, pos, .reference_close);
            self.clearOpeners(opener.startpos, pos);
            return pos + 1;
        } else if (pos + 1 <= endpos and self.byteAt(pos + 1) == '[') {
            opener.link_state = .reference_link;
            try self.addMatch(allocator, pos, pos, .str);
            opener.sub_match_index = self.matches.items.len - 1;
            try self.addMatch(allocator, pos + 1, pos + 1, .str);
            opener.substartpos = pos;
            opener.subendpos = pos + 1;
            self.clearOpeners(opener.startpos + 1, pos -| 1);
            return pos + 2;
        } else if (pos + 1 <= endpos and self.byteAt(pos + 1) == '(') {
            self.openers_(.paren).clearRetainingCapacity();
            opener.link_state = .explicit_link;
            try self.addMatch(allocator, pos, pos, .str);
            opener.sub_match_index = self.matches.items.len - 1;
            try self.addMatch(allocator, pos + 1, pos + 1, .str);
            opener.substartpos = pos;
            opener.subendpos = pos + 1;
            self.destination = true;
            self.clearOpeners(opener.startpos + 1, pos -| 1);
            return pos + 2;
        } else if (pos + 1 <= endpos and self.byteAt(pos + 1) == '{') {
            // Overwrites the `[`'s "str" placeholder rather than appending
            // -- matches djot.js's `addMatch(..., "+span", opener.matchIndex)`.
            self.replaceMatch(opener.match_index, opener.startpos, opener.endpos, .span_open);
            try self.addMatch(allocator, pos, pos, .span_close);
            self.clearOpeners(opener.startpos, pos);
            return pos + 1;
        }
        return null;
    }

    fn matchLeftParen(self: *InlineParser, allocator: Allocator, pos: usize) Allocator.Error!?usize {
        if (!self.destination) return null;
        try self.addOpener(allocator, .paren, pos, pos, .str);
        return pos + 1;
    }

    fn matchRightParen(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!?usize {
        _ = endpos;
        if (!self.destination) return null;
        const parens = self.openers_(.paren);
        if (parens.items.len > 0) {
            _ = parens.pop();
            try self.addMatch(allocator, pos, pos, .str);
            return pos + 1;
        }
        const openers = self.openers_(.bracket);
        if (openers.items.len == 0) return null;
        var opener = &openers.items[openers.items.len - 1];
        if (opener.link_state != .explicit_link) return null;

        self.strMatches((if (opener.subendpos) |v| v else opener.endpos) + 1, pos -| 1);
        const is_image = opener.startpos >= 1 and self.byteAt(opener.startpos - 1) == '!' and
            !(opener.startpos >= 2 and self.byteAt(opener.startpos - 2) == '\\');
        const o_startpos = opener.startpos;
        const o_endpos = opener.endpos;
        const o_match_index = opener.match_index;
        const o_sub_match_index = opener.sub_match_index;
        const o_substartpos = opener.substartpos orelse opener.startpos;
        if (is_image) {
            try self.addImageMarker(allocator, opener);
            opener = &openers.items[openers.items.len - 1];
            self.replaceMatch(opener.match_index, o_startpos, o_endpos, .imagetext_open);
            self.replaceMatch(opener.sub_match_index, o_substartpos, o_substartpos, .imagetext_close);
        } else {
            self.replaceMatch(o_match_index, o_startpos, o_endpos, .linktext_open);
            self.replaceMatch(o_sub_match_index, o_substartpos, o_substartpos, .linktext_close);
        }
        const subendpos = opener.subendpos orelse opener.endpos;
        // See the matching comment in `matchRightBracket`: overwrites the
        // `(`'s "str" placeholder rather than appending.
        self.replaceMatch(opener.sub_match_index + 1, subendpos, subendpos, .destination_open);
        try self.addMatch(allocator, pos, pos, .destination_close);
        self.destination = false;
        self.clearOpeners(opener.startpos, pos);
        return pos + 1;
    }

    fn matchHyphen(self: *InlineParser, allocator: Allocator, pos: usize, endpos: usize) Allocator.Error!usize {
        if (self.hasBrace(pos)) {
            const newpos = try self.betweenMatched(allocator, '-', .delete_open, .delete_close, .str, hasBrace, pos, endpos);
            return newpos;
        }
        var ep = pos;
        var hyphens: usize = 0;
        while (ep <= endpos and self.byteAt(ep) == '-') {
            ep += 1;
            hyphens += 1;
        }
        if (self.byteAt(ep) == '}') hyphens -= 1;
        if (hyphens == 0) {
            try self.addMatch(allocator, pos, pos + 1, .str);
            return pos + 2;
        }
        const all_em = hyphens % 3 == 0;
        const all_en = hyphens % 2 == 0;
        var p = pos;
        var remaining = hyphens;
        while (remaining > 0) {
            if (all_em) {
                try self.addMatch(allocator, p, p + 2, .em_dash);
                p += 3;
                remaining -= 3;
            } else if (all_en) {
                try self.addMatch(allocator, p, p + 1, .en_dash);
                p += 2;
                remaining -= 2;
            } else if (remaining >= 3 and (remaining % 2 != 0 or remaining > 4)) {
                try self.addMatch(allocator, p, p + 2, .em_dash);
                p += 3;
                remaining -= 3;
            } else if (remaining >= 2) {
                try self.addMatch(allocator, p, p + 1, .en_dash);
                p += 2;
                remaining -= 2;
            } else {
                try self.addMatch(allocator, p, p, .str);
                p += 1;
                remaining -= 1;
            }
        }
        return p;
    }
};

const testing = std.testing;

fn feedAll(allocator: Allocator, subject: []const u8) !struct { ip: InlineParser, events: []Event } {
    var ip = InlineParser.init(subject);
    try ip.feed(allocator, 0, subject.len - 1);
    const events = try ip.getMatches(allocator);
    return .{ .ip = ip, .events = events };
}

test "plain text becomes one str event" {
    var r = try feedAll(testing.allocator, "hello");
    defer testing.allocator.free(r.events);
    defer r.ip.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.events.len);
    try testing.expectEqual(Annotation.str, r.events[0].annot);
}

test "emphasis and strong" {
    var r = try feedAll(testing.allocator, "*foo bar*");
    defer testing.allocator.free(r.events);
    defer r.ip.deinit(testing.allocator);
    try testing.expectEqual(Annotation.strong_open, r.events[0].annot);
    try testing.expectEqual(Annotation.strong_close, r.events[r.events.len - 1].annot);

    var r2 = try feedAll(testing.allocator, "_foo bar_");
    defer testing.allocator.free(r2.events);
    defer r2.ip.deinit(testing.allocator);
    try testing.expectEqual(Annotation.emph_open, r2.events[0].annot);
    try testing.expectEqual(Annotation.emph_close, r2.events[r2.events.len - 1].annot);
}

test "verbatim span" {
    var r = try feedAll(testing.allocator, "`code`");
    defer testing.allocator.free(r.events);
    defer r.ip.deinit(testing.allocator);
    try testing.expectEqual(Annotation.verbatim_open, r.events[0].annot);
    try testing.expectEqual(Annotation.verbatim_close, r.events[r.events.len - 1].annot);
}

test "em dash and en dash" {
    var r = try feedAll(testing.allocator, "a---b--c");
    defer testing.allocator.free(r.events);
    defer r.ip.deinit(testing.allocator);
    var saw_em = false;
    var saw_en = false;
    for (r.events) |e| {
        if (e.annot == .em_dash) saw_em = true;
        if (e.annot == .en_dash) saw_en = true;
    }
    try testing.expect(saw_em);
    try testing.expect(saw_en);
}

test "explicit link" {
    var r = try feedAll(testing.allocator, "[text](http://example.com)");
    defer testing.allocator.free(r.events);
    defer r.ip.deinit(testing.allocator);
    var saw_linktext = false;
    var saw_dest = false;
    for (r.events) |e| {
        if (e.annot == .linktext_open) saw_linktext = true;
        if (e.annot == .destination_open) saw_dest = true;
    }
    try testing.expect(saw_linktext);
    try testing.expect(saw_dest);
}

