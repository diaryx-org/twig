//! Markdown's surface spelling — the table set `Editor`'s authoring gestures
//! consult. Port of `src/languages/markdown/syntax.zig`.
//!
//! Markdown's authorable subset is not a property of the format: `~~x~~` reads
//! back as a `delete` under `ParseOptions::strikethrough` and as literal tildes
//! without it, `==x==` as a `mark` under `highlight` and as text without it. A
//! gesture may only mint bytes the editor's own reparse reads back the same
//! way, so the answer comes from the parse config: [`for_options`] picks one
//! table per relevant flag combination, each DERIVED from [`BASE`].

use std::sync::LazyLock;

use twig_kit::syntax::{
    AlignmentCells, AngleEscapes, AttrSpelling, BlockAttrs, CodeFence, ContainerSpelling, Delims, DestEscapes,
    FootnoteSpelling, MarkColor, MarkColors, Quoting, Syntax, TableSpelling, TaskMarker, TextRenderer,
};
use crate::ast::{Ast, InlineMark, NodeId, TextLeafKind};
use crate::highlight;
use crate::ParseOptions;
use crate::Error;

/// Defers to the parser's own autolink scanner: Markdown wants an absolute URI
/// or a CommonMark email and silently reads anything else as RAW HTML.
fn spells_autolink(_: &Syntax, angled: &[u8]) -> bool {
    crate::spells_autolink(angled)
}

/// The serializer over a fragment.
fn render_block(_: &Syntax, ast: &Ast, root: NodeId, out: &mut Vec<u8>) -> Result<(), Error> {
    out.extend_from_slice(&crate::serializer::serialize_ast(&twig_kit::syntax::fragment(ast, root)));
    Ok(())
}

/// Every spelling Markdown has, independent of the parse config: what the
/// serializer emits, every escape alphabet, and the authorable flags for what
/// means the same thing under any options. The EXTENSION-gated answers are
/// left at their pessimistic value here and set by `derive`.
pub static BASE: Syntax = Syntax {
    // emph, strong, mark, superscript, subscript, insert, delete,
    // double_quoted, single_quoted. Only `strong`/`emph` are unconditionally
    // AUTHORABLE; `==`/`~~`/`<u>` move with the config (see `derive`), and the
    // rest are emit-only spellings for converting djot down to Markdown.
    inline_delims: [
        Some(Delims::new("*", "*")),
        Some(Delims::new("**", "**")),
        Some(Delims::emit_only("==", "==")),
        Some(Delims::emit_only("^", "^")),
        Some(Delims::emit_only("~", "~")),
        Some(Delims::emit_only("<u>", "</u>")),
        Some(Delims::emit_only("~~", "~~")),
        Some(Delims::emit_only("\"", "\"")),
        Some(Delims::emit_only("'", "'")),
    ],
    // symb, verbatim, inline_math, display_math, url, email,
    // footnote_reference, citation_reference, substitution_reference. The
    // formulas read back only under `ParseOptions::math`.
    text_leaf_delims: [
        Some(Delims::emit_only(":", ":")),
        Some(Delims::new("`", "`")),
        Some(Delims::emit_only("$", "$")),
        Some(Delims::emit_only("$$", "$$")),
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
    // An ATX heading is one line, so `heading_continues` stays false.
    heading_marker: Some(b'#'),
    // `---` is only a break after a blank line, which is why
    // `insert_thematic_break` blank-separates.
    thematic_break: Some(b"---"),
    // Backticks, not tildes; an info string ends at whitespace.
    code_fence: Some(CodeFence { char: b'`', min: 3, info_forbids: b" \t" }),
    task_marker: Some(TaskMarker::new("[ ]", "[x]")),
    footnote: Some(FootnoteSpelling::new("[^", "]", ": ")),
    // GFM pipe tables, padded on both sides of every cell, the delimiter row
    // included; the aligned forms ADD their colon to the three-dash run.
    table_spelling: Some(TableSpelling {
        bar: b"|",
        pad: b" ",
        delim_pad: b" ",
        delim: AlignmentCells::new("---", ":---", "---:", ":---:"),
    }),
    block_separator: Some(b"\n"),
    line_join: Some(b"\n"),
    // A generic directive's `{#id .class key=val}` shorthand: a value is left
    // bare when the attribute grammar can read it back, quoted otherwise.
    attr_spelling: Some(AttrSpelling {
        open: b"{",
        close: b"}",
        quoting: Quoting::WhenNeeded,
        quote_escapes: b"\"\\",
        id_sigil: Some(b"#"),
        class_sigil: Some(b"."),
        ..AttrSpelling::DEFAULT
    }),
    // `<` and `&` where djot has `{`/`}` and smart punctuation.
    link_text_escapes: Some(LINK_TEXT_ESCAPES),
    link_dest_escapes: Some(DestEscapes { plain: b"\\()<&", angle: Some(AngleEscapes { escapes: b"\\<>&" }) }),
    text_escapes: Some(TEXT_ESCAPES),
    // `#` heading, `>` quote, `-`/`+` bullets, `=` a setext underline.
    block_start_escapes: Some(b"#>-+="),
    render_text: Some(TextRenderer::Alphabet),
    render_block: Some(render_block),
    spells_autolink: Some(spells_autolink),
    // GFM's only in-cell break.
    cell_line_break: Some(b"<br>"),
    ..Syntax::NONE
};

const LINK_TEXT_ESCAPES: &[u8] = b"\\[]*_^`~<>&";
const LINK_TEXT_ESCAPES_MATH: &[u8] = b"\\[]*_^`~<>&$";
const TEXT_ESCAPES: &[u8] = b"\\*_`[]~<&";
const TEXT_ESCAPES_MATH: &[u8] = b"\\*_`[]~<&$";

/// Every colour `highlight.rs` knows, as an editor's palette.
static COLOR_SPELLINGS: LazyLock<Vec<MarkColor>> = LazyLock::new(|| {
    highlight::Color::ALL
        .iter()
        .map(|c| MarkColor { name: c.name().as_bytes(), prefix: c.emoji().as_bytes() })
        .collect()
});

/// How far the highlight extensions reach — one ordered axis, since a colour
/// is inert without a highlight to colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Highlights {
    None,
    Marks,
    Colors,
}

/// The flags that move an ANSWER, as one key — the address of a table in the
/// set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Key {
    strikethrough: bool,
    highlights: Highlights,
    directives: bool,
    html_elements: bool,
    math: bool,
    tables: bool,
    task_lists: bool,
    footnotes: bool,
}

impl Key {
    const COUNT: usize = 2 * 3 * 2 * 2 * 2 * 2 * 2 * 2;

    fn index(self) -> usize {
        let mut i = self.strikethrough as usize;
        i = i * 3 + self.highlights as usize;
        i = i * 2 + self.directives as usize;
        i = i * 2 + self.html_elements as usize;
        i = i * 2 + self.math as usize;
        i = i * 2 + self.tables as usize;
        i = i * 2 + self.task_lists as usize;
        i = i * 2 + self.footnotes as usize;
        i
    }

    fn from_index(i: usize) -> Key {
        let mut rest = i;
        let footnotes = rest % 2 == 1;
        rest /= 2;
        let task_lists = rest % 2 == 1;
        rest /= 2;
        let tables = rest % 2 == 1;
        rest /= 2;
        let math = rest % 2 == 1;
        rest /= 2;
        let html_elements = rest % 2 == 1;
        rest /= 2;
        let directives = rest % 2 == 1;
        rest /= 2;
        let highlights = match rest % 3 {
            0 => Highlights::None,
            1 => Highlights::Marks,
            _ => Highlights::Colors,
        };
        rest /= 3;
        Key { strikethrough: rest == 1, highlights, directives, html_elements, math, tables, task_lists, footnotes }
    }

    fn of(opts: &ParseOptions) -> Key {
        // Colours are inert without a highlight to colour, as in the parser.
        let highlights = if !opts.highlight {
            Highlights::None
        } else if opts.highlight_colors {
            Highlights::Colors
        } else {
            Highlights::Marks
        };
        Key {
            strikethrough: opts.strikethrough,
            highlights,
            directives: opts.directives,
            html_elements: opts.html_elements,
            math: opts.math,
            tables: opts.tables,
            task_lists: opts.task_lists,
            footnotes: opts.footnotes,
        }
    }
}

/// `BASE` with the extension-gated answers filled in.
fn derive(k: Key) -> Syntax {
    let mut t = BASE;
    set_authorable(&mut t, InlineMark::Delete, k.strikethrough);
    set_authorable(&mut t, InlineMark::Mark, k.highlights != Highlights::None);
    set_authorable(&mut t, InlineMark::Insert, k.html_elements);
    if k.highlights == Highlights::Colors {
        t.mark_colors =
            Some(MarkColors { attr_key: highlight::ATTR_KEY.as_bytes(), colors: COLOR_SPELLINGS.as_slice(), space: b" " });
    }
    // `::name[label]{attrs}` reads back as a container only under directives.
    t.names_leaf_containers = k.directives;
    // An attributed block is written inside a `<div>` and an attributed run
    // inside a `<span>`; only `html_elements` pairs the tags back.
    t.block_attrs = if k.html_elements { Some(BlockAttrs::Wrapped) } else { None };
    t.inline_attrs = k.html_elements;
    t.line_blocks = k.html_elements;
    if !k.tables {
        t.table_spelling = None;
    }
    if !k.task_lists {
        t.task_marker = None;
    }
    if !k.footnotes {
        t.footnote = None;
    }
    set_leaf_authorable(&mut t, TextLeafKind::InlineMath, k.math);
    set_leaf_authorable(&mut t, TextLeafKind::DisplayMath, k.math);
    if k.math {
        t.text_escapes = Some(TEXT_ESCAPES_MATH);
        t.link_text_escapes = Some(LINK_TEXT_ESCAPES_MATH);
    }
    t
}

fn set_authorable(t: &mut Syntax, m: InlineMark, yes: bool) {
    if let Some(d) = &mut t.inline_delims[m as usize] {
        d.authorable = yes;
    }
}

fn set_leaf_authorable(t: &mut Syntax, k: TextLeafKind, yes: bool) {
    if let Some(d) = &mut t.text_leaf_delims[k as usize] {
        d.authorable = yes;
    }
}

/// Every table Markdown is authored by, one per `Key`.
static TABLES: LazyLock<Vec<Syntax>> = LazyLock::new(|| {
    (0..Key::COUNT)
        .map(|i| {
            let t = derive(Key::from_index(i));
            t.assert_coherent();
            t
        })
        .collect()
});

/// The table for DEFAULT parse options: what the registry row points at and
/// what the serializer reads. The same address `for_options(&default)` gives.
pub fn table() -> &'static Syntax {
    for_options(&ParseOptions::default())
}

/// Every table in the set, for a check that has to hold each of them.
pub fn every() -> &'static [Syntax] {
    &TABLES
}

/// The table an editor over a document parsed with `opts` should consult.
pub fn for_options(opts: &ParseOptions) -> &'static Syntax {
    &TABLES[Key::of(opts).index()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use twig_kit::syntax::ALIGNMENTS;

    fn opts() -> ParseOptions {
        ParseOptions::default()
    }

    #[test]
    fn markdown_spells_every_mark_and_authors_the_ones_its_parse_config_reads_back() {
        for m in InlineMark::ALL {
            assert!(table().inline_delim(m).is_some());
        }
        let default_marks = [InlineMark::Strong, InlineMark::Emph, InlineMark::Delete];
        for m in InlineMark::ALL {
            assert_eq!(default_marks.contains(&m), table().inline_delim(m).unwrap().authorable);
        }
        let strict = for_options(&ParseOptions::COMMONMARK);
        let strict_marks = [InlineMark::Strong, InlineMark::Emph];
        for m in InlineMark::ALL {
            assert_eq!(strict_marks.contains(&m), strict.inline_delim(m).unwrap().authorable);
        }
        assert!(table().text_leaf_delim(TextLeafKind::Verbatim).unwrap().authorable);
        assert!(!table().text_leaf_delim(TextLeafKind::Url).unwrap().authorable);
        table().assert_coherent();
        assert!(table().authorable());
    }

    #[test]
    fn every_derived_table_differs_from_base_in_the_authorable_flags_and_nothing_else() {
        for (i, t) in every().iter().enumerate() {
            t.assert_coherent();
            for m in InlineMark::ALL {
                let b = BASE.inline_delim(m).unwrap();
                let d = t.inline_delim(m).unwrap();
                assert_eq!(b.open, d.open);
                assert_eq!(b.close, d.close);
                if m != InlineMark::Mark && m != InlineMark::Delete && m != InlineMark::Insert {
                    assert_eq!(b.authorable, d.authorable);
                }
            }
            assert_eq!(BASE.heading_marker, t.heading_marker);
            let k = Key::from_index(i);
            assert_eq!(k.html_elements, t.inline_delim(InlineMark::Insert).unwrap().authorable);
            let te: &[u8] = if k.math { TEXT_ESCAPES_MATH } else { TEXT_ESCAPES };
            let lte: &[u8] = if k.math { LINK_TEXT_ESCAPES_MATH } else { LINK_TEXT_ESCAPES };
            assert_eq!(te, t.text_escapes.unwrap());
            assert_eq!(k.math, t.text_leaf_delim(TextLeafKind::InlineMath).unwrap().authorable);
            assert_eq!(k.math, t.text_leaf_delim(TextLeafKind::DisplayMath).unwrap().authorable);
            assert_eq!(lte, t.link_text_escapes.unwrap());
            assert_eq!(BASE.block_start_escapes, t.block_start_escapes);
            assert_eq!(BASE.thematic_break, t.thematic_break);
            if t.mark_colors.is_some() {
                assert!(t.inline_delim(InlineMark::Mark).unwrap().authorable);
            }
            if t.names_leaf_containers || t.block_attrs.is_some() || t.inline_attrs {
                assert!(t.render_block.is_some());
            }
        }
        assert!(!BASE.inline_delim(InlineMark::Mark).unwrap().authorable);
        assert!(!BASE.inline_delim(InlineMark::Delete).unwrap().authorable);
        assert!(BASE.mark_colors.is_none());
        assert!(!BASE.names_leaf_containers);
        assert!(BASE.block_attrs.is_none());
        assert!(!BASE.inline_attrs);
        assert!(!BASE.text_leaf_delim(TextLeafKind::InlineMath).unwrap().authorable);
    }

    #[test]
    fn the_key_is_a_bijection_onto_the_set() {
        for i in 0..Key::COUNT {
            assert_eq!(i, Key::from_index(i).index());
        }
    }

    #[test]
    fn the_colour_palette_offers_every_circle_highlight_knows() {
        let colors = for_options(&ParseOptions { highlight: true, highlight_colors: true, ..opts() });
        let mc = colors.mark_colors.unwrap();
        assert_eq!(highlight::ATTR_KEY.as_bytes(), mc.attr_key);
        assert_eq!(highlight::Color::ALL.len(), mc.colors.len());
        for c in highlight::Color::ALL {
            assert_eq!(c.emoji().as_bytes(), mc.prefix_for(c.name().as_bytes()).unwrap());
            assert_eq!(c.name().as_bytes(), mc.prefix_at(c.emoji().as_bytes()).unwrap().name);
        }
        assert!(mc.prefix_for(b"pink").is_none());
        assert!(mc.prefix_at(b"x").is_none());
    }

    #[test]
    fn for_options_each_flag_moves_exactly_its_own_mark() {
        let same = |a: &Syntax, b: &Syntax| std::ptr::eq(a, b);
        assert!(same(table(), for_options(&opts())));
        assert!(table().inline_delim(InlineMark::Delete).unwrap().authorable);
        assert!(!table().inline_delim(InlineMark::Mark).unwrap().authorable);
        assert!(table().mark_colors.is_none());

        let strict = for_options(&ParseOptions::COMMONMARK);
        assert!(!strict.inline_delim(InlineMark::Delete).unwrap().authorable);
        assert!(!for_options(&ParseOptions { strikethrough: false, ..opts() })
            .inline_delim(InlineMark::Delete)
            .unwrap()
            .authorable);
        assert!(strict.table_spelling.is_none() && strict.task_marker.is_none() && strict.footnote.is_none());

        let gfm = for_options(&ParseOptions::GFM);
        assert!(gfm.footnote.is_none());
        assert!(gfm.table_spelling.is_some() && gfm.task_marker.is_some());
        assert!(gfm.inline_delim(InlineMark::Delete).unwrap().authorable);

        let hi = for_options(&ParseOptions { highlight: true, ..opts() });
        assert!(hi.inline_delim(InlineMark::Mark).unwrap().authorable);
        assert!(hi.inline_delim(InlineMark::Delete).unwrap().authorable);
        assert!(hi.mark_colors.is_none());

        let colors = for_options(&ParseOptions { highlight: true, highlight_colors: true, ..opts() });
        assert!(colors.mark_colors.is_some());
        assert!(!same(colors, hi));

        let colors_no_strike =
            for_options(&ParseOptions { strikethrough: false, highlight: true, highlight_colors: true, ..opts() });
        assert!(colors_no_strike.mark_colors.is_some());
        assert!(!colors_no_strike.inline_delim(InlineMark::Delete).unwrap().authorable);
        assert!(!same(colors_no_strike, colors));

        assert!(same(table(), for_options(&ParseOptions { highlight_colors: true, ..opts() })));

        assert!(!table().names_leaf_containers);
        let dir = for_options(&ParseOptions { directives: true, ..opts() });
        assert!(dir.names_leaf_containers);
        assert!(!same(dir, table()));
        assert!(dir.inline_delim(InlineMark::Delete).unwrap().authorable);
        assert!(!dir.inline_delim(InlineMark::Mark).unwrap().authorable);
        assert!(same(table(), for_options(&ParseOptions { definition_lists: false, ..opts() })));
        assert!(for_options(&ParseOptions { footnotes: false, ..opts() }).footnote.is_none());

        let math = for_options(&ParseOptions { math: true, ..opts() });
        assert!(!same(math, table()));
        assert!(math.text_leaf_delim(TextLeafKind::InlineMath).unwrap().authorable);
        assert!(math.text_leaf_delim(TextLeafKind::DisplayMath).unwrap().authorable);
        assert!(!table().text_leaf_delim(TextLeafKind::InlineMath).unwrap().authorable);
        assert!(math.text_escapes.unwrap().contains(&b'$'));
        assert!(math.link_text_escapes.unwrap().contains(&b'$'));
        assert!(!table().text_escapes.unwrap().contains(&b'$'));
        assert!(for_options(&ParseOptions { directives: true, math: true, ..opts() }).names_leaf_containers);

        assert!(table().block_attrs.is_none());
        assert!(!table().inline_attrs);
        let html = for_options(&ParseOptions { html_elements: true, ..opts() });
        assert_eq!(Some(BlockAttrs::Wrapped), html.block_attrs);
        assert!(html.inline_attrs);
        assert!(!same(html, table()));
        assert!(!html.names_leaf_containers);
        assert!(html.inline_delim(InlineMark::Delete).unwrap().authorable);
        let both = for_options(&ParseOptions { html_elements: true, directives: true, ..opts() });
        assert!(both.names_leaf_containers && both.inline_attrs);

        let mut all: Vec<&Syntax> = Vec::new();
        for i in 0..Key::COUNT {
            let k = Key::from_index(i);
            let t = for_options(&ParseOptions {
                strikethrough: k.strikethrough,
                highlight: k.highlights != Highlights::None,
                highlight_colors: k.highlights == Highlights::Colors,
                directives: k.directives,
                html_elements: k.html_elements,
                math: k.math,
                tables: k.tables,
                task_lists: k.task_lists,
                footnotes: k.footnotes,
                ..opts()
            });
            assert!(same(&every()[i], t));
            all.push(t);
        }
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert!(!same(a, b));
            }
        }
    }

    #[test]
    fn markdown_pads_its_delimiter_row_and_grows_the_dash_run_for_alignment() {
        let ts = table().table_spelling.unwrap();
        assert_eq!(ts.delim_pad, b" ");
        assert_eq!(ts.pad, b" ");
        let want: [&[u8]; 4] = [b"---", b":---", b"---:", b":---:"];
        for (a, w) in ALIGNMENTS.iter().zip(want) {
            assert_eq!(ts.delim.get(*a), w);
        }
        table().assert_coherent();
    }

    #[test]
    fn markdown_spells_the_in_cell_break_as_br() {
        assert_eq!(table().cell_line_break.unwrap(), b"<br>");
    }

    #[test]
    fn markdown_spells_body_text_and_line_start_literals() {
        let te = table().text_escapes.unwrap();
        for c in b"\\*_`[]~<&" {
            assert!(te.contains(c));
        }
        let bse = table().block_start_escapes.unwrap();
        for c in b"#>-+=" {
            assert!(bse.contains(c));
        }
        for c in te {
            assert!(!bse.contains(c));
        }
    }

    #[test]
    fn markdown_autolinks_by_scheme() {
        let none = twig_kit::syntax::none();
        assert!(spells_autolink(none, b"<https://x.dev>"));
        assert!(spells_autolink(none, b"<a@b.dev>"));
        assert!(!spells_autolink(none, b"<foo>"));
        assert!(!spells_autolink(none, b"<foo/bar>"));
    }
}
