//! `ParseOptions` — the feature flags threaded through the block parser
//! (`Markdown.parse` -> `block.parse` -> `Parser.init` -> `self.options`) and
//! consulted at each extension's own dispatch point, so that
//! `options == .commonmark` reproduces strict CommonMark exactly. Every flag
//! here is live as of Phase 3; `dialect` is the one deliberate exception (it
//! is a RENDER-time fact — see its own doc comment).
//!
//! Defaults follow GFM-ish expectations (most extensions on) except `math`,
//! `directives`, `html_elements`, and `highlight`, which aren't part of GFM and
//! stay opt-in.
//!
//! Two presets name the dialects twig renders distinctly — `commonmark` and
//! `gfm` — and both are composable: `args.zig` applies a preset first and
//! then any individual flags left-to-right, so `--gfm --math` means "GFM,
//! plus math".

const Options = @This();

tables: bool = true,
strikethrough: bool = true,
task_lists: bool = true,
autolinks: bool = true,
footnotes: bool = true,
definition_lists: bool = true,
frontmatter: bool = true,
/// Not part of GFM; off by default.
math: bool = false,
/// Generic directives (the remark/CommonMark "generic directives" proposal:
/// inline `:name[x]{attrs}`, leaf `::name[x]{attrs}`, container
/// `:::name{attrs}` ... `:::`). Not part of GFM; off by default, like `math`.
directives: bool = false,
/// `==text==` highlight (the markdown-it-mark / Obsidian / Typora extension):
/// a run of EXACTLY two `=` opens or closes a `mark` node, matched by the
/// same flanking rules as GFM strikethrough. A lone `=` or a run of three or
/// more stays literal, so `a == b` and a setext-looking `===` are untouched.
/// Not part of CommonMark or GFM; off by default, like `math`.
highlight: bool = false,
/// Coloured highlights, on top of `highlight` (Obsidian 1.14): a large-circle
/// emoji right after the opening `==` — `==🔴 text==` — names the colour. The
/// emoji is stripped from the content and recorded as `data-color="red"` on
/// the `mark` (see `highlight.zig` for the vocabulary and the optional-space
/// rule). Inert unless `highlight` is on, since there is no highlight to
/// colour otherwise; the CLI's `--highlight-colors` turns both on for that
/// reason. Off by default.
highlight_colors: bool = false,
/// Parse recognized HTML into the shared AST vocabulary — an `<img>` becomes
/// an `image` node, `<h1>` a `heading`, and anything without a semantic
/// mapping (`<picture>`, `<source>`, ...) a generic `element` — instead of a
/// single opaque `raw_block` / `raw_inline` holding the tag text verbatim.
/// This routes the block/tag through `languages/html/parser.zig`'s
/// `semanticKind` mapping, the same one the standalone HTML parser uses, so
/// the tree becomes addressable (query/edit an embedded `<img>`'s `src`)
/// rather than a black box.
///
/// Off by default: CommonMark 0.31.2 and GFM both specify raw HTML as
/// pass-through, so promotion would change parsing, and it is opt-in like
/// `math`/`directives`. A construct is only promoted when its accumulated
/// block/tag text maps verbatim onto the source (so a promoted node's span
/// still addresses the true input — the mission's correctness bar); anything
/// that doesn't map 1:1 (container-nested HTML, CRLF, expanded tabs) falls
/// back to the opaque `raw_block`/`raw_inline` it would have produced anyway.
html_elements: bool = false,

/// Which Markdown DIALECT this document is written in — the flavor whose
/// HTML conventions its rendering should follow.
///
/// Unlike every other field here, the parser never consults this one: the
/// extension flags above fully determine parsing. It exists because a
/// dialect is NOT recoverable from those flags, for two reasons:
///
///   1. Presets compose. `--gfm --math` yields an option set equal to no
///      preset, so "is this GFM?" can't be answered by comparing against
///      `Options.gfm`.
///   2. More fundamentally, two dialects can PARSE a construct identically
///      and still PRINT it differently. A GFM pipe table and a twig-markdown
///      pipe table produce exactly the same `table`/`row`/`cell` nodes; GFM
///      just spells a cell's alignment `align="center"` where twig-markdown
///      emits `style="text-align: center;"`. That's a render-time fact about
///      the dialect, invisible in the tree.
///
/// Maps 1:1 onto the shared printer's two markdown option presets — see
/// `languages/markdown/html.zig`, which does the mapping, and
/// `Html.commonmark_render_options`/`Html.gfm_render_options`.
dialect: Dialect = .commonmark,

/// The Markdown dialects twig renders distinctly. `commonmark` covers both
/// strict CommonMark and twig's own default flavor (CommonMark plus the
/// extensions above): the two parse differently but print identically, since
/// every convention they'd disagree on belongs to a construct strict
/// CommonMark doesn't have in the first place.
pub const Dialect = enum { commonmark, gfm };

/// Strict CommonMark: every extension off. Use this to compare Phase 1's
/// output against the CommonMark spec's own test suite (`conformance.zig`
/// uses this preset).
pub const commonmark: Options = .{
    .tables = false,
    .strikethrough = false,
    .task_lists = false,
    .autolinks = false,
    .footnotes = false,
    .definition_lists = false,
    .frontmatter = false,
    .math = false,
    .directives = false,
    .highlight = false,
    .highlight_colors = false,
    .html_elements = false,
    .dialect = .commonmark,
};

/// GitHub-Flavored Markdown's extension set (tables/strikethrough/task
/// lists/autolinks on; footnotes/definition lists/math off — GFM proper
/// doesn't define those), and GFM's HTML render conventions with it
/// (`.dialect = .gfm` — see that field's doc comment for why the flavor must
/// be recorded explicitly rather than inferred back out of the flags).
pub const gfm: Options = .{
    .tables = true,
    .strikethrough = true,
    .task_lists = true,
    .autolinks = true,
    .footnotes = false,
    .definition_lists = false,
    .frontmatter = false,
    .math = false,
    .directives = false,
    .highlight = false,
    .highlight_colors = false,
    .html_elements = false,
    .dialect = .gfm,
};
