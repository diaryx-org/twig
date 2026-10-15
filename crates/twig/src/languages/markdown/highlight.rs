//! The colour vocabulary of `==🔴 text==` — Obsidian's coloured highlights
//! (`ParseOptions::highlight_colors`). Port of `highlight.zig`.
//!
//! A large-circle emoji immediately after the opening `==` names the
//! highlight's colour. The emoji is SPELLING: the parser strips it and
//! records the colour as a `data-color` attribute on the `mark` node. An
//! optional single space after the emoji is part of the prefix, and which
//! form was written is kept in `Spelling::HighlightPrefix`.
//!
//! The medium circles ⚫/⚪ are deliberately absent.

/// The attribute the colour rides in, on the `mark` node.
pub const ATTR_KEY: &str = "data-color";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Color {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Brown,
}

impl Color {
    pub const ALL: [Color; 7] =
        [Color::Red, Color::Orange, Color::Yellow, Color::Green, Color::Blue, Color::Purple, Color::Brown];

    /// The attribute value, and what `from_name` reads back.
    pub fn name(self) -> &'static str {
        match self {
            Color::Red => "red",
            Color::Orange => "orange",
            Color::Yellow => "yellow",
            Color::Green => "green",
            Color::Blue => "blue",
            Color::Purple => "purple",
            Color::Brown => "brown",
        }
    }

    /// The emoji that spells this colour — one code point, four UTF-8 bytes.
    pub fn emoji(self) -> &'static str {
        match self {
            Color::Red => "\u{1F534}",
            Color::Orange => "\u{1F7E0}",
            Color::Yellow => "\u{1F7E1}",
            Color::Green => "\u{1F7E2}",
            Color::Blue => "\u{1F535}",
            Color::Purple => "\u{1F7E3}",
            Color::Brown => "\u{1F7E4}",
        }
    }

    pub fn from_name(s: &[u8]) -> Option<Color> {
        Color::ALL.into_iter().find(|c| c.name().as_bytes() == s)
    }
}

/// A colour prefix read off the front of a highlight's content.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Prefix {
    pub color: Color,
    /// Whether a single space followed the emoji (and was absorbed).
    pub spaced: bool,
    /// Byte length of the whole prefix: the emoji plus the space, if any.
    pub len: usize,
}

/// Read a colour prefix at the very start of `s` — a large-circle emoji, then
/// at most one ASCII space.
pub fn parse_prefix(s: &[u8]) -> Option<Prefix> {
    for c in Color::ALL {
        let e = c.emoji().as_bytes();
        if s.starts_with(e) {
            let spaced = s.len() > e.len() && s[e.len()] == b' ';
            return Some(Prefix { color: c, spaced, len: e.len() + spaced as usize });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_prefix_reads_each_circle() {
        for c in Color::ALL {
            let tight = format!("{}x", c.emoji());
            let p = parse_prefix(tight.as_bytes()).unwrap();
            assert_eq!(p.color, c);
            assert!(!p.spaced);
            assert_eq!(p.len, c.emoji().len());
            let spaced = format!("{} x", c.emoji());
            let q = parse_prefix(spaced.as_bytes()).unwrap();
            assert_eq!(q.color, c);
            assert!(q.spaced);
            assert_eq!(q.len, c.emoji().len() + 1);
        }
    }

    #[test]
    fn parse_prefix_refuses_others() {
        assert!(parse_prefix("\u{1F34E} x".as_bytes()).is_none());
        assert!(parse_prefix(" \u{1F534}x".as_bytes()).is_none());
        assert!(parse_prefix("\u{26AB}x".as_bytes()).is_none());
        assert!(parse_prefix(b"x").is_none());
        assert!(parse_prefix(b"").is_none());
    }

    #[test]
    fn only_one_space_is_absorbed() {
        let p = parse_prefix("\u{1F534}  x".as_bytes()).unwrap();
        assert!(p.spaced);
        assert_eq!(p.len, 5);
    }

    #[test]
    fn names_round_trip() {
        for c in Color::ALL {
            assert_eq!(Color::from_name(c.name().as_bytes()), Some(c));
        }
        assert!(Color::from_name(b"pink").is_none());
    }
}
