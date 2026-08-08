const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const twig = @import("root.zig");

const Allocator = std.mem.Allocator;
pub const TwigStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    parse_error = 2,
    out_of_memory = 3,
    unsupported_format = 4,
    /// A locator resolved to no node (an out-of-bounds index path, or a
    /// selector with zero matches). Editor-only.
    not_found = 5,
    /// A selector locator matched more than one node, so the intended target
    /// is ambiguous — refine it, add `:nth(k)`, or use an index path.
    /// Editor-only.
    ambiguous = 6,
    /// The target node has no editable span/interior: a leaf given to
    /// `replace_content`, or a node whose kind the parser doesn't span yet
    /// (e.g. some Markdown inline nodes). Editor-only.
    not_editable = 7,
    /// The edit produced a document that no longer parses; it was rolled back
    /// and nothing changed. Editor-only.
    edit_conflict = 8,
    /// A `metadata` node's body contains `</script`, which can't be emitted
    /// into a raw-text `<script>` HTML data island without breaking out of the
    /// element (an injection vector). The HTML printer refused. Render/
    /// serialize-to-HTML only.
    unsafe_metadata = 9,
    internal_error = 255,
};

pub const TwigFormat = enum(c_int) {
    djot = 1,
    markdown = 2,
    xml = 3,
    html = 4,
};

/// A byte range `[start, end)` into the source, C-ABI shape of `Span`. Used by
/// `twig_document_query` for each matched node's whole extent (`span`) and
/// interior (`content_span`).
pub const TwigSpan = extern struct {
    start: usize,
    end: usize,
};

/// One node matched by `twig_document_query`, the C-ABI shape of
/// `Select.Match` plus the node's kind name. `content_span` is only
/// meaningful when `has_content_span` is non-zero; a node with no interior
/// (most leaves, or a container the parser left without a known interior)
/// reports `has_content_span == 0` and a zeroed `content_span`. Note that a
/// text leaf CAN report `has_content_span == 1`: a `code_block` carries the
/// span of its body (fences excluded), so "has a content_span" does not imply
/// "is a container." `kind` is a NUL-terminated `Node.Kind` tag name
/// (e.g. `"heading"`, `"code_block"`) in static, library-owned storage — it
/// is never freed and stays valid for the process lifetime.
pub const TwigQueryMatch = extern struct {
    node_id: u32,
    span: TwigSpan,
    content_span: TwigSpan,
    has_content_span: c_int,
    kind: [*:0]const u8,
};

/// The sentinel `node_id` for "no such node" in a `TwigFlatNode` link field
/// (`parent`/`first_child`/`next_sibling`) — the root has no parent, a leaf no
/// child, a last sibling no next. A real id is a `[]Node` index, always `<`
/// this value.
pub const TWIG_NO_NODE: u32 = std.math.maxInt(u32);

/// The byte-level effect of an edit, C-ABI shape of `twig.Splicer.Change`.
/// `old` is the range of the pre-edit source that was replaced; `new` is the
/// range the replacement occupies in the post-edit source (same start). See
/// `twig_editor_edit_range` / `twig_editor_last_change`.
pub const TwigChange = extern struct {
    old: TwigSpan,
    new: TwigSpan,
};

/// One node in the editor's current tree, C-ABI shape for the flat-arena
/// snapshot `twig_editor_nodes` returns — the JSON-free read path. `id` is the
/// node's index in the arena; `parent`/`first_child`/`next_sibling` are ids or
/// `TWIG_NO_NODE`. `content_span` is meaningful only when `has_content_span`.
/// `level` is a heading's level (0 otherwise). `kind` is static, library-owned
/// storage (never freed). `text`/`destination` borrow the *node's* payload in
/// the current parse (the AST owns its own copies, not the source) and stay
/// valid until the next successful edit or `twig_editor_destroy`; each is NULL
/// when the kind carries no such payload.
///
/// `head` and `alignment` surface a `row`/`cell` payload the way `level`
/// surfaces a `heading`'s, so a consumer can render a table from the snapshot
/// alone. Both use `-1` for "this kind carries no such payload" rather than
/// `level`'s 0-means-absent trick, because a cell's `default` alignment is
/// itself a meaningful value.
///
/// New fields are *appended*: every offset above stays put across the bump, so
/// the layout change is strictly additive (only `@sizeOf` moves).
pub const TwigFlatNode = extern struct {
    id: u32,
    parent: u32,
    first_child: u32,
    next_sibling: u32,
    span: TwigSpan,
    content_span: TwigSpan,
    has_content_span: c_int,
    level: u32,
    kind: [*:0]const u8,
    text_ptr: ?[*]const u8,
    text_len: usize,
    destination_ptr: ?[*]const u8,
    destination_len: usize,
    /// A `row`/`cell`'s header flag: 1 true, 0 false, -1 for every other kind.
    head: c_int,
    /// A `cell`'s column alignment (`TwigAlignment`), -1 for every other kind.
    alignment: c_int,
    /// A generic `element`'s tag name (`"picture"`, `"source"`, …), NULL for
    /// every other kind — the one piece of an element's identity `kind`
    /// ("element") doesn't carry. Borrows the node payload, same lifetime as
    /// `text`/`destination`.
    name_ptr: ?[*]const u8,
    name_len: usize,
    /// The node's `{...}` / HTML attributes as `(key, value)` pairs in source
    /// order, or NULL/0 when it has none. A bare attribute (HTML `disabled`,
    /// or a source-picked `<source media=…>` with no value) has a NULL `value`
    /// with `value_len == 0`. Borrows: the `TwigKeyVal` records live in a buffer
    /// owned by the editor handle (replaced on the next snapshot call on the same
    /// accessor, freed on destroy), and each key/value pointer within them
    /// borrows the AST payload like `text`/`destination` — so a successful edit
    /// invalidates them too.
    attrs_ptr: ?[*]const TwigKeyVal,
    attrs_len: usize,
    /// A `directive`'s surface form (`TWIG_DIRECTIVE_*`), `TWIG_DIRECTIVE_NONE`
    /// for every other kind. All three forms report `kind == "directive"` and
    /// carry their type in `name`, so this is the only thing distinguishing an
    /// inline `:name[x]` from a block `::name{…}` or a `:::name` fence — and a
    /// consumer must render them differently.
    directive_form: c_int,
};

/// `TwigFlatNode.head` for a node that is neither a `row` nor a `cell`.
pub const TWIG_HEAD_NONE: c_int = -1;

/// A `cell`'s column alignment, as reported by `TwigFlatNode.alignment`.
/// `TWIG_ALIGN_NONE` (-1) means the node isn't a cell at all.
pub const TWIG_ALIGN_NONE: c_int = -1;
pub const TWIG_ALIGN_DEFAULT: c_int = 0;
pub const TWIG_ALIGN_LEFT: c_int = 1;
pub const TWIG_ALIGN_RIGHT: c_int = 2;
pub const TWIG_ALIGN_CENTER: c_int = 3;

/// `TwigFlatNode.directive_form` for a node that isn't a `directive`. The three
/// real forms are the `TwigDirectiveForm` enumerators below (the colon counts of
/// the generic-directives proposal: `:name[x]` text, `::name{…}` leaf,
/// `:::name{…}` … `:::` container). This one is deliberately not among them,
/// for the same reason `TWIG_ALIGN_NONE` isn't a `TwigAlignment`: that enum is
/// also `twig_builder_add_directive`'s parameter type, and "not a directive" is
/// not a form you can build with.
pub const TWIG_DIRECTIVE_NONE: c_int = -1;

pub const TwigDocument = opaque {};

/// A parsed document plus the caller-borrowed output buffers each accessor
/// caches on it. Every buffer follows the same contract: it is owned by the
/// handle, replaced on the next call to the same accessor, and freed when the
/// handle is destroyed — so a pointer handed out stays valid until the next
/// same-accessor call on this handle or `twig_document_destroy`, whichever
/// comes first. The buffers are independent: rendering HTML never invalidates
/// a serialize/ast-json/query result and vice versa.
const DocumentHandle = struct {
    parsed: twig.format.ParsedDoc,
    rendered: []u8 = &.{},
    serialized: []u8 = &.{},
    ast_json: []u8 = &.{},
    query_matches: []TwigQueryMatch = &.{},
};

fn activeAllocator() Allocator {
    return if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
}

fn asHandle(doc: *TwigDocument) *DocumentHandle {
    return @ptrCast(@alignCast(doc));
}

fn sliceOf(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| return p[0..len];
    if (len == 0) return &.{};
    return null;
}

/// Map a raw `int` format code to a `twig.Format`, or `null` if it names no
/// known format (the caller turns that into `unsupported_format`).
///
/// `TwigFormat`'s integers are the WIRE CONTRACT and so are frozen here;
/// `twig.Format` is Zig's own enum and carries no values at all. This function
/// is the only place the two meet — which is the whole shape of this file's job.
fn intToFormat(format: c_int) ?twig.Format {
    const wire: TwigFormat = switch (format) {
        @intFromEnum(TwigFormat.djot) => .djot,
        @intFromEnum(TwigFormat.markdown) => .markdown,
        @intFromEnum(TwigFormat.xml) => .xml,
        @intFromEnum(TwigFormat.html) => .html,
        else => return null,
    };
    return switch (wire) {
        inline else => |k| @field(twig.Format, @tagName(k)),
    };
}

pub export fn twig_version() u32 {
    return (@as(u32, build_options.version_major) << 16) |
        (@as(u32, build_options.version_minor) << 8) |
        @as(u32, build_options.version_patch);
}

pub export fn twig_version_string() [*:0]const u8 {
    const s = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
    });
    return s;
}

/// The C ABI contract version, independent of the semantic `twig_version`.
///
/// It is bumped ONLY on a breaking ABI change — an `extern struct`'s layout
/// changing, or an existing enum value being renumbered. Purely additive
/// changes do NOT bump it: appending a new `TwigFormat`/`TwigStatus`/
/// `TwigNodeKind` value at the end, or adding a new `twig_*` function (e.g. a
/// future `twig_editor_undo`), leaves every existing symbol binary-compatible,
/// so an older consumer keeps working. See the "ABI stability" contract in
/// `bindings/c/include/twig.h`.
///
/// A consumer records the `TWIG_ABI_VERSION` it compiled against and can call
/// `twig_abi_version` at load time to confirm the library it linked speaks the
/// same layout.
/// 2: `TwigFlatNode` grew `head`/`alignment` (96 → 104 bytes). Appended, so
/// every prior field kept its offset, but `@sizeOf` is part of the layout a
/// consumer strides an array with — that's a bump.
/// 3: `TwigFlatNode` grew `name`/`attrs` (104 → 136 bytes) — an `element`'s tag
/// name and a node's `(key, value)` attributes on the read path. Same
/// append-only shape, same reason it's still a bump.
/// 4: `TwigFlatNode` grew `directive_form` (136 → 144 bytes), and `name` now
/// also reports a `directive`'s type — the two halves of a directive's
/// identity, which `kind` ("directive") carries neither of. Filling an
/// existing field for a kind that used to report NULL is source-compatible;
/// the appended field is what makes it a bump.
pub const TWIG_ABI_VERSION: u32 = 4;

pub export fn twig_abi_version() u32 {
    return TWIG_ABI_VERSION;
}

// Freeze the canonical 64-bit C-ABI layout of every `extern struct` the
// bindings mirror. A field reordered, retyped, inserted, or removed shifts an
// offset or the size and fails the build here — turning a silent, memory-
// corrupting drift between this file and `twig.h`/`ffi.rs` into a compile
// error. Any *intentional* change to these numbers must also bump
// `TWIG_ABI_VERSION` and the mirrored `assert!`s in `ffi.rs`.
//
// Gated on 64-bit because the offsets below are the LP64/LLP64 layout (the
// shipped desktop/mobile targets); on a 32-bit target (e.g. `wasm32`) C-ABI
// rules still make Zig and the bindings agree, they just pack tighter, so the
// absolute numbers wouldn't apply.
comptime {
    if (@sizeOf(usize) == 8) {
        const assert = std.debug.assert;

        assert(@sizeOf(TwigSpan) == 16);
        assert(@offsetOf(TwigSpan, "start") == 0);
        assert(@offsetOf(TwigSpan, "end") == 8);

        assert(@sizeOf(TwigQueryMatch) == 56);
        assert(@offsetOf(TwigQueryMatch, "node_id") == 0);
        assert(@offsetOf(TwigQueryMatch, "span") == 8);
        assert(@offsetOf(TwigQueryMatch, "content_span") == 24);
        assert(@offsetOf(TwigQueryMatch, "has_content_span") == 40);
        assert(@offsetOf(TwigQueryMatch, "kind") == 48);

        assert(@sizeOf(TwigChange) == 32);
        assert(@offsetOf(TwigChange, "old") == 0);
        assert(@offsetOf(TwigChange, "new") == 16);

        assert(@sizeOf(TwigFlatNode) == 144);
        assert(@offsetOf(TwigFlatNode, "id") == 0);
        assert(@offsetOf(TwigFlatNode, "parent") == 4);
        assert(@offsetOf(TwigFlatNode, "first_child") == 8);
        assert(@offsetOf(TwigFlatNode, "next_sibling") == 12);
        assert(@offsetOf(TwigFlatNode, "span") == 16);
        assert(@offsetOf(TwigFlatNode, "content_span") == 32);
        assert(@offsetOf(TwigFlatNode, "has_content_span") == 48);
        assert(@offsetOf(TwigFlatNode, "level") == 52);
        assert(@offsetOf(TwigFlatNode, "kind") == 56);
        assert(@offsetOf(TwigFlatNode, "text_ptr") == 64);
        assert(@offsetOf(TwigFlatNode, "text_len") == 72);
        assert(@offsetOf(TwigFlatNode, "destination_ptr") == 80);
        assert(@offsetOf(TwigFlatNode, "destination_len") == 88);
        assert(@offsetOf(TwigFlatNode, "head") == 96);
        assert(@offsetOf(TwigFlatNode, "alignment") == 100);
        assert(@offsetOf(TwigFlatNode, "name_ptr") == 104);
        assert(@offsetOf(TwigFlatNode, "name_len") == 112);
        assert(@offsetOf(TwigFlatNode, "attrs_ptr") == 120);
        assert(@offsetOf(TwigFlatNode, "attrs_len") == 128);
        assert(@offsetOf(TwigFlatNode, "directive_form") == 136);

        assert(@sizeOf(TwigKeyVal) == 32);
        assert(@offsetOf(TwigKeyVal, "key") == 0);
        assert(@offsetOf(TwigKeyVal, "key_len") == 8);
        assert(@offsetOf(TwigKeyVal, "value") == 16);
        assert(@offsetOf(TwigKeyVal, "value_len") == 24);
    }
}

pub export fn twig_parse(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_doc: ?*?*TwigDocument,
) TwigStatus {
    return twig_parse_ext(input_ptr, input_len, format, 0, out_doc);
}

/// Like `twig_parse`, plus `md_flags` — a bitmask of `TWIG_MD_*` Markdown
/// extensions (`TWIG_MD_DIRECTIVES`, `TWIG_MD_MATH`, `TWIG_MD_HTML_ELEMENTS`) to
/// enable for a Markdown parse (ignored for other formats). Opens the read/query
/// surface to the same opt-in extensions `twig_editor_create_ext` gives the edit
/// surface — needed to, e.g., `twig_document_query` for `image` nodes that only
/// exist once `TWIG_MD_HTML_ELEMENTS` promotes raw `<img>` tags. A `0` mask is
/// exactly `twig_parse`.
pub export fn twig_parse_ext(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    md_flags: u32,
    out_doc: ?*?*TwigDocument,
) TwigStatus {
    const out = out_doc orelse return .invalid_argument;
    out.* = null;
    const source = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;

    const allocator = activeAllocator();
    const cfg: twig.format.ParseConfig = .{ .markdown = markdownOptionsFromFlags(md_flags) };
    const parsed = twig.format.entryFor(target).parse(&cfg, allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        // Only XML can reject its input; the others are infallible by design
        // (any byte sequence is *some* djot/Markdown/HTML document).
        else => return .parse_error,
    };

    const handle = allocator.create(DocumentHandle) catch return .out_of_memory;
    handle.* = .{ .parsed = parsed };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn twig_document_destroy(doc: ?*TwigDocument) void {
    const raw = doc orelse return;
    const allocator = activeAllocator();
    const handle = asHandle(raw);
    if (handle.rendered.len != 0) allocator.free(handle.rendered);
    if (handle.serialized.len != 0) allocator.free(handle.serialized);
    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.parsed.deinit();
    allocator.destroy(handle);
}

pub export fn twig_document_render_html(
    doc: ?*TwigDocument,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const rendered = twig.format.renderHtmlAlloc(allocator, &handle.parsed) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.UnsafeMetadata => return .unsafe_metadata,
    };

    if (handle.rendered.len != 0) allocator.free(handle.rendered);
    handle.rendered = rendered;

    ptr_out.* = if (rendered.len == 0) null else rendered.ptr;
    len_out.* = rendered.len;
    return .ok;
}

/// Serialize `parsed` as `target`'s own source syntax, mirroring
/// `twig convert`'s two paths (see `cli/actions.zig`'s `convertSource`):
///   - `target` == the document's own format: round-trip through that
///     format's `Document`-aware canonical serializer, which resolves djot/
///     Markdown reference/footnote side tables.
///   - `target` != it: cross-format conversion through the target's bare-`AST`
///     serializer (`serializeAstAlloc`), which rebuilds any side tables it
///     needs from the tree alone.
/// Returns `null` when `target` has no serializer for the requested direction
/// (today: converting *into* XML from another format — XML's serializer only
/// understands the generic-markup kinds its own parser produces), which the
/// caller turns into `unsupported_format`.
fn serializeDocument(
    allocator: Allocator,
    parsed: *const twig.format.ParsedDoc,
    target: twig.Format,
) anyerror!?[]u8 {
    const result = if (std.meta.activeTag(parsed.*) == target)
        twig.format.serializeCanonicalAlloc(allocator, parsed)
    else
        twig.format.serializeFromAstAlloc(allocator, parsed.ast(), target);
    // `null` is this function's "the registry has no serializer for that",
    // which the caller reports as `unsupported_format`.
    return result catch |err| switch (err) {
        error.UnsupportedFormat => null,
        else => err,
    };
}

/// Serialize a parsed document to `format`'s own source syntax (round-trip
/// when `format` matches the document's own format, cross-format conversion
/// otherwise).
///
/// The returned bytes are borrowed from `doc` and remain valid until the next
/// `twig_document_serialize` call on that same handle, or until the handle is
/// destroyed.
pub export fn twig_document_serialize(
    doc: ?*TwigDocument,
    format: c_int,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const serialized = (serializeDocument(allocator, &handle.parsed, target) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.UnsafeMetadata => return .unsafe_metadata,
        else => return .internal_error,
    }) orelse return .unsupported_format;

    if (handle.serialized.len != 0) allocator.free(handle.serialized);
    handle.serialized = serialized;

    ptr_out.* = if (serialized.len == 0) null else serialized.ptr;
    len_out.* = serialized.len;
    return .ok;
}

/// Encode a parsed document's shared `AST` as pretty-printed JSON — the same
/// stable encoding `twig convert -o ast` produces (see `ast/json.zig`).
///
/// The returned bytes are borrowed from `doc` and remain valid until the next
/// `twig_document_ast_json` call on that same handle, or until the handle is
/// destroyed.
pub export fn twig_document_ast_json(
    doc: ?*TwigDocument,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const json = twig.ast_json.encodeAlloc(allocator, handle.parsed.ast()) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    handle.ast_json = json;

    ptr_out.* = if (json.len == 0) null else json.ptr;
    len_out.* = json.len;
    return .ok;
}

/// Resolve a CSS-lite selector (see `ast/select.zig` for the grammar — e.g.
/// `heading[level=2]`, `link[dest^="http"]`, `code`, `list > item`) against a
/// parsed document and return one `TwigQueryMatch` per matching node, in
/// document order. This is the general replacement for the old bespoke
/// code-span scan: a `code` / `verbatim` / `raw_block` / `raw_inline` selector
/// recovers those spans, and every other node kind is reachable too.
///
/// A malformed selector returns `invalid_argument`. The returned matches are
/// borrowed from `doc` and remain valid until the next `twig_document_query`
/// call on that same handle, or until the handle is destroyed.
pub export fn twig_document_query(
    doc: ?*TwigDocument,
    selector_ptr: ?[*]const u8,
    selector_len: usize,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const raw = doc orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const selector_src = sliceOf(selector_ptr, selector_len) orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asHandle(raw);

    const out = buildQueryMatches(allocator, handle.parsed.ast(), selector_src) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
    };

    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.query_matches = out;

    ptr_out.* = if (out.len == 0) null else out.ptr;
    len_out.* = out.len;
    return .ok;
}

/// Parse `selector_src`, resolve it against `ast`, and return a freshly
/// allocated `[]TwigQueryMatch` in document order (caller owns it). Shared by
/// `twig_document_query` and `twig_editor_query`.
fn buildQueryMatches(
    allocator: Allocator,
    ast: *const twig.AST,
    selector_src: []const u8,
) error{ OutOfMemory, InvalidSelector }![]TwigQueryMatch {
    var selector = try twig.Select.parse(allocator, selector_src);
    defer selector.deinit();

    const matches = try twig.Select.resolveAll(allocator, ast, &selector);
    defer allocator.free(matches);

    if (matches.len == 0) return &.{};
    const buf = try allocator.alloc(TwigQueryMatch, matches.len);
    for (matches, buf) |m, *slot| {
        slot.* = .{
            .node_id = m.id,
            .span = .{ .start = m.span.start, .end = m.span.end },
            .content_span = if (m.content_span) |cs|
                .{ .start = cs.start, .end = cs.end }
            else
                .{ .start = 0, .end = 0 },
            .has_content_span = if (m.content_span != null) 1 else 0,
            .kind = @tagName(std.meta.activeTag(ast.nodes[m.id].kind)).ptr,
        };
    }
    return buf;
}

// ── Editor ─────────────────────────────────────────────────────────────────
// A separate handle from `TwigDocument`: the authoring editor (`twig.Editor` —
// a span-splice engine plus its format's `Syntax`) owns evolving source bytes
// plus a bare-AST reparse of them, where `TwigDocument` holds a one-shot parse
// with its language's side tables.
// Editing reparses after every successful edit, so node ids/paths are only
// valid against the tree *as of the last edit* — which is why every op here is
// addressed by a fresh locator string (an index path or a unique selector),
// resolved against the current tree, exactly like `twig edit`.

pub const TwigEditor = opaque {};

/// A parsed, editable document plus the caller-borrowed output buffers each
/// accessor caches on it.
///
/// `editor` is `twig.Editor` — the format-aware authoring layer, which is what
/// `TwigEditor` has always MEANT. The handle used to carry a `format` tag beside
/// a language-agnostic engine and re-derive the spelling of every gesture from
/// it at this boundary; `twig.Editor` is that pairing, done once, in Zig. What
/// is left here is the buffers, which are genuinely an ABI concern: a C caller
/// needs somewhere to borrow from.
const EditorHandle = struct {
    editor: twig.Editor,
    /// The parse configuration the editor's reparse callback borrows (via
    /// `Splicer.ParseFn`'s `ctx`). Stored ON the handle so its address is stable
    /// for the handle's whole lifetime — the editor holds `&this`.
    parse_config: twig.format.ParseConfig = .{},
    /// Caller-borrowed output buffers, same contract as `DocumentHandle`'s.
    ast_json: []u8 = &.{},
    query_matches: []TwigQueryMatch = &.{},
    /// The last `twig_editor_nodes` snapshot (editor tree read-back; see
    /// DESIGN.md's "Editor surface" tiers).
    flat_nodes: []TwigFlatNode = &.{},
    /// The `TwigKeyVal` records the last `twig_editor_nodes` snapshot's
    /// `attrs_ptr`s point into (see `fillAttrs`). Paired with `flat_nodes`:
    /// replaced together, freed together.
    flat_attrs: []TwigKeyVal = &.{},
    /// The last `twig_editor_nodes_at` ancestor chain. Independent of
    /// `query_matches` so a hit-test doesn't invalidate a prior query.
    ancestor_matches: []TwigQueryMatch = &.{},
    /// The last `twig_editor_subtree` snapshot. Independent of `flat_nodes` so a
    /// per-block re-marshal doesn't invalidate a prior whole-tree read.
    subtree_nodes: []TwigFlatNode = &.{},
    /// The `TwigKeyVal` records the last `twig_editor_subtree` snapshot's
    /// `attrs_ptr`s point into. Paired with `subtree_nodes`.
    subtree_attrs: []TwigKeyVal = &.{},
    /// The last `twig_editor_child_spans` result (direct-children enumeration).
    child_spans: []TwigQueryMatch = &.{},
};

fn asEditor(ed: *TwigEditor) *EditorHandle {
    return @ptrCast(@alignCast(ed));
}

/// The one edit each locator-addressed `twig_editor_*` op performs, dispatched
/// by `applyEdit` onto the matching `twig.Splicer` method.
const EditOp = enum { replace, replace_content, insert_before, insert_after, insert_child, delete, delete_smart, unwrap };

/// Markdown extension bitmask accepted by `twig_parse_ext` and
/// `twig_editor_create_ext` (`TWIG_MD_*` in `twig.h`); other formats ignore it.
/// The bit values are the wire contract, so they live here. Every bit is an
/// opt-in, default-off extension — the default-on ones (tables, strikethrough,
/// …) need no flag, and a `0` mask reproduces `twig_parse`/`twig_editor_create`.
const TWIG_MD_DIRECTIVES: u32 = 1 << 0;
const TWIG_MD_MATH: u32 = 1 << 1;
const TWIG_MD_HTML_ELEMENTS: u32 = 1 << 2;

fn markdownOptionsFromFlags(flags: u32) twig.Markdown.ParseOptions {
    var opts: twig.Markdown.ParseOptions = .{};
    opts.directives = (flags & TWIG_MD_DIRECTIVES) != 0;
    opts.math = (flags & TWIG_MD_MATH) != 0;
    opts.html_elements = (flags & TWIG_MD_HTML_ELEMENTS) != 0;
    return opts;
}

// ── error -> status ────────────────────────────────────────────────────────
// The whole translation layer, in one place. Each Zig error set below is
// exhaustively switched, so a new error variant is a compile error here rather
// than a silently-wrong status code.

fn statusOfEditorError(err: twig.Editor.Error) TwigStatus {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidRange, error.InvalidLevel, error.InvalidDestination => .invalid_argument,
        error.UnsupportedFormat => .unsupported_format,
        error.NoBlock => .not_found,
        error.NotEditable => .not_editable,
        error.EditConflict => .edit_conflict,
    };
}

fn statusOfLocatorError(err: twig.locator.Error) TwigStatus {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidLocator => .invalid_argument,
        error.NotFound => .not_found,
        error.Ambiguous => .ambiguous,
    };
}

/// The splicer's errors are an OPEN set: `ParseFn` is `anyerror`, so any
/// language's parse error can surface here. Anything not named is the parser
/// rejecting the edited document, which the splicer has already rolled back.
fn statusOfSplicerError(err: anyerror) TwigStatus {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.NoNodeSpan, error.NoContentSpan, error.NotAContainer => .not_editable,
        else => .edit_conflict,
    };
}

/// Create an editor over a private copy of `input`, parsed as `format` with
/// default options. On the initial parse failing, returns `parse_error` (or
/// `out_of_memory`).
pub export fn twig_editor_create(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_editor: ?*?*TwigEditor,
) TwigStatus {
    return twig_editor_create_ext(input_ptr, input_len, format, 0, out_editor);
}

/// Like `twig_editor_create`, plus `md_flags` — a bitmask of `TWIG_MD_*`
/// Markdown extensions (`TWIG_MD_DIRECTIVES`, `TWIG_MD_MATH`,
/// `TWIG_MD_HTML_ELEMENTS`) to enable for a Markdown parse (ignored for other
/// formats). The editor reparses with the
/// same flags after every edit, so a directive-bearing document stays
/// parseable — required before `twig_editor_filter` can match `directive[…]`
/// selectors.
pub export fn twig_editor_create_ext(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    md_flags: u32,
    out_editor: ?*?*TwigEditor,
) TwigStatus {
    const out = out_editor orelse return .invalid_argument;
    out.* = null;
    const source = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;
    const entry = twig.format.entryFor(target);

    const allocator = activeAllocator();
    const handle = allocator.create(EditorHandle) catch return .out_of_memory;
    // Set the config BEFORE `Editor.init` (which reads it via the ctx pointer on
    // its initial parse); the editor stores `&handle.parse_config`, stable for
    // the handle's lifetime.
    handle.* = .{
        .editor = undefined,
        .parse_config = .{ .markdown = markdownOptionsFromFlags(md_flags) },
    };
    // `parseToAst` and `syntax` come from the same registry row, so the parser
    // and the spelling can never be crossed.
    handle.editor = twig.Editor.init(
        allocator,
        source,
        &handle.parse_config,
        entry.parseToAst,
        entry.syntax,
    ) catch |err| {
        allocator.destroy(handle);
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .parse_error,
        };
    };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn twig_editor_destroy(ed: ?*TwigEditor) void {
    const raw = ed orelse return;
    const allocator = activeAllocator();
    const handle = asEditor(raw);
    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    if (handle.flat_nodes.len != 0) allocator.free(handle.flat_nodes);
    if (handle.flat_attrs.len != 0) allocator.free(handle.flat_attrs);
    if (handle.ancestor_matches.len != 0) allocator.free(handle.ancestor_matches);
    if (handle.subtree_nodes.len != 0) allocator.free(handle.subtree_nodes);
    if (handle.subtree_attrs.len != 0) allocator.free(handle.subtree_attrs);
    if (handle.child_spans.len != 0) allocator.free(handle.child_spans);
    handle.editor.deinit();
    allocator.destroy(handle);
}

/// Resolve `locator` against the editor's current tree and apply `op`. The
/// resolution rule itself is `twig.locator`'s — shared with `twig edit`, which
/// accepts the same strings — so all that happens here is error mapping.
fn applyEdit(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    op: EditOp,
    child_index: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const locator = sliceOf(locator_ptr, locator_len) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;

    const allocator = activeAllocator();
    const splicer = &asEditor(raw).editor.splicer;

    const id = twig.locator.resolve(allocator, splicer.astView(), locator) catch |err|
        return statusOfLocatorError(err);

    (switch (op) {
        .replace => splicer.replaceNodeById(id, text),
        .replace_content => splicer.replaceContentById(id, text),
        .insert_before => splicer.insertBeforeById(id, text),
        .insert_after => splicer.insertAfterById(id, text),
        .insert_child => splicer.insertChildById(id, child_index, text),
        .delete => splicer.deleteNodeById(id),
        .delete_smart => splicer.deleteNodeSmartById(id),
        .unwrap => splicer.unwrapNodeById(id),
    }) catch |err| return statusOfSplicerError(err);
    return .ok;
}

/// Replace the whole source of the located node with `text`.
pub export fn twig_editor_replace(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .replace, 0, text_ptr, text_len);
}

/// Replace the interior (between-delimiters content) of the located container.
pub export fn twig_editor_replace_content(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .replace_content, 0, text_ptr, text_len);
}

/// Insert `text` immediately before the located node.
pub export fn twig_editor_insert_before(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .insert_before, 0, text_ptr, text_len);
}

/// Insert `text` immediately after the located node.
pub export fn twig_editor_insert_after(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .insert_after, 0, text_ptr, text_len);
}

/// Insert `text` as the `child_index`-th child of the located container (past
/// the child count appends).
pub export fn twig_editor_insert_child(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
    child_index: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .insert_child, child_index, text_ptr, text_len);
}

/// Delete the located node (removes exactly its span; no whitespace cleanup).
pub export fn twig_editor_delete(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .delete, 0, null, 0);
}

/// Delete the located node, tidying surrounding blank lines for a whole-line
/// (block) node; an inline node degrades to the exact-span delete.
pub export fn twig_editor_delete_smart(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .delete_smart, 0, null, 0);
}

/// Unwrap the located node: replace it with its interior (drop the wrapper,
/// keep the children) — e.g. peel a `:::vis{…}` container. A node with no
/// interior (a leaf, or an empty container) is removed.
pub export fn twig_editor_unwrap(
    ed: ?*TwigEditor,
    locator_ptr: ?[*]const u8,
    locator_len: usize,
) TwigStatus {
    return applyEdit(ed, locator_ptr, locator_len, .unwrap, 0, null, 0);
}

/// Prune the document in place (`twig.Filter`): remove every node matching the
/// `drop` selector except those also matching `keep` (pass `keep_ptr == NULL`
/// to spare nothing), then — if `unwrap_kept` is non-zero — unwrap the
/// survivors. The edited bytes are then available via `twig_editor_source`.
/// A malformed selector returns `invalid_argument`; a reparse-breaking edit
/// (rolled back) `edit_conflict`.
pub export fn twig_editor_filter(
    ed: ?*TwigEditor,
    drop_ptr: ?[*]const u8,
    drop_len: usize,
    keep_ptr: ?[*]const u8,
    keep_len: usize,
    unwrap_kept: c_int,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const drop = sliceOf(drop_ptr, drop_len) orelse return .invalid_argument;
    // `keep` is optional: a NULL pointer means "no keep" (a zero-length keep
    // with a non-NULL pointer is a caller error, surfacing as invalid_argument
    // when the empty selector fails to parse).
    const keep: ?[]const u8 = if (keep_ptr) |p| p[0..keep_len] else null;

    const allocator = activeAllocator();
    twig.Filter.apply(allocator, &handle.editor.splicer, .{
        .drop = drop,
        .keep = keep,
        .unwrap_kept = unwrap_kept != 0,
    }) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
        error.FilterDidNotConverge => return .internal_error,
        error.NoNodeSpan, error.NoContentSpan => return .not_editable,
        else => return .edit_conflict,
    };
    return .ok;
}

/// The editor's current (edited) source bytes.
///
/// Unlike the other accessors, these bytes are borrowed directly from the
/// editor and remain valid until the next *successful* edit on this handle (a
/// failed edit leaves them untouched), or until the handle is destroyed.
pub export fn twig_editor_source(
    ed: ?*TwigEditor,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const bytes = asEditor(raw).editor.sourceBytes();
    ptr_out.* = if (bytes.len == 0) null else bytes.ptr;
    len_out.* = bytes.len;
    return .ok;
}

/// Encode the editor's current tree as pretty-printed JSON — the live
/// counterpart of `twig_document_ast_json`, for inspecting the document
/// between edits.
///
/// The returned bytes are borrowed from `ed` and remain valid until the next
/// `twig_editor_ast_json` call on that same handle, or until it is destroyed.
pub export fn twig_editor_ast_json(
    ed: ?*TwigEditor,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asEditor(raw);

    const json = twig.ast_json.encodeAlloc(allocator, handle.editor.astView()) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    handle.ast_json = json;

    ptr_out.* = if (json.len == 0) null else json.ptr;
    len_out.* = json.len;
    return .ok;
}

/// Resolve a selector against the editor's current tree — the live counterpart
/// of `twig_document_query`, e.g. to find a node's spans/kind before editing.
///
/// The returned matches are borrowed from `ed` and remain valid until the next
/// `twig_editor_query` call on that same handle, or until it is destroyed.
pub export fn twig_editor_query(
    ed: ?*TwigEditor,
    selector_ptr: ?[*]const u8,
    selector_len: usize,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const selector_src = sliceOf(selector_ptr, selector_len) orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asEditor(raw);

    const out = buildQueryMatches(allocator, handle.editor.astView(), selector_src) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
    };

    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.query_matches = out;

    ptr_out.* = if (out.len == 0) null else out.ptr;
    len_out.* = out.len;
    return .ok;
}

// ── Offset-addressed editing & read-back ─────────────────────────────────────
// The embeddable rich-text-editor surface (DESIGN.md's "Editor surface" tiers
// P0–P3): a caret speaks byte offsets, not locator
// strings. `edit_range` is the raw splice (`Editor.replaceAtSpan`) a keystroke
// maps onto; `node_at`/`nodes_at` hit-test an offset back to nodes; `nodes`
// hands out the whole tree as a flat array so a renderer needn't parse JSON.

fn spanC(s: twig.Span) TwigSpan {
    return .{ .start = s.start, .end = s.end };
}

fn changeC(c: twig.Splicer.Change) TwigChange {
    return .{ .old = spanC(c.old), .new = spanC(c.new) };
}

/// The node's static kind-tag name, matching `TwigQueryMatch.kind`.
fn kindName(node: *const twig.AST.Node) [*:0]const u8 {
    return @tagName(std.meta.activeTag(node.kind)).ptr;
}

/// The name a kind carries in its own payload rather than in `kind`: a generic
/// `element`'s tag (`"picture"`, `"source"`, `"div"`, …) and a `directive`'s
/// type (`"note"`, `"embed"`, `"vis"`, …, no leading colons). `null` for every
/// other kind, whose identity is `kind` alone. Both are cases of the same thing
/// — `kindName` reports every element as `"element"` and every directive as
/// `"directive"`, so without this a consumer cannot tell a `::embed` from a
/// `::toc`. Borrows the AST-owned name payload.
fn kindElementName(node: *const twig.AST.Node) ?[]const u8 {
    return switch (node.kind) {
        .container => |c| c.name,
        else => null,
    };
}

/// A `directive`'s surface form as a `TWIG_DIRECTIVE_*` code, or
/// `TWIG_DIRECTIVE_NONE` for every other kind. Pairs with `kindElementName`:
/// the name says *which* directive, this says *how it was written*, and a
/// consumer needs both — the same `embed` type is a span inline, a standalone
/// block as a leaf, and a wrapper as a container.
fn kindDirectiveForm(node: *const twig.AST.Node) c_int {
    return switch (node.kind) {
        .container => |c| if (c.form) |f| @intFromEnum(switch (f) {
            .inline_text => TwigDirectiveForm.text,
            .block_leaf => TwigDirectiveForm.leaf,
            .block_fenced => TwigDirectiveForm.container,
        }) else TWIG_DIRECTIVE_NONE,
        else => TWIG_DIRECTIVE_NONE,
    };
}

/// A heading's level, or 0 for any other kind.
fn kindLevel(node: *const twig.AST.Node) u32 {
    return switch (node.kind) {
        .heading => |h| h.level,
        else => 0,
    };
}

/// A `row`/`cell`'s header flag as a tri-state: 1 true, 0 false, -1 "not that
/// kind" — a table renderer needs to tell a header row from a body row.
fn kindHead(node: *const twig.AST.Node) c_int {
    return switch (node.kind) {
        .row => |r| @intFromBool(r.head),
        .cell => |c| @intFromBool(c.head),
        else => TWIG_HEAD_NONE,
    };
}

/// A `cell`'s column alignment as a `TWIG_ALIGN_*` code, or `TWIG_ALIGN_NONE`
/// for every other kind. The Markdown/Djot delimiter row (`|:--|--:|`) is
/// consumed by the parser and has no node of its own, so this is the only way
/// a consumer can recover the column alignment.
fn kindAlignment(node: *const twig.AST.Node) c_int {
    return switch (node.kind) {
        .cell => |c| switch (c.alignment) {
            .default => TWIG_ALIGN_DEFAULT,
            .left => TWIG_ALIGN_LEFT,
            .right => TWIG_ALIGN_RIGHT,
            .center => TWIG_ALIGN_CENTER,
        },
        else => TWIG_ALIGN_NONE,
    };
}

/// The node's primary text payload (a `str`'s bytes, a `code_block`'s body, …),
/// or `null` for kinds that carry none. Borrows the AST-owned payload.
fn kindText(node: *const twig.AST.Node) ?[]const u8 {
    return switch (node.kind) {
        .str, .symb, .verbatim, .inline_math, .display_math, .url, .email, .footnote_reference => |s| s,
        .comment, .doctype, .cdata => |s| s,
        // Each payload is a distinct anonymous struct type, so Zig can't merge
        // these captures into one prong — but each exposes a `.text` field.
        .code_block => |p| p.text,
        .raw_block => |p| p.text,
        .raw_inline => |p| p.text,
        .metadata => |p| p.text,
        .smart_punctuation => |p| p.text,
        else => null,
    };
}

/// A link/image destination, or `null`.
fn kindDestination(node: *const twig.AST.Node) ?[]const u8 {
    return switch (node.kind) {
        .link => |l| l.destination,
        .image => |l| l.destination,
        else => null,
    };
}

/// Splice `[start, end)` of the current source with `text` and reparse — the
/// offset-addressed primitive (`Editor.replaceAtSpan`) behind a caret editor:
/// a keystroke is `edit_range(caret, caret, "x")`, backspace
/// `edit_range(caret-1, caret, "")`, a selection replace `edit_range(a, b, s)`.
/// `start`/`end` are byte offsets into the *current* source with
/// `start <= end <= len`; a bad range is `invalid_argument`. On a reparse-
/// breaking edit the splice is rolled back and `edit_conflict` returned. On
/// success, if `out_change` is non-NULL it receives the byte effect (also
/// retrievable via `twig_editor_last_change`).
pub export fn twig_editor_edit_range(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    const handle = asEditor(raw);

    if (start > end or end > handle.editor.sourceBytes().len) return .invalid_argument;

    handle.editor.splicer.replaceAtSpan(twig.Span.init(start, end), text) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        // Any parse error means the edited document didn't reparse; it was
        // rolled back.
        else => return .edit_conflict,
    };
    if (out_change) |slot| slot.* = changeC(handle.editor.splicer.last_change.?);
    return .ok;
}

/// Write the byte effect of the last successful edit into `out_change`. Lets
/// the locator ops (`twig_editor_replace`, `_delete`, …) report their change
/// too, so a caret/selection can re-anchor without re-diffing. Returns
/// `not_found` if no edit has succeeded yet (nothing to report).
pub export fn twig_editor_last_change(
    ed: ?*TwigEditor,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const slot = out_change orelse return .invalid_argument;
    const change = asEditor(raw).editor.splicer.last_change orelse return .not_found;
    slot.* = changeC(change);
    return .ok;
}

/// Undo the last edit step, restoring the previous source and reparsing. On
/// success, if `out_change` is non-NULL it receives the byte effect of the undo
/// (current → restored) so a caret can re-anchor. Returns `not_found` when
/// there's nothing to undo. History is per-editor and spans every op that
/// funnels through `replaceAtSpan` (splices and the locator ops alike).
pub export fn twig_editor_undo(
    ed: ?*TwigEditor,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const change = (asEditor(raw).editor.splicer.undo() catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .edit_conflict,
    }) orelse return .not_found;
    if (out_change) |slot| slot.* = changeC(change);
    return .ok;
}

/// Redo the most recently undone edit step, symmetric to `twig_editor_undo`.
/// Returns `not_found` when the redo stack is empty (nothing was undone, or a
/// fresh edit has since invalidated it).
pub export fn twig_editor_redo(
    ed: ?*TwigEditor,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const change = (asEditor(raw).editor.splicer.redo() catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .edit_conflict,
    }) orelse return .not_found;
    if (out_change) |slot| slot.* = changeC(change);
    return .ok;
}

/// Fold the most recent edit into the undo step before it, so a caret editor can
/// coalesce a run of keystrokes into one undo. Call immediately after an
/// `edit_range` that continues a run (same kind, no intervening caret move). A
/// no-op unless there are at least two steps to merge.
pub export fn twig_editor_coalesce_last(ed: ?*TwigEditor) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    asEditor(raw).editor.splicer.coalesceLastUndo();
    return .ok;
}

/// A monotonic change token for `ed`, bumped once per successful mutation of the
/// document (`edit_range`, the locator ops, and undo/redo alike). Never
/// decreases and never repeats for the life of the editor; the initial parse is
/// revision 0. Equal revision ⇒ byte-identical document, so a caller can key a
/// cache on it instead of hand-tracking "did anything change?". Returns 0 for a
/// NULL `ed` (which also matches a fresh editor — harmless as a cache key).
pub export fn twig_editor_revision(ed: ?*TwigEditor) u64 {
    const raw = ed orelse return 0;
    return asEditor(raw).editor.splicer.revision;
}

/// Report the cumulative dirty byte range for `ed` — the union of every
/// mutation's byte effect (`edit_range`, the locator ops, and undo/redo alike)
/// since the last `twig_editor_clear_dirty`, or since the editor was created if
/// it has never been cleared. In CURRENT source coordinates. Writes the range
/// into `out_span` and returns `.ok`; returns `.not_found` when the document is
/// clean relative to the last clear (`out_span` left untouched).
///
/// This is the incremental-rebuild companion to `twig_editor_revision`:
/// `revision` says *whether* to rebuild a cached view, this says *which bytes*
/// to rebuild so a consumer can touch only the affected rows/spans. The range
/// is a single CONSERVATIVE interval — it always covers every changed byte and
/// may over-cover the gap between edits to disjoint regions, but never
/// under-covers.
///
/// It reports where BYTES differ (exact, because Twig splices losslessly and
/// never reflows untouched bytes), NOT where the PARSE differs: an edit can
/// reinterpret bytes outside this range — opening a code fence, a `#` promoting
/// a paragraph to a heading. A consumer rebuilding STRUCTURE from the range
/// should widen it to the enclosing block(s) itself (e.g. via
/// `twig_editor_node_at` on each end); that policy is the renderer's, not
/// Twig's. Typical loop: on a repaint, if `twig_editor_revision` moved, read
/// this range, rebuild the rows it (widened) covers, then `twig_editor_clear_dirty`.
pub export fn twig_editor_dirty_range(ed: ?*TwigEditor, out_span: ?*TwigSpan) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const slot = out_span orelse return .invalid_argument;
    const d = asEditor(raw).editor.splicer.dirtyRange() orelse return .not_found;
    slot.* = spanC(d);
    return .ok;
}

/// Acknowledge the current dirty range: mark `ed` clean so the next
/// `twig_editor_dirty_range` reports only mutations made after this call. Call
/// it once you have consumed the range (rebuilt the affected view). Leaves the
/// document, `twig_editor_revision`, and `twig_editor_last_change` untouched.
pub export fn twig_editor_clear_dirty(ed: ?*TwigEditor) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    asEditor(raw).editor.splicer.clearDirty();
    return .ok;
}

/// Attach an opaque, caller-owned blob (e.g. a serialized caret/selection) to
/// the editor's CURRENT document state. Twig copies the bytes and never
/// interprets them; it only carries them through the undo history so undo/redo
/// hand back the caret that matches the restored source (see
/// `twig_editor_caret_blob`). Set it with the pre-edit caret BEFORE an edit so
/// the retired undo step captures it. A zero-length blob clears the current
/// caret. `blob_ptr` may be NULL only when `blob_len` is 0.
pub export fn twig_editor_set_caret_blob(
    ed: ?*TwigEditor,
    blob_ptr: ?[*]const u8,
    blob_len: usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const blob = sliceOf(blob_ptr, blob_len) orelse return .invalid_argument;
    asEditor(raw).editor.splicer.setCaret(blob) catch return .out_of_memory;
    return .ok;
}

/// Read back the opaque caret blob for the editor's CURRENT document state (see
/// `twig_editor_set_caret_blob`). After `twig_editor_undo`/`_redo` this is the
/// restored state's caret; after an edit it is empty until the caller sets one.
///
/// The bytes are borrowed directly from the editor and stay valid until the next
/// `twig_editor_set_caret_blob`, successful edit, or undo/redo on this handle, or
/// until it is destroyed. `out_ptr` is NULL when the blob is empty.
pub export fn twig_editor_caret_blob(
    ed: ?*TwigEditor,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const bytes = asEditor(raw).editor.splicer.caretBlob();
    ptr_out.* = if (bytes.len == 0) null else bytes.ptr;
    len_out.* = bytes.len;
    return .ok;
}

/// Snapshot the editor's current tree as a flat array of `TwigFlatNode`, one
/// per arena node, indexed so `array[i].id == i`. The JSON-free read path for
/// a renderer: one call, one buffer, walked via the `parent`/`first_child`/
/// `next_sibling` id links (`TWIG_NO_NODE` where absent). The root is the node
/// whose `parent == TWIG_NO_NODE`.
///
/// The returned array is borrowed from `ed` and stays valid until the next
/// `twig_editor_nodes` call on this handle or `twig_editor_destroy`. The
/// `text`/`destination` pointers within it additionally require no *successful
/// edit* to have happened since (a reparse frees the payloads they borrow).
pub export fn twig_editor_nodes(
    ed: ?*TwigEditor,
    out_ptr: ?*?[*]const TwigFlatNode,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;

    const allocator = activeAllocator();
    const handle = asEditor(raw);
    const ast = handle.editor.astView();
    const nodes = ast.nodes;

    const buf = allocator.alloc(TwigFlatNode, nodes.len) catch return .out_of_memory;
    for (nodes, 0..) |*node, i| {
        buf[i] = flatNodeOf(
            node,
            @intCast(i),
            TWIG_NO_NODE, // parent filled in the pass below
            node.first_child orelse TWIG_NO_NODE,
            node.next_sibling orelse TWIG_NO_NODE,
        );
    }
    // Parent pass: a `Node` stores children, not its parent, so derive it by
    // stamping each node's children with its own id (one linear walk).
    for (nodes, 0..) |node, i| {
        var child = node.first_child;
        while (child) |cid| {
            buf[cid].parent = @intCast(i);
            child = nodes[cid].next_sibling;
        }
    }

    // Attributes: marshal into a companion buffer the flat nodes point into.
    // Built before publishing `buf` so a mid-way OOM leaves the old snapshot
    // intact. Identity order — `buf[i]` is arena node `i` for the whole tree.
    const attrs = fillAttrs(allocator, ast, buf, null) catch {
        allocator.free(buf);
        return .out_of_memory;
    };

    if (handle.flat_nodes.len != 0) allocator.free(handle.flat_nodes);
    if (handle.flat_attrs.len != 0) allocator.free(handle.flat_attrs);
    handle.flat_nodes = buf;
    handle.flat_attrs = attrs orelse &.{};

    ptr_out.* = if (buf.len == 0) null else buf.ptr;
    len_out.* = buf.len;
    return .ok;
}

/// The direct children of `node_id` as `TwigQueryMatch` (id, span, kind) — the
/// cheap top-level enumeration an incremental renderer uses to find the blocks
/// it must consider without marshalling the whole arena. Pair it with
/// `twig_editor_subtree` to then re-marshal only the block(s) that changed. Pass
/// `TWIG_NO_NODE` for `node_id` to enumerate the DOCUMENT ROOT's children (the
/// top-level blocks), so a caller needn't first look the root up.
///
/// Same borrow contract as `twig_editor_query`, on its own buffer (replaced on
/// the next `twig_editor_child_spans` call, freed on destroy). A childless node
/// yields a zero-length result and `.ok`. A `node_id` that is neither in range
/// nor the sentinel is `invalid_argument`.
pub export fn twig_editor_child_spans(
    ed: ?*TwigEditor,
    node_id: u32,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const allocator = activeAllocator();
    const handle = asEditor(raw);
    const ast = handle.editor.astView();

    const parent: twig.AST.Node.Id = if (node_id == TWIG_NO_NODE)
        ast.root
    else if (node_id < ast.nodes.len)
        node_id
    else
        return .invalid_argument;

    var list: std.ArrayList(TwigQueryMatch) = .empty;
    defer list.deinit(allocator);
    var it = ast.children(parent);
    while (it.next()) |child| {
        list.append(allocator, flatMatch(ast, child.id)) catch return .out_of_memory;
    }

    if (handle.child_spans.len != 0) allocator.free(handle.child_spans);
    handle.child_spans = list.toOwnedSlice(allocator) catch return .out_of_memory;
    ptr_out.* = if (handle.child_spans.len == 0) null else handle.child_spans.ptr;
    len_out.* = handle.child_spans.len;
    return .ok;
}

/// Snapshot the subtree rooted at `node_id` as a self-contained flat array with
/// LOCAL ids: `array[0]` is the root, every `id`/`parent`/`first_child`/
/// `next_sibling` is an index into THIS array (or `TWIG_NO_NODE`), and spans
/// stay ABSOLUTE (byte offsets into the whole document). The incremental-render
/// companion to `twig_editor_nodes`: a consumer that has localized an edit to
/// one block re-marshals only that block's subtree instead of the whole arena.
///
/// Because the array stops at the subtree, the root's `parent` and
/// `next_sibling` are `TWIG_NO_NODE` — a walker started at index 0 never
/// escapes it. Same borrow contract as `twig_editor_nodes` but on its own buffer
/// (replaced on the next `twig_editor_subtree` call): the `text`/`destination`
/// pointers additionally require no successful edit since. `node_id` out of
/// range is `invalid_argument`.
pub export fn twig_editor_subtree(
    ed: ?*TwigEditor,
    node_id: u32,
    out_ptr: ?*?[*]const TwigFlatNode,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const allocator = activeAllocator();
    const handle = asEditor(raw);
    const ast = handle.editor.astView();
    if (node_id >= ast.nodes.len) return .invalid_argument;

    // The traversal is `AST.subtreeIds`; everything below is the wire remap into
    // a dense local id space (`local[old] = new`), which is genuinely the ABI's.
    const ids = ast.subtreeIds(allocator, node_id) catch return .out_of_memory;
    defer allocator.free(ids);

    const local = allocator.alloc(u32, ast.nodes.len) catch return .out_of_memory;
    defer allocator.free(local);
    @memset(local, TWIG_NO_NODE);
    for (ids, 0..) |old_id, i| local[old_id] = @intCast(i);

    const buf = allocator.alloc(TwigFlatNode, ids.len) catch return .out_of_memory;
    for (ids, 0..) |old_id, i| {
        const node = &ast.nodes[old_id];
        buf[i] = flatNodeOf(
            node,
            @intCast(i),
            TWIG_NO_NODE, // parent filled in the pass below
            mapLocal(local, node.first_child),
            // The root's next_sibling leaves the subtree, so `local` maps it to
            // NO_NODE; a descendant's sibling is always inside.
            mapLocal(local, node.next_sibling),
        );
    }
    // Parent pass in local space (a `Node` stores children, not its parent).
    for (ids, 0..) |old_id, i| {
        var child = ast.nodes[old_id].first_child;
        while (child) |cid| {
            buf[local[cid]].parent = @intCast(i);
            child = ast.nodes[cid].next_sibling;
        }
    }

    // Attributes, keyed by the subtree's arena-id list (`buf[i]` is `ids[i]`).
    const attrs = fillAttrs(allocator, ast, buf, ids) catch {
        allocator.free(buf);
        return .out_of_memory;
    };

    if (handle.subtree_nodes.len != 0) allocator.free(handle.subtree_nodes);
    if (handle.subtree_attrs.len != 0) allocator.free(handle.subtree_attrs);
    handle.subtree_nodes = buf;
    handle.subtree_attrs = attrs orelse &.{};
    ptr_out.* = if (buf.len == 0) null else buf.ptr;
    len_out.* = buf.len;
    return .ok;
}

/// The deepest node whose span contains byte `offset` (half-open `[start, end)`,
/// with `offset == source.len` treated as inside the root) — mouse hit-testing
/// and "what's my cursor context". Descends from the root into the last child
/// that still contains the offset. Nodes with an unset `(0,0)` span (some
/// parsers leave inline spans unpopulated) can't be descended into and are
/// skipped. Fills `out_match` and returns `ok`, or `not_found` if no node
/// covers the offset (`invalid_argument` if `offset > source.len`).
pub export fn twig_editor_node_at(
    ed: ?*TwigEditor,
    offset: usize,
    out_match: ?*TwigQueryMatch,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const slot = out_match orelse return .invalid_argument;
    const handle = asEditor(raw);
    const ast = handle.editor.astView();
    if (offset > handle.editor.sourceBytes().len) return .invalid_argument;

    const found = twig.locate.deepestContaining(ast, offset, handle.editor.sourceBytes().len) orelse return .not_found;
    slot.* = flatMatch(ast, found);
    return .ok;
}

/// The chain of nodes containing byte `offset`, root-first down to the deepest
/// (the same node `twig_editor_node_at` returns) — the ancestor path for
/// breadcrumbs or context-scoped edits. Same borrow contract as
/// `twig_editor_query`, but on an independent buffer. Returns `not_found` (and
/// a zero-length result) if nothing covers the offset.
pub export fn twig_editor_nodes_at(
    ed: ?*TwigEditor,
    offset: usize,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const allocator = activeAllocator();
    const handle = asEditor(raw);
    const ast = handle.editor.astView();
    if (offset > handle.editor.sourceBytes().len) return .invalid_argument;

    const len = handle.editor.sourceBytes().len;
    // Rebuild the exact root→deepest descent path, so the chain's last element
    // is always the node `twig_editor_node_at` returns. The root is included as
    // the outermost breadcrumb even when its own span is unset.
    const deepest = twig.locate.deepestContaining(ast, offset, len) orelse {
        if (handle.ancestor_matches.len != 0) allocator.free(handle.ancestor_matches);
        handle.ancestor_matches = &.{};
        ptr_out.* = null;
        len_out.* = 0;
        return .not_found;
    };

    var chain: std.ArrayList(TwigQueryMatch) = .empty;
    defer chain.deinit(allocator);

    var cur = ast.root;
    chain.append(allocator, flatMatch(ast, cur)) catch return .out_of_memory;
    while (cur != deepest) {
        cur = twig.locate.childContaining(ast, cur, offset, len) orelse break;
        chain.append(allocator, flatMatch(ast, cur)) catch return .out_of_memory;
    }

    if (handle.ancestor_matches.len != 0) allocator.free(handle.ancestor_matches);
    handle.ancestor_matches = chain.toOwnedSlice(allocator) catch return .out_of_memory;
    ptr_out.* = handle.ancestor_matches.ptr;
    len_out.* = handle.ancestor_matches.len;
    return .ok;
}

/// Build a `TwigQueryMatch` for a node id from the flat arena.
fn flatMatch(ast: *const twig.AST, id: twig.AST.Node.Id) TwigQueryMatch {
    const node = &ast.nodes[id];
    return .{
        .node_id = id,
        .span = spanC(node.span),
        .content_span = if (node.content_span) |cs| spanC(cs) else .{ .start = 0, .end = 0 },
        .has_content_span = if (node.content_span != null) 1 else 0,
        .kind = kindName(node),
    };
}

/// Fill one `TwigFlatNode` for `node`, given its (already-resolved) id and link
/// ids in whatever id space the caller is building — arena ids for
/// `twig_editor_nodes`, local ids for `twig_editor_subtree`. Spans are always
/// absolute; only the links differ between the two callers.
fn flatNodeOf(node: *const twig.AST.Node, id: u32, parent: u32, first_child: u32, next_sibling: u32) TwigFlatNode {
    const text = kindText(node);
    const dest = kindDestination(node);
    const name = kindElementName(node);
    return .{
        .id = id,
        .parent = parent,
        .first_child = first_child,
        .next_sibling = next_sibling,
        .span = spanC(node.span),
        .content_span = if (node.content_span) |cs| spanC(cs) else .{ .start = 0, .end = 0 },
        .has_content_span = if (node.content_span != null) 1 else 0,
        .level = kindLevel(node),
        .kind = kindName(node),
        .text_ptr = if (text) |t| t.ptr else null,
        .text_len = if (text) |t| t.len else 0,
        .destination_ptr = if (dest) |d| d.ptr else null,
        .destination_len = if (dest) |d| d.len else 0,
        .head = kindHead(node),
        .alignment = kindAlignment(node),
        .name_ptr = if (name) |n| n.ptr else null,
        .name_len = if (name) |n| n.len else 0,
        // Filled by `fillAttrs` after the array is built (attrs need a companion
        // buffer the individual node struct can't own); NULL until then.
        .attrs_ptr = null,
        .attrs_len = 0,
        .directive_form = kindDirectiveForm(node),
    };
}

/// Marshal every snapshot node's attributes into one `TwigKeyVal` buffer and
/// point each flat node's `attrs_ptr`/`attrs_len` at its slice of it. `order[i]`
/// is the ARENA id whose attributes land on `buf[i]`; `null` means identity
/// (`buf[i]` is arena node `i`), which is the whole-tree snapshot — a subtree
/// snapshot passes its id list. The returned buffer is owned by the caller (to
/// cache on the handle and free on destroy); the key/value pointers inside it
/// borrow the AST payload, so it shares the snapshot's "invalid after a
/// successful edit" lifetime. `null` when no node carries any attribute (nothing
/// to allocate).
///
/// The AST-side knowledge — which nodes have attributes and where they live —
/// is `AST.attrsOf`'s (reader.zig); this is only the wire copy of its native
/// `KeyVal` entries into the `TwigKeyVal` layout the ABI hands out.
fn fillAttrs(
    allocator: Allocator,
    ast: *const twig.AST,
    buf: []TwigFlatNode,
    order: ?[]const u32,
) Allocator.Error!?[]TwigKeyVal {
    const arenaId = struct {
        fn at(ord: ?[]const u32, i: usize) twig.AST.Node.Id {
            return if (ord) |o| o[i] else @intCast(i);
        }
    }.at;

    var total: usize = 0;
    for (0..buf.len) |i| total += ast.attrsOf(arenaId(order, i)).entries.len;
    if (total == 0) return null;

    const store = try allocator.alloc(TwigKeyVal, total);
    var cursor: usize = 0;
    for (0..buf.len) |i| {
        const entries = ast.attrsOf(arenaId(order, i)).entries;
        for (entries, 0..) |kv, j| store[cursor + j] = keyValC(kv);
        if (entries.len != 0) {
            buf[i].attrs_ptr = store.ptr + cursor;
            buf[i].attrs_len = entries.len;
            cursor += entries.len;
        }
    }
    return store;
}

/// One native `KeyVal` in the C-ABI `TwigKeyVal` layout. A bare attribute
/// (`disabled`, `<source media …>` with no value) keeps a NULL `value`.
fn keyValC(kv: twig.AST.KeyVal) TwigKeyVal {
    return .{
        .key = kv.key.ptr,
        .key_len = kv.key.len,
        .value = if (kv.value) |v| v.ptr else null,
        .value_len = if (kv.value) |v| v.len else 0,
    };
}

/// Map an optional arena id into the local id space of a `twig_editor_subtree`
/// snapshot: `local[old]` for an id inside the subtree, `TWIG_NO_NODE` for
/// `null` or for a link that leaves the subtree (the root's `next_sibling`).
/// The one piece of `subtree` that is genuinely a wire concern — the traversal
/// itself is `AST.subtreeIds` in `ast/reader.zig`.
fn mapLocal(local: []const u32, maybe: ?twig.AST.Node.Id) u32 {
    const id = maybe orelse return TWIG_NO_NODE;
    return local[id];
}

// ── Range-oriented rich-text ops (the toolbar) ───────────────────────────────
// DESIGN.md's "Editor surface" tier P5.
// wrap_range / toggle_inline / set_block: a caret editor's Bold / Italic / Code
// buttons and its H1 / Body switch.
//
// The format-specific knowledge (which delimiters mark a `strong`, how a heading
// is spelled) used to live HERE, on the theory that this was "the boundary that
// knows the format". It isn't — it's the boundary that knows C. The tables are
// `syntax.zig`'s and the gestures are `twig.Editor`'s; what's left below is a
// `c_int` decode and an error map.

/// The inline mark kinds `twig_editor_wrap_range` / `_toggle_inline` accept
/// (C ABI enum; values are the wire contract, mirrored by `TwigInlineKind` in
/// `twig.h`).
const TwigInlineKind = enum(c_int) {
    strong = 0,
    emph = 1,
    verbatim = 2,
    mark = 3,
    superscript = 4,
    subscript = 5,
    insert = 6,
    delete = 7,
};

/// The block kinds `twig_editor_set_block` converts to.
const TwigBlockKind = enum(c_int) {
    paragraph = 0,
    heading = 1,
};

/// Map a raw C `int` to a `TwigInlineKind`, or `null` if it names none.
fn inlineKindFromInt(v: c_int) ?TwigInlineKind {
    return switch (v) {
        0 => .strong,
        1 => .emph,
        2 => .verbatim,
        3 => .mark,
        4 => .superscript,
        5 => .subscript,
        6 => .insert,
        7 => .delete,
        else => null,
    };
}

/// Map a raw C `int` to a `TwigBlockKind`, or `null` if it names none.
fn blockKindFromInt(v: c_int) ?TwigBlockKind {
    return switch (v) {
        0 => .paragraph,
        1 => .heading,
        else => null,
    };
}

/// The `twig.Editor` inline kind a wire code names.
fn inlineKindOf(kind: TwigInlineKind) twig.Editor.InlineKind {
    return switch (kind) {
        inline else => |k| @field(twig.Editor.InlineKind, @tagName(k)),
    };
}

/// Wrap `[start, end)` of the source with `kind`'s delimiters — the
/// unconditional half of the inline toolbar (always adds a mark). A kind the
/// format can't spell is `unsupported_format`; see `twig.Editor.wrapRange`.
pub export fn twig_editor_wrap_range(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    kind: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const ik = inlineKindFromInt(kind) orelse return .invalid_argument;

    handle.editor.wrapRange(twig.Span.init(start, end), inlineKindOf(ik)) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

/// Toggle `kind` over `[start, end)`: strip the mark if the range already *is* a
/// node of `kind`, else wrap it — a rich editor's Cmd-B. See
/// `twig.Editor.toggleInline`.
pub export fn twig_editor_toggle_inline(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    kind: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const ik = inlineKindFromInt(kind) orelse return .invalid_argument;

    handle.editor.toggleInline(twig.Span.init(start, end), inlineKindOf(ik)) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

/// Convert the block at `offset` to `block_kind` (a `level`-N heading, or a
/// paragraph) — the block half of the toolbar (H1 / Body). See
/// `twig.Editor.setBlock`.
pub export fn twig_editor_set_block(
    ed: ?*TwigEditor,
    offset: usize,
    block_kind: c_int,
    level: u32,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const bk = blockKindFromInt(block_kind) orelse return .invalid_argument;

    handle.editor.setBlock(offset, switch (bk) {
        .paragraph => .paragraph,
        .heading => .heading,
    }, level) catch |err| return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

// ── Block containers (quote / lists) ─────────────────────────────────────────
// The engine — line surgery over the covered blocks, the nest/convert/peel
// decision, the per-format marker table — is `twig.Editor.toggleBlockContainer`.
// What belongs here is the wire enum and its decode.

/// The container kinds `twig_editor_toggle_block_container` toggles (C ABI enum;
/// values are the wire contract, mirrored by `TwigBlockContainerKind` in
/// `twig.h`).
const TwigBlockContainerKind = enum(c_int) {
    block_quote = 0,
    bullet_list = 1,
    ordered_list = 2,
};

/// Map a raw C `int` to a `TwigBlockContainerKind`, or `null` if it names none.
fn blockContainerKindFromInt(v: c_int) ?TwigBlockContainerKind {
    return switch (v) {
        0 => .block_quote,
        1 => .bullet_list,
        2 => .ordered_list,
        else => null,
    };
}

/// The `twig.Editor` container kind a wire code names. The two vocabularies are
/// deliberately separate types: this one's integers are frozen by the ABI, that
/// one's are Zig's business.
fn containerKindOf(kind: TwigBlockContainerKind) twig.Editor.ContainerKind {
    return switch (kind) {
        .block_quote => .block_quote,
        .bullet_list => .bullet_list,
        .ordered_list => .ordered_list,
    };
}

/// Toggle a block container (quote / bullet list / ordered list) over the blocks
/// `[start, end)` covers. See `twig.h` for the semantics and
/// `twig.Editor.toggleBlockContainer` for the implementation.
pub export fn twig_editor_toggle_block_container(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    container_kind: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const ck = blockContainerKindFromInt(container_kind) orelse return .invalid_argument;

    handle.editor.toggleBlockContainer(twig.Span.init(start, end), containerKindOf(ck)) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

/// Renumber the ordered list at `offset` so its markers run `1, 2, 3, …` — see
/// `twig.Editor.renumberOrderedLists`. `not_found` when `offset` is not inside an
/// ordered list. When the numbering is already sequential this is a no-op that
/// still returns `.ok`; `out_change` then reports the most recent prior edit (or
/// is left untouched when there is none), so a caller must not treat a `.ok`
/// return as proof the source moved.
pub export fn twig_editor_renumber_ordered_lists(
    ed: ?*TwigEditor,
    offset: usize,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    handle.editor.renumberOrderedLists(offset) catch |err| return statusOfEditorError(err);
    if (out_change) |slot| {
        if (handle.editor.lastChange()) |c| slot.* = changeC(c);
    }
    return .ok;
}

// ── Tables ───────────────────────────────────────────────────────────────────
// The engine — grid extraction, the mutations, the re-spelled delimiter — is
// `twig.Editor`'s `table*` gestures over `table_edit.zig`. One entry point
// carries them all: `op` picks the gesture, `arg` its parameter.

/// The `op` codes for `twig_editor_table_edit` (the wire contract, mirrored by
/// `TwigTableOp` in `twig.h`).
const TwigTableOp = enum(c_int) {
    insert_row = 0,
    delete_row = 1,
    insert_column = 2,
    delete_column = 3,
    set_alignment = 4,
    move_row = 5,
    move_column = 6,
};

/// Edit the table at `offset`. `op` names the gesture; `arg` is its parameter:
/// for insert/move a side (0 = before/up/left, 1 = after/down/right), for
/// set_alignment a `TwigAlignment`, and ignored for the deletes. `not_found`
/// when `offset` is not in a table, `not_editable` for a refused (degenerate)
/// edit. Fills out_change on success if non-NULL.
pub export fn twig_editor_table_edit(
    ed: ?*TwigEditor,
    offset: usize,
    op: c_int,
    arg: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const e = &handle.editor;
    const result: twig.Editor.Error!void = switch (op) {
        @intFromEnum(TwigTableOp.insert_row) => e.tableInsertRow(offset, arg != 0),
        @intFromEnum(TwigTableOp.delete_row) => e.tableDeleteRow(offset),
        @intFromEnum(TwigTableOp.insert_column) => e.tableInsertColumn(offset, arg != 0),
        @intFromEnum(TwigTableOp.delete_column) => e.tableDeleteColumn(offset),
        @intFromEnum(TwigTableOp.set_alignment) => e.tableSetAlignment(
            offset,
            alignmentOf(arg) orelse return .invalid_argument,
        ),
        @intFromEnum(TwigTableOp.move_row) => e.tableMoveRow(offset, arg != 0),
        @intFromEnum(TwigTableOp.move_column) => e.tableMoveColumn(offset, arg != 0),
        else => return .invalid_argument,
    };
    result catch |err| return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

// ── Links ────────────────────────────────────────────────────────────────────
// The engine — the per-format escape alphabets, the autolink spelling, the
// link/autolink node reasoning — is `twig.Editor.insertLink`.

/// Link `[start, end)` to `destination`, or repoint the link already there. See
/// `twig.h` for the full semantics and `twig.Editor.insertLink` for the
/// implementation and its rationale.
pub export fn twig_editor_insert_link(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    destination_ptr: ?[*]const u8,
    destination_len: usize,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const dest = sliceOf(destination_ptr, destination_len) orelse return .invalid_argument;

    handle.editor.insertLink(twig.Span.init(start, end), dest) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

/// Spell `[start, end)` as an image pointing at `destination`. See `twig.h` for
/// the semantics and `twig.Editor.insertImage` for the implementation and its
/// rationale — in particular why the destination spelling is not the caller's to
/// reproduce.
pub export fn twig_editor_insert_image(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    destination_ptr: ?[*]const u8,
    destination_len: usize,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const dest = sliceOf(destination_ptr, destination_len) orelse return .invalid_argument;

    handle.editor.insertImage(twig.Span.init(start, end), dest) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

// ── Literal text ───────────────────────────────────────────────────────────────
// The engine — the per-format `text_escapes`/`block_start_escapes` alphabets and
// the positional escape walk — is `twig.Editor.insertLiteral`.

/// Insert `text` at `offset` as a literal run, escaped for the format so it
/// reparses as exactly `text`. See `twig.h` for the semantics and
/// `twig.Editor.insertLiteral` for the implementation and its rationale.
pub export fn twig_editor_insert_literal(
    ed: ?*TwigEditor,
    offset: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;

    handle.editor.insertLiteral(offset, text) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

// ── In-cell line break ─────────────────────────────────────────────────────────
// The engine is `twig.Editor.insertLineBreak`: inside a table cell it splices the
// format's `Syntax.cell_line_break` (`<br>` for Markdown), which reparses as a
// `hard_break`. `unsupported_format` when the format has no in-cell break (djot,
// HTML, XML); `not_found` when `offset` is not inside a cell.

/// Insert a hard line break inside the table cell at `offset`, spelled the
/// format's way. See `twig.h` for the semantics and `twig.Editor.insertLineBreak`
/// for the implementation and its rationale.
pub export fn twig_editor_insert_line_break(
    ed: ?*TwigEditor,
    offset: usize,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);

    handle.editor.insertLineBreak(offset) catch |err|
        return statusOfEditorError(err);
    if (out_change) |slot| slot.* = changeC(handle.editor.lastChange().?);
    return .ok;
}

// ── Builder ──────────────────────────────────────────────────────────────────
// Programmatic construction of a document, the write-path mirror of `twig_parse`
// (which reads a document from source). Wraps `twig.AST.Builder`: build the tree
// bottom-up — add children, then the container from their ids — where every
// `twig_builder_add*` call returns the new node's id through `out_id`. Then
// render / serialize / query / dump the subtree rooted at any id, on demand,
// WITHOUT consuming the builder (via `Builder.view`), so a build can be inspected
// and extended freely. Mirrors fig's `fig_value_*` value-construction surface.
//
// Two contracts, inherited from `twig.AST.Builder`:
//   * Every string handed in is COPIED — the caller's buffers need not outlive
//     the call, and a built tree borrows no source.
//   * Each node id must be placed in exactly one parent (`set_children`); reusing
//     an id in two parents corrupts the sibling chain (asserted in safe builds).

pub const TwigBuilder = opaque {};

/// The full shared `Node.Kind` vocabulary as stable C ABI codes, in
/// `ast.zig` declaration order. Used by `twig_builder_add` (void-payload kinds)
/// and `twig_builder_add_text` (single-string-payload kinds) to pick a kind;
/// the kinds with richer payloads have their own dedicated `twig_builder_add_*`
/// constructors and are not selectable through those two entry points.
pub const TwigNodeKind = enum(c_int) {
    doc = 0,
    para = 1,
    heading = 2,
    thematic_break = 3,
    section = 4,
    div = 5,
    code_block = 6,
    raw_block = 7,
    metadata = 8,
    block_quote = 9,
    bullet_list = 10,
    ordered_list = 11,
    task_list = 12,
    definition_list = 13,
    table = 14,
    list_item = 15,
    task_list_item = 16,
    definition_list_item = 17,
    term = 18,
    definition = 19,
    row = 20,
    cell = 21,
    caption = 22,
    footnote = 23,
    reference = 24,
    str = 25,
    soft_break = 26,
    hard_break = 27,
    non_breaking_space = 28,
    symb = 29,
    verbatim = 30,
    raw_inline = 31,
    inline_math = 32,
    display_math = 33,
    url = 34,
    email = 35,
    footnote_reference = 36,
    smart_punctuation = 37,
    emph = 38,
    strong = 39,
    link = 40,
    image = 41,
    span = 42,
    mark = 43,
    superscript = 44,
    subscript = 45,
    insert = 46,
    delete = 47,
    double_quoted = 48,
    single_quoted = 49,
    directive = 50,
    element = 51,
    comment = 52,
    doctype = 53,
    processing_instruction = 54,
    cdata = 55,
};

pub const TwigBulletStyle = enum(c_int) { dash = 0, plus = 1, star = 2 };
pub const TwigOrderedNumbering = enum(c_int) { decimal = 0, lower_alpha = 1, upper_alpha = 2, lower_roman = 3, upper_roman = 4 };
pub const TwigOrderedDelim = enum(c_int) { period = 0, paren_after = 1, paren_both = 2 };
pub const TwigAlignment = enum(c_int) { default = 0, left = 1, right = 2, center = 3 };
pub const TwigSmartPunctuation = enum(c_int) {
    left_single_quote = 0,
    right_single_quote = 1,
    left_double_quote = 2,
    right_double_quote = 3,
    ellipses = 4,
    em_dash = 5,
    en_dash = 6,
};
pub const TwigDirectiveForm = enum(c_int) { text = 0, leaf = 1, container = 2 };

/// One attribute pair for `twig_builder_set_attrs`. A NULL `value` is a *bare*
/// attribute (HTML `disabled`), distinct from a present-but-empty value
/// (`value` non-NULL, `value_len == 0`, i.e. `disabled=""`). The strings are
/// copied, so they need not outlive the call.
pub const TwigKeyVal = extern struct {
    key: ?[*]const u8,
    key_len: usize,
    value: ?[*]const u8,
    value_len: usize,
};

const BuilderHandle = struct {
    builder: twig.AST.Builder,
    /// Caller-borrowed output buffers, same contract as `DocumentHandle`'s:
    /// owned by the handle, replaced on the next call to the same accessor,
    /// freed on destroy.
    rendered: []u8 = &.{},
    serialized: []u8 = &.{},
    ast_json: []u8 = &.{},
    query_matches: []TwigQueryMatch = &.{},
};

fn asBuilder(b: *TwigBuilder) *BuilderHandle {
    return @ptrCast(@alignCast(b));
}

/// Write the id a builder call produced to `out_id`, mapping allocation failure
/// to a status. Node construction can only fail on OOM.
fn emitNode(out_id: ?*u32, result: Allocator.Error!twig.AST.Node.Id) TwigStatus {
    const out = out_id orelse return .invalid_argument;
    const id = result catch return .out_of_memory;
    out.* = id;
    return .ok;
}

pub export fn twig_builder_create(out_builder: ?*?*TwigBuilder) TwigStatus {
    const out = out_builder orelse return .invalid_argument;
    out.* = null;
    const allocator = activeAllocator();
    const handle = allocator.create(BuilderHandle) catch return .out_of_memory;
    handle.* = .{ .builder = twig.AST.Builder.init(allocator) };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn twig_builder_destroy(b: ?*TwigBuilder) void {
    const raw = b orelse return;
    const allocator = activeAllocator();
    const handle = asBuilder(raw);
    if (handle.rendered.len != 0) allocator.free(handle.rendered);
    if (handle.serialized.len != 0) allocator.free(handle.serialized);
    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.builder.deinit();
    allocator.destroy(handle);
}

// ── constructors ─────────────────────────────────────────────────────────────
// Grouped by payload shape: `add` for the void-payload kinds (children attached
// later via `set_children`), `add_text` for the single-string-payload kinds, and
// a dedicated constructor for each kind carrying a richer payload.

/// The void-payload `Node.Kind` for a `TwigNodeKind` code, or `null` if the code
/// names a kind with a payload (which needs its own `twig_builder_add_*`) or is
/// unknown. Any of these may still be given children via `twig_builder_set_children`.
fn voidKind(kind: c_int) ?twig.AST.Node.Kind {
    return switch (kind) {
        @intFromEnum(TwigNodeKind.doc) => .doc,
        @intFromEnum(TwigNodeKind.para) => .para,
        @intFromEnum(TwigNodeKind.thematic_break) => .thematic_break,
        @intFromEnum(TwigNodeKind.section) => .section,
        // `div`/`span` are no longer kinds of their own; the legacy codes
        // still build what they always built, now spelled as a `container`.
        @intFromEnum(TwigNodeKind.div) => .{ .container = .{ .name = "div", .form = .block_fenced } },
        @intFromEnum(TwigNodeKind.span) => .{ .container = .{ .name = "span", .form = .inline_text } },
        @intFromEnum(TwigNodeKind.block_quote) => .block_quote,
        @intFromEnum(TwigNodeKind.definition_list) => .definition_list,
        @intFromEnum(TwigNodeKind.table) => .table,
        @intFromEnum(TwigNodeKind.list_item) => .list_item,
        @intFromEnum(TwigNodeKind.definition_list_item) => .definition_list_item,
        @intFromEnum(TwigNodeKind.term) => .term,
        @intFromEnum(TwigNodeKind.definition) => .definition,
        @intFromEnum(TwigNodeKind.caption) => .caption,
        @intFromEnum(TwigNodeKind.soft_break) => .soft_break,
        @intFromEnum(TwigNodeKind.hard_break) => .hard_break,
        @intFromEnum(TwigNodeKind.non_breaking_space) => .non_breaking_space,
        @intFromEnum(TwigNodeKind.emph) => .emph,
        @intFromEnum(TwigNodeKind.strong) => .strong,
        @intFromEnum(TwigNodeKind.mark) => .mark,
        @intFromEnum(TwigNodeKind.superscript) => .superscript,
        @intFromEnum(TwigNodeKind.subscript) => .subscript,
        @intFromEnum(TwigNodeKind.insert) => .insert,
        @intFromEnum(TwigNodeKind.delete) => .delete,
        @intFromEnum(TwigNodeKind.double_quoted) => .double_quoted,
        @intFromEnum(TwigNodeKind.single_quoted) => .single_quoted,
        else => null,
    };
}

/// Add a void-payload node (`para`, `emph`, `block_quote`, `table`, …). Attach
/// its children afterward with `twig_builder_set_children`. A `kind` code that
/// names a payload-bearing kind (use that kind's own constructor) or is unknown
/// returns `invalid_argument`.
pub export fn twig_builder_add(b: ?*TwigBuilder, kind: c_int, out_id: ?*u32) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const node_kind = voidKind(kind) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(node_kind));
}

/// Add a single-string-payload inline/leaf node. `kind` must be one of the
/// string kinds (`str`, `symb`, `verbatim`, `inline_math`, `display_math`,
/// `url`, `email`, `footnote_reference`, `comment`, `doctype`, `cdata`); any
/// other code returns `invalid_argument`. The text is copied.
pub export fn twig_builder_add_text(
    b: ?*TwigBuilder,
    kind: c_int,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    const node_kind: twig.AST.Node.Kind = switch (kind) {
        @intFromEnum(TwigNodeKind.str) => .{ .str = text },
        @intFromEnum(TwigNodeKind.symb) => .{ .symb = text },
        @intFromEnum(TwigNodeKind.verbatim) => .{ .verbatim = text },
        @intFromEnum(TwigNodeKind.inline_math) => .{ .inline_math = text },
        @intFromEnum(TwigNodeKind.display_math) => .{ .display_math = text },
        @intFromEnum(TwigNodeKind.url) => .{ .url = text },
        @intFromEnum(TwigNodeKind.email) => .{ .email = text },
        @intFromEnum(TwigNodeKind.footnote_reference) => .{ .footnote_reference = text },
        @intFromEnum(TwigNodeKind.comment) => .{ .comment = text },
        @intFromEnum(TwigNodeKind.doctype) => .{ .doctype = text },
        @intFromEnum(TwigNodeKind.cdata) => .{ .cdata = text },
        else => return .invalid_argument,
    };
    return emitNode(out_id, handle.builder.addNode(node_kind));
}

pub export fn twig_builder_add_heading(b: ?*TwigBuilder, level: u32, out_id: ?*u32) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    return emitNode(out_id, handle.builder.addNode(.{ .heading = .{ .level = level } }));
}

/// Add a `code_block`. `has_lang == 0` means no info-string language (a NULL
/// `code_block.lang`); otherwise `lang_ptr[0..lang_len]` is the language. Both
/// strings are copied.
pub export fn twig_builder_add_code_block(
    b: ?*TwigBuilder,
    lang_ptr: ?[*]const u8,
    lang_len: usize,
    has_lang: c_int,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    const lang: ?[]const u8 = if (has_lang != 0) (sliceOf(lang_ptr, lang_len) orelse return .invalid_argument) else null;
    return emitNode(out_id, handle.builder.addNode(.{ .code_block = .{ .lang = lang, .text = text } }));
}

pub export fn twig_builder_add_raw_block(
    b: ?*TwigBuilder,
    format_ptr: ?[*]const u8,
    format_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const format = sliceOf(format_ptr, format_len) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .raw_block = .{ .format = format, .text = text } }));
}

pub export fn twig_builder_add_metadata(
    b: ?*TwigBuilder,
    lang_ptr: ?[*]const u8,
    lang_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const lang = sliceOf(lang_ptr, lang_len) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .metadata = .{ .lang = lang, .text = text } }));
}

pub export fn twig_builder_add_raw_inline(
    b: ?*TwigBuilder,
    format_ptr: ?[*]const u8,
    format_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const format = sliceOf(format_ptr, format_len) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .raw_inline = .{ .format = format, .text = text } }));
}

fn smartPunctOf(kind: c_int) ?twig.AST.SmartPunctuationKind {
    return switch (kind) {
        @intFromEnum(TwigSmartPunctuation.left_single_quote) => .left_single_quote,
        @intFromEnum(TwigSmartPunctuation.right_single_quote) => .right_single_quote,
        @intFromEnum(TwigSmartPunctuation.left_double_quote) => .left_double_quote,
        @intFromEnum(TwigSmartPunctuation.right_double_quote) => .right_double_quote,
        @intFromEnum(TwigSmartPunctuation.ellipses) => .ellipses,
        @intFromEnum(TwigSmartPunctuation.em_dash) => .em_dash,
        @intFromEnum(TwigSmartPunctuation.en_dash) => .en_dash,
        else => null,
    };
}

/// Add a `smart_punctuation` node. `punct_kind` is a `TwigSmartPunctuation`
/// code; `text` is the source spelling it stands for (e.g. `"---"` for an
/// em dash), copied.
pub export fn twig_builder_add_smart_punctuation(
    b: ?*TwigBuilder,
    punct_kind: c_int,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const pk = smartPunctOf(punct_kind) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .smart_punctuation = .{ .kind = pk, .text = text } }));
}

/// Add a `link`. `has_destination`/`has_reference` gate the two optional
/// fields (a NULL field when 0). Inline children (the link text) are attached
/// with `twig_builder_set_children`. Strings are copied.
pub export fn twig_builder_add_link(
    b: ?*TwigBuilder,
    dest_ptr: ?[*]const u8,
    dest_len: usize,
    has_destination: c_int,
    ref_ptr: ?[*]const u8,
    ref_len: usize,
    has_reference: c_int,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const dest: ?[]const u8 = if (has_destination != 0) (sliceOf(dest_ptr, dest_len) orelse return .invalid_argument) else null;
    const ref: ?[]const u8 = if (has_reference != 0) (sliceOf(ref_ptr, ref_len) orelse return .invalid_argument) else null;
    return emitNode(out_id, handle.builder.addNode(.{ .link = .{ .destination = dest, .reference = ref } }));
}

/// Add an `image` — like `twig_builder_add_link`, but the children are the alt
/// text.
pub export fn twig_builder_add_image(
    b: ?*TwigBuilder,
    dest_ptr: ?[*]const u8,
    dest_len: usize,
    has_destination: c_int,
    ref_ptr: ?[*]const u8,
    ref_len: usize,
    has_reference: c_int,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const dest: ?[]const u8 = if (has_destination != 0) (sliceOf(dest_ptr, dest_len) orelse return .invalid_argument) else null;
    const ref: ?[]const u8 = if (has_reference != 0) (sliceOf(ref_ptr, ref_len) orelse return .invalid_argument) else null;
    return emitNode(out_id, handle.builder.addNode(.{ .image = .{ .destination = dest, .reference = ref } }));
}

fn directiveFormOf(form: c_int) ?twig.AST.Form {
    return switch (form) {
        @intFromEnum(TwigDirectiveForm.text) => .inline_text,
        @intFromEnum(TwigDirectiveForm.leaf) => .block_leaf,
        @intFromEnum(TwigDirectiveForm.container) => .block_fenced,
        else => null,
    };
}

pub export fn twig_builder_add_directive(
    b: ?*TwigBuilder,
    form: c_int,
    name_ptr: ?[*]const u8,
    name_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const f = directiveFormOf(form) orelse return .invalid_argument;
    const name = sliceOf(name_ptr, name_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .container = .{ .form = f, .name = name } }));
}

pub export fn twig_builder_add_element(
    b: ?*TwigBuilder,
    name_ptr: ?[*]const u8,
    name_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const name = sliceOf(name_ptr, name_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .container = .{ .name = name } }));
}

pub export fn twig_builder_add_processing_instruction(
    b: ?*TwigBuilder,
    target_ptr: ?[*]const u8,
    target_len: usize,
    data_ptr: ?[*]const u8,
    data_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const target = sliceOf(target_ptr, target_len) orelse return .invalid_argument;
    const data = sliceOf(data_ptr, data_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .processing_instruction = .{ .target = target, .data = data } }));
}

pub export fn twig_builder_add_footnote(
    b: ?*TwigBuilder,
    label_ptr: ?[*]const u8,
    label_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const label = sliceOf(label_ptr, label_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .footnote = .{ .label = label } }));
}

pub export fn twig_builder_add_reference(
    b: ?*TwigBuilder,
    label_ptr: ?[*]const u8,
    label_len: usize,
    dest_ptr: ?[*]const u8,
    dest_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const label = sliceOf(label_ptr, label_len) orelse return .invalid_argument;
    const dest = sliceOf(dest_ptr, dest_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .reference = .{ .label = label, .destination = dest } }));
}

fn bulletStyleOf(style: c_int) ?twig.AST.BulletListStyle {
    return switch (style) {
        @intFromEnum(TwigBulletStyle.dash) => .dash,
        @intFromEnum(TwigBulletStyle.plus) => .plus,
        @intFromEnum(TwigBulletStyle.star) => .star,
        else => null,
    };
}

pub export fn twig_builder_add_bullet_list(
    b: ?*TwigBuilder,
    style: c_int,
    tight: c_int,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const s = bulletStyleOf(style) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .bullet_list = .{ .style = s, .tight = tight != 0 } }));
}

fn numberingOf(numbering: c_int) ?twig.AST.OrderedListStyle.Numbering {
    return switch (numbering) {
        @intFromEnum(TwigOrderedNumbering.decimal) => .decimal,
        @intFromEnum(TwigOrderedNumbering.lower_alpha) => .lower_alpha,
        @intFromEnum(TwigOrderedNumbering.upper_alpha) => .upper_alpha,
        @intFromEnum(TwigOrderedNumbering.lower_roman) => .lower_roman,
        @intFromEnum(TwigOrderedNumbering.upper_roman) => .upper_roman,
        else => null,
    };
}

fn delimOf(delim: c_int) ?twig.AST.OrderedListStyle.Delim {
    return switch (delim) {
        @intFromEnum(TwigOrderedDelim.period) => .period,
        @intFromEnum(TwigOrderedDelim.paren_after) => .paren_after,
        @intFromEnum(TwigOrderedDelim.paren_both) => .paren_both,
        else => null,
    };
}

/// Add an `ordered_list`. `has_start == 0` leaves the start number implicit (a
/// NULL `ordered_list.start`); otherwise `start` is the explicit first number.
pub export fn twig_builder_add_ordered_list(
    b: ?*TwigBuilder,
    numbering: c_int,
    delim: c_int,
    tight: c_int,
    start: u32,
    has_start: c_int,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const num = numberingOf(numbering) orelse return .invalid_argument;
    const del = delimOf(delim) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .ordered_list = .{
        .style = .{ .numbering = num, .delim = del },
        .tight = tight != 0,
        .start = if (has_start != 0) start else null,
    } }));
}

pub export fn twig_builder_add_task_list(b: ?*TwigBuilder, tight: c_int, out_id: ?*u32) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    return emitNode(out_id, handle.builder.addNode(.{ .task_list = .{ .tight = tight != 0 } }));
}

pub export fn twig_builder_add_task_list_item(b: ?*TwigBuilder, checked: c_int, out_id: ?*u32) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    return emitNode(out_id, handle.builder.addNode(.{ .task_list_item = .{ .checked = checked != 0 } }));
}

pub export fn twig_builder_add_row(b: ?*TwigBuilder, head: c_int, out_id: ?*u32) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    return emitNode(out_id, handle.builder.addNode(.{ .row = .{ .head = head != 0 } }));
}

fn alignmentOf(alignment: c_int) ?twig.AST.Alignment {
    return switch (alignment) {
        @intFromEnum(TwigAlignment.default) => .default,
        @intFromEnum(TwigAlignment.left) => .left,
        @intFromEnum(TwigAlignment.right) => .right,
        @intFromEnum(TwigAlignment.center) => .center,
        else => null,
    };
}

pub export fn twig_builder_add_cell(
    b: ?*TwigBuilder,
    head: c_int,
    alignment: c_int,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const a = alignmentOf(alignment) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .cell = .{ .head = head != 0, .alignment = a } }));
}

// ── structure & attributes ───────────────────────────────────────────────────

/// Set `parent`'s children to `ids` (in order), replacing any it had. Every id
/// — `parent` and each child — must name a node already added to this builder,
/// else `invalid_argument`. Each child id should appear in exactly one
/// `set_children` call across the whole build (a node has a single sibling
/// link); reusing one corrupts the tree.
pub export fn twig_builder_set_children(
    b: ?*TwigBuilder,
    parent: u32,
    ids_ptr: ?[*]const u32,
    ids_len: usize,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const count = handle.builder.nodes.items.len;
    if (parent >= count) return .invalid_argument;
    // u32 and Node.Id are the same type, so the C array is already the slice the
    // builder wants — no copy. Every id must name an existing node.
    const ids: []const u32 = if (ids_len == 0) &.{} else (ids_ptr orelse return .invalid_argument)[0..ids_len];
    for (ids) |id| if (id >= count) return .invalid_argument;
    handle.builder.setChildren(parent, ids);
    return .ok;
}

/// Attach `{...}` attributes to `id` (see `TwigKeyVal`), replacing any it had;
/// `kvs_len == 0` clears them. `id` must name an existing node. The keys/values
/// are copied.
pub export fn twig_builder_set_attrs(
    b: ?*TwigBuilder,
    id: u32,
    kvs_ptr: ?[*]const TwigKeyVal,
    kvs_len: usize,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    if (id >= handle.builder.nodes.items.len) return .invalid_argument;
    if (kvs_len == 0) {
        handle.builder.setAttrs(id, .{}) catch return .out_of_memory;
        return .ok;
    }
    const c_kvs = (kvs_ptr orelse return .invalid_argument)[0..kvs_len];
    const allocator = activeAllocator();
    // `setAttrs` copies each key/value into owned storage, so this decode array
    // (borrowing the caller's bytes) is only needed for the duration of the call.
    const entries = allocator.alloc(twig.AST.KeyVal, kvs_len) catch return .out_of_memory;
    defer allocator.free(entries);
    for (c_kvs, entries) |c, *e| {
        const key = sliceOf(c.key, c.key_len) orelse return .invalid_argument;
        const value: ?[]const u8 = if (c.value) |vp| vp[0..c.value_len] else null;
        e.* = .{ .key = key, .value = value };
    }
    handle.builder.setAttrs(id, .{ .entries = entries }) catch return .out_of_memory;
    return .ok;
}

// ── render / serialize / inspect the built tree ───────────────────────────────
// Each takes an explicit `root` id and operates on the subtree under it via a
// non-consuming `Builder.view`, so a build can be rendered/queried and then
// extended. Output buffers follow the borrowed-until-next-same-call contract.

/// Serialize a built `AST` (subtree rooted at the view's root) to `target`'s own
/// source syntax, always from a bare AST — a built tree has no djot/Markdown
/// side tables.
///
/// NOT routed through `twig.format.serializeFromAstAlloc`, and the reason is a
/// live bug rather than a design choice. The registry says XML has NO
/// `serializeFromAst`, because `xml/serializer.zig` handles only the
/// generic-markup kinds its own parser produces and `else => unreachable`s on
/// everything else. This function calls `Xml.serializeAlloc` directly anyway, so
/// `twig_builder_serialize(.., TWIG_FORMAT_XML)` over a tree holding any
/// semantic kind (a `heading`, a `link`) PANICS in a safe build rather than
/// returning the `unsupported_format` its caller's doc comment promises — the
/// `else =>` arm there can never fire, because `unreachable` is not an error.
/// `twig_document_serialize` refuses the same conversion correctly, which is how
/// the two copies of this dispatch came to disagree.
///
/// Switching to the registry would fix the panic but would also stop serializing
/// a purely generic-markup built tree (`element`/`comment`/...) into XML, which
/// works today and which nothing tests. That's a behaviour call, not a mechanical
/// one, so it is left exactly as it was — see the note in the refactor summary.
fn serializeBuiltAst(allocator: Allocator, ast: *const twig.AST, target: twig.Format) anyerror![]u8 {
    return switch (target) {
        .djot => twig.Djot.serializer.serializeAstAlloc(allocator, ast),
        .markdown => twig.Markdown.serializer.serializeAstAlloc(allocator, ast),
        .html => twig.Html.serializeAlloc(allocator, ast, null),
        .xml => twig.Xml.serializeAlloc(allocator, ast),
    };
}

/// Render the subtree rooted at `root` to HTML via the generic whole-vocabulary
/// printer (no djot/Markdown side tables — a built tree has none). Borrowed
/// output, valid until the next `twig_builder_render_html` on this handle or its
/// destruction.
pub export fn twig_builder_render_html(
    b: ?*TwigBuilder,
    root: u32,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    const allocator = activeAllocator();
    const ast = handle.builder.view(root);
    const rendered = twig.Html.serializeAlloc(allocator, &ast, null) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.UnsafeMetadata => return .unsafe_metadata,
    };

    if (handle.rendered.len != 0) allocator.free(handle.rendered);
    handle.rendered = rendered;

    ptr_out.* = if (rendered.len == 0) null else rendered.ptr;
    len_out.* = rendered.len;
    return .ok;
}

/// Serialize the subtree rooted at `root` to `format`'s source syntax.
/// `unsupported_format` when the target has no serializer for the built tree
/// (e.g. serializing semantic kinds into XML). Borrowed output, valid until the
/// next `twig_builder_serialize` on this handle or its destruction.
pub export fn twig_builder_serialize(
    b: ?*TwigBuilder,
    root: u32,
    format: c_int,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    const allocator = activeAllocator();
    const ast = handle.builder.view(root);
    const serialized = serializeBuiltAst(allocator, &ast, target) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.UnsafeMetadata => return .unsafe_metadata,
        // Any other serializer error means the built tree can't be represented
        // in the target format (e.g. XML's shape requirements).
        else => return .unsupported_format,
    };

    if (handle.serialized.len != 0) allocator.free(handle.serialized);
    handle.serialized = serialized;

    ptr_out.* = if (serialized.len == 0) null else serialized.ptr;
    len_out.* = serialized.len;
    return .ok;
}

/// Encode the subtree rooted at `root` as pretty-printed JSON (the same stable
/// encoding as `twig_document_ast_json`). Borrowed output, valid until the next
/// `twig_builder_ast_json` on this handle or its destruction.
pub export fn twig_builder_ast_json(
    b: ?*TwigBuilder,
    root: u32,
    out_ptr: ?*?[*]const u8,
    out_len: ?*usize,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    const allocator = activeAllocator();
    const ast = handle.builder.view(root);
    const json = twig.ast_json.encodeAlloc(allocator, &ast) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
    };

    if (handle.ast_json.len != 0) allocator.free(handle.ast_json);
    handle.ast_json = json;

    ptr_out.* = if (json.len == 0) null else json.ptr;
    len_out.* = json.len;
    return .ok;
}

/// Resolve a selector against the subtree rooted at `root`. Same grammar and
/// borrowed-output contract as `twig_document_query`; a malformed selector
/// returns `invalid_argument`.
pub export fn twig_builder_query(
    b: ?*TwigBuilder,
    root: u32,
    selector_ptr: ?[*]const u8,
    selector_len: usize,
    out_ptr: ?*?[*]const TwigQueryMatch,
    out_len: ?*usize,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const ptr_out = out_ptr orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const selector_src = sliceOf(selector_ptr, selector_len) orelse return .invalid_argument;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    const allocator = activeAllocator();
    const ast = handle.builder.view(root);
    const out = buildQueryMatches(allocator, &ast, selector_src) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidSelector => return .invalid_argument,
    };

    if (handle.query_matches.len != 0) allocator.free(handle.query_matches);
    handle.query_matches = out;

    ptr_out.* = if (out.len == 0) null else out.ptr;
    len_out.* = out.len;
    return .ok;
}

test "twig_parse + twig_document_render_html renders markdown" {
    const source = "# hi\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_document_render_html(doc, &ptr, &len));
    try std.testing.expectEqualStrings("<h1>hi</h1>\n", ptr.?[0..len]);
}

test "twig_parse accepts HTML input" {
    const source = "<p>hi</p>";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.html), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_document_render_html(doc, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "hi") != null);
}

test "twig_parse_ext with TWIG_MD_HTML_ELEMENTS makes an embedded <img> queryable" {
    // The read-path payoff of the flag: without it the `<img>` is opaque raw
    // HTML (no `image` node to match); with it, `twig_document_query` finds it.
    const source = "text <img src=\"a.png\" alt=\"x\"> more\n";

    inline for (.{ .{ @as(u32, 0), @as(usize, 0) }, .{ TWIG_MD_HTML_ELEMENTS, @as(usize, 1) } }) |case| {
        var doc: ?*TwigDocument = null;
        try std.testing.expectEqual(
            TwigStatus.ok,
            twig_parse_ext(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), case[0], &doc),
        );
        defer twig_document_destroy(doc);

        const selector = "image";
        var ptr: ?[*]const TwigQueryMatch = null;
        var len: usize = 0;
        try std.testing.expectEqual(
            TwigStatus.ok,
            twig_document_query(doc, selector.ptr, selector.len, &ptr, &len),
        );
        try std.testing.expectEqual(case[1], len);
    }
}

test "twig_editor_nodes exposes an element's name and attributes" {
    // The `<picture>` case: a `<source>` carries its theme selection entirely in
    // attributes (`media`/`srcset`) the flat snapshot must now surface — `kind`
    // is just "element" for both `<picture>` and `<source>`.
    const source =
        "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"d.svg\"><img src=\"l.svg\" alt=\"x\"></picture>\n";
    var ed: ?*TwigEditor = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_create_ext(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), TWIG_MD_HTML_ELEMENTS, &ed),
    );
    defer twig_editor_destroy(ed);

    var ptr: ?[*]const TwigFlatNode = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(ed, &ptr, &len));
    const nodes = ptr.?[0..len];

    // Find the `<source>` by its now-exposed element name.
    var source_node: ?*const TwigFlatNode = null;
    for (nodes) |*n| {
        if (n.name_ptr) |np| {
            if (std.mem.eql(u8, np[0..n.name_len], "source")) source_node = n;
        }
    }
    const src_el = source_node orelse return error.SourceElementMissing;

    // Its attributes are readable, in order, with the right values.
    const attrs = src_el.attrs_ptr.?[0..src_el.attrs_len];
    try std.testing.expectEqual(@as(usize, 2), attrs.len);
    try std.testing.expectEqualStrings("media", attrs[0].key.?[0..attrs[0].key_len]);
    try std.testing.expectEqualStrings("(prefers-color-scheme: dark)", attrs[0].value.?[0..attrs[0].value_len]);
    try std.testing.expectEqualStrings("srcset", attrs[1].key.?[0..attrs[1].key_len]);
    try std.testing.expectEqualStrings("d.svg", attrs[1].value.?[0..attrs[1].value_len]);

    // A plain `str`/`image` node carries no element name.
    for (nodes) |*n| {
        if (std.mem.orderZ(u8, n.kind, "str") == .eq) try std.testing.expect(n.name_ptr == null);
    }
}

test "twig_parse rejects an unknown format code" {
    const source = "x";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_parse(source.ptr, source.len, 99, &doc),
    );
    try std.testing.expectEqual(@as(?*TwigDocument, null), doc);
}

test "twig_document_serialize round-trips markdown and rejects xml-target cross-conversion" {
    const source = "# hi\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_document_serialize(doc, @intFromEnum(TwigFormat.markdown), &ptr, &len),
    );
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "# hi") != null);

    // Markdown -> XML has no serializer (see `serializeDocument`).
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_document_serialize(doc, @intFromEnum(TwigFormat.xml), &ptr, &len),
    );
}

test "twig_document_serialize cross-converts markdown to djot" {
    const source = "This is *markdown*.\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_document_serialize(doc, @intFromEnum(TwigFormat.djot), &ptr, &len),
    );
    // Markdown `*markdown*` (emphasis) renders djot-style with underscores.
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "_markdown_") != null);
}

test "twig_document_ast_json dumps the shared AST as JSON" {
    const source = "hello\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.djot), &doc),
    );
    defer twig_document_destroy(doc);

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_document_ast_json(doc, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "\"kind\": \"doc\"") != null);
}

test "twig_document_query finds nodes by selector and reports kind + spans" {
    const source = "See `x` and\n\n```\nblock\n```\n\nprose\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    // The inline code span (`verbatim`) recovers what the old code-span scan did.
    const selector = "verbatim";
    var ptr: ?[*]const TwigQueryMatch = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_document_query(doc, selector.ptr, selector.len, &ptr, &len),
    );
    try std.testing.expect(len == 1);

    const m = ptr.?[0];
    try std.testing.expectEqualStrings("verbatim", std.mem.span(m.kind));
    try std.testing.expect(m.span.start < m.span.end);
    // The matched span is `x`, not the surrounding prose.
    try std.testing.expect(!std.mem.containsAtLeast(u8, source[m.span.start..m.span.end], 1, "prose"));
}

test "twig_document_query rejects a malformed selector" {
    const source = "hi\n";
    var doc: ?*TwigDocument = null;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_parse(source.ptr, source.len, @intFromEnum(TwigFormat.markdown), &doc),
    );
    defer twig_document_destroy(doc);

    const bad = "list >";
    var ptr: ?[*]const TwigQueryMatch = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_document_query(doc, bad.ptr, bad.len, &ptr, &len),
    );
}

// ── editor tests ────────────────────────────────────────────────────────────
// XML is the vehicle (real spans + `content_span`, and the only language that
// can fail to parse — exercising rollback), matching `ast/splicer.zig`'s tests.

const EditorFixture = struct {
    ed: *TwigEditor,

    fn init(source: [:0]const u8) !EditorFixture {
        return initFmt(source, .xml);
    }

    fn initFmt(source: [:0]const u8, format: TwigFormat) !EditorFixture {
        var ed: ?*TwigEditor = null;
        try std.testing.expectEqual(
            TwigStatus.ok,
            twig_editor_create(source.ptr, source.len, @intFromEnum(format), &ed),
        );
        return .{ .ed = ed.? };
    }

    fn deinit(self: *EditorFixture) void {
        twig_editor_destroy(self.ed);
    }

    fn expectSource(self: *EditorFixture, expected: []const u8) !void {
        var ptr: ?[*]const u8 = null;
        var len: usize = 0;
        try std.testing.expectEqual(TwigStatus.ok, twig_editor_source(self.ed, &ptr, &len));
        try std.testing.expectEqualStrings(expected, if (len == 0) "" else ptr.?[0..len]);
    }
};

test "twig_editor: replace_content by index path, losslessly" {
    var fx = try EditorFixture.init("<a><b>hi</b></a>");
    defer fx.deinit();

    const path = "0.0";
    const text = "bye";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_replace_content(fx.ed, path.ptr, path.len, text.ptr, text.len),
    );
    try fx.expectSource("<a><b>bye</b></a>");
}

test "twig_editor: insert_child by index and delete" {
    var fx = try EditorFixture.init("<r><a/><c/></r>");
    defer fx.deinit();

    const root = "0";
    const b = "<b/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_child(fx.ed, root.ptr, root.len, 1, b.ptr, b.len),
    );
    try fx.expectSource("<r><a/><b/><c/></r>");

    // Delete the node now at path 0.1 (the freshly inserted <b/>).
    const b_path = "0.1";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_delete(fx.ed, b_path.ptr, b_path.len),
    );
    try fx.expectSource("<r><a/><c/></r>");
}

test "twig_editor: insert_before / insert_after" {
    var fx = try EditorFixture.init("<r><a/></r>");
    defer fx.deinit();

    const a = "0.0";
    const x = "<x/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_after(fx.ed, a.ptr, a.len, x.ptr, x.len),
    );
    try fx.expectSource("<r><a/><x/></r>");

    const a2 = "0.0";
    const y = "<y/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_before(fx.ed, a2.ptr, a2.len, y.ptr, y.len),
    );
    try fx.expectSource("<r><y/><a/><x/></r>");
}

test "twig_editor: a selector locator resolves and edits the target node" {
    var fx = try EditorFixture.initFmt("# One\n\n## Two\n", .markdown);
    defer fx.deinit();

    // Address the second heading by its text instead of a path. (`doc` also
    // contains "Two", but it isn't a `heading`, so the match is unambiguous.)
    const sel = "heading(\"Two\")";
    const text = "## Renamed";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_replace(fx.ed, sel.ptr, sel.len, text.ptr, text.len),
    );
    try fx.expectSource("# One\n\n## Renamed\n");
}

test "twig_editor: locator errors map to distinct statuses" {
    var fx = try EditorFixture.init("<r><a/><a/></r>");
    defer fx.deinit();

    const text = "x";

    // No node at this path.
    const oob = "0.9";
    try std.testing.expectEqual(
        TwigStatus.not_found,
        twig_editor_replace(fx.ed, oob.ptr, oob.len, text.ptr, text.len),
    );

    // Two <a> elements match -> ambiguous.
    const amb = "element";
    try std.testing.expectEqual(
        TwigStatus.ambiguous,
        twig_editor_replace(fx.ed, amb.ptr, amb.len, text.ptr, text.len),
    );

    // Malformed selector.
    const bad = "element(";
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_replace(fx.ed, bad.ptr, bad.len, text.ptr, text.len),
    );

    // Document is untouched by the failed edits.
    try fx.expectSource("<r><a/><a/></r>");
}

test "twig_editor: a reparse-breaking edit rolls back as edit_conflict" {
    var fx = try EditorFixture.init("<a>ok</a>");
    defer fx.deinit();

    // Replacing <a>'s interior with "<b>" makes `<a><b></a>` — malformed.
    const root = "0";
    const broken = "<b>";
    try std.testing.expectEqual(
        TwigStatus.edit_conflict,
        twig_editor_replace_content(fx.ed, root.ptr, root.len, broken.ptr, broken.len),
    );
    try fx.expectSource("<a>ok</a>");
}

test "twig_editor: replace_content on a leaf is not_editable" {
    var fx = try EditorFixture.init("<a>hi</a>");
    defer fx.deinit();

    // Path 0.0 is the "hi" text node, a leaf: no interior to splice.
    const leaf = "0.0";
    const text = "x";
    try std.testing.expectEqual(
        TwigStatus.not_editable,
        twig_editor_replace_content(fx.ed, leaf.ptr, leaf.len, text.ptr, text.len),
    );
}

test "twig_editor: ast_json and query reflect the current tree" {
    var fx = try EditorFixture.init("<r><a/></r>");
    defer fx.deinit();

    // Insert a second element, then confirm a query sees both.
    const root = "0";
    const b = "<b/>";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_child(fx.ed, root.ptr, root.len, 1, b.ptr, b.len),
    );

    // Three elements now: the root <r> plus <a/> and <b/>.
    const sel = "element";
    var qptr: ?[*]const TwigQueryMatch = null;
    var qlen: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_query(fx.ed, sel.ptr, sel.len, &qptr, &qlen),
    );
    try std.testing.expect(qlen == 3);

    var jptr: ?[*]const u8 = null;
    var jlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_ast_json(fx.ed, &jptr, &jlen));
    try std.testing.expect(std.mem.indexOf(u8, jptr.?[0..jlen], "\"kind\": \"doc\"") != null);
}

// ── toolbar tests ───────────────────────────────────────────────────────────
// The GESTURES are `twig.Editor`'s, and tested in `ast/editor_test.zig` — every
// escape alphabet, every autolink spelling, every quote-nesting rule. What is
// left to test here is this file's actual job: that a wire code decodes to the
// right kind, and that each Zig error surfaces as the right `TwigStatus`. So
// these are deliberately shallow — one per status, not one per behaviour.

fn toggleContainer(fx: *EditorFixture, start: usize, end: usize, kind: TwigBlockContainerKind) TwigStatus {
    return twig_editor_toggle_block_container(fx.ed, start, end, @intFromEnum(kind), null);
}

test "toolbar: the wire codes reach the right gesture" {
    var fx = try EditorFixture.initFmt("a\n", .djot);
    defer fx.deinit();

    // Each of these is a different `c_int` decode path landing on a different
    // `twig.Editor` method.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 0, 1, .block_quote));
    try fx.expectSource("> a\n");

    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_toggle_inline(fx.ed, 2, 3, @intFromEnum(TwigInlineKind.strong), null),
    );
    try fx.expectSource("> *a*\n");

    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_set_block(fx.ed, 3, @intFromEnum(TwigBlockKind.heading), 2, null),
    );
    try fx.expectSource("> ## *a*\n");

    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_link(fx.ed, 6, 7, "x.dev", 5, null),
    );
    try fx.expectSource("> ## *[a](x.dev)*\n");
}

test "insert_image: the wire reaches the gesture and escapes for the format" {
    var fx = try EditorFixture.initFmt("w\n", .markdown);
    defer fx.deinit();
    // A space in the destination is what a caller cannot spell; the op moves it
    // into Markdown's angle form.
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_image(fx.ed, 0, 1, "my cat.png", 10, null),
    );
    try fx.expectSource("![w](<my cat.png>)\n");

    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_insert_image(null, 0, 0, "x.png", 5, null),
    );

    var xml = try EditorFixture.init("<a>hi</a>");
    defer xml.deinit();
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_editor_insert_image(xml.ed, 3, 5, "x.png", 5, null),
    );
}

test "insert_literal: the wire reaches the gesture and escapes for the format" {
    var fx = try EditorFixture.initFmt("z\n", .markdown);
    defer fx.deinit();
    // A typed `*` at a line start would open emphasis; the op escapes it.
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_literal(fx.ed, 0, "*hi*", 4, null),
    );
    try fx.expectSource("\\*hi\\*z\n");

    // A parse-only format spells no literal.
    var xml = try EditorFixture.init("<a>hi</a>");
    defer xml.deinit();
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_editor_insert_literal(xml.ed, 3, "x", 1, null),
    );
    // An out-of-range offset is invalid_argument.
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_insert_literal(fx.ed, 999, "x", 1, null),
    );
}

test "insert_line_break: the wire splices an in-cell <br>, refuses off-cell and off-format" {
    var fx = try EditorFixture.initFmt("| a | b |\n| --- | --- |\n", .markdown);
    defer fx.deinit();
    // Caret just after `a` in the header cell.
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_insert_line_break(fx.ed, 3, null),
    );
    try fx.expectSource("| a<br> | b |\n| --- | --- |\n");

    // Not inside a cell → not_found (maps from NoBlock).
    var para = try EditorFixture.initFmt("just text\n", .markdown);
    defer para.deinit();
    try std.testing.expectEqual(
        TwigStatus.not_found,
        twig_editor_insert_line_break(para.ed, 3, null),
    );

    // Djot has no in-cell break spelling → unsupported_format.
    var dj = try EditorFixture.initFmt("| a | b |\n| --- | --- |\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_editor_insert_line_break(dj.ed, 3, null),
    );

    // Out-of-range offset is invalid_argument.
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_insert_line_break(fx.ed, 9999, null),
    );
}

test "toolbar: out_change reports the byte effect of a gesture" {
    var fx = try EditorFixture.initFmt("a\n", .djot);
    defer fx.deinit();

    var change: TwigChange = undefined;
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_editor_wrap_range(fx.ed, 0, 1, @intFromEnum(TwigInlineKind.emph), &change),
    );
    try fx.expectSource("_a_\n");
    // `a` [0,1) became `_a_` [0,3).
    try std.testing.expectEqual(@as(usize, 0), change.old.start);
    try std.testing.expectEqual(@as(usize, 1), change.old.end);
    try std.testing.expectEqual(@as(usize, 0), change.new.start);
    try std.testing.expectEqual(@as(usize, 3), change.new.end);
}

test "toolbar: every Editor error maps to its own status" {
    var dj = try EditorFixture.initFmt("see <https://x.dev> ok\n", .djot);
    defer dj.deinit();

    // NotEditable: a selection running from text into the middle of a URL.
    try std.testing.expectEqual(
        TwigStatus.not_editable,
        twig_editor_insert_link(dj.ed, 0, 10, "y.dev", 5, null),
    );
    // InvalidDestination -> invalid_argument.
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_insert_link(dj.ed, 0, 3, "a\nb", 3, null),
    );
    // InvalidRange -> invalid_argument.
    try std.testing.expectEqual(TwigStatus.invalid_argument, toggleContainer(&dj, 1, 0, .block_quote));
    try std.testing.expectEqual(TwigStatus.invalid_argument, toggleContainer(&dj, 0, 99, .block_quote));
    // InvalidLevel -> invalid_argument.
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_set_block(dj.ed, 0, @intFromEnum(TwigBlockKind.heading), 9, null),
    );
    // NoBlock -> not_found. (Offset 2 in `a\n\nb\n` is the blank separator.)
    var blank = try EditorFixture.initFmt("a\n\nb\n", .djot);
    defer blank.deinit();
    try std.testing.expectEqual(TwigStatus.not_found, toggleContainer(&blank, 2, 2, .block_quote));

    // UnsupportedFormat -> unsupported_format: XML spells none of these.
    var xml = try EditorFixture.init("<a>hi</a>");
    defer xml.deinit();
    try std.testing.expectEqual(TwigStatus.unsupported_format, toggleContainer(&xml, 3, 5, .block_quote));
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_editor_toggle_inline(xml.ed, 3, 5, @intFromEnum(TwigInlineKind.strong), null),
    );
    // …and Markdown, which spells `strong` but not `mark` — the same status from
    // a `null` one level deeper in the table.
    var md = try EditorFixture.initFmt("a word b\n", .markdown);
    defer md.deinit();
    try std.testing.expectEqual(
        TwigStatus.unsupported_format,
        twig_editor_toggle_inline(md.ed, 2, 6, @intFromEnum(TwigInlineKind.mark), null),
    );
}

test "toolbar: an unknown wire code is invalid_argument, never a wrong gesture" {
    var fx = try EditorFixture.initFmt("a\n", .djot);
    defer fx.deinit();
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_toggle_block_container(fx.ed, 0, 1, 99, null),
    );
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_toggle_inline(fx.ed, 0, 1, 99, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_wrap_range(fx.ed, 0, 1, -1, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_set_block(fx.ed, 0, 99, 1, null));
    try fx.expectSource("a\n");
}

test "toolbar: a NULL editor is invalid_argument on every gesture" {
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_wrap_range(null, 0, 0, 0, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_toggle_inline(null, 0, 0, 0, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_set_block(null, 0, 0, 1, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_toggle_block_container(null, 0, 0, 0, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_insert_link(null, 0, 0, "x", 1, null));
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_editor_insert_literal(null, 0, "x", 1, null));
}

// ── builder tests ─────────────────────────────────────────────────────────────

/// Add a node, asserting success, and return its id.
fn bAdd(b: *TwigBuilder, kind: TwigNodeKind) !u32 {
    var id: u32 = undefined;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_add(b, @intFromEnum(kind), &id));
    return id;
}

fn bAddText(b: *TwigBuilder, kind: TwigNodeKind, text: []const u8) !u32 {
    var id: u32 = undefined;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_add_text(b, @intFromEnum(kind), text.ptr, text.len, &id));
    return id;
}

fn bSetChildren(b: *TwigBuilder, parent: u32, ids: []const u32) !void {
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_set_children(b, parent, ids.ptr, ids.len));
}

test "twig_builder: build a small doc and render/serialize/query/dump it" {
    var b: ?*TwigBuilder = null;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_create(&b));
    defer twig_builder_destroy(b);
    const bld = b.?;

    // # Title\n\nhello *world*
    const title_text = try bAddText(bld, .str, "Title");
    var heading: u32 = undefined;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_add_heading(bld, 1, &heading));
    try bSetChildren(bld, heading, &.{title_text});

    const hello = try bAddText(bld, .str, "hello ");
    const world = try bAddText(bld, .str, "world");
    const emph = try bAdd(bld, .emph);
    try bSetChildren(bld, emph, &.{world});
    const para = try bAdd(bld, .para);
    try bSetChildren(bld, para, &.{ hello, emph });

    const doc = try bAdd(bld, .doc);
    try bSetChildren(bld, doc, &.{ heading, para });

    // Render to HTML via the generic printer.
    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_render_html(bld, doc, &ptr, &len));
    const html = ptr.?[0..len];
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<em>world</em>") != null);

    // Serialize to Markdown.
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_builder_serialize(bld, doc, @intFromEnum(TwigFormat.markdown), &ptr, &len),
    );
    const md = ptr.?[0..len];
    try std.testing.expect(std.mem.indexOf(u8, md, "# Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "*world*") != null);

    // Query the built subtree.
    var qptr: ?[*]const TwigQueryMatch = null;
    var qlen: usize = 0;
    const sel = "heading";
    try std.testing.expectEqual(
        TwigStatus.ok,
        twig_builder_query(bld, doc, sel.ptr, sel.len, &qptr, &qlen),
    );
    try std.testing.expect(qlen == 1);
    try std.testing.expectEqualStrings("heading", std.mem.span(qptr.?[0].kind));

    // AST JSON dump.
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_ast_json(bld, doc, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr.?[0..len], "\"kind\": \"doc\"") != null);
}

test "twig_builder: element with attributes renders as an HTML tag" {
    var b: ?*TwigBuilder = null;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_create(&b));
    defer twig_builder_destroy(b);
    const bld = b.?;

    const inner = try bAddText(bld, .str, "hi");
    var div: u32 = undefined;
    const name = "section";
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_add_element(bld, name.ptr, name.len, &div));
    try bSetChildren(bld, div, &.{inner});

    // class="note" plus a bare (valueless) attribute `hidden`.
    const kvs = [_]TwigKeyVal{
        .{ .key = "class", .key_len = 5, .value = "note", .value_len = 4 },
        .{ .key = "hidden", .key_len = 6, .value = null, .value_len = 0 },
    };
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_set_attrs(bld, div, &kvs, kvs.len));

    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_render_html(bld, div, &ptr, &len));
    const html = ptr.?[0..len];
    try std.testing.expect(std.mem.indexOf(u8, html, "<section") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hidden") != null);
}

test "twig_builder: invalid kind codes and out-of-range ids are rejected" {
    var b: ?*TwigBuilder = null;
    try std.testing.expectEqual(TwigStatus.ok, twig_builder_create(&b));
    defer twig_builder_destroy(b);
    const bld = b.?;

    var id: u32 = undefined;
    // `heading` carries a payload — not selectable via the void-kind `add`.
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_builder_add(bld, @intFromEnum(TwigNodeKind.heading), &id),
    );
    // `para` is void, not a string kind — not selectable via `add_text`.
    const t = "x";
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_builder_add_text(bld, @intFromEnum(TwigNodeKind.para), t.ptr, t.len, &id),
    );
    // A completely unknown code.
    try std.testing.expectEqual(TwigStatus.invalid_argument, twig_builder_add(bld, 9999, &id));

    // set_children with a child id that doesn't exist yet.
    const p = try bAdd(bld, .para);
    const bogus = [_]u32{4242};
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_builder_set_children(bld, p, &bogus, bogus.len),
    );
    // A root id past the end can't be rendered.
    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_builder_render_html(bld, 4242, &ptr, &len),
    );
}
