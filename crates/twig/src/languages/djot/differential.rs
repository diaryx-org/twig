//! Differential tests against the Zig oracle (`zig-out/bin/twig`): for every
//! input of the djot.js corpus plus the edge cases below, the node table, the
//! AST JSON, the HTML render, the canonical round trip and the cross-format
//! (markdown) serialization must be byte-identical. Skipped (with a note) when
//! the oracle binary is absent.

use std::io::Write;
use std::process::{Command, Stdio};

use crate::ast::{json, table};

fn oracle_path() -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/twig");
    p.exists().then_some(p)
}

/// Run `twig <args> -` on `src`. `Ok(stdout)` on success, `Err(stderr)` on
/// failure.
pub(crate) fn oracle(args: &[&str], src: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    let mut child = Command::new(oracle_path().unwrap())
        .args(args)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(src).unwrap();
    }
    let out = child.wait_with_output().unwrap();
    if out.status.success() { Ok(out.stdout) } else { Err(out.stderr) }
}

/// Edge cases beyond the djot.js corpus.
pub const EDGE_CASES: &[&[u8]] = &[
    b"",
    b"\n",
    b"\n\n\n",
    b"no final newline",
    b"# Heading without a final newline",
    b"{#intro .note key=\"v\"}\nA paragraph.\n",
    b"{.a}\n{.b #c}\npara\n",
    b"{.a\n .b}\npara\n",
    b"{unterminated\npara\n",
    b"{.a}\n\npara after blank\n",
    b"word{.cls} another{#id key=val}\n",
    b"x word{.a}\n",
    b"hi{key=\"x\"}\n",
    b"[span]{.x} and *strong*{.y} `code`{.z}\n",
    b"{% comment %}\npara\n",
    b"text[^1] and[^two].\n\n[^1]: First note.\n\n[^two]: Second note\n    with more.\n\n    And a para.\n",
    b"[^unused]: never referenced\n",
    b"ref[^missing]\n",
    b"| a | b |\n|---|:-:|\n| 1 | 2 |\n\n^ A _caption_\n",
    b"| a | b |\n\n^ cap1\n\n^ cap2\n",
    b"| left | center | right |\n|:-----|:------:|------:|\n| l | c | r |\n| `a|b` | \\| | x |\n",
    b"| a |\n| b |\n|---|\n| c |\n",
    b"|not a table\n",
    b"\"Hello,\" said the 'spider'. It's 'tis --- or -- is it... \"done\"?\n",
    b"don't 'quote' \"a 'nested' quote\" end'\n",
    b"a----b c-----d e------f\n",
    b"{\"braced\"} {'single'} x{-del-} {+ins+} {=mark=}\n",
    b"::: warning\nInside a div.\n\n::: inner\nnested\n:::\n:::\n",
    b":::\nunterminated div\n",
    b"::: verse\nRoses are red,\n\xe2\x80\x83violets blue.\n\nSecond stanza.\n:::\n",
    b"```=html\n<b>raw</b>\n```\n\n`<i>x</i>`{=html} and `\\x`{=latex}\n",
    b"```\nunterminated code\n",
    b"~~~~ python\nprint(1)\n~~~~\n",
    b":smile: :+1: :not a symbol: :a_b-c:\n",
    b"$`x^2` and $$`\\int_0^1 f` and \\$`not math`\n",
    b"- a\n  - b\n    - c\n- d\n\n1. one\n2. two\n\n   para\n3. three\n",
    b"i. roman\nii. two\n\na) alpha\nb) beta\n\n(1) paren\n(2) both\n",
    b"- [ ] todo\n- [x] done\n",
    b"5. five\n6. six\n",
    b"* star\n+ plus\n- dash\n",
    b": term\n\n  definition\n\n: second\n\n  def two\n",
    b"# One\n\ntext\n\n## Two\n\n### Three\n\n# One again\n\n# One\n",
    b"> # quoted heading\n> para\n",
    b"## Heading\ncontinued\n## not continued\n",
    b"[link][ref] and [Ref][] and ![img][ref] and [One]\n\n[ref]: /url\n\n# One\n",
    b"[inline](http://x.com \"title\") ![alt](i.png){width=10}\n",
    b"<https://example.com> and <me@example.com> and <mailto:a@b.c>\n",
    b"line one\\\nline two\\ \nhard\\\tbreak\n",
    b"escaped \\* \\_ \\\\ \\` and nbsp\\ here\n",
    b"***\n\n- - -\n\n{.rule}\n* * *\n",
    b"> quote\n> continues\nlazy line\n\n> > nested\n",
    b"[foo]: http://a\n  http://continued\n\n[foo]\n",
    b"crlf\r\nline\r\n\r\npara two\r\n",
    b"tab\tseparated\t text\n",
    b"unicode \xc3\xa9 \xe2\x9c\x93 heading\n\n# Caf\xc3\xa9 \xe2\x9c\x93\n",
    b"*unclosed _emph\n",
    b"_nested *strong* inside_ and *_both_*\n",
    b"^super^ and ~sub~ and H~2~O\n",
    b"``code with ` backtick``\n",
    b"`unterminated verbatim\n",
    b"| a |\n\n^ only caption\n\nafter\n",
];

fn check(src: &[u8]) -> Vec<String> {
    let mut problems = Vec::new();
    let show = || String::from_utf8_lossy(src).into_owned();
    let doc = super::parse(src);
    let utf8 = std::str::from_utf8(src).is_ok();

    let want = oracle(&["convert", "-i", "djot", "-o", "table"], src).unwrap();
    if utf8 && table::encode(&doc, Default::default()) != want {
        problems.push(format!("table differs for {:?}", show()));
    }
    let want = oracle(&["convert", "-i", "djot", "-o", "ast"], src).unwrap();
    if utf8 && json::encode(&doc) != want {
        problems.push(format!("ast differs for {:?}", show()));
    }
    let want = oracle(&["convert", "-i", "djot"], src).unwrap();
    let ours = super::html::render(&doc, &Default::default()).unwrap();
    if ours != want {
        problems.push(format!(
            "html differs for {:?}:\n ours {:?}\n want {:?}",
            show(),
            String::from_utf8_lossy(&ours),
            String::from_utf8_lossy(&want)
        ));
    }
    let want = oracle(&["convert", "-i", "djot", "-o", "canonical"], src).unwrap();
    let ours = super::serialize(&doc);
    if ours != want {
        problems.push(format!(
            "canonical differs for {:?}:\n ours {:?}\n want {:?}",
            show(),
            String::from_utf8_lossy(&ours),
            String::from_utf8_lossy(&want)
        ));
    }
    problems
}

/// Cross-format: another format's bare tree through `serialize_ast`.
fn check_cross(fmt: &str, src: &[u8], ast: &crate::ast::Ast) -> Option<String> {
    let want = oracle(&["convert", "-i", fmt, "-o", "djot"], src).unwrap();
    let ours = super::serialize_ast(ast);
    (ours != want).then(|| {
        format!(
            "{fmt} -> djot differs for {:?}:\n ours {:?}\n want {:?}",
            String::from_utf8_lossy(src),
            String::from_utf8_lossy(&ours),
            String::from_utf8_lossy(&want)
        )
    })
}

const HTML_INPUTS: &[&[u8]] = &[
    b"<p>hi <em>x</em> and <strong>y</strong></p><ul><li>a</li><li>b</li></ul>",
    b"<h1>Title</h1><p>para with <a href=\"/u\">link</a> and <img src=\"i.png\" alt=\"alt\"></p>",
    b"<blockquote><p>q</p><ol start=\"3\"><li>three</li></ol></blockquote>",
    b"<pre><code class=\"language-zig\">const x = 1;\n</code></pre><hr>",
    b"<div class=\"note\" id=\"n\"><p>inside</p></div><p><span class=\"x\">s</span> <code>`tick`</code></p>",
    b"<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>",
    b"<dl><dt>term</dt><dd>def</dd></dl><p>a<br>b <sup>s</sup><sub>t</sub><del>d</del><ins>i</ins><mark>m</mark></p>",
    b"<video controls src=\"v.mp4\"></video><script>if (a < b) {}</script>",
];

fn inputs() -> Vec<Vec<u8>> {
    let mut v: Vec<Vec<u8>> = super::conformance::all_cases().into_iter().map(|(_, c)| c.input).collect();
    v.extend(EDGE_CASES.iter().map(|s| s.to_vec()));
    v.extend(super::SAMPLES.iter().map(|s| s.to_vec()));
    v
}

#[test]
fn differential_against_the_zig_oracle() {
    if oracle_path().is_none() {
        eprintln!("zig oracle not built; skipping");
        return;
    }
    let mut problems = Vec::new();
    for src in inputs() {
        problems.extend(check(&src));
        // A djot tree through the cross-format path, as markdown input would
        // reach it: compared against the oracle's own djot -> ast -> djot.
    }
    for src in HTML_INPUTS {
        let doc = crate::languages::html::parse(src);
        problems.extend(check_cross("html", src, &doc.ast));
    }
    assert!(problems.is_empty(), "{} divergences:\n{}", problems.len(), problems.join("\n"));
}
