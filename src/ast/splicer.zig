//! The span-splice editor — Twig's reason for existing: precise, LOSSLESS
//! in-place edits to a document, driven by the AST's byte spans. The document
//! analogue of how sister project `fig` edits config files (see DESIGN.md's
//! "Relationship to fig"), reduced to its essence.
//!
//! ── The one primitive ──────────────────────────────────────────────────────
//! Everything reduces to `replaceAtSpan(span, replacement)`: build a new source
//! buffer that is the old bytes with `[span.start, span.end)` overwritten by
//! `replacement`, reparse it, and — only if the reparse succeeds — swap it in.
//! On reparse failure the edit is abandoned and the editor is left exactly as
//! it was (the new buffer is discarded; the old source and AST are untouched),
//! so a failed edit can never corrupt the document. Losslessness is automatic:
//! bytes outside the spliced span are copied verbatim and never reflow — Twig
//! never reformats what it didn't edit. An insertion is just a zero-width span.
//!
//! ── Language-agnostic by construction ──────────────────────────────────────
//! The editor holds only source bytes plus a `parse_fn` callback (source ->
//! `AST`), so the same engine edits djot, Markdown, or XML — the caller
//! supplies the right parser. It deliberately does NOT import any language
//! module (the CLI wires the per-language `parse_fn` adapters; djot/Markdown's
//! `Document` side tables are irrelevant to editing, so an adapter frees those
//! maps and hands back the bare `AST`). Tests below `@import` a real language
//! (XML) only inside the test bodies, so non-test builds carry no such dep.
//!
//! ── What it can't do yet (honest limits) ───────────────────────────────────
//!   - `replaceContent`/`insertChild`-into-empty need a container's interior
//!     offset (`content_span`); djot leaves that `null` for empty containers
//!     (XML always has it), so those ops return `error.NoContentSpan` there.
//!   - Payload fields (a `link`'s destination, a `code_block`'s language) are
//!     string payloads, not child nodes with their own spans — so there is no
//!     sub-node span to splice; editing one means `replaceNode` on the whole
//!     node's source. Per-field spans are future parser work.
//!   - `deleteNode` removes exactly the node's span and nothing else (no
//!     surrounding-whitespace cleanup) — predictable and lossless, but it can
//!     leave a blank line behind. `deleteNodeSmart` is the block-aware variant
//!     that tidies the surrounding blank lines (and falls back to the exact
//!     delete for an inline, mid-line node); the CLI's `--delete` uses it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Node = AST.Node;
const Span = @import("../span.zig");

/// Cap on retained undo steps, bounding history memory over a long session.
/// Coalescing (`coalesceLastUndo`) makes a run of keystrokes one step, so this
/// counts edit groups, not individual splices.
const MAX_UNDO: usize = 200;

pub const Splicer = struct {
    /// What the most recent successful edit did to the source, in byte terms.
    /// `old` is the range of the *pre-edit* source that was replaced; `new` is
    /// the range the replacement now occupies in the *post-edit* source (they
    /// share a start). An insertion has an empty `old`; a deletion an empty
    /// `new`. The net length delta is `new.len() - old.len()`. Everything a
    /// caret/selection needs to re-anchor across an edit without re-diffing.
    pub const Change = struct { old: Span, new: Span };

    /// Source -> a freshly-allocated `AST` the editor takes ownership of.
    /// Runtime (not comptime-generic) so the CLI can pick the language at run
    /// time; the error set is open (`anyerror`) because each language's parse
    /// error set differs and a reparse failure is a legitimate, caller-visible
    /// outcome.
    ///
    /// The leading `ctx` is an opaque pointer the caller supplies to `init`
    /// and the editor passes back to every reparse, unread — the hook for
    /// parse configuration the editor itself has no business knowing about
    /// (the CLI passes a `*const format.ParseConfig` so an edited Markdown
    /// document reparses with the SAME extension flags, e.g. `--directives`,
    /// it was first parsed with; a callback that needs no configuration just
    /// ignores it). It must outlive the editor.
    pub const ParseFn = *const fn (ctx: *const anyopaque, Allocator, []const u8) anyerror!AST;

    /// One history step: a whole source snapshot plus the opaque `caret` blob
    /// the host associated with THAT document state (see `current_caret`). The
    /// blob travels with the buffer it belongs to, so undo/redo hand back the
    /// caret that matches the restored source with no parallel bookkeeping on
    /// the host side. `caret` may be empty (the host set nothing).
    pub const HistoryEntry = struct {
        source: std.ArrayList(u8),
        caret: std.ArrayList(u8) = .empty,

        fn deinit(self: *HistoryEntry, allocator: Allocator) void {
            self.source.deinit(allocator);
            self.caret.deinit(allocator);
        }
    };

    allocator: Allocator,
    /// The current (edited) document bytes. Owns its memory.
    source: std.ArrayList(u8),
    /// The parse of `source.items` as of the last successful edit. Owns its
    /// memory; replaced wholesale on every successful edit.
    ast: AST,
    parse_fn: ParseFn,
    /// Opaque configuration handed to `parse_fn` on every reparse (see
    /// `ParseFn`). Borrowed; must outlive the editor.
    parse_ctx: *const anyopaque,
    /// The byte-level effect of the last successful `replaceAtSpan` (and hence
    /// of the last successful op, since every op funnels through it), or `null`
    /// before the first edit. A failed edit leaves it untouched. Note: a
    /// multi-splice op (e.g. `Filter`) leaves only its *final* splice here.
    last_change: ?Change = null,
    /// Undo/redo history as whole source snapshots, each tagged with a caret
    /// blob. `replaceAtSpan` retires the pre-edit source (and its `current_caret`)
    /// onto `undo_stack` instead of freeing it; `undo`/`redo` swap an entry
    /// between the stacks and reparse. Each single-splice op is one step;
    /// `coalesceLastUndo` folds a keystroke run into one.
    undo_stack: std.ArrayList(HistoryEntry) = .empty,
    redo_stack: std.ArrayList(HistoryEntry) = .empty,
    /// An opaque, host-owned blob describing the caret/selection for the CURRENT
    /// source state — twig never reads it, only stores and hands it back. The
    /// host sets it (via `setCaret`) BEFORE an edit so the pre-edit caret is what
    /// gets retired onto the undo stack; after undo/redo it holds the restored
    /// state's caret. Owns its bytes; reset to empty on every edit so a fresh
    /// state starts caret-less until the host sets one.
    current_caret: std.ArrayList(u8) = .empty,
    /// Monotonic change token, bumped once per successful mutation of `source`
    /// (`replaceAtSpan` and undo/redo alike). Never decreases, never repeats a
    /// value for the life of the editor. The host keys caches on it instead of
    /// hand-maintaining its own "did something change?" flag: equal revision ⇒
    /// identical document. Starts at 0 for the initial parse.
    revision: u64 = 0,
    /// The cumulative byte range that has changed since the last `clearDirty`
    /// (or since `init`), in CURRENT source coordinates, or `null` when nothing
    /// has changed since then. A single conservative interval, composed from
    /// each edit's `Change` in O(1): it always covers every byte an edit (or
    /// undo/redo) touched, and after several edits to disjoint regions may
    /// over-cover the gap between them, but it never under-covers. The host
    /// consumes it to rebuild only the affected part of a derived view (glyph
    /// rows, syntax spans, …) instead of the whole document, then calls
    /// `clearDirty` to acknowledge it.
    ///
    /// A companion to `revision`, not a replacement: `revision` answers "did
    /// anything change?" (cache key); `dirty` answers "which bytes?" (rebuild
    /// scope). This reports where BYTES differ, which — because Twig splices
    /// losslessly and never reflows untouched bytes — is exact. It does NOT
    /// report where the PARSE differs: an edit can reinterpret bytes outside
    /// this range (opening a code fence, a `#` promoting a paragraph to a
    /// heading). A consumer that rebuilds *structure* from the range must widen
    /// it to the enclosing block(s) itself; that is a render-side policy Twig
    /// has no business fixing.
    dirty: ?Span = null,

    /// Parse `source_bytes` and build an editor over a private copy of them.
    /// `parse_ctx` is forwarded verbatim to `parse_fn` on the initial parse
    /// and every reparse — see `ParseFn`.
    pub fn init(allocator: Allocator, source_bytes: []const u8, parse_ctx: *const anyopaque, parse_fn: ParseFn) !Splicer {
        var source: std.ArrayList(u8) = .empty;
        errdefer source.deinit(allocator);
        try source.appendSlice(allocator, source_bytes);
        const ast = try parse_fn(parse_ctx, allocator, source.items);
        return .{ .allocator = allocator, .source = source, .ast = ast, .parse_fn = parse_fn, .parse_ctx = parse_ctx };
    }

    pub fn deinit(self: *Splicer) void {
        self.ast.deinit();
        self.source.deinit(self.allocator);
        self.current_caret.deinit(self.allocator);
        for (self.undo_stack.items) |*e| e.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*e| e.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    /// The current edited document bytes.
    pub fn sourceBytes(self: *const Splicer) []const u8 {
        return self.source.items;
    }

    /// The current parse (valid until the next successful edit).
    pub fn astView(self: *const Splicer) *const AST {
        return &self.ast;
    }

    /// Associate an opaque `blob` with the current document state — twig stores
    /// a private copy and never interprets it. Call this with the pre-edit caret
    /// BEFORE an edit so the retired undo step carries it; after undo/redo the
    /// current blob is the restored state's, retrievable via `caretBlob`.
    /// A zero-length `blob` clears the current caret.
    pub fn setCaret(self: *Splicer, blob: []const u8) !void {
        self.current_caret.clearRetainingCapacity();
        try self.current_caret.appendSlice(self.allocator, blob);
    }

    /// The opaque caret blob for the CURRENT document state (see `setCaret`),
    /// empty if none is set. Borrowed from the editor; valid until the next
    /// `setCaret`, successful edit, or undo/redo on this editor.
    pub fn caretBlob(self: *const Splicer) []const u8 {
        return self.current_caret.items;
    }

    // ── the primitive ──────────────────────────────────────────────────────

    /// Overwrite `[span.start, span.end)` of the source with `replacement`,
    /// reparse, and swap in the result. On reparse failure nothing changes and
    /// the parser's error is returned. A zero-width `span` is an insertion.
    pub fn replaceAtSpan(self: *Splicer, span: Span, replacement: []const u8) !void {
        std.debug.assert(span.start <= span.end);
        std.debug.assert(span.end <= self.source.items.len);
        const s = self.source.items;

        // Assemble the whole new source once, then reparse it. Building a fresh
        // buffer (rather than mutating in place) means the rollback path is
        // just "throw the new buffer away" — the old source/AST never moved.
        const total = span.start + replacement.len + (s.len - span.end);
        var new_src: std.ArrayList(u8) = .empty;
        new_src.ensureTotalCapacityPrecise(self.allocator, total) catch |err| {
            new_src.deinit(self.allocator);
            return err;
        };
        new_src.appendSliceAssumeCapacity(s[0..span.start]);
        new_src.appendSliceAssumeCapacity(replacement);
        new_src.appendSliceAssumeCapacity(s[span.end..]);

        const new_ast = self.parse_fn(self.parse_ctx, self.allocator, new_src.items) catch |err| {
            new_src.deinit(self.allocator);
            return err;
        };

        // Commit: the reparse succeeded, so retire the old state. The pre-edit
        // source goes onto the undo history (not freed), and any redo is dropped
        // now that a fresh edit has diverged the timeline.
        self.ast.deinit();
        self.ast = new_ast;
        // Retire the pre-edit source together with the caret the host had set
        // for it, then reset `current_caret` — the new state is caret-less until
        // the host sets one for it.
        self.recordUndo(self.source, self.current_caret);
        self.current_caret = .empty;
        self.clearRedo();
        self.source = new_src;
        self.noteChange(.{
            .old = span,
            .new = Span.init(span.start, span.start + replacement.len),
        });
    }

    // ── undo / redo ─────────────────────────────────────────────────────────

    /// Retire a pre-edit source buffer (with its caret blob) onto the undo
    /// stack, evicting the oldest entry once past the cap. Takes ownership of
    /// both `buf` and `caret`.
    fn recordUndo(self: *Splicer, buf: std.ArrayList(u8), caret: std.ArrayList(u8)) void {
        self.undo_stack.append(self.allocator, .{ .source = buf, .caret = caret }) catch {
            var entry: HistoryEntry = .{ .source = buf, .caret = caret };
            entry.deinit(self.allocator);
            return;
        };
        if (self.undo_stack.items.len > MAX_UNDO) {
            var oldest = self.undo_stack.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    fn clearRedo(self: *Splicer) void {
        for (self.redo_stack.items) |*e| e.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Merge the most recent edit into the step before it, so a run of
    /// keystrokes undoes as one. Drops the latest "before" snapshot (and its
    /// caret blob), leaving the run's earlier one — so an undo of a coalesced
    /// run restores the caret from before the run began. A no-op unless there
    /// are at least two steps to merge.
    pub fn coalesceLastUndo(self: *Splicer) void {
        if (self.undo_stack.items.len < 2) return;
        var top = self.undo_stack.pop().?;
        top.deinit(self.allocator);
    }

    /// Restore the previous edit step, if any, moving the current source onto
    /// the redo stack. Returns the byte-level `Change` (current → restored) so a
    /// caret can re-anchor, or `null` when there's nothing to undo.
    pub fn undo(self: *Splicer) !?Change {
        if (self.undo_stack.items.len == 0) return null;
        const target = self.undo_stack.pop().?;
        return try self.swapTo(target, &self.redo_stack);
    }

    /// Re-apply the most recently undone step, symmetric to `undo`.
    pub fn redo(self: *Splicer) !?Change {
        if (self.redo_stack.items.len == 0) return null;
        const target = self.redo_stack.pop().?;
        return try self.swapTo(target, &self.undo_stack);
    }

    /// Make `target` the current state (reparsing its source) and push the
    /// outgoing state — source AND `current_caret` — onto `other`. The restored
    /// entry's caret becomes `current_caret`, so after undo/redo `caretBlob`
    /// reports the caret that matches the now-current source. Returns the
    /// `Change` describing current → target.
    fn swapTo(self: *Splicer, target: HistoryEntry, other: *std.ArrayList(HistoryEntry)) !?Change {
        var t = target;
        const new_ast = self.parse_fn(self.parse_ctx, self.allocator, t.source.items) catch |err| {
            // A stored snapshot parsed when it was recorded, so this shouldn't
            // happen; if it does, drop the entry and surface the error rather
            // than leave the editor half-swapped.
            t.deinit(self.allocator);
            return err;
        };
        const change = diffChange(self.source.items, t.source.items);
        other.append(self.allocator, .{ .source = self.source, .caret = self.current_caret }) catch {
            // OOM: lose this redo/undo entry, don't leak either buffer.
            var lost: HistoryEntry = .{ .source = self.source, .caret = self.current_caret };
            lost.deinit(self.allocator);
        };
        self.ast.deinit();
        self.ast = new_ast;
        self.source = t.source;
        self.current_caret = t.caret;
        self.noteChange(change);
        return change;
    }

    /// The minimal `[start, end)` byte range that differs between `before` and
    /// `after`, as a `Change` (common prefix and suffix trimmed). Lets undo/redo
    /// report where the edit landed without tracking edits through composition.
    fn diffChange(before: []const u8, after: []const u8) Change {
        const min = @min(before.len, after.len);
        var p: usize = 0;
        while (p < min and before[p] == after[p]) p += 1;
        var s: usize = 0;
        while (s < min - p and before[before.len - 1 - s] == after[after.len - 1 - s]) s += 1;
        return .{
            .old = Span.init(p, before.len - s),
            .new = Span.init(p, after.len - s),
        };
    }

    // ── change notification (revision + last_change + dirty range) ───────────

    /// The single choke point every successful mutation routes through, so the
    /// three things that describe "what just changed" can never drift apart:
    /// publish the byte effect as `last_change`, fold it into the running
    /// `dirty` range, and bump `revision`. Called by `replaceAtSpan` and
    /// undo/redo's `swapTo` after they have swapped the new state in.
    fn noteChange(self: *Splicer, change: Change) void {
        self.accumulateDirty(change);
        self.last_change = change;
        self.revision += 1;
    }

    /// Fold one edit's `Change` into the running `dirty` interval, in CURRENT
    /// (post-edit) source coordinates. The existing interval is in the PRE-edit
    /// coordinate space, so it is first shifted across this edit — positions at
    /// or after `old.end` move by the length delta, a position landing inside
    /// the replaced region collapses onto the edit window — then unioned with
    /// the edit's own `new` range. Unioning into one interval is what makes this
    /// conservative: it can only ever over-cover, never miss a changed byte.
    fn accumulateDirty(self: *Splicer, change: Change) void {
        const old = change.old;
        const new = change.new;
        const d = self.dirty orelse {
            self.dirty = new;
            return;
        };
        // Shift a pre-edit position into post-edit coordinates. A position
        // interior to the replaced span no longer exists, so a low bound
        // collapses to the window start and a high bound to the window end
        // (`new.start`/`new.end`) — either way it is then absorbed by the union
        // with `new` below. No underflow: for `p >= old.end`, `p >= old.len()`.
        const shifted_lo = if (d.start <= old.start)
            d.start
        else if (d.start >= old.end)
            d.start - old.len() + new.len()
        else
            new.start;
        const shifted_hi = if (d.end <= old.start)
            d.end
        else if (d.end >= old.end)
            d.end - old.len() + new.len()
        else
            new.end;
        self.dirty = Span.init(@min(shifted_lo, new.start), @max(shifted_hi, new.end));
    }

    /// The cumulative dirty byte range since the last `clearDirty` (or `init`),
    /// or `null` if the document is clean relative to that mark. See the `dirty`
    /// field for the full contract (conservative interval; bytes, not parse).
    pub fn dirtyRange(self: *const Splicer) ?Span {
        return self.dirty;
    }

    /// Acknowledge the current dirty range: mark the document clean so a later
    /// `dirtyRange` reports only mutations made after this call. The host calls
    /// it once it has consumed the range (rebuilt the affected view). Leaves
    /// `revision`, `last_change`, and the document itself untouched.
    pub fn clearDirty(self: *Splicer) void {
        self.dirty = null;
    }

    // ── ops ─────────────────────────────────────────────────────────────
    // Two flavors of each op: a `…ById` form taking a resolved `Node.Id` (what
    // a selector match hands you), and a path form that just resolves the index
    // path and delegates. Both converge on `replaceAtSpan`. Ids are valid only
    // against the CURRENT `ast` (recompute after any successful edit).

    /// A node's span, or `error.NoNodeSpan` if it's the degenerate `(0,0)` that
    /// means "unset". Some parsers don't populate spans for every kind yet
    /// (notably Markdown inline nodes — links, emphasis), and splicing at a
    /// `(0,0)` span would silently corrupt the document at offset 0 instead of
    /// touching the intended node. Guarding the whole-node ops turns that into
    /// a clear error. (A real node never legitimately occupies zero bytes at
    /// offset 0.)
    fn nodeSpan(self: *Splicer, id: Node.Id) !Span {
        const s = self.ast.nodes[id].span;
        if (s.start == 0 and s.end == 0) return error.NoNodeSpan;
        return s;
    }

    /// Replace the whole source of the node at `path`.
    pub fn replaceNode(self: *Splicer, path: []const usize, text: []const u8) !void {
        try self.replaceNodeById(try self.ast.getIdByPath(path), text);
    }
    pub fn replaceNodeById(self: *Splicer, id: Node.Id, text: []const u8) !void {
        try self.replaceAtSpan(try self.nodeSpan(id), text);
    }

    /// Replace the interior (between-delimiters `content_span`) of the node.
    /// Usually a container (its children), but also a text leaf that carries a
    /// `content_span`: on a `code_block` this replaces the code body, fences
    /// left intact. `error.NoContentSpan` if the node has no interior (most
    /// leaves, or a djot container the parser left with a null interior — see
    /// the module doc).
    pub fn replaceContent(self: *Splicer, path: []const usize, text: []const u8) !void {
        try self.replaceContentById(try self.ast.getIdByPath(path), text);
    }
    pub fn replaceContentById(self: *Splicer, id: Node.Id, text: []const u8) !void {
        const cs = self.ast.nodes[id].content_span orelse return error.NoContentSpan;
        try self.replaceAtSpan(cs, text);
    }

    /// Insert `text` immediately before / after the node (at its span start /
    /// end). The caller supplies any needed separators/newlines — the editor
    /// does no whitespace guessing.
    pub fn insertBefore(self: *Splicer, path: []const usize, text: []const u8) !void {
        try self.insertBeforeById(try self.ast.getIdByPath(path), text);
    }
    pub fn insertBeforeById(self: *Splicer, id: Node.Id, text: []const u8) !void {
        const at = (try self.nodeSpan(id)).start;
        try self.replaceAtSpan(Span.init(at, at), text);
    }
    pub fn insertAfter(self: *Splicer, path: []const usize, text: []const u8) !void {
        try self.insertAfterById(try self.ast.getIdByPath(path), text);
    }
    pub fn insertAfterById(self: *Splicer, id: Node.Id, text: []const u8) !void {
        const at = (try self.nodeSpan(id)).end;
        try self.replaceAtSpan(Span.init(at, at), text);
    }

    /// Insert `text` as the `index`-th child of the container. Anchor rules:
    /// `index == 0` -> before the current first child; an index at or past the
    /// child count -> after the current last child; otherwise -> before the
    /// index-th child. An *empty* container is anchored at its `content_span`
    /// start (`error.NoContentSpan` if it has none). `error.NotAContainer` for
    /// a text leaf like `code_block`: it has a `content_span` (its body) but no
    /// child sequence, so there is nothing to insert a *child* into (use
    /// `replaceContent` to edit the body instead).
    pub fn insertChild(self: *Splicer, path: []const usize, index: usize, text: []const u8) !void {
        try self.insertChildById(try self.ast.getIdByPath(path), index, text);
    }
    pub fn insertChildById(self: *Splicer, id: Node.Id, index: usize, text: []const u8) !void {
        const first = self.ast.nodes[id].first_child orelse {
            // A childless node with a `content_span` is either an EMPTY
            // container (anchor the first child at its interior start) or a
            // text leaf like `code_block`, whose `content_span` is opaque body
            // text, not a child region. Refuse the latter — it has no children
            // to index — even though it does carry a `content_span`.
            if (AST.contentModel(self.ast.nodes[id].kind) == .text) return error.NotAContainer;
            const cs = self.ast.nodes[id].content_span orelse return error.NoContentSpan;
            return self.replaceAtSpan(Span.init(cs.start, cs.start), text);
        };

        var cur: ?Node.Id = first;
        var i: usize = 0;
        var last: Node.Id = first;
        var prev_last: ?Node.Id = null; // the sibling before `last`, for gap sampling
        while (cur) |c| {
            if (i == index) {
                const at = self.ast.nodes[c].span.start;
                return self.replaceAtSpan(Span.init(at, at), text);
            }
            if (i > 0) prev_last = last;
            last = c;
            cur = self.ast.nodes[c].next_sibling;
            i += 1;
        }
        // Appending past the last child. The between-child branch above anchors
        // at the next sibling's start; with no next sibling we must synthesize
        // the point a sibling *would* start — otherwise the new node joins onto
        // the last one (`- b` + `- new` -> `- b- new`). The separator between
        // siblings is format-specific (a newline for block lists, nothing for
        // inline XML children), so infer it from the source rather than assume:
        //   1. A trailing newline already sits after the last child -> step past
        //      it (its own line ended; the new node starts on the next line).
        //   2. No trailing newline, but the existing siblings are newline-
        //      separated (sampled gap contains '\n') -> the last line just lacks
        //      its terminator (e.g. EOF); inject one before the new node.
        //   3. Otherwise siblings are adjacent (inline) -> splice verbatim.
        const src = self.source.items;
        const at = self.ast.nodes[last].span.end;
        if (at < src.len and src[at] == '\n') {
            return self.replaceAtSpan(Span.init(at + 1, at + 1), text);
        }
        const siblings_line_separated = if (prev_last) |p| blk: {
            const gap = src[self.ast.nodes[p].span.end..self.ast.nodes[last].span.start];
            break :blk std.mem.indexOfScalar(u8, gap, '\n') != null;
        } else false;
        if (siblings_line_separated) {
            const buf = try self.allocator.alloc(u8, text.len + 1);
            defer self.allocator.free(buf);
            buf[0] = '\n';
            @memcpy(buf[1..], text);
            return self.replaceAtSpan(Span.init(at, at), buf);
        }
        try self.replaceAtSpan(Span.init(at, at), text);
    }

    /// Delete the node (remove exactly its span; no whitespace cleanup). The
    /// predictable primitive — see `deleteNodeSmart` for the block-aware
    /// variant that also tidies the surrounding blank lines.
    pub fn deleteNode(self: *Splicer, path: []const usize) !void {
        try self.deleteNodeById(try self.ast.getIdByPath(path));
    }
    pub fn deleteNodeById(self: *Splicer, id: Node.Id) !void {
        try self.replaceAtSpan(try self.nodeSpan(id), "");
    }

    /// Delete the node, tidying surrounding whitespace so no dangling blank
    /// line is left behind. For a node that occupies WHOLE LINES (a block —
    /// paragraph, heading, list, container directive, …) this also removes the
    /// block's terminating newline and one blank-line separator, collapsing
    /// `A⏎⏎B⏎⏎C` down to `A⏎⏎C` when `B` is deleted (and trimming the now-
    /// dangling separator at a document edge). For a MID-LINE node (an inline
    /// — emphasis, a link) line surgery would be wrong, so it falls back to the
    /// exact-span delete of `deleteNode`. See `tidyDeletionSpan`.
    pub fn deleteNodeSmart(self: *Splicer, path: []const usize) !void {
        try self.deleteNodeSmartById(try self.ast.getIdByPath(path));
    }
    pub fn deleteNodeSmartById(self: *Splicer, id: Node.Id) !void {
        const span = try self.nodeSpan(id);
        try self.replaceAtSpan(tidyDeletionSpan(self.source.items, span), "");
    }

    /// Unwrap the node: replace its whole span with the source text of its
    /// interior (`content_span`), dropping the wrapper but keeping the children
    /// in place — e.g. peel a `:::vis{…}` container down to just the blocks
    /// inside it, or a `<div>` down to its contents. Lossless: the interior is
    /// spliced in verbatim, and the wrapper's own surrounding blank lines are
    /// left untouched (the interior takes the block's place). A node with no
    /// interior (`content_span == null`: a leaf, or an EMPTY container — nothing
    /// to keep) degrades to a smart delete.
    ///
    /// Because the interior is spliced VERBATIM, unwrap is exactly right for
    /// containers whose content lines carry no per-line marker (directives,
    /// divs, sections). For a marker-prefixed container (a block quote's `>`, a
    /// list item's indent) the markers live inside `content_span` and would
    /// survive the unwrap — stripping those needs serializer-assisted
    /// re-emission, which this span-splice editor deliberately doesn't do.
    pub fn unwrapNode(self: *Splicer, path: []const usize) !void {
        try self.unwrapNodeById(try self.ast.getIdByPath(path));
    }
    pub fn unwrapNodeById(self: *Splicer, id: Node.Id) !void {
        const span = try self.nodeSpan(id);
        const cs = self.ast.nodes[id].content_span orelse return self.deleteNodeSmartById(id);
        // `interior` aliases `self.source`; `replaceAtSpan` copies it into the
        // new buffer before retiring the old source, so this is safe.
        const interior = self.source.items[cs.start..cs.end];
        try self.replaceAtSpan(span, interior);
    }

    // ── range-oriented rich-text ops (the "toolbar") ────────────────────────
    // These stay language-agnostic: the caller (which knows the format) supplies
    // the delimiter bytes and the target `Node.Kind` tag, so this engine never
    // imports a language module. The format→delimiter table lives at the C-ABI
    // boundary. `wrapRange` always adds; `toggleInline` adds or removes based on
    // whether the range already *is* a node of that kind.

    /// The tag half of `Node.Kind` — a plain enum of kind names, what a caller
    /// names an inline kind by (`.strong`, `.emph`, …) without its payload.
    pub const KindTag = std.meta.Tag(Node.Kind);

    /// Wrap `[span.start, span.end)` with `open`/`close` in a single splice
    /// (one reparse), e.g. `*`…`*` to bold a selection. Losslessly reversible
    /// by `toggleInline`. The reparse validates the result; a delimiter that
    /// doesn't parse in context rolls the edit back like any other.
    pub fn wrapRange(self: *Splicer, span: Span, open: []const u8, close: []const u8) !void {
        std.debug.assert(span.start <= span.end);
        std.debug.assert(span.end <= self.source.items.len);
        const interior = self.source.items[span.start..span.end];
        const buf = try self.allocator.alloc(u8, open.len + interior.len + close.len);
        defer self.allocator.free(buf);
        @memcpy(buf[0..open.len], open);
        @memcpy(buf[open.len..][0..interior.len], interior);
        @memcpy(buf[open.len + interior.len ..], close);
        try self.replaceAtSpan(span, buf);
    }

    /// Toggle an inline mark of `kind` over `span`. If `span` already *is* a
    /// node of `kind` — its whole span or its interior `content_span` exactly
    /// equal to `span` — the mark is removed (delimiters stripped); otherwise
    /// `span` is wrapped with `open`/`close`. Mirrors a rich editor's Cmd-B:
    /// select a word, bold it; select it again, un-bold it.
    pub fn toggleInline(self: *Splicer, span: Span, kind: AST.KindRef, open: []const u8, close: []const u8) !void {
        const id = self.inlineNodeCovering(span, kind) orelse
            return self.wrapRange(span, open, close);

        const node = self.ast.nodes[id];
        // Prefer the parser's interior (correct regardless of delimiter width —
        // e.g. a multi-backtick `verbatim` whose interior the fixed-width
        // delimiters below can't strip); fall back to stripping the supplied
        // delimiters for a kind the parser leaves without a `content_span`. Both
        // replacement slices alias `self.source`, which `replaceAtSpan` copies
        // before retiring the old buffer — safe.
        if (node.content_span) |cs| {
            try self.replaceAtSpan(node.span, self.source.items[cs.start..cs.end]);
            return;
        }
        const s = self.source.items[node.span.start..node.span.end];
        if (s.len >= open.len + close.len and
            std.mem.startsWith(u8, s, open) and std.mem.endsWith(u8, s, close))
        {
            try self.replaceAtSpan(node.span, s[open.len .. s.len - close.len]);
            return;
        }
        // Matched a node of this kind but can't cleanly recover its interior.
        return error.NoContentSpan;
    }

    /// The id of a node of `kind` whose whole span or interior exactly equals
    /// `span` — the "is this selection already marked?" test behind
    /// `toggleInline`. `null` if none.
    fn inlineNodeCovering(self: *Splicer, span: Span, kind: AST.KindRef) ?Node.Id {
        for (self.ast.nodes, 0..) |node, id| {
            if (!kind.matches(node.kind)) continue;
            if (node.span.eql(span)) return @intCast(id);
            if (node.content_span) |cs| {
                if (cs.eql(span)) return @intCast(id);
            }
        }
        return null;
    }
};

// ── smart-delete whitespace tidying ────────────────────────────────────────

/// A line's content (its bytes excluding the terminating newline) is "blank"
/// if it holds only spaces/tabs (and a lone `\r` from a CRLF ending).
fn isBlankRun(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// From `from` (a line start), consume consecutive blank lines, returning the
/// offset of the first non-blank line (or `source.len`). A trailing blank
/// "line" with no newline (just whitespace before EOF) is consumed too.
fn consumeBlankLinesForward(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len) {
        var j = i;
        while (j < source.len and source[j] != '\n') j += 1;
        if (!isBlankRun(source[i..j])) break;
        i = if (j < source.len) j + 1 else j;
        if (j >= source.len) break; // trailing blank without a newline
    }
    return i;
}

/// From `from` (a line start), consume consecutive PRECEDING blank lines,
/// returning the start offset of the earliest one (or `from` if the previous
/// line isn't blank / there is none).
fn consumeBlankLinesBackward(source: []const u8, from: usize) usize {
    var s = from;
    while (s > 0 and source[s - 1] == '\n') {
        const nl = s - 1; // the newline terminating the previous line
        var pstart = nl;
        while (pstart > 0 and source[pstart - 1] != '\n') pstart -= 1;
        if (!isBlankRun(source[pstart..nl])) break;
        s = pstart;
    }
    return s;
}

/// The range to delete for a "tidy" removal of a node whose exact span is
/// `span`. If `span` occupies whole lines (starts at a line start and ends at
/// a line end — i.e. a block), the returned range also swallows the block's
/// terminating newline and the blank-line separator on one side: the trailing
/// blanks normally (leaving the leading blank as the surviving neighbors'
/// separator), or — when the block was the LAST thing in the document — the
/// leading blanks too, so nothing dangles at EOF. A mid-line span (an inline
/// node) is returned unchanged: exact delete, since line surgery there would
/// clip unrelated text.
fn tidyDeletionSpan(source: []const u8, span: Span) Span {
    const len = source.len;
    var s = span.start;
    var e = span.end;

    const at_line_start = (s == 0) or (s <= len and source[s - 1] == '\n');
    const at_line_end = (e == len) or (e < len and (source[e] == '\n' or source[e] == '\r'));
    if (!at_line_start or !at_line_end) return span;

    if (e < len and source[e] == '\r') e += 1;
    if (e < len and source[e] == '\n') e += 1;
    e = consumeBlankLinesForward(source, e);
    if (e >= len) s = consumeBlankLinesBackward(source, s);

    return Span.init(s, e);
}

// ── tests ────────────────────────────────────────────────────────────────
// XML is the test vehicle: it has real spans + `content_span` and, uniquely
// among Twig's languages, can fail to parse — which is what exercises the
// rollback path. Imported inside the test bodies so non-test builds of this
// module stay language-dependency-free.

const testing = std.testing;

fn parseXml(ctx: *const anyopaque, a: Allocator, s: []const u8) anyerror!AST {
    _ = ctx;
    const Xml = @import("../languages/xml/xml.zig");
    return Xml.parse(a, s);
}

/// Second test vehicle: Markdown, whose block children (list items, paragraphs)
/// are direct siblings separated by real newlines in the source — the shape XML
/// can't produce (it interns inter-element whitespace as its own text nodes).
/// Needed to exercise `insertChild`'s line-separated append path.
fn parseMarkdown(ctx: *const anyopaque, a: Allocator, s: []const u8) anyerror!AST {
    _ = ctx;
    const Markdown = @import("../languages/markdown/markdown.zig");
    var doc = try Markdown.parse(a, s, .{});
    doc.link_references.deinit(a);
    doc.footnotes.deinit(a);
    return doc.ast;
}

/// A throwaway context for the tests below, which use `parseXml` (which
/// ignores its `ctx`). Any stable pointer works; this is the conventional one.
const test_ctx: u8 = 0;

test "replaceContent rewrites an element interior, losslessly" {
    var ed = try Splicer.init(testing.allocator, "<a><b>hi</b></a>", &test_ctx, parseXml);
    defer ed.deinit();

    // Path [0,0] = doc -> <a> -> <b>. Replace <b>'s interior "hi".
    try ed.replaceContent(&.{ 0, 0 }, "bye");
    try testing.expectEqualStrings("<a><b>bye</b></a>", ed.sourceBytes());
}

test "insertChild appends and inserts by index" {
    var ed = try Splicer.init(testing.allocator, "<r><a/><c/></r>", &test_ctx, parseXml);
    defer ed.deinit();

    // Insert between the two children (index 1 of <r>).
    try ed.insertChild(&.{0}, 1, "<b/>");
    try testing.expectEqualStrings("<r><a/><b/><c/></r>", ed.sourceBytes());

    // Append at the end (index past child count).
    try ed.insertChild(&.{0}, 99, "<d/>");
    try testing.expectEqualStrings("<r><a/><b/><c/><d/></r>", ed.sourceBytes());

    // Insert at the front (index 0).
    try ed.insertChild(&.{0}, 0, "<z/>");
    try testing.expectEqualStrings("<r><z/><a/><b/><c/><d/></r>", ed.sourceBytes());
}

test "insertChild appends a block child onto its own line" {
    // The bullet list is the doc's first child (path [0]); its items are
    // newline-separated siblings. Appending past the end must start the new
    // item on a fresh line rather than join the last one (`- b` + `- c`).
    var ed = try Splicer.init(testing.allocator, "- a\n- b\n", &test_ctx, parseMarkdown);
    defer ed.deinit();

    try ed.insertChild(&.{0}, 99, "- c\n");
    try testing.expectEqualStrings("- a\n- b\n- c\n", ed.sourceBytes());
}

test "insertChild append injects a separator when the last line lacks a newline" {
    // No trailing newline after `- b`: the append can't step past one, so it
    // infers from the newline-separated siblings that a separator is needed and
    // injects it (rather than producing `- b- c`).
    var ed = try Splicer.init(testing.allocator, "- a\n- b", &test_ctx, parseMarkdown);
    defer ed.deinit();

    try ed.insertChild(&.{0}, 99, "- c\n");
    try testing.expectEqualStrings("- a\n- b\n- c\n", ed.sourceBytes());
}

test "insertBefore / insertAfter / deleteNode" {
    var ed = try Splicer.init(testing.allocator, "<r><a/><b/></r>", &test_ctx, parseXml);
    defer ed.deinit();

    try ed.insertAfter(&.{ 0, 0 }, "<x/>");
    try testing.expectEqualStrings("<r><a/><x/><b/></r>", ed.sourceBytes());

    try ed.deleteNode(&.{ 0, 0 });
    try testing.expectEqualStrings("<r><x/><b/></r>", ed.sourceBytes());

    try ed.insertBefore(&.{ 0, 0 }, "<y/>");
    try testing.expectEqualStrings("<r><y/><x/><b/></r>", ed.sourceBytes());
}

test "unwrapNode keeps a container's children, drops the wrapper" {
    var ed = try Splicer.init(testing.allocator, "<r><box><b/><c/></box></r>", &test_ctx, parseXml);
    defer ed.deinit();
    try ed.unwrapNode(&.{ 0, 0 }); // the <box> (doc=.{}, <r>=.{0}, <box>=.{0,0})
    try testing.expectEqualStrings("<r><b/><c/></r>", ed.sourceBytes());
}

test "unwrapNode on an empty/childless container degrades to delete" {
    var ed = try Splicer.init(testing.allocator, "<r><box/></r>", &test_ctx, parseXml);
    defer ed.deinit();
    // A self-closing element has no interior (null content_span) -> nothing to
    // keep -> the wrapper is removed.
    try ed.unwrapNode(&.{ 0, 0 });
    try testing.expectEqualStrings("<r></r>", ed.sourceBytes());
}

test "a reparse-breaking edit rolls back and leaves the document untouched" {
    var ed = try Splicer.init(testing.allocator, "<a>ok</a>", &test_ctx, parseXml);
    defer ed.deinit();

    // Replace <a>'s interior with a fragment that makes the doc malformed
    // (`<a><b></a>` — the close tag no longer matches) -> the reparse fails
    // and the whole edit is abandoned.
    try testing.expectError(error.MismatchedCloseTag, ed.replaceContent(&.{0}, "<b>"));
    // Byte-for-byte unchanged, and still a valid, navigable tree.
    try testing.expectEqualStrings("<a>ok</a>", ed.sourceBytes());
    _ = try ed.astView().getIdByPath(&.{0});
}

test "last_change records the byte effect of the last successful edit" {
    var ed = try Splicer.init(testing.allocator, "<a>hi</a>", &test_ctx, parseXml);
    defer ed.deinit();

    try testing.expectEqual(@as(?Splicer.Change, null), ed.last_change);

    // Replace "hi" [3,5) with "bye" -> new interior occupies [3,6).
    try ed.replaceContent(&.{0}, "bye");
    const c = ed.last_change.?;
    try testing.expectEqual(@as(usize, 3), c.old.start);
    try testing.expectEqual(@as(usize, 5), c.old.end);
    try testing.expectEqual(@as(usize, 3), c.new.start);
    try testing.expectEqual(@as(usize, 6), c.new.end);

    // A failed edit leaves last_change untouched.
    try testing.expectError(error.MismatchedCloseTag, ed.replaceContent(&.{0}, "<b>"));
    const c2 = ed.last_change.?;
    try testing.expectEqual(@as(usize, 6), c2.new.end);
}

test "wrapRange bolds a selection; toggleInline removes it" {
    var ed = try Splicer.init(testing.allocator, "a word b\n", &test_ctx, parseMarkdown);
    defer ed.deinit();

    // "word" is [2,6). Bold it (Markdown strong = **…**).
    try ed.wrapRange(Span.init(2, 6), "**", "**");
    try testing.expectEqualStrings("a **word** b\n", ed.sourceBytes());

    // The strong node's interior is now "word" [4,8); toggle it back off.
    try ed.toggleInline(Span.init(4, 8), .{ .mark = .strong }, "**", "**");
    try testing.expectEqualStrings("a word b\n", ed.sourceBytes());
}

test "toggleInline wraps when the range isn't already marked" {
    var ed = try Splicer.init(testing.allocator, "a word b\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try ed.toggleInline(Span.init(2, 6), .{ .mark = .emph }, "*", "*");
    try testing.expectEqualStrings("a *word* b\n", ed.sourceBytes());
}

test "toggleInline strips a verbatim run via its content_span" {
    var ed = try Splicer.init(testing.allocator, "a `code` b\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // The verbatim node is [2,8) "`code`" with content_span [3,7) "code"; toggle
    // replaces the whole node with its interior.
    try ed.toggleInline(Span.init(2, 8), .{ .text_leaf = .verbatim }, "`", "`");
    try testing.expectEqualStrings("a code b\n", ed.sourceBytes());
}

test "toggleInline strips a MULTI-backtick verbatim (content_span, not delimiter width)" {
    var ed = try Splicer.init(testing.allocator, "a ``x`` b\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // The verbatim node is [2,7) "``x``" with content_span [4,5) "x". Toggling
    // with single-backtick delimiters must still peel BOTH backtick runs — the
    // interior comes from content_span, not from stripping `open`/`close`. (The
    // old delimiter-strip fallback stripped one backtick per side, leaving the
    // corrupt "`x`".)
    try ed.toggleInline(Span.init(2, 7), .{ .text_leaf = .verbatim }, "`", "`");
    try testing.expectEqualStrings("a x b\n", ed.sourceBytes());
}

test "replaceContent on a leaf yields NoContentSpan" {
    var ed = try Splicer.init(testing.allocator, "<a>hi</a>", &test_ctx, parseXml);
    defer ed.deinit();
    // [0,0] = the "hi" text node, a leaf: no interior to splice.
    try testing.expectError(error.NoContentSpan, ed.replaceContent(&.{ 0, 0 }, "x"));
}

test "replaceContent on a code_block replaces the body, fences intact" {
    var ed = try Splicer.init(testing.allocator, "```\nold\n```\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // [0] = the code_block (root's first child). A code_block is a text leaf,
    // but it carries a content_span (its body), so replaceContent works.
    try ed.replaceContent(&.{0}, "new");
    try testing.expectEqualStrings("```\nnew\n```\n", ed.sourceBytes());
}

test "insertChild on a code_block is rejected (NotAContainer)" {
    var ed = try Splicer.init(testing.allocator, "```\ncode\n```\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // A code_block has a content_span but no child sequence: inserting a
    // *child* is meaningless, so it's refused (unlike an empty container).
    try testing.expectError(error.NotAContainer, ed.insertChild(&.{0}, 0, "x"));
}

test "path navigation reports out-of-bounds" {
    var ed = try Splicer.init(testing.allocator, "<a><b/></a>", &test_ctx, parseXml);
    defer ed.deinit();
    try testing.expectError(error.PathOutOfBounds, ed.astView().getIdByPath(&.{ 0, 5 }));
    try testing.expectError(error.PathOutOfBounds, ed.astView().getIdByPath(&.{ 0, 0, 0 }));
}

// ── smart-delete (tidyDeletionSpan) ─────────────────────────────────────────

/// Apply `tidyDeletionSpan` to `src` at `[start,end)` and return the resulting
/// bytes (what a smart delete of that span would leave behind).
fn tidyDelete(src: []const u8, start: usize, end: usize) [256]u8 {
    var buf: [256]u8 = undefined;
    const del = tidyDeletionSpan(src, Span.init(start, end));
    const n = del.start + (src.len - del.end);
    @memcpy(buf[0..del.start], src[0..del.start]);
    @memcpy(buf[del.start..n], src[del.end..]);
    return buf;
}

fn expectTidy(src: []const u8, start: usize, end: usize, want: []const u8) !void {
    const buf = tidyDelete(src, start, end);
    const del = tidyDeletionSpan(src, Span.init(start, end));
    const got = buf[0 .. del.start + (src.len - del.end)];
    try testing.expectEqualStrings(want, got);
}

test "tidyDeletionSpan: middle block leaves exactly one blank-line separator" {
    // "A\n\nB\n\nC\n", delete B ([3,4)).
    try expectTidy("A\n\nB\n\nC\n", 3, 4, "A\n\nC\n");
}

test "tidyDeletionSpan: first block leaves the rest clean at the top" {
    try expectTidy("A\n\nB\n\nC\n", 0, 1, "B\n\nC\n");
}

test "tidyDeletionSpan: last block trims the now-dangling trailing blank" {
    // "A\n\nB\n\nC\n", delete C ([6,7)) -> no trailing blank left after B.
    try expectTidy("A\n\nB\n\nC\n", 6, 7, "A\n\nB\n");
}

test "tidyDeletionSpan: adjacent blocks with no blank line between them" {
    try expectTidy("# A\n# B\n# C\n", 4, 7, "# A\n# C\n");
}

test "tidyDeletionSpan: a multi-line block plus its blank separator" {
    // A two-line block between two others; delete it and one separator.
    const src = "top\n\n:::x\nbody\n:::\n\nbottom\n";
    // block span = the ":::x\nbody\n:::" region = [5, 18)
    try expectTidy(src, 5, 18, "top\n\nbottom\n");
}

test "tidyDeletionSpan: the only block empties the document" {
    try expectTidy("A\n", 0, 1, "");
}

test "tidyDeletionSpan: a mid-line (inline) span is deleted exactly, no line surgery" {
    // "a *b* c\n", delete the "*b*" at [2,5): must NOT swallow the line.
    try expectTidy("a *b* c\n", 2, 5, "a  c\n");
}

// ── undo / redo ──────────────────────────────────────────────────────────────

test "undo restores the pre-edit source; redo re-applies it" {
    var ed = try Splicer.init(testing.allocator, "hello\n", &test_ctx, parseMarkdown);
    defer ed.deinit();

    try ed.replaceAtSpan(Span.init(5, 5), "!");
    try testing.expectEqualStrings("hello!\n", ed.sourceBytes());

    const undone = (try ed.undo()).?;
    try testing.expectEqualStrings("hello\n", ed.sourceBytes());
    // The change reports where the edit was, in the restored source.
    try testing.expectEqual(@as(usize, 5), undone.new.end);

    const redone = (try ed.redo()).?;
    try testing.expectEqualStrings("hello!\n", ed.sourceBytes());
    try testing.expectEqual(@as(usize, 6), redone.new.end);
}

test "undo and redo are no-ops (null) at the ends of history" {
    var ed = try Splicer.init(testing.allocator, "x\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try testing.expect((try ed.undo()) == null);
    try ed.replaceAtSpan(Span.init(1, 1), "y");
    _ = try ed.undo();
    try testing.expect((try ed.undo()) == null); // history exhausted
    _ = try ed.redo();
    try testing.expect((try ed.redo()) == null);
}

test "coalesceLastUndo folds a keystroke run into one undo step" {
    var ed = try Splicer.init(testing.allocator, "\n", &test_ctx, parseMarkdown);
    defer ed.deinit();

    // Simulate typing "abc": the first splice is its own step, each following
    // one coalesces into it (what a frontend does for a run of typing).
    try ed.replaceAtSpan(Span.init(0, 0), "a");
    try ed.replaceAtSpan(Span.init(1, 1), "b");
    ed.coalesceLastUndo();
    try ed.replaceAtSpan(Span.init(2, 2), "c");
    ed.coalesceLastUndo();
    try testing.expectEqualStrings("abc\n", ed.sourceBytes());

    // One undo removes the whole run.
    _ = try ed.undo();
    try testing.expectEqualStrings("\n", ed.sourceBytes());
    try testing.expect((try ed.undo()) == null);
}

test "a fresh edit invalidates the redo stack" {
    var ed = try Splicer.init(testing.allocator, "\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try ed.replaceAtSpan(Span.init(0, 0), "a");
    _ = try ed.undo(); // redo now holds the "a" state
    try ed.replaceAtSpan(Span.init(0, 0), "b"); // diverge
    try testing.expect((try ed.redo()) == null);
    try testing.expectEqualStrings("b\n", ed.sourceBytes());
}

// ── revision token ────────────────────────────────────────────────────────────

test "revision starts at 0 and bumps once per successful mutation" {
    var ed = try Splicer.init(testing.allocator, "x\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try testing.expectEqual(@as(u64, 0), ed.revision);

    try ed.replaceAtSpan(Span.init(1, 1), "y");
    try testing.expectEqual(@as(u64, 1), ed.revision);

    // A failed (reparse-breaking) edit must NOT bump the revision.
    var xml = try Splicer.init(testing.allocator, "<a>ok</a>", &test_ctx, parseXml);
    defer xml.deinit();
    try testing.expectEqual(@as(u64, 0), xml.revision);
    try testing.expectError(error.MismatchedCloseTag, xml.replaceContent(&.{0}, "<b>"));
    try testing.expectEqual(@as(u64, 0), xml.revision);

    // undo and redo are mutations too, so they each bump.
    _ = try ed.undo();
    try testing.expectEqual(@as(u64, 2), ed.revision);
    _ = try ed.redo();
    try testing.expectEqual(@as(u64, 3), ed.revision);

    // A no-op undo (nothing to undo) changes nothing.
    _ = try ed.undo();
    const r = ed.revision;
    try testing.expect((try ed.undo()) == null);
    try testing.expectEqual(r, ed.revision);
}

// ── dirty range ─────────────────────────────────────────────────────────────

test "dirty range is null on a fresh editor and after clearDirty" {
    var ed = try Splicer.init(testing.allocator, "abc\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try testing.expect(ed.dirtyRange() == null);

    try ed.replaceAtSpan(Span.init(1, 1), "X"); // "aXbc\n"
    try testing.expect(ed.dirtyRange() != null);

    ed.clearDirty();
    try testing.expect(ed.dirtyRange() == null);
    // clearDirty leaves revision untouched — it only acknowledges the range.
    const rev = ed.revision;
    ed.clearDirty();
    try testing.expectEqual(rev, ed.revision);
}

test "a single edit's dirty range is exactly its inserted bytes" {
    var ed = try Splicer.init(testing.allocator, "abcd\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // Insert two bytes at offset 2: the changed span is [2,4).
    try ed.replaceAtSpan(Span.init(2, 2), "XY"); // "abXYcd\n"
    const d = ed.dirtyRange().?;
    try testing.expectEqual(@as(usize, 2), d.start);
    try testing.expectEqual(@as(usize, 4), d.end);
    // Everything the dirty range excludes is byte-identical to before — the
    // losslessness guarantee the range rides on.
    try testing.expectEqualStrings("abXYcd\n", ed.sourceBytes());
}

test "dirty range accumulates conservatively across disjoint edits" {
    var ed = try Splicer.init(testing.allocator, "abcdefgh\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // Edit near the end first: insert at offset 6 -> changed [6,7).
    try ed.replaceAtSpan(Span.init(6, 6), "Z"); // "abcdefZgh\n"
    try testing.expectEqual(@as(usize, 6), ed.dirtyRange().?.start);
    try testing.expectEqual(@as(usize, 7), ed.dirtyRange().?.end);

    // Now edit near the start: insert at offset 1 -> changed [1,2). The prior
    // range [6,7) shifts right by the +1 delta to [7,8); the union spans both.
    try ed.replaceAtSpan(Span.init(1, 1), "Y"); // "aYbcdefZgh\n"
    const d = ed.dirtyRange().?;
    try testing.expectEqual(@as(usize, 1), d.start); // low bound = new start
    try testing.expectEqual(@as(usize, 8), d.end); // high bound = shifted old end
    // The reported range is a superset of both individual edits (conservative).
    try testing.expect(d.start <= 1 and d.end >= 8);
}

test "a deletion shifts a later dirty region left" {
    var ed = try Splicer.init(testing.allocator, "abcdefgh\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // Dirty a late region: insert at 6 -> [6,7).
    try ed.replaceAtSpan(Span.init(6, 6), "Z"); // "abcdefZgh\n", dirty [6,7)
    // Delete two bytes near the front: [1,3) -> "" (delta -2). The late region
    // shifts left by 2 to [4,5); union with the deletion point [1,1) is [1,5).
    try ed.replaceAtSpan(Span.init(1, 3), ""); // "adefZgh\n"
    const d = ed.dirtyRange().?;
    try testing.expectEqual(@as(usize, 1), d.start);
    try testing.expectEqual(@as(usize, 5), d.end);
    // The shifted high bound still lands on the 'Z' it was tracking.
    try testing.expectEqualStrings("adefZgh\n", ed.sourceBytes());
    try testing.expectEqual(@as(u8, 'Z'), ed.sourceBytes()[4]);
}

test "undo and redo dirty the range they touch" {
    var ed = try Splicer.init(testing.allocator, "abc\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try ed.replaceAtSpan(Span.init(3, 3), "d"); // "abcd\n"
    ed.clearDirty();
    try testing.expect(ed.dirtyRange() == null);

    // Undo restores "abc\n": the byte that differs is the removed 'd' at [3,3).
    _ = try ed.undo();
    try testing.expect(ed.dirtyRange() != null);

    ed.clearDirty();
    // Redo re-adds 'd': changed span [3,4).
    _ = try ed.redo();
    const d = ed.dirtyRange().?;
    try testing.expectEqual(@as(usize, 3), d.start);
    try testing.expectEqual(@as(usize, 4), d.end);
}

test "a failed edit leaves the dirty range untouched" {
    var xml = try Splicer.init(testing.allocator, "<a>ok</a>", &test_ctx, parseXml);
    defer xml.deinit();
    try testing.expect(xml.dirtyRange() == null);
    // A reparse-breaking edit rolls back; nothing is dirtied.
    try testing.expectError(error.MismatchedCloseTag, xml.replaceContent(&.{0}, "<b>"));
    try testing.expect(xml.dirtyRange() == null);
}

// ── opaque caret blob ─────────────────────────────────────────────────────────

test "setCaret/caretBlob round-trips an opaque host blob" {
    var ed = try Splicer.init(testing.allocator, "x\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    try testing.expectEqualStrings("", ed.caretBlob()); // none by default

    try ed.setCaret("caret@3");
    try testing.expectEqualStrings("caret@3", ed.caretBlob());

    // twig owns its copy: mutating the caller's bytes doesn't disturb it.
    var buf = [_]u8{ 'z', 'z' };
    try ed.setCaret(&buf);
    buf[0] = 'q';
    try testing.expectEqualStrings("zz", ed.caretBlob());

    try ed.setCaret(""); // clears
    try testing.expectEqualStrings("", ed.caretBlob());
}

test "undo restores the pre-edit caret; redo restores the post-edit caret" {
    var ed = try Splicer.init(testing.allocator, "hello\n", &test_ctx, parseMarkdown);
    defer ed.deinit();

    // Host sets the caret for the current state BEFORE editing, so the retired
    // undo step carries it.
    try ed.setCaret("before");
    try ed.replaceAtSpan(Span.init(5, 5), "!");
    // The new state starts caret-less; the host sets the post-edit caret.
    try testing.expectEqualStrings("", ed.caretBlob());
    try ed.setCaret("after");

    // Undo hands back the pre-edit caret with the pre-edit source.
    _ = try ed.undo();
    try testing.expectEqualStrings("hello\n", ed.sourceBytes());
    try testing.expectEqualStrings("before", ed.caretBlob());

    // Redo hands back the post-edit caret with the post-edit source.
    _ = try ed.redo();
    try testing.expectEqualStrings("hello!\n", ed.sourceBytes());
    try testing.expectEqualStrings("after", ed.caretBlob());
}

test "coalesced run keeps the caret from before the run began" {
    var ed = try Splicer.init(testing.allocator, "\n", &test_ctx, parseMarkdown);
    defer ed.deinit();

    // Type "abc" as a coalesced run, each keystroke preceded by its caret.
    try ed.setCaret("c0");
    try ed.replaceAtSpan(Span.init(0, 0), "a");
    try ed.setCaret("c1");
    try ed.replaceAtSpan(Span.init(1, 1), "b");
    ed.coalesceLastUndo();
    try ed.setCaret("c2");
    try ed.replaceAtSpan(Span.init(2, 2), "c");
    ed.coalesceLastUndo();
    try ed.setCaret("c3"); // caret after the whole run

    // One undo removes the run and restores the caret from before it began.
    _ = try ed.undo();
    try testing.expectEqualStrings("\n", ed.sourceBytes());
    try testing.expectEqualStrings("c0", ed.caretBlob());

    // Redo restores the end-of-run caret.
    _ = try ed.redo();
    try testing.expectEqualStrings("abc\n", ed.sourceBytes());
    try testing.expectEqualStrings("c3", ed.caretBlob());
}

test "caret blobs are evicted with their step past MAX_UNDO (no leak)" {
    var ed = try Splicer.init(testing.allocator, "\n", &test_ctx, parseMarkdown);
    defer ed.deinit();
    // Push more than MAX_UNDO steps, each with a caret blob, so the oldest are
    // evicted; the leak-checking allocator asserts nothing is dropped.
    var i: usize = 0;
    while (i < MAX_UNDO + 10) : (i += 1) {
        try ed.setCaret("caret-blob-payload");
        try ed.replaceAtSpan(Span.init(0, 0), "x");
    }
    try testing.expectEqual(MAX_UNDO, ed.undo_stack.items.len);
}
