// Compiles twig.h as C and links it against the real library.
//
// This file exists mostly to be *compiled*: twig.h is hand-written and shipped
// verbatim to C consumers, so without a C translation unit that includes it,
// nothing in `zig build test` ever runs the C preprocessor or parser over it.
// A header that only Zig and Rust ever read can be broken C for months. It was:
// TWIG_ALIGN_DEFAULT/LEFT/RIGHT/CENTER were once #defines *and* TwigAlignment
// enumerators, so the preprocessor rewrote `TWIG_ALIGN_DEFAULT = 0,` into
// `0 = 0,` and every C build died at the enum.
//
// The assertions below pin the part a compile check alone can't: that the codes
// the header hands a C caller are the codes the library actually returns.

#include "twig.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

// Deliberately not <assert.h>: this test runs under `-Doptimize=ReleaseFast`
// too, where Zig defines NDEBUG and assert() expands to nothing — the checks
// would silently evaporate in exactly the build a C consumer ships. CHECK is
// always live.
static int failures = 0;
#define CHECK(expr)                                                            \
    do {                                                                       \
        if (!(expr)) {                                                         \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,   \
                    #expr);                                                    \
            failures++;                                                        \
        }                                                                      \
    } while (0)

// The TWIG_ALIGN_* codes are ABI: a consumer may have compiled them into a
// switch years ago. Pin the values, not just their existence.
//
// These are static_asserts by hand (C99 has no _Static_assert) — an array with
// a negative length is a compile error, so each line fails the build if the
// code drifts. They also prove each name is still a constant expression, which
// is what a caller writing `case TWIG_ALIGN_LEFT:` depends on.
#define PIN_CAT_(a, b) a##b
#define PIN_CAT(a, b) PIN_CAT_(a, b)
#define PIN(expr) typedef char PIN_CAT(pin_, __LINE__)[(expr) ? 1 : -1]
PIN(TWIG_ALIGN_NONE == -1);
PIN(TWIG_ALIGN_DEFAULT == 0);
PIN(TWIG_ALIGN_LEFT == 1);
PIN(TWIG_ALIGN_RIGHT == 2);
PIN(TWIG_ALIGN_CENTER == 3);
PIN(TWIG_HEAD_NONE == -1);

// TwigAlignment is twig_builder_add_cell's parameter type, and TWIG_ALIGN_NONE
// is deliberately not one of its enumerators ("not a cell" isn't an alignment
// you can build). These two spellings must nonetheless agree where they
// overlap, since TwigFlatNode.alignment mixes both code spaces in one int.
PIN((int)TWIG_ALIGN_DEFAULT == 0);
PIN((int)TWIG_ALIGN_CENTER == 3);

static void test_align_codes_match_runtime(void) {
    // A table whose delimiter row spells out every alignment. The delimiter row
    // is consumed by the parser and has no node of its own, so TwigFlatNode.
    // alignment is the only way back to it — exactly the contract the
    // TWIG_ALIGN_* codes exist to express.
    static const char src[] =
        "| a | b | c | d |\n"
        "| :- | -: | :-: | - |\n"
        "| 1 | 2 | 3 | 4 |\n";

    TwigEditor *editor = NULL;
    TwigStatus st = twig_editor_create(
        (const uint8_t *)src, sizeof(src) - 1, TWIG_FORMAT_MARKDOWN, &editor);
    CHECK(st == TWIG_STATUS_OK);
    if (st != TWIG_STATUS_OK || editor == NULL) return;

    const TwigFlatNode *nodes = NULL;
    size_t len = 0;
    st = twig_editor_nodes(editor, &nodes, &len);
    CHECK(st == TWIG_STATUS_OK);
    CHECK(len > 0);
    if (st != TWIG_STATUS_OK) { twig_editor_destroy(editor); return; }

    // Collect the alignment of each cell in the first (header) row.
    int seen[4];
    size_t n = 0;
    for (size_t i = 0; i < len && n < 4; i++) {
        if (strcmp(nodes[i].kind, "cell") == 0) {
            seen[n++] = nodes[i].alignment;
        }
    }
    CHECK(n == 4);
    if (n != 4) { twig_editor_destroy(editor); return; }
    CHECK(seen[0] == TWIG_ALIGN_LEFT);
    CHECK(seen[1] == TWIG_ALIGN_RIGHT);
    CHECK(seen[2] == TWIG_ALIGN_CENTER);
    CHECK(seen[3] == TWIG_ALIGN_DEFAULT);

    // A non-cell node reports NONE, not a real alignment — the distinction the
    // separate TWIG_ALIGN_NONE code buys over `level`'s 0-means-absent trick.
    int checked_non_cell = 0;
    for (size_t i = 0; i < len; i++) {
        if (strcmp(nodes[i].kind, "table") == 0) {
            CHECK(nodes[i].alignment == TWIG_ALIGN_NONE);
            CHECK(nodes[i].head == TWIG_HEAD_NONE);
            checked_non_cell = 1;
        }
    }
    CHECK(checked_non_cell);

    twig_editor_destroy(editor);
}

static void test_cell_extent_accessors(void) {
    // colspan/rowspan are accessors, not TwigFlatNode fields — growing the
    // struct would bump TWIG_ABI_VERSION for every consumer. A table renderer
    // walks the flat nodes and asks per cell, which is what this pins.
    static const char src[] =
        "<table><tr><td colspan=\"2\" rowspan=\"3\">a</td><td>b</td></tr></table>";

    TwigDocument *doc = NULL;
    TwigStatus st = twig_parse(
        (const uint8_t *)src, sizeof(src) - 1, TWIG_FORMAT_HTML, &doc);
    CHECK(st == TWIG_STATUS_OK);
    if (st != TWIG_STATUS_OK || doc == NULL) return;

    const TwigFlatNode *nodes = NULL;
    size_t len = 0;
    st = twig_document_nodes(doc, &nodes, &len);
    CHECK(st == TWIG_STATUS_OK);
    if (st != TWIG_STATUS_OK) { twig_document_destroy(doc); return; }

    uint32_t extents[2][2];
    size_t n = 0;
    for (size_t i = 0; i < len && n < 2; i++) {
        if (strcmp(nodes[i].kind, "cell") != 0) continue;
        CHECK(twig_document_cell_colspan(doc, nodes[i].id, &extents[n][0]) == TWIG_STATUS_OK);
        CHECK(twig_document_cell_rowspan(doc, nodes[i].id, &extents[n][1]) == TWIG_STATUS_OK);
        n++;
    }
    CHECK(n == 2);
    if (n != 2) { twig_document_destroy(doc); return; }
    CHECK(extents[0][0] == 2 && extents[0][1] == 3);
    // The one-square default is 1, never 0.
    CHECK(extents[1][0] == 1 && extents[1][1] == 1);

    // A non-cell node is NOT_FOUND, and the out-param is left alone — the same
    // distinction TWIG_ALIGN_NONE draws for alignment, spelled as a status
    // because every u32 is a legal extent.
    uint32_t untouched = 0xABCDu;
    CHECK(twig_document_cell_colspan(doc, 0, &untouched) == TWIG_STATUS_NOT_FOUND);
    CHECK(untouched == 0xABCDu);

    twig_document_destroy(doc);
}

static void test_editor_document_shares_the_read_surface(void) {
    // twig_editor_document hands the document-side read functions the editor's
    // live tree, so an embedder needn't learn two spellings of the same walk —
    // and the view keeps reporting the CURRENT tree across edits.
    static const char src[] = "# one\n\ntwo\n";

    TwigEditor *editor = NULL;
    TwigStatus st = twig_editor_create(
        (const uint8_t *)src, sizeof(src) - 1, TWIG_FORMAT_MARKDOWN, &editor);
    CHECK(st == TWIG_STATUS_OK);
    if (st != TWIG_STATUS_OK || editor == NULL) return;

    TwigDocument *view = NULL;
    st = twig_editor_document(editor, &view);
    CHECK(st == TWIG_STATUS_OK);
    if (st != TWIG_STATUS_OK || view == NULL) { twig_editor_destroy(editor); return; }

    const TwigQueryMatch *kids = NULL;
    size_t kids_len = 0;
    st = twig_document_children(view, TWIG_NO_NODE, &kids, &kids_len);
    CHECK(st == TWIG_STATUS_OK);
    CHECK(kids_len == 2);
    if (st != TWIG_STATUS_OK || kids_len != 2) { twig_editor_destroy(editor); return; }
    CHECK(strcmp(kids[0].kind, "heading") == 0);

    const uint32_t heading = kids[0].node_id;
    TwigSpan span = {0, 0};
    CHECK(twig_document_node_span(view, heading, &span) == TWIG_STATUS_OK);
    CHECK(span.start == 0 && span.end == 5);

    // Whole-tree and subtree reads work off the same handle.
    const TwigFlatNode *flat = NULL;
    size_t flat_len = 0;
    CHECK(twig_document_nodes(view, &flat, &flat_len) == TWIG_STATUS_OK);
    CHECK(flat_len >= 3);
    const TwigFlatNode *sub = NULL;
    size_t sub_len = 0;
    CHECK(twig_document_subtree(view, heading, &sub, &sub_len) == TWIG_STATUS_OK);
    CHECK(sub_len >= 1 && sub[0].id == 0 && sub[0].parent == TWIG_NO_NODE);

    TwigQueryMatch hit;
    CHECK(twig_document_node_at(view, 2, &hit) == TWIG_STATUS_OK);
    const TwigQueryMatch *chain = NULL;
    size_t chain_len = 0;
    CHECK(twig_document_nodes_at(view, 2, &chain, &chain_len) == TWIG_STATUS_OK);
    CHECK(chain_len >= 2);
    CHECK(chain[chain_len - 1].node_id == hit.node_id);

    // The heading's marker is the `# ` a rich view hides, reachable both from
    // the accessor and from the flat snapshot.
    TwigSpan marker = {0, 0};
    CHECK(twig_document_node_marker_span(view, heading, &marker) == TWIG_STATUS_OK);
    CHECK(marker.start == 0 && marker.end == 2);
    CHECK(flat[heading].has_marker_span != 0);
    CHECK(flat[heading].marker_span.start == 0 && flat[heading].marker_span.end == 2);

    // On this line the whole hidden prefix IS that marker; a paragraph's line
    // has none at all.
    TwigSpan prefix = {0, 0};
    CHECK(twig_document_line_prefix(view, 2, &prefix) == TWIG_STATUS_OK);
    CHECK(prefix.start == 0 && prefix.end == 2);

    // A heading holds no continuation lines, so there is nothing to repeat —
    // the top-level answer, which is an empty prefix rather than an error.
    const uint8_t *cont = NULL;
    size_t cont_len = 0;
    size_t cont_cols = 0;
    CHECK(twig_document_continuation_prefix(view, 2, &cont, &cont_len, &cont_cols)
          == TWIG_STATUS_OK);
    CHECK(cont_len == 0 && cont_cols == 0);

    // The caret walk answers where the half-open one declines to: the offset at
    // the very end of the source is in no node by span, but a caret there is
    // somewhere, and the chain still ends at the node the scalar call returns.
    TwigQueryMatch caret_hit;
    CHECK(twig_document_node_at_caret(view, 2, &caret_hit) == TWIG_STATUS_OK);
    const TwigQueryMatch *caret_chain = NULL;
    size_t caret_chain_len = 0;
    CHECK(twig_document_nodes_at_caret(view, 2, &caret_chain, &caret_chain_len)
          == TWIG_STATUS_OK);
    CHECK(caret_chain_len >= 2);
    CHECK(caret_chain[caret_chain_len - 1].node_id == caret_hit.node_id);

    // The view follows the editor: after an edit the same handle re-reads it.
    static const char replacement[] = "# one and a half";
    CHECK(twig_editor_replace(editor, (const uint8_t *)"0", 1,
                              (const uint8_t *)replacement, sizeof(replacement) - 1)
          == TWIG_STATUS_OK);
    CHECK(twig_document_node_span(view, heading, &span) == TWIG_STATUS_OK);
    CHECK(span.end == sizeof(replacement) - 1);

    // Destroying a borrowed view is a no-op, not a double free.
    twig_document_destroy(view);
    twig_editor_destroy(editor);
}

static void test_new_block_gestures_link_and_edit(void) {
    // Compiles the newer gesture declarations as C and links them, and pins the
    // one wire convention a compile check can't see: `has_language`. NULL-vs-set
    // is the whole difference between "no info string" and "an empty one", and
    // the header would happily compile either way.
    static const char src[] = "- a\n";

    TwigEditor *editor = NULL;
    TwigStatus st = twig_editor_create(
        (const uint8_t *)src, sizeof(src) - 1, TWIG_FORMAT_MARKDOWN, &editor);
    CHECK(st == TWIG_STATUS_OK);
    if (st != TWIG_STATUS_OK || editor == NULL) return;

    // A checkbox onto the bullet, then tick it.
    TwigChange change = {{0, 0}, {0, 0}};
    CHECK(twig_editor_toggle_task_item(editor, 2, &change) == TWIG_STATUS_OK);
    CHECK(twig_editor_set_task_checked(editor, 6, 1, &change) == TWIG_STATUS_OK);

    const uint8_t *out = NULL;
    size_t out_len = 0;
    CHECK(twig_editor_source(editor, &out, &out_len) == TWIG_STATUS_OK);
    CHECK(out_len == 8 && memcmp(out, "- [x] a\n", 8) == 0);

    // Ticking again is the documented no-op: still OK, source unmoved.
    CHECK(twig_editor_set_task_checked(editor, 6, 1, &change) == TWIG_STATUS_OK);
    CHECK(twig_editor_source(editor, &out, &out_len) == TWIG_STATUS_OK);
    CHECK(out_len == 8);

    // A rule after the list, then a footnote — both halves in one edit.
    CHECK(twig_editor_insert_thematic_break(editor, 6, &change) == TWIG_STATUS_OK);
    CHECK(twig_editor_insert_footnote(editor, 7, (const uint8_t *)"a", 1, &change)
          == TWIG_STATUS_OK);
    CHECK(twig_editor_source(editor, &out, &out_len) == TWIG_STATUS_OK);
    CHECK(out_len > 8);

    twig_editor_destroy(editor);

    // Splitting a list item repeats its marker, so the second half is a sibling
    // item and not a paragraph that ends the list. A table refuses.
    static const char item[] = "- ab\n";
    TwigEditor *splitter = NULL;
    CHECK(twig_editor_create((const uint8_t *)item, sizeof(item) - 1,
                             TWIG_FORMAT_MARKDOWN, &splitter) == TWIG_STATUS_OK);
    if (splitter == NULL) return;
    CHECK(twig_editor_split_block(splitter, 3, &change) == TWIG_STATUS_OK);
    CHECK(twig_editor_source(splitter, &out, &out_len) == TWIG_STATUS_OK);
    CHECK(out_len == 8 && memcmp(out, "- a\n- b\n", 8) == 0);
    twig_editor_destroy(splitter);

    static const char tbl[] = "| a | b |\n|---|---|\n| c | d |\n";
    TwigEditor *table_ed = NULL;
    CHECK(twig_editor_create((const uint8_t *)tbl, sizeof(tbl) - 1,
                             TWIG_FORMAT_MARKDOWN, &table_ed) == TWIG_STATUS_OK);
    if (table_ed == NULL) return;
    CHECK(twig_editor_split_block(table_ed, 3, &change) == TWIG_STATUS_NOT_EDITABLE);
    twig_editor_destroy(table_ed);

    // has_language == 0 leaves the fence bare; a set language tags it. Both
    // write valid source, so only the bytes tell them apart.
    static const char para[] = "x\n";
    TwigEditor *bare = NULL;
    CHECK(twig_editor_create((const uint8_t *)para, sizeof(para) - 1,
                             TWIG_FORMAT_MARKDOWN, &bare) == TWIG_STATUS_OK);
    if (bare == NULL) return;
    CHECK(twig_editor_toggle_code_block(bare, 0, 1, NULL, 0, 0, &change) == TWIG_STATUS_OK);
    CHECK(twig_editor_source(bare, &out, &out_len) == TWIG_STATUS_OK);
    CHECK(out_len == 10 && memcmp(out, "```\nx\n```\n", 10) == 0);

    CHECK(twig_editor_set_code_language(bare, 0, (const uint8_t *)"zig", 3, 1, &change)
          == TWIG_STATUS_OK);
    CHECK(twig_editor_source(bare, &out, &out_len) == TWIG_STATUS_OK);
    CHECK(out_len == 13 && memcmp(out, "```zig\nx\n```\n", 13) == 0);

    // A space is not a Markdown info string, and the refusal is a status, not a
    // mangled fence.
    CHECK(twig_editor_set_code_language(bare, 0, (const uint8_t *)"a b", 3, 1, &change)
          == TWIG_STATUS_INVALID_ARGUMENT);

    twig_editor_destroy(bare);
}

static void test_abi_version_matches_header(void) {
    // If these disagree, the header and the linked library are from different
    // builds — the exact mismatch TWIG_ABI_VERSION exists to catch. Print both
    // when it fires: the interesting case is a STALE HEADER reached through an
    // include path nobody meant to be searched, and "which two numbers" is the
    // whole diagnosis.
    if (twig_abi_version() != TWIG_ABI_VERSION) {
        fprintf(stderr, "abi mismatch: header says %d, library says %u\n",
                TWIG_ABI_VERSION, twig_abi_version());
    }
    CHECK(twig_abi_version() == TWIG_ABI_VERSION);
}

static void test_diagnostics_report_what_a_conversion_loses(void) {
    // A djot superscript has no Markdown spelling, so converting to Markdown
    // degrades it — and converting to djot costs nothing. The point of the
    // call is that the two answers differ for the SAME document: fidelity is a
    // property of the (document, target) pair.
    const char *src = "a^b^ c\n";
    TwigDocument *doc = NULL;
    CHECK(twig_parse((const uint8_t *)src, strlen(src), TWIG_FORMAT_DJOT, &doc) ==
          TWIG_STATUS_OK);

    const TwigWarning *warnings = NULL;
    size_t len = 0;
    CHECK(twig_document_diagnostics(doc, TWIG_FORMAT_MARKDOWN, &warnings, &len) ==
          TWIG_STATUS_OK);
    CHECK(len == 1);
    if (len == 1) {
        CHECK(warnings[0].fidelity == TWIG_FIDELITY_DEGRADED);
        CHECK(strcmp(warnings[0].kind, "superscript") == 0);
        // "0/1": second child of the first block, not a byte offset — the
        // output does not exist yet, so there is nothing to point at in it.
        CHECK(warnings[0].path_len == 3);
        CHECK(memcmp(warnings[0].path_ptr, "0/1", 3) == 0);
    }

    // Lossless to djot: an empty result, and a real answer rather than an error.
    CHECK(twig_document_diagnostics(doc, TWIG_FORMAT_DJOT, &warnings, &len) ==
          TWIG_STATUS_OK);
    CHECK(len == 0);
    CHECK(warnings == NULL);

    // A target with no serializer is a capability answer, not a per-node
    // diagnosis of everything in the document.
    CHECK(twig_document_diagnostics(doc, TWIG_FORMAT_XML, &warnings, &len) ==
          TWIG_STATUS_UNSUPPORTED_FORMAT);

    twig_document_destroy(doc);
}

static void test_definitions_are_reachable_only_through_their_own_call(void) {
    // A footnote definition is resolved by label, so it is nobody's child: the
    // flat array has TWO nodes with parent == TWIG_NO_NODE, which is exactly
    // what the array's own documentation used to deny.
    const char *src = "text[^1]\n\n[^1]: note\n";
    TwigDocument *doc = NULL;
    CHECK(twig_parse((const uint8_t *)src, strlen(src), TWIG_FORMAT_MARKDOWN, &doc) ==
          TWIG_STATUS_OK);

    const TwigFlatNode *nodes = NULL;
    size_t node_count = 0;
    CHECK(twig_document_nodes(doc, &nodes, &node_count) == TWIG_STATUS_OK);
    size_t parentless = 0;
    for (size_t i = 0; i < node_count; i++) {
        if (nodes[i].parent == TWIG_NO_NODE) {
            parentless++;
        }
    }
    CHECK(parentless == 2);

    const TwigQueryMatch *defs = NULL;
    size_t def_count = 0;
    CHECK(twig_document_definitions(doc, &defs, &def_count) == TWIG_STATUS_OK);
    CHECK(def_count == 1);
    if (def_count == 1) {
        CHECK(strcmp(defs[0].kind, "footnote") == 0);
    }

    twig_document_destroy(doc);
}

static void test_line_prefixes_answer_two_different_questions(void) {
    // The bytes already on the line vs. the bytes a continuation would need.
    // They differ precisely where an editor gets it wrong by hand: the item's
    // "- " is PRESENT on line one and must NOT be repeated on line two, or the
    // continuation opens a second item instead of continuing the first.
    const char *src = "> - a\n";
    TwigDocument *doc = NULL;
    CHECK(twig_parse((const uint8_t *)src, strlen(src), TWIG_FORMAT_MARKDOWN, &doc) ==
          TWIG_STATUS_OK);

    TwigSpan span = {0, 0};
    CHECK(twig_document_line_prefix(doc, 4, &span) == TWIG_STATUS_OK);
    CHECK(span.start == 0 && span.end == 4);
    CHECK(memcmp(src + span.start, "> - ", 4) == 0);

    const uint8_t *cont = NULL;
    size_t cont_len = 0;
    size_t cont_cols = 0;
    CHECK(twig_document_continuation_prefix(doc, 4, &cont, &cont_len, &cont_cols) ==
          TWIG_STATUS_OK);
    // The quote reproduced, the item as width. Same column count as the line
    // prefix above, deliberately — the content stays where it was.
    CHECK(cont_len == 4 && cont_cols == 4);
    if (cont != NULL) CHECK(memcmp(cont, ">   ", 4) == 0);

    // A blank line inside the same containers keeps the quote alive and drops
    // the item's indent, and the quote's blank form has no trailing space.
    const uint8_t *blank = NULL;
    size_t blank_len = 0;
    size_t blank_cols = 0;
    CHECK(twig_document_blank_line_prefix(doc, 4, &blank, &blank_len, &blank_cols) ==
          TWIG_STATUS_OK);
    CHECK(blank_len == 1 && blank_cols == 1);
    if (blank != NULL) CHECK(blank[0] == '>');

    twig_document_destroy(doc);
}

static void test_task_items_report_their_checkbox_state(void) {
    // The state comes off the tree, where the parser recorded it. A capital
    // `[X]` is checked too, which a consumer matching the literal `[x]` misses.
    const char *src = "- [ ] a\n- [x] b\n- [X] c\n- d\n";
    TwigDocument *doc = NULL;
    CHECK(twig_parse((const uint8_t *)src, strlen(src), TWIG_FORMAT_MARKDOWN, &doc) ==
          TWIG_STATUS_OK);

    const TwigFlatNode *nodes = NULL;
    size_t count = 0;
    CHECK(twig_document_nodes(doc, &nodes, &count) == TWIG_STATUS_OK);

    int seen_unchecked = 0, seen_checked = 0, seen_plain = 0, seen_other = 0;
    for (size_t i = 0; i < count; i++) {
        if (strcmp(nodes[i].kind, "task_list_item") == 0) {
            if (nodes[i].checked == 1) seen_checked++;
            if (nodes[i].checked == 0) seen_unchecked++;
        } else if (strcmp(nodes[i].kind, "list_item") == 0) {
            // A plain item is not a task item, so it reports NONE rather than
            // "unchecked" — else a renderer draws a box beside it.
            seen_plain++;
            CHECK(nodes[i].checked == TWIG_TASK_CHECKED_NONE);
        } else if (nodes[i].checked != TWIG_TASK_CHECKED_NONE) {
            seen_other++;
        }
    }
    CHECK(seen_checked == 2 && seen_unchecked == 1 && seen_plain == 1);
    CHECK(seen_other == 0);

    twig_document_destroy(doc);
}

int main(void) {
    test_abi_version_matches_header();
    test_line_prefixes_answer_two_different_questions();
    test_task_items_report_their_checkbox_state();
    test_definitions_are_reachable_only_through_their_own_call();
    test_diagnostics_report_what_a_conversion_loses();
    test_align_codes_match_runtime();
    test_cell_extent_accessors();
    test_editor_document_shares_the_read_surface();
    test_new_block_gestures_link_and_edit();
    if (failures != 0) {
        fprintf(stderr, "c header test: %d check(s) failed\n", failures);
        return 1;
    }
    printf("c header test: ok\n");
    return 0;
}
