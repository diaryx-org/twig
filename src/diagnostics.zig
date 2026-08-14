//! Conversion diagnostics: a read-only pass that reports what serializing this
//! AST to that format would silently lose.
//!
//! Twig's serializers degrade or drop a node whenever the target format has no
//! spelling for it — djot's `{=mark=}` written into Markdown comes back as
//! plain text, an HTML comment converted to djot vanishes entirely. None of it
//! is an error (the output is still a valid document), so it happens quietly.
//! `analyze` surfaces it: it walks the tree and returns one `Warning` per lossy
//! node.
//!
//! Ported from fig's `src/diagnostics.zig`, which does the same job for its
//! data formats, and kept deliberately separate from `parse_diagnostic.zig` for
//! the reasons `languages/rst/rst.zig` sets out: a parse diagnostic anchors to a
//! byte span in the SOURCE and is a fact about one document, while a conversion
//! warning has no source offset to point at (the output does not exist yet), so
//! it anchors to a node PATH — and it is a fact about a (document, target)
//! PAIR, which is why it cannot be stored alongside a `Document` at all.
//!
//! ── The table is the gate on the vocabulary ────────────────────────────────
//! `fidelity` switches exhaustively over `Kind` AND over the three family enums
//! (`InlineMark`, `TextLeafKind`, `MarkupLeafKind`), which is what makes adding
//! a node kind cost one honest answer per target, declared here, instead of
//! whatever an `else =>` arm in three serializers happens to do. That is the
//! property `languages/rst/rst.zig` leans on to add kinds only rST has.
//!
//! It is easy to have this property and not notice it is gone. Both halves were
//! broken when the first such kinds (`citation`, `substitution`) arrived: the
//! per-target functions ended in `else => .faithful`, so a new `Kind` inherited
//! `.faithful` in silence; and this module was missing from `root.zig`'s
//! `test {}` block, so Zig — which analyzes lazily — never compiled these
//! switches at all and never ran the probe below. Keep both: the exhaustive
//! spelling, and the import that forces it to be analyzed.
//!
//! ── The table is measured, not asserted ────────────────────────────────────
//! `fidelity` is the single source of truth for what each target can hold, and
//! its entries are not a reading of the serializers — they are what the
//! serializers were OBSERVED to do. `test "the fidelity table matches what the
//! serializers actually do"` builds a minimal document around every kind,
//! serializes it, reparses it with the target's own parser, and asserts the
//! kind is present again exactly when the table claims `.faithful`. A serializer
//! change that alters a round-trip fails here rather than drifting.
//!
//! That mattered immediately: the nearest thing twig already had to a capability
//! model, `syntax.zig`'s `Delims.authorable`, turns out NOT to be one. It is
//! false for both djot's and Markdown's smart-quote containers, but converting
//! to djot round-trips them faithfully (djot's parser makes `double_quoted` out
//! of a bare `"`) while converting to Markdown does not. Same flag, opposite
//! answers — the flag means "an editor gesture may not mint this", which is a
//! different question from "the target can hold this".
//!
//! ── What is NOT covered yet ────────────────────────────────────────────────
//! Node kinds only. Attributes are the declared next axis: Markdown's serializer
//! writes a `{...}` block for a directive and nothing anywhere else, so a djot
//! paragraph's `{#id .cls}` is lost with no warning today. That needs its own
//! per-format answer and its own probe, so it is named here rather than guessed
//! at.
//!
//! fig's `Warning.cause` (`format_limitation` vs `explicit_option`) is also
//! absent, because twig has no serializer option that drops anything — every
//! loss here is inherent to the target. It returns when there is a second cause
//! to distinguish.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("ast/ast.zig");
const Node = AST.Node;
const format = @import("format.zig");
const Target = format.Target;

/// How much of a node survives a round-trip through a target format: serialize
/// it, hand the result back to that format's own parser, and see what returns.
///
/// The definition is a ROUND-TRIP, which is why this module is indexed by
/// `format.Target` and still needs each target to be readable back. An
/// export-only target (`Target.asFormat() == null`) has no parser to hand the
/// output to, so its fidelity is not measurable this way and the probe below
/// skips it by construction rather than by a hardcoded list. Whoever adds the
/// first such target will find an exhaustive switch in `fidelity` demanding an
/// answer: the honest one is a second axis, not a guess on this one.
pub const Fidelity = enum {
    /// The target spells the kind, and reparses that spelling back to it.
    faithful,
    /// Something is emitted, but the target's parser reads it as a DIFFERENT
    /// kind — the content survives, its meaning does not. Markdown has no
    /// `^sup^`, so a djot superscript arrives as literal text.
    degraded,
    /// Nothing is emitted at all: the node and its subtree leave no trace.
    dropped,

    pub fn isLossy(self: Fidelity) bool {
        return self != .faithful;
    }
};

/// One thing a conversion to a given format would lose.
pub const Warning = struct {
    fidelity: Fidelity,
    /// Slash-separated child-index trail from the analyzed root (`"1/0/2"`).
    /// Empty means the root itself. Arena-owned by `analyze`.
    path: []const u8,
    /// The affected node's published kind name — `Kind.kindName`, so a family
    /// member reports as itself (`"superscript"`, not `"inline_mark"`).
    kind: []const u8,

    /// The default human-readable message, no trailing newline. Bindings may
    /// render their own from the structured fields instead.
    pub fn render(self: Warning, writer: *Writer, target: Target) Writer.Error!void {
        switch (self.fidelity) {
            .faithful => unreachable, // never recorded
            .degraded => {
                try writer.print("`{s}` at ", .{self.kind});
                try writeLoc(writer, self.path);
                try writer.print(" is not spelled by {s} and will reparse as something else", .{@tagName(target)});
            },
            .dropped => {
                try writer.print("`{s}` at ", .{self.kind});
                try writeLoc(writer, self.path);
                try writer.print(" is dropped entirely ({s} cannot write it)", .{@tagName(target)});
            },
        }
    }
};

fn writeLoc(writer: *Writer, path: []const u8) Writer.Error!void {
    if (path.len == 0) {
        try writer.writeAll("the document root");
    } else {
        try writer.writeByte('`');
        try writer.writeAll(path);
        try writer.writeByte('`');
    }
}

pub const AnalyzeError = error{
    /// The target has no `serializeFromAst` at all, so there is no conversion to
    /// describe — every node would be lost, which is a `format.zig` capability
    /// answer (`error.UnsupportedFormat`) rather than a per-node diagnosis.
    UnsupportedFormat,
} || Allocator.Error;

/// Walk the subtree at `root_id` as `target`'s serializer would and collect one
/// `Warning` per lossy node. Warnings and their paths are allocated in `arena`.
///
/// A lossy node still has its children walked: a `dropped` container takes its
/// subtree with it, but reporting only the outermost loss would hide that six
/// distinct constructs went missing rather than one.
pub fn analyze(arena: Allocator, ast: *const AST, root_id: Node.Id, target: Target) AnalyzeError![]Warning {
    if (format.targetEntryFor(target).serializeFromAst == null) return error.UnsupportedFormat;
    var c: Collector = .{ .ast = ast, .arena = arena, .target = target };
    try c.walk(root_id, "");
    return c.warnings.toOwnedSlice(arena);
}

const Collector = struct {
    ast: *const AST,
    arena: Allocator,
    target: Target,
    warnings: std.ArrayList(Warning) = .empty,

    fn walk(self: *Collector, id: Node.Id, path: []const u8) AnalyzeError!void {
        const kind = self.ast.nodes[id].kind;
        const f = fidelity(self.target, kind);
        if (f.isLossy()) {
            try self.warnings.append(self.arena, .{
                .fidelity = f,
                .path = path,
                .kind = kind.kindName(),
            });
        }
        var it = self.ast.children(id);
        var i: usize = 0;
        while (it.next()) |child| : (i += 1) {
            try self.walk(child.id, try childPath(self.arena, path, i));
        }
    }
};

fn childPath(arena: Allocator, parent: []const u8, i: usize) Allocator.Error![]const u8 {
    if (parent.len == 0) return std.fmt.allocPrint(arena, "{d}", .{i});
    return std.fmt.allocPrint(arena, "{s}/{d}", .{ parent, i });
}

// ── the capability table ───────────────────────────────────────────────────
//
// What each target format can hold, per kind. EXHAUSTIVE over `Kind` and over
// the three family enums, which is the property that makes this the gate a new
// kind has to pass: adding one fails this build until it has declared an answer
// for every format, in one place, instead of silently inheriting whatever an
// `else =>` arm in three serializers happens to do.
//
// `str`, and the structural children that only ever appear inside their own
// parent (`list_item`, `row`, `cell`, `term`, …), are `.faithful` everywhere by
// construction: they carry no spelling of their own and ride along with the
// parent that does. A lossy parent is reported once, at the parent.

/// How `kind` survives a conversion to `target`. See the note above the table.
pub fn fidelity(target: Target, kind: Node.Kind) Fidelity {
    return switch (target) {
        // No `serializeFromAst`; `analyze` refuses before reaching the table.
        .xml, .asciidoc => .dropped,
        .djot => djotFidelity(kind),
        .markdown => markdownFidelity(kind),
        .html => htmlFidelity(kind),
    };
}

/// Djot holds nearly all of twig's vocabulary — unsurprising, since most of it
/// was named after djot's own. The four gaps are real, though, and two of them
/// lose data outright.
fn djotFidelity(kind: Node.Kind) Fidelity {
    return switch (kind) {
        // Generic markup: djot has no comment, doctype, CDATA or processing
        // instruction syntax, and its serializer has no arm for any of them —
        // they fall to an inline `else` that renders children, and these have
        // none. An HTML comment converted to djot leaves NOTHING behind.
        .markup_leaf, .processing_instruction => .dropped,
        // A substitution definition renders nothing at the point of definition
        // in any format (its body belongs at the use sites), and djot has no
        // `|name|` splice to carry it there — so the body goes nowhere. The
        // only kind whose CONTENT no target holds; `column` below is dropped by
        // all three too, but what it loses is metadata about content that
        // survives elsewhere.
        .substitution => .dropped,
        // A pipe table has no column axis to write one into — djot describes a
        // column only through the alignment of its cells. Nothing is emitted,
        // so the width and the stub flag go with it. Content is not at risk
        // (the cells are children of the ROWS), which is why this is a
        // metadata loss rather than a body one, but `Fidelity` measures the
        // node and the node does not survive. See `Kind.column`.
        .column => .dropped,
        // Djot writes a metadata block as a `{lang}`-tagged div, and its own
        // parser reads that back as a div, not as metadata.
        .metadata => .degraded,
        // Djot has no definition-list syntax; the serializer emits the term and
        // definition as ordinary blocks.
        .definition_list => .degraded,
        // No verse construct either: a line block is written as one paragraph
        // with hard breaks. The text and the breaks survive, the block does
        // not, and each line's `indent` goes with it — djot strips the leading
        // space of a continuation line. Unlike `term`/`row`/`cell`, `line` is
        // NOT faithful-by-riding-along here, because the parent it rides on
        // does not come back either; it is reported on its own.
        .line_block, .line => .degraded,
        // Djot has ONE footnote registry, so a citation is written as a footnote
        // definition and comes back a `footnote`. The content and the
        // definition/use link both survive; the second registry does not, which
        // is what makes it `degraded` rather than faithful — two labels that
        // were distinct across registries can now collide.
        .citation => .degraded,
        // Djot holds a container's identity in `attrs`, as a class — both the
        // fenced div's class line and the bracketed span's `{...}`. So the
        // answer turns on the NAME, not on the form: an anonymous container is
        // djot's own and returns as itself, while a named one (an rST role, a
        // Markdown directive, an HTML tag) comes back anonymous-and-classed.
        // The kind survives, its identity does not.
        //
        // This read `if (c.form == .inline_text) .degraded else .faithful`
        // while the serializer was deleting the name outright, and the probe
        // agreed, because `want` matched on the TAG — a container came back,
        // so a container had survived. `KindRef.container_named` is what makes
        // the difference measurable.
        .container => |c| if (c.name.len == 0) .faithful else .degraded,
        // Math is emitted as `$`…`` — a verbatim wearing a sigil — and djot's
        // parser returns the verbatim without it. A citation reference follows
        // its definition into the footnote registry; a substitution reference is
        // written in its rST spelling and reads as plain text.
        .text_leaf => |l| switch (l.kind) {
            .inline_math, .display_math, .citation_reference, .substitution_reference => .degraded,
            .symb, .verbatim, .url, .email, .footnote_reference => .faithful,
        },
        .doc,
        .para,
        .heading,
        .thematic_break,
        .section,
        .code_block,
        .raw_block,
        .block_quote,
        .bullet_list,
        .ordered_list,
        .task_list,
        .table,
        .list_item,
        .task_list_item,
        .definition_list_item,
        .term,
        .definition,
        .row,
        .cell,
        .caption,
        .footnote,
        .reference,
        .str,
        .soft_break,
        .hard_break,
        .non_breaking_space,
        .raw_inline,
        .smart_punctuation,
        .link,
        .image,
        .inline_mark,
        => .faithful,
    };
}

/// Markdown spells strictly less than djot — three inline marks against nine,
/// no generic containers, no smart punctuation of its own — so this is where
/// most conversion loss actually happens.
fn markdownFidelity(kind: Node.Kind) Fidelity {
    return switch (kind) {
        // CommonMark has no heading-scoped section; the children are emitted
        // flat and the wrapper is gone.
        .section => .degraded,
        // A raw block is written as a fenced code block, which reparses as one.
        .raw_block => .degraded,
        // Markdown has no `:::name` fenced div in CommonMark; the serializer's
        // directive spelling is an extension its own parser does not read back
        // without one.
        .container => .degraded,
        // Written as raw HTML text, which comes back as a raw block/inline or
        // as escaped characters — never as the leaf it was.
        .markup_leaf, .processing_instruction, .raw_inline => .degraded,
        // Emitted as its ASCII spelling (`...`, `"`), which CommonMark reads as
        // ordinary characters.
        .smart_punctuation => .degraded,
        // `&nbsp;` — an entity, so it returns as text.
        .non_breaking_space => .degraded,
        // Only `strong`, `emph` and GFM's `delete` survive. The rest carry the
        // extension spellings `markdown/syntax.zig` records for exactly this
        // conversion (`==mark==`, `^sup^`, `{+ins+}`), which CommonMark reads as
        // literal text — better than dropping the node, but not the same node.
        // The two smart-quote containers are the case that proves `authorable`
        // is not this question: they are `authorable = false` in BOTH tables,
        // yet faithful in djot and degraded here.
        .inline_mark => |m| switch (m) {
            .strong, .emph, .delete => .faithful,
            .mark, .superscript, .subscript, .insert, .double_quoted, .single_quoted => .degraded,
        },
        // Both new definitions behave exactly as they do for djot, and for the
        // same reasons — Markdown's footnote extension is djot's registry over
        // again, and it has no substitution mechanism either.
        .citation => .degraded,
        .substitution => .dropped,
        // Same spelling and same loss as djot's — see that arm.
        .line_block, .line => .degraded,
        // GFM's pipe table has no column axis either — same as djot.
        .column => .dropped,
        .text_leaf => |l| switch (l.kind) {
            .verbatim, .url, .email, .footnote_reference => .faithful,
            .symb, .inline_math, .display_math, .citation_reference, .substitution_reference => .degraded,
        },
        .doc,
        .para,
        .heading,
        .thematic_break,
        .code_block,
        .metadata,
        .block_quote,
        .bullet_list,
        .ordered_list,
        .task_list,
        .definition_list,
        .table,
        .list_item,
        .task_list_item,
        .definition_list_item,
        .term,
        .definition,
        .row,
        .cell,
        .caption,
        .footnote,
        .reference,
        .str,
        .soft_break,
        .hard_break,
        .link,
        .image,
        => .faithful,
    };
}

/// HTML is a RENDER target, not a source syntax, and the asymmetry shows: it
/// spells the generic-markup kinds djot and Markdown cannot, and loses the
/// lightweight-markup semantics they keep. Everything here is measured against
/// re-parsing the rendered HTML, which is what a caller converting to HTML and
/// reading it back actually gets.
fn htmlFidelity(kind: Node.Kind) Fidelity {
    return switch (kind) {
        // The generic-markup kinds are HTML's own, and survive as themselves.
        .processing_instruction => .faithful,
        .markup_leaf => |l| switch (l.kind) {
            .comment, .doctype => .faithful,
            // Rendered escaped rather than as a `<![CDATA[…]]>` section.
            .cdata => .degraded,
        },
        // A raw block's payload is written through verbatim, so the wrapper is
        // gone and what remains is whatever those bytes parse as.
        .raw_block, .raw_inline => .degraded,
        // Rendered as its config text inside a comment or dropped from the body.
        .metadata => .degraded,
        // Checkbox inputs inside an ordinary list: the list survives, the
        // task-ness does not.
        .task_list, .task_list_item => .degraded,
        // Definition lists render as `<dl>`, which twig's HTML parser has no
        // semantic mapping for yet.
        .definition_list, .definition_list_item, .term, .definition => .degraded,
        // The one target that spells a line block the way its source format
        // does — docutils' `<div class="line-block">`/`<div class="line">`,
        // indent and all (see the serializer's `renderLineBlock`). It still
        // degrades, for the `<dl>` reason: a classed div reads back as a
        // generic `container`, so the output is right and the KIND is gone.
        .line_block, .line => .degraded,
        // Footnote and link-reference DEFINITIONS are resolved at render time —
        // the reference is inlined into an `<a href>`/endnote and the definition
        // node itself has no output of its own.
        .footnote, .reference => .degraded,
        // A citation is the one definition this printer writes IN PLACE, as
        // docutils' HTML5 writer does, so it does leave output — a
        // `<div class="citation">` that twig's HTML parser reads back as a
        // generic `container`.
        .citation => .degraded,
        // Nothing is written, here or anywhere: the printer does not resolve a
        // substitution (no side table exists to resolve it against until the rST
        // parser lands), and a definition has no output of its own. The body is
        // lost outright, which is the strongest reason this whole module was
        // built before the vocabulary that needs it.
        .substitution => .dropped,
        // The one target that HAS the construct — `<colgroup><col>` — and still
        // does not write it. Emitting a bare `<col>` among the rows would be
        // invalid (HTML's table content model puts `col` inside a `colgroup`),
        // so spelling this means teaching the serializer's thead/tbody state
        // machine a third group, and reading it back means mapping `<col>` in
        // the HTML parser. Both are worth doing and neither is done, so the
        // honest entry today is the same as the other two targets'. This is the
        // arm to revisit first if `Kind.column` ever grows a typed payload.
        .column => .dropped,
        // A NAMED container is HTML's own — `<video>` goes out as `<video>` and
        // comes back as one. An ANONYMOUS one cannot be: there is no such thing
        // as an unnamed HTML tag, so the serializer picks `div` or `span` by
        // level and the parser reads that back as a container NAMED "div" or
        // "span". The node survives; the fact that it had no name does not, and
        // afterwards it is indistinguishable from a document that really did
        // write `<div>`.
        .container => |c| if (c.name.len == 0) .degraded else .faithful,
        // Rendered as Unicode glyphs, which come back as ordinary text.
        .smart_punctuation, .non_breaking_space => .degraded,
        .inline_mark => |m| switch (m) {
            // `<q>` is not what twig's HTML parser makes a `double_quoted` from.
            .double_quoted, .single_quoted => .degraded,
            .strong, .emph, .mark, .superscript, .subscript, .insert, .delete => .faithful,
        },
        .text_leaf => |l| switch (l.kind) {
            .verbatim => .faithful,
            // An autolink renders as `<a href>` and returns as a `link`; math
            // renders as a classed span; a footnote reference becomes a
            // numbered `<sup>` whose label is gone; a citation reference is an
            // `<a href="#label">` that likewise returns as a `link`; an
            // unresolved substitution reference is written as its own `|name|`
            // spelling and returns as text.
            .url, .email, .inline_math, .display_math, .symb, .footnote_reference, .citation_reference, .substitution_reference => .degraded,
        },
        .doc,
        .para,
        .heading,
        .thematic_break,
        .section,
        .code_block,
        .block_quote,
        .bullet_list,
        .ordered_list,
        .table,
        .list_item,
        .row,
        .cell,
        .caption,
        .str,
        .soft_break,
        .hard_break,
        .link,
        .image,
        => .faithful,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const select = @import("ast/select.zig");

/// The targets a round-trip claim can be made about at all: those Twig can
/// WRITE (`serializeFromAst`) and can also READ BACK (`reads_back_as`). Derived
/// from the `targets` table rather than listed, so a new row is either measured
/// automatically or excluded for a reason the table itself states — an
/// export-only target drops out here by construction, and no probe is ever
/// silently skipped by a hardcoded list going stale.
const round_trippable: []const Target = blk: {
    var out: []const Target = &.{};
    for (format.targets) |e| {
        if (e.serializeFromAst != null and e.reads_back_as != null) out = out ++ [_]Target{e.id};
    }
    break :blk out;
};

test "the probe covers every target that can be measured, and today that is three" {
    try testing.expectEqual(@as(usize, 3), round_trippable.len);
    try testing.expectEqualSlices(Target, &.{ .djot, .markdown, .html }, round_trippable);
}

test "analyze refuses a target with no serializer rather than reporting every node" {
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const root = try b.addContainer(.doc, &.{});
    var ast = try b.finish(root);
    defer ast.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedFormat, analyze(arena.allocator(), &ast, ast.root, .xml));
}

test "an HTML comment converted to djot is reported as dropped, and really is" {
    const allocator = testing.allocator;
    var b = AST.Builder.init(allocator);
    defer b.deinit();
    const c = try b.addLeaf(.{ .markup_leaf = .{ .kind = .comment, .text = " secret " } });
    const p = try b.addContainer(.para, &.{try b.addLeaf(.{ .str = "hi" })});
    const root = try b.addContainer(.doc, &.{ p, c });
    var ast = try b.finish(root);
    defer ast.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const warnings = try analyze(arena.allocator(), &ast, ast.root, .djot);
    try testing.expectEqual(@as(usize, 1), warnings.len);
    try testing.expectEqual(Fidelity.dropped, warnings[0].fidelity);
    try testing.expectEqualStrings("comment", warnings[0].kind);
    try testing.expectEqualStrings("1", warnings[0].path);

    // And the warning is true: the comment leaves no trace in the djot output.
    const src = try format.targetEntryFor(.djot).serializeFromAst.?(allocator, &ast);
    defer allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "secret") == null);
}

test "a substitution's body is dropped by every target, and is reported as such" {
    const allocator = testing.allocator;
    var b = AST.Builder.init(allocator);
    defer b.deinit();
    const def = try b.addContainer(.{ .substitution = .{ .label = "RST" } }, &.{try b.addLeaf(.{ .str = "reStructuredText" })});
    const ref = try b.addLeaf(.{ .text_leaf = .{ .kind = .substitution_reference, .text = "RST" } });
    const body = try b.addContainer(.para, &.{ref});
    const root = try b.addContainer(.doc, &.{ body, def });
    var ast = try b.finish(root);
    defer ast.deinit();

    for (round_trippable) |target| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const warnings = try analyze(arena.allocator(), &ast, ast.root, target);
        // The definition is `dropped` and its use `degraded` — two warnings,
        // never zero, for every target twig can write.
        try testing.expectEqual(@as(usize, 2), warnings.len);
        try testing.expectEqual(Fidelity.degraded, warnings[0].fidelity);
        try testing.expectEqualStrings("substitution_reference", warnings[0].kind);
        try testing.expectEqual(Fidelity.dropped, warnings[1].fidelity);
        try testing.expectEqualStrings("substitution", warnings[1].kind);

        // And `dropped` is the literal truth: the body reaches no output.
        const src = try format.targetEntryFor(target).serializeFromAst.?(allocator, &ast);
        defer allocator.free(src);
        try testing.expect(std.mem.indexOf(u8, src, "reStructuredText") == null);
    }
}

test "a citation survives a conversion as a footnote, definition and use together" {
    const allocator = testing.allocator;
    var b = AST.Builder.init(allocator);
    defer b.deinit();
    const p = try b.addContainer(.para, &.{try b.addLeaf(.{ .str = "Deep Thought." })});
    const def = try b.addContainer(.{ .citation = .{ .label = "CIT2002" } }, &.{p});
    const ref = try b.addLeaf(.{ .text_leaf = .{ .kind = .citation_reference, .text = "CIT2002" } });
    const body = try b.addContainer(.para, &.{ try b.addLeaf(.{ .str = "see " }), ref });
    const root = try b.addContainer(.doc, &.{ body, def });
    var ast = try b.finish(root);
    defer ast.deinit();

    // Flattened into djot's one footnote registry: `degraded`, not `dropped` —
    // both halves reach the output and still name each other, which is what
    // separates this from the substitution case above.
    const src = try format.targetEntryFor(.djot).serializeFromAst.?(allocator, &ast);
    defer allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "[^CIT2002]") != null);
    try testing.expect(std.mem.indexOf(u8, src, "[^CIT2002]: Deep Thought.") != null);
}

test "a warning renders with its path and target" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const warning: Warning = .{ .fidelity = .degraded, .path = "0/1", .kind = "superscript" };
    try warning.render(&w, .markdown);
    try testing.expectEqualStrings(
        "`superscript` at `0/1` is not spelled by markdown and will reparse as something else",
        w.buffered(),
    );
}

// ── the probe that keeps the table honest ──────────────────────────────────
//
// For every kind, build a minimal document containing it, serialize it to each
// target, reparse with that target's own parser, and assert the kind comes back
// exactly when `fidelity` says `.faithful`. This is what makes the table a
// measurement instead of a claim.
//
// Only the `.faithful` bit is asserted. Separating `degraded` from `dropped`
// needs to know whether ANY trace of the node reached the output, and for the
// payload-less kinds (`smart_punctuation`, `non_breaking_space`) there is no
// content to look for — so that distinction is documented per entry from the
// serializers rather than probed, and is the weaker half of this table.

fn str(b: *AST.Builder, s: []const u8) !Node.Id {
    return b.addLeaf(.{ .str = s });
}

fn blockDoc(b: *AST.Builder, kind: Node.Kind, children: []const Node.Id) !Node.Id {
    return b.addContainer(.doc, &.{try b.addContainer(kind, children)});
}

fn inlineDoc(b: *AST.Builder, kind: Node.Kind, children: []const Node.Id) !Node.Id {
    const n = try b.addContainer(kind, children);
    return b.addContainer(.doc, &.{try b.addContainer(.para, &.{n})});
}

fn buildLineBlock(b: *AST.Builder) anyerror!Node.Id {
    const l1 = try b.addContainer(.{ .line = .{} }, &.{try str(b, "one")});
    const l2 = try b.addContainer(.{ .line = .{ .indent = 1 } }, &.{try str(b, "two")});
    return blockDoc(b, .line_block, &.{ l1, l2 });
}

const Probe = struct {
    label: []const u8,
    /// What the built document is being probed FOR, and the kind whose
    /// `fidelity` entry the round-trip must agree with.
    want: AST.KindRef,
    kind: Node.Kind,
    build: *const fn (*AST.Builder) anyerror!Node.Id,
};

/// Only ever called with a `round_trippable` target, so both unwraps below hold:
/// the write half comes from the TARGET row and the read half from the INPUT row
/// the target names, which is the whole shape of the two-table split.
fn survives(allocator: Allocator, ast: *const AST, target: Target, want: AST.KindRef) !bool {
    const src = try format.targetEntryFor(target).serializeFromAst.?(allocator, ast);
    defer allocator.free(src);
    const cfg = format.ParseConfig{};
    var back = try format.entryFor(target.asFormat().?).parseToAst(&cfg, allocator, src);
    defer back.deinit();
    for (back.ast.nodes) |n| {
        if (want.matches(n.kind)) return true;
    }
    return false;
}

test "the fidelity table matches what the serializers actually do" {
    const allocator = testing.allocator;
    for (probes) |p| {
        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const root = try p.build(&b);
        var ast = try b.finish(root);
        defer ast.deinit();

        for (round_trippable) |target| {
            const claimed = fidelity(target, p.kind);
            const observed = try survives(allocator, &ast, target, p.want);
            if ((claimed == .faithful) != observed) {
                std.debug.print(
                    "\nfidelity({s}, {s}) claims .{s}, but the kind {s} a round-trip\n",
                    .{ @tagName(target), p.label, @tagName(claimed), if (observed) "SURVIVES" else "does NOT survive" },
                );
                return error.FidelityTableStale;
            }
        }
    }
}

const probes = [_]Probe{
    .{ .label = "heading", .want = .{ .tag = .heading }, .kind = .{ .heading = .{ .level = 2 } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .heading = .{ .level = 2 } }, &.{try str(b, "x")});
        }
    }.f },
    .{ .label = "section", .want = .{ .tag = .section }, .kind = .section, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const h = try b.addContainer(.{ .heading = .{ .level = 1 } }, &.{try str(b, "t")});
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            return blockDoc(b, .section, &.{ h, p });
        }
    }.f },
    .{ .label = "block_quote", .want = .{ .tag = .block_quote }, .kind = .block_quote, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            return blockDoc(b, .block_quote, &.{p});
        }
    }.f },
    .{ .label = "thematic_break", .want = .{ .tag = .thematic_break }, .kind = .thematic_break, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .thematic_break, &.{});
        }
    }.f },
    .{ .label = "code_block", .want = .{ .tag = .code_block }, .kind = .{ .code_block = .{ .lang = null, .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .code_block = .{ .lang = "zig", .text = "x\n" } }, &.{});
        }
    }.f },
    .{ .label = "raw_block", .want = .{ .tag = .raw_block }, .kind = .{ .raw_block = .{ .format = "", .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .raw_block = .{ .format = "html", .text = "<x>\n" } }, &.{});
        }
    }.f },
    .{ .label = "metadata", .want = .{ .tag = .metadata }, .kind = .{ .metadata = .{ .lang = "", .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .metadata = .{ .lang = "yaml", .text = "a: 1\n" } }, &.{});
        }
    }.f },
    .{ .label = "bullet_list", .want = .{ .tag = .bullet_list }, .kind = .{ .bullet_list = .{ .tight = true } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            const li = try b.addContainer(.list_item, &.{p});
            return blockDoc(b, .{ .bullet_list = .{ .tight = true } }, &.{li});
        }
    }.f },
    .{ .label = "ordered_list", .want = .{ .tag = .ordered_list }, .kind = .{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = 1 } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            const li = try b.addContainer(.list_item, &.{p});
            return blockDoc(b, .{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = 1 } }, &.{li});
        }
    }.f },
    .{ .label = "task_list", .want = .{ .tag = .task_list }, .kind = .{ .task_list = .{ .tight = true } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            const li = try b.addContainer(.{ .task_list_item = .{ .checked = true } }, &.{p});
            return blockDoc(b, .{ .task_list = .{ .tight = true } }, &.{li});
        }
    }.f },
    .{ .label = "definition_list", .want = .{ .tag = .definition_list }, .kind = .definition_list, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const t = try b.addContainer(.term, &.{try str(b, "t")});
            const p = try b.addContainer(.para, &.{try str(b, "d")});
            const d = try b.addContainer(.definition, &.{p});
            const item = try b.addContainer(.definition_list_item, &.{ t, d });
            return blockDoc(b, .definition_list, &.{item});
        }
    }.f },
    // A two-line verse with an indented second line, probed for the BLOCK and
    // for the LINE separately — the two claims are independent, and a probe
    // asserting both would be satisfied by either surviving alone.
    .{ .label = "line_block", .want = .{ .tag = .line_block }, .kind = .line_block, .build = buildLineBlock },
    .{ .label = "line", .want = .{ .tag = .line }, .kind = .{ .line = .{} }, .build = buildLineBlock },
    .{ .label = "table", .want = .{ .tag = .table }, .kind = .table, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const cap = try b.addContainer(.caption, &.{});
            const c1 = try b.addContainer(.{ .cell = .{ .head = true, .alignment = .default } }, &.{try str(b, "a")});
            const r1 = try b.addContainer(.{ .row = .{ .head = true } }, &.{c1});
            const c2 = try b.addContainer(.{ .cell = .{ .head = false, .alignment = .default } }, &.{try str(b, "1")});
            const r2 = try b.addContainer(.{ .row = .{ .head = false } }, &.{c2});
            return blockDoc(b, .table, &.{ cap, r1, r2 });
        }
    }.f },
    // The same table with a COLUMN AXIS. Probed separately from `table` so the
    // two claims stay independent: the table survives every target and the
    // column survives none, and a single probe asserting both would pass on the
    // table alone.
    .{ .label = "column", .want = .{ .tag = .column }, .kind = .column, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const col = try b.addContainer(.column, &.{});
            const c = try b.addContainer(.{ .cell = .{ .head = false, .alignment = .default } }, &.{try str(b, "1")});
            const r = try b.addContainer(.{ .row = .{ .head = false } }, &.{c});
            return blockDoc(b, .table, &.{ col, r });
        }
    }.f },
    .{ .label = "footnote", .want = .{ .tag = .footnote }, .kind = .{ .footnote = .{ .label = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "note")});
            const def = try b.addContainer(.{ .footnote = .{ .label = "1" } }, &.{p});
            const ref = try b.addLeaf(.{ .text_leaf = .{ .kind = .footnote_reference, .text = "1" } });
            const body = try b.addContainer(.para, &.{ try str(b, "x"), ref });
            return b.addContainer(.doc, &.{ body, def });
        }
    }.f },
    .{ .label = "reference", .want = .{ .tag = .reference }, .kind = .{ .reference = .{ .label = "", .destination = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const def = try b.addLeaf(.{ .reference = .{ .label = "r", .destination = "/u" } });
            const l = try b.addContainer(.{ .link = .{ .destination = null, .reference = "r" } }, &.{try str(b, "t")});
            const p = try b.addContainer(.para, &.{l});
            return b.addContainer(.doc, &.{ p, def });
        }
    }.f },
    .{ .label = "citation", .want = .{ .tag = .citation }, .kind = .{ .citation = .{ .label = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "Deep Thought.")});
            const def = try b.addContainer(.{ .citation = .{ .label = "CIT2002" } }, &.{p});
            const ref = try b.addLeaf(.{ .text_leaf = .{ .kind = .citation_reference, .text = "CIT2002" } });
            const body = try b.addContainer(.para, &.{ try str(b, "see "), ref });
            return b.addContainer(.doc, &.{ body, def });
        }
    }.f },
    // The one kind every target drops. The body is an inline run, not blocks —
    // that is the shape twig did not have before it (see `Kind.substitution`).
    .{ .label = "substitution", .want = .{ .tag = .substitution }, .kind = .{ .substitution = .{ .label = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const def = try b.addContainer(.{ .substitution = .{ .label = "RST" } }, &.{try str(b, "reStructuredText")});
            const ref = try b.addLeaf(.{ .text_leaf = .{ .kind = .substitution_reference, .text = "RST" } });
            const body = try b.addContainer(.para, &.{ ref, try str(b, " rules") });
            return b.addContainer(.doc, &.{ body, def });
        }
    }.f },
    .{ .label = "container(block)", .want = .{ .container_named = "note" }, .kind = .{ .container = .{ .name = "note", .form = .block_fenced } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            return blockDoc(b, .{ .container = .{ .name = "note", .form = .block_fenced } }, &.{p});
        }
    }.f },
    .{ .label = "container(inline)", .want = .{ .container_named = "span" }, .kind = .{ .container = .{ .name = "span", .form = .inline_text } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return inlineDoc(b, .{ .container = .{ .name = "span", .form = .inline_text } }, &.{try str(b, "x")});
        }
    }.f },
    // The ANONYMOUS container, probed apart from the two named ones because
    // the answer differs by instance rather than by kind: djot's own divs
    // carry no name, so there is nothing for djot to lose and `:::` returns as
    // itself — while the named probes above measure a name djot can only hold
    // as a class. One `.container` row could not have said both.
    .{ .label = "container(anonymous)", .want = .{ .container_named = "" }, .kind = .{ .container = .{ .name = "", .form = .block_fenced } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const p = try b.addContainer(.para, &.{try str(b, "x")});
            return blockDoc(b, .{ .container = .{ .name = "", .form = .block_fenced } }, &.{p});
        }
    }.f },
    .{ .label = "comment", .want = .{ .markup_leaf = .comment }, .kind = .{ .markup_leaf = .{ .kind = .comment, .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .markup_leaf = .{ .kind = .comment, .text = " hi " } }, &.{});
        }
    }.f },
    .{ .label = "doctype", .want = .{ .markup_leaf = .doctype }, .kind = .{ .markup_leaf = .{ .kind = .doctype, .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .markup_leaf = .{ .kind = .doctype, .text = "html" } }, &.{});
        }
    }.f },
    .{ .label = "cdata", .want = .{ .markup_leaf = .cdata }, .kind = .{ .markup_leaf = .{ .kind = .cdata, .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .markup_leaf = .{ .kind = .cdata, .text = "raw" } }, &.{});
        }
    }.f },
    .{ .label = "processing_instruction", .want = .{ .tag = .processing_instruction }, .kind = .{ .processing_instruction = .{ .target = "", .data = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return blockDoc(b, .{ .processing_instruction = .{ .target = "php", .data = "echo" } }, &.{});
        }
    }.f },
    .{ .label = "link", .want = .{ .tag = .link }, .kind = .{ .link = .{ .destination = null, .reference = null } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return inlineDoc(b, .{ .link = .{ .destination = "/u", .reference = null } }, &.{try str(b, "t")});
        }
    }.f },
    .{ .label = "image", .want = .{ .tag = .image }, .kind = .{ .image = .{ .destination = null, .reference = null } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            return inlineDoc(b, .{ .image = .{ .destination = "/u.png", .reference = null } }, &.{try str(b, "alt")});
        }
    }.f },
    .{ .label = "raw_inline", .want = .{ .tag = .raw_inline }, .kind = .{ .raw_inline = .{ .format = "", .text = "" } }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const n = try b.addLeaf(.{ .raw_inline = .{ .format = "html", .text = "<b>" } });
            return b.addContainer(.doc, &.{try b.addContainer(.para, &.{n})});
        }
    }.f },
    .{ .label = "hard_break", .want = .{ .tag = .hard_break }, .kind = .hard_break, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const n = try b.addLeaf(.hard_break);
            const p = try b.addContainer(.para, &.{ try str(b, "a"), n, try str(b, "b") });
            return b.addContainer(.doc, &.{p});
        }
    }.f },
    .{ .label = "non_breaking_space", .want = .{ .tag = .non_breaking_space }, .kind = .non_breaking_space, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const n = try b.addLeaf(.non_breaking_space);
            const p = try b.addContainer(.para, &.{ try str(b, "a"), n, try str(b, "b") });
            return b.addContainer(.doc, &.{p});
        }
    }.f },
    .{ .label = "smart_punctuation", .want = .{ .tag = .smart_punctuation }, .kind = .{ .smart_punctuation = .ellipses }, .build = struct {
        fn f(b: *AST.Builder) anyerror!Node.Id {
            const n = try b.addLeaf(.{ .smart_punctuation = .ellipses });
            return b.addContainer(.doc, &.{try b.addContainer(.para, &.{n})});
        }
    }.f },
};

test "every inline mark and text leaf is probed against the table" {
    const allocator = testing.allocator;
    inline for (comptime std.enums.values(AST.InlineMark)) |m| {
        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const root = try inlineDoc(&b, .{ .inline_mark = m }, &.{try str(&b, "x")});
        var ast = try b.finish(root);
        defer ast.deinit();
        for (round_trippable) |target| {
            const claimed = fidelity(target, .{ .inline_mark = m });
            const observed = try survives(allocator, &ast, target, .{ .mark = m });
            if ((claimed == .faithful) != observed) {
                std.debug.print("\nfidelity({s}, mark {s}) claims .{s}, observed survives={}\n", .{ @tagName(target), @tagName(m), @tagName(claimed), observed });
                return error.FidelityTableStale;
            }
        }
    }

    const leaf_text = std.StaticStringMap([]const u8).initComptime(.{
        .{ "symb", "name" },
        .{ "verbatim", "c" },
        .{ "inline_math", "a+b" },
        .{ "display_math", "a+b" },
        .{ "url", "https://e.com" },
        .{ "email", "a@e.com" },
        .{ "footnote_reference", "1" },
        .{ "citation_reference", "CIT1" },
        .{ "substitution_reference", "RST" },
    });
    inline for (comptime std.enums.values(AST.TextLeafKind)) |k| {
        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const n = try b.addLeaf(.{ .text_leaf = .{ .kind = k, .text = leaf_text.get(@tagName(k)).? } });
        const root = try b.addContainer(.doc, &.{try b.addContainer(.para, &.{n})});
        var ast = try b.finish(root);
        defer ast.deinit();
        for (round_trippable) |target| {
            const claimed = fidelity(target, .{ .text_leaf = .{ .kind = k, .text = "" } });
            const observed = try survives(allocator, &ast, target, .{ .text_leaf = k });
            if ((claimed == .faithful) != observed) {
                std.debug.print("\nfidelity({s}, leaf {s}) claims .{s}, observed survives={}\n", .{ @tagName(target), @tagName(k), @tagName(claimed), observed });
                return error.FidelityTableStale;
            }
        }
    }
}
