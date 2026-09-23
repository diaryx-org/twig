//! The helper wire: a runtime language served as newline-delimited JSON, one
//! request line to one response line — fig's wire, with twig's node table in
//! it. `docs/proposals/runtime-languages.md` is the argument; `runtime.zig`
//! is what a language becomes once registered.
//!
//! ── The wire ───────────────────────────────────────────────────────────────
//! Requests:
//!
//!     {"op":"describe"}
//!     {"op":"parse","dialect":"org","input":"…"}
//!     {"op":"print","dialect":"org","table":{…}}
//!
//! Responses:
//!
//!     {"ok":true,"description":{…}}
//!     {"ok":true,"table":{…}}
//!     {"ok":true,"output":"…"}
//!     {"ok":false,"message":"…"}
//!
//! A description is the `describe` document `runtime.Description` reads; a
//! table is `ast/table.zig`'s, with positions for a parse and without for a
//! print. `dialect` is the name the language registered under. Every string
//! is UTF-8: a document to parse crosses as a JSON string, so a helper never
//! sees bytes that are not text, and one that is not UTF-8 is refused before
//! it is sent.
//!
//! ── Both ends ──────────────────────────────────────────────────────────────
//! `language` is the CALLING end: a `runtime.Language` whose functions are
//! requests over a `Transport`, which is any way of trading one line for
//! another — a child process's pipes (`cli/languages.zig`), a host's callback
//! through the C ABI (`twig_language_register_transport`). The codec lives
//! here, in core, so no transport re-implements it. `handle` is the ANSWERING
//! end: one request line to one response line over a `runtime.Language`,
//! which is a helper's whole loop but for the reading and writing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

const runtime = @import("runtime.zig");

/// A way of trading one request line for one response line. Neither carries
/// its newline.
pub const Transport = struct {
    context: ?*anyopaque = null,
    /// Send `request`; return the response line, allocated with `allocator`.
    /// An error is a transport that failed — a helper that exited, a pipe
    /// that broke — and `diag` may say more.
    exchange: *const fn (context: ?*anyopaque, allocator: Allocator, request: []const u8, diag: *Writer) anyerror![]u8,
};

pub const DescribeError = error{InvalidLanguage} || Allocator.Error;

/// Ask the other end to describe itself. The description's strings live in
/// `arena`.
pub fn describe(arena: Allocator, transport: *const Transport, diag: *Writer) DescribeError!runtime.Description {
    const response = transport.exchange(transport.context, arena, "{\"op\":\"describe\"}", diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(diag, "describe: the helper did not answer: {t}", .{err}),
    };
    const obj = try answer(arena, response, diag, "describe");
    const value = obj.get("description") orelse return refuse(diag, "describe: the response has no \"description\"", .{});
    return runtime.Description.fromValue(arena, value, diag);
}

/// A `runtime.Language` whose calls are requests over `transport`, which
/// must outlive every registration made with it.
pub fn language(transport: *const Transport) runtime.Language {
    return .{ .context = @constCast(transport), .parse = parse, .print = print };
}

/// `describe`, then register what it describes over the same transport — the
/// one call a runner makes. `gpa` owns the transport's strings for the life
/// of the process, as `runtime.register` asks.
pub fn register(gpa: Allocator, transport: *const Transport, diag: *Writer) runtime.RegisterError!@import("format.zig").Format {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const description = describe(arena.allocator(), transport, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLanguage => return error.InvalidLanguage,
    };
    return runtime.register(gpa, language(transport), description, diag);
}

fn refuse(diag: *Writer, comptime fmt: []const u8, args: anytype) error{InvalidLanguage} {
    diag.print(fmt, args) catch {};
    return error.InvalidLanguage;
}

/// A response line's object, when it says `"ok": true`; its message in
/// `diag` when it says otherwise.
fn answer(arena: Allocator, line: []const u8, diag: *Writer, op: []const u8) error{ InvalidLanguage, OutOfMemory }!std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(diag, "{s}: the helper's answer is not a JSON line", .{op}),
    };
    const obj = switch (value) {
        .object => |o| o,
        else => return refuse(diag, "{s}: the helper's answer is not a JSON object", .{op}),
    };
    const ok = switch (obj.get("ok") orelse .null) {
        .bool => |b| b,
        else => return refuse(diag, "{s}: the helper's answer has no \"ok\"", .{op}),
    };
    if (!ok) {
        const message = switch (obj.get("message") orelse .null) {
            .string => |m| m,
            else => "the helper refused, and said nothing",
        };
        diag.writeAll(message) catch {};
        return error.InvalidLanguage;
    }
    return obj;
}

fn call(context: ?*anyopaque, allocator: Allocator, request: []const u8, diag: *Writer, op: []const u8) runtime.Error!std.json.ObjectMap {
    const transport: *const Transport = @ptrCast(@alignCast(context.?));
    const line = transport.exchange(transport.context, allocator, request, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diag.end == 0) diag.print("the helper did not answer: {t}", .{err}) catch {};
            return error.LanguageFailed;
        },
    };
    return answer(allocator, line, diag, op) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLanguage => return error.LanguageFailed,
    };
}

fn parse(context: ?*anyopaque, allocator: Allocator, row: []const u8, source: []const u8, diag: *Writer) runtime.Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(source)) {
        diag.writeAll("a helper reads text, and this input is not UTF-8") catch {};
        return error.LanguageFailed;
    }
    // The request and the parsed response live in an arena; the table is
    // copied out of it, re-encoded, into `allocator`.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try Stringify.valueAlloc(a, .{ .op = "parse", .dialect = row, .input = source }, .{});
    const obj = try call(context, a, request, diag, "parse");
    const table = obj.get("table") orelse {
        diag.writeAll("parse: the answer has no \"table\"") catch {};
        return error.LanguageFailed;
    };
    return Stringify.valueAlloc(allocator, table, .{});
}

fn print(context: ?*anyopaque, allocator: Allocator, row: []const u8, table: []const u8, diag: *Writer) runtime.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The table is already JSON, and goes in as it is.
    var request: Writer.Allocating = .init(a);
    request.writer.writeAll("{\"op\":\"print\",\"dialect\":") catch return error.OutOfMemory;
    Stringify.value(row, .{}, &request.writer) catch return error.OutOfMemory;
    request.writer.writeAll(",\"table\":") catch return error.OutOfMemory;
    request.writer.writeAll(table) catch return error.OutOfMemory;
    request.writer.writeByte('}') catch return error.OutOfMemory;
    const obj = try call(context, a, request.written(), diag, "print");
    const output = switch (obj.get("output") orelse .null) {
        .string => |o| o,
        else => {
            diag.writeAll("print: the answer has no \"output\" string") catch {};
            return error.LanguageFailed;
        },
    };
    return allocator.dupe(u8, output);
}

// ── the answering end ───────────────────────────────────────────────────────

/// One request line to one response line, over `lang` described by
/// `description` — the loop body of a helper written against this library.
/// Never fails for want of a well-formed request: a request it cannot read
/// is answered with `"ok": false`, as a language's own refusal is. The
/// response is allocated with `allocator` and carries no newline.
pub fn handle(allocator: Allocator, lang: runtime.Language, description: runtime.Description, request: []const u8) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Writer.Allocating = .init(a);
    const response = respond(a, lang, description, request, &diag.writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return Stringify.valueAlloc(allocator, .{ .ok = false, .message = diag.written() }, .{}),
    };
    return allocator.dupe(u8, response);
}

fn respond(a: Allocator, lang: runtime.Language, description: runtime.Description, request: []const u8, diag: *Writer) (error{Refused} || Allocator.Error)![]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, request, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return deny(diag, "the request is not a JSON line"),
    };
    const obj = switch (value) {
        .object => |o| o,
        else => return deny(diag, "the request is not a JSON object"),
    };
    const op = str(obj, "op") orelse return deny(diag, "the request has no \"op\"");
    if (std.mem.eql(u8, op, "describe")) {
        var out: Writer.Allocating = .init(a);
        writeDescription(&out.writer, description) catch return error.OutOfMemory;
        return out.written();
    }
    const row = str(obj, "dialect") orelse description.name;
    if (std.mem.eql(u8, op, "parse")) {
        const input = str(obj, "input") orelse return deny(diag, "parse: the request has no \"input\" string");
        const table = lang.parse(lang.context, a, row, input, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LanguageFailed => return error.Refused,
        };
        return std.fmt.allocPrint(a, "{{\"ok\":true,\"table\":{s}}}", .{table});
    }
    if (std.mem.eql(u8, op, "print")) {
        const f = lang.print orelse return deny(diag, "print: this language does not print");
        const table = obj.get("table") orelse return deny(diag, "print: the request has no \"table\"");
        const text = try Stringify.valueAlloc(a, table, .{});
        const output = f(lang.context, a, row, text, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LanguageFailed => return error.Refused,
        };
        return Stringify.valueAlloc(a, .{ .ok = true, .output = output }, .{});
    }
    diag.print("\"{s}\" is not an op this wire has", .{op}) catch {};
    return error.Refused;
}

fn deny(diag: *Writer, message: []const u8) error{Refused} {
    diag.writeAll(message) catch {};
    return error.Refused;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn writeDescription(w: *Writer, d: runtime.Description) Writer.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.write(.{ .ok = true, .description = .{
        .name = d.name,
        .extensions = d.extensions,
        .aliases = d.aliases,
        .caps = .{ .read = true, .write = d.write },
        .samples = d.samples,
    } });
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const format = @import("format.zig");
const node_table = @import("ast/table.zig");

/// A transport that answers in-process through `handle` — both ends of the
/// wire in one test, with nothing spawned.
const Loopback = struct {
    lang: runtime.Language,
    description: runtime.Description,
    transport: Transport = .{ .exchange = exchange },

    fn exchange(context: ?*anyopaque, allocator: Allocator, request: []const u8, _: *Writer) anyerror![]u8 {
        const self: *Loopback = @ptrCast(@alignCast(context.?));
        // What a helper would see: the request must be one line.
        try testing.expect(std.mem.indexOfScalar(u8, request, '\n') == null);
        const response = try handle(allocator, self.lang, self.description, request);
        try testing.expect(std.mem.indexOfScalar(u8, response, '\n') == null);
        return response;
    }
};

/// Markdown, as a language on the far side of the wire.
const MarkdownTwin = struct {
    fn parse(_: ?*anyopaque, allocator: Allocator, _: []const u8, source: []const u8, _: *Writer) runtime.Error![]u8 {
        var doc = @import("languages/markdown/markdown.zig").parse(allocator, source, .{}) catch return error.LanguageFailed;
        defer doc.deinit();
        return node_table.encodeAlloc(allocator, &doc, .{ .pretty = false });
    }

    fn print(_: ?*anyopaque, allocator: Allocator, _: []const u8, text: []const u8, diag: *Writer) runtime.Error![]u8 {
        var doc = node_table.decodeBare(allocator, text, null) catch {
            diag.writeAll("the table did not decode") catch {};
            return error.LanguageFailed;
        };
        defer doc.deinit();
        return @import("languages/markdown/serializer.zig").serializeAlloc(allocator, &doc) catch error.LanguageFailed;
    }
};

test "wire: a language across the wire is registered and used like one in process" {
    var loop: Loopback = .{
        .lang = .{ .parse = MarkdownTwin.parse, .print = MarkdownTwin.print },
        .description = .{ .name = "md-over-wire", .extensions = &.{"mdw"}, .write = true, .samples = &.{ "# A\n\n- *b*\n- \"c\" \\\\ d\n", "x\n" } },
    };
    loop.transport.context = &loop;
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = register(std.heap.page_allocator, &loop.transport, &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };
    try testing.expectEqualStrings("md-over-wire", fmt.name());
    try testing.expectEqual(fmt, format.detectFromExtension("a.mdw").?);

    const src = "Some *text* with a \"quote\" and a tab\there.\n";
    const cfg: format.ParseConfig = .{};
    var doc = try format.entryFor(fmt).parse(&cfg, testing.allocator, src);
    defer doc.deinit();
    var direct = try @import("languages/markdown/markdown.zig").parse(testing.allocator, src, .{});
    defer direct.deinit();
    try testing.expect(direct.ast.eql(doc.doc.ast));
    const back = try format.serializeCanonicalAlloc(testing.allocator, &doc);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(src, back);
}

test "wire: the answering end refuses what it cannot read, on one line" {
    const lang: runtime.Language = .{ .parse = MarkdownTwin.parse };
    const d: runtime.Description = .{ .name = "x", .samples = &.{"x"} };
    for ([_]struct { []const u8, []const u8 }{
        .{ "not json", "not a JSON line" },
        .{ "{\"op\":\"dance\"}", "dance\\\" is not an op" },
        .{ "{\"op\":\"parse\"}", "no \\\"input\\\"" },
        .{ "{\"op\":\"print\",\"table\":{}}", "does not print" },
    }) |case| {
        const response = try handle(testing.allocator, lang, d, case[0]);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "{\"ok\":false"));
        if (std.mem.indexOf(u8, response, case[1]) == null) {
            std.debug.print("\nwanted {s} in {s}\n", .{ case[1], response });
            return error.TestUnexpectedResult;
        }
    }
    const described = try handle(testing.allocator, lang, d, "{\"op\":\"describe\"}");
    defer testing.allocator.free(described);
    try testing.expectEqualStrings(
        "{\"ok\":true,\"description\":{\"name\":\"x\",\"extensions\":[],\"aliases\":[],\"caps\":{\"read\":true,\"write\":false},\"samples\":[\"x\"]}}",
        described,
    );
}

test "wire: a helper's refusal and a helper's silence both reach the caller as reasons" {
    const Mute = struct {
        fn exchange(_: ?*anyopaque, _: Allocator, _: []const u8, _: *Writer) anyerror![]u8 {
            return error.BrokenPipe;
        }
    };
    const mute: Transport = .{ .exchange = Mute.exchange };
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.InvalidLanguage, register(std.heap.page_allocator, &mute, &diag.writer));
    try testing.expect(std.mem.indexOf(u8, diag.written(), "did not answer: BrokenPipe") != null);

    const Refuser = struct {
        fn exchange(_: ?*anyopaque, allocator: Allocator, _: []const u8, _: *Writer) anyerror![]u8 {
            return allocator.dupe(u8, "{\"ok\":false,\"message\":\"no, thank you\"}");
        }
    };
    const refuser: Transport = .{ .exchange = Refuser.exchange };
    diag.clearRetainingCapacity();
    try testing.expectError(error.InvalidLanguage, register(std.heap.page_allocator, &refuser, &diag.writer));
    try testing.expectEqualStrings("no, thank you", diag.written());
}
