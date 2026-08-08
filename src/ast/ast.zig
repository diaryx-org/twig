//! AST = Abstract Syntax Tree for a parsed document.
//!
//! This is Twig's SHARED node vocabulary: every language module
//! (`src/languages/djot/` today; XML/HTML next) parses into this one node
//! model, so structural operations and printers written against `AST` work
//! regardless of which format produced the tree. The kinds below form a
//! common semantic core (headings, emphasis, lists, tables, ...) plus a
//! small generic-markup escape hatch (`element`, `comment`, `doctype`, ...)
//! for constructs with no semantic mapping — languages map what they can to
//! semantic kinds (`<em>` → `emph`) and fall back to `element` for the rest,
//! which is what keeps this vocabulary closed. Djot's tag-by-tag mapping
//! (mirroring djot.js's `src/ast.ts`) is one language's mapping, not this
//! file's definition; anything djot-specific (the reference/footnote
//! side-tables, the block/inline dichotomy) lives in the djot module.
//!
//! Structurally this is the document-format counterpart to fig's config-tree
//! `AST` https://github.com/diaryx-org/fig/blob/main/src/ast/ast.zig`
//! and follows the same conventions:
//! an index-based arena (`Node.Id = u32`, a flat `[]Node`),
//! containers link their children via `first_child`/`next_sibling`
//! rather than owning a `[]Node.Id` slice per node, and the AST is fully self-contained —
//! every string a node carries is copied into `owned_strings` at build time,
//! so a finished `AST` never borrows the original source text and printers can take `*const AST` alone.
//!
//! Node *shape* is much more heterogeneous here than in fig's config AST
//! (~50 kinds vs. ~8), so unlike fig — which folds a container's child
//! pointer directly into its `Kind` union payload (`sequence: ?Id`) — every
//! `Node` carries its own `first_child`/`next_sibling` fields uniformly,
//! regardless of kind. `Kind` then only needs to carry each kind's *extra*
//! data (a heading's level, a code block's language/text, ...); kinds with no
//! extra data beyond their children (e.g. `emph`, `block_quote`) are `void`
//! payloads, following fig's `null_,` shorthand.

const AST = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Span = @import("../span.zig");

const reader = @import("reader.zig");
pub const Builder = @import("builder.zig");

pub const children = reader.children;
pub const ChildIterator = reader.ChildIterator;
pub const attrsOf = reader.attrsOf;
pub const getIdByPath = reader.getIdByPath;
pub const getNodeByPath = reader.getNodeByPath;
pub const pathOf = reader.pathOf;
pub const subtreeIds = reader.subtreeIds;
pub const PathError = reader.PathError;

allocator: Allocator,
owned_strings: []const []const u8 = &.{},

/// The single `doc` node all content hangs off of.
root: Node.Id,

/// Complete node arena, such that `ast.nodes[id] == node` for every id handed
/// out during the build.
nodes: []const Node,

/// Indexed by `Node.attrs` (when non-null): the classes/id/keyvals attached
/// to that node. A side-table (like fig's `node_tags`/`node_comments`)
/// because most nodes carry no attributes at all.
attrs: []const Attrs = &.{},

pub fn deinit(self: *AST) void {
    for (self.owned_strings) |s| self.allocator.free(s);
    self.allocator.free(self.owned_strings);
    self.allocator.free(self.nodes);
    for (self.attrs) |a| {
        self.allocator.free(a.entries);
    }
    self.allocator.free(self.attrs);
}

pub const Node = struct {
    id: Id,
    kind: Kind,
    first_child: ?Id = null,
    next_sibling: ?Id = null,
    /// Byte range `[start, end)` into the source this node was parsed from.
    span: Span = Span.init(0, 0),
    /// The byte range of the node's *interior* — the region an editor may
    /// splice, sitting inside the node's own delimiters. For a container this
    /// is where its children live (for `<div class=x>abc</div>`, the span of
    /// `abc`; for a djot `::: div`, the lines between the fences). A *framed
    /// text leaf* carries one too — its payload interior with the delimiters,
    /// fences, or markers peeled off: a `code_block`'s / `metadata`'s body
    /// between its fences, an inline `verbatim`'s or math node's interior
    /// between its `` ` ``/`$`, a `symb`'s name between its colons, a `<…>`
    /// autolink's URL, an XML `comment`'s or `cdata`'s text. See
    /// `holdsOpaqueText` for the leaf kinds that can hold such interior text.
    ///
    /// `source[content_span]` is the raw source interior and need NOT equal a
    /// normalized text field: an `emph`'s interior is the raw bytes between
    /// its `*`s, not "rendered" emphasis, and a `code_block`'s interior is the
    /// original indented source, whereas its `.text` payload is dedented and
    /// newline-normalized — `source[content_span] != code_block.text` by
    /// design. `content_span` is *where the body is*, not *a copy of it*.
    ///
    /// `null` = unknown or not meaningful: a FRAMELESS node whose span already
    /// IS its content (a bare `str`; a bare `http://…` GFM autolink); a
    /// synthesized node; an EMPTY container or frame with no interior. Parsers
    /// should populate it when it is cheap to compute; a parser that leaves it
    /// `null` is still correct, just less useful to editors. Because a framed
    /// text leaf can carry one, "has a `content_span`" no longer implies
    /// "accepts child nodes" — see `holdsOpaqueText`.
    content_span: ?Span = null,
    /// Index into `AST.attrs`, or `null` if this node has no `{...}`
    /// attributes attached.
    attrs: ?u32 = null,

    pub const Id = u32;

    /// The shared kind vocabulary: a semantic core (one kind per djot.js
    /// `ast.ts` tag) plus generic-markup kinds for what XML/HTML can't map
    /// semantically. Container kinds (whose payload is `void` below) still
    /// get children like any other node, via the uniform
    /// `first_child`/`next_sibling` fields on `Node` itself — see this
    /// file's module doc comment for why that's a `Node`-level field rather
    /// than folded into each variant here (as fig does for its much smaller,
    /// config-oriented `Kind`).
    pub const Kind = union(enum) {
        // ── Document root ───────────────────────────────────────────────
        doc,

        // ── Blocks ──────────────────────────────────────────────────────
        para,
        heading: struct { level: u32 },
        thematic_break,
        /// A heading-implied nesting wrapper; never appears in raw djot
        /// syntax, only synthesized by the parser (see djot.js's `parse.ts`
        /// section handling).
        section,
        code_block: struct { lang: ?[]const u8, text: []const u8 },
        raw_block: struct { format: []const u8, text: []const u8 },
        /// Document-level metadata (front/end matter) as an inert,
        /// self-describing data island — NOT markup. `lang` is the config
        /// language it's written in, stored exactly as the fence tag was
        /// written (`yaml`, `toml`, `fig`, `figl`, `json`, …; a bare `---`
        /// fence defaults to `yaml`, `+++` to `toml`) — no normalization, so
        /// it round-trips losslessly. The HTML printer derives the data-island
        /// MIME mechanically as `application/<lang>`.
        /// `text` is the block body as written. Distinct from `code_block`
        /// (a *rendered* code sample) and `raw_block` (verbatim output for a
        /// target format): metadata is *about* the document and never renders
        /// into the body — the HTML printer projects it to a
        /// `<script type=mime>` data island. See `document-metadata.md`.
        /// Produced by the Markdown parser's frontmatter path; a future pass
        /// hoists front+end blocks into one parsed doc-level `fig` record.
        metadata: struct { lang: []const u8, text: []const u8 },
        block_quote,
        bullet_list: struct { style: BulletListStyle, tight: bool },
        ordered_list: struct { style: OrderedListStyle, tight: bool, start: ?u32 },
        task_list: struct { tight: bool },
        definition_list,
        /// Children: `[Caption, Row, Row, ...]` — the first child is always
        /// a `caption` (possibly an empty one), matching djot.js's tuple type.
        table,

        // ── Container children of the above ──────────────────────────────
        list_item,
        task_list_item: struct { checked: bool },
        definition_list_item,
        term,
        definition,
        row: struct { head: bool },
        cell: struct { head: bool, alignment: Alignment },
        caption,
        footnote: struct { label: []const u8 },
        reference: struct { label: []const u8, destination: []const u8 },

        // ── Inlines ───────────────────────────────────────────────────────
        str: []const u8,
        soft_break,
        hard_break,
        non_breaking_space,
        /// A `:name:` symbol/emoji shortcode; payload is the name, no
        /// leading/trailing `:`.
        symb: []const u8,
        verbatim: []const u8,
        raw_inline: struct { format: []const u8, text: []const u8 },
        inline_math: []const u8,
        display_math: []const u8,
        url: []const u8,
        email: []const u8,
        /// `[^label]` used inline; payload is the label (no `^`/brackets).
        footnote_reference: []const u8,
        smart_punctuation: struct { kind: SmartPunctuationKind, text: []const u8 },
        emph,
        strong,
        link: struct { destination: ?[]const u8, reference: ?[]const u8 },
        image: struct { destination: ?[]const u8, reference: ?[]const u8 },
        mark,
        superscript,
        subscript,
        insert,
        delete,
        double_quoted,
        single_quoted,
        // ── Generic markup ────────────────────────────────────────────────
        /// A NAMED GENERIC CONTAINER — the single escape hatch that keeps this
        /// vocabulary closed. Languages map what they can to semantic kinds
        /// (`<em>` → `emph`) and fall back to this for the rest: an HTML/XML
        /// element (`<video>`, `svg:rect`), a djot fenced div or bracketed
        /// span, a Markdown generic directive (`:::note`), an rST directive
        /// (`.. note::`). Children are parsed nodes like any container;
        /// attributes go in the normal `attrs` side-table.
        ///
        /// ── Why one kind and not four ──────────────────────────────────────
        /// This replaces `div`, `span`, `directive`, and `element`, which were
        /// four spellings of ONE concept — a named-or-classed container with
        /// attributes and children — split by which format's parser produced
        /// them. That split put SURFACE SYNTAX in `Kind`, which is exactly what
        /// `syntax.zig` exists to keep out of the shared vocabulary: it meant a
        /// djot `:::` and an HTML `<div>` were different nodes despite being
        /// the same construct, every consumer (`ast/select.zig`, `ast/json.zig`,
        /// `c_abi.zig`, four serializers) grew four near-identical arms, and a
        /// fifth format could only be added by growing a fifth kind.
        ///
        /// What it does NOT do is erase the difference between a NAME and a
        /// CLASS: djot's `::: note` is a div carrying `class=note` (the name is
        /// `"div"`, the class is in `attrs`), while Markdown's `:::note` is a
        /// directive whose TYPE is `note` (the name is `"note"`, `attrs` is
        /// empty). Those are genuinely different documents and still parse to
        /// different nodes. The unification is structural, not semantic.
        ///
        /// `name` is stored as written, including any namespace prefix
        /// (`svg:rect`) — prefix resolution is a reader-side helper, later.
        container: struct {
            /// The tag or directive type: `"div"`, `"span"`, `"video"`,
            /// `"svg:rect"`, `"note"`. Never empty — djot's anonymous `:::`
            /// and `[…]{…}` carry `"div"`/`"span"`, which is what they render
            /// as and what makes them compare equal to the HTML forms.
            name: []const u8,
            /// How the container was spelled, when the producing format draws
            /// a distinction its serializer must reproduce (see `Form`).
            ///
            /// `null` = UNCLASSIFIED, which is the honest answer for HTML/XML:
            /// whether `<video>` is a block or an inline is a property of the
            /// tag and the stylesheet, not of the parse, and the HTML parser
            /// has never decided it — `languages/djot/djot.zig`'s
            /// `isBlock`/`isInline` report *neither* for such a node, and that
            /// behaviour is preserved here rather than forced into a guess.
            form: ?Form = null,
            /// The directive ARGUMENT: rST's `.. image:: picture.png` puts
            /// `picture.png` here. Positional, so it is neither an attribute
            /// (`attrs` holds `:width: 50%`-style options) nor a child (the
            /// children are the body). `null` for every format that has no
            /// argument position — which today is all of them except rST.
            argument: ?[]const u8 = null,
        },
        /// HTML/XML `<!-- ... -->`; payload is the text between the
        /// delimiters, as written.
        comment: []const u8,
        /// Payload is everything between `<!DOCTYPE` and `>`, as written
        /// (e.g. `html`, or a full XML public/system id soup). Not parsed
        /// further.
        doctype: []const u8,
        /// XML `<?target data?>`.
        processing_instruction: struct { target: []const u8, data: []const u8 },
        /// XML `<![CDATA[...]]>`; payload is the raw contents. (Plain text
        /// nodes are `str`; `cdata` exists separately so the distinction
        /// round-trips.)
        cdata: []const u8,
    };
};

// ── The two axes ───────────────────────────────────────────────────────────
// `Kind` names WHAT a node is. Two further questions get asked of it constantly
// — where it sits in the block/inline hierarchy, and what it is allowed to
// contain — and until now each was answered by a separate hand-maintained list
// per consumer: `languages/djot/djot.zig`'s `block_tags`/`inline_tags`,
// `ast/locate.zig`'s `isBlockParent`, `languages/html/parser.zig`'s
// `isBlockKind`, and `holdsOpaqueText` below. Those lists disagreed (djot
// counted `reference`/`footnote` as blocks and HTML didn't; HTML counted
// `list_item`/`term` and djot didn't), and every new kind had to be threaded
// into each one by hand — with nothing failing the build if it wasn't.
//
// `level` and `contentModel` are the canonical answers. Both switch
// exhaustively, so a NEW KIND CANNOT BE ADDED WITHOUT DECLARING BOTH — which
// is the property the scattered lists never had.

/// Where a kind sits in the document hierarchy.
///
/// `neither` is not a shrug: it is the honest answer for three groups. The
/// `doc` root is not itself a block. A structural child (`list_item`, `row`,
/// `cell`, `term`, `caption`, …) only ever appears inside its own parent and
/// never where a paragraph could go — which is exactly djot.js's `isBlock`
/// rule, and why those are excluded here too. And a generic-markup node
/// (`comment`, `doctype`, an unclassified `container`) genuinely has no level:
/// whether an HTML `<video>` is a block is a property of the stylesheet, not
/// the parse.
pub const Level = enum { block, @"inline", neither };

/// What a kind may hold. The distinction `blocks`/`inlines` vs `text` is the
/// load-bearing one: a `text` node's `content_span` addresses OPAQUE BYTES, not
/// a child region, so `insertChild` must refuse it even though it has a
/// `content_span` (`replaceContent` still works). See `Node.content_span`.
///
/// This is what a kind may CONTAIN, not what a given node DOES contain. The
/// difference is observable: in one HTML table, `<td><p>x</p></td>` parses to
/// `cell > para` while its sibling `<td>y</td>` parses to `cell > str`, and
/// djot puts inlines directly in every cell. Both are `.blocks` here — an
/// inline run is the tight, `<p>`-elided case, exactly as a tight list item
/// holds inlines without stopping `list_item` from being a block container.
/// Every caller consults this as a PERMISSION ("may children go here at all"),
/// which is the only reading the data supports.
pub const ContentModel = enum {
    /// Children are block-level nodes.
    blocks,
    /// Children are inline nodes.
    inlines,
    /// An opaque text payload and no children — see `holdsOpaqueText`.
    text,
    /// Neither children nor text: `thematic_break`, `soft_break`, `reference`.
    empty,
};

/// `kind`'s position in the block/inline hierarchy. See `Level`.
pub fn level(kind: Node.Kind) Level {
    return switch (kind) {
        .para,
        .heading,
        .thematic_break,
        .section,
        .code_block,
        .raw_block,
        .metadata,
        .block_quote,
        .bullet_list,
        .ordered_list,
        .task_list,
        .definition_list,
        .table,
        .footnote,
        .reference,
        => .block,

        .str,
        .soft_break,
        .hard_break,
        .non_breaking_space,
        .symb,
        .verbatim,
        .raw_inline,
        .inline_math,
        .display_math,
        .url,
        .email,
        .footnote_reference,
        .smart_punctuation,
        .emph,
        .strong,
        .link,
        .image,
        .mark,
        .superscript,
        .subscript,
        .insert,
        .delete,
        .double_quoted,
        .single_quoted,
        => .@"inline",

        // A generic container's level is the one thing `form` was introduced to
        // carry (see `Form`); an unclassified one has none.
        .container => |c| if (c.form) |f|
            (if (f.isBlockForm()) .block else .@"inline")
        else
            .neither,

        // The root, the structural children, and generic markup — see `Level`.
        .doc,
        .list_item,
        .task_list_item,
        .definition_list_item,
        .term,
        .definition,
        .row,
        .cell,
        .caption,
        .comment,
        .doctype,
        .processing_instruction,
        .cdata,
        => .neither,
    };
}

/// What `kind` may contain. See `ContentModel`.
pub fn contentModel(kind: Node.Kind) ContentModel {
    return switch (kind) {
        .str,
        .symb,
        .verbatim,
        .raw_inline,
        .inline_math,
        .display_math,
        .url,
        .email,
        .footnote_reference,
        .smart_punctuation,
        .code_block,
        .raw_block,
        .metadata,
        .comment,
        .doctype,
        .cdata,
        => .text,

        .thematic_break,
        .soft_break,
        .hard_break,
        .non_breaking_space,
        .reference,
        .processing_instruction,
        => .empty,

        .doc,
        .section,
        .block_quote,
        .bullet_list,
        .ordered_list,
        .task_list,
        .definition_list,
        .table,
        .list_item,
        .task_list_item,
        .definition_list_item,
        .definition,
        .row,
        .cell,
        .footnote,
        => .blocks,

        .para,
        .heading,
        .term,
        .caption,
        .emph,
        .strong,
        .link,
        .image,
        .mark,
        .superscript,
        .subscript,
        .insert,
        .delete,
        .double_quoted,
        .single_quoted,
        => .inlines,

        // A fenced container holds blocks; the inline and one-line-leaf forms
        // hold the label's inlines. An UNCLASSIFIED container (an HTML/XML
        // element) may hold either, and answers `blocks` as the permissive
        // one — every caller that consults this is asking "may I put children
        // here at all", and only `text` answers no.
        .container => |c| if (c.form) |f| switch (f) {
            .block_fenced => .blocks,
            .block_leaf, .inline_text => .inlines,
        } else .blocks,
    };
}

/// True for kinds that carry a TEXT/opaque payload rather than child nodes —
/// a code block's body, an inline `verbatim`'s or math node's interior, a raw
/// block, a bare `str`, etc. (the same set `c_abi.zig`'s `kindText` extracts).
/// When such a leaf has a `content_span`, that span addresses opaque text, not
/// a child region: there is no child sequence to index into, so `insertChild`
/// must refuse it even though it has a `content_span` (`replaceContent`, which
/// replaces the whole interior, still works). This is the flip side of
/// `content_span` no longer implying "container" — see its doc on `Node`.
///
/// Now a thin reading of `contentModel`, kept as its own name because that is
/// what the callers mean and because it is public API.
pub fn holdsOpaqueText(kind: Node.Kind) bool {
    return contentModel(kind) == .text;
}

/// A single attribute pair (`AttributeParser`'s `keyval`). A `null` value
/// means a *bare* attribute — HTML `disabled`, which must round-trip
/// distinctly from `disabled=""`. Djot attribute syntax has no way to write
/// a bare attribute, so djot parses always produce non-null values.
pub const KeyVal = struct { key: []const u8, value: ?[]const u8 };

/// The parsed contents of a `{.class #id key="val"}` attribute block, as
/// attached to a `Node` via `Node.attrs`. See djot.js's `attributes.ts`.
///
/// Deliberately a single ORDER-PRESERVING list rather than separate
/// `classes`/`id`/`keyvals` fields: djot.js stores attributes as one plain
/// object whose iteration order is insertion order, and renders them back in
/// that same order — `{key1=val1 .foo key2=val2}` renders
/// `key1="val1" class="foo" key2="val2"`, interleaved exactly as written,
/// not grouped by kind. `class` and `id` are therefore just ordinary keys
/// here (`class`'s value accumulates multiple `.foo .bar` occurrences
/// space-joined, at the position of its FIRST occurrence — matching
/// djot.js's "mutate the existing object property" behavior). Use `get` for
/// lookups; there is no dedicated `id`/`class` accessor because callers that
/// care about rendering need the entries in order anyway.
pub const Attrs = struct {
    entries: []const KeyVal = &.{},

    pub fn isEmpty(self: Attrs) bool {
        return self.entries.len == 0;
    }

    /// Look up an attribute's whole entry by key — the presence test that
    /// distinguishes "key absent" (`null` here) from "key present but bare"
    /// (an entry whose `value` is `null`, e.g. HTML `disabled`).
    pub fn find(self: Attrs, key: []const u8) ?KeyVal {
        for (self.entries) |kv| {
            if (std.mem.eql(u8, kv.key, key)) return kv;
        }
        return null;
    }

    /// Look up an attribute's value by key (e.g. `"id"`, `"class"`). Both
    /// an absent key and a bare (valueless) attribute yield `null` — use
    /// `find` when that distinction matters.
    pub fn get(self: Attrs, key: []const u8) ?[]const u8 {
        const kv = self.find(key) orelse return null;
        return kv.value;
    }
};

/// How a `container` was spelled — the one piece of a generic container's
/// shape that a per-format `Syntax` table CANNOT hold, because it varies per
/// NODE rather than per format: one Markdown document may contain both a
/// `::name` leaf and a `:::name` fence, so the choice has to travel with the
/// node. Everything else about spelling a container back (the colon, the
/// angle brackets, the `.. ` prefix) is format-uniform and belongs in
/// `syntax.zig`.
///
/// Also carries the block/inline classification that `div` and `span` used to
/// encode by being separate kinds: `inline_text` is an inline, the two
/// `block_*` forms are blocks, and a `null` form is neither (see
/// `Kind.container.form`).
///   - `inline_text`: inline — djot `[label]{attrs}`, Markdown `:name[label]`.
///   - `block_leaf`: block, no body — Markdown `::name[label]{attrs}`,
///     rST `.. name:: argument` with nothing indented under it.
///   - `block_fenced`: block with a body — djot `:::` … `:::`, Markdown
///     `:::name{attrs}` … `:::`, rST `.. name::` + an indented block.
pub const Form = enum {
    inline_text,
    block_leaf,
    block_fenced,

    /// True for the forms that classify as blocks (`block_leaf`,
    /// `block_fenced`) — the half of `djot.zig`'s `isBlock` that a flat
    /// `EnumSet` over kind tags can no longer answer now that one kind spans
    /// both levels.
    pub fn isBlockForm(self: Form) bool {
        return self != .inline_text;
    }
};

pub const BulletListStyle = enum { dash, plus, star };

pub const OrderedListStyle = struct {
    numbering: Numbering,
    delim: Delim,

    pub const Numbering = enum { decimal, lower_alpha, upper_alpha, lower_roman, upper_roman };
    /// Which punctuation wraps the number: `1.`, `1)`, or `(1)`.
    pub const Delim = enum { period, paren_after, paren_both };
};

pub const Alignment = enum { default, left, right, center };

pub const SmartPunctuationKind = enum {
    left_single_quote,
    right_single_quote,
    left_double_quote,
    right_double_quote,
    ellipses,
    em_dash,
    en_dash,
};

test {
    _ = Builder;
    _ = reader;
}

test "Attrs.find distinguishes a bare attribute from an absent key" {
    const testing = std.testing;
    const attrs: Attrs = .{ .entries = &.{
        .{ .key = "disabled", .value = null },
        .{ .key = "id", .value = "x" },
    } };

    // Bare attribute: present per `find`, but `get` can't tell it apart
    // from an absent key.
    const bare = attrs.find("disabled") orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("disabled", bare.key);
    try testing.expectEqual(@as(?[]const u8, null), bare.value);
    try testing.expectEqual(@as(?[]const u8, null), attrs.get("disabled"));

    // Valued attribute: both accessors agree.
    try testing.expectEqualStrings("x", attrs.find("id").?.value.?);
    try testing.expectEqualStrings("x", attrs.get("id").?);

    // Absent key: `find` is the only way to see the difference.
    try testing.expectEqual(@as(?KeyVal, null), attrs.find("missing"));
    try testing.expectEqual(@as(?[]const u8, null), attrs.get("missing"));
}
