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
//! That model is now built, in two files whose split IS the scope decision:
//! `diagnostic.zig` holds twig's record (a typed `Code`, a `Severity`, a byte
//! span, and interpolation `Args`), and `system_message.zig` holds everything
//! that is a fact about DOCUTILS' OUTPUT rather than about the error — its exact
//! wording, and eventually the tree placement. Nothing that exists only to match
//! a corpus is allowed onto the record twig hands a caller.
//!
//! ── Message fidelity is TIERED, and the tiers are not arbitrary ────────────
//! The 299 messages divide by what reproducing them would actually require:
//!
//!   - **Tier A — core parser (158 messages; 107 of the 219 cases contain
//!     nothing else). IN SCOPE, done.** Unclosed inline markup, unexpected
//!     indentation, a block that ends by dedenting, malformed tables, section
//!     title/underline problems, duplicate target names. Every one is a problem
//!     twig's own parser will have to detect and would want to report on its own
//!     terms anyway.
//!   - **Tier B — directive/role machinery (107 messages, 80 cases). DEFERRED
//!     to the directive milestone.** Not because it is verbose, but because
//!     these messages are GENERATED FROM A SCHEMA twig does not have:
//!     `%d argument(s) required, %d supplied`, `unknown option: "%s"`, and
//!     `not a positive measure of one of the following units` are readouts of a
//!     directive's registered arity, option names, and per-option converter.
//!     Twig has no directive registry at all — Markdown's `:::note` accepts any
//!     name and validates nothing — and it needs one to PARSE rST regardless.
//!     Moving Tier B here would mean building that registry under a diagnostics
//!     heading; building it under a directive heading gets these messages free.
//!   - **Tier C — implementation leakage (34 messages, 32 cases). OUT OF SCOPE,
//!     permanently.** Python module paths (`in module
//!     "docutils.parsers.rst.languages.de"`), `repr` output (`arguments=['x'],
//!     options={}`), and errno text (`InputError: [Errno 2]`). Twelve come from
//!     a docutils TEST FIXTURE directive that exists only to echo its own
//!     arguments. Matching these byte-for-byte means emitting Python's `repr`
//!     from Zig — imitating docutils' implementation, not conforming to
//!     reStructuredText.
//!
//! ── What the projection still owes ─────────────────────────────────────────
//! `system_message.subtree` builds the message NODE; three things remain before
//! the 107 Tier A cases can actually be compared against a parse:
//!
//!   - **Position in the tree**, the hard part. 249 of 299 sit at document
//!     level, but 50 nest (section 14, definition 12, topic 5, block_quote 5,
//!     footnote 3, and eight more with one or two each). Byte offset does not
//!     determine it: for `Unexpected indentation.` docutils places the message
//!     at document level BEFORE the block quote, while the offending offset
//!     falls INSIDE that block quote's range. The rule is per-code knowledge
//!     about a docutils message, so it belongs in `system_message.zig`, not on
//!     `Diagnostic` — and it is deferred rather than guessed, because with no
//!     parser there is no tree to insert into and any rule written now would be
//!     untestable.
//!   - **`ids`/`backrefs`** (35 and 50 messages) linking a message to its
//!     `<problematic>` node. Outputs of id resolution, which arrives with the
//!     `target`/`problematic` mapping work.
//!   - **The quoted excerpt** is already handled: 132 messages carry a
//!     `<literal_block>` of the offending source, which is exactly
//!     `source[span]` — the reason `Diagnostic` carries a span rather than a
//!     bare offset, mirroring fig's `failSpan`.
//!
//! One caveat survives regardless: `problematic` (48 instances) is a real markup
//! node, not a message. Docutils wraps inline markup that failed to parse in
//! one, pointing at the corresponding system message. The tree changes shape on
//! an inline error whatever twig does with diagnostics.
//!
//! ── Which directives get a schema ──────────────────────────────────────────
//! docutils registers ~30 core directives, and each needs a SCHEMA (argument
//! arity, whether content is allowed, and a converter per option) before twig
//! can parse it — `.. image:: pic.png` with `:width: 50%` cannot be read without
//! knowing `image`'s. Twig has no directive registry at all today: Markdown's
//! `:::note` accepts any name and validates nothing.
//!
//! The line: **a directive gets a schema when it produces CONTENT — a node twig
//! models (including `Kind.container`, which is exactly how Markdown's
//! `:::note` is already represented) — especially where it is rST's primary or
//! only spelling for that content, or where it fills in for a feature the
//! language otherwise lacks, the way Markdown falls back to raw HTML.**
//!
//! IN (165 of the corpus's 252 directive cases): `image` (33) and `figure` (12),
//! rST's ONLY way to place an image — there is no inline `![]()`; the table
//! directives `csv-table`/`table`/`list-table` (41); the admonition family (17)
//! and the other classed containers `topic` (12), `container`, `rubric`,
//! `sidebar`, `compound`; `code` (15) and `parsed-literal` (4); `math` (5);
//! `line-block` (4); and `raw` (7) — which IS the "Markdown uses HTML" case,
//! and which twig already models as `Kind.raw_block`/`raw_inline`.
//!
//! Also IN, on the primary-spelling half of the rule rather than the node half:
//! `replace` (8) and `unicode` (3). Neither produces a node of its own, but
//! substitutions are core rST SYNTAX — 33 `substitution_definition` and 18
//! `substitution_reference` nodes — and these are what substitution bodies are
//! actually made of (`image` 16, `replace` 11, `unicode` 11, `raw` 1 across the
//! corpus). Excluding them would leave a core construct with over half its
//! bodies unparseable.
//!
//! OUT (87 cases), because they configure the parser, feed a transform, or
//! describe the document rather than contribute to it:
//!
//!   - **Parser configuration** — `role` (17), `default-role` (3), `class` (2).
//!     See the warning below; these are NOT safe to ignore.
//!   - **Transform inputs** — `contents` (13), `target-notes` (4), `sectnum`
//!     (2). They emit `pending` placeholders for a pass that does not run here.
//!   - **Document description** — `meta` (12), `title` (1). Worth recording that
//!     `meta` is a NEAR-MISS, not a match: it produces attribute-only
//!     `<meta content="…" name="…">` (HTML document metadata), whereas twig's
//!     `Kind.metadata` is a data island holding raw text in a config language.
//!     Same word, different construct.
//!   - **Document furniture** — `header` (3), `footer` (2), which build a
//!     `decoration` alongside the body rather than in it.
//!   - **Generated values** — `date` (2). A transform wearing a directive's
//!     clothes: its output comes from the clock, not the source.
//!   - Already excluded on other grounds: `include` (2, file I/O) and the
//!     `restructuredtext-test-directive` (12, a docutils test fixture).
//!
//! ⚠ **Out of scope here does NOT mean "skip".** The parser-configuration
//! directives change how SUBSEQUENT parsing works: after
//! `.. default-role:: subscript`, every later `` `x` `` is a subscript rather
//! than a `title_reference`. A parser that silently ignores that line does not
//! merely omit a feature — it produces a wrong tree for the rest of the
//! document. These need a defined refusal (recognize, then report unsupported),
//! distinct from the unknown-directive path.
//!
//! ── Conversion lossiness is a DIFFERENT system, and it now EXISTS ──────────
//! "Djot's multi-line heading has no Markdown spelling" is not a parse
//! diagnostic and does not belong in this layer. It lives in `src/diagnostics.zig`
//! (`analyze(arena, ast, root, target)` returning a `Warning` per lossy node),
//! built after this scope statement first called for it. The separation is
//! structural: a parse diagnostic anchors to a byte span in the SOURCE, while a
//! conversion warning has no source offset to point at (the output does not
//! exist yet) and anchors to a node PATH; and a parse diagnostic is a fact about
//! one document while a conversion warning is a fact about a (document, target)
//! pair, so it cannot be stored alongside a `Document` at all.
//!
//! It matters to rST specifically because it is what UNBLOCKS the vocabulary
//! work below. Adding a kind only rST has (a citation, a substitution) hands the
//! djot/Markdown/HTML serializers a node their format cannot spell; before
//! `diagnostics.zig` there was nowhere to say so, and the loss would have been
//! silent. Now `fidelity` is exhaustive over `Kind`, so a new kind fails that
//! build until it declares an answer for every target — one place, rather than
//! an `else =>` arm in three serializers.
//!
//! ── What twig's AST does not yet hold ──────────────────────────────────────
//! `conformance.zig`'s coverage ratchet measures this continuously; 3378 of 5682
//! element instances (59%) decode to a semantic twig kind and the rest fall back
//! to `Kind.container`. Reading that table,
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
//!   - **Hyperlink machinery**, now half mapped. `reference` (134) is twig's
//!     `link` down to the payload, the external `target` (29 of 73) is its
//!     `reference`, and `footnote` (30) its `footnote` — 193 instances that
//!     needed no new vocabulary at all, only the observation that a definition's
//!     name is docutils' `names` attribute rather than its `<label>` child.
//!
//!     What remains is the part that DOES need vocabulary, and it is a single
//!     decision repeated: rST has four resolvable namespaces (hyperlink,
//!     footnote, citation, substitution) where twig has two. `citation` (14) and
//!     `citation_reference` (7) are footnotes in a second registry;
//!     `substitution_definition` (33) and `substitution_reference` (18) are a
//!     definition whose body is inline, which twig has no shape for; the
//!     indirect `target` (14) is an alias `Kind.Reference` cannot hold; the
//!     internal `target` (30) is an anchor, which twig models as an ATTRIBUTE
//!     and docutils resolves the same way, in a transform. `label` (23) stays
//!     generic on purpose — it is the rendered marker, not the name.
//!
//!     Each commits twig's published vocabulary (`ast/json.zig`, `c_abi.zig`)
//!     to a construct only rST has, and hands the djot/Markdown/HTML
//!     serializers a node their format cannot spell. That WAS the gate; the
//!     conversion-lossiness section below now names the system that opens it.
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

/// rST parse diagnostics — twig's own typed `Code`/`Severity`/`Diagnostic`
/// records, collected in a `Report` sidecar rather than built into the tree.
/// See its module doc comment for the Tier A/B/C scope split.
pub const diagnostic = @import("diagnostic.zig");

/// The docutils `<system_message>` projection: docutils' exact message wording
/// and the doctree node it lives in, kept apart from twig's own diagnostics so
/// conformance never dictates what twig says to a user.
pub const system_message = @import("system_message.zig");

test {
    std.testing.refAllDecls(@This());
}
