//! What a format's *surface syntax* looks like — the spelling knowledge the
//! authoring gestures in `ast/editor.rs` need. Port of `src/syntax.zig`.
//!
//! ── Why this is a table and not a switch ───────────────────────────────────
//! Twig's formats are RAGGED: every one of them parses and renders, but they
//! author wildly different subsets. A `Option<Delims>` per (format, kind) makes
//! that raggedness DATA: a `None` field means "this format has no spelling for
//! that", and every caller turns that into one uniform "unsupported" error.
//!
//! ── Why data, not behaviour ────────────────────────────────────────────────
//! Nearly everything here is a byte string or a flag. The *algorithms* are
//! format-INDEPENDENT and live once in `ast/editor.rs`; only the alphabet
//! changes. Three fields are functions — the renderers — because some
//! format's spelling is not a table at all (`spells_autolink`, `render_text`,
//! `render_block`).
//!
//! ── The line model ─────────────────────────────────────────────────────────
//! Source is a sequence of LINES ended by `\n`; a block begins at a line start;
//! a container is a PREFIX on every line it covers (`marker`/`cont`/`blank`);
//! two blocks are kept apart by `block_separator`, one continues onto its next
//! line by `line_join`; everything written inside a line holds no line end.
//! `Syntax::validate` holds a table to the rules that are facts about its
//! bytes.
//!
//! `Syntax` names no format and imports no language module; `format.rs`'s
//! registry binds a format to its table. The per-language tables live beside
//! this file as `syntax/<lang>.rs`.

pub mod asciidoc;
pub mod djot;
pub mod html;
pub mod markdown;
pub mod xml;

use std::any::Any;

use crate::ast::{Alignment, Ast, InlineMark, KindRef, NodeId, TextLeafKind};
use crate::Error;

/// The inline marks a toolbar can wrap or toggle over a selection. Named for
/// the kinds they parse back as — see [`InlineKind::kind_ref`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InlineKind {
    Strong,
    Emph,
    Verbatim,
    Mark,
    Superscript,
    Subscript,
    Insert,
    Delete,
}

impl InlineKind {
    pub const ALL: [InlineKind; 8] = [
        InlineKind::Strong,
        InlineKind::Emph,
        InlineKind::Verbatim,
        InlineKind::Mark,
        InlineKind::Superscript,
        InlineKind::Subscript,
        InlineKind::Insert,
        InlineKind::Delete,
    ];

    /// The node this kind parses back as: seven are `InlineMark` family
    /// members, `verbatim` is a text leaf.
    pub fn kind_ref(self) -> KindRef {
        match self {
            InlineKind::Strong => KindRef::Mark(InlineMark::Strong),
            InlineKind::Emph => KindRef::Mark(InlineMark::Emph),
            InlineKind::Verbatim => KindRef::TextLeaf(TextLeafKind::Verbatim),
            InlineKind::Mark => KindRef::Mark(InlineMark::Mark),
            InlineKind::Superscript => KindRef::Mark(InlineMark::Superscript),
            InlineKind::Subscript => KindRef::Mark(InlineMark::Subscript),
            InlineKind::Insert => KindRef::Mark(InlineMark::Insert),
            InlineKind::Delete => KindRef::Mark(InlineMark::Delete),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            InlineKind::Strong => "strong",
            InlineKind::Emph => "emph",
            InlineKind::Verbatim => "verbatim",
            InlineKind::Mark => "mark",
            InlineKind::Superscript => "superscript",
            InlineKind::Subscript => "subscript",
            InlineKind::Insert => "insert",
            InlineKind::Delete => "delete",
        }
    }

    pub fn from_name(s: &str) -> Option<InlineKind> {
        InlineKind::ALL.into_iter().find(|k| k.name() == s)
    }
}

/// The blocks `Editor::set_block` converts between by rewriting a leading marker.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Paragraph,
    Heading,
}

/// The containers `Editor::toggle_block_container` wraps a block range in.
/// Unlike a `BlockKind` these prefix EVERY line, they nest, and a list numbers
/// its items.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ContainerKind {
    BlockQuote,
    BulletList,
    OrderedList,
}

impl ContainerKind {
    pub const ALL: [ContainerKind; 3] = [ContainerKind::BlockQuote, ContainerKind::BulletList, ContainerKind::OrderedList];

    pub fn name(self) -> &'static str {
        match self {
            ContainerKind::BlockQuote => "block_quote",
            ContainerKind::BulletList => "bullet_list",
            ContainerKind::OrderedList => "ordered_list",
        }
    }

    pub fn from_name(s: &str) -> Option<ContainerKind> {
        ContainerKind::ALL.into_iter().find(|k| k.name() == s)
    }

    /// The node tag this container parses back as.
    pub fn tag(self) -> crate::ast::Tag {
        match self {
            ContainerKind::BlockQuote => crate::ast::Tag::BlockQuote,
            ContainerKind::BulletList => crate::ast::Tag::BulletList,
            ContainerKind::OrderedList => crate::ast::Tag::OrderedList,
        }
    }
}

/// Where a run of literal text is about to land — the one thing `render_text`
/// is told beyond the bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TextPosition {
    /// Ordinary prose, after other text on its line: the inline
    /// metacharacters bite, block markers do not.
    InlineText,
    /// A line's leading whitespace and the byte that ends it, where a block
    /// marker opens a block — so the inline alphabet AND the line-start
    /// alphabet bite. A run handed in here holds at most one non-whitespace
    /// byte, and it is the last.
    BlockStart,
    /// Inside a code span, a code block or a raw node, whose body the format
    /// reads without interpreting.
    Verbatim,
}

impl TextPosition {
    pub const ALL: [TextPosition; 3] = [TextPosition::InlineText, TextPosition::BlockStart, TextPosition::Verbatim];
}

/// The source delimiters that mark an inline kind. Values are exactly what the
/// format's serializer emits, so a wrap round-trips.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Delims {
    pub open: &'static [u8],
    pub close: &'static [u8],
    /// May an EDITOR gesture author this, or is the spelling emit-only? A
    /// fact about a TABLE, not about a format: whether a spelling reparses can
    /// depend on the extensions the document is parsed with.
    pub authorable: bool,
}

impl Delims {
    pub const fn new(open: &'static str, close: &'static str) -> Delims {
        Delims { open: open.as_bytes(), close: close.as_bytes(), authorable: true }
    }

    /// A spelling the serializer may emit but a gesture must not mint.
    pub const fn emit_only(open: &'static str, close: &'static str) -> Delims {
        Delims { open: open.as_bytes(), close: close.as_bytes(), authorable: false }
    }
}

/// One colour of a [`MarkColors`] palette: the attribute value, and the bytes
/// that spell it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MarkColor {
    /// The value stored in `attr_key` — `red`. The name a caller passes.
    pub name: &'static [u8],
    /// The source bytes written after the opening delimiter — `🔴`.
    pub prefix: &'static [u8],
}

/// How a format spells a COLOUR on an inline `mark` — the prefix between the
/// mark's opening delimiter and its content.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MarkColors {
    /// The attribute the colour rides in on the node — `data-color`.
    pub attr_key: &'static [u8],
    /// Every colour this format spells, in the order a picker should offer them.
    pub colors: &'static [MarkColor],
    /// Written between the prefix and the content.
    pub space: &'static [u8],
}

impl MarkColors {
    /// The bytes that spell `name`, or `None` when this format has no colour
    /// by that name.
    pub fn prefix_for(&self, name: &[u8]) -> Option<&[u8]> {
        self.colors.iter().find(|c| c.name == name).map(|c| &c.prefix[..])
    }

    /// The colour whose prefix opens `s`, if any. Matches the LONGEST prefix.
    pub fn prefix_at(&self, s: &[u8]) -> Option<&MarkColor> {
        let mut found: Option<&MarkColor> = None;
        for c in self.colors {
            if c.prefix.is_empty() || !s.starts_with(&c.prefix) {
                continue;
            }
            if found.is_none_or(|f| c.prefix.len() > f.prefix.len()) {
                found = Some(c);
            }
        }
        found
    }
}

/// How a format spells a container's per-line prefix.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ContainerSpelling {
    /// Opens the container on the first line of each covered block.
    pub marker: &'static [u8],
    /// Holds a block's continuation lines inside the container.
    pub cont: &'static [u8],
    /// A blank line INSIDE the container.
    pub blank: &'static [u8],
    /// The marker is a per-item ordinal (`1. `, `2. `…), built at emit time.
    pub numbered: bool,
}

impl ContainerSpelling {
    pub const fn new(marker: &'static str, cont: &'static str, blank: &'static str) -> ContainerSpelling {
        ContainerSpelling { marker: marker.as_bytes(), cont: cont.as_bytes(), blank: blank.as_bytes(), numbered: false }
    }
}

/// How a format spells a FENCED code block.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CodeFence {
    /// The fence byte, repeated.
    pub char: u8,
    /// The shortest run that opens a fence.
    pub min: usize,
    /// Bytes that cannot appear in the info string, beyond `char` itself and
    /// the line ends every format forbids.
    pub info_forbids: &'static [u8],
}

impl CodeFence {
    pub const fn new(char: u8) -> CodeFence {
        CodeFence { char, min: 3, info_forbids: b"" }
    }
}

/// How a format spells a TASK-LIST item's checkbox.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TaskMarker {
    /// The box, brackets included and nothing else: `[ ]`.
    pub unchecked: &'static [u8],
    /// The checked box, the same width as `unchecked`.
    pub checked: &'static [u8],
    /// What separates the box from the item's text.
    pub space: &'static [u8],
    /// The bytes a box may hold to count as CHECKED when reading source back.
    pub checked_chars: &'static [u8],
}

impl TaskMarker {
    pub const fn new(unchecked: &'static str, checked: &'static str) -> TaskMarker {
        TaskMarker { unchecked: unchecked.as_bytes(), checked: checked.as_bytes(), space: b" ", checked_chars: b"xX" }
    }
}

/// How a format spells a footnote — both halves, because they are one gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FootnoteSpelling {
    /// Opens a reference: `[^`.
    pub ref_open: &'static [u8],
    /// Closes a reference: `]`.
    pub ref_close: &'static [u8],
    /// Follows the reference spelling to open a DEFINITION at a line start.
    pub def_suffix: &'static [u8],
    /// Bytes a label cannot hold, beyond the line ends every format forbids.
    pub label_forbids: &'static [u8],
}

impl FootnoteSpelling {
    pub const fn new(ref_open: &'static str, ref_close: &'static str, def_suffix: &'static str) -> FootnoteSpelling {
        FootnoteSpelling {
            ref_open: ref_open.as_bytes(),
            ref_close: ref_close.as_bytes(),
            def_suffix: def_suffix.as_bytes(),
            label_forbids: b"[]",
        }
    }
}

/// The delimiter cell per column alignment (Zig's `EnumArray(Alignment, …)`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AlignmentCells {
    pub default: &'static [u8],
    pub left: &'static [u8],
    pub right: &'static [u8],
    pub center: &'static [u8],
}

impl AlignmentCells {
    pub const fn new(default: &'static str, left: &'static str, right: &'static str, center: &'static str) -> AlignmentCells {
        AlignmentCells {
            default: default.as_bytes(),
            left: left.as_bytes(),
            right: right.as_bytes(),
            center: center.as_bytes(),
        }
    }

    pub fn get(&self, a: Alignment) -> &'static [u8] {
        match a {
            Alignment::Default => &self.default,
            Alignment::Left => &self.left,
            Alignment::Right => &self.right,
            Alignment::Center => &self.center,
        }
    }

    pub fn get_mut(&mut self, a: Alignment) -> &mut &'static [u8] {
        match a {
            Alignment::Default => &mut self.default,
            Alignment::Left => &mut self.left,
            Alignment::Right => &mut self.right,
            Alignment::Center => &mut self.center,
        }
    }
}

/// Every alignment in declaration order (Zig's `std.enums.values(Alignment)`).
pub const ALIGNMENTS: [Alignment; 4] = [Alignment::Default, Alignment::Left, Alignment::Right, Alignment::Center];

/// How a format spells a PIPE TABLE's skeleton.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TableSpelling {
    /// Borders a row and separates its cells.
    pub bar: &'static [u8],
    /// Written on both sides of a cell's content.
    pub pad: &'static [u8],
    /// The same, around a DELIMITER cell (djot's must abut the bar).
    pub delim_pad: &'static [u8],
    /// The delimiter cell per column alignment, colons included.
    pub delim: AlignmentCells,
}

/// The `<dest>` form of [`DestEscapes`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AngleEscapes {
    /// Bytes to backslash-escape between the angle brackets.
    pub escapes: &'static [u8],
}

/// How a format escapes a link's `(destination)` position.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct DestEscapes {
    /// Bytes to backslash-escape in the ordinary `(dest)` form.
    pub plain: &'static [u8],
    /// The `<dest>` form, used when the destination holds a space or tab —
    /// `None` when the format has no angle form.
    pub angle: Option<AngleEscapes>,
}

/// Whether a value needs `"` around it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Quoting {
    Never,
    Always,
    WhenNeeded,
}

impl Quoting {
    pub fn name(self) -> &'static str {
        match self {
            Quoting::Never => "never",
            Quoting::Always => "always",
            Quoting::WhenNeeded => "when_needed",
        }
    }
    pub fn from_name(s: &[u8]) -> Option<Quoting> {
        [Quoting::Never, Quoting::Always, Quoting::WhenNeeded].into_iter().find(|q| q.name().as_bytes() == s)
    }
}

/// How a format spells a node's ATTRIBUTES back into its own source. See
/// `attrs_writer.rs` for the one algorithm.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AttrSpelling {
    pub open: &'static [u8],
    pub close: &'static [u8],
    /// Written between two entries.
    pub between: &'static [u8],
    /// Written before every key.
    pub key_prefix: &'static [u8],
    /// Written between a key and its value.
    pub key_value: &'static [u8],
    /// When to wrap a value in `"`.
    pub quoting: Quoting,
    /// Bytes to backslash-escape inside a quoted value.
    pub quote_escapes: &'static [u8],
    /// The `#name` shorthand for the `id` key.
    pub id_sigil: Option<&'static [u8]>,
    /// The `.name` shorthand, written once per class.
    pub class_sigil: Option<&'static [u8]>,
}

impl AttrSpelling {
    pub const DEFAULT: AttrSpelling = AttrSpelling {
        open: b"",
        close: b"",
        between: b" ",
        key_prefix: b"",
        key_value: b"=",
        quoting: Quoting::Never,
        quote_escapes: b"",
        id_sigil: None,
        class_sigil: None,
    };
}

impl Default for AttrSpelling {
    fn default() -> AttrSpelling {
        AttrSpelling::DEFAULT
    }
}

/// How a node's own attributes are spelled — see `Syntax::node_attrs`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct NodeAttrs {
    /// What the node's opening spelling begins with, before its name — `<`.
    pub open: &'static [u8],
}

impl Default for NodeAttrs {
    fn default() -> NodeAttrs {
        NodeAttrs { open: b"<" }
    }
}

/// The shape a block's attributes come back in — see `Syntax::block_attrs`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BlockAttrs {
    /// On the block itself: djot's `{…}` line, HTML's tag, AsciiDoc's `[…]`.
    Native,
    /// On a container whose sole child is the block: Markdown's `<div>`.
    Wrapped,
}

impl BlockAttrs {
    pub fn name(self) -> &'static str {
        match self {
            BlockAttrs::Native => "native",
            BlockAttrs::Wrapped => "wrapped",
        }
    }
    pub fn from_name(s: &[u8]) -> Option<BlockAttrs> {
        [BlockAttrs::Native, BlockAttrs::Wrapped].into_iter().find(|q| q.name().as_bytes() == s)
    }
}

/// Spell `text` so that it reparses as ITSELF in `position`.
pub type RenderTextFn = fn(&Syntax, &[u8], TextPosition, &mut Vec<u8>) -> Result<(), Error>;
/// Spell the node `root` of `ast`, descendants included, as this format's source.
pub type RenderBlockFn = fn(&Syntax, &Ast, NodeId, &mut Vec<u8>) -> Result<(), Error>;
/// Whether `angled` — a `<dest>` run, BRACKETS INCLUDED — spells an autolink.
pub type SpellsAutolinkFn = fn(&Syntax, &[u8]) -> bool;

/// How a table renders a literal: by its own alphabet (the shared
/// [`render_text_by_alphabet`]), or by a function of its own. Zig compares
/// the function pointer against `renderTextByAlphabet`; the enum makes that
/// identity explicit.
#[derive(Clone, Copy, Debug)]
pub enum TextRenderer {
    Alphabet,
    Custom(RenderTextFn),
}

/// What a runtime language's renderers find it by (Zig's
/// `renderer_context: ?*const anyopaque`). Never crosses as JSON.
pub type RendererContext = &'static (dyn Any + Send + Sync);

/// One format's surface spelling. Every field defaults to "can't spell it", so
/// a format that only parses is `Syntax::default()` (see [`none`]).
#[derive(Clone, Copy, Debug)]
pub struct Syntax {
    /// Delimiters per inline mark, indexed by `InlineMark as usize`.
    pub inline_delims: [Option<Delims>; 9],
    /// Delimiters per delimited text leaf, indexed by `TextLeafKind as usize`.
    pub text_leaf_delims: [Option<Delims>; 9],
    /// How a colour is spelled on an inline `mark`.
    pub mark_colors: Option<MarkColors>,
    /// Per-line prefixes per container kind, indexed by `ContainerKind as usize`.
    pub container_spelling: [Option<ContainerSpelling>; 3],
    /// How a node's attributes are spelled back.
    pub attr_spelling: Option<AttrSpelling>,
    /// The byte that opens an ATX heading, repeated `level` times then a space.
    pub heading_marker: Option<u8>,
    /// Whether a heading written with `heading_marker` CONTINUES onto the line
    /// after it, as djot's does.
    pub heading_continues: bool,
    /// A thematic break, as the whole line it occupies (no trailing newline).
    pub thematic_break: Option<&'static [u8]>,
    pub code_fence: Option<CodeFence>,
    pub task_marker: Option<TaskMarker>,
    pub footnote: Option<FootnoteSpelling>,
    pub table_spelling: Option<TableSpelling>,
    /// What separates two BLOCKS of the same kind (`split_block`).
    pub block_separator: Option<&'static [u8]>,
    /// What continues a BLOCK onto its NEXT LINE (`join_blocks`).
    pub line_join: Option<&'static [u8]>,
    /// The line that ATTACHES a block to a list item's tail — AsciiDoc's `+`.
    pub list_attach: Option<&'static [u8]>,
    /// The bytes a link's TEXT position must have backslash-escaped.
    pub link_text_escapes: Option<&'static [u8]>,
    pub link_dest_escapes: Option<DestEscapes>,
    /// The bytes a run of user-typed text must have backslash-escaped in
    /// body-text position. Read by `render_text_by_alphabet` and nothing else.
    pub text_escapes: Option<&'static [u8]>,
    /// The bytes that only open a construct at a LINE START.
    pub block_start_escapes: Option<&'static [u8]>,
    /// How a hard break is spelled inside a table cell.
    pub cell_line_break: Option<&'static [u8]>,
    /// Whether a NAMED LEAF CONTAINER printed through `render_block` reparses
    /// to a container that still carries that name.
    pub names_leaf_containers: bool,
    /// How a BLOCK carrying attributes printed through `render_block` reparses.
    pub block_attrs: Option<BlockAttrs>,
    /// Whether a node's attributes live on its OWN opening spelling.
    pub node_attrs: Option<NodeAttrs>,
    /// Whether an ANONYMOUS INLINE CONTAINER carrying attributes reparses.
    pub inline_attrs: bool,
    /// Whether a `line_block` printed through `render_block` reparses as one.
    pub line_blocks: bool,

    // ── Renderers ──────────────────────────────────────────────────────────
    /// Spell a literal run. `None` = `insert_literal` is unsupported.
    pub render_text: Option<TextRenderer>,
    /// Print a fragment. `None` = this format cannot print one.
    pub render_block: Option<RenderBlockFn>,
    /// Whether an angled run spells an autolink. `None` = no autolink form.
    pub spells_autolink: Option<SpellsAutolinkFn>,
    /// What this table's renderers need to find the language that answers
    /// them; `None` for every compiled table.
    pub renderer_context: Option<RendererContext>,
}

impl Syntax {
    /// The table that spells nothing — every field at "can't spell it".
    pub const NONE: Syntax = Syntax {
        inline_delims: [None; 9],
        text_leaf_delims: [None; 9],
        mark_colors: None,
        container_spelling: [None; 3],
        attr_spelling: None,
        heading_marker: None,
        heading_continues: false,
        thematic_break: None,
        code_fence: None,
        task_marker: None,
        footnote: None,
        table_spelling: None,
        block_separator: None,
        line_join: None,
        list_attach: None,
        link_text_escapes: None,
        link_dest_escapes: None,
        text_escapes: None,
        block_start_escapes: None,
        cell_line_break: None,
        names_leaf_containers: false,
        block_attrs: None,
        node_attrs: None,
        inline_attrs: false,
        line_blocks: false,
        render_text: None,
        render_block: None,
        spells_autolink: None,
        renderer_context: None,
    };
}

impl Default for Syntax {
    fn default() -> Syntax {
        Syntax::NONE
    }
}

static NONE: Syntax = Syntax::NONE;

/// The spelling of a format that can't be authored into at all — every field
/// left at "can't spell it". A parse-only language carries THIS rather than a
/// `None`, so every gesture consults a table and reports unsupported through
/// the one uniform path.
pub fn none() -> &'static Syntax {
    &NONE
}

/// The `render_text` of every format that spells a literal by writing a
/// backslash before a byte from an alphabet. In `verbatim` position the bytes
/// are written as they are.
pub fn render_text_by_alphabet(syntax: &Syntax, text: &[u8], position: TextPosition, out: &mut Vec<u8>) -> Result<(), Error> {
    // `validate` pins both non-null wherever this is the renderer.
    let inline_escapes = syntax.text_escapes.ok_or(Error::Internal)?;
    let block_escapes = syntax.block_start_escapes.ok_or(Error::Internal)?;
    for &c in text {
        let escape = match position {
            TextPosition::Verbatim => false,
            TextPosition::InlineText => inline_escapes.contains(&c),
            TextPosition::BlockStart => inline_escapes.contains(&c) || block_escapes.contains(&c),
        };
        if escape {
            out.push(b'\\');
        }
        out.push(c);
    }
    Ok(())
}

/// The fragment a whole-tree serializer needs to print exactly `root` and its
/// descendants: the tree re-rooted there (Zig's `renderBlockVia` shallow copy).
pub fn fragment(ast: &Ast, root: NodeId) -> Ast {
    let mut f = ast.clone();
    f.root = root;
    f
}

impl Syntax {
    pub fn inline_delim(&self, m: InlineMark) -> Option<&Delims> {
        self.inline_delims[m as usize].as_ref()
    }

    pub fn text_leaf_delim(&self, k: TextLeafKind) -> Option<&Delims> {
        self.text_leaf_delims[k as usize].as_ref()
    }

    pub fn container(&self, k: ContainerKind) -> Option<&ContainerSpelling> {
        self.container_spelling[k as usize].as_ref()
    }

    pub fn set_inline(&mut self, m: InlineMark, d: Option<Delims>) {
        self.inline_delims[m as usize] = d;
    }

    pub fn set_text_leaf(&mut self, k: TextLeafKind, d: Option<Delims>) {
        self.text_leaf_delims[k as usize] = d;
    }

    pub fn set_container(&mut self, k: ContainerKind, c: Option<ContainerSpelling>) {
        self.container_spelling[k as usize] = c;
    }

    /// Whether `render_text` is the shared alphabet renderer.
    pub fn renders_text_by_alphabet(&self) -> bool {
        matches!(self.render_text, Some(TextRenderer::Alphabet))
    }

    /// Run this table's literal renderer. `Error::UnsupportedFormat` when it
    /// has none.
    pub fn render_text(&self, text: &[u8], position: TextPosition, out: &mut Vec<u8>) -> Result<(), Error> {
        match self.render_text {
            Some(TextRenderer::Alphabet) => render_text_by_alphabet(self, text, position, out),
            Some(TextRenderer::Custom(f)) => f(self, text, position, out),
            None => Err(Error::UnsupportedFormat),
        }
    }

    /// Whether this format can be authored into at all — a "is there a door
    /// in" predicate, not a capability report.
    pub fn authorable(&self) -> bool {
        self.link_text_escapes.is_some()
            || self.heading_marker.is_some()
            || self.render_text.is_some()
            || self.inline_delim(InlineMark::Strong).is_some()
    }

    /// The delimiters for whatever node `r` names, from whichever family table
    /// holds it. A `markup_leaf`, a plain tag and a named container are never
    /// spelled by a symmetric pair here.
    pub fn delims_for(&self, r: &KindRef) -> Option<&Delims> {
        match r {
            KindRef::Mark(m) => self.inline_delim(*m),
            KindRef::TextLeaf(l) => self.text_leaf_delim(*l),
            KindRef::MarkupLeaf(_) | KindRef::Tag(_) | KindRef::ContainerNamed(_) => None,
        }
    }

    /// `delims_for` restricted to what an editor gesture may write.
    pub fn authorable_delims_for(&self, r: &KindRef) -> Option<&Delims> {
        let d = self.delims_for(r)?;
        if d.authorable { Some(d) } else { None }
    }

    /// Whether the invariants between this table's fields hold. On the first
    /// that fails, the answer names which rule and which field.
    pub fn validate(&self) -> Result<(), Incoherence> {
        fn fail(rule: Rule, field: &str) -> Result<(), Incoherence> {
            Err(Incoherence { rule, field: field.to_string() })
        }

        // ── Implications ───────────────────────────────────────────────────
        if self.link_text_escapes.is_none() != self.link_dest_escapes.is_none() {
            return fail(Rule::LinkHalves, "link_text_escapes");
        }
        if self.text_escapes.is_none() != self.block_start_escapes.is_none() {
            return fail(Rule::LiteralHalves, "text_escapes");
        }
        if self.text_escapes.is_some() != self.renders_text_by_alphabet() {
            return fail(Rule::AlphabetRenderer, "renderText");
        }
        if let Some(tm) = &self.task_marker {
            if self.container(ContainerKind::BulletList).is_none() {
                return fail(Rule::TaskNeedsBullet, "task_marker");
            }
            if tm.checked.len() != tm.unchecked.len() {
                return fail(Rule::TaskWidths, "task_marker.checked");
            }
        }
        if let Some(mc) = &self.mark_colors {
            if mc.attr_key.is_empty() {
                return fail(Rule::ColorsSpelling, "mark_colors.attr_key");
            }
            if mc.colors.is_empty() {
                return fail(Rule::ColorsSpelling, "mark_colors.colors");
            }
            if mc.space.is_empty() {
                return fail(Rule::ColorsSpelling, "mark_colors.space");
            }
            match self.inline_delim(InlineMark::Mark) {
                Some(d) if d.authorable => {}
                _ => return fail(Rule::ColorsNeedMark, "mark_colors"),
            }
            for (i, c) in mc.colors.iter().enumerate() {
                if c.name.is_empty() || c.prefix.is_empty() {
                    return fail(Rule::ColorsSpelling, "mark_colors.colors");
                }
                if c.prefix.starts_with(&mc.space) {
                    return fail(Rule::ColorsSpelling, "mark_colors.colors");
                }
                for o in &mc.colors[i + 1..] {
                    if c.prefix == o.prefix || c.name == o.name {
                        return fail(Rule::ColorsDuplicate, "mark_colors.colors");
                    }
                }
            }
        }
        if let Some(fs) = &self.footnote {
            let Some(d) = self.text_leaf_delim(TextLeafKind::FootnoteReference) else {
                return fail(Rule::FootnoteHalves, "text_leaf_delims.footnote_reference");
            };
            if d.open != fs.ref_open || d.close != fs.ref_close {
                return fail(Rule::FootnoteHalves, "footnote.ref_open");
            }
        }
        if let Some(ts) = &self.table_spelling {
            if ts.bar.is_empty() {
                return fail(Rule::TableBar, "table_spelling.bar");
            }
            if contains_seq(&ts.pad, &ts.bar) {
                return fail(Rule::TableBar, "table_spelling.pad");
            }
            if contains_seq(&ts.delim_pad, &ts.bar) {
                return fail(Rule::TableBar, "table_spelling.delim_pad");
            }
            for a in ALIGNMENTS {
                let cell = ts.delim.get(a);
                if cell.is_empty() || contains_seq(cell, &ts.bar) {
                    return fail(Rule::TableBar, "table_spelling.delim");
                }
            }
        }
        if self.block_separator.is_some() {
            if self.heading_marker.is_none() {
                return fail(Rule::SplitNeedsMarkers, "heading_marker");
            }
            if self.code_fence.is_none() {
                return fail(Rule::SplitNeedsMarkers, "code_fence");
            }
            if self.line_join.is_none() {
                return fail(Rule::SplitNeedsJoin, "line_join");
            }
        }
        if self.heading_continues && self.heading_marker.is_none() {
            return fail(Rule::ContinuesNeedsMarker, "heading_continues");
        }
        if self.render_block.is_none() {
            if self.names_leaf_containers {
                return fail(Rule::ClaimNeedsRenderer, "names_leaf_containers");
            }
            if self.block_attrs.is_some() {
                return fail(Rule::ClaimNeedsRenderer, "block_attrs");
            }
            if self.inline_attrs {
                return fail(Rule::ClaimNeedsRenderer, "inline_attrs");
            }
            if self.line_blocks {
                return fail(Rule::ClaimNeedsRenderer, "line_blocks");
            }
            for (k, name) in [
                (TextLeafKind::InlineMath, "text_leaf_delims.inline_math"),
                (TextLeafKind::DisplayMath, "text_leaf_delims.display_math"),
            ] {
                if self.authorable_delims_for(&KindRef::TextLeaf(k)).is_some() {
                    return fail(Rule::ClaimNeedsRenderer, name);
                }
            }
        }

        // ── Well-formedness: the line model ─────────────────────────────────
        for d in self.inline_delims.iter().flatten() {
            if !in_line(&d.open, false) || !in_line(&d.close, false) {
                return fail(Rule::InlineSpelling, "inline_delims");
            }
        }
        for d in self.text_leaf_delims.iter().flatten() {
            if !in_line(&d.open, false) || !in_line(&d.close, false) {
                return fail(Rule::InlineSpelling, "text_leaf_delims");
            }
        }
        for c in self.container_spelling.iter().flatten() {
            if !in_line(&c.marker, c.numbered) || !in_line(&c.cont, true) || !in_line(&c.blank, true) {
                return fail(Rule::LineSpelling, "container_spelling");
            }
        }
        if let Some(h) = self.heading_marker {
            if !visible(h) {
                return fail(Rule::LineSpelling, "heading_marker");
            }
        }
        if let Some(t) = &self.thematic_break {
            if !in_line(t, false) {
                return fail(Rule::LineSpelling, "thematic_break");
            }
        }
        if let Some(f) = &self.code_fence {
            if !visible(f.char) || f.min == 0 {
                return fail(Rule::LineSpelling, "code_fence");
            }
        }
        if let Some(tm) = &self.task_marker {
            if !in_line(&tm.unchecked, false) || !in_line(&tm.checked, false) || !in_line(&tm.space, true) {
                return fail(Rule::LineSpelling, "task_marker");
            }
        }
        if let Some(fs) = &self.footnote {
            if !in_line(&fs.def_suffix, true) {
                return fail(Rule::LineSpelling, "footnote.def_suffix");
            }
        }
        if let Some(ts) = &self.table_spelling {
            if !in_line(&ts.bar, false) || !in_line(&ts.pad, true) || !in_line(&ts.delim_pad, true) {
                return fail(Rule::LineSpelling, "table_spelling");
            }
            for a in ALIGNMENTS {
                if !in_line(ts.delim.get(a), false) {
                    return fail(Rule::LineSpelling, "table_spelling.delim");
                }
            }
        }
        if let Some(l) = &self.list_attach {
            if !in_line(l, false) {
                return fail(Rule::LineSpelling, "list_attach");
            }
        }
        if let Some(b) = &self.cell_line_break {
            if !in_line(b, false) {
                return fail(Rule::LineSpelling, "cell_line_break");
            }
        }
        if let Some(s) = &self.block_separator {
            if !ends_line(s) {
                return fail(Rule::LineEndSpelling, "block_separator");
            }
        }
        if let Some(s) = &self.line_join {
            if !ends_line(s) {
                return fail(Rule::LineEndSpelling, "line_join");
            }
        }
        if let Some(te) = &self.text_escapes {
            if !punctuation(te) {
                return fail(Rule::AlphabetByte, "text_escapes");
            }
            let bse = self.block_start_escapes.unwrap_or_default();
            if !punctuation(bse) {
                return fail(Rule::AlphabetByte, "block_start_escapes");
            }
            if te.iter().any(|c| bse.contains(c)) {
                return fail(Rule::AlphabetsOverlap, "block_start_escapes");
            }
        }
        if let Some(e) = &self.link_text_escapes {
            if !punctuation(e) {
                return fail(Rule::AlphabetByte, "link_text_escapes");
            }
        }
        if let Some(d) = &self.link_dest_escapes {
            if !punctuation(&d.plain) {
                return fail(Rule::AlphabetByte, "link_dest_escapes.plain");
            }
            if let Some(a) = &d.angle {
                if !punctuation(&a.escapes) {
                    return fail(Rule::AlphabetByte, "link_dest_escapes.angle");
                }
            }
        }
        Ok(())
    }

    /// `validate` for a table a build already trusts: panics with the rule's
    /// name.
    pub fn assert_coherent(&self) {
        if let Err(why) = self.validate() {
            panic!("incoherent Syntax: {}: {}", why.field, why.rule.describe());
        }
    }
}

/// Which of `Syntax::validate`'s rules a table broke, and where.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Incoherence {
    pub rule: Rule,
    /// The field, as the description spells it (`task_marker.checked`).
    pub field: String,
}

/// `Syntax::validate`'s rules, by name.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Rule {
    LinkHalves,
    LiteralHalves,
    AlphabetRenderer,
    TaskNeedsBullet,
    TaskWidths,
    ColorsSpelling,
    ColorsNeedMark,
    ColorsDuplicate,
    FootnoteHalves,
    TableBar,
    SplitNeedsMarkers,
    SplitNeedsJoin,
    ContinuesNeedsMarker,
    ClaimNeedsRenderer,
    InlineSpelling,
    LineSpelling,
    LineEndSpelling,
    AlphabetByte,
    AlphabetsOverlap,
}

impl Rule {
    pub fn describe(self) -> &'static str {
        match self {
            Rule::LinkHalves => "a link's text and destination alphabets come together or not at all",
            Rule::LiteralHalves => "the body-text and line-start alphabets come together or not at all",
            Rule::AlphabetRenderer => "a text alphabet is read by the alphabet renderer, and a format with none renders literals itself",
            Rule::TaskNeedsBullet => "a task checkbox rides on a bullet item, so a bullet list must be spelled",
            Rule::TaskWidths => "the checked and unchecked boxes must be the same width",
            Rule::ColorsSpelling => "a mark colour needs a key, a space, and colours each with a name and a prefix not starting with the space",
            Rule::ColorsNeedMark => "a mark colour is written inside a mark this table can author",
            Rule::ColorsDuplicate => "two mark colours share a name or a prefix",
            Rule::FootnoteHalves => "a footnote's reference is spelled as its text leaf is",
            Rule::TableBar => "a table's bar is non-empty and appears in no padding or delimiter cell, and no delimiter cell is empty",
            Rule::SplitNeedsMarkers => "a format that splits blocks spells a heading marker and a code fence",
            Rule::SplitNeedsJoin => "a format that splits blocks can join them",
            Rule::ContinuesNeedsMarker => "a heading that continues onto its next line is written with a heading marker",
            Rule::ClaimNeedsRenderer => "a directive, attribute or formula claim needs a block renderer to print through",
            Rule::InlineSpelling => "an inline delimiter is non-empty and holds no line end",
            Rule::LineSpelling => "a spelling written inside a line holds no line end, and a marker is not empty",
            Rule::LineEndSpelling => "a block separator or line join ends in its only line end",
            Rule::AlphabetByte => "an escape alphabet holds only ASCII punctuation",
            Rule::AlphabetsOverlap => "a byte escaped everywhere is not also a line-start escape",
        }
    }
}

fn contains_seq(hay: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() {
        return true;
    }
    hay.windows(needle.len()).any(|w| w == needle)
}

/// Whether `s` fits inside one line: no line end, and non-empty unless
/// `may_be_empty`.
fn in_line(s: &[u8], may_be_empty: bool) -> bool {
    if s.is_empty() {
        return may_be_empty;
    }
    !s.iter().any(|&c| c == b'\r' || c == b'\n')
}

/// A marker byte a reparse can see: printable ASCII and not a space.
fn visible(c: u8) -> bool {
    c > b' ' && c < 0x7f
}

/// Ends in `\n`, with no line end before it.
fn ends_line(s: &[u8]) -> bool {
    if s.is_empty() || s[s.len() - 1] != b'\n' {
        return false;
    }
    !s[..s.len() - 1].iter().any(|&c| c == b'\r' || c == b'\n')
}

/// Every byte is ASCII punctuation.
fn punctuation(s: &[u8]) -> bool {
    s.iter().all(|&c| visible(c) && !c.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_parse_only_format_spells_nothing() {
        let s = Syntax::default();
        assert!(!s.authorable());
        assert!(s.inline_delim(InlineMark::Strong).is_none());
        assert!(s.container(ContainerKind::BlockQuote).is_none());
        assert!(s.heading_marker.is_none());
        assert!(!s.heading_continues);
        assert!(s.text_escapes.is_none());
        assert!(s.block_start_escapes.is_none());
        assert!(s.render_text.is_none());
        assert!(s.render_block.is_none());
        assert!(s.table_spelling.is_none());
        assert!(s.block_separator.is_none());
        assert!(!s.names_leaf_containers);
        assert!(s.block_attrs.is_none());
        assert!(!s.inline_attrs);
        s.assert_coherent();
    }

    #[test]
    fn validate_names_the_rule_a_table_breaks() {
        let half_link = Syntax { link_text_escapes: Some(b"[]"), ..Default::default() };
        assert_eq!(half_link.validate().unwrap_err().rule, Rule::LinkHalves);

        let continues_alone = Syntax { heading_continues: true, ..Default::default() };
        assert_eq!(continues_alone.validate().unwrap_err().rule, Rule::ContinuesNeedsMarker);

        let split_alone =
            Syntax { block_separator: Some(b"\n"), line_join: Some(b"\n"), ..Default::default() };
        let why = split_alone.validate().unwrap_err();
        assert_eq!(why.rule, Rule::SplitNeedsMarkers);
        assert_eq!(why.field, "heading_marker");

        let two_lines = Syntax { thematic_break: Some(b"-\n-"), ..Default::default() };
        assert_eq!(two_lines.validate().unwrap_err().rule, Rule::LineSpelling);

        let mut empty_open = Syntax::default();
        empty_open.set_inline(InlineMark::Strong, Some(Delims::new("", "*")));
        assert_eq!(empty_open.validate().unwrap_err().rule, Rule::InlineSpelling);

        let letter_escape = Syntax {
            text_escapes: Some(b"a"),
            block_start_escapes: Some(b"#"),
            render_text: Some(TextRenderer::Alphabet),
            ..Default::default()
        };
        assert_eq!(letter_escape.validate().unwrap_err().rule, Rule::AlphabetByte);

        none().validate().unwrap();
    }
}
