//! The splicer's reparse after an edit: what it costs on a large document
//! (an ignored benchmark).

use std::time::{Duration, Instant};

use crate::api::{Editor, Format};
use crate::test_languages;

/// A Markdown document of about `target` bytes with every construct an
/// editor meets: YAML frontmatter, headings, paragraphs with emphasis, links,
/// code and footnote references, nested lists, tables, fenced code, block
/// quotes and footnote definitions.
pub(crate) fn markdown_doc(target: usize) -> String {
    let mut s = String::from("---\ntitle: A generated document\ntags: [one, two]\n---\n\n# The document\n\n");
    let mut i = 0usize;
    while s.len() < target {
        s.push_str(&format!("## Section {i}\n\n"));
        s.push_str(&format!(
            "Paragraph {i} has *emphasis*, **strong text**, a [link](https://example.com/{i}) and `code {i}`, \
             and a footnote reference[^n{i}]. It runs on for a while so that it wraps\nacross a second line \
             with more words in it.\n\n"
        ));
        s.push_str(&format!(
            "- item {i} one\n- item {i} two with _emphasis_\n  - nested {i} a\n  - nested {i} b\n- item {i} three\n\n"
        ));
        if i % 2 == 0 {
            s.push_str(&format!(
                "| Name | Value |\n| ---- | ----: |\n| row {i} a | {i} |\n| row {i} b | {} |\n\n",
                i * 2
            ));
        }
        if i % 3 == 0 {
            s.push_str(&format!("```rust\nfn f{i}() -> u32 {{\n    {i}\n}}\n```\n\n"));
        }
        if i % 4 == 1 {
            s.push_str(&format!("> A quotation {i}, with *emphasis*\n> over two lines.\n\n"));
        }
        if i % 5 == 2 {
            s.push_str(&format!("1. first {i}\n2. second {i}\n\n"));
        }
        s.push_str(&format!("[^n{i}]: The footnote {i}, defined here.\n\n"));
        i += 1;
    }
    s
}

/// The Djot counterpart of [`markdown_doc`].
pub(crate) fn djot_doc(target: usize) -> String {
    let mut s = String::from("# The document\n\n");
    let mut i = 0usize;
    while s.len() < target {
        s.push_str(&format!("## Section {i}\n\n"));
        s.push_str(&format!(
            "Paragraph {i} has _emphasis_, *strong text*, a [link](https://example.com/{i}) and `code {i}`, \
             and a footnote reference[^n{i}]. It runs on for a while so that it wraps\nacross a second line \
             with more words in it.\n\n"
        ));
        s.push_str(&format!("- item {i} one\n- item {i} two with _emphasis_\n\n  - nested {i} a\n  - nested {i} b\n\n- item {i} three\n\n"));
        if i % 2 == 0 {
            s.push_str(&format!("| Name | Value |\n|------|------:|\n| row {i} a | {i} |\n| row {i} b | {} |\n\n", i * 2));
        }
        if i % 3 == 0 {
            s.push_str(&format!("``` rust\nfn f{i}() -> u32 {{\n    {i}\n}}\n```\n\n"));
        }
        if i % 4 == 1 {
            s.push_str(&format!("> A quotation {i}, with _emphasis_\n> over two lines.\n\n"));
        }
        if i % 5 == 2 {
            s.push_str(&format!("::: note\nA div {i}.\n:::\n\n"));
        }
        s.push_str(&format!("[^n{i}]: The footnote {i}, defined here.\n\n"));
        i += 1;
    }
    s
}

/// The first offset at or past `from` where `needle` starts, plus `skip`.
fn find_from(src: &str, from: usize, needle: &str, skip: usize) -> usize {
    src[from..].find(needle).map(|p| from + p + skip).unwrap_or_else(|| panic!("no {needle:?} past {from}"))
}

/// One benchmarked edit: a name and what it does to an editor over `src`.
struct BenchEdit {
    name: &'static str,
    run: fn(&mut Editor, &str),
}

const EDITS: &[BenchEdit] = &[
    BenchEdit {
        name: "type in a paragraph",
        run: |e, src| {
            let at = find_from(src, src.len() / 2, "Paragraph ", 4);
            e.insert_literal(at, "x").unwrap();
        },
    },
    BenchEdit {
        name: "type in a heading",
        run: |e, src| {
            let at = find_from(src, src.len() / 2, "## Section", 6);
            e.insert_literal(at, "x").unwrap();
        },
    },
    BenchEdit {
        name: "type in a list item",
        run: |e, src| {
            let at = find_from(src, src.len() / 2, "- item ", 4);
            e.insert_literal(at, "x").unwrap();
        },
    },
    BenchEdit {
        name: "type in a table cell",
        run: |e, src| {
            let at = find_from(src, src.len() / 2, "| row ", 4);
            e.insert_literal(at, "x").unwrap();
        },
    },
    BenchEdit {
        name: "delete across a block boundary",
        run: |e, src| {
            // From the end of a paragraph's text into the first list item.
            let start = find_from(src, src.len() / 2, "more words in it.", 10);
            let end = find_from(src, start, "- item ", 4);
            e.edit_range(start, end, "").unwrap();
        },
    },
];

fn time_edit(format: Format, src: &str, edit: &BenchEdit, rounds: usize) -> Duration {
    let mut times = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let mut e = Editor::new(src.as_bytes(), format).unwrap();
        e.set_history(false);
        // Time an edit after a first one, as a keystroke in a session is.
        let warm = find_from(src, 0, "Paragraph ", 4);
        e.insert_literal(warm, "w").unwrap();
        e.edit_range(warm, warm + 1, "").unwrap();
        let t = Instant::now();
        (edit.run)(&mut e, src);
        times.push(t.elapsed());
    }
    times.sort();
    times[times.len() / 2]
}

/// `cargo test --release -p twig-doc reparse_bench -- --ignored --nocapture`
#[test]
#[ignore = "a benchmark; run it in release with --ignored --nocapture"]
fn reparse_bench() {
    for (lang, format, make) in [
        ("markdown", test_languages::markdown(), markdown_doc as fn(usize) -> String),
        ("djot", test_languages::djot(), djot_doc as fn(usize) -> String),
    ] {
        for size in [100_000usize, 400_000, 1_000_000] {
            let src = make(size);
            let rounds = if size >= 1_000_000 { 7 } else { 15 };
            let mut parses: Vec<Duration> = (0..rounds)
                .map(|_| {
                    let t = Instant::now();
                    crate::format::parse_to_ast(format, &Default::default(), src.as_bytes()).unwrap();
                    t.elapsed()
                })
                .collect();
            parses.sort();
            let d = parses[parses.len() / 2];
            println!("{lang:8} {:>5} KB  {:32} {:>9.3} ms", src.len() / 1000, "(a full parse)", d.as_secs_f64() * 1e3);
            for edit in EDITS {
                let d = time_edit(format, &src, edit, rounds);
                println!("{lang:8} {:>5} KB  {:32} {:>9.3} ms", src.len() / 1000, edit.name, d.as_secs_f64() * 1e3);
            }
        }
    }
}
