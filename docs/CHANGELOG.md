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
