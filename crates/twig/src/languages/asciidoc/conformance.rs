//! The AsciiDoc TCK conformance harness — port of
//! `src/languages/asciidoc/conformance.zig`. Runs the vendored TCK corpus
//! (`testdata/asciidoc-tck-corpus.json`, 13 cases from the AsciiDoc Language
//! Working Group's `asciidoc-tck`) and twig's own authored corpus
//! (`testdata/asciidoc-twig-corpus.json`, validated against the official ASG
//! schema) through `asg.rs`'s codec and through `parser.rs`.
//!
//! ── The codec round-trip (`run` / `SEMANTIC_BASELINE`) ─────────────────────
//! `encode(decode(x)) == x` (structurally) over every case, plus `Coverage`:
//! how much of the TCK's element vocabulary maps to a semantic `Kind` versus
//! the `container` escape hatch.
//!
//! ── The parse comparison (`run_parse` / `PARSE_BASELINE`) ──────────────────
//! `parser::parse`/`parser::parse_inline_list` (chosen by `case.level`) ->
//! `asg::encode` -> compare against `case.asg`, structurally, over every case
//! of both corpora.
//!
//! The two corpora run through the same code path and are deliberately NOT
//! merged: the vendored one is a third party's expectation of what AsciiDoc
//! means, the authored one is twig's. They get separate ratchets.

use super::asg::{self, Coverage, Root};
use super::parser;
use crate::json::{self, Stringify, Value};

/// The vendored AsciiDoc TCK — a third party's expectations, the normative
/// ratchet.
pub const TCK_CORPUS_JSON: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/languages/asciidoc/testdata/asciidoc-tck-corpus.json"));

/// Twig's own authored cases — a weaker authority, a much wider net.
pub const TWIG_CORPUS_JSON: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/languages/asciidoc/testdata/asciidoc-twig-corpus.json"));

/// Ratchet floor: `Coverage::semantic` summed across all 13 TCK cases.
pub const SEMANTIC_BASELINE: u32 = 50;

/// Ratchet floor for the vendored TCK under `Mode::Parse`.
pub const PARSE_BASELINE: u32 = 13;

/// Ratchet floor for twig's own corpus under `Mode::Parse`.
pub const TWIG_PARSE_BASELINE: u32 = 137;

/// Ratchet floor for twig's own corpus under `Mode::Codec`.
pub const TWIG_CODEC_BASELINE: u32 = 137;

/// One corpus case.
#[derive(Clone, Debug)]
pub struct Case {
    /// The case's path within the TCK's `tests/` tree (or twig's own id).
    pub id: Vec<u8>,
    /// `"block"` (an `asg` shaped as a `document`) or `"inline"`.
    pub level: Vec<u8>,
    /// The AsciiDoc source.
    pub adoc: Vec<u8>,
    /// The expected ASG.
    pub asg: Value,
    /// Why this expectation is what it is — twig's own cases only.
    pub note: Option<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
}

/// A fully owned record of one failing case: the raw JSON text of each side
/// (or an `<… error: …>` placeholder), for a human to diff.
#[derive(Clone, Debug)]
pub struct Failure {
    pub id: Vec<u8>,
    pub adoc: Vec<u8>,
    pub expected: Vec<u8>,
    pub actual: Vec<u8>,
    pub note: Option<Vec<u8>>,
}

/// Which side of the harness a run exercises.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// `decode(case.asg)` -> `encode` -> compare. Tests the codec alone.
    Codec,
    /// `parse(case.adoc)` -> `encode` -> compare. Tests the parser.
    Parse,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct RunResult {
    pub summary: Summary,
    pub coverage: Coverage,
}

/// The corpus's cases, or `None` when the JSON does not have the shape.
pub fn load_cases(corpus_json: &[u8]) -> Option<Vec<Case>> {
    let v = json::parse(corpus_json).ok()?;
    let mut out = Vec::new();
    for c in v.get("cases")?.as_array()? {
        out.push(Case {
            id: c.get("id")?.as_str()?.to_vec(),
            level: c.get("level")?.as_str()?.to_vec(),
            adoc: c.get("adoc")?.as_str()?.to_vec(),
            asg: c.get("asg")?.clone(),
            note: c.get("note").and_then(|n| n.as_str()).map(|n| n.to_vec()),
        });
    }
    Some(out)
}

/// Run one corpus end to end in one `Mode`, collecting the tally, coverage
/// and — up to `max_failures` — detailed failure records.
pub fn run_corpus(corpus_json: &[u8], mode: Mode, max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    let cases = load_cases(corpus_json).expect("corpus JSON has the expected shape");
    let mut result = RunResult::default();
    for case in &cases {
        result.summary.total += 1;
        let root = if case.level == b"block" { Root::Document } else { Root::Inlines };
        let doc = match mode {
            Mode::Codec => asg::decode(&case.adoc, root, &case.asg, Some(&mut result.coverage)),
            Mode::Parse => Ok(match root {
                Root::Document => parser::parse(&case.adoc),
                Root::Inlines => parser::parse_inline_list(&case.adoc),
            }),
        };
        let doc = match doc {
            Ok(d) => d,
            Err(e) => {
                result.summary.failed += 1;
                let name = if mode == Mode::Codec { "codec" } else { "parse" };
                record_failure(max_failures, failures, case, format!("<{} error: {}>", name, e).into_bytes());
                continue;
            }
        };
        let actual_json = asg::encode(&doc, root);
        let ok = match json::parse(&actual_json) {
            Ok(actual) => asg::json_value_eql(&actual, &case.asg),
            Err(_) => false,
        };
        if ok {
            result.summary.passed += 1;
        } else {
            result.summary.failed += 1;
            record_failure(max_failures, failures, case, actual_json);
        }
    }
    result
}

fn record_failure(max_failures: usize, failures: &mut Vec<Failure>, case: &Case, actual: Vec<u8>) {
    if failures.len() >= max_failures {
        return;
    }
    failures.push(Failure {
        id: case.id.clone(),
        adoc: case.adoc.clone(),
        expected: expected_text(&case.asg),
        actual,
        note: case.note.clone(),
    });
}

/// The vendored TCK through the codec.
pub fn run(max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    run_corpus(TCK_CORPUS_JSON, Mode::Codec, max_failures, failures)
}

/// The vendored TCK through the parser.
pub fn run_parse(max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    run_corpus(TCK_CORPUS_JSON, Mode::Parse, max_failures, failures)
}

fn expected_text(value: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    Stringify::pretty(&mut out).value(value);
    out
}

/// A run's failures, printed for a human.
pub fn format_failures(failures: &[Failure]) -> String {
    let mut s = String::new();
    for f in failures {
        let l = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
        s.push_str(&format!("\n-- {} --\nadoc:\n{}\n", l(&f.id), l(&f.adoc)));
        if let Some(n) = &f.note {
            s.push_str(&format!("note: {}\n", l(n)));
        }
        s.push_str(&format!("expected:\n{}\nactual:\n{}\n", l(&f.expected), l(&f.actual)));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asciidoc_tck_corpus_round_trips_through_the_asg_codec() {
        let mut failures = Vec::new();
        let result = run(10, &mut failures);
        assert_eq!(
            result.summary.failed,
            0,
            "TCK round-trip {}/{}; coverage {:?}{}",
            result.summary.passed,
            result.summary.total,
            result.coverage,
            format_failures(&failures)
        );
        assert_eq!(result.summary.total, 13);
        assert!(result.coverage.semantic >= SEMANTIC_BASELINE, "{:?}", result.coverage);
    }

    #[test]
    fn asciidoc_parser_reproduces_expected_asgs_for_the_tck_corpus() {
        let mut failures = Vec::new();
        let result = run_parse(10, &mut failures);
        assert!(
            result.summary.passed as u32 >= PARSE_BASELINE,
            "parse (TCK): {}/{}{}",
            result.summary.passed,
            result.summary.total,
            format_failures(&failures)
        );
    }

    #[test]
    fn asciidoc_parser_reproduces_expected_asgs_for_twigs_own_corpus() {
        let mut failures = Vec::new();
        let result = run_corpus(TWIG_CORPUS_JSON, Mode::Parse, 10, &mut failures);
        assert!(
            result.summary.passed as u32 >= TWIG_PARSE_BASELINE,
            "parse (twig): {}/{}{}",
            result.summary.passed,
            result.summary.total,
            format_failures(&failures)
        );
    }

    #[test]
    fn twigs_own_asciidoc_corpus_round_trips_through_the_asg_codec() {
        let mut failures = Vec::new();
        let result = run_corpus(TWIG_CORPUS_JSON, Mode::Codec, 10, &mut failures);
        assert!(
            result.summary.passed as u32 >= TWIG_CODEC_BASELINE,
            "codec (twig): {}/{}{}",
            result.summary.passed,
            result.summary.total,
            format_failures(&failures)
        );
    }
}
