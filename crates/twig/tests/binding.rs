//! The drop-in proof: every test of the FFI binding crate `twig-doc` 4.x
//! (`bindings/rust/twig/src/lib.rs`'s `mod tests`), run against the pure-Rust
//! crate exactly as an external consumer would — `use twig::*`.
//!
//! A handful reached into the binding's private C layer (`ffi::…`,
//! `to_flags`, `to_c`); those assertions are restated over the public API,
//! each marked `// ported:` with what changed.

mod common;

use twig::*;

#[test]
fn markdown_extensions_are_the_markdown_rows_features() {
    let typed = twig_markdown::Extensions { math: true, highlight_colors: true, ..Default::default() };
    for row in [common::markdown(), common::gfm(), common::commonmark()] {
        // ported: `to_flags` is private; its bits are `TWIG_MD_MATH | TWIG_MD_HIGHLIGHT_COLORS`.
        let _ = typed;
        assert_eq!(row.feature_flags(&["math", "highlight_colors"]), Ok((1 << 1) | (1 << 4)));
    }
    assert_eq!(common::markdown().feature_flags(&["tables"]), Err(Error::NotFound));

    // Colours bring the highlight they colour, by either spelling.
    let source = "a ==\u{1F534} b== c\n";
    let mut doc = Document::parse_with_features(source.as_bytes(), common::markdown(), &["highlight_colors"]).unwrap();
    assert_eq!(doc.query("mark[data-color=red]").unwrap().len(), 1);
    assert!(common::markdown().supports_with_features(&["highlight_colors"], Gesture::SetMarkColor));
}

#[test]
fn abi_version_matches() {
    // ported: there is no `ffi` layer; the compiled-against constant is it.
    assert_eq!(abi_version(), ABI_VERSION);
}

#[test]
fn parses_and_renders_markdown_html() {
    let mut doc = Document::parse_str("# hi\n", common::markdown()).expect("parse markdown");
    let html = doc.render_html().expect("render html");
    assert_eq!(String::from_utf8_lossy(&html), "<h1>hi</h1>\n");
}

#[test]
fn parses_html_input() {
    let mut doc = Document::parse_str("<p>hi</p>", common::html()).expect("parse html");
    let html = doc.render_html().expect("render html");
    assert!(String::from_utf8_lossy(&html).contains("hi"));
}

#[test]
fn parses_renders_and_writes_asciidoc() {
    let mut doc = Document::parse_str("= Title\n\nsome *bold* text\n", common::asciidoc())
        .expect("parse asciidoc");
    let html = String::from_utf8_lossy(&doc.render_html().expect("render html")).into_owned();
    assert!(html.contains("<h1>Title</h1>"), "got {html:?}");
    assert!(html.contains("<strong>bold</strong>"), "got {html:?}");

    // Round-trip, and a cross-format conversion from Markdown.
    let back = doc.serialize_to(common::asciidoc().target()).expect("serialize asciidoc");
    assert_eq!(String::from_utf8_lossy(&back), "= Title\n\nsome *bold* text\n");
    let mut md = Document::parse_str("# Title\n\nsome **bold** text\n", common::markdown())
        .expect("parse markdown");
    let converted = md.serialize_to(common::asciidoc().target()).expect("convert to asciidoc");
    assert_eq!(String::from_utf8_lossy(&converted), "= Title\n\nsome *bold* text\n");
    assert_eq!(Target::from(common::asciidoc()), common::asciidoc().target());
    assert_eq!(common::asciidoc().target().as_format(), Some(common::asciidoc()));
}

#[test]
fn markdown_dialects_are_formats_over_one_parser() {
    // Three formats, one parser: strict CommonMark reads `~~x~~` as text
    // and a pipe table as a paragraph; GFM and the default read both; an
    // extension laid over GFM adds what GFM proper leaves out.
    let src = "a ~~b~~ c\n\n| x |\n| - |\n| $m$ |\n";
    let count = |doc: &mut Document, sel: &str| doc.query(sel).expect("query").len();
    for (format, ext, delete, table, math) in [
        (common::commonmark(), twig_markdown::Extensions::default(), 0, 0, 0),
        (common::markdown(), twig_markdown::Extensions::default(), 1, 1, 0),
        (common::gfm(), twig_markdown::Extensions::default(), 1, 1, 0),
        (common::gfm(), twig_markdown::Extensions { math: true, ..Default::default() }, 1, 1, 1),
    ] {
        let mut doc = common::parse_str_with(src, format, ext).expect("parse");
        assert_eq!(count(&mut doc, "delete"), delete, "{format:?} {ext:?}");
        assert_eq!(count(&mut doc, "table"), table, "{format:?} {ext:?}");
        assert_eq!(count(&mut doc, "inline_math"), math, "{format:?} {ext:?}");
    }

    // A dialect writes as its language, and a GFM document serialized as
    // Markdown is a round trip, spelling intact.
    assert_eq!(common::gfm().dialect_of(), Some(common::markdown()));
    assert_eq!(common::commonmark().dialect_of(), Some(common::markdown()));
    assert_eq!(common::markdown().dialect_of(), None);
    // And xml's one dialect, which writes as xml and takes xml's gesture.
    assert_eq!(common::svg().dialect_of(), Some(common::xml()));
    assert_eq!(Target::from(common::svg()), common::xml().target());
    let mut svg =
        Document::parse_str("<svg><rect x=\"1\"/></svg>", common::svg()).expect("parse svg");
    assert_eq!(
        String::from_utf8_lossy(&svg.serialize(common::xml()).expect("serialize")),
        "<svg><rect x=\"1\"/></svg>"
    );
    assert!(common::svg().supports(Gesture::SetNodeAttrs));
    assert!(!common::svg().is_authorable());
    assert_eq!(Target::from(common::gfm()), common::markdown().target());
    let mut gfm = Document::parse_str("* a ~~b~~\n", common::gfm()).expect("parse gfm");
    let back = gfm.serialize(common::gfm()).expect("serialize");
    assert_eq!(String::from_utf8_lossy(&back), "* a ~~b~~\n");

    // The render follows the row: GFM spells alignment as an attribute.
    let mut table = Document::parse_str("| a |\n| :-: |\n| 1 |\n", common::gfm()).expect("parse");
    let html = String::from_utf8_lossy(&table.render_html().expect("render")).into_owned();
    assert!(html.contains("align=\"center\""), "got {html:?}");

    // And the capability query answers per dialect.
    assert!(!common::commonmark().supports(Gesture::ToggleInline(InlineKind::Delete)));
    assert!(common::gfm().supports(Gesture::ToggleInline(InlineKind::Delete)));
}

#[test]
fn serialize_round_trips_and_cross_converts() {
    let mut doc = Document::parse_str("# hi\n", common::markdown()).expect("parse markdown");

    let canonical = doc.serialize(common::markdown()).expect("serialize markdown");
    assert!(String::from_utf8_lossy(&canonical).contains("# hi"));

    // Cross-format Markdown -> XML has no serializer.
    assert_eq!(doc.serialize(common::xml()), Err(Error::UnsupportedFormat));
}

#[test]
fn serialize_markdown_to_djot() {
    let mut doc =
        Document::parse_str("This is *markdown*.\n", common::markdown()).expect("parse markdown");
    let djot = doc.serialize(common::djot()).expect("serialize djot");
    assert!(String::from_utf8_lossy(&djot).contains("_markdown_"));
}

#[test]
fn serialize_to_takes_the_output_axis() {
    let mut doc =
        Document::parse_str("This is *markdown*.\n", common::markdown()).expect("parse markdown");

    let djot = doc.serialize_to(common::djot().target()).expect("serialize djot");
    assert!(String::from_utf8_lossy(&djot).contains("_markdown_"));

    // The capability answer is the target's, not the input's: converting
    // INTO XML has no serializer regardless of what parsed the document.
    assert_eq!(doc.serialize_to(common::xml().target()), Err(Error::UnsupportedFormat));
}

#[test]
fn serialize_and_serialize_to_agree() {
    // `serialize` is defined in terms of `serialize_to`, so the older
    // spelling stays exact rather than merely similar.
    let mut a = Document::parse_str("# hi\n", common::markdown()).expect("parse markdown");
    let mut b = Document::parse_str("# hi\n", common::markdown()).expect("parse markdown");
    for format in [common::markdown(), common::djot(), common::html()] {
        assert_eq!(a.serialize(format), b.serialize_to(Target::from(format)));
    }
}

#[test]
fn every_format_is_a_target_that_names_it_back() {
    // The subset invariant the Zig `targets` table enforces, restated at
    // this layer: `Target::from` is total, and `as_format` round-trips it.
    for format in [common::djot(), common::markdown(), common::xml(), common::html()] {
        assert_eq!(Target::from(format).as_format(), Some(format));
    }
}

#[test]
fn ast_json_dumps_the_tree() {
    let mut doc = Document::parse_str("hello\n", common::djot()).expect("parse djot");
    let json = doc.ast_json().expect("ast json");
    assert!(String::from_utf8_lossy(&json).contains("\"kind\": \"doc\""));
}

#[test]
fn node_table_is_what_lang_table_prints_spelling_included() {
    let mut doc = Document::parse_str("* a\n", common::markdown()).expect("parse markdown");
    let table = String::from_utf8(doc.node_table().expect("node table")).unwrap();
    // `twig lang table` on the same file, byte for byte.
    let expected = r#"{
  "nodes": [
    {"kind":"doc","parent":null,"span":[0,4],"content_span":[0,3]},
    {"kind":"bullet_list","parent":0,"span":[0,3],"content_span":[0,3],"spelling":{"bullet":"star"},"tight":true},
    {"kind":"list_item","parent":1,"span":[0,3],"content_span":[0,3],"marker_span":[0,2]},
    {"kind":"para","parent":2,"span":[0,3],"content_span":[2,3]},
    {"kind":"str","parent":3,"span":[2,3],"text":"a"}
  ],
  "labels": []
}
"#;
    assert_eq!(table, expected);
}

#[test]
fn query_finds_nodes_by_selector() {
    let source = "# One\n\n## Two\n";
    let mut doc = Document::parse_str(source, common::markdown()).expect("parse markdown");
    let matches = doc.query("heading").expect("query");

    assert_eq!(matches.len(), 2);
    for m in &matches {
        assert_eq!(m.kind, Kind::Heading);
        assert!(m.span.start < m.span.end);
    }
}

#[test]
fn query_recovers_code_spans() {
    let source = "prose `code` more prose\n";
    let mut doc = Document::parse_str(source, common::markdown()).expect("parse markdown");
    let matches = doc.query("verbatim").expect("query");

    assert_eq!(matches.len(), 1);
    assert_eq!(&source[matches[0].span.clone()], "`code`");
}

#[test]
fn document_span_accessors_read_by_node_id() {
    let source = "# hi\n\ntext\n";
    let mut doc = Document::parse_str(source, common::markdown()).expect("parse markdown");
    let heading = doc.query("heading").expect("query").pop().expect("heading");

    assert_eq!(
        doc.span(NodeId(heading.node_id)).expect("span"),
        heading.span
    );
    assert_eq!(
        doc.content_span(NodeId(heading.node_id))
            .expect("content span"),
        heading.content_span
    );
    assert_eq!(doc.span(NodeId(u32::MAX)), Err(Error::InvalidArgument));
}

#[test]
fn document_walks_its_tree_without_an_editor() {
    let source = "# hi\n\ntext\n";
    let mut doc = Document::parse_str(source, common::markdown()).expect("parse markdown");

    let nodes = doc.nodes().expect("nodes");
    assert!(nodes.len() >= 3);
    for (i, n) in nodes.iter().enumerate() {
        assert_eq!(n.id, NodeId(i as u32));
    }

    let kids = doc.children(None).expect("children");
    assert_eq!(kids.len(), 2);
    assert_eq!(kids[0].kind, Kind::Heading);

    let sub = doc.subtree(NodeId(kids[0].node_id)).expect("subtree");
    assert_eq!(sub[0].id, NodeId(0));
    assert_eq!(sub[0].parent, None);
    assert_eq!(sub[0].span, kids[0].span);

    let hit = doc.node_at(2).expect("node_at").expect("a node at 2");
    let chain = doc.ancestors_at(2).expect("ancestors");
    assert_eq!(chain.last().expect("deepest").node_id, hit.node_id);
    assert_eq!(chain[0].kind, Kind::Doc);

    assert_eq!(doc.subtree(NodeId(u32::MAX)), Err(Error::InvalidArgument));
}

#[test]
fn editor_document_view_reads_the_live_tree() {
    let mut ed = Editor::new_str("# one\n\ntwo\n", common::markdown()).expect("editor");

    {
        let mut view = ed.document().expect("view");
        let kids = view.children(None).expect("children");
        assert_eq!(kids.len(), 2);
        assert_eq!(kids[0].kind, Kind::Heading);
        assert_eq!(view.span(NodeId(kids[0].node_id)).expect("span"), 0..5);
        // The two the view can't serve.
        assert_eq!(view.render_html(), Err(Error::UnsupportedFormat));
        assert_eq!(
            view.serialize(common::markdown()),
            Err(Error::UnsupportedFormat)
        );
    }

    ed.replace("0", "# one and a half").expect("replace");
    let mut view = ed.document().expect("view");
    let kids = view.children(None).expect("children");
    assert_eq!(view.span(NodeId(kids[0].node_id)).expect("span"), 0..16);
}

#[test]
fn query_rejects_a_malformed_selector() {
    let mut doc = Document::parse_str("hi\n", common::markdown()).expect("parse markdown");
    assert_eq!(doc.query("list >"), Err(Error::InvalidArgument));
}

#[test]
fn editor_edits_by_index_path() {
    let mut ed = Editor::new_str("<a><b>hi</b></a>", common::xml()).expect("editor");
    ed.replace_content("0.0", "bye").expect("replace_content");
    assert_eq!(ed.source_str().expect("source"), "<a><b>bye</b></a>");
}

#[test]
fn flat_nodes_expose_element_name_and_attrs() {
    // A `<picture>` with a theme-switching `<source>`: the dark alternative
    // lives only in the `<source>`'s attributes, which the snapshot now
    // surfaces (both `<picture>` and `<source>` report `kind == "container"`).
    let src = "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"d.svg\"><img src=\"l.svg\" alt=\"x\"></picture>\n";
    let mut ed = common::new_ext(
        src.as_bytes(),
        common::markdown(),
        twig_markdown::Extensions {
            html_elements: true,
            ..Default::default()
        },
    )
    .expect("editor");
    let nodes = ed.nodes().expect("nodes");

    let source = nodes
        .iter()
        .find(|n| n.name.as_deref() == Some("source"))
        .expect("a <source> element node");
    assert_eq!(
        source.attrs,
        vec![
            (
                "media".to_string(),
                Some("(prefers-color-scheme: dark)".to_string())
            ),
            ("srcset".to_string(), Some("d.svg".to_string())),
        ]
    );

    // The `<img>` fallback stays an `image` node (no element name), and its
    // `src` is the ordinary `destination`.
    let img = nodes
        .iter()
        .find(|n| n.kind == Kind::Image)
        .expect("an image node");
    assert!(img.name.is_none());
    assert_eq!(img.destination.as_deref(), Some("l.svg"));

    // A semantic node carries neither an element name nor attributes.
    let picture_kids_str = nodes.iter().find(|n| n.kind == Kind::Str);
    if let Some(s) = picture_kids_str {
        assert!(s.name.is_none() && s.attrs.is_empty());
    }
}

#[test]
fn definitions_finds_what_a_walk_from_the_root_cannot() {
    // Both definitions are resolved by label, so neither is anybody's
    // child: the document root's subtree contains the paragraph and
    // nothing else.
    let mut doc = Document::parse_str(
        "text[^1] [x][a]\n\n[^1]: note\n\n[a]: /u\n",
        common::markdown(),
    )
    .expect("parse markdown");

    let defs = doc.definitions().expect("definitions");
    let mut kinds: Vec<Kind> = defs.iter().map(|m| m.kind.clone()).collect();
    kinds.sort_by(|a, b| a.as_str().cmp(b.as_str()));
    assert_eq!(kinds, vec![Kind::Footnote, Kind::Reference]);

    // Each one knows where it stands. A link reference definition used
    // to answer `0..0`, which left an editor unable to tell its lines
    // from blank ones.
    for d in &defs {
        let want = match d.kind {
            Kind::Footnote => 17..27,
            Kind::Reference => 29..36,
            _ => unreachable!(),
        };
        assert_eq!(d.span, want, "{} stands on its own bytes", d.kind);
    }

    // None of them is reachable from the root — the property that made a
    // whole-arena rescan the only way to find them.
    let all = doc.nodes().expect("nodes");
    let root = all
        .iter()
        .find(|n| n.kind == Kind::Doc)
        .expect("a doc root");
    let mut reachable = vec![root.id];
    let mut i = 0;
    while i < reachable.len() {
        let n = &all[reachable[i].0 as usize];
        let mut c = n.first_child;
        while let Some(cid) = c {
            reachable.push(cid);
            c = all[cid.0 as usize].next_sibling;
        }
        i += 1;
    }
    for d in &defs {
        assert!(
            !reachable.contains(&NodeId(d.node_id)),
            "{} should be unreachable from the root",
            d.kind
        );
    }

    // A document that defines nothing gets an empty vec, not an error.
    let mut plain = Document::parse_str("just text\n", common::markdown()).expect("parse");
    assert_eq!(plain.definitions().expect("definitions"), Vec::new());
}

#[test]
fn kind_round_trips_through_its_published_name() {
    // `as_str` is the wire vocabulary and `from` is its inverse, so any
    // variant whose spelling drifts from the C ABI's fails here rather
    // than quietly becoming `Other`.
    for k in [
        Kind::Doc,
        Kind::Para,
        Kind::Heading,
        Kind::Container,
        Kind::TaskListItem,
        Kind::Superscript,
        Kind::FootnoteReference,
        Kind::ProcessingInstruction,
        Kind::Cdata,
    ] {
        assert_eq!(Kind::from(k.as_str()), k, "{k} did not round-trip");
        assert!(!k.is_unknown());
    }
}

#[test]
fn an_unknown_kind_name_is_carried_rather_than_lost() {
    // A newer library against an older binding. The node is still a node,
    // and a renderer that passes it through unchanged should be able to.
    let k = Kind::from("some_future_kind");
    assert!(k.is_unknown());
    assert_eq!(k.as_str(), "some_future_kind");
    assert_eq!(k, Kind::Other("some_future_kind".to_string()));
}

#[test]
fn every_kind_the_library_publishes_has_a_variant() {
    // Walks documents covering every corner of the vocabulary this crate
    // can reach from Rust and asserts nothing arrives as `Other`. If twig
    // adds a kind, or renames one, this fails — which is the whole reason
    // the enum is here instead of a `String`.
    let cases: &[(&str, Format, twig_markdown::Extensions)] = &[
        (
            "# h\n\npara *emph* **strong** `code`\n\n- a\n- b\n\n1. c\n\n> q\n\n---\n\n```zig\nx\n```\n",
            common::markdown(),
            twig_markdown::Extensions {
                directives: false,
                math: false,
                html_elements: false,
                highlight: false,
                highlight_colors: false,
            },
        ),
        (
            "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n- [ ] task\n- [x] done\n\nfoot[^1]\n\n[^1]: note\n\n[l]: /u\n\n[x][l]\n",
            common::markdown(),
            twig_markdown::Extensions::default(),
        ),
        (
            ":::note\nbody\n:::\n\n:role[x]\n\n$a+b$ ==h== ==🔴 r==\n",
            common::markdown(),
            twig_markdown::Extensions {
                directives: true,
                math: true,
                html_elements: false,
                highlight: true,
                highlight_colors: true,
            },
        ),
        (
            "a^b^ c~d~ {=e=} {+f+} {-g-} 'q' \"dq\"\n\n![i](/p)\n\n<https://e.com>\n",
            common::djot(),
            twig_markdown::Extensions::default(),
        ),
        (
            "<!-- c --><!DOCTYPE html><video controls><p>x</p></video>",
            common::html(),
            twig_markdown::Extensions::default(),
        ),
    ];

    let mut unknown: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for (src, format, ext) in cases {
        let mut ed = common::new_ext(src.as_bytes(), *format, *ext).expect("editor");
        for n in ed.nodes().expect("nodes") {
            if n.kind.is_unknown() {
                unknown.push(n.kind.as_str().to_string());
            }
            seen.push(n.kind.as_str().to_string());
        }
    }
    unknown.sort();
    unknown.dedup();
    assert!(unknown.is_empty(), "kinds with no variant: {unknown:?}");

    // And the sweep really swept: without this the assertion above passes
    // just as happily on an empty walk.
    seen.sort();
    seen.dedup();
    assert!(
        seen.len() >= 30,
        "only {} distinct kinds reached: {seen:?}",
        seen.len()
    );
}

#[test]
fn diagnostics_report_what_a_conversion_would_lose() {
    // A djot superscript has no Markdown spelling. The two answers below
    // are for the SAME document — fidelity is a property of the
    // (document, target) pair, which is why it is asked per target.
    let mut doc = Document::parse_str("a^b^ c\n", common::djot()).expect("parse djot");

    let to_md = doc
        .diagnostics(common::markdown().target())
        .expect("markdown diagnostics");
    assert_eq!(
        to_md,
        vec![Warning {
            fidelity: Fidelity::Degraded,
            path: "0/1".to_string(),
            kind: Kind::Superscript,
        }]
    );

    // Lossless to djot: an empty vec is a real answer, not a failure.
    assert_eq!(
        doc.diagnostics(common::djot().target()).expect("djot diagnostics"),
        Vec::new()
    );
}

#[test]
fn diagnostics_separate_a_droppable_node_from_a_degradable_one() {
    // An HTML comment converted to djot leaves NOTHING behind — a
    // different and worse answer than "comes back as something else", and
    // the distinction a consumer needs to decide whether to warn or refuse.
    let mut doc =
        Document::parse_str("<p>hi</p><!-- secret -->", common::html()).expect("parse html");
    let warnings = doc.diagnostics(common::djot().target()).expect("djot diagnostics");
    let comment = warnings
        .iter()
        .find(|w| w.kind == Kind::Comment)
        .expect("a warning about the comment");
    assert_eq!(comment.fidelity, Fidelity::Dropped);
}

#[test]
fn diagnostics_report_a_surviving_nodes_lost_attributes() {
    // A djot paragraph carrying a class converts to Markdown as a `<div>`
    // around the paragraph, which Markdown's default parser reads as raw
    // HTML beside it: the node survives, the class is written where it is
    // not read back, and the warning says which of the two it is about.
    let mut doc = Document::parse_str("{.center}\nhello\n", common::djot()).expect("parse djot");
    assert_eq!(
        doc.diagnostics(common::markdown().target()).expect("markdown diagnostics"),
        vec![Warning {
            fidelity: Fidelity::AttrsDegraded,
            path: "0".to_string(),
            kind: Kind::Para,
        }]
    );
    // An emphasis carrying one has nowhere to put it.
    let mut em = Document::parse_str("_x_{.big}\n", common::djot()).expect("parse djot");
    assert_eq!(
        em.diagnostics(common::markdown().target()).expect("markdown diagnostics"),
        vec![Warning {
            fidelity: Fidelity::AttrsDropped,
            path: "0/0".to_string(),
            kind: Kind::Emph,
        }]
    );
    // HTML and AsciiDoc keep a paragraph's class: nothing to report.
    assert_eq!(doc.diagnostics(common::html().target()).expect("html"), Vec::new());
    assert_eq!(doc.diagnostics(common::asciidoc().target()).expect("asciidoc"), Vec::new());
}

#[test]
fn diagnostics_report_a_degraded_nodes_attributes_beside_it() {
    // A Word paste: `<html>` and `<body>` are sections, which Markdown
    // degrades and still writes a `<div>` for each one's attributes.
    // Three `<div>`s, three attribute warnings — two of them at a path
    // that also carries the node's own.
    let mut doc = Document::parse_str(
        r#"<html xmlns:o="urn:x"><body lang="EN-US"><p class="MsoNormal">Word text</p></body></html>"#,
        common::html(),
    )
    .expect("parse html");
    let w = |fidelity, path: &str, kind| Warning {
        fidelity,
        path: path.to_string(),
        kind,
    };
    assert_eq!(
        doc.diagnostics(common::markdown().target()).expect("markdown diagnostics"),
        vec![
            w(Fidelity::Degraded, "0", Kind::Section),
            w(Fidelity::AttrsDegraded, "0", Kind::Section),
            w(Fidelity::Degraded, "0/0", Kind::Section),
            w(Fidelity::AttrsDegraded, "0/0", Kind::Section),
            w(Fidelity::AttrsDegraded, "0/0/0", Kind::Para),
        ]
    );
}

#[test]
fn diagnostics_say_nothing_of_what_a_link_or_image_already_spells() {
    // `href`, `src` and `alt` are the node's destination and alt text,
    // which Markdown writes in full.
    for html in [r#"<p>a <a href="https://x.dev">l</a></p>"#, r#"<p><img src="u" alt="p"></p>"#] {
        let mut doc = Document::parse_str(html, common::html()).expect("parse html");
        assert_eq!(doc.diagnostics(common::markdown().target()).expect("markdown"), Vec::new());
        assert_eq!(doc.diagnostics(common::djot().target()).expect("djot"), Vec::new());
    }
}

#[test]
fn diagnostics_refuse_a_target_with_no_serializer() {
    // "This target cannot be written" is a capability answer, not a
    // per-node diagnosis of every node in the document.
    let mut doc = Document::parse_str("# hi\n", common::markdown()).expect("parse markdown");
    assert_eq!(doc.diagnostics(common::xml().target()), Err(Error::UnsupportedFormat));
    // AsciiDoc has a serializer now, so it gets a per-node answer instead.
    assert!(doc.diagnostics(common::asciidoc().target()).is_ok());
}

#[test]
fn diagnostics_flag_a_header_less_table_and_leave_a_headed_one_alone() {
    // The instance-level answer, and the one a consumer cannot reach by
    // looking at kinds: both documents contain a `table`, and only one of
    // them costs anything to convert. GFM's delimiter row is mandatory, so
    // the header-less table gets an empty header synthesized above it.
    let mut headed = Document::parse_str(
        "<table><tr><th>H</th></tr><tr><td>a</td></tr></table>",
        common::html(),
    )
    .expect("parse headed table");
    assert!(
        headed
            .diagnostics(common::markdown().target())
            .expect("diagnostics")
            .iter()
            .all(|w| w.kind != Kind::Table)
    );

    let mut headless = Document::parse_str("<table><tr><td>a</td></tr></table>", common::html())
        .expect("parse header-less table");
    let table_warning = headless
        .diagnostics(common::markdown().target())
        .expect("diagnostics")
        .into_iter()
        .find(|w| w.kind == Kind::Table)
        .expect("a warning about the table");
    assert_eq!(table_warning.fidelity, Fidelity::Degraded);
}

#[test]
fn container_origin_separates_a_div_from_a_div() {
    // The collision this field exists for. These two documents produce
    // container nodes that agree on `kind`, on `name` AND on
    // `directive_form` — so a consumer holding one of them could not say
    // which syntax the author wrote without re-reading the source bytes.
    let mut html =
        Editor::new("<div>hi</div>\n".as_bytes(), common::html()).expect("html editor");
    let mut md = common::new_ext(
        ":::div\nhi\n:::\n".as_bytes(),
        common::markdown(),
        twig_markdown::Extensions {
            directives: true,
            ..Default::default()
        },
    )
    .expect("markdown editor");

    let html_nodes = html.nodes().expect("html nodes");
    let md_nodes = md.nodes().expect("markdown nodes");
    let tag = html_nodes
        .iter()
        .find(|n| n.name.as_deref() == Some("div"))
        .expect("a <div> container");
    let directive = md_nodes
        .iter()
        .find(|n| n.name.as_deref() == Some("div"))
        .expect("a :::div container");

    // Indistinguishable on every field that predates `origin`.
    assert_eq!(tag.kind, directive.kind);
    assert_eq!(tag.name, directive.name);
    assert_eq!(tag.directive_form, directive.directive_form);
    assert_eq!(tag.directive_form, Some(DirectiveForm::Container));

    // And decidable now.
    assert_eq!(tag.origin, Some(ContainerOrigin::Element));
    assert_eq!(directive.origin, Some(ContainerOrigin::Directive));
}

#[test]
fn a_container_whose_body_is_text_says_so_in_text() {
    // `<script>` and `<span>` used to be the same shape — a container over
    // one `str` — and differ only in name, so an editor could not tell a
    // JavaScript body from prose without its own tag list. The tokenizer
    // knows: a raw-text or rcdata body is the node's `text`, and there
    // are no children to step into.
    let mut html = Editor::new(
        "<script>a < b</script><title>a &amp; b</title><span>a &amp; b</span>\n".as_bytes(),
        common::html(),
    )
    .expect("html editor");
    let nodes = html.nodes().expect("html nodes");
    let by_name = |name: &str| {
        nodes
            .iter()
            .find(|n| n.name.as_deref() == Some(name))
            .unwrap_or_else(|| panic!("a <{name}> container"))
    };
    let script = by_name("script");
    assert_eq!(script.kind, Kind::Container);
    assert_eq!(script.text.as_deref(), Some("a < b"));
    assert_eq!(script.first_child, None);
    // rcdata is decoded, like any text.
    assert_eq!(by_name("title").text.as_deref(), Some("a & b"));
    // A markup body is children, and `text` stays `None`.
    let span = by_name("span");
    assert_eq!(span.text, None);
    assert!(span.first_child.is_some());
}

/// Parse `src` as both authorable formats and run `check` over each — the
/// shape every test below wants, because the point of these two APIs is
/// that a consumer cannot tell which parser produced the tree.
fn for_both_formats(src: &str, check: impl Fn(&mut Document, Format)) {
    for format in [common::markdown(), common::djot()] {
        let mut doc = Document::parse(src.as_bytes(), format).expect("parse");
        check(&mut doc, format);
    }
}

#[test]
fn marker_span_is_what_a_rich_view_hides() {
    for_both_formats("> - [x] done\n", |doc, format| {
        let nodes = doc.nodes().expect("nodes");
        let quote = nodes
            .iter()
            .find(|n| n.kind == Kind::BlockQuote)
            .expect("a block quote");
        let item = nodes
            .iter()
            .find(|n| n.kind == Kind::TaskListItem)
            .expect("a task item");

        // The quote's `> ` and the item's `- [x] ` — the item's marker
        // takes its checkbox with it, because the rendered view draws a
        // checkbox in PLACE of those bytes rather than beside them.
        assert_eq!(quote.marker_span, Some(0..2), "{format:?}");
        assert_eq!(item.marker_span, Some(2..8), "{format:?}");

        // Not derivable from the other two spans: a marker-prefixed
        // container reports its whole extent as its interior, so the
        // subtraction a caller might reach for yields nothing.
        assert_eq!(quote.content_span, Some(quote.span.clone()), "{format:?}");

        // A paragraph has no marker of its own; only its ancestors do.
        let para = nodes
            .iter()
            .find(|n| n.kind == Kind::Para)
            .expect("a paragraph");
        assert_eq!(para.marker_span, None, "{format:?}");
    });
}

#[test]
fn attrs_span_locates_the_attribute_block_a_heuristic_had_to_guess_at() {
    // A Djot attribute line sits on its OWN line above the block it
    // attaches to, so a consumer dropping the block has to drop that line
    // too. Without this the extent was guessed at by scanning for `{`,
    // which strands the line as a published paragraph when the guess
    // misses — and the line names the audience.
    let src = "{.vis .family}\nheld back\n\nplain\n";
    let mut doc = Document::parse(src.as_bytes(), common::djot()).expect("parse");
    let nodes = doc.nodes().expect("nodes");
    let paras: Vec<&FlatNode> = nodes.iter().filter(|n| n.kind == Kind::Para).collect();
    assert_eq!(paras.len(), 2);

    let span = doc
        .attrs_span(paras[0].id)
        .expect("attrs span")
        .expect("the attributed paragraph has one");
    assert_eq!(&src[span.clone()], "{.vis .family}");
    // The block's own span starts AFTER the attribute line, which is why
    // dropping the block alone leaves the line behind.
    assert!(span.end <= paras[0].span.start);

    // `None` is a real answer, not a failure: the second paragraph is
    // unattributed.
    assert_eq!(doc.attrs_span(paras[1].id).expect("attrs span"), None);
}

#[test]
fn line_prefix_assembles_every_marker_on_the_line() {
    for_both_formats("> - [x] done\n", |doc, format| {
        // Four nodes' worth of hidden width as one range, which is what a
        // caret stepping over it needs — not a chain to stitch together.
        assert_eq!(doc.line_prefix(9).expect("prefix"), Some(0..8), "{format:?}");
    });
}

#[test]
fn line_prefix_is_none_on_a_continuation_line() {
    // Line two continues the quote but OPENS nothing. `None` is the honest
    // answer: what a continuation line repeats is a different question with
    // a different answer, and guessing it from marker spans is how an
    // editor ends up restructuring a document that never had the shape it
    // inferred.
    for_both_formats("> c\n> d\n", |doc, format| {
        assert_eq!(doc.line_prefix(2).expect("prefix"), Some(0..2), "{format:?}");
        assert_eq!(doc.line_prefix(6).expect("prefix"), None, "{format:?}");
    });
}

#[test]
fn a_caret_at_a_blocks_end_is_in_that_block_in_both_formats() {
    // The divergence this API exists for. Djot ends a paragraph's span
    // AFTER its newline and Markdown BEFORE it, so under half-open
    // containment offset 1 — the caret you get by pressing End on line one,
    // the commonest caret position there is — resolved to the paragraph
    // through Djot and to the root through Markdown.
    for_both_formats("a\n\nb\n", |doc, format| {
        for offset in [0usize, 1, 3, 4] {
            let hit = doc
                .node_at_caret(offset)
                .expect("caret hit")
                .expect("some node");
            assert_eq!(hit.kind, Kind::Str, "{format:?} at {offset}");
        }
        // The blank line between the two blocks belongs to neither, and
        // neither does the empty line after the final newline.
        for offset in [2usize, 5] {
            let hit = doc
                .node_at_caret(offset)
                .expect("caret hit")
                .expect("some node");
            assert_eq!(hit.kind, Kind::Doc, "{format:?} at {offset}");
        }
    });
}

#[test]
fn the_caret_chain_ends_at_the_node_the_scalar_call_returns() {
    for_both_formats("- a\n", |doc, format| {
        let hit = doc.node_at_caret(3).expect("hit").expect("some node");
        let chain = doc.ancestors_at_caret(3).expect("chain");
        assert_eq!(chain.last().map(|m| m.node_id), Some(hit.node_id), "{format:?}");
        // And the chain passes through the item, which is what a gesture
        // scoped to "the block I'm in" needs at a caret sitting at its end.
        assert!(
            chain.iter().any(|m| m.kind == Kind::ListItem),
            "{format:?}: chain should reach the list item"
        );
    });
}

#[test]
fn continuation_prefix_repeats_a_quote_and_indents_past_an_item() {
    for_both_formats("> - a\n", |doc, format| {
        // The bytes already on the line, and the bytes a continuation would
        // need. They differ exactly where an editor gets it wrong by hand:
        // the item's `- ` is PRESENT and must not be repeated, or the
        // continuation opens a second item instead of continuing the first.
        assert_eq!(doc.line_prefix(4).expect("prefix"), Some(0..4), "{format:?}");
        let cont = doc.continuation_prefix(4).expect("continuation");
        assert_eq!(cont.text, ">   ", "{format:?}");
        assert_eq!(cont.columns, 4, "{format:?}");
    });
}

#[test]
fn continuation_prefix_answers_on_a_line_that_opens_nothing() {
    // The case `line_prefix` declines. Each ancestor answers from its own
    // opening line, so the quote's marker is still found on line one.
    for_both_formats("> c\n> d\n", |doc, format| {
        assert_eq!(doc.line_prefix(6).expect("prefix"), None, "{format:?}");
        assert_eq!(
            doc.continuation_prefix(6).expect("continuation").text,
            "> ",
            "{format:?}"
        );
    });
}

#[test]
fn continuation_prefix_takes_an_ordered_markers_own_width() {
    // `10. ` is four columns where `1. ` is three. A fixed indent is the
    // assumption that makes Tab wrong on the tenth item.
    for_both_formats("10. x\n", |doc, format| {
        assert_eq!(
            doc.continuation_prefix(4).expect("continuation").columns,
            4,
            "{format:?}"
        );
    });
    for_both_formats("1. x\n", |doc, format| {
        assert_eq!(
            doc.continuation_prefix(3).expect("continuation").columns,
            3,
            "{format:?}"
        );
    });
}

#[test]
fn a_blank_line_keeps_a_quote_alive_and_drops_an_items_indent() {
    for_both_formats("> - a\n", |doc, format| {
        let blank = doc.blank_line_prefix(4).expect("blank");
        // `>` and not `> `: the space after the marker is content indent,
        // and a blank line has no content.
        assert_eq!(blank.text, ">", "{format:?}");
        assert_eq!(blank.columns, 1, "{format:?}");
    });
    // Inside a list alone there is nothing to keep alive, so a blank line
    // carries nothing at all.
    for_both_formats("- a\n", |doc, format| {
        assert_eq!(doc.blank_line_prefix(3).expect("blank").text, "", "{format:?}");
    });
}

#[test]
fn a_prefix_column_count_is_not_its_byte_length() {
    // A tab in a marker advances to a tab stop, so the two diverge — which
    // is why `columns` is carried rather than left to the caller to infer.
    let mut doc = Document::parse("-	x
".as_bytes(), common::markdown()).expect("parse");
    let cont = doc.continuation_prefix(2).expect("continuation");
    assert_eq!(cont.columns, 4);
}

#[test]
fn set_block_opens_a_heading_on_a_blank_line() {
    for format in [common::markdown(), common::djot()] {
        let mut ed = Editor::new("a\n\n".as_bytes(), format).expect("editor");
        ed.set_block(3, BlockKind::Heading(2)).expect("set_block");
        assert_eq!(ed.source().expect("source"), b"a\n\n## ", "{format:?}");
        // The reparse is the assertion that matters, not the bytes: Djot
        // does not let a heading interrupt a paragraph, so a marker written
        // without the separating blank would come back as literal text.
        let nodes = ed.nodes().expect("nodes");
        assert!(
            nodes.iter().any(|n| n.kind == Kind::Heading),
            "{format:?}: should have parsed a heading"
        );
    }
}

#[test]
fn set_block_refuses_a_blank_line_inside_a_code_block() {
    // `innermostBlock` reports nothing here exactly as it does between
    // blocks; only the line's owner tells them apart. Writing `# ` in would
    // add no heading and corrupt the listing.
    for format in [common::markdown(), common::djot()] {
        let src = "```\nx\n\ny\n```\n";
        let mut ed = Editor::new(src.as_bytes(), format).expect("editor");
        let blank = src.find("\n\n").expect("a blank line") + 1;
        assert!(
            matches!(
                ed.set_block(blank, BlockKind::Heading(1)),
                Err(Error::NotEditable)
            ),
            "{format:?}"
        );
        assert_eq!(ed.source().expect("source"), src.as_bytes(), "{format:?}");
    }
}

#[test]
fn task_items_report_their_checkbox_state() {
    // Twig would WRITE a checkbox and not read one back, so a consumer
    // rendering a clickable box re-derived the state by scanning for `[x]`.
    // A capital `[X]` is checked too, which that scan misses.
    for_both_formats("- [ ] a\n- [x] b\n- [X] c\n- d\n", |doc, format| {
        let nodes = doc.nodes().expect("nodes");
        let states: Vec<Option<bool>> = nodes
            .iter()
            .filter(|n| matches!(n.kind, Kind::TaskListItem | Kind::ListItem))
            .map(|n| n.checked)
            .collect();
        assert_eq!(
            states,
            vec![Some(false), Some(true), Some(true), None],
            "{format:?}"
        );

        // `None` is not `Some(false)`: a consumer treating "not a task
        // item" as unchecked draws an empty box beside every paragraph.
        for n in nodes.iter().filter(|n| n.kind == Kind::Para) {
            assert_eq!(n.checked, None, "{format:?}");
        }
    });
}

#[test]
fn an_editor_reaches_the_caret_reads_through_its_document_view() {
    // The path an editing host actually takes. These reads are questions
    // about a TREE, not about an editing session, so they live on the
    // document surface and an editor borrows it — no `twig_editor_*` alias
    // to keep in step. See DESIGN.md, "The reads are not editor-specific."
    let mut ed = Editor::new("- a\n".as_bytes(), common::markdown()).expect("editor");
    let mut view = ed.document().expect("document view");

    assert_eq!(view.line_prefix(3).expect("prefix"), Some(0..2));
    let hit = view.node_at_caret(3).expect("hit").expect("some node");
    assert_eq!(hit.kind, Kind::Str);
}

#[test]
fn container_origin_is_none_for_non_containers() {
    // The field is a container's, so everything else reports `None` rather
    // than a default that would read as a real answer.
    let mut ed = Editor::new("# hi\n\npara\n".as_bytes(), common::markdown()).expect("editor");
    for n in ed.nodes().expect("nodes") {
        assert_eq!(n.origin, None, "{} should carry no origin", n.kind);
    }
}

#[test]
fn flat_nodes_expose_directive_name_and_form() {
    // All three surface forms report `kind == "container"`, so the snapshot
    // has to carry both halves of a directive's identity: which type it is
    // (`name`) and how it was written (`directive_form`). Without them a
    // renderer can't tell an `::embed` from a `::toc`, nor an inline span
    // from a standalone block.
    let src = ":::note{.warning}\nBody\n:::\n\n::embed{src=\"demo.html\"}\n\nSee :abbr[HTML]{title=\"HyperText\"} inline.\n";
    let mut ed = common::new_ext(
        src.as_bytes(),
        common::markdown(),
        twig_markdown::Extensions {
            directives: true,
            ..Default::default()
        },
    )
    .expect("editor");
    let nodes = ed.nodes().expect("nodes");

    let forms: Vec<(Option<&str>, Option<DirectiveForm>)> = nodes
        .iter()
        .filter(|n| n.kind == Kind::Container)
        .map(|n| (n.name.as_deref(), n.directive_form))
        .collect();
    assert_eq!(
        forms,
        vec![
            (Some("note"), Some(DirectiveForm::Container)),
            (Some("embed"), Some(DirectiveForm::Leaf)),
            (Some("abbr"), Some(DirectiveForm::Text)),
        ]
    );

    // The attributes still ride the ordinary side-table, and a non-directive
    // reports no form at all.
    let embed = nodes
        .iter()
        .find(|n| n.name.as_deref() == Some("embed"))
        .expect("embed");
    assert_eq!(
        embed.attrs,
        vec![("src".to_string(), Some("demo.html".to_string()))]
    );
    let para = nodes.iter().find(|n| n.kind == Kind::Para).expect("a para");
    assert!(para.directive_form.is_none() && para.name.is_none());
}

#[test]
fn editor_insert_child_and_delete() {
    let mut ed = Editor::new_str("<r><a/><c/></r>", common::xml()).expect("editor");
    ed.insert_child("0", 1, "<b/>").expect("insert_child");
    assert_eq!(ed.source_str().expect("source"), "<r><a/><b/><c/></r>");
    ed.delete("0.1").expect("delete");
    assert_eq!(ed.source_str().expect("source"), "<r><a/><c/></r>");
}

#[test]
fn editor_edits_by_selector() {
    let mut ed = Editor::new_str("# One\n\n## Two\n", common::markdown()).expect("editor");
    ed.replace("heading(\"Two\")", "## Renamed")
        .expect("replace");
    assert_eq!(ed.source_str().expect("source"), "# One\n\n## Renamed\n");
}

#[test]
fn editor_locator_errors_are_distinct() {
    let mut ed = Editor::new_str("<r><a/><a/></r>", common::xml()).expect("editor");
    assert_eq!(ed.replace("0.9", "x"), Err(Error::NotFound));
    assert_eq!(ed.replace("element", "x"), Err(Error::Ambiguous));
    assert_eq!(ed.replace("element(", "x"), Err(Error::InvalidArgument));
    // Untouched by the failed edits.
    assert_eq!(ed.source_str().expect("source"), "<r><a/><a/></r>");
}

#[test]
fn editor_reparse_break_rolls_back() {
    let mut ed = Editor::new_str("<a>ok</a>", common::xml()).expect("editor");
    assert_eq!(ed.replace_content("0", "<b>"), Err(Error::EditConflict));
    assert_eq!(ed.source_str().expect("source"), "<a>ok</a>");
}

#[test]
fn editor_leaf_content_is_not_editable() {
    let mut ed = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(ed.replace_content("0.0", "x"), Err(Error::NotEditable));
}

#[test]
fn editor_query_reflects_current_tree() {
    let mut ed = Editor::new_str("<r><a/></r>", common::xml()).expect("editor");
    ed.insert_child("0", 1, "<b/>").expect("insert_child");
    // Root <r> plus <a/> and <b/>.
    assert_eq!(ed.query("element").expect("query").len(), 3);
    let json = ed.ast_json().expect("ast_json");
    assert!(String::from_utf8_lossy(&json).contains("\"kind\": \"doc\""));
}

// ── offset-addressed editing & read-back (P0–P3) ────────────────────────

#[test]
fn editor_edit_range_types_backspaces_and_reports_change() {
    let mut ed = Editor::new_str("ab\n", common::markdown()).expect("editor");

    // Type "X" at offset 1 (a zero-width splice = an insertion).
    let c = ed.edit_range(1, 1, "X").expect("edit_range insert");
    assert_eq!(ed.source_str().unwrap(), "aXb\n");
    assert_eq!(c.old, 1..1);
    assert_eq!(c.new, 1..2);
    assert_eq!(c.delta(), 1);

    // Backspace it (delete the "X").
    let c2 = ed.edit_range(1, 2, "").expect("edit_range delete");
    assert_eq!(ed.source_str().unwrap(), "ab\n");
    assert_eq!(c2.old, 1..2);
    assert_eq!(c2.new, 1..1);
    assert_eq!(c2.delta(), -1);
}

#[test]
fn editor_edit_range_rejects_bad_ranges() {
    let mut ed = Editor::new_str("hi\n", common::markdown()).expect("editor");
    assert_eq!(ed.edit_range(0, 99, "x"), Err(Error::InvalidArgument)); // end past len
    assert_eq!(ed.edit_range(2, 1, "x"), Err(Error::InvalidArgument)); // start > end
    assert_eq!(ed.source_str().unwrap(), "hi\n"); // untouched
}

#[test]
fn editor_apply_edits_several_places_as_one_step() {
    let mut ed = Editor::new_str("one two three\n", common::markdown()).expect("editor");
    let ops = [Op::Insert("(".into()), Op::Retain(4), Op::Delete(3), Op::Insert("2".into())];
    let c = ed.apply(&ops).expect("apply");
    assert_eq!(ed.source_str().unwrap(), "(one 2 three\n");
    assert_eq!((c.old, c.new), (0..7, 0..6));
    // Read back in their one spelling: an insert before a delete at one place.
    let canonical = [Op::Insert("(".into()), Op::Retain(4), Op::Insert("2".into()), Op::Delete(3)];
    assert_eq!(ed.last_ops().unwrap(), canonical);
    assert!(ed.undo().unwrap().is_some());
    assert_eq!(ed.source_str().unwrap(), "one two three\n");
    assert_eq!(ed.undo().unwrap(), None); // the whole edit was one step
}

#[test]
fn editor_apply_refuses_ops_past_the_end_or_inside_a_character() {
    let mut ed = Editor::new_str("é\n", common::markdown()).expect("editor");
    assert_eq!(ed.apply(&[Op::Retain(4)]), Err(Error::InvalidArgument));
    assert_eq!(ed.apply(&[Op::Retain(1), Op::Insert("x".into())]), Err(Error::InvalidArgument));
    assert_eq!(ed.apply(&[Op::Delete(1)]), Err(Error::InvalidArgument));
    assert_eq!(ed.source_str().unwrap(), "é\n"); // untouched
    assert_eq!(ed.last_ops().unwrap(), vec![]); // nothing edited yet
}

#[test]
fn editor_last_ops_of_a_gesture_are_the_fewest_that_make_it() {
    let mut ed = Editor::new_str("a word here\n", common::markdown()).expect("editor");
    let c = ed.toggle_inline(2, 6, InlineKind::Strong).expect("bold");
    assert_eq!(ed.source_str().unwrap(), "a **word** here\n");
    assert_eq!((c.old, c.new), (2..6, 2..10));
    assert_eq!(
        ed.last_ops().unwrap(),
        vec![Op::Retain(2), Op::Insert("**".into()), Op::Retain(4), Op::Insert("**".into())]
    );
    // `edit_range` is the span as asked.
    ed.edit_range(0, 1, "A").expect("edit");
    assert_eq!(ed.last_ops().unwrap(), vec![Op::Insert("A".into()), Op::Delete(1)]);
}

#[test]
fn editor_with_history_off_keeps_no_steps() {
    let mut ed = Editor::new_str("a\n", common::markdown()).expect("editor");
    assert!(ed.keeps_history());
    ed.set_history(false);
    assert!(!ed.keeps_history());
    ed.edit_range(1, 1, "b").expect("edit");
    assert_eq!(ed.undo().unwrap(), None);
    assert_eq!(ed.source_str().unwrap(), "ab\n");
}

#[test]
fn op_diff_apply_and_compose_work_on_text_alone() {
    let ops = Op::diff("a word here", "a **word** here!");
    assert_eq!(
        ops,
        vec![
            Op::Retain(2),
            Op::Insert("**".into()),
            Op::Retain(4),
            Op::Insert("**".into()),
            Op::Retain(5),
            Op::Insert("!".into())
        ]
    );
    assert_eq!(Op::apply("a word here", &ops).unwrap(), "a **word** here!");
    assert_eq!(Op::apply("é", &[Op::Retain(1)]), Err(Error::InvalidArgument));
    assert_eq!(Op::apply("é", &[Op::Retain(3)]), Err(Error::InvalidArgument));

    let then = [Op::Retain(4), Op::Delete(4)]; // "word" goes
    let both = Op::compose("a word here", &ops, &then).unwrap();
    assert_eq!(Op::apply("a word here", &both).unwrap(), "a **** here!");
    // `then` deleting half of the é `first` inserted.
    assert_eq!(Op::compose("", &[Op::Insert("é".into())], &[Op::Retain(1), Op::Delete(1)]), Err(Error::InvalidArgument));
    // ...or cutting inside one, with whole characters on either side.
    assert_eq!(Op::compose("", &[Op::Insert("éé".into())], &[Op::Retain(1), Op::Delete(2)]), Err(Error::InvalidArgument));
    // ...or inside a character `first` kept.
    assert_eq!(Op::compose("é", &[Op::Insert("a".into())], &[Op::Retain(2), Op::Delete(1)]), Err(Error::InvalidArgument));
    // `first` itself must fit the text.
    assert_eq!(Op::compose("é", &[Op::Retain(1), Op::Insert("a".into())], &[]), Err(Error::InvalidArgument));
}

#[test]
fn editor_last_change_reports_locator_ops_too() {
    let mut ed = Editor::new_str("# One\n\n## Two\n", common::markdown()).expect("editor");
    assert_eq!(ed.last_change(), None); // nothing edited yet

    ed.replace("heading(\"Two\")", "## Renamed")
        .expect("replace");
    assert_eq!(ed.source_str().unwrap(), "# One\n\n## Renamed\n");
    let c = ed.last_change().expect("a change was recorded");
    // "## Two" occupied [7,13); "## Renamed" (10 bytes) now occupies [7,17).
    assert_eq!(c.old, 7..13);
    assert_eq!(c.new, 7..17);
}

#[test]
fn editor_nodes_is_a_walkable_flat_tree() {
    let mut ed = Editor::new_str("# Hi\n\ntext\n", common::markdown()).expect("editor");
    let nodes = ed.nodes().expect("nodes");
    assert!(!nodes.is_empty());

    // Dense, index-aligned ids.
    for (i, n) in nodes.iter().enumerate() {
        assert_eq!(n.id, NodeId(i as u32));
    }
    // Exactly one root (no parent), and it's the doc.
    let roots: Vec<_> = nodes.iter().filter(|n| n.parent.is_none()).collect();
    assert_eq!(roots.len(), 1);
    assert_eq!(roots[0].kind, Kind::Doc);

    // The heading carries its level; the "Hi" text is reachable as a payload.
    let heading = nodes
        .iter()
        .find(|n| n.kind == Kind::Heading)
        .expect("a heading");
    assert_eq!(heading.level, Some(1));
    assert!(nodes.iter().any(|n| n.text.as_deref() == Some("Hi")));

    // A kind with no row/cell payload reports neither.
    assert_eq!(heading.head, None);
    assert_eq!(heading.alignment, None);

    // Every non-root node's parent links back to a node that lists it as a
    // child (via first_child/next_sibling).
    for n in nodes.iter().filter(|n| n.parent.is_some()) {
        let p = &nodes[n.parent.unwrap().0 as usize];
        let mut kid = p.first_child;
        let mut seen = false;
        while let Some(NodeId(k)) = kid {
            if k == n.id.0 {
                seen = true;
                break;
            }
            kid = nodes[k as usize].next_sibling;
        }
        assert!(
            seen,
            "node {:?} not found among its parent's children",
            n.id
        );
    }
}

#[test]
fn editor_child_spans_and_subtree_agree_with_nodes() {
    let src = "# Title\n\nHello **world** and more.\n\n- one\n- two\n";
    let mut ed = Editor::new_str(src, common::markdown()).expect("editor");
    let all = ed.nodes().expect("nodes");
    let doc = all.iter().find(|n| n.kind == Kind::Doc).expect("doc");

    // child_spans(None) == the doc root's children, same ids/kinds/spans and
    // in the same order.
    let top = ed.child_spans(None).expect("child_spans");
    let mut want = Vec::new();
    let mut c = doc.first_child;
    while let Some(id) = c {
        want.push(id);
        c = all[id.0 as usize].next_sibling;
    }
    assert_eq!(top.len(), want.len(), "top-level count");
    for (m, id) in top.iter().zip(&want) {
        assert_eq!(m.node_id, id.0, "child id");
        assert_eq!(m.kind, all[id.0 as usize].kind, "child kind");
        assert_eq!(m.span, all[id.0 as usize].span, "child span");
    }
    // The span addresses the block as written (absolute offsets).
    assert!(
        src[top[0].span.clone()].starts_with('#'),
        "first block is the heading"
    );

    // child_spans works below the top level too.
    let list = top
        .iter()
        .find(|m| {
            matches!(
                m.kind,
                Kind::BulletList | Kind::OrderedList | Kind::TaskList
            )
        })
        .expect("a list");
    let items = ed.child_spans(Some(NodeId(list.node_id))).expect("items");
    assert_eq!(items.len(), 2);
    assert!(
        items.iter().all(|m| m.kind == Kind::ListItem),
        "items: {items:?}"
    );

    // subtree(para) is self-contained, local-indexed, and spans stay absolute.
    let para = top
        .iter()
        .find(|m| m.kind == Kind::Para)
        .expect("a para")
        .node_id;
    let sub = ed.subtree(NodeId(para)).expect("subtree");
    assert_eq!(sub[0].id, NodeId(0), "root is local id 0");
    assert_eq!(sub[0].parent, None, "root has no parent inside the subtree");
    assert_eq!(sub[0].next_sibling, None, "root's sibling is severed");
    assert_eq!(sub[0].kind, Kind::Para);
    for (i, n) in sub.iter().enumerate() {
        assert_eq!(n.id, NodeId(i as u32), "dense local ids");
        for link in [n.parent, n.first_child, n.next_sibling]
            .into_iter()
            .flatten()
        {
            assert!(
                (link.0 as usize) < sub.len(),
                "link {link:?} escapes the subtree"
            );
        }
    }
    assert!(
        src[sub[0].span.clone()].starts_with("Hello"),
        "absolute span: {:?}",
        &src[sub[0].span.clone()]
    );

    // Same multiset of node kinds as the paragraph's arena subtree.
    fn arena_kinds(all: &[FlatNode], root: NodeId) -> Vec<Kind> {
        let mut out = Vec::new();
        let mut stack = vec![root];
        while let Some(id) = stack.pop() {
            let n = &all[id.0 as usize];
            out.push(n.kind.clone());
            let mut c = n.first_child;
            while let Some(cid) = c {
                stack.push(cid);
                c = all[cid.0 as usize].next_sibling;
            }
        }
        out
    }
    let mut want_kinds = arena_kinds(&all, NodeId(para));
    let mut got_kinds: Vec<Kind> = sub.iter().map(|n| n.kind.clone()).collect();
    // Sorted by NAME: `Kind` is deliberately not `Ord` (there is no
    // meaningful order over a vocabulary), and this only needs a canonical
    // one to compare two multisets.
    want_kinds.sort_by(|a, b| a.as_str().cmp(b.as_str()));
    got_kinds.sort_by(|a, b| a.as_str().cmp(b.as_str()));
    assert_eq!(got_kinds, want_kinds, "subtree kinds match the arena");

    // Out-of-range id is rejected.
    assert!(matches!(
        ed.subtree(NodeId(9999)),
        Err(Error::InvalidArgument)
    ));
}

#[test]
fn flat_nodes_carry_table_head_and_alignment() {
    // The delimiter row (`|:-----|----:|`) is consumed by the parser and has
    // no node of its own, so `alignment` on the cells is the only way a
    // consumer can recover the column alignment from a snapshot.
    let src = "| Name | Qty |\n|:-----|----:|\n| Pear | 3 |\n";
    let mut ed = Editor::new_str(src, common::markdown()).expect("editor");
    let nodes = ed.nodes().expect("nodes");

    let rows: Vec<_> = nodes.iter().filter(|n| n.kind == Kind::Row).collect();
    assert_eq!(rows.len(), 2, "a header row and one body row");
    assert_eq!(rows[0].head, Some(true), "first row is the header");
    assert_eq!(rows[1].head, Some(false), "second row is a body row");

    let cells: Vec<_> = nodes.iter().filter(|n| n.kind == Kind::Cell).collect();
    assert_eq!(cells.len(), 4);
    // Alignment comes from the delimiter row and applies down the column.
    assert_eq!(cells[0].alignment, Some(Alignment::Left));
    assert_eq!(cells[1].alignment, Some(Alignment::Right));
    assert_eq!(cells[2].alignment, Some(Alignment::Left));
    assert_eq!(cells[3].alignment, Some(Alignment::Right));
    // Header cells are flagged too, not just their row.
    assert_eq!(cells[0].head, Some(true));
    assert_eq!(cells[2].head, Some(false));

    // A table with no alignment spelled out reports Default — a real value,
    // distinct from the None a non-cell reports.
    let mut plain =
        Editor::new_str("| A |\n| --- |\n| b |\n", common::markdown()).expect("editor");
    let pnodes = plain.nodes().expect("nodes");
    let pcell = pnodes
        .iter()
        .find(|n| n.kind == Kind::Cell)
        .expect("a cell");
    assert_eq!(pcell.alignment, Some(Alignment::Default));
}

#[test]
fn cell_extent_reports_merged_cells_and_nothing_else() {
    let src = "<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td>b</td></tr></table>";
    let mut doc = Document::parse_str(src, common::html()).expect("parse");
    let cells: Vec<NodeId> = doc
        .nodes()
        .expect("nodes")
        .iter()
        .filter(|n| n.kind == Kind::Cell)
        .map(|n| n.id)
        .collect();
    assert_eq!(cells.len(), 2);
    assert_eq!(doc.cell_extent(cells[0]).expect("extent"), Some((2, 3)));
    // A plain cell is one square — 1, never 0.
    assert_eq!(doc.cell_extent(cells[1]).expect("extent"), Some((1, 1)));

    // A pipe table cannot express a span at all, so every cell is (1, 1).
    let mut pipe =
        Document::parse_str("| a |\n| --- |\n| b |\n", common::markdown()).expect("parse");
    let pipe_cell = pipe
        .nodes()
        .expect("nodes")
        .iter()
        .find(|n| n.kind == Kind::Cell)
        .expect("a cell")
        .id;
    assert_eq!(pipe.cell_extent(pipe_cell).expect("extent"), Some((1, 1)));

    // Not a cell at all: None, distinct from any extent.
    let root = NodeId(0);
    assert_eq!(pipe.cell_extent(root).expect("extent"), None);
}

#[test]
fn builder_add_cell_spanning_renders_colspan_and_rowspan() {
    let mut b = Builder::new().expect("builder");
    let wide_text = b.add_text(TextKind::Str, "wide").expect("str");
    let wide = b
        .add_cell_spanning(false, Alignment::Default, 2, 3)
        .expect("cell");
    b.set_children(wide, &[wide_text]).expect("children");
    let plain_text = b.add_text(TextKind::Str, "one").expect("str");
    let plain = b.add_cell(false, Alignment::Default).expect("cell");
    b.set_children(plain, &[plain_text]).expect("children");
    let row = b.add_row(false).expect("row");
    b.set_children(row, &[wide, plain]).expect("children");
    let table = b.add(VoidKind::Table).expect("table");
    b.set_children(table, &[row]).expect("children");

    let html = String::from_utf8(b.render_html(table).expect("html")).expect("utf-8");
    assert!(
        html.contains("<td colspan=\"2\" rowspan=\"3\">wide</td>"),
        "{html}"
    );
    // `add_cell` is the one-square case: the default extent writes nothing.
    assert!(html.contains("<td>one</td>"), "{html}");

    // A zero extent is no cell anyone can lay out.
    assert!(matches!(
        b.add_cell_spanning(false, Alignment::Default, 0, 1),
        Err(Error::InvalidArgument)
    ));
}

#[test]
fn editor_node_at_and_ancestors_hit_test_offsets() {
    let mut ed = Editor::new_str("# Hi\n\ntext\n", common::markdown()).expect("editor");

    // Offset 2 is the "H" of the heading "# Hi" [0,4).
    let m = ed
        .node_at(2)
        .expect("node_at")
        .expect("a node covers offset 2");
    assert!(m.span.contains(&2));

    // The ancestor chain is root-first and ends at the deepest (== node_at).
    let chain = ed.ancestors_at(2).expect("ancestors_at");
    assert!(!chain.is_empty());
    assert_eq!(chain[0].kind, Kind::Doc);
    assert_eq!(chain.last().unwrap().node_id, m.node_id);

    // An out-of-range offset is an error; a gap covers nothing deeper than doc.
    assert_eq!(ed.node_at(999), Err(Error::InvalidArgument));
}

// ── range-oriented rich-text ops (P5) ───────────────────────────────────

#[test]
fn editor_wrap_and_toggle_inline_round_trip() {
    let mut ed = Editor::new_str("a word b\n", common::markdown()).expect("editor");

    // Bold "word" [2,6); the Change reports the new "**word**" region.
    let c = ed.wrap_range(2, 6, InlineKind::Strong).expect("wrap");
    assert_eq!(ed.source_str().unwrap(), "a **word** b\n");
    assert_eq!(&ed.source_str().unwrap()[c.new.clone()], "**word**");

    // Toggle it off by selecting the strong node's interior [4,8).
    ed.toggle_inline(4, 8, InlineKind::Strong)
        .expect("toggle off");
    assert_eq!(ed.source_str().unwrap(), "a word b\n");

    // Toggle emphasis on when the range isn't already marked.
    ed.toggle_inline(2, 6, InlineKind::Emph).expect("toggle on");
    assert_eq!(ed.source_str().unwrap(), "a *word* b\n");
}

#[test]
fn editor_inline_marks_cut_at_block_boundaries() {
    // One pair per block, not one pair straddling the blank line — which
    // would reparse as four literal asterisks and no mark.
    let mut ed = Editor::new_str("one two\n\nthree four\n", common::markdown())
        .expect("editor");
    let c = ed.toggle_inline(0, 19, InlineKind::Strong).expect("toggle on");
    assert_eq!(
        ed.source_str().unwrap(),
        "**one two**\n\n**three four**\n"
    );

    // One splice, so one Change spanning the lot and one undo step — the
    // whole reason the pieces are assembled before anything is written.
    assert_eq!(&ed.source_str().unwrap()[c.new.clone()], "**one two**\n\n**three four**");
    ed.undo().expect("undo");
    assert_eq!(ed.source_str().unwrap(), "one two\n\nthree four\n");

    // And the second press removes both, rather than nesting a second pair
    // around each.
    ed.toggle_inline(0, 19, InlineKind::Strong).expect("toggle on");
    ed.toggle_inline(0, 27, InlineKind::Strong).expect("toggle off");
    assert_eq!(ed.source_str().unwrap(), "one two\n\nthree four\n");

    // A range with nowhere in it to put a mark says so.
    let mut fenced = Editor::new_str("```\nx y\n```\n", common::markdown()).expect("editor");
    assert_eq!(
        fenced.toggle_inline(4, 7, InlineKind::Strong),
        Err(Error::NotEditable)
    );
}

#[test]
fn editor_inline_kind_support_is_format_specific() {
    // Markdown has no highlight/mark spelling.
    let mut md = Editor::new_str("a word b\n", common::markdown()).expect("editor");
    assert_eq!(
        md.wrap_range(2, 6, InlineKind::Mark),
        Err(Error::UnsupportedFormat)
    );

    // Djot spells it {=…=}.
    let mut dj = Editor::new_str("a word b\n", common::djot()).expect("editor");
    dj.wrap_range(2, 6, InlineKind::Mark).expect("djot mark");
    assert_eq!(dj.source_str().unwrap(), "a {=word=} b\n");
}

#[test]
fn editor_authors_gfm_strikethrough_out_of_the_box() {
    // The extension that defaults ON, so the default editor is the one
    // that can write it — the opposite direction from `highlight` below,
    // and no flag on this side turns it off.
    assert!(common::markdown().supports(Gesture::ToggleInline(InlineKind::Delete)));
    let mut ed = Editor::new_str("a word b\n", common::markdown()).expect("editor");
    ed.toggle_inline(2, 6, InlineKind::Delete).expect("strike");
    assert_eq!(ed.source_str().unwrap(), "a ~~word~~ b\n");
    ed.toggle_inline(4, 8, InlineKind::Delete).expect("unstrike");
    assert_eq!(ed.source_str().unwrap(), "a word b\n");
}

#[test]
fn editor_highlight_is_authorable_with_the_extension_on() {
    let exts = twig_markdown::Extensions {
        highlight: true,
        ..Default::default()
    };
    // The same format and the same gesture, answered two ways: `==x==` is
    // text under default options and a mark under `highlight`, so the
    // toggle refuses in one and reverses in the other.
    assert!(!common::markdown().supports(Gesture::ToggleInline(InlineKind::Mark)));
    assert!(common::markdown().supports_flags(common::flags(exts), Gesture::ToggleInline(InlineKind::Mark)));

    let mut ed =
        common::new_ext(b"a word b\n", common::markdown(), exts).expect("editor");
    ed.toggle_inline(2, 6, InlineKind::Mark).expect("highlight");
    assert_eq!(ed.source_str().unwrap(), "a ==word== b\n");
    ed.toggle_inline(4, 8, InlineKind::Mark).expect("unhighlight");
    assert_eq!(ed.source_str().unwrap(), "a word b\n");
}

#[test]
fn editor_set_mark_color_writes_reads_and_clears_the_colour() {
    let exts = twig_markdown::Extensions {
        highlight: true,
        highlight_colors: true,
        ..Default::default()
    };
    assert!(common::markdown().supports_flags(common::flags(exts), Gesture::SetMarkColor));
    // The narrower gate: highlights alone do not buy a palette.
    let hi_only = twig_markdown::Extensions {
        highlight: true,
        ..Default::default()
    };
    assert!(!common::markdown().supports_flags(common::flags(hi_only), Gesture::SetMarkColor));
    assert!(!common::markdown().supports(Gesture::SetMarkColor));
    assert!(!common::djot().supports_flags(common::flags(exts), Gesture::SetMarkColor));

    let mut ed =
        common::new_ext("a ==word== b\n".as_bytes(), common::markdown(), exts).expect("editor");
    ed.set_mark_color(6, Some(MarkColor::Red)).expect("colour");
    assert_eq!(ed.source_str().unwrap(), "a ==\u{1F534} word== b\n");

    // And it is queryable as the attribute it is, not as text.
    let mut doc =
        common::parse_with(ed.source_str().unwrap().as_bytes(), common::markdown(), exts)
            .expect("parse");
    assert_eq!(doc.query("mark[data-color=red]").expect("query").len(), 1);

    ed.set_mark_color(9, Some(MarkColor::Blue)).expect("recolour");
    assert_eq!(ed.source_str().unwrap(), "a ==\u{1F535} word== b\n");
    ed.set_mark_color(9, None).expect("clear");
    assert_eq!(ed.source_str().unwrap(), "a ==word== b\n");

    // A caret outside any highlight edits nothing.
    assert_eq!(
        ed.set_mark_color(0, Some(MarkColor::Red)),
        Err(Error::NotEditable)
    );
    assert_eq!(ed.source_str().unwrap(), "a ==word== b\n");

    // The names are the attribute values, both ways.
    for c in [
        MarkColor::Red,
        MarkColor::Orange,
        MarkColor::Yellow,
        MarkColor::Green,
        MarkColor::Blue,
        MarkColor::Purple,
        MarkColor::Brown,
    ] {
        assert_eq!(MarkColor::from_str(c.as_str()), Some(c));
    }
    assert_eq!(MarkColor::from_str("pink"), None);
}

#[test]
fn editor_toggle_strips_verbatim_via_content_span() {
    let mut ed = Editor::new_str("a `code` b\n", common::markdown()).expect("editor");
    // The verbatim node [2,8) reports content_span [3,7); toggle peels it.
    ed.toggle_inline(2, 8, InlineKind::Verbatim)
        .expect("toggle code off");
    assert_eq!(ed.source_str().unwrap(), "a code b\n");

    // A multi-backtick span peels BOTH runs via content_span, not by
    // stripping a single delimiter (which would corrupt it to "`x`").
    let mut ed2 = Editor::new_str("a ``x`` b\n", common::markdown()).expect("editor");
    ed2.toggle_inline(2, 7, InlineKind::Verbatim)
        .expect("toggle multi off");
    assert_eq!(ed2.source_str().unwrap(), "a x b\n");
}

#[test]
fn editor_set_block_switches_para_and_heading_levels() {
    let mut ed = Editor::new_str("Title\n\nbody text\n", common::markdown()).expect("editor");

    // Paragraph -> H2 (offset 0 is inside "Title").
    ed.set_block(0, BlockKind::Heading(2)).expect("to h2");
    assert_eq!(ed.source_str().unwrap(), "## Title\n\nbody text\n");

    // H2 -> H1 (offset now inside "## Title").
    ed.set_block(3, BlockKind::Heading(1)).expect("to h1");
    assert_eq!(ed.source_str().unwrap(), "# Title\n\nbody text\n");

    // Heading -> paragraph, dropping the marker.
    ed.set_block(2, BlockKind::Paragraph).expect("to para");
    assert_eq!(ed.source_str().unwrap(), "Title\n\nbody text\n");
}

#[test]
fn editor_set_block_rejects_bad_level_and_format() {
    let mut md = Editor::new_str("hi\n", common::markdown()).expect("editor");
    assert_eq!(
        md.set_block(0, BlockKind::Heading(9)),
        Err(Error::InvalidArgument)
    );

    let mut xml = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(
        xml.set_block(1, BlockKind::Heading(1)),
        Err(Error::UnsupportedFormat)
    );
}

#[test]
fn editor_toggle_block_container_round_trips() {
    let mut ed = Editor::new_str("a\n", common::djot()).expect("editor");

    let c = ed
        .toggle_block_container(0, 1, BlockContainerKind::BlockQuote)
        .expect("quote on");
    assert_eq!(ed.source_str().unwrap(), "> a\n");
    assert_eq!(&ed.source_str().unwrap()[c.new.clone()], "> a\n");

    ed.toggle_block_container(2, 3, BlockContainerKind::BlockQuote)
        .expect("quote off");
    assert_eq!(ed.source_str().unwrap(), "a\n");
}

#[test]
fn editor_toggle_block_container_nests_a_partial_selection() {
    let mut ed = Editor::new_str("> a\n>\n> b\n", common::djot()).expect("editor");

    // Only the first paragraph is covered, so the quote is not fully
    // selected: nest rather than drag `b` out of the quote too.
    ed.toggle_block_container(2, 3, BlockContainerKind::BlockQuote)
        .expect("nest");
    assert_eq!(ed.source_str().unwrap(), "> > a\n>\n> b\n");

    // Peel the inner level back off, leaving the outer quote intact.
    ed.toggle_block_container(4, 5, BlockContainerKind::BlockQuote)
        .expect("peel");
    assert_eq!(ed.source_str().unwrap(), "> a\n>\n> b\n");
}

#[test]
fn editor_toggle_block_container_numbers_and_converts_lists() {
    let mut ed = Editor::new_str("a\n\nb\n", common::djot()).expect("editor");

    // Each covered block becomes its own numbered item.
    ed.toggle_block_container(0, 4, BlockContainerKind::OrderedList)
        .expect("ordered on");
    assert_eq!(ed.source_str().unwrap(), "1. a\n\n2. b\n");

    // The other list kind converts in place instead of nesting.
    ed.toggle_block_container(3, 9, BlockContainerKind::BulletList)
        .expect("convert");
    assert_eq!(ed.source_str().unwrap(), "- a\n\n- b\n");
}

#[test]
fn editor_toggle_block_container_rejects_unspellable_format() {
    let mut xml = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(
        xml.toggle_block_container(3, 5, BlockContainerKind::BlockQuote),
        Err(Error::UnsupportedFormat)
    );
}

#[test]
fn editor_insert_link_wraps_and_repoints() {
    let mut ed = Editor::new_str("a word b\n", common::djot()).expect("editor");

    ed.insert_link(2, 6, "http://x.dev").expect("link");
    assert_eq!(ed.source_str().unwrap(), "a [word](http://x.dev) b\n");

    // A caret inside the existing link re-points it rather than nesting.
    ed.insert_link(3, 7, "http://y.dev").expect("re-point");
    assert_eq!(ed.source_str().unwrap(), "a [word](http://y.dev) b\n");
}

#[test]
fn editor_insert_link_repoints_an_autolink() {
    // The regression: an autolink is a `url`/`email` node whose text IS its
    // destination. Read as ordinary text, a caret inside it spliced a whole
    // new link into the middle of the old URL —
    // `see <https<https://y.dev>://x.dev> ok`.
    for format in [common::markdown(), common::djot()] {
        let mut ed = Editor::new_str("see <https://x.dev> ok\n", format).expect("editor");
        ed.insert_link(10, 10, "https://y.dev").expect("re-point");
        assert_eq!(ed.source_str().unwrap(), "see <https://y.dev> ok\n");

        // Source that looks right can still parse wrong: assert the reparse.
        let nodes = ed.nodes().expect("nodes");
        let url = nodes
            .iter()
            .find(|n| n.kind == Kind::Url)
            .expect("still an autolink");
        assert_eq!(url.text.as_deref(), Some("https://y.dev"));
        assert!(!nodes.iter().any(|n| n.kind == Kind::Link));
    }
}

#[test]
fn editor_insert_link_escapes_the_destination() {
    // Unescaped, the `)` would close the link early and spill `b` into the
    // paragraph as literal text.
    let mut dj = Editor::new_str("w\n", common::djot()).expect("editor");
    dj.insert_link(0, 1, "a)b").expect("link");
    assert_eq!(dj.source_str().unwrap(), "[w](a\\)b)\n");

    // Whitespace is where the formats part ways: Markdown needs the angle
    // form (a bare space ends the destination and kills the link outright),
    // Djot must NOT use it (it would link to the literal text `<a b>`).
    let mut md = Editor::new_str("w\n", common::markdown()).expect("editor");
    md.insert_link(0, 1, "a b").expect("link");
    assert_eq!(md.source_str().unwrap(), "[w](<a b>)\n");

    let mut dj2 = Editor::new_str("w\n", common::djot()).expect("editor");
    dj2.insert_link(0, 1, "a b").expect("link");
    assert_eq!(dj2.source_str().unwrap(), "[w](a b)\n");
}

#[test]
fn editor_insert_image_escapes_the_destination_per_format() {
    // The whole point of the op: a caller's `![](my cat.png)` is not an image
    // in Markdown, and the correct repair differs by format.
    let mut md = Editor::new_str("w\n", common::markdown()).expect("editor");
    md.insert_image(0, 1, "my cat.png").expect("image");
    assert_eq!(md.source_str().unwrap(), "![w](<my cat.png>)\n");

    let mut dj = Editor::new_str("w\n", common::djot()).expect("editor");
    dj.insert_image(0, 1, "my cat.png").expect("image");
    assert_eq!(dj.source_str().unwrap(), "![w](my cat.png)\n");

    // A `)` would close the image early and spill the rest as literal text.
    let mut paren = Editor::new_str("w\n", common::djot()).expect("editor");
    paren.insert_image(0, 1, "a)b.png").expect("image");
    assert_eq!(paren.source_str().unwrap(), "![w](a\\)b.png)\n");
}

#[test]
fn editor_insert_image_keeps_an_empty_alt_empty() {
    // Unlike a link, where an empty range spells an autolink or doubles the
    // destination as text — an image with no alt is ordinary.
    let mut ed = Editor::new_str("ab\n", common::markdown()).expect("editor");
    ed.insert_image(1, 1, "cat.png").expect("image");
    assert_eq!(ed.source_str().unwrap(), "a![](cat.png)b\n");
}

#[test]
fn editor_insert_image_rejects_a_newline_destination() {
    let mut ed = Editor::new_str("w\n", common::djot()).expect("editor");
    assert_eq!(
        ed.insert_image(0, 1, "a\nb.png"),
        Err(Error::InvalidArgument)
    );

    let mut xml = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(
        xml.insert_image(3, 5, "x.png"),
        Err(Error::UnsupportedFormat)
    );
}

#[test]
fn editor_insert_link_rejects_a_newline_destination() {
    let mut ed = Editor::new_str("w\n", common::djot()).expect("editor");
    assert_eq!(ed.insert_link(0, 1, "a\nb"), Err(Error::InvalidArgument));

    let mut xml = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(xml.insert_link(3, 5, "u"), Err(Error::UnsupportedFormat));
}

#[test]
fn editor_insert_literal_keeps_typed_specials_literal() {
    for format in [common::markdown(), common::djot()] {
        let mut ed = Editor::new_str("z\n", format).expect("editor");
        // A `*` at a line start would open emphasis unescaped.
        ed.insert_literal(0, "*hi*").expect("literal");

        // Source that looks right can still parse wrong: assert the reparse.
        let nodes = ed.nodes().expect("nodes");
        assert!(
            !nodes
                .iter()
                .any(|n| n.kind == Kind::Emph || n.kind == Kind::Strong)
        );
        let text: String = nodes
            .iter()
            .filter(|n| n.kind == Kind::Str)
            .filter_map(|n| n.text.clone())
            .collect();
        assert_eq!(text, "*hi*z");
    }
}

#[test]
fn editor_insert_literal_escapes_block_markers_only_at_line_start() {
    // Mid-line, a `#` opens nothing and is left as typed.
    let mut ed = Editor::new_str("az\n", common::markdown()).expect("editor");
    ed.insert_literal(1, "# ").expect("literal");
    assert_eq!(ed.source_str().unwrap(), "a# z\n");

    // At a line start it would open a heading, so it is escaped.
    let mut ed2 = Editor::new_str("z\n", common::markdown()).expect("editor");
    ed2.insert_literal(0, "# ").expect("literal");
    assert_eq!(ed2.source_str().unwrap(), "\\# z\n");
    assert!(
        !ed2.nodes()
            .expect("nodes")
            .iter()
            .any(|n| n.kind == Kind::Heading)
    );
}

#[test]
fn editor_insert_literal_escapes_a_dollar_only_under_math() {
    // Under the math extension `$` opens a formula, so it is escaped.
    let exts = twig_markdown::Extensions { math: true, ..Default::default() };
    let mut ed = common::new_ext(b"a \n", common::markdown(), exts).expect("editor");
    ed.insert_literal(2, "$x$ and $$y$$").expect("literal");
    assert_eq!(ed.source_str().unwrap(), "a \\$x\\$ and \\$\\$y\\$\\$\n");

    // Without it a `$` is text, and stays bare.
    let mut plain = Editor::new_str("a \n", common::markdown()).expect("editor");
    plain.insert_literal(2, "$x$ and $$y$$").expect("literal");
    assert_eq!(plain.source_str().unwrap(), "a $x$ and $$y$$\n");
}

#[test]
fn editor_insert_literal_rejects_bad_offset_and_parse_only_format() {
    let mut ed = Editor::new_str("ab\n", common::markdown()).expect("editor");
    assert_eq!(ed.insert_literal(99, "x"), Err(Error::InvalidArgument));

    let mut xml = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(xml.insert_literal(3, "x"), Err(Error::UnsupportedFormat));
}

#[test]
fn editor_insert_line_break_splices_in_cell_br() {
    let mut ed =
        Editor::new_str("| a | b |\n| --- | --- |\n", common::markdown()).expect("editor");
    // Caret just after `a` in the header cell.
    ed.insert_line_break(3).expect("line break");
    assert_eq!(ed.source_str().unwrap(), "| a<br> | b |\n| --- | --- |\n");
    // The break reads back as a semantic node, not raw HTML.
    let nodes = ed.nodes().expect("nodes");
    assert!(nodes.iter().any(|n| n.kind == Kind::HardBreak));
    assert!(!nodes.iter().any(|n| n.kind == Kind::RawInline));
}

#[test]
fn editor_insert_line_break_rejects_off_cell_off_format_and_bad_offset() {
    // Not inside a cell → NotFound.
    let mut para = Editor::new_str("just text\n", common::markdown()).expect("editor");
    assert_eq!(para.insert_line_break(3), Err(Error::NotFound));

    // Djot has no in-cell break spelling → UnsupportedFormat.
    let mut dj = Editor::new_str("| a | b |\n| --- | --- |\n", common::djot()).expect("editor");
    assert_eq!(dj.insert_line_break(3), Err(Error::UnsupportedFormat));

    // Out-of-range offset → InvalidArgument.
    let mut ed =
        Editor::new_str("| a | b |\n| --- | --- |\n", common::markdown()).expect("editor");
    assert_eq!(ed.insert_line_break(9999), Err(Error::InvalidArgument));
}

#[test]
fn editor_insert_thematic_break_is_blank_separated_per_format() {
    // The blank line above is load-bearing, not cosmetic: flush against the
    // paragraph, Markdown's `---` is a setext underline and the paragraph
    // becomes an <h2>. So assert the reparsed KIND, not just the bytes.
    let mut md = Editor::new_str("a\n", common::markdown()).expect("editor");
    md.insert_thematic_break(0).expect("rule");
    assert_eq!(md.source_str().unwrap(), "a\n\n---\n");
    let nodes = md.nodes().expect("nodes");
    assert!(nodes.iter().any(|n| n.kind == Kind::ThematicBreak));
    assert!(!nodes.iter().any(|n| n.kind == Kind::Heading));

    // Djot spells the same construct differently — the reason the spelling
    // is the library's and not the caller's.
    let mut dj = Editor::new_str("a\n", common::djot()).expect("editor");
    dj.insert_thematic_break(0).expect("rule");
    assert_eq!(dj.source_str().unwrap(), "a\n\n* * *\n");

    let mut xml = Editor::new_str("<a>hi</a>", common::xml()).expect("editor");
    assert_eq!(xml.insert_thematic_break(3), Err(Error::UnsupportedFormat));
}

#[test]
fn editor_insert_table_writes_an_editable_table_after_the_block() {
    let mut md = Editor::new_str("a\n", common::markdown()).expect("editor");
    md.insert_table(0, 1, 2).expect("table");
    assert_eq!(md.source_str().unwrap(), "a\n\n|  |  |\n| --- | --- |\n|  |  |\n");
    // What was minted is what the table edits read back.
    md.table_insert_row(4, true).expect("row");
    assert_eq!(
        md.source_str().unwrap(),
        "a\n\n|  |  |\n| --- | --- |\n|  |  |\n|  |  |\n"
    );

    let mut dj = Editor::new_str("a\n", common::djot()).expect("editor");
    dj.insert_table(0, 1, 2).expect("table");
    assert_eq!(dj.source_str().unwrap(), "a\n\n|  |  |\n|---|---|\n|  |  |\n");

    let mut md = Editor::new_str("a\n", common::markdown()).expect("editor");
    assert_eq!(md.insert_table(0, 0, 2), Err(Error::InvalidArgument));
    assert_eq!(md.insert_table(0, 1, 0), Err(Error::InvalidArgument));
    assert_eq!(md.source_str().unwrap(), "a\n");

    let mut html = Editor::new_str("<p>ab</p>\n", common::html()).expect("editor");
    assert_eq!(html.insert_table(4, 1, 1), Err(Error::UnsupportedFormat));
    assert!(!common::html().supports(Gesture::InsertTable));
    assert!(common::markdown().supports(Gesture::InsertTable));
}

#[test]
fn editor_split_block_keeps_both_halves_the_same_kind() {
    // A list item's halves are both items — the marker is repeated, so the
    // second half doesn't fall out of the list as a paragraph.
    let mut item = Editor::new_str("- this is a list item\n", common::markdown()).expect("editor");
    item.split_block(10).expect("split");
    assert_eq!(item.source_str().unwrap(), "- this is \n- a list item\n");
    let nodes = item.nodes().expect("nodes");
    assert_eq!(nodes.iter().filter(|n| n.kind == Kind::ListItem).count(), 2);

    // At the item's end the empty sibling IS the point — that is Enter.
    let mut tail = Editor::new_str("- a\n", common::markdown()).expect("editor");
    tail.split_block(3).expect("split");
    assert_eq!(tail.source_str().unwrap(), "- a\n- \n");

    // A paragraph divides on a blank line instead.
    let mut para = Editor::new_str("ab\n", common::markdown()).expect("editor");
    para.split_block(1).expect("split");
    assert_eq!(para.source_str().unwrap(), "a\n\nb\n");

    // A table has no honest caret-split: a newline mid-cell destroys it.
    let mut table =
        Editor::new_str("| a | b |\n|---|---|\n| c | d |\n", common::markdown()).expect("editor");
    assert_eq!(table.split_block(3), Err(Error::NotEditable));

    let mut empty = Editor::new_str("", common::markdown()).expect("editor");
    assert_eq!(empty.split_block(0), Err(Error::NotFound));
}

#[test]
fn editor_join_blocks_carries_the_markup_that_has_to_travel() {
    // The Markdown `<div>` case, which is the whole reason this is a
    // gesture: `below` joins the div's last paragraph, and the `</div>` is
    // carried past the text that came in rather than being left above it.
    let src = "above\n\n<div class=\"center\">\n\nhello\n\n</div>\n\nbelow\n";
    let exts = twig_markdown::Extensions {
        html_elements: true,
        ..Default::default()
    };
    let mut into = common::new_ext(src.as_bytes(), common::markdown(), exts).expect("editor");
    into.join_blocks(44).expect("join");
    assert_eq!(
        into.source_str().unwrap(),
        "above\n\n<div class=\"center\">\n\nhello\nbelow\n\n</div>\n"
    );
    let nodes = into.nodes().expect("nodes");
    assert_eq!(nodes.iter().filter(|n| n.kind == Kind::Para).count(), 2);

    // Out of the div instead: B leaves it, so the div's own closers go with
    // B's markup — and the paragraph's attributes go with them, because the
    // joined text is the other block's.
    let mut out_of = common::new_ext(src.as_bytes(), common::markdown(), exts).expect("editor");
    out_of.join_blocks(29).expect("join");
    assert_eq!(out_of.source_str().unwrap(), "above\nhello\n\nbelow\n");

    // A list item's continuation is spaces, not its marker: two items in,
    // one out.
    let mut item = Editor::new_str("- a\n- b\n", common::markdown()).expect("editor");
    item.join_blocks(6).expect("join");
    assert_eq!(item.source_str().unwrap(), "- a\n  b\n");
    let nodes = item.nodes().expect("nodes");
    assert_eq!(nodes.iter().filter(|n| n.kind == Kind::ListItem).count(), 1);

    // The document's first block has nothing above it.
    let mut first = Editor::new_str("above\n", common::markdown()).expect("editor");
    assert_eq!(first.join_blocks(0), Err(Error::NotFound));
}

#[test]
fn editor_move_block_spells_the_destination_prefixes() {
    // Out of a quote: the `> ` and the `>` separator line go with the
    // block, and it arrives blank-separated at the top level.
    let mut out = Editor::new_str("> a\n>\n> y\n\nb\n", common::markdown()).expect("editor");
    let change = out.move_block(8, 13).expect("move");
    assert_eq!(out.source_str().unwrap(), "> a\n\nb\n\ny\n");
    assert_eq!(change.old.start, 4);

    // Into a list item's tail: the continuation indent and the blank line
    // that makes it a second block of the item.
    let mut tail = Editor::new_str("- x\n\ny\n", common::markdown()).expect("editor");
    tail.move_block(5, 3).expect("move");
    assert_eq!(tail.source_str().unwrap(), "- x\n\n  y\n");
    let nodes = tail.nodes().expect("nodes");
    assert_eq!(nodes.iter().filter(|n| n.kind == Kind::ListItem).count(), 1);

    // A bullet's text is the bullet: the item moves whole, and between
    // two items of a tight list no blank is written.
    let mut items = Editor::new_str("- a\n  - b\n- c\n", common::markdown()).expect("editor");
    items.move_block(12, 0).expect("move");
    assert_eq!(items.source_str().unwrap(), "- c\n- a\n  - b\n");

    // Where it already is moves nothing; inside a fence is no boundary.
    let mut same = Editor::new_str("a\n\n```\nx\n```\n", common::markdown()).expect("editor");
    assert_eq!(same.move_block(0, 1), Err(Error::InvalidArgument));
    assert_eq!(same.move_block(0, 8), Err(Error::NotEditable));
    assert_eq!(same.move_block(2, 0), Err(Error::NotFound));

    // XML has no blocks a caret could name.
    let mut xml = Editor::new_str("<r><a/><b/></r>", common::xml()).expect("editor");
    assert_eq!(xml.move_block(3, 11), Err(Error::UnsupportedFormat));
}

#[test]
fn editor_join_blocks_is_spelled_in_html_where_the_split_is_not() {
    // The pair that motivates the separate gate. A blank line between two
    // `<p>`s is not what separates them, so the split refuses; a newline
    // inside one is exactly the break the join needs, and the reparse hands
    // back the single paragraph the gesture claims to have made.
    let mut ed =
        Editor::new_str("<p>a</p>\n<p class=\"x\">b</p>\n", common::html()).expect("editor");
    assert_eq!(ed.split_block(4), Err(Error::UnsupportedFormat));
    assert!(common::html().supports(Gesture::JoinBlocks));
    ed.join_blocks(22).expect("join");
    assert_eq!(ed.source_str().unwrap(), "<p>a\nb</p>\n");
    let nodes = ed.nodes().expect("nodes");
    assert_eq!(nodes.iter().filter(|n| n.kind == Kind::Para).count(), 1);

    // XML spells nothing at all, so there the refusal is the format's.
    let mut xml = Editor::new_str("<r>ab</r>", common::xml()).expect("editor");
    assert_eq!(xml.join_blocks(4), Err(Error::UnsupportedFormat));
}

#[test]
fn editor_toggle_code_block_round_trips_and_measures_the_fence() {
    let mut ed = Editor::new_str("a\n", common::markdown()).expect("editor");
    ed.toggle_code_block(0, 1, Some("zig")).expect("fence");
    assert_eq!(ed.source_str().unwrap(), "```zig\na\n```\n");
    let nodes = ed.nodes().expect("nodes");
    assert!(nodes.iter().any(|n| n.kind == Kind::CodeBlock));

    ed.toggle_code_block(0, 0, None).expect("unfence");
    assert_eq!(ed.source_str().unwrap(), "a\n");

    // Three backticks in the body would close a three-backtick fence, so the
    // fence is measured against the body rather than fixed.
    let mut runs = Editor::new_str("a ``` b\n", common::markdown()).expect("editor");
    runs.toggle_code_block(0, 7, None).expect("fence");
    assert_eq!(runs.source_str().unwrap(), "````\na ``` b\n````\n");
}

#[test]
fn editor_toggle_code_block_inside_a_list_item_keeps_the_item() {
    // The fence sits at the item's content column, with the item's marker
    // on its line, so the block stays the item's — and comes back out.
    let mut ed = Editor::new_str("- a\n- b\n", common::markdown()).expect("editor");
    ed.toggle_code_block(2, 3, None).expect("fence");
    assert_eq!(ed.source_str().unwrap(), "- ```\n  a\n  ```\n- b\n");
    ed.toggle_code_block(8, 8, None).expect("unfence");
    assert_eq!(ed.source_str().unwrap(), "- a\n- b\n");
}

#[test]
fn editor_set_code_language_retags_clears_and_refuses() {
    let mut ed = Editor::new_str("```zig\na\n```\n", common::markdown()).expect("editor");
    ed.set_code_language(0, Some("rust")).expect("retag");
    assert_eq!(ed.source_str().unwrap(), "```rust\na\n```\n");

    // `None` clears the info string; `Some("")` writes the same bytes but is
    // a different request.
    ed.set_code_language(0, None).expect("clear");
    assert_eq!(ed.source_str().unwrap(), "```\na\n```\n");
    ed.set_code_language(0, Some("")).expect("empty");
    assert_eq!(ed.source_str().unwrap(), "```\na\n```\n");

    // Markdown's info string ends at whitespace, so a space would come back
    // truncated — refused rather than silently clipped.
    assert_eq!(
        ed.set_code_language(0, Some("a b")),
        Err(Error::InvalidArgument)
    );
    // Djot's runs to the end of the line, so the same string is fine there.
    let mut dj = Editor::new_str("```\na\n```\n", common::djot()).expect("editor");
    dj.set_code_language(0, Some("a b"))
        .expect("djot info string");
    assert_eq!(dj.source_str().unwrap(), "```a b\na\n```\n");

    let mut para = Editor::new_str("x\n", common::markdown()).expect("editor");
    assert_eq!(para.set_code_language(0, Some("zig")), Err(Error::NotFound));
}

#[test]
fn editor_task_checkbox_gestures() {
    let mut ed = Editor::new_str("- a\n", common::markdown()).expect("editor");

    // The box is added by one gesture and ticked by another — adding
    // converts the item's kind, ticking only changes what the box holds.
    ed.toggle_task_item(2).expect("add box");
    assert_eq!(ed.source_str().unwrap(), "- [ ] a\n");
    assert!(
        ed.nodes()
            .unwrap()
            .iter()
            .any(|n| n.kind == Kind::TaskListItem)
    );

    ed.set_task_checked(6, true).expect("tick");
    assert_eq!(ed.source_str().unwrap(), "- [x] a\n");
    // Already checked: a no-op that still succeeds and moves nothing.
    ed.set_task_checked(6, true).expect("no-op");
    assert_eq!(ed.source_str().unwrap(), "- [x] a\n");

    ed.toggle_task_checked(6).expect("flip");
    assert_eq!(ed.source_str().unwrap(), "- [ ] a\n");

    ed.toggle_task_item(6).expect("remove box");
    assert_eq!(ed.source_str().unwrap(), "- a\n");

    // A plain bullet has no box to tick; `toggle_task_item` is how a caller
    // asks for one.
    assert_eq!(ed.set_task_checked(2, true), Err(Error::NotEditable));
    // And a caret in no list item has no item at all.
    let mut para = Editor::new_str("a\n", common::markdown()).expect("editor");
    assert_eq!(para.toggle_task_item(0), Err(Error::NotFound));
}

#[test]
fn editor_insert_footnote_writes_both_halves_as_one_edit() {
    for format in [common::markdown(), common::djot()] {
        let mut ed = Editor::new_str("see\n", format).expect("editor");
        ed.insert_footnote(3, "a").expect("footnote");
        assert_eq!(ed.source_str().unwrap(), "see[^a]\n\n[^a]: \n");

        // Half a footnote is not a footnote, so assert both nodes exist.
        let nodes = ed.nodes().expect("nodes");
        assert!(nodes.iter().any(|n| n.kind == Kind::FootnoteReference));
        assert!(nodes.iter().any(|n| n.kind == Kind::Footnote));

        // One edit, so one undo takes both halves back.
        ed.undo().expect("undo");
        assert_eq!(ed.source_str().unwrap(), "see\n");
    }
}

#[test]
fn editor_insert_footnote_reuses_an_existing_definition() {
    let mut ed = Editor::new_str("see\n", common::markdown()).expect("editor");
    ed.insert_footnote(3, "a").expect("first");
    ed.insert_footnote(7, "a").expect("second reference");
    assert_eq!(ed.source_str().unwrap(), "see[^a][^a]\n\n[^a]: \n");
    let defs = ed
        .nodes()
        .unwrap()
        .iter()
        .filter(|n| n.kind == Kind::Footnote)
        .count();
    assert_eq!(defs, 1);

    assert_eq!(ed.insert_footnote(3, ""), Err(Error::InvalidArgument));
    assert_eq!(ed.insert_footnote(3, "a]b"), Err(Error::InvalidArgument));
}

#[test]
fn editor_undo_redo_round_trip() {
    let mut ed = Editor::new_str("hello\n", common::markdown()).expect("editor");
    ed.edit_range(5, 5, "!").expect("edit");
    assert_eq!(ed.source_str().unwrap(), "hello!\n");

    let change = ed.undo().expect("undo ok").expect("something to undo");
    assert_eq!(ed.source_str().unwrap(), "hello\n");
    assert_eq!(change.new.end, 5);
    assert!(ed.undo().expect("undo ok").is_none(), "history exhausted");

    ed.redo().expect("redo ok").expect("something to redo");
    assert_eq!(ed.source_str().unwrap(), "hello!\n");
}

#[test]
fn editor_coalesce_folds_a_run() {
    let mut ed = Editor::new_str("\n", common::markdown()).expect("editor");
    ed.edit_range(0, 0, "a").expect("edit");
    ed.edit_range(1, 1, "b").expect("edit");
    ed.coalesce_last_undo().expect("coalesce");
    assert_eq!(ed.source_str().unwrap(), "ab\n");
    // One undo removes the whole coalesced run.
    ed.undo().expect("undo ok").expect("something to undo");
    assert_eq!(ed.source_str().unwrap(), "\n");
    assert!(ed.undo().expect("undo ok").is_none());
}

#[test]
fn editor_revision_bumps_per_successful_mutation() {
    let mut ed = Editor::new_str("x\n", common::markdown()).expect("editor");
    assert_eq!(ed.revision(), 0);
    ed.edit_range(1, 1, "y").expect("edit");
    assert_eq!(ed.revision(), 1);

    // A reparse-breaking edit is rolled back and must not bump the revision.
    let mut xml = Editor::new_str("<a>ok</a>", common::xml()).expect("editor");
    assert_eq!(xml.revision(), 0);
    assert!(xml.replace_content("0", "<b>").is_err());
    assert_eq!(xml.revision(), 0);

    // undo and redo are mutations too.
    ed.undo().expect("undo ok").expect("something to undo");
    assert_eq!(ed.revision(), 2);
    ed.redo().expect("redo ok").expect("something to redo");
    assert_eq!(ed.revision(), 3);
}

#[test]
fn editor_dirty_range_tracks_and_clears() {
    let mut ed = Editor::new_str("abcdefgh\n", common::markdown()).expect("editor");
    // Clean to start.
    assert_eq!(ed.dirty_range(), None);

    // One insertion of two bytes at offset 2 dirties exactly [2, 4).
    ed.edit_range(2, 2, "XY").expect("edit");
    assert_eq!(ed.dirty_range(), Some(2..4));

    // A second, disjoint edit near the end accumulates conservatively: the
    // reported range is a superset covering both edits.
    ed.edit_range(9, 9, "Z").expect("edit"); // source is now "abXYcdefgZh\n"
    let d = ed.dirty_range().expect("dirty");
    assert!(
        d.start <= 2 && d.end >= 10,
        "range {d:?} must cover both edits"
    );

    // clear_dirty acknowledges without moving the revision.
    let rev = ed.revision();
    ed.clear_dirty();
    assert_eq!(ed.dirty_range(), None);
    assert_eq!(ed.revision(), rev);

    // Post-clear, only new mutations show up — and undo counts as one.
    ed.undo().expect("undo ok").expect("something to undo");
    assert!(ed.dirty_range().is_some());
}

#[test]
fn editor_caret_blob_follows_undo_and_redo() {
    let mut ed = Editor::new_str("hello\n", common::markdown()).expect("editor");
    assert!(ed.caret_blob().unwrap().is_empty());

    // Set the pre-edit caret, then edit: the retired undo step captures it.
    ed.set_caret_blob(b"before").expect("set caret");
    ed.edit_range(5, 5, "!").expect("edit");
    // A fresh state starts caret-less until the host sets one.
    assert!(ed.caret_blob().unwrap().is_empty());
    ed.set_caret_blob(b"after").expect("set caret");

    // Undo restores the pre-edit source AND the pre-edit caret.
    ed.undo().expect("undo ok").expect("something to undo");
    assert_eq!(ed.source_str().unwrap(), "hello\n");
    assert_eq!(ed.caret_blob().unwrap(), b"before");

    // Redo restores the post-edit source AND the post-edit caret.
    ed.redo().expect("redo ok").expect("something to redo");
    assert_eq!(ed.source_str().unwrap(), "hello!\n");
    assert_eq!(ed.caret_blob().unwrap(), b"after");
}

#[test]
fn editor_coalesced_run_keeps_the_pre_run_caret() {
    let mut ed = Editor::new_str("\n", common::markdown()).expect("editor");
    ed.set_caret_blob(b"c0").expect("set caret");
    ed.edit_range(0, 0, "a").expect("edit");
    ed.set_caret_blob(b"c1").expect("set caret");
    ed.edit_range(1, 1, "b").expect("edit");
    ed.coalesce_last_undo().expect("coalesce");
    ed.set_caret_blob(b"c2").expect("set caret");

    // One undo folds the run and restores the caret from before it began.
    ed.undo().expect("undo ok").expect("something to undo");
    assert_eq!(ed.source_str().unwrap(), "\n");
    assert_eq!(ed.caret_blob().unwrap(), b"c0");
}

#[test]
fn editor_renumber_ordered_lists_fixes_a_stale_sequence() {
    let mut ed = Editor::new_str("1. a\n2. x\n2. b\n3. c\n", common::markdown()).expect("editor");
    ed.renumber_ordered_lists(0).expect("renumber ok");
    assert_eq!(ed.source_str().unwrap(), "1. a\n2. x\n3. b\n4. c\n");
}

#[test]
fn editor_renumber_ordered_lists_leaves_djot_prose_alone() {
    // Djot reads `   2. b` as text inside item `a`; Markdown reads the same
    // bytes as a nested item. The author's digit survives in the one case.
    let src = "1. a\n   2. b\n2. c\n";
    let mut dj = Editor::new_str(src, common::djot()).expect("editor");
    dj.renumber_ordered_lists(0).expect("renumber ok");
    assert_eq!(dj.source_str().unwrap(), src);

    let mut md = Editor::new_str(src, common::markdown()).expect("editor");
    md.renumber_ordered_lists(0).expect("renumber ok");
    assert_eq!(md.source_str().unwrap(), "1. a\n   1. b\n2. c\n");
}

#[test]
fn editor_renumber_ordered_lists_off_a_list_is_not_found() {
    let mut ed = Editor::new_str("a paragraph\n", common::markdown()).expect("editor");
    assert!(matches!(ed.renumber_ordered_lists(2), Err(Error::NotFound)));
}

#[test]
fn editor_table_insert_row_and_set_alignment() {
    let src = "| a | b |\n| --- | --- |\n| 1 | 2 |\n";
    let mut ed = Editor::new_str(src, common::markdown()).expect("editor");
    ed.table_insert_row(24, true).expect("insert row"); // caret in body `1`
    assert_eq!(
        ed.source_str().unwrap(),
        "| a | b |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n"
    );
    ed.table_set_alignment(6, Alignment::Center).expect("align"); // column `b`
    assert!(ed.source_str().unwrap().contains("| --- | :---: |"));
}

#[test]
fn editor_table_edit_off_a_table_is_not_found() {
    let mut ed = Editor::new_str("nope\n", common::markdown()).expect("editor");
    assert!(matches!(ed.table_delete_row(2), Err(Error::NotFound)));
}

#[test]
fn editor_set_block_converts_setext_heading() {
    // A setext heading rebuilt from its content_span collapses the underline.
    let mut ed = Editor::new_str("Title\n=====\n\nbody\n", common::markdown()).expect("editor");
    ed.set_block(0, BlockKind::Heading(1))
        .expect("setext to atx");
    assert_eq!(ed.source_str().unwrap(), "# Title\n\nbody\n");
}

#[test]
fn editor_moves_a_node_next_to_another_in_one_step() {
    let mut ed = Editor::new_str("<svg>\n  <rect/>\n  <circle/>\n</svg>\n", common::xml())
        .expect("editor");
    ed.move_after("element[name=\"rect\"]", "element[name=\"circle\"]")
        .expect("after");
    assert_eq!(
        ed.source_str().unwrap(),
        "<svg>\n  <circle/>\n  <rect/>\n</svg>\n"
    );
    ed.move_before("element[name=\"rect\"]", "element[name=\"circle\"]")
        .expect("before");
    assert_eq!(
        ed.source_str().unwrap(),
        "<svg>\n  <rect/>\n  <circle/>\n</svg>\n"
    );
    // One undo step per move.
    ed.undo().expect("undo");
    assert_eq!(
        ed.source_str().unwrap(),
        "<svg>\n  <circle/>\n  <rect/>\n</svg>\n"
    );
    assert_eq!(
        ed.move_after("element[name=\"rect\"]", "element[name=\"svg\"]"),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        ed.move_after("element[name=\"rect\"]", "element[name=\"path\"]"),
        Err(Error::NotFound)
    );
    // Markdown's blank-line separator travels the same way.
    let mut md = Editor::new_str("A\n\nB\n\nC\n", common::markdown()).expect("editor");
    md.move_after("1", "2").expect("after");
    assert_eq!(md.source_str().unwrap(), "A\n\nC\n\nB\n");
}

#[test]
fn editor_unwrap_and_smart_delete() {
    let mut ed = Editor::new_str("<r><box><b/><c/></box></r>", common::xml()).expect("editor");
    ed.unwrap_node("0.0").expect("unwrap"); // <box>
    assert_eq!(ed.source_str().expect("source"), "<r><b/><c/></r>");

    let mut md = Editor::new_str("A\n\nB\n\nC\n", common::markdown()).expect("editor");
    md.delete_smart("1").expect("delete_smart"); // the "B" paragraph
    assert_eq!(md.source_str().expect("source"), "A\n\nC\n");
}

#[test]
fn editor_directives_require_the_extension_flag() {
    let src = ":::vis{.public}\nhi\n:::\n";
    // Without the flag, the colon-fence lines are plain paragraph text —
    // no directive node.
    let mut plain = Editor::new_str(src, common::markdown()).expect("editor");
    assert_eq!(plain.query("directive").expect("query").len(), 0);
    // With it enabled, the container directive is recognized.
    let mut ext = common::new_ext(
        src.as_bytes(),
        common::markdown(),
        twig_markdown::Extensions {
            directives: true,
            ..Default::default()
        },
    )
    .expect("editor");
    assert_eq!(ext.query("directive").expect("query").len(), 1);
}

#[test]
fn editor_set_node_attrs_rewrites_an_xml_tag_by_id_and_nothing_else() {
    assert!(common::xml().supports(Gesture::SetNodeAttrs));
    assert!(!common::xml().is_authorable());
    assert!(!common::html().supports(Gesture::SetNodeAttrs));
    assert!(!common::djot().supports(Gesture::SetNodeAttrs));

    let src = "<svg>\n  <g id=\"a\">\n    <rect x=\"1\" y=\"2\"/>\n  </g>\n</svg>\n";
    let mut ed = Editor::new_str(src, common::xml()).expect("editor");
    let rect = |ed: &mut Editor| {
        ed.nodes()
            .expect("nodes")
            .into_iter()
            .find(|n| n.name.as_deref() == Some("rect"))
            .expect("a rect")
            .id
    };
    let id = rect(&mut ed);
    let change = ed
        .set_node_attrs(
            id,
            &[("x", Some("10")), ("y", Some("2")), ("fill", Some("#f00"))],
        )
        .expect("set");
    assert_eq!(
        ed.source_str().unwrap(),
        "<svg>\n  <g id=\"a\">\n    <rect x=\"10\" y=\"2\" fill=\"#f00\"/>\n  </g>\n</svg>\n"
    );
    // The change is the tag's interior alone: the `<g>` around it and the
    // whitespace runs are not re-printed.
    assert_eq!(change.old, 28..40);
    assert_eq!(change.new, 28..53);
    // Ids are the current tree's: read them again after an edit.
    let id = rect(&mut ed);
    assert_eq!(
        ed.nodes()
            .unwrap()
            .iter()
            .find(|n| n.id == id)
            .unwrap()
            .attrs,
        vec![
            ("x".to_string(), Some("10".to_string())),
            ("y".to_string(), Some("2".to_string())),
            ("fill".to_string(), Some("#f00".to_string())),
        ]
    );
    ed.set_node_attrs(id, &[]).expect("clear");
    assert_eq!(
        ed.source_str().unwrap(),
        "<svg>\n  <g id=\"a\">\n    <rect/>\n  </g>\n</svg>\n"
    );
    // A text run is no element; an id past the tree is no node; a bare
    // attribute is one no format reads back; and a prose format refuses
    // before looking.
    let text = ed
        .nodes()
        .unwrap()
        .into_iter()
        .find(|n| n.kind == Kind::Str)
        .expect("a text run")
        .id;
    assert_eq!(
        ed.set_node_attrs(text, &[("a", Some("b"))]),
        Err(Error::NotEditable)
    );
    let past = NodeId(ed.nodes().unwrap().len() as u32 + 5);
    assert_eq!(
        ed.set_node_attrs(past, &[("a", Some("b"))]),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        ed.set_node_attrs(id, &[("hidden", None)]),
        Err(Error::InvalidArgument)
    );
    let mut md = Editor::new_str("hello\n", common::markdown()).expect("editor");
    assert_eq!(
        md.set_node_attrs(NodeId(0), &[("a", Some("b"))]),
        Err(Error::UnsupportedFormat)
    );
}

#[test]
fn editor_set_block_attrs_spells_per_format_and_replaces_rather_than_merging() {
    // djot: the line before the block, rewritten in place; the block's
    // bytes are never touched.
    let mut dj = Editor::new_str("hello _em_\n", common::djot()).expect("editor");
    dj.set_block_attrs(0, &[("class", Some("center"))]).expect("class");
    assert_eq!(dj.source_str().unwrap(), "{.center}\nhello _em_\n");
    dj.set_block_attrs(12, &[("data-size", Some("large"))]).expect("size");
    assert_eq!(dj.source_str().unwrap(), "{data-size=\"large\"}\nhello _em_\n");
    dj.set_block_attrs(22, &[]).expect("clear");
    assert_eq!(dj.source_str().unwrap(), "hello _em_\n");

    // HTML: the tag; AsciiDoc: its attribute line.
    let mut html = Editor::new_str("<p>a</p>\n", common::html()).expect("editor");
    html.set_block_attrs(4, &[("class", Some("c"))]).expect("class");
    assert_eq!(html.source_str().unwrap(), "<p class=\"c\">a</p>\n");
    let mut adoc = Editor::new_str("hello\n", common::asciidoc()).expect("editor");
    adoc.set_block_attrs(0, &[("class", Some("c"))]).expect("class");
    assert_eq!(adoc.source_str().unwrap(), "[.c]\nhello\n");

    // Markdown: refused without the flag; a div with it, rewritten rather
    // than nested on a second call, unwrapped by an empty list.
    assert!(!common::markdown().supports(Gesture::SetBlockAttrs));
    let exts = twig_markdown::Extensions {
        html_elements: true,
        ..Default::default()
    };
    assert!(common::markdown().supports_flags(common::flags(exts), Gesture::SetBlockAttrs));
    let mut plain = Editor::new_str("hello\n", common::markdown()).expect("editor");
    assert_eq!(
        plain.set_block_attrs(0, &[("class", Some("c"))]),
        Err(Error::UnsupportedFormat)
    );
    let mut md = common::new_ext(b"hello\n", common::markdown(), exts).expect("editor");
    md.set_block_attrs(0, &[("class", Some("c"))]).expect("class");
    assert_eq!(md.source_str().unwrap(), "<div class=\"c\">\n\nhello\n\n</div>\n");
    md.set_block_attrs(20, &[("class", Some("d"))]).expect("reclass");
    assert_eq!(md.source_str().unwrap(), "<div class=\"d\">\n\nhello\n\n</div>\n");
    md.set_block_attrs(20, &[]).expect("clear");
    assert_eq!(md.source_str().unwrap(), "hello\n");

    // An attribute no format reads back is refused before anything is
    // written.
    assert_eq!(
        dj.set_block_attrs(0, &[("hidden", None)]),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        dj.set_block_attrs(0, &[("a b", Some("x"))]),
        Err(Error::InvalidArgument)
    );
    assert_eq!(dj.source_str().unwrap(), "hello _em_\n");
}

#[test]
fn editor_wrap_range_attrs_spells_a_span_and_re_styles_rather_than_nesting() {
    let mut dj = Editor::new_str("a big b\n", common::djot()).expect("editor");
    dj.wrap_range_attrs(2, 5, &[("class", Some("large"))]).expect("wrap");
    assert_eq!(dj.source_str().unwrap(), "a [big]{.large} b\n");
    dj.wrap_range_attrs(3, 6, &[("class", Some("small"))]).expect("re-style");
    assert_eq!(dj.source_str().unwrap(), "a [big]{.small} b\n");
    dj.wrap_range_attrs(3, 6, &[]).expect("unwrap");
    assert_eq!(dj.source_str().unwrap(), "a big b\n");

    let mut html = Editor::new_str("<p>a big b</p>\n", common::html()).expect("editor");
    html.wrap_range_attrs(5, 8, &[("class", Some("large"))]).expect("wrap");
    assert_eq!(html.source_str().unwrap(), "<p>a <span class=\"large\">big</span> b</p>\n");

    // Markdown reads the span back only under `html_elements`; AsciiDoc
    // has no spelling that keeps every key.
    assert!(!common::markdown().supports(Gesture::WrapRangeAttrs));
    assert!(!common::asciidoc().supports(Gesture::WrapRangeAttrs));
    let exts = twig_markdown::Extensions {
        html_elements: true,
        ..Default::default()
    };
    assert!(common::markdown().supports_flags(common::flags(exts), Gesture::WrapRangeAttrs));
    let mut md = common::new_ext(b"a big b\n", common::markdown(), exts).expect("editor");
    md.wrap_range_attrs(2, 5, &[("class", Some("large"))]).expect("wrap");
    assert_eq!(md.source_str().unwrap(), "a <span class=\"large\">big</span> b\n");
    let mut plain = Editor::new_str("a big b\n", common::markdown()).expect("editor");
    assert_eq!(
        plain.wrap_range_attrs(2, 5, &[("class", Some("large"))]),
        Err(Error::UnsupportedFormat)
    );
}

#[test]
fn editor_insert_directive_writes_a_directive_the_reparse_reads_back() {
    let exts = twig_markdown::Extensions {
        directives: true,
        ..Default::default()
    };
    let mut md = common::new_ext(b"a\n\nb\n", common::markdown(), exts).expect("editor");
    md.insert_directive(0, "page-break", None, &[])
        .expect("directive");
    assert_eq!(md.source_str().unwrap(), "a\n\n::page-break\n\nb\n");
    // A directive to the parser, not a paragraph that starts with colons.
    assert_eq!(md.query("directive").expect("query").len(), 1);

    // A label and an attribute, in the serializer's own spelling — the
    // value is quoted because that is what the Markdown serializer writes.
    let mut em = common::new_ext(b"a\n", common::markdown(), exts).expect("editor");
    em.insert_directive(0, "embed", Some("Contents"), &[("src", Some("x.html"))])
        .expect("directive");
    assert_eq!(
        em.source_str().unwrap(),
        "a\n\n::embed[Contents]{src=\"x.html\"}\n"
    );
    assert_eq!(em.query("directive").expect("query").len(), 1);

    // Djot's div is anonymous, so its spelling is an empty `:::` fence
    // carrying the name — which is why the gate asks about the NAME
    // surviving rather than about the syntax.
    let mut dj = Editor::new_str("a\n", common::djot()).expect("editor");
    dj.insert_directive(0, "page-break", None, &[])
        .expect("directive");
    assert_eq!(dj.source_str().unwrap(), "a\n\n::: page-break\n:::\n");

    // `None` is no label and `Some("")` is an empty one — two different
    // documents, which is the whole reason the parameter is an `Option`
    // rather than a `&str`.
    let mut none = common::new_ext(b"", common::markdown(), exts).expect("editor");
    none.insert_directive(0, "x", None, &[]).expect("directive");
    assert_eq!(none.source_str().unwrap(), "::x\n");
    let mut empty = common::new_ext(b"", common::markdown(), exts).expect("editor");
    empty
        .insert_directive(0, "x", Some(""), &[])
        .expect("directive");
    assert_eq!(empty.source_str().unwrap(), "::x[]\n");
}

#[test]
fn editor_insert_math_writes_a_formula_the_reparse_reads_back() {
    let exts = twig_markdown::Extensions {
        math: true,
        ..Default::default()
    };
    let mut md = common::new_ext(b"a  b\n", common::markdown(), exts).expect("editor");
    md.insert_inline_math(2, "x^2").expect("inline");
    assert_eq!(md.source_str().unwrap(), "a $x^2$ b\n");
    md.insert_display_math(0, "\\frac{1}{2}").expect("display");
    assert_eq!(md.source_str().unwrap(), "a $x^2$ b\n\n$$\\frac{1}{2}$$\n");

    let mut dj = Editor::new_str("a  b\n", common::djot()).expect("editor");
    dj.insert_inline_math(2, "a`b").expect("inline");
    assert_eq!(dj.source_str().unwrap(), "a $``a`b`` b\n");

    // Refusals leave the source as it was.
    assert_eq!(md.insert_inline_math(0, " x"), Err(Error::InvalidArgument));
    let mut code = common::new_ext(b"`code`\n", common::markdown(), exts).expect("editor");
    assert_eq!(code.insert_inline_math(3, "x"), Err(Error::NotEditable));
    assert_eq!(code.source_str().unwrap(), "`code`\n");

    let mut plain = Editor::new_str("a\n", common::markdown()).expect("editor");
    assert_eq!(plain.insert_inline_math(0, "x"), Err(Error::UnsupportedFormat));
    assert!(!common::markdown().supports(Gesture::InsertInlineMath));
    assert!(common::markdown().supports_flags(common::flags(exts), Gesture::InsertDisplayMath));
    assert!(common::asciidoc().supports(Gesture::InsertInlineMath));
    assert!(!common::asciidoc().supports(Gesture::InsertDisplayMath));
}

#[test]
fn editor_insert_directive_needs_the_extension_it_will_be_read_back_with() {
    // Without the flag `::page-break` is a paragraph of colons, so the
    // gesture refuses rather than minting bytes one press cannot undo.
    let mut plain = Editor::new_str("a\n", common::markdown()).expect("editor");
    assert_eq!(
        plain.insert_directive(0, "page-break", None, &[]),
        Err(Error::UnsupportedFormat)
    );
    assert_eq!(plain.source_str().unwrap(), "a\n");

    assert!(!common::markdown().supports(Gesture::InsertDirective));
    assert!(common::markdown().supports_flags(common::flags(
        twig_markdown::Extensions {
            directives: true,
            ..Default::default()
        }),
        Gesture::InsertDirective
    ));
    // Djot needs no extension; XML spells nothing at all.
    assert!(common::djot().supports(Gesture::InsertDirective));
    assert!(!common::xml().supports(Gesture::InsertDirective));

    // An empty name is the caller's error, not a nameless directive.
    let mut ext = common::new_ext(
        b"a\n",
        common::markdown(),
        twig_markdown::Extensions {
            directives: true,
            ..Default::default()
        },
    )
    .expect("editor");
    assert_eq!(
        ext.insert_directive(0, "", None, &[]),
        Err(Error::InvalidArgument)
    );
    assert_eq!(
        ext.insert_directive(0, "a\nb", None, &[]),
        Err(Error::InvalidArgument)
    );
    // A name goes where a delimiter would otherwise be, so the grammar is
    // checked rather than left to the serializer: `::a b` would reparse as
    // a paragraph holding an inline directive named `a`.
    assert_eq!(
        ext.insert_directive(0, "a b", None, &[]),
        Err(Error::InvalidArgument)
    );
    // And a bracket in the label closes the `[…]` early.
    assert_eq!(
        ext.insert_directive(0, "page-break", Some("]"), &[]),
        Err(Error::InvalidArgument)
    );
    assert_eq!(ext.source_str().unwrap(), "a\n");
}

#[test]
fn document_html_elements_make_embedded_img_queryable() {
    let src = "text <img src=\"a.png\" alt=\"x\"> more\n";
    // Without the flag, the `<img>` is opaque raw HTML — no `image` node.
    let mut plain = Document::parse_str(src, common::markdown()).expect("parse");
    assert_eq!(plain.query("image").expect("query").len(), 0);
    // With it enabled on the read path, the promoted image is queryable.
    let mut ext = common::parse_str_with(
        src,
        common::markdown(),
        twig_markdown::Extensions {
            html_elements: true,
            ..Default::default()
        },
    )
    .expect("parse");
    let images = ext.query("image").expect("query");
    assert_eq!(images.len(), 1);
    assert_eq!(images[0].kind, Kind::Image);
}

#[test]
fn editor_filter_public_audience_view() {
    let src = "# Archive\n\n:::vis{.public}\nPublic.\n:::\n\n:::vis{.family}\nPrivate.\n:::\n";
    let mut ed = common::new_ext(
        src.as_bytes(),
        common::markdown(),
        twig_markdown::Extensions {
            directives: true,
            ..Default::default()
        },
    )
    .expect("editor");
    // Drop every vis block except the public one, then unwrap it.
    ed.filter(
        "directive[name=vis]",
        Some("directive[class~=public]"),
        true,
    )
    .expect("filter");
    assert_eq!(ed.source_str().expect("source"), "# Archive\n\nPublic.\n");
}

#[test]
fn editor_filter_rejects_a_malformed_selector() {
    let mut ed = Editor::new_str("hi\n", common::markdown()).expect("editor");
    assert_eq!(
        ed.filter("list >", None, false),
        Err(Error::InvalidArgument)
    );
}

#[test]
fn builder_builds_and_renders_a_document() {
    let mut b = Builder::new().expect("builder");

    // # Title\n\nhello *world*
    let title = b.add_text(TextKind::Str, "Title").unwrap();
    let heading = b.add_heading(1).unwrap();
    b.set_children(heading, &[title]).unwrap();

    let hello = b.add_text(TextKind::Str, "hello ").unwrap();
    let world = b.add_text(TextKind::Str, "world").unwrap();
    let emph = b.add(VoidKind::Emph).unwrap();
    b.set_children(emph, &[world]).unwrap();
    let para = b.add(VoidKind::Para).unwrap();
    b.set_children(para, &[hello, emph]).unwrap();

    let doc = b.add(VoidKind::Doc).unwrap();
    b.set_children(doc, &[heading, para]).unwrap();

    let html = String::from_utf8(b.render_html(doc).unwrap()).unwrap();
    assert!(html.contains("<h1>Title</h1>"), "{html}");
    assert!(html.contains("<em>world</em>"), "{html}");

    let md = String::from_utf8(b.serialize(doc, common::markdown()).unwrap()).unwrap();
    assert!(md.contains("# Title"), "{md}");
    assert!(md.contains("*world*"), "{md}");

    let matches = b.query(doc, "heading").unwrap();
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].kind, Kind::Heading);

    let json = String::from_utf8(b.ast_json(doc).unwrap()).unwrap();
    assert!(json.contains("\"kind\": \"doc\""), "{json}");
}

#[test]
fn builder_element_with_attributes() {
    let mut b = Builder::new().expect("builder");
    let inner = b.add_text(TextKind::Str, "hi").unwrap();
    let el = b.add_element("section").unwrap();
    b.set_children(el, &[inner]).unwrap();
    b.set_attrs(el, &[("class", Some("note")), ("hidden", None)])
        .unwrap();

    let html = String::from_utf8(b.render_html(el).unwrap()).unwrap();
    assert!(html.contains("<section"), "{html}");
    assert!(html.contains("class=\"note\""), "{html}");
    assert!(html.contains("hidden"), "{html}");
}

#[test]
fn builder_lists_round_trip_to_markdown() {
    let mut b = Builder::new().expect("builder");

    // An ordered list: 1. one / 2. two
    let one_txt = b.add_text(TextKind::Str, "one").unwrap();
    let one_para = b.add(VoidKind::Para).unwrap();
    b.set_children(one_para, &[one_txt]).unwrap();
    let one = b.add(VoidKind::ListItem).unwrap();
    b.set_children(one, &[one_para]).unwrap();

    let two_txt = b.add_text(TextKind::Str, "two").unwrap();
    let two_para = b.add(VoidKind::Para).unwrap();
    b.set_children(two_para, &[two_txt]).unwrap();
    let two = b.add(VoidKind::ListItem).unwrap();
    b.set_children(two, &[two_para]).unwrap();

    let list = b
        .add_ordered_list(
            OrderedNumbering::Decimal,
            OrderedDelim::Period,
            true,
            Some(1),
        )
        .unwrap();
    b.set_children(list, &[one, two]).unwrap();
    let doc = b.add(VoidKind::Doc).unwrap();
    b.set_children(doc, &[list]).unwrap();

    let md = String::from_utf8(b.serialize(doc, common::markdown()).unwrap()).unwrap();
    assert!(md.contains("1. one"), "{md}");
    assert!(md.contains("2. two"), "{md}");
}

#[test]
fn builder_rejects_invalid_kind_and_id() {
    let mut b = Builder::new().expect("builder");
    // ported: the raw-code guard on `add` (a payload kind through the void
    // entry point) is unrepresentable without the C layer — `VoidKind` has no
    // such variant. The id guards are what remains observable.

    // A root id past the end can't be rendered.
    assert_eq!(b.render_html(NodeId(4242)), Err(Error::InvalidArgument));
    assert_eq!(b.serialize_to(NodeId(4242), common::djot().target()), Err(Error::InvalidArgument));
    assert_eq!(b.ast_json(NodeId(4242)), Err(Error::InvalidArgument));
    assert_eq!(b.query(NodeId(4242), "str"), Err(Error::InvalidArgument));
    let p = b.add(VoidKind::Para).unwrap();
    assert_eq!(b.set_children(p, &[NodeId(99)]), Err(Error::InvalidArgument));
    assert_eq!(b.set_children(NodeId(99), &[p]), Err(Error::InvalidArgument));
    assert_eq!(b.set_attrs(NodeId(99), &[]), Err(Error::InvalidArgument));
}

// ── Format capability ───────────────────────────────────────────────────

/// Every gesture with a format-level gate, both kind vocabularies in full.
fn all_gestures() -> Vec<Gesture> {
    let inline = [
        InlineKind::Strong,
        InlineKind::Emph,
        InlineKind::Verbatim,
        InlineKind::Mark,
        InlineKind::Superscript,
        InlineKind::Subscript,
        InlineKind::Insert,
        InlineKind::Delete,
    ];
    let mut all: Vec<Gesture> = Vec::new();
    for k in inline {
        all.push(Gesture::WrapRange(k));
        all.push(Gesture::ToggleInline(k));
    }
    for k in [
        BlockContainerKind::BlockQuote,
        BlockContainerKind::BulletList,
        BlockContainerKind::OrderedList,
    ] {
        all.push(Gesture::ToggleBlockContainer(k));
    }
    all.extend([
        Gesture::SetMarkColor,
        Gesture::SetBlock,
        Gesture::InsertThematicBreak,
        Gesture::ToggleCodeBlock,
        Gesture::SetCodeLanguage,
        Gesture::ToggleTaskItem,
        Gesture::SetTaskChecked,
        Gesture::ToggleTaskChecked,
        Gesture::InsertLink,
        Gesture::InsertImage,
        Gesture::InsertFootnote,
        Gesture::InsertLiteral,
        Gesture::InsertLineBreak,
        Gesture::SplitBlock,
        Gesture::RenumberOrderedLists,
        Gesture::TableInsertRow,
        Gesture::TableDeleteRow,
        Gesture::TableInsertColumn,
        Gesture::TableDeleteColumn,
        Gesture::TableSetAlignment,
        Gesture::TableMoveRow,
        Gesture::TableMoveColumn,
        Gesture::InsertTable,
        Gesture::InsertDirective,
        Gesture::SetBlockAttrs,
        Gesture::WrapRangeAttrs,
        Gesture::JoinBlocks,
        Gesture::SetNodeAttrs,
        Gesture::MoveBlock,
        Gesture::InsertInlineMath,
        Gesture::InsertDisplayMath,
        Gesture::ToggleLineBlock,
    ]);
    all
}

#[test]
fn the_wire_space_ends_where_the_sweep_does() {
    // ported: the C wire codes (`to_c`, `twig_format_supports`) are gone with
    // the C layer. What stays checkable is that the sweep names every
    // gesture once — 35 of them, the wire's 0..=34 — and that each one gets
    // an answer from every compiled format without panicking.
    let all = all_gestures();
    let mut shapes: Vec<String> =
        all.iter().map(|g| format!("{g:?}").split('(').next().unwrap().to_string()).collect();
    shapes.sort();
    shapes.dedup();
    assert_eq!(shapes.len(), 35);
    for (i, a) in all.iter().enumerate() {
        assert!(!all[i + 1..].contains(a), "{a:?} listed twice");
    }
    for fmt in [
        common::djot(),
        common::markdown(),
        common::xml(),
        common::html(),
        common::asciidoc(),
        common::commonmark(),
        common::gfm(),
        common::svg(),
    ] {
        for g in &all {
            let _ = fmt.supports(*g);
            let _ = fmt.supports_flags(common::flags(twig_markdown::Extensions::default()), *g);
        }
    }
}

#[test]
fn supports_answers_per_gesture_where_authorable_cannot() {
    // HTML is why the per-gesture query exists. `is_authorable` is true for
    // it — it spells the inline marks, and every block its parser reads
    // back through a renderer — while a toolbar built on that predicate
    // would show a task-box button and a footnote button that both fail.
    assert!(common::html().is_authorable());
    assert!(common::html().supports(Gesture::ToggleInline(InlineKind::Strong)));
    assert!(common::html().supports(Gesture::SetBlock));
    assert!(common::html().supports(Gesture::InsertLiteral));
    assert!(common::html().supports(Gesture::ToggleBlockContainer(
        BlockContainerKind::BlockQuote
    )));
    assert!(common::html().supports(Gesture::ToggleCodeBlock));
    assert!(common::html().supports(Gesture::InsertLink));
    assert!(!common::html().supports(Gesture::ToggleTaskItem));
    assert!(!common::html().supports(Gesture::InsertFootnote));
    // The nine that used to answer nothing at all: HTML has a table its
    // parser reads and no spelling to write one back with, no blank-line
    // block separation, and no numbered list marker.
    assert!(!common::html().supports(Gesture::TableInsertRow));
    assert!(!common::html().supports(Gesture::TableSetAlignment));
    assert!(!common::html().supports(Gesture::SplitBlock));
    // And the one that goes the other way, which is why the join has a gate
    // of its own: HTML cannot be split at a blank line and *can* be joined
    // at a newline inside its `<p>`.
    assert!(common::html().supports(Gesture::JoinBlocks));
    // And the block move, whose lines HTML has like any other format.
    assert!(common::html().supports(Gesture::MoveBlock));
    assert!(!common::html().supports(Gesture::RenumberOrderedLists));
    assert!(common::markdown().supports(Gesture::TableInsertRow));
    assert!(common::djot().supports(Gesture::SplitBlock));

    // A format that spells no prose answers false to every caret gesture,
    // so the coarse predicate agrees there — it only misleads in the middle
    // of the range. The one gesture XML (and its svg dialect) supports is
    // the node-addressed one, which no caret asks for and `is_authorable`
    // deliberately does not count.
    for fmt in [common::xml(), common::svg()] {
        assert!(!fmt.is_authorable());
        for g in all_gestures() {
            assert_eq!(
                fmt.supports(g),
                g == Gesture::SetNodeAttrs,
                "{fmt:?} on {g:?}"
            );
        }
    }
    // AsciiDoc is in the middle of the range the other way round from
    // HTML: the block gestures work, a link prints through its renderer,
    // the footnote/table shapes don't.
    assert!(common::asciidoc().is_authorable());
    assert!(common::asciidoc().supports(Gesture::SetBlock));
    assert!(common::asciidoc().supports(Gesture::ToggleInline(InlineKind::Mark)));
    assert!(common::asciidoc().supports(Gesture::InsertLink));
    assert!(!common::asciidoc().supports(Gesture::InsertFootnote));
    assert!(!common::asciidoc().supports(Gesture::TableInsertRow));

    // And the two authorable formats differ from each other, which is the
    // other half of why one boolean can't serve.
    assert!(common::djot().supports(Gesture::ToggleInline(InlineKind::Mark)));
    assert!(!common::markdown().supports(Gesture::ToggleInline(InlineKind::Mark)));
    assert!(common::markdown().supports(Gesture::InsertLineBreak));
    assert!(!common::djot().supports(Gesture::InsertLineBreak));
}

#[test]
fn supports_agrees_with_what_the_editor_then_does() {
    // The pin at this layer: for the gestures whose refusal an `Editor`
    // can be made to demonstrate, the query's answer is the call's answer.
    // Zig covers the full (format x gesture) sweep; what's checked here is
    // that the Rust decode reaches the same question.
    for fmt in [common::djot(), common::markdown(), common::html()] {
        let mut ed = Editor::new_str("ab\n", fmt).expect("editor");
        let claimed = fmt.supports(Gesture::ToggleInline(InlineKind::Mark));
        let observed = ed.toggle_inline(0, 2, InlineKind::Mark);
        assert_eq!(
            claimed,
            !matches!(observed, Err(Error::UnsupportedFormat)),
            "{fmt:?}: supports said {claimed}, gesture said {observed:?}",
        );

        let mut ed = Editor::new_str("ab\n", fmt).expect("editor");
        let claimed = fmt.supports(Gesture::SetBlock);
        let observed = ed.set_block(0, BlockKind::Heading(1));
        assert_eq!(
            claimed,
            !matches!(observed, Err(Error::UnsupportedFormat)),
            "{fmt:?}: supports said {claimed}, gesture said {observed:?}",
        );
    }

    // The destructive one, spelled out: an HTML `<table>` extracts as a grid
    // and cannot be written back, so the refusal has to arrive before
    // anything is spliced. A `Ok(())` here once meant a destroyed table.
    let src = "<table><tr><td>a</td></tr></table>";
    let mut ed = Editor::new_str(src, common::html()).expect("editor");
    assert!(!common::html().supports(Gesture::TableInsertRow));
    assert_eq!(ed.table_insert_row(15, true), Err(Error::UnsupportedFormat));
    assert_eq!(ed.renumber_ordered_lists(15), Err(Error::UnsupportedFormat));
    assert!(matches!(ed.split_block(15), Err(Error::UnsupportedFormat)));
    // The join is spelled in HTML, so its refusal here is about the caret
    // being in a table — a different answer, from a different gate.
    assert_eq!(ed.join_blocks(15), Err(Error::NotEditable));
    assert_eq!(ed.source().expect("source"), src.as_bytes());
}

#[test]
fn supports_rides_the_gestures_own_kind_space() {
    // ported: the `(gesture, kind)` wire pairs and the C side's rejection of
    // mismatched ones are gone with the C layer; the Rust types make the
    // mismatches unrepresentable. The per-kind answers are what remain.
    assert!(common::markdown().supports(Gesture::ToggleBlockContainer(BlockContainerKind::BulletList)));
    assert!(common::markdown().supports(Gesture::ToggleInline(InlineKind::Emph)));
    assert!(!common::markdown().supports(Gesture::ToggleInline(InlineKind::Superscript)));
    assert!(common::markdown().supports(Gesture::InsertLink));
}

#[test]
fn toggle_line_block_makes_a_verse_whose_lines_report_their_indent() {
    let exts = twig_markdown::Extensions {
        html_elements: true,
        ..Default::default()
    };
    assert!(!common::markdown().supports(Gesture::ToggleLineBlock));
    assert!(common::markdown().supports_flags(common::flags(exts), Gesture::ToggleLineBlock));
    assert!(common::djot().supports(Gesture::ToggleLineBlock));
    assert!(!common::html().supports(Gesture::ToggleLineBlock));

    let mut ed = common::new_ext("One\n\u{2003}two\n".as_bytes(), common::markdown(), exts).expect("editor");
    ed.toggle_line_block(0, 0).expect("toggle on");
    assert_eq!(
        ed.source_str().expect("source"),
        "<div class=\"verse\">\n\nOne\\\n\u{2003}two\n\n</div>\n"
    );
    let nodes = ed.nodes().expect("nodes");
    let levels: Vec<Option<u32>> = nodes.iter().filter(|n| n.kind == Kind::Line).map(|n| n.level).collect();
    assert_eq!(levels, vec![None, Some(1)]);

    ed.toggle_line_block(0, 0).expect("toggle off");
    assert_eq!(ed.source_str().expect("source"), "One\n\u{2003}two\n");

    let mut plain = Editor::new("One\n".as_bytes(), common::markdown()).expect("editor");
    assert_eq!(plain.toggle_line_block(0, 0), Err(Error::UnsupportedFormat));
}
