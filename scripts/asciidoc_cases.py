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
           olist, colist, item, dlist, ditem, brk, macro, text, span, lines,
           meta, ref, charref, raw):

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
        "= Title\n\nbody\n:icons: font\n",
        doc(
            para(text("body\n:icons: font"), at=lines(3, 4)),
            header=header(text("Title"), at=lines(1)),
            attributes={},
            at=lines(1, 4),
        ),
        note="A blank line closes the header, so an entry-shaped line that "
             "follows body text is paragraph text, not a header entry. (A "
             "standalone body-level `:name: value` line is a body attribute "
             "entry — a shape the ASG does not model, so twig's `attributeEntry` "
             "extension covers it in unit tests rather than here.)",
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
        "block/list/unordered/marker-change-nests",
        "* one\n- two\n",
        doc(
            ulist(
                item(
                    text("one"), marker="*", at=lines(1, 2),
                    blocks=[ulist(item(text("two"), marker="-", at=lines(2)), marker="-", at=lines(2))],
                ),
                marker="*", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
        note="A different marker begins a NESTED list inside the current item "
             "(docs/modules/lists/pages/unordered.adoc — 'to nest, change the "
             "marker'), which is also what Asciidoctor does. An earlier reading "
             "of the same sentence made the second list a sibling; the "
             "documentation's own nested-list examples settle it.",
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

    # ── breaks ──────────────────────────────────────────────────────────────
    # docs/modules/blocks/pages/breaks.adoc. Both are one line and hold nothing.

    case(
        "block/break/thematic",
        "before\n\n'''\n\nafter\n",
        doc(
            para(text("before"), at=lines(1)),
            brk("thematic", at=lines(3)),
            para(text("after"), at=lines(5)),
            at=lines(1, 5),
        ),
    )

    case(
        "block/break/page",
        "before\n\n<<<\n\nafter\n",
        doc(
            para(text("before"), at=lines(1)),
            brk("page", at=lines(3)),
            para(text("after"), at=lines(5)),
            at=lines(1, 5),
        ),
    )

    case(
        "block/break/thematic-interrupts-paragraph",
        "before\n'''\nafter\n",
        doc(
            para(text("before"), at=lines(1)),
            brk("thematic", at=lines(2)),
            para(text("after"), at=lines(3)),
            at=lines(1, 3),
        ),
        note="A break needs no blank line around it: it interrupts a paragraph "
             "the way any block-start line does.",
    )

    # ── the rest of the delimited blocks ────────────────────────────────────
    # docs/modules/blocks/pages/delimited.adoc. Four of the ASG's five
    # `parentBlock` names and three of its six `leafBlock` names are just
    # different delimiter characters over the same two content models, so these
    # cases are about the table being right rather than about each block being
    # interesting on its own.

    case(
        "block/example/containing-paragraph",
        "====\nbody\n====\n",
        doc(
            parent("example", para(text("body"), at=lines(2)), delimiter="====", at=lines(1, 3)),
            at=lines(1, 3),
        ),
    )

    case(
        "block/open/containing-paragraph",
        "--\nbody\n--\n",
        doc(
            parent("open", para(text("body"), at=lines(2)), delimiter="--", at=lines(1, 3)),
            at=lines(1, 3),
        ),
        note="The open block is the one delimiter that is EXACTLY two "
             "characters rather than four or more (sdr-001-open-block-delimiter).",
    )

    case(
        "block/quote/containing-paragraph",
        "____\nbody\n____\n",
        doc(
            parent("quote", para(text("body"), at=lines(2)), delimiter="____", at=lines(1, 3)),
            at=lines(1, 3),
        ),
    )

    case(
        "block/literal/multiple-lines",
        "....\none\n  two\n....\n",
        doc(
            leaf("literal", text("one\n  two"), form="delimited", delimiter="....", at=lines(1, 4)),
            at=lines(1, 4),
        ),
        note="A literal block keeps its interior verbatim, indentation included, "
             "exactly as a listing block does — the two differ only in what a "
             "renderer does with the text, which the ASG records as the block's "
             "name rather than in its content.",
    )

    case(
        "block/pass/multiple-lines",
        "++++\n<hr>\n++++\n",
        doc(
            leaf("pass", text("<hr>"), form="delimited", delimiter="++++", at=lines(1, 3)),
            at=lines(1, 3),
        ),
    )

    case(
        "block/example/nested-blocks",
        "====\n* one\n\nbody\n====\n",
        doc(
            parent(
                "example",
                ulist(item(text("one"), marker="*", at=lines(2)), marker="*", at=lines(2)),
                para(text("body"), at=lines(4)),
                delimiter="====", at=lines(1, 5),
            ),
            at=lines(1, 5),
        ),
    )

    case(
        "block/sidebar/nested-delimited-block",
        "****\n====\nbody\n====\n****\n",
        doc(
            parent(
                "sidebar",
                parent("example", para(text("body"), at=lines(3)), delimiter="====", at=lines(2, 4)),
                delimiter="****", at=lines(1, 5),
            ),
            at=lines(1, 5),
        ),
    )

    case(
        "block/listing/unclosed",
        "----\nbody\n",
        doc(
            leaf("listing", text("body"), form="delimited", delimiter="----", at=lines(1, 2)),
            at=lines(1, 2),
        ),
        note="An unclosed delimited block runs to the end of its container. "
             "Asciidoctor warns and does the same; the ASG has nowhere to record "
             "the warning, so the block simply ends at its last content line — "
             "the only reading that keeps every location inside the source.",
    )

    case(
        "block/listing/mismatched-delimiter-does-not-close",
        "----\n---\nbody\n----\n",
        doc(
            leaf("listing", text("---\nbody"), form="delimited", delimiter="----", at=lines(1, 4)),
            at=lines(1, 4),
        ),
        note="A closing delimiter must match the opening one character for "
             "character, so a shorter run is content.",
    )

    # ── comments ────────────────────────────────────────────────────────────
    # docs/modules/blocks/pages/comments.adoc. Comments produce no ASG node at
    # all, which makes them the one construct whose expectation is an ABSENCE —
    # and the reason the parser has to be careful about where a block "starts".

    case(
        "block/comment/line",
        "// hidden\nbody\n",
        doc(
            para(text("body"), at=lines(2)),
            at=lines(2),
        ),
        note="A line comment yields nothing, and the document therefore starts "
             "at the paragraph below it rather than at line 1.",
    )

    case(
        "block/comment/line-interrupts-paragraph",
        "one\n// hidden\ntwo\n",
        doc(
            para(text("one"), at=lines(1)),
            para(text("two"), at=lines(3)),
            at=lines(1, 3),
        ),
        note="Asciidoctor treats a comment line inside a paragraph as a "
             "line-level interruption that does NOT split the paragraph; twig "
             "splits it, because the ASG's paragraph carries ONE text node whose "
             "location must map back to real source, and a value with the "
             "comment line spliced out could not.",
    )

    case(
        "block/comment/block",
        "////\nhidden\nmore\n////\nbody\n",
        doc(
            para(text("body"), at=lines(5)),
            at=lines(5),
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

    # ── emphasis, monospace and mark spans ──────────────────────────────────
    # docs/modules/text/pages/emphasis.adoc, monospace.adoc, highlight.adoc.
    # Asciidoctor applies the same single-character constrained word-boundary
    # rule strong-span.adoc states for `*` to each of these; there is no
    # per-construct normative page that restates it, so these expectations
    # follow the strong-span cases directly above by construction.

    case(
        "block/paragraph/emphasis-span-mid-line",
        "one _two_ three\n",
        doc(
            para(
                text("one "),
                span("emphasis", text("two"), at="_two_"),
                text(" three"),
                at=lines(1),
            ),
            at=lines(1),
        ),
    )

    case(
        "inline/span/emphasis/not-constrained-by-word-character",
        "a_b_c\n",
        [text("a_b_c")],
        level="inline",
    )

    case(
        "inline/span/emphasis/unterminated",
        "_not closed\n",
        [text("_not closed")],
        level="inline",
    )

    case(
        "block/paragraph/monospace-span-mid-line",
        "one `two` three\n",
        doc(
            para(
                text("one "),
                span("code", text("two"), at="`two`"),
                text(" three"),
                at=lines(1),
            ),
            at=lines(1),
        ),
        note="A monospace span decodes to twig's own `text_leaf` verbatim leaf "
             "rather than a nested mark (see asg.zig's doc comment), but the "
             "ASG shape asserted here is the ordinary `span`/`code` one — that "
             "choice is invisible at this level.",
    )

    case(
        "inline/span/code/not-constrained-by-word-character",
        "a`b`c\n",
        [text("a`b`c")],
        level="inline",
    )

    case(
        "inline/span/code/unterminated",
        "`not closed\n",
        [text("`not closed")],
        level="inline",
    )

    case(
        "block/paragraph/mark-span-mid-line",
        "one #two# three\n",
        doc(
            para(
                text("one "),
                span("mark", text("two"), at="#two#"),
                text(" three"),
                at=lines(1),
            ),
            at=lines(1),
        ),
    )

    case(
        "inline/span/mark/not-constrained-by-word-character",
        "a#b#c\n",
        [text("a#b#c")],
        level="inline",
    )

    case(
        "inline/span/mark/unterminated",
        "#not closed\n",
        [text("#not closed")],
        level="inline",
    )

    case(
        "inline/span/four-constrained-spans-in-one-line",
        "*bold* _emphasis_ `mono` #mark#\n",
        [
            span("strong", text("bold"), at="*bold*"),
            text(" "),
            span("emphasis", text("emphasis"), at="_emphasis_"),
            text(" "),
            span("code", text("mono"), at="`mono`"),
            text(" "),
            span("mark", text("mark"), at="#mark#"),
        ],
        level="inline",
        note="The four single-character constrained spans dispatch off the "
             "same byte-scan loop in parser.zig; this checks it doesn't "
             "confuse one delimiter for another mid-line.",
    )

    # ── unconstrained spans ─────────────────────────────────────────────────
    # docs/modules/text/pages/{bold,italic,monospace,highlight}.adoc. A doubled
    # delimiter drops the word-boundary rule entirely, which is the whole
    # reason the form exists: it is how AsciiDoc spells intraword formatting.
    #
    # These four were, before the scan tried unconstrained first, the one place
    # the parser CORRUPTED rather than passed through: `**bold**` came out as
    # `<strong>*bold</strong>*` — the constrained scan opened on the first byte
    # of the pair and closed on the near half of the closing pair. `__` was
    # worse (a doubly-nested emphasis), because `isWordByte` counts `_` and
    # pushed the close one byte further right.

    case(
        "inline/span/strong/unconstrained",
        "a **bold** word\n",
        [
            text("a "),
            span("strong", text("bold"), form="unconstrained", at="**bold**"),
            text(" word"),
        ],
        level="inline",
    )

    case(
        "inline/span/emphasis/unconstrained",
        "a __ital__ word\n",
        [
            text("a "),
            span("emphasis", text("ital"), form="unconstrained", at="__ital__"),
            text(" word"),
        ],
        level="inline",
    )

    case(
        "inline/span/code/unconstrained",
        "a ``mono`` word\n",
        [
            text("a "),
            span("code", text("mono"), form="unconstrained", at="``mono``"),
            text(" word"),
        ],
        level="inline",
    )

    case(
        "inline/span/mark/unconstrained",
        "a ##hi## word\n",
        [
            text("a "),
            span("mark", text("hi"), form="unconstrained", at="##hi##"),
            text(" word"),
        ],
        level="inline",
    )

    case(
        "inline/span/strong/unconstrained-intraword",
        "sub**string**here\n",
        [
            text("sub"),
            span("strong", text("string"), form="unconstrained", at="**string**"),
            text("here"),
        ],
        level="inline",
        note="The reason the unconstrained form exists: no word-boundary rule "
             "applies, so a span can open and close mid-word. The constrained "
             "form refuses exactly this (see "
             "inline/span/strong/not-constrained-by-word-character).",
    )

    case(
        "inline/span/strong/unconstrained-nests-constrained",
        "**bold _and_ more**\n",
        [
            span(
                "strong",
                text("bold "),
                span("emphasis", text("and"), at="_and_"),
                text(" more"),
                form="unconstrained",
                at="**bold _and_ more**",
            ),
        ],
        level="inline",
    )

    case(
        "inline/span/strong/doubled-opener-without-doubled-close",
        "a **bold* word\n",
        [
            text("a "),
            span("strong", text("*bold"), at="**bold*"),
            text(" word"),
        ],
        level="inline",
        note="A doubled opener with no doubled close falls THROUGH to the "
             "constrained scan rather than going literal — asciidoctor's own "
             "ordering, where the constrained pattern's interior is `*bold`.",
    )

    # ── ordered and callout lists ───────────────────────────────────────────
    # docs/modules/lists/pages/ordered.adoc. A list's `marker` is its first
    # item's marker as written, and an item's marker is its own — so a list
    # numbered `1.`/`2.` reports `1.` at the list and each ordinal at the item.

    case(
        "block/list/ordered/dot-markers",
        ". one\n. two\n",
        doc(
            olist(
                item(text("one"), marker=".", at=lines(1)),
                item(text("two"), marker=".", at=lines(2)),
                marker=".", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/list/ordered/explicit-numbers",
        "1. one\n2. two\n",
        doc(
            olist(
                item(text("one"), marker="1.", at=lines(1)),
                item(text("two"), marker="2.", at=lines(2)),
                marker="1.", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
        note="Explicit ordinals of one family (`1.`, `2.`) are one list; the "
             "list's marker is the first item's, each item keeps its own.",
    )

    case(
        "block/list/ordered/alpha-marker",
        "a. one\nb. two\n",
        doc(
            olist(
                item(text("one"), marker="a.", at=lines(1)),
                item(text("two"), marker="b.", at=lines(2)),
                marker="a.", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/list/ordered/roman-marker",
        "i) one\nii) two\n",
        doc(
            olist(
                item(text("one"), marker="i)", at=lines(1)),
                item(text("two"), marker="ii)", at=lines(2)),
                marker="i)", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/list/ordered/nested-by-marker-depth",
        ". one\n.. nested\n. two\n",
        doc(
            olist(
                item(
                    text("one"), marker=".", at=lines(1, 2),
                    blocks=[olist(item(text("nested"), marker="..", at=lines(2)), marker="..", at=lines(2))],
                ),
                item(text("two"), marker=".", at=lines(3)),
                marker=".", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
    )

    case(
        "block/list/callout/two-items",
        "<1> one\n<2> two\n",
        doc(
            colist(
                item(text("one"), marker="<1>", at=lines(1)),
                item(text("two"), marker="<2>", at=lines(2)),
                marker="<1>", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    # ── nesting, continuation and attached blocks ───────────────────────────
    # docs/modules/lists/pages/{nested,continuation}.adoc.

    case(
        "block/list/unordered/nested-by-marker-depth",
        "* one\n** two\n* three\n",
        doc(
            ulist(
                item(
                    text("one"), marker="*", at=lines(1, 2),
                    blocks=[ulist(item(text("two"), marker="**", at=lines(2)), marker="**", at=lines(2))],
                ),
                item(text("three"), marker="*", at=lines(3)),
                marker="*", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
    )

    case(
        "block/list/mixed/ordered-inside-unordered",
        "* fruit\n. apple\n. pear\n* veg\n",
        doc(
            ulist(
                item(
                    text("fruit"), marker="*", at=lines(1, 3),
                    blocks=[olist(
                        item(text("apple"), marker=".", at=lines(2)),
                        item(text("pear"), marker=".", at=lines(3)),
                        marker=".", at=lines(2, 3),
                    )],
                ),
                item(text("veg"), marker="*", at=lines(4)),
                marker="*", at=lines(1, 4),
            ),
            at=lines(1, 4),
        ),
        note="docs/modules/lists/pages/nested.adoc's own mixed example: a list "
             "of another type nests without any marker-depth change.",
    )

    case(
        "block/list/unordered/blank-line-then-nested",
        "* one\n\n** two\n",
        doc(
            ulist(
                item(
                    text("one"), marker="*", at=lines(1, 3),
                    blocks=[ulist(item(text("two"), marker="**", at=lines(3)), marker="**", at=lines(3))],
                ),
                marker="*", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
    )

    case(
        "block/list/unordered/continuation-paragraph",
        "* one\n+\npara\n",
        doc(
            ulist(
                item(text("one"), marker="*", at=lines(1, 3), blocks=[para(text("para"), at=lines(3))]),
                marker="*", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
        note="The `+` list continuation attaches the block below it to the "
             "item; the item's location runs through the attached block.",
    )

    case(
        "block/list/unordered/continuation-listing",
        "* one\n+\n----\ncode\n----\n* two\n",
        doc(
            ulist(
                item(
                    text("one"), marker="*", at=lines(1, 5),
                    blocks=[leaf("listing", text("code"), at=lines(3, 5), form="delimited", delimiter="----")],
                ),
                item(text("two"), marker="*", at=lines(6)),
                marker="*", at=lines(1, 6),
            ),
            at=lines(1, 6),
        ),
    )

    case(
        "block/list/unordered/attached-indented-literal",
        "* one\n\n  literal\n",
        doc(
            ulist(
                item(
                    text("one"), marker="*", at=lines(1, 3),
                    blocks=[leaf("literal", text("literal", spelling="  literal"), at=lines(3), form="indented")],
                ),
                marker="*", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
        note="A blank-separated indented paragraph after an item attaches to "
             "it as a literal block (docs/modules/lists/pages/continuation.adoc). "
             "The literal's text is dedented; its location is the raw line.",
    )

    case(
        "block/list/unordered/checklist",
        "* [x] one\n* [ ] two\n",
        doc(
            ulist(
                item(text("[x] one"), marker="*", at=lines(1)),
                item(text("[ ] two"), marker="*", at=lines(2)),
                marker="*", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
        note="The ASG has no checkbox, so a checklist item's box is principal "
             "text to it; twig's tree reads the same source as a task list.",
    )

    case(
        "block/list/unordered/title-belongs-to-the-list",
        ".Things\n* a\n",
        doc(
            ulist(item(text("a"), marker="*", at=lines(2)), marker="*", at=lines(1, 2), title=[text("Things")]),
            at=lines(1, 2),
        ),
        note="Block metadata above a list is the LIST's (its location starts at "
             "the title line), not the first item's.",
    )

    # ── description lists ───────────────────────────────────────────────────
    # docs/modules/lists/pages/description.adoc.

    case(
        "block/dlist/single-item",
        "term:: desc\n",
        doc(
            dlist(ditem(text("desc"), terms=[[text("term")]], marker="::", at=lines(1)), marker="::", at=lines(1)),
            at=lines(1),
        ),
    )

    case(
        "block/dlist/description-on-next-line",
        "term::\n  desc\n",
        doc(
            dlist(ditem(text("desc"), terms=[[text("term")]], marker="::", at=lines(1, 2)), marker="::", at=lines(1, 2)),
            at=lines(1, 2),
        ),
    )

    case(
        "block/dlist/multiple-terms",
        "one::\ntwo:: desc\n",
        doc(
            dlist(
                ditem(text("desc"), terms=[[text("one")], [text("two")]], marker="::", at=lines(1, 2)),
                marker="::", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/dlist/two-items",
        "a:: 1\nb:: 2\n",
        doc(
            dlist(
                ditem(text("1"), terms=[[text("a")]], marker="::", at=lines(1)),
                ditem(text("2"), terms=[[text("b")]], marker="::", at=lines(2)),
                marker="::", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/dlist/nested-by-colon-count",
        "a:: 1\nb::: 2\n",
        doc(
            dlist(
                ditem(
                    text("1"), terms=[[text("a")]], marker="::", at=lines(1, 2),
                    blocks=[dlist(ditem(text("2"), terms=[[text("b")]], marker=":::", at=lines(2)), marker=":::", at=lines(2))],
                ),
                marker="::", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/dlist/semicolon-marker",
        "term;; desc\n",
        doc(
            dlist(ditem(text("desc"), terms=[[text("term")]], marker=";;", at=lines(1)), marker=";;", at=lines(1)),
            at=lines(1),
        ),
    )

    case(
        "block/dlist/term-with-nested-unordered-list",
        "term::\n* a\n",
        doc(
            dlist(
                ditem(
                    terms=[[text("term")]], marker="::", at=lines(1, 2),
                    blocks=[ulist(item(text("a"), marker="*", at=lines(2)), marker="*", at=lines(2))],
                ),
                marker="::", at=lines(1, 2),
            ),
            at=lines(1, 2),
        ),
        note="A term with no description of its own and a list under it: no "
             "`principal`, and the list is the item's block.",
    )

    case(
        "block/dlist/with-continuation",
        "term:: desc\n+\npara\n",
        doc(
            dlist(
                ditem(text("desc"), terms=[[text("term")]], marker="::", at=lines(1, 3), blocks=[para(text("para"), at=lines(3))]),
                marker="::", at=lines(1, 3),
            ),
            at=lines(1, 3),
        ),
    )

    # ── discrete headings ───────────────────────────────────────────────────
    # docs/modules/blocks/pages/discrete-headings.adoc.

    case(
        "block/heading/discrete",
        "[discrete]\n== Title\n",
        doc(
            heading(text("Title"), level=1, at=lines(1, 2), metadata=meta(at=lines(1), attributes={"$1": "discrete"})),
            at=lines(1, 2),
        ),
        note="A `[discrete]` heading is a block in the flow, not a section; "
             "the style itself is the first positional attribute.",
    )

    # ── block metadata ──────────────────────────────────────────────────────
    # docs/modules/attributes/pages/{id,role,options,positional-and-named-attributes}.adoc
    # and docs/modules/blocks/pages/add-title.adoc. Every block's location
    # starts at its first metadata line; `metadata.location` is the attribute
    # line(s) alone; a title's text is located after its dot.

    case(
        "block/paragraph/with-title",
        ".Title\ntext\n",
        doc(para(text("text"), at=lines(1, 2), title=[text("Title")]), at=lines(1, 2)),
    )

    case(
        "block/paragraph/with-id-anchor-line",
        "[[para-id]]\ntext\n",
        doc(para(text("text"), at=lines(1, 2), id="para-id"), at=lines(1, 2)),
        note="A bare anchor line sets `id` and nothing else — no `metadata` "
             "object, which the ASG reserves for an attribute list.",
    )

    case(
        "block/paragraph/with-reftext",
        "[[para-id,Reference Text]]\ntext\n",
        doc(para(text("text"), at=lines(1, 2), id="para-id", reftext=[text("Reference Text")]), at=lines(1, 2)),
    )

    case(
        "block/paragraph/shorthand-attributes",
        "[#the-id.role1.role2%opt]\ntext\n",
        doc(
            para(
                text("text"), at=lines(1, 2), id="the-id",
                metadata=meta(at=lines(1), roles=["role1", "role2"], options=["opt"]),
            ),
            at=lines(1, 2),
        ),
    )

    case(
        "block/paragraph/named-attributes",
        '[key=value,other="quoted, value"]\ntext\n',
        doc(
            para(text("text"), at=lines(1, 2), metadata=meta(at=lines(1), attributes={"key": "value", "other": "quoted, value"})),
            at=lines(1, 2),
        ),
        note="A quoted value keeps its comma; the quotes themselves are not "
             "part of the value.",
    )

    case(
        "block/paragraph/style-is-first-positional",
        "[lead]\ntext\n",
        doc(
            para(text("text"), at=lines(1, 2), metadata=meta(at=lines(1), attributes={"$1": "lead"})),
            at=lines(1, 2),
        ),
        note="The block style is the first positional attribute, spelled `$1` "
             "per the schema's positional-attribute pattern.",
    )

    case(
        "block/paragraph/empty-attribute-line",
        "[]\ntext\n",
        doc(para(text("text"), at=lines(1, 2), metadata=meta(at=lines(1))), at=lines(1, 2)),
        note="An empty attribute line is still an attribute line: a `metadata` "
             "object with only its location.",
    )

    case(
        "block/listing/source-with-language",
        "[source,ruby]\n----\nputs 1\n----\n",
        doc(
            leaf(
                "listing", text("puts 1"), at=lines(1, 4), form="delimited", delimiter="----",
                metadata=meta(at=lines(1), attributes={"$1": "source", "$2": "ruby"}),
            ),
            at=lines(1, 4),
        ),
    )

    case(
        "block/listing/title-then-attributes",
        ".Example\n[source,ruby]\n----\nx\n----\n",
        doc(
            leaf(
                "listing", text("x"), at=lines(1, 5), form="delimited", delimiter="----",
                title=[text("Example")],
                metadata=meta(at=lines(2), attributes={"$1": "source", "$2": "ruby"}),
            ),
            at=lines(1, 5),
        ),
    )

    case(
        "block/section/with-id-anchor-line",
        "[[sec]]\n== Title\n",
        doc(section(title=[text("Title")], level=1, at=lines(1, 2), id="sec"), at=lines(1, 2)),
    )

    case(
        "block/section/anchor-in-title",
        "== Title [[sec]]\n",
        doc(section(title=[text("Title")], level=1, at=lines(1), id="sec"), at=lines(1)),
        note="A trailing `[[id]]` in the title line is the section's id, not "
             "title text; the section's location still covers the whole line.",
    )

    case(
        "block/section/with-role",
        "[.classy]\n== Title\n",
        doc(section(title=[text("Title")], level=1, at=lines(1, 2), metadata=meta(at=lines(1), roles=["classy"])), at=lines(1, 2)),
    )

    # ── styled blocks ───────────────────────────────────────────────────────
    # docs/modules/blocks/pages/{admonitions,verses}.adoc,
    # docs/modules/verbatim/pages/{listing-blocks,literal-blocks}.adoc,
    # docs/modules/stem/pages/stem.adoc.

    case(
        "block/admonition/delimited",
        "[NOTE]\n====\ntext\n====\n",
        doc(
            parent(
                "admonition", para(text("text"), at=lines(3)), variant="note",
                at=lines(1, 4), delimiter="====",
                metadata=meta(at=lines(1), attributes={"$1": "NOTE"}),
            ),
            at=lines(1, 4),
        ),
        note="An admonition style on an example block makes it an admonition "
             "whose `variant` is the style, lowercased.",
    )

    case(
        "block/example/with-title",
        ".Title\n====\ntext\n====\n",
        doc(
            parent("example", para(text("text"), at=lines(3)), at=lines(1, 4), delimiter="====", title=[text("Title")]),
            at=lines(1, 4),
        ),
    )

    case(
        "block/quote/with-attribution",
        "[quote,Someone,Somewhere]\n____\ntext\n____\n",
        doc(
            parent(
                "quote", para(text("text"), at=lines(3)), at=lines(1, 4), delimiter="____",
                metadata=meta(at=lines(1), attributes={"$1": "quote", "$2": "Someone", "$3": "Somewhere"}),
            ),
            at=lines(1, 4),
        ),
    )

    case(
        "block/verse/delimited",
        "[verse]\n____\nRoses are red\n  violets blue\n____\n",
        doc(
            leaf(
                "verse", text("Roses are red\n  violets blue"), at=lines(1, 5), form="delimited", delimiter="____",
                metadata=meta(at=lines(1), attributes={"$1": "verse"}),
            ),
            at=lines(1, 5),
        ),
        note="A verse keeps its line breaks and indentation verbatim, as one "
             "text node — twig's tree holds it as a line block, one node per "
             "line, and the codec joins them back.",
    )

    case(
        "block/literal/indented-paragraph",
        "  literal\n",
        doc(leaf("literal", text("literal", spelling="  literal"), at=lines(1), form="indented"), at=lines(1)),
        note="An indented paragraph is a literal block in the `indented` form; "
             "its text is dedented and its location is the raw line.",
    )

    case(
        "block/listing/paragraph-style",
        "[listing]\ntext\n",
        doc(
            leaf("listing", text("text"), at=lines(1, 2), form="paragraph", metadata=meta(at=lines(1), attributes={"$1": "listing"})),
            at=lines(1, 2),
        ),
    )

    case(
        "block/literal/paragraph-style",
        "[literal]\ntext\n",
        doc(
            leaf("literal", text("text"), at=lines(1, 2), form="paragraph", metadata=meta(at=lines(1), attributes={"$1": "literal"})),
            at=lines(1, 2),
        ),
    )

    case(
        "block/stem/delimited",
        "[stem]\n++++\nx^2\n++++\n",
        doc(
            leaf("stem", text("x^2"), at=lines(1, 4), form="delimited", delimiter="++++", metadata=meta(at=lines(1), attributes={"$1": "stem"})),
            at=lines(1, 4),
        ),
    )

    case(
        "block/open/source-style",
        "[source,js]\n--\nx\n--\n",
        doc(
            leaf(
                "listing", text("x"), at=lines(1, 4), form="delimited", delimiter="--",
                metadata=meta(at=lines(1), attributes={"$1": "source", "$2": "js"}),
            ),
            at=lines(1, 4),
        ),
        note="An open block takes the style's identity: `[source]` on `--` is a "
             "listing whose delimiter is `--`.",
    )

    case(
        "block/listing/markdown-fence",
        "```ruby\nx\n```\n",
        doc(leaf("listing", text("x"), at=lines(1, 3), form="delimited", delimiter="```"), at=lines(1, 3)),
        note="Asciidoctor reads a Markdown-style fence as a listing; the "
             "delimiter is the backtick run, the info string is not part of it.",
    )

    # ── block macros ────────────────────────────────────────────────────────
    # docs/modules/macros/pages/{image,audio-and-video}.adoc, toc.adoc.

    case(
        "block/macro/image",
        "image::logo.png[Logo]\n",
        doc(macro("image", at=lines(1), target="logo.png"), at=lines(1)),
    )

    case(
        "block/macro/image-with-title",
        ".A logo\nimage::logo.png[]\n",
        doc(macro("image", at=lines(1, 2), target="logo.png", title=[text("A logo")]), at=lines(1, 2)),
    )

    case(
        "block/macro/toc",
        "toc::[]\n",
        doc(macro("toc", at=lines(1)), at=lines(1)),
        note="A macro with an empty target has no `target` key.",
    )

    case(
        "block/macro/video",
        "video::clip.mp4[]\n",
        doc(macro("video", at=lines(1), target="clip.mp4"), at=lines(1)),
    )

    case(
        "block/macro/audio",
        "audio::clip.mp3[]\n",
        doc(macro("audio", at=lines(1), target="clip.mp3"), at=lines(1)),
    )

    # ── the header's author line ────────────────────────────────────────────
    # docs/modules/document/pages/author-line.adoc.

    case(
        "block/header/author-line",
        "= Title\nDoc Writer <doc@example.org>\n",
        doc(
            header=header(
                text("Title"), at=lines(1, 2),
                authors=[{"fullname": "Doc Writer", "initials": "DW", "firstname": "Doc", "lastname": "Writer", "address": "doc@example.org"}],
            ),
            attributes={},
            at=lines(1, 2),
        ),
    )

    case(
        "block/header/multiple-authors",
        "= Title\nAda B. Lovelace; Charles Babbage\n",
        doc(
            header=header(
                text("Title"), at=lines(1, 2),
                authors=[
                    {"fullname": "Ada B. Lovelace", "initials": "ABL", "firstname": "Ada", "middlename": "B.", "lastname": "Lovelace"},
                    {"fullname": "Charles Babbage", "initials": "CB", "firstname": "Charles", "lastname": "Babbage"},
                ],
            ),
            attributes={},
            at=lines(1, 2),
        ),
    )

    # ── references ──────────────────────────────────────────────────────────
    # docs/modules/macros/pages/{url,link-macro,email-macro,xref}.adoc.

    case(
        "inline/ref/bare-url",
        "see https://example.org now\n",
        [
            text("see "),
            ref("link", "https://example.org", text("https://example.org"), at="https://example.org"),
            text(" now"),
        ],
        level="inline",
    )

    case(
        "inline/ref/url-with-text",
        "https://example.org[Example]\n",
        [ref("link", "https://example.org", text("Example"), at="https://example.org[Example]")],
        level="inline",
    )

    case(
        "inline/ref/trailing-punctuation",
        "at https://example.org.\n",
        [
            text("at "),
            ref("link", "https://example.org", text("https://example.org"), at="https://example.org"),
            text("."),
        ],
        level="inline",
        note="Sentence punctuation after a bare URL is not part of it.",
    )

    case(
        "inline/ref/url-in-parentheses",
        "(https://example.org)\n",
        [
            text("("),
            ref("link", "https://example.org", text("https://example.org"), at="https://example.org"),
            text(")"),
        ],
        level="inline",
    )

    case(
        "inline/ref/link-macro",
        "link:page.html[Page]\n",
        [ref("link", "page.html", text("Page"), at="link:page.html[Page]")],
        level="inline",
    )

    case(
        "inline/ref/link-macro-empty-text",
        "link:page.html[]\n",
        [ref("link", "page.html", text("page.html"), at="link:page.html[]")],
        level="inline",
        note="With no text of its own a link shows its target, located where "
             "the target is spelled.",
    )

    case(
        "inline/ref/angle-url",
        "<https://example.org>\n",
        [ref("link", "https://example.org", text("https://example.org"), at="<https://example.org>")],
        level="inline",
    )

    case(
        "inline/ref/email",
        "mail a@example.org now\n",
        [text("mail "), ref("link", "mailto:a@example.org", text("a@example.org"), at="a@example.org"), text(" now")],
        level="inline",
    )

    case(
        "inline/ref/mailto-macro",
        "mailto:a@example.org[Mail]\n",
        [ref("link", "mailto:a@example.org", text("Mail"), at="mailto:a@example.org[Mail]")],
        level="inline",
    )

    case(
        "inline/ref/xref-angle",
        "see <<sec>>\n",
        [text("see "), ref("xref", "sec", text("sec"), at="<<sec>>")],
        level="inline",
        note="An xref with no text shows its target, as a link does.",
    )

    case(
        "inline/ref/xref-with-text",
        "<<sec,Section>>\n",
        [ref("xref", "sec", text("Section"), at="<<sec,Section>>")],
        level="inline",
    )

    case(
        "inline/ref/xref-macro",
        "xref:sec[Section]\n",
        [ref("xref", "sec", text("Section"), at="xref:sec[Section]")],
        level="inline",
    )

    case(
        "inline/span/strong-containing-link",
        "*see https://x.org[X]*\n",
        [span("strong", text("see "), ref("link", "https://x.org", text("X"), at="https://x.org[X]"), at="*see https://x.org[X]*")],
        level="inline",
    )

    # ── literals: character references, passthroughs, escapes ──────────────
    # docs/modules/subs/pages/{special-characters,replacements}.adoc,
    # docs/modules/pass/pages/pass-macro.adoc.

    case(
        "inline/charref/named",
        "a &amp; b\n",
        [text("a "), charref("&amp;"), text(" b")],
        level="inline",
        note="A character reference is its own literal, valued as written.",
    )

    case(
        "inline/charref/numeric",
        "&#169; 2024\n",
        [charref("&#169;"), text(" 2024")],
        level="inline",
    )

    case(
        "inline/raw/triple-plus",
        "a +++<b>x</b>+++ b\n",
        [text("a "), raw("<b>x</b>", at="+++<b>x</b>+++"), text(" b")],
        level="inline",
    )

    case(
        "inline/raw/pass-macro",
        "pass:[<u>x</u>]\n",
        [raw("<u>x</u>", at="pass:[<u>x</u>]")],
        level="inline",
    )

    case(
        "inline/escape/backslash-before-strong",
        "\\*not bold*\n",
        [text("*not bold*", spelling="\\*not bold*")],
        level="inline",
        note="A backslash suppresses the span; the text's location still "
             "covers the backslash, which is source the text came from.",
    )

    case(
        "inline/literal/constrained-plus",
        "a +*x*+ b\n",
        [text("a *x* b", spelling="a +*x*+ b")],
        level="inline",
        note="`+…+` is text with no substitutions applied — and adjacent text "
             "fuses into one node, so the whole line is a single text.",
    )
