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

static void test_abi_version_matches_header(void) {
    // If these disagree, the header and the linked library are from different
    // builds — the exact mismatch TWIG_ABI_VERSION exists to catch.
    CHECK(twig_abi_version() == TWIG_ABI_VERSION);
}

int main(void) {
    test_abi_version_matches_header();
    test_align_codes_match_runtime();
    test_editor_document_shares_the_read_surface();
    if (failures != 0) {
        fprintf(stderr, "c header test: %d check(s) failed\n", failures);
        return 1;
    }
    printf("c header test: ok\n");
    return 0;
}
