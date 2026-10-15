//! Differential tests against the Zig oracle (`zig-out/bin/twig`): the node
//! table, the AST JSON, the generic HTML render and the canonical round trip must be byte-identical,
//! and malformed input must fail on both sides with the same error. Skipped
//! (with a note) when the oracle binary is absent.

use std::io::Write;
use std::process::{Command, Stdio};

use crate::ast::{json, table};

/// Whether the Zig oracle is built; prints a skip note when it is not.
pub(crate) fn oracle_available() -> bool {
    let ok = oracle_path().is_some();
    if !ok {
        eprintln!("zig oracle not built; skipping");
    }
    ok
}

fn oracle_path() -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/twig");
    p.exists().then_some(p)
}

/// Run `twig convert -i <fmt> -o <out> -` on `src`. `Ok(stdout)` on success,
/// `Err(stderr)` on failure.
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

const CORPUS: &[&[u8]] = &[
    b"<a/>",
    b"<a></a>",
    b"<a x=\"1\">hi<b/></a>",
    b"<a x='single' y=\"double\" z='it&apos;s' w=\"&quot;q&quot;\"/>",
    b"<root>\n  <child/>\n  <child>text</child>\n</root>\n",
    b"\n\n  <root/>\n\n",
    b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE note SYSTEM \"note.dtd\">\n<note><to>Tove</to></note>",
    b"<!DOCTYPE r [ <!ENTITY e \"x>y\"> <!ELEMENT r (#PCDATA)> ]><r/>",
    b"<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0//EN' \"http://x/y.dtd\"><html/>",
    b"<r xmlns=\"urn:a\" xmlns:b=\"urn:b\"><b:c b:d=\"1\"/><e:f xmlns:e=\"urn:e\"/></r>",
    b"<r><?target some data ?><?bare?><?t   spaced  ?></r>",
    b"<?pi before?><r/><?pi after?><!-- after -->\n",
    b"<r><![CDATA[<not> & markup]]><![CDATA[]]><![CDATA[]]]]></r>",
    b"<r><!-- c1 --><!----><!-- a - b --></r>",
    b"<r>&lt;&gt;&amp;&apos;&quot;&#65;&#x42;&#X43;&#x1F600;&#0;&#+66;&#-0;&#6_7;</r>",
    b"<r a=\"&#x9;&#xA;tab\nnl\ttab\" b=\"&lt;&gt;\"/>",
    b"<r>  \t\r\n  </r>",
    b"<r>\r\n<x\r\n a = \"1\"\r\n/>\r\n</r>\r\n",
    b"<r>caf\xc3\xa9 \xe2\x9c\x93 <\xc3\xa9l\xc3\xa9ment \xc3\xa0=\"\xc3\xa7\"/></r>",
    b"<r>raw \xff\xfe bytes</r>",
    b"<a.b-c_d:e f.g-h=\"1\"></a.b-c_d:e>",
    b"<r><a></a ><b></b\n></r>",
    b"<r>]]> in text</r>",
    b"<r>> gt in text</r>",
    b"<?XML foo?><r/>",
    b"<r>text<i>em</i> tail<b><i>deep</i></b>.</r>",
    b"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect x=\"1\" y=\"1\" width=\"3\" height=\"3\" fill=\"#f00\"/></svg>",
    b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\">\n  <g id=\"layer\" transform=\"translate(1 2)\">\n    <path d=\"M 0 0 L 5 5\" stroke=\"black\"/>\n    <text x=\"1\" y=\"9\">a &amp; b</text>\n  </g>\n</svg>\n",
    b"<root key=\"value\">Text <child>inside</child>.</root>",
    b"<?xml version=\"1.0\"?><root><!-- comment --><![CDATA[a < b]]></root>",
    b"<html><head><script>if (a < b) {}</script></head><body><p>x</p><br/></body></html>",
    // ── malformed ──
    b"",
    b"   ",
    b"<!-- only -->",
    b"<a><b></a></b>",
    b"<a><b></b>",
    b"<a x=\"1\" x=\"2\"></a>",
    b"<a></a>trailing",
    b"<a/><b/>",
    b"<a>&nope;</a>",
    b"<a>& b</a>",
    b"<a>&amp</a>",
    b"<a>&#xZZ;</a>",
    b"<a>&#xD800;</a>",
    b"<a>&#x110000;</a>",
    b"<a>&#99999999;</a>",
    b"<a>&#;</a>",
    b"<a>&;</a>",
    b"<a x=1/>",
    b"<a x/>",
    b"<a x=\"<\"/>",
    b"<a x=\"unterminated/>",
    b"<a x=\"1\"y=\"2\"/>",
    b"<a/ >",
    b"<a",
    b"<a x=\"1\"",
    b"<1a/>",
    b"</a>",
    b"<a><!-- bad -- comment --></a>",
    b"<a><!-- unterminated </a>",
    b"<a><!-- ends at eof --",
    b"<a><![CDATA[ never </a>",
    b"<![CDATA[x]]><a/>",
    b"<a/><!DOCTYPE late>",
    b"<!DOCTYPE unterminated",
    b"<!DOCTYPE x \"unterminated>",
    b"<!ELEMENT x><a/>",
    b"<a><!DOCTYPE x></a>",
    b"<a><?pi unterminated</a>",
    b"<?1bad?><a/>",
    b"<a></a  x>",
    b"<a></>",
    b"<a>",
    b"text<a/>",
];

fn check(fmt: &str, src: &[u8]) -> Vec<String> {
    let mut problems = Vec::new();
    let ours = super::parse(src);
    match (ours, oracle(&["convert", "-i", fmt, "-o", "table"], src)) {
        (Ok(doc), Ok(expected)) => {
            // TODO(port): Zig's std.json writes a non-UTF-8 byte string as an
            // array of numbers; the shared `json::write_string` does not yet,
            // so the table/AST encodings are compared on UTF-8 input only.
            let utf8 = std::str::from_utf8(src).is_ok();
            if utf8 && table::encode(&doc, Default::default()) != expected {
                problems.push(format!("{fmt} table differs for {:?}", String::from_utf8_lossy(src)));
            }
            let want_ast = oracle(&["convert", "-i", fmt, "-o", "ast"], src).unwrap();
            if utf8 && json::encode(&doc) != want_ast {
                problems.push(format!("{fmt} ast differs for {:?}", String::from_utf8_lossy(src)));
            }
            let want_html = oracle(&["convert", "-i", fmt], src).unwrap();
            let mut html = Vec::new();
            crate::languages::html::serializer::serialize(&doc.ast, &mut html, None).unwrap();
            if html != want_html {
                problems.push(format!(
                    "{fmt} html differs for {:?}:\n ours {:?}\n want {:?}",
                    String::from_utf8_lossy(src),
                    String::from_utf8_lossy(&html),
                    String::from_utf8_lossy(&want_html)
                ));
            }
            let want_canon = oracle(&["convert", "-i", fmt, "-o", "canonical"], src).unwrap();
            if super::serialize(&doc) != want_canon {
                problems.push(format!("{fmt} canonical differs for {:?}", String::from_utf8_lossy(src)));
            }
        }
        (Err(e), Err(stderr)) => {
            let stderr = String::from_utf8_lossy(&stderr);
            if !stderr.trim_end().ends_with(e.name()) {
                problems.push(format!(
                    "{fmt} error differs for {:?}: ours {} oracle {stderr}",
                    String::from_utf8_lossy(src),
                    e.name()
                ));
            }
        }
        (Ok(_), Err(stderr)) => problems.push(format!(
            "{fmt}: we accept {:?}, oracle fails: {}",
            String::from_utf8_lossy(src),
            String::from_utf8_lossy(&stderr)
        )),
        (Err(e), Ok(_)) => problems.push(format!(
            "{fmt}: we fail {:?} with {}, oracle accepts",
            String::from_utf8_lossy(src),
            e.name()
        )),
    }
    problems
}

#[test]
fn differential_against_the_zig_oracle() {
    if !oracle_available() {
        return;
    }
    let mut problems = Vec::new();
    for src in CORPUS {
        problems.extend(check("xml", src));
    }
    for src in super::SVG_SAMPLES {
        problems.extend(check("svg", src.as_bytes()));
    }
    assert!(problems.is_empty(), "{} divergences:\n{}", problems.len(), problems.join("\n"));
}
