//! reStructuredText — the conformance harness, the parser, and THE SCOPE LINE.
//! Port of `src/languages/rst/rst.zig` (whose module doc is the full scope
//! statement; the essentials are kept here).
//!
//! There is no `format` registry entry for rST yet — the registry is a claim
//! of capability, and the parser covers only a first slice (see `parser`).
//!
//! ══ SCOPE ═════════════════════════════════════════════════════════════════
//!
//! ── Docutils core only. Not Sphinx. ────────────────────────────────────────
//! The reStructuredText twig supports is the one defined by the docutils
//! reference parser: the directives and roles registered in
//! `docutils.parsers.rst.directives`/`.roles`, and nothing else. Sphinx's
//! directive/role ecosystem is a plugin registry with no fixed grammar. An
//! unknown directive is still a well-defined docutils construct, so Sphinx
//! sources will parse — their unknown directives carry no meaning twig claims.
//!
//! ── The corpus IS the boundary ─────────────────────────────────────────────
//! `testdata/docutils-rst-corpus.json` — 713 cases across 100 groups, from
//! docutils 0.21.2's own tests. Outside what it can decide: 71 skipped cases
//! (non-literal Python), 13 filesystem/network cases (`include`, `csv-table
//! :file:`, `raw :file:`/`:url:` — twig's parsers do no I/O), and `docinfo`
//! (a post-parse transform). Docutils transforms are out of scope; `pending`
//! nodes are the placeholders the parser leaves for them.
//!
//! ── Diagnostics are a sidecar, not tree nodes ──────────────────────────────
//! docutils reports parse errors IN the doctree (`<system_message>`). Twig
//! does not: `diagnostic` holds twig's record (typed `Code`, `Severity`, byte
//! span, `Args`), and `system_message` holds everything that is a fact about
//! DOCUTILS' OUTPUT (its exact wording, and eventually tree placement).
//!
//! ── Message fidelity is TIERED ─────────────────────────────────────────────
//!   - **Tier A — core parser (158 messages). IN SCOPE, done.**
//!   - **Tier B — directive/role machinery (107 messages). DEFERRED** to the
//!     directive milestone: those messages are generated from a directive
//!     SCHEMA (arity, option names, converters) twig does not have yet.
//!   - **Tier C — implementation leakage (34 messages). OUT OF SCOPE**:
//!     Python module paths, `repr` output, errno text.
//!
//! ── Which directives get a schema ──────────────────────────────────────────
//! A directive gets a schema when it produces CONTENT — a node twig models
//! (including `Kind::Container`) — especially where it is rST's primary or
//! only spelling for it: `image`, `figure`, the table directives, the
//! admonitions, `topic`/`container`/`rubric`/`sidebar`/`compound`, `code`,
//! `parsed-literal`, `math`, `line-block`, `raw`, plus `replace` and
//! `unicode` (substitution bodies). OUT: parser configuration (`role`,
//! `default-role`, `class` — which must be REFUSED, not skipped, since they
//! change how later text parses), transform inputs (`contents`,
//! `target-notes`, `sectnum`), document description (`meta`, `title`),
//! furniture (`header`, `footer`), generated values (`date`).
//!
//! ── What twig's AST does not yet hold ──────────────────────────────────────
//! `conformance`'s coverage ratchet measures it continuously. Done: the table
//! subtree (`Kind::Column`, `tgroup`/`thead`/`tbody` dissolved), line blocks
//! (`Kind::Line { indent }`, nested wrappers dissolved), option lists
//! (absorbed into the definition-list kinds), citations and substitutions.
//! Still generic: `title` outside a table, the indirect and internal
//! `target`, field lists, `inline`, `problematic`.
//!
//! ⚠ A substitution is `dropped` by every serializer — its body belongs at
//! its USE sites and no printer resolves one.

/// Source bytes -> twig's shared `Ast` (first vertical slice).
pub mod parser;

/// The docutils pseudo-XML doctree codec: `decode` a `document.pformat()`
/// dump into twig's `Ast`, `encode` it back.
pub mod doctree;

/// The vendored docutils corpus runner and its ratchets.
pub mod conformance;

/// rST parse diagnostics — twig's own typed records, collected in a `Report`
/// sidecar rather than built into the tree.
pub mod diagnostic;

/// The docutils `<system_message>` projection: docutils' exact wording and the
/// doctree node it lives in.
pub mod system_message;
