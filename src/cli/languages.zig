//! Languages the CLI did not compile in: the `languages` file that names
//! them, the helper runner that speaks to each as a child process, and
//! `twig lang list` and `twig lang check`. `docs/proposals/runtime-languages.md`
//! is the argument; `twig.wire` is the codec.
//!
//! ── The file ───────────────────────────────────────────────────────────────
//! One language per line: its name, a comma-separated list of extensions or
//! `-` for none, then the command and its arguments, separated by
//! whitespace. A `#` that begins a word comments out the rest of the line; a
//! leading `~` in any argument is `$HOME`. There is no quoting — a command
//! that needs an argument with a space in it is a script.
//!
//!     # name   extensions   command…
//!     org      org          twig-quickjs ~/.config/twig/org.mjs
//!     wiki     wiki,mw      /usr/local/bin/wiki-helper --strict
//!
//! Found in this order, the earlier file winning a name: `$TWIG_LANGUAGES`
//! (a path — how a test points at one); `.twig/languages` in the working
//! directory and each ancestor; `$XDG_CONFIG_HOME/twig/languages`, which is
//! `~/.config/twig/languages` when the variable is unset. It is not fig
//! format, because twig does not depend on fig; if it ever does, the file
//! becomes `languages.figl` and this line form stays accepted.
//!
//! ── When a helper runs ─────────────────────────────────────────────────────
//! Only when `-i`, `-o`, `--lang` or a file's extension names nothing built
//! in: `format.zig`'s resolvers fall through to `resolveName` and
//! `resolveExtension` here, which read the file once and spawn only the
//! helper that answers. A compiled format's name or extension always wins,
//! and a runtime language may not claim one anyway. `lang list` and
//! `lang check` spawn on purpose.
//!
//! A spawned helper is asked `describe`, must describe itself by the name
//! its line gives, and is then registered through `twig.runtime.register` —
//! the load check runs, as for any runtime language — over a transport whose
//! lines cross the child's stdin and stdout. Its stderr stays on the
//! terminal, so a helper that wants to say why it refused something can. One
//! process per helper per invocation; it is never respawned, because an
//! invocation that loses its helper has nothing left to do with it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const builtin = @import("builtin");

const twig = @import("twig");
const Format = twig.format.Format;

/// One configured language, as its line states it.
pub const Configured = struct {
    name: []const u8,
    extensions: []const []const u8,
    command: []const []const u8,
    /// The file it came from, for `lang list` and for a message.
    source: []const u8,
    /// Set once the helper has been spawned and registered.
    format: ?Format = null,
    /// Why it was refused, when it was, so a second ask does not spawn again.
    failure: ?[]const u8 = null,
};

/// The process-wide state, set by `init` before arguments are parsed. One
/// invocation, one configuration.
var state: struct {
    io: ?Io = null,
    allocator: Allocator = undefined,
    environ: ?*const std.process.Environ.Map = null,
    /// Where a warning or a refusal is reported: the CLI's own stderr
    /// writer, so the two cannot interleave out of order.
    stderr: ?*Writer = null,
    loaded: bool = false,
    configured: std.ArrayList(Configured) = .empty,
} = .{};

/// Give the module what it needs to read files and spawn: called once from
/// `main` before `parseConfig`, which is where names and extensions resolve.
pub fn init(io: Io, allocator: Allocator, environ: *const std.process.Environ.Map, stderr: *Writer) void {
    state.io = io;
    state.allocator = allocator;
    state.environ = environ;
    state.stderr = stderr;
}

// ── the file ────────────────────────────────────────────────────────────────

/// Read every `languages` file in the search order, once. A missing file is
/// not an error; a malformed line is reported and skipped.
pub fn load() void {
    if (state.loaded) return;
    state.loaded = true;
    const io = state.io orelse return;
    const a = state.allocator;
    const env = state.environ orelse return;

    if (env.get("TWIG_LANGUAGES")) |path| loadFile(io, a, path);

    if (std.process.currentPathAlloc(io, a)) |cwd| {
        var dir: []const u8 = cwd;
        while (true) {
            const candidate = std.fs.path.join(a, &.{ dir, ".twig", "languages" }) catch break;
            loadFile(io, a, candidate);
            const parent = std.fs.path.dirname(dir) orelse break;
            if (parent.len == dir.len) break;
            dir = parent;
        }
    } else |_| {}

    const user_path = if (env.get("XDG_CONFIG_HOME")) |h|
        std.fs.path.join(a, &.{ h, "twig", "languages" }) catch return
    else if (env.get("HOME")) |home|
        std.fs.path.join(a, &.{ home, ".config", "twig", "languages" }) catch return
    else
        return;
    loadFile(io, a, user_path);
}

fn loadFile(io: Io, a: Allocator, path: []const u8) void {
    const content = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            warn("could not read {s}: {t}", .{ path, err });
            return;
        },
    };
    parseFile(a, path, content) catch |err| warn("{s}: {t}", .{ path, err });
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    report("warning: languages: " ++ fmt ++ "\n", args);
}

fn report(comptime fmt: []const u8, args: anytype) void {
    const w = state.stderr orelse return std.debug.print(fmt, args);
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

/// Add every line of one file, skipping a name an earlier file gave.
fn parseFile(a: Allocator, source: []const u8, content: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        while (it.next()) |w| {
            if (w[0] == '#') break;
            try words.append(a, w);
        }
        if (words.items.len == 0) continue;
        if (words.items.len < 3) {
            warn("{s}:{d}: a line is a name, its extensions (or -), and a command", .{ source, n });
            continue;
        }
        const name = words.items[0];
        if (findConfigured(name) != null) continue;
        var exts: std.ArrayList([]const u8) = .empty;
        if (!std.mem.eql(u8, words.items[1], "-")) {
            var parts = std.mem.splitScalar(u8, words.items[1], ',');
            while (parts.next()) |p| if (p.len > 0) try exts.append(a, p);
        }
        try state.configured.append(a, .{
            .name = name,
            .extensions = exts.items,
            .command = words.items[2..],
            .source = source,
        });
    }
}

fn findConfigured(name: []const u8) ?*Configured {
    for (state.configured.items) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// Every configured language, the file read if it had not been.
pub fn configured() []Configured {
    load();
    return state.configured.items;
}

// ── resolution ──────────────────────────────────────────────────────────────

/// The format a configured language named `name` answers to, spawning and
/// registering its helper on first ask; `null` when no line names it, or
/// when its helper was refused (the refusal is printed the first time).
pub fn resolveName(name: []const u8) ?Format {
    load();
    const c = findConfigured(name) orelse return null;
    return ensureLogged(c);
}

/// The format of the configured language owning `ext`, spawning as above.
pub fn resolveExtension(ext: []const u8) ?Format {
    load();
    for (state.configured.items) |*c| {
        for (c.extensions) |x| if (std.ascii.eqlIgnoreCase(x, ext)) return ensureLogged(c);
    }
    return null;
}

/// Spawn and register `c` if it has not been. A refusal is kept in
/// `c.failure` and not retried.
pub fn ensure(c: *Configured) ?Format {
    if (c.format) |f| return f;
    if (c.failure != null) return null;
    var diag: Writer.Allocating = .init(state.allocator);
    c.format = spawnAndRegister(c.name, c.command, &diag.writer) catch {
        c.failure = if (diag.written().len > 0) diag.written() else "refused";
        return null;
    };
    return c.format;
}

fn ensureLogged(c: *Configured) ?Format {
    const already = c.failure != null;
    const f = ensure(c);
    if (f == null and !already) report("error: language `{s}` ({s}): {s}\n", .{ c.name, c.source, c.failure.? });
    return f;
}

// ── the helper runner ───────────────────────────────────────────────────────

/// One spawned helper: the process, its pipes, and the transport over them.
/// Lives for the process; the registered language's context is `transport`.
const Helper = struct {
    transport: twig.wire.Transport,
    child: std.process.Child,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    read_buf: [64 * 1024]u8 = undefined,
    write_buf: [64 * 1024]u8 = undefined,

    fn exchange(context: ?*anyopaque, allocator: Allocator, request: []const u8, _: *Writer) anyerror![]u8 {
        const self: *Helper = @ptrCast(@alignCast(context.?));
        try self.writer.interface.writeAll(request);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        if (!try readLine(&self.reader.interface, allocator, &line)) return error.HelperExited;
        return line.toOwnedSlice(allocator);
    }
};

/// One whole line, however long, without its newline. `false` at the end
/// of the stream with nothing read.
fn readLine(r: *Io.Reader, allocator: Allocator, out: *std.ArrayList(u8)) !bool {
    while (true) {
        const chunk = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const buf = r.buffered();
                try out.appendSlice(allocator, buf);
                r.toss(buf.len);
                continue;
            },
            error.EndOfStream => {
                const rest = r.buffered();
                try out.appendSlice(allocator, rest);
                r.toss(rest.len);
                return out.items.len > 0;
            },
            else => return err,
        };
        try out.appendSlice(allocator, chunk[0 .. chunk.len - 1]);
        return true;
    }
}

pub const SpawnError = twig.runtime.RegisterError || error{ SpawnFailed, NameMismatch };

/// Start `command`, ask it to describe itself, hold it to `name` when one is
/// given, and register it.
pub fn spawnAndRegister(name: ?[]const u8, command: []const []const u8, diag: *Writer) SpawnError!Format {
    const io = state.io orelse return error.SpawnFailed;
    const a = state.allocator;
    const helper = try a.create(Helper);
    helper.* = .{
        .transport = .{ .exchange = Helper.exchange },
        .child = undefined,
        .reader = undefined,
        .writer = undefined,
    };
    helper.transport.context = helper;
    const argv = try expandArgv(a, command);
    helper.child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        diag.print("could not start `{s}`: {t}", .{ argv[0], err }) catch {};
        return error.SpawnFailed;
    };
    helper.reader = helper.child.stdout.?.readerStreaming(io, &helper.read_buf);
    helper.writer = helper.child.stdin.?.writerStreaming(io, &helper.write_buf);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const description = twig.wire.describe(arena.allocator(), &helper.transport, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLanguage => return error.InvalidLanguage,
    };
    if (name) |want| if (!std.mem.eql(u8, description.name, want)) {
        diag.print("the helper describes itself as `{s}`, but its line calls it `{s}`", .{ description.name, want }) catch {};
        return error.NameMismatch;
    };
    return twig.runtime.register(a, twig.wire.language(&helper.transport), description, diag);
}

/// `command` with a leading `~` in any argument expanded to `$HOME`.
fn expandArgv(a: Allocator, command: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, command.len);
    for (command, out) |arg, *o| {
        o.* = arg;
        if (arg.len > 0 and arg[0] == '~') {
            const env = state.environ orelse continue;
            const home = env.get("HOME") orelse continue;
            o.* = try std.fmt.allocPrint(a, "{s}{s}", .{ home, arg[1..] });
        }
    }
    return out;
}

// ── `twig lang` ─────────────────────────────────────────────────────────────

fn capsWord(fmt: Format) []const u8 {
    const entry = twig.format.entryFor(fmt);
    const writes = entry.serializeCanonical != null;
    const authors = entry.syntax.authorable();
    if (writes and authors) return "read write author";
    if (writes) return "read write";
    if (authors) return "read author";
    return "read";
}

fn writeExtensions(w: *Writer, exts: []const []const u8) Writer.Error!void {
    for (exts) |x| try w.print(" .{s}", .{x});
}

/// `twig lang list`: every compiled format and every configured language,
/// with what each can do. A configured language is spawned to be asked.
pub fn list(out: *Writer) Writer.Error!void {
    try out.writeAll("compiled:\n");
    for (&twig.format.registry) |*e| {
        try out.print("  {s:<12} {s:<18}", .{ e.id.name(), capsWord(e.id) });
        try writeExtensions(out, e.extensions);
        if (e.dialect_of) |lang| try out.print("  (a {s} dialect)", .{lang.name()});
        try out.writeByte('\n');
    }
    const langs = configured();
    if (langs.len == 0) {
        try out.writeAll("configured: none (no languages file found)\n");
        return;
    }
    try out.writeAll("configured:\n");
    for (langs) |*c| {
        if (ensure(c)) |f| {
            try out.print("  {s:<12} {s:<18}", .{ c.name, capsWord(f) });
            try writeExtensions(out, twig.format.entryFor(f).extensions);
            try out.print("  ({s})\n", .{c.source});
        } else {
            try out.print("  {s:<12} refused: {s}  ({s})\n", .{ c.name, c.failure.?, c.source });
        }
    }
}

pub const CheckError = error{ CheckFailed, OutOfMemory, WriteFailed };

/// `twig lang check`: load a language — which is the load check over its
/// samples — and, given a compiled format to hold it to, parse each sample
/// and each file with both and compare the node tables row for row. Reports
/// the first difference in each and fails if there was one.
pub fn check(
    out: *Writer,
    err_out: *Writer,
    name: ?[]const u8,
    command: []const []const u8,
    against: ?Format,
    files: []const []const u8,
) CheckError!void {
    const a = state.allocator;
    var diag: Writer.Allocating = .init(a);
    const fmt = if (name) |n| blk: {
        if (twig.format.parseFormatName(n)) |f| {
            if (twig.runtime.isRegistered(f)) break :blk f;
            try err_out.print("error: `{s}` is compiled in; lang check checks a runtime language\n", .{n});
            return error.CheckFailed;
        }
        load();
        const c = findConfigured(n) orelse {
            try err_out.print("error: no language named `{s}` is configured\n", .{n});
            return error.CheckFailed;
        };
        break :blk ensure(c) orelse {
            try out.print("{s}: refused: {s}\n", .{ n, c.failure.? });
            return error.CheckFailed;
        };
    } else spawnAndRegister(null, command, &diag.writer) catch {
        try out.print("{s}: refused: {s}\n", .{ command[0], diag.written() });
        return error.CheckFailed;
    };
    const entry = twig.format.entryFor(fmt);
    try out.print("{s}: registered ({s}); every sample parsed", .{ fmt.name(), capsWord(fmt) });
    if (entry.serializeCanonical != null) try out.writeAll(", printed and reparsed to the same tree; fidelity measured");
    try out.writeAll("\n");

    const sibling = against orelse return;
    const Input = struct { label: []const u8, content: []const u8 };
    var inputs: std.ArrayList(Input) = .empty;
    for (entry.samples, 0..) |s, i| try inputs.append(a, .{ .label = try std.fmt.allocPrint(a, "sample {d}", .{i}), .content = s });
    for (files) |f| {
        const content = Io.Dir.cwd().readFileAlloc(state.io.?, f, a, .limited(64 << 20)) catch |e| {
            try err_out.print("error: could not read {s}: {t}\n", .{ f, e });
            return error.CheckFailed;
        };
        try inputs.append(a, .{ .label = f, .content = content });
    }
    var failed = false;
    const cfg: twig.format.ParseConfig = .{};
    for (inputs.items) |in| {
        var mine = entry.parse(&cfg, a, in.content) catch |e| {
            try out.print("{s}: `{s}` does not parse it: {s}\n", .{ in.label, fmt.name(), failureOf(e) });
            failed = true;
            continue;
        };
        defer mine.deinit();
        var theirs = twig.format.entryFor(sibling).parse(&cfg, a, in.content) catch |e| {
            try out.print("{s}: `{s}` does not parse it: {t}\n", .{ in.label, sibling.name(), e });
            failed = true;
            continue;
        };
        defer theirs.deinit();
        if (try firstDifference(a, &mine.doc, &theirs.doc)) |d| {
            try out.print("{s}: differs from `{s}` at row {d}:\n  {s}: {s}\n  {s}: {s}\n", .{ in.label, sibling.name(), d.row, fmt.name(), d.mine, sibling.name(), d.theirs });
            failed = true;
        } else {
            try out.print("{s}: same table as `{s}` ({d} rows)\n", .{ in.label, sibling.name(), mine.doc.ast.nodes.len });
        }
    }
    if (failed) return error.CheckFailed;
}

/// Why a runtime call failed, as the registry recorded it.
pub fn failureOf(err: anyerror) []const u8 {
    const why = twig.runtime.lastFailure();
    return if (why.len > 0) why else @errorName(err);
}

const Difference = struct { row: usize, mine: []const u8, theirs: []const u8 };

/// The first row at which two documents' tables differ, each row as its JSON
/// line; `null` when every row and the label table agree.
fn firstDifference(a: Allocator, mine: *const twig.Document, theirs: *const twig.Document) Allocator.Error!?Difference {
    const x = try twig.ast_table.encodeAlloc(a, mine, .{});
    const y = try twig.ast_table.encodeAlloc(a, theirs, .{});
    var xs = std.mem.splitScalar(u8, x, '\n');
    var ys = std.mem.splitScalar(u8, y, '\n');
    // The first two lines open the table; rows follow one a line.
    var line: usize = 0;
    while (true) : (line += 1) {
        const l = xs.next();
        const r = ys.next();
        if (l == null and r == null) return null;
        const lt = std.mem.trim(u8, l orelse "(no row)", " ,");
        const rt = std.mem.trim(u8, r orelse "(no row)", " ,");
        if (!std.mem.eql(u8, lt, rt)) return .{ .row = line -| 2, .mine = lt, .theirs = rt };
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_stderr_buf: [4096]u8 = undefined;
var test_stderr: Writer = .fixed(&test_stderr_buf);

fn resetForTest(a: Allocator) void {
    state.configured = .empty;
    state.loaded = true;
    state.allocator = a;
    test_stderr = .fixed(&test_stderr_buf);
    state.stderr = &test_stderr;
}

test "languages: one line a language; an earlier file wins a name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    resetForTest(a);
    try parseFile(a, "first",
        \\# name   exts      command
        \\org      org       twig-quickjs ~/org.mjs   # the Org twin
        \\wiki     wiki,mw   wiki-helper --strict
        \\
        \\broken   x
    );
    try parseFile(a, "second",
        \\wiki     -         other
        \\bare     -         bare-helper
    );
    const langs = configured();
    try testing.expect(std.mem.indexOf(u8, test_stderr.buffered(), "first:5: a line is a name") != null);
    try testing.expectEqual(@as(usize, 3), langs.len);
    try testing.expectEqualStrings("org", langs[0].name);
    try testing.expectEqual(@as(usize, 2), langs[0].command.len);
    try testing.expectEqualStrings("~/org.mjs", langs[0].command[1]);
    try testing.expectEqualStrings("mw", langs[1].extensions[1]);
    try testing.expectEqualStrings("first", langs[1].source);
    try testing.expectEqual(@as(usize, 2), langs[1].command.len);
    try testing.expectEqual(@as(usize, 0), langs[2].extensions.len);
}

test "languages: a leading ~ in any argument is $HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/adam");
    state.environ = &env;
    defer state.environ = null;
    const argv = try expandArgv(a, &.{ "helper", "~/x.mjs", "not~here" });
    try testing.expectEqualStrings("/home/adam/x.mjs", argv[1]);
    try testing.expectEqualStrings("not~here", argv[2]);
}

/// A helper in `sh`: it reads one language, "shx", whose every document is
/// the one-character `x` — enough to be described, registered and parsed.
const sh_helper =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *describe*) printf '%s\n' '{"ok":true,"description":{"name":"shx","extensions":["shx"],"caps":{"read":true},"samples":["x"]}}' ;;
    \\    *parse*) printf '%s\n' '{"ok":true,"table":{"nodes":[{"kind":"doc","span":[0,1]},{"kind":"para","parent":0,"span":[0,1]},{"kind":"str","parent":1,"span":[0,1],"text":"x"}]}}' ;;
    \\    *) printf '%s\n' '{"ok":false,"message":"shx only reads"}' ;;
    \\  esac
    \\done
;

test "languages: a helper process is spawned, described, registered and asked" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    resetForTest(a);
    state.io = testing.io;
    var env = std.process.Environ.Map.init(a);
    state.environ = &env;
    defer state.environ = null;

    try state.configured.append(a, .{ .name = "shx", .extensions = &.{"shx"}, .command = &.{ "sh", "-c", sh_helper }, .source = "test" });
    const fmt = resolveExtension("shx") orelse {
        std.debug.print("\nrefused: {s}\n", .{state.configured.items[0].failure orelse "?"});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(fmt, resolveName("shx").?);
    try testing.expectEqualStrings("shx", fmt.name());

    const cfg: twig.format.ParseConfig = .{};
    var doc = try twig.format.entryFor(fmt).parse(&cfg, testing.allocator, "x");
    defer doc.deinit();
    const html = try twig.format.renderHtmlAlloc(testing.allocator, &doc);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>x</p>\n", html);

    // A line whose helper calls itself something else is refused, once.
    try state.configured.append(a, .{ .name = "notshx", .extensions = &.{}, .command = &.{ "sh", "-c", sh_helper }, .source = "test" });
    try testing.expectEqual(@as(?Format, null), ensure(&state.configured.items[1]));
    try testing.expect(std.mem.indexOf(u8, state.configured.items[1].failure.?, "describes itself as `shx`") != null);

    // A helper that exits without answering, and one that cannot start.
    var diag: Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.InvalidLanguage, spawnAndRegister(null, &.{ "sh", "-c", "exit 0" }, &diag.writer));
    try testing.expect(std.mem.indexOf(u8, diag.written(), "did not answer") != null);
    diag.clearRetainingCapacity();
    try testing.expectError(error.SpawnFailed, spawnAndRegister(null, &.{"/nonexistent/twig-helper"}, &diag.writer));
}
