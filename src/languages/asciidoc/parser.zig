//! AsciiDoc — the parser. Source bytes to twig's shared `AST`, judged by
//! `conformance.zig`'s corpus comparison (`asg.encode(parse(source)) ==
//! case.asg`, structurally) against the vendored TCK corpus and twig's own
//! authored one, exactly the shapes `asg.zig`'s `decode` already proved have
//! somewhere to live.
//!
//! ── Scope of THIS file ──────────────────────────────────────────────────────
//! Judged against a target that is finite and known: the official ASG JSON
//! Schema (vendored as `testdata/asg-schema.json`) enumerates the WHOLE block
//! and inline vocabulary, and this file emits every shape in it — plus the
//! handful of constructs AsciiDoc has and the ASG (draft-01) does not yet
//! model, which `asg.zig` writes as documented extensions rather than
//! crashing on.
//!
//! Blocks: the document header (title, the author and revision lines, the
//! attribute entries below them), front matter, paragraphs in every style the
//! `[style]` line can give them (`[source]`/`[listing]`/`[literal]`/`[pass]`/
//! `[stem]`/`[verse]`/`[quote]`/the five admonitions/anything else as a
//! role), `NOTE: ` admonition paragraphs, indented literal paragraphs, sections
//! by `=` count including level-0 part titles, `[discrete]` headings, every
//! delimited block (`listing`, `literal`, `pass`, `example`, `quote`, `verse`,
//! `sidebar`, `open`, comment, plus Markdown-style backtick fences and `> `
//! quotes, which Asciidoctor also reads), tables (`|===`, with column specs,
//! spans, alignment and header detection), unordered, ordered, callout and
//! description lists with marker-driven nesting, list continuation (`+`) and
//! attached indented literals, block metadata in all its spellings
//! (`[style#id.role%option,key=value]`, `[[id,reftext]]`, `.Title`) and what it
//! unlocks, the four block macros (`image::`, `audio::`, `video::`, `toc::`),
//! body attribute entries, line comments, thematic and page breaks.
//!
//! Inlines: the four spans in both forms (`*strong*`, `_emphasis_`,
//! `` `monospace` ``, `#mark#`, doubled for the unconstrained spelling),
//! superscript and subscript, curved quotes, `[.role]`-prefixed spans and
//! anonymous role spans, links in every spelling (bare URLs, `<url>`,
//! `url[text]`, `link:`, `mailto:`, bare e-mail addresses), cross references
//! (`<<id>>`, `<<id,text>>`, `xref:`), inline images, footnotes, inline
//! anchors, attribute references (`{name}`, with Asciidoctor's intrinsic
//! character attributes resolved), character references (`&amp;`, `&#169;`),
//! passthroughs (`+++raw+++`, `pass:[]`, and the `+literal+` forms), math
//! macros (`stem:[]`), `kbd:[]`/`btn:[]`, hard line breaks (` +`), the
//! `%hardbreaks` option, the text replacements (`(C)`, `--`, `...`, arrows)
//! and backslash escapes.
//!
//! Not modelled: the CSV/DSV table forms, `menu:`/`icon:`/`indexterm:`,
//! `include::`, conditional preprocessor directives, and attribute
//! SUBSTITUTION (a `{name}` reference stays a reference — twig's tree is for
//! editing, and resolving it would delete the author's spelling). What is not
//! recognized degrades to LITERAL SOURCE TEXT, which is the property the
//! `format.zig` registry entry rests on: an unhandled `menu:File[Save]`
//! renders as those characters, visibly unhandled, rather than as a mangled
//! tree.
//!
//! ── The shape mapping, and where the AsciiDoc-only facts go ─────────────────
//! Everything the shared vocabulary has a kind for takes it: a `[NOTE]` block
//! is the container NAMED `note` — the same node a Markdown `:::note` and an
//! rST `.. note::` produce, which is the whole point of a shared tree — a
//! `[verse]` is a `line_block`, a `pass` block is a `raw_block`, a description
//! list is a `definition_list`, an `image::` macro is a paragraph holding an
//! `image`, a body `:name: value` entry is a `substitution` definition and a
//! `{name}` reference its `substitution_reference` use. Block metadata lands
//! in `attrs` as the document's REAL attributes (`id`, `class` for roles and
//! unrecognized styles, `title`, `options`, every named entry) — that is the
//! channel `languages/html/serializer.zig` renders, so what lands there has
//! to be something the author wrote, never codec bookkeeping. The ASG's own
//! bookkeeping (`form`, `delimiter`, a block's `metadata` object, a span's
//! `form`, a list's `marker`) is DERIVED from the node's own source by
//! `asg.zig` on the way out, which is why `matchMetaLine`, `AttrIter` and the
//! author-line scanner are `pub`: the codec re-reads a block's leading lines
//! with the very functions that parsed them.
//!
//! ── Position matters here in a way it didn't for rST's first slice ────────
//! The TCK's ASG carries a `location` on every node and the conformance
//! harness compares through `asg.encode`, which writes it back — so every
//! span this file sets is load-bearing. A block's span starts at its FIRST
//! METADATA LINE (`.Title`, `[attrs]`, `[[id]]`) and runs to its last content
//! line; that is what lets the codec find the metadata again, and it is also
//! what an editor deleting a block wants removed.
//!
//! ── Why this shape ───────────────────────────────────────────────────────
//! Bottom-up onto `AST.Builder`, the posture `languages/rst/parser.zig` took.
//! Section nesting is spelled directly by the marker's `=` count, so
//! `parseSection` just recurses and `parseSectionsLoop` closes back to a
//! parent by comparing level numbers. List nesting is Asciidoctor's own rule —
//! an item whose marker differs from every list on the stack opens a nested
//! list, one whose marker matches an ancestor closes back to it — carried on
//! `list_stack` rather than on indentation, which AsciiDoc ignores.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../../ast/ast.zig");
const Node = AST.Node;
const Builder = AST.Builder;
const Span = @import("../../span.zig");
const Document = @import("../../document.zig");
const entities = @import("../markdown/entities.zig");

pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!Document {
    var p = try Parser.init(allocator, source);
    defer p.deinit();
    const root = try p.parseDocument();
    return p.b.finishDocument(source, root);
}

/// The TCK's `inline`-level entry point: `source` (a single line, e.g.
/// `"*s*\n"`) is scanned for inline markup directly, with no document/block
/// structure at all, and the resulting nodes are wrapped in a synthetic
/// `.doc` root — mirroring `asg.decode`'s own `.inlines` case exactly, so
/// `asg.encode(&doc, .inlines, ...)` (which reads straight through that
/// wrapper) can print it back.
pub fn parseInlineList(allocator: Allocator, source: []const u8) Allocator.Error!Document {
    var b = Builder.init(allocator);
    errdefer b.deinit();
    var footnotes: u32 = 0;
    const text = std.mem.trimEnd(u8, source, "\n");
    const ids = try parseInlines(.{ .b = &b, .footnotes = &footnotes }, text, 0);
    defer allocator.free(ids);
    const root = try b.addContainer(.doc, ids);
    return b.finishDocument(source, root);
}

// ── shared source scanners (used by asg.zig too) ─────────────────────────────

/// One classified block-metadata line. See `matchMetaLine`.
pub const MetaLine = union(enum) {
    /// `[…]` — the interior, brackets excluded.
    attrs: []const u8,
    /// `[[id]]` / `[[id,reftext]]`.
    anchor: struct { id: []const u8, reftext: ?[]const u8 },
    /// `.Title` — the text after the dot.
    title: []const u8,
};

/// Classify `line` (one source line, newline excluded) as block metadata, or
/// `null`. Asciidoctor's own three rules: a block attribute line is `[…]` whose
/// interior is empty or starts with a name/shorthand byte; a block anchor is
/// `[[…]]`; a block title is a `.` followed by anything but whitespace or a
/// second dot. All three must sit at column 0.
pub fn matchMetaLine(line: []const u8) ?MetaLine {
    const t = std.mem.trimEnd(u8, line, " \t");
    if (t.len < 2) return null;
    if (t[0] == '[') {
        if (t[t.len - 1] != ']') return null;
        if (t.len >= 4 and t[1] == '[' and t[t.len - 2] == ']') {
            const inner = t[2 .. t.len - 2];
            if (inner.len == 0 or std.mem.indexOfAny(u8, inner, "[]") != null) return null;
            const comma = std.mem.indexOfScalar(u8, inner, ',');
            const id = if (comma) |c| inner[0..c] else inner;
            if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t") != null) return null;
            return .{ .anchor = .{ .id = id, .reftext = if (comma) |c| std.mem.trim(u8, inner[c + 1 ..], " \t") else null } };
        }
        const inner = t[1 .. t.len - 1];
        if (inner.len == 0) return .{ .attrs = inner };
        const first = inner[0];
        const ok = std.ascii.isAlphanumeric(first) or std.mem.indexOfScalar(u8, "_.#%{,\"'", first) != null;
        if (!ok) return null;
        return .{ .attrs = inner };
    }
    if (t[0] == '.' and t[1] != ' ' and t[1] != '\t' and t[1] != '.') return .{ .title = t[1..] };
    return null;
}

/// One entry of a `[…]` attribute list — positional (`key == null`, `index`
/// 1-based) or named. `value` has its quotes removed.
pub const AttrEntry = struct { key: ?[]const u8, value: []const u8, index: usize };

/// Walks an attribute list's interior entry by entry: comma-separated, each
/// `key=value` or positional, values optionally `"`- or `'`-quoted (a comma
/// inside quotes does not split). Allocation-free, so the codec can stream it.
pub const AttrIter = struct {
    rest: []const u8,
    index: usize = 0,
    done: bool = false,

    pub fn init(interior: []const u8) AttrIter {
        return .{ .rest = interior };
    }

    pub fn next(self: *AttrIter) ?AttrEntry {
        if (self.done) return null;
        var raw: []const u8 = undefined;
        // Find the entry's end: the first comma outside quotes.
        var i: usize = 0;
        var quote: u8 = 0;
        while (i < self.rest.len) : (i += 1) {
            const c = self.rest[i];
            if (quote != 0) {
                if (c == '\\' and i + 1 < self.rest.len) {
                    i += 1;
                } else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                // Only a quote that starts a value (after `=` or at entry start) quotes.
                const before = std.mem.trim(u8, self.rest[0..i], " \t");
                if (before.len == 0 or before[before.len - 1] == '=') quote = c;
                continue;
            }
            if (c == ',') break;
        }
        raw = self.rest[0..i];
        if (i < self.rest.len) {
            self.rest = self.rest[i + 1 ..];
        } else {
            self.rest = "";
            self.done = true;
        }
        self.index += 1;
        const entry = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, entry, '=');
        if (eq) |e| {
            const key = std.mem.trim(u8, entry[0..e], " \t");
            if (key.len > 0 and isAttrName(key)) {
                return .{ .key = key, .value = unquote(std.mem.trim(u8, entry[e + 1 ..], " \t")), .index = self.index };
            }
        }
        return .{ .key = null, .value = unquote(entry), .index = self.index };
    }
};

fn isAttrName(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
    return v;
}

/// One piece of the first positional attribute's shorthand: `style#id.role%option`.
pub const ShorthandPiece = struct { kind: enum { style, id, role, option }, text: []const u8 };

/// Splits the block-style shorthand (`quote#id.role1.role2%opt`). The style is
/// whatever precedes the first sigil; an empty style piece is not reported.
pub const ShorthandIter = struct {
    rest: []const u8,
    first: bool = true,

    pub fn init(s: []const u8) ShorthandIter {
        return .{ .rest = s };
    }

    pub fn next(self: *ShorthandIter) ?ShorthandPiece {
        while (true) {
            if (self.rest.len == 0) return null;
            var kind: @TypeOf(@as(ShorthandPiece, undefined).kind) = .style;
            var start: usize = 0;
            if (!self.first or std.mem.indexOfScalar(u8, "#.%", self.rest[0]) != null) {
                kind = switch (self.rest[0]) {
                    '#' => .id,
                    '.' => .role,
                    '%' => .option,
                    else => .style,
                };
                if (kind != .style) start = 1;
            }
            self.first = false;
            var end = start;
            while (end < self.rest.len and std.mem.indexOfScalar(u8, "#.%", self.rest[end]) == null) end += 1;
            const text = self.rest[start..end];
            self.rest = self.rest[end..];
            if (text.len == 0) continue;
            return .{ .kind = kind, .text = text };
        }
    }
};

/// One author from the header's author line. Names are as written with `_`
/// turned back into spaces, the way Asciidoctor reads them.
pub const Author = struct {
    fullname: []const u8,
    firstname: []const u8,
    middlename: ?[]const u8,
    lastname: ?[]const u8,
    email: ?[]const u8,

    pub fn initials(self: Author, buf: *[3]u8) []const u8 {
        var n: usize = 0;
        buf[n] = self.firstname[0];
        n += 1;
        if (self.middlename) |m| {
            buf[n] = m[0];
            n += 1;
        }
        if (self.lastname) |l| {
            buf[n] = l[0];
            n += 1;
        }
        return buf[0..n];
    }
};

/// Walks the `;`-separated authors of a header author line. Each author is up
/// to three space-separated names and an optional `<address>`; a line that
/// does not fit (four or more names) yields one author whose full name is the
/// whole text and whose first/last names are its first and last words.
pub const AuthorIter = struct {
    rest: []const u8,
    done: bool = false,

    pub fn init(line: []const u8) AuthorIter {
        return .{ .rest = line };
    }

    pub fn next(self: *AuthorIter) ?Author {
        while (!self.done) {
            var piece: []const u8 = undefined;
            if (std.mem.indexOfScalar(u8, self.rest, ';')) |semi| {
                piece = self.rest[0..semi];
                self.rest = self.rest[semi + 1 ..];
            } else {
                piece = self.rest;
                self.done = true;
            }
            piece = std.mem.trim(u8, piece, " \t");
            if (piece.len == 0) continue;
            var email: ?[]const u8 = null;
            var names = piece;
            if (std.mem.indexOfScalar(u8, piece, '<')) |lt| {
                if (std.mem.indexOfScalarPos(u8, piece, lt, '>')) |gt| {
                    email = std.mem.trim(u8, piece[lt + 1 .. gt], " \t");
                    names = std.mem.trim(u8, piece[0..lt], " \t");
                }
            }
            if (names.len == 0) continue;
            var words: [4][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, names, " \t");
            while (it.next()) |w| {
                if (n < 4) words[n] = w;
                n += 1;
            }
            if (n == 0) continue;
            if (n > 3) {
                return .{ .fullname = names, .firstname = words[0], .middlename = null, .lastname = words[n - 1], .email = email };
            }
            return .{
                .fullname = names,
                .firstname = words[0],
                .middlename = if (n == 3) words[1] else null,
                .lastname = if (n >= 2) words[n - 1] else null,
                .email = email,
            };
        }
        return null;
    }
};

/// `true` for a line of the header (after the title) that Asciidoctor reads
/// as the author line: non-blank, not an attribute entry, not a comment.
pub fn isAuthorLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) return false;
    if (t[0] == ':') return false;
    if (std.mem.startsWith(u8, t, "//")) return false;
    return true;
}

/// One `:name: value` attribute entry. `value` is trimmed of surrounding
/// whitespace but not internally; a bare `:name:` yields an empty but
/// NON-null value, matching the TCK's own `{"toc": ""}`, while the two
/// negated spellings (`:!name:` and `:name!:`) yield `null` — the ASG's
/// document `attributes` map admits null for exactly this.
pub fn matchAttrEntry(line: []const u8) ?AST.KeyVal {
    const t = line;
    if (t.len < 2 or t[0] != ':') return null;
    var j: usize = 1;
    while (j < t.len and t[j] != ':') : (j += 1) {}
    if (j >= t.len or j == 1) return null;
    var key = t[1..j];
    var unset = false;
    if (key[0] == '!') {
        key = key[1..];
        unset = true;
    } else if (key[key.len - 1] == '!') {
        key = key[0 .. key.len - 1];
        unset = true;
    }
    if (key.len == 0) return null;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return null;
    }
    // `::` right after the name (`term:: desc`) is a description list, not an entry.
    if (j + 1 < t.len and t[j + 1] == ':') return null;
    if (j + 1 < t.len and t[j + 1] != ' ' and t[j + 1] != '\t') return null;
    return .{
        .key = key,
        .value = if (unset) null else std.mem.trim(u8, t[j + 1 ..], " \t"),
    };
}

/// The five admonition labels, as `NOTE: text` spells them.
pub const ADMONITIONS = [_][]const u8{ "NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION" };

/// The lowercase container name an admonition label or style becomes.
pub fn admonitionName(label: []const u8) ?[]const u8 {
    inline for (ADMONITIONS, .{ "note", "tip", "important", "warning", "caution" }) |l, n| {
        if (std.mem.eql(u8, label, l)) return n;
    }
    return null;
}

/// The block styles that name a LEAF block in the ASG (`[listing]` on a
/// paragraph, `[source]` on an open block, …).
pub fn isLeafStyle(style: []const u8) bool {
    inline for (.{ "listing", "source", "literal", "pass", "stem", "latexmath", "asciimath", "verse" }) |s| {
        if (std.mem.eql(u8, style, s)) return true;
    }
    return false;
}

/// The ASG leaf-block name a style spells — `source`, `latexmath` and
/// `asciimath` are aliases the ASG does not distinguish.
pub fn leafNameForStyle(style: []const u8) []const u8 {
    if (std.mem.eql(u8, style, "source")) return "listing";
    if (std.mem.eql(u8, style, "latexmath") or std.mem.eql(u8, style, "asciimath")) return "stem";
    return style;
}

/// Block styles that turn a paragraph or an open block into a PARENT block.
pub fn isParentStyle(style: []const u8) bool {
    inline for (.{ "quote", "sidebar", "example", "abstract", "partintro", "open" }) |s| {
        if (std.mem.eql(u8, style, s)) return true;
    }
    return admonitionName(style) != null;
}

/// A `|===` table delimiter: the bar and three or more `=`.
pub fn isTableDelimiterLine(t: []const u8) bool {
    if (t.len < 4 or t[0] != '|') return false;
    for (t[1..]) |c| if (c != '=') return false;
    return true;
}

/// A Markdown-style fence line: three or more backticks, then an optional
/// info string.
pub fn matchFenceLine(t: []const u8) ?struct { fence: []const u8, info: []const u8 } {
    if (t.len < 3 or t[0] != '`') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == '`') n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, t[n..], " \t");
    if (std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .fence = t[0..n], .info = info };
}

/// The marker of a list item line, classified. See `Parser.matchListMarker`
/// for the line-level entry; this is the text-level half, on a line whose
/// leading whitespace is already stripped, so the codec can call it too.
pub const ListMarker = struct {
    kind: Kind,
    /// The marker's bytes as written (`**`, `1.`, `<1>`, `::`).
    text: []const u8,
    /// Where the principal text begins, relative to the line's start
    /// (after the marker and the spaces that follow it). For a description
    /// list this is the description on the same line, or `line.len`.
    text_at: usize,
    numbering: AST.ListNumbering = .decimal,
    start: ?u32 = null,
    delim: Document.Spelling.OrderedDelim = .period,
    /// Description lists only: the term and where it starts on the line.
    term: []const u8 = "",
    term_at: usize = 0,

    pub const Kind = enum { unordered, ordered, callout, description };

    /// The identity two markers are compared by when deciding whether a line
    /// continues, nests under, or closes a list: the marker text itself,
    /// except that every explicit ordinal of one family (`1.`, `2.`, `c.`)
    /// is the same list.
    pub fn key(self: ListMarker) []const u8 {
        return switch (self.kind) {
            .unordered, .description => self.text,
            .callout => "<1>",
            .ordered => if (self.text[0] == '.') self.text else switch (self.numbering) {
                .decimal => "1.",
                .lower_alpha => "a.",
                .upper_alpha => "A.",
                .lower_roman => "i)",
                .upper_roman => "I)",
            },
        };
    }
};

fn markerTextEnd(t: []const u8, marker_end: usize) ?usize {
    // At least one space, then something that is not whitespace.
    if (marker_end >= t.len or t[marker_end] != ' ') return null;
    var j = marker_end;
    while (j < t.len and t[j] == ' ') j += 1;
    if (j >= t.len) return null;
    return j;
}

fn romanValue(s: []const u8) ?u32 {
    var total: u32 = 0;
    var prev: u32 = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        const v: u32 = switch (std.ascii.toLower(s[i])) {
            'i' => 1,
            'v' => 5,
            'x' => 10,
            else => return null,
        };
        if (v < prev) total -= v else total += v;
        prev = v;
    }
    return total;
}

/// Classify a bare marker as written (`.`, `3.`, `b.`, `iv)`, `<1>`, `*`,
/// `::`) — `matchListMarkerText` on the marker followed by one word, for a
/// caller that holds the marker alone.
pub fn classifyMarker(marker: []const u8) ?ListMarker {
    var buf: [40]u8 = undefined;
    if (marker.len + 2 > buf.len) return null;
    @memcpy(buf[0..marker.len], marker);
    buf[marker.len] = ' ';
    buf[marker.len + 1] = 'x';
    var m = matchListMarkerText(buf[0 .. marker.len + 2]) orelse return null;
    m.text = marker;
    return m;
}

/// Match a list marker at the start of `t` (leading whitespace already
/// stripped): `*`{1,5} or `-`, `.`{1,5} / `N.` / `a.` / `i)`, `<N>` / `<.>`,
/// or a description term followed by `::`…`::::` / `;;`.
pub fn matchListMarkerText(t: []const u8) ?ListMarker {
    if (t.len == 0) return null;
    // Unordered.
    if (t[0] == '*') {
        var n: usize = 0;
        while (n < t.len and t[n] == '*') n += 1;
        if (n <= 5) if (markerTextEnd(t, n)) |at| return .{ .kind = .unordered, .text = t[0..n], .text_at = at };
    } else if (t[0] == '-') {
        if (markerTextEnd(t, 1)) |at| return .{ .kind = .unordered, .text = t[0..1], .text_at = at };
    } else if (t[0] == '.') {
        var n: usize = 0;
        while (n < t.len and t[n] == '.') n += 1;
        if (n <= 5) if (markerTextEnd(t, n)) |at| return .{ .kind = .ordered, .text = t[0..n], .text_at = at };
    } else if (t[0] == '<') {
        var j: usize = 1;
        if (j < t.len and t[j] == '.') {
            j += 1;
        } else {
            while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
            if (j == 1) return null;
        }
        if (j < t.len and t[j] == '>') {
            if (markerTextEnd(t, j + 1)) |at| return .{ .kind = .callout, .text = t[0 .. j + 1], .text_at = at };
        }
    }
    // Explicit ordinals: digits+`.`, letter+`.`, roman+`)`.
    if (std.ascii.isDigit(t[0])) {
        var j: usize = 0;
        while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
        if (j < t.len and t[j] == '.' and j <= 9) {
            if (markerTextEnd(t, j + 1)) |at| {
                const n = std.fmt.parseInt(u32, t[0..j], 10) catch 1;
                return .{ .kind = .ordered, .text = t[0 .. j + 1], .text_at = at, .start = n };
            }
        }
    } else if (std.ascii.isAlphabetic(t[0]) and t.len >= 2) {
        if (t[1] == '.') {
            if (markerTextEnd(t, 2)) |at| {
                const lower = std.ascii.isLower(t[0]);
                return .{
                    .kind = .ordered,
                    .text = t[0..2],
                    .text_at = at,
                    .numbering = if (lower) .lower_alpha else .upper_alpha,
                    .start = @as(u32, std.ascii.toLower(t[0]) - 'a' + 1),
                };
            }
        }
        var j: usize = 0;
        while (j < t.len and std.mem.indexOfScalar(u8, "ivxIVX", t[j]) != null) j += 1;
        if (j > 0 and j < t.len and t[j] == ')') {
            if (markerTextEnd(t, j + 1)) |at| {
                if (romanValue(t[0..j])) |v| {
                    return .{
                        .kind = .ordered,
                        .text = t[0 .. j + 1],
                        .text_at = at,
                        .numbering = if (std.ascii.isLower(t[0])) .lower_roman else .upper_roman,
                        .start = v,
                        .delim = .paren_after,
                    };
                }
            }
        }
    }
    return matchDescriptionTerm(t);
}

fn matchDescriptionTerm(t: []const u8) ?ListMarker {
    if (t.len < 3 or std.mem.startsWith(u8, t, "//")) return null;
    if (t[0] == ':' and matchAttrEntry(t) != null) return null;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c != ':' and c != ';') continue;
        var n: usize = i;
        while (n < t.len and t[n] == c) n += 1;
        const run = n - i;
        const is_marker = (c == ':' and run >= 2 and run <= 4) or (c == ';' and run == 2);
        if (!is_marker) {
            i = n - 1;
            continue;
        }
        if (n < t.len and t[n] != ' ' and t[n] != '\t') {
            i = n - 1;
            continue;
        }
        const term = std.mem.trim(u8, t[0..i], " \t");
        if (term.len == 0) return null;
        var text_at = n;
        while (text_at < t.len and (t[text_at] == ' ' or t[text_at] == '\t')) text_at += 1;
        var term_at: usize = 0;
        while (term_at < i and (t[term_at] == ' ' or t[term_at] == '\t')) term_at += 1;
        return .{ .kind = .description, .text = t[i..n], .text_at = text_at, .term = term, .term_at = term_at };
    }
    return null;
}

// ── line-level types ────────────────────────────────────────────────────────

/// One line of source, as a byte range excluding its terminating `\n`.
const LineInfo = struct { start: usize, end: usize };

/// A recognized `=`-prefixed title line — a document title (`level == 0`,
/// only matched at the document's first non-blank line) or a section title
/// (`level >= 1`, matched anywhere at column 0). A trailing ` [[id]]` anchor
/// is peeled off into `anchor_id`.
const HeadingMatch = struct {
    level: i32,
    text: []const u8,
    text_span: Span,
    span_start: usize,
    marker_end: usize,
    /// End of the trimmed title line — past a trailing `[[anchor]]`, which
    /// belongs to the heading even though it is not title text.
    title_end: usize,
    next_line: usize,
    anchor_id: ?[]const u8 = null,
};

const BlockResult = struct { id: ?Node.Id, next: usize, start_offset: usize, end_offset: usize };

/// A run of parsed blocks, plus the source extent they cover.
const FlatResult = struct { items: []Node.Id, stopped_at: usize, first_start: usize = 0, last_end: usize = 0 };

/// One row of the delimited-block table.
const Delimiter = struct {
    char: u8,
    name: []const u8,
    content: enum { verbatim, compound, dropped },

    const open: Delimiter = .{ .char = '-', .name = "open", .content = .compound };
};

const DELIMITERS = [_]Delimiter{
    .{ .char = '-', .name = "listing", .content = .verbatim },
    .{ .char = '.', .name = "literal", .content = .verbatim },
    .{ .char = '+', .name = "pass", .content = .verbatim },
    .{ .char = '=', .name = "example", .content = .compound },
    .{ .char = '_', .name = "quote", .content = .compound },
    .{ .char = '*', .name = "sidebar", .content = .compound },
    .{ .char = '/', .name = "comment", .content = .dropped },
};

const ROOT_LEVEL: i32 = -1;

/// Block metadata waiting for the block it belongs to. See the module doc for
/// where each piece lands.
const Pending = struct {
    start: ?usize = null,
    attr_start: ?usize = null,
    attr_end: usize = 0,
    title: ?[]const u8 = null,
    id: ?[]const u8 = null,
    reftext: ?[]const u8 = null,
    style: ?[]const u8 = null,
    roles: std.ArrayList([]const u8) = .empty,
    options: std.ArrayList([]const u8) = .empty,
    /// Positional attributes from the second onward (`positional[0]` is `$2`);
    /// `null` once a block has consumed one into a semantic field.
    positional: std.ArrayList(?[]const u8) = .empty,
    named: std.ArrayList(AST.KeyVal) = .empty,

    fn deinit(self: *Pending, allocator: Allocator) void {
        self.roles.deinit(allocator);
        self.options.deinit(allocator);
        self.positional.deinit(allocator);
        self.named.deinit(allocator);
    }

    fn clear(self: *Pending) void {
        self.start = null;
        self.attr_start = null;
        self.attr_end = 0;
        self.title = null;
        self.id = null;
        self.reftext = null;
        self.style = null;
        self.roles.clearRetainingCapacity();
        self.options.clearRetainingCapacity();
        self.positional.clearRetainingCapacity();
        self.named.clearRetainingCapacity();
    }

    fn active(self: *const Pending) bool {
        return self.start != null;
    }

    fn hasOption(self: *const Pending, name: []const u8) bool {
        for (self.options.items) |o| if (std.mem.eql(u8, o, name)) return true;
        return false;
    }

    fn get(self: *const Pending, key: []const u8) ?[]const u8 {
        for (self.named.items) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value;
        return null;
    }

    /// The `n`th positional (2-based), consumed.
    fn takePositional(self: *Pending, n: usize) ?[]const u8 {
        const idx = n - 2;
        if (idx >= self.positional.items.len) return null;
        const v = self.positional.items[idx];
        self.positional.items[idx] = null;
        return v;
    }

    fn takeStyle(self: *Pending) ?[]const u8 {
        const s = self.style;
        self.style = null;
        return s;
    }

    fn styleIs(self: *const Pending, name: []const u8) bool {
        const s = self.style orelse return false;
        return std.mem.eql(u8, s, name);
    }
};

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    lines: []const LineInfo,
    b: Builder,
    pending: Pending = .{},
    footnote_count: u32 = 0,
    /// Marker keys of every list currently open, innermost last. Non-empty
    /// means "inside a list", where a description term line ends a paragraph
    /// (it starts the next item) although it does not at the top level.
    list_stack: std.ArrayList([]const u8) = .empty,
    /// Scratch for attribute entries while a block is being built.
    attr_buf: std.ArrayList(AST.KeyVal) = .empty,
    class_buf: std.ArrayList(u8) = .empty,
    /// Keys minted at parse time (`author_2`, `$3`); `setAttrs` copies them,
    /// so they live only until the parser is torn down.
    owned_keys: std.ArrayList([]u8) = .empty,

    fn init(allocator: Allocator, source: []const u8) Allocator.Error!Parser {
        return .{ .allocator = allocator, .source = source, .lines = try computeLines(allocator, source), .b = Builder.init(allocator) };
    }

    fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
        self.b.deinit();
        self.pending.deinit(self.allocator);
        self.list_stack.deinit(self.allocator);
        self.attr_buf.deinit(self.allocator);
        self.class_buf.deinit(self.allocator);
        for (self.owned_keys.items) |k| self.allocator.free(k);
        self.owned_keys.deinit(self.allocator);
    }

    fn inlineCtx(self: *Parser) InlineCtx {
        return .{ .b = &self.b, .footnotes = &self.footnote_count };
    }

    // ── line helpers ─────────────────────────────────────────────────────

    fn lineText(self: *const Parser, i: usize) []const u8 {
        return self.source[self.lines[i].start..self.lines[i].end];
    }

    fn lineTrimmed(self: *const Parser, i: usize) []const u8 {
        return std.mem.trimEnd(u8, self.lineText(i), " \t");
    }

    fn leadingSpaces(self: *const Parser, i: usize) usize {
        const t = self.lineText(i);
        var n: usize = 0;
        while (n < t.len and (t[n] == ' ' or t[n] == '\t')) n += 1;
        return n;
    }

    fn isBlankLine(self: *const Parser, i: usize) bool {
        for (self.lineText(i)) |c| {
            if (c != ' ' and c != '\t') return false;
        }
        return true;
    }

    fn firstNonBlankLine(self: *const Parser, from: usize) usize {
        var i = from;
        while (i < self.lines.len and self.isBlankLine(i)) i += 1;
        return i;
    }

    // ── title / heading recognition ─────────────────────────────────────

    fn matchHeadingLine(self: *const Parser, i: usize) ?HeadingMatch {
        if (i >= self.lines.len) return null;
        if (self.leadingSpaces(i) != 0) return null;
        const t = self.lineText(i);
        var n: usize = 0;
        while (n < t.len and t[n] == '=') : (n += 1) {}
        if (n == 0 or n > 6 or n >= t.len or t[n] != ' ') return null;
        var text = std.mem.trim(u8, t[n + 1 ..], " \t");
        if (text.len == 0) return null;
        const title_end = self.lines[i].start + std.mem.trimEnd(u8, t, " \t").len;
        // A trailing anchor: `== Title [[id]]`.
        var anchor: ?[]const u8 = null;
        if (std.mem.endsWith(u8, text, "]]")) {
            if (std.mem.lastIndexOf(u8, text, " [[")) |at| {
                const inner = text[at + 3 .. text.len - 2];
                if (inner.len > 0 and std.mem.indexOfAny(u8, inner, "[] \t") == null) {
                    anchor = if (std.mem.indexOfScalar(u8, inner, ',')) |c| inner[0..c] else inner;
                    text = std.mem.trimEnd(u8, text[0..at], " \t");
                }
            }
        }
        const text_start = self.lines[i].start + n + 1 + (std.mem.indexOf(u8, t[n + 1 ..], text) orelse 0);
        return .{
            .level = @intCast(n - 1),
            .text = text,
            .text_span = Span.init(text_start, text_start + text.len),
            .span_start = self.lines[i].start,
            .marker_end = self.lines[i].start + n + 1,
            .title_end = title_end,
            .next_line = i + 1,
            .anchor_id = anchor,
        };
    }

    // ── block-start recognition ─────────────────────────────────────────

    fn matchDelimiter(self: *const Parser, i: usize) ?struct { delim: Delimiter, text: []const u8 } {
        if (i >= self.lines.len) return null;
        if (self.leadingSpaces(i) != 0) return null;
        const t = self.lineTrimmed(i);
        if (t.len < 2) return null;
        if (std.mem.eql(u8, t, "--")) return .{ .delim = Delimiter.open, .text = t };
        if (t.len < 4) return null;
        for (t[1..]) |c| {
            if (c != t[0]) return null;
        }
        for (DELIMITERS) |d| {
            if (d.char == t[0]) return .{ .delim = d, .text = t };
        }
        return null;
    }

    fn matchesDelim(self: *const Parser, i: usize, opening: []const u8) bool {
        if (self.leadingSpaces(i) != 0) return false;
        return std.mem.eql(u8, self.lineTrimmed(i), opening);
    }

    fn matchFence(self: *const Parser, i: usize) ?struct { fence: []const u8, info: []const u8 } {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return null;
        const m = matchFenceLine(self.lineTrimmed(i)) orelse return null;
        return .{ .fence = m.fence, .info = m.info };
    }

    fn isTableOpen(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        return isTableDelimiterLine(self.lineTrimmed(i));
    }

    fn matchListMarker(self: *const Parser, i: usize) ?ListMarker {
        if (i >= self.lines.len) return null;
        const t = self.lineText(i);
        const indent = self.leadingSpaces(i);
        var m = matchListMarkerText(t[indent..]) orelse return null;
        // Description terms sit at column 0 only; the other markers may be indented.
        if (m.kind == .description and indent != 0) return null;
        m.text_at += indent;
        m.term_at += indent;
        return m;
    }

    /// A list marker that is NOT a description term — what may interrupt a
    /// paragraph, and what a principal-text scan stops at.
    fn isListLine(self: *const Parser, i: usize) bool {
        const m = self.matchListMarker(i) orelse return false;
        return m.kind != .description;
    }

    fn isContinuation(self: *const Parser, i: usize) bool {
        return i < self.lines.len and std.mem.eql(u8, self.lineTrimmed(i), "+");
    }

    /// `'''`, and Asciidoctor's Markdown-style `---`, `***`, `- - -`, `* * *`.
    fn isThematicBreak(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        const t = self.lineTrimmed(i);
        if (t.len < 3) return false;
        var all_quotes = true;
        for (t) |c| {
            if (c != '\'') all_quotes = false;
        }
        if (all_quotes) return true;
        inline for (.{ "---", "***", "- - -", "* * *" }) |s| {
            if (std.mem.eql(u8, t, s)) return true;
        }
        return false;
    }

    fn isPageBreak(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        return std.mem.eql(u8, self.lineTrimmed(i), "<<<");
    }

    fn isLineComment(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        const t = self.lineText(i);
        return t.len >= 2 and t[0] == '/' and t[1] == '/' and !(t.len >= 4 and t[2] == '/' and t[3] == '/');
    }

    fn isMetaLine(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        return matchMetaLine(self.lineText(i)) != null;
    }

    /// `[…]` and `[[…]]` lines: the two metadata spellings that interrupt a
    /// paragraph (a `.Title` line does not — a sentence may start with a dot).
    fn isAttrOrAnchorLine(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        const m = matchMetaLine(self.lineText(i)) orelse return false;
        return m != .title;
    }

    fn matchBlockMacro(self: *const Parser, i: usize) ?BlockMacro {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return null;
        return matchBlockMacroText(self.lineTrimmed(i));
    }

    fn isQuoteLine(self: *const Parser, i: usize) bool {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return false;
        const t = self.lineText(i);
        return t.len >= 1 and t[0] == '>';
    }

    fn matchAdmonitionPara(self: *const Parser, i: usize) ?struct { name: []const u8, text_at: usize } {
        if (i >= self.lines.len or self.leadingSpaces(i) != 0) return null;
        const t = self.lineText(i);
        for (ADMONITIONS) |label| {
            if (t.len > label.len + 2 and std.mem.startsWith(u8, t, label) and t[label.len] == ':' and t[label.len + 1] == ' ') {
                var at = label.len + 2;
                while (at < t.len and t[at] == ' ') at += 1;
                if (at >= t.len) return null;
                return .{ .name = admonitionName(label).?, .text_at = at };
            }
        }
        return null;
    }

    /// What ends a paragraph (or a list item's principal text) other than a
    /// blank line.
    fn isBlockStart(self: *const Parser, i: usize) bool {
        const list_line = if (self.list_stack.items.len > 0) self.matchListMarker(i) != null else self.isListLine(i);
        return self.matchHeadingLine(i) != null or self.matchDelimiter(i) != null or
            self.matchFence(i) != null or self.isTableOpen(i) or
            list_line or self.isThematicBreak(i) or self.isPageBreak(i) or
            self.isLineComment(i) or self.isAttrOrAnchorLine(i) or
            self.matchBlockMacro(i) != null or self.isContinuation(i);
    }

    // ── the top-level document scan ─────────────────────────────────────

    fn skipPreamble(self: *const Parser, from: usize) usize {
        var i = from;
        while (i < self.lines.len) {
            if (self.isBlankLine(i) or self.isLineComment(i)) {
                i += 1;
                continue;
            }
            if (self.matchDelimiter(i)) |d| if (d.delim.content == .dropped) {
                var j = i + 1;
                while (j < self.lines.len and !self.matchesDelim(j, d.text)) j += 1;
                i = if (j < self.lines.len) j + 1 else j;
                continue;
            };
            break;
        }
        return i;
    }

    fn parseFrontMatter(self: *Parser) Allocator.Error!?struct { id: Node.Id, next: usize } {
        if (self.lines.len < 2 or !std.mem.eql(u8, self.lineTrimmed(0), "---")) return null;
        var j: usize = 1;
        while (j < self.lines.len and !std.mem.eql(u8, self.lineTrimmed(j), "---")) j += 1;
        if (j >= self.lines.len) return null;
        const content = if (j > 1) Span.init(self.lines[1].start, self.lines[j - 1].end) else Span.init(self.lines[1].start, self.lines[1].start);
        const text = self.source[content.start..content.end];
        const id = try self.b.addLeaf(.{ .metadata = .{ .lang = "yaml", .text = text } });
        self.b.setSpan(id, Span.init(self.lines[0].start, self.lines[j].end));
        if (j > 1) self.b.setContentSpan(id, content);
        return .{ .id = id, .next = j + 1 };
    }

    fn parseDocument(self: *Parser) Allocator.Error!Node.Id {
        var children: std.ArrayList(Node.Id) = .empty;
        defer children.deinit(self.allocator);
        var start_offset: usize = 0;
        var end_offset: usize = 0;
        var have_start = false;

        var body_start_line: usize = 0;
        if (try self.parseFrontMatter()) |fm| {
            try children.append(self.allocator, fm.id);
            start_offset = self.b.spans.items[fm.id].start;
            end_offset = self.b.spans.items[fm.id].end;
            have_start = true;
            body_start_line = fm.next;
        }

        // The header, if any, is at the first non-blank, non-comment line.
        body_start_line = self.skipPreamble(body_start_line);
        const doc_title: ?HeadingMatch = if (self.matchHeadingLine(body_start_line)) |hm|
            (if (hm.level == 0) hm else null)
        else
            null;

        var header_id: ?Node.Id = null;
        var attrs_id: ?Node.Id = null;
        if (doc_title) |dt| {
            var line = dt.next_line;
            var header_end_offset = self.lines[body_start_line].end;
            self.attr_buf.clearRetainingCapacity();

            // The author line, then the revision line, then attribute entries.
            if (line < self.lines.len and !self.isBlankLine(line) and isAuthorLine(self.lineText(line)) and matchMetaLine(self.lineText(line)) == null) {
                try self.collectAuthors(self.lineText(line));
                header_end_offset = self.lines[line].end;
                line += 1;
                if (line < self.lines.len and !self.isBlankLine(line) and isAuthorLine(self.lineText(line)) and matchAttrEntry(self.lineText(line)) == null) {
                    try self.collectRevision(self.lineText(line));
                    header_end_offset = self.lines[line].end;
                    line += 1;
                }
            }
            while (line < self.lines.len and !self.isBlankLine(line)) {
                if (self.isLineComment(line)) {
                    line += 1;
                    continue;
                }
                const entry = matchAttrEntry(self.lineText(line)) orelse break;
                try self.attr_buf.append(self.allocator, entry);
                header_end_offset = self.lines[line].end;
                line += 1;
            }

            const title_ids = try parseInlines(self.inlineCtx(), dt.text, dt.text_span.start);
            defer self.allocator.free(title_ids);
            // `level = 1`, not the ASG's own `0`: twig's shared `heading.level`
            // is 1-based across every language. `asg.zig` shifts back on encode.
            const heading_id = try self.b.addContainer(.{ .heading = .{ .level = 1 } }, title_ids);
            self.b.setSpan(heading_id, Span.init(dt.span_start, header_end_offset));
            self.b.setMarkerSpan(heading_id, Span.init(dt.span_start, dt.marker_end));
            if (dt.anchor_id) |aid| try self.b.setAttrs(heading_id, .{ .entries = &.{.{ .key = "id", .value = aid }} });
            header_id = heading_id;
            if (!have_start) {
                start_offset = dt.span_start;
                have_start = true;
            }
            end_offset = header_end_offset;

            // The attributes marker is present whenever a header is, even with
            // zero entries — see `asg.zig`'s doc comment.
            const attrs_marker = try self.b.addNode(.{ .container = .{ .name = "document-attributes" } });
            self.b.setSpelling(attrs_marker, .{ .container_origin = .directive });
            if (self.attr_buf.items.len > 0) try self.b.setAttrs(attrs_marker, .{ .entries = self.attr_buf.items });
            attrs_id = attrs_marker;
            body_start_line = line;
        }

        const body = try self.parseSectionsLoop(body_start_line, self.lines.len, ROOT_LEVEL);
        defer self.allocator.free(body.items);

        if (attrs_id) |aid| try children.append(self.allocator, aid);
        if (header_id) |hid| try children.append(self.allocator, hid);
        try children.appendSlice(self.allocator, body.items);

        if (body.items.len > 0) {
            if (!have_start) start_offset = body.first_start;
            end_offset = body.last_end;
        }
        const root = try self.b.addContainer(.doc, children.items);
        self.b.setSpan(root, Span.init(start_offset, end_offset));
        return root;
    }

    /// The author line's implicit attributes, as Asciidoctor names them
    /// (`author`, `firstname`, …, with `_2`, `_3` suffixes past the first).
    fn collectAuthors(self: *Parser, line: []const u8) Allocator.Error!void {
        var it = AuthorIter.init(line);
        var n: usize = 0;
        while (it.next()) |a| {
            n += 1;
            try self.pushAuthorAttr("author", a.fullname, n);
            try self.pushAuthorAttr("firstname", a.firstname, n);
            if (a.middlename) |m| try self.pushAuthorAttr("middlename", m, n);
            if (a.lastname) |l| try self.pushAuthorAttr("lastname", l, n);
            if (a.email) |e| try self.pushAuthorAttr("email", e, n);
        }
    }

    fn pushAuthorAttr(self: *Parser, key: []const u8, value: []const u8, n: usize) Allocator.Error!void {
        if (n == 1) {
            try self.attr_buf.append(self.allocator, .{ .key = key, .value = value });
            return;
        }
        // Keys past the first author are freshly allocated; `setAttrs` copies
        // them, so they are freed with the scratch list.
        const k = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ key, n });
        try self.owned_keys.append(self.allocator, k);
        try self.attr_buf.append(self.allocator, .{ .key = k, .value = value });
    }

    fn collectRevision(self: *Parser, line: []const u8) Allocator.Error!void {
        var t = std.mem.trim(u8, line, " \t");
        var number: ?[]const u8 = null;
        var date: ?[]const u8 = null;
        var remark: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, t, ',')) |comma| {
            number = std.mem.trim(u8, t[0..comma], " \t");
            t = std.mem.trim(u8, t[comma + 1 ..], " \t");
            if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
                date = std.mem.trim(u8, t[0..colon], " \t");
                remark = std.mem.trim(u8, t[colon + 1 ..], " \t");
            } else date = t;
        } else if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
            number = std.mem.trim(u8, t[0..colon], " \t");
            remark = std.mem.trim(u8, t[colon + 1 ..], " \t");
        } else if (t.len > 0 and t[0] == 'v') {
            number = t;
        } else date = t;
        if (number) |nn| {
            const v = if (nn.len > 1 and nn[0] == 'v' and std.ascii.isDigit(nn[1])) nn[1..] else nn;
            if (v.len > 0) try self.attr_buf.append(self.allocator, .{ .key = "revnumber", .value = v });
        }
        if (date) |d| if (d.len > 0) try self.attr_buf.append(self.allocator, .{ .key = "revdate", .value = d });
        if (remark) |r| if (r.len > 0) try self.attr_buf.append(self.allocator, .{ .key = "revremark", .value = r });
    }

    // ── section nesting ───────────────────────────────────────────────────

    fn parseSectionsLoop(self: *Parser, lo: usize, hi: usize, current_level: i32) Allocator.Error!FlatResult {
        var children: std.ArrayList(Node.Id) = .empty;
        errdefer children.deinit(self.allocator);
        var i = lo;
        var first_start: usize = 0;
        var last_end: usize = 0;
        while (true) {
            const flat = try self.parseFlatBlocks(i, hi);
            if (flat.items.len > 0) {
                if (children.items.len == 0) first_start = flat.first_start;
                last_end = flat.last_end;
            }
            try children.appendSlice(self.allocator, flat.items);
            self.allocator.free(flat.items);
            i = flat.stopped_at;
            if (i >= hi) {
                self.pending.clear();
                break;
            }
            const hm = self.matchHeadingLine(i).?; // `parseFlatBlocks` only stops early for this
            if (hm.level <= current_level) break;
            const r = try self.parseSection(hm, hi);
            if (children.items.len == 0) first_start = r.start_offset;
            try children.append(self.allocator, r.id);
            last_end = r.end_offset;
            i = r.next;
        }
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = i, .first_start = first_start, .last_end = last_end };
    }

    fn parseSection(self: *Parser, hm: HeadingMatch, hi: usize) Allocator.Error!struct { id: Node.Id, next: usize, start_offset: usize, end_offset: usize } {
        // The metadata above the title (and the anchor inside it) is the
        // section's; the body's first block must not inherit it.
        var meta = self.takePending();
        defer meta.deinit(self.allocator);
        if (hm.anchor_id) |aid| if (meta.id == null) {
            meta.id = aid;
        };

        const title_ids = try parseInlines(self.inlineCtx(), hm.text, hm.text_span.start);
        defer self.allocator.free(title_ids);
        const heading_id = try self.b.addContainer(.{ .heading = .{ .level = @intCast(hm.level + 1) } }, title_ids);
        self.b.setSpan(heading_id, Span.init(hm.span_start, hm.title_end));
        self.b.setMarkerSpan(heading_id, Span.init(hm.span_start, hm.marker_end));

        const inner = try self.parseSectionsLoop(hm.next_line, hi, hm.level);
        defer self.allocator.free(inner.items);

        const all = try self.allocator.alloc(Node.Id, 1 + inner.items.len);
        defer self.allocator.free(all);
        all[0] = heading_id;
        @memcpy(all[1..], inner.items);

        const id = try self.b.addContainer(.section, all);
        const meta_start = try self.applyMeta(&meta, id, &.{});
        const start = meta_start orelse hm.span_start;
        const end_offset = if (inner.items.len > 0) inner.last_end else hm.title_end;
        self.b.setSpan(id, Span.init(start, end_offset));
        return .{ .id = id, .next = inner.stopped_at, .start_offset = start, .end_offset = end_offset };
    }

    // ── the flat block scan ────────────────────────────────────────────

    /// Record one metadata line into `pending`.
    fn collectMeta(self: *Parser, i: usize) Allocator.Error!void {
        const line = self.lineText(i);
        const m = matchMetaLine(line).?;
        if (self.pending.start == null) self.pending.start = self.lines[i].start;
        switch (m) {
            .title => |t| self.pending.title = t,
            .anchor => |a| {
                self.pending.id = a.id;
                self.pending.reftext = a.reftext;
                if (self.pending.attr_start == null) self.pending.attr_start = self.lines[i].start;
                self.pending.attr_end = self.lines[i].end;
            },
            .attrs => |interior| {
                if (self.pending.attr_start == null) self.pending.attr_start = self.lines[i].start;
                self.pending.attr_end = self.lines[i].end;
                var it = AttrIter.init(interior);
                while (it.next()) |e| {
                    if (e.key) |k| {
                        if (std.mem.eql(u8, k, "id")) {
                            self.pending.id = e.value;
                        } else if (std.mem.eql(u8, k, "role")) {
                            var rit = std.mem.tokenizeAny(u8, e.value, " ");
                            while (rit.next()) |r| try self.pending.roles.append(self.allocator, r);
                        } else if (std.mem.eql(u8, k, "options") or std.mem.eql(u8, k, "opts")) {
                            var oit = std.mem.tokenizeAny(u8, e.value, ", ");
                            while (oit.next()) |o| try self.pending.options.append(self.allocator, o);
                        } else if (std.mem.eql(u8, k, "title")) {
                            self.pending.title = e.value;
                        } else {
                            try self.pending.named.append(self.allocator, .{ .key = k, .value = e.value });
                        }
                    } else if (e.index == 1) {
                        var sit = ShorthandIter.init(e.value);
                        while (sit.next()) |p| switch (p.kind) {
                            .style => self.pending.style = p.text,
                            .id => self.pending.id = p.text,
                            .role => try self.pending.roles.append(self.allocator, p.text),
                            .option => try self.pending.options.append(self.allocator, p.text),
                        };
                    } else {
                        // Positional `$N` for N >= 2, in order; a skipped slot
                        // (`[a,,c]`) stays present and empty.
                        while (self.pending.positional.items.len < e.index - 1) try self.pending.positional.append(self.allocator, null);
                        self.pending.positional.items[e.index - 2] = e.value;
                    }
                }
            },
        }
    }

    /// Move the pending metadata out, leaving none pending — for a block
    /// whose children are parsed before the block node exists (a list, a
    /// section).
    fn takePending(self: *Parser) Pending {
        const p = self.pending;
        self.pending = .{};
        return p;
    }

    /// Attach the pending metadata to `id` as its attributes, then clear it.
    /// `extra` entries are written first (a block's own semantic projections).
    /// Returns the block's metadata start offset.
    fn applyPending(self: *Parser, id: Node.Id, extra: []const AST.KeyVal) Allocator.Error!?usize {
        return self.applyMeta(&self.pending, id, extra);
    }

    /// `applyPending` over an explicit `Pending` (one `takePending` moved out).
    fn applyMeta(self: *Parser, p: *Pending, id: Node.Id, extra: []const AST.KeyVal) Allocator.Error!?usize {
        const start = p.start;
        defer p.clear();
        self.attr_buf.clearRetainingCapacity();
        self.class_buf.clearRetainingCapacity();
        try self.attr_buf.appendSlice(self.allocator, extra);
        if (p.id) |i| try self.attr_buf.append(self.allocator, .{ .key = "id", .value = i });
        if (p.style) |st| try self.class_buf.appendSlice(self.allocator, st);
        for (p.roles.items) |r| {
            if (self.class_buf.items.len > 0) try self.class_buf.append(self.allocator, ' ');
            try self.class_buf.appendSlice(self.allocator, r);
        }
        if (self.class_buf.items.len > 0) try self.attr_buf.append(self.allocator, .{ .key = "class", .value = self.class_buf.items });
        if (p.title) |t| try self.attr_buf.append(self.allocator, .{ .key = "title", .value = t });
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(self.allocator);
        if (p.options.items.len > 0) {
            for (p.options.items, 0..) |o, k| {
                if (k > 0) try joined.append(self.allocator, ',');
                try joined.appendSlice(self.allocator, o);
            }
            try self.attr_buf.append(self.allocator, .{ .key = "options", .value = joined.items });
        }
        for (p.named.items) |kv| try self.attr_buf.append(self.allocator, kv);
        try self.appendLeftoverPositional(p);
        try self.b.setAttrs(id, .{ .entries = self.attr_buf.items });
        if (p.attr_start) |s| self.b.setAttrsSpan(id, Span.init(s, p.attr_end));
        return start;
    }

    fn appendLeftoverPositional(self: *Parser, p: *const Pending) Allocator.Error!void {
        for (p.positional.items, 0..) |slot, k| {
            const v = slot orelse continue;
            if (v.len == 0) continue;
            const key = try std.fmt.allocPrint(self.allocator, "${d}", .{k + 2});
            try self.owned_keys.append(self.allocator, key);
            try self.attr_buf.append(self.allocator, .{ .key = key, .value = v });
        }
    }

    /// Parses blocks in `[lo, hi)`, stopping at `hi` or at the first section
    /// heading (any level) — the only construct a caller needs to inspect
    /// rather than have consumed outright.
    fn parseFlatBlocks(self: *Parser, lo: usize, hi: usize) Allocator.Error!FlatResult {
        var children: std.ArrayList(Node.Id) = .empty;
        errdefer children.deinit(self.allocator);
        var i = lo;
        var first_start: usize = 0;
        var last_end: usize = 0;
        while (i < hi) {
            if (self.isBlankLine(i)) {
                i += 1;
                continue;
            }
            if (self.isMetaLine(i)) {
                try self.collectMeta(i);
                i += 1;
                continue;
            }
            const r = (try self.parseBlockAt(i, hi)) orelse break;
            if (r.id) |id| {
                if (children.items.len == 0) first_start = r.start_offset;
                try children.append(self.allocator, id);
                last_end = r.end_offset;
            }
            i = r.next;
        }
        return .{ .items = try children.toOwnedSlice(self.allocator), .stopped_at = i, .first_start = first_start, .last_end = last_end };
    }

    /// One block starting at (non-blank, non-metadata) line `i`. `null` when
    /// the line is a section heading, which only `parseSectionsLoop` may
    /// consume. `id` is `null` for a block that produces no node (a comment).
    fn parseBlockAt(self: *Parser, i: usize, hi: usize) Allocator.Error!?BlockResult {
        if (self.matchHeadingLine(i)) |hm| {
            if (self.pending.styleIs("discrete") or self.pending.styleIs("float")) return try self.parseDiscreteHeading(hm);
            return null;
        }
        if (self.isLineComment(i)) return .{ .id = null, .next = i + 1, .start_offset = 0, .end_offset = 0 };
        if (self.isThematicBreak(i) or self.isPageBreak(i)) return try self.parseBreak(i);
        if (self.matchDelimiter(i)) |d| return try self.parseDelimited(i, hi, d.delim, d.text);
        if (self.matchFence(i)) |f| return try self.parseFence(i, hi, f.fence, f.info);
        if (self.isTableOpen(i)) return try self.parseTable(i, hi);
        if (self.isQuoteLine(i)) return try self.parseMarkdownQuote(i, hi);
        if (self.matchBlockMacro(i)) |m| return try self.parseBlockMacro(i, m);
        if (self.matchListMarker(i)) |m| return try self.parseList(i, hi, m);
        if (self.leadingSpaces(i) == 0) {
            if (matchAttrEntry(self.lineText(i))) |e| return try self.parseAttrEntry(i, e);
        }
        if (self.matchAdmonitionPara(i)) |a| return try self.parseAdmonitionPara(i, hi, a.name, a.text_at);
        if (self.isContinuation(i)) {
            // A stray `+` outside a list is a paragraph of its own.
            return try self.parseParagraphBlock(i, i + 1);
        }
        if (self.leadingSpaces(i) > 0 and !self.pending.styleIs("normal") and self.pending.style == null) return try self.parseIndentedLiteral(i, hi);
        const end = self.paragraphEnd(i, hi);
        return try self.parseParagraphBlock(i, end);
    }

    fn paragraphEnd(self: *const Parser, lo: usize, hi: usize) usize {
        var i = lo + 1;
        while (i < hi) {
            if (self.isBlankLine(i) or self.isBlockStart(i)) break;
            i += 1;
        }
        return i;
    }

    fn parseBreak(self: *Parser, i: usize) Allocator.Error!BlockResult {
        const id = if (self.isThematicBreak(i))
            try self.b.addNode(.thematic_break)
        else blk: {
            const pb = try self.b.addNode(.{ .container = .{ .name = "page-break" } });
            self.b.setSpelling(pb, .{ .container_origin = .directive });
            break :blk pb;
        };
        const meta_start = try self.applyPending(id, &.{});
        const span = Span.init(meta_start orelse self.lines[i].start, self.lines[i].end);
        self.b.setSpan(id, span);
        return .{ .id = id, .next = i + 1, .start_offset = span.start, .end_offset = span.end };
    }

    fn parseDiscreteHeading(self: *Parser, hm: HeadingMatch) Allocator.Error!BlockResult {
        _ = self.pending.takeStyle();
        const ids = try parseInlines(self.inlineCtx(), hm.text, hm.text_span.start);
        defer self.allocator.free(ids);
        const id = try self.b.addContainer(.{ .heading = .{ .level = @intCast(hm.level + 1) } }, ids);
        if (hm.anchor_id) |aid| if (self.pending.id == null) {
            self.pending.id = aid;
        };
        const meta_start = try self.applyPending(id, &.{});
        const span = Span.init(meta_start orelse hm.span_start, hm.title_end);
        self.b.setSpan(id, span);
        self.b.setMarkerSpan(id, Span.init(hm.span_start, hm.marker_end));
        return .{ .id = id, .next = hm.next_line, .start_offset = span.start, .end_offset = span.end };
    }

    fn parseAttrEntry(self: *Parser, i: usize, e: AST.KeyVal) Allocator.Error!BlockResult {
        var ids: []Node.Id = &.{};
        defer if (ids.len > 0) self.allocator.free(ids);
        if (e.value) |v| if (v.len > 0) {
            const at = self.lines[i].start + (std.mem.indexOf(u8, self.lineText(i), v) orelse 0);
            ids = try parseInlines(self.inlineCtx(), v, at);
        };
        const id = try self.b.addContainer(.{ .substitution = .{ .label = e.key } }, ids);
        const extra: []const AST.KeyVal = if (e.value == null) &.{.{ .key = "unset", .value = null }} else &.{};
        const meta_start = try self.applyPending(id, extra);
        const span = Span.init(meta_start orelse self.lines[i].start, self.lines[i].end);
        self.b.setSpan(id, span);
        return .{ .id = id, .next = i + 1, .start_offset = span.start, .end_offset = span.end };
    }

    // ── paragraphs and their styles ──────────────────────────────────────

    /// The paragraph at `[lo, end_ex)`, dispatched on the pending style.
    fn parseParagraphBlock(self: *Parser, lo: usize, end_ex: usize) Allocator.Error!BlockResult {
        const span = Span.init(self.lines[lo].start, self.lines[end_ex - 1].end);
        if (self.pending.style) |style| {
            if (isLeafStyle(style)) return try self.parseLeafParagraph(span, end_ex, style);
            if (admonitionName(style)) |name| {
                _ = self.pending.takeStyle();
                return try self.wrapParagraph(span, end_ex, .{ .container = .{ .name = name, .form = .block_fenced } });
            }
            if (std.mem.eql(u8, style, "quote")) {
                _ = self.pending.takeStyle();
                try self.takeQuoteAttribution();
                return try self.wrapParagraph(span, end_ex, .block_quote);
            }
            if (isParentStyle(style)) {
                _ = self.pending.takeStyle();
                return try self.wrapParagraph(span, end_ex, .{ .container = .{ .name = style, .form = .block_fenced } });
            }
            if (std.mem.eql(u8, style, "normal")) _ = self.pending.takeStyle();
        }
        const hardbreaks = self.pending.hasOption("hardbreaks");
        const id = try self.buildPara(span, hardbreaks);
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse span.start;
        self.b.setSpan(id, Span.init(start, span.end));
        return .{ .id = id, .next = end_ex, .start_offset = start, .end_offset = span.end };
    }

    fn buildPara(self: *Parser, span: Span, hardbreaks: bool) Allocator.Error!Node.Id {
        const text = self.source[span.start..span.end];
        var ctx = self.inlineCtx();
        ctx.hardbreaks = hardbreaks;
        const ids = try parseInlines(ctx, text, span.start);
        defer self.allocator.free(ids);
        const id = try self.b.addContainer(.para, ids);
        self.b.setSpan(id, span);
        return id;
    }

    /// `[quote, attribution, citetitle]`'s two positionals become named
    /// attributes, which is what they are.
    fn takeQuoteAttribution(self: *Parser) Allocator.Error!void {
        if (self.pending.takePositional(2)) |a| if (a.len > 0) try self.pending.named.append(self.allocator, .{ .key = "attribution", .value = a });
        if (self.pending.takePositional(3)) |c| if (c.len > 0) try self.pending.named.append(self.allocator, .{ .key = "citetitle", .value = c });
    }

    /// A styled paragraph that becomes a parent block holding the paragraph.
    fn wrapParagraph(self: *Parser, span: Span, end_ex: usize, kind: Node.Kind) Allocator.Error!BlockResult {
        const para = try self.buildPara(span, self.pending.hasOption("hardbreaks"));
        const id = try self.b.addContainer(kind, &.{para});
        if (kind == .container) self.b.setSpelling(id, .{ .container_origin = .directive });
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse span.start;
        self.b.setSpan(id, Span.init(start, span.end));
        self.b.setContentSpan(id, span);
        return .{ .id = id, .next = end_ex, .start_offset = start, .end_offset = span.end };
    }

    /// `[source]`/`[listing]`/`[literal]`/`[pass]`/`[stem]`/`[verse]` on a
    /// paragraph: the paragraph's lines are the block's opaque content.
    fn parseLeafParagraph(self: *Parser, span: Span, end_ex: usize, style: []const u8) Allocator.Error!BlockResult {
        _ = self.pending.takeStyle();
        const id = try self.buildLeafBlock(style, span, span);
        const meta_start = try self.applyPending(id, try self.leafExtra(style));
        const start = meta_start orelse span.start;
        self.b.setSpan(id, Span.init(start, span.end));
        return .{ .id = id, .next = end_ex, .start_offset = start, .end_offset = span.end };
    }

    /// The semantic projection of a leaf style's positionals: nothing, since
    /// `source`'s language rides in `Kind.code_block.lang` and `verse`'s
    /// attribution is folded into `named` by `verseAttribution`.
    fn leafExtra(self: *Parser, style: []const u8) Allocator.Error![]const AST.KeyVal {
        if (std.mem.eql(u8, style, "verse")) try self.takeQuoteAttribution();
        return &.{};
    }

    /// The language a `[source,lang]` / `[,lang]` line names, consumed.
    fn takeLang(self: *Parser) ?[]const u8 {
        if (self.pending.get("language")) |l| return l;
        const p = self.pending.takePositional(2) orelse return null;
        return if (p.len > 0) p else null;
    }

    /// Build the leaf-block node a (style, content) pair means. `content` is
    /// the opaque interior (`null` content span for an empty block); `outer`
    /// is only used for the verse case's line splitting.
    fn buildLeafBlock(self: *Parser, style: []const u8, content: Span, outer: Span) Allocator.Error!Node.Id {
        _ = outer;
        const text = self.source[content.start..content.end];
        const has_content = content.end > content.start;
        if (std.mem.eql(u8, style, "verse")) return try self.buildVerse(content);
        if (std.mem.eql(u8, style, "pass")) {
            const id = try self.b.addLeaf(.{ .raw_block = .{ .format = "html", .text = text } });
            if (has_content) self.b.setContentSpan(id, content);
            return id;
        }
        var lang: ?[]const u8 = null;
        if (std.mem.eql(u8, style, "source")) {
            lang = self.takeLang();
        } else if (std.mem.eql(u8, style, "listing")) {
            lang = self.takeLang();
        } else if (std.mem.eql(u8, style, "stem") or std.mem.eql(u8, style, "latexmath") or std.mem.eql(u8, style, "asciimath")) {
            lang = style;
        }
        const id = try self.b.addLeaf(.{ .code_block = .{ .lang = lang, .text = text } });
        if (has_content) self.b.setContentSpan(id, content);
        return id;
    }

    /// A verse: one `line` per source line, holding that line's inlines, with
    /// `indent` as the line's depth among the block's distinct indentations.
    fn buildVerse(self: *Parser, content: Span) Allocator.Error!Node.Id {
        var lines_out: std.ArrayList(Node.Id) = .empty;
        defer lines_out.deinit(self.allocator);
        // Distinct indentation widths, ascending, so depth is an index.
        var widths: std.ArrayList(usize) = .empty;
        defer widths.deinit(self.allocator);
        const text = self.source[content.start..content.end];
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            const w = l.len - std.mem.trimStart(u8, l, " \t").len;
            if (l.len == w) continue;
            if (std.mem.indexOfScalar(usize, widths.items, w) == null) try widths.append(self.allocator, w);
        }
        std.mem.sort(usize, widths.items, {}, std.sort.asc(usize));
        var offset = content.start;
        var it2 = std.mem.splitScalar(u8, text, '\n');
        while (it2.next()) |l| {
            const w = l.len - std.mem.trimStart(u8, l, " \t").len;
            const body = l[w..];
            const depth: u32 = if (body.len == 0) 0 else @intCast(std.mem.indexOfScalar(usize, widths.items, w).?);
            const ids = try parseInlines(self.inlineCtx(), body, offset + w);
            defer self.allocator.free(ids);
            const line_id = try self.b.addContainer(.{ .line = .{ .indent = depth } }, ids);
            self.b.setSpan(line_id, Span.init(offset, offset + l.len));
            try lines_out.append(self.allocator, line_id);
            offset += l.len + 1;
        }
        const id = try self.b.addContainer(.line_block, lines_out.items);
        if (content.end > content.start) self.b.setContentSpan(id, content);
        return id;
    }

    /// `NOTE: text` — an admonition paragraph.
    fn parseAdmonitionPara(self: *Parser, i: usize, hi: usize, name: []const u8, text_at: usize) Allocator.Error!BlockResult {
        const end = self.paragraphEnd(i, hi);
        const para_span = Span.init(self.lines[i].start + text_at, self.lines[end - 1].end);
        const para = try self.buildPara(para_span, self.pending.hasOption("hardbreaks"));
        const id = try self.b.addContainer(.{ .container = .{ .name = name, .form = .block_fenced } }, &.{para});
        self.b.setSpelling(id, .{ .container_origin = .directive });
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse self.lines[i].start;
        self.b.setSpan(id, Span.init(start, para_span.end));
        self.b.setContentSpan(id, para_span);
        self.b.setMarkerSpan(id, Span.init(self.lines[i].start, self.lines[i].start + text_at));
        return .{ .id = id, .next = end, .start_offset = start, .end_offset = para_span.end };
    }

    /// An indented paragraph is a literal block; the common indentation is
    /// stripped from its text, the content span keeps it.
    fn parseIndentedLiteral(self: *Parser, i: usize, hi: usize) Allocator.Error!BlockResult {
        var end = i + 1;
        while (end < hi and !self.isBlankLine(end) and !self.isBlockStart(end)) end += 1;
        const content = Span.init(self.lines[i].start, self.lines[end - 1].end);
        var min: usize = std.math.maxInt(usize);
        var k = i;
        while (k < end) : (k += 1) min = @min(min, self.leadingSpaces(k));
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        k = i;
        while (k < end) : (k += 1) {
            if (k > i) try text.append(self.allocator, '\n');
            try text.appendSlice(self.allocator, self.lineText(k)[min..]);
        }
        const id = try self.b.addLeaf(.{ .code_block = .{ .lang = null, .text = text.items } });
        self.b.setContentSpan(id, content);
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse content.start;
        self.b.setSpan(id, Span.init(start, content.end));
        return .{ .id = id, .next = end, .start_offset = start, .end_offset = content.end };
    }

    // ── delimited blocks ─────────────────────────────────────────────────

    /// One delimited block, from its opening delimiter line. The pending
    /// STYLE can override what the delimiter says (`[source]` on an open
    /// block, `[NOTE]` on an example, `[verse]` on a quote), which is how
    /// Asciidoctor reads it too.
    ///
    /// An UNCLOSED block runs to `hi`. Asciidoctor warns and does the same; the
    /// ASG has nowhere to record the warning, so all that is left is the
    /// extent, and ending at the last content line (rather than at a delimiter
    /// that isn't there) is the only reading that keeps every location inside
    /// the source.
    fn parseDelimited(self: *Parser, delim_line: usize, hi: usize, delim: Delimiter, opening: []const u8) Allocator.Error!BlockResult {
        var close_line = delim_line + 1;
        while (close_line < hi and !self.matchesDelim(close_line, opening)) close_line += 1;
        const closed = close_line < hi;
        const content_lo = delim_line + 1;
        const content_hi = close_line;
        const has_content = content_hi > content_lo;
        const next = if (closed) close_line + 1 else content_hi;
        const end_offset = if (closed)
            self.lines[close_line].end
        else if (has_content)
            self.lines[content_hi - 1].end
        else
            self.lines[delim_line].end;

        if (delim.content == .dropped) return .{ .id = null, .next = next, .start_offset = 0, .end_offset = 0 };

        const content = if (has_content) Span.init(self.lines[content_lo].start, self.lines[content_hi - 1].end) else Span.init(self.lines[delim_line].end, self.lines[delim_line].end);

        // What the block IS: the style first, then the delimiter.
        const style = self.pending.style;
        var kind: BlockKind = switch (delim.content) {
            .verbatim => .{ .leaf = delim.name },
            .compound => if (std.mem.eql(u8, delim.name, "quote")) .quote else .{ .parent = delim.name },
            .dropped => unreachable,
        };
        if (style) |s| {
            if (isLeafStyle(s)) {
                kind = .{ .leaf = s };
                _ = self.pending.takeStyle();
            } else if (admonitionName(s)) |name| {
                kind = .{ .parent = name };
                _ = self.pending.takeStyle();
            } else if (std.mem.eql(u8, s, "quote")) {
                kind = .quote;
                _ = self.pending.takeStyle();
            } else if (isParentStyle(s)) {
                kind = .{ .parent = s };
                _ = self.pending.takeStyle();
            } else if (std.mem.eql(u8, delim.name, "listing") and (std.mem.eql(u8, s, "source") or self.pending.positional.items.len > 0)) {
                _ = self.pending.takeStyle();
            }
        }
        // `[,ruby]` on a listing is a source block with a language.
        if (kind == .leaf and std.mem.eql(u8, kind.leaf, "listing") and style == null) kind = .{ .leaf = "source" };

        var id: Node.Id = undefined;
        var meta_start: ?usize = null;
        switch (kind) {
            .leaf => |s| {
                id = try self.buildLeafBlock(s, content, content);
                meta_start = try self.applyPending(id, try self.leafExtra(s));
            },
            .quote, .parent => {
                if (kind == .quote) try self.takeQuoteAttribution();
                // The metadata is this block's; the interior's first block
                // must not inherit it.
                var meta = self.takePending();
                defer meta.deinit(self.allocator);
                const inner = try self.parseFlatBlocks(content_lo, content_hi);
                defer self.allocator.free(inner.items);
                if (kind == .quote) {
                    id = try self.b.addContainer(.block_quote, inner.items);
                } else {
                    id = try self.b.addContainer(.{ .container = .{ .name = kind.parent, .form = .block_fenced } }, inner.items);
                    self.b.setSpelling(id, .{ .container_origin = .directive });
                }
                if (has_content) self.b.setContentSpan(id, content);
                meta_start = try self.applyMeta(&meta, id, &.{});
            },
        }
        const start = meta_start orelse self.lines[delim_line].start;
        self.b.setSpan(id, Span.init(start, end_offset));
        return .{ .id = id, .next = next, .start_offset = start, .end_offset = end_offset };
    }

    const BlockKind = union(enum) { leaf: []const u8, quote, parent: []const u8 };

    /// A Markdown-style fenced code block, which Asciidoctor reads as a
    /// source listing.
    fn parseFence(self: *Parser, fence_line: usize, hi: usize, fence: []const u8, info: []const u8) Allocator.Error!BlockResult {
        var close_line = fence_line + 1;
        while (close_line < hi and !self.matchesDelim(close_line, fence)) close_line += 1;
        const closed = close_line < hi;
        const has_content = close_line > fence_line + 1;
        const content = if (has_content) Span.init(self.lines[fence_line + 1].start, self.lines[close_line - 1].end) else Span.init(self.lines[fence_line].end, self.lines[fence_line].end);
        const lang: ?[]const u8 = if (info.len > 0) info else self.takeLang();
        const id = try self.b.addLeaf(.{ .code_block = .{ .lang = lang, .text = self.source[content.start..content.end] } });
        if (has_content) self.b.setContentSpan(id, content);
        if (self.pending.styleIs("source")) _ = self.pending.takeStyle();
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse self.lines[fence_line].start;
        const end_offset = if (closed) self.lines[close_line].end else if (has_content) content.end else self.lines[fence_line].end;
        self.b.setSpan(id, Span.init(start, end_offset));
        return .{ .id = id, .next = if (closed) close_line + 1 else close_line, .start_offset = start, .end_offset = end_offset };
    }

    /// `> ` quotes: the marker is stripped from every line and the interior
    /// parsed as blocks. The interior is not contiguous source, so it is
    /// parsed from a copy and grafted back at the right offsets — one graft
    /// per line-run is what keeps every span pointing into the real source.
    fn parseMarkdownQuote(self: *Parser, lo: usize, hi: usize) Allocator.Error!BlockResult {
        var end = lo;
        while (end < hi and self.isQuoteLine(end)) end += 1;
        // Strip one `>` (and one following space) per line into a scratch
        // source, remembering each scratch line's real offset.
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.allocator);
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(self.allocator);
        var k = lo;
        while (k < end) : (k += 1) {
            const t = self.lineText(k);
            var strip: usize = 1;
            if (t.len > 1 and t[1] == ' ') strip = 2;
            try offsets.append(self.allocator, self.lines[k].start + strip);
            try scratch.appendSlice(self.allocator, t[strip..]);
            try scratch.append(self.allocator, '\n');
        }
        // Parse the scratch as its own document and graft its blocks in.
        var inner = try parse(self.allocator, scratch.items);
        defer inner.deinit();
        var children: std.ArrayList(Node.Id) = .empty;
        defer children.deinit(self.allocator);
        var it = inner.children(inner.ast.root);
        while (it.next()) |c| {
            const gid = try self.graftShifted(&inner, c.id, offsets.items, scratch.items);
            try children.append(self.allocator, gid);
        }
        const id = try self.b.addContainer(.block_quote, children.items);
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse self.lines[lo].start;
        const end_offset = self.lines[end - 1].end;
        self.b.setSpan(id, Span.init(start, end_offset));
        return .{ .id = id, .next = end, .start_offset = start, .end_offset = end_offset };
    }

    /// Copy a subtree parsed from a stripped scratch source into this
    /// builder, mapping every scratch offset to its real one through
    /// `offsets` (real offset of each scratch line's start).
    fn graftShifted(self: *Parser, src: *const Document, id: Node.Id, offsets: []const usize, scratch: []const u8) Allocator.Error!Node.Id {
        var kids: std.ArrayList(Node.Id) = .empty;
        defer kids.deinit(self.allocator);
        var it = src.children(id);
        while (it.next()) |c| try kids.append(self.allocator, try self.graftShifted(src, c.id, offsets, scratch));
        const node = src.ast.nodes[id];
        const nid = try self.b.addContainer(node.kind, kids.items);
        const sp = src.span(id);
        self.b.setSpan(nid, Span.init(mapOffset(offsets, scratch, sp.start), mapOffset(offsets, scratch, sp.end)));
        if (src.contentSpan(id)) |cs| self.b.setContentSpan(nid, Span.init(mapOffset(offsets, scratch, cs.start), mapOffset(offsets, scratch, cs.end)));
        if (src.spelling(id)) |s| self.b.setSpelling(nid, s);
        if (src.markerSpan(id)) |ms| self.b.setMarkerSpan(nid, Span.init(mapOffset(offsets, scratch, ms.start), mapOffset(offsets, scratch, ms.end)));
        const attrs = src.ast.attrsOf(id);
        if (!attrs.isEmpty()) try self.b.setAttrs(nid, attrs);
        return nid;
    }

    // ── block macros ─────────────────────────────────────────────────────

    fn parseBlockMacro(self: *Parser, i: usize, m: BlockMacro) Allocator.Error!BlockResult {
        const line_start = self.lines[i].start;
        const t = self.lineText(i);
        const attrs_at = line_start + (std.mem.indexOfScalar(u8, t, '[') orelse t.len);
        var id: Node.Id = undefined;
        if (std.mem.eql(u8, m.name, "image")) {
            var alt: ?[]const u8 = null;
            var width: ?[]const u8 = null;
            var height: ?[]const u8 = null;
            var it = AttrIter.init(m.attrs);
            while (it.next()) |e| {
                if (e.key) |k| {
                    if (std.mem.eql(u8, k, "alt")) alt = e.value else if (std.mem.eql(u8, k, "width")) width = e.value else if (std.mem.eql(u8, k, "height")) height = e.value else try self.pending.named.append(self.allocator, .{ .key = k, .value = e.value });
                } else switch (e.index) {
                    1 => alt = e.value,
                    2 => width = e.value,
                    3 => height = e.value,
                    else => {},
                }
            }
            var kids: [1]Node.Id = undefined;
            var n: usize = 0;
            if (alt) |a| if (a.len > 0) {
                const s = try self.b.addLeaf(.{ .str = a });
                const at = attrs_at + 1 + (std.mem.indexOf(u8, m.attrs, a) orelse 0);
                self.b.setSpan(s, Span.init(at, at + a.len));
                kids[0] = s;
                n = 1;
            };
            const img = try self.b.addContainer(.{ .image = .{ .destination = m.target, .reference = null } }, kids[0..n]);
            self.b.setSpan(img, Span.init(line_start, self.lines[i].end));
            self.attr_buf.clearRetainingCapacity();
            if (width) |w| try self.attr_buf.append(self.allocator, .{ .key = "width", .value = w });
            if (height) |h| try self.attr_buf.append(self.allocator, .{ .key = "height", .value = h });
            if (self.attr_buf.items.len > 0) try self.b.setAttrs(img, .{ .entries = self.attr_buf.items });
            id = try self.b.addContainer(.para, &.{img});
        } else {
            // audio / video / toc: a leaf directive whose argument is the target.
            id = try self.b.addNode(.{ .container = .{ .name = m.name, .form = .block_leaf, .argument = if (m.target.len > 0) m.target else null } });
            self.b.setSpelling(id, .{ .container_origin = .directive });
            var it = AttrIter.init(m.attrs);
            const positional_names: []const []const u8 = if (std.mem.eql(u8, m.name, "video")) &.{ "poster", "width", "height" } else &.{};
            while (it.next()) |e| {
                if (e.key) |k| {
                    try self.pending.named.append(self.allocator, .{ .key = k, .value = e.value });
                } else if (e.index <= positional_names.len) {
                    if (e.value.len > 0) try self.pending.named.append(self.allocator, .{ .key = positional_names[e.index - 1], .value = e.value });
                } else if (e.value.len > 0) {
                    while (self.pending.positional.items.len < e.index - 1) try self.pending.positional.append(self.allocator, null);
                    self.pending.positional.items[e.index - 2] = e.value;
                }
            }
        }
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse line_start;
        self.b.setSpan(id, Span.init(start, self.lines[i].end));
        return .{ .id = id, .next = i + 1, .start_offset = start, .end_offset = self.lines[i].end };
    }

    // ── tables ───────────────────────────────────────────────────────────

    const CellSpec = struct {
        colspan: u32 = 1,
        rowspan: u32 = 1,
        alignment: AST.Alignment = .default,
        /// Where the spec begins (the `2+` before the bar), for the cell's span.
        start: usize,
    };

    /// The cell spec directly before a bar at `bar` in `text`, if any:
    /// `[N*|N+][.N+][<^>][.<^>][style]`.
    fn cellSpecBefore(text: []const u8, bar: usize, floor: usize) CellSpec {
        var s = bar;
        while (s > floor and std.mem.indexOfScalar(u8, "0123456789.+*<^>aehlmsdv", text[s - 1]) != null) s -= 1;
        var spec: CellSpec = .{ .start = bar };
        const raw = text[s..bar];
        if (raw.len == 0) return spec;
        // Validate: a duplication/span group, then alignment, then a style letter.
        var i: usize = 0;
        var num: u32 = 0;
        var have_num = false;
        while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {
            num = num * 10 + (raw[i] - '0');
            have_num = true;
        }
        if (have_num) {
            if (i < raw.len and raw[i] == '+') {
                spec.colspan = @max(num, 1);
                i += 1;
            } else if (i < raw.len and raw[i] == '*') {
                i += 1; // duplication is not modelled; the cell still parses
            } else return .{ .start = bar };
        }
        if (i < raw.len and raw[i] == '.') {
            var j = i + 1;
            var rnum: u32 = 0;
            var have_r = false;
            while (j < raw.len and std.ascii.isDigit(raw[j])) : (j += 1) {
                rnum = rnum * 10 + (raw[j] - '0');
                have_r = true;
            }
            if (have_r and j < raw.len and raw[j] == '+') {
                spec.rowspan = @max(rnum, 1);
                i = j + 1;
            }
        }
        if (i < raw.len and std.mem.indexOfScalar(u8, "<^>", raw[i]) != null) {
            spec.alignment = switch (raw[i]) {
                '<' => .left,
                '^' => .center,
                else => .right,
            };
            i += 1;
        }
        if (i < raw.len and raw[i] == '.' and i + 1 < raw.len and std.mem.indexOfScalar(u8, "<^>", raw[i + 1]) != null) i += 2;
        if (i < raw.len and std.mem.indexOfScalar(u8, "aehlmsdv", raw[i]) != null) i += 1;
        if (i != raw.len) return .{ .start = bar };
        spec.start = s;
        return spec;
    }

    fn parseTable(self: *Parser, open_line: usize, hi: usize) Allocator.Error!BlockResult {
        const opening = self.lineTrimmed(open_line);
        var close_line = open_line + 1;
        while (close_line < hi and !self.matchesDelim(close_line, opening)) close_line += 1;
        const closed = close_line < hi;
        const content_lo = open_line + 1;
        const content_hi = close_line;

        // Column count: `cols`, else the first line's cell count.
        var ncols: usize = 0;
        if (self.pending.get("cols")) |cols| {
            var it = std.mem.tokenizeScalar(u8, cols, ',');
            while (it.next()) |c| {
                const spec = std.mem.trim(u8, c, " ");
                // `3*` or `3*<` repeats; a bare number is a width.
                if (std.mem.indexOfScalar(u8, spec, '*')) |star| {
                    ncols += std.fmt.parseInt(usize, spec[0..star], 10) catch 1;
                } else if (spec.len > 0 and std.ascii.isDigit(spec[0]) and std.mem.indexOfAny(u8, spec, "<^>.aehlmsdv") == null) {
                    // A single bare integer is a column COUNT when it is the only spec.
                    ncols += 1;
                } else ncols += 1;
            }
            if (ncols == 1) {
                const only = std.mem.trim(u8, cols, " ");
                if (std.fmt.parseInt(usize, only, 10) catch null) |n| ncols = n;
            }
        }

        // Every cell in the body, in order.
        const Cell = struct { spec: CellSpec, text_start: usize, text_end: usize, line: usize };
        var cells: std.ArrayList(Cell) = .empty;
        defer cells.deinit(self.allocator);
        if (content_hi > content_lo) {
            const region = Span.init(self.lines[content_lo].start, self.lines[content_hi - 1].end);
            const text = self.source[region.start..region.end];
            var i: usize = 0;
            var current: ?usize = null; // index into `cells` of the open cell
            var line_floor: usize = 0;
            var line_no = content_lo;
            while (i < text.len) : (i += 1) {
                const c = text[i];
                if (c == '\n') {
                    line_floor = i + 1;
                    line_no += 1;
                    continue;
                }
                if (c == '\\' and i + 1 < text.len and text[i + 1] == '|') {
                    i += 1;
                    continue;
                }
                if (c != '|') continue;
                const spec = cellSpecBefore(text, i, line_floor);
                if (current) |ci| cells.items[ci].text_end = region.start + spec.start;
                try cells.append(self.allocator, .{ .spec = .{ .colspan = spec.colspan, .rowspan = spec.rowspan, .alignment = spec.alignment, .start = region.start + spec.start }, .text_start = region.start + i + 1, .text_end = region.end, .line = line_no });
                current = cells.items.len - 1;
            }
            if (ncols == 0) {
                for (cells.items) |cell| {
                    if (cell.line != content_lo) break;
                    ncols += cell.spec.colspan;
                }
            }
        }
        if (ncols == 0) ncols = 1;

        // Header: the `header` option, or an implicit one — the first row on a
        // single line followed by a blank line.
        var header = self.pending.hasOption("header");
        if (!header and cells.items.len > 0 and content_hi > content_lo + 1) {
            var first_line_cols: usize = 0;
            for (cells.items) |cell| {
                if (cell.line != content_lo) break;
                first_line_cols += cell.spec.colspan;
            }
            if (first_line_cols == ncols and self.isBlankLine(content_lo + 1)) header = true;
        }
        var footer = self.pending.hasOption("footer");

        var rows: std.ArrayList(Node.Id) = .empty;
        defer rows.deinit(self.allocator);
        var row_cells: std.ArrayList(Node.Id) = .empty;
        defer row_cells.deinit(self.allocator);
        var filled: usize = 0;
        var row_start: usize = 0;
        var row_index: usize = 0;
        var k: usize = 0;
        while (k < cells.items.len) : (k += 1) {
            const cell = cells.items[k];
            const is_head = header and row_index == 0;
            const raw = self.source[cell.text_start..cell.text_end];
            const trimmed = std.mem.trim(u8, raw, " \t\n");
            const text_at = cell.text_start + (std.mem.indexOf(u8, raw, trimmed) orelse 0);
            const ids = try parseInlines(self.inlineCtx(), trimmed, text_at);
            defer self.allocator.free(ids);
            const cid = try self.b.addContainer(.{ .cell = .{ .head = is_head, .alignment = cell.spec.alignment, .colspan = cell.spec.colspan, .rowspan = cell.spec.rowspan } }, ids);
            const cell_end = if (trimmed.len > 0) text_at + trimmed.len else cell.text_start;
            self.b.setSpan(cid, Span.init(cell.spec.start, cell_end));
            if (trimmed.len > 0) self.b.setContentSpan(cid, Span.init(text_at, cell_end));
            if (row_cells.items.len == 0) row_start = cell.spec.start;
            try row_cells.append(self.allocator, cid);
            filled += cell.spec.colspan;
            if (filled >= ncols or k + 1 == cells.items.len) {
                const rid = try self.b.addContainer(.{ .row = .{ .head = is_head } }, row_cells.items);
                self.b.setSpan(rid, Span.init(row_start, cell_end));
                try rows.append(self.allocator, rid);
                row_cells.clearRetainingCapacity();
                filled = 0;
                row_index += 1;
            }
        }
        _ = &footer;

        var children: std.ArrayList(Node.Id) = .empty;
        defer children.deinit(self.allocator);
        if (self.pending.title) |title| {
            // A table's title is its caption — the one block whose title has a
            // structural child waiting for it.
            const cap_text = try self.b.addLeaf(.{ .str = title });
            const cap = try self.b.addContainer(.caption, &.{cap_text});
            try children.append(self.allocator, cap);
            self.pending.title = null;
        }
        try children.appendSlice(self.allocator, rows.items);
        const id = try self.b.addContainer(.table, children.items);
        const meta_start = try self.applyPending(id, &.{});
        const start = meta_start orelse self.lines[open_line].start;
        const end_offset = if (closed) self.lines[close_line].end else if (content_hi > content_lo) self.lines[content_hi - 1].end else self.lines[open_line].end;
        self.b.setSpan(id, Span.init(start, end_offset));
        if (content_hi > content_lo) self.b.setContentSpan(id, Span.init(self.lines[content_lo].start, self.lines[content_hi - 1].end));
        return .{ .id = id, .next = if (closed) close_line + 1 else close_line, .start_offset = start, .end_offset = end_offset };
    }

    // ── lists ────────────────────────────────────────────────────────────

    /// One list from its first item at line `lo`; every item shares the
    /// first item's marker identity (`ListMarker.key`). Items of another
    /// marker nest inside the current item unless that marker belongs to an
    /// enclosing list, in which case this list closes — Asciidoctor's rule,
    /// and the reason indentation is never consulted.
    fn parseList(self: *Parser, lo: usize, hi: usize, first: ListMarker) Allocator.Error!BlockResult {
        // The metadata above the list belongs to the LIST; the first item's
        // attached blocks must not inherit it.
        var meta = self.takePending();
        defer meta.deinit(self.allocator);
        const key = first.key();
        try self.list_stack.append(self.allocator, key);
        defer _ = self.list_stack.pop();

        var items: std.ArrayList(Node.Id) = .empty;
        defer items.deinit(self.allocator);
        var checks: std.ArrayList(?bool) = .empty;
        defer checks.deinit(self.allocator);
        var boxes: std.ArrayList(?Span) = .empty;
        defer boxes.deinit(self.allocator);
        var i = lo;
        var last_end: usize = self.lines[lo].end;
        var next_line: usize = lo;
        while (i < hi) {
            const m = self.matchListMarker(i) orelse break;
            if (!std.mem.eql(u8, m.key(), key)) break;
            const r = try self.parseListItem(i, hi, m, key);
            try items.append(self.allocator, r.id);
            try checks.append(self.allocator, r.checked);
            try boxes.append(self.allocator, r.box);
            last_end = r.end_offset;
            next_line = r.next;
            i = self.firstNonBlankLine(r.next);
        }

        // A checklist is a list whose every item carries a box.
        var all_boxed = first.kind == .unordered and items.items.len > 0;
        for (checks.items) |c| if (c == null) {
            all_boxed = false;
        };
        if (all_boxed) {
            for (items.items, checks.items) |item, c| self.b.nodes.items[item].kind = .{ .task_list_item = .{ .checked = c.? } };
        } else {
            // A box on an item of a list that is not a checklist is text, and
            // is put back in front of the item's principal.
            for (items.items, boxes.items) |item, box_opt| {
                const box = box_opt orelse continue;
                const box_str = try self.b.addLeaf(.{ .str = self.source[box.start..box.end] });
                self.b.setSpan(box_str, box);
                var kids: std.ArrayList(Node.Id) = .empty;
                defer kids.deinit(self.allocator);
                try kids.append(self.allocator, box_str);
                var c = self.b.nodes.items[item].first_child;
                while (c) |cid| : (c = self.b.nodes.items[cid].next_sibling) try kids.append(self.allocator, cid);
                self.b.setChildren(item, kids.items);
            }
        }

        const kind: Node.Kind = switch (first.kind) {
            .unordered => if (all_boxed) .{ .task_list = .{ .tight = true } } else .{ .bullet_list = .{ .tight = true } },
            .ordered => .{ .ordered_list = .{ .numbering = first.numbering, .tight = true, .start = first.start } },
            .callout => .{ .ordered_list = .{ .numbering = .decimal, .tight = true, .start = null } },
            .description => .definition_list,
        };
        const id = try self.b.addContainer(kind, items.items);
        switch (first.kind) {
            .unordered => self.b.setSpelling(id, .{ .bullet = bulletFromChar(first.text[0]) }),
            .ordered => self.b.setSpelling(id, .{ .ordered_delim = first.delim }),
            .callout, .description => {},
        }
        const meta_start = try self.applyMeta(&meta, id, &.{});
        const start = meta_start orelse self.lines[lo].start;
        self.b.setSpan(id, Span.init(start, last_end));
        return .{ .id = id, .next = next_line, .start_offset = start, .end_offset = last_end };
    }

    const ItemResult = struct { id: Node.Id, next: usize, end_offset: usize, checked: ?bool, box: ?Span = null };

    fn parseListItem(self: *Parser, i: usize, hi: usize, m: ListMarker, list_key: []const u8) Allocator.Error!ItemResult {
        const line_start = self.lines[i].start;
        var kids: std.ArrayList(Node.Id) = .empty;
        defer kids.deinit(self.allocator);
        var terms: std.ArrayList(Node.Id) = .empty;
        defer terms.deinit(self.allocator);

        var cur = i;
        var text_start: ?usize = null;
        var checked: ?bool = null;
        var box: ?Span = null;
        var marker_span = Span.init(line_start + (self.leadingSpaces(i)), line_start + m.text_at);

        if (m.kind == .description) {
            var mm = m;
            while (true) {
                const term_ids = try parseInlines(self.inlineCtx(), mm.term, self.lines[cur].start + mm.term_at);
                defer self.allocator.free(term_ids);
                const term_id = try self.b.addContainer(.term, term_ids);
                self.b.setSpan(term_id, Span.init(self.lines[cur].start + mm.term_at, self.lines[cur].start + mm.term_at + mm.term.len));
                try terms.append(self.allocator, term_id);
                marker_span = Span.init(self.lines[cur].start + mm.term_at + mm.term.len, self.lines[cur].start + mm.text_at);
                if (mm.text_at < self.lineText(cur).len) {
                    text_start = self.lines[cur].start + mm.text_at;
                    break;
                }
                cur += 1;
                if (cur < hi) if (self.matchListMarker(cur)) |nm| if (nm.kind == .description and std.mem.eql(u8, nm.key(), list_key)) {
                    mm = nm;
                    continue;
                };
                // The description on the following line(s), possibly after a blank.
                const q = self.firstNonBlankLine(cur);
                if (q < hi and self.matchListMarker(q) == null and !self.isBlockStart(q)) {
                    cur = q;
                    text_start = self.lines[q].start + self.leadingSpaces(q);
                }
                break;
            }
        } else {
            var at = m.text_at;
            const t = self.lineText(i);
            if (m.kind == .unordered and t.len >= at + 4 and t[at] == '[' and t[at + 2] == ']' and t[at + 3] == ' ' and std.mem.indexOfScalar(u8, " xX*", t[at + 1]) != null) {
                checked = t[at + 1] != ' ';
                const box_start = line_start + at;
                at += 4;
                while (at < t.len and t[at] == ' ') at += 1;
                box = Span.init(box_start, line_start + at);
            }
            text_start = line_start + at;
        }

        var end_offset: usize = marker_span.end;
        var end_line = cur; // the line after the last consumed content
        if (text_start) |ts| {
            // The principal text runs onto following lines that are neither
            // blank nor the start of another block or list item.
            end_line = cur + 1;
            while (end_line < hi and !self.isBlankLine(end_line) and !self.isBlockStart(end_line) and self.matchListMarker(end_line) == null) end_line += 1;
            const text = std.mem.trimEnd(u8, self.source[ts..self.lines[end_line - 1].end], " \t");
            const ids = try parseInlines(self.inlineCtx(), text, ts);
            defer self.allocator.free(ids);
            try kids.appendSlice(self.allocator, ids);
            end_offset = ts + text.len;
        } else {
            end_line = cur;
            end_offset = marker_span.end;
        }

        // Attached blocks: nested lists, `+` continuations, and blank-separated
        // indented literals.
        var j = end_line;
        while (j < hi) {
            const q = self.firstNonBlankLine(j);
            if (q >= hi) break;
            if (self.isContinuation(q)) {
                var k = self.firstNonBlankLine(q + 1);
                if (k >= hi) break;
                while (k < hi and self.isMetaLine(k)) : (k += 1) try self.collectMeta(k);
                if (k >= hi) break;
                const r = (try self.parseBlockAt(k, hi)) orelse break;
                if (r.id) |bid| {
                    try kids.append(self.allocator, bid);
                    end_offset = r.end_offset;
                }
                j = r.next;
                continue;
            }
            if (self.matchListMarker(q)) |nm| {
                const nk = nm.key();
                if (std.mem.eql(u8, nk, list_key)) break;
                var is_ancestor = false;
                for (self.list_stack.items) |k| if (std.mem.eql(u8, k, nk)) {
                    is_ancestor = true;
                };
                if (is_ancestor) break;
                const r = try self.parseList(q, hi, nm);
                try kids.append(self.allocator, r.id.?);
                end_offset = r.end_offset;
                j = r.next;
                continue;
            }
            if (q > j and self.leadingSpaces(q) > 0 and !self.isBlockStart(q)) {
                const r = try self.parseIndentedLiteral(q, hi);
                try kids.append(self.allocator, r.id.?);
                end_offset = r.end_offset;
                j = r.next;
                continue;
            }
            break;
        }

        var id: Node.Id = undefined;
        if (m.kind == .description) {
            var all: std.ArrayList(Node.Id) = .empty;
            defer all.deinit(self.allocator);
            try all.appendSlice(self.allocator, terms.items);
            if (kids.items.len > 0) {
                const def = try self.b.addContainer(.definition, kids.items);
                const def_start = text_start orelse self.b.spans.items[kids.items[0]].start;
                self.b.setSpan(def, Span.init(def_start, end_offset));
                try all.append(self.allocator, def);
            }
            id = try self.b.addContainer(.definition_list_item, all.items);
        } else {
            id = try self.b.addContainer(.list_item, kids.items);
            switch (m.kind) {
                .unordered => self.b.setSpelling(id, .{ .bullet = bulletFromChar(m.text[0]) }),
                .ordered => self.b.setSpelling(id, .{ .ordered_delim = m.delim }),
                else => {},
            }
        }
        self.b.setSpan(id, Span.init(line_start + self.leadingSpaces(i), end_offset));
        self.b.setMarkerSpan(id, marker_span);
        return .{ .id = id, .next = j, .end_offset = end_offset, .checked = checked, .box = box };
    }
};

/// A block macro line: `name::target[attrs]`.
pub const BlockMacro = struct { name: []const u8, target: []const u8, attrs: []const u8 };

pub fn matchBlockMacroText(t: []const u8) ?BlockMacro {
    inline for (.{ "image", "audio", "video", "toc" }) |name| {
        if (std.mem.startsWith(u8, t, name ++ "::")) {
            const rest = t[name.len + 2 ..];
            const open = std.mem.indexOfScalar(u8, rest, '[') orelse return null;
            if (t[t.len - 1] != ']') return null;
            const target = rest[0..open];
            if (std.mem.indexOfAny(u8, target, " \t") != null) return null;
            return .{ .name = name, .target = target, .attrs = rest[open + 1 .. rest.len - 1] };
        }
    }
    return null;
}

fn bulletFromChar(ch: u8) Document.Spelling.Bullet {
    return switch (ch) {
        '*' => .star,
        '-' => .dash,
        '+' => .plus,
        else => unreachable,
    };
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

// ── inlines ──────────────────────────────────────────────────────────────

/// What the inline scanner needs beyond the text: the builder, and the
/// document-wide footnote counter that numbers `footnote:[]` macros.
pub const InlineCtx = struct {
    b: *Builder,
    footnotes: *u32,
    /// The `%hardbreaks` option: every newline is a hard break.
    hardbreaks: bool = false,
};

/// Scan `text` (a slice of `source` starting at byte offset `base`) for
/// inline markup, returning the resulting run of nodes. See the module doc
/// comment for the constructs recognized.
pub fn parseInlines(ctx: InlineCtx, text: []const u8, base: usize) Allocator.Error![]Node.Id {
    var s = Scanner{ .ctx = ctx, .text = text, .base = base };
    defer s.buf.deinit(ctx.b.allocator);
    errdefer s.ids.deinit(ctx.b.allocator);
    try s.run();
    return s.ids.toOwnedSlice(ctx.b.allocator);
}

/// The single-character constrained spans that nest — `*strong*`, `_emphasis_`,
/// `#mark#` — and the marks they build. `` `monospace` `` follows the same
/// boundary rule but builds a `text_leaf{.verbatim}` leaf, since
/// `AST.InlineMark` is scoped to the marks djot spells.
const MARK_SPANS = [_]struct { char: u8, mark: AST.InlineMark }{
    .{ .char = '*', .mark = .strong },
    .{ .char = '_', .mark = .emph },
    .{ .char = '#', .mark = .mark },
};
const MONOSPACE_CHAR: u8 = '`';

fn markForChar(c: u8) ?AST.InlineMark {
    for (MARK_SPANS) |m| {
        if (m.char == c) return m.mark;
    }
    return null;
}

fn isSpanDelimiter(c: u8) bool {
    return markForChar(c) != null or c == MONOSPACE_CHAR;
}

/// May `text[i]`, a candidate delimiter byte, OPEN a constrained span? Not
/// preceded by a word character, not followed by whitespace or end of text.
fn opensConstrained(text: []const u8, i: usize) bool {
    if (i > 0 and isWordByte(text[i - 1])) return false;
    if (i + 1 >= text.len) return false;
    return !isSpaceByte(text[i + 1]);
}

/// The index of the delimiter byte `delim` that CLOSES a constrained span
/// opened at `open_idx`: not preceded by whitespace, not followed by a word
/// character. Starts at `open_idx + 2`, so the interior is at least one byte
/// — asciidoctor's `(\S|\S.*?\S)` likewise cannot match empty.
fn findConstrainedClose(text: []const u8, delim: u8, open_idx: usize) ?usize {
    var j = open_idx + 2;
    while (j < text.len) : (j += 1) {
        if (text[j] != delim) continue;
        const before_space = isSpaceByte(text[j - 1]);
        const after_word = j + 1 < text.len and isWordByte(text[j + 1]);
        if (!before_space and !after_word) return j;
    }
    return null;
}

/// The index of the FIRST byte of the doubled delimiter that closes an
/// UNCONSTRAINED span opened at `open_idx`: a plain scan for the next pair,
/// non-greedy like asciidoctor's `\*\*(.+?)\*\*`, with a non-empty interior.
fn findUnconstrainedClose(text: []const u8, delim: u8, open_idx: usize) ?usize {
    var j = open_idx + 3;
    while (j + 1 < text.len) : (j += 1) {
        if (text[j] == delim and text[j + 1] == delim) return j;
    }
    return null;
}

/// Asciidoctor's intrinsic character-replacement attributes: a `{name}` that
/// is text rather than a reference to something the document defined.
const INTRINSICS = std.StaticStringMap([]const u8).initComptime(.{
    .{ "sp", " " },           .{ "empty", "" },         .{ "blank", "" },
    .{ "plus", "+" },         .{ "caret", "^" },        .{ "tilde", "~" },
    .{ "startsb", "[" },      .{ "endsb", "]" },        .{ "vbar", "|" },
    .{ "amp", "&" },          .{ "lt", "<" },           .{ "gt", ">" },
    .{ "backslash", "\\" },   .{ "apos", "'" },         .{ "quot", "\"" },
    .{ "deg", "\u{b0}" },     .{ "two-colons", "::" },  .{ "two-semicolons", ";;" },
    .{ "cpp", "C++" },        .{ "zwsp", "\u{200b}" },  .{ "wj", "\u{2060}" },
    .{ "lsquo", "\u{2018}" }, .{ "rsquo", "\u{2019}" }, .{ "ldquo", "\u{201c}" },
    .{ "rdquo", "\u{201d}" }, .{ "brvbar", "\u{a6}" },  .{ "pp", "++" },
    .{ "asterisk", "*" },
});

const Scanner = struct {
    ctx: InlineCtx,
    text: []const u8,
    base: usize,
    i: usize = 0,
    ids: std.ArrayList(Node.Id) = .empty,
    /// The plain-text run being accumulated, and the source extent it covers
    /// (which can be wider than the text — a `\*` escape is two bytes of source
    /// for one of text).
    buf: std.ArrayList(u8) = .empty,
    run_start: usize = 0,
    run_end: usize = 0,
    /// The interior of a `[…]` attribute list parsed just before a span
    /// opener, applied to the span it precedes.
    pending_attrs: ?[]const u8 = null,

    fn alloc(self: *const Scanner) Allocator {
        return self.ctx.b.allocator;
    }

    fn plain(self: *Scanner, from: usize, to: usize) Allocator.Error!void {
        if (from >= to) return;
        try self.literal(self.text[from..to], from, to);
    }

    /// Append `bytes` to the text run as the reading of source `[from, to)`.
    fn literal(self: *Scanner, bytes: []const u8, from: usize, to: usize) Allocator.Error!void {
        if (self.buf.items.len == 0) self.run_start = self.base + from;
        try self.buf.appendSlice(self.alloc(), bytes);
        self.run_end = self.base + to;
    }

    fn flush(self: *Scanner) Allocator.Error!void {
        if (self.buf.items.len == 0) return;
        const id = try self.ctx.b.addLeaf(.{ .str = self.buf.items });
        self.ctx.b.setSpan(id, Span.init(self.run_start, self.run_end));
        try self.ids.append(self.alloc(), id);
        self.buf.clearRetainingCapacity();
    }

    fn emit(self: *Scanner, id: Node.Id) Allocator.Error!void {
        try self.flush();
        try self.ids.append(self.alloc(), id);
    }

    fn span(self: *const Scanner, from: usize, to: usize) Span {
        return Span.init(self.base + from, self.base + to);
    }

    fn leaf(self: *Scanner, kind: Node.Kind, from: usize, to: usize) Allocator.Error!Node.Id {
        const id = try self.ctx.b.addLeaf(kind);
        self.ctx.b.setSpan(id, self.span(from, to));
        return id;
    }

    fn container(self: *Scanner, kind: Node.Kind, kids: []const Node.Id, from: usize, to: usize) Allocator.Error!Node.Id {
        const id = try self.ctx.b.addContainer(kind, kids);
        self.ctx.b.setSpan(id, self.span(from, to));
        return id;
    }

    /// Parse `[from, to)` of this text as a nested inline run.
    fn sub(self: *Scanner, from: usize, to: usize) Allocator.Error![]Node.Id {
        return parseInlines(self.ctx, self.text[from..to], self.base + from);
    }

    fn strAt(self: *Scanner, from: usize, to: usize) Allocator.Error!Node.Id {
        return self.leaf(.{ .str = self.text[from..to] }, from, to);
    }

    fn run(self: *Scanner) Allocator.Error!void {
        while (self.i < self.text.len) {
            const c = self.text[self.i];
            const handled = switch (c) {
                '\\' => try self.tryEscape(),
                '+' => try self.tryPass(),
                '`', '*', '_', '#' => try self.trySpan(),
                '^', '~' => try self.trySupSub(),
                '"', '\'' => try self.tryCurved(),
                '<' => try self.tryAngle(),
                '[' => try self.tryBracket(),
                '{' => try self.tryAttrRef(),
                '&' => try self.tryCharref(),
                '(', '-', '=', '.' => try self.tryReplacement(),
                ' ' => try self.tryHardBreak(),
                '\n' => try self.tryNewline(),
                else => if (std.ascii.isAlphanumeric(c)) try self.tryWord() else false,
            };
            if (!handled) {
                try self.plain(self.i, self.i + 1);
                self.i += 1;
            }
        }
        try self.flush();
    }

    // ── escapes, passthroughs, replacements ───────────────────────────────

    /// `\` before a byte that would otherwise open a construct reads as that
    /// byte; `\\` as one backslash; `\` before a macro or URL scheme
    /// suppresses the macro; any other `\` is itself.
    fn tryEscape(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        if (i + 1 >= self.text.len) return false;
        const n = self.text[i + 1];
        if (std.mem.indexOfScalar(u8, "\\*_`#^~+{}[]<>&|(-=.'\"", n) != null) {
            try self.literal(self.text[i + 1 .. i + 2], i, i + 2);
            self.i = i + 2;
            return true;
        }
        if (std.ascii.isAlphabetic(n)) {
            // A scheme or macro name followed by a colon: copy it through as text
            // with the colon, so the scanner never sees a macro to open.
            var j = i + 1;
            while (j < self.text.len and (std.ascii.isAlphanumeric(self.text[j]) or self.text[j] == '-')) j += 1;
            if (j < self.text.len and self.text[j] == ':') {
                try self.literal(self.text[i + 1 .. j + 1], i, j + 1);
                self.i = j + 1;
                return true;
            }
        }
        return false;
    }

    fn tryPass(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        if (std.mem.startsWith(u8, t[i..], "+++")) {
            if (std.mem.indexOfPos(u8, t, i + 3, "+++")) |close| {
                if (close > i + 3) {
                    const id = try self.leaf(.{ .raw_inline = .{ .format = "html", .text = t[i + 3 .. close] } }, i, close + 3);
                    self.ctx.b.setContentSpan(id, self.span(i + 3, close));
                    try self.emit(id);
                    self.i = close + 3;
                    return true;
                }
            }
        }
        if (std.mem.startsWith(u8, t[i..], "++")) {
            if (findUnconstrainedClose(t, '+', i)) |close| {
                try self.emit(try self.leaf(.{ .str = t[i + 2 .. close] }, i, close + 2));
                self.i = close + 2;
                return true;
            }
        }
        if (!opensConstrained(t, i)) return false;
        const close = findConstrainedClose(t, '+', i) orelse return false;
        try self.emit(try self.leaf(.{ .str = t[i + 1 .. close] }, i, close + 1));
        self.i = close + 1;
        return true;
    }

    fn tryReplacement(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        const rest = t[i..];
        const Rep = struct { from: []const u8, to: []const u8 };
        const reps = [_]Rep{
            .{ .from = "(C)", .to = "\u{a9}" },    .{ .from = "(R)", .to = "\u{ae}" },
            .{ .from = "(TM)", .to = "\u{2122}" }, .{ .from = "->", .to = "\u{2192}" },
            .{ .from = "=>", .to = "\u{21d2}" },
        };
        for (reps) |r| {
            if (std.mem.startsWith(u8, rest, r.from)) {
                try self.literal(r.to, i, i + r.from.len);
                self.i = i + r.from.len;
                return true;
            }
        }
        if (std.mem.startsWith(u8, rest, "--") and !(rest.len > 2 and rest[2] == '-') and !(i > 0 and t[i - 1] == '-')) {
            const before_ok = i == 0 or isWordByte(t[i - 1]) or t[i - 1] == ' ';
            const after_ok = i + 2 >= t.len or isWordByte(t[i + 2]) or t[i + 2] == ' ' or t[i + 2] == '\n';
            if (before_ok and after_ok) {
                try self.emit(try self.leaf(.{ .smart_punctuation = .em_dash }, i, i + 2));
                self.i = i + 2;
                return true;
            }
        }
        if (std.mem.startsWith(u8, rest, "...") and !(rest.len > 3 and rest[3] == '.')) {
            try self.emit(try self.leaf(.{ .smart_punctuation = .ellipses }, i, i + 3));
            self.i = i + 3;
            return true;
        }
        return false;
    }

    /// `&name;`, `&#NNN;`, `&#xHH;` — its own `str` node holding the decoded
    /// character, so the codec can tell it from surrounding text.
    fn tryCharref(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        const semi = std.mem.indexOfScalarPos(u8, t, i + 1, ';') orelse return false;
        var decoded: [4]u8 = undefined;
        const value = decodeCharref(t[i .. semi + 1], &decoded) orelse return false;
        try self.emit(try self.leaf(.{ .str = value }, i, semi + 1));
        self.i = semi + 1;
        return true;
    }

    /// `{name}` — an attribute reference, or one of the intrinsic character
    /// attributes, which are text.
    fn tryAttrRef(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        const close = std.mem.indexOfScalarPos(u8, t, i + 1, '}') orelse return false;
        const name = t[i + 1 .. close];
        if (name.len == 0) return false;
        for (name, 0..) |c, k| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or (k > 0 and c == '-'))) return false;
        }
        if (std.mem.eql(u8, name, "nbsp")) {
            try self.emit(try self.leaf(.non_breaking_space, i, close + 1));
        } else if (INTRINSICS.get(name)) |rep| {
            try self.literal(rep, i, close + 1);
        } else {
            const id = try self.leaf(.{ .text_leaf = .{ .kind = .substitution_reference, .text = name } }, i, close + 1);
            self.ctx.b.setContentSpan(id, self.span(i + 1, close));
            try self.emit(id);
        }
        self.i = close + 1;
        return true;
    }

    fn tryHardBreak(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        if (i + 1 >= t.len or t[i + 1] != '+') return false;
        if (i + 2 == t.len) {
            try self.emit(try self.leaf(.hard_break, i, i + 2));
            self.i = i + 2;
            return true;
        }
        if (t[i + 2] == '\n') {
            try self.emit(try self.leaf(.hard_break, i, i + 3));
            self.i = i + 3;
            return true;
        }
        return false;
    }

    fn tryNewline(self: *Scanner) Allocator.Error!bool {
        if (!self.ctx.hardbreaks) return false;
        try self.emit(try self.leaf(.hard_break, self.i, self.i + 1));
        self.i += 1;
        return true;
    }

    // ── spans ─────────────────────────────────────────────────────────────

    /// `*strong*`, `_emphasis_`, `#mark#`, `` `mono` `` in both forms.
    /// Unconstrained is tried FIRST: asciidoctor applies its unconstrained
    /// patterns ahead of the constrained ones, and the constrained scan is
    /// actively wrong on a doubled delimiter (`**bold**` came out as
    /// `<strong>*bold</strong>*`). A doubled opener with no doubled close
    /// falls through to the constrained scan, as asciidoctor does.
    fn trySpan(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        const delim = t[i];
        const doubled = i + 1 < t.len and t[i + 1] == delim;
        if (doubled) {
            if (findUnconstrainedClose(t, delim, i)) |close| {
                try self.emitSpan(delim, i + 2, close, i, close + 2);
                self.i = close + 2;
                return true;
            }
        }
        if (!opensConstrained(t, i)) return false;
        const close = findConstrainedClose(t, delim, i) orelse return false;
        try self.emitSpan(delim, i + 1, close, i, close + 1);
        self.i = close + 1;
        return true;
    }

    /// Build the one node a span delimiter produces over `[ifrom, ito)`, with
    /// any pending `[.role]` attributes applied. Nothing records WHICH form
    /// was used: the span's own source spells it, and `asg.zig`'s `spanForm`
    /// reads it back.
    fn emitSpan(self: *Scanner, delim: u8, ifrom: usize, ito: usize, from: usize, to: usize) Allocator.Error!void {
        const attrs = self.pending_attrs;
        self.pending_attrs = null;
        var id: Node.Id = undefined;
        if (delim == MONOSPACE_CHAR) {
            id = try self.leaf(.{ .text_leaf = .{ .kind = .verbatim, .text = self.text[ifrom..ito] } }, from, to);
            self.ctx.b.setContentSpan(id, self.span(ifrom, ito));
        } else {
            const kids = try self.sub(ifrom, ito);
            defer self.alloc().free(kids);
            // A role on a `#` span makes it a plain styled span, which is what
            // asciidoctor renders (`<span class="role">`), not a highlight.
            const kind: Node.Kind = if (delim == '#' and attrs != null) .{ .container = .{ .name = "", .form = .inline_text } } else .{ .inline_mark = markForChar(delim).? };
            id = try self.container(kind, kids, from, to);
            if (kind == .container) self.ctx.b.setSpelling(id, .{ .container_origin = .directive });
            self.ctx.b.setContentSpan(id, self.span(ifrom, ito));
        }
        if (attrs) |a| try self.applyInlineAttrs(id, a);
        try self.emit(id);
    }

    /// The `[…]` before a span: `[.role]`, `[#id.role]`, `[role]`,
    /// `[role=x]`, `[id=x]`.
    fn applyInlineAttrs(self: *Scanner, id: Node.Id, interior: []const u8) Allocator.Error!void {
        var entries: std.ArrayList(AST.KeyVal) = .empty;
        defer entries.deinit(self.alloc());
        var class: std.ArrayList(u8) = .empty;
        defer class.deinit(self.alloc());
        var anchor: ?[]const u8 = null;
        var it = AttrIter.init(interior);
        while (it.next()) |e| {
            if (e.key) |k| {
                if (std.mem.eql(u8, k, "role")) {
                    if (class.items.len > 0) try class.append(self.alloc(), ' ');
                    try class.appendSlice(self.alloc(), e.value);
                } else if (std.mem.eql(u8, k, "id")) {
                    anchor = e.value;
                } else try entries.append(self.alloc(), .{ .key = k, .value = e.value });
            } else if (e.index == 1) {
                var sit = ShorthandIter.init(e.value);
                while (sit.next()) |p| switch (p.kind) {
                    .id => anchor = p.text,
                    .style, .role => {
                        if (class.items.len > 0) try class.append(self.alloc(), ' ');
                        try class.appendSlice(self.alloc(), p.text);
                    },
                    .option => {},
                };
            }
        }
        var all: std.ArrayList(AST.KeyVal) = .empty;
        defer all.deinit(self.alloc());
        if (anchor) |a| try all.append(self.alloc(), .{ .key = "id", .value = a });
        if (class.items.len > 0) try all.append(self.alloc(), .{ .key = "class", .value = class.items });
        try all.appendSlice(self.alloc(), entries.items);
        if (all.items.len > 0) try self.ctx.b.setAttrs(id, .{ .entries = all.items });
    }

    /// `^sup^` and `~sub~`: unconstrained, single delimiter, no whitespace
    /// inside.
    fn trySupSub(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        const delim = t[i];
        var j = i + 1;
        while (j < t.len and t[j] != delim) : (j += 1) {
            if (isSpaceByte(t[j])) return false;
        }
        if (j >= t.len or j == i + 1) return false;
        const attrs = self.pending_attrs;
        self.pending_attrs = null;
        const kids = try self.sub(i + 1, j);
        defer self.alloc().free(kids);
        const id = try self.container(.{ .inline_mark = if (delim == '^') .superscript else .subscript }, kids, i, j + 1);
        self.ctx.b.setContentSpan(id, self.span(i + 1, j));
        if (attrs) |a| try self.applyInlineAttrs(id, a);
        try self.emit(id);
        self.i = j + 1;
        return true;
    }

    /// Asciidoctor's curved quotes: `"`text`"` and `'`text`'`.
    fn tryCurved(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        if (i + 1 >= t.len or t[i + 1] != '`') return false;
        const closer: []const u8 = if (t[i] == '"') "`\"" else "`'";
        const close = std.mem.indexOfPos(u8, t, i + 2, closer) orelse return false;
        if (close == i + 2) return false;
        const kids = try self.sub(i + 2, close);
        defer self.alloc().free(kids);
        const id = try self.container(.{ .inline_mark = if (t[i] == '"') .double_quoted else .single_quoted }, kids, i, close + 2);
        self.ctx.b.setContentSpan(id, self.span(i + 2, close));
        try self.emit(id);
        self.i = close + 2;
        return true;
    }

    // ── references ────────────────────────────────────────────────────────

    fn tryAngle(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        if (std.mem.startsWith(u8, t[i..], "<<")) {
            const close = std.mem.indexOfPos(u8, t, i + 2, ">>") orelse return false;
            const interior = t[i + 2 .. close];
            if (interior.len == 0 or interior[0] == '<') return false;
            const comma = std.mem.indexOfScalar(u8, interior, ',');
            const target = std.mem.trim(u8, if (comma) |c| interior[0..c] else interior, " \t");
            if (target.len == 0 or std.mem.indexOfAny(u8, target, " \t\n") != null) return false;
            const text_from: usize = if (comma) |c| i + 2 + c + 1 else 0;
            try self.emitXref(target, if (comma != null) text_from else null, close, i, close + 2, i + 2, i + 2 + target.len);
            self.i = close + 2;
            return true;
        }
        if (std.mem.startsWith(u8, t[i..], "<-")) {
            try self.literal("\u{2190}", i, i + 2);
            self.i = i + 2;
            return true;
        }
        if (std.mem.startsWith(u8, t[i..], "<=")) {
            try self.literal("\u{21d0}", i, i + 2);
            self.i = i + 2;
            return true;
        }
        // `<https://…>` — the angle autolink.
        const close = std.mem.indexOfScalarPos(u8, t, i + 1, '>') orelse return false;
        const interior = t[i + 1 .. close];
        if (!isUrlStart(interior) or std.mem.indexOfAny(u8, interior, " \t\n<") != null) return false;
        const id = try self.leaf(.{ .text_leaf = .{ .kind = .url, .text = interior } }, i, close + 1);
        self.ctx.b.setContentSpan(id, self.span(i + 1, close));
        try self.emit(id);
        self.i = close + 1;
        return true;
    }

    /// A cross reference to `target`, with the visible text at
    /// `[text_from, text_to)` or — when `text_from` is null — the target
    /// itself, whose bytes sit at `[tfrom, tto)`.
    fn emitXref(self: *Scanner, target: []const u8, text_from: ?usize, text_to: usize, from: usize, to: usize, tfrom: usize, tto: usize) Allocator.Error!void {
        const dest = if (std.mem.indexOfScalar(u8, target, '#') != null) try self.alloc().dupe(u8, target) else try std.fmt.allocPrint(self.alloc(), "#{s}", .{target});
        defer self.alloc().free(dest);
        var kids: []Node.Id = &.{};
        var one: [1]Node.Id = undefined;
        if (text_from) |tf| {
            const trimmed_from = tf + (std.mem.indexOfNone(u8, self.text[tf..text_to], " \t") orelse 0);
            kids = try self.sub(trimmed_from, text_to);
        } else {
            one[0] = try self.strAt(tfrom, tto);
            kids = one[0..1];
        }
        defer if (text_from != null) self.alloc().free(kids);
        const id = try self.container(.{ .link = .{ .destination = dest, .reference = null } }, kids, from, to);
        if (text_from) |tf| self.ctx.b.setContentSpan(id, self.span(tf, text_to));
        try self.emit(id);
    }

    fn tryBracket(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        if (std.mem.startsWith(u8, t[i..], "[[")) {
            const close = std.mem.indexOfPos(u8, t, i + 2, "]]") orelse return false;
            const interior = t[i + 2 .. close];
            if (interior.len == 0 or std.mem.indexOfAny(u8, interior, " \t\n[") != null) return false;
            const id_text = if (std.mem.indexOfScalar(u8, interior, ',')) |c| interior[0..c] else interior;
            if (id_text.len == 0) return false;
            const id = try self.container(.{ .container = .{ .name = "", .form = .inline_text } }, &.{}, i, close + 2);
            self.ctx.b.setSpelling(id, .{ .container_origin = .directive });
            try self.ctx.b.setAttrs(id, .{ .entries = &.{.{ .key = "id", .value = id_text }} });
            try self.emit(id);
            self.i = close + 2;
            return true;
        }
        // `[.role]` directly before a span opener.
        const close = std.mem.indexOfScalarPos(u8, t, i + 1, ']') orelse return false;
        const interior = t[i + 1 .. close];
        if (interior.len == 0 or std.mem.indexOfAny(u8, interior, "\n[") != null) return false;
        if (close + 1 >= t.len) return false;
        const opener = t[close + 1];
        if (!(isSpanDelimiter(opener) or opener == '^' or opener == '~')) return false;
        // The list must be roles/ids only, not arbitrary text.
        var it = AttrIter.init(interior);
        while (it.next()) |e| {
            if (e.key) |k| {
                if (!std.mem.eql(u8, k, "role") and !std.mem.eql(u8, k, "id")) return false;
            } else if (e.index == 1) {
                if (std.mem.indexOfAny(u8, e.value, " \t") != null) return false;
            } else return false;
        }
        self.pending_attrs = interior;
        self.i = close + 1;
        const ok = if (isSpanDelimiter(opener)) try self.trySpan() else try self.trySupSub();
        if (ok) {
            // The attribute list is part of the span it styles: the node's
            // extent grows to cover it, and its own range is recorded.
            const id = self.ids.items[self.ids.items.len - 1];
            self.ctx.b.spans.items[id].start = self.base + i;
            self.ctx.b.setAttrsSpan(id, self.span(i, close + 1));
            return true;
        }
        self.pending_attrs = null;
        self.i = i;
        return false;
    }

    fn tryWord(self: *Scanner) Allocator.Error!bool {
        const i = self.i;
        const t = self.text;
        if (i > 0 and isWordByte(t[i - 1])) return false;
        var j = i;
        while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '-' or t[j] == '_')) j += 1;
        const name = t[i..j];
        if (j < t.len and t[j] == ':') {
            if (isUrlStart(t[i..])) return try self.tryUrl(i);
            if (try self.tryMacro(name, i, j + 1)) return true;
        }
        return try self.tryEmail(i);
    }

    /// A bare or bracketed URL starting at `start`.
    fn tryUrl(self: *Scanner, start: usize) Allocator.Error!bool {
        const t = self.text;
        var k = start;
        while (k < t.len and !isSpaceByte(t[k]) and std.mem.indexOfScalar(u8, "[]<", t[k]) == null) k += 1;
        if (k < t.len and t[k] == '[') {
            const close = findBracketClose(t, k) orelse return false;
            try self.emitLink(t[start..k], k + 1, close, start, close + 1, start, k);
            self.i = close + 1;
            return true;
        }
        // Trailing punctuation belongs to the sentence, not the URL.
        while (k > start and std.mem.indexOfScalar(u8, ",.?!;:)\"'", t[k - 1]) != null) k -= 1;
        const url = t[start..k];
        if (std.mem.endsWith(u8, url, "://")) return false;
        try self.emit(try self.leaf(.{ .text_leaf = .{ .kind = .url, .text = url } }, start, k));
        self.i = k;
        return true;
    }

    /// A `link` whose text is `[tfrom, tto)` (the bracket interior) or, when
    /// that is empty, the destination's own bytes at `[dfrom, dto)`.
    fn emitLink(self: *Scanner, dest: []const u8, tfrom: usize, tto: usize, from: usize, to: usize, dfrom: usize, dto: usize) Allocator.Error!void {
        var text_to = tto;
        var interior = self.text[tfrom..tto];
        var window: ?[]const u8 = null;
        var role: ?[]const u8 = null;
        // `[text,key=value]`: a trailing named-attribute list; `[text^]`: a new window.
        if (std.mem.indexOfScalar(u8, interior, ',')) |comma| {
            const rest = std.mem.trim(u8, interior[comma + 1 ..], " \t");
            if (looksLikeAttrList(rest)) {
                var it = AttrIter.init(rest);
                while (it.next()) |e| {
                    if (e.key) |k| {
                        if (std.mem.eql(u8, k, "window")) window = e.value else if (std.mem.eql(u8, k, "role")) role = e.value;
                    }
                }
                text_to = tfrom + comma;
                interior = self.text[tfrom..text_to];
            }
        }
        if (std.mem.endsWith(u8, interior, "^")) {
            window = "_blank";
            text_to -= 1;
            interior = self.text[tfrom..text_to];
        }
        var kids: []Node.Id = &.{};
        var one: [1]Node.Id = undefined;
        const has_text = std.mem.trim(u8, interior, " \t").len > 0;
        if (has_text) {
            kids = try self.sub(tfrom, text_to);
        } else {
            one[0] = try self.strAt(dfrom, dto);
            kids = one[0..1];
        }
        defer if (has_text) self.alloc().free(kids);
        const id = try self.container(.{ .link = .{ .destination = dest, .reference = null } }, kids, from, to);
        if (has_text) self.ctx.b.setContentSpan(id, self.span(tfrom, text_to));
        var attrs: [2]AST.KeyVal = undefined;
        var n: usize = 0;
        if (role) |r| {
            attrs[n] = .{ .key = "class", .value = r };
            n += 1;
        }
        if (window) |w| {
            attrs[n] = .{ .key = "window", .value = w };
            n += 1;
        }
        if (n > 0) try self.ctx.b.setAttrs(id, .{ .entries = attrs[0..n] });
        try self.emit(id);
    }

    fn tryMacro(self: *Scanner, name: []const u8, start: usize, target_from: usize) Allocator.Error!bool {
        const t = self.text;
        var k = target_from;
        while (k < t.len and !isSpaceByte(t[k]) and t[k] != '[' and t[k] != ']') k += 1;
        if (k >= t.len or t[k] != '[') return false;
        const target = t[target_from..k];
        const close = findBracketClose(t, k) orelse return false;
        const ifrom = k + 1;
        const ito = close;
        const interior = t[ifrom..ito];
        const to = close + 1;

        if (std.mem.eql(u8, name, "link")) {
            if (target.len == 0) return false;
            try self.emitLink(target, ifrom, ito, start, to, target_from, k);
        } else if (std.mem.eql(u8, name, "mailto")) {
            if (target.len == 0) return false;
            const dest = try std.fmt.allocPrint(self.alloc(), "mailto:{s}", .{target});
            defer self.alloc().free(dest);
            // Only the first positional is the text; subject and body are dropped.
            var text_to = ito;
            if (std.mem.indexOfScalar(u8, interior, ',')) |c| text_to = ifrom + c;
            try self.emitLink(dest, ifrom, text_to, start, to, target_from, k);
        } else if (std.mem.eql(u8, name, "xref")) {
            if (target.len == 0) return false;
            try self.emitXref(target, if (interior.len > 0) ifrom else null, ito, start, to, target_from, k);
        } else if (std.mem.eql(u8, name, "image")) {
            if (target.len == 0) return false;
            try self.emitImage(target, interior, ifrom, start, to);
        } else if (std.mem.eql(u8, name, "footnote")) {
            try self.emitFootnote(target, ifrom, ito, start, to);
        } else if (std.mem.eql(u8, name, "anchor")) {
            if (target.len == 0) return false;
            const id = try self.container(.{ .container = .{ .name = "", .form = .inline_text } }, &.{}, start, to);
            self.ctx.b.setSpelling(id, .{ .container_origin = .directive });
            try self.ctx.b.setAttrs(id, .{ .entries = &.{.{ .key = "id", .value = target }} });
            try self.emit(id);
        } else if (std.mem.eql(u8, name, "pass")) {
            const id = try self.leaf(.{ .raw_inline = .{ .format = "html", .text = interior } }, start, to);
            if (ito > ifrom) self.ctx.b.setContentSpan(id, self.span(ifrom, ito));
            try self.emit(id);
        } else if (std.mem.eql(u8, name, "stem") or std.mem.eql(u8, name, "latexmath") or std.mem.eql(u8, name, "asciimath")) {
            const id = try self.leaf(.{ .text_leaf = .{ .kind = .inline_math, .text = interior } }, start, to);
            if (ito > ifrom) self.ctx.b.setContentSpan(id, self.span(ifrom, ito));
            try self.emit(id);
        } else if (std.mem.eql(u8, name, "kbd") or std.mem.eql(u8, name, "btn")) {
            if (target.len != 0 or interior.len == 0) return false;
            const label = try self.strAt(ifrom, ito);
            const kbd = std.mem.eql(u8, name, "kbd");
            const id = try self.container(.{ .container = .{ .name = if (kbd) "kbd" else "b", .form = .inline_text } }, &.{label}, start, to);
            self.ctx.b.setSpelling(id, .{ .container_origin = .directive });
            self.ctx.b.setContentSpan(id, self.span(ifrom, ito));
            if (!kbd) try self.ctx.b.setAttrs(id, .{ .entries = &.{.{ .key = "class", .value = "button" }} });
            try self.emit(id);
        } else return false;
        self.i = to;
        return true;
    }

    fn emitImage(self: *Scanner, target: []const u8, interior: []const u8, ifrom: usize, from: usize, to: usize) Allocator.Error!void {
        var alt: ?[]const u8 = null;
        var width: ?[]const u8 = null;
        var height: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var it = AttrIter.init(interior);
        while (it.next()) |e| {
            if (e.key) |k| {
                if (std.mem.eql(u8, k, "alt")) alt = e.value else if (std.mem.eql(u8, k, "width")) width = e.value else if (std.mem.eql(u8, k, "height")) height = e.value else if (std.mem.eql(u8, k, "title")) title = e.value;
            } else switch (e.index) {
                1 => alt = e.value,
                2 => width = e.value,
                3 => height = e.value,
                else => {},
            }
        }
        var one: [1]Node.Id = undefined;
        var n: usize = 0;
        if (alt) |a| if (a.len > 0) {
            const at = ifrom + (std.mem.indexOf(u8, interior, a) orelse 0);
            one[0] = try self.strAt(at, at + a.len);
            n = 1;
        };
        const id = try self.container(.{ .image = .{ .destination = target, .reference = null } }, one[0..n], from, to);
        var attrs: [3]AST.KeyVal = undefined;
        var k: usize = 0;
        if (width) |w| {
            attrs[k] = .{ .key = "width", .value = w };
            k += 1;
        }
        if (height) |h| {
            attrs[k] = .{ .key = "height", .value = h };
            k += 1;
        }
        if (title) |tt| {
            attrs[k] = .{ .key = "title", .value = tt };
            k += 1;
        }
        if (k > 0) try self.ctx.b.setAttrs(id, .{ .entries = attrs[0..k] });
        try self.emit(id);
    }

    /// `footnote:[text]` / `footnote:id[text]` / `footnote:id[]`: a
    /// `footnote_reference` leaf at the use, and — when there is text — a
    /// detached `footnote` definition holding it, labelled by the id or by the
    /// document-order number. The definition is attached to nothing, as
    /// djot's and Markdown's are (see `AST.definitionRoots`).
    fn emitFootnote(self: *Scanner, target: []const u8, ifrom: usize, ito: usize, from: usize, to: usize) Allocator.Error!void {
        var num_buf: [12]u8 = undefined;
        var label: []const u8 = target;
        if (label.len == 0) {
            self.ctx.footnotes.* += 1;
            label = std.fmt.bufPrint(&num_buf, "{d}", .{self.ctx.footnotes.*}) catch unreachable;
        }
        if (ito > ifrom) {
            const kids = try self.sub(ifrom, ito);
            defer self.alloc().free(kids);
            const para = try self.container(.para, kids, ifrom, ito);
            const def = try self.container(.{ .footnote = .{ .label = label } }, &.{para}, ifrom, ito);
            self.ctx.b.setContentSpan(def, self.span(ifrom, ito));
        }
        const ref = try self.leaf(.{ .text_leaf = .{ .kind = .footnote_reference, .text = label } }, from, to);
        if (ito > ifrom) self.ctx.b.setContentSpan(ref, self.span(ifrom, ito));
        try self.emit(ref);
    }

    fn tryEmail(self: *Scanner, start: usize) Allocator.Error!bool {
        const t = self.text;
        var k = start;
        while (k < t.len and (std.ascii.isAlphanumeric(t[k]) or std.mem.indexOfScalar(u8, "._%+-", t[k]) != null)) k += 1;
        if (k == start or k >= t.len or t[k] != '@') return false;
        const at = k;
        k += 1;
        const dom_start = k;
        var last_dot: ?usize = null;
        while (k < t.len and (std.ascii.isAlphanumeric(t[k]) or t[k] == '.' or t[k] == '-')) : (k += 1) {
            if (t[k] == '.') last_dot = k;
        }
        // Trailing dots belong to the sentence.
        while (k > dom_start and t[k - 1] == '.') k -= 1;
        const ld = last_dot orelse return false;
        if (ld <= dom_start or ld + 2 >= k + 1) return false;
        if (k - ld - 1 < 2) return false;
        for (t[ld + 1 .. k]) |c| if (!std.ascii.isAlphabetic(c)) return false;
        if (k < t.len and isWordByte(t[k])) return false;
        _ = at;
        try self.emit(try self.leaf(.{ .text_leaf = .{ .kind = .email, .text = t[start..k] } }, start, k));
        self.i = k;
        return true;
    }
};

/// Decode a character reference spelled `&name;`, `&#NNN;` or `&#xHH;`
/// (delimiters included) into the character it names, or null when `ref`
/// is not one. A numeric reference decodes into `buf`.
pub fn decodeCharref(ref: []const u8, buf: *[4]u8) ?[]const u8 {
    if (ref.len < 3 or ref[0] != '&' or ref[ref.len - 1] != ';') return null;
    const body = ref[1 .. ref.len - 1];
    if (body.len == 0 or body.len > 32) return null;
    if (body[0] == '#') {
        const num = if (body.len > 1 and (body[1] == 'x' or body[1] == 'X')) std.fmt.parseInt(u21, body[2..], 16) catch return null else std.fmt.parseInt(u21, body[1..], 10) catch return null;
        const n = std.unicode.utf8Encode(if (num == 0) 0xfffd else num, buf) catch return null;
        return buf[0..n];
    }
    for (body) |c| if (!std.ascii.isAlphanumeric(c)) return null;
    return entities.table.get(body);
}

fn isUrlStart(s: []const u8) bool {
    inline for (.{ "https://", "http://", "ftp://", "irc://", "file://" }) |scheme| {
        if (std.mem.startsWith(u8, s, scheme)) return true;
    }
    return false;
}

/// Does `s` (the part of a link's bracket after its first comma) read as an
/// attribute list — its first entry a `key=value` pair?
fn looksLikeAttrList(s: []const u8) bool {
    var it = AttrIter.init(s);
    const first = it.next() orelse return false;
    return first.key != null;
}

/// The index of the `]` matching the `[` at `open`, honouring `\]` and
/// nested brackets, or null.
fn findBracketClose(t: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var k = open;
    while (k < t.len) : (k += 1) {
        const c = t[k];
        if (c == '\\' and k + 1 < t.len) {
            k += 1;
            continue;
        }
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return k;
        }
    }
    return null;
}

fn computeLines(allocator: Allocator, source: []const u8) Allocator.Error![]LineInfo {
    var list: std.ArrayList(LineInfo) = .empty;
    errdefer list.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            try list.append(allocator, .{ .start = start, .end = i });
            start = i + 1;
        }
    }
    // Only a source that does NOT end in a newline has a final partial line.
    if (start < source.len) try list.append(allocator, .{ .start = start, .end = source.len });
    return list.toOwnedSlice(allocator);
}

/// Map an offset in a stripped scratch source (see `parseMarkdownQuote`)
/// back to the real source, through the real offset of each scratch line.
fn mapOffset(offsets: []const usize, scratch: []const u8, off: usize) usize {
    var line: usize = 0;
    var line_start: usize = 0;
    var k: usize = 0;
    while (k < off and k < scratch.len) : (k += 1) {
        if (scratch[k] == '\n') {
            line += 1;
            line_start = k + 1;
        }
    }
    if (line >= offsets.len) return offsets[offsets.len - 1] + (off - line_start);
    return offsets[line] + (off - line_start);
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// The corpora (`conformance.zig`) judge every shape the ASG schema has a name
// for. What is tested here is the rest: the constructs draft-01 does not
// model, the tree-side facts the ASG comparison cannot see (attributes,
// spellings, marker spans, node kinds), and the parser's own edge cases.

const testing = std.testing;

fn firstBlock(doc: *const Document) Node.Id {
    return doc.ast.nodes[doc.ast.root].first_child.?;
}

fn nth(doc: *const Document, parent: Node.Id, n: usize) Node.Id {
    var id = doc.ast.nodes[parent].first_child.?;
    var i: usize = 0;
    while (i < n) : (i += 1) id = doc.ast.nodes[id].next_sibling.?;
    return id;
}

test "a single paragraph" {
    var doc = try parse(testing.allocator, "A paragraph that consists of a single line.\n");
    defer doc.deinit();
    const para = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[para].kind == .para);
    try testing.expectEqualStrings("A paragraph that consists of a single line.", doc.ast.nodes[doc.ast.nodes[para].first_child.?].kind.str);
}

test "a document title becomes the top-level heading, attribute entries attach to the document" {
    var doc = try parse(testing.allocator, "= Document Title\n:icons: font\n:toc:\n");
    defer doc.deinit();
    const ast = doc.ast;
    const attrs_marker = firstBlock(&doc);
    try testing.expectEqualStrings("document-attributes", ast.nodes[attrs_marker].kind.container.name);
    try testing.expectEqualStrings("font", ast.attrsOf(attrs_marker).get("icons").?);
    try testing.expectEqualStrings("", ast.attrsOf(attrs_marker).get("toc").?);
    const heading = ast.nodes[attrs_marker].next_sibling.?;
    // 1, not the ASG's 0: twig's shared `heading.level` is 1-based in every
    // language, so `= Title` and Markdown's `# Title` agree.
    try testing.expectEqual(@as(u32, 1), ast.nodes[heading].kind.heading.level);
    try testing.expectEqualStrings("= ", doc.markerText(heading).?);
}

test "the author and revision lines become the document's implicit attributes" {
    var doc = try parse(testing.allocator, "= Title\nDoc Writer <doc@example.org>; Ann B. Lee\nv2.1, 2024-05-01: Remark\n:toc:\n");
    defer doc.deinit();
    const attrs = doc.ast.attrsOf(firstBlock(&doc));
    try testing.expectEqualStrings("Doc Writer", attrs.get("author").?);
    try testing.expectEqualStrings("Doc", attrs.get("firstname").?);
    try testing.expectEqualStrings("Writer", attrs.get("lastname").?);
    try testing.expectEqualStrings("doc@example.org", attrs.get("email").?);
    try testing.expectEqualStrings("Ann B. Lee", attrs.get("author_2").?);
    try testing.expectEqualStrings("B.", attrs.get("middlename_2").?);
    try testing.expectEqualStrings("2.1", attrs.get("revnumber").?);
    try testing.expectEqualStrings("2024-05-01", attrs.get("revdate").?);
    try testing.expectEqualStrings("Remark", attrs.get("revremark").?);
    try testing.expectEqualStrings("", attrs.get("toc").?);
    // The header's span runs through its last line.
    const heading = doc.ast.nodes[firstBlock(&doc)].next_sibling.?;
    try testing.expectEqualStrings("= Title\nDoc Writer <doc@example.org>; Ann B. Lee\nv2.1, 2024-05-01: Remark\n:toc:", doc.text(heading));
}

test "front matter is a metadata block, and the title still follows it" {
    var doc = try parse(testing.allocator, "---\ntitle: x\n---\n= Title\n\nbody\n");
    defer doc.deinit();
    const fm = firstBlock(&doc);
    try testing.expectEqualStrings("yaml", doc.ast.nodes[fm].kind.metadata.lang);
    try testing.expectEqualStrings("title: x", doc.ast.nodes[fm].kind.metadata.text);
    try testing.expectEqualStrings("---\ntitle: x\n---", doc.text(fm));
    const marker = doc.ast.nodes[fm].next_sibling.?;
    try testing.expectEqualStrings("document-attributes", doc.ast.nodes[marker].kind.container.name);
}

test "a section nests a paragraph inside it and a same-level heading closes it" {
    var doc = try parse(testing.allocator, "== One\n\n=== Two\n\npar\n\n== Three\n");
    defer doc.deinit();
    const ast = doc.ast;
    const sec_one = firstBlock(&doc);
    try testing.expect(ast.nodes[sec_one].kind == .section);
    const heading_one = ast.nodes[sec_one].first_child.?;
    try testing.expectEqual(@as(u32, 2), ast.nodes[heading_one].kind.heading.level);
    const sec_two = ast.nodes[heading_one].next_sibling.?;
    try testing.expect(ast.nodes[sec_two].kind == .section);
    const sec_three = ast.nodes[sec_one].next_sibling.?;
    try testing.expectEqual(@as(?Node.Id, null), ast.nodes[sec_three].next_sibling);
}

test "section metadata lands on the section, and the title's anchor is its id" {
    var doc = try parse(testing.allocator, "[.classy]\n== One [[one]]\n\npar\n");
    defer doc.deinit();
    const sec = firstBlock(&doc);
    try testing.expectEqualStrings("one", doc.ast.attrsOf(sec).get("id").?);
    try testing.expectEqualStrings("classy", doc.ast.attrsOf(sec).get("class").?);
    // The paragraph did not inherit the section's metadata.
    const para = nth(&doc, sec, 1);
    try testing.expect(doc.ast.attrsOf(para).isEmpty());
    const heading = nth(&doc, sec, 0);
    try testing.expectEqualStrings("One", doc.ast.nodes[doc.ast.nodes[heading].first_child.?].kind.str);
}

test "block metadata: id, roles, options, title and named attributes become the block's attrs" {
    var doc = try parse(testing.allocator, ".A title\n[#the-id.a.b%opt,key=val]\ntext\n");
    defer doc.deinit();
    const para = firstBlock(&doc);
    const attrs = doc.ast.attrsOf(para);
    try testing.expectEqualStrings("the-id", attrs.get("id").?);
    try testing.expectEqualStrings("a b", attrs.get("class").?);
    try testing.expectEqualStrings("A title", attrs.get("title").?);
    try testing.expectEqualStrings("opt", attrs.get("options").?);
    try testing.expectEqualStrings("val", attrs.get("key").?);
    // The block's span starts at its first metadata line; the attribute
    // line's own span is recorded too.
    try testing.expectEqualStrings(".A title\n[#the-id.a.b%opt,key=val]\ntext", doc.text(para));
    try testing.expectEqualStrings("[#the-id.a.b%opt,key=val]", doc.attrsText(para).?);
}

test "an unrecognized style is a class; a leftover positional keeps its number" {
    var doc = try parse(testing.allocator, "[lead,second]\ntext\n");
    defer doc.deinit();
    const attrs = doc.ast.attrsOf(firstBlock(&doc));
    try testing.expectEqualStrings("lead", attrs.get("class").?);
    try testing.expectEqualStrings("second", attrs.get("$2").?);
}

test "a source block's language rides in the code_block, not in attrs" {
    var doc = try parse(testing.allocator, "[source,ruby]\n----\nputs 1\n----\n");
    defer doc.deinit();
    const cb = doc.ast.nodes[firstBlock(&doc)].kind.code_block;
    try testing.expectEqualStrings("ruby", cb.lang.?);
    try testing.expectEqualStrings("puts 1", cb.text);
    try testing.expect(doc.ast.attrsOf(firstBlock(&doc)).isEmpty());
}

test "a [,lang] listing and a markdown fence both carry the language" {
    var doc = try parse(testing.allocator, "[,js]\n----\nx\n----\n\n```py\ny\n```\n");
    defer doc.deinit();
    const a = firstBlock(&doc);
    try testing.expectEqualStrings("js", doc.ast.nodes[a].kind.code_block.lang.?);
    const b = doc.ast.nodes[a].next_sibling.?;
    try testing.expectEqualStrings("py", doc.ast.nodes[b].kind.code_block.lang.?);
    try testing.expectEqualStrings("y", doc.ast.nodes[b].kind.code_block.text);
}

test "a pass block is a raw block, not a code block" {
    var doc = try parse(testing.allocator, "++++\n<div>x</div>\n++++\n");
    defer doc.deinit();
    const rb = doc.ast.nodes[firstBlock(&doc)].kind.raw_block;
    try testing.expectEqualStrings("html", rb.format);
    try testing.expectEqualStrings("<div>x</div>", rb.text);
}

test "an admonition is the container named by its variant, in all three spellings" {
    var doc = try parse(testing.allocator, "NOTE: remember\n\n[TIP]\nhandy\n\n[WARNING]\n====\ncareful\n====\n");
    defer doc.deinit();
    const note = firstBlock(&doc);
    try testing.expectEqualStrings("note", doc.ast.nodes[note].kind.container.name);
    try testing.expectEqual(AST.Form.block_fenced, doc.ast.nodes[note].kind.container.form.?);
    try testing.expectEqualStrings("NOTE: ", doc.markerText(note).?);
    const para = doc.ast.nodes[note].first_child.?;
    try testing.expectEqualStrings("remember", doc.ast.nodes[doc.ast.nodes[para].first_child.?].kind.str);
    const tip = doc.ast.nodes[note].next_sibling.?;
    try testing.expectEqualStrings("tip", doc.ast.nodes[tip].kind.container.name);
    try testing.expect(doc.ast.attrsOf(tip).isEmpty());
    const warning = doc.ast.nodes[tip].next_sibling.?;
    try testing.expectEqualStrings("warning", doc.ast.nodes[warning].kind.container.name);
    try testing.expectEqualStrings("[WARNING]\n====\ncareful\n====", doc.text(warning));
}

test "a [quote] paragraph is a block quote; [verse] is a line block with depths" {
    var doc = try parse(testing.allocator, "[quote,Someone]\nwords\n\n[verse]\n____\nRoses\n    deep\n  mid\n____\n");
    defer doc.deinit();
    const quote = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[quote].kind == .block_quote);
    try testing.expectEqualStrings("Someone", doc.ast.attrsOf(quote).get("attribution").?);
    const verse = doc.ast.nodes[quote].next_sibling.?;
    try testing.expect(doc.ast.nodes[verse].kind == .line_block);
    try testing.expectEqual(@as(u32, 0), doc.ast.nodes[nth(&doc, verse, 0)].kind.line.indent);
    try testing.expectEqual(@as(u32, 2), doc.ast.nodes[nth(&doc, verse, 1)].kind.line.indent);
    try testing.expectEqual(@as(u32, 1), doc.ast.nodes[nth(&doc, verse, 2)].kind.line.indent);
    try testing.expectEqualStrings("deep", doc.ast.nodes[doc.ast.nodes[nth(&doc, verse, 1)].first_child.?].kind.str);
}

test "a markdown-style quote parses its interior as blocks at their real offsets" {
    const src = "> one *two*\n> \n> - item\n";
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    const quote = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[quote].kind == .block_quote);
    const para = nth(&doc, quote, 0);
    try testing.expect(doc.ast.nodes[para].kind == .para);
    const strong = nth(&doc, para, 1);
    try testing.expect(doc.ast.nodes[strong].kind.inline_mark == .strong);
    try testing.expectEqualStrings("*two*", doc.text(strong));
    const list = nth(&doc, quote, 1);
    try testing.expect(doc.ast.nodes[list].kind == .bullet_list);
    try testing.expectEqualStrings("- item", doc.text(list));
}

test "a discrete heading is a heading in the flow, not a section" {
    var doc = try parse(testing.allocator, "[discrete]\n== Title\n\npar\n");
    defer doc.deinit();
    const h = firstBlock(&doc);
    try testing.expectEqual(@as(u32, 2), doc.ast.nodes[h].kind.heading.level);
    try testing.expect(doc.ast.nodes[doc.ast.nodes[h].next_sibling.?].kind == .para);
    try testing.expect(doc.ast.attrsOf(h).isEmpty());
}

test "block macros: an image is a paragraph holding an image; audio, video and toc are leaf directives" {
    var doc = try parse(testing.allocator, "image::a.png[Alt,200,100]\n\nvideo::v.mp4[poster.png]\n\ntoc::[]\n");
    defer doc.deinit();
    const p = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[p].kind == .para);
    const img = doc.ast.nodes[p].first_child.?;
    try testing.expectEqualStrings("a.png", doc.ast.nodes[img].kind.image.destination.?);
    try testing.expectEqualStrings("Alt", doc.ast.nodes[doc.ast.nodes[img].first_child.?].kind.str);
    try testing.expectEqualStrings("200", doc.ast.attrsOf(img).get("width").?);
    try testing.expectEqualStrings("100", doc.ast.attrsOf(img).get("height").?);
    const video = doc.ast.nodes[p].next_sibling.?;
    try testing.expectEqualStrings("video", doc.ast.nodes[video].kind.container.name);
    try testing.expectEqual(AST.Form.block_leaf, doc.ast.nodes[video].kind.container.form.?);
    try testing.expectEqualStrings("v.mp4", doc.ast.nodes[video].kind.container.argument.?);
    try testing.expectEqualStrings("poster.png", doc.ast.attrsOf(video).get("poster").?);
    try testing.expectEqual(Document.Spelling.ContainerOrigin.directive, doc.containerOrigin(video).?);
    const toc = doc.ast.nodes[video].next_sibling.?;
    try testing.expectEqualStrings("toc", doc.ast.nodes[toc].kind.container.name);
    try testing.expectEqual(@as(?[]const u8, null), doc.ast.nodes[toc].kind.container.argument);
}

test "a body attribute entry is a substitution definition; a reference is its use" {
    var doc = try parse(testing.allocator, ":name: Twig\n\nHello {name} and {nbsp}there {undefined-one}\n");
    defer doc.deinit();
    const def = firstBlock(&doc);
    try testing.expectEqualStrings("name", doc.ast.nodes[def].kind.substitution.label);
    try testing.expectEqualStrings("Twig", doc.ast.nodes[doc.ast.nodes[def].first_child.?].kind.str);
    const para = doc.ast.nodes[def].next_sibling.?;
    const use = nth(&doc, para, 1);
    try testing.expectEqual(AST.TextLeafKind.substitution_reference, doc.ast.nodes[use].kind.text_leaf.kind);
    try testing.expectEqualStrings("name", doc.ast.nodes[use].kind.text_leaf.text);
    try testing.expectEqualStrings("{name}", doc.text(use));
    try testing.expect(doc.ast.nodes[nth(&doc, para, 3)].kind == .non_breaking_space);
}

test "intrinsic character attributes are text" {
    var doc = try parseInlineList(testing.allocator, "a{sp}b{startsb}c{endsb}\n");
    defer doc.deinit();
    const s = firstBlock(&doc);
    try testing.expectEqualStrings("a b[c]", doc.ast.nodes[s].kind.str);
    try testing.expectEqual(@as(?Node.Id, null), doc.ast.nodes[s].next_sibling);
}

test "an unordered list item carries its bullet spelling and marker span" {
    var doc = try parse(testing.allocator, "* water\n");
    defer doc.deinit();
    const list = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[list].kind == .bullet_list);
    const item = doc.ast.nodes[list].first_child.?;
    try testing.expectEqual(Document.Spelling.Bullet.star, doc.spelling(item).?.bullet);
    try testing.expectEqualStrings("* ", doc.markerText(item).?);
    try testing.expectEqualStrings("water", doc.ast.nodes[doc.ast.nodes[item].first_child.?].kind.str);
}

test "ordered markers carry numbering, start and delimiter spelling" {
    // An empty attribute line keeps the two lists apart; without it the
    // second, being of another marker, would nest inside `d.`.
    var doc = try parse(testing.allocator, "c. one\nd. two\n\n[]\niv) four\n");
    defer doc.deinit();
    const alpha = firstBlock(&doc);
    try testing.expectEqual(AST.ListNumbering.lower_alpha, doc.ast.nodes[alpha].kind.ordered_list.numbering);
    try testing.expectEqual(@as(?u32, 3), doc.ast.nodes[alpha].kind.ordered_list.start);
    try testing.expectEqual(Document.Spelling.OrderedDelim.period, doc.spelling(alpha).?.ordered_delim);
    const roman = doc.ast.nodes[alpha].next_sibling.?;
    try testing.expectEqual(AST.ListNumbering.lower_roman, doc.ast.nodes[roman].kind.ordered_list.numbering);
    try testing.expectEqual(@as(?u32, 4), doc.ast.nodes[roman].kind.ordered_list.start);
    try testing.expectEqual(Document.Spelling.OrderedDelim.paren_after, doc.spelling(roman).?.ordered_delim);
}

test "a list whose every item carries a box is a task list" {
    var doc = try parse(testing.allocator, "* [x] done\n* [ ] todo\n\n[]\n* [x] a\n* b\n");
    defer doc.deinit();
    const tasks = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[tasks].kind == .task_list);
    try testing.expect(doc.ast.nodes[nth(&doc, tasks, 0)].kind.task_list_item.checked);
    try testing.expect(!doc.ast.nodes[nth(&doc, tasks, 1)].kind.task_list_item.checked);
    try testing.expectEqualStrings("done", doc.ast.nodes[doc.ast.nodes[nth(&doc, tasks, 0)].first_child.?].kind.str);
    // One item without a box: a plain list, the box literal text.
    const plain = doc.ast.nodes[tasks].next_sibling.?;
    try testing.expect(doc.ast.nodes[plain].kind == .bullet_list);
    const boxed = nth(&doc, plain, 0);
    try testing.expectEqualStrings("[x] ", doc.ast.nodes[nth(&doc, boxed, 0)].kind.str);
    try testing.expectEqualStrings("a", doc.ast.nodes[nth(&doc, boxed, 1)].kind.str);
}

test "list continuation attaches blocks; the item's principal stays inline" {
    var doc = try parse(testing.allocator, "* one\n+\n[source]\n----\ncode\n----\n+\nmore\n* two\n");
    defer doc.deinit();
    const list = firstBlock(&doc);
    const item = nth(&doc, list, 0);
    try testing.expect(doc.ast.nodes[nth(&doc, item, 0)].kind == .str);
    const code = nth(&doc, item, 1);
    try testing.expect(doc.ast.nodes[code].kind == .code_block);
    try testing.expectEqualStrings("[source]\n----\ncode\n----", doc.text(code));
    try testing.expect(doc.ast.nodes[nth(&doc, item, 2)].kind == .para);
    try testing.expectEqualStrings("* two", doc.text(nth(&doc, list, 1)));
}

test "a description list: terms, a definition, nesting and a nested list" {
    var doc = try parse(testing.allocator, "CPU:: brain\nRAM::\n  memory\n+\nextra\nGPU::\n* fast\n");
    defer doc.deinit();
    const dl = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[dl].kind == .definition_list);
    const cpu = nth(&doc, dl, 0);
    try testing.expect(doc.ast.nodes[nth(&doc, cpu, 0)].kind == .term);
    try testing.expectEqualStrings(":: ", doc.markerText(cpu).?);
    const cpu_def = nth(&doc, cpu, 1);
    try testing.expect(doc.ast.nodes[cpu_def].kind == .definition);
    try testing.expectEqualStrings("brain", doc.ast.nodes[doc.ast.nodes[cpu_def].first_child.?].kind.str);
    const ram = nth(&doc, dl, 1);
    const ram_def = nth(&doc, ram, 1);
    try testing.expectEqualStrings("memory", doc.ast.nodes[nth(&doc, ram_def, 0)].kind.str);
    try testing.expect(doc.ast.nodes[nth(&doc, ram_def, 1)].kind == .para);
    const gpu = nth(&doc, dl, 2);
    const gpu_def = nth(&doc, gpu, 1);
    try testing.expect(doc.ast.nodes[nth(&doc, gpu_def, 0)].kind == .bullet_list);
}

test "a table: cells, header detection, spans, alignment and a caption" {
    const src = ".Fruit\n[cols=\"1,1\",options=\"header\"]\n|===\n|Name |Count\n\n|Apple\n^|3\n\n2+|wide\n|===\n";
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    const table = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[table].kind == .table);
    try testing.expectEqualStrings(src[0 .. src.len - 1], doc.text(table));
    const cap = nth(&doc, table, 0);
    try testing.expect(doc.ast.nodes[cap].kind == .caption);
    try testing.expectEqualStrings("Fruit", doc.ast.nodes[doc.ast.nodes[cap].first_child.?].kind.str);
    const head = nth(&doc, table, 1);
    try testing.expect(doc.ast.nodes[head].kind.row.head);
    try testing.expect(doc.ast.nodes[nth(&doc, head, 0)].kind.cell.head);
    try testing.expectEqualStrings("Name", doc.ast.nodes[doc.ast.nodes[nth(&doc, head, 0)].first_child.?].kind.str);
    const body = nth(&doc, table, 2);
    try testing.expect(!doc.ast.nodes[body].kind.row.head);
    const count = nth(&doc, body, 1);
    try testing.expectEqual(AST.Alignment.center, doc.ast.nodes[count].kind.cell.alignment);
    try testing.expectEqualStrings("3", doc.ast.nodes[doc.ast.nodes[count].first_child.?].kind.str);
    const wide = nth(&doc, nth(&doc, table, 3), 0);
    try testing.expectEqual(@as(u32, 2), doc.ast.nodes[wide].kind.cell.colspan);
    try testing.expectEqualStrings("1,1", doc.ast.attrsOf(table).get("cols").?);
}

test "an implicit header: the first row on one line followed by a blank line" {
    var doc = try parse(testing.allocator, "|===\n|A |B\n\n|1 |2\n|===\n");
    defer doc.deinit();
    const table = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[nth(&doc, table, 0)].kind.row.head);
    try testing.expect(!doc.ast.nodes[nth(&doc, table, 1)].kind.row.head);
    var doc2 = try parse(testing.allocator, "|===\n|A |B\n|1 |2\n|===\n");
    defer doc2.deinit();
    try testing.expect(!doc2.ast.nodes[nth(&doc2, firstBlock(&doc2), 0)].kind.row.head);
}

test "a table's cells may span lines and hold escaped bars" {
    var doc = try parse(testing.allocator, "|===\n|one\nline two \\| kept\n|three\n|===\n");
    defer doc.deinit();
    const row = nth(&doc, firstBlock(&doc), 0);
    const first = doc.ast.nodes[nth(&doc, row, 0)].first_child.?;
    try testing.expectEqualStrings("one\nline two | kept", doc.ast.nodes[first].kind.str);
}

test "spans: constrained, unconstrained, monospace, superscript, subscript and curved quotes" {
    var doc = try parseInlineList(testing.allocator, "*s* **u** `m` ^up^ ~down~ \"`dq`\" '`sq`'\n");
    defer doc.deinit();
    const root = doc.ast.root;
    try testing.expect(doc.ast.nodes[nth(&doc, root, 0)].kind.inline_mark == .strong);
    try testing.expect(doc.ast.nodes[nth(&doc, root, 2)].kind.inline_mark == .strong);
    try testing.expectEqualStrings("**u**", doc.text(nth(&doc, root, 2)));
    try testing.expectEqual(AST.TextLeafKind.verbatim, doc.ast.nodes[nth(&doc, root, 4)].kind.text_leaf.kind);
    try testing.expect(doc.ast.nodes[nth(&doc, root, 6)].kind.inline_mark == .superscript);
    try testing.expect(doc.ast.nodes[nth(&doc, root, 8)].kind.inline_mark == .subscript);
    try testing.expect(doc.ast.nodes[nth(&doc, root, 10)].kind.inline_mark == .double_quoted);
    try testing.expect(doc.ast.nodes[nth(&doc, root, 12)].kind.inline_mark == .single_quoted);
    try testing.expectEqualStrings("dq", doc.ast.nodes[doc.ast.nodes[nth(&doc, root, 10)].first_child.?].kind.str);
}

test "a superscript may not contain whitespace; a doubled opener with no doubled close is constrained" {
    var doc = try parseInlineList(testing.allocator, "^a b^ and **bold*\n");
    defer doc.deinit();
    const first = firstBlock(&doc);
    try testing.expectEqualStrings("^a b^ and ", doc.ast.nodes[first].kind.str);
    const span = doc.ast.nodes[first].next_sibling.?;
    try testing.expect(doc.ast.nodes[span].kind.inline_mark == .strong);
    try testing.expectEqualStrings("*bold", doc.ast.nodes[doc.ast.nodes[span].first_child.?].kind.str);
}

test "a constrained span's interior is never empty" {
    // Without the guard, `****` encoded as two EMPTY strong spans.
    var doc = try parseInlineList(testing.allocator, "****\n");
    defer doc.deinit();
    const span = firstBlock(&doc);
    try testing.expect(doc.ast.nodes[span].kind.inline_mark == .strong);
    try testing.expectEqualStrings("*", doc.ast.nodes[doc.ast.nodes[span].first_child.?].kind.str);
}

test "a role before a span is its class; a role on a # span makes it a styled span" {
    var doc = try parseInlineList(testing.allocator, "[.big]*x* [.red#r]#y# [#only]_z_\n");
    defer doc.deinit();
    const root = doc.ast.root;
    const x = nth(&doc, root, 0);
    try testing.expect(doc.ast.nodes[x].kind.inline_mark == .strong);
    try testing.expectEqualStrings("big", doc.ast.attrsOf(x).get("class").?);
    try testing.expectEqualStrings("[.big]*x*", doc.text(x));
    const y = nth(&doc, root, 2);
    try testing.expectEqualStrings("", doc.ast.nodes[y].kind.container.name);
    try testing.expectEqual(AST.Form.inline_text, doc.ast.nodes[y].kind.container.form.?);
    try testing.expectEqualStrings("red", doc.ast.attrsOf(y).get("class").?);
    try testing.expectEqualStrings("r", doc.ast.attrsOf(y).get("id").?);
    const z = nth(&doc, root, 4);
    try testing.expect(doc.ast.nodes[z].kind.inline_mark == .emph);
    try testing.expectEqualStrings("only", doc.ast.attrsOf(z).get("id").?);
}

test "a bracket that precedes nothing spannable is literal text" {
    var doc = try parseInlineList(testing.allocator, "see [1] and [.x]plain\n");
    defer doc.deinit();
    const s = firstBlock(&doc);
    try testing.expectEqualStrings("see [1] and [.x]plain", doc.ast.nodes[s].kind.str);
}

test "links: bare URL, angle URL, bracketed text, link macro attributes, e-mail" {
    var doc = try parseInlineList(testing.allocator, "https://a.org <https://b.org> https://c.org[C^] link:d.html[D,window=_blank,role=ext] x@y.org\n");
    defer doc.deinit();
    const root = doc.ast.root;
    const a = nth(&doc, root, 0);
    try testing.expectEqual(AST.TextLeafKind.url, doc.ast.nodes[a].kind.text_leaf.kind);
    try testing.expectEqualStrings("https://a.org", doc.ast.nodes[a].kind.text_leaf.text);
    const b = nth(&doc, root, 2);
    try testing.expectEqualStrings("<https://b.org>", doc.text(b));
    try testing.expectEqualStrings("https://b.org", doc.contentText(b).?);
    const c = nth(&doc, root, 4);
    try testing.expectEqualStrings("https://c.org", doc.ast.nodes[c].kind.link.destination.?);
    try testing.expectEqualStrings("C", doc.ast.nodes[doc.ast.nodes[c].first_child.?].kind.str);
    try testing.expectEqualStrings("_blank", doc.ast.attrsOf(c).get("window").?);
    const d = nth(&doc, root, 6);
    try testing.expectEqualStrings("d.html", doc.ast.nodes[d].kind.link.destination.?);
    try testing.expectEqualStrings("D", doc.ast.nodes[doc.ast.nodes[d].first_child.?].kind.str);
    try testing.expectEqualStrings("ext", doc.ast.attrsOf(d).get("class").?);
    try testing.expectEqualStrings("_blank", doc.ast.attrsOf(d).get("window").?);
    const e = nth(&doc, root, 8);
    try testing.expectEqual(AST.TextLeafKind.email, doc.ast.nodes[e].kind.text_leaf.kind);
    try testing.expectEqualStrings("x@y.org", doc.ast.nodes[e].kind.text_leaf.text);
}

test "a cross reference is a link to a fragment" {
    var doc = try parseInlineList(testing.allocator, "<<sec>> <<sec,Text>> xref:other#frag[]\n");
    defer doc.deinit();
    const root = doc.ast.root;
    const a = nth(&doc, root, 0);
    try testing.expectEqualStrings("#sec", doc.ast.nodes[a].kind.link.destination.?);
    try testing.expectEqualStrings("sec", doc.ast.nodes[doc.ast.nodes[a].first_child.?].kind.str);
    const b = nth(&doc, root, 2);
    try testing.expectEqualStrings("Text", doc.ast.nodes[doc.ast.nodes[b].first_child.?].kind.str);
    const c = nth(&doc, root, 4);
    try testing.expectEqualStrings("other#frag", doc.ast.nodes[c].kind.link.destination.?);
}

test "an inline image carries its alt text as children and its size in attrs" {
    var doc = try parseInlineList(testing.allocator, "see image:a.png[Alt,50] here\n");
    defer doc.deinit();
    const img = nth(&doc, doc.ast.root, 1);
    try testing.expectEqualStrings("a.png", doc.ast.nodes[img].kind.image.destination.?);
    try testing.expectEqualStrings("Alt", doc.ast.nodes[doc.ast.nodes[img].first_child.?].kind.str);
    try testing.expectEqualStrings("50", doc.ast.attrsOf(img).get("width").?);
    try testing.expectEqualStrings("image:a.png[Alt,50]", doc.text(img));
}

test "footnotes: a reference at the use and a detached definition, numbered in order" {
    var doc = try parse(testing.allocator, "a footnote:[first] b footnote:named[second] c footnote:named[]\n");
    defer doc.deinit();
    const para = firstBlock(&doc);
    const r1 = nth(&doc, para, 1);
    try testing.expectEqual(AST.TextLeafKind.footnote_reference, doc.ast.nodes[r1].kind.text_leaf.kind);
    try testing.expectEqualStrings("1", doc.ast.nodes[r1].kind.text_leaf.text);
    try testing.expectEqualStrings("first", doc.contentText(r1).?);
    const r2 = nth(&doc, para, 3);
    try testing.expectEqualStrings("named", doc.ast.nodes[r2].kind.text_leaf.text);
    const r3 = nth(&doc, para, 5);
    try testing.expectEqualStrings("named", doc.ast.nodes[r3].kind.text_leaf.text);
    try testing.expectEqual(@as(?Span, null), doc.contentSpan(r3));
    // Two definitions, unattached, found the way djot's and Markdown's are.
    const roots = try doc.ast.definitionRoots(testing.allocator);
    defer testing.allocator.free(roots);
    try testing.expectEqual(@as(usize, 2), roots.len);
    try testing.expectEqualStrings("1", doc.ast.nodes[roots[0]].kind.footnote.label);
    try testing.expectEqualStrings("named", doc.ast.nodes[roots[1]].kind.footnote.label);
    const body = doc.ast.nodes[roots[1]].first_child.?;
    try testing.expect(doc.ast.nodes[body].kind == .para);
    try testing.expectEqualStrings("second", doc.ast.nodes[doc.ast.nodes[body].first_child.?].kind.str);
}

test "passthroughs, math, kbd, btn and an inline anchor" {
    var doc = try parseInlineList(testing.allocator, "+++<b>+++ pass:[<i>] stem:[x^2] kbd:[Ctrl+C] btn:[OK] [[here]] anchor:there[]\n");
    defer doc.deinit();
    const root = doc.ast.root;
    try testing.expectEqualStrings("<b>", doc.ast.nodes[nth(&doc, root, 0)].kind.raw_inline.text);
    try testing.expectEqualStrings("html", doc.ast.nodes[nth(&doc, root, 0)].kind.raw_inline.format);
    try testing.expectEqualStrings("<i>", doc.ast.nodes[nth(&doc, root, 2)].kind.raw_inline.text);
    const math = nth(&doc, root, 4);
    try testing.expectEqual(AST.TextLeafKind.inline_math, doc.ast.nodes[math].kind.text_leaf.kind);
    try testing.expectEqualStrings("x^2", doc.ast.nodes[math].kind.text_leaf.text);
    const kbd = nth(&doc, root, 6);
    try testing.expectEqualStrings("kbd", doc.ast.nodes[kbd].kind.container.name);
    try testing.expectEqualStrings("Ctrl+C", doc.ast.nodes[doc.ast.nodes[kbd].first_child.?].kind.str);
    const btn = nth(&doc, root, 8);
    try testing.expectEqualStrings("b", doc.ast.nodes[btn].kind.container.name);
    try testing.expectEqualStrings("button", doc.ast.attrsOf(btn).get("class").?);
    const here = nth(&doc, root, 10);
    try testing.expectEqualStrings("here", doc.ast.attrsOf(here).get("id").?);
    try testing.expectEqual(@as(?Node.Id, null), doc.ast.nodes[here].first_child);
    const there = nth(&doc, root, 12);
    try testing.expectEqualStrings("there", doc.ast.attrsOf(there).get("id").?);
}

test "hard breaks: a trailing ` +`, and every newline under %hardbreaks" {
    var doc = try parse(testing.allocator, "a +\nb\n\n[%hardbreaks]\nc\nd\n");
    defer doc.deinit();
    const p1 = firstBlock(&doc);
    try testing.expectEqualStrings("a", doc.ast.nodes[nth(&doc, p1, 0)].kind.str);
    try testing.expect(doc.ast.nodes[nth(&doc, p1, 1)].kind == .hard_break);
    try testing.expectEqualStrings(" +\n", doc.text(nth(&doc, p1, 1)));
    try testing.expectEqualStrings("b", doc.ast.nodes[nth(&doc, p1, 2)].kind.str);
    const p2 = doc.ast.nodes[p1].next_sibling.?;
    try testing.expect(doc.ast.nodes[nth(&doc, p2, 1)].kind == .hard_break);
    try testing.expectEqualStrings("\n", doc.text(nth(&doc, p2, 1)));
}

test "replacements: symbols, arrows, an em dash and an ellipsis" {
    var doc = try parseInlineList(testing.allocator, "(C) a->b x--y wait...\n");
    defer doc.deinit();
    const root = doc.ast.root;
    try testing.expectEqualStrings("\u{a9} a\u{2192}b x", doc.ast.nodes[nth(&doc, root, 0)].kind.str);
    try testing.expectEqual(AST.SmartPunctuationKind.em_dash, doc.ast.nodes[nth(&doc, root, 1)].kind.smart_punctuation);
    try testing.expectEqualStrings("y wait", doc.ast.nodes[nth(&doc, root, 2)].kind.str);
    try testing.expectEqual(AST.SmartPunctuationKind.ellipses, doc.ast.nodes[nth(&doc, root, 3)].kind.smart_punctuation);
}

test "escapes: a backslash before a mark, a macro, a scheme, or a backslash" {
    var doc = try parseInlineList(testing.allocator, "\\*a* \\link:x[y] \\https://z.org \\\\ \\q\n");
    defer doc.deinit();
    const s = firstBlock(&doc);
    try testing.expectEqualStrings("*a* link:x[y] https://z.org \\ \\q", doc.ast.nodes[s].kind.str);
    try testing.expectEqual(@as(?Node.Id, null), doc.ast.nodes[s].next_sibling);
}

test "a character reference is its own str, decoded" {
    var doc = try parseInlineList(testing.allocator, "a &amp; &#x41; &bogus; b\n");
    defer doc.deinit();
    const root = doc.ast.root;
    try testing.expectEqualStrings("&", doc.ast.nodes[nth(&doc, root, 1)].kind.str);
    try testing.expectEqualStrings("&amp;", doc.text(nth(&doc, root, 1)));
    try testing.expectEqualStrings("A", doc.ast.nodes[nth(&doc, root, 3)].kind.str);
    try testing.expectEqualStrings(" &bogus; b", doc.ast.nodes[nth(&doc, root, 4)].kind.str);
}

test "an indented paragraph is a literal block with its common indent stripped" {
    var doc = try parse(testing.allocator, "    one\n      two\n");
    defer doc.deinit();
    const cb = doc.ast.nodes[firstBlock(&doc)].kind.code_block;
    try testing.expectEqualStrings("one\n  two", cb.text);
    try testing.expectEqualStrings("    one\n      two", doc.contentText(firstBlock(&doc)).?);
}

test "degenerate inputs parse and encode without crashing" {
    const asg = @import("asg.zig");
    for ([_][]const u8{
        "",            "\n",         "   \n",       "\n\n\n",    "= \n",      "----\n",
        "****\n",      "*\n",        "|===\n",      "|===\n|\n", "[[\n",      "[]\n",
        ".\n",         "..\n",       "term::\n",    "* \n",      "+\n",       "footnote:[]\n",
        "image::[]\n", "<<>>\n",     "[.]*x*\n",    "> \n",      "```\n",     "[verse]\n____\n____\n",
        "NOTE: \n",    "---\n",      "---\n---\n",  "&#0;\n",    "{}\n",      "1. \n",
        "= T\nA <\n",  "[source]\n", "[quote]\n\n", "\\\n",      "*a\n**b\n", "|===\n2+|a\n|===\n",
    }) |source| {
        var doc = try parse(testing.allocator, source);
        defer doc.deinit();
        const json = try asg.encodeAlloc(testing.allocator, &doc, .document);
        testing.allocator.free(json);
    }
}

test "every construct the parser produces encodes as an ASG (or a documented extension)" {
    const asg = @import("asg.zig");
    const src =
        \\= T
        \\A B <a@b.org>
        \\
        \\NOTE: x^2^ ~s~ "`q`" [.r]#y# image:i.png[] footnote:[f] {v} {nbsp} +++r+++ pass:[p] stem:[m] kbd:[K] [[a]] a +
        \\b
        \\
        \\:e: v
        \\
        \\[quote]
        \\q
        \\
        \\> md
        \\
        \\|===
        \\|c
        \\|===
        \\
        \\* [x] t
        \\
        \\[verse]
        \\v
        \\
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    const json = try asg.encodeAlloc(testing.allocator, &doc, .document);
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "delimited blocks carry no ASG bookkeeping in attrs" {
    var doc = try parse(testing.allocator, "----\ncode\n----\n\n[source,ruby]\n----\nx\n----\n");
    defer doc.deinit();
    for (0..doc.ast.nodes.len) |id| {
        try testing.expectEqual(@as(usize, 0), doc.ast.attrsOf(@intCast(id)).entries.len);
    }
}
