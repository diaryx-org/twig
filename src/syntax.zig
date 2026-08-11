//! What a format's *surface syntax* looks like — the spelling knowledge the
//! authoring gestures in `ast/editor.zig` need, and the only thing standing
//! between the language-agnostic `Splicer` and a working Cmd-B.
//!
//! ── Why this is a table and not a switch ───────────────────────────────────
//! Twig's four formats are RAGGED: every one of them parses and renders, but
//! only djot and Markdown can be *authored* into, and they don't even author
//! the same set — djot spells all eight inline marks, Markdown only three
//! (`**`/`*`/`` ` ``); XML and HTML spell none. A `?Delims` per (format, kind)
//! makes that raggedness DATA. The alternative — a `switch (format)` per op,
//! with an `else => unsupported_format` arm — is what the C ABI grew instead,
//! and it put the spelling of djot's `{=mark=}` behind an `extern` boundary
//! where the CLI couldn't reach it and only a C caller could test it.
//!
//! So: a `null` field means "this format has no spelling for that", and every
//! caller turns that into one uniform "unsupported" error. Exactly how
//! `format.zig`'s `serializeFromAst: ?*const fn(...)` already says "this
//! language has no serializer yet".
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
/// left at "can't spell it". A parse-only language (XML, HTML) carries THIS
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
    /// any one gesture. `false` for a parse-only format (XML, HTML).
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
            .markup_leaf, .tag => null,
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
    s.assertCoherent();
}
