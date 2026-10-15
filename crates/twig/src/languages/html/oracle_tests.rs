//! Differential tests against the Zig oracle (`zig-out/bin/twig`).
//!
//! - The HTML PARSER: every input of a corpus (hand-written edge cases, plus
//!   every HTML snippet the djot.js and CommonMark/GFM suites expect) is
//!   parsed by both sides and compared byte for byte as `-o table`, `-o ast`,
//!   HTML (`convert -i html`) and `-o canonical`.
//! - The RENDERER: documents parsed by the oracle (djot, CommonMark, GFM) are
//!   read back from their node table and printed by the Rust renderer with the
//!   matching preset, against the oracle's own HTML.
//!
//! Skipped (with a note on stderr) when the oracle binary is absent.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use super::serializer::{serialize_alloc, serialize_alloc_opts, RenderOptions};
use super::{COMMONMARK_RENDER_OPTIONS, GFM_RENDER_OPTIONS};
use crate::ast::table;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn oracle() -> Option<PathBuf> {
    let p = repo().join("zig-out/bin/twig");
    if p.exists() {
        Some(p)
    } else {
        eprintln!("oracle {} not found; skipping differential test", p.display());
        None
    }
}

/// Run the oracle with `args` over `input` on stdin; `None` when it fails.
fn run(bin: &PathBuf, args: &[&str], input: &[u8]) -> Option<Vec<u8>> {
    let mut child = Command::new(bin)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn oracle");
    let mut stdin = child.stdin.take().unwrap();
    let data = input.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&data);
    });
    let out = child.wait_with_output().expect("oracle output");
    writer.join().unwrap();
    if out.status.success() {
        Some(out.stdout)
    } else {
        None
    }
}

/// Run `check` over every case on a few threads; returns the failure reports.
fn par_check<T: Sync>(cases: &[T], check: impl Fn(&T) -> Option<String> + Sync) -> Vec<String> {
    let threads = 3;
    let chunk = cases.len().div_ceil(threads).max(1);
    std::thread::scope(|s| {
        let handles: Vec<_> =
            cases.chunks(chunk).map(|c| s.spawn(|| c.iter().filter_map(&check).collect::<Vec<_>>())).collect();
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect()
    })
}

fn report(what: &str, total: usize, failures: &[String]) {
    if failures.is_empty() {
        return;
    }
    let mut msg = format!("{what}: {} of {total} cases differ from the oracle\n", failures.len());
    for f in failures.iter().take(12) {
        msg.push_str(f);
        msg.push('\n');
    }
    panic!("{msg}");
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

fn diff(label: &str, input: &[u8], want: &[u8], got: &[u8]) -> String {
    format!("-- {label} --\ninput: {:?}\nwant: {}\ngot:  {}", lossy(input), lossy(want), lossy(got))
}

// ── corpora ─────────────────────────────────────────────────────────────────

/// Hand-written HTML exercising the parser's edge cases.
const HTML_CORPUS: &[&str] = &[
    "",
    "plain text",
    "<p>A paragraph with <em>emphasis</em> and <strong>strong</strong> text.</p>\n",
    "<h1>Heading</h1>\n<h2>Two</h2><h3>3</h3><h4>4</h4><h5>5</h5><h6>6</h6><h7>7</h7>",
    "<p id=\"intro\" class=\"note\">Text &amp; more.</p>\n",
    "<!DOCTYPE html>\n<html>\n<head><title>T &amp; t</title><meta charset=utf-8></head>\n<body>\n<p>x</p>\n</body>\n</html>\n",
    "<!doctype html><DIV class=x disabled>Hi &amp; &#x1f642;</DIV>",
    "<table><caption>C</caption><tr><th>a</th></tr><tr><td>1</td></tr></table>",
    "<table>\n<thead>\n<tr>\n<th>a</th>\n<th style=\"text-align: center;\">b</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>1</td>\n<td align=right>2</td>\n</tr>\n</tbody>\n<tfoot><tr><td>f</td></tr></tfoot>\n</table>\n",
    "<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td>b</td><td rowspan=\"0\">c</td><td colspan=\"nope\">d</td><td colspan=\" 4 \">e</td><td colspan=+2>f</td></tr></table>",
    "<table><tr><td>a<td>b<tr><td>c</table>",
    "<table><td style=\"text-align:left\">x</td><td style=\"color: red; text-align : RIGHT\">y</td></table>",
    "<ul><li>one<li>two</ul><p>a<div>b</div><script>a < b &amp;</script>",
    "<ul>\n<li>\none\n</li>\n<li>\ntwo\n</li>\n</ul>\n",
    "<ul>\n<li>\n<p>one\ntwo</p>\n</li>\n</ul>\n",
    "<ul><li>text<blockquote>quoted</blockquote></li></ul>",
    "<ul><li><p>a</p></li><li>b</li></ul>",
    "<ul><li></li><li/></ul><ul></ul>",
    "<ol start=\"3\"><li>x</ol><ol start=\"iii\"><li>y</ol><ol start=-0><li>z</ol><ol start=1_0 class=l><li>w</ol>",
    "<ol><li><pre>x</pre></li></ol>",
    "<dl><dt>term<dd>def<dt>t2</dl>",
    "<select><option>a<option>b<optgroup><option>c</select>",
    "<ruby>漢<rt>kan<rp>(</rp>字<rt>ji</ruby>",
    "<a href=\"/x\" class=\"c\">hi</a><a name=\"top\">hi</a><a href>bare</a><a href=/u/v>slash</a>",
    "<img src=\"/p.png\" alt=\"pic\" class=\"t\"><img src=x><img alt=only><img src='a' alt='b'/>",
    "<p>line<br>break<br/>again<br />x</p><hr><hr/>",
    "<input type=checkbox disabled checked><input value='a\"b' x=\"a'b\">",
    "<div a=1 b='2' c=\"3\" d e = 5 f=\"&lt;&amp;&gt;\" g=&quot;q>t</div>",
    "<div A=1 A=2 class=\"x y\">dup</div>",
    "<script>if (a < b && c) x();</script><style>.a>.b{x:1}</style>",
    "<script type=\"text/javascript\">\n  var s = '</scr' + 'ipt>';\n</script>",
    "<SCRIPT>x</SCRIPT><Style>y</sTyle >",
    "<textarea><b>x</b> &amp; &lt;</textarea><title>a &amp; b</title>",
    "<xmp><b>raw</b></xmp><iframe>i</iframe><noembed>n</noembed><noframes>f</noframes>",
    "<plaintext><p>everything</p></plaintext>after",
    "<script>unterminated",
    "<title>unterminated &amp;",
    "<!-- a comment --><!----><!-- <p>inner</p> -->",
    "<!-- unterminated comment",
    "<!bogus declaration><![CDATA[x<y]]>",
    "<?xml version=\"1.0\"?><?pi?><?target   data here ?>",
    "<?unterminated",
    "&amp; &lt; &gt; &quot; &apos; &nbsp; &copy; &reg; &hellip; &ndash; &mdash; &lsquo; &rsquo; &ldquo; &rdquo;",
    "&#65; &#x41; &#X41; &#0; &#xD800; &#x110000; &#1114111; &#+65; &#-0; &#1_0; &#_1; &#; &#x; &unknown; & alone",
    "a & b; c &amp d; &amp;",
    "text &",
    "<p>a < b > c</p>",
    "< p>not a tag</p>",
    "<3 hearts",
    "a <",
    "<",
    "</",
    "</>",
    "</p>",
    "stray </div> close",
    "<p>unclosed <em>emph <strong>strong</p>after",
    "<em>a<strong>b</em>c</strong>d",
    "<p>one<p>two<h1>three</h1><p>four<ul><li>five</ul>",
    "<div>\n\n  <p>  spaced  </p>\n\n  text\n\n</div>",
    "<div>hello <em>there</em> world</div>",
    "<blockquote>\n<p>q</p>\n</blockquote>\n",
    "<blockquote>  lead and trail  </blockquote>",
    "<section><main><body>s</body></main></section>",
    "<pre><code class=\"language-zig\">const x = 1;\n</code></pre>",
    "<pre><code class=\"a language-rust b\">fn x() {}</code></pre><pre><code>plain</code></pre><pre><code class=\"language-\">e</code></pre>",
    "<pre>\n<code>two children</code></pre><pre>just text</pre>",
    "<code>a &lt; b</code><code><em>x</em></code><code></code>",
    "<p><code class=k>v</code></p>",
    "<span>s</span><span class=c>t</span><mark>m</mark><ins>i</ins><u>u</u><del>d</del><s>s</s><sup>p</sup><sub>b</sub><i>i</i><b>b</b>",
    "<svg width=\"10\" height=\"10\"><rect x=\"0\" y=\"0\"/><circle r=5></circle></svg>",
    "<math><mi>x</mi><mo>=</mo><mn>1</mn></math>",
    "<video controls><source src=a.mp4><track kind=captions></video>",
    "<custom-element data-x=\"1\">c</custom-element><my:tag>n</my:tag>",
    "<p>\x0c</p><div>\x0c</div>",
    "<div>\x0ctext\x0c</div>",
    "<div>&#32;x&#32;</div>",
    "<br/ x><br / >",
    "<p\n class='multi\nline'\n>x</p\n>",
    "<p class=a/b>x</p>",
    "<p =x>y</p><p \"q\"=1>z</p>",
    "\u{feff}<p>bom</p>",
    "<p>caf\u{e9} \u{1F642}</p>",
    "<table><tr><th>a</th><td>b</td></tr><tr><th>c</th></tr><tr></tr></table>",
    "<table>\n  <tbody>\n    <tr>\n      <td> a </td>\n    </tr>\n  </tbody>\n</table>",
    "<table><thead><tr><th>h</th></tr><tbody><tr><td>b</td></tr></table>",
    "<li>orphan item<li>another",
    "<dd>orphan</dd>",
    "<td>orphan cell</td>",
    "<div><p>x</div>y",
    "<h1>a<h2>b</h2></h1>",
    "<ul>\n  <li>a\n  <li>b\n</ul>",
    "<ul><li>a</li>\n\n<li>b</li></ul>",
    "<p>x</p>\n\n\n<p>y</p>\n\n",
    "   leading and trailing   ",
];

fn read_testdata(rel: &str) -> Vec<u8> {
    std::fs::read(repo().join("src/languages").join(rel)).unwrap_or_else(|e| panic!("read {rel}: {e}"))
}

use super::conformance::{parse_tests, DJOT_TESTFILES};

/// Every `html` field of a CommonMark-format spec JSON.
fn spec_cases(rel: &str) -> Vec<(Vec<u8>, Vec<u8>)> {
    let v = crate::json::parse(&read_testdata(rel)).expect("spec json");
    v.as_array()
        .unwrap()
        .iter()
        .map(|c| (c.get("markdown").unwrap().as_str().unwrap().to_vec(), c.get("html").unwrap().as_str().unwrap().to_vec()))
        .collect()
}

fn html_inputs() -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = HTML_CORPUS.iter().map(|s| s.as_bytes().to_vec()).collect();
    for name in DJOT_TESTFILES {
        let content = read_testdata(&format!("djot/testdata/{name}"));
        for c in parse_tests(&content) {
            out.push(c.expected);
        }
    }
    for rel in ["markdown/testdata/commonmark-spec-0.31.2.json", "markdown/testdata/gfm-spec-0.29-extensions.json"] {
        for (_, html) in spec_cases(rel) {
            out.push(html);
        }
    }
    out.sort();
    out.dedup();
    out
}

// ── the HTML parser ─────────────────────────────────────────────────────────

#[test]
fn html_parser_matches_the_oracle() {
    let Some(bin) = oracle() else { return };
    let inputs = html_inputs();
    assert!(inputs.len() > 800, "corpus too small: {}", inputs.len());
    let compared = std::sync::atomic::AtomicUsize::new(0);
    let failures = par_check(&inputs, |input| {
        let doc = super::parse(input);
        let mut problems = Vec::new();
        let rust_html = serialize_alloc(&doc.ast, None).expect("html parse never yields metadata");
        let checks: [(&str, &[&str], Vec<u8>); 4] = [
            ("table", &["convert", "-i", "html", "-o", "table", "-"], table::encode(&doc, Default::default())),
            ("ast", &["convert", "-i", "html", "-o", "ast", "-"], crate::ast::json::encode(&doc)),
            ("html", &["convert", "-i", "html", "-"], rust_html.clone()),
            ("canonical", &["convert", "-i", "html", "-o", "canonical", "-"], rust_html),
        ];
        for (label, args, got) in checks {
            match run(&bin, args, input) {
                Some(want) if want == got => {
                    compared.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Some(want) => problems.push(diff(label, input, &want, &got)),
                None => problems.push(format!("-- {label} --\ninput: {:?}\noracle failed", lossy(input))),
            }
        }
        if problems.is_empty() {
            None
        } else {
            Some(problems.join("\n"))
        }
    });
    report("html parser", inputs.len(), &failures);
    eprintln!("html parser: {} inputs, {} outputs byte-identical", inputs.len(), compared.into_inner());
}

// ── the renderer, over documents the oracle parsed ──────────────────────────

fn render_check(bin: &PathBuf, format: &str, input: &[u8], options: RenderOptions, want_html: Option<&[u8]>) -> Option<String> {
    let Some(tab) = run(bin, &["convert", "-i", format, "-o", "table", "-"], input) else {
        return Some(format!("-- {format} -- oracle table failed for {:?}", lossy(input)));
    };
    let doc = match table::decode(input, &tab) {
        Ok(d) => d,
        // Zig's decoder refuses these too (see the extensions test); skip.
        Err(_) => return None,
    };
    let oracle_html;
    let want: &[u8] = match want_html {
        Some(w) => w,
        None => match run(bin, &["convert", "-i", format, "-"], input) {
            Some(h) => {
                oracle_html = h;
                &oracle_html
            }
            None => b"<oracle refused>",
        },
    };
    let got = match serialize_alloc_opts(&doc.ast, Some(&doc.labels), options) {
        Ok(g) => g,
        Err(_) => b"<oracle refused>".to_vec(),
    };
    if got == want {
        None
    } else {
        Some(diff(format, input, want, &got))
    }
}

#[test]
fn renderer_matches_oracle_for_commonmark_and_gfm() {
    let Some(bin) = oracle() else { return };
    let cm = spec_cases("markdown/testdata/commonmark-spec-0.31.2.json");
    let failures = par_check(&cm, |(md, _)| render_check(&bin, "commonmark", md, COMMONMARK_RENDER_OPTIONS, None));
    report("commonmark render", cm.len(), &failures);

    let mut gfm = spec_cases("markdown/testdata/gfm-spec-0.29-extensions.json");
    gfm.extend(cm);
    let failures = par_check(&gfm, |(md, _)| render_check(&bin, "gfm", md, GFM_RENDER_OPTIONS, None));
    report("gfm render", gfm.len(), &failures);
}

#[test]
fn renderer_matches_oracle_for_markdown_extensions() {
    let Some(bin) = oracle() else { return };
    // `markdown` (twig's own flavour) with every extension flag the CLI has.
    let inputs: &[&str] = &[
        "| a | b |\n| :-: | --: |\n| 1 | 2 |\n",
        "- [ ] todo\n- [x] done\n",
        "a ==b== c\n",
        "a ==\u{1F534} b== c\n",
        "text[^a] more\n\n[^a]: the note\n",
        "one[^b] two[^a]\n\n[^a]: A\n[^b]: B\n",
        "$x$ and $$y$$\n",
        "---\ntitle: x\n---\n\nbody\n",
        "+++\na = 1\n+++\n\nbody\n",
        "---\nevil: </script>\n---\n\nbody\n",
        ":::note{#i .c k=v}\nbody\n:::\n\n::leaf[label]{a=b}\n\nand :inline[t]{x=y}\n",
        "<div class=\"verse\">\n\nOne line\nsoft\\\nhard\n\n\u{2003}indented\n\n</div>\n",
        "~~del~~ ^sup^ ~sub~\n",
        "![img *alt*](/p.png \"title\") [link](</a b> 'T')\n",
        "<https://x.y/a b> <me@x.y>\n",
        "    code\n\n```zig\nconst x = 1;\n```\n",
        "Term\n: Definition\n",
    ];
    let flags: &[&str] = &["--directives", "--math", "--highlight", "--highlight-colors"];
    let mut extra: Vec<&str> = Vec::new();
    for f in flags {
        extra.push(f);
    }
    extra.push("--feature");
    extra.push("html_elements");
    let failures = par_check(inputs, |input| {
        let input = input.as_bytes();
        let mut targs: Vec<&str> = vec!["convert", "-i", "markdown", "-o", "table"];
        targs.extend(&extra);
        targs.push("-");
        let Some(tab) = run(&bin, &targs, input) else { return Some(format!("oracle table failed: {:?}", lossy(input))) };
        let doc = match table::decode(input, &tab) {
            Ok(d) => d,
            Err(p) => return Some(format!("table refused ({p}): {:?}", lossy(input))),
        };
        let mut hargs: Vec<&str> = vec!["convert", "-i", "markdown"];
        hargs.extend(&extra);
        hargs.push("-");
        let want = run(&bin, &hargs, input);
        let got = serialize_alloc_opts(&doc.ast, Some(&doc.labels), COMMONMARK_RENDER_OPTIONS).ok();
        if want == got {
            None
        } else {
            Some(diff("markdown+ext", input, &want.unwrap_or_default(), &got.unwrap_or_default()))
        }
    });
    report("markdown extensions render", inputs.len(), &failures);
}

// ── randomized ──────────────────────────────────────────────────────────────

/// Documents stitched together from HTML-ish fragments by a fixed-seed PRNG:
/// malformed nesting, stray closers, odd attributes and references.
fn random_inputs(n: usize) -> Vec<Vec<u8>> {
    const FRAGS: &[&str] = &[
        "<p>", "</p>", "<div>", "</div>", "<ul>", "</ul>", "<ol start=2>", "</ol>", "<li>", "</li>", "<table>",
        "</table>", "<tr>", "</tr>", "<td>", "<th align=center>", "</td>", "<thead>", "<tbody>", "</tbody>",
        "<em>", "</em>", "<b>", "</b>", "<a href='/x'>", "<a>", "</a>", "<img src=i alt=a>", "<br>", "<hr/>",
        "<pre>", "</pre>", "<code>", "</code>", "<script>", "</script>", "<title>", "</title>", "<textarea>",
        "<!-- c -->", "<!x>", "<?p d?>", "<!DOCTYPE html>", "<span class=\"a b\">", "</span>", "<dl><dt>",
        "<dd>", "<blockquote>", "</blockquote>", "<h2>", "</h2>", "<section>", "<svg><g/></svg>", "<x-y z>",
        "text", " ", "\n", "\n\n", "  ", "&amp;", "&lt;", "&#65;", "&#x1F642;", "&bogus;", "&", ";", "<", ">",
        "/", "\"", "'", "=", "<td colspan=2>", "<p id=x disabled>", "<input checked>", "</", "<3", "\u{e9}",
        "<caption>", "<tfoot>", "<option>", "<rt>", "<i>", "<u>", "<sup>", "<s>",
    ];
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    (0..n)
        .map(|_| {
            let len = (next() % 24) as usize;
            let mut doc = Vec::new();
            for _ in 0..len {
                doc.extend_from_slice(FRAGS[(next() % FRAGS.len() as u64) as usize].as_bytes());
            }
            doc
        })
        .collect()
}

#[test]
fn html_parser_matches_the_oracle_on_random_documents() {
    let Some(bin) = oracle() else { return };
    let inputs = random_inputs(1500);
    let failures = par_check(&inputs, |input| {
        let doc = super::parse(input);
        let got_table = table::encode(&doc, Default::default());
        let got_html = serialize_alloc(&doc.ast, None).unwrap();
        let want_table = run(&bin, &["convert", "-i", "html", "-o", "table", "-"], input);
        if want_table.as_deref() != Some(&got_table[..]) {
            return Some(diff("table", input, &want_table.unwrap_or_default(), &got_table));
        }
        let want_html = run(&bin, &["convert", "-i", "html", "-"], input);
        if want_html.as_deref() != Some(&got_html[..]) {
            return Some(diff("html", input, &want_html.unwrap_or_default(), &got_html));
        }
        None
    });
    report("html parser (random)", inputs.len(), &failures);
}
