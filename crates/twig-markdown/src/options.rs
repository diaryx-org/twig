//! `ParseOptions` — the feature flags threaded through the block parser and
//! consulted at each extension's own dispatch point, so that
//! `options == ParseOptions::COMMONMARK` reproduces strict CommonMark exactly.
//! Port of `src/languages/markdown/options.zig`.
//!
//! Defaults follow GFM-ish expectations (most extensions on) except `math`,
//! `directives`, `html_elements`, and `highlight`, which aren't part of GFM
//! and stay opt-in.

/// The feature flags of one Markdown parse.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ParseOptions {
    pub tables: bool,
    pub strikethrough: bool,
    pub task_lists: bool,
    pub autolinks: bool,
    pub footnotes: bool,
    pub definition_lists: bool,
    pub frontmatter: bool,
    /// Not part of GFM; off by default.
    pub math: bool,
    /// Generic directives (inline `:name[x]{attrs}`, leaf `::name[x]{attrs}`,
    /// container `:::name{attrs}` ... `:::`). Off by default.
    pub directives: bool,
    /// `==text==` highlight: a run of EXACTLY two `=` opens or closes a
    /// `mark` node, matched by the same flanking rules as GFM strikethrough.
    /// Off by default.
    pub highlight: bool,
    /// Coloured highlights on top of `highlight`: a large-circle emoji right
    /// after the opening `==` names the colour (`data-color`). Inert unless
    /// `highlight` is on. Off by default.
    pub highlight_colors: bool,
    /// Parse recognized HTML into the shared AST vocabulary instead of opaque
    /// `raw_block`/`raw_inline`. Also pairs `<div>`/`</div>` lines,
    /// `<span>…</span>` and `<u>…</u>`. Off by default.
    pub html_elements: bool,
    /// Which Markdown DIALECT this document is written in. The parser never
    /// consults it: it is a RENDER-time fact (GFM spells cell alignment
    /// differently), not recoverable from the flags above.
    pub dialect: Dialect,
}

/// The Markdown dialects twig renders distinctly. `Commonmark` covers both
/// strict CommonMark and twig's own default flavor.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Dialect {
    #[default]
    Commonmark,
    Gfm,
}

/// The opt-in extensions a caller may lay over a dialect's preset, per parse.
/// Only the extensions that are OFF in every preset are here, which is what
/// makes "laid over" a plain OR ([`ParseOptions::with_extensions`]).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Extensions {
    pub directives: bool,
    pub math: bool,
    pub html_elements: bool,
    pub highlight: bool,
    /// Inert without `highlight`, exactly as the field it maps onto.
    pub highlight_colors: bool,
}

impl Default for ParseOptions {
    fn default() -> Self {
        ParseOptions {
            tables: true,
            strikethrough: true,
            task_lists: true,
            autolinks: true,
            footnotes: true,
            definition_lists: true,
            frontmatter: true,
            math: false,
            directives: false,
            highlight: false,
            highlight_colors: false,
            html_elements: false,
            dialect: Dialect::Commonmark,
        }
    }
}

impl ParseOptions {
    /// Strict CommonMark: every extension off.
    pub const COMMONMARK: ParseOptions = ParseOptions {
        tables: false,
        strikethrough: false,
        task_lists: false,
        autolinks: false,
        footnotes: false,
        definition_lists: false,
        frontmatter: false,
        math: false,
        directives: false,
        highlight: false,
        highlight_colors: false,
        html_elements: false,
        dialect: Dialect::Commonmark,
    };

    /// GitHub-Flavored Markdown's extension set, and GFM's HTML render
    /// conventions with it.
    pub const GFM: ParseOptions = ParseOptions {
        tables: true,
        strikethrough: true,
        task_lists: true,
        autolinks: true,
        footnotes: false,
        definition_lists: false,
        frontmatter: false,
        math: false,
        directives: false,
        highlight: false,
        highlight_colors: false,
        html_elements: false,
        dialect: Dialect::Gfm,
    };

    /// The default flavor (`ParseOptions::default()`), as a function.
    pub fn markdown() -> ParseOptions {
        ParseOptions::default()
    }

    /// Strict CommonMark preset.
    pub fn commonmark() -> ParseOptions {
        ParseOptions::COMMONMARK
    }

    /// GFM preset.
    pub fn gfm() -> ParseOptions {
        ParseOptions::GFM
    }

    /// `self` with `ext`'s opt-ins turned on. `dialect` and every default-on
    /// flag come from `self` untouched.
    pub fn with_extensions(self, ext: Extensions) -> ParseOptions {
        let mut out = self;
        out.directives = self.directives || ext.directives;
        out.math = self.math || ext.math;
        out.html_elements = self.html_elements || ext.html_elements;
        out.highlight = self.highlight || ext.highlight;
        out.highlight_colors = self.highlight_colors || ext.highlight_colors;
        out
    }
}

/// Free-function form of [`ParseOptions::with_extensions`] (Zig's
/// `Options.withExtensions`).
pub fn with_extensions(base: ParseOptions, ext: Extensions) -> ParseOptions {
    base.with_extensions(ext)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions_covers_exactly_the_flags_every_preset_leaves_off() {
        for preset in [ParseOptions::default(), ParseOptions::COMMONMARK, ParseOptions::GFM] {
            assert!(!preset.directives);
            assert!(!preset.math);
            assert!(!preset.html_elements);
            assert!(!preset.highlight);
            assert!(!preset.highlight_colors);
            assert_eq!(preset, preset.with_extensions(Extensions::default()));
        }
        let over_gfm = ParseOptions::GFM.with_extensions(Extensions { math: true, ..Default::default() });
        assert!(over_gfm.math && over_gfm.tables && !over_gfm.footnotes);
        assert_eq!(Dialect::Gfm, over_gfm.dialect);
    }
}
