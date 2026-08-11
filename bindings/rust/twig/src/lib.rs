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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Format {
    Djot,
    Markdown,
    Xml,
    Html,
}

impl From<Format> for ffi::TwigFormat {
    fn from(value: Format) -> Self {
        match value {
            Format::Djot => ffi::TwigFormat::Djot,
            Format::Markdown => ffi::TwigFormat::Markdown,
            Format::Xml => ffi::TwigFormat::Xml,
            Format::Html => ffi::TwigFormat::Html,
        }
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
    /// The node-kind name (e.g. `"heading"`, `"code_block"`).
    pub kind: String,
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
    pub kind: String,
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
    /// Which of the three surface forms a `directive` was written in; `None` for
    /// every other kind. Pairs with [`name`](Self::name): the name says *which*
    /// directive, this says *how it was written*, and a renderer needs both —
    /// the same type is a span inline ([`DirectiveForm::Text`]), a standalone
    /// block with no body ([`DirectiveForm::Leaf`]), and a wrapper around blocks
    /// ([`DirectiveForm::Container`]).
    pub directive_form: Option<DirectiveForm>,
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

    /// Serialize the document to `format`'s own source syntax: a round-trip
    /// when `format` matches the document's own format, cross-format
    /// conversion otherwise (e.g. parse Markdown, serialize as Djot). Returns
    /// [`Error::UnsupportedFormat`] when the requested direction has no
    /// serializer (today: converting into XML from another format).
    pub fn serialize(&mut self, format: Format) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        let ffi_format: ffi::TwigFormat = format.into();
        collect_bytes(|ptr, len| unsafe {
            ffi::twig_document_serialize(raw, ffi_format as i32, ptr, len)
        })
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
        let status = unsafe {
            ffi::twig_document_node_content_span(self.raw.as_ptr(), node.0, &mut span)
        };
        match status.0 {
            ffi::TwigStatus::OK => Ok(Some(span.start..span.end)),
            ffi::TwigStatus::NOT_FOUND => Ok(None),
            _ => Err(Error::from_status(status).unwrap_err()),
        }
    }

    /// Snapshot the whole tree as a flat [`FlatNode`] array (the JSON-free read
    /// path for a renderer), indexed so `nodes[i].id == NodeId(i)`. Walk it via
    /// the `parent`/`first_child`/`next_sibling` links; the root is the node
    /// whose `parent` is `None`.
    pub fn nodes(&mut self) -> Result<Vec<FlatNode>, Error> {
        let raw = self.raw.as_ptr();
        collect_flat_nodes(|ptr, len| unsafe { ffi::twig_document_nodes(raw, ptr, len) })
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
        let status =
            unsafe { ffi::twig_editor_create(input.as_ptr(), input.len(), ffi_format as i32, &mut raw) };
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
    pub fn new_ext(input: &[u8], format: Format, extensions: MarkdownExtensions) -> Result<Self, Error> {
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
        let status = unsafe {
            ffi::twig_editor_delete(self.raw.as_ptr(), locator.as_ptr(), locator.len())
        };
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
        let status = unsafe {
            ffi::twig_editor_unwrap(self.raw.as_ptr(), locator.as_ptr(), locator.len())
        };
        Error::from_status(status)
    }

    /// Prune the document in place: remove every node matching the `drop`
    /// selector except those also matching `keep` (`None` spares nothing),
    /// then — if `unwrap_kept` — unwrap the survivors. Read the result with
    /// [`Editor::source`].
    pub fn filter(&mut self, drop: &str, keep: Option<&str>, unwrap_kept: bool) -> Result<(), Error> {
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
        let status =
            unsafe { ffi::twig_editor_set_caret_blob(self.raw.as_ptr(), blob.as_ptr(), blob.len()) };
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
    pub fn wrap_range(&mut self, start: usize, end: usize, kind: InlineKind) -> Result<Change, Error> {
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_wrap_range(ed, start, end, kind.to_c(), out)
        })
    }

    /// Toggle `kind` over `[start, end)`: remove the mark if the range already
    /// *is* a node of `kind` (its whole span or its rendered interior), else
    /// wrap it — a rich editor's Cmd-B. Same error rules as
    /// [`Editor::wrap_range`].
    pub fn toggle_inline(&mut self, start: usize, end: usize, kind: InlineKind) -> Result<Change, Error> {
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
    pub fn table_set_alignment(&mut self, offset: usize, alignment: Alignment) -> Result<(), Error> {
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
        self.change_op(|ed, out| unsafe {
            ffi::twig_editor_table_edit(ed, offset, op, arg, out)
        })?;
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
    /// URL — is refused with [`Status::NotEditable`]: half of it is real text,
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
        kind: borrowed_cstr(m.kind)?,
    })
}

/// Copy a borrowed C ABI [`ffi::TwigFlatNode`] into an owned [`FlatNode`].
fn flat_node_from_ffi(n: &ffi::TwigFlatNode) -> Result<FlatNode, Error> {
    let node_id = |v: u32| if v == ffi::TWIG_NO_NODE { None } else { Some(NodeId(v)) };
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
        kind: borrowed_cstr(n.kind)?,
        text: borrowed_bytes(n.text_ptr, n.text_len),
        destination: borrowed_bytes(n.destination_ptr, n.destination_len),
        head: match n.head {
            ffi::TWIG_HEAD_NONE => None,
            v => Some(v != 0),
        },
        alignment: Alignment::from_c(n.alignment),
        name: borrowed_bytes(n.name_ptr, n.name_len),
        directive_form: DirectiveForm::from_c(n.directive_form),
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
        self.emit(|b, out| unsafe { ffi::twig_builder_add_text(b, kind.to_c(), text.as_ptr(), text.len(), out) })
    }

    /// Add a heading of the given level (attach its inline children afterward).
    pub fn add_heading(&mut self, level: u32) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_heading(b, level, out) })
    }

    /// Add a code block, with an optional info-string language.
    pub fn add_code_block(&mut self, lang: Option<&str>, text: &str) -> Result<NodeId, Error> {
        let (lp, ll, has) = opt_str(lang);
        self.emit(|b, out| unsafe { ffi::twig_builder_add_code_block(b, lp, ll, has, text.as_ptr(), text.len(), out) })
    }

    /// Add a raw block targeting `format` (e.g. `"html"`).
    pub fn add_raw_block(&mut self, format: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_raw_block(b, format.as_ptr(), format.len(), text.as_ptr(), text.len(), out)
        })
    }

    /// Add a document-metadata block written in config language `lang`.
    pub fn add_metadata(&mut self, lang: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_metadata(b, lang.as_ptr(), lang.len(), text.as_ptr(), text.len(), out)
        })
    }

    /// Add a raw inline targeting `format`.
    pub fn add_raw_inline(&mut self, format: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_raw_inline(b, format.as_ptr(), format.len(), text.as_ptr(), text.len(), out)
        })
    }

    /// Add a smart-punctuation node of `kind`. `text` is accepted for ABI
    /// compatibility but ignored by the underlying builder: the node's
    /// spelling is always the canonical one for `kind` (e.g. `"---"` for an
    /// em dash), never a caller-supplied one.
    pub fn add_smart_punctuation(&mut self, kind: SmartPunctuation, text: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_smart_punctuation(b, kind.to_c(), text.as_ptr(), text.len(), out)
        })
    }

    /// Add a link with an optional destination and/or reference label (attach
    /// the link text as children).
    pub fn add_link(&mut self, destination: Option<&str>, reference: Option<&str>) -> Result<NodeId, Error> {
        let (dp, dl, hd) = opt_str(destination);
        let (rp, rl, hr) = opt_str(reference);
        self.emit(|b, out| unsafe { ffi::twig_builder_add_link(b, dp, dl, hd, rp, rl, hr, out) })
    }

    /// Add an image — like [`Builder::add_link`], but children are the alt text.
    pub fn add_image(&mut self, destination: Option<&str>, reference: Option<&str>) -> Result<NodeId, Error> {
        let (dp, dl, hd) = opt_str(destination);
        let (rp, rl, hr) = opt_str(reference);
        self.emit(|b, out| unsafe { ffi::twig_builder_add_image(b, dp, dl, hd, rp, rl, hr, out) })
    }

    /// Add a generic directive of the given form and name.
    pub fn add_directive(&mut self, form: DirectiveForm, name: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_directive(b, form.to_c(), name.as_ptr(), name.len(), out) })
    }

    /// Add a generic named element (the escape hatch for HTML/XML tags).
    pub fn add_element(&mut self, name: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_element(b, name.as_ptr(), name.len(), out) })
    }

    /// Add an XML processing instruction (`<?target data?>`).
    pub fn add_processing_instruction(&mut self, target: &str, data: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_processing_instruction(b, target.as_ptr(), target.len(), data.as_ptr(), data.len(), out)
        })
    }

    /// Add a footnote definition with the given label.
    pub fn add_footnote(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_footnote(b, label.as_ptr(), label.len(), out) })
    }

    /// Add a link/image reference definition (`label` → `destination`).
    pub fn add_reference(&mut self, label: &str, destination: &str) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe {
            ffi::twig_builder_add_reference(b, label.as_ptr(), label.len(), destination.as_ptr(), destination.len(), out)
        })
    }

    /// Add a bullet list.
    pub fn add_bullet_list(&mut self, style: BulletStyle, tight: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_bullet_list(b, style.to_c(), tight as c_int, out) })
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
            ffi::twig_builder_add_ordered_list(b, numbering.to_c(), delim.to_c(), tight as c_int, start_val, has_start, out)
        })
    }

    /// Add a task list.
    pub fn add_task_list(&mut self, tight: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_task_list(b, tight as c_int, out) })
    }

    /// Add a task-list item with the given checkbox state.
    pub fn add_task_list_item(&mut self, checked: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_task_list_item(b, checked as c_int, out) })
    }

    /// Add a table row (`head` marks a header row).
    pub fn add_row(&mut self, head: bool) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_row(b, head as c_int, out) })
    }

    /// Add a table cell (`head` marks a header cell).
    pub fn add_cell(&mut self, head: bool, alignment: Alignment) -> Result<NodeId, Error> {
        self.emit(|b, out| unsafe { ffi::twig_builder_add_cell(b, head as c_int, alignment.to_c(), out) })
    }

    /// Set `parent`'s children to `children` (in order), replacing any it had.
    /// Each child id should appear in exactly one `set_children` call.
    pub fn set_children(&mut self, parent: NodeId, children: &[NodeId]) -> Result<(), Error> {
        let ids: Vec<u32> = children.iter().map(|n| n.0).collect();
        let status = unsafe { ffi::twig_builder_set_children(self.raw.as_ptr(), parent.0, ids.as_ptr(), ids.len()) };
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
        let status = unsafe { ffi::twig_builder_set_attrs(self.raw.as_ptr(), id.0, kvs.as_ptr(), kvs.len()) };
        Error::from_status(status)
    }

    /// Render the subtree rooted at `root` to HTML (generic whole-vocabulary
    /// printer — a built tree has no djot/Markdown side tables).
    pub fn render_html(&mut self, root: NodeId) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        collect_bytes(|ptr, len| unsafe { ffi::twig_builder_render_html(raw, root.0, ptr, len) })
    }

    /// Serialize the subtree rooted at `root` to `format`'s source syntax.
    /// Returns [`Error::UnsupportedFormat`] when the target can't represent the
    /// built tree (e.g. semantic kinds into XML).
    pub fn serialize(&mut self, root: NodeId, format: Format) -> Result<Vec<u8>, Error> {
        let raw = self.raw.as_ptr();
        let ffi_format: ffi::TwigFormat = format.into();
        collect_bytes(|ptr, len| unsafe { ffi::twig_builder_serialize(raw, root.0, ffi_format as i32, ptr, len) })
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
            assert_eq!(m.kind, "heading");
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

        assert_eq!(doc.span(NodeId(heading.node_id)).expect("span"), heading.span);
        assert_eq!(
            doc.content_span(NodeId(heading.node_id)).expect("content span"),
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
        assert_eq!(kids[0].kind, "heading");

        let sub = doc.subtree(NodeId(kids[0].node_id)).expect("subtree");
        assert_eq!(sub[0].id, NodeId(0));
        assert_eq!(sub[0].parent, None);
        assert_eq!(sub[0].span, kids[0].span);

        let hit = doc.node_at(2).expect("node_at").expect("a node at 2");
        let chain = doc.ancestors_at(2).expect("ancestors");
        assert_eq!(chain.last().expect("deepest").node_id, hit.node_id);
        assert_eq!(chain[0].kind, "doc");

        assert_eq!(doc.subtree(NodeId(u32::MAX)), Err(Error::InvalidArgument));
    }

    #[test]
    fn editor_document_view_reads_the_live_tree() {
        let mut ed = Editor::new_str("# one\n\ntwo\n", Format::Markdown).expect("editor");

        {
            let mut view = ed.document().expect("view");
            let kids = view.children(None).expect("children");
            assert_eq!(kids.len(), 2);
            assert_eq!(kids[0].kind, "heading");
            assert_eq!(view.span(NodeId(kids[0].node_id)).expect("span"), 0..5);
            // The two the view can't serve.
            assert_eq!(view.render_html(), Err(Error::UnsupportedFormat));
            assert_eq!(view.serialize(Format::Markdown), Err(Error::UnsupportedFormat));
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
            MarkdownExtensions { html_elements: true, ..Default::default() },
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
                ("media".to_string(), Some("(prefers-color-scheme: dark)".to_string())),
                ("srcset".to_string(), Some("d.svg".to_string())),
            ]
        );

        // The `<img>` fallback stays an `image` node (no element name), and its
        // `src` is the ordinary `destination`.
        let img = nodes.iter().find(|n| n.kind == "image").expect("an image node");
        assert!(img.name.is_none());
        assert_eq!(img.destination.as_deref(), Some("l.svg"));

        // A semantic node carries neither an element name nor attributes.
        let picture_kids_str = nodes.iter().find(|n| n.kind == "str");
        if let Some(s) = picture_kids_str {
            assert!(s.name.is_none() && s.attrs.is_empty());
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
            MarkdownExtensions { directives: true, ..Default::default() },
        )
        .expect("editor");
        let nodes = ed.nodes().expect("nodes");

        let forms: Vec<(Option<&str>, Option<DirectiveForm>)> = nodes
            .iter()
            .filter(|n| n.kind == "container")
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
        let embed = nodes.iter().find(|n| n.name.as_deref() == Some("embed")).expect("embed");
        assert_eq!(embed.attrs, vec![("src".to_string(), Some("demo.html".to_string()))]);
        let para = nodes.iter().find(|n| n.kind == "para").expect("a para");
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
        ed.replace("heading(\"Two\")", "## Renamed").expect("replace");
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

        ed.replace("heading(\"Two\")", "## Renamed").expect("replace");
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
        assert_eq!(roots[0].kind, "doc");

        // The heading carries its level; the "Hi" text is reachable as a payload.
        let heading = nodes.iter().find(|n| n.kind == "heading").expect("a heading");
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
            assert!(seen, "node {:?} not found among its parent's children", n.id);
        }
    }

    #[test]
    fn editor_child_spans_and_subtree_agree_with_nodes() {
        let src = "# Title\n\nHello **world** and more.\n\n- one\n- two\n";
        let mut ed = Editor::new_str(src, Format::Markdown).expect("editor");
        let all = ed.nodes().expect("nodes");
        let doc = all.iter().find(|n| n.kind == "doc").expect("doc");

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
        assert!(src[top[0].span.clone()].starts_with('#'), "first block is the heading");

        // child_spans works below the top level too.
        let list = top.iter().find(|m| m.kind.ends_with("list")).expect("a list");
        let items = ed.child_spans(Some(NodeId(list.node_id))).expect("items");
        assert_eq!(items.len(), 2);
        assert!(items.iter().all(|m| m.kind == "list_item"), "items: {items:?}");

        // subtree(para) is self-contained, local-indexed, and spans stay absolute.
        let para = top.iter().find(|m| m.kind == "para").expect("a para").node_id;
        let sub = ed.subtree(NodeId(para)).expect("subtree");
        assert_eq!(sub[0].id, NodeId(0), "root is local id 0");
        assert_eq!(sub[0].parent, None, "root has no parent inside the subtree");
        assert_eq!(sub[0].next_sibling, None, "root's sibling is severed");
        assert_eq!(sub[0].kind, "para");
        for (i, n) in sub.iter().enumerate() {
            assert_eq!(n.id, NodeId(i as u32), "dense local ids");
            for link in [n.parent, n.first_child, n.next_sibling].into_iter().flatten() {
                assert!((link.0 as usize) < sub.len(), "link {link:?} escapes the subtree");
            }
        }
        assert!(
            src[sub[0].span.clone()].starts_with("Hello"),
            "absolute span: {:?}",
            &src[sub[0].span.clone()]
        );

        // Same multiset of node kinds as the paragraph's arena subtree.
        fn arena_kinds(all: &[FlatNode], root: NodeId) -> Vec<String> {
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
        let mut got_kinds: Vec<String> = sub.iter().map(|n| n.kind.clone()).collect();
        want_kinds.sort();
        got_kinds.sort();
        assert_eq!(got_kinds, want_kinds, "subtree kinds match the arena");

        // Out-of-range id is rejected.
        assert!(matches!(ed.subtree(NodeId(9999)), Err(Error::InvalidArgument)));
    }

    #[test]
    fn flat_nodes_carry_table_head_and_alignment() {
        // The delimiter row (`|:-----|----:|`) is consumed by the parser and has
        // no node of its own, so `alignment` on the cells is the only way a
        // consumer can recover the column alignment from a snapshot.
        let src = "| Name | Qty |\n|:-----|----:|\n| Pear | 3 |\n";
        let mut ed = Editor::new_str(src, Format::Markdown).expect("editor");
        let nodes = ed.nodes().expect("nodes");

        let rows: Vec<_> = nodes.iter().filter(|n| n.kind == "row").collect();
        assert_eq!(rows.len(), 2, "a header row and one body row");
        assert_eq!(rows[0].head, Some(true), "first row is the header");
        assert_eq!(rows[1].head, Some(false), "second row is a body row");

        let cells: Vec<_> = nodes.iter().filter(|n| n.kind == "cell").collect();
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
        let mut plain = Editor::new_str("| A |\n| --- |\n| b |\n", Format::Markdown).expect("editor");
        let pnodes = plain.nodes().expect("nodes");
        let pcell = pnodes.iter().find(|n| n.kind == "cell").expect("a cell");
        assert_eq!(pcell.alignment, Some(Alignment::Default));
    }

    #[test]
    fn editor_node_at_and_ancestors_hit_test_offsets() {
        let mut ed = Editor::new_str("# Hi\n\ntext\n", Format::Markdown).expect("editor");

        // Offset 2 is the "H" of the heading "# Hi" [0,4).
        let m = ed.node_at(2).expect("node_at").expect("a node covers offset 2");
        assert!(m.span.contains(&2));

        // The ancestor chain is root-first and ends at the deepest (== node_at).
        let chain = ed.ancestors_at(2).expect("ancestors_at");
        assert!(!chain.is_empty());
        assert_eq!(chain[0].kind, "doc");
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
        ed.toggle_inline(4, 8, InlineKind::Strong).expect("toggle off");
        assert_eq!(ed.source_str().unwrap(), "a word b\n");

        // Toggle emphasis on when the range isn't already marked.
        ed.toggle_inline(2, 6, InlineKind::Emph).expect("toggle on");
        assert_eq!(ed.source_str().unwrap(), "a *word* b\n");
    }

    #[test]
    fn editor_inline_kind_support_is_format_specific() {
        // Markdown has no highlight/mark spelling.
        let mut md = Editor::new_str("a word b\n", Format::Markdown).expect("editor");
        assert_eq!(md.wrap_range(2, 6, InlineKind::Mark), Err(Error::UnsupportedFormat));

        // Djot spells it {=…=}.
        let mut dj = Editor::new_str("a word b\n", Format::Djot).expect("editor");
        dj.wrap_range(2, 6, InlineKind::Mark).expect("djot mark");
        assert_eq!(dj.source_str().unwrap(), "a {=word=} b\n");
    }

    #[test]
    fn editor_toggle_strips_verbatim_via_content_span() {
        let mut ed = Editor::new_str("a `code` b\n", Format::Markdown).expect("editor");
        // The verbatim node [2,8) reports content_span [3,7); toggle peels it.
        ed.toggle_inline(2, 8, InlineKind::Verbatim).expect("toggle code off");
        assert_eq!(ed.source_str().unwrap(), "a code b\n");

        // A multi-backtick span peels BOTH runs via content_span, not by
        // stripping a single delimiter (which would corrupt it to "`x`").
        let mut ed2 = Editor::new_str("a ``x`` b\n", Format::Markdown).expect("editor");
        ed2.toggle_inline(2, 7, InlineKind::Verbatim).expect("toggle multi off");
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
        assert_eq!(md.set_block(0, BlockKind::Heading(9)), Err(Error::InvalidArgument));

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(xml.set_block(1, BlockKind::Heading(1)), Err(Error::UnsupportedFormat));
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
                .find(|n| n.kind == "url")
                .expect("still an autolink");
            assert_eq!(url.text.as_deref(), Some("https://y.dev"));
            assert!(!nodes.iter().any(|n| n.kind == "link"));
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
        assert_eq!(ed.insert_image(0, 1, "a\nb.png"), Err(Error::InvalidArgument));

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(xml.insert_image(3, 5, "x.png"), Err(Error::UnsupportedFormat));
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
            assert!(!nodes.iter().any(|n| n.kind == "emph" || n.kind == "strong"));
            let text: String = nodes
                .iter()
                .filter(|n| n.kind == "str")
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
        assert!(!ed2.nodes().expect("nodes").iter().any(|n| n.kind == "heading"));
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
        assert!(nodes.iter().any(|n| n.kind == "hard_break"));
        assert!(!nodes.iter().any(|n| n.kind == "raw_inline"));
    }

    #[test]
    fn editor_insert_line_break_rejects_off_cell_off_format_and_bad_offset() {
        // Not inside a cell → NotFound.
        let mut para = Editor::new_str("just text\n", Format::Markdown).expect("editor");
        assert_eq!(para.insert_line_break(3), Err(Error::NotFound));

        // Djot has no in-cell break spelling → UnsupportedFormat.
        let mut dj =
            Editor::new_str("| a | b |\n| --- | --- |\n", Format::Djot).expect("editor");
        assert_eq!(dj.insert_line_break(3), Err(Error::UnsupportedFormat));

        // Out-of-range offset → InvalidArgument.
        let mut ed =
            Editor::new_str("| a | b |\n| --- | --- |\n", Format::Markdown).expect("editor");
        assert_eq!(ed.insert_line_break(9999), Err(Error::InvalidArgument));
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
        assert!(d.start <= 2 && d.end >= 10, "range {d:?} must cover both edits");

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
        let mut ed =
            Editor::new_str("1. a\n2. x\n2. b\n3. c\n", Format::Markdown).expect("editor");
        ed.renumber_ordered_lists(0).expect("renumber ok");
        assert_eq!(ed.source_str().unwrap(), "1. a\n2. x\n3. b\n4. c\n");
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
        ed.set_block(0, BlockKind::Heading(1)).expect("setext to atx");
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
            MarkdownExtensions { directives: true, ..Default::default() },
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
            MarkdownExtensions { html_elements: true, ..Default::default() },
        )
        .expect("parse");
        let images = ext.query("image").expect("query");
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].kind, "image");
    }

    #[test]
    fn editor_filter_public_audience_view() {
        let src = "# Archive\n\n:::vis{.public}\nPublic.\n:::\n\n:::vis{.family}\nPrivate.\n:::\n";
        let mut ed = Editor::new_ext(
            src.as_bytes(),
            Format::Markdown,
            MarkdownExtensions { directives: true, ..Default::default() },
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
        assert_eq!(ed.filter("list >", None, false), Err(Error::InvalidArgument));
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
        assert_eq!(matches[0].kind, "heading");

        let json = String::from_utf8(b.ast_json(doc).unwrap()).unwrap();
        assert!(json.contains("\"kind\": \"doc\""), "{json}");
    }

    #[test]
    fn builder_element_with_attributes() {
        let mut b = Builder::new().expect("builder");
        let inner = b.add_text(TextKind::Str, "hi").unwrap();
        let el = b.add_element("section").unwrap();
        b.set_children(el, &[inner]).unwrap();
        b.set_attrs(el, &[("class", Some("note")), ("hidden", None)]).unwrap();

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
            .add_ordered_list(OrderedNumbering::Decimal, OrderedDelim::Period, true, Some(1))
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
        let status = unsafe { ffi::twig_builder_render_html(b.raw.as_ptr(), 4242, &mut ptr, &mut len) };
        assert_eq!(Error::from_status(status), Err(Error::InvalidArgument));
    }
}
