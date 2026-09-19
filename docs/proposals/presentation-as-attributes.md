---
title: "Proposal: presentation as attributes"
status: implemented
author: adammharris
created: 2026-09-18
updated: 2026-09-18
part_of: '[Proposals](/docs/proposals/proposals.md)'
---

# Presentation as attributes

## Status

`implemented` on 2026-09-18, in the sequence's order: the attribute axis of
`diagnostics.zig` in `1bc22e1`, the Markdown serializer's `<div>` and
`<span>` in `3a9e9a1`, the parser pairing and the two measured claims in
`e632cd6`, `setBlockAttrs` in `6390255` and `wrapRangeAttrs` in `e956f9f`,
each with its C and Rust surface (gesture codes 27 and 28). Three things the
text below did not foresee. `Syntax.block_attrs` is not a boolean but a
three-state — `native`, `wrapped`, or absent — because the editor needs the
shape to know whether to look for a sole-child wrapper; `inline_attrs` is
the boolean. AsciiDoc claims the block gesture and not the inline one: its
`[#id.role]#text#` keeps an id and a role and has no slot for a third key,
and a gesture that dropped one silently is what the gates exist to prevent.
And the measurement found three serializer defects beside the axis it was
built for, filed as tasks rather than fixed here: djot writes a heading's
attributes after its text, where its parser reads them as the text's; djot
writes a reference definition's attributes where the reparse then fails to
read the definition at all; AsciiDoc does not write a table's title. leaf's
vocabulary proposal is the next step, and it is leaf's.

`accepted` on 2026-09-18, on three decisions. Twig carries the keys and
interprets none of them; what `center` means is the host's, and the
recommendation to leaf is a class for an enumerated property and a `data-`
key for a valued one, for the reasons under **The principle**. Markdown
spells a block's attributes as a raw `<div>` around it and a run's as a raw
`<span>`, both read back under `ParseOptions.html_elements` — not pandoc's
fenced div and bracketed span, which the first draft recommended and which
**The Markdown decision** now argues against. And the loss is reported
before any spelling changes: `diagnostics.zig` gains the attribute axis it
had reserved, and reports it per target.

The sequence at the end is the order the work lands in.

## The picture

A rich-text editor over twig wants what every word processor has: this
paragraph centred, that one right-aligned, a run of words in a larger size,
a block with more air above it than the theme gives. leaf is asking for this
on the far side of its paginated view, and twig's README says the project
has no first-class support for presentation formats. Both are right, and the
way they are reconciled is already in the tree.

Twig does not carry styles. It carries **attributes** — the `Attrs` side
table, one ordered list of `(key, value)` per node, that every parser fills
and every serializer spells — and a rich-text editor's alignment is an
attribute the host names. `insertDirective` set the shape on 2026-09-18:
twig writes a name and reads one back and interprets none. A highlight's
colour set it earlier and more sharply: `==🔴 text==` is a presentational
fact, it rides the `mark` node as a `data-color` attribute, its Markdown
spelling is an extension the parser has to be given, and `setMarkColor` is
gated on the parse config so it never mints bytes the parser hands back as
prose. This proposal is that shape applied to the other properties, and the
question it has to answer is not whether twig carries them but where each
format can put them.

## What the formats do today, measured

The claims below were checked against the build on 2026-09-18, with
`twig convert -o ast` and `--warn`.

**Block attributes** — a class on a paragraph:

| format | spelling | parses to |
|---|---|---|
| djot | `{.center}` on the line before | `para` with `class=center` |
| HTML | `<p class="center" style="…">` | `para` with `class` and `style` |
| AsciiDoc | `[.center]` on the line before | `para` with `class=center`; `[role=center,id=x,data-size=large]` keeps every key |
| Markdown | — | nothing: `para {.center}` is literal text, and so is a `{.center}` line above it |
| Markdown, `html_elements` on | `<div class="center">`, blank line, the paragraph, blank line, `</div>` | an EMPTY container named `div` carrying the class, the paragraph as its *sibling*, and the closing tag as a raw block |

**Inline attributes** — a class on a run of words:

| format | spelling | parses to |
|---|---|---|
| djot | `[big text]{.large}` | anonymous inline `container` with `class=large` |
| HTML | `<span class="large">` | `container` named `span` with the class |
| AsciiDoc | `[.large]#big#` | anonymous inline `container` with the class |
| Markdown, `directives` on | `:span[big]{.large}` | `container` named `span` with the class |
| Markdown, `html_elements` on | `<span class="large">big</span>` | two `raw_inline` nodes with the text between them — the option promotes a self-contained tag and leaves a pair raw |
| Markdown otherwise | — | nothing |

Three of the four formats already parse and print both, and convert among
themselves with the attributes intact: djot's `{.center}` reaches AsciiDoc as
`[.center]` and HTML as `class="center"`, and HTML's `<span class="large">`
reaches AsciiDoc as `[.span.large]##big##`. A `style` key survives all three
as a key — AsciiDoc writes it as `[style="text-align: center"]` and reads it
back — whether or not the format's own renderer applies it (Asciidoctor does
not). The AST is not the problem.

**Markdown is the problem, twice over.** It has no block-attribute spelling
at all, and its one inline spelling is a directive. And a djot `{.center}`
converted to Markdown is dropped with no warning — the class simply is not
there — because the Markdown serializer writes a `{…}` block for a directive
and nowhere else. An anonymous djot div drops its class the same way:
`::: center` becomes `::: ` with nothing on the fence. `diagnostics.zig` already
names this as "the declared next axis" and declines to guess at it; this
proposal is where the guess is made.

The one Markdown spelling every reader agrees on is raw HTML, and twig reads
it too, as far as CommonMark goes: a `<div>` line is an HTML block, the
Markdown between it and the `</div>` line is Markdown provided a blank line
separates them, and a `<span>` pair is two raw inlines with inline content
between. What `html_elements` does not do yet is *pair* them — an opener
with its closer, the blocks between as the container's children — which is
the whole of the parser work below.

## The principle: twig carries the key, the host owns the vocabulary

Twig never learns that `center` means centred. The gestures below take
`(key, value)` pairs and spell them; what leaf writes into them is leaf's
decision, the way `page-break` and `embed` are, and a document that arrives
with `.lead` or `.wide` from somewhere else is carried and shown as best the
host can. The carrier is a parameter of each call, not a configuration of
twig: a call passing `class=center` and one passing `style="text-align:
center"` are both spelled, and twig is indifferent, so consistency is the
host's to keep. Three consequences worth stating:

- **Twig gains no configured vocabulary.** A higher-level gesture — set the
  alignment, with a switch for whether it writes a class or a declaration —
  would make twig own the mapping from *centred* to CSS, a versioned promise
  to every downstream, and any second host would inherit leaf's choices from
  twig rather than from leaf. The highlight colour is the one presentational
  vocabulary twig owns, and it owns it only because the Markdown spelling
  encodes the colour in the bytes, so the parser has to know. No format
  encodes alignment in its bytes.
- **A class or a `data-` key, not a `style`.** All three survive every format
  twig writes. What differs is who can act on them: a `style` value is a CSS
  declaration list, which a browser and pandoc apply unread and which leaf —
  a native renderer, not a browser — would need a CSS parser to read, and
  which GitHub's sanitizer strips. A class is a token a native renderer can
  switch on, and a `data-` key is a token with a value. The recommendation
  to leaf is a small class vocabulary for the enumerated properties —
  `center`, `right`, `justify` — and a `data-` key for a valued one such as a
  size, with leaf publishing the stylesheet that makes them render in HTML.
  Twig does not enforce this; it is a note about what survives and who can
  read it.
- **Document-level presentation is not here.** A default font, size and line
  height are the theme's (leaf's `EditorTheme` has them already) or the
  front matter's. A per-block attribute is an override of that default, and
  overrides are the whole of what this proposal spells.

## The gestures

Two, one per level, each the same shape as `insertDirective`: the editor
builds or rewrites a node, the format spells it, a `Syntax` claim measured by
the harness says whether the parser reads it back, and `supports` answers
per format and per parse config.

### `setBlockAttrs(offset, attrs)`

Replace the attribute set of the block `offset` sits in. Replace, not merge:
the caller reads the node's attributes, edits the list, and passes it back
whole, which is the contract `Builder.setAttrs` and the C ABI's
`twig_builder_set_attrs` already have, and an empty list clears them. A
merge policy would be a second semantics for one table.

Per format:

- **djot** rewrites the `{…}` line before the block. `Document.attrsSpan`
  gives the existing block's extent to replace; with none, a line is inserted
  above the block carrying the block's own quote prefix, the way
  `insertBlockAfter` carries one. This is the alphabet path, and it keeps
  the block's own bytes verbatim, which is why it is preferred where the
  span is known.
- **HTML** re-prints the element with the new attributes through
  `renderBlock`, which is `setBlockByRender`'s path — it already grafts a
  block's children under a fresh node and copies its attributes across, so
  the mechanism exists and the gesture is a caller of it.
- **AsciiDoc** takes the same render path: its `[…]` line is bespoke enough
  (`#id`, `.role`, `%option`, positionals) that the serializer is the only
  honest writer of it.
- **Markdown** wraps the block in a `<div>` carrying the attributes — a
  container named `div` with the block as its sole child, printed through
  the renderer — or, when the caret's block already *is* the sole child of
  such a div, rewrites that div's attributes instead of nesting a second;
  an empty set there unwraps it. This is the rule `insertLink` applies to a
  link covering the range, for the same reason.

### `wrapRangeAttrs(span, attrs)`

Wrap `span` in an anonymous attributed inline container — djot's
`[text]{…}`, HTML's `<span …>`, AsciiDoc's `[.a.b]#text#`, Markdown's
`<span …>` — or, when the range is exactly an existing one, replace its
attributes instead of nesting a second; an empty set there unwraps it. That
is the rule `insertLink` already applies to a link covering the range, and
for the same reason: re-styling is the common gesture, and it must not build
`[[text]{.a}]{.b}`. An anonymous span and one named `span` are the same
node for this purpose — HTML and Markdown hand back the name, djot and
AsciiDoc do not, and the harness pins that both are read as the container
they were.

### The claims

`Syntax.block_attrs` and `Syntax.inline_attrs`, both booleans defaulting to
false, each claiming that a node of that level carrying attributes, printed
through the format's renderer, reparses to a node carrying them: the same
kind, or — Markdown's shape — a container whose sole child is that kind.
Measured in `languages/harness.zig` per table, as `names_leaf_containers`
is, with a paragraph carrying a class, an id and a `data-` key. Markdown's
table set gains `html_elements` as its fourth axis; at four the nested-array
derivation in `markdown/syntax.zig` becomes a flag-set key, which is a
refactor the fourth axis pays for rather than a cost of this proposal.

`supports(.set_block_attrs)` and `supports(.wrap_range_attrs)` read those
fields. Two gesture codes, 27 and 28, in the C header; two methods on the
Rust `Editor`.

## The Markdown decision

Markdown has to gain a spelling, and the question is which. The bar is the
one every extension has met: a widely read spelling, or none. Four were on
the table.

**A `:::div{.center}` wrap under `directives`.** Needs no parser change and
works today. Rejected: it invents a name, it is a container *around* the
paragraph rather than an attribute *on* it, and it is read by nothing but
remark's directive plugin.

**djot's attribute line, `{.center}` above the block.** The smallest change
and byte-identical to djot. Rejected as the *block* spelling: the Markdown
readers that have an attribute list disagree about where it goes — kramdown
puts `{: .center}` on the line *after*, Python-Markdown and markdown-it-attrs
put it at the end of the *same* line — so there is no one spelling to be
compatible with, and where it is not read it renders as a visible line of
braces above every styled paragraph.

**pandoc's fenced div and bracketed span.** `::: {.center}` … `:::` for a
block and `[text]{.large}` for a run, as the first draft recommended. Both
are read by pandoc and its descendants, and the span is byte-identical to
djot's. Rejected on reflection: pandoc is where the fence's readership ends,
and everywhere else it degrades to a visible line of colons — the objection
the draft itself raised against djot's line. The bracketed span was new
grammar behind a fourth Markdown flag, for a spelling only pandoc reads.

**Raw HTML: a `<div>` around the block, a `<span>` around the run.** Both
are CommonMark already, so there is no grammar to add; both are read by
every renderer that passes raw HTML through — GitHub, Obsidian, markdown-it,
goldmark, pandoc — with the inside rendered as Markdown; both degrade to
*nothing* where HTML is stripped, the wrapper vanishing and the paragraph
staying a paragraph; and both are one spelling with the HTML format, so an
HTML div converts to Markdown near verbatim. What it costs is the pairing
`html_elements` does not do yet, and two more lines per aligned paragraph
than the fence, because the blank lines are what make the inside Markdown.
**Recommended, and accepted.**

The consequence to accept: a Markdown paragraph's alignment is a div around
it, which is a container with a class rather than a class on a paragraph.
So `setBlockAttrs` in Markdown wraps the block, or edits the div's
attributes when the caret's block is its sole child; the Markdown
serializer, converting a djot `para{.center}`, writes the same wrap instead
of dropping the class, and writes an anonymous div's own attributes onto the
`<div>` it already stood for. Reading back, the two trees differ by one
container, and a conversion from djot to Markdown and back gains a div each
way through — this proposal does not unwrap a sole-child div on the way
back, because a div an author wrote is not twig's to fold. A consumer that
wants "this paragraph's attributes" asks for the attributes of the block or
of the div whose only child it is, and leaf's walker already folds a
directive container to a panel, so the fold is a rule it has.

One spelling per name. A container named `div` or `span` is written as its
tag, whatever format it came from, *except* one the Markdown parser read as
a directive (`:::div{…}`, `:span[…]{…}`), which the canonical serializer
writes back as it found it — `Document.containerOrigin` says which, and a
tree with no origin is a conversion and takes the tag. Every other name
keeps the directive spelling it has.

Where the parsing lives: under `html_elements`, which already means "read
HTML into the tree". A `<div …>` line that is an HTML block by itself opens
a container that the next bare `</div>` line closes, the blocks between as
its children — the shape pandoc calls markdown-in-HTML blocks — and a
`<span …>` with its `</span>` in the same inline run is a `container` named
`span` over the inline content between. Only these two tags pair. An opener
with no closer in the document, and a pair whose interior is not separated
by blank lines, keep the reading they have today.

## Fidelity

Attributes become an axis of `diagnostics.zig`, which reserved the place. A
second measured table, `attrsFidelity`, says per target and per kind whether
a node's attributes come back on the node — `faithful` — or are written but
read back as something else by the target's *default* parser — `degraded`,
which is Markdown's answer for every block once the div wrap lands, because
`html_elements` is off by default and a `<div>` is a raw block without it —
or are not written at all — `dropped`, which is Markdown's answer for a
`*run*` with a class, and the answer every target gives for some kind. The
same probe that measures the kind table measures this one, with the same
three keys on every probed node, so a serializer that starts or stops
spelling a kind's attributes fails the build rather than drifting.

`analyze` reports one warning per lossy node *and* one per node whose
attributes are lossy, the second naming the keys. On the wire it is a fourth
fidelity code, `TWIG_FIDELITY_ATTRS_LOST`, rather than a new field: the
`TwigWarning` layout is frozen, and a code is what the append-only rule
allows. That is the honest form of the loss the tables above found, and it
lands first because it is true whether or not the gestures do.

## Sequence

1. Diagnostics: attribute loss reported per target, measured. No serializer
   changes.
2. Markdown serializer: an attributed block is written inside a `<div>`
   carrying its attributes; an anonymous or `div`-named fenced container
   writes `<div …>` … `</div>`; an anonymous inline container with
   attributes, or a `span`-named one, writes `<span …>` … `</span>`; a
   directive-origin `div`/`span` keeps its directive. A
   `Behavioural-change:` trailer — a djot document converted to Markdown
   gains lines it did not have, and an HTML div no longer becomes `:::div`.
3. Markdown parser: `<div>` and `<span>` pairing under `html_elements`.
   `Syntax.block_attrs` / `inline_attrs` and the harness contract, with the
   table-set derivation keyed by flag set.
4. `setBlockAttrs`: djot by its attribute line, HTML and AsciiDoc by a
   render, Markdown by a wrap.
5. `wrapRangeAttrs`, the four formats together — the spellings all exist.
6. `supports`, the C ABI, the Rust binding, each in the step whose gesture
   it exposes.

## What this does not do

- It does not give twig a vocabulary. No key or class name means anything
  to twig, before or after.
- It does not parse CSS. A `style` value is a string.
- It does not pair any tag but `div` and `span`. A `<section>` or
  `<figure>` written around Markdown stays what `html_elements` makes of it
  today.
- It does not add attributes to a kind that has no spelling for them in the
  source format — a Markdown heading's `{#id}` (pandoc's `header_attributes`)
  is a natural later flag and is left for whoever needs it.
- It does not decide leaf's class names. That is leaf's proposal, with its
  own theme mapping and its own stylesheet, and it can be written once the
  first two steps here have landed.

## Cost

Step 2 changes what an existing conversion produces. Step 3 grows the
Markdown syntax-table set, which is the moment to change how it is derived,
and teaches the block and inline parsers to pair a tag, which is a stack
each did not need before. The two gestures are new surface in three
languages, each measured before it is claimed, which is the cost
`insertDirective` has just paid and the pattern it leaves behind.
