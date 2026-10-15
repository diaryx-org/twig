//! Document -> HTML renderer. Port of `djot/html.zig`: a THIN ADAPTER over
//! the shared, language-neutral printer at `languages::html::serializer`.
//!
//! Reference/footnote resolution is deferred entirely to render time: a
//! `link`/`image`'s `reference` label and a `footnote_reference`'s label are
//! resolved against `Document.labels`. The printer stays djot-agnostic by
//! taking those tables as an optional `Context`; this module's whole job is
//! handing it `&doc.labels`, plus the render-time `warn` hook.

use crate::document::Document;
use twig_kit::html::{self as html, Renderer};

#[derive(Clone, Copy, Debug, Default)]
pub struct RenderOptions {
    pub warn: Option<fn(&str)>,
}

/// The shared printer's error: only its `UnsafeMetadata` refusal (which a
/// djot parse cannot reach — it never produces `metadata` nodes).
pub type RenderError = html::RenderError;

/// Render `doc` (rooted at `doc.ast.root`) to HTML, appending to `out`.
pub fn render_into(doc: &Document, out: &mut Vec<u8>, options: &RenderOptions) -> Result<(), RenderError> {
    let opts = html::RenderOptions { warn: options.warn, ..html::RenderOptions::DEFAULT };
    let mut r = Renderer::new(&doc.ast, out, Some(&doc.labels), opts);
    r.render_node(doc.ast.root)
}

/// Render `doc` to an owned buffer (`renderAlloc` in Zig).
pub fn render(doc: &Document, options: &RenderOptions) -> Result<Vec<u8>, RenderError> {
    let mut out = Vec::new();
    render_into(doc, &mut out, options)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Attrs, Builder, KeyVal, Kind};

    fn r(src: &[u8]) -> String {
        String::from_utf8(render(&super::super::parse(src), &RenderOptions::default()).unwrap()).unwrap()
    }

    #[test]
    fn renders_a_simple_paragraph_with_emphasis() {
        assert_eq!(r(b"hello *world*\n"), "<p>hello <strong>world</strong></p>\n");
    }

    #[test]
    fn heading_renders_with_level_and_section_wrapper() {
        assert_eq!(r(b"# Hi\n"), "<section id=\"Hi\">\n<h1>Hi</h1>\n</section>\n");
    }

    #[test]
    fn tight_list_renders_without_p_wrappers() {
        assert_eq!(r(b"- a\n- b\n"), "<ul>\n<li>\na\n</li>\n<li>\nb\n</li>\n</ul>\n");
    }

    #[test]
    fn a_bare_attribute_renders_as_just_its_key() {
        let mut b = Builder::new();
        let text = b.add_leaf(Kind::Str(b"x".to_vec()));
        let para = b.add_container(Kind::Para, &[text]);
        b.set_attrs(para, Attrs { entries: vec![KeyVal::new(b"disabled", None), KeyVal::new(b"id", Some(b"y"))] });
        let doc = Document::from_ast(b"", b.finish(para));
        let html = render(&doc, &RenderOptions::default()).unwrap();
        assert_eq!(html, b"<p disabled id=\"y\">x</p>\n");
    }

    #[test]
    fn warn_fires_for_an_unresolved_reference() {
        use std::sync::atomic::{AtomicBool, Ordering};
        static FIRED: AtomicBool = AtomicBool::new(false);
        fn warn(_: &str) {
            FIRED.store(true, Ordering::SeqCst);
        }
        let doc = super::super::parse(b"[foo][bar]\n");
        let _ = render(&doc, &RenderOptions { warn: Some(warn) }).unwrap();
        assert!(FIRED.load(Ordering::SeqCst));
    }
}
