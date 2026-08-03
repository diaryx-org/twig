---
title: "Proposal: a twig-native document markup language"
status: deferred
author: adammharris
created: 2026-08-03
---

# A twig-native document markup language

## Deferred (2026-08-03): sequencing

Held pending reStructuredText support. The reasoning is asymmetric risk: a
parser is additive and cheap to be wrong about, while a published surface syntax
is neither. Once `.sprig` files exist on disk, Part 6's inline family and Part
8's `Syntax` table are the parts that cannot be walked back — and they are
exactly what an AST expansion would invalidate. If `directive` grows an argument
slot, the `:::name` spelling has to change with it.

rST is the right next format because it pushes on this proposal's weakest
areas. What it will demand that the AST does not have today:

- **Directive arity.** rST directives are three slots — arguments, options,
  content (`.. image:: foo.png` + `:width: 50%` + body). `directive{form, name}`
  has name + attrs + children and no argument position. Most likely thing to
  reshape the `:::` family (Part 5).
- **Grid-table cell spans.** `cell{head, alignment}` has no rowspan/colspan.
  rST grid tables have both — as does HTML, so this gap is already costing the
  HTML side silently.
- **Field lists.** `:author: X` serves as both document metadata and directive
  options: Parts 3 and 4 arriving from a second direction, with a real-world
  shape to test against.
- Substitutions (`|name|`), line blocks, option lists, and citations as a
  namespace separate from footnotes — where DESIGN.md's "no citations" scope
  line needs restating rather than merely holding.

**Parts 3 and 4 are not deferred.** The metadata block and fig-backed
attributes are format-independent, and rST *needs* them — field lists and
directive options are attribute data with nowhere to live in `Attrs` today.
Landing that work as part of rST is strictly better than landing it
speculatively for a language that does not yet exist: it gets a real consumer
validating the design. The `Attrs.lang` / `Attrs.span` change (Part 4) goes with
it.

Working order: attribute/metadata infrastructure → rST → revisit the surface
syntax against a larger, tested AST.

Two things that would flip this. If Leaf needs a canonical on-disk save format
sooner than rST can land, that is a real deadline this proposal is on and rST is
not. And rST needs a scope line drawn up front — docutils core only; Sphinx's
directive and role ecosystem is unbounded, and "support rST" becomes "support
Sphinx" without one.

## Summary

Twig parses four languages it did not design. Each one arrived with a fixed
surface syntax and a fixed set of things it cannot say, and twig absorbs that
raggedness as `null`s: djot cannot spell a document-metadata block, cannot spell
an in-cell hard break (`languages/djot/syntax.zig:65`), and cannot spell a bare
attribute (`ast/ast.zig`'s `KeyVal` doc); Markdown cannot spell `mark`,
`insert`, `delete`, `superscript`, or `subscript`; HTML and XML cannot be
authored into at all.

The shared `AST` is therefore strictly larger than any single language twig
supports. **No format twig reads can hold a twig tree.** That is the gap this
proposal closes: a native language whose reason to exist is that the AST is its
specification, not an approximation of it.

The design goals, restated as testable claims:

1. **Fits the AST.** Every `Node.Kind` a semantic parser can produce has exactly
   one spelling, and every `Syntax` field is non-`null`. Round-trip is a
   property test, not a corpus of HTML expectations.
2. **Native metadata.** A first-class, non-rendering document header, in a real
   configuration language.
3. **Attributes in a config language, not a bespoke one.** `fig` already parses
   JSON, YAML, TOML, and fig. Twig should not ship a second, worse key-value
   grammar just for `{...}`.
4. **Cohesive, not accreted.** One rule per question, applied without exception.
5. **Learns from djot.** Djot got most of this right; the changes below are
   surgical, and each one pays for itself in the `Syntax` table.

---

## Part 1 — What the AST already decides

These are not open questions. The AST and the editor surface constrain the
language before any aesthetic choice is made.

**Headings must be ATX.** `Syntax.heading_marker` is a single `u8`, repeated
`level` times (`syntax.zig:131`). `Editor.setBlock` rewrites a leading marker
run. A setext heading — a line whose meaning is decided by the line *after* it —
cannot be expressed in that field at all. So: `#` × level, no alternative form.
Markdown's dual spelling was always a mistake; here it is a type error.

**Containers must have a per-line prefix.** `ContainerSpelling` is
`{marker, cont, blank, numbered}` — a container is authorable only if it can be
applied by prefixing every line of a covered block. Block quotes and lists
qualify. Any construct that wraps a region *without* a per-line marker (a `:::`
fence) is outside the toolbar's reach by construction, and that is fine — but it
means the fence family and the prefix family are genuinely different animals,
and the language should not pretend otherwise.

**Attributes are an ordered, flat list of string pairs.** `Attrs.entries` is
`[]const KeyVal`, `value: ?[]const u8`, order-preserving, `class` accumulating
at its first occurrence. A nested config value has nowhere to live. This is the
one place where goal 3 collides with the current AST — see "Attributes" below
for the resolution and the one additive change it needs.

**The first child of a `table` is always a `caption`.** So a caption needs a
spelling even when empty (djot's `^ ` line, kept).

**`section` is synthesized, never written.** Heading-implied nesting stays a
parser behaviour, exactly as in djot.

---

## Part 2 — Design principles

**P1. One construct, one spelling.** No format has two ways to write the same
node. This is the single biggest lesson from Markdown, which has two heading
forms, two code-block forms, three bullet markers with no semantic difference,
two emphasis characters with no semantic difference, and two link-reference
styles. (Bullet markers survive only because `BulletListStyle` makes the choice
*semantic* — the AST records which one you used.)

**P2. Block structure is decidable one line at a time.** No lookahead past the
current line, no lazy continuation, no reinterpretation of an already-closed
block. A line's block role is a function of its prefix and the open container
stack. This kills setext headings, Markdown's lazy paragraph continuation, and
the "is this a list or a paragraph?" backtracking that makes CommonMark parsers
what they are.

**P3. Indentation is structure, never content.** No indented code blocks. Four
spaces means "continue the enclosing container", full stop. Tabs are rejected
with a diagnostic rather than silently expanded — the tab-width question has no
right answer and twig should not pick one.

**P4. Invisible syntax is not syntax.** No two-space hard break. Every construct
is visible in a diff.

**P5. Frequency decides bareness.** A construct earns bare punctuation only if
it is common enough to justify the cost it imposes on the escape alphabet.
Everything rarer goes inside braces. This is the rule that reshapes djot's
inline family (Part 4) and it is what makes the WYSIWYG story work.

**P6. Configuration is one language, used everywhere.** The metadata block, the
attribute block, and the parse options are the same vocabulary at three scales.

**P7. Extensions are declared by the document, not the invocation.** DESIGN.md's
mission says "extensions off by default". In Markdown that promise is
unkeepable, because the same bytes mean different things under different
`ParseOptions` and the file does not say which it wants. Here the document
carries its own switches in its metadata header, so a twig-native file means one
thing everywhere. This is the structural fix for Markdown's fragmentation.

---

## Part 3 — The metadata block

A fence of three or more `+`, optionally tagged with a configuration language,
closed by a fence of at least the opening length:

```
+++
title = Twig
authors = [adammharris]
+++

# Body starts here
```

```
+++toml
title = "Twig"
+++
```

- **Default language is `fig`** when the tag is absent. The tag is stored
  verbatim in `metadata.lang`, so `+++yaml`, `+++toml`, `+++json`, `+++figl`
  all round-trip as written — the existing `metadata{lang, text}` node already
  has exactly this contract, and the HTML printer's `application/<lang>` data
  island keeps working unchanged.
- **Position is front, end, or both**, matching what the Markdown parser
  already does. Multiple blocks merge into one doc-level record, last-wins per
  key. (The AST comment at `ast/ast.zig` already anticipates this hoist.)
- **It is not markup and never renders into the body.** Already the node's
  defined semantics.

Why `+++` and not `---`: `---` is now free to mean exactly one thing (a thematic
break, Part 5), and the `+++` fence is the same shape as every other block fence
in the language — *three or more of a marker character, an optional tag, a
matching closer*. One rule, four fences (Part 5).

### Reserved keys

A small reserved namespace configures the parse itself (P7):

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `smart` | bool | `false` | Enable `smart_punctuation`, `double_quoted`, `single_quoted` |
| `math` | bool | `true` | Enable `$` math inlines |
| `attrs.lang` | string | `fig` | Config language for `{...}` blocks |
| `dialect` | string | — | Reserved for future opt-in surface extensions |

Everything else is the author's. A reader that does not understand a reserved
key must not guess; it reports a diagnostic and parses with the default.

---

## Part 4 — Attributes

### Syntax

The brace block is kept from djot, because it is genuinely good: it attaches
uniformly, it reads as an aside, and it already has a home in the AST. What
changes is what is *inside* it.

```
{#intro .lead .wide  lang = en  data.count = 3  disabled}
```

The contents are parsed by **fig, in its inline form** — the same parser, the
same quoting and escaping rules, the same number and string grammar as the
metadata block. Djot's shorthands survive as sugar because they are worth their
weight:

- `#name` → the `id` key
- `.name` → appended to `class`, space-joined, at the position of its first
  occurrence (the existing `Attrs` contract, unchanged)
- a bare word with no `=` → a **bare attribute**, `KeyVal{value: null}` — the
  thing djot cannot spell and HTML needs

A tagged form selects another language when the author wants one:

```
{toml: id = "intro", class = "lead" }
```

### The flattening rule

`Attrs.entries` is flat strings, but a config language admits nested tables and
arrays. The rule:

- **Scalars** stringify to their source spelling.
- **Nested tables** flatten to dotted keys (`data.count = 3` →
  `KeyVal{"data.count", "3"}`). Both fig and TOML spell dotted keys natively, so
  this is not a twig invention leaking into the file.
- **Arrays** join with a space when the target key is `class`, and otherwise
  serialize back to their source spelling as a single string value.

This is a *projection*, and projections lose things. To keep the round-trip
lossless the `Attrs` side table gains two additive fields:

```zig
pub const Attrs = struct {
    entries: []const KeyVal = &.{},
    /// The config language the block was written in, as tagged; `null` = the
    /// document default. Round-trips the `{toml: ...}` form.
    lang: ?[]const u8 = null,
    /// The source span of the `{...}` block, so a serializer can re-emit the
    /// author's exact bytes rather than the flattened projection.
    span: ?Span = null,
};
```

Both default to the current behaviour, so no existing language module changes.
The serializer prefers `span` when the entries are untouched and falls back to
emitting the projection when an edit has invalidated it — the same "lossless by
default, reflow only what you edited" rule the `Splicer` already follows.

**This is the only AST change the proposal requires.**

---

## Part 5 — Blocks

Four fence families, one rule: **three or more of the marker, an optional tag, a
closer of at least the opening length.** Every block may be preceded by a
standalone `{...}` line carrying its attributes.

| Marker | Node | Example |
|--------|------|---------|
| `` ``` `` | `code_block` / `raw_block` | ` ```zig ` / ` ```=html ` |
| `+++` | `metadata` | `+++toml` |
| `:::` | `div` (untagged) / `directive` (tagged) | `:::` / `:::note` |
| `$$$` | `display_math` | — |

Line-prefix blocks:

| Prefix | Node |
|--------|------|
| `#`…`######` + space | `heading{level}` (implies `section` nesting) |
| `>` + space | `block_quote` |
| `-` / `+` / `*` + space | `bullet_list` + `list_item` (marker recorded as `BulletListStyle`) |
| `1.` `1)` `(1)` `a.` `i.` … | `ordered_list` + `list_item` (`OrderedListStyle`) |
| `- [ ]` / `- [x]` | `task_list` + `task_list_item{checked}` |
| `: ` under a term line | `definition_list` / `term` / `definition` |
| `[^label]: ` | `footnote` |
| `[label]: dest` | `reference` |
| `\|` … `\|` | `table` / `row` / `cell` |
| `^` + space | `caption` |
| `---` (exactly three, alone on a line) | `thematic_break` |

`---` is the payoff for dropping setext headings and YAML-delimited frontmatter:
after thirty years of Markdown it finally has one meaning.

### Directives absorb divs

Markdown's generic-directive proposal and djot's div are the same construct at
different arities, and twig's AST carries both (`div`, `directive{form, name}`).
Unify them on the colon family:

- `:::` (untagged fence) → `div`
- `:::name{...}` (tagged fence) → `directive{.container, name}`
- `::name[label]{...}` (one line) → `directive{.leaf, name}`
- `:name[label]{...}` (inline) → `directive{.text, name}`
- `:name:` (inline) → `symb`

`symb` and the inline directive are disambiguated by a single character of
lookahead after the name — `:` closes a symbol, `[` or `{` opens a directive.
Deterministic, no backtracking (P2).

### Lists

A list item's content column is set by its marker, and continuation lines must
reach that column. No lazy continuation. A blank line makes the list loose
(`tight: false`); it never terminates it. Changing marker style starts a new
list, because the AST records the style.

---

## Part 6 — Inlines

P5 in action. The core three stay bare because they are what people actually
type; everything else moves inside braces, uniformly:

| Spelling | Node | vs djot |
|----------|------|---------|
| `*strong*` | `strong` | same |
| `_emph_` | `emph` | same |
| `` `verbatim` `` | `verbatim` | same |
| `{=mark=}` | `mark` | same |
| `{+insert+}` | `insert` | same |
| `{-delete-}` | `delete` | same |
| `{^sup^}` | `superscript` | **changed** from `^sup^` |
| `{~sub~}` | `subscript` | **changed** from `~sub~` |
| `{% comment %}` | `comment` | same |
| `[text](dest)` / `[text][ref]` | `link` | same |
| `![alt](dest)` | `image` | same |
| `[text]{...}` | `span` | same |
| `<https://…>` / `<a@b.dev>` | `url` / `email` | same |
| `` $`x` `` / `` $$`x` `` | `inline_math` / `display_math` | same |
| `` `x`{=html} `` | `raw_inline` | same |
| `:name:` | `symb` | same |
| `\` at end of line **or cell** | `hard_break` | **extended** |
| `\` + space | `non_breaking_space` | same |
| newline | `soft_break` | same |

### Why `^`/`~` move into braces

Because the escape alphabet is the WYSIWYG budget. Djot's is eighteen characters
(`syntax.zig` in the djot module):

```
\[]*_^`~"'-.:{}=+<
```

Under this design, with `smart` off by default (P7) and `^`/`~` braced:

```
\*_`[]{<$:!
```

Eleven characters, and the four that hurt most in ordinary prose — `"`, `'`,
`-`, `.` — are gone entirely. `insertLiteral` in Leaf's Hidden mode stops
peppering the source with `\-` and `\.` for text that was never going to become
markup. `=` and `+` drop out too: they are only meaningful *after* a `{`, which
is already escaped. That is a large, concrete win bought with two characters of
extra typing on two rare constructs.

### The in-cell hard break

Djot's gap, closed without a new character. The rule is stated positionally
rather than per-context:

> A `\` immediately before the end of its line is a hard break. Inside a table
> cell — where the row *is* the line — the cell's closing `|` is the end of the
> line for this purpose.

So `| a \| b |`… no: the closing pipe of the cell terminates it, and a `\`
directly before that pipe is a hard break. One rule, two positions, and
`Syntax.cell_line_break = "\\"` is finally non-`null` for a language twig
actually owns. The `in-cell-line-breaks.md` proposal's option C (a house dialect
escape hatch) becomes unnecessary: the native language just has the construct.

---

## Part 7 — Coverage

Every kind a semantic parser produces, and its spelling:

**Spelled natively (complete):** `doc`, `para`, `heading`, `thematic_break`,
`section` (synthesized), `div`, `code_block`, `raw_block`, `metadata`,
`block_quote`, `bullet_list`, `ordered_list`, `task_list`, `definition_list`,
`table`, `list_item`, `task_list_item`, `definition_list_item`, `term`,
`definition`, `row`, `cell`, `caption`, `footnote`, `reference`, `str`,
`soft_break`, `hard_break`, `non_breaking_space`, `symb`, `verbatim`,
`raw_inline`, `inline_math`, `display_math`, `url`, `email`,
`footnote_reference`, `smart_punctuation`, `emph`, `strong`, `link`, `image`,
`span`, `mark`, `superscript`, `subscript`, `insert`, `delete`,
`double_quoted`, `single_quoted`, `directive`, `comment`.

**Not spelled natively:** `element`, `doctype`, `processing_instruction`,
`cdata`.

These four are the generic-markup escape hatch — they exist so HTML and XML can
fall back when no semantic mapping exists, and inventing a native syntax for
"an arbitrary foreign element" would import exactly the ambiguity (P1, P2) that
raw HTML inflicted on Markdown. They are reachable through `raw_block` /
`raw_inline` with an explicit `=html` / `=xml` format tag, which is honest: the
content is foreign, and it says so.

The consequence is worth stating plainly: **HTML → twig-native is lossy for
generic elements** (they become raw blocks), while **djot → twig-native and
Markdown → twig-native are lossless**. If full-AST interchange later becomes a
goal in its own right, the right answer is a sigil'd generic form
(`:::!video{...}`), not a native `<tag>` syntax. Deferred, not foreclosed — see
open questions.

---

## Part 8 — The `Syntax` table

The point of the whole exercise: no `null`s.

```zig
pub const table: syntax.Syntax = .{
    .inline_delims = .init(.{
        .strong      = .{ .open = "*",  .close = "*" },
        .emph        = .{ .open = "_",  .close = "_" },
        .verbatim    = .{ .open = "`",  .close = "`" },
        .mark        = .{ .open = "{=", .close = "=}" },
        .insert      = .{ .open = "{+", .close = "+}" },
        .delete      = .{ .open = "{-", .close = "-}" },
        .superscript = .{ .open = "{^", .close = "^}" },
        .subscript   = .{ .open = "{~", .close = "~}" },
    }),
    .container_spelling = .init(.{
        .block_quote  = .{ .marker = "> ", .cont = "> ", .blank = ">" },
        .bullet_list  = .{ .marker = "- ", .cont = "  ", .blank = "" },
        .ordered_list = .{ .marker = "",   .cont = "",   .blank = "", .numbered = true },
    }),
    .heading_marker = '#',
    .link_text_escapes = "\\[]*_`{<",
    .link_dest_escapes = .{ .plain = "\\()[`", .angle = .{ .escapes = "\\<>" } },
    .text_escapes = "\\*_`[]{<$:!",
    .block_start_escapes = "#>|-+^",
    .spellsAutolink = spellsAutolink,
    .cell_line_break = "\\",
};
```

`text_escapes` and `block_start_escapes` are the two fields most likely to shift
during implementation; they should be *derived* from a fuzz test (Part 9), not
hand-tuned, since `assertCoherent` only checks their null-ness and nothing
checks their contents today.

---

## Part 9 — Conformance

Djot and CommonMark are specified by corpora of HTML expectations, which is why
twig's djot suite has six cases it cannot use (they assert against djot.js's
internal AST dump). A language whose specification *is* the AST should be tested
against the AST:

1. **`parse(serialize(ast)) == ast`**, over a generated corpus covering every
   `Node.Kind` and every payload variant. This is the primary bar. It is a
   property, so it can be fuzzed, and it catches exactly the class of bug the
   escape alphabets exist to prevent.
2. **`serialize(parse(src)) == src`** for a curated corpus of idiomatic source —
   stricter than (1), and only expected to hold for canonically-formatted input.
3. **`parse(insertLiteral(s)) == str(s)`** for arbitrary `s`, fuzzed. This is
   what actually validates `text_escapes` and `block_start_escapes`, and it
   should be run for djot and Markdown too — the alphabets there are currently
   asserted only by inspection.
4. **HTML rendering** as a secondary corpus, for humans comparing against djot.

---

## Part 10 — Implementation

Follows the existing convention exactly — `src/languages/twig/` with
`parser.zig`, `serializer.zig`, `syntax.zig`, `html.zig`, `block.zig`,
`inline.zig`, `conformance.zig`, and a `twig.zig` aggregating the sibling
`test {}` blocks. One `Format` enum variant, one `registry` entry with every
optional field populated, one `Syntax` literal.

Suggested order, each step independently useful:

1. `metadata` block + fig-backed attribute parsing. Lands the two goals with no
   dependency on the rest, and the attribute work is shared with a possible
   djot-side improvement.
2. Block grammar (the fence families and the prefix families), rendering to HTML.
3. Inline grammar and the escape alphabets, with the Part 9 fuzz harness.
4. Serializer, then property test (1) turns on.
5. `Attrs.lang` / `Attrs.span` and the lossless attribute re-emit.

Most of the block and inline machinery is a simplification of the djot module
rather than new work: this language is deliberately a subset-plus-corrections of
djot's shape, so the parser can be built by copying `languages/djot/` and
*deleting* — no setext path, no lazy continuation, no indented code, no
smart-punctuation state machine in the default configuration.

---

## Open questions

1. **Name and extension.** The natural name is Twig, which collides with the
   tool and, more practically, with PHP's Twig for `.twig` in editors and
   syntax-highlighting registries. Options: `.twig` and accept the collision;
   `.tw` (collides with Twee); or give the language its own name in the
   fig/twig family — `sprig`, `.sprig`. **Recommendation: `sprig`.** The
   tool/language distinction is worth having anyway, and it keeps
   "twig converts sprig" readable.
2. **Full-AST interchange as a goal.** Should `element` get the `:::!name`
   sigil form so a twig-native file can hold *any* twig tree losslessly? It is
   a real feature (a canonical on-disk format for the editor) and a real cost
   (a construct with no rendering semantics). Recommend deferring until the
   editor actually wants a save format.
3. **`fig` inline-form dependency.** Does `fig` expose an inline/one-line parse
   entry point suitable for `{...}` contents, or does twig need a small
   scalar-only subset parser to avoid the dependency? This gates step 1 and is
   the first thing to check.
4. **Should djot's `^`/`~` change be backported?** No — djot is djot, and twig
   parses it as specified. But it is worth confirming the two languages'
   `Syntax` tables are allowed to disagree this visibly.
5. **Tabs.** Rejected with a diagnostic (P3) is the cohesive answer, but it is
   the first thing a user will hit by accident. Silent conversion to the
   container's content column is the pragmatic alternative.
