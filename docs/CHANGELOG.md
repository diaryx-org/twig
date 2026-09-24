---
part_of: '[Twig](/README.md)'
---
# Twig — changelog

One entry per released version, newest first, plus an `Unreleased` section for
work that has landed on `main` and not yet been tagged.

Release notes used to live only in the annotated tag message
(`git tag -n20`). Those are kept, but a one-line summary cannot carry the
section this file exists for.

## Behavioural changes are their own section

Every entry has an **Added** list and, when it applies, a **Behavioural
changes** list. A behavioural change is one that alters *what an existing call
returns* without altering any type, signature, or ABI code — the class of
change that compiles clean against the previous version and fails at runtime.

The section is mandatory rather than a courtesy, because nothing else catches
this class for Twig's consumers. `TwigFlatNode.kind` is a `const char *` and
the Rust binding surfaces it as a `String`, so a renamed kind is not a compile
error in any language that binds Twig — it is a test failure, or a silently
wrong render, in whatever consumes the name. The same holds for a span whose
extent changes, a node that moves to a different parent, and a field that
starts reporting `NONE` where it used to report a value.

The rule for whether something belongs here: **if a caller who upgrades
without editing a line of their own code would observe a difference, it goes in
this section** — even when the change is a bug fix, and even when the previous
behaviour was plainly wrong.

## Where a behavioural change is written down

On the commit that causes it, as a `Behavioural-change:` trailer. `cliff.toml`
collects them into the section above.

```
fix(markdown): a block quote's span covers its own trailing marker lines

<the body: why, and how it works>

Behavioural-change: A Markdown `block_quote`'s span now covers its own
  trailing marker lines. `"> a\n>\n> \n"` reported `0..3` and now reports
  `0..8`. `content_span` is unchanged.
```

One trailer per observable difference; a commit may carry several, and most
commits carry none. Continuation lines are indented two spaces and fold into
one paragraph. Write the value for a consumer deciding whether to upgrade —
what used to happen, what happens now — not for a reviewer reading the diff.
That is what the body above it is for.

This used to be handwritten prose kept below the generated region, on the
argument that the judgment "would an unedited caller observe a difference" is
not a fact recoverable from a commit subject. That much is still true, and it
is why the trailer exists rather than some heuristic over `fix:` versus
`add:` — only the author knows. What was wrong was the conclusion: the
judgment has to be *made* at the commit, but it does not have to be *stored*
somewhere else. Writing it twice meant it could drift from the change it
describes, or be forgotten between landing the commit and cutting the release,
which is exactly when it is least likely to be reconstructed.

## How the Unreleased section is written

`release changelog --write` regenerates the marked region below from the
commits since the last tag, using `.config/cliff.toml`: one bullet per commit, grouped
Breaking / Added / Fixed / Changed, then the **Behavioural changes** section
gathered from the trailers. Edits inside the markers are overwritten on the
next run.

What is left to write by hand is a release **intro** — a paragraph or two for a
release that wants a narrative rather than a list, like 3.0.0's account of why
it is a major. Most releases want none, and an intro that only restates the
bullets below it should be cut. It goes below the end marker, where
regeneration cannot reach it.

Cutting a release is `release release <version|major|minor|patch|as-is>`, which
regenerates the region, renames `## Unreleased` to the version, strips the two
marker lines out of the section that just became history, and opens a fresh
empty `## Unreleased` above it. Exactly one marker pair is ever in this file, so
a later `--write` cannot reach back into a released section. See
[RELEASING.md](/docs/RELEASING.md).

## Unreleased

<!-- git-cliff:begin — generated; edits here are overwritten -->

_No commits since the last tag._

<!-- git-cliff:end -->

## 3.11.0

### Added

- **editor** — insert an inline or a display formula ([`56f28f7`](https://github.com/diaryx-org/twig/commit/56f28f7bc110597e51654d0b5bca691fb75e921c))

### Fixed

- **serialize** — djot writes math as djot, and display math is written tight ([`b54ef22`](https://github.com/diaryx-org/twig/commit/b54ef22a7d8f44d5c223a93e273a542bb39e7839))
- **editor** — toggle a code block inside a list item at the item's content column ([`9e38272`](https://github.com/diaryx-org/twig/commit/9e3827258644508550ff05aae680045adac9825c))

### Behavioural changes

- serializing to djot writes inline math as `` $`x` `` and display math as `` $$`x` `` instead of `$x$` and `$$\nx\n$$`; the output now reads back as math rather than as text.

- serializing to Markdown writes display math as `$$x$$` instead of `$$\nx\n$$`.

- fidelity (and `--warn`, and TwigWarning) reports inline and display math converted to djot as faithful rather than degraded, so a conversion that used to warn about them no longer does.

- `Syntax.text_leaf_delims` reports inline and display math as authorable for djot, for Markdown under `math`, and inline math for AsciiDoc; `twig lang syntax` prints those entries without `"authorable":false`.

- a runtime language whose syntax JSON lists `inline_math` or `display_math` delimiters without `"authorable":false` and names no `render_block` renderer is refused at registration (rule `claim_needs_renderer`), where it used to load. One that names `render_block` is now held by the contract to the two math gestures, which it was not before.

- `toggleCodeBlock` (C `twig_editor_toggle_code_block`, Rust `Editor::toggle_code_block`) no longer returns NotEditable inside a Markdown or Djot list item; it fences at the item's content column (`- a` becomes "- ```\n  a\n  ```\n") and unfences back (`- a`), including ordered, nested, task and quoted items.

- In AsciiDoc, a block attached to a list item by a `+` line can now be fenced and unfenced; the item's own first line is still NotEditable.

- A selection spanning several list items now fences the whole list at the list's column instead of returning NotEditable.

- Fencing a paragraph with a lazy continuation line inside a quote or list item now writes the container prefix onto that line, so the fence no longer ends the container (`> a\nb` gives "> ```\n> a\n> b\n> ```\n").

- Unfencing a Markdown indented code block inside a quote now dedents it after the quote marker (`>     code` gives `> code`); it was previously left unchanged.

- Unfencing an empty code block that is a list item's first block keeps the item (`-`), and a block following it in the item moves up under the marker instead of being left outside the item.


## 3.10.0

### Breaking

- **runtime** — register a language at runtime, in Zig, C and Rust ([`cd8caf3`](https://github.com/diaryx-org/twig/commit/cd8caf3c26bd84f4b024c4d4e62629da9d846d22))

### Added

- **markdown** — read and write underline as `<u>`…</u> ([`2bc933a`](https://github.com/diaryx-org/twig/commit/2bc933a1303c481e34ed7953728291d1ac877479))
- **table** — the node table, with every compiled format crossing it ([`741d74a`](https://github.com/diaryx-org/twig/commit/741d74ad3d6cfbeb6290668df54ff01ea61bf040))
- **helper** — the helper wire, and the runners in the CLI and Rust ([`18fb926`](https://github.com/diaryx-org/twig/commit/18fb926428869036223ec9282d08995bad91de1f))
- **syntax** — Syntax.validate names the rule a table breaks, and the line model is written down ([`935c60e`](https://github.com/diaryx-org/twig/commit/935c60eb0dfec0cd9a4b6d905f284a223584b068))
- **syntax** — Syntax as JSON, with every compiled table crossing it, and twig lang syntax ([`b46b6d9`](https://github.com/diaryx-org/twig/commit/b46b6d9d5a0a219d6805a547874f3359bf62d506))
- **contract** — the engine contract as a library that reports, run by the harness and at registration ([`be4a30e`](https://github.com/diaryx-org/twig/commit/be4a30e73b00bab5ba57072b3d8544bb7d64a77b))
- **contract** — every gesture, everywhere — the generative check an unseen Syntax is held to ([`8f9aaff`](https://github.com/diaryx-org/twig/commit/8f9aaffb3162394201732b0476816cd7429160f3))

### Fixed

- **tasks** — open-tasks leaves out dropped tasks and the closed shelf ([`d6c053b`](https://github.com/diaryx-org/twig/commit/d6c053b96a75369fead8cc4b3f6a52a73c013e03))
- **parse** — xml, html and asciidoc compact their arenas like djot and markdown ([`02efb1d`](https://github.com/diaryx-org/twig/commit/02efb1d9c49146fc8f5ea5aa3ca52c75fc929007))
- **markdown** — key the editing tables on tables, task_lists and footnotes ([`011eb77`](https://github.com/diaryx-org/twig/commit/011eb77b13a907b933d76c42fe9882f5b8a8ff91))
- **editor** — setBlock keeps the block's containers, and a join keeps a container it cannot take whole ([`6bb54e1`](https://github.com/diaryx-org/twig/commit/6bb54e1b96fed3c7fe53ebead787d54593d49580))

### Behavioural changes

- serializing an `insert` mark to Markdown writes `<u>x</u>` where it wrote `{+x+}`; the old spelling read back as literal text, the new one renders as underline and pairs back into an `insert` under `html_elements`.

- with `html_elements` on, Markdown `<u>x</u>` parses to an `insert` mark over `x` instead of two `raw_inline` nodes around it, and renders to HTML as `<ins>x</ins>`.

- HTML `<u>` parses to an `insert` mark instead of a generic `element`, and so serializes back to HTML as `<ins>`.

- `twig_format_supports` / `Syntax.inline_delims` report `insert` as authorable for Markdown parsed with `html_elements`.

- node ids in a parsed XML, SVG, HTML or AsciiDoc document are in document order with the root at 0, where the root was the last id and children came before their parents; a caller that addressed nodes by id across a reparse was already wrong, and one that read `twig_document_nodes` in id order now reads them in document order.

- an HTML document no longer carries unreferenced nodes in its arena, so `twig_document_nodes` and the node count report fewer nodes for documents with inter-element whitespace, `<thead>`/`<tbody>`, or `<code>` over text.

- an AsciiDoc document's `labels.footnotes` maps each `footnote:` label to its definition, where it was empty.

- a format code at or above `TWIG_FORMAT_RUNTIME_BASE` that a registration holds is accepted by every entry point that takes a format, where every such code was refused with `TWIG_STATUS_UNSUPPORTED_FORMAT`.

- Rust `From<Format>`/`From<Target>` for `twig_sys::TwigFormat` panics on the new `Runtime` variant; `Format::code` is total.

- with stderr redirected to a file, `twig`'s messages are appended where they were written from offset 0; output that other writers put on the same file is no longer overwritten.

- `-i`, `-o`, and a file's extension that name nothing compiled in now consult the `languages` files and may start a helper process, where they failed with "unsupported format" at once; the supported-formats list also shows configured languages.

- a runtime language refused at load for a sample now reports "`<name>`: sample N does not parse: …" (and "… prints to source that reparses to a different tree") where it reported "sample N: …"; the language's own reason still follows.

- over the `commonmark` row, and any Markdown parse config with `tables`, `task_lists` or `footnotes` off, `Editor.supports` and `twig_format_supports` answer false for the table gestures, the task-box gestures and `insert_footnote` respectively, and the gestures return `UnsupportedFormat`; over `gfm`, `insert_footnote` is unsupported. They used to succeed and write text the parser did not read as a table, a box or a footnote.

- `setBlock` over a Markdown paragraph or heading inside a block quote keeps the quote's `> `; it was deleted, and the block left the quote.

- `joinBlocks` returns `NotEditable` where B would leave an HTML `<blockquote>`, `<ul>`/`<ol>` or `<li>` (or any container that closes with markup) that holds more after B; it used to succeed and leave unbalanced tags.

- `joinBlocks` out of a prefix-spelled quote that continues after B now writes a blank line between the joined block and the rest of the quote, where the rest used to follow the joined text directly.


## 3.9.2

### Fixed

- **diagnostics** — a degraded node's attributes are reported, and a link's href is not ([`ab3d221`](https://github.com/diaryx-org/twig/commit/ab3d2210a857804c69738c67476b1bb2125159db))
- **markdown** — a literal typed under the math extension escapes its dollars ([`8721abc`](https://github.com/diaryx-org/twig/commit/8721abc8f5147400ff74a4a3ae9e20a59c24117d))
- **diagnostics** — a section with no heading is degraded in djot and AsciiDoc ([`ca9bf83`](https://github.com/diaryx-org/twig/commit/ca9bf83dd7d4a3fb6aff7936c3a2c863ea167294))
- **editor** — delete_smart takes an indented element's whole line ([`b03ed3e`](https://github.com/diaryx-org/twig/commit/b03ed3e2bd34f352bf77546c222e7de2fdb00cdd))

### Behavioural changes

- `diagnostics` reports an attribute-axis warning
(`AttrsDegraded`/`AttrsDropped`) beside a `Degraded` warning at the same
path when the degraded node's attributes are lost too — the Word-paste
fragment `<html xmlns:o…><body lang…><p class…>` yields five warnings
against Markdown, not three. A `Dropped` node still yields one.

- attribute warnings for some kinds change fidelity or
appear where they did not: HTML task lists, definition lists and line
blocks; Markdown containers; AsciiDoc inline containers and insert/delete
marks; HTML curly quotes, symbols, substitution and footnote references.

- an HTML-parsed link, image or `<ol start>` no longer
has `href`, `src`/`alt` or `start` in its attributes, and no longer
reports them as `AttrsDropped`/`AttrsDegraded`; converting `<ol start="3">`
to Markdown writes `3. x` with no `<div start="3">` around it, and `<ol
start="1">` to HTML writes `<ol>`.

- on a Markdown editor created with the `math` extension,
`insert_literal` writes every `$` as `\$`, and `insert_link` with an empty
selection writes a `$` in the destination-as-text as `\$`. A document parsed
without the extension is unchanged.

- converting an HTML document to djot or AsciiDoc reports
`Degraded` for each `<html>`, `<body>`, `<main>` or `<section>` that does
not open with a heading, and `AttrsDropped` beside it when that element
carries attributes. Djot reported nothing for these before; AsciiDoc
reported only the attributes.

- `delete_smart` on a node alone on an indented line —
  an XML element in a pretty-printed document, an indented block in a
  lightweight format — now removes the whole line, indentation and
  newline included. `"<r>\n  <a/>\n  <b/>\n</r>"` deleting `<a/>` gave
  `"<r>\n  \n  <b/>\n</r>"` and now gives `"<r>\n  <b/>\n</r>"`.


## 3.9.1

### Fixed

- **editor** — move_block reads a container's edges as boundaries outside it ([`a6cdfc9`](https://github.com/diaryx-org/twig/commit/a6cdfc91325bd08caf71a0d7aaea6878d84f07ce))

### Behavioural changes

- `move_block` with `to` at or before a block quote's
  marker (or a delimited container's first byte) now lands the block
  before the container, at its parent's level, where it landed inside the
  container before its first block. `to` at the first content byte is
  unchanged.

- `move_block` with `to` at the boundary the block
  already sits on, when the block is its container's first or last, now
  moves it out of the container — before or after it — where it returned
  InvalidArgument (or, on the blank line after a one-block quote,
  InvalidArgument too). At the top level, and for a block between two
  others, it is still InvalidArgument.

- `move_block` with `to` equal to the source's length,
  in a source whose last line has no line end, now lands the block after
  the last top-level block, where it landed inside whatever container that
  line closed — a trailing list item's tail, a trailing quote.


## 3.9.0

### Added

- **editor** — move a block to a boundary, spelling the destination's prefixes ([`56415a9`](https://github.com/diaryx-org/twig/commit/56415a9179254c3bfc29a687e54e9db8ab7047b0))

### Behavioural changes

- An AsciiDoc `block_quote` written with `> ` now records
  a marker span covering its first line's `> `, so
  `twig_document_marker_span` reports a span there where it reported
  `not_found`. The `____` form is unchanged.


## 3.8.1

### Added

- **xml** — record every element's attribute span ([`b5ac339`](https://github.com/diaryx-org/twig/commit/b5ac3396d7d59c4461a38874c89d49c0f9f2c40b))
- **editor** — setNodeAttrs rewrites an element's attributes by node id ([`11dcd8f`](https://github.com/diaryx-org/twig/commit/11dcd8fad5518c30bb9ccafed7b4aa52bf8c2062))
- **splicer** — moveNode reorders a node next to another in one splice ([`00b08e6`](https://github.com/diaryx-org/twig/commit/00b08e62f6df38a56ba7d04768cdc07f7169e9c4))
- **format** — svg is a dialect row over xml ([`89581d8`](https://github.com/diaryx-org/twig/commit/89581d84fb35caff16ee10b745a46e5c1eba8fc3))

### Behavioural changes

- `Document.attrsSpan` on an XML element that has
  attributes now reports the start tag's interior after the name, where it
  reported `null`; through the C ABI, `twig_document_attrs_span` reports
  `ok` with that span where it reported `not_found`. An element without
  attributes still reports none.


## 3.8.0

### Added

- **c-abi** — reserve the runtime format range ([`79f45b7`](https://github.com/diaryx-org/twig/commit/79f45b7466203384df15361c69298cc9d1436d47))


## 3.7.0

### Added

- **editor** — join a block into the block before it, per format ([`3a5d769`](https://github.com/diaryx-org/twig/commit/3a5d76953f4f0bbece0d7478b3910cc12df94eff))

### Fixed

- **djot** — a section's span ends before the heading that closes it ([`5a1aa06`](https://github.com/diaryx-org/twig/commit/5a1aa068d21f0876dab1eb595a3fff8fa2096ebe))
- **editor** — joinBlocks refuses a gap it cannot see across, and A's tail carries only closing markup ([`5140ec2`](https://github.com/diaryx-org/twig/commit/5140ec2f56a640342d59070b0a70157034bb310a))

### Behavioural changes

- A djot `section`'s span now ends at its last child
  rather than at the end of the heading that closes it. For
  `"# H\n\npara\n\n# H2\n\nx\n"` the first section reported `0..16` —
  covering the second section's `# H2` heading, and overlapping that
  section's own `11..19` — and now reports `0..10`. The last section of
  a document, which is closed at end of input rather than by a heading,
  is unchanged, as is every `content_span`.


## 3.6.0

### Added

- **editor** — insert a leaf directive after the caret's block ([`309fcce`](https://github.com/diaryx-org/twig/commit/309fcceae113fa315431f9aae96ee09cc8815d39))
- **diagnostics** — a node's attributes are the second measured axis ([`1bc22e1`](https://github.com/diaryx-org/twig/commit/1bc22e1d1bcde6b3fd63c2a480d9083fb038deba))
- **markdown** — an attributed block is written inside a div, and a div or span as its tag ([`3a9e9a1`](https://github.com/diaryx-org/twig/commit/3a9e9a1811a3052cdcf8b3a0d778c3f139cf36a3))
- **markdown** — html_elements pairs a bare `<div>` with its </div> and a <span> with its </span> ([`e632cd6`](https://github.com/diaryx-org/twig/commit/e632cd61550af2aca5287afbab22a0143a627cb3))
- **editor** — replace a block's attributes, per format ([`6390255`](https://github.com/diaryx-org/twig/commit/639025537744cc79a914a215e3c665cc1f27ad04))
- **editor** — wrap a range in an attributed span, per format ([`e956f9f`](https://github.com/diaryx-org/twig/commit/e956f9fab7fd2bb4060524036d5e1dfdcbd86ff9))

### Fixed

- **djot** — a heading's attributes are written on the line before it, and a section's with them ([`581f147`](https://github.com/diaryx-org/twig/commit/581f14743ee66b14ee0610d54d717cd52f1c738c))
- **djot** — a reference definition's attributes are written on the line before it ([`a080d68`](https://github.com/diaryx-org/twig/commit/a080d68e8bc8d38c372e8d93b3504249aff0fb62))
- **asciidoc** — a table's title attribute is written as its .Title line ([`07cb03e`](https://github.com/diaryx-org/twig/commit/07cb03e754bd1d17749fb11f43664670c3eed452))

### Behavioural changes

- `twig convert --warn` and `twig_document_diagnostics`
now report a node whose attributes a target loses, where they reported
nothing. A C consumer switching on `TwigWarning.fidelity` sees codes 3 and
4 for these; the Rust binding's `Fidelity::from_c` maps an unknown code to
`Degraded`, so an older binding over a newer library reads them as that.

- converting to Markdown writes `<div …>` and `</div>`
lines, blank-separated, around any block that carries attributes, where it
wrote the block alone; a djot fenced div or an HTML `<div>` is written as
`<div>` … `</div>` where it was a `::: ` or `:::div` fence; a djot bracketed
span or an HTML `<span>` is written as `<span …>` … `</span>` where it was
its bare text or a `:span[…]` directive. `twig_document_diagnostics` reports
`TWIG_FIDELITY_ATTRS_DEGRADED` rather than `_DROPPED` for those blocks.

- under `ParseOptions.html_elements` (`TWIG_MD_HTML_ELEMENTS`,

- djot writes a converted heading's attributes as a
  `{…}` line ABOVE the `#` line instead of after its text. `## t{.x}` is
  now `{.x}\n## t`, which djot reads back as the heading's (or, when the
  block names an id, the section's) rather than as the text's.

- djot writes a section's attributes, on the line before
  its heading, minus an id equal to the one the parser derives from the
  title. `{#h .x}\n## t` round-tripped to `## t` and now to `{#h .x}\n## t`.

- djot writes a reference definition's attributes as a
  `{…}` line ABOVE the definition instead of after its destination.
  `[label]: /dest{.x}` is now `{.x}\n[label]: /dest`, which djot reads
  back as an attributed definition where before it read no definition.

- AsciiDoc writes a `title` attribute on a `table` as a
  `.Title` line above it, where it wrote nothing. A table carrying a
  non-empty caption is unchanged; the caption is the line.


## 3.5.2

### Fixed

- **editor** — a block inserted from a blank line takes that line, and adds no blank beside one ([`953fa2a`](https://github.com/diaryx-org/twig/commit/953fa2ac531a51e39a40254be6d67aced17abf34))

### Behavioural changes

- `insertThematicBreak` and `insertTable` with the caret
  on a blank line that no block owns now write the block at that line's
  start, with a blank line above only where the line above is not already
  blank. `"a\n\nb\n"` at offset 2 gave `"a\n\n\n---\n\nb\n"` and now gives
  `"a\n\n---\n\nb\n"`; `"\npara\n"` at 0 gave `"\n\n---\n\npara\n"` and now
  gives `"---\n\npara\n"`. A caret inside a block is placed as before.


## 3.5.1

### Fixed

- **editor** — a block inserted after an unterminated last line is still blank-separated ([`a08bcf3`](https://github.com/diaryx-org/twig/commit/a08bcf364387abef510fc9ae38d41b81baf2f6c7))

### Behavioural changes

- `insertThematicBreak` and `insertTable` after a last
  line with no trailing newline now write that newline before the blank
  line above the block. `"a"` + rule gave `"a\n---\n"` (a Markdown setext
  heading) and now gives `"a\n\n---\n"`; a document ending in a newline is
  unchanged.


## 3.5.0

### Added

- **html** — a raw-text or rcdata body is the container's payload, not a child ([`ec512b8`](https://github.com/diaryx-org/twig/commit/ec512b819038dbb5ed7aeb449ae8637b75c4dda0))
- **editor** — the container, code block, link and image gestures print through the renderer where the alphabet is null ([`9805a88`](https://github.com/diaryx-org/twig/commit/9805a8897e999084eb6d3f99fc6003858b104513))
- **editor** — insert a fresh table after the caret's block ([`7d35bfa`](https://github.com/diaryx-org/twig/commit/7d35bfab0ca076bb2a95d32b168becb492c09753))

### Fixed

- **serializer** — a quote's blank line between its blocks keeps its marker ([`66c48fb`](https://github.com/diaryx-org/twig/commit/66c48fb8bf2230ef81f0a9b20c3e7152e16f2868))

### Behavioural changes

- An HTML `container` from a raw-text element
  (`<script>`, `<style>`, `<iframe>`, …) or an rcdata one (`<title>`,
  `<textarea>`) — parsed directly or promoted under Markdown's
  `html_elements` — now carries its body as its own text payload and has
  NO children, where it held one `str` child. `TwigFlatNode.text` and
  the Rust `FlatNode::text` are set for such a node and `first_child` is
  none; `ast_json` emits `"text"` on it; `holdsOpaqueText` is true and
  `twig_editor_insert_child` refuses it. Every other container is
  unchanged.

- `twig convert -o markdown` / `-o djot` and the
canonical serializers spell the blank line between two blocks of one block
quote as `>` (with any enclosing prefix, trimmed) instead of an empty line,
so the output reparses to one quote as the input did.

- `Editor.supports` / `twig_format_supports` /


## 3.4.0

### Added

- **syntax** — fragment renderers on the format, where an alphabet cannot spell the edit ([`e15b9b9`](https://github.com/diaryx-org/twig/commit/e15b9b9d441d76f87a0830a6e68e7e99260d88f8))
- **format** — Markdown's dialects are Format rows, as json/jsonc/json5 are in fig ([`d574a45`](https://github.com/diaryx-org/twig/commit/d574a45c648eeef08f6803b9d5f0fa1ee944079c))

### Fixed

- **languages** — enforce per-format engine contracts ([`383dc68`](https://github.com/diaryx-org/twig/commit/383dc68bdce86670ff966461670f89c98646d4fc))
- **markdown** — a table cell spans from the pipe that opens it to the one that closes it ([`86bfd04`](https://github.com/diaryx-org/twig/commit/86bfd04b110d55dabaf254c6568f34b095880d21))
- **editor** — a toggle finds the mark a selection covers, not only one it equals ([`f09e951`](https://github.com/diaryx-org/twig/commit/f09e9517872ab32dc200b15cec64a49c40ef9e43))
- **editor** — an inline mark over a code span closes around its backticks ([`dde59e7`](https://github.com/diaryx-org/twig/commit/dde59e74a794de981278d26aebaaf7583ba13840))

### Changed

- **document** — references and footnotes become Document.labels ([`ba8930a`](https://github.com/diaryx-org/twig/commit/ba8930a0d3cb88342714e0fad1583d637f3e06df))

### Behavioural changes

- Djot documents without a final newline now borrow the
  caller's source instead of freed scanner storage. Their source spans stop
  at the original byte length rather than including a synthetic newline.

- Canonical Djot serialization no longer emits implicit
  heading references as explicit definitions, avoiding duplicate reference
  nodes on reparse. Bare-AST serialization still prints its references.

- Djot paragraph attributes serialize on the preceding
  line, preserving their block attachment instead of attaching to inline text.

- `Editor.insertLiteral` and `Editor.setBlock` succeed
  over an HTML document where they returned `error.UnsupportedFormat`; a
  literal is spelled with `&lt;`/`&gt;`/`&amp;`, and a heading or
  paragraph is rebuilt as the tag pair with the block's attributes
  along. `Editor.supports`, `twig_format_supports` and
  `Format::supports` answer true for `set_block` and `insert_literal` on
  HTML accordingly.

- `insertLiteral` inside a code span, code block, math
  span or raw node now writes the run as it is in Markdown, djot and
  AsciiDoc, where it used to backslash-escape and the backslash showed
  as text. `"a `cd` e"` with `*` inserted at 4 gives `` a `c*d` e ``
  rather than `` a `c\*d` e ``.

- a `Syntax` literal that states `text_escapes` must
  now set `renderText = renderTextByAlphabet`, and one with `renderText`
  set to anything else must leave the alphabets `null`;
  `assertCoherent` fails otherwise. `Syntax.authorable()` reads
  `renderText` where it read `text_escapes`.

- `twig convert`/`query`/`edit`/`filter` treat
  `--gfm` and `--commonmark` as `-i gfm` / `-i commonmark` rather than
  as a rewrite of the Markdown parse options. Two consequences: an
  extension flag before the dialect flag is kept (`--math --gfm` is GFM
  plus math, where it used to be plain GFM), and the flag overrides an
  extension-inferred or `-i`-given input format, so `-i djot --gfm`
  parses as GFM where `--gfm` was inert for a non-Markdown input.
  `identify` never accepted either flag and still does not.

- the Zig `format.ParseConfig.markdown` field is
  `Markdown.ParseOptions.Extensions` rather than `Markdown.ParseOptions`.
  A caller that set `.markdown = .commonmark` or `.gfm` names
  `Format.commonmark`/`Format.gfm` instead; one that set `.highlight`,
  `.math`, `.directives`, `.html_elements` or `.highlight_colors` is
  unchanged; one that turned a default-on extension off has no
  spelling for that now short of the `commonmark` row.

- `twig_parse`, `twig_editor_create`,
  `twig_document_serialize`, `twig_format_supports` and
  `twig_format_is_authorable` accept format codes 6 and 7, which they
  reported as `TWIG_STATUS_UNSUPPORTED_FORMAT`.

- A Markdown `cell`'s `span` is now its own extent — from
  the pipe that opens it to the pipe that closes it, exclusive — rather
  than the whole row's. In `"| a | b |\n|---|---|\n"` the header's first
  cell reported `0..9` and now reports `0..4` (`| a `), its second `0..9`
  and now `4..8` (`| b `). `content_span` is unchanged. `nodes_at` and
  `node_at` inside a multi-column row now descend into the cell holding the
  offset and on into its inline content, where they stopped at the row's
  last cell.

- `toggle_inline` over a range that covers a `kind`
  node's whole interior and lies within its span — the interior plus some
  or all of its delimiters — now removes that mark, where it wrapped the
  range in another pair. Over a node of another kind whose only child is
  a `kind` node filling its interior (`***word***` for `strong`, a
  paragraph that is one mark) it now removes the inner mark, where it
  wrapped again. Exact-span and exact-interior ranges behave as before.

- `toggle_inline` and `wrap_range` over a range that
  cuts into an inline code span (`verbatim`) or inline math now widen the
  range to the whole leaf and write the delimiters around its backticks —
  `` `word` `` with `word` selected becomes `` **`word`** `` — where they
  wrote them inside as literal text (`` `**word**` ``). The `Change`
  reported covers the widened range.


## 3.3.3

### Fixed

- **markdown** — a link reference definition's span is the bytes it was parsed from ([`dc0106f`](https://github.com/diaryx-org/twig/commit/dc0106f0dd3361b6a446269f4b96280a7cd4b71d))

### Behavioural changes

- A Markdown `reference` node (a link reference
  definition, `[label]: /url "title"`) now carries the span of its own
  source bytes, from the `[` to the end of the destination or the title,
  where it used to report `0..0`. `Document::definitions()` and every
  `FlatNode` for one reflect it. `content_span` stays unset.


## 3.3.2

### Fixed

- **editor** — an inline mark is cut at the block boundaries the selection crosses ([`8feafb0`](https://github.com/diaryx-org/twig/commit/8feafb03176cf32d0826e7927a2d09d3c80864f9))

### Behavioural changes

- An inline mark written across a block boundary is now one
  mark per block. `twig_editor_toggle_inline` / `wrap_range` over
  `"one two\n\nthree four"` wrote `**one two\n\nthree four**` (two paragraphs,
  four literal asterisks, no mark) and now writes
  `**one two**\n\n**three four**`. A second toggle over the result removes both
  marks; before, it wrapped the range again.

- A block's own marker is no longer swept into an inline
  mark. A range covering the whole of `"# Title"` wrote `**# Title**` — a bold
  paragraph, not a bold heading — and now writes `# **Title**`; the same holds
  for a list item's `- ` and a quoted paragraph's `> `. The mark now covers the
  block's `content_span` clipped to the range, not the range itself.

- A non-empty range with no inline content in it — one wholly
  inside a code fence — is now `TWIG_STATUS_NOT_EDITABLE` (`Error::NotEditable`)
  rather than a success that spliced delimiters into the fence body. A
  zero-width range is unaffected and still inserts an empty pair.


## 3.3.1

### Added

- **editor** — highlights and their colours are authorable, per parse config ([`c10f02d`](https://github.com/diaryx-org/twig/commit/c10f02de30f3adcce2623290a295ae5aac6a10c1))
- **editor** — GFM strikethrough is authorable, and the table set says which extensions decide ([`a2a4c5a`](https://github.com/diaryx-org/twig/commit/a2a4c5a746a9f9e01db25c4b308b0d7906df54f5))

### Behavioural changes

- A Markdown editor created with `TWIG_MD_HIGHLIGHT`
  (`MarkdownExtensions::highlight`) now authors highlights.
  `twig_editor_toggle_inline` / `_wrap_range` with `TWIG_INLINE_MARK` returned
  `TWIG_STATUS_UNSUPPORTED_FORMAT` for Markdown whatever the flags, and now
  succeeds when that flag is on — writing `==x==` and stripping it again.
  Without the flag it still refuses, and `twig_format_supports` (which answers
  for default options) still reports 0; ask `twig_format_supports_ext` with the
  editor's own flags.

- Markdown now authors GFM strikethrough.
  `twig_editor_toggle_inline` / `_wrap_range` with `TWIG_INLINE_DELETE`
  returned `TWIG_STATUS_UNSUPPORTED_FORMAT` for Markdown and now writes
  `~~x~~` — and strips it again — for any editor parsed with
  `ParseOptions.strikethrough` on, which is the default and is every editor the
  C ABI creates. `twig_format_supports(TWIG_FORMAT_MARKDOWN,
  TWIG_GESTURE_TOGGLE_INLINE, TWIG_INLINE_DELETE)` reported 0 and now reports 1.
  A Zig caller parsing with `ParseOptions.commonmark` (or `strikethrough =
  false`) still gets the refusal, since `~~x~~` is two literal tildes there.


## 3.3.0

### Added

- **markdown** — add the ==highlight== extension behind ParseOptions.highlight ([`5cb01e3`](https://github.com/diaryx-org/twig/commit/5cb01e3eee0bf4f182ac9a8e0fa027b23eb0b353))
- **markdown** — coloured highlights, ==🔴 text==, behind ParseOptions.highlight_colors ([`96d7234`](https://github.com/diaryx-org/twig/commit/96d7234d0aac888d89350e710c986a0789062fb3))
- **asciidoc** — the rest of the language, judged against the whole ASG schema ([`a9c3fb2`](https://github.com/diaryx-org/twig/commit/a9c3fb27c0745c414aa9577fdedb313dc3ca36f7))
- **asciidoc** — the serializer and the syntax table, so AsciiDoc is written and authored as well as read ([`e82d1d6`](https://github.com/diaryx-org/twig/commit/e82d1d6bf863da784ec2837c0daffb2d4a5e995a))

### Fixed

- **editor** — gate the table, split and renumber gestures on the format's spelling ([`6de1c4f`](https://github.com/diaryx-org/twig/commit/6de1c4f99385d513a2e120c41e7f93cc04829c67))
- **markdown** — match strikethrough on the emphasis delimiter stack so it nests ([`42f6471`](https://github.com/diaryx-org/twig/commit/42f6471921e00ff066bca9179b5f7980a7971839))

### Changed

- **build** — cut releases with the shared tooling, not a sixth copy ([`860cb13`](https://github.com/diaryx-org/twig/commit/860cb13a62c0486d7735d4491b82b72f805e5d97))
- **release** — take the shared cliff config, one style for every repo ([`6e57d98`](https://github.com/diaryx-org/twig/commit/6e57d986977b9080ffacc7b1433776fc8d0e2cca))

### Behavioural changes

- `zig build release`, `zig build changelog`,
  `zig build changelog-check`, and `zig build sync-version` no longer exist.
  Releasing is `release <command>` from diaryx-org/devtools, which must be on
  PATH; the changelog steps are `release changelog [--write|--check]`.
  `zig build check`, `test`, `sync-version-check`, and the build steps are
  unchanged.

- `scripts/sync-version.sh` with no argument was a write and
  is now an error naming `release bump`. `--check` and `--print` are unchanged;
  `--set` is gone.

- `tag_pattern` is anchored, `^v[0-9]`. A tag with a `v`
  somewhere in it no longer ends the unreleased range.

- The seven table gestures (`Editor.table*`,
  `twig_editor_table_edit`, `Editor::table_*` in Rust) now return
  `UnsupportedFormat` for a format with no pipe-table spelling — HTML, XML
  and AsciiDoc. They previously spliced GFM pipe text over the region the
  table occupied and returned success; over an HTML `<table>` that reparsed
  as a paragraph and destroyed the table. Ask
  `twig_format_supports`/`Format::supports` with the matching
  `TWIG_GESTURE_TABLE_*` code before offering the gesture.

- `Editor.splitBlock` / `twig_editor_split_block` now
  returns `UnsupportedFormat` for a format that does not separate blocks
  with a blank line (HTML, XML, AsciiDoc). It previously returned success
  having inserted whitespace that HTML reads as insignificant, leaving the
  document with the same one block it started with.

- `Editor.renumberOrderedLists` /
  `twig_editor_renumber_ordered_lists` now returns `UnsupportedFormat` for a
  format that does not spell an ordered item as a numbered line marker
  (HTML, XML, AsciiDoc). It previously returned success having changed
  nothing, since an `<ol>` carries its numbering in the tag.

- A table edit on a DJOT document now writes djot's own
  delimiter row rather than Markdown's. `| --- |` becomes `|---|` and
  `| :---: |` becomes `|:-:|`; data rows are unchanged. The old output was
  read back as an ordinary data row, so an edited djot table lost its header
  row. Markdown output is byte-for-byte unchanged.

- A Markdown `delete` node now nests correctly inside and
  around emphasis, links, and images. `*a ~~b~~ c*` used to yield an `emph`
  holding `"a "`, `"~~"`, `"b"` and lose the rest of the text; it now yields
  `emph[ "a ", delete["b"], " c" ]`. `~~a *b~~ c*` used to yield
  `delete[ "a ", emph["b~~ c*"] ]`; it now yields `delete["a *b"]` followed
  by literal ` c*`, matching cmark-gfm. Documents with no `~` inside or
  across an emphasis pair are unaffected.

- An AsciiDoc `++++` pass block is now a `raw_block`
  (format `html`) rather than a `code_block`, so its interior renders
  raw instead of as escaped code.

- An AsciiDoc list item whose marker differs from the
  current list's (`* one` then `- two`, or `. sub` under `* item`) now
  opens a NESTED list inside the item instead of a sibling list after it.

- AsciiDoc constructs that used to survive as literal
  paragraph text now parse into their own nodes: block metadata lines
  (`[source,ruby]`, `.Title`, `[[id]]`) attach to the block below them,
  `NOTE: ` paragraphs become a `note` container, indented paragraphs a
  `code_block`, `|===` a `table`, `> ` lines a `block_quote`, `---` a
  `thematic_break`, `term:: desc` a `definition_list`, ordered markers
  an `ordered_list`; and inline URLs, `<<xrefs>>`, macros, `{attrs}`,
  `&amp;`, `^sup^`, `(C)`, `--` and `...` are their own inline nodes.

- An AsciiDoc section or document title's text is now
  parsed for inline markup (`== A *bold* title` yields a `strong`) where
  it used to be one `str`; a `[[anchor]]` at the end of the title line
  becomes the section's `id` attribute rather than title text.

- The AsciiDoc `document-attributes` marker now also
  carries the author line's implicit attributes (`author`, `firstname`,
  `email`, `author_2`, …) and the revision line's (`revnumber`,
  `revdate`, `revremark`), and the header heading's span covers those
  lines.

- `twig convert -o asciidoc` and `-o canonical` on
  an AsciiDoc input now produce output; `twig_document_serialize`,
  `twig_builder_serialize` and the Rust `serialize_to` with the
  AsciiDoc target used to report `UNSUPPORTED_FORMAT` and now succeed.

- `twig_document_diagnostics` and the Rust
  `diagnostics` with the AsciiDoc target now return per-node warnings
  instead of `UNSUPPORTED_FORMAT`.

- `twig_format_is_authorable(TWIG_FORMAT_ASCIIDOC)`
  now reports 1, `twig_format_supports` answers per gesture, and every
  editor gesture but the link, image, footnote and table ones now
  edits an AsciiDoc document where all of them used to refuse.


## 3.2.1

### Added

- **djot** — record where a `{...}` attribute block was written ([`a2ff0b7`](https://github.com/diaryx-org/twig/commit/a2ff0b73c430d2bc78dcbb75c09e7e85a232dc90))
- **rust** — bind twig_document_attrs_span ([`c76924b`](https://github.com/diaryx-org/twig/commit/c76924b217dbc0aa2af898225b4f4c88847cc9f7))
- **build** — `zig build release`, the whole release as one command ([`13e552c`](https://github.com/diaryx-org/twig/commit/13e552c78680101865f2f1a0d0db545af867293b))

### Fixed

- **markdown** — a directive's label may hold another directive ([`b5ae4f1`](https://github.com/diaryx-org/twig/commit/b5ae4f116fb048a51488d563fc274cf4b359fe6b))
- **editor** — a deleted block takes its own attribute line with it ([`eecf11e`](https://github.com/diaryx-org/twig/commit/eecf11e7b321a15621192579cf62f6fbf010db35))

### Behavioural changes

- A Markdown text directive's `[label]` now accepts
  balanced nested brackets, so a directive, link, or image inside one
  parses as such. `:vis[a :vis[b]{.x} c]{.y}` used to yield an empty
  `:vis` container followed by `[a `, an inner `vis`, and ` c]{.y}` as
  text; it now yields one `vis` with `class="y"` holding the inner one.
  Leaf and container directives (`::name[...]`, `:::name[...]`) take the
  same labels — such a line used to parse as a paragraph.

- A Markdown text directive whose `[` never closes is no
  longer a directive at all. `:vis[a [b c]` used to produce a bare `vis`
  container followed by the bracket text; it now stays literal text with
  no container.

- Markdown text directives nest at most 32 deep. Past
  that the `:` is literal text rather than opening another directive.

- `twig_document_attrs_span` (and `Document.attrsSpan` /
  `attrsText`) now answer for djot documents, which always reported
  TWIG_STATUS_NOT_FOUND before. A node whose attributes came from one
  `{...}` block reports that block's range; a set merged from several
  blocks, or synthesized like a heading's generated id, still reports
  NOT_FOUND.

- `twig_editor_delete_smart` / `deleteNodeSmart` and
  `twig_editor_unwrap` / `unwrapNode` now also remove an attribute block
  written on its own line(s) above the node. Deleting the paragraph in
  `{.vis}⏎held back⏎` used to leave `{.vis}⏎` behind; it now leaves
  nothing. Attributes written inside the node's own span are unaffected.

## 3.2.0

### Added

- **editor** — a blank line is a place a container can open ([`40966b8`](https://github.com/diaryx-org/twig/commit/40966b819606396a26b5f929fcd6551e4e4a3a79))

### Fixed

- **markdown** — a block quote's span covers its own trailing marker lines ([`9707eb1`](https://github.com/diaryx-org/twig/commit/9707eb1e59f742b3462f9f987a0558f94dc7d30a))
- **markdown** — two spans that did not match what their block holds ([`5127041`](https://github.com/diaryx-org/twig/commit/512704191bc8c1eba158ac28723aa9c0a86daebc))

### Changed

- refactor(ci): make homebrew workflow depend on shared diaryx-org
homebrew workflow ([`44843ea`](https://github.com/diaryx-org/twig/commit/44843ea159fea80183b538c7b0e3e11bb9dfca7c))

### Behavioural changes

- A Markdown `block_quote`'s span now covers its own trailing
  marker lines. `"> a\n>\n> \n"` reported `0..3` and now reports `0..8` -- the
  lines spelled with the quote's own `>` used to belong to no node at all.
  `content_span` is unchanged and still stops at the last child (`0..3`), so the
  two report the marker lines and the blocks separately. Nested quotes each
  cover every line they match. djot already behaved this way. No HTML output
  changes.

- `Editor.toggleBlockContainer` on a blank line no longer
  fails. It used to answer `error.NoBlock` (`TWIG_STATUS_NOT_FOUND`) for a range
  covering no block; it now opens an empty container there, and the same button
  again takes it back off. A caller that treated `NOT_FOUND` as "nothing to do
  here" gets an edit instead. A caret INSIDE a leaf is unaffected -- a blank line
  in a fenced code block still resolves to the code block, and the gesture wraps
  the whole fence as before.

- A Markdown indented `code_block`'s span stops at its last
  content line. `"    code\n\n\n\nafter\n"` reported `0..10` for a block whose
  text was `"code\n"`, so `source[content_span]` and `text` disagreed about
  where the block ended; both now end at `0..8`. A blank line BETWEEN two
  indented lines is body text and still included. The overrun propagated through
  `containerSpanExtended`, so an enclosing list item was too long too.

- A Markdown `definition_list`'s span starts at its first term
  rather than the `:` line below it, so the list contains its own first child.
  `"Term\n: def"` reported the list as `5..10` around an item of `0..10`; it is
  now `0..10`. Deleting a one-item definition list used to leave `Term` behind.
  `content_span` was always right, so only the syntactic span moves.

## 3.1.0

### Added

- **html** — a Syntax table, and HTML stops being parse-only ([`c5c33a0`](https://github.com/diaryx-org/twig/commit/c5c33a0c00cecbec334701bebec001fa3a4df43b))
- **editor** — a per-gesture capability query, so a toolbar can gray out ([`e59d376`](https://github.com/diaryx-org/twig/commit/e59d3764016a78db239296853035d357879abe96))

### Fixed

- **djot** — a block's span stops at its own last line ([`f511641`](https://github.com/diaryx-org/twig/commit/f5116414802de43c18f85e1a5126c05e42a7d9ea))

### Behavioural changes

- **A djot block's span stops at its own last line.** A block-level container
  closes on the line that *stopped* it, and the span was taken from wherever
  the scan had reached by then — so it ran past the blank lines separating the
  block from its neighbour and into that neighbour's first byte. Reading a
  footnote definition's source back gave `"a note.\n\n["`; deleting a list
  followed by `[link]: /url` left `link]: /url` behind.

  Affects `footnote` and `reference` definitions, `block_quote`, `bullet_list`
  / `ordered_list` and `list_item`, `table`, `caption`, and an unterminated
  fenced div or code block. Spans now end after the block's own last line;
  blank lines *inside* a block (between a footnote's two paragraphs, say) are
  still interior and still included. No HTML output changes.

  One consequence for anyone diffing against djot.js: its `sourcepos` ends a
  list item on the *next* line's indentation (`1:2:1-2:1:5` for ` - a\n - b`),
  which Twig no longer reproduces — a span is what an edit splices, and that
  byte belongs to the next item's line.


## 3.0.0 — editor gestures, and telling consumers what a conversion costs

Major because the Rust binding's `kind` changes type. Twig has shipped
read-path breaks in a minor before — 2.8.0's four-kind collapse changed which
strings `kind` reports — but that was a change in a *value*, which a consumer
discovers at runtime. This one changes a *type*, so every downstream Rust crate
fails to compile until it is updated. That is the line between a minor and a
major, and 2.8.0 landing on the wrong side of it is most of why this file
exists.

### Added

- **Eight caret gestures**, each driven by `Syntax` spelling data rather than a
  format switch, and wired through the C ABI and both Rust crates:
  `insertThematicBreak`, `splitBlock`, `toggleCodeBlock`, `setCodeLanguage`,
  `toggleTaskItem`, `setTaskChecked`, `toggleTaskChecked`, `insertFootnote`.
  `toggleTaskItem` / `setTaskChecked` / `toggleTaskChecked` are what a rendered
  checkbox needs to become a clickable one.

  `Syntax` grows `thematic_break`, `code_fence`, `task_marker` and `footnote`;
  two error codes, `InvalidLanguage` and `InvalidLabel`, both mapping to
  `TWIG_STATUS_INVALID_ARGUMENT`.

  `insertThematicBreak` places the rule AFTER the caret's block, blank-separated
  — a rule is a block, so there is no spelling for one mid-paragraph, and the
  blank above is load-bearing rather than cosmetic (`---` flush under a
  paragraph is a setext `<h2>` that eats it). "The caret's block" is
  `locate.lineOwningBlock`, the child of the innermost container whose children
  each own their lines. That is what makes a caret in a CODE BLOCK or a TABLE
  anchor to the whole construct — after the closing fence, after the last row.
  The narrower `locate.innermostBlock` (`para`/`heading` only, which is all
  `setBlock` rewrites markers for) would report no block at all there, and the
  no-block fallback writes at the caret's line end: `---` inside the fence,
  where it is text and not a rule, or between a table's header and its
  delimiter row, which stops it being a table.

  `splitBlock` is the gesture `insertThematicBreak` deliberately is not: it
  divides a block AT the caret, both halves the same kind. A host whose rule
  button splits the paragraph composes the two rather than getting a second
  spelling of either. Nearly a pure insertion: only the separator is minted, and
  the only bytes removed are the second half's leading spaces, which are
  structure rather than content at a block's start. The separator is a blank line
  for a paragraph, the item's marker repeated for a list item (so
  `- this is |a list item` yields two items, a nested item's indent rides along
  so its sibling stays in its own list, and Enter at an item's end opens an empty
  one — including when a sibling follows, where Markdown's `list_item` span stops
  before its trailing newline and puts the caret in the gap between items), the
  heading's own marker at its own level, or a fence pair reproducing the opening
  line so width and info string survive. `NotEditable` for a table (a newline mid-cell
  destroys rather than divides; splitting one table into two has to decide what
  the second one's header is, which makes it a table gesture), a setext heading,
  and an indented code block. A paragraph is the one boundary case where the
  empty block cannot be spelled, since no format has an empty paragraph.

- **Conversion diagnostics, reachable from outside Zig.** `src/diagnostics.zig`
  answers "what would converting this document to that format silently lose?",
  and until now had no C ABI symbol, no Rust wrapper and no CLI flag — so every
  consumer that needed the answer was re-deriving it by heuristic against a
  library that already knew.
  - `twig_document_diagnostics(doc, format, &warnings, &len)` → one
    `TwigWarning` (`{fidelity, path, kind}`) per lossy node, in document order.
  - `Document::diagnostics(target) -> Vec<Warning>` in Rust, with a
    `#[non_exhaustive]` `Fidelity` (`Degraded` / `Dropped`).
  - `twig convert --warn` prints them to stderr, without changing stdout or the
    exit status.

  An empty result means the conversion is lossless. A target with no serializer
  at all (XML, AsciiDoc) reports `UNSUPPORTED_FORMAT` rather than a warning per
  node: that is a capability answer, not a diagnosis.

- **`container_origin`** — whether a generic container was written as a **tag**
  or as a **directive**. An HTML `<div>` and a Markdown `:::div` agree on
  `kind`, on `name` and on `directive_form`, field for field; nothing in the
  tree separated them, and the only way to ask was to re-read the source bytes
  under the node's span. `TwigFlatNode.container_origin` in C,
  `Node.origin: Option<ContainerOrigin>` in Rust.

  `directive_form` is *not* this field and never was: it is a spelling hint, and
  twig's HTML parser sets one on `<div>` and `<span>` because those are the two
  tags djot and Markdown have generic spellings for.

- **`twig_document_definitions` / `Document::definitions()` /
  `AST.definitionRoots`** — the document-level definitions, which hang off no
  parent and which a walk from the root therefore never reaches.

- **A typed `Kind` in the Rust binding**, replacing `kind: String` on
  `FlatNode`, `QueryMatch` and `Warning`. `#[non_exhaustive]`, with an
  `Other(String)` arm for a name a newer library hands an older binding.

- **`Format::Asciidoc` in the Rust binding.** The C ABI has had
  `TWIG_FORMAT_ASCIIDOC` since 2.8.0; only the Rust enum was missing it.

- `Document.containerOrigin(id)`, `Document::Spelling.container_origin`, and
  `KindRef.container_named` on the Zig side.

 **`marker_span` — the bytes a rich view hides.** A node's own leading marker:
  a heading's `#`s and the space after them, a list item's `- ` / `1. `, a task
  item's marker plus its `[x] ` box, a block quote's `> `. `TwigFlatNode
  .marker_span` / `.has_marker_span` in C, `Node.marker_span:
  Option<Range<usize>>` in Rust, `twig_document_node_marker_span` /
  `Document::marker_span` as accessors, and `Document.node_marker_spans` in Zig.

  It is not derivable from `span` and `content_span`. For a heading it happens
  to be `[span.start, content_span.start)`; for a marker-prefixed container it
  is not, because those report `content_span == span` — a prefix that repeats on
  every line has no contiguous interior to point at. The answer used to be
  recoverable only by a per-format rule (from the item's inner paragraph in
  Markdown, from the item itself in djot), which is the "which parser produced
  this?" reasoning a shared AST exists to remove.

- **`twig_document_line_prefix` / `Document::line_prefix`** — everything hidden
  before the content on the line an offset sits on, as one span from the line
  start. The assembled form of `marker_span`: `>   1. [ ] ` is four nodes'
  markers plus the indent between them, and reaching back to the line start is
  what picks up a nested item's indentation, which no node claims as its own
  marker. `NOT_FOUND` on a CONTINUATION line, where nothing opens — what such a
  line repeats is a different question, not answerable from marker spans.

- **`continuation_prefix` / `blank_line_prefix`** — what a line that opens
  NOTHING must carry: `twig_document_continuation_prefix` /
  `_blank_line_prefix` in C, `Document::continuation_prefix` /
  `blank_line_prefix` in Rust, `locate.continuationPrefix` /
  `blankLinePrefix` in Zig.

  The other half of `line_prefix`, and not derivable from it. That one reports
  the bytes ALREADY THERE on a line something opens, so it hands back a span;
  this one reports the bytes that would have to be WRITTEN on a line nothing
  opens — a list item's continuation is spaces where its marker was, which is
  not source at all. A quote's `> ` is reproduced (dropping it ends the quote);
  an item's marker becomes its width in spaces (repeating it opens a second
  item). Each container on the caret's chain contributes the columns its own
  marker occupies on its OWN opening line, which is why this walks the tree
  rather than re-reading one line.

  Both report a width in COLUMNS alongside the bytes, because the two differ:
  `-\tx` is a two-byte marker occupying four columns, and Tab's step, a caret's
  horizontal home and an outdent's width all want the column count.

- **`checked` on the flat node** — a task item's checkbox state, `None` /
  `TWIG_TASK_CHECKED_NONE` for every other kind. The parser has always known it
  (it is what decides `task_list_item` over `list_item`), and nothing surfaced
  it, so a consumer rendering a clickable checkbox re-derived the state by
  scanning for `[x]` — a scan a `[` in prose can fool. Twig would write a
  checkbox and not read one back.

- **Caret-flavoured hit-testing** — `twig_document_node_at_caret` /
  `_nodes_at_caret`, `Document::node_at_caret` / `ancestors_at_caret`,
  `locate.deepestContainingForCaret` / `caretChain` in Zig. The same descent
  under the containment rule an editing caret needs: a block's END is inside it,
  and a trailing newline is not part of the block.

  The second half is what makes the two authorable formats agree. Djot ends a
  paragraph's span AFTER its newline and Markdown BEFORE it, so on `"a\n\nb\n"`
  a caret at offset 1 — the position pressing End on line one gives you — read
  as `para` through djot and `doc` through Markdown. Same caret, two answers,
  decided by which parser happened to produce the tree.

  `spanContains` and `twig_document_node_at` are unchanged: half-open
  containment is right for a byte range, and making it end-inclusive would make
  an inline mark sticky at the offset where you type to escape it.

  These are document reads, not editor reads, so there is no `twig_editor_*`
  alias — an editor reaches them through `twig_editor_document` /
  `Editor::document()`. See DESIGN.md, "The reads are not editor-specific."

### Behavioural changes

The first four change bytes that existing code may be matching on. All four are
bug fixes, and all four are listed for the reason this section exists: the
previous output being wrong does not make the new output a non-event for
someone who had worked around it.

- **A header-less table converted to Markdown now round-trips.** It previously
  emitted no delimiter row — `| a | b |`, which reparses as a *paragraph*, with
  every cell boundary gone. It now gets a synthesized empty header row above it,
  so the output is three lines where it was one. Reported as `degraded` by the
  new diagnostics.

- **An unclassified container converted to Markdown is written as a tag, not a
  directive.** An HTML `<my-widget>y</my-widget>` inline used to come out as
  `:my-widget[y]` — invented syntax that reparses as a directive with the
  extension on, and as literal text without it. It now passes through as
  `<my-widget>y</my-widget>`.

- **An unclassified container converted to Markdown keeps its attributes.**
  `<video controls src="a.mp4">` used to be written as a bare `<video>`.

- **A djot div's attributes are written on the line above the fence.**
  `::: {#i .c}` is not djot — the brace block never parses as attributes and the
  whole construct reparses as a paragraph, so `-o canonical` did not round-trip
  *any* div carrying attributes. Djot output for such a div gains a line.

  Related, same commit: djot's container arms ignored a container's `name`, so a
  Markdown `:::note` arrived as a bare `:::`. The name now rides as a class
  (`::: note`), which is where djot holds a container's identity.

- **`diagnostics.fidelity` now answers per node, not only per kind.**
  `nodeFidelity` refines the table's answer with what only a node can say, so a
  header-less table and a table with a header get different answers. Any code
  reading `fidelity` directly should read `nodeFidelity`.

- **`renumberOrderedLists` no longer rewrites a digit the author wrote as
  prose.** It was a purely textual line pass, so any line that *looked* like
  `N. ` was renumbered. Which lines are items is now taken from the tree; only
  their nesting level still comes from the marker's column. The visible case is
  djot, where a list marker cannot interrupt a paragraph: in `1. a\n   2. b` the
  second line is text inside item `a`, and the gesture used to rewrite the `2.`
  in it. Markdown reads the same bytes as a nested item and still renumbers
  them. A numbered line inside an indented code block is likewise left alone in
  both formats.

- **A djot `block_quote` / `list_item` / `task_list_item` /
  `definition_list_item` / `definition` / `footnote` now reports
  `content_span == span`**, where it previously reported the extent of its
  children. Markdown already reported the whole extent, so this is the two
  parsers agreeing rather than diverging.

  The old value was wrong, not merely different. `content_span` is defined as
  *the region an editor may splice*, and these containers hold their children
  behind a per-line prefix — `> ` on every line of a quote, the marker's width
  of indent on every line of an item. A range from the first child to the last
  peels that prefix off the FIRST line only and leaves it on every other, so the
  bytes it addressed were not a valid interior. `twig_editor_unwrap` spliced
  them in, which turned

      > a          into      a
      > b                    > b

  — one quote becoming a paragraph and a quote, a node count that went UP on an
  operation that removes a wrapper. `twig_editor_replace_content` had the same
  defect for the same reason. Both are now no-ops on such a container, matching
  Markdown's long-standing (and documented) behaviour.

  "Where does the content start" did not go away; it moved to `marker_span`,
  which answers it for one line — the only scale at which it has an answer.

- **`set_block` on a BLANK LINE now opens a heading instead of returning
  `NOT_FOUND`.** There is no node there to convert — no format spells an empty
  paragraph — so a caller wanting "H2, then type" from an empty line had to
  spell `#` itself, and spell it per format.

  The marker is blank-separated from whatever precedes it, which is correctness
  rather than tidiness: djot does not let a heading interrupt a paragraph, so a
  `## ` written on the line directly under one is read there as that paragraph's
  own text — the document gains no heading and `##` shows up literally, while
  Markdown reads the same bytes as a heading. It also carries the line's quote
  markers, re-emitted with the space after the last `>` that a blank quoted line
  does not have, because `>#` is a quoted heading in Markdown and a paragraph in
  djot. Both are the argument `insertThematicBreak` already makes for a rule.

  `NOT_EDITABLE` when the blank line is interior to a block rather than between
  blocks — inside a fenced code block or a table — where a marker would add no
  heading and corrupt what is there. `BlockKind::Paragraph` on a blank line is a
  no-op: the state asked for is the state it is in.

- **`renumberOrderedLists` now works inside a block quote.** It previously
  reported success at every offset in `> 1. a\n> 2. b\n> 2. c` and changed
  nothing: the marker scan started at column zero, found `>` where it wanted a
  digit, and copied the whole region verbatim. The scan now skips the quote
  prefix first, and measures nesting indent from after it — a quote's width is
  not a list's depth, and counting it opened a phantom level whose siblings
  never resumed.

- **`TWIG_ABI_VERSION` is 6.** `TwigFlatNode` grew `marker_span` /
  `has_marker_span` (144 → 168 bytes) and `checked` (free, in the tail padding).
  Every prior field keeps its offset; `@sizeOf` is what moved, and it is part of
  the layout a consumer strides an array with.

### Breaking

- **`TWIG_ABI_VERSION` 4 → 5.** `TwigFlatNode` gained `container_origin` in what
  was `directive_form`'s tail padding: `sizeof` is still 144 and *every prior
  offset is unchanged*, so a version-4 consumer linked against this library is
  bit-for-bit correct and needs no rebuild. The bump is for the other direction —
  a version-5 consumer against an older library would read uninitialized
  padding, and `twig_abi_version()` is the only way to catch that.

- **Rust: `kind` is a `Kind`, not a `String`.** Every `node.kind == "image"`
  becomes `node.kind == Kind::Image`. There is deliberately no
  `PartialEq<&str>`: it would keep those comparisons compiling, which is exactly
  the silence this change removes. Use `Kind::as_str()` where the name is
  genuinely what you want.

- **Rust: `Format` is `#[non_exhaustive]` and gained `Asciidoc`.** Matches on it
  need a `_` arm. `Target` gained `Asciidoc` too (it was already
  `#[non_exhaustive]`); serializing to it reports `UnsupportedFormat`.

- **Zig: `Kind.kindName` returns `[:0]const u8`.** Every arm was already a
  `@tagName` literal; the type was throwing the guarantee away.

- **Rust: `Error` is `#[non_exhaustive]`**

### Fixed

- `twig.h` and `c_abi.zig` told C consumers that `kind` reports
  `"element"`/`"directive"`. It has reported `"container"` since 2.8.0's
  four-kind collapse.
- `twig.h` said "the root is the node whose parent == `TWIG_NO_NODE`" — singular
  — on both `twig_document_nodes` and `twig_editor_nodes`. Several nodes can be
  parentless; see `twig_document_definitions`.
- `Kind.Container.name`'s doc comment claimed the name is never empty and that
  djot's anonymous `:::` carries `"div"`. Djot leaves it empty, deliberately.
- The C header test now prints both versions when they disagree, instead of only
  that they did.
- `twig.h` documented `TWIG_STATUS_INVALID_DESTINATION`, which has never been
  in the enum. `insert_link` / `insert_image` return
  `TWIG_STATUS_INVALID_ARGUMENT` in that position.

## 2.8.0 — AST slimming, AsciiDoc and rST parsers, the diagnostic layer

### Added

- An AsciiDoc parser covering a slice of the language — header, paragraphs,
  sections, lists, delimited blocks, and the inline spans — reachable as
  `TWIG_FORMAT_ASCIIDOC` (5). It parses and renders; it does not serialize.
- A reStructuredText parser (bullet, enumerated, definition, field and option
  lists; line blocks; tables with a column axis; the citation and substitution
  namespaces; Tier A parse diagnostics). Not yet registered as an input format
  — there is no `Format.rst`, so it is not reachable from the CLI or the C ABI.
- `src/diagnostics.zig`: a read-only pass reporting what serializing a given
  AST to a given target would silently lose. Zig-library only in this release.
- The document tree read surface on the C ABI, for parse-only consumers:
  `twig_document_nodes` / `_children` / `_subtree` / `_node_at` / `_nodes_at`,
  and `twig_editor_document` to borrow an editor's live tree.
- Document span accessors, and recorded source spans for attribute blocks.
- Table cell spanning (`colspan` / `rowspan`), and a table column axis
  (`TWIG_KIND_COLUMN`).
- List spelling (bullet character, ordered delimiter) recorded per node in
  `Document.node_spelling`.

### Behavioural changes

- **The four generic container kinds collapsed into one.** `div`, `span`,
  `directive` and `element` became a single `container` kind carrying
  `{name, form, argument}`. The break is on the **read path only**:
  `TwigFlatNode.kind` and `-o ast` JSON now report `"container"` everywhere
  they previously reported one of the four names. Every input code still
  works — `TWIG_KIND_DIV` / `TWIG_KIND_SPAN` build the anonymous container, and
  `twig_builder_add_directive` / `_add_element` construct the trees they always
  did — and struct layouts are unchanged, so `TWIG_ABI_VERSION` stays at 4.

  Selectors accept `container`, `element` and `directive` as names for the one
  kind, so existing selector strings keep matching.

- **Node spans moved out of the AST** into `Document`'s id-indexed side tables.
  This is a Zig API change only; the C ABI still exposes spans on its node
  structs, filled from the side tables.

## 2.7.2

Maintenance release.

## 2.7.1

### Added

- WASI support.

## 2.7.0 — Djot tables and raw content survive serialization
