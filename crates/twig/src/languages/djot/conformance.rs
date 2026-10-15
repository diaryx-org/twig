//! Runs the vendored djot.js conformance corpus (`testdata/*.test`) against
//! `parse` + `html`. Port of `conformance.zig`.
//!
//! Each file is prose with embedded fenced blocks:
//!
//! ````text
//! ```<options>
//! <djot input>
//! .
//! <expected HTML output>
//! ```
//! ````
//!
//! opened by a line of 3+ backticks optionally followed by an "options"
//! string, closed by a line starting with AT LEAST as many backticks as the
//! opener. `options` containing `a` means "compare against djot.js's AST
//! pretty-printer" — a djot.js-internal debug format this port doesn't
//! reproduce: those cases are skipped here and their behaviours asserted
//! natively (see `mod.rs` and `parser.rs` tests).

/// The vendored fixture files, in the order `conformance.zig` lists them.
pub const TEST_FILES: &[&str] = &[
    "attributes.test",
    "block_quote.test",
    "code_blocks.test",
    "definition_lists.test",
    "symb.test",
    "emphasis.test",
    "escapes.test",
    "fenced_divs.test",
    "footnotes.test",
    "headings.test",
    "insert_delete_mark.test",
    "links_and_images.test",
    "lists.test",
    "math.test",
    "para.test",
    "raw.test",
    "regression.test",
    "smart.test",
    "spans.test",
    "sourcepos.test",
    "super_subscript.test",
    "tables.test",
    "task_lists.test",
    "thematic_breaks.test",
    "verbatim.test",
];

#[derive(Clone, Debug)]
pub struct TestCase {
    pub line: usize,
    pub options: Vec<u8>,
    pub input: Vec<u8>,
    pub expected: Vec<u8>,
}

pub fn testdata_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../src/languages/djot/testdata")
}

/// Read one fixture file from the shared testdata directory.
pub fn read_test_file(name: &str) -> Vec<u8> {
    std::fs::read(testdata_dir().join(name)).expect("djot testdata")
}

fn starts_with_fence(line: &[u8]) -> bool {
    line.len() >= 3 && &line[..3] == b"```"
}

fn is_close_fence(line: &[u8], tick_len: usize) -> bool {
    line.len() >= tick_len && line[..tick_len].iter().all(|&c| c == b'`')
}

fn strip_cr(line: &[u8]) -> &[u8] {
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn trim_space_tab(s: &[u8]) -> &[u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && (s[a] == b' ' || s[a] == b'\t') {
        a += 1;
    }
    while b > a && (s[b - 1] == b' ' || s[b - 1] == b'\t') {
        b -= 1;
    }
    &s[a..b]
}

/// Parse every fenced test case out of `content`.
pub fn parse_tests(content: &[u8]) -> Vec<TestCase> {
    let lines: Vec<&[u8]> = content.split(|&c| c == b'\n').map(strip_cr).collect();
    let mut out = Vec::new();
    let mut idx = 0;
    loop {
        let mut open_line: Option<&[u8]> = None;
        while idx < lines.len() {
            let l = lines[idx];
            idx += 1;
            if starts_with_fence(l) {
                open_line = Some(l);
                break;
            }
        }
        let Some(line) = open_line else { break };
        let testlinenum = idx;
        let tick_len = line.iter().take_while(|&&c| c == b'`').count();
        let options = trim_space_tab(&line[tick_len..]).to_vec();

        let mut input = Vec::new();
        while idx < lines.len() {
            let l = lines[idx];
            idx += 1;
            if l == b"." || l == b"!" {
                break;
            }
            input.extend_from_slice(l);
            input.push(b'\n');
        }
        let mut expected = Vec::new();
        while idx < lines.len() {
            let l = lines[idx];
            idx += 1;
            if is_close_fence(l, tick_len) {
                break;
            }
            expected.extend_from_slice(l);
            expected.push(b'\n');
        }
        out.push(TestCase { line: testlinenum, options, input, expected });
    }
    out
}

/// Every case of every fixture file, tagged with its file name.
pub fn all_cases() -> Vec<(&'static str, TestCase)> {
    let mut out = Vec::new();
    for name in TEST_FILES {
        for c in parse_tests(&read_test_file(name)) {
            out.push((*name, c));
        }
    }
    out
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub skipped: usize,
}

#[derive(Clone, Debug)]
pub struct Failure {
    pub file: String,
    pub line: usize,
    pub input: Vec<u8>,
    pub expected: Vec<u8>,
    pub actual: Vec<u8>,
}

/// Run every fixture, collecting a summary and (up to `max_failures`)
/// detailed failure records.
pub fn run(max_failures: usize, failures: &mut Vec<Failure>) -> Summary {
    let mut summary = Summary::default();
    for (file, c) in all_cases() {
        summary.total += 1;
        if c.options.contains(&b'a') {
            summary.skipped += 1;
            continue;
        }
        let doc = super::parse(&c.input);
        let rendered = super::html::render(&doc, &Default::default()).unwrap_or_else(|e| format!("<{e:?}>").into_bytes());
        if rendered == c.expected {
            summary.passed += 1;
        } else {
            summary.failed += 1;
            if failures.len() < max_failures {
                failures.push(Failure {
                    file: file.to_string(),
                    line: c.line,
                    input: c.input.clone(),
                    expected: c.expected.clone(),
                    actual: rendered,
                });
            }
        }
    }
    summary
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn djot_js_conformance_corpus() {
        let mut failures = Vec::new();
        let summary = run(40, &mut failures);
        if summary.failed > 0 {
            eprintln!(
                "\ndjot conformance: {}/{} HTML cases passed, {} failed ({} AST-dump cases skipped)",
                summary.passed,
                summary.total - summary.skipped,
                summary.failed,
                summary.skipped
            );
            for f in &failures {
                eprintln!(
                    "\n-- {}:{} --\ninput:\n{}\nexpected:\n{}\nactual:\n{}",
                    f.file,
                    f.line,
                    String::from_utf8_lossy(&f.input),
                    String::from_utf8_lossy(&f.expected),
                    String::from_utf8_lossy(&f.actual)
                );
            }
        }
        assert_eq!(summary.failed, 0);
        assert_eq!(summary.passed, 265);
    }
}
