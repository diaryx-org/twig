//! The format registry: the single place a new Twig language plugs in.
//!
//! Each `Entry` bundles everything that varies by language behind one uniform
//! shape — a parser adapter (`parse`), the bare-AST reparse adapter the
//! `Splicer` needs (`parseToAst`), an HTML renderer (`renderHtml`), optional
//! serializers, and an optional `Syntax` table — so no consumer needs a
//! per-language `switch` of its own. Adding a language is "write a few small
//! adapters, add one `registry` entry".
//!
//! ── Why this isn't in `cli/` ───────────────────────────────────────────────
//! It used to be. The C ABI can't import the CLI, so it grew its own parallel
//! copy: the same four `parseToAst` adapters (its own comment admitted
//! "Mirrors `cli/format.zig`'s"), its own `ParseConfig`, and a hand-written
//! `switch (format)` per operation where this table has a field. Two copies of
//! one table is a drift bug waiting to happen — and the second copy sat behind
//! an `extern` boundary, so only a C caller could reach or test it. Living
//! here, both the CLI and the C ABI read the same row.
//!
//! ── Optional fields are the raggedness ─────────────────────────────────────
//! Twig's languages are not interchangeable. Every one parses and renders, but
//! AsciiDoc has no serializer at all, nothing can be written INTO XML from
//! another format, and only djot and Markdown have a `syntax` — a `null` says so
//! once, in whichever of the two tables owns the question, and every caller
//! turns it into the same "unsupported" error instead of rediscovering the fact
//! in an `else =>` arm. See `syntax.zig` for that argument in full.
//!
//! ── Two axes: what Twig READS and what Twig WRITES ─────────────────────────
//! There are two tables here, not one. `registry` is keyed by `Format` — the
//! languages Twig can PARSE — and `targets` is keyed by `Target` — the formats
//! Twig can WRITE. Every `Format` is also a `Target`, so the two lists coincide
//! today, and they are still separate types.
//!
//! The reason is that the enums answer different questions and only one of them
//! can grow freely. `Format` is `ParsedDoc`'s tag: a variant there must have a
//! parser, a reparse adapter for the `Splicer`, and a document type to hold. A
//! `Target` needs none of that — it needs somewhere for bytes to go. An
//! EXPORT-ONLY target (one Twig can write and no parser can read back; PDF is
//! the motivating case) is expressible as a `Target` and is NOT expressible as a
//! `Format`, and before the split there was nowhere to put it that did not also
//! claim Twig could parse it.
//!
//! The split was already latent rather than hypothetical: `diagnostics.zig`'s
//! `fidelity(target, kind)` has always indexed its capability table on an output
//! axis while spelling the parameter `Format`, and `cli/format.zig` had already
//! named its `-i` re-export `InputFormat` to distinguish it from what `-o`
//! accepts. `serializeFromAst` moved with it, from `Entry` to `TargetEntry`: it
//! is keyed by where the bytes are going, not by what parsed them.
//! `serializeCanonical` stayed on `Entry`, because it takes a `ParsedDoc`
//! variant and so is inherently a fact about the input row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("ast/ast.zig");
const Document = @import("document.zig");
const Djot = @import("languages/djot/djot.zig");
const Markdown = @import("languages/markdown/markdown.zig");
const Xml = @import("languages/xml/xml.zig");
const Html = @import("languages/html/html.zig");
const Asciidoc = @import("languages/asciidoc/asciidoc.zig");
const Splicer = @import("ast/splicer.zig").Splicer;
const syntax_mod = @import("syntax.zig");
const Syntax = syntax_mod.Syntax;

const djot_serializer = Djot.serializer;
const markdown_serializer = Markdown.serializer;

/// Every language Twig can PARSE — the `-i`/`--input` vocabulary, the enum
/// `ParsedDoc` is tagged by, and what the C ABI's `TwigFormat` wire codes decode
/// to on the parse path. Deliberately has NO explicit values: the integers are
/// the C ABI's contract, so they live there (`c_abi.zig`'s `intToFormat`), not
/// here.
///
/// This is the INPUT axis only. What Twig can write is `Target` — see the
/// two-axes note at the top of this file.
pub const Format = enum {
    djot,
    markdown,
    xml,
    html,
    asciidoc,
};

/// Every format Twig can WRITE — what `-o`/`--output` names beyond its three
/// `OutputMode` words, the axis `diagnostics.fidelity` is indexed by, and the
/// key of the `targets` table.
///
/// Spelled out rather than derived from `Format`, even though the two lists
/// coincide today. A generated enum would make the interesting case — a variant
/// that is a target and NOT a format — invisible at the point a reader looks for
/// it, and would put the subset relation in a comptime expression instead of in
/// a test that says what it is checking. The relation is enforced by `test
/// "every Format is also a Target"`: the same hand-maintained-table-plus-test
/// trust boundary `registry` itself relies on.
///
/// An export-only target appends HERE and nowhere else. It gets a `targets` row
/// with `reads_back_as = null` and no `Format` variant, no `registry` row, no
/// `ParsedDoc` variant, and no `Syntax` — none of which it could honestly fill
/// in. That is the whole reason this enum exists apart from `Format`.
pub const Target = enum {
    djot,
    markdown,
    xml,
    html,
    asciidoc,

    /// The `Format` whose parser reads this target's own output back, or `null`
    /// for an export-only target. `null` is what makes a round-trip
    /// unstateable, which is why `diagnostics.zig`'s probe skips such a target
    /// rather than guessing at an answer for it.
    pub fn asFormat(self: Target) ?Format {
        return targetEntryFor(self).reads_back_as;
    }
};

/// The output target that writes `fmt`'s own syntax. TOTAL — every input format
/// is also a target, including the ones with no serializer yet, because
/// `-o asciidoc` has to reach "not supported yet" rather than "unknown target".
/// Totality is a compile error rather than a test: `@field` fails to resolve if
/// a `Format` name is missing from `Target`.
pub fn targetFor(fmt: Format) Target {
    return switch (fmt) {
        inline else => |f| @field(Target, @tagName(f)),
    };
}

/// Per-invocation parse configuration, threaded from a consumer's feature flags
/// into the `parse`/`parseToAst` adapters. Passed as an opaque `*const anyopaque`
/// (so `ast/splicer.zig` can carry it across reparses without depending on this
/// type — see `Splicer.ParseFn`); every adapter that reads it `@ptrCast`s it
/// back. Only Markdown consults it today; other formats' adapters ignore it.
pub const ParseConfig = struct {
    markdown: Markdown.ParseOptions = .{},

    /// Recover a `*const ParseConfig` from the opaque pointer the registry
    /// adapters / the splicer pass around.
    pub fn from(ctx: *const anyopaque) *const ParseConfig {
        return @ptrCast(@alignCast(ctx));
    }
};

/// A parsed document, tagged by which `Format` produced it. Exists because
/// `Djot.parse`/`Markdown.parse` return a `Document` wrapper (the shared `AST`
/// plus side tables — see `Djot.Document`'s doc comment) while `Xml.parse`
/// returns the shared `AST` directly; this union gives a consumer one type to
/// hold, deinit, and pull an `*const AST` out of, regardless of language.
pub const ParsedDoc = union(Format) {
    djot: Djot.Document,
    markdown: Markdown.Document,
    xml: Document,
    html: Document,
    asciidoc: Document,

    /// The shared `AST` underneath, regardless of variant — MEANING only.
    pub fn ast(self: *const ParsedDoc) *const AST {
        return switch (self.*) {
            .djot => |*d| &d.ast,
            .markdown => |*d| &d.ast,
            .xml => |*d| &d.ast,
            .html => |*d| &d.ast,
            .asciidoc => |*d| &d.ast,
        };
    }

    /// A BORROWED `Document` view — the tree plus the positions addressing
    /// `source`. What the edit layer and `languages/xml/serializer.zig` take;
    /// must NOT be `deinit`ed (the variant owns the storage).
    pub fn document(self: *const ParsedDoc) Document {
        return switch (self.*) {
            .djot => |*d| d.document(),
            .markdown => |*d| d.document(),
            .xml, .html, .asciidoc => |*d| d.*,
        };
    }

    pub fn deinit(self: *ParsedDoc) void {
        switch (self.*) {
            .djot => |*d| d.deinit(),
            .markdown => |*d| d.deinit(),
            .xml => |*d| d.deinit(),
            .html => |*d| d.deinit(),
            .asciidoc => |*d| d.deinit(),
        }
    }
};

fn parseDjot(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    _ = ctx;
    return .{ .djot = try Djot.parse(allocator, source) };
}

fn parseMarkdown(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    return .{ .markdown = try Markdown.parse(allocator, source, ParseConfig.from(ctx).markdown) };
}

fn parseXml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    _ = ctx;
    return .{ .xml = try Xml.parse(allocator, source) };
}

fn parseHtml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    _ = ctx;
    return .{ .html = try Html.parse(allocator, source) };
}

fn parseAsciidoc(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!ParsedDoc {
    _ = ctx;
    return .{ .asciidoc = try Asciidoc.parser.parse(allocator, source) };
}

// ── splicer reparse adapters ───────────────────────────────────────────────
// The span-splice engine (`Splicer`) reparses after every edit and only needs
// the bare shared `AST` — spans/structure, never a `Document`'s side tables.
// These unwrap djot/Markdown's `Document`: its side-table map KEYS are slices
// into `ast.owned_strings` and the maps own no AST memory (see each
// `Document`'s doc comment), so freeing just the map *structures* and handing
// back `.ast` is leak-free and leaves a fully valid tree. XML and HTML already
// return a bare `AST`.

fn parseToAstDjot(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
    _ = ctx;
    var doc = try Djot.parse(allocator, source);
    doc.references.deinit(allocator);
    doc.auto_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.document();
}

fn parseToAstMarkdown(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
    var doc = try Markdown.parse(allocator, source, ParseConfig.from(ctx).markdown);
    doc.link_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.document();
}

fn parseToAstXml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
    _ = ctx;
    return Xml.parse(allocator, source);
}

fn parseToAstHtml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
    _ = ctx;
    return Html.parse(allocator, source);
}

fn parseToAstAsciidoc(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!Document {
    _ = ctx;
    return Asciidoc.parser.parse(allocator, source);
}

/// Djot needs its own HTML rendering path (`Djot.html.render`) rather than the
/// generic printer: it resolves reference/footnote labels against `Document`'s
/// side tables at render time (see `djot/html.zig`'s module doc comment) — the
/// generic `Html.serialize` has no djot `Document` to pull those tables from.
/// Using the generic printer here would silently drop footnotes and
/// reference-style links.
fn renderHtmlDjot(allocator: Allocator, doc: *const ParsedDoc, writer: *Writer) anyerror!void {
    try Djot.html.render(allocator, &doc.djot, writer, .{});
}

/// Every other language (XML and HTML) has no side tables to resolve, so the
/// shared, language-neutral printer (`languages/html/serializer.zig`) is the
/// whole story — `ctx = null`.
fn renderHtmlGeneric(allocator: Allocator, doc: *const ParsedDoc, writer: *Writer) anyerror!void {
    try Html.serialize(allocator, doc.ast(), writer, null);
}

/// Markdown needs its own HTML rendering path (`Markdown.html.render`) rather
/// than the generic printer for the same reason djot does (`renderHtmlDjot`'s
/// doc comment): footnotes (`self.options.footnotes`) resolve/number/backlink
/// entirely at RENDER time, against `Document.footnotes` — see
/// `markdown/html.zig`'s module doc comment. Using the generic printer here
/// would silently drop footnotes (every `link`/`image`, by contrast, is already
/// fully resolved at PARSE time, so those are unaffected either way).
fn renderHtmlMarkdown(allocator: Allocator, doc: *const ParsedDoc, writer: *Writer) anyerror!void {
    try Markdown.html.render(allocator, &doc.markdown, writer, .{});
}

fn serializeCanonicalXml(allocator: Allocator, doc: *const ParsedDoc) anyerror![]u8 {
    const d = doc.document();
    return Xml.serializeAlloc(allocator, &d);
}

fn serializeCanonicalDjot(allocator: Allocator, doc: *const ParsedDoc) anyerror![]u8 {
    return djot_serializer.serializeAlloc(allocator, &doc.djot);
}

fn serializeCanonicalMarkdown(allocator: Allocator, doc: *const ParsedDoc) anyerror![]u8 {
    return markdown_serializer.serializeAlloc(allocator, &doc.markdown);
}

/// HTML's printer renders the full shared vocabulary from a bare AST, so it
/// serves as both the round-trip and the cross-format path (`ctx = null`: this
/// is the side-table-free printer; `renderHtmlDjot`/`renderHtmlMarkdown` are the
/// richer, side-table-resolving renders).
///
/// These two are NEW to the registry and not new to Twig: the C ABI's
/// `serializeDocument` has always served HTML on both paths, while this table —
/// its other copy — claimed HTML had no serializer at all and made
/// `twig convert -i html -o canonical` fail. Neither copy was consulted by the
/// other, so nothing caught the disagreement. One table, one answer.
fn serializeCanonicalHtml(allocator: Allocator, doc: *const ParsedDoc) anyerror![]u8 {
    return Html.serializeAlloc(allocator, doc.ast(), null);
}

fn serializeFromAstHtml(allocator: Allocator, ast: *const AST) anyerror![]u8 {
    return Html.serializeAlloc(allocator, ast, null);
}

fn serializeFromAstDjot(allocator: Allocator, ast: *const AST) anyerror![]u8 {
    return djot_serializer.serializeAstAlloc(allocator, ast);
}

fn serializeFromAstMarkdown(allocator: Allocator, ast: *const AST) anyerror![]u8 {
    return markdown_serializer.serializeAstAlloc(allocator, ast);
}

/// One entry per `Format`. This IS the extensibility point Twig is built
/// around: consumers are written entirely against this table, never against a
/// per-language switch of their own.
pub const Entry = struct {
    id: Format,
    /// Lowercase, dot-less extensions that infer this format (checked
    /// case-insensitively against a path's last `.`-separated segment).
    extensions: []const []const u8,
    /// Extra input names accepted besides `@tagName(id)` itself (which
    /// `parseFormatName` always accepts via `std.meta.stringToEnum`).
    aliases: []const []const u8 = &.{},
    parse: *const fn (*const anyopaque, Allocator, []const u8) anyerror!ParsedDoc,
    /// Source -> the bare shared `AST`, the reparse callback the span-splice
    /// engine (`Splicer`) needs. Discards any `Document` side tables (see the
    /// splicer-adapter note above) — editing is language-neutral and only
    /// touches spans/structure. Every format has one. Its shape matches
    /// `Splicer.ParseFn` (leading opaque `ParseConfig` context) so it can be
    /// handed straight to `Splicer.init`.
    parseToAst: Splicer.ParseFn,
    renderHtml: *const fn (Allocator, *const ParsedDoc, *Writer) anyerror!void,
    /// Round-trip serializer back to this format's own source syntax —
    /// `convert -o canonical`'s implementation. `null` means the language has no
    /// serializer yet; callers turn that into a clear "not supported yet" error
    /// rather than a crash.
    ///
    /// The one serializer that stays on the INPUT row, because it takes a
    /// `ParsedDoc` variant — it can only ever serialize a document this very
    /// entry parsed, side tables and all. The bare-AST serializer that any
    /// document can be fed to lives on `TargetEntry.serializeFromAst`.
    serializeCanonical: ?*const fn (Allocator, *const ParsedDoc) anyerror![]u8 = null,
    /// This format's surface spelling — the table the authoring gestures in
    /// `ast/editor.zig` consult. Defaults to `Syntax.none`, the table that
    /// spells nothing: a language that can be parsed and rendered but not
    /// AUTHORED into (XML, HTML) simply omits this field, and every gesture over
    /// it reports unsupported by finding the same `null` in the same table any
    /// other unspellable kind would. See `syntax.zig`.
    syntax: *const Syntax = &syntax_mod.none,
};

pub const registry = [_]Entry{
    .{
        .id = .djot,
        .extensions = &.{ "dj", "djot" },
        .aliases = &.{"dj"},
        .parse = parseDjot,
        .parseToAst = parseToAstDjot,
        .renderHtml = renderHtmlDjot,
        .serializeCanonical = serializeCanonicalDjot,
        .syntax = &@import("languages/djot/syntax.zig").table,
    },
    .{
        .id = .markdown,
        .extensions = &.{ "md", "markdown" },
        .aliases = &.{"md"},
        .parse = parseMarkdown,
        .parseToAst = parseToAstMarkdown,
        .renderHtml = renderHtmlMarkdown,
        .serializeCanonical = serializeCanonicalMarkdown,
        .syntax = &@import("languages/markdown/syntax.zig").table,
    },
    .{
        .id = .xml,
        .extensions = &.{"xml"},
        .parse = parseXml,
        .parseToAst = parseToAstXml,
        .renderHtml = renderHtmlGeneric,
        .serializeCanonical = serializeCanonicalXml,
        // Why converting INTO xml from another format isn't meaningful yet is
        // now a fact about the xml TARGET row (`targets`, below), not this one.
        //
        // No `syntax`: XML has no lightweight inline markup to toggle and no
        // line-prefix containers, so it is parse-and-render only.
    },
    .{
        .id = .html,
        .extensions = &.{ "html", "htm" },
        .parse = parseHtml,
        .parseToAst = parseToAstHtml,
        .renderHtml = renderHtmlGeneric,
        .serializeCanonical = serializeCanonicalHtml,
        // No `syntax`: HTML is parse-and-render only. Authoring gestures spell
        // djot/Markdown's lightweight markup, which HTML doesn't have.
    },
    .{
        .id = .asciidoc,
        .extensions = &.{ "adoc", "asciidoc" },
        .aliases = &.{"adoc"},
        .parse = parseAsciidoc,
        .parseToAst = parseToAstAsciidoc,
        .renderHtml = renderHtmlGeneric,
        // ── The raggedest row in the table, and deliberately so ─────────────
        // AsciiDoc's parser covers a real slice of the language and NOT the
        // whole of it (`languages/asciidoc/parser.zig`'s doc comment draws the
        // exact line: four spans in both forms, the delimited blocks, sections,
        // unordered lists, the header — but no links, images, xrefs, attribute
        // references, ordered lists or block metadata).
        //
        // A row this partial earns its place because of HOW the parser fails:
        // every construct it doesn't implement survives as LITERAL SOURCE TEXT,
        // so an unhandled `image:logo.png[Logo]` renders as those very
        // characters — visibly unhandled, and diagnosable by whoever sees it —
        // rather than as a mangled tree. That is the property that makes
        // `renderHtml` honest here, and it is a property the parser had to earn:
        // the unconstrained spans (`**bold**`) used to corrupt instead, which is
        // why they were fixed before this entry was written rather than after.
        //
        // No `serializeCanonical`: there is no AsciiDoc serializer at all yet,
        // so `convert -o canonical` reports unsupported rather than inventing
        // output — and so does `-o asciidoc`, via the equally empty target row
        // below. No `syntax` either: every authoring gesture over an AsciiDoc
        // document is refused by the same `Syntax.none` XML and HTML carry.
    },
};

/// One entry per `Target` — the WRITE half of the registry. Split from `Entry`
/// (the READ half) for the reason the two-axes note at the top of this file
/// gives: what a target needs is somewhere for bytes to go, which is strictly
/// less than what a language needs to be parsed.
pub const TargetEntry = struct {
    id: Target,
    /// The `Format` whose parser reads this target's own output back — set for
    /// every target that is also an input language, `null` for an export-only
    /// one. This single field is what distinguishes the two kinds of target, and
    /// it is what `diagnostics.zig`'s round-trip probe reparses with.
    reads_back_as: ?Format,
    /// Serialize a BARE shared `AST` (regardless of which format parsed it) as
    /// this target's own syntax — `convert -o <target>`'s cross-format
    /// implementation (e.g. `-i markdown -o djot`), and the C ABI's builder
    /// output path. Unlike `Entry.serializeCanonical` it never needs a matching
    /// `ParsedDoc` variant: it is handed whatever `ParsedDoc.ast()` returns and
    /// builds any side tables it needs from that bare tree.
    ///
    /// `null` means Twig cannot write this target yet, and every caller turns it
    /// into the same `error.UnsupportedFormat`. For an export-only target this
    /// is the ONLY function in either table that would be non-null.
    serializeFromAst: ?*const fn (Allocator, *const AST) anyerror![]u8 = null,
};

pub const targets = [_]TargetEntry{
    .{ .id = .djot, .reads_back_as = .djot, .serializeFromAst = serializeFromAstDjot },
    .{ .id = .markdown, .reads_back_as = .markdown, .serializeFromAst = serializeFromAstMarkdown },
    .{
        .id = .xml,
        .reads_back_as = .xml,
        // No `serializeFromAst`: XML's serializer only understands the
        // generic-markup kinds (`element`/`comment`/`doctype`/...) its own
        // parser produces (see `xml/serializer.zig`'s `else => unreachable`); it
        // has no mapping for djot/Markdown's semantic kinds
        // (`heading`/`emph`/`link`/...), so cross-format conversion INTO xml
        // from another format isn't meaningful yet. Same-format `-o canonical` /
        // `-o xml` still works, through the input row's `serializeCanonical`.
    },
    .{ .id = .html, .reads_back_as = .html, .serializeFromAst = serializeFromAstHtml },
    .{
        .id = .asciidoc,
        .reads_back_as = .asciidoc,
        // No serializer of any kind yet — see the `.asciidoc` input row.
    },
};

/// Look up `fmt`'s entry. Every `Format` variant has exactly one `registry`
/// entry (enforced by the test below rather than the type system — same trust
/// boundary fig's own hand-maintained tables rely on), so this never
/// legitimately misses.
pub fn entryFor(fmt: Format) *const Entry {
    for (&registry) |*e| {
        if (e.id == fmt) return e;
    }
    unreachable;
}

/// Look up `t`'s write-half entry. Every `Target` variant has exactly one
/// `targets` entry (enforced by the test below, same as `entryFor`), so this
/// never legitimately misses.
pub fn targetEntryFor(t: Target) *const TargetEntry {
    for (&targets) |*e| {
        if (e.id == t) return e;
    }
    unreachable;
}

/// `fmt`'s surface spelling — `Syntax.none` for a parse-only language, never
/// `null`. Ask `.authorable()` if you need to know which.
pub fn syntaxFor(fmt: Format) *const Syntax {
    return entryFor(fmt).syntax;
}

/// The entry for whichever language produced `doc`. `ParsedDoc` is
/// `union(Format)`, so the document knows its own row.
pub fn entryForDoc(doc: *const ParsedDoc) *const Entry {
    return entryFor(std.meta.activeTag(doc.*));
}

/// Errors `renderHtmlAlloc` can produce beyond a language's own. Named because
/// the `unsafe_metadata` refusal is a real, reportable outcome and not an
/// internal failure — a `metadata` node whose body contains `</script` can't be
/// emitted into a raw-text `<script>` data island without breaking out of the
/// element.
pub const RenderError = error{ OutOfMemory, UnsafeMetadata };

/// Render `doc` to HTML as an owned buffer — the registry's writer-shaped
/// `renderHtml`, collected. `Writer.Allocating` only ever fails
/// (`error.WriteFailed`) when its own backing allocation does, so it collapses
/// to `error.OutOfMemory`.
pub fn renderHtmlAlloc(allocator: Allocator, doc: *const ParsedDoc) RenderError![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    entryForDoc(doc).renderHtml(allocator, doc, &out.writer) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.UnsafeMetadata => return error.UnsafeMetadata,
        // The registry's adapters are `anyerror`-shaped only because they're
        // function pointers; rendering a already-parsed tree has no other
        // failure mode.
        else => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

/// Errors the serialize helpers report on top of a language's own.
pub const SerializeError = error{ OutOfMemory, UnsupportedFormat };

/// Serialize `doc` back to its OWN source syntax (`convert -o canonical`).
/// `error.UnsupportedFormat` when the language has no serializer yet.
pub fn serializeCanonicalAlloc(allocator: Allocator, doc: *const ParsedDoc) anyerror![]u8 {
    const f = entryForDoc(doc).serializeCanonical orelse return error.UnsupportedFormat;
    return f(allocator, doc);
}

/// Serialize a bare `AST` as `target`'s syntax, regardless of which language
/// parsed it (`convert -o <target>`, and the C ABI's builder output).
/// `error.UnsupportedFormat` when `target` has no AST serializer.
pub fn serializeFromAstAlloc(allocator: Allocator, ast: *const AST, target: Target) anyerror![]u8 {
    const f = targetEntryFor(target).serializeFromAst orelse return error.UnsupportedFormat;
    return f(allocator, ast);
}

/// Map an input name to a `Format`: the enum's own tag name first
/// (`std.meta.stringToEnum`, so `"djot"`/`"markdown"`/`"xml"` always work), then
/// each entry's `aliases` (`"dj"`, `"md"`). Returns `null` for an unrecognized
/// name so the caller can print a tailored error.
pub fn parseFormatName(name: []const u8) ?Format {
    if (std.meta.stringToEnum(Format, name)) |f| return f;
    for (&registry) |*e| {
        for (e.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return e.id;
        }
    }
    return null;
}

/// Map an output name to a `Target`: the enum's own tag names first, then every
/// input format's aliases via `parseFormatName`, so `-o dj` / `-o md` keep
/// meaning what they always did. An export-only target has no input row to
/// inherit aliases from and so is spelled by its full name only — which is why
/// the aliases are not duplicated into a second list here.
pub fn parseTargetName(name: []const u8) ?Target {
    if (std.meta.stringToEnum(Target, name)) |t| return t;
    if (parseFormatName(name)) |f| return targetFor(f);
    return null;
}

/// Infer a `Format` from a file path's extension (the part after its last `.`),
/// matched case-insensitively against every `registry` entry's `extensions`.
/// Returns `null` when the path has no extension or it matches no known format.
pub fn detectFromExtension(file_path: []const u8) ?Format {
    const dot = std.mem.lastIndexOfScalar(u8, file_path, '.') orelse return null;
    const ext = file_path[dot + 1 ..];
    if (ext.len == 0) return null;
    for (&registry) |*e| {
        for (e.extensions) |known| {
            if (std.ascii.eqlIgnoreCase(known, ext)) return e.id;
        }
    }
    return null;
}

test "every Format has exactly one registry entry" {
    inline for (std.meta.fields(Format)) |f| {
        const fmt: Format = @enumFromInt(f.value);
        var seen: usize = 0;
        for (&registry) |*e| {
            if (e.id == fmt) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "every Target has exactly one targets entry" {
    inline for (std.meta.fields(Target)) |f| {
        const t: Target = @enumFromInt(f.value);
        var seen: usize = 0;
        for (&targets) |*e| {
            if (e.id == t) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "every Format is also a Target, and the two agree in both directions" {
    // The subset invariant the `Target` doc comment promises, checked rather
    // than generated. `targetFor` is total by construction (a missing name is a
    // compile error); what needs asserting is that the target it lands on says
    // the SAME format reads it back, so nothing can be wired to a row that
    // spells a different language.
    inline for (std.meta.fields(Format)) |f| {
        const fmt: Format = @enumFromInt(f.value);
        const t = targetFor(fmt);
        try std.testing.expectEqualStrings(@tagName(fmt), @tagName(t));
        try std.testing.expectEqual(fmt, t.asFormat().?);
    }
}

test "the write half is keyed on the target, not on what parsed it" {
    // `-i markdown -o djot` reaches djot's serializer without markdown's row
    // being consulted for it at all — the property that lets an export-only
    // target exist with no input row of its own. The `null` here is the same
    // "not supported yet" every caller reports, sourced from the TARGET table.
    try std.testing.expect(targetEntryFor(.djot).serializeFromAst != null);
    try std.testing.expect(targetEntryFor(.xml).serializeFromAst == null);
    try std.testing.expectEqual(Target.djot, parseTargetName("dj").?);
    try std.testing.expectEqual(Target.markdown, parseTargetName("markdown").?);
    try std.testing.expect(parseTargetName("nope") == null);
}

test "every syntax table in the registry is coherent" {
    for (&registry) |*e| e.syntax.assertCoherent();
}

test "exactly djot and markdown are authorable" {
    try std.testing.expect(syntaxFor(.djot).authorable());
    try std.testing.expect(syntaxFor(.markdown).authorable());
    // XML, HTML and AsciiDoc parse and render but cannot be authored into: they
    // carry the table that spells nothing, so every gesture over them is
    // refused.
    try std.testing.expect(!syntaxFor(.xml).authorable());
    try std.testing.expect(!syntaxFor(.html).authorable());
    try std.testing.expect(!syntaxFor(.asciidoc).authorable());
}

test "AsciiDoc parses and renders but does not serialize" {
    const entry = entryFor(.asciidoc);
    try std.testing.expect(entry.serializeCanonical == null);
    try std.testing.expect(targetEntryFor(.asciidoc).serializeFromAst == null);
    try std.testing.expectEqual(Format.asciidoc, parseFormatName("adoc").?);
    try std.testing.expectEqual(Format.asciidoc, detectFromExtension("guide.ADOC").?);
}

test "an unimplemented AsciiDoc construct renders as literal source, not as a mangled tree" {
    // The property the registry entry rests on — see the `.asciidoc` row. A
    // block macro is one of the many things `asciidoc/parser.zig` does not
    // implement; what matters is that its source SURVIVES to the output instead
    // of being half-consumed into some other node.
    var doc = try parseAsciidoc(&ParseConfig{}, std.testing.allocator, "image:logo.png[Logo]\n");
    defer doc.deinit();
    const html = try renderHtmlAlloc(std.testing.allocator, &doc);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<p>image:logo.png[Logo]</p>\n", html);
}

// ── cross-format round-trips ───────────────────────────────────────────────
//
// Markdown -> Djot -> HTML is where a serializer gap shows up as silent data
// loss rather than an error: a construct the Djot serializer can't spell is
// written as something that reparses into a DIFFERENT node, and only rendering
// the reparse catches it. Asserting on the Djot text alone would not — the
// output looks like a plausible document either way.

/// Markdown source -> Djot text -> reparsed as Djot -> HTML.
fn markdownThroughDjotToHtml(allocator: Allocator, source: []const u8) ![]u8 {
    var md = try Markdown.parse(allocator, source, .{});
    defer md.deinit();
    const djot_src = try djot_serializer.serializeAstAlloc(allocator, &md.ast);
    defer allocator.free(djot_src);
    var dj = try Djot.parse(allocator, djot_src);
    defer dj.deinit();
    return Djot.html.renderAlloc(allocator, &dj, .{});
}

test "round-trip: a Markdown table's header row survives the Djot leg" {
    const out = try markdownThroughDjotToHtml(std.testing.allocator, "| a | b |\n| --- | --- |\n| 1 | 2 |\n");
    defer std.testing.allocator.free(out);
    // Djot marks a header by the separator line under it, so dropping the
    // separator on the way out turns every `<th>` back into a `<td>`.
    try std.testing.expect(std.mem.indexOf(u8, out, "<th>a</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<td>1</td>") != null);
}

test "round-trip: column alignment survives the Djot leg" {
    const out = try markdownThroughDjotToHtml(std.testing.allocator, "| a | b |\n| :-- | --: |\n| 1 | 2 |\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<th style=\"text-align: left;\">a</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<td style=\"text-align: right;\">2</td>") != null);
}

test "round-trip: a table survives Djot -> HTML -> Djot" {
    // The other direction: HTML is a real input format, so a table has to
    // survive being read back out of the printer's own output — row groups,
    // header, alignment, caption and all.
    const source = "| a | b |\n|:--|--:|\n| 1 | 2 |\n^ Cap\n";
    var dj = try Djot.parse(std.testing.allocator, source);
    defer dj.deinit();
    const rendered = try Djot.html.renderAlloc(std.testing.allocator, &dj, .{});
    defer std.testing.allocator.free(rendered);

    var page = try Html.parse(std.testing.allocator, rendered);
    defer page.deinit();
    const back = try djot_serializer.serializeAstAlloc(std.testing.allocator, &page.ast);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(source, back);
}

test "round-trip: raw inline HTML survives the Djot leg" {
    const out = try markdownThroughDjotToHtml(std.testing.allocator, "x <sub>y</sub> z\n");
    defer std.testing.allocator.free(out);
    // Written as bare text, the tags reparse as ordinary characters and come
    // back escaped (`&lt;sub&gt;`) with no error raised anywhere.
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>x <sub>y</sub> z</p>") != null);
}

test "round-trip: a raw HTML block survives the Djot leg" {
    const out = try markdownThroughDjotToHtml(std.testing.allocator, "<div>\nhi\n</div>\n");
    defer std.testing.allocator.free(out);
    // Spelled as a language (` ```html `) rather than djot's raw form
    // (` ```=html `), this reparses as a code block and renders as escaped
    // text inside `<pre>`.
    try std.testing.expect(std.mem.indexOf(u8, out, "<div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<pre>") == null);
}

test "format names and extensions resolve" {
    try std.testing.expectEqual(Format.djot, parseFormatName("dj").?);
    try std.testing.expectEqual(Format.markdown, parseFormatName("markdown").?);
    try std.testing.expect(parseFormatName("nope") == null);
    try std.testing.expectEqual(Format.markdown, detectFromExtension("a/b.MD").?);
    try std.testing.expect(detectFromExtension("noext") == null);
}
