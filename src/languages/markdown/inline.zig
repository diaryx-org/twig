//! Phase 2 inline scanning: the full CommonMark inline grammar. Phase 1
//! (still intact below: backslash escapes, entity/numeric references, code
//! spans, soft/hard breaks) is extended here with emphasis/strong, links,
//! images, autolinks, and raw inline HTML — see `markdown.zig`'s module doc
//! comment for the phase boundary.
//!
//! ── Strategy ─────────────────────────────────────────────────────────────
//! Mirrors the strategy CommonMark's spec appendix ("A parsing strategy")
//! and `cmark`'s `inlines.c` both use: a single left-to-right scan produces a
//! flat sequence of inline "items" (`Scanner.items`, a doubly-linked list
//! built over an arena array rather than real pointers, since Zig arrays give
//! us stable indices without a GC) — most items are already-finished AST
//! nodes (text runs, code spans, breaks, autolinks, raw HTML), but `*`/`_`
//! delimiter runs and `[`/`![` brackets are pushed as PLACEHOLDER text items
//! (holding their literal run text) alongside a side-table entry on a
//! delimiter stack (`Scanner.delims`) or bracket stack (`Scanner.brackets`).
//! Links/images resolve eagerly, right when their closing `]` is scanned
//! (per spec, this can't wait for a second pass, since "links cannot contain
//! links" needs to know about closures as they happen); emphasis resolves
//! lazily, via the bottom-up `process_emphasis` pass over the delimiter
//! stack, run once over each link/image's contents (right before that
//! bracket resolves, so nested emphasis binds inside the link text) and once
//! more over whatever's left at the very end of the scan.
//!
//! Code spans, autolinks, and raw HTML are recognized as part of the SAME
//! left-to-right scan as backslash escapes and entities (all higher
//! precedence than emphasis/link delimiters, per spec), so e.g. `` *`a*` ``
//! never lets the `*` inside the code span participate in emphasis matching
//! — by the time the delimiter stack sees anything, the code span has
//! already been consumed as one atomic item.
//!
//! ── Reference links resolve at PARSE time ───────────────────────────────
//! Unlike djot (which keeps a reference table for the renderer to consult),
//! CommonMark reference links/images are resolved HERE, against
//! `Document.link_references` (threaded in as `link_refs`), producing a
//! `link`/`image` node with `destination` set and `reference == null` — this
//! file's caller (`block.zig`) defers calling `parseInline` until the WHOLE
//! document's block structure (and therefore every link reference
//! definition, including ones that appear after their first use) has been
//! parsed, specifically so forward references resolve correctly. See
//! `block.zig`'s `pending_inline`/`resolvePendingInline` for that
//! deferral. An unresolved label's brackets fall back to literal text, per
//! spec.
//!
//! ── Documented approximations ───────────────────────────────────────────
//! - Emphasis flanking (`computeFlanking`) classifies "Unicode whitespace"
//!   and "Unicode punctuation" fully for ASCII (matching `isAsciiPunct`
//!   below) but only approximately for non-ASCII code points (a curated
//!   table of common punctuation/space blocks — General Punctuation, CJK
//!   punctuation, fullwidth ASCII forms — rather than the complete Unicode
//!   General Category tables). Spec examples that hinge on obscure non-ASCII
//!   punctuation classification may not pass; this is the same style of
//!   tradeoff `block.zig`'s tab-handling approximation makes.
//! - `process_emphasis` (below) deliberately omits cmark's `openers_bottom`
//!   memoization table (a pure performance optimization that's easy to get
//!   subtly wrong — a 2-bucket, rather than 3-bucket, `length % 3`
//!   memoization can silently skip valid matches). Always rescanning back to
//!   `stack_bottom` is O(n^2) in the delimiter count instead of amortized
//!   O(n), which is fine at paragraph scale.
//! - Reference-form fallback: if `]` is immediately followed by a `[...]`
//!   that fails to scan as a syntactically valid label (e.g. contains an
//!   unescaped nested `[`), this falls back to trying the SHORTCUT form
//!   (the opening bracket's own text) rather than failing outright. This is
//!   a defensible reading of the spec's fallback chain but not exhaustively
//!   cross-checked against cmark's exact behavior for this rare corner.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const Span = @import("../../span.zig");
const entities = @import("entities.zig");
const Options = @import("options.zig");
const attrs_mod = @import("attributes.zig");

/// One contiguous run of a leaf block's assembled `text` that maps 1:1 onto
/// real source bytes: `text[buf_offset..buf_offset+len]` is byte-for-byte
/// identical to `source[src_offset..src_offset+len]`. `block.zig` builds a
/// leaf block's `text` by copying/joining possibly-noncontiguous source runs
/// (indentation/markers stripped, lines joined with a synthetic `\n`
/// separator) — this is how `parseInline` maps a byte offset in ITS `text`
/// back to an absolute offset in the original source (`Scanner.mapSpan`),
/// when that's even possible. A `text` byte not covered by any segment (e.g.
/// a synthetic line-join separator, or one that came from a multi-line join
/// whose two sides land in different segments) simply has no source mapping
/// — `mapSpan` returns `null` for any request that isn't fully contained in
/// ONE segment, and the caller leaves that node's span unset (`(0,0)`)
/// rather than risk an inaccurate one. See `block.zig`'s module doc comment
/// section on inline spans for how these are built.
pub const Segment = struct {
    buf_offset: usize,
    src_offset: usize,
    len: usize,
};

/// Parse `text` (a single leaf block's already-assembled content — see this
/// file's module doc comment) into a flat sequence of inline children, added
/// to `b` but not yet attached to any parent. `link_refs` is
/// `Document.link_references`'s underlying map (label, already normalized
/// per `block.zig`'s `normalizeLabel` -> the `reference` node holding that
/// definition's destination/title), consulted for reference-style links and
/// images; it must already be COMPLETE (every link reference definition in
/// the document registered), which is why `block.zig` defers calling this
/// until block-level parsing has finished. `options` gates Phase 3's
/// inline-level extensions (strikethrough, math, GFM extended autolinks —
/// see the "Phase 3" section below); every extension this file recognizes
/// checks `sc.options.<flag>` at its own dispatch point, so `options ==
/// .commonmark` reproduces Phase 2's behavior exactly. `segments` maps
/// `text` offsets back to absolute source offsets (see `Segment`'s doc
/// comment) — every node this scan creates gets its `span` (and, for
/// containers with a meaningful interior, `content_span`) set from it when
/// the mapping is available, left unset (`(0,0)`) otherwise. Returns the
/// ordered list of child ids (caller's to free; typically immediately
/// handed to `b.setChildren`).
/// One-shot inline parse: constructs a throwaway `Scanner`. External callers
/// and tests use this; a document that resolves many inline blocks should
/// instead pool one scanner via `initScanner` + `scanReuse` (see
/// `block.zig`'s `resolvePendingInline`) to avoid re-allocating the scanner's
/// working buffers per block.
pub fn parseInline(b: *Builder, text: []const u8, segments: []const Segment, link_refs: *const std.StringHashMapUnmanaged(Node.Id), options: Options) Allocator.Error![]Node.Id {
    var sc: Scanner = .{ .b = b, .link_refs = link_refs, .options = options, .segments = segments };
    defer sc.deinit();
    return runScan(&sc, text);
}

/// Construct a reusable inline `Scanner`. `b`/`link_refs`/`options` are fixed
/// for a whole document; only `segments` (and the working buffers) change per
/// block, so one scanner can be reset and reused across every inline block.
/// The caller owns it and must `deinit` it.
pub fn initScanner(b: *Builder, link_refs: *const std.StringHashMapUnmanaged(Node.Id), options: Options) Scanner {
    return .{ .b = b, .link_refs = link_refs, .options = options };
}

/// Parse one inline block reusing `sc`'s already-allocated buffers (their
/// capacity is retained across blocks). Result is caller-owned, exactly like
/// `parseInline`.
pub fn scanReuse(sc: *Scanner, text: []const u8, segments: []const Segment) Allocator.Error![]Node.Id {
    sc.reset(segments);
    return runScan(sc, text);
}

fn runScan(sc: *Scanner, text: []const u8) Allocator.Error![]Node.Id {
    const b = sc.b;
    var i: usize = 0;
    while (i < text.len) {
        if (sc.buf.items.len == 0) {
            sc.buf_start = i;
            sc.buf_pure = true;
        }
        const c = text[i];
        switch (c) {
            '\\' => {
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    // Backslash immediately before a line ending: hard break.
                    try sc.flushBuf(i);
                    const id = try b.addLeaf(.hard_break);
                    sc.setSpanIfMapped(id, i, i + 2);
                    _ = try sc.appendItem(id);
                    i += 2;
                    i = skipLeadingLineSpace(text, i);
                    continue;
                }
                if (i + 1 < text.len and isAsciiPunct(text[i + 1])) {
                    try sc.buf.append(b.allocator, text[i + 1]);
                    sc.buf_pure = false; // 2 source bytes -> 1 buf byte
                    i += 2;
                    continue;
                }
                try sc.buf.append(b.allocator, '\\');
                i += 1;
            },
            '\n' => {
                const hard = trailingHardBreakSpaces(sc.buf.items);
                sc.buf.items.len -= hard;
                try sc.flushBuf(i - hard);
                const kind: Node.Kind = if (hard >= 2) .hard_break else .soft_break;
                const id = try b.addLeaf(kind);
                sc.setSpanIfMapped(id, i - hard, i + 1);
                _ = try sc.appendItem(id);
                i += 1;
                i = skipLeadingLineSpace(text, i);
            },
            '`' => {
                if (scanCodeSpan(text, i)) |span| {
                    try sc.flushBuf(i);
                    const content = try normalizeCodeSpan(b.allocator, text[span.content_start..span.content_end]);
                    defer b.allocator.free(content);
                    const id = try b.addLeaf(.{ .verbatim = content });
                    sc.setSpanIfMapped(id, i, span.end);
                    _ = try sc.appendItem(id);
                    i = span.end;
                } else {
                    // No closing run of the SAME length as this opening run
                    // exists anywhere later in `text`: the whole opening run
                    // is literal backticks -- see `scanCodeSpan`'s doc
                    // comment.
                    var run_end = i;
                    while (run_end < text.len and text[run_end] == '`') run_end += 1;
                    try sc.buf.appendSlice(b.allocator, text[i..run_end]);
                    i = run_end;
                }
            },
            '&' => {
                if (try decodeCharRef(b.allocator, text, i)) |ref| {
                    try sc.buf.appendSlice(b.allocator, ref.text);
                    b.allocator.free(ref.text);
                    sc.buf_pure = false; // decoded reference -> not a verbatim copy
                    i = ref.end;
                } else {
                    try sc.buf.append(b.allocator, '&');
                    i += 1;
                }
            },
            '<' => {
                if (scanAutolinkUri(text, i)) |end| {
                    try sc.flushBuf(i);
                    const id = try b.addLeaf(.{ .url = text[i + 1 .. end - 1] });
                    sc.setSpanIfMapped(id, i, end);
                    _ = try sc.appendItem(id);
                    i = end;
                } else if (scanAutolinkEmail(text, i)) |end| {
                    try sc.flushBuf(i);
                    const id = try b.addLeaf(.{ .email = text[i + 1 .. end - 1] });
                    sc.setSpanIfMapped(id, i, end);
                    _ = try sc.appendItem(id);
                    i = end;
                } else if (scanHtmlTag(text, i)) |end| {
                    try sc.flushBuf(i);
                    const id = try b.addLeaf(.{ .raw_inline = .{ .format = "html", .text = text[i..end] } });
                    sc.setSpanIfMapped(id, i, end);
                    _ = try sc.appendItem(id);
                    i = end;
                } else {
                    try sc.buf.append(b.allocator, '<');
                    i += 1;
                }
            },
            '*', '_' => {
                var run_end = i;
                while (run_end < text.len and text[run_end] == c) run_end += 1;
                const flank = computeFlanking(text, i, run_end, c);
                if (flank.can_open or flank.can_close) {
                    // Only a run that could ever participate in matching
                    // needs its own item (so `spliceEmphasis` can shrink/
                    // bypass it later) -- a run with neither flag is
                    // permanently inert, so just fold it into the ambient
                    // literal-text buffer like any other character, which
                    // also keeps the AST from fragmenting into a fresh `str`
                    // node at every non-flanking `*`/`_` (e.g. `a_b_c`).
                    try sc.flushBuf(i);
                    const run_id = try b.addLeaf(.{ .str = text[i..run_end] });
                    sc.setSpanIfMapped(run_id, i, run_end);
                    const item_idx = try sc.appendItem(run_id);
                    try sc.delims.append(b.allocator, .{
                        .item = item_idx,
                        .char = c,
                        .count = run_end - i,
                        .can_open = flank.can_open,
                        .can_close = flank.can_close,
                        .range_start = i,
                        .range_end = run_end,
                    });
                } else {
                    try sc.buf.appendSlice(b.allocator, text[i..run_end]);
                }
                i = run_end;
            },
            '[' => {
                // GFM/Pandoc footnote reference (`self.options.footnotes`):
                // `[^label]` takes precedence over ordinary link-bracket
                // parsing -- resolved and consumed whole right here, before
                // any bracket-stack state is pushed, so it never interacts
                // with link/image bracket matching at all. With the flag off
                // (or `[` not immediately followed by `^`), this falls
                // through to the ordinary `[` handling below exactly as
                // before -- see `tryFootnoteReference`'s doc comment.
                if (sc.options.footnotes) {
                    if (tryFootnoteReference(text, i)) |fr| {
                        try sc.flushBuf(i);
                        const norm = try normalizeRefLabel(b.allocator, fr.label);
                        defer b.allocator.free(norm);
                        const id = try b.addLeaf(.{ .footnote_reference = norm });
                        sc.setSpanIfMapped(id, i, fr.end);
                        _ = try sc.appendItem(id);
                        i = fr.end;
                        continue;
                    }
                }
                try sc.flushBuf(i);
                const open_id = try b.addLeaf(.{ .str = "[" });
                sc.setSpanIfMapped(open_id, i, i + 1);
                const item_idx = try sc.appendItem(open_id);
                try sc.brackets.append(b.allocator, .{
                    .item = item_idx,
                    .is_image = false,
                    .active = true,
                    .open_start = i,
                    .content_start = i + 1,
                    .delim_stack_len = sc.delims.items.len,
                    .tilde_stack_len = sc.tilde_delims.items.len,
                });
                i += 1;
            },
            '!' => {
                if (i + 1 < text.len and text[i + 1] == '[') {
                    try sc.flushBuf(i);
                    const open_id = try b.addLeaf(.{ .str = "![" });
                    sc.setSpanIfMapped(open_id, i, i + 2);
                    const item_idx = try sc.appendItem(open_id);
                    try sc.brackets.append(b.allocator, .{
                        .item = item_idx,
                        .is_image = true,
                        .active = true,
                        .open_start = i,
                        .content_start = i + 2,
                        .delim_stack_len = sc.delims.items.len,
                        .tilde_stack_len = sc.tilde_delims.items.len,
                    });
                    i += 2;
                } else {
                    try sc.buf.append(b.allocator, '!');
                    i += 1;
                }
            },
            ']' => {
                try sc.flushBuf(i);
                i = try handleCloseBracket(sc, text, i);
            },
            '~' => {
                // GFM strikethrough (`self.options.strikethrough`): a `~`/`~~`
                // delimiter run, reusing the SAME flanking classification as
                // `*`/`_` (no intraword restriction, since `computeFlanking`
                // only special-cases `ch == '_'`) but its OWN delimiter stack
                // and matching pass (`tilde_delims`/`processStrikethrough`)
                // rather than folding into `delims`/`processEmphasis` — GFM
                // strikethrough has NO "rule of 3" and only ever matches
                // EQUAL-length runs of 1 or 2, both of which would be wrong if
                // it shared CommonMark emphasis's matching algorithm. A run
                // longer than 2 is never eligible (GFM requires "one or two
                // tildes"), so it always falls back to literal text.
                var run_end = i;
                while (run_end < text.len and text[run_end] == '~') run_end += 1;
                const run_len = run_end - i;
                const flank = if (sc.options.strikethrough) computeFlanking(text, i, run_end, '~') else Flank{ .can_open = false, .can_close = false };
                if (run_len <= 2 and (flank.can_open or flank.can_close)) {
                    try sc.flushBuf(i);
                    const run_id = try b.addLeaf(.{ .str = text[i..run_end] });
                    sc.setSpanIfMapped(run_id, i, run_end);
                    const item_idx = try sc.appendItem(run_id);
                    try sc.tilde_delims.append(b.allocator, .{
                        .item = item_idx,
                        .count = run_len,
                        .can_open = flank.can_open,
                        .can_close = flank.can_close,
                        .range_start = i,
                        .range_end = run_end,
                    });
                } else {
                    try sc.buf.appendSlice(b.allocator, text[i..run_end]);
                }
                i = run_end;
            },
            '$' => {
                // Twig's inline/display math extension (`self.options.math`,
                // OFF by default — not part of CommonMark or GFM). `$$...$$`
                // (display) is tried before single-`$` (inline) so `$$x$$`
                // doesn't parse as an empty inline-math pair either side of
                // `x`. Neither delimiter may be immediately preceded/followed
                // by whitespace at its inner edge (mirrors common `$...$`
                // math conventions, e.g. Pandoc's), which keeps stray prose
                // dollar signs ("$5 and $10") from being misread.
                var matched: ?struct { kind: Node.Kind, end: usize } = null;
                if (sc.options.math) {
                    if (i + 1 < text.len and text[i + 1] == '$') {
                        if (scanDisplayMath(text, i)) |m| {
                            matched = .{ .kind = .{ .display_math = text[i + 2 .. m.content_end] }, .end = m.end };
                        }
                    } else if (scanInlineMath(text, i)) |m| {
                        matched = .{ .kind = .{ .inline_math = text[i + 1 .. m.content_end] }, .end = m.end };
                    }
                }
                if (matched) |m| {
                    try sc.flushBuf(i);
                    const id = try b.addLeaf(m.kind);
                    sc.setSpanIfMapped(id, i, m.end);
                    _ = try sc.appendItem(id);
                    i = m.end;
                } else {
                    try sc.buf.append(b.allocator, '$');
                    i += 1;
                }
            },
            'h', 'f', 'w' => {
                // GFM extended autolinks (`self.options.autolinks`): bare
                // `http(s)://...`/`ftp://...`/`www...` URLs in ordinary text,
                // as opposed to Phase 2's CommonMark-core `<scheme:...>` form
                // (which stays on unconditionally via the `<` case above,
                // regardless of this flag). See `tryExtUrlAutolink`/
                // `tryExtWwwAutolink` for the word-boundary and trailing-
                // punctuation-trimming rules approximated here.
                const auto_end: ?usize = if (sc.options.autolinks)
                    (if (c == 'w') try tryExtWwwAutolink(sc, text, i) else try tryExtUrlAutolink(sc, text, i))
                else
                    null;
                if (auto_end) |end| {
                    i = end;
                } else {
                    try sc.buf.append(b.allocator, c);
                    i += 1;
                }
            },
            '@' => {
                // GFM extended email autolink: unlike the `http`/`www` forms,
                // the LOCAL part of the address is already sitting in `buf`
                // (ordinary preceding text) by the time `@` is seen, so
                // `tryExtEmailAutolink` reaches backward into `buf` to claim
                // it -- see that function's doc comment.
                const auto_end: ?usize = if (sc.options.autolinks) try tryExtEmailAutolink(sc, text, i) else null;
                if (auto_end) |end| {
                    i = end;
                } else {
                    try sc.buf.append(b.allocator, '@');
                    i += 1;
                }
            },
            ':' => {
                // Text (inline) directive (`self.options.directives`):
                // `:name[label]{attrs}` — single colon, name, optional
                // bracketed inline label, optional attribute shorthand. The
                // label (if present) is parsed as inline content and becomes
                // the directive node's children.
                const td: ?TextDirective = if (sc.options.directives) try scanTextDirective(b.allocator, text, i) else null;
                if (td) |d| {
                    try sc.flushBuf(i);
                    const id = try buildTextDirective(sc, d);
                    sc.setSpanIfMapped(id, i, d.end);
                    if (d.label) |lab| sc.setContentSpanIfMapped(id, lab.start, lab.end);
                    _ = try sc.appendItem(id);
                    i = d.end;
                } else {
                    try sc.buf.append(b.allocator, ':');
                    i += 1;
                }
            },
            else => {
                try sc.buf.append(b.allocator, c);
                i += 1;
            },
        }
    }
    try sc.flushBuf(text.len);
    // Resolve whatever emphasis/strikethrough delimiters are left over the
    // WHOLE stack.
    try sc.processEmphasis(0);
    try sc.processStrikethrough(0);

    var out = std.ArrayList(Node.Id).empty;
    errdefer out.deinit(b.allocator);
    var cur = sc.head;
    while (cur) |ci| {
        try out.append(b.allocator, sc.items.items[ci].node);
        cur = sc.items.items[ci].next;
    }
    return out.toOwnedSlice(b.allocator);
}

/// Backslash-escape and entity/numeric-character-reference decoding only —
/// no code spans, no break detection — for the plain-text contexts that
/// need *some* inline processing without being a full inline scan: a fenced
/// code block's info string (whose first word becomes `code_block.lang`;
/// CommonMark decodes entities there, e.g. `` ```f&ouml;&ouml; `` names the
/// language `föö`), link reference definition destinations/titles
/// (`block.zig`'s `stripLinkReferenceDefinitions`), and this file's own
/// inline link destination/title decoding (`handleCloseBracket`). Caller-
/// owned result.
pub fn decodeText(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and isAsciiPunct(text[i + 1])) {
            try out.append(allocator, text[i + 1]);
            i += 2;
        } else if (c == '&') {
            if (try decodeCharRef(allocator, text, i)) |ref| {
                try out.appendSlice(allocator, ref.text);
                allocator.free(ref.text);
                i = ref.end;
            } else {
                try out.append(allocator, c);
                i += 1;
            }
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── the item list / delimiter stack / bracket stack ─────────────────────

const ItemIdx = u32;

/// One entry of the flat inline sequence `Scanner` builds. `node` is always
/// a real, already-`Builder`-owned AST node id — for a `*`/`_` delimiter run
/// or a `[`/`![` bracket, that's a placeholder `str` leaf holding the
/// literal run/bracket text, which `spliceEmphasis`/`finishLinkOrImage` may
/// later shrink (mutating `.node` in place, e.g. `"**"` -> `"*"` when one of
/// two delimiters gets consumed by a match) or bypass entirely (splicing an
/// `emph`/`strong`/`link`/`image` node in around it). `prev`/`next` link the
/// sequence WITHOUT requiring index-shifting array surgery on every match —
/// see this file's module doc comment.
const Item = struct {
    node: Node.Id,
    prev: ?ItemIdx = null,
    next: ?ItemIdx = null,
};

/// One `*`/`_` delimiter run currently eligible to participate in emphasis
/// matching (pushed only when `can_open or can_close` -- see `parseInline`),
/// referencing the `Item` (a placeholder `str` leaf) that holds its literal
/// text. `count` starts as the run's length and shrinks by 1 or 2 each time
/// `process_emphasis` consumes it as an opener/closer; the entry is dropped
/// from the stack once its count reaches 0 (see `removeDelimRange`).
const Delim = struct {
    item: ItemIdx,
    char: u8,
    count: usize,
    can_open: bool,
    can_close: bool,
    /// The CURRENT remaining sub-range, in `text` coordinates, of this
    /// delimiter run -- starts as the whole run `[i, run_end)` at push time
    /// and shrinks from whichever edge gets consumed each time
    /// `processEmphasis` matches this delimiter as an opener (shrinks from
    /// `range_end`, since an opener's content-adjacent edge is its RIGHT
    /// one) or closer (shrinks from `range_start`, its LEFT edge being
    /// content-adjacent) -- see `processEmphasis`'s span-computation
    /// comment. Used to give the resulting `emph`/`strong` node (and any
    /// leftover placeholder run `spliceEmphasis` creates) an accurate span.
    range_start: usize,
    range_end: usize,
};

/// One `[`/`![` opener currently eligible to close into a link/image,
/// referencing the `Item` (a placeholder `str` leaf holding `"["` or
/// `"!["`) that will be entirely discarded if this bracket successfully
/// resolves. `active` is CommonMark's "links may not contain other links"
/// flag: a just-closed LINK (not image) deactivates every non-image bracket
/// still on the stack below it (see `finishLinkOrImage`), so an outer `[`
/// can never also close around this same span.
const Bracket = struct {
    item: ItemIdx,
    is_image: bool,
    active: bool,
    /// Byte offset of the opening `[` (or, for an image, the `!` right
    /// before it) -- the start of this bracket's own span once it resolves
    /// into a `link`/`image` node (see `finishLinkOrImage`).
    open_start: usize,
    /// Byte offset into the scanned text right after the opening `[`/`![`
    /// token -- the start of this bracket's own raw content, used both for
    /// the shortcut-reference fallback (the bracket's own text as the
    /// label) and to slice that text once the closing `]` is found, and as
    /// the resolved node's `content_span` start.
    content_start: usize,
    /// `Scanner.delims.items.len` at the moment this bracket was pushed --
    /// the `stack_bottom` boundary `finishLinkOrImage` passes to
    /// `process_emphasis` when this bracket resolves, so emphasis matching
    /// for THIS bracket's contents never reaches back past delimiters that
    /// existed before it opened.
    delim_stack_len: usize,
    /// `Scanner.tilde_delims.items.len` at the moment this bracket was
    /// pushed -- the strikethrough analog of `delim_stack_len`, same
    /// rationale (see `processStrikethrough`).
    tilde_stack_len: usize = 0,
};

/// One `~`/`~~` strikethrough delimiter run (`self.options.strikethrough`) --
/// the GFM analog of `Delim`, but on its OWN stack/matching pass
/// (`processStrikethrough`) rather than sharing CommonMark emphasis's rule-
/// of-3 matching -- see the `'~'` case in `parseInline`'s doc comment for why.
const StrikeDelim = struct {
    item: ItemIdx,
    count: usize,
    can_open: bool,
    can_close: bool,
    /// The whole run's `text` bounds -- see `Delim.range_start`/`.range_end`'s
    /// doc comment; unlike CommonMark emphasis, GFM strikethrough never
    /// partially consumes a run (`processStrikethrough`), so, unlike
    /// `Delim`'s, this never shrinks.
    range_start: usize,
    range_end: usize,
};

pub const Scanner = struct {
    b: *Builder,
    link_refs: *const std.StringHashMapUnmanaged(Node.Id),
    options: Options = .{},
    /// Maps `text` offsets back to absolute source offsets -- see
    /// `Segment`'s doc comment. Empty (the default) means "no mapping is
    /// available at all", which every span-setting call below already
    /// handles correctly (`mapSpan` just always returns `null`), so tests
    /// that construct a `Scanner`/call `parseInline` without real source
    /// segments get the same unset-span behavior as before this feature
    /// existed.
    segments: []const Segment = &.{},
    buf: std.ArrayList(u8) = .empty,
    /// The `text` offset where `buf`'s current run started accumulating
    /// (reset every time `buf` goes from empty to non-empty -- see
    /// `parseInline`'s main loop). Combined with whatever offset a flush
    /// call is told the run ends at, this gives a flushed `str` node's
    /// exact source extent regardless of any entity/backslash-escape
    /// decoding that happened along the way (decoding can shrink `buf`
    /// relative to the `text` bytes it came from, but never changes where
    /// the run STARTS or ENDS in `text`).
    buf_start: usize = 0,
    /// Whether `buf`'s current run is a byte-for-byte copy of
    /// `text[buf_start..buf_start+buf.items.len]` (no entity/backslash-
    /// escape decoding happened within it yet). Needed only by
    /// `tryExtEmailAutolink`, which reaches BACKWARD into `buf` by INDEX to
    /// claim a trailing run as an email's local part -- turning that index
    /// into a `text` offset (`buf_start + index`) is only valid while this
    /// holds; see that function's doc comment.
    buf_pure: bool = true,
    items: std.ArrayList(Item) = .empty,
    head: ?ItemIdx = null,
    tail: ?ItemIdx = null,
    delims: std.ArrayList(Delim) = .empty,
    tilde_delims: std.ArrayList(StrikeDelim) = .empty,
    brackets: std.ArrayList(Bracket) = .empty,

    pub fn deinit(self: *Scanner) void {
        self.buf.deinit(self.b.allocator);
        self.items.deinit(self.b.allocator);
        self.delims.deinit(self.b.allocator);
        self.tilde_delims.deinit(self.b.allocator);
        self.brackets.deinit(self.b.allocator);
    }

    /// Clear all per-block working state (retaining the buffers' capacity) and
    /// point at the next block's `segments`, so this scanner can parse another
    /// inline block without reallocating. Must reset EVERY mutable field --
    /// `b`/`link_refs`/`options` are the only document-constant ones.
    fn reset(self: *Scanner, segments: []const Segment) void {
        self.buf.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.delims.clearRetainingCapacity();
        self.tilde_delims.clearRetainingCapacity();
        self.brackets.clearRetainingCapacity();
        self.buf_start = 0;
        self.buf_pure = true;
        self.head = null;
        self.tail = null;
        self.segments = segments;
    }

    /// `text[local_start..local_end)`'s absolute source span, or `null` if
    /// that range isn't fully covered by one mapped `Segment` -- see
    /// `Segment`'s doc comment on why a request straddling two segments
    /// (typically: a construct that crosses a multi-line block's synthetic
    /// line-join) is refused rather than approximated.
    fn mapSpan(self: *const Scanner, local_start: usize, local_end: usize) ?Span {
        if (local_end < local_start) return null;
        for (self.segments) |seg| {
            if (local_start >= seg.buf_offset and local_end <= seg.buf_offset + seg.len) {
                const delta = local_start - seg.buf_offset;
                return Span.init(seg.src_offset + delta, seg.src_offset + delta + (local_end - local_start));
            }
        }
        return null;
    }

    fn setSpanIfMapped(self: *Scanner, id: Node.Id, local_start: usize, local_end: usize) void {
        if (self.mapSpan(local_start, local_end)) |sp| self.b.setSpan(id, sp);
    }

    fn setContentSpanIfMapped(self: *Scanner, id: Node.Id, local_start: usize, local_end: usize) void {
        if (self.mapSpan(local_start, local_end)) |sp| self.b.setContentSpan(id, sp);
    }

    /// Flush accumulated plain-text `buf` into a single `str` item, if any
    /// is pending, spanning `[self.buf_start, end)` in `text` -- `end` is
    /// always the caller's current scan position except in the one case
    /// (`'\n'`, for trailing hard-break spaces already trimmed off `buf`)
    /// where the run's true end precedes it. Called before every non-
    /// literal item is pushed, so plain runs stay coalesced into one node
    /// exactly like Phase 1 did.
    fn flushBuf(self: *Scanner, end: usize) Allocator.Error!void {
        if (self.buf.items.len == 0) return;
        const id = try self.b.addLeaf(.{ .str = self.buf.items });
        self.setSpanIfMapped(id, self.buf_start, end);
        _ = try self.appendItem(id);
        self.buf.clearRetainingCapacity();
    }

    /// Like `flushBuf`, but never sets a span -- for the one case
    /// (`tryExtEmailAutolink`'s backward buf split when `!buf_pure`) where
    /// there's no source offset we can safely attribute to the flushed
    /// remainder; see that function's doc comment.
    fn flushBufNoSpan(self: *Scanner) Allocator.Error!void {
        if (self.buf.items.len == 0) return;
        const id = try self.b.addLeaf(.{ .str = self.buf.items });
        _ = try self.appendItem(id);
        self.buf.clearRetainingCapacity();
    }

    /// Append `node` as a new item at the current tail of the sequence.
    fn appendItem(self: *Scanner, node: Node.Id) Allocator.Error!ItemIdx {
        return self.insertItemBetween(self.tail, null, node);
    }

    /// Splice a new item wrapping `node` in between `left` and `right`
    /// (either may be `null` for "sequence start"/"sequence end"), updating
    /// `head`/`tail` as needed. Used both for plain appends (`appendItem`,
    /// `right = null`) and for splicing an `emph`/`strong`/`link`/`image`
    /// node into the middle of the sequence in place of whatever it just
    /// consumed.
    fn insertItemBetween(self: *Scanner, left: ?ItemIdx, right: ?ItemIdx, node: Node.Id) Allocator.Error!ItemIdx {
        const idx: ItemIdx = @intCast(self.items.items.len);
        try self.items.append(self.b.allocator, .{ .node = node, .prev = left, .next = right });
        if (left) |l| self.items.items[l].next = idx else self.head = idx;
        if (right) |r| self.items.items[r].prev = idx else self.tail = idx;
        return idx;
    }

    /// Remove `delims[start..end)` from the delimiter stack (bookkeeping
    /// only -- the underlying `Item`s/text are untouched; delimiters that
    /// never matched simply remain literal text). `Delim` has no pointers
    /// into itself, so a plain compaction is correct and simple.
    fn removeDelimRange(self: *Scanner, start: usize, end: usize) void {
        if (end <= start) return;
        const tail = self.delims.items[end..];
        std.mem.copyForwards(Delim, self.delims.items[start..][0..tail.len], tail);
        self.delims.items.len -= (end - start);
    }

    /// CommonMark's `process_emphasis`: bottom-up matching of `*`/`_`
    /// delimiter runs at stack positions `[stack_bottom..)` into `emph`/
    /// `strong` nodes. Scans closers left to right; for each, scans
    /// backward (no further than `stack_bottom`) for the nearest matching
    /// opener, applying the "rule of 3" (a delimiter that can both open and
    /// close can't pair with one whose combined run length is a multiple of
    /// 3 unless both individual lengths are). A match consumes 1 delimiter
    /// from each side (or 2, forming `strong`, when both runs have >= 2
    /// left) and may leave a shorter run in place on either side to be
    /// matched again. Delimiters within `[stack_bottom..)` that end up
    /// unmatched are simply left as literal text (their placeholder items
    /// are never touched) -- only the STACK bookkeeping above `stack_bottom`
    /// is discarded once this returns (see this file's module doc comment's
    /// note on the `openers_bottom` optimization this deliberately skips).
    fn processEmphasis(self: *Scanner, stack_bottom: usize) Allocator.Error!void {
        var closer_idx = stack_bottom;
        while (closer_idx < self.delims.items.len) {
            const closer = self.delims.items[closer_idx];
            if (!closer.can_close) {
                closer_idx += 1;
                continue;
            }

            var opener_idx: ?usize = null;
            if (closer_idx > stack_bottom) {
                var k = closer_idx;
                while (k > stack_bottom) {
                    k -= 1;
                    const cand = self.delims.items[k];
                    if (cand.can_open and cand.char == closer.char) {
                        if ((cand.can_open and cand.can_close) or (closer.can_open and closer.can_close)) {
                            const sum = cand.count + closer.count;
                            if (sum % 3 == 0 and !(cand.count % 3 == 0 and closer.count % 3 == 0)) {
                                // Rule of 3 violation for this pairing --
                                // keep scanning further back for another
                                // (earlier) opener instead.
                                continue;
                            }
                        }
                        opener_idx = k;
                        break;
                    }
                }
            }

            if (opener_idx) |oi| {
                const use_delims: usize = if (self.delims.items[oi].count >= 2 and closer.count >= 2) 2 else 1;
                const ch = closer.char;
                const opener_item = self.delims.items[oi].item;
                const closer_item = self.delims.items[closer_idx].item;

                var kids = std.ArrayList(Node.Id).empty;
                defer kids.deinit(self.b.allocator);
                var cur = self.items.items[opener_item].next;
                while (cur) |ci| {
                    if (ci == closer_item) break;
                    try kids.append(self.b.allocator, self.items.items[ci].node);
                    cur = self.items.items[ci].next;
                }
                const new_node = try self.b.addContainer(if (use_delims == 2) .strong else .emph, kids.items);

                // The exact source bytes THIS match consumes: the opener's
                // innermost (content-adjacent, i.e. rightmost) `use_delims`
                // characters through the closer's innermost (leftmost)
                // `use_delims` characters -- see `Delim.range_start`/
                // `.range_end`'s doc comment. `content_*` is the interior
                // (between the matched delimiters); `match_*` extends that
                // by `use_delims` on each side to cover the delimiters
                // themselves too.
                const content_start = self.delims.items[oi].range_end;
                const content_end = self.delims.items[closer_idx].range_start;

                self.delims.items[oi].count -= use_delims;
                self.delims.items[closer_idx].count -= use_delims;
                self.delims.items[oi].range_end -= use_delims;
                self.delims.items[closer_idx].range_start += use_delims;
                const opener_count = self.delims.items[oi].count;
                const closer_count = self.delims.items[closer_idx].count;

                self.setSpanIfMapped(new_node, self.delims.items[oi].range_end, self.delims.items[closer_idx].range_start);
                self.setContentSpanIfMapped(new_node, content_start, content_end);

                try self.spliceEmphasis(
                    opener_item,
                    opener_count,
                    self.delims.items[oi].range_start,
                    self.delims.items[oi].range_end,
                    closer_item,
                    closer_count,
                    self.delims.items[closer_idx].range_start,
                    self.delims.items[closer_idx].range_end,
                    ch,
                    new_node,
                );

                const del_start = if (opener_count > 0) oi + 1 else oi;
                const del_end = if (closer_count > 0) closer_idx else closer_idx + 1;
                self.removeDelimRange(del_start, del_end);
                // `removeDelimRange(del_start, del_end)` shifts whatever was at
                // `del_end` down to `del_start`. When the closer still has
                // delimiters left (`closer_count > 0`) it lived at `del_end`,
                // so it now sits at `del_start` and must be re-examined there
                // for a further (earlier) opener -- e.g. `*foo *bar**`, where
                // the outer `*` still needs the leftover `*` after the inner
                // match. The old `oi + 1` was only correct when the opener
                // survived (`opener_count > 0`); with an exhausted opener it
                // skipped past the shifted-down closer, stranding it as literal
                // text. `del_start` is right in every case.
                closer_idx = del_start;
            } else if (!closer.can_open) {
                // No opener found, and this closer can never itself open --
                // it will never match anything; drop it from the stack (it
                // stays as literal text) and re-examine whatever shifted
                // into this position.
                self.removeDelimRange(closer_idx, closer_idx + 1);
            } else {
                closer_idx += 1;
            }
        }
        // Whatever's left above `stack_bottom` had its chance; discard the
        // bookkeeping (the literal text underneath is untouched).
        self.delims.items.len = stack_bottom;
    }

    /// GFM strikethrough's matching pass: bottom-up, over `tilde_delims`,
    /// pairing each closer with the NEAREST still-open opener of the SAME
    /// run length (1 matches 1, 2 matches 2 -- unlike `processEmphasis`,
    /// there's no partial consumption and no rule-of-3, since GFM
    /// strikethrough only ever recognizes whole "1 or 2 tildes" runs). A
    /// matched pair is entirely consumed (both placeholder items dropped
    /// from the sequence, replaced by one spliced-in `delete` node);
    /// unmatched delimiters are simply left as literal text, exactly like
    /// `processEmphasis`.
    fn processStrikethrough(self: *Scanner, stack_bottom: usize) Allocator.Error!void {
        var closer_idx = stack_bottom;
        while (closer_idx < self.tilde_delims.items.len) {
            const closer = self.tilde_delims.items[closer_idx];
            if (!closer.can_close) {
                closer_idx += 1;
                continue;
            }
            var opener_idx: ?usize = null;
            if (closer_idx > stack_bottom) {
                var k = closer_idx;
                while (k > stack_bottom) {
                    k -= 1;
                    const cand = self.tilde_delims.items[k];
                    if (cand.can_open and cand.count == closer.count) {
                        opener_idx = k;
                        break;
                    }
                }
            }
            if (opener_idx) |oi| {
                const opener_item = self.tilde_delims.items[oi].item;
                const closer_item = self.tilde_delims.items[closer_idx].item;
                var kids = std.ArrayList(Node.Id).empty;
                defer kids.deinit(self.b.allocator);
                var cur = self.items.items[opener_item].next;
                while (cur) |ci| {
                    if (ci == closer_item) break;
                    try kids.append(self.b.allocator, self.items.items[ci].node);
                    cur = self.items.items[ci].next;
                }
                const new_node = try self.b.addContainer(.delete, kids.items);
                // Unlike emphasis, strikethrough always consumes a matched
                // pair's runs WHOLE (see this function's doc comment), so
                // the span is simply the two runs' own (never-shrunk)
                // bounds, with the interior between them as `content_span`.
                self.setSpanIfMapped(new_node, self.tilde_delims.items[oi].range_start, self.tilde_delims.items[closer_idx].range_end);
                self.setContentSpanIfMapped(new_node, self.tilde_delims.items[oi].range_end, self.tilde_delims.items[closer_idx].range_start);
                const left = self.items.items[opener_item].prev;
                const right = self.items.items[closer_item].next;
                _ = try self.insertItemBetween(left, right, new_node);
                self.removeTildeDelimRange(oi, closer_idx + 1);
                closer_idx = oi;
            } else if (!closer.can_open) {
                self.removeTildeDelimRange(closer_idx, closer_idx + 1);
            } else {
                closer_idx += 1;
            }
        }
        self.tilde_delims.items.len = stack_bottom;
    }

    fn removeTildeDelimRange(self: *Scanner, start: usize, end: usize) void {
        if (end <= start) return;
        const tail = self.tilde_delims.items[end..];
        std.mem.copyForwards(StrikeDelim, self.tilde_delims.items[start..][0..tail.len], tail);
        self.tilde_delims.items.len -= (end - start);
    }

    /// Insert the `emph`/`strong` node `new_node` (already built from
    /// `use_delims` delimiters' worth of content) in place of the matched
    /// portion of the opener/closer runs. If either run has leftover
    /// (unconsumed) delimiters, its placeholder item's text is shrunk in
    /// place to just the leftover characters (spanning
    /// `[*_range_start, *_range_end)` -- the delimiter's own current
    /// remaining sub-range, already updated by the caller) and kept
    /// adjacent to `new_node`; if fully consumed, the item is dropped from
    /// the sequence entirely.
    fn spliceEmphasis(
        self: *Scanner,
        opener_item: ItemIdx,
        opener_count: usize,
        opener_range_start: usize,
        opener_range_end: usize,
        closer_item: ItemIdx,
        closer_count: usize,
        closer_range_start: usize,
        closer_range_end: usize,
        ch: u8,
        new_node: Node.Id,
    ) Allocator.Error!void {
        var left: ?ItemIdx = undefined;
        if (opener_count > 0) {
            const run_id = try makeRunStr(self.b, ch, opener_count);
            self.setSpanIfMapped(run_id, opener_range_start, opener_range_end);
            self.items.items[opener_item].node = run_id;
            left = opener_item;
        } else {
            left = self.items.items[opener_item].prev;
        }
        var right: ?ItemIdx = undefined;
        if (closer_count > 0) {
            const run_id = try makeRunStr(self.b, ch, closer_count);
            self.setSpanIfMapped(run_id, closer_range_start, closer_range_end);
            self.items.items[closer_item].node = run_id;
            right = closer_item;
        } else {
            right = self.items.items[closer_item].next;
        }
        _ = try self.insertItemBetween(left, right, new_node);
    }

    /// Resolve a just-matched link/image: `br` is the bracket being closed
    /// (already known active), `dest`/`title` its (already decoded)
    /// destination/title, `close_i` the position of the closing `]`, and
    /// `end` one past the whole construct's last byte (the closing `)` for
    /// an inline link/image, or the closing `]` of a reference form -- see
    /// `handleCloseBracket`'s call sites. Runs emphasis matching over the
    /// bracket's own contents first (so nested `*`/`_` bind INSIDE the link
    /// text, not across its boundary), gathers that content as the new
    /// node's children, splices the node in over the whole `[`/`![...]`
    /// span, and applies the "links cannot contain links" deactivation.
    fn finishLinkOrImage(self: *Scanner, br: Bracket, dest: []const u8, title: ?[]const u8, close_i: usize, end: usize) Allocator.Error!void {
        try self.processEmphasis(br.delim_stack_len);
        try self.processStrikethrough(br.tilde_stack_len);

        var kids = std.ArrayList(Node.Id).empty;
        defer kids.deinit(self.b.allocator);
        var cur = self.items.items[br.item].next;
        while (cur) |ci| {
            try kids.append(self.b.allocator, self.items.items[ci].node);
            cur = self.items.items[ci].next;
        }

        const kind: Node.Kind = if (br.is_image)
            .{ .image = .{ .destination = dest, .reference = null } }
        else
            .{ .link = .{ .destination = dest, .reference = null } };
        const node_id = try self.b.addContainer(kind, kids.items);
        // Full source extent (`[`/`![` through the closing `)`/`]`
        // inclusive); `content_span` is just the bracketed text between
        // `[`/`![` and `]` -- see this file's/`block.zig`'s module doc
        // comments on the "delimiters included" span convention.
        self.setSpanIfMapped(node_id, br.open_start, end);
        self.setContentSpanIfMapped(node_id, br.content_start, close_i);
        if (title) |t| {
            try self.b.setAttrs(node_id, .{ .entries = &.{.{ .key = "title", .value = t }} });
        }

        const left = self.items.items[br.item].prev;
        _ = try self.insertItemBetween(left, null, node_id);

        _ = self.brackets.pop();
        if (!br.is_image) {
            // Links may not contain other links: any outer, still-open
            // plain `[` opener can never close into a link now (an outer
            // `![` image opener is unaffected -- images may contain links).
            for (self.brackets.items) |*outer| {
                if (!outer.is_image) outer.active = false;
            }
        }
    }
};

fn makeRunStr(b: *Builder, ch: u8, count: usize) Allocator.Error!Node.Id {
    const buf = try b.allocator.alloc(u8, count);
    defer b.allocator.free(buf);
    @memset(buf, ch);
    return b.addLeaf(.{ .str = buf });
}

// ── links / images ───────────────────────────────────────────────────────

/// The `Attrs` attached to `id` within an in-progress `Builder` -- the
/// `Builder`-side equivalent of `AST.attrsOf` (which only exists on a
/// finished `AST`). `block.zig`'s own `tryParseLinkRefDef` reaches into
/// `Builder.nodes`/`.attrs` directly the same way; struct fields in Zig have
/// no cross-file privacy, so this is the established pattern here.
fn builderAttrsOf(b: *Builder, id: Node.Id) AST.Attrs {
    const idx = b.nodes.items[id].attrs orelse return .{};
    return b.attrs.items[idx];
}

/// Unicode simple case fold for the common bicameral scripts -- duplicated
/// from `block.zig`'s `foldCodepointInto`, and must stay byte-for-byte in sync
/// with it (both feed the SAME `Document.link_references` keys).
fn foldRefCodepointInto(allocator: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    if (cp == 0x00DF or cp == 0x1E9E) { // ß, ẞ → "ss"
        try out.appendSlice(allocator, "ss");
        return;
    }
    const folded: u21 = switch (cp) {
        'A'...'Z' => cp + 32,
        0x00C0...0x00D6, 0x00D8...0x00DE => cp + 32, // Latin-1 À–Þ (skip × at 0xD7)
        0x0391...0x03A1, 0x03A3...0x03AB => cp + 32, // Greek capitals (skip 0x03A2 hole)
        0x0410...0x042F => cp + 32, // Cyrillic А–Я
        else => cp,
    };
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(folded, &buf) catch return;
    try out.appendSlice(allocator, buf[0..n]);
}

/// Trim + collapse internal whitespace runs to a single space + Unicode case
/// fold -- duplicated from `block.zig`'s (private) `normalizeLabel` rather
/// than shared across files, so this file's link-label resolution stays
/// self-contained. Must stay byte-for-byte in sync with that function, since
/// both normalize against the SAME `Document.link_references` keys.
fn normalizeRefLabel(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var in_ws = false;
    var i: usize = 0;
    while (i < trimmed.len) {
        const c = trimmed[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!in_ws) try out.append(allocator, ' ');
            in_ws = true;
            i += 1;
        } else if (c < 0x80) {
            try out.append(allocator, std.ascii.toLower(c));
            in_ws = false;
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const end = @min(i + len, trimmed.len);
            const cp = std.unicode.utf8Decode(trimmed[i..end]) catch {
                try out.append(allocator, c);
                in_ws = false;
                i += 1;
                continue;
            };
            try foldRefCodepointInto(allocator, &out, cp);
            in_ws = false;
            i = end;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Handle a `]` at `text[close_i]`: try to close it into a link/image
/// against the topmost bracket on the stack (inline `(...)` form first,
/// then full/collapsed/shortcut reference forms against `link_refs`), or
/// fall back to literal text. Returns the index to resume scanning from
/// (either just past a successfully matched link/image, or `close_i + 1`
/// for a literal `]`). See this file's module doc comment for the
/// "position only advances past a FAILED attempt's own `]`, never past
/// whatever it tentatively looked ahead at" rule this implements.
fn handleCloseBracket(sc: *Scanner, text: []const u8, close_i: usize) Allocator.Error!usize {
    if (sc.brackets.items.len == 0) {
        try sc.buf.append(sc.b.allocator, ']');
        return close_i + 1;
    }
    const br = sc.brackets.items[sc.brackets.items.len - 1];
    if (!br.active) {
        _ = sc.brackets.pop();
        try sc.buf.append(sc.b.allocator, ']');
        return close_i + 1;
    }

    // Inline form: `](dest "title")`, immediately following, no whitespace
    // allowed between `]` and `(`.
    if (close_i + 1 < text.len and text[close_i + 1] == '(') {
        if (scanInlineLinkTail(text, close_i + 1)) |raw| {
            const dest = try decodeText(sc.b.allocator, raw.dest_raw);
            defer sc.b.allocator.free(dest);
            const title = if (raw.title_raw) |t| try decodeText(sc.b.allocator, t) else null;
            defer if (title) |t| sc.b.allocator.free(t);
            try sc.finishLinkOrImage(br, dest, title, close_i, raw.end);
            return raw.end;
        }
    }

    // Reference forms: full `][label]`, collapsed `][]`, or shortcut (no
    // second bracket at all -- the opener's own text is the label).
    var label_raw: []const u8 = text[br.content_start..close_i];
    var ref_end = close_i + 1;
    if (close_i + 1 < text.len and text[close_i + 1] == '[') {
        if (scanBracketLabel(text, close_i + 1)) |lbl| {
            ref_end = lbl.end;
            if (lbl.content.len > 0) label_raw = lbl.content; // else: collapsed, keep opener text
        }
        // An invalid second bracket (e.g. unescaped nested `[`) falls back
        // to the shortcut form using the opener's own text, WITHOUT
        // consuming the malformed second bracket -- see module doc comment.
    }
    const norm = try normalizeRefLabel(sc.b.allocator, label_raw);
    defer sc.b.allocator.free(norm);
    if (norm.len > 0) {
        if (sc.link_refs.get(norm)) |ref_id| {
            const dest = sc.b.nodes.items[ref_id].kind.reference.destination;
            const title = builderAttrsOf(sc.b, ref_id).get("title");
            try sc.finishLinkOrImage(br, dest, title, close_i, ref_end);
            return ref_end;
        }
    }

    // No match: this bracket is spent (pop it), and only the `]` itself is
    // consumed as literal text -- whatever came after it (including any
    // `[...]` we just tentatively scanned as a label) is left for the main
    // loop to rescan from scratch.
    _ = sc.brackets.pop();
    try sc.buf.append(sc.b.allocator, ']');
    return close_i + 1;
}

const RawLinkTail = struct { dest_raw: []const u8, title_raw: ?[]const u8, end: usize };

/// `text[start] == '('`. Scans (without allocating) an inline link/image
/// tail: optional whitespace, an optional destination (`<...>` or a
/// balanced-paren/backslash-aware bareword; empty is valid, e.g. `[x]()`),
/// optional whitespace + an optional quoted title, optional whitespace, and
/// a closing `)`. Returns raw (still backslash/entity-encoded) slices into
/// `text` on success -- the caller decodes only once it knows the whole
/// thing matched, so a failed attempt never allocates.
fn scanInlineLinkTail(text: []const u8, start: usize) ?RawLinkTail {
    var i = start + 1;
    i = skipWs(text, i);
    var dest_raw: []const u8 = "";
    if (i < text.len and text[i] == ')') {
        return .{ .dest_raw = "", .title_raw = null, .end = i + 1 };
    }
    if (i < text.len and text[i] == '<') {
        const dstart = i + 1;
        var j = dstart;
        while (j < text.len and text[j] != '>' and text[j] != '\n') : (j += 1) {
            if (text[j] == '\\' and j + 1 < text.len) j += 1;
        }
        if (j >= text.len or text[j] != '>') return null;
        dest_raw = text[dstart..j];
        i = j + 1;
    } else {
        const dstart = i;
        var depth: usize = 0;
        var j = i;
        while (j < text.len) : (j += 1) {
            const ch = text[j];
            if (ch == '\\' and j + 1 < text.len and isAsciiPunct(text[j + 1])) {
                j += 1;
                continue;
            }
            if (ch == ' ' or ch == '\t' or ch == '\n' or std.ascii.isControl(ch)) break;
            if (ch == '(') depth += 1;
            if (ch == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        if (j == dstart or depth != 0) return null;
        dest_raw = text[dstart..j];
        i = j;
    }

    const after_dest = i;
    const ws_end = skipWs(text, after_dest);
    var title_raw: ?[]const u8 = null;
    if (ws_end > after_dest and ws_end < text.len and (text[ws_end] == '"' or text[ws_end] == '\'' or text[ws_end] == '(')) {
        const open = text[ws_end];
        const close: u8 = if (open == '(') ')' else open;
        var j = ws_end + 1;
        while (j < text.len and text[j] != close) : (j += 1) {
            if (text[j] == '\\' and j + 1 < text.len) j += 1;
        }
        if (j >= text.len) return null;
        title_raw = text[ws_end + 1 .. j];
        i = j + 1;
    } else {
        i = after_dest;
    }
    i = skipWs(text, i);
    if (i >= text.len or text[i] != ')') return null;
    return .{ .dest_raw = dest_raw, .title_raw = title_raw, .end = i + 1 };
}

pub const RawLabel = struct { content: []const u8, end: usize };

/// `text[start] == '['`. Scans a link LABEL (as opposed to link TEXT --
/// no nested brackets allowed at all, even balanced ones, per spec) up to
/// its closing `]`. Returns `null` if unterminated or if an unescaped `[`
/// appears before the close (an invalid label, per spec's "cannot contain
/// unescaped brackets" rule) or the label exceeds the spec's 999-character
/// cap.
pub fn scanBracketLabel(text: []const u8, start: usize) ?RawLabel {
    var i = start + 1;
    const content_start = i;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (c == '[') return null;
        if (c == ']') break;
    }
    if (i >= text.len or text[i] != ']') return null;
    if (i - content_start > 999) return null;
    return .{ .content = text[content_start..i], .end = i + 1 };
}

// ── Phase 3: text directives (`self.options.directives`) ───────────────

/// The parsed pieces of a text directive `:name[label]{attrs}`. `name`/`label`
/// slice into the scan's `text`; `attrs` (if any) is freshly allocated and
/// owned by the `TextDirective` — `buildTextDirective` consumes and frees it.
/// The inner text of a directive's `[label]` and its absolute byte range
/// within the scan's `text` (used for the directive node's `content_span`).
const DirectiveLabel = struct { text: []const u8, start: usize, end: usize };

const TextDirective = struct {
    name: []const u8,
    /// `null` when the directive has no `[label]` bracket.
    label: ?DirectiveLabel,
    attrs: ?attrs_mod.Parsed,
    end: usize,
};

/// `text[at] == ':'`. Recognize a text directive: a single colon, a directive
/// name (must start with a letter — so `10:30`/`ratio 3:4` never match), then
/// an optional `[label]` and optional `{attrs}` (at least one of which, or the
/// bare name, is enough — matching remark, where a bare `:name` is valid).
/// Returns `null` for anything that isn't a well-formed directive; a
/// malformed `{...}` simply ends the directive before it rather than failing
/// the whole match (the `{` becomes literal text after the directive).
fn scanTextDirective(allocator: Allocator, text: []const u8, at: usize) Allocator.Error!?TextDirective {
    const name_end = attrs_mod.scanName(text, at + 1) orelse return null;
    const name = text[at + 1 .. name_end];

    var i = name_end;
    var label: ?DirectiveLabel = null;
    if (i < text.len and text[i] == '[') {
        if (scanBracketLabel(text, i)) |raw| {
            label = .{ .text = raw.content, .start = i + 1, .end = raw.end - 1 };
            i = raw.end;
        }
    }

    var attrs: ?attrs_mod.Parsed = null;
    if (i < text.len and text[i] == '{') {
        if (try attrs_mod.parse(allocator, text, i)) |p| {
            attrs = p;
            i = p.end;
        }
    }

    return .{ .name = name, .label = label, .attrs = attrs, .end = i };
}

/// Build the `directive` node for a scanned text directive: parse its label as
/// inline children, attach the shorthand attributes, and free the transient
/// `TextDirective.attrs`.
fn buildTextDirective(sc: *Scanner, d: TextDirective) Allocator.Error!Node.Id {
    const b = sc.b;
    const children: []Node.Id = if (d.label) |lab|
        try parseInline(b, lab.text, &.{}, sc.link_refs, sc.options)
    else
        &.{};
    defer if (children.len > 0) b.allocator.free(children);

    const id = try b.addContainer(.{ .directive = .{ .form = .text, .name = d.name } }, children);
    if (d.attrs) |p| {
        defer p.deinit(b.allocator);
        try b.setAttrs(id, .{ .entries = p.entries });
    }
    return id;
}

// ── Phase 3: footnote references (`self.options.footnotes`) ────────────

const FootnoteRefLabel = struct { label: []const u8, end: usize };

/// `text[at] == '['`. `[^label]`: shares `scanBracketLabel`'s label grammar
/// (no unescaped nested `[`, 999-character cap) minus the leading `^`, so
/// `[^a[b]` fails to scan here for the same reason `[a[b]` fails as an
/// ordinary link label -- falling back to literal-bracket handling, exactly
/// like an ordinary unresolved link label does. The label must contain at
/// least one non-whitespace character (mirrors link reference definitions'
/// "at least one character other than blank space" rule).
fn tryFootnoteReference(text: []const u8, at: usize) ?FootnoteRefLabel {
    if (at + 1 >= text.len or text[at + 1] != '^') return null;
    const raw = scanBracketLabel(text, at) orelse return null;
    const label = raw.content[1..]; // drop the leading '^' claimed above
    if (std.mem.trim(u8, label, " \t\r\n").len == 0) return null;
    return .{ .label = label, .end = raw.end };
}

/// Whitespace per the inline link-tail/HTML-tag grammars: any run of
/// spaces, tabs, and line endings (line endings are always bare `\n` here --
/// see this file's module doc comment on `text` never containing `\r`).
fn skipWs(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) i += 1;
    return i;
}

// ── autolinks ────────────────────────────────────────────────────────────

/// `text[at] == '<'`. An absolute-URI autolink: `<scheme:rest>` where
/// `scheme` is 2-32 characters (a letter, then letters/digits/`+`/`-`/`.`)
/// and `rest` contains no ASCII control characters, space, `<`, or `>`.
pub fn scanAutolinkUri(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    if (i >= text.len or !std.ascii.isAlphabetic(text[i])) return null;
    const scheme_start = i;
    i += 1;
    while (i < text.len and (i - scheme_start) < 32 and
        (std.ascii.isAlphanumeric(text[i]) or text[i] == '+' or text[i] == '-' or text[i] == '.')) : (i += 1)
    {}
    if (i - scheme_start < 2) return null;
    if (i >= text.len or text[i] != ':') return null;
    i += 1;
    while (i < text.len and text[i] != '>' and text[i] != '<' and text[i] != ' ' and !std.ascii.isControl(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

fn isEmailLocalChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

/// One dot-separated domain label of an email autolink:
/// `[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?` -- must start AND end
/// with an alphanumeric, with up to 63 characters total. Advances `i.*` past
/// the label (trimming any trailing hyphens off the accepted length, since
/// the label must end in an alphanumeric) and returns whether a label was
/// present at all.
fn scanEmailDomainLabel(text: []const u8, i: *usize) bool {
    const start = i.*;
    if (start >= text.len or !std.ascii.isAlphanumeric(text[start])) return false;
    var j = start + 1;
    var end = j;
    while (j < text.len and (j - start) < 63 and (std.ascii.isAlphanumeric(text[j]) or text[j] == '-')) : (j += 1) {
        if (std.ascii.isAlphanumeric(text[j])) end = j + 1;
    }
    i.* = end;
    return true;
}

/// `text[at] == '<'`. An email autolink per CommonMark's (deliberately
/// restrictive, not RFC 5322) grammar: a nonempty local part, `@`, and one
/// or more dot-separated domain labels.
pub fn scanAutolinkEmail(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    const local_start = i;
    while (i < text.len and isEmailLocalChar(text[i])) i += 1;
    if (i == local_start) return null;
    if (i >= text.len or text[i] != '@') return null;
    i += 1;
    if (!scanEmailDomainLabel(text, &i)) return null;
    while (i < text.len and text[i] == '.') {
        const save = i;
        i += 1;
        if (!scanEmailDomainLabel(text, &i)) {
            i = save;
            break;
        }
    }
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

// ── Phase 3: inline/display math (`self.options.math`) ─────────────────
// A twig extension, not part of CommonMark or GFM (mission: "off by default,
// render is whatever the shared printer already does for `inline_math`/
// `display_math`"). Follows the common `$...$`/`$$...$$` convention (e.g.
// Pandoc's): a delimiter's INNER edge (the character right after an opener /
// right before a closer) may not be whitespace, which is what keeps stray
// prose dollar signs ("costs $5 and $10") from being misread as math.

const MathSpan = struct { content_end: usize, end: usize };

/// `text[at..at+2] == "$$"`. Scans forward for the next `$$`, requiring at
/// least one byte of content between them (an adjacent `$$$$` is therefore
/// never read as empty display math).
fn scanDisplayMath(text: []const u8, at: usize) ?MathSpan {
    var j = at + 2;
    while (j + 1 < text.len) : (j += 1) {
        if (text[j] == '$' and text[j + 1] == '$') {
            if (j == at + 2) return null;
            return .{ .content_end = j, .end = j + 2 };
        }
    }
    return null;
}

/// `text[at] == '$'` (and, per the caller, not the start of a `$$` run).
/// Scans forward for a closing `$` whose preceding byte isn't whitespace,
/// skipping `\`-escaped bytes (so `\$` inside the span never closes it) and
/// refusing to cross a line ending (no multi-line inline math).
fn scanInlineMath(text: []const u8, at: usize) ?MathSpan {
    if (at + 1 >= text.len) return null;
    const first = text[at + 1];
    if (first == ' ' or first == '\t' or first == '\n' or first == '$') return null;
    var j = at + 1;
    while (j < text.len) {
        const ch = text[j];
        if (ch == '\\' and j + 1 < text.len) {
            j += 2;
            continue;
        }
        if (ch == '\n') return null;
        if (ch == '$' and text[j - 1] != ' ' and text[j - 1] != '\t') {
            return .{ .content_end = j, .end = j + 1 };
        }
        j += 1;
    }
    return null;
}

// ── Phase 3: GFM extended autolinks (`self.options.autolinks`) ─────────
// Bare `http(s)://`/`ftp://`/`www.`/email URLs in ordinary text -- as opposed
// to Phase 2's CommonMark-core `<scheme:...>`/`<email>` form (the `'<'` case
// above), which stays on unconditionally regardless of this flag. Covered by
// `languages/markdown/gfm_conformance.zig` (the spec's whole Autolinks-
// extension section), including the full trailing-punctuation rules
// (`trimTrailingAutolinkPunct`: the ASCII punct set, balanced-paren trimming,
// and the `&entity;`-shaped-suffix carve-out) and the email domain grammar
// (`scanExtEmailDomain`).
//
// One documented APPROXIMATION remains against GFM's own grammar (GFM spec's
// Autolinks-extension section, and cmark-gfm's `extensions/autolink.c`):
// word-boundary detection is "the previous byte isn't alphanumeric/`_`",
// where GFM's own rule is "beginning of line, after whitespace, or after one
// of `*`, `_`, `~`, `(`" -- close, but not identical for all Unicode input.
// Neither is the spec's "[valid domain]" production enforced for the `www.`/
// url forms (segments of alphanumerics/`_`/`-` separated by `.`, at least one
// `.`, and no `_` in the last two segments); the body is simply scanned to
// the next space/`<`. The email form DOES enforce its own domain rule, since
// the spec makes the trailing-`-`/`_` check load-bearing there (see
// `scanExtEmailDomain`).

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Trim trailing punctuation off an autolink candidate per GFM's "extended
/// autolink path validation" (spec's Autolinks-extension section, mirroring
/// cmark-gfm `extensions/autolink.c`'s `autolink_delim`):
///   - `?!.,:*_~'"` are always trimmed, repeatedly (so e.g. `".` trims both).
///   - A trailing `)` is only trimmed while it's unbalanced against `(`
///     earlier in `s`, so `(see http://example.com/a(b))` keeps the inner `)`
///     but drops the outer one. When the parens are balanced this stops,
///     leaving an interior-only case like `?q=(business))+ok` untouched.
///   - A trailing `;` is special-cased: if what precedes it looks like an
///     entity reference (`&` + one or more ASCII letters, e.g. `&hl;`), the
///     WHOLE `&...;` run is excluded from the autolink rather than just the
///     `;` — so `www.google.com/search?q=commonmark&hl;` links only
///     `...?q=commonmark` and leaves `&hl;` as text. Otherwise just the `;`
///     is trimmed and trimming continues.
/// Stops at the first byte that matches none of the above.
fn trimTrailingAutolinkPunct(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const c = s[end - 1];
        if (c == ')') {
            var open: usize = 0;
            var close: usize = 0;
            for (s[0..end]) |ch| {
                if (ch == '(') open += 1;
                if (ch == ')') close += 1;
            }
            if (close > open) {
                end -= 1;
                continue;
            }
            break;
        }
        if (c == ';') {
            // Walk back over the letters preceding the `;`; if they're
            // introduced by an `&`, drop the entity-shaped run entirely.
            var k = end - 1;
            while (k > 0 and std.ascii.isAlphabetic(s[k - 1])) k -= 1;
            if (k < end - 1 and k > 0 and s[k - 1] == '&') {
                end = k - 1;
            } else {
                end -= 1;
            }
            continue;
        }
        switch (c) {
            '?', '!', '.', ',', ':', '*', '_', '~', '\'', '"' => {
                end -= 1;
                continue;
            },
            else => break,
        }
    }
    return s[0..end];
}

/// The body of an extended autolink: every byte from `start` up to (but not
/// including) the next whitespace byte or `<` (GFM stops an autolink at
/// `<`, treating it as the start of raw HTML/an autolink instead).
fn scanExtAutolinkBody(text: []const u8, start: usize) usize {
    var j = start;
    while (j < text.len and text[j] != ' ' and text[j] != '\t' and text[j] != '\n' and text[j] != '<') j += 1;
    return j;
}

/// `text[at] == 'h'` or `'f'`. One of GFM's three extended-url-autolink
/// schemes — `http://`, `https://`, `ftp://` — not preceded by a word
/// character. Maps to a plain `url` node (destination == displayed text,
/// matching how Phase 2 already renders `<scheme:...>` autolinks), since the
/// text IS already a valid href with no prefixing needed.
fn tryExtUrlAutolink(sc: *Scanner, text: []const u8, i: usize) Allocator.Error!?usize {
    if (i > 0 and isWordChar(text[i - 1])) return null;
    const prefix: []const u8 = if (std.mem.startsWith(u8, text[i..], "https://"))
        "https://"
    else if (std.mem.startsWith(u8, text[i..], "http://"))
        "http://"
    else if (std.mem.startsWith(u8, text[i..], "ftp://"))
        "ftp://"
    else
        return null;
    const raw_end = scanExtAutolinkBody(text, i + prefix.len);
    if (raw_end == i + prefix.len) return null;
    const trimmed = trimTrailingAutolinkPunct(text[i..raw_end]);
    if (trimmed.len <= prefix.len) return null;
    const final_end = i + trimmed.len;
    try sc.flushBuf(i);
    const id = try sc.b.addLeaf(.{ .url = text[i..final_end] });
    sc.setSpanIfMapped(id, i, final_end);
    _ = try sc.appendItem(id);
    return final_end;
}

/// `text[at] == 'w'`. `www.` not preceded by a word character. Unlike the
/// `http(s)://` form, the DISPLAYED text (`www.example.com`) isn't itself a
/// valid href, so this maps to a `link` node instead of `url` -- destination
/// gets an `http://` prefix (per the mission: "`www.` gets `http://`
/// prefixed"), while the child `str` keeps the original, unprefixed text.
fn tryExtWwwAutolink(sc: *Scanner, text: []const u8, i: usize) Allocator.Error!?usize {
    if (i > 0 and isWordChar(text[i - 1])) return null;
    if (!std.mem.startsWith(u8, text[i..], "www.")) return null;
    const raw_end = scanExtAutolinkBody(text, i + 4);
    if (raw_end == i + 4) return null;
    const trimmed = trimTrailingAutolinkPunct(text[i..raw_end]);
    if (trimmed.len <= 4) return null;
    const final_end = i + trimmed.len;
    try sc.flushBuf(i);
    var dest = std.ArrayList(u8).empty;
    defer dest.deinit(sc.b.allocator);
    try dest.appendSlice(sc.b.allocator, "http://");
    try dest.appendSlice(sc.b.allocator, text[i..final_end]);
    const text_node = try sc.b.addLeaf(.{ .str = text[i..final_end] });
    sc.setSpanIfMapped(text_node, i, final_end);
    const link_node = try sc.b.addContainer(.{ .link = .{ .destination = dest.items, .reference = null } }, &.{text_node});
    sc.setSpanIfMapped(link_node, i, final_end);
    _ = try sc.appendItem(link_node);
    return final_end;
}

fn isExtEmailLocalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '-' or c == '_';
}

/// One segment of an extended-email-autolink domain: a nonempty run of
/// alphanumerics, `-`, or `_`. Advances `i` past it and reports whether it
/// matched anything.
fn scanExtEmailSegment(text: []const u8, i: *usize) bool {
    const start = i.*;
    while (i.* < text.len and (std.ascii.isAlphanumeric(text[i.*]) or text[i.*] == '-' or text[i.*] == '_')) i.* += 1;
    return i.* > start;
}

/// GFM's extended-email-autolink domain grammar (the spec's Autolinks-
/// extension section): one or more `scanExtEmailSegment`s separated by `.`,
/// with at least one `.`, and a last character that is NOT `-` or `_`.
/// Returns the domain's end offset, or `null` if `text[start..]` doesn't
/// begin with a valid one.
///
/// Deliberately NOT `scanEmailDomainLabel` (Phase 2's CommonMark `<email>`
/// grammar), because the two specs genuinely disagree and sharing one scanner
/// would regress the CommonMark suite: CommonMark forbids `_` in a domain and
/// tolerates a trailing `-` by backing up to the last alphanumeric, whereas
/// GFM allows `_` and treats a trailing `-`/`_` as DISQUALIFYING the whole
/// autolink rather than as something to trim back to -- per the spec's own
/// examples, `a.b-c_d@a.b-` and `a.b-c_d@a.b_` are not links at all, where
/// backing-up would have wrongly produced one for `a.b-c_d@a.b`.
///
/// A trailing `.` is left unconsumed (so `a.b-c_d@a.b.` links `a.b-c_d@a.b`
/// and leaves the sentence's period as text), which is also why the caller
/// needs no `trimTrailingAutolinkPunct` pass: every domain this accepts
/// already ends in an alphanumeric.
fn scanExtEmailDomain(text: []const u8, start: usize) ?usize {
    var j = start;
    if (!scanExtEmailSegment(text, &j)) return null;
    var has_dot = false;
    while (j < text.len and text[j] == '.') {
        const save = j;
        j += 1;
        if (!scanExtEmailSegment(text, &j)) {
            j = save;
            break;
        }
        has_dot = true;
    }
    if (!has_dot) return null;
    const last = text[j - 1];
    if (last == '-' or last == '_') return null;
    return j;
}

/// `text[at] == '@'`. Unlike the `http`/`www` forms, the LOCAL part of an
/// extended email autolink is already-scanned plain text sitting in
/// `sc.buf` by the time `@` is reached (there's no lookahead for it), so
/// this reaches BACKWARD into `buf` to claim its trailing run of valid
/// local-part characters, then scans FORWARD from `@` for a dot-separated
/// domain (`scanExtEmailDomain`, GFM's own domain grammar -- deliberately
/// not Phase 2's CommonMark `<email>` one; see that function's doc comment),
/// requiring at least two labels (i.e. at least one `.`) so a bare
/// `user@host` doesn't autolink. On success,
/// `buf`'s claimed suffix is dropped (so it isn't ALSO flushed as plain
/// text) and an `email` leaf is appended in its place.
///
/// Span note: `local_start` is an INDEX into `buf`, not a `text` offset --
/// turning it into one (`sc.buf_start + local_start`) is only valid while
/// `sc.buf_pure` holds (no entity/backslash-escape decoding happened
/// earlier in this run, which would make `buf` shorter than the `text` span
/// it came from -- see `Scanner.buf_pure`'s doc comment). When it doesn't
/// hold, this deliberately leaves BOTH the split-off leftover `str` and the
/// `email` node's spans unset rather than risk computing a wrong one.
fn tryExtEmailAutolink(sc: *Scanner, text: []const u8, at: usize) Allocator.Error!?usize {
    const buf = sc.buf.items;
    var local_start = buf.len;
    while (local_start > 0 and isExtEmailLocalChar(buf[local_start - 1])) local_start -= 1;
    while (local_start < buf.len and !std.ascii.isAlphanumeric(buf[local_start])) local_start += 1;
    if (local_start == buf.len) return null;

    const final_end = scanExtEmailDomain(text, at + 1) orelse return null;

    var email = std.ArrayList(u8).empty;
    defer email.deinit(sc.b.allocator);
    try email.appendSlice(sc.b.allocator, buf[local_start..]);
    try email.append(sc.b.allocator, '@');
    try email.appendSlice(sc.b.allocator, text[at + 1 .. final_end]);

    const local_part_src_start: ?usize = if (sc.buf_pure) sc.buf_start + local_start else null;
    sc.buf.items.len = local_start;
    if (local_part_src_start) |lps| {
        try sc.flushBuf(lps);
    } else {
        try sc.flushBufNoSpan();
    }
    const email_id = try sc.b.addLeaf(.{ .email = email.items });
    if (local_part_src_start) |lps| sc.setSpanIfMapped(email_id, lps, final_end);
    _ = try sc.appendItem(email_id);
    return final_end;
}

// ── raw inline HTML ─────────────────────────────────────────────────────

fn isAttrNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':';
}

fn isAttrNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':' or c == '-';
}

/// `text[at] == '<'`, dispatching to whichever raw-HTML production
/// applies based on the next character (`/` close tag, `?` processing
/// instruction, `!` comment/CDATA/declaration, else an open tag).
fn scanHtmlTag(text: []const u8, at: usize) ?usize {
    if (at + 1 >= text.len) return null;
    return switch (text[at + 1]) {
        '/' => scanHtmlCloseTag(text, at),
        '?' => scanHtmlPI(text, at),
        '!' => blk: {
            if (std.mem.startsWith(u8, text[at..], "<!--")) break :blk scanHtmlComment(text, at);
            if (std.mem.startsWith(u8, text[at..], "<![CDATA[")) break :blk scanHtmlCData(text, at);
            break :blk scanHtmlDeclaration(text, at);
        },
        else => scanHtmlOpenTag(text, at),
    };
}

/// `text[at] == '<'`. An HTML open tag: a tag name, zero or more
/// attributes, optional whitespace, an optional `/`, and `>`.
fn scanHtmlOpenTag(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    if (i >= text.len or !std.ascii.isAlphabetic(text[i])) return null;
    i += 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) i += 1;

    while (true) {
        const before_ws = i;
        const after_ws = skipWs(text, i);
        if (after_ws == before_ws) break;
        if (after_ws < text.len and isAttrNameStart(text[after_ws])) {
            var j = after_ws + 1;
            while (j < text.len and isAttrNameChar(text[j])) j += 1;
            const name_end = j;
            const after_name_ws = skipWs(text, name_end);
            if (after_name_ws < text.len and text[after_name_ws] == '=') {
                var k = skipWs(text, after_name_ws + 1);
                if (k >= text.len) return null;
                const qc = text[k];
                if (qc == '"' or qc == '\'') {
                    k += 1;
                    while (k < text.len and text[k] != qc) k += 1;
                    if (k >= text.len) return null;
                    i = k + 1;
                } else {
                    const vstart = k;
                    while (k < text.len and !std.ascii.isWhitespace(text[k]) and
                        text[k] != '"' and text[k] != '\'' and text[k] != '=' and
                        text[k] != '<' and text[k] != '>' and text[k] != '`') : (k += 1)
                    {}
                    if (k == vstart) return null;
                    i = k;
                }
            } else {
                i = name_end;
            }
        } else {
            i = before_ws;
            break;
        }
    }

    i = skipWs(text, i);
    if (i < text.len and text[i] == '/') i += 1;
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

/// `text[at] == '<'`. An HTML closing tag: `</`, a tag name, optional
/// whitespace, `>`.
fn scanHtmlCloseTag(text: []const u8, at: usize) ?usize {
    var i = at + 2;
    if (i >= text.len or !std.ascii.isAlphabetic(text[i])) return null;
    i += 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) i += 1;
    i = skipWs(text, i);
    if (i >= text.len or text[i] != '>') return null;
    return i + 1;
}

/// `text[at..at+4] == "<!--"`. An HTML comment per the HTML5-aligned
/// grammar: text that does not start with `>`/`->`, does not contain `--`,
/// and (implied by "does not contain --", since the closer itself starts
/// with `--`) does not end with `-`.
fn scanHtmlComment(text: []const u8, at: usize) ?usize {
    // CommonMark 0.31 (HTML5-aligned): an HTML comment is `<!-->`, `<!--->`,
    // or `<!--` followed by any characters not containing the string `-->`
    // and then `-->`. Searching for the FIRST `-->` guarantees the interior
    // excludes it, and a bare `--` inside is now allowed (the pre-0.31 rule
    // rejected `--` and the two empty forms -- spec ex625/626).
    var j = at + 4; // past "<!--"
    if (j < text.len and text[j] == '>') return j + 1; // <!-->
    if (j + 1 < text.len and text[j] == '-' and text[j + 1] == '>') return j + 2; // <!--->
    while (j + 2 < text.len) : (j += 1) {
        if (text[j] == '-' and text[j + 1] == '-' and text[j + 2] == '>') return j + 3;
    }
    return null;
}

/// `text[at..at+2] == "<?"`. A processing instruction: everything up to
/// the first `?>`.
fn scanHtmlPI(text: []const u8, at: usize) ?usize {
    const start = at + 2;
    const idx = std.mem.indexOfPos(u8, text, start, "?>") orelse return null;
    return idx + 2;
}

/// `text[at..at+2] == "<!"`. A declaration: `<!`, one or more uppercase
/// ASCII letters, at least one whitespace character, then everything up to
/// the first `>`.
fn scanHtmlDeclaration(text: []const u8, at: usize) ?usize {
    var i = at + 2;
    const name_start = i;
    while (i < text.len and std.ascii.isUpper(text[i])) i += 1;
    if (i == name_start) return null;
    if (i >= text.len or !std.ascii.isWhitespace(text[i])) return null;
    const gt = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return null;
    return gt + 1;
}

/// `text[at..].startsWith("<![CDATA[")`. A CDATA section: everything up to
/// the first `]]>`.
fn scanHtmlCData(text: []const u8, at: usize) ?usize {
    const start = at + "<![CDATA[".len;
    const idx = std.mem.indexOfPos(u8, text, start, "]]>") orelse return null;
    return idx + 3;
}

// ── emphasis flanking (CommonMark 6.2) ──────────────────────────────────

const Flank = struct { can_open: bool, can_close: bool };

/// Classify a `*`/`_` delimiter run `text[run_start..run_end)` per
/// CommonMark's left/right-flanking rules, folding in `_`'s extra
/// "intraword" restriction (rules 1-8 of "Emphasis and strong emphasis").
/// The "rule of 3" (multiples-of-3 length interaction between an opener and
/// closer) is a separate, pairwise concern handled during matching
/// (`Scanner.processEmphasis`), not here.
fn computeFlanking(text: []const u8, run_start: usize, run_end: usize, ch: u8) Flank {
    const before_cp = codepointBefore(text, run_start);
    const after_cp = codepointAfter(text, run_end);

    const before_is_ws = before_cp == null or isUnicodeWhitespaceCp(before_cp.?);
    const before_is_punct = before_cp != null and isUnicodePunctuationCp(before_cp.?);
    const after_is_ws = after_cp == null or isUnicodeWhitespaceCp(after_cp.?);
    const after_is_punct = after_cp != null and isUnicodePunctuationCp(after_cp.?);

    const left_flanking = !after_is_ws and (!after_is_punct or before_is_ws or before_is_punct);
    const right_flanking = !before_is_ws and (!before_is_punct or after_is_ws or after_is_punct);

    if (ch == '_') {
        return .{
            .can_open = left_flanking and (!right_flanking or before_is_punct),
            .can_close = right_flanking and (!left_flanking or after_is_punct),
        };
    }
    return .{ .can_open = left_flanking, .can_close = right_flanking };
}

fn codepointAt(text: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return text[i];
    if (i + len > text.len) return text[i];
    return std.unicode.utf8Decode(text[i .. i + len]) catch text[i];
}

/// The code point starting at byte offset `i`, or `null` at end of text
/// (end of text counts as Unicode whitespace for flanking purposes, per
/// spec, which callers get for free by treating `null` as whitespace).
fn codepointAfter(text: []const u8, i: usize) ?u21 {
    if (i >= text.len) return null;
    return codepointAt(text, i);
}

/// The code point ending at byte offset `i` (i.e. immediately before it),
/// or `null` at start of text. Walks back over UTF-8 continuation bytes to
/// find the lead byte of the preceding code point.
fn codepointBefore(text: []const u8, i: usize) ?u21 {
    if (i == 0) return null;
    var start = i - 1;
    var back: usize = 0;
    while (start > 0 and (text[start] & 0xC0) == 0x80 and back < 3) : (back += 1) start -= 1;
    return codepointAt(text, start);
}

/// Unicode whitespace per CommonMark: Unicode `Zs` (space separator) code
/// points, plus tab/LF/FF/CR (which, for ASCII, is exactly
/// `std.ascii.isWhitespace`). Non-ASCII coverage is the common `Zs` code
/// points, not the complete set -- see this file's module doc comment.
fn isUnicodeWhitespaceCp(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isWhitespace(@intCast(cp));
    return switch (cp) {
        0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Unicode punctuation per CommonMark: code points in the Unicode P
/// (punctuation) or S (symbol) general categories. For ASCII this is
/// exactly `isAsciiPunct`; non-ASCII coverage is a curated table of common
/// blocks (General Punctuation, CJK punctuation, fullwidth ASCII forms),
/// not the complete Unicode category tables -- see this file's module doc
/// comment.
fn isUnicodePunctuationCp(cp: u21) bool {
    if (cp < 0x80) return isAsciiPunct(@intCast(cp));
    return switch (cp) {
        // Latin-1 Supplement P/S code points (0.31.2 counts Symbol categories
        // as punctuation for flanking, so currency like £/¥ blocks emphasis --
        // spec ex354). The interspersed letters/numbers (ª µ º ² ³ ¹ ¼ ½ ¾ and
        // the letter ranges) are deliberately excluded.
        0x00A1, 0x00A7, 0x00B6, 0x00BF => true, // ¡ § ¶ ¿ (Po)
        0x00A2...0x00A6 => true, // ¢ £ ¤ ¥ ¦ (Sc/So)
        0x00A8, 0x00A9, 0x00AC, 0x00AE, 0x00AF => true, // ¨ © ¬ ® ¯ (Sk/So/Sm)
        0x00AB, 0x00BB => true, // « » (Pi/Pf)
        0x00B0, 0x00B1, 0x00B4, 0x00B7, 0x00B8 => true, // ° ± ´ · ¸ (So/Sm/Sk/Po)
        0x00D7, 0x00F7 => true, // × ÷ (Sm)
        0x2010...0x2027, 0x2030...0x205E => true, // General Punctuation (dashes, quotes, ellipsis, etc.)
        0x20A0...0x20BF => true, // Currency Symbols block (€ etc., Sc)
        0x3001...0x303F => true, // CJK punctuation
        0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65 => true, // fullwidth ASCII punctuation
        else => false,
    };
}

/// After a break has just been consumed (the input cursor is right past the
/// `\n`), skip leading spaces/tabs on the following line — CommonMark's "a
/// line ending... [with] spaces at the end of the line and the beginning of
/// the next line ... removed" rule.
fn skipLeadingLineSpace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// How many of `buf`'s trailing bytes are the spaces that (per the hard-break
/// rule) should be stripped before the line break they precede — 0 if fewer
/// than two, otherwise the full run length (all get stripped either way; the
/// caller distinguishes hard vs. soft by comparing this count against 2).
fn trailingHardBreakSpaces(buf: []const u8) usize {
    var n: usize = 0;
    while (n < buf.len and buf[buf.len - 1 - n] == ' ') n += 1;
    return n;
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

// ── code spans ───────────────────────────────────────────────────────────

const CodeSpan = struct { end: usize, content_start: usize, content_end: usize };

/// `text[start] == '\''`, sorry — `'`` '`. Finds a closing backtick run of
/// exactly the same length as the opening run, per CommonMark's "Code
/// spans": the shortest such match starting after the opener. Returns `null`
/// if no run of matching length exists anywhere later in `text`, in which
/// case the opening backticks are literal text (handled by the caller).
fn scanCodeSpan(text: []const u8, start: usize) ?CodeSpan {
    var i = start;
    while (i < text.len and text[i] == '`') i += 1;
    const open_len = i - start;
    const content_start = i;
    var j = i;
    while (j < text.len) {
        if (text[j] == '`') {
            const run_start = j;
            while (j < text.len and text[j] == '`') j += 1;
            if (j - run_start == open_len) {
                return .{ .end = j, .content_start = content_start, .content_end = run_start };
            }
        } else {
            j += 1;
        }
    }
    return null;
}

/// Line endings inside a code span become spaces, and if the resulting
/// string both begins and ends with a space (but isn't all spaces), one
/// leading and one trailing space are stripped. Mirrors CommonMark's code
/// span content normalization.
fn normalizeCodeSpan(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (raw) |c| try out.append(allocator, if (c == '\n') ' ' else c);

    if (out.items.len >= 2 and out.items[0] == ' ' and out.items[out.items.len - 1] == ' ') {
        var all_spaces = true;
        for (out.items) |c| {
            if (c != ' ') {
                all_spaces = false;
                break;
            }
        }
        if (!all_spaces) {
            _ = out.orderedRemove(0);
            out.items.len -= 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── entity / numeric character references ──────────────────────────────

const CharRef = struct { text: []u8, end: usize };

/// `text[at] == '&'`. Returns the decoded UTF-8 replacement (caller-owned)
/// and the index just past the reference on success, or `null` if `text[at]`
/// doesn't begin a valid reference (in which case the `&` is literal).
fn decodeCharRef(allocator: Allocator, text: []const u8, at: usize) Allocator.Error!?CharRef {
    var i = at + 1;
    if (i < text.len and text[i] == '#') {
        i += 1;
        const hex = i < text.len and (text[i] == 'x' or text[i] == 'X');
        if (hex) i += 1;
        const digits_start = i;
        while (i < text.len and (if (hex) std.ascii.isHex(text[i]) else std.ascii.isDigit(text[i]))) i += 1;
        const digits = text[digits_start..i];
        // CommonMark caps decimal numeric references at 7 digits and
        // hexadecimal ones at 6 (`&#87654321;`, at 8 digits, is NOT a
        // reference at all -- it stays literal text, distinct from a
        // reference whose value is merely out of Unicode's range, which
        // decodes to U+FFFD).
        const max_digits: usize = if (hex) 6 else 7;
        if (digits.len == 0 or digits.len > max_digits) return null;
        if (i >= text.len or text[i] != ';') return null;
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
        const cp: u21 = if (value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF))
            0xFFFD
        else
            @intCast(value);
        var stack_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &stack_buf) catch blk: {
            // A surrogate or otherwise-invalid scalar slipped through the
            // check above (shouldn't happen given it above); fall back to
            // the replacement character rather than propagate the error.
            break :blk std.unicode.utf8Encode(0xFFFD, &stack_buf) catch unreachable;
        };
        // Allocate exactly `n` bytes (not the 4-byte scratch buffer's
        // size) so the caller can `free` the returned slice directly —
        // freeing a slice shorter than its original allocation is invalid.
        return .{ .text = try allocator.dupe(u8, stack_buf[0..n]), .end = i + 1 };
    }

    const name_start = i;
    while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
    const name = text[name_start..i];
    if (name.len == 0 or i >= text.len or text[i] != ';') return null;
    const replacement = entities.table.get(name) orelse return null;
    return .{ .text = try allocator.dupe(u8, replacement), .end = i + 1 };
}

const testing = std.testing;

const empty_refs: std.StringHashMapUnmanaged(Node.Id) = .empty;

fn parseAndFinish(text: []const u8) !AST {
    return parseAndFinishWithOptions(text, .{});
}

fn parseAndFinishWithOptions(text: []const u8, options: Options) !AST {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const children = try parseInline(&b, text, &.{}, &empty_refs, options);
    defer b.allocator.free(children);
    const root = try b.addContainer(.para, children);
    return b.finish(root);
}

/// Like `parseAndFinishWithOptions`, but treats `text` itself as "the
/// source" (a single `Segment` mapping the whole buffer onto itself 1:1),
/// so a test can slice `text` directly with a resulting node's `span` and
/// expect an exact match -- see this file's span tests below. Real callers
/// (`block.zig`) build `Segment`s mapping back into an actual document's
/// source instead; this is just the degenerate "the leaf text IS the
/// source" case, valid whenever `text` has no line joins/stripped markers
/// of its own (true for every single-line case these tests use).
fn parseAndFinishMapped(text: []const u8, options: Options) !AST {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const segs = [_]Segment{.{ .buf_offset = 0, .src_offset = 0, .len = text.len }};
    const children = try parseInline(&b, text, &segs, &empty_refs, options);
    defer b.allocator.free(children);
    const root = try b.addContainer(.para, children);
    return b.finish(root);
}

test "plain text becomes a single str node" {
    var ast = try parseAndFinish("hello world");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("hello world", ast.nodes[child].kind.str);
}

const directives_on: Options = .{ .directives = true };

test "text directive with label and attrs" {
    var ast = try parseAndFinishWithOptions(":abbr[HTML]{title=\"HyperText\" .up}", directives_on);
    defer ast.deinit();
    const dir = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[dir].kind == .directive);
    try testing.expectEqual(AST.DirectiveForm.text, ast.nodes[dir].kind.directive.form);
    try testing.expectEqualStrings("abbr", ast.nodes[dir].kind.directive.name);
    // label parsed as inline children
    const label_child = ast.nodes[dir].first_child.?;
    try testing.expectEqualStrings("HTML", ast.nodes[label_child].kind.str);
    // attrs
    const attrs = ast.attrsOf(dir);
    try testing.expectEqualStrings("HyperText", attrs.get("title").?);
    try testing.expectEqualStrings("up", attrs.get("class").?);
}

test "bare text directive (no label, no attrs)" {
    var ast = try parseAndFinishWithOptions(":here", directives_on);
    defer ast.deinit();
    const dir = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[dir].kind == .directive);
    try testing.expectEqualStrings("here", ast.nodes[dir].kind.directive.name);
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[dir].first_child);
}

test "text directive label parses nested inline" {
    var ast = try parseAndFinishWithOptions(":span[a *b* c]", directives_on);
    defer ast.deinit();
    const dir = ast.nodes[ast.root].first_child.?;
    const first = ast.nodes[dir].first_child.?;
    try testing.expectEqualStrings("a ", ast.nodes[first].kind.str);
    const emph = ast.nodes[first].next_sibling.?;
    try testing.expect(ast.nodes[emph].kind == .emph);
}

test "colon not starting a valid directive stays literal" {
    // digit-led name is not a directive; whole thing is text
    var ast = try parseAndFinishWithOptions("ratio 3:4 mix", directives_on);
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("ratio 3:4 mix", ast.nodes[child].kind.str);
}

test "directives disabled: no directive node is produced" {
    var ast = try parseAndFinishWithOptions(":abbr[HTML]", .{});
    defer ast.deinit();
    for (ast.nodes) |n| try testing.expect(n.kind != .directive);
    // the colon in particular is plain literal text
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings(":abbr", ast.nodes[child].kind.str);
}

test "backslash escape yields the literal punctuation character" {
    var ast = try parseAndFinish("\\*not emphasis\\*");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("*not emphasis*", ast.nodes[child].kind.str);
}

test "a backslash before a non-punctuation character is literal" {
    var ast = try parseAndFinish("\\a");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("\\a", ast.nodes[child].kind.str);
}

test "named and numeric entities decode to UTF-8" {
    var ast = try parseAndFinish("&amp; &#65; &#x41;");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("& A A", ast.nodes[child].kind.str);
}

test "an unknown entity name stays literal" {
    var ast = try parseAndFinish("&nosuchentity;");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("&nosuchentity;", ast.nodes[child].kind.str);
}

test "code span strips one matching leading/trailing space and converts newlines to spaces" {
    var ast = try parseAndFinish("a `` `foo` `` b");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const s1 = it.next().?;
    try testing.expectEqualStrings("a ", s1.kind.str);
    const code = it.next().?;
    try testing.expectEqualStrings("`foo`", code.kind.verbatim);
    const s2 = it.next().?;
    try testing.expectEqualStrings(" b", s2.kind.str);
}

test "two trailing spaces before a line ending produce a hard break" {
    var ast = try parseAndFinish("foo  \nbar");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const s1 = it.next().?;
    try testing.expectEqualStrings("foo", s1.kind.str);
    const brk = it.next().?;
    try testing.expect(brk.kind == .hard_break);
    const s2 = it.next().?;
    try testing.expectEqualStrings("bar", s2.kind.str);
}

test "a backslash before a line ending produces a hard break" {
    var ast = try parseAndFinish("foo\\\nbar");
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?;
    const brk = it.next().?;
    try testing.expect(brk.kind == .hard_break);
}

test "a plain line ending is a soft break" {
    var ast = try parseAndFinish("foo\nbar");
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?;
    const brk = it.next().?;
    try testing.expect(brk.kind == .soft_break);
}

test "simple emphasis and strong emphasis" {
    var ast = try parseAndFinish("*em* and **strong**");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const em = it.next().?;
    try testing.expect(em.kind == .emph);
    try testing.expectEqualStrings("em", ast.nodes[em.first_child.?].kind.str);
    _ = it.next().?; // " and "
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    try testing.expectEqualStrings("strong", ast.nodes[strong.first_child.?].kind.str);
}

test "nested emphasis inside strong inside emphasis" {
    // *a **b** c* -> <em>a <strong>b</strong> c</em>
    var ast = try parseAndFinish("*a **b** c*");
    defer ast.deinit();
    const em = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[em].kind == .emph);
    var it = ast.children(em);
    const t1 = it.next().?;
    try testing.expectEqualStrings("a ", t1.kind.str);
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    try testing.expectEqualStrings("b", ast.nodes[strong.first_child.?].kind.str);
    const t2 = it.next().?;
    try testing.expectEqualStrings(" c", t2.kind.str);
}

test "underscore emphasis and asterisk strong side by side" {
    var ast = try parseAndFinish("**a** and _b_");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    _ = it.next().?; // " and "
    const em = it.next().?;
    try testing.expect(em.kind == .emph);
    try testing.expectEqualStrings("b", ast.nodes[em.first_child.?].kind.str);
}

test "intraword underscore does not open emphasis" {
    var ast = try parseAndFinish("a_b_c");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("a_b_c", ast.nodes[child].kind.str);
}

test "asterisk strong can start immediately after a word (no intraword restriction)" {
    var ast = try parseAndFinish("foo**bar**baz");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const t1 = it.next().?;
    try testing.expectEqualStrings("foo", t1.kind.str);
    const strong = it.next().?;
    try testing.expect(strong.kind == .strong);
    try testing.expectEqualStrings("bar", ast.nodes[strong.first_child.?].kind.str);
    const t2 = it.next().?;
    try testing.expectEqualStrings("baz", t2.kind.str);
}

test "inline link with a title" {
    var ast = try parseAndFinish("[foo](/url \"title\")");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
    try testing.expectEqual(@as(?[]const u8, null), ast.nodes[link].kind.link.reference);
    try testing.expectEqualStrings("title", ast.attrsOf(link).get("title").?);
    try testing.expectEqualStrings("foo", ast.nodes[ast.nodes[link].first_child.?].kind.str);
}

test "inline image" {
    var ast = try parseAndFinish("![alt text](/img.png)");
    defer ast.deinit();
    const img = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[img].kind == .image);
    try testing.expectEqualStrings("/img.png", ast.nodes[img].kind.image.destination.?);
    try testing.expectEqualStrings("alt text", ast.nodes[ast.nodes[img].first_child.?].kind.str);
}

test "autolink URI and email" {
    var ast = try parseAndFinish("<https://example.com> <foo@bar.com>");
    defer ast.deinit();
    var it = ast.children(ast.root);
    const url = it.next().?;
    try testing.expect(url.kind == .url);
    try testing.expectEqualStrings("https://example.com", url.kind.url);
    _ = it.next().?; // " "
    const email = it.next().?;
    try testing.expect(email.kind == .email);
    try testing.expectEqualStrings("foo@bar.com", email.kind.email);
}

test "raw inline HTML passes through as raw_inline" {
    var ast = try parseAndFinish("a <span class=\"x\"> b");
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?; // "a "
    const raw = it.next().?;
    try testing.expect(raw.kind == .raw_inline);
    try testing.expectEqualStrings("html", raw.kind.raw_inline.format);
    try testing.expectEqualStrings("<span class=\"x\">", raw.kind.raw_inline.text);
}

/// Builds a one-entry `link_references` table (mirroring what `block.zig`
/// hands `parseInline` for a real document) so full/collapsed/shortcut
/// reference-link resolution can be exercised without going through the
/// block parser.
fn parseWithOneReference(text: []const u8, label: []const u8, dest: []const u8) !AST {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const ref_id = try b.addLeaf(.{ .reference = .{ .label = label, .destination = dest } });
    var refs: std.StringHashMapUnmanaged(Node.Id) = .empty;
    defer refs.deinit(testing.allocator);
    try refs.put(testing.allocator, b.nodes.items[ref_id].kind.reference.label, ref_id);

    const children = try parseInline(&b, text, &.{}, &refs, .{});
    defer b.allocator.free(children);
    const root = try b.addContainer(.para, children);
    return b.finish(root);
}

test "full reference link resolves against link_references" {
    var ast = try parseWithOneReference("[foo][bar]", "bar", "/url");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
    try testing.expectEqualStrings("foo", ast.nodes[ast.nodes[link].first_child.?].kind.str);
}

test "collapsed reference link resolves against link_references" {
    var ast = try parseWithOneReference("[foo][]", "foo", "/url");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
}

test "shortcut reference link resolves against link_references" {
    var ast = try parseWithOneReference("[foo]", "foo", "/url");
    defer ast.deinit();
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("/url", ast.nodes[link].kind.link.destination.?);
}

test "an unresolved reference label falls back to literal brackets" {
    var ast = try parseWithOneReference("[foo][nope]", "bar", "/url");
    defer ast.deinit();
    // A failed match doesn't re-coalesce its `[`/text/`]` fragments back
    // into one node (each bracket attempt got its own placeholder item
    // along the way) -- concatenating every child's literal text is the
    // right way to check "this rendered as plain text", not a single node's
    // `.str` field. (The HTML output is identical either way.)
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var it = ast.children(ast.root);
    while (it.next()) |n| try buf.appendSlice(testing.allocator, n.kind.str);
    try testing.expectEqualStrings("[foo][nope]", buf.items);
}

test "unhandled inline markup (unresolved brackets) passes through as literal text" {
    var ast = try parseAndFinish("[link](url)");
    defer ast.deinit();
    // No reference table entry and a syntactically valid inline destination
    // -- this one DOES resolve (Phase 2); assert the structured result
    // instead of literal passthrough, which was Phase 1's contract for this
    // exact input.
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
}

// ── span accuracy (byte-accurate, delimiters included) ──────────────────
// See `Segment`'s doc comment: these use `parseAndFinishMapped`, which
// treats the `text` argument as its own source (a single identity segment),
// so a node's resolved `span`/`content_span` can be sliced directly out of
// the very same string and compared byte-for-byte.

test "span: a str leaf's span is its own exact bytes" {
    var ast = try parseAndFinishMapped("hello world", .{});
    defer ast.deinit();
    const s = "hello world";
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings(s, Span.of(u8, ast.nodes[child].span, s));
}

test "span: emphasis covers the delimiters, content_span covers just the interior" {
    var ast = try parseAndFinishMapped("*abc*", .{});
    defer ast.deinit();
    const s = "*abc*";
    const em = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[em].kind == .emph);
    try testing.expectEqualStrings("*abc*", Span.of(u8, ast.nodes[em].span, s));
    try testing.expectEqualStrings("abc", Span.of(u8, ast.nodes[em].content_span.?, s));
}

test "span: strong emphasis covers its own delimiters" {
    var ast = try parseAndFinishMapped("**abc**", .{});
    defer ast.deinit();
    const s = "**abc**";
    const strong = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[strong].kind == .strong);
    try testing.expectEqualStrings("**abc**", Span.of(u8, ast.nodes[strong].span, s));
    try testing.expectEqualStrings("abc", Span.of(u8, ast.nodes[strong].content_span.?, s));
}

test "span: a partially-consumed delimiter run pairs its leftover with an outer opener" {
    // "*a **b***": the `***` closer (3) first pairs 2 of its delimiters with
    // the inner `**` opener to form `strong` over "**b**", and its leftover
    // single `*` then pairs with the OUTER leading `*` to form `emph` over
    // the whole "*a **b***" (CommonMark: <em>a <strong>b</strong></em>). This
    // leftover-opener re-match is exactly the delimiter-stack bookkeeping in
    // `processEmphasis` (spec ex409/414/415). Spans must stay byte-accurate
    // through both the partial consumption and the outer pairing.
    var ast = try parseAndFinishMapped("*a **b***", .{});
    defer ast.deinit();
    const s = "*a **b***";

    const emph = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[emph].kind == .emph);
    try testing.expectEqualStrings("*a **b***", Span.of(u8, ast.nodes[emph].span, s));
    try testing.expectEqualStrings("a **b**", Span.of(u8, ast.nodes[emph].content_span.?, s));
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[emph].next_sibling);

    const a_space = ast.nodes[emph].first_child.?;
    try testing.expectEqualStrings("a ", Span.of(u8, ast.nodes[a_space].span, s));

    const strong = ast.nodes[a_space].next_sibling.?;
    try testing.expect(ast.nodes[strong].kind == .strong);
    try testing.expectEqualStrings("**b**", Span.of(u8, ast.nodes[strong].span, s));
    try testing.expectEqualStrings("b", Span.of(u8, ast.nodes[strong].content_span.?, s));
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[strong].next_sibling);
}

test "span: an inline link covers '[text](dest)', content_span covers just the text" {
    var ast = try parseAndFinishMapped("[x](http://a.co)", .{});
    defer ast.deinit();
    const s = "[x](http://a.co)";
    const link = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("[x](http://a.co)", Span.of(u8, ast.nodes[link].span, s));
    try testing.expectEqualStrings("x", Span.of(u8, ast.nodes[link].content_span.?, s));
}

test "span: an inline image covers '![alt](dest)'" {
    var ast = try parseAndFinishMapped("![alt](/a.png)", .{});
    defer ast.deinit();
    const s = "![alt](/a.png)";
    const img = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[img].kind == .image);
    try testing.expectEqualStrings("![alt](/a.png)", Span.of(u8, ast.nodes[img].span, s));
    try testing.expectEqualStrings("alt", Span.of(u8, ast.nodes[img].content_span.?, s));
}

test "span: a code span covers its own backticks" {
    var ast = try parseAndFinishMapped("a `bc` d", .{});
    defer ast.deinit();
    const s = "a `bc` d";
    const first = ast.nodes[ast.root].first_child.?; // "a "
    const code = ast.nodes[first].next_sibling.?; // the verbatim node
    try testing.expect(ast.nodes[code].kind == .verbatim);
    try testing.expectEqualStrings("`bc`", Span.of(u8, ast.nodes[code].span, s));
}

test "span: a strikethrough delete node covers '~~text~~'" {
    var ast = try parseAndFinishMapped("~~gone~~", .{ .strikethrough = true });
    defer ast.deinit();
    const s = "~~gone~~";
    const del = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[del].kind == .delete);
    try testing.expectEqualStrings("~~gone~~", Span.of(u8, ast.nodes[del].span, s));
    try testing.expectEqualStrings("gone", Span.of(u8, ast.nodes[del].content_span.?, s));
}

test "span: an autolink covers '<...>' including the angle brackets" {
    var ast = try parseAndFinishMapped("<http://a.co>", .{});
    defer ast.deinit();
    const s = "<http://a.co>";
    const url = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[url].kind == .url);
    try testing.expectEqualStrings(s, Span.of(u8, ast.nodes[url].span, s));
}

test "span: a node with no segment map is left unset (0,0)" {
    // The plain (unmapped) helper -- no `Segment`s at all -- must never
    // fabricate a span.
    var ast = try parseAndFinish("*abc*");
    defer ast.deinit();
    const em = ast.nodes[ast.root].first_child.?;
    try testing.expectEqual(@as(usize, 0), ast.nodes[em].span.start);
    try testing.expectEqual(@as(usize, 0), ast.nodes[em].span.end);
}

// ── Phase 3: footnote references ────────────────────────────────────────

test "footnote reference: [^label] becomes a footnote_reference node when the flag is on" {
    var ast = try parseAndFinishWithOptions("see[^a]", .{ .footnotes = true });
    defer ast.deinit();
    var it = ast.children(ast.root);
    const text = it.next().?;
    try testing.expectEqualStrings("see", text.kind.str);
    const ref = it.next().?;
    try testing.expect(ref.kind == .footnote_reference);
    try testing.expectEqualStrings("a", ref.kind.footnote_reference);
    try testing.expectEqual(@as(?*const AST.Node, null), it.next());
}

test "footnote reference: the label is normalized (trim/collapse ws/lowercase), matching link labels" {
    var ast = try parseAndFinishWithOptions("[^ A  B ]", .{ .footnotes = true });
    defer ast.deinit();
    const ref = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[ref].kind == .footnote_reference);
    try testing.expectEqualStrings("a b", ast.nodes[ref].kind.footnote_reference);
}

test "footnote reference OFF: [^a] parses as plain CommonMark (an unresolved shortcut link falls back to literal brackets)" {
    var ast = try parseAndFinishWithOptions("[^a]", .{ .footnotes = false });
    defer ast.deinit();
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var it = ast.children(ast.root);
    while (it.next()) |n| try buf.appendSlice(testing.allocator, n.kind.str);
    try testing.expectEqualStrings("[^a]", buf.items);
}

// ── Phase 3: strikethrough ────────────────────────────────────────────────

test "strikethrough: ~~text~~ becomes a delete node when the flag is on" {
    var ast = try parseAndFinishWithOptions("~~gone~~", .{ .strikethrough = true });
    defer ast.deinit();
    const del = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[del].kind == .delete);
    try testing.expectEqualStrings("gone", ast.nodes[ast.nodes[del].first_child.?].kind.str);
}

test "strikethrough: single tilde also delimits (GFM allows one or two)" {
    var ast = try parseAndFinishWithOptions("~gone~", .{ .strikethrough = true });
    defer ast.deinit();
    const del = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[del].kind == .delete);
    try testing.expectEqualStrings("gone", ast.nodes[ast.nodes[del].first_child.?].kind.str);
}

test "strikethrough: a run of 3+ tildes is never a delimiter, stays literal" {
    var ast = try parseAndFinishWithOptions("~~~not~~~", .{ .strikethrough = true });
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("~~~not~~~", ast.nodes[child].kind.str);
}

test "strikethrough OFF: ~~text~~ parses as plain CommonMark literal text" {
    var ast = try parseAndFinishWithOptions("~~gone~~", .{ .strikethrough = false });
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("~~gone~~", ast.nodes[child].kind.str);
}

// ── Phase 3: math ────────────────────────────────────────────────────────

test "inline math: $x$ becomes inline_math when the flag is on" {
    var ast = try parseAndFinishWithOptions("$x^2$", .{ .math = true });
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[child].kind == .inline_math);
    try testing.expectEqualStrings("x^2", ast.nodes[child].kind.inline_math);
}

test "display math: $$x$$ becomes display_math when the flag is on" {
    var ast = try parseAndFinishWithOptions("$$x^2$$", .{ .math = true });
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[child].kind == .display_math);
    try testing.expectEqualStrings("x^2", ast.nodes[child].kind.display_math);
}

test "math OFF (the default): $x$ parses as plain CommonMark literal text" {
    var ast = try parseAndFinish("$x$");
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("$x$", ast.nodes[child].kind.str);
}

test "math: a dollar sign followed by whitespace never opens math" {
    var ast = try parseAndFinishWithOptions("costs $5 and $10 total", .{ .math = true });
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("costs $5 and $10 total", ast.nodes[child].kind.str);
}

// ── Phase 3: GFM extended autolinks ─────────────────────────────────────

test "extended autolink: bare https:// URL becomes a url node" {
    var ast = try parseAndFinishWithOptions("see https://example.com/x for more", .{ .autolinks = true });
    defer ast.deinit();
    var it = ast.children(ast.root);
    const s1 = it.next().?;
    try testing.expectEqualStrings("see ", s1.kind.str);
    const url = it.next().?;
    try testing.expect(url.kind == .url);
    try testing.expectEqualStrings("https://example.com/x", url.kind.url);
}

test "extended autolink: www. gets an http:// prefix on the destination, text unchanged" {
    var ast = try parseAndFinishWithOptions("visit www.example.com now", .{ .autolinks = true });
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?; // "visit "
    const link = it.next().?;
    try testing.expect(link.kind == .link);
    try testing.expectEqualStrings("http://www.example.com", link.kind.link.destination.?);
    try testing.expectEqualStrings("www.example.com", ast.nodes[link.first_child.?].kind.str);
}

test "extended autolink: trailing sentence punctuation is trimmed off the link" {
    var ast = try parseAndFinishWithOptions("Check https://example.com.", .{ .autolinks = true });
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?; // "Check "
    const url = it.next().?;
    try testing.expect(url.kind == .url);
    try testing.expectEqualStrings("https://example.com", url.kind.url);
    const trailing = it.next().?;
    try testing.expectEqualStrings(".", trailing.kind.str);
}

test "extended autolink: a balanced trailing paren is kept, an unbalanced one is trimmed" {
    var ast = try parseAndFinishWithOptions("(see https://en.wikipedia.org/wiki/Foo_(bar))", .{ .autolinks = true });
    defer ast.deinit();
    var it = ast.children(ast.root);
    _ = it.next().?; // "(see "
    const url = it.next().?;
    try testing.expect(url.kind == .url);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", url.kind.url);
    const trailing = it.next().?;
    try testing.expectEqualStrings(")", trailing.kind.str);
}

test "extended autolink: bare email address becomes an email node" {
    var ast = try parseAndFinishWithOptions("contact foo@bar.example.com today", .{ .autolinks = true });
    defer ast.deinit();
    var it = ast.children(ast.root);
    const s1 = it.next().?;
    try testing.expectEqualStrings("contact ", s1.kind.str);
    const email = it.next().?;
    try testing.expect(email.kind == .email);
    try testing.expectEqualStrings("foo@bar.example.com", email.kind.email);
}

test "extended autolinks OFF: bare www./http(s) text parses as plain CommonMark literal text" {
    var ast = try parseAndFinishWithOptions("see www.example.com and https://x.com", .{ .autolinks = false });
    defer ast.deinit();
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var it = ast.children(ast.root);
    while (it.next()) |n| try buf.appendSlice(testing.allocator, n.kind.str);
    try testing.expectEqualStrings("see www.example.com and https://x.com", buf.items);
}

test "extended autolinks: a word-internal http:// (preceded by a letter) does not autolink" {
    var ast = try parseAndFinishWithOptions("xhttp://example.com", .{ .autolinks = true });
    defer ast.deinit();
    const child = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("xhttp://example.com", ast.nodes[child].kind.str);
}
