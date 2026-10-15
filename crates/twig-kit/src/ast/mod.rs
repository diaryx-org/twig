//! AST = Abstract Syntax Tree for a parsed document.
//!
//! Twig's SHARED node vocabulary: every language module parses into this one
//! node model, so structural operations and printers written against [`Ast`]
//! work regardless of which format produced the tree. See `docs/AST-KINDS.md`
//! for why each kind exists.
//!
//! The arena is index-based (`NodeId = u32`, a flat `Vec<Node>`), containers
//! link their children through `first_child`/`next_sibling`, and every string
//! a node carries is owned by the tree.
//!
//! This module holds MEANING, not POSITION: byte offsets live in
//! [`crate::document::Document`]'s id-indexed side tables.
//!
//! Strings are bytes (`Vec<u8>`): a document need not be valid UTF-8, and every
//! offset Twig hands out is a byte offset.

pub mod builder;
pub mod compact;
pub mod json;
pub mod reader;
pub mod table;

pub mod select;
pub mod verse;

pub use builder::Builder;

pub type NodeId = u32;
pub type AttrsId = u32;
pub type Bytes = Vec<u8>;

/// One node of the arena.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    pub id: NodeId,
    pub kind: Kind,
    pub first_child: Option<NodeId>,
    pub next_sibling: Option<NodeId>,
    /// Index into [`Ast::attrs`], or `None` when the node carries none.
    pub attrs: Option<AttrsId>,
}

/// A complete parsed tree.
#[derive(Clone, Debug, Default)]
pub struct Ast {
    /// The single `doc` node all content hangs off of.
    pub root: NodeId,
    pub nodes: Vec<Node>,
    /// Indexed by `Node::attrs`.
    pub attrs: Vec<Attrs>,
}

// ── Payload shapes ──────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InlineMark {
    Emph,
    Strong,
    Mark,
    Superscript,
    Subscript,
    Insert,
    Delete,
    DoubleQuoted,
    SingleQuoted,
}

impl InlineMark {
    pub const ALL: [InlineMark; 9] = [
        InlineMark::Emph,
        InlineMark::Strong,
        InlineMark::Mark,
        InlineMark::Superscript,
        InlineMark::Subscript,
        InlineMark::Insert,
        InlineMark::Delete,
        InlineMark::DoubleQuoted,
        InlineMark::SingleQuoted,
    ];
    pub fn name(self) -> &'static str {
        match self {
            InlineMark::Emph => "emph",
            InlineMark::Strong => "strong",
            InlineMark::Mark => "mark",
            InlineMark::Superscript => "superscript",
            InlineMark::Subscript => "subscript",
            InlineMark::Insert => "insert",
            InlineMark::Delete => "delete",
            InlineMark::DoubleQuoted => "double_quoted",
            InlineMark::SingleQuoted => "single_quoted",
        }
    }
    pub fn from_name(s: &str) -> Option<InlineMark> {
        InlineMark::ALL.into_iter().find(|m| m.name() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TextLeafKind {
    /// `:name:` — payload is the name, no surrounding colons.
    Symb,
    /// `` `code` `` — payload is the interior.
    Verbatim,
    InlineMath,
    DisplayMath,
    Url,
    Email,
    /// `[^label]` used inline; payload is the label.
    FootnoteReference,
    /// rST's `[CIT2002]_`.
    CitationReference,
    /// rST's `|name|`.
    SubstitutionReference,
}

impl TextLeafKind {
    pub const ALL: [TextLeafKind; 9] = [
        TextLeafKind::Symb,
        TextLeafKind::Verbatim,
        TextLeafKind::InlineMath,
        TextLeafKind::DisplayMath,
        TextLeafKind::Url,
        TextLeafKind::Email,
        TextLeafKind::FootnoteReference,
        TextLeafKind::CitationReference,
        TextLeafKind::SubstitutionReference,
    ];
    pub fn name(self) -> &'static str {
        match self {
            TextLeafKind::Symb => "symb",
            TextLeafKind::Verbatim => "verbatim",
            TextLeafKind::InlineMath => "inline_math",
            TextLeafKind::DisplayMath => "display_math",
            TextLeafKind::Url => "url",
            TextLeafKind::Email => "email",
            TextLeafKind::FootnoteReference => "footnote_reference",
            TextLeafKind::CitationReference => "citation_reference",
            TextLeafKind::SubstitutionReference => "substitution_reference",
        }
    }
    pub fn from_name(s: &str) -> Option<TextLeafKind> {
        TextLeafKind::ALL.into_iter().find(|m| m.name() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarkupLeafKind {
    /// `<!-- ... -->`; payload is the text between the delimiters.
    Comment,
    /// Everything between `<!DOCTYPE` and `>`, as written.
    Doctype,
    /// `<![CDATA[...]]>`; payload is the raw contents.
    Cdata,
}

impl MarkupLeafKind {
    pub const ALL: [MarkupLeafKind; 3] = [MarkupLeafKind::Comment, MarkupLeafKind::Doctype, MarkupLeafKind::Cdata];
    pub fn name(self) -> &'static str {
        match self {
            MarkupLeafKind::Comment => "comment",
            MarkupLeafKind::Doctype => "doctype",
            MarkupLeafKind::Cdata => "cdata",
        }
    }
    pub fn from_name(s: &str) -> Option<MarkupLeafKind> {
        MarkupLeafKind::ALL.into_iter().find(|m| m.name() == s)
    }
}

/// How a `container` was spelled — see `ast.zig`'s `Form`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Form {
    /// inline — djot `[label]{attrs}`, Markdown `:name[label]`.
    InlineText,
    /// block, no body — Markdown `::name[label]{attrs}`.
    BlockLeaf,
    /// block with a body — djot `:::`, Markdown `:::name`, rST `.. name::`.
    BlockFenced,
}

impl Form {
    pub fn is_block_form(self) -> bool {
        self != Form::InlineText
    }
    pub fn name(self) -> &'static str {
        match self {
            Form::InlineText => "inline_text",
            Form::BlockLeaf => "block_leaf",
            Form::BlockFenced => "block_fenced",
        }
    }
    pub fn from_name(s: &str) -> Option<Form> {
        [Form::InlineText, Form::BlockLeaf, Form::BlockFenced].into_iter().find(|m| m.name() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ListNumbering {
    Decimal,
    LowerAlpha,
    UpperAlpha,
    LowerRoman,
    UpperRoman,
}

impl ListNumbering {
    pub fn name(self) -> &'static str {
        match self {
            ListNumbering::Decimal => "decimal",
            ListNumbering::LowerAlpha => "lower_alpha",
            ListNumbering::UpperAlpha => "upper_alpha",
            ListNumbering::LowerRoman => "lower_roman",
            ListNumbering::UpperRoman => "upper_roman",
        }
    }
    pub fn from_name(s: &str) -> Option<ListNumbering> {
        [
            ListNumbering::Decimal,
            ListNumbering::LowerAlpha,
            ListNumbering::UpperAlpha,
            ListNumbering::LowerRoman,
            ListNumbering::UpperRoman,
        ]
        .into_iter()
        .find(|m| m.name() == s)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Alignment {
    #[default]
    Default,
    Left,
    Right,
    Center,
}

impl Alignment {
    pub fn name(self) -> &'static str {
        match self {
            Alignment::Default => "default",
            Alignment::Left => "left",
            Alignment::Right => "right",
            Alignment::Center => "center",
        }
    }
    pub fn from_name(s: &str) -> Option<Alignment> {
        [Alignment::Default, Alignment::Left, Alignment::Right, Alignment::Center]
            .into_iter()
            .find(|m| m.name() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SmartPunctuationKind {
    LeftSingleQuote,
    RightSingleQuote,
    LeftDoubleQuote,
    RightDoubleQuote,
    Ellipses,
    EmDash,
    EnDash,
}

impl SmartPunctuationKind {
    pub const ALL: [SmartPunctuationKind; 7] = [
        SmartPunctuationKind::LeftSingleQuote,
        SmartPunctuationKind::RightSingleQuote,
        SmartPunctuationKind::LeftDoubleQuote,
        SmartPunctuationKind::RightDoubleQuote,
        SmartPunctuationKind::Ellipses,
        SmartPunctuationKind::EmDash,
        SmartPunctuationKind::EnDash,
    ];
    /// The canonical ASCII spelling — what djot and Markdown both write back.
    pub fn ascii(self) -> &'static str {
        match self {
            SmartPunctuationKind::LeftSingleQuote | SmartPunctuationKind::RightSingleQuote => "'",
            SmartPunctuationKind::LeftDoubleQuote | SmartPunctuationKind::RightDoubleQuote => "\"",
            SmartPunctuationKind::Ellipses => "...",
            SmartPunctuationKind::EnDash => "--",
            SmartPunctuationKind::EmDash => "---",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            SmartPunctuationKind::LeftSingleQuote => "left_single_quote",
            SmartPunctuationKind::RightSingleQuote => "right_single_quote",
            SmartPunctuationKind::LeftDoubleQuote => "left_double_quote",
            SmartPunctuationKind::RightDoubleQuote => "right_double_quote",
            SmartPunctuationKind::Ellipses => "ellipses",
            SmartPunctuationKind::EmDash => "em_dash",
            SmartPunctuationKind::EnDash => "en_dash",
        }
    }
    pub fn from_name(s: &str) -> Option<SmartPunctuationKind> {
        SmartPunctuationKind::ALL.into_iter().find(|m| m.name() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Cell {
    pub head: bool,
    pub alignment: Alignment,
    pub colspan: u32,
    pub rowspan: u32,
}

impl Cell {
    pub fn new(head: bool, alignment: Alignment) -> Cell {
        Cell { head, alignment, colspan: 1, rowspan: 1 }
    }
}

/// The one payload shape behind both `link` and `image`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Link {
    pub destination: Option<Bytes>,
    pub reference: Option<Bytes>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Container {
    /// The tag or directive type: `"div"`, `"video"`, `"svg:rect"`, `"note"`.
    /// EMPTY for djot's anonymous `:::` and `[…]{…}`.
    pub name: Bytes,
    pub form: Option<Form>,
    /// The directive ARGUMENT (rST only today).
    pub argument: Option<Bytes>,
    /// The body, where the tokenizer read it as TEXT (HTML raw-text/rcdata).
    pub text: Option<Bytes>,
}

impl Container {
    pub fn named(name: &[u8]) -> Container {
        Container { name: name.to_vec(), ..Default::default() }
    }
    pub fn with_form(name: &[u8], form: Form) -> Container {
        Container { name: name.to_vec(), form: Some(form), ..Default::default() }
    }
}

/// The shared kind vocabulary. See `ast.zig`'s `Kind`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Doc,

    // ── Blocks ──
    Para,
    Heading { level: u32 },
    ThematicBreak,
    Section,
    CodeBlock { lang: Option<Bytes>, text: Bytes },
    RawBlock { format: Bytes, text: Bytes },
    Metadata { lang: Bytes, text: Bytes },
    BlockQuote,
    BulletList { tight: bool },
    OrderedList { numbering: ListNumbering, tight: bool, start: Option<u32> },
    TaskList { tight: bool },
    DefinitionList,
    LineBlock,
    Table,

    // ── Container children, and the document-level definitions ──
    ListItem,
    TaskListItem { checked: bool },
    DefinitionListItem,
    Term,
    Definition,
    Line { indent: u32 },
    Row { head: bool },
    Cell(Cell),
    Column,
    Caption,
    Footnote { label: Bytes },
    Reference { label: Bytes, destination: Bytes },
    Citation { label: Bytes },
    Substitution { label: Bytes },

    // ── Inlines ──
    Str(Bytes),
    SoftBreak,
    HardBreak,
    NonBreakingSpace,
    TextLeaf { kind: TextLeafKind, text: Bytes },
    RawInline { format: Bytes, text: Bytes },
    SmartPunctuation(SmartPunctuationKind),
    Link(Link),
    Image(Link),
    InlineMark(InlineMark),

    // ── Generic markup ──
    Container(Container),
    MarkupLeaf { kind: MarkupLeafKind, text: Bytes },
    ProcessingInstruction { target: Bytes, data: Bytes },
}

/// The bare tag of a [`Kind`], payload dropped — Zig's `std.meta.Tag(Kind)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Tag {
    Doc,
    Para,
    Heading,
    ThematicBreak,
    Section,
    CodeBlock,
    RawBlock,
    Metadata,
    BlockQuote,
    BulletList,
    OrderedList,
    TaskList,
    DefinitionList,
    LineBlock,
    Table,
    ListItem,
    TaskListItem,
    DefinitionListItem,
    Term,
    Definition,
    Line,
    Row,
    Cell,
    Column,
    Caption,
    Footnote,
    Reference,
    Citation,
    Substitution,
    Str,
    SoftBreak,
    HardBreak,
    NonBreakingSpace,
    TextLeaf,
    RawInline,
    SmartPunctuation,
    Link,
    Image,
    InlineMark,
    Container,
    MarkupLeaf,
    ProcessingInstruction,
}

impl Tag {
    pub const ALL: [Tag; 42] = [
        Tag::Doc,
        Tag::Para,
        Tag::Heading,
        Tag::ThematicBreak,
        Tag::Section,
        Tag::CodeBlock,
        Tag::RawBlock,
        Tag::Metadata,
        Tag::BlockQuote,
        Tag::BulletList,
        Tag::OrderedList,
        Tag::TaskList,
        Tag::DefinitionList,
        Tag::LineBlock,
        Tag::Table,
        Tag::ListItem,
        Tag::TaskListItem,
        Tag::DefinitionListItem,
        Tag::Term,
        Tag::Definition,
        Tag::Line,
        Tag::Row,
        Tag::Cell,
        Tag::Column,
        Tag::Caption,
        Tag::Footnote,
        Tag::Reference,
        Tag::Citation,
        Tag::Substitution,
        Tag::Str,
        Tag::SoftBreak,
        Tag::HardBreak,
        Tag::NonBreakingSpace,
        Tag::TextLeaf,
        Tag::RawInline,
        Tag::SmartPunctuation,
        Tag::Link,
        Tag::Image,
        Tag::InlineMark,
        Tag::Container,
        Tag::MarkupLeaf,
        Tag::ProcessingInstruction,
    ];

    /// The tag's own name (`@tagName`), which for the three families is the
    /// family name and NOT a published kind name.
    pub fn name(self) -> &'static str {
        match self {
            Tag::Doc => "doc",
            Tag::Para => "para",
            Tag::Heading => "heading",
            Tag::ThematicBreak => "thematic_break",
            Tag::Section => "section",
            Tag::CodeBlock => "code_block",
            Tag::RawBlock => "raw_block",
            Tag::Metadata => "metadata",
            Tag::BlockQuote => "block_quote",
            Tag::BulletList => "bullet_list",
            Tag::OrderedList => "ordered_list",
            Tag::TaskList => "task_list",
            Tag::DefinitionList => "definition_list",
            Tag::LineBlock => "line_block",
            Tag::Table => "table",
            Tag::ListItem => "list_item",
            Tag::TaskListItem => "task_list_item",
            Tag::DefinitionListItem => "definition_list_item",
            Tag::Term => "term",
            Tag::Definition => "definition",
            Tag::Line => "line",
            Tag::Row => "row",
            Tag::Cell => "cell",
            Tag::Column => "column",
            Tag::Caption => "caption",
            Tag::Footnote => "footnote",
            Tag::Reference => "reference",
            Tag::Citation => "citation",
            Tag::Substitution => "substitution",
            Tag::Str => "str",
            Tag::SoftBreak => "soft_break",
            Tag::HardBreak => "hard_break",
            Tag::NonBreakingSpace => "non_breaking_space",
            Tag::TextLeaf => "text_leaf",
            Tag::RawInline => "raw_inline",
            Tag::SmartPunctuation => "smart_punctuation",
            Tag::Link => "link",
            Tag::Image => "image",
            Tag::InlineMark => "inline_mark",
            Tag::Container => "container",
            Tag::MarkupLeaf => "markup_leaf",
            Tag::ProcessingInstruction => "processing_instruction",
        }
    }

    pub fn from_name(s: &str) -> Option<Tag> {
        Tag::ALL.into_iter().find(|t| t.name() == s)
    }
}

/// Where a kind sits in the document hierarchy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Block,
    Inline,
    Neither,
}

/// What a kind may hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContentModel {
    Blocks,
    Inlines,
    Text,
    Empty,
}

/// The generic-markup kinds, which may appear inside ANY container.
pub const GENERIC_MARKUP: [Tag; 3] = [Tag::Container, Tag::MarkupLeaf, Tag::ProcessingInstruction];

impl Kind {
    pub fn tag(&self) -> Tag {
        match self {
            Kind::Doc => Tag::Doc,
            Kind::Para => Tag::Para,
            Kind::Heading { .. } => Tag::Heading,
            Kind::ThematicBreak => Tag::ThematicBreak,
            Kind::Section => Tag::Section,
            Kind::CodeBlock { .. } => Tag::CodeBlock,
            Kind::RawBlock { .. } => Tag::RawBlock,
            Kind::Metadata { .. } => Tag::Metadata,
            Kind::BlockQuote => Tag::BlockQuote,
            Kind::BulletList { .. } => Tag::BulletList,
            Kind::OrderedList { .. } => Tag::OrderedList,
            Kind::TaskList { .. } => Tag::TaskList,
            Kind::DefinitionList => Tag::DefinitionList,
            Kind::LineBlock => Tag::LineBlock,
            Kind::Table => Tag::Table,
            Kind::ListItem => Tag::ListItem,
            Kind::TaskListItem { .. } => Tag::TaskListItem,
            Kind::DefinitionListItem => Tag::DefinitionListItem,
            Kind::Term => Tag::Term,
            Kind::Definition => Tag::Definition,
            Kind::Line { .. } => Tag::Line,
            Kind::Row { .. } => Tag::Row,
            Kind::Cell(_) => Tag::Cell,
            Kind::Column => Tag::Column,
            Kind::Caption => Tag::Caption,
            Kind::Footnote { .. } => Tag::Footnote,
            Kind::Reference { .. } => Tag::Reference,
            Kind::Citation { .. } => Tag::Citation,
            Kind::Substitution { .. } => Tag::Substitution,
            Kind::Str(_) => Tag::Str,
            Kind::SoftBreak => Tag::SoftBreak,
            Kind::HardBreak => Tag::HardBreak,
            Kind::NonBreakingSpace => Tag::NonBreakingSpace,
            Kind::TextLeaf { .. } => Tag::TextLeaf,
            Kind::RawInline { .. } => Tag::RawInline,
            Kind::SmartPunctuation(_) => Tag::SmartPunctuation,
            Kind::Link(_) => Tag::Link,
            Kind::Image(_) => Tag::Image,
            Kind::InlineMark(_) => Tag::InlineMark,
            Kind::Container(_) => Tag::Container,
            Kind::MarkupLeaf { .. } => Tag::MarkupLeaf,
            Kind::ProcessingInstruction { .. } => Tag::ProcessingInstruction,
        }
    }

    /// The name a kind reports to the OUTSIDE — JSON's `"kind"`. For a
    /// family member this is the member's name (`"emph"`), never the family.
    pub fn kind_name(&self) -> &'static str {
        match self {
            Kind::InlineMark(m) => m.name(),
            Kind::TextLeaf { kind, .. } => kind.name(),
            Kind::MarkupLeaf { kind, .. } => kind.name(),
            other => other.tag().name(),
        }
    }

    pub fn level(&self) -> Level {
        use Kind::*;
        match self {
            Para | Heading { .. } | ThematicBreak | Section | CodeBlock { .. } | RawBlock { .. }
            | Metadata { .. } | BlockQuote | BulletList { .. } | OrderedList { .. }
            | TaskList { .. } | DefinitionList | LineBlock | Table | Footnote { .. }
            | Reference { .. } | Citation { .. } | Substitution { .. } => Level::Block,

            Str(_) | SoftBreak | HardBreak | NonBreakingSpace | TextLeaf { .. } | RawInline { .. }
            | SmartPunctuation(_) | Link(_) | Image(_) | InlineMark(_) => Level::Inline,

            Container(c) => match c.form {
                Some(f) if f.is_block_form() => Level::Block,
                Some(_) => Level::Inline,
                None => Level::Neither,
            },

            Doc | ListItem | TaskListItem { .. } | DefinitionListItem | Term | Definition
            | Line { .. } | Row { .. } | Cell(_) | Column | Caption | MarkupLeaf { .. }
            | ProcessingInstruction { .. } => Level::Neither,
        }
    }

    pub fn content_model(&self) -> ContentModel {
        use Kind::*;
        match self {
            Str(_) | TextLeaf { .. } | RawInline { .. } | SmartPunctuation(_) | CodeBlock { .. }
            | RawBlock { .. } | Metadata { .. } | MarkupLeaf { .. } => ContentModel::Text,

            ThematicBreak | SoftBreak | HardBreak | NonBreakingSpace | Reference { .. }
            | ProcessingInstruction { .. } | Column => ContentModel::Empty,

            Doc | Section | BlockQuote | BulletList { .. } | OrderedList { .. } | TaskList { .. }
            | DefinitionList | LineBlock | Table | ListItem | TaskListItem { .. }
            | DefinitionListItem | Definition | Row { .. } | Cell(_) | Footnote { .. }
            | Citation { .. } => ContentModel::Blocks,

            Para | Heading { .. } | Term | Line { .. } | Caption | Link(_) | Image(_)
            | InlineMark(_) | Substitution { .. } => ContentModel::Inlines,

            Container(c) => {
                if c.text.is_some() {
                    ContentModel::Text
                } else {
                    match c.form {
                        Some(Form::BlockFenced) => ContentModel::Blocks,
                        Some(Form::BlockLeaf) | Some(Form::InlineText) => ContentModel::Inlines,
                        None => ContentModel::Blocks,
                    }
                }
            }
        }
    }

    /// The closed set of child kinds a parent gives STRUCTURAL meaning to, or
    /// `None` when its children are constrained only by `content_model`.
    pub fn structural_children(&self) -> Option<&'static [Tag]> {
        match self {
            Kind::BulletList { .. } | Kind::OrderedList { .. } => Some(&[Tag::ListItem]),
            Kind::TaskList { .. } => Some(&[Tag::TaskListItem]),
            Kind::DefinitionList => Some(&[Tag::DefinitionListItem]),
            Kind::DefinitionListItem => Some(&[Tag::Term, Tag::Definition]),
            Kind::LineBlock => Some(&[Tag::Line]),
            Kind::Table => Some(&[Tag::Caption, Tag::Column, Tag::Row]),
            Kind::Row { .. } => Some(&[Tag::Cell]),
            _ => None,
        }
    }

    /// Whether `child` may sit directly inside `self`.
    pub fn admits_child(&self, child: &Kind) -> bool {
        match self.content_model() {
            ContentModel::Text | ContentModel::Empty => return false,
            _ => {}
        }
        let tag = child.tag();
        let Some(set) = self.structural_children() else { return true };
        set.contains(&tag) || GENERIC_MARKUP.contains(&tag)
    }

    pub fn holds_opaque_text(&self) -> bool {
        self.content_model() == ContentModel::Text
    }

    pub fn is_inline_mark(&self, m: InlineMark) -> bool {
        matches!(self, Kind::InlineMark(x) if *x == m)
    }

    pub fn is_text_leaf(&self, k: TextLeafKind) -> bool {
        matches!(self, Kind::TextLeaf { kind, .. } if *kind == k)
    }

    pub fn container(&self) -> Option<&Container> {
        match self {
            Kind::Container(c) => Some(c),
            _ => None,
        }
    }

    pub fn str_text(&self) -> Option<&[u8]> {
        match self {
            Kind::Str(s) => Some(s),
            _ => None,
        }
    }
}

/// Names a kind precisely enough to match a node against it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum KindRef {
    Tag(Tag),
    Mark(InlineMark),
    TextLeaf(TextLeafKind),
    MarkupLeaf(MarkupLeafKind),
    ContainerNamed(Bytes),
}

impl KindRef {
    pub fn matches(&self, kind: &Kind) -> bool {
        match self {
            KindRef::Tag(t) => kind.tag() == *t,
            KindRef::Mark(m) => kind.is_inline_mark(*m),
            KindRef::TextLeaf(k) => kind.is_text_leaf(*k),
            KindRef::MarkupLeaf(k) => matches!(kind, Kind::MarkupLeaf { kind: x, .. } if x == k),
            KindRef::ContainerNamed(n) => matches!(kind, Kind::Container(c) if &c.name == n),
        }
    }

    /// The inverse of [`Kind::kind_name`].
    pub fn from_name(name: &str) -> Option<KindRef> {
        if let Some(m) = InlineMark::from_name(name) {
            return Some(KindRef::Mark(m));
        }
        if let Some(k) = TextLeafKind::from_name(name) {
            return Some(KindRef::TextLeaf(k));
        }
        if let Some(k) = MarkupLeafKind::from_name(name) {
            return Some(KindRef::MarkupLeaf(k));
        }
        match Tag::from_name(name)? {
            Tag::InlineMark | Tag::TextLeaf | Tag::MarkupLeaf => None,
            t => Some(KindRef::Tag(t)),
        }
    }
}

/// A single attribute pair. A `None` value is a *bare* attribute (HTML
/// `disabled`), which round-trips distinctly from `disabled=""`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeyVal {
    pub key: Bytes,
    pub value: Option<Bytes>,
}

impl KeyVal {
    pub fn new(key: &[u8], value: Option<&[u8]>) -> KeyVal {
        KeyVal { key: key.to_vec(), value: value.map(|v| v.to_vec()) }
    }
}

/// An order-preserving attribute list. `class` and `id` are ordinary keys.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Attrs {
    pub entries: Vec<KeyVal>,
}

impl Attrs {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn find(&self, key: &[u8]) -> Option<&KeyVal> {
        self.entries.iter().find(|kv| kv.key == key)
    }

    pub fn get(&self, key: &[u8]) -> Option<&[u8]> {
        self.find(key)?.value.as_deref()
    }
}

static EMPTY_ATTRS: Attrs = Attrs { entries: Vec::new() };

impl Ast {
    pub fn node(&self, id: NodeId) -> &Node {
        &self.nodes[id as usize]
    }

    pub fn kind(&self, id: NodeId) -> &Kind {
        &self.nodes[id as usize].kind
    }

    /// The attributes attached to `id` (empty when it has none).
    pub fn attrs_of(&self, id: NodeId) -> &Attrs {
        match self.nodes[id as usize].attrs {
            Some(i) => &self.attrs[i as usize],
            None => &EMPTY_ATTRS,
        }
    }

    /// Abstract document equality: do these two trees MEAN the same thing?
    /// Compares the arenas directly (compaction canonicalizes them), attributes
    /// by value.
    pub fn eql(&self, other: &Ast) -> bool {
        if self.root != other.root || self.nodes.len() != other.nodes.len() {
            return false;
        }
        for (i, (a, b)) in self.nodes.iter().zip(other.nodes.iter()).enumerate() {
            if a.id != b.id || a.first_child != b.first_child || a.next_sibling != b.next_sibling {
                return false;
            }
            if a.kind != b.kind {
                return false;
            }
            if self.attrs_of(i as NodeId) != other.attrs_of(i as NodeId) {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn published_kind_names_are_pairwise_distinct() {
        let mut names: Vec<&str> = Vec::new();
        for t in Tag::ALL {
            if !matches!(t, Tag::InlineMark | Tag::TextLeaf | Tag::MarkupLeaf) {
                names.push(t.name());
            }
        }
        names.extend(InlineMark::ALL.iter().map(|m| m.name()));
        names.extend(TextLeafKind::ALL.iter().map(|m| m.name()));
        names.extend(MarkupLeafKind::ALL.iter().map(|m| m.name()));
        let mut sorted = names.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), names.len());
    }

    #[test]
    fn kindref_from_name_inverts_kind_name() {
        for t in Tag::ALL {
            match t {
                Tag::InlineMark | Tag::TextLeaf | Tag::MarkupLeaf => {
                    assert_eq!(KindRef::from_name(t.name()), None)
                }
                _ => assert_eq!(KindRef::from_name(t.name()), Some(KindRef::Tag(t))),
            }
        }
        for m in InlineMark::ALL {
            assert_eq!(KindRef::from_name(m.name()), Some(KindRef::Mark(m)));
        }
        assert_eq!(KindRef::from_name("paragraph"), None);
    }

    #[test]
    fn admits_child_closed_vocabulary() {
        let list = Kind::BulletList { tight: true };
        assert!(list.admits_child(&Kind::ListItem));
        assert!(!list.admits_child(&Kind::Para));
        assert!(!list.admits_child(&Kind::TaskListItem { checked: false }));
        assert!(list.admits_child(&Kind::Container(Container::named(b"note"))));
        let code = Kind::CodeBlock { lang: None, text: b"x".to_vec() };
        assert!(!code.admits_child(&Kind::Str(b"x".to_vec())));
        assert!(Kind::ListItem.admits_child(&Kind::Str(b"x".to_vec())));
    }
}
