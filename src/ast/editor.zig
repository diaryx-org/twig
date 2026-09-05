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
        /// A footnote label this format cannot hold: empty, or carrying a line
        /// end or a reference bracket.
        InvalidLabel,
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
        renumber_ordered_lists,
        table_insert_row,
        table_delete_row,
        table_insert_column,
        table_delete_column,
        table_set_alignment,
        table_move_row,
        table_move_column,
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
    ///   * `Syntax.authorable()` is "is there a door in" — true for HTML on its
    ///     inline marks alone, while every block gesture over it is still
    ///     unsupported. A toolbar enabled on that predicate is mostly buttons
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
            .set_block => syntax.heading_marker != null,
            .toggle_block_container => |k| syntax.container_spelling.get(k) != null,
            .insert_thematic_break => syntax.thematic_break != null,
            .toggle_code_block, .set_code_language => syntax.code_fence != null,
            .toggle_task_item, .set_task_checked, .toggle_task_checked => syntax.task_marker != null,
            .insert_link => syntax.link_text_escapes != null,
            // Both halves, as `insertImage` checks them. `assertCoherent` pins
            // them null-together, so this can't disagree with `.insert_link` —
            // it is written out anyway so the query reads as the gesture does.
            .insert_image => syntax.link_text_escapes != null and syntax.link_dest_escapes != null,
            .insert_footnote => syntax.footnote != null,
            .insert_literal => syntax.text_escapes != null,
            .insert_line_break => syntax.cell_line_break != null,
            // A total answer only because `assertCoherent` pins a heading marker
            // and a code fence non-null wherever a block separator is: those are
            // the two spellings `splitBlock` reaches for once it knows which
            // block the caret is in, and without that invariant this row would
            // be true while the gesture reported unsupported in a fence.
            .split_block => syntax.block_separator != null,
            .renumber_ordered_lists => spellsOrderedMarkers(syntax),
            .table_insert_row,
            .table_delete_row,
            .table_insert_column,
            .table_delete_column,
            .table_set_alignment,
            .table_move_row,
            .table_move_column,
            => syntax.table_spelling != null,
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
    /// the inline toolbar (always adds a mark).
    pub fn wrapRange(self: *Editor, span: Span, kind: InlineKind) Error!void {
        try self.checkRange(span.start, span.end);
        const d = self.syntax.authorableDelimsFor(kindRef(kind)) orelse return error.UnsupportedFormat;
        self.splicer.wrapRange(span, d.open, d.close) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EditConflict,
        };
    }

    /// Toggle `kind` over `[start, end)`: strip the mark if the range already
    /// IS a node of `kind` (its whole span or its interior), else wrap it — a
    /// rich editor's Cmd-B.
    pub fn toggleInline(self: *Editor, span: Span, kind: InlineKind) Error!void {
        try self.checkRange(span.start, span.end);
        const d = self.syntax.authorableDelimsFor(kindRef(kind)) orelse return error.UnsupportedFormat;
        self.splicer.toggleInline(span, kindRef(kind), d.open, d.close) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoNodeSpan, error.NoContentSpan => return error.NotEditable,
            else => return error.EditConflict,
        };
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
    pub fn setBlock(self: *Editor, offset: usize, kind: BlockKind, level: u32) Error!void {
        const marker = self.syntax.heading_marker orelse return error.UnsupportedFormat;
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
    pub fn toggleBlockContainer(self: *Editor, span: Span, kind: ContainerKind) Error!void {
        try self.checkRange(span.start, span.end);
        const sp = self.syntax.container_spelling.get(kind) orelse return error.UnsupportedFormat;

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
    ///     formats. The blank below is added only when the next line isn't
    ///     already blank, so repeating the gesture doesn't accumulate them.
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
    /// with no block to sit after it goes at the caret's line end.
    pub fn insertThematicBreak(self: *Editor, offset: usize) Error!void {
        const rule = self.syntax.thematic_break orelse return error.UnsupportedFormat;
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const allocator = self.splicer.allocator;

        const block = if (locate.lineOwningBlock(&self.splicer.doc, offset)) |lb| lb.block else null;
        const anchor = if (block) |b| self.splicer.doc.span(b).end -| 1 else offset;
        const pos = locate.lineEndAt(src, anchor);
        const prefix = if (block) |b| containerPrefix(src, self.splicer.doc.span(b).start) else "";
        // A quote's blank line carries its marker but not the space after it —
        // the same rule `ContainerSpelling.blank` states for the toggle.
        const blank = std.mem.trimEnd(u8, prefix, " ");

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        if (pos > 0) {
            try out.appendSlice(allocator, blank);
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, rule);
        try out.append(allocator, '\n');
        if (pos < src.len and !locate.isBlankLine(locate.lineBody(src[pos..locate.lineEndAt(src, pos)]))) {
            try out.appendSlice(allocator, blank);
            try out.append(allocator, '\n');
        }

        return self.commitSplice(pos, pos, out.items);
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
    pub fn toggleCodeBlock(self: *Editor, span: Span, lang: ?[]const u8) Error!void {
        try self.checkRange(span.start, span.end);
        const fence = self.syntax.code_fence orelse return error.UnsupportedFormat;
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
    pub fn setCodeLanguage(self: *Editor, offset: usize, lang: ?[]const u8) Error!void {
        const fence = self.syntax.code_fence orelse return error.UnsupportedFormat;
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
    pub fn insertLink(self: *Editor, span: Span, dest: []const u8) Error!void {
        try self.checkRange(span.start, span.end);
        // A format with no link spelling refuses before anything else is read.
        if (self.syntax.link_text_escapes == null) return error.UnsupportedFormat;
        if (std.mem.indexOfAny(u8, dest, "\r\n") != null) return error.InvalidDestination;

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
    pub fn insertImage(self: *Editor, span: Span, dest: []const u8) Error!void {
        try self.checkRange(span.start, span.end);
        if (self.syntax.link_text_escapes == null) return error.UnsupportedFormat;
        if (self.syntax.link_dest_escapes == null) return error.UnsupportedFormat;
        if (std.mem.indexOfAny(u8, dest, "\r\n") != null) return error.InvalidDestination;

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
    pub fn insertLiteral(self: *Editor, offset: usize, text: []const u8) Error!void {
        try self.checkRange(offset, offset);
        if (self.syntax.text_escapes == null) return error.UnsupportedFormat;

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

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try writeLiteral(allocator, self.syntax, text, at_line_start, &out);

        return self.commitSplice(offset, offset, out.items);
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

/// Escape `text` for BODY-TEXT position, backslash-escaping every `text_escapes`
/// byte and — only while in a line's leading whitespace — every
/// `block_start_escapes` byte. `at_line_start` seeds that zone for the first
/// line; a `\n` re-enters it, and spaces/tabs (a block marker tolerates up to
/// three leading spaces) hold it, so `\n  # h` still escapes the `#`. The two
/// alphabets are separate because a `#` is a heading only at a line start but a
/// `*` is emphasis anywhere. See `Editor.insertLiteral`.
fn writeLiteral(
    allocator: Allocator,
    syntax: *const Syntax,
    text: []const u8,
    at_line_start: bool,
    out: *std.ArrayList(u8),
) !void {
    const inline_escapes = syntax.text_escapes orelse return error.UnsupportedFormat;
    const block_escapes = syntax.block_start_escapes orelse return error.UnsupportedFormat;
    var block_pos = at_line_start;
    for (text) |c| {
        const escape = std.mem.indexOfScalar(u8, inline_escapes, c) != null or
            (block_pos and std.mem.indexOfScalar(u8, block_escapes, c) != null);
        if (escape) try out.append(allocator, '\\');
        try out.append(allocator, c);
        if (c == '\n') {
            block_pos = true;
        } else if (c != ' ' and c != '\t') {
            block_pos = false;
        }
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
