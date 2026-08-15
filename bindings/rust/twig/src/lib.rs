mod error;

// The raw FFI layer moved to the `twig-sys` crate. Alias it as `ffi` so every
// `ffi::…` / `crate::ffi::…` reference in this crate keeps resolving unchanged,
// and so `twig-sys`'s build script (via its `links = "twig"`) links `libtwig.a`
// into this crate.
pub(crate) use twig_sys as ffi;

use std::marker::PhantomData;
use std::ops::Range;
use std::os::raw::{c_char, c_int};
use std::ptr::NonNull;

pub use error::Error;
pub use ffi::TwigSpan as Span;

/// Every format Twig can **parse** — the input axis, as opposed to [`Target`],
/// which is where output bytes can go.
///
/// `#[non_exhaustive]` for the same reason [`Target`] is: Twig's parser list
/// grows (reStructuredText is written and awaiting a registry entry), and a
/// caller matching on this enum should not have to be recompiled to keep
/// compiling. Match with a `_` arm.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Format {
    Djot,
    Markdown,
    Xml,
    Html,
    /// Parsed and rendered, but **not** serialized: `Target::Asciidoc` reports
    /// [`Error::UnsupportedFormat`], and no [`Editor`] gesture applies to an
    /// AsciiDoc document.
    ///
    /// The parser also covers a *slice* of AsciiDoc rather than all of it —
    /// the header, paragraphs, sections, lists, delimited blocks and the inline
    /// spans. What it does not implement survives as literal source text rather
    /// than failing the parse, so a successful parse is not by itself a claim
    /// that the whole document was understood.
    Asciidoc,
}

impl From<Format> for ffi::TwigFormat {
    fn from(value: Format) -> Self {
        match value {
            Format::Djot => ffi::TwigFormat::Djot,
            Format::Markdown => ffi::TwigFormat::Markdown,
            Format::Xml => ffi::TwigFormat::Xml,
            Format::Html => ffi::TwigFormat::Html,
            Format::Asciidoc => ffi::TwigFormat::Asciidoc,
        }
    }
}

/// Every format Twig can **write** — the output axis, as opposed to [`Format`],
/// which is what Twig can **parse**.
///
/// Every [`Format`] is also a `Target` (use `Target::from(format)`), so the two
/// lists coincide today and the distinction costs nothing to ignore. It exists
/// because only one of them can grow freely: a [`Format`] must have a parser
/// behind it, while a target only needs somewhere for bytes to go. That makes an
/// *export-only* target — one Twig can write and no parser reads back, PDF being
/// the motivating case — expressible here and nowhere else. See the two format
/// axes in the Zig library's `DESIGN.md`.
///
/// `#[non_exhaustive]` for exactly that reason: a future export-only variant is
/// then an additive change rather than a breaking one for callers that match on
/// this enum.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Target {
    Djot,
    Markdown,
    Xml,
    Html,
    /// Nameable, and always [`Error::UnsupportedFormat`] at the moment of
    /// serializing — AsciiDoc has a parser and no serializer. Present for the
    /// reason [`From<Format> for Target`](#impl-From<Format>-for-Target) is
    /// total: an input format Twig cannot write back is a *runtime* answer, not
    /// an unnameable target.
    Asciidoc,
}

impl Target {
    /// The [`Format`] whose parser reads this target's own output back, or
    /// `None` for an export-only target.
    ///
    /// Always `Some` today. It is the question to ask before assuming a target
    /// can be round-tripped: `None` means bytes go out and nothing comes back,
    /// so there is no "parse it again and compare" available for that target.
    pub fn as_format(self) -> Option<Format> {
        match self {
            Target::Djot => Some(Format::Djot),
            Target::Markdown => Some(Format::Markdown),
            Target::Xml => Some(Format::Xml),
            Target::Html => Some(Format::Html),
            Target::Asciidoc => Some(Format::Asciidoc),
        }
    }
}

/// Total: every input format is also an output target, even the ones with no
/// serializer yet (converting *into* XML reports [`Error::UnsupportedFormat`]
/// rather than being unnameable).
impl From<Format> for Target {
    fn from(value: Format) -> Self {
        match value {
            Format::Djot => Target::Djot,
            Format::Markdown => Target::Markdown,
            Format::Xml => Target::Xml,
            Format::Html => Target::Html,
            Format::Asciidoc => Target::Asciidoc,
        }
    }
}

impl From<Target> for ffi::TwigFormat {
    fn from(value: Target) -> Self {
        match value {
            Target::Djot => ffi::TwigFormat::Djot,
            Target::Markdown => ffi::TwigFormat::Markdown,
            Target::Xml => ffi::TwigFormat::Xml,
            Target::Html => ffi::TwigFormat::Html,
            Target::Asciidoc => ffi::TwigFormat::Asciidoc,
        }
    }
}

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

/// One node returned by [`Document::query`]: its AST id, byte spans, and kind.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryMatch {
    /// The node's id in the shared AST.
    pub node_id: u32,
    /// The node's whole byte range in the source.
    pub span: Range<usize>,
    /// The node's interior byte range (between its delimiters), or `None` for
    /// a leaf / a container with no known interior.
    pub content_span: Option<Range<usize>>,
    /// The node's kind. See [`Kind`] for why this is an enum and not the
    /// name string the C ABI carries.
    pub kind: Kind,
}

/// The byte-level effect of an [`Editor`] edit: `old` is the range of the
/// pre-edit source that was replaced, `new` the range the replacement now
/// occupies in the post-edit source (they share a start). An insertion has an
/// empty `old`; a deletion an empty `new`. Everything a caret/selection needs
/// to re-anchor across an edit without re-diffing: shift any offset `>= old.end`
/// by `new.len() - old.len()`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Change {
    pub old: Range<usize>,
    pub new: Range<usize>,
}

impl Change {
    /// The net change in source length (`new.len() - old.len()`).
    pub fn delta(&self) -> isize {
        self.new.len() as isize - self.old.len() as isize
    }

    fn from_ffi(c: ffi::TwigChange) -> Self {
        Change {
            old: c.old_span.start..c.old_span.end,
            new: c.new_span.start..c.new_span.end,
        }
    }
}

/// One node of an [`Editor::nodes`] snapshot — the flat AST arena as owned Rust
/// data (the JSON-free read path). `id` indexes the snapshot; `parent`,
/// `first_child`, and `next_sibling` link the tree (`None` where absent).
/// `text` is the node's primary payload (a `str`'s bytes, a `code_block`'s
/// body, …) and `destination` a link/image target, each `None` when the kind
/// carries no such payload.
/// `#[non_exhaustive]`: a snapshot node is something twig *hands you*, never
/// something you build, so it gains a field whenever a node kind's payload is
/// surfaced (as `head`/`alignment` were for tables). Sealing construction here
/// keeps every future addition a minor release instead of a major one.
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub struct FlatNode {
    pub id: NodeId,
    pub parent: Option<NodeId>,
    pub first_child: Option<NodeId>,
    pub next_sibling: Option<NodeId>,
    pub span: Range<usize>,
    pub content_span: Option<Range<usize>>,
    /// A heading's level; `None` for every other kind.
    pub level: Option<u32>,
    pub kind: Kind,
    pub text: Option<String>,
    pub destination: Option<String>,
    /// Whether a `row`/`cell` belongs to the table head; `None` for every other
    /// kind.
    pub head: Option<bool>,
    /// A `cell`'s column alignment; `None` for every other kind. The delimiter
    /// row (`|:--|--:|`) that spells the alignment out is consumed by the parser
    /// and has no node of its own, so this is the only way to recover it.
    /// [`Alignment::Default`] is a real, unspecified alignment (a bare `---`) —
    /// distinct from the `None` a non-cell node reports.
    pub alignment: Option<Alignment>,
    /// The name a generic container carries in its own payload rather than in
    /// `kind`: an HTML/XML tag (`"picture"`, `"source"`, …) or a directive type
    /// (`"note"`, `"embed"`, `"vis"`, …, no leading colons). `None` for every
    /// semantic kind, whose identity is `kind` alone. With this an
    /// `html_elements` parse's `<picture>`/`<source>` are distinguishable — both
    /// report `kind == "container"` — and so are a `::embed` and a `::toc`.
    ///
    /// A tag and a directive type share one `kind` because they are one concept
    /// in the core: a named container with attributes and children. `name` is
    /// what tells them apart, which is why it is not optional in practice for
    /// anything a renderer cares about.
    pub name: Option<String>,
    /// Which of the three generic-container SPELLINGS this node's producer
    /// draws; `None` when it draws none. Pairs with [`name`](Self::name): the
    /// name says *which* container, this says *how it is written*, and a
    /// renderer needs both — the same type is a span inline
    /// ([`DirectiveForm::Text`]), a standalone block with no body
    /// ([`DirectiveForm::Leaf`]), and a wrapper around blocks
    /// ([`DirectiveForm::Container`]).
    ///
    /// **This does not answer "is it a directive?"** — use
    /// [`origin`](Self::origin). HTML's parser sets a form on `<div>` and
    /// `<span>`, the two tags djot and Markdown have generic spellings for, so
    /// this reports `Some(Container)` for a `<div>` and `None` for a
    /// `<video>`: right often enough to look usable, wrong on the two tags you
    /// meet first.
    pub directive_form: Option<DirectiveForm>,
    /// Whether a generic container was WRITTEN as a tag or as a directive;
    /// `None` when nothing recorded it — the node is not a container, or no
    /// parser produced it (a [`Builder`] tree).
    ///
    /// This is the field that separates an HTML `<div>` from a Markdown
    /// `:::div`. Those two agree on [`kind`](Self::kind) (`"container"`), on
    /// [`name`](Self::name) (`"div"`) and on
    /// [`directive_form`](Self::directive_form) (`Container`), field for field,
    /// so none of the three can tell you which one you have.
    pub origin: Option<ContainerOrigin>,
    /// The node's own MARKER — the leading bytes a rich view HIDES, on its
    /// opening line: a heading's `#`s and the space after them, a list item's
    /// `- ` / `1. `, a task item's marker plus its `[x] ` box, a block quote's
    /// `> `. `None` for a node with no leading marker (every inline, a
    /// paragraph, a SETEXT heading whose `---` sits *under* the block).
    ///
    /// **Not derivable from [`span`](Self::span) and
    /// [`content_span`](Self::content_span).** For a heading it happens to be
    /// `span.start..content_span.start`; for a marker-prefixed container it is
    /// not, because those report `content_span == span` — a prefix repeating on
    /// every line has no contiguous interior to point at. Before this field the
    /// answer was recoverable only by a per-format rule (from the item's inner
    /// paragraph in Markdown, from the item itself in Djot), which is the
    /// "which parser produced this?" reasoning a shared AST exists to remove.
    ///
    /// Covers ONE LINE, and this node's own marker alone. For the whole prefix a
    /// nested construct sits behind (`>   1. [ ] ` is four nodes' markers plus
    /// the indent between them), call [`Document::line_prefix`].
    pub marker_span: Option<Range<usize>>,
    /// The node's `{...}` / HTML attributes as `(key, value)` pairs in source
    /// order (empty when it has none). A bare attribute (HTML `disabled`, or a
    /// `<source media=…>` used as a flag) has a `None` value.
    pub attrs: Vec<(String, Option<String>)>,
}

/// An inline mark for [`Editor::wrap_range`] / [`Editor::toggle_inline`] — a
/// rich editor's Bold / Italic / Code / … buttons. Markdown spells only
/// [`InlineKind::Strong`], [`InlineKind::Emph`], and [`InlineKind::Verbatim`];
/// Djot spells all of them. An unsupported kind yields [`Error::UnsupportedFormat`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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
    fn to_c(self) -> c_int {
        match self {
            InlineKind::Strong => 0,
            InlineKind::Emph => 1,
            InlineKind::Verbatim => 2,
            InlineKind::Mark => 3,
            InlineKind::Superscript => 4,
            InlineKind::Subscript => 5,
            InlineKind::Insert => 6,
            InlineKind::Delete => 7,
        }
    }
}

/// A block target for [`Editor::set_block`] — the toolbar's H1…H6 / Body switch.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockKind {
    Paragraph,
    /// A heading of the given level (1–6; out of range is [`Error::InvalidArgument`]).
    Heading(u32),
}

impl BlockKind {
    /// `(block_kind_code, level)` for the C ABI.
    fn to_c(self) -> (c_int, u32) {
        match self {
            BlockKind::Paragraph => (0, 0),
            BlockKind::Heading(level) => (1, level),
        }
    }
}

/// A block container for [`Editor::toggle_block_container`] — the toolbar's
/// Quote / Bulleted list / Numbered list buttons. Where a [`BlockKind`] rewrites
/// one block's leading marker, a container prefixes every line of a range and
/// nests. Djot and Markdown spell all three; other formats yield
/// [`Error::UnsupportedFormat`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockContainerKind {
    BlockQuote,
    BulletList,
    OrderedList,
}

impl BlockContainerKind {
    fn to_c(self) -> c_int {
        match self {
            BlockContainerKind::BlockQuote => 0,
            BlockContainerKind::BulletList => 1,
            BlockContainerKind::OrderedList => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
}

pub fn version() -> Version {
    let packed = unsafe { ffi::twig_version() };
    Version {
        major: (packed >> 16) as u8,
        minor: (packed >> 8) as u8,
        patch: packed as u8,
    }
}

/// The C ABI contract version this crate was **compiled** against — the
/// compile-time counterpart to [`abi_version`] (which reports the **linked
/// library's**). This crate builds and links its own vendored copy of the Zig
/// source, so the two always agree; the pair is exposed so a consumer embedding
/// a separately-built library can verify layout compatibility at load time.
pub const ABI_VERSION: u32 = ffi::TWIG_ABI_VERSION;

/// The C ABI contract version of the linked library. This crate is written
/// against [`ABI_VERSION`]; the two agreeing is what makes the `#[repr(C)]`
/// mirrors in `ffi` sound. It is bumped only on a breaking ABI change (a struct
/// layout change or a renumbered enum value), never on an additive one (a new
/// format code or a new function).
pub fn abi_version() -> u32 {
    unsafe { ffi::twig_abi_version() }
}

pub fn version_string() -> &'static str {
    let ptr = unsafe { ffi::twig_version_string() };
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
}

#[derive(Debug)]
pub struct Document {
    raw: NonNull<ffi::TwigDocument>,
}

impl Document {
    pub fn parse(input: &[u8], format: Format) -> Result<Self, Error> {
        Self::parse_with(input, format, MarkdownExtensions::default())
    }

    pub fn parse_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::parse(input.as_bytes(), format)
    }

    /// Like [`Document::parse`], plus Markdown `extensions` to enable (ignored
    /// for other formats) — the read-path counterpart of [`Editor::new_ext`].
    /// Enable [`MarkdownExtensions::html_elements`] here to make embedded HTML
    /// (`<img>`, `<picture>`, …) queryable via [`Document::query`] instead of
    /// arriving as opaque raw HTML.
    pub fn parse_with(
        input: &[u8],
        format: Format,
        extensions: MarkdownExtensions,
    ) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status = unsafe {
            ffi::twig_parse_ext(
                input.as_ptr(),
                input.len(),
                ffi_format as i32,
                extensions.to_flags(),
                &mut raw,
            )
        };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    /// [`Document::parse_with`] for a `&str`.
    pub fn parse_str_with(
        input: &str,
        format: Format,
        extensions: MarkdownExtensions,
    ) -> Result<Self, Error> {
        Self::parse_with(input.as_bytes(), format, extensions)
    }

    /// Render the document to HTML. For Djot/Markdown this is the rich
    /// rendering path that resolves reference/footnote side tables.
    pub fn render_html(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_document_render_html(raw, ptr, len) })
    }

    /// Serialize the document to `target`'s own syntax: a round-trip when
    /// `target` names the document's own format, cross-format conversion
    /// otherwise (e.g. parse Markdown, serialize as Djot). Returns
    /// [`Error::UnsupportedFormat`] when the requested direction has no
    /// serializer (today: converting into XML from another format).
    ///
    /// Prefer this over [`Document::serialize`]: serializing is a question about
    /// where the bytes are going, so it takes a [`Target`]. The older spelling
    /// takes a [`Format`] and still works — every `Format` is a `Target` — but
    /// it cannot name an export-only target, and this one can.
    pub fn serialize_to(&mut self, target: Target) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        let ffi_target: ffi::TwigFormat = target.into();
        collect_bytes(|ptr, len| unsafe {
            ffi::twig_document_serialize(raw, ffi_target as i32, ptr, len)
        })
    }

    /// Serialize the document to `format`'s own source syntax.
    ///
    /// The original spelling of [`Document::serialize_to`], kept for
    /// compatibility and defined in terms of it. It types the output axis as
    /// [`Format`], which is the input vocabulary; reach for `serialize_to` in
    /// new code.
    pub fn serialize(&mut self, format: Format) -> Result<Vec<u8>, Error> {
        self.serialize_to(format.into())
    }

    /// Encode the document's AST as pretty-printed JSON (the same encoding as
    /// `twig convert -o ast`).
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_document_ast_json(raw, ptr, len) })
    }

    /// Resolve a CSS-lite selector (e.g. `heading[level=2]`,
    /// `link[dest^="http"]`, `code`, `list > item`) against the document,
    /// returning one [`QueryMatch`] per matching node in document order. A
    /// malformed selector yields [`Error::InvalidArgument`].
    ///
    /// This is the general replacement for scanning code spans by hand: a
    /// `verbatim` / `code_block` / `raw_inline` / `raw_block` selector recovers
    /// those, and every other node kind is reachable too.
    pub fn query(&mut self, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        collect_matches(|ptr, len| unsafe {
            ffi::twig_document_query(raw, selector.as_ptr(), selector.len(), ptr, len)
        })
    }

    /// Return the whole source span of `node` without running a selector query.
    pub fn span(&mut self, node: NodeId) -> Result<Range<usize>, Error> {
        let mut span = ffi::TwigSpan { start: 0, end: 0 };
        let status = unsafe { ffi::twig_document_node_span(self.raw.as_ptr(), node.0, &mut span) };
        Error::from_status(status)?;
        Ok(span.start..span.end)
    }

    /// Return the interior span of `node`, or `None` when the node has no
    /// recorded content span.
    pub fn content_span(&mut self, node: NodeId) -> Result<Option<Range<usize>>, Error> {
        let mut span = ffi::TwigSpan { start: 0, end: 0 };
        let status =
            unsafe { ffi::twig_document_node_content_span(self.raw.as_ptr(), node.0, &mut span) };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(span.start..span.end)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// The span of `node`'s own leading MARKER — the leading bytes a rich view
    /// HIDES on its opening line — or `None` when it has none. See
    /// [`FlatNode::marker_span`], which is the same answer inside a snapshot.
    pub fn marker_span(&mut self, node: NodeId) -> Result<Option<Range<usize>>, Error> {
        let mut span = ffi::TwigSpan { start: 0, end: 0 };
        let status =
            unsafe { ffi::twig_document_node_marker_span(self.raw.as_ptr(), node.0, &mut span) };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(span.start..span.end)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// Everything HIDDEN before the content on the line byte `offset` sits on:
    /// every marker a node OPENS that line with, and the indentation between
    /// them, as one range running from the line start.
    ///
    /// This is the assembled form of [`FlatNode::marker_span`], which records
    /// each node's own marker alone. `>   1. [ ] ` is four nodes' markers plus
    /// the spaces between them, and the union is contiguous from the line start
    /// — so a caller gets one range to hide, or one width for a caret to step
    /// over, rather than a chain to walk and stitch together itself.
    ///
    /// `None` when nothing opens on this line — a CONTINUATION line, the second
    /// line of a wrapped paragraph or of a block quote. That is a real answer
    /// rather than a gap: what a continuation line repeats is a different
    /// question (a quote re-emits `> `, a list item re-emits spaces) and is not
    /// answerable from marker spans. [`Error::InvalidArgument`] if `offset`
    /// exceeds the source length.
    pub fn line_prefix(&mut self, offset: usize) -> Result<Option<Range<usize>>, Error> {
        let mut span = ffi::TwigSpan { start: 0, end: 0 };
        let status =
            unsafe { ffi::twig_document_line_prefix(self.raw.as_ptr(), offset, &mut span) };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(span.start..span.end)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// The grid extent of the cell at `node` — how many `(columns, rows)` it
    /// occupies — or `None` when the node is not a cell. Both are at least 1,
    /// and `(1, 1)` is the ordinary one-square cell; anything larger is a merged
    /// cell from a format with a real grid (HTML's `colspan`/`rowspan`, an rST
    /// grid table). GFM and djot pipe tables always report `(1, 1)`.
    ///
    /// HTML's `rowspan="0"` ("to the end of the row group") is not a count and
    /// reports 1; the source spelling survives on the node's attributes.
    ///
    /// This is an accessor rather than a [`FlatNode`] field because the C struct
    /// it snapshots is ABI-frozen — see [`Document::span`] for the same shape.
    pub fn cell_extent(&mut self, node: NodeId) -> Result<Option<(u32, u32)>, Error> {
        let raw = self.raw.as_ptr();
        let mut colspan: u32 = 0;
        let status = unsafe { ffi::twig_document_cell_colspan(raw, node.0, &mut colspan) };
        match status.0 {
            ffi::TwigStatus::OK => {}
            ffi::TwigStatus::NOT_FOUND => return Ok(None),
            _ => return Err(Error::from_status(status).unwrap_err()),
        }
        let mut rowspan: u32 = 0;
        Error::from_status(unsafe { ffi::twig_document_cell_rowspan(raw, node.0, &mut rowspan) })?;
        Ok(Some((colspan, rowspan)))
    }

    /// Snapshot the whole tree as a flat [`FlatNode`] array (the JSON-free read
    /// path for a renderer), indexed so `nodes[i].id == NodeId(i)`. Walk it via
    /// the `parent`/`first_child`/`next_sibling` links; the root is the node
    /// whose `parent` is `None`.
    pub fn nodes(&mut self) -> Result<Vec<FlatNode>, Error> {
        let raw = self.raw.as_ptr();
        collect_flat_nodes(|ptr, len| unsafe { ffi::twig_document_nodes(raw, ptr, len) })
    }

    /// The document-level **definitions**: every node that hangs off no parent
    /// and is not the document root, in arena order. Usually empty.
    ///
    /// A parsed document is not one tree. Footnote definitions and
    /// link-reference definitions are resolved by LABEL rather than by
    /// position, so twig attaches them to nothing — walking from the root over
    /// [`FlatNode::first_child`] never reaches them, and a renderer that wants
    /// to resolve `[^1]` has to find the definition some other way. This is
    /// that way, and it replaces scanning the whole [`Document::nodes`] array
    /// for entries whose `parent` is `None`.
    ///
    /// Not filtered to a kind list: WHICH kinds end up detached is a property
    /// of how a format resolves its definitions (djot and Markdown detach
    /// [`Kind::Footnote`] and [`Kind::Reference`]; rST adds [`Kind::Citation`]
    /// and [`Kind::Substitution`]), not something a caller should enumerate.
    /// Read the [`kind`](QueryMatch::kind) on each match.
    pub fn definitions(&mut self) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        collect_matches(|ptr, len| unsafe { ffi::twig_document_definitions(raw, ptr, len) })
    }

    /// What converting this document to `target` would silently **lose**: one
    /// [`Warning`] per lossy node, in document order. An empty vec means the
    /// conversion is lossless.
    ///
    /// Twig's serializers degrade or drop a node whenever the target has no
    /// spelling for it — a djot `{=mark=}` written into Markdown comes back as
    /// plain text, an HTML comment converted to djot vanishes entirely. None of
    /// it is an error, so all of it happens quietly. This is the call that makes
    /// it loud, and it replaces guessing from the outside: the answers are
    /// measured against the serializers by a round-trip probe in the Zig
    /// library, not asserted.
    ///
    /// The answer belongs to the (document, target) PAIR, not to the document —
    /// the same document has different answers for different targets, which is
    /// why this takes one and why nothing is cached on [`Document`] itself.
    ///
    /// [`Error::UnsupportedFormat`] for a target with no serializer at all
    /// ([`Target::Xml`], [`Target::Asciidoc`]): "this cannot be written" is a
    /// capability answer, not a per-node diagnosis.
    pub fn diagnostics(&mut self, target: Target) -> Result<Vec<Warning>, Error> {
        let raw = self.raw.as_ptr();
        let code = ffi::TwigFormat::from(target) as c_int;
        let mut ptr: *const ffi::TwigWarning = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe { ffi::twig_document_diagnostics(raw, code, &mut ptr, &mut len) };
        Error::from_status(status)?;
        if len == 0 || ptr.is_null() {
            return Ok(Vec::new());
        }
        let raw_warnings = unsafe { std::slice::from_raw_parts(ptr, len) };
        Ok(raw_warnings
            .iter()
            .map(|w| Warning {
                fidelity: Fidelity::from_c(w.fidelity),
                path: borrowed_bytes(w.path_ptr, w.path_len).unwrap_or_default(),
                kind: Kind::from(borrowed_cstr(w.kind).unwrap_or_default().as_str()),
            })
            .collect())
    }

    /// The direct children of `node` as [`QueryMatch`]es (id, span, kind) —
    /// `None` enumerates the document root's children (the top-level blocks).
    /// The cheap enumeration an incremental renderer walks to decide which
    /// blocks to re-marshal with [`Document::subtree`]. A childless node yields
    /// an empty vec.
    pub fn children(&mut self, node: Option<NodeId>) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        let id = node.map_or(ffi::TWIG_NO_NODE, |n| n.0);
        collect_matches(|ptr, len| unsafe { ffi::twig_document_children(raw, id, ptr, len) })
    }

    /// Snapshot the subtree rooted at `node` as a self-contained [`FlatNode`]
    /// array with *local* ids: `array[0]` is the root, every link is an index
    /// into the returned vec (or `None`), and spans stay absolute. The root's
    /// `parent` and `next_sibling` are `None`, so a walk from index 0 stays
    /// inside the subtree. [`Error::InvalidArgument`] if `node` is out of range.
    pub fn subtree(&mut self, node: NodeId) -> Result<Vec<FlatNode>, Error> {
        let raw = self.raw.as_ptr();
        collect_flat_nodes(|ptr, len| unsafe { ffi::twig_document_subtree(raw, node.0, ptr, len) })
    }

    /// The deepest node whose span contains byte `offset` (with `offset` equal
    /// to the source length treated as inside the root) — hit-testing and
    /// cursor context. `Ok(None)` if no node covers the offset;
    /// [`Error::InvalidArgument`] if `offset` exceeds the source length.
    pub fn node_at(&mut self, offset: usize) -> Result<Option<QueryMatch>, Error> {
        let mut m = empty_ffi_match();
        let status = unsafe { ffi::twig_document_node_at(self.raw.as_ptr(), offset, &mut m) };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(query_match_from_ffi(&m)?)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// The chain of nodes containing byte `offset`, root-first down to the
    /// deepest (the node [`Document::node_at`] returns) — the ancestor path for
    /// a breadcrumb. Empty if no node covers the offset.
    pub fn ancestors_at(&mut self, offset: usize) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        let mut ptr: *const ffi::TwigQueryMatch = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe { ffi::twig_document_nodes_at(raw, offset, &mut ptr, &mut len) };
        match status.0 {
            ffi::TwigStatus::OK => {}
            ffi::TwigStatus::NOT_FOUND => return Ok(Vec::new()),
            _ => return Err(Error::from_status(status).unwrap_err()),
        }
        if len == 0 || ptr.is_null() {
            return Ok(Vec::new());
        }
        let raw_matches = unsafe { std::slice::from_raw_parts(ptr, len) };
        raw_matches.iter().map(query_match_from_ffi).collect()
    }

    /// [`Document::node_at`] under CARET containment — the same descent, under
    /// the rule an editing caret needs rather than the one a byte range needs.
    ///
    /// Two differences, both because a caret is a position BETWEEN bytes while a
    /// span is a range OF bytes:
    ///
    /// 1. **A block's end is inside it.** A caret after the last character of a
    ///    paragraph is *in* that paragraph — it is where you stand to type the
    ///    rest of it. Half-open containment puts it outside, which is why a
    ///    consumer probing [`Document::ancestors_at`] ends up guessing at
    ///    contrived offsets (the content start, `caret - 1`, a marker byte) to
    ///    find the block it was plainly inside of.
    ///
    /// 2. **A trailing newline is not part of the block**, which is what makes
    ///    the two authorable formats AGREE. Djot ends a paragraph's span after
    ///    its newline and Markdown before it, so on `"a\n\nb\n"` the caret at
    ///    offset 1 read as `para` through Djot and `doc` through Markdown — the
    ///    same caret, two answers, decided by which parser produced the tree.
    ///
    /// Never `Ok(None)` for a non-empty document: a caret in the gap between two
    /// blocks reports the container holding the gap (usually the root) rather
    /// than nothing at all.
    pub fn node_at_caret(&mut self, offset: usize) -> Result<Option<QueryMatch>, Error> {
        let mut m = empty_ffi_match();
        let status = unsafe { ffi::twig_document_node_at_caret(self.raw.as_ptr(), offset, &mut m) };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(query_match_from_ffi(&m)?)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// [`Document::ancestors_at`] under caret containment — root-first down to
    /// the node [`Document::node_at_caret`] returns. See that method for the
    /// containment rule and why it differs.
    pub fn ancestors_at_caret(&mut self, offset: usize) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        let mut ptr: *const ffi::TwigQueryMatch = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe { ffi::twig_document_nodes_at_caret(raw, offset, &mut ptr, &mut len) };
        match status.0 {
            ffi::TwigStatus::OK => {}
            ffi::TwigStatus::NOT_FOUND => return Ok(Vec::new()),
            _ => return Err(Error::from_status(status).unwrap_err()),
        }
        if len == 0 || ptr.is_null() {
            return Ok(Vec::new());
        }
        let raw_matches = unsafe { std::slice::from_raw_parts(ptr, len) };
        raw_matches.iter().map(query_match_from_ffi).collect()
    }
}

/// A [`Document`] borrowed from an [`Editor`] (see [`Editor::document`]): the
/// editor's live tree behind the whole document read surface, without a parse.
///
/// It holds the editor mutably borrowed for as long as it lives, so the tree —
/// and every node id and span read out of it — cannot change underneath it.
/// Dropping it frees nothing; the editor owns the tree.
///
/// [`Document::render_html`] and [`Document::serialize`] are the two methods it
/// cannot serve ([`Error::UnsupportedFormat`] — they need a real parse's
/// language tag and side tables). Parse [`Editor::source`] for those.
#[derive(Debug)]
pub struct DocumentView<'a> {
    doc: Document,
    _editor: PhantomData<&'a mut Editor>,
}

impl std::ops::Deref for DocumentView<'_> {
    type Target = Document;

    fn deref(&self) -> &Document {
        &self.doc
    }
}

impl std::ops::DerefMut for DocumentView<'_> {
    fn deref_mut(&mut self) -> &mut Document {
        &mut self.doc
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe { ffi::twig_document_destroy(self.raw.as_ptr()) }
    }
}

/// Opt-in Markdown extensions to enable for a parse — for either the read path
/// ([`Document::parse_with`]) or the edit path ([`Editor::new_ext`]). Ignored
/// for non-Markdown formats. Every field defaults off, matching the library; the
/// default-on extensions (tables, strikethrough, task lists, …) are always on
/// and need no flag here.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MarkdownExtensions {
    /// Generic directives: `:name`, `::name`, `:::name`.
    pub directives: bool,
    /// `$...$` / `$$...$$` math.
    pub math: bool,
    /// Parse recognized raw HTML into semantic AST nodes — an `<img>` becomes an
    /// [`image` node](FlatNode) instead of an opaque `raw_block`/`raw_inline`, so
    /// it is addressable by [`Document::query`] and the tree read paths. Only
    /// tags that map verbatim onto the source are promoted; the rest stay raw.
    pub html_elements: bool,
}

impl MarkdownExtensions {
    fn to_flags(self) -> u32 {
        let mut flags = 0;
        if self.directives {
            flags |= ffi::TWIG_MD_DIRECTIVES;
        }
        if self.math {
            flags |= ffi::TWIG_MD_MATH;
        }
        if self.html_elements {
            flags |= ffi::TWIG_MD_HTML_ELEMENTS;
        }
        flags
    }
}

/// A span-splice editor over a document: applies lossless, in-place edits and
/// reparses after each one, so node addressing stays valid as the document
/// evolves. Every op is addressed by a `locator` — a dot-separated index path
/// (`"0.3.1"`) or a selector that must match exactly one node
/// (`heading("Status")`). A failed edit leaves the document unchanged.
#[derive(Debug)]
pub struct Editor {
    raw: NonNull<ffi::TwigEditor>,
}

impl Editor {
    /// Create an editor over a private copy of `input`, parsed as `format` with
    /// default options.
    pub fn new(input: &[u8], format: Format) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status = unsafe {
            ffi::twig_editor_create(input.as_ptr(), input.len(), ffi_format as i32, &mut raw)
        };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    pub fn new_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::new(input.as_bytes(), format)
    }

    /// Like [`Editor::new`], plus Markdown `extensions` to enable (ignored for
    /// other formats). The editor reparses with these after every edit, so a
    /// directive-bearing document stays parseable — needed before
    /// [`Editor::filter`] can match `directive[...]` selectors.
    pub fn new_ext(
        input: &[u8],
        format: Format,
        extensions: MarkdownExtensions,
    ) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status = unsafe {
            ffi::twig_editor_create_ext(
                input.as_ptr(),
                input.len(),
                ffi_format as i32,
                extensions.to_flags(),
                &mut raw,
            )
        };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    /// Replace the whole source of the located node with `text`.
    pub fn replace(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_replace(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Replace the interior (between-delimiters content) of the located
    /// container.
    pub fn replace_content(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_replace_content(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Insert `text` immediately before the located node.
    pub fn insert_before(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_insert_before(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Insert `text` immediately after the located node.
    pub fn insert_after(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply(locator, text, |ed, loc, loc_len, txt, txt_len| unsafe {
            ffi::twig_editor_insert_after(ed, loc, loc_len, txt, txt_len)
        })
    }

    /// Insert `text` as the `index`-th child of the located container (an index
    /// at or past the child count appends).
    pub fn insert_child(&mut self, locator: &str, index: usize, text: &str) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_insert_child(
                self.raw.as_ptr(),
                locator.as_ptr(),
                locator.len(),
                index,
                text.as_ptr(),
                text.len(),
            )
        };
        Error::from_status(status)
    }

    /// Delete the located node (removes exactly its span; no whitespace
    /// cleanup).
    pub fn delete(&mut self, locator: &str) -> Result<(), Error> {
        let status =
            unsafe { ffi::twig_editor_delete(self.raw.as_ptr(), locator.as_ptr(), locator.len()) };
        Error::from_status(status)
    }

    /// Delete the located node, tidying surrounding blank lines for a
    /// whole-line (block) node; an inline node degrades to the exact delete.
    pub fn delete_smart(&mut self, locator: &str) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_delete_smart(self.raw.as_ptr(), locator.as_ptr(), locator.len())
        };
        Error::from_status(status)
    }

    /// Unwrap the located node: replace it with its interior (drop the wrapper,
    /// keep the children) — e.g. peel a `:::vis{...}` container. A node with no
    /// interior (a leaf, or an empty container) is removed.
    pub fn unwrap_node(&mut self, locator: &str) -> Result<(), Error> {
        let status =
            unsafe { ffi::twig_editor_unwrap(self.raw.as_ptr(), locator.as_ptr(), locator.len()) };
        Error::from_status(status)
    }

    /// Prune the document in place: remove every node matching the `drop`
    /// selector except those also matching `keep` (`None` spares nothing),
    /// then — if `unwrap_kept` — unwrap the survivors. Read the result with
    /// [`Editor::source`].
    pub fn filter(
        &mut self,
        drop: &str,
        keep: Option<&str>,
        unwrap_kept: bool,
    ) -> Result<(), Error> {
        let (keep_ptr, keep_len) = match keep {
            Some(k) => (k.as_ptr(), k.len()),
            None => (std::ptr::null(), 0),
        };
        let status = unsafe {
            ffi::twig_editor_filter(
                self.raw.as_ptr(),
                drop.as_ptr(),
                drop.len(),
                keep_ptr,
                keep_len,
                unwrap_kept as i32,
            )
        };
        Error::from_status(status)
    }

    /// The editor's current (edited) source bytes.
    pub fn source(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_editor_source(raw, ptr, len) })
    }

    /// The editor's current source bytes as a UTF-8 string.
    pub fn source_str(&mut self) -> Result<String, Error> {
        String::from_utf8(self.source()?).map_err(|_| Error::Internal)
    }

    /// Encode the editor's current tree as pretty-printed JSON — the live
    /// counterpart of [`Document::ast_json`], for inspecting between edits.
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_editor_ast_json(raw, ptr, len) })
    }

    /// Resolve a selector against the editor's current tree — the live
    /// counterpart of [`Document::query`].
    pub fn query(&mut self, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        collect_matches(|ptr, len| unsafe {
            ffi::twig_editor_query(raw, selector.as_ptr(), selector.len(), ptr, len)
        })
    }

    // ── offset-addressed editing & read-back ────────────────────────────────

    /// Splice `[start, end)` of the current source with `text`, reparse, and
    /// return the [`Change`] the edit produced — the offset-addressed primitive
    /// a caret editor is built on: a keystroke is `edit_range(c, c, "x")`,
    /// backspace `edit_range(c - 1, c, "")`, a selection replace
    /// `edit_range(a, b, s)`. `start <= end <= ` source length, else
    /// [`Error::InvalidArgument`]. A reparse-breaking edit is rolled back and
    /// returns [`Error::EditConflict`], leaving the document untouched.
    pub fn edit_range(&mut self, start: usize, end: usize, text: &str) -> Result<Change, Error> {
        let mut change = ffi::TwigChange {
            old_span: ffi::TwigSpan { start: 0, end: 0 },
            new_span: ffi::TwigSpan { start: 0, end: 0 },
        };
        let status = unsafe {
            ffi::twig_editor_edit_range(
                self.raw.as_ptr(),
                start,
                end,
                text.as_ptr(),
                text.len(),
                &mut change,
            )
        };
        Error::from_status(status)?;
        Ok(Change::from_ffi(change))
    }

    /// The byte effect of the last successful edit — including the locator ops
    /// ([`Editor::replace`], [`Editor::delete_smart`], …), so any edit can
    /// re-anchor a caret without re-diffing. `None` before the first successful
    /// edit. (A multi-splice op such as [`Editor::filter`] reports only its
    /// final splice.)
    pub fn last_change(&mut self) -> Option<Change> {
        let mut change = ffi::TwigChange {
            old_span: ffi::TwigSpan { start: 0, end: 0 },
            new_span: ffi::TwigSpan { start: 0, end: 0 },
        };
        let status = unsafe { ffi::twig_editor_last_change(self.raw.as_ptr(), &mut change) };
        match status.0 {
            ffi::TwigStatus::OK => Some(Change::from_ffi(change)),
            _ => None,
        }
    }

    /// Undo the last edit step, restoring the previous source and reparsing.
    /// Returns the [`Change`] the undo produced (current → restored) so a caret
    /// can re-anchor, or `None` when there's nothing to undo. History accrues
    /// across every successful edit that funnels through the splice primitive.
    pub fn undo(&mut self) -> Result<Option<Change>, Error> {
        let mut change = ffi::TwigChange {
            old_span: ffi::TwigSpan { start: 0, end: 0 },
            new_span: ffi::TwigSpan { start: 0, end: 0 },
        };
        let status = unsafe { ffi::twig_editor_undo(self.raw.as_ptr(), &mut change) };
        if status.0 == ffi::TwigStatus::NOT_FOUND {
            return Ok(None);
        }
        Error::from_status(status)?;
        Ok(Some(Change::from_ffi(change)))
    }

    /// Redo the most recently undone edit step; the inverse of [`Editor::undo`].
    /// Returns `None` when the redo stack is empty (nothing undone, or a fresh
    /// edit has invalidated it).
    pub fn redo(&mut self) -> Result<Option<Change>, Error> {
        let mut change = ffi::TwigChange {
            old_span: ffi::TwigSpan { start: 0, end: 0 },
            new_span: ffi::TwigSpan { start: 0, end: 0 },
        };
        let status = unsafe { ffi::twig_editor_redo(self.raw.as_ptr(), &mut change) };
        if status.0 == ffi::TwigStatus::NOT_FOUND {
            return Ok(None);
        }
        Error::from_status(status)?;
        Ok(Some(Change::from_ffi(change)))
    }

    /// Fold the most recent edit into the undo step before it, so a caret editor
    /// can coalesce a run of keystrokes into a single undo. Call right after an
    /// `edit_range` that continues a run (same kind, no intervening caret move);
    /// a no-op unless there are at least two steps to merge.
    pub fn coalesce_last_undo(&mut self) -> Result<(), Error> {
        let status = unsafe { ffi::twig_editor_coalesce_last(self.raw.as_ptr()) };
        Error::from_status(status)
    }

    /// A monotonic change token, bumped once per successful mutation of the
    /// document (every edit and every undo/redo). Never decreases and never
    /// repeats for the life of the editor; the initial parse is revision 0.
    /// Equal revision means a byte-identical document, so it can key a cache
    /// instead of hand-tracking "did anything change?".
    pub fn revision(&mut self) -> u64 {
        unsafe { ffi::twig_editor_revision(self.raw.as_ptr()) }
    }

    /// The cumulative dirty byte range since the last [`Editor::clear_dirty`]
    /// (or since the editor was created) — the union of every mutation's byte
    /// effect over that window, in current source coordinates — or `None` when
    /// the document is clean relative to the last clear.
    ///
    /// The incremental-rebuild companion to [`Editor::revision`]: `revision`
    /// says *whether* a cached view (glyph rows, syntax spans) needs rebuilding,
    /// this says *which bytes* changed, so a consumer rebuilds only the affected
    /// part instead of the whole document. A single conservative interval: it
    /// always covers every changed byte and may over-cover the gap between edits
    /// to disjoint regions, but never under-covers.
    ///
    /// It reports where *bytes* differ — exact, because twig splices losslessly
    /// and never reflows untouched bytes — not where the *parse* differs. An
    /// edit can reinterpret bytes outside the range (opening a code fence, a `#`
    /// promoting a paragraph to a heading), so a consumer rebuilding *structure*
    /// from it should widen the range to the enclosing block(s) itself (e.g. via
    /// [`Editor::node_at`] on each end). Typical loop: on a repaint, if
    /// [`Editor::revision`] moved, read this range, rebuild the rows it (widened)
    /// covers, then call [`Editor::clear_dirty`].
    pub fn dirty_range(&mut self) -> Option<Range<usize>> {
        let mut span = ffi::TwigSpan { start: 0, end: 0 };
        let status = unsafe { ffi::twig_editor_dirty_range(self.raw.as_ptr(), &mut span) };
        match status.0 {
            ffi::TwigStatus::OK => Some(span.start..span.end),
            _ => None,
        }
    }

    /// Acknowledge the current dirty range: mark the document clean so a later
    /// [`Editor::dirty_range`] reports only mutations made after this call. Call
    /// it once you've consumed the range (rebuilt the affected view). Leaves the
    /// document, [`Editor::revision`], and [`Editor::last_change`] untouched.
    pub fn clear_dirty(&mut self) {
        unsafe { ffi::twig_editor_clear_dirty(self.raw.as_ptr()) };
    }

    /// Attach an opaque, caller-owned blob (e.g. a serialized caret/selection)
    /// to the editor's current document state. Twig copies the bytes and never
    /// interprets them; it only carries them through the undo history so
    /// [`Editor::undo`]/[`Editor::redo`] hand back the caret matching the
    /// restored source (via [`Editor::caret_blob`]). Set it with the pre-edit
    /// caret *before* an edit so the retired undo step captures it. An empty
    /// blob clears the current caret.
    pub fn set_caret_blob(&mut self, blob: &[u8]) -> Result<(), Error> {
        let status = unsafe {
            ffi::twig_editor_set_caret_blob(self.raw.as_ptr(), blob.as_ptr(), blob.len())
        };
        Error::from_status(status)
    }

    /// The opaque caret blob for the editor's current document state (see
    /// [`Editor::set_caret_blob`]). After [`Editor::undo`]/[`Editor::redo`] this
    /// is the restored state's caret; after an edit it is empty until set again.
    /// Returns an owned copy, so it outlives the next edit.
    pub fn caret_blob(&mut self) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_editor_caret_blob(raw, ptr, len) })
    }

    /// The editor's current tree as a borrowed [`Document`], so the whole
    /// document read surface ([`Document::nodes`], [`Document::children`],
    /// [`Document::subtree`], [`Document::node_at`], [`Document::query`],
    /// [`Document::span`], …) applies to a document being edited.
    ///
    /// The view borrows the editor mutably, so no edit can land while it is
    /// alive and the ids it yields cannot go stale; drop it to edit again. See
    /// [`DocumentView`] for the two methods it cannot serve.
    pub fn document(&mut self) -> Result<DocumentView<'_>, Error> {
        let mut raw = std::ptr::null_mut();
        let status = unsafe { ffi::twig_editor_document(self.raw.as_ptr(), &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(DocumentView {
            doc: Document { raw },
            _editor: PhantomData,
        })
    }

    /// Snapshot the current tree as a flat [`FlatNode`] array (the JSON-free
    /// read path for a renderer), indexed so `nodes[i].id == NodeId(i)`. Walk it
    /// via the `parent`/`first_child`/`next_sibling` links; the root is the node
    /// whose `parent` is `None`.
    pub fn nodes(&mut self) -> Result<Vec<FlatNode>, Error> {
        let mut ptr: *const ffi::TwigFlatNode = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe { ffi::twig_editor_nodes(self.raw.as_ptr(), &mut ptr, &mut len) };
        Error::from_status(status)?;
        if len == 0 {
            return Ok(Vec::new());
        }
        if ptr.is_null() {
            return Err(Error::Internal);
        }
        let raw = unsafe { std::slice::from_raw_parts(ptr, len) };
        raw.iter().map(flat_node_from_ffi).collect()
    }

    /// The direct children of `node` as [`QueryMatch`]es (id, span, kind) —
    /// `None` enumerates the document root's children (the top-level blocks). The
    /// cheap top-level enumeration an incremental renderer walks to decide which
    /// blocks changed, without marshalling the whole arena; pair it with
    /// [`Editor::subtree`] to then re-marshal only those that did. A childless
    /// node yields an empty vec.
    pub fn child_spans(&mut self, node: Option<NodeId>) -> Result<Vec<QueryMatch>, Error> {
        let id = node.map_or(ffi::TWIG_NO_NODE, |n| n.0);
        let mut ptr: *const ffi::TwigQueryMatch = std::ptr::null();
        let mut len = 0usize;
        let status =
            unsafe { ffi::twig_editor_child_spans(self.raw.as_ptr(), id, &mut ptr, &mut len) };
        Error::from_status(status)?;
        if len == 0 || ptr.is_null() {
            return Ok(Vec::new());
        }
        let raw = unsafe { std::slice::from_raw_parts(ptr, len) };
        raw.iter().map(query_match_from_ffi).collect()
    }

    /// Snapshot the subtree rooted at `node` as a self-contained [`FlatNode`]
    /// array with *local* ids: `array[0]` is the root, every link is an index
    /// into the returned vec (or `None`), and spans stay absolute. The
    /// incremental-render companion to [`Editor::nodes`] — re-marshal one edited
    /// block's subtree instead of the whole document. The root's `parent` and
    /// `next_sibling` are `None`, so a walk from index 0 stays inside the
    /// subtree. [`Error::InvalidArgument`] if `node` is out of range.
    pub fn subtree(&mut self, node: NodeId) -> Result<Vec<FlatNode>, Error> {
        let mut ptr: *const ffi::TwigFlatNode = std::ptr::null();
        let mut len = 0usize;
        let status =
            unsafe { ffi::twig_editor_subtree(self.raw.as_ptr(), node.0, &mut ptr, &mut len) };
        Error::from_status(status)?;
        if len == 0 || ptr.is_null() {
            return Ok(Vec::new());
        }
        let raw = unsafe { std::slice::from_raw_parts(ptr, len) };
        raw.iter().map(flat_node_from_ffi).collect()
    }

    /// The deepest node whose span contains byte `offset` (with `offset` equal
    /// to the source length treated as inside the root) — mouse hit-testing and
    /// cursor context. `Ok(None)` if no node covers the offset;
    /// [`Error::InvalidArgument`] if `offset` exceeds the source length.
    pub fn node_at(&mut self, offset: usize) -> Result<Option<QueryMatch>, Error> {
        let mut m = ffi::TwigQueryMatch {
            node_id: 0,
            span: ffi::TwigSpan { start: 0, end: 0 },
            content_span: ffi::TwigSpan { start: 0, end: 0 },
            has_content_span: 0,
            kind: std::ptr::null(),
        };
        let status = unsafe { ffi::twig_editor_node_at(self.raw.as_ptr(), offset, &mut m) };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(query_match_from_ffi(&m)?)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// The chain of nodes containing byte `offset`, root-first down to the
    /// deepest (the node [`Editor::node_at`] returns) — the ancestor path for a
    /// breadcrumb or context-scoped edit. Empty if no node covers the offset.
    pub fn ancestors_at(&mut self, offset: usize) -> Result<Vec<QueryMatch>, Error> {
        let mut ptr: *const ffi::TwigQueryMatch = std::ptr::null();
        let mut len = 0usize;
        let status =
            unsafe { ffi::twig_editor_nodes_at(self.raw.as_ptr(), offset, &mut ptr, &mut len) };
        match status.0 {
            ffi::TwigStatus::OK => {}
            ffi::TwigStatus::NOT_FOUND => return Ok(Vec::new()),
            _ => return Err(Error::from_status(status).unwrap_err()),
        }
        if len == 0 || ptr.is_null() {
            return Ok(Vec::new());
        }
        let raw = unsafe { std::slice::from_raw_parts(ptr, len) };
        raw.iter().map(query_match_from_ffi).collect()
    }

    // ── range-oriented rich-text ops (the toolbar) ──────────────────────────

    /// Wrap `[start, end)` with `kind`'s delimiters — the unconditional half of
    /// the inline toolbar (always adds a mark; `*word*` → `**word**` stacks).
    /// [`Error::UnsupportedFormat`] if the document's format can't spell `kind`
    /// (e.g. a Markdown [`InlineKind::Mark`]); [`Error::InvalidArgument`] for a
    /// bad range; [`Error::EditConflict`] if the result doesn't reparse.
    pub fn wrap_range(
        &mut self,
        start: usize,
        end: usize,
        kind: InlineKind,
    ) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_wrap_range(ed, start, end, kind.to_c(), out)
        })
    }

    /// Toggle `kind` over `[start, end)`: remove the mark if the range already
    /// *is* a node of `kind` (its whole span or its rendered interior), else
    /// wrap it — a rich editor's Cmd-B. Same error rules as
    /// [`Editor::wrap_range`].
    pub fn toggle_inline(
        &mut self,
        start: usize,
        end: usize,
        kind: InlineKind,
    ) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_toggle_inline(ed, start, end, kind.to_c(), out)
        })
    }

    /// Convert the innermost heading/paragraph covering byte `offset` to `kind`,
    /// rewriting its leading marker while keeping its inline content (the
    /// toolbar's H1…H6 / Body switch). Djot and Markdown only, else
    /// [`Error::UnsupportedFormat`]; [`Error::NotFound`] if no heading/paragraph
    /// covers `offset`; [`Error::InvalidArgument`] for a heading level outside
    /// 1–6.
    pub fn set_block(&mut self, offset: usize, kind: BlockKind) -> Result<Change, Error> {
        let (block_kind, level) = kind.to_c();
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_set_block(ed, offset, block_kind, level, out)
        })
    }

    /// Toggle a block container over the blocks `[start, end)` covers — the
    /// toolbar's Quote / Bulleted list / Numbered list buttons. Djot and Markdown
    /// only, else [`Error::UnsupportedFormat`]; [`Error::NotFound`] if the range
    /// covers no block; [`Error::InvalidArgument`] for a bad range.
    ///
    /// The range widens to whole lines of the blocks it touches (you cannot quote
    /// half a paragraph), and the prefix lands at column 0, so a container wraps
    /// the outermost structure on those lines.
    ///
    /// Whether this adds or removes is decided from the **AST** — the ancestors
    /// of `start` — not by looking for a `>` in the source. It removes the
    /// container only when the range covers every block that container holds, and
    /// then only one level (`> > a` → `> a`). A partly covered container **nests**
    /// instead, since removing it would drag its uncovered siblings out with it:
    /// selecting the first paragraph of `> a\n>\n> b\n` gives `> > a\n>\n> b\n`.
    /// Toggling one list kind while inside the other **converts** in place
    /// (`- a` → `1. a`) rather than nesting.
    ///
    /// Each covered block becomes one item, so an ordered list numbers a
    /// multi-block range `1.`, `2.`, `3.`… Removing a list inserts a blank line
    /// between items that lacked one, keeping them separate blocks (a tight
    /// `- a\n- b\n` stripped bare would be a single two-line paragraph).
    pub fn toggle_block_container(
        &mut self,
        start: usize,
        end: usize,
        kind: BlockContainerKind,
    ) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_toggle_block_container(ed, start, end, kind.to_c(), out)
        })
    }

    /// Renumber the ordered list at byte `offset` so its markers run `1, 2, 3, …`,
    /// each nesting level restarting at 1 — the numbering a caret editor keeps as
    /// items are inserted, deleted, and nested, where a raw splice leaves the
    /// source numbers stale (`1. 2. 2. 3.`). Djot and Markdown; the display of an
    /// ordered list is renumbered by any CommonMark renderer regardless, so this
    /// is source hygiene, not a render fix.
    ///
    /// [`Error::NotFound`] when `offset` is not inside an ordered list. When the
    /// numbering is already sequential this is a no-op that still returns `Ok` —
    /// the source is left byte-for-byte unchanged. The `Change` is not returned
    /// because a no-op has none; re-read [`Editor::source_str`] for the result.
    ///
    /// Only lines the PARSER reads as items are touched, so this never rewrites a
    /// digit the author wrote as prose. That is not a corner case across formats:
    /// Djot doesn't let a list marker interrupt a paragraph, so in
    /// `1. a\n   2. b` the second line is text inside item `a`, while Markdown
    /// reads it as a nested item — the same bytes, renumbered in one format and
    /// left alone in the other.
    pub fn renumber_ordered_lists(&mut self, offset: usize) -> Result<(), Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_renumber_ordered_lists(ed, offset, out)
        })?;
        Ok(())
    }

    // ── Tables ───────────────────────────────────────────────────────────────
    // Structural editing of the pipe table at a byte `offset`: the caret's cell
    // is the anchor. The whole table is re-spelled and spliced in one edit, so a
    // caller re-reads [`Editor::source_str`] and re-places its caret rather than
    // leaning on the returned span. [`Error::NotFound`] when `offset` is not in a
    // table; [`Error::NotEditable`] for a refused (degenerate) edit.

    /// Insert an empty row below (`below`) or above the caret's row.
    pub fn table_insert_row(&mut self, offset: usize, below: bool) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_INSERT_ROW, below as c_int)
    }

    /// Delete the caret's row. [`Error::NotEditable`] for the header row or the
    /// last remaining body row.
    pub fn table_delete_row(&mut self, offset: usize) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_DELETE_ROW, 0)
    }

    /// Insert an empty column right (`right`) or left of the caret's column.
    pub fn table_insert_column(&mut self, offset: usize, right: bool) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_INSERT_COLUMN, right as c_int)
    }

    /// Delete the caret's column. [`Error::NotEditable`] when it is the only one.
    pub fn table_delete_column(&mut self, offset: usize) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_DELETE_COLUMN, 0)
    }

    /// Set the caret's column to `alignment`.
    pub fn table_set_alignment(
        &mut self,
        offset: usize,
        alignment: Alignment,
    ) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_SET_ALIGNMENT, alignment.to_c())
    }

    /// Move the caret's row one place down (`down`) or up, within the body rows.
    pub fn table_move_row(&mut self, offset: usize, down: bool) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_MOVE_ROW, down as c_int)
    }

    /// Move the caret's column one place right (`right`) or left.
    pub fn table_move_column(&mut self, offset: usize, right: bool) -> Result<(), Error> {
        self.table_edit(offset, ffi::TWIG_TABLE_MOVE_COLUMN, right as c_int)
    }

    fn table_edit(&mut self, offset: usize, op: c_int, arg: c_int) -> Result<(), Error> {
        self.change_op(|ed, out| unsafe { ffi::twig_editor_table_edit(ed, offset, op, arg, out) })?;
        Ok(())
    }

    /// Link `[start, end)` to `destination` — `[text](destination)`. Djot and
    /// Markdown only, else [`Error::UnsupportedFormat`];
    /// [`Error::InvalidArgument`] for a bad range or a destination containing a
    /// newline (neither format can carry one, and quietly rewriting the URL would
    /// be worse than refusing).
    ///
    /// An existing link covering the range has its destination **replaced** and
    /// its text kept, so re-linking fixes a URL instead of nesting
    /// `[[t](a)](b)`; to unlink, use [`Editor::unwrap_node`].
    ///
    /// A **range inside an existing autolink** (`<https://x.dev>`) re-points it
    /// the same way, but there is no text to keep — an autolink's text *is* its
    /// destination — so the node is replaced whole, respelled canonically for the
    /// new destination. This covers a caret and any selection the autolink
    /// contains, including one covering it exactly: an autolink's URL is not
    /// editable text, so no part of it can host a `[`, and "link half this URL"
    /// has no spelling. A caret inside both an autolink and a link
    /// (`[<https://x.dev>](d)`) re-points the link, whose text is separable from
    /// its destination and so survives.
    ///
    /// A selection starting or ending strictly **inside** an autolink without
    /// being contained by it — running from ordinary text into the middle of a
    /// URL — is refused with [`Error::NotEditable`]: half of it is real text,
    /// so there is nothing to re-point, and any splice would rewrite the URL.
    /// A selection that *contains* an autolink whole is unaffected — it splices
    /// at the edges and wraps as usual.
    ///
    /// A link with **no text** — an empty range, or re-pointing an existing
    /// `[](old)` — is spelled canonically for the destination given, never as
    /// `[](destination)`: a childless link has nothing to render, so consumers
    /// fall back to showing the destination and a caret has nowhere to sit. A
    /// destination the format can autolink (an absolute URL or an email, by that
    /// format's own rules) yields `<destination>`; anything else yields
    /// `[destination](destination)`, the destination doubling as the text so it
    /// stays visible and editable. Which destinations autolink is not the
    /// caller's to guess — `<foo>` is raw HTML in Markdown, a relative path goes
    /// literal in both, and the formats disagree (`<mailto:a@b.dev>` is a url in
    /// Markdown, an email in Djot), so each is asked its own parser.
    ///
    /// The destination is escaped for the format, so a `)` or a space in it
    /// cannot break the markup — and the two formats genuinely differ: Markdown
    /// ends a destination at the first space (`[t](a b)` is not a link at all) so
    /// whitespace moves it into the `<…>` form, while Djot takes spaces literally
    /// and would read `<a b>` as the URL itself.
    pub fn insert_link(
        &mut self,
        start: usize,
        end: usize,
        destination: &str,
    ) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_insert_link(
                ed,
                start,
                end,
                destination.as_ptr(),
                destination.len(),
                out,
            )
        })
    }

    /// Spell `[start, end)` as an image pointing at `destination` —
    /// `![alt](destination)`, the selected source becoming the alt text.
    ///
    /// The destination is escaped exactly as [`insert_link`](Self::insert_link)
    /// escapes one, because it is the same grammar production: Markdown moves a
    /// destination holding whitespace into the `<…>` form, Djot leaves it bare
    /// because `<…>` there would read as the URL itself. That is the reason this
    /// exists rather than being a `format!` at the call site — `![](my file.png)`
    /// is not an image in Markdown at all, and no caller can fix that without
    /// reproducing twig's per-format escape table.
    ///
    /// Two ways it is simpler than a link. An empty range stays empty:
    /// `![](destination)` is a perfectly good image, where the childless
    /// `[](destination)` that `insert_link` works to avoid has nothing to render
    /// or put a caret in. And there is no autolink or re-point reasoning — an
    /// image has no bare-URL spelling, and re-pointing an existing one is a read
    /// of its destination plus an insert, above this op.
    ///
    /// Returns [`Error::InvalidArgument`] for a destination holding a newline and
    /// [`Error::UnsupportedFormat`] for a parse-only format (XML, HTML).
    pub fn insert_image(
        &mut self,
        start: usize,
        end: usize,
        destination: &str,
    ) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_insert_image(
                ed,
                start,
                end,
                destination.as_ptr(),
                destination.len(),
                out,
            )
        })
    }

    /// Insert `text` at `offset` as a literal run: every byte the format reads as
    /// markup is backslash-escaped so the run reparses as exactly `text` — a typed
    /// `*`, `#` or `` ` `` stays that character rather than opening emphasis, a
    /// heading or a code span. This is the inverse of serialization (which writes
    /// an already-parsed run verbatim): it is what a WYSIWYG surface calls so that
    /// keyboard input can never mint markup, leaving formatting to explicit
    /// commands.
    ///
    /// The escaping is positional and per-format, and neither is the caller's to
    /// reproduce: inline specials (`*`, `` ` ``, `[`, `<`…) are escaped anywhere
    /// on the line, while block markers (`#`, `>`, `-`…) are escaped only where
    /// `offset` sits in its line's leading whitespace — so an inserted "5 - 3"
    /// keeps its `-` but "- item" at column zero does not become a bullet. An
    /// embedded newline in `text` re-enters that line-start zone.
    ///
    /// Two constructs a byte-alphabet cannot reach are left as typed: a GFM
    /// bare-URL autolink (`https://x.com`, with no delimiter to escape) and an
    /// ordered-list marker (`1.`, special only after a digit run). Returns
    /// [`Error::UnsupportedFormat`] for a parse-only format (XML, HTML) and
    /// [`Error::InvalidArgument`] when `offset` is past the source.
    pub fn insert_literal(&mut self, offset: usize, text: &str) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_insert_literal(ed, offset, text.as_ptr(), text.len(), out)
        })
    }

    /// Insert a hard line break *inside a table cell* at `offset`, spelled the
    /// format's way (`<br>` for Markdown). A table row is one source line, so the
    /// ordinary newline-based hard break can't appear there; the spliced `<br>`
    /// reparses as a semantic `hard_break` node — not opaque raw HTML — so the
    /// break reads back as structure. Like the other gestures it leans on the
    /// splice+reparse+rollback backstop: a break that would no longer parse as the
    /// same table yields [`Error::EditConflict`] and changes nothing.
    ///
    /// Returns [`Error::UnsupportedFormat`] for a format with no in-cell break
    /// spelling — djot (no idiomatic in-cell break), HTML and XML (parse-only);
    /// [`Error::NotFound`] when `offset` is not inside a table cell (only the
    /// in-cell gesture is spelled today); and [`Error::InvalidArgument`] when
    /// `offset` is past the source.
    pub fn insert_line_break(&mut self, offset: usize) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe { ffi::twig_editor_insert_line_break(ed, offset, out) })
    }

    /// Insert a thematic break (a horizontal rule) as its own block, on the line
    /// after the block `offset` sits in. A rule is a block, so there is no
    /// spelling for one mid-paragraph.
    ///
    /// The rule is blank-line separated from its neighbours, and that is
    /// load-bearing rather than cosmetic: Markdown reads `---` on the line
    /// directly under a paragraph as a setext `<h2>` underline, so a rule written
    /// flush against its predecessor silently becomes a heading and swallows it.
    /// The blank below is added only when the next line isn't already blank. The
    /// spelling is the format's (`---` for Markdown, `* * *` for djot) and not
    /// the caller's to reproduce.
    ///
    /// Inside a block quote the rule inherits the quote's prefix and stays in the
    /// quote. Inside a list it lands at column zero after the caret's item, which
    /// splits the list in two with the rule between — a real document, nothing
    /// swallowed. There is no [`Error::NotFound`]: an empty document is a fine
    /// place for a rule. [`Error::UnsupportedFormat`] for a parse-only format
    /// (XML, HTML); [`Error::InvalidArgument`] when `offset` is past the source.
    pub fn insert_thematic_break(&mut self, offset: usize) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe { ffi::twig_editor_insert_thematic_break(ed, offset, out) })
    }

    /// Split the block at `offset` in two at the caret, both halves the same
    /// kind — Enter in the middle of a paragraph, and the gesture
    /// [`Editor::insert_thematic_break`] deliberately is not. A host wanting
    /// "rule at the caret" calls this and then that.
    ///
    /// Nearly a pure insertion at `offset`: what is minted is the separator
    /// between the halves, and the only bytes removed are the second half's
    /// leading spaces and tabs, which are structure rather than content at the
    /// start of a block — a split at `- b| c` that kept its space would write
    /// `-  c`, setting that item's content indent to three. A code block sheds
    /// nothing, because there leading whitespace *is* the content.
    ///
    /// * A **paragraph** gets a blank line. Inside a quote the blank carries the
    ///   quote's marker and the second half its full prefix, so the split
    ///   happens inside the quote rather than ending it.
    /// * A paragraph in a **list item** gets the item's marker instead of a
    ///   blank, so the second half is a sibling item: `- this is |a list item`
    ///   becomes `- this is ` and `- a list item`. The marker is repeated
    ///   verbatim, ordered numbers included, so a split `1.` item yields two
    ///   `1.` items — both formats renumber on render, and
    ///   [`Editor::renumber_ordered_lists`] is the gesture for fixing the
    ///   source. A **task** item's new half is an unchecked box whatever the
    ///   original's state. A **nested** item's leading indent rides along with
    ///   its marker, so the new sibling stays in its own list rather than
    ///   dropping to column zero and joining the enclosing one.
    /// * A **heading** repeats its own marker at its own level;
    ///   [`Editor::set_block`] is how a caller demotes the second half instead.
    /// * A **code block** becomes two code blocks, the opening fence line
    ///   reproduced verbatim so its width and info string both survive. A
    ///   consumer that doesn't want the gesture offered there can ask the tree
    ///   what block the caret is in before calling.
    ///
    /// At a block boundary this still splits, which is what makes it Enter: at
    /// the end of a list item it opens an empty sibling item, which is the block
    /// the caller wants to type into. A paragraph is the one place that empty
    /// block cannot be spelled — no format has an empty paragraph — so the
    /// source gains a blank line and reparses as one paragraph; the node appears
    /// when there is text to hold.
    ///
    /// [`Error::NotEditable`] where a caret-split has no honest meaning: a
    /// **table** (a newline mid-cell destroys rather than divides; splitting one
    /// table into two is a table gesture, not this one), a **setext heading**
    /// (whose `---` underline would end up under the second half alone —
    /// [`Editor::set_block`] normalises one to ATX, which makes this work), and
    /// an **indented code block** (where a blank line is interior, so the split
    /// would parse back as one block). [`Error::NotFound`] when nothing covers
    /// `offset`; [`Error::InvalidArgument`] when `offset` is past the source.
    pub fn split_block(&mut self, offset: usize) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe { ffi::twig_editor_split_block(ed, offset, out) })
    }

    /// Toggle a fenced code block over the blocks `[start, end)` covers: fence
    /// them if the caret is not in a code block, unfence the one it is in if it
    /// is. `language` tags the opening fence and is ignored when unfencing.
    ///
    /// `None` and `Some("")` are different requests: both write a bare fence, but
    /// the second says the caller asked for an empty info string. Reading the
    /// language back gives `None` either way — the distinction is in the ask, not
    /// the bytes. (Across the C ABI this rides as the `(ptr, len, has_*)` triple,
    /// the same spelling [`Builder::add_code_block`] uses for the same value.)
    ///
    /// Fencing *inserts* at the covered region's edges rather than rewriting its
    /// lines, so a body already carrying a quote's `> ` keeps it and the fence
    /// lines get the same prefix. The fence is **measured** — one character
    /// longer than the longest run of the fence character in the body — so
    /// fencing text that itself contains a fence nests instead of closing early.
    ///
    /// Unfencing peels the opening line and, when there is one, the closing fence
    /// line; a Markdown *indented* code block has no fence to peel and is
    /// dedented instead, so the toggle stays reversible on the older spelling.
    /// Note that unfencing can yield a different tree than the one that was
    /// fenced: a code body is by definition text the parser did not read as
    /// markup, so `# x` inside a fence becomes a heading once the fence is gone.
    ///
    /// [`Error::NotEditable`] **inside a list item**, in both directions: a
    /// quote's marker is on every line, a list item's is on its first line only,
    /// so a fence at column zero there would pull the `- ` into the code body and
    /// the item would stop being an item. [`Error::InvalidArgument`] for an info
    /// string the fence cannot carry (a line end, the fence character, or — in
    /// Markdown, whose info string ends at whitespace — a space);
    /// [`Error::UnsupportedFormat`] for a parse-only format;
    /// [`Error::NotFound`] when no block covers the range.
    pub fn toggle_code_block(
        &mut self,
        start: usize,
        end: usize,
        language: Option<&str>,
    ) -> Result<Change, Error> {
        let (ptr, len, has) = opt_str(language);
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_toggle_code_block(ed, start, end, ptr, len, has, out)
        })
    }

    /// Retag the code block at `offset` with `language`, or clear its info string
    /// with `None` — the language dropdown beside a code block. Same
    /// `None`/`Some("")` distinction as [`Editor::toggle_code_block`].
    ///
    /// Only the info string is rewritten; the fence's own width is kept, because
    /// it was measured against a body this does not touch. [`Error::NotEditable`]
    /// for an *indented* Markdown code block, which has no fence and so nowhere
    /// to carry a language; [`Error::NotFound`] when `offset` is not in a code
    /// block.
    pub fn set_code_language(
        &mut self,
        offset: usize,
        language: Option<&str>,
    ) -> Result<Change, Error> {
        let (ptr, len, has) = opt_str(language);
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_set_code_language(ed, offset, ptr, len, has, out)
        })
    }

    /// Add a checkbox to the list item at `offset`, or take one away — the
    /// gesture that converts between a plain list item and a task list item. A
    /// box is added unchecked; [`Editor::set_task_checked`] ticks it.
    ///
    /// The box is inline content of the item's first paragraph, not part of its
    /// marker, so adding or removing one leaves the item's continuation-line
    /// indentation alone. An item inside a quote is found past the quote markers.
    /// [`Error::NotFound`] when `offset` is in no list item;
    /// [`Error::NotEditable`] when the item's line carries no recognizable list
    /// marker; [`Error::UnsupportedFormat`] for a format with no checkbox.
    pub fn toggle_task_item(&mut self, offset: usize) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe { ffi::twig_editor_toggle_task_item(ed, offset, out) })
    }

    /// Tick or untick the task item at `offset` — a checkbox click when the
    /// caller knows which way it should end up.
    ///
    /// Rewrites the box alone, never the space after it, so an item spelled with
    /// unusual spacing keeps it. A capital `[X]` is read as checked.
    ///
    /// When the box is already in the requested state this is a no-op that still
    /// returns `Ok` — the source is left byte-for-byte unchanged. The `Change` is
    /// not returned because a no-op has none; re-read [`Editor::source_str`].
    ///
    /// [`Error::NotEditable`] when the item has no box: minting one here would
    /// make "set checked" silently convert a bullet into a task, which is
    /// [`Editor::toggle_task_item`]'s job to do explicitly.
    pub fn set_task_checked(&mut self, offset: usize, checked: bool) -> Result<(), Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_set_task_checked(ed, offset, checked as c_int, out)
        })?;
        Ok(())
    }

    /// Flip the task item at `offset` — what a checkbox click actually is when
    /// the caller does not already know the state. Always edits or fails, so
    /// unlike [`Editor::set_task_checked`] there is no silent no-op and the
    /// `Change` is always real.
    pub fn toggle_task_checked(&mut self, offset: usize) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe { ffi::twig_editor_toggle_task_checked(ed, offset, out) })
    }

    /// Insert a footnote reference at `offset` and, unless the label is already
    /// defined, the matching definition at the end of the document.
    ///
    /// It writes **both halves**, because in neither format is half a footnote a
    /// footnote: a bare `[^a]` with nothing defining it renders as four literal
    /// characters. The definition body is left empty — that parses, and the
    /// caller then types into it like any other block. A label that is already
    /// defined gets only the reference, so referring to one footnote twice does
    /// not append a second, dead definition.
    ///
    /// It is **one** edit, spanning the caret to the end of the document even
    /// though the halves are far apart: two edits would take two undos to
    /// reverse, and the returned `Change` would describe only the second,
    /// omitting the reference the caret is sitting in.
    ///
    /// [`Error::InvalidArgument`] for a label that is empty or holds a line end
    /// or a reference bracket; [`Error::UnsupportedFormat`] for a format with no
    /// footnotes.
    pub fn insert_footnote(&mut self, offset: usize, label: &str) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_insert_footnote(ed, offset, label.as_ptr(), label.len(), out)
        })
    }

    /// Shared plumbing for the change-returning ops: run `op` (which fills a
    /// `TwigChange` out-param) and wrap the result.
    fn change_op(
        &mut self,
        op: impl FnOnce(*mut ffi::TwigEditor, *mut ffi::TwigChange) -> ffi::TwigStatus,
    ) -> Result<Change, Error> {
        let mut change = ffi::TwigChange {
            old_span: ffi::TwigSpan { start: 0, end: 0 },
            new_span: ffi::TwigSpan { start: 0, end: 0 },
        };
        let status = op(self.raw.as_ptr(), &mut change);
        Error::from_status(status)?;
        Ok(Change::from_ffi(change))
    }

    /// Shared plumbing for the `(locator, text)` edit ops.
    fn apply(
        &mut self,
        locator: &str,
        text: &str,
        op: impl FnOnce(*mut ffi::TwigEditor, *const u8, usize, *const u8, usize) -> ffi::TwigStatus,
    ) -> Result<(), Error> {
        let status = op(
            self.raw.as_ptr(),
            locator.as_ptr(),
            locator.len(),
            text.as_ptr(),
            text.len(),
        );
        Error::from_status(status)
    }
}

impl Drop for Editor {
    fn drop(&mut self) {
        unsafe { ffi::twig_editor_destroy(self.raw.as_ptr()) }
    }
}

/// Run `call` (which writes a borrowed `(ptr, len)` byte buffer) and copy the
/// result into an owned `Vec` — the buffer is only valid until the next
/// same-accessor call on the handle, so we copy before returning. Shared by
/// [`Document`] and [`Editor`].
fn collect_bytes(
    call: impl FnOnce(*mut *const u8, *mut usize) -> ffi::TwigStatus,
) -> Result<Vec<u8>, Error> {
    let mut ptr = std::ptr::null();
    let mut len = 0usize;
    let status = call(&mut ptr, &mut len);
    Error::from_status(status)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    if ptr.is_null() {
        return Err(Error::Internal);
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    Ok(bytes.to_vec())
}

/// Run `call` (which writes a borrowed `(ptr, len)` match array) and copy each
/// match into an owned [`QueryMatch`]. Shared by [`Document`] and [`Editor`].
fn collect_matches(
    call: impl FnOnce(*mut *const ffi::TwigQueryMatch, *mut usize) -> ffi::TwigStatus,
) -> Result<Vec<QueryMatch>, Error> {
    let mut ptr = std::ptr::null();
    let mut len = 0usize;
    let status = call(&mut ptr, &mut len);
    Error::from_status(status)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    if ptr.is_null() {
        return Err(Error::Internal);
    }
    let matches = unsafe { std::slice::from_raw_parts(ptr, len) };
    matches.iter().map(query_match_from_ffi).collect()
}

/// `collect_matches` for the flat-node reads (`nodes` / `subtree`), which hand
/// back a borrowed [`ffi::TwigFlatNode`] array on the same contract.
fn collect_flat_nodes(
    call: impl FnOnce(*mut *const ffi::TwigFlatNode, *mut usize) -> ffi::TwigStatus,
) -> Result<Vec<FlatNode>, Error> {
    let mut ptr = std::ptr::null();
    let mut len = 0usize;
    let status = call(&mut ptr, &mut len);
    Error::from_status(status)?;
    if len == 0 {
        return Ok(Vec::new());
    }
    if ptr.is_null() {
        return Err(Error::Internal);
    }
    let nodes = unsafe { std::slice::from_raw_parts(ptr, len) };
    nodes.iter().map(flat_node_from_ffi).collect()
}

/// The zeroed out-parameter the `node_at` hit-tests fill.
fn empty_ffi_match() -> ffi::TwigQueryMatch {
    ffi::TwigQueryMatch {
        node_id: 0,
        span: ffi::TwigSpan { start: 0, end: 0 },
        content_span: ffi::TwigSpan { start: 0, end: 0 },
        has_content_span: 0,
        kind: std::ptr::null(),
    }
}

/// Copy a borrowed C ABI [`ffi::TwigQueryMatch`] into an owned [`QueryMatch`].
/// Shared by `collect_matches`, [`Editor::node_at`], and [`Editor::ancestors_at`].
fn query_match_from_ffi(m: &ffi::TwigQueryMatch) -> Result<QueryMatch, Error> {
    Ok(QueryMatch {
        node_id: m.node_id,
        span: m.span.start..m.span.end,
        content_span: if m.has_content_span != 0 {
            Some(m.content_span.start..m.content_span.end)
        } else {
            None
        },
        kind: Kind::from(borrowed_cstr(m.kind)?.as_str()),
    })
}

/// Copy a borrowed C ABI [`ffi::TwigFlatNode`] into an owned [`FlatNode`].
fn flat_node_from_ffi(n: &ffi::TwigFlatNode) -> Result<FlatNode, Error> {
    let node_id = |v: u32| {
        if v == ffi::TWIG_NO_NODE {
            None
        } else {
            Some(NodeId(v))
        }
    };
    Ok(FlatNode {
        id: NodeId(n.id),
        parent: node_id(n.parent),
        first_child: node_id(n.first_child),
        next_sibling: node_id(n.next_sibling),
        span: n.span.start..n.span.end,
        content_span: if n.has_content_span != 0 {
            Some(n.content_span.start..n.content_span.end)
        } else {
            None
        },
        level: if n.level != 0 { Some(n.level) } else { None },
        kind: Kind::from(borrowed_cstr(n.kind)?.as_str()),
        text: borrowed_bytes(n.text_ptr, n.text_len),
        destination: borrowed_bytes(n.destination_ptr, n.destination_len),
        head: match n.head {
            ffi::TWIG_HEAD_NONE => None,
            v => Some(v != 0),
        },
        alignment: Alignment::from_c(n.alignment),
        name: borrowed_bytes(n.name_ptr, n.name_len),
        directive_form: DirectiveForm::from_c(n.directive_form),
        origin: ContainerOrigin::from_c(n.container_origin),
        marker_span: if n.has_marker_span != 0 {
            Some(n.marker_span.start..n.marker_span.end)
        } else {
            None
        },
        attrs: borrowed_attrs(n.attrs_ptr, n.attrs_len),
    })
}

/// Copy a borrowed `TwigKeyVal` array into owned `(key, value)` pairs, or an
/// empty vec for a NULL pointer (the node has no attributes). A bare attribute
/// (NULL `value`) maps to a `None` value, distinct from a present-but-empty one.
fn borrowed_attrs(ptr: *const ffi::TwigKeyVal, len: usize) -> Vec<(String, Option<String>)> {
    if ptr.is_null() || len == 0 {
        return Vec::new();
    }
    let kvs = unsafe { std::slice::from_raw_parts(ptr, len) };
    kvs.iter()
        .map(|kv| {
            let key = borrowed_bytes(kv.key, kv.key_len).unwrap_or_default();
            (key, borrowed_bytes(kv.value, kv.value_len))
        })
        .collect()
}

/// Copy a NUL-terminated, library-owned C string into an owned `String`.
fn borrowed_cstr(ptr: *const c_char) -> Result<String, Error> {
    if ptr.is_null() {
        return Err(Error::Internal);
    }
    Ok(unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| Error::Internal)?
        .to_owned())
}

/// Copy a borrowed `(ptr, len)` payload slice into an owned `String`, or `None`
/// for a NULL pointer (the kind carries no such payload). The bytes are a slice
/// of a UTF-8 document, so a lossy decode never actually substitutes.
fn borrowed_bytes(ptr: *const u8, len: usize) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    Some(String::from_utf8_lossy(bytes).into_owned())
}

/// The id of a node added to a [`Builder`], returned by every `add*` method and
/// used to wire up the tree via [`Builder::set_children`] and to root a
/// render/serialize/query.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct NodeId(pub u32);

/// The void-payload node kinds, addable via [`Builder::add`]. Kinds with a
/// payload have their own dedicated `add_*` method instead.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VoidKind {
    Doc,
    Para,
    ThematicBreak,
    Section,
    Div,
    BlockQuote,
    DefinitionList,
    Table,
    ListItem,
    DefinitionListItem,
    Term,
    Definition,
    Caption,
    SoftBreak,
    HardBreak,
    NonBreakingSpace,
    Emph,
    Strong,
    Span,
    Mark,
    Superscript,
    Subscript,
    Insert,
    Delete,
    DoubleQuoted,
    SingleQuoted,
}

impl VoidKind {
    fn to_c(self) -> c_int {
        // Discriminants match `TwigNodeKind` in the C ABI.
        match self {
            VoidKind::Doc => 0,
            VoidKind::Para => 1,
            VoidKind::ThematicBreak => 3,
            VoidKind::Section => 4,
            VoidKind::Div => 5,
            VoidKind::BlockQuote => 9,
            VoidKind::DefinitionList => 13,
            VoidKind::Table => 14,
            VoidKind::ListItem => 15,
            VoidKind::DefinitionListItem => 17,
            VoidKind::Term => 18,
            VoidKind::Definition => 19,
            VoidKind::Caption => 22,
            VoidKind::SoftBreak => 26,
            VoidKind::HardBreak => 27,
            VoidKind::NonBreakingSpace => 28,
            VoidKind::Emph => 38,
            VoidKind::Strong => 39,
            VoidKind::Span => 42,
            VoidKind::Mark => 43,
            VoidKind::Superscript => 44,
            VoidKind::Subscript => 45,
            VoidKind::Insert => 46,
            VoidKind::Delete => 47,
            VoidKind::DoubleQuoted => 48,
            VoidKind::SingleQuoted => 49,
        }
    }
}

/// The single-string-payload node kinds, addable via [`Builder::add_text`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextKind {
    Str,
    Symb,
    Verbatim,
    InlineMath,
    DisplayMath,
    Url,
    Email,
    FootnoteReference,
    /// reStructuredText's `[CIT2002]_` — a use of a citation definition. The
    /// payload is the label as WRITTEN, not the normalized name it resolves by.
    CitationReference,
    /// reStructuredText's `|name|` — a use of a substitution definition.
    SubstitutionReference,
    Comment,
    Doctype,
    Cdata,
}

impl TextKind {
    fn to_c(self) -> c_int {
        match self {
            TextKind::Str => 25,
            TextKind::Symb => 29,
            TextKind::Verbatim => 30,
            TextKind::InlineMath => 32,
            TextKind::DisplayMath => 33,
            TextKind::Url => 34,
            TextKind::Email => 35,
            TextKind::FootnoteReference => 36,
            TextKind::CitationReference => 58,
            TextKind::SubstitutionReference => 59,
            TextKind::Comment => 52,
            TextKind::Doctype => 53,
            TextKind::Cdata => 55,
        }
    }
}

/// Bullet marker style for [`Builder::add_bullet_list`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BulletStyle {
    Dash,
    Plus,
    Star,
}

impl BulletStyle {
    fn to_c(self) -> c_int {
        match self {
            BulletStyle::Dash => 0,
            BulletStyle::Plus => 1,
            BulletStyle::Star => 2,
        }
    }
}

/// Numbering scheme for [`Builder::add_ordered_list`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrderedNumbering {
    Decimal,
    LowerAlpha,
    UpperAlpha,
    LowerRoman,
    UpperRoman,
}

impl OrderedNumbering {
    fn to_c(self) -> c_int {
        match self {
            OrderedNumbering::Decimal => 0,
            OrderedNumbering::LowerAlpha => 1,
            OrderedNumbering::UpperAlpha => 2,
            OrderedNumbering::LowerRoman => 3,
            OrderedNumbering::UpperRoman => 4,
        }
    }
}

/// Delimiter around an ordered-list number (`1.`, `1)`, `(1)`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrderedDelim {
    Period,
    ParenAfter,
    ParenBoth,
}

impl OrderedDelim {
    fn to_c(self) -> c_int {
        match self {
            OrderedDelim::Period => 0,
            OrderedDelim::ParenAfter => 1,
            OrderedDelim::ParenBoth => 2,
        }
    }
}

/// Table-cell alignment: written via [`Builder::add_cell`], read back on
/// [`FlatNode::alignment`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Alignment {
    Default,
    Left,
    Right,
    Center,
}

impl Alignment {
    fn to_c(self) -> c_int {
        match self {
            Alignment::Default => ffi::TWIG_ALIGN_DEFAULT,
            Alignment::Left => ffi::TWIG_ALIGN_LEFT,
            Alignment::Right => ffi::TWIG_ALIGN_RIGHT,
            Alignment::Center => ffi::TWIG_ALIGN_CENTER,
        }
    }

    /// The inverse of [`Alignment::to_c`]; `None` for [`ffi::TWIG_ALIGN_NONE`]
    /// (the node isn't a cell) or any code this binding doesn't know.
    fn from_c(v: c_int) -> Option<Self> {
        match v {
            ffi::TWIG_ALIGN_DEFAULT => Some(Alignment::Default),
            ffi::TWIG_ALIGN_LEFT => Some(Alignment::Left),
            ffi::TWIG_ALIGN_RIGHT => Some(Alignment::Right),
            ffi::TWIG_ALIGN_CENTER => Some(Alignment::Center),
            _ => None,
        }
    }
}

/// The smart-punctuation kind for [`Builder::add_smart_punctuation`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SmartPunctuation {
    LeftSingleQuote,
    RightSingleQuote,
    LeftDoubleQuote,
    RightDoubleQuote,
    Ellipses,
    EmDash,
    EnDash,
}

impl SmartPunctuation {
    fn to_c(self) -> c_int {
        match self {
            SmartPunctuation::LeftSingleQuote => 0,
            SmartPunctuation::RightSingleQuote => 1,
            SmartPunctuation::LeftDoubleQuote => 2,
            SmartPunctuation::RightDoubleQuote => 3,
            SmartPunctuation::Ellipses => 4,
            SmartPunctuation::EmDash => 5,
            SmartPunctuation::EnDash => 6,
        }
    }
}

/// Whether a generic container was written as a TAG or as a DIRECTIVE — the
/// axis [`DirectiveForm`] is repeatedly mistaken for and cannot answer.
///
/// `DirectiveForm` is a spelling hint: which of a directive-capable format's
/// three spellings fits this node. Twig's HTML parser sets one on `<div>` and
/// `<span>` because those are the two tags djot and Markdown have generic
/// spellings for — so a `<div>` and a Markdown `:::div` produce nodes that
/// agree on kind, name and form alike. Until this axis existed, the only way
/// to separate them was to re-read the source bytes under the node's span and
/// look at the first character.
///
/// Read-only: it records what a parser saw, and there is nothing to set on the
/// build path.
/// One thing a conversion would silently lose. See [`Document::diagnostics`].
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Warning {
    pub fidelity: Fidelity,
    /// A slash-separated child-index trail from the document root (`"1/0/2"`),
    /// EMPTY for the root itself.
    ///
    /// A path and not a byte span, because the output being described does not
    /// exist yet — there is nothing in it to point at. Resolve it against the
    /// tree you already have.
    pub path: String,
    /// The affected node's kind, with family members reported as themselves
    /// ([`Kind::Superscript`], not an `inline_mark`).
    pub kind: Kind,
}

/// How much of a node survives a conversion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Fidelity {
    /// Something is emitted, but the target's parser reads it back as a
    /// DIFFERENT kind. The content survives; its meaning does not.
    Degraded,
    /// Nothing is emitted at all: the node and its subtree leave no trace.
    Dropped,
}

impl Fidelity {
    /// Only the lossy codes have a variant — a faithful node is never reported
    /// as a warning, so there is nothing for it to map to. An unknown code
    /// reads as [`Fidelity::Degraded`], the weaker of the two claims.
    fn from_c(v: c_int) -> Self {
        match v {
            ffi::TWIG_FIDELITY_DROPPED => Fidelity::Dropped,
            _ => Fidelity::Degraded,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum ContainerOrigin {
    /// An HTML or XML tag: `<div>`, `<video>`, `<svg:rect>`.
    Element,
    /// A lightweight-markup generic container: a djot fenced div or bracketed
    /// span, a Markdown `:::note` / `::name` / `:name`, an rST `.. note::`, an
    /// AsciiDoc delimited block.
    Directive,
}

impl ContainerOrigin {
    /// `None` for [`ffi::TWIG_CONTAINER_ORIGIN_NONE`] (nothing recorded an
    /// origin) or any code this binding doesn't know.
    fn from_c(v: c_int) -> Option<Self> {
        match v {
            ffi::TWIG_CONTAINER_ORIGIN_ELEMENT => Some(ContainerOrigin::Element),
            ffi::TWIG_CONTAINER_ORIGIN_DIRECTIVE => Some(ContainerOrigin::Directive),
            _ => None,
        }
    }
}

/// The surface form of a generic directive for [`Builder::add_directive`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DirectiveForm {
    Text,
    Leaf,
    Container,
}

impl DirectiveForm {
    fn to_c(self) -> c_int {
        match self {
            DirectiveForm::Text => ffi::TWIG_DIRECTIVE_TEXT,
            DirectiveForm::Leaf => ffi::TWIG_DIRECTIVE_LEAF,
            DirectiveForm::Container => ffi::TWIG_DIRECTIVE_CONTAINER,
        }
    }

    /// The inverse of [`DirectiveForm::to_c`]; `None` for
    /// [`ffi::TWIG_DIRECTIVE_NONE`] (the node isn't a directive) or any code
    /// this binding doesn't know.
    fn from_c(v: c_int) -> Option<Self> {
        match v {
            ffi::TWIG_DIRECTIVE_TEXT => Some(DirectiveForm::Text),
            ffi::TWIG_DIRECTIVE_LEAF => Some(DirectiveForm::Leaf),
            ffi::TWIG_DIRECTIVE_CONTAINER => Some(DirectiveForm::Container),
            _ => None,
        }
    }
}

/// Decompose an optional string into `(ptr, len, has)` for the C ABI's
/// `(ptr, len, has_*)` optional-string triples. The pointer borrows `s` and is
/// only used within the same call.
fn opt_str(s: Option<&str>) -> (*const u8, usize, c_int) {
    match s {
        Some(x) => (x.as_ptr(), x.len(), 1),
        None => (std::ptr::null(), 0, 0),
    }
}

/// Programmatic construction of a document — the write-path mirror of
/// [`Document::parse`]. Build the tree bottom-up (add children, then the
/// container, wiring them with [`Builder::set_children`]); every `add*` method
/// returns the new node's [`NodeId`]. Then render, serialize, query, or dump the
/// subtree rooted at any id, on demand, without consuming the builder. All input
/// strings are copied, so caller buffers need not outlive a call.
#[derive(Debug)]
pub struct Builder {
    raw: NonNull<ffi::TwigBuilder>,
}

impl Builder {
    /// Create an empty builder.
    pub fn new() -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let status = unsafe { ffi::twig_builder_create(&mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    /// Add a void-payload node (attach children later with
    /// [`Builder::set_children`]).
    pub fn add(&mut self, kind: VoidKind) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add(b, kind.to_c(), out) })
    }

    /// Add a single-string-payload node (a `str`, code span, url, comment, …).
    pub fn add_text(&mut self, kind: TextKind, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_text(b, kind.to_c(), text.as_ptr(), text.len(), out)
        })
    }

    /// Add a heading of the given level (attach its inline children afterward).
    pub fn add_heading(&mut self, level: u32) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_heading(b, level, out) })
    }

    /// Add a code block, with an optional info-string language.
    pub fn add_code_block(&mut self, lang: Option<&str>, text: &str) -> Result<NodeId, Error> {
        let (lp, ll, has) = opt_str(lang);
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_code_block(b, lp, ll, has, text.as_ptr(), text.len(), out)
        })
    }

    /// Add a raw block targeting `format` (e.g. `"html"`).
    pub fn add_raw_block(&mut self, format: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_raw_block(
                b,
                format.as_ptr(),
                format.len(),
                text.as_ptr(),
                text.len(),
                out,
            )
        })
    }

    /// Add a document-metadata block written in config language `lang`.
    pub fn add_metadata(&mut self, lang: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_metadata(
                b,
                lang.as_ptr(),
                lang.len(),
                text.as_ptr(),
                text.len(),
                out,
            )
        })
    }

    /// Add a raw inline targeting `format`.
    pub fn add_raw_inline(&mut self, format: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_raw_inline(
                b,
                format.as_ptr(),
                format.len(),
                text.as_ptr(),
                text.len(),
                out,
            )
        })
    }

    /// Add a smart-punctuation node of `kind`. `text` is accepted for ABI
    /// compatibility but ignored by the underlying builder: the node's
    /// spelling is always the canonical one for `kind` (e.g. `"---"` for an
    /// em dash), never a caller-supplied one.
    pub fn add_smart_punctuation(
        &mut self,
        kind: SmartPunctuation,
        text: &str,
    ) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_smart_punctuation(b, kind.to_c(), text.as_ptr(), text.len(), out)
        })
    }

    /// Add a link with an optional destination and/or reference label (attach
    /// the link text as children).
    pub fn add_link(
        &mut self,
        destination: Option<&str>,
        reference: Option<&str>,
    ) -> Result<NodeId, Error> {
        let (dp, dl, hd) = opt_str(destination);
        let (rp, rl, hr) = opt_str(reference);
        self.emit(|b, out| unsafe { ffi::twig_builder_add_link(b, dp, dl, hd, rp, rl, hr, out) })
    }

    /// Add an image — like [`Builder::add_link`], but children are the alt text.
    pub fn add_image(
        &mut self,
        destination: Option<&str>,
        reference: Option<&str>,
    ) -> Result<NodeId, Error> {
        let (dp, dl, hd) = opt_str(destination);
        let (rp, rl, hr) = opt_str(reference);
        self.emit(|b, out| unsafe { ffi::twig_builder_add_image(b, dp, dl, hd, rp, rl, hr, out) })
    }

    /// Add a generic directive of the given form and name.
    pub fn add_directive(&mut self, form: DirectiveForm, name: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_directive(b, form.to_c(), name.as_ptr(), name.len(), out)
        })
    }

    /// Add a generic named element (the escape hatch for HTML/XML tags).
    pub fn add_element(&mut self, name: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_element(b, name.as_ptr(), name.len(), out)
        })
    }

    /// Add an XML processing instruction (`<?target data?>`).
    pub fn add_processing_instruction(
        &mut self,
        target: &str,
        data: &str,
    ) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_processing_instruction(
                b,
                target.as_ptr(),
                target.len(),
                data.as_ptr(),
                data.len(),
                out,
            )
        })
    }

    /// Add a footnote definition with the given label.
    pub fn add_footnote(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_footnote(b, label.as_ptr(), label.len(), out)
        })
    }

    /// Add a citation definition — reStructuredText's `.. [CIT2002] ...`. Holds
    /// blocks, like a footnote; the two differ in which name registry resolves
    /// them, which is why this is its own call and not a flag on
    /// [`Builder::add_footnote`].
    pub fn add_citation(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_citation(b, label.as_ptr(), label.len(), out)
        })
    }

    /// Add a substitution definition — reStructuredText's
    /// `.. |name| image:: p.png`. Unlike a footnote or citation, its children
    /// are INLINE nodes.
    pub fn add_substitution(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_substitution(b, label.as_ptr(), label.len(), out)
        })
    }

    /// Add a link/image reference definition (`label` → `destination`).
    pub fn add_reference(&mut self, label: &str, destination: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_reference(
                b,
                label.as_ptr(),
                label.len(),
                destination.as_ptr(),
                destination.len(),
                out,
            )
        })
    }

    /// Add a bullet list.
    pub fn add_bullet_list(&mut self, style: BulletStyle, tight: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_bullet_list(b, style.to_c(), tight as c_int, out)
        })
    }

    /// Add an ordered list, with an optional explicit start number.
    pub fn add_ordered_list(
        &mut self,
        numbering: OrderedNumbering,
        delim: OrderedDelim,
        tight: bool,
        start: Option<u32>,
    ) -> Result<NodeId, Error> {
        let (start_val, has_start) = match start {
            Some(s) => (s, 1),
            None => (0, 0),
        };
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_ordered_list(
                b,
                numbering.to_c(),
                delim.to_c(),
                tight as c_int,
                start_val,
                has_start,
                out,
            )
        })
    }

    /// Add a task list.
    pub fn add_task_list(&mut self, tight: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_task_list(b, tight as c_int, out) })
    }

    /// Add a task-list item with the given checkbox state.
    pub fn add_task_list_item(&mut self, checked: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_task_list_item(b, checked as c_int, out)
        })
    }

    /// Add a table row (`head` marks a header row).
    pub fn add_row(&mut self, head: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_row(b, head as c_int, out) })
    }

    /// Add a one-square table cell (`head` marks a header cell).
    pub fn add_cell(&mut self, head: bool, alignment: Alignment) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_cell(b, head as c_int, alignment.to_c(), out)
        })
    }

    /// Add a table cell occupying `colspan` columns and `rowspan` rows — a grid
    /// table's merged cell. Both must be at least 1
    /// ([`Error::InvalidArgument`] otherwise); `(1, 1)` is exactly
    /// [`Builder::add_cell`]. Read back with [`Document::cell_extent`].
    pub fn add_cell_spanning(
        &mut self,
        head: bool,
        alignment: Alignment,
        colspan: u32,
        rowspan: u32,
    ) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_cell_spanning(
                b,
                head as c_int,
                alignment.to_c(),
                colspan,
                rowspan,
                out,
            )
        })
    }

    /// Set `parent`'s children to `children` (in order), replacing any it had.
    /// Each child id should appear in exactly one `set_children` call.
    pub fn set_children(&mut self, parent: NodeId, children: &[NodeId]) -> Result<(), Error> {
        let ids: Vec<u32> = children.iter().map(|n| n.0).collect();
        let status = unsafe {
            ffi::twig_builder_set_children(self.raw.as_ptr(), parent.0, ids.as_ptr(), ids.len())
        };
        Error::from_status(status)
    }

    /// Attach `{...}` attributes to `id` (`(key, Some(value))`, or
    /// `(key, None)` for a bare attribute), replacing any it had. An empty slice
    /// clears them.
    pub fn set_attrs(&mut self, id: NodeId, attrs: &[(&str, Option<&str>)]) -> Result<(), Error> {
        let kvs: Vec<ffi::TwigKeyVal> = attrs
            .iter()
            .map(|(k, v)| ffi::TwigKeyVal {
                key: k.as_ptr(),
                key_len: k.len(),
                value: v.map_or(std::ptr::null(), |s| s.as_ptr()),
                value_len: v.map_or(0, |s| s.len()),
            })
            .collect();
        let status = unsafe {
            ffi::twig_builder_set_attrs(self.raw.as_ptr(), id.0, kvs.as_ptr(), kvs.len())
        };
        Error::from_status(status)
    }

    /// Render the subtree rooted at `root` to HTML (generic whole-vocabulary
    /// printer — a built tree has no djot/Markdown side tables).
    pub fn render_html(&mut self, root: NodeId) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_builder_render_html(raw, root.0, ptr, len) })
    }

    /// Serialize the subtree rooted at `root` to `target`'s syntax. Returns
    /// [`Error::UnsupportedFormat`] when the target can't represent the built
    /// tree (e.g. semantic kinds into XML).
    ///
    /// Prefer this over [`Builder::serialize`], for the reason
    /// [`Document::serialize_to`] gives.
    pub fn serialize_to(&mut self, root: NodeId, target: Target) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        let ffi_target: ffi::TwigFormat = target.into();
        collect_bytes(|ptr, len| unsafe {
            ffi::twig_builder_serialize(raw, root.0, ffi_target as i32, ptr, len)
        })
    }

    /// Serialize the subtree rooted at `root` to `format`'s source syntax.
    ///
    /// The original spelling of [`Builder::serialize_to`], kept for
    /// compatibility and defined in terms of it.
    pub fn serialize(&mut self, root: NodeId, format: Format) -> Result<Vec<u8>, Error> {
        self.serialize_to(root, format.into())
    }

    /// Encode the subtree rooted at `root` as pretty-printed JSON.
    pub fn ast_json(&mut self, root: NodeId) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_builder_ast_json(raw, root.0, ptr, len) })
    }

    /// Resolve a selector against the subtree rooted at `root` (same grammar as
    /// [`Document::query`]).
    pub fn query(&mut self, root: NodeId, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        let raw = self.raw.as_ptr();
        collect_matches(|ptr, len| unsafe {
            ffi::twig_builder_query(raw, root.0, selector.as_ptr(), selector.len(), ptr, len)
        })
    }

    /// Shared plumbing for the `add*` constructors: run `call` (which writes the
    /// new node's id) and wrap the result.
    fn emit(
        &mut self,
        call: impl FnOnce(*mut ffi::TwigBuilder, *mut u32) -> ffi::TwigStatus,
    ) -> Result<NodeId, Error> {
        let mut id: u32 = 0;
        let status = call(self.raw.as_ptr(), &mut id);
        Error::from_status(status)?;
        Ok(NodeId(id))
    }
}

impl Drop for Builder {
    fn drop(&mut self) {
        unsafe { ffi::twig_builder_destroy(self.raw.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_version_matches() {
        // The linked library must speak the exact ABI layout this crate's
        // `#[repr(C)]` mirrors assume. If this fails, the Zig `TWIG_ABI_VERSION`
        // was bumped without updating `ffi::TWIG_ABI_VERSION` (and the mirrors).
        assert_eq!(abi_version(), ffi::TWIG_ABI_VERSION);
    }

    #[test]
    fn parses_and_renders_markdown_html() {
        let mut doc = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");
        let html = doc.render_html().expect("render html");
        assert_eq!(String::from_utf8_lossy(&html), "<h1>hi</h1>\n");
    }

    #[test]
    fn parses_html_input() {
        let mut doc = Document::parse_str("<p>hi</p>", Format::Html).expect("parse html");
        let html = doc.render_html().expect("render html");
        assert!(String::from_utf8_lossy(&html).contains("hi"));
    }

    #[test]
    fn parses_asciidoc_and_refuses_to_write_it() {
        let mut doc = Document::parse_str("= Title\n\nsome *bold* text\n", Format::Asciidoc)
            .expect("parse asciidoc");
        let html = String::from_utf8_lossy(&doc.render_html().expect("render html")).into_owned();
        assert!(html.contains("<h1>Title</h1>"), "got {html:?}");
        assert!(html.contains("<strong>bold</strong>"), "got {html:?}");

        // Nameable as a target, and always a runtime refusal: AsciiDoc has a
        // parser and no serializer. This is the case `Target`'s totality
        // exists for — the answer is `UnsupportedFormat`, not "unnameable".
        assert_eq!(
            doc.serialize_to(Target::Asciidoc),
            Err(Error::UnsupportedFormat)
        );
        assert_eq!(Target::from(Format::Asciidoc), Target::Asciidoc);
        assert_eq!(Target::Asciidoc.as_format(), Some(Format::Asciidoc));
    }

    #[test]
    fn serialize_round_trips_and_cross_converts() {
        let mut doc = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");

        let canonical = doc.serialize(Format::Markdown).expect("serialize markdown");
        assert!(String::from_utf8_lossy(&canonical).contains("# hi"));

        // Cross-format Markdown -> XML has no serializer.
        assert_eq!(doc.serialize(Format::Xml), Err(Error::UnsupportedFormat));
    }

    #[test]
    fn serialize_markdown_to_djot() {
        let mut doc =
            Document::parse_str("This is *markdown*.\n", Format::Markdown).expect("parse markdown");
        let djot = doc.serialize(Format::Djot).expect("serialize djot");
        assert!(String::from_utf8_lossy(&djot).contains("_markdown_"));
    }

    #[test]
    fn serialize_to_takes_the_output_axis() {
        let mut doc =
            Document::parse_str("This is *markdown*.\n", Format::Markdown).expect("parse markdown");

        let djot = doc.serialize_to(Target::Djot).expect("serialize djot");
        assert!(String::from_utf8_lossy(&djot).contains("_markdown_"));

        // The capability answer is the target's, not the input's: converting
        // INTO XML has no serializer regardless of what parsed the document.
        assert_eq!(doc.serialize_to(Target::Xml), Err(Error::UnsupportedFormat));
    }

    #[test]
    fn serialize_and_serialize_to_agree() {
        // `serialize` is defined in terms of `serialize_to`, so the older
        // spelling stays exact rather than merely similar.
        let mut a = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");
        let mut b = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");
        for format in [Format::Markdown, Format::Djot, Format::Html] {
            assert_eq!(a.serialize(format), b.serialize_to(Target::from(format)));
        }
    }

    #[test]
    fn every_format_is_a_target_that_names_it_back() {
        // The subset invariant the Zig `targets` table enforces, restated at
        // this layer: `Target::from` is total, and `as_format` round-trips it.
        for format in [Format::Djot, Format::Markdown, Format::Xml, Format::Html] {
            assert_eq!(Target::from(format).as_format(), Some(format));
        }
    }

    #[test]
    fn ast_json_dumps_the_tree() {
        let mut doc = Document::parse_str("hello\n", Format::Djot).expect("parse djot");
        let json = doc.ast_json().expect("ast json");
        assert!(String::from_utf8_lossy(&json).contains("\"kind\": \"doc\""));
    }

    #[test]
    fn query_finds_nodes_by_selector() {
        let source = "# One\n\n## Two\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");
        let matches = doc.query("heading").expect("query");

        assert_eq!(matches.len(), 2);
        for m in &matches {
            assert_eq!(m.kind, Kind::Heading);
            assert!(m.span.start < m.span.end);
        }
    }

    #[test]
    fn query_recovers_code_spans() {
        let source = "prose `code` more prose\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");
        let matches = doc.query("verbatim").expect("query");

        assert_eq!(matches.len(), 1);
        assert_eq!(&source[matches[0].span.clone()], "`code`");
    }

    #[test]
    fn document_span_accessors_read_by_node_id() {
        let source = "# hi\n\ntext\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");
        let heading = doc.query("heading").expect("query").pop().expect("heading");

        assert_eq!(
            doc.span(NodeId(heading.node_id)).expect("span"),
            heading.span
        );
        assert_eq!(
            doc.content_span(NodeId(heading.node_id))
                .expect("content span"),
            heading.content_span
        );
        assert_eq!(doc.span(NodeId(u32::MAX)), Err(Error::InvalidArgument));
    }

    #[test]
    fn document_walks_its_tree_without_an_editor() {
        let source = "# hi\n\ntext\n";
        let mut doc = Document::parse_str(source, Format::Markdown).expect("parse markdown");

        let nodes = doc.nodes().expect("nodes");
        assert!(nodes.len() >= 3);
        for (i, n) in nodes.iter().enumerate() {
            assert_eq!(n.id, NodeId(i as u32));
        }

        let kids = doc.children(None).expect("children");
        assert_eq!(kids.len(), 2);
        assert_eq!(kids[0].kind, Kind::Heading);

        let sub = doc.subtree(NodeId(kids[0].node_id)).expect("subtree");
        assert_eq!(sub[0].id, NodeId(0));
        assert_eq!(sub[0].parent, None);
        assert_eq!(sub[0].span, kids[0].span);

        let hit = doc.node_at(2).expect("node_at").expect("a node at 2");
        let chain = doc.ancestors_at(2).expect("ancestors");
        assert_eq!(chain.last().expect("deepest").node_id, hit.node_id);
        assert_eq!(chain[0].kind, Kind::Doc);

        assert_eq!(doc.subtree(NodeId(u32::MAX)), Err(Error::InvalidArgument));
    }

    #[test]
    fn editor_document_view_reads_the_live_tree() {
        let mut ed = Editor::new_str("# one\n\ntwo\n", Format::Markdown).expect("editor");

        {
            let mut view = ed.document().expect("view");
            let kids = view.children(None).expect("children");
            assert_eq!(kids.len(), 2);
            assert_eq!(kids[0].kind, Kind::Heading);
            assert_eq!(view.span(NodeId(kids[0].node_id)).expect("span"), 0..5);
            // The two the view can't serve.
            assert_eq!(view.render_html(), Err(Error::UnsupportedFormat));
            assert_eq!(
                view.serialize(Format::Markdown),
                Err(Error::UnsupportedFormat)
            );
        }

        ed.replace("0", "# one and a half").expect("replace");
        let mut view = ed.document().expect("view");
        let kids = view.children(None).expect("children");
        assert_eq!(view.span(NodeId(kids[0].node_id)).expect("span"), 0..16);
    }

    #[test]
    fn query_rejects_a_malformed_selector() {
        let mut doc = Document::parse_str("hi\n", Format::Markdown).expect("parse markdown");
        assert_eq!(doc.query("list >"), Err(Error::InvalidArgument));
    }

    #[test]
    fn editor_edits_by_index_path() {
        let mut ed = Editor::new_str("<a><b>hi</b></a>", Format::Xml).expect("editor");
        ed.replace_content("0.0", "bye").expect("replace_content");
        assert_eq!(ed.source_str().expect("source"), "<a><b>bye</b></a>");
    }

    #[test]
    fn flat_nodes_expose_element_name_and_attrs() {
        // A `<picture>` with a theme-switching `<source>`: the dark alternative
        // lives only in the `<source>`'s attributes, which the snapshot now
        // surfaces (both `<picture>` and `<source>` report `kind == "container"`).
        let src = "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"d.svg\"><img src=\"l.svg\" alt=\"x\"></picture>\n";
        let mut ed = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions {
                html_elements: true,
                ..Default::default()
            },
        )
        .expect("editor");
        let nodes = ed.nodes().expect("nodes");

        let source = nodes
            .iter()
            .find(|n| n.name.as_deref() == Some("source"))
            .expect("a <source> element node");
        assert_eq!(
            source.attrs,
            vec![
                (
                    "media".to_string(),
                    Some("(prefers-color-scheme: dark)".to_string())
                ),
                ("srcset".to_string(), Some("d.svg".to_string())),
            ]
        );

        // The `<img>` fallback stays an `image` node (no element name), and its
        // `src` is the ordinary `destination`.
        let img = nodes
            .iter()
            .find(|n| n.kind == Kind::Image)
            .expect("an image node");
        assert!(img.name.is_none());
        assert_eq!(img.destination.as_deref(), Some("l.svg"));

        // A semantic node carries neither an element name nor attributes.
        let picture_kids_str = nodes.iter().find(|n| n.kind == Kind::Str);
        if let Some(s) = picture_kids_str {
            assert!(s.name.is_none() && s.attrs.is_empty());
        }
    }

    #[test]
    fn definitions_finds_what_a_walk_from_the_root_cannot() {
        // Both definitions are resolved by label, so neither is anybody's
        // child: the document root's subtree contains the paragraph and
        // nothing else.
        let mut doc = Document::parse_str(
            "text[^1] [x][a]\n\n[^1]: note\n\n[a]: /u\n",
            Format::Markdown,
        )
        .expect("parse markdown");

        let defs = doc.definitions().expect("definitions");
        let mut kinds: Vec<Kind> = defs.iter().map(|m| m.kind.clone()).collect();
        kinds.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        assert_eq!(kinds, vec![Kind::Footnote, Kind::Reference]);

        // None of them is reachable from the root — the property that made a
        // whole-arena rescan the only way to find them.
        let all = doc.nodes().expect("nodes");
        let root = all
            .iter()
            .find(|n| n.kind == Kind::Doc)
            .expect("a doc root");
        let mut reachable = vec![root.id];
        let mut i = 0;
        while i < reachable.len() {
            let n = &all[reachable[i].0 as usize];
            let mut c = n.first_child;
            while let Some(cid) = c {
                reachable.push(cid);
                c = all[cid.0 as usize].next_sibling;
            }
            i += 1;
        }
        for d in &defs {
            assert!(
                !reachable.contains(&NodeId(d.node_id)),
                "{} should be unreachable from the root",
                d.kind
            );
        }

        // A document that defines nothing gets an empty vec, not an error.
        let mut plain = Document::parse_str("just text\n", Format::Markdown).expect("parse");
        assert_eq!(plain.definitions().expect("definitions"), Vec::new());
    }

    #[test]
    fn kind_round_trips_through_its_published_name() {
        // `as_str` is the wire vocabulary and `from` is its inverse, so any
        // variant whose spelling drifts from the C ABI's fails here rather
        // than quietly becoming `Other`.
        for k in [
            Kind::Doc,
            Kind::Para,
            Kind::Heading,
            Kind::Container,
            Kind::TaskListItem,
            Kind::Superscript,
            Kind::FootnoteReference,
            Kind::ProcessingInstruction,
            Kind::Cdata,
        ] {
            assert_eq!(Kind::from(k.as_str()), k, "{k} did not round-trip");
            assert!(!k.is_unknown());
        }
    }

    #[test]
    fn an_unknown_kind_name_is_carried_rather_than_lost() {
        // A newer library against an older binding. The node is still a node,
        // and a renderer that passes it through unchanged should be able to.
        let k = Kind::from("some_future_kind");
        assert!(k.is_unknown());
        assert_eq!(k.as_str(), "some_future_kind");
        assert_eq!(k, Kind::Other("some_future_kind".to_string()));
    }

    #[test]
    fn every_kind_the_library_publishes_has_a_variant() {
        // Walks documents covering every corner of the vocabulary this crate
        // can reach from Rust and asserts nothing arrives as `Other`. If twig
        // adds a kind, or renames one, this fails — which is the whole reason
        // the enum is here instead of a `String`.
        let cases: &[(&str, Format, MarkdownExtensions)] = &[
            (
                "# h\n\npara *emph* **strong** `code`\n\n- a\n- b\n\n1. c\n\n> q\n\n---\n\n```zig\nx\n```\n",
                Format::Markdown,
                MarkdownExtensions {
                    directives: false,
                    math: false,
                    html_elements: false,
                },
            ),
            (
                "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n- [ ] task\n- [x] done\n\nfoot[^1]\n\n[^1]: note\n\n[l]: /u\n\n[x][l]\n",
                Format::Markdown,
                MarkdownExtensions::default(),
            ),
            (
                ":::note\nbody\n:::\n\n:role[x]\n\n$a+b$\n",
                Format::Markdown,
                MarkdownExtensions {
                    directives: true,
                    math: true,
                    html_elements: false,
                },
            ),
            (
                "a^b^ c~d~ {=e=} {+f+} {-g-} 'q' \"dq\"\n\n![i](/p)\n\n<https://e.com>\n",
                Format::Djot,
                MarkdownExtensions::default(),
            ),
            (
                "<!-- c --><!DOCTYPE html><video controls><p>x</p></video>",
                Format::Html,
                MarkdownExtensions::default(),
            ),
        ];

        let mut unknown: Vec<String> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        for (src, format, ext) in cases {
            let mut ed = Editor::new_ext(src.as_bytes(), *format, *ext).expect("editor");
            for n in ed.nodes().expect("nodes") {
                if n.kind.is_unknown() {
                    unknown.push(n.kind.as_str().to_string());
                }
                seen.push(n.kind.as_str().to_string());
            }
        }
        unknown.sort();
        unknown.dedup();
        assert!(unknown.is_empty(), "kinds with no variant: {unknown:?}");

        // And the sweep really swept: without this the assertion above passes
        // just as happily on an empty walk.
        seen.sort();
        seen.dedup();
        assert!(
            seen.len() >= 30,
            "only {} distinct kinds reached: {seen:?}",
            seen.len()
        );
    }

    #[test]
    fn diagnostics_report_what_a_conversion_would_lose() {
        // A djot superscript has no Markdown spelling. The two answers below
        // are for the SAME document — fidelity is a property of the
        // (document, target) pair, which is why it is asked per target.
        let mut doc = Document::parse_str("a^b^ c\n", Format::Djot).expect("parse djot");

        let to_md = doc
            .diagnostics(Target::Markdown)
            .expect("markdown diagnostics");
        assert_eq!(
            to_md,
            vec![Warning {
                fidelity: Fidelity::Degraded,
                path: "0/1".to_string(),
                kind: Kind::Superscript,
            }]
        );

        // Lossless to djot: an empty vec is a real answer, not a failure.
        assert_eq!(
            doc.diagnostics(Target::Djot).expect("djot diagnostics"),
            Vec::new()
        );
    }

    #[test]
    fn diagnostics_separate_a_droppable_node_from_a_degradable_one() {
        // An HTML comment converted to djot leaves NOTHING behind — a
        // different and worse answer than "comes back as something else", and
        // the distinction a consumer needs to decide whether to warn or refuse.
        let mut doc =
            Document::parse_str("<p>hi</p><!-- secret -->", Format::Html).expect("parse html");
        let warnings = doc.diagnostics(Target::Djot).expect("djot diagnostics");
        let comment = warnings
            .iter()
            .find(|w| w.kind == Kind::Comment)
            .expect("a warning about the comment");
        assert_eq!(comment.fidelity, Fidelity::Dropped);
    }

    #[test]
    fn diagnostics_refuse_a_target_with_no_serializer() {
        // "This target cannot be written" is a capability answer, not a
        // per-node diagnosis of every node in the document.
        let mut doc = Document::parse_str("# hi\n", Format::Markdown).expect("parse markdown");
        assert_eq!(doc.diagnostics(Target::Xml), Err(Error::UnsupportedFormat));
        assert_eq!(
            doc.diagnostics(Target::Asciidoc),
            Err(Error::UnsupportedFormat)
        );
    }

    #[test]
    fn diagnostics_flag_a_header_less_table_and_leave_a_headed_one_alone() {
        // The instance-level answer, and the one a consumer cannot reach by
        // looking at kinds: both documents contain a `table`, and only one of
        // them costs anything to convert. GFM's delimiter row is mandatory, so
        // the header-less table gets an empty header synthesized above it.
        let mut headed = Document::parse_str(
            "<table><tr><th>H</th></tr><tr><td>a</td></tr></table>",
            Format::Html,
        )
        .expect("parse headed table");
        assert!(
            headed
                .diagnostics(Target::Markdown)
                .expect("diagnostics")
                .iter()
                .all(|w| w.kind != Kind::Table)
        );

        let mut headless = Document::parse_str("<table><tr><td>a</td></tr></table>", Format::Html)
            .expect("parse header-less table");
        let table_warning = headless
            .diagnostics(Target::Markdown)
            .expect("diagnostics")
            .into_iter()
            .find(|w| w.kind == Kind::Table)
            .expect("a warning about the table");
        assert_eq!(table_warning.fidelity, Fidelity::Degraded);
    }

    #[test]
    fn container_origin_separates_a_div_from_a_div() {
        // The collision this field exists for. These two documents produce
        // container nodes that agree on `kind`, on `name` AND on
        // `directive_form` — so a consumer holding one of them could not say
        // which syntax the author wrote without re-reading the source bytes.
        let mut html =
            Editor::new("<div>hi</div>\n".as_bytes(), Format::Html).expect("html editor");
        let mut md = Editor::new_ext(
            ":::div\nhi\n:::\n".as_bytes(),
            Format::Markdown,
            MarkdownExtensions {
                directives: true,
                ..Default::default()
            },
        )
        .expect("markdown editor");

        let html_nodes = html.nodes().expect("html nodes");
        let md_nodes = md.nodes().expect("markdown nodes");
        let tag = html_nodes
            .iter()
            .find(|n| n.name.as_deref() == Some("div"))
            .expect("a <div> container");
        let directive = md_nodes
            .iter()
            .find(|n| n.name.as_deref() == Some("div"))
            .expect("a :::div container");

        // Indistinguishable on every field that predates `origin`.
        assert_eq!(tag.kind, directive.kind);
        assert_eq!(tag.name, directive.name);
        assert_eq!(tag.directive_form, directive.directive_form);
        assert_eq!(tag.directive_form, Some(DirectiveForm::Container));

        // And decidable now.
        assert_eq!(tag.origin, Some(ContainerOrigin::Element));
        assert_eq!(directive.origin, Some(ContainerOrigin::Directive));
    }

    /// Parse `src` as both authorable formats and run `check` over each — the
    /// shape every test below wants, because the point of these two APIs is
    /// that a consumer cannot tell which parser produced the tree.
    fn for_both_formats(src: &str, check: impl Fn(&mut Document, Format)) {
        for format in [Format::Markdown, Format::Djot] {
            let mut doc = Document::parse(src.as_bytes(), format).expect("parse");
            check(&mut doc, format);
        }
    }

    #[test]
    fn marker_span_is_what_a_rich_view_hides() {
        for_both_formats("> - [x] done\n", |doc, format| {
            let nodes = doc.nodes().expect("nodes");
            let quote = nodes
                .iter()
                .find(|n| n.kind == Kind::BlockQuote)
                .expect("a block quote");
            let item = nodes
                .iter()
                .find(|n| n.kind == Kind::TaskListItem)
                .expect("a task item");

            // The quote's `> ` and the item's `- [x] ` — the item's marker
            // takes its checkbox with it, because the rendered view draws a
            // checkbox in PLACE of those bytes rather than beside them.
            assert_eq!(quote.marker_span, Some(0..2), "{format:?}");
            assert_eq!(item.marker_span, Some(2..8), "{format:?}");

            // Not derivable from the other two spans: a marker-prefixed
            // container reports its whole extent as its interior, so the
            // subtraction a caller might reach for yields nothing.
            assert_eq!(quote.content_span, Some(quote.span.clone()), "{format:?}");

            // A paragraph has no marker of its own; only its ancestors do.
            let para = nodes
                .iter()
                .find(|n| n.kind == Kind::Para)
                .expect("a paragraph");
            assert_eq!(para.marker_span, None, "{format:?}");
        });
    }

    #[test]
    fn line_prefix_assembles_every_marker_on_the_line() {
        for_both_formats("> - [x] done\n", |doc, format| {
            // Four nodes' worth of hidden width as one range, which is what a
            // caret stepping over it needs — not a chain to stitch together.
            assert_eq!(doc.line_prefix(9).expect("prefix"), Some(0..8), "{format:?}");
        });
    }

    #[test]
    fn line_prefix_is_none_on_a_continuation_line() {
        // Line two continues the quote but OPENS nothing. `None` is the honest
        // answer: what a continuation line repeats is a different question with
        // a different answer, and guessing it from marker spans is how an
        // editor ends up restructuring a document that never had the shape it
        // inferred.
        for_both_formats("> c\n> d\n", |doc, format| {
            assert_eq!(doc.line_prefix(2).expect("prefix"), Some(0..2), "{format:?}");
            assert_eq!(doc.line_prefix(6).expect("prefix"), None, "{format:?}");
        });
    }

    #[test]
    fn a_caret_at_a_blocks_end_is_in_that_block_in_both_formats() {
        // The divergence this API exists for. Djot ends a paragraph's span
        // AFTER its newline and Markdown BEFORE it, so under half-open
        // containment offset 1 — the caret you get by pressing End on line one,
        // the commonest caret position there is — resolved to the paragraph
        // through Djot and to the root through Markdown.
        for_both_formats("a\n\nb\n", |doc, format| {
            for offset in [0usize, 1, 3, 4] {
                let hit = doc
                    .node_at_caret(offset)
                    .expect("caret hit")
                    .expect("some node");
                assert_eq!(hit.kind, Kind::Str, "{format:?} at {offset}");
            }
            // The blank line between the two blocks belongs to neither, and
            // neither does the empty line after the final newline.
            for offset in [2usize, 5] {
                let hit = doc
                    .node_at_caret(offset)
                    .expect("caret hit")
                    .expect("some node");
                assert_eq!(hit.kind, Kind::Doc, "{format:?} at {offset}");
            }
        });
    }

    #[test]
    fn the_caret_chain_ends_at_the_node_the_scalar_call_returns() {
        for_both_formats("- a\n", |doc, format| {
            let hit = doc.node_at_caret(3).expect("hit").expect("some node");
            let chain = doc.ancestors_at_caret(3).expect("chain");
            assert_eq!(chain.last().map(|m| m.node_id), Some(hit.node_id), "{format:?}");
            // And the chain passes through the item, which is what a gesture
            // scoped to "the block I'm in" needs at a caret sitting at its end.
            assert!(
                chain.iter().any(|m| m.kind == Kind::ListItem),
                "{format:?}: chain should reach the list item"
            );
        });
    }

    #[test]
    fn an_editor_reaches_the_caret_reads_through_its_document_view() {
        // The path an editing host actually takes. These reads are questions
        // about a TREE, not about an editing session, so they live on the
        // document surface and an editor borrows it — no `twig_editor_*` alias
        // to keep in step. See DESIGN.md, "The reads are not editor-specific."
        let mut ed = Editor::new("- a\n".as_bytes(), Format::Markdown).expect("editor");
        let mut view = ed.document().expect("document view");

        assert_eq!(view.line_prefix(3).expect("prefix"), Some(0..2));
        let hit = view.node_at_caret(3).expect("hit").expect("some node");
        assert_eq!(hit.kind, Kind::Str);
    }

    #[test]
    fn container_origin_is_none_for_non_containers() {
        // The field is a container's, so everything else reports `None` rather
        // than a default that would read as a real answer.
        let mut ed = Editor::new("# hi\n\npara\n".as_bytes(), Format::Markdown).expect("editor");
        for n in ed.nodes().expect("nodes") {
            assert_eq!(n.origin, None, "{} should carry no origin", n.kind);
        }
    }

    #[test]
    fn flat_nodes_expose_directive_name_and_form() {
        // All three surface forms report `kind == "container"`, so the snapshot
        // has to carry both halves of a directive's identity: which type it is
        // (`name`) and how it was written (`directive_form`). Without them a
        // renderer can't tell an `::embed` from a `::toc`, nor an inline span
        // from a standalone block.
        let src = ":::note{.warning}\nBody\n:::\n\n::embed{src=\"demo.html\"}\n\nSee :abbr[HTML]{title=\"HyperText\"} inline.\n";
        let mut ed = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions {
                directives: true,
                ..Default::default()
            },
        )
        .expect("editor");
        let nodes = ed.nodes().expect("nodes");

        let forms: Vec<(Option<&str>, Option<DirectiveForm>)> = nodes
            .iter()
            .filter(|n| n.kind == Kind::Container)
            .map(|n| (n.name.as_deref(), n.directive_form))
            .collect();
        assert_eq!(
            forms,
            vec![
                (Some("note"), Some(DirectiveForm::Container)),
                (Some("embed"), Some(DirectiveForm::Leaf)),
                (Some("abbr"), Some(DirectiveForm::Text)),
            ]
        );

        // The attributes still ride the ordinary side-table, and a non-directive
        // reports no form at all.
        let embed = nodes
            .iter()
            .find(|n| n.name.as_deref() == Some("embed"))
            .expect("embed");
        assert_eq!(
            embed.attrs,
            vec![("src".to_string(), Some("demo.html".to_string()))]
        );
        let para = nodes.iter().find(|n| n.kind == Kind::Para).expect("a para");
        assert!(para.directive_form.is_none() && para.name.is_none());
    }

    #[test]
    fn editor_insert_child_and_delete() {
        let mut ed = Editor::new_str("<r><a/><c/></r>", Format::Xml).expect("editor");
        ed.insert_child("0", 1, "<b/>").expect("insert_child");
        assert_eq!(ed.source_str().expect("source"), "<r><a/><b/><c/></r>");
        ed.delete("0.1").expect("delete");
        assert_eq!(ed.source_str().expect("source"), "<r><a/><c/></r>");
    }

    #[test]
    fn editor_edits_by_selector() {
        let mut ed = Editor::new_str("# One\n\n## Two\n", Format::Markdown).expect("editor");
        ed.replace("heading(\"Two\")", "## Renamed")
            .expect("replace");
        assert_eq!(ed.source_str().expect("source"), "# One\n\n## Renamed\n");
    }

    #[test]
    fn editor_locator_errors_are_distinct() {
        let mut ed = Editor::new_str("<r><a/><a/></r>", Format::Xml).expect("editor");
        assert_eq!(ed.replace("0.9", "x"), Err(Error::NotFound));
        assert_eq!(ed.replace("element", "x"), Err(Error::Ambiguous));
        assert_eq!(ed.replace("element(", "x"), Err(Error::InvalidArgument));
        // Untouched by the failed edits.
        assert_eq!(ed.source_str().expect("source"), "<r><a/><a/></r>");
    }

    #[test]
    fn editor_reparse_break_rolls_back() {
        let mut ed = Editor::new_str("<a>ok</a>", Format::Xml).expect("editor");
        assert_eq!(ed.replace_content("0", "<b>"), Err(Error::EditConflict));
        assert_eq!(ed.source_str().expect("source"), "<a>ok</a>");
    }

    #[test]
    fn editor_leaf_content_is_not_editable() {
        let mut ed = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(ed.replace_content("0.0", "x"), Err(Error::NotEditable));
    }

    #[test]
    fn editor_query_reflects_current_tree() {
        let mut ed = Editor::new_str("<r><a/></r>", Format::Xml).expect("editor");
        ed.insert_child("0", 1, "<b/>").expect("insert_child");
        // Root <r> plus <a/> and <b/>.
        assert_eq!(ed.query("element").expect("query").len(), 3);
        let json = ed.ast_json().expect("ast_json");
        assert!(String::from_utf8_lossy(&json).contains("\"kind\": \"doc\""));
    }

    // ── offset-addressed editing & read-back (P0–P3) ────────────────────────

    #[test]
    fn editor_edit_range_types_backspaces_and_reports_change() {
        let mut ed = Editor::new_str("ab\n", Format::Markdown).expect("editor");

        // Type "X" at offset 1 (a zero-width splice = an insertion).
        let c = ed.edit_range(1, 1, "X").expect("edit_range insert");
        assert_eq!(ed.source_str().unwrap(), "aXb\n");
        assert_eq!(c.old, 1..1);
        assert_eq!(c.new, 1..2);
        assert_eq!(c.delta(), 1);

        // Backspace it (delete the "X").
        let c2 = ed.edit_range(1, 2, "").expect("edit_range delete");
        assert_eq!(ed.source_str().unwrap(), "ab\n");
        assert_eq!(c2.old, 1..2);
        assert_eq!(c2.new, 1..1);
        assert_eq!(c2.delta(), -1);
    }

    #[test]
    fn editor_edit_range_rejects_bad_ranges() {
        let mut ed = Editor::new_str("hi\n", Format::Markdown).expect("editor");
        assert_eq!(ed.edit_range(0, 99, "x"), Err(Error::InvalidArgument)); // end past len
        assert_eq!(ed.edit_range(2, 1, "x"), Err(Error::InvalidArgument)); // start > end
        assert_eq!(ed.source_str().unwrap(), "hi\n"); // untouched
    }

    #[test]
    fn editor_last_change_reports_locator_ops_too() {
        let mut ed = Editor::new_str("# One\n\n## Two\n", Format::Markdown).expect("editor");
        assert_eq!(ed.last_change(), None); // nothing edited yet

        ed.replace("heading(\"Two\")", "## Renamed")
            .expect("replace");
        assert_eq!(ed.source_str().unwrap(), "# One\n\n## Renamed\n");
        let c = ed.last_change().expect("a change was recorded");
        // "## Two" occupied [7,13); "## Renamed" (10 bytes) now occupies [7,17).
        assert_eq!(c.old, 7..13);
        assert_eq!(c.new, 7..17);
    }

    #[test]
    fn editor_nodes_is_a_walkable_flat_tree() {
        let mut ed = Editor::new_str("# Hi\n\ntext\n", Format::Markdown).expect("editor");
        let nodes = ed.nodes().expect("nodes");
        assert!(!nodes.is_empty());

        // Dense, index-aligned ids.
        for (i, n) in nodes.iter().enumerate() {
            assert_eq!(n.id, NodeId(i as u32));
        }
        // Exactly one root (no parent), and it's the doc.
        let roots: Vec<_> = nodes.iter().filter(|n| n.parent.is_none()).collect();
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0].kind, Kind::Doc);

        // The heading carries its level; the "Hi" text is reachable as a payload.
        let heading = nodes
            .iter()
            .find(|n| n.kind == Kind::Heading)
            .expect("a heading");
        assert_eq!(heading.level, Some(1));
        assert!(nodes.iter().any(|n| n.text.as_deref() == Some("Hi")));

        // A kind with no row/cell payload reports neither.
        assert_eq!(heading.head, None);
        assert_eq!(heading.alignment, None);

        // Every non-root node's parent links back to a node that lists it as a
        // child (via first_child/next_sibling).
        for n in nodes.iter().filter(|n| n.parent.is_some()) {
            let p = &nodes[n.parent.unwrap().0 as usize];
            let mut kid = p.first_child;
            let mut seen = false;
            while let Some(NodeId(k)) = kid {
                if k == n.id.0 {
                    seen = true;
                    break;
                }
                kid = nodes[k as usize].next_sibling;
            }
            assert!(
                seen,
                "node {:?} not found among its parent's children",
                n.id
            );
        }
    }

    #[test]
    fn editor_child_spans_and_subtree_agree_with_nodes() {
        let src = "# Title\n\nHello **world** and more.\n\n- one\n- two\n";
        let mut ed = Editor::new_str(src, Format::Markdown).expect("editor");
        let all = ed.nodes().expect("nodes");
        let doc = all.iter().find(|n| n.kind == Kind::Doc).expect("doc");

        // child_spans(None) == the doc root's children, same ids/kinds/spans and
        // in the same order.
        let top = ed.child_spans(None).expect("child_spans");
        let mut want = Vec::new();
        let mut c = doc.first_child;
        while let Some(id) = c {
            want.push(id);
            c = all[id.0 as usize].next_sibling;
        }
        assert_eq!(top.len(), want.len(), "top-level count");
        for (m, id) in top.iter().zip(&want) {
            assert_eq!(m.node_id, id.0, "child id");
            assert_eq!(m.kind, all[id.0 as usize].kind, "child kind");
            assert_eq!(m.span, all[id.0 as usize].span, "child span");
        }
        // The span addresses the block as written (absolute offsets).
        assert!(
            src[top[0].span.clone()].starts_with('#'),
            "first block is the heading"
        );

        // child_spans works below the top level too.
        let list = top
            .iter()
            .find(|m| {
                matches!(
                    m.kind,
                    Kind::BulletList | Kind::OrderedList | Kind::TaskList
                )
            })
            .expect("a list");
        let items = ed.child_spans(Some(NodeId(list.node_id))).expect("items");
        assert_eq!(items.len(), 2);
        assert!(
            items.iter().all(|m| m.kind == Kind::ListItem),
            "items: {items:?}"
        );

        // subtree(para) is self-contained, local-indexed, and spans stay absolute.
        let para = top
            .iter()
            .find(|m| m.kind == Kind::Para)
            .expect("a para")
            .node_id;
        let sub = ed.subtree(NodeId(para)).expect("subtree");
        assert_eq!(sub[0].id, NodeId(0), "root is local id 0");
        assert_eq!(sub[0].parent, None, "root has no parent inside the subtree");
        assert_eq!(sub[0].next_sibling, None, "root's sibling is severed");
        assert_eq!(sub[0].kind, Kind::Para);
        for (i, n) in sub.iter().enumerate() {
            assert_eq!(n.id, NodeId(i as u32), "dense local ids");
            for link in [n.parent, n.first_child, n.next_sibling]
                .into_iter()
                .flatten()
            {
                assert!(
                    (link.0 as usize) < sub.len(),
                    "link {link:?} escapes the subtree"
                );
            }
        }
        assert!(
            src[sub[0].span.clone()].starts_with("Hello"),
            "absolute span: {:?}",
            &src[sub[0].span.clone()]
        );

        // Same multiset of node kinds as the paragraph's arena subtree.
        fn arena_kinds(all: &[FlatNode], root: NodeId) -> Vec<Kind> {
            let mut out = Vec::new();
            let mut stack = vec![root];
            while let Some(id) = stack.pop() {
                let n = &all[id.0 as usize];
                out.push(n.kind.clone());
                let mut c = n.first_child;
                while let Some(cid) = c {
                    stack.push(cid);
                    c = all[cid.0 as usize].next_sibling;
                }
            }
            out
        }
        let mut want_kinds = arena_kinds(&all, NodeId(para));
        let mut got_kinds: Vec<Kind> = sub.iter().map(|n| n.kind.clone()).collect();
        // Sorted by NAME: `Kind` is deliberately not `Ord` (there is no
        // meaningful order over a vocabulary), and this only needs a canonical
        // one to compare two multisets.
        want_kinds.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        got_kinds.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        assert_eq!(got_kinds, want_kinds, "subtree kinds match the arena");

        // Out-of-range id is rejected.
        assert!(matches!(
            ed.subtree(NodeId(9999)),
            Err(Error::InvalidArgument)
        ));
    }

    #[test]
    fn flat_nodes_carry_table_head_and_alignment() {
        // The delimiter row (`|:-----|----:|`) is consumed by the parser and has
        // no node of its own, so `alignment` on the cells is the only way a
        // consumer can recover the column alignment from a snapshot.
        let src = "| Name | Qty |\n|:-----|----:|\n| Pear | 3 |\n";
        let mut ed = Editor::new_str(src, Format::Markdown).expect("editor");
        let nodes = ed.nodes().expect("nodes");

        let rows: Vec<_> = nodes.iter().filter(|n| n.kind == Kind::Row).collect();
        assert_eq!(rows.len(), 2, "a header row and one body row");
        assert_eq!(rows[0].head, Some(true), "first row is the header");
        assert_eq!(rows[1].head, Some(false), "second row is a body row");

        let cells: Vec<_> = nodes.iter().filter(|n| n.kind == Kind::Cell).collect();
        assert_eq!(cells.len(), 4);
        // Alignment comes from the delimiter row and applies down the column.
        assert_eq!(cells[0].alignment, Some(Alignment::Left));
        assert_eq!(cells[1].alignment, Some(Alignment::Right));
        assert_eq!(cells[2].alignment, Some(Alignment::Left));
        assert_eq!(cells[3].alignment, Some(Alignment::Right));
        // Header cells are flagged too, not just their row.
        assert_eq!(cells[0].head, Some(true));
        assert_eq!(cells[2].head, Some(false));

        // A table with no alignment spelled out reports Default — a real value,
        // distinct from the None a non-cell reports.
        let mut plain =
            Editor::new_str("| A |\n| --- |\n| b |\n", Format::Markdown).expect("editor");
        let pnodes = plain.nodes().expect("nodes");
        let pcell = pnodes
            .iter()
            .find(|n| n.kind == Kind::Cell)
            .expect("a cell");
        assert_eq!(pcell.alignment, Some(Alignment::Default));
    }

    #[test]
    fn cell_extent_reports_merged_cells_and_nothing_else() {
        let src = "<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td>b</td></tr></table>";
        let mut doc = Document::parse_str(src, Format::Html).expect("parse");
        let cells: Vec<NodeId> = doc
            .nodes()
            .expect("nodes")
            .iter()
            .filter(|n| n.kind == Kind::Cell)
            .map(|n| n.id)
            .collect();
        assert_eq!(cells.len(), 2);
        assert_eq!(doc.cell_extent(cells[0]).expect("extent"), Some((2, 3)));
        // A plain cell is one square — 1, never 0.
        assert_eq!(doc.cell_extent(cells[1]).expect("extent"), Some((1, 1)));

        // A pipe table cannot express a span at all, so every cell is (1, 1).
        let mut pipe =
            Document::parse_str("| a |\n| --- |\n| b |\n", Format::Markdown).expect("parse");
        let pipe_cell = pipe
            .nodes()
            .expect("nodes")
            .iter()
            .find(|n| n.kind == Kind::Cell)
            .expect("a cell")
            .id;
        assert_eq!(pipe.cell_extent(pipe_cell).expect("extent"), Some((1, 1)));

        // Not a cell at all: None, distinct from any extent.
        let root = NodeId(0);
        assert_eq!(pipe.cell_extent(root).expect("extent"), None);
    }

    #[test]
    fn builder_add_cell_spanning_renders_colspan_and_rowspan() {
        let mut b = Builder::new().expect("builder");
        let wide_text = b.add_text(TextKind::Str, "wide").expect("str");
        let wide = b
            .add_cell_spanning(false, Alignment::Default, 2, 3)
            .expect("cell");
        b.set_children(wide, &[wide_text]).expect("children");
        let plain_text = b.add_text(TextKind::Str, "one").expect("str");
        let plain = b.add_cell(false, Alignment::Default).expect("cell");
        b.set_children(plain, &[plain_text]).expect("children");
        let row = b.add_row(false).expect("row");
        b.set_children(row, &[wide, plain]).expect("children");
        let table = b.add(VoidKind::Table).expect("table");
        b.set_children(table, &[row]).expect("children");

        let html = String::from_utf8(b.render_html(table).expect("html")).expect("utf-8");
        assert!(
            html.contains("<td colspan=\"2\" rowspan=\"3\">wide</td>"),
            "{html}"
        );
        // `add_cell` is the one-square case: the default extent writes nothing.
        assert!(html.contains("<td>one</td>"), "{html}");

        // A zero extent is no cell anyone can lay out.
        assert!(matches!(
            b.add_cell_spanning(false, Alignment::Default, 0, 1),
            Err(Error::InvalidArgument)
        ));
    }

    #[test]
    fn editor_node_at_and_ancestors_hit_test_offsets() {
        let mut ed = Editor::new_str("# Hi\n\ntext\n", Format::Markdown).expect("editor");

        // Offset 2 is the "H" of the heading "# Hi" [0,4).
        let m = ed
            .node_at(2)
            .expect("node_at")
            .expect("a node covers offset 2");
        assert!(m.span.contains(&2));

        // The ancestor chain is root-first and ends at the deepest (== node_at).
        let chain = ed.ancestors_at(2).expect("ancestors_at");
        assert!(!chain.is_empty());
        assert_eq!(chain[0].kind, Kind::Doc);
        assert_eq!(chain.last().unwrap().node_id, m.node_id);

        // An out-of-range offset is an error; a gap covers nothing deeper than doc.
        assert_eq!(ed.node_at(999), Err(Error::InvalidArgument));
    }

    // ── range-oriented rich-text ops (P5) ───────────────────────────────────

    #[test]
    fn editor_wrap_and_toggle_inline_round_trip() {
        let mut ed = Editor::new_str("a word b\n", Format::Markdown).expect("editor");

        // Bold "word" [2,6); the Change reports the new "**word**" region.
        let c = ed.wrap_range(2, 6, InlineKind::Strong).expect("wrap");
        assert_eq!(ed.source_str().unwrap(), "a **word** b\n");
        assert_eq!(&ed.source_str().unwrap()[c.new.clone()], "**word**");

        // Toggle it off by selecting the strong node's interior [4,8).
        ed.toggle_inline(4, 8, InlineKind::Strong)
            .expect("toggle off");
        assert_eq!(ed.source_str().unwrap(), "a word b\n");

        // Toggle emphasis on when the range isn't already marked.
        ed.toggle_inline(2, 6, InlineKind::Emph).expect("toggle on");
        assert_eq!(ed.source_str().unwrap(), "a *word* b\n");
    }

    #[test]
    fn editor_inline_kind_support_is_format_specific() {
        // Markdown has no highlight/mark spelling.
        let mut md = Editor::new_str("a word b\n", Format::Markdown).expect("editor");
        assert_eq!(
            md.wrap_range(2, 6, InlineKind::Mark),
            Err(Error::UnsupportedFormat)
        );

        // Djot spells it {=…=}.
        let mut dj = Editor::new_str("a word b\n", Format::Djot).expect("editor");
        dj.wrap_range(2, 6, InlineKind::Mark).expect("djot mark");
        assert_eq!(dj.source_str().unwrap(), "a {=word=} b\n");
    }

    #[test]
    fn editor_toggle_strips_verbatim_via_content_span() {
        let mut ed = Editor::new_str("a `code` b\n", Format::Markdown).expect("editor");
        // The verbatim node [2,8) reports content_span [3,7); toggle peels it.
        ed.toggle_inline(2, 8, InlineKind::Verbatim)
            .expect("toggle code off");
        assert_eq!(ed.source_str().unwrap(), "a code b\n");

        // A multi-backtick span peels BOTH runs via content_span, not by
        // stripping a single delimiter (which would corrupt it to "`x`").
        let mut ed2 = Editor::new_str("a ``x`` b\n", Format::Markdown).expect("editor");
        ed2.toggle_inline(2, 7, InlineKind::Verbatim)
            .expect("toggle multi off");
        assert_eq!(ed2.source_str().unwrap(), "a x b\n");
    }

    #[test]
    fn editor_set_block_switches_para_and_heading_levels() {
        let mut ed = Editor::new_str("Title\n\nbody text\n", Format::Markdown).expect("editor");

        // Paragraph -> H2 (offset 0 is inside "Title").
        ed.set_block(0, BlockKind::Heading(2)).expect("to h2");
        assert_eq!(ed.source_str().unwrap(), "## Title\n\nbody text\n");

        // H2 -> H1 (offset now inside "## Title").
        ed.set_block(3, BlockKind::Heading(1)).expect("to h1");
        assert_eq!(ed.source_str().unwrap(), "# Title\n\nbody text\n");

        // Heading -> paragraph, dropping the marker.
        ed.set_block(2, BlockKind::Paragraph).expect("to para");
        assert_eq!(ed.source_str().unwrap(), "Title\n\nbody text\n");
    }

    #[test]
    fn editor_set_block_rejects_bad_level_and_format() {
        let mut md = Editor::new_str("hi\n", Format::Markdown).expect("editor");
        assert_eq!(
            md.set_block(0, BlockKind::Heading(9)),
            Err(Error::InvalidArgument)
        );

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(
            xml.set_block(1, BlockKind::Heading(1)),
            Err(Error::UnsupportedFormat)
        );
    }

    #[test]
    fn editor_toggle_block_container_round_trips() {
        let mut ed = Editor::new_str("a\n", Format::Djot).expect("editor");

        let c = ed
            .toggle_block_container(0, 1, BlockContainerKind::BlockQuote)
            .expect("quote on");
        assert_eq!(ed.source_str().unwrap(), "> a\n");
        assert_eq!(&ed.source_str().unwrap()[c.new.clone()], "> a\n");

        ed.toggle_block_container(2, 3, BlockContainerKind::BlockQuote)
            .expect("quote off");
        assert_eq!(ed.source_str().unwrap(), "a\n");
    }

    #[test]
    fn editor_toggle_block_container_nests_a_partial_selection() {
        let mut ed = Editor::new_str("> a\n>\n> b\n", Format::Djot).expect("editor");

        // Only the first paragraph is covered, so the quote is not fully
        // selected: nest rather than drag `b` out of the quote too.
        ed.toggle_block_container(2, 3, BlockContainerKind::BlockQuote)
            .expect("nest");
        assert_eq!(ed.source_str().unwrap(), "> > a\n>\n> b\n");

        // Peel the inner level back off, leaving the outer quote intact.
        ed.toggle_block_container(4, 5, BlockContainerKind::BlockQuote)
            .expect("peel");
        assert_eq!(ed.source_str().unwrap(), "> a\n>\n> b\n");
    }

    #[test]
    fn editor_toggle_block_container_numbers_and_converts_lists() {
        let mut ed = Editor::new_str("a\n\nb\n", Format::Djot).expect("editor");

        // Each covered block becomes its own numbered item.
        ed.toggle_block_container(0, 4, BlockContainerKind::OrderedList)
            .expect("ordered on");
        assert_eq!(ed.source_str().unwrap(), "1. a\n\n2. b\n");

        // The other list kind converts in place instead of nesting.
        ed.toggle_block_container(3, 9, BlockContainerKind::BulletList)
            .expect("convert");
        assert_eq!(ed.source_str().unwrap(), "- a\n\n- b\n");
    }

    #[test]
    fn editor_toggle_block_container_rejects_unspellable_format() {
        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(
            xml.toggle_block_container(3, 5, BlockContainerKind::BlockQuote),
            Err(Error::UnsupportedFormat)
        );
    }

    #[test]
    fn editor_insert_link_wraps_and_repoints() {
        let mut ed = Editor::new_str("a word b\n", Format::Djot).expect("editor");

        ed.insert_link(2, 6, "http://x.dev").expect("link");
        assert_eq!(ed.source_str().unwrap(), "a [word](http://x.dev) b\n");

        // A caret inside the existing link re-points it rather than nesting.
        ed.insert_link(3, 7, "http://y.dev").expect("re-point");
        assert_eq!(ed.source_str().unwrap(), "a [word](http://y.dev) b\n");
    }

    #[test]
    fn editor_insert_link_repoints_an_autolink() {
        // The regression: an autolink is a `url`/`email` node whose text IS its
        // destination. Read as ordinary text, a caret inside it spliced a whole
        // new link into the middle of the old URL —
        // `see <https<https://y.dev>://x.dev> ok`.
        for format in [Format::Markdown, Format::Djot] {
            let mut ed = Editor::new_str("see <https://x.dev> ok\n", format).expect("editor");
            ed.insert_link(10, 10, "https://y.dev").expect("re-point");
            assert_eq!(ed.source_str().unwrap(), "see <https://y.dev> ok\n");

            // Source that looks right can still parse wrong: assert the reparse.
            let nodes = ed.nodes().expect("nodes");
            let url = nodes
                .iter()
                .find(|n| n.kind == Kind::Url)
                .expect("still an autolink");
            assert_eq!(url.text.as_deref(), Some("https://y.dev"));
            assert!(!nodes.iter().any(|n| n.kind == Kind::Link));
        }
    }

    #[test]
    fn editor_insert_link_escapes_the_destination() {
        // Unescaped, the `)` would close the link early and spill `b` into the
        // paragraph as literal text.
        let mut dj = Editor::new_str("w\n", Format::Djot).expect("editor");
        dj.insert_link(0, 1, "a)b").expect("link");
        assert_eq!(dj.source_str().unwrap(), "[w](a\\)b)\n");

        // Whitespace is where the formats part ways: Markdown needs the angle
        // form (a bare space ends the destination and kills the link outright),
        // Djot must NOT use it (it would link to the literal text `<a b>`).
        let mut md = Editor::new_str("w\n", Format::Markdown).expect("editor");
        md.insert_link(0, 1, "a b").expect("link");
        assert_eq!(md.source_str().unwrap(), "[w](<a b>)\n");

        let mut dj2 = Editor::new_str("w\n", Format::Djot).expect("editor");
        dj2.insert_link(0, 1, "a b").expect("link");
        assert_eq!(dj2.source_str().unwrap(), "[w](a b)\n");
    }

    #[test]
    fn editor_insert_image_escapes_the_destination_per_format() {
        // The whole point of the op: a caller's `![](my cat.png)` is not an image
        // in Markdown, and the correct repair differs by format.
        let mut md = Editor::new_str("w\n", Format::Markdown).expect("editor");
        md.insert_image(0, 1, "my cat.png").expect("image");
        assert_eq!(md.source_str().unwrap(), "![w](<my cat.png>)\n");

        let mut dj = Editor::new_str("w\n", Format::Djot).expect("editor");
        dj.insert_image(0, 1, "my cat.png").expect("image");
        assert_eq!(dj.source_str().unwrap(), "![w](my cat.png)\n");

        // A `)` would close the image early and spill the rest as literal text.
        let mut paren = Editor::new_str("w\n", Format::Djot).expect("editor");
        paren.insert_image(0, 1, "a)b.png").expect("image");
        assert_eq!(paren.source_str().unwrap(), "![w](a\\)b.png)\n");
    }

    #[test]
    fn editor_insert_image_keeps_an_empty_alt_empty() {
        // Unlike a link, where an empty range spells an autolink or doubles the
        // destination as text — an image with no alt is ordinary.
        let mut ed = Editor::new_str("ab\n", Format::Markdown).expect("editor");
        ed.insert_image(1, 1, "cat.png").expect("image");
        assert_eq!(ed.source_str().unwrap(), "a![](cat.png)b\n");
    }

    #[test]
    fn editor_insert_image_rejects_a_newline_destination() {
        let mut ed = Editor::new_str("w\n", Format::Djot).expect("editor");
        assert_eq!(
            ed.insert_image(0, 1, "a\nb.png"),
            Err(Error::InvalidArgument)
        );

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(
            xml.insert_image(3, 5, "x.png"),
            Err(Error::UnsupportedFormat)
        );
    }

    #[test]
    fn editor_insert_link_rejects_a_newline_destination() {
        let mut ed = Editor::new_str("w\n", Format::Djot).expect("editor");
        assert_eq!(ed.insert_link(0, 1, "a\nb"), Err(Error::InvalidArgument));

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(xml.insert_link(3, 5, "u"), Err(Error::UnsupportedFormat));
    }

    #[test]
    fn editor_insert_literal_keeps_typed_specials_literal() {
        for format in [Format::Markdown, Format::Djot] {
            let mut ed = Editor::new_str("z\n", format).expect("editor");
            // A `*` at a line start would open emphasis unescaped.
            ed.insert_literal(0, "*hi*").expect("literal");

            // Source that looks right can still parse wrong: assert the reparse.
            let nodes = ed.nodes().expect("nodes");
            assert!(
                !nodes
                    .iter()
                    .any(|n| n.kind == Kind::Emph || n.kind == Kind::Strong)
            );
            let text: String = nodes
                .iter()
                .filter(|n| n.kind == Kind::Str)
                .filter_map(|n| n.text.clone())
                .collect();
            assert_eq!(text, "*hi*z");
        }
    }

    #[test]
    fn editor_insert_literal_escapes_block_markers_only_at_line_start() {
        // Mid-line, a `#` opens nothing and is left as typed.
        let mut ed = Editor::new_str("az\n", Format::Markdown).expect("editor");
        ed.insert_literal(1, "# ").expect("literal");
        assert_eq!(ed.source_str().unwrap(), "a# z\n");

        // At a line start it would open a heading, so it is escaped.
        let mut ed2 = Editor::new_str("z\n", Format::Markdown).expect("editor");
        ed2.insert_literal(0, "# ").expect("literal");
        assert_eq!(ed2.source_str().unwrap(), "\\# z\n");
        assert!(
            !ed2.nodes()
                .expect("nodes")
                .iter()
                .any(|n| n.kind == Kind::Heading)
        );
    }

    #[test]
    fn editor_insert_literal_rejects_bad_offset_and_parse_only_format() {
        let mut ed = Editor::new_str("ab\n", Format::Markdown).expect("editor");
        assert_eq!(ed.insert_literal(99, "x"), Err(Error::InvalidArgument));

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(xml.insert_literal(3, "x"), Err(Error::UnsupportedFormat));
    }

    #[test]
    fn editor_insert_line_break_splices_in_cell_br() {
        let mut ed =
            Editor::new_str("| a | b |\n| --- | --- |\n", Format::Markdown).expect("editor");
        // Caret just after `a` in the header cell.
        ed.insert_line_break(3).expect("line break");
        assert_eq!(ed.source_str().unwrap(), "| a<br> | b |\n| --- | --- |\n");
        // The break reads back as a semantic node, not raw HTML.
        let nodes = ed.nodes().expect("nodes");
        assert!(nodes.iter().any(|n| n.kind == Kind::HardBreak));
        assert!(!nodes.iter().any(|n| n.kind == Kind::RawInline));
    }

    #[test]
    fn editor_insert_line_break_rejects_off_cell_off_format_and_bad_offset() {
        // Not inside a cell → NotFound.
        let mut para = Editor::new_str("just text\n", Format::Markdown).expect("editor");
        assert_eq!(para.insert_line_break(3), Err(Error::NotFound));

        // Djot has no in-cell break spelling → UnsupportedFormat.
        let mut dj = Editor::new_str("| a | b |\n| --- | --- |\n", Format::Djot).expect("editor");
        assert_eq!(dj.insert_line_break(3), Err(Error::UnsupportedFormat));

        // Out-of-range offset → InvalidArgument.
        let mut ed =
            Editor::new_str("| a | b |\n| --- | --- |\n", Format::Markdown).expect("editor");
        assert_eq!(ed.insert_line_break(9999), Err(Error::InvalidArgument));
    }

    #[test]
    fn editor_insert_thematic_break_is_blank_separated_per_format() {
        // The blank line above is load-bearing, not cosmetic: flush against the
        // paragraph, Markdown's `---` is a setext underline and the paragraph
        // becomes an <h2>. So assert the reparsed KIND, not just the bytes.
        let mut md = Editor::new_str("a\n", Format::Markdown).expect("editor");
        md.insert_thematic_break(0).expect("rule");
        assert_eq!(md.source_str().unwrap(), "a\n\n---\n");
        let nodes = md.nodes().expect("nodes");
        assert!(nodes.iter().any(|n| n.kind == Kind::ThematicBreak));
        assert!(!nodes.iter().any(|n| n.kind == Kind::Heading));

        // Djot spells the same construct differently — the reason the spelling
        // is the library's and not the caller's.
        let mut dj = Editor::new_str("a\n", Format::Djot).expect("editor");
        dj.insert_thematic_break(0).expect("rule");
        assert_eq!(dj.source_str().unwrap(), "a\n\n* * *\n");

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(xml.insert_thematic_break(3), Err(Error::UnsupportedFormat));
    }

    #[test]
    fn editor_split_block_keeps_both_halves_the_same_kind() {
        // A list item's halves are both items — the marker is repeated, so the
        // second half doesn't fall out of the list as a paragraph.
        let mut item = Editor::new_str("- this is a list item\n", Format::Markdown).expect("editor");
        item.split_block(10).expect("split");
        assert_eq!(item.source_str().unwrap(), "- this is \n- a list item\n");
        let nodes = item.nodes().expect("nodes");
        assert_eq!(nodes.iter().filter(|n| n.kind == Kind::ListItem).count(), 2);

        // At the item's end the empty sibling IS the point — that is Enter.
        let mut tail = Editor::new_str("- a\n", Format::Markdown).expect("editor");
        tail.split_block(3).expect("split");
        assert_eq!(tail.source_str().unwrap(), "- a\n- \n");

        // A paragraph divides on a blank line instead.
        let mut para = Editor::new_str("ab\n", Format::Markdown).expect("editor");
        para.split_block(1).expect("split");
        assert_eq!(para.source_str().unwrap(), "a\n\nb\n");

        // A table has no honest caret-split: a newline mid-cell destroys it.
        let mut table =
            Editor::new_str("| a | b |\n|---|---|\n| c | d |\n", Format::Markdown).expect("editor");
        assert_eq!(table.split_block(3), Err(Error::NotEditable));

        let mut empty = Editor::new_str("", Format::Markdown).expect("editor");
        assert_eq!(empty.split_block(0), Err(Error::NotFound));
    }

    #[test]
    fn editor_toggle_code_block_round_trips_and_measures_the_fence() {
        let mut ed = Editor::new_str("a\n", Format::Markdown).expect("editor");
        ed.toggle_code_block(0, 1, Some("zig")).expect("fence");
        assert_eq!(ed.source_str().unwrap(), "```zig\na\n```\n");
        let nodes = ed.nodes().expect("nodes");
        assert!(nodes.iter().any(|n| n.kind == Kind::CodeBlock));

        ed.toggle_code_block(0, 0, None).expect("unfence");
        assert_eq!(ed.source_str().unwrap(), "a\n");

        // Three backticks in the body would close a three-backtick fence, so the
        // fence is measured against the body rather than fixed.
        let mut runs = Editor::new_str("a ``` b\n", Format::Markdown).expect("editor");
        runs.toggle_code_block(0, 7, None).expect("fence");
        assert_eq!(runs.source_str().unwrap(), "````\na ``` b\n````\n");
    }

    #[test]
    fn editor_toggle_code_block_refuses_inside_a_list_item() {
        // A fence at column zero here would pull the item's `- ` into the code
        // body and the item would stop being an item.
        let mut ed = Editor::new_str("- a\n- b\n", Format::Markdown).expect("editor");
        assert_eq!(ed.toggle_code_block(2, 3, None), Err(Error::NotEditable));
        assert_eq!(ed.source_str().unwrap(), "- a\n- b\n");
    }

    #[test]
    fn editor_set_code_language_retags_clears_and_refuses() {
        let mut ed = Editor::new_str("```zig\na\n```\n", Format::Markdown).expect("editor");
        ed.set_code_language(0, Some("rust")).expect("retag");
        assert_eq!(ed.source_str().unwrap(), "```rust\na\n```\n");

        // `None` clears the info string; `Some("")` writes the same bytes but is
        // a different request.
        ed.set_code_language(0, None).expect("clear");
        assert_eq!(ed.source_str().unwrap(), "```\na\n```\n");
        ed.set_code_language(0, Some("")).expect("empty");
        assert_eq!(ed.source_str().unwrap(), "```\na\n```\n");

        // Markdown's info string ends at whitespace, so a space would come back
        // truncated — refused rather than silently clipped.
        assert_eq!(
            ed.set_code_language(0, Some("a b")),
            Err(Error::InvalidArgument)
        );
        // Djot's runs to the end of the line, so the same string is fine there.
        let mut dj = Editor::new_str("```\na\n```\n", Format::Djot).expect("editor");
        dj.set_code_language(0, Some("a b"))
            .expect("djot info string");
        assert_eq!(dj.source_str().unwrap(), "```a b\na\n```\n");

        let mut para = Editor::new_str("x\n", Format::Markdown).expect("editor");
        assert_eq!(para.set_code_language(0, Some("zig")), Err(Error::NotFound));
    }

    #[test]
    fn editor_task_checkbox_gestures() {
        let mut ed = Editor::new_str("- a\n", Format::Markdown).expect("editor");

        // The box is added by one gesture and ticked by another — adding
        // converts the item's kind, ticking only changes what the box holds.
        ed.toggle_task_item(2).expect("add box");
        assert_eq!(ed.source_str().unwrap(), "- [ ] a\n");
        assert!(
            ed.nodes()
                .unwrap()
                .iter()
                .any(|n| n.kind == Kind::TaskListItem)
        );

        ed.set_task_checked(6, true).expect("tick");
        assert_eq!(ed.source_str().unwrap(), "- [x] a\n");
        // Already checked: a no-op that still succeeds and moves nothing.
        ed.set_task_checked(6, true).expect("no-op");
        assert_eq!(ed.source_str().unwrap(), "- [x] a\n");

        ed.toggle_task_checked(6).expect("flip");
        assert_eq!(ed.source_str().unwrap(), "- [ ] a\n");

        ed.toggle_task_item(6).expect("remove box");
        assert_eq!(ed.source_str().unwrap(), "- a\n");

        // A plain bullet has no box to tick; `toggle_task_item` is how a caller
        // asks for one.
        assert_eq!(ed.set_task_checked(2, true), Err(Error::NotEditable));
        // And a caret in no list item has no item at all.
        let mut para = Editor::new_str("a\n", Format::Markdown).expect("editor");
        assert_eq!(para.toggle_task_item(0), Err(Error::NotFound));
    }

    #[test]
    fn editor_insert_footnote_writes_both_halves_as_one_edit() {
        for format in [Format::Markdown, Format::Djot] {
            let mut ed = Editor::new_str("see\n", format).expect("editor");
            ed.insert_footnote(3, "a").expect("footnote");
            assert_eq!(ed.source_str().unwrap(), "see[^a]\n\n[^a]: \n");

            // Half a footnote is not a footnote, so assert both nodes exist.
            let nodes = ed.nodes().expect("nodes");
            assert!(nodes.iter().any(|n| n.kind == Kind::FootnoteReference));
            assert!(nodes.iter().any(|n| n.kind == Kind::Footnote));

            // One edit, so one undo takes both halves back.
            ed.undo().expect("undo");
            assert_eq!(ed.source_str().unwrap(), "see\n");
        }
    }

    #[test]
    fn editor_insert_footnote_reuses_an_existing_definition() {
        let mut ed = Editor::new_str("see\n", Format::Markdown).expect("editor");
        ed.insert_footnote(3, "a").expect("first");
        ed.insert_footnote(7, "a").expect("second reference");
        assert_eq!(ed.source_str().unwrap(), "see[^a][^a]\n\n[^a]: \n");
        let defs = ed
            .nodes()
            .unwrap()
            .iter()
            .filter(|n| n.kind == Kind::Footnote)
            .count();
        assert_eq!(defs, 1);

        assert_eq!(ed.insert_footnote(3, ""), Err(Error::InvalidArgument));
        assert_eq!(ed.insert_footnote(3, "a]b"), Err(Error::InvalidArgument));
    }

    #[test]
    fn editor_undo_redo_round_trip() {
        let mut ed = Editor::new_str("hello\n", Format::Markdown).expect("editor");
        ed.edit_range(5, 5, "!").expect("edit");
        assert_eq!(ed.source_str().unwrap(), "hello!\n");

        let change = ed.undo().expect("undo ok").expect("something to undo");
        assert_eq!(ed.source_str().unwrap(), "hello\n");
        assert_eq!(change.new.end, 5);
        assert!(ed.undo().expect("undo ok").is_none(), "history exhausted");

        ed.redo().expect("redo ok").expect("something to redo");
        assert_eq!(ed.source_str().unwrap(), "hello!\n");
    }

    #[test]
    fn editor_coalesce_folds_a_run() {
        let mut ed = Editor::new_str("\n", Format::Markdown).expect("editor");
        ed.edit_range(0, 0, "a").expect("edit");
        ed.edit_range(1, 1, "b").expect("edit");
        ed.coalesce_last_undo().expect("coalesce");
        assert_eq!(ed.source_str().unwrap(), "ab\n");
        // One undo removes the whole coalesced run.
        ed.undo().expect("undo ok").expect("something to undo");
        assert_eq!(ed.source_str().unwrap(), "\n");
        assert!(ed.undo().expect("undo ok").is_none());
    }

    #[test]
    fn editor_revision_bumps_per_successful_mutation() {
        let mut ed = Editor::new_str("x\n", Format::Markdown).expect("editor");
        assert_eq!(ed.revision(), 0);
        ed.edit_range(1, 1, "y").expect("edit");
        assert_eq!(ed.revision(), 1);

        // A reparse-breaking edit is rolled back and must not bump the revision.
        let mut xml = Editor::new_str("<a>ok</a>", Format::Xml).expect("editor");
        assert_eq!(xml.revision(), 0);
        assert!(xml.replace_content("0", "<b>").is_err());
        assert_eq!(xml.revision(), 0);

        // undo and redo are mutations too.
        ed.undo().expect("undo ok").expect("something to undo");
        assert_eq!(ed.revision(), 2);
        ed.redo().expect("redo ok").expect("something to redo");
        assert_eq!(ed.revision(), 3);
    }

    #[test]
    fn editor_dirty_range_tracks_and_clears() {
        let mut ed = Editor::new_str("abcdefgh\n", Format::Markdown).expect("editor");
        // Clean to start.
        assert_eq!(ed.dirty_range(), None);

        // One insertion of two bytes at offset 2 dirties exactly [2, 4).
        ed.edit_range(2, 2, "XY").expect("edit");
        assert_eq!(ed.dirty_range(), Some(2..4));

        // A second, disjoint edit near the end accumulates conservatively: the
        // reported range is a superset covering both edits.
        ed.edit_range(9, 9, "Z").expect("edit"); // source is now "abXYcdefgZh\n"
        let d = ed.dirty_range().expect("dirty");
        assert!(
            d.start <= 2 && d.end >= 10,
            "range {d:?} must cover both edits"
        );

        // clear_dirty acknowledges without moving the revision.
        let rev = ed.revision();
        ed.clear_dirty();
        assert_eq!(ed.dirty_range(), None);
        assert_eq!(ed.revision(), rev);

        // Post-clear, only new mutations show up — and undo counts as one.
        ed.undo().expect("undo ok").expect("something to undo");
        assert!(ed.dirty_range().is_some());
    }

    #[test]
    fn editor_caret_blob_follows_undo_and_redo() {
        let mut ed = Editor::new_str("hello\n", Format::Markdown).expect("editor");
        assert!(ed.caret_blob().unwrap().is_empty());

        // Set the pre-edit caret, then edit: the retired undo step captures it.
        ed.set_caret_blob(b"before").expect("set caret");
        ed.edit_range(5, 5, "!").expect("edit");
        // A fresh state starts caret-less until the host sets one.
        assert!(ed.caret_blob().unwrap().is_empty());
        ed.set_caret_blob(b"after").expect("set caret");

        // Undo restores the pre-edit source AND the pre-edit caret.
        ed.undo().expect("undo ok").expect("something to undo");
        assert_eq!(ed.source_str().unwrap(), "hello\n");
        assert_eq!(ed.caret_blob().unwrap(), b"before");

        // Redo restores the post-edit source AND the post-edit caret.
        ed.redo().expect("redo ok").expect("something to redo");
        assert_eq!(ed.source_str().unwrap(), "hello!\n");
        assert_eq!(ed.caret_blob().unwrap(), b"after");
    }

    #[test]
    fn editor_coalesced_run_keeps_the_pre_run_caret() {
        let mut ed = Editor::new_str("\n", Format::Markdown).expect("editor");
        ed.set_caret_blob(b"c0").expect("set caret");
        ed.edit_range(0, 0, "a").expect("edit");
        ed.set_caret_blob(b"c1").expect("set caret");
        ed.edit_range(1, 1, "b").expect("edit");
        ed.coalesce_last_undo().expect("coalesce");
        ed.set_caret_blob(b"c2").expect("set caret");

        // One undo folds the run and restores the caret from before it began.
        ed.undo().expect("undo ok").expect("something to undo");
        assert_eq!(ed.source_str().unwrap(), "\n");
        assert_eq!(ed.caret_blob().unwrap(), b"c0");
    }

    #[test]
    fn editor_renumber_ordered_lists_fixes_a_stale_sequence() {
        let mut ed = Editor::new_str("1. a\n2. x\n2. b\n3. c\n", Format::Markdown).expect("editor");
        ed.renumber_ordered_lists(0).expect("renumber ok");
        assert_eq!(ed.source_str().unwrap(), "1. a\n2. x\n3. b\n4. c\n");
    }

    #[test]
    fn editor_renumber_ordered_lists_leaves_djot_prose_alone() {
        // Djot reads `   2. b` as text inside item `a`; Markdown reads the same
        // bytes as a nested item. The author's digit survives in the one case.
        let src = "1. a\n   2. b\n2. c\n";
        let mut dj = Editor::new_str(src, Format::Djot).expect("editor");
        dj.renumber_ordered_lists(0).expect("renumber ok");
        assert_eq!(dj.source_str().unwrap(), src);

        let mut md = Editor::new_str(src, Format::Markdown).expect("editor");
        md.renumber_ordered_lists(0).expect("renumber ok");
        assert_eq!(md.source_str().unwrap(), "1. a\n   1. b\n2. c\n");
    }

    #[test]
    fn editor_renumber_ordered_lists_off_a_list_is_not_found() {
        let mut ed = Editor::new_str("a paragraph\n", Format::Markdown).expect("editor");
        assert!(matches!(ed.renumber_ordered_lists(2), Err(Error::NotFound)));
    }

    #[test]
    fn editor_table_insert_row_and_set_alignment() {
        let src = "| a | b |\n| --- | --- |\n| 1 | 2 |\n";
        let mut ed = Editor::new_str(src, Format::Markdown).expect("editor");
        ed.table_insert_row(24, true).expect("insert row"); // caret in body `1`
        assert_eq!(
            ed.source_str().unwrap(),
            "| a | b |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n"
        );
        ed.table_set_alignment(6, Alignment::Center).expect("align"); // column `b`
        assert!(ed.source_str().unwrap().contains("| --- | :---: |"));
    }

    #[test]
    fn editor_table_edit_off_a_table_is_not_found() {
        let mut ed = Editor::new_str("nope\n", Format::Markdown).expect("editor");
        assert!(matches!(ed.table_delete_row(2), Err(Error::NotFound)));
    }

    #[test]
    fn editor_set_block_converts_setext_heading() {
        // A setext heading rebuilt from its content_span collapses the underline.
        let mut ed = Editor::new_str("Title\n=====\n\nbody\n", Format::Markdown).expect("editor");
        ed.set_block(0, BlockKind::Heading(1))
            .expect("setext to atx");
        assert_eq!(ed.source_str().unwrap(), "# Title\n\nbody\n");
    }

    #[test]
    fn editor_unwrap_and_smart_delete() {
        let mut ed = Editor::new_str("<r><box><b/><c/></box></r>", Format::Xml).expect("editor");
        ed.unwrap_node("0.0").expect("unwrap"); // <box>
        assert_eq!(ed.source_str().expect("source"), "<r><b/><c/></r>");

        let mut md = Editor::new_str("A\n\nB\n\nC\n", Format::Markdown).expect("editor");
        md.delete_smart("1").expect("delete_smart"); // the "B" paragraph
        assert_eq!(md.source_str().expect("source"), "A\n\nC\n");
    }

    #[test]
    fn editor_directives_require_the_extension_flag() {
        let src = ":::vis{.public}\nhi\n:::\n";
        // Without the flag, the colon-fence lines are plain paragraph text —
        // no directive node.
        let mut plain = Editor::new_str(src, Format::Markdown).expect("editor");
        assert_eq!(plain.query("directive").expect("query").len(), 0);
        // With it enabled, the container directive is recognized.
        let mut ext = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions {
                directives: true,
                ..Default::default()
            },
        )
        .expect("editor");
        assert_eq!(ext.query("directive").expect("query").len(), 1);
    }

    #[test]
    fn document_html_elements_make_embedded_img_queryable() {
        let src = "text <img src=\"a.png\" alt=\"x\"> more\n";
        // Without the flag, the `<img>` is opaque raw HTML — no `image` node.
        let mut plain = Document::parse_str(src, Format::Markdown).expect("parse");
        assert_eq!(plain.query("image").expect("query").len(), 0);
        // With it enabled on the read path, the promoted image is queryable.
        let mut ext = Document::parse_str_with(
            src,
            Format::Markdown,
            MarkdownExtensions {
                html_elements: true,
                ..Default::default()
            },
        )
        .expect("parse");
        let images = ext.query("image").expect("query");
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].kind, Kind::Image);
    }

    #[test]
    fn editor_filter_public_audience_view() {
        let src = "# Archive\n\n:::vis{.public}\nPublic.\n:::\n\n:::vis{.family}\nPrivate.\n:::\n";
        let mut ed = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions {
                directives: true,
                ..Default::default()
            },
        )
        .expect("editor");
        // Drop every vis block except the public one, then unwrap it.
        ed.filter(
            "directive[name=vis]",
            Some("directive[class~=public]"),
            true,
        )
        .expect("filter");
        assert_eq!(ed.source_str().expect("source"), "# Archive\n\nPublic.\n");
    }

    #[test]
    fn editor_filter_rejects_a_malformed_selector() {
        let mut ed = Editor::new_str("hi\n", Format::Markdown).expect("editor");
        assert_eq!(
            ed.filter("list >", None, false),
            Err(Error::InvalidArgument)
        );
    }

    #[test]
    fn builder_builds_and_renders_a_document() {
        let mut b = Builder::new().expect("builder");

        // # Title\n\nhello *world*
        let title = b.add_text(TextKind::Str, "Title").unwrap();
        let heading = b.add_heading(1).unwrap();
        b.set_children(heading, &[title]).unwrap();

        let hello = b.add_text(TextKind::Str, "hello ").unwrap();
        let world = b.add_text(TextKind::Str, "world").unwrap();
        let emph = b.add(VoidKind::Emph).unwrap();
        b.set_children(emph, &[world]).unwrap();
        let para = b.add(VoidKind::Para).unwrap();
        b.set_children(para, &[hello, emph]).unwrap();

        let doc = b.add(VoidKind::Doc).unwrap();
        b.set_children(doc, &[heading, para]).unwrap();

        let html = String::from_utf8(b.render_html(doc).unwrap()).unwrap();
        assert!(html.contains("<h1>Title</h1>"), "{html}");
        assert!(html.contains("<em>world</em>"), "{html}");

        let md = String::from_utf8(b.serialize(doc, Format::Markdown).unwrap()).unwrap();
        assert!(md.contains("# Title"), "{md}");
        assert!(md.contains("*world*"), "{md}");

        let matches = b.query(doc, "heading").unwrap();
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].kind, Kind::Heading);

        let json = String::from_utf8(b.ast_json(doc).unwrap()).unwrap();
        assert!(json.contains("\"kind\": \"doc\""), "{json}");
    }

    #[test]
    fn builder_element_with_attributes() {
        let mut b = Builder::new().expect("builder");
        let inner = b.add_text(TextKind::Str, "hi").unwrap();
        let el = b.add_element("section").unwrap();
        b.set_children(el, &[inner]).unwrap();
        b.set_attrs(el, &[("class", Some("note")), ("hidden", None)])
            .unwrap();

        let html = String::from_utf8(b.render_html(el).unwrap()).unwrap();
        assert!(html.contains("<section"), "{html}");
        assert!(html.contains("class=\"note\""), "{html}");
        assert!(html.contains("hidden"), "{html}");
    }

    #[test]
    fn builder_lists_round_trip_to_markdown() {
        let mut b = Builder::new().expect("builder");

        // An ordered list: 1. one / 2. two
        let one_txt = b.add_text(TextKind::Str, "one").unwrap();
        let one_para = b.add(VoidKind::Para).unwrap();
        b.set_children(one_para, &[one_txt]).unwrap();
        let one = b.add(VoidKind::ListItem).unwrap();
        b.set_children(one, &[one_para]).unwrap();

        let two_txt = b.add_text(TextKind::Str, "two").unwrap();
        let two_para = b.add(VoidKind::Para).unwrap();
        b.set_children(two_para, &[two_txt]).unwrap();
        let two = b.add(VoidKind::ListItem).unwrap();
        b.set_children(two, &[two_para]).unwrap();

        let list = b
            .add_ordered_list(
                OrderedNumbering::Decimal,
                OrderedDelim::Period,
                true,
                Some(1),
            )
            .unwrap();
        b.set_children(list, &[one, two]).unwrap();
        let doc = b.add(VoidKind::Doc).unwrap();
        b.set_children(doc, &[list]).unwrap();

        let md = String::from_utf8(b.serialize(doc, Format::Markdown).unwrap()).unwrap();
        assert!(md.contains("1. one"), "{md}");
        assert!(md.contains("2. two"), "{md}");
    }

    #[test]
    fn builder_rejects_invalid_kind_and_id() {
        let b = Builder::new().expect("builder");
        // `heading` (code 2) carries a payload, so the void-kind `add` rejects it
        // — the safe `VoidKind` enum has no such variant, so we go through the raw
        // ABI to prove the guard.
        let mut id = 0u32;
        let status = unsafe { ffi::twig_builder_add(b.raw.as_ptr(), 2, &mut id) };
        assert_eq!(Error::from_status(status), Err(Error::InvalidArgument));

        // A root id past the end can't be rendered.
        let mut ptr = std::ptr::null();
        let mut len = 0usize;
        let status =
            unsafe { ffi::twig_builder_render_html(b.raw.as_ptr(), 4242, &mut ptr, &mut len) };
        assert_eq!(Error::from_status(status), Err(Error::InvalidArgument));
    }
}
