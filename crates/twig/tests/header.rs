//! The behavioural assertions of `bindings/c/test/header_test.c`, restated
//! over the Rust API. The C test pins two things: that its constants compile
//! (gone with the C layer) and that the library does what the codes say —
//! which is what is ported here, where `tests/binding.rs` does not already
//! cover it. The runtime-language half (`twig_language_register`, the
//! server) belongs to the runtime layer's tests.

mod common;

use twig::*;

#[test]
fn abi_version_matches_header() {
    assert_eq!(abi_version(), ABI_VERSION);
    assert_eq!(ABI_VERSION, 6);
}

#[test]
fn markdown_dialect_codes_match_runtime() {
    let src = "a ~~b~~ c\n";
    assert!(!common::commonmark().supports(Gesture::ToggleInline(InlineKind::Delete)));
    assert!(common::gfm().supports(Gesture::ToggleInline(InlineKind::Delete)));

    let mut doc = Document::parse_str(src, common::gfm()).unwrap();
    assert_eq!(doc.query("delete").unwrap().len(), 1);
    assert_eq!(doc.serialize(common::gfm()).unwrap(), src.as_bytes());

    let mut doc = Document::parse_str(src, common::commonmark()).unwrap();
    assert_eq!(doc.query("delete").unwrap().len(), 0);

    // The wire codes the C header pins, which `Format::code` still reports.
    assert_eq!(common::djot().code(), 1);
    assert_eq!(common::svg().code(), 8);
    assert!(common::svg().code() < 4096);
    assert_eq!(common::asciidoc().target().code(), 5);
}

#[test]
fn line_prefixes_answer_two_different_questions() {
    let src = "> - a\n";
    let mut doc = Document::parse_str(src, common::markdown()).unwrap();

    let span = doc.line_prefix(4).unwrap().expect("a prefix");
    assert_eq!(span, 0..4);
    assert_eq!(&src[span], "> - ");

    // The quote reproduced, the item as width; the same column count.
    let cont = doc.continuation_prefix(4).unwrap();
    assert_eq!(cont, LinePrefix { text: ">   ".into(), columns: 4 });

    // A blank line keeps the quote alive and drops the item's indent.
    let blank = doc.blank_line_prefix(4).unwrap();
    assert_eq!(blank, LinePrefix { text: ">".into(), columns: 1 });

    assert_eq!(doc.line_prefix(src.len() + 1), Err(Error::InvalidArgument));
    assert_eq!(doc.continuation_prefix(src.len() + 1), Err(Error::InvalidArgument));
}

#[test]
fn task_items_report_their_checkbox_state() {
    let src = "- [ ] a\n- [x] b\n- [X] c\n- d\n";
    let mut doc = Document::parse_str(src, common::markdown()).unwrap();
    let nodes = doc.nodes().unwrap();
    let (mut checked, mut unchecked, mut plain, mut other) = (0, 0, 0, 0);
    for n in &nodes {
        match n.kind {
            Kind::TaskListItem => match n.checked {
                Some(true) => checked += 1,
                Some(false) => unchecked += 1,
                None => other += 1,
            },
            Kind::ListItem => {
                plain += 1;
                assert_eq!(n.checked, None);
            }
            _ => {
                if n.checked.is_some() {
                    other += 1;
                }
            }
        }
    }
    assert_eq!((checked, unchecked, plain, other), (2, 1, 1, 0));
}

#[test]
fn definitions_are_reachable_only_through_their_own_call() {
    let src = "text[^1]\n\n[^1]: note\n";
    let mut doc = Document::parse_str(src, common::markdown()).unwrap();
    let parentless = doc.nodes().unwrap().iter().filter(|n| n.parent.is_none()).count();
    assert_eq!(parentless, 2);
    let defs = doc.definitions().unwrap();
    assert_eq!(defs.len(), 1);
    assert_eq!(defs[0].kind, Kind::Footnote);
}

#[test]
fn diagnostics_report_what_a_conversion_loses() {
    let mut doc = Document::parse_str("a^b^ c\n", common::djot()).unwrap();
    let warnings = doc.diagnostics(common::markdown().target()).unwrap();
    assert_eq!(
        warnings,
        vec![Warning { fidelity: Fidelity::Degraded, path: "0/1".into(), kind: Kind::Superscript }]
    );
    assert_eq!(doc.diagnostics(common::djot().target()).unwrap(), vec![]);
    assert_eq!(doc.diagnostics(common::xml().target()), Err(Error::UnsupportedFormat));

    // A node that survives while its attributes do not.
    let mut doc2 = Document::parse_str("{.center}\nhello\n", common::djot()).unwrap();
    let warnings = doc2.diagnostics(common::markdown().target()).unwrap();
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].fidelity, Fidelity::AttrsDegraded);
    assert_eq!(warnings[0].kind, Kind::Para);
    assert_eq!(doc2.diagnostics(common::html().target()).unwrap(), vec![]);
}

#[test]
fn align_codes_match_runtime() {
    let src = "| a | b | c | d |\n| :- | -: | :-: | - |\n| 1 | 2 | 3 | 4 |\n";
    let mut ed = Editor::new_str(src, common::markdown()).unwrap();
    let nodes = ed.nodes().unwrap();
    let seen: Vec<Option<Alignment>> = nodes.iter().filter(|n| n.kind == Kind::Cell).take(4).map(|n| n.alignment).collect();
    assert_eq!(
        seen,
        vec![Some(Alignment::Left), Some(Alignment::Right), Some(Alignment::Center), Some(Alignment::Default)]
    );
    let table = nodes.iter().find(|n| n.kind == Kind::Table).expect("a table");
    assert_eq!(table.alignment, None);
    assert_eq!(table.head, None);
}

#[test]
fn cell_extent_accessors() {
    let src = "<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td>b</td></tr></table>";
    let mut doc = Document::parse_str(src, common::html()).unwrap();
    let cells: Vec<NodeId> = doc.nodes().unwrap().iter().filter(|n| n.kind == Kind::Cell).map(|n| n.id).collect();
    assert_eq!(cells.len(), 2);
    assert_eq!(doc.cell_extent(cells[0]).unwrap(), Some((2, 3)));
    assert_eq!(doc.cell_extent(cells[1]).unwrap(), Some((1, 1)));
    // A non-cell is `None`; an id past the tree is an error.
    assert_eq!(doc.cell_extent(NodeId(0)).unwrap(), None);
    assert_eq!(doc.cell_extent(NodeId(u32::MAX - 1)), Err(Error::InvalidArgument));
}

#[test]
fn editor_document_shares_the_read_surface() {
    let mut ed = Editor::new_str("# one\n\ntwo\n", common::markdown()).unwrap();
    let heading;
    {
        let mut view = ed.document().unwrap();
        let kids = view.children(None).unwrap();
        assert_eq!(kids.len(), 2);
        assert_eq!(kids[0].kind, Kind::Heading);
        heading = NodeId(kids[0].node_id);
        assert_eq!(view.span(heading).unwrap(), 0..5);

        let flat = view.nodes().unwrap();
        assert!(flat.len() >= 3);
        let sub = view.subtree(heading).unwrap();
        assert!(!sub.is_empty() && sub[0].id == NodeId(0) && sub[0].parent.is_none());

        let hit = view.node_at(2).unwrap().expect("a node");
        let chain = view.ancestors_at(2).unwrap();
        assert!(chain.len() >= 2);
        assert_eq!(chain.last().unwrap().node_id, hit.node_id);

        assert_eq!(view.marker_span(heading).unwrap(), Some(0..2));
        assert_eq!(flat[heading.0 as usize].marker_span, Some(0..2));
        assert_eq!(view.line_prefix(2).unwrap(), Some(0..2));
        assert_eq!(view.continuation_prefix(2).unwrap(), LinePrefix::default());

        let caret_hit = view.node_at_caret(2).unwrap().expect("a node");
        let caret_chain = view.ancestors_at_caret(2).unwrap();
        assert!(caret_chain.len() >= 2);
        assert_eq!(caret_chain.last().unwrap().node_id, caret_hit.node_id);

        // The two methods a view cannot serve.
        assert_eq!(view.render_html(), Err(Error::UnsupportedFormat));
        assert_eq!(view.serialize(common::markdown()), Err(Error::UnsupportedFormat));
    }

    // After an edit a fresh view reads the current tree.
    let replacement = "# one and a half";
    ed.replace("0", replacement).unwrap();
    let mut view = ed.document().unwrap();
    assert_eq!(view.span(heading).unwrap().end, replacement.len());
}

#[test]
fn new_block_gestures_link_and_edit() {
    let mut ed = Editor::new_str("- a\n", common::markdown()).unwrap();
    ed.toggle_task_item(2).unwrap();
    ed.set_task_checked(6, true).unwrap();
    assert_eq!(ed.source_str().unwrap(), "- [x] a\n");
    // Ticking again is the documented no-op.
    ed.set_task_checked(6, true).unwrap();
    assert_eq!(ed.source_str().unwrap(), "- [x] a\n");

    ed.insert_thematic_break(6).unwrap();
    assert_eq!(ed.insert_table(6, 0, 2), Err(Error::InvalidArgument));
    ed.insert_table(6, 1, 2).unwrap();
    ed.insert_footnote(7, "a").unwrap();
    assert!(ed.source().unwrap().len() > 8);
    // Created without directives, so `::page-break` is refused.
    assert_eq!(ed.insert_directive(6, "page-break", None, &[]), Err(Error::UnsupportedFormat));

    // Math, under the flag that makes `$` open a formula.
    let math_exts = twig_markdown::Extensions { math: true, ..Default::default() };
    let mut math = common::new_ext(b"a  b\n", common::markdown(), math_exts).unwrap();
    math.insert_inline_math(2, "x").unwrap();
    math.insert_display_math(0, "y").unwrap();
    assert_eq!(math.source_str().unwrap(), "a $x$ b\n\n$$y$$\n");
    assert_eq!(math.insert_inline_math(0, "x "), Err(Error::InvalidArgument));

    // Directives with the flag on: a label and an attribute.
    let dir_exts = twig_markdown::Extensions { directives: true, ..Default::default() };
    let mut dir = common::new_ext(b"a\n", common::markdown(), dir_exts).unwrap();
    dir.insert_directive(0, "embed", Some("Contents"), &[("src", Some("x.html"))]).unwrap();
    assert_eq!(dir.source_str().unwrap(), "a\n\n::embed[Contents]{src=\"x.html\"}\n");
    // An empty label is not no label.
    dir.insert_directive(0, "x", Some(""), &[]).unwrap();
    assert_eq!(dir.source_str().unwrap(), "a\n\n::x[]\n\n::embed[Contents]{src=\"x.html\"}\n");

    // Block attributes need html_elements.
    assert_eq!(dir.set_block_attrs(0, &[("class", Some("center"))]), Err(Error::UnsupportedFormat));
    let attr_exts = twig_markdown::Extensions { html_elements: true, ..Default::default() };
    let mut attr_ed = common::new_ext(b"hello\n", common::markdown(), attr_exts).unwrap();
    attr_ed.set_block_attrs(0, &[("class", Some("center"))]).unwrap();
    assert_eq!(attr_ed.source_str().unwrap(), "<div class=\"center\">\n\nhello\n\n</div>\n");
    attr_ed.wrap_range_attrs(22, 27, &[("class", Some("large"))]).unwrap();
    assert_eq!(
        attr_ed.source_str().unwrap(),
        "<div class=\"center\">\n\n<span class=\"large\">hello</span>\n\n</div>\n"
    );

    // A node's attributes, by id: XML only.
    assert!(common::xml().supports(Gesture::SetNodeAttrs));
    assert!(!common::xml().supports(Gesture::SetBlockAttrs));
    assert!(!common::markdown().supports(Gesture::SetNodeAttrs));
    let mut svg = Editor::new_str("<svg><rect x=\"1\"/></svg>", common::svg()).unwrap();
    let rect = svg.nodes().unwrap().into_iter().find(|n| n.name.as_deref() == Some("rect")).unwrap().id;
    svg.set_node_attrs(rect, &[("x", Some("10")), ("fill", Some("red"))]).unwrap();
    assert_eq!(svg.source_str().unwrap(), "<svg><rect x=\"10\" fill=\"red\"/></svg>");
    svg.set_node_attrs(rect, &[]).unwrap();
    assert_eq!(svg.source_str().unwrap(), "<svg><rect/></svg>");
    svg.insert_after("0.0", "<circle/>").unwrap();
    svg.move_after("0.0", "0.1").unwrap();
    assert_eq!(svg.source_str().unwrap(), "<svg><circle/><rect/></svg>");
    svg.move_before("0.1", "0.0").unwrap();
    assert_eq!(svg.source_str().unwrap(), "<svg><rect/><circle/></svg>");
    assert_eq!(svg.move_after("0.0", "0"), Err(Error::InvalidArgument));

    // Directive names and labels.
    assert_eq!(dir.insert_directive(0, "", None, &[]), Err(Error::InvalidArgument));
    assert_eq!(dir.insert_directive(0, "a b", None, &[]), Err(Error::InvalidArgument));
    assert_eq!(dir.insert_directive(0, "x", Some("]"), &[]), Err(Error::InvalidArgument));

    // Splitting a list item repeats its marker; a table refuses.
    let mut splitter = Editor::new_str("- ab\n", common::markdown()).unwrap();
    splitter.split_block(3).unwrap();
    assert_eq!(splitter.source_str().unwrap(), "- a\n- b\n");
    let mut table = Editor::new_str("| a | b |\n|---|---|\n| c | d |\n", common::markdown()).unwrap();
    assert_eq!(table.split_block(3), Err(Error::NotEditable));

    // And the inverse.
    let mut joiner = Editor::new_str("- a\n- b\n", common::markdown()).unwrap();
    joiner.join_blocks(6).unwrap();
    assert_eq!(joiner.source_str().unwrap(), "- a\n  b\n");
    assert_eq!(joiner.join_blocks(2), Err(Error::NotFound));

    // A move across a quote's edge.
    let mut mover = Editor::new_str("> a\n>\n> y\n\nb\n", common::markdown()).unwrap();
    mover.move_block(8, 13).unwrap();
    assert_eq!(mover.source_str().unwrap(), "> a\n\nb\n\ny\n");
    assert_eq!(mover.move_block(8, 7), Err(Error::InvalidArgument));

    // No language leaves the fence bare; a set one tags it.
    let mut bare = Editor::new_str("x\n", common::markdown()).unwrap();
    bare.toggle_code_block(0, 1, None).unwrap();
    assert_eq!(bare.source_str().unwrap(), "```\nx\n```\n");
    bare.set_code_language(0, Some("zig")).unwrap();
    assert_eq!(bare.source_str().unwrap(), "```zig\nx\n```\n");
    assert_eq!(bare.set_code_language(0, Some("a b")), Err(Error::InvalidArgument));
}

#[test]
fn format_capability_matches_the_gestures() {
    assert!(!common::xml().is_authorable());
    assert!(common::html().is_authorable());
    assert!(common::html().supports(Gesture::ToggleInline(InlineKind::Strong)));
    assert!(!common::html().supports(Gesture::ToggleTaskItem));
    assert!(!common::markdown().supports(Gesture::ToggleInline(InlineKind::Mark)));
    assert!(common::djot().supports(Gesture::ToggleInline(InlineKind::Mark)));

    let mut md = Editor::new_str("ab\n", common::markdown()).unwrap();
    assert_eq!(md.toggle_inline(0, 2, InlineKind::Mark), Err(Error::UnsupportedFormat));
    let mut dj = Editor::new_str("ab\n", common::djot()).unwrap();
    assert!(dj.toggle_inline(0, 2, InlineKind::Mark).is_ok());

    assert!(!common::html().supports(Gesture::TableInsertRow));
    assert!(!common::html().supports(Gesture::SplitBlock));
    assert!(common::html().supports(Gesture::JoinBlocks));
    assert!(!common::xml().supports(Gesture::JoinBlocks));
    assert!(common::html().supports(Gesture::MoveBlock));
    assert!(!common::xml().supports(Gesture::MoveBlock));
    assert!(!common::html().supports(Gesture::RenumberOrderedLists));
    assert!(common::markdown().supports(Gesture::TableInsertRow));
    assert!(!common::html().supports(Gesture::InsertTable));
    assert!(common::djot().supports(Gesture::InsertTable));
    assert!(!common::markdown().supports(Gesture::InsertDirective));
    let dir = twig_markdown::Extensions { directives: true, ..Default::default() };
    assert!(common::markdown().supports_flags(common::flags(dir), Gesture::InsertDirective));
    assert!(common::djot().supports(Gesture::InsertDirective));
    assert!(!common::xml().supports(Gesture::InsertDirective));

    let html_table = "<table><tr><td>a</td></tr></table>";
    let mut ht = Editor::new_str(html_table, common::html()).unwrap();
    assert_eq!(ht.table_insert_row(15, true), Err(Error::UnsupportedFormat));
    assert_eq!(ht.insert_table(15, 1, 1), Err(Error::UnsupportedFormat));
    assert_eq!(ht.split_block(15), Err(Error::UnsupportedFormat));
    assert_eq!(ht.join_blocks(15), Err(Error::NotEditable));
    assert_eq!(ht.renumber_ordered_lists(15), Err(Error::UnsupportedFormat));
    assert_eq!(ht.source_str().unwrap(), html_table);

    assert!(common::markdown().supports(Gesture::ToggleBlockContainer(BlockContainerKind::BulletList)));
}

#[test]
fn format_names_and_lookups() {
    // `twig_format_by_name` / `twig_format_name` / `twig_format_dialect_of`
    // and `twig_format_feature_bit` over the compiled rows.
    common::all();
    assert_eq!(Format::by_name("md"), Some(common::markdown()));
    assert_eq!(Format::by_name("gfm"), Some(common::gfm()));
    assert_eq!(Format::by_name("svg"), Some(common::svg()));
    assert_eq!(Format::by_name("nope"), None);
    assert_eq!(common::gfm().name(), "gfm");
    assert_eq!(common::markdown().target().name(), "markdown");
    assert_eq!(common::gfm().feature_flags(&["math"]), Ok(1 << 1));
    assert_eq!(common::djot().feature_flags(&["math"]), Err(Error::UnsupportedFormat));
    assert_eq!(common::djot().feature_flags(&[]), Ok(0));
}
