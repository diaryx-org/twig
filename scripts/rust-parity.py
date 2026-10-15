#!/usr/bin/env python3
"""Differential parity check: the Rust `twig` CLI against the Zig one.

Builds a corpus from the repository's own test data (the djot.js cases, the
CommonMark and GFM spec examples, both AsciiDoc corpora, the HTML those specs
expect, and the repository's Markdown documents), runs both binaries over it
with every output mode, and reports how many invocations agree byte for byte
on stdout and exit status.

    scripts/rust-parity.py [--zig zig-out/bin/twig] [--rust target/release/twig]
                           [--only djot,markdown,...] [--mismatches FILE] [-j N]
"""

import argparse
import concurrent.futures as cf
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANG = ROOT / "src" / "languages"


def djot_cases():
    for path in sorted((LANG / "djot" / "testdata").glob("*.test")):
        lines = path.read_text(encoding="utf-8").split("\n")
        i = 0
        n = 0
        while i < len(lines):
            line = lines[i]
            if line.startswith("```") and line.strip("`") == "":
                fence = line
                i += 1
                inp = []
                while i < len(lines) and lines[i] != ".":
                    inp.append(lines[i])
                    i += 1
                while i < len(lines) and lines[i] != fence:
                    i += 1
                yield f"{path.stem}-{n}", "\n".join(inp) + "\n"
                n += 1
            i += 1


def spec_cases(name):
    data = json.loads((LANG / "markdown" / "testdata" / name).read_text(encoding="utf-8"))
    for case in data:
        yield case["example"], case["markdown"], case["html"]


def asciidoc_cases():
    for name in ("asciidoc-tck-corpus.json", "asciidoc-twig-corpus.json"):
        data = json.loads((LANG / "asciidoc" / "testdata" / name).read_text(encoding="utf-8"))
        for case in data["cases"]:
            yield f"{name.split('-')[1]}-{case['id']}", case["adoc"]


def repo_markdown():
    for path in sorted(ROOT.glob("**/*.md")):
        rel = path.relative_to(ROOT)
        if rel.parts[0] in ("target", "zig-out", ".zig-cache", "bindings") or ".git" in rel.parts:
            continue
        yield str(rel).replace("/", "_"), path.read_bytes()


XML_SAMPLES = [
    b'<?xml version="1.0"?>\n<root a="1" b=\'2\'><child/><x:y xmlns:x="u">t</x:y><!-- c --><![CDATA[a<b]]></root>\n',
    b'<svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="5" height="5"/><g><circle r="1"/></g></svg>',
    b'<!DOCTYPE note SYSTEM "Note.dtd">\n<note>\n  <to>Tove</to>\n  <body>Don&apos;t &amp; &lt;forget&gt; &#65;&#x42;</body>\n</note>\n',
    b'<a><b></a>',
    b'<?pi data?><r>\n\t<e attr="&quot;q&quot;"></e>\n</r>',
    b'',
    b'<r><unclosed>',
    b'text outside',
]


def write_corpus(tmp: pathlib.Path):
    """Returns [(format_name, path)]."""
    out = []

    def put(fmt, ext, name, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        p = tmp / fmt / f"{name}.{ext}"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        out.append((fmt, p))

    for name, text in djot_cases():
        put("djot", "dj", name, text)
    for ex, md, html in spec_cases("commonmark-spec-0.31.2.json"):
        put("markdown", "md", f"cm-{ex}", md)
        put("html", "html", f"cm-{ex}", html)
    for ex, md, html in spec_cases("gfm-spec-0.29-extensions.json"):
        put("markdown", "md", f"gfm-{ex}", md)
        put("html", "html", f"gfm-{ex}", html)
    for name, data in repo_markdown():
        put("markdown", "md", f"repo-{name}", data)
    for name, text in asciidoc_cases():
        put("asciidoc", "adoc", name, text)
    for i, data in enumerate(XML_SAMPLES):
        put("xml", "xml", f"sample-{i}", data)
        put("svg", "svg", f"sample-{i}", data)
    return out


OUTPUTS = ["table", "ast", "html", "canonical", "djot", "markdown", "asciidoc"]

VARIANTS = {
    "djot": [["-i", "djot"]],
    "markdown": [
        ["-i", "markdown"],
        ["-i", "commonmark"],
        ["-i", "gfm"],
        ["-i", "markdown", "--math", "--directives", "--highlight-colors", "--feature", "html_elements"],
    ],
    "html": [["-i", "html"]],
    "asciidoc": [["-i", "asciidoc"]],
    "xml": [["-i", "xml"]],
    "svg": [["-i", "svg"]],
}


def run(binary, args):
    try:
        p = subprocess.run([binary] + args, capture_output=True, timeout=30)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", b"", b""
    except FileNotFoundError:
        return "missing", b"", b""


def job(zig, rust, fmt, variant, output, path):
    args = ["convert"] + variant + ["-o", output, str(path)]
    z = run(zig, args)
    r = run(rust, args)
    same = z[0] == r[0] and z[1] == r[1]
    return fmt, " ".join(variant[2:]) or "-", output, str(path), same, z, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zig", default=str(ROOT / "zig-out" / "bin" / "twig"))
    ap.add_argument("--rust", default=str(ROOT / "target" / "release" / "twig"))
    ap.add_argument("--only", default="")
    ap.add_argument("--outputs", default=",".join(OUTPUTS))
    ap.add_argument("--mismatches", default="")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    outputs = a.outputs.split(",")

    with tempfile.TemporaryDirectory() as td:
        corpus = write_corpus(pathlib.Path(td))
        jobs = []
        for fmt, path in corpus:
            if only and fmt not in only:
                continue
            for variant in VARIANTS[fmt]:
                for output in outputs:
                    jobs.append((fmt, variant, output, path))
        tally = {}
        bad = []
        with cf.ThreadPoolExecutor(max_workers=a.j) as ex:
            futs = [ex.submit(job, a.zig, a.rust, *j) for j in jobs]
            for f in cf.as_completed(futs):
                fmt, var, output, path, same, z, r = f.result()
                key = (fmt, var, output)
                t = tally.setdefault(key, [0, 0])
                t[1] += 1
                if same:
                    t[0] += 1
                else:
                    bad.append((key, path, z, r))

    total_ok = sum(v[0] for v in tally.values())
    total = sum(v[1] for v in tally.values())
    for key in sorted(tally):
        ok, n = tally[key]
        flag = "" if ok == n else "  <--"
        print(f"{key[0]:9} {key[1][:40]:40} {key[2]:9} {ok:5}/{n:<5}{flag}")
    pct = 100.0 * total_ok / total if total else 0.0
    print(f"TOTAL {total_ok}/{total} = {pct:.2f}%")
    if a.mismatches:
        with open(a.mismatches, "w", encoding="utf-8") as fh:
            for key, path, z, r in sorted(bad, key=lambda b: (b[0], b[1])):
                fh.write(f"== {key} {path}\n")
                fh.write(f"   zig  exit={z[0]} stdout={z[1][:400]!r} stderr={z[2][:200]!r}\n")
                fh.write(f"   rust exit={r[0]} stdout={r[1][:400]!r} stderr={r[2][:200]!r}\n")
    return 0 if total_ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
