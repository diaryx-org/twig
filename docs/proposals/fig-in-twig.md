---
title: 'Proposal: fig in twig'
part_of: '[Proposals](/docs/proposals/proposals.md)'
status: draft
author: adammharris
created: 2026-10-14
updated: 2026-10-15
---

# fig in twig

## Status

`draft`. Step 1 below is built, in `src/meta/`. It is a separate module
behind `-Dfig`, so nothing about `twig` itself changes until the decisions
under **Open questions** are made.

## The picture

fig 6.0 took embedding out of fig. `fig.Embed`, the `fig_embed_*` C ABI,
Rust's `Embed`/`EmbedType` and the CLI's `--embed` are gone
(fig's `docs/migrating-to-6.md`, "Embedding has left fig"). What fig's docs
say instead is that twig locates the block and the caller opens fig's
`Editor` over its contents and splices the result back.

That sentence moves work onto every consumer, and twig only half does its
part today. prov is the consumer that shows the size of it. Its
`MetaEditor` (`prov-store/src/edit.rs`) runs every metadata edit through
`fig::Embed`, and `prov-graph/src/document.rs` names twenty `EmbedType`
archetypes in four families:

| prov's family | archetypes | twig today |
| --- | --- | --- |
| delimited | `---` YAML, `+++` TOML, `;;;` JSON, `---json`/`---toml`/`---fig` | `---`, `+++` and `---<lang>` are `metadata` nodes; `;;;` is not read |
| code block | ```` ```yaml ````/`json`/`toml`/`fig` blocks, YAML endmatter | endmatter is a `metadata` node; a fenced block is a `code_block`, nothing more |
| HTML script | `<script type="application/yaml">` and the rest | not read as metadata |
| HTML code | `<pre><code class="language-yaml">` and the rest, entity-encoded | not read as metadata, and nothing decodes the entities |

When prov moves to fig 6 it has nothing to move to. The user-facing goal is
to give it something, and to give twig's own CLI and editor the same thing:
a document's config read and edited in place, with comments and spacing
kept.

The second goal is that twig *uses* what the config says. A document's
frontmatter is the natural place for it to say how it should be read: which
Markdown dialect it is, and which extensions it was written with. Today a
caller has to know that from somewhere else and pass it in.

## The split

The whole proposal turns on one question: does twig's core depend on fig?
It argues no, and puts the fig half in its own module.

**twig locates.** Finding a block and saying where its fences and body are
is a document question, and it stays in `twig`, fig-free. Every archetype
in the table above becomes a `metadata` node (or a node twig can report as
one) with three spans: the opening fence, the body, and the closing fence.
This is what fig's docs already promise, and every design below needs it.

**`twig-meta` edits and reads.** A second Zig module, `src/meta/`, imports
`twig` and `fig`. It opens fig's `Editor` over a block's body, splices the
result back, synthesizes a block for a document that has none, and reads
the config as fig values. It is built only with `-Dfig`, and fig is a lazy
dependency, so the core library, the C ABI, the wasm module and the Rust
crates' vendored Zig fetch and compile nothing new.

Two reasons keep fig out of the core.

- **fig 6 registers its languages per process.** A program that links
  fig's own crate *and* a twig with a private copy of fig has two
  registries. A language registered with one is unknown to the other, and
  the binary carries fig twice. prov is that program: it depends on `fig`
  and on `twig-doc` both.
- **Most of twig's callers never touch metadata.** A conformance run, an
  HTML render or an editor keystroke needs no config parser, and should not
  pay for one in size, build time or the Rust crate's prebuilt payload.

### The Rust side

For the same first reason, the Rust binding should not get its embedding
from a fig inside `twig-sys`. `twig-doc` gains a `fig` feature that depends
on the `fig` crate and does in Rust what `twig-meta` does in Zig. twig's
spans say where the body is, `fig::Editor` edits it, and the result is
spliced back. It is a thin layer, a few hundred lines, and the type prov
needs is roughly fig 5's `Embed`:

```rust
let mut e = twig::meta::Embed::open(text, twig::meta::Carrier::Frontmatter)?;
e.set_value(&[Segment::Key("title")], "Hello")?;
let text = e.render();
```

It waits on fig 6.0 being on crates.io, since the org's rule is that fig is
a crates.io dependency by version.

The cost of this is that the splice is written twice, once in Zig and once
in Rust. The splice is small, and the part worth having once, which is
locating the blocks and the archetype rules, lives in twig's core where
both read it.

## Render settings

A document names its own settings under a `twig` key in its frontmatter:

```yaml
---
title: Notes
twig:
  dialect: gfm
  features: [math, highlight]
---
```

`dialect` is a row of the host's own language (`gfm`, `commonmark`), and
`features` are the names `format.features` already gives each row's
features: Markdown's extensions, or a runtime language's declared features.
Nothing new is invented. A document's settings are laid over a caller's
config; they never turn anything off. A name twig does not know is
reported, not refused, so a document written for a newer twig still
renders on an older one.

Reading a document's settings is a two-pass parse. Frontmatter is a leading
construct that no extension changes, so the first pass finds it under the
caller's config, and the second reads the document as it asks.
`twig-meta`'s `resolve` does this and is built. What is not decided is
whether the CLI applies it unasked. A document that says `features: [math]`
and is today rendered without math would render with it, which is a
behavioural change for every `twig convert` caller (see **Open questions**).

Settings are the first use, not the only one. AST-KINDS already plans for
"a future pass [that] hoists front+end blocks into one parsed doc-level
`fig` record". With `twig-meta`, that pass can produce a record of fig
values that the HTML printer reads for `<title>` and `lang`, and the editor
reads to know a document's dialect without being told.

## The sequence

1. **`twig-meta`, over the blocks twig reads today.** *Built.* `find`
   locates frontmatter and endmatter, `Embed` edits one through fig and
   renders the host back, `Embed.openOrInit` writes a new block above a
   document's first line, and `resolve` reads render settings. A fence's
   tag names fig's dialect, and fig 5's `fig` and `yml` spellings still
   read. `zig build test-meta -Dfig` runs its tests, and CI runs it as a
   step of its own.
2. **The remaining archetypes, in `twig`.** `;;;` JSON frontmatter
   (a `metadata` node, like `+++`). Fenced config blocks: a `code_block`
   whose info string names a config language is *reported* as metadata by
   `twig-meta`, and stays a `code_block` in the tree, because it renders as
   one. HTML `<script type="application/<lang>">` islands, which twig's HTML
   printer already writes and its parser should read back. `<code>` islands
   with their entity codec. Each is a task, with the archetype's tests from
   fig's deleted `embed.zig` carried over.
3. **Retype.** Rewrite a block from one archetype or language to another
   (`---` YAML to `+++` TOML), as fig's `Embed.retype` did. prov's
   `convert` needs it. fig converts the body, and twig writes the fences.
4. **The C ABI and the CLI.** `twig meta get|set|…`, the verbs `fig
   --embed` had, in a `twig` built with `-Dfig`. Whether the release CLI is
   built that way is an open question below.
5. **`twig-doc`'s `fig` feature**, once fig 6.0 is on crates.io. Then prov
   moves `MetaEditor` from `fig::Embed` to it.
6. **The hoisted record**, and the HTML printer and editor reading it.

## Open questions

- **Does the release CLI build with `-Dfig`?** The recommendation is yes.
  The CLI is where `twig meta` and settings are most useful, and its size
  is not what anyone weighs. The library and C ABI stay fig-free.
- **Does `twig convert` apply a document's settings unasked?** The
  recommendation is yes, behind a `--no-settings` escape, recorded as a
  `Behavioural-change:`. The other choice, an opt-in `--settings`, is the
  safe one, but it would be safe mostly by going unused.
- **Is `twig` the right key?** It is short and says whose it is. A
  workspace-wide default belongs to prov's config, not to each document,
  and is out of scope here.
