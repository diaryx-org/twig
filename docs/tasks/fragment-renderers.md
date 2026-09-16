---
title: Fragment renderers on the format, where an alphabet cannot spell the edit
description: `Syntax` is inert bytes plus one smuggled function pointer, and two proposals have already hit its ceiling — `insertLiteral` is `null` for HTML because HTML escapes with entities, and no block element can be authored in HTML because a heading there is not a leading marker; the fix is a `render` verb the format supplies and the editor calls
author: adammharris
created: 2026-09-15
updated: 2026-09-15
status: done
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# Fragment renderers on the format, where an alphabet cannot spell the edit

## Resolution

Completed in the commit `feat(syntax): fragment renderers on the format, where
an alphabet cannot spell the edit`, which also sets this status. `Syntax`
carries a "Renderers" section of three function-valued fields — `renderText`,
`renderBlock`, and `spellsAutolink` moved beside them — dispatched by presence
like every alphabet.

- `renderText(syntax, text, position, *Writer)`, with `TextPosition` one of
  `inline_text`, `block_start`, `verbatim`. The editor computes the position
  and slices the run so no format re-derives where a line starts. Markdown,
  djot and AsciiDoc share `syntax.renderTextByAlphabet`, which reads
  `text_escapes`/`block_start_escapes` — the backslash rule moved out of
  `editor.zig` and the alphabets stayed data; `assertCoherent` pins an alphabet
  to that renderer and no other. HTML writes entities, and `insertLiteral` over
  an HTML document reparses to the same `str`. The `verbatim` position is new:
  inside a code span, code block or raw node the alphabet formats write the run
  raw, where they used to write an escape that showed its backslash.
- `renderBlock(allocator, ast, root, *Writer)`. HTML's is `serializeNode`; the
  other three are `syntax.renderBlockVia(serializeAstAlloc)`. `setBlock` keeps
  the marker path wherever `heading_marker` exists and takes the render path
  otherwise: clone the block's inline children under a fresh `heading`/`para`
  (`Builder.graftSubtree`), print, splice. `<p class="lead">a <em>b</em></p>`
  becomes `<h2 class="lead">a <em>b</em></h2>`, and a blank line opens
  `<h2></h2>`.
- `languages/harness.zig` states the two contracts over every format that
  declares a renderer: a specials run inserted through `renderText` reparses
  to itself with no markup minted, and a heading fragment printed through
  `renderBlock` reparses to that heading.

One deviation from the "done when" below: there is no alphabet fallback in the
editor. A format spells a literal through `renderText` or not at all, and the
alphabet formats opt in by naming the shared renderer — one question asked of
every format rather than two mechanisms for one gesture. No format's output
moved, except the verbatim case above.

**Where.** `src/syntax.zig` is deliberately data: `Delims` per inline kind,
leading markers per block kind, escape alphabets. The *algorithms* — walk the
text emitting a backslash before a byte from the alphabet, prefix each line
of a covered block, rewrite a leading marker — live once in
`src/ast/editor.zig`. One behaviour is already smuggled in as a function
pointer, `spellsAutolink`, because it has to run the format's own scanner.

Two proposals record the ceiling of that design:

- [Format-correct literal text insertion](/docs/proposals/literal-text-insertion.md)'s
  update: `text_escapes` and `block_start_escapes` are `null` for HTML, and
  `insertLiteral` refuses, not because HTML is unauthorable but because the
  editor's algorithm is "backslash before a byte" and HTML escapes with
  entities. `null` is the honest entry for a mechanism that cannot fit.
- [Editable HTML block elements](/docs/proposals/editable-html-block-elements.md)
  (open): every block construct an editor would insert is unspellable in
  HTML, because `setBlock` rewrites a leading marker and `<h2>` is not one.

Fig hit the same wall. Its last per-format hooks were the spellings that are
not a table, and the answer was a small set of named fragment renderers
(`renderValue`, `renderEntry`, `renderItem`, `renderKey`, `renderTail`)
dispatched by presence, with the engine computing the context — what the
bare-literal rules make of the text — so no format restates the rule.

**Done when** `Syntax` (or the `registry` row beside it) carries:

- `renderText: ?*const fn (text, ctx, *Writer)` — the format spells literal
  text in the given position (inline, block start, inside verbatim). Markdown
  and djot move their backslash rule out of the editor and into this; HTML
  writes entities; `insertLiteral` on an HTML document succeeds and its
  reparse gives back the same `str`.
- `renderBlock: ?*const fn (*const AST, root, *Writer)` — the format spells
  a fragment. For every format with `serializeFromAst` the default is that
  serializer over the fragment, which is what makes "make this line a
  heading in HTML" *build a heading node, render it, splice*.
- `spellsAutolink` folded into the same family rather than standing alone.

The editor's algorithms stay where they are; a `null` renderer means the
editor falls back to the alphabet as today, so no format's current behaviour
moves until it opts in. Closing this closes the mechanism half of the HTML
block-elements proposal; which elements to expose stays that proposal's
question.
