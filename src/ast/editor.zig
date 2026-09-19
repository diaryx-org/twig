//! The authoring editor: a `Splicer` that knows how its format is SPELLED.
//!
//! ── The two layers ─────────────────────────────────────────────────────────
//! `Splicer` (`ast/splicer.zig`) is the engine: byte spans in, reparse,
//! rollback, undo. It is language-agnostic by construction and imports no
//! language module — hand it a `parse_fn` and it will edit djot, Markdown or
//! XML with the same code. What it cannot do is decide that bold is spelled
//! `**` here and `*` there.
//!
//! `Editor` is that decision, and nothing else: `Splicer` + a `*const Syntax`.
//! It hosts the gestures a caret editor actually performs — Cmd-B, H1, quote,
//! link — each of which is "consult the table, build the bytes, hand the
//! Splicer one span". The Splicer's invariant survives intact, because `Editor`
//! depends only on the `Syntax` INTERFACE and still names no format: it never
//! learns whether the table it was handed came from djot or Markdown.
//! `format.zig`'s registry is what binds the two.
//!
//! ── Why this exists ────────────────────────────────────────────────────────
//! All of this lived in `c_abi.zig`. Not by design — it accreted there because
//! the C ABI was the first (and only) caller with a caret to serve, and the
//! layer it needed didn't exist. The cost was steep: the knowledge that
//! `mailto:a@b.dev` is a `url` in Markdown but an `email` in djot could only be
//! reached through an `extern` function, could only be tested through a
//! `TwigEditor*` handle and a `TwigStatus` code, and could not be reached by
//! `twig edit` at all.
//!
//! So the C ABI's `TwigEditor` was never `Splicer` — it was always this type,
//! `{ editor, format }`, assembled by hand at the boundary. That is why this
//! module took the `Editor` name and the engine underneath was renamed to what
//! it always was: `TwigEditor` maps to `*Editor`, 1:1, and the ABI's job is
//! back to marshalling.
//!
//! ── Errors ─────────────────────────────────────────────────────────────────
//! Typed, so the ABI's mapping is mechanical and every other caller gets to
//! `switch` on something real. `error.UnsupportedFormat` is uniformly "the
//! `Syntax` table has a `null` where this gesture needed a spelling" — never a
//! hand-written per-format arm. See `syntax.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("ast.zig");
const Document = @import("../document.zig");
const Span = @import("../span.zig");
const locate = @import("locate.zig");
const table_edit = @import("table_edit.zig");
const syntax_mod = @import("../syntax.zig");

pub const Splicer = @import("splicer.zig").Splicer;

/// Used by the free functions below; the public vocabularies all hang off
/// `Editor` itself (`Editor.InlineKind`, `Editor.Error`, ...).
const Syntax = syntax_mod.Syntax;
const ContainerSpelling = syntax_mod.ContainerSpelling;
/// The renderers' types, unwrapped from their optional fields — what a gesture
/// holds once it has dispatched on presence.
const RenderTextFn = @typeInfo(@FieldType(Syntax, "renderText")).optional.child;
const attrs_writer = @import("../attrs_writer.zig");
const RenderBlockFn = @typeInfo(@FieldType(Syntax, "renderBlock")).optional.child;

/// The node `setBlock`'s render path builds for a `BlockKind`.
fn blockNodeKind(kind: syntax_mod.BlockKind, level: u32) AST.Node.Kind {
    return switch (kind) {
        .paragraph => .para,
        .heading => .{ .heading = .{ .level = level } },
    };
}

/// The node an `InlineKind`/`ContainerKind` parses back as. The vocabularies
/// are named for their kinds, so this is a rename, not a mapping — and it fails
/// to compile rather than silently mis-mapping if one drifts.
///
/// It yields an `AST.KindRef` rather than a bare tag because seven of the eight
/// `InlineKind`s are now `InlineMark` family members sharing the `inline_mark`
/// tag; only `verbatim` (a text leaf, not a paired wrapper) is still a tag of
/// its own. The `@hasField` split is resolved at comptime, so a vocabulary
/// entry that matches NEITHER a mark nor a kind tag is still a compile error.
fn kindRef(kind: anytype) AST.KindRef {
    return switch (kind) {
        inline else => |k| if (@hasField(AST.InlineMark, @tagName(k)))
            .{ .mark = @field(AST.InlineMark, @tagName(k)) }
        else if (@hasField(AST.TextLeafKind, @tagName(k)))
            .{ .text_leaf = @field(AST.TextLeafKind, @tagName(k)) }
        else
            .{ .tag = @field(Splicer.KindTag, @tagName(k)) },
    };
}

/// `kindRef` for a vocabulary that is always a plain tag (`ContainerKind`) —
/// asserts that at comptime rather than leaving the caller to unwrap.
fn kindTag(kind: anytype) Splicer.KindTag {
    return switch (kindRef(kind)) {
        .tag => |t| t,
        .text_leaf => unreachable,
        .mark => unreachable,
        .markup_leaf => unreachable,
        // `kindRef` never mints one: it maps a gesture vocabulary, and no
        // gesture names a container by name.
        .container_named => unreachable,
    };
}

/// Room for the widest marker/indent a list can produce (`999. ` and friends).
const container_indent = " " ** 24;

pub const Editor = struct {
    /// The kind vocabularies, re-exported so a caller needs only this type:
    /// `twig.Editor.InlineKind`. (The `Syntax` type itself is `twig.Syntax`.)
    pub const InlineKind = syntax_mod.InlineKind;
    pub const BlockKind = syntax_mod.BlockKind;
    pub const ContainerKind = syntax_mod.ContainerKind;

    pub const Error = error{
        /// `start > end`, or a range reaching past the source.
        InvalidRange,
        /// A heading level outside 1-6.
        InvalidLevel,
        /// A destination this format cannot hold (one containing a newline).
        InvalidDestination,
        /// An info string this format's code fence cannot hold — one carrying a
        /// line end, the fence byte itself, or (where the format ends its info
        /// string at whitespace) a space.
        InvalidLanguage,
        /// A colour name outside `Syntax.MarkColors.colors` — a colour this
        /// format has no spelling for, which is not one an editor may write:
        /// the bytes would be content, not a colour.
        InvalidColor,
        /// A label this format cannot hold. For a footnote: empty, or carrying
        /// a line end or a reference bracket. For a directive: carrying a line
        /// end or a square bracket, either of which closes the `[…]` the label
        /// is written in. An EMPTY directive label is legitimate — `::name[]`
        /// — and is a different document from no label at all, which is
        /// spelled by passing `null`.
        InvalidLabel,
        /// A table shape no pipe format spells: zero columns, or zero body rows
        /// under the header.
        InvalidShape,
        /// A directive name outside the grammar every format reads one back
        /// by: an ASCII letter followed by letters, digits, `-` and `_`. A
        /// name is the whole identity of the node being written — there is no
        /// `::` without one — and it is written where a delimiter would
        /// otherwise be, so anything outside that alphabet reparses as
        /// something else. See `checkDirectiveName`.
        InvalidName,
        /// An attribute no format reads back as one: a key outside the grammar
        /// they share (an ASCII letter or `_`, then letters, digits, `-`, `_`
        /// and `:`), a BARE key with no value (djot's `{…}` has no spelling
        /// for one, so it would come back as text), or a value carrying a
        /// line end or a double quote. See `checkAttr`.
        InvalidAttribute,
        /// The `Syntax` table has no spelling for this gesture in this format.
        UnsupportedFormat,
        /// No block covers the offset/range this gesture needs one for.
        NoBlock,
        /// The target node has no editable span/interior, or the gesture would
        /// corrupt something it refuses to touch.
        NotEditable,
        /// The edit produced a document that no longer parses; it was rolled
        /// back and nothing changed.
        EditConflict,
    } || Allocator.Error;

    splicer: Splicer,
    /// This format's spelling. Borrowed — `format.zig`'s registry entries are
    /// static, so it outlives any editor.
    syntax: *const Syntax,

    /// `parse_ctx`/`parse_fn` are the Splicer's contract (see its doc comment);
    /// `syntax` is the table every gesture below consults. Pair them from
    /// `format.zig`'s registry rather than by hand — an entry's `parseToAst` and
    /// `syntax` are two halves of one language, and crossing them would spell
    /// djot into a Markdown document.
    pub fn init(
        allocator: Allocator,
        source_bytes: []const u8,
        parse_ctx: *const anyopaque,
        parse_fn: Splicer.ParseFn,
        syntax: *const Syntax,
    ) !Editor {
        return .{
            .splicer = try Splicer.init(allocator, source_bytes, parse_ctx, parse_fn),
            .syntax = syntax,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.splicer.deinit();
    }

    pub fn sourceBytes(self: *const Editor) []const u8 {
        return self.splicer.sourceBytes();
    }

    pub fn astView(self: *const Editor) *const AST {
        return self.splicer.astView();
    }

    pub fn lastChange(self: *const Editor) ?Splicer.Change {
        return self.splicer.last_change;
    }

    /// Validate a caller-supplied byte range. `Splicer.replaceAtSpan` ASSERTS on
    /// a bad range — fine for internal callers, but a range from a C caller or a
    /// stale caret is untrusted input, so it is checked into an error here,
    /// once, before any gesture can reach the assert.
    fn checkRange(self: *const Editor, start: usize, end: usize) Error!void {
        if (start > end or end > self.sourceBytes().len) return error.InvalidRange;
    }

    /// Splice rebuilt source in over `[start, end)`. Every gesture ends here.
    fn commitSplice(self: *Editor, start: usize, end: usize, text: []const u8) Error!void {
        self.splicer.replaceAtSpan(Span.init(start, end), text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Anything else is the parser rejecting the edited document; the
            // splicer has already rolled it back.
            else => return error.EditConflict,
        };
    }

    // ── Capability ─────────────────────────────────────────────────────────

    /// One gesture, named with whatever kind it takes — the question
    /// `supports` answers, in the same vocabulary the gesture itself is called
    /// with. A payload here exists exactly where the gesture has a `kind`
    /// parameter, so a caller that can spell the call can spell the query.
    ///
    /// Every gesture `Editor` has appears here, because every gesture now has a
    /// FORMAT-level gate. Nine of them didn't:
    ///
    ///   * The seven TABLE gestures rebuilt a table by writing pipe syntax from
    ///     literals in `table_edit.zig`. HTML's parser lowers `<table>` to the
    ///     same `table`/`row`/`cell` nodes a pipe table produces, so the grid
    ///     extracted cleanly and the pipes were spliced over the elements —
    ///     which reparses as a paragraph, so not even `EditConflict` fired. They
    ///     read `Syntax.table_spelling` now.
    ///   * `splitBlock`'s plain-text arm separated the halves with a blank line,
    ///     which means "two blocks" only where blank lines separate blocks. In
    ///     HTML it is insignificant whitespace inside the `<p>`: one paragraph
    ///     in, one paragraph out, success reported. It reads
    ///     `Syntax.block_separator` now, and `assertCoherent` pins the other two
    ///     spellings it may need (a heading marker, a code fence) non-null
    ///     alongside it, so the answer below stays a total one rather than a
    ///     property of the caret.
    ///   * `renumberOrderedLists` rewrote `N.`/`N)` markers textually, which
    ///     finds nothing in an HTML `<ol>` and reports a successful no-op. It
    ///     gates on the ordered-list container spelling now.
    ///
    /// The table gestures get one variant EACH rather than one shared
    /// `table_edit`, which is the granularity the task and code-block families
    /// already use: they share a gate, and a toolbar still grays out seven
    /// buttons.
    pub const Gesture = union(enum) {
        wrap_range: InlineKind,
        toggle_inline: InlineKind,
        set_mark_color,
        set_block,
        toggle_block_container: ContainerKind,
        insert_thematic_break,
        toggle_code_block,
        set_code_language,
        toggle_task_item,
        set_task_checked,
        toggle_task_checked,
        insert_link,
        insert_image,
        insert_footnote,
        insert_literal,
        insert_line_break,
        split_block,
        join_blocks,
        renumber_ordered_lists,
        table_insert_row,
        table_delete_row,
        table_insert_column,
        table_delete_column,
        table_set_alignment,
        table_move_row,
        table_move_column,
        insert_table,
        insert_directive,
        set_block_attrs,
        wrap_range_attrs,
    };

    /// Whether `syntax` can spell `gesture` — the toolbar's gray-out question,
    /// asked WITHOUT a document, so a caller can build its UI before it has one.
    ///
    /// This is the format half of the answer and only that half. `true` means
    /// the gesture will not fail with `error.UnsupportedFormat`; it says
    /// nothing about the caret, so a supported gesture can still report
    /// `NoBlock`, `NotEditable` or `EditConflict` at the position it is
    /// actually run. Gray out on `false`; do not assume `true` means the call
    /// will succeed.
    ///
    /// Distinct from BOTH neighbouring questions, which are easy to reach for
    /// and wrong here:
    ///
    ///   * `Syntax.authorable()` is "is there a door in" — true for HTML,
    ///     while a task box, a footnote and every table edit over it are
    ///     still unsupported. A toolbar enabled on that predicate has buttons
    ///     that fail.
    ///   * `diagnostics.zig`'s `fidelity` is "what survives a CONVERSION to this
    ///     target", which is a different table with genuinely different answers
    ///     (a smart-quote container is unauthorable in djot yet round-trips
    ///     there perfectly). Use that one for a save-as warning, this one for
    ///     an enabled/disabled button.
    ///
    /// Static — it takes the table rather than an editor — because the whole
    /// point is to answer before an `Editor` exists. `format.zig`'s `syntaxFor`
    /// gets you the table from a `Format`.
    pub fn supports(syntax: *const Syntax, gesture: Gesture) bool {
        return switch (gesture) {
            // The two inline gestures share one gate, and it is
            // `authorableDelimsFor` rather than `delimsFor`: a spelling the
            // serializer may emit but a gesture must not mint (Markdown's
            // `==mark==`) is unsupported HERE while still being written on
            // conversion. That asymmetry is `Delims.authorable`'s reason to
            // exist, so the query has to ask the same way the gesture does.
            .wrap_range, .toggle_inline => |k| syntax.authorableDelimsFor(kindRef(k)) != null,
            // A separate gate from `.toggle_inline = .mark`, and a strictly
            // narrower one: Markdown authors a highlight under
            // `ParseOptions.highlight` and can only COLOUR one under
            // `highlight_colors` on top, so a toolbar grays the palette while
            // the highlight button stays live. `assertCoherent` pins the
            // implication (a palette implies an authorable mark), not the
            // converse.
            .set_mark_color => syntax.mark_colors != null,
            // Either path: a marker alphabet to write, or a fragment renderer
            // to print a fresh node through. Each of these gestures prefers
            // the alphabet and falls back to the renderer, in that order —
            // see `setBlock`, which set the pattern — so a format that has an
            // alphabet keeps its byte-preserving path and a format with none
            // (HTML's tag pairs, AsciiDoc's `dest[text]` link) prints the node.
            .set_block => syntax.heading_marker != null or syntax.renderBlock != null,
            .toggle_block_container => |k| syntax.container_spelling.get(k) != null or syntax.renderBlock != null,
            .insert_thematic_break => syntax.thematic_break != null,
            .toggle_code_block, .set_code_language => syntax.code_fence != null or syntax.renderBlock != null,
            .toggle_task_item, .set_task_checked, .toggle_task_checked => syntax.task_marker != null,
            .insert_link => syntax.link_text_escapes != null or syntax.renderBlock != null,
            // Both halves, as `insertImage` checks them. `assertCoherent` pins
            // them null-together, so this can't disagree with `.insert_link` —
            // it is written out anyway so the query reads as the gesture does.
            .insert_image => (syntax.link_text_escapes != null and syntax.link_dest_escapes != null) or syntax.renderBlock != null,
            .insert_footnote => syntax.footnote != null,
            .insert_literal => syntax.renderText != null,
            .insert_line_break => syntax.cell_line_break != null,
            // A total answer only because `assertCoherent` pins a heading marker
            // and a code fence non-null wherever a block separator is: those are
            // the two spellings `splitBlock` reaches for once it knows which
            // block the caret is in, and without that invariant this row would
            // be true while the gesture reported unsupported in a fence.
            .split_block => syntax.block_separator != null,
            // A WIDER gate than the split's, and the pair is the clearest case
            // in this switch for why each gesture reads its own field: a join
            // writes a line break INSIDE a block, which HTML spells (a newline
            // in a `<p>` is whitespace, and the reparse gives back the one
            // paragraph the gesture claims) while it spells no blank-line
            // block separator at all. Nothing else the gesture needs comes
            // from the table — a heading's marker, the container prefix and
            // the closing markup it carries are all read out of the document —
            // so this row needs no `assertCoherent` implication behind it.
            .join_blocks => syntax.line_join != null,
            .renumber_ordered_lists => spellsOrderedMarkers(syntax),
            .table_insert_row,
            .table_delete_row,
            .table_insert_column,
            .table_delete_column,
            .table_set_alignment,
            .table_move_row,
            .table_move_column,
            .insert_table,
            => syntax.table_spelling != null,
            // Both halves, and neither implies the other here: the renderer is
            // how the bytes are written, and the claim is whether the parser
            // hands them back as the container they were. `assertCoherent`
            // pins the first onto the second, so this cannot answer true with
            // nothing to print through.
            .insert_directive => syntax.names_leaf_containers and syntax.renderBlock != null,
            // The same two halves: a shape the attributes come back in, and
            // the renderer that prints them. `assertCoherent` pins the second
            // onto the first, as for the directive.
            .set_block_attrs => syntax.block_attrs != null and syntax.renderBlock != null,
            .wrap_range_attrs => syntax.inline_attrs and syntax.renderBlock != null,
        };
    }

    /// Whether this format spells an ordered list item as a NUMBERED LINE
    /// MARKER — the one question `renumberOrderedLists` needs answered, and the
    /// expression it and `supports` share so the two cannot drift.
    ///
    /// The renumber pass rewrites the numeric run of a `N.` / `N)` marker in the
    /// source. That is a gesture about a marker, so a spelling is not enough: a
    /// format could spell an ordered list some other way (`ContainerSpelling`
    /// admits a fixed `marker`), and rewriting digits in it would find none and
    /// call the no-op a success — which is precisely what an HTML `<ol>` did
    /// before this gate, where there is no container spelling at all.
    fn spellsOrderedMarkers(syntax: *const Syntax) bool {
        const sp = syntax.container_spelling.get(.ordered_list) orelse return false;
        return sp.numbered;
    }

    // ── Inline marks ───────────────────────────────────────────────────────

    /// Wrap `[start, end)` in `kind`'s delimiters — the unconditional half of
    /// the inline toolbar (always adds a mark). One pair per block the range
    /// touches; see `applyInline`.
    pub fn wrapRange(self: *Editor, span: Span, kind: InlineKind) Error!void {
        return self.applyInline(span, kind, .wrap);
    }

    /// Toggle `kind` over `[start, end)`: strip the mark where the range already
    /// IS a node of `kind` — covers its whole interior and reaches no further
    /// than its delimiters, looking through a mark of another kind that is
    /// nothing but it (`Splicer.inlineNodeCovering`) — else wrap it — a rich
    /// editor's Cmd-B. One decision per block the range touches; see
    /// `applyInline`.
    pub fn toggleInline(self: *Editor, span: Span, kind: InlineKind) Error!void {
        return self.applyInline(span, kind, .toggle);
    }

    /// Whether the gesture may REMOVE a mark it finds, or only ever adds one —
    /// the single difference between `toggleInline` and `wrapRange`, which
    /// otherwise cut the range up and reassemble it identically.
    const InlineMode = enum { wrap, toggle };

    /// One replacement inside the assembled region: `span` goes, and either
    /// `interior` takes its place (a mark being removed) or `span`'s own bytes
    /// come back wrapped in delimiters (a mark being added).
    ///
    /// `interior` aliases the pre-edit source, so an `Edit` is valid only until
    /// the splice that consumes it.
    const Edit = struct { span: Span, interior: ?[]const u8 };

    /// Both inline gestures, in one pass: cut `span` at its block boundaries,
    /// decide per piece, and splice the lot once.
    ///
    /// ── Why per block ──────────────────────────────────────────────────────
    /// A selection is a byte range; a mark is not. Wrapping the range whole put
    /// the opening delimiter in one block and the closing one in the next
    /// (`**one two\n\nthree four**`), which reparses perfectly well as two
    /// paragraphs carrying four literal asterisks — so nothing failed, and the
    /// document simply did not gain the mark the gesture reported writing.
    /// `locate.inlineHostPieces` is where the boundaries come from; the bytes
    /// between the pieces (the blank line, the next block's `- ` or `> `) are
    /// copied through untouched, so what comes out is `**one two**` and
    /// `**three four**` and a document that still says what it said.
    ///
    /// This is what every rich editor does with a multi-block selection, and it
    /// is also what makes the SECOND press work: each piece is decided on its
    /// own, so pressing Cmd-B again over the same selection finds a mark around
    /// each piece and removes both, instead of nesting a second pair around the
    /// first.
    ///
    /// ── Why still ONE splice ───────────────────────────────────────────────
    /// Every gesture here is one `commitSplice`, and that is not a stylistic
    /// preference: a splice is a reparse, an undo step, and a `Splicer.Change`
    /// the host re-anchors its caret against. N pieces spliced separately would
    /// be N reparses, N undo steps to press Cmd-Z through, and N changes whose
    /// offsets each invalidate the next piece's span. So the pieces are decided
    /// against ONE document state, assembled into one buffer, and written once
    /// — the same shape `renumberOrderedLists` uses over a whole list.
    ///
    /// The region that buffer covers is the selection UNION every mark being
    /// removed, because a removal takes its delimiters with it and those sit
    /// outside a selection of the mark's interior (see `Splicer.inlineStrip`).
    /// That is why nothing can be written until every piece has been asked.
    ///
    /// `error.NotEditable` when the range holds no inline host at all — a
    /// selection inside a code block, where `**` would be two asterisks of
    /// someone's program rather than a mark. A code SPAN is the same asterisks
    /// at a smaller scale, and a piece that cuts into one is widened to the
    /// whole of it (`locate.widenOverVerbatim`), so the mark closes around the
    /// backticks. A zero-width range is exempt from the whole business: it
    /// crosses no boundary, and inserting an empty pair for the caret to type
    /// between is a gesture in its own right.
    fn applyInline(self: *Editor, span: Span, kind: InlineKind, mode: InlineMode) Error!void {
        try self.checkRange(span.start, span.end);
        const d = self.syntax.authorableDelimsFor(kindRef(kind)) orelse return error.UnsupportedFormat;
        const allocator = self.splicer.allocator;

        var pieces: std.ArrayList(Span) = .empty;
        defer pieces.deinit(allocator);
        if (span.len() == 0) {
            // A caret spans no block, and clipping it to a host would find a
            // zero-width share and drop it — losing "open a pair here".
            try pieces.append(allocator, span);
        } else {
            try locate.inlineHostPieces(allocator, &self.splicer.doc, span, &pieces);
            if (pieces.items.len == 0) return error.NotEditable;
            // A piece that cuts into a code span widens to the whole of it:
            // `**` inside the backticks is two asterisks of code, so the
            // mark closes around the code instead — `` **`word`** `` from a
            // selection of `word`, which the next press takes off again.
            for (pieces.items) |*p| locate.widenOverVerbatim(&self.splicer.doc, p);
        }

        // Decide everything first: a removal expands its piece to the whole
        // mark, so the region being spliced is not known until the last piece
        // has answered.
        var edits: std.ArrayList(Edit) = .empty;
        defer edits.deinit(allocator);
        var region = span;
        for (pieces.items) |p| {
            // A piece widened over a code span reaches past the selection.
            region.start = @min(region.start, p.start);
            region.end = @max(region.end, p.end);
            const strip = if (mode == .toggle)
                self.splicer.inlineStrip(p, kindRef(kind), d.open, d.close) catch
                    return error.NotEditable
            else
                null;
            if (strip) |s| {
                region.start = @min(region.start, s.span.start);
                region.end = @max(region.end, s.span.end);
                try edits.append(allocator, .{ .span = s.span, .interior = s.interior });
            } else {
                try edits.append(allocator, .{ .span = p, .interior = null });
            }
        }

        const src = self.sourceBytes();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var cursor = region.start;
        for (edits.items) |e| {
            // Ascending and disjoint by construction — one piece per host, and
            // hosts do not overlap — but a removal grows its piece leftward, so
            // refuse rather than slice backwards if that ever stops holding.
            if (e.span.start < cursor) return error.EditConflict;
            try out.appendSlice(allocator, src[cursor..e.span.start]);
            if (e.interior) |interior| {
                try out.appendSlice(allocator, interior);
            } else {
                try out.appendSlice(allocator, d.open);
                try out.appendSlice(allocator, src[e.span.start..e.span.end]);
                try out.appendSlice(allocator, d.close);
            }
            cursor = e.span.end;
        }
        try out.appendSlice(allocator, src[cursor..region.end]);

        return self.commitSplice(region.start, region.end, out.items);
    }

    /// Set — or clear — the COLOUR of the `mark` the caret at `offset` is in:
    /// the second half of an authorable highlight, and the only gesture that
    /// writes a mark's colour rather than its delimiters.
    ///
    /// `color` is a name from `Syntax.MarkColors.colors` (`"red"`), or `null`
    /// to leave the highlight uncoloured. Setting one on a mark that has none
    /// inserts the prefix, setting one on a mark that has another REPLACES it,
    /// and clearing removes it — so the gesture is total over the palette plus
    /// "no colour", the way a colour picker asks it.
    ///
    /// ── Why this is not part of `toggleInline` ─────────────────────────────
    /// A colour is a property of a mark that already exists, and every gesture
    /// here is one splice: giving the toggle a colour parameter would make
    /// "highlight this" and "recolour that" the same call with two different
    /// answers to "what if there is no mark?". Authoring a coloured highlight
    /// from scratch is the two gestures in order — `toggleInline(.mark)`, then
    /// this at any offset inside the new mark, which is `start + open.len` for
    /// a range wrapped at `start`.
    ///
    /// ── What "the prefix" is ───────────────────────────────────────────────
    /// The bytes between the mark's opening delimiter and its content span,
    /// read from the SOURCE rather than from the node's attributes. That keeps
    /// the edit honest about what it is overwriting: a mark whose interior
    /// starts right after its opener has no prefix to replace, one whose
    /// interior starts later has exactly those bytes, and anything there that
    /// the palette does not spell is `error.NotEditable` rather than a splice
    /// that eats a character of the author's text.
    ///
    /// An existing prefix keeps its own SPACING — `==🔴text==` recolours tight,
    /// `==🔴 text==` recolours spaced — because that is spelling the author
    /// chose and the parser preserves. A prefix being written for the first
    /// time gets `MarkColors.space`.
    ///
    /// `error.UnsupportedFormat` where the format (or the parse config behind
    /// this editor — see `format.zig`'s `syntaxForConfig`) spells no colour,
    /// `error.InvalidColor` for a name outside the palette, `error.NotEditable`
    /// when the caret is not inside a mark. Clearing a colour a mark does not
    /// have is a no-op that reports success.
    pub fn setMarkColor(self: *Editor, offset: usize, color: ?[]const u8) Error!void {
        const mc = self.syntax.mark_colors orelse return error.UnsupportedFormat;
        // The mark's own delimiters, which the prefix sits behind. Pinned
        // non-null beside `mark_colors` by `Syntax.assertCoherent`.
        const d = self.syntax.delimsFor(.{ .mark = .mark }).?;
        const new_prefix: ?[]const u8 = if (color) |name|
            (mc.prefixFor(name) orelse return error.InvalidColor)
        else
            null;

        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const doc = &self.splicer.doc;
        const allocator = self.splicer.allocator;

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.caretChain(allocator, doc, offset, &chain);

        // The innermost `mark`, so a highlight nested in emphasis (or in
        // another mark) recolours the one the caret is actually in.
        var found: ?AST.Node.Id = null;
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const kind = doc.ast.nodes[chain.items[i]].kind;
            if (kind == .inline_mark and kind.inline_mark == .mark) {
                found = chain.items[i];
                break;
            }
        }
        const id = found orelse return error.NotEditable;

        const node_span = doc.span(id);
        const cs = doc.contentSpan(id) orelse return error.NotEditable;
        const prefix_start = node_span.start + d.open.len;
        if (prefix_start > cs.start or cs.start > src.len) return error.NotEditable;

        // What is there now, and whether this editor recognizes it. A prefix it
        // cannot read is text as far as it knows, and text is not ours to
        // overwrite.
        const existing = src[prefix_start..cs.start];
        var spaced = false;
        if (existing.len > 0) {
            const c = mc.prefixAt(existing) orelse return error.NotEditable;
            const rest = existing[c.prefix.len..];
            if (std.mem.eql(u8, rest, mc.space)) {
                spaced = true;
            } else if (rest.len != 0) return error.NotEditable;
        }

        const prefix = new_prefix orelse
            // Clearing: the prefix goes, and the space it absorbed goes with it
            // — it was part of the spelling, not of the text.
            return if (existing.len == 0) {} else self.commitSplice(prefix_start, cs.start, "");

        // A first colour is written spaced; a replacement keeps the spacing the
        // source already had.
        const write_space = if (existing.len == 0) true else spaced;
        const buf = try allocator.alloc(u8, prefix.len + if (write_space) mc.space.len else 0);
        defer allocator.free(buf);
        @memcpy(buf[0..prefix.len], prefix);
        if (write_space) @memcpy(buf[prefix.len..], mc.space);
        return self.commitSplice(prefix_start, cs.start, buf);
    }

    // ── Block kind ─────────────────────────────────────────────────────────

    /// Convert the block at `offset` to `kind` (a `level`-N heading, or a
    /// paragraph) by rewriting its leading marker while keeping its inline
    /// content verbatim — the block half of the toolbar (H1 / Body).
    ///
    /// ON A BLANK LINE this OPENS the block instead of converting one, so
    /// "H2, then type" works from an empty line the way it works from a full
    /// one. There is no node there to rewrite — no format spells an empty
    /// paragraph, which is the same gap `splitBlock` documents — so a caller
    /// that could only convert an existing block had to spell `#` itself, and
    /// spell it per format. See `openBlockOnBlankLine`.
    ///
    /// TWO SPELLINGS, tried in this order. Where the format has a
    /// `heading_marker` the block's leading marker is rewritten and its inline
    /// bytes are kept verbatim — a `*em*` stays `*em*`. Where it has none but
    /// carries a `renderBlock`, there is no marker to rewrite (HTML's heading is
    /// a tag PAIR, level in both ends), so the block's inline children are put
    /// under a fresh node of the requested kind and the format prints it — the
    /// same tree, re-spelled, which is why a marker is preferred when there is
    /// one. A format with neither is `error.UnsupportedFormat`.
    pub fn setBlock(self: *Editor, offset: usize, kind: BlockKind, level: u32) Error!void {
        if (self.syntax.heading_marker) |marker| return self.setBlockByMarker(offset, kind, level, marker);
        if (self.syntax.renderBlock) |render| return self.setBlockByRender(offset, kind, level, render);
        return error.UnsupportedFormat;
    }

    /// `setBlock` over a format with a leading heading marker: rewrite it.
    fn setBlockByMarker(self: *Editor, offset: usize, kind: BlockKind, level: u32, marker: u8) Error!void {
        if (kind == .heading and (level < 1 or level > 6)) return error.InvalidLevel;

        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const block = locate.innermostBlock(&self.splicer.doc, offset) orelse
            return self.openBlockOnBlankLine(offset, kind, level, marker);
        const cs = self.splicer.doc.contentSpan(block) orelse return error.NotEditable;
        const content = src[cs.start..cs.end];

        // Rewrite [block start, end-of-text): the leading marker region (a
        // heading) or nothing (a paragraph), plus the text — but NOT any
        // trailing newline the block span includes (Djot blocks do), so we don't
        // fuse with the next block. Rebuilding from `content_span` also
        // collapses a setext heading's underline line away for free.
        const block_span = self.splicer.doc.span(block);
        var end = block_span.end;
        if (end > block_span.start and src[end - 1] == '\n') end -= 1;
        if (end > block_span.start and src[end - 1] == '\r') end -= 1;

        const allocator = self.splicer.allocator;
        const prefix_len: usize = if (kind == .heading) level + 1 else 0; // marker*level + " "
        const buf = try allocator.alloc(u8, prefix_len + content.len);
        defer allocator.free(buf);
        if (kind == .heading) {
            @memset(buf[0..level], marker);
            buf[level] = ' ';
        }
        @memcpy(buf[prefix_len..], content);

        return self.commitSplice(block_span.start, end, buf);
    }

    /// `setBlock` over a format with no leading marker but a fragment
    /// renderer: BUILD the block and let the format print it.
    ///
    /// The block's inline children are cloned under a new `heading`/`para`
    /// node — its attributes ride along, so `<p class="lead">` becomes
    /// `<h2 class="lead">` — and the rendered fragment replaces the block's
    /// whole span. The renderer's trailing line end is dropped because a block
    /// span excludes its own; the reparse is the backstop, as everywhere.
    fn setBlockByRender(
        self: *Editor,
        offset: usize,
        kind: BlockKind,
        level: u32,
        render: RenderBlockFn,
    ) Error!void {
        if (kind == .heading and (level < 1 or level > 6)) return error.InvalidLevel;

        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const doc = &self.splicer.doc;
        const block = locate.innermostBlock(doc, offset) orelse
            return self.openBlockByRender(offset, kind, level, render);

        const allocator = self.splicer.allocator;
        var b = AST.Builder.init(allocator);
        defer b.deinit();
        var kids: std.ArrayList(AST.Node.Id) = .empty;
        defer kids.deinit(allocator);
        var child = doc.ast.nodes[block].first_child;
        while (child) |c| : (child = doc.ast.nodes[c].next_sibling) {
            try kids.append(allocator, try b.graftSubtree(&doc.ast, c));
        }
        const root = try b.addContainer(blockNodeKind(kind, level), kids.items);
        if (doc.ast.nodes[block].attrs) |ai| try b.setAttrs(root, doc.ast.attrs[ai]);

        const block_span = doc.span(block);
        return self.spliceRendered(&b, root, render, block_span.start, block_span.end);
    }

    /// `setBlockByRender` on a BLANK LINE: open an EMPTY block of the requested
    /// kind there. The same guard as `openBlockOnBlankLine` — a blank line
    /// interior to a leaf (a code body, a table) is `error.NotEditable`, and
    /// `.paragraph` is a no-op — but no quote markers to carry and no blank
    /// separation to write: a format that spells a heading as a fragment does
    /// not read line prefixes, so the fragment stands wherever it is spliced.
    fn openBlockByRender(
        self: *Editor,
        offset: usize,
        kind: BlockKind,
        level: u32,
        render: RenderBlockFn,
    ) Error!void {
        const line = try self.blankLineBetweenBlocks(offset);
        if (kind == .paragraph) return;

        var b = AST.Builder.init(self.splicer.allocator);
        defer b.deinit();
        const root = try b.addContainer(blockNodeKind(kind, level), &.{});
        return self.spliceRendered(&b, root, render, line.start, line.end);
    }

    /// Print `root` of `b` through `render` and splice it over `[start, end)`,
    /// minus the line end a block renderer writes after its block — the span
    /// being replaced excludes its own.
    fn spliceRendered(
        self: *Editor,
        b: *const AST.Builder,
        root: AST.Node.Id,
        render: RenderBlockFn,
        start: usize,
        end: usize,
    ) Error!void {
        const view = b.view(root);
        var out: Writer.Allocating = .init(self.splicer.allocator);
        defer out.deinit();
        try renderNode(self.splicer.allocator, render, &view, root, &out.writer);
        const rendered = std.mem.trimEnd(u8, out.written(), "\r\n");
        return self.commitSplice(start, end, rendered);
    }

    /// One node through `render`, with the renderer's errors folded into the
    /// editor's: a refusal to print is a content refusal, not a format one,
    /// since the renderer exists.
    fn renderNode(allocator: Allocator, render: RenderBlockFn, ast: *const AST, id: AST.Node.Id, out: *Writer) Error!void {
        render(allocator, ast, id, out) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            else => return error.NotEditable,
        };
    }

    /// The line the caret is on, when it is a BLANK line lying BETWEEN a
    /// container's children — the place `setBlock` may open a block. The span
    /// is the whole line body, trailing spaces included, so a splice over it
    /// takes them along. `error.NotEditable` for a line with content, or for a
    /// blank line INTERIOR to a leaf; `openBlockOnBlankLine` below makes the
    /// same two tests, with a line prefix in the way, and says why
    /// `locate.isBlockParent` is the hinge.
    fn blankLineBetweenBlocks(self: *const Editor, offset: usize) Error!Span {
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;
        const line_start = locate.lineStartAt(src, offset);
        const body = locate.lineBody(src[line_start..locate.lineEndAt(src, offset)]);
        if (!locate.isBlankLine(body)) return error.NotEditable;
        if (locate.lineOwningBlock(doc, offset)) |lb| {
            if (!locate.isBlockParent(doc.ast.nodes[lb.block].kind)) return error.NotEditable;
        }
        return Span.init(line_start, line_start + body.len);
    }

    /// `setBlock` where there is no block to convert: the caret sits on a BLANK
    /// LINE, so the marker is OPENED rather than rewritten.
    ///
    /// The line's own quote markers are kept and the heading marker written
    /// after them, so an H2 asked for on a quote's blank line lands inside the
    /// quote rather than ending it. They are re-emitted with a SPACE after the
    /// last `>` even when the blank line carries none, because a blank quoted
    /// line is spelled `>` and `>#` is not a quoted heading in both formats:
    /// Markdown reads it as one, djot reads the whole line as a paragraph. The
    /// space is what makes one spelling work in both, the same argument
    /// `Syntax.thematic_break` makes for blank-separating a rule.
    ///
    /// It is BLANK-SEPARATED from whatever precedes it, and that is load-bearing
    /// rather than cosmetic: djot does not let a heading interrupt a paragraph,
    /// so a `## ` written on the line directly under one is read there as the
    /// paragraph's own text — the document gains no heading and the marker shows
    /// up as literal `##`. Markdown reads the same bytes as a heading. Emitting
    /// the blank when the line above is non-blank is what makes one spelling
    /// work in both, the same argument `insertThematicBreak` makes for a rule
    /// and `Syntax.thematic_break` records for `---`.
    ///
    /// The blank carries the line's quote markers, minus the space after them —
    /// a quote's blank line is spelled `>` — so a heading opened on a quote's
    /// blank line stays inside the quote instead of ending it.
    ///
    /// `error.NotEditable` when the blank line is INTERIOR to a block rather
    /// than between blocks — a blank line in a fenced code block, or in a table.
    /// `locate.isBlockParent` is the hinge: a line owned by a container (the
    /// document, a quote, a list item) is a gap between that container's
    /// children and a block may open there, while a line owned by anything else
    /// is inside a leaf whose bytes mean something already. Writing `## ` into a
    /// code body would add no heading and corrupt the listing.
    ///
    /// `.paragraph` is a NO-OP rather than an error: a blank line already holds
    /// no block marker, so the state the caller asked for is the state it is in.
    fn openBlockOnBlankLine(
        self: *Editor,
        offset: usize,
        kind: BlockKind,
        level: u32,
        marker: u8,
    ) Error!void {
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;
        const line_start = locate.lineStartAt(src, offset);
        const body = locate.lineBody(src[line_start..locate.lineEndAt(src, offset)]);

        // Past the line's own quote markers; what remains must be blank, or this
        // is a line with content that simply isn't a `para`/`heading` — a fence
        // line, a table row — and there is nothing here to open.
        var i: usize = 0;
        while (skipQuoteMarker(body, i)) |j| i = j;
        if (!locate.isBlankLine(body[i..])) return error.NotEditable;

        // Interior to a leaf (a code block's body, a table) rather than between
        // a container's children. `innermostBlock` reports `null` for both, and
        // only this tells them apart.
        if (locate.lineOwningBlock(doc, offset)) |lb| {
            if (!locate.isBlockParent(doc.ast.nodes[lb.block].kind)) return error.NotEditable;
        }

        if (kind == .paragraph) return;

        const allocator = self.splicer.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // The line's quote markers, re-emitted with the space djot needs after
        // the last `>` even when the blank line carries none.
        const prefix = body[0..i];
        const needs_space = i > 0 and body[i - 1] == '>';

        // A blank line above, when the previous line has content — see above for
        // why that is correctness rather than tidiness. Inside a quote the blank
        // carries the marker WITHOUT its trailing space, which is how a quote
        // spells a blank line.
        if (precedingLineHasContent(src, line_start)) {
            try out.appendSlice(allocator, std.mem.trimEnd(u8, prefix, " "));
            try out.append(allocator, '\n');
        }

        try out.appendSlice(allocator, prefix);
        if (needs_space) try out.append(allocator, ' ');
        try out.appendNTimes(allocator, marker, level);
        try out.append(allocator, ' ');

        // The whole line body, so a blank line's trailing spaces go with it.
        return self.commitSplice(line_start, line_start + body.len, out.items);
    }

    // ── Block containers (quote / lists) ───────────────────────────────────
    // `setBlock` rewrites the leading marker of ONE block at one offset. A block
    // container is a different animal: it prefixes EVERY line of a possibly
    // multi-block range, it nests, and a list numbers its items — so it gets its
    // own gesture rather than another `BlockKind`. Everything below is line
    // surgery over the covered blocks, spliced in one shot.

    /// Toggle a block container over the blocks `[start, end)` covers.
    ///
    /// The already-in-container test walks the AST ancestors of `start` for a
    /// container of `kind`, and the toggle turns OFF only when the range covers
    /// every block that container holds — otherwise it turns ON, which is what
    /// makes a partial selection inside a quote nest (`> >`) instead of dragging
    /// the container's uncovered siblings out with it. Toggling a list kind
    /// while inside the other list kind converts in place rather than nesting.
    ///
    /// ON A BLANK LINE this OPENS an empty container instead of wrapping one,
    /// `setBlock`'s rule for the same position — see `openContainerOnBlankLine`.
    ///
    /// TWO SPELLINGS, in `setBlock`'s order. Where the format has a
    /// `ContainerSpelling` every line of the range is prefixed and the covered
    /// bytes are kept verbatim. Where it has none but carries a `renderBlock`,
    /// the container is a wrapping pair (`<blockquote>`, `<ul>` with an `<li>`
    /// per item) and the covered blocks are put under a fresh node the format
    /// prints — see `toggleBlockContainerByRender`. A format with neither is
    /// `error.UnsupportedFormat`.
    pub fn toggleBlockContainer(self: *Editor, span: Span, kind: ContainerKind) Error!void {
        try self.checkRange(span.start, span.end);
        const sp = self.syntax.container_spelling.get(kind) orelse {
            if (self.syntax.renderBlock) |render| return self.toggleBlockContainerByRender(span, kind, render);
            return error.UnsupportedFormat;
        };

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const ast = self.astView();

        const blocks = coveredBlocks(allocator, &self.splicer.doc, span.start, span.end) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Nothing to wrap: the caret is on a BLANK LINE, where the gesture
            // opens an empty container rather than failing.
            else => return self.openContainerOnBlankLine(span.start, kind, sp),
        };
        defer allocator.free(blocks.chain);

        const region_start = locate.lineStartAt(src, self.splicer.doc.span(blocks.first).start);
        const region_end = locate.lineEndAt(src, self.splicer.doc.span(blocks.last).end -| 1);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // The toggle-off / convert / nest decision, all from the ancestor chain.
        if (locate.innermostOfKind(&self.splicer.doc, blocks.chain, kindTag(kind))) |target| {
            if (containerFullyCovered(&self.splicer.doc, target, region_start, region_end)) {
                const t = self.splicer.doc.span(target);
                // The container's own lines, not the range's: its span can reach
                // past the last covered block (a quote's trailing `>` line).
                const splice_start = locate.lineStartAt(src, t.start);
                const splice_end = locate.lineEndAt(src, t.end -| 1);
                switch (kind) {
                    .block_quote => try buildQuoteStrip(
                        allocator,
                        src,
                        splice_start,
                        splice_end,
                        quoteDepthAbove(ast, blocks.chain, target),
                        &out,
                    ),
                    .bullet_list, .ordered_list => try buildListRewrite(
                        allocator,
                        src,
                        &self.splicer.doc,
                        target,
                        splice_start,
                        splice_end,
                        null,
                        &out,
                    ),
                }
                return self.commitSplice(splice_start, splice_end, out.items);
            }
        }
        if (kind == .bullet_list or kind == .ordered_list) {
            const other: Splicer.KindTag = if (kind == .bullet_list) .ordered_list else .bullet_list;
            if (locate.innermostOfKind(&self.splicer.doc, blocks.chain, other)) |target| {
                if (containerFullyCovered(&self.splicer.doc, target, region_start, region_end)) {
                    const t = self.splicer.doc.span(target);
                    const splice_start = locate.lineStartAt(src, t.start);
                    const splice_end = locate.lineEndAt(src, t.end -| 1);
                    try buildListRewrite(allocator, src, &self.splicer.doc, target, splice_start, splice_end, sp, &out);
                    return self.commitSplice(splice_start, splice_end, out.items);
                }
            }
        }

        try buildContainerAdd(allocator, src, &self.splicer.doc, blocks, region_start, region_end, sp, &out);
        return self.commitSplice(region_start, region_end, out.items);
    }

    /// `toggleBlockContainer` where there is no block to wrap: the caret sits on
    /// a BLANK LINE, so the container's marker is OPENED on it and the author
    /// types into it — "bullet, then type", which is how a list most often
    /// starts.
    ///
    /// The twin of `openBlockOnBlankLine`, and it has to be: `setBlock` opening
    /// `# ` on a blank line while the quote and list gestures answered
    /// `error.NoBlock` meant a toolbar's H1 button worked on an empty line and
    /// its Quote / Bulleted / Numbered buttons were silent no-ops beside it.
    /// Everything that function reasons about applies unchanged here, so the
    /// shape is deliberately the same one:
    ///
    /// The line's own quote markers are kept and the container's marker written
    /// after them, so a bullet asked for on a quote's blank line lands inside
    /// the quote rather than ending it — re-emitted with a space after the last
    /// `>` even when the blank line carries none, since a blank quoted line is
    /// spelled `>` and `>-` is not a quoted bullet.
    ///
    /// It is BLANK-SEPARATED from whatever precedes it, and here that is
    /// load-bearing in BOTH formats rather than djot alone: an empty list item
    /// cannot interrupt a paragraph, so `- ` written on the line directly under
    /// one is read as that paragraph's own text and the document gains no list
    /// at all. (`> ` can interrupt, so a quote would survive without the blank —
    /// it gets one anyway, because a rule that holds for one of three buttons is
    /// a rule nobody can remember.)
    ///
    /// One thing `openBlockOnBlankLine` needs and this does NOT: a guard against
    /// the blank line being INTERIOR to a leaf (a fenced code block's body, a
    /// table). That function is reached whenever `locate.innermostBlock` finds
    /// nothing, and that is a narrow question — `para`/`heading`, all `setBlock`
    /// rewrites markers for — so a code block's interior lands there and has to
    /// be turned away. This is reached only when `coveredBlocks` finds nothing,
    /// and that is a broad one: a caret anywhere inside a code block resolves to
    /// the code block, which the gesture then wraps whole (`- ```…` over every
    /// line, listing intact). By the time control arrives here the offset is in
    /// no leaf at all, so there is nothing left to refuse.
    ///
    /// It TOGGLES, which is the whole gesture's name and not a bonus: a line
    /// already holding an empty container of `kind` and nothing else has that
    /// marker taken back off, because the press that made it has to un-make it.
    /// Without this, Quote pressed twice on a blank line nested `> > ` and
    /// Bulleted pressed twice failed outright — a button that cannot be
    /// un-pressed until the author types something into it. An empty marker of
    /// the OTHER list kind is CONVERTED, matching what the non-empty path does
    /// for a real list.
    ///
    /// `error.NotEditable` when the line is neither blank nor exactly one empty
    /// marker — content in no block, which no container edit fits.
    fn openContainerOnBlankLine(self: *Editor, offset: usize, kind: ContainerKind, sp: ContainerSpelling) Error!void {
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const line_start = locate.lineStartAt(src, offset);
        const body = locate.lineBody(src[line_start..locate.lineEndAt(src, offset)]);

        // The line's quote markers, and where the INNERMOST one began — the one
        // a Quote press takes back off.
        var quotes_end: usize = 0;
        var last_quote: usize = 0;
        while (skipQuoteMarker(body, quotes_end)) |j| {
            last_quote = quotes_end;
            quotes_end = j;
        }

        const marker = listMarkerAt(body, quotes_end);
        const empty_list = if (marker) |m| locate.isBlankLine(body[m.end..]) else false;
        const blank = locate.isBlankLine(body[quotes_end..]);
        if (!blank and !empty_list) return error.NotEditable;

        // `keep` is the prefix that survives the edit, `write` what follows it.
        // An empty `write` is the toggle-off direction.
        var keep: usize = if (empty_list) marker.?.start else quotes_end;
        var num_buf: [24]u8 = undefined;
        const write: []const u8 = if (kind == .block_quote) blk: {
            // A quote's own marker is what `skipQuoteMarker` has already eaten,
            // so "an empty quote" is a line that is blank once they are all
            // gone. Drop the innermost rather than nesting a second.
            if (blank and quotes_end > 0) {
                keep = last_quote;
                break :blk "";
            }
            break :blk sp.marker;
        } else if (empty_list and isOrderedMarker(body[marker.?.start]) == sp.numbered)
            ""
        else
            listMarker(sp, 1, &num_buf);

        const allocator = self.splicer.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // A blank line above, when the previous line has content — see above for
        // why that is correctness rather than tidiness. Only when OPENING on a
        // blank line: rewriting a marker that is already there needs no
        // separation it does not already have, and adding one would make an
        // enclosing list loose.
        if (write.len > 0 and blank and precedingLineHasContent(src, line_start)) {
            try out.appendSlice(allocator, std.mem.trimEnd(u8, body[0..keep], " "));
            try out.append(allocator, '\n');
        }

        try out.appendSlice(allocator, body[0..keep]);
        // The space djot needs after the last `>` even when the blank line
        // carries none: `>-` is not a quoted bullet in either format.
        if (write.len > 0 and keep > 0 and body[keep - 1] == '>') try out.append(allocator, ' ');
        try out.appendSlice(allocator, write);

        // Toggling off can leave the prefix's own trailing space stranded on an
        // otherwise empty line; a quote's blank line is spelled `>`.
        const tidy = if (write.len == 0) std.mem.trimEnd(u8, out.items, " ") else out.items;

        // The whole line body, so a blank line's trailing spaces go with it.
        return self.commitSplice(line_start, line_start + body.len, tidy);
    }

    /// `toggleBlockContainer` over a format with no line prefix but a
    /// fragment renderer: BUILD the container and let the format print it.
    ///
    /// The same three decisions as the marker path, taken from the tree
    /// rather than from lines — there are no lines to reason about in
    /// `<ul><li>a</li><li>b</li></ul>`, and the parser has already said what
    /// nests in what:
    ///
    ///   * TOGGLE OFF when the range reaches every block a container of `kind`
    ///     holds (`coversContainer`): the container's children — for a list,
    ///     each item's children — are printed in its place. The blocks print
    ///     from the document's own tree, so a paragraph that was a tight
    ///     item's elided `<p>` comes out as a `<p>` again.
    ///   * CONVERT when the range covers the OTHER list kind whole: its items
    ///     are grafted under a fresh list of the requested kind, tightness
    ///     kept, numbering start dropped.
    ///   * WRAP otherwise: the covered blocks go under a `block_quote`, or one
    ///     `list_item` each under a list — TIGHT when every block is a
    ///     paragraph, which is the list the marker path's `- a\n- b` parses
    ///     to. A partial selection inside a container nests, as it does there.
    ///
    /// The splice replaces the covered blocks' own spans (toggle-off and
    /// convert: the container's), minus the line end a block span may carry
    /// after its closing tag, so the fragment lands where the blocks were and
    /// the line structure around them is untouched.
    fn toggleBlockContainerByRender(
        self: *Editor,
        span: Span,
        kind: ContainerKind,
        render: RenderBlockFn,
    ) Error!void {
        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;
        const ast = self.astView();

        const blocks = coveredBlocks(allocator, doc, span.start, span.end) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Nothing to wrap: a blank line, or an empty container — see there.
            else => return self.openContainerByRender(span.start, kind, render),
        };
        defer allocator.free(blocks.chain);

        if (locate.innermostOfKind(doc, blocks.chain, kindTag(kind))) |target| {
            if (coversContainer(ast, target, blocks)) return self.unwrapContainer(target, render);
        }
        if (kind != .block_quote) {
            const other: Splicer.KindTag = if (kind == .bullet_list) .ordered_list else .bullet_list;
            if (locate.innermostOfKind(doc, blocks.chain, other)) |target| {
                if (coversContainer(ast, target, blocks)) {
                    var b = AST.Builder.init(allocator);
                    defer b.deinit();
                    var items: std.ArrayList(AST.Node.Id) = .empty;
                    defer items.deinit(allocator);
                    var item = ast.nodes[target].first_child;
                    while (item) |i| : (item = ast.nodes[i].next_sibling) {
                        try items.append(allocator, try b.graftSubtree(ast, i));
                    }
                    const tight = switch (ast.nodes[target].kind) {
                        .bullet_list => |v| v.tight,
                        .ordered_list => |v| v.tight,
                        else => unreachable,
                    };
                    const root = try b.addContainer(containerNodeKind(kind, tight), items.items);
                    if (ast.nodes[target].attrs) |ai| try b.setAttrs(root, ast.attrs[ai]);
                    const t = doc.span(target);
                    return self.spliceRendered(&b, root, render, t.start, blockSpanEnd(src, t));
                }
            }
        }

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        var kids: std.ArrayList(AST.Node.Id) = .empty;
        defer kids.deinit(allocator);
        var all_paras = true;
        var cur: ?AST.Node.Id = blocks.first;
        while (cur) |c| : (cur = if (c == blocks.last) null else ast.nodes[c].next_sibling) {
            if (ast.nodes[c].kind != .para) all_paras = false;
            const block = try b.graftSubtree(ast, c);
            try kids.append(allocator, if (kind == .block_quote) block else try b.addContainer(.list_item, &.{block}));
        }
        const root = try b.addContainer(containerNodeKind(kind, all_paras), kids.items);
        const first = doc.span(blocks.first);
        const last = doc.span(blocks.last);
        return self.spliceRendered(&b, root, render, first.start, blockSpanEnd(src, last));
    }

    /// `toggleBlockContainerByRender` where `coveredBlocks` found nothing: the
    /// caret is on a BLANK LINE between blocks, or inside an EMPTY container.
    ///
    /// On a blank line an empty container of `kind` is OPENED — over an empty
    /// paragraph, because that is the shape a wrapped paragraph has, so the
    /// press that made it un-makes it through the ordinary toggle-off above
    /// and the author has a block to type into. `blankLineBetweenBlocks` makes
    /// `openBlockByRender`'s guard: a blank line interior to a leaf is
    /// `error.NotEditable`.
    ///
    /// Inside an empty container of `kind` — `<blockquote></blockquote>`, or
    /// an `<li></li>` that is the only item of a list of `kind`, neither of
    /// which this gesture writes but both of which a document may hold — the
    /// container is REMOVED, which is what a toggle owes the press that finds
    /// it. Anything else the caret can be in with no block around it is
    /// `error.NotEditable`.
    fn openContainerByRender(self: *Editor, offset: usize, kind: ContainerKind, render: RenderBlockFn) Error!void {
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const allocator = self.splicer.allocator;
        const doc = &self.splicer.doc;
        const ast = self.astView();

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, offset, &chain);
        if (emptyContainerOf(ast, chain.items, kind)) |empty| {
            const t = doc.span(empty);
            return self.commitSplice(t.start, blockSpanEnd(src, t), "");
        }

        const line = try self.blankLineBetweenBlocks(offset);
        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const para = try b.addContainer(.para, &.{});
        const root = switch (kind) {
            .block_quote => try b.addContainer(.block_quote, &.{para}),
            // Loose, so the empty paragraph is printed as a `<p>` the author can
            // type into rather than elided to nothing.
            .bullet_list, .ordered_list => try b.addContainer(
                containerNodeKind(kind, false),
                &.{try b.addContainer(.list_item, &.{para})},
            ),
        };
        return self.spliceRendered(&b, root, render, line.start, line.end);
    }

    /// Print `target`'s blocks — for a list, each item's blocks — from the
    /// document's own tree and splice them over the container: the render
    /// path's toggle-off.
    fn unwrapContainer(self: *Editor, target: AST.Node.Id, render: RenderBlockFn) Error!void {
        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;
        const ast = self.astView();
        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        const is_list = std.meta.activeTag(ast.nodes[target].kind) != .block_quote;
        var child = ast.nodes[target].first_child;
        while (child) |c| : (child = ast.nodes[c].next_sibling) {
            if (is_list) {
                var block = ast.nodes[c].first_child;
                while (block) |bl| : (block = ast.nodes[bl].next_sibling) {
                    try renderNode(allocator, render, ast, bl, &out.writer);
                }
            } else {
                try renderNode(allocator, render, ast, c, &out.writer);
            }
        }
        const t = doc.span(target);
        return self.commitSplice(t.start, blockSpanEnd(src, t), std.mem.trimEnd(u8, out.written(), "\r\n"));
    }

    /// Renumber the ordered list at `offset` so its markers run `1, 2, 3, …`,
    /// with each nesting level restarting at 1 — the numbering a caret editor
    /// keeps as items are inserted, deleted, and nested, where a plain splice
    /// leaves the source numbers stale (`1. 2. 2. 3.`). A no-op that returns
    /// `error.NoBlock` when `offset` is not inside an ordered list.
    ///
    /// Which lines ARE items comes from the tree; only their LEVEL comes from
    /// indentation. The level is one left-to-right pass with a small stack of
    /// (indent column → next number), so a sub-list restarts and its parent
    /// resumes where it left off — indentation, because a nested list's depth is
    /// what the marker's column says it is, in both formats and at any width.
    /// But whether a `N.`-looking line is an item at all is a question only the
    /// parser can answer: Djot does not let a list marker interrupt a paragraph,
    /// so in `1. a\n   2. b` the second line is not a nested item but literal
    /// text inside item `a`'s paragraph — and a purely textual pass rewrote the
    /// author's own digit there. Markdown reads the same bytes as a sub-list.
    ///
    /// Only the numeric run of a `N.` / `N)` marker is rewritten; its delimiter,
    /// spacing, indentation, and every other (bullet, prose, continuation, blank)
    /// line are copied byte-for-byte.
    ///
    /// `error.UnsupportedFormat` where the format doesn't spell an ordered item
    /// as a numbered line marker (see `spellsOrderedMarkers`). An HTML `<ol>`
    /// parses into the same `ordered_list`/`list_item` nodes a Markdown one
    /// does, so the pass used to run over it, find no `N.` to rewrite, and
    /// report the silent no-op as a success.
    pub fn renumberOrderedLists(self: *Editor, offset: usize) Error!void {
        if (!spellsOrderedMarkers(self.syntax)) return error.UnsupportedFormat;
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const ast = self.astView();
        const allocator = self.splicer.allocator;

        // The OUTERMOST ordered list on the descent to `offset`: renumber the
        // whole nest under it in one pass so its levels stay consistent.
        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        locate.ancestorChain(allocator, &self.splicer.doc, offset, &chain) catch
            return error.OutOfMemory;
        var outer: ?AST.Node.Id = null;
        for (chain.items) |id| {
            if (std.meta.activeTag(ast.nodes[id].kind) == .ordered_list) {
                outer = id;
                break;
            }
        }
        const list = outer orelse return error.NoBlock;

        const region_start = locate.lineStartAt(src, self.splicer.doc.span(list).start);
        const region_end = locate.lineEndAt(src, self.splicer.doc.span(list).end -| 1);

        // The line each item in the region OPENS on, ascending. An item's span
        // may start at its marker (Markdown) or at its text (Djot), but either
        // way it starts on the marker's own line, so the line start identifies it.
        var item_lines: std.ArrayList(usize) = .empty;
        defer item_lines.deinit(allocator);
        for (ast.nodes, 0..) |n, i| {
            switch (std.meta.activeTag(n.kind)) {
                .list_item, .task_list_item => {},
                else => continue,
            }
            const start = self.splicer.doc.span(@intCast(i)).start;
            if (start < region_start or start >= region_end) continue;
            try item_lines.append(allocator, locate.lineStartAt(src, start));
        }
        std.mem.sort(usize, item_lines.items, {}, std.sort.asc(usize));

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try buildRenumber(allocator, src, region_start, region_end, item_lines.items, &out);

        // Identical bytes: don't spend an edit (and an undo step) on a no-op.
        if (std.mem.eql(u8, out.items, src[region_start..region_end])) return;
        return self.commitSplice(region_start, region_end, out.items);
    }

    // ── Thematic break ───────────────────────────────────────────────────────

    /// Insert a thematic break — a horizontal rule — as its own block, on the
    /// line after the block `offset` sits in.
    ///
    /// Decisions:
    ///   * It goes AFTER the caret's block rather than AT the caret. A rule is a
    ///     block, not an inline, so there is no spelling for one in the middle of
    ///     a paragraph; splitting the paragraph in two would be a different
    ///     gesture the caller didn't ask for.
    ///   * It is BLANK-SEPARATED from its neighbours unconditionally, and that is
    ///     load-bearing rather than cosmetic: Markdown reads `---` on the line
    ///     directly under a paragraph as a setext `<h2>` underline, so a rule
    ///     written flush against its predecessor silently becomes a heading and
    ///     eats it. The blank above is what makes one spelling safe in both
    ///     formats. Neither blank is added where the line is already one — the
    ///     one below so repeating the gesture doesn't accumulate them, the one
    ///     above so a caret ON a blank line between two blocks gets a rule with
    ///     one blank each side rather than two above (`a\n\n|\nb` used to give
    ///     `a\n\n\n---\n\nb`). A blank line is a separator, and one is all a
    ///     separator is; the gesture writes what is missing and nothing more.
    ///   * It inherits the caret block's QUOTE PREFIX, so a rule inside a quote
    ///     stays inside it (`> a` gains `>` and `> * * *`, not a rule that ends
    ///     the quote). Only quote markers are reproduced — a list item's indent
    ///     is not — so a rule requested inside a list lands at column zero after
    ///     the caret's ITEM, which SPLITS the list in two with the rule between.
    ///     That is a real document rather than a corrupted one (nothing is
    ///     swallowed and no item loses its marker), and it is the honest reading
    ///     of a rule at column zero, so unlike `toggleCodeBlock` — where the same
    ///     prefix gap would eat the item's marker — it is allowed rather than
    ///     refused.
    ///   * "The caret's block" is `locate.lineOwningBlock`, NOT
    ///     `locate.innermostBlock`. The latter only knows `para`/`heading`, so a
    ///     caret in a CODE BLOCK or a TABLE looked to it like no block at all,
    ///     and the fallback below put the rule at the caret's own line end —
    ///     inside the fence (where `---` is text, so the document gained no rule
    ///     and the code body was corrupted), or between a table's header and its
    ///     delimiter row (which stops it being a table). Losing a node is the
    ///     same failure `toggleCodeBlock` refuses a list for; here it needn't be
    ///     refused, because the rule that governs every other case already says
    ///     where it goes — AFTER the caret's block, the fence and the table
    ///     included.
    ///
    /// `error.UnsupportedFormat` when the format has no thematic break. There is
    /// no `error.NoBlock`: an empty document is a legitimate place for a rule, and
    /// with no block to sit after it goes at the caret's line — ON that line
    /// when it is blank, since a blank line is where a block goes, after it
    /// otherwise.
    pub fn insertThematicBreak(self: *Editor, offset: usize) Error!void {
        const rule = self.syntax.thematic_break orelse return error.UnsupportedFormat;
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const allocator = self.splicer.allocator;

        const line = try std.mem.concat(allocator, u8, &.{ rule, "\n" });
        defer allocator.free(line);
        return self.insertBlockAfter(offset, line);
    }

    /// Insert a fresh table — one header row, `rows` body rows, `cols` columns,
    /// every cell empty — as its own block after the block `offset` sits in.
    ///
    /// The placement is `insertThematicBreak`'s, decision for decision: after
    /// the caret's block rather than at the caret, blank-separated on both
    /// sides, carrying a quote's prefix on every line and landing at column
    /// zero after a list item. The blank above is load-bearing here for the
    /// same reason it is for the rule: GFM lets a table's header row be read
    /// out of the paragraph it follows, so a table written flush under prose
    /// can take the paragraph's last line as its header.
    ///
    /// The bytes are the format's own `TableSpelling`, emitted by
    /// `table_edit.emit` over a `table_edit.blank` grid — the same path every
    /// table edit re-spells through, so a table this mints is one those edits
    /// can read back. The header row is not optional, because neither pipe
    /// format has a table without one; `error.InvalidShape` for zero columns
    /// or zero body rows, the shape `tableDeleteRow` and `tableDeleteColumn`
    /// refuse to leave behind. `error.UnsupportedFormat` where the format has
    /// no table spelling, before anything is read.
    pub fn insertTable(self: *Editor, offset: usize, rows: usize, cols: usize) Error!void {
        const spelling = self.syntax.table_spelling orelse return error.UnsupportedFormat;
        if (offset > self.sourceBytes().len) return error.InvalidRange;
        if (rows == 0 or cols == 0) return error.InvalidShape;
        const allocator = self.splicer.allocator;

        var grid = table_edit.blank(allocator, cols, rows) catch |e| return mapTableErr(e);
        defer grid.deinit();
        const bytes = table_edit.emit(allocator, &grid, spelling) catch |e| return mapTableErr(e);
        defer allocator.free(bytes);
        return self.insertBlockAfter(offset, bytes);
    }

    /// Insert a LEAF DIRECTIVE — Markdown's `::name[label]{attrs}` — as its own
    /// block after the block `offset` sits in.
    ///
    /// What a name MEANS is the host application's, not twig's: this writes a
    /// named `container` with `form = .block_leaf` and asks the format to
    /// spell it. A rich-text editor's page break is `insertDirective(off,
    /// "page-break", null, &.{})`, and the same call with `"embed"` and a
    /// `src` is an embed — twig has no vocabulary of directive names and reads
    /// none back.
    ///
    /// The placement is `insertThematicBreak`'s, decision for decision, shared
    /// with it and `insertTable` as `insertBlockAfter`: after the caret's
    /// block rather than at the caret, blank-separated on both sides, a
    /// quote's prefix on every line — djot's two-line fence included — and
    /// column zero after a list item.
    ///
    /// The bytes are the format's own, through the FRAGMENT RENDERER: the node
    /// is built with `AST.Builder`, `label` becomes its single inline child
    /// (which is what the `[label]` brackets print from), `attrs` are set on
    /// it, and `Syntax.renderBlock` spells the result. So the spelling is the
    /// serializer's — `::name` in Markdown, an empty `::: name` fence in djot,
    /// `<name></name>` in HTML — and stays that way when a serializer's does.
    ///
    /// Gated on `Syntax.names_leaf_containers`, which is the narrower question
    /// than "can this format print one": every format with a renderer prints
    /// SOMETHING for a named leaf, and the gate asks whether the parser hands
    /// that back as a container carrying the name. In Markdown the answer is
    /// the parse config's — `::name` is a paragraph of colons without
    /// `ParseOptions.directives` — so an editor over a document parsed without
    /// the extension gets `error.UnsupportedFormat` here, exactly as
    /// `setMarkColor` does without `highlight_colors`.
    ///
    /// `error.InvalidName` for a name outside `checkDirectiveName`'s grammar —
    /// an ASCII letter then letters, digits, `-` and `_` — which is checked
    /// here rather than per format because a name is written where a delimiter
    /// would otherwise be, and anything else reparses as something other than
    /// the container it was meant to be. `error.InvalidLabel` for a label
    /// carrying a line end or a square bracket, either of which closes the
    /// `[…]` early. `error.InvalidRange` for an `offset` past the source.
    /// There is no `error.NoBlock` — an empty document is a legitimate place
    /// for one, as it is for a rule.
    pub fn insertDirective(
        self: *Editor,
        offset: usize,
        name: []const u8,
        label: ?[]const u8,
        attrs: []const AST.KeyVal,
    ) Error!void {
        if (!self.syntax.names_leaf_containers) return error.UnsupportedFormat;
        // `assertCoherent` pins this non-null wherever the claim above is
        // made, so the `orelse` is the compiler's requirement rather than a
        // second gate; `supports` states both halves for the same reason.
        const render = self.syntax.renderBlock orelse return error.UnsupportedFormat;
        if (offset > self.sourceBytes().len) return error.InvalidRange;
        try checkDirectiveName(name);
        // A label is written inside `[…]`, so a bracket closes it early and
        // the tail becomes ordinary text beside the directive — the same
        // reasoning `insertFootnote` applies to its own reference brackets.
        if (label) |l| {
            if (std.mem.indexOfAny(u8, l, "\r\n[]") != null) return error.InvalidLabel;
        }
        const allocator = self.splicer.allocator;

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        // A label is the container's INLINE CHILDREN, which is where every
        // serializer looks for it: Markdown prints `[` … `]` around them and
        // writes nothing at all when there are none, so "no label" is an
        // absent child rather than an empty one.
        var child: [1]AST.Node.Id = undefined;
        var children: []const AST.Node.Id = child[0..0];
        if (label) |l| {
            child[0] = try b.addLeaf(.{ .str = l });
            children = child[0..1];
        }
        const root = try b.addContainer(
            .{ .container = .{ .name = name, .form = .block_leaf } },
            children,
        );
        if (attrs.len != 0) try b.setAttrs(root, .{ .entries = attrs });

        const view = b.view(root);
        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        try renderNode(allocator, render, &view, root, &out.writer);
        // No trim here, unlike `spliceRendered`: `insertBlockAfter`
        // re-terminates every line itself and trims the renderer's trailing
        // newline on the way in.
        return self.insertBlockAfter(offset, out.written());
    }

    /// Write `body` — one or more `\n`-terminated lines — as a block of its
    /// own after the block `offset` sits in: the shared placement behind
    /// `insertThematicBreak`, `insertTable` and `insertDirective`, whose doc
    /// comments own the reasoning for each decision made here.
    fn insertBlockAfter(self: *Editor, offset: usize, body: []const u8) Error!void {
        const src = self.sourceBytes();
        const allocator = self.splicer.allocator;

        const block = if (locate.lineOwningBlock(&self.splicer.doc, offset)) |lb| lb.block else null;
        // With no block to sit after, the caret's own line is the anchor: a
        // BLANK one is a separator the block can take the place of — written at
        // its start, the blank becomes the separator below — where writing after
        // it would step past a blank only to add another above.
        const line_start = locate.lineStartAt(src, offset);
        const on_blank = block == null and
            locate.isBlankLine(locate.lineBody(src[line_start..locate.lineEndAt(src, offset)]));
        const pos = if (on_blank)
            line_start
        else
            locate.lineEndAt(src, if (block) |b| self.splicer.doc.span(b).end -| 1 else offset);
        const prefix = if (block) |b| containerPrefix(src, self.splicer.doc.span(b).start) else "";
        // A quote's blank line carries its marker but not the space after it —
        // the same rule `ContainerSpelling.blank` states for the toggle.
        const blank = std.mem.trimEnd(u8, prefix, " ");

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        if (pos > 0) {
            // An unterminated last line is ended first, or the "blank" written
            // next is not a blank line but that line's own newline, and the
            // block lands flush under the paragraph — `a\n---\n`, the setext
            // heading the blank exists to prevent.
            if (src[pos - 1] != '\n') try out.append(allocator, '\n');
            // The blank above, unless the line above already is one — the
            // mirror of the rule below.
            const above = src[locate.lineStartAt(src, pos - 1)..pos];
            if (!locate.isBlankLine(locate.lineBody(above))) {
                try out.appendSlice(allocator, blank);
                try out.append(allocator, '\n');
            }
        }
        // Every line of the block takes the prefix, not just its first: a
        // quote's marker is on each line it covers.
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
        while (lines.next()) |l| {
            try out.appendSlice(allocator, prefix);
            try out.appendSlice(allocator, l);
            try out.append(allocator, '\n');
        }
        if (pos < src.len and !locate.isBlankLine(locate.lineBody(src[pos..locate.lineEndAt(src, pos)]))) {
            try out.appendSlice(allocator, blank);
            try out.append(allocator, '\n');
        }

        return self.commitSplice(pos, pos, out.items);
    }

    // ── Block attributes ───────────────────────────────────────────────────

    /// Replace the attribute set of the block `offset` sits in — a paragraph
    /// or heading, the block `setBlock` rewrites — with `attrs`. REPLACE, not
    /// merge: a caller reads the node's attributes, edits the list and passes
    /// it back whole, which is the contract `Builder.setAttrs` and the C ABI's
    /// `twig_builder_set_attrs` already have, and an empty list clears them.
    ///
    /// What a key MEANS is the host's, not twig's — this is `insertDirective`'s
    /// rule applied to a block's presentation: a rich-text editor's centred
    /// paragraph is `setBlockAttrs(off, &.{.{ .key = "class", .value =
    /// "center" }})`, and twig spells the pair and interprets neither half.
    /// See `docs/proposals/presentation-as-attributes.md`.
    ///
    /// THREE SPELLINGS, chosen by `Syntax.block_attrs` and the table's fields:
    ///
    ///   * `native` with an `attr_spelling` — djot: the format spells a
    ///     block's attributes on the line BEFORE it, and the document recorded
    ///     where (`Document.attrsSpan`). That line is rewritten, inserted with
    ///     the block's own quote prefix, or removed, and the block's bytes are
    ///     not touched. The alphabet path, preferred for the reason `setBlock`
    ///     prefers a marker.
    ///   * `native` otherwise — HTML's tag, AsciiDoc's `[…]` line: the block
    ///     is rebuilt with the new set and printed through `renderBlock`, as
    ///     `setBlockByRender` prints a heading, so its bytes are re-spelled by
    ///     the format.
    ///   * `wrapped` — Markdown under `html_elements`: the block is printed
    ///     inside a container the format spells as `<div …>` around it. When
    ///     the block is already the SOLE CHILD of such a wrapper, the wrapper's
    ///     attributes are replaced instead of a second one nesting, and an
    ///     empty set unwraps it — the rule `insertLink` applies to a link
    ///     covering the range, for the same reason.
    ///
    /// `error.UnsupportedFormat` where the table makes no claim, before
    /// anything is read. `error.NoBlock` when no paragraph or heading holds
    /// `offset`; `error.InvalidRange` for an offset past the source;
    /// `error.InvalidAttribute` for a key or value no format reads back (see
    /// `checkAttr`). `error.NotEditable` where the alphabet path cannot place
    /// the line — a block that starts on a list item's marker line — or where
    /// the document's attributes came from more than one `{…}` block and no
    /// single span describes them, and where the wrap path would need a list
    /// item's continuation indent it cannot reproduce.
    pub fn setBlockAttrs(self: *Editor, offset: usize, attrs: []const AST.KeyVal) Error!void {
        const shape = self.syntax.block_attrs orelse return error.UnsupportedFormat;
        // `assertCoherent` pins this non-null wherever the claim above is
        // made, so the `orelse` is the compiler's requirement.
        const render = self.syntax.renderBlock orelse return error.UnsupportedFormat;
        if (offset > self.sourceBytes().len) return error.InvalidRange;
        for (attrs) |kv| try checkAttr(kv);
        const block = locate.innermostBlock(&self.splicer.doc, offset) orelse return error.NoBlock;
        return switch (shape) {
            .native => if (self.syntax.attr_spelling) |sp|
                self.setBlockAttrsByLine(block, attrs, sp)
            else
                self.setNodeAttrsByRender(block, attrs, render),
            .wrapped => self.setBlockAttrsByWrap(block, attrs, render),
        };
    }

    /// `setBlockAttrs` where the format spells a block's attributes as a line
    /// before it: rewrite that line in place.
    fn setBlockAttrsByLine(self: *Editor, block: AST.Node.Id, attrs: []const AST.KeyVal, sp: syntax_mod.AttrSpelling) Error!void {
        const doc = &self.splicer.doc;
        const src = self.sourceBytes();
        const allocator = self.splicer.allocator;
        const existing = doc.attrsSpan(block);
        // Attributes the node has but no single span describes — djot merges
        // consecutive `{…}` blocks into one set — are not ours to rewrite: a
        // new line would sit beside the old ones.
        if (existing == null and !doc.ast.attrsOf(block).isEmpty()) return error.NotEditable;

        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        if (attrs.len != 0) attrs_writer.write(&out.writer, .{ .entries = attrs }, sp, "") catch return error.OutOfMemory;

        if (existing) |es| {
            if (attrs.len != 0) return self.commitSplice(es.start, es.end, out.written());
            // Clearing takes the whole line when the block was alone on it —
            // a quote's marker at most beside it — so no blank line is left
            // where the attributes were.
            const ls = locate.lineStartAt(src, es.start);
            const le = locate.lineEndAt(src, es.end); // past the newline
            const prefix = containerPrefix(src, es.start);
            const before = src[ls..es.start];
            const alone = std.mem.startsWith(u8, before, prefix) and
                locate.isBlankLine(before[prefix.len..]) and
                locate.isBlankLine(locate.lineBody(src[es.end..le]));
            if (!alone) return self.commitSplice(es.start, es.end, "");
            return self.commitSplice(ls, le, "");
        }
        if (attrs.len == 0) return;
        // A fresh line above the block, carrying the block's own quote
        // prefix. A block that starts on a list item's marker line has no
        // line above it that is its own — the marker is there — so that is
        // refused rather than written before the marker, where it would be
        // the list's.
        const bs = doc.span(block).start;
        const ls = locate.lineStartAt(src, bs);
        const prefix = containerPrefix(src, bs);
        const content_start = @max(bs, ls + prefix.len);
        if (!locate.isBlankLine(src[ls + prefix.len .. content_start])) return error.NotEditable;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, prefix);
        try line.appendSlice(allocator, out.written());
        try line.append(allocator, '\n');
        return self.commitSplice(ls, ls, line.items);
    }

    /// `setBlockAttrs` over a format whose attributes live on the block's own
    /// spelling and which has no line to rewrite: rebuild the block with the
    /// new set and print it, `setBlockByRender`'s path with the kind kept.
    fn setNodeAttrsByRender(self: *Editor, block: AST.Node.Id, attrs: []const AST.KeyVal, render: RenderBlockFn) Error!void {
        const doc = &self.splicer.doc;
        const allocator = self.splicer.allocator;
        var b = AST.Builder.init(allocator);
        defer b.deinit();
        var kids: std.ArrayList(AST.Node.Id) = .empty;
        defer kids.deinit(allocator);
        var child = doc.ast.nodes[block].first_child;
        while (child) |c| : (child = doc.ast.nodes[c].next_sibling) {
            try kids.append(allocator, try b.graftSubtree(&doc.ast, c));
        }
        const root = try b.addContainer(doc.ast.nodes[block].kind, kids.items);
        if (attrs.len != 0) try b.setAttrs(root, .{ .entries = attrs });
        const span = doc.span(block);
        return self.spliceRendered(&b, root, render, span.start, span.end);
    }

    /// `setBlockAttrs` where the attributes come back on a container around
    /// the block — Markdown's `<div>`: print the block inside one, or rewrite
    /// the one it is already the sole child of.
    fn setBlockAttrsByWrap(self: *Editor, block: AST.Node.Id, attrs: []const AST.KeyVal, render: RenderBlockFn) Error!void {
        const doc = &self.splicer.doc;
        const ast = &doc.ast;
        const allocator = self.splicer.allocator;
        const block_span = doc.span(block);

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, block_span.start, &chain);
        // The wrapper: the block's parent when that is a div — a fenced
        // container that is anonymous or named `div`, and not one the parser
        // read as a directive — with the block as its only child.
        var wrapper: ?AST.Node.Id = null;
        for (chain.items, 0..) |id, i| {
            if (id != block or i == 0) continue;
            const parent = chain.items[i - 1];
            const c = switch (ast.nodes[parent].kind) {
                .container => |c| c,
                else => break,
            };
            if (c.form != .block_fenced) break;
            if (c.name.len != 0 and !std.mem.eql(u8, c.name, "div")) break;
            if (c.name.len != 0 and doc.containerOrigin(parent) == .directive) break;
            if (ast.nodes[parent].first_child != block or ast.nodes[block].next_sibling != null) break;
            wrapper = parent;
            break;
        }
        // The printed lines take the block's quote prefix; a list item's
        // continuation indent is not one `containerPrefix` reproduces.
        if (insideListItem(doc, chain.items)) return error.NotEditable;

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const grafted = try b.graftSubtree(ast, block);
        const target = if (wrapper) |w| doc.span(w) else block_span;
        if (attrs.len == 0) {
            // Nothing to wrap in: the block alone, over the wrapper if any.
            if (wrapper == null) return;
            return self.spliceRenderedPrefixed(&b, grafted, render, target);
        }
        const root = try b.addContainer(.{ .container = .{ .name = "div", .form = .block_fenced } }, &.{grafted});
        try b.setAttrs(root, .{ .entries = attrs });
        return self.spliceRenderedPrefixed(&b, root, render, target);
    }

    /// Wrap `[start, end)` in an anonymous inline container carrying `attrs`
    /// — djot's `[text]{…}`, HTML's and Markdown's `<span …>` — or, when the
    /// range lies inside one already, REPLACE that container's attributes
    /// instead of nesting a second; an empty set there unwraps it. That is the
    /// rule `insertLink` applies to a link covering the range, for the same
    /// reason: re-styling is the common gesture, and it must not build
    /// `[[text]{.a}]{.b}`. An anonymous span and one named `span` are the
    /// same node here — HTML and Markdown hand the name back, djot does not —
    /// and a `:span[…]` the Markdown parser read as a directive is neither.
    ///
    /// The inline half of `setBlockAttrs`, with the same vocabulary rule: twig
    /// spells the pairs and interprets none. The bytes are the format's,
    /// through `renderBlock` over the container — the covered inline nodes
    /// grafted under it as `insertLinkByRender` grafts them under a link — so
    /// a mark inside the range rides along. Unwrapping splices the node's
    /// CONTENT bytes over the node, which needs no renderer and keeps them.
    ///
    /// `error.UnsupportedFormat` where `Syntax.inline_attrs` is not claimed —
    /// AsciiDoc, whose `[#id.role]#text#` keeps two keys and drops a third,
    /// and Markdown without `html_elements`; `error.InvalidRange` for a bad
    /// range; `error.InvalidAttribute` as `setBlockAttrs`; `error.NotEditable`
    /// for an empty range with no span to re-style, or a range that cuts a
    /// node it cannot slice (see `coveredInlines`).
    pub fn wrapRangeAttrs(self: *Editor, span: Span, attrs: []const AST.KeyVal) Error!void {
        if (!self.syntax.inline_attrs) return error.UnsupportedFormat;
        const render = self.syntax.renderBlock orelse return error.UnsupportedFormat;
        try self.checkRange(span.start, span.end);
        for (attrs) |kv| try checkAttr(kv);
        const doc = &self.splicer.doc;
        const ast = self.astView();
        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, span.start, &chain);
        // The innermost attributed span covering the range.
        var existing: ?AST.Node.Id = null;
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const id = chain.items[i];
            const c = switch (ast.nodes[id].kind) {
                .container => |c| c,
                else => continue,
            };
            if (c.form != .inline_text) continue;
            if (c.name.len != 0 and !std.mem.eql(u8, c.name, "span")) continue;
            // djot's own span is anonymous and, being lightweight markup,
            // carries the `directive` origin too; the one to leave alone is a
            // NAMED span with it — Markdown's `:span[…]` directive.
            if (c.name.len != 0 and doc.containerOrigin(id) == .directive) continue;
            const sp = doc.span(id);
            if (sp.start <= span.start and sp.end >= span.end) {
                existing = id;
                break;
            }
        }

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        var kids: std.ArrayList(AST.Node.Id) = .empty;
        defer kids.deinit(allocator);
        var target = span;
        if (existing) |id| {
            target = doc.span(id);
            if (target.start == 0 and target.end == 0) return error.NotEditable;
            // djot's `{…}` follows the brackets OUTSIDE the node's span, and
            // the document recorded where; a set merged from several blocks
            // has no single span and is not ours to rewrite. HTML's and
            // Markdown's attributes sit inside the tag, inside the span — the
            // formats whose `block_attrs` path is the line rewrite are the
            // ones whose attributes lie outside, as `setBlockAttrs` reads it.
            if (doc.attrsSpan(id)) |as| {
                target = Span.init(@min(target.start, as.start), @max(target.end, as.end));
            } else if (self.syntax.block_attrs == .native and self.syntax.attr_spelling != null and !ast.attrsOf(id).isEmpty()) {
                return error.NotEditable;
            }
            if (attrs.len == 0) {
                const cs = doc.contentSpan(id) orelse return error.NotEditable;
                return self.commitSplice(target.start, target.end, src[cs.start..cs.end]);
            }
            var child = ast.nodes[id].first_child;
            while (child) |c| : (child = ast.nodes[c].next_sibling) {
                try kids.append(allocator, try b.graftSubtree(ast, c));
            }
        } else {
            if (attrs.len == 0) return;
            if (span.end == span.start) return error.NotEditable;
            const covered = try coveredInlines(allocator, doc, span.start, span.end);
            defer allocator.free(covered);
            for (covered) |piece| {
                try kids.append(allocator, if (piece.text) |t|
                    try b.addLeaf(.{ .str = t })
                else
                    try b.graftSubtree(ast, piece.node));
            }
        }
        const root = try b.addContainer(.{ .container = .{ .name = "", .form = .inline_text } }, kids.items);
        try b.setAttrs(root, .{ .entries = attrs });
        return self.spliceRendered(&b, root, render, target.start, target.end);
    }

    /// `spliceRendered` for a fragment of several lines going into a quote:
    /// every line after the first takes the quote prefix the first already
    /// sits behind, a blank line its marker alone.
    fn spliceRenderedPrefixed(self: *Editor, b: *const AST.Builder, root: AST.Node.Id, render: RenderBlockFn, target: Span) Error!void {
        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const prefix = containerPrefix(src, target.start);
        const blank = std.mem.trimEnd(u8, prefix, " ");
        // A Markdown block's span starts at column zero, quote marker
        // included; the first printed line goes after that marker, which is
        // then the prefix every later line copies.
        const start = @max(target.start, locate.lineStartAt(src, target.start) + prefix.len);
        const view = b.view(root);
        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        try renderNode(allocator, render, &view, root, &out.writer);
        const rendered = std.mem.trimEnd(u8, out.written(), "\r\n");
        if (prefix.len == 0) return self.commitSplice(start, target.end, rendered);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        var lines = std.mem.splitScalar(u8, rendered, '\n');
        var first = true;
        while (lines.next()) |l| {
            if (!first) {
                try text.append(allocator, '\n');
                try text.appendSlice(allocator, if (l.len == 0) blank else prefix);
            }
            first = false;
            try text.appendSlice(allocator, l);
        }
        return self.commitSplice(start, target.end, text.items);
    }

    // ── Splitting a block ────────────────────────────────────────────────────

    /// Split the block at `offset` in two AT THE CARET, both halves the SAME
    /// KIND — Enter in the middle of a paragraph, and the gesture
    /// `insertThematicBreak` deliberately isn't.
    ///
    /// Nearly a pure INSERTION at `offset`: what is minted is the separator
    /// between the halves, and the only bytes REMOVED are the second half's
    /// leading spaces and tabs. Those are structure rather than content at the
    /// start of a block — a split at `- b| c` that kept its space would write
    /// `-  c`, setting that item's content indent to three. A code block sheds
    /// nothing, because there leading whitespace IS the content. What the
    /// separator is, is the only other thing that varies:
    ///
    ///   * A PARAGRAPH gets a blank line — `ab` -> `a`/`b`. Inside a quote the
    ///     blank carries the quote's marker and the second half its full prefix
    ///     (`> ab` -> `> a`/`>`/`> b`), so the split happens INSIDE the quote
    ///     rather than ending it.
    ///   * A paragraph in a LIST ITEM gets the item's MARKER instead of a blank,
    ///     so the second half is a sibling item and not a paragraph that ends
    ///     the list: `- this is |a list item` -> `- this is `/`- a list item`.
    ///     The marker is repeated VERBATIM, ordered numbers included, so a split
    ///     `1.` item yields two `1.` items — both formats renumber on render,
    ///     and `renumberOrderedLists` is the gesture for fixing the source when
    ///     the caller wants it fixed. A TASK item's new half is an UNCHECKED
    ///     box regardless of the original's state: splitting one done thing in
    ///     two does not make the remainder done. The marker is taken from the
    ///     END OF ANY QUOTE PREFIX rather than from the bullet, so a NESTED
    ///     item's indent rides along with it and the new sibling stays in its
    ///     own list instead of dropping to column zero and joining the
    ///     enclosing one.
    ///   * A HEADING repeats its own marker at its own level, because both
    ///     halves being the same kind is what "split" means here; `setBlock` is
    ///     how the caller demotes the second half if that is what they wanted.
    ///   * A CODE BLOCK becomes two code blocks — the first closed with a fence,
    ///     the second reopened with the opening fence line REPRODUCED VERBATIM,
    ///     so its width and its info string both survive. Splitting code is a
    ///     real request (one listing becoming two), and a consumer that doesn't
    ///     want the gesture live there can ask the tree what kind of block the
    ///     caret is in before offering it.
    ///
    /// AT A BLOCK BOUNDARY this still splits, which is what makes it Enter: at
    /// the end of a list item it opens an EMPTY sibling item (`- a|` -> `- a`/
    /// `- `), which is exactly the empty block the caller wants to type into.
    /// The paragraph case is the one place the "empty block" is unrepresentable
    /// — no format spells an empty paragraph — so `a|` gains a trailing blank
    /// line and reparses as ONE paragraph. The caret is where the next one will
    /// begin; the node appears when there is text to hold.
    ///
    /// `error.NotEditable` for the blocks where a caret-split has no honest
    /// meaning:
    ///   * A TABLE, whose structure is rows and cells rather than lines — a
    ///     newline mid-cell doesn't divide a table, it destroys one. Splitting a
    ///     table INTO TWO TABLES is a real gesture, but it is a table gesture
    ///     (it has to decide what the second table's header is), not this one.
    ///   * A SETEXT heading, whose `---` underline belongs to a block that would
    ///     no longer be under it. `setBlock` normalises one to ATX, which makes
    ///     this work; doing that silently here would rewrite the half the caller
    ///     didn't touch.
    ///   * An INDENTED code block, where a blank line is interior rather than a
    ///     separator, so the "split" would parse back as one block.
    ///
    /// `error.NoBlock` when nothing covers `offset` — an empty document has no
    /// block to divide.
    ///
    /// `error.UnsupportedFormat` when the format has no `block_separator`, and
    /// that is checked FIRST, before a single byte of source is read: the blank
    /// line every case above writes is only a divider where blank lines divide
    /// blocks. In HTML it is insignificant whitespace inside the `<p>`, so the
    /// gesture used to report success over a document it had not changed the
    /// shape of at all.
    pub fn splitBlock(self: *Editor, offset: usize) Error!void {
        const separator = self.syntax.block_separator orelse return error.UnsupportedFormat;
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const doc = &self.splicer.doc;
        const found = splitTarget(doc, offset) orelse return error.NoBlock;

        const block_start = doc.span(found.block).start;
        const prefix = containerPrefix(src, block_start);
        // As in `insertThematicBreak`: a quote's blank line carries its marker
        // but not the space after it.
        const blank = std.mem.trimEnd(u8, prefix, " ");

        // When the caret already sits at a line start, the line end before it is
        // the separator's first newline — emitting another would leave a blank
        // line trailing inside the FIRST half (and, in a code block, inside its
        // body). This only decides whether the separator needs to open a line or
        // is already on one.
        const at_line_start = offset == 0 or src[offset - 1] == '\n';

        const allocator = self.splicer.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // How many bytes after the caret the second half must SHED. Leading
        // spaces at the start of a block are structure, not content — a split at
        // `- b| c` whose second half kept its space would write `-  c`, setting
        // that item's content indent to three. This is the one place the gesture
        // isn't a pure insertion, and it is deliberately not done for a code
        // block, where leading whitespace IS the content.
        var shed: usize = 0;

        switch (splitShape(std.meta.activeTag(doc.ast.nodes[found.block].kind))) {
            .text => {
                var marker: std.ArrayList(u8) = .empty;
                defer marker.deinit(allocator);
                const in_item = try self.splitMarker(found, block_start, &marker);

                while (offset + shed < src.len and
                    (src[offset + shed] == ' ' or src[offset + shed] == '\t')) shed += 1;

                if (!at_line_start) try out.append(allocator, '\n');
                // A list item's halves stay in ONE list, so no blank line
                // between them — a blank there loosens the list, changing every
                // sibling's rendering. Everywhere else the blank IS the divider.
                if (!in_item) {
                    try out.appendSlice(allocator, blank);
                    try out.appendSlice(allocator, separator);
                }
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, marker.items);
            },

            .code => {
                const fence = self.syntax.code_fence orelse return error.UnsupportedFormat;
                const open = src[locate.lineStartAt(src, block_start)..locate.lineEndAt(src, block_start)];
                // No fence on the opening line means an INDENTED code block,
                // where a blank line is interior and would not divide anything.
                const at = fenceAt(open, fence.char, fence.min) orelse return error.NotEditable;

                if (!at_line_start) try out.append(allocator, '\n');
                try out.appendSlice(allocator, prefix);
                try out.appendNTimes(allocator, fence.char, at.width);
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, blank);
                try out.appendSlice(allocator, separator);
                // Verbatim from the fence character on, so width and info
                // string both survive; the prefix is re-minted, not copied.
                try out.appendSlice(allocator, prefix);
                try out.appendSlice(allocator, locate.lineBody(open)[at.start..]);
                try out.append(allocator, '\n');
            },

            .refuse => return error.NotEditable,
        }

        return self.commitSplice(offset, offset + shed, out.items);
    }

    /// Append to `out` what the second half of a split must carry to come back
    /// as the SAME KIND as the first — a list item's marker, a heading's marker,
    /// both when a heading sits in an item, or nothing for a plain paragraph.
    /// Returns whether the block is in a LIST ITEM, which is what decides
    /// whether a blank line may separate the halves.
    ///
    /// The list case reads the marker off the ITEM'S OWN first line rather than
    /// rebuilding it from `Syntax`, so `*` stays `*`, `1)` stays `1)`, and the
    /// document keeps the spelling its author chose.
    fn splitMarker(
        self: *Editor,
        found: locate.LineBlock,
        block_start: usize,
        out: *std.ArrayList(u8),
    ) Error!bool {
        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;
        const parent_tag = std.meta.activeTag(doc.ast.nodes[found.parent].kind);
        const in_item = parent_tag == .list_item or parent_tag == .task_list_item;

        if (in_item) {
            const item_start = doc.span(found.parent).start;
            const line = src[locate.lineStartAt(src, item_start)..locate.lineEndAt(src, item_start)];
            var from: usize = 0;
            while (skipQuoteMarker(line, from)) |j| from = j;
            const m = listMarkerAt(line, from) orelse return error.NotEditable;
            // From the end of the quote prefix, NOT from `m.start` — the run of
            // spaces between them is the item's NESTING DEPTH, and dropping it
            // moves the new sibling to column zero, out of its own list and into
            // the enclosing one. `listMarkerAt` puts `start` at the bullet on
            // purpose (its other callers want the indent left where it is), so
            // taking it back is this caller's job.
            try out.appendSlice(allocator, line[from..m.end]);

            // A task item's new half is an UNCHECKED box: the marker as written,
            // then this format's empty box rather than the original's state.
            if (parent_tag == .task_list_item) {
                const box = self.syntax.task_marker orelse return error.NotEditable;
                try out.appendSlice(allocator, box.unchecked);
                try out.appendSlice(allocator, box.space);
            }
        }

        if (std.meta.activeTag(doc.ast.nodes[found.block].kind) != .heading) return in_item;

        // A heading repeats its own marker. A SETEXT one has none on its first
        // line — its `---` sits UNDER the block, and would end up under the
        // second half alone — so it is refused rather than silently normalised.
        const marker = self.syntax.heading_marker orelse return error.UnsupportedFormat;
        const line = src[locate.lineStartAt(src, block_start)..locate.lineEndAt(src, block_start)];
        var i: usize = 0;
        while (skipQuoteMarker(line, i)) |j| i = j;
        if (listMarkerAt(line, i)) |m| i = m.end;
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len or line[i] != marker) return error.NotEditable;

        try out.appendNTimes(allocator, marker, doc.ast.nodes[found.block].kind.heading.level);
        try out.append(allocator, ' ');
        return in_item;
    }

    // ── Joining two blocks ───────────────────────────────────────────────────

    /// Join the block at `offset` into the block BEFORE it — Backspace at the
    /// start of a block, and forward Delete at the end of the one above it.
    /// The inverse of `splitBlock`, and the reason it is a gesture rather than
    /// a host's own delete: what joins two blocks is a fact about the FORMAT,
    /// and a host that deletes the newline between them is right only for two
    /// Markdown paragraphs at the top level. In HTML that byte is the `>` of
    /// `</p>`; under a heading it leaves two blocks; after a Markdown `<div>`
    /// it deletes the blank line the div needed and breaks the div.
    ///
    /// ── The two blocks ─────────────────────────────────────────────────────
    /// **B** is the innermost `para`/`heading` covering `offset` — the block
    /// being joined UPWARD, and the one whose identity is given up. **A** is
    /// the LEAF BLOCK immediately before it in document order: the nearest
    /// preceding node holding no blocks of its own, with no other leaf block
    /// between the two. A is found by document order rather than by sibling
    /// order because the caret does not know about containers: the block
    /// visually above `below` in `above`/`<div>`/`hello`/`</div>`/`below` is
    /// `hello`, three levels down, and joining into `above` would be joining
    /// into the wrong paragraph.
    ///
    /// ── What the result is made of ─────────────────────────────────────────
    /// One splice over `[A.ce, R_end)`, assembled from four pieces:
    ///
    ///   * **The separator.** `Syntax.line_join` followed by the CONTAINER
    ///     PREFIX A's own first line sits behind (`locate.continuationPrefix`
    ///     — a quote's `> ` repeated, a list item's marker's WIDTH in spaces,
    ///     nothing at the top level). That prefix is what keeps the joined
    ///     line inside its containers in a format with no lazy continuation,
    ///     which is djot: `- a` + `below` is `- a`/`  below` and not `- a`/
    ///     `below`, which would end the list. The one exception is a heading A
    ///     with a LEADING MARKER (`# Title`, AsciiDoc's `== Title`): such a
    ///     heading is one line by its own spelling, so the separator is a
    ///     single SPACE and `# Title` + `below` is `# Title below`. A SETEXT
    ///     heading A takes the line end like everything else — its content may
    ///     already span lines, and its underline rides along in A's tail.
    ///   * **B's content**, `[B.cs, B.ce)` — its text and nothing else.
    ///   * **A's tail**, `[A.ce, span(a_top).end)`, carried PAST the joined
    ///     text: A's own closing markup (an ATX closing `#` run, a setext
    ///     underline, `</p>`) followed by the closers of every container A
    ///     sits in below the two blocks' lowest common ancestor (a Markdown
    ///     `</div>`, a djot `:::` fence). `a_top` is the LCA's own child
    ///     holding A, so this is exactly what has to be re-closed after the
    ///     text that was pulled in. A is necessarily the last leaf in those
    ///     containers, since B follows it immediately. Its trailing SEPARATOR
    ///     LINES are trimmed first — see `trimTailSeparators`, without which a
    ///     Markdown quote's own trailing `>` line travelled past the joined
    ///     text and piled up there.
    ///   * **Everything else between them vanishes**: the blank line, B's
    ///     markers (`# `, `- `), B's attribute line (djot's `{…}`,
    ///     AsciiDoc's `[…]`), B's opening tags (`<div class="center">`,
    ///     `<p class="x">`). B's ATTRIBUTES ARE DISCARDED on purpose — the
    ///     joined text is A's block, so it takes A's presentation.
    ///
    /// `R_end` is `span(B).end`, so B's own closing markup goes with it. When
    /// B's ancestor chain below the LCA passes through a DELIMITED container —
    /// one spelled with closing bytes of its own after its children, which is
    /// the `container` kind (a Markdown `<div>`, an HTML element, a djot `:::`
    /// fence, a directive) — it is the OUTERMOST of those whose span end is
    /// used instead, because B leaving it means that container's closers go
    /// too. The PREFIX containers (a quote, a list item, a list, a section, a
    /// definition item) have no closers, so whatever follows B inside them
    /// simply stays where it is: joining the first item's text out of a list
    /// leaves the other items a list.
    ///
    /// ── What is refused ────────────────────────────────────────────────────
    /// `error.NoBlock` when no `para`/`heading` covers `offset`, and when B is
    /// the document's FIRST block — there is nothing above to join into, which
    /// is the ordinary Backspace-at-the-top-of-the-document answer.
    ///
    /// `error.NotEditable` for the shapes with no honest result:
    ///   * **A is not a `para` or a `heading`** — a code block, a table, a
    ///     rule, a raw block, a reference definition. There is no text to join
    ///     into, and pulling B's prose into a fence or a table would destroy
    ///     the block a caller was standing next to.
    ///   * **Either block is in a TABLE CELL.** A cell's blocks are not the
    ///     document's lines; a newline between two of them divides nothing and
    ///     a join across a cell boundary is not a join at all.
    ///   * **B is a SETEXT heading**, whose underline is how it is spelled at
    ///     all. `setBlock` normalises one to ATX, which makes this work;
    ///     doing that silently here would rewrite the half the caller did not
    ///     point at, exactly as `splitBlock` refuses one for its own half.
    ///   * **B would have to leave a delimited container that has more content
    ///     after it.** That container's closers cannot move up past content
    ///     that is still inside it, and there is no single obvious thing to do
    ///     instead — split the container in two, or drag the rest out with B —
    ///     so this is the one shape the gesture refuses rather than guesses at.
    ///   * **The GAP between A and B holds anything but separation** — see
    ///     `gapIsClean`. The splice destroys everything between the two that
    ///     is on neither's chain, and a definition is not in the tree at all,
    ///     so nothing above can notice it. This is the guard, and it is read
    ///     off the SOURCE for that reason.
    ///
    /// `error.InvalidRange` when `offset` is past the source.
    ///
    /// `error.UnsupportedFormat` when the format has no `Syntax.line_join`,
    /// checked FIRST, before a byte of source is read: a join writes a line
    /// break INSIDE a block, which is a spelling and not a universal. It is a
    /// different gate from `splitBlock`'s `block_separator` and deliberately a
    /// wider one — HTML has no blank-line block separator and so cannot be
    /// split, while a newline inside its `<p>` is precisely what a join needs.
    pub fn joinBlocks(self: *Editor, offset: usize) Error!void {
        const join = self.syntax.line_join orelse return error.UnsupportedFormat;
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const doc = &self.splicer.doc;
        const allocator = self.splicer.allocator;

        // A caret in a TABLE, before B is looked for at all. A pipe table's
        // cell holds its text directly, with no `para` under it, so the
        // `innermostBlock` below would answer `null` there and the refusal
        // would come back as `NoBlock` — "there is nothing here", about a
        // caret sitting in plain view inside a cell. `lineOwningBlock` stops
        // at the table (a `cell` is deliberately not a block parent), which
        // makes this the same position answer for every format, whether or
        // not its cells wrap their content in a block.
        if (locate.lineOwningBlock(doc, offset)) |lb| {
            if (std.meta.activeTag(doc.ast.nodes[lb.block].kind) == .table) return error.NotEditable;
        }

        const b = locate.innermostBlock(doc, offset) orelse return error.NoBlock;
        if (isSetextHeading(doc, b)) return error.NotEditable;

        var b_chain: std.ArrayList(AST.Node.Id) = .empty;
        defer b_chain.deinit(allocator);
        if (!try nodePath(allocator, doc, b, &b_chain)) return error.NoBlock;
        if (passesThroughTable(doc, b_chain.items)) return error.NotEditable;

        const a = precedingLeafBlock(doc, b) orelse return error.NoBlock;
        switch (std.meta.activeTag(doc.ast.nodes[a].kind)) {
            .para, .heading => {},
            else => return error.NotEditable,
        }

        var a_chain: std.ArrayList(AST.Node.Id) = .empty;
        defer a_chain.deinit(allocator);
        if (!try nodePath(allocator, doc, a, &a_chain)) return error.NotEditable;
        if (passesThroughTable(doc, a_chain.items)) return error.NotEditable;

        // Where the two chains diverge. Both start at the root and neither is a
        // prefix of the other — A is a leaf, so B cannot be inside it, and B is
        // not A — so this index exists in both. It is never 0: the root is the
        // first element of both chains, so the loop below runs at least once.
        // Running off the end of either chain would mean one block is inside
        // the other, which the two facts above rule out; refusing beats
        // indexing past the end should a future kind make it reachable.
        var i: usize = 0;
        while (i < a_chain.items.len and i < b_chain.items.len and
            a_chain.items[i] == b_chain.items[i]) i += 1;
        if (i >= a_chain.items.len or i >= b_chain.items.len) return error.NotEditable;
        const a_top = a_chain.items[i];
        const b_top = b_chain.items[i];

        // Everything between the two that is on neither chain is about to be
        // destroyed. This is the one guard against that, and the shapes it
        // catches are ones no walk above could have — see `gapIsClean`.
        if (!gapIsClean(doc, src, a_chain.items[0..i], a_top, b_top)) return error.NotEditable;

        // B's own closing markup goes; a delimited container it is leaving
        // takes its closers with it, and the OUTERMOST such container is the
        // one whose span bounds the removal.
        var r_end = doc.span(b).end;
        for (b_chain.items[i .. b_chain.items.len - 1]) |id| {
            if (std.meta.activeTag(doc.ast.nodes[id].kind) != .container) continue;
            // Nothing may be left behind inside a container whose closers are
            // about to move up past it.
            if (lastLeafBlock(doc, id) != b) return error.NotEditable;
            r_end = doc.span(id).end;
            break;
        }

        const a_content = blockContent(doc, a);
        const b_content = blockContent(doc, b);
        const a_tail = trimTailSeparators(src[a_content.end..doc.span(a_top).end]);
        const b_text = src[b_content.start..b_content.end];

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // A heading written with a leading marker is ONE LINE, so what
        // continues it is a space, not a line end. `markerSpan` is the whole
        // test: an HTML `<h1>` has no marker and takes the line end, and
        // `<h1>a\nb</h1>` is the one heading it should be.
        if (std.meta.activeTag(doc.ast.nodes[a].kind) == .heading and doc.markerSpan(a) != null) {
            try out.append(allocator, ' ');
            // B may be several lines; the heading is one. Each of B's line
            // ends becomes the space that continues the sentence, or `# T` +
            // `xx`/`yy` would be a heading `# T xx` with `yy` left below it
            // as a paragraph — two blocks, from a gesture that reports having
            // made one.
            try appendAsOneLine(allocator, b_text, &out);
        } else {
            try out.appendSlice(allocator, join);
            _ = try locate.continuationPrefix(allocator, doc, a_content.start, &out);
            try appendAsContinuation(allocator, self.syntax, b_text, &out);
        }
        try out.appendSlice(allocator, a_tail);

        // The removed region ran to the end of a line in every format whose
        // block span covers its own terminator (djot's does, Markdown's does
        // not), and A's tail only ends at one when A's container did. Put the
        // terminator back when B's removal took it and the tail did not supply
        // it, so the document keeps the line structure it had. `out` is never
        // empty — the separator above is at least one byte — but the index is
        // guarded rather than argued, since a `line_join` of `""` would make
        // the argument false and the panic real.
        if (r_end > a_content.end and src[r_end - 1] == '\n' and
            (out.items.len == 0 or out.items[out.items.len - 1] != '\n')) try out.append(allocator, '\n');

        return self.commitSplice(a_content.end, r_end, out.items);
    }

    // ── Code blocks ──────────────────────────────────────────────────────────

    /// Toggle a fenced code block over the blocks `[start, end)` covers: fence
    /// them if the caret isn't in a code block, unfence the one it is in if it
    /// is. `lang` is the info string to tag the opening fence with, ignored when
    /// unfencing.
    ///
    /// Fencing is an INSERTION at the covered region's edges, not a rewrite of
    /// its lines: the body is source that already parsed where it sits, and its
    /// enclosing container's prefix is already on every line, so leaving the
    /// lines alone is what keeps a fence inside a quote working (`> a` becomes
    /// `` > ``` ``/`> a`/`` > ``` ``). Only the two fence lines are minted, and
    /// they carry the same quote prefix for the same reason
    /// `insertThematicBreak` does.
    ///
    /// The fence is measured, not fixed: it is one byte longer than the longest
    /// run of the fence character anywhere in the body, so fencing text that
    /// itself holds a fence nests instead of closing early. `CodeFence.min` is
    /// the floor.
    ///
    /// Unfencing peels the opening line and — when it is one — the closing fence
    /// line, leaving the interior verbatim. A Markdown INDENTED code block has no
    /// fences to peel, so it is dedented by up to four spaces a line instead;
    /// that is the same construct with a different spelling, and refusing it
    /// would make the toggle irreversible on a document that merely happens to
    /// use the older form.
    ///
    /// Unfencing is the one gesture here that can produce something other than
    /// what it removed: a code body is by definition text the parser did not
    /// read as markup, so `# x` inside a fence becomes a heading once the fence
    /// is gone. That is what unfencing MEANS, not a defect — but it is why this
    /// is a toggle over whole blocks rather than an "unwrap" that promises to
    /// give the same tree back.
    ///
    /// INSIDE A LIST ITEM this is `error.NotEditable`. A quote's prefix is on
    /// every line already, but a list item's is not: its content is held by
    /// INDENTATION whose width is the marker's, and only the item's first line
    /// carries that marker. A fence written at column zero there swallows the
    /// `- ` into the code body and the item stops being an item — the document
    /// loses a node rather than gaining a code block. Refusing beats that, for
    /// the same reason a selection running into the middle of a URL is refused
    /// rather than spliced; fencing inside a list wants marker-width prefixing,
    /// which is `toggleBlockContainer`'s machinery and not a one-line prefix's.
    ///
    /// TWO SPELLINGS, in `setBlock`'s order: the fence above where the format
    /// has one, and where it has none but carries a `renderBlock`, a
    /// `code_block` node the format prints — see `toggleCodeBlockByRender`.
    pub fn toggleCodeBlock(self: *Editor, span: Span, lang: ?[]const u8) Error!void {
        try self.checkRange(span.start, span.end);
        const fence = self.syntax.code_fence orelse {
            if (self.syntax.renderBlock) |render| return self.toggleCodeBlockByRender(span, lang, render);
            return error.UnsupportedFormat;
        };
        if (lang) |l| try checkInfoString(fence, l);

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, span.start, &chain);
        // Refused rather than mangled — see the doc comment. A fence written at
        // the container prefix would sit at column zero inside a list item and
        // swallow the item's own marker into the code body.
        if (insideListItem(doc, chain.items)) return error.NotEditable;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        if (locate.innermostOfKind(doc, chain.items, .code_block)) |cb| {
            const b = doc.span(cb);
            const region_start = locate.lineStartAt(src, b.start);
            const region_end = locate.lineEndAt(src, b.end -| 1);
            try buildUnfence(allocator, src, region_start, region_end, fence, &out);
            return self.commitSplice(region_start, region_end, out.items);
        }

        const blocks = coveredBlocks(allocator, doc, span.start, span.end) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoBlock,
        };
        defer allocator.free(blocks.chain);

        const region_start = locate.lineStartAt(src, doc.span(blocks.first).start);
        const region_end = locate.lineEndAt(src, doc.span(blocks.last).end -| 1);
        const prefix = containerPrefix(src, doc.span(blocks.first).start);
        const width = fenceWidth(src[region_start..region_end], fence.char, fence.min);

        try out.appendSlice(allocator, prefix);
        try out.appendNTimes(allocator, fence.char, width);
        if (lang) |l| try out.appendSlice(allocator, l);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, src[region_start..region_end]);
        // An unterminated last line would otherwise fuse with the closing fence.
        if (region_end > region_start and src[region_end - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, prefix);
        try out.appendNTimes(allocator, fence.char, width);
        try out.append(allocator, '\n');

        return self.commitSplice(region_start, region_end, out.items);
    }

    /// Retag the code block at `offset` with `lang`, or clear its info string
    /// when `lang` is null — the "language" dropdown next to a code block.
    ///
    /// Only the info string is rewritten; the fence's own width is kept, because
    /// it was measured against a body this gesture doesn't touch. An INDENTED
    /// Markdown code block is `error.NotEditable`: it has no fence, so it has
    /// nowhere to carry a language (convert it with `toggleCodeBlock` twice).
    ///
    /// Where the format has no fence but a `renderBlock`, the block is
    /// rebuilt with the new language and printed — see
    /// `setCodeLanguageByRender`.
    pub fn setCodeLanguage(self: *Editor, offset: usize, lang: ?[]const u8) Error!void {
        const fence = self.syntax.code_fence orelse {
            if (self.syntax.renderBlock) |render| return self.setCodeLanguageByRender(offset, lang, render);
            return error.UnsupportedFormat;
        };
        if (lang) |l| try checkInfoString(fence, l);

        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const allocator = self.splicer.allocator;
        const doc = &self.splicer.doc;

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, offset, &chain);
        const cb = locate.innermostOfKind(doc, chain.items, .code_block) orelse return error.NoBlock;

        const line_start = locate.lineStartAt(src, doc.span(cb).start);
        const line = src[line_start..locate.lineEndAt(src, line_start)];
        const f = fenceAt(line, fence.char, fence.min) orelse return error.NotEditable;

        const info_start = line_start + f.start + f.width;
        const info_end = line_start + locate.lineBody(line).len;
        return self.commitSplice(info_start, info_end, lang orelse "");
    }

    /// `toggleCodeBlock` over a format with no fence but a fragment renderer:
    /// BUILD the code block and let the format print it, or take one apart.
    ///
    /// The fence path works on SOURCE — the covered lines go inside the fence
    /// verbatim, and unfencing gives them back — because in a lightweight
    /// format a paragraph's source is its text. Here it is not (`<p>a
    /// &amp; b</p>`), so the payload is the covered blocks' TEXT
    /// (`blockTextInto`): the selection's words, with its marks dropped, is
    /// what a listing made from prose holds. And toggling OFF puts the
    /// listing's text under a paragraph the format prints, so `a < b` reads
    /// back as those five characters and mints no markup — the one thing the
    /// fence path's "unfencing means the body is read as source" cannot
    /// promise, and the reason this direction is a render too.
    ///
    /// A paragraph in, the same paragraph out: toggle twice on plain prose and
    /// the document is what it was. Prose carrying marks loses them on the way
    /// in, which is what a code block MEANS.
    ///
    /// No list-item refusal: the fence path refuses inside an item because a
    /// fence at column zero swallows the item's marker, and a wrapping pair
    /// swallows nothing.
    fn toggleCodeBlockByRender(self: *Editor, span: Span, lang: ?[]const u8, render: RenderBlockFn) Error!void {
        if (lang) |l| try checkLanguageToken(l);

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const doc = &self.splicer.doc;
        const ast = self.astView();

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, span.start, &chain);
        if (locate.innermostOfKind(doc, chain.items, .code_block)) |cb| {
            var b = AST.Builder.init(allocator);
            defer b.deinit();
            const text = try b.addLeaf(.{ .str = ast.nodes[cb].kind.code_block.text });
            const root = try b.addContainer(.para, &.{text});
            const t = doc.span(cb);
            return self.spliceRendered(&b, root, render, t.start, blockSpanEnd(src, t));
        }

        const blocks = coveredBlocks(allocator, doc, span.start, span.end) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoBlock,
        };
        defer allocator.free(blocks.chain);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        var cur: ?AST.Node.Id = blocks.first;
        while (cur) |c| : (cur = if (c == blocks.last) null else ast.nodes[c].next_sibling) {
            if (c != blocks.first) try text.append(allocator, '\n');
            try blockTextInto(allocator, ast, c, &text);
        }

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const root = try b.addLeaf(.{ .code_block = .{ .lang = lang, .text = text.items } });
        const first = doc.span(blocks.first);
        const last = doc.span(blocks.last);
        return self.spliceRendered(&b, root, render, first.start, blockSpanEnd(src, last));
    }

    /// `setCodeLanguage` over a format with no fence but a fragment renderer:
    /// the block is rebuilt with `lang` over the same text — its attributes
    /// along — and printed in its place.
    fn setCodeLanguageByRender(self: *Editor, offset: usize, lang: ?[]const u8, render: RenderBlockFn) Error!void {
        if (lang) |l| try checkLanguageToken(l);

        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const allocator = self.splicer.allocator;
        const doc = &self.splicer.doc;
        const ast = self.astView();

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, offset, &chain);
        const cb = locate.innermostOfKind(doc, chain.items, .code_block) orelse return error.NoBlock;

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        const root = try b.addLeaf(.{ .code_block = .{ .lang = lang, .text = ast.nodes[cb].kind.code_block.text } });
        if (ast.nodes[cb].attrs) |ai| try b.setAttrs(root, ast.attrs[ai]);
        const t = doc.span(cb);
        return self.spliceRendered(&b, root, render, t.start, blockSpanEnd(src, t));
    }

    // ── Task list checkboxes ─────────────────────────────────────────────────
    // A checkbox is not a node an editor wraps a range in: it is a marker on an
    // ITEM, so every gesture here is addressed by a caret `offset` and edits the
    // few bytes after that item's list marker. Nothing else on the line moves —
    // in particular the box is INLINE CONTENT of the item's first paragraph, not
    // part of the marker, so adding or removing one leaves the item's
    // continuation-line indentation alone (unlike `toggleBlockContainer`, which
    // has to re-indent).

    /// Add a checkbox to the list item at `offset`, or take one away — the
    /// gesture that converts between a `list_item` and a `task_list_item`. A box
    /// is added UNCHECKED; use `setTaskChecked` to tick it.
    ///
    /// `error.NoBlock` when `offset` is in no list item, `error.NotEditable`
    /// when the item's line carries no recognizable list marker to hang a box
    /// off (a lazy continuation line).
    pub fn toggleTaskItem(self: *Editor, offset: usize) Error!void {
        const tm = self.syntax.task_marker orelse return error.UnsupportedFormat;
        const found = try self.locateTaskBox(offset);
        if (found.box) |b| return self.commitSplice(b.start, b.end + found.space, "");

        const allocator = self.splicer.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, tm.unchecked);
        try out.appendSlice(allocator, tm.space);
        return self.commitSplice(found.at, found.at, out.items);
    }

    /// Tick or untick the task item at `offset` — a click on the checkbox.
    ///
    /// Rewrites the BOX ALONE, never the space after it, so an item spelled with
    /// unusual spacing keeps it. A no-op (no edit, no undo step) when the box is
    /// already in the requested state. `error.NotEditable` when the item has no
    /// box: minting one here would make a "set checked" call silently convert a
    /// bullet into a task, which is `toggleTaskItem`'s job to do explicitly.
    pub fn setTaskChecked(self: *Editor, offset: usize, checked: bool) Error!void {
        const tm = self.syntax.task_marker orelse return error.UnsupportedFormat;
        const found = try self.locateTaskBox(offset);
        const b = found.box orelse return error.NotEditable;
        if (found.checked == checked) return;
        return self.commitSplice(b.start, b.end, if (checked) tm.checked else tm.unchecked);
    }

    /// Flip the task item at `offset` — `setTaskChecked` against its current
    /// state, which is what a checkbox click actually is when the caller doesn't
    /// already know the state.
    pub fn toggleTaskChecked(self: *Editor, offset: usize) Error!void {
        if (self.syntax.task_marker == null) return error.UnsupportedFormat;
        const found = try self.locateTaskBox(offset);
        if (found.box == null) return error.NotEditable;
        return self.setTaskChecked(offset, !found.checked);
    }

    /// Where the checkbox on the list item at `offset` is, or would go. The
    /// shared body of the three gestures above.
    fn locateTaskBox(self: *Editor, offset: usize) Error!TaskBox {
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const tm = self.syntax.task_marker orelse return error.UnsupportedFormat;
        const allocator = self.splicer.allocator;
        const doc = &self.splicer.doc;

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, offset, &chain);

        // The innermost item of EITHER kind, walked directly rather than through
        // two `innermostOfKind` calls: a plain item can gain a box and a task
        // item can lose one, so both are targets and whichever is deeper wins.
        var item: ?AST.Node.Id = null;
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            switch (std.meta.activeTag(doc.ast.nodes[chain.items[i]].kind)) {
                .list_item, .task_list_item => {
                    item = chain.items[i];
                    break;
                },
                else => {},
            }
        }
        const id = item orelse return error.NoBlock;

        // The item's FIRST line, which is the only one a marker can open. Djot
        // starts a quoted item at its marker and Markdown at column 0, so the
        // line start is taken from the span rather than the span itself.
        const line_start = locate.lineStartAt(src, doc.span(id).start);
        const line = src[line_start..locate.lineEndAt(src, line_start)];
        var from: usize = 0;
        while (skipQuoteMarker(line, from)) |j| from = j;
        const m = listMarkerAt(line, from) orelse return error.NotEditable;

        const at = line_start + m.end;
        const rest = line[m.end..];
        const width = tm.unchecked.len;
        if (rest.len >= width and rest[0] == '[' and rest[width - 1] == ']') {
            // The box's INTERIOR, read rather than compared against the two
            // spellings: source in the wild writes `[X]` as well as `[x]`, and a
            // literal match would call the capital form "not a checkbox at all"
            // and hand the caller a second box to insert beside it.
            const inner = rest[1 .. width - 1];
            const checked = std.mem.indexOfAny(u8, inner, tm.checked_chars) != null;
            if (checked or locate.isBlankLine(inner)) return .{
                .at = at,
                .box = Span.init(at, at + width),
                // However the author spaced it — removing the box takes the
                // separator with it, ticking it leaves the separator alone.
                .space = if (rest.len > width and rest[width] == ' ') 1 else 0,
                .checked = checked,
            };
        }
        return .{ .at = at, .box = null, .space = 0, .checked = false };
    }

    // ── Tables ───────────────────────────────────────────────────────────────
    // A table is a grid, not a run of delimited text, so its edits are grid
    // surgery (add/remove/move a row or column, set a column's alignment) rather
    // than a toggle. The grid is lifted from the AST, mutated, and the whole
    // table re-spelled in one splice — see `table_edit.zig`. Every gesture is
    // addressed by a caret `offset`; the cell it lands in is the anchor.

    /// Insert an empty row below (`after`) or above the caret's row.
    pub fn tableInsertRow(self: *Editor, offset: usize, after: bool) Error!void {
        return self.tableEdit(offset, .{ .insert_row = if (after) .after else .before });
    }

    /// Delete the caret's row. `error.NotEditable` for a header row or the last
    /// body row (a table keeps a header and at least one body row).
    pub fn tableDeleteRow(self: *Editor, offset: usize) Error!void {
        return self.tableEdit(offset, .delete_row);
    }

    /// Insert an empty column right (`after`) or left of the caret's column.
    pub fn tableInsertColumn(self: *Editor, offset: usize, after: bool) Error!void {
        return self.tableEdit(offset, .{ .insert_column = if (after) .after else .before });
    }

    /// Delete the caret's column. `error.NotEditable` when it is the only one.
    pub fn tableDeleteColumn(self: *Editor, offset: usize) Error!void {
        return self.tableEdit(offset, .delete_column);
    }

    /// Set the caret's column to `alignment`.
    pub fn tableSetAlignment(self: *Editor, offset: usize, alignment: AST.Alignment) Error!void {
        return self.tableEdit(offset, .{ .set_alignment = alignment });
    }

    /// Move the caret's row one place down (`down`) or up, within the body rows.
    pub fn tableMoveRow(self: *Editor, offset: usize, down: bool) Error!void {
        return self.tableEdit(offset, .{ .move_row = if (down) .after else .before });
    }

    /// Move the caret's column one place right (`right`) or left.
    pub fn tableMoveColumn(self: *Editor, offset: usize, right: bool) Error!void {
        return self.tableEdit(offset, .{ .move_column = if (right) .after else .before });
    }

    const TableOp = union(enum) {
        insert_row: table_edit.Side,
        delete_row,
        insert_column: table_edit.Side,
        delete_column,
        set_alignment: AST.Alignment,
        move_row: table_edit.Side,
        move_column: table_edit.Side,
    };

    /// Lift the table at `offset`, apply one grid op, and splice the rebuilt
    /// table back — the shared body of every table gesture above.
    ///
    /// The spelling is fetched FIRST, before the grid is extracted and long
    /// before anything is spliced, and that ordering is the whole fix rather
    /// than a tidiness: a format can have a table this file can READ and no
    /// table it can WRITE. HTML is exactly that — `html/parser.zig` lowers
    /// `<table>/<tr>/<td>` to the same `table`/`row`/`cell` nodes a pipe table
    /// produces, so extraction succeeded and the rebuilt pipe text went over the
    /// `<table>…</table>` region, which HTML then reparsed as a paragraph. A
    /// document that still parses is one the splicer will not roll back, so the
    /// table was destroyed without an error anywhere.
    fn tableEdit(self: *Editor, offset: usize, op: TableOp) Error!void {
        const spelling = self.syntax.table_spelling orelse return error.UnsupportedFormat;
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const allocator = self.splicer.allocator;

        var grid = table_edit.extract(allocator, &self.splicer.doc, offset) catch |e| return mapTableErr(e);
        defer grid.deinit();

        (switch (op) {
            .insert_row => |s| table_edit.insertRow(&grid, s),
            .delete_row => table_edit.deleteRow(&grid),
            .insert_column => |s| table_edit.insertColumn(&grid, s),
            .delete_column => table_edit.deleteColumn(&grid),
            .set_alignment => |a| table_edit.setAlignment(&grid, a),
            .move_row => |d| table_edit.moveRow(&grid, d),
            .move_column => |d| table_edit.moveColumn(&grid, d),
        }) catch |e| return mapTableErr(e);

        const bytes = table_edit.emit(allocator, &grid, spelling) catch |e| return mapTableErr(e);
        defer allocator.free(bytes);
        return self.commitSplice(grid.region.start, grid.region.end, bytes);
    }

    /// Map a `table_edit` error onto the `Editor` error set: "not in a table"
    /// reads as no block for the gesture, a refused (degenerate) edit as not
    /// editable.
    fn mapTableErr(e: table_edit.Error) Error {
        return switch (e) {
            error.NotInTable => error.NoBlock,
            error.Refused => error.NotEditable,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    // ── Links ──────────────────────────────────────────────────────────────

    /// Link `[start, end)` to `destination`, or repoint the link already there.
    ///
    /// Decisions:
    ///   * An EXISTING link covering the range has its destination REPLACED, its
    ///     text kept. Re-linking is the common gesture (fix a URL), and it keeps
    ///     the op idempotent instead of nesting `[[t](a)](b)`. Removing a link is
    ///     already `Splicer.unwrapNode`, which peels a node to its interior.
    ///   * A RANGE INSIDE an existing autolink re-points it the same way, but
    ///     there is no text to keep: an autolink's text IS its destination, so
    ///     the node is respelled whole for the new one (canonically — see below
    ///     — so a `<url>` re-pointed at a relative path becomes `[dest](dest)`,
    ///     not a broken `<>`). Without this the op reads the URL as ordinary text
    ///     and splices a link into the middle of it:
    ///     `<https<https://y.dev>://x.dev>`.
    ///
    ///     This covers a caret AND any selection the autolink contains —
    ///     including one covering it exactly. An autolink's URL is not editable
    ///     text: no part of it can host a `[`, so "link half this URL" has no
    ///     spelling, and the selection carries no text a splice could keep.
    ///
    ///     A selection that starts or ends strictly INSIDE an autolink but isn't
    ///     contained by it (`see <https://x` … `.dev> ok`) is refused with
    ///     `error.NotEditable`: half of it is real text, so there is nothing to
    ///     re-point, and any splice would rewrite the URL. Refusing beats
    ///     silently changing the caller's URL, for the same reason a newline
    ///     destination is `error.InvalidDestination`.
    ///
    ///     A range inside BOTH a link and an autolink (`[<https://x.dev>](d)`)
    ///     re-points the link, not the autolink: a link's text is separable from
    ///     its destination, so re-pointing it keeps text that re-pointing the
    ///     autolink would discard.
    ///
    ///     A range that CONTAINS an autolink whole plus text around it is
    ///     untouched by all of the above — it splices at the autolink's edges,
    ///     corrupting nothing, and the autolink stays as the new link's text.
    ///   * A link with NO TEXT gets the canonical spelling for the destination it
    ///     was given, never `[](dest)`: a childless link has nothing to render,
    ///     so consumers fall back to showing the destination and the caret has
    ///     nowhere correct to sit. Where the format can spell an autolink it gets
    ///     `<dest>`; where it can't it gets `[dest](dest)`, the destination
    ///     doubling as text so it stays visible and editable. Which destinations
    ///     autolink, and how each format spells one, is twig's knowledge — a
    ///     consumer guessing would turn `<foo>` into raw HTML (Markdown) or
    ///     literal text (both). See `Syntax.spellsAutolink`.
    ///   * A destination is escaped per format (see `writeLinkDestination`); a
    ///     newline in one is `error.InvalidDestination`, since neither format can
    ///     hold it (Djot strips it, Markdown's `<…>` form forbids it) and
    ///     silently changing the caller's URL is worse than refusing.
    ///
    /// TWO SPELLINGS, in `setBlock`'s order: `[text](dest)` from the escape
    /// alphabets where the format has them, and where it has none but carries
    /// a `renderBlock`, a `link` node over the selection's inline nodes that
    /// the format prints — see `insertLinkByRender`.
    pub fn insertLink(self: *Editor, span: Span, dest: []const u8) Error!void {
        try self.checkRange(span.start, span.end);
        if (std.mem.indexOfAny(u8, dest, "\r\n") != null) return error.InvalidDestination;
        // A format with no link spelling refuses before anything else is read.
        if (self.syntax.link_text_escapes == null) {
            if (self.syntax.renderBlock) |render| return self.insertLinkByRender(span, dest, render, .link);
            return error.UnsupportedFormat;
        }

        const start = span.start;
        const end = span.end;
        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const ast = self.astView();

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, &self.splicer.doc, start, &chain);

        // The text to sit in the brackets, and the span the rebuilt link
        // replaces. Re-pointing an existing link rebuilds the whole node: a
        // destination is a string payload with no span of its own, so there is
        // nothing smaller to splice (see `splicer.zig`'s module doc).
        var text: []const u8 = src[start..end];
        var target = Span.init(start, end);
        var repoint = locate.innermostCovering(&self.splicer.doc, chain.items, &.{.link}, start, end);
        if (repoint == null) repoint = autolinkCovering(&self.splicer.doc, chain.items, start, end);
        // Not covered by an autolink, but still landing inside one: the range
        // runs from ordinary text into the middle of a URL (either end can be the
        // one inside). There is nothing to re-point — half the selection is real
        // text — and no way to spell the result, so refuse rather than corrupt
        // the URL.
        if (repoint == null and start != end) {
            const splits =
                (try splitsAutolink(allocator, &self.splicer.doc, start)) or
                (try splitsAutolink(allocator, &self.splicer.doc, end));
            if (splits) return error.NotEditable;
        }
        if (repoint) |id| {
            const node = ast.nodes[id];
            const rp = self.splicer.doc.span(id);
            if (rp.start == 0 and rp.end == 0) return error.NotEditable;
            // An autolink has no `[text]` half: the text it shows is the OLD
            // destination, so keeping it would spell the new link with the URL it
            // was meant to replace. Empty text sends it through the canonical
            // spelling below, exactly as a caret on bare text goes.
            text = switch (node.kind) {
                // An autolink's visible text IS its destination; the caller
                // supplies that, so the node contributes nothing.
                .text_leaf => |l| if (l.kind == .url or l.kind == .email) "" else if (self.splicer.doc.contentSpan(id)) |cs| src[cs.start..cs.end] else "",
                else => if (self.splicer.doc.contentSpan(id)) |cs| src[cs.start..cs.end] else "",
            };
            target = rp;
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // Keyed on the TEXT being empty, not the range: re-pointing an existing
        // `[](old)` is an empty range too, and it has the same childless link to
        // avoid. A non-empty range always carries text, so it never lands here.
        if (text.len == 0) {
            if (self.syntax.spellsAutolink) |spells| {
                try out.append(allocator, '<');
                try out.appendSlice(allocator, dest);
                try out.append(allocator, '>');
                // Ask about the exact bytes we would emit, so the test and the
                // output cannot disagree about what was spelled.
                if (spells(out.items)) return self.commitSplice(target.start, target.end, out.items);
                out.clearRetainingCapacity();
            }
        }

        try out.append(allocator, '[');
        if (text.len == 0) {
            // `dest` is a raw string being repurposed as text, so it needs
            // escaping for that position — unlike `text`, which is already source
            // the author (or a prior parse) spelled and which must be copied
            // through verbatim.
            try writeLinkText(allocator, self.syntax, dest, &out);
        } else {
            try out.appendSlice(allocator, text);
        }
        try out.appendSlice(allocator, "](");
        try writeLinkDestination(allocator, self.syntax, dest, &out);
        try out.append(allocator, ')');

        return self.commitSplice(target.start, target.end, out.items);
    }

    /// Spell `[start, end)` as an image pointing at `dest` — `![alt](dest)`, the
    /// selected source becoming the alt text.
    ///
    /// Shares `insertLink`'s destination spelling, which is the whole reason this
    /// belongs here rather than in a caller's format string: an image destination
    /// is the *same grammar production* as a link's, so it needs the same
    /// per-format treatment — Markdown moving a destination that holds whitespace
    /// into the `<…>` form, Djot taking it bare because `<…>` means nothing there
    /// and would link the literal characters. A caller spelling `![](my file.png)`
    /// by hand writes something Markdown does not read as an image at all, and
    /// cannot fix without reproducing `writeLinkDestination`.
    ///
    /// Simpler than a link in two ways. There is no autolink form to prefer and no
    /// re-point reasoning: an image has no bare-URL spelling, and re-pointing an
    /// existing one is `imageDestinationAt`-then-insert above this op rather than a
    /// shape to detect here. And empty text stays empty — `![](dest)` is a perfectly
    /// good image, where the `[](dest)` that `insertLink` works to avoid is a link
    /// with nothing to click.
    ///
    /// The same two spellings as `insertLink`: where the format has no
    /// alphabet but a renderer, an `image` node over the selection's inline
    /// nodes — its alt text — is printed instead (`insertLinkByRender`, with
    /// `.image`).
    pub fn insertImage(self: *Editor, span: Span, dest: []const u8) Error!void {
        try self.checkRange(span.start, span.end);
        if (std.mem.indexOfAny(u8, dest, "\r\n") != null) return error.InvalidDestination;
        if (self.syntax.link_text_escapes == null or self.syntax.link_dest_escapes == null) {
            if (self.syntax.renderBlock) |render| return self.insertLinkByRender(span, dest, render, .image);
            return error.UnsupportedFormat;
        }

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        // Already-parsed source, copied verbatim — the same distinction
        // `insertLink` draws between a span of the document and a raw argument.
        const text = src[span.start..span.end];

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        try out.appendSlice(allocator, "![");
        try out.appendSlice(allocator, text);
        try out.appendSlice(allocator, "](");
        try writeLinkDestination(allocator, self.syntax, dest, &out);
        try out.append(allocator, ')');

        return self.commitSplice(span.start, span.end, out.items);
    }

    /// `insertLink`/`insertImage` over a format with no link alphabet but a
    /// fragment renderer: BUILD the node over the selection and let the format
    /// print it.
    ///
    /// The alphabet path copies the selected SOURCE between `[` and `]`, which
    /// works because in a lightweight format a selection's source is text the
    /// format reads back. A renderer prints a TREE, so the selection has to be
    /// one: the inline nodes it covers (`coveredInlines`), grafted under a
    /// fresh `link` or `image`. A selection that starts or ends inside a plain
    /// text run takes the run's covered part; one that cuts through anything
    /// else — a mark, a code span, a text run whose source spells characters
    /// as entities so that a byte offset names no character in it — is
    /// `error.NotEditable`, as a range into the middle of an autolink is on the
    /// alphabet path. Refusing beats a link whose text is not what was
    /// selected.
    ///
    /// Re-pointing an existing link keeps its children and attributes and
    /// replaces its destination — the alphabet path's rule, on the tree. An
    /// empty selection gets a link whose text IS the destination, which is
    /// the alphabet path's `[dest](dest)` for a format with no autolink form;
    /// an empty selection makes an image with empty alt text, as `![](dest)`
    /// does.
    fn insertLinkByRender(
        self: *Editor,
        span: Span,
        dest: []const u8,
        render: RenderBlockFn,
        shape: enum { link, image },
    ) Error!void {
        const allocator = self.splicer.allocator;
        const doc = &self.splicer.doc;
        const ast = self.astView();

        var b = AST.Builder.init(allocator);
        defer b.deinit();
        var kids: std.ArrayList(AST.Node.Id) = .empty;
        defer kids.deinit(allocator);
        var target = span;
        var attrs: ?AST.Attrs = null;

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, doc, span.start, &chain);
        const repoint = if (shape == .link)
            locate.innermostCovering(doc, chain.items, &.{.link}, span.start, span.end)
        else
            null;
        if (repoint) |id| {
            target = doc.span(id);
            if (target.start == 0 and target.end == 0) return error.NotEditable;
            if (ast.nodes[id].attrs) |ai| attrs = ast.attrs[ai];
            var child = ast.nodes[id].first_child;
            while (child) |c| : (child = ast.nodes[c].next_sibling) {
                try kids.append(allocator, try b.graftSubtree(ast, c));
            }
        } else if (span.end > span.start) {
            const covered = try coveredInlines(allocator, doc, span.start, span.end);
            defer allocator.free(covered);
            for (covered) |piece| {
                try kids.append(allocator, if (piece.text) |t|
                    try b.addLeaf(.{ .str = t })
                else
                    try b.graftSubtree(ast, piece.node));
            }
        }
        if (shape == .link and kids.items.len == 0) try kids.append(allocator, try b.addLeaf(.{ .str = dest }));

        const payload: AST.Node.Kind.Link = .{ .destination = dest, .reference = null };
        const root = try b.addContainer(switch (shape) {
            .link => .{ .link = payload },
            .image => .{ .image = payload },
        }, kids.items);
        if (attrs) |a| try b.setAttrs(root, a);
        return self.spliceRendered(&b, root, render, target.start, target.end);
    }

    // ── Footnotes ────────────────────────────────────────────────────────────

    /// Insert a footnote reference at `offset` and, unless one already exists,
    /// the matching definition at the end of the document.
    ///
    /// Decisions:
    ///   * It writes BOTH HALVES, because in neither format is half a footnote a
    ///     footnote: a bare `[^a]` with nothing defining it renders as the
    ///     literal four characters. That is also why `Syntax.footnote` is one
    ///     field holding both spellings rather than a reference entry in
    ///     `text_leaf_delims` (which is there for the serializer, and which
    ///     `assertCoherent` pins to this).
    ///   * The definition body is left EMPTY, and that parses — both parsers
    ///     read `[^a]: ` as a footnote with no children. The caller then types
    ///     into it like any other block; minting a placeholder body here would be
    ///     text the author has to delete.
    ///   * A label that is ALREADY DEFINED gets only the reference. Referring to
    ///     an existing footnote twice is an ordinary thing to want, and appending
    ///     a second definition for the same label is not — the parsers keep one
    ///     and the other becomes dead source.
    ///   * It is ONE splice, spanning the caret to the end of the document, even
    ///     though the two halves are far apart and the bytes between them are
    ///     rewritten unchanged. Two splices would be less wasteful and strictly
    ///     worse: the pair would take two undo steps to reverse, and `lastChange`
    ///     — the range a caller re-renders from — would describe only the second,
    ///     silently omitting the reference the caret is sitting in.
    ///
    /// `error.InvalidLabel` for a label that is empty or holds a line end or a
    /// reference bracket; `error.UnsupportedFormat` where the format has no
    /// footnotes.
    pub fn insertFootnote(self: *Editor, offset: usize, label: []const u8) Error!void {
        try self.checkRange(offset, offset);
        const fs = self.syntax.footnote orelse return error.UnsupportedFormat;
        if (label.len == 0) return error.InvalidLabel;
        if (std.mem.indexOfAny(u8, label, "\r\n") != null) return error.InvalidLabel;
        if (std.mem.indexOfAny(u8, label, fs.label_forbids) != null) return error.InvalidLabel;

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        try out.appendSlice(allocator, fs.ref_open);
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, fs.ref_close);

        if (footnoteDefined(self.astView(), label)) {
            return self.commitSplice(offset, offset, out.items);
        }

        try out.appendSlice(allocator, src[offset..]);
        // The definition is a block of its own at the end of the document, so it
        // needs a line to itself and a blank line above it.
        if (src.len > 0 and src[src.len - 1] != '\n') try out.append(allocator, '\n');
        if (!endsWithBlankLine(src)) try out.append(allocator, '\n');
        try out.appendSlice(allocator, fs.ref_open);
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, fs.ref_close);
        try out.appendSlice(allocator, fs.def_suffix);
        try out.append(allocator, '\n');

        return self.commitSplice(offset, src.len, out.items);
    }

    // ── Literal text ─────────────────────────────────────────────────────────

    /// Insert `text` at `offset` as a LITERAL run: every byte the format reads as
    /// markup is backslash-escaped so the run reparses as exactly `text`, never as
    /// emphasis, a code span, a link, an entity, or — at a line start — a heading,
    /// quote or list. This is the inverse of the serializer, which writes an
    /// already-parsed `str` verbatim: that byte survived a parse in place, whereas
    /// `text` is arbitrary input that has to be MADE safe.
    ///
    /// The escaping is positional. `Syntax.text_escapes` fires anywhere on the
    /// line (`*`, `` ` ``, `[`, `<`…); `Syntax.block_start_escapes` fires only
    /// while `offset` sits in its line's leading whitespace (`#`, `>`, `-`…),
    /// where those bytes open a block — so an inserted "5 - 3" keeps its `-` but
    /// an inserted "- item" at column zero does not become a bullet. An embedded
    /// newline in `text` re-enters that line-start zone for the bytes after it.
    ///
    /// Like the link ops, this guards the inserted run's OWN bytes; it does not
    /// reason about source already flanking `offset`. The shared
    /// splice+reparse+rollback path is the backstop: an insertion that somehow
    /// still corrupts the document yields `error.EditConflict` and changes
    /// nothing. `error.UnsupportedFormat` when the format can spell no literal
    /// (`text_escapes == null`), `error.InvalidRange` when `offset` is past the
    /// source.
    ///
    /// Two constructs a fixed byte-alphabet cannot reach, and so does not: a GFM
    /// bare-URL autolink (`https://x.com`, linkified with no delimiter to
    /// backslash) and an ordered-list marker (`1.`/`1)`, special only after a
    /// digit run, not per-byte). Both mint at most a link or a list from
    /// literal-looking text, never corruption; a caller that must suppress them
    /// does so above this op.
    ///
    /// INSIDE A CODE SPAN, a code block or a raw node the run is written in
    /// `verbatim` position instead: the format reads that body literally, so a
    /// backslash format writes the bytes as they are (an escape there would
    /// SHOW its backslash) and an entity format still escapes. The one byte no
    /// position can hold is the span's own closing delimiter, which is the same
    /// "guards its own bytes" limit as above.
    ///
    /// The engine here decides WHERE each byte lands; the format decides how a
    /// byte is written there. That split is `Syntax.renderText`: Markdown, djot
    /// and AsciiDoc share one renderer over their alphabets, and HTML — which
    /// has no backslash to spell a literal with — writes entities. The editor
    /// never sees either rule.
    pub fn insertLiteral(self: *Editor, offset: usize, text: []const u8) Error!void {
        try self.checkRange(offset, offset);
        const render = self.syntax.renderText orelse return error.UnsupportedFormat;

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();

        // At a line start iff every byte from this line's start up to `offset` is
        // leading whitespace — the same zone in which a block marker bites.
        var at_line_start = true;
        for (src[locate.lineStartAt(src, offset)..offset]) |c| {
            if (c != ' ' and c != '\t') {
                at_line_start = false;
                break;
            }
        }

        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        const in_verbatim = try self.insideVerbatim(offset);
        writeLiteral(self.syntax, render, text, at_line_start, in_verbatim, &out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return self.commitSplice(offset, offset, out.written());
    }

    /// Whether writing at `offset` lands inside a body the format reads
    /// LITERALLY — a code span, a code block, a raw node — where the inline and
    /// block-start alphabets mean nothing. Inclusive at both ends of the body
    /// (`content_span`), because text written flush against either delimiter
    /// still ends up inside it; a node with no interior is a leaf whose bytes
    /// ARE its delimiters, and a splice at its edge lands beside it.
    fn insideVerbatim(self: *const Editor, offset: usize) Allocator.Error!bool {
        const doc = &self.splicer.doc;
        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(self.splicer.allocator);
        try locate.ancestorChain(self.splicer.allocator, doc, offset, &chain);
        for (chain.items) |id| {
            const literal = switch (doc.ast.nodes[id].kind) {
                .code_block, .raw_block, .raw_inline => true,
                .text_leaf => |l| switch (l.kind) {
                    .verbatim, .inline_math, .display_math => true,
                    else => false,
                },
                else => false,
            };
            if (!literal) continue;
            const cs = doc.contentSpan(id) orelse continue;
            if (cs.start <= offset and offset <= cs.end) return true;
        }
        return false;
    }

    /// Insert a hard line break *inside a table cell* at `offset`, spelled the
    /// format's way (`Syntax.cell_line_break` — `<br>` for Markdown). A row is a
    /// single source line, so this is the one break the cell can hold; the
    /// spliced `<br>` reparses as a `hard_break` in cell context (see
    /// `markdown/inline.zig`), so the caller reads back a semantic node, not raw
    /// HTML. In HTML itself `<br>` is not borrowed at all — it is simply the
    /// break, and the cell restriction here understates what the format allows.
    ///
    /// Errors:
    /// - `UnsupportedFormat` — the format has no in-cell break spelling (djot,
    ///   XML). Checked first: it is a property of the format, not the caret.
    /// - `NoBlock` — `offset` is not inside a table cell. Only the in-cell
    ///   gesture is spelled today; a general (non-cell) hard break is future work.
    /// - `EditConflict` — the splice would no longer parse as the same table; the
    ///   splicer rolled it back and nothing changed (the standard contract).
    pub fn insertLineBreak(self: *Editor, offset: usize) Error!void {
        try self.checkRange(offset, offset);

        // Format capability before caret position: a format with no in-cell
        // break spelling can never satisfy this gesture, wherever the caret is.
        const spelling = self.syntax.cell_line_break orelse return error.UnsupportedFormat;

        const allocator = self.splicer.allocator;

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, &self.splicer.doc, offset, &chain);
        if (locate.innermostOfKind(&self.splicer.doc, chain.items, .cell) == null) return error.NoBlock;

        return self.commitSplice(offset, offset, spelling);
    }
};

// ── Block-container internals ──────────────────────────────────────────────

/// The blocks `[start, end)` touches: sibling `first`…`last` under the nearest
/// ancestor whose children are blocks. You cannot quote half a paragraph, so a
/// container op always widens to whole blocks first.
const BlockRange = struct {
    first: AST.Node.Id,
    last: AST.Node.Id,
    /// The ancestor chain down to `start`, reused for container detection.
    chain: []const AST.Node.Id,
};

/// Resolve `[start, end)` to the sibling blocks it touches. `end` is pulled back
/// off a trailing newline first: a block's span stops at its text in Markdown,
/// so a selection ending on the line break would otherwise resolve above the
/// block and drag the whole document in.
fn coveredBlocks(
    allocator: Allocator,
    doc: *const Document,
    start: usize,
    end: usize,
) !BlockRange {
    var last_off = if (end > start) end - 1 else start;
    while (last_off > start and (doc.source[last_off] == '\n' or doc.source[last_off] == '\r')) last_off -= 1;

    var chain_a: std.ArrayList(AST.Node.Id) = .empty;
    errdefer chain_a.deinit(allocator);
    try locate.ancestorChain(allocator, doc, start, &chain_a);

    var chain_b: std.ArrayList(AST.Node.Id) = .empty;
    defer chain_b.deinit(allocator);
    try locate.ancestorChain(allocator, doc, last_off, &chain_b);

    var i: usize = 0;
    while (i + 1 < chain_a.items.len and i + 1 < chain_b.items.len and
        chain_a.items[i + 1] == chain_b.items[i + 1]) : (i += 1)
    {}
    // Climb to the nearest ancestor that holds blocks: the deepest shared node
    // may be an inline (a `str`), and a container wraps blocks, not words.
    var p = i;
    while (p > 0 and !locate.isBlockParent(doc.ast.nodes[chain_a.items[p]].kind)) p -= 1;

    if (p + 1 >= chain_a.items.len) return error.NoBlock;
    const first = chain_a.items[p + 1];
    const last = if (p + 1 < chain_b.items.len) chain_b.items[p + 1] else first;
    return .{
        .first = first,
        .last = last,
        .chain = try chain_a.toOwnedSlice(allocator),
    };
}

/// True when the range's lines cover every block `target` holds — the condition
/// for toggling the container OFF rather than nesting inside it.
///
/// The test is "are all its blocks covered?", NOT "is its span inside the
/// region?": a container's span can run past its last block, because the blank
/// `>` line continuing a quote belongs to the quote and to no paragraph in it
/// (Djot spans `> > a\n>\n` as the inner quote, ending two bytes past its only
/// paragraph). Comparing spans there reads a fully-covered quote as partial and
/// nests forever.
fn containerFullyCovered(
    doc: *const Document,
    target: AST.Node.Id,
    region_start: usize,
    region_end: usize,
) bool {
    const first = doc.ast.nodes[target].first_child orelse return false;
    var last = first;
    var cur: ?AST.Node.Id = first;
    while (cur) |c| {
        last = c;
        cur = doc.ast.nodes[c].next_sibling;
    }
    const lo = locate.lineStartAt(doc.source, doc.span(first).start);
    const hi = locate.lineEndAt(doc.source, doc.span(last).end -| 1);
    return region_start <= lo and region_end >= hi;
}

/// The node `toggleBlockContainerByRender` builds for a `ContainerKind`. A
/// list built here is decimal from 1: a fresh list has no other numbering to
/// keep, and the marker path's `1. ` says the same.
fn containerNodeKind(kind: syntax_mod.ContainerKind, tight: bool) AST.Node.Kind {
    return switch (kind) {
        .block_quote => .block_quote,
        .bullet_list => .{ .bullet_list = .{ .tight = tight } },
        .ordered_list => .{ .ordered_list = .{ .numbering = .decimal, .tight = tight, .start = null } },
    };
}

/// Where a splice over a block span ENDS: the span's end, minus the line end
/// some parsers fold into a block's span after its closing bytes. A rendered
/// fragment carries no trailing line end (`spliceRendered` trims it), so
/// leaving the source's in place is what keeps the next block on its own line.
fn blockSpanEnd(src: []const u8, span: Span) usize {
    var end = span.end;
    if (end > span.start and src[end - 1] == '\n') end -= 1;
    if (end > span.start and src[end - 1] == '\r') end -= 1;
    return end;
}

/// The render path's `containerFullyCovered`: true when the covered blocks
/// hold `target` whole, or reach from the FIRST leaf block under its first
/// child to the LAST under its last — the tree's statement of "every line the
/// container holds", for a format whose lines say nothing. `blocks.first` may
/// be an ancestor of that leaf (a nested list the range covers whole), which
/// is why each end tests a path and not a node.
fn coversContainer(ast: *const AST, target: AST.Node.Id, blocks: BlockRange) bool {
    // The range covers a block that holds `target` whole — a list selected
    // from outside it, the way a range over every line of one is. Both are
    // on the chain to the range's start, so the shallower one contains the
    // other.
    const first_at = std.mem.indexOfScalar(AST.Node.Id, blocks.chain, blocks.first).?;
    const target_at = std.mem.indexOfScalar(AST.Node.Id, blocks.chain, target).?;
    if (first_at <= target_at) return true;

    const first = ast.nodes[target].first_child orelse return false;
    var last = first;
    while (ast.nodes[last].next_sibling) |n| last = n;
    return onEdgePath(ast, first, blocks.first, .first) and onEdgePath(ast, last, blocks.last, .last);
}

/// Whether `node` lies on the path of first (or last) children descending
/// from `from`, `from` itself included.
fn onEdgePath(ast: *const AST, from: AST.Node.Id, node: AST.Node.Id, edge: enum { first, last }) bool {
    var cur = from;
    while (true) {
        if (cur == node) return true;
        cur = ast.nodes[cur].first_child orelse return false;
        if (edge == .last) {
            while (ast.nodes[cur].next_sibling) |n| cur = n;
        }
    }
}

/// The empty container of `kind` the caret sits in, if the innermost node on
/// `chain` is one — or is an empty item that is the ONLY child of one — so
/// that `openContainerByRender` can take it back off. `null` otherwise.
fn emptyContainerOf(ast: *const AST, chain: []const AST.Node.Id, kind: syntax_mod.ContainerKind) ?AST.Node.Id {
    if (chain.len == 0) return null;
    const deepest = chain[chain.len - 1];
    if (ast.nodes[deepest].first_child != null) return null;
    const tag = std.meta.activeTag(ast.nodes[deepest].kind);
    if (tag == kindTag(kind)) return deepest;
    if (tag == .list_item and chain.len >= 2) {
        const list = chain[chain.len - 2];
        const only = ast.nodes[list].first_child == deepest and ast.nodes[deepest].next_sibling == null;
        if (only and std.meta.activeTag(ast.nodes[list].kind) == kindTag(kind)) return list;
    }
    return null;
}

/// The TEXT of a subtree, for a code block's payload: every text payload in
/// order, a break as a line end, and a line end between sibling blocks. This
/// is `select.textOf` with the breaks kept as breaks rather than folded to
/// spaces — a listing is the one place a paragraph's line structure is the
/// content, so a `<br>` in a poem becomes the line end it displayed as.
fn blockTextInto(allocator: Allocator, ast: *const AST, id: AST.Node.Id, out: *std.ArrayList(u8)) Allocator.Error!void {
    switch (ast.nodes[id].kind) {
        .str => |t| try out.appendSlice(allocator, t),
        .text_leaf => |l| try out.appendSlice(allocator, l.text),
        .smart_punctuation => |v| try out.appendSlice(allocator, v.ascii()),
        .raw_inline => |v| try out.appendSlice(allocator, v.text),
        .code_block => |v| try out.appendSlice(allocator, v.text),
        .raw_block => |v| try out.appendSlice(allocator, v.text),
        .non_breaking_space => try out.append(allocator, ' '),
        .soft_break, .hard_break => try out.append(allocator, '\n'),
        else => {
            var child = ast.nodes[id].first_child;
            var first = true;
            while (child) |c| : (child = ast.nodes[c].next_sibling) {
                if (!first and ast.nodes[c].kind.level() == .block) try out.append(allocator, '\n');
                try blockTextInto(allocator, ast, c, out);
                first = false;
            }
        },
    }
}

/// How many quotes enclose `target` on the chain — the number of `>` markers to
/// step over before the one that belongs to `target`.
fn quoteDepthAbove(ast: *const AST, chain: []const AST.Node.Id, target: AST.Node.Id) usize {
    var depth: usize = 0;
    for (chain) |id| {
        if (id == target) break;
        if (std.meta.activeTag(ast.nodes[id].kind) == .block_quote) depth += 1;
    }
    return depth;
}

// ── Join internals ─────────────────────────────────────────────────────────

/// The interior of a BLOCK, for the formats whose parsers record one and for
/// the ones that do not — `Editor.joinBlocks` needs both halves of a block's
/// bytes (its content, and the markup around it) and AsciiDoc's parser records
/// no `content_span` at all.
///
/// The fallback is the marker: a block with a leading marker holds its content
/// from the marker's end to its own end, and one with neither a content span
/// nor a marker is all content. That is a reconstruction, not a guess — it is
/// the same relation `Document.node_content_spans` states for the parsers that
/// do fill it in, read off `node_marker_spans` instead.
fn blockContent(doc: *const Document, id: AST.Node.Id) Span {
    if (doc.contentSpan(id)) |c| return c;
    const sp = doc.span(id);
    if (doc.markerSpan(id)) |m| {
        if (m.end >= sp.start and m.end <= sp.end) return Span.init(m.end, sp.end);
    }
    // Neither: the INLINE CHILDREN are where the text is, and the block's own
    // span is not. AsciiDoc is the format that forces this — a paragraph's
    // span opens at its METADATA (`[.lead]`, a `.Title` line), which is markup
    // and not content, and nothing records where it ends. Handing the whole
    // span back spliced those bytes into the middle of the joined line, so
    // `above` + `[.lead]`/`below` read `above`/`[.lead]`/`below` with the
    // attribute line now literal text. The first child's start and the last
    // child's end are the same relation `node_content_spans` states, read off
    // the tree where no span table answers.
    var it = doc.children(id);
    const first = it.next() orelse return sp;
    var last = first.id;
    while (it.next()) |child| last = child.id;
    const start = doc.span(first.id).start;
    const end = doc.span(last).end;
    if (start >= sp.start and end <= sp.end and start <= end) return Span.init(start, end);
    return sp;
}

/// A's tail with its trailing SEPARATOR LINES removed — what is left is the
/// closing markup and the closers `joinBlocks`'s doc comment says travel past
/// the joined text, and nothing else.
///
/// A container's span can reach past its last block: a Markdown `block_quote`
/// covers its own trailing marker lines (`> a\n>\n` is `0..5`), so the tail of
/// `a` there is `"\n>\n"` — a `>` line that, written after the joined text,
/// left a stray quote line below it, and piled one up per join. Those lines
/// separate; they close nothing.
///
/// WHOLE LINES only, which is the whole care needed here: `</div>` ends in a
/// `>`, and a byte-wise trim over the same alphabet would eat it and unclose
/// the div. The line end this drops is put back by `joinBlocks`'s
/// trailing-terminator rule wherever the removal took one.
fn trimTailSeparators(tail: []const u8) []const u8 {
    var end = tail.len;
    while (std.mem.lastIndexOfScalar(u8, tail[0..end], '\n')) |nl| {
        if (!isSeparatorRun(tail[nl + 1 .. end])) break;
        end = nl;
    }
    return tail[0..end];
}

/// Whether `bytes` are only what SEPARATES two blocks: line ends, spaces, tabs
/// and quote markers. A `>` is separation because a quote's marker is on every
/// line of it, blank ones included.
fn isSeparatorRun(bytes: []const u8) bool {
    for (bytes) |c| switch (c) {
        ' ', '\t', '\r', '\n', '>' => {},
        else => return false,
    };
    return true;
}

/// Whether the region between A's and B's topmost ancestors below the LCA
/// holds nothing the join would destroy. `joinBlocks`'s one data-loss guard.
///
/// The splice writes `[A.ce, R_end)` out of A's tail and B's content alone, so
/// whatever else lies in there is gone. Neither walk that found A and B can
/// see all of it. `precedingLeafBlock` steps over any node HOLDING NO LEAF
/// BLOCK — an empty `<div>`, a bare `>`, a bare `-`, an empty djot `:::`
/// fence — and a Markdown LINK REFERENCE DEFINITION (`[ref]: /zed`), a
/// FOOTNOTE DEFINITION (`[^n]: note`) and a djot CAPTION (`^ caption`) are not
/// in the tree at all: Markdown keeps a definition as a lookup table and not
/// as a node, so no tree walk could be written that sees one. `alpha` +
/// `[ref]: /zed` + `beta` joined to `alpha\nbeta\n` and the definition, along
/// with every link that resolved through it, was simply gone.
///
/// So the region is read twice, once against each thing that can be true of
/// it:
///
///   * **No node that HOLDS BLOCKS may overlap it** other than the two
///     blocks' COMMON ANCESTORS, which necessarily do. `holdsBlocks` is the
///     same classifier `precedingLeafBlock` descends by, and that is why it is
///     the right one: a node in the gap holding a leaf block WOULD BE A, so
///     what can be in there is exactly what that walk stepped over. It is
///     also why a bare `>` is refused where the `>` of a quote holding both
///     blocks is not — the bytes are identical and the tree is not. Inline
///     nodes are passed over: HTML keeps the newline between two elements as
///     a `str`, and the byte rule below is what judges those bytes.
///   * **What is left may only SEPARATE**, by `isSeparatorRun` — with B's own
///     PREAMBLE peeled off the right first. That preamble is the run of
///     non-blank whole lines directly above B with no blank line between: a
///     djot attribute line (`{.center}`) sits there, outside the span the
///     parser gives B, and B's attributes are discarded by design. A
///     definition is a block, so a blank line divides it from B and the peel
///     never reaches one — and the node check above holds it anyway.
///
/// A's extent reaching PAST B's start is false here too. Nothing produces it
/// now that djot's section spans are right, and it would make A's tail a slice
/// running through B.
fn gapIsClean(
    doc: *const Document,
    src: []const u8,
    common: []const AST.Node.Id,
    a_top: AST.Node.Id,
    b_top: AST.Node.Id,
) bool {
    const start = doc.span(a_top).end;
    const b_start = doc.span(b_top).start;
    if (start > b_start or b_start > src.len) return false;

    for (doc.ast.nodes, 0..) |_, idx| {
        const id: AST.Node.Id = @intCast(idx);
        const sp = doc.span(id);
        if (sp.start >= b_start or sp.end <= start) continue;
        if (!holdsBlocks(doc, id)) continue;
        if (std.mem.indexOfScalar(AST.Node.Id, common, id) == null) return false;
    }

    var end = b_start;
    while (end > start and src[end - 1] == '\n') {
        const line_start = locate.lineStartAt(src, end - 1);
        if (line_start < start) break;
        if (isSeparatorRun(src[line_start .. end - 1])) break;
        end = line_start;
    }
    return isSeparatorRun(src[start..end]);
}

/// B's content written as ONE LINE — what a marker heading A can hold. Each of
/// B's line ends becomes a single space, and the CONTINUATION PREFIX behind it
/// (a list item's indent, a quote's `> `) goes with it, since a heading's one
/// line sits behind its own prefix already.
fn appendAsOneLine(
    allocator: Allocator,
    text: []const u8,
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        try out.appendSlice(allocator, std.mem.trimEnd(u8, rest[0..nl], " \t\r"));
        try out.append(allocator, ' ');
        rest = rest[nl + 1 ..];
        var k: usize = 0;
        while (k < rest.len and (rest[k] == ' ' or rest[k] == '\t' or rest[k] == '>')) k += 1;
        rest = rest[k..];
    }
    try out.appendSlice(allocator, rest);
}

/// B's content written as a CONTINUATION LINE of A, which is one byte more
/// than verbatim in exactly one shape.
///
/// A line of `=` or `-` under a paragraph is a SETEXT UNDERLINE, and it is the
/// only line-start construct that rewrites the block ABOVE it rather than
/// opening one of its own: `above` + `===` joined to `above\n===\n` reparsed
/// as a single heading and no paragraph at all — B's text became A's spelling.
/// A backslash on its first byte is what `insertLiteral` writes for the same
/// bytes at the same position, and `\` before ASCII punctuation is that
/// character in every format stating the alphabet, so the gate is
/// `block_start_escapes` being stated at all.
///
/// Nothing else is escaped, and that is deliberate: `#`, `>`, `-` + space, a
/// table's `|` all open a BLOCK of their own as a continuation line, so the
/// join merely fails to merge two blocks into one — it does not rewrite A.
fn appendAsContinuation(
    allocator: Allocator,
    syntax: *const Syntax,
    text: []const u8,
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    if (syntax.block_start_escapes != null and isUnderlineLine(text)) {
        const lead = text.len - std.mem.trimStart(u8, text, " \t").len;
        try out.appendSlice(allocator, text[0..lead]);
        try out.append(allocator, '\\');
        try out.appendSlice(allocator, text[lead..]);
        return;
    }
    try out.appendSlice(allocator, text);
}

/// Whether `text`'s FIRST line is a run of `=` or a run of `-` and nothing
/// else — a setext underline, whichever level it spells.
fn isUnderlineLine(text: []const u8) bool {
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const trimmed = std.mem.trim(u8, first, " \t\r");
    if (trimmed.len == 0) return false;
    for (trimmed) |c| if (c != trimmed[0]) return false;
    return trimmed[0] == '=' or trimmed[0] == '-';
}

/// Whether `id` is a heading spelled by an UNDERLINE rather than by a marker —
/// Markdown's setext form, the one `Editor.splitBlock` refuses for its own half
/// and `joinBlocks` refuses for B.
///
/// Three conditions, and all three are needed. No recorded marker rules out
/// every ATX-ish heading (`# x`, AsciiDoc's `== x`). Content starting where the
/// block does rules out a WRAPPING spelling — an HTML `<h1>a</h1>` records no
/// marker either, and its content starts after the opening tag. Content ending
/// before the block does is the underline itself.
fn isSetextHeading(doc: *const Document, id: AST.Node.Id) bool {
    if (std.meta.activeTag(doc.ast.nodes[id].kind) != .heading) return false;
    if (doc.markerSpan(id) != null) return false;
    const content = doc.contentSpan(id) orelse return false;
    const sp = doc.span(id);
    return content.start == sp.start and content.end < sp.end;
}

/// Whether a node on `chain` is a table. A table's cells hold paragraphs, so a
/// `para` inside one is a perfectly ordinary leaf block to the walks below —
/// and joining one into the cell above it, or into the paragraph before the
/// table, is not a join of two lines but a hole in a grid. Stated as a chain
/// test rather than as a kind test for exactly that reason: what is refused is
/// the POSITION, not the node.
fn passesThroughTable(doc: *const Document, chain: []const AST.Node.Id) bool {
    for (chain) |id| {
        if (std.meta.activeTag(doc.ast.nodes[id].kind) == .table) return true;
    }
    return false;
}

/// The path of node ids from the root down to `target`, appended to `out`.
///
/// A tree walk rather than `locate.ancestorChain`, which descends by OFFSET: two
/// nodes can share a start byte (a Markdown `list_item` and its first `para`
/// both begin at column zero), so an offset names a path and not a node.
/// `joinBlocks` already holds the node, and what it needs is that node's own
/// ancestors — for the lowest common ancestor, which is what decides how much
/// of A's closing markup has to travel.
fn nodePath(
    allocator: Allocator,
    doc: *const Document,
    target: AST.Node.Id,
    out: *std.ArrayList(AST.Node.Id),
) Allocator.Error!bool {
    try out.append(allocator, doc.ast.root);
    if (target == doc.ast.root) return true;
    if (try descendTo(allocator, doc, doc.ast.root, target, out)) return true;
    out.clearRetainingCapacity();
    return false;
}

fn descendTo(
    allocator: Allocator,
    doc: *const Document,
    id: AST.Node.Id,
    target: AST.Node.Id,
    out: *std.ArrayList(AST.Node.Id),
) Allocator.Error!bool {
    var it = doc.children(id);
    while (it.next()) |child| {
        try out.append(allocator, child.id);
        if (child.id == target) return true;
        if (try descendTo(allocator, doc, child.id, target, out)) return true;
        _ = out.pop();
    }
    return false;
}

/// True for a node that HOLDS BLOCKS, and so is a container the leaf walks
/// below descend into rather than a block they stop at.
///
/// `contentModel` is the classifier rather than a hand-kept list, because it is
/// already the exhaustive answer to this exact question and a new kind has to
/// declare one. It puts a `table` on the container side — its rows hold cells
/// which hold paragraphs — which is why `passesThroughTable` exists rather than
/// a "is a table a leaf?" special case here.
fn holdsBlocks(doc: *const Document, id: AST.Node.Id) bool {
    return doc.ast.nodes[id].kind.contentModel() == .blocks;
}

/// The last LEAF BLOCK inside `root`'s subtree in document order, or `null` when
/// it holds none — how `joinBlocks` asks whether B is the last thing in a
/// delimited container it is about to pull out of.
fn lastLeafBlock(doc: *const Document, root: AST.Node.Id) ?AST.Node.Id {
    if (!holdsBlocks(doc, root)) return root;
    var last: ?AST.Node.Id = null;
    var it = doc.children(root);
    while (it.next()) |child| {
        if (lastLeafBlock(doc, child.id)) |leaf| last = leaf;
    }
    return last;
}

/// The leaf block immediately before `target` in DOCUMENT ORDER — the block a
/// caret at the start of `target` has visually above it, wherever in the tree
/// that is. `null` when `target` is the document's first block.
///
/// Document order rather than sibling order is the whole point: the block above
/// a paragraph following a `<div>` is the div's LAST paragraph, and the block
/// above the first paragraph INSIDE the div is whatever preceded the div.
/// Sibling order answers "the div" to the first and "nothing" to the second,
/// and both are the wrong block to join into.
fn precedingLeafBlock(doc: *const Document, target: AST.Node.Id) ?AST.Node.Id {
    var state: PrecedingLeaf = .{ .doc = doc, .target = target };
    scanLeaves(&state, doc.ast.root);
    return if (state.found) state.last else null;
}

const PrecedingLeaf = struct {
    doc: *const Document,
    target: AST.Node.Id,
    last: ?AST.Node.Id = null,
    found: bool = false,
};

fn scanLeaves(state: *PrecedingLeaf, id: AST.Node.Id) void {
    if (id == state.target) {
        state.found = true;
        return;
    }
    if (!holdsBlocks(state.doc, id)) {
        state.last = id;
        return;
    }
    var it = state.doc.children(id);
    while (it.next()) |child| {
        scanLeaves(state, child.id);
        if (state.found) return;
    }
}

/// What `Editor.splitBlock` does with a block of a given kind. Having ONE
/// exhaustive switch answer this — rather than a "can I split it?" predicate
/// beside the switch that builds the separator — is what keeps `splitTarget`
/// and the builder from drifting apart about which kinds are splittable.
const SplitShape = enum { text, code, refuse };

/// Spelled out rather than left to an `else`, so a new `Kind` is a compile error
/// here and gets an answer on purpose — this switch is the checklist.
fn splitShape(tag: locate.KindTag) SplitShape {
    return switch (tag) {
        // The line-owning text blocks: a blank line divides them, unless a list
        // item's marker has to be repeated instead.
        .para, .heading => .text,
        .code_block => .code,

        // Structure whose parts are not lines, or containers a split would have
        // to descend into rather than divide.
        .table,
        .doc,
        .section,
        .block_quote,
        .bullet_list,
        .ordered_list,
        .task_list,
        .definition_list,
        .line_block,
        .list_item,
        .task_list_item,
        .definition_list_item,
        .term,
        .definition,
        .line,
        .row,
        .cell,
        .column,
        .caption,
        .footnote,
        .reference,
        .citation,
        .substitution,
        .container,
        // Blocks with no interior to divide: a rule is one line, and metadata
        // and raw blocks are inert islands whose bytes are not ours to
        // punctuate.
        .thematic_break,
        .metadata,
        .raw_block,
        // Inlines. `lineOwningBlock` cannot return one — it stops at a block
        // parent's child — but naming them is what keeps this exhaustive, and a
        // refusal is the right answer if that ever changes.
        .str,
        .soft_break,
        .hard_break,
        .non_breaking_space,
        .text_leaf,
        .raw_inline,
        .smart_punctuation,
        .link,
        .image,
        .inline_mark,
        .markup_leaf,
        .processing_instruction,
        => .refuse,
    };
}

/// The block `Editor.splitBlock` should divide for a caret at `offset`, which is
/// not simply "the block at `offset`" — because of where a caret at the END of a
/// block actually lands.
///
/// Spans are half-open, so a caret at a block's end is outside it. Whether it is
/// outside EVERYTHING depends on the format, and the two authorable ones
/// disagree: djot's `list_item` covers its trailing newline (`[0,6)` for
/// `- one\n`), while Markdown's stops before it (`[0,5)`). So for
/// `- one|\n- two\n` the caret at 5 is inside djot's item but, in Markdown, in
/// the GAP between two items — inside the `bullet_list` and inside no item at
/// all. A lookup that trusts the deepest hit gets the LIST, which is not
/// splittable, and "Enter at the end of an item" — the single most common way
/// this gesture is asked for — fails on the format where lists are commonest.
///
/// Retrying one byte back is therefore not a null-check: the answer at `offset`
/// can be non-null and still wrong. What makes it wrong is that it isn't
/// splittable, so that is what the retry keys on. A caret in any gap resolves to
/// the block that just ENDED, which is where the text cursor visually sits.
///
/// When neither position yields a splittable block the ORIGINAL is returned, so
/// a genuine refusal (a caret in a table) still reports `NotEditable` against
/// the block the caller actually pointed at rather than `NoBlock`.
fn splitTarget(doc: *const Document, offset: usize) ?locate.LineBlock {
    const at = locate.lineOwningBlock(doc, offset);
    if (at) |lb| {
        if (splitShape(std.meta.activeTag(doc.ast.nodes[lb.block].kind)) != .refuse) return lb;
    }
    if (offset > 0) {
        if (locate.lineOwningBlock(doc, offset - 1)) |back| {
            if (splitShape(std.meta.activeTag(doc.ast.nodes[back.block].kind)) != .refuse) return back;
        }
    }
    return at;
}

/// Advance past one `>` quote marker — its optional indent, the `>`, and the one
/// optional space after it — or `null` if `line[i..]` doesn't start one.
/// Whether the line ENDING at `line_start` carries content — anything past its
/// own quote markers. `false` at the start of the source, where there is no
/// preceding line to run into.
///
/// What `openBlockOnBlankLine` consults to decide whether it must mint a blank
/// separator: a marker written flush under a paragraph line is that paragraph's
/// text in djot, not a heading.
fn precedingLineHasContent(src: []const u8, line_start: usize) bool {
    if (line_start == 0) return false;
    const prev = locate.lineBody(src[locate.lineStartAt(src, line_start - 1)..line_start]);
    var i: usize = 0;
    while (skipQuoteMarker(prev, i)) |j| i = j;
    return !locate.isBlankLine(prev[i..]);
}

/// The marker that opens `sp`'s `ordinal`-th item — `sp.marker` for a fixed
/// spelling, the ordinal itself for a numbered one, which is why `buf` is the
/// caller's (the returned slice borrows it).
///
/// Shared by `buildContainerAdd`, which writes one per covered block, and
/// `openContainerOnBlankLine`, which writes exactly one: `1. ` and `- ` have to
/// be spelled the same by both, and two `{d}. ` format strings is one too many.
fn listMarker(sp: ContainerSpelling, ordinal: u32, buf: *[24]u8) []const u8 {
    if (!sp.numbered) return sp.marker;
    return std.fmt.bufPrint(buf, "{d}. ", .{ordinal}) catch unreachable;
}

/// Whether the byte opening a list marker (`listMarkerAt`'s `start`) opens an
/// ORDERED one — a digit, or the `(` of `(1)`. The complement is a `-`/`*`/`+`
/// bullet. Lets `openContainerOnBlankLine` tell "the same button again" from
/// "the other list button" against `ContainerSpelling.numbered`.
fn isOrderedMarker(c: u8) bool {
    return c == '(' or c == '.' or (c >= '0' and c <= '9');
}

fn skipQuoteMarker(line: []const u8, i: usize) ?usize {
    var j = i;
    var indent: usize = 0;
    while (j < line.len and line[j] == ' ' and indent < 3) : (indent += 1) j += 1;
    if (j >= line.len or line[j] != '>') return null;
    j += 1;
    if (j < line.len and line[j] == ' ') j += 1;
    return j;
}

/// The `[start, end)` of a list marker on `line`, scanning from `from` —
/// `start` at the bullet/first digit (so the indent before it stays put, keeping
/// an enclosing container's prefix intact) and `end` past the marker's trailing
/// spaces. `null` if the line doesn't open a list item.
///
/// `from` is how a caller skips a prefix the marker sits after: the checkbox
/// gestures pass the end of the line's quote markers, so `> - [ ] a` is found.
/// The container builders pass 0, which is the whole line.
fn listMarkerAt(line: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var j: usize = from;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
    const start = j;
    if (j >= line.len) return null;
    if (line[j] == '-' or line[j] == '*' or line[j] == '+') {
        j += 1;
    } else if (line[j] == '.') {
        // AsciiDoc's ordered marker: a run of dots, its depth its nesting.
        while (j < line.len and line[j] == '.') j += 1;
    } else {
        if (line[j] == '(') j += 1;
        var digits: usize = 0;
        while (j < line.len and line[j] >= '0' and line[j] <= '9') : (digits += 1) j += 1;
        if (digits == 0) return null;
        if (j >= line.len or (line[j] != '.' and line[j] != ')')) return null;
        j += 1;
    }
    // A marker must be followed by whitespace (or end the line): `-x` is a
    // paragraph starting with a hyphen, not a bullet.
    if (j < line.len and line[j] != ' ' and line[j] != '\n' and line[j] != '\r') return null;
    while (j < line.len and line[j] == ' ') j += 1;
    return .{ .start = start, .end = j };
}

/// True if one of the covered blocks begins on `[line_start, line_end)` — the
/// test for "this line opens a new list item". Djot starts a quoted block at its
/// text (after `> `), Markdown at the line start; either way it lands on the
/// block's first line, which is all this asks.
fn blockStartsOnLine(doc: *const Document, blocks: BlockRange, line_start: usize, line_end: usize) bool {
    var cur: ?AST.Node.Id = blocks.first;
    while (cur) |id| {
        const s = doc.span(id).start;
        if (s >= line_start and s < line_end) return true;
        if (id == blocks.last) break;
        cur = doc.ast.nodes[id].next_sibling;
    }
    return false;
}

/// True if one of `list`'s items begins on `[line_start, line_end)`.
fn itemStartsOnLine(doc: *const Document, list: AST.Node.Id, line_start: usize, line_end: usize) bool {
    var it = doc.children(list);
    while (it.next()) |item| {
        const s = doc.span(item.id).start;
        if (s >= line_start and s < line_end) return true;
    }
    return false;
}

/// Wrap every line of `[region_start, region_end)` in `kind`'s prefix, one item
/// per covered block. The lines already carry any enclosing container's prefix,
/// so prefixing at column 0 nests naturally (`> a` -> `> > a`).
fn buildContainerAdd(
    allocator: Allocator,
    src: []const u8,
    doc: *const Document,
    blocks: BlockRange,
    region_start: usize,
    region_end: usize,
    sp: ContainerSpelling,
    out: *std.ArrayList(u8),
) !void {
    var ordinal: u32 = 1;
    var cont: []const u8 = sp.cont;
    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = locate.lineEndAt(src, line_start);
        const line = src[line_start..line_end];
        const body = locate.lineBody(line);

        if (locate.isBlankLine(body)) {
            // A blank line inside the region: mark it for a quote (else the quote
            // ends here), leave it bare for a list (it separates items).
            if (sp.blank.len > 0) {
                try out.appendSlice(allocator, sp.blank);
                try out.appendSlice(allocator, line[body.len..]);
            } else {
                try out.appendSlice(allocator, line);
            }
            line_start = line_end;
            continue;
        }

        if (blockStartsOnLine(doc, blocks, line_start, line_end)) {
            var num_buf: [24]u8 = undefined;
            const marker = listMarker(sp, ordinal, &num_buf);
            if (sp.numbered) cont = container_indent[0..@min(marker.len, container_indent.len)];
            try out.appendSlice(allocator, marker);
            try out.appendSlice(allocator, line);
            ordinal += 1;
        } else {
            try out.appendSlice(allocator, cont);
            try out.appendSlice(allocator, line);
        }
        line_start = line_end;
    }
}

/// Strip the quote marker `target` contributes from each of its lines, leaving
/// any outer quote levels untouched: `depth` is how many quotes enclose it, so
/// the marker removed is the `depth`-th + 1 on every line. That's what makes
/// toggling off a nested quote peel exactly one level (`> > a` -> `> a`).
fn buildQuoteStrip(
    allocator: Allocator,
    src: []const u8,
    region_start: usize,
    region_end: usize,
    depth: usize,
    out: *std.ArrayList(u8),
) !void {
    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = locate.lineEndAt(src, line_start);
        const line = src[line_start..line_end];

        var keep: usize = 0;
        var d: usize = 0;
        while (d < depth) : (d += 1) keep = skipQuoteMarker(line, keep) orelse break;
        if (d == depth) {
            if (skipQuoteMarker(line, keep)) |after| {
                try out.appendSlice(allocator, line[0..keep]);
                try out.appendSlice(allocator, line[after..]);
                line_start = line_end;
                continue;
            }
        }
        // A line with no marker at this level (a lazy continuation) is already
        // outside the level being removed — pass it through untouched.
        try out.appendSlice(allocator, line);
        line_start = line_end;
    }
}

/// Rewrite the list `target`'s item markers: `sp == null` removes the list
/// (toggle off), otherwise it converts one list kind to the other in place. The
/// text before a marker (an enclosing quote's `> `, a nesting indent) is kept
/// verbatim; a block's continuation lines are re-indented to the new marker's
/// width so they stay attached to their item.
///
/// Removing a list has to keep its items separate BLOCKS: a tight `- a\n- b\n`
/// would strip to `a\nb\n`, which is one two-line paragraph, not two. So a blank
/// line is injected between items that had none — the structure the items had is
/// what survives, not their tightness.
fn buildListRewrite(
    allocator: Allocator,
    src: []const u8,
    doc: *const Document,
    target: AST.Node.Id,
    region_start: usize,
    region_end: usize,
    sp: ?ContainerSpelling,
    out: *std.ArrayList(u8),
) !void {
    var ordinal: u32 = 1;
    var old_width: usize = 0;
    var new_width: usize = 0;
    var seen_item = false;
    var last_blank = true;
    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = locate.lineEndAt(src, line_start);
        const line = src[line_start..line_end];
        const body = locate.lineBody(line);

        if (locate.isBlankLine(body)) {
            try out.appendSlice(allocator, line);
            last_blank = true;
            line_start = line_end;
            continue;
        }

        if (itemStartsOnLine(doc, target, line_start, line_end)) {
            // Only when the list is going away: a conversion keeps the items as
            // items, so it must not loosen a tight list.
            if (sp == null and seen_item and !last_blank) try out.append(allocator, '\n');
            const m = listMarkerAt(line, 0) orelse {
                try out.appendSlice(allocator, line);
                line_start = line_end;
                continue;
            };
            var num_buf: [24]u8 = undefined;
            const marker: []const u8 = if (sp) |s|
                (if (s.numbered)
                    std.fmt.bufPrint(&num_buf, "{d}. ", .{ordinal}) catch unreachable
                else
                    s.marker)
            else
                "";
            try out.appendSlice(allocator, line[0..m.start]);
            try out.appendSlice(allocator, marker);
            try out.appendSlice(allocator, line[m.end..]);
            old_width = m.end - m.start;
            new_width = marker.len;
            ordinal += 1;
            seen_item = true;
            last_blank = false;
        } else {
            // A continuation line: swap the old marker's indent for the new one's
            // so the line stays inside its item.
            var j: usize = 0;
            while (j < line.len and j < old_width and line[j] == ' ') j += 1;
            try out.appendSlice(allocator, container_indent[0..@min(new_width, container_indent.len)]);
            try out.appendSlice(allocator, line[j..]);
            last_blank = false;
        }
        line_start = line_end;
    }
}

/// One left-to-right rewrite of `[region_start, region_end)` that renumbers
/// ordered-list items by their indentation depth — the body of
/// [`Editor.renumberOrderedLists`], where its reasoning lives.
fn buildRenumber(
    allocator: Allocator,
    src: []const u8,
    region_start: usize,
    region_end: usize,
    item_lines: []const usize,
    out: *std.ArrayList(u8),
) !void {
    // A small stack of (indent column, next number), one entry per open nesting
    // level. Documents don't nest lists dozens deep; 32 is plenty and keeps this
    // allocation-free. A level deeper than 32 just isn't renumbered (copied).
    var cols: [32]usize = undefined;
    var nums: [32]u32 = undefined;
    var depth: usize = 0;

    // `item_lines` ascends and so does the walk, so one cursor answers "does an
    // item open here" for every line without a search.
    var next_item: usize = 0;

    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = locate.lineEndAt(src, line_start);
        const line = src[line_start..line_end];
        while (next_item < item_lines.len and item_lines[next_item] < line_start) next_item += 1;
        const opens_item = next_item < item_lines.len and item_lines[next_item] == line_start;
        // Past any `>` markers first. A quoted list's items sit BEHIND a prefix,
        // and scanning from column zero finds `>` where it wants a bullet or a
        // digit — so every line of `> 1. a` failed the marker test, the whole
        // region was copied verbatim, and the gesture reported success having
        // changed nothing. `splitMarker` skips the same way for the same reason.
        var from: usize = 0;
        while (skipQuoteMarker(line, from)) |j| from = j;
        const m = if (opens_item) listMarkerAt(line, from) else null;
        const numbered = if (m) |mm| isNumberedMarker(line[mm.start..mm.end]) else false;
        if (numbered) {
            const mm = m.?;
            // Leading whitespace measured from AFTER the quote prefix, not from
            // column zero: the prefix's own width is not this list's nesting
            // depth, and counting it would put a quoted top-level item at a
            // deeper level than an unquoted one.
            const indent = mm.start - from;
            // Drop levels deeper than this item; then resume this level or open it.
            while (depth > 0 and cols[depth - 1] > indent) depth -= 1;
            var number: u32 = 1;
            if (depth > 0 and cols[depth - 1] == indent) {
                number = nums[depth - 1];
                nums[depth - 1] += 1;
            } else if (depth < cols.len) {
                cols[depth] = indent;
                nums[depth] = 2; // this item is 1; its next sibling will be 2
                depth += 1;
            }
            // Emit: indentation, an optional `(`, the new number, then the
            // delimiter and everything after it verbatim.
            try out.appendSlice(allocator, line[0..mm.start]);
            var d = mm.start;
            if (d < line.len and line[d] == '(') {
                try out.append(allocator, '(');
                d += 1;
            }
            var num_buf: [16]u8 = undefined;
            const digits = std.fmt.bufPrint(&num_buf, "{d}", .{number}) catch unreachable;
            try out.appendSlice(allocator, digits);
            var k = d;
            while (k < line.len and line[k] >= '0' and line[k] <= '9') k += 1;
            try out.appendSlice(allocator, line[k..]);
        } else {
            // A bullet item, a blank line, or prose — including prose that LOOKS
            // like a marker but opens no item: verbatim. A bullet doesn't disturb
            // the ordered counters at other columns, and neither does prose.
            try out.appendSlice(allocator, line);
        }
        line_start = line_end;
    }
}

/// Whether a marker (as returned by `listMarkerAt`) is an ordered one — a run of
/// digits, allowing a leading `(` for the `(1)` form — rather than a bullet.
fn isNumberedMarker(marker: []const u8) bool {
    var j: usize = 0;
    if (j < marker.len and marker[j] == '(') j += 1;
    return j < marker.len and marker[j] >= '0' and marker[j] <= '9';
}

/// The run of QUOTE MARKERS opening the line `at` sits on — the prefix a new
/// block written beside it must repeat to stay in the same containers.
///
/// Quote markers only, because a quote's marker is on EVERY line it covers
/// while a list item's is on its first line alone — a list item holds its
/// content by indentation of the marker's width, which this cannot see from one
/// line. The callers differ on what to do about that gap: `insertThematicBreak`
/// accepts landing at column zero (it splits the list, corrupting nothing),
/// while `toggleCodeBlock` refuses, because there the same gap would pull the
/// item's marker into the code body.
fn containerPrefix(src: []const u8, at: usize) []const u8 {
    const line_start = locate.lineStartAt(src, at);
    const line = src[line_start..locate.lineEndAt(src, at)];
    var i: usize = 0;
    while (skipQuoteMarker(line, i)) |j| i = j;
    return line[0..i];
}

/// Whether `chain` passes through a list item — the containers `containerPrefix`
/// cannot reproduce, and so the ones a gesture that relies on it must refuse.
fn insideListItem(doc: *const Document, chain: []const AST.Node.Id) bool {
    for (chain) |id| {
        switch (std.meta.activeTag(doc.ast.nodes[id].kind)) {
            .list_item, .task_list_item => return true,
            else => {},
        }
    }
    return false;
}

// ── Code-fence internals ───────────────────────────────────────────────────

/// How many fence characters a fence over `body` needs: one more than the
/// longest run of `char` anywhere in it, floored at `min`. That is what lets a
/// code block hold a code block — the outer fence simply outgrows the inner one.
fn fenceWidth(body: []const u8, char: u8, min: usize) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (body) |c| {
        if (c != char) {
            run = 0;
            continue;
        }
        run += 1;
        if (run > longest) longest = run;
    }
    return @max(min, longest + 1);
}

/// The fence opening `line`: where its first character sits and how many there
/// are, after any quote prefix and up to three spaces of indentation. `null`
/// when the line opens no fence — which is not a malformed document but the
/// ordinary shape of a Markdown INDENTED code block.
fn fenceAt(line: []const u8, char: u8, min: usize) ?struct { start: usize, width: usize } {
    var i: usize = 0;
    while (skipQuoteMarker(line, i)) |j| i = j;
    var indent: usize = 0;
    while (i < line.len and line[i] == ' ' and indent < 3) : (indent += 1) i += 1;
    const start = i;
    while (i < line.len and line[i] == char) i += 1;
    return if (i - start >= min) .{ .start = start, .width = i - start } else null;
}

/// The interior of the code block occupying `[region_start, region_end)`, with
/// its framing removed — the body of `Editor.toggleCodeBlock`'s unfence half,
/// where its reasoning lives.
fn buildUnfence(
    allocator: Allocator,
    src: []const u8,
    region_start: usize,
    region_end: usize,
    fence: syntax_mod.CodeFence,
    out: *std.ArrayList(u8),
) !void {
    const first_end = locate.lineEndAt(src, region_start);
    if (fenceAt(src[region_start..first_end], fence.char, fence.min) == null) {
        // No opening fence: a Markdown indented code block, whose framing IS its
        // indentation. Four spaces is the marker; a line indented further keeps
        // the rest, which is the indentation the code itself carried.
        var line_start = region_start;
        while (line_start < region_end) {
            const line_end = locate.lineEndAt(src, line_start);
            const line = src[line_start..line_end];
            var j: usize = 0;
            while (j < line.len and j < 4 and line[j] == ' ') j += 1;
            try out.appendSlice(allocator, line[j..]);
            line_start = line_end;
        }
        return;
    }

    // Fenced: drop the opening line, and the closing one when there IS one — an
    // unterminated fence at the end of the document has no closing line, and its
    // last line is content that must survive.
    var body_end = region_end;
    const last_start = locate.lineStartAt(src, region_end -| 1);
    if (last_start >= first_end and
        fenceAt(src[last_start..region_end], fence.char, fence.min) != null)
    {
        body_end = last_start;
    }
    try out.appendSlice(allocator, src[first_end..@max(first_end, body_end)]);
}

/// Refuse an info string this format's fence cannot carry back out: a line end
/// (which would end the fence line), the fence character itself (which would
/// widen or close the fence), and whatever else the format forbids — Markdown
/// ends its info string at whitespace, so a space there would come back
/// truncated rather than broken, which is worse.
fn checkInfoString(fence: syntax_mod.CodeFence, lang: []const u8) Editor.Error!void {
    if (std.mem.indexOfAny(u8, lang, "\r\n") != null) return error.InvalidLanguage;
    if (std.mem.indexOfScalar(u8, lang, fence.char) != null) return error.InvalidLanguage;
    if (std.mem.indexOfAny(u8, lang, fence.info_forbids) != null) return error.InvalidLanguage;
}

/// Refuse a directive name that would not come back as the name of a
/// container. The grammar is `markdown/attributes.zig`'s `scanName` — an ASCII
/// letter, then letters, digits, `-` and `_` — minus the colon that one also
/// admits, and it is checked HERE, once, rather than per format, because a
/// name is written where a delimiter would otherwise be in every spelling of
/// one. The failures are not subtle and they differ per format, which is
/// exactly why the editor takes the intersection:
///
///   * A SPACE: Markdown reads `::a b` as a paragraph holding an INLINE
///     directive named `a`, djot reads `::: a b` as a paragraph of literal
///     colons, and HTML truncates `<a b>` to a tag named `a` with an
///     attribute. Three different wrong answers from one gesture.
///   * A BRACKET or a brace: `::]{ ` is no container at all, in any of them.
///   * A LEADING DIGIT: Markdown's own `scanName` requires a letter, so
///     `::1x` is a paragraph — the rule that keeps `:30` from being a name.
///   * A COLON is the one Markdown itself would accept, and djot would not:
///     its class grammar has none, so `::: a:b` reparses as a paragraph. A
///     format-neutral gesture cannot mint a name only some formats read.
///
/// Case is not checked, because it is not a refusal: HTML folds a tag name, so
/// an upper-case name comes back lower-cased there while every other format
/// keeps it. That is a spelling difference, not a lost node.
/// The grammar an attribute must fit for every format to read it back: a key
/// that is an ASCII letter or `_` followed by letters, digits, `-`, `_` and
/// `:` (the intersection of djot's, Markdown's and HTML's attribute names), a
/// value — a BARE key is HTML's alone; djot's `{…}` has no spelling for one
/// and reads the whole block as text — and no line end or double quote in
/// it, the two bytes a quoted value cannot hold in every spelling at once.
fn checkAttr(kv: AST.KeyVal) Editor.Error!void {
    if (kv.key.len == 0) return error.InvalidAttribute;
    if (!std.ascii.isAlphabetic(kv.key[0]) and kv.key[0] != '_') return error.InvalidAttribute;
    for (kv.key[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != ':') return error.InvalidAttribute;
    }
    const value = kv.value orelse return error.InvalidAttribute;
    if (std.mem.indexOfAny(u8, value, "\r\n\"") != null) return error.InvalidAttribute;
}

fn checkDirectiveName(name: []const u8) Editor.Error!void {
    if (name.len == 0) return error.InvalidName;
    if (!std.ascii.isAlphabetic(name[0])) return error.InvalidName;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidName;
    }
}

// ── Task-checkbox internals ────────────────────────────────────────────────

/// Where a list item's checkbox is, or would go. `box` is the brackets and what
/// is between them and NOTHING else — `space` counts the separator after it
/// separately, because ticking a box must not touch the author's spacing while
/// removing one must take the separator with it.
const TaskBox = struct {
    at: usize,
    box: ?Span,
    space: usize,
    checked: bool,
};

// ── Footnote internals ─────────────────────────────────────────────────────

/// Whether `label` already has a DEFINITION in this tree.
///
/// A linear scan of `ast.nodes` rather than a walk from the root, because a
/// footnote definition is attached to no parent: both parsers resolve them by
/// label, not by position, so the node is a detached root that a child walk
/// never reaches.
/// `checkInfoString` for the render path, which has no fence to measure
/// against: a language is ONE TOKEN in every format that spells one — a
/// `class="language-…"` splits on whitespace as an info string ends at it —
/// so any whitespace is `error.InvalidLanguage`. Whatever else the token
/// holds is the renderer's to escape, and the reparse's to check.
fn checkLanguageToken(lang: []const u8) Editor.Error!void {
    for (lang) |c| if (std.ascii.isWhitespace(c)) return error.InvalidLanguage;
}

/// One inline node a selection covers: the node whole, or — for a `str` the
/// selection starts or ends inside — the covered part of its text.
const InlinePiece = struct { node: AST.Node.Id, text: ?[]const u8 };

/// The inline nodes `[start, end)` covers, in order: the children of the
/// deepest node containing both ends, from the one holding `start` to the one
/// holding `end - 1`, each of which must be inline-level. Caller frees.
///
/// The ends may fall inside a `str`, and only a `str`: its covered part is a
/// slice of its text, which is exact only where the text is the source
/// byte-for-byte (`span.len == text.len`) — a run spelling `&amp;` has no
/// character at every byte, and slicing it would put an entity's tail in the
/// link. Anything else the range cuts through is `error.NotEditable`, and so
/// is a range whose ends sit in nothing (`error.NoBlock`) or that crosses a
/// block boundary.
fn coveredInlines(allocator: Allocator, doc: *const Document, start: usize, end: usize) Editor.Error![]InlinePiece {
    const ast = &doc.ast;
    var chain_a: std.ArrayList(AST.Node.Id) = .empty;
    defer chain_a.deinit(allocator);
    try locate.ancestorChain(allocator, doc, start, &chain_a);
    var chain_b: std.ArrayList(AST.Node.Id) = .empty;
    defer chain_b.deinit(allocator);
    try locate.ancestorChain(allocator, doc, end - 1, &chain_b);

    var i: usize = 0;
    while (i + 1 < chain_a.items.len and i + 1 < chain_b.items.len and
        chain_a.items[i + 1] == chain_b.items[i + 1]) : (i += 1)
    {}
    const common = chain_a.items[i];

    var pieces: std.ArrayList(InlinePiece) = .empty;
    errdefer pieces.deinit(allocator);

    // The range IS one node (`<em>this</em>` selected whole): that node.
    const common_span = doc.span(common);
    if (common_span.start >= start and common_span.end <= end) {
        if (ast.nodes[common].kind.level() != .@"inline") return error.NotEditable;
        try pieces.append(allocator, .{ .node = common, .text = null });
        return pieces.toOwnedSlice(allocator);
    }
    // Both ends in one text run: its covered part, and nothing else.
    if (ast.nodes[common].kind == .str) {
        try pieces.append(allocator, .{ .node = common, .text = try strSlice(doc, common, start, end) });
        return pieces.toOwnedSlice(allocator);
    }
    if (i + 1 >= chain_a.items.len or i + 1 >= chain_b.items.len) return error.NoBlock;
    const first = chain_a.items[i + 1];
    const last = chain_b.items[i + 1];
    var cur: ?AST.Node.Id = first;
    while (cur) |c| : (cur = if (c == last) null else ast.nodes[c].next_sibling) {
        if (ast.nodes[c].kind.level() != .@"inline") return error.NotEditable;
        const sp = doc.span(c);
        const cut = (c == first and sp.start < start) or (c == last and sp.end > end);
        try pieces.append(allocator, .{
            .node = c,
            .text = if (cut) try strSlice(doc, c, @max(sp.start, start), @min(sp.end, end)) else null,
        });
    }
    return pieces.toOwnedSlice(allocator);
}

/// The part of `str` node `id`'s text that `[start, end)` covers, where the
/// text is its source byte-for-byte; `error.NotEditable` for any other node,
/// or a run whose source spells a character some other way.
fn strSlice(doc: *const Document, id: AST.Node.Id, start: usize, end: usize) Editor.Error![]const u8 {
    const text = switch (doc.ast.nodes[id].kind) {
        .str => |t| t,
        else => return error.NotEditable,
    };
    const sp = doc.span(id);
    if (sp.end - sp.start != text.len) return error.NotEditable;
    return text[start - sp.start .. end - sp.start];
}

fn footnoteDefined(ast: *const AST, label: []const u8) bool {
    for (ast.nodes) |n| {
        if (std.meta.activeTag(n.kind) != .footnote) continue;
        if (std.mem.eql(u8, n.kind.footnote.label, label)) return true;
    }
    return false;
}

/// Whether `src` already ends in a blank line — so appending a block needs only
/// a line of its own, not a separator too. An EMPTY document counts: there is
/// nothing above for the new block to fuse with.
fn endsWithBlankLine(src: []const u8) bool {
    if (src.len == 0) return true;
    if (src[src.len - 1] != '\n') return false;
    const last = locate.lineStartAt(src, src.len - 1);
    return locate.isBlankLine(locate.lineBody(src[last..]));
}

// ── Link internals ─────────────────────────────────────────────────────────
// `toggleInline` can't spell a link: its delimiters are a fixed `(open, close)`
// pair, and a link's closing half carries a payload (`](dest)`). Hence a
// dedicated gesture with a destination argument — and with the escaping that
// payload needs.

/// Write `dest` into `out` spelled so the format parses it back byte-for-byte.
///
/// This is the sharp edge of the whole gesture, and it is NOT one escape table:
///
///   * Markdown ends a destination at the first space — `[t](a b)` is not a link
///     at all, it is literal text — so a destination holding whitespace has to
///     move into the `<…>` form, where `<`/`>`/`\` are what need escaping.
///   * Djot takes spaces literally and gives `<…>` NO meaning: `[t](<a b>)`
///     links to the seven characters `<a b>`. Wrapping there would corrupt the
///     URL rather than protect it.
///
/// That difference is `DestEscapes.angle`: non-null means the format HAS an
/// angle form to escape into. The algorithm is the same either way, which is why
/// it lives here once and the alphabets live in `syntax.zig`.
///
/// Both formats honour a backslash escape inside the destination, which is what
/// keeps an unbalanced `)` from closing the link early.
fn writeLinkDestination(
    allocator: Allocator,
    syntax: *const Syntax,
    dest: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const de = syntax.link_dest_escapes orelse return error.UnsupportedFormat;
    const angle: ?[]const u8 = if (de.angle) |a|
        (if (std.mem.indexOfAny(u8, dest, " \t") != null) a.escapes else null)
    else
        null;

    if (angle != null) try out.append(allocator, '<');
    const escapes = angle orelse de.plain;
    for (dest) |c| {
        if (std.mem.indexOfScalar(u8, escapes, c) != null) try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    if (angle != null) try out.append(allocator, '>');
}

fn writeLinkText(
    allocator: Allocator,
    syntax: *const Syntax,
    text: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const escapes = syntax.link_text_escapes orelse return error.UnsupportedFormat;
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, escapes, c) != null) try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
}

/// Write `text` through `render`, one run per `TextPosition`. The engine's half
/// of `Editor.insertLiteral`: it decides which bytes sit at a LINE START —
/// `at_line_start` seeds that zone for the first line; a `\n` re-enters it, and
/// spaces/tabs (a block marker tolerates up to three leading spaces) hold it, so
/// `\n  # h` still hands the `#` over in `block_start` position — and which sit
/// in a verbatim body, where the whole run goes over at once. Every run given
/// to `render` lies in exactly one position, so the format spells bytes and
/// never re-derives where a line starts.
fn writeLiteral(
    syntax: *const Syntax,
    render: RenderTextFn,
    text: []const u8,
    at_line_start: bool,
    in_verbatim: bool,
    out: *Writer,
) Writer.Error!void {
    if (in_verbatim) return render(syntax, text, .verbatim, out);
    var rest = text;
    var block_pos = at_line_start;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len - 1;
        const line = rest[0 .. nl + 1];
        rest = rest[nl + 1 ..];
        var body = line;
        if (block_pos) {
            // The leading whitespace and the byte that ends it: the run in
            // which a block marker bites.
            var i: usize = 0;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            const zone = @min(i + 1, line.len);
            try render(syntax, line[0..zone], .block_start, out);
            body = line[zone..];
        }
        if (body.len > 0) try render(syntax, body, .inline_text, out);
        // A line end re-enters the zone for whatever follows it.
        block_pos = line[line.len - 1] == '\n';
    }
}

/// The innermost autolink — the `<https://x.dev>` / `<a@b.dev>` form — on the
/// chain that wholly contains `[start, end)`.
///
/// Both node kinds are matched in both formats because the split is not the one
/// the names suggest — it follows the FORMAT, not just the destination.
/// `<mailto:a@b.dev>` parses as a `url` in Markdown and an `email` in djot, so
/// picking one kind per format would miss half the autolinks it was meant to
/// catch.
fn autolinkCovering(doc: *const Document, chain: []const AST.Node.Id, start: usize, end: usize) ?AST.Node.Id {
    const id = locate.innermostCovering(doc, chain, &.{.text_leaf}, start, end) orelse return null;
    const l = doc.ast.nodes[id].kind.text_leaf;
    return if (l.kind == .url or l.kind == .email) id else null;
}

/// Whether writing at `pos` would land STRICTLY INSIDE an autolink's URL — an
/// autolink covers `pos`, and `pos` is neither of its edges. A splice at an edge
/// is safe (it lands beside the node); one strictly inside rewrites the URL
/// itself, which is never what any caller meant. See `Editor.insertLink`.
///
/// Builds its own chain because the caller's is rooted at `start`, and the offset
/// that lands inside can be `end` (a selection running from ordinary text into
/// the middle of a URL).
fn splitsAutolink(allocator: Allocator, doc: *const Document, pos: usize) Allocator.Error!bool {
    var chain: std.ArrayList(AST.Node.Id) = .empty;
    defer chain.deinit(allocator);
    try locate.ancestorChain(allocator, doc, pos, &chain);
    const id = autolinkCovering(doc, chain.items, pos, pos) orelse return false;
    const span = doc.span(id);
    return span.start < pos and pos < span.end;
}

test {
    _ = @import("editor_test.zig");
}
