//! The splicer's reparse after an edit: what it costs on a large document
//! (an ignored benchmark), and that a reparse of only the edited blocks is
//! the parse a fresh one of the whole new source gives.

use std::time::{Duration, Instant};

use crate::api::{Editor, Format};
use crate::ast::reparse::{self, Edit};
use crate::ast::splicer::{ParseError, ParseFn, Splicer};
use crate::document::Document;
use crate::format::{self, ParseConfig};
use crate::span::Span;
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
        // An editor's first edit learns what its later ones reuse; time an
        // edit after one, as a keystroke in a session is.
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

// ── the differential test ──────────────────────────────────────────────────

/// A small deterministic generator (xorshift64*), so a failure replays.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

/// What an edit writes: plain typing, and every spelling that can change a
/// block's extent or a document-wide table.
const SNIPPETS: &[&str] = &[
    "x", "x", "x", "word ", " ", "é", "\n", "\n\n", "\n\n\n", "*", "**", "_", "`", "```", "```\n", "~~~", "# ",
    "## ", "\n# H\n", "- ", "\n- ", "* ", "+ ", "1. ", "2) ", "\n1. a\n", "> ", "\n> ", "|", " | ", "\n| a | b |\n| - | - |\n",
    "---", "\n---\n", "===", "\n===\n", "    ", "\t", "[", "]", "](/u)", "[link](/u)", "[foo]", "[foo][]", "[^n1]",
    "\n[foo]: /url\n", "\n[^q]: a note\n", "\n[^n3]: again\n", "<div>", "</div>", "\n<div>\n", "<!--", "-->", ":::",
    "\n::: note\n", "{.c}", "{#id}", "\n{.c}\n", "$", "$$", "\\", "&amp;", "<http://a.b>", "- [ ] ", ": ", "\n: d\n",
    "^", "~", "==", "\"", "'", "{=html}", "\r\n", "---json\n", "\n---json\n", "\n\n---json\n", "+++", "\n+++\n", "---\n",
];

/// The fragment parser and full parser for `format`, as the editor builds
/// them.
fn parsers(format: Format) -> (ParseFn, reparse::FragmentFn) {
    let cfg = ParseConfig::default();
    let parse: ParseFn = Box::new(move |src: &[u8]| format::parse_to_ast(format, &cfg, src).map_err(|e| ParseError::new(e.name())));
    let frag: reparse::FragmentFn = Box::new(move |src: &[u8], range: std::ops::Range<usize>, doc: &Document| format::parse_fragment(format, &cfg, src, range, doc));
    (parse, frag)
}

/// Where the two documents first differ, or `None`.
fn difference(a: &Document, b: &Document) -> Option<String> {
    if a.source != b.source {
        return Some("source".into());
    }
    if a.ast.root != b.ast.root {
        return Some("root".into());
    }
    if a.ast.nodes.len() != b.ast.nodes.len() {
        return Some(format!("node count {} vs {}", a.ast.nodes.len(), b.ast.nodes.len()));
    }
    for i in 0..a.ast.nodes.len() {
        let id = i as u32;
        if a.ast.nodes[i] != b.ast.nodes[i] {
            return Some(format!("node {i}: {:?} vs {:?}", a.ast.nodes[i], b.ast.nodes[i]));
        }
        if a.span(id) != b.span(id)
            || a.content_span(id) != b.content_span(id)
            || a.marker_span(id) != b.marker_span(id)
            || a.spelling(id) != b.spelling(id)
        {
            return Some(format!(
                "node {i} ({:?}) positions: {:?} {:?} {:?} vs {:?} {:?} {:?}",
                a.ast.nodes[i].kind.tag(),
                a.span(id),
                a.content_span(id),
                a.marker_span(id),
                b.span(id),
                b.content_span(id),
                b.marker_span(id)
            ));
        }
    }
    if a.ast.attrs != b.ast.attrs {
        return Some("attrs table".into());
    }
    if !a.spans_eql(b) || a.node_spans.len() != b.node_spans.len() || a.node_spelling.len() != b.node_spelling.len() {
        return Some("span tables".into());
    }
    if a.labels != b.labels {
        return Some(format!("labels {:?} vs {:?}", a.labels, b.labels));
    }
    None
}

/// The nearest character boundary at or before `at`.
fn floor_char(src: &[u8], mut at: usize) -> usize {
    while at > 0 && at < src.len() && src[at] & 0xC0 == 0x80 {
        at -= 1;
    }
    at.min(src.len())
}

/// One random edit to `src`: the range it replaces and what with.
fn random_edit(rng: &mut Rng, src: &[u8]) -> (usize, usize, Vec<u8>) {
    let start = floor_char(src, rng.below(src.len() + 1));
    let (end, text) = match rng.below(10) {
        // Typing, the common case.
        0..=4 => (start, SNIPPETS[rng.below(SNIPPETS.len())].as_bytes().to_vec()),
        // A short deletion: a backspace, a word, a line.
        5..=6 => (floor_char(src, (start + 1 + rng.below(12)).min(src.len())), Vec::new()),
        // A deletion across blocks.
        7 => (floor_char(src, (start + rng.below(200)).min(src.len())), Vec::new()),
        // A replacement.
        _ => {
            let end = floor_char(src, (start + rng.below(30)).min(src.len()));
            (end, SNIPPETS[rng.below(SNIPPETS.len())].as_bytes().to_vec())
        }
    };
    (start, end.max(start), text)
}

/// Run `edits` random edits from `src` through the cut reparse, checking each
/// against a parse of the whole new source. How many reparsed in place.
fn differential(format: Format, src: &str, edits: usize, seed: u64) -> usize {
    let (parse, frag) = parsers(format);
    let mut rng = Rng(seed | 1);
    let mut source = src.as_bytes().to_vec();
    let mut doc = parse(&source).unwrap();
    let mut hits = 0;
    let mut dense = None;
    for step in 0..edits {
        let (start, end, text) = random_edit(&mut rng, &source);
        let mut next = source[..start].to_vec();
        next.extend_from_slice(&text);
        next.extend_from_slice(&source[end..]);
        let edit = Edit { start, old_end: end, new_end: start + text.len() };
        let before = doc.clone();
        let full = parse(&next).unwrap();
        let run = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut d = doc.clone();
            let mut dn = dense;
            let ok = reparse::reparse(&mut d, &next, edit, frag.as_ref(), &mut dn);
            (d, dn, ok)
        }));
        let Ok((inc, dn, ok)) = run else {
            panic!("{} seed {seed} step {step}: a parse panicked replacing {start}..{end} with {:?}\nbefore: {:?}", format.name(), String::from_utf8_lossy(&text), String::from_utf8_lossy(&source));
        };
        doc = inc;
        dense = dn;
        if ok {
            hits += 1;
            if let Some(d) = difference(&doc, &full) {
                panic!(
                    "{} seed {seed} step {step}: replacing {start}..{end} ({:?}) with {:?} reparsed to a different tree: {d}\n\
                     before: {:?}\nafter: {:?}",
                    format.name(),
                    String::from_utf8_lossy(&source[start..end]),
                    String::from_utf8_lossy(&text),
                    String::from_utf8_lossy(&source),
                    String::from_utf8_lossy(&next),
                );
            }
        } else if let Some(d) = difference(&doc, &before) {
            panic!("a refused reparse changed the document: {d}");
        } else {
            doc = full;
            dense = None;
        }
        source = next;
    }
    hits
}

#[test]
fn a_cut_reparse_is_the_whole_parse_markdown() {
    let mut hits = 0;
    for (i, format) in [test_languages::markdown(), test_languages::gfm(), test_languages::commonmark()].into_iter().enumerate() {
        hits += differential(format, &markdown_doc(12_000), 1500, 0x9E37_79B9 + i as u64);
    }
    // An endmatter, found from the end of the document.
    let ended = format!("{}---json\n{{\"a\": 1}}\n---\n", markdown_doc(8_000));
    hits += differential(test_languages::markdown(), &ended, 1500, 0xE11D);
    // The test means something only if most edits take the cut.
    assert!(hits > 2500, "only {hits} of 6000 edits reparsed in place");
}

#[test]
fn a_cut_reparse_is_the_whole_parse_djot() {
    let hits = differential(test_languages::djot(), &djot_doc(12_000), 2000, 0xD1CE);
    assert!(hits > 800, "only {hits} of 2000 edits reparsed in place");
}

/// The CommonMark spec's examples, one by one and run together.
fn commonmark_examples() -> Vec<String> {
    let json = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../twig-markdown/testdata/commonmark-spec-0.31.2.json"))
        .expect("the CommonMark corpus");
    let mut out = Vec::new();
    let mut rest = json.as_str();
    while let Some(at) = rest.find("\"markdown\": \"") {
        rest = &rest[at + 13..];
        let mut s = String::new();
        let mut chars = rest.char_indices();
        while let Some((i, c)) = chars.next() {
            match c {
                '"' => {
                    rest = &rest[i + 1..];
                    break;
                }
                '\\' => match chars.next().map(|(_, e)| e) {
                    Some('n') => s.push('\n'),
                    Some('t') => s.push('\t'),
                    Some('u') => {
                        let hex: String = (0..4).filter_map(|_| chars.next().map(|(_, h)| h)).collect();
                        s.push(char::from_u32(u32::from_str_radix(&hex, 16).unwrap()).unwrap_or('\u{FFFD}'));
                    }
                    Some(e) => s.push(e),
                    None => {}
                },
                c => s.push(c),
            }
        }
        out.push(s);
    }
    out
}

/// The djot.js corpus's inputs.
fn djot_examples() -> Vec<String> {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../twig-djot/testdata");
    let mut out = Vec::new();
    let mut names: Vec<_> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    names.sort();
    for path in names.into_iter().filter(|p| p.extension().is_some_and(|e| e == "test")) {
        let text = std::fs::read_to_string(path).unwrap();
        let mut lines = text.lines();
        while let Some(line) = lines.next() {
            if !line.starts_with("```") {
                continue;
            }
            let fence = line.chars().take_while(|&c| c == '`').count();
            let mut input = String::new();
            for l in lines.by_ref() {
                if l == "." {
                    break;
                }
                input.push_str(l);
                input.push('\n');
            }
            for l in lines.by_ref() {
                if l.starts_with(&"`".repeat(fence)) && l.trim_end().chars().all(|c| c == '`') {
                    break;
                }
            }
            out.push(input);
        }
    }
    out
}

#[test]
fn a_cut_reparse_is_the_whole_parse_over_the_corpora() {
    let md = test_languages::markdown();
    let djot = test_languages::djot();
    let cm = commonmark_examples();
    let dj = djot_examples();
    assert!(cm.len() > 600 && dj.len() > 200, "{} and {} examples", cm.len(), dj.len());
    for (i, ex) in cm.iter().enumerate() {
        differential(md, ex, 12, i as u64 + 1);
    }
    for (i, ex) in dj.iter().enumerate() {
        differential(djot, ex, 12, i as u64 + 1);
    }
    // Run together, every example is the neighbour of another.
    differential(md, &cm.join("\n"), 1500, 7);
    differential(test_languages::commonmark(), &cm.join("\n\n"), 800, 11);
    differential(djot, &dj.join("\n"), 1500, 13);
}

/// Through the splicer as the editor drives it — keystrokes, undo and redo —
/// every state is the whole parse of its source.
#[test]
fn the_splicer_keeps_the_whole_parse_through_undo_and_redo() {
    for (format, src) in [(test_languages::markdown(), markdown_doc(6_000)), (test_languages::djot(), djot_doc(6_000))] {
        let (parse, frag) = parsers(format);
        let (check, _) = parsers(format);
        let mut sp = Splicer::new(src.as_bytes(), parse).unwrap();
        sp.set_fragment_parser(Some(frag));
        let mut rng = Rng(42);
        for step in 0..400 {
            match rng.below(8) {
                0 => drop(sp.undo()),
                1 => drop(sp.redo()),
                _ => {
                    let (start, end, text) = random_edit(&mut rng, sp.source_bytes());
                    sp.splice(Span::new(start, end), &text).unwrap();
                }
            }
            let full = check(sp.source_bytes()).unwrap();
            if let Some(d) = difference(&sp.doc, &full) {
                panic!("{} step {step}: {d}", format.name());
            }
        }
    }
}


/// The differential tests at length, over many seeds:
/// `TWIG_SOAK=<seeds> [TWIG_SOAK_FROM=<first>] cargo test --release -p twig-doc reparse_soak -- --ignored`.
#[test]
#[ignore = "long; run it in release with --ignored"]
fn reparse_soak() {
    let seeds: u64 = std::env::var("TWIG_SOAK").ok().and_then(|s| s.parse().ok()).unwrap_or(20);
    let from: u64 = std::env::var("TWIG_SOAK_FROM").ok().and_then(|s| s.parse().ok()).unwrap_or(1);
    let cm = commonmark_examples().join("\n");
    let dj = djot_examples().join("\n");
    let ended = format!("{}---json\n{{\"a\": 1}}\n---\n", markdown_doc(6_000));
    let mut runs = 0;
    let mut hits = 0;
    for seed in from..from + seeds {
        for (format, src) in [
            (test_languages::markdown(), markdown_doc(8_000)),
            (test_languages::gfm(), markdown_doc(8_000)),
            (test_languages::commonmark(), cm.clone()),
            (test_languages::markdown(), cm.clone()),
            (test_languages::markdown(), ended.clone()),
            (test_languages::djot(), djot_doc(8_000)),
            (test_languages::djot(), dj.clone()),
        ] {
            runs += 1;
            hits += differential(format, &src, 3000, seed * 7919 + runs);
        }
    }
    println!("{hits} of {} edits reparsed in place", runs * 3000);
}
