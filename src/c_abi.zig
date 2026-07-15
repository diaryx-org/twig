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
/// meaningful when `has_content_span` is non-zero (a leaf, or a container the
/// parser left without a known interior, reports `has_content_span == 0` and
/// a zeroed `content_span`). `kind` is a NUL-terminated `Node.Kind` tag name
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

/// The byte-level effect of an edit, C-ABI shape of `twig.Editor.Change`.
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

pub const TwigDocument = opaque {};

const ParsedDocument = union(TwigFormat) {
    djot: twig.Djot.Document,
    markdown: twig.Markdown.Document,
    xml: twig.AST,
    html: twig.AST,

    fn deinit(self: *ParsedDocument) void {
        switch (self.*) {
            .djot => |*doc| doc.deinit(),
            .markdown => |*doc| doc.deinit(),
            .xml => |*ast| ast.deinit(),
            .html => |*ast| ast.deinit(),
        }
    }
};

/// A parsed document plus the caller-borrowed output buffers each accessor
/// caches on it. Every buffer follows the same contract: it is owned by the
/// handle, replaced on the next call to the same accessor, and freed when the
/// handle is destroyed — so a pointer handed out stays valid until the next
/// same-accessor call on this handle or `twig_document_destroy`, whichever
/// comes first. The buffers are independent: rendering HTML never invalidates
/// a serialize/ast-json/query result and vice versa.
const DocumentHandle = struct {
    parsed: ParsedDocument,
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

/// Map a raw `int` format code to a `TwigFormat`, or `null` if it names no
/// known format (the caller turns that into `unsupported_format`).
fn intToFormat(format: c_int) ?TwigFormat {
    return switch (format) {
        @intFromEnum(TwigFormat.djot) => .djot,
        @intFromEnum(TwigFormat.markdown) => .markdown,
        @intFromEnum(TwigFormat.xml) => .xml,
        @intFromEnum(TwigFormat.html) => .html,
        else => null,
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
pub const TWIG_ABI_VERSION: u32 = 2;

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

        assert(@sizeOf(TwigFlatNode) == 104);
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
    const out = out_doc orelse return .invalid_argument;
    out.* = null;
    const source = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const target = intToFormat(format) orelse return .unsupported_format;

    const allocator = activeAllocator();
    const parsed: ParsedDocument = switch (target) {
        .djot => .{
            .djot = twig.Djot.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
        .markdown => .{
            .markdown = twig.Markdown.parse(allocator, source, .{}) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
        .xml => .{
            .xml = twig.Xml.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
                else => return .parse_error,
            },
        },
        .html => .{
            .html = twig.Html.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return .out_of_memory,
            },
        },
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

/// The shared `AST` underlying a parsed document, regardless of which
/// language produced it — `Djot.Document`/`Markdown.Document` wrap it
/// alongside their own side tables, `Xml.parse`/`Html.parse` return it bare.
fn astOf(parsed: *const ParsedDocument) *const twig.AST {
    return switch (parsed.*) {
        .djot => |*doc| &doc.ast,
        .markdown => |*doc| &doc.ast,
        .xml => |*ast| ast,
        .html => |*ast| ast,
    };
}

fn renderHtml(allocator: Allocator, parsed: *const ParsedDocument) twig.Html.RenderAllocError![]u8 {
    return switch (parsed.*) {
        .djot => |*doc| twig.Djot.html.renderAlloc(allocator, doc, .{}),
        .markdown => |*doc| twig.Markdown.html.renderAlloc(allocator, doc, .{}),
        .xml => |*ast| twig.Html.serializeAlloc(allocator, ast, null),
        .html => |*ast| twig.Html.serializeAlloc(allocator, ast, null),
    };
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

    const rendered = renderHtml(allocator, &handle.parsed) catch |err| switch (err) {
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
    parsed: *const ParsedDocument,
    target: TwigFormat,
) twig.Html.RenderAllocError!?[]u8 {
    if (std.meta.activeTag(parsed.*) == target) {
        return switch (parsed.*) {
            .djot => |*doc| try twig.Djot.serializer.serializeAlloc(allocator, doc),
            .markdown => |*doc| try twig.Markdown.serializer.serializeAlloc(allocator, doc),
            .xml => |*ast| try twig.Xml.serializeAlloc(allocator, ast),
            .html => |*ast| try twig.Html.serializeAlloc(allocator, ast, null),
        };
    }

    const ast = astOf(parsed);
    return switch (target) {
        .djot => try twig.Djot.serializer.serializeAstAlloc(allocator, ast),
        .markdown => try twig.Markdown.serializer.serializeAstAlloc(allocator, ast),
        // The generic HTML printer renders the full shared vocabulary from a
        // bare AST, so cross-format-to-HTML works from any source (this is the
        // side-table-free path; `twig_document_render_html` is the richer
        // djot/Markdown HTML rendering).
        .html => try twig.Html.serializeAlloc(allocator, ast, null),
        // No cross-format serializer into XML — see this function's doc comment.
        .xml => null,
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

    const json = twig.ast_json.encodeAlloc(allocator, astOf(&handle.parsed)) catch |err| switch (err) {
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

    const out = buildQueryMatches(allocator, astOf(&handle.parsed), selector_src) catch |err| switch (err) {
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
// A separate handle from `TwigDocument`: the span-splice editor
// (`twig.Editor`) owns evolving source bytes plus a bare-AST reparse of them,
// where `TwigDocument` holds a one-shot parse with its language's side tables.
// Editing reparses after every successful edit, so node ids/paths are only
// valid against the tree *as of the last edit* — which is why every op here is
// addressed by a fresh locator string (an index path or a unique selector),
// resolved against the current tree, exactly like `twig edit`.

pub const TwigEditor = opaque {};

const EditorHandle = struct {
    editor: twig.Editor,
    /// The document's format — the reparse callback captures it, but the
    /// range-oriented ops (`wrap_range`/`toggle_inline`/`set_block`) also need
    /// it to pick format-specific delimiters, so it's kept explicitly.
    format: TwigFormat,
    /// The parse configuration the editor's reparse callback borrows (via
    /// `twig.Editor.ParseFn`'s `ctx`). Stored ON the handle so its address is
    /// stable for the handle's whole lifetime — the editor holds `&this`.
    parse_config: EditorParseConfig = .{},
    /// Caller-borrowed output buffers, same contract as `DocumentHandle`'s.
    ast_json: []u8 = &.{},
    query_matches: []TwigQueryMatch = &.{},
    /// The last `twig_editor_nodes` snapshot (P2).
    flat_nodes: []TwigFlatNode = &.{},
    /// The last `twig_editor_nodes_at` ancestor chain (P3). Independent of
    /// `query_matches` so a hit-test doesn't invalidate a prior query.
    ancestor_matches: []TwigQueryMatch = &.{},
};

fn asEditor(ed: *TwigEditor) *EditorHandle {
    return @ptrCast(@alignCast(ed));
}

/// The one edit each `twig_editor_*` op performs, dispatched by `applyEdit`
/// onto the matching `twig.Editor` method.
const EditOp = enum { replace, replace_content, insert_before, insert_after, insert_child, delete, delete_smart, unwrap };

// Per-format `source -> bare AST` reparse callbacks the editor drives. Djot and
// Markdown's `Document` side tables are irrelevant to editing (it only touches
// spans/structure), so these free those maps and hand back the bare `AST`;
// XML/HTML already parse to a bare `AST`. Mirrors `cli/format.zig`'s
// `parseToAst*` adapters.

/// Markdown extension bitmask accepted by `twig_editor_create_ext`
/// (`TWIG_MD_*` in `twig.h`); other formats ignore it.
const TWIG_MD_DIRECTIVES: u32 = 1 << 0;
const TWIG_MD_MATH: u32 = 1 << 1;

/// The editor reparse callback's opaque `ctx` (`twig.Editor.ParseFn`), carried
/// on each `EditorHandle` and forwarded to every reparse so an edited Markdown
/// document keeps the extension flags it was created with. Only the Markdown
/// adapter reads it; djot/xml/html ignore it.
const EditorParseConfig = struct { markdown: twig.Markdown.ParseOptions = .{} };

fn markdownOptionsFromFlags(flags: u32) twig.Markdown.ParseOptions {
    var opts: twig.Markdown.ParseOptions = .{};
    opts.directives = (flags & TWIG_MD_DIRECTIVES) != 0;
    opts.math = (flags & TWIG_MD_MATH) != 0;
    return opts;
}

fn parseToAstDjot(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    var doc = try twig.Djot.parse(allocator, source);
    doc.references.deinit(allocator);
    doc.auto_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.ast;
}

fn parseToAstMarkdown(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    const cfg: *const EditorParseConfig = @ptrCast(@alignCast(ctx));
    var doc = try twig.Markdown.parse(allocator, source, cfg.markdown);
    doc.link_references.deinit(allocator);
    doc.footnotes.deinit(allocator);
    return doc.ast;
}

fn parseToAstXml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    return twig.Xml.parse(allocator, source);
}

fn parseToAstHtml(ctx: *const anyopaque, allocator: Allocator, source: []const u8) anyerror!twig.AST {
    _ = ctx;
    return twig.Html.parse(allocator, source);
}

fn parseFnFor(format: TwigFormat) twig.Editor.ParseFn {
    return switch (format) {
        .djot => parseToAstDjot,
        .markdown => parseToAstMarkdown,
        .xml => parseToAstXml,
        .html => parseToAstHtml,
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
/// Markdown extensions (`TWIG_MD_DIRECTIVES`, `TWIG_MD_MATH`) to enable for a
/// Markdown parse (ignored for other formats). The editor reparses with the
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

    const allocator = activeAllocator();
    const handle = allocator.create(EditorHandle) catch return .out_of_memory;
    // Set the config BEFORE `Editor.init` (which reads it via the ctx pointer on
    // its initial parse); the editor stores `&handle.parse_config`, stable for
    // the handle's lifetime.
    handle.* = .{ .editor = undefined, .format = target, .parse_config = .{ .markdown = markdownOptionsFromFlags(md_flags) } };
    handle.editor = twig.Editor.init(allocator, source, &handle.parse_config, parseFnFor(target)) catch |err| {
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
    if (handle.ancestor_matches.len != 0) allocator.free(handle.ancestor_matches);
    handle.editor.deinit();
    allocator.destroy(handle);
}

const LocatorError = error{ OutOfMemory, InvalidLocator, NotFound, Ambiguous };

/// A locator is an index path when it's made only of digits and dots (so an
/// empty string — the root — counts); anything else is a selector. Mirrors the
/// CLI's `isIndexPath`.
fn isIndexPath(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c) and c != '.') return false;
    return true;
}

fn parsePath(allocator: Allocator, path_str: []const u8) LocatorError![]const usize {
    if (path_str.len == 0) return &.{};
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, path_str, '.');
    while (it.next()) |seg| {
        const n = std.fmt.parseInt(usize, seg, 10) catch return error.InvalidLocator;
        list.append(allocator, n) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Resolve a locator (index path or unique selector) to a single node id
/// against `ast`, mirroring the CLI's `resolveLocator` but reporting via
/// `LocatorError` instead of printing.
fn resolveLocator(allocator: Allocator, ast: *const twig.AST, locator: []const u8) LocatorError!twig.AST.Node.Id {
    if (isIndexPath(locator)) {
        const path = try parsePath(allocator, locator);
        defer if (path.len > 0) allocator.free(path);
        return ast.getIdByPath(path) catch return error.NotFound;
    }

    var selector = twig.Select.parse(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSelector => return error.InvalidLocator,
    };
    defer selector.deinit();

    const matches = try twig.Select.resolveAll(allocator, ast, &selector);
    defer allocator.free(matches);

    if (matches.len == 0) return error.NotFound;
    if (matches.len > 1) return error.Ambiguous;
    return matches[0].id;
}

/// Resolve `locator` against the editor's current tree and apply `op`. Every
/// failure maps to a status: a malformed locator to `invalid_argument`, a
/// resolvable-but-missing one to `not_found`/`ambiguous`, an uneditable target
/// to `not_editable`, and a reparse-breaking edit (rolled back) to
/// `edit_conflict`.
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
    const handle = asEditor(raw);

    const id = resolveLocator(allocator, handle.editor.astView(), locator) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.InvalidLocator => return .invalid_argument,
        error.NotFound => return .not_found,
        error.Ambiguous => return .ambiguous,
    };

    const result = switch (op) {
        .replace => handle.editor.replaceNodeById(id, text),
        .replace_content => handle.editor.replaceContentById(id, text),
        .insert_before => handle.editor.insertBeforeById(id, text),
        .insert_after => handle.editor.insertAfterById(id, text),
        .insert_child => handle.editor.insertChildById(id, child_index, text),
        .delete => handle.editor.deleteNodeById(id),
        .delete_smart => handle.editor.deleteNodeSmartById(id),
        .unwrap => handle.editor.unwrapNodeById(id),
    };
    result catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.NoNodeSpan, error.NoContentSpan => return .not_editable,
        // Any other error is the parser rejecting the edited document; the
        // editor already rolled the edit back.
        else => return .edit_conflict,
    };
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
    twig.Filter.apply(allocator, &handle.editor, .{
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

// ── Offset-addressed editing & read-back (P0–P3) ─────────────────────────────
// The rich-text-editor surface: a caret speaks byte offsets, not locator
// strings. `edit_range` is the raw splice (`Editor.replaceAtSpan`) a keystroke
// maps onto; `node_at`/`nodes_at` hit-test an offset back to nodes; `nodes`
// hands out the whole tree as a flat array so a renderer needn't parse JSON.

fn spanC(s: twig.Span) TwigSpan {
    return .{ .start = s.start, .end = s.end };
}

fn changeC(c: twig.Editor.Change) TwigChange {
    return .{ .old = spanC(c.old), .new = spanC(c.new) };
}

/// The node's static kind-tag name, matching `TwigQueryMatch.kind`.
fn kindName(node: *const twig.AST.Node) [*:0]const u8 {
    return @tagName(std.meta.activeTag(node.kind)).ptr;
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

    handle.editor.replaceAtSpan(twig.Span.init(start, end), text) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        // Any parse error means the edited document didn't reparse; it was
        // rolled back.
        else => return .edit_conflict,
    };
    if (out_change) |slot| slot.* = changeC(handle.editor.last_change.?);
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
    const change = asEditor(raw).editor.last_change orelse return .not_found;
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
    const change = (asEditor(raw).editor.undo() catch |err| switch (err) {
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
    const change = (asEditor(raw).editor.redo() catch |err| switch (err) {
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
    asEditor(raw).editor.coalesceLastUndo();
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
    for (nodes, 0..) |node, i| {
        const text = kindText(&node);
        const dest = kindDestination(&node);
        buf[i] = .{
            .id = @intCast(i),
            .parent = TWIG_NO_NODE, // filled in the parent pass below
            .first_child = node.first_child orelse TWIG_NO_NODE,
            .next_sibling = node.next_sibling orelse TWIG_NO_NODE,
            .span = spanC(node.span),
            .content_span = if (node.content_span) |cs| spanC(cs) else .{ .start = 0, .end = 0 },
            .has_content_span = if (node.content_span != null) 1 else 0,
            .level = kindLevel(&node),
            .kind = kindName(&node),
            .text_ptr = if (text) |t| t.ptr else null,
            .text_len = if (text) |t| t.len else 0,
            .destination_ptr = if (dest) |d| d.ptr else null,
            .destination_len = if (dest) |d| d.len else 0,
            .head = kindHead(&node),
            .alignment = kindAlignment(&node),
        };
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

    if (handle.flat_nodes.len != 0) allocator.free(handle.flat_nodes);
    handle.flat_nodes = buf;

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

    const found = deepestContaining(ast, offset, handle.editor.sourceBytes().len) orelse return .not_found;
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
    const deepest = deepestContaining(ast, offset, len) orelse {
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
        cur = childContaining(ast, cur, offset, len) orelse break;
        chain.append(allocator, flatMatch(ast, cur)) catch return .out_of_memory;
    }

    if (handle.ancestor_matches.len != 0) allocator.free(handle.ancestor_matches);
    handle.ancestor_matches = chain.toOwnedSlice(allocator) catch return .out_of_memory;
    ptr_out.* = handle.ancestor_matches.ptr;
    len_out.* = handle.ancestor_matches.len;
    return .ok;
}

/// True if `offset` falls in node span `s` (half-open), treating a whole-source
/// end position as inside, and an unset `(0,0)` span as containing nothing.
fn spanContains(s: twig.Span, offset: usize, source_len: usize) bool {
    if (s.start == 0 and s.end == 0) return false;
    if (offset == source_len) return offset >= s.start and s.end >= source_len;
    return offset >= s.start and offset < s.end;
}

/// The child of `id` whose span contains `offset` — the last such child, so an
/// offset on a boundary resolves into the later sibling. `null` if none.
fn childContaining(ast: *const twig.AST, id: twig.AST.Node.Id, offset: usize, source_len: usize) ?twig.AST.Node.Id {
    var found: ?twig.AST.Node.Id = null;
    var it = ast.children(id);
    while (it.next()) |child| {
        if (spanContains(child.span, offset, source_len)) found = child.id;
    }
    return found;
}

/// The deepest node containing `offset`, descending from the root. The root's
/// own span may be unset `(0,0)` (some parsers don't span the `doc` node); when
/// so, entry is the root's child that owns the offset, and descent continues
/// fully from there. `null` if no node covers the offset at all.
fn deepestContaining(ast: *const twig.AST, offset: usize, source_len: usize) ?twig.AST.Node.Id {
    var cur = ast.root;
    if (!spanContains(ast.nodes[cur].span, offset, source_len)) {
        cur = childContaining(ast, cur, offset, source_len) orelse return null;
    }
    while (childContaining(ast, cur, offset, source_len)) |child| cur = child;
    return cur;
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

// ── Range-oriented rich-text ops (the toolbar, P5) ───────────────────────────
// wrap_range / toggle_inline / set_block: a caret editor's Bold / Italic / Code
// buttons and its H1 / Body switch. The format-specific knowledge (which
// delimiters mark a `strong`, how a heading is spelled) lives HERE, at the
// boundary that knows the format; the `twig.Editor` engine stays language-
// agnostic (it's handed delimiter bytes and a `Node.Kind` tag).

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

const Delims = struct { open: []const u8, close: []const u8 };

/// The source delimiters that mark `kind` in `format`, or `null` when the
/// format has no lightweight spelling for it (Markdown has only strong / emph /
/// verbatim; XML and HTML have no lightweight inline markup at all). Values are
/// exactly what each format's serializer emits, so a wrap round-trips.
fn inlineDelims(format: TwigFormat, kind: TwigInlineKind) ?Delims {
    return switch (format) {
        .markdown => switch (kind) {
            .strong => .{ .open = "**", .close = "**" },
            .emph => .{ .open = "*", .close = "*" },
            .verbatim => .{ .open = "`", .close = "`" },
            else => null,
        },
        .djot => switch (kind) {
            .strong => .{ .open = "*", .close = "*" },
            .emph => .{ .open = "_", .close = "_" },
            .verbatim => .{ .open = "`", .close = "`" },
            .mark => .{ .open = "{=", .close = "=}" },
            .superscript => .{ .open = "^", .close = "^" },
            .subscript => .{ .open = "~", .close = "~" },
            .insert => .{ .open = "{+", .close = "+}" },
            .delete => .{ .open = "{-", .close = "-}" },
        },
        else => null,
    };
}

/// The `Node.Kind` tag an inline kind detects as, for `toggleInline`'s
/// "already marked?" test.
fn inlineKindTag(kind: TwigInlineKind) twig.Editor.KindTag {
    return switch (kind) {
        .strong => .strong,
        .emph => .emph,
        .verbatim => .verbatim,
        .mark => .mark,
        .superscript => .superscript,
        .subscript => .subscript,
        .insert => .insert,
        .delete => .delete,
    };
}

/// Wrap `[start, end)` of the source with `kind`'s delimiters — the
/// unconditional half of the inline toolbar (always adds a mark). `start <=
/// end <= ` source length, else `invalid_argument`; a kind the format can't
/// spell is `unsupported_format`; a reparse-breaking result rolls back to
/// `edit_conflict`. On success fills `out_change` if non-NULL.
pub export fn twig_editor_wrap_range(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    kind: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    if (start > end or end > handle.editor.sourceBytes().len) return .invalid_argument;
    const ik = inlineKindFromInt(kind) orelse return .invalid_argument;
    const d = inlineDelims(handle.format, ik) orelse return .unsupported_format;

    handle.editor.wrapRange(twig.Span.init(start, end), d.open, d.close) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .edit_conflict,
    };
    if (out_change) |slot| slot.* = changeC(handle.editor.last_change.?);
    return .ok;
}

/// Toggle `kind` over `[start, end)`: strip the mark if the range already *is*
/// a node of `kind` (its whole span or its interior), else wrap it — a rich
/// editor's Cmd-B. Same argument/format/rollback rules as
/// `twig_editor_wrap_range`; a matched-but-unrecoverable mark is `not_editable`.
pub export fn twig_editor_toggle_inline(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    kind: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    if (start > end or end > handle.editor.sourceBytes().len) return .invalid_argument;
    const ik = inlineKindFromInt(kind) orelse return .invalid_argument;
    const d = inlineDelims(handle.format, ik) orelse return .unsupported_format;

    handle.editor.toggleInline(twig.Span.init(start, end), inlineKindTag(ik), d.open, d.close) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.NoNodeSpan, error.NoContentSpan => return .not_editable,
        else => return .edit_conflict,
    };
    if (out_change) |slot| slot.* = changeC(handle.editor.last_change.?);
    return .ok;
}

/// The innermost `heading`/`para` block on the descent to `offset`, or `null`.
fn innermostBlock(ast: *const twig.AST, offset: usize, source_len: usize) ?twig.AST.Node.Id {
    var result: ?twig.AST.Node.Id = null;
    var cur = ast.root;
    while (true) {
        switch (std.meta.activeTag(ast.nodes[cur].kind)) {
            .heading, .para => result = cur,
            else => {},
        }
        cur = childContaining(ast, cur, offset, source_len) orelse break;
    }
    return result;
}

/// Convert the block at `offset` to `block_kind` (a `level`-N heading, or a
/// paragraph) by rewriting its leading marker while keeping its inline content
/// verbatim — the block half of the toolbar (H1 / Body). Works for Djot and
/// Markdown (both spell headings `#`…); other formats are `unsupported_format`.
/// `not_found` if no `heading`/`para` covers `offset`; `invalid_argument` for a
/// heading `level` outside 1–6 or an `offset` past the source.
pub export fn twig_editor_set_block(
    ed: ?*TwigEditor,
    offset: usize,
    block_kind: c_int,
    level: u32,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    switch (handle.format) {
        .markdown, .djot => {},
        else => return .unsupported_format,
    }
    const bk = blockKindFromInt(block_kind) orelse return .invalid_argument;
    if (bk == .heading and (level < 1 or level > 6)) return .invalid_argument;

    const src = handle.editor.sourceBytes();
    if (offset > src.len) return .invalid_argument;
    const ast = handle.editor.astView();
    const block = innermostBlock(ast, offset, src.len) orelse return .not_found;
    const node = ast.nodes[block];
    const cs = node.content_span orelse return .not_editable;
    const content = src[cs.start..cs.end];

    // Rewrite [block start, end-of-text): the leading `#`-marker region (a
    // heading) or nothing (a paragraph), plus the text — but NOT any trailing
    // newline the block span includes (Djot blocks do), so we don't fuse with
    // the next block. Rebuilding from `content_span` also collapses a setext
    // heading's underline line away for free.
    var end = node.span.end;
    if (end > node.span.start and src[end - 1] == '\n') end -= 1;
    if (end > node.span.start and src[end - 1] == '\r') end -= 1;

    const allocator = activeAllocator();
    const prefix_len: usize = if (bk == .heading) level + 1 else 0; // "#"*level + " "
    const buf = allocator.alloc(u8, prefix_len + content.len) catch return .out_of_memory;
    defer allocator.free(buf);
    if (bk == .heading) {
        @memset(buf[0..level], '#');
        buf[level] = ' ';
    }
    @memcpy(buf[prefix_len..], content);

    handle.editor.replaceAtSpan(twig.Span.init(node.span.start, end), buf) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .edit_conflict,
    };
    if (out_change) |slot| slot.* = changeC(handle.editor.last_change.?);
    return .ok;
}

// ── Block containers (quote / lists) ─────────────────────────────────────────
// `set_block` rewrites the leading marker of ONE block at one offset. A block
// container is a different animal: it prefixes EVERY line of a possibly
// multi-block range, it nests, and a list numbers its items — so it gets its own
// op rather than another `TwigBlockKind`. Everything below is line surgery over
// the covered blocks, spliced in one shot through `replaceAtSpan`; the format
// table lives here beside `inlineDelims`, and the engine stays language-agnostic.

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

/// The `Node.Kind` tag a container kind detects as.
fn containerKindTag(kind: TwigBlockContainerKind) twig.Editor.KindTag {
    return switch (kind) {
        .block_quote => .block_quote,
        .bullet_list => .bullet_list,
        .ordered_list => .ordered_list,
    };
}

/// How a format spells a container's per-line prefix. Blank fields mean "build
/// it per item" (an ordered list's ordinal) or "leave the line alone".
const ContainerSpelling = struct {
    /// Opens the container on the first line of each covered block.
    marker: []const u8,
    /// Holds a block's continuation lines inside the container.
    cont: []const u8,
    /// A blank line INSIDE the container. A blank line separates list items (it
    /// merely makes the list loose) but BREAKS a quote in two, so a quote has to
    /// mark its blanks and a list must not.
    blank: []const u8,
    /// The marker is a per-item ordinal (`1. `, `2. `…), built at emit time.
    numbered: bool = false,
};

/// The source prefixes that spell `kind` in `format`, or `null` when the format
/// has no line-prefixed spelling for block containers at all (XML and HTML mark
/// structure with elements, not line markers). Djot and Markdown happen to agree
/// on all three — `> ` (with a bare `>` carrying a quote across a blank line),
/// `- `, `1. `, and `> > ` to nest — but they are listed per format rather than
/// shared, because the agreement is a coincidence of these two formats and not a
/// property a third one would inherit (their link destinations already diverge;
/// see `writeLinkDestination`).
fn containerSpelling(format: TwigFormat, kind: TwigBlockContainerKind) ?ContainerSpelling {
    return switch (format) {
        .djot, .markdown => switch (kind) {
            .block_quote => .{ .marker = "> ", .cont = "> ", .blank = ">" },
            .bullet_list => .{ .marker = "- ", .cont = "  ", .blank = "" },
            .ordered_list => .{ .marker = "", .cont = "", .blank = "", .numbered = true },
        },
        else => null,
    };
}

/// True for a node whose children are blocks — the level a container op works
/// at. Everything else (a `para`, a `heading`) holds inlines.
fn isBlockParent(tag: twig.Editor.KindTag) bool {
    return switch (tag) {
        .doc, .block_quote, .list_item, .task_list_item, .div, .section => true,
        else => false,
    };
}

/// True for the three container kinds a toggle targets.
fn isBlockContainer(tag: twig.Editor.KindTag) bool {
    return switch (tag) {
        .block_quote, .bullet_list, .ordered_list => true,
        else => false,
    };
}

/// The start of the line `at` sits on.
fn lineStartAt(src: []const u8, at: usize) usize {
    var i = @min(at, src.len);
    while (i > 0 and src[i - 1] != '\n') i -= 1;
    return i;
}

/// One past the newline terminating the line `at` sits on (or `src.len` at an
/// unterminated last line).
fn lineEndAt(src: []const u8, at: usize) usize {
    var i = @min(at, src.len);
    while (i < src.len and src[i] != '\n') i += 1;
    return if (i < src.len) i + 1 else i;
}

/// `line` without its trailing `\r\n` / `\n`.
fn lineBody(line: []const u8) []const u8 {
    var e = line.len;
    if (e > 0 and line[e - 1] == '\n') e -= 1;
    if (e > 0 and line[e - 1] == '\r') e -= 1;
    return line[0..e];
}

/// Only spaces/tabs (or nothing) — a line that separates blocks.
fn isBlankLine(body: []const u8) bool {
    for (body) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// The chain of node ids from the root down to the deepest node containing
/// `offset` — the ancestor walk `toggle_block_container` detects containers with
/// (`Node` carries no parent link, so the chain is rebuilt by descending).
fn ancestorChain(
    allocator: Allocator,
    ast: *const twig.AST,
    offset: usize,
    source_len: usize,
    out: *std.ArrayList(twig.AST.Node.Id),
) !void {
    var cur = ast.root;
    try out.append(allocator, cur);
    while (childContaining(ast, cur, offset, source_len)) |child| {
        cur = child;
        try out.append(allocator, cur);
    }
}

/// The blocks `[start, end)` touches: sibling `first`…`last` under the nearest
/// ancestor whose children are blocks. You cannot quote half a paragraph, so a
/// container op always widens to whole blocks first.
const BlockRange = struct {
    first: twig.AST.Node.Id,
    last: twig.AST.Node.Id,
    /// The ancestor chain down to `start`, reused for container detection.
    chain: []const twig.AST.Node.Id,
};

/// Advance past one `>` quote marker — its optional indent, the `>`, and the one
/// optional space after it — or `null` if `line[i..]` doesn't start one.
fn skipQuoteMarker(line: []const u8, i: usize) ?usize {
    var j = i;
    var indent: usize = 0;
    while (j < line.len and line[j] == ' ' and indent < 3) : (indent += 1) j += 1;
    if (j >= line.len or line[j] != '>') return null;
    j += 1;
    if (j < line.len and line[j] == ' ') j += 1;
    return j;
}

/// The `[start, end)` of a list marker on `line` — `start` at the bullet/first
/// digit (so the indent before it stays put, keeping an enclosing container's
/// prefix intact) and `end` past the marker's trailing spaces. `null` if the
/// line doesn't open a list item.
fn listMarkerAt(line: []const u8) ?struct { start: usize, end: usize } {
    var j: usize = 0;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
    const start = j;
    if (j >= line.len) return null;
    if (line[j] == '-' or line[j] == '*' or line[j] == '+') {
        j += 1;
    } else {
        if (line[j] == '(') j += 1;
        var digits: usize = 0;
        while (j < line.len and line[j] >= '0' and line[j] <= '9') : (digits += 1) j += 1;
        if (digits == 0) return null;
        if (j >= line.len or (line[j] != '.' and line[j] != ')')) return null;
        j += 1;
    }
    // A marker must be followed by whitespace (or end the line): `-x` is a
    // paragraph starting with a hyphen, not a bullet.
    if (j < line.len and line[j] != ' ' and line[j] != '\n' and line[j] != '\r') return null;
    while (j < line.len and line[j] == ' ') j += 1;
    return .{ .start = start, .end = j };
}

const container_indent = " " ** 24;

/// Wrap every line of `[region_start, region_end)` in `kind`'s prefix, one item
/// per covered block. The lines already carry any enclosing container's prefix,
/// so prefixing at column 0 nests naturally (`> a` -> `> > a`).
fn buildContainerAdd(
    allocator: Allocator,
    src: []const u8,
    ast: *const twig.AST,
    blocks: BlockRange,
    region_start: usize,
    region_end: usize,
    sp: ContainerSpelling,
    out: *std.ArrayList(u8),
) !void {
    var ordinal: u32 = 1;
    var cont: []const u8 = sp.cont;
    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = lineEndAt(src, line_start);
        const line = src[line_start..line_end];
        const body = lineBody(line);

        if (isBlankLine(body)) {
            // A blank line inside the region: mark it for a quote (else the
            // quote ends here), leave it bare for a list (it separates items).
            if (sp.blank.len > 0) {
                try out.appendSlice(allocator, sp.blank);
                try out.appendSlice(allocator, line[body.len..]);
            } else {
                try out.appendSlice(allocator, line);
            }
            line_start = line_end;
            continue;
        }

        if (blockStartsOnLine(ast, blocks, line_start, line_end)) {
            var num_buf: [24]u8 = undefined;
            const marker = if (sp.numbered)
                std.fmt.bufPrint(&num_buf, "{d}. ", .{ordinal}) catch unreachable
            else
                sp.marker;
            if (sp.numbered) cont = container_indent[0..@min(marker.len, container_indent.len)];
            try out.appendSlice(allocator, marker);
            try out.appendSlice(allocator, line);
            ordinal += 1;
        } else {
            try out.appendSlice(allocator, cont);
            try out.appendSlice(allocator, line);
        }
        line_start = line_end;
    }
}

/// True if one of the covered blocks begins on `[line_start, line_end)` — the
/// test for "this line opens a new list item". Djot starts a quoted block at its
/// text (after `> `), Markdown at the line start; either way it lands on the
/// block's first line, which is all this asks.
fn blockStartsOnLine(
    ast: *const twig.AST,
    blocks: BlockRange,
    line_start: usize,
    line_end: usize,
) bool {
    var cur: ?twig.AST.Node.Id = blocks.first;
    while (cur) |id| {
        const s = ast.nodes[id].span.start;
        if (s >= line_start and s < line_end) return true;
        if (id == blocks.last) break;
        cur = ast.nodes[id].next_sibling;
    }
    return false;
}

/// Strip the quote marker `target` contributes from each of its lines, leaving
/// any outer quote levels untouched: `depth` is how many quotes enclose it, so
/// the marker removed is the `depth`-th + 1 on every line. That's what makes
/// toggling off a nested quote peel exactly one level (`> > a` -> `> a`).
fn buildQuoteStrip(
    allocator: Allocator,
    src: []const u8,
    region_start: usize,
    region_end: usize,
    depth: usize,
    out: *std.ArrayList(u8),
) !void {
    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = lineEndAt(src, line_start);
        const line = src[line_start..line_end];

        var keep: usize = 0;
        var d: usize = 0;
        while (d < depth) : (d += 1) keep = skipQuoteMarker(line, keep) orelse break;
        if (d == depth) {
            if (skipQuoteMarker(line, keep)) |after| {
                try out.appendSlice(allocator, line[0..keep]);
                try out.appendSlice(allocator, line[after..]);
                line_start = line_end;
                continue;
            }
        }
        // A line with no marker at this level (a lazy continuation) is already
        // outside the level being removed — pass it through untouched.
        try out.appendSlice(allocator, line);
        line_start = line_end;
    }
}

/// Rewrite the list `target`'s item markers: `new_marker` empty removes the list
/// (toggle off), otherwise it converts one list kind to the other in place. The
/// text before a marker (an enclosing quote's `> `, a nesting indent) is kept
/// verbatim; a block's continuation lines are re-indented to the new marker's
/// width so they stay attached to their item.
///
/// Removing a list has to keep its items separate BLOCKS: a tight `- a\n- b\n`
/// would strip to `a\nb\n`, which is one two-line paragraph, not two. So a blank
/// line is injected between items that had none — the structure the items had is
/// what survives, not their tightness.
fn buildListRewrite(
    allocator: Allocator,
    src: []const u8,
    ast: *const twig.AST,
    target: twig.AST.Node.Id,
    region_start: usize,
    region_end: usize,
    sp: ?ContainerSpelling,
    out: *std.ArrayList(u8),
) !void {
    var ordinal: u32 = 1;
    var old_width: usize = 0;
    var new_width: usize = 0;
    var seen_item = false;
    var last_blank = true;
    var line_start = region_start;
    while (line_start < region_end) {
        const line_end = lineEndAt(src, line_start);
        const line = src[line_start..line_end];
        const body = lineBody(line);

        if (isBlankLine(body)) {
            try out.appendSlice(allocator, line);
            last_blank = true;
            line_start = line_end;
            continue;
        }

        if (itemStartsOnLine(ast, target, line_start, line_end)) {
            // Only when the list is going away: a conversion keeps the items as
            // items, so it must not loosen a tight list.
            if (sp == null and seen_item and !last_blank) try out.append(allocator, '\n');
            const m = listMarkerAt(line) orelse {
                try out.appendSlice(allocator, line);
                line_start = line_end;
                continue;
            };
            var num_buf: [24]u8 = undefined;
            const marker: []const u8 = if (sp) |s|
                (if (s.numbered)
                    std.fmt.bufPrint(&num_buf, "{d}. ", .{ordinal}) catch unreachable
                else
                    s.marker)
            else
                "";
            try out.appendSlice(allocator, line[0..m.start]);
            try out.appendSlice(allocator, marker);
            try out.appendSlice(allocator, line[m.end..]);
            old_width = m.end - m.start;
            new_width = marker.len;
            ordinal += 1;
            seen_item = true;
            last_blank = false;
        } else {
            // A continuation line: swap the old marker's indent for the new
            // one's so the line stays inside its item.
            var j: usize = 0;
            while (j < line.len and j < old_width and line[j] == ' ') j += 1;
            try out.appendSlice(allocator, container_indent[0..@min(new_width, container_indent.len)]);
            try out.appendSlice(allocator, line[j..]);
            last_blank = false;
        }
        line_start = line_end;
    }
}

/// True if one of `list`'s items begins on `[line_start, line_end)`.
fn itemStartsOnLine(
    ast: *const twig.AST,
    list: twig.AST.Node.Id,
    line_start: usize,
    line_end: usize,
) bool {
    var it = ast.children(list);
    while (it.next()) |item| {
        const s = item.span.start;
        if (s >= line_start and s < line_end) return true;
    }
    return false;
}

/// Toggle a block container (quote / bullet list / ordered list) over the blocks
/// `[start, end)` covers. See `twig.h` for the full semantics; in short: the
/// already-in-container test walks the AST ancestors of `start` for a container
/// of `container_kind`, and the toggle turns OFF only when the range covers
/// every block that container holds — otherwise it turns ON, which is what makes
/// a partial selection inside a quote nest (`> >`) instead of dragging the
/// container's uncovered siblings out with it. Toggling a list kind while inside
/// the other list kind converts in place rather than nesting.
pub export fn twig_editor_toggle_block_container(
    ed: ?*TwigEditor,
    start: usize,
    end: usize,
    container_kind: c_int,
    out_change: ?*TwigChange,
) TwigStatus {
    const raw = ed orelse return .invalid_argument;
    const handle = asEditor(raw);
    if (start > end or end > handle.editor.sourceBytes().len) return .invalid_argument;
    const ck = blockContainerKindFromInt(container_kind) orelse return .invalid_argument;
    const sp = containerSpelling(handle.format, ck) orelse return .unsupported_format;

    const allocator = activeAllocator();
    const src = handle.editor.sourceBytes();
    const ast = handle.editor.astView();

    const blocks = coveredBlocks(allocator, ast, src, start, end) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .not_found,
    };
    defer allocator.free(blocks.chain);

    const region_start = lineStartAt(src, ast.nodes[blocks.first].span.start);
    const region_end = lineEndAt(src, ast.nodes[blocks.last].span.end -| 1);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // The toggle-off / convert / nest decision, all from the ancestor chain.
    if (innermostContainerIn(ast, blocks.chain, containerKindTag(ck))) |target| {
        if (containerFullyCovered(ast, src, target, region_start, region_end)) {
            const t = ast.nodes[target].span;
            // The container's own lines, not the range's: its span can reach
            // past the last covered block (a quote's trailing `>` line).
            const splice_start = lineStartAt(src, t.start);
            const splice_end = lineEndAt(src, t.end -| 1);
            switch (ck) {
                .block_quote => buildQuoteStrip(
                    allocator,
                    src,
                    splice_start,
                    splice_end,
                    quoteDepthAbove(ast, blocks.chain, target),
                    &out,
                ) catch return .out_of_memory,
                .bullet_list, .ordered_list => buildListRewrite(
                    allocator,
                    src,
                    ast,
                    target,
                    splice_start,
                    splice_end,
                    null,
                    &out,
                ) catch return .out_of_memory,
            }
            return commitSplice(handle, splice_start, splice_end, out.items, out_change);
        }
    }
    if (ck == .bullet_list or ck == .ordered_list) {
        const other: twig.Editor.KindTag = if (ck == .bullet_list) .ordered_list else .bullet_list;
        if (innermostContainerIn(ast, blocks.chain, other)) |target| {
            if (containerFullyCovered(ast, src, target, region_start, region_end)) {
                const t = ast.nodes[target].span;
                const splice_start = lineStartAt(src, t.start);
                const splice_end = lineEndAt(src, t.end -| 1);
                buildListRewrite(allocator, src, ast, target, splice_start, splice_end, sp, &out) catch
                    return .out_of_memory;
                return commitSplice(handle, splice_start, splice_end, out.items, out_change);
            }
        }
    }

    buildContainerAdd(allocator, src, ast, blocks, region_start, region_end, sp, &out) catch
        return .out_of_memory;
    return commitSplice(handle, region_start, region_end, out.items, out_change);
}

/// Splice rebuilt source in over `[start, end)`, mapping the editor's errors the
/// way the rest of the toolbar does.
fn commitSplice(
    handle: *EditorHandle,
    start: usize,
    end: usize,
    text: []const u8,
    out_change: ?*TwigChange,
) TwigStatus {
    handle.editor.replaceAtSpan(twig.Span.init(start, end), text) catch |err| switch (err) {
        error.OutOfMemory => return .out_of_memory,
        else => return .edit_conflict,
    };
    if (out_change) |slot| slot.* = changeC(handle.editor.last_change.?);
    return .ok;
}

/// True when the range's lines cover every block `target` holds — the condition
/// for toggling the container OFF rather than nesting inside it.
///
/// The test is "are all its blocks covered?", NOT "is its span inside the
/// region?": a container's span can run past its last block, because the blank
/// `>` line continuing a quote belongs to the quote and to no paragraph in it
/// (Djot spans `> > a\n>\n` as the inner quote, ending two bytes past its only
/// paragraph). Comparing spans there reads a fully-covered quote as partial and
/// nests forever.
fn containerFullyCovered(
    ast: *const twig.AST,
    src: []const u8,
    target: twig.AST.Node.Id,
    region_start: usize,
    region_end: usize,
) bool {
    const first = ast.nodes[target].first_child orelse return false;
    var last = first;
    var cur: ?twig.AST.Node.Id = first;
    while (cur) |c| {
        last = c;
        cur = ast.nodes[c].next_sibling;
    }
    const lo = lineStartAt(src, ast.nodes[first].span.start);
    const hi = lineEndAt(src, ast.nodes[last].span.end -| 1);
    return region_start <= lo and region_end >= hi;
}

/// The deepest node of `tag` on the ancestor chain — the "is the range already
/// in one of these?" test, answered from the AST rather than by sniffing the
/// source for a `>`; a `>` inside a code block or a verbatim run isn't a quote,
/// and the parser is the only thing that knows that.
fn innermostContainerIn(
    ast: *const twig.AST,
    chain: []const twig.AST.Node.Id,
    tag: twig.Editor.KindTag,
) ?twig.AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        if (std.meta.activeTag(ast.nodes[chain[i]].kind) == tag) return chain[i];
    }
    return null;
}

/// How many quotes enclose `target` on the chain — the number of `>` markers to
/// step over before the one that belongs to `target`.
fn quoteDepthAbove(
    ast: *const twig.AST,
    chain: []const twig.AST.Node.Id,
    target: twig.AST.Node.Id,
) usize {
    var depth: usize = 0;
    for (chain) |id| {
        if (id == target) break;
        if (std.meta.activeTag(ast.nodes[id].kind) == .block_quote) depth += 1;
    }
    return depth;
}

/// Resolve `[start, end)` to the sibling blocks it touches. `end` is pulled back
/// off a trailing newline first: a block's span stops at its text in Markdown, so
/// a selection ending on the line break would otherwise resolve above the block
/// and drag the whole document in.
fn coveredBlocks(
    allocator: Allocator,
    ast: *const twig.AST,
    src: []const u8,
    start: usize,
    end: usize,
) !BlockRange {
    var last_off = if (end > start) end - 1 else start;
    while (last_off > start and (src[last_off] == '\n' or src[last_off] == '\r')) last_off -= 1;

    var chain_a: std.ArrayList(twig.AST.Node.Id) = .empty;
    errdefer chain_a.deinit(allocator);
    try ancestorChain(allocator, ast, start, src.len, &chain_a);

    var chain_b: std.ArrayList(twig.AST.Node.Id) = .empty;
    defer chain_b.deinit(allocator);
    try ancestorChain(allocator, ast, last_off, src.len, &chain_b);

    var i: usize = 0;
    while (i + 1 < chain_a.items.len and i + 1 < chain_b.items.len and
        chain_a.items[i + 1] == chain_b.items[i + 1]) : (i += 1)
    {}
    // Climb to the nearest ancestor that holds blocks: the deepest shared node
    // may be an inline (a `str`), and a container wraps blocks, not words.
    var p = i;
    while (p > 0 and !isBlockParent(std.meta.activeTag(ast.nodes[chain_a.items[p]].kind))) p -= 1;

    if (p + 1 >= chain_a.items.len) return error.NoBlock;
    const first = chain_a.items[p + 1];
    const last = if (p + 1 < chain_b.items.len) chain_b.items[p + 1] else first;
    return .{
        .first = first,
        .last = last,
        .chain = try chain_a.toOwnedSlice(allocator),
    };
}

// ── Links ────────────────────────────────────────────────────────────────────
// `toggle_inline` can't spell a link: its delimiters are a fixed `(open, close)`
// pair, and a link's closing half carries a payload (`](dest)`). Hence a
// dedicated op with a destination argument — and with the escaping that payload
// needs.

/// Write `dest` into `out` spelled so `format` parses it back byte-for-byte.
///
/// This is the sharp edge of the whole op, and it is NOT one escape table:
///
///   * Markdown ends a destination at the first space — `[t](a b)` is not a
///     link at all, it is literal text — so a destination holding whitespace has
///     to move into the `<…>` form, where `<`/`>`/`\` are what need escaping.
///   * Djot takes spaces literally and gives `<…>` NO meaning: `[t](<a b>)`
///     links to the seven characters `<a b>`. Wrapping there would corrupt the
///     URL rather than protect it.
///
/// Both honour a backslash escape inside the destination, which is what keeps an
/// unbalanced `)` from closing the link early. Inside Markdown's `<…>` form the
/// parens need no escape — the destination ends at the `>` — so escaping them
/// there would put a literal backslash in the URL.
///
/// The parens are not the only byte that ends the scan, though, and the rest of
/// that set is per-format too: Markdown reads a `<` as the START of the angle
/// form even mid-destination (`[w](<)` is no link at all), while djot's
/// destination is still scanned for inline openers, so a `[` or a `` ` `` there
/// swallows the `)` into a bracket run or a verbatim span. Each of those is a
/// destination that silently stops being a link, which is the same class of bug
/// as the unbalanced paren.
///
/// Markdown also DECODES entity references in a destination, in both forms — an
/// `a&amp;b` handed in would come back out as `a&b` — so its `&` is escaped
/// whether or not the angle form is in play. That one corrupts the URL rather
/// than breaking the link, which is the quieter failure of the two. Djot has no
/// entities and leaves `&` alone.
fn writeLinkDestination(
    allocator: Allocator,
    format: TwigFormat,
    dest: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const angle = format == .markdown and std.mem.indexOfAny(u8, dest, " \t") != null;
    if (angle) try out.append(allocator, '<');
    const escapes: []const u8 = if (angle) "\\<>&" else switch (format) {
        .markdown => "\\()<&",
        .djot => "\\()[`",
        else => "\\()",
    };
    for (dest) |c| {
        if (std.mem.indexOfScalar(u8, escapes, c) != null) try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    if (angle) try out.append(allocator, '>');
}

/// Whether `angled` — a `<dest>` run, brackets included — spells an autolink,
/// asked of the format's OWN scanner (the one its parser dispatches on) rather
/// than re-derived here, so this cannot drift from what a reparse will see.
///
/// There is no shared rule to hoist: the formats genuinely disagree. Markdown
/// wants an absolute URI (a 2-32 character `scheme:`) or a CommonMark email,
/// and silently reads anything else as raw HTML (`<foo>` is a tag!) or literal
/// text. Djot classifies on content alone — an `@` not preceded by `:` is an
/// email, else a `letter:` is a url — which is why `mailto:a@b.dev` is a `url`
/// in Markdown but an `email` in djot. Both refuse a relative path.
fn spellsAutolink(format: TwigFormat, angled: []const u8) bool {
    return switch (format) {
        .markdown => twig.Markdown.spellsAutolink(angled),
        .djot => twig.Djot.autolinkKindOf(angled[1 .. angled.len - 1]) != null,
        else => false,
    };
}

/// The bytes a link's TEXT position must have backslash-escaped for the text to
/// reparse as the literal string handed in. Each one either opens a construct
/// that swallows the text — `*`/`_`/`` ` ``/`~`/`^` emphasis-ish runs, djot's
/// `{…}` attributes and `"`/`'`/`-`/`.`/`:` smart punctuation, Markdown's `<…>`
/// raw HTML and `&…;` entities — or breaks the brackets outright (`[`/`]`/`\`).
///
/// The sets differ because the metacharacters do: djot has attributes and no
/// entities, Markdown the reverse. Both read `\` + ASCII punctuation as that
/// literal character, so an escape here is always safe, never a stray backslash.
///
/// This is NOT `writeLinkDestination`'s set: that one guards the `(…)` position,
/// where parens end the destination and emphasis means nothing.
fn linkTextEscapes(format: TwigFormat) []const u8 {
    return switch (format) {
        .markdown => "\\[]*_^`~<>&",
        .djot => "\\[]*_^`~\"'-.:{}",
        else => "",
    };
}

fn writeLinkText(
    allocator: Allocator,
    format: TwigFormat,
    text: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const escapes = linkTextEscapes(format);
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, escapes, c) != null) try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
}

/// The innermost `link` on the chain that wholly contains `[start, end)`.
fn linkCovering(
    ast: *const twig.AST,
    chain: []const twig.AST.Node.Id,
    start: usize,
    end: usize,
) ?twig.AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        const node = ast.nodes[chain[i]];
        if (std.meta.activeTag(node.kind) != .link) continue;
        if (node.span.start <= start and node.span.end >= end) return chain[i];
    }
    return null;
}

/// The innermost autolink — the `<https://x.dev>` / `<a@b.dev>` form — on the
/// chain. Callers pass a chain built at a CARET; see `twig_editor_insert_link`
/// for why a selection doesn't consult this.
///
/// Both node kinds are matched in both formats because the split is not the one
/// the names suggest — it follows the FORMAT, not just the destination.
/// `<mailto:a@b.dev>` parses as a `url` in Markdown and an `email` in djot, so
/// picking one kind per format would miss half the autolinks it was meant to
/// catch.
fn autolinkCovering(ast: *const twig.AST, chain: []const twig.AST.Node.Id) ?twig.AST.Node.Id {
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        switch (std.meta.activeTag(ast.nodes[chain[i]].kind)) {
            .url, .email => return chain[i],
            else => {},
        }
    }
    return null;
}

/// Link `[start, end)` to `destination`, or repoint the link already there.
///
/// Decisions, all visible in `twig.h`:
///   * An EXISTING link covering the range has its destination REPLACED, its
///     text kept. Re-linking is the common gesture (fix a URL), and it keeps the
///     op idempotent instead of nesting `[[t](a)](b)`. Removing a link is
///     already `twig_editor_unwrap`, which peels a node to its interior.
///   * A CARET in an existing autolink re-points it the same way, but there is
///     no text to keep: an autolink's text IS its destination, so the node is
///     respelled whole for the new one (canonically — see below — so a `<url>`
///     re-pointed at a relative path becomes `[dest](dest)`, not a broken `<>`).
///     Without this the op reads the URL as ordinary text and splices a link
///     into the middle of it: `<https<https://y.dev>://x.dev>`.
///
///     Only a caret, never a selection. A selection carries text of its own to
///     link, and can straddle the autolink's edges, where "re-point" means
///     nothing; a caret is the unambiguous gesture. And a caret inside BOTH
///     (`[<https://x.dev>](d)`) re-points the link, not the autolink: a link's
///     text is separable from its destination, so re-pointing it keeps text that
///     re-pointing the autolink would discard.
///   * A link with NO TEXT gets the canonical spelling for the destination it
///     was given, never `[](dest)`: a childless link has nothing to render, so
///     consumers fall back to showing the destination and the caret has nowhere
///     correct to sit. Where the format can spell an autolink it gets `<dest>`;
///     where it can't it gets `[dest](dest)`, the destination doubling as text
///     so it stays visible and editable. Which destinations autolink, and how
///     each format spells one, is twig's knowledge — a consumer guessing would
///     turn `<foo>` into raw HTML (Markdown) or literal text (both). See
///     `spellsAutolink`.
///   * A destination is escaped per format (see `writeLinkDestination`); a
///     newline in one is `invalid_argument`, since neither format can hold it
///     (Djot strips it, Markdown's `<…>` form forbids it) and silently changing
///     the caller's URL is worse than refusing.
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
    if (start > end or end > handle.editor.sourceBytes().len) return .invalid_argument;
    switch (handle.format) {
        .markdown, .djot => {},
        else => return .unsupported_format,
    }
    const dest = sliceOf(destination_ptr, destination_len) orelse return .invalid_argument;
    if (std.mem.indexOfAny(u8, dest, "\r\n") != null) return .invalid_argument;

    const allocator = activeAllocator();
    const src = handle.editor.sourceBytes();
    const ast = handle.editor.astView();

    var chain: std.ArrayList(twig.AST.Node.Id) = .empty;
    defer chain.deinit(allocator);
    ancestorChain(allocator, ast, start, src.len, &chain) catch return .out_of_memory;

    // The text to sit in the brackets, and the span the rebuilt link replaces.
    // Re-pointing an existing link rebuilds the whole node: a destination is a
    // string payload with no span of its own, so there is nothing smaller to
    // splice (see `ast/editor.zig`'s module doc).
    var text: []const u8 = src[start..end];
    var target = twig.Span.init(start, end);
    var repoint = linkCovering(ast, chain.items, start, end);
    if (repoint == null and start == end) repoint = autolinkCovering(ast, chain.items);
    if (repoint) |id| {
        const node = ast.nodes[id];
        if (node.span.start == 0 and node.span.end == 0) return .not_editable;
        // An autolink has no `[text]` half: the text it shows is the OLD
        // destination, so keeping it would spell the new link with the URL it
        // was meant to replace. Empty text sends it through the canonical
        // spelling below, exactly as a caret on bare text goes.
        text = switch (std.meta.activeTag(node.kind)) {
            .url, .email => "",
            else => if (node.content_span) |cs| src[cs.start..cs.end] else "",
        };
        target = node.span;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // Keyed on the TEXT being empty, not the range: re-pointing an existing
    // `[](old)` is an empty range too, and it has the same childless link to
    // avoid. A non-empty range always carries text, so it never lands here.
    if (text.len == 0) {
        out.append(allocator, '<') catch return .out_of_memory;
        out.appendSlice(allocator, dest) catch return .out_of_memory;
        out.append(allocator, '>') catch return .out_of_memory;
        // Ask about the exact bytes we would emit, so the test and the output
        // cannot disagree about what was spelled.
        if (spellsAutolink(handle.format, out.items))
            return commitSplice(handle, target.start, target.end, out.items, out_change);
        out.clearRetainingCapacity();
    }

    out.append(allocator, '[') catch return .out_of_memory;
    if (text.len == 0) {
        // `dest` is a raw string being repurposed as text, so it needs escaping
        // for that position — unlike `text`, which is already source the author
        // (or a prior parse) spelled and which must be copied through verbatim.
        writeLinkText(allocator, handle.format, dest, &out) catch return .out_of_memory;
    } else {
        out.appendSlice(allocator, text) catch return .out_of_memory;
    }
    out.appendSlice(allocator, "](") catch return .out_of_memory;
    writeLinkDestination(allocator, handle.format, dest, &out) catch return .out_of_memory;
    out.append(allocator, ')') catch return .out_of_memory;

    return commitSplice(handle, target.start, target.end, out.items, out_change);
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
        @intFromEnum(TwigNodeKind.div) => .div,
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
        @intFromEnum(TwigNodeKind.span) => .span,
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

fn directiveFormOf(form: c_int) ?twig.AST.DirectiveForm {
    return switch (form) {
        @intFromEnum(TwigDirectiveForm.text) => .text,
        @intFromEnum(TwigDirectiveForm.leaf) => .leaf,
        @intFromEnum(TwigDirectiveForm.container) => .container,
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
    return emitNode(out_id, handle.builder.addNode(.{ .directive = .{ .form = f, .name = name } }));
}

pub export fn twig_builder_add_element(
    b: ?*TwigBuilder,
    name_ptr: ?[*]const u8,
    name_len: usize,
    out_id: ?*u32,
) TwigStatus {
    const handle = asBuilder(b orelse return .invalid_argument);
    const name = sliceOf(name_ptr, name_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNode(.{ .element = .{ .name = name } }));
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
/// source syntax. Mirrors `serializeDocument`'s cross-format arm, but always
/// from a bare AST — a built tree has no djot/Markdown side tables. Any error is
/// mapped by the caller (OOM / unsafe-metadata / otherwise unsupported).
fn serializeBuiltAst(allocator: Allocator, ast: *const twig.AST, target: TwigFormat) anyerror![]u8 {
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
// can fail to parse — exercising rollback), matching `ast/editor.zig`'s tests.

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

// ── block-container tests ───────────────────────────────────────────────────
// Djot and Markdown both, because their spans differ in exactly the places this
// op reads them: Djot starts a quoted block AT its text (`> a` -> para at 2) and
// a nested quote at its own `>`, Markdown starts both at column 0 — so a rule
// derived from one format's spans silently breaks on the other.

fn toggleContainer(fx: *EditorFixture, start: usize, end: usize, kind: TwigBlockContainerKind) TwigStatus {
    return twig_editor_toggle_block_container(fx.ed, start, end, @intFromEnum(kind), null);
}

test "toggle_block_container: quote on, then off, round-trips (djot)" {
    var fx = try EditorFixture.initFmt("a\n", .djot);
    defer fx.deinit();

    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 0, 1, .block_quote));
    try fx.expectSource("> a\n");

    // "a" now sits at [2,3); the range covers the whole quote -> toggle off.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 3, .block_quote));
    try fx.expectSource("a\n");
}

test "toggle_block_container: quote on, then off, round-trips (markdown)" {
    var fx = try EditorFixture.initFmt("a\n", .markdown);
    defer fx.deinit();

    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 0, 1, .block_quote));
    try fx.expectSource("> a\n");
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 3, .block_quote));
    try fx.expectSource("a\n");
}

test "toggle_block_container: a multi-block range becomes one quote, blanks marked" {
    var fx = try EditorFixture.initFmt("a\n\nb\n", .djot);
    defer fx.deinit();

    // The blank line between the paragraphs must carry a `>` too, or the result
    // is two quotes instead of one.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 0, 4, .block_quote));
    try fx.expectSource("> a\n>\n> b\n");

    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 9, .block_quote));
    try fx.expectSource("a\n\nb\n");
}

test "toggle_block_container: quoting inside a quote nests, and off peels one level" {
    var fx = try EditorFixture.initFmt("> a\n>\n> b\n", .djot);
    defer fx.deinit();

    // Only the first paragraph is selected, so the enclosing quote is NOT fully
    // covered: the toggle nests rather than unquoting `b` along with it.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 3, .block_quote));
    try fx.expectSource("> > a\n>\n> b\n");

    // "a" is now at [4,5); toggling again peels the inner level only.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 4, 5, .block_quote));
    try fx.expectSource("> a\n>\n> b\n");
}

test "toggle_block_container: a nested quote peels one level (markdown)" {
    var fx = try EditorFixture.initFmt("> > a\n", .markdown);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 4, 5, .block_quote));
    try fx.expectSource("> a\n");
}

test "toggle_block_container: each covered block becomes its own list item" {
    var fx = try EditorFixture.initFmt("a\n\nb\n", .djot);
    defer fx.deinit();

    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 0, 4, .bullet_list));
    try fx.expectSource("- a\n\n- b\n");
}

test "toggle_block_container: an ordered list numbers a multi-item range" {
    var fx = try EditorFixture.initFmt("a\n\nb\n\nc\n", .djot);
    defer fx.deinit();

    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 0, 7, .ordered_list));
    try fx.expectSource("1. a\n\n2. b\n\n3. c\n");
}

test "toggle_block_container: unlisting keeps the items as separate blocks" {
    var fx = try EditorFixture.initFmt("- a\n- b\n", .djot);
    defer fx.deinit();

    // A tight list stripped to `a\nb\n` would be ONE paragraph; the blank line
    // is what keeps the two items two blocks.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 7, .bullet_list));
    try fx.expectSource("a\n\nb\n");
}

test "toggle_block_container: toggling the other list kind converts in place" {
    var fx = try EditorFixture.initFmt("- a\n- b\n", .djot);
    defer fx.deinit();

    // Not a nest (`1. - a`): a list asked to become the other list kind rewrites
    // its own markers.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 7, .ordered_list));
    try fx.expectSource("1. a\n2. b\n");

    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 3, 9, .bullet_list));
    try fx.expectSource("- a\n- b\n");
}

test "toggle_block_container: a list's continuation lines follow the new marker width" {
    var fx = try EditorFixture.initFmt("- a\n  b\n", .djot);
    defer fx.deinit();

    // `1. ` is a byte wider than `- `, so the second line has to re-indent or it
    // falls out of the item.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 2, 7, .ordered_list));
    try fx.expectSource("1. a\n   b\n");
}

test "toggle_block_container: a `>` inside a code block is not a quote" {
    var fx = try EditorFixture.initFmt("```\n> a\n```\n", .djot);
    defer fx.deinit();

    // The AST has no block_quote here — the `> a` is code_block TEXT. Detection
    // by string-matching the line prefix would "toggle off" a quote that was
    // never there and corrupt the code; the AST walk quotes the block instead.
    try std.testing.expectEqual(TwigStatus.ok, toggleContainer(&fx, 4, 7, .block_quote));
    try fx.expectSource("> ```\n> > a\n> ```\n");
}

test "toggle_block_container: a range covering no block is not_found" {
    var fx = try EditorFixture.initFmt("a\n\nb\n", .djot);
    defer fx.deinit();
    // Offset 2 is the blank line between the paragraphs: no block owns it.
    try std.testing.expectEqual(TwigStatus.not_found, toggleContainer(&fx, 2, 2, .block_quote));
}

test "toggle_block_container: rejects formats with no line-marker spelling" {
    var fx = try EditorFixture.init("<a>hi</a>");
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.unsupported_format, toggleContainer(&fx, 3, 5, .block_quote));
}

test "toggle_block_container: rejects a bad kind code and a bad range" {
    var fx = try EditorFixture.initFmt("a\n", .djot);
    defer fx.deinit();
    try std.testing.expectEqual(
        TwigStatus.invalid_argument,
        twig_editor_toggle_block_container(fx.ed, 0, 1, 99, null),
    );
    try std.testing.expectEqual(TwigStatus.invalid_argument, toggleContainer(&fx, 1, 0, .block_quote));
    try std.testing.expectEqual(TwigStatus.invalid_argument, toggleContainer(&fx, 0, 99, .block_quote));
}

// ── link tests ──────────────────────────────────────────────────────────────

fn insertLink(fx: *EditorFixture, start: usize, end: usize, dest: []const u8) TwigStatus {
    return twig_editor_insert_link(fx.ed, start, end, dest.ptr, dest.len, null);
}

/// The destination the parser reads back out of the EDITED source — the only
/// thing that proves an escape worked. Source that merely looks right can still
/// have ended the link early, leaving the tail as literal text.
fn expectLinkDest(fx: *EditorFixture, expected: []const u8) !void {
    var nptr: ?[*]const TwigFlatNode = null;
    var nlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(fx.ed, &nptr, &nlen));
    for (nptr.?[0..nlen]) |n| {
        if (!std.mem.eql(u8, std.mem.span(n.kind), "link")) continue;
        const dest = n.destination_ptr orelse return error.NoDestination;
        try std.testing.expectEqualStrings(expected, dest[0..n.destination_len]);
        return;
    }
    return error.NoLink;
}

test "insert_link wraps a range as link text" {
    var fx = try EditorFixture.initFmt("a word b\n", .djot);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 2, 6, "http://x.dev"));
    try fx.expectSource("a [word](http://x.dev) b\n");
}

/// The node KIND the parser reads back out of the EDITED source, with its
/// payload (a `link`'s destination, an autolink's text). Kind is the whole
/// point here: `<foo>` and `[foo](foo)` both "look like" a link in the source
/// but reparse as raw HTML and a link respectively.
fn expectSpelled(fx: *EditorFixture, kind: []const u8, payload: []const u8) !void {
    var nptr: ?[*]const TwigFlatNode = null;
    var nlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(fx.ed, &nptr, &nlen));
    for (nptr.?[0..nlen]) |n| {
        if (!std.mem.eql(u8, std.mem.span(n.kind), kind)) continue;
        if (n.destination_ptr) |d| {
            try std.testing.expectEqualStrings(payload, d[0..n.destination_len]);
        } else if (n.text_ptr) |t| {
            try std.testing.expectEqualStrings(payload, t[0..n.text_len]);
        } else return error.NoPayload;
        return;
    }
    return error.KindNotFound;
}

fn expectNoNodeOfKind(fx: *EditorFixture, kind: []const u8) !void {
    var nptr: ?[*]const TwigFlatNode = null;
    var nlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(fx.ed, &nptr, &nlen));
    for (nptr.?[0..nlen]) |n| {
        if (std.mem.eql(u8, std.mem.span(n.kind), kind)) return error.UnexpectedKind;
    }
}

/// That `needle` survives in no node's payload. A node replaced WHOLE leaves no
/// trace of its old destination; one the op spliced INTO leaves the halves
/// behind as `str` siblings, which the kind assertions alone would not notice.
fn expectNoTextMatching(fx: *EditorFixture, needle: []const u8) !void {
    var nptr: ?[*]const TwigFlatNode = null;
    var nlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(fx.ed, &nptr, &nlen));
    for (nptr.?[0..nlen]) |n| {
        if (n.text_ptr) |t| {
            if (std.mem.indexOf(u8, t[0..n.text_len], needle) != null) return error.TextFound;
        }
        if (n.destination_ptr) |d| {
            if (std.mem.indexOf(u8, d[0..n.destination_len], needle) != null) return error.TextFound;
        }
    }
}

/// A `link`'s VISIBLE text: its `str` children joined. Djot splits an escaped
/// run into several `str` nodes, so a single-child check would miss.
fn expectLinkText(fx: *EditorFixture, expected: []const u8) !void {
    var nptr: ?[*]const TwigFlatNode = null;
    var nlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(fx.ed, &nptr, &nlen));
    const nodes = nptr.?[0..nlen];
    const link = for (nodes) |n| {
        if (std.mem.eql(u8, std.mem.span(n.kind), "link")) break n;
    } else return error.NoLink;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (nodes) |n| {
        if (n.parent != link.id) continue;
        // Anything other than a `str` under the text means the destination
        // grew emphasis / raw HTML / an entity on the way through.
        if (!std.mem.eql(u8, std.mem.span(n.kind), "str")) return error.TextNotLiteral;
        if (n.text_ptr) |t| try buf.appendSlice(std.testing.allocator, t[0..n.text_len]);
    }
    try std.testing.expectEqualStrings(expected, buf.items);
}

// The autolinkable/not split, across both formats. A childless `[](dest)` has
// no text to render or put a caret in, so an empty range spells the destination
// canonically instead — and only the reparsed KIND proves which spelling landed.

test "insert_link: an empty range autolinks an absolute URL (both formats)" {
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("ab\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 1, 1, "https://x.dev"));
        try fx.expectSource("a<https://x.dev>b\n");
        try expectSpelled(&fx, "url", "https://x.dev");
        try expectNoNodeOfKind(&fx, "link");
    }
}

test "insert_link: an empty range autolinks a bare email (both formats)" {
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("ab\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 1, 1, "a@b.dev"));
        try fx.expectSource("a<a@b.dev>b\n");
        try expectSpelled(&fx, "email", "a@b.dev");
    }
}

test "insert_link: the formats disagree on what a `mailto:` autolink IS" {
    // Same spelling, different node: Markdown sees the `mailto:` scheme and
    // calls it a url; djot classifies on the `@` and calls it an email. Both
    // autolink, which is all the caller asked for — but this is exactly why the
    // decision can't be hoisted out of the per-format scanners.
    var dj = try EditorFixture.initFmt("ab\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 1, 1, "mailto:a@b.dev"));
    try dj.expectSource("a<mailto:a@b.dev>b\n");
    try expectSpelled(&dj, "email", "mailto:a@b.dev");

    var md = try EditorFixture.initFmt("ab\n", .markdown);
    defer md.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&md, 1, 1, "mailto:a@b.dev"));
    try md.expectSource("a<mailto:a@b.dev>b\n");
    try expectSpelled(&md, "url", "mailto:a@b.dev");
}

test "insert_link: a bare word is NOT autolinkable — `<foo>` would be raw HTML" {
    // The hazard that motivates the whole split: Markdown reads `<foo>` as an
    // HTML tag and djot as literal text, so neither may spell it as an autolink.
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("ab\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 1, 1, "foo"));
        try fx.expectSource("a[foo](foo)b\n");
        try expectSpelled(&fx, "link", "foo");
        try expectLinkText(&fx, "foo");
        try expectNoNodeOfKind(&fx, "raw_inline");
    }
}

test "insert_link: a relative path is NOT autolinkable — it would go literal" {
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("ab\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 1, 1, "./rel/path.md"));
        try expectSpelled(&fx, "link", "./rel/path.md");
        // Visible and editable, which a childless link never was.
        try expectLinkText(&fx, "./rel/path.md");
    }
}

test "insert_link: a destination with a space falls back, escaped per format" {
    // `<x dev>` is an autolink in neither format (the space ends the scan), so
    // this lands on `[dest](dest)` — where Markdown still needs its angle form
    // for the destination itself.
    var dj = try EditorFixture.initFmt("ab\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 1, 1, "x dev"));
    try dj.expectSource("a[x dev](x dev)b\n");
    try expectSpelled(&dj, "link", "x dev");
    try expectLinkText(&dj, "x dev");

    var md = try EditorFixture.initFmt("ab\n", .markdown);
    defer md.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&md, 1, 1, "x dev"));
    try md.expectSource("a[x dev](<x dev>)b\n");
    try expectSpelled(&md, "link", "x dev");
    try expectLinkText(&md, "x dev");
}

test "insert_link: the doubled destination is escaped for the TEXT position too" {
    // The `(…)` escaping `writeLinkDestination` does is not enough once the
    // destination also sits in the brackets: a `]` closes the text early, and
    // the emphasis/attribute/raw-HTML metacharacters rewrite what's visible.
    var dj = try EditorFixture.initFmt("\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 0, 0, "a]b[c*d*{e}"));
    try expectSpelled(&dj, "link", "a]b[c*d*{e}");
    try expectLinkText(&dj, "a]b[c*d*{e}");

    var md = try EditorFixture.initFmt("\n", .markdown);
    defer md.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&md, 0, 0, "a]b[c*d*<e>&f;"));
    try expectSpelled(&md, "link", "a]b[c*d*<e>&f;");
    try expectLinkText(&md, "a]b[c*d*<e>&f;");
}

/// The destination the parser reads back, whichever spelling the op chose: a
/// `link`'s destination, or an autolink's text (which IS its destination).
fn expectDestRoundTrip(fx: *EditorFixture, expected: []const u8) !void {
    var nptr: ?[*]const TwigFlatNode = null;
    var nlen: usize = 0;
    try std.testing.expectEqual(TwigStatus.ok, twig_editor_nodes(fx.ed, &nptr, &nlen));
    for (nptr.?[0..nlen]) |n| {
        const kind = std.mem.span(n.kind);
        const payload = if (std.mem.eql(u8, kind, "link"))
            (n.destination_ptr orelse return error.NoDestination)[0..n.destination_len]
        else if (std.mem.eql(u8, kind, "url") or std.mem.eql(u8, kind, "email"))
            (n.text_ptr orelse return error.NoText)[0..n.text_len]
        else
            continue;
        try std.testing.expectEqualStrings(expected, payload);
        return;
    }
    return error.NoLinkOfAnyKind;
}

test "insert_link: an empty range round-trips any destination, both formats" {
    // The property both escape sets exist to hold: whichever spelling the op
    // picks, the destination the parser reads back is the one handed in. Every
    // ASCII metacharacter either format has an opinion about is in here.
    const dests = [_][]const u8{
        "https://x.dev",  "mailto:a@b.dev",   "a@b.dev", "foo",
        "./rel/path.md",  "x dev",            "a)b(c",   "a[b",
        "a`b",            "a<b",              "a>b",     "#anchor",
        "../up.md",       "path/to/f (1).md", "a\\b",    "a{b}c",
        "a*b*c",          "a_b_c",            "a]b",     "a&amp;b",
        "a b)c",          "a~b",              "a^b",     "a\"b",
        "a'b",            "a--b",             "a...b",   "a:b",
        "a$b",            "a!b",              "a|b",     "a%20b",
        "a b<c>d",        "a=b+c",            "https://x.dev?a=1&b=2#f",
    };
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        for (dests) |d| {
            var fx = try EditorFixture.initFmt("ab\n", fmt);
            defer fx.deinit();
            try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 1, 1, d));
            expectDestRoundTrip(&fx, d) catch |err| {
                std.debug.print("\nfmt={s} dest=\"{s}\": {s}\n", .{ @tagName(fmt), d, @errorName(err) });
                return err;
            };
        }
    }
}

test "insert_link: re-pointing a text-less link also gets the canonical spelling" {
    // Keyed on the TEXT being empty, not the range — a `[](old)` left by an
    // older twig has the same childless-link problem a bare caret does.
    var fx = try EditorFixture.initFmt("a [](old) b\n", .djot);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 3, 3, "https://x.dev"));
    try fx.expectSource("a <https://x.dev> b\n");
    try expectSpelled(&fx, "url", "https://x.dev");
}

// An autolink re-points too, and it is the case the empty-text spelling made
// reachable: before, the op read `<https://x.dev>` as ordinary text and spliced
// a link into the middle of the URL — `see <https<https://y.dev>://x.dev> ok`.

test "insert_link: a caret in an autolink re-points it, not its URL text" {
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("see <https://x.dev> ok\n", fmt);
        defer fx.deinit();
        // Offset 10 is mid-URL, inside the `url` node's span.
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 10, 10, "https://y.dev"));
        try fx.expectSource("see <https://y.dev> ok\n");
        try expectSpelled(&fx, "url", "https://y.dev");
        // The corruption left the old URL's halves behind as text; a re-point
        // takes the whole node, so no fragment of `x.dev` survives anywhere.
        try expectNoNodeOfKind(&fx, "link");
        try expectNoTextMatching(&fx, "x.dev");
    }
}

test "insert_link: re-pointing an autolink RESPELLS it for the new destination" {
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("see <https://x.dev> ok\n", fmt);
        defer fx.deinit();
        // `<./notes.md>` is not an autolink in either format — carrying the old
        // node's spelling over would leave raw HTML (Markdown) or literal text.
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 10, 10, "./notes.md"));
        // Asserted through the AST, not the bytes: the formats spell this text
        // differently (djot escapes the `.` against smart punctuation), and it
        // is the reparse, not the spelling, that has to agree.
        try expectLinkDest(&fx, "./notes.md");
        try expectLinkText(&fx, "./notes.md");
        try expectNoNodeOfKind(&fx, "url");
    }
}

test "insert_link: an `email` autolink re-points like a `url` one" {
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("see <a@b.dev> ok\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 8, 8, "c@d.dev"));
        try fx.expectSource("see <c@d.dev> ok\n");
        try expectSpelled(&fx, "email", "c@d.dev");
    }
}

test "insert_link: a `mailto:` autolink re-points though the formats disagree on its kind" {
    // The node kind is not a property of the destination: djot calls this an
    // `email`, Markdown a `url`. Matching one kind per format would leave the
    // other format's `<mailto:…>` to be corrupted exactly as before.
    var dj = try EditorFixture.initFmt("see <mailto:a@b.dev> ok\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 10, 10, "mailto:c@d.dev"));
    try dj.expectSource("see <mailto:c@d.dev> ok\n");
    try expectSpelled(&dj, "email", "mailto:c@d.dev");

    var md = try EditorFixture.initFmt("see <mailto:a@b.dev> ok\n", .markdown);
    defer md.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&md, 10, 10, "mailto:c@d.dev"));
    try md.expectSource("see <mailto:c@d.dev> ok\n");
    try expectSpelled(&md, "url", "mailto:c@d.dev");
}

test "insert_link: an autolink's boundaries read like a link's — start in, end out" {
    // The chain's own half-open rule, so both re-point paths agree: a caret AT
    // `span.start` is inside the node, one at `span.end` belongs to the next
    // sibling and means "a new link here".
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var at_start = try EditorFixture.initFmt("see <https://x.dev> ok\n", fmt);
        defer at_start.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&at_start, 4, 4, "https://y.dev"));
        try at_start.expectSource("see <https://y.dev> ok\n");

        var at_end = try EditorFixture.initFmt("see <https://x.dev> ok\n", fmt);
        defer at_end.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&at_end, 19, 19, "https://y.dev"));
        try at_end.expectSource("see <https://x.dev><https://y.dev> ok\n");
    }
}

test "insert_link: a SELECTION overlapping an autolink still wraps, never re-points" {
    // A selection carries its own text to link, so it takes the wrap path
    // whether or not an autolink is under it — the re-point is a caret gesture.
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("see <https://x.dev> ok\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 4, 19, "https://y.dev"));
        try fx.expectSource("see [<https://x.dev>](https://y.dev) ok\n");
    }
}

test "insert_link: a caret in an autolink INSIDE a link re-points the link" {
    // Both are on the chain. The link wins: its text is separable from its
    // destination, so re-pointing it keeps text the autolink path would drop.
    for ([_]TwigFormat{ .djot, .markdown }) |fmt| {
        var fx = try EditorFixture.initFmt("see [<https://x.dev>](old) ok\n", fmt);
        defer fx.deinit();
        try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 10, 10, "https://y.dev"));
        try fx.expectSource("see [<https://x.dev>](https://y.dev) ok\n");
        try expectLinkDest(&fx, "https://y.dev");
    }
}

test "insert_link re-points an existing link instead of nesting one" {
    var fx = try EditorFixture.initFmt("a [word](old) b\n", .djot);
    defer fx.deinit();
    // A caret inside the link text, not a selection of the whole node.
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 4, 6, "new"));
    try fx.expectSource("a [word](new) b\n");
    try expectLinkDest(&fx, "new");
}

test "insert_link escapes parens so the destination survives (djot)" {
    var fx = try EditorFixture.initFmt("w\n", .djot);
    defer fx.deinit();
    // Unescaped, the `)` closes the link early and `b(c` spills out as literal
    // text — the whole reason this op escapes at all.
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 0, 1, "a)b(c"));
    try fx.expectSource("[w](a\\)b\\(c)\n");
    try expectLinkDest(&fx, "a)b(c");
}

test "insert_link escapes parens so the destination survives (markdown)" {
    var fx = try EditorFixture.initFmt("w\n", .markdown);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 0, 1, "a)b(c"));
    try expectLinkDest(&fx, "a)b(c");
}

test "insert_link carries whitespace per format: djot literal, markdown angled" {
    // Djot has no angle form — it would read `<a b>` as the URL itself.
    var dj = try EditorFixture.initFmt("w\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 0, 1, "a b"));
    try dj.expectSource("[w](a b)\n");
    try expectLinkDest(&dj, "a b");

    // Markdown ends the destination at the space, so without `<…>` there is no
    // link at all.
    var md = try EditorFixture.initFmt("w\n", .markdown);
    defer md.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&md, 0, 1, "a b"));
    try md.expectSource("[w](<a b>)\n");
    try expectLinkDest(&md, "a b");
}

test "insert_link escapes the angle form's own delimiters (markdown)" {
    var fx = try EditorFixture.initFmt("w\n", .markdown);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 0, 1, "a >b< c"));
    try expectLinkDest(&fx, "a >b< c");
}

test "insert_link handles whitespace and a paren together (markdown)" {
    var fx = try EditorFixture.initFmt("w\n", .markdown);
    defer fx.deinit();
    // The space forces the angle form, where `)` is ALREADY safe — the
    // destination ends at `>`, so escaping the paren here would put a literal
    // backslash in the URL.
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 0, 1, "a b)c"));
    try fx.expectSource("[w](<a b)c>)\n");
    try expectLinkDest(&fx, "a b)c");
}

test "insert_link escapes the non-paren bytes that also end a destination" {
    // A destination stops being a link for more reasons than an unbalanced
    // paren, and the rest of the set is per-format. Each of these reparses as
    // plain text (or a verbatim span) without its escape.
    var dj = try EditorFixture.initFmt("w\n", .djot);
    defer dj.deinit();
    // Djot keeps scanning inline openers inside `(…)`: `[` starts a bracket run
    // and `` ` `` a verbatim span, either of which eats the closing paren.
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 0, 1, "a[b`c"));
    try dj.expectSource("[w](a\\[b\\`c)\n");
    try expectLinkDest(&dj, "a[b`c");

    var md = try EditorFixture.initFmt("w\n", .markdown);
    defer md.deinit();
    // Markdown reads `<` as the start of the angle form even mid-destination.
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&md, 0, 1, "a<b"));
    try md.expectSource("[w](a\\<b)\n");
    try expectLinkDest(&md, "a<b");
}

test "insert_link escapes an entity so markdown can't decode the destination" {
    // The quiet one: this doesn't break the link, it silently hands back a
    // DIFFERENT URL than the caller asked for. Markdown decodes entities in a
    // destination, so an unescaped `a&amp;b` reparses as `a&b`.
    var fx = try EditorFixture.initFmt("w\n", .markdown);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 0, 1, "a&amp;b"));
    try fx.expectSource("[w](a\\&amp;b)\n");
    try expectLinkDest(&fx, "a&amp;b");

    // ...including inside the angle form the whitespace forces.
    var sp = try EditorFixture.initFmt("w\n", .markdown);
    defer sp.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&sp, 0, 1, "a&amp; b"));
    try sp.expectSource("[w](<a\\&amp; b>)\n");
    try expectLinkDest(&sp, "a&amp; b");

    // Djot has no entities; a `&` there is already literal.
    var dj = try EditorFixture.initFmt("w\n", .djot);
    defer dj.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&dj, 0, 1, "a&amp;b"));
    try dj.expectSource("[w](a&amp;b)\n");
    try expectLinkDest(&dj, "a&amp;b");
}

test "insert_link round-trips a backslash in the destination" {
    var fx = try EditorFixture.initFmt("w\n", .djot);
    defer fx.deinit();
    try std.testing.expectEqual(TwigStatus.ok, insertLink(&fx, 0, 1, "a\\b"));
    try expectLinkDest(&fx, "a\\b");
}

test "insert_link rejects a newline in the destination and an unspellable format" {
    var fx = try EditorFixture.initFmt("w\n", .djot);
    defer fx.deinit();
    // Djot silently strips a newline out of a destination; refusing beats
    // handing back a URL the caller never asked for.
    try std.testing.expectEqual(TwigStatus.invalid_argument, insertLink(&fx, 0, 1, "a\nb"));
    try std.testing.expectEqual(TwigStatus.invalid_argument, insertLink(&fx, 1, 0, "u"));

    var xml = try EditorFixture.init("<a>hi</a>");
    defer xml.deinit();
    try std.testing.expectEqual(TwigStatus.unsupported_format, insertLink(&xml, 3, 5, "u"));
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
