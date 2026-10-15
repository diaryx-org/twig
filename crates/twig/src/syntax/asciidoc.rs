//! AsciiDoc's surface spelling — the table `Editor`'s authoring gestures
//! consult, and the one the AsciiDoc serializer reads its inline delimiters
//! from. Port of `src/languages/asciidoc/syntax.zig`.
//!
//! ── The doubled forms ──────────────────────────────────────────────────────
//! AsciiDoc spells every span twice: a CONSTRAINED form (`*bold*`) and an
//! UNCONSTRAINED one (`**bold**`) that works anywhere. A gesture wraps whatever
//! range the caret gave it, so the table holds the unconstrained forms; the
//! serializer derives the constrained spelling from the same entry.
//!
//! ── What stays None ────────────────────────────────────────────────────────
//! The link alphabets (AsciiDoc's link is `dest[text]`), `footnote` (one
//! macro, no definition line), `table_spelling` (`|===` fences, no delimiter
//! row) and `cell_line_break`: shapes the gesture algorithms cannot write.

use super::{BlockAttrs, CodeFence, ContainerSpelling, Delims, Syntax, TaskMarker, TextRenderer};
use crate::ast::{Ast, NodeId};
use crate::Error;

/// `<https://…>` autolinks in AsciiDoc when the interior is a URL of a scheme
/// the parser knows; a bare word in angle brackets is text.
fn spells_autolink(_: &Syntax, angled: &[u8]) -> bool {
    if angled.len() < 3 || angled[0] != b'<' || angled[angled.len() - 1] != b'>' {
        return false;
    }
    let inner = &angled[1..angled.len() - 1];
    if inner.iter().any(|c| b" \t\n<>".contains(c)) {
        return false;
    }
    for scheme in [&b"https://"[..], b"http://", b"ftp://", b"irc://", b"file://"] {
        if inner.starts_with(scheme) && inner.len() > scheme.len() {
            return true;
        }
    }
    false
}

/// The serializer over a fragment.
fn render_block(_: &Syntax, ast: &Ast, root: NodeId, out: &mut Vec<u8>) -> Result<(), Error> {
    // TODO(port): `crate::languages::asciidoc` serializer's `serialize_ast`
    // over `super::fragment(ast, root)` once it lands.
    let _ = (ast, root, out);
    Err(Error::Internal)
}

pub static TABLE: Syntax = Syntax {
    // emph, strong, mark, superscript, subscript, insert, delete,
    // double_quoted, single_quoted. No insert/delete marks: Asciidoctor's
    // convention is a role, read back as a styled span. The curved quotes are
    // emit-only: they reparse as a quoted CONTAINER.
    inline_delims: [
        Some(Delims::new("__", "__")),
        Some(Delims::new("**", "**")),
        Some(Delims::new("##", "##")),
        Some(Delims::new("^", "^")),
        Some(Delims::new("~", "~")),
        Some(Delims::emit_only("[.underline]#", "#")),
        Some(Delims::emit_only("[.line-through]#", "#")),
        Some(Delims::emit_only("\"`", "`\"")),
        Some(Delims::emit_only("'`", "`'")),
    ],
    // symb, verbatim, inline_math, display_math, url, email,
    // footnote_reference, citation_reference, substitution_reference.
    // `stem:[…]` reads back as INLINE math, so the display form is emit-only.
    text_leaf_delims: [
        None,
        Some(Delims::new("``", "``")),
        Some(Delims::new("stem:[", "]")),
        Some(Delims::emit_only("stem:[", "]")),
        None,
        None,
        Some(Delims::emit_only("footnote:", "[]")),
        Some(Delims::emit_only("<<", ">>")),
        Some(Delims::emit_only("{", "}")),
    ],
    container_spelling: [
        Some(ContainerSpelling::new("> ", "> ", ">")),
        // A blank line between items keeps them in one list.
        Some(ContainerSpelling::new("* ", "  ", "")),
        Some(ContainerSpelling { marker: b"", cont: b"  ", blank: b"", numbered: true }),
    ],
    heading_marker: Some(b'='),
    thematic_break: Some(b"'''"),
    code_fence: Some(CodeFence { char: b'`', min: 3, info_forbids: b" \t" }),
    task_marker: Some(TaskMarker::new("[ ]", "[x]")),
    block_separator: Some(b"\n"),
    line_join: Some(b"\n"),
    // A block in a list item's tail is attached by a `+` line, because an
    // indented line after a blank is a literal paragraph here.
    list_attach: Some(b"+"),
    text_escapes: Some(b"\\*_`#^~+{[<&"),
    block_start_escapes: Some(b"=.>|/':-"),
    render_text: Some(TextRenderer::Alphabet),
    render_block: Some(render_block),
    spells_autolink: Some(spells_autolink),
    // A named leaf container survives as a STYLE (or its native form).
    names_leaf_containers: true,
    block_attrs: Some(BlockAttrs::Native),
    // `[verse]` over a `____` block is AsciiDoc's own line block.
    line_blocks: true,
    ..Syntax::NONE
};

pub fn table() -> &'static Syntax {
    &TABLE
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{InlineMark, TextLeafKind};
    use crate::syntax::ContainerKind;

    #[test]
    fn asciidoc_spells_every_mark_and_authors_the_five_that_reparse_anywhere() {
        let authorable = [
            InlineMark::Strong,
            InlineMark::Emph,
            InlineMark::Mark,
            InlineMark::Superscript,
            InlineMark::Subscript,
        ];
        for m in InlineMark::ALL {
            let d = TABLE.inline_delim(m).unwrap();
            assert_eq!(authorable.contains(&m), d.authorable);
        }
        assert!(TABLE.text_leaf_delim(TextLeafKind::Verbatim).unwrap().authorable);
        assert!(TABLE.text_leaf_delim(TextLeafKind::InlineMath).unwrap().authorable);
        assert!(!TABLE.text_leaf_delim(TextLeafKind::DisplayMath).unwrap().authorable);
        TABLE.assert_coherent();
        assert!(TABLE.authorable());
    }

    #[test]
    fn the_authorable_delimiters_are_the_unconstrained_forms() {
        for d in [&b"**"[..], b"__", b"##"] {
            assert!(TABLE.inline_delims.iter().flatten().any(|x| x.open == d));
        }
        assert_eq!(TABLE.text_leaf_delim(TextLeafKind::Verbatim).unwrap().open, b"``");
    }

    #[test]
    fn the_escape_alphabets_are_disjoint() {
        // TODO(port): the Zig test also parses `\X` for every byte with the
        // AsciiDoc inline parser; add once `languages::asciidoc` lands.
        let te = TABLE.text_escapes.unwrap();
        let bse = TABLE.block_start_escapes.unwrap();
        for c in te {
            assert!(!bse.contains(c));
        }
        TABLE.assert_coherent();
    }

    #[test]
    fn asciidoc_autolinks_a_url_in_angle_brackets_and_nothing_else() {
        let none = crate::syntax::none();
        assert!(spells_autolink(none, b"<https://x.dev>"));
        assert!(!spells_autolink(none, b"<foo>"));
        assert!(!spells_autolink(none, b"<https://x.dev y>"));
        assert!(!spells_autolink(none, b"<a@b.dev>"));
    }

    #[test]
    fn the_shapes_the_gesture_algorithms_cannot_write_stay_none() {
        assert!(TABLE.link_text_escapes.is_none());
        assert!(TABLE.link_dest_escapes.is_none());
        assert!(TABLE.footnote.is_none());
        assert!(TABLE.table_spelling.is_none());
        assert!(TABLE.cell_line_break.is_none());
        assert!(TABLE.attr_spelling.is_none());
        assert_eq!(TABLE.heading_marker, Some(b'='));
        assert!(TABLE.container(ContainerKind::BlockQuote).is_some());
        assert!(TABLE.container(ContainerKind::OrderedList).unwrap().numbered);
        assert!(TABLE.task_marker.is_some());
        assert!(TABLE.code_fence.is_some());
    }
}
