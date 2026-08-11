//! The docutils pseudo-XML *doctree* codec — the comparison format the rST
//! conformance harness is built on.
//!
//! ── Why a codec and not a printer ──────────────────────────────────────────
//! Twig's other two corpora compare HTML strings, so their harnesses need only
//! a printer. rST's does not: every one of the 713 vendored cases
//! (`testdata/docutils-rst-corpus.json`) expects a docutils DOCTREE, dumped by
//! `docutils.nodes.document.pformat()` — an indentation-based pseudo-XML that
//! is docutils' *tree* rather than its rendered output. The djot suite punted
//! its 6 tree-shaped cases to hand-written AST unit tests; at 713 that escape
//! hatch does not scale, so the doctree has to become a first-class format
//! twig can both READ and WRITE.
//!
//! Reading is what earns its keep before a parser exists. `decode` turns each
//! expected doctree into a twig `AST`; `encode` turns it back. Asserting
//! `encode(decode(x)) == x` over the whole corpus does two jobs at once: it
//! proves this file handles docutils' output format exactly (indentation, text
//! runs, attribute order, significant trailing whitespace), and — via
//! `Coverage` — it measures how much of docutils' 93-element vocabulary twig's
//! shared `AST` can actually hold. That second number is the intel the parser
//! work needs, and it is available now rather than after the parser is written.
//! When the parser does land, `encode` becomes the real comparison path
//! unchanged.
//!
//! ── The pformat grammar, as observed ───────────────────────────────────────
//! There is no spec for it; the rules below were derived from the 713 vendored
//! expectations and cross-checked against `docutils.nodes.Element.pformat`:
//!
//!   - Four spaces of indent per level. NO closing tags — nesting is carried by
//!     indentation alone, so an element with no children is one line.
//!   - An element is `<name key="value" ...>`, attributes sorted by name
//!     (docutils' `attlist()` sorts; all 2208 attribute-bearing lines in the
//!     corpus obey it). Values are never quote-escaped and no entity escaping
//!     happens anywhere — a doctree is a debug dump, not XML.
//!   - A `Text` node is written as its lines, each prefixed by the indent. So
//!     text lines can carry their own leading whitespace (238 corpus lines have
//!     an indent that is not a multiple of four) and their own TRAILING
//!     whitespace, which is significant (226 lines) — a paragraph's `, ` run
//!     between two inline elements is a real text node.
//!   - A blank line inside a text node is written as the bare indent, so a
//!     whitespace-only line is content, not a separator. There are no truly
//!     empty lines in a doctree.
//!
//! ── The one genuine ambiguity ──────────────────────────────────────────────
//! Because text is written raw, a text line CAN look exactly like an element.
//! The corpus contains exactly one: an option list documenting
//! `--source-url=<URL>`, whose `<option_argument>` has the text child `<URL>`.
//! `decode` resolves this by only treating a tag-shaped line as an element when
//! its name is in the closed `Tag` vocabulary below — `URL` is not a docutils
//! element, so it stays text. That is a heuristic, so it is not left implicit:
//! `Coverage.unknown_tag_shaped_text` counts every line it fires on, and the
//! conformance test pins that count, meaning a corpus refresh that introduces a
//! real element missing from `Tag` fails the build instead of silently decoding
//! to text.
//!
//! ── Where `system_message` went ────────────────────────────────────────────
//! 299 of the corpus's nodes are `<system_message>`: docutils reports parse
//! errors as tree nodes. Twig does not, and will not — when the rST parser
//! lands, its diagnostics follow fig's model (`fig/src/languages/fig/parser.zig`
//! and `fig/src/parse_diagnostic.zig`): a `Report` sidecar of
//! `Diagnostic`/`Warning` records carrying a typed `code` plus a byte span, kept
//! out of the tree entirely, with the harness gaining a projection step that
//! renders that sidecar back into `<system_message>` nodes to compare against.
//! See `rst.zig`'s scope statement for what that projection has to reproduce.
//!
//! Here in the codec, `system_message` is simply one more element being DECODED
//! from docutils' output, and it takes the same `container` fallback every
//! other unmapped element takes. That is a decoder fact, not a vocabulary
//! commitment: nothing outside this file learns that a container named
//! `system_message` means anything in particular.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AST = @import("../../ast/ast.zig");
const Node = AST.Node;

/// Spaces per nesting level, as docutils' `pformat` writes them.
pub const indent_width = 4;

/// The closed docutils element vocabulary — every element class in
/// `docutils/nodes.py`, not merely the 93 the corpus happens to exercise.
///
/// It is the full published set on purpose, because this enum does double duty.
/// As a MAPPING KEY it only needs the tags that appear; as the LEXER's
/// disambiguator (see the module doc's "one genuine ambiguity") it decides
/// whether a tag-shaped line is markup or text, and there a name missing from
/// the list silently becomes text. Listing the whole vocabulary means a corpus
/// refresh that starts exercising, say, `docinfo` finds it here already.
pub const Tag = enum {
    abbreviation,
    acronym,
    address,
    admonition,
    attention,
    attribution,
    author,
    authors,
    block_quote,
    bullet_list,
    caption,
    caution,
    citation,
    citation_reference,
    classifier,
    colspec,
    comment,
    compound,
    contact,
    container,
    copyright,
    danger,
    date,
    decoration,
    definition,
    definition_list,
    definition_list_item,
    description,
    docinfo,
    doctest_block,
    document,
    emphasis,
    entry,
    enumerated_list,
    @"error",
    field,
    field_body,
    field_list,
    field_name,
    figure,
    footer,
    footnote,
    footnote_reference,
    generated,
    header,
    hint,
    image,
    important,
    @"inline",
    label,
    legend,
    line,
    line_block,
    list_item,
    literal,
    literal_block,
    math,
    math_block,
    meta,
    note,
    option,
    option_argument,
    option_group,
    option_list,
    option_list_item,
    option_string,
    organization,
    paragraph,
    pending,
    problematic,
    raw,
    reference,
    revision,
    row,
    rubric,
    section,
    sidebar,
    status,
    strong,
    subscript,
    substitution_definition,
    substitution_reference,
    subtitle,
    superscript,
    system_message,
    table,
    target,
    tbody,
    term,
    tgroup,
    thead,
    tip,
    title,
    title_reference,
    topic,
    transition,
    version,
    warning,

    pub const count = @typeInfo(Tag).@"enum".fields.len;

    pub fn name(self: Tag) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?Tag {
        return std.meta.stringToEnum(Tag, text);
    }
};

// ── the decode table ───────────────────────────────────────────────────────
//
// Which docutils elements decode to a twig SEMANTIC kind, and which fall back
// to the generic `container` escape hatch. The split is the harness's real
// measurement, so the rule for adding a row is strict: a mapping earns its
// place only if `encode` can inverse it EXACTLY, attributes and all. Anything
// that would need a normalization step, a defaulted field the doctree cannot
// see, or knowledge of an ancestor stays generic and is counted as such.
//
// Three families are deliberately still generic, and their absence is the
// finding rather than an oversight:
//
//   - The table subtree (`table`/`tgroup`/`colspec`/`thead`/`tbody`/`row`/
//     `entry`). docutils nests a `tgroup` with `colspec` widths between the
//     table and its rows, and marks header rows by putting them under `thead`;
//     twig's `table` holds `[caption, row...]` directly and marks headers with
//     `row.head`. That is one restructuring decision — where `cols`/`colwidth`/
//     `stub` live — and it should be made as a unit with the parser, not
//     smuggled in one tag at a time.
//   - `title`. Twig spells it `heading`, which carries a `level`; the doctree
//     does not write one, so decoding would have to synthesize it from section
//     nesting depth and encoding would have to recompute it. `title` also
//     appears under `topic`/`sidebar`/`table`, where no such depth exists.
//   - The REST of the hyperlink cluster. `reference`, the external `target`,
//     and `footnote` are mapped below because twig already has their kinds; the
//     four that remain each want a NEW entry in twig's shared vocabulary, and
//     the corpus cannot decide any of them:
//
//       `citation` (14) + `citation_reference` (7) — structurally identical to
//       footnotes, differing only in which name registry they resolve in. So
//       either `Kind.Footnote` grows a namespace or `citation` becomes its own
//       kind; and those two choices differ in whether the serializers are FORCED
//       to notice (a payload field compiles everywhere unchanged, a new kind
//       fails every exhaustive switch until it is answered).
//
//       `substitution_definition` (33) + `substitution_reference` (18) — a
//       definition whose body is INLINE, unlike every definition twig has.
//
//       The indirect `target` (14) — an alias naming another definition rather
//       than a URI, which `Kind.Reference` has no field for.
//
//       The internal `target` (30) — an anchor; see `decodeTarget`.
//
//     What they share is that mapping any of them commits twig's PUBLISHED
//     vocabulary (`ast/json.zig`'s `kind`, `c_abi.zig`'s `TwigNodeKind`) to a
//     construct only rST has, and hands three serializers a node their format
//     cannot spell — which is the conversion-lossiness layer `rst.zig` names as
//     a separate system that does not exist yet. Deliberately not smuggled in
//     under a coverage ratchet.

/// The twig `Kind` `tag` decodes to, or `null` for the generic `container`
/// fallback. `children` are the already-built child ids, needed by the three
/// text-carrying mappings — see `soleStr`; `attrs` are the element's own,
/// borrowed from the input and safe to hand to the builder, which dupes every
/// payload string (`Builder.dupeKind`).
fn decodeKind(
    b: *const AST.Builder,
    tag: Tag,
    children: []const Node.Id,
    attrs: []const AST.KeyVal,
) ?Node.Kind {
    return switch (tag) {
        .document => .doc,
        .paragraph => .para,
        .emphasis => .{ .inline_mark = .emph },
        .strong => .{ .inline_mark = .strong },
        .block_quote => .block_quote,
        // docutils has no tight/loose distinction, so there is nothing in the
        // doctree for `tight` to come from and nothing for `encode` to write
        // back: it is pinned to `false` and never observed. The `bullet="*"`
        // attribute stays in `attrs` and round-trips there rather than moving
        // to `Document.Spelling`, because this codec produces a bare `AST` (see
        // `decode`) and a spelling table would have nowhere to live.
        .bullet_list => .{ .bullet_list = .{ .tight = false } },
        .list_item => .list_item,
        .definition_list => .definition_list,
        .definition_list_item => .definition_list_item,
        .term => .term,
        .definition => .definition,
        .section => .section,
        .transition => .thematic_break,

        // A hyperlink USE. docutils' `reference` and twig's `link` are the same
        // node down to the payload: `refuri` is a resolved destination and
        // `refname` is an unresolved name to look up later, which is exactly the
        // `{destination, reference}` pair `Kind.Link` already carries for djot's
        // `[text][label]`. All four corpus shapes fit — `refuri` alone (26),
        // `name refuri` (20), `name refname` (52), `anonymous name` (33) — with
        // the two that describe the reference rather than its target (`name`,
        // the normalized link text; `anonymous`) riding in `attrs`.
        .reference => .{ .link = .{
            .destination = attrValue(attrs, "refuri"),
            .reference = attrValue(attrs, "refname"),
        } },

        // A hyperlink DEFINITION — and only ONE of the three things docutils
        // spells `<target>`. See `decodeTarget`.
        .target => decodeTarget(children, attrs),

        // A footnote definition. The label is `names` — the normalized name
        // resolution uses — and NOT the `<label>` child, which is a different
        // thing wearing the same word: `<label>` is the RENDERED marker (`1`
        // for `[1]`), it is absent from all 21 auto-numbered footnotes because
        // a transform supplies their number, and for the 9 that have one it
        // merely repeats `names`. So it stays an ordinary child element and
        // `Kind.Footnote.label` gets the value it is actually for, matching how
        // `decodeTarget` reads a definition's name.
        .footnote => .{ .footnote = .{ .label = definitionName(attrs) } },

        // The three text-carrying mappings. Each holds its payload as opaque
        // text on the node, so it can only absorb a lone `Text` child — a
        // `literal_block` with inline children (docutils' parsed-literal) or an
        // empty `comment` has no lossless form here and stays generic. That
        // conditional is not a wart: "how many of the 175 literal blocks are
        // plain text" is exactly the kind of number the parser work needs.
        .literal => if (soleStr(b, children)) |t| .{ .text_leaf = .{ .kind = .verbatim, .text = t } } else null,
        .literal_block => if (soleStr(b, children)) |t| .{ .code_block = .{ .lang = null, .text = t } } else null,
        .comment => if (soleStr(b, children)) |t| .{ .markup_leaf = .{ .kind = .comment, .text = t } } else null,

        else => null,
    };
}

/// The docutils element `kind` encodes back to, or `null` when the kind has no
/// doctree spelling at all. Every arm is spelled so that a new `Kind` variant
/// fails this build until it declares one — the same exhaustiveness property
/// `Kind.level`/`contentModel` have.
fn encodeTag(kind: Node.Kind) ?Tag {
    return switch (kind) {
        .doc => .document,
        .para => .paragraph,
        .block_quote => .block_quote,
        .bullet_list => .bullet_list,
        .list_item => .list_item,
        .definition_list => .definition_list,
        .definition_list_item => .definition_list_item,
        .term => .term,
        .definition => .definition,
        .section => .section,
        .thematic_break => .transition,
        .code_block => .literal_block,
        // The two hyperlink arms cross names, which is confusing exactly once:
        // docutils' `<reference>` is the USE and its `<target>` is the
        // DEFINITION, while twig's `link` is the use and its `reference` is the
        // definition. Same two constructs, opposite words.
        .link => .reference,
        .reference => .target,
        .footnote => .footnote,
        .inline_mark => |m| switch (m) {
            .emph => .emphasis,
            .strong => .strong,
            else => null,
        },
        .text_leaf => |l| switch (l.kind) {
            .verbatim => .literal,
            else => null,
        },
        .markup_leaf => |l| switch (l.kind) {
            .comment => .comment,
            else => null,
        },
        // A generic container names its own element; `decode` only ever mints
        // one from a `Tag`, so the name is always a valid element name.
        .container => |c| Tag.fromName(c.name),

        // `str` is text, not an element — `writeNode` handles it before ever
        // asking. Everything else has no doctree spelling, which is honest:
        // twig kinds like `task_list`, `metadata`, or `smart_punctuation` name
        // constructs reStructuredText does not have.
        .str,
        .heading,
        .raw_block,
        .metadata,
        .ordered_list,
        .task_list,
        .table,
        .task_list_item,
        .row,
        .cell,
        .caption,
        .soft_break,
        .hard_break,
        .non_breaking_space,
        .raw_inline,
        .smart_punctuation,
        .image,
        .processing_instruction,
        => null,
    };
}

/// docutils spells three different constructs `<target>`, and only one of them
/// is a link reference definition. The corpus separates them cleanly:
///
///   - **External** (29) — `.. _name: http://x`, carrying `refuri`. This IS
///     twig's `Kind.reference`, the same node djot's `[name]: /url` produces,
///     and it is what this decodes.
///   - **Indirect** (14) — `.. _a: b_`, carrying `refname`: an ALIAS, pointing
///     at another definition rather than at a URI. `Kind.Reference.destination`
///     is a URI and has no second field to hold a name, so this stays generic.
///   - **Internal** (30; 13 empty and 17 inline, the only targets with children)
///     — `.. _name:` alone, an ANCHOR naming a position rather than a
///     destination. Deliberately NOT forced into a destination-less
///     `Kind.reference`: docutils resolves an internal target by moving its name
///     onto the FOLLOWING element's `ids` in a transform, which is how twig
///     already models an anchor too (an attribute on a node, not a node). What
///     the parser emits here is that transform's placeholder, so the twig
///     construct it corresponds to is an attribute twig cannot attach until it
///     knows what comes next.
///
/// See `definitionName` for the label.
fn decodeTarget(children: []const Node.Id, attrs: []const AST.KeyVal) ?Node.Kind {
    if (children.len != 0) return null;
    const destination = attrValue(attrs, "refuri") orelse return null;
    return .{ .reference = .{ .label = definitionName(attrs), .destination = destination } };
}

/// The name a definition is resolved by: docutils' `names`, which is the
/// NORMALIZED form (`Title 1` is stored as `title\ 1` — a list serialization
/// whose members escape their spaces, though every one in the corpus has exactly
/// one member). `dupnames` is that same value under a different key, used when
/// docutils has flagged the name as a duplicate, so it is read as a fallback.
///
/// `""` when a definition has neither, which is not a failure: an anonymous
/// target (`__ http://x`) and an unnamed auto-footnote (`[#]_`) genuinely have
/// no name and are resolved by position.
fn definitionName(attrs: []const AST.KeyVal) []const u8 {
    return attrValue(attrs, "names") orelse attrValue(attrs, "dupnames") orelse "";
}

/// The value of `attrs`'s `key`, or `null` when it is absent. First match, which
/// is the whole story here: `scanAttrs` reads a docutils `attlist()` dump, and
/// docutils' attribute dictionaries cannot repeat a key.
fn attrValue(attrs: []const AST.KeyVal, key: []const u8) ?[]const u8 {
    for (attrs) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// The text a text-carrying mapping absorbs: `children` must be exactly one
/// `str` node, whose text becomes the payload and whose node is then orphaned
/// (left in the arena, unreachable from the root — `encode` walks from the
/// root, so it never sees it).
fn soleStr(b: *const AST.Builder, children: []const Node.Id) ?[]const u8 {
    if (children.len != 1) return null;
    const kind = b.nodes.items[children[0]].kind;
    return switch (kind) {
        .str => |t| t,
        else => null,
    };
}

// ── coverage ───────────────────────────────────────────────────────────────

/// What a decode saw — the harness's measurement of how much of docutils'
/// vocabulary twig's `AST` holds semantically versus behind the `container`
/// escape hatch. Accumulates across cases, so one `Coverage` can be threaded
/// through the whole corpus.
pub const Coverage = struct {
    /// Per `Tag`, how many instances decoded to a semantic twig kind.
    semantic: [Tag.count]u32 = @splat(0),
    /// Per `Tag`, how many fell back to a generic `container`. For the three
    /// conditional mappings this is the count that failed the condition.
    generic: [Tag.count]u32 = @splat(0),
    /// `Text` nodes decoded to `str`.
    text_nodes: u32 = 0,
    /// Text lines that LOOK like an element but whose name is not a known
    /// docutils element, so they were decoded as text. See the module doc's
    /// "one genuine ambiguity" — the conformance test pins this count.
    unknown_tag_shaped_text: u32 = 0,

    pub fn semanticTotal(self: Coverage) u32 {
        var n: u32 = 0;
        for (self.semantic) |c| n += c;
        return n;
    }

    pub fn genericTotal(self: Coverage) u32 {
        var n: u32 = 0;
        for (self.generic) |c| n += c;
        return n;
    }

    /// Elements decoded, text nodes excluded.
    pub fn elementTotal(self: Coverage) u32 {
        return self.semanticTotal() + self.genericTotal();
    }
};

// ── line scanning ──────────────────────────────────────────────────────────

const Scanned = union(enum) {
    /// A well-formed element line whose name is a known docutils element.
    element: struct { tag: Tag, attrs_src: []const u8 },
    /// A well-formed element line whose name is NOT a known element — the
    /// `<URL>` case. Decoded as text, counted separately.
    unknown_tag,
    /// Not element-shaped at all: ordinary text.
    text,
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == ':' or c == '.' or c == '-';
}

/// Classify one already-dedented line. Recognizes exactly
/// `<name key="value" ...>` with no trailing content — the shape
/// `Element.starttag` produces. Anything else (including `<src dest>`, a text
/// line from the same option-list case, whose `dest` has no `="`) is text.
fn scanLine(body: []const u8) Scanned {
    if (body.len < 3 or body[0] != '<' or body[body.len - 1] != '>') return .text;
    var i: usize = 1;
    if (i >= body.len or !isNameStart(body[i])) return .text;
    const name_start = i;
    while (i < body.len and isNameChar(body[i])) i += 1;
    const name = body[name_start..i];

    const attrs_start = i;
    while (true) {
        // Either the closing `>` (possibly after trailing spaces) or another
        // `key="value"` pair.
        var j = i;
        while (j < body.len and body[j] == ' ') j += 1;
        if (j == body.len - 1 and body[j] == '>') break;
        if (j == i) return .text; // no separating space before an attribute
        if (j >= body.len or !isNameChar(body[j])) return .text;
        const key_start = j;
        while (j < body.len and isNameChar(body[j])) j += 1;
        if (j == key_start) return .text;
        if (j + 1 >= body.len or body[j] != '=' or body[j + 1] != '"') return .text;
        j += 2;
        const val_start = j;
        while (j < body.len and body[j] != '"') j += 1;
        if (j >= body.len) return .text;
        _ = val_start;
        i = j + 1; // past the closing quote
    }
    const attrs_src = body[attrs_start .. body.len - 1];
    const tag = Tag.fromName(name) orelse return .unknown_tag;
    return .{ .element = .{ .tag = tag, .attrs_src = attrs_src } };
}

/// Split an already-validated attribute region into `key="value"` pairs. The
/// returned slices BORROW `src` (which borrows the caller's input), so they
/// live exactly as long as the decoded text does; `Builder.setAttrs` copies.
fn scanAttrs(src: []const u8, out: *std.ArrayList(AST.KeyVal), allocator: Allocator) Allocator.Error!void {
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and src[i] == ' ') i += 1;
        if (i >= src.len) break;
        const key_start = i;
        while (i < src.len and isNameChar(src[i])) i += 1;
        const key = src[key_start..i];
        // `scanLine` already validated the shape, so `="` is guaranteed here.
        i += 2;
        const val_start = i;
        while (i < src.len and src[i] != '"') i += 1;
        const value = src[val_start..i];
        i += 1;
        try out.append(allocator, .{ .key = key, .value = value });
    }
}

// ── decode ─────────────────────────────────────────────────────────────────

pub const DecodeError = error{
    /// The input was empty, or its first line was not an element.
    NoRoot,
    /// An element line sat deeper than its parent allows — pformat never
    /// produces this, so it means the input is not a doctree.
    IndentJump,
    /// A text line appeared before any element opened it.
    TextOutsideRoot,
} || Allocator.Error;

const Frame = struct {
    tag: Tag,
    attrs_src: []const u8,
    children: std.ArrayList(Node.Id) = .empty,
};

/// Decode a docutils pformat doctree into a bare `AST`.
///
/// A bare `AST` and not a `Document` on purpose: a doctree is a dump of a tree
/// docutils already parsed, so it carries no positions into the ORIGINAL rST —
/// the only offsets available would be into the dump itself, which addresses
/// nothing anyone wants to edit. `Document`'s contract is that its spans index
/// `source`; there is no such source here, so the honest product is meaning
/// alone. (The `line="3"` attributes on `system_message` are docutils' own
/// record of rST line numbers, and ride in `attrs` like any other attribute.)
///
/// `text` is BORROWED for the duration of the call only; every string is copied
/// into the returned AST's owned storage. `coverage`, when non-null, accumulates
/// this decode's tallies on top of whatever it already holds.
pub fn decode(allocator: Allocator, text: []const u8, coverage: ?*Coverage) DecodeError!AST {
    var b = AST.Builder.init(allocator);
    defer b.deinit();

    var stack = std.ArrayList(Frame).empty;
    defer {
        for (stack.items) |*f| f.children.deinit(allocator);
        stack.deinit(allocator);
    }

    // The open text run: lines accumulate here until the run's parent changes.
    var run = std.ArrayList(u8).empty;
    defer run.deinit(allocator);
    var run_open = false;

    var attr_buf = std.ArrayList(AST.KeyVal).empty;
    defer attr_buf.deinit(allocator);

    var root: ?Node.Id = null;

    // pformat always ends with a newline, so exactly one trailing newline is a
    // terminator rather than a line. Only that one is dropped: an INTERIOR
    // empty line is not something pformat produces (a blank line inside a text
    // node is written as the bare indent, which is why the corpus has 81
    // whitespace-only lines and zero empty ones), so silently skipping them
    // would let a non-doctree decode into something plausible. Left as a line,
    // it dedents to the root and the round-trip fails, which is the honest
    // outcome.
    const body_text = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (body_text.len == 0) return error.NoRoot;

    var lines = std.mem.splitScalar(u8, body_text, '\n');
    while (lines.next()) |line| {
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        const body = line[indent..];

        const scanned = scanLine(body);
        if (scanned == .element and indent % indent_width == 0) {
            const depth = indent / indent_width;
            if (depth > stack.items.len) return error.IndentJump;

            try flushRun(allocator, &b, &stack, &run, &run_open, coverage);
            while (stack.items.len > depth) {
                try closeTop(allocator, &b, &stack, &attr_buf, coverage, &root);
            }
            try stack.append(allocator, .{
                .tag = scanned.element.tag,
                .attrs_src = scanned.element.attrs_src,
            });
            continue;
        }

        if (scanned == .unknown_tag) {
            if (coverage) |c| c.unknown_tag_shaped_text += 1;
        }

        // A text line. Its owner is the deepest frame whose child indent is at
        // most this line's — dedenting past a frame closes it. Text NEVER
        // closes the root, which is what makes a stray under-indented line an
        // error rather than a silent reparent.
        if (stack.items.len == 0) return error.TextOutsideRoot;
        while (stack.items.len * indent_width > indent and stack.items.len > 1) {
            try flushRun(allocator, &b, &stack, &run, &run_open, coverage);
            try closeTop(allocator, &b, &stack, &attr_buf, coverage, &root);
        }

        const base = stack.items.len * indent_width;
        const content = if (line.len > base) line[base..] else "";
        if (run_open) try run.append(allocator, '\n');
        try run.appendSlice(allocator, content);
        run_open = true;
    }

    try flushRun(allocator, &b, &stack, &run, &run_open, coverage);
    while (stack.items.len > 0) {
        try closeTop(allocator, &b, &stack, &attr_buf, coverage, &root);
    }

    return b.finish(root orelse return error.NoRoot);
}

/// Attach the open text run (if any) to the deepest frame as a `str`.
fn flushRun(
    allocator: Allocator,
    b: *AST.Builder,
    stack: *std.ArrayList(Frame),
    run: *std.ArrayList(u8),
    run_open: *bool,
    coverage: ?*Coverage,
) DecodeError!void {
    if (!run_open.*) return;
    run_open.* = false;
    const id = try b.addLeaf(.{ .str = run.items });
    run.clearRetainingCapacity();
    if (coverage) |c| c.text_nodes += 1;
    // A run is only ever opened with a frame on the stack (see the
    // `TextOutsideRoot` guard), so this cannot be empty.
    try stack.items[stack.items.len - 1].children.append(allocator, id);
}

/// Build the deepest frame into a node, attach it to its parent (or record it
/// as the root), and pop it.
fn closeTop(
    allocator: Allocator,
    b: *AST.Builder,
    stack: *std.ArrayList(Frame),
    attr_buf: *std.ArrayList(AST.KeyVal),
    coverage: ?*Coverage,
    root: *?Node.Id,
) DecodeError!void {
    var frame = stack.pop().?;
    defer frame.children.deinit(allocator);

    // Attributes are scanned BEFORE the kind is chosen: a mapping may read one
    // into its payload (`reference`'s `refuri` becomes `Kind.Link.destination`).
    // They are still attached to the node afterwards either way — see `encode`
    // for why the payload never becomes a second source of truth.
    attr_buf.clearRetainingCapacity();
    try scanAttrs(frame.attrs_src, attr_buf, allocator);

    const semantic = decodeKind(b, frame.tag, frame.children.items, attr_buf.items);
    const kind: Node.Kind = semantic orelse .{ .container = .{ .name = frame.tag.name() } };
    if (coverage) |c| {
        const slot = @intFromEnum(frame.tag);
        if (semantic != null) c.semantic[slot] += 1 else c.generic[slot] += 1;
    }

    // A text-carrying mapping absorbed its lone `str` child into the payload,
    // so that child must not also be linked in — see `soleStr`.
    const absorbed = semantic != null and switch (kind) {
        .text_leaf, .code_block, .markup_leaf => true,
        else => false,
    };
    const id = try b.addContainer(kind, if (absorbed) &.{} else frame.children.items);
    if (attr_buf.items.len > 0) try b.setAttrs(id, .{ .entries = attr_buf.items });

    if (stack.items.len == 0) {
        root.* = id;
    } else {
        try stack.items[stack.items.len - 1].children.append(allocator, id);
    }
}

// ── encode ─────────────────────────────────────────────────────────────────

pub const EncodeError = error{
    /// A node whose kind has no doctree spelling — see `encodeTag`.
    UnrepresentableKind,
} || Allocator.Error || Writer.Error;

/// Write `ast` as a docutils pformat doctree.
pub fn encode(allocator: Allocator, ast: *const AST, w: *Writer) EncodeError!void {
    try writeNode(allocator, ast, ast.root, 0, w);
}

/// `encode` into an owned buffer.
pub fn encodeAlloc(allocator: Allocator, ast: *const AST) EncodeError![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    try encode(allocator, ast, &out.writer);
    return out.toOwnedSlice();
}

fn writeIndent(w: *Writer, depth: usize) Writer.Error!void {
    try w.splatByteAll(' ', depth * indent_width);
}

/// Write `text` as a docutils `Text` node: one line per `\n`-separated piece,
/// each at `depth`. A trailing empty piece is a real (blank) line, because
/// docutils writes `indent + line` for every piece including the last.
fn writeText(w: *Writer, depth: usize, text: []const u8) Writer.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |piece| {
        try writeIndent(w, depth);
        try w.writeAll(piece);
        try w.writeByte('\n');
    }
}

fn lessByKey(_: void, a: AST.KeyVal, b: AST.KeyVal) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn writeNode(allocator: Allocator, ast: *const AST, id: Node.Id, depth: usize, w: *Writer) EncodeError!void {
    const node = ast.nodes[id];
    if (node.kind == .str) {
        try writeText(w, depth, node.kind.str);
        return;
    }

    const tag = encodeTag(node.kind) orelse return error.UnrepresentableKind;
    try writeIndent(w, depth);
    try w.writeByte('<');
    try w.writeAll(tag.name());

    // Attributes come from `attrs` and ONLY from `attrs`, never from a kind's
    // payload — including where `decode` read one into the payload (a `link`'s
    // `destination` came from `refuri`). Synthesizing `refuri=` from
    // `Kind.Link.destination` would give the same byte here and make the pair a
    // second source of truth, so that a payload edited without its attribute
    // would silently win. The one direction is: attributes are the record, and a
    // payload read out of them is a READING. Whether the eventual parser also
    // populates `attrs` is a question for the parser (it must anyway — docutils
    // `ids`/`names` have nowhere else to live), not one to prejudge here.
    //
    // docutils' `attlist()` sorts by name, so a doctree's attribute order is
    // canonical rather than as-written. `AST.Attrs` is order-preserving (djot
    // needs that), so the sort happens here on a copy.
    const attrs = ast.attrsOf(id);
    if (attrs.entries.len > 0) {
        const sorted = try allocator.dupe(AST.KeyVal, attrs.entries);
        defer allocator.free(sorted);
        std.mem.sort(AST.KeyVal, sorted, {}, lessByKey);
        for (sorted) |kv| {
            try w.writeByte(' ');
            try w.writeAll(kv.key);
            // pformat has no bare-attribute form; a valueless entry (which no
            // decode produces) writes as empty rather than silently vanishing.
            try w.writeAll("=\"");
            try w.writeAll(kv.value orelse "");
            try w.writeByte('"');
        }
    }
    try w.writeByte('>');
    try w.writeByte('\n');

    // A text-carrying kind holds what was a `Text` child, so it writes back out
    // as one — before any real children, which these kinds never have.
    switch (node.kind) {
        .text_leaf => |l| try writeText(w, depth + 1, l.text),
        .code_block => |c| try writeText(w, depth + 1, c.text),
        .markup_leaf => |l| try writeText(w, depth + 1, l.text),
        else => {},
    }

    var it = ast.children(id);
    while (it.next()) |child| {
        try writeNode(allocator, ast, child.id, depth + 1, w);
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Decode `src` and encode it straight back — the identity the corpus asserts.
fn roundTrip(allocator: Allocator, src: []const u8) ![]u8 {
    var ast = try decode(allocator, src, null);
    defer ast.deinit();
    return encodeAlloc(allocator, &ast);
}

test "round-trips a nested document with attributes" {
    const src =
        \\<document source="test data">
        \\    <paragraph>
        \\        Line 1.
        \\        Line 2.
        \\    <block_quote>
        \\        <paragraph>
        \\            Indented.
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "attributes are re-emitted sorted by name" {
    // Decoded in source order, written back sorted — which is already the
    // corpus's order, so a doctree that arrives sorted stays byte-identical.
    var b = AST.Builder.init(testing.allocator);
    defer b.deinit();
    const p = try b.addContainer(.para, &.{});
    try b.setAttrs(p, .{ .entries = &.{
        .{ .key = "names", .value = "z" },
        .{ .key = "ids", .value = "a" },
    } });
    var ast = try b.finish(p);
    defer ast.deinit();

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<paragraph ids=\"a\" names=\"z\">\n", out);
}

test "text interleaved with inline elements keeps its trailing whitespace" {
    // The `, ` runs between references are real text nodes; losing their
    // trailing space would still look plausible, which is why this is pinned.
    const src =
        \\<document source="test data">
        \\    <paragraph>
        \\        <reference name="ref" refname="ref">
        \\            ref
        \\        , and
        \\        <emphasis>
        \\            more
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a tag-shaped text line whose name is not a docutils element stays text" {
    // The corpus's single genuine ambiguity: `<URL>` is an option argument's
    // text, not an element.
    const src =
        \\<document source="test data">
        \\    <option_argument delimiter="=">
        \\        <URL>
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    try testing.expectEqual(@as(u32, 1), cov.unknown_tag_shaped_text);
    // It decoded as a text child, not as an element.
    const opt = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("<URL>", ast.nodes[ast.nodes[opt].first_child.?].kind.str);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a blank line inside a literal block is written as the bare indent" {
    // Spelled with explicit escapes rather than a `\\` block because the third
    // line is EIGHT SPACES and nothing else — the whole point of the case, and
    // exactly the kind of thing an editor or a formatter would quietly trim out
    // of a multiline literal.
    const src = "<document source=\"test data\">\n" ++
        "    <literal_block xml:space=\"preserve\">\n" ++
        "        line one\n" ++
        "        \n" ++
        "        line three\n";

    var ast = try decode(testing.allocator, src, null);
    defer ast.deinit();
    const lb = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("line one\n\nline three", ast.nodes[lb].kind.code_block.text);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a text line indented past its own base keeps that indentation" {
    const src =
        \\<document source="test data">
        \\    <paragraph>
        \\        normal
        \\         one space in
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an element with no children is one line" {
    const src =
        \\<document source="test data">
        \\    <comment xml:space="preserve">
        \\    <transition>
        \\
    ;
    const out = try roundTrip(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);

    // The childless `comment` failed `soleStr`, so it stayed generic — an
    // empty payload and an absent one are indistinguishable on a `markup_leaf`.
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();
    try testing.expectEqual(@as(u32, 1), cov.generic[@intFromEnum(Tag.comment)]);
    try testing.expectEqual(@as(u32, 0), cov.semantic[@intFromEnum(Tag.comment)]);
}

test "a literal block with a lone text child decodes to a code block" {
    const src =
        \\<document source="test data">
        \\    <literal_block xml:space="preserve">
        \\        code here
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    const lb = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("code here", ast.nodes[lb].kind.code_block.text);
    // The `xml:space` attribute rides along untouched rather than being
    // absorbed, which is what makes the write-back exact.
    try testing.expectEqualStrings("preserve", ast.attrsOf(lb).get("xml:space").?);
    try testing.expectEqual(@as(u32, 1), cov.semantic[@intFromEnum(Tag.literal_block)]);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an unmapped element decodes to a generic container named after its tag" {
    const src =
        \\<document source="test data">
        \\    <system_message level="3" line="3" source="test data" type="ERROR">
        \\        <paragraph>
        \\            Unexpected indentation.
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    const sm = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("system_message", ast.nodes[sm].kind.container.name);
    try testing.expectEqualStrings("ERROR", ast.attrsOf(sm).get("type").?);
    try testing.expectEqual(@as(u32, 1), cov.generic[@intFromEnum(Tag.system_message)]);
    // ...while the paragraph inside it took the semantic path.
    try testing.expectEqual(@as(u32, 1), cov.semantic[@intFromEnum(Tag.paragraph)]);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "decode rejects input that is not a doctree" {
    try testing.expectError(error.NoRoot, decode(testing.allocator, "", null));
    try testing.expectError(error.TextOutsideRoot, decode(testing.allocator, "bare text\n", null));
}
