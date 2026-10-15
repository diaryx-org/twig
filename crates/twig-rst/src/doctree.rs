//! The docutils pseudo-XML *doctree* codec — the comparison format the rST
//! conformance harness is built on. Port of `src/languages/rst/doctree.zig`.
//!
//! ── Why a codec and not a printer ──────────────────────────────────────────
//! Every one of the 713 vendored cases expects a docutils DOCTREE, dumped by
//! `docutils.nodes.document.pformat()` — an indentation-based pseudo-XML that
//! is docutils' *tree* rather than its rendered output. So the doctree is a
//! format twig can both READ and WRITE: `decode` turns each expected doctree
//! into a twig `Ast`, `encode` turns it back, and `encode(decode(x)) == x`
//! over the whole corpus proves the format handling while [`Coverage`]
//! measures how much of docutils' vocabulary twig's shared `Ast` can hold.
//!
//! ── The pformat grammar, as observed ───────────────────────────────────────
//!   - Four spaces of indent per level. NO closing tags.
//!   - An element is `<name key="value" ...>`, attributes sorted by name.
//!     Values are never quote-escaped and no entity escaping happens anywhere.
//!   - A `Text` node is written as its lines, each prefixed by the indent; its
//!     leading and TRAILING whitespace is significant.
//!   - A blank line inside a text node is written as the bare indent.
//!
//! ── The one genuine ambiguity ──────────────────────────────────────────────
//! A text line CAN look exactly like an element (`<URL>` in one option-list
//! case). `decode` only treats a tag-shaped line as an element when its name
//! is in the closed [`Tag`] vocabulary; `Coverage::unknown_tag_shaped_text`
//! counts every line it fires on and the conformance test pins that count.
//!
//! ── Where `system_message` went ────────────────────────────────────────────
//! Here `system_message` is simply one more element being DECODED, taking the
//! same `container` fallback every other unmapped element takes.
//!
//! ── Dissolving elements ────────────────────────────────────────────────────
//! `tgroup`/`thead`/`tbody` and NESTED `line_block`s produce no twig node:
//! their children move up into their parent, with what the wrapper meant
//! (header-ness, one more level of indent) moved onto the children first
//! (`mark_head_rows`, `bump_line_indent`). `write_table`/`write_line_block`
//! rebuild the wrappers on the way out.
//!
//! ── Option lists ───────────────────────────────────────────────────────────
//! `option_list`/`option_list_item`/`option_group`/`description` are ABSORBED
//! into the definition-list four. On the way out the CONTENT decides which
//! construct a definition list is (`is_option_list`): `<option>` appears
//! nowhere else in docutils' vocabulary.

use crate::ast::{
    Ast, Attrs, Builder, Cell, Container, KeyVal, Kind, Link, ListNumbering, MarkupLeafKind, NodeId, Tag as KindTag,
    TextLeafKind,
};
use crate::document::{ContainerOrigin, Spelling};

/// Spaces per nesting level, as docutils' `pformat` writes them.
pub const INDENT_WIDTH: usize = 4;

macro_rules! tags {
    ($($variant:ident => $name:literal,)*) => {
        /// The closed docutils element vocabulary — every element class in
        /// `docutils/nodes.py`, not merely the ones the corpus exercises. It
        /// doubles as the LEXER's disambiguator (see the module doc's "one
        /// genuine ambiguity"), so it is the full published set.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum Tag {
            $($variant,)*
        }

        impl Tag {
            pub const ALL: &'static [Tag] = &[$(Tag::$variant,)*];
            pub const COUNT: usize = Tag::ALL.len();

            pub fn name(self) -> &'static str {
                match self {
                    $(Tag::$variant => $name,)*
                }
            }

            pub fn from_name(text: &[u8]) -> Option<Tag> {
                match text {
                    $(x if x == $name.as_bytes() => Some(Tag::$variant),)*
                    _ => None,
                }
            }
        }
    };
}

tags! {
    Abbreviation => "abbreviation",
    Acronym => "acronym",
    Address => "address",
    Admonition => "admonition",
    Attention => "attention",
    Attribution => "attribution",
    Author => "author",
    Authors => "authors",
    BlockQuote => "block_quote",
    BulletList => "bullet_list",
    Caption => "caption",
    Caution => "caution",
    Citation => "citation",
    CitationReference => "citation_reference",
    Classifier => "classifier",
    Colspec => "colspec",
    Comment => "comment",
    Compound => "compound",
    Contact => "contact",
    Container => "container",
    Copyright => "copyright",
    Danger => "danger",
    Date => "date",
    Decoration => "decoration",
    Definition => "definition",
    DefinitionList => "definition_list",
    DefinitionListItem => "definition_list_item",
    Description => "description",
    Docinfo => "docinfo",
    DoctestBlock => "doctest_block",
    Document => "document",
    Emphasis => "emphasis",
    Entry => "entry",
    EnumeratedList => "enumerated_list",
    Error => "error",
    Field => "field",
    FieldBody => "field_body",
    FieldList => "field_list",
    FieldName => "field_name",
    Figure => "figure",
    Footer => "footer",
    Footnote => "footnote",
    FootnoteReference => "footnote_reference",
    Generated => "generated",
    Header => "header",
    Hint => "hint",
    Image => "image",
    Important => "important",
    Inline => "inline",
    Label => "label",
    Legend => "legend",
    Line => "line",
    LineBlock => "line_block",
    ListItem => "list_item",
    Literal => "literal",
    LiteralBlock => "literal_block",
    Math => "math",
    MathBlock => "math_block",
    Meta => "meta",
    Note => "note",
    Option => "option",
    OptionArgument => "option_argument",
    OptionGroup => "option_group",
    OptionList => "option_list",
    OptionListItem => "option_list_item",
    OptionString => "option_string",
    Organization => "organization",
    Paragraph => "paragraph",
    Pending => "pending",
    Problematic => "problematic",
    Raw => "raw",
    Reference => "reference",
    Revision => "revision",
    Row => "row",
    Rubric => "rubric",
    Section => "section",
    Sidebar => "sidebar",
    Status => "status",
    Strong => "strong",
    Subscript => "subscript",
    SubstitutionDefinition => "substitution_definition",
    SubstitutionReference => "substitution_reference",
    Subtitle => "subtitle",
    Superscript => "superscript",
    SystemMessage => "system_message",
    Table => "table",
    Target => "target",
    Tbody => "tbody",
    Term => "term",
    Tgroup => "tgroup",
    Thead => "thead",
    Tip => "tip",
    Title => "title",
    TitleReference => "title_reference",
    Topic => "topic",
    Transition => "transition",
    Version => "version",
    Warning => "warning",
}

impl Tag {
    /// The slot of this tag in a [`Coverage`] table.
    pub fn index(self) -> usize {
        self as usize
    }
}

// ── the decode table ───────────────────────────────────────────────────────
//
// A mapping earns its place only if `encode` can inverse it EXACTLY,
// attributes and all; anything else stays a generic `container`. A parent is
// available on both sides, so a mapping that reads one (`title` is a table's
// caption) inverts as exactly as any other.

/// The elements that produce no node of their own. Their children are spliced
/// into their parent's child list; their attributes must be derivable, moved
/// onto the children, or absent. `parent` makes `line_block` conditional: the
/// OUTERMOST one is the construct and stays.
fn dissolves(tag: Tag, parent: Option<Tag>) -> bool {
    match tag {
        Tag::Tgroup | Tag::Thead | Tag::Tbody => true,
        Tag::LineBlock => parent == Some(Tag::LineBlock),
        _ => false,
    }
}

/// The twig `Kind` `tag` decodes to, or `None` for the generic `container`
/// fallback.
fn decode_kind(b: &Builder, tag: Tag, parent: Option<Tag>, children: &[NodeId], attrs: &[KeyVal]) -> Option<Kind> {
    Some(match tag {
        Tag::Document => Kind::Doc,
        Tag::Paragraph => Kind::Para,
        Tag::Emphasis => Kind::InlineMark(crate::ast::InlineMark::Emph),
        Tag::Strong => Kind::InlineMark(crate::ast::InlineMark::Strong),
        Tag::BlockQuote => Kind::BlockQuote,
        // docutils has no tight/loose distinction: `tight` is pinned to false.
        Tag::BulletList => Kind::BulletList { tight: false },
        // `enumtype` and `start` are READINGS; all four attributes stay in
        // `attrs`. A missing/unknown `enumtype` stays generic.
        Tag::EnumeratedList => {
            let n = decode_numbering(attrs)?;
            Kind::OrderedList { numbering: n, tight: false, start: decode_start(attrs) }
        }
        Tag::ListItem => Kind::ListItem,
        Tag::DefinitionList => Kind::DefinitionList,
        Tag::DefinitionListItem => Kind::DefinitionListItem,
        Tag::Term => Kind::Term,
        Tag::Definition => Kind::Definition,
        Tag::Section => Kind::Section,
        Tag::Transition => Kind::ThematicBreak,

        // ── the table subtree ──
        Tag::Table => Kind::Table,
        Tag::Colspec => Kind::Column,
        Tag::Row => Kind::Row { head: false },
        // `head` is set later by `mark_head_rows`; `alignment` has no doctree
        // spelling; `morecols`/`morerows` are the extent MINUS one.
        Tag::Entry => Kind::Cell(Cell {
            head: false,
            alignment: crate::ast::Alignment::Default,
            colspan: span_extent(attrs, b"morecols"),
            rowspan: span_extent(attrs, b"morerows"),
        }),

        // ── the option-list subtree ──
        Tag::OptionList => Kind::DefinitionList,
        Tag::OptionListItem => {
            if parent == Some(Tag::OptionList) {
                Kind::DefinitionListItem
            } else {
                return None;
            }
        }
        Tag::OptionGroup => {
            if parent == Some(Tag::OptionListItem) {
                Kind::Term
            } else {
                return None;
            }
        }
        Tag::Description => {
            if parent == Some(Tag::OptionListItem) {
                Kind::Definition
            } else {
                return None;
            }
        }

        // ── the line-block subtree ──
        Tag::LineBlock => Kind::LineBlock,
        // Every line decodes flush-left and is bumped by each wrapper.
        Tag::Line => Kind::Line { indent: 0 },

        Tag::Title => {
            if parent == Some(Tag::Table) {
                Kind::Caption
            } else {
                return None;
            }
        }
        // A FIGURE's caption; same twig kind, told apart again by parent.
        Tag::Caption => Kind::Caption,

        // A hyperlink USE: `refuri` is the destination, `refname` the name.
        Tag::Reference => Kind::Link(Link {
            destination: attr_value(attrs, b"refuri").map(|v| v.to_vec()),
            reference: attr_value(attrs, b"refname").map(|v| v.to_vec()),
        }),

        Tag::Target => return decode_target(children, attrs),

        // A definition's label is `names`, NOT its `<label>` child (which is
        // the rendered marker).
        Tag::Footnote => Kind::Footnote { label: definition_name(attrs).to_vec() },
        Tag::Citation => Kind::Citation { label: definition_name(attrs).to_vec() },
        Tag::SubstitutionDefinition => Kind::Substitution { label: definition_name(attrs).to_vec() },

        // The two USES: payload is the label as WRITTEN (the children's text).
        Tag::CitationReference => {
            Kind::TextLeaf { kind: TextLeafKind::CitationReference, text: sole_str(b, children)?.to_vec() }
        }
        Tag::SubstitutionReference => {
            Kind::TextLeaf { kind: TextLeafKind::SubstitutionReference, text: sole_str(b, children)?.to_vec() }
        }

        // The three text-carrying mappings absorb a lone `Text` child only.
        Tag::Literal => Kind::TextLeaf { kind: TextLeafKind::Verbatim, text: sole_str(b, children)?.to_vec() },
        Tag::LiteralBlock => Kind::CodeBlock { lang: None, text: sole_str(b, children)?.to_vec() },
        Tag::Comment => Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text: sole_str(b, children)?.to_vec() },

        _ => return None,
    })
}

/// What an encoding node is told about where it sits, threaded down by
/// `write_node`. `option_list` is the answer `is_option_list` reached at the
/// enclosing `definition_list`, carried down rather than re-derived.
#[derive(Clone, Copy, Default)]
struct Where {
    parent: Option<KindTag>,
    option_list: bool,
}

/// Is this `definition_list` really an rST OPTION LIST? Its parent kind cannot
/// say (all four levels are the definition-list kinds either way), but its
/// CONTENT can: a term holding an `<option>` is an option group.
fn is_option_list(ast: &Ast, id: NodeId) -> bool {
    for item in ast.children(id) {
        if item.kind != Kind::DefinitionListItem {
            continue;
        }
        for part in ast.children(item.id) {
            if part.kind != Kind::Term {
                continue;
            }
            for opt in ast.children(part.id) {
                if let Kind::Container(c) = &opt.kind {
                    if c.name == Tag::Option.name().as_bytes() {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// The docutils element `kind` encodes back to, or `None` when the kind has no
/// doctree spelling at all.
fn encode_tag(kind: &Kind, w: Where) -> Option<Tag> {
    let parent = w.parent;
    Some(match kind {
        Kind::Doc => Tag::Document,
        Kind::Para => Tag::Paragraph,
        Kind::BlockQuote => Tag::BlockQuote,
        Kind::BulletList { .. } => Tag::BulletList,
        Kind::OrderedList { .. } => Tag::EnumeratedList,
        Kind::ListItem => Tag::ListItem,
        Kind::DefinitionList => {
            if w.option_list {
                Tag::OptionList
            } else {
                Tag::DefinitionList
            }
        }
        Kind::DefinitionListItem => {
            if w.option_list {
                Tag::OptionListItem
            } else {
                Tag::DefinitionListItem
            }
        }
        Kind::Term => {
            if w.option_list {
                Tag::OptionGroup
            } else {
                Tag::Term
            }
        }
        Kind::Definition => {
            if w.option_list {
                Tag::Description
            } else {
                Tag::Definition
            }
        }
        Kind::LineBlock => Tag::LineBlock,
        Kind::Line { .. } => Tag::Line,
        Kind::Section => Tag::Section,
        Kind::ThematicBreak => Tag::Transition,
        Kind::CodeBlock { .. } => Tag::LiteralBlock,

        Kind::Table => Tag::Table,
        Kind::Column => Tag::Colspec,
        Kind::Row { .. } => Tag::Row,
        Kind::Cell(_) => Tag::Entry,
        Kind::Caption => {
            if parent == Some(KindTag::Table) {
                Tag::Title
            } else {
                Tag::Caption
            }
        }
        // docutils' `<reference>` is the USE and its `<target>` the
        // DEFINITION; twig's words are the other way round.
        Kind::Link(_) => Tag::Reference,
        Kind::Reference { .. } => Tag::Target,
        Kind::Footnote { .. } => Tag::Footnote,
        Kind::Citation { .. } => Tag::Citation,
        Kind::Substitution { .. } => Tag::SubstitutionDefinition,
        Kind::InlineMark(m) => match m {
            crate::ast::InlineMark::Emph => Tag::Emphasis,
            crate::ast::InlineMark::Strong => Tag::Strong,
            _ => return None,
        },
        Kind::TextLeaf { kind, .. } => match kind {
            TextLeafKind::Verbatim => Tag::Literal,
            TextLeafKind::CitationReference => Tag::CitationReference,
            TextLeafKind::SubstitutionReference => Tag::SubstitutionReference,
            _ => return None,
        },
        Kind::MarkupLeaf { kind, .. } => match kind {
            MarkupLeafKind::Comment => Tag::Comment,
            _ => return None,
        },
        Kind::Container(c) => return Tag::from_name(&c.name),

        Kind::Str(_)
        | Kind::Heading { .. }
        | Kind::RawBlock { .. }
        | Kind::Metadata { .. }
        | Kind::TaskList { .. }
        | Kind::TaskListItem { .. }
        | Kind::SoftBreak
        | Kind::HardBreak
        | Kind::NonBreakingSpace
        | Kind::RawInline { .. }
        | Kind::SmartPunctuation(_)
        | Kind::Image(_)
        | Kind::ProcessingInstruction { .. } => return None,
    })
}

/// docutils spells three constructs `<target>`; only the EXTERNAL one (no
/// children, a `refuri`) is twig's `Kind::Reference`. The indirect (alias) and
/// internal (anchor) shapes stay generic.
fn decode_target(children: &[NodeId], attrs: &[KeyVal]) -> Option<Kind> {
    if !children.is_empty() {
        return None;
    }
    let destination = attr_value(attrs, b"refuri")?;
    Some(Kind::Reference { label: definition_name(attrs).to_vec(), destination: destination.to_vec() })
}

/// The name a definition is resolved by: `names`, else `dupnames`, else `""`.
fn definition_name(attrs: &[KeyVal]) -> &[u8] {
    attr_value(attrs, b"names").or_else(|| attr_value(attrs, b"dupnames")).unwrap_or(b"")
}

/// docutils' `enumtype` as twig's `ListNumbering`.
fn decode_numbering(attrs: &[KeyVal]) -> Option<ListNumbering> {
    match attr_value(attrs, b"enumtype")? {
        b"arabic" => Some(ListNumbering::Decimal),
        b"loweralpha" => Some(ListNumbering::LowerAlpha),
        b"upperalpha" => Some(ListNumbering::UpperAlpha),
        b"lowerroman" => Some(ListNumbering::LowerRoman),
        b"upperroman" => Some(ListNumbering::UpperRoman),
        _ => None,
    }
}

/// Zig's `std.fmt.parseInt(u32, raw, 10)`: an optional `+`, decimal digits
/// (underscores allowed between digits), no overflow.
fn parse_u32(raw: &[u8]) -> Option<u32> {
    let (negative, digits) = match raw.first() {
        Some(b'+') => (false, &raw[1..]),
        Some(b'-') => (true, &raw[1..]),
        _ => (false, raw),
    };
    if digits.is_empty() || digits[0] == b'_' || digits[digits.len() - 1] == b'_' {
        return None;
    }
    let mut n: u32 = 0;
    let mut prev_underscore = false;
    for &c in digits {
        if c == b'_' {
            if prev_underscore {
                return None;
            }
            prev_underscore = true;
            continue;
        }
        prev_underscore = false;
        if !c.is_ascii_digit() {
            return None;
        }
        n = n.checked_mul(10)?.checked_add((c - b'0') as u32)?;
    }
    // An unsigned `-0` parses (to 0); any other negative overflows.
    if negative && n != 0 {
        return None;
    }
    Some(n)
}

pub(crate) fn parse_u32_zig(raw: &[u8]) -> Option<u32> {
    parse_u32(raw)
}

/// `start` is written only when not 1; absent (or non-numeric) means `None`.
fn decode_start(attrs: &[KeyVal]) -> Option<u32> {
    parse_u32(attr_value(attrs, b"start")?)
}

/// A cell's grid extent from `morecols`/`morerows` (one more than the
/// attribute); absent or non-numeric means 1.
fn span_extent(attrs: &[KeyVal], key: &[u8]) -> u32 {
    let Some(raw) = attr_value(attrs, key) else { return 1 };
    let Some(more) = parse_u32(raw) else { return 1 };
    more.wrapping_add(1)
}

/// The value of `attrs`'s `key`, first match.
fn attr_value<'a>(attrs: &'a [KeyVal], key: &[u8]) -> Option<&'a [u8]> {
    for kv in attrs {
        if kv.key == key {
            return kv.value.as_deref();
        }
    }
    None
}

/// The text a text-carrying mapping absorbs: `children` must be exactly one
/// `str` node (which is then orphaned).
fn sole_str<'a>(b: &'a Builder, children: &[NodeId]) -> Option<&'a [u8]> {
    if children.len() != 1 {
        return None;
    }
    match &b.nodes[children[0] as usize].kind {
        Kind::Str(t) => Some(t),
        _ => None,
    }
}

// ── coverage ───────────────────────────────────────────────────────────────

/// What a decode saw — how much of docutils' vocabulary twig's `Ast` holds
/// semantically versus behind the `container` escape hatch. Accumulates
/// across cases.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Coverage {
    /// Per `Tag`, how many instances decoded to a semantic twig kind.
    pub semantic: [u32; Tag::COUNT],
    /// Per `Tag`, how many fell back to a generic `container`.
    pub generic: [u32; Tag::COUNT],
    /// Per `Tag`, how many produced NO node (`dissolves`).
    pub dissolved: [u32; Tag::COUNT],
    /// `Text` nodes decoded to `str`.
    pub text_nodes: u32,
    /// Text lines that LOOK like an element but whose name is not a known
    /// docutils element.
    pub unknown_tag_shaped_text: u32,
}

impl Default for Coverage {
    fn default() -> Coverage {
        Coverage {
            semantic: [0; Tag::COUNT],
            generic: [0; Tag::COUNT],
            dissolved: [0; Tag::COUNT],
            text_nodes: 0,
            unknown_tag_shaped_text: 0,
        }
    }
}

impl Coverage {
    pub fn semantic_total(&self) -> u32 {
        self.semantic.iter().sum()
    }

    pub fn generic_total(&self) -> u32 {
        self.generic.iter().sum()
    }

    pub fn dissolved_total(&self) -> u32 {
        self.dissolved.iter().sum()
    }

    /// Elements decoded, text nodes excluded.
    pub fn element_total(&self) -> u32 {
        self.semantic_total() + self.generic_total() + self.dissolved_total()
    }
}

// ── line scanning ──────────────────────────────────────────────────────────

enum Scanned<'a> {
    /// A well-formed element line whose name is a known docutils element.
    Element { tag: Tag, attrs_src: &'a [u8] },
    /// A well-formed element line whose name is NOT a known element.
    UnknownTag,
    /// Not element-shaped at all.
    Text,
}

fn is_name_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

fn is_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b':' || c == b'.' || c == b'-'
}

/// Classify one already-dedented line. Recognizes exactly
/// `<name key="value" ...>` with no trailing content.
fn scan_line(body: &[u8]) -> Scanned<'_> {
    if body.len() < 3 || body[0] != b'<' || body[body.len() - 1] != b'>' {
        return Scanned::Text;
    }
    let mut i = 1;
    if i >= body.len() || !is_name_start(body[i]) {
        return Scanned::Text;
    }
    let name_start = i;
    while i < body.len() && is_name_char(body[i]) {
        i += 1;
    }
    let name = &body[name_start..i];

    let attrs_start = i;
    loop {
        let mut j = i;
        while j < body.len() && body[j] == b' ' {
            j += 1;
        }
        if j == body.len() - 1 && body[j] == b'>' {
            break;
        }
        if j == i {
            return Scanned::Text;
        }
        if j >= body.len() || !is_name_char(body[j]) {
            return Scanned::Text;
        }
        let key_start = j;
        while j < body.len() && is_name_char(body[j]) {
            j += 1;
        }
        if j == key_start {
            return Scanned::Text;
        }
        if j + 1 >= body.len() || body[j] != b'=' || body[j + 1] != b'"' {
            return Scanned::Text;
        }
        j += 2;
        while j < body.len() && body[j] != b'"' {
            j += 1;
        }
        if j >= body.len() {
            return Scanned::Text;
        }
        i = j + 1;
    }
    let attrs_src = &body[attrs_start..body.len() - 1];
    match Tag::from_name(name) {
        Some(tag) => Scanned::Element { tag, attrs_src },
        None => Scanned::UnknownTag,
    }
}

/// Split an already-validated attribute region into `key="value"` pairs.
fn scan_attrs(src: &[u8], out: &mut Vec<KeyVal>) {
    let mut i = 0;
    while i < src.len() {
        while i < src.len() && src[i] == b' ' {
            i += 1;
        }
        if i >= src.len() {
            break;
        }
        let key_start = i;
        while i < src.len() && is_name_char(src[i]) {
            i += 1;
        }
        let key = &src[key_start..i];
        i += 2;
        let val_start = i;
        while i < src.len() && src[i] != b'"' {
            i += 1;
        }
        let value = &src[val_start..i];
        i += 1;
        out.push(KeyVal::new(key, Some(value)));
    }
}

// ── decode ─────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// The input was empty, or its first line was not an element.
    NoRoot,
    /// An element line sat deeper than its parent allows.
    IndentJump,
    /// A text line appeared before any element opened it.
    TextOutsideRoot,
}

impl DecodeError {
    /// Zig's `@errorName`.
    pub fn name(self) -> &'static str {
        match self {
            DecodeError::NoRoot => "NoRoot",
            DecodeError::IndentJump => "IndentJump",
            DecodeError::TextOutsideRoot => "TextOutsideRoot",
        }
    }
}

struct Frame<'a> {
    tag: Tag,
    attrs_src: &'a [u8],
    children: Vec<NodeId>,
}

struct Decoder<'a, 'c> {
    b: Builder,
    stack: Vec<Frame<'a>>,
    run: Vec<u8>,
    run_open: bool,
    coverage: Option<&'c mut Coverage>,
    root: Option<NodeId>,
}

/// Decode a docutils pformat doctree into a bare `Ast` (no positions: a
/// doctree carries none into the ORIGINAL rST). `coverage`, when given,
/// accumulates this decode's tallies.
pub fn decode(text: &[u8], coverage: Option<&mut Coverage>) -> Result<Ast, DecodeError> {
    let mut d =
        Decoder { b: Builder::new(), stack: Vec::new(), run: Vec::new(), run_open: false, coverage, root: None };

    // Exactly one trailing newline is a terminator rather than a line.
    let body_text = if text.ends_with(b"\n") { &text[..text.len() - 1] } else { text };
    if body_text.is_empty() {
        return Err(DecodeError::NoRoot);
    }

    for line in body_text.split(|&c| c == b'\n') {
        let mut indent = 0;
        while indent < line.len() && line[indent] == b' ' {
            indent += 1;
        }
        let body = &line[indent..];

        let scanned = scan_line(body);
        if let Scanned::Element { tag, attrs_src } = scanned {
            if indent % INDENT_WIDTH == 0 {
                let depth = indent / INDENT_WIDTH;
                if depth > d.stack.len() {
                    return Err(DecodeError::IndentJump);
                }
                d.flush_run();
                while d.stack.len() > depth {
                    d.close_top();
                }
                d.stack.push(Frame { tag, attrs_src, children: Vec::new() });
                continue;
            }
        }

        if let Scanned::UnknownTag = scanned {
            if let Some(c) = d.coverage.as_deref_mut() {
                c.unknown_tag_shaped_text += 1;
            }
        }

        // A text line. Its owner is the deepest frame whose child indent is at
        // most this line's. Text NEVER closes the root.
        if d.stack.is_empty() {
            return Err(DecodeError::TextOutsideRoot);
        }
        while d.stack.len() * INDENT_WIDTH > indent && d.stack.len() > 1 {
            d.flush_run();
            d.close_top();
        }

        let base = d.stack.len() * INDENT_WIDTH;
        let content: &[u8] = if line.len() > base { &line[base..] } else { b"" };
        if d.run_open {
            d.run.push(b'\n');
        }
        d.run.extend_from_slice(content);
        d.run_open = true;
    }

    d.flush_run();
    while !d.stack.is_empty() {
        d.close_top();
    }

    let root = d.root.ok_or(DecodeError::NoRoot)?;
    Ok(d.b.finish(root))
}

impl<'a, 'c> Decoder<'a, 'c> {
    /// Attach the open text run (if any) to the deepest frame as a `str`.
    fn flush_run(&mut self) {
        if !self.run_open {
            return;
        }
        self.run_open = false;
        let id = self.b.add_leaf(Kind::Str(std::mem::take(&mut self.run)));
        if let Some(c) = self.coverage.as_deref_mut() {
            c.text_nodes += 1;
        }
        self.stack.last_mut().expect("a run implies an open frame").children.push(id);
    }

    /// Build the deepest frame into a node, attach it to its parent (or record
    /// it as the root), and pop it.
    fn close_top(&mut self) {
        let frame = self.stack.pop().expect("close_top on an empty stack");
        let parent = self.stack.last().map(|f| f.tag);

        if dissolves(frame.tag, parent) {
            if frame.tag == Tag::Thead {
                mark_head_rows(&mut self.b, &frame.children);
            }
            if frame.tag == Tag::LineBlock {
                bump_line_indent(&mut self.b, &frame.children);
            }
            if let Some(c) = self.coverage.as_deref_mut() {
                c.dissolved[frame.tag.index()] += 1;
            }
            match self.stack.last_mut() {
                None => return,
                Some(top) => top.children.extend_from_slice(&frame.children),
            }
            return;
        }

        let mut attrs: Vec<KeyVal> = Vec::new();
        scan_attrs(frame.attrs_src, &mut attrs);

        let semantic = decode_kind(&self.b, frame.tag, parent, &frame.children, &attrs);
        let is_semantic = semantic.is_some();
        let kind = semantic.unwrap_or_else(|| Kind::Container(Container::named(frame.tag.name().as_bytes())));
        if let Some(c) = self.coverage.as_deref_mut() {
            if is_semantic {
                c.semantic[frame.tag.index()] += 1;
            } else {
                c.generic[frame.tag.index()] += 1;
            }
        }

        let absorbed =
            is_semantic && matches!(kind, Kind::TextLeaf { .. } | Kind::CodeBlock { .. } | Kind::MarkupLeaf { .. });
        let is_container = matches!(kind, Kind::Container(_));
        let id = self.b.add_container(kind, if absorbed { &[] } else { &frame.children });
        if is_container {
            self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
        }
        if !attrs.is_empty() {
            self.b.set_attrs(id, Attrs { entries: attrs });
        }

        match self.stack.last_mut() {
            None => self.root = Some(id),
            Some(top) => top.children.push(id),
        }
    }
}

/// Flag every row in a dissolving `<thead>`, and every cell in those rows, as a
/// header. Well-founded because pformat writes a parent AFTER its children.
fn mark_head_rows(b: &mut Builder, rows: &[NodeId]) {
    for &row_id in rows {
        match &mut b.nodes[row_id as usize].kind {
            Kind::Row { head } => *head = true,
            _ => continue,
        }
        let mut cell = b.nodes[row_id as usize].first_child;
        while let Some(id) = cell {
            if let Kind::Cell(c) = &mut b.nodes[id as usize].kind {
                c.head = true;
            }
            cell = b.nodes[id as usize].next_sibling;
        }
    }
}

/// Add one level of indent to every line in a dissolving nested
/// `<line_block>`. Shallow by construction: deeper wrappers already dissolved
/// into this one and bumped their lines once each.
fn bump_line_indent(b: &mut Builder, children: &[NodeId]) {
    for &id in children {
        if let Kind::Line { indent } = &mut b.nodes[id as usize].kind {
            *indent += 1;
        }
    }
}

// ── encode ─────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncodeError {
    /// A node whose kind has no doctree spelling — see `encode_tag`.
    UnrepresentableKind,
}

impl EncodeError {
    /// Zig's `@errorName`.
    pub fn name(self) -> &'static str {
        "UnrepresentableKind"
    }
}

/// Write `ast` as a docutils pformat doctree.
pub fn encode(ast: &Ast, w: &mut Vec<u8>) -> Result<(), EncodeError> {
    write_node(ast, ast.root, Where::default(), 0, w)
}

/// `encode` into an owned buffer.
pub fn encode_alloc(ast: &Ast) -> Result<Vec<u8>, EncodeError> {
    let mut out = Vec::new();
    encode(ast, &mut out)?;
    Ok(out)
}

fn write_indent(w: &mut Vec<u8>, depth: usize) {
    w.resize(w.len() + depth * INDENT_WIDTH, b' ');
}

/// Write `text` as a docutils `Text` node: one line per `\n`-separated piece,
/// each at `depth`, including a trailing empty piece.
fn write_text(w: &mut Vec<u8>, depth: usize, text: &[u8]) {
    for piece in text.split(|&c| c == b'\n') {
        write_indent(w, depth);
        w.extend_from_slice(piece);
        w.push(b'\n');
    }
}

fn write_node(ast: &Ast, id: NodeId, wh: Where, depth: usize, w: &mut Vec<u8>) -> Result<(), EncodeError> {
    let node = ast.node(id);
    if let Kind::Str(s) = &node.kind {
        write_text(w, depth, s);
        return Ok(());
    }

    // Which construct the definition-list four spell is settled at the list
    // and inherited below it.
    let option_list = match node.kind {
        Kind::DefinitionList => is_option_list(ast, id),
        Kind::DefinitionListItem | Kind::Term | Kind::Definition => wh.option_list,
        _ => false,
    };

    let tag =
        encode_tag(&node.kind, Where { parent: wh.parent, option_list }).ok_or(EncodeError::UnrepresentableKind)?;
    write_indent(w, depth);
    w.push(b'<');
    w.extend_from_slice(tag.name().as_bytes());

    // Attributes come from `attrs` and ONLY from `attrs`, never from a kind's
    // payload, sorted by name as docutils' `attlist()` does.
    let attrs = ast.attrs_of(id);
    if !attrs.entries.is_empty() {
        let mut sorted: Vec<&KeyVal> = attrs.entries.iter().collect();
        sorted.sort_by(|a, b| a.key.cmp(&b.key));
        for kv in sorted {
            w.push(b' ');
            w.extend_from_slice(&kv.key);
            w.extend_from_slice(b"=\"");
            w.extend_from_slice(kv.value.as_deref().unwrap_or(b""));
            w.push(b'"');
        }
    }
    w.push(b'>');
    w.push(b'\n');

    // A text-carrying kind writes back its absorbed `Text` child.
    match &node.kind {
        Kind::TextLeaf { text, .. } => write_text(w, depth + 1, text),
        Kind::CodeBlock { text, .. } => write_text(w, depth + 1, text),
        Kind::MarkupLeaf { text, .. } => write_text(w, depth + 1, text),
        _ => {}
    }

    if node.kind == Kind::Table {
        return write_table(ast, id, depth, w);
    }
    if node.kind == Kind::LineBlock {
        return write_line_block(ast, id, depth, w);
    }

    // The option-list answer descends exactly two levels and stops.
    let child_where = Where {
        parent: Some(node.kind.tag()),
        option_list: match node.kind {
            Kind::DefinitionList | Kind::DefinitionListItem => option_list,
            _ => false,
        },
    };
    for child in ast.children(id) {
        write_node(ast, child.id, child_where, depth + 1, w)?;
    }
    Ok(())
}

/// Write a line block's lines back into docutils' nesting: one wrapper
/// `<line_block>` per level of `indent`. The exact inverse of the dissolution.
fn write_line_block(ast: &Ast, id: NodeId, depth: usize, w: &mut Vec<u8>) -> Result<(), EncodeError> {
    let mut open: u32 = 0;
    for child in ast.children(id) {
        let indent = match child.kind {
            Kind::Line { indent } => indent,
            _ => 0,
        };
        while open < indent {
            write_indent(w, depth + 1 + open as usize);
            w.extend_from_slice(b"<line_block>\n");
            open += 1;
        }
        open = indent;
        write_node(
            ast,
            child.id,
            Where { parent: Some(KindTag::LineBlock), option_list: false },
            depth + 1 + open as usize,
            w,
        )?;
    }
    Ok(())
}

/// Write a table's children back into docutils' shape: the caption stays a
/// direct child, the columns and rows go under a synthesized `<tgroup>` with
/// header rows under `<thead>` and the rest under `<tbody>`.
fn write_table(ast: &Ast, id: NodeId, depth: usize, w: &mut Vec<u8>) -> Result<(), EncodeError> {
    let table_where = Where { parent: Some(KindTag::Table), option_list: false };
    let mut cols = 0usize;
    let mut head_rows = 0usize;
    let mut body_rows = 0usize;
    for child in ast.children(id) {
        match child.kind {
            Kind::Column => cols += 1,
            Kind::Row { head } => {
                if head {
                    head_rows += 1
                } else {
                    body_rows += 1
                }
            }
            _ => write_node(ast, child.id, table_where, depth + 1, w)?,
        }
    }

    if cols == 0 && head_rows == 0 && body_rows == 0 {
        return Ok(());
    }

    write_indent(w, depth + 1);
    w.extend_from_slice(format!("<tgroup cols=\"{}\">\n", cols).as_bytes());

    for child in ast.children(id) {
        if child.kind != Kind::Column {
            continue;
        }
        write_node(ast, child.id, table_where, depth + 2, w)?;
    }

    // docutils always writes a `<tbody>`.
    if head_rows > 0 {
        write_row_group(ast, id, true, depth + 2, w)?;
    }
    write_row_group(ast, id, false, depth + 2, w)
}

/// Write one `<thead>`/`<tbody>` and its rows. Grouping is by FLAG, not by run:
/// a docutils `<tgroup>` admits at most one `<thead>` and exactly one `<tbody>`.
fn write_row_group(ast: &Ast, table: NodeId, head: bool, depth: usize, w: &mut Vec<u8>) -> Result<(), EncodeError> {
    write_indent(w, depth);
    w.extend_from_slice(if head { b"<thead>\n" } else { b"<tbody>\n" });
    for child in ast.children(table) {
        if let Kind::Row { head: h } = child.kind {
            if h == head {
                write_node(ast, child.id, Where { parent: Some(KindTag::Table), option_list: false }, depth + 1, w)?;
            }
        }
    }
    Ok(())
}

// ── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(src: &str) -> String {
        let ast = decode(src.as_bytes(), None).unwrap();
        String::from_utf8(encode_alloc(&ast).unwrap()).unwrap()
    }

    fn first_child(ast: &Ast, id: NodeId) -> NodeId {
        ast.node(id).first_child.unwrap()
    }

    fn next(ast: &Ast, id: NodeId) -> NodeId {
        ast.node(id).next_sibling.unwrap()
    }

    fn str_of(ast: &Ast, id: NodeId) -> &[u8] {
        ast.kind(id).str_text().unwrap()
    }

    fn container_name(ast: &Ast, id: NodeId) -> &[u8] {
        &ast.kind(id).container().unwrap().name
    }

    #[test]
    fn round_trips_a_nested_document_with_attributes() {
        let src = "<document source=\"test data\">\n    <paragraph>\n        Line 1.\n        Line 2.\n    <block_quote>\n        <paragraph>\n            Indented.\n";
        assert_eq!(round_trip(src), src);
    }

    #[test]
    fn attributes_are_re_emitted_sorted_by_name() {
        let mut b = Builder::new();
        let p = b.add_container(Kind::Para, &[]);
        b.set_attrs(p, Attrs { entries: vec![KeyVal::new(b"names", Some(b"z")), KeyVal::new(b"ids", Some(b"a"))] });
        let ast = b.finish(p);
        assert_eq!(encode_alloc(&ast).unwrap(), b"<paragraph ids=\"a\" names=\"z\">\n");
    }

    #[test]
    fn text_interleaved_with_inline_elements_keeps_its_trailing_whitespace() {
        let src = "<document source=\"test data\">\n    <paragraph>\n        <reference name=\"ref\" refname=\"ref\">\n            ref\n        , and\n        <emphasis>\n            more\n";
        assert_eq!(round_trip(src), src);
    }

    #[test]
    fn a_tag_shaped_text_line_whose_name_is_not_a_docutils_element_stays_text() {
        let src = "<document source=\"test data\">\n    <option_argument delimiter=\"=\">\n        <URL>\n";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        assert_eq!(cov.unknown_tag_shaped_text, 1);
        let opt = first_child(&ast, ast.root);
        assert_eq!(str_of(&ast, first_child(&ast, opt)), b"<URL>");
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_blank_line_inside_a_literal_block_is_written_as_the_bare_indent() {
        let src = "<document source=\"test data\">\n    <literal_block xml:space=\"preserve\">\n        line one\n        \n        line three\n";
        let ast = decode(src.as_bytes(), None).unwrap();
        let lb = first_child(&ast, ast.root);
        assert_eq!(ast.kind(lb), &Kind::CodeBlock { lang: None, text: b"line one\n\nline three".to_vec() });
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_text_line_indented_past_its_own_base_keeps_that_indentation() {
        let src = "<document source=\"test data\">\n    <paragraph>\n        normal\n         one space in\n";
        assert_eq!(round_trip(src), src);
    }

    #[test]
    fn an_element_with_no_children_is_one_line() {
        let src = "<document source=\"test data\">\n    <comment xml:space=\"preserve\">\n    <transition>\n";
        assert_eq!(round_trip(src), src);
        let mut cov = Coverage::default();
        decode(src.as_bytes(), Some(&mut cov)).unwrap();
        assert_eq!(cov.generic[Tag::Comment.index()], 1);
        assert_eq!(cov.semantic[Tag::Comment.index()], 0);
    }

    #[test]
    fn a_literal_block_with_a_lone_text_child_decodes_to_a_code_block() {
        let src = "<document source=\"test data\">\n    <literal_block xml:space=\"preserve\">\n        code here\n";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let lb = first_child(&ast, ast.root);
        assert_eq!(ast.kind(lb), &Kind::CodeBlock { lang: None, text: b"code here".to_vec() });
        assert_eq!(ast.attrs_of(lb).get(b"xml:space"), Some(&b"preserve"[..]));
        assert_eq!(cov.semantic[Tag::LiteralBlock.index()], 1);
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_citations_name_is_names_and_its_label_is_the_written_form() {
        let src = "<document source=\"test data\">\n    <citation ids=\"target\" names=\"target\">\n        <label>\n            TARGET\n        <paragraph>\n            Body.\n";
        let ast = decode(src.as_bytes(), None).unwrap();
        let cit = first_child(&ast, ast.root);
        assert_eq!(ast.kind(cit), &Kind::Citation { label: b"target".to_vec() });
        let label = first_child(&ast, cit);
        assert_eq!(container_name(&ast, label), b"label");
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_citation_reference_keeps_the_written_label_and_leaves_refname_in_attrs() {
        let src = "<document source=\"test data\">\n    <paragraph>\n        <citation_reference ids=\"citation-reference-1\" refname=\"cit1\">\n            CIT1\n";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let para = first_child(&ast, ast.root);
        let r = first_child(&ast, para);
        assert_eq!(ast.kind(r), &Kind::TextLeaf { kind: TextLeafKind::CitationReference, text: b"CIT1".to_vec() });
        assert_eq!(ast.attrs_of(r).get(b"refname"), Some(&b"cit1"[..]));
        assert_eq!(cov.semantic[Tag::CitationReference.index()], 1);
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_substitution_definition_holds_its_body_inline() {
        let src =
            "<document source=\"test data\">\n    <substitution_definition names=\"RST\">\n        reStructuredText\n";
        let ast = decode(src.as_bytes(), None).unwrap();
        let sub = first_child(&ast, ast.root);
        assert_eq!(ast.kind(sub), &Kind::Substitution { label: b"RST".to_vec() });
        assert_eq!(ast.kind(sub).content_model(), crate::ast::ContentModel::Inlines);
        assert_eq!(str_of(&ast, first_child(&ast, sub)), b"reStructuredText");
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_table_is_flattened_out_of_tgroup_thead_tbody_and_built_back_into_them() {
        let src = "<document source=\"test data\">
    <table>
        <title>
            Prices
        <tgroup cols=\"2\">
            <colspec colwidth=\"10\" stub=\"1\">
            <colspec colwidth=\"20\">
            <thead>
                <row>
                    <entry>
                        <paragraph>
                            Treat
                    <entry>
                        <paragraph>
                            Price
            <tbody>
                <row>
                    <entry morecols=\"1\">
                        <paragraph>
                            Sold out
";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let table = first_child(&ast, ast.root);
        assert_eq!(ast.kind(table), &Kind::Table);
        let kinds: Vec<KindTag> = ast.children(table).map(|c| c.kind.tag()).collect();
        assert_eq!(kinds, vec![KindTag::Caption, KindTag::Column, KindTag::Column, KindTag::Row, KindTag::Row]);

        let caption = first_child(&ast, table);
        let stub_col = next(&ast, caption);
        assert_eq!(ast.attrs_of(stub_col).get(b"colwidth"), Some(&b"10"[..]));
        assert_eq!(ast.attrs_of(stub_col).get(b"stub"), Some(&b"1"[..]));

        let rows: Vec<_> = ast.table_rows(table).collect();
        let head = rows.iter().find(|r| r.head).unwrap().id;
        let body = rows.iter().find(|r| !r.head).unwrap().id;
        assert!(matches!(ast.kind(first_child(&ast, head)), Kind::Cell(c) if c.head));
        assert!(matches!(ast.kind(first_child(&ast, body)), Kind::Cell(c) if !c.head));

        let spanning = first_child(&ast, body);
        assert!(matches!(ast.kind(spanning), Kind::Cell(c) if c.colspan == 2 && c.rowspan == 1));
        assert_eq!(ast.attrs_of(spanning).get(b"morecols"), Some(&b"1"[..]));

        assert_eq!(cov.dissolved[Tag::Tgroup.index()], 1);
        assert_eq!(cov.dissolved[Tag::Thead.index()], 1);
        assert_eq!(cov.dissolved[Tag::Tbody.index()], 1);
        assert_eq!(cov.generic[Tag::Tgroup.index()], 0);
        assert_eq!(cov.semantic[Tag::Colspec.index()], 2);

        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_line_blocks_nesting_flattens_to_a_per_line_indent_and_is_rebuilt_from_it() {
        let src = "<document source=\"test data\">
    <line_block>
        <line>
            Initial indentation is also significant and preserved:
        <line>
        <line_block>
            <line>
                Indented 4 spaces
        <line>
            Not indented
        <line_block>
            <line_block>
                <line>
                    Indented 2 spaces
                <line_block>
                    <line>
                        Indented 4 spaces
            <line>
                Only one space
            <line>
            <line_block>
                <line>
                    Continuation lines may be indented less
                    than their base lines.
";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let block = first_child(&ast, ast.root);
        assert_eq!(ast.kind(block), &Kind::LineBlock);
        let indents: Vec<u32> = ast
            .children(block)
            .map(|c| match c.kind {
                Kind::Line { indent } => indent,
                _ => panic!(),
            })
            .collect();
        assert_eq!(indents, vec![0, 0, 1, 0, 2, 3, 1, 1, 2]);
        let empty = ast.children(block).filter(|c| c.first_child.is_none()).count();
        assert_eq!(empty, 2);
        assert_eq!(cov.semantic[Tag::LineBlock.index()], 1);
        assert_eq!(cov.dissolved[Tag::LineBlock.index()], 5);
        assert_eq!(cov.generic[Tag::LineBlock.index()], 0);
        assert_eq!(cov.semantic[Tag::Line.index()], 9);
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn an_option_list_is_a_definition_list_told_apart_on_the_way_out_by_its_options() {
        let src = "<document source=\"test data\">
    <option_list>
        <option_list_item>
            <option_group>
                <option>
                    <option_string>
                        -b
                    <option_argument delimiter=\" \">
                        file
                <option>
                    <option_string>
                        --bbbb
                    <option_argument delimiter=\"=\">
                        file
            <description>
                <paragraph>
                    option -b
";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let list = first_child(&ast, ast.root);
        assert_eq!(ast.kind(list), &Kind::DefinitionList);
        let item = first_child(&ast, list);
        assert_eq!(ast.kind(item), &Kind::DefinitionListItem);
        let group = first_child(&ast, item);
        assert_eq!(ast.kind(group), &Kind::Term);
        assert_eq!(ast.kind(next(&ast, group)), &Kind::Definition);
        let option = first_child(&ast, group);
        assert_eq!(container_name(&ast, option), b"option");
        let arg = next(&ast, first_child(&ast, option));
        assert_eq!(container_name(&ast, arg), b"option_argument");
        assert_eq!(ast.attrs_of(arg).get(b"delimiter"), Some(&b" "[..]));
        assert_eq!(cov.semantic[Tag::OptionList.index()], 1);
        assert_eq!(cov.semantic[Tag::OptionGroup.index()], 1);
        assert_eq!(cov.generic[Tag::Option.index()], 2);
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_real_definition_list_still_encodes_as_one_options_or_not() {
        let src = "<document source=\"test data\">
    <definition_list>
        <definition_list_item>
            <term>
                -b
            <definition>
                <paragraph>
                    Looks like an option, is not one.
";
        assert_eq!(round_trip(src), src);
    }

    #[test]
    fn an_option_list_nested_in_a_description_does_not_infect_the_list_around_it() {
        let src = "<document source=\"test data\">
    <option_list>
        <option_list_item>
            <option_group>
                <option>
                    <option_string>
                        -a
            <description>
                <definition_list>
                    <definition_list_item>
                        <term>
                            see also
                        <definition>
                            <paragraph>
                                the manual
";
        assert_eq!(round_trip(src), src);
    }

    #[test]
    fn an_enumerated_list_reads_enumtype_start_into_the_kind_and_leaves_all_four_attributes_alone() {
        let src = "<document source=\"test data\">
    <enumerated_list enumtype=\"lowerroman\" prefix=\"(\" start=\"3\" suffix=\")\">
        <list_item>
            <paragraph>
                Item iii.
";
        let ast = decode(src.as_bytes(), None).unwrap();
        let list = first_child(&ast, ast.root);
        assert_eq!(
            ast.kind(list),
            &Kind::OrderedList { numbering: ListNumbering::LowerRoman, tight: false, start: Some(3) }
        );
        assert_eq!(ast.attrs_of(list).get(b"prefix"), Some(&b"("[..]));
        assert_eq!(ast.attrs_of(list).get(b"suffix"), Some(&b")"[..]));
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn an_enumerated_list_with_no_enumtype_stays_a_generic_container() {
        let src = "<document source=\"test data\">\n    <enumerated_list>\n        <list_item>\n";
        let ast = decode(src.as_bytes(), None).unwrap();
        let list = first_child(&ast, ast.root);
        assert_eq!(container_name(&ast, list), b"enumerated_list");
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn only_a_nested_line_block_dissolves_the_outermost_keeps_its_attributes() {
        let src = "<document source=\"test data\">
    <line_block classes=\"linear\" ids=\"cit-short\" names=\"cit:short\">
        <line>
            This is a line block with options.
";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let block = first_child(&ast, ast.root);
        assert_eq!(ast.kind(block), &Kind::LineBlock);
        assert_eq!(ast.attrs_of(block).get(b"classes"), Some(&b"linear"[..]));
        assert_eq!(cov.dissolved[Tag::LineBlock.index()], 0);
        assert_eq!(ast.kind(first_child(&ast, block)), &Kind::Line { indent: 0 });
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_caption_is_a_tables_title_but_a_figures_caption() {
        let src = "<document source=\"test data\">\n    <figure>\n        <caption>\n            A picture\n";
        let ast = decode(src.as_bytes(), None).unwrap();
        let figure = first_child(&ast, ast.root);
        let caption = first_child(&ast, figure);
        assert_eq!(ast.kind(caption), &Kind::Caption);
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn a_decoded_tree_owns_its_payload_strings_and_outlives_the_source() {
        let src = "<document source=\"test data\">
    <citation ids=\"cit\" names=\"cit\">
        <paragraph>
            Body.
    <substitution_definition names=\"RST\">
        reStructuredText
";
        let owned = src.as_bytes().to_vec();
        let ast = decode(&owned, None).unwrap();
        drop(owned);
        let cit = first_child(&ast, ast.root);
        assert_eq!(ast.kind(cit), &Kind::Citation { label: b"cit".to_vec() });
        let sub = next(&ast, cit);
        assert_eq!(ast.kind(sub), &Kind::Substitution { label: b"RST".to_vec() });
    }

    #[test]
    fn an_unmapped_element_decodes_to_a_generic_container_named_after_its_tag() {
        let src = "<document source=\"test data\">
    <system_message level=\"3\" line=\"3\" source=\"test data\" type=\"ERROR\">
        <paragraph>
            Unexpected indentation.
";
        let mut cov = Coverage::default();
        let ast = decode(src.as_bytes(), Some(&mut cov)).unwrap();
        let sm = first_child(&ast, ast.root);
        assert_eq!(container_name(&ast, sm), b"system_message");
        assert_eq!(ast.attrs_of(sm).get(b"type"), Some(&b"ERROR"[..]));
        assert_eq!(cov.generic[Tag::SystemMessage.index()], 1);
        assert_eq!(cov.semantic[Tag::Paragraph.index()], 1);
        assert_eq!(encode_alloc(&ast).unwrap(), src.as_bytes());
    }

    #[test]
    fn decode_rejects_input_that_is_not_a_doctree() {
        assert_eq!(decode(b"", None).unwrap_err(), DecodeError::NoRoot);
        assert_eq!(decode(b"bare text\n", None).unwrap_err(), DecodeError::TextOutsideRoot);
    }

    #[test]
    fn the_tag_vocabulary_is_the_full_docutils_set() {
        assert_eq!(Tag::COUNT, 98);
        for &t in Tag::ALL {
            assert_eq!(Tag::from_name(t.name().as_bytes()), Some(t));
        }
        assert_eq!(Tag::from_name(b"URL"), None);
    }
}
