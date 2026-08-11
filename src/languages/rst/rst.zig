//! reStructuredText — the conformance harness and, written down before any of
//! it is built, THE SCOPE LINE.
//!
//! Nothing here parses rST yet. What exists is the machinery that will say
//! whether a parser is right (`conformance.zig`) and the format it will be
//! judged in (`doctree.zig`), plus this file's statement of how much rST twig
//! is agreeing to support. That order is deliberate: rST is the first format
//! twig has taken on whose "support it" boundary is genuinely contested, and a
//! boundary decided later is a boundary decided by whatever the first bug
//! report happens to ask for.
//!
//! There is no `format.zig` registry entry for rST, and there should not be one
//! until `parse` exists — the registry is a claim of capability.
//!
//! ══ SCOPE ═════════════════════════════════════════════════════════════════
//!
//! ── Docutils core only. Not Sphinx. ────────────────────────────────────────
//! The reStructuredText that twig supports is the one defined by the docutils
//! reference implementation's own parser: the directives and roles registered
//! in `docutils.parsers.rst.directives`/`.roles`, and nothing else.
//!
//! Sphinx is excluded, and it is the exclusion that matters, because in
//! practice most rST in the world is Sphinx rST. Sphinx adds an open-ended
//! directive and role ecosystem — `toctree`, `automodule`, `py:function`,
//! `:ref:`, `:doc:`, plus whatever any installed extension registers at import
//! time — that is not a language surface at all but a plugin registry. It has
//! no fixed grammar to conform to and no test corpus to conform against; the
//! set of valid Sphinx documents depends on which Python packages are
//! installed. Without this line drawn explicitly, "support rST" silently
//! becomes "support Sphinx", which is unbounded.
//!
//! This is not a permanent refusal to parse a Sphinx document. An unknown
//! directive is a well-defined docutils construct (it produces an error, and
//! `Kind.container` with `Form.block_fenced`/`block_leaf` already holds its
//! shape), so Sphinx sources will parse — their unknown directives simply carry
//! no meaning twig claims to understand.
//!
//! ── The corpus IS the boundary ─────────────────────────────────────────────
//! `testdata/docutils-rst-corpus.json` — 713 cases across 100 groups, extracted
//! statically from docutils 0.21.2's own `test/test_parsers/test_rst` by
//! `scripts/extract-rst-corpus.py`. Conformance means passing it. That makes
//! the scope auditable rather than a matter of opinion, and it is why the
//! extraction script itemizes every case it had to skip in
//! `provenance.skipped` instead of dropping any silently.
//!
//! Known to sit OUTSIDE what the corpus can decide:
//!
//!   - **71 cases the extractor skipped**, because one half of the pair is not
//!     a Python literal (an f-string interpolating `__file__`, a
//!     `PYGMENTS_2_14_OR_HIGHER` conditional). Overwhelmingly `include`
//!     directive tests whose expectations embed the absolute path of the test
//!     file. Not portable to a Zig harness under any extraction scheme.
//!   - **13 filesystem- and network-touching cases** that DID extract:
//!     `include` (2), `include-root` (3), `csv-table :file:` (4), and
//!     `raw :file:`/`:url:` (4). Reading these means resolving a path relative
//!     to the document, or fetching a URL, inside what is otherwise a pure
//!     `source bytes -> tree` function. That is a capability decision (twig's
//!     parsers do no I/O), not a parsing one, and it is deferred rather than
//!     assumed.
//!   - **`docinfo`.** Zero cases in the corpus: docutils builds it in a
//!     post-parse TRANSFORM, not in the parser. Whatever twig does about
//!     document metadata is therefore not on rST's critical path.
//!
//! Docutils transforms in general are out of scope. The corpus asserts against
//! the parser's output, so the harness does too — `pending` nodes (15 in the
//! corpus: `contents`, `sectnum`, `target-notes`) are exactly the placeholders
//! the parser leaves for a transform that will not run here.
//!
//! ── Diagnostics are a sidecar, not tree nodes ──────────────────────────────
//! 299 nodes across 219 of the 713 cases are `<system_message>`: docutils
//! reports parse errors by putting them IN the doctree. Twig will not. Its rST
//! parser follows fig's model (`fig/src/languages/fig/parser.zig`,
//! `fig/src/parse_diagnostic.zig`): a `Report` sidecar of `Diagnostic`/`Warning`
//! records, each a typed `code` plus a byte span, with `describe`/`shortLabel`
//! teaching messages and shared caret rendering. The tree stays markup.
//!
//! The harness therefore owes a PROJECTION step — sidecar back into
//! `<system_message>` nodes — before those 219 cases can be compared. What that
//! projection has to reproduce, measured against the corpus rather than
//! guessed:
//!
//!   - **Severity** is docutils' `level`/`type` pair, which is a superset of
//!     fig's two-way error/warning split: 113 ERROR (3), 113 WARNING (2), 57
//!     INFO (1), 16 SEVERE (4). So the `code` enum needs a severity per code,
//!     not one enum per severity.
//!   - **Message text** is 171 distinct strings over 299 instances, and they
//!     interpolate (`Duplicate explicit target name: "target".`). So a code
//!     carries arguments — fig's `describe(code) []const u8` is not enough on
//!     its own. Docutils' exact wording should live in a projection-side table
//!     used by the harness, NOT in twig's own `describe`: matching docutils
//!     byte-for-byte is a conformance requirement, and twig's user-facing
//!     message quality is a separate concern that should not be hostage to it.
//!   - **The quoted excerpt.** 132 messages carry a `<literal_block>` child
//!     holding the offending source. That is derivable from the diagnostic's
//!     `[offset, end)` span, which is precisely why the span belongs on the
//!     record — fig's `failSpan` exists for the same reason.
//!   - **Position in the tree**, which is the hard part. 249 of 299 sit at
//!     document level, but 50 are nested (section 14, definition 12, topic 5,
//!     block_quote 5, footnote 3, and eight more parents with one or two each).
//!     A flat list keyed by byte offset does not by itself say where in the
//!     tree a message goes, so the projection needs an insertion point, not
//!     just a line number.
//!
//! One caveat that survives regardless: `problematic` (48 instances) is a real
//! markup node, not a message. Docutils wraps inline markup that failed to
//! parse in one, pointing at the corresponding system message. The tree changes
//! shape on an inline error whatever twig does with diagnostics.
//!
//! ── What twig's AST does not yet hold ──────────────────────────────────────
//! `conformance.zig`'s coverage ratchet measures this continuously; as of the
//! initial harness, 3185 of 5682 element instances (56%) decode to a semantic
//! twig kind and the rest fall back to `Kind.container`. Reading that table,
//! the structural work rST implies, in rough order of corpus weight:
//!
//!   - **The table subtree** (`entry` 266, `colspec` 142, `row` 124, `table` 65,
//!     `tgroup` 65, `tbody` 65, `thead` 12). Docutils puts a `tgroup` carrying
//!     `cols` and per-column `colwidth` between a table and its rows, and marks
//!     header rows by nesting them under `thead`; twig's `table` holds
//!     `[caption, row...]` and marks headers with `row.head`. One restructuring
//!     decision, to be made as a unit. Cell spans already landed
//!     (`Kind.Cell.colspan`/`rowspan`); docutils spells them `morecols`/
//!     `morerows`, extent MINUS one, so the parser converts at its boundary.
//!   - **`title` (101).** Twig spells it `heading`, which carries a `level` the
//!     doctree does not write — it would have to come from section nesting
//!     depth, and `title` also appears under `topic`/`sidebar`/`table` where
//!     there is no such depth.
//!   - **Hyperlink machinery**: `reference` (134), `target` (73),
//!     `footnote_reference` (32), `footnote` (30), `substitution_definition`
//!     (33), `substitution_reference` (18), `citation` (14),
//!     `citation_reference` (7). Citations are a namespace DISTINCT from
//!     footnotes in rST; twig has one `Kind.footnote`.
//!   - **Field lists** (`field` 54, `field_name` 54, `field_body` 54,
//!     `field_list` 21). Structural, NOT attribute data — docutils parses a
//!     body-position `:Author: Me` into a real subtree whose body holds
//!     arbitrary blocks. Only DIRECTIVE OPTIONS are `Attrs` data.
//!   - **Option lists** (`option_string` 54, `option` 54, `description` 48,
//!     `option_group` 48, `option_list_item` 48, `option_argument` 38,
//!     `option_list` 15) and **line blocks** (`line` 47, `line_block` 30) —
//!     two constructs with no counterpart in any format twig parses today.
//!   - **`inline` (43)**, docutils' generic classed span, and `problematic`
//!     (48). Both map onto `Kind.container` reasonably; they are listed so the
//!     count is not mistaken for a gap.
//!
//! One `Attrs`-shape question is already known and is NOT about duplicate keys
//! (docutils rejects a repeated directive option outright, so first-match
//! `Attrs.find` is correct for rST): docutils' `classes` and `names` are
//! LIST-valued, while twig's `KeyVal.value` is a scalar. Space-joining matches
//! HTML; `names` additionally allows backslash-escaped spaces inside a single
//! name, so its escaping needs deciding.

const std = @import("std");

/// The docutils pseudo-XML doctree codec: `decode` a `document.pformat()` dump
/// into twig's shared `AST`, `encode` it back. The comparison format the
/// conformance harness is built on, and — once a parser exists — the printer it
/// compares through. See its module doc comment for the pformat grammar.
pub const doctree = @import("doctree.zig");

/// The vendored docutils corpus runner and its ratchets. See its module doc
/// comment for what it asserts before a parser exists and what changes after.
pub const conformance = @import("conformance.zig");

test {
    std.testing.refAllDecls(@This());
}
