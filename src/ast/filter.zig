//! filter.zig — a declarative document-pruning pass, layered over `Select` +
//! `Splicer`. The higher-level counterpart to the splicer's single-node ops:
//! instead of "delete THIS node", it expresses "keep only the family members
//! matching a predicate, drop the rest" over the whole document — the shape
//! Diaryx's audience filtering needs (`:::vis{…}` blocks kept or dropped by
//! their `class` set).
//!
//! ── Model ────────────────────────────────────────────────────────────────
//! Two selectors and a flag (`Options`):
//!   - `drop`  — the candidate FAMILY (e.g. `directive[name=vis]`); every match
//!               is a removal candidate.
//!   - `keep`  — exceptions spared despite matching `drop` (e.g.
//!               `directive[class~=public]`). `null` drops the whole family.
//!   - `unwrap_kept` — after the drop pass, unwrap each surviving family member
//!               (peel the `:::vis` wrapper off its content).
//! A node is removed iff it matches `drop` AND not `keep`; a survivor is one
//! matching both.
//!
//! ── Why it loops + re-resolves ─────────────────────────────────────────────
//! The `Splicer` reparses after every edit, so `Node.Id`s (and index paths) from
//! before an edit are stale afterward. Rather than track positions across
//! edits, each step re-resolves both selectors against the CURRENT tree, acts
//! on ONE node, and repeats — every edit strictly shrinks the tree, so the loop
//! is bounded by the initial node count (a hard `FilterDidNotConverge` guard
//! backstops any surprise). O(n²) reparses, fine for documents; correctness and
//! the editor's per-edit reparse-validation (a bad edit rolls back and surfaces
//! as an error) matter more than speed here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Node = AST.Node;
const Document = @import("../document.zig");
const Splicer = @import("splicer.zig").Splicer;
const Select = @import("select.zig");

pub const Options = struct {
    /// The candidate family: a selector whose every match is a removal
    /// candidate (e.g. `"directive[name=vis]"`).
    drop: []const u8,
    /// Exceptions kept despite matching `drop` (e.g.
    /// `"directive[class~=public]"`). `null` = spare nothing; the whole `drop`
    /// family is removed.
    keep: ?[]const u8 = null,
    /// After the drop pass, unwrap each KEPT family member — replace it with
    /// its interior, peeling the surviving `:::vis` wrappers off their content
    /// (`Splicer.unwrapNode`). Only meaningful with `keep`.
    unwrap_kept: bool = false,
};

/// `apply`'s own guard error, unioned with whatever the selectors and the
/// editor's reparse can raise (the latter is open — a language's parse error
/// set — so this stays `anyerror`-compatible at call sites).
pub const FilterError = error{FilterDidNotConverge};

/// Run the filter over `editor` in place (see this file's module doc comment
/// for the model and the loop rationale). On success `editor.sourceBytes()`
/// holds the pruned document. On any editor error (notably a reparse-breaking
/// edit, already rolled back) the partial progress so far stands and the error
/// is returned.
pub fn apply(gpa: Allocator, editor: *Splicer, options: Options) anyerror!void {
    var drop_sel = try Select.parse(gpa, options.drop);
    defer drop_sel.deinit();

    var keep_sel_opt: ?Select.Selector = if (options.keep) |k| try Select.parse(gpa, k) else null;
    defer if (keep_sel_opt) |*k| k.deinit();

    // Each successful edit removes at least one node, so the tree strictly
    // shrinks; the initial node count (plus slack) bounds total iterations.
    const bound = editor.astView().nodes.len + 8;

    // ── Phase 1: drop candidates not spared by `keep`. ──────────────────────
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i > bound) return FilterError.FilterDidNotConverge;
        const drops = try Select.resolveAll(gpa, &editor.doc, &drop_sel);
        defer gpa.free(drops);

        const target: ?Node.Id = blk: {
            if (keep_sel_opt) |*k| {
                const keeps = try Select.resolveAll(gpa, &editor.doc, k);
                defer gpa.free(keeps);
                break :blk firstNotIn(drops, keeps);
            }
            break :blk if (drops.len > 0) drops[0].id else null;
        };

        const t = target orelse break;
        try editor.deleteNodeSmartById(t);
    }

    // ── Phase 2: unwrap the survivors. ──────────────────────────────────────
    // After phase 1 every remaining `drop` match is, by definition, a spared
    // one — so unwrapping all remaining `drop` matches unwraps exactly the kept
    // family members (and never a `keep` match that was outside the family).
    if (options.unwrap_kept and keep_sel_opt != null) {
        var j: usize = 0;
        while (true) : (j += 1) {
            if (j > bound) return FilterError.FilterDidNotConverge;
            const drops = try Select.resolveAll(gpa, &editor.doc, &drop_sel);
            defer gpa.free(drops);
            if (drops.len == 0) break;
            try editor.unwrapNodeById(drops[0].id);
        }
    }
}

/// The id of the first `candidates` match whose id appears in none of `set`
/// (both resolved against the same tree, so ids are comparable), or `null`.
fn firstNotIn(candidates: []const Select.Match, set: []const Select.Match) ?Node.Id {
    outer: for (candidates) |c| {
        for (set) |s| {
            if (s.id == c.id) continue :outer;
        }
        return c.id;
    }
    return null;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseMarkdownDirectives(ctx: *const anyopaque, a: Allocator, s: []const u8) anyerror!Document {
    _ = ctx;
    const Markdown = @import("../languages/markdown/markdown.zig");
    var doc = try Markdown.parse(a, s, .{ .directives = true });
    doc.link_references.deinit(a);
    doc.footnotes.deinit(a);
    return doc.document();
}

const md_ctx: u8 = 0;

fn runFilter(src: []const u8, options: Options) ![]u8 {
    var ed = try Splicer.init(testing.allocator, src, &md_ctx, parseMarkdownDirectives);
    defer ed.deinit();
    try apply(testing.allocator, &ed, options);
    return testing.allocator.dupe(u8, ed.sourceBytes());
}

test "filter: drop non-kept family members, keep the wrappers intact" {
    const src =
        ":::vis{.public}\nA\n:::\n\n" ++
        ":::vis{.family}\nB\n:::\n\n" ++
        ":::vis{.public}\nC\n:::\n";
    const out = try runFilter(src, .{ .drop = "directive[name=vis]", .keep = "directive[class~=public]" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        ":::vis{.public}\nA\n:::\n\n:::vis{.public}\nC\n:::\n",
        out,
    );
}

test "filter: unwrap_kept peels the survivors down to their content" {
    const src =
        ":::vis{.public}\nA\n:::\n\n" ++
        ":::vis{.family}\nB\n:::\n";
    const out = try runFilter(src, .{
        .drop = "directive[name=vis]",
        .keep = "directive[class~=public]",
        .unwrap_kept = true,
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A\n", out);
}

test "filter: no keep selector drops the whole family" {
    const src = "keep me\n\n:::vis{.public}\nA\n:::\n\ntail\n";
    const out = try runFilter(src, .{ .drop = "directive[name=vis]" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("keep me\n\ntail\n", out);
}

test "filter: a document with no family matches is unchanged" {
    const src = "# Just a heading\n\nA paragraph.\n";
    const out = try runFilter(src, .{ .drop = "directive[name=vis]", .keep = "directive[class~=public]" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "filter: keep applies per-audience (family kept, others unwrapped away)" {
    // Two audiences; keep 'family', drop+unwrap leaves only the family block's
    // content.
    const src =
        ":::vis{.public}\npublic only\n:::\n\n" ++
        ":::vis{.family}\nfamily only\n:::\n";
    const out = try runFilter(src, .{
        .drop = "directive[name=vis]",
        .keep = "directive[class~=family]",
        .unwrap_kept = true,
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("family only\n", out);
}
