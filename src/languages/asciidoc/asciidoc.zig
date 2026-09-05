//! AsciiDoc: the parser (`Asciidoc.parser`) — source bytes to twig's shared
//! `AST` — the conformance harness that judges it (`Asciidoc.conformance`:
//! the vendored AsciiDoc TCK corpus plus twig's own authored one), and the
//! ASG codec both compare through (`Asciidoc.asg`). Mirrors where
//! `languages/rst/` went: the testing harness landed first, so the
//! vocabulary-mapping work had a ratchet to climb before there was a parser
//! to climb it with — and the parser then climbed it to the top.
//!
//! ── The corpus IS the boundary, and there are two of them ──────────────────
//! `testdata/asciidoc-tck-corpus.json` — 13 cases hand-vendored from the
//! Eclipse AsciiDoc Language Working Group's `asciidoc-tck`
//! (`gitlab.eclipse.org/eclipse/asciidoc-lang/asciidoc-tck`), whose own ASG
//! test suite is still `1.0.0-alpha.0` and has stopped growing alongside a
//! spec (`asciidoc-lang/asciidoc-lang`) that is itself still being written
//! section by section. That is the normative ratchet, and it is small.
//! `testdata/asciidoc-twig-corpus.json` is twig's OWN corpus, authored in
//! `scripts/asciidoc_cases.py` against the AsciiDoc Language documentation
//! and validated at generation time against the official ASG JSON Schema
//! (`testdata/asg-schema.json`), so its shapes are the Working Group's even
//! where its expectations are twig's. See `conformance.zig` for why the two
//! are kept apart, and each corpus file's `provenance` for where it came
//! from.
//!
//! ── What "finished" means here ─────────────────────────────────────────────
//! The ASG schema enumerates the whole block and inline vocabulary, and the
//! parser emits every shape in it; `parser.zig`'s doc comment lists the
//! constructs, and the few AsciiDoc has that the ASG (draft-01) does not model
//! yet — tables, footnotes, superscript and the like — which the parser reads
//! anyway and `asg.zig` writes as documented extensions. The `format.zig`
//! registry row carries the parser, the serializer (`Asciidoc.serializer`)
//! and the surface-syntax table (`Asciidoc.syntax`) that lets the editor's
//! authoring gestures work over an AsciiDoc document.

const std = @import("std");

/// The ASG (Abstract Semantic Graph) codec: `decode` a TCK expectation into
/// twig's shared `Document`, `encode` it back. The comparison format the
/// conformance harness is built on, and — once a parser exists — the printer
/// it compares through. See its module doc comment for the shape mapping and
/// why comparison is structural rather than byte-for-byte.
pub const asg = @import("asg.zig");

/// Source bytes -> twig's shared `AST`. See its module doc comment for the
/// constructs covered and the shape each takes in the shared vocabulary.
pub const parser = @import("parser.zig");

/// Twig's shared `AST` -> AsciiDoc text: `convert -o asciidoc`, and
/// `-o canonical` for a document that came from AsciiDoc. See its module
/// doc comment for the spellings and what degrades.
pub const serializer = @import("serializer.zig");

/// AsciiDoc's surface spelling — the table the editor's authoring gestures
/// consult and the serializer reads its delimiters from. See `src/syntax.zig`
/// for the model and this file for what stays null and why.
pub const syntax = @import("syntax.zig");

/// The vendored TCK corpus runner and its ratchets. See its module doc
/// comment for the codec round-trip and the parser comparison it now also
/// runs.
pub const conformance = @import("conformance.zig");

test {
    std.testing.refAllDecls(@This());
}
