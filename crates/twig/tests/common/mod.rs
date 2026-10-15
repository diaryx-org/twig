//! The language crates, registered for the integration tests: each returns
//! its format, registering the language the first time.

#![allow(dead_code)]



use twig::{register, Format};

pub fn djot() -> Format {
    register(twig_djot::Djot).unwrap()
}

pub fn markdown() -> Format {
    register(twig_markdown::Markdown).unwrap()
}

pub fn commonmark() -> Format {
    markdown();
    Format::by_name("commonmark").unwrap()
}

pub fn gfm() -> Format {
    markdown();
    Format::by_name("gfm").unwrap()
}

pub fn xml() -> Format {
    register(twig_xml::Xml).unwrap()
}

pub fn svg() -> Format {
    xml();
    Format::by_name("svg").unwrap()
}

pub fn html() -> Format {
    register(twig_html::Html).unwrap()
}

pub fn asciidoc() -> Format {
    register(twig_asciidoc::Asciidoc).unwrap()
}

/// Every language twig ships, registered; their formats in the order the
/// compiled registry had them.
pub fn all() -> [Format; 8] {
    [djot(), markdown(), commonmark(), gfm(), xml(), svg(), html(), asciidoc()]
}

/// Markdown's extensions as the feature flags its row reads.
pub fn flags(e: twig_markdown::Extensions) -> u32 {
    twig_markdown::language::mask_from_extensions(e)
}

/// An editor over `input` with Markdown's extensions `e` on.
pub fn new_ext(input: &[u8], format: Format, e: twig_markdown::Extensions) -> Result<twig::Editor, twig::Error> {
    twig::Editor::new_with_flags(input, format, flags(e))
}

/// A parse of `input` with Markdown's extensions `e` on.
pub fn parse_with(input: &[u8], format: Format, e: twig_markdown::Extensions) -> Result<twig::Document, twig::Error> {
    twig::Document::parse_with_flags(input, format, flags(e))
}

/// [`parse_with`] for a `&str`.
pub fn parse_str_with(input: &str, format: Format, e: twig_markdown::Extensions) -> Result<twig::Document, twig::Error> {
    parse_with(input.as_bytes(), format, e)
}
