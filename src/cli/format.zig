//! The CLI's view of the format registry: the `-i`/`-o` vocabulary and the
//! diagnostics printed when one doesn't resolve.
//!
//! The registry itself — the parser/renderer/serializer/syntax adapters, and
//! `Format` itself — moved to `twig.format` (`src/format.zig`), because the C
//! ABI needs the same table and cannot import the CLI; it used to keep a second
//! hand-maintained copy of the parse adapters instead. What's left here is the
//! part that is genuinely about being a command-line tool: which words `-o`
//! accepts, and what to print at a human when they typo one.
//!
//! The core names are re-exported below so the rest of the CLI keeps saying
//! `format.entryFor` / `format.InputFormat` and needn't care where they live.

const std = @import("std");
const Writer = std.Io.Writer;

const twig = @import("twig");

// ── re-exports from the shared registry ────────────────────────────────────

/// Every language Twig can PARSE — the `-i`/`--input` vocabulary. Named
/// `InputFormat` here (against `twig.Format`) because in CLI terms it is
/// specifically what `-i` accepts, as opposed to `-o`'s `OutputMode`.
///
/// That naming turned out to be the first half of a distinction the library
/// itself now draws: `twig.format.Target` is the OUTPUT axis, re-exported below,
/// and `-o` accepts one of those rather than an `InputFormat`.
pub const InputFormat = twig.format.Format;
/// Every format Twig can WRITE — the other half of what `-o`/`--output` accepts,
/// alongside the three `OutputMode` words. A superset of `InputFormat` in
/// principle; the same list in practice, until the first export-only target.
pub const Target = twig.format.Target;
pub const FormatEntry = twig.format.Entry;
pub const TargetEntry = twig.format.TargetEntry;
pub const ParsedDoc = twig.format.ParsedDoc;
pub const ParseConfig = twig.format.ParseConfig;
pub const registry = twig.format.registry;
pub const targets = twig.format.targets;
pub const entryFor = twig.format.entryFor;
pub const targetEntryFor = twig.format.targetEntryFor;
pub const targetFor = twig.format.targetFor;
pub const parseFormatName = twig.format.parseFormatName;
pub const parseTargetName = twig.format.parseTargetName;
pub const detectFromExtension = twig.format.detectFromExtension;

// ── the CLI's own vocabulary ───────────────────────────────────────────────

/// What `-o`/`--output` selects: not a source language like `InputFormat`, but
/// one of the three ways `convert` can render a parsed document. `html` is the
/// default; `ast` and `canonical` are documented on `actions.zig`'s `runConvert`.
pub const OutputMode = enum { html, ast, canonical };

pub fn parseOutputMode(name: []const u8) ?OutputMode {
    return std.meta.stringToEnum(OutputMode, name);
}

/// What `-o`/`--output` resolved to: `mode` is always one of the three
/// `OutputMode`s, plus (only ever set alongside `.canonical`) an explicit
/// `Target` when `-o` named one directly (e.g. `-o djot`) rather than the
/// literal word `canonical` — which means "serialize back to whatever `-i` was",
/// same format in, same format out. `-o <target-name>` is `.canonical` plus "but
/// serialize as `<target-name>` even if that's not the input format", the
/// cross-format `convert` path (`actions.zig`'s `convertSource`).
///
/// Named for the SELECTION rather than for the target because `target` is now a
/// library type of its own (`twig.format.Target`) and this struct is the pair of
/// answers `-o` produces, only one of which is a target.
pub const OutputSelection = struct {
    mode: OutputMode,
    target: ?Target = null,
};

/// Parse an `-o`/`--output` value against both vocabularies it accepts:
/// `OutputMode`'s own names (`html`, `ast`, `canonical`) first, then every
/// target's name/inherited aliases (`djot`/`dj`, `markdown`/`md`, `xml`) as a
/// request to convert TO that target. Returns `null` when `name` matches
/// neither, so the caller can print a diagnostic listing both.
pub fn parseOutputSelection(name: []const u8) ?OutputSelection {
    if (parseOutputMode(name)) |mode| return .{ .mode = mode };
    if (parseTargetName(name)) |t| return .{ .mode = .canonical, .target = t };
    return null;
}

/// Write a "supported input formats" list to `w` — the same list an unknown
/// `-i`/`--input` name or an undetectable extension both point the user at
/// (mirrors fig's `main.zig` inline loop over `types.Format`'s fields).
pub fn printSupportedInputFormats(w: *Writer) Writer.Error!void {
    try w.writeAll("supported input formats:\n");
    for (&registry) |*e| {
        try w.print("  - {s}", .{@tagName(e.id)});
        for (e.aliases) |alias| try w.print(" ({s})", .{alias});
        try w.writeByte('\n');
    }
}

/// Write the `-o`/`--output` vocabulary to `w`: the three modes, then every
/// target. A target that is also an input format shows the aliases it inherits;
/// an export-only one has none to show, which is exactly the shape
/// `parseTargetName` documents.
///
/// A target whose name is already an `OutputMode` word is skipped rather than
/// listed twice. `html` is the case: `parseOutputSelection` tries the modes
/// first, so `-o html` always means the RENDER mode (which resolves djot's and
/// Markdown's side tables) and can never reach the html target's bare-AST
/// serializer. Listing it under both would advertise a spelling that does not
/// exist.
pub fn printSupportedOutputTargets(w: *Writer) Writer.Error!void {
    try w.writeAll("supported output values:\n");
    for (std.meta.fieldNames(OutputMode)) |mode| try w.print("  - {s}\n", .{mode});
    for (&targets) |*t| {
        if (parseOutputMode(@tagName(t.id)) != null) continue;
        try w.print("  - {s}", .{@tagName(t.id)});
        if (t.reads_back_as) |f| {
            for (entryFor(f).aliases) |alias| try w.print(" ({s})", .{alias});
        }
        try w.writeByte('\n');
    }
}

/// Errors `resolveInputFormat` can produce, beyond the write failures its own
/// diagnostics can hit. Folded into `args.zig`'s `ArgError` via `||`.
pub const ResolveInputFormatError = Writer.Error || error{
    /// `-` (stdin) was given as the file with no `-i`/`--input` override — there
    /// is no extension to infer from, so the caller MUST say what it is.
    StdinRequiresInputFormat,
    /// A real file path was given, but its extension is missing or matches no
    /// registry entry, and no `-i`/`--input` override was given either.
    UnknownExtension,
};

/// Resolve the definitive `InputFormat` for `convert`/`identify`: an explicit
/// `override` (from `-i`/`--input`) always wins; otherwise infer from
/// `file_path`'s extension; otherwise fail with a diagnostic written to `stderr`
/// (mirrors fig's `ArgError.UnsupportedFileFormat` handling in `main.zig`, but
/// resolved eagerly here in one place instead of deferred to every action).
/// `file_path == "-"` (stdin) skips extension inference entirely, since there is
/// no path to infer from.
pub fn resolveInputFormat(stderr: *Writer, file_path: []const u8, override: ?InputFormat) ResolveInputFormatError!InputFormat {
    if (override) |f| return f;

    if (std.mem.eql(u8, file_path, "-")) {
        try stderr.writeAll("error: reading from stdin ('-') requires an explicit --input/-i format (there is no file extension to infer one from).\n");
        try stderr.flush();
        return error.StdinRequiresInputFormat;
    }

    if (detectFromExtension(file_path)) |f| return f;

    try stderr.print("error: could not infer an input format for '{s}' from its extension.\n", .{file_path});
    try stderr.writeAll("Try using --input/-i <format> to specify one explicitly.\n");
    try printSupportedInputFormats(stderr);
    try stderr.flush();
    return error.UnknownExtension;
}
