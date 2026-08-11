//! The ONE algorithm that spells a node's attributes back into source — the
//! serializer-side counterpart to `ast/editor.zig`, which is where the
//! authoring gestures' format-independent algorithms live.
//!
//! ── Why this is a file and not a method on `Syntax` ────────────────────────
//! `syntax.zig`'s header states the property it is protecting: the tables are
//! INERT, so "a new format is a `Syntax` literal, not new code paths". Keeping
//! the walk out of that file preserves it. `Syntax.AttrSpelling` is the
//! alphabet; this is the algorithm that reads it, and neither knows which
//! format it is serving.
//!
//! ── What it replaced ───────────────────────────────────────────────────────
//! `djot/serializer.zig`'s `writeDjotAttrs` and `markdown/serializer.zig`'s
//! `writeDirectiveAttrs`: two walks over the same side table, in the same
//! order, applying the same `id`/`class`/bare-attribute rules, differing only
//! in a quoting policy (djot quotes every value, Markdown quotes only what the
//! bare grammar can't hold). rST's `:width: 50%` option block is the same walk
//! again with no braces and a newline between entries — so it arrives as a
//! table entry rather than a third copy of this loop.
//!
//! HTML is deliberately NOT a client. `html/serializer.zig`'s
//! `renderAttributes` merges a synthesized `extra` list into the node's own
//! entries, dedups keys across the two, and escapes for a tag's interior; that
//! is HTML-output machinery rather than surface spelling, and HTML carries
//! `Syntax.none` regardless.

const std = @import("std");
const Writer = std.Io.Writer;

const AST = @import("ast/ast.zig");
const syntax = @import("syntax.zig");
const AttrSpelling = syntax.AttrSpelling;

/// Spell `attrs` per `sp`, writing nothing at all when there is nothing to say.
///
/// `indent` is written after every `between` — the continuation prefix a
/// line-per-entry form needs (rST indents its options under the directive) and
/// which a brace form leaves empty. It is not part of `AttrSpelling` because it
/// is a property of the POSITION being written into, not of the format: the
/// same rST spelling indents by two spaces under a top-level directive and by
/// more inside a list item, exactly as `ContainerSpelling`'s prefixes compose.
pub fn write(
    w: *Writer,
    attrs: AST.Attrs,
    sp: AttrSpelling,
    indent: []const u8,
) Writer.Error!void {
    if (attrs.isEmpty()) return;

    // An entry can turn out to spell NOTHING (see `willWrite`), so the opener
    // and the separators are emitted only once the entry is known to write —
    // otherwise a set whose sole entry is degenerate would leave a stray `{}`,
    // and a trailing `between` could reach the wire with nothing after it.
    var wrote_any = false;
    for (attrs.entries) |kv| {
        if (!willWrite(kv, sp)) continue;
        if (!wrote_any) {
            try w.writeAll(sp.open);
        } else {
            try w.writeAll(sp.between);
            try w.writeAll(indent);
        }
        wrote_any = true;
        try writeEntry(w, kv, sp, indent);
    }
    if (wrote_any) try w.writeAll(sp.close);
}

/// Whether `kv` spells anything under `sp`. The two degenerate cases are an
/// `id` with no value and a `class` whose value holds no classes: both are
/// unreachable from any parser (an `id`/`class` entry always carries a
/// non-empty value), and both would otherwise emit a dangling sigil — a lone
/// `#` or `.` — which is worse than emitting nothing. A hand-built tree (via
/// `AST.Builder` or the C ABI's `twig_builder_set_attrs`) can still produce
/// them, which is why this is checked rather than asserted.
fn willWrite(kv: AST.KeyVal, sp: AttrSpelling) bool {
    if (sp.id_sigil != null and std.mem.eql(u8, kv.key, "id")) {
        const v = kv.value orelse return false;
        return v.len > 0;
    }
    if (sp.class_sigil != null and std.mem.eql(u8, kv.key, "class")) {
        const v = kv.value orelse return false;
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        return it.next() != null;
    }
    return true;
}

fn writeEntry(w: *Writer, kv: AST.KeyVal, sp: AttrSpelling, indent: []const u8) Writer.Error!void {
    if (sp.id_sigil) |sigil| {
        if (std.mem.eql(u8, kv.key, "id")) {
            try w.writeAll(sigil);
            try w.writeAll(kv.value.?);
            return;
        }
    }
    if (sp.class_sigil) |sigil| {
        if (std.mem.eql(u8, kv.key, "class")) {
            // `class="a b"` is ONE entry holding several classes — the parse-time
            // accumulation this reverses (see `AST.Attrs`) space-joins them at
            // the position of the first `.foo`, so they come back apart here.
            var it = std.mem.tokenizeScalar(u8, kv.value.?, ' ');
            var first = true;
            while (it.next()) |cls| {
                // Several classes are several ENTRIES on the wire even though
                // they are one side-table entry, so they take the same
                // separator-plus-indent the outer loop uses.
                if (!first) {
                    try w.writeAll(sp.between);
                    try w.writeAll(indent);
                }
                first = false;
                try w.writeAll(sigil);
                try w.writeAll(cls);
            }
            return;
        }
    }

    try w.writeAll(sp.key_prefix);
    try w.writeAll(kv.key);
    // A bare attribute is the key alone — HTML's `disabled`, which must not
    // round-trip as `disabled=""`. See `AST.KeyVal`.
    const value = kv.value orelse return;
    try w.writeAll(sp.key_value);
    if (quotes(sp.quoting, value)) {
        try w.writeByte('"');
        for (value) |c| {
            if (std.mem.indexOfScalar(u8, sp.quote_escapes, c) != null) try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeByte('"');
    } else {
        try w.writeAll(value);
    }
}

fn quotes(q: syntax.Quoting, value: []const u8) bool {
    return switch (q) {
        .never => false,
        .always => true,
        .when_needed => needsQuoting(value),
    };
}

/// A bare (unquoted) value may hold only name characters; empty or anything
/// else must be quoted. Markdown's rule, moved here verbatim from
/// `markdown/serializer.zig` — the alphabet matches `markdown/attributes.zig`'s
/// `isNameChar`, which is what reads it back.
fn needsQuoting(v: []const u8) bool {
    if (v.len == 0) return true;
    for (v) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':')) return true;
    }
    return false;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn spell(sp: AttrSpelling, entries: []const AST.KeyVal, indent: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, .{ .entries = entries }, sp, indent);
    return out.toOwnedSlice();
}

/// The three alphabets, one loop — the property this file exists for.
const djot_spelling: AttrSpelling = .{
    .open = "{",
    .close = "}",
    .quoting = .always,
    .id_sigil = "#",
    .class_sigil = ".",
};

const markdown_spelling: AttrSpelling = .{
    .open = "{",
    .close = "}",
    .quoting = .when_needed,
    .quote_escapes = "\"\\",
    .id_sigil = "#",
    .class_sigil = ".",
};

/// What an rST directive's option block will want: no braces, one `:key: value`
/// per line. Not wired to a format yet — it is here to prove the table can say
/// it without this file changing, which is the whole claim.
const rst_spelling: AttrSpelling = .{
    .between = "\n",
    .key_prefix = ":",
    .key_value = ": ",
};

test "djot quotes every value and spells the shorthands" {
    const out = try spell(djot_spelling, &.{
        .{ .key = "id", .value = "intro" },
        .{ .key = "class", .value = "lead wide" },
        .{ .key = "lang", .value = "en" },
    }, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{#intro .lead .wide lang=\"en\"}", out);
}

test "markdown quotes only what the bare grammar cannot hold" {
    const out = try spell(markdown_spelling, &.{
        .{ .key = "key", .value = "val" },
        .{ .key = "title", .value = "two words" },
    }, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{key=val title=\"two words\"}", out);
}

test "a quoted value escapes per the table's alphabet" {
    const out = try spell(markdown_spelling, &.{.{ .key = "t", .value = "a\"b" }}, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{t=\"a\\\"b\"}", out);

    // Djot quotes but does not escape, and the table says so rather than the
    // algorithm deciding.
    const dj = try spell(djot_spelling, &.{.{ .key = "t", .value = "a\"b" }}, "");
    defer testing.allocator.free(dj);
    try testing.expectEqualStrings("{t=\"a\"b\"}", dj);
}

test "a bare attribute is the key alone" {
    const out = try spell(markdown_spelling, &.{.{ .key = "disabled", .value = null }}, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{disabled}", out);
}

test "an rST-shaped option block is the same walk with no braces" {
    const out = try spell(rst_spelling, &.{
        .{ .key = "width", .value = "50%" },
        .{ .key = "class", .value = "new" },
        .{ .key = "name", .value = "eq:Eulers law" },
    }, "   ");
    defer testing.allocator.free(out);
    // No sigils, so `class`/`name` are ordinary options — which is exactly what
    // docutils parses them as.
    try testing.expectEqualStrings(
        \\:width: 50%
        \\   :class: new
        \\   :name: eq:Eulers law
    , out);
}

test "nothing is written for an empty set, and no block is opened for one that spells nothing" {
    const empty = try spell(djot_spelling, &.{}, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);

    // A degenerate `id`/`class` (unreachable from a parser) emits no dangling
    // sigil — and since it was the only entry, no braces either.
    const degenerate = try spell(djot_spelling, &.{
        .{ .key = "id", .value = null },
        .{ .key = "class", .value = "" },
    }, "");
    defer testing.allocator.free(degenerate);
    try testing.expectEqualStrings("", degenerate);
}
