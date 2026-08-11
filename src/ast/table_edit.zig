//! Structural table editing: add / remove / move rows and columns, and set a
//! column's alignment. The pipe-table half of the authoring `Editor`, and the
//! one gesture family that has no delimiter to toggle — a table is a *grid*, so
//! its edits are grid surgery, spliced back as one rebuilt table.
//!
//! ── The shape ──────────────────────────────────────────────────────────────
//! A parsed table is `[caption, row, row, …]`; the header row carries
//! `head = true`, the alignment lives on each `cell`, and the `|---|:--|`
//! delimiter line the source spells alignment with is CONSUMED by the parser and
//! leaves no node. So the grid is read from the AST — cell CONTENT from each
//! cell's `content_span`, per-column ALIGNMENT from the header cells — and the
//! delimiter line is re-spelled from the alignments on the way back out.
//!
//! A table can also hold a run of `column` nodes describing its column axis (see
//! `Kind.column`), but only a format with a real one produces them, and pipe
//! tables — all this file edits — never do. The row scan skips any non-`row`
//! child regardless.
//!
//! ── Why re-emit the whole table ────────────────────────────────────────────
//! Column ops touch every row and the delimiter at once; row ops shift the lines
//! below. Rebuilding the table's line region in one buffer and splicing it once
//! keeps the edit a single reparse and a single undo step, the same discipline
//! the list rewrites keep. Cell content is copied verbatim from the source
//! (escapes and all), so a `\|` in a cell survives; only the pipe skeleton and
//! the delimiter are this module's to spell.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Document = @import("../document.zig");
const Span = @import("../span.zig");
const locate = @import("locate.zig");

pub const Alignment = AST.Alignment;

/// Where a row/column op lands relative to the caret's cell.
pub const Side = enum { before, after };

/// A grid lifted out of a parsed table, ready to mutate and re-emit. Cell
/// contents are slices into the live source (valid until the splice that
/// replaces it), so extraction copies nothing; a cell added by an edit is an
/// empty slice.
pub const Grid = struct {
    allocator: Allocator,
    /// `rows[r][c]` — row-major cell contents. Ragged rows are padded to `cols`
    /// on emit, never here.
    rows: std.ArrayList(std.ArrayList([]const u8)),
    /// One alignment per column.
    aligns: std.ArrayList(Alignment),
    /// How many leading rows are header rows (GFM: 1). The delimiter is emitted
    /// right after them.
    header_rows: usize,
    /// The caret's cell, as a grid coordinate — the anchor every op works from.
    caret_row: usize,
    caret_col: usize,
    /// The source line range the rebuilt table replaces.
    region: Span,

    pub fn deinit(self: *Grid) void {
        for (self.rows.items) |*r| r.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.aligns.deinit(self.allocator);
    }

    fn cols(self: *const Grid) usize {
        return self.aligns.items.len;
    }
};

/// Errors distinct enough for the `Editor` to map to its own set.
pub const Error = error{
    /// The offset isn't inside a table.
    NotInTable,
    /// The edit would leave the table degenerate (delete its last body row, its
    /// last column, or the header row).
    Refused,
    OutOfMemory,
};

/// Lift the table containing `offset` into a [`Grid`], or `error.NotInTable`.
pub fn extract(allocator: Allocator, doc: *const Document, offset: usize) Error!Grid {
    const ast = &doc.ast;
    const src = doc.source;
    var chain: std.ArrayList(AST.Node.Id) = .empty;
    defer chain.deinit(allocator);
    locate.ancestorChain(allocator, doc, offset, &chain) catch return error.OutOfMemory;

    var table_id: ?AST.Node.Id = null;
    for (chain.items) |id| {
        if (std.meta.activeTag(ast.nodes[id].kind) == .table) {
            table_id = id;
            break;
        }
    }
    const table = table_id orelse return error.NotInTable;

    var grid: Grid = .{
        .allocator = allocator,
        .rows = .empty,
        .aligns = .empty,
        .header_rows = 0,
        .caret_row = 0,
        .caret_col = 0,
        .region = undefined,
    };
    errdefer grid.deinit();

    var row_index: usize = 0;
    var found_caret = false;
    var it = ast.tableRows(table);
    while (it.next()) |child| {
        const is_head = child.head;
        if (is_head and grid.header_rows == row_index) grid.header_rows += 1;

        var cells: std.ArrayList([]const u8) = .empty;
        var col_index: usize = 0;
        var cit = ast.children(child.id);
        while (cit.next()) |cell| {
            if (std.meta.activeTag(cell.kind) != .cell) continue;
            const content = if (doc.contentSpan(cell.id)) |cs| src[cs.start..cs.end] else "";
            try cells.append(allocator, content);
            // Alignment is per column; the first row to reach a column defines it.
            if (col_index >= grid.aligns.items.len) {
                try grid.aligns.append(allocator, cell.kind.cell.alignment);
            }
            col_index += 1;
        }
        // Every cell of a row shares the ROW's span (the parser doesn't span
        // cells individually), so the caret's cell can't be read off a cell span
        // — the row is located by its own (per-line) span, and the column by
        // counting the `|` separators before the caret on that line.
        if (!found_caret and offset >= doc.span(child.id).start and offset <= doc.span(child.id).end) {
            grid.caret_row = row_index;
            grid.caret_col = columnAt(src, doc.span(child.id).start, offset);
            found_caret = true;
        }
        try grid.rows.append(allocator, cells);
        row_index += 1;
    }

    if (grid.rows.items.len == 0 or grid.aligns.items.len == 0) return error.NotInTable;
    if (grid.header_rows == 0) grid.header_rows = 1; // a table always has a header

    // The caret sat off the cells (the delimiter line, or a ragged gap): aim the
    // op at the first body row so it still does something sensible.
    if (!found_caret) {
        grid.caret_row = @min(grid.header_rows, grid.rows.items.len - 1);
        grid.caret_col = 0;
    }

    const t = doc.span(table);
    grid.region = Span.init(locate.lineStartAt(src, t.start), locate.lineEndAt(src, t.end -| 1));
    return grid;
}

/// The column the caret sits in on a table row: the number of unescaped `|`
/// separators between the row's start and `offset`, minus the leading border. A
/// `\|` inside a cell is not a separator, so it doesn't count.
fn columnAt(src: []const u8, row_start: usize, offset: usize) usize {
    var pipes: usize = 0;
    var i = row_start;
    while (i < offset and i < src.len) : (i += 1) {
        if (src[i] == '|' and (i == 0 or src[i - 1] != '\\')) pipes += 1;
    }
    // The first `|` opens column 0; each later one steps into the next column.
    return if (pipes == 0) 0 else pipes - 1;
}

/// Serialize `grid` back to pipe-table source: header rows, the delimiter row
/// spelled from the alignments, then the body rows. Columns are padded so every
/// row and the delimiter share a width. The caller owns the returned bytes.
pub fn emit(allocator: Allocator, grid: *const Grid) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const cols = grid.cols();

    for (grid.rows.items, 0..) |row, r| {
        try emitRow(allocator, &out, row.items, cols);
        // The delimiter goes right after the last header row.
        if (r + 1 == grid.header_rows) try emitDelimiter(allocator, &out, grid.aligns.items);
    }
    // A header-only table (all rows are header) still needs its delimiter.
    if (grid.header_rows >= grid.rows.items.len) {
        try emitDelimiter(allocator, &out, grid.aligns.items);
    }
    return out.toOwnedSlice(allocator);
}

fn emitRow(allocator: Allocator, out: *std.ArrayList(u8), cells: []const []const u8, cols: usize) !void {
    try out.append(allocator, '|');
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        const content = if (c < cells.len) cells[c] else "";
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, content);
        try out.append(allocator, ' ');
        try out.append(allocator, '|');
    }
    try out.append(allocator, '\n');
}

fn emitDelimiter(allocator: Allocator, out: *std.ArrayList(u8), aligns: []const Alignment) !void {
    try out.append(allocator, '|');
    for (aligns) |a| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, switch (a) {
            .default => "---",
            .left => ":---",
            .right => "---:",
            .center => ":---:",
        });
        try out.append(allocator, ' ');
        try out.append(allocator, '|');
    }
    try out.append(allocator, '\n');
}

// ── Grid mutations ───────────────────────────────────────────────────────────
// Each returns `error.Refused` when the edit would leave the table degenerate,
// leaving the grid untouched so the caller can report and splice nothing.

/// Insert an empty row on `side` of the caret's row. A row above the header is
/// clamped to just below it (a row before the header would break the table).
pub fn insertRow(grid: *Grid, side: Side) Error!void {
    var at = if (side == .after) grid.caret_row + 1 else grid.caret_row;
    if (at < grid.header_rows) at = grid.header_rows;
    var cells: std.ArrayList([]const u8) = .empty;
    var c: usize = 0;
    while (c < grid.cols()) : (c += 1) try cells.append(grid.allocator, "");
    grid.rows.insert(grid.allocator, at, cells) catch return error.OutOfMemory;
}

/// Delete the caret's row. Refused for a header row or the last body row.
pub fn deleteRow(grid: *Grid) Error!void {
    if (grid.caret_row < grid.header_rows) return error.Refused;
    if (grid.rows.items.len <= grid.header_rows + 1) return error.Refused;
    var row = grid.rows.orderedRemove(grid.caret_row);
    row.deinit(grid.allocator);
}

/// Insert an empty column on `side` of the caret's column.
pub fn insertColumn(grid: *Grid, side: Side) Error!void {
    const at = if (side == .after) grid.caret_col + 1 else grid.caret_col;
    for (grid.rows.items) |*row| {
        const c = @min(at, row.items.len);
        row.insert(grid.allocator, c, "") catch return error.OutOfMemory;
    }
    grid.aligns.insert(grid.allocator, @min(at, grid.aligns.items.len), .default) catch
        return error.OutOfMemory;
}

/// Delete the caret's column. Refused when it is the only column.
pub fn deleteColumn(grid: *Grid) Error!void {
    if (grid.cols() <= 1) return error.Refused;
    const at = grid.caret_col;
    for (grid.rows.items) |*row| {
        if (at < row.items.len) _ = row.orderedRemove(at);
    }
    if (at < grid.aligns.items.len) _ = grid.aligns.orderedRemove(at);
}

/// Set the caret's column to `align`.
pub fn setAlignment(grid: *Grid, alignment: Alignment) Error!void {
    if (grid.caret_col < grid.aligns.items.len) grid.aligns.items[grid.caret_col] = alignment;
}

/// Move the caret's row one step in `dir` (before = up, after = down), within the
/// body rows. Refused at the body's edge or for a header row.
pub fn moveRow(grid: *Grid, dir: Side) Error!void {
    const r = grid.caret_row;
    if (r < grid.header_rows) return error.Refused;
    const other: usize = if (dir == .before) blk: {
        if (r <= grid.header_rows) return error.Refused;
        break :blk r - 1;
    } else blk: {
        if (r + 1 >= grid.rows.items.len) return error.Refused;
        break :blk r + 1;
    };
    std.mem.swap(std.ArrayList([]const u8), &grid.rows.items[r], &grid.rows.items[other]);
    grid.caret_row = other;
}

/// Move the caret's column one step in `dir` (before = left, after = right).
/// Refused at the edge.
pub fn moveColumn(grid: *Grid, dir: Side) Error!void {
    const c = grid.caret_col;
    const other: usize = if (dir == .before) blk: {
        if (c == 0) return error.Refused;
        break :blk c - 1;
    } else blk: {
        if (c + 1 >= grid.cols()) return error.Refused;
        break :blk c + 1;
    };
    for (grid.rows.items) |*row| {
        if (c < row.items.len and other < row.items.len)
            std.mem.swap([]const u8, &row.items[c], &row.items[other]);
    }
    std.mem.swap(Alignment, &grid.aligns.items[c], &grid.aligns.items[other]);
    grid.caret_col = other;
}
