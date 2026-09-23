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
//! ── The line model ─────────────────────────────────────────────────────────
//! Every gesture that touches block structure assumes one shape of source,
//! and a format authored through this table has to have it. It was implicit
//! while every table was compiled beside the parser it described; a runtime
//! language's author gets it written down:
//!
//!   * Source is a sequence of LINES ended by `\n`. A `\r` before one is kept
//!     and ignored, never written.
//!   * A block begins at a line start. A marker (`heading_marker`, a
//!     container's `marker`, a task box, a footnote definition) is written at
//!     the start of the block's first line, after the enclosing containers'
//!     prefixes.
//!   * A container is a PREFIX on every line it covers: `marker` on a block's
//!     first line, `cont` on its continuation lines, `blank` on an empty line
//!     inside it. Nesting concatenates prefixes, outermost first, so a
//!     container never has to know what it is inside of.
//!   * Two blocks are kept apart by `block_separator` written after the
//!     prefix, and one block continues onto its next line by `line_join` —
//!     each ends in its only line end. A thematic break, a fence and a table
//!     row are each one whole line.
//!   * Everything written inside a line — delimiters, markers, boxes, a
//!     table's skeleton, an in-cell break — holds no line end.
//!
//! A format whose blocks are delimited fragments rather than lines (HTML's
//! element pairs) states none of the line spellings and reaches the same
//! gestures through `renderBlock`, which prints whole fragments. What it
//! cannot do is state a line spelling it does not mean. `Syntax.validate`
//! holds a table to the rules above that are facts about its bytes, and
//! `languages/harness.zig` holds it to the ones that are facts about its
//! parser.
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

    /// What continues a BLOCK onto its NEXT LINE — the bytes
    /// `Editor.joinBlocks` writes between the two halves it merges, after the
    /// container prefix its first half's line carries.
    ///
    /// The mirror of `block_separator`, and deliberately a second field rather
    /// than a derivation from it: a split has to end one block and open
    /// another, a join has to stay INSIDE one, and the two are not the same
    /// question in every format. HTML is the case that proves it — a blank
    /// line there is insignificant whitespace, so `block_separator` is `null`
    /// and `splitBlock` refuses, while a newline inside a `<p>` is exactly the
    /// line break a join needs and reparses as one paragraph. Every format
    /// twig authors spells this `"\n"`; a format whose blocks cannot span
    /// lines at all would spell it `null`, and so does a parse-only table,
    /// which is what makes `Editor.supports(.join_blocks)` false for XML.
    ///
    /// One implication hangs off it, and only in the one direction:
    /// `block_separator != null` implies this is non-null, because a blank
    /// line between two blocks is a line join and one line end more. The
    /// converse is false — HTML joins where it cannot split — which is the
    /// whole reason this is a second field. Nothing else a join needs is
    /// pinned here: the container prefix, a heading's own marker and the
    /// closing markup it carries past the joined text are read out of the
    /// DOCUMENT, never re-spelled from this table.
    line_join: ?[]const u8 = null,

    /// The line that ATTACHES a block to a list item's tail where the item's
    /// continuation indent does not — AsciiDoc's `+`, written on a line of
    /// its own between the item's text and the block that follows it.
    ///
    /// `null` = a block is inside an item by standing behind the item's
    /// continuation indent after a blank line, which is Markdown's and djot's
    /// rule and needs nothing from this table: `Editor.moveBlock` reads the
    /// indent off the item's marker. AsciiDoc is the one format where that
    /// spelling means something else — an indented line after a blank is a
    /// LITERAL paragraph — so a block landing in an item's tail there is
    /// written at column zero under a `+` line, and a block leaving one takes
    /// that line with it. The value is the line's text without its line end.
    list_attach: ?[]const u8 = null,

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

    /// Whether a NAMED LEAF CONTAINER — a `container` with `form =
    /// .block_leaf` and a `name` — printed through `renderBlock` reparses to a
    /// container that still carries that name: as the node's own `name`
    /// (Markdown's `::name`, HTML's `<name></name>`), or as a `class`
    /// attribute where the format has nowhere else to put it (djot's `:::`
    /// fence is anonymous and carries its identity as a class; AsciiDoc spells
    /// one it has no macro for as an open block whose STYLE is the name, which
    /// parses back as a class too).
    ///
    /// THE NAME is the whole of the claim; the attributes survive only where
    /// the format's spelling has room for them. AsciiDoc is the case that
    /// forces the distinction: a name it spells NATIVELY is written in that
    /// native form, and `page-break` is `<<<`, which has nowhere to put a
    /// `src` — the name comes back, the attributes do not. Nor is the reparsed
    /// `form` part of it (HTML classifies only `div` and `span`, so an unknown
    /// element comes back with `form = null`), nor the label, which only
    /// Markdown and djot keep, nor the name's CASE, which HTML folds.
    ///
    /// `false` = printing one would mint bytes the parser hands back as
    /// something else — Markdown without its directives extension reads
    /// `::name` as a paragraph of literal text — so `Editor.insertDirective`
    /// is `error.UnsupportedFormat` there. That is the same rule
    /// `Delims.authorable` states for `==mark==`, which is why this claim is a
    /// field rather than a property of the renderer: it moves with the PARSE
    /// CONFIG, and Markdown's table set states it per option combination (see
    /// `markdown/syntax.zig`'s `forOptions`).
    ///
    /// Measured rather than asserted: `languages/harness.zig` prints a named
    /// leaf fragment through every table that makes this claim and reparses
    /// the print. Implies `renderBlock != null` — there is no other way to
    /// print one — which `assertCoherent` pins.
    names_leaf_containers: bool = false,

    /// How a BLOCK carrying attributes — a paragraph with a class, an id and
    /// a `data-` key — printed through `renderBlock` reparses: to the same
    /// kind carrying them (`native`), or to a container whose SOLE CHILD is
    /// that kind and which carries them (`wrapped`, Markdown's shape — a
    /// `<div>` around the block, read back under `html_elements`). `null` =
    /// the attributes do not come back, so `Editor.setBlockAttrs` is
    /// `error.UnsupportedFormat`. The same rule as `names_leaf_containers`:
    /// a claim about a TABLE, moving with the parse config where the parser
    /// does, measured by `languages/harness.zig` rather than asserted, and
    /// implying `renderBlock != null`, which `assertCoherent` pins.
    block_attrs: ?BlockAttrs = null,

    /// Whether a node's attributes live on the node's OWN opening spelling,
    /// at the span its parser records (`Document.attrsSpan`), written as a
    /// tag interior — XML's ` key="value"` run, with `&`, `<`, `>` and `"`
    /// as entities — so `Editor.setNodeAttrs` can rewrite that span alone
    /// and leave every other byte of the node, its children included, where
    /// it is. `null` = the gesture is `error.UnsupportedFormat`.
    ///
    /// The node-addressed sibling of `block_attrs`, and a different claim:
    /// that one finds a BLOCK by offset and re-prints it or rewrites the
    /// line before it, which is what a caret editor over prose wants; this
    /// one takes a node id and splices, because the caller that wants it
    /// holds a tree and not a caret — a canvas editor over an SVG names the
    /// shape it is dragging, and no byte position stands for it. Measured
    /// by `languages/harness.zig` rather than asserted: an element of every
    /// sample, given `claim_attrs`, reparses carrying them, and given none
    /// reparses carrying none.
    node_attrs: ?NodeAttrs = null,

    /// Whether an ANONYMOUS INLINE CONTAINER carrying attributes, printed
    /// through `renderBlock`, reparses to an inline container carrying them —
    /// anonymous (djot's `[text]{…}`) or named `span` (HTML's and Markdown's
    /// tag), which `Editor.wrapRangeAttrs` treats as one node. `false` = it
    /// does not, so the gesture is unsupported. AsciiDoc answers false: its
    /// `[#id.role]#text#` keeps an id and a role and has no slot for a third
    /// key, and a gesture that silently dropped one is what the gate is for.
    /// Measured like `block_attrs`; implies `renderBlock != null`.
    inline_attrs: bool = false,

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

    /// Whether the invariants between this table's fields hold — the rules
    /// every gesture in `ast/editor.zig` takes on trust, stated once. On the
    /// first that fails, `why` (when given) says which rule and which field,
    /// and the answer is `error.Incoherent`.
    ///
    /// A compiled table is checked at comptime (`comptimeCheck`), so a literal
    /// that breaks a rule fails its build; a table read from a runtime
    /// language's description is checked here at registration, so it is
    /// refused with the rule's name rather than trusted into an assert. The
    /// rules are the same list either way — that is the point of there being
    /// one function.
    ///
    /// Two families. The implications between fields are the older half:
    /// what one gesture writes, another field has to be able to finish. The
    /// well-formedness rules are the line model (see the module doc) stated
    /// as data: a spelling the editor writes inside one line never holds a
    /// line end, and the two that write line ends are nothing else.
    pub fn validate(self: *const Syntax, why: ?*Incoherence) error{Incoherent}!void {
        const fail = struct {
            fn f(w: ?*Incoherence, rule: Rule, field: []const u8) error{Incoherent} {
                if (w) |p| p.* = .{ .rule = rule, .field = field };
                return error.Incoherent;
            }
        }.f;

        // ── Implications ───────────────────────────────────────────────────

        // Text and destination escaping are two halves of spelling ONE link.
        // A format with one but not the other would build `[text](` and then
        // have nothing to say about what follows.
        if ((self.link_text_escapes == null) != (self.link_dest_escapes == null))
            return fail(why, .link_halves, "link_text_escapes");
        // The body-text and line-start alphabets are two halves of spelling ONE
        // literal run: a format that could escape mid-line specials but not
        // block markers (or vice versa) would let `insertLiteral` mint the other.
        if ((self.text_escapes == null) != (self.block_start_escapes == null))
            return fail(why, .literal_halves, "text_escapes");
        // An alphabet is read by exactly one renderer, and that renderer reads
        // nothing else: a table that stated an alphabet and pointed `renderText`
        // elsewhere would carry a spelling nothing consults, and one that named
        // the alphabet renderer without an alphabet would fail on first use
        // rather than here.
        if ((self.text_escapes != null) != (self.renderText == &renderTextByAlphabet))
            return fail(why, .alphabet_renderer, "renderText");
        // A checkbox is written after a bullet marker, so the two spellings are
        // one construct: `- ` + `[ ] `. A format with a checkbox and no bullet
        // list would have nowhere to put it.
        if (self.task_marker) |tm| {
            if (self.container_spelling.get(.bullet_list) == null)
                return fail(why, .task_needs_bullet, "task_marker");
            // Ticking a box overwrites it in place, so the two spellings must
            // be the same width or the item's text would shift.
            if (tm.checked.len != tm.unchecked.len)
                return fail(why, .task_widths, "task_marker.checked");
        }
        // A colour prefix is written INSIDE a mark, so a format that spells one
        // must spell the mark itself — and must be able to author it, since a
        // table where the colour gesture worked and the highlight gesture did
        // not would offer a palette for a construct its own editor cannot
        // make. (Markdown's two tables are exactly this pair moving together:
        // `highlight` makes the mark authorable, `highlight_colors` adds the
        // palette on top.)
        if (self.mark_colors) |mc| {
            if (mc.attr_key.len == 0) return fail(why, .colors_spelling, "mark_colors.attr_key");
            if (mc.colors.len == 0) return fail(why, .colors_spelling, "mark_colors.colors");
            if (mc.space.len == 0) return fail(why, .colors_spelling, "mark_colors.space");
            const d = self.inline_delims.get(.mark);
            if (d == null or !d.?.authorable) return fail(why, .colors_need_mark, "mark_colors");
            for (mc.colors, 0..) |c, i| {
                if (c.name.len == 0 or c.prefix.len == 0)
                    return fail(why, .colors_spelling, "mark_colors.colors");
                // A prefix that began with the space would make the written
                // form and the tight form indistinguishable on the way back in.
                if (std.mem.startsWith(u8, c.prefix, mc.space))
                    return fail(why, .colors_spelling, "mark_colors.colors");
                // Two colours spelled or named the same way would make
                // `prefixAt`/`prefixFor` depend on table order.
                for (mc.colors[i + 1 ..]) |o| {
                    if (std.mem.eql(u8, c.prefix, o.prefix) or std.mem.eql(u8, c.name, o.name))
                        return fail(why, .colors_duplicate, "mark_colors.colors");
                }
            }
        }
        // The reference half of a footnote is spelled TWICE — here, for the
        // gesture, and in `text_leaf_delims` for the serializer. Neither is
        // redundant (one authors a pair, the other prints a leaf), so the
        // duplicate is pinned rather than removed.
        if (self.footnote) |fs| {
            const d = self.text_leaf_delims.get(.footnote_reference) orelse
                return fail(why, .footnote_halves, "text_leaf_delims.footnote_reference");
            if (!std.mem.eql(u8, d.open, fs.ref_open) or !std.mem.eql(u8, d.close, fs.ref_close))
                return fail(why, .footnote_halves, "footnote.ref_open");
        }
        // A table is re-spelled cell by cell between bars, so anything holding a
        // BAR outside a cell's content mints a column no row asked for — and the
        // rebuilt table would have a different shape from the grid it came from.
        // An empty delimiter cell is the same failure from the other side: a
        // delimiter row of bare bars isn't one, so the header would be lost.
        if (self.table_spelling) |ts| {
            if (ts.bar.len == 0) return fail(why, .table_bar, "table_spelling.bar");
            if (std.mem.indexOf(u8, ts.pad, ts.bar) != null) return fail(why, .table_bar, "table_spelling.pad");
            if (std.mem.indexOf(u8, ts.delim_pad, ts.bar) != null) return fail(why, .table_bar, "table_spelling.delim_pad");
            for (std.enums.values(AST.Alignment)) |a| {
                const cell = ts.delim.get(a);
                if (cell.len == 0 or std.mem.indexOf(u8, cell, ts.bar) != null)
                    return fail(why, .table_bar, "table_spelling.delim");
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
            if (self.heading_marker == null) return fail(why, .split_needs_markers, "heading_marker");
            if (self.code_fence == null) return fail(why, .split_needs_markers, "code_fence");
            // And it can continue one onto its next line. A block separator IS
            // a line join and one line end more — the blank line between two
            // blocks is the terminator of the first plus an empty line — so a
            // format that could end a block but not continue one would be
            // spelling the wider gesture out of the narrower one's parts while
            // reporting the narrower unsupported. `Editor.supports` would then
            // offer a caret editor an Enter with no Backspace. The implication
            // is one-way: HTML joins where it cannot split, which is the whole
            // reason `line_join` is a second field.
            if (self.line_join == null) return fail(why, .split_needs_join, "line_join");
        }
        // A named leaf container has exactly one way to reach the source — the
        // fragment renderer — so a table claiming the reparse without carrying
        // the printer states a promise nothing could keep. The two attribute
        // claims rest on the same renderer.
        if (self.renderBlock == null) {
            if (self.names_leaf_containers) return fail(why, .claim_needs_renderer, "names_leaf_containers");
            if (self.block_attrs != null) return fail(why, .claim_needs_renderer, "block_attrs");
            if (self.inline_attrs) return fail(why, .claim_needs_renderer, "inline_attrs");
        }

        // ── Well-formedness: the line model ─────────────────────────────────

        // A delimiter pair is written around a run inside one line, and an
        // empty one would wrap nothing the reparse could find.
        for (std.enums.values(AST.InlineMark)) |m| {
            const d = self.inline_delims.get(m) orelse continue;
            if (!inLine(d.open, false) or !inLine(d.close, false)) return fail(why, .inline_spelling, "inline_delims");
        }
        for (std.enums.values(AST.TextLeafKind)) |k| {
            const d = self.text_leaf_delims.get(k) orelse continue;
            if (!inLine(d.open, false) or !inLine(d.close, false)) return fail(why, .inline_spelling, "text_leaf_delims");
        }
        // A container is a prefix on every line it covers. Only a numbered
        // list may leave its marker empty, since that one is built per item.
        for (std.enums.values(ContainerKind)) |k| {
            const c = self.container_spelling.get(k) orelse continue;
            if (!inLine(c.marker, c.numbered) or !inLine(c.cont, true) or !inLine(c.blank, true))
                return fail(why, .line_spelling, "container_spelling");
        }
        if (self.heading_marker) |h| {
            if (!visible(h)) return fail(why, .line_spelling, "heading_marker");
        }
        if (self.thematic_break) |t| {
            if (!inLine(t, false)) return fail(why, .line_spelling, "thematic_break");
        }
        if (self.code_fence) |f| {
            if (!visible(f.char) or f.min == 0) return fail(why, .line_spelling, "code_fence");
        }
        if (self.task_marker) |tm| {
            if (!inLine(tm.unchecked, false) or !inLine(tm.checked, false) or !inLine(tm.space, true))
                return fail(why, .line_spelling, "task_marker");
        }
        if (self.footnote) |fs| {
            if (!inLine(fs.def_suffix, true)) return fail(why, .line_spelling, "footnote.def_suffix");
        }
        if (self.table_spelling) |ts| {
            // A pipe table's row is one line: nothing in its skeleton may end one.
            if (!inLine(ts.bar, false) or !inLine(ts.pad, true) or !inLine(ts.delim_pad, true))
                return fail(why, .line_spelling, "table_spelling");
            for (std.enums.values(AST.Alignment)) |a| {
                if (!inLine(ts.delim.get(a), false)) return fail(why, .line_spelling, "table_spelling.delim");
            }
        }
        if (self.list_attach) |l| {
            if (!inLine(l, false)) return fail(why, .line_spelling, "list_attach");
        }
        if (self.cell_line_break) |b| {
            if (!inLine(b, false)) return fail(why, .line_spelling, "cell_line_break");
        }
        // The two spellings that write line ends write them at the END: what
        // precedes the last is the container prefix the editor has already
        // written, and nothing a format adds after it.
        if (self.block_separator) |s| {
            if (!endsLine(s)) return fail(why, .line_end_spelling, "block_separator");
        }
        if (self.line_join) |s| {
            if (!endsLine(s)) return fail(why, .line_end_spelling, "line_join");
        }
        // An escape is a backslash before the byte, which reads back as that
        // byte only where the byte is punctuation. And the two literal
        // alphabets are disjoint: a byte escaped everywhere needs no
        // line-start entry, and one in both is a table that forgot which.
        if (self.text_escapes) |te| {
            if (!punctuation(te)) return fail(why, .alphabet_byte, "text_escapes");
            const bse = self.block_start_escapes.?;
            if (!punctuation(bse)) return fail(why, .alphabet_byte, "block_start_escapes");
            for (te) |c| {
                if (std.mem.indexOfScalar(u8, bse, c) != null) return fail(why, .alphabets_overlap, "block_start_escapes");
            }
        }
        if (self.link_text_escapes) |e| {
            if (!punctuation(e)) return fail(why, .alphabet_byte, "link_text_escapes");
        }
        if (self.link_dest_escapes) |d| {
            if (!punctuation(d.plain)) return fail(why, .alphabet_byte, "link_dest_escapes.plain");
            if (d.angle) |a| {
                if (!punctuation(a.escapes)) return fail(why, .alphabet_byte, "link_dest_escapes.angle");
            }
        }
    }

    /// `validate` for a table a build already trusts: a compiled row, checked
    /// once where it is defined. Fails the BUILD with the rule's name when
    /// run at comptime, and panics with it at runtime.
    pub fn assertCoherent(self: *const Syntax) void {
        var why: Incoherence = .{};
        self.validate(&why) catch {
            if (@inComptime()) @compileError("incoherent Syntax: " ++ why.field ++ ": " ++ why.rule.describe());
            std.debug.panic("incoherent Syntax: {s}: {s}", .{ why.field, why.rule.describe() });
        };
    }
};

/// Which of `Syntax.validate`'s rules a table broke, and where.
pub const Incoherence = struct {
    rule: Rule = .link_halves,
    /// The field, as the description spells it (`task_marker.checked`).
    field: []const u8 = "",
};

/// `Syntax.validate`'s rules, by name.
pub const Rule = enum {
    link_halves,
    literal_halves,
    alphabet_renderer,
    task_needs_bullet,
    task_widths,
    colors_spelling,
    colors_need_mark,
    colors_duplicate,
    footnote_halves,
    table_bar,
    split_needs_markers,
    split_needs_join,
    claim_needs_renderer,
    inline_spelling,
    line_spelling,
    line_end_spelling,
    alphabet_byte,
    alphabets_overlap,

    pub fn describe(rule: Rule) []const u8 {
        return switch (rule) {
            .link_halves => "a link's text and destination alphabets come together or not at all",
            .literal_halves => "the body-text and line-start alphabets come together or not at all",
            .alphabet_renderer => "a text alphabet is read by the alphabet renderer, and a format with none renders literals itself",
            .task_needs_bullet => "a task checkbox rides on a bullet item, so a bullet list must be spelled",
            .task_widths => "the checked and unchecked boxes must be the same width",
            .colors_spelling => "a mark colour needs a key, a space, and colours each with a name and a prefix not starting with the space",
            .colors_need_mark => "a mark colour is written inside a mark this table can author",
            .colors_duplicate => "two mark colours share a name or a prefix",
            .footnote_halves => "a footnote's reference is spelled as its text leaf is",
            .table_bar => "a table's bar is non-empty and appears in no padding or delimiter cell, and no delimiter cell is empty",
            .split_needs_markers => "a format that splits blocks spells a heading marker and a code fence",
            .split_needs_join => "a format that splits blocks can join them",
            .claim_needs_renderer => "a directive or attribute claim needs a block renderer to print through",
            .inline_spelling => "an inline delimiter is non-empty and holds no line end",
            .line_spelling => "a spelling written inside a line holds no line end, and a marker is not empty",
            .line_end_spelling => "a block separator or line join ends in its only line end",
            .alphabet_byte => "an escape alphabet holds only ASCII punctuation",
            .alphabets_overlap => "a byte escaped everywhere is not also a line-start escape",
        };
    }
};

/// Whether `s` fits inside one line: no line end, and non-empty unless
/// `may_be_empty`.
fn inLine(s: []const u8, may_be_empty: bool) bool {
    if (s.len == 0) return may_be_empty;
    return std.mem.indexOfAny(u8, s, "\r\n") == null;
}

/// A marker byte a reparse can see: printable ASCII and not a space.
fn visible(c: u8) bool {
    return c > ' ' and c < 0x7f;
}

/// Ends in `\n`, with no line end before it.
fn endsLine(s: []const u8) bool {
    if (s.len == 0 or s[s.len - 1] != '\n') return false;
    return std.mem.indexOfAny(u8, s[0 .. s.len - 1], "\r\n") == null;
}

/// Every byte is ASCII punctuation — what a backslash escape reads back as
/// itself in every backslash format twig knows.
fn punctuation(s: []const u8) bool {
    for (s) |c| {
        if (!visible(c) or std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

/// How a node's own attributes are spelled — see `Syntax.node_attrs`. The
/// run itself is `attrs_writer.writeHtmlAttrs`'s and is not a field here: a
/// tag interior is the one shape a recorded attribute span has ever held,
/// and a second spelling earns a field when a parser records one.
pub const NodeAttrs = struct {
    /// What the node's opening spelling begins with, before its name — the
    /// `<` of a tag. The first attribute of a node that has none is inserted
    /// `open.len + name.len` bytes into the node, where the parser reads it.
    open: []const u8 = "<",
};

/// The shape a block's attributes come back in — see `Syntax.block_attrs`.
pub const BlockAttrs = enum {
    /// On the block itself: djot's `{…}` line, HTML's tag, AsciiDoc's `[…]`.
    native,
    /// On a container whose sole child is the block: Markdown's `<div>`.
    wrapped,
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
    try std.testing.expect(!s.names_leaf_containers);
    try std.testing.expect(s.block_attrs == null);
    try std.testing.expect(!s.inline_attrs);
    s.assertCoherent();
}

test "validate names the rule a table breaks" {
    var why: Incoherence = .{};
    const half_link: Syntax = .{ .link_text_escapes = "[]" };
    try std.testing.expectError(error.Incoherent, half_link.validate(&why));
    try std.testing.expectEqual(Rule.link_halves, why.rule);

    const split_alone: Syntax = .{ .block_separator = "\n", .line_join = "\n" };
    try std.testing.expectError(error.Incoherent, split_alone.validate(&why));
    try std.testing.expectEqual(Rule.split_needs_markers, why.rule);
    try std.testing.expectEqualStrings("heading_marker", why.field);

    const two_lines: Syntax = .{ .thematic_break = "-\n-" };
    try std.testing.expectError(error.Incoherent, two_lines.validate(&why));
    try std.testing.expectEqual(Rule.line_spelling, why.rule);

    var marks: std.EnumArray(AST.InlineMark, ?Delims) = .initFill(null);
    marks.set(.strong, .{ .open = "", .close = "*" });
    const empty_open: Syntax = .{ .inline_delims = marks };
    try std.testing.expectError(error.Incoherent, empty_open.validate(&why));
    try std.testing.expectEqual(Rule.inline_spelling, why.rule);

    const letter_escape: Syntax = .{ .text_escapes = "a", .block_start_escapes = "#", .renderText = &renderTextByAlphabet };
    try std.testing.expectError(error.Incoherent, letter_escape.validate(&why));
    try std.testing.expectEqual(Rule.alphabet_byte, why.rule);

    try none.validate(&why);
}
