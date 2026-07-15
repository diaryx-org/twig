//! CommonMark block structure: source text -> `AST`, via an incremental
//! line-by-line scan that mirrors the strategy sketched in the CommonMark
//! spec's own "Appendix: A parsing strategy" (and implemented, in spirit, by
//! `cmark`/`commonmark.js`) — maintain a stack of currently OPEN block
//! containers (the document, plus any block quotes / list items nested
//! inside it) and, for each input line, (1) match as much of the line as
//! possible against that stack's markers/indentation, (2) decide whether
//! the containers that failed to match should really close (vs. this being
//! a *lazy continuation* line of an open paragraph, which doesn't need to
//! repeat its ancestors' markers), (3) either continue an open leaf block
//! (paragraph/code/HTML) or scan the remaining text for a new block start.
//!
//! Unlike `languages/djot/parser.zig` (which manages its own flat node
//! array because it needs to mutate already-emitted nodes), this builds
//! purely bottom-up — a container's children are fully known before the
//! container itself is ever handed to `AST.Builder.addContainer` — so
//! `Builder`'s batch-children API fits directly (see `languages/xml/parser.zig`
//! for the same shape of recursive-descent-onto-`Builder` this mirrors,
//! modulo the block scan being iterative-over-lines rather than
//! recursive-over-tags).
//!
//! ── Scope (Phase 1) ─────────────────────────────────────────────────────
//! Implements CommonMark block structure per the mission: blank lines, ATX
//! and setext headings, thematic breaks, indented and fenced code blocks,
//! block quotes (with lazy continuation), bullet/ordered lists (marker
//! parsing, start number, tight/loose detection), paragraphs, the 7 HTML
//! block start conditions, and link reference definitions (parsed, stripped
//! from the block stream, and recorded in `link_references` — never
//! rendered as nodes themselves). Inline content is delegated to
//! `inline.zig`'s deliberately minimal Phase 1 subset.
//!
//! ── Documented simplifications ───────────────────────────────────────────
//! These are approximations of the full CommonMark grammar, each chosen to
//! keep this file tractable; `conformance.zig` reports the resulting gap
//! against the spec's own test suite rather than papering over it:
//!   - Tabs: a tab always advances the column to the next multiple of 4 (per
//!     spec), but when consuming a *bounded* number of indent columns (e.g.
//!     "at most 3" before a block-quote marker), a tab that would overshoot
//!     the bound is left unconsumed rather than being split into partial
//!     spaces — CommonMark's own reference dialect partially expands such a
//!     tab; the "Tabs" section of the spec test suite exercises exactly this
//!     and is where this shows up.
//!   - List-item tight/loose detection uses the standard "blank line seen
//!     while the list is open, followed by more content added to it before
//!     it closes" rule (see `markListsLoose`/`Container.blank_pending`),
//!     which matches the spec's definition but is tracked with a simpler
//!     bookkeeping scheme than cmark's; deeply nested blank-line placements
//!     are less exhaustively tested here.
//!   - HTML block type 7 (a bare complete tag with nothing else on the
//!     line) uses a hand-rolled approximation of the HTML tag grammar
//!     (`parseCompleteTag`) rather than the full attribute-value grammar.
//!   - Link reference definitions: if a title candidate is present but
//!     malformed (trailing non-whitespace after its closing delimiter), the
//!     whole definition attempt is rejected rather than the spec's
//!     backtrack-and-retry-without-a-title.
//!   - Label/link-reference normalization case-folds ASCII only (not full
//!     Unicode case folding).
//!
//! ── Inline spans ─────────────────────────────────────────────────────────
//! Block nodes get their `span` directly from `lineStart`/`lineEnd` (this
//! file always knows a line's absolute source offset). Inline nodes are
//! trickier: `resolvePendingInline` hands `inline.zig`'s `parseInline` an
//! already-ASSEMBLED text buffer (`PendingInline.text`) -- indentation and
//! block markers stripped, multiple lines joined with a synthetic `\n` --
//! that no longer has a fixed offset from the source. Every place this file
//! builds such a buffer (`Leaf.text`/`.text_segs` for paragraphs and setext
//! headings; the local `content`/`content_segs` in
//! `tryStartDefinitionList`'s definition-body loop) tracks, alongside the
//! text itself, a list of `Segment`s recording which run of the assembled
//! buffer came from which run of the ORIGINAL source (`appendMappedSource`
//! records one; a synthetic separator byte, e.g. the line-join `\n`, is
//! appended with `appendUnmappedByte` and simply isn't covered by any
//! segment). `PendingInline.segments` carries these through to
//! `parseInline`, which -- via `Scanner.mapSpan` -- can then give a node an
//! exact absolute span whenever its whole local extent falls within ONE
//! segment, and must leave it unset (`(0,0)`) otherwise (typically: a
//! construct that straddles a multi-line block's line join). Single-line
//! constructs (ATX headings, GFM table cells, most definition-list terms)
//! skip the segment-list machinery entirely and just hand `parseInline` one
//! segment covering the whole (always-single-line, hence always-contiguous)
//! text -- see `singleSegment`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const Span = @import("../../span.zig");
const Options = @import("options.zig");
const inline_mod = @import("inline.zig");
const attrs_mod = @import("attributes.zig");

/// Re-exported for readability at this file's own call sites -- see
/// `inline_mod.Segment`'s doc comment for what it means and this file's
/// module doc comment section on inline spans for how it's built here.
const Segment = inline_mod.Segment;

pub const BlockResult = struct {
    ast: AST,
    link_references: std.StringHashMapUnmanaged(Node.Id),
    /// Label (normalized via `normalizeLabel`, same as `link_references`) ->
    /// the `footnote` definition node with that label (`self.options
    /// .footnotes`; see this file's "footnote definitions" section). Mirrors
    /// `link_references`'s shape and lifetime: keys are slices of the
    /// `footnote` node's own owned `.label` string, not separately
    /// allocated.
    footnotes: std.StringHashMapUnmanaged(Node.Id),
};

// ── low-level line/column helpers ───────────────────────────────────────

/// A position on the current line. `col` is the visual column of the byte at
/// `pos` (its *start*, a byte boundary). `spent` handles the CommonMark rule
/// that a tab advances to the next 4-column stop but can be consumed a column
/// at a time: when `spent > 0`, `line[pos]` is a `\t` whose first `spent`
/// columns have already been consumed, so the *logical* column here is
/// `col + spent` and the tab still contributes `(4 - col%4) - spent` columns
/// of content whitespace. Almost all cursors have `spent == 0`; it only
/// becomes nonzero when a container prefix (a block-quote marker's optional
/// space, or a list item's required indent) lands in the middle of a tab.
const Cursor = struct { pos: usize = 0, col: usize = 0, spent: usize = 0 };

/// The degenerate `(0,0)` span `AST.Builder.addNode`/`addLeaf`/`addContainer`
/// default every node to, meaning "never explicitly set" -- mirrors
/// `ast/editor.zig`'s own `nodeSpan` check (the span-splice editor's
/// definition of "this node has no usable span").
fn isUnsetSpan(s: Span) bool {
    return s.start == 0 and s.end == 0;
}

fn isBlankLine(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// A frontmatter language tag (`figl`, `toml`, `ld+json`): starts with a
/// letter, then letters/digits/`-_.+`. Two jobs: (1) gate a `---<tag>` fence
/// apart from a `----` thematic break (whose remainder, `-`, isn't a valid
/// tag), and (2) guarantee the tag is a legal MIME subtype, since the HTML
/// projection derives the type mechanically as `application/<tag>` — this
/// admitted set is a strict subset of RFC 6838's subtype grammar, so no
/// escaping is ever needed.
fn isLangTag(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '+') return false;
    }
    return true;
}

/// Columns of leading whitespace from `cur`'s logical position (`col+spent`)
/// to the first non-whitespace byte, tabs advancing to the next multiple-of-4
/// column (per CommonMark's tab-handling rule).
fn indentCols(line: []const u8, cur: Cursor) usize {
    var col = cur.col;
    var i = cur.pos;
    while (i < line.len) {
        if (line[i] == ' ') {
            col += 1;
            i += 1;
        } else if (line[i] == '\t') {
            col += 4 - (col % 4);
            i += 1;
        } else break;
    }
    // `col` is now the logical column at the first non-ws byte (each tab was
    // advanced to its stop); subtract the logical start (`cur.col + cur.spent`,
    // accounting for any already-consumed columns of a straddled leading tab).
    return col - (cur.col + cur.spent);
}

/// Consume up to `max_cols` columns of leading whitespace, splitting a tab
/// that straddles the limit: the tab byte stays at `pos` with `spent` marking
/// how many of its columns were taken (CommonMark's partial-tab rule).
fn skipWsUpToCols(line: []const u8, cur: Cursor, max_cols: usize) Cursor {
    var col = cur.col;
    var i = cur.pos;
    var spent = cur.spent;
    var consumed: usize = 0;
    while (i < line.len and consumed < max_cols) {
        const c = line[i];
        if (c == ' ') {
            col += 1;
            i += 1;
            consumed += 1;
            spent = 0;
        } else if (c == '\t') {
            const avail = (4 - (col % 4)) - spent; // remaining columns of this tab
            if (consumed + avail <= max_cols) {
                consumed += avail;
                col += 4 - (col % 4);
                i += 1;
                spent = 0;
            } else {
                spent += max_cols - consumed;
                consumed = max_cols;
                break;
            }
        } else break;
    }
    return .{ .pos = i, .col = col, .spent = spent };
}

/// Consume leading whitespace until the logical column reaches (at least)
/// `target_col`, or a non-whitespace byte is hit. A tab straddling the target
/// is split via `spent` (see `Cursor`).
fn skipWsToTarget(line: []const u8, cur: Cursor, target_col: usize) Cursor {
    var col = cur.col;
    var i = cur.pos;
    var spent = cur.spent;
    while (i < line.len and (col + spent) < target_col) {
        const c = line[i];
        if (c == ' ') {
            col += 1;
            i += 1;
            spent = 0;
        } else if (c == '\t') {
            const tab_end = col + (4 - (col % 4));
            if (tab_end <= target_col) {
                col = tab_end;
                i += 1;
                spent = 0;
            } else {
                spent = target_col - col;
                break;
            }
        } else break;
    }
    return .{ .pos = i, .col = col, .spent = spent };
}

fn stripUpTo3Indent(s: []const u8) []const u8 {
    const c = skipWsUpToCols(s, .{}, 3);
    return s[c.pos..];
}

fn trimLeadingWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn isAsciiLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAsciiLetterOrDigit(c: u8) bool {
    return isAsciiLetter(c) or (c >= '0' and c <= '9');
}

// ── block-start pattern matchers (pure; operate on an indent-stripped line) ─

fn isThematicBreak(s: []const u8) bool {
    var count: usize = 0;
    var ch: u8 = 0;
    for (s) |c| {
        if (c == '*' or c == '-' or c == '_') {
            if (ch == 0) ch = c else if (c != ch) return false;
            count += 1;
        } else if (c == ' ' or c == '\t') {
            // ok
        } else return false;
    }
    return count >= 3;
}

const AtxHeading = struct { level: u32, content: []const u8 };

fn tryAtxHeading(s: []const u8) ?AtxHeading {
    var i: usize = 0;
    while (i < s.len and s[i] == '#') i += 1;
    if (i == 0 or i > 6) return null;
    if (i < s.len and s[i] != ' ' and s[i] != '\t') return null;
    var content_start = i;
    while (content_start < s.len and (s[content_start] == ' ' or s[content_start] == '\t')) content_start += 1;
    var end = s.len;
    while (end > content_start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    var hash_start = end;
    while (hash_start > content_start and s[hash_start - 1] == '#') hash_start -= 1;
    if (hash_start < end and (hash_start == content_start or s[hash_start - 1] == ' ' or s[hash_start - 1] == '\t')) {
        end = hash_start;
        while (end > content_start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    }
    return .{ .level = @intCast(i), .content = s[content_start..end] };
}

/// A setext underline: a line consisting solely of `=` characters (level 1)
/// or solely of `-` characters (level 2), with any number of trailing
/// spaces/tabs.
fn trySetextUnderline(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    const ch = s[0];
    if (ch != '=' and ch != '-') return null;
    var i: usize = 0;
    while (i < s.len and s[i] == ch) i += 1;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i != s.len) return null;
    return if (ch == '=') 1 else 2;
}

const FenceOpen = struct { char: u8, len: usize, info: []const u8 };

fn tryFenceOpen(s: []const u8) ?FenceOpen {
    if (s.len == 0) return null;
    const c = s[0];
    if (c != '`' and c != '~') return null;
    var i: usize = 0;
    while (i < s.len and s[i] == c) i += 1;
    if (i < 3) return null;
    const rest = s[i..];
    if (c == '`' and std.mem.indexOfScalar(u8, rest, '`') != null) return null;
    return .{ .char = c, .len = i, .info = std.mem.trim(u8, rest, " \t") };
}

fn isFenceClose(s: []const u8, fence_char: u8, fence_len: usize) bool {
    var i: usize = 0;
    while (i < s.len and s[i] == fence_char) i += 1;
    if (i < fence_len) return false;
    for (s[i..]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

const ListMarker = struct {
    ordered: bool,
    bullet_char: u8 = 0,
    delim: AST.OrderedListStyle.Delim = .period,
    start: ?u32 = null,
    marker_len: usize,
};

fn tryListMarker(s: []const u8) ?ListMarker {
    if (s.len == 0) return null;
    const c = s[0];
    if (c == '-' or c == '+' or c == '*') {
        if (s.len > 1 and s[1] != ' ' and s[1] != '\t') return null;
        return .{ .ordered = false, .bullet_char = c, .marker_len = 1 };
    }
    if (c >= '0' and c <= '9') {
        var i: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i > 9) return null;
        if (i >= s.len) return null;
        const delim_ch = s[i];
        if (delim_ch != '.' and delim_ch != ')') return null;
        const marker_len = i + 1;
        if (marker_len < s.len and s[marker_len] != ' ' and s[marker_len] != '\t') return null;
        const num = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
        return .{ .ordered = true, .delim = if (delim_ch == '.') .period else .paren_after, .start = num, .marker_len = marker_len };
    }
    return null;
}

const TaskMarker = struct { checked: bool, rest: []const u8 };

/// GFM task list marker: `[ ]`, `[x]`, or `[X]`, immediately followed by a
/// space/tab or end of the item's first line (`after_marker` is the item's
/// content, i.e. everything after the list marker itself and its own
/// separating whitespace). Returns `null` for anything else, leaving the
/// item as an ordinary `list_item`.
fn tryTaskListMarker(after_marker: []const u8) ?TaskMarker {
    if (after_marker.len < 3) return null;
    if (after_marker[0] != '[') return null;
    const c = after_marker[1];
    if (c != ' ' and c != 'x' and c != 'X') return null;
    if (after_marker[2] != ']') return null;
    if (after_marker.len == 3) return .{ .checked = c != ' ', .rest = "" };
    if (after_marker[3] != ' ' and after_marker[3] != '\t') return null;
    return .{ .checked = c != ' ', .rest = after_marker[4..] };
}

/// True when `s` looks like the start of some OTHER block construct
/// (block quote / thematic break / ATX heading / fence / list marker / HTML
/// block) -- used by both `tryStartTable` and `tryStartDefinitionList` to
/// decide when a subsequent line ends their own multi-line construct rather
/// than continuing it (GFM: "The table is broken at ... the beginning of
/// another block-level structure"). Deliberately reuses the SAME pattern
/// matchers `tryStartBlocks` itself uses, rather than a separate/looser
/// heuristic, so "does this line start a new block" means the same thing in
/// both places.
fn looksLikeNewBlockStart(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '>') return true;
    if (isThematicBreak(s)) return true;
    if (tryAtxHeading(s) != null) return true;
    if (tryFenceOpen(s) != null) return true;
    if (tryListMarker(s) != null) return true;
    if (s.len > 0 and s[0] == '<' and detectHtmlBlockStart(s) != null) return true;
    return false;
}

/// A `:`-marked definition-list line: `:` followed by a space/tab (or
/// nothing else on the line) -- see `tryStartDefinitionList`.
fn isDefinitionMarkerLine(s: []const u8) bool {
    if (s.len == 0 or s[0] != ':') return false;
    return s.len == 1 or s[1] == ' ' or s[1] == '\t';
}

// ── GFM table row / delimiter-row parsing ────────────────────────────────

/// True if `s` contains a `|` not immediately preceded by an odd number of
/// backslashes (i.e. not itself backslash-escaped) -- the cheap pre-check
/// `tryStartTable` uses before committing to full row-splitting.
fn containsUnescapedPipe(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '|') return true;
    }
    return false;
}

/// Strip one leading `|` (if present) and one trailing, UNESCAPED `|` (if
/// present) -- the "outer" pipes of `| a | b |`-style rows, which don't
/// themselves delimit a cell.
fn stripEdgePipes(s: []const u8) []const u8 {
    var t = s;
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') {
        var backslashes: usize = 0;
        var k = t.len - 1;
        while (k > 0 and t[k - 1] == '\\') : (k -= 1) backslashes += 1;
        if (backslashes % 2 == 0) t = t[0 .. t.len - 1];
    }
    return t;
}

/// Split a table row into its cell texts, on unescaped `|` (a `\|` stays a
/// literal pipe WITHIN a cell -- decoded later, like any other backslash
/// escape, when the cell's inline content is parsed), after stripping outer
/// edge pipes and trimming each cell's surrounding whitespace. Always
/// returns at least one cell (an all-blank/edge-pipes-only row yields one
/// empty cell). Caller frees the returned slice (not its (borrowed) string
/// contents).
fn splitTableRow(allocator: Allocator, s: []const u8) Allocator.Error![][]const u8 {
    const trimmed_outer = std.mem.trim(u8, s, " \t");
    const inner = stripEdgePipes(trimmed_outer);
    var cells = std.ArrayList([]const u8).empty;
    errdefer cells.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            continue;
        }
        if (inner[i] == '|') {
            try cells.append(allocator, std.mem.trim(u8, inner[start..i], " \t"));
            start = i + 1;
        }
    }
    try cells.append(allocator, std.mem.trim(u8, inner[start..], " \t"));
    return cells.toOwnedSlice(allocator);
}

/// Parse a table DELIMITER row (`---|:--:|--:`) into one `Alignment` per
/// cell, or `null` if any cell isn't of the form `:?-+:?` (at least one
/// hyphen, optionally flanked by a `:` on either/both sides) -- i.e. `s`
/// doesn't validly delimit a table at all. Caller frees the returned slice.
fn parseDelimiterRow(allocator: Allocator, s: []const u8) Allocator.Error!?[]AST.Alignment {
    const cells = try splitTableRow(allocator, s);
    defer allocator.free(cells);
    if (cells.len == 0) return null;
    for (cells) |cell| {
        var c = cell;
        if (c.len == 0) return null;
        if (c[0] == ':') c = c[1..];
        if (c.len > 0 and c[c.len - 1] == ':') c = c[0 .. c.len - 1];
        if (c.len == 0) return null;
        for (c) |ch| {
            if (ch != '-') return null;
        }
    }
    const aligns = try allocator.alloc(AST.Alignment, cells.len);
    for (cells, 0..) |cell, i| {
        var c = cell;
        var left = false;
        var right = false;
        if (c[0] == ':') {
            left = true;
            c = c[1..];
        }
        if (c.len > 0 and c[c.len - 1] == ':') {
            right = true;
            c = c[0 .. c.len - 1];
        }
        aligns[i] = if (left and right) .center else if (left) .left else if (right) .right else .default;
    }
    return aligns;
}

// ── HTML block start detection ──────────────────────────────────────────

const html_type1_tags = [_][]const u8{ "script", "pre", "style", "textarea" };

const html_type6_tags = std.StaticStringMap(void).initComptime(.{
    .{"address"},    .{"article"},  .{"aside"},   .{"base"},     .{"basefont"},
    .{"blockquote"}, .{"body"},     .{"caption"}, .{"center"},   .{"col"},
    .{"colgroup"},   .{"dd"},       .{"details"}, .{"dialog"},   .{"dir"},
    .{"div"},        .{"dl"},       .{"dt"},      .{"fieldset"}, .{"figcaption"},
    .{"figure"},     .{"footer"},   .{"form"},    .{"frame"},    .{"frameset"},
    .{"h1"},         .{"h2"},       .{"h3"},      .{"h4"},       .{"h5"},
    .{"h6"},         .{"head"},     .{"header"},  .{"hr"},       .{"html"},
    .{"iframe"},     .{"legend"},   .{"li"},      .{"link"},     .{"main"},
    .{"menu"},       .{"menuitem"}, .{"nav"},     .{"noframes"}, .{"ol"},
    .{"optgroup"},   .{"option"},   .{"p"},       .{"param"},    .{"section"},
    .{"summary"},    .{"table"},    .{"tbody"},   .{"td"},       .{"tfoot"},
    .{"th"},         .{"thead"},    .{"title"},   .{"tr"},       .{"track"},
    .{"ul"},
});

fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

/// If `s[1..]` starts with `name` (case-insensitive), returns the index
/// just past it.
fn matchTagNameCI(s: []const u8, name: []const u8) ?usize {
    if (s.len < name.len) return null;
    for (name, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != c) return null;
    }
    return name.len;
}

fn isUnquotedValueStop(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '\'' or c == '=' or c == '<' or c == '>' or c == '`';
}

/// A minimal HTML tag grammar for HTML block type 7 (see this file's module
/// doc comment). `s[0] == '<'`; `closing` reports whether `s[1] == '/'`.
/// Returns the index just past the tag's closing `>` on success.
fn parseCompleteTag(s: []const u8, closing: bool, name_end: usize) ?usize {
    var i = name_end;
    if (closing) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i < s.len and s[i] == '>') return i + 1;
        return null;
    }
    while (true) {
        const before = i;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) i += 1;
        if (i < s.len and s[i] == '/') {
            if (i + 1 < s.len and s[i + 1] == '>') return i + 2;
            return null;
        }
        if (i < s.len and s[i] == '>') return i + 1;
        // Every attribute -- including the FIRST -- must be preceded by
        // whitespace per CommonMark's tag grammar ("Zero or more
        // attributes, each preceded by one or more spaces or tabs"); `<m:abc>`
        // has no whitespace between the tag name `m` and `:abc`, so it must
        // NOT parse as an attribute there (this used to only guard
        // subsequent attributes, via `and i > name_end`, wrongly letting a
        // whitespace-less first "attribute" through).
        if (i == before) return null;
        if (i >= s.len or !(isAsciiLetter(s[i]) or s[i] == '_' or s[i] == ':')) return null;
        while (i < s.len and (isAsciiLetterOrDigit(s[i]) or s[i] == '_' or s[i] == ':' or s[i] == '.' or s[i] == '-')) i += 1;
        var j = i;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n')) j += 1;
        if (j < s.len and s[j] == '=') {
            j += 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n')) j += 1;
            if (j >= s.len) return null;
            if (s[j] == '"') {
                const close = std.mem.indexOfScalarPos(u8, s, j + 1, '"') orelse return null;
                j = close + 1;
            } else if (s[j] == '\'') {
                const close = std.mem.indexOfScalarPos(u8, s, j + 1, '\'') orelse return null;
                j = close + 1;
            } else {
                const vstart = j;
                while (j < s.len and !isUnquotedValueStop(s[j])) j += 1;
                if (j == vstart) return null;
            }
            i = j;
        } else {
            i = j;
        }
    }
}

/// `s` is already indent-stripped (<=3 columns) and starts with `<`.
/// Returns the HTML block type (1-7) it begins, or `null`.
fn detectHtmlBlockStart(s: []const u8) ?u8 {
    if (s.len == 0 or s[0] != '<') return null;
    if (std.mem.startsWith(u8, s, "<!--")) return 2;
    if (std.mem.startsWith(u8, s, "<?")) return 3;
    if (std.mem.startsWith(u8, s, "<![CDATA[")) return 5;
    if (s.len >= 3 and s[1] == '!' and isAsciiLetter(s[2])) return 4;

    inline for (html_type1_tags) |name| {
        if (matchTagNameCI(s[1..], name)) |n| {
            const after = 1 + n;
            if (after == s.len or s[after] == ' ' or s[after] == '\t' or s[after] == '\n' or s[after] == '>') return 1;
        }
    }

    var i: usize = 1;
    var closing = false;
    if (i < s.len and s[i] == '/') {
        closing = true;
        i += 1;
    }
    const name_start = i;
    if (i >= s.len or !isAsciiLetter(s[i])) return null;
    while (i < s.len and (isAsciiLetterOrDigit(s[i]) or s[i] == '-')) i += 1;
    const name = s[name_start..i];

    var lower_buf: [32]u8 = undefined;
    if (lowerInto(&lower_buf, name)) |lname| {
        if (html_type6_tags.has(lname)) {
            if (i == s.len) return 6;
            const c = s[i];
            if (c == ' ' or c == '\t' or c == '>') return 6;
            if (c == '/' and i + 1 < s.len and s[i + 1] == '>') return 6;
            return null;
        }
    }

    if (parseCompleteTag(s, closing, i)) |end| {
        if (isBlankLine(s[end..])) return 7;
    }
    return null;
}

// ── label normalization (link reference definitions) ───────────────────

/// Simple Unicode case fold for the common bicameral scripts, applied to
/// reference labels (CommonMark matches labels under Unicode case folding, not
/// just ASCII). Like the flanking punctuation table this is a *curated* subset
/// -- ASCII, Latin-1, Latin Extended sharp-s, Greek, and Cyrillic -- covering
/// the scripts real labels use rather than the whole `CaseFolding.txt`. Most
/// folds are the +0x20 upper→lower offset; `ß`/`ẞ` fold to the two bytes "ss"
/// (a length-changing fold), so this writes straight into `out`.
fn foldCodepointInto(allocator: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
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
    const n = std.unicode.utf8Encode(folded, &buf) catch return; // unencodable: drop
    try out.appendSlice(allocator, buf[0..n]);
}

/// Trim + collapse internal whitespace runs to a single space + Unicode case
/// fold (`foldCodepointInto`). ASCII stays on a byte-wise fast path; only
/// multibyte code points are decoded and folded.
fn normalizeLabel(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
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
            try foldCodepointInto(allocator, &out, cp);
            in_ws = false;
            i = end;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── container / leaf staging types ──────────────────────────────────────

const ContainerKind = enum { document, block_quote, list, list_item, footnote_def, directive };

const Container = struct {
    kind: ContainerKind,
    children: std.ArrayList(Node.Id) = .empty,
    start_line: usize = 0,
    end_line: usize = 0,

    // .list_item / .footnote_def: the column continuation lines must be
    // indented to at least (see `matchListItem`, reused for `.footnote_def`
    // too -- see "footnote definitions" below).
    content_col: usize = 0,

    // .footnote_def: the (not-yet-normalized) label text, a borrowed slice
    // of `Parser.source` (stable for the whole parse) -- normalized into an
    // owned copy only once, in `finishFootnoteDef`, right before it becomes
    // a node's payload / a `Parser.footnotes` map key.
    footnote_label: []const u8 = "",
    /// GFM task list items (`self.options.task_lists`): this item's content
    /// began with a `[ ]`/`[x]` checkbox marker (already stripped from the
    /// content before parsing began -- see the list-marker handling in
    /// `tryStartBlocks`). `popContainer` emits `task_list_item` instead of
    /// `list_item` when set.
    is_task: bool = false,
    task_checked: bool = false,

    // .list
    ordered: bool = false,
    bullet_char: u8 = 0,
    delim: AST.OrderedListStyle.Delim = .period,
    start_num: ?u32 = null,
    tight: bool = true,
    blank_pending: bool = false,
    /// Set when ANY child item pushed this list turned out to be a task
    /// item (see `is_task` above); `popContainer` emits `task_list` instead
    /// of `bullet_list` when set (task lists are unordered-only, per the
    /// mission -- an ordered list marker is never eligible for task-item
    /// detection in the first place, so this only ever fires for a bullet
    /// list).
    any_task: bool = false,

    // .directive (container directives, `self.options.directives`): the
    // opening fence's colon count (a closing fence must be at least this
    // long), the directive name (a borrowed slice of `Parser.source`, stable
    // for the whole parse), and the parsed `{attrs}` shorthand (owned; freed
    // in `deinit`, after `popContainer` has copied it into the node).
    directive_name: []const u8 = "",
    directive_fence_len: usize = 0,
    directive_attrs: ?attrs_mod.Parsed = null,

    fn deinit(self: *Container, allocator: Allocator) void {
        self.children.deinit(allocator);
        if (self.directive_attrs) |p| p.deinit(allocator);
    }
};

const LeafKind = enum { paragraph, indented_code, fenced_code, html_block };

const Leaf = struct {
    kind: LeafKind,
    text: std.ArrayList(u8) = .empty,
    /// `.paragraph` only (see this file's module doc comment's "Inline
    /// spans" section): every mapped run appended to `text` so far, in the
    /// same order -- built alongside `text` by `openParagraph`/
    /// `appendParagraphLine` via `appendMappedSource`/`appendUnmappedByte`.
    /// Left empty (and simply ignored) for every other `LeafKind`, whose
    /// `text` never reaches `parseInline`.
    text_segs: std.ArrayList(Segment) = .empty,
    start_line: usize = 0,
    end_line: usize = 0,

    // .fenced_code / .indented_code: number of content lines appended so
    // far, INCLUDING blank ones -- `text.items.len > 0` can't distinguish
    // "no lines yet" from "one blank line so far" (both are empty), which
    // matters because a fenced/indented code block's very first content
    // line can itself be blank (see e.g. spec example 129, a fence whose
    // first line inside is blank) and the join logic (`continueFencedCode`)
    // needs to know whether to prepend a `\n` separator before this line.
    line_count: usize = 0,

    // .fenced_code
    fence_char: u8 = 0,
    fence_len: usize = 0,
    fence_col: usize = 0,
    lang: ?[]u8 = null,

    // .html_block
    html_type: u8 = 0,

    // .indented_code: trailing blank lines tentatively buffered, trimmed if
    // the block turns out to end there.
    trailing_blanks: usize = 0,

    fn deinit(self: *Leaf, allocator: Allocator) void {
        self.text.deinit(allocator);
        self.text_segs.deinit(allocator);
        if (self.lang) |l| allocator.free(l);
    }
};

/// A leaf text block (paragraph/heading) whose inline content parsing has
/// been deferred until the whole document's block structure -- and
/// therefore every link reference definition -- is known. See
/// `emitTextBlock`/`resolvePendingInline`: link reference definitions can
/// appear AFTER their first use (`[foo][bar]` followed, later in the
/// document, by `[bar]: /url`), so `parseInline` can't safely run until
/// `self.link_references` is complete, which isn't true until `parse`'s
/// line-by-line scan has finished entirely.
const PendingInline = struct {
    id: Node.Id,
    /// Owned copy of the block's assembled text: the source this was sliced
    /// from (typically a `Leaf.text` buffer) is freed as soon as its block
    /// closes, long before `resolvePendingInline` runs.
    text: []u8,
    /// Owned copy of `text`'s source mapping -- see this file's module doc
    /// comment's "Inline spans" section. Possibly empty (never `null`;
    /// `parseInline`/`Scanner.mapSpan` treat an empty slice the same as "no
    /// mapping available", so every node built from this text simply keeps
    /// its default unset `(0,0)` span).
    segments: []Segment,
};

pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    lines: []const []const u8,
    line_starts: []const usize,
    builder: Builder,
    stack: std.ArrayList(Container),
    leaf: ?Leaf = null,
    link_references: std.StringHashMapUnmanaged(Node.Id) = .empty,
    /// See `BlockResult.footnotes`'s doc comment.
    footnotes: std.StringHashMapUnmanaged(Node.Id) = .empty,
    pending_inline: std.ArrayList(PendingInline) = .empty,
    options: Options,
    /// Phase 3's multi-line block extensions (GFM tables, definition lists,
    /// frontmatter) recognize and consume SEVERAL lines at once, ahead of
    /// the normal one-line-at-a-time driver in `parse`'s `for` loop -- rather
    /// than restructure that loop to let a single `processLine` call report
    /// back "advance by N lines", each of those extensions just directly
    /// reads `self.lines[idx+1..]` for as far as its own grammar allows, then
    /// sets this to the index of the first line it DIDN'T consume.
    /// `processLine` checks this first and no-ops for any `idx` still below
    /// it, so the driving loop doesn't need to change at all.
    skip_until_line: usize = 0,
    /// The trailing mirror of `skip_until_line`: `processLine` no-ops for any
    /// `idx` at or above this. Set by `tryConsumeEndmatter` to the endmatter
    /// opener line so the body scan never sees the trailing metadata block.
    /// `maxInt` (the default) means "no endmatter" — nothing is trailing-skipped.
    stop_at_line: usize = std.math.maxInt(usize),
    /// The endmatter `metadata` node, built up-front by `tryConsumeEndmatter`
    /// but appended to the doc as its LAST child only after the body scan (so
    /// it lands after every body block). Null when there is no endmatter.
    endmatter_id: ?Node.Id = null,

    pub fn init(allocator: Allocator, source: []const u8, options: Options) Allocator.Error!Parser {
        var lines = std.ArrayList([]const u8).empty;
        errdefer lines.deinit(allocator);
        var starts = std.ArrayList(usize).empty;
        errdefer starts.deinit(allocator);

        var start: usize = 0;
        var i: usize = 0;
        while (i < source.len) {
            if (source[i] == '\n') {
                var end = i;
                if (end > start and source[end - 1] == '\r') end -= 1;
                try lines.append(allocator, source[start..end]);
                try starts.append(allocator, start);
                i += 1;
                start = i;
            } else i += 1;
        }
        if (start < source.len) {
            var end = source.len;
            if (end > start and source[end - 1] == '\r') end -= 1;
            try lines.append(allocator, source[start..end]);
            try starts.append(allocator, start);
        }

        var stack = std.ArrayList(Container).empty;
        errdefer stack.deinit(allocator);
        try stack.append(allocator, .{ .kind = .document });

        return .{
            .allocator = allocator,
            .source = source,
            .lines = try lines.toOwnedSlice(allocator),
            .line_starts = try starts.toOwnedSlice(allocator),
            .builder = Builder.init(allocator),
            .stack = stack,
            .options = options,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.line_starts);
        for (self.stack.items) |*c| c.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        if (self.leaf) |*lf| lf.deinit(self.allocator);
        // Normally empty by the time `deinit` runs -- `parse` drains this
        // via `resolvePendingInline` before returning -- but freed
        // defensively here too in case `deinit` is ever reached without a
        // completed `parse` (e.g. a future early-return error path).
        for (self.pending_inline.items) |p| {
            self.allocator.free(p.text);
            self.allocator.free(p.segments);
        }
        self.pending_inline.deinit(self.allocator);
        self.builder.deinit();
        // Keys are slices into the builder's `owned_strings` (see
        // `tryParseLinkRefDef`), not separately allocated, so — mirroring
        // djot's `Document.references` — only the map structure itself is
        // freed here; `self.builder.deinit()` above (on a failure path) or
        // the finished `AST`'s `deinit` (on success, via `Document.deinit`)
        // owns the actual bytes.
        self.link_references.deinit(self.allocator);
        // Same story as `link_references` above, one line up.
        self.footnotes.deinit(self.allocator);
    }

    pub fn parse(self: *Parser) Allocator.Error!BlockResult {
        if (self.options.frontmatter) {
            try self.tryConsumeFrontmatter();
            try self.tryConsumeEndmatter();
        }
        for (self.lines, 0..) |line, idx| {
            try self.processLine(line, idx);
        }
        // Every link reference definition has now been seen and registered
        // in `self.link_references` (they're only ever stripped off the
        // front of a closing paragraph, which the loop above and this
        // final `closeLeaf` cover) -- safe to resolve every deferred leaf
        // text block's inline content now, forward references included.
        //
        // Close the body at its last line. With endmatter present that's the
        // line just below the opener (`stop_at_line - 1`, the mandatory blank
        // separator), NOT the document's final line — otherwise a trailing
        // open container's span would stretch across the endmatter block.
        const close_idx = if (self.endmatter_id != null)
            self.stop_at_line - 1
        else if (self.lines.len == 0) 0 else self.lines.len - 1;
        try self.closeLeaf(close_idx);
        while (self.stack.items.len > 1) try self.popContainer(close_idx);
        try self.resolvePendingInline();

        // Endmatter is appended last, after every body block, so it lands as
        // the doc's final child (the root is the sole remaining stack entry).
        if (self.endmatter_id) |id| try self.appendToTop(id);

        var root = self.stack.pop().?;
        defer root.deinit(self.allocator);
        const doc_id = try self.builder.addContainer(.doc, root.children.items);
        self.builder.setSpan(doc_id, Span.init(0, self.source.len));
        setContentSpanFromChildren(&self.builder, doc_id);

        const ast = try self.builder.finish(doc_id);
        const refs = self.link_references;
        self.link_references = .empty;
        const fns = self.footnotes;
        self.footnotes = .empty;
        return .{ .ast = ast, .link_references = refs, .footnotes = fns };
    }

    /// Parse every deferred leaf text block's inline content (see
    /// `PendingInline`'s doc comment) now that `self.link_references` is
    /// complete, attaching the result as that node's children.
    fn resolvePendingInline(self: *Parser) Allocator.Error!void {
        defer {
            self.pending_inline.deinit(self.allocator);
            self.pending_inline = .empty;
        }
        // One inline scanner, reused across every pending block: `b`,
        // `link_refs` and `options` are document-constant, so only the working
        // buffers (retained) and per-block `segments` change -- avoids
        // re-allocating the scanner's five ArrayLists per block.
        var sc = inline_mod.initScanner(&self.builder, &self.link_references, self.options);
        defer sc.deinit();
        for (self.pending_inline.items) |p| {
            defer self.allocator.free(p.text);
            defer self.allocator.free(p.segments);
            const kids = try inline_mod.scanReuse(&sc, p.text, p.segments);
            defer self.allocator.free(kids);
            self.builder.setChildren(p.id, kids);
            setContentSpanFromChildren(&self.builder, p.id);
        }
    }

    // ── span helpers ─────────────────────────────────────────────────────

    fn lineStart(self: *Parser, idx: usize) usize {
        return self.line_starts[idx];
    }
    fn lineEnd(self: *Parser, idx: usize) usize {
        return self.line_starts[idx] + self.lines[idx].len;
    }

    /// Append `slice` -- a genuine BORROWED slice of `self.source` (e.g.
    /// some line's content with leading indentation/markers already
    /// stripped off the front via ordinary sub-slicing; never a copy) -- to
    /// `buf`, recording a `Segment` in `segs` that maps the newly-appended
    /// run back to its exact source position. The source offset is found
    /// via pointer arithmetic against `self.source`, which works no matter
    /// how many times `slice` was itself further sliced from some line/
    /// remainder first -- slicing narrows a slice's bounds but never moves
    /// what address its bytes live at. A no-op for an empty `slice`
    /// (nothing to map, and an empty segment would just be dead weight).
    /// See this file's module doc comment's "Inline spans" section.
    fn appendMappedSource(self: *Parser, buf: *std.ArrayList(u8), segs: *std.ArrayList(Segment), slice: []const u8) Allocator.Error!void {
        if (slice.len == 0) return;
        const buf_offset = buf.items.len;
        try buf.appendSlice(self.allocator, slice);
        const src_offset = @intFromPtr(slice.ptr) - @intFromPtr(self.source.ptr);
        try segs.append(self.allocator, .{ .buf_offset = buf_offset, .src_offset = src_offset, .len = slice.len });
    }

    /// Append one synthetic byte (e.g. the `\n` line-join separator between
    /// two joined paragraph/definition lines) to `buf` WITHOUT recording a
    /// segment: this byte has no single corresponding source position
    /// (indentation/block markers may have been stripped from the source
    /// between the two lines it joins), so any inline node whose span would
    /// need to cross it is correctly left unmapped -- see this file's
    /// module doc comment's "Inline spans" section.
    fn appendUnmappedByte(self: *Parser, buf: *std.ArrayList(u8), byte: u8) Allocator.Error!void {
        try buf.append(self.allocator, byte);
    }

    /// One `Segment` covering the whole of `slice` -- a genuine borrowed
    /// slice of `self.source` -- for the common single-line case (ATX
    /// headings, GFM table cells, most definition-list terms) where the
    /// text handed to `parseInline` is already exactly one contiguous run
    /// of source bytes, with no need for `appendMappedSource`'s fuller
    /// segment-LIST bookkeeping (which exists only to handle a
    /// potentially-multi-line, potentially-noncontiguous `Leaf.text`).
    fn singleSegment(self: *Parser, slice: []const u8) [1]Segment {
        const src_offset = if (slice.len == 0) 0 else @intFromPtr(slice.ptr) - @intFromPtr(self.source.ptr);
        return .{.{ .buf_offset = 0, .src_offset = src_offset, .len = slice.len }};
    }

    /// Re-express `segs` (offsets relative to `orig`) as segments relative
    /// to `sub`, a sub-slice of `orig` obtained via ordinary Zig slicing
    /// (`std.mem.trim`, `stripLinkReferenceDefinitions`'s prefix-consuming
    /// re-slices, ...) -- found via pointer arithmetic rather than asking
    /// every caller to track the offset explicitly, since a plain slicing
    /// operation already IS that offset, just implicitly. A segment
    /// entirely outside `sub`'s bounds is dropped; one straddling either
    /// edge is clipped to it (its `src_offset` shifted to match whatever
    /// front portion got clipped away). Caller owns the returned slice.
    fn rebaseSegments(allocator: Allocator, segs: []const Segment, orig: []const u8, sub: []const u8) Allocator.Error![]Segment {
        const k = @intFromPtr(sub.ptr) - @intFromPtr(orig.ptr);
        var out = std.ArrayList(Segment).empty;
        errdefer out.deinit(allocator);
        for (segs) |seg| {
            const seg_end = seg.buf_offset + seg.len;
            const lo = @max(seg.buf_offset, k);
            const hi = @min(seg_end, k + sub.len);
            if (lo >= hi) continue;
            const front_trim = lo - seg.buf_offset;
            try out.append(allocator, .{
                .buf_offset = lo - k,
                .src_offset = seg.src_offset + front_trim,
                .len = hi - lo,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn setContentSpanFromChildren(b: *Builder, id: Node.Id) void {
        const first = b.nodes.items[id].first_child orelse return;
        var last = first;
        while (b.nodes.items[last].next_sibling) |next| last = next;
        // A child's span may be unset (`(0,0)`, e.g. an inline node whose
        // local extent couldn't be mapped back to source -- see this file's
        // module doc comment's "Inline spans" section) -- computing a
        // content span from an unset ENDPOINT would silently fabricate a
        // wrong one (typically starting/ending at absolute offset 0), so
        // bail out and leave `id`'s own content_span unset too rather than
        // risk that. Blocks (this function's original use case, before
        // inline nodes got spans) never hit this: every block child always
        // gets a real span.
        if (isUnsetSpan(b.nodes.items[first].span) or isUnsetSpan(b.nodes.items[last].span)) return;
        b.setContentSpan(id, Span.init(b.nodes.items[first].span.start, b.nodes.items[last].span.end));
    }

    /// A container's source span must contain all its children. The `syntactic`
    /// span (from `start_line`/`end_line`) is right for a fenced container like
    /// a container directive, whose closing `:::` fence follows the last child
    /// and is tracked in `end_line`. But the LAZY containers — lists, list
    /// items, block quotes, footnote definitions — never advance `end_line`
    /// past their opening line, so their syntactic end collapses onto the first
    /// line and an `edit`/`delete` of the whole container touches only its
    /// first child. Extend the end to the last child's when it reaches further;
    /// children are always finalized before their parent is popped, so their
    /// spans are already correct (this composes bottom-up through nesting).
    /// `@max` leaves fenced containers untouched (their fence sits past the
    /// last child, so `syntactic.end` already wins).
    fn containerSpanExtended(b: *Builder, id: Node.Id, syntactic: Span) Span {
        const first = b.nodes.items[id].first_child orelse return syntactic;
        var last = first;
        while (b.nodes.items[last].next_sibling) |next| last = next;
        if (isUnsetSpan(b.nodes.items[last].span)) return syntactic;
        return Span.init(syntactic.start, @max(syntactic.end, b.nodes.items[last].span.end));
    }

    fn top(self: *Parser) *Container {
        return &self.stack.items[self.stack.items.len - 1];
    }

    fn appendToTop(self: *Parser, id: Node.Id) Allocator.Error!void {
        try self.top().children.append(self.allocator, id);
    }

    /// Called whenever genuinely new block-level content is added while some
    /// list(s) are open: resolves a pending blank line into tightness, per
    /// CommonMark's tight/loose definition (see this file's module doc
    /// comment).
    ///
    /// A blank line makes exactly ONE list loose: the deepest still-open list
    /// on the stack, i.e. the innermost list whose sibling-level the content
    /// being added joins. (A list gains a new *item* only after any deeper
    /// list has already been popped by `closeToDepth`/`maybeCloseTopList`, so
    /// the deepest list still on the stack is precisely the one the new
    /// sibling belongs to.) The earlier "mark every pending list loose"
    /// over-reached: a blank nested inside a deep item wrongly made every
    /// ancestor list loose too (spec ex307/319/320). Once resolved, all
    /// `blank_pending` flags are cleared — the blank event is consumed.
    fn markListsLoose(self: *Parser) void {
        var i = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            const c = &self.stack.items[i];
            if (c.kind == .list and c.blank_pending) {
                c.tight = false;
                break;
            }
        }
        for (self.stack.items) |*c| {
            if (c.kind == .list) c.blank_pending = false;
        }
    }

    // ── container open/close ────────────────────────────────────────────

    fn pushContainer(self: *Parser, kind: ContainerKind, line_idx: usize) Allocator.Error!void {
        try self.stack.append(self.allocator, .{ .kind = kind, .start_line = line_idx, .end_line = line_idx });
    }

    fn popContainer(self: *Parser, line_idx: usize) Allocator.Error!void {
        var c = self.stack.pop().?;
        defer c.deinit(self.allocator);
        if (c.kind == .footnote_def) {
            try self.finishFootnoteDef(&c, line_idx);
            return;
        }
        if (c.kind == .directive) {
            const id = try self.builder.addContainer(
                .{ .directive = .{ .form = .container, .name = c.directive_name } },
                c.children.items,
            );
            const syntactic = Span.init(self.lineStart(c.start_line), self.lineEnd(@min(c.end_line, line_idx)));
            self.builder.setSpan(id, containerSpanExtended(&self.builder, id, syntactic));
            setContentSpanFromChildren(&self.builder, id);
            if (c.directive_attrs) |p| try self.builder.setAttrs(id, .{ .entries = p.entries });
            try self.appendToTop(id);
            return;
        }
        const kind: Node.Kind = switch (c.kind) {
            .document => unreachable,
            .footnote_def => unreachable, // handled above
            .directive => unreachable, // handled above
            .block_quote => .block_quote,
            .list_item => if (c.is_task) .{ .task_list_item = .{ .checked = c.task_checked } } else .list_item,
            .list => if (c.ordered)
                .{ .ordered_list = .{ .style = .{ .numbering = .decimal, .delim = c.delim }, .tight = c.tight, .start = c.start_num } }
            else if (c.any_task)
                .{ .task_list = .{ .tight = c.tight } }
            else
                .{ .bullet_list = .{ .style = bulletStyle(c.bullet_char), .tight = c.tight } },
        };
        const id = try self.builder.addContainer(kind, c.children.items);
        const syntactic = Span.init(self.lineStart(c.start_line), self.lineEnd(@min(c.end_line, line_idx)));
        self.builder.setSpan(id, containerSpanExtended(&self.builder, id, syntactic));
        setContentSpanFromChildren(&self.builder, id);
        try self.appendToTop(id);
    }

    fn bulletStyle(c: u8) AST.BulletListStyle {
        return switch (c) {
            '+' => .plus,
            '*' => .star,
            else => .dash,
        };
    }

    /// Close containers from the top of the stack down to (not including)
    /// `matched_index`, finalizing the currently open leaf first (it
    /// belongs to whatever was on top before any popping).
    fn closeToDepth(self: *Parser, matched_index: usize, line_idx: usize) Allocator.Error!void {
        try self.closeLeaf(line_idx);
        while (self.stack.items.len > matched_index) try self.popContainer(line_idx);
    }

    // ── leaf open/close ──────────────────────────────────────────────────

    fn closeLeaf(self: *Parser, line_idx: usize) Allocator.Error!void {
        var lf = self.leaf orelse return;
        self.leaf = null;
        switch (lf.kind) {
            .paragraph => try self.finishParagraph(&lf),
            .indented_code => try self.finishIndentedCode(&lf),
            .fenced_code => try self.finishFencedCode(&lf),
            .html_block => try self.finishHtmlBlock(&lf),
        }
        _ = line_idx;
        lf.deinit(self.allocator);
    }

    fn finishParagraph(self: *Parser, lf: *Leaf) Allocator.Error!void {
        while (lf.text.items.len > 0 and (lf.text.items[lf.text.items.len - 1] == ' ' or lf.text.items[lf.text.items.len - 1] == '\t')) {
            lf.text.items.len -= 1;
        }
        const remaining = try self.stripLinkReferenceDefinitions(lf.text.items);
        const trimmed = std.mem.trim(u8, remaining, " \t\r\n");
        if (trimmed.len == 0) return;
        const segs = try rebaseSegments(self.allocator, lf.text_segs.items, lf.text.items, trimmed);
        defer self.allocator.free(segs);
        try self.emitTextBlock(.para, trimmed, segs, lf.start_line, lf.end_line);
    }

    /// Adds a leaf text block (paragraph/heading) node with `text` as its
    /// eventual inline content -- eventual, because parsing that content is
    /// deferred (see `PendingInline`) until the whole document's link
    /// reference definitions are known. `text` and `segs` (`text`'s source
    /// mapping -- see this file's module doc comment's "Inline spans"
    /// section) are both duped here since their backing storage (typically
    /// a soon-to-be-`deinit`'d `Leaf.text`/`.text_segs`) won't outlive this
    /// call.
    fn emitTextBlock(self: *Parser, kind: Node.Kind, text: []const u8, segs: []const Segment, start_line: usize, end_line: usize) Allocator.Error!void {
        const id = try self.addDeferredTextNode(kind, text, segs, start_line, end_line);
        try self.appendToTop(id);
    }

    /// Like `emitTextBlock`, but returns the new node's id WITHOUT attaching
    /// it to `self.top()` -- for Phase 3 constructs (GFM table cells,
    /// definition-list terms/definitions) that assemble a node's own
    /// children (table rows, a `definition_list_item`'s term + definitions)
    /// themselves via `self.builder.addContainer` before the whole thing
    /// gets appended to the currently open container in one shot, rather
    /// than each leaf attaching itself as it's created.
    fn addDeferredTextNode(self: *Parser, kind: Node.Kind, text: []const u8, segs: []const Segment, start_line: usize, end_line: usize) Allocator.Error!Node.Id {
        const id = try self.builder.addNode(kind);
        self.builder.setSpan(id, Span.init(self.lineStart(start_line), self.lineEnd(end_line)));
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_segs = try self.allocator.dupe(Segment, segs);
        errdefer self.allocator.free(owned_segs);
        try self.pending_inline.append(self.allocator, .{ .id = id, .text = owned_text, .segments = owned_segs });
        return id;
    }

    fn finishIndentedCode(self: *Parser, lf: *Leaf) Allocator.Error!void {
        // Trim the tentatively-buffered trailing blank lines: an indented
        // code block's content never includes blank lines that turned out
        // to be trailing (see `continueIndentedCode`). The trimmed text is
        // always a prefix of `lf.text`, so shorten it in place rather than
        // copying to a scratch buffer -- `addLeaf` makes the one owning copy,
        // and `lf` is deinited right after this returns.
        var text = lf.text.items;
        var n = lf.trailing_blanks;
        while (n > 0) : (n -= 1) {
            if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| {
                text = text[0..nl];
            } else {
                text = "";
            }
        }
        lf.text.items.len = text.len;
        if (lf.text.items.len > 0 and lf.text.items[lf.text.items.len - 1] != '\n') try lf.text.append(self.allocator, '\n');
        const id = try self.builder.addLeaf(.{ .code_block = .{ .lang = null, .text = lf.text.items } });
        self.builder.setSpan(id, Span.init(self.lineStart(lf.start_line), self.lineEnd(lf.end_line)));
        try self.appendToTop(id);
    }

    fn finishFencedCode(self: *Parser, lf: *Leaf) Allocator.Error!void {
        // Append the terminating newline straight onto `lf.text` (owned by the
        // soon-to-be-deinited `Leaf`); `addLeaf` copies it. No scratch buffer.
        if (lf.text.items.len > 0) try lf.text.append(self.allocator, '\n');
        const id = try self.builder.addLeaf(.{ .code_block = .{ .lang = lf.lang, .text = lf.text.items } });
        self.builder.setSpan(id, Span.init(self.lineStart(lf.start_line), self.lineEnd(lf.end_line)));
        try self.appendToTop(id);
    }

    fn finishHtmlBlock(self: *Parser, lf: *Leaf) Allocator.Error!void {
        if (lf.text.items.len > 0) try lf.text.append(self.allocator, '\n');
        const id = try self.builder.addLeaf(.{ .raw_block = .{ .format = "html", .text = lf.text.items } });
        self.builder.setSpan(id, Span.init(self.lineStart(lf.start_line), self.lineEnd(lf.end_line)));
        try self.appendToTop(id);
    }

    // ── the per-line driver ──────────────────────────────────────────────

    fn matchContainers(self: *Parser, line: []const u8) struct { matched_index: usize, cur: Cursor } {
        var cur: Cursor = .{};
        var i: usize = 1;
        while (i < self.stack.items.len) : (i += 1) {
            const c = &self.stack.items[i];
            switch (c.kind) {
                .document => unreachable,
                .list => {},
                // A container directive imposes no per-line prefix: every line
                // until its closing colon-fence is content, at whatever
                // indentation it's written (like a djot fenced div). So it
                // always "matches" and consumes nothing, exactly like `.list`.
                .directive => {},
                .block_quote => {
                    const nc = matchBlockQuote(line, cur) orelse break;
                    cur = nc;
                },
                .list_item, .footnote_def => {
                    // A footnote definition's body continues under exactly
                    // the same "indented to at least the content column, or
                    // blank" rule as a list item's own content -- see
                    // `tryStartFootnoteDef`'s doc comment.
                    const nc = matchListItem(line, cur, c.content_col) orelse break;
                    cur = nc;
                },
            }
        }
        return .{ .matched_index = i, .cur = cur };
    }

    fn matchBlockQuote(line: []const u8, cur: Cursor) ?Cursor {
        const after_indent = skipWsUpToCols(line, cur, 3);
        if (after_indent.pos >= line.len or line[after_indent.pos] != '>') return null;
        var c2: Cursor = .{ .pos = after_indent.pos + 1, .col = after_indent.col + 1 };
        // One optional space/tab after `>`, consumed as a single COLUMN. A tab
        // wider than one column is only partially consumed -- its remaining
        // columns stay as the quote's content indentation (e.g. `>\t\tfoo`
        // yields an indented code block `  foo`, spec ex6).
        if (c2.pos < line.len) {
            if (line[c2.pos] == ' ') {
                c2 = .{ .pos = c2.pos + 1, .col = c2.col + 1 };
            } else if (line[c2.pos] == '\t') {
                if (4 - (c2.col % 4) == 1) {
                    c2 = .{ .pos = c2.pos + 1, .col = c2.col + 1 };
                } else {
                    c2 = .{ .pos = c2.pos, .col = c2.col, .spent = 1 };
                }
            }
        }
        return c2;
    }

    fn matchListItem(line: []const u8, cur: Cursor, content_col: usize) ?Cursor {
        if (isBlankLine(line[cur.pos..])) return cur;
        // `content_col` is the item's continuation indent RELATIVE to its
        // parent container's content start, resolved here against THIS line's
        // parent position (`cur`). A nested block quote's prefix width can
        // differ line-to-line, so an ABSOLUTE column would match the wrong
        // amount of indentation (spec ex259/260).
        const target = cur.col + cur.spent + content_col;
        const t = skipWsToTarget(line, cur, target);
        // `col + spent` is the logical column reached (a straddled tab leaves
        // `spent` nonzero); the item continues only if it reaches `target`.
        if (t.col + t.spent < target) return null;
        return t;
    }

    fn processLine(self: *Parser, line: []const u8, idx: usize) Allocator.Error!void {
        // Already consumed by a Phase 3 multi-line construct (a GFM table,
        // definition list, or frontmatter block) started at an earlier
        // `idx` -- see `skip_until_line`'s doc comment.
        if (idx < self.skip_until_line) return;
        // Part of a trailing endmatter block -- see `stop_at_line`.
        if (idx >= self.stop_at_line) return;
        const m = self.matchContainers(line);
        const cur = m.cur;

        if (m.matched_index < self.stack.items.len) {
            const remainder0 = line[cur.pos..];
            if (!isBlankLine(remainder0) and self.leaf != null and self.leaf.?.kind == .paragraph and
                !self.canInterruptParagraph(remainder0))
            {
                try self.appendParagraphLine(remainder0, idx);
                return;
            }
            try self.closeToDepth(m.matched_index, idx);
        }

        const remainder = line[cur.pos..];
        if (isBlankLine(remainder)) {
            try self.handleBlankLine(line, cur, idx);
            return;
        }

        if (self.leaf) |*lf| {
            switch (lf.kind) {
                .fenced_code => {
                    try self.continueFencedCode(lf, line, cur, idx);
                    return;
                },
                .html_block => {
                    try self.continueHtmlBlock(lf, remainder, idx);
                    return;
                },
                .indented_code => {
                    const indent = indentCols(line, cur);
                    if (indent >= 4) {
                        try self.continueIndentedCode(lf, line, cur, idx);
                        return;
                    }
                    try self.closeLeaf(idx);
                },
                .paragraph => {
                    if (self.options.definition_lists and lf.start_line == lf.end_line) {
                        if (try self.tryStartDefinitionList(lf, line, cur, idx)) return;
                    }
                    if (trySetextUnderline(stripUpTo3Indent(remainder))) |level| {
                        // If the paragraph was entirely link reference
                        // definitions, no heading is produced and this line
                        // falls through to be parsed as fresh content.
                        if (try self.closeParagraphAsHeading(level, idx)) return;
                    }
                },
            }
        }

        if (try self.tryStartBlocks(line, cur, idx, self.leaf != null and self.leaf.?.kind == .paragraph)) return;

        if (self.leaf != null and self.leaf.?.kind == .paragraph) {
            try self.appendParagraphLine(remainder, idx);
        } else {
            try self.openParagraph(remainder, idx);
        }
    }

    /// A blank line is never *itself* fence/tag syntax, but it's still an
    /// ordinary CONTENT line for fenced code / non-6-7 HTML blocks (its
    /// whitespace, if any beyond the fence's own indentation, is preserved
    /// verbatim -- see spec example 129, a `"  "`-only line inside a fenced
    /// block) and a TENTATIVE content line for indented code (trimmed back
    /// off at close time if it turns out to be trailing -- `finishIndentedCode`).
    /// Every leaf branch below follows the same "prepend a `\n` separator
    /// only if there's already content, then append this line's own
    /// (possibly empty) text" join convention `continueFencedCode`/
    /// `continueIndentedCode` use for non-blank lines, so a blank line
    /// contributes exactly one line to the joined text either way.
    fn handleBlankLine(self: *Parser, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!void {
        const remainder = line[cur.pos..];
        // A blank line absorbed as the *interior* of an open leaf block (a
        // fenced code block, or an HTML block of type 1-5) is code/markup
        // content, not a separator between an item's blocks -- so it must NOT
        // arm `blank_pending`, or a fenced block containing blank lines would
        // spuriously make its enclosing list loose (CommonMark's tight/loose
        // rule counts only blanks *between* an item's block-level children).
        // A paragraph is closed by the blank (a real separator) and an HTML
        // 6/7 block ends on it; those, and a blank at pure container level,
        // still arm it.
        var interior_of_leaf = false;
        if (self.leaf) |*lf| {
            switch (lf.kind) {
                .paragraph => try self.closeLeaf(idx),
                .indented_code => {
                    if (lf.line_count > 0) try lf.text.append(self.allocator, '\n');
                    const stripped = skipWsUpToCols(remainder, .{}, 4);
                    try lf.text.appendSlice(self.allocator, remainder[stripped.pos..]);
                    lf.line_count += 1;
                    lf.trailing_blanks += 1;
                    lf.end_line = idx;
                },
                .fenced_code => {
                    try self.continueFencedCode(lf, line, cur, idx);
                    interior_of_leaf = true;
                },
                .html_block => {
                    if (lf.html_type == 6 or lf.html_type == 7) {
                        try self.closeLeaf(idx);
                    } else {
                        if (lf.text.items.len > 0) try lf.text.append(self.allocator, '\n');
                        try lf.text.appendSlice(self.allocator, remainder);
                        lf.end_line = idx;
                        interior_of_leaf = true;
                    }
                },
            }
        }
        if (!interior_of_leaf) {
            // "A list item can begin with at most one blank line": if the top
            // container is a list item still empty at this blank (its only
            // preceding line was the marker, whose own trailing blank is the
            // one allowed -- any real content would have produced a leaf or
            // child by now), a further blank terminates it empty, so later
            // content attaches outside it rather than being adopted (spec
            // ex280). Close it before arming, so `blank_pending` lands on the
            // enclosing list, not the defunct item.
            {
                const top_c = &self.stack.items[self.stack.items.len - 1];
                if (top_c.kind == .list_item and top_c.children.items.len == 0 and self.leaf == null) {
                    try self.popContainer(idx);
                }
            }
            // A blank scoped *inside* a block quote (or footnote definition) --
            // the deepest still-matched container, meaning this line carried
            // that container's own marker (e.g. a lone `>`) -- separates blocks
            // within it, not the items/blocks of any enclosing list, so it must
            // not arm those lists (spec ex320). A blank at the list's own level
            // fails to match the quote and closes it first (via `closeToDepth`
            // in `processLine`), leaving a list/list_item on top, so arming then
            // proceeds normally.
            const top_kind = self.stack.items[self.stack.items.len - 1].kind;
            if (top_kind != .block_quote and top_kind != .footnote_def) {
                for (self.stack.items) |*c| {
                    if (c.kind == .list) c.blank_pending = true;
                }
            }
        }
    }

    // ── paragraph accumulation ──────────────────────────────────────────

    fn openParagraph(self: *Parser, remainder: []const u8, idx: usize) Allocator.Error!void {
        // A `list`'s only valid children are `list_item`s (see the AST's
        // `bullet_list`/`ordered_list` doc comments) -- a fresh paragraph
        // can never be one directly. If a list_item just failed to match
        // (closed via `closeToDepth`) and nothing continued its parent
        // `.list` either, that dangling list must close FIRST -- before
        // `markListsLoose`, so the blank line that led here doesn't
        // retroactively mark this now-irrelevant list loose.
        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();
        var lf: Leaf = .{ .kind = .paragraph, .start_line = idx, .end_line = idx };
        try self.appendMappedSource(&lf.text, &lf.text_segs, trimLeadingWs(remainder));
        self.leaf = lf;
    }

    fn appendParagraphLine(self: *Parser, remainder: []const u8, idx: usize) Allocator.Error!void {
        var lf = &self.leaf.?;
        try self.appendUnmappedByte(&lf.text, '\n');
        try self.appendMappedSource(&lf.text, &lf.text_segs, trimLeadingWs(remainder));
        lf.end_line = idx;
    }

    /// Turn the open paragraph into a setext heading. Leading link reference
    /// definitions are NOT part of the paragraph the underline applies to, so
    /// they're stripped (and registered) first -- exactly as `finishParagraph`
    /// does. Returns `false` (having closed the leaf, its refs registered)
    /// when nothing but ref definitions remained: there is then no paragraph
    /// for the `===`/`---` line to underline, so the caller must let that line
    /// fall through and be parsed as fresh content (spec ex215/216).
    fn closeParagraphAsHeading(self: *Parser, level: u32, idx: usize) Allocator.Error!bool {
        var lf = self.leaf.?;
        self.leaf = null;
        defer lf.deinit(self.allocator);
        const remaining = try self.stripLinkReferenceDefinitions(lf.text.items);
        const trimmed = std.mem.trim(u8, remaining, " \t\r\n");
        if (trimmed.len == 0) return false;
        const segs = try rebaseSegments(self.allocator, lf.text_segs.items, lf.text.items, trimmed);
        defer self.allocator.free(segs);
        try self.emitTextBlock(.{ .heading = .{ .level = level } }, trimmed, segs, lf.start_line, idx);
        return true;
    }

    // ── indented code ────────────────────────────────────────────────────

    /// Append one indented-code content line. Starting from `cur` (which may
    /// sit mid-tab after a container prefix consumed part of a tab), strip up
    /// to 4 columns of the code block's own indentation. A tab straddling that
    /// 4-column boundary is split: its columns past the boundary survive as
    /// leading spaces of the content, and the rest of the line is appended
    /// verbatim (interior tabs are preserved, per CommonMark). Spec ex5/6/7.
    fn appendIndentedContent(self: *Parser, buf: *std.ArrayList(u8), line: []const u8, cur: Cursor) Allocator.Error!void {
        var col = cur.col;
        var i = cur.pos;
        var spent = cur.spent;
        var consumed: usize = 0;
        while (i < line.len and consumed < 4) {
            const c = line[i];
            if (c == ' ') {
                col += 1;
                i += 1;
                consumed += 1;
                spent = 0;
            } else if (c == '\t') {
                const avail = (4 - (col % 4)) - spent;
                if (consumed + avail <= 4) {
                    consumed += avail;
                    col += 4 - (col % 4);
                    i += 1;
                    spent = 0;
                } else {
                    const leftover = avail - (4 - consumed);
                    var k: usize = 0;
                    while (k < leftover) : (k += 1) try buf.append(self.allocator, ' ');
                    i += 1; // consume the straddled tab byte
                    try buf.appendSlice(self.allocator, line[i..]);
                    return;
                }
            } else break;
        }
        try buf.appendSlice(self.allocator, line[i..]);
    }

    fn continueIndentedCode(self: *Parser, lf: *Leaf, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!void {
        if (lf.line_count > 0) try lf.text.append(self.allocator, '\n');
        try self.appendIndentedContent(&lf.text, line, cur);
        lf.line_count += 1;
        lf.trailing_blanks = 0;
        lf.end_line = idx;
    }

    // ── fenced code ──────────────────────────────────────────────────────

    fn continueFencedCode(self: *Parser, lf: *Leaf, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!void {
        const remainder = line[cur.pos..];
        if (indentCols(remainder, .{}) < 4 and isFenceClose(stripUpTo3Indent(remainder), lf.fence_char, lf.fence_len)) {
            // The closing fence is part of the block's source span (though not
            // its `text`), so advance `end_line` to it before closing —
            // otherwise the node's span stops at the last content line and an
            // `edit`/`delete` orphans the closing fence. An unterminated fence
            // (EOF, no close line) never reaches here, so its span correctly
            // ends at the last content line.
            lf.end_line = idx;
            try self.closeLeaf(idx);
            return;
        }
        if (lf.line_count > 0) try lf.text.append(self.allocator, '\n');
        const strip_cols = if (lf.fence_col > cur.col) lf.fence_col - cur.col else 0;
        const stripped = skipWsUpToCols(line, cur, strip_cols);
        try lf.text.appendSlice(self.allocator, line[stripped.pos..]);
        lf.line_count += 1;
        lf.end_line = idx;
    }

    // ── html block ───────────────────────────────────────────────────────

    fn continueHtmlBlock(self: *Parser, lf: *Leaf, remainder: []const u8, idx: usize) Allocator.Error!void {
        if (lf.text.items.len > 0) try lf.text.append(self.allocator, '\n');
        try lf.text.appendSlice(self.allocator, remainder);
        lf.end_line = idx;
        const ends = switch (lf.html_type) {
            1 => containsAnyCI(remainder, &.{ "</script>", "</pre>", "</style>", "</textarea>" }),
            2 => std.mem.indexOf(u8, remainder, "-->") != null,
            3 => std.mem.indexOf(u8, remainder, "?>") != null,
            4 => std.mem.indexOfScalar(u8, remainder, '>') != null,
            5 => std.mem.indexOf(u8, remainder, "]]>") != null,
            else => false, // 6/7 only end at a blank line, handled in handleBlankLine
        };
        if (ends) try self.closeLeaf(idx);
    }

    fn containsAnyCI(haystack: []const u8, needles: []const []const u8) bool {
        var buf: [4096]u8 = undefined;
        const n = @min(haystack.len, buf.len);
        for (haystack[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];
        for (needles) |needle| {
            if (std.mem.indexOf(u8, lower, needle) != null) return true;
        }
        return false;
    }

    // ── new block start scanning ────────────────────────────────────────

    /// Pure (non-mutating) check: would `remainder` (a lazily-continued
    /// line, i.e. one that failed to match one or more ancestor containers)
    /// start a block allowed to interrupt an open paragraph? If so, the
    /// caller should NOT treat this as a lazy continuation line.
    fn canInterruptParagraph(self: *Parser, remainder: []const u8) bool {
        const indent = indentCols(remainder, .{});
        if (indent >= 4) return false;
        const s = stripUpTo3Indent(remainder);
        if (s.len > 0 and s[0] == '>') return true;
        if (self.options.directives and self.looksLikeDirective(s)) return true;
        if (isThematicBreak(s)) return true;
        if (tryAtxHeading(s) != null) return true;
        if (tryFenceOpen(s) != null) return true;
        if (tryListMarker(s)) |mk| {
            const after = s[mk.marker_len..];
            if (self.isInsideListItem()) return true;
            if (!isBlankLine(after) and (!mk.ordered or mk.start.? == 1)) return true;
        }
        // See `isInsideFootnoteDef`'s doc comment: a fresh `[^label]:` marker
        // ends an already-open footnote definition's own trailing paragraph
        // (so back-to-back definitions with no blank line between them, e.g.
        // "[^a]: x\n[^b]: y\n", each get their own `footnote` node) -- but,
        // mirroring `tryStartTable`'s documented restriction, a footnote
        // definition still never interrupts an ORDINARY paragraph outside
        // that context (`tryStartFootnoteDef`'s own `!interrupting` gate).
        if (self.options.footnotes and self.isInsideFootnoteDef() and tryFootnoteDefMarker(s) != null) return true;
        if (s.len > 0 and s[0] == '<') {
            if (detectHtmlBlockStart(s)) |t| {
                if (t != 7) return true;
            }
        }
        return false;
    }

    // ── generic directives (`self.options.directives`) ──────────────────

    /// Leading `:` run length of `s`.
    fn countColons(s: []const u8) usize {
        var n: usize = 0;
        while (n < s.len and s[n] == ':') n += 1;
        return n;
    }

    /// Pure predicate for `canInterruptParagraph`: does `s` (indent already
    /// stripped) begin a container opening/closing fence or a leaf directive?
    fn looksLikeDirective(self: *Parser, s: []const u8) bool {
        const n = countColons(s);
        if (n >= 3) {
            if (isBlankLine(s[n..])) return self.innermostDirectiveIndex(n) != null; // close
            return attrs_mod.scanName(s, n) != null; // open
        }
        if (n == 2) return attrs_mod.scanName(s, 2) != null; // leaf
        return false;
    }

    /// Index (on `self.stack`) of the innermost open container directive that
    /// a closing fence of `close_len` colons would close — i.e. the topmost
    /// `.directive` whose own opening fence is no longer than `close_len`.
    /// `null` if there is none (the fence is then just content).
    fn innermostDirectiveIndex(self: *Parser, close_len: usize) ?usize {
        var i = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            const c = &self.stack.items[i];
            if (c.kind == .directive) {
                return if (c.directive_fence_len <= close_len) i else null;
            }
        }
        return null;
    }

    const DirectiveOpen = struct { name: []const u8, attrs: ?attrs_mod.Parsed };

    /// Parse a container directive opening fence: `n` colons already counted,
    /// a name directly after them, an optional (ignored) `[label]`, an
    /// optional `{attrs}`, then nothing but whitespace. `null` if malformed.
    fn parseDirectiveOpen(self: *Parser, s: []const u8, n: usize) Allocator.Error!?DirectiveOpen {
        const name_end = attrs_mod.scanName(s, n) orelse return null;
        const name = s[n..name_end];
        var i = name_end;
        // A container directive's `[label]` isn't represented (its children
        // are blocks, not inline) — consume and drop it if present.
        if (i < s.len and s[i] == '[') {
            if (inline_mod.scanBracketLabel(s, i)) |raw| i = raw.end;
        }
        var attrs: ?attrs_mod.Parsed = null;
        if (i < s.len and s[i] == '{') {
            if (try attrs_mod.parse(self.allocator, s, i)) |p| {
                attrs = p;
                i = p.end;
            }
        }
        if (!isBlankLine(s[i..])) {
            if (attrs) |p| p.deinit(self.allocator);
            return null;
        }
        return .{ .name = name, .attrs = attrs };
    }

    /// Handle a leaf directive line `::name[label]{attrs}` (exactly two
    /// colons). Emits the node (its `[label]` deferred to inline resolution)
    /// and returns true, or returns false if `s` isn't a valid leaf directive.
    fn parseLeafDirective(self: *Parser, s: []const u8, idx: usize, interrupting: bool) Allocator.Error!bool {
        const name_end = attrs_mod.scanName(s, 2) orelse return false;
        const name = s[2..name_end];
        var i = name_end;
        var label: ?[]const u8 = null;
        if (i < s.len and s[i] == '[') {
            if (inline_mod.scanBracketLabel(s, i)) |raw| {
                label = raw.content;
                i = raw.end;
            }
        }
        var attrs: ?attrs_mod.Parsed = null;
        if (i < s.len and s[i] == '{') {
            if (try attrs_mod.parse(self.allocator, s, i)) |p| {
                attrs = p;
                i = p.end;
            }
        }
        if (!isBlankLine(s[i..])) {
            if (attrs) |p| p.deinit(self.allocator);
            return false;
        }
        defer if (attrs) |p| p.deinit(self.allocator);

        if (interrupting) try self.closeLeaf(idx);
        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();

        const kind: Node.Kind = .{ .directive = .{ .form = .leaf, .name = name } };
        const id = if (label) |lab| blk: {
            const seg = self.singleSegment(lab);
            break :blk try self.addDeferredTextNode(kind, lab, &seg, idx, idx);
        } else blk: {
            const nid = try self.builder.addNode(kind);
            self.builder.setSpan(nid, Span.init(self.lineStart(idx), self.lineEnd(idx)));
            break :blk nid;
        };
        if (attrs) |p| try self.builder.setAttrs(id, .{ .entries = p.entries });
        try self.appendToTop(id);
        return true;
    }

    /// Dispatch the three directive forms for a line whose indent is already
    /// stripped into `s`. Returns true if it consumed the line.
    fn tryStartDirective(self: *Parser, s: []const u8, idx: usize, interrupting: bool) Allocator.Error!bool {
        const n = countColons(s);
        if (n < 2) return false;

        if (n >= 3) {
            // Closing fence: colons only.
            if (isBlankLine(s[n..])) {
                const d_idx = self.innermostDirectiveIndex(n) orelse return false;
                self.stack.items[d_idx].end_line = idx;
                try self.closeToDepth(d_idx, idx);
                return true;
            }
            // Opening container fence.
            if (try self.parseDirectiveOpen(s, n)) |open| {
                // Until ownership of `open.attrs` transfers to the container
                // below, free it on any error path.
                errdefer if (open.attrs) |p| p.deinit(self.allocator);
                if (interrupting) try self.closeLeaf(idx);
                try self.maybeCloseTopList(idx, null);
                self.markListsLoose();
                try self.pushContainer(.directive, idx);
                const c = self.top();
                c.directive_name = open.name;
                c.directive_fence_len = n;
                c.directive_attrs = open.attrs;
                return true;
            }
            return false;
        }

        // n == 2: leaf directive.
        return self.parseLeafDirective(s, idx, interrupting);
    }

    /// Attempt to recognize and consume one or more new block starts
    /// beginning at `cur` in `line` (container starts loop — a block quote
    /// or list item can directly contain another block start on the same
    /// line — before finally trying a leaf-block start). Returns `true` if
    /// anything was started (in which case the line has been fully
    /// handled), `false` if `remainder` matches no known block start (the
    /// caller falls back to paragraph continuation/creation).
    fn tryStartBlocks(self: *Parser, line: []const u8, cur_in: Cursor, idx: usize, interrupting_paragraph: bool) Allocator.Error!bool {
        var cur = cur_in;
        var interrupting = interrupting_paragraph;
        // Once a container (block quote / list item) has been pushed, this
        // line is "handled" even if nothing deeper matches on the
        // remainder — the remaining text becomes a fresh paragraph INSIDE
        // the newly pushed container(s), using the up-to-date `cur`, not
        // the pre-push position the caller knows about. Returning `false`
        // after already mutating the stack would make the caller retry
        // with stale state (see this function's tests / the module doc
        // comment's "List items"/"Block quotes" sections in
        // `conformance.zig` output for what that bug looked like).
        var pushed_any = false;
        while (true) {
            const remainder = line[cur.pos..];
            const indent = indentCols(line, cur);

            if (indent < 4) {
                const s = stripUpTo3Indent(remainder);
                const indent_bytes = remainder.len - s.len;

                // Generic directives (`self.options.directives`): a container
                // opening/closing colon-fence or a leaf directive, all led by
                // colons — which no other CommonMark block start uses, so this
                // can go first without shadowing anything. Consumes the whole
                // line when it matches.
                if (self.options.directives) {
                    if (try self.tryStartDirective(s, idx, interrupting)) return true;
                }

                if (s.len > 0 and s[0] == '>') {
                    if (interrupting) try self.closeLeaf(idx);
                    self.markListsLoose();
                    try self.pushContainer(.block_quote, idx);
                    cur = matchBlockQuote(line, cur).?;
                    interrupting = false;
                    pushed_any = true;
                    continue;
                }

                // Thematic break takes precedence over a same-character
                // list-marker reading (e.g. "- - -").
                if (isThematicBreak(s)) {
                    if (interrupting) try self.closeLeaf(idx);
                    try self.maybeCloseTopList(idx, null);
                    self.markListsLoose();
                    const id = try self.builder.addLeaf(.thematic_break);
                    self.builder.setSpan(id, Span.init(self.lineStart(idx), self.lineEnd(idx)));
                    try self.appendToTop(id);
                    return true;
                }

                if (tryAtxHeading(s)) |h| {
                    if (interrupting) try self.closeLeaf(idx);
                    try self.maybeCloseTopList(idx, null);
                    self.markListsLoose();
                    // A single-line construct (`s`, hence `h.content`, is
                    // this one `line`'s own content) -- `singleSegment`
                    // maps the whole trimmed text directly, no
                    // `Leaf`/segment-list bookkeeping needed.
                    const heading_text = std.mem.trim(u8, h.content, " \t");
                    const seg = self.singleSegment(heading_text);
                    try self.emitTextBlock(.{ .heading = .{ .level = h.level } }, heading_text, &seg, idx, idx);
                    return true;
                }

                if (tryFenceOpen(s)) |f| {
                    if (interrupting) try self.closeLeaf(idx);
                    try self.maybeCloseTopList(idx, null);
                    self.markListsLoose();
                    var lf: Leaf = .{
                        .kind = .fenced_code,
                        .start_line = idx,
                        .end_line = idx,
                        .fence_char = f.char,
                        .fence_len = f.len,
                        .fence_col = cur.col + indent_bytes,
                    };
                    if (f.info.len > 0) {
                        const decoded = try inline_mod.decodeText(self.allocator, f.info);
                        defer self.allocator.free(decoded);
                        var word_end: usize = 0;
                        while (word_end < decoded.len and decoded[word_end] != ' ' and decoded[word_end] != '\t') word_end += 1;
                        lf.lang = try self.allocator.dupe(u8, decoded[0..word_end]);
                    }
                    self.leaf = lf;
                    return true;
                }

                if (tryListMarker(s)) |mk| {
                    const after = s[mk.marker_len..];
                    const item_blank = isBlankLine(after);
                    const eligible = !interrupting or self.isInsideListItem() or (!item_blank and (!mk.ordered or mk.start.? == 1));
                    if (eligible) {
                        if (interrupting) try self.closeLeaf(idx);
                        const reuse = self.topIsCompatibleList(mk);
                        if (!reuse) {
                            try self.maybeCloseTopList(idx, mk);
                            self.markListsLoose();
                            try self.pushContainer(.list, idx);
                            var lc = self.top();
                            lc.ordered = mk.ordered;
                            lc.bullet_char = mk.bullet_char;
                            lc.delim = mk.delim;
                            lc.start_num = mk.start;
                            lc.tight = true;
                        } else {
                            self.markListsLoose();
                        }
                        const marker_col = cur.col + indent_bytes;
                        const after_marker_col = marker_col + mk.marker_len;
                        var content_col: usize = undefined;
                        if (item_blank) {
                            content_col = after_marker_col + 1;
                        } else {
                            const spaces = indentCols(after, .{ .pos = 0, .col = after_marker_col });
                            content_col = if (spaces >= 1 and spaces <= 4) after_marker_col + spaces else after_marker_col + 1;
                        }
                        try self.pushContainer(.list_item, idx);
                        // Store the continuation indent RELATIVE to the parent
                        // content start (`cur.col + cur.spent` here), not the
                        // absolute column -- see `matchListItem`.
                        self.top().content_col = content_col -| (cur.col + cur.spent);
                        const after_marker_cursor: Cursor = .{ .pos = cur.pos + indent_bytes + mk.marker_len, .col = after_marker_col };
                        cur = skipWsToTarget(line, after_marker_cursor, content_col);
                        // GFM task list items (`self.options.task_lists`,
                        // shadowing core bullet-list-item parsing per the
                        // mission): only tried for a bullet item (never
                        // ordered) whose content begins with a `[ ]`/`[x]`
                        // checkbox marker -- see `tryTaskListMarker`. The
                        // marker text itself is consumed here (advancing
                        // `cur` past it) so it never reaches inline parsing;
                        // the enclosing `.list` is flagged `any_task` so
                        // `popContainer` promotes it to `task_list`.
                        if (self.options.task_lists and !mk.ordered) {
                            if (tryTaskListMarker(line[cur.pos..])) |tm| {
                                self.top().is_task = true;
                                self.top().task_checked = tm.checked;
                                if (self.stack.items.len >= 2) {
                                    self.stack.items[self.stack.items.len - 2].any_task = true;
                                }
                                const consumed = line[cur.pos..].len - tm.rest.len;
                                cur = .{ .pos = cur.pos + consumed, .col = cur.col + consumed };
                            }
                        }
                        interrupting = false;
                        pushed_any = true;
                        continue;
                    }
                }

                if (self.options.tables and !interrupting) {
                    if (try self.tryStartTable(line, cur, idx)) return true;
                }

                if (self.options.footnotes and !interrupting) {
                    if (try self.tryStartFootnoteDef(line, cur, idx)) return true;
                }

                if (s.len > 0 and s[0] == '<') {
                    if (detectHtmlBlockStart(s)) |t| {
                        if (!interrupting or t != 7) {
                            if (interrupting) try self.closeLeaf(idx);
                            try self.maybeCloseTopList(idx, null);
                            self.markListsLoose();
                            var lf: Leaf = .{ .kind = .html_block, .start_line = idx, .end_line = idx, .html_type = t };
                            try lf.text.appendSlice(self.allocator, remainder);
                            self.leaf = lf;
                            const ends = switch (t) {
                                1 => containsAnyCI(remainder, &.{ "</script>", "</pre>", "</style>", "</textarea>" }),
                                2 => std.mem.indexOf(u8, remainder, "-->") != null,
                                3 => std.mem.indexOf(u8, remainder, "?>") != null,
                                4 => std.mem.indexOfScalar(u8, remainder, '>') != null,
                                5 => std.mem.indexOf(u8, remainder, "]]>") != null,
                                else => false,
                            };
                            if (ends) try self.closeLeaf(idx);
                            return true;
                        }
                    }
                }
            } else if (!interrupting) {
                // Indented code (indent >= 4) can never interrupt a
                // paragraph, and is only a *start* (continuing an already-
                // open one is handled before `tryStartBlocks` is called).
                try self.maybeCloseTopList(idx, null);
                var lf: Leaf = .{ .kind = .indented_code, .start_line = idx, .end_line = idx, .line_count = 1 };
                try self.appendIndentedContent(&lf.text, line, cur);
                self.markListsLoose();
                self.leaf = lf;
                return true;
            }

            if (!pushed_any) return false;
            // A container (or more than one) was pushed this line, but its
            // remaining text starts no further block itself: that
            // remainder becomes the first line of a fresh paragraph inside
            // whatever was just pushed (or nothing, if it's blank -- e.g.
            // a bare "> " or list marker with nothing after it).
            const final_remainder = line[cur.pos..];
            if (!isBlankLine(final_remainder)) try self.openParagraph(final_remainder, idx);
            return true;
        }
    }

    /// After popping a mismatched list_item (in `closeToDepth`), the parent
    /// `.list` is still open. A `list`'s only valid children are
    /// `list_item`s, so if the upcoming content at this depth is anything
    /// other than a compatible list marker (a new item of the SAME list),
    /// the list itself must close before that content is processed — see
    /// this file's module doc comment section on tight/loose and the
    /// `topIsCompatibleList` companion. Idempotent (a no-op when the top
    /// isn't a `.list`), so call sites don't need to check first.
    fn maybeCloseTopList(self: *Parser, idx: usize, mk: ?ListMarker) Allocator.Error!void {
        if (self.top().kind != .list) return;
        if (mk) |m| if (self.topIsCompatibleList(m)) return;
        try self.popContainer(idx);
    }

    fn listCompatible(c: *const Container, mk: ListMarker) bool {
        if (c.kind != .list) return false;
        if (c.ordered != mk.ordered) return false;
        if (mk.ordered) return c.delim == mk.delim;
        return c.bullet_char == mk.bullet_char;
    }

    fn topIsCompatibleList(self: *Parser, mk: ListMarker) bool {
        return listCompatible(self.top(), mk);
    }

    /// True when the currently open leaf's own container is a `.list_item`
    /// -- i.e. we are already somewhere inside a list, as opposed to a
    /// bare top-level (or block-quote-level, etc.) paragraph with no list
    /// context at all. Used by `canInterruptParagraph`: CommonMark's "an
    /// empty list item / an ordered list not starting at 1 can't interrupt
    /// a paragraph" restriction exists only to stop a bare paragraph from
    /// spuriously turning into a list (see the spec's "hard-wrapped
    /// numerals" rationale); it does NOT apply once we're already inside a
    /// list item, where "changing the bullet or ordered list delimiter
    /// starts a new list" applies UNCONDITIONALLY instead (spec examples
    /// 283 and 301-302: `1. foo / 2. / 3. bar` keeps an empty item 2, and
    /// `1. foo / 2. bar / 3) baz` starts a whole new `<ol>` at item 3,
    /// despite neither satisfying the "non-empty"/"starts at 1" gate).
    fn isInsideListItem(self: *Parser) bool {
        return self.top().kind == .list_item;
    }

    /// The footnote-definition analog of `isInsideListItem`, used the same
    /// way by `canInterruptParagraph`: a bare `[^b]:` line right after
    /// `[^a]:`'s own paragraph, with NO blank line between them, must end
    /// `[^a]`'s definition and start `[^b]`'s -- otherwise `[^b]: ...` would
    /// be swallowed as a lazy-continuation line of `[^a]`'s open paragraph
    /// (see `canInterruptParagraph`'s doc comment on this general class of
    /// mismatched-container question). Only fires when a `.footnote_def` is
    /// the CURRENT (innermost) open container, mirroring
    /// `isInsideListItem`'s own scope.
    fn isInsideFootnoteDef(self: *Parser) bool {
        return self.top().kind == .footnote_def;
    }

    // ── Phase 3: frontmatter ─────────────────────────────────────────────

    /// A leading `---`/`+++` frontmatter block (`self.options.frontmatter`):
    /// only ever tried ONCE, before the main line-by-line scan even starts
    /// (see `parse`), since frontmatter is defined as a leading construct —
    /// unlike every other Phase 3 extension, it never competes with
    /// mid-document block starts. `self.lines[0]` must be EXACTLY `---` (a
    /// YAML block) or `+++` (a TOML block), ignoring only trailing
    /// whitespace; the block ends at the first later line that's exactly
    /// the SAME delimiter. If no such closing line exists, this is NOT
    /// frontmatter at all (falls through to ordinary parsing — a bare
    /// leading `---` with no closer is just a thematic break, same as with
    /// the flag off). On success, the whole block becomes a single inert
    /// `metadata{lang,text}` node (see `document-metadata.md`): it never
    /// renders into the HTML body — the printer projects it to a
    /// `<script type=…>` data island — while staying fully inspectable via
    /// `-o ast`. See `tryConsumeEndmatter` for the trailing counterpart.
    fn tryConsumeFrontmatter(self: *Parser) Allocator.Error!void {
        if (self.lines.len == 0) return;
        const first = std.mem.trimEnd(u8, self.lines[0], " \t");
        const delim: []const u8 = if (std.mem.startsWith(u8, first, "---"))
            "---"
        else if (std.mem.startsWith(u8, first, "+++"))
            "+++"
        else
            return;

        // Optional language tag after the delimiter, fenced-code-block style
        // (`---fig`). A bare fence defaults by delimiter (`---` = yaml, `+++`
        // = toml). A non-empty remainder that ISN'T a valid language token
        // means this isn't frontmatter at all — `----` stays a thematic break.
        const rest = std.mem.trim(u8, first[3..], " \t");
        const lang: []const u8 = if (rest.len == 0)
            (if (delim[0] == '-') "yaml" else "toml")
        else if (isLangTag(rest))
            rest // stored exactly as written; MIME is derived as application/<lang>
        else
            return;

        var i: usize = 1;
        while (i < self.lines.len) : (i += 1) {
            // The closer is the bare delimiter run, tag-free (like a closing
            // code fence), so `---fig` … `---`.
            const line = std.mem.trimEnd(u8, self.lines[i], " \t");
            if (!std.mem.eql(u8, line, delim)) continue;

            var text = std.ArrayList(u8).empty;
            defer text.deinit(self.allocator);
            for (self.lines[1..i]) |content_line| {
                try text.appendSlice(self.allocator, content_line);
                try text.append(self.allocator, '\n');
            }
            const id = try self.builder.addLeaf(.{ .metadata = .{ .lang = lang, .text = text.items } });
            self.builder.setSpan(id, Span.init(self.lineStart(0), self.lineEnd(i)));
            try self.appendToTop(id);
            self.skip_until_line = i + 1;
            return;
        }
        // No closing delimiter anywhere in the document: not frontmatter.
    }

    /// A trailing `---<lang>` … `---` endmatter block (the back-of-book
    /// counterpart to frontmatter; see `document-metadata.md`). Tried ONCE
    /// after `tryConsumeFrontmatter`, before the main scan. Unlike frontmatter,
    /// endmatter MUST carry an explicit language tag: a bare `---` away from
    /// the top is a CommonMark thematic break (and after a paragraph, a setext
    /// underline), so only a tagged `---<lang>` opener is unambiguous. It must
    /// also be separated from the body by a blank line — that blank both reads
    /// naturally and lets the body scan close cleanly at it, so the trailing
    /// block never tangles with an open paragraph/list. The node is built here
    /// but appended by `parse` as the doc's LAST child. Recognition rules:
    ///   - the last non-blank line is exactly `---` (the closer);
    ///   - scanning up from it, the nearest `---<lang>` line is the opener;
    ///   - the line just above the opener is blank, and sits at or after the
    ///     frontmatter boundary (`skip_until_line`) so the two never overlap.
    /// Any of these failing means "no endmatter" — the tail parses normally.
    fn tryConsumeEndmatter(self: *Parser) Allocator.Error!void {
        if (self.lines.len == 0) return;

        // The closer: the last non-blank line, which must be a bare `---`.
        var last = self.lines.len;
        while (last > 0) : (last -= 1) {
            if (!isBlankLine(self.lines[last - 1])) break;
        }
        if (last == 0) return; // all blank
        last -= 1;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, self.lines[last], " \t"), "---")) return;
        if (last < self.skip_until_line + 2) return; // no room for opener+blank+closer

        // The opener: the nearest tagged `---<lang>` line above the closer,
        // not scanning into consumed frontmatter.
        var open = last;
        const lo = self.skip_until_line;
        while (open > lo) {
            open -= 1;
            const t = std.mem.trimEnd(u8, self.lines[open], " \t");
            if (!std.mem.startsWith(u8, t, "---")) continue;
            const rest = std.mem.trim(u8, t[3..], " \t");
            if (!isLangTag(rest)) continue;
            // Found a tagged opener. It's endmatter only if the separator
            // blank sits above it (and after any frontmatter).
            if (open == 0 or open - 1 < self.skip_until_line) return;
            if (!isBlankLine(self.lines[open - 1])) return;

            var text = std.ArrayList(u8).empty;
            defer text.deinit(self.allocator);
            for (self.lines[open + 1 .. last]) |content_line| {
                try text.appendSlice(self.allocator, content_line);
                try text.append(self.allocator, '\n');
            }
            const id = try self.builder.addLeaf(.{ .metadata = .{ .lang = rest, .text = text.items } });
            self.builder.setSpan(id, Span.init(self.lineStart(open), self.lineEnd(last)));
            self.endmatter_id = id;
            self.stop_at_line = open;
            return;
        }
        // No tagged opener above the closer: not endmatter.
    }

    // ── Phase 3: GFM tables ──────────────────────────────────────────────

    /// GFM pipe tables (`self.options.tables`). APPROXIMATIONS, documented:
    ///   - A table never interrupts an already-open paragraph (checked via
    ///     the caller's `!interrupting` gate) -- unlike CommonMark's other
    ///     block starts. Most real-world tables are preceded by a blank
    ///     line anyway; this keeps the "does this line start a table"
    ///     question fully local to a genuine fresh-block position instead
    ///     of needing paragraph-reinterpretation machinery.
    ///   - A header row is any non-blank, <=3-space-indented line containing
    ///     an unescaped `|` (`containsUnescapedPipe`), immediately followed
    ///     by a valid delimiter row (`parseDelimiterRow`: cells of the form
    ///     `:?-+:?`) with the exact SAME cell count.
    ///   - Body rows continue for as long as subsequent lines (i) still
    ///     match every currently open ancestor container (so a table nested
    ///     in a block quote/list item stays properly scoped), (ii) are
    ///     non-blank and not indented code, and (iii) don't themselves look
    ///     like the start of some other block construct
    ///     (`looksLikeNewBlockStart`). Per the GFM spec, ragged rows are
    ///     padded (missing cells) or truncated (extra cells) to the header's
    ///     column count rather than ending the table.
    ///   - `|` inside a backtick code span is NOT treated specially (unlike
    ///     real GFM); only a backslash-escaped `\|` is recognized as a
    ///     non-splitting pipe. A cell containing `` `a|b` `` therefore
    ///     splits where a strict implementation wouldn't.
    fn tryStartTable(self: *Parser, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!bool {
        const remainder = line[cur.pos..];
        const s = stripUpTo3Indent(remainder);
        if (isBlankLine(s)) return false;
        if (!containsUnescapedPipe(s)) return false;
        if (idx + 1 >= self.lines.len) return false;

        const next_line = self.lines[idx + 1];
        const nm = self.matchContainers(next_line);
        if (nm.matched_index != self.stack.items.len) return false;
        const next_remainder = next_line[nm.cur.pos..];
        if (indentCols(next_remainder, .{}) >= 4) return false;
        const next_s = stripUpTo3Indent(next_remainder);

        const header_cells = try splitTableRow(self.allocator, s);
        defer self.allocator.free(header_cells);
        if (header_cells.len == 0) return false;

        const aligns = (try parseDelimiterRow(self.allocator, next_s)) orelse return false;
        defer self.allocator.free(aligns);
        if (aligns.len != header_cells.len) return false;

        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();

        var row_ids = std.ArrayList(Node.Id).empty;
        defer row_ids.deinit(self.allocator);

        const header_row_id = try self.buildTableRow(header_cells, aligns, true, idx, idx);
        try row_ids.append(self.allocator, header_row_id);

        var last_idx = idx + 1;
        var scan = idx + 2;
        while (scan < self.lines.len) {
            const row_line = self.lines[scan];
            const rm = self.matchContainers(row_line);
            if (rm.matched_index != self.stack.items.len) break;
            const row_remainder = row_line[rm.cur.pos..];
            if (isBlankLine(row_remainder)) break;
            if (indentCols(row_remainder, .{}) >= 4) break;
            const row_s = stripUpTo3Indent(row_remainder);
            if (looksLikeNewBlockStart(row_s)) break;

            const raw_cells = try splitTableRow(self.allocator, row_s);
            defer self.allocator.free(raw_cells);
            const row_id = try self.buildTableRow(raw_cells, aligns, false, scan, scan);
            try row_ids.append(self.allocator, row_id);
            last_idx = scan;
            scan += 1;
        }

        const caption_id = try self.builder.addContainer(.caption, &.{});
        var all_children = std.ArrayList(Node.Id).empty;
        defer all_children.deinit(self.allocator);
        try all_children.append(self.allocator, caption_id);
        try all_children.appendSlice(self.allocator, row_ids.items);

        const table_id = try self.builder.addContainer(.table, all_children.items);
        self.builder.setSpan(table_id, Span.init(self.lineStart(idx), self.lineEnd(last_idx)));
        setContentSpanFromChildren(&self.builder, table_id);
        try self.appendToTop(table_id);

        self.skip_until_line = last_idx + 1;
        return true;
    }

    /// GFM: a `\|` inside a table cell is an ESCAPED pipe — it doesn't split
    /// the row (`splitTableRow` already skips over it) and it must reach
    /// inline parsing as a bare `|`. The ordinary inline backslash-escape
    /// path can't do this job, because it doesn't run inside every inline
    /// construct: `` `\|` `` would come out as `<code>\|</code>` where GFM
    /// wants `<code>|</code>` (the spec's own Tables example), since a code
    /// span's content is verbatim. So the unescape happens HERE, rewriting
    /// the cell's text up front — which is what cmark-gfm does too.
    ///
    /// The rewritten text is no longer a contiguous slice of `self.source`,
    /// so this also builds the `Segment` LIST mapping it back: one segment
    /// per run between dropped backslashes, leaving spans (and therefore
    /// `edit`) accurate across the rewrite. Appends to caller-owned scratch;
    /// `addDeferredTextNode` dupes both, so both can be freed straight after.
    fn unescapeCellPipes(
        self: *Parser,
        cell: []const u8,
        out: *std.ArrayList(u8),
        segs: *std.ArrayList(Segment),
    ) Allocator.Error!void {
        const src_base = @intFromPtr(cell.ptr) - @intFromPtr(self.source.ptr);
        // Flush `cell[run_start..end]` as one segment; `run_start` resumes at
        // the `|` itself, so only the `\` is ever dropped.
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < cell.len) {
            if (cell[i] == '\\' and i + 1 < cell.len and cell[i + 1] == '|') {
                try self.appendCellRun(cell, run_start, i, src_base, out, segs);
                run_start = i + 1;
                i += 2;
                continue;
            }
            i += 1;
        }
        try self.appendCellRun(cell, run_start, cell.len, src_base, out, segs);
    }

    /// Append `cell[from..to]` to `out` and record the `Segment` mapping it
    /// back to source. An empty run (a cell starting with `\|`, or two
    /// adjacent escapes) contributes nothing and is skipped rather than
    /// recorded as a zero-length segment.
    fn appendCellRun(
        self: *Parser,
        cell: []const u8,
        from: usize,
        to: usize,
        src_base: usize,
        out: *std.ArrayList(u8),
        segs: *std.ArrayList(Segment),
    ) Allocator.Error!void {
        if (to == from) return;
        try segs.append(self.allocator, .{
            .buf_offset = out.items.len,
            .src_offset = src_base + from,
            .len = to - from,
        });
        try out.appendSlice(self.allocator, cell[from..to]);
    }

    /// Build one `row` node with exactly `aligns.len` `cell` children,
    /// pulling text from `cells[i]` when present or `""` for a ragged
    /// row's missing trailing cells (extra `cells` entries beyond
    /// `aligns.len` are simply never visited -- GFM's "ignore extra cells"
    /// rule).
    fn buildTableRow(self: *Parser, cells: []const []const u8, aligns: []const AST.Alignment, head: bool, start_line: usize, end_line: usize) Allocator.Error!Node.Id {
        var cell_ids = std.ArrayList(Node.Id).empty;
        defer cell_ids.deinit(self.allocator);
        for (aligns, 0..) |al, i| {
            // Every `cells[i]` is a genuine (trimmed) slice of this row's
            // OWN line -- `splitTableRow`/`stripEdgePipes` only ever
            // sub-slice, never copy -- so, like an ATX heading's content,
            // one `singleSegment` maps it directly; a ragged row's missing
            // trailing cell (`""`) just gets an empty (harmless) mapping.
            // A cell carrying an escaped `\|` is the one exception: its text
            // has to be REWRITTEN before inline parsing, so it takes
            // `unescapeCellPipes`' segment LIST instead (see there for why
            // the ordinary inline backslash-escape path can't do this job).
            const text = if (i < cells.len) cells[i] else "";
            const kind: Node.Kind = .{ .cell = .{ .head = head, .alignment = al } };
            const cell_id = if (std.mem.indexOf(u8, text, "\\|") == null) blk: {
                const seg = self.singleSegment(text);
                break :blk try self.addDeferredTextNode(kind, text, &seg, start_line, end_line);
            } else blk: {
                var out = std.ArrayList(u8).empty;
                defer out.deinit(self.allocator);
                var segs = std.ArrayList(Segment).empty;
                defer segs.deinit(self.allocator);
                try self.unescapeCellPipes(text, &out, &segs);
                break :blk try self.addDeferredTextNode(kind, out.items, segs.items, start_line, end_line);
            };
            try cell_ids.append(self.allocator, cell_id);
        }
        const row_id = try self.builder.addContainer(.{ .row = .{ .head = head } }, cell_ids.items);
        self.builder.setSpan(row_id, Span.init(self.lineStart(start_line), self.lineEnd(end_line)));
        return row_id;
    }

    // ── Phase 3: definition lists ────────────────────────────────────────

    /// PHP-Markdown-Extra / Pandoc style definition lists
    /// (`self.options.definition_lists`). Grammar implemented here
    /// (documented since this is a twig-chosen approximation, not a spec):
    ///
    ///   Term
    ///   : Definition text -- may lazily continue onto further lines
    ///     (joined with a soft break, like an ordinary paragraph) until a
    ///     blank line, another `:`-line, or a line that looks like some
    ///     other block construct.
    ///   : A second `:`-line right after the first starts ANOTHER
    ///     definition for the SAME term (a `definition_list_item` can hold
    ///     more than one `definition`).
    ///
    ///   Term 2
    ///   : Definition
    ///
    /// A "term" is a single-line paragraph (no blank line yet, exactly one
    /// line accumulated) immediately followed by a `:`-line (at <=3 space
    /// indent, `:` then a space/tab). Consecutive `Term\n: def...` groups,
    /// separated by at most ONE blank line, merge into a single
    /// `definition_list`; anything else ends it. Only tried when the
    /// currently open leaf is a single-line paragraph (mirrors the
    /// setext-heading check right next to this call site) -- a definition
    /// list therefore never interrupts a multi-line paragraph.
    fn tryStartDefinitionList(self: *Parser, lf: *Leaf, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!bool {
        const s = stripUpTo3Indent(line[cur.pos..]);
        if (!isDefinitionMarkerLine(s)) return false;

        const trimmed_term = std.mem.trim(u8, lf.text.items, " \t\r\n");
        if (trimmed_term.len == 0) return false;
        const term_text = try self.allocator.dupe(u8, trimmed_term);
        defer self.allocator.free(term_text);
        // "A term is a single-line paragraph" (this function's own doc
        // comment) -- but it's STILL built via the ordinary paragraph
        // `Leaf`/`appendMappedSource` machinery (`openParagraph`), so it
        // gets its span the same way a one-line paragraph would, rather
        // than a fresh `singleSegment` (`lf.text.items` is a COPY, not a
        // source slice, so `singleSegment` -- which needs a genuine source
        // slice -- isn't available here; `rebaseSegments` against
        // `lf.text_segs` is).
        const term_segs = try rebaseSegments(self.allocator, lf.text_segs.items, lf.text.items, trimmed_term);
        defer self.allocator.free(term_segs);
        var term_start_line = lf.start_line;
        // Free the paragraph leaf's own buffer FIRST (while `lf` -- a
        // pointer into `self.leaf`'s payload -- is still valid), THEN null
        // out `self.leaf` itself; doing it in the other order would zero
        // the memory `lf` points to before `deinit` ever reads it, leaking
        // the text buffer (`Leaf.deinit` on an already-zeroed `ArrayList`
        // is a silent no-op, not a double-free, which is exactly what made
        // this easy to miss).
        lf.deinit(self.allocator);
        self.leaf = null;

        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();

        var item_ids = std.ArrayList(Node.Id).empty;
        defer item_ids.deinit(self.allocator);
        var scan = idx;
        var last_idx = idx;
        var current_term = term_text;
        var current_term_segs: []const Segment = term_segs;
        var owned_term: ?[]u8 = null;
        defer if (owned_term) |t| self.allocator.free(t);
        var owned_term_segs: ?[]Segment = null;
        defer if (owned_term_segs) |seg| self.allocator.free(seg);

        while (true) {
            const term_id = try self.addDeferredTextNode(.term, current_term, current_term_segs, term_start_line, term_start_line);
            var def_ids = std.ArrayList(Node.Id).empty;
            defer def_ids.deinit(self.allocator);

            while (scan < self.lines.len) {
                const dline = self.lines[scan];
                const dm = self.matchContainers(dline);
                if (dm.matched_index != self.stack.items.len) break;
                const ds = stripUpTo3Indent(dline[dm.cur.pos..]);
                if (!isDefinitionMarkerLine(ds)) break;

                // Built the same "mapped source runs + unmapped line-join
                // separators" way `Leaf.text`/`.text_segs` are (see this
                // file's module doc comment's "Inline spans" section) --
                // a definition's body can span multiple (lazily-indented)
                // lines exactly like a paragraph's can.
                var content = std.ArrayList(u8).empty;
                defer content.deinit(self.allocator);
                var content_segs = std.ArrayList(Segment).empty;
                defer content_segs.deinit(self.allocator);
                try self.appendMappedSource(&content, &content_segs, trimLeadingWs(ds[1..]));
                const def_start = scan;
                var def_end = scan;
                scan += 1;
                while (scan < self.lines.len) {
                    const cline = self.lines[scan];
                    const cm = self.matchContainers(cline);
                    if (cm.matched_index != self.stack.items.len) break;
                    const crem = cline[cm.cur.pos..];
                    if (isBlankLine(crem)) break;
                    const cs = stripUpTo3Indent(crem);
                    if (isDefinitionMarkerLine(cs)) break;
                    if (looksLikeNewBlockStart(cs)) break;
                    try self.appendUnmappedByte(&content, '\n');
                    try self.appendMappedSource(&content, &content_segs, trimLeadingWs(crem));
                    def_end = scan;
                    scan += 1;
                }
                const def_id = try self.addDeferredTextNode(.definition, content.items, content_segs.items, def_start, def_end);
                try def_ids.append(self.allocator, def_id);
                last_idx = def_end;
            }
            if (def_ids.items.len == 0) {
                // The term matched but not one single `:`-line actually
                // parsed (shouldn't happen given `isDefinitionMarkerLine`
                // gated entry, but guards against an empty item).
                break;
            }

            var item_children = std.ArrayList(Node.Id).empty;
            defer item_children.deinit(self.allocator);
            try item_children.append(self.allocator, term_id);
            try item_children.appendSlice(self.allocator, def_ids.items);
            const item_id = try self.builder.addContainer(.definition_list_item, item_children.items);
            self.builder.setSpan(item_id, Span.init(self.lineStart(term_start_line), self.lineEnd(last_idx)));
            try item_ids.append(self.allocator, item_id);

            // Look for another `Term\n: def` group, tolerating at most one
            // blank line before it.
            var next_idx = scan;
            if (next_idx < self.lines.len) {
                const bl = self.lines[next_idx];
                const bm = self.matchContainers(bl);
                if (bm.matched_index == self.stack.items.len and isBlankLine(bl[bm.cur.pos..])) next_idx += 1;
            }
            if (next_idx >= self.lines.len or next_idx + 1 >= self.lines.len) break;
            const tl = self.lines[next_idx];
            const tm = self.matchContainers(tl);
            if (tm.matched_index != self.stack.items.len) break;
            const trem = tl[tm.cur.pos..];
            if (isBlankLine(trem) or indentCols(trem, .{}) >= 4) break;
            const ts = stripUpTo3Indent(trem);
            if (isDefinitionMarkerLine(ts) or looksLikeNewBlockStart(ts)) break;

            const dl2 = self.lines[next_idx + 1];
            const dm2 = self.matchContainers(dl2);
            if (dm2.matched_index != self.stack.items.len) break;
            const ds2 = stripUpTo3Indent(dl2[dm2.cur.pos..]);
            if (!isDefinitionMarkerLine(ds2)) break;

            // Unlike the FIRST term (which came from an already-open
            // paragraph `Leaf`, hence `rebaseSegments` above), `ts` here is
            // a genuine slice of `self.lines[next_idx]` -- straight off
            // this loop's own line scan, never routed through a `Leaf` --
            // so `singleSegment` applies directly, same as an ATX heading.
            const next_term_text = std.mem.trim(u8, ts, " \t\r\n");
            if (owned_term) |t| self.allocator.free(t);
            owned_term = try self.allocator.dupe(u8, next_term_text);
            current_term = owned_term.?;
            if (owned_term_segs) |seg| self.allocator.free(seg);
            const next_seg = self.singleSegment(next_term_text);
            owned_term_segs = try self.allocator.dupe(Segment, &next_seg);
            current_term_segs = owned_term_segs.?;
            term_start_line = next_idx;
            scan = next_idx + 1;
        }

        const list_id = try self.builder.addContainer(.definition_list, item_ids.items);
        self.builder.setSpan(list_id, Span.init(self.lineStart(idx), self.lineEnd(last_idx)));
        setContentSpanFromChildren(&self.builder, list_id);
        try self.appendToTop(list_id);
        self.skip_until_line = last_idx + 1;
        return true;
    }

    // ── Phase 3: footnote definitions ───────────────────────────────────

    /// GFM/Pandoc-style footnote definitions (`self.options.footnotes`):
    ///
    ///   [^label]: First line of the note's content.
    ///       Lazily-indented continuation lines (indented to at least the
    ///       column right after "[^label]: ", exactly like a list item's own
    ///       content -- see `matchListItem`, reused here via
    ///       `.footnote_def`'s `content_col`) join the SAME block; blank
    ///       lines are tolerated mid-definition too.
    ///
    ///       A blank line followed by MORE indented content keeps extending
    ///       this definition (its body can hold multiple paragraphs, nested
    ///       lists, etc., just like a list item's body); a blank line
    ///       followed by non-indented content ends it.
    ///
    /// A definition is recognized as a fresh block start (`tryStartBlocks`,
    /// gated `!interrupting` like `tryStartTable` -- see that flag's use
    /// here) rather than being stripped from already-accumulated paragraph
    /// text the way link reference definitions are (`stripLinkReferenceDefinitions`):
    /// unlike a link reference definition's single destination/title, a
    /// footnote's body is arbitrary block content, which needs the ordinary
    /// container-stack machinery (nested paragraphs/lists/code) rather than
    /// a one-shot text-parse. Consequence, documented: a footnote definition
    /// NEVER interrupts an open paragraph -- `[^a]: note` immediately
    /// following prose with no blank line in between is read as an ordinary
    /// lazy-continuation line of that paragraph, not a new definition
    /// (mirroring `tryStartTable`'s own documented restriction).
    ///
    /// Label normalization matches link reference definitions exactly
    /// (`normalizeLabel`: trim, collapse internal whitespace, ASCII
    /// lowercase), so `[^A b]:`/`[^a  b]:`/`[^a b]` all key the same table
    /// entry. Because inline parsing is deferred until the WHOLE document's
    /// block structure is known (`pending_inline`/`resolvePendingInline`),
    /// and `self.footnotes` is populated here at BLOCK-parse time (not
    /// waiting for inline resolution), a forward `[^a]` reference (used
    /// before its `[^a]:` definition appears) needs no special handling --
    /// same story as link reference definitions.
    ///
    /// Like a link reference definition (and like djot's own footnotes --
    /// see `Djot.Document.footnotes`'s doc comment), the finished `footnote`
    /// node is NEVER appended into the enclosing container's children: it is
    /// collected into `self.footnotes` only, to be resolved/numbered/
    /// backlinked entirely at RENDER time by the shared HTML printer (see
    /// `markdown/html.zig`) via `Markdown.Document.footnotes`.
    fn tryStartFootnoteDef(self: *Parser, line: []const u8, cur: Cursor, idx: usize) Allocator.Error!bool {
        const remainder = line[cur.pos..];
        const s = stripUpTo3Indent(remainder);
        const indent_bytes = remainder.len - s.len;
        const m = tryFootnoteDefMarker(s) orelse return false;

        try self.maybeCloseTopList(idx, null);
        self.markListsLoose();

        // Same "1-4 spaces after the marker sets the content column, else
        // fall back to exactly 1" rule `tryStartBlocks`' list-marker handling
        // uses (see its own comment for the rationale) -- kept consistent
        // rather than inventing a second scheme.
        const marker_col = cur.col + indent_bytes;
        const after_marker_col = marker_col + m.marker_len;
        const after = s[m.marker_len..];
        const item_blank = isBlankLine(after);
        var content_col: usize = undefined;
        if (item_blank) {
            content_col = after_marker_col + 1;
        } else {
            const spaces = indentCols(after, .{ .pos = 0, .col = after_marker_col });
            content_col = if (spaces >= 1 and spaces <= 4) after_marker_col + spaces else after_marker_col + 1;
        }

        try self.pushContainer(.footnote_def, idx);
        // Relative continuation indent, like a list item's -- see `matchListItem`.
        self.top().content_col = content_col -| (cur.col + cur.spent);
        self.top().footnote_label = m.label;

        const after_marker_cursor: Cursor = .{ .pos = cur.pos + indent_bytes + m.marker_len, .col = after_marker_col };
        const content_cur = skipWsToTarget(line, after_marker_cursor, content_col);
        const final_remainder = line[content_cur.pos..];
        if (!isBlankLine(final_remainder)) try self.openParagraph(final_remainder, idx);
        return true;
    }

    const FootnoteDefMarker = struct { marker_len: usize, label: []const u8 };

    /// `\[\^([^\]\r\n]*)\]:([ \t]|$)` -- `s` is already indent-stripped (<=3
    /// columns). The label must contain at least one non-whitespace
    /// character (mirrors link reference definitions' "at least one
    /// character other than blank space" rule -- see `tryParseLinkRefDef`),
    /// and the marker must be followed by a space/tab or the end of the
    /// line (so `[^a]:foo`, with no separating space, is NOT read as a
    /// footnote definition -- same shape of guard `tryParseLinkRefDef`'s
    /// `skipLrdWs` enforces for link reference definitions).
    fn tryFootnoteDefMarker(s: []const u8) ?FootnoteDefMarker {
        if (s.len < 2 or s[0] != '[' or s[1] != '^') return null;
        var i: usize = 2;
        const label_start = i;
        while (i < s.len and s[i] != ']' and s[i] != '\r' and s[i] != '\n') i += 1;
        const label_end = i;
        if (i >= s.len or s[i] != ']') return null;
        i += 1;
        if (i >= s.len or s[i] != ':') return null;
        i += 1;
        if (i < s.len and s[i] != ' ' and s[i] != '\t') return null;
        const label = s[label_start..label_end];
        if (std.mem.trim(u8, label, " \t\r\n").len == 0) return null;
        return .{ .marker_len = i, .label = label };
    }

    /// Finalize a popped `.footnote_def` container into a `footnote` node
    /// and record it in `self.footnotes` -- see `tryStartFootnoteDef`'s doc
    /// comment for why this does NOT call `appendToTop`. A duplicate label
    /// keeps its FIRST definition (same "first one wins" rule
    /// `tryParseLinkRefDef` applies to `self.link_references`).
    fn finishFootnoteDef(self: *Parser, c: *Container, line_idx: usize) Allocator.Error!void {
        const label_owned = try normalizeLabel(self.allocator, c.footnote_label);
        defer self.allocator.free(label_owned);
        const id = try self.builder.addContainer(.{ .footnote = .{ .label = label_owned } }, c.children.items);
        const syntactic = Span.init(self.lineStart(c.start_line), self.lineEnd(@min(c.end_line, line_idx)));
        self.builder.setSpan(id, containerSpanExtended(&self.builder, id, syntactic));
        setContentSpanFromChildren(&self.builder, id);
        if (!self.footnotes.contains(label_owned)) {
            // Reuse the node's OWN (builder-owned) label string as the map
            // key -- see `deinit`'s comment on why this map never frees its
            // own keys.
            const key = self.builder.nodes.items[id].kind.footnote.label;
            try self.footnotes.put(self.allocator, key, id);
        }
    }

    // ── link reference definitions ───────────────────────────────────────

    /// Strip as many consecutive link reference definitions as possible
    /// from the FRONT of `raw` (a to-be-closed paragraph's accumulated raw
    /// text), registering each in `self.link_references`. Returns whatever
    /// text is left (possibly all of it, if none matched, or empty, if the
    /// whole thing was definitions).
    fn stripLinkReferenceDefinitions(self: *Parser, raw: []const u8) Allocator.Error![]const u8 {
        var text = raw;
        while (true) {
            const consumed = try self.tryParseLinkRefDef(text);
            if (consumed == 0) break;
            text = text[consumed..];
            if (text.len > 0 and text[0] == '\n') text = text[1..];
        }
        return text;
    }

    /// Returns the number of bytes consumed from the front of `text` on a
    /// successful parse (0 = no definition there).
    fn tryParseLinkRefDef(self: *Parser, text: []const u8) Allocator.Error!usize {
        var i: usize = 0;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len or text[i] != '[') return 0;
        i += 1;
        const label_start = i;
        var escaped = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '[') return 0;
            if (c == ']') break;
        }
        if (i >= text.len or text[i] != ']') return 0;
        const label = text[label_start..i];
        // A label needs at least one non-whitespace character -- `[]: /uri`
        // is not a link reference definition at all (CommonMark: "at least
        // one character other than blank space").
        if (std.mem.trim(u8, label, " \t\r\n").len == 0) return 0;
        i += 1;
        if (i >= text.len or text[i] != ':') return 0;
        i += 1;
        i = skipLrdWs(text, i);
        if (i >= text.len) return 0;

        var dest: []const u8 = undefined;
        if (text[i] == '<') {
            const start = i + 1;
            var j = start;
            while (j < text.len and text[j] != '>' and text[j] != '\n') : (j += 1) {
                if (text[j] == '\\' and j + 1 < text.len) j += 1;
            }
            if (j >= text.len or text[j] != '>') return 0;
            dest = text[start..j];
            i = j + 1;
        } else {
            const start = i;
            var depth: usize = 0;
            var j = i;
            while (j < text.len) : (j += 1) {
                const c = text[j];
                if (c == '\\' and j + 1 < text.len) {
                    j += 1;
                    continue;
                }
                if (c == ' ' or c == '\t' or c == '\n') break;
                if (c == '(') depth += 1;
                if (c == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            if (j == start) return 0;
            dest = text[start..j];
            i = j;
        }

        const label_owned = try normalizeLabel(self.allocator, label);
        defer self.allocator.free(label_owned);
        const dest_decoded = try inline_mod.decodeText(self.allocator, dest);
        defer self.allocator.free(dest_decoded);

        // Try a title: whitespace (possibly with one line ending) then a
        // quoted/paren title, with only blank content after its closer on
        // that line. If a title-shaped thing is present but malformed, the
        // whole definition attempt fails (see this file's module doc
        // comment's documented simplification).
        const after_dest = i;
        const dest_line_end = std.mem.indexOfScalarPos(u8, text, after_dest, '\n') orelse text.len;
        const ws_end = skipLrdWs(text, after_dest);
        // Did the whitespace between the destination and a title candidate
        // cross a line ending? A malformed title on a *separate* line doesn't
        // sink the whole definition -- the definition ends at the destination
        // line and the bad title line becomes an ordinary paragraph (spec
        // ex210). A malformed title on the *same* line as the destination
        // still fails the definition entirely.
        const title_on_new_line = std.mem.indexOfScalarPos(u8, text, after_dest, '\n') != null and dest_line_end < ws_end;
        // Backing off to a dest-only definition is only valid if the
        // destination's own line has nothing but blanks after it.
        const dest_line_blank = isBlankLine(text[after_dest..dest_line_end]);
        var title: ?[]const u8 = null;
        var end = after_dest;
        if (ws_end > after_dest and ws_end < text.len and (text[ws_end] == '"' or text[ws_end] == '\'' or text[ws_end] == '(')) {
            const open = text[ws_end];
            const close: u8 = if (open == '(') ')' else open;
            var j = ws_end + 1;
            while (j < text.len and text[j] != close) : (j += 1) {
                if (text[j] == '\\' and j + 1 < text.len) j += 1;
            }
            const malformed = blk: {
                if (j >= text.len) break :blk true;
                const rest_start = j + 1;
                const line_end = std.mem.indexOfScalarPos(u8, text, rest_start, '\n') orelse text.len;
                if (!isBlankLine(text[rest_start..line_end])) break :blk true;
                title = text[ws_end + 1 .. j];
                end = line_end;
                break :blk false;
            };
            if (malformed) {
                if (title_on_new_line and dest_line_blank) {
                    end = dest_line_end;
                } else return 0;
            }
        } else {
            if (!dest_line_blank) return 0;
            end = dest_line_end;
        }

        const ref_id = try self.builder.addLeaf(.{ .reference = .{ .label = label_owned, .destination = dest_decoded } });
        if (title) |t| {
            const title_decoded = try inline_mod.decodeText(self.allocator, t);
            defer self.allocator.free(title_decoded);
            try self.builder.setAttrs(ref_id, .{ .entries = &.{.{ .key = "title", .value = title_decoded }} });
        }
        if (!self.link_references.contains(label_owned)) {
            // Reuse the `reference` node's OWN label string (already
            // duped into `self.builder`'s `owned_strings` by `addLeaf` /
            // `dupeKind`) as the map key, rather than allocating yet
            // another copy — see `deinit`'s comment on why this map never
            // frees its own keys.
            const key = self.builder.nodes.items[ref_id].kind.reference.label;
            try self.link_references.put(self.allocator, key, ref_id);
        }
        return end;
    }

    fn skipLrdWs(text: []const u8, start: usize) usize {
        var i = start;
        var seen_nl = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == ' ' or c == '\t') continue;
            if (c == '\n' and !seen_nl) {
                seen_nl = true;
                continue;
            }
            break;
        }
        return i;
    }
};

pub fn parse(allocator: Allocator, source: []const u8, options: Options) Allocator.Error!BlockResult {
    var p = try Parser.init(allocator, source, options);
    defer p.deinit();
    return p.parse();
}

const testing = std.testing;
const Html = @import("../html/html.zig");

fn renderHtml(source: []const u8, options: Options) ![]u8 {
    var r = try parse(testing.allocator, source, options);
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    return Html.serializeAlloc(testing.allocator, &r.ast, null);
}

test "ATX heading" {
    var r = try parse(testing.allocator, "## Hello\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const h = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[h].kind.heading.level == 2);
    const text = r.ast.nodes[h].first_child.?;
    try testing.expectEqualStrings("Hello", r.ast.nodes[text].kind.str);
}

// ── inline spans (byte-accurate, delimiters included) ───────────────────
// See this file's module doc comment's "Inline spans" section: unlike
// `inline.zig`'s own span tests (which fabricate a `Segment` mapping a bare
// string onto itself), these run the FULL pipeline -- real source, real
// `lineStart`/`lineEnd`-derived offsets, real indentation/marker stripping
// -- and slice the ORIGINAL source with a resolved node's span, which is the
// mission's actual correctness bar.

test "span: a link in a single-line paragraph covers '[x](url)', content_span the link text" {
    const src = "see [x](http://a.co) now\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    const first = r.ast.nodes[para].first_child.?; // "see "
    const link = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("[x](http://a.co)", Span.of(u8, r.ast.nodes[link].span, src));
    try testing.expectEqualStrings("x", Span.of(u8, r.ast.nodes[link].content_span.?, src));
}

test "span: a link inside a heading is byte-accurate" {
    const src = "## see [x](http://a.co) now\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const h = r.ast.nodes[r.ast.root].first_child.?;
    const first = r.ast.nodes[h].first_child.?; // "see "
    const link = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[link].kind == .link);
    try testing.expectEqualStrings("[x](http://a.co)", Span.of(u8, r.ast.nodes[link].span, src));
}

test "span: emphasis in a single-line paragraph covers its own delimiters" {
    const src = "hi *abc* there\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    const first = r.ast.nodes[para].first_child.?; // "hi "
    const em = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[em].kind == .emph);
    try testing.expectEqualStrings("*abc*", Span.of(u8, r.ast.nodes[em].span, src));
    try testing.expectEqualStrings("abc", Span.of(u8, r.ast.nodes[em].content_span.?, src));
}

test "span: a code span includes its own backticks" {
    const src = "x `code` y\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    const first = r.ast.nodes[para].first_child.?; // "x "
    const code = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[code].kind == .verbatim);
    try testing.expectEqualStrings("`code`", Span.of(u8, r.ast.nodes[code].span, src));
}

test "span: a str leaf's span is its own exact source bytes, even nested in a block quote" {
    const src = "> hello world\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const bq = r.ast.nodes[r.ast.root].first_child.?;
    const para = r.ast.nodes[bq].first_child.?;
    const str = r.ast.nodes[para].first_child.?;
    try testing.expectEqualStrings("hello world", Span.of(u8, r.ast.nodes[str].span, src));
}

test "span: a multi-line paragraph's inline nodes are left unset when they'd cross the line join" {
    // See this file's module doc comment's "Inline spans" section: a
    // paragraph joined from more than one source line is only mapped
    // per-segment (one per source line); an inline construct entirely
    // within ONE of those lines still gets an accurate span (checked
    // below), but one that straddles the synthetic line-join `\n` (the
    // emphasis run here opens on line 1 and closes on line 2) can't be
    // mapped accurately, so it's deliberately left unset (`(0,0)`) rather
    // than risk a wrong one.
    const src = "a *b\nc* d\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    const first = r.ast.nodes[para].first_child.?; // "a "
    try testing.expectEqualStrings("a ", Span.of(u8, r.ast.nodes[first].span, src));
    const em = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[em].kind == .emph);
    try testing.expectEqual(@as(usize, 0), r.ast.nodes[em].span.start);
    try testing.expectEqual(@as(usize, 0), r.ast.nodes[em].span.end);
}

test "fenced code block with a language" {
    var r = try parse(testing.allocator, "```zig\nconst x = 1;\n```\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const cb = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expectEqualStrings("zig", r.ast.nodes[cb].kind.code_block.lang.?);
    try testing.expectEqualStrings("const x = 1;\n", r.ast.nodes[cb].kind.code_block.text);
}

test "tight bullet list with two items" {
    var r = try parse(testing.allocator, "- a\n- b\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind.bullet_list.tight);
    const item1 = r.ast.nodes[list].first_child.?;
    const item2 = r.ast.nodes[item1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[item2].next_sibling);
}

test "block quote" {
    var r = try parse(testing.allocator, "> foo\n> bar\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const bq = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[bq].kind == .block_quote);
    const para = r.ast.nodes[bq].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
}

test "HTML block" {
    var r = try parse(testing.allocator, "<div>\n  <p>hi</p>\n</div>\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const rb = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[rb].kind == .raw_block);
    try testing.expectEqualStrings("html", r.ast.nodes[rb].kind.raw_block.format);
}

test "paragraph with a code span and a hard break" {
    var r = try parse(testing.allocator, "foo `bar`  \nbaz\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    var it = r.ast.children(para);
    _ = it.next().?; // "foo "
    const code = it.next().?;
    try testing.expectEqualStrings("bar", code.kind.verbatim);
    const brk = it.next().?;
    try testing.expect(brk.kind == .hard_break);
}

test "a link reference definition is stripped and recorded in the table" {
    var r = try parse(testing.allocator, "[foo]: /url \"title\"\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[r.ast.root].first_child);
    const ref_id = r.link_references.get("foo") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("/url", r.ast.nodes[ref_id].kind.reference.destination);
    try testing.expectEqualStrings("title", r.ast.attrsOf(ref_id).get("title").?);
}

// ── Phase 3: GFM tables ─────────────────────────────────────────────────

test "table: header/delimiter/body with per-column alignment" {
    var r = try parse(testing.allocator,
        \\| a | b | c |
        \\|---|:--:|--:|
        \\| 1 | 2 | 3 |
        \\
    , .{ .tables = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const table = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[table].kind == .table);
    const caption = r.ast.nodes[table].first_child.?;
    try testing.expect(r.ast.nodes[caption].kind == .caption);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[caption].first_child);

    const head_row = r.ast.nodes[caption].next_sibling.?;
    try testing.expect(r.ast.nodes[head_row].kind == .row);
    try testing.expect(r.ast.nodes[head_row].kind.row.head);
    const c1 = r.ast.nodes[head_row].first_child.?;
    try testing.expect(r.ast.nodes[c1].kind.cell.head);
    try testing.expectEqual(AST.Alignment.default, r.ast.nodes[c1].kind.cell.alignment);
    const c2 = r.ast.nodes[c1].next_sibling.?;
    try testing.expectEqual(AST.Alignment.center, r.ast.nodes[c2].kind.cell.alignment);
    const c3 = r.ast.nodes[c2].next_sibling.?;
    try testing.expectEqual(AST.Alignment.right, r.ast.nodes[c3].kind.cell.alignment);

    const body_row = r.ast.nodes[head_row].next_sibling.?;
    try testing.expect(!r.ast.nodes[body_row].kind.row.head);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[body_row].next_sibling);
}

test "table: ragged rows are padded/truncated to the header's column count" {
    var r = try parse(testing.allocator,
        \\| a | b |
        \\| - | - |
        \\| 1 |
        \\| 1 | 2 | 3 |
        \\
    , .{ .tables = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const table = r.ast.nodes[r.ast.root].first_child.?;
    const caption = r.ast.nodes[table].first_child.?;
    const head_row = r.ast.nodes[caption].next_sibling.?;
    const short_row = r.ast.nodes[head_row].next_sibling.?;
    const short_c1 = r.ast.nodes[short_row].first_child.?;
    const short_c2 = r.ast.nodes[short_c1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[short_c2].next_sibling);

    const long_row = r.ast.nodes[short_row].next_sibling.?;
    const long_c1 = r.ast.nodes[long_row].first_child.?;
    const long_c2 = r.ast.nodes[long_c1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[long_c2].next_sibling);
}

test "table: renders through the shared HTML printer with an empty caption" {
    const html = try renderHtml("| a | b |\n| - | - |\n| 1 | 2 |\n", .{ .tables = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<table>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</table>\n",
        html,
    );
}

test "table OFF: a pipe 'table' parses as an ordinary CommonMark paragraph" {
    var r = try parse(testing.allocator, "| a | b |\n| - | - |\n", .{ .tables = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[para].next_sibling);
}

// ── Phase 3: task lists ──────────────────────────────────────────────────

test "task list: unchecked and checked (case-insensitive) items" {
    var r = try parse(testing.allocator, "- [ ] todo\n- [x] done\n- [X] also done\n", .{ .task_lists = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind == .task_list);
    const item1 = r.ast.nodes[list].first_child.?;
    try testing.expect(r.ast.nodes[item1].kind == .task_list_item);
    try testing.expect(!r.ast.nodes[item1].kind.task_list_item.checked);
    const para1 = r.ast.nodes[item1].first_child.?;
    const text1 = r.ast.nodes[para1].first_child.?;
    try testing.expectEqualStrings("todo", r.ast.nodes[text1].kind.str);

    const item2 = r.ast.nodes[item1].next_sibling.?;
    try testing.expect(r.ast.nodes[item2].kind.task_list_item.checked);
    const item3 = r.ast.nodes[item2].next_sibling.?;
    try testing.expect(r.ast.nodes[item3].kind.task_list_item.checked);
}

test "task list: renders an <input type=checkbox> via the shared HTML printer" {
    const html = try renderHtml("- [x] done\n", .{ .task_lists = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<ul class=\"task-list\">\n<li>\n<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\ndone\n</li>\n</ul>\n",
        html,
    );
}

test "task lists OFF: '- [ ] x' is a plain bullet list item with literal text" {
    var r = try parse(testing.allocator, "- [ ] x\n", .{ .task_lists = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind == .bullet_list);
    const item = r.ast.nodes[list].first_child.?;
    try testing.expect(r.ast.nodes[item].kind == .list_item);
    const para = r.ast.nodes[item].first_child.?;
    // `[ ]` with no following `(`/`[` and no matching reference falls back
    // to literal brackets per Phase 2's existing (unrelated to this flag)
    // link-resolution rules -- it doesn't stay ONE `str` node (see
    // `inline.zig`'s "an unresolved reference label falls back to literal
    // brackets" test), so concatenate every child's text instead.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var it = r.ast.children(para);
    while (it.next()) |n| try buf.appendSlice(testing.allocator, n.kind.str);
    try testing.expectEqualStrings("[ ] x", buf.items);
}

// ── Phase 3: extended autolinks (block-level integration) ────────────────

test "extended autolinks render through the shared HTML printer" {
    const html = try renderHtml("visit www.example.com today\n", .{ .autolinks = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>visit <a href=\"http://www.example.com\">www.example.com</a> today</p>\n", html);
}

// ── Phase 3: math (block-level integration) ──────────────────────────────

test "math renders through the shared HTML printer" {
    const html = try renderHtml("$x$ and $$y$$\n", .{ .math = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<p><span class=\"math inline\">\\(x\\)</span> and <span class=\"math display\">\\[y\\]</span></p>\n",
        html,
    );
}

// ── Phase 3: definition lists ────────────────────────────────────────────

test "definition list: a term with two definitions" {
    var r = try parse(testing.allocator,
        \\Term
        \\: First definition
        \\: Second definition
        \\
    , .{ .definition_lists = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const dl = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[dl].kind == .definition_list);
    const item = r.ast.nodes[dl].first_child.?;
    try testing.expect(r.ast.nodes[item].kind == .definition_list_item);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[item].next_sibling);

    const term = r.ast.nodes[item].first_child.?;
    try testing.expect(r.ast.nodes[term].kind == .term);
    const term_text = r.ast.nodes[term].first_child.?;
    try testing.expectEqualStrings("Term", r.ast.nodes[term_text].kind.str);

    const def1 = r.ast.nodes[term].next_sibling.?;
    try testing.expect(r.ast.nodes[def1].kind == .definition);
    const def1_text = r.ast.nodes[def1].first_child.?;
    try testing.expectEqualStrings("First definition", r.ast.nodes[def1_text].kind.str);

    const def2 = r.ast.nodes[def1].next_sibling.?;
    try testing.expect(r.ast.nodes[def2].kind == .definition);
    const def2_text = r.ast.nodes[def2].first_child.?;
    try testing.expectEqualStrings("Second definition", r.ast.nodes[def2_text].kind.str);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[def2].next_sibling);
}

test "definition list: two adjacent term groups merge into one definition_list" {
    var r = try parse(testing.allocator,
        \\Term A
        \\: def a
        \\
        \\Term B
        \\: def b
        \\
    , .{ .definition_lists = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const dl = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[dl].kind == .definition_list);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[dl].next_sibling);
    const item1 = r.ast.nodes[dl].first_child.?;
    const item2 = r.ast.nodes[item1].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[item2].next_sibling);
    const term2 = r.ast.nodes[item2].first_child.?;
    const term2_text = r.ast.nodes[term2].first_child.?;
    try testing.expectEqualStrings("Term B", r.ast.nodes[term2_text].kind.str);
}

test "definition list: renders as <dl><dt>...<dd>... via the shared HTML printer" {
    const html = try renderHtml("Term\n: def\n", .{ .definition_lists = true });
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<dl>\n<dt>Term</dt>\n<dd>\ndef</dd>\n</dl>\n", html);
}

test "definition lists OFF: 'Term\\n: def' lazily continues one CommonMark paragraph" {
    var r = try parse(testing.allocator, "Term\n: def\n", .{ .definition_lists = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[para].next_sibling);
}

// ── Phase 3: footnote definitions ────────────────────────────────────────

test "footnote definition: collected into r.footnotes, NOT emitted into the main flow" {
    var r = try parse(testing.allocator, "para\n\n[^a]: the note\n", .{ .footnotes = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const para = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
    // The footnote definition is the ONLY other top-level content in the
    // source, and it must not show up as a sibling block.
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[para].next_sibling);

    const fn_id = r.footnotes.get("a") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("a", r.ast.nodes[fn_id].kind.footnote.label);
    const body = r.ast.nodes[fn_id].first_child.?;
    try testing.expect(r.ast.nodes[body].kind == .para);
}

test "footnote definition: the label is normalized (trim/collapse ws/lowercase)" {
    var r = try parse(testing.allocator, "[^ A  B ]: note\n", .{ .footnotes = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    try testing.expect(r.footnotes.contains("a b"));
}

test "footnote definition: a continuation line indented to line up with the first line's content joins the same note body" {
    // Pandoc's own documented convention (which this mirrors -- see
    // `tryStartFootnoteDef`'s doc comment): "subsequent paragraphs are
    // indented to line up with the first line of the note". "[^a]: " is 6
    // columns wide, so the continuation must be indented 6 columns to join.
    var r = try parse(testing.allocator, "[^a]: first line\n      second line\n", .{ .footnotes = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const fn_id = r.footnotes.get("a") orelse return error.TestExpectedNonNull;
    const body = r.ast.nodes[fn_id].first_child.?;
    try testing.expect(r.ast.nodes[body].kind == .para);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[body].next_sibling);
    // The embedded newline becomes a `soft_break` (same as any other
    // multi-line paragraph -- Phase 2 inline scanning, not this file's own
    // logic), so the body is "first line", a soft break, then "second
    // line", NOT one single joined `str` node.
    const s1 = r.ast.nodes[body].first_child.?;
    try testing.expectEqualStrings("first line", r.ast.nodes[s1].kind.str);
    const brk = r.ast.nodes[s1].next_sibling.?;
    try testing.expect(r.ast.nodes[brk].kind == .soft_break);
    const s2 = r.ast.nodes[brk].next_sibling.?;
    try testing.expectEqualStrings("second line", r.ast.nodes[s2].kind.str);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[s2].next_sibling);
}

test "footnote definitions: back-to-back definitions with no blank line between them each get their own node" {
    var r = try parse(testing.allocator, "[^a]: first\n[^b]: second\n", .{ .footnotes = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const a_id = r.footnotes.get("a") orelse return error.TestExpectedNonNull;
    const b_id = r.footnotes.get("b") orelse return error.TestExpectedNonNull;
    const a_body = r.ast.nodes[a_id].first_child.?; // the note's `para`
    const b_body = r.ast.nodes[b_id].first_child.?;
    try testing.expectEqualStrings("first", r.ast.nodes[r.ast.nodes[a_body].first_child.?].kind.str);
    try testing.expectEqualStrings("second", r.ast.nodes[r.ast.nodes[b_body].first_child.?].kind.str);
    // Neither shows up in the main flow.
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[r.ast.root].first_child);
}

test "footnotes OFF: '[^a]:' is an ordinary link reference definition, not collected as a footnote" {
    var r = try parse(testing.allocator, "[^a]: /url\n", .{ .footnotes = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.footnotes.count());
    try testing.expect(r.link_references.contains("^a"));
}

// ── Phase 3: frontmatter ──────────────────────────────────────────────────

test "frontmatter: a leading YAML block becomes a metadata node, not rendered to HTML body" {
    var r = try parse(testing.allocator, "---\ntitle: Hi\n---\n# Heading\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const fm = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[fm].kind == .metadata);
    try testing.expectEqualStrings("yaml", r.ast.nodes[fm].kind.metadata.lang);
    try testing.expectEqualStrings("title: Hi\n", r.ast.nodes[fm].kind.metadata.text);

    const heading = r.ast.nodes[fm].next_sibling.?;
    try testing.expect(r.ast.nodes[heading].kind == .heading);

    // Metadata projects to an inert `<script type>` data island — no body text.
    const html = try Html.serializeAlloc(testing.allocator, &r.ast, null);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<script type=\"application/yaml\">\ntitle: Hi\n</script>\n<h1>Heading</h1>\n", html);
}

test "frontmatter: a leading TOML (+++) block is tagged lang=\"toml\"" {
    var r = try parse(testing.allocator, "+++\ntitle = \"Hi\"\n+++\nbody\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const fm = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[fm].kind == .metadata);
    try testing.expectEqualStrings("toml", r.ast.nodes[fm].kind.metadata.lang);
    try testing.expectEqualStrings("title = \"Hi\"\n", r.ast.nodes[fm].kind.metadata.text);
}

test "frontmatter: the language tag is stored as-written; MIME is application/<lang>" {
    var r = try parse(testing.allocator, "---fig\ntitle = Twig\n---\n# Twig\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const fm = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[fm].kind == .metadata);
    // No normalization: `fig` stays `fig` (and `figl` would stay `figl`).
    try testing.expectEqualStrings("fig", r.ast.nodes[fm].kind.metadata.lang);
    try testing.expectEqualStrings("title = Twig\n", r.ast.nodes[fm].kind.metadata.text);

    // Round-trips losslessly: `---fig` in, `---fig` out.
    const md = try @import("serializer.zig").serializeAstAlloc(testing.allocator, &r.ast);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.startsWith(u8, md, "---fig\ntitle = Twig\n---\n"));

    // MIME is derived mechanically: `application/fig`.
    const html = try Html.serializeAlloc(testing.allocator, &r.ast, null);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.startsWith(u8, html, "<script type=\"application/fig\">\n"));
}

test "frontmatter: an arbitrary config language flows through the application/<lang> rule" {
    var r = try parse(testing.allocator, "---edn\n{:title \"Hi\"}\n---\nbody\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const fm = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[fm].kind == .metadata);
    try testing.expectEqualStrings("edn", r.ast.nodes[fm].kind.metadata.lang);
    const html = try Html.serializeAlloc(testing.allocator, &r.ast, null);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.startsWith(u8, html, "<script type=\"application/edn\">\n"));
}

test "frontmatter: HTML printer refuses a metadata body containing `</script` (injection guard)" {
    var r = try parse(testing.allocator, "---figl\nx = \"</script><img src=x onerror=alert(1)>\"\n---\n# Body\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    try testing.expectError(error.UnsafeMetadata, Html.serializeAlloc(testing.allocator, &r.ast, null));

    // The other surfaces stay lossless — only the raw-text HTML island is unsafe.
    const md = try @import("serializer.zig").serializeAstAlloc(testing.allocator, &r.ast);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "</script>") != null);
}

test "frontmatter: the `</script` guard is case-insensitive" {
    var r = try parse(testing.allocator, "---figl\nx = \"a </SCRIPT b\"\n---\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    try testing.expectError(error.UnsafeMetadata, Html.serializeAlloc(testing.allocator, &r.ast, null));
}

test "frontmatter: a lone `<script` (no close) is inert raw text and still renders" {
    // Without a `</script`, the content can't break out of the island, so the
    // guard must NOT over-refuse it.
    var r = try parse(testing.allocator, "---figl\nx = \"see <script src=x>\"\n---\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const html = try Html.serializeAlloc(testing.allocator, &r.ast, null);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.startsWith(u8, html, "<script type=\"application/figl\">\n"));
}

test "endmatter: a trailing `---<lang>` block becomes the doc's last child" {
    var r = try parse(testing.allocator, "# Body\n\ntext\n\n---toml\nisbn = \"1-2-3\"\n---\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    // Body first (heading, paragraph), metadata LAST.
    const root = r.ast.root;
    var last: Node.Id = r.ast.nodes[root].first_child.?;
    while (r.ast.nodes[last].next_sibling) |n| last = n;
    try testing.expect(r.ast.nodes[last].kind == .metadata);
    try testing.expectEqualStrings("toml", r.ast.nodes[last].kind.metadata.lang);
    try testing.expectEqualStrings("isbn = \"1-2-3\"\n", r.ast.nodes[last].kind.metadata.text);

    // The heading really is first — endmatter didn't swallow the body.
    const first = r.ast.nodes[root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .heading);
}

test "endmatter: front AND end matter coexist on one document" {
    var r = try parse(testing.allocator, "---figl\ntitle = Twig\n---\n\n# Body\n\n---toml\nisbn = \"x\"\n---\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const first = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .metadata);
    try testing.expectEqualStrings("figl", r.ast.nodes[first].kind.metadata.lang);

    var last: Node.Id = first;
    while (r.ast.nodes[last].next_sibling) |n| last = n;
    try testing.expect(r.ast.nodes[last].kind == .metadata);
    try testing.expectEqualStrings("toml", r.ast.nodes[last].kind.metadata.lang);
    try testing.expect(first != last);
}

test "endmatter: round-trips through the Markdown serializer" {
    const src = "# Body\n\n---toml\nisbn = \"x\"\n---\n";
    var r = try parse(testing.allocator, src, .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const md = try @import("serializer.zig").serializeAstAlloc(testing.allocator, &r.ast);
    defer testing.allocator.free(md);
    // The trailing block re-emits as `---toml` … `---`.
    try testing.expect(std.mem.indexOf(u8, md, "---toml\nisbn = \"x\"\n---\n") != null);
}

test "endmatter: an untagged trailing `---` block is NOT endmatter (thematic breaks)" {
    // Bare `---` is ambiguous away from the top, so it parses as ordinary
    // CommonMark: `text` + thematic break + `k = v` paragraph + thematic break.
    var r = try parse(testing.allocator, "text\n\n---\nk = v\n---\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    var last: Node.Id = r.ast.nodes[r.ast.root].first_child.?;
    while (r.ast.nodes[last].next_sibling) |n| last = n;
    try testing.expect(r.ast.nodes[last].kind != .metadata);
}

test "endmatter: a tagged trailing block with no blank separator is NOT endmatter" {
    // Without the mandatory blank line above the opener, the tail parses
    // normally (here the `---toml` is a lazy paragraph continuation).
    var r = try parse(testing.allocator, "text\n---toml\nk = v\n---\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    var last: Node.Id = r.ast.nodes[r.ast.root].first_child.?;
    while (r.ast.nodes[last].next_sibling) |n| last = n;
    try testing.expect(r.ast.nodes[last].kind != .metadata);
}

test "frontmatter: `----` (four dashes) is a thematic break, not a metadata fence" {
    var r = try parse(testing.allocator, "----\nfoo\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const first = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .thematic_break);
}

test "frontmatter: an unterminated leading '---' block falls back to ordinary parsing" {
    var r = try parse(testing.allocator, "---\ntitle: Hi\n", .{ .frontmatter = true });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    // No closing `---`: the first line is just a thematic break, same as
    // with the flag off.
    const first = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .thematic_break);
}

test "frontmatter OFF: a leading '---' is an ordinary CommonMark thematic break" {
    var r = try parse(testing.allocator, "---\nfoo\n", .{ .frontmatter = false });
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const first = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[first].kind == .thematic_break);
    const para = r.ast.nodes[first].next_sibling.?;
    try testing.expect(r.ast.nodes[para].kind == .para);
}

// ── generic directives (`options.directives`) ───────────────────────────

const directives_on: Options = .{ .directives = true };

fn firstChild(ast: anytype, id: Node.Id) Node.Id {
    return ast.nodes[id].first_child.?;
}

test "container directive: name becomes an element tag, attrs applied" {
    const html = try renderHtml(":::note{#n .box}\nHello *world*\n:::\n", directives_on);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<note id=\"n\" class=\"box\">\n<p>Hello <em>world</em></p>\n</note>\n", html);
}

test "container directive: AST node kind/form/name/attrs" {
    var r = try parse(testing.allocator, ":::warning\ncontent\n:::\n", directives_on);
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const dir = firstChild(r.ast, r.ast.root);
    try testing.expect(r.ast.nodes[dir].kind == .directive);
    try testing.expectEqual(AST.DirectiveForm.container, r.ast.nodes[dir].kind.directive.form);
    try testing.expectEqualStrings("warning", r.ast.nodes[dir].kind.directive.name);
    const para = firstChild(r.ast, dir);
    try testing.expect(r.ast.nodes[para].kind == .para);
}

test "container directive: nested blocks (list) parse as blocks" {
    var r = try parse(testing.allocator, ":::box\n- a\n- b\n:::\n", directives_on);
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const dir = firstChild(r.ast, r.ast.root);
    const list = firstChild(r.ast, dir);
    try testing.expect(r.ast.nodes[list].kind == .bullet_list);
}

test "nested container directives, longer fence outside" {
    const html = try renderHtml("::::outer\n:::inner\nhi\n:::\n::::\n", directives_on);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<outer>\n<inner>\n<p>hi</p>\n</inner>\n</outer>\n", html);
}

test "leaf directive: single line, label is inline content" {
    const html = try renderHtml("::youtube[A caption]{#v}\n", directives_on);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<youtube id=\"v\">A caption</youtube>\n", html);
}

test "leaf directive: AST kind and no-label case" {
    var r = try parse(testing.allocator, "::hr\n", directives_on);
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const dir = firstChild(r.ast, r.ast.root);
    try testing.expect(r.ast.nodes[dir].kind == .directive);
    try testing.expectEqual(AST.DirectiveForm.leaf, r.ast.nodes[dir].kind.directive.form);
    try testing.expectEqual(@as(?Node.Id, null), r.ast.nodes[dir].first_child);
}

test "container directive interrupts a paragraph" {
    var r = try parse(testing.allocator, "text\n:::box\nin\n:::\n", directives_on);
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    const para = firstChild(r.ast, r.ast.root);
    try testing.expect(r.ast.nodes[para].kind == .para);
    const dir = r.ast.nodes[para].next_sibling.?;
    try testing.expect(r.ast.nodes[dir].kind == .directive);
}

test "unterminated container directive stays open to end of document" {
    const html = try renderHtml(":::box\nhi\n", directives_on);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<box>\n<p>hi</p>\n</box>\n", html);
}

test "directives OFF: colon-fence lines are ordinary paragraphs" {
    var r = try parse(testing.allocator, ":::note\nhi\n:::\n", .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);
    // Everything is one paragraph; no directive node anywhere.
    for (r.ast.nodes) |n| try testing.expect(n.kind != .directive);
}

test "container directive inside a block quote" {
    const html = try renderHtml("> :::box\n> hi\n> :::\n", directives_on);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<blockquote>\n<box>\n<p>hi</p>\n</box>\n</blockquote>\n", html);
}

test "text directive renders inline as its named element" {
    const html = try renderHtml("See :abbr[HTML]{title=\"HyperText\"} here.\n", directives_on);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<p>See <abbr title=\"HyperText\">HTML</abbr> here.</p>\n", html);
}

test "span: a fenced code block covers its closing fence" {
    const src = "```zig\nconst x = 1;\n```\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const cb = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[cb].kind == .code_block);
    const sp = r.ast.nodes[cb].span;
    // Must include the closing ``` fence, not stop at the last content line —
    // otherwise `edit --delete`/`--replace` orphans the closing fence.
    try testing.expectEqualStrings("```zig\nconst x = 1;\n```", src[sp.start..sp.end]);
}

test "span: an UNterminated fenced code block stops at its last content line" {
    // No closing fence exists, so the span must not overshoot past EOF; it ends
    // at the last content line (the complement of the test above).
    const src = "```zig\nconst x = 1;\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const cb = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[cb].kind == .code_block);
    const sp = r.ast.nodes[cb].span;
    try testing.expectEqualStrings("```zig\nconst x = 1;", src[sp.start..sp.end]);
}

test "span: a list's span covers ALL its items, not just the first" {
    // Regression: a container's span must contain every child. Deleting the
    // whole list depends on this — a first-item-only span would leave `- b\n- c`.
    const src = "- a\n- b\n- c\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const list = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[list].kind == .bullet_list);
    const sp = r.ast.nodes[list].span;
    try testing.expectEqualStrings("- a\n- b\n- c", src[sp.start..sp.end]);
}

test "span: a multi-line list item covers its continuation lines" {
    const src = "- first\n  continued\n- second\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const list = r.ast.nodes[r.ast.root].first_child.?;
    const item = r.ast.nodes[list].first_child.?;
    try testing.expect(r.ast.nodes[item].kind == .list_item);
    const sp = r.ast.nodes[item].span;
    try testing.expectEqualStrings("- first\n  continued", src[sp.start..sp.end]);
}

test "span: a block quote's span covers all its lines" {
    const src = "> line one\n> line two\n";
    var r = try parse(testing.allocator, src, .{});
    defer r.ast.deinit();
    defer r.link_references.deinit(testing.allocator);
    defer r.footnotes.deinit(testing.allocator);

    const bq = r.ast.nodes[r.ast.root].first_child.?;
    try testing.expect(r.ast.nodes[bq].kind == .block_quote);
    const sp = r.ast.nodes[bq].span;
    try testing.expectEqualStrings("> line one\n> line two", src[sp.start..sp.end]);
}
