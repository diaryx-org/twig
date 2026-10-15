//! The shipped languages' formats, registered, for the CLI's own tests.

#![allow(dead_code)]

use twig::Format;

pub fn djot() -> Format {
    crate::format::register_languages();
    twig_djot::format()
}

pub fn markdown() -> Format {
    crate::format::register_languages();
    twig_markdown::format()
}

pub fn commonmark() -> Format {
    crate::format::register_languages();
    twig_markdown::commonmark()
}

pub fn gfm() -> Format {
    crate::format::register_languages();
    twig_markdown::gfm()
}

pub fn xml() -> Format {
    crate::format::register_languages();
    twig_xml::format()
}

pub fn svg() -> Format {
    crate::format::register_languages();
    twig_xml::svg()
}

pub fn html() -> Format {
    crate::format::register_languages();
    twig_html::format()
}

pub fn asciidoc() -> Format {
    crate::format::register_languages();
    twig_asciidoc::format()
}
