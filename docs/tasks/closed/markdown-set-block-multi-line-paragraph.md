---
title: setBlock makes a heading of a Markdown paragraph's first line and leaves the rest a paragraph
description: '`Editor.setBlock(.heading)` over a Markdown paragraph that spans more than one line writes the heading marker before the first line only, and an ATX heading is one line, so the reparse is a heading over the first line and a paragraph over the rest — a success reported over a block that was split.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: done
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
---

# setBlock makes a heading of a Markdown paragraph's first line and leaves the rest a paragraph

Found by the gesture check (`contract.gestures`) run over a runtime language
twinning Markdown with its `math` feature on: the sample's `$$\ny\n$$` is a
paragraph of three lines, and the check's `set_block heading` found no
heading over the paragraph's text. The compiled harness runs the gestures
under default options over samples whose paragraphs are one line each, so it
never met one.

## Repro

Markdown, the source `a\nb\n` — one paragraph, a soft break inside it.

- `setBlock(0, .heading, 2)` writes `## a\nb\n`, which parses as a heading
  over `a` and a paragraph over `b`. It reports success.

The same over djot keeps one heading (`## a\nb` — djot's heading takes the
following line). AsciiDoc refuses with `error.NotEditable`.

## Why

`setBlockByMarker` prefixes the block's content with the marker and keeps
the rest verbatim. That is right where a heading continues onto its next
line, as djot's does, and wrong where it is one line, as Markdown's ATX
heading is. `Syntax` says nothing about which a format's heading is.

## Done when

`setBlock(.heading)` over a multi-line Markdown paragraph either gives one
heading over the paragraph's text — its soft breaks joined, which a heading
renders the same — or refuses with `error.NotEditable`. Whichever it is, the
gesture check passes over a Markdown sample with a multi-line paragraph, and
`Markdown.samples` gains one so the compiled harness holds it.

## Resolution

One heading, its soft breaks joined. `Syntax` now says which kind of heading
a format's marker writes: `heading_continues`, true for djot and left at its
default `false` for Markdown and AsciiDoc. Where it is false,
`setBlockByMarker` writes the paragraph as one line, each soft break (its
span, continuation prefix included) a space, and refuses a hard break or a
line end inside a leaf with `error.NotEditable`. Either way the splice is
kept only if the reparse gives back one heading of the level asked for over
the paragraph's text, so a heading the format reads differently is refused
rather than reported. `Markdown.samples` and djot's gained a paragraph of
several lines, the `mdf` runtime samples are multi-line again, and the
gesture check holds a table claiming `heading_continues` to it.
