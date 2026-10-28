---
title: Djot panics on an attribute block opened in a block quote and left unclosed
part_of: '[Closed tasks](/docs/tasks/closed/closed.md)'
status: done
description: twig_djot::parse panics (slice index starts past its end, parser.rs text_of) on `> {y="\n>  "}`; any parse of such a document, and so any editor over one, aborts.
author: adammharris
created: 2026-10-28
updated: 2026-10-28
---

# Djot panics on an attribute block opened in a block quote and left unclosed

## Repro

```rust
twig_djot::parse(b"> {y=\"\n>  \"}");
```

panics in `TreeBuilder::text_of` (`crates/twig-djot/src/parser.rs`): *slice
index starts at N but ends at N-5*: an event's `end` lies before its
`start`. The attribute block's quoted value runs across the block quote's
`> ` marker; why that gives an inverted event is not yet found.

The editor's reparse after an edit
(`crates/twig/src/ast/reparse_test.rs`, `reparse_soak`) found it in the
djot.js corpus run together under random edits; the soak leaves out an edit
whose whole parse panics, so it does not fail on this. Any parse of such a
document panics, a whole one as much as the fragment one, and so does any
editor over it.

## Done

The source above parses without panicking, and the corpus soak no longer
needs to leave out edits whose whole parse panics.

## Fix

The attribute parser (`crates/twig-djot/src/attributes.rs`) closed a value
continued onto a new line with a piece from that line's first byte fed to the
last byte fed before it. The block parser feeds a block quote's line from past
its `> `, so a quote opening the line gave a piece from 10 to 6. A value
closed at the start of its line now has no piece there. The soak no longer
leaves out edits whose whole parse panics.
