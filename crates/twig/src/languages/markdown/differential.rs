//! Differential tests against the Zig oracle (`zig-out/bin/twig`): every
//! `markdown` input of the CommonMark 0.31.2 spec and of the GFM extension
//! spec, the edge cases below, and a deterministic pseudo-random corpus are
//! parsed by both implementations under every dialect (default `markdown`,
//! `commonmark`, `gfm`) and with every opt-in extension on, and the node
//! tables (`-o table`) and AST JSON (`-o ast`) must be byte-identical.
//! Skipped (with a note) when the oracle binary is absent.

use std::io::Write;
use std::process::{Command, Stdio};

use crate::ast::{json, table};

use super::{parse, Extensions, ParseOptions};

fn oracle_path() -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/twig");
    p.exists().then_some(p)
}

fn oracle(args: &[&str], src: &[u8]) -> Vec<u8> {
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
    assert!(out.status.success(), "oracle failed: {}", String::from_utf8_lossy(&out.stderr));
    out.stdout
}

const ALL_EXT: Extensions =
    Extensions { directives: true, math: true, html_elements: true, highlight: true, highlight_colors: true };
const EXT_FLAGS: &[&str] =
    &["--math", "--directives", "--highlight", "--highlight-colors", "--feature", "html_elements"];

#[derive(Clone, Copy)]
struct Config {
    name: &'static str,
    input: &'static str,
    extended: bool,
}

impl Config {
    fn options(self) -> ParseOptions {
        let base = match self.input {
            "commonmark" => ParseOptions::COMMONMARK,
            "gfm" => ParseOptions::GFM,
            _ => ParseOptions::default(),
        };
        if self.extended { base.with_extensions(ALL_EXT) } else { base }
    }

    fn args(self, out: &'static str) -> Vec<&'static str> {
        let mut a = vec!["convert", "-i", self.input, "-o", out];
        if self.extended {
            a.extend_from_slice(EXT_FLAGS);
        }
        a
    }
}

const CONFIGS: [Config; 6] = [
    Config { name: "markdown", input: "markdown", extended: false },
    Config { name: "commonmark", input: "commonmark", extended: false },
    Config { name: "gfm", input: "gfm", extended: false },
    Config { name: "markdown+ext", input: "markdown", extended: true },
    Config { name: "commonmark+ext", input: "commonmark", extended: true },
    Config { name: "gfm+ext", input: "gfm", extended: true },
];

/// Compare every `(input, config)` pair, both outputs, on a few threads.
/// Returns the number of comparisons made; panics listing every mismatch.
fn run_corpus(label: &str, inputs: &[Vec<u8>], configs: &[Config], ast_too: bool) -> usize {
    let jobs: Vec<(usize, Config)> =
        (0..inputs.len()).flat_map(|i| configs.iter().map(move |&c| (i, c))).collect();
    let workers = 4;
    let failures: Vec<String> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..workers)
            .map(|w| {
                let jobs = &jobs;
                scope.spawn(move || {
                    let mut fails = Vec::new();
                    for (i, c) in jobs.iter().skip(w).step_by(workers) {
                        let src = &inputs[*i];
                        let doc = parse(src, c.options());
                        let mine = table::encode(&doc, Default::default());
                        if oracle(&c.args("table"), src) != mine {
                            fails.push(format!("{label}#{i} [{}] table: {:?}", c.name, String::from_utf8_lossy(src)));
                            continue;
                        }
                        if ast_too && oracle(&c.args("ast"), src) != json::encode(&doc) {
                            fails.push(format!("{label}#{i} [{}] ast: {:?}", c.name, String::from_utf8_lossy(src)));
                        }
                    }
                    fails
                })
            })
            .collect();
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect()
    });
    assert!(failures.is_empty(), "{} divergences:\n{}", failures.len(), failures.join("\n"));
    jobs.len()
}

fn spec_inputs(file: &str) -> Vec<Vec<u8>> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../src/languages/markdown/testdata").join(file);
    let text = std::fs::read(path).unwrap();
    let value = crate::json::parse(&text).unwrap();
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|ex| ex.get("markdown").and_then(|m| m.as_str()).unwrap().to_vec())
        .collect()
}

#[test]
fn commonmark_spec_matches_oracle() {
    if oracle_path().is_none() {
        eprintln!("note: zig-out/bin/twig not built; skipping the Markdown differential");
        return;
    }
    let inputs = spec_inputs("commonmark-spec-0.31.2.json");
    assert_eq!(inputs.len(), 652);
    run_corpus("commonmark-spec", &inputs, &CONFIGS, true);
}

#[test]
fn gfm_spec_matches_oracle() {
    if oracle_path().is_none() {
        return;
    }
    let inputs = spec_inputs("gfm-spec-0.29-extensions.json");
    assert!(!inputs.is_empty());
    run_corpus("gfm-spec", &inputs, &CONFIGS, true);
}

#[test]
fn edge_cases_match_oracle() {
    if oracle_path().is_none() {
        return;
    }
    let inputs: Vec<Vec<u8>> = EDGE_CASES.iter().map(|s| s.to_vec()).collect();
    run_corpus("edge", &inputs, &CONFIGS, true);
}

#[test]
fn generated_corpus_matches_oracle() {
    if oracle_path().is_none() {
        return;
    }
    let mut rng = Lcg(0x5eed_1234_abcd);
    let mut inputs = Vec::new();
    for _ in 0..150 {
        inputs.push(gen_inline_soup(&mut rng));
    }
    for _ in 0..150 {
        inputs.push(gen_block_soup(&mut rng));
    }
    for _ in 0..60 {
        inputs.push(gen_byte_soup(&mut rng));
    }
    let configs = [CONFIGS[0], CONFIGS[1], CONFIGS[2], CONFIGS[3]];
    run_corpus("generated", &inputs, &configs, false);
}

/// A tiny deterministic generator (no dependencies).
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len())]
    }
}

const INLINE_FRAGS: &[&str] = &[
    "*", "**", "_", "__", "~", "~~", "==", "===", "=", "`", "``", "$", "$$", "[", "]", "(", ")", "![", "<", ">", "&amp;",
    "&#35;", "&nope;", "\\", "\\|", "|", " | ", "---", "- ", "* ", "1. ", "> ", "#", "## ", "    ", "\t", "\n", "\n\n",
    "\r\n", ":", ": ", "::", "::: note", ":::", ":abbr[x]{title=\"t\"}", ":kbd[", "{#id .c k=v}", "{", "}", "[^1]",
    "[^1]: ", "[ ]", "[x] ", "www.example.com", "https://a.b/c?d", "a@b.co", "<a@b.co>", "<http://x.y>",
    "<span class=\"x\">", "</span>", "<u>", "</u>", "<div class=\"verse\">", "<div>", "</div>", "<img src=\"i.png\" alt=\"a\">",
    "<br>", "<!-- c -->", "word", "foo bar", "Ünïcödé", "ß", "𝔸", "🔴", "🔵 ", "\u{a0}", "…", "\"", "'", "!", ".", "---yaml",
    "+++", "```", "~~~", "```js", "[ref]", "[ref]: /url \"T\"", "[foo][ref]", "[a](b \"c\")", "| a | b |\n|---|:-:|\n",
    "Term\n: def", "$x$", "$$y$$", "==🔴 hi==", "~~del~~", "**strong**", "_em_", "&copy;", "&#x1F600;",
];

fn gen_inline_soup(rng: &mut Lcg) -> Vec<u8> {
    let mut out = String::new();
    for _ in 0..1 + rng.below(40) {
        out.push_str(rng.pick(INLINE_FRAGS));
        out.push_str(rng.pick(&["", " ", "\n"]));
    }
    out.into_bytes()
}

const PREFIXES: &[&str] = &[
    "", "", "> ", ">", "- ", "* ", "+ ", "1. ", "3) ", "  ", "   ", "    ", "\t", " \t", "[^n]: ", ": ", "- [ ] ", "- [x] ",
    ">\t", "-\t", "10. ",
];
const BODIES: &[&str] = &[
    "text", "*em* and **st**", "`code`", "```", "~~~ py", ":::", "::: tip", "::leaf[x]", "| a | b |", "|---|---|",
    "| 1 | 2 |", "---", "***", "===", "# h", "## h ##", "<div>", "</div>", "<div class=\"verse\">", "<pre>", "</pre>",
    "<!--", "-->", "[r]: /u", "[r]", "Term", "$$", "$a$", "==m==", "", "", "  ", "www.x.com.", "a@b.cd",
    "<span>s</span>", "[^n]", "x\\", "x  ",
];

fn gen_block_soup(rng: &mut Lcg) -> Vec<u8> {
    let mut lines = Vec::new();
    for _ in 0..1 + rng.below(25) {
        let mut l = String::new();
        for _ in 0..*rng.pick(&[0usize, 1, 1, 2, 3]) {
            l.push_str(rng.pick(PREFIXES));
        }
        l.push_str(rng.pick(BODIES));
        lines.push(l);
    }
    let mut s = lines.join("\n");
    if rng.below(5) == 0 {
        s = format!("---\ntitle: x\n---\n{s}");
    }
    if rng.below(5) == 0 {
        s.push_str("\n\n---toml\na = 1\n---\n");
    }
    if rng.below(5) != 0 {
        s.push('\n');
    }
    s.into_bytes()
}

const BYTES: &[&[u8]] = &[
    b"*", b"_", b"a", b" ", b"\n", b"\r", b"\x00", b"\x80", b"\xc3", b"\xa9", b"\xe2\x80", b"\x9c",
    b"\xf0\x9f\x94\xb4", b"\xff", b"[", b"]", b"(", b")", b"&", b";", b"#", b"=", b"~", b"\xc2\xa0", b"`", b"<", b">",
    b"\\", b"\xce\xa3", b"\xd0\x96", b"\xe1\xba\x9e", b":", b"|", b"-", b"\t", b"$", b"@", b".", b"w", b"x",
];

fn gen_byte_soup(rng: &mut Lcg) -> Vec<u8> {
    let mut out = Vec::new();
    for _ in 0..1 + rng.below(60) {
        out.extend_from_slice(rng.pick(BYTES));
    }
    out
}

/// Hand-written cases for every construct and extension.
pub const EDGE_CASES: &[&[u8]] = &[
    b"",
    b"\n",
    b"\n\n\n",
    b"no final newline",
    b"# Heading without a final newline",
    b"line one\r\nline two\r\n\r\n- crlf item\r\n",
    b"\tindented with a tab\n",
    b"-\tfoo\n\n\t\tbar\n",
    b">\t\tfoo\n",
    b"  - a\n   - b\n    - c\n",
    b"1. one\n2. two\n\n   para\n3. three\n",
    b"1) a\n2) b\n3. c\n",
    b"- a\n\n- b\n\n\n- c\n",
    b"- a\n  - b\n\n    c\n- d\n",
    b"* star\n+ plus\n- dash\n",
    b"> # quoted heading\n> para\n> - list\n>\n> ```\n> code\n> ```\n",
    b"> a\n>\n> \n",
    b"> > a\n> >\n> > \n",
    b"Setext\n===\n\nAnother\n---\n",
    b"[foo]: /url \"title\"\n\n[foo] and [Foo][] and [bar][foo]\n",
    b"[\xe1\xba\x9e]: /sharp\n\n[SS] [ss] [\xc3\x9f]\n",
    b"[\xce\xa3]: /sigma\n\n[\xcf\x83]\n",
    b"[d]: /d\n  \"dee\"\ntext\n",
    b"[a]: <b c> 'tit\\'le'\n[a]\n",
    b"```f&ouml;&ouml; bar\ncode\n```\n",
    b"~~~~\n```\n~~~\n~~~~\n",
    b"    code\n\n\n    more\n\n\n",
    b"<script>\nalert(1)\n</script>\nafter\n",
    b"<!-- comment\nstill -->\n",
    b"<?php echo 1; ?>\n",
    b"<!DOCTYPE html>\n",
    b"<![CDATA[\nx\n]]>\n",
    b"<del>*foo*</del>\n",
    b"<custom-tag attr=\"v\">\n",
    b"| a | b |\n|---|:-:|\n| 1 | 2 |\n| `a|b` | \\| | x |\n",
    b"| a |\n| - |\n| b |\n> quote ends it\n",
    b"| a | b |\n| --- | ---: |\n| 1 |\n| 1 | 2 | 3 |\n",
    b"- | a | b |\n  |---|---|\n  | 1 | 2 |\n",
    b"> | a |\n> |---|\n> | 1 |\n",
    b"|not a table\n|---|---|\n",
    b"| cell<br>two | x |\n|---|---|\n| a<br/>b | <br class=\"x\"> |\n",
    b"- [ ] todo\n- [x] done\n- [X] caps\n-  [ ] wide\n- [ ]\n",
    b"1. [ ] ordered never tasks\n",
    b"- [x] task\n- plain\n",
    b"Term\n: def one\n: def two\n\nTerm 2\n: def three\n  lazy\n",
    b"Term\n:\n",
    b"> Term\n> : def in quote\n",
    b"text[^1] and[^Two].\n\n[^1]: First note.\n\n[^two]: Second note\n    with more.\n\n    And a para.\n",
    b"[^a]: one\n[^b]: two\n[^a]: dup\n",
    b"ref[^missing]\n",
    b"para\n[^a]: not a def\n",
    b"---\ntitle: Hi\n---\n# Body\n",
    b"+++\na = 1\n+++\nbody\n",
    b"---fig\ntitle = Twig\n---\n\n# Body\n\n---toml\nisbn = \"x\"\n---\n",
    b"----\nfoo\n",
    b"---\nunterminated\n",
    b"text\n\n---\nk = v\n---\n",
    b"text\n---toml\nk = v\n---\n",
    b"$x^2$ and $$\\int_0^1$$ and $5 and $ x$ and \\$y$\n",
    b"$$\nblock\n$$\n",
    b"costs $5 and $10\n",
    b"==mark== and ===not=== and =single=\n",
    b"==\xf0\x9f\x94\xb4 red== ==\xf0\x9f\x9f\xa2green== ==\xf0\x9f\x8d\x8e apple== ==a==\xf0\x9f\x94\xb4 b==\n",
    b"*a ==\xf0\x9f\x94\xb5 b== c* ~~==x==~~\n",
    b":::note{#n .box key=\"v\"}\nHello *world*\n:::\n",
    b"::::outer\n:::inner\nhi\n:::\n::::\n",
    b"::youtube[A *caption*]{#v}\n::hr\n::bad name\n",
    b":::box[label [nested](/x)]{.k}\nhi\n:::\n",
    b"text\n:::box\nin\n:::\n",
    b":::box\nunterminated\n",
    b"> :::box\n> hi\n> :::\n",
    b"- :::box\n  in list\n  :::\n",
    b"See :abbr[HTML]{title=\"HyperText\"} and :kbd[Ctrl] and :bare and 10:30.\n",
    b":vis[a :vis[b]{.x} c]{.y}\n",
    b":vis[a [b c]{.y}\n",
    b":::div{.verse}\nRoses are red,\nviolets blue.\n\nSecond stanza.\n:::\n",
    b"<div class=\"verse\">\n\nRoses are red,\nviolets blue.\n\n</div>\n",
    b"<div class=\"center\" data-k=\"v\">\n\nhello *there*\n\n- one\n\n</div>\n\nafter\n",
    b"<div class=\"a\">\n\n<div class=\"b\">\n\nx\n\n</div>\n\ny\n\n</div>\n",
    b"> <div class=\"c\">\n>\n> hello\n>\n> </div>\n",
    b"<div>\n\nhello\n\n</div>\ntail\n",
    b"<div/>\n\nhello\n\n</div>\n",
    b"<img src=\"a.svg\" alt=\"x\">\n",
    b"see <img src=\"a.svg\" alt=\"x\"> and <br> here\n",
    b"<video src=\"clip.mp4\" poster=\"p.png\" controls></video>\n",
    b"<picture><source srcset=\"d.svg\"><img src=\"l.svg\" alt=\"b\"></picture>\n",
    b"<h1 align=\"center\">\n  <picture>\n    <source media=\"(x)\" srcset=\"d.svg\">\n    <img src=\"l.svg\" width=\"220\" alt=\"fig\">\n  </picture>\n</h1>\n",
    b"a <span class=\"l\" data-k=\"v\">big *text*</span> b <U>under</u> <u class=x>no</u>\n",
    b"<span class=\"a\">x <span class=\"b\">y</span> z</span>\n",
    b"visit www.example.com, https://x.dev/a_(b)) and foo@bar.example.com.\n",
    b"[a https://x.dev](d) [a b@c.de](d) [a b@c.de] ![a b@c.de](i) [a <b@c.de>](d)\n",
    b"www.example.com/a]b and xhttp://no.dev and a.b-c_d@a.b- and a.b-c_d@a.b.\n",
    b"www.google.com/search?q=commonmark&hl;\n",
    b"*a **b***\n",
    b"~~a *b~~ c*\n",
    b"***strong emph*** **_mixed_**\n",
    b"foo  \nbar\\\nbaz\n",
    b"`` `foo` `` and ``` `` ```\n",
    b"&amp; &#65; &#x41; &#0; &#xD800; &#87654321; &nosuch; &ngE;\n",
    b"\\*not\\* \\a \\\n",
    b"\xff\xfe invalid \x80 utf8 *\xc3*\n",
];
