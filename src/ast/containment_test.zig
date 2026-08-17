//! Checks `Kind.structuralChildren` and `Kind.contentModel` against every
//! document Twig can actually produce.
//!
//! A containment rule that only a doc comment asserts is a rule that drifts —
//! which is the whole reason those two facts moved out of prose and into
//! `ast.zig`. So the oracle here is not a hand-written fixture but the
//! vendored corpora themselves: CommonMark and GFM, the docutils rST corpus
//! (through the parser AND the doctree decoder, which reaches a much wider
//! vocabulary), both AsciiDoc corpora, and djot's `.test` suite. Six parsers,
//! ~7000 documents.
//!
//! Two invariants, both of which the corpora satisfy and neither of which was
//! checked before:
//!
//!   1. A `.text` or `.empty` `contentModel` means NO children. This one
//!      caught a real bug on its first run: `languages/html/parser.zig` mapped
//!      `<pre><code>x</code></pre>` onto a `code_block` while leaving the
//!      absorbed `<code>` node attached, so the same bytes hung off the tree
//!      three times under two nodes that are documented as childless.
//!
//!   2. A parent with a closed `structuralChildren` set holds only that set,
//!      plus `Kind.generic_markup`. The escape-hatch half is not a hedge: the
//!      corpora put an rST `classifier` container inside a
//!      `definition_list_item`, a `system_message` inside a `line_block`, and
//!      an HTML `colgroup` inside a `table`.
//!
//! What is deliberately NOT asserted is the block/inline LEVEL of a general
//! parent's children — see `Kind.admitsChild`, which explains why the corpora
//! refute the rule that axis looks like it should give.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast.zig");
const Node = AST.Node;
const Kind = Node.Kind;

const Djot = @import("../languages/djot/djot.zig");
const Markdown = @import("../languages/markdown/markdown.zig");
const Html = @import("../languages/html/html.zig");
const Xml = @import("../languages/xml/xml.zig");
const rst_parser = @import("../languages/rst/parser.zig");
const doctree = @import("../languages/rst/doctree.zig");
const adoc_parser = @import("../languages/asciidoc/parser.zig");
const adoc_conf = @import("../languages/asciidoc/conformance.zig");

const md_spec_json = @embedFile("../languages/markdown/testdata/commonmark-spec-0.31.2.json");
const gfm_spec_json = @embedFile("../languages/markdown/testdata/gfm-spec-0.29-extensions.json");
const rst_corpus_json = @embedFile("../languages/rst/testdata/docutils-rst-corpus.json");

/// The vendored djot suite, mirroring `languages/djot/conformance.zig`'s list.
/// Only the bytes matter here — this test reports violations by source format,
/// not by fixture file — so these are the contents, embedded like the
/// CommonMark and docutils corpora above.
const djot_testfiles = [_][]const u8{
    @embedFile("../languages/djot/testdata/attributes.test"),
    @embedFile("../languages/djot/testdata/block_quote.test"),
    @embedFile("../languages/djot/testdata/code_blocks.test"),
    @embedFile("../languages/djot/testdata/definition_lists.test"),
    @embedFile("../languages/djot/testdata/symb.test"),
    @embedFile("../languages/djot/testdata/emphasis.test"),
    @embedFile("../languages/djot/testdata/escapes.test"),
    @embedFile("../languages/djot/testdata/fenced_divs.test"),
    @embedFile("../languages/djot/testdata/footnotes.test"),
    @embedFile("../languages/djot/testdata/headings.test"),
    @embedFile("../languages/djot/testdata/insert_delete_mark.test"),
    @embedFile("../languages/djot/testdata/links_and_images.test"),
    @embedFile("../languages/djot/testdata/lists.test"),
    @embedFile("../languages/djot/testdata/math.test"),
    @embedFile("../languages/djot/testdata/para.test"),
    @embedFile("../languages/djot/testdata/raw.test"),
    @embedFile("../languages/djot/testdata/regression.test"),
    @embedFile("../languages/djot/testdata/smart.test"),
    @embedFile("../languages/djot/testdata/spans.test"),
    @embedFile("../languages/djot/testdata/sourcepos.test"),
    @embedFile("../languages/djot/testdata/super_subscript.test"),
    @embedFile("../languages/djot/testdata/tables.test"),
    @embedFile("../languages/djot/testdata/task_lists.test"),
    @embedFile("../languages/djot/testdata/thematic_breaks.test"),
    @embedFile("../languages/djot/testdata/verbatim.test"),
};

const Violation = struct {
    source: []const u8,
    parent: []const u8,
    child: []const u8,
    reason: enum { childless_kind_has_children, outside_structural_vocabulary },
};

const Checker = struct {
    allocator: Allocator,
    source: []const u8 = "",
    violations: std.ArrayList(Violation) = .empty,

    fn deinit(self: *Checker) void {
        self.violations.deinit(self.allocator);
    }

    fn check(self: *Checker, ast: *const AST) !void {
        for (ast.nodes) |n| {
            var child = n.first_child;
            while (child) |cid| {
                const c = ast.nodes[cid];
                if (!n.kind.admitsChild(c.kind)) {
                    const childless = switch (n.kind.contentModel()) {
                        .text, .empty => true,
                        .blocks, .inlines => false,
                    };
                    try self.violations.append(self.allocator, .{
                        .source = self.source,
                        .parent = n.kind.kindName(),
                        .child = c.kind.kindName(),
                        .reason = if (childless)
                            .childless_kind_has_children
                        else
                            .outside_structural_vocabulary,
                    });
                }
                child = c.next_sibling;
            }
        }
    }
};

const MdExample = struct { markdown: []const u8 };
const RstCase = struct { rst: []const u8, doctree: []const u8 };
const RstCorpus = struct { cases: []const RstCase };
const AdocCorpus = struct { cases: []const adoc_conf.Case };

test "every corpus document respects the AST containment rules" {
    const allocator = std.testing.allocator;
    var checker: Checker = .{ .allocator = allocator };
    defer checker.deinit();

    // ── Markdown: CommonMark + GFM, with the opt-in extensions ON, since
    //    `html_elements` promotion is where invariant 1 was broken.
    checker.source = "markdown";
    inline for (.{ md_spec_json, gfm_spec_json }) |json| {
        var parsed = try std.json.parseFromSlice([]const MdExample, allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        for (parsed.value) |ex| {
            var doc = try Markdown.parse(allocator, ex.markdown, .{
                .math = true,
                .directives = true,
                .html_elements = true,
            });
            defer doc.deinit();
            try checker.check(&doc.ast);
        }
    }

    // ── rST: the parser for what it can read, the doctree decoder for the
    //    rest of the vocabulary (columns, spans, citations, substitutions).
    {
        var parsed = try std.json.parseFromSlice(RstCorpus, allocator, rst_corpus_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        for (parsed.value.cases) |case| {
            checker.source = "rst (parser)";
            if (rst_parser.parse(allocator, case.rst, .{ .source_name = "test data" })) |r| {
                var result = r;
                defer result.deinit(allocator);
                try checker.check(&result.document.ast);
            } else |_| {}

            checker.source = "rst (doctree decode)";
            var ast = doctree.decode(allocator, case.doctree, null) catch continue;
            defer ast.deinit();
            try checker.check(&ast);
        }
    }

    // ── AsciiDoc: the TCK corpus and twig's own.
    checker.source = "asciidoc";
    inline for (.{ adoc_conf.tck_corpus_json, adoc_conf.twig_corpus_json }) |json| {
        var parsed = try std.json.parseFromSlice(AdocCorpus, allocator, json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        for (parsed.value.cases) |case| {
            var doc = adoc_parser.parse(allocator, case.adoc) catch continue;
            defer doc.deinit();
            try checker.check(&doc.ast);
        }
    }

    // ── Djot: each framed case's INPUT half, from the same vendored files
    //    `languages/djot/conformance.zig` runs.
    checker.source = "djot";
    {
        for (djot_testfiles) |text| {
            // A case opens with a backtick fence; its input ends at a lone `.`
            // or `!`. Feeding whole files instead would invent trees no real
            // document has.
            var lines = std.mem.splitScalar(u8, text, '\n');
            var input = std.ArrayList(u8).empty;
            defer input.deinit(allocator);
            var in_input = false;
            while (lines.next()) |raw| {
                const line = if (raw.len > 0 and raw[raw.len - 1] == '\r')
                    raw[0 .. raw.len - 1]
                else
                    raw;
                if (!in_input) {
                    if (line.len > 0 and line[0] == '`') in_input = true;
                    continue;
                }
                if (std.mem.eql(u8, line, ".") or std.mem.eql(u8, line, "!")) {
                    var doc = try Djot.parse(allocator, input.items);
                    defer doc.deinit();
                    try checker.check(&doc.ast);
                    input.clearRetainingCapacity();
                    in_input = false;
                    continue;
                }
                try input.appendSlice(allocator, line);
                try input.append(allocator, '\n');
            }
        }
    }

    // ── HTML / XML: no vendored corpus, so a snippet covering the
    //    generic-markup corner and the table axis these rules constrain.
    checker.source = "html";
    {
        const html_src =
            \\<!DOCTYPE html><!-- c --><table><caption>c</caption><colgroup><col span="2"></colgroup>
            \\<tr><td colspan="2"><p>x</p></td></tr></table><pre><code>k</code></pre>
            \\<video><source></video><dl><dt>t</dt><dd>d</dd></dl>
        ;
        var doc = try Html.parse(allocator, html_src);
        defer doc.deinit();
        try checker.check(&doc.ast);
    }
    checker.source = "xml";
    {
        const xml_src =
            \\<?xml version="1.0"?><!-- c --><r><![CDATA[raw]]><a x="1">t</a><?pi data?></r>
        ;
        var doc = try Xml.parse(allocator, xml_src);
        defer doc.deinit();
        try checker.check(&doc.ast);
    }

    if (checker.violations.items.len > 0) {
        for (checker.violations.items) |v| std.debug.print(
            "containment violation [{s}]: {s} > {s} ({s})\n",
            .{ v.source, v.parent, v.child, @tagName(v.reason) },
        );
        return error.ContainmentViolation;
    }
}
