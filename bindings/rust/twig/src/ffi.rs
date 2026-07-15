use std::os::raw::{c_char, c_int};

/// The C ABI contract version this binding is written against; see
/// `twig_abi_version`. Must match the value baked into the linked library
/// (asserted at runtime by the `abi_version_matches` test in `lib.rs`).
pub const TWIG_ABI_VERSION: u32 = 2;

// Freeze the canonical 64-bit layout of every `#[repr(C)]` mirror below so it
// can never silently drift from the Zig `extern struct` it shadows. These are
// the same offsets asserted on the Zig side in `src/c_abi.zig`; a change on
// either side that isn't matched on the other fails to compile. Gated on 64-bit
// (the offsets are the LP64/LLP64 layout); 32-bit targets pack tighter but the
// C ABI still keeps both languages in agreement.
#[cfg(target_pointer_width = "64")]
const _: () = {
    use std::mem::offset_of;
    use std::mem::size_of;

    assert!(size_of::<TwigSpan>() == 16);
    assert!(offset_of!(TwigSpan, start) == 0);
    assert!(offset_of!(TwigSpan, end) == 8);

    assert!(size_of::<TwigQueryMatch>() == 56);
    assert!(offset_of!(TwigQueryMatch, node_id) == 0);
    assert!(offset_of!(TwigQueryMatch, span) == 8);
    assert!(offset_of!(TwigQueryMatch, content_span) == 24);
    assert!(offset_of!(TwigQueryMatch, has_content_span) == 40);
    assert!(offset_of!(TwigQueryMatch, kind) == 48);

    assert!(size_of::<TwigChange>() == 32);
    assert!(offset_of!(TwigChange, old_span) == 0);
    assert!(offset_of!(TwigChange, new_span) == 16);

    assert!(size_of::<TwigFlatNode>() == 104);
    assert!(offset_of!(TwigFlatNode, id) == 0);
    assert!(offset_of!(TwigFlatNode, parent) == 4);
    assert!(offset_of!(TwigFlatNode, first_child) == 8);
    assert!(offset_of!(TwigFlatNode, next_sibling) == 12);
    assert!(offset_of!(TwigFlatNode, span) == 16);
    assert!(offset_of!(TwigFlatNode, content_span) == 32);
    assert!(offset_of!(TwigFlatNode, has_content_span) == 48);
    assert!(offset_of!(TwigFlatNode, level) == 52);
    assert!(offset_of!(TwigFlatNode, kind) == 56);
    assert!(offset_of!(TwigFlatNode, text_ptr) == 64);
    assert!(offset_of!(TwigFlatNode, text_len) == 72);
    assert!(offset_of!(TwigFlatNode, destination_ptr) == 80);
    assert!(offset_of!(TwigFlatNode, destination_len) == 88);
    assert!(offset_of!(TwigFlatNode, head) == 96);
    assert!(offset_of!(TwigFlatNode, alignment) == 100);

    assert!(size_of::<TwigKeyVal>() == 32);
    assert!(offset_of!(TwigKeyVal, key) == 0);
    assert!(offset_of!(TwigKeyVal, key_len) == 8);
    assert!(offset_of!(TwigKeyVal, value) == 16);
    assert!(offset_of!(TwigKeyVal, value_len) == 24);
};

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TwigStatus(pub c_int);

#[allow(dead_code)]
impl TwigStatus {
    pub const OK: c_int = 0;
    pub const INVALID_ARGUMENT: c_int = 1;
    pub const PARSE_ERROR: c_int = 2;
    pub const OUT_OF_MEMORY: c_int = 3;
    pub const UNSUPPORTED_FORMAT: c_int = 4;
    pub const NOT_FOUND: c_int = 5;
    pub const AMBIGUOUS: c_int = 6;
    pub const NOT_EDITABLE: c_int = 7;
    pub const EDIT_CONFLICT: c_int = 8;
    pub const UNSAFE_METADATA: c_int = 9;
    pub const INTERNAL_ERROR: c_int = 255;
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TwigFormat {
    Djot = 1,
    Markdown = 2,
    Xml = 3,
    Html = 4,
}

/// Markdown extension flags for `twig_editor_create_ext`'s `md_flags` bitmask.
pub const TWIG_MD_DIRECTIVES: u32 = 1 << 0;
pub const TWIG_MD_MATH: u32 = 1 << 1;

pub enum TwigDocument {}

pub enum TwigEditor {}

pub enum TwigBuilder {}

/// C ABI mirror of Zig's `TwigKeyVal` — one attribute pair for
/// `twig_builder_set_attrs`. A NULL `value` is a bare attribute.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigKeyVal {
    pub key: *const u8,
    pub key_len: usize,
    pub value: *const u8,
    pub value_len: usize,
}

/// C ABI mirror of Zig's `TwigSpan` — a byte range `[start, end)`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TwigSpan {
    pub start: usize,
    pub end: usize,
}

/// C ABI mirror of Zig's `TwigQueryMatch` — one node returned by
/// `twig_document_query`. `content_span` is only meaningful when
/// `has_content_span` is non-zero. `kind` is a NUL-terminated node-kind name
/// in static, library-owned storage (never freed).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigQueryMatch {
    pub node_id: u32,
    pub span: TwigSpan,
    pub content_span: TwigSpan,
    pub has_content_span: c_int,
    pub kind: *const c_char,
}

/// The sentinel `node_id` for "no such node" in a [`TwigFlatNode`] link field.
pub const TWIG_NO_NODE: u32 = u32::MAX;

/// C ABI mirror of Zig's `TwigChange` — the byte effect of an edit. `old_span`
/// is the replaced range in the pre-edit source; `new_span` is the range the
/// replacement occupies in the post-edit source (same start).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigChange {
    pub old_span: TwigSpan,
    pub new_span: TwigSpan,
}

/// C ABI mirror of Zig's `TwigFlatNode` — one node of the editor's flat tree
/// snapshot. Link fields (`parent`/`first_child`/`next_sibling`) are ids or
/// [`TWIG_NO_NODE`]. `content_span` is meaningful only when `has_content_span`.
/// `kind` is static, library-owned storage; `text`/`destination` pointers
/// borrow the current parse's payloads (NULL when the kind carries none).
/// `head`/`alignment` carry a `row`/`cell` payload, each `-1` for a kind that
/// has none (see [`TWIG_HEAD_NONE`] / [`TWIG_ALIGN_NONE`]).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigFlatNode {
    pub id: u32,
    pub parent: u32,
    pub first_child: u32,
    pub next_sibling: u32,
    pub span: TwigSpan,
    pub content_span: TwigSpan,
    pub has_content_span: c_int,
    pub level: u32,
    pub kind: *const c_char,
    pub text_ptr: *const u8,
    pub text_len: usize,
    pub destination_ptr: *const u8,
    pub destination_len: usize,
    pub head: c_int,
    pub alignment: c_int,
}

/// `TwigFlatNode::head` for a node that is neither a `row` nor a `cell`.
pub const TWIG_HEAD_NONE: c_int = -1;

/// `TwigFlatNode::alignment` codes; `NONE` means the node isn't a `cell`.
/// `NONE` is part of the ABI contract even though `Alignment::from_c` folds it
/// into its catch-all, so spell it out rather than leaving the -1 a mystery.
#[allow(dead_code)]
pub const TWIG_ALIGN_NONE: c_int = -1;
pub const TWIG_ALIGN_DEFAULT: c_int = 0;
pub const TWIG_ALIGN_LEFT: c_int = 1;
pub const TWIG_ALIGN_RIGHT: c_int = 2;
pub const TWIG_ALIGN_CENTER: c_int = 3;

unsafe extern "C" {
    pub fn twig_abi_version() -> u32;
    pub fn twig_version() -> u32;
    pub fn twig_version_string() -> *const c_char;
    pub fn twig_parse(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut TwigDocument,
    ) -> TwigStatus;
    pub fn twig_document_destroy(doc: *mut TwigDocument);
    pub fn twig_document_render_html(
        doc: *mut TwigDocument,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_document_serialize(
        doc: *mut TwigDocument,
        format: c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_document_ast_json(
        doc: *mut TwigDocument,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_document_query(
        doc: *mut TwigDocument,
        selector: *const u8,
        selector_len: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;

    pub fn twig_editor_create(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_editor: *mut *mut TwigEditor,
    ) -> TwigStatus;
    pub fn twig_editor_create_ext(
        input: *const u8,
        input_len: usize,
        format: c_int,
        md_flags: u32,
        out_editor: *mut *mut TwigEditor,
    ) -> TwigStatus;
    pub fn twig_editor_destroy(editor: *mut TwigEditor);
    pub fn twig_editor_replace(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_replace_content(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_insert_before(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_insert_after(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_insert_child(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
        child_index: usize,
        text: *const u8,
        text_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_delete(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_delete_smart(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_unwrap(
        editor: *mut TwigEditor,
        locator: *const u8,
        locator_len: usize,
    ) -> TwigStatus;
    pub fn twig_editor_filter(
        editor: *mut TwigEditor,
        drop: *const u8,
        drop_len: usize,
        keep: *const u8,
        keep_len: usize,
        unwrap_kept: c_int,
    ) -> TwigStatus;
    pub fn twig_editor_source(
        editor: *mut TwigEditor,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_ast_json(
        editor: *mut TwigEditor,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_query(
        editor: *mut TwigEditor,
        selector: *const u8,
        selector_len: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_edit_range(
        editor: *mut TwigEditor,
        start: usize,
        end: usize,
        text: *const u8,
        text_len: usize,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_last_change(
        editor: *mut TwigEditor,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_undo(editor: *mut TwigEditor, out_change: *mut TwigChange) -> TwigStatus;
    pub fn twig_editor_redo(editor: *mut TwigEditor, out_change: *mut TwigChange) -> TwigStatus;
    pub fn twig_editor_coalesce_last(editor: *mut TwigEditor) -> TwigStatus;
    pub fn twig_editor_nodes(
        editor: *mut TwigEditor,
        out_ptr: *mut *const TwigFlatNode,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_node_at(
        editor: *mut TwigEditor,
        offset: usize,
        out_match: *mut TwigQueryMatch,
    ) -> TwigStatus;
    pub fn twig_editor_nodes_at(
        editor: *mut TwigEditor,
        offset: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_editor_wrap_range(
        editor: *mut TwigEditor,
        start: usize,
        end: usize,
        kind: c_int,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_toggle_inline(
        editor: *mut TwigEditor,
        start: usize,
        end: usize,
        kind: c_int,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_set_block(
        editor: *mut TwigEditor,
        offset: usize,
        block_kind: c_int,
        level: u32,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_toggle_block_container(
        editor: *mut TwigEditor,
        start: usize,
        end: usize,
        container_kind: c_int,
        out_change: *mut TwigChange,
    ) -> TwigStatus;
    pub fn twig_editor_insert_link(
        editor: *mut TwigEditor,
        start: usize,
        end: usize,
        destination: *const u8,
        destination_len: usize,
        out_change: *mut TwigChange,
    ) -> TwigStatus;

    pub fn twig_builder_create(out_builder: *mut *mut TwigBuilder) -> TwigStatus;
    pub fn twig_builder_destroy(builder: *mut TwigBuilder);
    pub fn twig_builder_add(builder: *mut TwigBuilder, kind: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_text(
        builder: *mut TwigBuilder,
        kind: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_heading(builder: *mut TwigBuilder, level: u32, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_code_block(
        builder: *mut TwigBuilder,
        lang: *const u8,
        lang_len: usize,
        has_lang: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_raw_block(
        builder: *mut TwigBuilder,
        format: *const u8,
        format_len: usize,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_metadata(
        builder: *mut TwigBuilder,
        lang: *const u8,
        lang_len: usize,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_raw_inline(
        builder: *mut TwigBuilder,
        format: *const u8,
        format_len: usize,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_smart_punctuation(
        builder: *mut TwigBuilder,
        punct_kind: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_link(
        builder: *mut TwigBuilder,
        destination: *const u8,
        destination_len: usize,
        has_destination: c_int,
        reference: *const u8,
        reference_len: usize,
        has_reference: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_image(
        builder: *mut TwigBuilder,
        destination: *const u8,
        destination_len: usize,
        has_destination: c_int,
        reference: *const u8,
        reference_len: usize,
        has_reference: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_directive(
        builder: *mut TwigBuilder,
        form: c_int,
        name: *const u8,
        name_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_element(
        builder: *mut TwigBuilder,
        name: *const u8,
        name_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_processing_instruction(
        builder: *mut TwigBuilder,
        target: *const u8,
        target_len: usize,
        data: *const u8,
        data_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_footnote(
        builder: *mut TwigBuilder,
        label: *const u8,
        label_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_reference(
        builder: *mut TwigBuilder,
        label: *const u8,
        label_len: usize,
        destination: *const u8,
        destination_len: usize,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_bullet_list(
        builder: *mut TwigBuilder,
        style: c_int,
        tight: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_ordered_list(
        builder: *mut TwigBuilder,
        numbering: c_int,
        delim: c_int,
        tight: c_int,
        start: u32,
        has_start: c_int,
        out_id: *mut u32,
    ) -> TwigStatus;
    pub fn twig_builder_add_task_list(builder: *mut TwigBuilder, tight: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_task_list_item(builder: *mut TwigBuilder, checked: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_row(builder: *mut TwigBuilder, head: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_add_cell(builder: *mut TwigBuilder, head: c_int, alignment: c_int, out_id: *mut u32) -> TwigStatus;
    pub fn twig_builder_set_children(
        builder: *mut TwigBuilder,
        parent: u32,
        ids: *const u32,
        ids_len: usize,
    ) -> TwigStatus;
    pub fn twig_builder_set_attrs(
        builder: *mut TwigBuilder,
        id: u32,
        kvs: *const TwigKeyVal,
        kvs_len: usize,
    ) -> TwigStatus;
    pub fn twig_builder_render_html(
        builder: *mut TwigBuilder,
        root: u32,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_builder_serialize(
        builder: *mut TwigBuilder,
        root: u32,
        format: c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_builder_ast_json(
        builder: *mut TwigBuilder,
        root: u32,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> TwigStatus;
    pub fn twig_builder_query(
        builder: *mut TwigBuilder,
        root: u32,
        selector: *const u8,
        selector_len: usize,
        out_ptr: *mut *const TwigQueryMatch,
        out_len: *mut usize,
    ) -> TwigStatus;
}
