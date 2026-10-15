//! A declarative document-pruning pass, layered over `select` + `Splicer`.
//! Port of `src/ast/filter.zig`.
//!
//! Two selectors and a flag (`Options`):
//!   - `drop`  — the candidate FAMILY (e.g. `directive[name=vis]`);
//!   - `keep`  — exceptions spared despite matching `drop`; `None` drops the
//!               whole family;
//!   - `unwrap_kept` — after the drop pass, unwrap each surviving member.
//!
//! The splicer reparses after every edit, so ids are stale afterward: each
//! step re-resolves both selectors against the CURRENT tree, acts on ONE node,
//! and repeats. Every edit strictly shrinks the tree, so the loop is bounded.

use std::fmt;

use crate::ast::select::{self, Match};
use crate::ast::splicer::{self, Splicer};
use crate::ast::NodeId;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Options<'a> {
    /// The candidate family: a selector whose every match is a removal
    /// candidate.
    pub drop: &'a [u8],
    /// Exceptions kept despite matching `drop`.
    pub keep: Option<&'a [u8]>,
    /// After the drop pass, unwrap each KEPT family member. Only meaningful
    /// with `keep`.
    pub unwrap_kept: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// A selector does not parse.
    InvalidSelector,
    /// The bounded loop did not settle (a guard; never expected).
    FilterDidNotConverge,
    /// An edit failed (already rolled back); the progress so far stands.
    Edit(splicer::Error),
}

impl Error {
    /// The Zig error name (`@errorName`).
    pub fn name(&self) -> &str {
        match self {
            Error::InvalidSelector => "InvalidSelector",
            Error::FilterDidNotConverge => "FilterDidNotConverge",
            Error::Edit(e) => e.name(),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl From<splicer::Error> for Error {
    fn from(e: splicer::Error) -> Error {
        Error::Edit(e)
    }
}

/// Run the filter over `editor` in place. On success `editor.source_bytes()`
/// holds the pruned document.
pub fn apply(editor: &mut Splicer, options: &Options<'_>) -> Result<(), Error> {
    let drop_sel = select::parse(options.drop).map_err(|_| Error::InvalidSelector)?;
    let keep_sel = match options.keep {
        Some(k) => Some(select::parse(k).map_err(|_| Error::InvalidSelector)?),
        None => None,
    };

    let bound = editor.ast_view().nodes.len() + 8;

    // ── Phase 1: drop candidates not spared by `keep`. ──────────────────────
    let mut i = 0;
    loop {
        if i > bound {
            return Err(Error::FilterDidNotConverge);
        }
        i += 1;
        let drops = select::resolve_all(&editor.doc, &drop_sel);
        let target = match &keep_sel {
            Some(k) => {
                let keeps = select::resolve_all(&editor.doc, k);
                first_not_in(&drops, &keeps)
            }
            None => drops.first().map(|m| m.id),
        };
        let Some(t) = target else { break };
        editor.delete_node_smart_by_id(t)?;
    }

    // ── Phase 2: unwrap the survivors. ──────────────────────────────────────
    if options.unwrap_kept && keep_sel.is_some() {
        let mut j = 0;
        loop {
            if j > bound {
                return Err(Error::FilterDidNotConverge);
            }
            j += 1;
            let drops = select::resolve_all(&editor.doc, &drop_sel);
            let Some(first) = drops.first() else { break };
            editor.unwrap_node_by_id(first.id)?;
        }
    }
    Ok(())
}

/// The id of the first `candidates` match whose id appears in none of `set`.
fn first_not_in(candidates: &[Match], set: &[Match]) -> Option<NodeId> {
    candidates.iter().find(|c| !set.iter().any(|s| s.id == c.id)).map(|c| c.id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::languages::markdown::{self, ParseOptions};

    fn run_filter(src: &str, drop: &str, keep: Option<&str>, unwrap_kept: bool) -> String {
        let parse: splicer::ParseFn =
            Box::new(|s: &[u8]| Ok(markdown::parse(s, ParseOptions { directives: true, ..Default::default() })));
        let mut ed = Splicer::new(src.as_bytes(), parse).unwrap();
        let options = Options { drop: drop.as_bytes(), keep: keep.map(str::as_bytes), unwrap_kept };
        apply(&mut ed, &options).unwrap();
        String::from_utf8(ed.source_bytes().to_vec()).unwrap()
    }

    #[test]
    fn filter_drop_non_kept_family_members_keep_the_wrappers_intact() {
        let src = ":::vis{.public}\nA\n:::\n\n:::vis{.family}\nB\n:::\n\n:::vis{.public}\nC\n:::\n";
        let out = run_filter(src, "directive[name=vis]", Some("directive[class~=public]"), false);
        assert_eq!(out, ":::vis{.public}\nA\n:::\n\n:::vis{.public}\nC\n:::\n");
    }

    #[test]
    fn filter_unwrap_kept_peels_the_survivors_down_to_their_content() {
        let src = ":::vis{.public}\nA\n:::\n\n:::vis{.family}\nB\n:::\n";
        let out = run_filter(src, "directive[name=vis]", Some("directive[class~=public]"), true);
        assert_eq!(out, "A\n");
    }

    #[test]
    fn filter_no_keep_selector_drops_the_whole_family() {
        let src = "keep me\n\n:::vis{.public}\nA\n:::\n\ntail\n";
        assert_eq!(run_filter(src, "directive[name=vis]", None, false), "keep me\n\ntail\n");
    }

    #[test]
    fn filter_a_document_with_no_family_matches_is_unchanged() {
        let src = "# Just a heading\n\nA paragraph.\n";
        assert_eq!(run_filter(src, "directive[name=vis]", Some("directive[class~=public]"), false), src);
    }

    #[test]
    fn filter_keep_applies_per_audience() {
        let src = ":::vis{.public}\npublic only\n:::\n\n:::vis{.family}\nfamily only\n:::\n";
        let out = run_filter(src, "directive[name=vis]", Some("directive[class~=family]"), true);
        assert_eq!(out, "family only\n");
    }
}
