//! AsciiDoc: the conformance harness (`Asciidoc.conformance`, the vendored
//! AsciiDoc TCK corpus), the ASG codec it compares through (`Asciidoc.asg`),
//! and now a first-slice parser (`Asciidoc.parser`) — source bytes to twig's
//! shared `AST`, judged by `conformance.zig`'s `parse` comparison against the
//! same corpus the codec's `decode`/`encode` round-trip already climbed.
//! Mirrors where `languages/rst/` went: the testing harness landed first, so
//! the vocabulary-mapping work (`asg.zig`'s `Coverage`) had a ratchet to
//! climb before there was a parser to climb it with. There is still
//! deliberately no `format.zig` registry entry — `parser.zig`'s own doc
//! comment has the exact boundary of what this slice covers, and it is far
//! short of a registry-worthy claim of "supports AsciiDoc".
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

/// Source bytes -> twig's shared `AST`. See its module doc comment for what
/// this first slice covers (the document header, paragraphs, section
/// nesting, unordered lists, listing blocks, sidebars, constrained `*strong*`
/// spans) and for what's still unimplemented.
pub const parser = @import("parser.zig");

/// The vendored TCK corpus runner and its ratchets. See its module doc
/// comment for the codec round-trip and the parser comparison it now also
/// runs.
pub const conformance = @import("conformance.zig");

test {
    std.testing.refAllDecls(@This());
}
