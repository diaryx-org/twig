"""The authored AsciiDoc conformance cases — see `build-asciidoc-corpus.py`.

Cases are grouped by construct and named on the TCK's own path convention
(`block/<construct>/<variant>/<case>`), so they slot into its `tests/` tree
unchanged when exported. Each group's comment records where its expectation
comes from: a page of the AsciiDoc Language documentation, a section of the
(short) normative spec, or — where both are silent — Asciidoctor's behaviour,
called out as such.

The builders are injected by `define(...)` rather than imported, so this file
has no import cycle with the machinery and no global state of its own.
"""


def define(*, case, doc, header, para, leaf, parent, section, heading, ulist,
           olist, colist, item, dlist, ditem, brk, macro, text, span, lines):

    # ── paragraphs ──────────────────────────────────────────────────────────
    # docs/modules/blocks/pages/paragraph.adoc. The TCK covers the single-line,
    # hard-wrapped and blank-separated shapes; what it leaves open is what
    # happens around the edges of a paragraph — leading blank lines, trailing
    # blank lines, and interior whitespace — all of which are span questions
    # rather than tree questions, and all of which twig's parser answers by
    # "the paragraph is exactly its non-blank lines".

    case(
        "block/paragraph/leading-blank-lines",
        "\n\nbody\n",
        doc(
            para(text("body"), at=lines(3)),
            at=lines(3),
        ),
        note="A document's location starts at its first block, not at line 1: "
             "leading blank lines are not part of any node.",
    )

    case(
        "block/paragraph/trailing-blank-lines",
        "body\n\n\n",
        doc(
            para(text("body"), at=lines(1)),
            at=lines(1),
        ),
    )

    case(
        "block/paragraph/no-trailing-newline",
        "body",
        doc(
            para(text("body"), at=lines(1)),
            at=lines(1),
        ),
        note="A file with no final newline parses identically to one with it; "
             "the terminating newline is not part of the paragraph's location.",
    )

    case(
        "block/paragraph/three-lines",
        "one\ntwo\nthree\n",
        doc(
            para(text("one\ntwo\nthree"), at=lines(1, 3)),
            at=lines(1, 3),
        ),
        note="A hard-wrapped paragraph is ONE text node whose value carries the "
             "interior newlines verbatim — the TCK's block/paragraph/multiple-lines "
             "establishes this for two lines; nothing changes at three.",
    )

    case(
        "block/paragraph/indented-continuation",
        "one\n  two\n",
        doc(
            para(text("one\n  two"), at=lines(1, 2)),
            at=lines(1, 2),
        ),
        note="Only the FIRST line of a block decides its form, so an indented "
             "second line continues the paragraph rather than opening a literal "
             "block (docs/modules/verbatim/pages/literal-blocks.adoc).",
    )

    # ── sections ────────────────────────────────────────────────────────────
    # docs/modules/sections/pages/titles-and-levels.adoc. A section's level is
    # its `=` count minus one, and a section's location runs from its own title
    # marker through the last line of its last descendant.

    case(
        "block/section/nested-levels",
        "== One\n\n=== Two\n\nbody\n",
        doc(
            section(
                section(
                    para(text("body"), at=lines(5)),
                    title=[text("Two")], level=2, at=lines(3, 5),
                ),
                title=[text("One")], level=1, at=lines(1, 5),
            ),
            at=lines(1, 5),
        ),
    )

    case(
        "block/section/sibling-sections",
        "== One\n\n== Two\n",
        doc(
            section(title=[text("One")], level=1, at=lines(1)),
            section(title=[text("Two")], level=1, at=lines(3)),
            at=lines(1, 3),
        ),
        note="A section with no body has no `blocks` key at all, and its "
             "location ends at its own title.",
    )

    case(
        "block/section/level-skip",
        "== One\n\n==== Deep\n",
        doc(
            section(
                section(title=[text("Deep")], level=3, at=lines(3)),
                title=[text("One")], level=1, at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
        note="An AsciiDoc section's level is spelled directly by its marker, so "
             "a skipped level nests rather than being renumbered. Asciidoctor "
             "warns about this and still nests it; the ASG has no place to "
             "record the warning, so the tree is all that is asserted here.",
    )

    case(
        "block/section/body-before-first-section",
        "intro\n\n== One\n\nbody\n",
        doc(
            para(text("intro"), at=lines(1)),
            section(
                para(text("body"), at=lines(5)),
                title=[text("One")], level=1, at=lines(3, 5),
            ),
            at=lines(1, 5),
        ),
    )

    case(
        "block/section/closes-back-to-shallower",
        "== One\n\n=== Two\n\n== Three\n",
        doc(
            section(
                section(title=[text("Two")], level=2, at=lines(3)),
                title=[text("One")], level=1, at=lines(1, 3),
            ),
            section(title=[text("Three")], level=1, at=lines(5)),
            at=lines(1, 5),
        ),
    )

    # ── the document header ─────────────────────────────────────────────────
    # docs/modules/document/pages/header.adoc. The header is the title plus the
    # attribute entries attached to it; `attributes` is present whenever a
    # header is, even when empty (the TCK's block/document/header-body has
    # `"attributes": {}`).

    case(
        "block/header/title-only",
        "= Title\n",
        doc(header=header(text("Title"), at=lines(1)), attributes={}, at=lines(1)),
    )

    case(
        "block/header/attribute-entry-unset",
        "= Title\n:!toc:\n",
        doc(
            header=header(text("Title"), at=lines(1, 2)),
            attributes={"toc": None},
            at=lines(1, 2),
        ),
        note="`:!name:` UNSETS an attribute. The schema's document `attributes` "
             "map allows a null value precisely for this; an unset entry is not "
             "the same as `:name:` with an empty value.",
    )

    case(
        "block/header/attribute-entry-padded-value",
        "= Title\n:name:   spaced value\n",
        doc(
            header=header(text("Title"), at=lines(1, 2)),
            attributes={"name": "spaced value"},
            at=lines(1, 2),
        ),
        note="The value is trimmed of surrounding whitespace but not internally "
             "(docs/modules/attributes/pages/attribute-entries.adoc).",
    )

    case(
        "block/header/blank-line-ends-header",
        "= Title\n\n:not-an-entry: value\n",
        doc(
            para(text(":not-an-entry: value"), at=lines(3)),
            header=header(text("Title"), at=lines(1)),
            attributes={},
            at=lines(1, 3),
        ),
        note="A blank line closes the header, so what follows is body — an "
             "attribute entry below it is a paragraph, not an entry. (Asciidoctor "
             "does hoist body-level entries into the attribute table; the ASG "
             "models the document TREE, and the line is a paragraph in it.)",
    )

    case(
        "block/header/title-not-at-line-one",
        "body\n\n= Not A Title\n",
        doc(
            para(text("body"), at=lines(1)),
            section(title=[text("Not A Title")], level=0, at=lines(3)),
            at=lines(1, 3),
        ),
        note="A level-0 title below the header is a level-0 SECTION (a part "
             "title), not a second document title.",
    )

    # ── unordered lists ─────────────────────────────────────────────────────
    # docs/modules/lists/pages/unordered.adoc.

    case(
        "block/list/unordered/multiple-items",
        "* one\n* two\n* three\n",
        doc(
            ulist(
                item(text("one"), marker="*", at=lines(1)),
                item(text("two"), marker="*", at=lines(2)),
                item(text("three"), marker="*", at=lines(3)),
                marker="*", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
    )

    case(
        "block/list/unordered/dash-marker",
        "- one\n- two\n",
        doc(
            ulist(
                item(text("one"), marker="-", at=lines(1)),
                item(text("two"), marker="-", at=lines(2)),
                marker="-", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
        note="The marker is carried as written; `-` and `*` are the same "
             "unordered variant with different markers.",
    )

    case(
        "block/list/unordered/blank-line-between-items",
        "* one\n\n* two\n",
        doc(
            ulist(
                item(text("one"), marker="*", at=lines(1)),
                item(text("two"), marker="*", at=lines(3)),
                marker="*", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
        note="A single blank line between items does NOT end the list "
             "(docs/modules/lists/pages/build-a-list.adoc); it only makes the "
             "list loose, which the ASG does not record.",
    )

    case(
        "block/list/unordered/paragraph-after-list",
        "* one\n\nbody\n",
        doc(
            ulist(item(text("one"), marker="*", at=lines(1)), marker="*", at=lines(1)),
            para(text("body"), at=lines(3)),
            at=lines(1, 3),
        ),
    )

    case(
        "block/list/unordered/marker-change-starts-new-list",
        "* one\n- two\n",
        doc(
            ulist(item(text("one"), marker="*", at=lines(1)), marker="*", at=lines(1)),
            ulist(item(text("two"), marker="-", at=lines(2)), marker="-", at=lines(2)),
            at=lines(1, 2),
        ),
        note="A different marker character at the same level begins a sibling "
             "list rather than continuing the first "
             "(docs/modules/lists/pages/unordered.adoc — 'to nest, change the "
             "marker'). Asciidoctor instead NESTS the second list; twig follows "
             "the documentation's flat reading, which is also what the ASG's "
             "`marker` field per list implies.",
    )

    case(
        "block/list/unordered/wrapped-principal-text",
        "* one\n  continued\n",
        doc(
            ulist(
                item(text("one\n  continued"), marker="*", at=lines(1, 2)),
                marker="*", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
        note="An item's principal text continues onto following indented lines, "
             "newlines and indentation preserved verbatim, exactly as a "
             "hard-wrapped paragraph's are.",
    )

    # ── listing blocks ──────────────────────────────────────────────────────
    # docs/modules/verbatim/pages/listing-blocks.adoc.

    case(
        "block/listing/empty",
        "----\n----\n",
        doc(
            leaf("listing", form="delimited", delimiter="----", at=lines(1, 2)),
            at=lines(1, 2),
        ),
        note="An empty listing block has no `inlines` at all (the schema "
             "defaults it to []), not a text node with an empty value.",
    )

    case(
        "block/listing/blank-lines-inside",
        "----\none\n\ntwo\n----\n",
        doc(
            leaf(
                "listing", text("one\n\ntwo"),
                form="delimited", delimiter="----", at=lines(1, 5),
            ),
            at=lines(1, 5),
        ),
        note="A blank line inside a delimited block is content, not a separator.",
    )

    case(
        "block/listing/longer-delimiter",
        "-----\nbody\n-----\n",
        doc(
            leaf(
                "listing", text("body"),
                form="delimited", delimiter="-----", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
        note="A delimiter line is four or more of its character; the closing "
             "line must match the opening one exactly, so `delimiter` is "
             "carried as written.",
    )

    case(
        "block/listing/markup-not-interpreted",
        "----\n*not strong*\n----\n",
        doc(
            leaf(
                "listing", text("*not strong*"),
                form="delimited", delimiter="----", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
    )

    # ── sidebars ────────────────────────────────────────────────────────────
    # docs/modules/blocks/pages/sidebar.adoc.

    case(
        "block/sidebar/containing-paragraphs",
        "****\none\n\ntwo\n****\n",
        doc(
            parent(
                "sidebar",
                para(text("one"), at=lines(2)),
                para(text("two"), at=lines(4)),
                delimiter="****", at=lines(1, 5),
            ),
            at=lines(1, 5),
        ),
    )

    case(
        "block/sidebar/empty",
        "****\n****\n",
        doc(
            parent("sidebar", delimiter="****", at=lines(1, 2)),
            at=lines(1, 2),
        ),
    )

    # ── strong spans ────────────────────────────────────────────────────────
    # spec/modules/ROOT/pages/strong-span.adoc — one of the six pages of the
    # normative spec that are actually written, so these expectations are on
    # firmer ground than most in this file.

    case(
        "block/paragraph/strong-span-mid-line",
        "one *two* three\n",
        doc(
            para(
                text("one "),
                span("strong", text("two"), at="*two*"),
                text(" three"),
                at=lines(1),
            ),
            at=lines(1),
        ),
    )

    case(
        "block/paragraph/strong-span-whole-line",
        "*all of it*\n",
        doc(
            para(span("strong", text("all of it"), at="*all of it*"), at=lines(1)),
            at=lines(1),
        ),
    )

    case(
        "inline/span/strong/not-constrained-by-word-character",
        "a*b*c\n",
        [text("a*b*c")],
        level="inline",
        note="A constrained span's opening delimiter may not follow a word "
             "character, so this is plain text (spec strong-span.adoc).",
    )

    case(
        "inline/span/strong/space-after-opening-delimiter",
        "* not a span*\n",
        [text("* not a span*")],
        level="inline",
        note="A constrained opening delimiter may not be followed by "
             "whitespace. At block level this line would be a list item; as an "
             "inline-level case it is text.",
    )

    case(
        "inline/span/strong/two-spans",
        "*one* and *two*\n",
        [
            span("strong", text("one"), at="*one*"),
            text(" and "),
            span("strong", text("two"), at="*two*"),
        ],
        level="inline",
    )

    case(
        "inline/span/strong/unterminated",
        "*not closed\n",
        [text("*not closed")],
        level="inline",
    )

    case(
        "inline/no-markup/multiple-words",
        "two words\n",
        [text("two words")],
        level="inline",
    )
