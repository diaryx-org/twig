//! Djot's surface spelling — the table `Editor`'s authoring gestures consult.
//! Port of `src/languages/djot/syntax.zig`. Every value here is a claim about
//! what the djot parser will read back and what its serializer emits.

use twig_kit::syntax::{
    AlignmentCells, AttrSpelling, BlockAttrs, CodeFence, ContainerSpelling, Delims, DestEscapes, FootnoteSpelling,
    Quoting, Syntax, TableSpelling, TaskMarker, TextRenderer,
};
use crate::ast::{Ast, NodeId};
use crate::Error;

/// Djot classifies an autolink on content alone, so this defers to the
/// parser's own scanner. `angled` arrives with its brackets.
fn spells_autolink(_: &Syntax, angled: &[u8]) -> bool {
    if angled.len() < 2 {
        return false;
    }
    crate::inline::autolink_kind_of(&angled[1..angled.len() - 1]).is_some()
}

/// The serializer over a fragment.
fn render_block(_: &Syntax, ast: &Ast, root: NodeId, out: &mut Vec<u8>) -> Result<(), Error> {
    out.extend_from_slice(&crate::serializer::serialize_ast(&twig_kit::syntax::fragment(ast, root)));
    Ok(())
}

/// Djot's table.
pub fn table() -> &'static Syntax {
    &TABLE
}

/// Djot spells every inline mark — which is why `InlineMark` has the variants
/// it does.
pub static TABLE: Syntax = Syntax {
    // Indexed by `InlineMark`: emph, strong, mark, superscript, subscript,
    // insert, delete, double_quoted, single_quoted. Djot's smart-quote
    // containers are produced by the PARSER from bare `"`/`'`, so an editor
    // toggling them would write the bytes the parser turns into curly quotes:
    // emit-only.
    inline_delims: [
        Some(Delims::new("_", "_")),
        Some(Delims::new("*", "*")),
        Some(Delims::new("{=", "=}")),
        Some(Delims::new("^", "^")),
        Some(Delims::new("~", "~")),
        Some(Delims::new("{+", "+}")),
        Some(Delims::new("{-", "-}")),
        Some(Delims::emit_only("\"", "\"")),
        Some(Delims::emit_only("'", "'")),
    ],
    // Indexed by `TextLeafKind`: symb, verbatim, inline_math, display_math,
    // url, email, footnote_reference, citation_reference,
    // substitution_reference. `$`code`` — the dollar sits OUTSIDE the verbatim
    // run, so a gesture prints a formula through the serializer rather than
    // from this pair. Djot has one footnote registry and no substitutions, so
    // the last two are `None`, not a borrowed `[^…]`.
    text_leaf_delims: [
        Some(Delims::emit_only(":", ":")),
        Some(Delims::new("`", "`")),
        Some(Delims::new("$`", "`")),
        Some(Delims::new("$$`", "`")),
        Some(Delims::emit_only("<", ">")),
        Some(Delims::emit_only("<", ">")),
        Some(Delims::emit_only("[^", "]")),
        None,
        None,
    ],
    container_spelling: [
        Some(ContainerSpelling::new("> ", "> ", ">")),
        Some(ContainerSpelling::new("- ", "  ", "")),
        Some(ContainerSpelling { marker: b"", cont: b"", blank: b"", numbered: true }),
    ],
    heading_marker: Some(b'#'),
    // A djot heading runs to the blank line, not the line end: `## a` + `b`
    // is one heading.
    heading_continues: true,
    // What the serializer emits; the canonical spelling a round-trip
    // reproduces.
    thematic_break: Some(b"* * *"),
    // Djot's info string runs to the end of the line and may hold spaces.
    code_fence: Some(CodeFence::new(b'`')),
    task_marker: Some(TaskMarker::new("[ ]", "[x]")),
    footnote: Some(FootnoteSpelling::new("[^", "]", ": ")),
    // The delimiter row carries NO padding (djot.js steps a single byte past
    // the `|` before matching the dashes, so `| --- |` is a data row there),
    // and an aligned cell REPLACES a dash, keeping every cell three wide.
    table_spelling: Some(TableSpelling {
        bar: b"|",
        pad: b" ",
        delim_pad: b"",
        delim: AlignmentCells::new("---", ":--", "--:", ":-:"),
    }),
    block_separator: Some(b"\n"),
    // Djot has no lazy continuation, so the container prefix `join_blocks`
    // writes after this is what keeps the joined line inside its container.
    line_join: Some(b"\n"),
    // `{#id .class key="val"}`. Djot quotes every value.
    attr_spelling: Some(AttrSpelling {
        open: b"{",
        close: b"}",
        quoting: Quoting::Always,
        id_sigil: Some(b"#"),
        class_sigil: Some(b"."),
        ..AttrSpelling::DEFAULT
    }),
    link_text_escapes: Some(b"\\[]*_^`~\"'-.:{}"),
    // No angle form: djot has no `<…>` destination spelling, so a space is
    // escaped in place.
    link_dest_escapes: Some(DestEscapes { plain: b"\\()[`", angle: None }),
    // Djot's inline metacharacters, plus `=`/`+` (the brace-inner delimiters
    // a `{…}` span keys on) and `<` (the autolink form).
    text_escapes: Some(b"\\[]*_^`~\"'-.:{}=+<"),
    // `#` heading, `>` quote, `|` table row.
    block_start_escapes: Some(b"#>|"),
    render_text: Some(TextRenderer::Alphabet),
    render_block: Some(render_block),
    spells_autolink: Some(spells_autolink),
    // A named leaf container round-trips as a CLASS: djot's fenced div is
    // anonymous, so `::: name` reads back as `class=name`.
    names_leaf_containers: true,
    block_attrs: Some(BlockAttrs::Native),
    inline_attrs: true,
    // `::: verse`, read as a line block by `ast/verse.rs`.
    line_blocks: true,
    // No `cell_line_break`: djot has no native in-cell hard break.
    ..Syntax::NONE
};

#[cfg(test)]
mod tests {
    use super::*;
    use twig_kit::syntax::{InlineKind, ALIGNMENTS};

    #[test]
    fn djot_spells_every_inline_kind() {
        for k in InlineKind::ALL {
            assert!(table().delims_for(&k.kind_ref()).is_some());
        }
        table().assert_coherent();
        assert!(table().authorable());
    }

    #[test]
    fn djots_delimiter_row_abuts_the_bar_unlike_markdowns() {
        let ts = table().table_spelling.unwrap();
        assert_eq!(ts.delim_pad, b"");
        assert_eq!(ts.pad, b" ");
        let want: [&[u8]; 4] = [b"---", b":--", b"--:", b":-:"];
        for (a, w) in ALIGNMENTS.iter().zip(want) {
            assert_eq!(ts.delim.get(*a), w);
        }
    }

    #[test]
    fn djot_has_no_in_cell_break_spelling() {
        assert!(table().cell_line_break.is_none());
    }

    #[test]
    fn djot_body_text_literals_extend_the_link_text_alphabet() {
        let te = table().text_escapes.unwrap();
        for c in table().link_text_escapes.unwrap() {
            assert!(te.contains(c));
        }
        for c in b"=+<" {
            assert!(te.contains(c));
        }
        let bse = table().block_start_escapes.unwrap();
        for c in b"#>|" {
            assert!(bse.contains(c));
        }
        for c in te {
            assert!(!bse.contains(c));
        }
    }

    #[test]
    fn djot_autolinks_by_content() {
        let none = twig_kit::syntax::none();
        assert!(spells_autolink(none, b"<https://x.dev>"));
        assert!(spells_autolink(none, b"<a@b.dev>"));
        assert!(spells_autolink(none, b"<mailto:a@b.dev>"));
        assert!(!spells_autolink(none, b"<foo/bar>"));
        assert!(!spells_autolink(none, b"<>"));
    }
}
