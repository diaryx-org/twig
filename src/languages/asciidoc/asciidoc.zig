//! AsciiDoc: NOT a parser yet — the conformance harness (`Asciidoc.conformance`,
//! the vendored AsciiDoc TCK corpus) and the ASG codec it compares through
//! (`Asciidoc.asg`). Mirrors where `languages/rst/` started: a testing
//! harness first, so the vocabulary-mapping work (`asg.zig`'s `Coverage`) has
//! a ratchet to climb before there's a parser to climb it with. There is
//! deliberately no `format.zig` registry entry until `parse` exists.
//!
//! ── The corpus IS the boundary, and today it is a small one ────────────────
//! `testdata/asciidoc-tck-corpus.json` — 13 cases hand-vendored from the
//! Eclipse AsciiDoc Language Working Group's `asciidoc-tck`
//! (`gitlab.eclipse.org/eclipse/asciidoc-lang/asciidoc-tck`), whose own ASG
//! test suite is still `1.0.0-alpha.0` and growing alongside a spec
//! (`asciidoc-lang/asciidoc-lang`) that is itself still being written section
//! by section. Unlike rST's 713-case docutils corpus or CommonMark's 652, this
//! is not yet a corpus whose completion means anything — conformance here
//! means "passes what the TCK has today", full stop, and that boundary moves
//! as the TCK grows rather than staying fixed the way rST's vendored snapshot
//! does. See the corpus file's own `provenance` block for exactly where the
//! 13 cases came from.
//!
//! Covered today: paragraphs (including multi-paragraph and hard-wrapped
//! bodies), a document title and attribute entries, one level of sections,
//! unordered lists, delimited listing blocks, sidebars (generic container —
//! see `asg.zig`'s doc comment for why), and constrained `**strong**` spans.
//! Not yet exercised by the TCK at all: ordered lists, links, images, tables,
//! admonitions, cross references, and everything inline besides strong spans
//! and plain text.

const std = @import("std");

/// The ASG (Abstract Semantic Graph) codec: `decode` a TCK expectation into
/// twig's shared `Document`, `encode` it back. The comparison format the
/// conformance harness is built on, and — once a parser exists — the printer
/// it compares through. See its module doc comment for the shape mapping and
/// why comparison is structural rather than byte-for-byte.
pub const asg = @import("asg.zig");

/// The vendored TCK corpus runner and its ratchet. See its module doc comment
/// for what it asserts before a parser exists.
pub const conformance = @import("conformance.zig");

test {
    std.testing.refAllDecls(@This());
}
