---
title: TypeScript
part_of: '[Twig](/README.md)'
---
# twig for TypeScript & JavaScript

`@diaryx/twig` parses, queries, **edits** and converts documents — Djot,
Markdown (twig's own, strict CommonMark, and GFM), HTML, XML (and SVG) and
AsciiDoc — and reads and writes their frontmatter. An edit is a splice: every
byte you did not touch stays as it was.

The core is twig's Rust library compiled to WebAssembly and embedded in the
package, so there is **no native build step and no separate `.wasm` file to
serve**. It runs in Node, Bun, Deno and the browser. Every language twig ships
is compiled in.

- [Install](#install)
- [Loading the module](#loading-the-module)
- [Quick start](#quick-start)
- [Formats](#formats)
- [Reading a document](#reading-a-document)
- [Editing](#editing)
- [Metadata](#metadata)
- [Errors](#errors)
- [Managing resources](#managing-resources)
- [Developing the binding](#developing-the-binding)

## Install

```sh
npm install @diaryx/twig
```

Requires Node 22+, or a current Bun, Deno or browser. The package is ESM-only
and ships its own TypeScript types.

## Loading the module

The WebAssembly core initializes **lazily**: the first call that needs it
compiles it. Under Node, Bun, Deno and Web Workers you can call any API
directly.

On a **browser main thread**, the platform does not allow synchronous
compilation of a module larger than 4 KB. Call `init()` once at startup, before
any other twig API:

```ts
import { init, renderHtml } from "@diaryx/twig";

await init();
renderHtml("# Hi\n", "md");
```

`isReady()` tells you whether the module is loaded, without loading it.

## Quick start

```ts
import { convert, Document, Editor, metadataValue, renderHtml } from "@diaryx/twig";

renderHtml("# Hi *there*\n", "md");           // "<h1>Hi <em>there</em></h1>\n"
convert("Some *emphasis*.\n", "md", "djot");  // "Some _emphasis_.\n"

metadataValue("---\ntitle: Notes\n---\n# Body\n", "md"); // { title: "Notes" }

using ed = Editor.create("# Title\n\nText.\n", "md");
ed.replace('heading("Title")', "# New title");
ed.source; // "# New title\n\nText.\n"
```

## Formats

Every API that takes a format takes a `Format` code or a name:

| `Format`            | names                    |
|---------------------|--------------------------|
| `Format.Djot`       | `djot`                   |
| `Format.Markdown`   | `markdown`, `md`         |
| `Format.CommonMark` | `commonmark`             |
| `Format.Gfm`        | `gfm`                    |
| `Format.Html`       | `html`                   |
| `Format.Xml`        | `xml`                    |
| `Format.Svg`        | `svg`                    |
| `Format.AsciiDoc`   | `asciidoc`               |

`formatByName`, `formatName` and `dialectOf` (Markdown for GFM, XML for SVG)
read the registry.

Markdown extensions are off unless you turn them on. Pass `MarkdownFlags`,
OR-ed together, as `flags`:

```ts
import { MarkdownFlags, renderHtml } from "@diaryx/twig";

renderHtml("Some ==marked== text.\n", "md", { flags: MarkdownFlags.Highlight });
```

## Reading a document

`Document.parse(input, format, { flags })` gives a read-only handle. Input is a
string or UTF-8 bytes.

```ts
using doc = Document.parse(source, "md");

doc.renderHtml();               // HTML
doc.serialize("djot");          // the document in another format
doc.diagnostics("djot");        // what that conversion would lose
doc.ast();                      // twig's AST, as `twig convert -o ast` writes it
doc.query("heading[level=2]");  // [{ id, kind, span, contentSpan? }, …]
doc.nodes();                    // the whole tree, flat: links, payloads, attributes
doc.children();                 // the top-level blocks
doc.nodeAt(offset);             // the deepest node at a byte offset
doc.nodesAt(offset);            // every node at it, root first
```

**Spans are UTF-8 byte offsets**, as the core counts them, not JavaScript
string indices. `doc.text(span)` gives the source text a span covers.

Selectors are twig's CSS-lite selectors: `heading`, `heading[level=2]`,
`link[dest^="http"]`, `list > item`, `heading("Status")`. See the
[cookbook](/docs/COOKBOOK.md).

## Editing

`Editor.create(input, format, { flags })` opens a lossless editor over a
private copy of the source. It reparses after every edit, and an edit that
fails, or that would leave a document that does not parse, changes nothing.

An edit is addressed by a **locator**: a dot-separated child-index path
(`"0.3.1"`) or a selector that must match exactly one node
(`heading("Status")`).

```ts
using ed = Editor.create(source, "md");

ed.replace(locator, text);         // the node's whole source
ed.replaceContent(locator, text);  // a container's interior
ed.insertBefore(locator, text);
ed.insertAfter(locator, text);
ed.insertChild(locator, index, text);
ed.delete(locator);                // { smart: false } removes the exact span
ed.unwrap(locator);
ed.moveBefore(locator, anchor);
ed.moveAfter(locator, anchor);
ed.filter("directive", { keep: "directive[name=keep]", unwrapKept: true });
ed.editRange(start, end, text);    // UTF-8 byte offsets

ed.undo(); ed.redo();              // each edit is one undo step
ed.source;                         // the edited text
ed.revision;                       // bumped by each edit, undo and redo
```

Each edit returns its `Change`: the `oldSpan` it replaced and the `newSpan` its
text now fills, so a caret can re-anchor.

`ed.document()` is a `Document` over the editor's live tree. It stays current
across edits; it reads, queries and walks, but cannot render or serialize
(parse `ed.source` for that). `ed.query`, `ed.nodes` and `ed.ast` read through
it.

## Metadata

A document's metadata block is its frontmatter (`---` YAML, `+++` TOML,
`---<lang>`), its endmatter (a tagged `---<lang>` block at the end), or, in an
HTML page, the first `<script type="application/<lang>">` data island. An
island is always the **front** block. twig reads YAML, TOML, JSON and figl
bodies.

```ts
import { metadataValue, readMetadata, setMetadata } from "@diaryx/twig";

const src = "---\ntitle: Hi # kept\n---\n# Body\n";

metadataValue(src, "md");        // { title: "Hi" }
readMetadata(src, "md");         // { lang: "yaml", span, bodySpan, body: "title: Hi # kept\n" }
readMetadata(src, "md", "end");  // null: no endmatter

setMetadata(src, "md", "title: Hello # kept\n");
// "---\ntitle: Hello # kept\n---\n# Body\n"
```

`Document` and `Editor` have the same reads as methods (`metadata(at)`,
`metadataValue(at)`), and `Editor#setMetadata(body, { at, lang })` is one undo
step.

`setMetadata` replaces the **body**: every byte outside it, the fences
included, stays. The body must parse in the block's language. When a document
has no front block, `setMetadata` writes one in `lang` (YAML by default): above
the first line, or in an HTML page as an island inside `<head>` (else after a
leading doctype). The old body is never parsed, so `setMetadata` can repair a
block that does not parse. A body that would close its block early — `</script`
or `<!--` in an island, or a line such as TOML's `+++` inside a multi-line
string — is refused with `Status.UnsafeMetadata`, and nothing changes.

`metadataValue` gives the body as data, not as text, so it cannot keep
comments. To change one value and keep every comment, edit the body with
[`@diaryx/fig`](https://www.npmjs.com/package/@diaryx/fig) and give the result
to `setMetadata`:

```ts
import { Editor as FigEditor, registerLanguage } from "@diaryx/fig";
import yaml from "@diaryx/fig-yaml";
import { readMetadata, setMetadata } from "@diaryx/twig";

const Yaml = registerLanguage(yaml);
const block = readMetadata(src, "md")!;
using fig = FigEditor.open(block.body, Yaml);
fig.setValue(["title"], "Hello");
const out = setMetadata(src, "md", fig.source());
```

## Errors

A failed call throws a `TwigError`. Its `status` is the core's `Status` code,
and `op` is the C entry point that returned it:

| `Status`            | when                                                        |
|---------------------|-------------------------------------------------------------|
| `InvalidArgument`   | a malformed selector, locator or range                      |
| `ParseError`        | the input, or a metadata body, does not parse               |
| `UnsupportedFormat` | an unknown format, or a direction with no serializer        |
| `NotFound`          | a locator matched nothing; no metadata block where asked    |
| `Ambiguous`         | a selector locator matched more than one node               |
| `NotEditable`       | the node has no editable span                               |
| `EditConflict`      | the edit would leave a document that does not parse         |
| `UnsafeMetadata`    | a metadata body would close its block early                 |

A status a newer core adds passes through as its number.

## Managing resources

A `Document` and an `Editor` each hold memory inside the WebAssembly module.
Release it with `dispose()`, or let a `using` declaration do it:

```ts
using doc = Document.parse(source, "md");
```

A handle dropped without `dispose()` is freed when it is garbage-collected, as
a backstop. The one-call helpers (`renderHtml`, `convert`, `parseAst`,
`readMetadata`, `metadataValue`, `setMetadata`) release what they open.

## Developing the binding

The binding lives in `bindings/typescript`. It is a thin layer over twig's C
ABI ([`twig.h`](/bindings/c/include/twig.h)), built from `crates/twig-capi`
for `wasm32-unknown-unknown` with the workspace's size-first `wasm` profile.

```sh
cd bindings/typescript
npm ci
npm run build   # builds the wasm module, inlines it, compiles to dist/
npm test        # Node 24+: the tests run their .ts under type stripping
```

The package takes twig's one version, `[workspace.package] version` in the
root `Cargo.toml`. `node scripts/version-sync.mjs` writes it into
`package.json` and its lockfile (`ship` runs it after a bump), and `--check`
fails on any that disagrees. A `v*` tag publishes the package to npm
(`.github/workflows/release-npm.yml`).
