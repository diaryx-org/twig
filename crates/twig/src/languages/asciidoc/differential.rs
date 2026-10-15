//! Differential tests: every input in both AsciiDoc corpora (plus the
//! module's samples and a set of edge cases) through the Zig oracle binary
//! (`zig-out/bin/twig`) and through this port, comparing `-o table`,
//! `-o ast`, `-o canonical` and (once the HTML renderer is ported) HTML bytes.
//! Skipped, loudly, when the oracle binary is absent.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::json;

fn oracle() -> Option<PathBuf> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/twig");
    if p.exists() {
        Some(p)
    } else {
        eprintln!("asciidoc differential: oracle {} not found, skipping", p.display());
        None
    }
}

fn run_oracle(bin: &PathBuf, args: &[&str], input: &[u8]) -> Option<Vec<u8>> {
    let mut child = Command::new(bin)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    child.stdin.take().unwrap().write_all(input).ok()?;
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(out.stdout)
}

pub(crate) fn corpus_inputs(file: &str) -> Vec<(String, Vec<u8>)> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../src/languages/asciidoc/testdata").join(file);
    let text = std::fs::read(&path).expect("corpus file");
    let v = json::parse(&text).expect("corpus JSON");
    let cases = v.get("cases").and_then(|c| c.as_array()).expect("cases");
    cases
        .iter()
        .map(|c| {
            let id = c.get("id").and_then(|x| x.as_str_lossy()).unwrap_or_default();
            let adoc = c.get("adoc").and_then(|x| x.as_str()).unwrap_or_default().to_vec();
            (id, adoc)
        })
        .collect()
}

/// Inputs beyond the corpora: the samples, the parser's unit-test sources and
/// assorted edge cases.
fn extra_inputs() -> Vec<(String, Vec<u8>)> {
    let mut v: Vec<&[u8]> = Vec::new();
    v.extend(super::SAMPLES.iter().copied());
    v.extend([
        &b""[..],
        b"\n",
        b"   \n",
        b"\n\n\n",
        b"= \n",
        b"----\n",
        b"****\n",
        b"*\n",
        b"|===\n",
        b"|===\n|\n",
        b"[[\n",
        b"[]\n",
        b".\n",
        b"..\n",
        b"term::\n",
        b"* \n",
        b"+\n",
        b"footnote:[]\n",
        b"image::[]\n",
        b"<<>>\n",
        b"[.]*x*\n",
        b"> \n",
        b"```\n",
        b"[verse]\n____\n____\n",
        b"NOTE: \n",
        b"---\n",
        b"---\n---\n",
        b"&#0;\n",
        b"{}\n",
        b"1. \n",
        b"= T\nA <\n",
        b"[source]\n",
        b"[quote]\n\n",
        b"\\\n",
        b"*a\n**b\n",
        b"|===\n2+|a\n|===\n",
        b"A paragraph that consists of a single line.\n",
        b"= Document Title\n:icons: font\n:toc:\n",
        b"= Title\nDoc Writer <doc@example.org>; Ann B. Lee\nv2.1, 2024-05-01: Remark\n:toc:\n",
        b"= T\nA B C D\n",
        b"= T\nA B C D E\n",
        b"---\ntitle: x\n---\n= Title\n\nbody\n",
        b"== One\n\n=== Two\n\npar\n\n== Three\n",
        b"[.classy]\n== One [[one]]\n\npar\n",
        b".A title\n[#the-id.a.b%opt,key=val]\ntext\n",
        b"[lead,second]\ntext\n",
        b"[source,ruby]\n----\nputs 1\n----\n",
        b"[,js]\n----\nx\n----\n\n```py\ny\n```\n",
        b"++++\n<div>x</div>\n++++\n",
        b"NOTE: remember\n\n[TIP]\nhandy\n\n[WARNING]\n====\ncareful\n====\n",
        b"[quote,Someone]\nwords\n\n[verse]\n____\nRoses\n    deep\n  mid\n____\n",
        b"> one *two*\n> \n> - item\n",
        b"[discrete]\n== Title\n\npar\n",
        b"image::a.png[Alt,200,100]\n\nvideo::v.mp4[poster.png]\n\ntoc::[]\n",
        b":name: Twig\n\nHello {name} and {nbsp}there {undefined-one}\n",
        b"a{sp}b{startsb}c{endsb}\n",
        b"* water\n",
        b"c. one\nd. two\n\n[]\niv) four\n",
        b"* [x] done\n* [ ] todo\n\n[]\n* [x] a\n* b\n",
        b"* one\n+\n[source]\n----\ncode\n----\n+\nmore\n* two\n",
        b"CPU:: brain\nRAM::\n  memory\n+\nextra\nGPU::\n* fast\n",
        b".Fruit\n[cols=\"1,1\",options=\"header\"]\n|===\n|Name |Count\n\n|Apple\n^|3\n\n2+|wide\n|===\n",
        b"|===\n|A |B\n\n|1 |2\n|===\n",
        b"|===\n|A |B\n|1 |2\n|===\n",
        b"|===\n|one\nline two \\| kept\n|three\n|===\n",
        b"*s* **u** `m` ^up^ ~down~ \"`dq`\" '`sq`'\n",
        b"^a b^ and **bold*\n",
        b"****\n",
        b"[.big]*x* [.red#r]#y# [#only]_z_\n",
        b"xfootnote:[n] xhttps://a.org\n",
        b"see [1] and [.x]plain\n",
        b"https://a.org <https://b.org> https://c.org[C^] link:d.html[D,window=_blank,role=ext] x@y.org\n",
        b"<<sec>> <<sec,Text>> xref:other#frag[]\n",
        b"see image:a.png[Alt,50] here\n",
        b"a footnote:[first] b footnote:named[second] c footnote:named[]\n",
        b"+++<b>+++ pass:[<i>] stem:[x^2] kbd:[Ctrl+C] btn:[OK] [[here]] anchor:there[]\n",
        b"a +\nb\n\n[%hardbreaks]\nc\nd\n",
        b"(C) a->b x--y wait...\n",
        b"\\*a* \\link:x[y] \\https://z.org \\\\ \\q\n",
        b"a &amp; &#x41; &bogus; b\n",
        b"    one\n      two\n",
        b"= T\nA B <a@b.org>\n\nNOTE: x^2^ ~s~ \"`q`\" [.r]#y# image:i.png[] footnote:[f] {v} {nbsp} +++r+++ pass:[p] stem:[m] kbd:[K] [[a]] a +\nb\n\n:e: v\n\n[quote]\nq\n\n> md\n\n|===\n|c\n|===\n\n* [x] t\n\n[verse]\nv\n",
        b"----\ncode\n----\n\n[source,ruby]\n----\nx\n----\n",
        b"= Title\n:toc:\n:icons: font\n\nIntro *bold* and _em_.\n\n== Section\n\nBody.\n",
        b"a **b** c sub**str**ing `m` x``y``z ##h## ^s^ ~t~\n",
        b"- one\n- two\n** deep\n+\nattached\n\n[]\n. first\n.. inner\n\n[]\nterm:: desc\nother::: nested\n",
        b"* [x] done\n* [ ] todo\n\n[loweralpha,start=3]\n. c\n. d\n",
        b"[source,ruby]\n----\nputs 1\n----\n\n[NOTE]\n====\ncareful\n====\n\n[quote,Someone,Somewhere]\n____\nwords\n____\n\n[verse]\n____\nRoses\n  red\n____\n\n.Fruit\n[%header,cols=2]\n|===\n|Name\n|Count\n\n|Apple\n^|3\n|===\n",
        b"See https://x.org[X] and <<sec,There>> and image:i.png[Alt,50] and footnote:[note] and [[a]] and stem:[x] and +++<b>+++ and {name}.\n",
        b"-----\n----\nx\n-----\n",
        b"pre**fix**\n",
        b"&#1114112; &#xD800; &#-0; &#+65; &#1_0; &#x;\n",
        b"[cols=\"3*\"]\n|===\n|a|b|c\n|d|e|f\n|===\n",
        b"[cols=3]\n|===\n|a|b|c|d\n|===\n",
        b"|===\n|a .2+|b\n2.3+^.>s|c\n|===\n",
        b"<1> callout\n<2> next\n",
        b"<.> auto\n",
        b"[arabic,start=x]\n. a\n",
        b"mailto:a@b.org[Mail,Subject] link:x[,role=r]\n",
        b"[pass]\n<b>hi</b>\n\n[stem]\nx^2\n\n[literal]\nlit\n\n[listing]\nlst\n",
        b"[example]\nex\n\n[sidebar]\nsb\n\n[abstract]\nabs\n\n[normal]\n  not literal\n",
        b"[quote]\n____\ninside\n____\n\n[source]\n--\ncode\n--\n\n[NOTE]\n--\nnote\n--\n",
        b"''''\n\n<<<\n\n* * *\n",
        b"// comment\n\n////\nblock\n////\n\ntext\n",
        b"= Doc\n\n= Part\n\n== Ch\n\n=== Sec\n\n==== Sub\n\n===== Deep\n\n====== Deeper\n",
        b"audio::a.mp3[opts=autoplay]\n\nvideo::v.mp4[p.png,640,480,start=5]\n",
        b":!gone:\n:also!:\n:k: v *b*\n",
        b"text with trailing spaces   \nnext line\n",
        b"* a\n** b\n*** c\n** d\n* e\n",
        b". a\n.. b\n. c\n",
        b"term1::\nterm2:: def\n",
        b"a;; b\nc;; d\n",
        b"Indented::\n  def text\n  more\n",
        b"* item\n\n  literal after blank\n",
        b"[[anchor,Ref Text]]\n.Title\npara\n",
        b"[#x]\n[.y]\n[%z]\npara\n",
        b"\"`unclosed\n'`also\n",
        b"kbd:[] btn:x[y] anchor:[] xref:[] link:[x] mailto:[x] image:[x]\n",
        b"http:// and https://a.org, then (https://b.org).\n",
        b"<https://a.org bad> <ftp://f.org>\n",
        b"x__y__z __a__ _b_c _d_\n",
        b"`a` ``b`` `c\n",
        b"a\\\nb\n",
        b"2. two\n3. three\n",
        b"a. x\nb. y\n\nA. X\n",
        b"I) one\nII) two\n",
        b"[upperroman]\n. a\n. b\n",
        b"* [*] star box\n* [X] cap box\n",
        b"|===\n|===\n",
        b"|===\n|unclosed\n",
        b"----\nunclosed listing\n",
        b"====\nunclosed example\n",
        b"> > nested md quote\n> plain\n",
        b"text\n> not a quote\n",
        b"[[a]]\n[[b]]\n== Heading\n\nbody\n",
        b"= Title [[top]]\n\nbody\n",
        b"[float]\n=== Floating\n",
        b"\t\tindented with tabs\n",
        b"x\r\ny\r\n",
        b"binary \x00 bytes \x01\x1f\n",
    ]);
    v.into_iter().enumerate().map(|(i, s)| (format!("extra-{}", i), s.to_vec())).collect()
}

fn all_inputs() -> Vec<(String, Vec<u8>)> {
    let mut v = corpus_inputs("asciidoc-tck-corpus.json");
    v.extend(corpus_inputs("asciidoc-twig-corpus.json"));
    v.extend(extra_inputs());
    v
}

fn show(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// `target` is the `-o` value, or `None` for the default (HTML render).
fn check(target: Option<&str>, port: impl Fn(&[u8]) -> Vec<u8>) {
    let Some(bin) = oracle() else { return };
    let mut args = vec!["convert", "-i", "asciidoc"];
    if let Some(t) = target {
        args.extend(["-o", t]);
    }
    args.push("-");
    let target = target.unwrap_or("html (render)");
    let mut failures = Vec::new();
    let mut compared = 0;
    for (id, src) in all_inputs() {
        let Some(want) = run_oracle(&bin, &args, &src) else {
            continue;
        };
        compared += 1;
        let got = port(&src);
        if got != want {
            failures.push(format!("[{}] {:?}\n--- oracle\n{}\n--- port\n{}", id, show(&src), show(&want), show(&got)));
        }
    }
    assert!(compared > 150, "too few inputs compared: {}", compared);
    if !failures.is_empty() {
        let n = failures.len();
        failures.truncate(5);
        panic!("{} of {} inputs differ on -o {}:\n{}", n, compared, target, failures.join("\n\n"));
    }
}

#[test]
fn table_matches_oracle() {
    check(Some("table"), |src| crate::ast::table::encode(&super::parse(src), Default::default()));
}

#[test]
fn canonical_matches_oracle() {
    check(Some("canonical"), |src| super::serialize(&super::parse(src)));
}

/// AsciiDoc renders through the generic, label-free HTML printer (the
/// registry's `renderHtmlGeneric`).
fn render_html(src: &[u8]) -> Vec<u8> {
    let doc = super::parse(src);
    let mut out = Vec::new();
    crate::languages::html::serialize(&doc.ast, &mut out, None).expect("render");
    out
}

#[test]
fn html_matches_oracle() {
    check(None, render_html);
}

#[test]
fn ast_matches_oracle() {
    check(Some("ast"), |src| crate::ast::json::encode(&super::parse(src)));
}

// ── cross-format: another language's tree -> `-o asciidoc` ──────────────────
//
// `serialize_ast` is the cross-format printer. These feed other formats'
// inputs through the oracle's `-i <fmt> -o asciidoc` and through the port's
// parser for that format plus `serialize_ast`. Only inputs whose `-o table`
// already agrees are compared, so a divergence in ANOTHER module's parser is
// not reported as this serializer's.

fn commonmark_inputs() -> Vec<Vec<u8>> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../src/languages/markdown/testdata/commonmark-spec-0.31.2.json");
    let Ok(text) = std::fs::read(&path) else { return Vec::new() };
    let Ok(v) = json::parse(&text) else { return Vec::new() };
    v.as_array()
        .unwrap_or(&[])
        .iter()
        .filter_map(|c| c.get("markdown").and_then(|m| m.as_str()).map(|m| m.to_vec()))
        .collect()
}

fn djot_inputs() -> Vec<Vec<u8>> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../src/languages/djot/testdata");
    let Ok(entries) = std::fs::read_dir(&dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> =
        entries.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "test")).collect();
    files.sort();
    let mut out = Vec::new();
    for f in files {
        let Ok(text) = std::fs::read(&f) else { continue };
        let mut lines = text.split(|&c| c == b'\n').peekable();
        while let Some(line) = lines.next() {
            if line.len() < 3 || !line.iter().all(|&c| c == b'`') {
                continue;
            }
            let mut input = Vec::new();
            for l in lines.by_ref() {
                if l == b"." {
                    break;
                }
                input.extend_from_slice(l);
                input.push(b'\n');
            }
            // Skip the expected output up to the closing fence.
            for l in lines.by_ref() {
                if l == line {
                    break;
                }
            }
            out.push(input);
        }
    }
    out
}

fn html_inputs() -> Vec<Vec<u8>> {
    [
        &b"<h1>T</h1><p>some <strong>bold</strong> <code>code</code> <a href=\"https://x.org\">link</a></p>"[..],
        b"<table title=\"Figures\"><tr><td>a</td></tr></table><table title=\"Lost\"><caption>Cap</caption><tr><td>b</td></tr></table>",
        b"<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul><ol start=\"3\"><li>x</li></ol>",
        b"<blockquote><p>q</p></blockquote><pre><code>x\n----\n</code></pre><hr>",
        b"<dl><dt>t</dt><dd>d</dd></dl><p>a<br>b <em>e</em> <mark>m</mark> <sup>s</sup> <sub>b</sub> <ins>i</ins> <del>d</del></p>",
        b"<div class=\"note\"><p>n</p></div><script>if (a < b) {}</script><textarea>a & b</textarea>",
        b"<!-- comment --><p>x<span id=\"y\">z</span><img src=\"i.png\" alt=\"A\" width=\"5\"></p>",
        b"<table><thead><tr><th>h</th><th align=\"right\">r</th></tr></thead><tbody><tr><td colspan=\"2\">w</td></tr></tbody></table>",
        b"<p><kbd>K</kbd> <b class=\"button\">OK</b> <a href=\"#frag\">F</a> <a href=\"mailto:a@b.org\">a@b.org</a></p>",
    ]
    .iter()
    .map(|s| s.to_vec())
    .collect()
}

fn check_cross(format: &str, inputs: Vec<Vec<u8>>, parse: impl Fn(&[u8]) -> crate::document::Document) {
    let Some(bin) = oracle() else { return };
    let mut failures = Vec::new();
    let mut compared = 0;
    let mut skipped = 0;
    for src in inputs {
        let Some(want_table) = run_oracle(&bin, &["convert", "-i", format, "-o", "table", "-"], &src) else { continue };
        let doc = parse(&src);
        if crate::ast::table::encode(&doc, Default::default()) != want_table {
            skipped += 1;
            continue;
        }
        let Some(want) = run_oracle(&bin, &["convert", "-i", format, "-o", "asciidoc", "-"], &src) else { continue };
        compared += 1;
        let got = super::serialize_ast(&doc.ast);
        if got != want {
            failures.push(format!("{:?}\n--- oracle\n{}\n--- port\n{}", show(&src), show(&want), show(&got)));
        }
    }
    eprintln!("asciidoc cross-format from {}: {} compared, {} skipped (source tree differs)", format, compared, skipped);
    if !failures.is_empty() {
        let n = failures.len();
        failures.truncate(5);
        panic!("{} of {} {} inputs differ on -o asciidoc:\n{}", n, compared, format, failures.join("\n\n"));
    }
}

#[test]
fn markdown_to_asciidoc_matches_oracle() {
    check_cross("markdown", commonmark_inputs(), |s| crate::languages::markdown::parse(s, Default::default()));
}

#[test]
fn djot_to_asciidoc_matches_oracle() {
    check_cross("djot", djot_inputs(), crate::languages::djot::parse);
}

#[test]
fn html_to_asciidoc_matches_oracle() {
    check_cross("html", html_inputs(), crate::languages::html::parse);
}
