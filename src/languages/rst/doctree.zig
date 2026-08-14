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
// that would need a normalization step, or a defaulted field the doctree cannot
// see, stays generic and is counted as such.
//
// That rule used to also bar any mapping that needed KNOWLEDGE OF AN ANCESTOR,
// and the table subtree is what showed the bar was in the wrong place. What the
// rule protects is EXACT INVERSION, and a parent is available on both sides —
// `closeTop` holds the enclosing frame, `writeNode` recurses through the parent
// on its way down — so a mapping that reads one inverts as exactly as any
// other. One does: `title` is a table's caption or a section's heading
// depending on where it sits, and `caption`/`title` is the inverse pair on the
// way out. It is checked by the same corpus identity as everything else. What
// remains barred is an ancestor mapping that cannot be inverted, which is a
// special case of the real rule rather than a rule of its own.
//
// A DEEPER ancestor is still out of reach, and `entry` is the case that shows
// where the line falls: a header cell is a cell in a header row, which is two
// levels up (`thead > row > entry`) and not yet read when the entry closes. It
// is handled by rewriting the cells when the `thead` dissolves, not by widening
// this argument — see `markHeadRows`.
//
// Two families are deliberately still generic, and their absence is the finding
// rather than an oversight:
//
//   - `title` OUTSIDE a table (83 of 101), under `section`/`topic`/`sidebar`/
//     `admonition`. Twig spells it `heading`, which carries a `level`; the
//     doctree does not write one, so decoding would have to synthesize it from
//     section nesting depth and encoding would have to recompute it — and under
//     `topic`/`sidebar` there is no such depth to synthesize from. The 18 under
//     a `table` are a different construct with a different answer; see
//     `decodeKind`.
//   - What is LEFT of the hyperlink cluster, which is now the two `target`
//     shapes and nothing else. `reference`, the external `target` and
//     `footnote` were mapped first because twig already had their kinds;
//     `citation`/`citation_reference` and `substitution_definition`/
//     `substitution_reference` are mapped below onto vocabulary added FOR them,
//     which was gated until `src/diagnostics.zig` existed to say what a
//     conversion would lose (see `Kind.citation`'s doc for why each became its
//     own kind rather than a namespace field). The two that remain are both
//     `target`, and neither is waiting on vocabulary:
//
//       The indirect `target` (14) — an alias naming another definition rather
//       than a URI, which `Kind.Reference` has no field for.
//
//       The internal `target` (30) — an anchor; see `decodeTarget`.

// ── the table subtree ──────────────────────────────────────────────────────
//
// The one family that could not be mapped a tag at a time, and the corpus says
// so numerically: `colspec` appears in ALL 65 tables, so mapping
// `table`/`row`/`entry` while leaving `colspec` generic unlocks exactly ZERO
// additional cases. Mapped together they unlock 38, and 51 with `title`.
//
// docutils' shape is `table -> title?, tgroup`, `tgroup cols=N -> colspec×N,
// thead?, tbody`, and twig's is `table -> caption?, column*, row*`. Three
// elements have no twig node and are DISSOLVED — they contribute their children
// to their parent and vanish (see `dissolves`):
//
//   - `tgroup` carries only `cols`, which is the number of `colspec` children
//     in all 65 tables without exception. Nothing to store, so nothing is:
//     `encode` counts the columns back.
//   - `thead`/`tbody` are docutils' way of saying which rows are header rows,
//     which twig says with `row.head`. Exactly HTML's `<thead>`/`<tbody>`
//     problem, and it gets HTML's answer — `html/parser.zig`'s
//     `flattenRowGroups`. `thead` never follows `tbody` in the corpus, so the
//     flat `head`-flagged run re-groups without ambiguity.
//
// What each row group knows has to reach the rows before the wrapper is gone,
// so dissolving `thead` REWRITES the rows it is dissolving (`markHeadRows`).
// That is the one place this decoder edits a node it already built, and it is
// safe because a doctree is written parents-last: a `thead` closes only after
// every row inside it has closed.
//
// `entry` -> `cell` is the mapping that needs its parent, and only for `head`:
// docutils writes nothing on the entry itself, so a header cell is one whose
// row is a header row. `colspec`'s `stub` — an entire column of header cells —
// is deliberately NOT folded in; see `Kind.column`.

// ── the line-block subtree ─────────────────────────────────────────────────
//
// The second family that dissolves, and for a reason worth stating separately
// from the table's: a NESTED `<line_block>` is not a construct, it is docutils'
// encoding of one number. An indented run of lines becomes a child
// `<line_block>`, recursively, by grouping every line indented past the current
// group's minimum — so the corpus's 30 blocks are 20 real ones and 10 wrappers,
// and its deepest case reaches three levels for a single stanza. `Kind.line`'s
// doc has the argument for storing the depth on the line instead, including why
// the tree is a worse record of the source than the number is.
//
// Dissolving is safe by exactly the rule `dissolves` states: none of the 10
// nested blocks carries an attribute (the only attributed block in the corpus is
// a top-level one, from `.. line-block:: :class: linear`), so nothing is lost by
// splicing them away. What the wrapper MEANT — one more level of indent for
// everything inside it — is moved onto the lines by `bumpLineIndent`, the same
// move `markHeadRows` makes for `thead` and well-founded for the same reason:
// pformat writes a parent after its children, so those lines are finished nodes.
//
// `writeLineBlock` rebuilds the nesting on the way out, opening a wrapper when
// the indent rises and closing one when it falls, which inverts this exactly —
// including the two-at-once jumps that appear when a group's minimum indent is
// itself indented.

// ── the option-list subtree ────────────────────────────────────────────────
//
// An OPTION LIST documents a program's command-line options — `-b file`, `-a,
// --aaaa, /A`, each with a description — and docutils gives it seven elements.
// Four of them ARE twig's definition-list four, exactly:
//
//     option_list       -> definition_list         (15)
//     option_list_item  -> definition_list_item    (48)
//     option_group      -> term                    (48)
//     description       -> definition              (48)
//
// so this family is ABSORBED rather than given vocabulary of its own: 159
// instances mapped for no new `Kind`, no new fidelity row, and no new answer
// owed by three serializers. The corpus supports the shape without exception —
// every `option_list_item` sits in an `option_list` and holds exactly one group
// and one description, and no group or description is empty.
//
// The remaining three are the OPTION PARSE — `option` (54) inside a group, and
// `option_string` (54) plus `option_argument` (38) inside that, which is where
// docutils splits `-b file` into a string and an argument carrying the
// `delimiter` (`" "`, `"="`) it was written with. Those stay GENERIC inside the
// term, and that is lossless rather than a compromise: a generic container
// names its own element, so the split and the delimiter round-trip verbatim
// without this codec learning to spell them.
//
// What the absorption costs is the one thing `encodeTag` normally gets for
// free. See `isOptionList`.

/// The elements that produce no node of their own. Their children are spliced
/// into their parent's child list, and their attributes must therefore be either
/// derivable (`tgroup`'s `cols`), moved onto the children (`thead`'s
/// header-ness, a nested `line_block`'s indent level), or absent. An element
/// with an attribute that is none of those cannot dissolve, because `encode`
/// would have nowhere to read it back from.
///
/// `parent` is what makes `line_block` conditional: the OUTERMOST one is the
/// construct and stays, and only the wrappers inside it dissolve.
fn dissolves(tag: Tag, parent: ?Tag) bool {
    return switch (tag) {
        .tgroup, .thead, .tbody => true,
        .line_block => parent == .line_block,
        else => false,
    };
}

/// The twig `Kind` `tag` decodes to, or `null` for the generic `container`
/// fallback. `children` are the already-built child ids, needed by the three
/// text-carrying mappings — see `soleStr`; `attrs` are the element's own,
/// borrowed from the input and safe to hand to the builder, which dupes every
/// payload string (`Builder.dupeKind`). `parent` is the enclosing element's
/// tag, `null` at the root — read by the one mapping whose twig kind depends on
/// where the element sits (`title`).
fn decodeKind(
    b: *const AST.Builder,
    tag: Tag,
    parent: ?Tag,
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
        // `enumtype` and `start` are READINGS, the same arrangement `refuri` has
        // for a `link`: all four of docutils' attributes (`enumtype`, `prefix`,
        // `suffix`, `start`) stay in `attrs` and are what `encode` writes back
        // from. Only two of them have a twig payload — `prefix`/`suffix` have no
        // `Kind.OrderedList` field at all, which is exactly why the attributes
        // must remain the record rather than the payload.
        //
        // An unrecognized or absent `enumtype` decodes to `null`, leaving the
        // list a generic `container` that round-trips as itself, rather than
        // guessing `.decimal`: docutils writes the attribute on every one of the
        // corpus's 46 enumerated lists, so a missing one is a doctree this codec
        // has no reading for, not a default.
        .enumerated_list => if (decodeNumbering(attrs)) |n| .{ .ordered_list = .{
            .numbering = n,
            .tight = false,
            .start = decodeStart(attrs),
        } } else null,
        .list_item => .list_item,
        .definition_list => .definition_list,
        .definition_list_item => .definition_list_item,
        .term => .term,
        .definition => .definition,
        .section => .section,
        .transition => .thematic_break,

        // ── the table subtree ──────────────────────────────────────────────
        // See the block comment above for why these move as a unit.
        .table => .table,
        .colspec => .column,
        .row => .{ .row = .{ .head = false } },
        // `head` starts false and is NOT decided here, even though a header
        // cell is exactly a cell in a header row. An entry's parent is always
        // `row` — never `thead`, which is the row's parent — so the answer is
        // two levels up, and at the moment an entry closes that `thead` has not
        // been read yet (pformat writes parents last). `markHeadRows` sets this
        // flag and the row's together when the `thead` finally dissolves, which
        // is the first point either can be known.
        //
        // `alignment` has no doctree spelling at all: docutils puts alignment
        // on the TABLE (`align="left"`, 3 in the corpus), never on a cell, so
        // this is pinned to `.default` and `encode` never writes it — the same
        // arrangement `bullet_list.tight` has, and honest for the same reason.
        //
        // `morecols`/`morerows` are the extent MINUS ONE (docutils counts the
        // ADDITIONAL cells spanned), so they convert here. They also stay in
        // `attrs` untouched, which is what `encode` writes back from — the
        // payload is a READING, exactly as `refuri` is for a `link`.
        .entry => .{ .cell = .{
            .head = false,
            .alignment = .default,
            .colspan = spanExtent(attrs, "morecols"),
            .rowspan = spanExtent(attrs, "morerows"),
        } },
        // docutils spells a table's caption `<title>`, the same element it uses
        // for a section heading — one word for two constructs, told apart by
        // where it sits. Under a `table` it is twig's `caption`, which is
        // exactly what `table`'s content model expects to lead with. Everywhere
        // else it stays generic; see the decode-table comment.
        // ── the option-list subtree ────────────────────────────────────────
        // Absorbed into the definition-list four; see the block comment above.
        // The three below the list are gated on their parent even though
        // docutils puts them nowhere else, because the gate is what makes the
        // inversion exact: `encodeTag` decides these four by CONTENT, so a
        // `<description>` appearing outside an option list would come back a
        // `<definition>`. Gated, it stays generic and round-trips as itself.
        .option_list => .definition_list,
        .option_list_item => if (parent == .option_list) .definition_list_item else null,
        .option_group => if (parent == .option_list_item) .term else null,
        .description => if (parent == .option_list_item) .definition else null,

        // ── the line-block subtree ─────────────────────────────────────────
        // Only the outermost block reaches here; `dissolves` splices the nested
        // wrappers away and `bumpLineIndent` moves what they meant onto the
        // lines. See the block comment above.
        .line_block => .line_block,
        // Every line decodes flush-left and is bumped afterwards, once per
        // wrapper it turns out to be inside. It cannot be decided here: a line
        // closes before the wrappers above it do, and the count is exactly how
        // many of those there will be.
        .line => .{ .line = .{} },

        .title => if (parent == .table) .caption else null,
        // And the reverse spelling: docutils ALSO has a `<caption>`, which is a
        // FIGURE's caption and never a table's. Same twig kind, so the two
        // docutils elements converge here and `encodeTag` tells them apart
        // again by parent. All 10 in the corpus hold text and nothing else,
        // which is `caption`'s `.inlines` content model exactly.
        .caption => .caption,

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

        // A citation definition — a footnote in rST's second name registry, and
        // read exactly the same way: the name is `names`, and the `<label>`
        // child stays a generic node. The corpus makes the reason plain here in
        // a way it could not for footnotes: for `.. [TARGET] …` docutils writes
        // `names="target"` with `<label>TARGET`, so the two are the NORMALIZED
        // and the WRITTEN form of the name, not the same string twice.
        .citation => .{ .citation = .{ .label = definitionName(attrs) } },

        // A substitution definition. Same `names` rule again; the body is the
        // element's inline children, which `Kind.substitution` holds directly.
        .substitution_definition => .{ .substitution = .{ .label = definitionName(attrs) } },

        // The two USES. Payload is the label as WRITTEN, which is the children's
        // text, not the `refname` attribute — docutils normalizes `refname`
        // (`[CIT1]_` gives `refname="cit1"` over a `CIT1` body) and the written
        // form is the one that cannot be recovered from the other. `refname`
        // itself rides in `attrs` and round-trips there verbatim, so nothing has
        // to re-derive it and no normalization step enters this codec — the same
        // division `.reference => .link` makes for `name`/`anonymous`.
        //
        // Both absorb a lone `str` child, so they are conditional for the reason
        // the three text-carrying mappings below are. The condition bites in one
        // real place: an auto-numbered footnote reference has NO children (a
        // transform supplies the number), and a substitution reference may carry
        // a multi-line name — neither is a lone `str`, and both stay generic
        // rather than being decoded to an empty or re-joined payload.
        .citation_reference => if (soleStr(b, children)) |t| .{ .text_leaf = .{ .kind = .citation_reference, .text = t } } else null,
        .substitution_reference => if (soleStr(b, children)) |t| .{ .text_leaf = .{ .kind = .substitution_reference, .text = t } } else null,

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

/// What an encoding node is told about where it sits, threaded down by
/// `writeNode`.
///
/// `parent` is the enclosing node's kind, mirroring `decodeKind`'s argument and
/// inverting the same two mappings. `option_list` is the answer `isOptionList`
/// reached at the enclosing `definition_list`, carried down rather than
/// re-derived — see there for why the parent kind alone cannot supply it.
const Where = struct {
    parent: ?Node.Kind = null,
    option_list: bool = false,
};

/// Is this `definition_list` really an rST OPTION LIST?
///
/// The one mapping in this table that a node plus its parent cannot invert, and
/// structurally so rather than by accident: docutils' four option-list elements
/// are twig's four definition-list kinds EXACTLY, so at every level the parent
/// kind is identical either way. A `definition_list_item` sits in a
/// `definition_list` whichever construct it came from.
///
/// The CONTENT does tell them apart. `<option>` appears nowhere else in
/// docutils' vocabulary, so a term holding one is an option group and the list
/// around it is an option list. That is a total discriminator rather than a
/// heuristic: all 54 `option`s in the corpus sit inside one of the 48 groups,
/// and no group is empty.
///
/// Asked once, at the LIST, and inherited by everything under it through
/// `Where` — a list, its items and their terms must all agree, and deriving the
/// answer separately at each level is how they would come to disagree.
fn isOptionList(ast: *const AST, id: Node.Id) bool {
    var items = ast.children(id);
    while (items.next()) |item| {
        if (ast.nodes[item.id].kind != .definition_list_item) continue;
        var parts = ast.children(item.id);
        while (parts.next()) |part| {
            if (ast.nodes[part.id].kind != .term) continue;
            var opts = ast.children(part.id);
            while (opts.next()) |opt| switch (ast.nodes[opt.id].kind) {
                .container => |c| if (std.mem.eql(u8, c.name, Tag.option.name())) return true,
                else => {},
            };
        }
    }
    return false;
}

/// The docutils element `kind` encodes back to, or `null` when the kind has no
/// doctree spelling at all. Every arm is spelled so that a new `Kind` variant
/// fails this build until it declares one — the same exhaustiveness property
/// `Kind.level`/`contentModel` have.
fn encodeTag(kind: Node.Kind, where: Where) ?Tag {
    const parent = where.parent;
    return switch (kind) {
        .doc => .document,
        .para => .paragraph,
        .block_quote => .block_quote,
        .bullet_list => .bullet_list,
        .ordered_list => .enumerated_list,
        .list_item => .list_item,
        // The definition-list four double as the option-list four; which
        // construct this is was settled at the list by `isOptionList` and rides
        // down in `Where`, so all four read the same flag and cannot disagree.
        .definition_list => if (where.option_list) .option_list else .definition_list,
        .definition_list_item => if (where.option_list) .option_list_item else .definition_list_item,
        .term => if (where.option_list) .option_group else .term,
        .definition => if (where.option_list) .description else .definition,
        // The nested wrappers `decode` dissolved have no arm because they have
        // no twig node — `writeLineBlock` synthesizes them from each line's
        // `indent`, as `writeTable` does for `tgroup`/`thead`/`tbody`.
        .line_block => .line_block,
        .line => .line,
        .section => .section,
        .thematic_break => .transition,
        .code_block => .literal_block,

        // The table subtree. `tgroup`/`thead`/`tbody` have no arm because they
        // have no twig node — `writeTable` synthesizes all three on the way
        // out, which is where the shape difference is reconciled.
        .table => .table,
        .column => .colspec,
        .row => .row,
        .cell => .entry,
        // The inverse of the `title`/`caption` split: a caption inside a table
        // is docutils' `<title>`, and one inside a `figure` (which is a generic
        // `container` here, since no rST directive is parsed yet) is its own
        // `<caption>`. The parent decides, in both directions.
        .caption => if (parent != null and parent.? == .table) .title else .caption,
        // The two hyperlink arms cross names, which is confusing exactly once:
        // docutils' `<reference>` is the USE and its `<target>` is the
        // DEFINITION, while twig's `link` is the use and its `reference` is the
        // definition. Same two constructs, opposite words.
        .link => .reference,
        .reference => .target,
        .footnote => .footnote,
        .citation => .citation,
        .substitution => .substitution_definition,
        .inline_mark => |m| switch (m) {
            .emph => .emphasis,
            .strong => .strong,
            else => null,
        },
        .text_leaf => |l| switch (l.kind) {
            .verbatim => .literal,
            .citation_reference => .citation_reference,
            .substitution_reference => .substitution_reference,
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
        .task_list,
        .task_list_item,
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

/// docutils' `enumtype` as twig's `ListNumbering`. The five names line up one
/// for one, which is why `enumerated_list` needs no vocabulary of its own —
/// `Kind.ordered_list` already carried this axis for Markdown/djot.
fn decodeNumbering(attrs: []const AST.KeyVal) ?AST.ListNumbering {
    const raw = attrValue(attrs, "enumtype") orelse return null;
    const table = .{
        .{ "arabic", AST.ListNumbering.decimal },
        .{ "loweralpha", AST.ListNumbering.lower_alpha },
        .{ "upperalpha", AST.ListNumbering.upper_alpha },
        .{ "lowerroman", AST.ListNumbering.lower_roman },
        .{ "upperroman", AST.ListNumbering.upper_roman },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, raw, row[0])) return row[1];
    }
    return null;
}

/// docutils writes `start` only when the first enumerator is not ordinal-1, so
/// its absence means 1 and `Kind.OrderedList.start` is `null` there — the same
/// "absent means the ordinary case" reading `spanExtent` makes. A non-numeric
/// value is treated as absent for the reason given there.
fn decodeStart(attrs: []const AST.KeyVal) ?u32 {
    const raw = attrValue(attrs, "start") orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

/// A cell's grid extent, read from docutils' `morecols`/`morerows` — which
/// count the ADDITIONAL columns or rows the cell covers, so the extent is one
/// more than the attribute. Absent means the ordinary one-square cell, `1`.
///
/// A value that is not a number is treated as absent rather than as an error:
/// this decodes a docutils dump, and a malformed one should fail the corpus
/// round-trip (which compares the whole text) rather than the decode. Every one
/// of the 21 in the corpus parses.
fn spanExtent(attrs: []const AST.KeyVal, key: []const u8) u32 {
    const raw = attrValue(attrs, key) orelse return 1;
    const more = std.fmt.parseInt(u32, raw, 10) catch return 1;
    return more + 1;
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
    /// Per `Tag`, how many produced NO node because twig's shape has no place
    /// for the element itself — `tgroup`/`thead`/`tbody`, whose children move
    /// up into the parent (see `dissolves`).
    ///
    /// A third category and not a bucket of `semantic`, because it answers a
    /// different question. `semantic` counts elements twig's vocabulary HOLDS;
    /// these are elements it deliberately does not hold and does not need to,
    /// their content having been absorbed losslessly. Folding them into
    /// `semantic` would inflate the coverage ratio with elements that have no
    /// twig node, and folding them into `generic` would claim a gap that is not
    /// there. The round-trip is what proves the absorption is lossless; this
    /// number just keeps the books honest about which elements it applied to.
    dissolved: [Tag.count]u32 = @splat(0),
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

    pub fn dissolvedTotal(self: Coverage) u32 {
        var n: u32 = 0;
        for (self.dissolved) |c| n += c;
        return n;
    }

    /// Elements decoded, text nodes excluded.
    pub fn elementTotal(self: Coverage) u32 {
        return self.semanticTotal() + self.genericTotal() + self.dissolvedTotal();
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

/// Flag every row in a dissolving `<thead>`, and every cell in those rows, as a
/// header — the information the wrapper was carrying, moved to where twig keeps
/// it before the wrapper disappears.
///
/// This is the decoder's only in-place edit of an already-built node, and it is
/// well-founded rather than a shortcut: pformat writes a parent AFTER all of its
/// children, so when a `thead` frame closes, its rows and their cells are
/// finished nodes that nothing else will touch again. Both flags are set here
/// rather than at `entry` time because at that point the row does not yet know
/// it is a header row (see `decodeKind`'s `.entry` arm).
fn markHeadRows(b: *AST.Builder, rows: []const Node.Id) void {
    for (rows) |row_id| {
        const row = &b.nodes.items[row_id];
        switch (row.kind) {
            // Only rows are flagged. A `thead` holds nothing else in the
            // corpus, and a non-row child (which would have to be a decode of
            // something docutils does not produce) is passed through untouched
            // rather than reinterpreted.
            .row => row.kind.row.head = true,
            else => continue,
        }
        var cell = row.first_child;
        while (cell) |id| : (cell = b.nodes.items[id].next_sibling) {
            switch (b.nodes.items[id].kind) {
                .cell => b.nodes.items[id].kind.cell.head = true,
                else => {},
            }
        }
    }
}

/// Add one level of indent to every line in a dissolving nested `<line_block>`
/// — the wrapper's entire meaning, moved onto the lines before it disappears.
///
/// Shallow by construction, and that is not an oversight: a wrapper nested two
/// deep has already dissolved into this one by the time this runs (pformat
/// writes parents last), so its lines are already children here and have already
/// been bumped once. Each level bumps once and the counts compose.
fn bumpLineIndent(b: *AST.Builder, children: []const Node.Id) void {
    for (children) |id| {
        switch (b.nodes.items[id].kind) {
            .line => b.nodes.items[id].kind.line.indent += 1,
            // A line block holds nothing but lines in the corpus. Anything else
            // is passed through rather than reinterpreted, as `markHeadRows`
            // does with a non-row child.
            else => continue,
        }
    }
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
    const parent: ?Tag = if (stack.items.len == 0) null else stack.items[stack.items.len - 1].tag;

    // An element with no twig node of its own: hand its children to its parent
    // and vanish. This happens BEFORE attributes are scanned because a
    // dissolving element has none worth keeping by construction — see
    // `dissolves`. `thead` is the one that carries information rather than
    // structure, and it moves that information onto its rows here.
    if (dissolves(frame.tag, parent)) {
        if (frame.tag == .thead) markHeadRows(b, frame.children.items);
        if (frame.tag == .line_block) bumpLineIndent(b, frame.children.items);
        if (coverage) |c| c.dissolved[@intFromEnum(frame.tag)] += 1;
        // A dissolving element at the root would leave the document with no
        // node; pformat never produces one (a doctree's root is always
        // `<document>`), so this cannot fire, and returning without recording a
        // root makes `decode` report `NoRoot` rather than crash if it ever does.
        if (stack.items.len == 0) return;
        try stack.items[stack.items.len - 1].children.appendSlice(allocator, frame.children.items);
        return;
    }

    // Attributes are scanned BEFORE the kind is chosen: a mapping may read one
    // into its payload (`reference`'s `refuri` becomes `Kind.Link.destination`).
    // They are still attached to the node afterwards either way — see `encode`
    // for why the payload never becomes a second source of truth.
    attr_buf.clearRetainingCapacity();
    try scanAttrs(frame.attrs_src, attr_buf, allocator);

    const semantic = decodeKind(b, frame.tag, parent, frame.children.items, attr_buf.items);
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
    // Everything rST spells generically is directive-family: a `.. name::`
    // block, a role, or a doctree element with no twig kind of its own.
    if (kind == .container) b.setSpelling(id, .{ .container_origin = .directive });
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
    try writeNode(allocator, ast, ast.root, .{}, 0, w);
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

fn writeNode(
    allocator: Allocator,
    ast: *const AST,
    id: Node.Id,
    where: Where,
    depth: usize,
    w: *Writer,
) EncodeError!void {
    const node = ast.nodes[id];
    if (node.kind == .str) {
        try writeText(w, depth, node.kind.str);
        return;
    }

    // Which of the two constructs the definition-list four are spelling is
    // settled HERE, at the list, and inherited by everything below it. A list
    // ignores what it was told (nothing above it knows) and asks the tree; its
    // items, terms and definitions take the answer as given.
    const option_list = switch (node.kind) {
        .definition_list => isOptionList(ast, id),
        .definition_list_item, .term, .definition => where.option_list,
        else => false,
    };

    const tag = encodeTag(node.kind, .{ .parent = where.parent, .option_list = option_list }) orelse
        return error.UnrepresentableKind;
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

    // A table's children are re-nested under the `tgroup`/`thead`/`tbody`
    // wrappers `decode` dissolved.
    if (node.kind == .table) {
        try writeTable(allocator, ast, id, depth, w);
        return;
    }

    // And a line block's under the nested `line_block` wrappers it dissolved.
    if (node.kind == .line_block) {
        try writeLineBlock(allocator, ast, id, depth, w);
        return;
    }

    // The option-list answer descends exactly two levels — list to item, item to
    // term and description — and stops. A definition list nested inside one of
    // those descriptions is a list of its own and asks the tree again.
    const child_where: Where = .{
        .parent = node.kind,
        .option_list = switch (node.kind) {
            .definition_list, .definition_list_item => option_list,
            else => false,
        },
    };
    var it = ast.children(id);
    while (it.next()) |child| {
        try writeNode(allocator, ast, child.id, child_where, depth + 1, w);
    }
}

/// Write a line block's lines back into docutils' nesting: one wrapper
/// `<line_block>` per level of `indent`, opened when a line's indent rises above
/// the level currently open and closed when it falls. The exact inverse of the
/// dissolution in `closeTop`.
///
/// Closing is a decrement and nothing else, because pformat has no closing tags
/// — a level ends when the next line is written shallower. That is also why a
/// jump of more than one level costs nothing to reproduce: docutils writes
/// `<line_block><line_block>` back to back when a group's own minimum indent is
/// indented, and so does opening two wrappers in a row here.
///
/// The indent of anything that is not a `line` reads as zero, which puts a
/// stray child at the block's own level rather than dropping it — the same
/// posture `bumpLineIndent` takes on the way in.
fn writeLineBlock(allocator: Allocator, ast: *const AST, id: Node.Id, depth: usize, w: *Writer) EncodeError!void {
    var open: u32 = 0;
    var it = ast.children(id);
    while (it.next()) |child| {
        const indent = switch (ast.nodes[child.id].kind) {
            .line => |l| l.indent,
            else => 0,
        };
        while (open < indent) : (open += 1) {
            try writeIndent(w, depth + 1 + open);
            try w.writeAll("<line_block>\n");
        }
        open = indent;
        try writeNode(allocator, ast, child.id, .{ .parent = .line_block }, depth + 1 + open, w);
    }
}

/// Write a table's children back into docutils' shape: the caption stays a
/// direct child, and the columns and rows are re-nested under a synthesized
/// `<tgroup>` with the header rows under `<thead>` and the rest under
/// `<tbody>`. The exact inverse of the three dissolutions in `closeTop`.
///
/// Everything synthesized here is DERIVED, which is what made dissolving safe
/// in the first place: `cols` is the number of `column` children, and the row
/// grouping is `row.head`. Nothing is read back from a field `decode` had to
/// invent.
///
/// A table with no columns and no rows writes no `tgroup` at all rather than an
/// empty one — docutils cannot produce such a table (a table always has at
/// least one column), so there is no corpus answer to match, and emitting
/// `<tgroup cols="0">` would be inventing one.
fn writeTable(allocator: Allocator, ast: *const AST, id: Node.Id, depth: usize, w: *Writer) EncodeError!void {
    // One pass does both jobs: it measures the grid, and it writes the children
    // that are NOT part of it (the caption) in place at the table's own depth.
    // The two are independent, and the grid cannot start being written until the
    // measurement is complete anyway — `<tgroup cols="N">` needs the count.
    var cols: usize = 0;
    var head_rows: usize = 0;
    var body_rows: usize = 0;
    var it = ast.children(id);
    while (it.next()) |child| switch (ast.nodes[child.id].kind) {
        .column => cols += 1,
        .row => |r| if (r.head) {
            head_rows += 1;
        } else {
            body_rows += 1;
        },
        else => try writeNode(allocator, ast, child.id, .{ .parent = .table }, depth + 1, w),
    };

    if (cols == 0 and head_rows == 0 and body_rows == 0) return;

    try writeIndent(w, depth + 1);
    try w.print("<tgroup cols=\"{d}\">\n", .{cols});

    var columns = ast.children(id);
    while (columns.next()) |child| {
        if (ast.nodes[child.id].kind != .column) continue;
        try writeNode(allocator, ast, child.id, .{ .parent = .table }, depth + 2, w);
    }

    // docutils always writes a `<tbody>`, even where twig's flat row list has
    // no body rows — all 65 corpus tables have one, and 12 also have a
    // `<thead>`, never the other way round.
    if (head_rows > 0) try writeRowGroup(allocator, ast, id, true, depth + 2, w);
    try writeRowGroup(allocator, ast, id, false, depth + 2, w);
}

/// Write one `<thead>`/`<tbody>` and the rows belonging to it, in document order
/// within the group.
///
/// Grouping by FLAG rather than by RUN is the deliberate half of this, and it is
/// where the doctree parts company with `html/serializer.zig`'s
/// `renderSectionedTable` — which solves the same flat-rows-to-sectioned-output
/// problem, in one pass, by opening a new section every time `head` changes.
/// That is right for HTML, whose `<table>` admits any number of `<thead>`/
/// `<tbody>` groups. A docutils `<tgroup>` does not: every one of the 65 in the
/// corpus has AT MOST ONE `<thead>` and EXACTLY ONE `<tbody>`, which is also
/// what docutils' DTD allows. Run-grouping a table whose header rows are
/// INTERLEAVED with body rows would therefore emit `<thead><tbody><thead>…` —
/// output docutils could never produce and its own reader would reject.
///
/// So an interleaved table (which twig's flat model permits and docutils' shape
/// cannot express) is REORDERED into the one legal grouping rather than
/// faithfully sectioned. Nothing in the corpus exercises it — decoded groups
/// were contiguous to begin with — and the alternative is emitting an invalid
/// doctree.
fn writeRowGroup(
    allocator: Allocator,
    ast: *const AST,
    table: Node.Id,
    head: bool,
    depth: usize,
    w: *Writer,
) EncodeError!void {
    try writeIndent(w, depth);
    try w.writeAll(if (head) "<thead>\n" else "<tbody>\n");
    var it = ast.children(table);
    while (it.next()) |child| switch (ast.nodes[child.id].kind) {
        .row => |r| if (r.head == head) try writeNode(allocator, ast, child.id, .{ .parent = .table }, depth + 1, w),
        else => {},
    };
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

test "a citation's name is `names`, and its `<label>` is the written form" {
    // The corpus case that separates the two: `.. [TARGET] …` normalizes to
    // `target` for resolution while the rendered marker keeps its case. A
    // decode that read the `<label>` child would get `TARGET` and resolve
    // against nothing.
    const src =
        \\<document source="test data">
        \\    <citation ids="target" names="target">
        \\        <label>
        \\            TARGET
        \\        <paragraph>
        \\            Body.
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    const cit = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("target", ast.nodes[cit].kind.citation.label);
    // `<label>` stays an ordinary generic child — it is the marker, not the
    // name, exactly as for a footnote.
    const label = ast.nodes[cit].first_child.?;
    try testing.expectEqualStrings("label", ast.nodes[label].kind.container.name);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a citation reference keeps the written label and leaves refname in attrs" {
    // `[CIT1]_` gives `refname="cit1"` over a `CIT1` body: the normalized name
    // and the written one. The payload takes the written form (the one that
    // cannot be recovered from the other) and `refname` round-trips as an
    // attribute, so no normalization step enters this codec.
    const src =
        \\<document source="test data">
        \\    <paragraph>
        \\        <citation_reference ids="citation-reference-1" refname="cit1">
        \\            CIT1
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    const para = ast.nodes[ast.root].first_child.?;
    const ref = ast.nodes[para].first_child.?;
    try testing.expectEqual(AST.TextLeafKind.citation_reference, ast.nodes[ref].kind.text_leaf.kind);
    try testing.expectEqualStrings("CIT1", ast.nodes[ref].kind.text_leaf.text);
    try testing.expectEqualStrings("cit1", ast.attrsOf(ref).get("refname").?);
    try testing.expectEqual(@as(u32, 1), cov.semantic[@intFromEnum(Tag.citation_reference)]);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a substitution definition holds its body inline" {
    // The shape twig had no kind for: a named definition whose children are
    // inlines. The corpus's most common body is an `image`, which is still a
    // generic container here — the point is that it sits DIRECTLY under the
    // definition, with no paragraph in between.
    const src =
        \\<document source="test data">
        \\    <substitution_definition names="RST">
        \\        reStructuredText
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    const sub = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("RST", ast.nodes[sub].kind.substitution.label);
    try testing.expectEqual(AST.Node.Kind.ContentModel.inlines, ast.nodes[sub].kind.contentModel());
    const body = ast.nodes[sub].first_child.?;
    try testing.expectEqualStrings("reStructuredText", ast.nodes[body].kind.str);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a table is flattened out of tgroup/thead/tbody and built back into them" {
    // The whole restructuring in one document: a caption spelled `<title>`, a
    // `<tgroup>` whose `cols` is derivable, per-column `<colspec>`s, and a
    // header row that is a header only because of the `<thead>` around it.
    const src =
        \\<document source="test data">
        \\    <table>
        \\        <title>
        \\            Prices
        \\        <tgroup cols="2">
        \\            <colspec colwidth="10" stub="1">
        \\            <colspec colwidth="20">
        \\            <thead>
        \\                <row>
        \\                    <entry>
        \\                        <paragraph>
        \\                            Treat
        \\                    <entry>
        \\                        <paragraph>
        \\                            Price
        \\            <tbody>
        \\                <row>
        \\                    <entry morecols="1">
        \\                        <paragraph>
        \\                            Sold out
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    // Twig's shape: the three wrappers are gone and the table holds its caption,
    // its columns and its rows directly.
    const table = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[table].kind == .table);
    var kinds = std.ArrayList(std.meta.Tag(Node.Kind)).empty;
    defer kinds.deinit(testing.allocator);
    var it = ast.children(table);
    while (it.next()) |child| try kinds.append(testing.allocator, std.meta.activeTag(ast.nodes[child.id].kind));
    try testing.expectEqualSlices(
        std.meta.Tag(Node.Kind),
        &.{ .caption, .column, .column, .row, .row },
        kinds.items,
    );

    // `<title>` under a table is the caption; the columns keep their width and
    // stub as attributes, since `Kind.column` carries no payload.
    const caption = ast.nodes[table].first_child.?;
    const stub_col = ast.nodes[caption].next_sibling.?;
    try testing.expectEqualStrings("10", ast.attrsOf(stub_col).get("colwidth").?);
    try testing.expectEqualStrings("1", ast.attrsOf(stub_col).get("stub").?);

    // The `<thead>` moved its header-ness onto the row AND its cells before
    // dissolving — neither carries a marker of its own in the doctree.
    var rows = ast.children(table);
    var head: ?Node.Id = null;
    var body: ?Node.Id = null;
    while (rows.next()) |child| switch (ast.nodes[child.id].kind) {
        .row => |r| if (r.head) {
            head = child.id;
        } else {
            body = child.id;
        },
        else => {},
    };
    try testing.expect(ast.nodes[head.?].kind.row.head);
    try testing.expect(ast.nodes[ast.nodes[head.?].first_child.?].kind.cell.head);
    try testing.expect(!ast.nodes[body.?].kind.row.head);
    try testing.expect(!ast.nodes[ast.nodes[body.?].first_child.?].kind.cell.head);

    // `morecols` counts the ADDITIONAL columns spanned, so the extent is one
    // more — and the attribute stays put for `encode` to write back from.
    const spanning = ast.nodes[body.?].first_child.?;
    try testing.expectEqual(@as(u32, 2), ast.nodes[spanning].kind.cell.colspan);
    try testing.expectEqual(@as(u32, 1), ast.nodes[spanning].kind.cell.rowspan);
    try testing.expectEqualStrings("1", ast.attrsOf(spanning).get("morecols").?);

    // The three wrappers produced no node, and are counted as neither semantic
    // nor generic.
    try testing.expectEqual(@as(u32, 1), cov.dissolved[@intFromEnum(Tag.tgroup)]);
    try testing.expectEqual(@as(u32, 1), cov.dissolved[@intFromEnum(Tag.thead)]);
    try testing.expectEqual(@as(u32, 1), cov.dissolved[@intFromEnum(Tag.tbody)]);
    try testing.expectEqual(@as(u32, 0), cov.generic[@intFromEnum(Tag.tgroup)]);
    try testing.expectEqual(@as(u32, 2), cov.semantic[@intFromEnum(Tag.colspec)]);

    // And it all comes back — `cols="2"` recounted, the groups re-nested, the
    // caption spelled `<title>` again.
    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a line block's nesting flattens to a per-line indent and is rebuilt from it" {
    // `test_line_blocks.py:8` from the corpus, which is the case the whole
    // design rests on: SIX `<line_block>` elements for ONE authored block, and a
    // depth that is a line's rank within its group rather than its column — the
    // 2-space line ends up DEEPER than the 4-space line three lines above it.
    const src =
        \\<document source="test data">
        \\    <line_block>
        \\        <line>
        \\            Initial indentation is also significant and preserved:
        \\        <line>
        \\        <line_block>
        \\            <line>
        \\                Indented 4 spaces
        \\        <line>
        \\            Not indented
        \\        <line_block>
        \\            <line_block>
        \\                <line>
        \\                    Indented 2 spaces
        \\                <line_block>
        \\                    <line>
        \\                        Indented 4 spaces
        \\            <line>
        \\                Only one space
        \\            <line>
        \\            <line_block>
        \\                <line>
        \\                    Continuation lines may be indented less
        \\                    than their base lines.
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    // Twig's shape: ONE block holding NINE lines, flat, each carrying the depth
    // the wrappers around it used to say. Note the 0→2 step — a group whose own
    // minimum indent is itself indented opens two wrappers at once.
    const block = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[block].kind == .line_block);
    var indents = std.ArrayList(u32).empty;
    defer indents.deinit(testing.allocator);
    var it = ast.children(block);
    while (it.next()) |child| try indents.append(testing.allocator, ast.nodes[child.id].kind.line.indent);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 0, 2, 3, 1, 1, 2 }, indents.items);

    // The two childless lines are the stanza breaks, and they are CONTENT: a
    // decode that dropped them would still round-trip the indents above.
    var lines = ast.children(block);
    var empty: usize = 0;
    while (lines.next()) |child| {
        if (ast.nodes[child.id].first_child == null) empty += 1;
    }
    try testing.expectEqual(@as(usize, 2), empty);

    // One block is the construct; the other five were wrappers and produced no
    // node at all, counted as neither semantic nor generic.
    try testing.expectEqual(@as(u32, 1), cov.semantic[@intFromEnum(Tag.line_block)]);
    try testing.expectEqual(@as(u32, 5), cov.dissolved[@intFromEnum(Tag.line_block)]);
    try testing.expectEqual(@as(u32, 0), cov.generic[@intFromEnum(Tag.line_block)]);
    try testing.expectEqual(@as(u32, 9), cov.semantic[@intFromEnum(Tag.line)]);

    // And all six come back, in the right places, from the nine numbers.
    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an option list is a definition list, told apart on the way out by its options" {
    // `test_option_lists.py:5`, the aliased case: one item, THREE options in its
    // group, and an argument on each spelled with a different delimiter.
    const src =
        \\<document source="test data">
        \\    <option_list>
        \\        <option_list_item>
        \\            <option_group>
        \\                <option>
        \\                    <option_string>
        \\                        -b
        \\                    <option_argument delimiter=" ">
        \\                        file
        \\                <option>
        \\                    <option_string>
        \\                        --bbbb
        \\                    <option_argument delimiter="=">
        \\                        file
        \\            <description>
        \\                <paragraph>
        \\                    option -b
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    // Twig's shape: an ordinary definition list, no new vocabulary anywhere.
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind == .definition_list);
    const item = ast.nodes[list].first_child.?;
    try testing.expect(ast.nodes[item].kind == .definition_list_item);
    const group = ast.nodes[item].first_child.?;
    try testing.expect(ast.nodes[group].kind == .term);
    try testing.expect(ast.nodes[ast.nodes[group].next_sibling.?].kind == .definition);

    // The option PARSE stays generic inside the term, which is what lets the
    // `delimiter` — the one piece of it a `term` could never hold — round-trip
    // untouched.
    const option = ast.nodes[group].first_child.?;
    try testing.expectEqualStrings("option", ast.nodes[option].kind.container.name);
    const arg = ast.nodes[ast.nodes[option].first_child.?].next_sibling.?;
    try testing.expectEqualStrings("option_argument", ast.nodes[arg].kind.container.name);
    try testing.expectEqualStrings(" ", ast.attrsOf(arg).get("delimiter").?);

    try testing.expectEqual(@as(u32, 1), cov.semantic[@intFromEnum(Tag.option_list)]);
    try testing.expectEqual(@as(u32, 1), cov.semantic[@intFromEnum(Tag.option_group)]);
    try testing.expectEqual(@as(u32, 2), cov.generic[@intFromEnum(Tag.option)]);

    // And `isOptionList` finds the options again, so all four spell themselves
    // back rather than decaying to a definition list.
    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a real definition list still encodes as one, options or not" {
    // The other side of the discriminator. Same four twig kinds, same nesting,
    // no `option` in the term — so nothing here may come back as an option list.
    const src =
        \\<document source="test data">
        \\    <definition_list>
        \\        <definition_list_item>
        \\            <term>
        \\                -b
        \\            <definition>
        \\                <paragraph>
        \\                    Looks like an option, is not one.
        \\
    ;
    var ast = try decode(testing.allocator, src, null);
    defer ast.deinit();
    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an option list nested in a description does not infect the list around it" {
    // The answer is per-LIST, not per-subtree: a definition list inside an
    // option list's description asks the tree again rather than inheriting, so
    // the two constructs nest without either one renaming the other.
    const src =
        \\<document source="test data">
        \\    <option_list>
        \\        <option_list_item>
        \\            <option_group>
        \\                <option>
        \\                    <option_string>
        \\                        -a
        \\            <description>
        \\                <definition_list>
        \\                    <definition_list_item>
        \\                        <term>
        \\                            see also
        \\                        <definition>
        \\                            <paragraph>
        \\                                the manual
        \\
    ;
    var ast = try decode(testing.allocator, src, null);
    defer ast.deinit();
    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an enumerated list reads enumtype/start into the kind and leaves all four attributes alone" {
    const src =
        \\<document source="test data">
        \\    <enumerated_list enumtype="lowerroman" prefix="(" start="3" suffix=")">
        \\        <list_item>
        \\            <paragraph>
        \\                Item iii.
        \\
    ;
    var ast = try decode(testing.allocator, src, null);
    defer ast.deinit();

    const list = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[list].kind.ordered_list.numbering == .lower_roman);
    try testing.expectEqual(@as(?u32, 3), ast.nodes[list].kind.ordered_list.start);
    // `prefix`/`suffix` have no payload to move to, which is why the record
    // stays in `attrs` for all four rather than for only the two twig can hold.
    try testing.expectEqualStrings("(", ast.attrsOf(list).get("prefix").?);
    try testing.expectEqualStrings(")", ast.attrsOf(list).get("suffix").?);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "an enumerated list with no enumtype stays a generic container" {
    // Not a default of `.decimal`: docutils writes `enumtype` on every list it
    // emits, so one without it is a doctree this codec has no reading for.
    const src =
        \\<document source="test data">
        \\    <enumerated_list>
        \\        <list_item>
        \\
    ;
    var ast = try decode(testing.allocator, src, null);
    defer ast.deinit();
    const list = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("enumerated_list", ast.nodes[list].kind.container.name);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "only a NESTED line block dissolves; the outermost keeps its attributes" {
    // `.. line-block:: :class: linear :name: cit:short` — the one attributed
    // block in the corpus, and the reason `dissolves` had to become conditional
    // on the parent rather than a property of the tag.
    const src =
        \\<document source="test data">
        \\    <line_block classes="linear" ids="cit-short" names="cit:short">
        \\        <line>
        \\            This is a line block with options.
        \\
    ;
    var cov: Coverage = .{};
    var ast = try decode(testing.allocator, src, &cov);
    defer ast.deinit();

    const block = ast.nodes[ast.root].first_child.?;
    try testing.expect(ast.nodes[block].kind == .line_block);
    try testing.expectEqualStrings("linear", ast.attrsOf(block).get("classes").?);
    try testing.expectEqual(@as(u32, 0), cov.dissolved[@intFromEnum(Tag.line_block)]);
    try testing.expectEqual(@as(u32, 0), ast.nodes[ast.nodes[block].first_child.?].kind.line.indent);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a caption is a table's <title> but a figure's <caption>" {
    // The one mapping that reads its parent, in the direction that proves it is
    // not simply `title -> caption`: a `figure` is still a generic container
    // here, and the `<caption>` inside it stays a `<caption>`.
    const src =
        \\<document source="test data">
        \\    <figure>
        \\        <caption>
        \\            A picture
        \\
    ;
    var ast = try decode(testing.allocator, src, null);
    defer ast.deinit();

    const figure = ast.nodes[ast.root].first_child.?;
    const caption = ast.nodes[figure].first_child.?;
    try testing.expect(ast.nodes[caption].kind == .caption);

    const out = try encodeAlloc(testing.allocator, &ast);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "a decoded tree owns its payload strings and outlives the source" {
    // `decode`'s contract is that the returned `AST` borrows nothing from the
    // input — `Builder` copies every payload string. That is easy to break
    // WITHOUT failing anything: a kind missing from `Builder.dupeKind` still
    // compiles and still passes any test whose source outlives the tree, which
    // is nearly all of them. `citation`/`substitution` were broken exactly that
    // way when they were added. This frees the source first.
    const src =
        \\<document source="test data">
        \\    <citation ids="cit" names="cit">
        \\        <paragraph>
        \\            Body.
        \\    <substitution_definition names="RST">
        \\        reStructuredText
        \\
    ;
    const owned = try testing.allocator.dupe(u8, src);
    var ast = try decode(testing.allocator, owned, null);
    defer ast.deinit();
    testing.allocator.free(owned);

    const cit = ast.nodes[ast.root].first_child.?;
    try testing.expectEqualStrings("cit", ast.nodes[cit].kind.citation.label);
    const sub = ast.nodes[cit].next_sibling.?;
    try testing.expectEqualStrings("RST", ast.nodes[sub].kind.substitution.label);
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
