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
        else
            .{ .tag = @field(Splicer.KindTag, @tagName(k)) },
    };
}

/// `kindRef` for a vocabulary that is always a plain tag (`ContainerKind`) —
/// asserts that at comptime rather than leaving the caller to unwrap.
fn kindTag(kind: anytype) Splicer.KindTag {
    return switch (kindRef(kind)) {
        .tag => |t| t,
        .mark => unreachable,
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

    // ── Inline marks ───────────────────────────────────────────────────────

    /// Wrap `[start, end)` in `kind`'s delimiters — the unconditional half of
    /// the inline toolbar (always adds a mark).
    pub fn wrapRange(self: *Editor, span: Span, kind: InlineKind) Error!void {
        try self.checkRange(span.start, span.end);
        const d = self.syntax.inline_delims.get(kind) orelse return error.UnsupportedFormat;
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
        const d = self.syntax.inline_delims.get(kind) orelse return error.UnsupportedFormat;
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
    pub fn setBlock(self: *Editor, offset: usize, kind: BlockKind, level: u32) Error!void {
        const marker = self.syntax.heading_marker orelse return error.UnsupportedFormat;
        if (kind == .heading and (level < 1 or level > 6)) return error.InvalidLevel;

        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const ast = self.astView();
        const block = locate.innermostBlock(ast, offset, src.len) orelse return error.NoBlock;
        const node = ast.nodes[block];
        const cs = node.content_span orelse return error.NotEditable;
        const content = src[cs.start..cs.end];

        // Rewrite [block start, end-of-text): the leading marker region (a
        // heading) or nothing (a paragraph), plus the text — but NOT any
        // trailing newline the block span includes (Djot blocks do), so we don't
        // fuse with the next block. Rebuilding from `content_span` also
        // collapses a setext heading's underline line away for free.
        var end = node.span.end;
        if (end > node.span.start and src[end - 1] == '\n') end -= 1;
        if (end > node.span.start and src[end - 1] == '\r') end -= 1;

        const allocator = self.splicer.allocator;
        const prefix_len: usize = if (kind == .heading) level + 1 else 0; // marker*level + " "
        const buf = try allocator.alloc(u8, prefix_len + content.len);
        defer allocator.free(buf);
        if (kind == .heading) {
            @memset(buf[0..level], marker);
            buf[level] = ' ';
        }
        @memcpy(buf[prefix_len..], content);

        return self.commitSplice(node.span.start, end, buf);
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
    pub fn toggleBlockContainer(self: *Editor, span: Span, kind: ContainerKind) Error!void {
        try self.checkRange(span.start, span.end);
        const sp = self.syntax.container_spelling.get(kind) orelse return error.UnsupportedFormat;

        const allocator = self.splicer.allocator;
        const src = self.sourceBytes();
        const ast = self.astView();

        const blocks = coveredBlocks(allocator, ast, src, span.start, span.end) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoBlock,
        };
        defer allocator.free(blocks.chain);

        const region_start = locate.lineStartAt(src, ast.nodes[blocks.first].span.start);
        const region_end = locate.lineEndAt(src, ast.nodes[blocks.last].span.end -| 1);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // The toggle-off / convert / nest decision, all from the ancestor chain.
        if (locate.innermostOfKind(ast, blocks.chain, kindTag(kind))) |target| {
            if (containerFullyCovered(ast, src, target, region_start, region_end)) {
                const t = ast.nodes[target].span;
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
                        ast,
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
            if (locate.innermostOfKind(ast, blocks.chain, other)) |target| {
                if (containerFullyCovered(ast, src, target, region_start, region_end)) {
                    const t = ast.nodes[target].span;
                    const splice_start = locate.lineStartAt(src, t.start);
                    const splice_end = locate.lineEndAt(src, t.end -| 1);
                    try buildListRewrite(allocator, src, ast, target, splice_start, splice_end, sp, &out);
                    return self.commitSplice(splice_start, splice_end, out.items);
                }
            }
        }

        try buildContainerAdd(allocator, src, ast, blocks, region_start, region_end, sp, &out);
        return self.commitSplice(region_start, region_end, out.items);
    }

    /// Renumber the ordered list at `offset` so its markers run `1, 2, 3, …`,
    /// with each nesting level restarting at 1 — the numbering a caret editor
    /// keeps as items are inserted, deleted, and nested, where a plain splice
    /// leaves the source numbers stale (`1. 2. 2. 3.`). A no-op that returns
    /// `error.NoBlock` when `offset` is not inside an ordered list.
    ///
    /// Numbering tracks the marker's INDENTATION, not the AST: one left-to-right
    /// pass with a small stack of (indent column → next number), so a sub-list
    /// restarts and its parent resumes where it left off. Only the numeric run of
    /// a `N.` / `N)` marker is rewritten; its delimiter, spacing, indentation, and
    /// every non-item (bullet, continuation, blank) line are copied byte-for-byte.
    pub fn renumberOrderedLists(self: *Editor, offset: usize) Error!void {
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const ast = self.astView();
        const allocator = self.splicer.allocator;

        // The OUTERMOST ordered list on the descent to `offset`: renumber the
        // whole nest under it in one pass so its levels stay consistent.
        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        locate.ancestorChain(allocator, ast, offset, src.len, &chain) catch
            return error.OutOfMemory;
        var outer: ?AST.Node.Id = null;
        for (chain.items) |id| {
            if (std.meta.activeTag(ast.nodes[id].kind) == .ordered_list) {
                outer = id;
                break;
            }
        }
        const list = outer orelse return error.NoBlock;

        const region_start = locate.lineStartAt(src, ast.nodes[list].span.start);
        const region_end = locate.lineEndAt(src, ast.nodes[list].span.end -| 1);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try buildRenumber(allocator, src, region_start, region_end, &out);

        // Identical bytes: don't spend an edit (and an undo step) on a no-op.
        if (std.mem.eql(u8, out.items, src[region_start..region_end])) return;
        return self.commitSplice(region_start, region_end, out.items);
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
    fn tableEdit(self: *Editor, offset: usize, op: TableOp) Error!void {
        const src = self.sourceBytes();
        if (offset > src.len) return error.InvalidRange;
        const ast = self.astView();
        const allocator = self.splicer.allocator;

        var grid = table_edit.extract(allocator, ast, src, offset) catch |e| return mapTableErr(e);
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

        const bytes = table_edit.emit(allocator, &grid) catch |e| return mapTableErr(e);
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
        try locate.ancestorChain(allocator, ast, start, src.len, &chain);

        // The text to sit in the brackets, and the span the rebuilt link
        // replaces. Re-pointing an existing link rebuilds the whole node: a
        // destination is a string payload with no span of its own, so there is
        // nothing smaller to splice (see `splicer.zig`'s module doc).
        var text: []const u8 = src[start..end];
        var target = Span.init(start, end);
        var repoint = locate.innermostCovering(ast, chain.items, &.{.link}, start, end);
        if (repoint == null) repoint = autolinkCovering(ast, chain.items, start, end);
        // Not covered by an autolink, but still landing inside one: the range
        // runs from ordinary text into the middle of a URL (either end can be the
        // one inside). There is nothing to re-point — half the selection is real
        // text — and no way to spell the result, so refuse rather than corrupt
        // the URL.
        if (repoint == null and start != end) {
            const splits =
                (try splitsAutolink(allocator, ast, src.len, start)) or
                (try splitsAutolink(allocator, ast, src.len, end));
            if (splits) return error.NotEditable;
        }
        if (repoint) |id| {
            const node = ast.nodes[id];
            if (node.span.start == 0 and node.span.end == 0) return error.NotEditable;
            // An autolink has no `[text]` half: the text it shows is the OLD
            // destination, so keeping it would spell the new link with the URL it
            // was meant to replace. Empty text sends it through the canonical
            // spelling below, exactly as a caret on bare text goes.
            text = switch (std.meta.activeTag(node.kind)) {
                .url, .email => "",
                else => if (node.content_span) |cs| src[cs.start..cs.end] else "",
            };
            target = node.span;
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
    /// HTML.
    ///
    /// Errors:
    /// - `UnsupportedFormat` — the format has no in-cell break spelling (djot,
    ///   HTML, XML). Checked first: it is a property of the format, not the caret.
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
        const ast = self.astView();
        const src = self.sourceBytes();

        var chain: std.ArrayList(AST.Node.Id) = .empty;
        defer chain.deinit(allocator);
        try locate.ancestorChain(allocator, ast, offset, src.len, &chain);
        if (locate.innermostOfKind(ast, chain.items, .cell) == null) return error.NoBlock;

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
    ast: *const AST,
    src: []const u8,
    start: usize,
    end: usize,
) !BlockRange {
    var last_off = if (end > start) end - 1 else start;
    while (last_off > start and (src[last_off] == '\n' or src[last_off] == '\r')) last_off -= 1;

    var chain_a: std.ArrayList(AST.Node.Id) = .empty;
    errdefer chain_a.deinit(allocator);
    try locate.ancestorChain(allocator, ast, start, src.len, &chain_a);

    var chain_b: std.ArrayList(AST.Node.Id) = .empty;
    defer chain_b.deinit(allocator);
    try locate.ancestorChain(allocator, ast, last_off, src.len, &chain_b);

    var i: usize = 0;
    while (i + 1 < chain_a.items.len and i + 1 < chain_b.items.len and
        chain_a.items[i + 1] == chain_b.items[i + 1]) : (i += 1)
    {}
    // Climb to the nearest ancestor that holds blocks: the deepest shared node
    // may be an inline (a `str`), and a container wraps blocks, not words.
    var p = i;
    while (p > 0 and !locate.isBlockParent(ast.nodes[chain_a.items[p]].kind)) p -= 1;

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
    ast: *const AST,
    src: []const u8,
    target: AST.Node.Id,
    region_start: usize,
    region_end: usize,
) bool {
    const first = ast.nodes[target].first_child orelse return false;
    var last = first;
    var cur: ?AST.Node.Id = first;
    while (cur) |c| {
        last = c;
        cur = ast.nodes[c].next_sibling;
    }
    const lo = locate.lineStartAt(src, ast.nodes[first].span.start);
    const hi = locate.lineEndAt(src, ast.nodes[last].span.end -| 1);
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

/// Advance past one `>` quote marker — its optional indent, the `>`, and the one
/// optional space after it — or `null` if `line[i..]` doesn't start one.
fn skipQuoteMarker(line: []const u8, i: usize) ?usize {
    var j = i;
    var indent: usize = 0;
    while (j < line.len and line[j] == ' ' and indent < 3) : (indent += 1) j += 1;
    if (j >= line.len or line[j] != '>') return null;
    j += 1;
    if (j < line.len and line[j] == ' ') j += 1;
    return j;
}

/// The `[start, end)` of a list marker on `line` — `start` at the bullet/first
/// digit (so the indent before it stays put, keeping an enclosing container's
/// prefix intact) and `end` past the marker's trailing spaces. `null` if the
/// line doesn't open a list item.
fn listMarkerAt(line: []const u8) ?struct { start: usize, end: usize } {
    var j: usize = 0;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
    const start = j;
    if (j >= line.len) return null;
    if (line[j] == '-' or line[j] == '*' or line[j] == '+') {
        j += 1;
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
fn blockStartsOnLine(ast: *const AST, blocks: BlockRange, line_start: usize, line_end: usize) bool {
    var cur: ?AST.Node.Id = blocks.first;
    while (cur) |id| {
        const s = ast.nodes[id].span.start;
        if (s >= line_start and s < line_end) return true;
        if (id == blocks.last) break;
        cur = ast.nodes[id].next_sibling;
    }
    return false;
}

/// True if one of `list`'s items begins on `[line_start, line_end)`.
fn itemStartsOnLine(ast: *const AST, list: AST.Node.Id, line_start: usize, line_end: usize) bool {
    var it = ast.children(list);
    while (it.next()) |item| {
        const s = item.span.start;
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
    ast: *const AST,
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

        if (blockStartsOnLine(ast, blocks, line_start, line_end)) {
            var num_buf: [24]u8 = undefined;
            const marker = if (sp.numbered)
                std.fmt.bufPrint(&num_buf, "{d}. ", .{ordinal}) catch unreachable
            else
                sp.marker;
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
    ast: *const AST,
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

        if (itemStartsOnLine(ast, target, line_start, line_end)) {
            // Only when the list is going away: a conversion keeps the items as
            // items, so it must not loosen a tight list.
            if (sp == null and seen_item and !last_blank) try out.append(allocator, '\n');
            const m = listMarkerAt(line) orelse {
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
    out: *std.ArrayList(u8),
) !void {
    // A small stack of (indent column, next number), one entry per open nesting
    // level. Documents don't nest lists dozens deep; 32 is plenty and keeps this
    // allocation-free. A level deeper than 32 just isn't renumbered (copied).
    var cols: [32]usize = undefined;
    var nums: [32]u32 = undefined;
    var depth: usize = 0;

    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = locate.lineEndAt(src, line_start);
        const line = src[line_start..line_end];
        const m = listMarkerAt(line);
        const numbered = if (m) |mm| isNumberedMarker(line[mm.start..mm.end]) else false;
        if (numbered) {
            const mm = m.?;
            const indent = mm.start; // columns of leading whitespace
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
            // A bullet item, a continuation line, or a blank line: verbatim. A
            // bullet doesn't disturb the ordered counters at other columns.
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
fn autolinkCovering(ast: *const AST, chain: []const AST.Node.Id, start: usize, end: usize) ?AST.Node.Id {
    return locate.innermostCovering(ast, chain, &.{ .url, .email }, start, end);
}

/// Whether writing at `pos` would land STRICTLY INSIDE an autolink's URL — an
/// autolink covers `pos`, and `pos` is neither of its edges. A splice at an edge
/// is safe (it lands beside the node); one strictly inside rewrites the URL
/// itself, which is never what any caller meant. See `Editor.insertLink`.
///
/// Builds its own chain because the caller's is rooted at `start`, and the offset
/// that lands inside can be `end` (a selection running from ordinary text into
/// the middle of a URL).
fn splitsAutolink(allocator: Allocator, ast: *const AST, source_len: usize, pos: usize) Allocator.Error!bool {
    var chain: std.ArrayList(AST.Node.Id) = .empty;
    defer chain.deinit(allocator);
    try locate.ancestorChain(allocator, ast, pos, source_len, &chain);
    const id = autolinkCovering(ast, chain.items, pos, pos) orelse return false;
    const span = ast.nodes[id].span;
    return span.start < pos and pos < span.end;
}

test {
    _ = @import("editor_test.zig");
}
