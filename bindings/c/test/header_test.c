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

static void test_abi_version_matches_header(void) {
    // If these disagree, the header and the linked library are from different
    // builds — the exact mismatch TWIG_ABI_VERSION exists to catch.
    CHECK(twig_abi_version() == TWIG_ABI_VERSION);
}

int main(void) {
    test_abi_version_matches_header();
    test_align_codes_match_runtime();
    if (failures != 0) {
        fprintf(stderr, "c header test: %d check(s) failed\n", failures);
        return 1;
    }
    printf("c header test: ok\n");
    return 0;
}
