//! The colour vocabulary of `==🔴 text==` — Obsidian's coloured highlights
//! (`ParseOptions.highlight_colors`, on top of `ParseOptions.highlight`).
//!
//! A large-circle emoji immediately after the opening `==` names the
//! highlight's colour. Obsidian 1.14 reads 🔴 🟠 🟢 🔵 🟣; this table is the
//! whole Unicode large-circle family (yellow and brown too), because a
//! document that writes `==🟡 x==` means the same thing by it. The emoji is
//! SPELLING: it is not part of the highlighted text, so the parser strips it
//! and records the colour as a `data-color` attribute on the `mark` node
//! (`attr_key`), which the HTML printer emits as `<mark data-color="red">`,
//! selectors match as `mark[data-color=red]`, and the Markdown serializer
//! spells back as the emoji. An optional single space after the emoji is part
//! of the prefix — `==🔴 text==` and `==🔴text==` are the same highlight —
//! and which form was written is kept in `Document.Spelling.highlight_prefix`
//! so a round-trip reproduces it.
//!
//! The medium circles ⚫/⚪ (U+26AB/U+26AA) are deliberately absent: they are
//! a different Unicode block, render as text rather than emoji without a
//! variation selector, and name no highlight colour anyone uses.

const std = @import("std");

/// The attribute the colour rides in, on the `mark` node.
pub const attr_key = "data-color";

pub const Color = enum {
    red,
    orange,
    yellow,
    green,
    blue,
    purple,
    brown,

    /// The attribute value, and what `fromName` reads back.
    pub fn name(self: Color) []const u8 {
        return @tagName(self);
    }

    /// The emoji that spells this colour — one code point, four UTF-8 bytes.
    pub fn emoji(self: Color) []const u8 {
        return switch (self) {
            .red => "\u{1F534}",
            .orange => "\u{1F7E0}",
            .yellow => "\u{1F7E1}",
            .green => "\u{1F7E2}",
            .blue => "\u{1F535}",
            .purple => "\u{1F7E3}",
            .brown => "\u{1F7E4}",
        };
    }

    pub fn fromName(s: []const u8) ?Color {
        return std.meta.stringToEnum(Color, s);
    }
};

/// A colour prefix read off the front of a highlight's content.
pub const Prefix = struct {
    color: Color,
    /// Whether a single space followed the emoji (and was absorbed).
    spaced: bool,
    /// Byte length of the whole prefix: the emoji plus the space, if any.
    len: usize,
};

/// Read a colour prefix at the very start of `s` — a large-circle emoji, then
/// at most one ASCII space. `null` if `s` starts with anything else.
pub fn parsePrefix(s: []const u8) ?Prefix {
    inline for (std.enums.values(Color)) |c| {
        const e = c.emoji();
        if (std.mem.startsWith(u8, s, e)) {
            const spaced = s.len > e.len and s[e.len] == ' ';
            return .{ .color = c, .spaced = spaced, .len = e.len + @intFromBool(spaced) };
        }
    }
    return null;
}

const testing = std.testing;

test "parsePrefix reads each circle, with and without a trailing space" {
    for (std.enums.values(Color)) |c| {
        var buf: [16]u8 = undefined;
        const tight = try std.fmt.bufPrint(&buf, "{s}x", .{c.emoji()});
        const p = parsePrefix(tight).?;
        try testing.expectEqual(c, p.color);
        try testing.expect(!p.spaced);
        try testing.expectEqual(c.emoji().len, p.len);

        var buf2: [16]u8 = undefined;
        const spaced = try std.fmt.bufPrint(&buf2, "{s} x", .{c.emoji()});
        const q = parsePrefix(spaced).?;
        try testing.expectEqual(c, q.color);
        try testing.expect(q.spaced);
        try testing.expectEqual(c.emoji().len + 1, q.len);
    }
}

test "parsePrefix refuses other emoji, a leading space, and the medium circles" {
    try testing.expect(parsePrefix("\u{1F34E} x") == null); // 🍎
    try testing.expect(parsePrefix(" \u{1F534}x") == null);
    try testing.expect(parsePrefix("\u{26AB}x") == null); // ⚫
    try testing.expect(parsePrefix("x") == null);
    try testing.expect(parsePrefix("") == null);
}

test "only one space is absorbed" {
    const p = parsePrefix("\u{1F534}  x").?;
    try testing.expect(p.spaced);
    try testing.expectEqual(@as(usize, 5), p.len);
}

test "names round-trip" {
    for (std.enums.values(Color)) |c| try testing.expectEqual(c, Color.fromName(c.name()).?);
    try testing.expect(Color.fromName("pink") == null);
}
