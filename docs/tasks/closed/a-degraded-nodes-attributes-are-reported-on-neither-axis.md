---
title: A degraded node's attributes are reported on neither axis
description: '`analyze` reports a node on the node axis or the attribute axis, never both, so a `Section` that Markdown writes as a literal `<div class="MsoNormal">` raises `Degraded` and no `Attrs*` warning — the markup a consumer is gating against is the one thing the diagnostics do not name.'
author: adammharris
created: 2026-09-18
updated: 2026-09-22
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# A degraded node's attributes are reported on neither axis

## Resolution

Done on 2026-09-22, in the commit `fix(diagnostics): a degraded node's attributes are reported, and a link's href is not`,
on the preferred decision: `walk` asks the attribute axis of every node that
is not dropped, so the Word fragment below yields its five warnings. A
dropped node is reported once, at the node — nothing of it is written — and
a test pins that.

Asking the table about degraded nodes meant measuring it there. The probe
now round-trips every node it does not drop, and found two things the old
rule had hidden:

- **A degraded node's attributes cannot be faithful.** The node is not read
  back as itself, so no key comes back as its. `AttrsFidelity.under` caps
  `faithful` at `degraded` for such a node, which is also what lets one row
  answer for a djot container with a name (degraded) and one without.
- **The rows for degraded kinds were never measured.** HTML writes a task
  list's, a definition list's and a line block's attributes on the element
  it renders (`degraded`, not `dropped`); Markdown writes a container's on a
  directive or a `<span>`; AsciiDoc writes an id and role on an inline
  container and on `insert`/`delete`; HTML writes nothing for curly quotes,
  a symbol or a substitution reference, and overwrites a footnote
  reference's id. Each row now says what the probe observes.

The C ABI and the Rust binding carry the extra warnings
unchanged — each warning is its own `TwigWarning` with its own code — and
their docs no longer say an `ATTRS_*` code means the node survived.

`Collector.walk` in `diagnostics.zig` is an `if`/`else`: a node whose
`nodeFidelity` is lossy gets a node-axis warning, and `noteAttrs` is reached
only in the `else` branch. So the attribute axis, added in 3.6 precisely so a
consumer could see the `<div …>` Markdown now writes for a block's
attributes, is silent on exactly the nodes that are already in trouble.

The two axes answer different questions — *is this node read back as itself*
and *are this node's attributes read back as its* — and a node can fail both.
Suppressing the second under the first loses the answer rather than
deduplicating it.

Found by leaf's paste gate on twig 3.6.0 (`c8a293b`,
`crates/leaf-core/src/html.rs`), whose one question is "would converting put
something in the document the user did not copy?". A Word paste is the case:
the gate exempts `Degraded/Section` deliberately, because twig models
`<html>` and `<body>` as sections and their loss is not visible markup — but
the `<div>`s written *for those sections' attributes* very much are, and
nothing in the warning list says so.

**Repro**, against 3.6.0's Rust binding (`bindings/rust/twig`). Parse as
`Format::Html`, ask `diagnostics(Target::Markdown)`, serialize to the same
target:

```
input:  <html xmlns:o="urn:x"><body lang="EN-US"><p class="MsoNormal">Word text</p></body></html>
attrs:  Para [("class", Some("MsoNormal"))]
attrs:  Section [("lang", Some("EN-US"))]
attrs:  Section [("xmlns:o", Some("urn:x"))]
warn:   Degraded path="0" kind=Section
warn:   Degraded path="0/0" kind=Section
warn:   AttrsDegraded path="0/0/0" kind=Para
output: "<div xmlns:o=\"urn:x\">\n\n<div lang=\"EN-US\">\n\n<div class=\"MsoNormal\">\n\nWord text\n\n</div>\n\n</div>\n\n</div>\n"
```

Three `<div>`s are written and one is reported. The two sections carry
`xmlns:o` and `lang`, `markdownAttrsFidelity(.section)` is `.all(.degraded)`
— the same answer that produced the `Para` warning — and neither section
raises an `Attrs*` warning, because `walk` never asks.

**Decide, and say so in the fix.** Either `walk` calls `noteAttrs`
unconditionally, so a doubly lossy node yields two warnings at the same path
(one per subject, which is what `Warning.subject` is for and what a consumer
reading the pair already handles); or a node-axis warning is documented as
subsuming the attribute answer, and the binding's `Fidelity` docs say that a
`Degraded` node's attributes are unmeasured so a consumer knows not to trust
the absence. The first is preferred here — the axes are independent by
construction, and a `Dropped` node is the only case where the attribute answer
is genuinely implied (nothing is emitted, so nothing of its attributes is
either).

**Done when** the fragment above yields an attribute-axis warning for each of
the two sections beside their `Degraded` warnings — five warnings, not three —
with the node-axis and attribute-axis warnings at a shared path distinguished
by `subject` as they already are elsewhere; a `Dropped` node's behaviour is
whatever the decision above says and is covered by a test either way; the C
ABI and the Rust and WASM bindings carry the extra warnings without change
(they already key on `fidelity`, not on one warning per path — check); and the
change carries a `Behavioural-change:` trailer, since any consumer counting or
gating on `diagnostics` sees more warnings after upgrading.
