//! `ParseOptions` — the feature flags threaded through the block parser
//! (`Markdown.parse` -> `block.parse` -> `Parser.init` -> `self.options`) and
//! consulted at each extension's own dispatch point, so that
//! `options == .commonmark` reproduces strict CommonMark exactly. Every flag
//! here is live as of Phase 3; `dialect` is the one deliberate exception (it
//! is a RENDER-time fact — see its own doc comment).
//!
//! Defaults follow GFM-ish expectations (most extensions on) except `math`
//! and `directives`, which aren't part of GFM and stay opt-in.
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
    .dialect = .gfm,
};
