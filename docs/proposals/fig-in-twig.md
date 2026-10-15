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

`draft`. Step 1 below is built, in `crates/twig-meta`. It is a crate of its
own, beside `twig-doc`, so nothing about `twig-doc` itself changes until the
decisions under **Open questions** are made.

This proposal was first written against the Zig implementation, where step 1
was a `src/meta/` module behind `zig build -Dfig`. twig and fig are both
Rust now, and the module is the `twig-meta` crate, with the same functions
and the same tests.

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

The whole proposal turns on one question: does `twig-doc` depend on fig?
It argues no, and puts the fig half in a crate of its own.

**twig locates.** Finding a block and saying where its fences and body are
is a document question, and it stays in `twig-doc`, fig-free. Every
archetype in the table above becomes a `metadata` node (or a node twig can
report as one) with three spans: the opening fence, the body, and the
closing fence. This is what fig's docs already promise, and every design
below needs it.

**`twig-meta` edits and reads.** A second crate, `crates/twig-meta`,
depends on `twig-doc` and on `fig`. It opens `fig::Editor` over a block's
body, splices the result back, synthesizes a block for a document that has
none, and reads the config as fig values. `twig-doc`, the CLI, the C ABI and
the wasm module compile none of it.

Two reasons keep fig out of `twig-doc`.

- **fig registers its languages per process.** fig's registry is the
  `fig-core` crate's; a language registered through one copy of it is
  unknown to another. `twig-meta` depends on the same `fig` and language
  crates a program like prov does, so Cargo unifies them and there is one
  registry. `twig_meta::dialect_for` registers the four languages it brings
  (YAML, TOML, JSON, figl) the first time it is asked, and finds any other
  language the program registered by the fence's tag.
- **Most of twig's callers never touch metadata.** A conformance run, an
  HTML render or an editor keystroke needs no config parser, and should not
  pay for one in size or build time.

### Why a crate and not a `fig` feature of `twig-doc`

The draft of this proposal for the Zig implementation said `twig-doc` would
gain a `fig` feature. It is a crate instead, for now, because fig's Rust
port is not on crates.io: the `fig` 6.0.0 published there is the
Zig-backed binding (`fig-sys`), whose language crates have no `fig`
feature, and `fig-core` is not published at all. So `twig-meta` takes fig
from git, pinned to a commit, and is `publish = false`. A git dependency
in `twig-doc`, even an optional one, would stop `cargo publish -p twig-doc`.

Once fig's Rust port is released, `twig-meta` moves to fig by version (the
org's rule) and can be published, or folded into `twig-doc` behind a `fig`
feature. Either is a small move: the crate uses only `twig-doc`'s public
modules.

**Update, 2026-10-15.** fig 7, the Rust port, is on crates.io, and
`twig-meta` now takes `fig` and its four language crates by version and is
published. It stays a crate: [one crate per language](language-crates.md)
leaves `twig-doc` with no features but, at most, a `fig` one, and whether
`twig-meta` becomes that feature is still open.

### The API

```rust
use twig_meta::{Embed, Where};

let mut e = Embed::open_in(host, twig::Format::Markdown, Where::Front)?;
e.editor_mut().set_value(&["title".into()], "Hello")?;
let host = e.render()?;
```

`find` locates a block (`Block`: its node, fence tag, whole span and body
span), `Embed::open` opens one, `Embed::open_or_init` writes a new block
above a document's first line when it has none, `read` gives the body as a
`fig::Document`, and `resolve` reads render settings (below). fig 5's `fig`
and `yml` fence tags still read, as figl and YAML.

The cost of the split is that the splice lives outside `twig-doc`. The
splice is small, and the part worth having once, which is locating the
blocks and the archetype rules, lives in `twig-doc` where every consumer
reads it.

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
`features` are the names `Format::feature_flags` already reads for each
row: Markdown's extensions, or a runtime language's declared features.
Nothing new is invented. A document's settings are laid over a caller's
features; they never turn anything off. A name twig does not know is
reported, not refused, so a document written for a newer twig still
renders on an older one.

Reading a document's settings is a two-pass parse. Frontmatter is a leading
construct that no extension changes, so the first pass finds it under the
caller's features, and the second reads the document as it asks.
`twig_meta::resolve` does this and is built; `Resolved::parse` is the
second pass. What is not decided is whether the CLI applies it unasked. A
document that says `features: [math]` and is today rendered without math
would render with it, which is a behavioural change for every
`twig convert` caller (see **Open questions**).

Settings are the first use, not the only one. AST-KINDS already plans for
"a future pass [that] hoists front+end blocks into one parsed doc-level
`fig` record". With `twig-meta`, that pass can produce a record of fig
values that the HTML printer reads for `<title>` and `lang`, and the editor
reads to know a document's dialect without being told.

## The sequence

1. **`twig-meta`, over the blocks twig reads today.** *Built*, in
   `crates/twig-meta`, tested by `cargo test -p twig-meta` (and so by CI's
   `cargo test --workspace`).
2. **The remaining archetypes, in `twig-doc`.** `;;;` JSON frontmatter
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
4. **The CLI.** `twig meta get|set|…`, the verbs `fig --embed` had, in the
   `twig` CLI. Whether the release CLI depends on `twig-meta` is an open
   question below, and waits on fig being on crates.io, since `twig-doc-cli`
   is published.
5. **fig by version.** Done: `twig-meta` depends on fig 7 by version and is
   published. Next, prov moves `MetaEditor` from `fig::Embed` to it.
6. **The hoisted record**, and the HTML printer and editor reading it.

## Open questions

- **Does the release CLI depend on `twig-meta`?** The recommendation is yes.
  The CLI is where `twig meta` and settings are most useful, and its size
  is not what anyone weighs. The library and C ABI stay fig-free.
- **Does `twig convert` apply a document's settings unasked?** The
  recommendation is yes, behind a `--no-settings` escape, recorded as a
  `Behavioural-change:`. The other choice, an opt-in `--settings`, is the
  safe one, but it would be safe mostly by going unused.
- **Is `twig` the right key?** It is short and says whose it is. A
  workspace-wide default belongs to prov's config, not to each document,
  and is out of scope here.
- **A crate or a feature, once fig is on crates.io?** A crate keeps
  `twig-doc`'s dependency list empty for everyone; a feature saves a
  dependency line for those who want it. Either reads the same to prov.
