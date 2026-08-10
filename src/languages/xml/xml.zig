//! XML: the entry point for this language module, mirroring
//! `languages/djot/djot.zig`'s role for djot. Wires the recursive-descent
//! parser (`parser.zig`) and the serializer (`serializer.zig`) together and
//! aggregates every sibling file's `test {}` blocks (the fig/djot
//! convention).
//!
//! XML needs none of djot's side tables (no cross-document reference
//! resolution, no block/inline dichotomy) so, unlike `Djot.parse`, `parse`
//! here returns the shared `AST` directly rather than a wrapper struct.
//!
//! XML is entirely generic markup from this vocabulary's point of view —
//! `element`/`comment`/`doctype`/`processing_instruction`/`cdata`/`str` are
//! the whole output alphabet; see `ast.zig`'s "Generic markup" section.
//! Reading `parser.zig`'s doc comment first is recommended: it covers why a
//! plain recursive descent suffices here (unlike djot's flat event-stream
//! builder) and the error/diagnostic shape.
//!
//! Documented deviations from strict XML 1.0 well-formedness (each is a
//! deliberate simplification, not an oversight):
//!   - `Name` is approximated as ASCII letter/`_`/`:` start, plus
//!     alnum/`-`/`.`/`:`/any non-ASCII byte to continue — not the full
//!     Unicode `Name` production. International names still parse; a name
//!     using a codepoint XML itself would reject does too, harmlessly.
//!   - `]]>` occurring in ordinary text (outside a CDATA section) is not
//!     flagged as the well-formedness error the spec calls for.
//!   - The `PITarget` "xml"/"XML"/... case-insensitive reservation outside
//!     the XML declaration itself is not enforced — a stray `<?XML foo?>`
//!     parses as an ordinary processing instruction instead of erroring.
//!   - No external DTD subset is fetched or interpreted (by design — see
//!     the module-level "no external DTD processing" scope) and an internal
//!     subset's *contents* are skipped over as opaque bytes rather than
//!     parsed, so `<!ENTITY ...>` declarations don't create usable entities;
//!     referencing anything but the five predefined entities is always an
//!     `error.UnknownEntity`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");

const parser_mod = @import("parser.zig");
const serializer_mod = @import("serializer.zig");

pub const Parser = parser_mod.Parser;
pub const Diagnostic = parser_mod.Diagnostic;
pub const Error = parser_mod.Error;
pub const ParseError = parser_mod.ParseError;

pub const serialize = serializer_mod.serialize;
pub const serializeNode = serializer_mod.serializeNode;
pub const serializeAlloc = serializer_mod.serializeAlloc;

/// Parse `source` (an XML 1.0 document) into a fresh, self-contained `AST`
/// rooted at a `doc` node. On failure, this discards the failure's
/// `Diagnostic` (offset + message) — construct a `Parser` directly and call
/// its `.parse()` instead when that detail matters (e.g. to point an editor
/// at the exact byte that failed).
pub fn parse(allocator: Allocator, source: []const u8) ParseError!Document {
    var p = Parser.init(allocator, source);
    defer p.deinit();
    return p.parse();
}

test {
    _ = parser_mod;
    _ = serializer_mod;
}

// ── tree-equality helper (round-trip tests) ─────────────────────────────
// Structural comparison, ignoring `span`/`content_span` byte offsets (which
// necessarily differ between the original and the reparsed-after-serializing
// tree) but NOT ignoring content_span's null-ness, since that's the only
// signal carrying whether an element was written self-closing.

const Node = AST.Node;

fn kindsEqual(a: Node.Kind, b: Node.Kind) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .doc => true,
        .container => |av| std.mem.eql(u8, av.name, b.container.name),
        .str => |av| std.mem.eql(u8, av, b.str),
        .markup_leaf => |av| av.kind == b.markup_leaf.kind and std.mem.eql(u8, av.text, b.markup_leaf.text),
        .processing_instruction => |av| std.mem.eql(u8, av.target, b.processing_instruction.target) and
            std.mem.eql(u8, av.data, b.processing_instruction.data),
        // A well-formed-XML parse never produces any other kind.
        else => unreachable,
    };
}

fn attrsEqual(a: AST.Attrs, b: AST.Attrs) bool {
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key)) return false;
        if ((x.value == null) != (y.value == null)) return false;
        if (x.value) |xv| {
            if (!std.mem.eql(u8, xv, y.value.?)) return false;
        }
    }
    return true;
}

fn treesEqual(a: *const Document, a_id: Node.Id, b: *const Document, b_id: Node.Id) bool {
    const an = a.ast.nodes[a_id];
    const bn = b.ast.nodes[b_id];
    if (!kindsEqual(an.kind, bn.kind)) return false;
    if (!attrsEqual(a.ast.attrsOf(a_id), b.ast.attrsOf(b_id))) return false;
    // The self-closing signal is an ABSENT interior span, which now lives on
    // the document rather than the node — see `serializer.zig`.
    if ((a.contentSpan(a_id) == null) != (b.contentSpan(b_id) == null)) return false;

    var ia = a.children(a_id);
    var ib = b.children(b_id);
    while (true) {
        const ca = ia.next();
        const cb = ib.next();
        if (ca == null and cb == null) return true;
        const cca = ca orelse return false;
        const ccb = cb orelse return false;
        if (!treesEqual(a, cca.id, b, ccb.id)) return false;
    }
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const Span = @import("../../span.zig");

test "tree shape: prolog + doctype + nested elements/attrs + comment + cdata + pi + mixed text" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE root>
        \\<root xmlns:x="http://example.com/x" id="r1">
        \\  <!-- a comment -->
        \\  <child x:attr="v">text &amp; more<?pi data?></child>
        \\  <![CDATA[<raw> stuff]]>
        \\</root>
    ;
    var ast = try parse(testing.allocator, src);
    defer ast.deinit();

    try testing.expect(ast.ast.nodes[ast.ast.root].kind == .doc);

    var doc_it = ast.children(ast.ast.root);
    const xml_decl = doc_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(xml_decl.kind == .processing_instruction);
    try testing.expectEqualStrings("xml", xml_decl.kind.processing_instruction.target);
    try testing.expectEqualStrings("version=\"1.0\" encoding=\"UTF-8\"", xml_decl.kind.processing_instruction.data);

    const nl1 = doc_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(nl1.kind == .str);

    const doctype = doc_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(doctype.kind == .markup_leaf and doctype.kind.markup_leaf.kind == .doctype);
    try testing.expectEqualStrings(" root", doctype.kind.markup_leaf.text);

    const nl2 = doc_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(nl2.kind == .str);

    const root = doc_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(root.kind == .container);
    try testing.expectEqualStrings("root", root.kind.container.name);
    try testing.expectEqual(@as(?*const Node, null), doc_it.next());

    const root_attrs = ast.ast.attrsOf(root.id);
    try testing.expectEqualStrings("http://example.com/x", root_attrs.get("xmlns:x").?);
    try testing.expectEqualStrings("r1", root_attrs.get("id").?);

    var root_it = ast.children(root.id);
    const w1 = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(w1.kind == .str);

    const comment = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(comment.kind == .markup_leaf and comment.kind.markup_leaf.kind == .comment);
    try testing.expectEqualStrings(" a comment ", comment.kind.markup_leaf.text);

    const w2 = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(w2.kind == .str);

    const child = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(child.kind == .container);
    try testing.expectEqualStrings("child", child.kind.container.name);
    try testing.expectEqualStrings("v", ast.ast.attrsOf(child.id).get("x:attr").?);

    var child_it = ast.children(child.id);
    const child_text = child_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(child_text.kind == .str);
    try testing.expectEqualStrings("text & more", child_text.kind.str);
    const child_pi = child_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(child_pi.kind == .processing_instruction);
    try testing.expectEqualStrings("pi", child_pi.kind.processing_instruction.target);
    try testing.expectEqualStrings("data", child_pi.kind.processing_instruction.data);
    try testing.expectEqual(@as(?*const Node, null), child_it.next());

    const w3 = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(w3.kind == .str);

    const cdata = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(cdata.kind == .markup_leaf and cdata.kind.markup_leaf.kind == .cdata);
    try testing.expectEqualStrings("<raw> stuff", cdata.kind.markup_leaf.text);

    const w4 = root_it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(w4.kind == .str);
    try testing.expectEqual(@as(?*const Node, null), root_it.next());
}

test "spans: zero-width content_span for <a></a>, null for <a/>, exact offsets with attrs+text" {
    {
        var ast = try parse(testing.allocator, "<a></a>");
        defer ast.deinit();
        const el = ast.ast.nodes[ast.ast.root].first_child.?;
        try testing.expect(ast.span(el).eql(Span.init(0, 7)));
        try testing.expect(ast.contentSpan(el).?.eql(Span.init(3, 3)));
    }
    {
        var ast = try parse(testing.allocator, "<a/>");
        defer ast.deinit();
        const el = ast.ast.nodes[ast.ast.root].first_child.?;
        try testing.expect(ast.span(el).eql(Span.init(0, 4)));
        try testing.expectEqual(@as(?Span, null), ast.contentSpan(el));
    }
    {
        // 0123456789012345
        // <a b="1">x</a>
        var ast = try parse(testing.allocator, "<a b=\"1\">x</a>");
        defer ast.deinit();
        const el = ast.ast.nodes[ast.ast.root].first_child.?;
        try testing.expect(ast.span(el).eql(Span.init(0, 14)));
        try testing.expect(ast.contentSpan(el).?.eql(Span.init(9, 10)));
        const text = ast.ast.nodes[el].first_child.?;
        try testing.expect(ast.span(text).eql(Span.init(9, 10)));
        try testing.expectEqualStrings("x", ast.ast.nodes[text].kind.str);
    }
}

test "entities decode in both text and attribute values" {
    var ast = try parse(testing.allocator, "<a b=\"x &amp; y &#65; z\">t &lt;&gt; &apos;&quot; &#x41;</a>");
    defer ast.deinit();
    const el = ast.ast.nodes[ast.ast.root].first_child.?;
    try testing.expectEqualStrings("x & y A z", ast.ast.attrsOf(el).get("b").?);
    const text = ast.ast.nodes[el].first_child.?;
    try testing.expectEqualStrings("t <> '\" A", ast.ast.nodes[text].kind.str);
}

test "unknown entity errors with a diagnostic offset at the '&'" {
    var p = Parser.init(testing.allocator, "<a>x &nope; y</a>");
    defer p.deinit();
    try testing.expectError(error.UnknownEntity, p.parse());
    try testing.expectEqual(@as(usize, 5), p.diagnostic.?.offset);
}

test "errors: mismatched close tag, unclosed element, duplicate attribute, text after root" {
    {
        var p = Parser.init(testing.allocator, "<a><b></a></b>");
        defer p.deinit();
        try testing.expectError(error.MismatchedCloseTag, p.parse());
        try testing.expect(p.diagnostic != null);
    }
    {
        var p = Parser.init(testing.allocator, "<a><b></b>");
        defer p.deinit();
        try testing.expectError(error.UnclosedElement, p.parse());
        try testing.expect(p.diagnostic != null);
    }
    {
        var p = Parser.init(testing.allocator, "<a x=\"1\" x=\"2\"></a>");
        defer p.deinit();
        try testing.expectError(error.DuplicateAttribute, p.parse());
        try testing.expect(p.diagnostic != null);
    }
    {
        var p = Parser.init(testing.allocator, "<a></a>trailing");
        defer p.deinit();
        try testing.expectError(error.TextOutsideRoot, p.parse());
        try testing.expect(p.diagnostic != null);
    }
}

const rss_sample =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<rss version="2.0">
    \\  <channel>
    \\    <title>Example Feed</title>
    \\    <link>http://example.com/</link>
    \\    <description>An example RSS feed for testing.</description>
    \\    <language>en-us</language>
    \\    <item>
    \\      <title>First Post</title>
    \\      <link>http://example.com/first</link>
    \\      <guid isPermaLink="true">http://example.com/first</guid>
    \\      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    \\      <description><![CDATA[<p>Hello &amp; welcome!</p>]]></description>
    \\    </item>
    \\    <item>
    \\      <title>Second Post</title>
    \\      <link>http://example.com/second</link>
    \\      <guid isPermaLink="true">http://example.com/second</guid>
    \\      <pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate>
    \\      <description>Just some text, no markup.</description>
    \\    </item>
    \\  </channel>
    \\</rss>
;

test "round trip (tree level): parse -> serialize -> parse yields a structurally equal tree" {
    const samples = [_][]const u8{
        "<a/>",
        "<a x=\"1\"><b/><c>text</c></a>",
        "<root xmlns=\"urn:x\"><!-- c --><![CDATA[raw]]><?pi d?></root>",
        rss_sample,
    };
    for (samples) |src| {
        var ast1 = try parse(testing.allocator, src);
        defer ast1.deinit();

        const out = try serializeAlloc(testing.allocator, &ast1);
        defer testing.allocator.free(out);

        var ast2 = try parse(testing.allocator, out);
        defer ast2.deinit();

        try testing.expect(treesEqual(&ast1, ast1.ast.root, &ast2, ast2.ast.root));
    }
}

test "round trip (byte level): canonical-style input serializes byte-identically" {
    const samples = [_][]const u8{
        "<a/>",
        "<a b=\"1\" c=\"two\"></a>",
        "<root><child>hello world</child><child2 x=\"y\"/></root>",
        "<a>less &lt; than, amp &amp; amp</a>",
        "<root>\n  <child/>\n</root>",
        rss_sample,
    };
    for (samples) |src| {
        var ast = try parse(testing.allocator, src);
        defer ast.deinit();
        const out = try serializeAlloc(testing.allocator, &ast);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(src, out);
    }
}
