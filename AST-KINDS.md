---
part_of: '[Twig](/twig.md)'
---
# Twig — the AST kind vocabulary

This document is the home for the *rationale* behind `src/ast/ast.zig`'s
`Node.Kind`: why the vocabulary has the shape it has, why a given kind exists
rather than a cheaper alternative, and which arguments were tried and rejected.

The source comments in `ast.zig` say what each kind **is**. This file says why
it is that and not something else. If a comment there points at a section
heading below, this is where the argument lives.

Like [DESIGN.md](/DESIGN.md), this file is deliberately self-contained: Twig is
published independently, so everything a reader needs travels with the repo.

---

## The shape: one flat union and three classifiers

`Kind` is a single flat `union(enum)` of ~50 arms. Every node carries its own
`first_child`/`next_sibling`, regardless of kind, so `Kind` only needs each
kind's *extra* data — a heading's level, a code block's text. Kinds with no
extra data are `void` payloads.

That is one more level of heterogeneity than `fig`'s config AST (~8 kinds),
which folds a container's child pointer directly into its `Kind` payload
(`sequence: ?Id`). At ~50 kinds that folding stops paying for itself, so Twig
keeps the child pointers uniform on `Node`.

### Why the union is not nested by position

The obvious tidying is to group the arms into the banners the file already
uses — a document root, blocks, container children, inlines, generic markup —
and make each group a nested union. It was considered and rejected, for four
reasons.

**The groups are not static.** A `container`'s level is decided by its `form`
payload at runtime: `block_leaf`/`block_fenced` are blocks, `inline_text` is
an inline, and a `null` form (every HTML/XML element) is neither, because
whether `<video>` is a block is a property of the stylesheet and not of the
parse. No static group can hold it.

**The axes cross.** `substitution` is block-level with inline children.
`line`, `caption`, and `term` are `neither`-level with inline children. A tree
encodes at most one classification, and there are at least three worth having.

**The grouping test fails.** The three families that *are* nested
(§ [When a family gets nested](#when-a-family-gets-nested)) share one
property: every generic consumer treats their members identically, and only
the printers tell them apart. Blocks are the opposite — `html/serializer.zig`
switches 35 kinds apart in a single switch, `rst/doctree.zig` 46. Consumers
switch on the member, not on the group.

**It reopens a hole that has already cost three bugs.** With
`.block => |b| switch (b)`, adding a block kind only breaks the builds of
consumers that switch *inside* the group; a consumer with an outer
`.block => …` arm silently swallows it. That is structurally the same failure
as an `else =>` arm on a `Kind` switch, which has hidden a real bug three
times.

The cost would also be real: ~360 construction sites, ~130 switches, and
`std.meta.Tag(Node.Kind)` is used as flat node identity by `KindRef`,
`ast/splicer.zig`, `rst/doctree.zig`, and the editor tests. Nesting turns that
tag into `.block` and destroys the identity, so a synthetic flat tag enum
would have to be maintained alongside the nesting.

The grouping instinct is right; the answer is a **function**, not a shape.

### The three classifiers

Each is an exhaustive switch over every kind, so **a new kind cannot be added
without declaring all three** — the property the hand-maintained lists they
replaced never had.

| Classifier | Answers | Replaced |
|---|---|---|
| `level` | block / inline / neither | `djot.zig`'s `block_tags`/`inline_tags`, `ast/locate.zig`'s `isBlockParent`, `html/parser.zig`'s `isBlockKind` |
| `contentModel` | blocks / inlines / text / empty | `holdsOpaqueText`'s hand-written set |
| `structuralChildren` | the closed child vocabulary, or `null` | prose on `line_block`, `table`, `definition_list_item`, … |

The lists these replaced disagreed with each other: djot counted
`reference`/`footnote` as blocks and HTML did not; HTML counted
`list_item`/`term` and djot did not. Every new kind had to be threaded into
each list by hand, with nothing failing the build if it wasn't.

`level`'s `neither` is not a shrug. It is the honest answer for three groups:
the `doc` root is not itself a block; a structural child (`list_item`, `row`,
`cell`, `term`, `caption`, …) only ever appears inside its own parent and
never where a paragraph could go, which is exactly djot.js's `isBlock` rule;
and a generic-markup node has no level at all.

`contentModel` describes what a kind may **contain**, not what a given node
does contain. The difference is observable: in one HTML table
`<td><p>x</p></td>` parses to `cell > para` while its sibling `<td>y</td>`
parses to `cell > str`, and djot puts inlines directly in every cell. Both are
`.blocks` — an inline run is the tight, `<p>`-elided case, exactly as a tight
list item holds inlines without stopping `list_item` from being a block
container. Every caller reads it as a permission: *may children go here at
all*. Only `text` and `empty` answer no.

The `blocks`/`inlines` vs `text` split is the load-bearing one. A `text`
node's `content_span` addresses **opaque bytes**, not a child region, so
`insertChild` must refuse it even though it has a `content_span`
(`replaceContent` still works).

`structuralChildren` is the newest of the three and the one with the most
direct evidence: its sets are what six parsers and every vendored corpus
actually produce, checked by `ast/containment_test.zig` over ~7000 documents.
Writing it turned up a real bug — `html/parser.zig` mapped
`<pre><code>x</code></pre>` onto a `code_block` while leaving the absorbed
`<code>` node attached, so the same bytes hung off the tree three times under
two nodes documented as childless.

Two findings from that corpus survey are worth recording, because both refute
what the prose used to claim:

- **The generic-markup kinds go anywhere.** `container`, `markup_leaf`, and
  `processing_instruction` are admitted by every parent on top of its closed
  set. The corpora put an rST `classifier` container inside a
  `definition_list_item`, a `system_message` inside a `line_block`, and an
  HTML `colgroup` inside a `table`. "Children are `line` nodes and nothing
  else" was simply false.
- **The level axis does not constrain a general parent.** A `.blocks` parent
  legitimately holds inlines, and a `.inlines` parent holds an rST
  `reference` — a `block`-level definition node. So `admitsChild` is
  permissive wherever there is no closed set, and it is a claim about where an
  **edit** may place a node, not about what a parser may produce. A forgiving
  parser puts a stray HTML `<tr>` straight under `doc` when CommonMark's
  blank-line rule splits a table across two HTML blocks (spec examples
  190/191), and that parse is correct.

### Which side a fact lands on: `Kind` or `Document`

`ast.zig` holds MEANING; `document.zig` holds POSITION. Byte offsets
(`span`/`content_span`) live in `Document`'s id-indexed side-tables alongside
the `source` they address — following `fig`, whose `Node` is likewise
`{id, kind, next_sibling}` with positions in a sibling `Document`.

The rule for a new field: **it belongs in `Document` iff two documents
differing only in that fact render identically.** A list's `tight` flag fails
that test (it elides the `<p>`), so it stays in `Kind`. A bullet's `-`-versus-
`*` spelling passes it, so it goes to `Document.Spelling`.

The split is what makes `AST.eql` possible — two parses can be compared for
*meaning* because there are no positions left in the tree to disagree about,
with `Document.spansEql` as the separate layer for "…and were written the same
way". It is also enforceable rather than conventional: a printer taking
`*const AST` cannot reach a byte offset, while the edit layer takes a
`*const Document` because splicing needs both halves.

`AST.eql` compares the two node arrays directly rather than walking from the
root, and the walk is not merely slower — it is wrong. A link reference
definition and a footnote definition are live nodes attached to no parent, so
a tree walk never reaches them. Djot resolves reference labels at render time,
so for `[a][r]` the destination lives only on that unattached `reference`
node: two djot documents whose definitions differ (`[r]: /XXX` versus
`[r]: /YYY`) have identical reachable trees and render to different HTML, and
a tree walk calls them equal. Comparing the arena catches it, because
`ast/compact.zig` keeps those definitions (they are passed in as extra roots)
and orders them deterministically. That compaction pass is also what makes
slot-by-slot comparison legal at all: Twig's inline grammars are not decidable
left to right, so the parsers speculate and abandon nodes, and without
compaction the arena would hold orphaned delimiter runs whose payloads record
the *spelling* (`str "**"` versus `str "__"`).

---

## When a family gets nested

Three enums sit one level below `Kind`: `InlineMark` (9 members),
`TextLeafKind` (9), and `MarkupLeafKind` (3). The pattern is borrowed from
`fig`'s `Kind.Extended`, whose doc states the property it is there for:
*adding a new such scalar is a new `ExtKind`, not a new union arm — the outer
switches stay closed; only the printers gain a case.*

**The test for nesting a family: every generic consumer treats the members
identically, and only the printers tell them apart.** The nine `InlineMark`s
were nine arms, and `level` and `contentModel` listed all nine twice over,
`ast/json.zig` lumped them into one payload-free arm, and `ast/select.zig`
never distinguished them. Only the three serializers cared, and only because
each mark has its own delimiters — which is `syntax.zig`'s `Delims` table's
job, not `Kind`'s. `TextLeafKind` and `MarkupLeafKind` are the same story:
seven byte-identical `{"text": …}` arms in `ast/json.zig`, seven identical
dupes in `ast/builder.zig`.

This is **not** string matching and **not** a loss of exhaustiveness: a
serializer still switches over `InlineMark` exhaustively, so a tenth mark
still fails those builds until it is spelled. What it stops doing is failing
the builds that never cared.

Three kinds are deliberately excluded from the families:

- **`raw_inline`** is not a `TextLeafKind`: its payload is `{format, text}`, a
  second field that would have to be `null` for all the others.
- **`processing_instruction`** is not a `MarkupLeafKind`, for exactly the same
  reason — its payload is `{target, data}`.
- **`str`** is not a `TextLeafKind` for the opposite reason: it is the
  *undelimited* case, plain content with no marker at all, and by far the most
  common node in any document. It keeps its own arm rather than paying an
  indirection to join a family it doesn't belong to. `fig` draws the same line
  between `string` and `extended`.

`smart_punctuation` stays its own arm rather than folding into `text_leaf` or
`inline_mark` because its kind is a *semantic* choice the HTML printer acts on
(which glyph to emit), not a spelling. But its payload is the bare
`SmartPunctuationKind` enum rather than a `{kind, text}` struct: the source
spelling is canonical per kind — the parser normalizes djot's explicit `{"` to
`"`, same as the implicit form — so there is no per-node spelling left to
store. It is derived on demand by `SmartPunctuationKind.ascii`.

`KindRef` is the consequence of the families. A bare `Kind` tag used to be
enough to name a kind precisely, and for most kinds it still is; it stopped
being enough for the nine `InlineMark`s, whose tag is now all `inline_mark`,
so "find the enclosing `strong`" cannot be asked with a tag. `KindRef` is the
exhaustively-switched bridge — no strings, and adding a family means adding an
arm there, which fails every `matches` caller until handled.

---

## The published vocabulary

`Kind.kindName` projects **three** namespaces into **one** flat published
vocabulary: the `Kind` tags (minus `inline_mark`/`text_leaf`/`markup_leaf`,
whose names are internal), plus every `InlineMark`, `TextLeafKind`, and
`MarkupLeafKind` member. `ast/json.zig`'s `"kind"` field and `c_abi.zig`'s
`twig_node_kind_name` share that namespace, and `twig query` selectors match
against it.

So for an `inline_mark` the published name is the *mark's* — `"emph"`,
`"strong"` — never `"inline_mark"`. The family nesting is an internal
structuring; the published vocabulary predates it and does not move because of
it.

A future family member colliding with a `Kind` tag would silently alias two
different node kinds under one published name, so a comptime test in
`ast.zig` makes the collision a compile error naming the duplicate.

---

## Per-kind notes

### `container` — why one kind and not four

`container` replaced `div`, `span`, `directive`, and `element`, which were
four spellings of **one** concept — a named-or-classed container with
attributes and children — split by which format's parser produced them.

That split put surface syntax in `Kind`, which is exactly what `syntax.zig`
exists to keep out of the shared vocabulary. It meant a djot `:::` and an HTML
`<div>` were different nodes despite being the same construct; every consumer
(`ast/select.zig`, `ast/json.zig`, `c_abi.zig`, four serializers) grew four
near-identical arms; and a fifth format could only be added by growing a fifth
kind.

What the unification does **not** do is erase the difference between a NAME
and a CLASS. Djot's `::: note` is a div carrying `class=note` (the name is
`"div"`, the class is in `attrs`), while Markdown's `:::note` is a directive
whose *type* is `note` (the name is `"note"`, `attrs` is empty). Those are
genuinely different documents and still parse to different nodes. The
unification is structural, not semantic.

`name` is stored as written, including any namespace prefix (`svg:rect`);
prefix resolution is a reader-side helper, later.

`Form` carries the one piece of a container's shape that a per-format `Syntax`
table cannot hold, because it varies per **node** rather than per format: one
Markdown document may contain both a `::name` leaf and a `:::name` fence, so
the choice has to travel with the node. Everything else about spelling a
container back — the colon, the angle brackets, the `.. ` prefix — is
format-uniform and belongs in `syntax.zig`. `Form` also carries the
block/inline classification that `div` and `span` used to encode by being
separate kinds, and its `null` means UNCLASSIFIED, which is the honest answer
for HTML/XML.

### `line_block` and `line` — why `indent` is a number

A line block is a run of lines whose **breaks are the content**: rST spells it
`| ` per line (or `.. line-block::`), AsciiDoc `[verse]`, docutils' HTML
writer `<div class="line-block">`. Verse, addresses, anything where reflowing
the text would destroy it.

It is not a `code_block` with the monospace turned off. A code block's payload
is opaque text, while every line here is a normal inline container — the
docutils corpus has `emphasis`, `reference`, and `target` inside lines. The
right reading is "a list whose items are single lines".

docutils models a line's leading whitespace by **nesting**: an indented run
becomes a child `<line_block>`, recursively, by grouping every line indented
past the current group's minimum. The corpus reaches three levels deep, and
the encoding is lossy on its own terms — in `test_line_blocks.py:8` a 2-space
line lands *deeper* than an earlier 4-space one, because the depth is a line's
rank within its group and not its column. docutils' own HTML writer then
flattens the tree back to one `<div class="line-block">` per level for a CSS
margin.

So the nesting is an *encoding of a per-line number*, not a grouping anything
reads as a unit, and Twig stores the number. The two forms are mutually
recoverable — a depth sequence rebuilds docutils' tree by opening and closing
blocks on demand — so `doctree.zig` still round-trips the corpus exactly,
including its 0→2 jumps.

An empty line (no children) is content, not a separator: it is the stanza
break, and 7 of the corpus's 47 lines are one.

### `table`, `column`, `cell`

A table's children are `[caption?, column*, row*]`. The caption comes first
when present — djot.js's tuple type always writes one, even empty, while the
HTML and rST parsers emit one only when the source has one.

A `column` is one column of the table's **column axis** — a description of a
column as a whole, sitting alongside the rows rather than inside them. rST
spells it `<colspec colwidth="33">`, HTML `<col>` inside a `<colgroup>`,
DocBook `<colspec>` again.

A table does not need one: GFM and djot pipe tables have no column axis at
all. Where a format does have one it is not optional in practice — every one
of the 65 tables in the docutils corpus carries a full run of them, which is
why the rST table subtree could not be mapped without this kind.

**Why `column` carries no payload.** A column's interesting content is its
WIDTH, and the two formats that have one disagree about what a width is: rST's
`colwidth` is a unitless relative integer, HTML's is a CSS length (`25%`,
`3em`). Picking a representation on the evidence of one format would be
guessing, so the width rides in the normal `attrs` side-table as written,
which is where every other un-normalized source value already lives (a
`bullet="*"`, a `refuri`). rST's `stub` — the column is a row-header column —
is there for the same reason; it is deliberately *not* projected onto the
`head` flag of each cell in the column, since that is a per-column fact and
re-deriving it from the cells would be lossy in both directions. So `column`
is a marker: it says a column axis exists, how many columns are in it, and
gives per-column data somewhere to attach. A typed payload is the obvious next
step the moment a **second** format needs to act on one.

A cell's `colspan`/`rowspan` are its **grid extent**, always ≥ 1, with `1`
meaning the ordinary one-square cell. They are semantic, not spelling:
`<td colspan=2>` and `<td>` are different documents, so they live on `Kind`
rather than in `Document`'s side tables. Only formats with a real grid produce
anything but `1`: HTML's attributes today, rST's grid tables next (docutils
spells them `morecols`/`morerows` — extent *minus one* — so that boundary
converts). GFM and djot pipe tables cannot express a span at all.

HTML's two oddities stay out of the shared model and ride in `attrs`, where
the source spelling is preserved verbatim: `colspan=0` (a parse error UAs
treat as 1) and `rowspan=0` ("to the end of the row group", a count nobody can
resolve without the whole table). Both normalize to `1` here, and because the
HTML serializer only synthesizes the attribute when the extent is not `1`, the
original `rowspan="0"` still round-trips off the node's own attributes.

### `citation` — why not `Footnote.namespace`

A citation definition (`.. [CIT2002] Deep Thought.`) is a footnote in a
second, separate name registry. Structurally it *is* a footnote — a named
definition holding blocks, used from an inline reference — and the tempting
cheaper move was a `namespace` field on `Footnote` rather than a kind of its
own.

The **use** side is what decides it. A footnote reference is a
`TextLeafKind.footnote_reference`, and that family's members are uniformly
`{kind, text}`; giving it a namespace would add a second field to all of them
for the sake of one (the same reason `raw_inline` is not in the family). So
the use must split by `TextLeafKind` regardless, and a design where the use is
told apart by its tag while the definition is told apart by a payload field is
incoherent. Both split.

`label` is the name resolution uses, exactly as `footnote.label` is; rST
spells it the `names` attribute. docutils normalizes that (`.. [TARGET]`
resolves as `target`) and keeps the written form in a `<label>` child, which
stays a generic node — see `doctree.zig`'s `definitionName`.

### `substitution` — a named definition whose body is inline

rST's `.. |name| image:: pic.png`, whose body is spliced in wherever `|name|`
appears. This is a shape Twig did not previously have: `footnote` and
`citation` are named definitions holding blocks, and `reference` is a named
definition holding nothing at all. This one holds inlines — corpus bodies are
an `image` (13), plain text (12), or a short inline run (`emph`, `strong`,
`superscript`, a `link`, a `raw_inline`).

So it is block-level (it is a document-level definition, like the other two)
with inline children, which is `para`'s combination and needs nothing new from
the model.

Only reStructuredText has this, and that is not disqualifying — `task_list` is
GFM's alone and `processing_instruction` is XML's. What a format-specific kind
costs is one honest answer per target in `diagnostics.zig`'s `fidelity`, which
is the gate it has to pass.

It is named `substitution` and not `substitution_definition` to match
`footnote`, where the bare noun is the definition and the `_reference` suffix
is the use.

### `metadata` — a data island, not markup

Document-level metadata (front/end matter) as an inert, self-describing data
island. `lang` is the config language it is written in, stored exactly as the
fence tag was written (`yaml`, `toml`, `fig`, `figl`, `json`, …; a bare `---`
fence defaults to `yaml`, `+++` to `toml`) — no normalization, so it
round-trips losslessly. The HTML printer derives the data-island MIME
mechanically as `application/<lang>`.

It is distinct from `code_block` (a *rendered* code sample) and `raw_block`
(verbatim output for a target format): metadata is *about* the document and
never renders into the body — the HTML printer projects it to a
`<script type=mime>` data island. Produced by the Markdown parser's
frontmatter path; a future pass hoists front+end blocks into one parsed
doc-level `fig` record.

### `link` and `image` share one payload

`Kind.Link` is the payload of both, and the shapes are identical on purpose:
an image is a link rendered differently, not a different record. Sharing the
type documents that.

By contrast `Citation` and `Substitution` have the same shape as `Footnote`
and are still *distinct types*: they are the same structure in different name
registries, and naming that separately is what stops a later field added for
one (an `auto` flag for `[#]_`, which citations cannot have) from silently
arriving on the other.

### `section`

A heading-implied nesting wrapper. It never appears in raw djot syntax; it is
only synthesized by the parser — see djot.js's `parse.ts` section handling.

### `ordered_list` numbering versus punctuation

How an ordered list **counts** (`<ol type="a">` renders differently) lives on
`Kind` as `ListNumbering`. How its markers are **punctuated** (`1.` vs `1)` vs
`(1)`) renders identically and is therefore spelling — it lives in
`Document.Spelling.ordered_delim`, alongside a bullet list's `-`/`+`/`*`
character. Both used to sit on `Kind` as `BulletListStyle`/`OrderedListStyle`.

### `Attrs` is one ordered list

Deliberately a single order-preserving list rather than separate
`classes`/`id`/`keyvals` fields: djot.js stores attributes as one plain object
whose iteration order is insertion order, and renders them back in that same
order — `{key1=val1 .foo key2=val2}` renders
`key1="val1" class="foo" key2="val2"`, interleaved exactly as written, not
grouped by kind. `class` and `id` are therefore ordinary keys here (`class`'s
value accumulates multiple `.foo .bar` occurrences space-joined, at the
position of its *first* occurrence, matching djot.js's "mutate the existing
object property" behaviour). There is no dedicated `id`/`class` accessor
because callers that care about rendering need the entries in order anyway.

A `null` value means a **bare** attribute — HTML `disabled`, which must
round-trip distinctly from `disabled=""`. Djot attribute syntax has no way to
write a bare attribute, so djot parses always produce non-null values. `find`
is the accessor that can tell "key absent" from "key present but bare"; `get`
cannot.

### Why there is no `Node.eql`

A node's identity in `ast.zig` is its `id`/`first_child`/`next_sibling` —
arena slots, which are a parsing artifact and not part of the document. A
node-level equality that compared them would be a trap; one that ignored them
would just be `kind.eql`. Compare kinds, or compare trees.
