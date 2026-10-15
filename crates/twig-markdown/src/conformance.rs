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

use twig_kit::json::{self, Value};
use twig_kit::html::{serialize_alloc_opts, COMMONMARK_RENDER_OPTIONS};
use crate::{parse, ParseOptions};

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
    let path = format!("{}/testdata/{name}", env!("CARGO_MANIFEST_DIR"));
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
