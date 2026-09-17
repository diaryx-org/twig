//! What a format's *surface syntax* looks like — the spelling knowledge the
//! authoring gestures in `ast/editor.zig` need, and the only thing standing
//! between the language-agnostic `Splicer` and a working Cmd-B.
//!
//! ── Why this is a table and not a switch ───────────────────────────────────
//! Twig's formats are RAGGED: every one of them parses and renders, but they
//! author wildly different subsets — djot spells all eight inline marks,
//! Markdown four (`**`/`*`/`` ` ``/`~~`, and `==…==` where the parse config
//! reads it back), HTML spells seven as tag pairs and its blocks through a
//! renderer, AsciiDoc everything but a footnote and a table, XML none at
//! all. A `?Delims` per (format, kind) makes that raggedness DATA. The
//! alternative — a `switch (format)` per op, with an `else =>
//! unsupported_format` arm — is what the C ABI grew instead, and it put the
//! spelling of djot's `{=mark=}` behind an `extern` boundary where the CLI
//! couldn't reach it and only a C caller could test it.
//!
//! So: a `null` field means "this format has no spelling for that", and every
//! caller turns that into one uniform "unsupported" error. Exactly how
//! `format.zig`'s `TargetEntry.serializeFromAst: ?*const fn(...)` already says
//! "Twig cannot write that target yet".
//!
//! ── Why data, not behaviour ────────────────────────────────────────────────
//! Nearly everything here is a byte string or a flag. That's deliberate: the
//! *algorithms* — walk the destination escaping bytes, prefix each line of a
//! covered block — are format-INDEPENDENT and live once in `ast/editor.zig`.
//! Only the alphabet changes. Keeping the tables inert means a new format is a
//! `Syntax` literal, not new code paths.
//!
//! ── Where an alphabet cannot spell the edit: the renderers ─────────────────
//! Three fields are functions, not bytes, and they are the WHOLE list — see the
//! "Renderers" section of `Syntax`. Each exists because some format's spelling
//! is not a table at all:
//!
//!   * `spellsAutolink` has to run the format's own scanner.
//!   * `renderText` spells a literal run. Three formats spell one by writing a
//!     backslash before a byte from an alphabet, and they share ONE function for
//!     it (`renderTextByAlphabet`, below, reading `text_escapes`); HTML spells
//!     one with entities, which no alphabet can say.
//!   * `renderBlock` spells a node from a tree fragment. `Editor.setBlock`
//!     rewrites a leading marker where the format has one; where a heading is
//!     `<h2>…</h2>` there is no marker to rewrite, so the editor builds the
//!     node and asks the format to print it. The quote, list, code block,
//!     link and image gestures take the same path where their alphabet is
//!     missing.
//!
//! The engine still owns the algorithm — WHICH position a byte sits in, WHICH
//! node to build — and dispatches on presence: a `null` renderer is the same
//! uniform "unsupported" a `null` alphabet is. No renderer receives the editor,
//! performs a splice, or is called with a format's name. (Fig's editor grew the
//! same small family, for the same reason, once its last per-format hooks
//! turned out to be the spellings that were not a table.)
//!
//! `Syntax` names no format and imports no language module; `format.zig`'s
//! registry is what binds a `Format` to its `Syntax`, and `ast/editor.zig`
//! takes a `*const Syntax` without ever learning which format it came from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
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

/// Where a run of literal text is about to land — the one thing `renderText`
/// is told beyond the bytes. The EDITOR computes it from the tree and the
/// caret, and hands the renderer runs that never straddle two positions, so a
/// format spells each position without restating how they are told apart.
pub const TextPosition = enum {
    /// Ordinary prose, after other text on its line: the inline
    /// metacharacters bite (`*`, `` ` ``, `[`, `<`…), block markers do not.
    inline_text,
    /// A line's leading whitespace and the byte that ends it, where a block
    /// marker opens a block (`#`, `>`, `-`…) — so the inline alphabet AND the
    /// line-start alphabet bite. The editor slices a run so that this position
    /// covers exactly that zone: a run handed in here holds at most one
    /// non-whitespace byte, and it is the last.
    block_start,
    /// Inside a code span, a code block or a raw node, whose body the format
    /// reads without interpreting. A backslash format writes the bytes as they
    /// are; an entity format still escapes, because `<pre>` reads `&lt;` the
    /// same way `<p>` does.
    verbatim,
};

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
    ///
    /// It is a fact about a TABLE, not about a format: whether a spelling
    /// reparses can depend on the extensions the document is parsed with, and
    /// Markdown's two extension marks are that case in both directions —
    /// `==x==` is literal text until `highlight` is on, `~~x~~` is a `delete`
    /// until `strikethrough` is off. A format whose authorable subset moves
    /// with its parse config carries one table per answer and picks between
    /// them in `format.zig`'s `syntaxForConfig`; nothing here has to know that
    /// happened.
    authorable: bool = true,
};

/// How a format spells a COLOUR on an inline `mark` — the prefix that sits
/// between the mark's opening delimiter and its content, naming the colour the
/// node carries as an attribute.
///
/// Markdown's coloured highlights are the motivating spelling: `==🔴 text==`
/// is a `mark` whose content is `text` and whose `data-color` is `red`, with
/// the emoji stripped as SPELLING (see `languages/markdown/highlight.zig`,
/// which owns the vocabulary; this table is only how an editor writes it).
///
/// `null` = this format has no colour spelling for a mark, so
/// `Editor.setMarkColor` over it is `error.UnsupportedFormat`. That is every
/// format but Markdown-with-coloured-highlights today, and it is the honest
/// answer for two different reasons: djot and HTML spell a colour as an
/// ordinary attribute rather than a prefix (`{=x=}{.red}`, `<mark
/// class="red">`), which is a different gesture, and Markdown itself spells
/// none unless the parse config asks for one — the emoji is literal content
/// without `highlight_colors`, so an editor that wrote it would silently
/// change the text rather than colour it.
pub const MarkColors = struct {
    /// The attribute the colour rides in on the node — `data-color`. What
    /// `Editor` reads to know a mark's current colour, and what a caller names
    /// a colour by is the `Color.name` below, never this.
    attr_key: []const u8,
    /// Every colour this format spells, in the order a picker should offer
    /// them. A name outside this list is `error.InvalidColor` rather than a
    /// prefix written blind: an unknown emoji is content, and writing one
    /// would edit the highlighted text.
    colors: []const Color,
    /// Written between the prefix and the content. The parser absorbs at most
    /// one, and a tight `==🔴text==` means the same thing, so this is what a
    /// gesture WRITES rather than what it requires — an existing prefix keeps
    /// whatever spacing its author gave it.
    space: []const u8 = " ",

    /// One colour: the attribute value, and the bytes that spell it.
    pub const Color = struct {
        /// The value stored in `attr_key` — `red`. The name a caller passes.
        name: []const u8,
        /// The source bytes written after the opening delimiter — `🔴`.
        prefix: []const u8,
    };

    /// The bytes that spell `name`, or `null` when this format has no colour
    /// by that name.
    pub fn prefixFor(self: *const MarkColors, name: []const u8) ?[]const u8 {
        for (self.colors) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.prefix;
        }
        return null;
    }

    /// The colour whose prefix opens `s`, if any — the read half, used to
    /// recognize a prefix already in the source. Matches the LONGEST prefix,
    /// so a vocabulary where one spelling extends another still reads back the
    /// spelling that was written.
    pub fn prefixAt(self: *const MarkColors, s: []const u8) ?Color {
        var found: ?Color = null;
        for (self.colors) |c| {
            if (c.prefix.len == 0) continue;
            if (!std.mem.startsWith(u8, s, c.prefix)) continue;
            if (found == null or c.prefix.len > found.?.prefix.len) found = c;
        }
        return found;
    }
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

/// The `renderText` of every format that spells a literal by writing a
/// backslash before a byte from an alphabet — Markdown, djot and AsciiDoc,
/// which differ only in `text_escapes`/`block_start_escapes` and share this
/// one function.
/// In `verbatim` position the bytes are written as they are: a backslash there
/// is a backslash, not an escape, in all three.
///
/// This is the algorithm `ast/editor.zig` used to hold. It moved here so that
/// the editor asks one question of every format — `renderText` — and so that
/// the alphabets are read in exactly one place, next to their definition.
pub fn renderTextByAlphabet(
    syntax: *const Syntax,
    text: []const u8,
    position: TextPosition,
    out: *Writer,
) Writer.Error!void {
    // `assertCoherent` pins both non-null wherever this is the renderer.
    const inline_escapes = syntax.text_escapes.?;
    const block_escapes = syntax.block_start_escapes.?;
    for (text) |c| {
        const escape = switch (position) {
            .verbatim => false,
            .inline_text => std.mem.indexOfScalar(u8, inline_escapes, c) != null,
            .block_start => std.mem.indexOfScalar(u8, inline_escapes, c) != null or
                std.mem.indexOfScalar(u8, block_escapes, c) != null,
        };
        if (escape) try out.writeByte('\\');
        try out.writeByte(c);
    }
}

/// A `renderBlock` made from a whole-tree serializer: the fragment is the
/// tree re-rooted at `root`, which is all a `serializeAstAlloc` needs to
/// print exactly that node and its descendants. The three lightweight formats
/// build theirs from this; HTML's serializer prints a node directly and needs
/// no adapter.
pub fn renderBlockVia(
    comptime serializeAstAlloc: fn (Allocator, *const AST) Allocator.Error![]u8,
) *const fn (Allocator, *const AST, AST.Node.Id, *Writer) anyerror!void {
    return &struct {
        fn render(allocator: Allocator, ast: *const AST, root: AST.Node.Id, out: *Writer) anyerror!void {
            // A shallow copy: the arena and strings are still `ast`'s, and this
            // value is never `deinit`ed.
            var fragment = ast.*;
            fragment.root = root;
            const text = try serializeAstAlloc(allocator, &fragment);
            defer allocator.free(text);
            try out.writeAll(text);
        }
    }.render;
}

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

    /// How a colour is spelled on an inline `mark`. `null` = this format has
    /// no colour spelling, so `Editor.setMarkColor` is unsupported. See
    /// `MarkColors`.
    mark_colors: ?MarkColors = null,

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
    /// source. Read by `renderTextByAlphabet` and nothing else: a format that
    /// states an alphabet sets `renderText` to that function, and a format
    /// that spells a literal some other way (HTML) states no alphabet at all —
    /// see `assertCoherent`. `null` alone says nothing about whether a literal
    /// can be spelled; `renderText` does.
    text_escapes: ?[]const u8 = null,

    /// The bytes that only open a construct at a LINE START — block markers
    /// (`#`, `>`, `-`, `+`, table `|`, setext `=`…). `insertLiteral` escapes one
    /// only when the insertion point sits in the leading whitespace of its line;
    /// mid-line they are ordinary text and left alone, so a sentence's "5 - 3"
    /// keeps its `-`. Disjoint from `text_escapes` by construction: a byte that
    /// must be escaped everywhere lives there and needs no line-start entry here.
    /// `null` iff `text_escapes` is — see `assertCoherent`.
    block_start_escapes: ?[]const u8 = null,

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

    // ── Renderers ──────────────────────────────────────────────────────────
    // The spellings that are not a table. Every field above is bytes an
    // algorithm in `ast/editor.zig` writes; each field here is the algorithm's
    // last step handed to the format, for the cases where no alphabet could
    // say it. They are dispatched by presence exactly as the alphabets are —
    // `null` is "unsupported", through the one uniform path — and the module
    // doc comment says why there are three and not thirty.

    /// Spell `text` so that it reparses as ITSELF in `position` — the format
    /// half of `Editor.insertLiteral`. `null` = this format cannot spell a
    /// literal, so `insertLiteral` is `error.UnsupportedFormat`.
    ///
    /// The editor decides the position and slices the run (see
    /// `TextPosition`); the renderer only ever answers "how are these bytes
    /// written here". A format whose answer is "a backslash before a byte from
    /// an alphabet" sets this to `renderTextByAlphabet` and states the
    /// alphabet in `text_escapes`/`block_start_escapes`; `assertCoherent` pins
    /// the three together. A format whose answer is anything else — HTML's
    /// entities — writes its own, and carries no alphabet.
    renderText: ?*const fn (
        syntax: *const Syntax,
        text: []const u8,
        position: TextPosition,
        out: *Writer,
    ) Writer.Error!void = null,

    /// Spell the node `root` of `ast`, descendants included, as this format's
    /// source — a fragment printed by the format's own serializer. `null` =
    /// this format cannot print a fragment.
    ///
    /// The editor reaches for this where a gesture has no alphabet to write:
    /// `setBlock` over a format with no `heading_marker` builds a heading node
    /// over the block's inline children, renders it here, and splices what
    /// comes back; `toggleBlockContainer`, `toggleCodeBlock`,
    /// `setCodeLanguage`, `insertLink` and `insertImage` do the same with a
    /// quote, a list, a code block, a link and an image where their alphabet
    /// is missing. The root is usually a block, and a `link` or `image` when
    /// it is not; every renderer prints whatever node it is given. For every
    /// format with a from-AST serializer this is that serializer over the
    /// fragment (`renderBlockVia`), which is what makes a tag-pair heading
    /// authorable without teaching the editor about tags.
    ///
    /// Where a format HAS an alphabet the editor keeps using it, because the
    /// alphabet path preserves the covered bytes verbatim while this one
    /// re-spells them from the tree. So carrying this alongside an alphabet
    /// moves nothing; it is the answer for the formats that have no other.
    renderBlock: ?*const fn (
        allocator: Allocator,
        ast: *const AST,
        root: AST.Node.Id,
        out: *Writer,
    ) anyerror!void = null,

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

    /// Whether this format can be authored into at all — true once it can spell
    /// ANY one gesture, which is a weaker claim than it looks. HTML answers true
    /// while a task box, a footnote and every table edit over it are still
    /// unsupported, so this is a "is there a door in" predicate, not a
    /// capability report. `false` for a format that spells nothing (XML).
    /// For what a given format actually preserves per node kind, see
    /// `diagnostics.zig`'s measured fidelity table.
    pub fn authorable(self: *const Syntax) bool {
        return self.link_text_escapes != null or
            self.heading_marker != null or
            self.renderText != null or
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
        // An alphabet is read by exactly one renderer, and that renderer reads
        // nothing else: a table that stated an alphabet and pointed `renderText`
        // elsewhere would carry a spelling nothing consults, and one that named
        // the alphabet renderer without an alphabet would fail on first use
        // rather than here.
        std.debug.assert((self.text_escapes != null) == (self.renderText == &renderTextByAlphabet));
        // A checkbox is written after a bullet marker, so the two spellings are
        // one construct: `- ` + `[ ] `. A format with a checkbox and no bullet
        // list would have nowhere to put it.
        if (self.task_marker) |tm| {
            std.debug.assert(self.container_spelling.get(.bullet_list) != null);
            // Ticking a box overwrites it in place, so the two spellings must
            // be the same width or the item's text would shift.
            std.debug.assert(tm.checked.len == tm.unchecked.len);
        }
        // A colour prefix is written INSIDE a mark, so a format that spells one
        // must spell the mark itself — and must be able to author it, since a
        // table where the colour gesture worked and the highlight gesture did
        // not would offer a palette for a construct its own editor cannot
        // make. (Markdown's two tables are exactly this pair moving together:
        // `highlight` makes the mark authorable, `highlight_colors` adds the
        // palette on top.)
        if (self.mark_colors) |mc| {
            std.debug.assert(mc.attr_key.len > 0);
            std.debug.assert(mc.colors.len > 0);
            std.debug.assert(mc.space.len > 0);
            const d = self.inline_delims.get(.mark);
            std.debug.assert(d != null and d.?.authorable);
            for (mc.colors, 0..) |c, i| {
                std.debug.assert(c.name.len > 0);
                std.debug.assert(c.prefix.len > 0);
                // A prefix that began with the space would make the written
                // form and the tight form indistinguishable on the way back in.
                std.debug.assert(!std.mem.startsWith(u8, c.prefix, mc.space));
                // Two colours spelled or named the same way would make
                // `prefixAt`/`prefixFor` depend on table order.
                for (mc.colors[i + 1 ..]) |o| {
                    std.debug.assert(!std.mem.eql(u8, c.prefix, o.prefix));
                    std.debug.assert(!std.mem.eql(u8, c.name, o.name));
                }
            }
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
    try std.testing.expect(s.renderText == null);
    try std.testing.expect(s.renderBlock == null);
    try std.testing.expect(s.table_spelling == null);
    try std.testing.expect(s.block_separator == null);
    s.assertCoherent();
}
