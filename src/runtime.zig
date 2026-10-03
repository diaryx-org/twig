//! Languages registered at runtime: a format twig did not compile in, carried
//! by a table of functions that parse into the node table (`ast/table.zig`)
//! and print from it. `docs/proposals/runtime-languages.md` is the argument;
//! this file is its in-process carrier.
//!
//! ── What a registration becomes ────────────────────────────────────────────
//! Rows like any other. `register` hands back a `Format` whose value is the
//! language's C wire code, `base` and up, and from then on `format.entryFor`
//! and `format.targetEntryFor` return real `Entry`/`TargetEntry` rows for it:
//! `parse` and `parseToAst` call the language and decode its table, `renderHtml`
//! is the shared printer over that table with core's labels, and a language
//! that prints has `serializeCanonical` and `serializeFromAst`. So the CLI, the
//! C ABI, the editor and the diagnostics reach a runtime language through the
//! code they already have, and none of them switches on where a row came from.
//!
//! A row's functions are plain function pointers with no closure, so each slot
//! has its own set, instantiated at comptime over the slot index (`Row`). That
//! is what bounds the registry at `capacity`, and why a slot never moves.
//!
//! ── Features and sets ──────────────────────────────────────────────────────
//! A language may declare FEATURES — named switches its parser reads, as
//! Markdown's extensions are — and SETS, each a name for a list of them, as
//! `gfm` is a name for Markdown's. The language's own row parses with the
//! features it declares on by default; each set is a row of its own, with a
//! `Format` of its own, `dialect_of` the language's row. A caller lays more
//! features over a row through `ParseConfig.features`, a mask in declaration
//! order, and can only turn features on: turning one off is choosing another
//! row. A feature may require others, which come on with it. The language is
//! told the features in force on every call, by mask and by name (`Call`),
//! and never which row's preset they came from beyond the row's name.
//!
//! ── The author tier ────────────────────────────────────────────────────────
//! A language that declares `caps.author` hands over a `syntax` — the table
//! `syntax_json.zig` reads — and, per feature, a PATCH: a partial table whose
//! members replace the base's while the feature is on. A patch replaces a
//! member whole, except in the three keyed tables (`inline_delims`,
//! `text_leaf_delims`, `container_spelling`), where it replaces per key. Two
//! features may not patch the same member or key, so the order features come
//! on in cannot change a table. The table for a combination of features is
//! built on first use, validated (`Syntax.validate`), and kept; one that
//! breaks a rule spells nothing, and `lastFailure` says why.
//!
//! The renderers the table names — `render_text`, `render_block`,
//! `spells_autolink` — are calls into the language (`Language.render`), and
//! find it through `Syntax.renderer_context`, which is the table's
//! `Combination`. A language that names `render_block` and has no `render`
//! of its own prints the fragment with `print`, as three compiled formats do
//! — naming it is the claim that its print spells every fragment a gesture
//! builds, which a printer that writes less than that does not make. One
//! whose table states `text_escapes` gets the alphabet renderer.
//!
//! ── Load is the validation moment ──────────────────────────────────────────
//! A compiled format has its test suite; a runtime one has what it declares,
//! and `register` holds it to that before any row exists: the description is
//! well-formed and claims no name or extension a row already has; then
//! `contract.all`, the checks the harness runs over every compiled row —
//! samples, renderers, claims, and for a table that authors a block moved
//! across its containers and every gesture run everywhere it applies. Those
//! run over every row's own features, over each row with each one feature
//! more, and with every feature on. The fidelity probe runs over each row
//! that prints, so `diagnostics` measures what a conversion into it loses
//! rather than being told. After load, core still validates every table it
//! receives — a parse that fails later is an error naming the language, never
//! a crash.
//!
//! ── Concurrency ────────────────────────────────────────────────────────────
//! Append-only. A registration fills its slots under `lock` and publishes them
//! by bumping `count` with release ordering; a reader that sees the count sees
//! the slots whole, and a slot never changes once published but for its cache
//! of combinations, which is append-only under `combo_lock`. There is no
//! unregistration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("ast/ast.zig");
const Document = @import("document.zig");
const format = @import("format.zig");
const Format = format.Format;
const Target = format.Target;
const node_table = @import("ast/table.zig");
const diagnostics = @import("diagnostics.zig");
const contract = @import("contract.zig");
const Html = @import("languages/html/html.zig");
const syntax_mod = @import("syntax.zig");
const Syntax = syntax_mod.Syntax;
const syntax_json = @import("syntax_json.zig");

/// The first `Format`/`Target` value — and C wire code — a registration is
/// given. The C ABI's `TWIG_FORMAT_RUNTIME_BASE` is the same number, checked
/// at comptime there.
pub const base: u16 = 4096;

/// How many rows one process may register: a language's own, and one per set.
pub const capacity = 64;

/// How many features one language may declare: one bit each of a `u32`, the
/// mask `ParseConfig.features` and the C ABI carry.
pub const max_features = 32;

/// What a language's functions may fail with. `LanguageFailed` carries its
/// reason in the `diag` writer it was handed.
pub const Error = error{ LanguageFailed, OutOfMemory };

/// Which call a language is answering: the row it registered under, and the
/// features in force — the row's own and whatever the caller laid over them.
pub const Call = struct {
    /// The language's name, or a set's.
    row: []const u8,
    /// Bit `i` is the description's `features[i]`.
    features: u32 = 0,
    /// The same features, by name, in declaration order.
    feature_names: []const []const u8 = &.{},
};

/// One renderer's question, as the table names it (`syntax_json.Renderers`).
pub const Render = union(enum) {
    /// Spell `text` so it reparses as itself in `position` — `Syntax.renderText`.
    render_text: struct { text: []const u8, position: syntax_mod.TextPosition },
    /// Spell a fragment: a node table without positions, rooted at the node
    /// to print — `Syntax.renderBlock`.
    render_block: []const u8,
    /// Whether a `<dest>` run, brackets included, spells an autolink —
    /// `Syntax.spellsAutolink`. Answered `true` or `false`.
    spells_autolink: []const u8,
};

/// The functions a runtime language supplies. Each exchanges the node table
/// as JSON text (`ast/table.zig`), allocated with the allocator it is given;
/// `call` names the row and the features, so one table of functions serves
/// every row a language registers.
pub const Language = struct {
    context: ?*anyopaque = null,
    /// `source` to the node table of its parse.
    parse: *const fn (context: ?*anyopaque, allocator: Allocator, call: Call, source: []const u8, diag: *Writer) Error![]u8,
    /// A node table to source. Its rows carry no positions when the tree
    /// was never parsed from anything — a conversion from another format.
    /// `null` for a language that only reads.
    print: ?*const fn (context: ?*anyopaque, allocator: Allocator, call: Call, table: []const u8, diag: *Writer) Error![]u8 = null,
    /// The renderers the description's `syntax` names, answered as text.
    /// `null` for a language that names none — or only `render_block`, which
    /// `print` then answers.
    render: ?*const fn (context: ?*anyopaque, allocator: Allocator, call: Call, request: Render, diag: *Writer) Error![]u8 = null,
};

/// A document the load check holds a language to, and the features it needs
/// on to mean what it says.
pub const Sample = struct {
    text: []const u8,
    features: []const []const u8 = &.{},
};

pub const Feature = struct {
    name: []const u8,
    /// Whether the language's own row has it on.
    default: bool = false,
    /// Features that come on with this one.
    requires: []const []const u8 = &.{},
    /// The patch over the language's `syntax` while it is on, as JSON text:
    /// an object of `Syntax` members. Only for a language that authors.
    syntax: ?[]const u8 = null,
};

/// A named list of features, registered as a row of its own.
pub const Set = struct {
    name: []const u8,
    extensions: []const []const u8 = &.{},
    aliases: []const []const u8 = &.{},
    features: []const []const u8 = &.{},
};

/// What a language says about itself — the `describe` document of the
/// proposal, read by `Description.parse`.
pub const Description = struct {
    name: []const u8,
    /// Lowercase and dot-less, as `Entry.extensions` are.
    extensions: []const []const u8 = &.{},
    aliases: []const []const u8 = &.{},
    /// Whether the language prints — the write tier. It must supply `print`.
    write: bool = false,
    /// Whether the language authors — `syntax` is its table.
    author: bool = false,
    /// The table an editor writes with, as JSON text (`syntax_json.zig`).
    syntax: ?[]const u8 = null,
    features: []const Feature = &.{},
    sets: []const Set = &.{},
    /// Small documents the load check holds the language to. At least one,
    /// and at least one that needs no feature.
    samples: []const Sample,

    /// Read a `describe` document:
    ///
    ///     {"name": "wiki", "extensions": ["wiki"], "aliases": [],
    ///      "caps": {"read": true, "write": true, "author": true},
    ///      "syntax": {…},
    ///      "features": [{"name": "math", "default": false,
    ///                    "requires": [], "syntax": {…}}],
    ///      "sets": [{"name": "wiki-strict", "features": []}],
    ///      "samples": ["= x\n", {"text": "$x$\n", "features": ["math"]}]}
    ///
    /// Strings borrow from the parsed JSON, which `arena` owns; a `syntax`
    /// is re-encoded into it. Unknown keys are ignored; `dialects` is refused
    /// by name, since a language declaring them expects rows this carrier
    /// spells as `sets`.
    pub fn parse(arena: Allocator, text: []const u8, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!Description {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refuse(diag, "the description is not a JSON document", .{}),
        };
        return fromValue(arena, value, diag);
    }

    /// `parse` over an already-parsed value — the description as it sits in
    /// a `describe` response on the helper wire. Strings borrow from `value`.
    pub fn fromValue(arena: Allocator, value: std.json.Value, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!Description {
        const obj = switch (value) {
            .object => |o| o,
            else => return refuse(diag, "the description is a JSON object", .{}),
        };
        if (obj.get("dialects") != null) return refuse(diag, "\"dialects\" is not a runtime language's: a named configuration is a set (\"sets\") of the language's \"features\"", .{});
        var write = false;
        var author = false;
        if (obj.get("caps")) |caps_value| {
            const caps = switch (caps_value) {
                .object => |o| o,
                else => return refuse(diag, "\"caps\" is an object of booleans", .{}),
            };
            if (caps.get("read")) |_| if (!try flag(caps, "read", "caps.read", diag)) return refuse(diag, "caps.read is every language's", .{});
            write = try flag(caps, "write", "caps.write", diag);
            author = try flag(caps, "author", "caps.author", diag);
        }

        const feature_values = try array(obj, "features", "\"features\"", diag);
        const features = try arena.alloc(Feature, feature_values.len);
        for (feature_values, features, 0..) |v, *f, i| {
            const label = try std.fmt.allocPrint(arena, "features[{d}]", .{i});
            const fo = try object(v, label, diag);
            f.* = .{
                .name = try string(fo, "name", label, diag),
                .default = try flag(fo, "default", label, diag),
                .requires = try strings(arena, fo, "requires", label, diag),
                .syntax = try syntaxText(arena, fo, label, diag),
            };
        }

        const set_values = try array(obj, "sets", "\"sets\"", diag);
        const sets = try arena.alloc(Set, set_values.len);
        for (set_values, sets, 0..) |v, *s, i| {
            const label = try std.fmt.allocPrint(arena, "sets[{d}]", .{i});
            const so = try object(v, label, diag);
            s.* = .{
                .name = try string(so, "name", label, diag),
                .extensions = try strings(arena, so, "extensions", label, diag),
                .aliases = try strings(arena, so, "aliases", label, diag),
                .features = try strings(arena, so, "features", label, diag),
            };
        }

        const sample_values = try array(obj, "samples", "\"samples\"", diag);
        const samples = try arena.alloc(Sample, sample_values.len);
        for (sample_values, samples, 0..) |v, *s, i| {
            s.* = switch (v) {
                .string => |t| .{ .text = t },
                .object => |so| blk: {
                    const label = try std.fmt.allocPrint(arena, "samples[{d}]", .{i});
                    break :blk .{
                        .text = try string(so, "text", label, diag),
                        .features = try strings(arena, so, "features", label, diag),
                    };
                },
                else => return refuse(diag, "samples[{d}] is a string, or an object with \"text\" and \"features\"", .{i}),
            };
        }

        return .{
            .name = try string(obj, "name", "the description", diag),
            .extensions = try strings(arena, obj, "extensions", "the description", diag),
            .aliases = try strings(arena, obj, "aliases", "the description", diag),
            .write = write,
            .author = author,
            .syntax = try syntaxText(arena, obj, "the description", diag),
            .features = features,
            .sets = sets,
            .samples = samples,
        };
    }

    fn flag(obj: std.json.ObjectMap, key: []const u8, label: []const u8, diag: *Writer) error{InvalidLanguage}!bool {
        return switch (obj.get(key) orelse return false) {
            .bool => |b| b,
            else => refuse(diag, "{s}: \"{s}\" is a boolean", .{ label, key }),
        };
    }

    fn string(obj: std.json.ObjectMap, key: []const u8, label: []const u8, diag: *Writer) error{InvalidLanguage}![]const u8 {
        return switch (obj.get(key) orelse .null) {
            .string => |s| s,
            else => refuse(diag, "{s}: \"{s}\" is a string", .{ label, key }),
        };
    }

    fn object(v: std.json.Value, label: []const u8, diag: *Writer) error{InvalidLanguage}!std.json.ObjectMap {
        return switch (v) {
            .object => |o| o,
            else => refuse(diag, "{s} is an object", .{label}),
        };
    }

    fn array(obj: std.json.ObjectMap, key: []const u8, label: []const u8, diag: *Writer) error{InvalidLanguage}![]const std.json.Value {
        return switch (obj.get(key) orelse return &.{}) {
            .array => |a| a.items,
            else => refuse(diag, "{s} is an array", .{label}),
        };
    }

    fn strings(arena: Allocator, obj: std.json.ObjectMap, key: []const u8, label: []const u8, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)![]const []const u8 {
        const items = switch (obj.get(key) orelse return &.{}) {
            .array => |a| a.items,
            else => return refuse(diag, "{s}: \"{s}\" is an array of strings", .{ label, key }),
        };
        const out = try arena.alloc([]const u8, items.len);
        for (items, out) |item, *o| o.* = switch (item) {
            .string => |s| s,
            else => return refuse(diag, "{s}: \"{s}\" is an array of strings", .{ label, key }),
        };
        return out;
    }

    /// A `syntax` member, as compact JSON text: what is kept, and read again
    /// when a table is built.
    fn syntaxText(arena: Allocator, obj: std.json.ObjectMap, label: []const u8, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!?[]const u8 {
        const v = obj.get("syntax") orelse return null;
        switch (v) {
            .null => return null,
            .object => {},
            else => return refuse(diag, "{s}: \"syntax\" is an object", .{label}),
        }
        return try std.json.Stringify.valueAlloc(arena, v, .{});
    }
};

fn refuse(diag: *Writer, comptime fmt: []const u8, args: anytype) error{InvalidLanguage} {
    diag.print(fmt, args) catch {};
    return error.InvalidLanguage;
}

// ── the registry ────────────────────────────────────────────────────────────

/// One registration: the language, what it declared, and what was worked out
/// from that once. Shared by its rows.
const Lang = struct {
    language: Language,
    description: Description,
    /// What the language was registered with: the arena's backing, and what
    /// a renderer that is handed no allocator allocates with.
    gpa: Allocator,
    /// Owns the description's copy, the parsed tables, and every combination.
    arena: std.heap.ArenaAllocator,
    /// Each feature's bit with every bit it requires, transitively.
    closure: [max_features]u32 = @splat(0),
    /// Every declared feature's bit.
    declared: u32 = 0,
    /// The base table and each feature's patch, as parsed JSON. `null` for a
    /// language that does not author, and for a feature with no patch.
    base_syntax: ?std.json.ObjectMap = null,
    patches: []?std.json.ObjectMap = &.{},
    renderers: syntax_json.Renderers = .{},

    /// `mask`, with what each of its features requires.
    fn close(self: *const Lang, mask: u32) u32 {
        var out: u32 = 0;
        var rest = mask & self.declared;
        while (rest != 0) {
            const i = @ctz(rest);
            out |= self.closure[i];
            rest &= rest - 1;
        }
        return out;
    }

    /// The features in `mask`, by name, in `buf`.
    fn names(self: *const Lang, mask: u32, buf: *[max_features][]const u8) []const []const u8 {
        var n: usize = 0;
        for (self.description.features, 0..) |f, i| {
            if (mask & (@as(u32, 1) << @intCast(i)) != 0) {
                buf[n] = f.name;
                n += 1;
            }
        }
        return buf[0..n];
    }
};

/// One table a row's language authors with, for one combination of features,
/// built on first use and kept. `syntax.renderer_context` points here.
pub const Combination = struct {
    syntax: Syntax,
    slot: *const Slot,
    mask: u32,
    /// Why the table spells nothing, when its rules refused it.
    failure: ?[]const u8 = null,
};

const Slot = struct {
    lang: *Lang,
    /// The language's name, or a set's.
    name: []const u8,
    extensions: []const []const u8,
    aliases: []const []const u8,
    /// The features the row has on before a caller lays any over it.
    mask: u32,
    entry: format.Entry,
    target: format.TargetEntry,
    /// What a conversion into this row keeps, measured at load. `null` for a
    /// language that does not print, which has nothing to measure.
    measured: ?diagnostics.Measured,
    /// Features the load check lays over every call through this row while
    /// it checks a combination — only before the row is published, so only
    /// on the registering thread.
    load_features: u32 = 0,
    /// The tables built so far, under `combo_lock`.
    combos: std.ArrayList(*Combination) = .empty,

    /// The features a call through this row has on, given a caller's.
    fn effective(self: *const Slot, extra: u32) u32 {
        return self.mask | self.lang.close(extra) | self.load_features;
    }

    fn call(self: *const Slot, mask: u32, buf: *[max_features][]const u8) Call {
        return .{ .row = self.name, .features = mask, .feature_names = self.lang.names(mask, buf) };
    }

    fn parseDocument(self: *const Slot, allocator: Allocator, mask: u32, source: []const u8) anyerror!Document {
        var diag: Writer.Allocating = .init(allocator);
        defer diag.deinit();
        var buf: [max_features][]const u8 = undefined;
        const l = &self.lang.language;
        const text = l.parse(l.context, allocator, self.call(mask, &buf), source, &diag.writer) catch |err| {
            fail("{s}: parse failed: {s}", .{ self.name, diag.written() });
            return err;
        };
        defer allocator.free(text);
        var problem: node_table.Problem = .{};
        return node_table.decode(allocator, source, text, &problem) catch |err| {
            if (err == error.InvalidTable) failTable(self.name, problem);
            return err;
        };
    }

    fn printTable(self: *const Slot, allocator: Allocator, mask: u32, text: []const u8) anyerror![]u8 {
        const l = &self.lang.language;
        const print = l.print orelse return error.UnsupportedFormat;
        var diag: Writer.Allocating = .init(allocator);
        defer diag.deinit();
        var buf: [max_features][]const u8 = undefined;
        return print(l.context, allocator, self.call(mask, &buf), text, &diag.writer) catch |err| {
            fail("{s}: print failed: {s}", .{ self.name, diag.written() });
            return err;
        };
    }

    fn render(self: *const Slot, allocator: Allocator, mask: u32, request: Render) anyerror![]u8 {
        const l = &self.lang.language;
        const f = l.render orelse return error.UnsupportedFormat;
        var diag: Writer.Allocating = .init(allocator);
        defer diag.deinit();
        var buf: [max_features][]const u8 = undefined;
        return f(l.context, allocator, self.call(mask, &buf), request, &diag.writer) catch |err| {
            fail("{s}: {t} failed: {s}", .{ self.name, std.meta.activeTag(request), diag.written() });
            return err;
        };
    }

    /// The table this row authors with under `mask` — built, validated and
    /// kept the first time it is asked for. `Syntax.none` for a language
    /// that does not author; a table that spells nothing, with its failure
    /// recorded, for one whose combination breaks a rule.
    fn syntaxFor(self: *Slot, mask: u32) *const Syntax {
        const c = self.combination(mask) catch |err| {
            fail("{s}: no table for these features: {t}", .{ self.name, err });
            return &syntax_mod.none;
        } orelse return &syntax_mod.none;
        if (c.failure) |why| fail("{s}: {s}", .{ self.name, why });
        return &c.syntax;
    }

    fn combination(self: *Slot, mask: u32) Allocator.Error!?*Combination {
        if (self.lang.base_syntax == null) return null;
        while (!combo_lock.tryLock()) std.atomic.spinLoopHint();
        defer combo_lock.unlock();
        for (self.combos.items) |c| if (c.mask == mask) return c;
        const a = self.lang.arena.allocator();
        const c = try a.create(Combination);
        c.* = .{ .syntax = .{}, .slot = self, .mask = mask };
        try buildTable(self.lang, mask, c);
        try self.combos.append(a, c);
        return c;
    }
};

var slots: [capacity]Slot = undefined;
var count = std.atomic.Value(u32).init(0);
/// The values of the rows `register` is filling, `[lo, hi)`, while its load
/// check runs; empty otherwise.
var loading_lo = std.atomic.Value(u16).init(0);
var loading_hi = std.atomic.Value(u16).init(0);
var lock: std.atomic.Mutex = .unlocked;
var combo_lock: std.atomic.Mutex = .unlocked;

/// The published slots.
fn published() []Slot {
    return slots[0..count.load(.acquire)];
}

fn slotOf(value: u16) ?*Slot {
    if (value < base) return null;
    const i = value - base;
    if (i >= count.load(.acquire)) return null;
    return &slots[i];
}

/// Whether `fmt` names a registered row — false for a compiled row, and for
/// a value in the runtime range that no registration has been given.
pub fn isRegistered(fmt: Format) bool {
    return slotOf(@backingInt(fmt)) != null;
}

/// The `Format` a wire code names, if a row holds it.
pub fn formatFromCode(code: i64) ?Format {
    const value = std.math.cast(u16, code) orelse return null;
    _ = slotOf(value) orelse return null;
    return @fromBackingInt(@intCast(value));
}

/// `slotOf`, or a row being loaded: its value reaches no caller before it is
/// published, but the load check reaches it — through `Format.name` for its
/// messages, and through `format.entryFor`/`targetEntryFor` where a check
/// prints a tree into the row it is checking.
fn slotOrLoading(value: u16) ?*Slot {
    if (slotOf(value)) |s| return s;
    if (value >= loading_lo.load(.acquire) and value < loading_hi.load(.acquire)) return &slots[value - base];
    return null;
}

pub fn entryFor(fmt: Format) ?*const format.Entry {
    return if (slotOrLoading(@backingInt(fmt))) |s| &s.entry else null;
}

pub fn targetEntryFor(t: Target) ?*const format.TargetEntry {
    return if (slotOrLoading(@backingInt(t))) |s| &s.target else null;
}

/// The name a runtime `Format` or `Target` value was registered under, or
/// `"unregistered"` for a value in the range no row holds.
pub fn nameOf(value: u16) []const u8 {
    return if (slotOrLoading(value)) |s| s.name else "unregistered";
}

/// Every registered row, in registration order.
pub fn entries() []const Slot {
    return published();
}

pub fn byName(name: []const u8) ?Format {
    for (published()) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s.entry.id;
        for (s.aliases) |a| if (std.mem.eql(u8, a, name)) return s.entry.id;
    }
    return null;
}

pub fn byExtension(ext: []const u8) ?Format {
    for (published()) |*s| {
        for (s.extensions) |known| if (std.ascii.eqlIgnoreCase(known, ext)) return s.entry.id;
    }
    return null;
}

/// What a conversion into `t` keeps, as the load-time probe measured it.
pub fn measured(t: Target) ?*const diagnostics.Measured {
    const s = slotOf(@backingInt(t)) orelse return null;
    return if (s.measured) |*m| m else null;
}

/// The bit `ParseConfig.features` turns `name` on with for `fmt`'s language,
/// or `null` when `fmt` is not a registered row or its language declares no
/// such feature.
pub fn featureBit(fmt: Format, name: []const u8) ?u32 {
    const s = slotOf(@backingInt(fmt)) orelse return null;
    for (s.lang.description.features, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @as(u32, 1) << @intCast(i);
    }
    return null;
}

/// The features `fmt`'s language declares, in bit order; empty for a
/// compiled row.
pub fn featuresOf(fmt: Format) []const Feature {
    const s = slotOf(@backingInt(fmt)) orelse return &.{};
    return s.lang.description.features;
}

// ── why the last call failed ────────────────────────────────────────────────

threadlocal var failure_buf: [1024]u8 = undefined;
threadlocal var failure_len: usize = 0;

/// Why the most recent failed call into a runtime language on this thread
/// failed: the language's own message, or the table rule its output broke.
/// The row functions are `anyerror`-shaped and cannot carry a message, so
/// the CLI and the C ABI read it here after one returns an error.
pub fn lastFailure() []const u8 {
    return failure_buf[0..failure_len];
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    const out = std.fmt.bufPrint(&failure_buf, fmt, args) catch failure_buf[0..];
    failure_len = out.len;
}

fn failTable(name: []const u8, problem: node_table.Problem) void {
    var w: Writer = .fixed(&failure_buf);
    w.print("{s}: the table is refused: ", .{name}) catch {};
    problem.render(&w) catch {};
    failure_len = w.end;
}

// ── the per-slot rows ───────────────────────────────────────────────────────

fn Row(comptime i: usize) type {
    return struct {
        fn parse(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!format.ParsedDoc {
            const s = &slots[i];
            const cfg = format.ParseConfig.from(ctx);
            return .{ .format = s.entry.id, .config = cfg.*, .doc = try s.parseDocument(allocator, s.effective(cfg.features), source) };
        }

        fn parseToAst(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
            const s = &slots[i];
            return s.parseDocument(allocator, s.effective(format.ParseConfig.from(ctx).features), source);
        }

        /// The shared printer, with the labels the table carried or core
        /// indexed from it — the path every compiled format but djot and
        /// Markdown takes, and those two only because they number footnotes
        /// against labels of their own.
        fn renderHtml(allocator: Allocator, doc: *const format.ParsedDoc, writer: *Writer) anyerror!void {
            try Html.serialize(allocator, doc.ast(), writer, &doc.doc.labels);
        }

        /// The parse's own table without its positions — a print has no
        /// source to hold them against — and with the spelling and labels
        /// the parse recorded, which is what `serializeCanonical` keeps
        /// that `serializeFromAst` rebuilds. Printed with the features the
        /// document was parsed with.
        fn serializeCanonical(allocator: Allocator, doc: *const format.ParsedDoc) anyerror![]u8 {
            const s = &slots[i];
            const text = try node_table.encodeAlloc(allocator, &doc.doc, .{ .pretty = false, .positions = false });
            defer allocator.free(text);
            return s.printTable(allocator, s.effective(doc.config.features), text);
        }

        fn serializeFromAst(allocator: Allocator, ast: *const AST) anyerror![]u8 {
            const s = &slots[i];
            const text = try node_table.encodeAstAlloc(allocator, ast, .{ .pretty = false });
            defer allocator.free(text);
            return s.printTable(allocator, s.effective(0), text);
        }

        fn syntaxFor(cfg: *const format.ParseConfig) *const Syntax {
            const s = &slots[i];
            return s.syntaxFor(s.effective(cfg.features));
        }
    };
}

const RowFns = struct {
    parse: *const fn (*const anyopaque, Allocator, []const u8) anyerror!format.ParsedDoc,
    parseToAst: *const fn (*const anyopaque, Allocator, []const u8) anyerror!Document,
    renderHtml: *const fn (Allocator, *const format.ParsedDoc, *Writer) anyerror!void,
    serializeCanonical: *const fn (Allocator, *const format.ParsedDoc) anyerror![]u8,
    serializeFromAst: *const fn (Allocator, *const AST) anyerror![]u8,
    syntaxFor: *const fn (*const format.ParseConfig) *const Syntax,
};

const rows: [capacity]RowFns = blk: {
    var out: [capacity]RowFns = undefined;
    for (&out, 0..) |*r, i| {
        const R = Row(i);
        r.* = .{
            .parse = R.parse,
            .parseToAst = R.parseToAst,
            .renderHtml = R.renderHtml,
            .serializeCanonical = R.serializeCanonical,
            .serializeFromAst = R.serializeFromAst,
            .syntaxFor = R.syntaxFor,
        };
    }
    break :blk out;
};

// ── the renderers ───────────────────────────────────────────────────────────
//
// One set for every runtime table: each finds its language, row and features
// through the table it was found in.

fn comboOf(s: *const Syntax) *const Combination {
    return @ptrCast(@alignCast(s.renderer_context.?));
}

fn renderText(s: *const Syntax, text: []const u8, position: syntax_mod.TextPosition, out: *Writer) anyerror!void {
    const c = comboOf(s);
    const gpa = c.slot.lang.gpa;
    const spelled = try c.slot.render(gpa, c.mask, .{ .render_text = .{ .text = text, .position = position } });
    defer gpa.free(spelled);
    try out.writeAll(spelled);
}

/// The fragment `root` of `ast` as a node table without positions.
fn fragmentTable(allocator: Allocator, ast: *const AST, root: AST.Node.Id) Allocator.Error![]u8 {
    // A shallow copy: the arena and strings are still `ast`'s, and this value
    // is never `deinit`ed — as `syntax.renderBlockVia` re-roots one.
    var fragment = ast.*;
    fragment.root = root;
    return node_table.encodeAstAlloc(allocator, &fragment, .{ .pretty = false });
}

fn renderBlock(s: *const Syntax, allocator: Allocator, ast: *const AST, root: AST.Node.Id, out: *Writer) anyerror!void {
    const c = comboOf(s);
    const table = try fragmentTable(allocator, ast, root);
    defer allocator.free(table);
    const spelled = try c.slot.render(allocator, c.mask, .{ .render_block = table });
    defer allocator.free(spelled);
    try out.writeAll(spelled);
}

/// `renderBlock` for a language that names it and answers it with `print`:
/// the fragment printed whole, as `syntax.renderBlockVia` is for a compiled
/// serializer.
fn renderBlockByPrint(s: *const Syntax, allocator: Allocator, ast: *const AST, root: AST.Node.Id, out: *Writer) anyerror!void {
    const c = comboOf(s);
    const table = try fragmentTable(allocator, ast, root);
    defer allocator.free(table);
    const spelled = try c.slot.printTable(allocator, c.mask, table);
    defer allocator.free(spelled);
    try out.writeAll(spelled);
}

/// A language that fails to answer has not spelled an autolink, and the
/// gesture takes the path it would without one; `lastFailure` keeps why.
fn spellsAutolink(s: *const Syntax, angled: []const u8) bool {
    const c = comboOf(s);
    const gpa = c.slot.lang.gpa;
    const answer = c.slot.render(gpa, c.mask, .{ .spells_autolink = angled }) catch return false;
    defer gpa.free(answer);
    return std.mem.eql(u8, std.mem.trim(u8, answer, " \t\r\n"), "true");
}

// ── building a table ────────────────────────────────────────────────────────

/// The `Syntax` members a patch replaces per key rather than whole.
const keyed_members = [_][]const u8{ "inline_delims", "text_leaf_delims", "container_spelling" };

fn isKeyed(member: []const u8) bool {
    for (keyed_members) |k| if (std.mem.eql(u8, k, member)) return true;
    return false;
}

/// The base table with every patch `mask` turns on laid over it, decoded,
/// bound to the language's renderers, and validated — into `c`, whose
/// `failure` says why when the rules refuse it. Under `combo_lock`, or on
/// the registering thread.
fn buildTable(lang: *Lang, mask: u32, c: *Combination) Allocator.Error!void {
    const a = lang.arena.allocator();
    var merged = try lang.base_syntax.?.clone(a);
    for (lang.patches, 0..) |patch_opt, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const patch = patch_opt orelse continue;
        var it = patch.iterator();
        while (it.next()) |member| {
            const key = member.key_ptr.*;
            const into = merged.get(key);
            if (isKeyed(key) and into != null and into.? == .object and member.value_ptr.* == .object) {
                var table = try into.?.object.clone(a);
                var kit = member.value_ptr.object.iterator();
                while (kit.next()) |entry| try table.put(a, entry.key_ptr.*, entry.value_ptr.*);
                try merged.put(a, key, .{ .object = table });
            } else {
                try merged.put(a, key, member.value_ptr.*);
            }
        }
    }
    var problem: syntax_json.Problem = .{};
    const decoded = syntax_json.fromValue(a, .{ .object = merged }, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Each part decoded alone at load, so a merge that does not is a
        // table whose parts disagree on a member's shape.
        error.InvalidSyntax => {
            c.syntax = .{};
            c.failure = try std.fmt.allocPrint(a, "the table for these features is refused: {s}: {s}", .{ problem.path, problem.what });
            return;
        },
    };
    var s = decoded.syntax;
    s.renderer_context = c;
    if (decoded.renderers.render_text) s.renderText = &renderText;
    if (decoded.renderers.render_block) s.renderBlock = if (lang.language.render != null) &renderBlock else &renderBlockByPrint;
    if (decoded.renderers.spells_autolink) s.spellsAutolink = &spellsAutolink;
    var why: syntax_mod.Incoherence = .{};
    s.validate(&why) catch {
        c.syntax = .{};
        c.failure = try std.fmt.allocPrint(a, "the table for these features breaks a rule at {s}: {s}", .{ why.field, why.rule.describe() });
        return;
    };
    c.syntax = s;
}

// ── registration ────────────────────────────────────────────────────────────

pub const RegisterError = error{ InvalidLanguage, RegistryFull, OutOfMemory };

/// Names a runtime language may not take: the CLI's `-o` words, which would
/// shadow it on the command line.
const reserved_names = [_][]const u8{ "ast", "table", "canonical" };

/// Register `language` under `description` — a row for the language, and
/// one per set — run the load check over it, and return the `Format` of the
/// language's own row; a set's is found by its name. `gpa` owns the copies
/// of the description for the life of the process. On refusal nothing is
/// registered, and `diag` says why.
pub fn register(gpa: Allocator, language: Language, description: Description, diag: *Writer) RegisterError!Format {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();

    const first = count.load(.acquire);
    try checkDescription(gpa, description, language, diag);
    const row_count = 1 + description.sets.len;
    if (first + row_count > capacity) return refuseFull(diag);

    const lang = try gpa.create(Lang);
    lang.* = .{ .language = language, .description = undefined, .gpa = gpa, .arena = .init(gpa) };
    var published_ok = false;
    defer if (!published_ok) {
        lang.arena.deinit();
        gpa.destroy(lang);
    };
    const a = lang.arena.allocator();
    lang.description = try own(a, description);
    try prepare(lang, diag);

    // The rows, filled and not yet published: the checks below call their
    // own functions, which read them, while no other reader can see them.
    const lo: u16 = base + @as(u16, @intCast(first));
    loading_lo.store(lo, .release);
    loading_hi.store(lo + @as(u16, @intCast(row_count)), .release);
    defer {
        loading_lo.store(0, .release);
        loading_hi.store(0, .release);
    }
    const d = &lang.description;
    var default_mask: u32 = 0;
    for (d.features, 0..) |f, i| {
        if (f.default) default_mask |= lang.closure[i];
    }
    for (0..row_count) |r| {
        const i = first + r;
        const id: Format = @fromBackingInt(@intCast(base + i));
        const own_row = r == 0;
        const set: ?Set = if (own_row) null else d.sets[r - 1];
        const mask = if (set) |s| lang.close(maskOf(d, s.features)) else default_mask;
        const fns = rows[i];
        slots[i] = .{
            .lang = lang,
            .name = if (set) |s| s.name else d.name,
            .extensions = if (set) |s| s.extensions else d.extensions,
            .aliases = if (set) |s| s.aliases else d.aliases,
            .mask = mask,
            .entry = .{
                .id = id,
                .dialect_of = if (own_row) null else @fromBackingInt(@intCast(base + first)),
                .samples = try samplesUnder(a, d, lang, mask),
                .extensions = if (set) |s| s.extensions else d.extensions,
                .aliases = if (set) |s| s.aliases else d.aliases,
                .parse = fns.parse,
                .parseToAst = fns.parseToAst,
                .renderHtml = fns.renderHtml,
                .serializeCanonical = if (d.write) fns.serializeCanonical else null,
                .syntaxFor = if (d.author) fns.syntaxFor else null,
            },
            .target = .{
                .id = @fromBackingInt(@intCast(base + i)),
                .reads_back_as = id,
                .serializeFromAst = if (d.write) fns.serializeFromAst else null,
            },
            .measured = null,
        };
        slots[i].entry.syntax = slots[i].syntaxFor(mask);
        if (d.author) {
            const c = (try slots[i].combination(mask)).?;
            if (c.failure) |why| return refuse(diag, "{s}: {s}", .{ slots[i].name, why });
        }
    }

    try checkRows(gpa, lang, first, row_count, diag);
    // A print that fails on a probe is measured as dropping it, not as a
    // reason to refuse the language: it declared the write tier, not the
    // whole vocabulary.
    if (d.write) for (first..first + row_count) |i| {
        slots[i].measured = try diagnostics.measure(gpa, rows[i].serializeFromAst, rows[i].parseToAst);
    };
    published_ok = true;
    count.store(@intCast(first + row_count), .release);
    return @fromBackingInt(@intCast(base + first));
}

fn refuseFull(diag: *Writer) error{RegistryFull} {
    diag.print("the registry holds {d} rows and is full", .{capacity}) catch {};
    return error.RegistryFull;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (!std.ascii.isLower(s[0])) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

/// Whether a compiled row or a registered one already answers to `name`.
fn nameTaken(name: []const u8) bool {
    if (format.parseFormatName(name) != null or format.parseTargetName(name) != null) return true;
    for (reserved_names) |r| if (std.mem.eql(u8, r, name)) return true;
    return false;
}

fn indexOfName(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |item, i| if (std.mem.eql(u8, item, name)) return i;
    return null;
}

fn featureIndex(d: *const Description, name: []const u8) ?usize {
    for (d.features, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return null;
}

fn maskOf(d: *const Description, names: []const []const u8) u32 {
    var m: u32 = 0;
    for (names) |n| m |= @as(u32, 1) << @intCast(featureIndex(d, n).?);
    return m;
}

/// The names and extensions one row claims, held to what is already taken
/// and to what the description's other rows claim (`seen_names`,
/// `seen_exts`).
fn checkRowNames(
    d: *const Description,
    name: []const u8,
    aliases: []const []const u8,
    extensions: []const []const u8,
    seen_names: *std.ArrayList([]const u8),
    seen_exts: *std.ArrayList([]const u8),
    scratch: Allocator,
    diag: *Writer,
) (error{InvalidLanguage} || Allocator.Error)!void {
    if (!isIdentifier(name)) return refuse(diag, "the name \"{s}\" is not a lowercase identifier", .{name});
    if (nameTaken(name)) return refuse(diag, "the name \"{s}\" is already a format's", .{name});
    if (indexOfName(seen_names.items, name) != null) return refuse(diag, "{s}: the name \"{s}\" is given twice", .{ d.name, name });
    try seen_names.append(scratch, name);
    for (aliases) |al| {
        if (!isIdentifier(al)) return refuse(diag, "{s}: the alias \"{s}\" is not a lowercase identifier", .{ name, al });
        if (nameTaken(al) or indexOfName(seen_names.items, al) != null) return refuse(diag, "{s}: the alias \"{s}\" is already a format's", .{ name, al });
        try seen_names.append(scratch, al);
    }
    for (extensions) |e| {
        if (e.len == 0 or std.mem.indexOfScalar(u8, e, '.') != null) return refuse(diag, "{s}: the extension \"{s}\" is written without its dot", .{ name, e });
        for (e) |ch| if (std.ascii.isUpper(ch)) return refuse(diag, "{s}: the extension \"{s}\" is written in lowercase", .{ name, e });
        var probe_path: [80]u8 = undefined;
        const path = std.fmt.bufPrint(&probe_path, "x.{s}", .{e}) catch return refuse(diag, "{s}: the extension \"{s}\" is too long", .{ name, e });
        if (format.detectFromExtension(path)) |owner| return refuse(diag, "{s}: the extension \"{s}\" is {s}'s", .{ name, e, owner.name() });
        if (indexOfName(seen_exts.items, e) != null) return refuse(diag, "{s}: the extension \"{s}\" is given twice", .{ name, e });
        try seen_exts.append(scratch, e);
    }
}

fn checkFeatureNames(d: *const Description, names: []const []const u8, label: []const u8, diag: *Writer) error{InvalidLanguage}!void {
    for (names) |n| {
        if (featureIndex(d, n) == null) return refuse(diag, "{s}: {s} names \"{s}\", which is not a declared feature", .{ d.name, label, n });
    }
}

fn checkDescription(gpa: Allocator, d: Description, language: Language, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!void {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var seen_names: std.ArrayList([]const u8) = .empty;
    var seen_exts: std.ArrayList([]const u8) = .empty;
    try checkRowNames(&d, d.name, d.aliases, d.extensions, &seen_names, &seen_exts, scratch, diag);
    for (d.sets) |s| try checkRowNames(&d, s.name, s.aliases, s.extensions, &seen_names, &seen_exts, scratch, diag);

    if (d.write and language.print == null) return refuse(diag, "{s}: caps.write needs a print function", .{d.name});
    if (d.author and d.syntax == null) return refuse(diag, "{s}: caps.author needs a \"syntax\", the table its gestures write with", .{d.name});
    if (!d.author and d.syntax != null) return refuse(diag, "{s}: a \"syntax\" is the author tier's, and caps.author is not declared", .{d.name});

    if (d.features.len > max_features) return refuse(diag, "{s}: a language declares at most {d} features", .{ d.name, max_features });
    for (d.features, 0..) |f, i| {
        if (!isIdentifier(f.name)) return refuse(diag, "{s}: the feature \"{s}\" is not a lowercase identifier", .{ d.name, f.name });
        if (featureIndex(&d, f.name) != i) return refuse(diag, "{s}: the feature \"{s}\" is declared twice", .{ d.name, f.name });
        try checkFeatureNames(&d, f.requires, f.name, diag);
        if (f.syntax != null and !d.author) return refuse(diag, "{s}: the feature \"{s}\" patches a \"syntax\", and caps.author is not declared", .{ d.name, f.name });
    }
    for (d.sets) |s| try checkFeatureNames(&d, s.features, s.name, diag);

    if (d.samples.len == 0) return refuse(diag, "{s}: a language declares at least one sample, which is the whole of what the load check holds it to", .{d.name});
    var plain = false;
    for (d.samples, 0..) |s, i| {
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "sample {d}", .{i}) catch "a sample";
        try checkFeatureNames(&d, s.features, label, diag);
        if (s.features.len == 0) plain = true;
    }
    if (!plain) return refuse(diag, "{s}: at least one sample needs no feature, so every row has one to be held to", .{d.name});
}

/// What `register` works out from a checked description once: each
/// feature's closure, and — for a language that authors — the base table and
/// the patches, each decoded alone so a mistake is refused at its own path,
/// and no two patches spelling the same member.
fn prepare(lang: *Lang, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!void {
    const a = lang.arena.allocator();
    const d = &lang.description;
    for (d.features, 0..) |f, i| {
        lang.declared |= @as(u32, 1) << @intCast(i);
        lang.closure[i] = (@as(u32, 1) << @intCast(i)) | maskOf(d, f.requires);
    }
    // Requirements of requirements: grow every closure until none moves.
    var moved = true;
    while (moved) {
        moved = false;
        for (0..d.features.len) |i| {
            var grown = lang.closure[i];
            var rest = lang.closure[i];
            while (rest != 0) : (rest &= rest - 1) grown |= lang.closure[@ctz(rest)];
            if (grown != lang.closure[i]) {
                lang.closure[i] = grown;
                moved = true;
            }
        }
    }

    if (!d.author) return;
    const base_value = try parseSyntax(a, d.syntax.?, "syntax", diag);
    lang.base_syntax = base_value;
    var problem: syntax_json.Problem = .{};
    const decoded = syntax_json.fromValue(a, .{ .object = base_value }, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSyntax => return refuse(diag, "{s}: syntax.{s} {s}", .{ d.name, problem.path, problem.what }),
    };
    lang.renderers = decoded.renderers;
    const r = decoded.renderers;
    if ((r.render_text or r.spells_autolink) and lang.language.render == null)
        return refuse(diag, "{s}: the syntax names renderers, and the language has no render function", .{d.name});
    if (r.render_block and lang.language.render == null and !d.write)
        return refuse(diag, "{s}: the syntax names render_block, and the language neither renders nor prints", .{d.name});

    lang.patches = try a.alloc(?std.json.ObjectMap, d.features.len);
    for (d.features, lang.patches) |f, *p| {
        const text = f.syntax orelse {
            p.* = null;
            continue;
        };
        const label = try std.fmt.allocPrint(a, "the feature \"{s}\"'s syntax", .{f.name});
        const patch = try parseSyntax(a, text, label, diag);
        if (patch.get("renderers") != null) return refuse(diag, "{s}: {s} names renderers, which are the language's and not a feature's", .{ d.name, label });
        _ = syntax_json.fromValue(a, .{ .object = patch }, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSyntax => return refuse(diag, "{s}: {s}: {s} {s}", .{ d.name, label, problem.path, problem.what }),
        };
        p.* = patch;
    }
    // No two patches spell the same member, or the same key of a keyed one.
    for (lang.patches, 0..) |p, i| {
        const one = p orelse continue;
        for (lang.patches[i + 1 ..], i + 1..) |q, j| {
            const other = q orelse continue;
            if (overlap(one, other)) |path| return refuse(diag, "{s}: the features \"{s}\" and \"{s}\" both patch {s}", .{ d.name, d.features[i].name, d.features[j].name, path });
        }
    }
}

fn parseSyntax(a: Allocator, text: []const u8, label: []const u8, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(diag, "{s} is not JSON", .{label}),
    };
    return switch (v) {
        .object => |o| o,
        else => refuse(diag, "{s} is not an object", .{label}),
    };
}

/// The first member, or key of a keyed member, that both patches spell.
fn overlap(x: std.json.ObjectMap, y: std.json.ObjectMap) ?[]const u8 {
    var it = x.iterator();
    while (it.next()) |member| {
        const key = member.key_ptr.*;
        const other = y.get(key) orelse continue;
        if (isKeyed(key) and member.value_ptr.* == .object and other == .object) {
            var kit = member.value_ptr.object.iterator();
            while (kit.next()) |entry| {
                if (other.object.get(entry.key_ptr.*) != null) return key;
            }
            continue;
        }
        return key;
    }
    return null;
}

/// The samples whose features `mask` has on.
fn samplesUnder(a: Allocator, d: *const Description, lang: *const Lang, mask: u32) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (d.samples) |s| {
        const needs = lang.close(maskOf(d, s.features));
        if (needs & ~mask == 0) try out.append(a, s.text);
    }
    return out.toOwnedSlice(a);
}

fn own(a: Allocator, d: Description) Allocator.Error!Description {
    const features = try a.alloc(Feature, d.features.len);
    for (d.features, features) |f, *o| o.* = .{
        .name = try a.dupe(u8, f.name),
        .default = f.default,
        .requires = try ownAll(a, f.requires),
        .syntax = if (f.syntax) |s| try a.dupe(u8, s) else null,
    };
    const sets = try a.alloc(Set, d.sets.len);
    for (d.sets, sets) |s, *o| o.* = .{
        .name = try a.dupe(u8, s.name),
        .extensions = try ownAll(a, s.extensions),
        .aliases = try ownAll(a, s.aliases),
        .features = try ownAll(a, s.features),
    };
    const samples = try a.alloc(Sample, d.samples.len);
    for (d.samples, samples) |s, *o| o.* = .{ .text = try a.dupe(u8, s.text), .features = try ownAll(a, s.features) };
    return .{
        .name = try a.dupe(u8, d.name),
        .extensions = try ownAll(a, d.extensions),
        .aliases = try ownAll(a, d.aliases),
        .write = d.write,
        .author = d.author,
        .syntax = if (d.syntax) |s| try a.dupe(u8, s) else null,
        .features = features,
        .sets = sets,
        .samples = samples,
    };
}

fn ownAll(a: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |item, *o| o.* = try a.dupe(u8, item);
    return out;
}

/// The engine contract — `contract.all`, the checks every compiled format's
/// harness runs — over each combination of features a row can be asked
/// for that is worth asking: every row's own features, each with one
/// feature more, and every feature on. A combination two rows share is
/// checked once, through the first row that has it.
fn checkRows(gpa: Allocator, lang: *Lang, first: usize, row_count: usize, diag: *Writer) RegisterError!void {
    const d = &lang.description;
    const all = lang.declared;
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);
    for (first..first + row_count) |i| {
        const slot = &slots[i];
        var candidates: std.ArrayList(u32) = .empty;
        defer candidates.deinit(gpa);
        try candidates.append(gpa, slot.mask);
        for (0..d.features.len) |f| {
            const more = slot.mask | lang.closure[f];
            if (more != slot.mask) try candidates.append(gpa, more);
        }
        try candidates.append(gpa, slot.mask | all);
        for (candidates.items) |mask| {
            if (std.mem.indexOfScalar(u32, seen.items, mask) != null) continue;
            try seen.append(gpa, mask);
            try checkUnder(gpa, slot, mask, diag);
        }
    }
}

fn checkUnder(gpa: Allocator, slot: *Slot, mask: u32, diag: *Writer) RegisterError!void {
    const lang = slot.lang;
    var entry = slot.entry;
    entry.syntax = slot.syntaxFor(mask);
    entry.syntaxFor = null;
    entry.samples = try samplesUnder(lang.arena.allocator(), &lang.description, lang, mask);
    var buf: [max_features][]const u8 = undefined;
    const names = lang.names(mask & ~slot.mask, &buf);
    if (lang.description.author) {
        const c = (try slot.combination(mask)).?;
        if (c.failure) |why| return refuseUnder(diag, slot.name, names, "{s}", .{why});
    }
    slot.load_features = mask & ~slot.mask;
    defer slot.load_features = 0;
    var report: contract.Report = .{};
    contract.all(gpa, &entry, &report) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContractBroken => return refuseUnder(diag, slot.name, names, "{s}", .{report.message()}),
    };
}

/// A refusal that says which features were on, when any beyond the row's
/// own were.
fn refuseUnder(diag: *Writer, row: []const u8, names: []const []const u8, comptime fmt: []const u8, args: anytype) error{InvalidLanguage} {
    if (names.len > 0) {
        diag.print("{s} with ", .{row}) catch {};
        for (names, 0..) |n, i| diag.print("{s}{s}", .{ if (i == 0) "" else ", ", n }) catch {};
        diag.writeAll(": ") catch {};
    }
    return refuse(diag, fmt, args);
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// The registry is process-global and append-only, so the tests below share
// it: each registers under a name of its own and never assumes a count.

const testing = std.testing;
const Editor = @import("ast/editor.zig").Editor;
const Djot = @import("languages/djot/djot.zig");
const djot_serializer = @import("languages/djot/serializer.zig");
const Markdown = @import("languages/markdown/markdown.zig");
const markdown_serializer = @import("languages/markdown/serializer.zig");
const markdown_syntax = @import("languages/markdown/syntax.zig");

fn plainSamples(comptime texts: []const []const u8) []const Sample {
    comptime var out: [texts.len]Sample = undefined;
    inline for (texts, 0..) |t, i| out[i] = .{ .text = t };
    const frozen = out;
    return &frozen;
}

/// A language whose "parse" is djot's, written out as a table, and whose
/// "print" is djot's serializer over the decoded table — the compiled row
/// driven through the runtime contract, which is what a twin is. Its
/// renderers are djot's own, over the tables they are handed.
const DjotTwin = struct {
    fn parse(_: ?*anyopaque, allocator: Allocator, _: Call, source: []const u8, _: *Writer) Error![]u8 {
        var doc = Djot.parse(allocator, source) catch return error.LanguageFailed;
        defer doc.deinit();
        return node_table.encodeAlloc(allocator, &doc, .{ .pretty = false });
    }

    fn print(_: ?*anyopaque, allocator: Allocator, _: Call, text: []const u8, diag: *Writer) Error![]u8 {
        var doc = node_table.decodeBare(allocator, text, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                diag.writeAll("the table did not decode") catch {};
                return error.LanguageFailed;
            },
        };
        defer doc.deinit();
        // The Document-aware print, as the compiled row's canonical path:
        // the table carried the parse's labels, which say that a heading's
        // target was implicit and is not to be written out.
        return djot_serializer.serializeAlloc(allocator, &doc) catch error.LanguageFailed;
    }

    fn render(_: ?*anyopaque, allocator: Allocator, _: Call, request: Render, diag: *Writer) Error![]u8 {
        switch (request) {
            .render_text => {
                diag.writeAll("djot spells a literal by its alphabet") catch {};
                return error.LanguageFailed;
            },
            .render_block => |text| {
                var doc = node_table.decodeBare(allocator, text, null) catch return error.LanguageFailed;
                defer doc.deinit();
                return djot_serializer.serializeAstAlloc(allocator, &doc.ast) catch error.LanguageFailed;
            },
            .spells_autolink => |angled| {
                const djot_table = format.syntaxFor(.djot);
                return allocator.dupe(u8, if (djot_table.spellsAutolink.?(djot_table, angled)) "true" else "false");
            },
        }
    }
};

/// Djot's compiled table, as the JSON a description carries.
fn djotSyntaxJson(allocator: Allocator) ![]u8 {
    return syntax_json.encodeAlloc(allocator, format.syntaxFor(.djot), .{ .pretty = false });
}

test "runtime: a registered language is a row every consumer reaches" {
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = register(std.heap.page_allocator, .{ .parse = DjotTwin.parse, .print = DjotTwin.print }, .{
        .name = "djot-twin",
        .extensions = &.{"djtwin"},
        .aliases = &.{"djt"},
        .write = true,
        .samples = plainSamples(&.{ "# Title\n\nSome _emphasis_ and a [link](/u).\n", "- a\n- b\n" }),
    }, &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };

    try testing.expect(isRegistered(fmt));
    try testing.expectEqualStrings("djot-twin", fmt.name());
    try testing.expectEqual(fmt, format.parseFormatName("djot-twin").?);
    try testing.expectEqual(fmt, format.parseFormatName("djt").?);
    try testing.expectEqual(fmt, format.detectFromExtension("notes.DJTWIN").?);
    try testing.expectEqual(@backingInt(fmt), @backingInt(format.targetFor(fmt)));

    const src = "Hello *world*.\n";
    const cfg: format.ParseConfig = .{};
    var doc = try format.entryFor(fmt).parse(&cfg, testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(fmt, doc.format);
    var djot = try Djot.parse(testing.allocator, src);
    defer djot.deinit();
    try testing.expect(djot.ast.eql(doc.doc.ast));

    const html = try format.renderHtmlAlloc(testing.allocator, &doc);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>Hello <strong>world</strong>.</p>\n", html);

    const again = try format.serializeCanonicalAlloc(testing.allocator, &doc);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(src, again);

    // Into the runtime target from a compiled parse, and out of it.
    var md = try format.entryFor(.markdown).parse(&cfg, testing.allocator, "# T\n\n*x*\n");
    defer md.deinit();
    const as_twin = try format.serializeFromAstAlloc(testing.allocator, md.ast(), format.targetFor(fmt));
    defer testing.allocator.free(as_twin);
    try testing.expectEqualStrings("# T\n\n_x_\n", as_twin);

    // The probe measured it, and it measures what djot's table declares.
    const t = format.targetFor(fmt);
    try testing.expectEqual(diagnostics.Fidelity.faithful, diagnostics.fidelity(t, .{ .heading = .{ .level = 2 } }));
    try testing.expectEqual(diagnostics.fidelity(.djot, .{ .inline_mark = .superscript }), diagnostics.fidelity(t, .{ .inline_mark = .superscript }));

    // An editor opens over it, and has nothing to author with.
    var editor = try Editor.init(testing.allocator, src, &cfg, format.entryFor(fmt).parseToAst, format.entryFor(fmt).syntax);
    defer editor.deinit();
    try testing.expect(!format.entryFor(fmt).syntax.authorable());
}

test "runtime: a language that authors is edited like the compiled format it twins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = register(std.heap.page_allocator, .{ .parse = DjotTwin.parse, .print = DjotTwin.print, .render = DjotTwin.render }, .{
        .name = "djot-author",
        .extensions = &.{"djauth"},
        .write = true,
        .author = true,
        .syntax = try djotSyntaxJson(arena),
        .samples = plainSamples(&.{ "# Title\n\nSome _emphasis_ and a [link](/u).\n", "- a\n- b\n\n> q\n" }),
    }, &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };

    // Every gesture djot's table offers, the twin's offers.
    const table = format.syntaxFor(fmt);
    try testing.expect(table.authorable());
    try testing.expect(table.renderer_context != null);
    for ([_]Editor.Gesture{ .set_block, .insert_literal, .insert_link, .{ .toggle_inline = .strong }, .{ .toggle_block_container = .block_quote } }) |g| {
        try testing.expectEqual(Editor.supports(format.syntaxFor(.djot), g), Editor.supports(table, g));
    }

    // A gesture through the row edits as djot's does, renderers and all.
    const src = "Hello world.\n";
    const cfg: format.ParseConfig = .{};
    const entry = format.entryFor(fmt);
    var twin = try Editor.init(testing.allocator, src, &cfg, entry.parseToAst, format.syntaxForConfig(fmt, &cfg));
    defer twin.deinit();
    var real = try Editor.init(testing.allocator, src, &cfg, format.entryFor(.djot).parseToAst, format.syntaxFor(.djot));
    defer real.deinit();
    try twin.toggleInline(.{ .start = 6, .end = 11 }, .strong);
    try real.toggleInline(.{ .start = 6, .end = 11 }, .strong);
    try twin.insertLiteral(0, "*a* ");
    try real.insertLiteral(0, "*a* ");
    try twin.insertLink(.{ .start = 0, .end = 0 }, "https://x.dev");
    try real.insertLink(.{ .start = 0, .end = 0 }, "https://x.dev");
    try testing.expectEqualStrings(real.sourceBytes(), twin.sourceBytes());
}

test "runtime: a language that names render_block and has no render prints its fragments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table = format.syntaxFor(.djot).*;
    table.spellsAutolink = null;
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = register(std.heap.page_allocator, .{ .parse = DjotTwin.parse, .print = DjotTwin.print }, .{
        .name = "djot-printing",
        .write = true,
        .author = true,
        .syntax = try syntax_json.encodeAlloc(arena, &table, .{ .pretty = false }),
        .samples = plainSamples(&.{"# Title\n\nSome _emphasis_.\n"}),
    }, &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };
    // A formula goes in through `renderBlock`, here the twin's print.
    const cfg: format.ParseConfig = .{};
    var twin = try Editor.init(testing.allocator, "Cost.\n", &cfg, format.entryFor(fmt).parseToAst, format.syntaxFor(fmt));
    defer twin.deinit();
    var real = try Editor.init(testing.allocator, "Cost.\n", &cfg, format.entryFor(.djot).parseToAst, format.syntaxFor(.djot));
    defer real.deinit();
    try twin.insertInlineMath(4, "x`y");
    try real.insertInlineMath(4, "x`y");
    try testing.expectEqualStrings(real.sourceBytes(), twin.sourceBytes());
}

/// Markdown, with two of its extensions as features a caller turns on: the
/// language reads its features from the call, and its table moves with them.
const MarkdownFeatures = struct {
    fn options(call: Call) Markdown.ParseOptions {
        var o: Markdown.ParseOptions = .{};
        for (call.feature_names) |n| {
            if (std.mem.eql(u8, n, "math")) o.math = true;
            if (std.mem.eql(u8, n, "highlight")) o.highlight = true;
        }
        return o;
    }

    fn parse(_: ?*anyopaque, allocator: Allocator, call: Call, source: []const u8, _: *Writer) Error![]u8 {
        var doc = Markdown.parse(allocator, source, options(call)) catch return error.LanguageFailed;
        defer doc.deinit();
        return node_table.encodeAlloc(allocator, &doc, .{ .pretty = false });
    }

    fn print(_: ?*anyopaque, allocator: Allocator, _: Call, text: []const u8, _: *Writer) Error![]u8 {
        var doc = node_table.decodeBare(allocator, text, null) catch return error.LanguageFailed;
        defer doc.deinit();
        return markdown_serializer.serializeAlloc(allocator, &doc) catch error.LanguageFailed;
    }

    fn render(_: ?*anyopaque, allocator: Allocator, _: Call, request: Render, _: *Writer) Error![]u8 {
        return switch (request) {
            .render_text => error.LanguageFailed,
            .render_block => |text| {
                var doc = node_table.decodeBare(allocator, text, null) catch return error.LanguageFailed;
                defer doc.deinit();
                return markdown_serializer.serializeAstAlloc(allocator, &doc.ast) catch error.LanguageFailed;
            },
            .spells_autolink => |angled| allocator.dupe(u8, if (Markdown.spellsAutolink(angled)) "true" else "false"),
        };
    }
};

/// The description of `MarkdownFeatures`: Markdown's default table as the
/// base, and as each feature's patch exactly the members Markdown's own
/// table for that option moves.
fn markdownFeaturesDescription(arena: Allocator, name: []const u8) !Description {
    const b = markdown_syntax.table;
    const math = try std.fmt.allocPrint(arena,
        \\{{"text_leaf_delims":{{"inline_math":{{"open":"$","close":"$"}},"display_math":{{"open":"$$","close":"$$"}}}},
        \\ "text_escapes":{f},"link_text_escapes":{f}}}
    , .{
        std.json.fmt(try std.mem.concat(arena, u8, &.{ b.text_escapes.?, "$" }), .{}),
        std.json.fmt(try std.mem.concat(arena, u8, &.{ b.link_text_escapes.?, "$" }), .{}),
    });
    const features = try arena.dupe(Feature, &.{
        .{ .name = "math", .syntax = math },
        .{ .name = "highlight", .syntax = "{\"inline_delims\":{\"mark\":{\"open\":\"==\",\"close\":\"==\"}}}" },
    });
    const sets = try arena.dupe(Set, &.{.{ .name = try std.fmt.allocPrint(arena, "{s}-math", .{name}), .features = &.{"math"} }});
    const samples = try arena.dupe(Sample, &.{
        .{ .text = "# Title\n\nSome *emphasis* and\n==marks==.\n" },
        // A display formula run over three lines, which is the paragraph
        // that found `setBlock` heading its first line alone.
        .{ .text = "A formula, $x^2$, and\n$$\ny\n$$\n", .features = &.{"math"} },
        .{ .text = "A ==highlight== here.\n", .features = &.{"highlight"} },
    });
    return .{
        .name = name,
        .write = true,
        .author = true,
        .syntax = try syntax_json.encodeAlloc(arena, b, .{ .pretty = false }),
        .features = features,
        .sets = sets,
        .samples = samples,
    };
}

/// `s` as JSON, without its renderers — what two tables are compared by
/// when one's renderers are a runtime language's and the other's compiled.
fn spelling(arena: Allocator, s: *const Syntax) ![]u8 {
    var bare = s.*;
    bare.renderText = if (s.text_escapes != null) &syntax_mod.renderTextByAlphabet else null;
    bare.renderBlock = null;
    bare.spellsAutolink = null;
    return syntax_json.encodeAlloc(arena, &bare, .{ .pretty = false });
}

test "runtime: features move a table as Markdown's options move its own, and a set is a row" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const lang: Language = .{ .parse = MarkdownFeatures.parse, .print = MarkdownFeatures.print, .render = MarkdownFeatures.render };
    const fmt = register(std.heap.page_allocator, lang, try markdownFeaturesDescription(arena, "mdf"), &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };

    const math_bit = featureBit(fmt, "math").?;
    const highlight_bit = featureBit(fmt, "highlight").?;
    try testing.expectEqual(@as(u32, 1), math_bit);
    try testing.expectEqual(@as(u32, 2), highlight_bit);
    try testing.expectEqual(@as(?u32, null), featureBit(fmt, "tables"));

    // Each combination spells what Markdown's own table for those options
    // spells, member for member.
    for ([_]struct { u32, Markdown.ParseOptions }{
        .{ 0, .{} },
        .{ math_bit, .{ .math = true } },
        .{ highlight_bit, .{ .highlight = true } },
        .{ math_bit | highlight_bit, .{ .math = true, .highlight = true } },
    }) |case| {
        const cfg: format.ParseConfig = .{ .features = case[0] };
        try testing.expectEqualStrings(
            try spelling(arena, markdown_syntax.forOptions(case[1])),
            try spelling(arena, format.syntaxForConfig(fmt, &cfg)),
        );
    }

    // The parse reads the features too: `$x$` is a formula only with math.
    const src = "Cost $x$.\n";
    const plain: format.ParseConfig = .{};
    var without = try format.entryFor(fmt).parse(&plain, testing.allocator, src);
    defer without.deinit();
    const with_math: format.ParseConfig = .{ .features = math_bit };
    var with = try format.entryFor(fmt).parse(&with_math, testing.allocator, src);
    defer with.deinit();
    var formulas: [2]usize = .{ 0, 0 };
    for ([_]*const AST{ without.ast(), with.ast() }, &formulas) |ast, *n| {
        for (ast.nodes) |node| if (node.kind == .text_leaf) {
            n.* += 1;
        };
    }
    try testing.expectEqual([2]usize{ 0, 1 }, formulas);

    // The set is a row of its own, a dialect of the language's, with its
    // features on before a caller lays any.
    const set = format.parseFormatName("mdf-math").?;
    try testing.expect(set != fmt);
    try testing.expectEqual(fmt, format.entryFor(set).dialect_of.?);
    try testing.expectEqualStrings("mdf-math", set.name());
    try testing.expectEqualStrings(
        try spelling(arena, markdown_syntax.forOptions(.{ .math = true })),
        try spelling(arena, format.syntaxFor(set)),
    );
    var through_set = try format.entryFor(set).parse(&plain, testing.allocator, src);
    defer through_set.deinit();
    try testing.expect(with.ast().eql(through_set.ast().*));

    // An editor over the row with math laid on may insert a formula, and
    // its literal escapes the dollar it would otherwise mint one with.
    var editor = try Editor.init(testing.allocator, "x\n", &with_math, format.entryFor(fmt).parseToAst, format.syntaxForConfig(fmt, &with_math));
    defer editor.deinit();
    try editor.insertLiteral(0, "$5 ");
    try testing.expectEqualStrings("\\$5 x\n", editor.sourceBytes());
    try testing.expect(Editor.supports(format.syntaxForConfig(fmt, &with_math), .insert_inline_math));
    try testing.expect(!Editor.supports(format.syntaxFor(fmt), .insert_inline_math));
}

fn failingParse(_: ?*anyopaque, allocator: Allocator, _: Call, source: []const u8, diag: *Writer) Error![]u8 {
    if (std.mem.startsWith(u8, source, "bad")) {
        diag.writeAll("this language does not read \"bad\"") catch {};
        return error.LanguageFailed;
    }
    // A table whose paragraph claims a span past the source.
    if (std.mem.startsWith(u8, source, "wide")) return allocator.dupe(u8, "{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,1]},{\"kind\":\"para\",\"parent\":0,\"span\":[0,99]}]}");
    return std.fmt.allocPrint(allocator, "{{\"nodes\":[{{\"kind\":\"doc\",\"span\":[0,{d}]}}]}}", .{source.len});
}

fn expectRefusal(description: Description, language: Language, want: []const u8) !void {
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    _ = register(std.heap.page_allocator, language, description, &diag.writer) catch |err| {
        try testing.expectEqual(error.InvalidLanguage, err);
        if (std.mem.indexOf(u8, diag.written(), want) == null) {
            std.debug.print("\nwanted \"{s}\" in \"{s}\"\n", .{ want, diag.written() });
            return error.TestUnexpectedResult;
        }
        return;
    };
    return error.TestUnexpectedResult;
}

test "runtime: load refuses what the description or the samples get wrong" {
    const lang: Language = .{ .parse = failingParse };
    const x = plainSamples(&.{"x"});
    try expectRefusal(.{ .name = "Org", .samples = x }, lang, "lowercase identifier");
    try expectRefusal(.{ .name = "markdown", .samples = x }, lang, "already a format's");
    try expectRefusal(.{ .name = "table", .samples = x }, lang, "already a format's");
    try expectRefusal(.{ .name = "orgish", .aliases = &.{"md"}, .samples = x }, lang, "alias \"md\"");
    try expectRefusal(.{ .name = "orgish", .extensions = &.{"md"}, .samples = x }, lang, "is markdown's");
    try expectRefusal(.{ .name = "orgish", .extensions = &.{".org"}, .samples = x }, lang, "without its dot");
    try expectRefusal(.{ .name = "orgish", .samples = &.{} }, lang, "at least one sample");
    try expectRefusal(.{ .name = "orgish", .write = true, .samples = x }, lang, "needs a print");
    try expectRefusal(.{ .name = "orgish", .samples = plainSamples(&.{ "x", "bad" }) }, lang, "orgish: sample 1 does not parse: orgish: parse failed: this language does not read \"bad\"");
    try expectRefusal(.{ .name = "orgish", .samples = plainSamples(&.{"wide"}) }, lang, "row 1: span: ends past the source");
    // Features, sets and the author tier are held to what they name.
    try expectRefusal(.{ .name = "orgish", .author = true, .samples = x }, lang, "caps.author needs a \"syntax\"");
    try expectRefusal(.{ .name = "orgish", .syntax = "{}", .samples = x }, lang, "caps.author is not declared");
    try expectRefusal(.{ .name = "orgish", .sets = &.{.{ .name = "orgish-x", .features = &.{"nope"} }}, .samples = x }, lang, "\"nope\", which is not a declared feature");
    try expectRefusal(.{ .name = "orgish", .sets = &.{.{ .name = "orgish" }}, .samples = x }, lang, "\"orgish\" is given twice");
    try expectRefusal(.{ .name = "orgish", .features = &.{ .{ .name = "a" }, .{ .name = "a" } }, .samples = x }, lang, "\"a\" is declared twice");
    try expectRefusal(.{ .name = "orgish", .features = &.{.{ .name = "a" }}, .samples = &.{.{ .text = "x", .features = &.{"a"} }} }, lang, "at least one sample needs no feature");
    try expectRefusal(.{ .name = "orgish", .author = true, .syntax = "{\"heading_markr\":\"#\"}", .samples = x }, lang, "orgish: syntax.heading_markr is not a member of this table");
    try expectRefusal(.{
        .name = "orgish",
        .author = true,
        .syntax = "{}",
        .features = &.{
            .{ .name = "a", .syntax = "{\"inline_delims\":{\"strong\":{\"open\":\"*\",\"close\":\"*\"}}}" },
            .{ .name = "b", .syntax = "{\"inline_delims\":{\"emph\":{\"open\":\"_\",\"close\":\"_\"},\"strong\":{\"open\":\"**\",\"close\":\"**\"}}}" },
        },
        .samples = x,
    }, lang, "the features \"a\" and \"b\" both patch inline_delims");
    try expectRefusal(.{ .name = "orgish", .author = true, .syntax = "{\"renderers\":[\"spells_autolink\"]}", .samples = x }, lang, "has no render function");
    try expectRefusal(.{ .name = "orgish", .author = true, .syntax = "{\"renderers\":[\"render_block\"]}", .samples = x }, lang, "neither renders nor prints");
    // A table that breaks a rule is refused with the rule's name.
    try expectRefusal(.{ .name = "orgish", .author = true, .syntax = "{\"link_text_escapes\":\"[]\"}", .samples = x }, lang, "breaks a rule at");
    // Nothing above registered anything.
    try testing.expectEqual(@as(?Format, null), format.parseFormatName("orgish"));
    try testing.expectEqual(@as(?Format, null), format.parseFormatName("orgish-x"));

    // And a read-tier language that passes is a row with no writer.
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = try register(std.heap.page_allocator, lang, .{ .name = "blank-reader", .samples = x }, &diag.writer);
    try testing.expect(format.entryFor(fmt).serializeCanonical == null);
    try testing.expect(format.targetEntryFor(format.targetFor(fmt)).serializeFromAst == null);
    try testing.expect(measured(format.targetFor(fmt)) == null);
    // A later parse that breaks the table is an error with a reason, not a crash.
    const cfg: format.ParseConfig = .{};
    try testing.expectError(error.InvalidTable, format.entryFor(fmt).parse(&cfg, testing.allocator, "wide"));
    try testing.expect(std.mem.indexOf(u8, lastFailure(), "blank-reader: the table is refused: row 1: span") != null);
}

test "runtime: a renderer that lies is refused at load, under the features it lies under" {
    const Liar = struct {
        fn render(_: ?*anyopaque, allocator: Allocator, call: Call, request: Render, diag: *Writer) Error![]u8 {
            // Honest until math is on; then a fragment prints as nothing.
            if (request == .render_block and call.features & 1 != 0) return allocator.dupe(u8, "");
            return MarkdownFeatures.render(null, allocator, call, request, diag);
        }
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const d = try markdownFeaturesDescription(arena_state.allocator(), "mdf-liar");
    try expectRefusal(d, .{ .parse = MarkdownFeatures.parse, .print = MarkdownFeatures.print, .render = Liar.render }, "renderBlock");
    try testing.expectEqual(@as(?Format, null), format.parseFormatName("mdf-liar"));
}

test "runtime: a combination's table is built once, and one that breaks a rule spells nothing" {
    // Load checks a row's own features, each with one more, and all of them,
    // so the combinations a caller can still reach first are the rest — and
    // what keeps those honest is that each is built, validated and kept on
    // first use. Driven here directly, over a language assembled by hand.
    const gpa = testing.allocator;
    var lang: Lang = .{ .language = .{ .parse = failingParse }, .description = .{ .name = "by-hand", .samples = &.{} }, .gpa = gpa, .arena = .init(gpa) };
    defer lang.arena.deinit();
    const a = lang.arena.allocator();
    var diag: Writer.Allocating = .init(gpa);
    defer diag.deinit();
    lang.base_syntax = try parseSyntax(a, "{\"heading_marker\":\"#\",\"inline_delims\":{\"strong\":{\"open\":\"*\",\"close\":\"*\"}}}", "syntax", &diag.writer);
    lang.patches = try a.dupe(?std.json.ObjectMap, &.{
        try parseSyntax(a, "{\"inline_delims\":{\"emph\":{\"open\":\"_\",\"close\":\"_\"}}}", "a", &diag.writer),
        try parseSyntax(a, "{\"link_text_escapes\":\"[]\"}", "b", &diag.writer),
    });
    var slot: Slot = undefined;
    slot.lang = &lang;
    slot.name = "by-hand";
    slot.combos = .empty;

    // A keyed member merges per key: the base's `strong` and the patch's
    // `emph` are both in the table.
    const one = (try slot.combination(1)).?;
    try testing.expect(one.failure == null);
    try testing.expect(one.syntax.inline_delims.get(.strong) != null and one.syntax.inline_delims.get(.emph) != null);
    try testing.expectEqual(@as(?u8, '#'), one.syntax.heading_marker);
    try testing.expectEqual(one, (try slot.combination(1)).?);
    try testing.expect(one.syntax.renderer_context == @as(*const anyopaque, one));

    // Half a link's spelling is refused by name, and the table spells nothing.
    const two = (try slot.combination(3)).?;
    try testing.expect(std.mem.indexOf(u8, two.failure.?, "breaks a rule at link_text_escapes") != null);
    try testing.expect(!two.syntax.authorable());
    try testing.expect(!slot.syntaxFor(3).authorable());
    try testing.expect(std.mem.indexOf(u8, lastFailure(), "by-hand: the table for these features breaks a rule") != null);
}

test "runtime: a description reads from its describe document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const d = try Description.parse(arena.allocator(),
        \\{"name":"org","extensions":["org"],"caps":{"read":true,"write":true,"author":true},
        \\ "syntax":{"heading_marker":"*"},
        \\ "features":[{"name":"math","requires":["tex"],"syntax":{"text_escapes":"$"}},{"name":"tex","default":true}],
        \\ "sets":[{"name":"org-plain","extensions":["orgp"],"features":[]}],
        \\ "samples":["* x\n",{"text":"$x$\n","features":["math"]}],"future":1}
    , &diag.writer);
    try testing.expectEqualStrings("org", d.name);
    try testing.expectEqualStrings("org", d.extensions[0]);
    try testing.expect(d.write and d.author);
    try testing.expectEqualStrings("{\"heading_marker\":\"*\"}", d.syntax.?);
    try testing.expectEqual(@as(usize, 0), d.aliases.len);
    try testing.expectEqualStrings("tex", d.features[0].requires[0]);
    try testing.expectEqualStrings("{\"text_escapes\":\"$\"}", d.features[0].syntax.?);
    try testing.expect(d.features[1].default and d.features[1].syntax == null);
    try testing.expectEqualStrings("orgp", d.sets[0].extensions[0]);
    try testing.expectEqualStrings("math", d.samples[1].features[0]);

    try testing.expectError(error.InvalidLanguage, Description.parse(arena.allocator(),
        \\{"name":"org","dialects":[],"samples":["x"]}
    , &diag.writer));
    try testing.expect(std.mem.indexOf(u8, diag.written(), "a set (\"sets\")") != null);
    diag.clearRetainingCapacity();
    try testing.expectError(error.InvalidLanguage, Description.parse(arena.allocator(),
        \\{"name":"org","samples":[1]}
    , &diag.writer));
    try testing.expect(std.mem.indexOf(u8, diag.written(), "samples[0] is a string") != null);
}

test "runtime: what a feature requires comes on with it" {
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const Seen = struct {
        threadlocal var last: u32 = 0;
        fn parse(ctx: ?*anyopaque, allocator: Allocator, call: Call, source: []const u8, d: *Writer) Error![]u8 {
            last = call.features;
            return failingParse(ctx, allocator, call, source, d);
        }
    };
    const fmt = try register(std.heap.page_allocator, .{ .parse = Seen.parse }, .{
        .name = "requiring",
        .features = &.{ .{ .name = "colors", .requires = &.{"marks"} }, .{ .name = "marks" }, .{ .name = "loud", .default = true } },
        .sets = &.{.{ .name = "requiring-colors", .features = &.{"colors"} }},
        .samples = plainSamples(&.{"x"}),
    }, &diag.writer);
    const cfg: format.ParseConfig = .{ .features = 1 };
    var doc = try format.entryFor(fmt).parse(&cfg, testing.allocator, "x");
    doc.deinit();
    try testing.expectEqual(@as(u32, 0b111), Seen.last);
    const none: format.ParseConfig = .{};
    var set_doc = try format.entryFor(format.parseFormatName("requiring-colors").?).parse(&none, testing.allocator, "x");
    set_doc.deinit();
    try testing.expectEqual(@as(u32, 0b011), Seen.last);
    // A bit no feature holds is not a feature.
    const stray: format.ParseConfig = .{ .features = 1 << 20 };
    var stray_doc = try format.entryFor(fmt).parse(&stray, testing.allocator, "x");
    stray_doc.deinit();
    try testing.expectEqual(@as(u32, 0b100), Seen.last);
}
