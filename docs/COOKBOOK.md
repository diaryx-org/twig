---
part_of: '[Twig](/README.md)'
---
# Twig Cookbook — `jq`/`sed` for documents

Twig treats a document the way `jq` treats JSON: locate a node, then act on it.
Four verbs cover almost everything, and they compose over Markdown, Djot, HTML,
and XML with the same selectors.

| verb        | role                          | mutates? |
|-------------|-------------------------------|----------|
| `query`     | **locate** — find nodes       | no       |
| `edit`      | **splice** — one lossless edit| in place |
| `filter`    | **prune** — drop node families| in place |
| `convert`   | whole-document format / AST   | no       |

Every `edit`/`filter` writes back in place; add `--dry-run` to print instead.
Read from stdin with `-` (requires an explicit `-i`, since there's no extension
to sniff). All examples below were run against the real binary.

> Examples use `twig`; if you haven't installed it, use `./zig-out/bin/twig`.

---

## The selector language

A selector is a chain of steps, each `kind` plus optional refinements:

```
heading                     every heading
heading[level=2]            H2s only
heading("Status")           heading whose text contains "Status"
link[dest^="http"]          external links (prefix match)
code[lang=zig]              fenced code, language zig
item[2]                     the 2nd match (0-based nth shorthand)
list > item("dishes")       direct-child combinator
```

Attribute operators: `[k]` present · `[k=v]` equals · `^=` prefix · `$=` suffix ·
`*=` substring · `~=` word. Pseudos: `:nth(k)`, `:contains("…")`. Combinators:
whitespace = descendant, `>` = direct child.

**Kind aliases** save typing: `code` matches `code_block`, `list` matches
`bullet_list`/`ordered_list`. Otherwise kinds are the AST tag names (`heading`,
`para`, `link`, `image`, `block_quote`, `table`, `directive`, …); run
`twig convert -o ast <file>` to see them all.

---

## 1. Inspect (read-only)

```sh
twig query doc.md heading                 # document outline
twig query doc.md 'heading[level=2]'      # just the H2s
twig query doc.md 'link[dest^="http"]'    # every external link
twig query doc.md 'code[lang=zig]'        # every zig code block
twig query doc.md image                   # every image
twig convert -o ast doc.md                # dump the whole tree as JSON
```

Output is one `[index.path]  kind  "preview"` line per match:

```
[1]     heading "Twig"
[5]     heading "Status"
```

That `[5]` path feeds straight into `edit` — copy it verbatim.

---

## 2. Restructure (lossless edits)

The headline feature: an edit rewrites **only the matched node's bytes** and
leaves the rest of the file untouched — no reflow, no reformat.

```sh
# Demote a heading: `# Status` -> `## Status`, everything else byte-identical
twig edit doc.md --replace 'heading("Status")' '## Status'

# Rename a heading's text but keep its level and syntax
twig edit doc.md --replace-content 'heading("Status")' 'Project Status'

# Insert a paragraph after a heading
twig edit doc.md --insert-after 'heading("Intro")' $'\nWelcome.\n'

# Insert a list item at any position (2nd child here; use a large index to
# append). Include the trailing newline; Twig handles the line separator.
twig edit doc.md --insert-child 'list' 1 $'- inserted item\n'

# Delete a node (also tidies the surrounding blank lines)
twig edit doc.md --delete 'heading("Draft")'

# Peel a wrapper, keeping its contents (e.g. a ::: container)
twig edit doc.md --unwrap 'directive[name=note]'
```

A `<path>` is **either** a dot-path (`0.3.1`) **or** a selector that matches
**exactly one** node. An ambiguous selector refuses to guess:

```
$ twig edit doc.md --replace 'heading' 'X'
error: selector 'heading' is ambiguous — 2 nodes match. Refine it, add
:nth(k), or use an index path:
[0]     heading "H1"
[1]     heading "H2"
```

Refine it (`heading("Status")`, `heading[level=2]`, `heading[0]`) or use the
index path.

---

## 3. Prune (drop node families)

```sh
# Strip every image from a file
twig filter doc.md --drop image

# Strip every code block
twig filter doc.md --drop code_block

# Publish only the "public" audience: drop all :::vis blocks except the
# public one, and unwrap the survivor so the marker disappears too
twig filter doc.md --directives \
  --drop 'directive[name=vis]' --keep 'directive[class~=public]' --unwrap
```

`filter` re-parses until it converges, so it cleans up cleanly even where a
single `edit` wouldn't (see Gotchas).

---

## 4. Cross-format

```sh
twig convert doc.md                       # -> HTML (default)
twig convert -o canonical doc.md          # round-trip back to Markdown
twig convert -o canonical feed.xml        # any format with a serializer
twig identify mystery.txt                 # detect the format
```

---

## 5. Batch & compose

Twig has no built-in globbing or piping between nodes — use the shell:

```sh
# Strip images from every post (in place)
for f in posts/*.md; do twig filter "$f" --drop image; done

# Pipe through stdin (no in-place write; prints result)
cat draft.md | twig edit -i markdown - --replace-content 'heading' 'Hello'

# Extract every external link across a repo, tagged by file
for f in **/*.md; do
  twig query "$f" 'link[dest^="http"]' | sed "s|^|$f: |"
done
```

---

## Notes

- **`edit` takes exactly one node.** By design — an ambiguous selector errors
  rather than editing all matches. Loop in the shell for many.
