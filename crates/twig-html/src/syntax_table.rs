//! HTML's surface spelling. Port of `src/languages/html/syntax.zig`.
//!
//! HTML has no `**`, no `> ` prefix, no fence — but it spells seven of the
//! nine inline marks with a plain element pair, and the HTML parser reads every
//! one of them back. The rest of its spellings have no table shape at all:
//!
//!   * A literal is spelled with ENTITIES, so the alphabets stay `None` and
//!     `render_text` below writes `&amp;`/`&lt;`/`&gt;` instead, in every
//!     position alike.
//!   * Every block is a WRAPPING PAIR, so `render_block` is the serializer
//!     over a fragment: the editor builds the node and the tag pair falls out
//!     of the tree.
//!
//! A task box, a footnote and a table edit still stop: HTML has no native
//! spelling for the first two, and a table is authored by `table_edit.rs`,
//! whose pipe spelling this format cannot write back.

use twig_kit::syntax::{BlockAttrs, Delims, Syntax, TextPosition, TextRenderer};
use crate::ast::{Ast, NodeId};
use crate::Error;

/// HTML's literal: the three bytes that open markup become entities, in every
/// position.
fn render_text(_: &Syntax, text: &[u8], _: TextPosition, out: &mut Vec<u8>) -> Result<(), Error> {
    for &c in text {
        match c {
            b'&' => out.extend_from_slice(b"&amp;"),
            b'<' => out.extend_from_slice(b"&lt;"),
            b'>' => out.extend_from_slice(b"&gt;"),
            _ => out.push(c),
        }
    }
    Ok(())
}

/// The serializer over one node. Label-free: a fragment the editor builds
/// resolves nothing by label.
fn render_block(_: &Syntax, ast: &Ast, root: NodeId, out: &mut Vec<u8>) -> Result<(), Error> {
    twig_kit::html::serialize_node(ast, root, out, None)?;
    Ok(())
}

pub static TABLE: Syntax = Syntax {
    // Seven of nine, each the tag the serializer emits AND the parser maps
    // back. The aliases (`<b>`, `<i>`, `<s>`) are absent: a gesture picks ONE
    // spelling to author. The quote containers render as CHARACTERS, so there
    // is no spelling to author or emit.
    inline_delims: [
        Some(Delims::new("<em>", "</em>")),
        Some(Delims::new("<strong>", "</strong>")),
        Some(Delims::new("<mark>", "</mark>")),
        Some(Delims::new("<sup>", "</sup>")),
        Some(Delims::new("<sub>", "</sub>")),
        Some(Delims::new("<ins>", "</ins>")),
        Some(Delims::new("<del>", "</del>")),
        None,
        None,
    ],
    // `<code>` is the one text leaf HTML spells as a pair the parser reads
    // back.
    text_leaf_delims: [None, Some(Delims::new("<code>", "</code>")), None, None, None, None, None, None, None],
    thematic_break: Some(b"<hr>"),
    cell_line_break: Some(b"<br>"),
    // A newline inside a `<p>` — the line break a join needs. `block_separator`
    // stays `None`: a blank line between two `<p>`s is not what separates them.
    line_join: Some(b"\n"),
    render_text: Some(TextRenderer::Custom(render_text)),
    render_block: Some(render_block),
    // An unknown element reads back as a container named by its tag.
    names_leaf_containers: true,
    // An element's content is its label: `<x-card>Title</x-card>`.
    labels_leaf_containers: true,
    block_attrs: Some(BlockAttrs::Native),
    inline_attrs: true,
    ..Syntax::NONE
};

pub fn table() -> &'static Syntax {
    &TABLE
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Builder, InlineMark, Kind, TextLeafKind};
    use twig_kit::syntax::ContainerKind;

    #[test]
    fn html_authors_the_seven_marks_it_can_read_back_and_neither_quote() {
        let paired = [
            InlineMark::Emph,
            InlineMark::Strong,
            InlineMark::Mark,
            InlineMark::Superscript,
            InlineMark::Subscript,
            InlineMark::Insert,
            InlineMark::Delete,
        ];
        for m in InlineMark::ALL {
            let d = TABLE.inline_delim(m);
            assert_eq!(paired.contains(&m), d.is_some());
            if let Some(d) = d {
                assert!(d.authorable);
                assert!(d.open.starts_with(b"<"));
                assert!(d.close.starts_with(b"</"));
                assert_eq!(&d.open[1..], &d.close[2..]);
            }
        }
        TABLE.assert_coherent();
        assert!(TABLE.authorable());
    }

    #[test]
    fn html_spells_code_and_no_other_text_leaf() {
        for l in TextLeafKind::ALL {
            assert_eq!(l == TextLeafKind::Verbatim, TABLE.text_leaf_delim(l).is_some());
        }
        assert!(TABLE.text_leaf_delim(TextLeafKind::Verbatim).unwrap().authorable);
    }

    #[test]
    fn html_spells_no_line_prefixed_block_structure_and_no_backslash_alphabet() {
        assert!(TABLE.render_block.is_some());
        assert!(TABLE.heading_marker.is_none());
        for k in ContainerKind::ALL {
            assert!(TABLE.container(k).is_none());
        }
        assert!(TABLE.code_fence.is_none());
        assert!(TABLE.link_text_escapes.is_none());
        assert!(TABLE.link_dest_escapes.is_none());
        assert!(TABLE.text_escapes.is_none());
        assert!(TABLE.block_start_escapes.is_none());
        assert!(TABLE.render_text.is_some());
        assert!(!TABLE.renders_text_by_alphabet());
        assert!(TABLE.footnote.is_none());
        assert!(TABLE.task_marker.is_none());
        assert!(TABLE.spells_autolink.is_none());
        assert!(TABLE.attr_spelling.is_none());
        TABLE.assert_coherent();
    }

    #[test]
    fn html_spells_a_literal_with_entities_in_every_position() {
        for pos in TextPosition::ALL {
            let mut out = Vec::new();
            TABLE.render_text(b"a <b> & \\c", pos, &mut out).unwrap();
            assert_eq!(out, b"a &lt;b&gt; &amp; \\c");
        }
    }

    #[test]
    fn html_prints_a_fragment_as_the_tag_pair_its_parser_reads_back() {
        let mut b = Builder::new();
        let text = b.add_leaf(Kind::Str(b"hi".to_vec()));
        let em = b.add_container(Kind::InlineMark(InlineMark::Emph), &[text]);
        let h = b.add_container(Kind::Heading { level: 2 }, &[em]);
        let view = b.view(h);
        let mut out = Vec::new();
        (TABLE.render_block.unwrap())(&TABLE, &view, h, &mut out).unwrap();
        assert_eq!(out, b"<h2><em>hi</em></h2>\n");

        let mut c = Builder::new();
        let a = c.add_leaf(Kind::Str(b"a".to_vec()));
        let p1 = c.add_container(Kind::Para, &[a]);
        let bb = c.add_leaf(Kind::Str(b"b".to_vec()));
        let p2 = c.add_container(Kind::Para, &[bb]);
        let i1 = c.add_container(Kind::ListItem, &[p1]);
        let i2 = c.add_container(Kind::ListItem, &[p2]);
        let list = c.add_container(Kind::BulletList { tight: true }, &[i1, i2]);
        let code = c.add_leaf(Kind::CodeBlock { lang: Some(b"zig".to_vec()), text: b"a < b".to_vec() });
        let t = c.add_leaf(Kind::Str(b"t".to_vec()));
        let link = c.add_container(
            Kind::Link(crate::ast::Link { destination: Some(b"x?a=1&b=2".to_vec()), reference: None }),
            &[t],
        );
        let p3 = c.add_container(Kind::Para, &[link]);
        let q = c.add_container(Kind::BlockQuote, &[list, code, p3]);
        let qv = c.view(q);
        let mut qout = Vec::new();
        (TABLE.render_block.unwrap())(&TABLE, &qv, q, &mut qout).unwrap();
        assert_eq!(
            String::from_utf8(qout).unwrap(),
            "<blockquote>\n<ul>\n<li>\na\n</li>\n<li>\nb\n</li>\n</ul>\n\
             <pre><code class=\"language-zig\">a &lt; b</code></pre>\n\
             <p><a href=\"x?a=1&amp;b=2\">t</a></p>\n</blockquote>\n"
        );
    }

    #[test]
    fn html_spells_the_rule_and_the_break_as_void_tags() {
        assert_eq!(TABLE.thematic_break.unwrap(), b"<hr>");
        assert_eq!(TABLE.cell_line_break.unwrap(), b"<br>");
    }
}
