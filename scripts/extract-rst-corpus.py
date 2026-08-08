#!/usr/bin/env python3
"""Extract docutils' reStructuredText parser tests into a language-neutral corpus.

Twig's other two conformance corpora arrive ready to use: CommonMark publishes
`spec.json`, and djot.js ships `.test` files that are plain text. rST has
neither. Its authoritative test suite is *Python source* — 60-odd
`test/test_parsers/test_rst/test_*.py` modules, each building a `totest` dict of

    totest['group'] = [
      ["<rST input>", "<expected pseudo-XML doctree>"],
      ...
    ]

and asserting `docutils.utils.new_document(...).pformat() == expected`. This
script lifts those pairs out into one JSON file that `languages/rst/` can
`@embedFile`, so running the corpus never needs Python or docutils installed.

    ./scripts/extract-rst-corpus.py <path-to-docutils-sdist-root> [-o OUT]

Extraction is a *static* read: the module is parsed with Python's own `ast` and
every string is folded from literals only (`ast.literal_eval` semantics plus
`'a' + 'b'` constant folding). docutils is never imported and no test ever runs,
so the output is a pure function of the source tree — same input tree, same
bytes out, no timestamp in the file. That matters because this corpus is
committed: a regenerate must produce an empty diff unless docutils changed.

## What gets skipped, and why

A case is skipped when either half is not statically knowable — an f-string
interpolating `__file__`, a `PYGMENTS_2_14_OR_HIGHER` conditional, a `%`-format
over a computed path. These are overwhelmingly `include` directive tests whose
expectations embed the absolute path of the test file itself; they are not
portable to a Zig harness under any extraction scheme. Every skip is counted and
itemized in the output's `provenance.skipped` so the tally is auditable and
nothing is dropped silently.

`test_TableParser.py` / `test_SimpleTableParser.py` also contribute little: they
assert against docutils' *internal* table-parser return tuples rather than a
doctree, which is an API contract Twig does not reimplement. The rST-level table
coverage lives in `test_tables.py` and `test_directives/test_tables.py`, both of
which extract cleanly.

## Licensing

Most of docutils is public domain, but `COPYING.txt` lists four files under
`test/test_parsers/test_rst/` as BSD-2-Clause (Copyright © Günter Milde). They
are excluded by name below. As of docutils 0.21.2 all four would yield zero
cases anyway (their expectations are dynamic), but relying on that is an
accident waiting to change under us — the exclusion makes the guarantee that
the emitted corpus is 100% public domain hold by construction.
"""

import argparse
import ast
import collections
import hashlib
import json
import pathlib
import sys

# COPYING.txt "Exceptions": BSD-2-Clause, not public domain. See module docstring.
NON_PUBLIC_DOMAIN = {
    "test_directives/test__init__.py",
    "test_directives/test_code_parsing.py",
    "test_line_length_limit.py",
    "test_line_length_limit_default.py",
}

# These assert docutils' internal table-parser API, not a doctree: their `totest`
# pairs are (source, parsed-tuple) and, for malformed input, (source, exception
# message string). The message-string cases are the dangerous ones — they are
# statically foldable, so they extract cleanly and look like every other case
# while carrying no doctree at all. Excluded by module; `validate` below is the
# backstop that catches any future file that does the same thing.
NOT_DOCTREE_TESTS = {
    "test_TableParser.py",
    "test_SimpleTableParser.py",
}


def const_str(node):
    """Fold a node to `str` using literals only; `None` if it isn't static.

    Handles the two spellings the suite actually uses: a plain (possibly
    implicitly concatenated) string literal, and explicit `+` concatenation.
    Anything else — f-string, `%` format, conditional, call — is a skip.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = const_str(node.left), const_str(node.right)
        return None if left is None or right is None else left + right
    return None


def extract(rst_test_dir):
    cases, skipped = [], []
    for path in sorted(rst_test_dir.rglob("test_*.py")):
        rel = path.relative_to(rst_test_dir).as_posix()
        if rel in NON_PUBLIC_DOMAIN or rel in NOT_DOCTREE_TESTS:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            # Only `totest['group'] = [...]` assignments carry cases.
            if not isinstance(node, ast.Assign):
                continue
            target = node.targets[0]
            if not (
                isinstance(target, ast.Subscript)
                and isinstance(target.value, ast.Name)
                and target.value.id == "totest"
            ):
                continue
            group = const_str(target.slice)
            if group is None or not isinstance(node.value, (ast.List, ast.Tuple)):
                skipped.append({"file": rel, "line": node.lineno, "why": "non-literal totest assignment"})
                continue
            for index, pair in enumerate(node.value.elts):
                if not isinstance(pair, (ast.List, ast.Tuple)) or len(pair.elts) != 2:
                    # test_TableParser.py and friends: internal-API tuples, not
                    # (source, doctree) pairs.
                    skipped.append({"file": rel, "line": pair.lineno, "why": "case is not an [input, expected] pair"})
                    continue
                source, expected = const_str(pair.elts[0]), const_str(pair.elts[1])
                if source is None or expected is None:
                    half = "input" if source is None else "expected"
                    kind = type(pair.elts[0] if source is None else pair.elts[1]).__name__
                    skipped.append({"file": rel, "line": pair.lineno, "why": f"{half} is dynamic ({kind})"})
                    continue
                cases.append(
                    {
                        "file": rel,
                        "group": group,
                        "index": index,
                        "line": pair.lineno,
                        "rst": source,
                        "doctree": expected,
                        # docutils reports recoverable syntax errors *into the
                        # doctree* as <system_message>/<problematic> nodes, so a
                        # third of the suite is really error-recovery assertion.
                        # Flagged so the Zig harness can ratchet on the clean
                        # subset before Twig has anywhere to put diagnostics.
                        "asserts_error": "<system_message" in expected or "<problematic" in expected,
                    }
                )
    return cases, skipped


def validate(cases):
    """Fail loudly if anything that isn't a doctree slipped through.

    `document.pformat()` always opens with `<document source="test data">`, so a
    case whose expectation doesn't is a test module asserting something else
    entirely (see `NOT_DOCTREE_TESTS`). Rather than silently shipping it as a
    case a Zig harness would then fail forever, stop and make the human add the
    module to the exclusion set.
    """
    strays = [c for c in cases if not c["doctree"].lstrip().startswith("<document")]
    if strays:
        listing = "\n".join(f"  {c['file']}:{c['line']}  {c['doctree'][:60]!r}" for c in strays[:10])
        sys.exit(
            f"{len(strays)} extracted case(s) do not hold a pseudo-XML doctree:\n{listing}\n"
            "Add the module to NOT_DOCTREE_TESTS if it asserts a non-doctree contract."
        )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sdist_root", type=pathlib.Path, help="unpacked docutils sdist root (contains COPYING.txt)")
    ap.add_argument("-o", "--output", type=pathlib.Path, required=True)
    ap.add_argument("--sdist-sha256", default=None, help="sha256 of the sdist tarball, recorded as provenance")
    args = ap.parse_args()

    rst_test_dir = args.sdist_root / "test" / "test_parsers" / "test_rst"
    if not rst_test_dir.is_dir():
        sys.exit(f"not a docutils sdist root (no {rst_test_dir}): {args.sdist_root}")

    version = "unknown"
    version_py = args.sdist_root / "docutils" / "__init__.py"
    if version_py.is_file():
        for node in ast.walk(ast.parse(version_py.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", None) == "__version__":
                version = const_str(node.value) or version

    cases, skipped = extract(rst_test_dir)
    validate(cases)
    by_file = collections.Counter(c["file"] for c in cases)
    doc = {
        "provenance": {
            "source": "docutils test/test_parsers/test_rst",
            "docutils_version": version,
            "sdist_url": f"https://files.pythonhosted.org/packages/source/d/docutils/docutils-{version}.tar.gz",
            "sdist_sha256": args.sdist_sha256,
            "license": "public domain (docutils COPYING.txt); BSD-2-Clause test files excluded by name",
            "extracted_by": "scripts/extract-rst-corpus.py",
            "expectation_format": "docutils pseudo-XML doctree (document.pformat())",
            "counts": {
                "cases": len(cases),
                "asserts_error": sum(c["asserts_error"] for c in cases),
                "clean": sum(not c["asserts_error"] for c in cases),
                "files": len(by_file),
                "skipped": len(skipped),
            },
            "skipped": skipped,
        },
        "cases": cases,
    }
    payload = json.dumps(doc, indent=1, ensure_ascii=False, sort_keys=False) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(payload, encoding="utf-8")

    print(f"docutils {version} -> {args.output}")
    print(f"  {len(cases)} cases ({doc['provenance']['counts']['clean']} clean, "
          f"{doc['provenance']['counts']['asserts_error']} error-asserting) from {len(by_file)} files")
    print(f"  {len(skipped)} skipped")
    print(f"  sha256(json) = {hashlib.sha256(payload.encode()).hexdigest()}")


if __name__ == "__main__":
    main()
