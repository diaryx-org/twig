//! `TwigDocument` — a one-shot parse, or a borrowed view of an editor's live
//! tree — and the whole `twig_document_*` read surface. Port of the document
//! half of `src/c_abi.zig`.

use std::ffi::c_int;

use twig::ast::editor::Editor as EngineEditor;
use twig::ast::{self as engine, locate, select, NodeId};
use twig::diagnostics;
use twig::document::{ContainerOrigin, Document};
use twig::format as reg;

use crate::*;

/// The opaque C handle.
pub enum TwigDocument {}

/// What a handle is a view OF (`DocumentView` in Zig).
pub(crate) enum View {
    /// A parse the handle owns, with the format and config it was made under.
    Owned(Box<reg::ParsedDoc>),
    /// An editor's live tree, borrowed. The pointer is to the `Editor` inside
    /// the (boxed, never moved) editor handle; its document is replaced on
    /// every reparse, which is what keeps the view current.
    Borrowed(*const EngineEditor),
}

/// A document plus the caller-borrowed output buffers each accessor caches
/// on it — each owned by the handle, replaced by the next call to the same
/// accessor, freed with the handle.
pub(crate) struct DocumentHandle {
    pub(crate) view: View,
    rendered: Vec<u8>,
    serialized: Vec<u8>,
    ast_json: Vec<u8>,
    query_matches: Vec<TwigQueryMatch>,
    flat_nodes: Vec<TwigFlatNode>,
    flat_attrs: Vec<TwigKeyVal>,
    subtree_nodes: Vec<TwigFlatNode>,
    subtree_attrs: Vec<TwigKeyVal>,
    ancestor_matches: Vec<TwigQueryMatch>,
    line_prefix_buf: Vec<u8>,
    caret_matches: Vec<TwigQueryMatch>,
    definition_matches: Vec<TwigQueryMatch>,
    child_matches: Vec<TwigQueryMatch>,
    warnings: Vec<TwigWarning>,
    /// The path strings `warnings` point into.
    warning_paths: Vec<String>,
}

impl DocumentHandle {
    pub(crate) fn new(view: View) -> DocumentHandle {
        DocumentHandle {
            view,
            rendered: Vec::new(),
            serialized: Vec::new(),
            ast_json: Vec::new(),
            query_matches: Vec::new(),
            flat_nodes: Vec::new(),
            flat_attrs: Vec::new(),
            subtree_nodes: Vec::new(),
            subtree_attrs: Vec::new(),
            ancestor_matches: Vec::new(),
            line_prefix_buf: Vec::new(),
            caret_matches: Vec::new(),
            definition_matches: Vec::new(),
            child_matches: Vec::new(),
            warnings: Vec::new(),
            warning_paths: Vec::new(),
        }
    }

    /// The document this handle reads.
    pub(crate) fn doc(&self) -> &Document {
        match &self.view {
            View::Owned(p) => &p.doc,
            // SAFETY: a borrowed view lives inside its editor handle, which
            // outlives it, and the editor is never moved.
            View::Borrowed(e) => unsafe { (**e).doc() },
        }
    }
}

/// The handle behind a non-NULL `TwigDocument`.
unsafe fn handle<'a>(doc: *mut TwigDocument) -> Option<&'a mut DocumentHandle> {
    // SAFETY: every `TwigDocument` this library hands out is a
    // `DocumentHandle` (boxed, or the field of an editor handle).
    unsafe { (doc as *mut DocumentHandle).as_mut() }
}

// ── marshalling ─────────────────────────────────────────────────────────────

pub(crate) fn span_c(s: twig::span::Span) -> TwigSpan {
    TwigSpan { start: s.start, end: s.end }
}

fn kind_name(d: &Document, id: NodeId) -> *const c_char {
    kind_cstr(d.ast.nodes[id as usize].kind.kind_name())
}

/// `flatMatch`.
pub(crate) fn flat_match(d: &Document, id: NodeId) -> TwigQueryMatch {
    let cs = d.content_span(id);
    TwigQueryMatch {
        node_id: id,
        span: span_c(d.span(id)),
        content_span: cs.map(span_c).unwrap_or_default(),
        has_content_span: cs.is_some() as c_int,
        kind: kind_name(d, id),
    }
}

/// `buildQueryMatches`; `None` for a malformed selector.
pub(crate) fn build_query_matches(d: &Document, selector: &[u8]) -> Option<Vec<TwigQueryMatch>> {
    let sel = select::parse(selector).ok()?;
    Some(
        select::resolve_all(d, &sel)
            .into_iter()
            .map(|m| TwigQueryMatch {
                node_id: m.id,
                span: span_c(m.span),
                content_span: m.content_span.map(span_c).unwrap_or_default(),
                has_content_span: m.content_span.is_some() as c_int,
                kind: kind_name(d, m.id),
            })
            .collect(),
    )
}

fn bytes_ptr(b: Option<&[u8]>) -> (*const u8, usize) {
    match b {
        Some(b) => (b.as_ptr(), b.len()),
        None => (std::ptr::null(), 0),
    }
}

/// `flatNodeOf`, with the attributes left for `fill_attrs`.
fn flat_node_of(d: &Document, arena_id: NodeId, id: u32, parent: u32, first_child: u32, next_sibling: u32) -> TwigFlatNode {
    use engine::Kind as K;
    let kind = &d.ast.nodes[arena_id as usize].kind;
    let text: Option<&[u8]> = match kind {
        K::Str(s) => Some(s),
        K::TextLeaf { text, .. } | K::MarkupLeaf { text, .. } => Some(text),
        K::CodeBlock { text, .. } | K::RawBlock { text, .. } | K::RawInline { text, .. } | K::Metadata { text, .. } => {
            Some(text)
        }
        K::Container(c) => c.text.as_deref(),
        K::SmartPunctuation(p) => Some(p.ascii().as_bytes()),
        _ => None,
    };
    let destination = match kind {
        K::Link(l) | K::Image(l) => l.destination.as_deref(),
        _ => None,
    };
    let name = match kind {
        K::Container(c) => Some(&c.name[..]),
        _ => None,
    };
    let level = match kind {
        K::Heading { level } => *level,
        K::Line { indent } => *indent,
        _ => 0,
    };
    let head = match kind {
        K::Row { head } => *head as c_int,
        K::Cell(c) => c.head as c_int,
        _ => TWIG_HEAD_NONE,
    };
    let alignment = match kind {
        K::Cell(c) => match c.alignment {
            engine::Alignment::Default => TWIG_ALIGN_DEFAULT,
            engine::Alignment::Left => TWIG_ALIGN_LEFT,
            engine::Alignment::Right => TWIG_ALIGN_RIGHT,
            engine::Alignment::Center => TWIG_ALIGN_CENTER,
        },
        _ => TWIG_ALIGN_NONE,
    };
    let directive_form = match kind {
        K::Container(c) => match c.form {
            Some(engine::Form::InlineText) => TWIG_DIRECTIVE_TEXT,
            Some(engine::Form::BlockLeaf) => TWIG_DIRECTIVE_LEAF,
            Some(engine::Form::BlockFenced) => TWIG_DIRECTIVE_CONTAINER,
            None => TWIG_DIRECTIVE_NONE,
        },
        _ => TWIG_DIRECTIVE_NONE,
    };
    let container_origin = match d.container_origin(arena_id) {
        Some(ContainerOrigin::Element) => TWIG_CONTAINER_ORIGIN_ELEMENT,
        Some(ContainerOrigin::Directive) => TWIG_CONTAINER_ORIGIN_DIRECTIVE,
        None => TWIG_CONTAINER_ORIGIN_NONE,
    };
    let checked = match kind {
        K::TaskListItem { checked } => *checked as c_int,
        _ => TWIG_TASK_CHECKED_NONE,
    };
    let cs = d.content_span(arena_id);
    let ms = d.marker_span(arena_id);
    let (text_ptr, text_len) = bytes_ptr(text);
    let (destination_ptr, destination_len) = bytes_ptr(destination);
    let (name_ptr, name_len) = bytes_ptr(name);
    TwigFlatNode {
        id,
        parent,
        first_child,
        next_sibling,
        span: span_c(d.span(arena_id)),
        content_span: cs.map(span_c).unwrap_or_default(),
        has_content_span: cs.is_some() as c_int,
        level,
        kind: kind_cstr(kind.kind_name()),
        text_ptr,
        text_len,
        destination_ptr,
        destination_len,
        head,
        alignment,
        name_ptr,
        name_len,
        attrs_ptr: std::ptr::null(),
        attrs_len: 0,
        directive_form,
        container_origin,
        marker_span: ms.map(span_c).unwrap_or_default(),
        has_marker_span: ms.is_some() as c_int,
        checked,
    }
}

/// `fillAttrs`: every snapshot node's attributes in one `TwigKeyVal` buffer,
/// each node pointed at its slice. `order[i]` is the arena id of `buf[i]`.
/// The key/value pointers borrow the AST payload.
fn fill_attrs(d: &Document, buf: &mut [TwigFlatNode], order: &[NodeId]) -> Vec<TwigKeyVal> {
    let total: usize = order.iter().map(|&id| d.ast.attrs_of(id).entries.len()).sum();
    let mut store: Vec<TwigKeyVal> = Vec::with_capacity(total);
    let mut spans = Vec::with_capacity(buf.len());
    for &id in order {
        let entries = &d.ast.attrs_of(id).entries;
        spans.push((store.len(), entries.len()));
        for kv in entries {
            let (value, value_len) = bytes_ptr(kv.value.as_deref());
            store.push(TwigKeyVal { key: kv.key.as_ptr(), key_len: kv.key.len(), value, value_len });
        }
    }
    // The store is complete (and never grows again), so its addresses are
    // final.
    for (node, (start, len)) in buf.iter_mut().zip(spans) {
        if len != 0 {
            node.attrs_ptr = store[start..].as_ptr();
            node.attrs_len = len;
        }
    }
    store
}

/// Hand a cached buffer out: NULL for an empty one.
unsafe fn emit<T>(buf: &[T], out_ptr: *mut *const T, out_len: *mut usize) {
    unsafe {
        put(out_ptr, if buf.is_empty() { std::ptr::null() } else { buf.as_ptr() });
        put(out_len, buf.len());
    }
}

// ── lifecycle ───────────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_parse(
    input_ptr: *const u8,
    input_len: usize,
    format: c_int,
    out_doc: *mut *mut TwigDocument,
) -> TwigStatus {
    unsafe { twig_parse_ext(input_ptr, input_len, format, 0, out_doc) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_parse_ext(
    input_ptr: *const u8,
    input_len: usize,
    format: c_int,
    md_flags: u32,
    out_doc: *mut *mut TwigDocument,
) -> TwigStatus {
    guard(|| {
        if out_doc.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        unsafe { put(out_doc, std::ptr::null_mut()) };
        let Some(source) = (unsafe { slice_of(input_ptr, input_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let cfg = config_from_flags(fmt, md_flags);
        let Ok(parsed) = reg::parse(fmt, &cfg, source) else { return TWIG_STATUS_PARSE_ERROR };
        let handle = Box::new(DocumentHandle::new(View::Owned(Box::new(parsed))));
        unsafe { put(out_doc, Box::into_raw(handle) as *mut TwigDocument) };
        TWIG_STATUS_OK
    })
}

/// A no-op for a view borrowed from an editor, which the editor frees.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_destroy(doc: *mut TwigDocument) {
    let Some(h) = (unsafe { handle(doc) }) else { return };
    if matches!(h.view, View::Borrowed(_)) {
        return;
    }
    // SAFETY: an owned handle came from `Box::into_raw` in `twig_parse_ext`.
    drop(unsafe { Box::from_raw(doc as *mut DocumentHandle) });
}

// ── render / serialize / dump / query ───────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_render_html(
    doc: *mut TwigDocument,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let View::Owned(parsed) = &h.view else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        h.rendered = match reg::render_html(parsed) {
            Ok(r) => r,
            Err(reg::PrintFailure::UnsafeMetadata) => return TWIG_STATUS_UNSAFE_METADATA,
            Err(reg::PrintFailure::UnsupportedFormat) => return TWIG_STATUS_UNSUPPORTED_FORMAT,
            Err(reg::PrintFailure::Language(_)) => return TWIG_STATUS_INTERNAL_ERROR,
        };
        unsafe { emit(&h.rendered, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_serialize(
    doc: *mut TwigDocument,
    format: c_int,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(target) = int_to_target(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let View::Owned(parsed) = &h.view else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let result = if reg::writes_own_syntax(parsed.format, target) {
            reg::serialize_canonical(parsed)
        } else {
            reg::serialize_converted(parsed, target)
        };
        h.serialized = match result {
            Ok(s) => s,
            Err(reg::PrintFailure::UnsupportedFormat) => return TWIG_STATUS_UNSUPPORTED_FORMAT,
            Err(reg::PrintFailure::UnsafeMetadata) => return TWIG_STATUS_UNSAFE_METADATA,
            Err(reg::PrintFailure::Language(_)) => return TWIG_STATUS_INTERNAL_ERROR,
        };
        unsafe { emit(&h.serialized, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_ast_json(
    doc: *mut TwigDocument,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        h.ast_json = twig::ast::json::encode(h.doc());
        unsafe { emit(&h.ast_json, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_query(
    doc: *mut TwigDocument,
    selector_ptr: *const u8,
    selector_len: usize,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(selector) = (unsafe { slice_of(selector_ptr, selector_len) }) else {
            return TWIG_STATUS_INVALID_ARGUMENT;
        };
        let Some(matches) = build_query_matches(h.doc(), selector) else { return TWIG_STATUS_INVALID_ARGUMENT };
        h.query_matches = matches;
        unsafe { emit(&h.query_matches, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_diagnostics(
    doc: *mut TwigDocument,
    format: c_int,
    out_warnings: *mut *const TwigWarning,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_warnings.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(target) = int_to_target(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let d = h.doc();
        let warnings = match diagnostics::analyze(&d.ast, d.ast.root, target) {
            Ok(w) => w,
            Err(diagnostics::AnalyzeError::UnsupportedFormat) => return TWIG_STATUS_UNSUPPORTED_FORMAT,
        };
        let paths: Vec<String> = warnings.iter().map(|w| w.path.clone()).collect();
        let out: Vec<TwigWarning> = warnings
            .iter()
            .zip(&paths)
            .map(|(w, path)| {
                use diagnostics::{Fidelity as F, Subject as S};
                let fidelity = match (w.subject, w.fidelity) {
                    (_, F::Faithful) => TWIG_FIDELITY_FAITHFUL,
                    (S::Node, F::Degraded) => TWIG_FIDELITY_DEGRADED,
                    (S::Node, F::Dropped) => TWIG_FIDELITY_DROPPED,
                    (S::Attrs, F::Degraded) => TWIG_FIDELITY_ATTRS_DEGRADED,
                    (S::Attrs, F::Dropped) => TWIG_FIDELITY_ATTRS_DROPPED,
                };
                let (path_ptr, path_len) = out_bytes(path.as_bytes());
                TwigWarning { fidelity, path_ptr, path_len, kind: kind_cstr(w.kind) }
            })
            .collect();
        h.warnings = out;
        h.warning_paths = paths;
        unsafe { emit(&h.warnings, out_warnings, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_definitions(
    doc: *mut TwigDocument,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        h.definition_matches = d.ast.definition_roots().into_iter().map(|id| flat_match(d, id)).collect();
        unsafe { emit(&h.definition_matches, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

// ── per-node accessors ──────────────────────────────────────────────────────

/// The shared shape of the span accessors: `None` from `get` is NOT_FOUND
/// with the out-param untouched.
unsafe fn span_accessor(
    doc: *mut TwigDocument,
    node_id: u32,
    out_span: *mut TwigSpan,
    get: impl FnOnce(&Document, NodeId) -> Option<twig::span::Span>,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_span.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if node_id as usize >= d.ast.nodes.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(s) = get(d, node_id) else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_span, span_c(s)) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_node_span(doc: *mut TwigDocument, node_id: u32, out_span: *mut TwigSpan) -> TwigStatus {
    unsafe { span_accessor(doc, node_id, out_span, |d, id| Some(d.span(id))) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_node_content_span(
    doc: *mut TwigDocument,
    node_id: u32,
    out_span: *mut TwigSpan,
) -> TwigStatus {
    unsafe { span_accessor(doc, node_id, out_span, |d, id| d.content_span(id)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_node_marker_span(
    doc: *mut TwigDocument,
    node_id: u32,
    out_span: *mut TwigSpan,
) -> TwigStatus {
    unsafe { span_accessor(doc, node_id, out_span, |d, id| d.marker_span(id)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_attrs_span(doc: *mut TwigDocument, node_id: u32, out_span: *mut TwigSpan) -> TwigStatus {
    unsafe { span_accessor(doc, node_id, out_span, |d, id| d.attrs_span(id)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_line_prefix(doc: *mut TwigDocument, offset: usize, out_span: *mut TwigSpan) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_span.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if offset > d.source.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(s) = locate::line_prefix_span(d, offset) else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_span, span_c(s)) };
        TWIG_STATUS_OK
    })
}

/// `linePrefixInto`.
unsafe fn line_prefix_into(
    doc: *mut TwigDocument,
    offset: usize,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
    out_columns: *mut usize,
    blank: bool,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if offset > d.source.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let mut buf = Vec::new();
        let columns = if blank {
            locate::blank_line_prefix(d, offset, &mut buf)
        } else {
            locate::continuation_prefix(d, offset, &mut buf)
        };
        h.line_prefix_buf = buf;
        unsafe {
            emit(&h.line_prefix_buf, out_ptr, out_len);
            put(out_columns, columns);
        }
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_continuation_prefix(
    doc: *mut TwigDocument,
    offset: usize,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
    out_columns: *mut usize,
) -> TwigStatus {
    unsafe { line_prefix_into(doc, offset, out_ptr, out_len, out_columns, false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_blank_line_prefix(
    doc: *mut TwigDocument,
    offset: usize,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
    out_columns: *mut usize,
) -> TwigStatus {
    unsafe { line_prefix_into(doc, offset, out_ptr, out_len, out_columns, true) }
}

/// `cellExtent`.
unsafe fn cell_extent(doc: *mut TwigDocument, node_id: u32, out: *mut u32, rows: bool) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if node_id as usize >= d.ast.nodes.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let engine::Kind::Cell(c) = &d.ast.nodes[node_id as usize].kind else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out, if rows { c.rowspan } else { c.colspan }) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_cell_colspan(doc: *mut TwigDocument, node_id: u32, out_colspan: *mut u32) -> TwigStatus {
    unsafe { cell_extent(doc, node_id, out_colspan, false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_cell_rowspan(doc: *mut TwigDocument, node_id: u32, out_rowspan: *mut u32) -> TwigStatus {
    unsafe { cell_extent(doc, node_id, out_rowspan, true) }
}

// ── tree read-back ──────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_nodes(
    doc: *mut TwigDocument,
    out_ptr: *mut *const TwigFlatNode,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        let nodes = &d.ast.nodes;
        let link = |id: Option<NodeId>| id.unwrap_or(TWIG_NO_NODE);
        let mut buf: Vec<TwigFlatNode> = nodes
            .iter()
            .enumerate()
            .map(|(i, n)| flat_node_of(d, i as u32, i as u32, TWIG_NO_NODE, link(n.first_child), link(n.next_sibling)))
            .collect();
        // A node stores children, not its parent: stamp each node's children.
        for (i, n) in nodes.iter().enumerate() {
            let mut child = n.first_child;
            while let Some(c) = child {
                buf[c as usize].parent = i as u32;
                child = nodes[c as usize].next_sibling;
            }
        }
        let order: Vec<NodeId> = (0..nodes.len() as u32).collect();
        let attrs = fill_attrs(d, &mut buf, &order);
        h.flat_nodes = buf;
        h.flat_attrs = attrs;
        unsafe { emit(&h.flat_nodes, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_children(
    doc: *mut TwigDocument,
    node_id: u32,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        let parent = if node_id == TWIG_NO_NODE {
            d.ast.root
        } else if (node_id as usize) < d.ast.nodes.len() {
            node_id
        } else {
            return TWIG_STATUS_INVALID_ARGUMENT;
        };
        h.child_matches = d.ast.children(parent).map(|c| flat_match(d, c.id)).collect();
        unsafe { emit(&h.child_matches, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_subtree(
    doc: *mut TwigDocument,
    node_id: u32,
    out_ptr: *mut *const TwigFlatNode,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        let ast = &d.ast;
        if node_id as usize >= ast.nodes.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let ids = ast.subtree_ids(node_id);
        let mut local = vec![TWIG_NO_NODE; ast.nodes.len()];
        for (i, &old) in ids.iter().enumerate() {
            local[old as usize] = i as u32;
        }
        // The root's next_sibling leaves the subtree, so `local` maps it to
        // NO_NODE; a descendant's sibling is always inside.
        let map = |maybe: Option<NodeId>| maybe.map_or(TWIG_NO_NODE, |id| local[id as usize]);
        let mut buf: Vec<TwigFlatNode> = ids
            .iter()
            .enumerate()
            .map(|(i, &old)| {
                let n = &ast.nodes[old as usize];
                flat_node_of(d, old, i as u32, TWIG_NO_NODE, map(n.first_child), map(n.next_sibling))
            })
            .collect();
        for (i, &old) in ids.iter().enumerate() {
            let mut child = ast.nodes[old as usize].first_child;
            while let Some(c) = child {
                let l = local[c as usize];
                if l != TWIG_NO_NODE {
                    buf[l as usize].parent = i as u32;
                }
                child = ast.nodes[c as usize].next_sibling;
            }
        }
        let attrs = fill_attrs(d, &mut buf, &ids);
        h.subtree_nodes = buf;
        h.subtree_attrs = attrs;
        unsafe { emit(&h.subtree_nodes, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_node_at(doc: *mut TwigDocument, offset: usize, out_match: *mut TwigQueryMatch) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_match.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if offset > d.source.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(found) = locate::deepest_containing(d, offset) else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_match, flat_match(d, found)) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_nodes_at(
    doc: *mut TwigDocument,
    offset: usize,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if offset > d.source.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        // Rebuild the exact root→deepest descent, so the chain ends at what
        // `twig_document_node_at` returns.
        let Some(deepest) = locate::deepest_containing(d, offset) else {
            h.ancestor_matches = Vec::new();
            unsafe { emit(&h.ancestor_matches, out_ptr, out_len) };
            return TWIG_STATUS_NOT_FOUND;
        };
        let mut cur = d.ast.root;
        let mut chain = vec![flat_match(d, cur)];
        while cur != deepest {
            match locate::child_containing(d, cur, offset) {
                Some(c) => cur = c,
                None => break,
            }
            chain.push(flat_match(d, cur));
        }
        h.ancestor_matches = chain;
        unsafe { emit(&h.ancestor_matches, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_node_at_caret(
    doc: *mut TwigDocument,
    offset: usize,
    out_match: *mut TwigQueryMatch,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_match.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if offset > d.source.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(found) = locate::deepest_containing_for_caret(d, offset) else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_match, flat_match(d, found)) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_nodes_at_caret(
    doc: *mut TwigDocument,
    offset: usize,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let d = h.doc();
        if offset > d.source.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        if d.ast.nodes.is_empty() {
            h.caret_matches = Vec::new();
            unsafe { emit(&h.caret_matches, out_ptr, out_len) };
            return TWIG_STATUS_NOT_FOUND;
        }
        let mut cur = d.ast.root;
        let mut chain = vec![flat_match(d, cur)];
        while let Some(child) = locate::caret_child_containing(d, cur, offset) {
            cur = child;
            chain.push(flat_match(d, cur));
        }
        h.caret_matches = chain;
        unsafe { emit(&h.caret_matches, out_ptr, out_len) };
        TWIG_STATUS_OK
    })
}
