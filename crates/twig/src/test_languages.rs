//! The language crates, registered for the core's own tests: each returns
//! its format, registering the language the first time.

use crate::format::{register, Format};

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
