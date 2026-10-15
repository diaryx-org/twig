//! Acceptance test: the vendored djot.js conformance corpus, rendered through
//! THIS module's generic `serialize` with the parsed document's own labels as
//! the `Context`. Port of `src/languages/html/conformance.zig`.
//!
//! TODO(port): the Zig suite parses each case with the djot parser. Until
//! `crate::languages::djot::parse` is ported, the documents come from the Zig
//! oracle's node table (`convert -i djot -o table`), read back with
//! `ast::table::decode` — the same tree, so the renderer is held to the same
//! byte-exact expectations. Swap `parse_djot` for the Rust parser then.

use std::path::PathBuf;

use super::serializer::serialize_alloc;
use crate::document::Document;

/// The fixtures, read from `src/languages/djot/testdata/`.
pub const DJOT_TESTFILES: [&str; 25] = [
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

pub struct TestCase {
    pub line: usize,
    pub options: Vec<u8>,
    pub input: Vec<u8>,
    pub expected: Vec<u8>,
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

/// Parse every fenced test case out of `content` (djot.js's fixture format).
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
        let opts = &line[tick_len..];
        let a = opts.iter().take_while(|c| b" \t".contains(c)).count();
        let b = opts.iter().rev().take_while(|c| b" \t".contains(c)).count();
        let options = if a >= opts.len() { Vec::new() } else { opts[a..opts.len() - b].to_vec() };

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

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// TODO(port): replace with `crate::languages::djot::parse` once ported.
fn parse_djot(input: &[u8]) -> Option<Document> {
    let bin = repo().join("zig-out/bin/twig");
    let out = std::process::Command::new(bin)
        .args(["convert", "-i", "djot", "-o", "table", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()
        .and_then(|mut child| {
            use std::io::Write;
            let mut stdin = child.stdin.take().unwrap();
            let data = input.to_vec();
            let t = std::thread::spawn(move || {
                let _ = stdin.write_all(&data);
            });
            let o = child.wait_with_output().ok();
            t.join().unwrap();
            o
        })?;
    if !out.status.success() {
        return None;
    }
    crate::ast::table::decode(input, &out.stdout).ok()
}

#[test]
fn shared_html_printer_matches_djot_js_conformance_corpus() {
    if !repo().join("zig-out/bin/twig").exists() {
        eprintln!("oracle not built; skipping (TODO(port): use the Rust djot parser)");
        return;
    }
    let mut total = 0;
    let mut skipped = 0;
    let mut failures: Vec<String> = Vec::new();
    for name in DJOT_TESTFILES {
        let content = std::fs::read(repo().join("src/languages/djot/testdata").join(name)).unwrap();
        for c in parse_tests(&content) {
            total += 1;
            if c.options.contains(&b'a') {
                // AST-pretty-print mode: neither renderer implements it.
                skipped += 1;
                continue;
            }
            let rendered = match parse_djot(&c.input) {
                Some(doc) => serialize_alloc(&doc.ast, Some(&doc.labels)).unwrap(),
                None => b"<parse error>".to_vec(),
            };
            if rendered != c.expected {
                failures.push(format!(
                    "-- {name}:{} --\ninput:\n{}\nexpected:\n{}\nactual:\n{}",
                    c.line,
                    String::from_utf8_lossy(&c.input),
                    String::from_utf8_lossy(&c.expected),
                    String::from_utf8_lossy(&rendered)
                ));
            }
        }
    }
    assert!(total - skipped > 200, "corpus too small: {total}");
    if !failures.is_empty() {
        panic!(
            "html printer conformance: {} of {} cases failed\n{}",
            failures.len(),
            total - skipped,
            failures.iter().take(20).cloned().collect::<Vec<_>>().join("\n")
        );
    }
}
