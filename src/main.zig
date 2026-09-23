//! Twig's CLI entry point: `twig <command> [options] <file>`, modeled on
//! sister project fig's `cli/main.zig` at Twig's smaller scale. Deliberately
//! thin — process/IO setup, turning argv into a `CliConfig`
//! (`cli/args.zig`), and a dispatch switch straight into `cli/actions.zig`.
//! Everything else (format inference/registry, argument parsing, the verb
//! implementations, the AST JSON encoder) lives in its own sibling module
//! under `cli/` — see each file's own doc comment.
//!
//! Unlike fig's `cli/main.zig`, there is no `std.log`/terminal-color/`NO_COLOR`
//! machinery here: Twig's CLI is plain `stdout`/`stderr` writers throughout
//! (Twig keeps its CLI modest and clean — see DESIGN.md's design principles),
//! and diagnostics
//! are printed directly by whichever `cli/` module detects the problem
//! (`args.zig` for bad flags/undetectable formats, `actions.zig` for
//! read/parse/render/serialize failures — see their module doc comments for
//! the shared "print then return a sentinel error" convention that keeps
//! this file's dispatch switch simple).

const std = @import("std");
const Io = std.Io;

const cli_args = @import("cli/args.zig");
const cli_format = @import("cli/format.zig");
const cli_actions = @import("cli/actions.zig");
const cli_languages = @import("cli/languages.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    // Streaming, not positional: a helper process inherits stderr and writes
    // to it directly, and a positional writer redirected to a file would
    // start again at offset 0 and write over it.
    var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    // Before the arguments: a name or extension nothing compiled answers to
    // is resolved by spawning the helper a `languages` file names.
    cli_languages.init(io, arena, init.environ_map, stderr_writer);

    const argv = try init.minimal.args.toSlice(arena);
    var arg_iter = cli_args.ArgIterator{ .items = argv };

    const config = cli_args.parseConfig(&arg_iter, stderr_writer) catch {
        // `args.zig` already printed a tailored diagnostic for every failure —
        // the specific message plus the failing command's one-line usage (via
        // `argFail`), or the supported-format list for a bad `-i`/`-o`/
        // extension. The full `runHelp` manual is reserved for an explicit
        // `twig help`, so here we only set the exit code.
        stderr_writer.flush() catch {};
        std.process.exit(2);
    };

    switch (config.action) {
        .help => try cli_actions.runHelp(stdout_writer, config.binary_name),
        .version => try cli_actions.runVersion(stdout_writer),
        .identify => try cli_actions.runIdentify(stdout_writer, config.options.identify),
        .convert => cli_actions.runConvert(arena, io, stdout_writer, stderr_writer, config.options.convert) catch |err| switch (err) {
            // `actions.zig` already printed and flushed a clear message;
            // just set the exit code.
            error.ActionFailed => std.process.exit(1),
        },
        .edit => cli_actions.runEdit(arena, io, stdout_writer, stderr_writer, config.options.edit) catch |err| switch (err) {
            error.ActionFailed => std.process.exit(1),
        },
        .query => cli_actions.runQuery(arena, io, stdout_writer, stderr_writer, config.options.query) catch |err| switch (err) {
            error.ActionFailed => std.process.exit(1),
        },
        .filter => cli_actions.runFilter(arena, io, stdout_writer, stderr_writer, config.options.filter) catch |err| switch (err) {
            error.ActionFailed => std.process.exit(1),
        },
        .lang => cli_actions.runLang(arena, io, stdout_writer, stderr_writer, config.options.lang) catch |err| switch (err) {
            error.ActionFailed => std.process.exit(1),
        },
    }
}

// Pull every CLI sibling module's tests into this binary's `exe_tests` (the
// fig/djot/xml convention — see e.g. `djot.zig`'s trailing `test {}` block).
// Without this, a `test {}`-only module reachable solely through `main.zig`
// (never through `root.zig`'s module graph) would never actually run.
test {
    _ = cli_args;
    _ = cli_format;
    _ = cli_actions;
    _ = cli_languages;
}
