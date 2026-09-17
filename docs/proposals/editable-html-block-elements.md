---
title: "Proposal: editable HTML block elements"
status: implemented
author: adammharris
created: 2026-09-09
updated: 2026-09-16
part_of: '[Proposals](/docs/proposals/proposals.md)'
---

# Editable HTML block elements

## Status

`implemented` on 2026-09-16. Step 1 landed in `feat(html): a raw-text or
rcdata body is the container's payload, not a child`; steps 2–5 in
`feat(editor): the container, code block, link and image gestures print
through the renderer where the alphabet is null`. Two things the sequence
did not foresee: the render path is format-neutral, so AsciiDoc — whose
`dest[text]` link was the other alphabet-shaped refusal — gained `insertLink`
and `insertImage` through the same gate; and the harness contract written
over every renderer caught the Markdown and djot serializers ending a quote
at the blank line between its paragraphs, fixed alongside.

`accepted` on 2026-09-16, on the three decisions below: the bar for a block
element is a Markdown or Djot equivalent; twig tells an editor what its
tokenizer did with an element's body and nothing more; the admitted set needs
no new diagnostic. The MECHANISM half had closed on 2026-09-15 with
[Fragment renderers on the format](/docs/tasks/fragment-renderers.md) —
`Syntax.renderBlock` lets a gesture build a node and have the format print
it, and `Editor.setBlock` takes that path where there is no heading marker.
The work is sequenced at the end.

## The question

`Format::Html` carries a `Syntax` table: seven of the nine inline marks as
tag pairs, `<code>` for verbatim, `<hr>` for a thematic break, `<br>` for the
in-cell break, and — since the renderers — a heading. Every other block
construct an editor would insert, a list and its items, a block quote, a code
fence, a link, is unspellable in HTML today, so a leaf editor over an HTML
document can mark a word bold and make a line a heading, and cannot quote it
or list it.

Three things needed deciding:

- Which block elements twig should let an editor author in HTML.
- How an element-origin `container` should be described to an editor.
- What `diagnostics` should say about a block an editor inserts into HTML
  that the other serializers cannot spell.

## Which elements: the ones with a Markdown or Djot equivalent

The bar is the one the inline marks already met. HTML's table carries seven
of nine marks because those seven are the tags `html/parser.zig` reads BACK
to the same mark, so a toggle reverses; the two it leaves out (the smart
quotes) have no tag. The same test over the blocks admits exactly the set a
Markdown or Djot toolbar has buttons for, because every one of them already
parses back to the semantic kind (`semanticKind` in `html/parser.zig`):

| gesture | element | reads back as |
|---|---|---|
| `toggleBlockContainer(.block_quote)` | `<blockquote>` | `block_quote` |
| `toggleBlockContainer(.bullet_list)` | `<ul>` + `<li>` | `bullet_list` / `list_item` |
| `toggleBlockContainer(.ordered_list)` | `<ol start>` + `<li>` | `ordered_list` / `list_item` |
| `toggleCodeBlock`, `setCodeLanguage` | `<pre><code class="language-x">` | `code_block` |
| `insertLink` | `<a href>` | `link` |
| `insertImage` | `<img src alt>` | `image` |

Each is a `renderBlock` path: the editor builds the node — the covered blocks
under a `block_quote`, each under a `list_item` under a list, the covered
text as a `code_block`'s payload, the selection under a `link` — and the
format prints it, exactly as `setBlock` prints a heading. No new spelling is
added to `html/syntax.zig`; what changes is that each gesture in `editor.zig`
learns the render path it lacked, gated the way `setBlock` is: the marker
alphabet where the format has one, the renderer where it has none.

Deferred by the same bar, each for a stated reason:

- **Definition lists.** Djot has them and HTML spells `<dl>`, but the parser
  does not read `dl`/`dt`/`dd` yet, so the toggle would not reverse. Reading
  them is a parser change first, and this proposal does not make it.
- **Task items.** HTML has no native spelling; `<input type="checkbox">` is a
  form control, not a list marker, and the parser reads it as a container.
- **Footnotes.** No native spelling.
- **Tables.** Already authored by `table_edit.zig` over a parsed table;
  inserting a table from nothing is a gesture no format has yet.

## The `container`: twig states a parse fact, not a judgement

`Form == null` on an HTML element means UNCLASSIFIED, and `AST-KINDS.md`
says why: whether `<video>` is a block "is a property of the stylesheet and
not of the parse." Whether an element is CHROME is the same kind of judgement
one step on — `<header>` inside `<article>` is prose, a `<form>` can be the
whole content of a page — and leaf's own proposal calls its list of chrome
tags "a fixed list, not a judgement about the page." If twig declines to say
block-or-inline it should decline to say chrome-or-prose. The editor keeps
its tag list; that is editorial.

What twig knows and does not currently tell the editor is what its tokenizer
DID with the element's body. `html/parser.zig` reads `script`, `style`,
`iframe`, `xmp`, `noembed`, `noframes` and `plaintext` as raw text and
`title` and `textarea` as rcdata — no markup inside, one run of bytes — but
the result is a `container` whose child is an ordinary `str`, so to a
flat-node consumer `<script>a < b</script>` and `<span>a &lt; b</span>` are
the same shape and differ only in `name`. An editor that steps into the
script and toggles bold writes `<strong>` into JavaScript, and `insertLiteral`
there entity-escapes what must stay raw. That is the one fact leaf cannot
learn without duplicating the tokenizer's tables, and it is the line in
leaf's proposal that is actually twig's ("keeps `<script>` and `<style>` as
raw text").

So: a container whose body the tokenizer read as text carries that body as
its `text` payload — `Container.text`, `null` for every element whose body
is markup — and `Kind.contentModel` answers `.text` for it, the way it does
for `code_block`. Nothing new is invented: `.text` already means "an opaque
payload and no children", `insertChild` already refuses it,
`replaceContent` already works on it, `kindText` in the C ABI already
extracts every `.text` payload and a flat node's `text` is already `Some`
for exactly that set. An editor reads `text != null` on a container and
knows the body is not prose, whichever tag it is.

Nothing else. No "sectioning", no HTML content categories, no "chrome" — not
because they are unknowable but because no gesture reads them yet, and a
classification with no consumer is a table that drifts. `section`, `main`,
`body` and `html` already fold to `section`, which is the one sectioning
signal that has a reader.

Leaf's proposal changes by one line: its atom list splits into what twig
says is opaque (script, style, iframe, title, …) and what leaf says is chrome
(nav, header, footer, form, svg), and the second list is honestly leaf's.

## Diagnostics: nothing new

Every admitted block reparses to a semantic kind, so inserting one into HTML
loses nothing when the document is later serialized as Markdown or Djot — a
`<blockquote>` the editor wrote is a `block_quote` like any other. There is
no new diagnostic for the admitted set, and the deferred set is never
inserted. The existing `diagnostics.zig` fidelity table is unchanged.

## Sequence

1. `Container.text`: the parser stores a raw-text or rcdata body as the
   payload; `contentModel` answers `.text`; the serializers print the payload
   where they printed the child; `eql`, `ast_json`, the C ABI and the Rust
   bindings follow. A `Behavioural-change:` trailer, since a consumer walking
   children of a `<script>` finds none.
2. `toggleBlockContainer` by render — quote, bullet list, ordered list, the
   three toggle-off and convert cases included.
3. `toggleCodeBlock` and `setCodeLanguage` by render.
4. `insertLink` and `insertImage` by render.
5. `Editor.supports` widened to match, so a toolbar over HTML enables what
   now works; `html/syntax.zig`'s pinning tests updated to say the shape
   mismatch is answered by the renderer, not left.
