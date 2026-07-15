mod error;
mod ffi;

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
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::TwigFormat = format.into();
        let status = unsafe { ffi::twig_parse(input.as_ptr(), input.len(), ffi_format as i32, &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    pub fn parse_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::parse(input.as_bytes(), format)
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
}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe { ffi::twig_document_destroy(self.raw.as_ptr()) }
    }
}

/// Markdown extensions to enable for an [`Editor`] parse (see
/// [`Editor::new_ext`]). Ignored for non-Markdown formats. Both default off,
/// matching the library.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MarkdownExtensions {
    /// Generic directives: `:name`, `::name`, `:::name`.
    pub directives: bool,
    /// `$...$` / `$$...$$` math.
    pub math: bool,
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

    /// Link `[start, end)` to `destination` — `[text](destination)`. Djot and
    /// Markdown only, else [`Error::UnsupportedFormat`];
    /// [`Error::InvalidArgument`] for a bad range or a destination containing a
    /// newline (neither format can carry one, and quietly rewriting the URL would
    /// be worse than refusing).
    ///
    /// An existing link covering the range has its destination **replaced** and
    /// its text kept, so re-linking fixes a URL instead of nesting
    /// `[[t](a)](b)`; to unlink, use [`Editor::unwrap_node`]. An empty range yields
    /// `[](destination)`, mirroring [`Editor::wrap_range`] on an empty range.
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
    })
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
            DirectiveForm::Text => 0,
            DirectiveForm::Leaf => 1,
            DirectiveForm::Container => 2,
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

    /// Add a smart-punctuation node standing for `text` (its source spelling).
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
    fn editor_toggle_strips_verbatim_without_content_span() {
        let mut ed = Editor::new_str("a `code` b\n", Format::Markdown).expect("editor");
        // The verbatim node [2,8) has no content_span; toggle peels the backticks.
        ed.toggle_inline(2, 8, InlineKind::Verbatim).expect("toggle code off");
        assert_eq!(ed.source_str().unwrap(), "a code b\n");
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
    fn editor_insert_link_rejects_a_newline_destination() {
        let mut ed = Editor::new_str("w\n", Format::Djot).expect("editor");
        assert_eq!(ed.insert_link(0, 1, "a\nb"), Err(Error::InvalidArgument));

        let mut xml = Editor::new_str("<a>hi</a>", Format::Xml).expect("editor");
        assert_eq!(xml.insert_link(3, 5, "u"), Err(Error::UnsupportedFormat));
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
