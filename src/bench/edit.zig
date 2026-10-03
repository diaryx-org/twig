//! `zig build bench-edit -- [--keys N] <file.dj>` — what a keystroke costs
//! through a runtime row, against the compiled row it twins: step 6 of
//! `docs/proposals/runtime-languages.md`, the part that needs no engine.
//!
//! The twin is djot's own parser written out as a node table, and the table
//! read back — the runtime contract with the language's work held equal, so
//! the difference between the two rows is what the contract costs: encoding
//! the table, decoding it, and the checks a runtime row's output passes
//! through. A language behind an engine or a pipe pays that plus its own
//! parse; `twig-quickjs` measures that half.
//!
//! Each keystroke is `Splicer.replaceAtSpan` inserting one byte in the middle
//! of the document, which reparses it, as an editor's every key does. Wall
//! time per keystroke is reported for both rows, as the median and the 95th
//! percentile, beside the bare parse of each.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const twig = @import("twig");

const runtime = twig.runtime;

const Twin = struct {
    fn parse(_: ?*anyopaque, allocator: Allocator, _: runtime.Call, source: []const u8, _: *Writer) runtime.Error![]u8 {
        var doc = twig.Djot.parse(allocator, source) catch return error.LanguageFailed;
        defer doc.deinit();
        return twig.ast_table.encodeAlloc(allocator, &doc, .{ .pretty = false });
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    const argv = try init.minimal.args.toSlice(arena);
    var keys: usize = 200;
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--keys")) {
            i += 1;
            if (i >= argv.len) return error.MissingKeys;
            keys = try std.fmt.parseInt(usize, argv[i], 10);
        } else path = argv[i];
    }
    const file = path orelse {
        std.debug.print("usage: bench-edit [--keys N] <file.dj>\n", .{});
        return error.MissingFile;
    };
    const source = try Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 * 1024 * 1024));

    const gpa = std.heap.smp_allocator;
    var diag: Writer.Allocating = .init(arena);
    const samples = [_]runtime.Sample{.{ .text = "# T\n\nA *b* c.\n" }};
    const twin = runtime.register(gpa, .{ .parse = Twin.parse }, .{
        .name = "djot-bench-twin",
        .samples = &samples,
    }, &diag.writer) catch |err| {
        std.debug.print("the twin was refused: {s}\n", .{diag.written()});
        return err;
    };

    try out.print("file      : {s}\nsource    : {d} bytes\nkeystrokes: {d}\n\n", .{ file, source.len, keys });
    try out.print("{s:<10} {s:>12} {s:>12} {s:>12}\n", .{ "row", "parse", "key p50", "key p95" });
    var compiled: Result = undefined;
    for ([_]twig.Format{ .djot, twin }) |fmt| {
        const r = try measure(io, gpa, arena, fmt, source, keys);
        if (fmt == .djot) compiled = r;
        try out.print("{s:<10} {d:>10.3}ms {d:>10.3}ms {d:>10.3}ms\n", .{ if (fmt == .djot) "compiled" else "runtime", ms(r.parse), ms(r.p50), ms(r.p95) });
        if (fmt != .djot) try out.print("{s:<10} {d:>11.2}x {d:>11.2}x {d:>11.2}x\n", .{
            "ratio",
            ratio(r.parse, compiled.parse),
            ratio(r.p50, compiled.p50),
            ratio(r.p95, compiled.p95),
        });
    }

    // Where the runtime row's time goes: the language's parse, its table
    // written out, and the table read back (decoded and checked).
    var best = [_]u64{std.math.maxInt(u64)} ** 4;
    for (0..5) |_| {
        const t0 = Io.Clock.awake.now(io);
        var doc = try twig.Djot.parse(gpa, source);
        const t1 = Io.Clock.awake.now(io);
        const text = try twig.ast_table.encodeAlloc(gpa, &doc, .{ .pretty = false });
        const t2 = Io.Clock.awake.now(io);
        doc.deinit();
        var back = try twig.ast_table.decode(gpa, source, text, null);
        const t3 = Io.Clock.awake.now(io);
        back.deinit();
        gpa.free(text);
        best[0] = @min(best[0], nanos(t0, t1));
        best[1] = @min(best[1], nanos(t1, t2));
        best[2] = @min(best[2], nanos(t2, t3));
        best[3] = @min(best[3], text.len);
    }
    try out.print("\nruntime row, by part: language parse {d:.3}ms, table encode {d:.3}ms, table decode {d:.3}ms; table {d} bytes ({d:.1}x the source)\n", .{
        ms(best[0]),
        ms(best[1]),
        ms(best[2]),
        best[3],
        @as(f64, @floatFromInt(best[3])) / @as(f64, @floatFromInt(@max(source.len, 1))),
    });
    try out.flush();
}

const Result = struct { parse: u64, p50: u64, p95: u64 };

fn measure(io: Io, gpa: Allocator, arena: Allocator, fmt: twig.Format, source: []const u8, keys: usize) !Result {
    const entry = twig.format.entryFor(fmt);
    const cfg: twig.format.ParseConfig = .{};

    // The bare parse, best of a few, so a cold cache is not the number.
    var parse_best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t0 = Io.Clock.awake.now(io);
        var doc = try entry.parseToAst(&cfg, gpa, source);
        const t1 = Io.Clock.awake.now(io);
        doc.deinit();
        parse_best = @min(parse_best, nanos(t0, t1));
    }

    var splicer = try twig.Splicer.init(gpa, source, &cfg, entry.parseToAst);
    defer splicer.deinit();
    const times = try arena.alloc(u64, keys);
    for (times) |*t| {
        const at = splicer.sourceBytes().len / 2;
        const t0 = Io.Clock.awake.now(io);
        try splicer.replaceAtSpan(.{ .start = at, .end = at }, "x");
        const t1 = Io.Clock.awake.now(io);
        t.* = nanos(t0, t1);
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    return .{ .parse = parse_best, .p50 = times[keys / 2], .p95 = times[@min(keys - 1, keys * 95 / 100)] };
}

fn nanos(a: Io.Timestamp, b: Io.Timestamp) u64 {
    return @intCast(a.durationTo(b).nanoseconds);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn ratio(a: u64, b: u64) f64 {
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}
