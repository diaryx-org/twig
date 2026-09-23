//! A `Syntax` written down as JSON, and read back.
//!
//! ── Why ─────────────────────────────────────────────────────────────────────
//! A runtime language that authors has to hand core the table its gestures
//! read, and it cannot hand over a Zig struct. So `Syntax` crosses the same
//! boundary the node table does (`ast/table.zig`), as data, and the compiled
//! formats cross it first: every compiled table, encoded and decoded, is the
//! table it was. That identity is what makes the encoding a contract rather
//! than a description of one.
//!
//! ── The shape ──────────────────────────────────────────────────────────────
//! One object, keyed by `Syntax`'s field names, which are already the
//! snake_case a description is written in. The encoding is DERIVED from the
//! struct rather than written beside it, so a field added to `Syntax` is in
//! the encoding the moment it exists, and the identity test fails until it
//! round-trips:
//!
//!   * a byte string is a JSON string; a single byte (`heading_marker`,
//!     `code_fence.char`) is a one-byte string, since `"#"` is what a person
//!     means and `35` is not;
//!   * an enum is its tag name, a flag a bool, a count an integer;
//!   * an `EnumArray` is an object keyed by the enum's tag names — a table of
//!     optionals names only the keys it spells, a table of values names all;
//!   * a nested struct is an object, and a list of them an array;
//!   * a member left at its default is omitted, and a member omitted takes its
//!     default, so `{}` is `syntax.none` and a description states only what
//!     it spells.
//!
//! The three renderers are functions, and a function does not cross. What
//! crosses is which ones the language answers itself, as `renderers`: any of
//! `render_text`, `render_block` and `spells_autolink`. A table that states
//! `text_escapes` renders literals by that alphabet — `renderTextByAlphabet`,
//! which core has — so it names no `render_text`, exactly as a compiled table
//! that points at that function states nothing else. Binding the named ones
//! to something callable is the caller's: the identity test binds the
//! compiled functions back, and a runtime language binds calls to itself.
//!
//! Decoding does not validate — `Syntax.validate` does, once the renderers
//! are bound, since two of its rules are about them. Decoding refuses what is
//! not a `Syntax` at all: an unknown key, a value of the wrong type, a byte
//! that is not one byte, a missing member that has no default. A refusal
//! fills a `Problem` with the key path at fault.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

const syntax = @import("syntax.zig");
const Syntax = syntax.Syntax;

/// Which renderers a table's language answers itself — the part of a
/// `Syntax` that crosses as names rather than values.
pub const Renderers = struct {
    render_text: bool = false,
    render_block: bool = false,
    spells_autolink: bool = false,

    /// What `s` answers itself: every renderer it carries, except the
    /// alphabet renderer, which its `text_escapes` already says.
    pub fn of(s: *const Syntax) Renderers {
        return .{
            .render_text = s.renderText != null and s.renderText != &syntax.renderTextByAlphabet,
            .render_block = s.renderBlock != null,
            .spells_autolink = s.spellsAutolink != null,
        };
    }
};

/// A decoded table: every spelling, the alphabet renderer bound where an
/// alphabet is stated, and the other renderers named but unbound.
pub const Decoded = struct {
    syntax: Syntax,
    renderers: Renderers,
};

/// Why a description's `syntax` was refused: the key path at fault
/// (`container_spelling.block_quote.marker`), and what is wrong with it.
pub const Problem = struct {
    path: []const u8 = "",
    what: []const u8 = "",
};

pub const Options = struct {
    pretty: bool = true,
};

// ── Encoding ────────────────────────────────────────────────────────────────

pub fn encode(writer: *Writer, s: *const Syntax, options: Options) Writer.Error!void {
    var w: Stringify = .{ .writer = writer, .options = .{ .whitespace = if (options.pretty) .indent_2 else .minified } };
    try w.beginObject();
    try writeMembers(&w, Syntax, s.*);
    const r = Renderers.of(s);
    if (r.render_text or r.render_block or r.spells_autolink) {
        try w.objectField("renderers");
        try w.beginArray();
        inline for (std.meta.fields(Renderers)) |f| {
            if (@field(r, f.name)) try w.write(f.name);
        }
        try w.endArray();
    }
    try w.endObject();
}

pub fn encodeAlloc(allocator: Allocator, s: *const Syntax, options: Options) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    encode(&out.writer, s, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Whether `T` is a function pointer, or an optional one — a renderer, which
/// the encoding names rather than carries.
fn isFunction(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| isFunction(o.child),
        .pointer => |p| @typeInfo(p.child) == .@"fn",
        else => false,
    };
}

fn isEnumArray(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Indexer") and @hasDecl(T, "Value") and @hasField(T, "values");
}

fn writeMembers(w: *Stringify, comptime T: type, v: T) Writer.Error!void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime isFunction(f.type)) continue;
        const value = @field(v, f.name);
        const at_default = if (f.defaultValue()) |d| eqlValue(f.type, value, d) else false;
        if (!at_default) {
            try w.objectField(f.name);
            try writeValue(w, f.type, value);
        }
    }
}

fn writeValue(w: *Stringify, comptime T: type, v: T) Writer.Error!void {
    if (T == u8) return w.write(&[_]u8{v});
    if (comptime isEnumArray(T)) {
        try w.beginObject();
        for (std.enums.values(T.Key)) |k| {
            const item = v.get(k);
            if (@typeInfo(T.Value) == .optional and item == null) continue;
            try w.objectField(@tagName(k));
            try writeValue(w, T.Value, item);
        }
        return w.endObject();
    }
    switch (@typeInfo(T)) {
        .bool, .int => try w.write(v),
        .@"enum" => try w.write(@tagName(v)),
        .optional => |o| if (v) |inner| try writeValue(w, o.child, inner) else try w.write(null),
        .pointer => |p| {
            if (p.child == u8) return w.write(v);
            try w.beginArray();
            for (v) |item| try writeValue(w, p.child, item);
            try w.endArray();
        },
        .@"struct" => {
            try w.beginObject();
            try writeMembers(w, T, v);
            try w.endObject();
        },
        else => @compileError("no JSON spelling for " ++ @typeName(T)),
    }
}

// ── Equality ────────────────────────────────────────────────────────────────

/// Two tables spell the same: every byte string equal by content, every
/// renderer the same function. What the identity is stated in.
pub fn eql(a: *const Syntax, b: *const Syntax) bool {
    return eqlValue(Syntax, a.*, b.*);
}

fn eqlValue(comptime T: type, a: T, b: T) bool {
    if (comptime isEnumArray(T)) {
        for (std.enums.values(T.Key)) |k| {
            if (!eqlValue(T.Value, a.get(k), b.get(k))) return false;
        }
        return true;
    }
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => a == b,
        .optional => |o| if (a) |x| (if (b) |y| eqlValue(o.child, x, y) else false) else b == null,
        .pointer => |p| blk: {
            if (@typeInfo(p.child) == .@"fn") break :blk a == b;
            if (a.len != b.len) break :blk false;
            for (a, b) |x, y| {
                if (!eqlValue(p.child, x, y)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => blk: {
            inline for (std.meta.fields(T)) |f| {
                if (!eqlValue(f.type, @field(a, f.name), @field(b, f.name))) break :blk false;
            }
            break :blk true;
        },
        else => @compileError("no equality for " ++ @typeName(T)),
    };
}

// ── Decoding ────────────────────────────────────────────────────────────────

pub const Error = error{ InvalidSyntax, OutOfMemory };

/// Read a `Syntax` from its JSON value. Strings are copied into `arena`,
/// which owns the result. The alphabet renderer is bound where `text_escapes`
/// is stated; the renderers `renderers` names are left null for the caller.
pub fn fromValue(arena: Allocator, value: std.json.Value, problem: *Problem) Error!Decoded {
    var r: Reader = .{ .arena = arena, .problem = problem };
    const obj = switch (value) {
        .object => |o| o,
        else => return r.fail("", "is not an object"),
    };
    var decoded: Decoded = .{ .syntax = try r.members(Syntax, obj, "", &.{"renderers"}), .renderers = .{} };
    if (obj.get("renderers")) |list| {
        const items = switch (list) {
            .array => |a| a.items,
            else => return r.fail("renderers", "is not an array"),
        };
        for (items) |item| {
            const name = switch (item) {
                .string => |n| n,
                else => return r.fail("renderers", "holds a value that is not a renderer's name"),
            };
            inline for (std.meta.fields(Renderers)) |f| {
                if (std.mem.eql(u8, name, f.name)) {
                    @field(decoded.renderers, f.name) = true;
                    break;
                }
            } else return r.fail("renderers", "names a renderer that is not render_text, render_block or spells_autolink");
        }
    }
    if (decoded.syntax.text_escapes != null) decoded.syntax.renderText = &syntax.renderTextByAlphabet;
    return decoded;
}

/// `fromValue` over JSON text.
pub fn decode(arena: Allocator, text: []const u8, problem: *Problem) Error!Decoded {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            problem.* = .{ .what = "is not JSON" };
            return error.InvalidSyntax;
        },
    };
    return fromValue(arena, value, problem);
}

const Reader = struct {
    arena: Allocator,
    problem: *Problem,

    fn fail(self: *Reader, path: []const u8, what: []const u8) Error {
        self.problem.* = .{ .path = path, .what = what };
        return error.InvalidSyntax;
    }

    fn join(self: *Reader, path: []const u8, key: []const u8) Error![]const u8 {
        if (path.len == 0) return self.arena.dupe(u8, key);
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, key });
    }

    fn members(
        self: *Reader,
        comptime T: type,
        obj: std.json.ObjectMap,
        path: []const u8,
        comptime ignore: []const []const u8,
    ) Error!T {
        var out: T = undefined;
        inline for (std.meta.fields(T)) |f| {
            if (comptime isFunction(f.type)) {
                @field(out, f.name) = f.defaultValue().?;
            } else if (obj.get(f.name)) |v| {
                @field(out, f.name) = try self.value(f.type, v, try self.join(path, f.name));
            } else if (f.defaultValue()) |d| {
                @field(out, f.name) = d;
            } else {
                return self.fail(try self.join(path, f.name), "is missing, and has no default");
            }
        }
        for (obj.keys()) |key| {
            if (!isMember(T, key, ignore)) return self.fail(try self.join(path, key), "is not a member of this table");
        }
        return out;
    }

    fn isMember(comptime T: type, key: []const u8, comptime ignore: []const []const u8) bool {
        inline for (ignore) |name| {
            if (std.mem.eql(u8, key, name)) return true;
        }
        inline for (std.meta.fields(T)) |f| {
            if (comptime isFunction(f.type)) continue;
            if (std.mem.eql(u8, key, f.name)) return true;
        }
        return false;
    }

    fn value(self: *Reader, comptime T: type, v: std.json.Value, path: []const u8) Error!T {
        if (T == u8) {
            const s = switch (v) {
                .string => |s| s,
                else => return self.fail(path, "is not a one-byte string"),
            };
            if (s.len != 1) return self.fail(path, "is not a one-byte string");
            return s[0];
        }
        if (comptime isEnumArray(T)) {
            const obj = switch (v) {
                .object => |o| o,
                else => return self.fail(path, "is not an object"),
            };
            const optional = @typeInfo(T.Value) == .optional;
            var out: T = undefined;
            for (std.enums.values(T.Key)) |k| {
                if (obj.get(@tagName(k))) |item| {
                    out.set(k, try self.value(T.Value, item, try self.join(path, @tagName(k))));
                } else if (optional) {
                    out.set(k, null);
                } else {
                    return self.fail(try self.join(path, @tagName(k)), "is missing");
                }
            }
            var keys = obj.iterator();
            while (keys.next()) |entry| {
                if (std.meta.stringToEnum(T.Key, entry.key_ptr.*) == null)
                    return self.fail(try self.join(path, entry.key_ptr.*), "is not a key of this table");
            }
            return out;
        }
        switch (@typeInfo(T)) {
            .bool => return switch (v) {
                .bool => |b| b,
                else => self.fail(path, "is not a bool"),
            },
            .int => return switch (v) {
                .integer => |i| std.math.cast(T, i) orelse self.fail(path, "is out of range"),
                else => self.fail(path, "is not an integer"),
            },
            .@"enum" => {
                const s = switch (v) {
                    .string => |s| s,
                    else => return self.fail(path, "is not a name"),
                };
                return std.meta.stringToEnum(T, s) orelse self.fail(path, "names no value this member takes");
            },
            .optional => |o| return switch (v) {
                .null => null,
                else => try self.value(o.child, v, path),
            },
            .pointer => |p| {
                if (p.child == u8) {
                    const s = switch (v) {
                        .string => |s| s,
                        else => return self.fail(path, "is not a string"),
                    };
                    return self.arena.dupe(u8, s);
                }
                const items = switch (v) {
                    .array => |a| a.items,
                    else => return self.fail(path, "is not an array"),
                };
                const out = try self.arena.alloc(p.child, items.len);
                for (items, out, 0..) |item, *slot, i| {
                    slot.* = try self.value(p.child, item, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ path, i }));
                }
                return out;
            },
            .@"struct" => {
                const obj = switch (v) {
                    .object => |o| o,
                    else => return self.fail(path, "is not an object"),
                };
                return self.members(T, obj, path, &.{});
            },
            else => @compileError("no JSON reading for " ++ @typeName(T)),
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const format = @import("format.zig");
const markdown_syntax = @import("languages/markdown/syntax.zig");

/// `s` encoded, decoded, and given back its own renderers is `s`.
fn expectIdentity(s: *const Syntax) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try encodeAlloc(arena, s, .{});
    errdefer std.debug.print("\n--- syntax ---\n{s}\n", .{text});
    var problem: Problem = .{};
    var decoded = decode(arena, text, &problem) catch |err| {
        std.debug.print("\nrefused: {s}: {s}\n", .{ problem.path, problem.what });
        return err;
    };
    try testing.expectEqual(Renderers.of(s), decoded.renderers);
    if (decoded.renderers.render_text) decoded.syntax.renderText = s.renderText;
    if (decoded.renderers.render_block) decoded.syntax.renderBlock = s.renderBlock;
    if (decoded.renderers.spells_autolink) decoded.syntax.spellsAutolink = s.spellsAutolink;
    try testing.expect(eql(s, &decoded.syntax));
    try decoded.syntax.validate(null);
    // And the encoding is a fixed point: nothing the decode filled in by
    // default is written back differently.
    const again = try encodeAlloc(arena, &decoded.syntax, .{});
    try testing.expectEqualStrings(text, again);
}

test "syntax json: every compiled table is its own encoding" {
    for (format.registry) |entry| {
        errdefer std.debug.print("\n{s}: syntax identity\n", .{@tagName(entry.id)});
        try expectIdentity(entry.syntax);
    }
    // Every table Markdown is authored by, not only the registry's default:
    // the palette, the directives and the math alphabet live only in these.
    for ([_]bool{ false, true }) |st| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ true, true } }) |h| {
            for ([_]bool{ false, true }) |d| {
                for ([_]bool{ false, true }) |e| {
                    for ([_]bool{ false, true }) |m| {
                        try expectIdentity(markdown_syntax.forOptions(.{
                            .strikethrough = st,
                            .highlight = h[0],
                            .highlight_colors = h[1],
                            .directives = d,
                            .html_elements = e,
                            .math = m,
                        }));
                    }
                }
            }
        }
    }
}

test "syntax json: the empty object is the table that spells nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var problem: Problem = .{};
    const decoded = try decode(arena_state.allocator(), "{}", &problem);
    try testing.expect(eql(&syntax.none, &decoded.syntax));
    const text = try encodeAlloc(arena_state.allocator(), &syntax.none, .{ .pretty = false });
    try testing.expectEqualStrings("{}", text);
}

test "syntax json: a description states only what it spells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var problem: Problem = .{};
    const decoded = try decode(arena_state.allocator(),
        \\{"inline_delims":{"strong":{"open":"*","close":"*"},"mark":{"open":"==","close":"==","authorable":false}},
        \\ "heading_marker":"=","code_fence":{"char":"~"},
        \\ "text_escapes":"*\\","block_start_escapes":"=",
        \\ "table_spelling":{"bar":"|","delim_pad":" ","delim":{"default":"---","left":":--","right":"--:","center":":-:"}},
        \\ "renderers":["render_block"]}
    , &problem);
    const s = decoded.syntax;
    try testing.expectEqualStrings("*", s.inline_delims.get(.strong).?.open);
    try testing.expect(s.inline_delims.get(.strong).?.authorable);
    try testing.expect(!s.inline_delims.get(.mark).?.authorable);
    try testing.expect(s.inline_delims.get(.emph) == null);
    try testing.expectEqual(@as(?u8, '='), s.heading_marker);
    try testing.expectEqual(@as(u8, '~'), s.code_fence.?.char);
    try testing.expectEqual(@as(usize, 3), s.code_fence.?.min);
    try testing.expectEqualStrings(" ", s.table_spelling.?.pad);
    try testing.expect(s.renderText == &syntax.renderTextByAlphabet);
    try testing.expect(decoded.renderers.render_block and !decoded.renderers.render_text);
    try testing.expect(s.renderBlock == null);
}

test "syntax json: what is not a Syntax is refused at its path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { text: []const u8, path: []const u8 }{
        .{ .text = "{\"heading_markr\":\"#\"}", .path = "heading_markr" },
        .{ .text = "{\"heading_marker\":\"##\"}", .path = "heading_marker" },
        .{ .text = "{\"inline_delims\":{\"bold\":{\"open\":\"*\",\"close\":\"*\"}}}", .path = "inline_delims.bold" },
        .{ .text = "{\"inline_delims\":{\"strong\":{\"open\":\"*\"}}}", .path = "inline_delims.strong.close" },
        .{ .text = "{\"attr_spelling\":{\"quoting\":\"sometimes\"}}", .path = "attr_spelling.quoting" },
        .{ .text = "{\"table_spelling\":{\"bar\":\"|\",\"delim_pad\":\"\",\"delim\":{\"default\":\"---\"}}}", .path = "table_spelling.delim.left" },
        .{ .text = "{\"mark_colors\":{\"attr_key\":\"c\",\"colors\":[{\"name\":\"red\"}]}}", .path = "mark_colors.colors[0].prefix" },
        .{ .text = "{\"renderers\":[\"render_html\"]}", .path = "renderers" },
        .{ .text = "[]", .path = "" },
    };
    for (cases) |c| {
        var problem: Problem = .{};
        errdefer std.debug.print("\ncase: {s}\n", .{c.text});
        try testing.expectError(error.InvalidSyntax, decode(arena, c.text, &problem));
        try testing.expectEqualStrings(c.path, problem.path);
    }
}
