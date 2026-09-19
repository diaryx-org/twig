---
title: "Proposal: presentation as attributes"
status: draft
author: adammharris
created: 2026-09-18
updated: 2026-09-18
part_of: '[Proposals](/docs/proposals/proposals.md)'
---

# Presentation as attributes

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

**Inline attributes** — a class on a run of words:

| format | spelling | parses to |
|---|---|---|
| djot | `[big text]{.large}` | anonymous inline `container` with `class=large` |
| HTML | `<span class="large">` | `container` named `span` with the class |
| AsciiDoc | `[.large]#big#` | anonymous inline `container` with the class |
| Markdown, `directives` on | `:span[big]{.large}` | `container` named `span` with the class |
| Markdown otherwise | — | nothing |

Three of the four formats already parse and print both, and convert among
themselves with the attributes intact: djot's `{.center}` reaches AsciiDoc as
`[.center]` and HTML as `class="center"`, and HTML's `<span class="large">`
reaches AsciiDoc as `[.span.large]##big##`. The AST is not the problem.

**Markdown is the problem, twice over.** It has no block-attribute spelling
at all, and its one inline spelling is a directive. And a djot `{.center}`
converted to Markdown is dropped with no warning — the class simply is not
there — because the Markdown serializer writes a `{…}` block for a directive
and nowhere else. An anonymous djot div drops its class the same way:
`::: center` becomes `::: ` with nothing on the fence. `diagnostics.zig` already
names this as "the declared next axis" and declines to guess at it; this
proposal is where the guess is made.

## The principle: twig carries the key, the host owns the vocabulary

Twig never learns that `center` means centred. The gestures below take
`(key, value)` pairs and spell them; what leaf writes into them is leaf's
decision, the way `page-break` and `embed` are, and a document that arrives
with `.lead` or `.wide` from somewhere else is carried and shown as best the
host can. Two consequences worth stating:

- **Classes over inline styles.** A `style="text-align: center"` value is
  CSS, and twig would have to parse it to do anything with it, so it does
  nothing with it: it is a key like any other. But AsciiDoc has no `style`
  and djot's readers do not apply one, so a host that spells its alignment
  as a class reaches every format and one that spells it as CSS reaches HTML.
  The recommendation to leaf is a small class vocabulary — `center`,
  `right`, `justify`, a size scale — that its theme maps and its stylesheet
  publishes. Twig does not enforce this; it is a note about what survives.
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
  `insertBlockAfter` carries one.
- **HTML** re-prints the element with the new attributes through
  `renderBlock`, which is `setBlockByRender`'s path — it already grafts a
  block's children under a fresh node and copies its attributes across, so
  the mechanism exists and the gesture is a caller of it.
- **AsciiDoc** rewrites the `[…]` attribute line before the block: `.name`
  per class, `#id`, and `key=value` for the rest, which the parser reads
  back in full (measured above).
- **Markdown** is the open decision, below.

### `wrapRangeAttrs(span, attrs)`

Wrap `span` in an anonymous attributed inline container — djot's
`[text]{…}`, HTML's `<span …>`, AsciiDoc's `[.a.b]#text#`, Markdown's
`:span[text]{…}` under `directives` — or, when the range is exactly an
existing one, replace its attributes instead of nesting a second. That is the
rule `insertLink` already applies to a link covering the range, and for the
same reason: re-styling is the common gesture, and it must not build
`[[text]{.a}]{.b}`. Whether an anonymous span and one named `span` are "the
same" for this purpose is answered the way `names_leaf_containers` answers
for a class-carried name: by what each format hands back, which the harness
pins.

### The claims

`Syntax.block_attrs` and `Syntax.inline_attrs`, both booleans defaulting to
false, each claiming that a node of that level carrying attributes, printed
through the format's renderer, reparses to the same kind with the attributes
intact. Measured in `languages/harness.zig` per table, as
`names_leaf_containers` is, with a paragraph carrying a class, an id and a
`data-` key. Markdown's table set gains an axis per extension that moves the
answer; at four flags the nested-array derivation in `markdown/syntax.zig`
wants to become a flag-set key, which is a refactor the fourth axis pays for
rather than a cost of this proposal.

`supports(.set_block_attrs)` and `supports(.wrap_range_attrs)` read those
fields. Two gesture codes, 27 and 28, in the C header; two methods on the
Rust `Editor`.

## The Markdown decision

Markdown has to gain a spelling, and the question is which. The bar is the
one every extension has met: a widely read spelling, or none. Three are on
the table.

**A `:::div{.center}` wrap under `directives`.** Needs no parser change and
works today. Rejected: it invents a name, it is a container *around* the
paragraph rather than an attribute *on* it (so a djot `{.center}` and its
Markdown "equivalent" are different trees), and it costs three lines per
aligned paragraph.

**djot's attribute line, `{.center}` above the block.** The smallest change
and byte-identical to djot. Rejected as the *block* spelling: no other
Markdown reader has it, and where it is not read it renders as a visible
line of braces above every styled paragraph. An extension that degrades to
junk in every other renderer is not one to write into people's documents.

**pandoc's fenced div and bracketed span.** `::: {.center}` … `:::` for a
block and `[text]{.large}` for a run. Both are read by pandoc and its
descendants; the fenced div is exactly the anonymous `:::` twig's Markdown
serializer already writes for a djot div (minus the attributes it drops),
and the bracketed span is byte-identical to djot's, so the inline case has
one spelling across both lightweight formats. Where they are not read, the
fence degrades as every directive already does and the span degrades to the
text in brackets. **Recommended.**

The consequence to accept: a Markdown paragraph's alignment is a fenced div
around it, which is a container with a class rather than a class on a
paragraph. So `setBlockAttrs` in Markdown wraps the block in an anonymous
fenced div carrying the attributes, or edits that div's attributes when the
caret's block is its sole child; and the Markdown serializer, converting a
djot `para{.center}`, writes the same wrap instead of dropping the class.
Reading back, the two trees differ by one container. A consumer that wants
"this paragraph's attributes" asks for the attributes of the block or of the
anonymous div whose only child it is, and leaf's walker already folds a
directive container to a panel, so the fold is a rule it has.

Where the spellings live: the anonymous fence is the `:::` grammar and
belongs under `directives`, which today insists on a name and should stop
insisting. The bracketed span is new grammar and gets its own flag,
`bracketed_spans`, off by default, since `[text]` followed by `{` is
plausible prose that CommonMark reads as text and a shortcut reference where
`[text]:` is defined.

## Fidelity

Attributes become an axis of `diagnostics.zig`, which reserved the place.
`nodeFidelity` reports, per target, when a node's attributes will not survive
the conversion — a `style` key to AsciiDoc, everything to Markdown until the
serializer learns the wrap, everything to XML — as `degraded` with the keys
named. That is the honest form of the loss the tables above found, and it
lands first because it is true whether or not the gestures do.

## Sequence

1. Diagnostics: attribute loss reported per target. No serializer changes.
2. Markdown serializer: an attributed block, and an anonymous div's own
   attributes, are written as `::: {…}` fences. A `Behavioural-change:`
   trailer — a djot document converted to Markdown gains lines it did not
   have.
3. Markdown parser: the anonymous attributed fence under `directives`;
   `bracketed_spans` as a new extension. `Syntax.block_attrs` /
   `inline_attrs` and the harness contract, with the table-set derivation
   keyed by flag set.
4. `setBlockAttrs`, djot and AsciiDoc first (a line to rewrite), then HTML
   (a render), then Markdown (a wrap).
5. `wrapRangeAttrs`, the four formats together — the spellings all exist.
6. `supports`, the C ABI, the Rust binding, each in the step whose gesture
   it exposes.

## What this does not do

- It does not give twig a vocabulary. No key or class name means anything
  to twig, before or after.
- It does not parse CSS. A `style` value is a string.
- It does not add attributes to a kind that has no spelling for them in the
  source format — a Markdown heading's `{#id}` (pandoc's `header_attributes`)
  is a natural fourth flag and is left for whoever needs it.
- It does not decide leaf's class names. That is leaf's proposal, with its
  own theme mapping and its own stylesheet, and it can be written once the
  first two steps here have landed.

## Cost

Step 2 changes what an existing conversion produces. Step 3 grows the
Markdown syntax-table set, which is the moment to change how it is derived.
The two gestures are new surface in three languages, each measured before it
is claimed, which is the cost `insertDirective` has just paid and the pattern
it leaves behind.
