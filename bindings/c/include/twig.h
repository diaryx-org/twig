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
//     reused — so a new document format, or a new export-only output target, is
//     TWIG_FORMAT_* = <next int>, leaving every prior code untouched.
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
// 3: TwigFlatNode grew name/attrs (104 -> 136 bytes) — an element's tag name
//    and a node's (key, value) attributes on the read path. Appended, same as 2.
// 4: TwigFlatNode grew directive_form (136 -> 144 bytes), and name_ptr now also
//    reports a directive's type — the two halves of a directive's identity,
//    neither of which `kind` ("directive") carries. Appended, same as 2.
// 5: TwigFlatNode grew container_origin — whether a container was written as a
//    tag or as a directive. An HTML <div> and a Markdown :::div agree on kind,
//    on name_ptr and on directive_form, field for field, so none of those three
//    could answer it. Unlike 2-4 this one lands in directive_form's tail
//    padding: sizeof is still 144 and every prior offset is unchanged, so a
//    version-4 consumer linked against this library is bit-for-bit correct and
//    needs no rebuild. The bump is for the other direction — a version-5
//    consumer against an older library reads uninitialized padding, and
//    twig_abi_version() is the only way to catch that.
// 6: TwigFlatNode grew marker_span/has_marker_span (144 -> 168 bytes) — the
//    leading bytes a rich view HIDES for this node (a heading's #s, an item's
//    "- ", a quote's "> "). span and content_span together cannot express it
//    for a marker-prefixed container, which reports content_span == span
//    because no contiguous range is such a container's interior. Appended, so
//    every prior offset is unchanged and only sizeof moves — same as 2 and 3.
//    `checked` landed in this same version rather than a seventh: it fits in
//    has_marker_span's tail padding, and no release ever carried a version 6
//    without it, so numbering it separately would name a contract that never
//    existed. Once 6 ships, this note freezes.
#define TWIG_ABI_VERSION 6

// The TWIG_FORMAT_* codes span BOTH format axes, in one integer space:
//   - what a document can be PARSED as   (twig_parse, twig_editor_create)
//   - what a document can be WRITTEN as  (twig_document_serialize,
//                                         twig_builder_serialize)
// Every code below is valid for both. A future EXPORT-ONLY target — one twig
// can write and no parser can read back — appends a code that the write
// functions accept and the parse functions reject with
// TWIG_STATUS_UNSUPPORTED_FORMAT. Check the per-code notes; do not assume a code
// accepted by twig_document_serialize is also accepted by twig_parse.
#define TWIG_FORMAT_DJOT 1
#define TWIG_FORMAT_MARKDOWN 2
#define TWIG_FORMAT_XML 3
#define TWIG_FORMAT_HTML 4
// Parses and renders, but does not serialize: twig_serialize_document with
// TWIG_FORMAT_ASCIIDOC reports TWIG_STATUS_UNSUPPORTED_FORMAT, and no editing
// gesture applies to an AsciiDoc document. The parser also covers a SLICE of
// the language rather than all of it; what it doesn't implement survives as
// literal source text. See src/format.zig's `.asciidoc` registry row.
#define TWIG_FORMAT_ASCIIDOC 5

// Markdown extension flags for the `md_flags` bitmask of twig_parse_ext and
// twig_editor_create_ext (ignored for non-Markdown formats). Each is an opt-in,
// default-off extension; a 0 mask is the plain twig_parse/twig_editor_create.
#define TWIG_MD_DIRECTIVES    (1u << 0)  // generic directives: :name, ::name, :::name
#define TWIG_MD_MATH          (1u << 1)  // $...$ / $$...$$ math
#define TWIG_MD_HTML_ELEMENTS (1u << 2)  // parse raw HTML into semantic AST nodes
#define TWIG_MD_HIGHLIGHT     (1u << 3)  // ==text== highlight, parsed as a `mark`

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

// One attribute pair — a (key, value) as written. A NULL `value` is a *bare*
// attribute (HTML `disabled`, `<source media=...>` used as a flag), distinct
// from a present-but-empty value (`value` non-NULL, `value_len == 0`). Used on
// both the read path (TwigFlatNode.attrs, where key/value BORROW the node's
// payload — same lifetime as text_ptr) and the write path
// (twig_builder_set_attrs, where they are COPIED in).
typedef struct TwigKeyVal {
    const uint8_t *key;
    size_t key_len;
    const uint8_t *value;
    size_t value_len;
} TwigKeyVal;

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
//
// name_ptr is the name a generic container carries in its own payload: an
// HTML/XML tag ("picture", "video", "svg:rect") or a directive's type ("note",
// "embed", no leading colons) — NULL for every other kind. `kind` reports every
// one of them as "container", so this is the whole of a container's identity.
// It is EMPTY (non-NULL, length 0) for djot's anonymous ::: and [...]{...},
// which carry theirs as a class instead.
//
// The two int fields beside it answer two different questions, and mixing them
// up is the mistake this comment exists to prevent:
//
//   directive_form (TWIG_DIRECTIVE_*, or TWIG_DIRECTIVE_NONE) says WHICH OF THE
//     THREE generic-container spellings fits — inline :name[x], block leaf
//     ::name{...}, or a :::name fence. A consumer must render those
//     differently. It is NOT "is this a directive?": HTML's parser sets a form
//     on <div> and <span>, the two tags djot and Markdown have generic
//     spellings for, so a <div> reports CONTAINER and a <video> reports NONE.
//
//   container_origin (TWIG_CONTAINER_ORIGIN_*) says whether the node was
//     WRITTEN as a tag or as a directive. This is the one that separates an
//     HTML <div> from a Markdown :::div; they agree on kind, name_ptr and
//     directive_form. TWIG_CONTAINER_ORIGIN_NONE means nothing recorded it —
//     the node is not a container, or no parser produced it.
//
// checked is a task_list_item's checkbox state: 1 checked, 0 unchecked,
// TWIG_TASK_CHECKED_NONE for every other kind. The parser has always known this
// — it is what decides task_list_item over list_item in the first place — and
// nothing surfaced it, so a consumer rendering a clickable checkbox re-derived
// the state by scanning the source for "[x]". That scan is fooled by a "[" in
// prose, and it asks the bytes a question the tree had already answered.
//
// marker_span (valid only when has_marker_span is non-zero) is the node's own
// MARKER — the leading bytes a rich view HIDES, on its opening line: a heading's
// #s and the space after them, a list item's "- " / "1. ", a task item's marker
// plus its "[x] " box, a block quote's "> ".
//
// It is NOT derivable from span and content_span. For a heading it happens to
// equal [span.start, content_span.start); for a marker-prefixed container it
// does not, because those report content_span == span — a prefix that repeats on
// every line has no contiguous interior to point at. Before this field the
// answer was recoverable only by a per-format rule (from the item's inner
// paragraph in Markdown, from the item itself in djot), which is exactly the
// "which parser produced this?" reasoning a shared AST exists to remove.
//
// It covers ONE LINE and this node's own marker alone. For the whole prefix a
// nested construct sits behind (">   1. [ ] " is four nodes' markers plus the
// indent between them), call twig_document_line_prefix.
//
// attrs is the node's (key, value) attributes in source order (attrs_len of
// them), or NULL/0 for a node with none. Both borrow the node's payload with the
// same lifetime as text_ptr/destination_ptr (invalid after the next successful
// edit); the TwigKeyVal records additionally live in a snapshot-owned buffer
// replaced on the next twig_editor_nodes / twig_editor_subtree call.
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
    const uint8_t *name_ptr;
    size_t name_len;
    const TwigKeyVal *attrs_ptr;
    size_t attrs_len;
    int directive_form;
    int container_origin;
    TwigSpan marker_span;
    int has_marker_span;
    int checked;
} TwigFlatNode;

// TwigFlatNode.checked for a node that is not a task_list_item. Spelled out
// rather than folded into 0, because "unchecked" is a real state and a consumer
// treating "not a task item" as unchecked draws an empty box beside every
// paragraph in the document.
#define TWIG_TASK_CHECKED_NONE (-1)

// TwigFlatNode.head for a node that is neither a row nor a cell.
#define TWIG_HEAD_NONE (-1)

// TwigFlatNode.alignment for a node that isn't a cell. The other four codes are
// the TwigAlignment enumerators below; this one is deliberately not among them,
// because TwigAlignment is also twig_builder_add_cell's parameter type and
// "not a cell" is not an alignment you can build with. The delimiter row
// (|:--|--:|) that spells a column's alignment out is consumed by the parser and
// has no node, so TwigFlatNode.alignment is the only way to recover it.
#define TWIG_ALIGN_NONE (-1)

// TwigFlatNode.directive_form for a node that isn't a directive. The three real
// forms are the TwigDirectiveForm enumerators below — :name[x] inline (TEXT),
// ::name{...} as a standalone block with no body (LEAF), :::name{...} ... :::
// around blocks (CONTAINER) — and this one is deliberately not among them, for
// the same reason TWIG_ALIGN_NONE isn't a TwigAlignment: that enum is also
// twig_builder_add_directive's parameter type, and "not a directive" is not a
// form you can build with. All three real forms report kind == "container" and
// carry their type in name_ptr.
#define TWIG_DIRECTIVE_NONE (-1)

// TwigFlatNode.container_origin: whether a generic container was WRITTEN as a
// tag or as a directive — the question kind/name_ptr/directive_form agree on
// for an HTML <div> and a Markdown :::div, and so cannot answer between them.
//
// TWIG_CONTAINER_ORIGIN_NONE means nothing recorded an origin: the node is not
// a container, or no parser produced it (a twig_builder_* tree). Not a
// TwigContainerOrigin enumerator, for the same reason TWIG_ALIGN_NONE isn't a
// TwigAlignment.
#define TWIG_CONTAINER_ORIGIN_NONE (-1)
// An HTML or XML tag: <div>, <video>, <svg:rect>.
#define TWIG_CONTAINER_ORIGIN_ELEMENT 0
// A lightweight-markup generic container: a djot fenced div or bracketed span,
// a Markdown :::note / ::name / :name, an rST .. note::, an AsciiDoc delimited
// block.
#define TWIG_CONTAINER_ORIGIN_DIRECTIVE 1

// One thing converting a document to a given target would silently lose.
//
// path_ptr/path_len is a slash-separated child-index trail from the analyzed
// root ("1/0/2"); EMPTY (NULL/0) means the root itself. `kind` is the affected
// node's published kind name, in static library-owned storage. Both are
// borrowed and share the lifetime of twig_document_diagnostics's output array.
//
// There is deliberately no message string: a warning is structured, and every
// consumer that renders one wants its own wording.
typedef struct TwigWarning {
    int fidelity;
    const uint8_t *path_ptr;
    size_t path_len;
    const char *kind;
} TwigWarning;

// TwigWarning.fidelity codes. FAITHFUL exists so the space is complete and a
// consumer can spell the concept; it is never the value of a reported warning,
// because a faithful node is not a warning.
#define TWIG_FIDELITY_FAITHFUL 0
// Something is emitted, but the target's parser reads it back as a DIFFERENT
// kind. The content survives; its meaning does not.
#define TWIG_FIDELITY_DEGRADED 1
// Nothing is emitted at all: the node and its subtree leave no trace.
#define TWIG_FIDELITY_DROPPED 2

// What converting `doc` to `format` would silently LOSE: one TwigWarning per
// lossy node, in document order, borrowed until the next
// twig_document_diagnostics call on this document or twig_document_destroy.
//
// Every serializer degrades or drops a node when the target has no spelling for
// it — a djot {=mark=} written into Markdown comes back as plain text, an HTML
// comment converted to djot vanishes — and none of it is an error, so all of it
// happens quietly. This is where it stops being quiet.
//
// The answer is a property of the (document, target) PAIR, which is why it is
// computed on demand rather than stored: the same document converted to two
// targets has two different answers and neither belongs to the document.
//
// A format with no serializer at all (XML, AsciiDoc) reports
// TWIG_STATUS_UNSUPPORTED_FORMAT rather than warning about every node in turn.
//
// An empty result (*out_len == 0, *out_warnings == NULL) means the conversion
// is lossless — a real answer, not a failure.
// Non-const `doc` for the reason every other read here is: the result is
// cached on the handle so the caller can borrow it.
TwigStatus twig_document_diagnostics(
    TwigDocument *doc,
    int format,
    const TwigWarning **out_warnings,
    size_t *out_len
);

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

// Like twig_parse, plus `md_flags` — a bitmask of TWIG_MD_* Markdown extensions
// to enable (ignored for non-Markdown formats). Opens the read/query surface to
// the same opt-in extensions twig_editor_create_ext gives the edit surface; a 0
// mask is exactly twig_parse.
TwigStatus twig_parse_ext(
    const uint8_t *input,
    size_t input_len,
    int format,
    uint32_t md_flags,
    TwigDocument **out_doc
);

// Destroy a document handle. A no-op for a borrowed handle (one obtained from
// twig_editor_document), which its editor owns and frees.
void twig_document_destroy(TwigDocument *doc);

// Render a parsed document to HTML. For Djot/Markdown this is the rich
// rendering path that resolves reference/footnote side tables. Returns
// TWIG_STATUS_UNSUPPORTED_FORMAT for a view borrowed from an editor (it has the
// tree, not the language side tables — render twig_editor_source via twig_parse).
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
// serializer (today: converting into XML from another format), and likewise for
// a view borrowed from an editor, whose current bytes twig_editor_source hands
// back directly.
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

// The source span of node `node_id` — the accessor form of
// TwigQueryMatch.span, usable with any node id (e.g. one held across queries)
// without re-running a query. Writes into *out_span and returns
// TWIG_STATUS_OK; TWIG_STATUS_INVALID_ARGUMENT for an out-of-range id.
// Additive in ABI v4 — the struct fields remain.
TwigStatus twig_document_node_span(
    TwigDocument *doc,
    uint32_t node_id,
    TwigSpan *out_span
);

// The interior (between-delimiters) span of node `node_id` — the accessor form
// of TwigQueryMatch.content_span/has_content_span, with TWIG_STATUS_NOT_FOUND
// replacing the has_content_span == 0 convention (*out_span is untouched).
// TWIG_STATUS_INVALID_ARGUMENT for an out-of-range id. Additive in ABI v4.
TwigStatus twig_document_node_content_span(
    TwigDocument *doc,
    uint32_t node_id,
    TwigSpan *out_span
);

// The span of node `node_id`'s own leading MARKER — the accessor form of
// TwigFlatNode.marker_span/has_marker_span, usable with any node id without
// taking a whole snapshot. TWIG_STATUS_NOT_FOUND when the node has no marker
// (see the struct field's comment for which those are),
// TWIG_STATUS_INVALID_ARGUMENT for an out-of-range id. Additive in ABI v6.
TwigStatus twig_document_node_marker_span(
    TwigDocument *doc,
    uint32_t node_id,
    TwigSpan *out_span
);

// Everything HIDDEN before the content on the line byte `offset` sits on: every
// marker a node OPENS that line with, and the indentation between them, as one
// span running from the line start.
//
// This is the assembled form of TwigFlatNode.marker_span, which records each
// node's own marker alone. ">   1. [ ] " is four nodes' markers plus the spaces
// between them, and the union is contiguous from the line start — so a caller
// gets one range to hide, or one width for a caret to step over, rather than a
// chain to walk and stitch together itself.
//
// TWIG_STATUS_NOT_FOUND when nothing opens on this line — a CONTINUATION line,
// the second line of a wrapped paragraph or of a block quote. That is a real
// answer, not a gap: what a continuation line repeats is a different question
// (a quote re-emits "> ", a list item re-emits spaces) and is not answerable
// from marker spans. TWIG_STATUS_INVALID_ARGUMENT if offset > source length.
// Additive in ABI v6.
TwigStatus twig_document_line_prefix(
    TwigDocument *doc,
    size_t offset,
    TwigSpan *out_span
);

// What a CONTINUATION LINE at byte `offset` must open with to stay inside every
// container holding it, plus that prefix's width in COLUMNS.
//
// The other half of twig_document_line_prefix, and not derivable from it. That
// one reports the bytes ALREADY THERE on a line something opens, so it hands
// back a span into the source. This one reports the bytes that WOULD HAVE TO BE
// WRITTEN on a line nothing opens — a list item's continuation is spaces where
// its marker was, which is not source at all, so it is built rather than
// pointed at.
//
// A quote's "> " is REPRODUCED (dropping it ends the quote); a list item's
// marker becomes its WIDTH IN SPACES (repeating it would open a second item).
// Each container on the caret's chain contributes the columns its own marker
// occupies, on its own opening line — which may be a different line for each of
// them, and is why this is a tree walk rather than a re-read of one line:
//
//     > - a      quote "> " + item "- " as width   ->  ">   "
//     - a
//       - b      outer item + inner item           ->  "    "
//
// out_columns may be NULL if the caller wants only the bytes. It is NOT out_len:
// a tab in a marker advances to a tab stop, so "-\tx" yields four columns from a
// two-byte marker, and an editor sizing a Tab step or a caret's horizontal home
// wants the column count.
//
// The bytes are borrowed from `doc` and stay valid until the next
// twig_document_continuation_prefix / twig_document_blank_line_prefix call on
// the same handle, or until it is destroyed. out_ptr is NULL and
// out_len/out_columns are 0 at the top level, which is the correct prefix there:
// none. TWIG_STATUS_INVALID_ARGUMENT if offset > source length. Additive in
// ABI v6.
TwigStatus twig_document_continuation_prefix(
    TwigDocument *doc,
    size_t offset,
    const uint8_t **out_ptr,
    size_t *out_len,
    size_t *out_columns
);

// What a BLANK line inside the containers at byte `offset` must carry, plus its
// width in columns. Same borrow contract as twig_document_continuation_prefix.
//
// A quote's blank line still has to carry its ">" or the quote ENDS there; a
// list item's must carry nothing, because a blank line between two of an item's
// blocks is what makes its list loose and indenting it changes nothing about
// that. So this is the continuation prefix with its trailing spaces cut back —
// which drops an item's indent entirely and leaves a quote marker standing.
//
// The quote form is ">" and not "> ", because the space after the marker is
// content indentation and a blank line has no content. Additive in ABI v6.
TwigStatus twig_document_blank_line_prefix(
    TwigDocument *doc,
    size_t offset,
    const uint8_t **out_ptr,
    size_t *out_len,
    size_t *out_columns
);

// The source span of the `{...}` attribute block attached to node `node_id` —
// the range a lossless serializer re-emits instead of the flattened
// TwigFlatNode.attrs projection (a multi-line option block, or a nested or
// array-valued entry, says more than the flat (key, value) pairs preserve).
// TWIG_STATUS_NOT_FOUND when the node has no attributes, or has some with no
// single recorded range (a synthesized set, or one merged from several source
// blocks). TWIG_STATUS_INVALID_ARGUMENT for an out-of-range id.
//
// A new function rather than a field on TwigFlatNode: the range is per
// attribute BLOCK, not per (key, value) pair, so TwigKeyVal is the wrong home,
// and growing TwigFlatNode would bump TWIG_ABI_VERSION. Additive in ABI v4.
// The document-level DEFINITIONS: every node that hangs off no parent and is
// not the document root, as TwigQueryMatches in arena order. Borrowed until the
// next twig_document_definitions call on this document or twig_document_destroy.
//
// Footnote definitions and link-reference definitions are resolved by LABEL
// rather than by position, so the parsers attach them to nothing — a walk from
// the document root never reaches them, and a renderer that wants to resolve a
// footnote reference has to find them some other way. This is that other way.
//
// Deliberately not filtered to a kind list: WHICH kinds end up detached is a
// property of how a format resolves its definitions (djot and Markdown detach
// `footnote` and `reference`; rST adds `citation` and `substitution`), not
// something a caller should have to enumerate. Read the `kind` on each match.
//
// An empty result is the common case — most documents define nothing.
TwigStatus twig_document_definitions(
    TwigDocument *doc,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

TwigStatus twig_document_attrs_span(
    TwigDocument *doc,
    uint32_t node_id,
    TwigSpan *out_span
);

// How many COLUMNS the cell at `node_id` occupies — HTML's colspan, rST's
// morecols plus one. Always at least 1; 1 is the ordinary one-square cell.
// TWIG_STATUS_NOT_FOUND when the node is not a cell (*out_colspan untouched),
// TWIG_STATUS_INVALID_ARGUMENT for an out-of-range id.
//
// An accessor rather than a TwigFlatNode field, for the reason
// twig_document_attrs_span gives: growing the struct bumps TWIG_ABI_VERSION for
// every consumer and a new symbol does not. A table renderer pays one extra
// call per cell. Additive in ABI v4.
TwigStatus twig_document_cell_colspan(
    TwigDocument *doc,
    uint32_t node_id,
    uint32_t *out_colspan
);

// How many ROWS the cell at `node_id` occupies — HTML's rowspan, rST's morerows
// plus one. Always at least 1. HTML's rowspan="0" ("to the end of the row
// group") is not a count and reports 1; the source spelling survives on the
// node's attributes. Same contract as twig_document_cell_colspan. Additive in
// ABI v4.
TwigStatus twig_document_cell_rowspan(
    TwigDocument *doc,
    uint32_t node_id,
    uint32_t *out_rowspan
);

// ── Document tree read-back ─────────────────────────────────────────────────
// The JSON-free tree walk, for any document: a parse (twig_parse) or an
// editor's live tree (twig_editor_document). These five predate this section as
// twig_editor_nodes / _child_spans / _subtree / _node_at / _nodes_at, which
// remain as aliases onto the same code and the same buffers. Purely additive —
// no struct changed, so TWIG_ABI_VERSION stays 4.

// Snapshot the whole tree as a flat array of TwigFlatNode, one per arena node,
// indexed so array[i].id == i. Walk it via the parent / first_child /
// next_sibling id links (TWIG_NO_NODE where absent).
//
// The array is the whole ARENA, and a parsed document is not one tree, so
// SEVERAL nodes can have parent == TWIG_NO_NODE. The document root is one of
// them; the others are the document-level definitions — footnote and
// link-reference definitions are resolved by label rather than by position, so
// the parsers attach them to nothing. A walk from the document root will not
// reach them. Use twig_document_definitions to enumerate them rather than
// re-deriving them by scanning this array (this text used to say "the root is
// the node whose parent == TWIG_NO_NODE", which is where that scan came from).
//
// Borrowed from `doc`, valid until the next twig_document_nodes call on that
// handle or until it is destroyed. For an editor view, the text/destination
// pointers within additionally require no successful edit since (a reparse
// frees the payloads they borrow).
TwigStatus twig_document_nodes(
    TwigDocument *doc,
    const TwigFlatNode **out_ptr,
    size_t *out_len
);

// The direct children of `node_id` as TwigQueryMatch (id, span, kind) — the
// cheap enumeration an incremental renderer uses to find the blocks it must
// consider without marshalling the whole arena; pair with twig_document_subtree
// to re-marshal only the block(s) that changed. Pass TWIG_NO_NODE for node_id
// to enumerate the DOCUMENT ROOT's children (the top-level blocks). Same borrow
// contract as twig_document_query, on its own buffer. A childless node yields a
// zero-length result and TWIG_STATUS_OK; a node_id neither in range nor the
// sentinel is TWIG_STATUS_INVALID_ARGUMENT.
TwigStatus twig_document_children(
    TwigDocument *doc,
    uint32_t node_id,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// Snapshot the subtree rooted at `node_id` as a self-contained TwigFlatNode
// array with LOCAL ids: array[0] is the root, every id / parent / first_child /
// next_sibling indexes into THIS array (or TWIG_NO_NODE), and spans stay
// ABSOLUTE. The root's parent and next_sibling are TWIG_NO_NODE, so a walk from
// index 0 never leaves the subtree. Same borrow contract as
// twig_document_nodes, on its own buffer; node_id out of range is
// TWIG_STATUS_INVALID_ARGUMENT.
TwigStatus twig_document_subtree(
    TwigDocument *doc,
    uint32_t node_id,
    const TwigFlatNode **out_ptr,
    size_t *out_len
);

// The deepest node whose span contains byte `offset` (half-open [start, end),
// with offset == source length treated as inside the root) — mouse hit-testing
// and cursor context. Fills out_match and returns TWIG_STATUS_OK, or
// TWIG_STATUS_NOT_FOUND if no node covers the offset
// (TWIG_STATUS_INVALID_ARGUMENT if offset > source length). out_match is a value
// copy (its `kind` is static).
TwigStatus twig_document_node_at(
    TwigDocument *doc,
    size_t offset,
    TwigQueryMatch *out_match
);

// The chain of nodes containing byte `offset`, root-first down to the deepest
// (the node twig_document_node_at returns) — the ancestor path for breadcrumbs
// or context-scoped edits. Same borrow contract as twig_document_query, on an
// independent buffer. Returns TWIG_STATUS_NOT_FOUND (and a zero-length result)
// if nothing covers the offset.
TwigStatus twig_document_nodes_at(
    TwigDocument *doc,
    size_t offset,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// twig_document_node_at under CARET containment — the same descent, under the
// rule an editing caret needs rather than the one a byte range needs.
//
// Two differences, both because a caret is a position BETWEEN bytes while a span
// is a range OF bytes:
//
//   1. A block's END is inside it. A caret after the last character of a
//      paragraph is IN that paragraph — it is where you stand to type the rest
//      of it. Half-open containment puts it outside, which is why a consumer
//      probing twig_document_nodes_at ended up guessing at contrived offsets
//      (the content start, caret - 1, a marker byte) to find the block it was
//      plainly inside of.
//
//   2. A trailing newline is not part of the block, which is what makes the two
//      authorable formats AGREE. Djot ends a paragraph's span after its newline
//      and Markdown before it, so on "a\n\nb\n" the caret at offset 1 read as
//      "para" through djot and "doc" through Markdown — the same caret, two
//      answers, decided by which parser produced the tree.
//
// Never returns TWIG_STATUS_NOT_FOUND for a non-empty document: a caret in the
// gap between two blocks reports the container holding the gap (usually the
// root) rather than nothing at all. Additive in ABI v6.
TwigStatus twig_document_node_at_caret(
    TwigDocument *doc,
    size_t offset,
    TwigQueryMatch *out_match
);

// twig_document_nodes_at under caret containment — root-first down to the node
// twig_document_node_at_caret returns. Same borrow contract as
// twig_document_nodes_at, on its own independent buffer (a renderer hit-testing
// a mouse and an editor tracking a caret are two live readers; neither call
// invalidates the other's slice). Additive in ABI v6.
TwigStatus twig_document_nodes_at_caret(
    TwigDocument *doc,
    size_t offset,
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

// ── Format capability (the toolbar's gray-out question) ───────────────────────
// Twig's formats are RAGGED: Djot spells all eight inline marks and Markdown
// three, HTML spells marks and nothing block-level, XML and AsciiDoc spell
// nothing. Every gesture below already reports that, as
// TWIG_STATUS_UNSUPPORTED_FORMAT — but only once called, which is too late for a
// UI that wants to DISABLE the button instead of letting it fail. An editor
// building its toolbar has a format and no document yet.
//
// twig_format_supports is that same answer, asked earlier. It is a pure function
// of the format code — no handle, no document, no allocation — so ask once at
// startup and cache. A Zig test pins it against every gesture's real refusal in
// every format, so it cannot drift into claiming a button works when the call
// would refuse.

// The gestures twig_format_supports answers for. One entry per gesture with a
// FORMAT-level gate — which, since 15-23 were added, is every gesture the editor
// has. The names match the twig_editor_* function they ask about. (The integer
// values are the wire contract — do not renumber, and append only.)
//
// 15-23 were absent until the formats they lied to were noticed. All nine used
// to read no format spelling at all, so they refused on position and never on
// format — and an HTML document is where that stopped being harmless:
//
//   - TWIG_GESTURE_TABLE_* — HTML's parser lowers <table>/<tr>/<td> to the same
//     nodes a pipe table produces, so twig_editor_table_edit extracted the grid
//     and wrote GFM pipe text over the <table>…</table> region. HTML reparses
//     that as a paragraph — a document that still parses, so no rollback, no
//     error, and the table destroyed. These nine codes are how a caller asks
//     first.
//   - TWIG_GESTURE_SPLIT_BLOCK — the blank line it writes means "two blocks"
//     only where blank lines separate blocks. In HTML it is whitespace inside
//     the <p>: one paragraph in, one paragraph out, TWIG_STATUS_OK returned.
//   - TWIG_GESTURE_RENUMBER_ORDERED_LISTS — a textual N. / N) rewrite finds
//     nothing in an <ol>, whose numbering lives in the tag, and reported the
//     no-op as success.
typedef enum TwigGesture {
    TWIG_GESTURE_WRAP_RANGE = 0,
    TWIG_GESTURE_TOGGLE_INLINE = 1,
    TWIG_GESTURE_SET_BLOCK = 2,
    TWIG_GESTURE_TOGGLE_BLOCK_CONTAINER = 3,
    TWIG_GESTURE_INSERT_THEMATIC_BREAK = 4,
    TWIG_GESTURE_TOGGLE_CODE_BLOCK = 5,
    TWIG_GESTURE_SET_CODE_LANGUAGE = 6,
    TWIG_GESTURE_TOGGLE_TASK_ITEM = 7,
    TWIG_GESTURE_SET_TASK_CHECKED = 8,
    TWIG_GESTURE_TOGGLE_TASK_CHECKED = 9,
    TWIG_GESTURE_INSERT_LINK = 10,
    TWIG_GESTURE_INSERT_IMAGE = 11,
    TWIG_GESTURE_INSERT_FOOTNOTE = 12,
    TWIG_GESTURE_INSERT_LITERAL = 13,
    TWIG_GESTURE_INSERT_LINE_BREAK = 14,
    TWIG_GESTURE_SPLIT_BLOCK = 15,
    TWIG_GESTURE_RENUMBER_ORDERED_LISTS = 16,
    TWIG_GESTURE_TABLE_INSERT_ROW = 17,
    TWIG_GESTURE_TABLE_DELETE_ROW = 18,
    TWIG_GESTURE_TABLE_INSERT_COLUMN = 19,
    TWIG_GESTURE_TABLE_DELETE_COLUMN = 20,
    TWIG_GESTURE_TABLE_SET_ALIGNMENT = 21,
    TWIG_GESTURE_TABLE_MOVE_ROW = 22,
    TWIG_GESTURE_TABLE_MOVE_COLUMN = 23,
} TwigGesture;

// Whether `format` (a TWIG_FORMAT_* code) can spell `gesture` — writes 1 or 0
// through out_supported.
//
// `kind` is read in THAT GESTURE'S OWN kind space, so the constant is the same
// one the twig_editor_* call takes:
//
//   - TWIG_GESTURE_WRAP_RANGE / _TOGGLE_INLINE      a TwigInlineKind
//   - TWIG_GESTURE_TOGGLE_BLOCK_CONTAINER           a TwigBlockContainerKind
//   - every other gesture                           must be 0
//
// A stray non-zero `kind` on a kindless gesture is TWIG_STATUS_INVALID_ARGUMENT
// rather than ignored: a caller that forgot to reset the argument gets told,
// instead of a confident answer to a question it did not ask. Same status for a
// `kind` or `gesture` naming nothing, or a NULL out_supported;
// TWIG_STATUS_UNSUPPORTED_FORMAT for an unknown format code.
//
// A 1 means the gesture will not fail with TWIG_STATUS_UNSUPPORTED_FORMAT. It is
// NOT a promise the call succeeds — the caret still decides, and NOT_FOUND /
// INVALID_ARGUMENT / the rollback contract all remain in play. Gray out on 0;
// do not read a 1 as "this will work here".
//
// Note this is a strictly different question from the per-node `fidelity` field
// on TwigWarning, which reports what survives a CONVERSION to a target. The two
// genuinely disagree — Djot round-trips a smart-quote container faithfully while
// no editor gesture may author one. Use fidelity for a save-as warning and this
// for an enabled/disabled button.
TwigStatus twig_format_supports(
    int format,
    int gesture,
    int kind,
    int *out_supported
);

// Whether `format` can be authored into AT ALL — writes 1 or 0 through
// out_authorable. TWIG_STATUS_UNSUPPORTED_FORMAT for an unknown format code,
// TWIG_STATUS_INVALID_ARGUMENT for a NULL out_authorable.
//
// This answers the open-read-only question and only that one: 0 for a parse-only
// format (XML, AsciiDoc), where every gesture refuses and an editor should offer
// no toolbar at all.
//
// A 1 is a WEAKER claim than it looks, and driving per-button state from it is
// the mistake this comment exists to prevent. HTML answers 1 — it spells the
// inline marks — while TWIG_GESTURE_SET_BLOCK, the container, code-block, task
// and footnote gestures and TWIG_GESTURE_INSERT_LITERAL are all still
// unsupported there. Use twig_format_supports per button.
TwigStatus twig_format_is_authorable(int format, int *out_authorable);

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

// A monotonic change token for `editor`, bumped once per successful mutation of
// the document (edit_range, the locator ops, and undo/redo alike). Never
// decreases and never repeats for the life of the editor; the initial parse is
// revision 0. Equal revision => byte-identical document, so a caller can key a
// cache on it instead of hand-tracking "did anything change?". Returns 0 for a
// NULL editor (which also matches a fresh editor — harmless as a cache key).
uint64_t twig_editor_revision(TwigEditor *editor);

// Report the cumulative dirty byte range for `editor` — the union of every
// mutation's byte effect (edit_range, the locator ops, and undo/redo alike)
// since the last twig_editor_clear_dirty, or since the editor was created if it
// has never been cleared — in CURRENT source coordinates. Writes it into
// `out_span` and returns TWIG_OK; returns TWIG_NOT_FOUND when the document is
// clean relative to the last clear (`out_span` untouched).
//
// The incremental-rebuild companion to twig_editor_revision: revision says
// WHETHER to rebuild a cached view, this says WHICH bytes, so a consumer touches
// only the affected rows/spans. A single CONSERVATIVE interval: always covers
// every changed byte, may over-cover the gap between disjoint edits, never
// under-covers. It reports where BYTES differ (exact — Twig splices losslessly)
// NOT where the PARSE differs: an edit can reinterpret bytes outside the range
// (opening a code fence, a `#` promoting a paragraph to a heading), so a
// consumer rebuilding STRUCTURE should widen the range to the enclosing
// block(s) itself (e.g. via twig_editor_node_at on each end).
TwigStatus twig_editor_dirty_range(TwigEditor *editor, TwigSpan *out_span);

// Acknowledge the current dirty range: mark `editor` clean so the next
// twig_editor_dirty_range reports only mutations made after this call. Call it
// once you've consumed the range. Leaves the document, twig_editor_revision, and
// twig_editor_last_change untouched.
TwigStatus twig_editor_clear_dirty(TwigEditor *editor);

// Attach an opaque, caller-owned blob (e.g. a serialized caret/selection) to the
// editor's CURRENT document state. Twig copies the bytes and never interprets
// them; it only carries them through the undo history so undo/redo hand back the
// caret that matches the restored source (see twig_editor_caret_blob). Set it
// with the pre-edit caret BEFORE an edit so the retired undo step captures it. A
// zero-length blob clears the current caret. blob_ptr may be NULL only when
// blob_len is 0.
TwigStatus twig_editor_set_caret_blob(
    TwigEditor *editor,
    const uint8_t *blob_ptr,
    size_t blob_len
);

// Read back the opaque caret blob for the editor's CURRENT document state (see
// twig_editor_set_caret_blob). After twig_editor_undo / _redo this is the
// restored state's caret; after an edit it is empty until the caller sets one.
// The bytes are borrowed from `editor` and stay valid until the next
// twig_editor_set_caret_blob, successful edit, or undo/redo on this handle, or
// until it is destroyed. *out_ptr is NULL when the blob is empty.
TwigStatus twig_editor_caret_blob(
    TwigEditor *editor,
    const uint8_t **out_ptr,
    size_t *out_len
);

// A read-only TwigDocument view of the editor's CURRENT tree, so an editor can
// use the twig_document_* read surface (_nodes, _children, _subtree, _node_at,
// _nodes_at, _query, _ast_json, _node_span, _node_content_span) directly.
//
// The handle is BORROWED from `editor`: do NOT pass it to
// twig_document_destroy (which ignores it), it stays valid until
// twig_editor_destroy, and it always reflects the tree as of the last
// successful edit. The same pointer keeps working across edits — but anything
// already read out of it goes stale exactly as the editor's own reads do, since
// node ids and spans are only valid against the tree they came from.
//
// The view shares its buffers with the editor's read functions, so
// twig_editor_nodes and twig_document_nodes on this view invalidate each other.
// twig_document_render_html and twig_document_serialize are the two functions it
// cannot serve (TWIG_STATUS_UNSUPPORTED_FORMAT — they need a real parse's
// language tag and side tables); pass twig_editor_source to twig_parse instead.
TwigStatus twig_editor_document(
    TwigEditor *editor,
    TwigDocument **out_doc
);

// The five reads below are twig_document_* over twig_editor_document(editor),
// kept as the editor-side spelling; see the document-side functions for the
// full contract. New code may use either.

// Snapshot the editor's current tree as a flat array of TwigFlatNode, one per
// arena node, indexed so array[i].id == i. The JSON-free read path for a
// renderer: walk it via the parent / first_child / next_sibling id links
// (TWIG_NO_NODE where absent). As with twig_document_nodes, MORE THAN ONE node
// can have parent == TWIG_NO_NODE: the document root plus any detached
// definition (see twig_document_definitions).
// Borrowed from `editor`, valid until the next twig_editor_nodes /
// twig_document_nodes call or destroy; the text/destination pointers within
// additionally require no successful edit since (a reparse frees the payloads
// they borrow).
TwigStatus twig_editor_nodes(
    TwigEditor *editor,
    const TwigFlatNode **out_ptr,
    size_t *out_len
);

// The direct children of `node_id` as TwigQueryMatch (id, span, kind) — the
// cheap top-level enumeration an incremental renderer uses to find the blocks it
// must consider without marshalling the whole arena; pair with
// twig_editor_subtree to re-marshal only the block(s) that changed. Pass
// TWIG_NO_NODE for node_id to enumerate the DOCUMENT ROOT's children (the
// top-level blocks). Same borrow contract as twig_editor_query, on its own
// buffer. A childless node yields a zero-length result and TWIG_STATUS_OK; a
// node_id neither in range nor the sentinel is TWIG_STATUS_INVALID_ARGUMENT.
// (twig_document_children is the same call under the document-side name.)
TwigStatus twig_editor_child_spans(
    TwigEditor *editor,
    uint32_t node_id,
    const TwigQueryMatch **out_ptr,
    size_t *out_len
);

// Snapshot the subtree rooted at `node_id` as a self-contained TwigFlatNode
// array with LOCAL ids: array[0] is the root, every id / parent / first_child /
// next_sibling indexes into THIS array (or TWIG_NO_NODE), and spans stay
// ABSOLUTE. The incremental-render companion to twig_editor_nodes: re-marshal
// one edited block's subtree instead of the whole arena. The root's parent and
// next_sibling are TWIG_NO_NODE, so a walk from index 0 never leaves the
// subtree. Same borrow contract as twig_editor_nodes, on its own buffer; node_id
// out of range is TWIG_STATUS_INVALID_ARGUMENT.
TwigStatus twig_editor_subtree(
    TwigEditor *editor,
    uint32_t node_id,
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
// else TWIG_STATUS_UNSUPPORTED_FORMAT. TWIG_STATUS_INVALID_ARGUMENT for a
// heading `level` outside 1–6 or an `offset` past the source. Fills out_change
// on success if non-NULL.
//
// On a BLANK LINE it OPENS the block instead of converting one, so "H2, then
// type" works from an empty line the way it works from a full one — there is no
// node there to rewrite, since no format spells an empty paragraph. The marker
// is blank-separated from whatever precedes it (djot does not let a heading
// interrupt a paragraph, so a marker flush under one is read as that
// paragraph's text) and carries the line's quote markers, so a heading opened on
// a quote's blank line stays inside the quote. TWIG_BLOCK_PARAGRAPH there is a
// no-op: a blank line already holds no marker.
//
// TWIG_STATUS_NOT_EDITABLE when the blank line is INTERIOR to a block rather
// than between blocks — inside a fenced code block, or a table — where writing a
// marker would add no heading and corrupt what is there.
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

// Renumber the ordered list at `offset` so its markers run 1, 2, 3, …, each
// nesting level restarting at 1 — the numbering a caret editor keeps as items
// are inserted, deleted, and nested (a plain splice leaves `1. 2. 2. 3.`).
// TWIG_STATUS_NOT_FOUND when `offset` is not inside an ordered list. When the
// numbering is already sequential this is a no-op that still returns
// TWIG_STATUS_OK; out_change then reports the most recent prior edit (or is left
// untouched when there is none), so OK is not proof the source moved. Fills
// out_change on success if non-NULL.
//
// Only lines the PARSER reads as items are touched, so this never rewrites a
// digit the author wrote as prose. That is not a corner case across formats:
// Djot doesn't let a list marker interrupt a paragraph, so in "1. a\n   2. b"
// the second line is text inside item `a`, while Markdown reads it as a nested
// item — the same bytes, renumbered in one format and left alone in the other.
//
// TWIG_STATUS_UNSUPPORTED_FORMAT where the format doesn't spell an ordered item
// as a numbered line marker: an <ol> keeps its numbering in the tag, so there is
// no digit to rewrite and this used to return OK having done nothing at all. Ask
// twig_format_supports with TWIG_GESTURE_RENUMBER_ORDERED_LISTS.
TwigStatus twig_editor_renumber_ordered_lists(
    TwigEditor *editor,
    size_t offset,
    TwigChange *out_change
);

// Table ops for twig_editor_table_edit's `op` argument. `arg` is the gesture's
// parameter: for insert/move a side (0 = before/up/left, 1 = after/down/right),
// for TWIG_TABLE_SET_ALIGNMENT a TwigAlignment, ignored for the deletes.
typedef enum {
    TWIG_TABLE_INSERT_ROW = 0,
    TWIG_TABLE_DELETE_ROW = 1,
    TWIG_TABLE_INSERT_COLUMN = 2,
    TWIG_TABLE_DELETE_COLUMN = 3,
    TWIG_TABLE_SET_ALIGNMENT = 4,
    TWIG_TABLE_MOVE_ROW = 5,
    TWIG_TABLE_MOVE_COLUMN = 6
} TwigTableOp;

// Edit the table at `offset` — add/remove/move a row or column, or set a
// column's alignment. `op` is a TwigTableOp; `arg` is its parameter (see the
// enum). The whole table is re-spelled and spliced in one edit.
// TWIG_STATUS_NOT_FOUND when `offset` is not inside a table;
// TWIG_STATUS_NOT_EDITABLE for a refused edit (deleting the header row, the last
// body row, or the last column). Fills out_change on success if non-NULL.
//
// TWIG_STATUS_UNSUPPORTED_FORMAT when the format has no table spelling to write
// the rebuilt table back with — checked before the grid is read, so the source
// is untouched rather than restored. A format can have a table twig can READ and
// none it can WRITE: HTML's <table> parses into the same nodes a pipe table
// does, so this used to return OK having replaced the table with pipe text that
// reparsed as a paragraph. Ask twig_format_supports with the matching
// TWIG_GESTURE_TABLE_* code.
TwigStatus twig_editor_table_edit(
    TwigEditor *editor,
    size_t offset,
    int op,
    int arg,
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
//   * A RANGE INSIDE an existing autolink (`<https://x.dev>`, `<a@b.dev>`)
//     re-points it the same way, but there is no text to keep: an autolink's
//     text IS its destination, so the node is replaced WHOLE, spelled
//     canonically for the new destination (below) — a `<url>` re-pointed at a
//     relative path becomes `[dest](dest)`. This covers a caret and any
//     selection the autolink contains, including one covering it exactly: an
//     autolink's URL is not editable text, so no part of it can host a `[`, and
//     "link half this URL" has no spelling. A caret inside BOTH an autolink and
//     a link (`[<https://x.dev>](d)`) re-points the LINK, whose text is
//     separable from its destination and so survives.
//   * A selection starting or ending strictly INSIDE an autolink without being
//     contained by it — running from ordinary text into the middle of a URL —
//     is refused with TWIG_STATUS_NOT_EDITABLE. Half of it is real text, so
//     there is nothing to re-point, and any splice would rewrite the URL into
//     something the caller never asked for. A selection that CONTAINS an
//     autolink whole is unaffected: it splices at the edges and wraps as usual.
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

// Spell `[start, end)` as an IMAGE pointing at `destination` — `![alt](dest)`,
// the selected source becoming the alt text.
//
// The destination is escaped exactly as twig_editor_insert_link escapes one (see
// the paragraph above it), because it is the same grammar production: Markdown
// moves a destination holding whitespace into the `<…>` form, Djot leaves it bare
// because `<…>` means nothing there. That is why this op exists rather than being
// a caller's sprintf — `![](my file.png)` is not an image in Markdown at all, and
// a caller cannot fix it without reproducing twig's per-format escape table.
//
// Two ways it is simpler than a link. An empty range stays empty: `![](dest)` is
// a perfectly good image, where the childless `[](dest)` that insert_link works to
// avoid has nothing to render or put a caret in. And there is no autolink or
// re-point reasoning — an image has no bare-URL spelling, and re-pointing an
// existing one is a read of its destination plus an insert, above this op.
//
// TWIG_STATUS_INVALID_ARGUMENT when `destination` holds a newline;
// TWIG_STATUS_UNSUPPORTED_FORMAT for a parse-only format (XML, HTML).
TwigStatus twig_editor_insert_image(
    TwigEditor *editor,
    size_t start,
    size_t end,
    const uint8_t *destination,
    size_t destination_len,
    TwigChange *out_change
);

// Insert `text` at `offset` as a LITERAL run: every byte the format would read as
// markup is backslash-escaped so the run reparses as exactly `text` — a typed
// `*`, `#` or backtick stays that character instead of opening emphasis, a
// heading or a code span. This is the inverse of serialization (which writes an
// already-parsed run verbatim); it is what an editor calls to enter text that
// must not become markup by keystroke — a WYSIWYG surface where formatting comes
// only from commands.
//
// The escaping is positional and per-format, and neither is the caller's to
// reproduce. `text_escapes` bytes (`*`, backtick, `[`, `<`…) are escaped anywhere
// on the line; `block_start_escapes` bytes (`#`, `>`, `-`…) only where `offset`
// sits in its line's leading whitespace, since they open a block only there — so
// an inserted "5 - 3" keeps its `-` while "- item" at column zero does not become
// a bullet. An embedded newline in `text` re-enters that line-start zone.
//
// Like twig_editor_insert_link, this guards the run's own bytes and leans on the
// splice+reparse+rollback backstop for anything else: an insertion that would
// still corrupt the document is rolled back with TWIG_STATUS_EDIT_CONFLICT and
// changes nothing. Two constructs a byte-alphabet cannot reach are left as-is: a
// GFM bare-URL autolink (`https://x.com`, no delimiter to escape) and an
// ordered-list marker (`1.`, special only after digits). Returns
// TWIG_STATUS_UNSUPPORTED_FORMAT for a parse-only format (XML, HTML), and
// TWIG_STATUS_INVALID_ARGUMENT when `offset` is past the source.
TwigStatus twig_editor_insert_literal(
    TwigEditor *editor,
    size_t offset,
    const uint8_t *text,
    size_t text_len,
    TwigChange *out_change
);

// Insert a hard line break INSIDE a table cell at `offset`, spelled the format's
// way. A table row is a single source line, so the ordinary newline-based hard
// break cannot appear there; GFM's only in-cell break is a `<br>`, which this
// splices and which reparses as a semantic hard_break node (not opaque raw HTML),
// so a caller reads the break back as structure. Leans on the same
// splice+reparse+rollback backstop as the other gestures: a break that would no
// longer parse as the same table is rolled back with TWIG_STATUS_EDIT_CONFLICT
// and changes nothing.
//
// Returns TWIG_STATUS_UNSUPPORTED_FORMAT for a format with no in-cell break
// spelling — djot (which has no idiomatic in-cell break), HTML and XML (parse
// only); TWIG_STATUS_NOT_FOUND when `offset` is not inside a table cell (only the
// in-cell gesture is spelled today); and TWIG_STATUS_INVALID_ARGUMENT when
// `offset` is past the source.
TwigStatus twig_editor_insert_line_break(
    TwigEditor *editor,
    size_t offset,
    TwigChange *out_change
);

// Insert a THEMATIC BREAK (a horizontal rule) as its own block, on the line after
// the block `offset` sits in. A rule is a block, so there is no spelling for one
// mid-paragraph; splitting the paragraph would be a different gesture.
//
// The rule is blank-line separated from its neighbours, and that is load-bearing
// rather than cosmetic: Markdown reads `---` on the line directly under a
// paragraph as a setext `<h2>` underline, so a rule written flush against its
// predecessor silently becomes a heading and swallows it. The blank below is
// added only when the next line isn't already blank, so repeating the gesture
// doesn't accumulate them. The spelling itself is the format's (`---` for
// Markdown, `* * *` for djot) and not the caller's to reproduce.
//
// Inside a block quote the rule inherits the quote's prefix and stays in the
// quote. Inside a LIST it lands at column zero after the caret's item, which
// splits the list in two with the rule between — a real document, nothing
// swallowed. There is no TWIG_STATUS_NOT_FOUND: an empty document is a fine place
// for a rule, and with no block to sit after it goes at the caret's line end.
// TWIG_STATUS_UNSUPPORTED_FORMAT for a format with no thematic break (XML, HTML);
// TWIG_STATUS_INVALID_ARGUMENT when `offset` is past the source.
TwigStatus twig_editor_insert_thematic_break(
    TwigEditor *editor,
    size_t offset,
    TwigChange *out_change
);

// Split the block at `offset` in two AT THE CARET, both halves the SAME KIND —
// Enter in the middle of a paragraph, and the gesture
// twig_editor_insert_thematic_break deliberately is not. A host wanting "rule at
// the caret" calls this and then that.
//
// Nearly a pure INSERTION at `offset`: what is minted is the separator between
// the halves, and the only bytes REMOVED are the second half's leading spaces and
// tabs, which are structure rather than content at the start of a block (a split
// at `- b| c` that kept its space would write `-  c`, setting that item's content
// indent to three). A code block sheds nothing — there leading whitespace IS the
// content.
//
//   * A PARAGRAPH gets a blank line. Inside a quote the blank carries the quote's
//     marker and the second half its full prefix, so the split happens inside the
//     quote rather than ending it.
//   * A paragraph in a LIST ITEM gets the item's MARKER instead of a blank, so
//     the second half is a sibling item: `- this is |a list item` becomes
//     `- this is ` and `- a list item`. The marker is repeated VERBATIM, ordered
//     numbers included, so a split `1.` item yields two `1.` items — both formats
//     renumber on render, and twig_editor_renumber_ordered_lists is the gesture
//     for fixing the source. A TASK item's new half is an UNCHECKED box whatever
//     the original's state. A NESTED item's leading indent rides along with its
//     marker, so the new sibling stays in its own list rather than dropping to
//     column zero and joining the enclosing one.
//   * A HEADING repeats its own marker at its own level. twig_editor_set_block is
//     how a caller demotes the second half instead.
//   * A CODE BLOCK becomes two code blocks, the opening fence line reproduced
//     verbatim so its width and info string both survive. A consumer that doesn't
//     want the gesture offered there can ask the tree what block the caret is in
//     before calling.
//
// AT A BLOCK BOUNDARY this still splits, which is what makes it Enter: at the end
// of a list item it opens an EMPTY sibling item, which is the block the caller
// wants to type into. A paragraph is the one place that empty block cannot be
// spelled — no format has an empty paragraph — so the source gains a blank line
// and reparses as one paragraph; the node appears when there is text to hold.
//
// TWIG_STATUS_NOT_EDITABLE where a caret-split has no honest meaning: a TABLE
// (whose structure is rows and cells, so a newline mid-cell destroys rather than
// divides — splitting a table into two tables is a table gesture, not this one),
// a SETEXT heading (whose `---` underline would end up under the second half
// alone; twig_editor_set_block normalises one to ATX, which makes this work), and
// an INDENTED code block (where a blank line is interior, so the split would
// parse back as one block). TWIG_STATUS_NOT_FOUND when nothing covers `offset` —
// an empty document has no block to divide. TWIG_STATUS_INVALID_ARGUMENT when
// `offset` is past the source.
//
// TWIG_STATUS_UNSUPPORTED_FORMAT where a blank line does not separate blocks,
// checked before the source is read. In HTML a blank line is whitespace inside
// the <p>, so this used to return OK for an edit that left one paragraph as one
// paragraph. Ask twig_format_supports with TWIG_GESTURE_SPLIT_BLOCK.
TwigStatus twig_editor_split_block(
    TwigEditor *editor,
    size_t offset,
    TwigChange *out_change
);

// Toggle a FENCED CODE BLOCK over the blocks `[start, end)` covers: fence them if
// the caret is not in a code block, unfence the one it is in if it is.
//
// `language` tags the opening fence and is ignored when unfencing. It is
// OPTIONAL, spelled as this ABI's (ptr, len, has_*) triple — the same spelling
// twig_builder_add_code_block uses for the same value. has_language == 0 leaves
// the fence bare; otherwise language[0..language_len] is the info string, and an
// empty one is a distinct request from an absent one even though both write a
// bare fence. A NULL pointer with has_language != 0 and a non-zero length is
// TWIG_STATUS_INVALID_ARGUMENT.
//
// Fencing INSERTS at the covered region's edges rather than rewriting its lines:
// the body already parsed where it sits and already carries its container's
// prefix, so only the two fence lines are minted (and they carry the quote prefix
// too, which is what makes fencing inside a quote work). The fence is MEASURED,
// not fixed — one character longer than the longest run of the fence character in
// the body — so fencing text that itself contains a fence nests instead of
// closing early.
//
// Unfencing peels the opening line and, when there is one, the closing fence
// line. A Markdown INDENTED code block has no fence to peel and is dedented by up
// to four spaces a line instead, so the toggle stays reversible on documents
// using the older spelling. Note that unfencing can produce a different tree than
// the one that was fenced: a code body is by definition text the parser did not
// read as markup, so `# x` inside a fence becomes a heading once the fence is
// gone. That is what unfencing means.
//
// Returns TWIG_STATUS_NOT_EDITABLE INSIDE A LIST ITEM, in both directions. A
// quote's marker is on every line it covers; a list item's is on its first line
// only, and its content is held by indentation of the marker's width — so a fence
// written at column zero there would pull the `- ` into the code body and the
// item would stop being an item. Refusing beats losing a node.
// TWIG_STATUS_INVALID_ARGUMENT for an info string the fence cannot carry (one
// holding a line end, the fence character itself, or — in Markdown, whose info
// string ends at whitespace — a space); TWIG_STATUS_UNSUPPORTED_FORMAT for a
// format with no code fence (XML, HTML); TWIG_STATUS_NOT_FOUND when no block
// covers the range.
TwigStatus twig_editor_toggle_code_block(
    TwigEditor *editor,
    size_t start,
    size_t end,
    const uint8_t *language,
    size_t language_len,
    int has_language,
    TwigChange *out_change
);

// Retag the code block at `offset` with `language`, or CLEAR its info string when
// has_language == 0 — the language dropdown beside a code block. Same optional-
// string convention as twig_editor_toggle_code_block.
//
// Only the info string is rewritten; the fence's own width is kept, because it
// was measured against a body this gesture does not touch.
// TWIG_STATUS_NOT_EDITABLE for an INDENTED Markdown code block, which has no
// fence and so nowhere to carry a language; TWIG_STATUS_NOT_FOUND when `offset`
// is not in a code block; TWIG_STATUS_INVALID_ARGUMENT and
// TWIG_STATUS_UNSUPPORTED_FORMAT as above.
TwigStatus twig_editor_set_code_language(
    TwigEditor *editor,
    size_t offset,
    const uint8_t *language,
    size_t language_len,
    int has_language,
    TwigChange *out_change
);

// Add a CHECKBOX to the list item at `offset`, or take one away — the gesture
// that converts between a plain list item and a task list item. A box is added
// unchecked; twig_editor_set_task_checked ticks it.
//
// The box is inline content of the item's first paragraph, not part of its
// marker, so adding or removing one leaves the item's continuation-line
// indentation alone — unlike twig_editor_toggle_block_container, which has to
// re-indent. An item inside a quote is found past the quote markers.
// TWIG_STATUS_NOT_FOUND when `offset` is in no list item;
// TWIG_STATUS_NOT_EDITABLE when the item's line carries no recognizable list
// marker to hang a box off; TWIG_STATUS_UNSUPPORTED_FORMAT for a format with no
// checkbox (XML, HTML).
TwigStatus twig_editor_toggle_task_item(
    TwigEditor *editor,
    size_t offset,
    TwigChange *out_change
);

// Tick (`checked` non-zero) or untick the task item at `offset` — a click on the
// checkbox when the caller knows which way it should end up.
//
// Rewrites the BOX ALONE, never the space after it, so an item spelled with
// unusual spacing keeps it. A capital `[X]` is read as checked, so this does not
// mistake one for an unchecked box.
//
// When the box is ALREADY in the requested state this is a no-op that still
// returns TWIG_STATUS_OK — the source is left byte-for-byte unchanged. As for
// twig_editor_renumber_ordered_lists, `out_change` then reports the most recent
// PRIOR edit (or is left untouched when there is none), so a TWIG_STATUS_OK
// return is not proof the source moved; re-read twig_editor_source.
//
// TWIG_STATUS_NOT_EDITABLE when the item has no box: minting one here would make
// "set checked" silently convert a bullet into a task, which is
// twig_editor_toggle_task_item's job to do explicitly. TWIG_STATUS_NOT_FOUND when
// `offset` is in no list item.
TwigStatus twig_editor_set_task_checked(
    TwigEditor *editor,
    size_t offset,
    int checked,
    TwigChange *out_change
);

// Flip the task item at `offset` — what a checkbox click actually is when the
// caller does not already know the state. Always edits or fails, so unlike
// twig_editor_set_task_checked there is no silent no-op to guard against. Same
// errors as that function.
TwigStatus twig_editor_toggle_task_checked(
    TwigEditor *editor,
    size_t offset,
    TwigChange *out_change
);

// Insert a FOOTNOTE reference at `offset` and, unless the label is already
// defined, the matching definition at the end of the document.
//
// It writes BOTH HALVES because in neither format is half a footnote a footnote:
// a bare `[^a]` with nothing defining it renders as four literal characters. The
// definition body is left EMPTY — that parses, and the caller then types into it
// like any other block, where a minted placeholder would be text to delete. A
// label that is ALREADY DEFINED gets only the reference, so referring to one
// footnote twice does not append a second, dead definition.
//
// It is ONE edit, spanning the caret to the end of the document even though the
// two halves are far apart. Two edits would take two undos to reverse, and
// twig_editor_last_change would describe only the second — silently omitting the
// reference the caret is sitting in. So one twig_editor_undo takes both halves
// back, and the reported change covers both.
//
// TWIG_STATUS_INVALID_ARGUMENT for a label that is empty or holds a line end or a
// reference bracket; TWIG_STATUS_UNSUPPORTED_FORMAT for a format with no
// footnotes (XML, HTML); TWIG_STATUS_INVALID_ARGUMENT when `offset` is past the
// source.
TwigStatus twig_editor_insert_footnote(
    TwigEditor *editor,
    size_t offset,
    const uint8_t *label,
    size_t label_len,
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
    // Appended rather than slotted in beside FOOTNOTE/FOOTNOTE_REFERENCE, where
    // they belong by meaning: renumbering an existing code is an ABI break (see
    // "ABI stability" above), so declaration order and numeric order diverge
    // from here on. CITATION is a footnote in reStructuredText's second name
    // registry; SUBSTITUTION is a named definition whose body is INLINE.
    TWIG_KIND_CITATION = 56,
    TWIG_KIND_SUBSTITUTION = 57,
    TWIG_KIND_CITATION_REFERENCE = 58,
    TWIG_KIND_SUBSTITUTION_REFERENCE = 59,
    // A table's COLUMN AXIS: one node per column, sitting among the table's
    // children before its rows. Payload-free, so it is built with
    // twig_builder_add like any other void-payload kind; per-column data (a
    // width, reStructuredText's stub flag) is ordinary node attributes.
    TWIG_KIND_COLUMN = 60,
    // A LINE BLOCK and one of its LINES: verse, an address, anything whose line
    // breaks are the content rather than reflowable whitespace. The block is
    // payload-free and built with twig_builder_add; a line carries an indent
    // depth, so it has twig_builder_add_line just as a row has
    // twig_builder_add_row.
    TWIG_KIND_LINE_BLOCK = 61,
    TWIG_KIND_LINE = 62,
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

// Add a smart_punctuation node; `punct_kind` is a TwigSmartPunctuation code.
// `text`/`text_len` are accepted for ABI compatibility but ignored: the
// spelling is always derived from `punct_kind` (e.g. "---" for an em dash).
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

// Add a citation definition (reStructuredText's `.. [CIT2002] ...`). Same
// payload as a footnote, and a separate call rather than a namespace argument
// because the two registries are two kinds all the way out to this surface.
TwigStatus twig_builder_add_citation(
    TwigBuilder *builder,
    const uint8_t *label,
    size_t label_len,
    uint32_t *out_id
);

// Add a substitution definition (reStructuredText's `.. |name| image:: p.png`).
// Its children are INLINE nodes, unlike a footnote's or citation's.
TwigStatus twig_builder_add_substitution(
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

// Add one line of a line block. `indent` is the line's leading-whitespace DEPTH
// within the block (0 for flush-left), not a column count. The block itself is
// twig_builder_add(builder, TWIG_KIND_LINE_BLOCK, &id).
TwigStatus twig_builder_add_line(TwigBuilder *builder, uint32_t indent, uint32_t *out_id);

// Add a one-square table cell; `alignment` is a TwigAlignment code.
TwigStatus twig_builder_add_cell(TwigBuilder *builder, int head, int alignment, uint32_t *out_id);

// Add a table cell occupying `colspan` columns and `rowspan` rows — a grid
// table's merged cell. Both must be at least 1 (TWIG_STATUS_INVALID_ARGUMENT
// otherwise); 1 and 1 is exactly twig_builder_add_cell. Read back with
// twig_document_cell_colspan / twig_document_cell_rowspan.
//
// A second entry point rather than two more parameters on
// twig_builder_add_cell: an existing signature never changes in place.
TwigStatus twig_builder_add_cell_spanning(
    TwigBuilder *builder,
    int head,
    int alignment,
    uint32_t colspan,
    uint32_t rowspan,
    uint32_t *out_id
);

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
