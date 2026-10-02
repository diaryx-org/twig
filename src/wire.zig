//! The helper wire: a runtime language served as newline-delimited JSON, one
//! request line to one response line — fig's wire, with twig's node table in
//! it. `docs/proposals/runtime-languages.md` is the argument; `runtime.zig`
//! is what a language becomes once registered.
//!
//! ── The wire ───────────────────────────────────────────────────────────────
//! Requests:
//!
//!     {"op":"describe"}
//!     {"op":"parse","dialect":"org","features":["math"],"input":"…"}
//!     {"op":"print","dialect":"org","features":[],"table":{…}}
//!     {"op":"render","which":"render_text","dialect":"org","features":[],
//!      "text":"…","position":"inline_text"}
//!     {"op":"render","which":"render_block",…,"table":{…}}
//!     {"op":"render","which":"spells_autolink",…,"text":"<…>"}
//!
//! Responses:
//!
//!     {"ok":true,"description":{…}}
//!     {"ok":true,"table":{…}}
//!     {"ok":true,"output":"…"}           print, render_text, render_block
//!     {"ok":true,"output":true}          spells_autolink
//!     {"ok":false,"message":"…"}
//!
//! A description is the `describe` document `runtime.Description` reads; a
//! table is `ast/table.zig`'s, with positions for a parse and without for a
//! print or a fragment. `dialect` is the row the call is through — the
//! language's name, or a set's — and `features` the features in force, by
//! name, the row's own and whatever the caller laid over them; a request
//! with no `features` has none on. `position` is one of `inline_text`,
//! `block_start` and `verbatim`. Every string is UTF-8: a document to parse
//! crosses as a JSON string, so a helper never sees bytes that are not text,
//! and one that is not UTF-8 is refused before it is sent.
//!
//! ── Both ends ──────────────────────────────────────────────────────────────
//! `language` is the CALLING end: a `runtime.Language` whose functions are
//! requests over a `Transport`, which is any way of trading one line for
//! another — a child process's pipes (`cli/languages.zig`), a host's callback
//! through the C ABI (`twig_language_register_transport`). The codec lives
//! here, in core, so no transport re-implements it. `Server` is the ANSWERING
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
    return .{ .context = @constCast(transport), .parse = parse, .print = print, .render = render };
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

/// The members every request through a row carries: which row, and the
/// features in force.
fn writeCall(w: *Writer, c: runtime.Call) Writer.Error!void {
    try w.writeAll(",\"dialect\":");
    try Stringify.value(c.row, .{}, w);
    try w.writeAll(",\"features\":");
    try Stringify.value(c.feature_names, .{}, w);
}

fn parse(context: ?*anyopaque, allocator: Allocator, call_: runtime.Call, source: []const u8, diag: *Writer) runtime.Error![]u8 {
    if (!std.unicode.utf8ValidateSlice(source)) {
        diag.writeAll("a helper reads text, and this input is not UTF-8") catch {};
        return error.LanguageFailed;
    }
    // The request and the parsed response live in an arena; the table is
    // copied out of it, re-encoded, into `allocator`.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var request: Writer.Allocating = .init(a);
    buildRequest(&request.writer, "parse", call_, .{ .input = source }) catch return error.OutOfMemory;
    const obj = try call(context, a, request.written(), diag, "parse");
    const table = obj.get("table") orelse {
        diag.writeAll("parse: the answer has no \"table\"") catch {};
        return error.LanguageFailed;
    };
    return Stringify.valueAlloc(allocator, table, .{});
}

/// `{"op":…,"dialect":…,"features":…` and then `extra`'s members, with any
/// member named `table` written as the JSON text it already is.
fn buildRequest(w: *Writer, op: []const u8, call_: runtime.Call, extra: anytype) Writer.Error!void {
    try w.writeAll("{\"op\":");
    try Stringify.value(op, .{}, w);
    try writeCall(w, call_);
    inline for (std.meta.fields(@TypeOf(extra))) |f| {
        try w.writeAll(",");
        try Stringify.value(f.name, .{}, w);
        try w.writeAll(":");
        if (comptime std.mem.eql(u8, f.name, "table")) {
            try w.writeAll(@field(extra, f.name));
        } else {
            try Stringify.value(@field(extra, f.name), .{}, w);
        }
    }
    try w.writeByte('}');
}

fn print(context: ?*anyopaque, allocator: Allocator, call_: runtime.Call, table: []const u8, diag: *Writer) runtime.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The table is already JSON, and goes in as it is.
    var request: Writer.Allocating = .init(a);
    buildRequest(&request.writer, "print", call_, .{ .table = table }) catch return error.OutOfMemory;
    const obj = try call(context, a, request.written(), diag, "print");
    return output(allocator, obj, diag, "print");
}

fn render(context: ?*anyopaque, allocator: Allocator, call_: runtime.Call, req: runtime.Render, diag: *Writer) runtime.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var request: Writer.Allocating = .init(a);
    (switch (req) {
        .render_text => |t| buildRequest(&request.writer, "render", call_, .{ .which = "render_text", .text = t.text, .position = @tagName(t.position) }),
        .render_block => |table| buildRequest(&request.writer, "render", call_, .{ .which = "render_block", .table = table }),
        .spells_autolink => |angled| buildRequest(&request.writer, "render", call_, .{ .which = "spells_autolink", .text = angled }),
    }) catch return error.OutOfMemory;
    const obj = try call(context, a, request.written(), diag, "render");
    if (req == .spells_autolink) {
        if (obj.get("output")) |o| switch (o) {
            .bool => |b| return allocator.dupe(u8, if (b) "true" else "false"),
            else => {},
        };
    }
    return output(allocator, obj, diag, "render");
}

fn output(allocator: Allocator, obj: std.json.ObjectMap, diag: *Writer, op: []const u8) runtime.Error![]u8 {
    const text = switch (obj.get("output") orelse .null) {
        .string => |o| o,
        else => {
            diag.print("{s}: the answer has no \"output\" string", .{op}) catch {};
            return error.LanguageFailed;
        },
    };
    return allocator.dupe(u8, text);
}

// ── the answering end ───────────────────────────────────────────────────────

/// A language served over the wire: the loop body of a helper written
/// against this library, which reads a line, hands it to `handle`, and
/// writes what comes back.
pub const Server = struct {
    lang: runtime.Language,
    /// The description, compact and on one line, as `describe` answers it.
    description: []const u8,
    /// Its features' names, in the order a mask counts them.
    features: []const []const u8,

    /// Serve `lang` as `description` — a `describe` document, which is read
    /// here so a request's features can be counted against it. The strings
    /// live in `arena`. A description that does not read is refused with why.
    pub fn init(arena: Allocator, lang: runtime.Language, description: []const u8, diag: *Writer) (error{InvalidLanguage} || Allocator.Error)!Server {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, description, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refuse(diag, "the description is not a JSON document", .{}),
        };
        const d = try runtime.Description.fromValue(arena, value, diag);
        const names = try arena.alloc([]const u8, d.features.len);
        for (d.features, names) |f, *n| n.* = f.name;
        return .{ .lang = lang, .description = try Stringify.valueAlloc(arena, value, .{}), .features = names };
    }

    /// One request line to one response line. Never fails for want of a
    /// well-formed request: a request it cannot read is answered with
    /// `"ok": false`, as a language's own refusal is. The response is
    /// allocated with `allocator` and carries no newline.
    pub fn handle(self: *const Server, allocator: Allocator, request: []const u8) Allocator.Error![]u8 {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var diag: Writer.Allocating = .init(a);
        const response = self.respond(a, request, &diag.writer) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Refused => return Stringify.valueAlloc(allocator, .{ .ok = false, .message = diag.written() }, .{}),
        };
        return allocator.dupe(u8, response);
    }

    fn respond(self: *const Server, a: Allocator, request: []const u8, diag: *Writer) (error{Refused} || Allocator.Error)![]const u8 {
        const lang = self.lang;
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, request, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return deny(diag, "the request is not a JSON line"),
        };
        const obj = switch (value) {
            .object => |o| o,
            else => return deny(diag, "the request is not a JSON object"),
        };
        const op = str(obj, "op") orelse return deny(diag, "the request has no \"op\"");
        if (std.mem.eql(u8, op, "describe")) return std.fmt.allocPrint(a, "{{\"ok\":true,\"description\":{s}}}", .{self.description});

        var c: runtime.Call = .{ .row = str(obj, "dialect") orelse "" };
        if (obj.get("features")) |list| {
            const items = switch (list) {
                .array => |arr| arr.items,
                else => return deny(diag, "\"features\" is an array of names"),
            };
            const names = try a.alloc([]const u8, items.len);
            for (items, names) |item, *n| {
                n.* = switch (item) {
                    .string => |name| name,
                    else => return deny(diag, "\"features\" is an array of names"),
                };
                for (self.features, 0..) |declared, i| {
                    if (std.mem.eql(u8, declared, n.*)) {
                        c.features |= @as(u32, 1) << @intCast(i);
                        break;
                    }
                } else {
                    diag.print("\"{s}\" is not a feature this language declares", .{n.*}) catch {};
                    return error.Refused;
                }
            }
            c.feature_names = names;
        }

        if (std.mem.eql(u8, op, "parse")) {
            const input = str(obj, "input") orelse return deny(diag, "parse: the request has no \"input\" string");
            const table = lang.parse(lang.context, a, c, input, diag) catch |err| return refused(err);
            return std.fmt.allocPrint(a, "{{\"ok\":true,\"table\":{s}}}", .{table});
        }
        if (std.mem.eql(u8, op, "print")) {
            const f = lang.print orelse return deny(diag, "print: this language does not print");
            const table = obj.get("table") orelse return deny(diag, "print: the request has no \"table\"");
            const text = try Stringify.valueAlloc(a, table, .{});
            const out = f(lang.context, a, c, text, diag) catch |err| return refused(err);
            return Stringify.valueAlloc(a, .{ .ok = true, .output = out }, .{});
        }
        if (std.mem.eql(u8, op, "render")) {
            const which = str(obj, "which") orelse return deny(diag, "render: the request has no \"which\"");
            // A language with no `render` answers `render_block` with its
            // print, as the in-process carrier does.
            if (lang.render == null and std.mem.eql(u8, which, "render_block")) {
                const p = lang.print orelse return deny(diag, "render: this language neither renders nor prints");
                const table = obj.get("table") orelse return deny(diag, "render: render_block needs a \"table\"");
                const out = p(lang.context, a, c, try Stringify.valueAlloc(a, table, .{}), diag) catch |err| return refused(err);
                return Stringify.valueAlloc(a, .{ .ok = true, .output = out }, .{});
            }
            const f = lang.render orelse return deny(diag, "render: this language names no renderers");
            const req: runtime.Render = if (std.mem.eql(u8, which, "render_text")) .{ .render_text = .{
                .text = str(obj, "text") orelse return deny(diag, "render: render_text needs a \"text\" string"),
                .position = std.meta.stringToEnum(@import("syntax.zig").TextPosition, str(obj, "position") orelse "") orelse
                    return deny(diag, "render: \"position\" is inline_text, block_start or verbatim"),
            } } else if (std.mem.eql(u8, which, "render_block")) .{
                .render_block = try Stringify.valueAlloc(a, obj.get("table") orelse return deny(diag, "render: render_block needs a \"table\""), .{}),
            } else if (std.mem.eql(u8, which, "spells_autolink")) .{
                .spells_autolink = str(obj, "text") orelse return deny(diag, "render: spells_autolink needs a \"text\" string"),
            } else {
                diag.print("render: \"{s}\" is not a renderer", .{which}) catch {};
                return error.Refused;
            };
            const out = f(lang.context, a, c, req, diag) catch |err| return refused(err);
            if (req == .spells_autolink) return Stringify.valueAlloc(a, .{ .ok = true, .output = std.mem.eql(u8, std.mem.trim(u8, out, " \t\r\n"), "true") }, .{});
            return Stringify.valueAlloc(a, .{ .ok = true, .output = out }, .{});
        }
        diag.print("\"{s}\" is not an op this wire has", .{op}) catch {};
        return error.Refused;
    }
};

fn refused(err: runtime.Error) (error{Refused} || Allocator.Error) {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LanguageFailed => error.Refused,
    };
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

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const format = @import("format.zig");
const node_table = @import("ast/table.zig");

/// A transport that answers in-process through a `Server` — both ends of the
/// wire in one test, with nothing spawned. `log` keeps every request line.
const Loopback = struct {
    server: Server,
    transport: Transport = .{ .exchange = exchange },
    log: std.ArrayList(u8) = .empty,

    fn exchange(context: ?*anyopaque, allocator: Allocator, request: []const u8, _: *Writer) anyerror![]u8 {
        const self: *Loopback = @ptrCast(@alignCast(context.?));
        // What a helper would see: the request must be one line.
        try testing.expect(std.mem.indexOfScalar(u8, request, '\n') == null);
        try self.log.appendSlice(std.heap.page_allocator, request);
        try self.log.append(std.heap.page_allocator, '\n');
        const response = try self.server.handle(allocator, request);
        try testing.expect(std.mem.indexOfScalar(u8, response, '\n') == null);
        return response;
    }
};

const Markdown = @import("languages/markdown/markdown.zig");
const markdown_serializer = @import("languages/markdown/serializer.zig");

/// Markdown, as a language on the far side of the wire, reading `math`
/// from the features a call names.
const MarkdownTwin = struct {
    fn parse(_: ?*anyopaque, allocator: Allocator, c: runtime.Call, source: []const u8, _: *Writer) runtime.Error![]u8 {
        var options: Markdown.ParseOptions = .{};
        for (c.feature_names) |n| {
            if (std.mem.eql(u8, n, "math")) options.math = true;
        }
        var doc = Markdown.parse(allocator, source, options) catch return error.LanguageFailed;
        defer doc.deinit();
        return node_table.encodeAlloc(allocator, &doc, .{ .pretty = false });
    }

    fn print(_: ?*anyopaque, allocator: Allocator, _: runtime.Call, text: []const u8, diag: *Writer) runtime.Error![]u8 {
        var doc = node_table.decodeBare(allocator, text, null) catch {
            diag.writeAll("the table did not decode") catch {};
            return error.LanguageFailed;
        };
        defer doc.deinit();
        return markdown_serializer.serializeAlloc(allocator, &doc) catch error.LanguageFailed;
    }

    fn render(_: ?*anyopaque, allocator: Allocator, _: runtime.Call, request: runtime.Render, _: *Writer) runtime.Error![]u8 {
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

fn loopback(lang: runtime.Language, description: []const u8) !*Loopback {
    const loop = try std.heap.page_allocator.create(Loopback);
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    loop.* = .{ .server = Server.init(std.heap.page_allocator, lang, description, &diag.writer) catch |err| {
        std.debug.print("\nserver refused: {s}\n", .{diag.written()});
        return err;
    } };
    loop.transport.context = loop;
    return loop;
}

test "wire: a language across the wire is registered and used like one in process" {
    const loop = try loopback(.{ .parse = MarkdownTwin.parse, .print = MarkdownTwin.print },
        \\{"name": "md-over-wire", "extensions": ["mdw"], "caps": {"write": true},
        \\ "samples": ["# A\n\n- *b*\n- \"c\" \\\\ d\n", "x\n"]}
    );
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
    var direct = try Markdown.parse(testing.allocator, src, .{});
    defer direct.deinit();
    try testing.expect(direct.ast.eql(doc.doc.ast));
    const back = try format.serializeCanonicalAlloc(testing.allocator, &doc);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(src, back);
}

test "wire: a language that authors, with a feature, is edited across the wire as in process" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const md = @import("languages/markdown/syntax.zig").table;
    const description = try std.fmt.allocPrint(arena,
        \\{{"name": "md-author-wire", "caps": {{"write": true, "author": true}},
        \\ "syntax": {s},
        \\ "features": [{{"name": "math", "syntax": {{
        \\   "text_leaf_delims": {{"inline_math": {{"open": "$", "close": "$"}}, "display_math": {{"open": "$$", "close": "$$"}}}},
        \\   "text_escapes": {f}, "link_text_escapes": {f}}}}}],
        \\ "sets": [{{"name": "md-author-wire-math", "features": ["math"]}}],
        \\ "samples": ["# A\n\nSome *b*.\n", {{"text": "A $x$ formula.\n", "features": ["math"]}}]}}
    , .{
        try @import("syntax_json.zig").encodeAlloc(arena, md, .{ .pretty = false }),
        std.json.fmt(try std.mem.concat(arena, u8, &.{ md.text_escapes.?, "$" }), .{}),
        std.json.fmt(try std.mem.concat(arena, u8, &.{ md.link_text_escapes.?, "$" }), .{}),
    });
    const loop = try loopback(.{ .parse = MarkdownTwin.parse, .print = MarkdownTwin.print, .render = MarkdownTwin.render }, description);
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const fmt = register(std.heap.page_allocator, &loop.transport, &diag.writer) catch |err| {
        std.debug.print("\nrefused: {s}\n", .{diag.written()});
        return err;
    };
    const set = format.parseFormatName("md-author-wire-math").?;

    // Through the set's row, math is on: a formula goes in through
    // `render_block` across the wire, and a literal dollar is escaped.
    const Editor = @import("ast/editor.zig").Editor;
    const cfg: format.ParseConfig = .{};
    var editor = try Editor.init(testing.allocator, "Cost.\n", &cfg, format.entryFor(set).parseToAst, format.syntaxForConfig(set, &cfg));
    defer editor.deinit();
    loop.log.clearRetainingCapacity();
    try editor.insertInlineMath(4, "x^2");
    try editor.insertLiteral(0, "$ ");
    try editor.insertLink(.{ .start = 0, .end = 0 }, "https://x.dev");
    try testing.expectEqualStrings("<https://x.dev>\\$ Cost$x^2$.\n", editor.sourceBytes());
    const log = loop.log.items;
    try testing.expect(std.mem.indexOf(u8, log, "{\"op\":\"render\",\"dialect\":\"md-author-wire-math\",\"features\":[\"math\"],\"which\":\"render_block\",\"table\":{") != null);
    try testing.expect(std.mem.indexOf(u8, log, "\"which\":\"spells_autolink\",\"text\":\"<https://x.dev>\"") != null);
    try testing.expect(std.mem.indexOf(u8, log, "{\"op\":\"parse\",\"dialect\":\"md-author-wire-math\",\"features\":[\"math\"],\"input\":") != null);

    // Through the language's own row, with nothing laid over it, the same
    // literal stays bare, and no formula may be minted.
    try testing.expect(!Editor.supports(format.syntaxFor(fmt), .insert_inline_math));
    var plain = try Editor.init(testing.allocator, "Cost.\n", &cfg, format.entryFor(fmt).parseToAst, format.syntaxForConfig(fmt, &cfg));
    defer plain.deinit();
    try plain.insertLiteral(0, "$ ");
    try testing.expectEqualStrings("$ Cost.\n", plain.sourceBytes());
}

test "wire: the answering end refuses what it cannot read, on one line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const server = try Server.init(arena_state.allocator(), .{ .parse = MarkdownTwin.parse },
        \\{"name": "x",
        \\ "features": [{"name": "math"}],
        \\ "samples": ["x"]}
    , &diag.writer);
    for ([_]struct { []const u8, []const u8 }{
        .{ "not json", "not a JSON line" },
        .{ "{\"op\":\"dance\"}", "dance\\\" is not an op" },
        .{ "{\"op\":\"parse\"}", "no \\\"input\\\"" },
        .{ "{\"op\":\"parse\",\"features\":[\"tables\"],\"input\":\"x\"}", "\\\"tables\\\" is not a feature" },
        .{ "{\"op\":\"print\",\"table\":{}}", "does not print" },
        .{ "{\"op\":\"render\",\"which\":\"render_text\"}", "names no renderers" },
    }) |case| {
        const response = try server.handle(testing.allocator, case[0]);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.startsWith(u8, response, "{\"ok\":false"));
        if (std.mem.indexOf(u8, response, case[1]) == null) {
            std.debug.print("\nwanted {s} in {s}\n", .{ case[1], response });
            return error.TestUnexpectedResult;
        }
    }
    // The description goes back as it was given, on one line.
    const described = try server.handle(testing.allocator, "{\"op\":\"describe\"}");
    defer testing.allocator.free(described);
    try testing.expectEqualStrings(
        "{\"ok\":true,\"description\":{\"name\":\"x\",\"features\":[{\"name\":\"math\"}],\"samples\":[\"x\"]}}",
        described,
    );
    // A description that does not read is refused when the server is made.
    try testing.expectError(error.InvalidLanguage, Server.init(arena_state.allocator(), .{ .parse = MarkdownTwin.parse }, "{\"name\":1}", &diag.writer));
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
