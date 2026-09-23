//! Languages registered at runtime: a format twig did not compile in, carried
//! by a table of functions that parse into the node table (`ast/table.zig`)
//! and print from it. `docs/proposals/runtime-languages.md` is the argument;
//! this file is its in-process carrier.
//!
//! ── What a registration becomes ────────────────────────────────────────────
//! A row like any other. `register` hands back a `Format` whose value is the
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
//! ── What a runtime language may declare ────────────────────────────────────
//! The read and write tiers: `parse`, and optionally `print`. Not `author` —
//! a `Syntax` from outside the library, and the editor gestures it unlocks,
//! wait for the checks that make an unseen spelling table safe to edit with
//! (the proposal's Status names them). A language that declares it is refused
//! by name rather than registered as something less than it said.
//!
//! ── Load is the validation moment ──────────────────────────────────────────
//! A compiled format has its test suite; a runtime one has what it declares,
//! and `register` holds it to that before the row exists: the description is
//! well-formed and claims no name or extension a row already has; then
//! `contract.all`, the checks the harness runs over every compiled row —
//! every sample parses to a table `ast/table.zig` accepts, and a language that
//! prints reparses every sample's print to an equal tree; and the fidelity
//! probe runs over it,
//! so `diagnostics` measures what a conversion into it loses rather than being
//! told. After load, core still validates every table it receives — a parse
//! that fails later is an error naming the language, never a crash.
//!
//! ── Concurrency ────────────────────────────────────────────────────────────
//! Append-only. A registration fills its slot under `lock` and publishes it by
//! bumping `count` with release ordering; a reader that sees the count sees
//! the slot whole, and a slot never changes once published. There is no
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

/// The first `Format`/`Target` value — and C wire code — a registration is
/// given. The C ABI's `TWIG_FORMAT_RUNTIME_BASE` is the same number, checked
/// at comptime there.
pub const base: u16 = 4096;

/// How many languages one process may register.
pub const capacity = 64;

/// What a language's functions may fail with. `LanguageFailed` carries its
/// reason in the `diag` writer it was handed.
pub const Error = error{ LanguageFailed, OutOfMemory };

/// The functions a runtime language supplies. Both exchange the node table
/// as JSON text (`ast/table.zig`), allocated with the allocator they are
/// given; `row` is the name the language registered under, so one table of
/// functions can serve several registrations.
pub const Language = struct {
    context: ?*anyopaque = null,
    /// `source` to the node table of its parse.
    parse: *const fn (context: ?*anyopaque, allocator: Allocator, row: []const u8, source: []const u8, diag: *Writer) Error![]u8,
    /// A node table to source. Its rows carry no positions when the tree
    /// was never parsed from anything — a conversion from another format.
    /// `null` for a language that only reads.
    print: ?*const fn (context: ?*anyopaque, allocator: Allocator, row: []const u8, table: []const u8, diag: *Writer) Error![]u8 = null,
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
    /// Small documents the load check holds the language to. At least one.
    samples: []const []const u8,

    /// Read a `describe` document:
    ///
    ///     {"name": "org", "extensions": ["org"], "aliases": [],
    ///      "caps": {"read": true, "write": true}, "samples": ["* x\n"]}
    ///
    /// Strings borrow from the parsed JSON, which `arena` owns. Unknown keys
    /// are ignored; `caps.author`, `syntax` and `dialects` are refused by name,
    /// since a language declaring them expects what this tier cannot give.
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
        for ([_][]const u8{ "syntax", "dialects" }) |key| {
            if (obj.get(key) != null) return refuse(diag, "\"{s}\" is not open to a runtime language yet: it reads and writes, and does not author", .{key});
        }
        var write = false;
        if (obj.get("caps")) |caps_value| {
            const caps = switch (caps_value) {
                .object => |o| o,
                else => return refuse(diag, "\"caps\" is an object of booleans", .{}),
            };
            if (try flag(caps, "author", diag)) return refuse(diag, "caps.author is not open to a runtime language yet: it reads and writes, and does not author", .{});
            if (caps.get("read")) |_| if (!try flag(caps, "read", diag)) return refuse(diag, "caps.read is every language's", .{});
            write = try flag(caps, "write", diag);
        }
        return .{
            .name = switch (obj.get("name") orelse .null) {
                .string => |s| s,
                else => return refuse(diag, "\"name\" is a string", .{}),
            },
            .extensions = try strings(arena, obj, "extensions", diag),
            .aliases = try strings(arena, obj, "aliases", diag),
            .write = write,
            .samples = try strings(arena, obj, "samples", diag),
        };
    }

    fn flag(obj: std.json.ObjectMap, key: []const u8, diag: *Writer) error{InvalidLanguage}!bool {
        return switch (obj.get(key) orelse return false) {
            .bool => |b| b,
            else => refuse(diag, "caps.{s} is a boolean", .{key}),
        };
    }

    fn strings(arena: Allocator, obj: std.json.ObjectMap, key: []const u8, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)![]const []const u8 {
        const items = switch (obj.get(key) orelse return &.{}) {
            .array => |a| a.items,
            else => return refuse(diag, "\"{s}\" is an array of strings", .{key}),
        };
        const out = try arena.alloc([]const u8, items.len);
        for (items, out) |item, *o| o.* = switch (item) {
            .string => |s| s,
            else => return refuse(diag, "\"{s}\" is an array of strings", .{key}),
        };
        return out;
    }
};

fn refuse(diag: *Writer, comptime fmt: []const u8, args: anytype) error{InvalidLanguage} {
    diag.print(fmt, args) catch {};
    return error.InvalidLanguage;
}

// ── the registry ────────────────────────────────────────────────────────────

const Slot = struct {
    language: Language,
    description: Description,
    entry: format.Entry,
    target: format.TargetEntry,
    /// What a conversion into this language keeps, measured at load. `null`
    /// for a language that does not print, which has nothing to measure.
    measured: ?diagnostics.Measured,

    fn parseDocument(self: *const Slot, allocator: Allocator, source: []const u8) anyerror!Document {
        var diag: Writer.Allocating = .init(allocator);
        defer diag.deinit();
        const text = self.language.parse(self.language.context, allocator, self.description.name, source, &diag.writer) catch |err| {
            fail("{s}: parse failed: {s}", .{ self.description.name, diag.written() });
            return err;
        };
        defer allocator.free(text);
        var problem: node_table.Problem = .{};
        return node_table.decode(allocator, source, text, &problem) catch |err| {
            if (err == error.InvalidTable) failTable(self.description.name, problem);
            return err;
        };
    }

    fn printTable(self: *const Slot, allocator: Allocator, text: []const u8) anyerror![]u8 {
        const print = self.language.print orelse return error.UnsupportedFormat;
        var diag: Writer.Allocating = .init(allocator);
        defer diag.deinit();
        return print(self.language.context, allocator, self.description.name, text, &diag.writer) catch |err| {
            fail("{s}: print failed: {s}", .{ self.description.name, diag.written() });
            return err;
        };
    }
};

var slots: [capacity]Slot = undefined;
var count = std.atomic.Value(u32).init(0);
/// The value of the row `register` is filling, while its load check runs;
/// zero otherwise.
var loading = std.atomic.Value(u16).init(0);
var lock: std.atomic.Mutex = .unlocked;

/// The published slots.
fn published() []const Slot {
    return slots[0..count.load(.acquire)];
}

fn slotOf(value: u16) ?*const Slot {
    if (value < base) return null;
    const i = value - base;
    if (i >= count.load(.acquire)) return null;
    return &slots[i];
}

/// Whether `fmt` names a registered language — false for a compiled row, and
/// for a value in the runtime range that no registration has been given.
pub fn isRegistered(fmt: Format) bool {
    return slotOf(@intFromEnum(fmt)) != null;
}

/// The `Format` a wire code names, if a language holds it.
pub fn formatFromCode(code: i64) ?Format {
    const value = std.math.cast(u16, code) orelse return null;
    _ = slotOf(value) orelse return null;
    return @enumFromInt(value);
}

pub fn entryFor(fmt: Format) ?*const format.Entry {
    return if (slotOf(@intFromEnum(fmt))) |s| &s.entry else null;
}

pub fn targetEntryFor(t: Target) ?*const format.TargetEntry {
    return if (slotOf(@intFromEnum(t))) |s| &s.target else null;
}

/// The name a runtime `Format` or `Target` value was registered under, or
/// `"unregistered"` for a value in the range no language holds.
pub fn nameOf(value: u16) []const u8 {
    if (slotOf(value)) |s| return s.description.name;
    // A row being loaded has its name before it is published, so the load
    // check's messages can say whose samples they are about.
    if (loading.load(.acquire) == value) return slots[value - base].description.name;
    return "unregistered";
}

/// Every registered row, in registration order.
pub fn entries() []const Slot {
    return published();
}

pub fn byName(name: []const u8) ?Format {
    for (published()) |*s| {
        if (std.mem.eql(u8, s.description.name, name)) return s.entry.id;
        for (s.description.aliases) |a| if (std.mem.eql(u8, a, name)) return s.entry.id;
    }
    return null;
}

pub fn byExtension(ext: []const u8) ?Format {
    for (published()) |*s| {
        for (s.description.extensions) |known| if (std.ascii.eqlIgnoreCase(known, ext)) return s.entry.id;
    }
    return null;
}

/// What a conversion into `t` keeps, as the load-time probe measured it.
pub fn measured(t: Target) ?*const diagnostics.Measured {
    const s = slotOf(@intFromEnum(t)) orelse return null;
    return if (s.measured) |*m| m else null;
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
            return .{ .format = s.entry.id, .config = format.ParseConfig.from(ctx).*, .doc = try s.parseDocument(allocator, source) };
        }

        fn parseToAst(_: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
            return slots[i].parseDocument(allocator, source);
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
        /// that `serializeFromAst` rebuilds.
        fn serializeCanonical(allocator: Allocator, doc: *const format.ParsedDoc) anyerror![]u8 {
            const text = try node_table.encodeAlloc(allocator, &doc.doc, .{ .pretty = false, .positions = false });
            defer allocator.free(text);
            return slots[i].printTable(allocator, text);
        }

        fn serializeFromAst(allocator: Allocator, ast: *const AST) anyerror![]u8 {
            const text = try node_table.encodeAstAlloc(allocator, ast, .{ .pretty = false });
            defer allocator.free(text);
            return slots[i].printTable(allocator, text);
        }
    };
}

const RowFns = struct {
    parse: *const fn (*const anyopaque, Allocator, []const u8) anyerror!format.ParsedDoc,
    parseToAst: *const fn (*const anyopaque, Allocator, []const u8) anyerror!Document,
    renderHtml: *const fn (Allocator, *const format.ParsedDoc, *Writer) anyerror!void,
    serializeCanonical: *const fn (Allocator, *const format.ParsedDoc) anyerror![]u8,
    serializeFromAst: *const fn (Allocator, *const AST) anyerror![]u8,
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
        };
    }
    break :blk out;
};

// ── registration ────────────────────────────────────────────────────────────

pub const RegisterError = error{ InvalidLanguage, RegistryFull, OutOfMemory };

/// Names a runtime language may not take: the CLI's `-o` words, which would
/// shadow it on the command line.
const reserved_names = [_][]const u8{ "ast", "table", "canonical" };

/// Register `language` under `description`, run the load check over it, and
/// return the `Format` it answers to. `gpa` owns the copies of the description
/// for the life of the process. On refusal nothing is registered, and `diag`
/// says why.
pub fn register(gpa: Allocator, language: Language, description: Description, diag: *Writer) RegisterError!Format {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();

    const i = count.load(.acquire);
    try checkDescription(description, language, diag);
    if (i >= capacity) return refuseFull(diag);

    const owned = try own(gpa, description);
    const id: Format = @enumFromInt(base + i);
    const fns = rows[i];
    slots[i] = .{
        .language = language,
        .description = owned,
        .entry = .{
            .id = id,
            .samples = owned.samples,
            .extensions = owned.extensions,
            .aliases = owned.aliases,
            .parse = fns.parse,
            .parseToAst = fns.parseToAst,
            .renderHtml = fns.renderHtml,
            .serializeCanonical = if (owned.write) fns.serializeCanonical else null,
        },
        .target = .{
            .id = @enumFromInt(base + i),
            .reads_back_as = id,
            .serializeFromAst = if (owned.write) fns.serializeFromAst else null,
        },
        .measured = null,
    };

    // The slot is filled and not yet published: the checks below call the
    // row's own functions, which read it, while no other reader can see it.
    loading.store(base + @as(u16, @intCast(i)), .release);
    defer loading.store(0, .release);
    try checkContract(gpa, &slots[i], diag);
    // A print that fails on a probe is measured as dropping it, not as a
    // reason to refuse the language: it declared the write tier, not the
    // whole vocabulary.
    if (owned.write) slots[i].measured = try diagnostics.measure(gpa, fns.serializeFromAst, fns.parseToAst);
    count.store(i + 1, .release);
    return id;
}

fn refuseFull(diag: *Writer) error{RegistryFull} {
    diag.print("the registry holds {d} languages and is full", .{capacity}) catch {};
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

fn checkDescription(d: Description, language: Language, diag: *Writer) error{InvalidLanguage}!void {
    if (!isIdentifier(d.name)) return refuse(diag, "the name \"{s}\" is not a lowercase identifier", .{d.name});
    if (nameTaken(d.name)) return refuse(diag, "the name \"{s}\" is already a format's", .{d.name});
    for (d.aliases) |a| {
        if (!isIdentifier(a)) return refuse(diag, "{s}: the alias \"{s}\" is not a lowercase identifier", .{ d.name, a });
        if (nameTaken(a) or std.mem.eql(u8, a, d.name)) return refuse(diag, "{s}: the alias \"{s}\" is already a format's", .{ d.name, a });
    }
    for (d.extensions) |e| {
        if (e.len == 0 or std.mem.indexOfScalar(u8, e, '.') != null) return refuse(diag, "{s}: the extension \"{s}\" is written without its dot", .{ d.name, e });
        for (e) |c| if (std.ascii.isUpper(c)) return refuse(diag, "{s}: the extension \"{s}\" is written in lowercase", .{ d.name, e });
        var probe_path: [80]u8 = undefined;
        const path = std.fmt.bufPrint(&probe_path, "x.{s}", .{e}) catch return refuse(diag, "{s}: the extension \"{s}\" is too long", .{ d.name, e });
        if (format.detectFromExtension(path)) |owner| return refuse(diag, "{s}: the extension \"{s}\" is {s}'s", .{ d.name, e, owner.name() });
    }
    if (d.samples.len == 0) return refuse(diag, "{s}: a language declares at least one sample, which is the whole of what the load check holds it to", .{d.name});
    if (d.write and language.print == null) return refuse(diag, "{s}: caps.write needs a print function", .{d.name});
}

fn own(gpa: Allocator, d: Description) Allocator.Error!Description {
    return .{
        .name = try gpa.dupe(u8, d.name),
        .extensions = try ownAll(gpa, d.extensions),
        .aliases = try ownAll(gpa, d.aliases),
        .write = d.write,
        .samples = try ownAll(gpa, d.samples),
    };
}

fn ownAll(gpa: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, items.len);
    for (items, out) |item, *o| o.* = try gpa.dupe(u8, item);
    return out;
}

/// The engine contract — `contract.all`, the checks every compiled format's
/// harness runs: every sample parses to a table core accepts, and a language
/// that prints reparses each print to an equal tree. The renderer, claim,
/// move and gesture checks apply to a row that authors, which a runtime one
/// does not yet.
fn checkContract(gpa: Allocator, slot: *const Slot, diag: *Writer) RegisterError!void {
    var report: contract.Report = .{};
    contract.all(gpa, &slot.entry, &report) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContractBroken => return refuse(diag, "{s}", .{report.message()}),
    };
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// The registry is process-global and append-only, so the tests below share
// it: each registers under a name of its own and never assumes a count.

const testing = std.testing;

/// A language whose "parse" is djot's, written out as a table, and whose
/// "print" is djot's serializer over the decoded table — the compiled row
/// driven through the runtime contract, which is what a twin is.
const DjotTwin = struct {
    fn parse(_: ?*anyopaque, allocator: Allocator, _: []const u8, source: []const u8, _: *Writer) Error![]u8 {
        var doc = @import("languages/djot/djot.zig").parse(allocator, source) catch return error.LanguageFailed;
        defer doc.deinit();
        return node_table.encodeAlloc(allocator, &doc, .{ .pretty = false });
    }

    fn print(_: ?*anyopaque, allocator: Allocator, _: []const u8, text: []const u8, diag: *Writer) Error![]u8 {
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
        return @import("languages/djot/serializer.zig").serializeAlloc(allocator, &doc) catch error.LanguageFailed;
    }
};

test "runtime: a registered language is a row every consumer reaches" {
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = register(std.heap.page_allocator, .{ .parse = DjotTwin.parse, .print = DjotTwin.print }, .{
        .name = "djot-twin",
        .extensions = &.{"djtwin"},
        .aliases = &.{"djt"},
        .write = true,
        .samples = &.{ "# Title\n\nSome _emphasis_ and a [link](/u).\n", "- a\n- b\n" },
    }, &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };

    try testing.expect(isRegistered(fmt));
    try testing.expectEqualStrings("djot-twin", fmt.name());
    try testing.expectEqual(fmt, format.parseFormatName("djot-twin").?);
    try testing.expectEqual(fmt, format.parseFormatName("djt").?);
    try testing.expectEqual(fmt, format.detectFromExtension("notes.DJTWIN").?);
    try testing.expectEqual(@intFromEnum(fmt), @intFromEnum(format.targetFor(fmt)));

    const src = "Hello *world*.\n";
    const cfg: format.ParseConfig = .{};
    var doc = try format.entryFor(fmt).parse(&cfg, testing.allocator, src);
    defer doc.deinit();
    try testing.expectEqual(fmt, doc.format);
    var djot = try @import("languages/djot/djot.zig").parse(testing.allocator, src);
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
    var editor = try @import("ast/editor.zig").Editor.init(testing.allocator, src, &cfg, format.entryFor(fmt).parseToAst, format.entryFor(fmt).syntax);
    defer editor.deinit();
    try testing.expect(!format.entryFor(fmt).syntax.authorable());
}

fn failingParse(_: ?*anyopaque, allocator: Allocator, _: []const u8, source: []const u8, diag: *Writer) Error![]u8 {
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
    try expectRefusal(.{ .name = "Org", .samples = &.{"x"} }, lang, "lowercase identifier");
    try expectRefusal(.{ .name = "markdown", .samples = &.{"x"} }, lang, "already a format's");
    try expectRefusal(.{ .name = "table", .samples = &.{"x"} }, lang, "already a format's");
    try expectRefusal(.{ .name = "orgish", .aliases = &.{"md"}, .samples = &.{"x"} }, lang, "alias \"md\"");
    try expectRefusal(.{ .name = "orgish", .extensions = &.{"md"}, .samples = &.{"x"} }, lang, "is markdown's");
    try expectRefusal(.{ .name = "orgish", .extensions = &.{".org"}, .samples = &.{"x"} }, lang, "without its dot");
    try expectRefusal(.{ .name = "orgish", .samples = &.{} }, lang, "at least one sample");
    try expectRefusal(.{ .name = "orgish", .write = true, .samples = &.{"x"} }, lang, "needs a print");
    try expectRefusal(.{ .name = "orgish", .samples = &.{ "x", "bad" } }, lang, "orgish: sample 1 does not parse: orgish: parse failed: this language does not read \"bad\"");
    try expectRefusal(.{ .name = "orgish", .samples = &.{"wide"} }, lang, "row 1: span: ends past the source");
    // Nothing above registered anything.
    try testing.expectEqual(@as(?Format, null), format.parseFormatName("orgish"));

    // And a read-tier language that passes is a row with no writer.
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = try register(std.heap.page_allocator, lang, .{ .name = "blank-reader", .samples = &.{"x"} }, &diag.writer);
    try testing.expect(format.entryFor(fmt).serializeCanonical == null);
    try testing.expect(format.targetEntryFor(format.targetFor(fmt)).serializeFromAst == null);
    try testing.expect(measured(format.targetFor(fmt)) == null);
    // A later parse that breaks the table is an error with a reason, not a crash.
    const cfg: format.ParseConfig = .{};
    try testing.expectError(error.InvalidTable, format.entryFor(fmt).parse(&cfg, testing.allocator, "wide"));
    try testing.expect(std.mem.indexOf(u8, lastFailure(), "blank-reader: the table is refused: row 1: span") != null);
}

test "runtime: a description reads from its describe document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const d = try Description.parse(arena.allocator(),
        \\{"name":"org","extensions":["org"],"caps":{"read":true,"write":true},"samples":["* x\n"],"future":1}
    , &diag.writer);
    try testing.expectEqualStrings("org", d.name);
    try testing.expectEqualStrings("org", d.extensions[0]);
    try testing.expect(d.write);
    try testing.expectEqual(@as(usize, 0), d.aliases.len);

    try testing.expectError(error.InvalidLanguage, Description.parse(arena.allocator(),
        \\{"name":"org","caps":{"author":true},"samples":["x"]}
    , &diag.writer));
    try testing.expect(std.mem.indexOf(u8, diag.written(), "caps.author is not open") != null);
    try testing.expectError(error.InvalidLanguage, Description.parse(arena.allocator(),
        \\{"name":"org","syntax":{},"samples":["x"]}
    , &diag.writer));
}
