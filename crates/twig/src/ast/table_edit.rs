//! Structural table editing: add / remove / move rows and columns, and set a
//! column's alignment. Port of `src/ast/table_edit.zig`.
//!
//! A table is a *grid*, so its edits are grid surgery, spliced back as one
//! rebuilt table: the grid is read from the AST — cell CONTENT from each
//! cell's `content_span`, per-column ALIGNMENT from the cells — and the
//! delimiter line is re-spelled from the alignments on the way back out, in
//! the caller's `TableSpelling` (never literals here).

use crate::ast::{locate, Alignment, Kind, NodeId, Tag};
use crate::document::Document;
use crate::span::Span;
use crate::syntax::TableSpelling;

/// Where a row/column op lands relative to the caret's cell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Before,
    After,
}

/// A grid lifted out of a parsed table, ready to mutate and re-emit. Cell
/// contents are copied out of the source; a cell added by an edit is empty.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grid {
    /// `rows[r][c]` — row-major cell contents. Ragged rows are padded on emit.
    pub rows: Vec<Vec<Vec<u8>>>,
    /// One alignment per column.
    pub aligns: Vec<Alignment>,
    /// How many leading rows are header rows. The delimiter follows them.
    pub header_rows: usize,
    /// The caret's cell, as a grid coordinate.
    pub caret_row: usize,
    pub caret_col: usize,
    /// The source line range the rebuilt table replaces.
    pub region: Span,
}

impl Grid {
    fn cols(&self) -> usize {
        self.aligns.len()
    }
}

/// Errors distinct enough for the `Editor` to map to its own set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// The offset isn't inside a table.
    NotInTable,
    /// The edit would leave the table degenerate.
    Refused,
}

/// A grid that came from no source: one header row and `body_rows` body rows,
/// every cell empty, `cols` columns of default alignment.
pub fn blank(cols: usize, body_rows: usize) -> Result<Grid, Error> {
    if cols == 0 || body_rows == 0 {
        return Err(Error::Refused);
    }
    Ok(Grid {
        rows: vec![vec![Vec::new(); cols]; body_rows + 1],
        aligns: vec![Alignment::Default; cols],
        header_rows: 1,
        caret_row: 0,
        caret_col: 0,
        region: Span::new(0, 0),
    })
}

/// Lift the table containing `offset` into a [`Grid`].
pub fn extract(doc: &Document, offset: usize) -> Result<Grid, Error> {
    let ast = &doc.ast;
    let src = &doc.source;
    let chain = locate::ancestor_chain_vec(doc, offset);
    let table: NodeId =
        chain.iter().copied().find(|&id| ast.kind(id).tag() == Tag::Table).ok_or(Error::NotInTable)?;

    let mut grid = Grid {
        rows: Vec::new(),
        aligns: Vec::new(),
        header_rows: 0,
        caret_row: 0,
        caret_col: 0,
        region: Span::new(0, 0),
    };
    let mut row_index = 0;
    let mut found_caret = false;
    for row in ast.table_rows(table) {
        if row.head && grid.header_rows == row_index {
            grid.header_rows += 1;
        }
        let mut cells: Vec<Vec<u8>> = Vec::new();
        let mut col_index = 0;
        for cell in ast.children(row.id) {
            let Kind::Cell(c) = &cell.kind else { continue };
            let content = match doc.content_span(cell.id) {
                Some(cs) => src[cs.start..cs.end].to_vec(),
                None => Vec::new(),
            };
            cells.push(content);
            if col_index >= grid.aligns.len() {
                grid.aligns.push(c.alignment);
            }
            col_index += 1;
        }
        let rs = doc.span(row.id);
        if !found_caret && offset >= rs.start && offset <= rs.end {
            grid.caret_row = row_index;
            grid.caret_col = column_at(src, rs.start, offset);
            found_caret = true;
        }
        grid.rows.push(cells);
        row_index += 1;
    }

    if grid.rows.is_empty() || grid.aligns.is_empty() {
        return Err(Error::NotInTable);
    }
    if grid.header_rows == 0 {
        grid.header_rows = 1;
    }
    if !found_caret {
        grid.caret_row = grid.header_rows.min(grid.rows.len() - 1);
        grid.caret_col = 0;
    }
    let t = doc.span(table);
    grid.region = Span::new(locate::line_start_at(src, t.start), locate::line_end_at(src, t.end.saturating_sub(1)));
    Ok(grid)
}

/// The column the caret sits in on a table row: the unescaped `|` separators
/// between the row's start and `offset`, minus the leading border.
fn column_at(src: &[u8], row_start: usize, offset: usize) -> usize {
    let mut pipes: usize = 0;
    let mut i = row_start;
    while i < offset && i < src.len() {
        if src[i] == b'|' && (i == 0 || src[i - 1] != b'\\') {
            pipes += 1;
        }
        i += 1;
    }
    pipes.saturating_sub(1)
}

/// Serialize `grid` back to `spelling`'s table source.
pub fn emit(grid: &Grid, spelling: &TableSpelling) -> Vec<u8> {
    let mut out = Vec::new();
    let cols = grid.cols();
    for (r, row) in grid.rows.iter().enumerate() {
        emit_row(&mut out, row, cols, spelling);
        if r + 1 == grid.header_rows {
            emit_delimiter(&mut out, &grid.aligns, spelling);
        }
    }
    if grid.header_rows >= grid.rows.len() {
        emit_delimiter(&mut out, &grid.aligns, spelling);
    }
    out
}

fn emit_row(out: &mut Vec<u8>, cells: &[Vec<u8>], cols: usize, spelling: &TableSpelling) {
    out.extend_from_slice(spelling.bar);
    for c in 0..cols {
        let content: &[u8] = cells.get(c).map(|v| &v[..]).unwrap_or(b"");
        out.extend_from_slice(spelling.pad);
        out.extend_from_slice(content);
        out.extend_from_slice(spelling.pad);
        out.extend_from_slice(spelling.bar);
    }
    out.push(b'\n');
}

fn emit_delimiter(out: &mut Vec<u8>, aligns: &[Alignment], spelling: &TableSpelling) {
    out.extend_from_slice(spelling.bar);
    for &a in aligns {
        out.extend_from_slice(spelling.delim_pad);
        out.extend_from_slice(spelling.delim.get(a));
        out.extend_from_slice(spelling.delim_pad);
        out.extend_from_slice(spelling.bar);
    }
    out.push(b'\n');
}

// ── Grid mutations ───────────────────────────────────────────────────────────

/// Insert an empty row on `side` of the caret's row, clamped below the header.
pub fn insert_row(grid: &mut Grid, side: Side) -> Result<(), Error> {
    let mut at = if side == Side::After { grid.caret_row + 1 } else { grid.caret_row };
    if at < grid.header_rows {
        at = grid.header_rows;
    }
    let cols = grid.cols();
    grid.rows.insert(at, vec![Vec::new(); cols]);
    Ok(())
}

/// Delete the caret's row. Refused for a header row or the last body row.
pub fn delete_row(grid: &mut Grid) -> Result<(), Error> {
    if grid.caret_row < grid.header_rows || grid.rows.len() <= grid.header_rows + 1 {
        return Err(Error::Refused);
    }
    grid.rows.remove(grid.caret_row);
    Ok(())
}

/// Insert an empty column on `side` of the caret's column.
pub fn insert_column(grid: &mut Grid, side: Side) -> Result<(), Error> {
    let at = if side == Side::After { grid.caret_col + 1 } else { grid.caret_col };
    for row in grid.rows.iter_mut() {
        let c = at.min(row.len());
        row.insert(c, Vec::new());
    }
    let a = at.min(grid.aligns.len());
    grid.aligns.insert(a, Alignment::Default);
    Ok(())
}

/// Delete the caret's column. Refused when it is the only column.
pub fn delete_column(grid: &mut Grid) -> Result<(), Error> {
    if grid.cols() <= 1 {
        return Err(Error::Refused);
    }
    let at = grid.caret_col;
    for row in grid.rows.iter_mut() {
        if at < row.len() {
            row.remove(at);
        }
    }
    if at < grid.aligns.len() {
        grid.aligns.remove(at);
    }
    Ok(())
}

/// Set the caret's column to `alignment`.
pub fn set_alignment(grid: &mut Grid, alignment: Alignment) -> Result<(), Error> {
    if grid.caret_col < grid.aligns.len() {
        grid.aligns[grid.caret_col] = alignment;
    }
    Ok(())
}

/// Move the caret's row one step in `dir`, within the body rows.
pub fn move_row(grid: &mut Grid, dir: Side) -> Result<(), Error> {
    let r = grid.caret_row;
    if r < grid.header_rows {
        return Err(Error::Refused);
    }
    let other = match dir {
        Side::Before => {
            if r <= grid.header_rows {
                return Err(Error::Refused);
            }
            r - 1
        }
        Side::After => {
            if r + 1 >= grid.rows.len() {
                return Err(Error::Refused);
            }
            r + 1
        }
    };
    grid.rows.swap(r, other);
    grid.caret_row = other;
    Ok(())
}

/// Move the caret's column one step in `dir`. Refused at the edge.
pub fn move_column(grid: &mut Grid, dir: Side) -> Result<(), Error> {
    let c = grid.caret_col;
    let other = match dir {
        Side::Before => {
            if c == 0 {
                return Err(Error::Refused);
            }
            c - 1
        }
        Side::After => {
            if c + 1 >= grid.cols() {
                return Err(Error::Refused);
            }
            c + 1
        }
    };
    for row in grid.rows.iter_mut() {
        if c < row.len() && other < row.len() {
            row.swap(c, other);
        }
    }
    grid.aligns.swap(c, other);
    grid.caret_col = other;
    Ok(())
}
