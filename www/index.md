---
title: twig
nav_title: twig
nav_order: 30
description: twig — a round-trippable document AST for Markdown, Djot, and HTML. Parse once, edit precisely, write back exactly what you mean.
audience: public
part_of: '[twig](/README.md)'
id: wxmq0ww
---
<section class="pj-head">
  <div class="wrap">
    <p><a class="crumb" href="../about/#projects">diaryx.org / projects /</a></p>
    <div class="pj-title" style="margin-top: 1rem">
      <h1>twig</h1>
      <span class="pj-tags">
        <span class="tag-chip">Zig</span>
        <span class="tag-chip">MIT / Apache-2.0</span>
      </span>
    </div>
    <p class="pj-tagline">
      A round-trippable document AST for Markdown, Djot, and HTML.
    </p>
  </div>
</section>

<section class="pj-main">
<div class="wrap pj-layout reveal">
<div class="pj-body">

Where fig parses configuration files, twig parses
*documents*. It's comparable to Pandoc, but with different
goals: not conversion for its own sake, but exposing the abstract
syntax tree so precise operations can be performed on it — then
writing the document back, faithfully.

- **Round-trippable by intent.** First-class support is for formats you can edit and re-serialize without loss — not presentation formats like PDF.
- **Markdown.** Fully CommonMark 0.31.2 conformant: 652/652 spec examples passing.
- **Djot.** 100% conformant with the djot.js corpus — every case that defines an HTML expectation passes.
- **HTML.** A generic-markup parser and serializer with forgiving, document-oriented tree construction.
- **An editor surface.** Offset-addressed edits, ancestor queries, inline toggles — the operations a text editor needs, defined on the tree.

## Where it fits

twig is the document model everything at Diaryx is written
against — every entry in a vault is a twig document, and
[leaf](id:leaf/z4z2w13) is a rich-text editor over its tree.
Standalone, it's a library (crates.io as `twig-doc`)
for anyone who needs to treat markup as data.

</div>
<aside class="pj-aside">
<div class="install">
<span class="install-head">Install</span>
<div class="cmd">brew install diaryx-org/tap/twig <small>CLI</small></div>
<div class="cmd">cargo add twig-doc <small>Rust</small></div>
</div>
<div class="facts">
<div class="row"><span class="k">Language</span><span class="v">Zig (Rust bindings)</span></div>
<div class="row"><span class="k">Used by</span><span class="v"><a href="../prov/index.md">prov</a> · <a href="../leaf/index.md">leaf</a> · <a href="../index.html">Diaryx</a></span></div>
<div class="row"><span class="k">Source</span><span class="v"><a href="https://github.com/diaryx-org/twig">github.com/diaryx-org/twig</a></span></div>
<div class="row"><span class="k">Packages</span><span class="v"><a href="https://crates.io/crates/twig-doc">crates.io/crates/twig-doc</a> · <a href="https://docs.rs/twig-doc">docs.rs/twig-doc</a></span></div>
<div class="row"><span class="k">License</span><span class="v">MIT or Apache-2.0</span></div>
</div>
</aside>
</div>
</section>
