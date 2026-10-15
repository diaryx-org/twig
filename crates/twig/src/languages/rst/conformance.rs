//! The reStructuredText conformance harness: runs the vendored docutils corpus
//! (`src/languages/rst/testdata/docutils-rst-corpus.json`, 713 cases from
//! docutils 0.21.2's own `test/test_parsers/test_rst`) against `doctree`'s
//! codec and `parser`. Port of `src/languages/rst/conformance.zig`.
//!
//! ── The codec round-trip (`run`/`SEMANTIC_BASELINE`) ────────────────────────
//! `encode(decode(expected)) == expected` over all 713 pins the pformat
//! grammar, and, through `Coverage`, measures how much of docutils' element
//! vocabulary twig's shared `Ast` holds semantically. A RATCHET.
//!
//! ── The parse comparison (`run_parse`/`PARSE_BASELINE`) ─────────────────────
//! `parser::parse(case.rst)` → `encode` → compare against `case.doctree`, for
//! the 494 cases whose expectation has no `<system_message>`. The other 219
//! need the diagnostics-to-tree projection, so they are skipped outright
//! rather than counted as failures.
//!
//! The corpus is READ at run time from the shared test data (Zig embeds it).

use super::doctree::{self, Coverage, Tag};
use super::parser;
use super::system_message;
use crate::ast::{Ast, Kind, NodeId};

/// Where the shared corpus lives.
pub fn corpus_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../src/languages/rst/testdata/docutils-rst-corpus.json")
}

/// Ratchet floor: element instances across the corpus that decode to a twig
/// SEMANTIC kind rather than a generic `container` (4347 of 5682).
pub const SEMANTIC_BASELINE: u32 = 4347;

/// Tag-shaped text lines whose name is not a docutils element, corpus-wide:
/// exactly one (`<URL>`). Pinned rather than merely reported.
pub const UNKNOWN_TAG_SHAPED_TEXT: u32 = 1;

/// Tier A message instances `system_message::recognize` claims and `write`
/// reproduces byte-for-byte: 158 of the 299.
pub const MESSAGE_BASELINE: u32 = 158;

/// Ratchet floor for `run_parse`: of the 494 error-free cases, how many does
/// `parser::parse` → `encode` reproduce byte-for-byte.
pub const PARSE_BASELINE: u32 = 100;

/// One extracted docutils test case.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Case {
    /// Path of the docutils test module, relative to `test/test_parsers/test_rst`.
    pub file: Vec<u8>,
    /// The `totest` key the case was listed under.
    pub group: Vec<u8>,
    /// Index within that group.
    pub index: u32,
    /// Line in the docutils source the case starts at.
    pub line: u32,
    /// The reStructuredText input.
    pub rst: Vec<u8>,
    /// The expected doctree, as `document.pformat()` writes it.
    pub doctree: Vec<u8>,
    /// Whether the expectation contains a `<system_message>`.
    pub asserts_error: bool,
}

/// Parse a corpus JSON document (`{"provenance": …, "cases": [...]}`).
pub fn parse_corpus(text: &[u8]) -> Result<Vec<Case>, String> {
    let v = crate::json::parse(text).map_err(|e| e.to_string())?;
    let cases = v.get("cases").and_then(|c| c.as_array()).ok_or("corpus has no `cases` array")?;
    let mut out = Vec::with_capacity(cases.len());
    for c in cases {
        let s = |k: &str| c.get(k).and_then(|x| x.as_str()).map(|x| x.to_vec()).ok_or(format!("case missing `{k}`"));
        let n = |k: &str| c.get(k).and_then(|x| x.as_int()).map(|x| x as u32).ok_or(format!("case missing `{k}`"));
        out.push(Case {
            file: s("file")?,
            group: s("group")?,
            index: n("index")?,
            line: n("line")?,
            rst: s("rst")?,
            doctree: s("doctree")?,
            asserts_error: c.get("asserts_error").and_then(|x| x.as_bool()).ok_or("case missing `asserts_error`")?,
        });
    }
    Ok(out)
}

/// Read and parse the shared corpus.
pub fn load_corpus() -> Result<Vec<Case>, String> {
    let path = corpus_path();
    let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    parse_corpus(&bytes)
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    /// Of `total`, how many expectations contain a `<system_message>`.
    pub asserts_error: usize,
}

/// Per-`totest`-group tallies.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GroupStat {
    pub file: Vec<u8>,
    pub group: Vec<u8>,
    pub passed: usize,
    pub total: usize,
}

/// One failing case.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub file: Vec<u8>,
    pub group: Vec<u8>,
    pub index: u32,
    pub line: u32,
    pub rst: Vec<u8>,
    pub expected: Vec<u8>,
    pub actual: Vec<u8>,
}

#[derive(Clone, Debug, Default)]
pub struct RunResult {
    pub summary: Summary,
    pub coverage: Coverage,
    pub groups: Vec<GroupStat>,
}

fn failure(case: &Case, actual: Vec<u8>) -> Failure {
    Failure {
        file: case.file.clone(),
        group: case.group.clone(),
        index: case.index,
        line: case.line,
        rst: case.rst.clone(),
        expected: case.doctree.clone(),
        actual,
    }
}

/// Decode every expected doctree and encode it straight back, collecting the
/// round-trip tally, the vocabulary coverage, and (up to `max_failures`)
/// detailed failure records.
pub fn run(cases: &[Case], max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    let mut result = RunResult::default();
    for case in cases {
        result.summary.total += 1;
        if case.asserts_error {
            result.summary.asserts_error += 1;
        }
        let stat = group_stat(&mut result.groups, case);
        result.groups[stat].total += 1;

        let actual = round_trip(&case.doctree, &mut result.coverage);
        if actual == case.doctree {
            result.summary.passed += 1;
            result.groups[stat].passed += 1;
        } else {
            result.summary.failed += 1;
            if failures.len() < max_failures {
                failures.push(failure(case, actual));
            }
        }
    }
    result
}

fn round_trip(expected: &[u8], coverage: &mut Coverage) -> Vec<u8> {
    let ast = match doctree::decode(expected, Some(coverage)) {
        Ok(a) => a,
        Err(e) => return format!("<decode error: {}>", e.name()).into_bytes(),
    };
    match doctree::encode_alloc(&ast) {
        Ok(out) => out,
        Err(e) => format!("<decode error: {}>", e.name()).into_bytes(),
    }
}

/// The stat row index for `case`'s group, appending one if new.
fn group_stat(groups: &mut Vec<GroupStat>, case: &Case) -> usize {
    if let Some(i) = groups.iter().position(|g| g.file == case.file && g.group == case.group) {
        return i;
    }
    groups.push(GroupStat { file: case.file.clone(), group: case.group.clone(), passed: 0, total: 0 });
    groups.len() - 1
}

/// Write the vocabulary coverage table: per docutils element, how many
/// instances fell back to the `container` fallback, most first.
pub fn write_coverage(w: &mut Vec<u8>, coverage: &Coverage) {
    w.extend_from_slice(
        format!(
            "  vocabulary: {}/{} element instances decode to a semantic kind ({} generic containers, {} dissolved), {} text nodes\n",
            coverage.semantic_total(),
            coverage.element_total(),
            coverage.generic_total(),
            coverage.dissolved_total(),
            coverage.text_nodes,
        )
        .as_bytes(),
    );
    w.extend_from_slice(b"  unmapped elements, by instance count:\n");
    let mut printed = [false; Tag::COUNT];
    loop {
        let mut best: Option<Tag> = None;
        let mut best_n = 0u32;
        for &tag in Tag::ALL {
            if printed[tag.index()] {
                continue;
            }
            let n = coverage.generic[tag.index()];
            if n > best_n {
                best = Some(tag);
                best_n = n;
            }
        }
        let Some(tag) = best else { break };
        printed[tag.index()] = true;
        w.extend_from_slice(format!("    {:>5}  {}\n", best_n, tag.name()).as_bytes());
    }
}

/// Parse every error-free case and compare its encoding to the expectation.
pub fn run_parse(cases: &[Case], max_failures: usize, failures: &mut Vec<Failure>) -> RunResult {
    let mut result = RunResult::default();
    for case in cases {
        // Excluded rather than counted: no honest pass/fail answer yet.
        if case.asserts_error {
            continue;
        }
        result.summary.total += 1;
        let stat = group_stat(&mut result.groups, case);
        result.groups[stat].total += 1;

        let actual = parse_and_encode(&case.rst);
        if actual == case.doctree {
            result.summary.passed += 1;
            result.groups[stat].passed += 1;
        } else {
            result.summary.failed += 1;
            if failures.len() < max_failures {
                failures.push(failure(case, actual));
            }
        }
    }
    result
}

/// `parser::parse` with the corpus's `source_name`, encoded as a doctree (or
/// `<parse error: …>`).
pub fn parse_and_encode(source: &[u8]) -> Vec<u8> {
    let result = parser::parse(source, &parser::Options { source_name: b"test data".to_vec() });
    match doctree::encode_alloc(&result.document.ast) {
        Ok(out) => out,
        Err(e) => format!("<parse error: {}>", e.name()).into_bytes(),
    }
}

/// Every `<system_message>` in the corpus, tallied by whether twig can
/// account for its wording.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MessageStats {
    pub total: u32,
    pub recognized: u32,
    /// Recognized but re-written differently — always a bug.
    pub mismatched: u32,
    /// A message whose paragraph is not a lone text run.
    pub unreadable: u32,
    /// Cases in which EVERY message is recognized.
    pub cases_fully_recognized: u32,
    /// Cases with at least one message.
    pub cases_with_messages: u32,
}

/// Walk every decoded case for `<system_message>` nodes and check each one's
/// wording against `write` ∘ `recognize`. `unclaimed` collects the messages
/// twig has no code for.
pub fn run_messages(
    cases: &[Case],
    mut unclaimed: Option<&mut Vec<Vec<u8>>>,
) -> Result<MessageStats, doctree::DecodeError> {
    let mut stats = MessageStats::default();
    for case in cases {
        if !case.asserts_error {
            continue;
        }
        stats.cases_with_messages += 1;
        let ast = doctree::decode(&case.doctree, None)?;

        let mut all_claimed = true;
        for node in &ast.nodes {
            match &node.kind {
                Kind::Container(c) if c.name == b"system_message" => {}
                _ => continue,
            }
            stats.total += 1;

            let Some(text) = message_text_of(&ast, node.id) else {
                stats.unreadable += 1;
                all_claimed = false;
                continue;
            };
            let Some(found) = system_message::recognize(text) else {
                all_claimed = false;
                if let Some(list) = unclaimed.as_deref_mut() {
                    list.push(text.to_vec());
                }
                continue;
            };
            stats.recognized += 1;
            if system_message::write_alloc(found.code, &found.args) != text {
                stats.mismatched += 1;
            }
        }
        if all_claimed {
            stats.cases_fully_recognized += 1;
        }
    }
    Ok(stats)
}

/// The message text of a `system_message`: its first child is a `<paragraph>`
/// holding one text run and nothing after it.
fn message_text_of(ast: &Ast, id: NodeId) -> Option<&[u8]> {
    let para = ast.node(id).first_child?;
    if *ast.kind(para) != Kind::Para {
        return None;
    }
    let text = ast.node(para).first_child?;
    if ast.node(text).next_sibling.is_some() {
        return None;
    }
    ast.kind(text).str_text()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lossy(b: &[u8]) -> std::borrow::Cow<'_, str> {
        String::from_utf8_lossy(b)
    }

    fn print_failures(groups: &[GroupStat], failures: &[Failure]) {
        for g in groups {
            if g.passed == g.total {
                continue;
            }
            eprintln!("    {}::{}  {}/{}", lossy(&g.file), lossy(&g.group), g.passed, g.total);
        }
        for f in failures {
            eprintln!(
                "\n-- {}::{}[{}] (docutils source line {}) --\nrST:\n{}\nexpected:\n{}\nactual:\n{}",
                lossy(&f.file),
                lossy(&f.group),
                f.index,
                f.line,
                lossy(&f.rst),
                lossy(&f.expected),
                lossy(&f.actual)
            );
        }
    }

    #[test]
    fn rst_parser_reproduces_expected_doctrees_for_error_free_corpus_cases() {
        let cases = load_corpus().unwrap();
        let mut failures = Vec::new();
        let result = run_parse(&cases, 10, &mut failures);
        if result.summary.passed != PARSE_BASELINE as usize {
            eprintln!(
                "\nrST parse: {}/{} error-free cases match ({} failed)",
                result.summary.passed, result.summary.total, result.summary.failed
            );
            print_failures(&result.groups, &failures);
        }
        assert_eq!(result.summary.total, 494);
        assert!(result.summary.passed >= PARSE_BASELINE as usize);
    }

    #[test]
    fn docutils_system_message_wording_round_trips_for_every_tier_a_code() {
        let cases = load_corpus().unwrap();
        let mut unclaimed = Vec::new();
        let stats = run_messages(&cases, Some(&mut unclaimed)).unwrap();
        if stats.mismatched > 0 || stats.recognized != MESSAGE_BASELINE {
            eprintln!(
                "\nrST system_message wording: {}/{} messages recognized ({} mismatched, {} unreadable); {}/{} error-asserting cases fully accounted for",
                stats.recognized,
                stats.total,
                stats.mismatched,
                stats.unreadable,
                stats.cases_fully_recognized,
                stats.cases_with_messages
            );
            let mut seen: Vec<&Vec<u8>> = Vec::new();
            for m in &unclaimed {
                if seen.contains(&m) {
                    continue;
                }
                seen.push(m);
                eprintln!("    unclaimed: {}", lossy(m));
            }
        }
        assert_eq!(stats.mismatched, 0);
        assert_eq!(stats.total, 299);
        assert!(stats.recognized >= MESSAGE_BASELINE);
    }

    #[test]
    fn docutils_doctree_corpus_round_trips_through_the_codec() {
        let cases = load_corpus().unwrap();
        let mut failures = Vec::new();
        let result = run(&cases, 10, &mut failures);
        if result.summary.failed > 0 || result.coverage.semantic_total() != SEMANTIC_BASELINE {
            eprintln!(
                "\nrST doctree round-trip: {}/{} cases ({} failed; {} of the corpus expects a system_message)",
                result.summary.passed, result.summary.total, result.summary.failed, result.summary.asserts_error
            );
            let mut report = Vec::new();
            write_coverage(&mut report, &result.coverage);
            eprint!("{}", lossy(&report));
            print_failures(&result.groups, &failures);
        }
        assert_eq!(result.summary.failed, 0);
        assert_eq!(result.summary.total, 713);
        assert_eq!(result.coverage.unknown_tag_shaped_text, UNKNOWN_TAG_SHAPED_TEXT);
        assert!(result.coverage.semantic_total() >= SEMANTIC_BASELINE);
    }
}
