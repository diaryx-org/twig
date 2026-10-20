//! The authoring editor: a `Splicer` that knows how its format is SPELLED.
//! Port of `src/ast/editor.zig`.
//!
//! ── The two layers ─────────────────────────────────────────────────────────
//! `Splicer` (`ast/splicer.rs`) is the engine: byte spans in, reparse,
//! rollback, undo. It is language-agnostic by construction — hand it a parse
//! function and it will edit djot, Markdown or XML with the same code. What it
//! cannot do is decide that bold is spelled `**` here and `*` there.
//!
//! `Editor` is that decision, and nothing else: `Splicer` + a `&Syntax`. It
//! hosts the gestures a caret editor actually performs — Cmd-B, H1, quote,
//! link — each of which is "consult the table, build the bytes, hand the
//! Splicer one span". `Editor` depends only on the `Syntax` INTERFACE and still
//! names no format; `format.rs`'s registry is what binds the two.
//!
//! ── Errors ─────────────────────────────────────────────────────────────────
//! Typed: `Error::UnsupportedFormat` is uniformly "the `Syntax` table has a
//! `None` where this gesture needed a spelling" — never a per-format arm.

use std::fmt;

use crate::ast::splicer::{self, Change, ParseError, ParseFn, Splicer};
use crate::ast::{
    locate, select, table_edit, verse, Alignment, Ast, Attrs, Builder, Container, ContentModel, Form, InlineMark,
    KeyVal, Kind, KindRef, Level, Link, ListNumbering, NodeId, Tag, TextLeafKind,
};
use crate::document::{ContainerOrigin, Document};
use crate::span::Span;
use crate::syntax::{
    BlockAttrs, CodeFence, ContainerSpelling, RenderBlockFn, Syntax, TextPosition,
};

pub use crate::syntax::{BlockKind, ContainerKind, InlineKind};

/// Room for the widest marker/indent a list can produce (`999. ` and friends).
const CONTAINER_INDENT: &[u8; 24] = b"                        ";

/// Everything a gesture can refuse with.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Error {
    /// `start > end`, or a range reaching past the source.
    InvalidRange,
    /// A heading level outside 1-6.
    InvalidLevel,
    /// A destination this format cannot hold (one containing a newline).
    InvalidDestination,
    /// An info string this format's code fence cannot hold.
    InvalidLanguage,
    /// A colour name outside the format's palette.
    InvalidColor,
    /// A label this format cannot hold.
    InvalidLabel,
    /// A table shape no pipe format spells: zero columns or zero body rows.
    InvalidShape,
    /// A directive name outside the grammar every format reads one back by.
    InvalidName,
    /// An attribute no format reads back as one (see `check_attr`).
    InvalidAttribute,
    /// A formula this format cannot hold.
    InvalidFormula,
    /// `move_block`'s destination names the block being moved.
    InvalidArgument,
    /// The `Syntax` table has no spelling for this gesture in this format.
    UnsupportedFormat,
    /// No block covers the offset/range this gesture needs one for.
    NoBlock,
    /// The target node has no editable span/interior, or the gesture would
    /// corrupt something it refuses to touch.
    NotEditable,
    /// The edit produced a document that no longer parses; it was rolled
    /// back and nothing changed.
    EditConflict,
}

impl Error {
    /// The Zig error name (`@errorName`).
    pub fn name(self) -> &'static str {
        match self {
            Error::InvalidRange => "InvalidRange",
            Error::InvalidLevel => "InvalidLevel",
            Error::InvalidDestination => "InvalidDestination",
            Error::InvalidLanguage => "InvalidLanguage",
            Error::InvalidColor => "InvalidColor",
            Error::InvalidLabel => "InvalidLabel",
            Error::InvalidShape => "InvalidShape",
            Error::InvalidName => "InvalidName",
            Error::InvalidAttribute => "InvalidAttribute",
            Error::InvalidFormula => "InvalidFormula",
            Error::InvalidArgument => "InvalidArgument",
            Error::UnsupportedFormat => "UnsupportedFormat",
            Error::NoBlock => "NoBlock",
            Error::NotEditable => "NotEditable",
            Error::EditConflict => "EditConflict",
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl std::error::Error for Error {}

type R<T = ()> = Result<T, Error>;

/// One gesture, named with whatever kind it takes — the question `supports`
/// answers, in the same vocabulary the gesture itself is called with.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Gesture {
    WrapRange(InlineKind),
    ToggleInline(InlineKind),
    SetMarkColor,
    SetBlock,
    ToggleBlockContainer(ContainerKind),
    InsertThematicBreak,
    ToggleCodeBlock,
    SetCodeLanguage,
    ToggleTaskItem,
    SetTaskChecked,
    ToggleTaskChecked,
    InsertLink,
    InsertImage,
    InsertFootnote,
    InsertLiteral,
    InsertLineBreak,
    SplitBlock,
    JoinBlocks,
    RenumberOrderedLists,
    TableInsertRow,
    TableDeleteRow,
    TableInsertColumn,
    TableDeleteColumn,
    TableSetAlignment,
    TableMoveRow,
    TableMoveColumn,
    InsertTable,
    InsertDirective,
    SetBlockAttrs,
    WrapRangeAttrs,
    SetNodeAttrs,
    MoveBlock,
    InsertInlineMath,
    InsertDisplayMath,
    ToggleLineBlock,
}

/// Whether `syntax` can spell `gesture` — the toolbar's gray-out question,
/// asked WITHOUT a document. `true` means the gesture will not fail with
/// `UnsupportedFormat`; it says nothing about the caret.
pub fn supports(syntax: &Syntax, gesture: Gesture) -> bool {
    use Gesture::*;
    match gesture {
        WrapRange(k) | ToggleInline(k) => syntax.authorable_delims_for(&k.kind_ref()).is_some(),
        SetMarkColor => syntax.mark_colors.is_some(),
        SetBlock => syntax.heading_marker.is_some() || syntax.render_block.is_some(),
        ToggleBlockContainer(k) => syntax.container(k).is_some() || syntax.render_block.is_some(),
        InsertThematicBreak => syntax.thematic_break.is_some(),
        ToggleCodeBlock | SetCodeLanguage => syntax.code_fence.is_some() || syntax.render_block.is_some(),
        ToggleTaskItem | SetTaskChecked | ToggleTaskChecked => syntax.task_marker.is_some(),
        InsertLink => syntax.link_text_escapes.is_some() || syntax.render_block.is_some(),
        InsertImage => {
            (syntax.link_text_escapes.is_some() && syntax.link_dest_escapes.is_some()) || syntax.render_block.is_some()
        }
        InsertFootnote => syntax.footnote.is_some(),
        InsertLiteral => syntax.render_text.is_some(),
        InsertLineBreak => syntax.cell_line_break.is_some(),
        SplitBlock => syntax.block_separator.is_some(),
        JoinBlocks => syntax.line_join.is_some(),
        RenumberOrderedLists => spells_ordered_markers(syntax),
        TableInsertRow | TableDeleteRow | TableInsertColumn | TableDeleteColumn | TableSetAlignment | TableMoveRow
        | TableMoveColumn | InsertTable => syntax.table_spelling.is_some(),
        InsertDirective => syntax.names_leaf_containers && syntax.render_block.is_some(),
        SetBlockAttrs => syntax.block_attrs.is_some() && syntax.render_block.is_some(),
        WrapRangeAttrs => syntax.inline_attrs && syntax.render_block.is_some(),
        SetNodeAttrs => syntax.node_attrs.is_some(),
        ToggleLineBlock => syntax.line_blocks && syntax.render_block.is_some(),
        MoveBlock => syntax.block_separator.is_some() || syntax.render_block.is_some(),
        InsertInlineMath => {
            syntax.authorable_delims_for(&KindRef::TextLeaf(TextLeafKind::InlineMath)).is_some()
                && syntax.render_block.is_some()
        }
        InsertDisplayMath => {
            syntax.authorable_delims_for(&KindRef::TextLeaf(TextLeafKind::DisplayMath)).is_some()
                && syntax.render_block.is_some()
        }
    }
}

/// Whether this format spells an ordered list item as a NUMBERED LINE MARKER —
/// the one question `renumber_ordered_lists` needs answered.
fn spells_ordered_markers(syntax: &Syntax) -> bool {
    syntax.container(ContainerKind::OrderedList).is_some_and(|sp| sp.numbered)
}

/// The node `set_block`'s render path builds for a `BlockKind`.
fn block_node_kind(kind: BlockKind, level: u32) -> Kind {
    match kind {
        BlockKind::Paragraph => Kind::Para,
        BlockKind::Heading => Kind::Heading { level },
    }
}

// ── byte helpers ─────────────────────────────────────────────────────────────

fn trim_end<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    let mut e = s.len();
    while e > 0 && set.contains(&s[e - 1]) {
        e -= 1;
    }
    &s[..e]
}

fn trim_start<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    let mut b = 0;
    while b < s.len() && set.contains(&s[b]) {
        b += 1;
    }
    &s[b..]
}

fn trim<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    trim_start(trim_end(s, set), set)
}

fn contains_any(s: &[u8], set: &[u8]) -> bool {
    s.iter().any(|c| set.contains(c))
}

fn find_byte(s: &[u8], c: u8) -> Option<usize> {
    s.iter().position(|&x| x == c)
}

fn rfind_byte(s: &[u8], c: u8) -> Option<usize> {
    s.iter().rposition(|&x| x == c)
}

fn repeat(out: &mut Vec<u8>, c: u8, n: usize) {
    out.extend(std::iter::repeat_n(c, n));
}

fn is_whitespace(c: u8) -> bool {
    // Zig's `std.ascii.isWhitespace`: space, \t, \n, \r, \x0B, \x0C.
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0B | 0x0C)
}

/// One node through `render`, with the renderer's errors folded into the
/// editor's: a refusal to print is a content refusal, not a format one.
fn render_node(syntax: &Syntax, render: RenderBlockFn, ast: &Ast, id: NodeId, out: &mut Vec<u8>) -> R {
    render(syntax, ast, id, out).map_err(|_| Error::NotEditable)
}

/// The authoring editor: a `Splicer` plus the spelling table of its format.
pub struct Editor {
    pub splicer: Splicer,
    /// This format's spelling. `format.rs`'s registry entries are static.
    pub syntax: &'static Syntax,
}

impl fmt::Debug for Editor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Editor").field("splicer", &self.splicer).finish()
    }
}

impl Editor {
    /// `parse_fn` is the Splicer's contract; `syntax` is the table every
    /// gesture consults. Pair them from `format.rs`'s registry — crossing
    /// them would spell djot into a Markdown document.
    pub fn new(source: &[u8], parse_fn: ParseFn, syntax: &'static Syntax) -> Result<Editor, ParseError> {
        Ok(Editor { splicer: Splicer::new(source, parse_fn)?, syntax })
    }

    pub fn source_bytes(&self) -> &[u8] {
        self.splicer.source_bytes()
    }

    pub fn ast_view(&self) -> &Ast {
        self.splicer.ast_view()
    }

    pub fn doc(&self) -> &Document {
        &self.splicer.doc
    }

    pub fn last_change(&self) -> Option<Change> {
        self.splicer.last_change
    }

    /// Whether this editor's table can spell `gesture` (see [`supports`]).
    pub fn supports(&self, gesture: Gesture) -> bool {
        supports(self.syntax, gesture)
    }

    /// Validate a caller-supplied byte range.
    fn check_range(&self, start: usize, end: usize) -> R {
        if start > end || end > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        Ok(())
    }

    /// Splice rebuilt source in over `[start, end)`. Every gesture ends here.
    fn commit_splice(&mut self, start: usize, end: usize, text: &[u8]) -> R {
        self.commit_splice_checked(start, end, text, None)
    }

    /// `commit_splice`, kept only if `check` accepts the reparse. A rejected
    /// reparse is `NotEditable`.
    fn commit_splice_checked(
        &mut self,
        start: usize,
        end: usize,
        text: &[u8],
        check: Option<&dyn Fn(&Document) -> bool>,
    ) -> R {
        match self.splicer.replace_at_span_checked(Span::new(start, end), text, check) {
            Ok(()) => Ok(()),
            Err(splicer::Error::Rejected) => Err(Error::NotEditable),
            Err(_) => Err(Error::EditConflict),
        }
    }

    // ── Inline marks ───────────────────────────────────────────────────────

    /// Wrap `span` in `kind`'s delimiters — the unconditional half of the
    /// inline toolbar. One pair per block the range touches.
    pub fn wrap_range(&mut self, span: Span, kind: InlineKind) -> R {
        self.apply_inline(span, kind, false)
    }

    /// Toggle `kind` over `span`: strip the mark where the range already IS a
    /// node of `kind`, else wrap it — a rich editor's Cmd-B. One decision per
    /// block the range touches.
    pub fn toggle_inline(&mut self, span: Span, kind: InlineKind) -> R {
        self.apply_inline(span, kind, true)
    }

    /// Both inline gestures, in one pass: cut `span` at its block boundaries,
    /// decide per piece, and splice the lot once. A selection crossing a blank
    /// line gets one pair per paragraph; the region spliced is the selection
    /// UNION every mark being removed. `NotEditable` when the range holds no
    /// inline host at all (a selection inside a code block).
    fn apply_inline(&mut self, span: Span, kind: InlineKind, toggle: bool) -> R {
        self.check_range(span.start, span.end)?;
        let d = *self.syntax.authorable_delims_for(&kind.kind_ref()).ok_or(Error::UnsupportedFormat)?;
        let doc = &self.splicer.doc;

        let mut pieces: Vec<Span> = Vec::new();
        if span.is_empty() {
            pieces.push(span);
        } else {
            locate::inline_host_pieces(doc, span, &mut pieces);
            if pieces.is_empty() {
                return Err(Error::NotEditable);
            }
            for p in pieces.iter_mut() {
                locate::widen_over_verbatim(doc, p);
            }
        }

        // (span, interior): `Some(interior)` removes a mark, `None` wraps.
        let mut edits: Vec<(Span, Option<Vec<u8>>)> = Vec::new();
        let mut region = span;
        for &p in &pieces {
            region.start = region.start.min(p.start);
            region.end = region.end.max(p.end);
            let strip = if toggle {
                self.splicer.inline_strip(p, &kind.kind_ref(), d.open, d.close).map_err(|_| Error::NotEditable)?
            } else {
                None
            };
            match strip {
                Some(s) => {
                    region.start = region.start.min(s.span.start);
                    region.end = region.end.max(s.span.end);
                    edits.push((s.span, Some(s.interior)));
                }
                None => edits.push((p, None)),
            }
        }

        let src = self.source_bytes();
        let mut out = Vec::new();
        let mut cursor = region.start;
        for (es, interior) in &edits {
            if es.start < cursor {
                return Err(Error::EditConflict);
            }
            out.extend_from_slice(&src[cursor..es.start]);
            match interior {
                Some(i) => out.extend_from_slice(i),
                None => {
                    out.extend_from_slice(d.open);
                    out.extend_from_slice(&src[es.start..es.end]);
                    out.extend_from_slice(d.close);
                }
            }
            cursor = es.end;
        }
        out.extend_from_slice(&src[cursor..region.end]);
        self.commit_splice(region.start, region.end, &out)
    }

    /// Set — or clear — the COLOUR of the `mark` the caret at `offset` is in.
    /// `color` is a palette name (`"red"`), or `None` to leave the highlight
    /// uncoloured. An existing prefix keeps its own spacing; a first one is
    /// written with `MarkColors::space`.
    pub fn set_mark_color(&mut self, offset: usize, color: Option<&[u8]>) -> R {
        let mc = self.syntax.mark_colors.ok_or(Error::UnsupportedFormat)?;
        let d = *self.syntax.delims_for(&KindRef::Mark(InlineMark::Mark)).ok_or(Error::UnsupportedFormat)?;
        let new_prefix = match color {
            Some(name) => Some(mc.prefix_for(name).ok_or(Error::InvalidColor)?),
            None => None,
        };
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let chain = locate::caret_chain_vec(doc, offset);
        let id = chain
            .iter()
            .rev()
            .copied()
            .find(|&id| doc.ast.kind(id).is_inline_mark(InlineMark::Mark))
            .ok_or(Error::NotEditable)?;

        let node_span = doc.span(id);
        let cs = doc.content_span(id).ok_or(Error::NotEditable)?;
        let prefix_start = node_span.start + d.open.len();
        if prefix_start > cs.start || cs.start > src.len() {
            return Err(Error::NotEditable);
        }
        let existing = &src[prefix_start..cs.start];
        let mut spaced = false;
        if !existing.is_empty() {
            let c = mc.prefix_at(existing).ok_or(Error::NotEditable)?;
            let rest = &existing[c.prefix.len()..];
            if rest == mc.space {
                spaced = true;
            } else if !rest.is_empty() {
                return Err(Error::NotEditable);
            }
        }
        let existing_empty = existing.is_empty();
        let Some(prefix) = new_prefix else {
            if existing_empty {
                return Ok(());
            }
            return self.commit_splice(prefix_start, cs.start, b"");
        };
        let write_space = if existing_empty { true } else { spaced };
        let mut buf = prefix.to_vec();
        if write_space {
            buf.extend_from_slice(mc.space);
        }
        self.commit_splice(prefix_start, cs.start, &buf)
    }

    // ── Block kind ─────────────────────────────────────────────────────────

    /// Convert the block at `offset` to `kind` (a `level`-N heading, or a
    /// paragraph) by rewriting its leading marker while keeping its inline
    /// content verbatim. ON A BLANK LINE this OPENS the block instead. Where
    /// the format has no marker but a renderer, the block is rebuilt and
    /// printed. The reparse must give back a heading of `level` holding the
    /// block's text, or the splice is `NotEditable`.
    pub fn set_block(&mut self, offset: usize, kind: BlockKind, level: u32) -> R {
        if let Some(marker) = self.syntax.heading_marker {
            return self.set_block_by_marker(offset, kind, level, marker);
        }
        if let Some(render) = self.syntax.render_block {
            return self.set_block_by_render(offset, kind, level, render);
        }
        Err(Error::UnsupportedFormat)
    }

    fn set_block_by_marker(&mut self, offset: usize, kind: BlockKind, level: u32, marker: u8) -> R {
        if kind == BlockKind::Heading && !(1..=6).contains(&level) {
            return Err(Error::InvalidLevel);
        }
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let Some(block) = locate::innermost_block(doc, offset) else {
            return self.open_block_on_blank_line(offset, kind, level, marker);
        };
        let cs = doc.content_span(block).ok_or(Error::NotEditable)?;
        let content = &src[cs.start..cs.end];

        let block_span = doc.span(block);
        let mut start = cs.start;
        if let Some(m) = doc.marker_span(block) {
            if m.end <= cs.start && m.start >= locate::line_start_at(src, cs.start) {
                start = m.start;
            }
        }
        let mut end = block_span.end;
        if end > block_span.start && src[end - 1] == b'\n' {
            end -= 1;
        }
        if end > block_span.start && src[end - 1] == b'\r' {
            end -= 1;
        }

        if kind == BlockKind::Paragraph {
            let content = content.to_vec();
            return self.commit_splice(start, end, &content);
        }

        let mut buf = Vec::new();
        repeat(&mut buf, marker, level as usize);
        buf.push(b' ');
        if self.syntax.heading_continues {
            buf.extend_from_slice(content);
        } else {
            append_block_as_one_line(doc, block, cs, &mut buf)?;
        }
        let text = select::text_of(&doc.ast, block);
        let want_text = trim(&text, b" ").to_vec();
        let within = Span::new(start, start + buf.len());
        let check = move |d: &Document| heading_check(d, level, &want_text, within);
        self.commit_splice_checked(start, end, &buf, Some(&check))
    }

    /// `set_block` over a format with no leading marker but a fragment
    /// renderer: BUILD the block and let the format print it.
    fn set_block_by_render(&mut self, offset: usize, kind: BlockKind, level: u32, render: RenderBlockFn) -> R {
        if kind == BlockKind::Heading && !(1..=6).contains(&level) {
            return Err(Error::InvalidLevel);
        }
        if offset > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let Some(block) = locate::innermost_block(doc, offset) else {
            return self.open_block_by_render(offset, kind, level, render);
        };
        let mut b = Builder::new();
        let kids: Vec<NodeId> = doc.ast.child_ids(block).into_iter().map(|c| b.graft_subtree(&doc.ast, c)).collect();
        let root = b.add_container(block_node_kind(kind, level), &kids);
        if let Some(ai) = doc.ast.nodes[block as usize].attrs {
            b.set_attrs(root, doc.ast.attrs[ai as usize].clone());
        }
        let bs = doc.span(block);
        self.splice_rendered(&b, root, render, bs.start, bs.end)
    }

    /// `set_block_by_render` on a BLANK LINE: open an EMPTY block there.
    fn open_block_by_render(&mut self, offset: usize, kind: BlockKind, level: u32, render: RenderBlockFn) -> R {
        let line = self.blank_line_between_blocks(offset)?;
        if kind == BlockKind::Paragraph {
            return Ok(());
        }
        let mut b = Builder::new();
        let root = b.add_container(block_node_kind(kind, level), &[]);
        self.splice_rendered(&b, root, render, line.start, line.end)
    }

    /// Print `root` of `b` through `render` and splice it over `[start, end)`,
    /// minus the line end a block renderer writes after its block.
    fn splice_rendered(&mut self, b: &Builder, root: NodeId, render: RenderBlockFn, start: usize, end: usize) -> R {
        let view = b.view(root);
        let mut out = Vec::new();
        render_node(self.syntax, render, &view, root, &mut out)?;
        let rendered = trim_end(&out, b"\r\n");
        self.commit_splice(start, end, rendered)
    }

    /// The line the caret is on, when it is a BLANK line lying BETWEEN a
    /// container's children.
    fn blank_line_between_blocks(&self, offset: usize) -> R<Span> {
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let line_start = locate::line_start_at(src, offset);
        let body = locate::line_body(&src[line_start..locate::line_end_at(src, offset)]);
        if !locate::is_blank_line(body) {
            return Err(Error::NotEditable);
        }
        if let Some(lb) = locate::line_owning_block(doc, offset) {
            if !locate::is_block_parent(doc.ast.kind(lb.block)) {
                return Err(Error::NotEditable);
            }
        }
        Ok(Span::new(line_start, line_start + body.len()))
    }

    /// `set_block` where there is no block to convert: the caret sits on a
    /// BLANK LINE, so the marker is OPENED. The line's quote markers are kept
    /// (with a space after the last `>`), and it is blank-separated from a
    /// preceding line with content — djot does not let a heading interrupt a
    /// paragraph. `NotEditable` for a blank line INTERIOR to a leaf;
    /// `.Paragraph` is a no-op.
    fn open_block_on_blank_line(&mut self, offset: usize, kind: BlockKind, level: u32, marker: u8) -> R {
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let line_start = locate::line_start_at(src, offset);
        let body = locate::line_body(&src[line_start..locate::line_end_at(src, offset)]);

        let mut i = 0;
        while let Some(j) = skip_quote_marker(body, i) {
            i = j;
        }
        if !locate::is_blank_line(&body[i..]) {
            return Err(Error::NotEditable);
        }
        if let Some(lb) = locate::line_owning_block(doc, offset) {
            if !locate::is_block_parent(doc.ast.kind(lb.block)) {
                return Err(Error::NotEditable);
            }
        }
        if kind == BlockKind::Paragraph {
            return Ok(());
        }

        let mut out = Vec::new();
        let prefix = &body[..i];
        let needs_space = i > 0 && body[i - 1] == b'>';
        if preceding_line_has_content(src, line_start) {
            out.extend_from_slice(trim_end(prefix, b" "));
            out.push(b'\n');
        }
        out.extend_from_slice(prefix);
        if needs_space {
            out.push(b' ');
        }
        repeat(&mut out, marker, level as usize);
        out.push(b' ');
        let end = line_start + body.len();
        self.commit_splice(line_start, end, &out)
    }

    // ── Block containers (quote / lists) ───────────────────────────────────

    /// Toggle a block container over the blocks `span` covers. The toggle turns
    /// OFF only when the range covers every block the container holds —
    /// otherwise it turns ON (a partial selection inside a quote nests).
    /// Toggling a list kind inside the other list kind converts in place. ON A
    /// BLANK LINE this OPENS an empty container. Where the format has no
    /// `ContainerSpelling` but a renderer, the container is built and printed.
    pub fn toggle_block_container(&mut self, span: Span, kind: ContainerKind) -> R {
        self.check_range(span.start, span.end)?;
        let Some(sp) = self.syntax.container(kind).copied() else {
            if let Some(render) = self.syntax.render_block {
                return self.toggle_block_container_by_render(span, kind, render);
            }
            return Err(Error::UnsupportedFormat);
        };
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let Ok(blocks) = covered_blocks(doc, span.start, span.end) else {
            return self.open_container_on_blank_line(span.start, kind, sp);
        };

        let region_start = locate::line_start_at(src, doc.span(blocks.first).start);
        let region_end = locate::line_end_at(src, doc.span(blocks.last).end.saturating_sub(1));
        if let Some(label) = labelled_parent(doc, &blocks, region_start) {
            return self.rewrap_labelled(label, &blocks, |b, ast, covered, _| {
                let all_paras = covered.iter().all(|&c| *ast.kind(c) == Kind::Para);
                let kids: Vec<NodeId> = covered
                    .iter()
                    .map(|&c| {
                        let block = b.graft_subtree(ast, c);
                        if kind == ContainerKind::BlockQuote { block } else { b.add_container(Kind::ListItem, &[block]) }
                    })
                    .collect();
                b.add_container(container_node_kind(kind, all_paras), &kids)
            });
        }
        let mut out = Vec::new();

        if let Some(target) = locate::innermost_of_kind(doc, &blocks.chain, kind.tag()) {
            if container_fully_covered(doc, target, region_start, region_end) {
                let t = doc.span(target);
                let splice_start = locate::line_start_at(src, t.start);
                let splice_end = locate::line_end_at(src, t.end.saturating_sub(1));
                match kind {
                    ContainerKind::BlockQuote => build_quote_strip(
                        src,
                        splice_start,
                        splice_end,
                        quote_depth_above(ast, &blocks.chain, target),
                        &mut out,
                    ),
                    ContainerKind::BulletList | ContainerKind::OrderedList => {
                        build_list_rewrite(src, doc, target, splice_start, splice_end, None, &mut out)
                    }
                }
                return self.commit_splice(splice_start, splice_end, &out);
            }
        }
        if kind != ContainerKind::BlockQuote {
            let other = if kind == ContainerKind::BulletList { Tag::OrderedList } else { Tag::BulletList };
            if let Some(target) = locate::innermost_of_kind(doc, &blocks.chain, other) {
                if container_fully_covered(doc, target, region_start, region_end) {
                    let t = doc.span(target);
                    let splice_start = locate::line_start_at(src, t.start);
                    let splice_end = locate::line_end_at(src, t.end.saturating_sub(1));
                    build_list_rewrite(src, doc, target, splice_start, splice_end, Some(&sp), &mut out);
                    return self.commit_splice(splice_start, splice_end, &out);
                }
            }
        }
        build_container_add(src, doc, &blocks, region_start, region_end, &sp, &mut out);
        self.commit_splice(region_start, region_end, &out)
    }

    /// `toggle_block_container` and `toggle_code_block` under a container
    /// that spells itself on its first child's first line (see
    /// [`labelled_parent`]): `label` is rebuilt with `wrap`'s block in place
    /// of the covered ones and printed through the format's renderer, which
    /// writes the container in a spelling of its own lines (AsciiDoc's
    /// delimited admonition), so the container is kept rather than its label
    /// taken into the new block as text. `wrap` is also handed the covered
    /// blocks' source, label excluded and behind no quote prefix. `NotEditable`
    /// where the format has no renderer or the covered blocks are not
    /// `label`'s own children.
    fn rewrap_labelled(
        &mut self,
        label: NodeId,
        blocks: &BlockRange,
        wrap: impl FnOnce(&mut Builder, &Ast, &[NodeId], &[u8]) -> NodeId,
    ) -> R {
        let render = self.syntax.render_block.ok_or(Error::NotEditable)?;
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let children = ast.child_ids(label);
        let (Some(lo), Some(hi)) = (
            children.iter().position(|&c| c == blocks.first),
            children.iter().position(|&c| c == blocks.last),
        ) else {
            return Err(Error::NotEditable);
        };
        let span = doc.span(label);
        let prefix = container_prefix(src, span.start);
        let blank = trim_end(prefix, b" ");
        let mut body = Vec::new();
        let covered = &src[doc.span(blocks.first).start..block_span_end(src, doc.span(blocks.last))];
        for (i, line) in covered.split(|&c| c == b'\n').enumerate() {
            if i > 0 {
                body.push(b'\n');
            }
            let line = line.strip_prefix(prefix).or_else(|| line.strip_prefix(blank)).unwrap_or(line);
            body.extend_from_slice(line);
        }
        let mut b = Builder::new();
        let mut kids: Vec<NodeId> = children[..lo].iter().map(|&c| b.graft_subtree(ast, c)).collect();
        kids.push(wrap(&mut b, ast, &children[lo..=hi], &body));
        kids.extend(children[hi + 1..].iter().map(|&c| b.graft_subtree(ast, c)));
        let root = b.add_container(ast.kind(label).clone(), &kids);
        if let Some(ai) = ast.nodes[label as usize].attrs {
            b.set_attrs(root, ast.attrs[ai as usize].clone());
        }
        let end = block_span_end(src, span);
        self.splice_rendered_prefixed(&b, root, render, Span::new(span.start, end))
    }

    /// `toggle_block_container` where there is no block to wrap: the caret
    /// sits on a BLANK LINE, so the container's marker is OPENED on it. It
    /// TOGGLES: a line already holding an empty container of `kind` and
    /// nothing else has that marker taken back off, and an empty marker of the
    /// OTHER list kind is converted. `NotEditable` when the line is neither
    /// blank nor exactly one empty marker.
    fn open_container_on_blank_line(&mut self, offset: usize, kind: ContainerKind, sp: ContainerSpelling) -> R {
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let line_start = locate::line_start_at(src, offset);
        let body = locate::line_body(&src[line_start..locate::line_end_at(src, offset)]);

        let mut quotes_end = 0;
        let mut last_quote = 0;
        while let Some(j) = skip_quote_marker(body, quotes_end) {
            last_quote = quotes_end;
            quotes_end = j;
        }
        let marker = list_marker_at(body, quotes_end);
        let empty_list = marker.is_some_and(|m| locate::is_blank_line(&body[m.1..]));
        let blank = locate::is_blank_line(&body[quotes_end..]);
        if !blank && !empty_list {
            return Err(Error::NotEditable);
        }

        let mut keep = if empty_list { marker.unwrap().0 } else { quotes_end };
        let write: Vec<u8> = if kind == ContainerKind::BlockQuote {
            if blank && quotes_end > 0 {
                keep = last_quote;
                Vec::new()
            } else {
                sp.marker.to_vec()
            }
        } else if empty_list && is_ordered_marker(body[marker.unwrap().0]) == sp.numbered {
            Vec::new()
        } else {
            list_marker(&sp, 1)
        };

        let mut out = Vec::new();
        if !write.is_empty() && blank && preceding_line_has_content(src, line_start) {
            out.extend_from_slice(trim_end(&body[..keep], b" "));
            out.push(b'\n');
        }
        out.extend_from_slice(&body[..keep]);
        if !write.is_empty() && keep > 0 && body[keep - 1] == b'>' {
            out.push(b' ');
        }
        out.extend_from_slice(&write);
        let tidy_len = if write.is_empty() { trim_end(&out, b" ").len() } else { out.len() };
        out.truncate(tidy_len);
        let end = line_start + body.len();
        self.commit_splice(line_start, end, &out)
    }

    /// `toggle_block_container` over a format with no line prefix but a
    /// fragment renderer: the same three decisions (toggle off, convert, wrap)
    /// taken from the tree.
    fn toggle_block_container_by_render(&mut self, span: Span, kind: ContainerKind, render: RenderBlockFn) -> R {
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let Ok(blocks) = covered_blocks(doc, span.start, span.end) else {
            return self.open_container_by_render(span.start, kind, render);
        };

        if let Some(target) = locate::innermost_of_kind(doc, &blocks.chain, kind.tag()) {
            if covers_container(ast, target, &blocks) {
                return self.unwrap_container(target, render);
            }
        }
        if kind != ContainerKind::BlockQuote {
            let other = if kind == ContainerKind::BulletList { Tag::OrderedList } else { Tag::BulletList };
            if let Some(target) = locate::innermost_of_kind(doc, &blocks.chain, other) {
                if covers_container(ast, target, &blocks) {
                    let mut b = Builder::new();
                    let items: Vec<NodeId> =
                        ast.child_ids(target).into_iter().map(|i| b.graft_subtree(ast, i)).collect();
                    let tight = match ast.kind(target) {
                        Kind::BulletList { tight } => *tight,
                        Kind::OrderedList { tight, .. } => *tight,
                        _ => unreachable!(),
                    };
                    let root = b.add_container(container_node_kind(kind, tight), &items);
                    if let Some(ai) = ast.nodes[target as usize].attrs {
                        b.set_attrs(root, ast.attrs[ai as usize].clone());
                    }
                    let t = doc.span(target);
                    let end = block_span_end(src, t);
                    return self.splice_rendered(&b, root, render, t.start, end);
                }
            }
        }

        let mut b = Builder::new();
        let mut kids = Vec::new();
        let mut all_paras = true;
        let mut cur = Some(blocks.first);
        while let Some(c) = cur {
            if *ast.kind(c) != Kind::Para {
                all_paras = false;
            }
            let block = b.graft_subtree(ast, c);
            kids.push(if kind == ContainerKind::BlockQuote {
                block
            } else {
                b.add_container(Kind::ListItem, &[block])
            });
            cur = if c == blocks.last { None } else { ast.nodes[c as usize].next_sibling };
        }
        let root = b.add_container(container_node_kind(kind, all_paras), &kids);
        let first = doc.span(blocks.first);
        let last = doc.span(blocks.last);
        let end = block_span_end(src, last);
        self.splice_rendered(&b, root, render, first.start, end)
    }

    /// `toggle_block_container_by_render` where `covered_blocks` found
    /// nothing: OPEN an empty container on a blank line, or REMOVE an empty
    /// container of `kind` the caret is in.
    fn open_container_by_render(&mut self, offset: usize, kind: ContainerKind, render: RenderBlockFn) -> R {
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let chain = locate::ancestor_chain_vec(doc, offset);
        if let Some(empty) = empty_container_of(&doc.ast, &chain, kind) {
            let t = doc.span(empty);
            let end = block_span_end(src, t);
            return self.commit_splice(t.start, end, b"");
        }
        let line = self.blank_line_between_blocks(offset)?;
        let mut b = Builder::new();
        let para = b.add_container(Kind::Para, &[]);
        let root = match kind {
            ContainerKind::BlockQuote => b.add_container(Kind::BlockQuote, &[para]),
            ContainerKind::BulletList | ContainerKind::OrderedList => {
                let item = b.add_container(Kind::ListItem, &[para]);
                b.add_container(container_node_kind(kind, false), &[item])
            }
        };
        self.splice_rendered(&b, root, render, line.start, line.end)
    }

    /// Print `target`'s blocks — for a list, each item's blocks — from the
    /// document's own tree and splice them over the container.
    fn unwrap_container(&mut self, target: NodeId, render: RenderBlockFn) -> R {
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let mut out = Vec::new();
        let is_list = ast.kind(target).tag() != Tag::BlockQuote;
        for c in ast.child_ids(target) {
            if is_list {
                for bl in ast.child_ids(c) {
                    render_node(self.syntax, render, ast, bl, &mut out)?;
                }
            } else {
                render_node(self.syntax, render, ast, c, &mut out)?;
            }
        }
        let t = doc.span(target);
        let end = block_span_end(src, t);
        let text = trim_end(&out, b"\r\n").to_vec();
        self.commit_splice(t.start, end, &text)
    }

    /// Renumber the ordered list at `offset` so its markers run `1, 2, 3, …`,
    /// each nesting level restarting at 1. Which lines ARE items comes from
    /// the tree; only their LEVEL comes from indentation. `NoBlock` when
    /// `offset` is not inside an ordered list.
    pub fn renumber_ordered_lists(&mut self, offset: usize) -> R {
        if !spells_ordered_markers(self.syntax) {
            return Err(Error::UnsupportedFormat);
        }
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let chain = locate::ancestor_chain_vec(doc, offset);
        let list = chain
            .iter()
            .copied()
            .find(|&id| matches!(ast.kind(id), Kind::OrderedList { .. }))
            .ok_or(Error::NoBlock)?;
        let region_start = locate::line_start_at(src, doc.span(list).start);
        let region_end = locate::line_end_at(src, doc.span(list).end.saturating_sub(1));

        let mut item_lines: Vec<usize> = Vec::new();
        for n in &ast.nodes {
            if !matches!(n.kind, Kind::ListItem | Kind::TaskListItem { .. }) {
                continue;
            }
            let start = doc.span(n.id).start;
            if start < region_start || start >= region_end {
                continue;
            }
            item_lines.push(locate::line_start_at(src, start));
        }
        item_lines.sort_unstable();

        let mut out = Vec::new();
        build_renumber(src, region_start, region_end, &item_lines, &mut out);
        if out == src[region_start..region_end] {
            return Ok(());
        }
        self.commit_splice(region_start, region_end, &out)
    }

    // ── Thematic break ───────────────────────────────────────────────────────

    /// Insert a thematic break as its own block, on the line after the block
    /// `offset` sits in — blank-separated, carrying a quote's prefix. See
    /// `block_after` for the placement rules.
    pub fn insert_thematic_break(&mut self, offset: usize) -> R {
        let rule = self.syntax.thematic_break.ok_or(Error::UnsupportedFormat)?;
        if offset > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        let mut line = rule.to_vec();
        line.push(b'\n');
        self.insert_block_after(offset, &line)
    }

    /// Insert a fresh table — one header row, `rows` body rows, `cols`
    /// columns, every cell empty — as its own block after the block `offset`
    /// sits in, spelled by the format's `TableSpelling`.
    pub fn insert_table(&mut self, offset: usize, rows: usize, cols: usize) -> R {
        let spelling = self.syntax.table_spelling.ok_or(Error::UnsupportedFormat)?;
        if offset > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        if rows == 0 || cols == 0 {
            return Err(Error::InvalidShape);
        }
        let grid = table_edit::blank(cols, rows).map_err(map_table_err)?;
        let bytes = table_edit::emit(&grid, &spelling);
        self.insert_block_after(offset, &bytes)
    }

    /// Insert a LEAF DIRECTIVE — Markdown's `::name[label]{attrs}` — as its own
    /// block after the block `offset` sits in, printed through the format's
    /// renderer. Gated on `Syntax::names_leaf_containers`. `InvalidAttribute`
    /// for an attribute outside `check_attr`'s grammar, a bare key included;
    /// `InvalidLabel` for a non-empty label where the format has no
    /// `Syntax::labels_leaf_containers`, or one the brackets cannot hold.
    pub fn insert_directive(&mut self, offset: usize, name: &[u8], label: Option<&[u8]>, attrs: &[KeyVal]) -> R {
        if !self.syntax.names_leaf_containers {
            return Err(Error::UnsupportedFormat);
        }
        let render = self.syntax.render_block.ok_or(Error::UnsupportedFormat)?;
        if offset > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        check_directive_name(name)?;
        for kv in attrs {
            check_attr(kv)?;
        }
        // Where the format has nowhere to put a label, an empty one is no
        // label and any other is refused.
        let label = match label {
            Some(l) if !self.syntax.labels_leaf_containers && !l.is_empty() => return Err(Error::InvalidLabel),
            Some(_) if !self.syntax.labels_leaf_containers => None,
            label => label,
        };
        if let Some(l) = label {
            if contains_any(l, b"\r\n[]") {
                return Err(Error::InvalidLabel);
            }
        }
        let mut b = Builder::new();
        let mut children = Vec::new();
        if let Some(l) = label {
            children.push(b.add_leaf(Kind::Str(l.to_vec())));
        }
        let root = b.add_container(Kind::Container(Container::with_form(name, Form::BlockLeaf)), &children);
        if !attrs.is_empty() {
            b.set_attrs(root, Attrs { entries: attrs.to_vec() });
        }
        let view = b.view(root);
        let mut out = Vec::new();
        render_node(self.syntax, render, &view, root, &mut out)?;
        self.insert_block_after(offset, &out)
    }

    /// Write `body` — one or more `\n`-terminated lines — as a block of its
    /// own after the block `offset` sits in.
    fn insert_block_after(&mut self, offset: usize, body: &[u8]) -> R {
        let mut out = Vec::new();
        let pos = self.block_after(offset, body, &mut out);
        self.commit_splice(pos, pos, &out)
    }

    /// `insert_block_after`'s bytes without the splice: fills `out` with what
    /// goes in and answers where it goes. After the caret's line-owning block
    /// (a fence and a table included), or ON a blank caret line; blank-
    /// separated on both sides where the neighbour is not already blank;
    /// every line behind the block's quote prefix.
    fn block_after(&self, offset: usize, body: &[u8], out: &mut Vec<u8>) -> usize {
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let block = locate::line_owning_block(doc, offset).map(|lb| lb.block);
        let line_start = locate::line_start_at(src, offset);
        let on_blank = block.is_none()
            && locate::is_blank_line(locate::line_body(&src[line_start..locate::line_end_at(src, offset)]));
        let pos = if on_blank {
            line_start
        } else {
            locate::line_end_at(src, block.map(|b| doc.span(b).end.saturating_sub(1)).unwrap_or(offset))
        };
        let prefix: &[u8] = match block {
            Some(b) => container_prefix(src, doc.span(b).start),
            None => b"",
        };
        let blank = trim_end(prefix, b" ");

        if pos > 0 {
            if src[pos - 1] != b'\n' {
                out.push(b'\n');
            }
            let above = &src[locate::line_start_at(src, pos - 1)..pos];
            if !locate::is_blank_line(locate::line_body(above)) {
                out.extend_from_slice(blank);
                out.push(b'\n');
            }
        }
        for l in trim_end(body, b"\n").split(|&c| c == b'\n') {
            out.extend_from_slice(prefix);
            out.extend_from_slice(l);
            out.push(b'\n');
        }
        if pos < src.len() && !locate::is_blank_line(locate::line_body(&src[pos..locate::line_end_at(src, pos)])) {
            out.extend_from_slice(blank);
            out.push(b'\n');
        }
        pos
    }

    // ── Verse ──────────────────────────────────────────────────────────────

    /// Make the paragraphs `[start, end)` touches a verse, or a verse back
    /// into paragraphs — the one Verse button. ON: each paragraph a stanza,
    /// every break a line end; a wrapper div whose children they are exactly
    /// becomes the verse. OFF: one paragraph per stanza. `NotEditable` across
    /// non-paragraph siblings or inside a list item.
    pub fn toggle_line_block(&mut self, start: usize, end: usize) -> R {
        if !self.syntax.line_blocks {
            return Err(Error::UnsupportedFormat);
        }
        let render = self.syntax.render_block.ok_or(Error::UnsupportedFormat)?;
        self.check_range(start, end)?;
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let chain = locate::caret_chain_vec(doc, start);
        if inside_list_item(doc, &chain) {
            return Err(Error::NotEditable);
        }
        if let Some(lb) = locate::innermost_of_kind(doc, &chain, Tag::LineBlock) {
            return self.unwrap_line_block(lb, render);
        }
        let (first, parent) = innermost_para(doc, &chain).ok_or(Error::NoBlock)?;
        let mut last = first;
        if end > start {
            let end_chain = locate::caret_chain_vec(doc, end);
            last = innermost_para(doc, &end_chain).ok_or(Error::NoBlock)?.0;
        }
        let mut cur = first;
        while cur != last {
            cur = ast.nodes[cur as usize].next_sibling.ok_or(Error::NotEditable)?;
            if *ast.kind(cur) != Kind::Para {
                return Err(Error::NotEditable);
            }
        }

        let wrapper = parent.and_then(|p| {
            let Kind::Container(c) = ast.kind(p) else { return None };
            if c.form != Some(Form::BlockFenced) || c.text.is_some() {
                return None;
            }
            if !c.name.is_empty() && c.name != b"div" {
                return None;
            }
            if ast.nodes[p as usize].first_child != Some(first) || ast.nodes[last as usize].next_sibling.is_some() {
                return None;
            }
            Some(p)
        });

        let mut b = Builder::new();
        let mut lines = Vec::new();
        let mut kids = Vec::new();
        let mut para = first;
        loop {
            if para != first {
                lines.push(b.add_container(Kind::Line { indent: 0 }, &[]));
            }
            for c in ast.child_ids(para) {
                match ast.kind(c) {
                    Kind::SoftBreak | Kind::HardBreak => {
                        if !kids.is_empty() {
                            lines.push(b.add_container(Kind::Line { indent: 0 }, &kids));
                        }
                        kids.clear();
                    }
                    _ => kids.push(b.graft_subtree(ast, c)),
                }
            }
            if !kids.is_empty() {
                lines.push(b.add_container(Kind::Line { indent: 0 }, &kids));
            }
            kids.clear();
            if para == last {
                break;
            }
            para = ast.nodes[para as usize].next_sibling.unwrap();
        }
        let root = b.add_container(Kind::LineBlock, &lines);
        let mut target = Span::new(doc.span(first).start, doc.span(last).end);
        if let Some(w) = wrapper {
            let attrs = ast.attrs_of(w);
            if !attrs.is_empty() {
                b.set_attrs(root, attrs.clone());
            }
            target = self.with_attr_line(w);
        }
        let target = self.without_line_end(target);
        self.splice_rendered_prefixed(&b, root, render, target)
    }

    /// `span` short of the line end(s) it closes on.
    fn without_line_end(&self, span: Span) -> Span {
        let src = self.source_bytes();
        let mut end = span.end;
        while end > span.start && (src[end - 1] == b'\n' || src[end - 1] == b'\r') {
            end -= 1;
        }
        Span::new(span.start, end)
    }

    /// `toggle_line_block`'s OFF half: the verse `lb` as paragraphs.
    fn unwrap_line_block(&mut self, lb: NodeId, render: RenderBlockFn) -> R {
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let mut b = Builder::new();
        let mut paras = Vec::new();
        let mut kids = Vec::new();
        for line in ast.child_ids(lb) {
            if ast.nodes[line as usize].first_child.is_none() {
                if !kids.is_empty() {
                    paras.push(b.add_container(Kind::Para, &kids));
                }
                kids.clear();
                continue;
            }
            if !kids.is_empty() {
                kids.push(b.add_leaf(Kind::SoftBreak));
            }
            let indent = match ast.kind(line) {
                Kind::Line { indent } => *indent as usize,
                _ => 0,
            };
            if indent != 0 {
                kids.push(b.add_leaf(Kind::Str(verse::EM_SPACE.repeat(indent))));
            }
            for c in ast.child_ids(line) {
                kids.push(b.graft_subtree(ast, c));
            }
        }
        if !kids.is_empty() {
            paras.push(b.add_container(Kind::Para, &kids));
        }
        if paras.is_empty() {
            paras.push(b.add_container(Kind::Para, &[]));
        }
        let attrs = ast.attrs_of(lb);
        let root = if !attrs.is_empty() {
            let div = b.add_container(Kind::Container(Container::with_form(b"div", Form::BlockFenced)), &paras);
            b.set_attrs(div, attrs.clone());
            div
        } else if paras.len() == 1 {
            paras[0]
        } else {
            b.add_container(Kind::Doc, &paras)
        };
        let target = self.without_line_end(self.with_attr_line(lb));
        self.splice_rendered_prefixed(&b, root, render, target)
    }

    /// `id`'s span, widened back over an attribute line written before it.
    fn with_attr_line(&self, id: NodeId) -> Span {
        let doc = &self.splicer.doc;
        let span = doc.span(id);
        let Some(attrs) = doc.attrs_span(id) else { return span };
        if attrs.start >= span.start {
            return span;
        }
        Span::new(locate::line_start_at(&doc.source, attrs.start), span.end)
    }

    // ── Block attributes ───────────────────────────────────────────────────

    /// Replace the attribute set of the block `offset` sits in — a paragraph
    /// or heading — with `attrs` (REPLACE, not merge; empty clears). Three
    /// spellings by `Syntax::block_attrs`: a `{…}` line rewritten in place
    /// (djot), the block re-printed (HTML, AsciiDoc), or a `<div>` wrapper
    /// (Markdown under `html_elements`).
    pub fn set_block_attrs(&mut self, offset: usize, attrs: &[KeyVal]) -> R {
        let shape = self.syntax.block_attrs.ok_or(Error::UnsupportedFormat)?;
        let render = self.syntax.render_block.ok_or(Error::UnsupportedFormat)?;
        if offset > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        for kv in attrs {
            check_attr(kv)?;
        }
        let block = locate::innermost_block(&self.splicer.doc, offset).ok_or(Error::NoBlock)?;
        match shape {
            BlockAttrs::Native => match self.syntax.attr_spelling {
                Some(sp) => self.set_block_attrs_by_line(block, attrs, &sp),
                None => self.set_node_attrs_by_render(block, attrs, render),
            },
            BlockAttrs::Wrapped => self.set_block_attrs_by_wrap(block, attrs, render),
        }
    }

    fn set_block_attrs_by_line(&mut self, block: NodeId, attrs: &[KeyVal], sp: &crate::syntax::AttrSpelling) -> R {
        let doc = &self.splicer.doc;
        let src = self.source_bytes();
        let existing = doc.attrs_span(block);
        if existing.is_none() && !doc.ast.attrs_of(block).is_empty() {
            return Err(Error::NotEditable);
        }
        let mut out = Vec::new();
        if !attrs.is_empty() {
            crate::attrs_writer::write(&mut out, &Attrs { entries: attrs.to_vec() }, sp, b"");
        }
        if let Some(es) = existing {
            if !attrs.is_empty() {
                return self.commit_splice(es.start, es.end, &out);
            }
            let ls = locate::line_start_at(src, es.start);
            let le = locate::line_end_at(src, es.end);
            let prefix = container_prefix(src, es.start);
            let before = &src[ls..es.start];
            let alone = before.starts_with(prefix)
                && locate::is_blank_line(&before[prefix.len()..])
                && locate::is_blank_line(locate::line_body(&src[es.end..le]));
            if !alone {
                return self.commit_splice(es.start, es.end, b"");
            }
            return self.commit_splice(ls, le, b"");
        }
        if attrs.is_empty() {
            return Ok(());
        }
        let bs = doc.span(block).start;
        let ls = locate::line_start_at(src, bs);
        let prefix = container_prefix(src, bs);
        let content_start = bs.max(ls + prefix.len());
        if !locate::is_blank_line(&src[ls + prefix.len()..content_start]) {
            return Err(Error::NotEditable);
        }
        let mut line = prefix.to_vec();
        line.extend_from_slice(&out);
        line.push(b'\n');
        self.commit_splice(ls, ls, &line)
    }

    /// `set_block_attrs` over a format whose attributes live on the block's
    /// own spelling: rebuild the block with the new set and print it.
    fn set_node_attrs_by_render(&mut self, block: NodeId, attrs: &[KeyVal], render: RenderBlockFn) -> R {
        let doc = &self.splicer.doc;
        let mut b = Builder::new();
        let kids: Vec<NodeId> = doc.ast.child_ids(block).into_iter().map(|c| b.graft_subtree(&doc.ast, c)).collect();
        let root = b.add_container(doc.ast.kind(block).clone(), &kids);
        if !attrs.is_empty() {
            b.set_attrs(root, Attrs { entries: attrs.to_vec() });
        }
        let span = doc.span(block);
        self.splice_rendered(&b, root, render, span.start, span.end)
    }

    /// `set_block_attrs` where the attributes come back on a container around
    /// the block — Markdown's `<div>`.
    fn set_block_attrs_by_wrap(&mut self, block: NodeId, attrs: &[KeyVal], render: RenderBlockFn) -> R {
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let block_span = doc.span(block);
        let chain = locate::ancestor_chain_vec(doc, block_span.start);
        let mut wrapper: Option<NodeId> = None;
        for (i, &id) in chain.iter().enumerate() {
            if id != block || i == 0 {
                continue;
            }
            let parent = chain[i - 1];
            let Kind::Container(c) = ast.kind(parent) else { break };
            if c.form != Some(Form::BlockFenced) {
                break;
            }
            if !c.name.is_empty() && c.name != b"div" {
                break;
            }
            if !c.name.is_empty() && doc.container_origin(parent) == Some(ContainerOrigin::Directive) {
                break;
            }
            if ast.nodes[parent as usize].first_child != Some(block) || ast.nodes[block as usize].next_sibling.is_some()
            {
                break;
            }
            wrapper = Some(parent);
            break;
        }
        if inside_list_item(doc, &chain) {
            return Err(Error::NotEditable);
        }
        let mut b = Builder::new();
        let grafted = b.graft_subtree(ast, block);
        let target = match wrapper {
            Some(w) => doc.span(w),
            None => block_span,
        };
        if attrs.is_empty() {
            if wrapper.is_none() {
                return Ok(());
            }
            return self.splice_rendered_prefixed(&b, grafted, render, target);
        }
        let root = b.add_container(Kind::Container(Container::with_form(b"div", Form::BlockFenced)), &[grafted]);
        b.set_attrs(root, Attrs { entries: attrs.to_vec() });
        self.splice_rendered_prefixed(&b, root, render, target)
    }

    /// Wrap `span` in an anonymous inline container carrying `attrs` — djot's
    /// `[text]{…}`, HTML's and Markdown's `<span …>` — or REPLACE the
    /// attributes of the span already covering the range; an empty set there
    /// unwraps it.
    pub fn wrap_range_attrs(&mut self, span: Span, attrs: &[KeyVal]) -> R {
        if !self.syntax.inline_attrs {
            return Err(Error::UnsupportedFormat);
        }
        let render = self.syntax.render_block.ok_or(Error::UnsupportedFormat)?;
        self.check_range(span.start, span.end)?;
        for kv in attrs {
            check_attr(kv)?;
        }
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let src = self.source_bytes();
        let chain = locate::ancestor_chain_vec(doc, span.start);
        let mut existing: Option<NodeId> = None;
        for &id in chain.iter().rev() {
            let Kind::Container(c) = ast.kind(id) else { continue };
            if c.form != Some(Form::InlineText) {
                continue;
            }
            if !c.name.is_empty() && c.name != b"span" {
                continue;
            }
            if !c.name.is_empty() && doc.container_origin(id) == Some(ContainerOrigin::Directive) {
                continue;
            }
            let sp = doc.span(id);
            if sp.start <= span.start && sp.end >= span.end {
                existing = Some(id);
                break;
            }
        }

        let mut b = Builder::new();
        let mut kids = Vec::new();
        let mut target = span;
        if let Some(id) = existing {
            target = doc.span(id);
            if target.start == 0 && target.end == 0 {
                return Err(Error::NotEditable);
            }
            if let Some(a) = doc.attrs_span(id) {
                target = Span::new(target.start.min(a.start), target.end.max(a.end));
            } else if self.syntax.block_attrs == Some(BlockAttrs::Native)
                && self.syntax.attr_spelling.is_some()
                && !ast.attrs_of(id).is_empty()
            {
                return Err(Error::NotEditable);
            }
            if attrs.is_empty() {
                let cs = doc.content_span(id).ok_or(Error::NotEditable)?;
                let interior = src[cs.start..cs.end].to_vec();
                return self.commit_splice(target.start, target.end, &interior);
            }
            for c in ast.child_ids(id) {
                kids.push(b.graft_subtree(ast, c));
            }
        } else {
            if attrs.is_empty() {
                return Ok(());
            }
            if span.end == span.start {
                return Err(Error::NotEditable);
            }
            for piece in covered_inlines(doc, span.start, span.end)? {
                kids.push(match piece.text {
                    Some(t) => b.add_leaf(Kind::Str(t)),
                    None => b.graft_subtree(ast, piece.node),
                });
            }
        }
        let root = b.add_container(Kind::Container(Container::with_form(b"", Form::InlineText)), &kids);
        b.set_attrs(root, Attrs { entries: attrs.to_vec() });
        self.splice_rendered(&b, root, render, target.start, target.end)
    }

    /// `splice_rendered` for a fragment of several lines going into a quote:
    /// every line after the first takes the quote prefix the first already
    /// sits behind, a blank line its marker alone.
    fn splice_rendered_prefixed(&mut self, b: &Builder, root: NodeId, render: RenderBlockFn, target: Span) -> R {
        let src = self.source_bytes();
        let prefix = container_prefix(src, target.start).to_vec();
        let blank = trim_end(&prefix, b" ").to_vec();
        let start = target.start.max(locate::line_start_at(src, target.start) + prefix.len());
        let view = b.view(root);
        let mut out = Vec::new();
        render_node(self.syntax, render, &view, root, &mut out)?;
        let rendered = trim_end(&out, b"\r\n");
        if prefix.is_empty() {
            return self.commit_splice(start, target.end, rendered);
        }
        let mut text = Vec::new();
        for (i, l) in rendered.split(|&c| c == b'\n').enumerate() {
            if i > 0 {
                text.push(b'\n');
                text.extend_from_slice(if l.is_empty() { &blank } else { &prefix });
            }
            text.extend_from_slice(l);
        }
        self.commit_splice(start, target.end, &text)
    }

    // ── Node attributes ────────────────────────────────────────────────────

    /// Replace the attribute set of node `id` with `attrs` — an element,
    /// addressed by id. The run is written on the node's own opening spelling
    /// at the span the parser recorded; a node with no attributes yet gets the
    /// run right after its name. Every other byte stays where it is.
    pub fn set_node_attrs(&mut self, id: NodeId, attrs: &[KeyVal]) -> R {
        let spelling = self.syntax.node_attrs.ok_or(Error::UnsupportedFormat)?;
        let doc = &self.splicer.doc;
        if id as usize >= doc.ast.nodes.len() {
            return Err(Error::InvalidRange);
        }
        for kv in attrs {
            check_attr(kv)?;
        }
        let Kind::Container(c) = doc.ast.kind(id) else { return Err(Error::NotEditable) };
        if doc.container_origin(id) != Some(ContainerOrigin::Element) {
            return Err(Error::NotEditable);
        }
        let existing = doc.attrs_span(id);
        if existing.is_none() && !doc.ast.attrs_of(id).is_empty() {
            return Err(Error::NotEditable);
        }
        let mut out = Vec::new();
        crate::attrs_writer::write_html_attrs(&mut out, &Attrs { entries: attrs.to_vec() });
        if let Some(es) = existing {
            return self.commit_splice(es.start, es.end, &out);
        }
        if attrs.is_empty() {
            return Ok(());
        }
        let at = doc.span(id).start + spelling.open.len() + c.name.len();
        self.commit_splice(at, at, &out)
    }

    // ── Splitting a block ────────────────────────────────────────────────────

    /// Split the block at `offset` in two AT THE CARET, both halves the SAME
    /// KIND — Enter. A paragraph gets a blank line (inside a quote, carrying
    /// its marker); a paragraph in a list item gets the item's marker
    /// verbatim (a task item's new half an unchecked box); a heading repeats
    /// its marker; a fenced code block is closed and reopened with its
    /// opening line verbatim. The second half sheds its leading blanks (not
    /// in code). `NotEditable` for a table, a setext heading or an indented
    /// code block; `NoBlock` when nothing covers `offset`.
    pub fn split_block(&mut self, offset: usize) -> R {
        let separator = self.syntax.block_separator.ok_or(Error::UnsupportedFormat)?;
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let found = split_target(doc, offset).ok_or(Error::NoBlock)?;
        let block_start = doc.span(found.block).start;
        let prefix = container_prefix(src, block_start);
        let blank = trim_end(prefix, b" ");
        let at_line_start = offset == 0 || src[offset - 1] == b'\n';

        let mut out = Vec::new();
        let mut shed = 0;
        match split_shape(doc.ast.kind(found.block).tag()) {
            SplitShape::Text => {
                let mut marker = Vec::new();
                let in_item = self.split_marker(found, block_start, &mut marker)?;
                while offset + shed < src.len() && (src[offset + shed] == b' ' || src[offset + shed] == b'\t') {
                    shed += 1;
                }
                if !at_line_start {
                    out.push(b'\n');
                }
                if !in_item {
                    out.extend_from_slice(blank);
                    out.extend_from_slice(separator);
                }
                out.extend_from_slice(prefix);
                out.extend_from_slice(&marker);
            }
            SplitShape::Code => {
                let fence = self.syntax.code_fence.ok_or(Error::UnsupportedFormat)?;
                let open = &src[locate::line_start_at(src, block_start)..locate::line_end_at(src, block_start)];
                let at = fence_at(open, fence.char, fence.min).ok_or(Error::NotEditable)?;
                if !at_line_start {
                    out.push(b'\n');
                }
                out.extend_from_slice(prefix);
                repeat(&mut out, fence.char, at.1);
                out.push(b'\n');
                out.extend_from_slice(blank);
                out.extend_from_slice(separator);
                out.extend_from_slice(prefix);
                out.extend_from_slice(&locate::line_body(open)[at.0..]);
                out.push(b'\n');
            }
            SplitShape::Refuse => return Err(Error::NotEditable),
        }
        self.commit_splice(offset, offset + shed, &out)
    }

    /// Append to `out` what the second half of a split must carry to come
    /// back as the SAME KIND as the first. Returns whether the block is in a
    /// LIST ITEM.
    fn split_marker(&self, found: locate::LineBlock, block_start: usize, out: &mut Vec<u8>) -> R<bool> {
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let parent_tag = doc.ast.kind(found.parent).tag();
        let in_item = parent_tag == Tag::ListItem || parent_tag == Tag::TaskListItem;
        if in_item {
            let item_start = doc.span(found.parent).start;
            let line = &src[locate::line_start_at(src, item_start)..locate::line_end_at(src, item_start)];
            let mut from = 0;
            while let Some(j) = skip_quote_marker(line, from) {
                from = j;
            }
            let m = list_marker_at(line, from).ok_or(Error::NotEditable)?;
            out.extend_from_slice(&line[from..m.1]);
            if parent_tag == Tag::TaskListItem {
                let bx = self.syntax.task_marker.ok_or(Error::NotEditable)?;
                out.extend_from_slice(bx.unchecked);
                out.extend_from_slice(bx.space);
            }
        }
        let Kind::Heading { level } = doc.ast.kind(found.block) else { return Ok(in_item) };
        let marker = self.syntax.heading_marker.ok_or(Error::UnsupportedFormat)?;
        let line = &src[locate::line_start_at(src, block_start)..locate::line_end_at(src, block_start)];
        let mut i = 0;
        while let Some(j) = skip_quote_marker(line, i) {
            i = j;
        }
        if let Some(m) = list_marker_at(line, i) {
            i = m.1;
        }
        while i < line.len() && line[i] == b' ' {
            i += 1;
        }
        if i >= line.len() || line[i] != marker {
            return Err(Error::NotEditable);
        }
        repeat(out, marker, *level as usize);
        out.push(b' ');
        Ok(in_item)
    }

    // ── Joining two blocks ───────────────────────────────────────────────────

    /// Join the block at `offset` (B) into the leaf block before it in
    /// document order (A) — Backspace at the start of a block. One splice over
    /// `[A.content_end, R_end)`: the separator (`line_join` plus A's
    /// continuation prefix, or a space after a marker heading), B's content,
    /// then A's tail (its closing markup and its containers' closers) carried
    /// past. `NoBlock` when B is the first block; `NotEditable` for A not a
    /// paragraph/heading, a table cell, a setext B, a delimited container B
    /// cannot leave, or a gap holding anything but separation.
    pub fn join_blocks(&mut self, offset: usize) -> R {
        let join = self.syntax.line_join.ok_or(Error::UnsupportedFormat)?;
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        if let Some(lb) = locate::line_owning_block(doc, offset) {
            if doc.ast.kind(lb.block).tag() == Tag::Table {
                return Err(Error::NotEditable);
            }
        }
        let b = locate::innermost_block(doc, offset).ok_or(Error::NoBlock)?;
        if is_setext_heading(doc, b) {
            return Err(Error::NotEditable);
        }
        let b_chain = node_path(doc, b).ok_or(Error::NoBlock)?;
        if passes_through_table(doc, &b_chain) {
            return Err(Error::NotEditable);
        }
        let a = preceding_leaf_block(doc, b).ok_or(Error::NoBlock)?;
        if !matches!(doc.ast.kind(a), Kind::Para | Kind::Heading { .. }) {
            return Err(Error::NotEditable);
        }
        let a_chain = node_path(doc, a).ok_or(Error::NotEditable)?;
        if passes_through_table(doc, &a_chain) {
            return Err(Error::NotEditable);
        }
        let mut i = 0;
        while i < a_chain.len() && i < b_chain.len() && a_chain[i] == b_chain[i] {
            i += 1;
        }
        if i >= a_chain.len() || i >= b_chain.len() {
            return Err(Error::NotEditable);
        }
        let a_top = a_chain[i];
        let b_top = b_chain[i];
        if !gap_is_clean(doc, src, &a_chain[..i], a_top, b_top) {
            return Err(Error::NotEditable);
        }

        let mut r_end = doc.span(b).end;
        for &id in &b_chain[i..b_chain.len() - 1] {
            if !writes_closers(doc, src, id) {
                continue;
            }
            if last_leaf_block(doc, id) != Some(b) {
                return Err(Error::NotEditable);
            }
            r_end = doc.span(id).end;
            break;
        }

        let mut separate_rest = false;
        if b_top != b && r_end == doc.span(b).end {
            let line_start =
                if r_end > 0 && src[r_end - 1] == b'\n' { r_end } else { locate::line_end_at(src, r_end) };
            let line_end = locate::line_end_at(src, line_start);
            if line_start < src.len() && line_end < doc.span(b_top).end {
                let line = locate::line_body(&src[line_start..line_end]);
                let mut k = 0;
                while let Some(j) = skip_quote_marker(line, k) {
                    k = j;
                }
                if k > 0 && trim(&line[k..], b" \t").is_empty() {
                    r_end = line_end;
                    separate_rest = true;
                }
            }
        }

        let a_content = block_content(doc, a);
        let b_content = block_content(doc, b);
        let a_tail = trim_tail_separators(&src[a_content.end..doc.span(a_top).end]);
        let b_text = &src[b_content.start..b_content.end];

        let mut out = Vec::new();
        if doc.ast.kind(a).tag() == Tag::Heading && doc.marker_span(a).is_some() {
            out.push(b' ');
            append_as_one_line(b_text, &mut out);
        } else {
            out.extend_from_slice(join);
            locate::continuation_prefix(doc, a_content.start, &mut out);
            append_as_continuation(self.syntax, b_text, &mut out);
        }
        out.extend_from_slice(a_tail);
        if r_end > a_content.end && src[r_end - 1] == b'\n' && out.last() != Some(&b'\n') {
            out.push(b'\n');
        }
        if separate_rest {
            if out.last() != Some(&b'\n') {
                out.push(b'\n');
            }
            let mut prefix = Vec::new();
            locate::continuation_prefix(doc, a_content.start, &mut prefix);
            out.extend_from_slice(trim_end(&prefix, b" "));
            out.push(b'\n');
        }
        self.commit_splice(a_content.end, r_end, &out)
    }

    // ── Moving a block ───────────────────────────────────────────────────────

    /// Move the block at `from` to the boundary `to` names, spelling the line
    /// prefixes of the container it lands in — a drag-and-drop. The block is
    /// the deepest block owning `from`'s line, widened to its list item when
    /// it is the item's first block. `to` is a position BETWEEN blocks (see the
    /// Zig doc comment of `moveBlock` for the boundary rules). One splice.
    /// `NoBlock` on a blank line; `NotEditable` for a `to` interior to a block;
    /// `InvalidArgument` for a `to` inside the block or on its own boundary.
    pub fn move_block(&mut self, from: usize, to: usize) -> R {
        if !supports(self.syntax, Gesture::MoveBlock) {
            return Err(Error::UnsupportedFormat);
        }
        let syntax = self.syntax;
        let src = self.source_bytes();
        if from > src.len() || to > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let unit = movable_unit(doc, from).ok_or(Error::NoBlock)?;
        let unit_chain = node_path(doc, unit).ok_or(Error::NoBlock)?;
        let ancestors = &unit_chain[..unit_chain.len() - 1];
        let lines = unit_lines(doc, unit, ancestors)?;
        let own = if is_list_item(doc.ast.kind(unit)) {
            let sp = doc.span(unit);
            let mut end = sp.end;
            if end > sp.start && src[end - 1] == b'\n' {
                end -= 1;
            }
            Span::new(doc.marker_span(unit).map(|m| m.end).unwrap_or(sp.start), end)
        } else {
            block_content(doc, unit)
        };
        if to > own.start && to < own.end {
            return Err(Error::InvalidArgument);
        }
        let unit_is_item = is_list_item(doc.ast.kind(unit));
        let mut dest = resolve_boundary(syntax, doc, to, unit)?;

        let dest_chain = node_path(doc, dest.container).ok_or(Error::NotEditable)?;
        if dest_chain.contains(&unit) {
            return Err(Error::InvalidArgument);
        }
        let removal = removal_lines(syntax, doc, &unit_chain, lines);
        if dest.pos > removal.start && dest.pos < removal.end {
            dest.pos = removal.start;
        }
        let dest_walk = prefix_chain(syntax, doc, &dest_chain);
        let mut prefix = Vec::new();
        locate::continuation_prefix_along(doc, &dest_walk, &mut prefix);
        let blank_prefix = trim_end(&prefix, b" \t").to_vec();

        let mut sep = Vec::new();
        let separates = syntax.block_separator.is_some()
            && !(unit_is_item && is_tight_list(doc.ast.kind(dest.container)));
        if separates {
            sep.extend_from_slice(&blank_prefix);
            if let Some(attach) = syntax.list_attach {
                if is_list_item(doc.ast.kind(dest.container)) {
                    sep.extend_from_slice(attach);
                }
            }
            sep.extend_from_slice(syntax.block_separator.unwrap());
        }

        let old_walk = prefix_chain(syntax, doc, ancestors);
        let mut old_prefix = Vec::new();
        let old_cols = locate::continuation_prefix_along(doc, &old_walk, &mut old_prefix);
        let own_start = doc.marker_span(unit).map(|m| m.start).unwrap_or_else(|| block_content(doc, unit).start);

        let mut rewrap: Option<Span> = None;
        let mut rewrapped = Vec::new();
        if syntax.block_separator.is_none() && is_list_item(doc.ast.kind(dest.container)) {
            if let Some(p) = dest.prev {
                if is_bare_paragraph(doc, p) {
                    rewrap = Some(self.rewrap_block(p, &mut rewrapped)?);
                }
            }
        }

        #[derive(Clone, Copy, PartialEq, Eq)]
        enum EditKind {
            Removal,
            Rewrap,
            Insert,
        }
        let mut edits: Vec<(Span, EditKind)> = vec![(removal, EditKind::Removal)];
        if let Some(r) = rewrap {
            edits.push((r, EditKind::Rewrap));
        }
        edits.push((Span::new(dest.pos, dest.pos), EditKind::Insert));
        edits.sort_by(|a, b| (a.0.start, a.0.end).cmp(&(b.0.start, b.0.end)));
        let n = edits.len();
        let region_start = edits[0].0.start;
        let region_end = edits[n - 1].0.end;

        let mut out = Vec::new();
        let mut cur = region_start;
        for (i, &(es, kind)) in edits.iter().enumerate() {
            if es.start < cur {
                return Err(Error::NotEditable);
            }
            out.extend_from_slice(&src[cur..es.start]);
            cur = es.end;
            match kind {
                EditKind::Removal => {}
                EditKind::Rewrap => out.extend_from_slice(trim_end(&rewrapped, b"\r\n")),
                EditKind::Insert => {
                    let before = last_line_of(&src[..region_start], &out);
                    if !before.terminated {
                        out.push(b'\n');
                    }
                    if separates && dest.prev.is_some() && !before.empty && !is_separator_line(syntax, &before.body) {
                        out.extend_from_slice(&sep);
                    }
                    self.append_moved_lines(
                        &mut out,
                        lines,
                        ancestors,
                        unit_is_item,
                        dest.container,
                        old_cols,
                        own_start,
                        &prefix,
                        &blank_prefix,
                    );
                    let rest_to = if i + 1 < n { edits[i + 1].0.start } else { src.len() };
                    let rest_from = if i + 1 < n { edits[i + 1].0.end } else { src.len() };
                    let after = first_line_of(&src[es.end..rest_to], &src[rest_from..]);
                    if separates && dest.next.is_some() && !after.is_empty() && !is_separator_line(syntax, after) {
                        out.extend_from_slice(&sep);
                    }
                }
            }
        }
        out.extend_from_slice(&src[cur..region_end]);
        if region_end == src.len() && !src.is_empty() && src[src.len() - 1] != b'\n' && out.last() == Some(&b'\n') {
            out.pop();
        }
        self.commit_splice(region_start, region_end, &out)
    }

    /// The block's lines, each behind the destination prefix, appended to
    /// `out`. An item landing outside a list brings its list's own opening and
    /// closing lines with it.
    #[allow(clippy::too_many_arguments)]
    fn append_moved_lines(
        &self,
        out: &mut Vec<u8>,
        lines: Span,
        ancestors: &[NodeId],
        unit_is_item: bool,
        container: NodeId,
        old_cols: usize,
        own_start: usize,
        prefix: &[u8],
        blank_prefix: &[u8],
    ) {
        let doc = &self.splicer.doc;
        let src = &doc.source;
        let mut wrap = ListWrap::default();
        if unit_is_item && !is_list(doc.ast.kind(container)) {
            wrap = list_wrap(doc, ancestors[ancestors.len() - 1], lines);
        }
        let mut first = true;
        for part in [wrap.open, lines, wrap.close] {
            let mut at = part.start;
            while at < part.end {
                let le = locate::line_end_at(src, at);
                let body = locate::line_body(&src[at..le]);
                let mut strip = strip_columns(body, old_cols);
                if first {
                    for &a in ancestors {
                        if let Some(m) = doc.marker_span(a) {
                            if m.start >= at && m.start < le && m.end - at > strip {
                                strip = m.end - at;
                            }
                        }
                    }
                    if own_start > at && own_start - at < strip {
                        strip = own_start - at;
                    }
                }
                let rest = &body[strip.min(body.len())..];
                if locate::is_blank_line(rest) {
                    out.extend_from_slice(blank_prefix);
                } else {
                    out.extend_from_slice(prefix);
                    out.extend_from_slice(rest);
                }
                out.push(b'\n');
                first = false;
                at = le;
            }
        }
    }

    /// Print `block` through the format's renderer into `w`, returning the
    /// span the print replaces.
    fn rewrap_block(&self, block: NodeId, w: &mut Vec<u8>) -> R<Span> {
        let render = self.syntax.render_block.ok_or(Error::UnsupportedFormat)?;
        let doc = &self.splicer.doc;
        let mut b = Builder::new();
        let root = b.graft_subtree(&doc.ast, block);
        let view = b.view(root);
        render_node(self.syntax, render, &view, root, w)?;
        Ok(doc.span(block))
    }

    // ── Code blocks ──────────────────────────────────────────────────────────

    /// Toggle a fenced code block over the blocks `span` covers: fence them if
    /// the caret isn't in a code block, unfence the one it is in if it is.
    /// Fencing inserts the two fence lines (behind the containers' prefix, a
    /// list item's head moved onto the opening fence); the fence is one longer
    /// than the longest run of the fence byte in the body. Unfencing peels
    /// them (an indented Markdown block is dedented instead). Where the format
    /// has no fence but a renderer, a `code_block` node is printed.
    pub fn toggle_code_block(&mut self, span: Span, lang: Option<&[u8]>) -> R {
        self.check_range(span.start, span.end)?;
        let Some(fence) = self.syntax.code_fence else {
            if let Some(render) = self.syntax.render_block {
                return self.toggle_code_block_by_render(span, lang, render);
            }
            return Err(Error::UnsupportedFormat);
        };
        if let Some(l) = lang {
            check_info_string(&fence, l)?;
        }
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let chain = locate::ancestor_chain_vec(doc, span.start);
        let mut out = Vec::new();

        if let Some(cb) = locate::innermost_of_kind(doc, &chain, Tag::CodeBlock) {
            let at = chain.iter().position(|&x| x == cb).unwrap();
            let frame = CodeFrame::new(self.syntax, doc, &chain[..at]);
            let b = doc.span(cb);
            let region_start = locate::line_start_at(src, b.start);
            let region_end = locate::line_end_at(src, b.end.saturating_sub(1));
            let end = build_unfence(doc, &frame, cb, region_start, region_end, &fence, &mut out);
            return self.commit_splice(region_start, end, &out);
        }

        let blocks = covered_blocks(doc, span.start, span.end).map_err(|_| Error::NoBlock)?;
        let region_start = locate::line_start_at(src, doc.span(blocks.first).start);
        let region_end = locate::line_end_at(src, doc.span(blocks.last).end.saturating_sub(1));
        if let Some(label) = labelled_parent(doc, &blocks, region_start) {
            let lang = lang.map(|l| l.to_vec());
            return self.rewrap_labelled(label, &blocks, |b, _, _, body| {
                b.add_leaf(Kind::CodeBlock { lang, text: body.to_vec() })
            });
        }
        let at = blocks.chain.iter().position(|&x| x == blocks.first).ok_or(Error::NoBlock)?;
        let frame = CodeFrame::new(self.syntax, doc, &blocks.chain[..at]);
        if self.syntax.list_attach.is_some() && frame.opens_item(doc, region_start) {
            return Err(Error::NotEditable);
        }
        let width = fence_width(&src[region_start..region_end], fence.char, fence.min);

        let head = frame.head_len(doc, region_start);
        match head {
            Some(h) => out.extend_from_slice(&src[region_start..region_start + h]),
            None => out.extend_from_slice(&frame.prefix),
        }
        repeat(&mut out, fence.char, width);
        if let Some(l) = lang {
            out.extend_from_slice(l);
        }
        out.push(b'\n');
        let mut line_start = region_start;
        while line_start < region_end {
            let line_end = locate::line_end_at(src, line_start);
            let body = locate::line_body(&src[line_start..line_end]);
            let ending = &src[line_start + body.len()..line_end];
            let st = frame.strip(body);
            if line_start == region_start && head.is_some() {
                frame.write_line(&mut out, 0, &body[head.unwrap()..], ending);
            } else if st.full {
                out.extend_from_slice(&src[line_start..line_end]);
            } else {
                frame.write_line(&mut out, 0, &body[st.len..], ending);
            }
            line_start = line_end;
        }
        if out.last() != Some(&b'\n') {
            out.push(b'\n');
        }
        out.extend_from_slice(&frame.prefix);
        repeat(&mut out, fence.char, width);
        out.push(b'\n');
        self.commit_splice(region_start, region_end, &out)
    }

    /// Retag the code block at `offset` with `lang`, or clear its info string
    /// when `lang` is `None`. Only the info string is rewritten. An indented
    /// Markdown code block is `NotEditable`.
    pub fn set_code_language(&mut self, offset: usize, lang: Option<&[u8]>) -> R {
        let Some(fence) = self.syntax.code_fence else {
            if let Some(render) = self.syntax.render_block {
                return self.set_code_language_by_render(offset, lang, render);
            }
            return Err(Error::UnsupportedFormat);
        };
        if let Some(l) = lang {
            check_info_string(&fence, l)?;
        }
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let chain = locate::ancestor_chain_vec(doc, offset);
        let cb = locate::innermost_of_kind(doc, &chain, Tag::CodeBlock).ok_or(Error::NoBlock)?;
        let line_start = locate::line_start_at(src, doc.span(cb).start);
        let line = &src[line_start..locate::line_end_at(src, line_start)];
        let f = fence_at(line, fence.char, fence.min).ok_or(Error::NotEditable)?;
        let info_start = line_start + f.0 + f.1;
        let info_end = line_start + locate::line_body(line).len();
        self.commit_splice(info_start, info_end, lang.unwrap_or(b""))
    }

    /// `toggle_code_block` over a format with no fence but a renderer: the
    /// covered blocks' TEXT becomes a `code_block`, and toggling off puts the
    /// listing's text under a paragraph.
    fn toggle_code_block_by_render(&mut self, span: Span, lang: Option<&[u8]>, render: RenderBlockFn) -> R {
        if let Some(l) = lang {
            check_language_token(l)?;
        }
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let chain = locate::ancestor_chain_vec(doc, span.start);
        if let Some(cb) = locate::innermost_of_kind(doc, &chain, Tag::CodeBlock) {
            let Kind::CodeBlock { text, .. } = ast.kind(cb) else { unreachable!() };
            let mut b = Builder::new();
            let t = b.add_leaf(Kind::Str(text.clone()));
            let root = b.add_container(Kind::Para, &[t]);
            let s = doc.span(cb);
            let end = block_span_end(src, s);
            return self.splice_rendered(&b, root, render, s.start, end);
        }
        let blocks = covered_blocks(doc, span.start, span.end).map_err(|_| Error::NoBlock)?;
        let mut text = Vec::new();
        let mut cur = Some(blocks.first);
        while let Some(c) = cur {
            if c != blocks.first {
                text.push(b'\n');
            }
            block_text_into(ast, c, &mut text);
            cur = if c == blocks.last { None } else { ast.nodes[c as usize].next_sibling };
        }
        let mut b = Builder::new();
        let root = b.add_leaf(Kind::CodeBlock { lang: lang.map(|l| l.to_vec()), text });
        let first = doc.span(blocks.first);
        let last = doc.span(blocks.last);
        let end = block_span_end(src, last);
        self.splice_rendered(&b, root, render, first.start, end)
    }

    /// `set_code_language` over a format with no fence but a renderer.
    fn set_code_language_by_render(&mut self, offset: usize, lang: Option<&[u8]>, render: RenderBlockFn) -> R {
        if let Some(l) = lang {
            check_language_token(l)?;
        }
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let chain = locate::ancestor_chain_vec(doc, offset);
        let cb = locate::innermost_of_kind(doc, &chain, Tag::CodeBlock).ok_or(Error::NoBlock)?;
        let Kind::CodeBlock { text, .. } = ast.kind(cb) else { unreachable!() };
        let mut b = Builder::new();
        let root = b.add_leaf(Kind::CodeBlock { lang: lang.map(|l| l.to_vec()), text: text.clone() });
        if let Some(ai) = ast.nodes[cb as usize].attrs {
            b.set_attrs(root, ast.attrs[ai as usize].clone());
        }
        let t = doc.span(cb);
        let end = block_span_end(src, t);
        self.splice_rendered(&b, root, render, t.start, end)
    }

    // ── Task list checkboxes ─────────────────────────────────────────────────

    /// Add a checkbox to the list item at `offset`, or take one away. A box is
    /// added UNCHECKED.
    pub fn toggle_task_item(&mut self, offset: usize) -> R {
        let tm = self.syntax.task_marker.ok_or(Error::UnsupportedFormat)?;
        let found = self.locate_task_box(offset)?;
        if let Some(b) = found.bx {
            return self.commit_splice(b.start, b.end + found.space, b"");
        }
        let mut out = tm.unchecked.to_vec();
        out.extend_from_slice(tm.space);
        self.commit_splice(found.at, found.at, &out)
    }

    /// Tick or untick the task item at `offset` — rewrites the BOX ALONE. A
    /// no-op when already in the requested state; `NotEditable` with no box.
    pub fn set_task_checked(&mut self, offset: usize, checked: bool) -> R {
        let tm = self.syntax.task_marker.ok_or(Error::UnsupportedFormat)?;
        let found = self.locate_task_box(offset)?;
        let b = found.bx.ok_or(Error::NotEditable)?;
        if found.checked == checked {
            return Ok(());
        }
        self.commit_splice(b.start, b.end, if checked { tm.checked } else { tm.unchecked })
    }

    /// Flip the task item at `offset`.
    pub fn toggle_task_checked(&mut self, offset: usize) -> R {
        if self.syntax.task_marker.is_none() {
            return Err(Error::UnsupportedFormat);
        }
        let found = self.locate_task_box(offset)?;
        if found.bx.is_none() {
            return Err(Error::NotEditable);
        }
        self.set_task_checked(offset, !found.checked)
    }

    /// Where the checkbox on the list item at `offset` is, or would go.
    fn locate_task_box(&self, offset: usize) -> R<TaskBox> {
        let src = self.source_bytes();
        if offset > src.len() {
            return Err(Error::InvalidRange);
        }
        let tm = self.syntax.task_marker.ok_or(Error::UnsupportedFormat)?;
        let doc = &self.splicer.doc;
        let chain = locate::ancestor_chain_vec(doc, offset);
        let id = chain
            .iter()
            .rev()
            .copied()
            .find(|&id| matches!(doc.ast.kind(id), Kind::ListItem | Kind::TaskListItem { .. }))
            .ok_or(Error::NoBlock)?;
        let line_start = locate::line_start_at(src, doc.span(id).start);
        let line = &src[line_start..locate::line_end_at(src, line_start)];
        let mut from = 0;
        while let Some(j) = skip_quote_marker(line, from) {
            from = j;
        }
        let m = list_marker_at(line, from).ok_or(Error::NotEditable)?;
        let at = line_start + m.1;
        let rest = &line[m.1..];
        let width = tm.unchecked.len();
        if rest.len() >= width && rest[0] == b'[' && rest[width - 1] == b']' {
            let inner = &rest[1..width - 1];
            let checked = contains_any(inner, tm.checked_chars);
            if checked || locate::is_blank_line(inner) {
                return Ok(TaskBox {
                    at,
                    bx: Some(Span::new(at, at + width)),
                    space: if rest.len() > width && rest[width] == b' ' { 1 } else { 0 },
                    checked,
                });
            }
        }
        Ok(TaskBox { at, bx: None, space: 0, checked: false })
    }

    // ── Tables ───────────────────────────────────────────────────────────────

    /// Insert an empty row below (`after`) or above the caret's row.
    pub fn table_insert_row(&mut self, offset: usize, after: bool) -> R {
        self.table_edit(offset, TableOp::InsertRow(side(after)))
    }

    /// Delete the caret's row. `NotEditable` for a header row or the last body row.
    pub fn table_delete_row(&mut self, offset: usize) -> R {
        self.table_edit(offset, TableOp::DeleteRow)
    }

    /// Insert an empty column right (`after`) or left of the caret's column.
    pub fn table_insert_column(&mut self, offset: usize, after: bool) -> R {
        self.table_edit(offset, TableOp::InsertColumn(side(after)))
    }

    /// Delete the caret's column. `NotEditable` when it is the only one.
    pub fn table_delete_column(&mut self, offset: usize) -> R {
        self.table_edit(offset, TableOp::DeleteColumn)
    }

    /// Set the caret's column to `alignment`.
    pub fn table_set_alignment(&mut self, offset: usize, alignment: Alignment) -> R {
        self.table_edit(offset, TableOp::SetAlignment(alignment))
    }

    /// Move the caret's row one place down (`down`) or up.
    pub fn table_move_row(&mut self, offset: usize, down: bool) -> R {
        self.table_edit(offset, TableOp::MoveRow(side(down)))
    }

    /// Move the caret's column one place right (`right`) or left.
    pub fn table_move_column(&mut self, offset: usize, right: bool) -> R {
        self.table_edit(offset, TableOp::MoveColumn(side(right)))
    }

    /// Lift the table at `offset`, apply one grid op, and splice the rebuilt
    /// table back. The spelling is fetched FIRST: a format can have a table
    /// this can READ and none it can WRITE (HTML).
    fn table_edit(&mut self, offset: usize, op: TableOp) -> R {
        let spelling = self.syntax.table_spelling.ok_or(Error::UnsupportedFormat)?;
        if offset > self.source_bytes().len() {
            return Err(Error::InvalidRange);
        }
        let mut grid = table_edit::extract(&self.splicer.doc, offset).map_err(map_table_err)?;
        match op {
            TableOp::InsertRow(s) => table_edit::insert_row(&mut grid, s),
            TableOp::DeleteRow => table_edit::delete_row(&mut grid),
            TableOp::InsertColumn(s) => table_edit::insert_column(&mut grid, s),
            TableOp::DeleteColumn => table_edit::delete_column(&mut grid),
            TableOp::SetAlignment(a) => table_edit::set_alignment(&mut grid, a),
            TableOp::MoveRow(d) => table_edit::move_row(&mut grid, d),
            TableOp::MoveColumn(d) => table_edit::move_column(&mut grid, d),
        }
        .map_err(map_table_err)?;
        let bytes = table_edit::emit(&grid, &spelling);
        self.commit_splice(grid.region.start, grid.region.end, &bytes)
    }

    // ── Links ──────────────────────────────────────────────────────────────

    /// Link `span` to `dest`, or repoint the link already there. An existing
    /// link covering the range keeps its text; a range inside an autolink
    /// respells it whole; a range that splits an autolink is `NotEditable`. A
    /// link with no text gets `<dest>` where the format autolinks it, else
    /// `[dest](dest)`. A destination holding a line end is
    /// `InvalidDestination`. Where the format has no link alphabet but a
    /// renderer, a `link` node is printed.
    pub fn insert_link(&mut self, span: Span, dest: &[u8]) -> R {
        self.check_range(span.start, span.end)?;
        if contains_any(dest, b"\r\n") {
            return Err(Error::InvalidDestination);
        }
        if self.syntax.link_text_escapes.is_none() {
            if let Some(render) = self.syntax.render_block {
                return self.insert_link_by_render(span, dest, render, false);
            }
            return Err(Error::UnsupportedFormat);
        }
        let (start, end) = (span.start, span.end);
        let src = self.source_bytes();
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let chain = locate::ancestor_chain_vec(doc, start);

        let mut text: &[u8] = &src[start..end];
        let mut target = Span::new(start, end);
        let mut repoint = locate::innermost_covering(doc, &chain, &[Tag::Link], start, end);
        if repoint.is_none() {
            repoint = autolink_covering(doc, &chain, start, end);
        }
        if repoint.is_none() && start != end && (splits_autolink(doc, start) || splits_autolink(doc, end)) {
            return Err(Error::NotEditable);
        }
        if let Some(id) = repoint {
            let rp = doc.span(id);
            if rp.start == 0 && rp.end == 0 {
                return Err(Error::NotEditable);
            }
            let content = || doc.content_span(id).map(|cs| &src[cs.start..cs.end]).unwrap_or(b"");
            text = match ast.kind(id) {
                Kind::TextLeaf { kind: TextLeafKind::Url | TextLeafKind::Email, .. } => b"",
                _ => content(),
            };
            target = rp;
        }

        let mut out = Vec::new();
        if text.is_empty() {
            if let Some(spells) = self.syntax.spells_autolink {
                out.push(b'<');
                out.extend_from_slice(dest);
                out.push(b'>');
                if spells(self.syntax, &out) {
                    return self.commit_splice(target.start, target.end, &out);
                }
                out.clear();
            }
        }
        out.push(b'[');
        if text.is_empty() {
            write_link_text(self.syntax, dest, &mut out)?;
        } else {
            out.extend_from_slice(text);
        }
        out.extend_from_slice(b"](");
        write_link_destination(self.syntax, dest, &mut out)?;
        out.push(b')');
        self.commit_splice(target.start, target.end, &out)
    }

    /// Spell `span` as an image pointing at `dest` — `![alt](dest)`, the
    /// selected source becoming the alt text.
    pub fn insert_image(&mut self, span: Span, dest: &[u8]) -> R {
        self.check_range(span.start, span.end)?;
        if contains_any(dest, b"\r\n") {
            return Err(Error::InvalidDestination);
        }
        if self.syntax.link_text_escapes.is_none() || self.syntax.link_dest_escapes.is_none() {
            if let Some(render) = self.syntax.render_block {
                return self.insert_link_by_render(span, dest, render, true);
            }
            return Err(Error::UnsupportedFormat);
        }
        let src = self.source_bytes();
        let mut out = b"![".to_vec();
        out.extend_from_slice(&src[span.start..span.end]);
        out.extend_from_slice(b"](");
        write_link_destination(self.syntax, dest, &mut out)?;
        out.push(b')');
        self.commit_splice(span.start, span.end, &out)
    }

    /// `insert_link`/`insert_image` over a format with no link alphabet but a
    /// renderer: BUILD the node over the selection's inline nodes and print it.
    fn insert_link_by_render(&mut self, span: Span, dest: &[u8], render: RenderBlockFn, image: bool) -> R {
        let doc = &self.splicer.doc;
        let ast = &doc.ast;
        let mut b = Builder::new();
        let mut kids = Vec::new();
        let mut target = span;
        let mut attrs: Option<Attrs> = None;
        let chain = locate::ancestor_chain_vec(doc, span.start);
        let repoint =
            if image { None } else { locate::innermost_covering(doc, &chain, &[Tag::Link], span.start, span.end) };
        if let Some(id) = repoint {
            target = doc.span(id);
            if target.start == 0 && target.end == 0 {
                return Err(Error::NotEditable);
            }
            if let Some(ai) = ast.nodes[id as usize].attrs {
                attrs = Some(ast.attrs[ai as usize].clone());
            }
            for c in ast.child_ids(id) {
                kids.push(b.graft_subtree(ast, c));
            }
        } else if span.end > span.start {
            for piece in covered_inlines(doc, span.start, span.end)? {
                kids.push(match piece.text {
                    Some(t) => b.add_leaf(Kind::Str(t)),
                    None => b.graft_subtree(ast, piece.node),
                });
            }
        }
        if !image && kids.is_empty() {
            kids.push(b.add_leaf(Kind::Str(dest.to_vec())));
        }
        let payload = Link { destination: Some(dest.to_vec()), reference: None };
        let root = b.add_container(if image { Kind::Image(payload) } else { Kind::Link(payload) }, &kids);
        if let Some(a) = attrs {
            b.set_attrs(root, a);
        }
        self.splice_rendered(&b, root, render, target.start, target.end)
    }

    // ── Footnotes ────────────────────────────────────────────────────────────

    /// Insert a footnote reference at `offset` and, unless one already
    /// exists, the matching (empty) definition at the end of the document —
    /// ONE splice. `InvalidLabel` for an empty label or one holding a line end
    /// or a reference bracket.
    pub fn insert_footnote(&mut self, offset: usize, label: &[u8]) -> R {
        self.check_range(offset, offset)?;
        let fs = self.syntax.footnote.ok_or(Error::UnsupportedFormat)?;
        if label.is_empty() || contains_any(label, b"\r\n") || contains_any(label, fs.label_forbids) {
            return Err(Error::InvalidLabel);
        }
        let src = self.source_bytes();
        let mut out = fs.ref_open.to_vec();
        out.extend_from_slice(label);
        out.extend_from_slice(fs.ref_close);
        if footnote_defined(self.ast_view(), label) {
            return self.commit_splice(offset, offset, &out);
        }
        out.extend_from_slice(&src[offset..]);
        if !src.is_empty() && src[src.len() - 1] != b'\n' {
            out.push(b'\n');
        }
        if !ends_with_blank_line(src) {
            out.push(b'\n');
        }
        out.extend_from_slice(fs.ref_open);
        out.extend_from_slice(label);
        out.extend_from_slice(fs.ref_close);
        out.extend_from_slice(fs.def_suffix);
        out.push(b'\n');
        let end = src.len();
        self.commit_splice(offset, end, &out)
    }

    // ── Math ─────────────────────────────────────────────────────────────────

    /// Insert `formula` at `offset` as an INLINE formula, printed by the
    /// serializer. A formula the format cannot hold is `InvalidFormula`; one
    /// that does not come back in place (a caret in a code span) is
    /// `NotEditable`.
    pub fn insert_inline_math(&mut self, offset: usize, formula: &[u8]) -> R {
        self.check_range(offset, offset)?;
        let render = self.math_renderer(TextLeafKind::InlineMath)?;
        let bytes = self.print_formula(render, TextLeafKind::InlineMath, formula)?;
        let within = Span::new(offset, offset + bytes.len());
        let f = formula.to_vec();
        let check = move |d: &Document| formula_holds(d, TextLeafKind::InlineMath, &f, within);
        self.commit_splice_checked(offset, offset, &bytes, Some(&check))
    }

    /// Insert `formula` as a DISPLAY formula in a paragraph of its own after
    /// the block `offset` sits in (`insert_thematic_break`'s placement).
    pub fn insert_display_math(&mut self, offset: usize, formula: &[u8]) -> R {
        self.check_range(offset, offset)?;
        let render = self.math_renderer(TextLeafKind::DisplayMath)?;
        let bytes = self.print_formula(render, TextLeafKind::DisplayMath, formula)?;
        let mut block = Vec::new();
        let pos = self.block_after(offset, &bytes, &mut block);
        let within = Span::new(pos, pos + block.len());
        let f = formula.to_vec();
        let check = move |d: &Document| formula_holds(d, TextLeafKind::DisplayMath, &f, within);
        self.commit_splice_checked(pos, pos, &block, Some(&check))
    }

    fn math_renderer(&self, kind: TextLeafKind) -> R<RenderBlockFn> {
        if self.syntax.authorable_delims_for(&KindRef::TextLeaf(kind)).is_none() {
            return Err(Error::UnsupportedFormat);
        }
        self.syntax.render_block.ok_or(Error::UnsupportedFormat)
    }

    /// Print `formula` as a math leaf of `kind`, alone in a paragraph, and
    /// answer the leaf's bytes — `InvalidFormula` unless those bytes, parsed
    /// on their own, come back as that formula.
    fn print_formula(&self, render: RenderBlockFn, kind: TextLeafKind, formula: &[u8]) -> R<Vec<u8>> {
        let mut b = Builder::new();
        let leaf = b.add_leaf(Kind::TextLeaf { kind, text: formula.to_vec() });
        let root = b.add_container(Kind::Para, &[leaf]);
        let view = b.view(root);
        let mut out = Vec::new();
        render_node(self.syntax, render, &view, root, &mut out)?;
        let bytes = trim_end(&out, b"\r\n").to_vec();
        let alone = self.splicer.reparse(&bytes).map_err(|_| Error::InvalidFormula)?;
        if !formula_holds(&alone, kind, formula, Span::new(0, bytes.len())) {
            return Err(Error::InvalidFormula);
        }
        Ok(bytes)
    }

    // ── Literal text ─────────────────────────────────────────────────────────

    /// Insert `text` at `offset` as a LITERAL run: every byte the format reads
    /// as markup is escaped so the run reparses as exactly `text`. Positional:
    /// line-start escapes bite only while `offset` sits in its line's leading
    /// whitespace; inside a code span or block the run is written verbatim.
    pub fn insert_literal(&mut self, offset: usize, text: &[u8]) -> R {
        self.check_range(offset, offset)?;
        if self.syntax.render_text.is_none() {
            return Err(Error::UnsupportedFormat);
        }
        let src = self.source_bytes();
        let at_line_start = src[locate::line_start_at(src, offset)..offset].iter().all(|&c| c == b' ' || c == b'\t');
        let in_verbatim = self.inside_verbatim(offset);
        let mut out = Vec::new();
        write_literal(self.syntax, text, at_line_start, in_verbatim, &mut out).map_err(|_| Error::NotEditable)?;
        self.commit_splice(offset, offset, &out)
    }

    /// Whether writing at `offset` lands inside a body the format reads
    /// LITERALLY — a code span, a code block, a raw node.
    fn inside_verbatim(&self, offset: usize) -> bool {
        let doc = &self.splicer.doc;
        for id in locate::ancestor_chain_vec(doc, offset) {
            let literal = match doc.ast.kind(id) {
                Kind::CodeBlock { .. } | Kind::RawBlock { .. } | Kind::RawInline { .. } => true,
                Kind::TextLeaf { kind, .. } => {
                    matches!(kind, TextLeafKind::Verbatim | TextLeafKind::InlineMath | TextLeafKind::DisplayMath)
                }
                _ => false,
            };
            if !literal {
                continue;
            }
            let Some(cs) = doc.content_span(id) else { continue };
            if cs.start <= offset && offset <= cs.end {
                return true;
            }
        }
        false
    }

    /// Insert a hard line break *inside a table cell* at `offset`, spelled the
    /// format's way (`Syntax::cell_line_break`). `NoBlock` outside a cell.
    pub fn insert_line_break(&mut self, offset: usize) -> R {
        self.check_range(offset, offset)?;
        let spelling = self.syntax.cell_line_break.ok_or(Error::UnsupportedFormat)?;
        let chain = locate::ancestor_chain_vec(&self.splicer.doc, offset);
        if locate::innermost_of_kind(&self.splicer.doc, &chain, Tag::Cell).is_none() {
            return Err(Error::NoBlock);
        }
        self.commit_splice(offset, offset, spelling)
    }
}

fn side(after: bool) -> table_edit::Side {
    if after { table_edit::Side::After } else { table_edit::Side::Before }
}

#[derive(Clone, Copy, Debug)]
enum TableOp {
    InsertRow(table_edit::Side),
    DeleteRow,
    InsertColumn(table_edit::Side),
    DeleteColumn,
    SetAlignment(Alignment),
    MoveRow(table_edit::Side),
    MoveColumn(table_edit::Side),
}

/// "Not in a table" reads as no block for the gesture, a refused (degenerate)
/// edit as not editable.
fn map_table_err(e: table_edit::Error) -> Error {
    match e {
        table_edit::Error::NotInTable => Error::NoBlock,
        table_edit::Error::Refused => Error::NotEditable,
    }
}

/// What `set_block` looks for in the reparse: a heading of `level` over the
/// bytes it wrote that holds exactly `text`.
fn heading_check(doc: &Document, level: u32, text: &[u8], within: Span) -> bool {
    for n in &doc.ast.nodes {
        let Kind::Heading { level: l } = n.kind else { continue };
        if l != level {
            continue;
        }
        let sp = doc.span(n.id);
        if sp.end <= within.start || sp.start >= within.end {
            continue;
        }
        let mut rest = text;
        if !consume_text(&doc.ast, n.id, &mut rest) {
            continue;
        }
        if trim(rest, b" ").is_empty() {
            return true;
        }
    }
    false
}

/// What a math gesture looks for in the reparse: a leaf of `kind` holding
/// exactly `formula`, lying within the bytes it wrote.
fn formula_holds(doc: &Document, kind: TextLeafKind, formula: &[u8], within: Span) -> bool {
    for n in &doc.ast.nodes {
        let Kind::TextLeaf { kind: k, text } = &n.kind else { continue };
        if *k != kind || text != formula {
            continue;
        }
        let sp = doc.span(n.id);
        if sp.start >= within.start && sp.end <= within.end {
            return true;
        }
    }
    false
}

// ── Block-container internals ──────────────────────────────────────────────

/// The blocks `[start, end)` touches: sibling `first`…`last` under the nearest
/// ancestor whose children are blocks.
struct BlockRange {
    first: NodeId,
    last: NodeId,
    /// The ancestor chain down to `start`, reused for container detection.
    chain: Vec<NodeId>,
}

/// Resolve `[start, end)` to the sibling blocks it touches. `end` is pulled
/// back off a trailing newline first.
fn covered_blocks(doc: &Document, start: usize, end: usize) -> R<BlockRange> {
    let mut last_off = if end > start { end - 1 } else { start };
    while last_off > start && (doc.source[last_off] == b'\n' || doc.source[last_off] == b'\r') {
        last_off -= 1;
    }
    let chain_a = locate::ancestor_chain_vec(doc, start);
    let chain_b = locate::ancestor_chain_vec(doc, last_off);
    let mut i = 0;
    while i + 1 < chain_a.len() && i + 1 < chain_b.len() && chain_a[i + 1] == chain_b[i + 1] {
        i += 1;
    }
    let mut p = i;
    while p > 0 && !locate::is_block_parent(doc.ast.kind(chain_a[p])) {
        p -= 1;
    }
    if p + 1 >= chain_a.len() {
        return Err(Error::NoBlock);
    }
    let first = chain_a[p + 1];
    let last = if p + 1 < chain_b.len() { chain_b[p + 1] } else { first };
    Ok(BlockRange { first, last, chain: chain_a })
}

/// The container above the covered blocks that spells itself on the first
/// block's own first line, as AsciiDoc's `NOTE: ` paragraph admonition does.
/// That label is no line prefix the line model strips and writes back (a
/// quote's `> ` and a list marker are), so a gesture that took the block's
/// lines would carry it into the new block as text.
fn labelled_parent(doc: &Document, blocks: &BlockRange, region_start: usize) -> Option<NodeId> {
    let at = blocks.chain.iter().position(|&x| x == blocks.first).unwrap_or(0);
    blocks.chain[..at].iter().copied().find(|&c| {
        matches!(doc.ast.kind(c), Kind::Container(_)) && doc.marker_span(c).is_some_and(|m| m.start >= region_start)
    })
}

/// True when the range's lines cover every block `target` holds.
fn container_fully_covered(doc: &Document, target: NodeId, region_start: usize, region_end: usize) -> bool {
    let Some(first) = doc.ast.nodes[target as usize].first_child else { return false };
    let mut last = first;
    let mut cur = Some(first);
    while let Some(c) = cur {
        last = c;
        cur = doc.ast.nodes[c as usize].next_sibling;
    }
    let lo = locate::line_start_at(&doc.source, doc.span(first).start);
    let hi = locate::line_end_at(&doc.source, doc.span(last).end.saturating_sub(1));
    region_start <= lo && region_end >= hi
}

/// The node `toggle_block_container_by_render` builds for a `ContainerKind`.
fn container_node_kind(kind: ContainerKind, tight: bool) -> Kind {
    match kind {
        ContainerKind::BlockQuote => Kind::BlockQuote,
        ContainerKind::BulletList => Kind::BulletList { tight },
        ContainerKind::OrderedList => Kind::OrderedList { numbering: ListNumbering::Decimal, tight, start: None },
    }
}

/// Where a splice over a block span ENDS: minus the line end some parsers fold
/// into a block's span.
fn block_span_end(src: &[u8], span: Span) -> usize {
    let mut end = span.end;
    if end > span.start && src[end - 1] == b'\n' {
        end -= 1;
    }
    if end > span.start && src[end - 1] == b'\r' {
        end -= 1;
    }
    end
}

/// The render path's `container_fully_covered`.
fn covers_container(ast: &Ast, target: NodeId, blocks: &BlockRange) -> bool {
    let first_at = blocks.chain.iter().position(|&x| x == blocks.first).unwrap();
    let target_at = blocks.chain.iter().position(|&x| x == target).unwrap();
    if first_at <= target_at {
        return true;
    }
    let Some(first) = ast.nodes[target as usize].first_child else { return false };
    let mut last = first;
    while let Some(n) = ast.nodes[last as usize].next_sibling {
        last = n;
    }
    on_edge_path(ast, first, blocks.first, false) && on_edge_path(ast, last, blocks.last, true)
}

/// Whether `node` lies on the path of first (or last) children descending
/// from `from`, `from` itself included.
fn on_edge_path(ast: &Ast, from: NodeId, node: NodeId, last_edge: bool) -> bool {
    let mut cur = from;
    loop {
        if cur == node {
            return true;
        }
        let Some(c) = ast.nodes[cur as usize].first_child else { return false };
        cur = c;
        if last_edge {
            while let Some(n) = ast.nodes[cur as usize].next_sibling {
                cur = n;
            }
        }
    }
}

/// The empty container of `kind` the caret sits in, if any.
fn empty_container_of(ast: &Ast, chain: &[NodeId], kind: ContainerKind) -> Option<NodeId> {
    let &deepest = chain.last()?;
    if ast.nodes[deepest as usize].first_child.is_some() {
        return None;
    }
    let tag = ast.kind(deepest).tag();
    if tag == kind.tag() {
        return Some(deepest);
    }
    if tag == Tag::ListItem && chain.len() >= 2 {
        let list = chain[chain.len() - 2];
        let only = ast.nodes[list as usize].first_child == Some(deepest)
            && ast.nodes[deepest as usize].next_sibling.is_none();
        if only && ast.kind(list).tag() == kind.tag() {
            return Some(list);
        }
    }
    None
}

/// The TEXT of a subtree, for a code block's payload: breaks kept as line
/// ends, a line end between sibling blocks.
fn block_text_into(ast: &Ast, id: NodeId, out: &mut Vec<u8>) {
    match ast.kind(id) {
        Kind::Str(t) => out.extend_from_slice(t),
        Kind::TextLeaf { text, .. } => out.extend_from_slice(text),
        Kind::SmartPunctuation(v) => out.extend_from_slice(v.ascii().as_bytes()),
        Kind::RawInline { text, .. } => out.extend_from_slice(text),
        Kind::CodeBlock { text, .. } => out.extend_from_slice(text),
        Kind::RawBlock { text, .. } => out.extend_from_slice(text),
        Kind::NonBreakingSpace => out.push(b' '),
        Kind::SoftBreak | Kind::HardBreak => out.push(b'\n'),
        _ => {
            let mut first = true;
            for c in ast.child_ids(id) {
                if !first && ast.kind(c).level() == Level::Block {
                    out.push(b'\n');
                }
                block_text_into(ast, c, out);
                first = false;
            }
        }
    }
}

/// How many quotes enclose `target` on the chain.
fn quote_depth_above(ast: &Ast, chain: &[NodeId], target: NodeId) -> usize {
    let mut depth = 0;
    for &id in chain {
        if id == target {
            break;
        }
        if ast.kind(id).tag() == Tag::BlockQuote {
            depth += 1;
        }
    }
    depth
}

// ── Join internals ─────────────────────────────────────────────────────────

/// The interior of a BLOCK, for the formats whose parsers record one and for
/// the ones that do not (AsciiDoc): the marker's end to the block's end, or
/// the first child's start to the last child's end.
fn block_content(doc: &Document, id: NodeId) -> Span {
    if let Some(c) = doc.content_span(id) {
        return c;
    }
    let sp = doc.span(id);
    if let Some(m) = doc.marker_span(id) {
        if m.end >= sp.start && m.end <= sp.end {
            return Span::new(m.end, sp.end);
        }
    }
    let kids = doc.ast.child_ids(id);
    let (Some(&first), Some(&last)) = (kids.first(), kids.last()) else { return sp };
    let start = doc.span(first).start;
    let end = doc.span(last).end;
    if start >= sp.start && end <= sp.end && start <= end {
        return Span::new(start, end);
    }
    sp
}

/// A's tail with its trailing SEPARATOR LINES removed — WHOLE LINES only.
fn trim_tail_separators(tail: &[u8]) -> &[u8] {
    let mut end = tail.len();
    while let Some(nl) = rfind_byte(&tail[..end], b'\n') {
        if !is_separator_run(&tail[nl + 1..end]) {
            break;
        }
        end = nl;
    }
    &tail[..end]
}

/// Whether `bytes` are only what SEPARATES two blocks: line ends, spaces, tabs
/// and quote markers.
fn is_separator_run(bytes: &[u8]) -> bool {
    bytes.iter().all(|c| matches!(c, b' ' | b'\t' | b'\r' | b'\n' | b'>'))
}

/// Whether the region between A's and B's topmost ancestors below the LCA
/// holds nothing the join would destroy — `join_blocks`'s one data-loss guard.
fn gap_is_clean(doc: &Document, src: &[u8], common: &[NodeId], a_top: NodeId, b_top: NodeId) -> bool {
    let start = doc.span(a_top).end;
    let b_start = doc.span(b_top).start;
    if start > b_start || b_start > src.len() {
        return false;
    }
    for idx in 0..doc.ast.nodes.len() {
        let id = idx as NodeId;
        let sp = doc.span(id);
        if sp.start >= b_start || sp.end <= start {
            continue;
        }
        if !holds_blocks(doc, id) {
            continue;
        }
        if !common.contains(&id) {
            return false;
        }
    }
    let mut end = b_start;
    while end > start && src[end - 1] == b'\n' {
        let line_start = locate::line_start_at(src, end - 1);
        if line_start < start {
            break;
        }
        if is_separator_run(&src[line_start..end - 1]) {
            break;
        }
        end = line_start;
    }
    is_separator_run(&src[start..end])
}

/// Consume from `rest` the text of the subtree at `id`, as `select::text_of`
/// spells it; the subtree's leading spaces go.
fn consume_text(ast: &Ast, id: NodeId, rest: &mut &[u8]) -> bool {
    let mut lead = true;
    consume_text_inner(ast, id, rest, &mut lead)
}

fn consume_text_inner(ast: &Ast, id: NodeId, rest: &mut &[u8], lead: &mut bool) -> bool {
    let piece: &[u8] = match ast.kind(id) {
        Kind::Str(t) => t,
        Kind::TextLeaf { text, .. } => text,
        Kind::SmartPunctuation(v) => v.ascii().as_bytes(),
        Kind::RawInline { text, .. } => text,
        Kind::CodeBlock { text, .. } => text,
        Kind::RawBlock { text, .. } => text,
        Kind::NonBreakingSpace | Kind::SoftBreak | Kind::HardBreak => b" ",
        _ => {
            for c in ast.child_ids(id) {
                if !consume_text_inner(ast, c, rest, lead) {
                    return false;
                }
            }
            return true;
        }
    };
    let p = if *lead { trim_start(piece, b" ") } else { piece };
    if !p.is_empty() {
        *lead = false;
    }
    if !rest.starts_with(p) {
        return false;
    }
    *rest = &rest[p.len()..];
    true
}

/// The content `cs` of `block` written as ONE LINE: each soft break becomes
/// one space. `NotEditable` for a hard break, or any line end left after that.
fn append_block_as_one_line(doc: &Document, block: NodeId, cs: Span, out: &mut Vec<u8>) -> R {
    let src = &doc.source;
    let mut breaks = Vec::new();
    collect_breaks(&doc.ast, block, &mut breaks);
    let from = out.len();
    let mut at = cs.start;
    for id in breaks {
        if doc.ast.kind(id).tag() == Tag::HardBreak {
            return Err(Error::NotEditable);
        }
        let sp = doc.span(id);
        if sp.start < at || sp.end > cs.end {
            return Err(Error::NotEditable);
        }
        out.extend_from_slice(trim_end(&src[at..sp.start], b" \t"));
        out.push(b' ');
        at = sp.end;
        while at < cs.end && (src[at] == b' ' || src[at] == b'\t') {
            at += 1;
        }
    }
    out.extend_from_slice(&src[at..cs.end]);
    if contains_any(&out[from..], b"\r\n") {
        return Err(Error::NotEditable);
    }
    Ok(())
}

/// Every soft and hard break under `id`, in document order.
fn collect_breaks(ast: &Ast, id: NodeId, out: &mut Vec<NodeId>) {
    for c in ast.child_ids(id) {
        match ast.kind(c) {
            Kind::SoftBreak | Kind::HardBreak => out.push(c),
            _ => collect_breaks(ast, c, out),
        }
    }
}

/// B's content written as ONE LINE — what a marker heading A can hold.
fn append_as_one_line(text: &[u8], out: &mut Vec<u8>) {
    let mut rest = text;
    while let Some(nl) = find_byte(rest, b'\n') {
        out.extend_from_slice(trim_end(&rest[..nl], b" \t\r"));
        out.push(b' ');
        rest = &rest[nl + 1..];
        let mut k = 0;
        while k < rest.len() && (rest[k] == b' ' || rest[k] == b'\t' || rest[k] == b'>') {
            k += 1;
        }
        rest = &rest[k..];
    }
    out.extend_from_slice(rest);
}

/// B's content written as a CONTINUATION LINE of A: a setext underline line
/// gets a backslash on its first byte, where the format states line-start
/// escapes at all.
fn append_as_continuation(syntax: &Syntax, text: &[u8], out: &mut Vec<u8>) {
    if syntax.block_start_escapes.is_some() && is_underline_line(text) {
        let lead = text.len() - trim_start(text, b" \t").len();
        out.extend_from_slice(&text[..lead]);
        out.push(b'\\');
        out.extend_from_slice(&text[lead..]);
        return;
    }
    out.extend_from_slice(text);
}

/// Whether `text`'s FIRST line is a run of `=` or a run of `-`.
fn is_underline_line(text: &[u8]) -> bool {
    let first = &text[..find_byte(text, b'\n').unwrap_or(text.len())];
    let trimmed = trim(first, b" \t\r");
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.iter().any(|&c| c != trimmed[0]) {
        return false;
    }
    trimmed[0] == b'=' || trimmed[0] == b'-'
}

/// Whether `id` is a heading spelled by an UNDERLINE rather than a marker.
fn is_setext_heading(doc: &Document, id: NodeId) -> bool {
    if doc.ast.kind(id).tag() != Tag::Heading {
        return false;
    }
    if doc.marker_span(id).is_some() {
        return false;
    }
    let Some(content) = doc.content_span(id) else { return false };
    let sp = doc.span(id);
    content.start == sp.start && content.end < sp.end
}

/// Whether a node on `chain` is a table.
fn passes_through_table(doc: &Document, chain: &[NodeId]) -> bool {
    chain.iter().any(|&id| doc.ast.kind(id).tag() == Tag::Table)
}

/// The path of node ids from the root down to `target`, or `None`.
fn node_path(doc: &Document, target: NodeId) -> Option<Vec<NodeId>> {
    let mut out = vec![doc.ast.root];
    if target == doc.ast.root {
        return Some(out);
    }
    if descend_to(doc, doc.ast.root, target, &mut out) { Some(out) } else { None }
}

fn descend_to(doc: &Document, id: NodeId, target: NodeId, out: &mut Vec<NodeId>) -> bool {
    for child in doc.ast.child_ids(id) {
        out.push(child);
        if child == target {
            return true;
        }
        if descend_to(doc, child, target, out) {
            return true;
        }
        out.pop();
    }
    false
}

/// True for a node that HOLDS BLOCKS.
fn holds_blocks(doc: &Document, id: NodeId) -> bool {
    doc.ast.kind(id).content_model() == ContentModel::Blocks
}

/// The last LEAF BLOCK inside `root`'s subtree in document order.
fn last_leaf_block(doc: &Document, root: NodeId) -> Option<NodeId> {
    if !holds_blocks(doc, root) {
        return Some(root);
    }
    let mut last = None;
    for c in doc.ast.child_ids(root) {
        if let Some(leaf) = last_leaf_block(doc, c) {
            last = Some(leaf);
        }
    }
    last
}

/// The leaf block immediately before `target` in DOCUMENT ORDER.
fn preceding_leaf_block(doc: &Document, target: NodeId) -> Option<NodeId> {
    fn scan(doc: &Document, id: NodeId, target: NodeId, last: &mut Option<NodeId>) -> bool {
        if id == target {
            return true;
        }
        if !holds_blocks(doc, id) {
            *last = Some(id);
            return false;
        }
        for c in doc.ast.child_ids(id) {
            if scan(doc, c, target, last) {
                return true;
            }
        }
        false
    }
    let mut last = None;
    if scan(doc, doc.ast.root, target, &mut last) { last } else { None }
}

/// What `split_block` does with a block of a given kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SplitShape {
    Text,
    Code,
    Refuse,
}

fn split_shape(tag: Tag) -> SplitShape {
    match tag {
        Tag::Para | Tag::Heading => SplitShape::Text,
        Tag::CodeBlock => SplitShape::Code,
        _ => SplitShape::Refuse,
    }
}

/// The block `split_block` should divide for a caret at `offset`, retrying one
/// byte back when the answer at `offset` is not splittable.
fn split_target(doc: &Document, offset: usize) -> Option<locate::LineBlock> {
    let at = locate::line_owning_block(doc, offset);
    if let Some(lb) = at {
        if split_shape(doc.ast.kind(lb.block).tag()) != SplitShape::Refuse {
            return Some(lb);
        }
    }
    if offset > 0 {
        if let Some(back) = locate::line_owning_block(doc, offset - 1) {
            if split_shape(doc.ast.kind(back.block).tag()) != SplitShape::Refuse {
                return Some(back);
            }
        }
    }
    at
}

/// Whether the line ENDING at `line_start` carries content past its own quote
/// markers.
fn preceding_line_has_content(src: &[u8], line_start: usize) -> bool {
    if line_start == 0 {
        return false;
    }
    let prev = locate::line_body(&src[locate::line_start_at(src, line_start - 1)..line_start]);
    let mut i = 0;
    while let Some(j) = skip_quote_marker(prev, i) {
        i = j;
    }
    !locate::is_blank_line(&prev[i..])
}

/// The marker that opens `sp`'s `ordinal`-th item.
fn list_marker(sp: &ContainerSpelling, ordinal: u32) -> Vec<u8> {
    if !sp.numbered {
        return sp.marker.to_vec();
    }
    format!("{ordinal}. ").into_bytes()
}

/// Whether the byte opening a list marker opens an ORDERED one.
fn is_ordered_marker(c: u8) -> bool {
    c == b'(' || c == b'.' || c.is_ascii_digit()
}

/// Advance past one `>` quote marker — up to three spaces of indent, the `>`,
/// and one optional space after it.
fn skip_quote_marker(line: &[u8], i: usize) -> Option<usize> {
    let mut j = i;
    let mut indent = 0;
    while j < line.len() && line[j] == b' ' && indent < 3 {
        j += 1;
        indent += 1;
    }
    if j >= line.len() || line[j] != b'>' {
        return None;
    }
    j += 1;
    if j < line.len() && line[j] == b' ' {
        j += 1;
    }
    Some(j)
}

/// The `(start, end)` of a list marker on `line`, scanning from `from` —
/// `start` at the bullet/first digit and `end` past the marker's trailing
/// spaces.
fn list_marker_at(line: &[u8], from: usize) -> Option<(usize, usize)> {
    let mut j = from;
    while j < line.len() && (line[j] == b' ' || line[j] == b'\t') {
        j += 1;
    }
    let start = j;
    if j >= line.len() {
        return None;
    }
    if matches!(line[j], b'-' | b'*' | b'+') {
        j += 1;
    } else if line[j] == b'.' {
        while j < line.len() && line[j] == b'.' {
            j += 1;
        }
    } else {
        if line[j] == b'(' {
            j += 1;
        }
        let mut digits = 0;
        while j < line.len() && line[j].is_ascii_digit() {
            j += 1;
            digits += 1;
        }
        if digits == 0 {
            return None;
        }
        if j >= line.len() || (line[j] != b'.' && line[j] != b')') {
            return None;
        }
        j += 1;
    }
    if j < line.len() && line[j] != b' ' && line[j] != b'\n' && line[j] != b'\r' {
        return None;
    }
    while j < line.len() && line[j] == b' ' {
        j += 1;
    }
    Some((start, j))
}

/// True if one of the covered blocks begins on `[line_start, line_end)`.
fn block_starts_on_line(doc: &Document, blocks: &BlockRange, line_start: usize, line_end: usize) -> bool {
    let mut cur = Some(blocks.first);
    while let Some(id) = cur {
        let s = doc.span(id).start;
        if s >= line_start && s < line_end {
            return true;
        }
        if id == blocks.last {
            break;
        }
        cur = doc.ast.nodes[id as usize].next_sibling;
    }
    false
}

/// True if one of `list`'s items begins on `[line_start, line_end)`.
fn item_starts_on_line(doc: &Document, list: NodeId, line_start: usize, line_end: usize) -> bool {
    doc.children(list).any(|item| {
        let s = doc.span(item.id).start;
        s >= line_start && s < line_end
    })
}

/// Wrap every line of `[region_start, region_end)` in `kind`'s prefix, one
/// item per covered block.
fn build_container_add(
    src: &[u8],
    doc: &Document,
    blocks: &BlockRange,
    region_start: usize,
    region_end: usize,
    sp: &ContainerSpelling,
    out: &mut Vec<u8>,
) {
    let mut ordinal = 1;
    let mut cont: Vec<u8> = sp.cont.to_vec();
    let mut line_start = region_start;
    while line_start < region_end {
        let line_end = locate::line_end_at(src, line_start);
        let line = &src[line_start..line_end];
        let body = locate::line_body(line);
        if locate::is_blank_line(body) {
            if !sp.blank.is_empty() {
                out.extend_from_slice(sp.blank);
                out.extend_from_slice(&line[body.len()..]);
            } else {
                out.extend_from_slice(line);
            }
            line_start = line_end;
            continue;
        }
        if block_starts_on_line(doc, blocks, line_start, line_end) {
            let marker = list_marker(sp, ordinal);
            if sp.numbered {
                cont = CONTAINER_INDENT[..marker.len().min(CONTAINER_INDENT.len())].to_vec();
            }
            out.extend_from_slice(&marker);
            out.extend_from_slice(line);
            ordinal += 1;
        } else {
            out.extend_from_slice(&cont);
            out.extend_from_slice(line);
        }
        line_start = line_end;
    }
}

/// Strip the quote marker `target` contributes from each of its lines, leaving
/// outer quote levels untouched.
fn build_quote_strip(src: &[u8], region_start: usize, region_end: usize, depth: usize, out: &mut Vec<u8>) {
    let mut line_start = region_start;
    while line_start < region_end {
        let line_end = locate::line_end_at(src, line_start);
        let line = &src[line_start..line_end];
        let mut keep = 0;
        let mut d = 0;
        while d < depth {
            match skip_quote_marker(line, keep) {
                Some(k) => keep = k,
                None => break,
            }
            d += 1;
        }
        if d == depth {
            if let Some(after) = skip_quote_marker(line, keep) {
                out.extend_from_slice(&line[..keep]);
                out.extend_from_slice(&line[after..]);
                line_start = line_end;
                continue;
            }
        }
        out.extend_from_slice(line);
        line_start = line_end;
    }
}

/// Rewrite the list `target`'s item markers: `sp == None` removes the list,
/// otherwise it converts one list kind to the other in place.
fn build_list_rewrite(
    src: &[u8],
    doc: &Document,
    target: NodeId,
    region_start: usize,
    region_end: usize,
    sp: Option<&ContainerSpelling>,
    out: &mut Vec<u8>,
) {
    let mut ordinal = 1;
    let mut old_width = 0;
    let mut new_width = 0;
    let mut seen_item = false;
    let mut last_blank = true;
    let mut line_start = region_start;
    while line_start < region_end {
        let line_end = locate::line_end_at(src, line_start);
        let line = &src[line_start..line_end];
        let body = locate::line_body(line);
        if locate::is_blank_line(body) {
            out.extend_from_slice(line);
            last_blank = true;
            line_start = line_end;
            continue;
        }
        if item_starts_on_line(doc, target, line_start, line_end) {
            if sp.is_none() && seen_item && !last_blank {
                out.push(b'\n');
            }
            let Some(m) = list_marker_at(line, 0) else {
                out.extend_from_slice(line);
                line_start = line_end;
                continue;
            };
            let marker: Vec<u8> = match sp {
                Some(s) if s.numbered => format!("{ordinal}. ").into_bytes(),
                Some(s) => s.marker.to_vec(),
                None => Vec::new(),
            };
            out.extend_from_slice(&line[..m.0]);
            out.extend_from_slice(&marker);
            out.extend_from_slice(&line[m.1..]);
            old_width = m.1 - m.0;
            new_width = marker.len();
            ordinal += 1;
            seen_item = true;
            last_blank = false;
        } else {
            let mut j = 0;
            while j < line.len() && j < old_width && line[j] == b' ' {
                j += 1;
            }
            out.extend_from_slice(&CONTAINER_INDENT[..new_width.min(CONTAINER_INDENT.len())]);
            out.extend_from_slice(&line[j..]);
            last_blank = false;
        }
        line_start = line_end;
    }
}

/// One left-to-right rewrite that renumbers ordered-list items by their
/// indentation depth.
fn build_renumber(src: &[u8], region_start: usize, region_end: usize, item_lines: &[usize], out: &mut Vec<u8>) {
    let mut cols = [0usize; 32];
    let mut nums = [0u32; 32];
    let mut depth = 0;
    let mut next_item = 0;
    let mut line_start = region_start;
    while line_start < region_end {
        let line_end = locate::line_end_at(src, line_start);
        let line = &src[line_start..line_end];
        while next_item < item_lines.len() && item_lines[next_item] < line_start {
            next_item += 1;
        }
        let opens_item = next_item < item_lines.len() && item_lines[next_item] == line_start;
        let mut from = 0;
        while let Some(j) = skip_quote_marker(line, from) {
            from = j;
        }
        let m = if opens_item { list_marker_at(line, from) } else { None };
        let numbered = m.is_some_and(|mm| is_numbered_marker(&line[mm.0..mm.1]));
        if numbered {
            let mm = m.unwrap();
            let indent = mm.0 - from;
            while depth > 0 && cols[depth - 1] > indent {
                depth -= 1;
            }
            let mut number: u32 = 1;
            if depth > 0 && cols[depth - 1] == indent {
                number = nums[depth - 1];
                nums[depth - 1] += 1;
            } else if depth < cols.len() {
                cols[depth] = indent;
                nums[depth] = 2;
                depth += 1;
            }
            out.extend_from_slice(&line[..mm.0]);
            let mut d = mm.0;
            if d < line.len() && line[d] == b'(' {
                out.push(b'(');
                d += 1;
            }
            out.extend_from_slice(number.to_string().as_bytes());
            let mut k = d;
            while k < line.len() && line[k].is_ascii_digit() {
                k += 1;
            }
            out.extend_from_slice(&line[k..]);
        } else {
            out.extend_from_slice(line);
        }
        line_start = line_end;
    }
}

/// Whether a marker is an ordered one — a run of digits, allowing `(`.
fn is_numbered_marker(marker: &[u8]) -> bool {
    let mut j = 0;
    if j < marker.len() && marker[j] == b'(' {
        j += 1;
    }
    j < marker.len() && marker[j].is_ascii_digit()
}

/// The run of QUOTE MARKERS opening the line `at` sits on.
fn container_prefix(src: &[u8], at: usize) -> &[u8] {
    let line_start = locate::line_start_at(src, at);
    let line = &src[line_start..locate::line_end_at(src, at)];
    let mut i = 0;
    while let Some(j) = skip_quote_marker(line, i) {
        i = j;
    }
    &line[..i]
}

/// Whether container `id` ends in markup of its own after its last child.
fn writes_closers(doc: &Document, src: &[u8], id: NodeId) -> bool {
    let last = doc.ast.child_ids(id).last().copied();
    let end = doc.span(id).end;
    let tail_start = match last {
        Some(l) => doc.span(l).end,
        None => doc.span(id).start,
    };
    if tail_start >= end {
        return false;
    }
    src[tail_start..end].iter().any(|&b| !is_whitespace(b))
}

/// The innermost paragraph on `chain` and its parent (`None` for the root).
fn innermost_para(doc: &Document, chain: &[NodeId]) -> Option<(NodeId, Option<NodeId>)> {
    for i in (0..chain.len()).rev() {
        if *doc.ast.kind(chain[i]) != Kind::Para {
            continue;
        }
        return Some((chain[i], if i == 0 { None } else { Some(chain[i - 1]) }));
    }
    None
}

/// Whether `chain` passes through a list item.
fn inside_list_item(doc: &Document, chain: &[NodeId]) -> bool {
    chain.iter().any(|&id| matches!(doc.ast.kind(id), Kind::ListItem | Kind::TaskListItem { .. }))
}

// ── Move internals ─────────────────────────────────────────────────────────

/// Where `move_block` puts a block.
#[derive(Clone, Copy, Debug)]
struct Dest {
    container: NodeId,
    prev: Option<NodeId>,
    next: Option<NodeId>,
    pos: usize,
}

/// A node `move_block` descends INTO looking for the block at an offset.
fn descends_into(kind: &Kind) -> bool {
    locate::is_block_parent(kind) || matches!(kind, Kind::BulletList { .. } | Kind::OrderedList { .. } | Kind::TaskList { .. })
}

fn is_list_item(kind: &Kind) -> bool {
    matches!(kind, Kind::ListItem | Kind::TaskListItem { .. })
}

fn is_list(kind: &Kind) -> bool {
    matches!(kind, Kind::BulletList { .. } | Kind::OrderedList { .. } | Kind::TaskList { .. })
}

/// The lines a list has apart from its items, as whole lines.
#[derive(Clone, Copy, Debug, Default)]
struct ListWrap {
    open: Span,
    close: Span,
}

fn list_wrap(doc: &Document, list: NodeId, item_lines: Span) -> ListWrap {
    if !is_list(doc.ast.kind(list)) {
        return ListWrap::default();
    }
    let src = &doc.source;
    let sp = doc.span(list);
    if sp.end <= sp.start {
        return ListWrap::default();
    }
    let Some(first) = doc.ast.nodes[list as usize].first_child else { return ListWrap::default() };
    let mut last = first;
    while let Some(n) = doc.ast.nodes[last as usize].next_sibling {
        last = n;
    }
    let lo = locate::line_start_at(src, sp.start);
    let hi = locate::line_end_at(src, sp.end - 1);
    let first_line = locate::line_start_at(src, doc.span(first).start);
    let last_sp = doc.span(last);
    let last_line =
        if last_sp.end > last_sp.start { locate::line_end_at(src, last_sp.end - 1) } else { item_lines.end };
    ListWrap {
        open: Span::new(lo, lo.max(first_line.min(item_lines.start))),
        close: Span::new(hi.min(last_line.max(item_lines.end)), hi),
    }
}

/// A paragraph the parser read without any markup around it.
fn is_bare_paragraph(doc: &Document, id: NodeId) -> bool {
    if *doc.ast.kind(id) != Kind::Para {
        return false;
    }
    let Some(content) = doc.content_span(id) else { return false };
    content == doc.span(id)
}

fn is_tight_list(kind: &Kind) -> bool {
    match kind {
        Kind::BulletList { tight } | Kind::OrderedList { tight, .. } | Kind::TaskList { tight } => *tight,
        _ => false,
    }
}

/// An inline node — what a list item holds DIRECTLY in a format that gives
/// its text no paragraph.
fn is_inline_kind(kind: &Kind) -> bool {
    match kind {
        Kind::Str(_)
        | Kind::SoftBreak
        | Kind::HardBreak
        | Kind::NonBreakingSpace
        | Kind::TextLeaf { .. }
        | Kind::RawInline { .. }
        | Kind::SmartPunctuation(_)
        | Kind::Link(_)
        | Kind::Image(_)
        | Kind::InlineMark(_)
        | Kind::Substitution { .. }
        | Kind::Reference { .. } => true,
        Kind::Container(c) => c.form == Some(Form::InlineText),
        _ => false,
    }
}

/// The block `move_block` moves for a caret at `offset`.
fn movable_unit(doc: &Document, offset: usize) -> Option<NodeId> {
    if doc.ast.nodes.is_empty() {
        return None;
    }
    let mut cur = doc.ast.root;
    loop {
        let Some(child) = locate::caret_child_containing(doc, cur, offset) else {
            if is_list_item(doc.ast.kind(cur)) {
                if let Some(m) = doc.marker_span(cur) {
                    if offset < m.end {
                        return Some(cur);
                    }
                }
            }
            return None;
        };
        let kind = doc.ast.kind(child);
        if descends_into(kind) {
            cur = child;
            continue;
        }
        if is_list_item(doc.ast.kind(cur)) {
            if is_inline_kind(kind) || doc.ast.nodes[cur as usize].first_child == Some(child) {
                return Some(cur);
            }
        } else if is_inline_kind(kind) {
            return None;
        }
        return Some(child);
    }
}

/// The whole lines `unit` owns, trailing separator lines trimmed.
fn unit_lines(doc: &Document, unit: NodeId, ancestors: &[NodeId]) -> R<Span> {
    let src = &doc.source;
    let sp = doc.span(unit);
    if sp.end <= sp.start {
        return Err(Error::NotEditable);
    }
    let start = locate::line_start_at(src, sp.start);
    let mut end = locate::line_end_at(src, sp.end - 1);
    while end > start {
        let ls = locate::line_start_at(src, end - 1);
        if ls <= start {
            break;
        }
        if !is_separator_run(locate::line_body(&src[ls..end])) {
            break;
        }
        end = ls;
    }
    if !line_head_is_prefix(doc, ancestors, start, sp.start) {
        return Err(Error::NotEditable);
    }
    if sp.end < end && !locate::is_blank_line(locate::line_body(&src[sp.end..end])) {
        return Err(Error::NotEditable);
    }
    Ok(Span::new(start, end))
}

/// Whether the bytes `[line_start, at)` are all container prefix.
fn line_head_is_prefix(doc: &Document, chain: &[NodeId], line_start: usize, at: usize) -> bool {
    'scan: for i in line_start..at {
        if matches!(doc.source[i], b' ' | b'\t' | b'>') {
            continue;
        }
        for &id in chain {
            if let Some(m) = doc.marker_span(id) {
                if i >= m.start && i < m.end {
                    continue 'scan;
                }
            }
        }
        return false;
    }
    true
}

/// Resolve `to` to the boundary `move_block` lands on.
fn resolve_boundary(syntax: &Syntax, doc: &Document, to: usize, unit: NodeId) -> R<Dest> {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Side {
        Before,
        After,
        Gap,
    }
    let src = &doc.source;
    let unit_is_item = is_list_item(doc.ast.kind(unit));
    let mut chain: Vec<NodeId> = vec![doc.ast.root];
    let mut container = doc.ast.root;
    let mut prev: Option<NodeId> = None;
    let mut next: Option<NodeId> = None;
    let mut side = Side::Gap;

    let at_end = to == src.len() && !src.is_empty() && src[src.len() - 1] != b'\n';
    let mut anchor: Option<NodeId> = None;
    if !at_end {
        while let Some(child) = locate::caret_child_containing(doc, *chain.last().unwrap(), to) {
            if !descends_into(doc.ast.kind(child)) {
                anchor = Some(child);
                break;
            }
            chain.push(child);
        }
        container = *chain.last().unwrap();
    }

    if let Some(a) = anchor {
        let content = if doc.ast.kind(a).content_model() == ContentModel::Text {
            let sp = doc.span(a);
            let mut end = sp.end;
            if end > sp.start && src[end - 1] == b'\n' {
                end -= 1;
            }
            Span::new(sp.start, end)
        } else {
            block_content(doc, a)
        };
        if to <= content.start {
            side = Side::Before;
        } else if to >= content.end {
            side = Side::After;
        } else {
            return Err(Error::NotEditable);
        }
        let inline_anchor = is_inline_kind(doc.ast.kind(a));
        if side == Side::Before {
            if inline_anchor && doc.ast.nodes[container as usize].first_child != Some(a) {
                return Err(Error::NotEditable);
            }
            prev = prev_sibling(doc, container, a);
            next = Some(a);
        } else {
            let mut n = doc.ast.nodes[a as usize].next_sibling;
            if inline_anchor {
                if let Some(nn) = n {
                    if is_inline_kind(doc.ast.kind(nn)) {
                        return Err(Error::NotEditable);
                    }
                }
                n = None;
                let mut seen = false;
                for c in doc.ast.child_ids(container) {
                    if seen && !is_inline_kind(doc.ast.kind(c)) {
                        n = Some(c);
                        break;
                    }
                    if c == a {
                        seen = true;
                    }
                }
            }
            prev = Some(a);
            next = n;
        }
    } else {
        for c in doc.ast.child_ids(container) {
            let sp = doc.span(c);
            if sp.start < to {
                prev = Some(c);
            } else if next.is_none() {
                next = Some(c);
            }
        }
        if at_end && prev.is_some() {
            side = Side::After;
        }
    }

    let to_line = locate::line_start_at(src, to);
    for depth in 1..chain.len() {
        let c = chain[depth];
        if is_list(doc.ast.kind(c)) {
            continue;
        }
        let open = doc.marker_span(c).map(|m| m.start).unwrap_or_else(|| doc.span(c).start);
        if to > open || locate::line_start_at(src, open) != to_line {
            continue;
        }
        chain.truncate(depth);
        container = chain[depth - 1];
        side = Side::Before;
        prev = prev_sibling(doc, container, c);
        next = Some(c);
        break;
    }

    let mut climbed = false;
    loop {
        if is_list_item(doc.ast.kind(container)) && chain.len() >= 2 {
            let item = container;
            let at_head = prev.is_none() || (next.is_some() && next == doc.ast.nodes[item as usize].first_child);
            if at_head || unit_is_item {
                chain.pop();
                container = *chain.last().unwrap();
                if at_head {
                    side = Side::Before;
                    prev = prev_sibling(doc, container, item);
                    next = Some(item);
                } else {
                    side = Side::After;
                    prev = Some(item);
                    next = doc.ast.nodes[item as usize].next_sibling;
                }
            }
        }
        if !unit_is_item && is_list(doc.ast.kind(container)) && chain.len() >= 2 {
            let list = container;
            if next.is_some() && next == doc.ast.nodes[list as usize].first_child {
                chain.pop();
                container = *chain.last().unwrap();
                side = Side::Before;
                prev = prev_sibling(doc, container, list);
                next = Some(list);
            } else if next.is_none() {
                chain.pop();
                container = *chain.last().unwrap();
                side = Side::After;
                prev = Some(list);
                next = doc.ast.nodes[list as usize].next_sibling;
            }
        }
        let after_self = prev == Some(unit);
        let before_self = next == Some(unit);
        if !after_self && !before_self {
            break;
        }
        let at_edge = if after_self {
            doc.ast.nodes[unit as usize].next_sibling.is_none()
        } else {
            doc.ast.nodes[container as usize].first_child == Some(unit)
        };
        if climbed || !at_edge || chain.len() < 2 {
            return Err(Error::InvalidArgument);
        }
        let c = container;
        chain.pop();
        container = *chain.last().unwrap();
        if after_self {
            side = Side::After;
            prev = Some(c);
            next = doc.ast.nodes[c as usize].next_sibling;
        } else {
            side = Side::Before;
            prev = prev_sibling(doc, container, c);
            next = Some(c);
        }
        climbed = true;
    }

    let pos = match side {
        Side::Before => {
            let sp = doc.span(next.unwrap());
            let ls = locate::line_start_at(src, sp.start);
            if !line_head_is_prefix(doc, &chain, ls, sp.start) {
                return Err(Error::NotEditable);
            }
            ls
        }
        Side::After => {
            let sp = doc.span(prev.unwrap());
            if sp.end <= sp.start {
                return Err(Error::NotEditable);
            }
            let le = locate::line_end_at(src, sp.end - 1);
            if sp.end < le && !locate::is_blank_line(locate::line_body(&src[sp.end..le])) {
                return Err(Error::NotEditable);
            }
            le
        }
        Side::Gap => {
            let ls = locate::line_start_at(src, to);
            if !is_separator_line(syntax, locate::line_body(&src[ls..locate::line_end_at(src, to)])) {
                return Err(Error::NotEditable);
            }
            ls
        }
    };
    Ok(Dest { container, prev, next, pos })
}

fn prev_sibling(doc: &Document, parent: NodeId, id: NodeId) -> Option<NodeId> {
    let mut prev = None;
    for c in doc.ast.child_ids(parent) {
        if c == id {
            return prev;
        }
        prev = Some(c);
    }
    None
}

/// The lines `move_block` removes: the block's own plus the separator lines
/// that kept it apart from its neighbours, climbing through prefix-spelled
/// containers the block is the only content of.
fn removal_lines(syntax: &Syntax, doc: &Document, chain: &[NodeId], lines: Span) -> Span {
    let src = &doc.source;
    let mut r = chain.len() - 1;
    while r > 0 {
        let parent = chain[r - 1];
        if parent == doc.ast.root || !spelled_by_prefix(doc, parent) {
            break;
        }
        if doc.ast.nodes[parent as usize].first_child != Some(chain[r])
            || doc.ast.nodes[chain[r] as usize].next_sibling.is_some()
        {
            break;
        }
        r -= 1;
    }
    let mut lo = lines.start;
    let mut hi = lines.end;
    if r < chain.len() - 1 {
        let rsp = doc.span(chain[r]);
        if rsp.end > rsp.start {
            lo = lo.min(locate::line_start_at(src, rsp.start));
            hi = hi.max(locate::line_end_at(src, rsp.end - 1));
        }
    }
    let parent = chain[r - 1];
    let mut parent_start = 0;
    let mut parent_end = src.len();
    if parent != doc.ast.root {
        let psp = doc.content_span(parent).unwrap_or_else(|| doc.span(parent));
        if psp.end > psp.start {
            parent_start = locate::line_start_at(src, psp.start);
            parent_end = locate::line_end_at(src, psp.end - 1).max(hi);
        }
    }
    let mut after = hi;
    while after < parent_end {
        let le = locate::line_end_at(src, after);
        if !is_separator_line(syntax, locate::line_body(&src[after..le])) {
            break;
        }
        after = le;
    }
    let mut before = lo;
    if after >= parent_end {
        while before > parent_start {
            let ls = locate::line_start_at(src, before - 1);
            if ls < parent_start {
                break;
            }
            if !is_separator_line(syntax, locate::line_body(&src[ls..before])) {
                break;
            }
            before = ls;
        }
    }
    Span::new(before, after)
}

/// Whether `parent` goes when its only child does.
fn spelled_by_prefix(doc: &Document, parent: NodeId) -> bool {
    match doc.ast.kind(parent) {
        Kind::BulletList { .. } | Kind::OrderedList { .. } | Kind::TaskList { .. } => true,
        Kind::BlockQuote | Kind::ListItem | Kind::TaskListItem { .. } => doc.marker_span(parent).is_some(),
        Kind::Section => true,
        _ => false,
    }
}

/// `chain` as the prefix walk should see it: without its list items where the
/// format attaches a block to an item by a line of its own.
fn prefix_chain(syntax: &Syntax, doc: &Document, chain: &[NodeId]) -> Vec<NodeId> {
    chain
        .iter()
        .copied()
        .filter(|&id| !(syntax.list_attach.is_some() && is_list_item(doc.ast.kind(id))))
        .collect()
}

/// `is_separator_run` for a whole line, plus the format's attach line.
fn is_separator_line(syntax: &Syntax, body: &[u8]) -> bool {
    if is_separator_run(body) {
        return true;
    }
    match syntax.list_attach {
        Some(attach) => trim(body, b" \t\r") == attach,
        None => false,
    }
}

/// How many bytes of `body` are prefix inside the first `cols` columns.
fn strip_columns(body: &[u8], cols: usize) -> usize {
    let mut i = 0;
    let mut col = 0;
    while i < body.len() && col < cols {
        match body[i] {
            b' ' | b'>' => col += 1,
            b'\t' => col += 4 - col % 4,
            _ => break,
        }
        i += 1;
    }
    i
}

/// The line that ends the text `a ++ b`.
struct LastLine {
    body: Vec<u8>,
    terminated: bool,
    empty: bool,
}

fn last_line_of(a: &[u8], b: &[u8]) -> LastLine {
    if a.is_empty() && b.is_empty() {
        return LastLine { body: Vec::new(), terminated: true, empty: true };
    }
    let mut text_a = a;
    let mut text_b = b;
    let mut terminated = false;
    if !text_b.is_empty() {
        if text_b[text_b.len() - 1] == b'\n' {
            terminated = true;
            text_b = &text_b[..text_b.len() - 1];
        }
    } else if text_a[text_a.len() - 1] == b'\n' {
        terminated = true;
        text_a = &text_a[..text_a.len() - 1];
    }
    if let Some(nl) = rfind_byte(text_b, b'\n') {
        return LastLine { body: trim_end(&text_b[nl + 1..], b"\r").to_vec(), terminated, empty: false };
    }
    let a_tail = match rfind_byte(text_a, b'\n') {
        Some(nl) => &text_a[nl + 1..],
        None => text_a,
    };
    if text_b.is_empty() {
        return LastLine { body: trim_end(a_tail, b"\r").to_vec(), terminated, empty: false };
    }
    let mut joined = a_tail.to_vec();
    joined.extend_from_slice(text_b);
    let len = trim_end(&joined, b"\r").len();
    joined.truncate(len);
    LastLine { body: joined, terminated, empty: false }
}

/// The first line of the text `a ++ b`, without its line end.
fn first_line_of<'a>(a: &'a [u8], b: &'a [u8]) -> &'a [u8] {
    let text = if !a.is_empty() { a } else { b };
    let line = &text[..find_byte(text, b'\n').unwrap_or(text.len())];
    trim_end(line, b"\r")
}

// ── Code-fence internals ───────────────────────────────────────────────────

/// How many fence characters a fence over `body` needs: one more than the
/// longest run of `char` anywhere in it, floored at `min`.
fn fence_width(body: &[u8], char: u8, min: usize) -> usize {
    let mut longest = 0;
    let mut run = 0;
    for &c in body {
        if c != char {
            run = 0;
            continue;
        }
        run += 1;
        longest = longest.max(run);
    }
    min.max(longest + 1)
}

/// The fence opening `line`: `(start, width)` after any quote prefix and up to
/// three spaces of indentation, or `None`.
fn fence_at(line: &[u8], char: u8, min: usize) -> Option<(usize, usize)> {
    let mut i = 0;
    while let Some(j) = skip_quote_marker(line, i) {
        i = j;
    }
    let mut indent = 0;
    while i < line.len() && line[i] == b' ' && indent < 3 {
        i += 1;
        indent += 1;
    }
    let start = i;
    while i < line.len() && line[i] == char {
        i += 1;
    }
    if i - start >= min { Some((start, i - start)) } else { None }
}

/// Where a code block's lines sit: the containers around it.
struct CodeFrame {
    ancestors: Vec<NodeId>,
    /// What a line inside the containers opens with where nothing opens on it.
    prefix: Vec<u8>,
    /// `prefix`'s width in columns.
    cols: usize,
}

/// How much of a body is the continuation prefix.
#[derive(Clone, Copy, Debug)]
struct FrameStrip {
    len: usize,
    pad: usize,
    full: bool,
}

impl CodeFrame {
    fn new(syntax: &Syntax, doc: &Document, ancestors: &[NodeId]) -> CodeFrame {
        let mut f = CodeFrame { ancestors: ancestors.to_vec(), prefix: Vec::new(), cols: 0 };
        let src = &doc.source;
        for &id in ancestors {
            let kind = doc.ast.kind(id);
            if !Self::frames(kind) {
                continue;
            }
            if syntax.list_attach.is_some() && is_list_item(kind) {
                continue;
            }
            let Some(m) = doc.marker_span(id) else { continue };
            let mut end = m.end;
            if matches!(kind, Kind::TaskListItem { .. }) {
                if let Some(lm) = list_marker_at(&src[m.start..m.end], 0) {
                    end = m.start + lm.1;
                }
            }
            let start_col = locate::column_of(src, m.start);
            let end_col = locate::column_of(src, end);
            while f.cols < start_col {
                f.prefix.push(b' ');
                f.cols += 1;
            }
            if end_col > f.cols {
                if *kind == Kind::BlockQuote {
                    f.prefix.extend_from_slice(&src[m.start..end]);
                } else {
                    repeat(&mut f.prefix, b' ', end_col - f.cols);
                }
                f.cols = end_col;
            }
        }
        f
    }

    fn frames(kind: &Kind) -> bool {
        matches!(
            kind,
            Kind::BlockQuote
                | Kind::ListItem
                | Kind::TaskListItem { .. }
                | Kind::DefinitionListItem
                | Kind::Definition
                | Kind::Footnote { .. }
        )
    }

    fn blank(&self) -> &[u8] {
        trim_end(&self.prefix, b" \t")
    }

    /// How many bytes of the line starting at `at` are markers opening there.
    fn head_len(&self, doc: &Document, at: usize) -> Option<usize> {
        let le = locate::line_end_at(&doc.source, at);
        let body_len = locate::line_body(&doc.source[at..le]).len();
        let mut n: Option<usize> = None;
        for &a in &self.ancestors {
            if !Self::frames(doc.ast.kind(a)) {
                continue;
            }
            let Some(m) = doc.marker_span(a) else { continue };
            if m.start >= at && m.start < le {
                n = Some(body_len.min(n.unwrap_or(0).max(m.end - at)));
            }
        }
        n
    }

    /// Whether a list item's marker opens on the line starting at `at`.
    fn opens_item(&self, doc: &Document, at: usize) -> bool {
        let le = locate::line_end_at(&doc.source, at);
        self.ancestors.iter().any(|&a| {
            is_list_item(doc.ast.kind(a)) && doc.marker_span(a).is_some_and(|m| m.start >= at && m.start < le)
        })
    }

    fn strip(&self, body: &[u8]) -> FrameStrip {
        let mut i = 0;
        let mut col = 0;
        while i < body.len() && col < self.cols {
            match body[i] {
                b' ' | b'>' => col += 1,
                b'\t' => col += 4 - col % 4,
                _ => break,
            }
            i += 1;
        }
        FrameStrip { len: i, pad: col.saturating_sub(self.cols), full: col >= self.cols }
    }

    fn write_line(&self, out: &mut Vec<u8>, pad: usize, rest: &[u8], ending: &[u8]) {
        if locate::is_blank_line(rest) {
            out.extend_from_slice(self.blank());
        } else {
            out.extend_from_slice(&self.prefix);
            repeat(out, b' ', pad);
            out.extend_from_slice(rest);
        }
        out.extend_from_slice(ending);
    }
}

/// The interior of the code block `cb` with its framing removed, written to
/// `out`. Returns where the splice ends.
fn build_unfence(
    doc: &Document,
    frame: &CodeFrame,
    cb: NodeId,
    region_start: usize,
    region_end: usize,
    fence: &CodeFence,
    out: &mut Vec<u8>,
) -> usize {
    let src = &doc.source;
    let head = frame.head_len(doc, region_start);
    let first_end = locate::line_end_at(src, region_start);
    let first_body = locate::line_body(&src[region_start..first_end]);
    let opening = &first_body[head.unwrap_or_else(|| frame.strip(first_body).len)..];

    if fence_at(opening, fence.char, fence.min).is_none() {
        let mut line_start = region_start;
        while line_start < region_end {
            let line_end = locate::line_end_at(src, line_start);
            let body = locate::line_body(&src[line_start..line_end]);
            let ending = &src[line_start + body.len()..line_end];
            let on_head = line_start == region_start && head.is_some();
            let st = if on_head { FrameStrip { len: head.unwrap(), pad: 0, full: true } } else { frame.strip(body) };
            let mut rest = &body[st.len..];
            let mut pad = st.pad;
            let mut indent = pad.min(4);
            pad -= indent;
            while indent < 4 && !rest.is_empty() && rest[0] == b' ' {
                rest = &rest[1..];
                indent += 1;
            }
            if on_head {
                append_head_line(out, &src[region_start..region_start + head.unwrap()], pad, rest, ending);
            } else {
                frame.write_line(out, pad, rest, ending);
            }
            line_start = line_end;
        }
        return region_end;
    }

    let mut body_end = region_end;
    let last_start = locate::line_start_at(src, region_end.saturating_sub(1));
    if last_start >= first_end {
        let last = locate::line_body(&src[last_start..region_end]);
        if fence_at(&last[frame.strip(last).len..], fence.char, fence.min).is_some() {
            body_end = last_start;
        }
    }
    body_end = body_end.max(first_end);
    let Some(h) = head else {
        out.extend_from_slice(&src[first_end..body_end]);
        return region_end;
    };
    let head_bytes = &src[region_start..region_start + h];
    let item = frame.opens_item(doc, region_start);

    let mut line_start = first_end;
    if item {
        while line_start < body_end {
            let le = locate::line_end_at(src, line_start);
            let body = locate::line_body(&src[line_start..le]);
            if !locate::is_blank_line(&body[frame.strip(body).len..]) {
                break;
            }
            line_start = le;
        }
    }
    if line_start >= body_end {
        if !item {
            return region_end;
        }
        out.extend_from_slice(trim_end(head_bytes, b" \t"));
        out.push(b'\n');
        let mut end = region_end;
        if doc.ast.nodes[cb as usize].next_sibling.is_some() {
            while end < src.len() {
                let le = locate::line_end_at(src, end);
                let body = locate::line_body(&src[end..le]);
                if !locate::is_blank_line(&body[frame.strip(body).len..]) {
                    break;
                }
                end = le;
            }
        }
        return end;
    }
    let le = locate::line_end_at(src, line_start);
    let body = locate::line_body(&src[line_start..le]);
    let st = frame.strip(body);
    append_head_line(out, head_bytes, st.pad, &body[st.len..], &src[line_start + body.len()..le]);
    out.extend_from_slice(&src[le..le.max(body_end)]);
    region_end
}

/// `rest` behind the head of a block's first line and `pad` spaces.
fn append_head_line(out: &mut Vec<u8>, head: &[u8], pad: usize, rest: &[u8], ending: &[u8]) {
    if locate::is_blank_line(rest) {
        out.extend_from_slice(trim_end(head, b" \t"));
    } else {
        out.extend_from_slice(head);
        repeat(out, b' ', pad);
        out.extend_from_slice(rest);
    }
    out.extend_from_slice(ending);
}

/// Refuse an info string this format's fence cannot carry back out.
fn check_info_string(fence: &CodeFence, lang: &[u8]) -> R {
    if contains_any(lang, b"\r\n") || lang.contains(&fence.char) || contains_any(lang, fence.info_forbids) {
        return Err(Error::InvalidLanguage);
    }
    Ok(())
}

/// The grammar an attribute must fit for every format to read it back.
fn check_attr(kv: &KeyVal) -> R {
    let key = &kv.key;
    if key.is_empty() {
        return Err(Error::InvalidAttribute);
    }
    if !key[0].is_ascii_alphabetic() && key[0] != b'_' {
        return Err(Error::InvalidAttribute);
    }
    if key[1..].iter().any(|&c| !c.is_ascii_alphanumeric() && c != b'-' && c != b'_' && c != b':') {
        return Err(Error::InvalidAttribute);
    }
    let value = kv.value.as_deref().ok_or(Error::InvalidAttribute)?;
    if contains_any(value, b"\r\n\"") {
        return Err(Error::InvalidAttribute);
    }
    Ok(())
}

/// Refuse a directive name that would not come back as the name of a
/// container: an ASCII letter, then letters, digits, `-` and `_`.
fn check_directive_name(name: &[u8]) -> R {
    if name.is_empty() || !name[0].is_ascii_alphabetic() {
        return Err(Error::InvalidName);
    }
    if name[1..].iter().any(|&c| !c.is_ascii_alphanumeric() && c != b'-' && c != b'_') {
        return Err(Error::InvalidName);
    }
    Ok(())
}

/// Where a list item's checkbox is, or would go.
#[derive(Clone, Copy, Debug)]
struct TaskBox {
    at: usize,
    bx: Option<Span>,
    space: usize,
    checked: bool,
}

/// `check_info_string` for the render path: a language is ONE TOKEN.
fn check_language_token(lang: &[u8]) -> R {
    if lang.iter().any(|&c| is_whitespace(c)) {
        return Err(Error::InvalidLanguage);
    }
    Ok(())
}

/// One inline node a selection covers: the node whole, or — for a `str` the
/// selection starts or ends inside — the covered part of its text.
struct InlinePiece {
    node: NodeId,
    text: Option<Vec<u8>>,
}

/// The inline nodes `[start, end)` covers, in order.
fn covered_inlines(doc: &Document, start: usize, end: usize) -> R<Vec<InlinePiece>> {
    let ast = &doc.ast;
    let chain_a = locate::ancestor_chain_vec(doc, start);
    let chain_b = locate::ancestor_chain_vec(doc, end - 1);
    let mut i = 0;
    while i + 1 < chain_a.len() && i + 1 < chain_b.len() && chain_a[i + 1] == chain_b[i + 1] {
        i += 1;
    }
    let common = chain_a[i];
    let mut pieces = Vec::new();
    let common_span = doc.span(common);
    if common_span.start >= start && common_span.end <= end {
        if ast.kind(common).level() != Level::Inline {
            return Err(Error::NotEditable);
        }
        pieces.push(InlinePiece { node: common, text: None });
        return Ok(pieces);
    }
    if ast.kind(common).tag() == Tag::Str {
        pieces.push(InlinePiece { node: common, text: Some(str_slice(doc, common, start, end)?) });
        return Ok(pieces);
    }
    if i + 1 >= chain_a.len() || i + 1 >= chain_b.len() {
        return Err(Error::NoBlock);
    }
    let first = chain_a[i + 1];
    let last = chain_b[i + 1];
    let mut cur = Some(first);
    while let Some(c) = cur {
        if ast.kind(c).level() != Level::Inline {
            return Err(Error::NotEditable);
        }
        let sp = doc.span(c);
        let cut = (c == first && sp.start < start) || (c == last && sp.end > end);
        pieces.push(InlinePiece {
            node: c,
            text: if cut { Some(str_slice(doc, c, sp.start.max(start), sp.end.min(end))?) } else { None },
        });
        cur = if c == last { None } else { ast.nodes[c as usize].next_sibling };
    }
    Ok(pieces)
}

/// The part of `str` node `id`'s text that `[start, end)` covers, where the
/// text is its source byte-for-byte.
fn str_slice(doc: &Document, id: NodeId, start: usize, end: usize) -> R<Vec<u8>> {
    let Kind::Str(text) = doc.ast.kind(id) else { return Err(Error::NotEditable) };
    let sp = doc.span(id);
    if sp.end - sp.start != text.len() {
        return Err(Error::NotEditable);
    }
    Ok(text[start - sp.start..end - sp.start].to_vec())
}

/// Whether `label` already has a footnote DEFINITION in this tree.
fn footnote_defined(ast: &Ast, label: &[u8]) -> bool {
    ast.nodes.iter().any(|n| matches!(&n.kind, Kind::Footnote { label: l } if l == label))
}

/// Whether `src` already ends in a blank line (an empty document counts).
fn ends_with_blank_line(src: &[u8]) -> bool {
    if src.is_empty() {
        return true;
    }
    if src[src.len() - 1] != b'\n' {
        return false;
    }
    let last = locate::line_start_at(src, src.len() - 1);
    locate::is_blank_line(locate::line_body(&src[last..]))
}

// ── Link internals ─────────────────────────────────────────────────────────

/// Write `dest` spelled so the format parses it back byte-for-byte: the
/// `<…>` form where the format has one and the destination holds whitespace.
fn write_link_destination(syntax: &Syntax, dest: &[u8], out: &mut Vec<u8>) -> R {
    let de = syntax.link_dest_escapes.ok_or(Error::UnsupportedFormat)?;
    let angle = match de.angle {
        Some(a) if contains_any(dest, b" \t") => Some(a.escapes),
        _ => None,
    };
    if angle.is_some() {
        out.push(b'<');
    }
    let escapes = angle.unwrap_or(de.plain);
    for &c in dest {
        if escapes.contains(&c) {
            out.push(b'\\');
        }
        out.push(c);
    }
    if angle.is_some() {
        out.push(b'>');
    }
    Ok(())
}

fn write_link_text(syntax: &Syntax, text: &[u8], out: &mut Vec<u8>) -> R {
    let escapes = syntax.link_text_escapes.ok_or(Error::UnsupportedFormat)?;
    for &c in text {
        if escapes.contains(&c) {
            out.push(b'\\');
        }
        out.push(c);
    }
    Ok(())
}

/// Write `text` through the format's literal renderer, one run per
/// `TextPosition`: the leading whitespace of a line and the byte that ends it
/// in `BlockStart`, the rest `InlineText`; a verbatim body all at once.
fn write_literal(syntax: &Syntax, text: &[u8], at_line_start: bool, in_verbatim: bool, out: &mut Vec<u8>) -> Result<(), crate::Error> {
    if in_verbatim {
        return syntax.render_text(text, TextPosition::Verbatim, out);
    }
    let mut rest = text;
    let mut block_pos = at_line_start;
    while !rest.is_empty() {
        let nl = find_byte(rest, b'\n').unwrap_or(rest.len() - 1);
        let line = &rest[..nl + 1];
        rest = &rest[nl + 1..];
        let mut body = line;
        if block_pos {
            let mut i = 0;
            while i < line.len() && (line[i] == b' ' || line[i] == b'\t') {
                i += 1;
            }
            let zone = (i + 1).min(line.len());
            syntax.render_text(&line[..zone], TextPosition::BlockStart, out)?;
            body = &line[zone..];
        }
        if !body.is_empty() {
            syntax.render_text(body, TextPosition::InlineText, out)?;
        }
        block_pos = line[line.len() - 1] == b'\n';
    }
    Ok(())
}

/// The innermost autolink on the chain that wholly contains `[start, end)`.
fn autolink_covering(doc: &Document, chain: &[NodeId], start: usize, end: usize) -> Option<NodeId> {
    let id = locate::innermost_covering(doc, chain, &[Tag::TextLeaf], start, end)?;
    match doc.ast.kind(id) {
        Kind::TextLeaf { kind: TextLeafKind::Url | TextLeafKind::Email, .. } => Some(id),
        _ => None,
    }
}

/// Whether writing at `pos` would land STRICTLY INSIDE an autolink's URL.
fn splits_autolink(doc: &Document, pos: usize) -> bool {
    let chain = locate::ancestor_chain_vec(doc, pos);
    let Some(id) = autolink_covering(doc, &chain, pos, pos) else { return false };
    let span = doc.span(id);
    span.start < pos && pos < span.end
}


#[cfg(test)]
#[path = "editor_test.rs"]
mod editor_test;
