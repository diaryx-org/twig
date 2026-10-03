---
title: "Proposal: runtime languages"
status: accepted
author: adammharris
created: 2026-09-19
updated: 2026-10-02
part_of: '[Proposals](/docs/proposals/proposals.md)'
---

# Runtime languages

## Status

`accepted` on 2026-09-19, on the decisions below: twig carries its format
contract two ways — a table of function pointers in-process and a helper
protocol out-of-process — and links no engine; the compiled formats cross
the contract before the first outside format does; the CLI discovers helpers
without a dependency on fig; the first engine is `twig-quickjs`, a separate
repository over the Rust crate. The one thing cheaper now than later — the
reserved range of format codes — landed beside this document, in
`add(c-abi): reserve the runtime format range`. The build is sequenced at
the end, and closes
[the task that asked for this decision](/docs/tasks/closed/runtime-languages.md).

**2026-09-23: the author tier waits on groundwork, and the groundwork is
done.** Steps 2–4 shipped the read and write tiers and refuse `author` by
name, because nothing yet made a `Syntax` twig had never seen safe to edit
with: every compiled table's safety came from debug asserts, from being Zig
rather than data, from test-only checks, and from bugs found by hand. Five
pieces of groundwork replace those, and each is in:

1. `Syntax.validate` names the rule a table breaks
   (`add(syntax): Syntax.validate names the rule…`); compiled tables are
   checked at comptime.
2. `Syntax` crosses as JSON, every compiled table round-tripping, with
   `twig lang syntax <format>` as the oracle
   (`add(syntax): Syntax as JSON…`).
3. The harness is `contract.zig`, checks that report, run by the harness and
   at registration (`add(contract): the engine contract as a library…`).
4. `contract.gestures` runs every supported gesture everywhere it applies
   and holds each to a clean refusal or the promised shape with nothing else
   changed (`add(contract): every gesture, everywhere…`). It found four bugs
   in the compiled formats, fixed in `fix(markdown)` and `fix(editor)` beside
   it, and one filed as
   [a task](/docs/tasks/asciidoc-admonition-label-gestures.md).
5. The line model is written down in `syntax.zig`'s module doc, and
   `validate` enforces the parts that are facts about a table's bytes.

What is left for the author tier is the carrier's half: a `syntax` in the
description decoded and bound, the renderers as a `render` op on the wire
and slots in `TwigLanguageVTable`, and the refusal lifted — registration
already runs `contract.all`, which applies the gesture check to any row that
authors.

**2026-10-02: the author tier is in, with features and sets in place of
dialects** (`add(runtime)!: the author tier, with features and sets`). A
description's `syntax` is decoded and bound, the renderers it names are a
`render` op on the wire and one slot in the vtable, and the refusal is
lifted. Where it differs from the text below:

- **Features and sets, not dialects.** A language declares *features* —
  switches its parser reads, as Markdown's extensions are, each optionally
  requiring others — and *sets*, each a name for a list of them. The
  language's own row has its `default` features on; each set is a row of
  its own (`dialect_of` the language's), as `gfm` is a row over Markdown.
  A caller lays more features over any row through
  `ParseConfig.features` — the same flags argument that carries
  `TWIG_MD_*` for a Markdown row — and can only turn features on: off is
  another row. Every call names its row and the features in force. A
  `dialects` key is refused, pointing at `sets`.
- **A feature patches the table.** A language's `syntax` is the base; a
  feature's `syntax` is a partial table whose members replace the base's
  while it is on — per key in the three keyed tables, whole elsewhere — and
  no two features may patch the same one, so order cannot matter. The table
  for a combination is built on first use, validated, and kept; one that
  breaks a rule spells nothing and says why.
- **Load checks combinations, not only rows.** The whole contract runs
  under every row's own features, each with one feature more, and with all
  of them on; a sample may name the features it needs. Running it so found
  a bug in the compiled Markdown that the default-options harness never
  reaches, filed as
  [a task](/docs/tasks/closed/markdown-set-block-multi-line-paragraph.md).
- **One `render` slot.** The vtable is version 2: its functions take a call
  record (row, feature mask, input), and one `render` function takes the
  wire's render request as JSON — `render_text`, `render_block`,
  `spells_autolink` — so a renderer added later is a new `which`, not a new
  layout. A version-1 table is still read, as a language that reads and
  writes. `renderBlockVia(print)` is opted into rather than given: a
  language that names `render_block` and has no `render` prints its
  fragments, and one that does not name it has none — the load check
  refused the first language whose print writes less than every fragment a
  gesture builds, with no way for it to decline.
- **Every renderer is handed its table.** `renderBlock` and
  `spellsAutolink` now take the `*const Syntax` they were found in, as
  `renderText` did, and `Syntax.renderer_context` is how a runtime table's
  renderers find their language and features; `renderText` may fail, as a
  call into a language can.
- **The answering end through the C ABI.** `twig_server_create` and
  `twig_server_handle` serve a host's table over the wire, and the Rust
  crate's `Server` and `serve` are built on them — the `serve` step 5 needs
  from this crate.

Since: compiled Markdown's opt-in extensions are features of its three
rows (`twig.format.features`), by the names of their `TWIG_MD_*` bits, so
`twig_format_feature_bit` and the Rust crate's `feature_flags` answer for
both kinds of row, and `highlight_colors` requires `highlight` where the
flags are read rather than only on the command line. The CLI lays a
feature over any row with `--feature`, `lang list` shows each language's
features, and a set's name or extension resolves before its language has
loaded — the helpers are asked in turn, one whose name begins the set's
first. `twig_format_dialect_of` gives a set's language.

"Runtime" throughout means *resolved when the program runs*, as opposed to a
format compiled into `src/languages/`. It names no engine.

## The question

Fig's 3.0 restated its `Language` contract as values — a flat node table
with spans and declared side columns, a `syntax` record, fragment renderers
— and carried it two ways: a vtable in-process, a JSON protocol to a helper
process. The engines are their own repositories and core links none of
them. The task asked whether twig should do the same, and named the three
things that made it a decision rather than a build:

- whether twig's parse result has a shape that can be written down;
- whether the `render` half — a runtime format spelling a heading, a quote,
  a literal — is tractable over a wire at document granularity;
- whether any document format is worth a helper process, given that
  document formats are fewer than config formats and each is larger.

The first two have answers in the code as it stands. The third is the
argument, and it turns on where twig runs.

## Where twig stands

Twig is nearer the in-process carrier than fig was, because the shape fig
had to *arrive at* is the shape twig's registry took from the start.

**The contract is already values.** `src/format.zig`'s `Entry` is a struct
of function pointers — `parse`, `parseToAst` (which is `Splicer.ParseFn`,
the reparse the editor calls after every splice), `renderHtml`,
`serializeCanonical` — beside a `*const Syntax`, and `TargetEntry` carries
`serializeFromAst` the same way. `Syntax` is inert bytes plus three
function-valued fields dispatched by presence: `renderText`, `renderBlock`,
`spellsAutolink`. `ast/editor.zig` takes a `ParseFn` and a `*const Syntax`
and never learns which format it is editing; the harness constructs an
`Editor` over every row from exactly those two. Fig's contract was comptime
declarations that `Language.validate` checked; twig's is a row that a
runtime value could fill today. What stands between the two is the
exhaustive `Format` enum and the comptime `registry` array — a lookup, not
a refactor.

**The node table exists twice.** `ast/json.zig` emits every node as `kind`,
`span`, `content_span`, `marker_span`, the kind's own payload fields
(`writeKindPayload` switches exhaustively over `Kind`, so a new kind fails
its build until it is given fields), `attrs` and `children`. The C ABI's
`TwigFlatNode` is the same information flat — `parent`, `first_child`,
`next_sibling`, the spans, `level`, `kind` by published name, `text`,
`destination`, `head`, `alignment`, `name`, `attrs`, `directive_form`,
`container_origin`, `checked` — and is what `twig_document_nodes` hands a
renderer that would rather not parse JSON. Against `src/document.zig`'s
columns, both are missing two: `node_spelling` (a bullet's character, an
ordered list's punctuation) and `attrs_spans`. `labels` is the third
column and is not missing, because it is an index — `Labels.index` rebuilds
it from a bare tree, up to the parser's say on which of two same-labelled
definitions wins.

**The harness is the load-time check.** `languages/harness.zig` runs, over
every registry row: each declared sample parses; where the row serializes,
the print reparses to an equal tree under `AST.eql`; where the row is
authorable, an `Editor` constructs and a zero-length splice is the identity;
every column is well-formed (spans inside the source, markers only on the
kinds that carry them, attrs spans only where attrs exist); a specials run
through `renderText` reparses to itself with nothing minted; a heading, a
quote, a list, a code block, a link and an image printed through
`renderBlock` each reparse to their kind. A format with no samples is a test
failure. That list is fig's §6 almost line for line, and it was written for
this purpose: the three tasks filed with this one were sequenced ahead of it
so that the node table would have a shape and the engine's assumptions would
be stated somewhere a runtime format could be held to.

**The ABI addresses formats by a frozen integer.** `TwigFormat` is seven
codes, `intToFormat` switches on them exhaustively, and
`twig_format_supports(format, gesture, kind)` is a pure function of the code
so a toolbar can be built before a document exists. The Rust `Format` is
already `#[non_exhaustive]`, with its doc comment saying why: the list
grows, and a caller should not have to recompile to keep compiling.

**Where twig runs.** Leaf reaches twig through the `twig-doc` crate, in
process, on every host it has — the terminal, gpui, iOS through UniFFI, and
the browser through `wasm-bindgen`. The CLI runs `twig convert` once per
invocation. Nothing consumes twig through a `twig` npm package yet;
`build.zig`'s wasm step says it is for "future JS/TS bindings".

## The answers to the three questions

**The table can be written down.** It is `TwigFlatNode` plus the two
columns above, with the payload fields `ast_json` already names per kind.
The vocabulary is closed — sixty published kind names, projected from the
`Kind` tags and their three families — and a runtime format cannot add one,
exactly as a fig format cannot add an `ExtKind`. That is less of a limit
than it sounds:
`container{name, form, argument}` is the generic escape every markup twig
has met so far has fit into, and rST's `citation` and `substitution` were
added compiled because they changed what the *engine* had to know, which no
runtime format could do anyway.

**The render half is tractable, because it is already three string
functions.** `renderText(text, position)` is text in, text out; the editor
computes the position (inline, block start, verbatim) and slices the run so
no format re-derives where a line starts. `renderBlock(fragment)` is a
print of a table whose root is not `doc` — of the four compiled formats
that declare it, three declare it as `renderBlockVia(serializeAstAlloc)`,
so a runtime format that declares `print` has `renderBlock` for nothing.
`spellsAutolink` is bytes in, a boolean out. None receives the editor,
performs a splice, or is called more than once per gesture, and the harness
holds each to a reparse. The task's worry was that a wire could not carry
"spell a heading" at document granularity; it does not have to, because the
engine builds the node and the format prints the fragment, which is what
`setBlock` over HTML does today. Fig's renderers reduced twenty-five hooks
to five string functions; twig's were three string functions before the
question was asked.

**Whether a format is worth a process depends on which process.** This is
where twig differs from fig, and the difference decides the design rather
than the verdict.

Fig's helper is spawned once per `fig` command, and the ~6 ms it costs is
spent against a file whose point is to be small. Twig's editor reparses
after every splice: over a helper, that is a process round-trip and the
whole document's table as JSON *per keystroke*, on top of the parse. For
`twig convert` and `twig query` the cost is fig's and is nothing. For leaf
it is the wrong carrier twice over — the duty cycle is per edit, not per
invocation, and two of leaf's four hosts cannot spawn a process at all.

So the two carriers serve two consumers, and the proposal says so rather
than pretending one wire fits both:

- The **helper protocol** serves the CLI and anything else that runs one
  command per process: `twig convert -i org`, `twig query`, `-o table`, a
  CI check, an import into a vault.
- The **in-process vtable** serves an editor. A Rust `Language` — over an
  existing Rust parser, or over `twig-quickjs` linked as a crate the way
  `fig-quickjs` is `register_file`d — costs a table conversion per edit and
  no process. What that conversion costs at leaf's keystroke rate is
  measured before a runtime format is offered to an editor (sequence step
  6), and the number decides whether the table crosses as JSON or as typed
  arrays, which is the optimization fig deferred for the same reason.

That is the honest limit of the design: an editor over a runtime format is
slower than over a compiled one by the conversion, and the CLI over a
runtime format is slower by a spawn. Neither is a reason not to have the
contract; both are reasons to state which carrier a consumer gets.

## Why twig, when document formats are few

The task's "why it might not" is that document parsers are large. They are:

| language | lines of Zig |
|---|---|
| markdown | 13,790 |
| asciidoc | 7,662 |
| djot | 7,259 |
| rst (in progress) | 5,951 |
| html | 3,386 |
| xml | 1,164 |

Fig found a script twin runs about half the lines of the Zig. A wiki
dialect at two or three thousand lines of JavaScript is a weekend for
someone who is not twig's maintainer — and that is the point. The tail is
real and it is not twig's to compile: Org, Typst's markup, Textile,
MediaWiki, Creole, Pod, the man macros, Obsidian's callouts over Markdown,
and every house format a vault imports from. Today the only path for any of
them is a pull request into `src/languages/`, a Zig toolchain, and a release,
and none of them is worth that to twig while every one of them is worth an
afternoon to whoever has the files.

Three consumers are closer than the tail:

- **The twig-native language.** [That proposal](twig-native-language.md) is
  deferred on sequencing: a published surface syntax cannot be walked back,
  so it waits for the AST to be pressure-tested. A script is the way to
  try a surface syntax without publishing it — prototype the grammar as a
  module, iterate it against the harness and the fuzz properties of its
  Part 9, hand it to leaf under a flag, and compile it into `src/languages/`
  once it settles. Its `Syntax` table and escape alphabets are data either
  way, and Part 10's plan (copy djot and delete) stays the plan for the
  compiled version.
- **Existing Rust parsers.** A Rust `Language` over `orgize` or
  `typst-syntax` is a read-tier format in an afternoon, with no engine and
  no wire: parse, map the tree to the table, keep the spans. That is the
  in-process carrier's own use, and leaf can open the result read-only
  wherever it runs.
- **A twin as the conformance oracle.** djot.js is a small ES module whose
  parse tree carries source positions. A `djot.mjs` over it is a twin of
  twig's richest compiled format at a fraction of the cost fig paid for its
  twins, and holding it to the compiled tables — every row, span and payload
  — is the proof that the contract is complete, which is the proof fig
  waited for before tagging.

## The contract

What a compiled row declares, restated as values. One new part, the node
table, because the parse result crosses a boundary; nothing changed in the
editing surface, because twig's renderers were already the shape fig's hooks
had to be reduced to.

### The node table

A parse returns rows in pre-order, row index being node id. A print takes
the same rows without spans — a bare `AST` — and returns bytes.

| Column | Meaning |
|---|---|
| `kind` | The published name (`Kind.kindName`): `"heading"`, `"emph"`, `"str"`… the vocabulary `ast_json` and `twig_node_kind_name` share. |
| `parent` | Row index, or none for the root. Core rebuilds `first_child`/`next_sibling`. |
| `span` | `[start, end)` bytes into the input. Required of every node; the editor splices by it. |
| `content_span` | The interior, or none — the meaning `Document.node_content_spans` gives it, self-closing signal for XML included. |
| `marker_span` | The leading bytes a rich view hides, on the kinds `harness.zig` allows one on, or none. |
| payload | The kind's own fields, as `writeKindPayload` names them: `level`; `text` and `lang`; `destination` and `reference`; `numbering`, `start`, `tight`; `checked`; `head`, `alignment`; `name`, `form`, `argument`; `indent`; and so on. That switch is the specification: a runtime row for a kind carries the fields the JSON encoder writes for it, and the decoder is written against the same switch, so a new kind fails both until it is mapped. |
| `attrs` | Ordered `(key, value)` pairs, `value` optional, `class` accumulating at its first occurrence — `Attrs` as it stands. |
| `attrs_span` | Where the `{…}` was written, or none — `Document.attrs_spans`. |
| `spelling` | A bullet's character, an ordered list's punctuation, or none — `Document.node_spelling`. |

One optional side table: `labels`, `(label, node, reference | footnote)`, for
a parser that wants its say on which of two same-labelled definitions wins.
Absent, core indexes the tree with `Labels.index`, which is what a bare
`AST` gets today.

`ast_json` stays what it is — nested, for a human diffing two parses. The
flat table is a second encoding of the same rows, and `twig lang table
<file>` prints it for a compiled format so a twin has an oracle to be held
to, which is how fig's twins were written.

### The declarations

- `name`, `extensions`, `aliases`; `dialects` as rows, each a name and its
  own `syntax` where it differs, the way `commonmark` and `gfm` are rows
  over Markdown's parser — a runtime language's `parse` and `print` take the
  row's name.
- `caps`: `read`, `write`, `author`. Read is `parse`; write adds `print`;
  author adds `syntax` and whichever renderers the table needs. The tiers
  are fig's, and `author` is finer than a boolean because `Syntax` is: the
  table itself says which gestures may mint, and `Editor.supports` and
  `twig_format_supports` read it for a runtime row exactly as for a compiled
  one.
- `syntax`: the seventeen fields of `Syntax` as data — the `Delims` per
  inline kind with their `authorable` flag, the container spellings, the
  heading marker, the escape alphabets, `cell_line_break`, the rest — with
  enums by name and absent optionals as `null`, plus the list of renderers
  the format answers.
- `samples`, required. A compiled format has a test suite beside it; a
  runtime one has only what it declares, and the harness is the whole of
  what holds it.

Not declared, because core supplies it: `renderHtml`. A runtime format
renders through the shared printer, `Html.serialize` over its table with
core's indexed `labels` passed as the context — the path every compiled
format but djot and Markdown takes, and those two only because they number
footnotes at render time against a table core now owns.

### The renderers over a wire

| Renderer | Signature | Who calls it |
|---|---|---|
| `renderText` | `(text, position) -> text` | `insertLiteral`, with `position` one of `inline_text`, `block_start`, `verbatim` |
| `renderBlock` | `(fragment table) -> text` | `setBlock` and the container, code block, link and image gestures where the alphabet is null |
| `spellsAutolink` | `(bytes) -> bool` | the autolink gesture |

A runtime format that declares `print` and no `renderBlock` gets
`renderBlockVia(print)`, as three compiled formats do. A format whose
literal spelling is a backslash before a byte declares `text_escapes` and
names no `renderText`; core's `renderTextByAlphabet` is what it gets, which
is what `assertCoherent` already pins. HTML's entity renderer is the case
that has to be a function, and a wire carries it as one.

### The two carriers

**In-process.** `TwigLanguageVTable`: a `version` first, the declarations as
fields, and function pointers — `parse` (input and dialect to table),
`print` (table and dialect to bytes), `free` for what those allocated,
`describe`, and one nullable slot per renderer.
`twig_language_register(const TwigLanguageVTable *, int *out_format)`,
one call per dialect row, returns a code at or above
`TWIG_FORMAT_RUNTIME_BASE`; `twig_format_by_name` resolves a name to a code.
The Rust crate exposes the same as `trait Language` and `register`, and
`Format` gains `Runtime(RuntimeId)` under its `#[non_exhaustive]`. In Zig, a
`Runtime` entry whose functions forward to the vtable at its id, so `Editor`
instantiates once over it and the C ABI's editor gains one arm. The
vtable's `version` is bumped on the rule `TWIG_ABI_VERSION` follows: only
when a field changes meaning.

**Out-of-process.** Newline-delimited JSON over a child's stdin and stdout:
`describe` once, then `parse`, `print` and `render` per call, one request
line to one response line — fig's wire with twig's table in it. The helper
is any executable that speaks it; JSON because every host that could write
one already has a JSON library, and twig parses JSON with `std.json`. The
runner is a vtable whose functions talk to a process, lives beside the CLI
and in the Rust crate (`twig::helper::spawn(command)`), never in the
library, and registers through the same `twig_language_register` a host's
own vtable does. The CLI spawns it once per invocation; a long-lived host
spawns on first use and respawns on the next request if it exits, reporting
a diagnostic if it exits again on the same one.

**The browser.** The npm build, when there is one, reaches a JS object
through one wasm import carrying the same wire — fig's "as implemented"
note, taken as the design rather than arrived at: the object a JavaScript
author writes *is* the wire's description with the functions on it, so one
module is a CLI helper under `twig-quickjs`, a Node test under
`serve`, and a browser format under `registerLanguage`, unchanged. Leaf's
web build reaches twig through Rust, so its browser carrier is a Rust
`Language` bridged through `wasm-bindgen`, which is leaf's to decide.

### Load is the validation moment

A compiled format has `zig build test`; a runtime one has registration, and
registration runs the harness and refuses on the first failure:

1. The description is well-formed: `name` an identifier, `extensions`
   non-empty and not owned by a compiled row, `author` implies a `syntax`,
   the `syntax` coherent under the rules `assertCoherent` states.
2. Every sample parses, and every table is well-formed under
   `expectColumns`: spans inside the input, nested and pre-ordered, markers
   only where the engine allows them, attrs spans only where attrs exist.
3. If `write`, every sample prints and reparses to an equal tree.
4. If `author`, an `Editor` constructs over every sample and a no-op splice
   is the identity; each declared renderer meets `expectRenderText` and
   `expectRenderBlock`.
5. The **fidelity probe** runs. `diagnostics.zig` measures its table rather
   than declaring it — a document around every kind, serialized, reparsed —
   and that probe runs over a runtime target at load, so `twig convert -o
   <runtime>` warns about what it drops from the day it exists. Fig's
   runtime targets have no loss diagnostics yet; twig's cannot lack them,
   because twig's table was never a declaration to begin with.

`twig lang check <helper-or-module>` runs the list from the CLI and says
what failed. A parse that fails after load is a diagnostic naming the
language and, for a helper, the command; a helper that exits or writes
something that is not the wire is the same diagnostic. Neither is a crash,
because core validates every table it receives, not only the samples.

## The experience

**CLI.** Discovery is a file twig reads with no dependency: one language per
line — its name, a comma-separated list of extensions or `-` for none, then
the command and its arguments — with `#` comments, searched as
`.twig/languages` from the working directory upward and then
`$XDG_CONFIG_HOME/twig/languages`. A `languages.figl` would be the first
fig-format file in this repository, and twig does not depend on fig; if it
ever does, the file becomes figl and the line form stays accepted. The file
is consulted only when `-i`, `-o` or an extension names nothing built in,
and `--lang <name>` selects a registered language where the extension would
resolve to a compiled one. Then `twig convert app.org`, `twig convert -o
org`, `twig query`, `-o ast` and `-o table` do what they do for a built-in,
at the tier the format declares. `twig lang list` shows the built-in and
registered formats with their capabilities; `twig lang check` and `twig lang
table` are above.

Twig has no content sniffing to keep a runtime format out of: a format is
inferred from an extension or named, and a runtime one resolves the same
way. A runtime extension may not take one a compiled row owns.

**Rust.** `Document::parse`, `Editor::new`, `serialize`, `Format::supports`
take a `Format::Runtime(id)` as they take any other. `twig::helper::spawn`
is for a host that wants a helper without linking its engine; `twig-quickjs`
as a crate is for one that wants the engine in process.

**Leaf.** Nothing changes until a runtime format is registered; then the
toolbar dims what the format's `syntax` cannot spell, which it already does
per format, and `Format::supports` answers for a runtime code the way it
answers for GFM.

## What this is not

Not a plugin system for the engine: nothing lets a format change how the
editor splices, what a locator means, or how a conversion is diagnosed. A
renderer returns text and never receives the editor. A runtime format
cannot add a kind, a classifier, or a column; it fills the ones there are.
Not a proposal to carry the compiled formats as scripts: the invariant worth
having is that every compiled format is *expressible* through the contract,
checked by a twin, not that every format is carried by it — a VM in every
binding is the objection this design starts from. And not a change to any
existing call: every entry point keeps its meaning for every code below the
base, which is why the range is reserved in a minor and the ABI stays at 6.

## Answers taken

- **Codes.** `TWIG_FORMAT_RUNTIME_BASE` is 4096, reserved now; a runtime
  code is assigned per process in registration order and is never pinned; a
  caller that persists a format persists its name.
- **`Format` is exhaustive in Zig.** It gains one member, `.runtime`, with
  the id beside it, and `intToFormat`/`intToTarget` become a checked lookup
  that routes a code at or above the base to the registry before the switch.
  `twig_format_supports` and `twig_format_is_authorable` read the registered
  `Syntax`. Every `int format` entry point is reached, and a test holds that
  none is missed.
- **Registry state.** Append-only under a mutex; a registration is complete
  before its code is returned, so every read is of an immutable value.
  There is no unregistration.
- **Dialects.** Rows, as fig's and as Markdown's; a runtime row is a
  `Format` by name with `dialect_of` set.
- **HTML.** The shared printer over the table, with core's indexed labels.
- **Fidelity.** Measured at load by the existing probe, never declared.
- **The npm carrier.** Designed for — the object is the wire document — and
  built when twig ships a package to carry it, not before.

## Sequence

1. **Reserve the range.** Done, in `add(c-abi): reserve the runtime format
   range`: `TWIG_FORMAT_RUNTIME_BASE` in `twig.h`, `c_abi.zig` (with a
   comptime check that no `TwigFormat` member reaches it), `header_test.c`
   and `twig-sys`, and a test that a code in the range is refused on both
   axes until registration exists. ABI 6, unchanged.
2. **The table, written down.** `documentToTable` and `tableToDocument` in
   core, the identity over every harness sample under `AST.eql` and the
   column checks; `node_spelling` and `attrs_spans` as columns; `-o table`
   and `twig lang table` printing it for a compiled format. The compiled
   formats cross the contract here, before any runtime one exists.
   Done, in `add(table): the node table, with every compiled format
   crossing it`: `ast/table.zig`'s `encode` and `decode`, the column rules
   as `checkColumns` shared with the harness, and the identity over every
   sample and every fidelity probe. It found that XML, HTML and AsciiDoc
   never compacted their arenas, which `fix(parse)` before it corrected.
3. **The in-process carrier.** `TwigLanguageVTable`, `twig_language_register`,
   `twig_format_by_name`, the `Runtime` registry entry and `.runtime` in
   `Format`, the checked lookup at every entry point, and load running the
   harness and the fidelity probe. Additive; ABI stays 6. Then the Rust
   half: `trait Language`, `register`, `Format::Runtime`.
   Done, in `add(runtime): register a language at runtime, in Zig, C and
   Rust`, for the read and write tiers. Where it differs from the text
   above: the author tier is refused by name (`caps.author`, `syntax`) until
   the checks that make an unseen `Syntax` safe exist, and `dialects` with
   it; `Format` and `Target` are non-exhaustive enums whose runtime value is
   the wire code, rather than a `.runtime` member with an id beside it; the
   C table carries the description as the same `describe` JSON the helper
   wire will, not as fields; the registry holds 64 languages, one comptime
   row of functions per slot; a print receives the table without positions
   (`decodeBare`), rooted at any kind; and the fidelity probe measures
   attributes as well as kinds, per key class, as the attribute probe does
   for a compiled target.
4. **The helper runner.** The wire's codec in core over a `Transport`, the
   process runner beside the CLI and in the Rust crate, the discovery file,
   `--lang`, `twig lang list` and `twig lang check`.
   Done, in `add(helper): the helper wire, and the runners in the CLI and
   Rust`. Where it differs from the text above: the codec is exposed
   through the C ABI too (`twig_language_register_transport`), so the Rust
   runner moves lines and never parses JSON; the wire's field for the row
   is `dialect`, as fig's is; `$TWIG_LANGUAGES` is searched first, as fig
   searches `$FIG_LANGUAGES`, so a test can point at a file; `lang check`
   takes a configured name or, after `--`, a helper's command, and
   `--against` compares tables row for row as fig's does; `--lang` refuses
   a compiled name, which `-i` already takes. The CLI never respawns a
   helper, since an invocation that loses one has nothing left to do with
   it; the Rust runner does, once per request. The answering end (`wire.handle`)
   is in core, and a Rust `serve` over it is step 5's, with `twig-quickjs`.
5. **`twig-quickjs`.** A new repository over the Rust crate and `rquickjs`:
   `twig-quickjs <module.mjs>` as the helper and `register_file` as the
   crate, with `twig`, `twig/grammar` and the wire served from the binary
   as `fig-quickjs` serves its own. The bar for calling the contract
   crossed: `djot.mjs` over djot.js passing `twig lang check --against djot`
   on the harness samples and the djot.js corpus, table for table. Then the
   first format twig does not compile in — the twig-native prototype at
   read tier, or whichever of Org and the wiki dialects someone brings
   first.

   Built, 2026-10-02, as a local repository not yet published: `djot.mjs`
   is `js/languages/djot.js` there, over djot.js 0.3.2 vendored with its
   corpus, and it reads, writes and authors. `twig lang check js-djot
   --against djot` passes the load check and gives djot's table on every
   harness sample and on 248 of the corpus's 260 cases; the twelve that
   differ are two twig bugs ([empty `str`](/docs/tasks/djot-word-attributes-split-an-empty-str.md),
   [caption span](/docs/tasks/djot-table-caption-content-span-runs-backwards.md))
   and one change in djot since 0.3.2, written up in its
   `docs/twin-differences.md`. Where it departs from the text above: the
   twin reads djot.js's event stream as well as its AST, for the positions
   of attributes, fence bodies and verbatim interiors the AST does not
   keep; and an authoring helper's load check costs about 4 s per CLI
   invocation, against 40 ms for one that reads and writes
   ([a task](/docs/tasks/runtime-load-check-cost-per-invocation.md)).
6. **Measure before an editor gets one.** The per-edit cost of an
   in-process runtime format at leaf's keystroke rate, with the djot twin as
   the benchmark against the compiled row. The number decides whether the
   table stays JSON or becomes typed arrays, and whether the twig-native
   prototype reaches leaf as a script or waits to be compiled.

   The contract's half, measured with no engine (`zig build bench-edit`,
   2026-10-02, ReleaseFast, Apple silicon): a twin whose parse is djot's
   own, written out as a table, against the compiled row, one byte typed
   mid-document per keystroke.

   | document | compiled key | runtime key | ratio |
   |---|---|---|---|
   | 8 KB | 0.06 ms | 0.44 ms | 7.1x |
   | 34 KB | 0.33 ms | 2.36 ms | 7.3x |
   | 135 KB | 1.36 ms | 9.45 ms | 6.9x |

   The table is 4.5–6x the source, and reading it back is three quarters of
   the cost: on the 34 KB document 0.38 ms of parse, 0.41 ms of encode and
   1.78 ms of decode, which builds a `std.json.Value` tree with a map per
   row before reading a field. So the first number says the JSON can stay
   and its reader cannot ([a task](/docs/tasks/table-decode-without-a-value-tree.md)).

   The engine's half, from `twig-quickjs`'s djot twin on djot.js's 12.6 KB
   bench readme (release build, same machine): a parse is 13–14 ms
   in-process and 14–15 ms through the helper, against 0.09 ms compiled —
   about 150x, of which djot.js's own parse is 6.7 ms and the event pass
   the twin reads positions from 3.3 ms. The table's decode is under a
   millisecond of that. So the table stays JSON: the contract is a small
   part of a scripted language's cost, and typed arrays would not move it.
   And a script does not keep up with typing past a few kilobytes — one
   frame is spent on a 12.6 KB document — so a language an editor reparses
   per keystroke reaches leaf compiled, or once the runtime row reparses
   only the blocks a keystroke touched; the twig-native prototype waits to
   be compiled.

Steps 2 through 4 are a core minor and a Rust minor each, none breaking; 5
is a repository; 6 is a number. Versions are Adam's to name. Each step is
verified the way the tasks before this one were: `zig build check` green,
the harness over the compiled formats unchanged, and — from step 5 — the
harness over each twin producing the tables its compiled sibling does.
