//! The flat, published node-kind vocabulary (`Kind`), as the binding exposed it.

/// A node's kind, as the shared vocabulary publishes it.
///
/// A typed enum rather than the `String` this used to be, because the string
/// made a whole class of upstream change invisible here. When twig collapsed
/// its four generic container kinds (`div`, `span`, `directive`, `element`)
/// into one `container`, every site in this crate that compared a kind name
/// kept compiling and started being wrong at runtime. With this, each of those
/// sites is a compile error pointing at the exact line.
///
/// `#[non_exhaustive]`, and with an [`Other`](Kind::Other) arm, for the two
/// different ways the vocabulary can outrun a given build of this crate:
/// `#[non_exhaustive]` makes ADDING a variant here a non-breaking change for
/// callers, and `Other` carries a name the linked library published that this
/// crate has no variant for at all. Match with a `_` arm.
///
/// ## What is one variant here and two in the core
///
/// The nine inline marks share a single `inline_mark` kind in twig's own AST,
/// and the nine text leaves share a single `text_leaf`; both publish their
/// MEMBER name (`"superscript"`, not `"inline_mark"`). This enum follows the
/// published vocabulary, so they are variants here — the grouping is an
/// implementation detail of the core, not something a consumer should have to
/// know.
///
/// ## No `PartialEq<&str>`
///
/// Deliberately absent, though it would be one impl and would keep every
/// `node.kind == Kind::Image` in existing code compiling. That is precisely the
/// property this type exists to remove: a comparison against a string literal
/// is exactly what survived the container rename and went silently wrong.
/// Compare against a variant; reach for [`as_str`](Kind::as_str) only when you
/// genuinely want the name (logging it, or forwarding it to something that
/// speaks the wire vocabulary).
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
#[non_exhaustive]
pub enum Kind {
    // ── Document root ─────────────────────────────────────────────────────
    Doc,
    // ── Blocks ────────────────────────────────────────────────────────────
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
    // ── Structural children, and the document-level definitions ───────────
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
    // ── Inlines ───────────────────────────────────────────────────────────
    Str,
    SoftBreak,
    HardBreak,
    NonBreakingSpace,
    RawInline,
    SmartPunctuation,
    Link,
    Image,
    // ── Inline marks — one `inline_mark` kind in the core, published apart
    Emph,
    Strong,
    Mark,
    Superscript,
    Subscript,
    Insert,
    Delete,
    DoubleQuoted,
    SingleQuoted,
    // ── Text leaves — one `text_leaf` kind in the core, published apart ───
    Symb,
    Verbatim,
    InlineMath,
    DisplayMath,
    Url,
    Email,
    FootnoteReference,
    CitationReference,
    SubstitutionReference,
    // ── Generic markup ────────────────────────────────────────────────────
    Container,
    ProcessingInstruction,
    Comment,
    Doctype,
    Cdata,
    /// A kind name the linked library published that this crate has no variant
    /// for — a newer twig against an older binding.
    ///
    /// Deliberately not an error: a node whose kind this crate cannot name is
    /// still a node with a span, children and attributes, and a renderer that
    /// wants to pass it through unchanged should not be stopped from doing so.
    Other(String),
}

impl Kind {
    /// The name twig publishes for this kind — the exact string the C ABI's
    /// `TwigFlatNode.kind` carries.
    pub fn as_str(&self) -> &str {
        match self {
            Kind::Doc => "doc",
            Kind::Para => "para",
            Kind::Heading => "heading",
            Kind::ThematicBreak => "thematic_break",
            Kind::Section => "section",
            Kind::CodeBlock => "code_block",
            Kind::RawBlock => "raw_block",
            Kind::Metadata => "metadata",
            Kind::BlockQuote => "block_quote",
            Kind::BulletList => "bullet_list",
            Kind::OrderedList => "ordered_list",
            Kind::TaskList => "task_list",
            Kind::DefinitionList => "definition_list",
            Kind::LineBlock => "line_block",
            Kind::Table => "table",
            Kind::ListItem => "list_item",
            Kind::TaskListItem => "task_list_item",
            Kind::DefinitionListItem => "definition_list_item",
            Kind::Term => "term",
            Kind::Definition => "definition",
            Kind::Line => "line",
            Kind::Row => "row",
            Kind::Cell => "cell",
            Kind::Column => "column",
            Kind::Caption => "caption",
            Kind::Footnote => "footnote",
            Kind::Reference => "reference",
            Kind::Citation => "citation",
            Kind::Substitution => "substitution",
            Kind::Str => "str",
            Kind::SoftBreak => "soft_break",
            Kind::HardBreak => "hard_break",
            Kind::NonBreakingSpace => "non_breaking_space",
            Kind::RawInline => "raw_inline",
            Kind::SmartPunctuation => "smart_punctuation",
            Kind::Link => "link",
            Kind::Image => "image",
            Kind::Container => "container",
            Kind::ProcessingInstruction => "processing_instruction",
            Kind::Emph => "emph",
            Kind::Strong => "strong",
            Kind::Mark => "mark",
            Kind::Superscript => "superscript",
            Kind::Subscript => "subscript",
            Kind::Insert => "insert",
            Kind::Delete => "delete",
            Kind::DoubleQuoted => "double_quoted",
            Kind::SingleQuoted => "single_quoted",
            Kind::Symb => "symb",
            Kind::Verbatim => "verbatim",
            Kind::InlineMath => "inline_math",
            Kind::DisplayMath => "display_math",
            Kind::Url => "url",
            Kind::Email => "email",
            Kind::FootnoteReference => "footnote_reference",
            Kind::CitationReference => "citation_reference",
            Kind::SubstitutionReference => "substitution_reference",
            Kind::Comment => "comment",
            Kind::Doctype => "doctype",
            Kind::Cdata => "cdata",
            Kind::Other(name) => name.as_str(),
        }
    }

    /// Whether this is a kind the linked library named and this crate could
    /// not — the [`Other`](Kind::Other) case, and the one worth logging when a
    /// renderer meets a node it has no arm for.
    pub fn is_unknown(&self) -> bool {
        matches!(self, Kind::Other(_))
    }
}

impl From<&str> for Kind {
    fn from(name: &str) -> Self {
        match name {
            "doc" => Kind::Doc,
            "para" => Kind::Para,
            "heading" => Kind::Heading,
            "thematic_break" => Kind::ThematicBreak,
            "section" => Kind::Section,
            "code_block" => Kind::CodeBlock,
            "raw_block" => Kind::RawBlock,
            "metadata" => Kind::Metadata,
            "block_quote" => Kind::BlockQuote,
            "bullet_list" => Kind::BulletList,
            "ordered_list" => Kind::OrderedList,
            "task_list" => Kind::TaskList,
            "definition_list" => Kind::DefinitionList,
            "line_block" => Kind::LineBlock,
            "table" => Kind::Table,
            "list_item" => Kind::ListItem,
            "task_list_item" => Kind::TaskListItem,
            "definition_list_item" => Kind::DefinitionListItem,
            "term" => Kind::Term,
            "definition" => Kind::Definition,
            "line" => Kind::Line,
            "row" => Kind::Row,
            "cell" => Kind::Cell,
            "column" => Kind::Column,
            "caption" => Kind::Caption,
            "footnote" => Kind::Footnote,
            "reference" => Kind::Reference,
            "citation" => Kind::Citation,
            "substitution" => Kind::Substitution,
            "str" => Kind::Str,
            "soft_break" => Kind::SoftBreak,
            "hard_break" => Kind::HardBreak,
            "non_breaking_space" => Kind::NonBreakingSpace,
            "raw_inline" => Kind::RawInline,
            "smart_punctuation" => Kind::SmartPunctuation,
            "link" => Kind::Link,
            "image" => Kind::Image,
            "container" => Kind::Container,
            "processing_instruction" => Kind::ProcessingInstruction,
            "emph" => Kind::Emph,
            "strong" => Kind::Strong,
            "mark" => Kind::Mark,
            "superscript" => Kind::Superscript,
            "subscript" => Kind::Subscript,
            "insert" => Kind::Insert,
            "delete" => Kind::Delete,
            "double_quoted" => Kind::DoubleQuoted,
            "single_quoted" => Kind::SingleQuoted,
            "symb" => Kind::Symb,
            "verbatim" => Kind::Verbatim,
            "inline_math" => Kind::InlineMath,
            "display_math" => Kind::DisplayMath,
            "url" => Kind::Url,
            "email" => Kind::Email,
            "footnote_reference" => Kind::FootnoteReference,
            "citation_reference" => Kind::CitationReference,
            "substitution_reference" => Kind::SubstitutionReference,
            "comment" => Kind::Comment,
            "doctype" => Kind::Doctype,
            "cdata" => Kind::Cdata,
            other => Kind::Other(other.to_string()),
        }
    }
}

impl std::fmt::Display for Kind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}
