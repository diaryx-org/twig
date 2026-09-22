---
title: "`href`, `src` and `alt` are reported as attributes the Markdown target dropped"
description: 'The HTML parser keeps a link''s `href` and an image''s `src`/`alt` in the node''s attribute bag *besides* modelling them as the destination and the alt text, so the attribute axis measures them against Markdown''s absent attribute syntax and reports `AttrsDropped` on markup the conversion writes in full.'
author: adammharris
created: 2026-09-18
updated: 2026-09-22
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# `href`, `src` and `alt` are reported as attributes the Markdown target dropped

## Resolution

Done on 2026-09-22, in the commit `fix(diagnostics): a degraded node's attributes are reported, and a link's href is not`,
on the recommended fix: the HTML parser's `setElementAttrs` leaves out of
the bag what `semanticKind` promoted — `href` from a link, `src` and `alt`
from an image, `start` from an ordered list — and keeps a key the model did
not take (`start="iii"`, an `<a>` with no `href`).

The `hrefValue` cost did not apply: `renderAttributes` already let the
synthesized key win over the bag's, so the bag copy never reached HTML
output and no `href` survived through it. The HTML→HTML output of all three
fragments is unchanged. The one HTML difference is `<ol start="1">`, which
the model spells as the default and now writes as `<ol>`.

Every link and every image in an HTML document reports a loss that did not
happen. A consumer gating on `diagnostics` cannot tell this false positive
from a real one, because the warning carries the same `fidelity` and the same
`kind` either way.

Found by leaf's paste gate when it moved to twig 3.6.0
(`c8a293b`, `crates/leaf-core/src/html.rs`): declining on `AttrsDropped`
made every link and image on the clipboard unpasteable, and the gate now
carries a written-out exemption for this case rather than the rule it wanted.

**Repro**, against 3.6.0's Rust binding (`bindings/rust/twig`). Parse the
fragment as `Format::Html`, ask `diagnostics(Target::Markdown)`, and
serialize to the same target:

```
input:  <p>a <a href="https://x.dev">l</a></p>
attrs:  Link [("href", Some("https://x.dev"))]
warn:   AttrsDropped path="0/1" kind=Link
output: "a [l](https://x.dev)\n"

input:  <p><img src="u" alt="p"></p>
attrs:  Image [("src", Some("u")), ("alt", Some("p"))]
warn:   AttrsDropped path="0/0" kind=Image
output: "![p](u)\n"
```

The destination is in the output, the alt text is in the output, and the
warning says they were dropped. `Target::Djot` reports the same two warnings
for the same two fragments, so this is not Markdown's.

**Cause.** `languages/html/parser.zig` promotes `href` to
`link.destination` and `src`/`alt` to `image.destination` and a synthesized
`str` child, *and leaves the raw attributes in the bag* — its own comment says
so, and `diagnostics.zig`'s `noteAttrs` then measures the bag against
`markdownAttrsFidelity(.link)`, which is `.all(.dropped)` because Markdown's
link syntax has no attribute spelling. Both statements are true; the
conflict is that the key is in two places at once and only one of them is
consulted.

`ordered_list` is the third instance and shows the shape more plainly, because
there Markdown's answer is `.degraded` rather than `.dropped`:

```
input:  <ol start="3"><li>x</li></ol>
attrs:  OrderedList [("start", Some("3"))]
warn:   AttrsDegraded path="0" kind=OrderedList
output: "<div start=\"3\">\n\n3. x\n\n</div>\n"
```

The `3.` marker already carries `start`; the bag copy is what produces the
spurious `<div start="3">` wrapper around it. So the duplicate bag entry is
not only a reporting defect — it makes the serializer write markup for a fact
the node's own model had already spelled.

**Recommended fix: the bag does not carry what the node's model owns.**
Strip `href` from an `a` promoted to `link`, `src` and `alt` from an `img`
promoted to `image`, and `start` from an `ol`, at the point of promotion in
the HTML parser. Preferred over exempting the keys per kind in
`attrsFidelity` because:

- `AttrsFidelity` has four buckets — `id`, `class`, `title`, `other` — and no
  way to say "this one key on this one kind". A per-kind exemption needs a new
  mechanism, and then needs repeating in `djotAttrsFidelity`,
  `markdownAttrsFidelity` and `asciidocAttrsFidelity` alike, since the false
  positive appears in each.
- The exemption would be a table asserting what the parser does, which is the
  arrangement the round-trip probe exists to replace.
- `html/serializer.zig`'s `renderLinkOrImage` already synthesizes
  `href`/`src`/`alt` from the model and dedups the bag against them — the test
  `HTML round-trip does not duplicate attributes promoted to semantic fields`
  pins the output, and it is unchanged by an empty bag. The dedup then becomes
  dead weight rather than load-bearing.
- A duplicate entry is a hazard beyond diagnostics: an editor gesture that
  rewrites the bag's `href` changes nothing the serializer reads.

The cost to weigh is `hrefValue` — the serializer normalizes a destination on
its way out, so an exotic `href` that today survives via the bag copy would
then round-trip through the model's normalization instead. Check the HTML
corpus for one before committing to it.

**Done when** `<p>a <a href="https://x.dev">l</a></p>` and
`<p><img src="u" alt="p"></p>` parsed as HTML report no warning at all
against `Target::Markdown` and `Target::Djot`; `<ol start="3">` writes
`3. x` with no `<div start="3">` around it; the HTML→HTML round-trip of all
three is byte-identical to what it is today; and the change carries a
`Behavioural-change:` trailer, because a consumer gating on `AttrsDropped`
observes a different set of warnings after upgrading.
