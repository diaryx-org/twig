//! Parser for the `{#id .class key=val key="value"}` attribute shorthand that
//! trails a generic directive (`inline.zig`'s text directives, `block.zig`'s
//! leaf/container directives). This is the Markdown module's OWN parser — it
//! deliberately does NOT reuse `languages/djot/attributes.zig`, whose
//! incremental state machine is wired into djot's event stream and its
//! multi-line block-attribute semantics. A directive's attributes always sit
//! on a single line, so this is a plain one-shot scan with no continuation
//! machinery.
//!
//! Grammar (a practical subset of `micromark-extension-directive`'s, which is
//! itself close to djot's `attributes.ts`):
//! ```
//! attributes <- '{' (ws* attribute)* ws* '}'
//! attribute  <- '#' name          # id
//!             | '.' name           # class (accumulates, space-joined)
//!             | name ('=' value)?  # key, or key=value ("" if bare)
//! name       <- (alnum | '-' | '_' | ':')+
//! value      <- '"' (! '"' | '\\"')* '"' | (! ws | '}' | '"')+
//! ```
//! Shorthand chaining without whitespace works (`{#id.a.b}`) because `.`/`#`
//! are not name characters, so each terminates the previous value.
//!
//! Results follow the shared `AST.Attrs` convention (see `ast.zig`): a single
//! ORDER-PRESERVING list where `class` accumulates at its first occurrence and
//! `id`/other keys are last-write-wins — so the shared HTML printer's
//! attribute merge treats a directive's attrs exactly like djot's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const KeyVal = AST.KeyVal;

/// A successfully-parsed attribute block. `entries` and every string they
/// point at are freshly allocated with the parse allocator; call `deinit`
/// once the entries have been handed to `Builder.setAttrs` (which copies
/// them into the AST's own owned storage).
pub const Parsed = struct {
    entries: []KeyVal,
    /// Byte index of the opening `{` — i.e. whatever `start` was passed to
    /// `parse`. Paired with `end` it is the block's range, which is what
    /// `Document.attrs_spans` records so a serializer can re-emit the author's
    /// bytes rather than the flattened `entries` projection.
    ///
    /// Relative to the `text` handed to `parse`, NOT to the whole source: this
    /// parser is handed indent-stripped lines. Callers rebase it (see
    /// `block.zig`'s `attrsSpanIn`).
    start: usize,
    /// Byte index just past the closing `}`.
    end: usize,

    pub fn deinit(self: Parsed, allocator: Allocator) void {
        for (self.entries) |kv| {
            allocator.free(kv.key);
            if (kv.value) |v| allocator.free(v);
        }
        allocator.free(self.entries);
    }
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// A directive name: an ASCII letter followed by name characters. Returns the
/// index just past the name, or `null` if `text[start]` can't begin one (used
/// to reject `:30`-style false positives — the name must start with a letter).
pub fn scanName(text: []const u8, start: usize) ?usize {
    if (start >= text.len or !std.ascii.isAlphabetic(text[start])) return null;
    var i = start + 1;
    while (i < text.len and isNameChar(text[i])) i += 1;
    return i;
}

const Accumulator = struct {
    allocator: Allocator,
    entries: std.ArrayList(KeyVal) = .empty,

    fn deinit(self: *Accumulator) void {
        for (self.entries.items) |kv| {
            self.allocator.free(kv.key);
            if (kv.value) |v| self.allocator.free(v);
        }
        self.entries.deinit(self.allocator);
    }

    fn find(self: *Accumulator, key: []const u8) ?usize {
        for (self.entries.items, 0..) |kv, idx| {
            if (std.mem.eql(u8, kv.key, key)) return idx;
        }
        return null;
    }

    /// Set `key` to `value` (owned copies), last-write-wins if the key already
    /// exists.
    fn set(self: *Accumulator, key: []const u8, value: ?[]const u8) Allocator.Error!void {
        const owned_val: ?[]const u8 = if (value) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (owned_val) |v| self.allocator.free(v);
        if (self.find(key)) |idx| {
            if (self.entries.items[idx].value) |old| self.allocator.free(old);
            self.entries.items[idx].value = owned_val;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_val });
    }

    /// Append `cls` to the `class` entry (space-joined at its first
    /// occurrence), creating it if absent.
    fn addClass(self: *Accumulator, cls: []const u8) Allocator.Error!void {
        if (self.find("class")) |idx| {
            const old = self.entries.items[idx].value orelse "";
            const joined = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ old, cls });
            errdefer self.allocator.free(joined);
            if (self.entries.items[idx].value) |v| self.allocator.free(v);
            self.entries.items[idx].value = joined;
            return;
        }
        try self.set("class", cls);
    }
};

/// Parse an attribute block whose opening `{` is at `text[start]`. Returns
/// `null` (consuming nothing) if `text[start]` is not `{` or the block is
/// malformed / unterminated — the caller then treats the `{` as literal text.
pub fn parse(allocator: Allocator, text: []const u8, start: usize) Allocator.Error!?Parsed {
    if (start >= text.len or text[start] != '{') return null;

    var acc = Accumulator{ .allocator = allocator };
    errdefer acc.deinit();

    var i = start + 1;
    while (i < text.len) {
        const c = text[i];
        if (isSpace(c)) {
            i += 1;
            continue;
        }
        if (c == '}') {
            const entries = try acc.entries.toOwnedSlice(allocator);
            return .{ .entries = entries, .start = start, .end = i + 1 };
        }
        if (c == '#') {
            const name_end = scanNameLoose(text, i + 1);
            if (name_end == i + 1) return fail(&acc); // empty id name
            try acc.set("id", text[i + 1 .. name_end]);
            i = name_end;
            continue;
        }
        if (c == '.') {
            const name_end = scanNameLoose(text, i + 1);
            if (name_end == i + 1) return fail(&acc); // empty class name
            try acc.addClass(text[i + 1 .. name_end]);
            i = name_end;
            continue;
        }
        if (isNameChar(c)) {
            const key_end = scanNameLoose(text, i);
            const key = text[i..key_end];
            i = key_end;
            if (i < text.len and text[i] == '=') {
                i += 1;
                const v = (try scanValue(allocator, text, i)) orelse return fail(&acc);
                defer allocator.free(v.text);
                try acc.set(key, v.text);
                i = v.end;
            } else {
                // Bare key (`{disabled}`): value "" (matches remark), NOT a
                // null/bare AST attribute.
                try acc.set(key, "");
            }
            continue;
        }
        return fail(&acc); // unexpected character
    }
    return fail(&acc); // reached end of text with no closing `}`
}

/// An id/class/key name run (name characters, possibly empty). Unlike
/// `scanName` this does NOT require a leading letter — id/class/key values are
/// allowed to start with a digit (`.2col`, `#4`), and emptiness is checked at
/// the call site.
fn scanNameLoose(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and isNameChar(text[i])) i += 1;
    return i;
}

const Value = struct { text: []u8, end: usize };

/// A value after `=`: a `"`-quoted string (with `\"`/`\\` escapes decoded) or
/// a bare run up to whitespace/`}`/`"`. Returns an owned decoded string, or
/// `null` if a quoted value is unterminated.
fn scanValue(allocator: Allocator, text: []const u8, start: usize) Allocator.Error!?Value {
    if (start < text.len and text[start] == '"') {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        var i = start + 1;
        while (i < text.len) {
            const c = text[i];
            if (c == '"') {
                const owned = try out.toOwnedSlice(allocator);
                return .{ .text = owned, .end = i + 1 };
            }
            if (c == '\\' and i + 1 < text.len and (text[i + 1] == '"' or text[i + 1] == '\\')) {
                try out.append(allocator, text[i + 1]);
                i += 2;
                continue;
            }
            try out.append(allocator, c);
            i += 1;
        }
        out.deinit(allocator);
        return null; // unterminated quoted value
    }
    var i = start;
    while (i < text.len and !isSpace(text[i]) and text[i] != '}' and text[i] != '"') i += 1;
    const owned = try allocator.dupe(u8, text[start..i]);
    return .{ .text = owned, .end = i };
}

fn fail(acc: *Accumulator) ?Parsed {
    acc.deinit();
    return null;
}

const testing = std.testing;

fn expectAttr(p: Parsed, key: []const u8, value: ?[]const u8) !void {
    for (p.entries) |kv| {
        if (std.mem.eql(u8, kv.key, key)) {
            if (value) |v| {
                try testing.expectEqualStrings(v, kv.value orelse return error.TestExpectedNonNull);
            } else {
                try testing.expectEqual(@as(?[]const u8, null), kv.value);
            }
            return;
        }
    }
    return error.TestAttrNotFound;
}

test "id, classes, keyvals; classes accumulate space-joined" {
    const subject = "{#hero .a .b key=val other=\"a b\"}";
    const p = (try parse(testing.allocator, subject, 0)) orelse return error.TestExpectedNonNull;
    defer p.deinit(testing.allocator);
    try testing.expectEqual(subject.len, p.end);
    try expectAttr(p, "id", "hero");
    try expectAttr(p, "class", "a b");
    try expectAttr(p, "key", "val");
    try expectAttr(p, "other", "a b");
}

test "shorthand chaining without spaces" {
    const p = (try parse(testing.allocator, "{#x.a.b}", 0)) orelse return error.TestExpectedNonNull;
    defer p.deinit(testing.allocator);
    try expectAttr(p, "id", "x");
    try expectAttr(p, "class", "a b");
}

test "bare key becomes empty-string value" {
    const p = (try parse(testing.allocator, "{disabled}", 0)) orelse return error.TestExpectedNonNull;
    defer p.deinit(testing.allocator);
    try expectAttr(p, "disabled", "");
}

test "quoted value with escaped quote" {
    const p = (try parse(testing.allocator, "{title=\"a \\\"b\\\" c\"}", 0)) orelse return error.TestExpectedNonNull;
    defer p.deinit(testing.allocator);
    try expectAttr(p, "title", "a \"b\" c");
}

test "last-write-wins for id and plain keys" {
    const p = (try parse(testing.allocator, "{#a #b k=1 k=2}", 0)) orelse return error.TestExpectedNonNull;
    defer p.deinit(testing.allocator);
    try expectAttr(p, "id", "b");
    try expectAttr(p, "k", "2");
}

test "unterminated block and unterminated quote both fail cleanly" {
    try testing.expectEqual(@as(?Parsed, null), try parse(testing.allocator, "{#a .b", 0));
    try testing.expectEqual(@as(?Parsed, null), try parse(testing.allocator, "{k=\"oops}", 0));
    try testing.expectEqual(@as(?Parsed, null), try parse(testing.allocator, "not an attr", 0));
}

test "empty block is valid and yields no entries" {
    const p = (try parse(testing.allocator, "{}", 0)) orelse return error.TestExpectedNonNull;
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), p.entries.len);
    try testing.expectEqual(@as(usize, 2), p.end);
}
