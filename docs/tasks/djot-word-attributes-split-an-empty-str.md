---
title: "A djot word's attributes split off an empty `str` when nothing precedes the word"
description: '`hi{key="x"}` parses as an empty `str` over `[0,2]` and then `hi` carrying the attributes; djot.js splits a word from the text before it only when there is text before it.'
author: adammharris
created: 2026-10-02
updated: 2026-10-02
status: open
part_of: '[Tasks](/docs/tasks/tasks.md)'
---

# A djot word's attributes split off an empty `str` when nothing precedes the word

`hi{key="x"}` parses as an empty `str` over `[0,2]` and then `hi` carrying the attributes; djot.js splits a word from the text before it only when there is text before it.

## Repro

`printf 'hi{key="x"}\n' | twig lang table -i djot -` gives, under the paragraph,
`{"kind":"str","span":[0,2],"text":""}` and then
`{"kind":"str","span":[0,2],"text":"hi","attrs":[…]}`. djot.js 0.3.2 gives the
one `str` with the attributes. Found by `twig-quickjs`'s djot twin, which
excludes nine cases of djot.js's `attributes.test` for it (lines 25, 39,
47, 60, 66, 72, 80, 217, 223; `twig-quickjs/docs/twin-differences.md`).

## Done when

The single-word split in `src/languages/djot/parser.zig` happens only when
text precedes the word in its `str`, the table above has one `str`, and
djot's samples or conformance tests hold the case.
