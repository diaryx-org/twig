//! The two format axes: [`Format`] (what Twig can PARSE) and [`Target`] (what
//! it can WRITE), and the registry tying each to its parser and printers.
//! Port of `src/format.zig` — see `docs/DESIGN.md`'s "two format axes".

use crate::languages::markdown::options::Extensions;
use crate::runtime;

/// Every format Twig can parse. A dialect (`Commonmark`, `Gfm`, `Svg`) is a
/// format of its own over its language's parser. `Runtime` is a language
/// registered at run time, by its wire code (`runtime::BASE` and up).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Format {
    Djot,
    Markdown,
    Xml,
    Html,
    Asciidoc,
    Commonmark,
    Gfm,
    Svg,
    Runtime(u16),
}

/// Every place output bytes can go.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Target {
    Djot,
    Markdown,
    Xml,
    Html,
    Asciidoc,
    Runtime(u16),
}

impl Format {
    /// The compiled formats, in registry order.
    pub const COMPILED: [Format; 8] = [
        Format::Djot,
        Format::Markdown,
        Format::Commonmark,
        Format::Gfm,
        Format::Xml,
        Format::Svg,
        Format::Html,
        Format::Asciidoc,
    ];

    /// The C wire code (`TWIG_FORMAT_*`): the Zig enum's backing value.
    pub fn code(self) -> u16 {
        match self {
            Format::Djot => 0,
            Format::Markdown => 1,
            Format::Xml => 2,
            Format::Html => 3,
            Format::Asciidoc => 4,
            Format::Commonmark => 5,
            Format::Gfm => 6,
            Format::Svg => 7,
            Format::Runtime(c) => c,
        }
    }

    pub fn from_code(code: i64) -> Option<Format> {
        Some(match code {
            0 => Format::Djot,
            1 => Format::Markdown,
            2 => Format::Xml,
            3 => Format::Html,
            4 => Format::Asciidoc,
            5 => Format::Commonmark,
            6 => Format::Gfm,
            7 => Format::Svg,
            _ => return runtime::format_from_code(code),
        })
    }

    pub fn name(self) -> String {
        match self {
            Format::Runtime(c) => runtime::name_of(c),
            f => f.static_name().to_string(),
        }
    }

    /// The name of a compiled format (`""` for a runtime one).
    pub fn static_name(self) -> &'static str {
        match self {
            Format::Djot => "djot",
            Format::Markdown => "markdown",
            Format::Xml => "xml",
            Format::Html => "html",
            Format::Asciidoc => "asciidoc",
            Format::Commonmark => "commonmark",
            Format::Gfm => "gfm",
            Format::Svg => "svg",
            Format::Runtime(_) => "",
        }
    }

    pub fn is_runtime(self) -> bool {
        matches!(self, Format::Runtime(_))
    }

    /// The format whose dialect this is, if any.
    pub fn dialect_of(self) -> Option<Format> {
        match self {
            Format::Commonmark | Format::Gfm => Some(Format::Markdown),
            Format::Svg => Some(Format::Xml),
            Format::Runtime(c) => runtime::dialect_of(c),
            _ => None,
        }
    }

    pub fn extensions(self) -> &'static [&'static str] {
        match self {
            Format::Djot => &["dj", "djot"],
            Format::Markdown => &["md", "markdown"],
            Format::Xml => &["xml"],
            Format::Svg => &["svg"],
            Format::Html => &["html", "htm"],
            Format::Asciidoc => &["adoc", "asciidoc"],
            _ => &[],
        }
    }

    pub fn aliases(self) -> &'static [&'static str] {
        match self {
            Format::Djot => &["dj"],
            Format::Markdown => &["md"],
            Format::Asciidoc => &["adoc"],
            _ => &[],
        }
    }

    pub fn is_markdown_row(self) -> bool {
        matches!(self, Format::Markdown | Format::Gfm | Format::Commonmark)
    }
}

impl Target {
    pub const COMPILED: [Target; 5] = [Target::Djot, Target::Markdown, Target::Xml, Target::Html, Target::Asciidoc];

    pub fn code(self) -> u16 {
        match self {
            Target::Djot => 0,
            Target::Markdown => 1,
            Target::Xml => 2,
            Target::Html => 3,
            Target::Asciidoc => 4,
            Target::Runtime(c) => c,
        }
    }

    pub fn name(self) -> String {
        match self {
            Target::Runtime(c) => runtime::name_of(c),
            t => t.static_name().to_string(),
        }
    }

    pub fn static_name(self) -> &'static str {
        match self {
            Target::Djot => "djot",
            Target::Markdown => "markdown",
            Target::Xml => "xml",
            Target::Html => "html",
            Target::Asciidoc => "asciidoc",
            Target::Runtime(_) => "",
        }
    }

    /// The format this target's bytes parse back as, if any.
    pub fn as_format(self) -> Option<Format> {
        match self {
            Target::Djot => Some(Format::Djot),
            Target::Markdown => Some(Format::Markdown),
            Target::Xml => Some(Format::Xml),
            Target::Html => Some(Format::Html),
            Target::Asciidoc => Some(Format::Asciidoc),
            Target::Runtime(c) => runtime::reads_back_as(c),
        }
    }
}

impl From<Format> for Target {
    fn from(f: Format) -> Target {
        target_for(f)
    }
}

pub fn target_for(fmt: Format) -> Target {
    match fmt {
        Format::Commonmark | Format::Gfm | Format::Markdown => Target::Markdown,
        Format::Svg | Format::Xml => Target::Xml,
        Format::Djot => Target::Djot,
        Format::Html => Target::Html,
        Format::Asciidoc => Target::Asciidoc,
        Format::Runtime(c) => Target::Runtime(runtime::target_code_of(c)),
    }
}

pub fn writes_own_syntax(fmt: Format, target: Target) -> bool {
    target_for(fmt) == target
}

/// Whether `target` can be written from a bare tree (its `serializeFromAst`
/// slot). XML's printer needs the `Document` it parsed, so it cannot.
pub fn target_serializes_from_ast(target: Target) -> bool {
    match target {
        Target::Xml => false,
        Target::Runtime(c) => runtime::prints(c),
        _ => true,
    }
}

// ── Features ────────────────────────────────────────────────────────────────

/// A named switch a row's parser reads. Markdown's are its extensions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Feature {
    pub name: String,
    pub requires: Vec<String>,
}

/// Markdown's extensions as features, in `TWIG_MD_*` (field) order.
pub const MARKDOWN_FEATURE_NAMES: [&str; 5] = ["directives", "math", "html_elements", "highlight", "highlight_colors"];

pub fn markdown_features() -> Vec<Feature> {
    MARKDOWN_FEATURE_NAMES
        .iter()
        .map(|n| Feature {
            name: n.to_string(),
            requires: if *n == "highlight_colors" { vec!["highlight".to_string()] } else { vec![] },
        })
        .collect()
}

pub fn features(fmt: Format) -> Vec<Feature> {
    if fmt.is_markdown_row() {
        return markdown_features();
    }
    runtime::features_of(fmt)
}

pub fn feature_bit(fmt: Format, name: &str) -> Option<u32> {
    features(fmt).iter().position(|f| f.name == name).map(|i| 1u32 << i)
}

/// `mask` restricted to the declared features and closed under `requires`.
pub fn close_features(fmt: Format, mask: u32) -> u32 {
    let fs = features(fmt);
    let declared: u32 = if fs.len() >= 32 { !0 } else { (1u32 << fs.len()) - 1 };
    let mut out = mask & declared;
    loop {
        let mut grown = out;
        for (i, f) in fs.iter().enumerate() {
            if out & (1 << i) == 0 {
                continue;
            }
            for r in &f.requires {
                grown |= feature_bit(fmt, r).unwrap_or(0);
            }
        }
        if grown == out {
            return out;
        }
        out = grown;
    }
}

/// What a caller lays over the row it chose: Markdown's opt-in extensions, or
/// a runtime row's feature mask.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct ParseConfig {
    pub markdown: Extensions,
    pub features: u32,
}

impl ParseConfig {
    pub fn for_features(fmt: Format, mask: u32) -> ParseConfig {
        if !fmt.is_markdown_row() {
            return ParseConfig { features: mask, ..Default::default() };
        }
        let closed = close_features(fmt, mask);
        let bit = |i: u32| closed & (1 << i) != 0;
        ParseConfig {
            markdown: Extensions {
                directives: bit(0),
                math: bit(1),
                html_elements: bit(2),
                highlight: bit(3),
                highlight_colors: bit(4),
            },
            features: 0,
        }
    }

    /// The Markdown extensions as a `TWIG_MD_*` flag mask.
    pub fn markdown_mask(&self) -> u32 {
        let e = self.markdown;
        (e.directives as u32) | (e.math as u32) << 1 | (e.html_elements as u32) << 2 | (e.highlight as u32) << 3
            | (e.highlight_colors as u32) << 4
    }
}

// ── Names ───────────────────────────────────────────────────────────────────

/// An input name to a `Format`: its own name, then an alias, then a runtime
/// language's name.
pub fn parse_format_name(name: &str) -> Option<Format> {
    for f in Format::COMPILED {
        if f.static_name() == name {
            return Some(f);
        }
    }
    for f in Format::COMPILED {
        if f.aliases().contains(&name) {
            return Some(f);
        }
    }
    runtime::by_name(name)
}

pub fn parse_target_name(name: &str) -> Option<Target> {
    for t in Target::COMPILED {
        if t.static_name() == name {
            return Some(t);
        }
    }
    parse_format_name(name).map(target_for)
}

pub fn detect_from_extension(file_path: &str) -> Option<Format> {
    let dot = file_path.rfind('.')?;
    let ext = &file_path[dot + 1..];
    if ext.is_empty() {
        return None;
    }
    for f in Format::COMPILED {
        if f.extensions().iter().any(|k| k.eq_ignore_ascii_case(ext)) {
            return Some(f);
        }
    }
    runtime::by_extension(ext)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_extensions_are_features_in_flag_order() {
        for row in [Format::Markdown, Format::Gfm, Format::Commonmark] {
            assert_eq!(feature_bit(row, "math"), Some(1 << 1));
            assert_eq!(feature_bit(row, "highlight_colors"), Some(1 << 4));
        }
        assert_eq!(feature_bit(Format::Markdown, "tables"), None);
        assert!(features(Format::Djot).is_empty());
        let colors = feature_bit(Format::Markdown, "highlight_colors").unwrap();
        assert_eq!(close_features(Format::Markdown, colors), colors | feature_bit(Format::Markdown, "highlight").unwrap());
        let cfg = ParseConfig::for_features(Format::Gfm, colors | feature_bit(Format::Gfm, "math").unwrap());
        assert!(cfg.markdown.highlight && cfg.markdown.highlight_colors && cfg.markdown.math);
        assert!(!cfg.markdown.directives && !cfg.markdown.html_elements);
        assert_eq!(close_features(Format::Djot, 0b111), 0);
    }

    #[test]
    fn names_and_extensions_resolve() {
        assert_eq!(parse_format_name("dj"), Some(Format::Djot));
        assert_eq!(parse_format_name("markdown"), Some(Format::Markdown));
        assert_eq!(parse_format_name("gfm"), Some(Format::Gfm));
        assert_eq!(parse_format_name("adoc"), Some(Format::Asciidoc));
        assert_eq!(parse_format_name("nope"), None);
        assert_eq!(detect_from_extension("a/b.MD"), Some(Format::Markdown));
        assert_eq!(detect_from_extension("guide.ADOC"), Some(Format::Asciidoc));
        assert_eq!(detect_from_extension("drawing.svg"), Some(Format::Svg));
        assert_eq!(detect_from_extension("noext"), None);
        assert_eq!(parse_target_name("gfm"), Some(Target::Markdown));
        assert_eq!(parse_target_name("svg"), Some(Target::Xml));
        assert_eq!(parse_target_name("dj"), Some(Target::Djot));
        assert_eq!(parse_target_name("nope"), None);
    }

    #[test]
    fn every_format_is_a_target_and_they_agree() {
        for f in Format::COMPILED {
            let t = target_for(f);
            let lang = f.dialect_of().unwrap_or(f);
            assert_eq!(lang.static_name(), t.static_name());
            assert_eq!(t.as_format(), Some(lang));
            assert!(writes_own_syntax(f, t));
        }
    }
}
