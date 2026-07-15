//! Command-line parsing: turns the raw argv iterator into a `CliConfig`
//! (`parseConfig`). Mirrors fig's `cli/args.zig` at Twig's smaller scale — no
//! embed archetypes, no structural edit paths, just the `-i`/`-o` format-flag
//! convention fig established plus Twig's two verbs (`convert`, `identify`).
//!
//! Diagnostics are printed here, at the exact point a flag/format fails to
//! resolve (via the `stderr` writer every parse function takes), rather than
//! deferred to `main.zig`'s catch site the way fig routes through `std.log` —
//! Twig's CLI has no `std.log`/terminal-color machinery (see `main.zig`'s
//! module doc comment), so a plain writer threaded through is the modest
//! equivalent. Every failure prints a message scoped to the command that
//! failed, plus that command's one-line usage synopsis (`commandUsage`, via
//! the `argFail` helper) — never the whole `runHelp` manual, which is
//! reserved for an explicit `twig help`. `main.zig`'s catch site therefore
//! just sets the exit code.

const std = @import("std");
const Writer = std.Io.Writer;

const format = @import("format.zig");
const InputFormat = format.InputFormat;
const OutputMode = format.OutputMode;

pub const Action = enum { help, version, convert, identify, edit, query, filter };

/// One-line usage synopsis for each command, matching the per-command
/// synopsis lines in `actions.zig`'s `runHelp`. When a command's arguments
/// fail to parse, `argFail` prints just this line (prefixed with the binary
/// name) instead of the whole help manual, so the diagnostic points at the
/// shape of the command that actually failed. `help`/`version` never fail to
/// parse, so they fall back to the top-level synopsis.
pub fn commandUsage(action: Action) []const u8 {
    return switch (action) {
        .convert => "convert [-i <format>] [-o <format>] <file|->",
        .identify => "identify [-i <format>] <file>",
        .query => "query [-i <format>] <file> <selector>",
        .edit => "edit [-i <format>] <file|-> <operation>",
        .filter => "filter [-i <format>] <file|-> --drop <sel> [--keep <sel>] [--unwrap]",
        .help, .version => "<command> [options] <file>",
    };
}

/// The span-splice edit `twig edit` performs — one per invocation, selected by
/// the corresponding `--…` flag. See `actions.zig`'s `applyEdit` for the
/// mapping onto `twig.Editor`'s methods.
pub const EditOp = enum { replace, replace_content, insert_before, insert_after, insert_child, delete, unwrap };

pub const ConvertOptions = struct {
    /// The file to convert, or `"-"` for stdin.
    file: []const u8 = "",
    /// Resolved by `parseConfig` (via `format.resolveInputFormat`) — always a
    /// definite `InputFormat` by the time a `ConvertOptions` exists, never
    /// re-resolved by `actions.zig`.
    input: InputFormat = .djot,
    /// Defaults to `.html` — `convert file.dj` alone renders HTML, per the
    /// mission's "the workhorse" framing of this command.
    output: OutputMode = .html,
    /// Set only when `-o` named a specific TARGET format directly (e.g.
    /// `-o djot`) rather than the literal `canonical`/`html`/`ast` mode
    /// names — see `format.OutputTarget`'s doc comment. `null` for the
    /// ordinary `-o canonical` ("round-trip back to `input`") case.
    output_format: ?InputFormat = null,
    /// Markdown extension flags (`--directives`, `--math`, `--commonmark`,
    /// `--gfm`); ignored for non-Markdown inputs. See `applyExtFlag`.
    parse_config: format.ParseConfig = .{},
};

pub const IdentifyOptions = struct {
    file: []const u8 = "",
    input: InputFormat = .djot,
};

pub const EditOptions = struct {
    /// The file to edit, or `"-"` for stdin (stdin always prints to stdout —
    /// it can't be written back in place).
    file: []const u8 = "",
    input: InputFormat = .djot,
    /// Markdown extension flags — see `ConvertOptions.parse_config`. The editor
    /// reparses with these on every edit, so a directive-bearing document stays
    /// parseable across edits.
    parse_config: format.ParseConfig = .{},
    op: EditOp = .replace,
    /// The target node's index path as written on the command line
    /// (dot-separated, e.g. `"0.3.1"`); parsed into `[]const usize` by
    /// `actions.zig` (which has the allocator). Empty string = the root.
    path_str: []const u8 = "",
    /// Only meaningful for `.insert_child`: the child position to insert at.
    child_index: usize = 0,
    /// The replacement/inserted text (unused for `.delete`).
    text: []const u8 = "",
    /// Print the edited document to stdout instead of writing it back in place.
    dry_run: bool = false,
};

pub const QueryOptions = struct {
    file: []const u8 = "",
    input: InputFormat = .djot,
    /// The selector string (see `Select`), e.g. `heading[level=2]`.
    selector: []const u8 = "",
    /// Markdown extension flags — see `ConvertOptions.parse_config`. Needed so
    /// a selector like `directive[name=vis]` has directive nodes to match.
    parse_config: format.ParseConfig = .{},
};

pub const FilterOptions = struct {
    file: []const u8 = "",
    input: InputFormat = .djot,
    /// The candidate family selector (`--drop`, required): every match is a
    /// removal candidate. See `Filter.Options`.
    drop: []const u8 = "",
    /// Exceptions spared despite matching `drop` (`--keep`, optional).
    keep: ?[]const u8 = null,
    /// `--unwrap`: after dropping, unwrap each kept family member.
    unwrap_kept: bool = false,
    /// Print the result instead of writing back in place.
    dry_run: bool = false,
    /// Markdown extension flags — see `ConvertOptions.parse_config`. Needed so a
    /// selector like `directive[name=vis]` has directive nodes to match.
    parse_config: format.ParseConfig = .{},
};

pub const CliActionOptions = union(Action) {
    help: void,
    version: void,
    convert: ConvertOptions,
    identify: IdentifyOptions,
    edit: EditOptions,
    query: QueryOptions,
    filter: FilterOptions,
};

pub const CliConfig = struct {
    action: Action = .help,
    options: CliActionOptions = .{ .help = {} },
    binary_name: []const u8 = "twig",
};

/// Errors `parseConfig` can return. Every variant has already printed a
/// specific diagnostic to `stderr` by the time it's returned: the format
/// variants (`UnsupportedFormat`, the `ResolveInputFormatError`s) print the
/// supported-format list at their point of failure, and the
/// `Missing*`/`TooManyPositionals`/edit variants go through `argFail`, which
/// prints the specific message plus the offending command's one-line usage.
/// `main.zig` therefore only needs to set the exit code — see this file's and
/// `main.zig`'s module doc comments.
pub const ArgError = error{
    UnsupportedFormat,
    MissingFormatValue,
    MissingFile,
    TooManyPositionals,
    /// An `edit` operation flag (`--replace`, `--insert-child`, …) was missing
    /// one of its required following values (path/text/index).
    MissingEditArgument,
    /// `edit` was given a file but no operation flag at all.
    MissingEditOperation,
    /// `--insert-child`'s index value wasn't a non-negative integer (a message
    /// was already printed).
    InvalidEditIndex,
    /// `query` was given a file but no selector string.
    MissingSelector,
    /// `filter` was given a file but no `--drop` selector, or a `--drop`/
    /// `--keep` flag was missing its selector value.
    MissingFilterSelector,
} || format.ResolveInputFormatError;

/// A `[:0]const u8`-argv-slice-backed iterator satisfying the `.next()`
/// contract `parseConfig` expects (`anytype`, so the same function also
/// accepts the plain-slice `TestArgs` the unit tests below use — mirroring
/// fig's `cli/args.zig` split between real argv and its own `TestArgs`).
pub const ArgIterator = struct {
    items: []const [:0]const u8,
    i: usize = 0,

    pub fn next(self: *ArgIterator) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

fn isAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// Print a specific parse-error diagnostic plus the offending command's
/// one-line usage (`commandUsage`), then return `err` for the caller to
/// propagate. This is the "message + short usage, not the whole manual"
/// convention for every bare-argument failure a sub-parser can hit
/// (`MissingFile`, `TooManyPositionals`, the edit/selector variants, a flag
/// missing its value). Format-resolution failures don't come through here —
/// `format.zig` and the inline `-i`/`-o` handlers print their own richer
/// diagnostics (the supported-format list) at their point of failure.
fn argFail(
    stderr: *Writer,
    binary_name: []const u8,
    action: Action,
    message: []const u8,
    err: ArgError,
) ArgError {
    stderr.print("error: {s}\nusage: {s} {s}\n", .{ message, binary_name, commandUsage(action) }) catch {};
    stderr.flush() catch {};
    return err;
}

/// Consume a Markdown extension flag, mutating `cfg`. Returns true if `arg`
/// was one (so the caller's arg loop skips its own positional handling). These
/// only affect a Markdown parse; for any other input format they're inert.
///   --directives / --no-directives   the generic-directives extension
///   --math / --no-math                `$…$`/`$$…$$` math
///   --commonmark                      strict CommonMark (every extension off)
///   --gfm                             the GFM dialect
/// A preset (`--commonmark`/`--gfm`) followed by an individual flag composes
/// left-to-right, so `--gfm --directives` is GFM plus directives.
///
/// The two presets select a DIALECT, not just a set of extensions: each also
/// carries the HTML conventions its flavor renders with (`Options.dialect`),
/// so `--gfm` prints GFM's tables/task lists rather than twig-markdown's.
/// Composition preserves that — `--gfm --math` is still the GFM dialect.
fn applyExtFlag(arg: []const u8, cfg: *format.ParseConfig) bool {
    if (std.mem.eql(u8, arg, "--directives")) {
        cfg.markdown.directives = true;
    } else if (std.mem.eql(u8, arg, "--no-directives")) {
        cfg.markdown.directives = false;
    } else if (std.mem.eql(u8, arg, "--math")) {
        cfg.markdown.math = true;
    } else if (std.mem.eql(u8, arg, "--no-math")) {
        cfg.markdown.math = false;
    } else if (std.mem.eql(u8, arg, "--commonmark")) {
        cfg.markdown = .commonmark;
    } else if (std.mem.eql(u8, arg, "--gfm")) {
        cfg.markdown = .gfm;
    } else {
        return false;
    }
    return true;
}

pub fn parseConfig(args: anytype, stderr: *Writer) ArgError!CliConfig {
    var config = CliConfig{};
    config.binary_name = args.next() orelse "twig";

    const action_str = args.next() orelse {
        config.action = .help;
        return config;
    };

    if (isAny(action_str, &.{ "help", "--help", "-h" })) {
        config.action = .help;
        return config;
    }
    if (isAny(action_str, &.{ "version", "--version", "-v" })) {
        config.action = .version;
        config.options = .{ .version = {} };
        return config;
    }
    if (std.mem.eql(u8, action_str, "convert")) {
        return parseConvert(args, stderr, config.binary_name);
    }
    if (std.mem.eql(u8, action_str, "identify")) {
        return parseIdentify(args, stderr, config.binary_name);
    }
    if (std.mem.eql(u8, action_str, "edit")) {
        return parseEdit(args, stderr, config.binary_name);
    }
    if (std.mem.eql(u8, action_str, "query")) {
        return parseQuery(args, stderr, config.binary_name);
    }
    if (std.mem.eql(u8, action_str, "filter")) {
        return parseFilter(args, stderr, config.binary_name);
    }

    // Unrecognized verb: fall back to help, same as no args / an explicit
    // `twig help` (mirrors fig's `parseConfig` falling back rather than
    // hard-erroring on a typo'd action).
    config.action = .help;
    return config;
}

fn parseConvert(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var output: OutputMode = .html;
    var output_format: ?InputFormat = null;
    var file: ?[]const u8 = null;
    var parse_config = format.ParseConfig{};

    while (args.next()) |arg| {
        if (applyExtFlag(arg, &parse_config)) {
            // handled
        } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return argFail(stderr, binary_name, .convert, "convert: -i/--input needs a format value", ArgError.MissingFormatValue);
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            const name = args.next() orelse return argFail(stderr, binary_name, .convert, "convert: -o/--output needs a format value", ArgError.MissingFormatValue);
            const target = format.parseOutputTarget(name) orelse {
                try stderr.print("error: unsupported output format '{s}' (expected html, ast, canonical, or a target language like djot/markdown/xml)\n", .{name});
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
            output = target.mode;
            output_format = target.format;
        } else if (file == null) {
            file = arg;
        } else {
            return argFail(stderr, binary_name, .convert, "convert: unexpected extra argument (only one input file is accepted)", ArgError.TooManyPositionals);
        }
    }

    const path = file orelse return argFail(stderr, binary_name, .convert, "convert: missing input file", ArgError.MissingFile);
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .convert,
        .binary_name = binary_name,
        .options = .{ .convert = .{ .file = path, .input = resolved, .output = output, .output_format = output_format, .parse_config = parse_config } },
    };
}

fn parseIdentify(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return argFail(stderr, binary_name, .identify, "identify: -i/--input needs a format value", ArgError.MissingFormatValue);
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (file == null) {
            file = arg;
        } else {
            return argFail(stderr, binary_name, .identify, "identify: unexpected extra argument (only one input file is accepted)", ArgError.TooManyPositionals);
        }
    }

    const path = file orelse return argFail(stderr, binary_name, .identify, "identify: missing input file", ArgError.MissingFile);
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .identify,
        .binary_name = binary_name,
        .options = .{ .identify = .{ .file = path, .input = resolved } },
    };
}

fn parseQuery(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var file: ?[]const u8 = null;
    var selector: ?[]const u8 = null;
    var parse_config = format.ParseConfig{};

    while (args.next()) |arg| {
        if (applyExtFlag(arg, &parse_config)) {
            // handled
        } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return argFail(stderr, binary_name, .query, "query: -i/--input needs a format value", ArgError.MissingFormatValue);
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (file == null) {
            file = arg;
        } else if (selector == null) {
            selector = arg;
        } else {
            return argFail(stderr, binary_name, .query, "query: unexpected extra argument (expected just <file> and <selector>)", ArgError.TooManyPositionals);
        }
    }

    const path = file orelse return argFail(stderr, binary_name, .query, "query: missing input file", ArgError.MissingFile);
    const sel = selector orelse return argFail(stderr, binary_name, .query, "query: missing selector", ArgError.MissingSelector);
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .query,
        .binary_name = binary_name,
        .options = .{ .query = .{ .file = path, .input = resolved, .selector = sel, .parse_config = parse_config } },
    };
}

fn parseFilter(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var file: ?[]const u8 = null;
    var drop: ?[]const u8 = null;
    var keep: ?[]const u8 = null;
    var unwrap_kept = false;
    var dry_run = false;
    var parse_config = format.ParseConfig{};

    while (args.next()) |arg| {
        if (applyExtFlag(arg, &parse_config)) {
            // handled
        } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return argFail(stderr, binary_name, .filter, "filter: -i/--input needs a format value", ArgError.MissingFormatValue);
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (std.mem.eql(u8, arg, "--drop")) {
            drop = args.next() orelse return argFail(stderr, binary_name, .filter, "filter: --drop needs a selector value", ArgError.MissingFilterSelector);
        } else if (std.mem.eql(u8, arg, "--keep")) {
            keep = args.next() orelse return argFail(stderr, binary_name, .filter, "filter: --keep needs a selector value", ArgError.MissingFilterSelector);
        } else if (std.mem.eql(u8, arg, "--unwrap")) {
            unwrap_kept = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (file == null) {
            file = arg;
        } else {
            return argFail(stderr, binary_name, .filter, "filter: unexpected extra argument (only one input file is accepted)", ArgError.TooManyPositionals);
        }
    }

    const path = file orelse return argFail(stderr, binary_name, .filter, "filter: missing input file", ArgError.MissingFile);
    const drop_sel = drop orelse return argFail(stderr, binary_name, .filter, "filter: missing required --drop <selector>", ArgError.MissingFilterSelector);
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .filter,
        .binary_name = binary_name,
        .options = .{ .filter = .{
            .file = path,
            .input = resolved,
            .drop = drop_sel,
            .keep = keep,
            .unwrap_kept = unwrap_kept,
            .dry_run = dry_run,
            .parse_config = parse_config,
        } },
    };
}

fn parseEdit(args: anytype, stderr: *Writer, binary_name: []const u8) ArgError!CliConfig {
    var input_override: ?InputFormat = null;
    var file: ?[]const u8 = null;
    var op: ?EditOp = null;
    var path_str: []const u8 = "";
    var child_index: usize = 0;
    var text: []const u8 = "";
    var dry_run = false;
    var parse_config = format.ParseConfig{};

    while (args.next()) |arg| {
        if (applyExtFlag(arg, &parse_config)) {
            // handled
        } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            const name = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: -i/--input needs a format value", ArgError.MissingFormatValue);
            input_override = format.parseFormatName(name) orelse {
                try stderr.print("error: unsupported input format '{s}'\n", .{name});
                try format.printSupportedInputFormats(stderr);
                try stderr.flush();
                return ArgError.UnsupportedFormat;
            };
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            op = .replace;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --replace needs a <path> and <text>", ArgError.MissingEditArgument);
            text = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --replace needs a <text> after its <path>", ArgError.MissingEditArgument);
        } else if (std.mem.eql(u8, arg, "--replace-content")) {
            op = .replace_content;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --replace-content needs a <path> and <text>", ArgError.MissingEditArgument);
            text = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --replace-content needs a <text> after its <path>", ArgError.MissingEditArgument);
        } else if (std.mem.eql(u8, arg, "--insert-before")) {
            op = .insert_before;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-before needs a <path> and <text>", ArgError.MissingEditArgument);
            text = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-before needs a <text> after its <path>", ArgError.MissingEditArgument);
        } else if (std.mem.eql(u8, arg, "--insert-after")) {
            op = .insert_after;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-after needs a <path> and <text>", ArgError.MissingEditArgument);
            text = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-after needs a <text> after its <path>", ArgError.MissingEditArgument);
        } else if (std.mem.eql(u8, arg, "--insert-child")) {
            op = .insert_child;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-child needs a <path>, <index>, and <text>", ArgError.MissingEditArgument);
            const idx_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-child needs an <index> and <text> after its <path>", ArgError.MissingEditArgument);
            child_index = std.fmt.parseInt(usize, idx_str, 10) catch {
                stderr.print("error: edit: invalid child index '{s}' (expected a non-negative integer)\nusage: {s} {s}\n", .{ idx_str, binary_name, commandUsage(.edit) }) catch {};
                stderr.flush() catch {};
                return ArgError.InvalidEditIndex;
            };
            text = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --insert-child needs a <text> after its <index>", ArgError.MissingEditArgument);
        } else if (std.mem.eql(u8, arg, "--delete")) {
            op = .delete;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --delete needs a <path>", ArgError.MissingEditArgument);
        } else if (std.mem.eql(u8, arg, "--unwrap")) {
            op = .unwrap;
            path_str = args.next() orelse return argFail(stderr, binary_name, .edit, "edit: --unwrap needs a <path>", ArgError.MissingEditArgument);
        } else if (file == null) {
            file = arg;
        } else {
            return argFail(stderr, binary_name, .edit, "edit: unexpected extra argument", ArgError.TooManyPositionals);
        }
    }

    const path = file orelse return argFail(stderr, binary_name, .edit, "edit: missing input file", ArgError.MissingFile);
    const the_op = op orelse return argFail(stderr, binary_name, .edit, "edit: missing an operation (e.g. --replace, --delete, --insert-child)", ArgError.MissingEditOperation);
    const resolved = try format.resolveInputFormat(stderr, path, input_override);

    return .{
        .action = .edit,
        .binary_name = binary_name,
        .options = .{ .edit = .{
            .file = path,
            .input = resolved,
            .parse_config = parse_config,
            .op = the_op,
            .path_str = path_str,
            .child_index = child_index,
            .text = text,
            .dry_run = dry_run,
        } },
    };
}

const testing = std.testing;

/// A plain-slice-backed stand-in for the real argv iterator, for unit tests
/// that don't want to build a `[:0]const u8` slice — mirrors fig's own
/// `TestArgs` in `cli/args.zig`.
const TestArgs = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *TestArgs) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

/// A generously-sized scratch `Writer` for tests that don't care about the
/// diagnostic text, just that parsing succeeds or fails as expected. Backed
/// by a fixed buffer (not `Writer.Discarding`, whose drain implementation
/// recovers its owning struct via `@fieldParentPtr` and so isn't safe to hand
/// back out of a helper function by value).
fn scratchWriter(buf: []u8) Writer {
    return Writer.fixed(buf);
}

test "parseConfig: no args and explicit help/--help/-h all select help" {
    var buf: [256]u8 = undefined;
    inline for (&.{
        &[_][]const u8{"twig"},
        &[_][]const u8{ "twig", "help" },
        &[_][]const u8{ "twig", "--help" },
        &[_][]const u8{ "twig", "-h" },
    }) |argv| {
        var w = scratchWriter(&buf);
        var a = TestArgs{ .items = argv };
        const c = try parseConfig(&a, &w);
        try testing.expectEqual(Action.help, c.action);
    }
}

test "parseConfig: version/--version/-v select version" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "version" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.version, c.action);
}

test "parseConfig: convert infers input format from extension, defaults output to html" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "doc.dj" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.convert, c.action);
    try testing.expectEqualStrings("doc.dj", c.options.convert.file);
    try testing.expectEqual(InputFormat.djot, c.options.convert.input);
    try testing.expectEqual(OutputMode.html, c.options.convert.output);
}

test "parseConfig: convert -i/-o override inference, in either flag order" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-i", "md", "-o", "ast", "weird.ext" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(InputFormat.markdown, c.options.convert.input);
    try testing.expectEqual(OutputMode.ast, c.options.convert.output);

    var w2 = scratchWriter(&buf);
    var a2 = TestArgs{ .items = &.{ "twig", "convert", "--output", "canonical", "--input", "xml", "f" } };
    const c2 = try parseConfig(&a2, &w2);
    try testing.expectEqual(InputFormat.xml, c2.options.convert.input);
    try testing.expectEqual(OutputMode.canonical, c2.options.convert.output);
}

test "parseConfig: a failed parse writes a command-scoped message and that command's usage, not the whole manual" {
    var buf: [512]u8 = undefined;

    // convert with no file: message names the command, usage is convert's
    // one-liner, and no other command's synopsis leaks in (that would mean the
    // full `runHelp` manual was printed instead).
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert" } };
    try testing.expectError(error.MissingFile, parseConfig(&a, &w));
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "error: convert: missing input file") != null);
    try testing.expect(std.mem.indexOf(u8, out, commandUsage(.convert)) != null);
    try testing.expect(std.mem.indexOf(u8, out, commandUsage(.filter)) == null);

    // The usage line is prefixed with the actual binary name from argv[0].
    var w2 = scratchWriter(&buf);
    var a2 = TestArgs{ .items = &.{ "mytwig", "edit", "doc.dj" } };
    try testing.expectError(error.MissingEditOperation, parseConfig(&a2, &w2));
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "usage: mytwig edit") != null);
}

test "parseConfig: convert stdin ('-') without -i errors clearly" {
    var buf: [512]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-" } };
    try testing.expectError(error.StdinRequiresInputFormat, parseConfig(&a, &w));
}

test "parseConfig: convert stdin with -i succeeds" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-i", "djot", "-" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqualStrings("-", c.options.convert.file);
    try testing.expectEqual(InputFormat.djot, c.options.convert.input);
}

test "parseConfig: convert with an unrecognized extension and no -i errors" {
    var buf: [512]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "notes.txt" } };
    try testing.expectError(error.UnknownExtension, parseConfig(&a, &w));
}

test "parseConfig: convert rejects an unknown -i/-o value, a missing file, and extra positionals" {
    var buf: [512]u8 = undefined;

    var w1 = scratchWriter(&buf);
    var bad_i = TestArgs{ .items = &.{ "twig", "convert", "-i", "bogus", "f.dj" } };
    try testing.expectError(error.UnsupportedFormat, parseConfig(&bad_i, &w1));

    var w2 = scratchWriter(&buf);
    var bad_o = TestArgs{ .items = &.{ "twig", "convert", "-o", "bogus", "f.dj" } };
    try testing.expectError(error.UnsupportedFormat, parseConfig(&bad_o, &w2));

    var w3 = scratchWriter(&buf);
    var no_file = TestArgs{ .items = &.{ "twig", "convert" } };
    try testing.expectError(error.MissingFile, parseConfig(&no_file, &w3));

    var w4 = scratchWriter(&buf);
    var extra = TestArgs{ .items = &.{ "twig", "convert", "a.dj", "b.dj" } };
    try testing.expectError(error.TooManyPositionals, parseConfig(&extra, &w4));
}

test "parseConfig: identify resolves the input format and takes no -o" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "identify", "post.md" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.identify, c.action);
    try testing.expectEqual(InputFormat.markdown, c.options.identify.input);
}

test "parseConfig: query takes a file and a selector, plus -i override" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "query", "doc.md", "heading[level=2]" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.query, c.action);
    try testing.expectEqualStrings("doc.md", c.options.query.file);
    try testing.expectEqualStrings("heading[level=2]", c.options.query.selector);
    try testing.expectEqual(InputFormat.markdown, c.options.query.input);

    var w2 = scratchWriter(&buf);
    var no_sel = TestArgs{ .items = &.{ "twig", "query", "doc.md" } };
    try testing.expectError(error.MissingSelector, parseConfig(&no_sel, &w2));
}

test "parseConfig: convert --directives / --math set the markdown parse config" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "convert", "-i", "md", "--directives", "--math", "doc.md" } };
    const c = try parseConfig(&a, &w);
    try testing.expect(c.options.convert.parse_config.markdown.directives);
    try testing.expect(c.options.convert.parse_config.markdown.math);
    // A default parse leaves both off.
    var w2 = scratchWriter(&buf);
    var a2 = TestArgs{ .items = &.{ "twig", "convert", "doc.md" } };
    const c2 = try parseConfig(&a2, &w2);
    try testing.expect(!c2.options.convert.parse_config.markdown.directives);
}

test "parseConfig: --commonmark and --gfm presets, and left-to-right composition" {
    var buf: [256]u8 = undefined;

    var w = scratchWriter(&buf);
    var cm = TestArgs{ .items = &.{ "twig", "query", "--commonmark", "doc.md", "para" } };
    const c = try parseConfig(&cm, &w);
    try testing.expect(!c.options.query.parse_config.markdown.tables); // commonmark turns extensions off

    var w2 = scratchWriter(&buf);
    var gfmd = TestArgs{ .items = &.{ "twig", "query", "--gfm", "--directives", "doc.md", "para" } };
    const c2 = try parseConfig(&gfmd, &w2);
    try testing.expect(c2.options.query.parse_config.markdown.tables); // from --gfm
    try testing.expect(c2.options.query.parse_config.markdown.directives); // added after the preset
}

test "parseConfig: edit carries the parse config too" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "edit", "-i", "md", "--directives", "doc.md", "--delete", "1" } };
    const c = try parseConfig(&a, &w);
    try testing.expect(c.options.edit.parse_config.markdown.directives);
    try testing.expectEqual(EditOp.delete, c.options.edit.op);
}

test "parseConfig: filter parses --drop/--keep/--unwrap and needs a --drop" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "filter", "-i", "md", "--directives", "archive.md", "--drop", "directive[name=vis]", "--keep", "directive[class~=public]", "--unwrap" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.filter, c.action);
    const f = c.options.filter;
    try testing.expectEqualStrings("archive.md", f.file);
    try testing.expectEqual(InputFormat.markdown, f.input);
    try testing.expectEqualStrings("directive[name=vis]", f.drop);
    try testing.expectEqualStrings("directive[class~=public]", f.keep.?);
    try testing.expect(f.unwrap_kept);
    try testing.expect(f.parse_config.markdown.directives);

    // No --drop is an error.
    var w2 = scratchWriter(&buf);
    var a2 = TestArgs{ .items = &.{ "twig", "filter", "archive.md" } };
    try testing.expectError(error.MissingFilterSelector, parseConfig(&a2, &w2));
}

test "parseConfig: filter without --keep leaves keep null (drop the whole family)" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "filter", "doc.md", "--drop", "directive[name=vis]" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(@as(?[]const u8, null), c.options.filter.keep);
    try testing.expect(!c.options.filter.unwrap_kept);
}

test "parseConfig: an unrecognized verb falls back to help rather than erroring" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "frobnicate", "f.dj" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.help, c.action);
}

test "parseConfig: edit --replace parses op, path, text, and the file positional" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "edit", "doc.md", "--replace", "0.1", "new text" } };
    const c = try parseConfig(&a, &w);
    try testing.expectEqual(Action.edit, c.action);
    const e = c.options.edit;
    try testing.expectEqual(EditOp.replace, e.op);
    try testing.expectEqualStrings("doc.md", e.file);
    try testing.expectEqualStrings("0.1", e.path_str);
    try testing.expectEqualStrings("new text", e.text);
    try testing.expectEqual(InputFormat.markdown, e.input);
    try testing.expect(!e.dry_run);
}

test "parseConfig: edit --insert-child parses the index, --dry-run, and -i override" {
    var buf: [256]u8 = undefined;
    var w = scratchWriter(&buf);
    var a = TestArgs{ .items = &.{ "twig", "edit", "-i", "xml", "--dry-run", "--insert-child", "0", "2", "<x/>", "f" } };
    const c = try parseConfig(&a, &w);
    const e = c.options.edit;
    try testing.expectEqual(EditOp.insert_child, e.op);
    try testing.expectEqualStrings("0", e.path_str);
    try testing.expectEqual(@as(usize, 2), e.child_index);
    try testing.expectEqualStrings("<x/>", e.text);
    try testing.expectEqual(InputFormat.xml, e.input);
    try testing.expect(e.dry_run);
}

test "parseConfig: edit --delete needs only a path; missing op or arg errors" {
    var buf: [256]u8 = undefined;

    var w1 = scratchWriter(&buf);
    var del = TestArgs{ .items = &.{ "twig", "edit", "doc.dj", "--delete", "2" } };
    const c = try parseConfig(&del, &w1);
    try testing.expectEqual(EditOp.delete, c.options.edit.op);
    try testing.expectEqualStrings("2", c.options.edit.path_str);

    var w2 = scratchWriter(&buf);
    var no_op = TestArgs{ .items = &.{ "twig", "edit", "doc.dj" } };
    try testing.expectError(error.MissingEditOperation, parseConfig(&no_op, &w2));

    var w3 = scratchWriter(&buf);
    var no_arg = TestArgs{ .items = &.{ "twig", "edit", "doc.dj", "--replace", "0.1" } };
    try testing.expectError(error.MissingEditArgument, parseConfig(&no_arg, &w3));

    var w4 = scratchWriter(&buf);
    var bad_idx = TestArgs{ .items = &.{ "twig", "edit", "f.xml", "--insert-child", "0", "notnum", "<x/>" } };
    try testing.expectError(error.InvalidEditIndex, parseConfig(&bad_idx, &w4));
}
