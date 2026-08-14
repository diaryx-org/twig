//! AST = Abstract Syntax Tree for a parsed document.
//!
//! This is Twig's SHARED node vocabulary: every language module parses into
//! this one node model, so structural operations and printers written against
//! `AST` work regardless of which format produced the tree. The kinds below
//! form a common semantic core (headings, emphasis, lists, tables, ...) plus a
//! small generic-markup escape hatch (`container`, `markup_leaf`,
//! `processing_instruction`) for constructs with no semantic mapping, which is
//! what keeps this vocabulary closed. Djot's tag-by-tag mapping (mirroring
//! djot.js's `src/ast.ts`) is one language's mapping, not this file's
//! definition; anything djot-specific (the reference/footnote side-tables, the
//! block/inline dichotomy) lives in the djot module.
//!
//! Structurally this is the document-format counterpart to fig's config-tree
//! `AST` https://github.com/diaryx-org/fig/blob/main/src/ast/ast.zig`
//! and follows the same conventions: an index-based arena (`Node.Id = u32`, a
//! flat `[]Node`), containers linking their children via
//! `first_child`/`next_sibling` rather than owning a `[]Node.Id` slice per
//! node, and an AST that is fully self-contained — every string a node carries
//! is copied into `owned_strings` at build time, so a finished `AST` never
//! borrows the original source text and printers can take `*const AST` alone.
//!
//! ── This file holds MEANING, not POSITION ──────────────────────────────────
//! Byte offsets are NOT here. A node's `span`/`content_span` live in
//! `src/document.zig`'s id-indexed side-tables, alongside the `source` they
//! address. The rule for which side a new field lands on: a fact belongs in
//! `Document` iff two documents differing only in that fact RENDER
//! IDENTICALLY. A list's `tight` flag fails that test (it elides the `<p>`),
//! so it stays in `Kind`; a bullet's `-`-vs-`*` spelling passes it.
//!
//! ── Where the rationale lives ──────────────────────────────────────────────
//! `AST-KINDS.md` at the repo root. Why the vocabulary is one flat union
//! rather than a nesting, what each of the three classifiers is for, why a
//! given kind exists rather than a cheaper alternative, and which alternatives
//! were tried and rejected. The comments here say what a kind IS and point
//! there for why.

const AST = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("reader.zig");
pub const Builder = @import("builder.zig");

pub const children = reader.children;
pub const ChildIterator = reader.ChildIterator;
pub const tableRows = reader.tableRows;
pub const TableRowIterator = reader.TableRowIterator;
pub const TableRow = reader.TableRow;
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

    // There is deliberately no `Node.eql` — see `AST-KINDS.md`.

    /// The shared kind vocabulary: a semantic core (one kind per djot.js
    /// `ast.ts` tag) plus generic-markup kinds for what XML/HTML can't map
    /// semantically. Container kinds (whose payload is `void` below) still
    /// get children like any other node, via the uniform
    /// `first_child`/`next_sibling` fields on `Node` itself.
    ///
    /// The banners below group the arms for a READER only. They are not a
    /// classification and have been wrong before — `footnote`, `reference`,
    /// `citation` and `substitution` sat under "container children" while
    /// `level` called all four blocks. The three classifiers at the bottom of
    /// this type are the answers; `AST-KINDS.md` has why they are functions
    /// and not a nesting of this union.
    pub const Kind = union(enum) {
        // ── Document root ───────────────────────────────────────────────
        doc,

        // ── Blocks ──────────────────────────────────────────────────────
        para,
        heading: Heading,
        thematic_break,
        /// A heading-implied nesting wrapper; never appears in raw djot
        /// syntax, only synthesized by the parser.
        section,
        code_block: CodeBlock,
        raw_block: RawBlock,
        /// Document-level metadata (front/end matter) as an inert,
        /// self-describing data island — NOT markup, and distinct from both
        /// `code_block` and `raw_block`. `lang` is the config language it is
        /// written in, stored exactly as the fence tag was written; `text` is
        /// the body as written. See `AST-KINDS.md`.
        metadata: Metadata,
        block_quote,
        bullet_list: BulletList,
        ordered_list: OrderedList,
        task_list: TaskList,
        definition_list,
        /// A LINE BLOCK — a run of lines whose BREAKS ARE THE CONTENT. rST
        /// spells it `| ` per line (or `.. line-block::`), AsciiDoc `[verse]`,
        /// docutils' HTML writer `<div class="line-block">`. Verse, addresses,
        /// anything where reflowing the text would destroy it. Read it as "a
        /// list whose items are single lines" — see `structuralChildren`.
        line_block,
        /// Children are a `caption`, a `column` run describing the COLUMN
        /// AXIS, and the rows, in that order — see `structuralChildren`.
        table,

        // ── Container children, and the document-level definitions ───────
        // NOT a classification: `footnote`/`reference`/`citation`/
        // `substitution` below are `level() == .block`. See `Kind`'s doc.
        list_item,
        task_list_item: TaskListItem,
        definition_list_item,
        term,
        definition,
        /// ONE LINE of a `line_block`, holding that line's inlines. `indent`
        /// is the line's leading-whitespace DEPTH, not a column count, and an
        /// EMPTY line is content — the stanza break — not a separator. Both
        /// choices are argued in `AST-KINDS.md`.
        line: Line,
        row: Row,
        cell: Cell,
        /// One column of a table's COLUMN AXIS — a description of a column as
        /// a whole, sitting alongside the rows rather than inside them. rST
        /// spells it `<colspec colwidth="33">`, HTML `<col>` inside a
        /// `<colgroup>`, DocBook `<colspec>` again. A table need not have one
        /// (GFM and djot pipe tables have no column axis at all).
        ///
        /// Carries no payload: the two formats with a column axis disagree
        /// about what a width even is, so it rides in `attrs` as written. See
        /// `AST-KINDS.md`.
        column,
        caption,
        footnote: Footnote,
        reference: Reference,
        /// A CITATION definition — `.. [CIT2002] Deep Thought.` — a footnote
        /// in a second, separate name registry. Its own kind rather than a
        /// `Footnote.namespace` field because the USE side has to split
        /// anyway; see `AST-KINDS.md`. `label` is the name resolution uses.
        citation: Citation,
        /// A SUBSTITUTION definition — rST's `.. |name| image:: pic.png`,
        /// whose body is spliced in wherever `|name|` appears. The one named
        /// definition whose body is INLINE (`footnote` and `citation` hold
        /// blocks, `reference` holds nothing), so it is block-level with
        /// inline children — `para`'s combination.
        ///
        /// Named for the definition, not the use, to match `footnote`.
        substitution: Substitution,

        // ── Inlines ───────────────────────────────────────────────────────
        str: []const u8,
        soft_break,
        hard_break,
        non_breaking_space,
        /// A DELIMITED INLINE TEXT LEAF — a `:name:` shortcode, a `` `code` ``
        /// span, `$math$`, a `<https://…>` autolink, a `[^label]` footnote
        /// reference. Opaque text plus the marker that frames it; which one it
        /// is rides in the payload. See `TextLeafKind`. (`str` is the
        /// UNdelimited case and stays its own arm — `AST-KINDS.md` has why.)
        text_leaf: TextLeaf,
        raw_inline: RawInline,
        /// A `'`/`'`/`"`/`"`/`...`/`--`/`---` run djot recognized as smart
        /// punctuation. The payload is the bare kind, with no stored spelling:
        /// the source form is canonical per kind, so the text is derived on
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
        /// One kind, not the four (`div`, `span`, `directive`, `element`) it
        /// replaced — and the unification is structural, not semantic: a
        /// container's NAME and its CLASS stay distinct, so djot's `::: note`
        /// (name `"div"`, `class=note` in `attrs`) and Markdown's `:::note`
        /// (name `"note"`, no attrs) still parse to different nodes. See
        /// `AST-KINDS.md`.
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
        pub const BulletList = struct { tight: bool };
        pub const OrderedList = struct { numbering: ListNumbering, tight: bool, start: ?u32 };
        pub const TaskList = struct { tight: bool };
        pub const TaskListItem = struct { checked: bool };
        pub const Row = struct { head: bool };
        /// `indent` is the line's leading-whitespace DEPTH within its block, not
        /// a column count — see `Kind.line`. Zero is flush-left and by far the
        /// common case, so it defaults.
        pub const Line = struct { indent: u32 = 0 };
        /// `colspan`/`rowspan` are the cell's GRID EXTENT — how many columns and
        /// rows it occupies — and they are always ≥ 1, `1` meaning the ordinary
        /// one-square cell. They are semantic, not spelling: `<td colspan=2>`
        /// and `<td>` are different documents, so they live here rather than in
        /// `Document`'s side tables (contrast a bullet's `-` vs `*`).
        ///
        /// HTML's `colspan=0`/`rowspan=0` normalize to `1` here and round-trip
        /// off `attrs` instead — see `AST-KINDS.md`.
        pub const Cell = struct {
            head: bool,
            alignment: Alignment,
            colspan: u32 = 1,
            rowspan: u32 = 1,
        };
        pub const Footnote = struct { label: []const u8 };
        pub const Reference = struct { label: []const u8, destination: []const u8 };
        /// Same shape as `Footnote` on purpose, and a distinct type rather
        /// than a reuse — so a field added for one cannot silently arrive on
        /// the other. Contrast `Link`, which `image` shares deliberately.
        pub const Citation = struct { label: []const u8 };
        pub const Substitution = struct { label: []const u8 };
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
            /// tag and the stylesheet, not of the parse. `level` reports
            /// `.neither` for such a node rather than guessing.
            form: ?Form = null,
            /// The directive ARGUMENT: rST's `.. image:: picture.png` puts
            /// `picture.png` here. Positional, so it is neither an attribute
            /// (`attrs` holds `:width: 50%`-style options) nor a child (the
            /// children are the body). `null` for every format that has no
            /// argument position — which today is all of them except rST.
            argument: ?[]const u8 = null,
        };

        // ── The three classifiers ────────────────────────────────────────
        // `Kind` names WHAT a node is. Three further questions get asked of
        // it constantly — where it sits in the block/inline hierarchy, what
        // it may contain, and which children its own model gives meaning to.
        // `level`, `contentModel`, and `structuralChildren` are the canonical
        // answers. All three switch exhaustively, so A NEW KIND CANNOT BE
        // ADDED WITHOUT DECLARING ALL THREE — the property the hand-written
        // per-consumer lists they replaced never had. `AST-KINDS.md` has the
        // history of those lists and why the grouping is functions rather
        // than a nesting of this union.

        /// Where a kind sits in the document hierarchy.
        ///
        /// `neither` is not a shrug: it is the honest answer for the `doc`
        /// root, for a structural child (which only ever appears inside its
        /// own parent, never where a paragraph could go — djot.js's `isBlock`
        /// rule), and for generic markup (whose level is a property of the
        /// stylesheet, not the parse).
        pub const Level = enum { block, @"inline", neither };

        /// What a kind may hold. The distinction `blocks`/`inlines` vs `text`
        /// is the load-bearing one: a `text` node's `content_span` addresses
        /// OPAQUE BYTES, not a child region, so `insertChild` must refuse it
        /// even though it has a `content_span` (`replaceContent` still
        /// works). See `Node.content_span`.
        ///
        /// This is what a kind may CONTAIN, not what a given node DOES
        /// contain — a `.blocks` parent holding inlines is the tight,
        /// `<p>`-elided case. Every caller reads it as a PERMISSION ("may
        /// children go here at all"), which is the only reading the corpora
        /// support; see `AST-KINDS.md`.
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
                .line_block,
                .table,
                .footnote,
                .reference,
                .citation,
                .substitution,
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

                // The root, the structural children (each named by exactly one
                // parent's `structuralChildren`), and generic markup — see
                // `Level`.
                .doc,
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
                // `.text` here means DERIVED text: its payload is a bare kind,
                // with no stored string to point a `content_span` at. It
                // stays out of `.empty` because `c_abi.zig`'s `kindText` is
                // documented as extracting exactly the `holdsOpaqueText` set,
                // and keeps reporting the `ascii()` spelling.
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
                // A column DESCRIBES a column; the cells that sit in it are
                // children of the rows, not of it.
                .column,
                => .empty,

                .doc,
                .section,
                .block_quote,
                .bullet_list,
                .ordered_list,
                .task_list,
                .definition_list,
                .line_block,
                .table,
                .list_item,
                .task_list_item,
                .definition_list_item,
                .definition,
                .row,
                .cell,
                .footnote,
                .citation,
                => .blocks,

                .para,
                .heading,
                .term,
                // A line holds inlines like a paragraph does; what it does not
                // hold is a soft break, since the break IS the line boundary.
                .line,
                .caption,
                .link,
                .image,
                .inline_mark,
                .substitution,
                => .inlines,

                // A fenced container holds blocks; the inline and
                // one-line-leaf forms hold the label's inlines. An
                // UNCLASSIFIED container answers `blocks` as the permissive
                // one, since only `text` answers no.
                .container => |c| if (c.form) |f| switch (f) {
                    .block_fenced => .blocks,
                    .block_leaf, .inline_text => .inlines,
                } else .blocks,
            };
        }

        /// The generic-markup kinds, which may appear inside ANY container
        /// regardless of its structural vocabulary. An HTML comment goes
        /// anywhere; so does an XML processing instruction; and a `container`
        /// is the escape hatch every format falls back to for a construct
        /// with no semantic mapping — rST's `classifier` inside a
        /// `definition_list_item`, its `system_message` inside a
        /// `line_block`, HTML's `colgroup` inside a `table`. All three are
        /// `.neither` in `level` for the same reason.
        pub const generic_markup = [_]std.meta.Tag(Kind){
            .container,
            .markup_leaf,
            .processing_instruction,
        };

        /// The closed set of child kinds a parent gives STRUCTURAL meaning to,
        /// or `null` when its children are constrained only by `contentModel`.
        ///
        /// This is the third classifier, alongside `level` and `contentModel`,
        /// and it exists for the same reason they do: these facts were prose
        /// ("children are `line` nodes and nothing else", "Children:
        /// `[Caption, Column…, Row, Row, ...]`") that nothing checked, on
        /// kinds whose whole point is that their children are not free-form.
        /// A list holds items; a row holds cells; the alternative spellings
        /// are not documents, they are bugs.
        ///
        /// Two properties, both deliberate. It switches exhaustively, so a new
        /// kind must declare whether it constrains its children. And the sets
        /// are what six parsers and every vendored corpus ACTUALLY produce —
        /// `generic_markup` is admitted on top of each one (see
        /// `admitsChild`) because the corpora put a `container` in three of
        /// these positions, which the prose these sets replace did not say.
        pub fn structuralChildren(self: Kind) ?[]const std.meta.Tag(Kind) {
            return switch (self) {
                .bullet_list, .ordered_list => &.{.list_item},
                .task_list => &.{.task_list_item},
                .definition_list => &.{.definition_list_item},
                .definition_list_item => &.{ .term, .definition },
                // A list whose items are single lines, and the reason a line
                // block is not a paragraph full of breaks.
                .line_block => &.{.line},
                // `caption` first when present, then the `column` run when
                // present, then the rows — an ORDER this set does not encode,
                // because no consumer reads one and every producer writes it.
                .table => &.{ .caption, .column, .row },
                .row => &.{.cell},

                // Everything else: `contentModel` is the whole answer. Spelled
                // out rather than `else`-d, which is what makes adding a kind
                // a decision instead of a default.
                .doc,
                .para,
                .heading,
                .thematic_break,
                .section,
                .code_block,
                .raw_block,
                .metadata,
                .block_quote,
                .list_item,
                .task_list_item,
                .term,
                .definition,
                .line,
                .cell,
                .column,
                .caption,
                .footnote,
                .reference,
                .citation,
                .substitution,
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
                .container,
                .markup_leaf,
                .processing_instruction,
                => null,
            };
        }

        /// Whether `child` may sit directly inside `parent` — the permission
        /// `contentModel` and `structuralChildren` answer together.
        ///
        /// It says NO in exactly two places, and is permissive everywhere
        /// else. An opaque-text or childless kind takes nothing. A kind with
        /// a closed vocabulary takes that set plus `generic_markup`. The rest
        /// answer `true`, which is not laziness: a `.blocks` parent
        /// legitimately holds inlines (the tight, `<p>`-elided case that
        /// `contentModel`'s doc describes), and a `.inlines` parent holds an
        /// rST `reference` — a `.block`-level definition node — so the level
        /// axis does not constrain a general parent the way it looks like it
        /// should.
        ///
        /// The intended caller is an EDIT (`insertChild` and friends) asking
        /// where a node may be placed. It is not a claim about what a parser
        /// may produce: a forgiving parser puts a stray HTML `<tr>` straight
        /// under `doc` when CommonMark's blank-line rule splits the table
        /// across two HTML blocks (spec examples 190/191), and that parse is
        /// correct.
        pub fn admitsChild(parent: Kind, child: Kind) bool {
            switch (parent.contentModel()) {
                .text, .empty => return false,
                .blocks, .inlines => {},
            }
            const tag = std.meta.activeTag(child);
            const set = parent.structuralChildren() orelse return true;
            for (set) |t| if (t == tag) return true;
            for (generic_markup) |t| if (t == tag) return true;
            return false;
        }

        /// True for kinds that carry a TEXT/opaque payload rather than child
        /// nodes — the same set `c_abi.zig`'s `kindText` extracts. A thin
        /// reading of `contentModel`, kept as its own name because that is
        /// what the callers mean and because it is public API.
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
                .line_block,
                .table,
                .list_item,
                .definition_list_item,
                .term,
                .definition,
                .column,
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
                .bullet_list => |v| v.tight == other.bullet_list.tight,
                .ordered_list => |v| v.numbering == other.ordered_list.numbering and
                    v.tight == other.ordered_list.tight and
                    v.start == other.ordered_list.start,
                .task_list => |v| v.tight == other.task_list.tight,
                .task_list_item => |v| v.checked == other.task_list_item.checked,
                .line => |v| v.indent == other.line.indent,
                .row => |v| v.head == other.row.head,
                .cell => |v| v.head == other.cell.head and
                    v.alignment == other.cell.alignment and
                    v.colspan == other.cell.colspan and
                    v.rowspan == other.cell.rowspan,
                .footnote => |v| eqlStr(v.label, other.footnote.label),
                .citation => |v| eqlStr(v.label, other.citation.label),
                .substitution => |v| eqlStr(v.label, other.substitution.label),
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
/// It compares the two node ARRAYS directly rather than walking from the root,
/// which is legal because `ast/compact.zig` canonicalizes the arena at the end
/// of every parse, and necessary because unattached definition nodes carry
/// meaning a walk would never reach. `AST-KINDS.md` has both arguments.
///
/// Attributes are compared by VALUE rather than by index: `Node.attrs` points
/// into a side-table that compaction deliberately does not renumber, so two
/// equivalent parses can carry different indices for identical attributes.
pub fn eql(self: AST, other: AST) bool {
    if (self.root != other.root) return false;
    if (self.nodes.len != other.nodes.len) return false;
    for (self.nodes, other.nodes, 0..) |a, b, i| {
        if (a.id != b.id) return false;
        if (a.first_child != b.first_child) return false;
        if (a.next_sibling != b.next_sibling) return false;
        if (!a.kind.eql(b.kind)) return false;
        const id: Node.Id = @intCast(i);
        if (!attrsEql(self.attrsOf(id), other.attrsOf(id))) return false;
    }
    return true;
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
/// A nested enum and not nine union arms, because every generic consumer
/// treated all nine identically and only the serializers tell them apart —
/// the test for nesting a family, argued in `AST-KINDS.md` along with the two
/// families below. Exhaustiveness is NOT lost: a serializer still switches
/// over `InlineMark` with every arm spelled, so a tenth mark still fails those
/// builds. Nor is the published vocabulary affected — `kindName` projects the
/// mark's name up, so `ast/json.zig` still emits `"kind": "emph"`.
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
/// The same pattern as `InlineMark`. `raw_inline` is excluded because its
/// payload is `{format, text}`, a second field the members here don't have;
/// `str` is excluded for the opposite reason (see `Kind.text_leaf`).
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
    /// rST's `[CIT2002]_` — a use of a `Kind.citation`, resolved in the
    /// citation registry rather than the footnote one. Payload is the label as
    /// WRITTEN (`CIT1`), not the normalized name docutils resolves by (`cit1`);
    /// the normalized form is derivable and the written one is not.
    citation_reference,
    /// rST's `|name|` — a use of a `Kind.substitution`. Payload is the name as
    /// written, same rule as `citation_reference`.
    substitution_reference,
};

/// Which generic-markup leaf a `Kind.markup_leaf` is — the same pattern as
/// `InlineMark` and `TextLeafKind`, in the generic-markup corner. Only the
/// delimiters differ (`<!-- … -->`, `<!DOCTYPE …>`, `<![CDATA[…]]>`).
/// `processing_instruction` is excluded for the same reason `raw_inline`
/// stayed out of `TextLeafKind`: its payload has a second field.
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
    /// A `container` carrying exactly this NAME — the one payload a `tag`
    /// match is too coarse for. Every other kind's identity is its tag (a
    /// `heading` that comes back is a heading), but a container's identity is
    /// its name, and a target can return the tag while dropping the name:
    /// djot has only classes to hold a name in, so a Markdown `:::note`
    /// arrives as an anonymous div classed `note`. Matching on the tag alone
    /// scored that as a survival and let `diagnostics.zig`'s table call it
    /// `faithful` for as long as the name was being deleted outright.
    container_named: []const u8,

    pub fn matches(self: KindRef, kind: Node.Kind) bool {
        return switch (self) {
            .tag => |t| std.meta.activeTag(kind) == t,
            .mark => |m| kind == .inline_mark and kind.inline_mark == m,
            .text_leaf => |k| kind == .text_leaf and kind.text_leaf.kind == k,
            .markup_leaf => |k| kind == .markup_leaf and kind.markup_leaf.kind == k,
            .container_named => |n| kind == .container and std.mem.eql(u8, kind.container.name, n),
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
/// `classes`/`id`/`keyvals` fields, because djot renders attributes back
/// interleaved exactly as written. `class` and `id` are ordinary keys here;
/// use `get`/`find` to look them up. See `AST-KINDS.md`.
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
/// `::name` leaf and a `:::name` fence. Everything else about spelling a
/// container back is format-uniform and belongs in `syntax.zig`.
///
/// Also carries the block/inline classification that `div` and `span` used to
/// encode by being separate kinds, which is what `level` reads:
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

/// How an ordered list COUNTS (`<ol type="a">` renders differently), which is
/// why it lives on `Kind`. How its markers are PUNCTUATED (`1.` vs `1)` vs
/// `(1)`) renders identically and is therefore spelling — see
/// `Document.Spelling.ordered_delim`.
pub const ListNumbering = enum { decimal, lower_alpha, upper_alpha, lower_roman, upper_roman };

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

// `kindName` projects THREE namespaces into ONE flat published vocabulary
// (see `AST-KINDS.md`), which `ast/json.zig`, `c_abi.zig`, and `twig query`
// selectors all share. A future family member colliding with a `Kind` tag, or
// with a member of another family, would silently alias two different node
// kinds under one published name. This makes that a compile error naming the
// duplicate.
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

// The corpus-wide version of this lives in `ast/containment_test.zig`; these
// are the three shapes of the answer, spelled locally so a reader of `Kind`
// can see what the classifier claims without running six parsers.
test "admitsChild: a closed vocabulary takes its own set plus generic markup" {
    const testing = std.testing;
    const list: Node.Kind = .{ .bullet_list = .{ .tight = true } };
    try testing.expect(list.admitsChild(.list_item));
    try testing.expect(!list.admitsChild(.para));
    try testing.expect(!list.admitsChild(.{ .task_list_item = .{ .checked = false } }));
    // rST hangs a `classifier` off a `definition_list_item`, docutils hangs a
    // `system_message` off a `line_block`, HTML a `colgroup` off a `table`.
    try testing.expect(list.admitsChild(.{ .container = .{ .name = "note" } }));
    try testing.expect(list.admitsChild(.{ .markup_leaf = .{ .kind = .comment, .text = "x" } }));
}

test "admitsChild: an opaque-text or childless kind takes nothing" {
    const testing = std.testing;
    const code: Node.Kind = .{ .code_block = .{ .lang = null, .text = "x" } };
    try testing.expect(!code.admitsChild(.{ .str = "x" }));
    // The exact pair `languages/html/parser.zig` used to build from
    // `<pre><code>x</code></pre>`.
    try testing.expect(!code.admitsChild(.{ .text_leaf = .{ .kind = .verbatim, .text = "x" } }));
    const rule: Node.Kind = .thematic_break;
    try testing.expect(!rule.admitsChild(.{ .str = "x" }));
}

test "admitsChild: a general parent is permissive on the level axis" {
    const testing = std.testing;
    // A `.blocks` parent holding inlines is the tight, `<p>`-elided case; a
    // `.inlines` parent holding a `.block`-level `reference` is what rST does.
    const item: Node.Kind = .list_item;
    const para: Node.Kind = .para;
    try testing.expect(item.admitsChild(.{ .str = "x" }));
    try testing.expect(para.admitsChild(.{
        .reference = .{ .label = "r", .destination = "/x" },
    }));
}

test "structuralChildren: every constrained kind's set is reachable" {
    const testing = std.testing;
    // The parents that constrain, and the sole parent each structural child
    // belongs to — the containment half of what `Level.neither` means.
    const table: Node.Kind = .table;
    const line_block: Node.Kind = .line_block;
    const doc: Node.Kind = .doc;
    try testing.expectEqualSlices(
        std.meta.Tag(Node.Kind),
        &.{ .caption, .column, .row },
        table.structuralChildren().?,
    );
    try testing.expectEqualSlices(
        std.meta.Tag(Node.Kind),
        &.{.line},
        line_block.structuralChildren().?,
    );
    try testing.expectEqual(@as(?[]const std.meta.Tag(Node.Kind), null), doc.structuralChildren());
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
