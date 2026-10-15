//! Locators: naming ONE node with a string, either way the CLI and the C ABI
//! both accept. Port of `src/ast/locator.zig`.
//!
//! A locator is an index path (`0.2.1`, or `""` for the root) or a selector
//! (`heading[level=2]`). The disambiguation is syntactic and total: a string
//! of only digits and dots is a path, anything else is a selector.

use crate::ast::{select, NodeId};
use crate::document::Document;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// Not a well-formed path and not a parseable selector.
    InvalidLocator,
    /// Resolved to no node: an out-of-bounds index path, or a selector with
    /// zero matches.
    NotFound,
    /// A selector matched more than one node.
    Ambiguous,
}

impl Error {
    /// The Zig error name (`@errorName`).
    pub fn name(self) -> &'static str {
        match self {
            Error::InvalidLocator => "InvalidLocator",
            Error::NotFound => "NotFound",
            Error::Ambiguous => "Ambiguous",
        }
    }
}

/// A locator is an index path when it's made only of digits and dots (so an
/// empty string — the root — counts); anything else is a selector.
pub fn is_index_path(s: &[u8]) -> bool {
    s.iter().all(|&c| c.is_ascii_digit() || c == b'.')
}

/// Parse a dotted index path.
pub fn parse_path(path_str: &[u8]) -> Result<Vec<usize>, Error> {
    if path_str.is_empty() {
        return Ok(Vec::new());
    }
    path_str.split(|&c| c == b'.').map(|seg| parse_segment(seg).ok_or(Error::InvalidLocator)).collect()
}

/// Zig's `parseInt(usize, seg, 10)` over a segment that holds only digits
/// (the caller split on `.`; `is_index_path` admits nothing else).
fn parse_segment(seg: &[u8]) -> Option<usize> {
    if seg.is_empty() {
        return None;
    }
    let mut n: usize = 0;
    for &c in seg {
        if !c.is_ascii_digit() {
            return None;
        }
        n = n.checked_mul(10)?.checked_add((c - b'0') as usize)?;
    }
    Some(n)
}

/// Resolve a locator (index path or unique selector) to a single node id.
pub fn resolve(doc: &Document, locator: &[u8]) -> Result<NodeId, Error> {
    if is_index_path(locator) {
        let path = parse_path(locator)?;
        return doc.ast.id_by_path(&path).map_err(|_| Error::NotFound);
    }
    let selector = select::parse(locator).map_err(|_| Error::InvalidLocator)?;
    let matches = select::resolve_all(doc, &selector);
    match matches.len() {
        0 => Err(Error::NotFound),
        1 => Ok(matches[0].id),
        _ => Err(Error::Ambiguous),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_path_selector_split_is_purely_syntactic() {
        assert!(is_index_path(b""));
        assert!(is_index_path(b"0"));
        assert!(is_index_path(b"0.2.1"));
        assert!(!is_index_path(b"heading"));
        assert!(!is_index_path(b"heading[level=2]"));
    }

    #[test]
    fn parse_path_splits_on_dots() {
        assert!(parse_path(b"").unwrap().is_empty());
        assert_eq!(parse_path(b"0.2.1").unwrap(), [0, 2, 1]);
        assert_eq!(parse_path(b"0..1"), Err(Error::InvalidLocator));
    }

    #[test]
    fn resolve_accepts_both_a_path_and_a_selector_and_reports_why_it_failed() {
        let doc = twig_xml::parse(b"<r><a>one</a><a>two</a></r>").unwrap();
        assert_eq!(resolve(&doc, b""), Ok(doc.ast.root));
        assert!(resolve(&doc, b"element[name=r]").is_ok());
        assert_eq!(resolve(&doc, b"element[name=a]"), Err(Error::Ambiguous));
        assert_eq!(resolve(&doc, b"element[name=zz]"), Err(Error::NotFound));
        assert_eq!(resolve(&doc, b"99"), Err(Error::NotFound));
        assert_eq!(resolve(&doc, b"!!"), Err(Error::InvalidLocator));
    }
}
