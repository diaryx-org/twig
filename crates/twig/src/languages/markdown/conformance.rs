//! Acceptance test: runs `parse` + the shared HTML printer against the
//! vendored CommonMark spec test suite
//! (`testdata/commonmark-spec-0.31.2.json`) and reports a pass/total tally,
//! broken down by spec section. Port of
//! `src/languages/markdown/conformance.zig`.
//!
//! This suite passes in FULL — all 652 examples of CommonMark 0.31.2 — so it
//! asserts zero failures. Failures are cheaply bucketed into three categories
//! (living diagnostics):
//!   - `InlineNotYet`: the expected output uses a construct (`<em>`/
//!     `<strong>`/`<a `/`<img `, or unescaped `<...>` markup) that the ACTUAL
//!     output shows no sign of recognizing either.
//!   - `RenderingDivergence`: the actual output's HTML tags substantially
//!     overlap the expected one's, suggesting a printer-convention mismatch.
//!   - `Other`: most likely a genuine parsing gap or bug.
//!
//! The module also hosts the Markdown printing differential tests against the
//! Zig oracle (HTML and canonical output over the spec corpora, in all three
//! dialects).

use crate::json::{self, Value};
use crate::languages::html::{serialize_alloc_opts, COMMONMARK_RENDER_OPTIONS};
use crate::languages::markdown::{parse, ParseOptions};

/// Ratchet floor: the FULL suite, 652/652 of CommonMark 0.31.2. Keep this at
/// 652 — a drop means a real regression in a construct that used to parse.
pub const BASELINE: usize = 652;

pub(super) struct SpecExample {
    pub markdown: Vec<u8>,
    pub html: Vec<u8>,
    pub example: u32,
    pub section: Vec<u8>,
}

/// Read one of the vendored spec JSON files under
/// `src/languages/markdown/testdata/`.
pub(super) fn load_spec(name: &str) -> Vec<SpecExample> {
    let path = format!("{}/../../src/languages/markdown/testdata/{name}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    let value = json::parse(&text).unwrap_or_else(|_| panic!("parse {path}"));
    let field = |ex: &Value, key: &str| -> Vec<u8> { ex.get(key).and_then(|v| v.as_str()).unwrap().to_vec() };
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|ex| SpecExample {
            markdown: field(ex, "markdown"),
            html: field(ex, "html"),
            example: ex.get("example").and_then(|v| v.as_int()).unwrap() as u32,
            section: field(ex, "section"),
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    InlineNotYet,
    RenderingDivergence,
    Other,
}

#[derive(Default, Debug)]
pub struct CategoryCounts {
    pub inline_not_yet: usize,
    pub rendering_divergence: usize,
    pub other: usize,
}

#[derive(Debug)]
pub struct SectionStat {
    pub name: Vec<u8>,
    pub passed: usize,
    pub total: usize,
}

#[derive(Default, Debug)]
pub struct Summary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
}

#[derive(Debug)]
pub struct Failure {
    pub example: u32,
    pub section: Vec<u8>,
    pub category: Category,
    pub markdown: Vec<u8>,
    pub expected: Vec<u8>,
    pub actual: Vec<u8>,
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn contains_any(haystack: &[u8], needles: &[&[u8]]) -> bool {
    needles.iter().any(|n| find(haystack, n).is_some())
}

/// Extract tag names (duplicates kept, closing-slash ignored) from `html`.
fn extract_tags(html: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < html.len() {
        if html[i] == b'<' {
            let mut j = i + 1;
            if j < html.len() && html[j] == b'/' {
                j += 1;
            }
            let name_start = j;
            while j < html.len() && html[j].is_ascii_alphanumeric() {
                j += 1;
            }
            if j > name_start {
                out.push(&html[name_start..j]);
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

/// The fraction of tag occurrences in `expected` also found (as a multiset
/// intersection) in `actual`.
fn tag_overlap_ratio(expected: &[u8], actual: &[u8]) -> f64 {
    let exp_tags = extract_tags(expected);
    let act_tags = extract_tags(actual);
    if exp_tags.is_empty() {
        return if act_tags.is_empty() { 1.0 } else { 0.0 };
    }
    let mut used = vec![false; act_tags.len()];
    let mut matched = 0usize;
    for et in &exp_tags {
        for (idx, at) in act_tags.iter().enumerate() {
            if !used[idx] && et == at {
                used[idx] = true;
                matched += 1;
                break;
            }
        }
    }
    matched as f64 / exp_tags.len() as f64
}

fn categorize(expected: &[u8], actual: &[u8]) -> Category {
    let inline_tags: &[&[u8]] = &[b"<em>", b"<strong>", b"<a>", b"<a ", b"<img>", b"<img "];
    if contains_any(expected, inline_tags) && !contains_any(actual, inline_tags) {
        return Category::InlineNotYet;
    }
    if find(actual, b"&lt;").is_some() && find(expected, b"&lt;").is_none() && expected.contains(&b'<') {
        return Category::InlineNotYet;
    }
    if tag_overlap_ratio(expected, actual) > 0.6 {
        return Category::RenderingDivergence;
    }
    Category::Other
}

pub struct RunResult {
    pub summary: Summary,
    pub categories: CategoryCounts,
    pub sections: Vec<SectionStat>,
}

pub fn run(max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    let mut summary = Summary::default();
    let mut categories = CategoryCounts::default();
    let mut sections: Vec<SectionStat> = Vec::new();

    for ex in load_spec("commonmark-spec-0.31.2.json") {
        summary.total += 1;
        let idx = match sections.iter().position(|s| s.name == ex.section) {
            Some(i) => i,
            None => {
                sections.push(SectionStat { name: ex.section.clone(), passed: 0, total: 0 });
                sections.len() - 1
            }
        };
        sections[idx].total += 1;

        let doc = parse(&ex.markdown, ParseOptions::COMMONMARK);
        let rendered = serialize_alloc_opts(&doc.ast, None, COMMONMARK_RENDER_OPTIONS).unwrap();
        if rendered == ex.html {
            summary.passed += 1;
            sections[idx].passed += 1;
        } else {
            summary.failed += 1;
            let cat = categorize(&ex.html, &rendered);
            match cat {
                Category::InlineNotYet => categories.inline_not_yet += 1,
                Category::RenderingDivergence => categories.rendering_divergence += 1,
                Category::Other => categories.other += 1,
            }
            if failures.len() < max_failures {
                failures.push(Failure {
                    example: ex.example,
                    section: ex.section.clone(),
                    category: cat,
                    markdown: ex.markdown.clone(),
                    expected: ex.html.clone(),
                    actual: rendered,
                });
            }
        }
    }
    RunResult { summary, categories, sections }
}

#[test]
fn commonmark_0_31_2_spec_conformance_full() {
    let mut failures = Vec::new();
    let result = run(8, &mut failures);
    if result.summary.failed > 0 {
        eprintln!(
            "\nmarkdown conformance: {}/{} passed ({} failed)",
            result.summary.passed, result.summary.total, result.summary.failed
        );
        eprintln!(
            "  failure categories: inline-not-yet={} rendering-divergence={} other={}",
            result.categories.inline_not_yet, result.categories.rendering_divergence, result.categories.other
        );
        for s in &result.sections {
            eprintln!("    {:<40} {}/{}", String::from_utf8_lossy(&s.name), s.passed, s.total);
        }
        for f in &failures {
            eprintln!(
                "\n  --- example {} ({}, {:?})\n  markdown: {:?}\n  expected: {:?}\n  actual:   {:?}",
                f.example,
                String::from_utf8_lossy(&f.section),
                f.category,
                String::from_utf8_lossy(&f.markdown),
                String::from_utf8_lossy(&f.expected),
                String::from_utf8_lossy(&f.actual)
            );
        }
    }
    assert!(result.summary.passed >= BASELINE);
    assert_eq!(result.summary.failed, 0);
}

// ── differential tests against the Zig oracle ───────────────────────────

#[cfg(test)]
mod differential {
    use super::load_spec;
    use crate::languages::markdown::{html, parse, serializer, ParseOptions};
    use crate::languages::xml::differential::{oracle, oracle_available};

    struct Dialectal {
        cli: &'static str,
        options: ParseOptions,
    }

    fn dialects() -> [Dialectal; 3] {
        [
            Dialectal { cli: "markdown", options: ParseOptions::markdown() },
            Dialectal { cli: "commonmark", options: ParseOptions::COMMONMARK },
            Dialectal { cli: "gfm", options: ParseOptions::GFM },
        ]
    }

    fn corpus() -> Vec<Vec<u8>> {
        let mut out: Vec<Vec<u8>> = Vec::new();
        for name in ["commonmark-spec-0.31.2.json", "gfm-spec-0.29-extensions.json"] {
            out.extend(load_spec(name).into_iter().map(|e| e.markdown));
        }
        out
    }

    /// Run one output kind over the whole corpus in one dialect and collect
    /// every divergence.
    fn check(d: &Dialectal, what: &str, ours: impl Fn(&[u8]) -> Vec<u8>) -> Vec<String> {
        let mut problems = Vec::new();
        for src in corpus() {
            let mut args = vec!["convert", "-i", d.cli];
            if what != "html" {
                args.extend(["-o", what]);
            }
            let want = oracle(&args, &src).unwrap_or_else(|e| panic!("oracle failed: {}", String::from_utf8_lossy(&e)));
            let got = ours(&src);
            if got != want {
                problems.push(format!(
                    "{} {what}: {:?}\n  ours: {:?}\n  want: {:?}",
                    d.cli,
                    String::from_utf8_lossy(&src),
                    String::from_utf8_lossy(&got),
                    String::from_utf8_lossy(&want)
                ));
            }
        }
        problems
    }

    fn report(problems: Vec<String>) {
        if !problems.is_empty() {
            let shown: Vec<_> = problems.iter().take(10).cloned().collect();
            panic!("{} divergences; first {}:\n{}", problems.len(), shown.len(), shown.join("\n"));
        }
    }

    #[test]
    fn html_matches_the_oracle_in_every_dialect() {
        if !oracle_available() {
            return;
        }
        let mut problems = Vec::new();
        for d in &dialects() {
            problems.extend(check(d, "html", |src| {
                let doc = parse(src, d.options);
                html::render_alloc(&doc, html::RenderOptions { dialect: d.options.dialect, ..Default::default() })
                    .unwrap()
            }));
        }
        report(problems);
    }

    #[test]
    fn canonical_matches_the_oracle_in_every_dialect() {
        if !oracle_available() {
            return;
        }
        let mut problems = Vec::new();
        for d in &dialects() {
            problems.extend(check(d, "canonical", |src| serializer::serialize(&parse(src, d.options))));
        }
        report(problems);
    }

    struct Html {
        html: Vec<u8>,
    }

    /// Hand-written HTML reaching the printer's attribute, container and
    /// verse paths, which the spec outputs never do.
    const EXTRA_HTML: &[&str] = &[
        "<div class=\"c\"><p>x</p><p>y</p></div>",
        "<div class=\"verse\"><p>Roses are red,<br>violets<br>1. not a list</p><p># two</p></div>",
        "<p class=\"lead\" id=\"p1\">attributed</p><h2 id=\"t\">Title</h2>",
        "<blockquote><p class=\"q\">in a quote</p><ul><li>a</li><li><p>b</p><p>c</p></li></ul></blockquote>",
        "<p>a <span class=\"large\">big</span> b <span>plain</span> <u>under</u> <mark>hi</mark> <del>x</del> <sup>2</sup><sub>i</sub></p>",
        "<aside class=\"n\"><p>x</p></aside><video controls src=\"a.mp4\"></video>",
        "<p>x <my-widget data-x=\"1\">y</my-widget> <script>if (a < b) {}</script></p>",
        "<table><caption>cap</caption><thead><tr><th style=\"text-align: right\">h</th><th>i</th></tr></thead><tbody><tr><td>1<br>2</td><td>3</td></tr></tbody></table>",
        "<table><tr><td>a</td><td>b</td></tr><tr><th>h</th></tr></table>",
        "<dl><dt>term</dt><dd>def</dd><dt>t2</dt><dd><p>p1</p><p>p2</p></dd></dl>",
        "<ol start=\"3\"><li>three</li><li>four</li></ol><ol type=\"a\"><li>x</li></ol>",
        "<pre><code class=\"language-zig\">const x = ```;\n</code></pre><hr><p>after</p>",
        "<!-- c --><?pi data?><p>&nbsp;x&amp;y</p>",
        "<ul><li><input type=\"checkbox\" checked> done</li><li><input type=\"checkbox\"> todo</li></ul>",
        "<p><img src=\"a.png\" alt=\"alt\" title=\"t\"> <a href=\"/u\" title=\"x\">link <code>c`d</code></a></p>",
        "<title>T &amp; t</title><style>p { color: red }</style>",
    ];

    #[test]
    fn bare_tree_markdown_matches_the_oracle_cross_format() {
        // `convert -i html -o markdown` is a cross-format conversion, so it
        // goes through the bare-tree `serialize_ast` path. The corpus is the
        // spec's own expected HTML, which exercises every block and inline
        // kind the Markdown printer spells.
        if !oracle_available() {
            return;
        }
        let mut problems = Vec::new();
        let mut corpus: Vec<Vec<u8>> = EXTRA_HTML.iter().map(|s| s.as_bytes().to_vec()).collect();
        for name in ["commonmark-spec-0.31.2.json", "gfm-spec-0.29-extensions.json"] {
            corpus.extend(load_spec(name).into_iter().map(|e| e.html));
        }
        {
            for html in corpus {
                let ex = Html { html };
                let want = match oracle(&["convert", "-i", "html", "-o", "markdown"], &ex.html) {
                    Ok(w) => w,
                    Err(e) => panic!("oracle failed: {}", String::from_utf8_lossy(&e)),
                };
                let got = serializer::serialize_ast(&crate::languages::html::parse(&ex.html).ast);
                if got != want {
                    problems.push(format!(
                        "html->markdown: {:?}\n  ours: {:?}\n  want: {:?}",
                        String::from_utf8_lossy(&ex.html),
                        String::from_utf8_lossy(&got),
                        String::from_utf8_lossy(&want)
                    ));
                }
            }
        }
        report(problems);
    }

    /// The inputs of djot's vendored `.test` files: every fenced example's
    /// text up to its `.` separator line.
    fn djot_corpus() -> Vec<Vec<u8>> {
        let dir = format!("{}/../../src/languages/djot/testdata", env!("CARGO_MANIFEST_DIR"));
        let mut names: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|x| x == "test"))
            .collect();
        names.sort();
        let mut out = Vec::new();
        for path in names {
            let text = std::fs::read(&path).unwrap();
            let mut lines = text.split_inclusive(|&c| c == b'\n');
            while let Some(line) = lines.next() {
                if !line.starts_with(b"```") {
                    continue;
                }
                let mut input = Vec::new();
                for l in lines.by_ref() {
                    if l == b".\n" {
                        break;
                    }
                    input.extend_from_slice(l);
                }
                // Skip the expected output up to the closing fence.
                for l in lines.by_ref() {
                    if l.starts_with(b"```") {
                        break;
                    }
                }
                out.push(input);
            }
        }
        out
    }

    #[test]
    fn djot_to_markdown_matches_the_oracle() {
        // `convert -i djot -o markdown`: the bare-tree path over djot's
        // attributes, divs, spans, footnotes, math, line blocks and smart
        // punctuation — kinds the Markdown and HTML parsers never produce.
        if !oracle_available() {
            return;
        }
        let mut problems = Vec::new();
        let corpus = djot_corpus();
        assert!(corpus.len() > 200, "djot corpus: {} examples", corpus.len());
        for src in corpus {
            let want = match oracle(&["convert", "-i", "djot", "-o", "markdown"], &src) {
                Ok(w) => w,
                Err(e) => panic!("oracle failed: {}", String::from_utf8_lossy(&e)),
            };
            let got = serializer::serialize_ast(&crate::languages::djot::parse(&src).ast);
            if got != want {
                problems.push(format!(
                    "djot->markdown: {:?}\n  ours: {:?}\n  want: {:?}",
                    String::from_utf8_lossy(&src),
                    String::from_utf8_lossy(&got),
                    String::from_utf8_lossy(&want)
                ));
            }
        }
        report(problems);
    }
}
