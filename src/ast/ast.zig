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
//! ── This file holds MEANING, not POSITION ──────────────────────────────────
//! Byte offsets are NOT here. A node's `span`/`content_span` live in
//! `src/document.zig`'s id-indexed side-tables, alongside the `source` they
//! address — again following fig, whose `Node` is likewise `{id, kind,
//! next_sibling}` with positions in a sibling `Document`.
//!
//! The split is what makes `eql` (below) possible: two parses can be compared
//! for *meaning* because there are no positions left in the tree to disagree
//! about, with `Document.spansEql` as the separate layer for "…and were
//! written the same way". It also makes the boundary enforceable rather than
//! conventional — a printer taking `*const AST` cannot reach a byte offset,
//! while the edit layer takes a `*const Document` because splicing needs both
//! halves.
//!
//! The rule for which side a new field lands on: a fact belongs in `Document`
//! iff two documents differing only in that fact RENDER IDENTICALLY. A list's
//! `tight` flag fails that test (it elides the `<p>`), so it stays in `Kind`;
//! a bullet's `-`-vs-`*` spelling passes it.
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
    /// Index into `AST.attrs`, or `null` if this node has no `{...}`
    /// attributes attached.
    attrs: ?Attrs.Id = null,

    pub const Id = u32;

    // There is deliberately no `Node.eql`. A node's identity here is its
    // `id`/`first_child`/`next_sibling` — arena slots, which are a parsing
    // artifact, not part of the document (see `AST.eql`). A node-level
    // equality that compared them would be a trap; one that ignored them
    // would just be `kind.eql`. Compare kinds, or compare trees.

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
        heading: Heading,
        thematic_break,
        /// A heading-implied nesting wrapper; never appears in raw djot
        /// syntax, only synthesized by the parser (see djot.js's `parse.ts`
        /// section handling).
        section,
        code_block: CodeBlock,
        raw_block: RawBlock,
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
        metadata: Metadata,
        block_quote,
        bullet_list: BulletList,
        ordered_list: OrderedList,
        task_list: TaskList,
        definition_list,
        /// Children: `[Caption, Row, Row, ...]` — the first child is always
        /// a `caption` (possibly an empty one), matching djot.js's tuple type.
        table,

        // ── Container children of the above ──────────────────────────────
        list_item,
        task_list_item: TaskListItem,
        definition_list_item,
        term,
        definition,
        row: Row,
        cell: Cell,
        caption,
        footnote: Footnote,
        reference: Reference,

        // ── Inlines ───────────────────────────────────────────────────────
        str: []const u8,
        soft_break,
        hard_break,
        non_breaking_space,
        /// A DELIMITED INLINE TEXT LEAF — a `:name:` shortcode, a `` `code` ``
        /// span, `$math$`, a `<https://…>` autolink, a `[^label]` footnote
        /// reference. Opaque text plus the marker that frames it; which one it
        /// is rides in the payload. See `TextLeafKind`.
        ///
        /// `str` is deliberately NOT one of these: it is the UNdelimited case —
        /// plain content with no marker at all — and it is by far the most
        /// common node in any document, so it keeps its own arm rather than
        /// paying an indirection to join a family it doesn't belong to. fig
        /// draws the same line between `string` and `extended`.
        text_leaf: TextLeaf,
        raw_inline: RawInline,
        /// A `'`/`'`/`"`/`"`/`...`/`--`/`---` run djot recognized as smart
        /// punctuation. Stays its own arm (rather than folding into
        /// `text_leaf` or `inline_mark`) because its kind is a SEMANTIC
        /// choice the HTML printer acts on (which glyph to emit), not a
        /// spelling — but unlike `text_leaf`/`markup_leaf`, the payload here
        /// is the bare `SmartPunctuationKind` enum, not `{kind, text}`: the
        /// source spelling is CANONICAL per kind (the parser normalizes
        /// djot's explicit `{"` to `"`, same as the implicit form), so
        /// there is no per-node spelling left to store — it is derived on
        /// demand by `SmartPunctuationKind.ascii`.
        smart_punctuation: SmartPunctuationKind,
        link: Link,
        /// Same payload type as `link` on purpose — see `Link`.
        image: Link,
        /// A paired-delimiter inline wrapper — `*emph*`, `**strong**`,
        /// `{=mark=}`, `^sup^`, `~sub~`, `{+ins+}`, `{-del-}`, and djot's two
        /// smart-quote containers. Which one it is rides in the payload rather
        /// than in the tag; see `InlineMark`.
        inline_mark: InlineMark,
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
        container: Container,
        /// A DELIMITED GENERIC-MARKUP LEAF — an HTML/XML `<!-- comment -->`,
        /// a `<!DOCTYPE …>`, a `<![CDATA[…]]>`. Opaque text plus the
        /// delimiters that frame it; which one it is rides in the payload.
        /// See `MarkupLeafKind`.
        markup_leaf: MarkupLeaf,
        /// XML `<?target data?>`. NOT a `markup_leaf`, for the same reason
        /// `raw_inline` is not a `text_leaf`: its payload is `{target, data}`,
        /// a second field the family's members don't have.
        processing_instruction: ProcessingInstruction,

        // ── Payload shapes ────────────────────────────────────────────────
        // Named, like fig's `Number`/`Extended`, so a payload can be spelled
        // outside a switch prong (`Kind.Heading`, `Kind.Container`).
        // Anonymous literals (`.{ .heading = .{ .level = 2 } }`) coerce to
        // these unchanged.

        pub const Heading = struct { level: u32 };
        pub const CodeBlock = struct { lang: ?[]const u8, text: []const u8 };
        pub const RawBlock = struct { format: []const u8, text: []const u8 };
        pub const Metadata = struct { lang: []const u8, text: []const u8 };
        pub const BulletList = struct { style: BulletListStyle, tight: bool };
        pub const OrderedList = struct { style: OrderedListStyle, tight: bool, start: ?u32 };
        pub const TaskList = struct { tight: bool };
        pub const TaskListItem = struct { checked: bool };
        pub const Row = struct { head: bool };
        pub const Cell = struct { head: bool, alignment: Alignment };
        pub const Footnote = struct { label: []const u8 };
        pub const Reference = struct { label: []const u8, destination: []const u8 };
        pub const TextLeaf = struct { kind: TextLeafKind, text: []const u8 };
        pub const RawInline = struct { format: []const u8, text: []const u8 };
        /// The ONE payload shape behind BOTH `link` and `image` — the shapes
        /// are identical on purpose (an image is a link rendered differently,
        /// not a different record), and sharing the type documents that.
        pub const Link = struct { destination: ?[]const u8, reference: ?[]const u8 };
        pub const MarkupLeaf = struct { kind: MarkupLeafKind, text: []const u8 };
        pub const ProcessingInstruction = struct { target: []const u8, data: []const u8 };

        pub const Container = struct {
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
        };

        // ── The two axes ─────────────────────────────────────────────────
        // `Kind` names WHAT a node is. Two further questions get asked of it
        // constantly — where it sits in the block/inline hierarchy, and what
        // it is allowed to contain — and until now each was answered by a
        // separate hand-maintained list per consumer:
        // `languages/djot/djot.zig`'s `block_tags`/`inline_tags`,
        // `ast/locate.zig`'s `isBlockParent`, `languages/html/parser.zig`'s
        // `isBlockKind`, and `holdsOpaqueText` below. Those lists disagreed
        // (djot counted `reference`/`footnote` as blocks and HTML didn't;
        // HTML counted `list_item`/`term` and djot didn't), and every new
        // kind had to be threaded into each one by hand — with nothing
        // failing the build if it wasn't.
        //
        // `level` and `contentModel` are the canonical answers. Both switch
        // exhaustively, so a NEW KIND CANNOT BE ADDED WITHOUT DECLARING BOTH
        // — which is the property the scattered lists never had.

        /// Where a kind sits in the document hierarchy.
        ///
        /// `neither` is not a shrug: it is the honest answer for three
        /// groups. The `doc` root is not itself a block. A structural child
        /// (`list_item`, `row`, `cell`, `term`, `caption`, …) only ever
        /// appears inside its own parent and never where a paragraph could
        /// go — which is exactly djot.js's `isBlock` rule, and why those are
        /// excluded here too. And a generic-markup node (a `markup_leaf`, an
        /// unclassified `container`) genuinely has no level: whether an HTML
        /// `<video>` is a block is a property of the stylesheet, not the
        /// parse.
        pub const Level = enum { block, @"inline", neither };

        /// What a kind may hold. The distinction `blocks`/`inlines` vs `text`
        /// is the load-bearing one: a `text` node's `content_span` addresses
        /// OPAQUE BYTES, not a child region, so `insertChild` must refuse it
        /// even though it has a `content_span` (`replaceContent` still
        /// works). See `Node.content_span`.
        ///
        /// This is what a kind may CONTAIN, not what a given node DOES
        /// contain. The difference is observable: in one HTML table,
        /// `<td><p>x</p></td>` parses to `cell > para` while its sibling
        /// `<td>y</td>` parses to `cell > str`, and djot puts inlines
        /// directly in every cell. Both are `.blocks` here — an inline run is
        /// the tight, `<p>`-elided case, exactly as a tight list item holds
        /// inlines without stopping `list_item` from being a block container.
        /// Every caller consults this as a PERMISSION ("may children go here
        /// at all"), which is the only reading the data supports.
        pub const ContentModel = enum {
            /// Children are block-level nodes.
            blocks,
            /// Children are inline nodes.
            inlines,
            /// An opaque text payload and no children — see `holdsOpaqueText`.
            text,
            /// Neither children nor text: `thematic_break`, `soft_break`,
            /// `reference`.
            empty,
        };

        /// The name a kind reports to the OUTSIDE — `ast/json.zig`'s `"kind"`
        /// field and `c_abi.zig`'s `twig_node_kind_name`.
        ///
        /// For an `inline_mark` this is the MARK's name (`"emph"`,
        /// `"strong"`), never `"inline_mark"`. The family is an internal
        /// structuring; the published vocabulary predates it and does not
        /// move because of it.
        pub fn kindName(self: Kind) []const u8 {
            return switch (self) {
                .inline_mark => |m| @tagName(m),
                .text_leaf => |l| @tagName(l.kind),
                .markup_leaf => |l| @tagName(l.kind),
                else => @tagName(self),
            };
        }

        /// The kind's position in the block/inline hierarchy. See `Level`.
        pub fn level(self: Kind) Level {
            return switch (self) {
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
                .text_leaf,
                .raw_inline,
                .smart_punctuation,
                .link,
                .image,
                .inline_mark,
                => .@"inline",

                // A generic container's level is the one thing `form` was
                // introduced to carry (see `Form`); an unclassified one has
                // none.
                .container => |c| if (c.form) |f|
                    (if (f.isBlockForm()) .block else .@"inline")
                else
                    .neither,

                // The root, the structural children, and generic markup —
                // see `Level`.
                .doc,
                .list_item,
                .task_list_item,
                .definition_list_item,
                .term,
                .definition,
                .row,
                .cell,
                .caption,
                .markup_leaf,
                .processing_instruction,
                => .neither,
            };
        }

        /// What the kind may contain. See `ContentModel`.
        pub fn contentModel(self: Kind) ContentModel {
            return switch (self) {
                .str,
                .text_leaf,
                .raw_inline,
                // Its payload is now a bare `SmartPunctuationKind` (see
                // `Kind.smart_punctuation`'s doc), not a `{kind, text}`
                // struct — there is no stored string to point `content_span`
                // at, and the djot parser never gives it one (`content_span`
                // stays `null`; `replaceContent` already refuses it via that,
                // not via this classification). It stays `.text` rather than
                // moving to `.empty` because `c_abi.zig`'s `kindText` is
                // documented as extracting exactly the `holdsOpaqueText`
                // set, and keeps reporting a (derived, via
                // `SmartPunctuationKind.ascii`) string for it to hold that
                // external C-surface behavior steady — so "opaque text
                // payload" here means DERIVED text, not stored text.
                .smart_punctuation,
                .code_block,
                .raw_block,
                .metadata,
                .markup_leaf,
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
                .link,
                .image,
                .inline_mark,
                => .inlines,

                // A fenced container holds blocks; the inline and
                // one-line-leaf forms hold the label's inlines. An
                // UNCLASSIFIED container (an HTML/XML element) may hold
                // either, and answers `blocks` as the permissive one — every
                // caller that consults this is asking "may I put children
                // here at all", and only `text` answers no.
                .container => |c| if (c.form) |f| switch (f) {
                    .block_fenced => .blocks,
                    .block_leaf, .inline_text => .inlines,
                } else .blocks,
            };
        }

        /// True for kinds that carry a TEXT/opaque payload rather than child
        /// nodes — a code block's body, an inline `verbatim`'s or math node's
        /// interior, a raw block, a bare `str`, etc. (the same set
        /// `c_abi.zig`'s `kindText` extracts — `smart_punctuation` included,
        /// even though its "text" is now DERIVED from the kind rather than
        /// stored; see `contentModel`'s comment on that arm). When such a
        /// leaf has a `content_span`, that span addresses opaque text, not a
        /// child region: there is no child sequence to index into, so
        /// `insertChild` must refuse it even though it has a `content_span`
        /// (`replaceContent`, which replaces the whole interior, still
        /// works). This is the flip side of `content_span` no longer implying
        /// "container" — see its doc on `Node`.
        ///
        /// Now a thin reading of `contentModel`, kept as its own name because
        /// that is what the callers mean and because it is public API.
        pub fn holdsOpaqueText(self: Kind) bool {
            return self.contentModel() == .text;
        }

        /// Structural equality of two kinds, payload included. Every arm is
        /// spelled, so a new kind (or a new payload field) fails this build
        /// until it declares how it compares — the same exhaustiveness
        /// property `level`/`contentModel` have.
        pub fn eql(self: Kind, other: Kind) bool {
            if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
            return switch (self) {
                // Payload-free kinds: the tag match above is the whole answer.
                .doc,
                .para,
                .thematic_break,
                .section,
                .block_quote,
                .definition_list,
                .table,
                .list_item,
                .definition_list_item,
                .term,
                .definition,
                .caption,
                .soft_break,
                .hard_break,
                .non_breaking_space,
                => true,

                .heading => |v| v.level == other.heading.level,
                .code_block => |v| eqlOptStr(v.lang, other.code_block.lang) and
                    eqlStr(v.text, other.code_block.text),
                .raw_block => |v| eqlStr(v.format, other.raw_block.format) and
                    eqlStr(v.text, other.raw_block.text),
                .metadata => |v| eqlStr(v.lang, other.metadata.lang) and
                    eqlStr(v.text, other.metadata.text),
                .bullet_list => |v| v.style == other.bullet_list.style and
                    v.tight == other.bullet_list.tight,
                .ordered_list => |v| v.style.numbering == other.ordered_list.style.numbering and
                    v.style.delim == other.ordered_list.style.delim and
                    v.tight == other.ordered_list.tight and
                    v.start == other.ordered_list.start,
                .task_list => |v| v.tight == other.task_list.tight,
                .task_list_item => |v| v.checked == other.task_list_item.checked,
                .row => |v| v.head == other.row.head,
                .cell => |v| v.head == other.cell.head and v.alignment == other.cell.alignment,
                .footnote => |v| eqlStr(v.label, other.footnote.label),
                .reference => |v| eqlStr(v.label, other.reference.label) and
                    eqlStr(v.destination, other.reference.destination),
                .str => |v| eqlStr(v, other.str),
                .text_leaf => |v| v.kind == other.text_leaf.kind and
                    eqlStr(v.text, other.text_leaf.text),
                .raw_inline => |v| eqlStr(v.format, other.raw_inline.format) and
                    eqlStr(v.text, other.raw_inline.text),
                .smart_punctuation => |v| v == other.smart_punctuation,
                .link => |v| eqlOptStr(v.destination, other.link.destination) and
                    eqlOptStr(v.reference, other.link.reference),
                .image => |v| eqlOptStr(v.destination, other.image.destination) and
                    eqlOptStr(v.reference, other.image.reference),
                .inline_mark => |v| v == other.inline_mark,
                .container => |v| eqlStr(v.name, other.container.name) and
                    v.form == other.container.form and
                    eqlOptStr(v.argument, other.container.argument),
                .markup_leaf => |v| v.kind == other.markup_leaf.kind and
                    eqlStr(v.text, other.markup_leaf.text),
                .processing_instruction => |v| eqlStr(v.target, other.processing_instruction.target) and
                    eqlStr(v.data, other.processing_instruction.data),
            };
        }
    };
};

fn eqlStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn eqlOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return std.mem.eql(u8, a.?, b.?);
}

/// Abstract document equality: do these two trees MEAN the same thing?
///
/// Source positions are not consulted — they live in `document.zig`, and
/// `Document.spansEql` is the separate layer for "…and were written the same
/// way". That split is the point of the two types: this function is what makes
/// "two documents of different formats can have the same AST" a claim a test
/// can check rather than a design aspiration.
///
/// This is a STRUCTURAL WALK from each root, not a comparison of the two node
/// arrays. fig's `AST.eql` can compare `nodes` as a flat slice because its
/// parsers emit exactly the reachable tree; Twig's do not.
///
/// Twig's inline parsers are SPECULATIVE: `languages/markdown/inline.zig`
/// emits each delimiter run as a literal-text `str` up front, then, if the run
/// resolves into emphasis, builds the mark node and leaves the two `str`s
/// unreferenced in the arena. Parsing `**x**` and `__x__` therefore yields
/// arenas of the same size and the same kinds — but the orphans hold `"**"` in
/// one and `"__"` in the other. Those payloads are the abandoned SPELLING, and
/// a flat slice comparison compares them, reporting two spellings of one
/// document as different documents. That is exactly the question this function
/// exists to answer correctly, so it walks only what is reachable.
///
/// Ids are not compared either: an id is an arena slot, and arena slots are a
/// parsing artifact. What is compared is each node's kind (payload included),
/// its attributes, and its children in order.
pub fn eql(self: AST, other: AST) bool {
    return eqlNode(self, self.root, other, other.root);
}

fn eqlNode(a: AST, a_id: Node.Id, b: AST, b_id: Node.Id) bool {
    const an = a.nodes[a_id];
    const bn = b.nodes[b_id];
    if (!an.kind.eql(bn.kind)) return false;
    if (!attrsEql(a.attrsOf(a_id), b.attrsOf(b_id))) return false;

    var ia = a.children(a_id);
    var ib = b.children(b_id);
    while (true) {
        const ca = ia.next();
        const cb = ib.next();
        if (ca == null and cb == null) return true;
        const x = ca orelse return false;
        const y = cb orelse return false;
        if (!eqlNode(a, x.id, b, y.id)) return false;
    }
}

fn attrsEql(a: Attrs, b: Attrs) bool {
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |x, y| {
        if (!eqlStr(x.key, y.key)) return false;
        if (!eqlOptStr(x.value, y.value)) return false;
    }
    return true;
}

/// Which paired-delimiter inline a `Kind.inline_mark` is.
///
/// ── Why a nested enum and not nine union arms ──────────────────────────────
/// Borrowed from fig's `Kind.Extended` (`ast/ast.zig`), whose doc states the
/// property this is here for: "adding a new such scalar is a new `ExtKind`, not
/// a new union arm: the outer switches stay closed; only the printers (where
/// cross-format rendering is inherently type-specific) gain a case."
///
/// These nine were nine arms, and every GENERIC consumer treated all nine
/// identically — `level` and `contentModel` below listed them twice over,
/// `ast/json.zig` lumped them into one payload-free arm, `ast/select.zig` never
/// distinguished them. Only the three serializers care, and only because each
/// mark has its own delimiters — which is `syntax.zig`'s `Delims` table's job,
/// not `Kind`'s.
///
/// Crucially this is NOT string matching and NOT a loss of exhaustiveness: a
/// serializer still switches over `InlineMark` exhaustively, so a tenth mark
/// still fails those builds until it is spelled. What it stops doing is failing
/// the builds that never cared.
///
/// The EXTERNAL vocabulary is unchanged: `ast/json.zig` still emits
/// `"kind": "emph"` and `c_abi.zig`'s `kindName` still reports `"emph"`, both
/// by projecting the mark name up into the kind name. This is an internal
/// structuring, not a surface change.
pub const InlineMark = enum {
    emph,
    strong,
    mark,
    superscript,
    subscript,
    insert,
    delete,
    double_quoted,
    single_quoted,
};

/// Which delimited inline text leaf a `Kind.text_leaf` is.
///
/// The same pattern as `InlineMark`, one level down: seven kinds that every
/// generic consumer handled identically — `ast/json.zig` had seven
/// byte-identical `{"text": …}` arms, `ast/builder.zig` seven identical dupes,
/// `level`/`contentModel` listed all seven twice — and that only the printers
/// tell apart, because only their delimiters differ.
///
/// `raw_inline` is excluded: its payload is `{format, text}`, a second field
/// that would have to be `null` for all seven of these. `str` is excluded for
/// the opposite reason (see `Kind.text_leaf`).
pub const TextLeafKind = enum {
    /// `:name:` — payload is the name, no surrounding colons.
    symb,
    /// `` `code` `` — payload is the interior.
    verbatim,
    inline_math,
    display_math,
    url,
    email,
    /// `[^label]` used inline; payload is the label (no `^`/brackets).
    footnote_reference,
};

/// Which generic-markup leaf a `Kind.markup_leaf` is.
///
/// The same pattern as `InlineMark` and `TextLeafKind`, in the generic-markup
/// corner: three kinds that every generic consumer handled identically — all
/// `.neither` in `level`, all `.text` in `contentModel`, near-identical
/// `{"text": …}` arms in `ast/json.zig` and dupes in `ast/builder.zig` — and
/// that only the serializers tell apart, because only their delimiters differ
/// (`<!-- … -->`, `<!DOCTYPE …>`, `<![CDATA[…]]>`).
///
/// `processing_instruction` is excluded for the same reason `raw_inline`
/// stayed out of `TextLeafKind`: its payload is `{target, data}`, a second
/// field that would have to be `null` for all three of these.
pub const MarkupLeafKind = enum {
    /// HTML/XML `<!-- ... -->`; payload is the text between the delimiters,
    /// as written.
    comment,
    /// Payload is everything between `<!DOCTYPE` and `>`, as written (e.g.
    /// `html`, or a full XML public/system id soup). Not parsed further.
    doctype,
    /// XML `<![CDATA[...]]>`; payload is the raw contents. (Plain text nodes
    /// are `str`; `cdata` exists separately so the distinction round-trips.)
    cdata,
};

/// Names a kind precisely enough to match a node against it.
///
/// A bare `Kind` tag used to be enough, and for most kinds it still is. It
/// stopped being enough for the nine `InlineMark`s, whose tag is now all
/// `inline_mark`: "find the enclosing `strong`" cannot be asked with a tag.
/// This is the exhaustively-switched bridge — no strings, and adding a family
/// means adding an arm here, which fails every `matches` caller until handled.
pub const KindRef = union(enum) {
    tag: std.meta.Tag(Node.Kind),
    mark: InlineMark,
    text_leaf: TextLeafKind,
    markup_leaf: MarkupLeafKind,

    pub fn matches(self: KindRef, kind: Node.Kind) bool {
        return switch (self) {
            .tag => |t| std.meta.activeTag(kind) == t,
            .mark => |m| kind == .inline_mark and kind.inline_mark == m,
            .text_leaf => |k| kind == .text_leaf and kind.text_leaf.kind == k,
            .markup_leaf => |k| kind == .markup_leaf and kind.markup_leaf.kind == k,
        };
    }
};

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

    /// Index into the `AST.attrs` side-table — the type of `Node.attrs`.
    /// Mirrors `Node.Id`'s precedent: documentation-by-naming, not an enum.
    pub const Id = u32;

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

    /// The canonical ASCII spelling — what djot and Markdown both write back
    /// out, and the plain-text projection (`ast/select.zig`'s `textOf`, the
    /// HTML renderer's alt-text extraction). The HTML serializer does NOT use
    /// this: it maps kinds to Unicode glyphs instead (its own `smartPunct`).
    pub fn ascii(self: SmartPunctuationKind) []const u8 {
        return switch (self) {
            .left_single_quote, .right_single_quote => "'",
            .left_double_quote, .right_double_quote => "\"",
            .ellipses => "...",
            .en_dash => "--",
            .em_dash => "---",
        };
    }
};

test {
    _ = Builder;
    _ = reader;
}

// `Kind.kindName` projects THREE namespaces into ONE published vocabulary:
// the `Kind` tags (minus `inline_mark`/`text_leaf`/`markup_leaf`, whose names
// are internal), plus every `InlineMark`, `TextLeafKind`, and `MarkupLeafKind`
// member. `ast/json.zig`'s `"kind"` field and `c_abi.zig`'s
// `twig_node_kind_name` share that flat namespace, and `twig query` selectors
// match against it — so a future family member that collides with a `Kind`
// tag (or with a member of another family) would silently alias two different
// node kinds under one published name. This comptime check makes such a
// collision a compile error naming the duplicate.
test "published kind names are pairwise distinct" {
    comptime {
        // ~60 names -> ~1800 pairwise `eql`s, each a comptime loop; the
        // default quota of 1000 backwards branches is far too small.
        @setEvalBranchQuota(100_000);
        var names: []const [:0]const u8 = &.{};
        for (std.enums.values(std.meta.Tag(Node.Kind))) |tag| switch (tag) {
            // The family tags are internal spellings; `kindName` never
            // publishes them (it publishes the member's name instead).
            .inline_mark, .text_leaf, .markup_leaf => {},
            else => names = names ++ &[_][:0]const u8{@tagName(tag)},
        };
        for (std.enums.values(InlineMark)) |m| names = names ++ &[_][:0]const u8{@tagName(m)};
        for (std.enums.values(TextLeafKind)) |k| names = names ++ &[_][:0]const u8{@tagName(k)};
        for (std.enums.values(MarkupLeafKind)) |k| names = names ++ &[_][:0]const u8{@tagName(k)};

        for (names, 0..) |name, i| {
            for (names[i + 1 ..]) |other| {
                if (std.mem.eql(u8, name, other)) @compileError(
                    "published kind name collision: \"" ++ name ++
                        "\" is spelled by two of Kind/InlineMark/TextLeafKind/MarkupLeafKind",
                );
            }
        }
    }
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
