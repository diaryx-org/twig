//! The span-splice editor — Twig's reason for existing: precise, LOSSLESS
//! in-place edits to a document, driven by the AST's byte spans. Port of
//! `src/ast/splicer.zig`.
//!
//! ── The one primitive ──────────────────────────────────────────────────────
//! Everything reduces to `apply_checked(ops)`: build a new source buffer that
//! is the old bytes with the [`Op`]s applied — retain, insert and delete, read
//! from the start — reparse it, and — only if the reparse succeeds — swap it
//! in. On reparse failure the edit is abandoned and the editor is left exactly
//! as it was. Bytes the ops retain are copied verbatim and never reflow.
//!
//! `replace_at_span(span, replacement)` is how the gestures reach it: it
//! writes the FEWEST ops that turn the span's bytes into `replacement`
//! ([`ops::diff`]), so wrapping a word in `**` is two inserts and the word
//! retained, not the word deleted and written again. `splice` is the literal
//! one — the whole span deleted, the whole replacement inserted — for a
//! caller who said exactly which bytes go. [`Splicer::last_ops`] is what the
//! last edit did, as ops.
//!
//! ── The reparse ────────────────────────────────────────────────────────────
//! A whole parse costs the size of the document, a keystroke the size of its
//! block. With a fragment parser ([`Splicer::set_fragment_parser`], which the
//! API's `Editor` sets for every format whose language has one) an unchecked
//! edit reparses only the blocks it touched and splices them into the tree it
//! had, wherever that is shown to give the tree a whole parse would
//! ([`reparse`]); everywhere else, and for an edit a [`Check`] reads, it
//! parses the whole document as before. Either way the tree is the same.
//!
//! ── History ────────────────────────────────────────────────────────────────
//! An undo step is the inverse ops of its edit and the host's caret blob, not
//! a copy of the source. History can be turned off (`set_history(false)`) for
//! a host that keeps its own.
//!
//! ── Language-agnostic by construction ──────────────────────────────────────
//! The splicer holds only source bytes plus a [`ParseFn`] (source ->
//! `Document`), so the same engine edits djot, Markdown, or XML — the caller
//! (the format registry) supplies the right parser, configured however the
//! document was first parsed.
//!
//! ── Honest limits ──────────────────────────────────────────────────────────
//!   - `replace_content`/`insert_child`-into-empty need a container's
//!     interior offset (`content_span`); a node without one is
//!     `NoContentSpan`.
//!   - Payload fields (a link's destination) have no sub-node span; editing
//!     one means `replace_node` on the whole node's source.
//!   - `delete_node` removes exactly the node's span; `delete_node_smart` is
//!     the block-aware variant that tidies the surrounding blank lines.

use std::fmt;

use crate::ast::ops::{self, Op};
use crate::ast::reparse::{self, FragmentFn};
use crate::ast::{Ast, KindRef, NodeId, Tag};
use crate::document::Document;
use crate::span::Span;

/// Cap on retained undo steps, bounding history memory over a long session.
pub const MAX_UNDO: usize = 200;

/// The tag half of `Kind` — what a caller names a kind by without its payload.
pub type KindTag = Tag;

/// Why a reparse refused the edited source — the parser's own error, by name
/// (Zig's `@errorName`, e.g. `MismatchedCloseTag`), which is what the CLI
/// reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub name: String,
}

impl ParseError {
    pub fn new(name: impl Into<String>) -> ParseError {
        ParseError { name: name.into() }
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.name)
    }
}

/// Source -> a freshly parsed `Document`. Boxed so the caller can pick the
/// language at run time and close over its parse configuration (Zig's
/// `ParseFn` + opaque `ctx`): an edited Markdown document reparses with the
/// SAME extension flags it was first parsed with.
pub type ParseFn = Box<dyn Fn(&[u8]) -> Result<Document, ParseError>>;

/// Everything a splice can fail with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// The node's span is the unset `(0,0)`.
    NoNodeSpan,
    /// The node has no interior (`content_span`).
    NoContentSpan,
    /// A text leaf (e.g. `code_block`) has no child sequence to insert into.
    NotAContainer,
    /// `move_node`'s two nodes are the same, or one holds the other.
    OverlappingNodes,
    /// A [`Check`] refused the reparse; nothing changed.
    Rejected,
    /// An index path past the tree.
    PathOutOfBounds,
    /// Ops that read past the end of the source.
    OutOfRange,
    /// The reparse failed; nothing changed.
    Parse(ParseError),
}

impl Error {
    /// The Zig error name (`@errorName`).
    pub fn name(&self) -> &str {
        match self {
            Error::NoNodeSpan => "NoNodeSpan",
            Error::NoContentSpan => "NoContentSpan",
            Error::NotAContainer => "NotAContainer",
            Error::OverlappingNodes => "OverlappingNodes",
            Error::Rejected => "Rejected",
            Error::PathOutOfBounds => "PathOutOfBounds",
            Error::OutOfRange => "OutOfRange",
            Error::Parse(p) => &p.name,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl std::error::Error for Error {}

/// What the most recent successful edit did to the source. `old` is the range
/// of the pre-edit source that was replaced; `new` the range the replacement
/// now occupies in the post-edit source (they share a start).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Change {
    pub old: Span,
    pub new: Span,
}

/// One history step: the ops that lead from the current state to the one the
/// step restores, plus the opaque caret blob the host associated with THAT
/// state. On the undo stack they are an edit's inverse; on the redo stack, an
/// undo's.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HistoryEntry {
    pub ops: Vec<Op>,
    pub caret: Vec<u8>,
}

/// A caller's test of the reparse: whether the edited document is the one it
/// meant to write.
pub type Check<'a> = &'a dyn Fn(&Document) -> bool;

/// What a removal replaces, and with what: `span` goes, `interior` (bytes of
/// the current source, copied) takes its place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Strip {
    pub span: Span,
    pub interior: Vec<u8>,
}

/// Where `move_node` puts the node relative to its anchor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    Before,
    After,
}

pub struct Splicer {
    /// The current (edited) document bytes.
    source: Vec<u8>,
    /// The parse of `source` as of the last successful edit.
    pub doc: Document,
    parse_fn: ParseFn,
    /// Reparses only the blocks an edit touched, where the format can; see
    /// [`Splicer::set_fragment_parser`].
    fragment_fn: Option<FragmentFn>,
    /// Whether every attribute of `doc` belongs to a node, once worked out
    /// ([`reparse::attrs_dense`]); `None` after a whole parse.
    attrs_dense: Option<bool>,
    /// The byte-level effect of the last successful splice (or undo/redo), or
    /// `None` before the first edit. A failed edit leaves it untouched.
    pub last_change: Option<Change>,
    /// The last successful edit (or undo/redo) as canonical ops against the
    /// source before it; empty before the first. A failed edit leaves it
    /// untouched.
    pub last_ops: Vec<Op>,
    /// Undo/redo history as inverse ops, each tagged with a caret blob.
    pub undo_stack: Vec<HistoryEntry>,
    pub redo_stack: Vec<HistoryEntry>,
    /// Whether edits record undo steps. Off, both stacks stay empty.
    history: bool,
    /// An opaque, host-owned blob describing the caret for the CURRENT
    /// source state — never read, only stored and handed back.
    current_caret: Vec<u8>,
    /// Monotonic change token, bumped once per successful mutation.
    pub revision: u64,
    /// The cumulative byte range changed since the last `clear_dirty`, in
    /// CURRENT source coordinates — conservative: it may over-cover, never
    /// under-cover.
    dirty: Option<Span>,
}

impl fmt::Debug for Splicer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Splicer").field("source", &String::from_utf8_lossy(&self.source)).field("revision", &self.revision).finish()
    }
}

impl Splicer {
    /// Parse `source_bytes` and build an editor over a private copy of them.
    pub fn new(source_bytes: &[u8], parse_fn: ParseFn) -> Result<Splicer, ParseError> {
        let source = source_bytes.to_vec();
        let doc = parse_fn(&source)?;
        Ok(Splicer {
            source,
            doc,
            parse_fn,
            fragment_fn: None,
            attrs_dense: None,
            last_change: None,
            last_ops: Vec::new(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            history: true,
            current_caret: Vec::new(),
            revision: 0,
            dirty: None,
        })
    }

    /// The current edited document bytes.
    pub fn source_bytes(&self) -> &[u8] {
        &self.source
    }

    /// The current parse (valid until the next successful edit).
    pub fn ast_view(&self) -> &Ast {
        &self.doc.ast
    }

    /// Reparse `source` with this splicer's parser — what a gesture that
    /// checks a candidate print uses.
    pub fn reparse(&self, source: &[u8]) -> Result<Document, ParseError> {
        (self.parse_fn)(source)
    }

    /// Have an edit reparse only the blocks it touched, through `fragment`
    /// (the format's [`twig_kit::Language::parse_fragment`] under this
    /// splicer's parse configuration), and the whole document only where
    /// that cannot be shown to give the same tree ([`reparse`]). `None`
    /// reparses the whole document after every edit, as before.
    pub fn set_fragment_parser(&mut self, fragment: Option<FragmentFn>) {
        self.fragment_fn = fragment;
    }

    /// Bring `self.doc` up to date with `new_src` by reparsing only what
    /// `change` touched. `false`, with nothing changed, when it cannot.
    fn reparse_in_place(&mut self, new_src: &[u8], change: Change) -> bool {
        let Some(fragment) = &self.fragment_fn else { return false };
        let edit = reparse::Edit { start: change.old.start, old_end: change.old.end, new_end: change.new.end };
        change.old.start == change.new.start
            && reparse::reparse(&mut self.doc, new_src, edit, fragment.as_ref(), &mut self.attrs_dense)
    }

    /// Associate an opaque `blob` with the current document state. An empty
    /// blob clears the current caret.
    pub fn set_caret(&mut self, blob: &[u8]) {
        self.current_caret.clear();
        self.current_caret.extend_from_slice(blob);
    }

    /// The opaque caret blob for the CURRENT document state.
    pub fn caret_blob(&self) -> &[u8] {
        &self.current_caret
    }

    // ── the primitive ──────────────────────────────────────────────────────

    /// Apply `ops` to the source, reparse, and swap in the result, as one
    /// undo step. `OutOfRange` when they read past the end; on reparse
    /// failure nothing changes. The `Change` is the span from the first byte
    /// they touch to the last ([`ops::bounds`]).
    pub fn apply(&mut self, ops: &[Op]) -> Result<(), Error> {
        self.apply_checked(ops, None)
    }

    /// `apply`, committed only if `check` accepts the reparse —
    /// `Error::Rejected` otherwise, with nothing changed.
    pub fn apply_checked(&mut self, ops: &[Op], check: Option<Check>) -> Result<(), Error> {
        let change = ops::bounds(ops);
        self.commit(ops, change, check)
    }

    /// Overwrite `[span.start, span.end)` of the source with `replacement`,
    /// reparse, and swap in the result. On reparse failure nothing changes.
    /// The ops recorded are the fewest that make the replacement
    /// ([`ops::diff`]); the `Change` is the span asked.
    pub fn replace_at_span(&mut self, span: Span, replacement: &[u8]) -> Result<(), Error> {
        self.replace_at_span_checked(span, replacement, None)
    }

    /// `replace_at_span`, committed only if `check` accepts the reparse —
    /// `Error::Rejected` otherwise, with nothing changed.
    pub fn replace_at_span_checked(&mut self, span: Span, replacement: &[u8], check: Option<Check>) -> Result<(), Error> {
        assert!(span.start <= span.end);
        assert!(span.end <= self.source.len());
        let mut ops = vec![Op::Retain(span.start)];
        ops.extend(ops::diff(&self.source[span.start..span.end], replacement));
        let change = Change { old: span, new: Span::new(span.start, span.start + replacement.len()) };
        self.commit(&ops, change, check)
    }

    /// `replace_at_span` as asked: the ops recorded delete the whole span and
    /// insert the whole replacement — for a caller (a keystroke, a paste over
    /// a selection) that named exactly which bytes go.
    pub fn splice(&mut self, span: Span, replacement: &[u8]) -> Result<(), Error> {
        if span.start > span.end || span.end > self.source.len() {
            return Err(Error::OutOfRange);
        }
        let change = Change { old: span, new: Span::new(span.start, span.start + replacement.len()) };
        self.commit(&ops::splice(span, replacement), change, None)
    }

    /// The one place the source changes by an edit: apply, reparse, check,
    /// then swap in and record.
    fn commit(&mut self, ops: &[Op], change: Change, check: Option<Check>) -> Result<(), Error> {
        let new_src = ops::apply(&self.source, ops).ok_or(Error::OutOfRange)?;
        // A check reads the reparse before it is kept, so only an unchecked
        // edit reparses in place.
        let new_doc = if check.is_none() && self.reparse_in_place(&new_src, change) {
            None
        } else {
            let new_doc = (self.parse_fn)(&new_src).map_err(Error::Parse)?;
            if let Some(c) = check {
                if !c(&new_doc) {
                    return Err(Error::Rejected);
                }
            }
            Some(new_doc)
        };

        let ops = ops::canonical(ops.iter().cloned());
        if self.history {
            let inverse = ops::invert(&self.source, &ops);
            let old_caret = std::mem::take(&mut self.current_caret);
            self.record_undo(inverse, old_caret);
        } else {
            self.current_caret.clear();
        }
        self.redo_stack.clear();
        if let Some(d) = new_doc {
            self.doc = d;
            self.attrs_dense = None;
        }
        self.source = new_src;
        self.last_ops = ops;
        self.note_change(change);
        Ok(())
    }

    // ── undo / redo ─────────────────────────────────────────────────────────

    fn record_undo(&mut self, ops: Vec<Op>, caret: Vec<u8>) {
        self.undo_stack.push(HistoryEntry { ops, caret });
        if self.undo_stack.len() > MAX_UNDO {
            self.undo_stack.remove(0);
        }
    }

    /// Whether edits record undo steps.
    pub fn keeps_history(&self) -> bool {
        self.history
    }

    /// Turn undo history on or off. Off drops both stacks, and edits record
    /// nothing: `undo` and `redo` find nothing to do, and `coalesce_last_undo`
    /// nothing to merge. For a host that keeps its own history over
    /// [`Splicer::last_ops`].
    pub fn set_history(&mut self, keep: bool) {
        self.history = keep;
        if !keep {
            self.undo_stack.clear();
            self.redo_stack.clear();
        }
    }

    /// Merge the most recent edit into the step before it, so a run of
    /// keystrokes undoes as one. A no-op unless there are two steps to merge.
    pub fn coalesce_last_undo(&mut self) {
        if self.undo_stack.len() < 2 {
            return;
        }
        let last = self.undo_stack.pop().expect("two steps");
        let prev = self.undo_stack.last_mut().expect("two steps");
        // `last` leads back to the state `prev` starts from; together they
        // lead back to `prev`'s state, whose caret `prev` already holds.
        prev.ops = ops::compose(&last.ops, &prev.ops);
    }

    /// Restore the previous edit step, if any. Returns the `Change` (current →
    /// restored), or `None` when there's nothing to undo. A restore the parser
    /// refuses leaves the step where it was.
    pub fn undo(&mut self) -> Result<Option<Change>, ParseError> {
        let Some(target) = self.undo_stack.pop() else { return Ok(None) };
        self.swap_to(target, true).map(Some)
    }

    /// Re-apply the most recently undone step, symmetric to `undo`.
    pub fn redo(&mut self) -> Result<Option<Change>, ParseError> {
        let Some(target) = self.redo_stack.pop() else { return Ok(None) };
        self.swap_to(target, false).map(Some)
    }

    /// Make `target`'s state the current one and push the way back onto the
    /// other stack (redo when undoing). On failure `target` goes back where
    /// it came from.
    fn swap_to(&mut self, target: HistoryEntry, onto_redo: bool) -> Result<Change, ParseError> {
        let Some(new_src) = ops::apply(&self.source, &target.ops) else {
            if onto_redo { &mut self.undo_stack } else { &mut self.redo_stack }.push(target);
            return Err(ParseError::new("OutOfRange"));
        };
        let change = diff_change(&self.source, &new_src);
        let new_doc = if self.reparse_in_place(&new_src, change) {
            None
        } else {
            match (self.parse_fn)(&new_src) {
                Ok(d) => Some(d),
                Err(e) => {
                    if onto_redo { &mut self.undo_stack } else { &mut self.redo_stack }.push(target);
                    return Err(e);
                }
            }
        };
        let outgoing = HistoryEntry {
            ops: ops::invert(&self.source, &target.ops),
            caret: std::mem::replace(&mut self.current_caret, target.caret),
        };
        if onto_redo {
            self.redo_stack.push(outgoing);
        } else {
            self.undo_stack.push(outgoing);
        }
        if let Some(d) = new_doc {
            self.doc = d;
            self.attrs_dense = None;
        }
        self.source = new_src;
        self.last_ops = target.ops;
        self.note_change(change);
        Ok(change)
    }

    // ── change notification ────────────────────────────────────────────────

    fn note_change(&mut self, change: Change) {
        self.accumulate_dirty(change);
        self.last_change = Some(change);
        self.revision += 1;
    }

    /// Fold one edit's `Change` into the running `dirty` interval, in CURRENT
    /// source coordinates.
    fn accumulate_dirty(&mut self, change: Change) {
        let old = change.old;
        let new = change.new;
        let Some(d) = self.dirty else {
            self.dirty = Some(new);
            return;
        };
        let shifted_lo = if d.start <= old.start {
            d.start
        } else if d.start >= old.end {
            d.start - old.len() + new.len()
        } else {
            new.start
        };
        let shifted_hi = if d.end <= old.start {
            d.end
        } else if d.end >= old.end {
            d.end - old.len() + new.len()
        } else {
            new.end
        };
        self.dirty = Some(Span::new(shifted_lo.min(new.start), shifted_hi.max(new.end)));
    }

    /// The cumulative dirty byte range since the last `clear_dirty`.
    pub fn dirty_range(&self) -> Option<Span> {
        self.dirty
    }

    /// Acknowledge the current dirty range.
    pub fn clear_dirty(&mut self) {
        self.dirty = None;
    }

    // ── ops ─────────────────────────────────────────────────────────────

    fn id_by_path(&self, path: &[usize]) -> Result<NodeId, Error> {
        self.doc.ast.id_by_path(path).map_err(|_| Error::PathOutOfBounds)
    }

    /// A node's span, or `NoNodeSpan` if it's the degenerate `(0,0)` that
    /// means "unset".
    fn node_span(&self, id: NodeId) -> Result<Span, Error> {
        let s = self.doc.span(id);
        if s.start == 0 && s.end == 0 {
            return Err(Error::NoNodeSpan);
        }
        Ok(s)
    }

    /// Replace the whole source of the node at `path`.
    pub fn replace_node(&mut self, path: &[usize], text: &[u8]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.replace_node_by_id(id, text)
    }
    pub fn replace_node_by_id(&mut self, id: NodeId, text: &[u8]) -> Result<(), Error> {
        let s = self.node_span(id)?;
        self.replace_at_span(s, text)
    }

    /// Replace the interior (`content_span`) of the node.
    pub fn replace_content(&mut self, path: &[usize], text: &[u8]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.replace_content_by_id(id, text)
    }
    pub fn replace_content_by_id(&mut self, id: NodeId, text: &[u8]) -> Result<(), Error> {
        let cs = self.doc.content_span(id).ok_or(Error::NoContentSpan)?;
        self.replace_at_span(cs, text)
    }

    /// Insert `text` immediately before / after the node.
    pub fn insert_before(&mut self, path: &[usize], text: &[u8]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.insert_before_by_id(id, text)
    }
    pub fn insert_before_by_id(&mut self, id: NodeId, text: &[u8]) -> Result<(), Error> {
        let at = self.node_span(id)?.start;
        self.replace_at_span(Span::new(at, at), text)
    }
    pub fn insert_after(&mut self, path: &[usize], text: &[u8]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.insert_after_by_id(id, text)
    }
    pub fn insert_after_by_id(&mut self, id: NodeId, text: &[u8]) -> Result<(), Error> {
        let at = self.node_span(id)?.end;
        self.replace_at_span(Span::new(at, at), text)
    }

    /// Insert `text` as the `index`-th child of the container.
    pub fn insert_child(&mut self, path: &[usize], index: usize, text: &[u8]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.insert_child_by_id(id, index, text)
    }
    pub fn insert_child_by_id(&mut self, id: NodeId, index: usize, text: &[u8]) -> Result<(), Error> {
        let Some(first) = self.doc.ast.nodes[id as usize].first_child else {
            if self.doc.ast.nodes[id as usize].kind.content_model() == crate::ast::ContentModel::Text {
                return Err(Error::NotAContainer);
            }
            let cs = self.doc.content_span(id).ok_or(Error::NoContentSpan)?;
            return self.replace_at_span(Span::new(cs.start, cs.start), text);
        };

        let mut cur = Some(first);
        let mut i = 0;
        let mut last = first;
        let mut prev_last: Option<NodeId> = None;
        while let Some(c) = cur {
            if i == index {
                let at = self.doc.span(c).start;
                return self.replace_at_span(Span::new(at, at), text);
            }
            if i > 0 {
                prev_last = Some(last);
            }
            last = c;
            cur = self.doc.ast.nodes[c as usize].next_sibling;
            i += 1;
        }
        // Appending past the last child: infer the sibling separator from the
        // source rather than assume.
        let src = &self.source;
        let at = self.doc.span(last).end;
        if at < src.len() && src[at] == b'\n' {
            return self.replace_at_span(Span::new(at + 1, at + 1), text);
        }
        let siblings_line_separated = match prev_last {
            Some(p) => src[self.doc.span(p).end..self.doc.span(last).start].contains(&b'\n'),
            None => false,
        };
        if siblings_line_separated {
            let mut buf = Vec::with_capacity(text.len() + 1);
            buf.push(b'\n');
            buf.extend_from_slice(text);
            return self.replace_at_span(Span::new(at, at), &buf);
        }
        self.replace_at_span(Span::new(at, at), text)
    }

    /// Delete the node (remove exactly its span; no whitespace cleanup).
    pub fn delete_node(&mut self, path: &[usize]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.delete_node_by_id(id)
    }
    pub fn delete_node_by_id(&mut self, id: NodeId) -> Result<(), Error> {
        let s = self.node_span(id)?;
        self.replace_at_span(s, b"")
    }

    /// Delete the node, tidying surrounding whitespace so no dangling blank
    /// line is left behind. See `tidy_deletion_span`.
    pub fn delete_node_smart(&mut self, path: &[usize]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.delete_node_smart_by_id(id)
    }
    pub fn delete_node_smart_by_id(&mut self, id: NodeId) -> Result<(), Error> {
        let s = self.node_span(id)?;
        let span = self.span_with_leading_attrs(id, s);
        let del = tidy_deletion_span(&self.source, span);
        self.replace_at_span(del, b"")
    }

    /// `span`, widened to take in an attribute block the node's attributes
    /// were written in BEFORE it — djot's `{.vis}` on its own line above the
    /// block. An orphan attribute line attaches to whatever block follows it,
    /// so leaving it would MOVE that marking onto the next block.
    fn span_with_leading_attrs(&self, id: NodeId, span: Span) -> Span {
        let Some(a) = self.doc.attrs_span(id) else { return span };
        if a.end > span.start {
            return span;
        }
        if self.source[a.end..span.start].iter().any(|&c| !matches!(c, b' ' | b'\t' | b'\r' | b'\n')) {
            return span;
        }
        Span::new(a.start, span.end)
    }

    /// Unwrap the node: replace its whole span with the source text of its
    /// interior. A node with no interior degrades to a smart delete.
    pub fn unwrap_node(&mut self, path: &[usize]) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        self.unwrap_node_by_id(id)
    }
    pub fn unwrap_node_by_id(&mut self, id: NodeId) -> Result<(), Error> {
        let s = self.node_span(id)?;
        let span = self.span_with_leading_attrs(id, s);
        let Some(cs) = self.doc.content_span(id) else { return self.delete_node_smart_by_id(id) };
        let interior = self.source[cs.start..cs.end].to_vec();
        self.replace_at_span(span, &interior)
    }

    /// Move node `id` to immediately before or after node `anchor`, in ONE
    /// splice over the range that covers both. The node travels with the
    /// WHITESPACE RUN before it.
    pub fn move_node(&mut self, path: &[usize], anchor_path: &[usize], place: Placement) -> Result<(), Error> {
        let id = self.id_by_path(path)?;
        let anchor = self.id_by_path(anchor_path)?;
        self.move_node_by_id(id, anchor, place)
    }
    pub fn move_node_by_id(&mut self, id: NodeId, anchor: NodeId, place: Placement) -> Result<(), Error> {
        let a = self.node_span(id)?;
        let b = self.node_span(anchor)?;
        let unit = Span::new(self.leading_gap_start(id, a.start), a.end);
        if unit.start < b.end && b.start < unit.end {
            return Err(Error::OverlappingNodes);
        }
        let src = &self.source;
        let gap = &src[unit.start..a.start];
        let node = &src[a.start..a.end];
        let other = &src[b.start..b.end];
        let a_first = unit.end <= b.start;
        let between = if a_first { &src[unit.end..b.start] } else { &src[b.end..unit.start] };

        let mut buf = Vec::with_capacity(unit.len() + between.len() + other.len());
        if a_first {
            buf.extend_from_slice(between);
        }
        match place {
            Placement::After => {
                buf.extend_from_slice(other);
                buf.extend_from_slice(gap);
                buf.extend_from_slice(node);
            }
            Placement::Before => {
                buf.extend_from_slice(node);
                buf.extend_from_slice(gap);
                buf.extend_from_slice(other);
            }
        }
        if !a_first {
            buf.extend_from_slice(between);
        }
        let whole = if a_first { Span::new(unit.start, b.end) } else { Span::new(b.start, unit.end) };
        self.replace_at_span(whole, &buf)
    }

    /// Where the whitespace run ahead of node `id` begins — bounded by the
    /// previous sibling's end (unless that sibling is whitespace-only text)
    /// and the parent's interior.
    fn leading_gap_start(&self, id: NodeId, start: usize) -> usize {
        let src = &self.source;
        let mut floor = 0;
        if let Some(parent) = self.doc.ast.parent_of(id) {
            if let Some(cs) = self.doc.content_span(parent) {
                floor = cs.start;
            }
            let mut prev: Option<NodeId> = None;
            let mut child = self.doc.ast.nodes[parent as usize].first_child;
            while let Some(c) = child {
                if c == id {
                    break;
                }
                prev = Some(c);
                child = self.doc.ast.nodes[c as usize].next_sibling;
            }
            if let Some(p) = prev {
                let ps = self.doc.span(p);
                let blank = match &self.doc.ast.nodes[p as usize].kind {
                    crate::ast::Kind::Str(t) => t.iter().all(|c| matches!(c, b' ' | b'\t' | b'\r' | b'\n')),
                    _ => false,
                };
                if !blank {
                    floor = floor.max(ps.end);
                }
            }
        }
        let mut at = start;
        while at > floor {
            match src[at - 1] {
                b' ' | b'\t' | b'\r' | b'\n' => at -= 1,
                _ => break,
            }
        }
        at
    }

    // ── range-oriented rich-text ops (the "toolbar") ────────────────────────

    /// Wrap `[span.start, span.end)` with `open`/`close` in a single splice.
    pub fn wrap_range(&mut self, span: Span, open: &[u8], close: &[u8]) -> Result<(), Error> {
        assert!(span.start <= span.end && span.end <= self.source.len());
        let mut buf = Vec::with_capacity(open.len() + span.len() + close.len());
        buf.extend_from_slice(open);
        buf.extend_from_slice(&self.source[span.start..span.end]);
        buf.extend_from_slice(close);
        self.replace_at_span(span, &buf)
    }

    /// Toggle an inline mark of `kind` over `span`: remove it where `span`
    /// already IS a node of `kind`, else wrap `span` with `open`/`close`.
    pub fn toggle_inline(&mut self, span: Span, kind: &KindRef, open: &[u8], close: &[u8]) -> Result<(), Error> {
        match self.inline_strip(span, kind, open, close)? {
            Some(strip) => self.replace_at_span(strip.span, &strip.interior),
            None => self.wrap_range(span, open, close),
        }
    }

    /// The half of `toggle_inline` that DECIDES: whether `span` is already a
    /// mark of `kind`, and if so what removing it would write. `None` means
    /// it is not. `NoContentSpan` where a mark exists but cannot be cleanly
    /// removed.
    pub fn inline_strip(&self, span: Span, kind: &KindRef, open: &[u8], close: &[u8]) -> Result<Option<Strip>, Error> {
        let Some(id) = self.inline_node_covering(span, kind) else { return Ok(None) };
        let node_span = self.doc.span(id);
        if let Some(cs) = self.doc.content_span(id) {
            return Ok(Some(Strip { span: node_span, interior: self.source[cs.start..cs.end].to_vec() }));
        }
        let s = &self.source[node_span.start..node_span.end];
        if s.len() >= open.len() + close.len() && s.starts_with(open) && s.ends_with(close) {
            return Ok(Some(Strip { span: node_span, interior: s[open.len()..s.len() - close.len()].to_vec() }));
        }
        Err(Error::NoContentSpan)
    }

    /// The id of the node of `kind` that `span` already IS: `content_span ⊆
    /// span ⊆ span(node)`, looking through a mark of another kind whose whole
    /// interior is the `kind` node.
    fn inline_node_covering(&self, span: Span, kind: &KindRef) -> Option<NodeId> {
        for node in &self.doc.ast.nodes {
            let node_span = self.doc.span(node.id);
            if node_span == Span::new(0, 0) {
                continue;
            }
            if kind.matches(&node.kind) && node_span == span {
                return Some(node.id);
            }
            let Some(interior) = self.doc.content_span(node.id) else { continue };
            if !(node_span.start <= span.start
                && span.start <= interior.start
                && interior.end <= span.end
                && span.end <= node_span.end)
            {
                continue;
            }
            if kind.matches(&node.kind) {
                return Some(node.id);
            }
            if let Some(child) = self.sole_child_filling(node.id, interior) {
                if kind.matches(&self.doc.ast.nodes[child as usize].kind) {
                    return Some(child);
                }
            }
        }
        None
    }

    /// `id`'s only child, if it has exactly one and that child's span is the
    /// whole of `interior`.
    fn sole_child_filling(&self, id: NodeId, interior: Span) -> Option<NodeId> {
        let mut it = self.doc.children(id);
        let first = it.next()?;
        if it.next().is_some() {
            return None;
        }
        if self.doc.span(first.id) == interior { Some(first.id) } else { None }
    }
}

/// The minimal `[start, end)` byte range that differs between `before` and
/// `after`, as a `Change` (common prefix and suffix trimmed).
fn diff_change(before: &[u8], after: &[u8]) -> Change {
    let min = before.len().min(after.len());
    let mut p = 0;
    while p < min && before[p] == after[p] {
        p += 1;
    }
    let mut s = 0;
    while s < min - p && before[before.len() - 1 - s] == after[after.len() - 1 - s] {
        s += 1;
    }
    Change { old: Span::new(p, before.len() - s), new: Span::new(p, after.len() - s) }
}

// ── smart-delete whitespace tidying ────────────────────────────────────────

/// A line's content is "blank" if it holds only spaces/tabs (and a lone `\r`).
fn is_blank_run(s: &[u8]) -> bool {
    s.iter().all(|&c| c == b' ' || c == b'\t' || c == b'\r')
}

/// From `from` (a line start), consume consecutive blank lines.
fn consume_blank_lines_forward(source: &[u8], from: usize) -> usize {
    let mut i = from;
    while i < source.len() {
        let mut j = i;
        while j < source.len() && source[j] != b'\n' {
            j += 1;
        }
        if !is_blank_run(&source[i..j]) {
            break;
        }
        i = if j < source.len() { j + 1 } else { j };
        if j >= source.len() {
            break;
        }
    }
    i
}

/// From `from` (a line start), consume consecutive PRECEDING blank lines.
fn consume_blank_lines_backward(source: &[u8], from: usize) -> usize {
    let mut s = from;
    while s > 0 && source[s - 1] == b'\n' {
        let nl = s - 1;
        let mut pstart = nl;
        while pstart > 0 && source[pstart - 1] != b'\n' {
            pstart -= 1;
        }
        if !is_blank_run(&source[pstart..nl]) {
            break;
        }
        s = pstart;
    }
    s
}

/// The range to delete for a "tidy" removal of a node whose exact span is
/// `span`. A span occupying whole lines takes its indentation, its line end
/// and one blank-line separator; a mid-line span is returned unchanged.
pub fn tidy_deletion_span(source: &[u8], span: Span) -> Span {
    let len = source.len();
    let mut s = span.start;
    let mut e = span.end;
    while s > 0 && (source[s - 1] == b' ' || source[s - 1] == b'\t') {
        s -= 1;
    }
    while e < len && (source[e] == b' ' || source[e] == b'\t') {
        e += 1;
    }
    let at_line_start = s == 0 || source[s - 1] == b'\n';
    let at_line_end = e == len || source[e] == b'\n' || source[e] == b'\r';
    if !at_line_start || !at_line_end {
        return span;
    }
    if e < len && source[e] == b'\r' {
        e += 1;
    }
    if e < len && source[e] == b'\n' {
        e += 1;
    }
    e = consume_blank_lines_forward(source, e);
    if e >= len {
        s = consume_blank_lines_backward(source, s);
    }
    Span::new(s, e)
}

#[cfg(test)]
#[path = "splicer_test.rs"]
mod splicer_test;
