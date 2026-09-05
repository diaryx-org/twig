//! What a format's *surface syntax* looks like — the spelling knowledge the
//! authoring gestures in `ast/editor.zig` need, and the only thing standing
//! between the language-agnostic `Splicer` and a working Cmd-B.
//!
//! ── Why this is a table and not a switch ───────────────────────────────────
//! Twig's formats are RAGGED: every one of them parses and renders, but they
//! author wildly different subsets — djot spells all eight inline marks,
//! Markdown only three (`**`/`*`/`` ` ``), HTML spells seven as tag pairs and
//! nothing block-level, AsciiDoc everything but a link, a footnote and a
//! table, XML none at all. A `?Delims` per (format, kind)
//! makes that raggedness DATA. The alternative — a `switch (format)` per op,
//! with an `else => unsupported_format` arm — is what the C ABI grew instead,
//! and it put the spelling of djot's `{=mark=}` behind an `extern` boundary
//! where the CLI couldn't reach it and only a C caller could test it.
//!
//! So: a `null` field means "this format has no spelling for that", and every
//! caller turns that into one uniform "unsupported" error. Exactly how
//! `format.zig`'s `TargetEntry.serializeFromAst: ?*const fn(...)` already says
//! "Twig cannot write that target yet".
//!
//! ── Why data, not behaviour ────────────────────────────────────────────────
//! Everything here is a byte string or a flag except `spellsAutolink`, which
//! has to run the format's OWN scanner (see below). That's deliberate: the
//! *algorithms* — walk the destination escaping bytes, prefix each line of a
//! covered block — are format-INDEPENDENT and live once in `ast/editor.zig`.
//! Only the alphabet changes. Keeping the tables inert means a new format is a
//! `Syntax` literal, not new code paths.
//!
//! `Syntax` names no format and imports no language module; `format.zig`'s
//! registry is what binds a `Format` to its `Syntax`, and `ast/editor.zig`
//! takes a `*const Syntax` without ever learning which format it came from.

const std = @import("std");
const AST = @import("ast/ast.zig");

/// The inline marks a toolbar can wrap or toggle over a selection. Named for
/// the `AST.Node.Kind` tags they parse back as — see `kindTag`.
pub const InlineKind = enum {
    strong,
    emph,
    verbatim,
    mark,
    superscript,
    subscript,
    insert,
    delete,
};

/// The blocks `Editor.setBlock` converts between by rewriting a leading marker.
pub const BlockKind = enum { paragraph, heading };

/// The containers `Editor.toggleBlockContainer` wraps a block range in. Unlike
/// a `BlockKind` these prefix EVERY line, they nest, and a list numbers its
/// items — which is why they're a separate vocabulary.
pub const ContainerKind = enum { block_quote, bullet_list, ordered_list };

/// The source delimiters that mark an inline kind. Values are exactly what the
/// format's serializer emits, so a wrap round-trips.
pub const Delims = struct {
    open: []const u8,
    close: []const u8,
    /// May an EDITOR gesture author this, or is the spelling emit-only?
    ///
    /// The two questions are genuinely different, and conflating them is why
    /// this flag exists. Converting a djot document to Markdown should spell a
    /// `mark` as `==x==` — lossy, but better than dropping the node. A Cmd-B
    /// style toggle must NOT mint the same bytes: `==x==` is not CommonMark, so
    /// the reparse gives back a `str`, not a `mark`, and the toggle isn't
    /// reversible.
    ///
    /// `false` = the serializer may spell it, `Editor` refuses it with
    /// `error.UnsupportedFormat`. Before this flag the two answers lived in two
    /// places — a `null` here and a hand-written arm in the serializer — and
    /// nothing kept them honest.
    authorable: bool = true,
};

/// How a format spells a container's per-line prefix.
pub const ContainerSpelling = struct {
    /// Opens the container on the first line of each covered block.
    marker: []const u8,
    /// Holds a block's continuation lines inside the container.
    cont: []const u8,
    /// A blank line INSIDE the container. A blank line separates list items (it
    /// merely makes the list loose) but BREAKS a quote in two, so a quote has to
    /// mark its blanks and a list must not.
    blank: []const u8,
    /// The marker is a per-item ordinal (`1. `, `2. `…), built at emit time
    /// rather than read from `marker`.
    numbered: bool = false,
};

/// How a format spells a FENCED code block.
///
/// A fence is not a fixed string, which is why this is a struct and not a
/// `[]const u8`: the opener must be LONGER than any run of `char` in the body,
/// or the code closes its own block. `Editor` does that measurement (the
/// algorithm is format-independent); this says only which byte to count and how
/// short a fence may be.
pub const CodeFence = struct {
    /// The fence byte, repeated. Both authorable formats use a backtick; the
    /// tilde form exists in Markdown but is not what its serializer emits, and
    /// a second spelling would give the toggle two shapes to reverse.
    char: u8,
    /// The shortest run that opens a fence.
    min: usize = 3,
    /// Bytes that cannot appear in the info string, beyond `char` itself and
    /// the line ends every format forbids. Empty when the format's info string
    /// admits anything else.
    info_forbids: []const u8 = "",
};

/// How a format spells a TASK-LIST item's checkbox — the `[ ]`/`[x]` that
/// follows a bullet marker and turns a `list_item` into a `task_list_item`.
///
/// The box and its separator are separate fields because the two gestures need
/// different pieces: ticking a box rewrites the BOX ALONE (so it never touches
/// how the author spaced the item), while adding one has to write the separator
/// too or the box would run into the text and stay literal.
pub const TaskMarker = struct {
    /// The box, brackets included and nothing else: `[ ]`.
    unchecked: []const u8,
    /// The checked box, which must be the same width as `unchecked` — ticking
    /// one is an in-place overwrite.
    checked: []const u8,
    /// What separates the box from the item's text.
    space: []const u8 = " ",
    /// The bytes a box may hold to count as CHECKED when reading source back
    /// (`x` and `X` in both formats). The unchecked box is always a space.
    checked_chars: []const u8 = "xX",
};

/// How a format spells a footnote — both halves, because they are one gesture.
///
/// A reference with no definition is not a footnote in either format: it either
/// renders as literal `[^label]` or dangles. So the spelling an editor needs is
/// the PAIR, and `Syntax.footnote` being non-null is the claim that this format
/// can author both. The reference delimiters are also in `text_leaf_delims`
/// (where the serializer reads them); `assertCoherent` pins the two together so
/// the duplicate cannot drift.
pub const FootnoteSpelling = struct {
    /// Opens a reference: `[^`.
    ref_open: []const u8,
    /// Closes a reference: `]`.
    ref_close: []const u8,
    /// Follows the reference spelling to open a DEFINITION at a line start:
    /// `[^label]` + `: ` + the body.
    def_suffix: []const u8,
    /// Bytes a label cannot hold, beyond the line ends every format forbids.
    label_forbids: []const u8 = "[]",
};

/// How a format spells a PIPE TABLE's skeleton — the bars, the padding, and the
/// delimiter row that carries the columns' alignment.
///
/// A table is the one construct an editor re-spells IN FULL rather than wrapping
/// or prefixing: a column op touches every row and the delimiter at once, so the
/// grid is lifted out of the tree, mutated, and written back as fresh source (see
/// `ast/table_edit.zig`). Every byte of the skeleton is therefore a spelling this
/// table has to carry. They were literals in `table_edit.zig`, which wrote GFM
/// into every format whose table the extractor could read.
pub const TableSpelling = struct {
    /// Borders a row and separates its cells.
    bar: []const u8,
    /// Written on both sides of a cell's content, so a row reads `| a | b |`
    /// rather than `|a|b|`. Both serializers pad, and an edited table has to
    /// come back out the way the serializer would have written it.
    pad: []const u8 = " ",
    /// The same, around a DELIMITER cell. A separate field because the two
    /// formats disagree, and djot's answer is load-bearing rather than a matter
    /// of style: djot.js steps a single byte past the `|` before matching the
    /// dashes, so `| --- |` is read there as an ordinary data row and the table
    /// silently loses its header. See `djot/serializer.zig`'s
    /// `writeTableSeparator`, which spells the same line on the way out.
    delim_pad: []const u8,
    /// The delimiter cell per column alignment, colons included and padding
    /// excluded. A table rather than a dash run plus a colon rule, because the
    /// formats build the aligned forms differently: Markdown ADDS a colon to the
    /// three-dash run (`:---`), djot REPLACES a dash so the cell stays three
    /// wide (`:--`). One rule that produced both would be a rule about nothing.
    delim: std.EnumArray(AST.Alignment, []const u8),
};

/// How a format escapes a link's `(destination)` position.
///
/// This is NOT `link_text_escapes`' alphabet: this one guards the position
/// where parens end the destination and emphasis means nothing.
pub const DestEscapes = struct {
    /// Bytes to backslash-escape in the ordinary `(dest)` form.
    plain: []const u8,
    /// The `<dest>` form, used when the destination holds a space or tab —
    /// `null` when the format has no angle form and must escape in place.
    angle: ?struct {
        /// Bytes to backslash-escape between the angle brackets. A different
        /// alphabet: the brackets themselves now matter, parens no longer do.
        escapes: []const u8,
    } = null,
};

/// How a format spells a node's ATTRIBUTES back into its own source.
///
/// The formats disagree only on an alphabet, never on the algorithm: walk the
/// entries in stored order, spell `id`/`class` with their shorthand sigils if
/// the format has them, spell everything else as a key and (unless bare) a
/// value. That walk lived twice — `djot/serializer.zig`'s `writeDjotAttrs` and
/// `markdown/serializer.zig`'s `writeDirectiveAttrs` — as near-identical code
/// differing in a quoting policy. rST would have made it a third copy, which is
/// what this table exists to prevent: `.. image::`'s `:width: 50%` options are
/// the SAME walk with `open`/`close` empty, `between` a newline, and `:` for a
/// key prefix. See `attrs_writer.zig` for the one algorithm.
///
/// `null` = this format has no attribute spelling, so a serializer that reaches
/// for one writes nothing. HTML is deliberately not a client of this: its
/// `renderAttributes` merges a synthesized `extra` list, dedups keys against it,
/// and escapes for a tag's interior — output machinery, not surface spelling —
/// and HTML carries `none` anyway.
pub const AttrSpelling = struct {
    /// Opens and closes the whole block: `{`/`}` for a brace form. Both empty
    /// when each entry stands on its own (rST's field lines).
    open: []const u8 = "",
    close: []const u8 = "",
    /// Written between two entries: a space inside braces, a newline (plus a
    /// caller-supplied indent) for field lines.
    between: []const u8 = " ",
    /// Written before every key. Empty for a brace form, `:` for rST.
    key_prefix: []const u8 = "",
    /// Written between a key and its value. A BARE entry (`KeyVal.value ==
    /// null` — HTML's `disabled`) omits this and the value both.
    key_value: []const u8 = "=",
    /// When to wrap a value in `"`.
    quoting: Quoting = .never,
    /// Bytes to backslash-escape inside a quoted value. Empty means the format
    /// quotes without escaping.
    quote_escapes: []const u8 = "",
    /// The `#name` shorthand for the `id` key. `null` spells `id` as an
    /// ordinary key — which is what rST wants: docutils has no sigils, and
    /// `:name:` is just another option.
    id_sigil: ?[]const u8 = null,
    /// The `.name` shorthand, written once per space-separated class in the
    /// `class` value (`class="a b"` -> `.a .b`). `null` spells `class` as an
    /// ordinary key.
    class_sigil: ?[]const u8 = null,
};

/// Whether a value needs `"` around it.
///
/// `when_needed` means "quote unless the value is spellable bare", where bare
/// admits only name characters — Markdown's rule, and the reason `key=val` and
/// `key="a b"` both appear in its output. `always` is djot's.
pub const Quoting = enum { never, always, when_needed };

/// The spelling of a format that can't be authored into at all — every field
/// left at "can't spell it". A parse-only language (XML) carries THIS
/// rather than a `null`, which is what lets `Editor.syntax` be a plain pointer:
/// every gesture consults a table, finds the `null` it would have found anyway,
/// and reports unsupported through the one uniform path. There is no second
/// "but does this format have a table at all?" question to forget to ask.
pub const none: Syntax = .{};

/// One format's surface spelling. Every field defaults to "can't spell it", so
/// a format that only parses is `.{}` (see `none`) and every gesture over it
/// reports unsupported without that format needing to say so.
pub const Syntax = struct {
    /// Delimiters per inline mark. `null` for a mark this format cannot spell
    /// AT ALL; a spelling that exists but must not be authored carries
    /// `authorable = false` instead (see `Delims`).
    ///
    /// Keyed on `AST.InlineMark` rather than on `InlineKind`, so the table has
    /// exactly one entry per node the serializers emit — which is what lets
    /// them read it instead of keeping a second, drifting copy.
    inline_delims: std.EnumArray(AST.InlineMark, ?Delims) = .initFill(null),

    /// Delimiters per delimited text leaf — a `` `code` `` span, `$math$`, a
    /// `:shortcode:`. Same contract as `inline_delims`, for the other family.
    text_leaf_delims: std.EnumArray(AST.TextLeafKind, ?Delims) = .initFill(null),

    /// Per-line prefixes per container kind.
    container_spelling: std.EnumArray(ContainerKind, ?ContainerSpelling) = .initFill(null),

    /// How a node's attributes are spelled back. `null` = no spelling, so a
    /// serializer writes nothing. See `AttrSpelling`.
    attr_spelling: ?AttrSpelling = null,

    /// The byte that opens an ATX heading, repeated `level` times then a space.
    /// `null` = this format has no heading marker, so `setBlock` is unsupported.
    heading_marker: ?u8 = null,

    /// A thematic break, as the whole line it occupies (no trailing newline).
    /// `null` = this format has no thematic break, so `insertThematicBreak` is
    /// unsupported.
    ///
    /// The formats disagree on the spelling for a reason worth keeping: djot's
    /// `* * *` and Markdown's `---` are both what their serializers emit, and
    /// Markdown's choice is NOT free — a `---` line is only a break when a blank
    /// line precedes it, since after a paragraph line it is a setext heading
    /// underline instead. `Editor.insertThematicBreak` blank-separates
    /// unconditionally, which is what makes one spelling safe for both.
    thematic_break: ?[]const u8 = null,

    /// How a fenced code block is spelled. `null` = this format cannot author
    /// one, so the code-block gestures are unsupported. See `CodeFence`.
    code_fence: ?CodeFence = null,

    /// How a task-list checkbox is spelled. `null` = this format has no
    /// checkbox. See `TaskMarker`.
    ///
    /// A checkbox rides on a bullet item, so a format spelling one must also
    /// spell a bullet list — `assertCoherent` checks that.
    task_marker: ?TaskMarker = null,

    /// How a footnote's reference and definition are spelled. `null` = this
    /// format has no footnotes. See `FootnoteSpelling`.
    footnote: ?FootnoteSpelling = null,

    /// How a pipe table is spelled. `null` = this format has no pipe table, so
    /// every table gesture is unsupported. See `TableSpelling`.
    ///
    /// HTML is what forced this field to exist, and it is the sharpest case in
    /// the file for why a gesture must consult a table before it reads the tree:
    /// `html/parser.zig` lowers `<table>/<tr>/<td>` to the SAME `table`/`row`/
    /// `cell` nodes a pipe table produces, so the grid extracted perfectly and
    /// the rebuilt pipe text was spliced straight over the `<table>…</table>`
    /// region. HTML's forgiving reparse reads that as a paragraph — a document
    /// that still parses, so there was no `EditConflict` to roll it back, and
    /// the table was gone.
    table_spelling: ?TableSpelling = null,

    /// What separates two BLOCKS of the same kind — the bytes `Editor.splitBlock`
    /// writes between the halves of a block it divides at the caret, after the
    /// enclosing container's blank-line prefix (`ContainerSpelling.blank`).
    ///
    /// A blank line in both formats that have one, which is why the value is a
    /// bare newline rather than a line of text: the algorithm has already
    /// written whatever prefix the line carries, and what makes the line a
    /// SEPARATOR is that nothing else follows it.
    ///
    /// `null` = this format does not divide blocks with a blank line, and
    /// `splitBlock` over it is `error.UnsupportedFormat`. HTML is why: its
    /// blocks are element pairs, so the newlines a split wrote landed INSIDE the
    /// `<p>` as insignificant whitespace — one paragraph in, one paragraph out,
    /// and a success reported for a gesture that had done nothing.
    block_separator: ?[]const u8 = null,

    /// The bytes a link's TEXT position must have backslash-escaped for the text
    /// to reparse as the literal string handed in. Each one either opens a
    /// construct that swallows the text — `*`/`_`/`` ` ``/`~`/`^` emphasis-ish
    /// runs, djot's `{…}` attributes and `"`/`'`/`-`/`.`/`:` smart punctuation,
    /// Markdown's `<…>` raw HTML and `&…;` entities — or breaks the brackets
    /// outright (`[`/`]`/`\`).
    ///
    /// The sets differ because the metacharacters do: djot has attributes and no
    /// entities, Markdown the reverse. Both read `\` + ASCII punctuation as that
    /// literal character, so an escape here is always safe, never a stray
    /// backslash.
    ///
    /// `null` = this format can't spell a link at all, and every link gesture
    /// over it reports unsupported.
    link_text_escapes: ?[]const u8 = null,

    /// How to escape a link's destination. `null` alongside a non-null
    /// `link_text_escapes` is a contradiction — see `assertCoherent`.
    link_dest_escapes: ?DestEscapes = null,

    /// The bytes a run of user-typed text must have backslash-escaped for the
    /// run to reparse as ITSELF in ordinary *body-text* position — the alphabet
    /// `Editor.insertLiteral` guards. These are the inline metacharacters that
    /// fire anywhere on a line: `*`/`_`/`` ` ``/`~`/`^` emphasis-ish runs, `[`/`]`
    /// link brackets, `\` itself, plus each format's own — Markdown's `<…>` raw
    /// HTML and `&…;` entities, djot's `{…}` attributes and `"`/`'`/`-`/`.`/`:`
    /// smart punctuation. A `\` before ASCII punctuation is that literal
    /// character in both formats, so an escape here is always safe.
    ///
    /// A sibling of `link_text_escapes`, not the same set: link text sits inside
    /// `[…]` where the brackets already bound it, while body text also opens
    /// blocks (see `block_start_escapes`) and is where a typed `<https://…>`
    /// would otherwise autolink. Over-escaping is safe (valid, just noisier
    /// source), so this errs wide — the Hidden-mode caller never shows the
    /// source. `null` = a parse-only format, so `insertLiteral` is
    /// `error.UnsupportedFormat`.
    text_escapes: ?[]const u8 = null,

    /// The bytes that only open a construct at a LINE START — block markers
    /// (`#`, `>`, `-`, `+`, table `|`, setext `=`…). `insertLiteral` escapes one
    /// only when the insertion point sits in the leading whitespace of its line;
    /// mid-line they are ordinary text and left alone, so a sentence's "5 - 3"
    /// keeps its `-`. Disjoint from `text_escapes` by construction: a byte that
    /// must be escaped everywhere lives there and needs no line-start entry here.
    /// `null` iff `text_escapes` is — see `assertCoherent`.
    block_start_escapes: ?[]const u8 = null,

    /// Whether `angled` — a `<dest>` run, BRACKETS INCLUDED — spells an
    /// autolink. `null` = this format has no autolink form.
    ///
    /// A function, not a table, because it must be asked of the format's OWN
    /// scanner (the one its parser dispatches on) rather than re-derived here,
    /// so it cannot drift from what a reparse will see. There is no shared rule
    /// to hoist: the formats genuinely disagree. Markdown wants an absolute URI
    /// (a 2-32 character `scheme:`) or a CommonMark email, and silently reads
    /// anything else as raw HTML (`<foo>` is a tag!) or literal text. Djot
    /// classifies on content alone — an `@` not preceded by `:` is an email,
    /// else a `letter:` is a url — which is why `mailto:a@b.dev` is a `url` in
    /// Markdown but an `email` in djot. Both refuse a relative path.
    spellsAutolink: ?*const fn (angled: []const u8) bool = null,

    /// How a hard break is spelled *inside a table cell*, where a row is a
    /// single source line so the ordinary newline spelling (`  \n`, djot's
    /// `\`+newline) can't appear. This is a distinct alphabet from the ordinary
    /// hard break precisely because the position forbids a line end: Markdown
    /// spells it `<br>` (raw HTML is valid inside a GFM cell), and the same
    /// `<br>` round-trips 1:1 because the parser reads it back as a `hard_break`
    /// in cell context (see `markdown/inline.zig`) and the serializer re-emits it
    /// from this field (see `markdown/serializer.zig`).
    ///
    /// `null` = this format has no in-cell break, so `Editor.insertLineBreak`
    /// inside a cell is `error.UnsupportedFormat`. Djot is `null` on purpose: it
    /// has no native in-cell break, and spelling one as `<br>` would emit
    /// non-idiomatic djot that any other djot reader renders as the literal text
    /// `<br>`. Unlike the other fields, a `null` here carries no coherence
    /// obligation — it neither implies nor is implied by any other spelling, so
    /// `assertCoherent` says nothing about it.
    cell_line_break: ?[]const u8 = null,

    /// Whether this format can be authored into at all — true once it can spell
    /// ANY one gesture, which is a weaker claim than it looks. HTML answers true
    /// on its inline marks alone while every block gesture over it is still
    /// unsupported, so this is a "is there a door in" predicate, not a
    /// capability report. `false` for a format that spells nothing (XML).
    /// For what a given format actually preserves per node kind, see
    /// `diagnostics.zig`'s measured fidelity table.
    pub fn authorable(self: *const Syntax) bool {
        return self.link_text_escapes != null or
            self.heading_marker != null or
            self.text_escapes != null or
            self.inline_delims.get(.strong) != null;
    }

    /// The delimiters for whatever node `ref` names, from whichever family
    /// table holds it — the one lookup a serializer needs, so it never has to
    /// know which family a kind belongs to. `null` = this format has no
    /// spelling for it.
    pub fn delimsFor(self: *const Syntax, ref: AST.KindRef) ?Delims {
        return switch (ref) {
            .mark => |m| self.inline_delims.get(m),
            .text_leaf => |l| self.text_leaf_delims.get(l),
            // A `markup_leaf` IS framed by a symmetric pair (`<!--`/`-->`,
            // `<![CDATA[`/`]]>`, …), but there is deliberately no table for
            // it: the only formats that spell one (XML, HTML) are parse-only
            // and carry no `Syntax` at all (see `format.zig`'s registry), no
            // editor gesture authors one, and HTML's `cdata` isn't even a
            // pair (it renders as escaped text). Each serializer's arm is the
            // SINGLE copy of those spellings, so a table here would create
            // the duplicate that `inline_delims` existed to remove. No
            // remaining `.tag` kind is spelled by a symmetric pair.
            // A `container_named` is never spelled by a symmetric pair either:
            // its name goes in the opener alone (`:::note` … `:::`), which is
            // `ContainerSpelling`'s job, not this table's.
            .markup_leaf, .tag, .container_named => null,
        };
    }

    /// `delimsFor` restricted to what an editor gesture may write — the
    /// serializer's question minus the emit-only spellings. See `Delims`.
    pub fn authorableDelimsFor(self: *const Syntax, ref: AST.KindRef) ?Delims {
        const d = self.delimsFor(ref) orelse return null;
        return if (d.authorable) d else null;
    }

    /// A `Syntax` literal is hand-maintained, so the invariants between its
    /// fields are checked once at startup rather than trusted at every call
    /// site — the same trust boundary `format.zig`'s registry relies on.
    pub fn assertCoherent(self: *const Syntax) void {
        // Text and destination escaping are two halves of spelling ONE link.
        // A format with one but not the other would build `[text](` and then
        // have nothing to say about what follows.
        std.debug.assert((self.link_text_escapes == null) == (self.link_dest_escapes == null));
        // The body-text and line-start alphabets are two halves of spelling ONE
        // literal run: a format that could escape mid-line specials but not
        // block markers (or vice versa) would let `insertLiteral` mint the other.
        std.debug.assert((self.text_escapes == null) == (self.block_start_escapes == null));
        // A checkbox is written after a bullet marker, so the two spellings are
        // one construct: `- ` + `[ ] `. A format with a checkbox and no bullet
        // list would have nowhere to put it.
        if (self.task_marker) |tm| {
            std.debug.assert(self.container_spelling.get(.bullet_list) != null);
            // Ticking a box overwrites it in place, so the two spellings must
            // be the same width or the item's text would shift.
            std.debug.assert(tm.checked.len == tm.unchecked.len);
        }
        // The reference half of a footnote is spelled TWICE — here, for the
        // gesture, and in `text_leaf_delims` for the serializer. Neither is
        // redundant (one authors a pair, the other prints a leaf), so the
        // duplicate is pinned rather than removed.
        if (self.footnote) |fs| {
            const d = self.text_leaf_delims.get(.footnote_reference).?;
            std.debug.assert(std.mem.eql(u8, d.open, fs.ref_open));
            std.debug.assert(std.mem.eql(u8, d.close, fs.ref_close));
        }
        // A table is re-spelled cell by cell between bars, so anything holding a
        // BAR outside a cell's content mints a column no row asked for — and the
        // rebuilt table would have a different shape from the grid it came from.
        // An empty delimiter cell is the same failure from the other side: a
        // delimiter row of bare bars isn't one, so the header would be lost.
        if (self.table_spelling) |ts| {
            std.debug.assert(ts.bar.len > 0);
            std.debug.assert(std.mem.indexOf(u8, ts.pad, ts.bar) == null);
            std.debug.assert(std.mem.indexOf(u8, ts.delim_pad, ts.bar) == null);
            for (std.enums.values(AST.Alignment)) |a| {
                const cell = ts.delim.get(a);
                std.debug.assert(cell.len > 0);
                std.debug.assert(std.mem.indexOf(u8, cell, ts.bar) == null);
            }
        }
        // `splitBlock` divides a block at the caret and gives BOTH halves the
        // same kind, which means re-spelling a heading's marker and closing and
        // reopening a code fence. A format that separated blocks but could spell
        // neither would make `Editor.supports(.split_block)` — a format-level
        // answer, given without a document — start lying the moment the caret
        // sat in a heading or a fence. That is the exact drift the capability
        // query exists to prevent, so it is pinned here rather than caveated
        // there.
        if (self.block_separator != null) {
            std.debug.assert(self.heading_marker != null);
            std.debug.assert(self.code_fence != null);
        }
    }
};

test "a parse-only format spells nothing" {
    const s = Syntax{};
    try std.testing.expect(!s.authorable());
    try std.testing.expect(s.inline_delims.get(.strong) == null);
    try std.testing.expect(s.container_spelling.get(.block_quote) == null);
    try std.testing.expect(s.heading_marker == null);
    try std.testing.expect(s.text_escapes == null);
    try std.testing.expect(s.block_start_escapes == null);
    try std.testing.expect(s.table_spelling == null);
    try std.testing.expect(s.block_separator == null);
    s.assertCoherent();
}
