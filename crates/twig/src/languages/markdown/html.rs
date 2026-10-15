//! Document -> HTML renderer. Port of `src/languages/markdown/html.zig`: a
//! thin adapter over the shared, language-neutral printer
//! (`languages::html::serializer`).
//!
//! Markdown resolves `link`/`image` references at PARSE time, so the shared
//! printer never looks a reference up here. Footnotes are the one Markdown
//! construct that resolves at RENDER time, so `labels.footnotes` is the table
//! that matters — which is why the CLI renders Markdown through this module
//! rather than the bare generic printer (which would drop every footnote).

use crate::document::Document;
use crate::languages::html::{self as html_lang, RenderAllocError, RenderError, Renderer};
use crate::languages::markdown::Dialect;

#[derive(Clone, Copy, Debug, Default)]
pub struct RenderOptions {
    pub warn: Option<fn(&str)>,
    /// Which Markdown dialect's HTML conventions to print with — GFM spells a
    /// table cell's alignment `align="center"` where twig's default flavour
    /// writes a `style`. This is `ParseOptions::dialect`, which the parser
    /// never reads and the `Document` does not record; the caller that held
    /// the parse config supplies it.
    pub dialect: Dialect,
}

/// Render `doc` (rooted at `doc.ast.root`) to HTML, appending to `out`.
pub fn render(doc: &Document, out: &mut Vec<u8>, options: RenderOptions) -> Result<(), RenderError> {
    let mut render_opts = match options.dialect {
        Dialect::Commonmark => html_lang::COMMONMARK_RENDER_OPTIONS,
        Dialect::Gfm => html_lang::GFM_RENDER_OPTIONS,
    };
    render_opts.warn = options.warn;
    let mut r = Renderer::new(&doc.ast, out, Some(&doc.labels), render_opts);
    r.render_node(doc.ast.root)
}

/// Convenience wrapper: render to an owned buffer (Zig's `renderAlloc`).
pub fn render_alloc(doc: &Document, options: RenderOptions) -> Result<Vec<u8>, RenderAllocError> {
    let mut out = Vec::new();
    render(doc, &mut out, options)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::languages::markdown::{parse, ParseOptions};

    fn md() -> ParseOptions {
        ParseOptions::markdown()
    }

    fn html_of(src: &str, opts: ParseOptions, ro: RenderOptions) -> String {
        let doc = parse(src.as_bytes(), opts);
        String::from_utf8(render_alloc(&doc, ro).unwrap()).unwrap()
    }

    fn gfm_ro() -> RenderOptions {
        RenderOptions { dialect: Dialect::Gfm, ..Default::default() }
    }

    #[test]
    fn dialect_the_same_table_prints_twig_markdown_shaped_by_default_and_gfm_shaped_under_gfm() {
        let src = "| a |\n| :-: |\n| 1 |\n";
        let md_out = html_of(src, ParseOptions { tables: true, ..md() }, RenderOptions::default());
        let gfm_out = html_of(src, ParseOptions::gfm(), gfm_ro());
        assert!(md_out.contains("<thead>"));
        assert!(gfm_out.contains("<thead>"));
        assert!(md_out.contains("<th style=\"text-align: center;\">a</th>"));
        assert!(gfm_out.contains("<th align=\"center\">a</th>"));
        assert!(!md_out.contains("align=\"center\""));
        assert!(!gfm_out.contains("text-align"));
    }

    #[test]
    fn dialect_tagfilter_is_gfm_only() {
        let src = "<strong> <title>\n";
        let md_out = html_of(src, md(), RenderOptions::default());
        assert!(md_out.contains("<title>"));
        let gfm_out = html_of(src, ParseOptions::gfm(), gfm_ro());
        assert!(gfm_out.contains("&lt;title>"));
        assert!(gfm_out.contains("<strong>"));
    }

    #[test]
    fn highlight_colors_render_as_mark_with_data_color() {
        let opts = ParseOptions { highlight: true, highlight_colors: true, ..md() };
        assert_eq!(
            html_of("a ==\u{1F534} b== c\n", opts, RenderOptions::default()),
            "<p>a <mark data-color=\"red\">b</mark> c</p>\n"
        );
    }

    #[test]
    fn highlight_renders_as_mark_with_the_extension_on_literal_text_off() {
        let on = ParseOptions { highlight: true, ..md() };
        assert_eq!(html_of("a ==b== c\n", on, RenderOptions::default()), "<p>a <mark>b</mark> c</p>\n");
        assert_eq!(html_of("a ==b== c\n", md(), RenderOptions::default()), "<p>a ==b== c</p>\n");
    }

    #[test]
    fn renders_a_simple_paragraph_with_emphasis() {
        assert_eq!(html_of("hello *world*\n", md(), RenderOptions::default()), "<p>hello <em>world</em></p>\n");
    }

    #[test]
    fn a_top_level_block_quote_after_a_list_is_a_sibling_of_the_list() {
        assert_eq!(
            html_of("- item\n\n> quote\n", md(), RenderOptions::default()),
            "<ul>\n<li>item</li>\n</ul>\n<blockquote>\n<p>quote</p>\n</blockquote>\n"
        );
    }

    #[test]
    fn a_block_quote_indented_into_a_list_item_stays_inside_the_item() {
        assert_eq!(
            html_of("- item\n\n  > quote\n", md(), RenderOptions::default()),
            "<ul>\n<li>\n<p>item</p>\n<blockquote>\n<p>quote</p>\n</blockquote>\n</li>\n</ul>\n"
        );
    }

    #[test]
    fn footnote_reference_and_definition_render() {
        let html = html_of("text[^a] more\n\n[^a]: the note\n", ParseOptions { footnotes: true, ..md() }, RenderOptions::default());
        for needle in [
            "id=\"fnref1\"",
            "role=\"doc-noteref\"",
            "<sup>",
            "role=\"doc-endnotes\"",
            "id=\"fn1\"",
            "the note",
            "href=\"#fnref1\"",
        ] {
            assert!(html.contains(needle), "{needle} in {html}");
        }
    }

    #[test]
    fn footnote_forward_reference_still_resolves() {
        let html = html_of("see[^a]\n\n[^a]: later\n", ParseOptions { footnotes: true, ..md() }, RenderOptions::default());
        assert!(html.contains("id=\"fnref1\""));
        assert!(html.contains("later"));
    }

    #[test]
    fn footnotes_are_numbered_in_reference_order() {
        let html = html_of(
            "one[^b] two[^a]\n\n[^a]: A\n[^b]: B\n",
            ParseOptions { footnotes: true, ..md() },
            RenderOptions::default(),
        );
        assert!(html.contains("id=\"fnref1\""));
        assert!(html.contains("id=\"fnref2\""));
        let fn1 = html.find("id=\"fn1\"").unwrap();
        let fn2 = html.find("id=\"fn2\"").unwrap();
        assert!(fn1 < fn2);
        assert!(html[fn1..fn2].contains('B'));
    }

    #[test]
    fn footnotes_off_caret_label_is_an_ordinary_unresolved_link() {
        let html = html_of("see [^a]\n", ParseOptions { footnotes: false, ..md() }, RenderOptions::default());
        assert!(!html.contains("doc-endnotes"));
        assert!(!html.contains("doc-noteref"));
        assert!(html.contains("[^a]"));
    }

    #[test]
    fn footnotes_off_caret_definition_is_an_ordinary_link_reference() {
        let html = html_of("see[^a]\n\n[^a]: /note\n", ParseOptions { footnotes: false, ..md() }, RenderOptions::default());
        assert!(!html.contains("doc-endnotes"));
        assert!(!html.contains("doc-noteref"));
        assert!(html.contains("href=\"/note\""));
    }
}
