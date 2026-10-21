//! `twig::meta`, and every parse honouring a document's `twig` settings: the
//! default `fig` feature.

#![cfg(feature = "fig")]

use twig::meta::{Embed, Error, Where, find, parse_host, resolve};

fn s(bytes: &[u8]) -> &str {
    std::str::from_utf8(bytes).unwrap()
}

fn edited(host: &str, edit: impl FnOnce(&mut fig::Editor)) -> String {
    let mut e = Embed::open_in(host.as_bytes(), twig_markdown::format(), Where::Front).unwrap();
    edit(e.editor_mut());
    String::from_utf8(e.render().unwrap()).unwrap()
}

#[test]
fn find_frontmatters_fences_body_and_language() {
    let host = b"---\ntitle: Hi # kept\n---\n# Body\n";
    let parsed = parse_host(host, twig_markdown::format()).unwrap();
    let block = find(&parsed.doc, Where::Front).unwrap();
    assert_eq!("yaml", block.lang);
    assert_eq!("title: Hi # kept\n", s(&host[block.body.clone()]));
    assert_eq!("---\ntitle: Hi # kept\n---", s(&host[block.span.clone()]));
    assert!(find(&parsed.doc, Where::End).is_none());
}

#[test]
fn find_endmatter_is_the_trailing_block_and_not_frontmatter() {
    let host = b"# Body\n\ntext\n\n---toml\nx = 1\n---\n";
    let parsed = parse_host(host, twig_markdown::format()).unwrap();
    assert!(find(&parsed.doc, Where::Front).is_none());
    let block = find(&parsed.doc, Where::End).unwrap();
    assert_eq!("toml", block.lang);
    assert_eq!("x = 1\n", s(&host[block.body.clone()]));
}

#[test]
fn find_a_document_with_no_metadata_has_none() {
    let parsed = parse_host(b"# Body\n", twig_markdown::format()).unwrap();
    assert!(find(&parsed.doc, Where::Front).is_none());
    assert!(find(&parsed.doc, Where::End).is_none());
}

#[test]
fn embed_a_yaml_edit_moves_only_its_value() {
    let out = edited("---\ntitle: Hi # kept\ntags: [a]\n---\n# Body\n", |e| {
        e.set_value(&["title".into()], "Hello").unwrap();
    });
    assert_eq!("---\ntitle: Hello # kept\ntags: [a]\n---\n# Body\n", out);
}

#[test]
fn embed_a_new_key_lands_inside_the_fences() {
    let out = edited("---\ntitle: Hi\n---\nbody\n", |e| {
        e.set_value(&["draft".into()], true).unwrap();
    });
    assert_eq!("---\ntitle: Hi\ndraft: true\n---\nbody\n", out);
}

#[test]
fn embed_toml_frontmatter_is_edited_as_toml() {
    let out = edited("+++\ntitle = \"Hi\"\n+++\nbody\n", |e| {
        e.set_value(&["title".into()], "Hello").unwrap();
    });
    assert_eq!("+++\ntitle = \"Hello\"\n+++\nbody\n", out);
}

#[test]
fn embed_fig_is_read_as_figl() {
    let out = edited("---fig\ntitle = Hi\n---\nbody\n", |e| {
        e.set_value(&["title".into()], "Hello").unwrap();
    });
    assert_eq!("---fig\ntitle = Hello\n---\nbody\n", out);
}

#[test]
fn embed_json_endmatter_is_edited_as_json() {
    let host = b"# Body\n\n---json\n{\"n\": 1}\n---\n";
    let mut e = Embed::open_in(host, twig_markdown::format(), Where::End).unwrap();
    e.editor_mut().set_value(&["n".into()], 2i64).unwrap();
    assert_eq!(
        "# Body\n\n---json\n{\"n\": 2}\n---\n",
        s(&e.render().unwrap())
    );
}

#[test]
fn embed_a_block_in_a_language_fig_does_not_know_is_refused() {
    let host = b"---edn\n{:title \"Hi\"}\n---\nbody\n";
    let parsed = parse_host(host, twig_markdown::format()).unwrap();
    let block = find(&parsed.doc, Where::Front).unwrap();
    assert!(matches!(Embed::open(host, &block), Err(Error::UnsupportedLanguage(l)) if l == "edn"));
}

#[test]
fn embed_open_in_a_host_with_no_block_there_is_no_metadata() {
    assert!(matches!(
        Embed::open_in(b"# Body\n", twig_markdown::format(), Where::Front),
        Err(Error::NoMetadata)
    ));
}

#[test]
fn open_or_init_a_host_with_no_frontmatter_gains_a_block_above_its_first_line() {
    let mut e = Embed::open_or_init(b"# Body\n", twig_markdown::format(), "yaml").unwrap();
    e.editor_mut().set_value(&["title".into()], "Hi").unwrap();
    assert_eq!("---\ntitle: Hi\n---\n# Body\n", s(&e.render().unwrap()));
}

#[test]
fn open_or_init_a_toml_block_is_fenced_with_plus() {
    let mut e = Embed::open_or_init(b"# Body\n", twig_markdown::format(), "toml").unwrap();
    e.editor_mut().set_value(&["title".into()], "Hi").unwrap();
    assert_eq!(
        "+++\ntitle = \"Hi\"\n+++\n# Body\n",
        s(&e.render().unwrap())
    );
}

#[test]
fn open_or_init_a_host_with_frontmatter_opens_it_whatever_language_was_asked() {
    let mut e =
        Embed::open_or_init(b"+++\nx = 1\n+++\nbody\n", twig_markdown::format(), "yaml").unwrap();
    assert_eq!("toml", e.lang());
    e.editor_mut().set_value(&["x".into()], 2i64).unwrap();
    assert_eq!("+++\nx = 2\n+++\nbody\n", s(&e.render().unwrap()));
}

#[test]
fn find_an_html_island_leading_the_page_is_its_front_block() {
    let host = b"<script type=\"application/yaml\">\ntitle: Hi\n</script>\n<p>Body</p>\n";
    let parsed = parse_host(host, twig_html::format()).unwrap();
    let block = find(&parsed.doc, Where::Front).unwrap();
    assert_eq!("yaml", block.lang);
    assert_eq!("title: Hi\n", s(&host[block.body.clone()]));
    assert_eq!(
        "<script type=\"application/yaml\">\ntitle: Hi\n</script>",
        s(&host[block.span.clone()])
    );
    assert!(find(&parsed.doc, Where::End).is_none());
}

#[test]
fn find_an_html_island_in_head_is_found_where_it_sits() {
    let host = b"<!doctype html>\n<html>\n<head>\n  <script type=\"application/toml\">\n  x = 1\n  </script>\n</head>\n<body><p>Hi</p></body>\n</html>\n";
    let parsed = parse_host(host, twig_html::format()).unwrap();
    let block = find(&parsed.doc, Where::Front).unwrap();
    assert_eq!("toml", block.lang);
    assert_eq!("  x = 1\n", s(&host[block.body.clone()]));
}

#[test]
fn embed_an_html_island_edit_keeps_every_byte_outside_its_body() {
    let host = "<script type=\"application/yaml\">\ntitle: Hi # kept\n</script>\n<style>p{}</style>\n<p>Body</p>\n";
    let mut e = Embed::open_in(host.as_bytes(), twig_html::format(), Where::Front).unwrap();
    e.editor_mut().set_value(&["id".into()], "80k72t9").unwrap();
    assert_eq!(
        "<script type=\"application/yaml\">\ntitle: Hi # kept\nid: 80k72t9\n</script>\n<style>p{}</style>\n<p>Body</p>\n",
        s(&e.render().unwrap())
    );
}

#[test]
fn open_or_init_an_html_host_opens_its_island_and_writes_a_new_one_as_an_island() {
    let host = b"<script type=\"application/yaml\">\ntitle: Hi\n</script>\n<p>Body</p>\n";
    let mut e = Embed::open_or_init(host, twig_html::format(), "yaml").unwrap();
    e.editor_mut().set_value(&["id".into()], "x").unwrap();
    assert_eq!(
        "<script type=\"application/yaml\">\ntitle: Hi\nid: x\n</script>\n<p>Body</p>\n",
        s(&e.render().unwrap())
    );

    let mut e = Embed::open_or_init(b"<p>Body</p>\n", twig_html::format(), "yaml").unwrap();
    e.editor_mut().set_value(&["id".into()], "x").unwrap();
    let out = e.render().unwrap();
    assert_eq!(
        "<script type=\"application/yaml\">\nid: x\n</script>\n<p>Body</p>\n",
        s(&out)
    );
    let parsed = parse_host(&out, twig_html::format()).unwrap();
    assert!(find(&parsed.doc, Where::Front).is_some());
}

#[test]
fn read_gives_the_block_as_a_fig_document() {
    let host = b"---\ntitle: Hi\ntags: [a, b]\n---\nbody\n";
    let parsed = parse_host(host, twig_markdown::format()).unwrap();
    let meta = twig::meta::read(&parsed.doc, Where::Front)
        .unwrap()
        .unwrap()
        .to_value()
        .unwrap();
    assert_eq!(Some("Hi"), meta.get("title").and_then(|v| v.as_str()));
    assert_eq!(2, meta.get("tags").and_then(|v| v.as_seq()).unwrap().len());
    assert!(twig::meta::read(&parsed.doc, Where::End).unwrap().is_none());
}

#[test]
fn resolve_frontmatters_twig_settings_turn_on_features_and_pick_the_dialect() {
    let host = b"---\ntitle: Notes\ntwig:\n  dialect: gfm\n  features: [math, highlight]\n---\n$x$ and ==marked==\n";
    let r = resolve(host, twig_markdown::format(), &[]).unwrap();
    assert_eq!(twig_markdown::gfm(), r.format);
        assert!(r.features.iter().any(|f| f == "math"));
    assert!(r.features.iter().any(|f| f == "highlight"));
    assert!(!r.features.iter().any(|f| f == "directives"));
    assert!(r.ignored().is_empty());

    // And the document reads as it asked: `$x$` is math, `==…==` a mark.
    let mut doc = r.parse(host).unwrap();
    let kinds: Vec<_> = doc.nodes().unwrap().into_iter().map(|n| n.kind).collect();
    assert!(kinds.contains(&twig::Kind::InlineMath), "{kinds:?}");
    assert!(kinds.contains(&twig::Kind::Mark), "{kinds:?}");
}

#[test]
fn resolve_the_callers_features_stay_under_the_documents_settings() {
    let host = b"---\ntwig:\n  features: math\n---\nbody\n";
    let r = resolve(host, twig_markdown::format(), &["directives"]).unwrap();
    assert_eq!(twig_markdown::format(), r.format);
        assert!(r.features.iter().any(|f| f == "math"));
    assert!(r.features.iter().any(|f| f == "directives"));
}

#[test]
fn resolve_unknown_names_are_reported_not_refused() {
    let host =
        b"---\ntwig:\n  dialect: djot\n  features: [math, sparkles]\n  colour: red\n---\nbody\n";
    let r = resolve(host, twig_markdown::format(), &[]).unwrap();
    assert_eq!(twig_markdown::format(), r.format);
    assert!(r.features.iter().any(|f| f == "math"));
    assert_eq!(["dialect", "colour", "sparkles"], r.ignored());
}

#[test]
fn resolve_no_frontmatter_or_frontmatter_that_does_not_parse_reads_as_asked() {
    for host in [&b"# Body\n"[..], b"---\ntwig: [unclosed\n---\nbody\n"] {
        let r = resolve(host, twig_markdown::format(), &[]).unwrap();
        assert_eq!(twig_markdown::format(), r.format);
        assert!(!r.features.iter().any(|f| f == "math"));
    }
}

#[test]
fn resolve_a_callers_feature_the_row_does_not_declare_is_an_error() {
    assert!(matches!(
        resolve(b"body\n", twig_markdown::format(), &["sparkles"]),
        Err(Error::Twig(twig::Error::NotFound))
    ));
}

// ── every parse honours the document's settings ──

#[test]
fn a_parse_reads_the_document_as_its_frontmatter_asks() {
    let host = "---\ntwig:\n  dialect: gfm\n  features: [math]\n---\n$x$ and ~~gone~~\n";
    let mut doc = twig::Document::parse_str(host, twig_markdown::format()).unwrap();
    let kinds: Vec<_> = doc.nodes().unwrap().into_iter().map(|n| n.kind).collect();
    assert!(kinds.contains(&twig::Kind::InlineMath), "{kinds:?}");
    // GFM's HTML conventions, as the dialect asked.
    let html = String::from_utf8(doc.render_html().unwrap()).unwrap();
    assert!(html.contains("<del>gone</del>"), "{html}");
}

#[test]
fn an_editor_reads_and_reparses_the_document_as_it_asks() {
    let host = "---\ntwig:\n  features: math\n---\n$x$\n";
    let mut ed = twig::Editor::new_str(host, twig_markdown::format()).unwrap();
    assert_eq!(ed.query("inline_math").unwrap().len(), 1);
    // A reparse after an edit keeps the features the document asked for.
    ed.replace("inline_math", "$y$").unwrap();
    assert_eq!(ed.query("inline_math").unwrap().len(), 1);
}

#[test]
fn a_document_without_settings_reads_as_asked() {
    for host in ["$x$\n", "---\ntitle: plain\n---\n$x$\n", "---\ntwig: [unclosed\n---\n$x$\n"] {
        let mut doc = twig::Document::parse_str(host, twig_markdown::format()).unwrap();
        let kinds: Vec<_> = doc.nodes().unwrap().into_iter().map(|n| n.kind).collect();
        assert!(!kinds.contains(&twig::Kind::InlineMath), "{host:?}: {kinds:?}");
    }
}

#[test]
fn settings_only_add_to_the_callers_features_and_stay_in_the_language() {
    // The caller's `directives` stays on; `dialect: djot` names another
    // language's row and is not acted on.
    let host = "---\ntwig:\n  dialect: djot\n  features: [math]\n---\n$x$\n\n::leaf\n";
    let mut doc =
        twig::Document::parse_with_features(host.as_bytes(), twig_markdown::format(), &["directives"]).unwrap();
    let kinds: Vec<_> = doc.nodes().unwrap().into_iter().map(|n| n.kind).collect();
    assert!(kinds.contains(&twig::Kind::InlineMath), "{kinds:?}");
    assert_eq!(doc.query("directive").unwrap().len(), 1);
}
