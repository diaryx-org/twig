//! Locators: naming ONE node with a string, either way the CLI and the C ABI
//! both accept.
//!
//! A locator is an index path (`0.2.1`, or `""` for the root) or a `Select`
//! selector (`heading[level=2]`). The disambiguation is syntactic and total: a
//! string of only digits and dots is a path, anything else is a selector — so
//! there is no escape hatch needed and no ambiguity to resolve.
//!
//! Both `cli/actions.zig` and `c_abi.zig` had their own copy of this rule (the
//! C ABI's said "Mirrors the CLI's `isIndexPath`" in its doc comment, which is
//! the sort of comment that documents a bug in waiting). They differed only in
//! how they REPORTED failure — the CLI printed to stderr, the ABI returned a
//! status code — so this reports via a typed error set and lets each caller
//! render it however it likes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const AST = @import("ast.zig");
const Document = @import("../document.zig");
const Select = @import("select.zig");

pub const Error = error{
    /// Not a well-formed path and not a parseable selector.
    InvalidLocator,
    /// Resolved to no node: an out-of-bounds index path, or a selector with
    /// zero matches.
    NotFound,
    /// A selector matched more than one node, so the intended target is
    /// ambiguous — refine it, add `:nth(k)`, or use an index path.
    Ambiguous,
} || Allocator.Error;

/// A locator is an index path when it's made only of digits and dots (so an
/// empty string — the root — counts); anything else is a selector.
pub fn isIndexPath(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c) and c != '.') return false;
    return true;
}

/// Parse a dotted index path. The caller frees the result when non-empty.
pub fn parsePath(allocator: Allocator, path_str: []const u8) Error![]const usize {
    if (path_str.len == 0) return &.{};
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, path_str, '.');
    while (it.next()) |seg| {
        const n = std.fmt.parseInt(usize, seg, 10) catch return error.InvalidLocator;
        try list.append(allocator, n);
    }
    return list.toOwnedSlice(allocator);
}

/// Resolve a locator (index path or unique selector) to a single node id
/// against `ast`.
pub fn resolve(allocator: Allocator, doc: *const Document, locator: []const u8) Error!AST.Node.Id {
    const ast = &doc.ast;
    if (isIndexPath(locator)) {
        const path = try parsePath(allocator, locator);
        defer if (path.len > 0) allocator.free(path);
        return ast.getIdByPath(path) catch return error.NotFound;
    }

    var selector = Select.parse(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSelector => return error.InvalidLocator,
    };
    defer selector.deinit();

    const matches = try Select.resolveAll(allocator, doc, &selector);
    defer allocator.free(matches);

    if (matches.len == 0) return error.NotFound;
    if (matches.len > 1) return error.Ambiguous;
    return matches[0].id;
}

test "the path/selector split is purely syntactic" {
    try std.testing.expect(isIndexPath(""));
    try std.testing.expect(isIndexPath("0"));
    try std.testing.expect(isIndexPath("0.2.1"));
    try std.testing.expect(!isIndexPath("heading"));
    try std.testing.expect(!isIndexPath("heading[level=2]"));
}

test "parsePath" {
    const gpa = std.testing.allocator;
    const empty = try parsePath(gpa, "");
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const p = try parsePath(gpa, "0.2.1");
    defer gpa.free(p);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1 }, p);

    try std.testing.expectError(error.InvalidLocator, parsePath(gpa, "0..1"));
}

test "resolve accepts both a path and a selector, and reports why it failed" {
    const Xml = @import("../languages/xml/xml.zig");
    const gpa = std.testing.allocator;
    var ast = try Xml.parse(gpa, "<r><a>one</a><a>two</a></r>");
    defer ast.deinit();

    // The root is the empty path.
    try std.testing.expectEqual(ast.ast.root, try resolve(gpa, &ast, ""));
    // A selector matching exactly one node resolves.
    _ = try resolve(gpa, &ast, "element[name=r]");
    // Two `<a>` elements: ambiguous, not a silent first-match.
    try std.testing.expectError(error.Ambiguous, resolve(gpa, &ast, "element[name=a]"));
    // A selector matching nothing.
    try std.testing.expectError(error.NotFound, resolve(gpa, &ast, "element[name=zz]"));
    // A path past the end.
    try std.testing.expectError(error.NotFound, resolve(gpa, &ast, "99"));
    // Neither a path nor a parseable selector.
    try std.testing.expectError(error.InvalidLocator, resolve(gpa, &ast, "!!"));
}
