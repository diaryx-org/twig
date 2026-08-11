#!/usr/bin/env python3
"""Build twig's own AsciiDoc conformance corpus, in the TCK's own case format.

## Why this file exists at all

Twig's other conformance corpora are *vendored*: CommonMark publishes
`spec.json`, djot.js ships `.test` files, docutils' expectations are lifted out
of its own test modules by `extract-rst-corpus.py`. Each one is somebody else's
authored expectation, and twig's job is only to agree with it.

AsciiDoc has no such thing. The official TCK
(`gitlab.eclipse.org/eclipse/asciidoc-lang/asciidoc-tck`, vendored next door as
`asciidoc-tck-corpus.json`) is `1.0.0-alpha.0` with **thirteen** cases, and it
is not moving — its head commit is the one we vendored, and the last three
commits to it are harness plumbing rather than tests. The normative spec is
likewise six pages long (`lexicon`, `block-element`, `block-content-model`,
`block-parsing-and-structural-form`, `paragraph`, `strong-span`), covering
roughly what twig's parser already implemented against those thirteen cases.
Nor can the expectations be *generated*: no published implementation emits an
ASG, and Asciidoctor structurally cannot, because it has no inline AST — it
substitutes markup straight into output strings.

So the expectations here are twig's own, hand-authored, and this script is where
they are authored. That is a real step down in authority from a vendored corpus
and the corpus file says so in its own `provenance` block. Two things keep it
honest:

  * **The shape is not ours to choose.** Every case is validated against the
    official ASG JSON Schema (`testdata/asg-schema.json`, vendored from
    `asciidoc-lang`) before it is written out. Twig cannot invent a node name, a
    variant, a form, or a required field it forgot to fill in — a case that
    isn't a legal ASG never reaches the corpus.
  * **The format is the TCK's.** Cases are emitted in exactly the shape
    `asciidoc-tck-corpus.json` has, so `conformance.zig` runs both corpora
    through one code path, and so any case here can be exported as an
    `-input.adoc`/`-output.json` pair and offered upstream. `--export-tck DIR`
    does exactly that.

The *behaviour* each case asserts is derived from the AsciiDoc Language
documentation (`asciidoc-lang/docs/modules/`) and, where the docs are silent,
from Asciidoctor's long-standing behaviour. Where neither settles it, the case
carries a `note` recording what was decided and why.

## Authoring model

A case is `(id, source, tree)`. Locations are the fiddly part of an ASG — every
node carries one, 1-based in both `line` and `col`, and **inclusive at both
ends** — so they are computed here rather than typed out:

  * Block nodes take `at=lines(first, last)`: column 1 of `first` through the
    last column of `last`. That is the convention every block in the TCK's own
    corpus follows (`lines(1, 5)` for a five-line listing, delimiters included).
    An indented block passes `col=` for its start column.
  * Inline nodes locate themselves by *scanning the source for their own
    spelling*, from a cursor that only moves forward. Inlines appear in document
    order, so the first match at or after the cursor is the right one, and a
    string that appears twice needs no disambiguation as long as both are
    authored in order. A scan that fails is an error, not a silent skip.

Run it:

    ./scripts/build-asciidoc-corpus.py                 # rewrite the corpus
    ./scripts/build-asciidoc-corpus.py --check         # verify it is current
    ./scripts/build-asciidoc-corpus.py --export-tck D  # write TCK-format pairs

The output is a pure function of this file, so a regenerate produces an empty
diff unless the cases changed.
"""

import argparse
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
TESTDATA = HERE.parent / "src" / "languages" / "asciidoc" / "testdata"
CORPUS = TESTDATA / "asciidoc-twig-corpus.json"
SCHEMA = TESTDATA / "asg-schema.json"


# ── location plumbing ───────────────────────────────────────────────────────


class Loc:
    """A block location expressed in lines, resolved against a source later."""

    def __init__(self, first, last, col=1, end_col=None):
        self.first = first
        self.last = last
        self.col = col
        self.end_col = end_col

    def resolve(self, src):
        lines = src.lines
        end = self.end_col if self.end_col is not None else len(lines[self.last - 1])
        return [
            {"line": self.first, "col": self.col},
            {"line": self.last, "col": end},
        ]


def lines(first, last=None, col=1, end_col=None):
    return Loc(first, last if last is not None else first, col=col, end_col=end_col)


class Source:
    """The case's `.adoc` text, plus the forward-only cursor inlines locate by."""

    def __init__(self, text):
        self.text = text
        self.lines = text.split("\n")
        self.cursor = 0

    def scan(self, needle):
        """Locate `needle` at or after the cursor; advance past it."""
        idx = self.text.find(needle, self.cursor)
        if idx < 0:
            raise ValueError(
                f"inline text {needle!r} not found at/after offset {self.cursor} "
                f"in:\n{self.text!r}\n(inlines must be authored in document order)"
            )
        self.cursor = idx + len(needle)
        return [self.point(idx), self.point(idx + len(needle) - 1)]

    def point(self, offset):
        line = self.text.count("\n", 0, offset) + 1
        line_start = self.text.rfind("\n", 0, offset) + 1
        return {"line": line, "col": offset - line_start + 1}


# ── ASG node builders ───────────────────────────────────────────────────────
#
# Each returns a thunk taking the `Source`, so locations resolve in document
# order against one shared cursor.


def _resolve(node, src):
    return node(src) if callable(node) else node


def _seq(nodes, src):
    return [_resolve(n, src) for n in nodes]


def doc(*blocks, header=None, attributes=None, at=None):
    def build(src):
        out = {"name": "document", "type": "block"}
        if attributes is not None:
            out["attributes"] = attributes
        if header is not None:
            out["header"] = _resolve(header, src)
        body = _seq(blocks, src)
        if body:
            out["blocks"] = body
        out["location"] = (at or lines(1, len(src.lines) - 1)).resolve(src)
        return out

    return build


def header(*title, at=None):
    def build(src):
        out = {"title": _seq(title, src)}
        if at is not None:
            out["location"] = at.resolve(src)
        return out

    return build


def _block(name, at, **fields):
    def build(src):
        out = {"name": name, "type": "block"}
        for key, value in fields.items():
            # An absent key and an empty one are the SAME ASG (the schema spells
            # the empty value in its `defaults` block), and the TCK's own output
            # files always take the absent spelling — a section with no body has
            # no `blocks` key at all. Twig's comparison is exact, so the two
            # must not both be reachable: empty collections are dropped here,
            # and a field the schema actually requires then fails validation
            # rather than being written as an empty stub.
            if value is None or (isinstance(value, (list, tuple)) and not value):
                continue
            out[key] = _seq(value, src) if isinstance(value, (list, tuple)) else value
        out["location"] = at.resolve(src)
        return out

    return build


def para(*inlines, at, **kw):
    return _block("paragraph", at, inlines=list(inlines), **kw)


def leaf(name, *inlines, at, form=None, delimiter=None, **kw):
    return _block(name, at, form=form, delimiter=delimiter, inlines=list(inlines), **kw)


def parent(name, *blocks, at, delimiter, variant=None, **kw):
    return _block(
        name, at, form="delimited", delimiter=delimiter, variant=variant,
        blocks=list(blocks), **kw,
    )


def section(*blocks, title, level, at, **kw):
    return _block("section", at, title=list(title), level=level, blocks=list(blocks) or None, **kw)


def heading(*title, level, at, **kw):
    return _block("heading", at, title=list(title), level=level, **kw)


def ulist(*items, marker="*", at, **kw):
    return _block("list", at, marker=marker, variant="unordered", items=list(items), **kw)


def olist(*items, marker=".", at, **kw):
    return _block("list", at, marker=marker, variant="ordered", items=list(items), **kw)


def colist(*items, marker="<.>", at, **kw):
    return _block("list", at, marker=marker, variant="callout", items=list(items), **kw)


def item(*principal, marker, at, blocks=None, **kw):
    return _block(
        "listItem", at, marker=marker, principal=list(principal),
        blocks=list(blocks) if blocks else None, **kw,
    )


def dlist(*items, marker="::", at, **kw):
    return _block("dlist", at, marker=marker, items=list(items), **kw)


def ditem(*principal, terms, marker="::", at, blocks=None, **kw):
    def build(src):
        out = {"name": "dlistItem", "type": "block", "marker": marker}
        out["terms"] = [_seq(t, src) for t in terms]
        if principal:
            out["principal"] = _seq(principal, src)
        if blocks:
            out["blocks"] = _seq(blocks, src)
        out["location"] = at.resolve(src)
        return out

    return build


def brk(variant, at, **kw):
    return _block("break", at, variant=variant, **kw)


def macro(name, at, target=None, **kw):
    return _block(name, at, form="macro", target=target, **kw)


def text(value, spelling=None):
    """A `text` node. Located by scanning for `spelling` (default: `value`)."""

    def build(src):
        return {
            "name": "text",
            "type": "string",
            "value": value,
            "location": src.scan(spelling if spelling is not None else value),
        }

    return build


def span(variant, *inlines, form="constrained", at=None):
    """An inline span. `at` is its full spelling *including* its delimiters."""

    def build(src):
        loc = src.scan(at) if at is not None else None
        out = {
            "name": "span",
            "type": "inline",
            "variant": variant,
            "form": form,
            "inlines": _seq(inlines, src),
        }
        # The delimiters are scanned first so the span's own location is right,
        # but its children then need to scan from *inside* it — so rewind to
        # just past the opening delimiter before resolving them, and leave the
        # cursor past the whole span afterwards.
        out["location"] = loc
        return out

    def build_ordered(src):
        if at is None:
            return build(src)
        start = src.text.find(at, src.cursor)
        if start < 0:
            raise ValueError(f"span spelling {at!r} not found at/after {src.cursor}")
        end = start + len(at)
        loc = [src.point(start), src.point(end - 1)]
        src.cursor = start
        children = _seq(inlines, src)
        src.cursor = end
        return {
            "name": "span",
            "type": "inline",
            "variant": variant,
            "form": form,
            "inlines": children,
            "location": loc,
        }

    return build_ordered


# ── the cases ───────────────────────────────────────────────────────────────

CASES = []


def case(id, adoc, tree, level="block", note=None):
    CASES.append({"id": id, "adoc": adoc, "tree": tree, "level": level, "note": note})


# The cases live in a separate module so this one stays the machinery.
from asciidoc_cases import define  # noqa: E402

define(
    case=case,
    doc=doc, header=header, para=para, leaf=leaf, parent=parent, section=section,
    heading=heading, ulist=ulist, olist=olist, colist=colist, item=item,
    dlist=dlist, ditem=ditem, brk=brk, macro=macro, text=text, span=span,
    lines=lines,
)


# ── schema validation ───────────────────────────────────────────────────────


class SchemaError(Exception):
    pass


def validate(asg, schema, level):
    """Validate one case's ASG against the official schema.

    A deliberately small subset of JSON Schema — enough for this schema's own
    vocabulary (`$ref`, `allOf`, `oneOf`, `if`/`then`, `const`, `enum`,
    `required`, `properties`, `patternProperties`, `items`, `prefixItems`,
    `additionalProperties`/`unevaluatedProperties: false`) and nothing more. A
    construct the schema starts using that isn't handled here raises rather
    than passing silently.
    """
    if level == "inline":
        for node in asg:
            _check(node, {"$ref": "#/$defs/inline"}, schema, "$")
    else:
        _check(asg, schema, schema, "$")


def _deref(node, schema):
    if "$ref" not in node:
        return node
    ref = node["$ref"]
    if not ref.startswith("#/$defs/"):
        raise SchemaError(f"unsupported $ref {ref}")
    merged = dict(schema["$defs"][ref[len("#/$defs/"):]])
    for key, value in node.items():
        if key != "$ref":
            merged[key] = value
    return merged


def _evaluated(value, node, schema, path):
    """Property names `node` (and everything it composes) accounts for."""
    node = _deref(node, schema)
    seen = set(node.get("properties", {}))
    for pattern in node.get("patternProperties", {}):
        seen |= {k for k in value if re.search(pattern, k)}
    for sub in node.get("allOf", []):
        seen |= _evaluated(value, sub, schema, path)
    for sub in node.get("oneOf", []):
        try:
            _check(value, sub, schema, path)
        except SchemaError:
            continue
        seen |= _evaluated(value, sub, schema, path)
    if "if" in node:
        try:
            _check(value, node["if"], schema, path)
        except SchemaError:
            pass
        else:
            seen |= _evaluated(value, node["then"], schema, path)
    return seen


def _check(value, node, schema, path):
    node = _deref(node, schema)

    for key in node:
        if key not in {
            "$schema", "$id", "$defs", "$ref", "title", "description", "type", "const",
            "enum", "required", "properties", "patternProperties", "items",
            "prefixItems", "minItems", "maxItems", "minimum", "additionalProperties",
            "unevaluatedProperties", "allOf", "oneOf", "if", "then", "defaults",
            "discriminator",
        }:
            raise SchemaError(f"{path}: unsupported schema keyword {key!r}")

    if "type" in node:
        types = {
            "object": dict, "array": list, "string": str, "null": type(None),
            "integer": int, "number": (int, float), "boolean": bool,
        }
        want = node["type"]
        want = [want] if isinstance(want, str) else want
        if not any(
            isinstance(value, types[t]) and not (t != "boolean" and isinstance(value, bool))
            for t in want
        ):
            raise SchemaError(f"{path}: expected {want}, got {type(value).__name__}")

    if "const" in node and value != node["const"]:
        raise SchemaError(f"{path}: expected const {node['const']!r}, got {value!r}")
    if "enum" in node and value not in node["enum"]:
        raise SchemaError(f"{path}: {value!r} not in {node['enum']}")
    if "minimum" in node and value < node["minimum"]:
        raise SchemaError(f"{path}: {value} < minimum {node['minimum']}")

    if isinstance(value, dict):
        for req in node.get("required", []):
            if req not in value:
                raise SchemaError(f"{path}: missing required property {req!r}")
        for key, sub in node.get("properties", {}).items():
            if key in value:
                _check(value[key], sub, schema, f"{path}.{key}")
        for pattern, sub in node.get("patternProperties", {}).items():
            for key in value:
                if re.search(pattern, key):
                    _check(value[key], sub, schema, f"{path}.{key}")
        if node.get("additionalProperties") is False or node.get("unevaluatedProperties") is False:
            extra = set(value) - _evaluated(value, node, schema, path)
            if extra:
                raise SchemaError(f"{path}: unexpected properties {sorted(extra)}")

    if isinstance(value, list):
        for i, sub in enumerate(node.get("prefixItems", [])):
            if i < len(value):
                _check(value[i], sub, schema, f"{path}[{i}]")
        if "items" in node:
            for i, element in enumerate(value):
                _check(element, node["items"], schema, f"{path}[{i}]")
        if "minItems" in node and len(value) < node["minItems"]:
            raise SchemaError(f"{path}: {len(value)} items < minItems {node['minItems']}")
        if "maxItems" in node and len(value) > node["maxItems"]:
            raise SchemaError(f"{path}: {len(value)} items > maxItems {node['maxItems']}")

    for sub in node.get("allOf", []):
        _check(value, sub, schema, path)

    if "oneOf" in node:
        matched = 0
        errors = []
        for sub in node["oneOf"]:
            try:
                _check(value, sub, schema, path)
            except SchemaError as err:
                errors.append(str(err))
            else:
                matched += 1
        if matched != 1:
            raise SchemaError(f"{path}: matched {matched} of oneOf; {errors}")

    if "if" in node:
        try:
            _check(value, node["if"], schema, path)
        except SchemaError:
            pass
        else:
            _check(value, node["then"], schema, path)


# ── output ──────────────────────────────────────────────────────────────────


def build():
    schema = json.loads(SCHEMA.read_text())
    cases = []
    counts = {"block": 0, "inline": 0}
    for spec in CASES:
        src = Source(spec["adoc"])
        tree = spec["tree"]
        asg = _seq(tree, src) if isinstance(tree, list) else _resolve(tree, src)
        try:
            validate(asg, schema, spec["level"])
        except SchemaError as err:
            raise SystemExit(f"case {spec['id']}: ASG violates the schema: {err}")
        counts[spec["level"]] += 1
        entry = {
            "id": spec["id"],
            "level": spec["level"],
            "adoc": spec["adoc"],
            "config": None,
            "asg": asg,
        }
        if spec["note"]:
            entry["note"] = spec["note"]
        cases.append(entry)

    ids = [c["id"] for c in cases]
    if len(set(ids)) != len(ids):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        raise SystemExit(f"duplicate case ids: {dupes}")

    return {
        "provenance": {
            "source": "twig — hand-authored, NOT vendored",
            "authored_by": "scripts/build-asciidoc-corpus.py (regenerate with it; do not edit this file by hand)",
            "why": (
                "The official AsciiDoc TCK is 1.0.0-alpha.0 with 13 cases and is not "
                "growing; the normative spec covers six pages; and no implementation "
                "emits an ASG to generate expectations from (Asciidoctor has no inline "
                "AST at all). These expectations are therefore twig's own reading of "
                "the AsciiDoc Language documentation, not a third party's authored "
                "test suite — a weaker authority than testdata/asciidoc-tck-corpus.json "
                "next door, which stays the normative ratchet."
            ),
            "validated_against": (
                "asg-schema.json — the official ASG JSON Schema "
                "(https://schemas.asciidoc.org/asg/1-0-0/draft-01), vendored from "
                "gitlab.eclipse.org/eclipse/asciidoc-lang/asciidoc-lang @ "
                "cf4674c019b387fbb6d609a39a28ebf9f20db8e0. Every case here is checked "
                "against it at generation time, so node names, variants, forms and "
                "required fields are the WG's, not twig's."
            ),
            "format": (
                "Identical to asciidoc-tck-corpus.json's, so conformance.zig runs both "
                "through one path and any case here can be exported as a TCK "
                "-input.adoc/-output.json pair (--export-tck) and offered upstream."
            ),
            "license": "EPL-2.0, matching the AsciiDoc TCK's, so cases can be contributed upstream unchanged.",
            "counts": {"cases": len(cases), **counts},
        },
        "cases": cases,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="fail if the corpus is stale")
    ap.add_argument("--export-tck", metavar="DIR", help="also write TCK-format input/output pairs")
    args = ap.parse_args()

    corpus = build()
    rendered = json.dumps(corpus, indent=1, ensure_ascii=False) + "\n"

    if args.check:
        current = CORPUS.read_text() if CORPUS.exists() else ""
        if current != rendered:
            print(f"{CORPUS} is stale — rerun {sys.argv[0]}", file=sys.stderr)
            return 1
        print(f"{CORPUS} is current ({len(corpus['cases'])} cases)")
        return 0

    CORPUS.write_text(rendered)
    print(f"wrote {CORPUS} ({len(corpus['cases'])} cases)")

    if args.export_tck:
        root = pathlib.Path(args.export_tck)
        for entry in corpus["cases"]:
            path = root / entry["id"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.with_name(path.name + "-input.adoc").write_text(entry["adoc"])
            path.with_name(path.name + "-output.json").write_text(
                json.dumps(entry["asg"], indent=2) + "\n"
            )
        print(f"exported {len(corpus['cases'])} TCK-format pairs under {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
