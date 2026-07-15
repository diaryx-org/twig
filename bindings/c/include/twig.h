#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── ABI stability contract ───────────────────────────────────────────────────
// This header follows an APPEND-ONLY discipline so that adding capability is a
// minor release, never a breaking one:
//
//   - Enum-like code spaces (TWIG_FORMAT_*, TwigStatus, TwigNodeKind,
//     TwigInlineKind, TwigBlockKind, TwigBlockContainerKind, and the builder
//     enums) only ever gain new
//     values appended at the end. An existing value is NEVER renumbered or
//     reused — so a new document format is TWIG_FORMAT_* = <next int>, leaving
//     every prior code untouched.
//   - New functions (e.g. a future twig_editor_undo) are added; existing
//     signatures never change in place.
//   - The struct layouts below are frozen. Any change to a struct's fields —
//     or any renumbering of an existing enum value — is a breaking change that
//     bumps TWIG_ABI_VERSION.
//
// A consumer records TWIG_ABI_VERSION at compile time and may call
// twig_abi_version() at load time to confirm the linked library agrees.
// 2: TwigFlatNode grew head/alignment (96 -> 104 bytes). The new fields are
//    appended, so every prior field kept its offset, but sizeof is part of the
//    layout a consumer strides an array with — hence the bump.
#define TWIG_ABI_VERSION 2

#define TWIG_FORMAT_DJOT 1
#define TWIG_FORMAT_MARKDOWN 2
#define TWIG_FORMAT_XML 3
#define TWIG_FORMAT_HTML 4

// Markdown extension flags for twig_editor_create_ext's `md_flags` bitmask
// (ignored for non-Markdown formats).
#define TWIG_MD_DIRECTIVES (1u << 0)  // generic directives: :name, ::name, :::name
#define TWIG_MD_MATH       (1u << 1)  // $...$ / $$...$$ math

typedef enum TwigStatus {
    TWIG_STATUS_OK = 0,
    TWIG_STATUS_INVALID_ARGUMENT = 1,
    TWIG_STATUS_PARSE_ERROR = 2,
    TWIG_STATUS_OUT_OF_MEMORY = 3,
    TWIG_STATUS_UNSUPPORTED_FORMAT = 4,
    // Editor-only. A locator resolved to no node (out-of-bounds index path, or
    // a selector with zero matches).
    TWIG_STATUS_NOT_FOUND = 5,
    // Editor-only. A selector locator matched more than one node.
    TWIG_STATUS_AMBIGUOUS = 6,
    // Editor-only. The target node has no editable span/interior.
    TWIG_STATUS_NOT_EDITABLE = 7,
    // Editor-only. The edit produced a document that no longer parses; it was
    // rolled back and nothing changed.
    TWIG_STATUS_EDIT_CONFLICT = 8,
    TWIG_STATUS_INTERNAL_ERROR = 255,
} TwigStatus;

typedef struct TwigDocument TwigDocument;

// A span-splice editor over a document: applies lossless, in-place edits and
// reparses after each one. Independent of TwigDocument.
typedef struct TwigEditor TwigEditor;

// A byte range [start, end) into the source.
typedef struct TwigSpan {
    size_t start;
    size_t end;
} TwigSpan;

// One node matched by `twig_document_query`. `content_span` is only meaningful
// when `has_content_span` is non-zero (a leaf, or a container the parser left
// without a known interior, reports has_content_span == 0 and a zeroed
// content_span). `kind` is a NUL-terminated node-kind name (e.g. "heading",
// "code_block") in static, library-owned storage: never free it; it stays
// valid for the process lifetime.
typedef struct TwigQueryMatch {
    uint32_t node_id;
    TwigSpan span;
    TwigSpan content_span;
    int has_content_span;
    const char *kind;
} TwigQueryMatch;

// The sentinel node id meaning "no such node" in a TwigFlatNode link field
// (parent / first_child / next_sibling): the root has no parent, a leaf no
// child, a last sibling no next. A real id is a node-arena index, always less
// than this value.
#define TWIG_NO_NODE ((uint32_t)0xFFFFFFFFu)

// The byte-level effect of an edit. `old_span` is the range of the pre-edit
// source that was replaced; `new_span` is the range the replacement occupies in
// the post-edit source (they share a start). An insertion has an empty
// `old_span`, a deletion an empty `new_span`. See twig_editor_edit_range /
// twig_editor_last_change.
typedef struct TwigChange {
    TwigSpan old_span;
    TwigSpan new_span;
} TwigChange;

// One node in the editor's current tree — the flat-arena snapshot
// twig_editor_nodes returns, the JSON-free read path. `id` is the node's index
// in the arena; parent / first_child / next_sibling are ids or TWIG_NO_NODE.
// content_span is meaningful only when has_content_span is non-zero. `level` is
// a heading's level (0 otherwise). `kind` is static, library-owned storage
// (never freed). text_ptr/destination_ptr borrow the node's payload in the
// current parse and stay valid until the next successful edit or
// twig_editor_destroy; each pointer is NULL when the kind carries no such
// payload.
//
// `head` and `alignment` surface a row/cell payload the way `level` surfaces a
// heading's, so a table can be rendered from the snapshot alone. Each is -1
// (TWIG_HEAD_NONE / TWIG_ALIGN_NONE) for a kind that carries no such payload —
// not `level`'s 0-means-absent trick, because a cell's TWIG_ALIGN_DEFAULT is
// itself a meaningful value.
typedef struct TwigFlatNode {
    uint32_t id;
    uint32_t parent;
    uint32_t first_child;
    uint32_t next_sibling;
    TwigSpan span;
    TwigSpan content_span;
    int has_content_span;
    uint32_t level;
    const char *kind;
    const uint8_t *text_ptr;
    size_t text_len;
    const uint8_t *destination_ptr;
    size_t destination_len;
    int head;
    int alignment;
} TwigFlatNode;

// TwigFlatNode.head for a node that is neither a row nor a cell.
#define TWIG_HEAD_NONE (-1)

// TwigFlatNode.alignment for a node that isn't a cell. The other four codes are
// the TwigAlignment enumerators below; this one is deliberately not among them,
// because TwigAlignment is also twig_builder_add_cell's parameter type and
// "not a cell" is not an alignment you can build with. The delimiter row
// (|:--|--:|) that spells a column's alignment out is consumed by the parser and
// has no node, so TwigFlatNode.alignment is the only way to recover it.
#define TWIG_ALIGN_NONE (-1)

// The C ABI contract version (see the "ABI stability contract" above); compare
// against the TWIG_ABI_VERSION you compiled with to detect a layout mismatch.
// Bumped only on a breaking ABI change, never on an additive one.
uint32_t twig_abi_version(void);

// Packed as (major << 16) | (minor << 8) | patch.
uint32_t twig_version(void);
// Null-terminated "major.minor.patch" string in static library-owned storage.
const char *twig_version_string(void);

// Parse input bytes into a document handle. `format` is one of the
// TWIG_FORMAT_* codes.
TwigStatus twig_parse(
    const uint8_t *input,
    size_t input_len,
    int format,
    TwigDocument **out_doc
);

// Destroy a document handle.
void twig_document_destroy(TwigDocument *doc);

// Render a parsed document to HTML. For Djot/Markdown this is the rich
// rendering path that resolves reference/footnote side tables.
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_render_html` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_render_html(
    TwigDocument *doc,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Serialize a parsed document to `format`'s own source syntax: a round-trip
// when `format` matches the document's own format, cross-format conversion
// otherwise (e.g. parse Markdown, serialize as Djot). Returns
// TWIG_STATUS_UNSUPPORTED_FORMAT when the requested direction has no
// serializer (today: converting into XML from another format).
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_serialize` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_serialize(
    TwigDocument *doc,
    int format,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Encode the parsed document's AST as pretty-printed JSON (the same encoding
// as `twig convert -o ast`).
//
// The returned bytes are borrowed from `doc` and remain valid until the next
// `twig_document_ast_json` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_ast_json(
    TwigDocument *doc,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Resolve a CSS-lite selector (e.g. "heading[level=2]", "link[dest^=\"http\"]",
// "code", "list > item") against a parsed document, yielding one match per
// node in document order. A malformed selector returns
// TWIG_STATUS_INVALID_ARGUMENT.
//
// The returned matches are borrowed from `doc` and remain valid until the next
// `twig_document_query` call on that same handle, or until the handle is
// destroyed.
TwigStatus twig_document_query(
    TwigDocument *doc,
    const uint8_t *selector,
    size_t selector_len,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// ── Editor ──────────────────────────────────────────────────────────────────
// Lossless, in-place span-splice editing. Create an editor over some source,
// apply edits addressed by a `locator` — either a dot-separated index path
// ("0.3.1") or a selector that must match exactly one node (`heading("Status")`)
// — and read the edited bytes back. Each successful edit reparses, so a
// locator is resolved against the tree as it stands at that call; a failed edit
// leaves the document byte-for-byte unchanged. Use twig_editor_query /
// twig_editor_ast_json to inspect the current tree between edits.

// Create an editor over a private copy of `input`, parsed as `format` (a
// TWIG_FORMAT_* code) with default options.
TwigStatus twig_editor_create(
    const uint8_t *input,
    size_t input_len,
    int format,
    TwigEditor **out_editor
);

// Like twig_editor_create, plus `md_flags` — a bitmask of TWIG_MD_* Markdown
// extensions to enable (ignored for other formats). The editor reparses with
// these flags after every edit, so a directive-bearing document stays
// parseable — required before twig_editor_filter can match `directive[...]`
// selectors.
TwigStatus twig_editor_create_ext(
    const uint8_t *input,
    size_t input_len,
    int format,
    uint32_t md_flags,
    TwigEditor **out_editor
);

// Destroy an editor handle.
void twig_editor_destroy(TwigEditor *editor);

// Replace the whole source of the located node with `text`.
TwigStatus twig_editor_replace(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Replace the interior (between-delimiters content) of the located container.
TwigStatus twig_editor_replace_content(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Insert `text` immediately before the located node.
TwigStatus twig_editor_insert_before(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Insert `text` immediately after the located node.
TwigStatus twig_editor_insert_after(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    const uint8_t *text,
    size_t text_len
);

// Insert `text` as the `child_index`-th child of the located container (an
// index at or past the child count appends).
TwigStatus twig_editor_insert_child(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len,
    size_t child_index,
    const uint8_t *text,
    size_t text_len
);

// Delete the located node (removes exactly its span; no whitespace cleanup).
TwigStatus twig_editor_delete(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len
);

// Delete the located node, tidying surrounding blank lines for a whole-line
// (block) node; an inline node degrades to the exact-span delete.
TwigStatus twig_editor_delete_smart(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len
);

// Unwrap the located node: replace it with its interior (drop the wrapper, keep
// the children) — e.g. peel a `:::vis{...}` container. A node with no interior
// (a leaf, or an empty container) is removed.
TwigStatus twig_editor_unwrap(
    TwigEditor *editor,
    const uint8_t *locator,
    size_t locator_len
);

// Prune the document in place: remove every node matching the `drop` selector
// except those also matching `keep` (pass keep == NULL to spare nothing), then
// — if `unwrap_kept` is non-zero — unwrap the survivors. Read the result via
// twig_editor_source. A malformed selector returns TWIG_STATUS_INVALID_ARGUMENT;
// a reparse-breaking edit (rolled back) TWIG_STATUS_EDIT_CONFLICT.
TwigStatus twig_editor_filter(
    TwigEditor *editor,
    const uint8_t *drop,
    size_t drop_len,
    const uint8_t *keep,
    size_t keep_len,
    int unwrap_kept
);

// The editor's current (edited) source bytes. Borrowed from `editor` and valid
// until the next successful edit on this handle, or until it is destroyed.
TwigStatus twig_editor_source(
    TwigEditor *editor,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Encode the editor's current tree as pretty-printed JSON. Borrowed from
// `editor` and valid until the next twig_editor_ast_json call, or until it is
// destroyed.
TwigStatus twig_editor_ast_json(
    TwigEditor *editor,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Resolve a selector against the editor's current tree. Borrowed from `editor`
// and valid until the next twig_editor_query call, or until it is destroyed.
TwigStatus twig_editor_query(
    TwigEditor *editor,
    const uint8_t *selector,
    size_t selector_len,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// Inline mark kinds for twig_editor_wrap_range / twig_editor_toggle_inline.
// Markdown spells only STRONG / EMPH / VERBATIM; Djot spells all of them.
// (The integer values are the wire contract — do not renumber.)
typedef enum TwigInlineKind {
    TWIG_INLINE_STRONG = 0,
    TWIG_INLINE_EMPH = 1,
    TWIG_INLINE_VERBATIM = 2,
    TWIG_INLINE_MARK = 3,
    TWIG_INLINE_SUPERSCRIPT = 4,
    TWIG_INLINE_SUBSCRIPT = 5,
    TWIG_INLINE_INSERT = 6,
    TWIG_INLINE_DELETE = 7,
} TwigInlineKind;

// Block kinds for twig_editor_set_block. For TWIG_BLOCK_HEADING the `level`
// argument (1–6) applies; for TWIG_BLOCK_PARAGRAPH it is ignored.
typedef enum TwigBlockKind {
    TWIG_BLOCK_PARAGRAPH = 0,
    TWIG_BLOCK_HEADING = 1,
} TwigBlockKind;

// Container kinds for twig_editor_toggle_block_container. Where a TwigBlockKind
// is a marker on ONE block, a container prefixes every line of a range and nests.
// (The integer values are the wire contract — do not renumber.)
typedef enum TwigBlockContainerKind {
    TWIG_CONTAINER_BLOCK_QUOTE = 0,
    TWIG_CONTAINER_BULLET_LIST = 1,
    TWIG_CONTAINER_ORDERED_LIST = 2,
} TwigBlockContainerKind;

// ── Offset-addressed editing & read-back ──────────────────────────────────────
// The rich-text-editor surface: a caret speaks byte offsets, not locator
// strings. edit_range is the raw splice a keystroke maps onto; node_at /
// nodes_at hit-test an offset back to nodes; nodes hands out the whole tree as
// a flat array so a renderer needn't parse the AST JSON.

// Splice [start, end) of the current source with `text` and reparse — the
// offset-addressed primitive behind a caret editor: a keystroke is
// edit_range(caret, caret, "x"); backspace edit_range(caret-1, caret, "");
// a selection replace edit_range(a, b, s). start <= end <= source length, else
// TWIG_STATUS_INVALID_ARGUMENT. A reparse-breaking edit is rolled back and
// returns TWIG_STATUS_EDIT_CONFLICT. On success, if out_change is non-NULL it
// receives the byte effect (also available via twig_editor_last_change).
TwigStatus twig_editor_edit_range(
    TwigEditor *editor,
    size_t start,
    size_t end,
    const uint8_t *text,
    size_t text_len,
    TwigChange *out_change
);

// Write the byte effect of the last successful edit into out_change — lets the
// locator ops (twig_editor_replace, _delete, …) report their change too, so a
// caret/selection can re-anchor without re-diffing. Returns TWIG_STATUS_NOT_FOUND
// if no edit has succeeded yet. (A multi-splice op such as filter reports only
// its final splice.)
TwigStatus twig_editor_last_change(
    TwigEditor *editor,
    TwigChange *out_change
);

// Undo the last edit step, restoring the previous source and reparsing. On
// success, if out_change is non-NULL it receives the byte effect of the undo
// (current -> restored) so a caret can re-anchor. Returns TWIG_STATUS_NOT_FOUND
// when there is nothing to undo. History is per-editor and accrues across every
// op that funnels through the splice primitive (splices and locator ops alike).
TwigStatus twig_editor_undo(
    TwigEditor *editor,
    TwigChange *out_change
);

// Redo the most recently undone edit step, symmetric to twig_editor_undo.
// Returns TWIG_STATUS_NOT_FOUND when the redo stack is empty (nothing undone, or
// a fresh edit has since invalidated it).
TwigStatus twig_editor_redo(
    TwigEditor *editor,
    TwigChange *out_change
);

// Fold the most recent edit into the undo step before it, so a caret editor can
// coalesce a run of keystrokes into one undo. Call immediately after an
// edit_range that continues a run. A no-op unless there are two steps to merge.
TwigStatus twig_editor_coalesce_last(TwigEditor *editor);

// Snapshot the editor's current tree as a flat array of TwigFlatNode, one per
// arena node, indexed so array[i].id == i. The JSON-free read path for a
// renderer: walk it via the parent / first_child / next_sibling id links
// (TWIG_NO_NODE where absent); the root is the node whose parent == TWIG_NO_NODE.
// Borrowed from `editor`, valid until the next twig_editor_nodes call or
// destroy; the text/destination pointers within additionally require no
// successful edit since (a reparse frees the payloads they borrow).
TwigStatus twig_editor_nodes(
    TwigEditor *editor,
    const TwigFlatNode **out_ptr,
    size_t *out_len
);

// The deepest node whose span contains byte `offset` (half-open [start, end),
// with offset == source length treated as inside the root) — mouse hit-testing
// and cursor context. Fills out_match and returns TWIG_STATUS_OK, or
// TWIG_STATUS_NOT_FOUND if no node covers the offset (TWIG_STATUS_INVALID_ARGUMENT
// if offset > source length). out_match is a value copy (its `kind` is static).
TwigStatus twig_editor_node_at(
    TwigEditor *editor,
    size_t offset,
    TwigQueryMatch *out_match
);

// The chain of nodes containing byte `offset`, root-first down to the deepest
// (the node twig_editor_node_at returns) — the ancestor path for breadcrumbs or
// context-scoped edits. Same borrow contract as twig_editor_query, on an
// independent buffer. Returns TWIG_STATUS_NOT_FOUND (and a zero-length result)
// if nothing covers the offset.
TwigStatus twig_editor_nodes_at(
    TwigEditor *editor,
    size_t offset,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// ── Range-oriented rich-text ops (the toolbar) ────────────────────────────────
// A caret editor's Bold / Italic / Code buttons and its H1 / Body switch, done
// format-aware: twig knows a Markdown strong is `**…**` and a Djot one `*…*`.

// Wrap [start, end) of the source with `kind`'s delimiters (always adds a mark).
// start <= end <= source length, else TWIG_STATUS_INVALID_ARGUMENT; a kind the
// format can't spell is TWIG_STATUS_UNSUPPORTED_FORMAT; a reparse-breaking result
// rolls back to TWIG_STATUS_EDIT_CONFLICT. Fills out_change on success if non-NULL.
TwigStatus twig_editor_wrap_range(
    TwigEditor *editor,
    size_t start,
    size_t end,
    int kind,
    TwigChange *out_change
);

// Toggle `kind` over [start, end): strip the mark if the range already is a node
// of `kind` (its whole span or its interior), else wrap it — a rich editor's
// Cmd-B. Same argument/format/rollback rules as twig_editor_wrap_range; a
// matched-but-unrecoverable mark is TWIG_STATUS_NOT_EDITABLE.
TwigStatus twig_editor_toggle_inline(
    TwigEditor *editor,
    size_t start,
    size_t end,
    int kind,
    TwigChange *out_change
);

// Convert the innermost heading/paragraph covering byte `offset` to `block_kind`
// (a `level`-N heading, or a paragraph), rewriting its leading marker while
// keeping its inline content. Djot and Markdown only (both spell headings `#`…),
// else TWIG_STATUS_UNSUPPORTED_FORMAT. TWIG_STATUS_NOT_FOUND if no heading/para
// covers `offset`; TWIG_STATUS_INVALID_ARGUMENT for a heading `level` outside 1–6
// or an `offset` past the source. Fills out_change on success if non-NULL.
TwigStatus twig_editor_set_block(
    TwigEditor *editor,
    size_t offset,
    int block_kind,
    uint32_t level,
    TwigChange *out_change
);

// Toggle a block container (quote / bullet list / ordered list) over the blocks
// that [start, end) covers. `container_kind` is a TwigBlockContainerKind. Djot and
// Markdown only — both spell these `> `, `- `, `1. ` and nest quotes `> > ` —
// else TWIG_STATUS_UNSUPPORTED_FORMAT. TWIG_STATUS_INVALID_ARGUMENT for a bad
// range or kind code; TWIG_STATUS_NOT_FOUND if the range covers no block; a
// reparse-breaking result rolls back to TWIG_STATUS_EDIT_CONFLICT. Fills
// out_change on success if non-NULL.
//
// The range is always widened to WHOLE LINES of the blocks it touches — you
// cannot quote half a paragraph — and the prefix is applied at column 0, so a
// container wraps the outermost structure on those lines (quoting inside a list
// item quotes the item: `- a` -> `> - a`).
//
// ON vs OFF is decided from the AST, not by looking for a `>` in the source (a
// `>` inside a code block is not a quote). The op walks the ancestors of `start`
// for a container of `container_kind` and toggles OFF only when the range covers
// every block that container holds; otherwise it toggles ON. So:
//
//   * A fully covered container is REMOVED, one level only: `> > a` -> `> a`.
//   * A PARTLY covered one NESTS instead, because unquoting it would drag its
//     uncovered siblings out too. Selecting the first paragraph of
//     `> a\n>\n> b\n` gives `> > a\n>\n> b\n`.
//   * Toggling a list kind while in the OTHER list kind CONVERTS in place
//     (`- a` -> `1. a`) rather than nesting a list inside a list.
//
// Each covered block becomes one list item, so an ordered list numbers a
// multi-block range 1., 2., 3.… A blank line between blocks is marked (`>`) for a
// quote, which would otherwise end at it, and left bare for a list, where it only
// makes the list loose. Removing a list INSERTS a blank line between items that
// lacked one: a tight `- a\n- b\n` stripped to `a\nb\n` would be one paragraph,
// not two — the items' block structure is what is preserved, not the tightness.
//
TwigStatus twig_editor_toggle_block_container(
    TwigEditor *editor,
    size_t start,
    size_t end,
    int container_kind,
    TwigChange *out_change
);

// Link [start, end) to `destination` — `[text](destination)`. Djot and Markdown
// only, else TWIG_STATUS_UNSUPPORTED_FORMAT. TWIG_STATUS_INVALID_ARGUMENT for a
// bad range, a NULL destination with a non-zero length, or a destination holding
// a newline (neither format can carry one: Djot strips it, Markdown's `<…>` form
// forbids it — refusing beats silently rewriting the caller's URL). Fills
// out_change on success if non-NULL.
//
//   * An EXISTING link covering the range has its destination REPLACED and its
//     text kept — re-linking is the common gesture, and it keeps the op from
//     nesting `[[t](a)](b)`. To unlink, use twig_editor_unwrap, which peels a
//     node down to its interior.
//   * A CARET in an existing autolink (`<https://x.dev>`, `<a@b.dev>`) re-points
//     it the same way, but there is no text to keep: an autolink's text IS its
//     destination, so the node is replaced WHOLE, spelled canonically for the
//     new destination (below) — a `<url>` re-pointed at a relative path becomes
//     `[dest](dest)`. Only a caret: a selection carries text of its own to link,
//     and one straddling the autolink's edges has no re-point to mean, so it
//     wraps as usual. A caret inside BOTH an autolink and a link
//     (`[<https://x.dev>](d)`) re-points the LINK, whose text is separable from
//     its destination and so survives.
//   * A link with NO TEXT — an empty range, or re-pointing an existing
//     `[](old)` — is spelled canonically for the destination given, never as
//     `[](destination)`: a childless link has nothing to render, so consumers
//     fall back to showing the destination and a caret has nowhere to sit.
//     A destination the format can autolink (an absolute URL or an email, by
//     that format's own rules) gives `<destination>`; anything else gives
//     `[destination](destination)`, the destination doubling as the text so it
//     stays visible and editable. Which destinations autolink is NOT a caller
//     decision: `<foo>` is raw HTML in Markdown, and a relative path degrades to
//     literal text in both. The formats also disagree — `<mailto:a@b.dev>` is a
//     url in Markdown but an email in Djot — so each is asked its own parser.
//
// The destination is escaped for the target format, so a `)` or a space in it
// cannot break the markup. This differs BY FORMAT, and not cosmetically:
// Markdown ends a destination at the first space (`[t](a b)` is not a link at
// all), so a destination with whitespace moves into the `<…>` form; Djot takes
// spaces literally and gives `<…>` no meaning, so `[t](<a b>)` there would link
// to the literal text `<a b>`. Parens and backslashes are backslash-escaped, as
// is each format's other destination-ending byte (`<` in Markdown; `[` and a
// backtick in Djot, whose destination is still scanned for inline openers).
TwigStatus twig_editor_insert_link(
    TwigEditor *editor,
    size_t start,
    size_t end,
    const uint8_t *destination,
    size_t destination_len,
    TwigChange *out_change
);

// ── Builder ───────────────────────────────────────────────────────────────────
// Programmatic construction of a document — the write-path mirror of twig_parse.
// Build the tree bottom-up: add children, then the container, wiring them with
// twig_builder_set_children; every twig_builder_add* call returns the new node's
// id through out_id. Then render / serialize / query / dump the subtree rooted at
// any id, on demand, without consuming the builder. All input strings are copied,
// so caller buffers need not outlive a call. Each node id must be placed in
// exactly one parent (a node has a single sibling link).

typedef struct TwigBuilder TwigBuilder;

// The shared node-kind vocabulary as stable codes (declaration order). Used by
// twig_builder_add (the void-payload kinds) and twig_builder_add_text (the
// single-string-payload kinds); kinds with richer payloads have their own
// twig_builder_add_* constructor and are not selectable through those two.
typedef enum TwigNodeKind {
    TWIG_KIND_DOC = 0,
    TWIG_KIND_PARA = 1,
    TWIG_KIND_HEADING = 2,
    TWIG_KIND_THEMATIC_BREAK = 3,
    TWIG_KIND_SECTION = 4,
    TWIG_KIND_DIV = 5,
    TWIG_KIND_CODE_BLOCK = 6,
    TWIG_KIND_RAW_BLOCK = 7,
    TWIG_KIND_METADATA = 8,
    TWIG_KIND_BLOCK_QUOTE = 9,
    TWIG_KIND_BULLET_LIST = 10,
    TWIG_KIND_ORDERED_LIST = 11,
    TWIG_KIND_TASK_LIST = 12,
    TWIG_KIND_DEFINITION_LIST = 13,
    TWIG_KIND_TABLE = 14,
    TWIG_KIND_LIST_ITEM = 15,
    TWIG_KIND_TASK_LIST_ITEM = 16,
    TWIG_KIND_DEFINITION_LIST_ITEM = 17,
    TWIG_KIND_TERM = 18,
    TWIG_KIND_DEFINITION = 19,
    TWIG_KIND_ROW = 20,
    TWIG_KIND_CELL = 21,
    TWIG_KIND_CAPTION = 22,
    TWIG_KIND_FOOTNOTE = 23,
    TWIG_KIND_REFERENCE = 24,
    TWIG_KIND_STR = 25,
    TWIG_KIND_SOFT_BREAK = 26,
    TWIG_KIND_HARD_BREAK = 27,
    TWIG_KIND_NON_BREAKING_SPACE = 28,
    TWIG_KIND_SYMB = 29,
    TWIG_KIND_VERBATIM = 30,
    TWIG_KIND_RAW_INLINE = 31,
    TWIG_KIND_INLINE_MATH = 32,
    TWIG_KIND_DISPLAY_MATH = 33,
    TWIG_KIND_URL = 34,
    TWIG_KIND_EMAIL = 35,
    TWIG_KIND_FOOTNOTE_REFERENCE = 36,
    TWIG_KIND_SMART_PUNCTUATION = 37,
    TWIG_KIND_EMPH = 38,
    TWIG_KIND_STRONG = 39,
    TWIG_KIND_LINK = 40,
    TWIG_KIND_IMAGE = 41,
    TWIG_KIND_SPAN = 42,
    TWIG_KIND_MARK = 43,
    TWIG_KIND_SUPERSCRIPT = 44,
    TWIG_KIND_SUBSCRIPT = 45,
    TWIG_KIND_INSERT = 46,
    TWIG_KIND_DELETE = 47,
    TWIG_KIND_DOUBLE_QUOTED = 48,
    TWIG_KIND_SINGLE_QUOTED = 49,
    TWIG_KIND_DIRECTIVE = 50,
    TWIG_KIND_ELEMENT = 51,
    TWIG_KIND_COMMENT = 52,
    TWIG_KIND_DOCTYPE = 53,
    TWIG_KIND_PROCESSING_INSTRUCTION = 54,
    TWIG_KIND_CDATA = 55,
} TwigNodeKind;

typedef enum TwigBulletStyle {
    TWIG_BULLET_DASH = 0,
    TWIG_BULLET_PLUS = 1,
    TWIG_BULLET_STAR = 2,
} TwigBulletStyle;

typedef enum TwigOrderedNumbering {
    TWIG_ORDERED_DECIMAL = 0,
    TWIG_ORDERED_LOWER_ALPHA = 1,
    TWIG_ORDERED_UPPER_ALPHA = 2,
    TWIG_ORDERED_LOWER_ROMAN = 3,
    TWIG_ORDERED_UPPER_ROMAN = 4,
} TwigOrderedNumbering;

typedef enum TwigOrderedDelim {
    TWIG_ORDERED_DELIM_PERIOD = 0,
    TWIG_ORDERED_DELIM_PAREN_AFTER = 1,
    TWIG_ORDERED_DELIM_PAREN_BOTH = 2,
} TwigOrderedDelim;

typedef enum TwigAlignment {
    TWIG_ALIGN_DEFAULT = 0,
    TWIG_ALIGN_LEFT = 1,
    TWIG_ALIGN_RIGHT = 2,
    TWIG_ALIGN_CENTER = 3,
} TwigAlignment;

typedef enum TwigSmartPunctuation {
    TWIG_SMART_LEFT_SINGLE_QUOTE = 0,
    TWIG_SMART_RIGHT_SINGLE_QUOTE = 1,
    TWIG_SMART_LEFT_DOUBLE_QUOTE = 2,
    TWIG_SMART_RIGHT_DOUBLE_QUOTE = 3,
    TWIG_SMART_ELLIPSES = 4,
    TWIG_SMART_EM_DASH = 5,
    TWIG_SMART_EN_DASH = 6,
} TwigSmartPunctuation;

typedef enum TwigDirectiveForm {
    TWIG_DIRECTIVE_TEXT = 0,
    TWIG_DIRECTIVE_LEAF = 1,
    TWIG_DIRECTIVE_CONTAINER = 2,
} TwigDirectiveForm;

// One attribute pair for twig_builder_set_attrs. A NULL `value` is a *bare*
// attribute (HTML `disabled`), distinct from a present-but-empty value (`value`
// non-NULL, `value_len == 0`). Keys/values are copied.
typedef struct TwigKeyVal {
    const uint8_t *key;
    size_t key_len;
    const uint8_t *value;
    size_t value_len;
} TwigKeyVal;

// Create/destroy a builder handle.
TwigStatus twig_builder_create(TwigBuilder **out_builder);
void twig_builder_destroy(TwigBuilder *builder);

// Add a void-payload node (para, emph, block_quote, table, …); attach children
// afterward with twig_builder_set_children. A payload-bearing or unknown `kind`
// returns TWIG_STATUS_INVALID_ARGUMENT.
TwigStatus twig_builder_add(TwigBuilder *builder, int kind, uint32_t *out_id);

// Add a single-string-payload node (`kind` one of STR, SYMB, VERBATIM,
// INLINE_MATH, DISPLAY_MATH, URL, EMAIL, FOOTNOTE_REFERENCE, COMMENT, DOCTYPE,
// CDATA). Any other `kind` returns TWIG_STATUS_INVALID_ARGUMENT.
TwigStatus twig_builder_add_text(
    TwigBuilder *builder,
    int kind,
    const uint8_t *text,
    size_t text_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_heading(TwigBuilder *builder, uint32_t level, uint32_t *out_id);

// Add a code_block. has_lang == 0 leaves the info-string language absent (a NULL
// code_block lang); otherwise lang[0..lang_len] is the language.
TwigStatus twig_builder_add_code_block(
    TwigBuilder *builder,
    const uint8_t *lang,
    size_t lang_len,
    int has_lang,
    const uint8_t *text,
    size_t text_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_raw_block(
    TwigBuilder *builder,
    const uint8_t *format,
    size_t format_len,
    const uint8_t *text,
    size_t text_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_metadata(
    TwigBuilder *builder,
    const uint8_t *lang,
    size_t lang_len,
    const uint8_t *text,
    size_t text_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_raw_inline(
    TwigBuilder *builder,
    const uint8_t *format,
    size_t format_len,
    const uint8_t *text,
    size_t text_len,
    uint32_t *out_id
);

// Add a smart_punctuation node; `punct_kind` is a TwigSmartPunctuation code and
// `text` is the source spelling it stands for (e.g. "---" for an em dash).
TwigStatus twig_builder_add_smart_punctuation(
    TwigBuilder *builder,
    int punct_kind,
    const uint8_t *text,
    size_t text_len,
    uint32_t *out_id
);

// Add a link. has_destination/has_reference gate the two optional fields (NULL
// when 0). Attach the link text as children.
TwigStatus twig_builder_add_link(
    TwigBuilder *builder,
    const uint8_t *destination,
    size_t destination_len,
    int has_destination,
    const uint8_t *reference,
    size_t reference_len,
    int has_reference,
    uint32_t *out_id
);

// Add an image — like twig_builder_add_link, but children are the alt text.
TwigStatus twig_builder_add_image(
    TwigBuilder *builder,
    const uint8_t *destination,
    size_t destination_len,
    int has_destination,
    const uint8_t *reference,
    size_t reference_len,
    int has_reference,
    uint32_t *out_id
);

// Add a generic directive; `form` is a TwigDirectiveForm code.
TwigStatus twig_builder_add_directive(
    TwigBuilder *builder,
    int form,
    const uint8_t *name,
    size_t name_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_element(
    TwigBuilder *builder,
    const uint8_t *name,
    size_t name_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_processing_instruction(
    TwigBuilder *builder,
    const uint8_t *target,
    size_t target_len,
    const uint8_t *data,
    size_t data_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_footnote(
    TwigBuilder *builder,
    const uint8_t *label,
    size_t label_len,
    uint32_t *out_id
);

TwigStatus twig_builder_add_reference(
    TwigBuilder *builder,
    const uint8_t *label,
    size_t label_len,
    const uint8_t *destination,
    size_t destination_len,
    uint32_t *out_id
);

// Add a bullet_list; `style` is a TwigBulletStyle code, `tight` a 0/1 flag.
TwigStatus twig_builder_add_bullet_list(
    TwigBuilder *builder,
    int style,
    int tight,
    uint32_t *out_id
);

// Add an ordered_list; `numbering`/`delim` are TwigOrderedNumbering/
// TwigOrderedDelim codes. has_start == 0 leaves the first number implicit.
TwigStatus twig_builder_add_ordered_list(
    TwigBuilder *builder,
    int numbering,
    int delim,
    int tight,
    uint32_t start,
    int has_start,
    uint32_t *out_id
);

TwigStatus twig_builder_add_task_list(TwigBuilder *builder, int tight, uint32_t *out_id);
TwigStatus twig_builder_add_task_list_item(TwigBuilder *builder, int checked, uint32_t *out_id);
TwigStatus twig_builder_add_row(TwigBuilder *builder, int head, uint32_t *out_id);

// Add a table cell; `alignment` is a TwigAlignment code.
TwigStatus twig_builder_add_cell(TwigBuilder *builder, int head, int alignment, uint32_t *out_id);

// Set `parent`'s children to `ids` (in order), replacing any it had. Every id
// (parent and each child) must name a node already added; a child id should
// appear in exactly one set_children call across the build.
TwigStatus twig_builder_set_children(
    TwigBuilder *builder,
    uint32_t parent,
    const uint32_t *ids,
    size_t ids_len
);

// Attach `{...}` attributes to `id`, replacing any it had; kvs_len == 0 clears
// them.
TwigStatus twig_builder_set_attrs(
    TwigBuilder *builder,
    uint32_t id,
    const TwigKeyVal *kvs,
    size_t kvs_len
);

// Render the subtree rooted at `root` to HTML via the generic whole-vocabulary
// printer. Borrowed output, valid until the next twig_builder_render_html on
// this handle or its destruction.
TwigStatus twig_builder_render_html(
    TwigBuilder *builder,
    uint32_t root,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Serialize the subtree rooted at `root` to `format`'s source syntax.
// TWIG_STATUS_UNSUPPORTED_FORMAT when the target can't represent the built tree
// (e.g. semantic kinds into XML). Borrowed output, same contract as above.
TwigStatus twig_builder_serialize(
    TwigBuilder *builder,
    uint32_t root,
    int format,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Encode the subtree rooted at `root` as pretty-printed JSON. Borrowed output.
TwigStatus twig_builder_ast_json(
    TwigBuilder *builder,
    uint32_t root,
    const uint8_t **out_ptr,
    size_t *out_len
);

// Resolve a selector against the subtree rooted at `root`. Same grammar and
// borrowed-output contract as twig_document_query.
TwigStatus twig_builder_query(
    TwigBuilder *builder,
    uint32_t root,
    const uint8_t *selector,
    size_t selector_len,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

#ifdef __cplusplus
}
#endif
