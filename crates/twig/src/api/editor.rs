//! [`Editor`] — the span-splice editor and its authoring gestures. Port of the
//! `twig_editor_*` half of `src/c_abi.zig` over `ast::editor::Editor`: what is
//! left at this layer is the locator resolution, the error map and the
//! `Change` read-back.

use std::marker::PhantomData;
use std::ops::Range;

use crate::ast::editor::{self as engine_editor, Editor as EngineEditor};
use crate::ast::ops as engine_ops;
use crate::ast::splicer::{self, ParseError, Placement};
use crate::ast::{filter, locator};
use crate::error::Error;
use crate::format as reg;
use crate::span::Span;

use super::builder::key_vals;
use super::document::{self as read, Alignment, Document, DocumentView, FlatNode, QueryMatch};
use super::format::{config_from_flags, BlockContainerKind, BlockKind, Format, InlineKind, MarkColor};
use super::NodeId;

/// The byte-level effect of an [`Editor`] edit: `old` is the range of the
/// pre-edit source that was replaced, `new` the range the replacement now
/// occupies in the post-edit source (they share a start).
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

    fn from_engine(c: splicer::Change) -> Change {
        Change { old: c.old.start..c.old.end, new: c.new.start..c.new.end }
    }

    fn empty() -> Change {
        Change { old: 0..0, new: 0..0 }
    }
}

/// One step of an edit, read against the source from its start: an edit is a
/// list of these over the whole text, rather than a span and the string that
/// replaces it. Whatever the ops do not reach is kept.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum Op {
    /// Keep the next `n` bytes.
    Retain(usize),
    /// Write this text here.
    Insert(String),
    /// Remove the next `n` bytes.
    Delete(usize),
}

impl Op {
    /// The fewest ops that turn `old` into `new`, cut between characters:
    /// Myers' diff over characters, and past 512 edits one splice of what
    /// lies between the two texts' common prefix and suffix.
    pub fn diff(old: &str, new: &str) -> Vec<Op> {
        engine_ops::diff(old.as_bytes(), new.as_bytes())
            .iter()
            .map(|op| Op::from_engine(op).expect("a diff of two strings cuts between characters"))
            .collect()
    }

    /// `text` with `ops` applied. [`Error::InvalidArgument`] when they read
    /// past its end or put a position inside a character.
    pub fn apply(text: &str, ops: &[Op]) -> Result<String, Error> {
        check_ops(text.as_bytes(), ops)?;
        let ops: Vec<engine_ops::Op> = ops.iter().map(Op::to_engine).collect();
        let out = engine_ops::apply(text.as_bytes(), &ops).ok_or(Error::InvalidArgument)?;
        String::from_utf8(out).map_err(|_| Error::InvalidArgument)
    }

    /// The one list of ops, in their one spelling, that does `first` to
    /// `text` and then `then`, where `then` reads the text `first` made — a
    /// run of edits sent as one. [`Error::InvalidArgument`] when either does
    /// not fit the text it reads, as [`Op::apply`] would refuse it.
    pub fn compose(text: &str, first: &[Op], then: &[Op]) -> Result<Vec<Op>, Error> {
        // Only the text `first` made shows whether `then` cuts a character,
        // whether `first` inserted it or kept it.
        check_ops(Op::apply(text, first)?.as_bytes(), then)?;
        let first: Vec<engine_ops::Op> = first.iter().map(Op::to_engine).collect();
        let then: Vec<engine_ops::Op> = then.iter().map(Op::to_engine).collect();
        engine_ops::compose(&first, &then).iter().map(|op| Op::from_engine(op).ok_or(Error::InvalidArgument)).collect()
    }

    fn to_engine(&self) -> engine_ops::Op {
        match self {
            Op::Retain(n) => engine_ops::Op::Retain(*n),
            Op::Insert(t) => engine_ops::Op::Insert(t.as_bytes().to_vec()),
            Op::Delete(n) => engine_ops::Op::Delete(*n),
        }
    }

    fn from_engine(op: &engine_ops::Op) -> Option<Op> {
        Some(match op {
            engine_ops::Op::Retain(n) => Op::Retain(*n),
            engine_ops::Op::Insert(t) => Op::Insert(String::from_utf8(t.clone()).ok()?),
            engine_ops::Op::Delete(n) => Op::Delete(*n),
        })
    }
}

/// Whether `ops` fit `src`: they read no further than its end, and every
/// position they reach lies between two characters.
fn check_ops(src: &[u8], ops: &[Op]) -> Result<(), Error> {
    let on_boundary = |at: usize| at == src.len() || (at < src.len() && src[at] & 0xC0 != 0x80);
    let mut at = 0usize;
    for op in ops {
        if !on_boundary(at) {
            return Err(Error::InvalidArgument);
        }
        if let Op::Retain(n) | Op::Delete(n) = op {
            at = at.checked_add(*n).ok_or(Error::InvalidArgument)?;
        }
    }
    if on_boundary(at) { Ok(()) } else { Err(Error::InvalidArgument) }
}

/// A span-splice editor over a document: lossless, in-place edits, reparsed
/// after each one. A failed edit leaves the document unchanged.
#[derive(Debug)]
pub struct Editor {
    editor: EngineEditor,
}

/// `statusOfEditorError`.
fn editor_error(e: engine_editor::Error) -> Error {
    use engine_editor::Error as E;
    match e {
        E::InvalidRange
        | E::InvalidLevel
        | E::InvalidDestination
        | E::InvalidLanguage
        | E::InvalidLabel
        | E::InvalidColor
        | E::InvalidShape
        | E::InvalidName
        | E::InvalidAttribute
        | E::InvalidFormula
        | E::InvalidArgument => Error::InvalidArgument,
        E::UnsupportedFormat => Error::UnsupportedFormat,
        E::NoBlock => Error::NotFound,
        E::NotEditable => Error::NotEditable,
        E::EditConflict => Error::EditConflict,
    }
}

/// `statusOfLocatorError`.
fn locator_error(e: locator::Error) -> Error {
    match e {
        locator::Error::InvalidLocator => Error::InvalidArgument,
        locator::Error::NotFound => Error::NotFound,
        locator::Error::Ambiguous => Error::Ambiguous,
    }
}

/// `statusOfSplicerError`: anything not named is the parser rejecting the
/// edited document, already rolled back.
fn splicer_error(e: splicer::Error) -> Error {
    match e {
        splicer::Error::NoNodeSpan | splicer::Error::NoContentSpan | splicer::Error::NotAContainer => {
            Error::NotEditable
        }
        splicer::Error::OverlappingNodes => Error::InvalidArgument,
        _ => Error::EditConflict,
    }
}

impl Editor {
    /// Create an editor over a private copy of `input`, parsed as `format`
    /// with default options.
    pub fn new(input: &[u8], format: Format) -> Result<Self, Error> {
        Self::create(input, format, 0)
    }

    pub fn new_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::new(input.as_bytes(), format)
    }

    /// Like [`Editor::new`], with the features `flags` names laid over the
    /// row's own — for the reparse after every edit and for what the
    /// gestures may write. Bit `i` is the language's `i`th feature
    /// ([`Format::feature_flags`]).
    pub fn new_with_flags(input: &[u8], format: Format, flags: u32) -> Result<Self, Error> {
        Self::create(input, format, flags)
    }

    /// Like [`Editor::new`], with `features` laid over the row's own.
    pub fn new_with_features(input: &[u8], format: Format, features: &[&str]) -> Result<Self, Error> {
        let flags = format.feature_flags(features)?;
        Self::create(input, format, flags)
    }

    /// `twig_editor_create_ext`: the parser and the spelling come from the
    /// same registry row under the same config, so a gesture writes exactly
    /// what the editor's own reparse reads back.
    fn create(input: &[u8], format: Format, flags: u32) -> Result<Self, Error> {
        let fmt = format.resolve()?;
        let (fmt, cfg) = reg::resolve_as_asked(fmt, &config_from_flags(fmt, flags), input);
        let parse: splicer::ParseFn =
            Box::new(move |src: &[u8]| reg::parse_to_ast(fmt, &cfg, src).map_err(|e| ParseError::new(e.name())));
        let syntax = reg::syntax_for_config(fmt, &cfg);
        let mut editor = EngineEditor::new(input, parse, syntax).map_err(|_| Error::ParseError)?;
        // An edit reparses only the blocks it touched, where the format can.
        editor
            .splicer
            .set_fragment_parser(Some(Box::new(move |src: &[u8], range: Range<usize>, doc: &crate::document::Document| {
                reg::parse_fragment(fmt, &cfg, src, range, doc)
            })));
        Ok(Editor { editor })
    }

    fn splicer(&mut self) -> &mut splicer::Splicer {
        &mut self.editor.splicer
    }

    /// `applyEdit`: resolve `locator` against the current tree and run `op`.
    fn apply_located(
        &mut self,
        locator: &str,
        op: impl FnOnce(&mut splicer::Splicer, crate::ast::NodeId) -> Result<(), splicer::Error>,
    ) -> Result<(), Error> {
        let id = locator::resolve(&self.editor.splicer.doc, locator.as_bytes()).map_err(locator_error)?;
        op(self.splicer(), id).map_err(splicer_error)
    }

    /// Replace the whole source of the located node with `text`.
    pub fn replace(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.replace_node_by_id(id, text.as_bytes()))
    }

    /// Replace the interior of the located container.
    pub fn replace_content(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.replace_content_by_id(id, text.as_bytes()))
    }

    /// Insert `text` immediately before the located node.
    pub fn insert_before(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.insert_before_by_id(id, text.as_bytes()))
    }

    /// Insert `text` immediately after the located node.
    pub fn insert_after(&mut self, locator: &str, text: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.insert_after_by_id(id, text.as_bytes()))
    }

    /// Insert `text` as the `index`-th child of the located container (an
    /// index at or past the child count appends).
    pub fn insert_child(&mut self, locator: &str, index: usize, text: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.insert_child_by_id(id, index, text.as_bytes()))
    }

    /// Delete the located node (exactly its span).
    pub fn delete(&mut self, locator: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.delete_node_by_id(id))
    }

    /// Delete the located node, tidying surrounding blank lines for a
    /// whole-line node.
    pub fn delete_smart(&mut self, locator: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.delete_node_smart_by_id(id))
    }

    /// Unwrap the located node: replace it with its interior.
    pub fn unwrap_node(&mut self, locator: &str) -> Result<(), Error> {
        self.apply_located(locator, |s, id| s.unwrap_node_by_id(id))
    }

    fn move_node(&mut self, locator: &str, anchor: &str, place: Placement) -> Result<(), Error> {
        let doc = &self.editor.splicer.doc;
        let id = locator::resolve(doc, locator.as_bytes()).map_err(locator_error)?;
        let target = locator::resolve(doc, anchor.as_bytes()).map_err(locator_error)?;
        self.splicer().move_node_by_id(id, target, place).map_err(splicer_error)
    }

    /// Move the node `locator` names to immediately before the node `anchor`
    /// names, in one splice and one undo step.
    pub fn move_before(&mut self, locator: &str, anchor: &str) -> Result<(), Error> {
        self.move_node(locator, anchor, Placement::Before)
    }

    /// Move the node `locator` names to immediately after the node `anchor`
    /// names.
    pub fn move_after(&mut self, locator: &str, anchor: &str) -> Result<(), Error> {
        self.move_node(locator, anchor, Placement::After)
    }

    /// Prune the document in place: remove every node matching `drop` except
    /// those also matching `keep`, then — if `unwrap_kept` — unwrap the
    /// survivors.
    pub fn filter(&mut self, drop: &str, keep: Option<&str>, unwrap_kept: bool) -> Result<(), Error> {
        let options = filter::Options { drop: drop.as_bytes(), keep: keep.map(str::as_bytes), unwrap_kept };
        filter::apply(self.splicer(), &options).map_err(|e| match e {
            filter::Error::InvalidSelector => Error::InvalidArgument,
            filter::Error::FilterDidNotConverge => Error::Internal,
            filter::Error::Edit(splicer::Error::NoNodeSpan | splicer::Error::NoContentSpan) => Error::NotEditable,
            filter::Error::Edit(_) => Error::EditConflict,
        })
    }

    /// The editor's current (edited) source bytes.
    pub fn source(&mut self) -> Result<Vec<u8>, Error> {
        Ok(self.editor.source_bytes().to_vec())
    }

    /// The editor's current source bytes as a UTF-8 string.
    pub fn source_str(&mut self) -> Result<String, Error> {
        String::from_utf8(self.source()?).map_err(|_| Error::Internal)
    }

    /// The editor's current tree as pretty-printed JSON.
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        Ok(crate::ast::json::encode(self.editor.doc()))
    }

    /// Resolve a selector against the editor's current tree.
    pub fn query(&mut self, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        read::query_matches(self.editor.doc(), selector)
    }

    // ── offset-addressed editing & read-back ────────────────────────────────

    /// Splice `[start, end)` of the current source with `text`, reparse, and
    /// return the [`Change`]. A reparse-breaking edit is rolled back and
    /// returns [`Error::EditConflict`].
    pub fn edit_range(&mut self, start: usize, end: usize, text: &str) -> Result<Change, Error> {
        if start > end || end > self.editor.source_bytes().len() {
            return Err(Error::InvalidArgument);
        }
        self.splicer().splice(Span::new(start, end), text.as_bytes()).map_err(|_| Error::EditConflict)?;
        Ok(self.last_or_empty())
    }

    /// Apply `ops` to the current source as one edit: one reparse and one
    /// undo step, however many places they change. The [`Change`] spans the
    /// first byte they touch to the last. Ops that read past the end, or put a
    /// position inside a UTF-8 character, are [`Error::InvalidArgument`]; a
    /// reparse-breaking edit is rolled back and returns
    /// [`Error::EditConflict`].
    pub fn apply(&mut self, ops: &[Op]) -> Result<Change, Error> {
        check_ops(self.editor.source_bytes(), ops)?;
        let ops: Vec<engine_ops::Op> = ops.iter().map(Op::to_engine).collect();
        self.splicer().apply(&ops).map_err(splicer_error)?;
        Ok(self.last_or_empty())
    }

    /// What the last successful edit, undo or redo did, as ops against the
    /// source before it: the fewest that make a gesture's change, exactly the
    /// span asked for [`Editor::edit_range`]. In one spelling: no op of zero
    /// length, no two of a kind side by side, an insert before a delete at
    /// one place, and no retain at the end. Empty before the first edit.
    /// [`Error::Internal`] when the text they insert is not UTF-8, as
    /// [`Editor::source_str`] reports.
    pub fn last_ops(&mut self) -> Result<Vec<Op>, Error> {
        self.editor.splicer.last_ops.iter().map(|op| Op::from_engine(op).ok_or(Error::Internal)).collect()
    }

    /// The byte effect of the last successful edit, or `None` before the
    /// first.
    pub fn last_change(&mut self) -> Option<Change> {
        self.editor.last_change().map(Change::from_engine)
    }

    fn last_or_empty(&self) -> Change {
        self.editor.last_change().map(Change::from_engine).unwrap_or_else(Change::empty)
    }

    /// Undo the last edit step; `None` when there's nothing to undo.
    pub fn undo(&mut self) -> Result<Option<Change>, Error> {
        let c = self.splicer().undo().map_err(|_| Error::EditConflict)?;
        Ok(c.map(Change::from_engine))
    }

    /// Redo the most recently undone edit step; `None` when there is none.
    pub fn redo(&mut self) -> Result<Option<Change>, Error> {
        let c = self.splicer().redo().map_err(|_| Error::EditConflict)?;
        Ok(c.map(Change::from_engine))
    }

    /// Fold the most recent edit into the undo step before it.
    pub fn coalesce_last_undo(&mut self) -> Result<(), Error> {
        self.splicer().coalesce_last_undo();
        Ok(())
    }

    /// Turn the undo history on or off; it is on in a new editor. Off drops
    /// every step, and edits record none: [`Editor::undo`] and
    /// [`Editor::redo`] return `None`. For a host that keeps its own history
    /// from [`Editor::last_ops`].
    pub fn set_history(&mut self, keep: bool) {
        self.splicer().set_history(keep);
    }

    /// Whether edits record undo steps.
    pub fn keeps_history(&mut self) -> bool {
        self.editor.splicer.keeps_history()
    }

    /// A monotonic change token, bumped once per successful mutation.
    pub fn revision(&mut self) -> u64 {
        self.editor.splicer.revision
    }

    /// The cumulative dirty byte range since the last
    /// [`Editor::clear_dirty`], or `None` when clean.
    pub fn dirty_range(&mut self) -> Option<Range<usize>> {
        self.editor.splicer.dirty_range().map(|s| s.start..s.end)
    }

    /// Acknowledge the current dirty range.
    pub fn clear_dirty(&mut self) {
        self.splicer().clear_dirty();
    }

    /// Attach an opaque caret blob to the current document state.
    pub fn set_caret_blob(&mut self, blob: &[u8]) -> Result<(), Error> {
        self.splicer().set_caret(blob);
        Ok(())
    }

    /// The opaque caret blob for the current document state.
    pub fn caret_blob(&mut self) -> Result<Vec<u8>, Error> {
        Ok(self.editor.splicer.caret_blob().to_vec())
    }

    /// The editor's current tree as a borrowed [`Document`].
    pub fn document(&mut self) -> Result<DocumentView<'_>, Error> {
        Ok(DocumentView { doc: Document::borrowed(self.editor.doc().clone()), _editor: PhantomData })
    }

    /// Snapshot the current tree as a flat [`FlatNode`] array.
    pub fn nodes(&mut self) -> Result<Vec<FlatNode>, Error> {
        Ok(read::flat_nodes(self.editor.doc()))
    }

    /// The direct children of `node` — `None` enumerates the root's.
    pub fn child_spans(&mut self, node: Option<NodeId>) -> Result<Vec<QueryMatch>, Error> {
        read::children_of(self.editor.doc(), node)
    }

    /// Snapshot the subtree rooted at `node` with *local* ids.
    pub fn subtree(&mut self, node: NodeId) -> Result<Vec<FlatNode>, Error> {
        read::subtree_of(self.editor.doc(), node)
    }

    /// The deepest node whose span contains byte `offset`.
    pub fn node_at(&mut self, offset: usize) -> Result<Option<QueryMatch>, Error> {
        read::node_at(self.editor.doc(), offset)
    }

    /// The chain of nodes containing byte `offset`, root-first.
    pub fn ancestors_at(&mut self, offset: usize) -> Result<Vec<QueryMatch>, Error> {
        read::ancestors_at(self.editor.doc(), offset)
    }

    // ── gestures ────────────────────────────────────────────────────────────

    /// Run a gesture and read back the change it made (`.?` in Zig: every
    /// successful gesture but the documented no-ops leaves one).
    fn gesture(&mut self, op: impl FnOnce(&mut EngineEditor) -> Result<(), engine_editor::Error>) -> Result<Change, Error> {
        op(&mut self.editor).map_err(editor_error)?;
        Ok(self.last_or_empty())
    }

    /// Wrap `[start, end)` with `kind`'s delimiters.
    pub fn wrap_range(&mut self, start: usize, end: usize, kind: InlineKind) -> Result<Change, Error> {
        self.gesture(|e| e.wrap_range(Span::new(start, end), kind.to_engine()))
    }

    /// Toggle `kind` over `[start, end)`.
    pub fn toggle_inline(&mut self, start: usize, end: usize, kind: InlineKind) -> Result<Change, Error> {
        self.gesture(|e| e.toggle_inline(Span::new(start, end), kind.to_engine()))
    }

    /// Set — or clear, with `None` — the colour of the highlight the caret at
    /// `offset` is inside.
    pub fn set_mark_color(&mut self, offset: usize, color: Option<MarkColor>) -> Result<Change, Error> {
        self.gesture(|e| e.set_mark_color(offset, color.map(|c| c.as_str().as_bytes())))
    }

    /// Convert the innermost heading/paragraph covering `offset` to `kind`.
    pub fn set_block(&mut self, offset: usize, kind: BlockKind) -> Result<Change, Error> {
        let (k, level) = match kind {
            BlockKind::Paragraph => (engine_editor::BlockKind::Paragraph, 0),
            BlockKind::Heading(l) => (engine_editor::BlockKind::Heading, l),
        };
        self.gesture(|e| e.set_block(offset, k, level))
    }

    /// Toggle a block container over the blocks `[start, end)` covers.
    pub fn toggle_block_container(&mut self, start: usize, end: usize, kind: BlockContainerKind) -> Result<Change, Error> {
        self.gesture(|e| e.toggle_block_container(Span::new(start, end), kind.to_engine()))
    }

    /// Renumber the ordered list at `offset` so its markers run `1, 2, 3, …`.
    pub fn renumber_ordered_lists(&mut self, offset: usize) -> Result<(), Error> {
        self.gesture(|e| e.renumber_ordered_lists(offset))?;
        Ok(())
    }

    /// Insert an empty row below (`below`) or above the caret's row.
    pub fn table_insert_row(&mut self, offset: usize, below: bool) -> Result<(), Error> {
        self.gesture(|e| e.table_insert_row(offset, below)).map(drop)
    }

    /// Delete the caret's row.
    pub fn table_delete_row(&mut self, offset: usize) -> Result<(), Error> {
        self.gesture(|e| e.table_delete_row(offset)).map(drop)
    }

    /// Insert an empty column right (`right`) or left of the caret's column.
    pub fn table_insert_column(&mut self, offset: usize, right: bool) -> Result<(), Error> {
        self.gesture(|e| e.table_insert_column(offset, right)).map(drop)
    }

    /// Delete the caret's column.
    pub fn table_delete_column(&mut self, offset: usize) -> Result<(), Error> {
        self.gesture(|e| e.table_delete_column(offset)).map(drop)
    }

    /// Set the caret's column to `alignment`.
    pub fn table_set_alignment(&mut self, offset: usize, alignment: Alignment) -> Result<(), Error> {
        self.gesture(|e| e.table_set_alignment(offset, alignment.to_engine())).map(drop)
    }

    /// Move the caret's row one place down (`down`) or up.
    pub fn table_move_row(&mut self, offset: usize, down: bool) -> Result<(), Error> {
        self.gesture(|e| e.table_move_row(offset, down)).map(drop)
    }

    /// Move the caret's column one place right (`right`) or left.
    pub fn table_move_column(&mut self, offset: usize, right: bool) -> Result<(), Error> {
        self.gesture(|e| e.table_move_column(offset, right)).map(drop)
    }

    /// Insert a fresh table after the block `offset` sits in.
    pub fn insert_table(&mut self, offset: usize, rows: usize, cols: usize) -> Result<Change, Error> {
        self.gesture(|e| e.insert_table(offset, rows, cols))
    }

    /// Insert a **leaf directive** as its own block after the block `offset`
    /// sits in.
    pub fn insert_directive(
        &mut self,
        offset: usize,
        name: &str,
        label: Option<&str>,
        attrs: &[(&str, Option<&str>)],
    ) -> Result<Change, Error> {
        let entries = key_vals(attrs);
        self.gesture(|e| e.insert_directive(offset, name.as_bytes(), label.map(str::as_bytes), &entries))
    }

    /// Replace the attribute set of the block `offset` sits in.
    pub fn set_block_attrs(&mut self, offset: usize, attrs: &[(&str, Option<&str>)]) -> Result<Change, Error> {
        let entries = key_vals(attrs);
        self.gesture(|e| e.set_block_attrs(offset, &entries))
    }

    /// Replace the attribute set of the element `node`.
    pub fn set_node_attrs(&mut self, node: NodeId, attrs: &[(&str, Option<&str>)]) -> Result<Change, Error> {
        let entries = key_vals(attrs);
        self.gesture(|e| e.set_node_attrs(node.0, &entries))
    }

    /// Wrap `[start, end)` in an anonymous inline container carrying `attrs`,
    /// or re-style the span already there.
    pub fn wrap_range_attrs(&mut self, start: usize, end: usize, attrs: &[(&str, Option<&str>)]) -> Result<Change, Error> {
        let entries = key_vals(attrs);
        self.gesture(|e| e.wrap_range_attrs(Span::new(start, end), &entries))
    }

    /// Link `[start, end)` to `destination`, or re-point the link there.
    pub fn insert_link(&mut self, start: usize, end: usize, destination: &str) -> Result<Change, Error> {
        self.gesture(|e| e.insert_link(Span::new(start, end), destination.as_bytes()))
    }

    /// Spell `[start, end)` as an image pointing at `destination`.
    pub fn insert_image(&mut self, start: usize, end: usize, destination: &str) -> Result<Change, Error> {
        self.gesture(|e| e.insert_image(Span::new(start, end), destination.as_bytes()))
    }

    /// Insert `text` at `offset` as a literal run.
    pub fn insert_literal(&mut self, offset: usize, text: &str) -> Result<Change, Error> {
        self.gesture(|e| e.insert_literal(offset, text.as_bytes()))
    }

    /// Insert a hard line break inside a table cell at `offset`.
    pub fn insert_line_break(&mut self, offset: usize) -> Result<Change, Error> {
        self.gesture(|e| e.insert_line_break(offset))
    }

    /// Insert a thematic break after the block `offset` sits in.
    pub fn insert_thematic_break(&mut self, offset: usize) -> Result<Change, Error> {
        self.gesture(|e| e.insert_thematic_break(offset))
    }

    /// Split the block at `offset` in two at the caret.
    pub fn split_block(&mut self, offset: usize) -> Result<Change, Error> {
        self.gesture(|e| e.split_block(offset))
    }

    /// Join the block at `offset` into the block before it.
    pub fn join_blocks(&mut self, offset: usize) -> Result<Change, Error> {
        self.gesture(|e| e.join_blocks(offset))
    }

    /// Move the block at `from` to the boundary `to` names.
    pub fn move_block(&mut self, from: usize, to: usize) -> Result<Change, Error> {
        self.gesture(|e| e.move_block(from, to))
    }

    /// Fence the blocks `[start, end)` covers as a code block, or unfence the
    /// one the caret is in.
    pub fn toggle_code_block(&mut self, start: usize, end: usize, language: Option<&str>) -> Result<Change, Error> {
        self.gesture(|e| e.toggle_code_block(Span::new(start, end), language.map(str::as_bytes)))
    }

    /// Retag the code block at `offset` with `language`, or clear it.
    pub fn set_code_language(&mut self, offset: usize, language: Option<&str>) -> Result<Change, Error> {
        self.gesture(|e| e.set_code_language(offset, language.map(str::as_bytes)))
    }

    /// Add a checkbox to the list item at `offset`, or take one away.
    pub fn toggle_task_item(&mut self, offset: usize) -> Result<Change, Error> {
        self.gesture(|e| e.toggle_task_item(offset))
    }

    /// Tick or untick the task item at `offset`.
    pub fn set_task_checked(&mut self, offset: usize, checked: bool) -> Result<(), Error> {
        self.gesture(|e| e.set_task_checked(offset, checked)).map(drop)
    }

    /// Flip the task item at `offset`.
    pub fn toggle_task_checked(&mut self, offset: usize) -> Result<Change, Error> {
        self.gesture(|e| e.toggle_task_checked(offset))
    }

    /// Insert a footnote reference at `offset` and, unless the label is
    /// already defined, its definition at the end of the document.
    pub fn insert_footnote(&mut self, offset: usize, label: &str) -> Result<Change, Error> {
        self.gesture(|e| e.insert_footnote(offset, label.as_bytes()))
    }

    /// Insert `formula` at `offset` as an inline formula.
    pub fn insert_inline_math(&mut self, offset: usize, formula: &str) -> Result<Change, Error> {
        self.gesture(|e| e.insert_inline_math(offset, formula.as_bytes()))
    }

    /// Insert `formula` as a display formula after the block `offset` sits in.
    pub fn insert_display_math(&mut self, offset: usize, formula: &str) -> Result<Change, Error> {
        self.gesture(|e| e.insert_display_math(offset, formula.as_bytes()))
    }

    /// Make the paragraphs `start..end` touches a verse, or a verse back into
    /// paragraphs.
    pub fn toggle_line_block(&mut self, start: usize, end: usize) -> Result<Change, Error> {
        self.gesture(|e| e.toggle_line_block(start, end))
    }
}
