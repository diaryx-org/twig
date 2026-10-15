//! Acceptance test: runs `parse` + the Markdown HTML renderer against the
//! GitHub-Flavored Markdown spec's EXTENSION examples
//! (`testdata/gfm-spec-0.29-extensions.json`). Port of
//! `src/languages/markdown/gfm_conformance.zig`; asserts zero failures.
//!
//! Only the extensions: GFM 0.29 is defined against CommonMark 0.29, which
//! disagrees with the 0.31.2 core `conformance.rs` already passes in full, so
//! its core examples would pin a spec twig has moved past.
//!
//! It renders through `markdown::html::render_alloc` — the real, user-facing
//! path — so it covers the DIALECT PLUMBING end to end
//! (`ParseOptions::GFM.dialect` -> `RenderOptions::dialect` ->
//! `GFM_RENDER_OPTIONS`), not just the printer.

use super::conformance::load_spec;
use crate::{html, parse, ParseOptions};

/// Ratchet floor: the whole vendored suite. Keep it at 24.
pub const BASELINE: usize = 24;

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
    pub markdown: Vec<u8>,
    pub expected: Vec<u8>,
    pub actual: Vec<u8>,
}

pub struct RunResult {
    pub summary: Summary,
    pub sections: Vec<SectionStat>,
}

/// Run the vendored suite, appending up to `max_failures` records.
pub fn run(max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    let mut summary = Summary::default();
    let mut sections: Vec<SectionStat> = Vec::new();
    for ex in load_spec("gfm-spec-0.29-extensions.json") {
        summary.total += 1;
        let idx = match sections.iter().position(|s| s.name == ex.section) {
            Some(i) => i,
            None => {
                sections.push(SectionStat { name: ex.section.clone(), passed: 0, total: 0 });
                sections.len() - 1
            }
        };
        sections[idx].total += 1;

        let doc = parse(&ex.markdown, ParseOptions::GFM);
        // Deliberately the real render path: the dialect mapping is part of
        // what this suite pins.
        let rendered =
            html::render_alloc(&doc, html::RenderOptions { dialect: ParseOptions::GFM.dialect, ..Default::default() })
                .unwrap();
        if rendered == ex.html {
            summary.passed += 1;
            sections[idx].passed += 1;
        } else {
            summary.failed += 1;
            if failures.len() < max_failures {
                failures.push(Failure {
                    example: ex.example,
                    section: ex.section.clone(),
                    markdown: ex.markdown.clone(),
                    expected: ex.html.clone(),
                    actual: rendered,
                });
            }
        }
    }
    RunResult { summary, sections }
}

#[test]
fn gfm_0_29_extension_conformance_full() {
    let mut failures = Vec::new();
    let result = run(8, &mut failures);
    if result.summary.failed > 0 {
        eprintln!(
            "\nGFM extension conformance: {}/{} passed ({} failed)",
            result.summary.passed, result.summary.total, result.summary.failed
        );
        for s in &result.sections {
            eprintln!("    {:<34} {}/{}", String::from_utf8_lossy(&s.name), s.passed, s.total);
        }
        for f in &failures {
            eprintln!(
                "\n  --- example {} ({}) — https://github.github.com/gfm/#example-{}\n  markdown: {:?}\n  expected: {:?}\n  actual:   {:?}",
                f.example,
                String::from_utf8_lossy(&f.section),
                f.example,
                String::from_utf8_lossy(&f.markdown),
                String::from_utf8_lossy(&f.expected),
                String::from_utf8_lossy(&f.actual)
            );
        }
    }
    assert!(result.summary.passed >= BASELINE);
    assert_eq!(result.summary.failed, 0);
}
