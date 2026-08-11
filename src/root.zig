//! By convention, root.zig is the root source file when making a package.
//!
//! Twig parses document formats (Djot first) into a shared, index-based
//! `AST` — the document-format counterpart to fig's config-tree `AST` — so
//! that precise structural operations can be performed on a document,
//! rather than just converting between formats. See `twig.md` for the
//! project's goals and `AST`'s module doc comment for the node model.

/// The shared document AST every format parses into. See its module doc
/// comment for the node/kind model and the ownership discipline (every
/// string a node carries is copied, so a finished `AST` never borrows the
/// original source and is safe to hold onto after parsing).
pub const AST = @import("ast/ast.zig");

/// A parsed `AST` plus the source it came from and the byte spans tying them
/// together. `AST` holds MEANING; `Document` holds POSITION. Printers take
/// `*const AST` and cannot see a byte offset; the edit layer takes a
/// `*const Document` because splicing needs both. See `document.zig`.
pub const Document = @import("document.zig");

/// Djot support: `Djot.parse(allocator, source) !Djot.Document` (the shared
/// `AST` plus djot's reference/footnote side tables) plus `Djot.html` for
/// HTML rendering. See `languages/djot/djot.zig`'s module doc comment.
pub const Djot = @import("languages/djot/djot.zig");

/// XML support: `Xml.parse(allocator, source) !AST` (well-formed XML 1.0, no
/// external DTD processing) plus `Xml.serialize`/`Xml.serializeAlloc` for
/// rendering back to text. Unlike `Djot`, XML needs no side-table wrapper —
/// `parse` returns the shared `AST` directly. See `languages/xml/xml.zig`'s
/// module doc comment.
pub const Xml = @import("languages/xml/xml.zig");

/// HTML support: `Html.parse` builds generic-markup AST nodes from forgiving
/// HTML; `Html.serialize`/`Html.serializeAlloc` render the full shared
/// vocabulary.  The printer takes an optional `Html.Context` to resolve
/// djot-style reference/footnote side tables without this module depending on
/// `Djot`.
pub const Html = @import("languages/html/html.zig");

/// Markdown support: `Markdown.parse(allocator, source, options) !Markdown.Document`
/// (the shared `AST` plus Markdown's link-reference-definition side table)
/// plus `Markdown.ParseOptions` feature flags. Rendering uses
/// `Markdown.html` (an adapter over the shared `Html` printer). See
/// `languages/markdown/markdown.zig`'s module doc comment for scope details.
pub const Markdown = @import("languages/markdown/markdown.zig");

/// reStructuredText: NOT a parser yet — the conformance harness
/// (`Rst.conformance`, the vendored docutils corpus) and the docutils doctree
/// codec it compares through (`Rst.doctree`), plus the written scope line for
/// how much of rST twig supports. See `languages/rst/rst.zig`. There is
/// deliberately no `format.zig` registry entry until `parse` exists.
pub const Rst = @import("languages/rst/rst.zig");

/// Shared parse-diagnostic machinery: locating a byte offset in source
/// (`locateOffset`) and rendering the compiler-style `file:line:col` report with
/// a caret. Each language keeps its own typed `Code` enums and teaching
/// messages; only this offset-independent-of-code half is shared. Ported from
/// fig. See `parse_diagnostic.zig`.
pub const parse_diagnostic = @import("parse_diagnostic.zig");

/// Conversion diagnostics: what serializing an AST to a given format would
/// SILENTLY lose. A separate system from `parse_diagnostic` on purpose — a parse
/// diagnostic anchors to a byte span in one document's source, while these
/// anchor to a node path and are a fact about a (document, target) pair. See
/// `diagnostics.zig`, whose capability table is verified by round-tripping every
/// kind through every serializer rather than asserted.
pub const diagnostics = @import("diagnostics.zig");

/// The span-splice engine: lossless, in-place edits to a parsed document via
/// index paths into the shared `AST`. Language-agnostic by construction —
/// construct it with a `parse_fn` for the source's format and it never learns
/// what that format was. See `ast/splicer.zig`'s module doc comment for the
/// reparse/rollback model and its current limits.
///
/// For the authoring gestures a caret editor needs — Cmd-B, H1, quote, link —
/// use `Editor`, which is this plus a `Syntax`.
pub const Splicer = @import("ast/splicer.zig").Splicer;

/// The authoring editor: a `Splicer` plus the `Syntax` table that says how its
/// format is spelled. Hosts the gestures that need both an engine and a
/// spelling — `toggleInline`, `setBlock`, `toggleBlockContainer`, `insertLink`.
/// Build one from a `format.zig` registry entry, which pairs a language's
/// `parseToAst` with its `syntax`. See `ast/editor.zig`'s module doc comment for
/// why this layer exists and why it, not the engine, holds the `Editor` name.
pub const Editor = @import("ast/editor.zig").Editor;

/// What a format's surface syntax looks like — the delimiter/escape/spelling
/// tables `Editor`'s gestures consult, and the `null`s that make a format's
/// gaps (Markdown has no `{=mark=}`; XML has no inline markup at all) data
/// rather than a `switch` arm. See `syntax.zig`.
pub const Syntax = @import("syntax.zig").Syntax;

/// The format registry: one entry per language, bundling its parser, reparse
/// adapter, HTML renderer, optional serializers, and optional `Syntax` behind a
/// uniform shape. The single place a new language plugs in, and the single
/// source of `Format`. See `format.zig`.
pub const format = @import("format.zig");

/// Every language Twig can parse — re-exported from `format.zig` for reach.
pub const Format = format.Format;

/// Hit-testing: byte offset -> node (`deepestContaining`, `ancestorChain`), plus
/// the line scanning the block gestures are built on. The addressing scheme a
/// caret speaks. See `ast/locate.zig`.
pub const locate = @import("ast/locate.zig");

/// Locators: naming one node with a string that is either an index path
/// (`0.2.1`) or a `Select` selector (`heading[level=2]`). See `ast/locator.zig`.
pub const locator = @import("ast/locator.zig");

/// A byte range `[start, end)` into the source — the currency of the span-splice
/// engine, the authoring gestures, and the offset-addressed
/// `twig_editor_edit_range`/`node_at` C-ABI surface. See `span.zig`.
pub const Span = @import("span.zig");

/// Content-based node addressing: `Select.parse` a CSS-lite selector (e.g.
/// `heading[level=2]`, `link[dest^="http"]`, `item("eggs")`) then
/// `Select.resolveAll`/`resolveOne` it against an `AST` — the friendly
/// alternative to raw index paths, and the engine behind `twig query`/`edit`.
/// See `ast/select.zig`'s module doc comment.
pub const Select = @import("ast/select.zig");

/// Declarative document pruning over `Select` + `Splicer`: `Filter.apply` keeps
/// only the family members (`drop` selector) matching a `keep` predicate,
/// optionally unwrapping the survivors — the engine behind `twig filter`. See
/// `ast/filter.zig`'s module doc comment.
pub const Filter = @import("ast/filter.zig");

/// A stable, inspectable JSON encoding of the shared `AST`
/// (`ast_json.encode`/`encodeAlloc`) — the engine behind `twig convert -o ast`
/// and the C ABI's `twig_document_ast_json`. See `ast/json.zig`'s module doc
/// comment.
pub const ast_json = @import("ast/json.zig");

test {
    _ = AST;
    _ = Djot;
    _ = Xml;
    _ = Html;
    _ = Markdown;
    _ = @import("ast/splicer.zig");
    _ = @import("ast/editor.zig");
    _ = @import("ast/locate.zig");
    _ = @import("ast/locator.zig");
    _ = @import("syntax.zig");
    _ = @import("attrs_writer.zig");
    _ = @import("format.zig");
    _ = @import("languages/djot/syntax.zig");
    _ = @import("languages/markdown/syntax.zig");
    _ = Select;
    _ = Filter;
    _ = ast_json;
    _ = @import("ast/compact.zig");
    _ = Rst;
    _ = parse_diagnostic;
    // Not optional, and its absence was invisible: Zig analyzes lazily, so an
    // unreferenced module's exhaustive switches are never compiled. Without
    // this line `diagnostics.fidelity` was neither a gate on a new `Kind` nor a
    // test that ran, which is precisely the property `languages/rst/rst.zig`
    // says opened the rST vocabulary work.
    _ = diagnostics;
}
