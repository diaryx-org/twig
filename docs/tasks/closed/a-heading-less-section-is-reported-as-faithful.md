---
title: A section with no heading is reported as faithful where it does not come back
description: 'Djot and AsciiDoc write a section''s children and nothing of the section when it has no heading, and `nodeFidelity` calls it faithful because the fidelity probe only ever builds a section with one — so an HTML `<body lang="…">` converts to djot with its section and its attributes gone and no warning.'
author: adammharris
created: 2026-09-22
updated: 2026-09-22
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# A section with no heading is reported as faithful where it does not come back

## Resolution

Done on 2026-09-22, in the commit `fix(diagnostics): a section with no
heading is degraded in djot and AsciiDoc`. The probe has a
`section(headless)` row, and what it measured is what `sectionFidelity` now
says: `degraded` in djot and AsciiDoc, which write the section's children
and nothing of it; Markdown already degraded every section, and HTML keeps
one whatever it holds. On the attribute axis, `nodeAttrsFidelity` is the
instance-level counterpart of `nodeFidelity`. It answers `dropped` for a
heading-less section's attributes in djot, where the line they belong on is
never written. The repro now reports `Degraded` and `AttrsDropped` for
`lang` in both formats.

Found while closing
[A degraded node's attributes are reported on neither axis](/docs/tasks/closed/a-degraded-nodes-attributes-are-reported-on-neither-axis.md):
the Word fragment from that task converts to djot as a bare paragraph and
reports nothing about the two sections it lost.

**Repro**, with the CLI:

```
input:  <section lang="x"><p>t</p></section>
djot:      "t\n"                                   no warning
asciidoc:  "t\n"   `section` at `0` carries attributes (lang) that asciidoc cannot write
markdown:  <div lang="x"> … </div>                 Degraded + AttrsDegraded (correct)
```

**Cause.** A section is a heading and what follows it. Djot's serializer
writes a section's attributes as the line above its heading
(`writeSectionAttrs`) and has nothing to write for a section without one,
and the section itself is only ever implied by the heading. So a
heading-less section is not read back as a section in either format. But
`sectionFidelity` refines only AsciiDoc's level-one case, and the probe's
`section` row always builds a heading, so the table's `.faithful` has never
been measured against the shape HTML's parser produces for `<html>`,
`<body>`, `<main>` and `<section>`. The attribute axis then consults
`djotAttrsFidelity(.section)`, which is `.all(.faithful)` and was also
measured with a heading.

**Done when** `sectionFidelity` answers `degraded` for a section whose first
child is not a heading in every target that does not keep one — djot and
AsciiDoc as observed, with Markdown and HTML checked. The probe gains a
heading-less section row, so the answer is measured and not asserted. The
djot repro above then reports `Degraded` and an attribute warning for
`lang`, whichever of `degraded` and `dropped` the probe observes for it. The
commit carries a `Behavioural-change:` trailer, because a consumer
converting HTML to djot will see warnings it did not before.
