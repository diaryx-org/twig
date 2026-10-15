//! `TwigEditor` — the span-splice editor and its authoring gestures, plus the
//! format capability queries. Port of the editor half of `src/c_abi.zig`.

use std::ffi::c_int;
use std::ptr::addr_of_mut;

use twig::ast::editor::{self as engine_editor, Editor as EngineEditor};
use twig::ast::splicer::{self, ParseError, Placement};
use twig::ast::{self as engine, filter, locator, KeyVal, NodeId};
use twig::format as reg;
use twig::span::Span;

use crate::document::{span_c, DocumentHandle, View};
use crate::*;

/// The opaque C handle.
pub enum TwigEditor {}

/// The engine editor plus a `TwigDocument` over its live tree — the home of
/// every caller-borrowed read buffer this handle hands out, so the
/// `twig_editor_*` reads and the `twig_document_*` ones reached through
/// `twig_editor_document` are one implementation over one set of buffers.
pub(crate) struct EditorHandle {
    editor: EngineEditor,
    view: DocumentHandle,
}

unsafe fn editor_handle(ed: *mut TwigEditor) -> Option<*mut EditorHandle> {
    if ed.is_null() { None } else { Some(ed as *mut EditorHandle) }
}

/// The engine editor of a non-NULL handle.
unsafe fn editor<'a>(ed: *mut TwigEditor) -> Option<&'a mut EngineEditor> {
    // SAFETY: every `TwigEditor` is a boxed `EditorHandle`; only the
    // `editor` field is borrowed, leaving the view's buffers alone.
    unsafe { editor_handle(ed).map(|h| &mut *addr_of_mut!((*h).editor)) }
}

/// The editor's borrowed document view as the opaque C type.
unsafe fn view_of(h: *mut EditorHandle) -> *mut TwigDocument {
    unsafe { addr_of_mut!((*h).view) as *mut TwigDocument }
}

fn change_c(c: splicer::Change) -> TwigChange {
    TwigChange { old_span: span_c(c.old), new_span: span_c(c.new) }
}

// ── error → status ──────────────────────────────────────────────────────────

fn status_of_editor_error(e: engine_editor::Error) -> TwigStatus {
    use engine_editor::Error as E;
    match e {
        E::InvalidRange
        | E::InvalidLevel
        | E::InvalidDestination
        | E::InvalidLanguage
        | E::InvalidLabel
        | E::InvalidColor
        | E::InvalidShape
        | E::InvalidName
        | E::InvalidAttribute
        | E::InvalidFormula
        | E::InvalidArgument => TWIG_STATUS_INVALID_ARGUMENT,
        E::UnsupportedFormat => TWIG_STATUS_UNSUPPORTED_FORMAT,
        E::NoBlock => TWIG_STATUS_NOT_FOUND,
        E::NotEditable => TWIG_STATUS_NOT_EDITABLE,
        E::EditConflict => TWIG_STATUS_EDIT_CONFLICT,
    }
}

fn status_of_locator_error(e: locator::Error) -> TwigStatus {
    match e {
        locator::Error::InvalidLocator => TWIG_STATUS_INVALID_ARGUMENT,
        locator::Error::NotFound => TWIG_STATUS_NOT_FOUND,
        locator::Error::Ambiguous => TWIG_STATUS_AMBIGUOUS,
    }
}

/// Anything not named is the parser rejecting the edited document, which the
/// splicer has already rolled back.
fn status_of_splicer_error(e: splicer::Error) -> TwigStatus {
    match e {
        splicer::Error::NoNodeSpan | splicer::Error::NoContentSpan | splicer::Error::NotAContainer => {
            TWIG_STATUS_NOT_EDITABLE
        }
        splicer::Error::OverlappingNodes => TWIG_STATUS_INVALID_ARGUMENT,
        _ => TWIG_STATUS_EDIT_CONFLICT,
    }
}

// ── lifecycle ───────────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_create(
    input_ptr: *const u8,
    input_len: usize,
    format: c_int,
    out_editor: *mut *mut TwigEditor,
) -> TwigStatus {
    unsafe { twig_editor_create_ext(input_ptr, input_len, format, 0, out_editor) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_create_ext(
    input_ptr: *const u8,
    input_len: usize,
    format: c_int,
    md_flags: u32,
    out_editor: *mut *mut TwigEditor,
) -> TwigStatus {
    guard(|| {
        if out_editor.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        unsafe { put(out_editor, std::ptr::null_mut()) };
        let Some(source) = (unsafe { slice_of(input_ptr, input_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let (fmt, cfg) = reg::resolve_as_asked(fmt, &config_from_flags(fmt, md_flags), source);
        // The parser and the spelling come from the same registry row under
        // the same config, so a gesture writes exactly what the editor's own
        // reparse reads back.
        let parse: splicer::ParseFn =
            Box::new(move |src: &[u8]| reg::parse_to_ast(fmt, &cfg, src).map_err(|e| ParseError::new(e.name())));
        let syntax = reg::syntax_for_config(fmt, &cfg);
        let Ok(engine) = EngineEditor::new(source, parse, syntax) else { return TWIG_STATUS_PARSE_ERROR };
        let raw = Box::into_raw(Box::new(EditorHandle {
            editor: engine,
            view: DocumentHandle::new(View::Borrowed(std::ptr::null())),
        }));
        // Only now is the editor at the address the view borrows; the box is
        // never moved, so that address holds until destroy.
        unsafe {
            (*raw).view.view = View::Borrowed(addr_of_mut!((*raw).editor) as *const EngineEditor);
            put(out_editor, raw as *mut TwigEditor);
        }
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_destroy(ed: *mut TwigEditor) {
    if let Some(h) = unsafe { editor_handle(ed) } {
        // SAFETY: the handle came from `Box::into_raw` in create.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// A read-only `TwigDocument` view of the editor's current tree, borrowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_document(ed: *mut TwigEditor, out_doc: *mut *mut TwigDocument) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { editor_handle(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_doc.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        unsafe { put(out_doc, view_of(h)) };
        TWIG_STATUS_OK
    })
}

// ── locator-addressed tree ops ──────────────────────────────────────────────

/// `applyEdit`: resolve `locator` against the current tree and run `op`.
unsafe fn apply_edit(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    op: impl FnOnce(&mut splicer::Splicer, NodeId, &[u8]) -> Result<(), splicer::Error>,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(locator) = (unsafe { slice_of(locator_ptr, locator_len) }) else {
            return TWIG_STATUS_INVALID_ARGUMENT;
        };
        let Some(text) = (unsafe { slice_of(text_ptr, text_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let id = match locator::resolve(&e.splicer.doc, locator) {
            Ok(id) => id,
            Err(err) => return status_of_locator_error(err),
        };
        match op(&mut e.splicer, id, text) {
            Ok(()) => TWIG_STATUS_OK,
            Err(err) => status_of_splicer_error(err),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_replace(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    text_ptr: *const u8,
    text_len: usize,
) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, text_ptr, text_len, |s, id, t| s.replace_node_by_id(id, t)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_replace_content(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    text_ptr: *const u8,
    text_len: usize,
) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, text_ptr, text_len, |s, id, t| s.replace_content_by_id(id, t)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_before(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    text_ptr: *const u8,
    text_len: usize,
) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, text_ptr, text_len, |s, id, t| s.insert_before_by_id(id, t)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_after(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    text_ptr: *const u8,
    text_len: usize,
) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, text_ptr, text_len, |s, id, t| s.insert_after_by_id(id, t)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_child(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    child_index: usize,
    text_ptr: *const u8,
    text_len: usize,
) -> TwigStatus {
    unsafe {
        apply_edit(ed, locator_ptr, locator_len, text_ptr, text_len, |s, id, t| s.insert_child_by_id(id, child_index, t))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_delete(ed: *mut TwigEditor, locator_ptr: *const u8, locator_len: usize) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, std::ptr::null(), 0, |s, id, _| s.delete_node_by_id(id)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_delete_smart(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, std::ptr::null(), 0, |s, id, _| s.delete_node_smart_by_id(id)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_unwrap(ed: *mut TwigEditor, locator_ptr: *const u8, locator_len: usize) -> TwigStatus {
    unsafe { apply_edit(ed, locator_ptr, locator_len, std::ptr::null(), 0, |s, id, _| s.unwrap_node_by_id(id)) }
}

/// `applyMove`: both locators against the same tree.
unsafe fn apply_move(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    anchor_ptr: *const u8,
    anchor_len: usize,
    place: Placement,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(locator) = (unsafe { slice_of(locator_ptr, locator_len) }) else {
            return TWIG_STATUS_INVALID_ARGUMENT;
        };
        let Some(anchor) = (unsafe { slice_of(anchor_ptr, anchor_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let id = match locator::resolve(&e.splicer.doc, locator) {
            Ok(id) => id,
            Err(err) => return status_of_locator_error(err),
        };
        let target = match locator::resolve(&e.splicer.doc, anchor) {
            Ok(id) => id,
            Err(err) => return status_of_locator_error(err),
        };
        match e.splicer.move_node_by_id(id, target, place) {
            Ok(()) => TWIG_STATUS_OK,
            Err(err) => status_of_splicer_error(err),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_move_before(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    anchor_ptr: *const u8,
    anchor_len: usize,
) -> TwigStatus {
    unsafe { apply_move(ed, locator_ptr, locator_len, anchor_ptr, anchor_len, Placement::Before) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_move_after(
    ed: *mut TwigEditor,
    locator_ptr: *const u8,
    locator_len: usize,
    anchor_ptr: *const u8,
    anchor_len: usize,
) -> TwigStatus {
    unsafe { apply_move(ed, locator_ptr, locator_len, anchor_ptr, anchor_len, Placement::After) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_filter(
    ed: *mut TwigEditor,
    drop_ptr: *const u8,
    drop_len: usize,
    keep_ptr: *const u8,
    keep_len: usize,
    unwrap_kept: c_int,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(drop) = (unsafe { slice_of(drop_ptr, drop_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        // `keep` is optional: NULL means "no keep".
        let keep = if keep_ptr.is_null() { None } else { unsafe { slice_of(keep_ptr, keep_len) } };
        let options = filter::Options { drop, keep, unwrap_kept: unwrap_kept != 0 };
        match filter::apply(&mut e.splicer, &options) {
            Ok(()) => TWIG_STATUS_OK,
            Err(filter::Error::InvalidSelector) => TWIG_STATUS_INVALID_ARGUMENT,
            Err(filter::Error::FilterDidNotConverge) => TWIG_STATUS_INTERNAL_ERROR,
            Err(filter::Error::Edit(splicer::Error::NoNodeSpan | splicer::Error::NoContentSpan)) => {
                TWIG_STATUS_NOT_EDITABLE
            }
            Err(filter::Error::Edit(_)) => TWIG_STATUS_EDIT_CONFLICT,
        }
    })
}

// ── reads ───────────────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_source(ed: *mut TwigEditor, out_ptr: *mut *const u8, out_len: *mut usize) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let (p, n) = out_bytes(e.source_bytes());
        unsafe {
            put(out_ptr, p);
            put(out_len, n);
        }
        TWIG_STATUS_OK
    })
}

/// Forward an editor read to the document read over the editor's view.
unsafe fn via_view(ed: *mut TwigEditor, read: impl FnOnce(*mut TwigDocument) -> TwigStatus) -> TwigStatus {
    match unsafe { editor_handle(ed) } {
        Some(h) => read(unsafe { view_of(h) }),
        None => TWIG_STATUS_INVALID_ARGUMENT,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_ast_json(ed: *mut TwigEditor, out_ptr: *mut *const u8, out_len: *mut usize) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_ast_json(d, out_ptr, out_len)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_query(
    ed: *mut TwigEditor,
    selector_ptr: *const u8,
    selector_len: usize,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_query(d, selector_ptr, selector_len, out_ptr, out_len)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_nodes(
    ed: *mut TwigEditor,
    out_ptr: *mut *const TwigFlatNode,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_nodes(d, out_ptr, out_len)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_child_spans(
    ed: *mut TwigEditor,
    node_id: u32,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_children(d, node_id, out_ptr, out_len)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_subtree(
    ed: *mut TwigEditor,
    node_id: u32,
    out_ptr: *mut *const TwigFlatNode,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_subtree(d, node_id, out_ptr, out_len)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_node_at(ed: *mut TwigEditor, offset: usize, out_match: *mut TwigQueryMatch) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_node_at(d, offset, out_match)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_nodes_at(
    ed: *mut TwigEditor,
    offset: usize,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe { via_view(ed, |d| twig_document_nodes_at(d, offset, out_ptr, out_len)) }
}

// ── offset-addressed editing & history ──────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_edit_range(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(text) = (unsafe { slice_of(text_ptr, text_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if start > end || end > e.source_bytes().len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        // Any failure is the edited document not reparsing; rolled back.
        if e.splicer.replace_at_span(Span::new(start, end), text).is_err() {
            return TWIG_STATUS_EDIT_CONFLICT;
        }
        if let Some(c) = e.splicer.last_change {
            unsafe { put(out_change, change_c(c)) };
        }
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_last_change(ed: *mut TwigEditor, out_change: *mut TwigChange) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_change.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(c) = e.splicer.last_change else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_change, change_c(c)) };
        TWIG_STATUS_OK
    })
}

/// `undo` / `redo`: NOT_FOUND on an empty stack.
unsafe fn history(
    ed: *mut TwigEditor,
    out_change: *mut TwigChange,
    step: impl FnOnce(&mut splicer::Splicer) -> Result<Option<splicer::Change>, ParseError>,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        match step(&mut e.splicer) {
            Ok(Some(c)) => {
                unsafe { put(out_change, change_c(c)) };
                TWIG_STATUS_OK
            }
            Ok(None) => TWIG_STATUS_NOT_FOUND,
            Err(_) => TWIG_STATUS_EDIT_CONFLICT,
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_undo(ed: *mut TwigEditor, out_change: *mut TwigChange) -> TwigStatus {
    unsafe { history(ed, out_change, |s| s.undo()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_redo(ed: *mut TwigEditor, out_change: *mut TwigChange) -> TwigStatus {
    unsafe { history(ed, out_change, |s| s.redo()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_coalesce_last(ed: *mut TwigEditor) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        e.splicer.coalesce_last_undo();
        TWIG_STATUS_OK
    })
}

/// 0 for a NULL editor.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_revision(ed: *mut TwigEditor) -> u64 {
    match unsafe { editor(ed) } {
        Some(e) => e.splicer.revision,
        None => 0,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_dirty_range(ed: *mut TwigEditor, out_span: *mut TwigSpan) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_span.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(d) = e.splicer.dirty_range() else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_span, span_c(d)) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_clear_dirty(ed: *mut TwigEditor) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        e.splicer.clear_dirty();
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_caret_blob(ed: *mut TwigEditor, blob_ptr: *const u8, blob_len: usize) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(blob) = (unsafe { slice_of(blob_ptr, blob_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        e.splicer.set_caret(blob);
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_caret_blob(ed: *mut TwigEditor, out_ptr: *mut *const u8, out_len: *mut usize) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let (p, n) = out_bytes(e.splicer.caret_blob());
        unsafe {
            put(out_ptr, p);
            put(out_len, n);
        }
        TWIG_STATUS_OK
    })
}

// ── gestures ────────────────────────────────────────────────────────────────

/// Run a gesture and report its change through `out_change` when there is
/// one. A documented no-op (renumbering a sequential list, ticking a ticked
/// box, clearing an absent colour) leaves no change of its own, so the slot
/// then reports the most recent prior edit, or is left untouched.
unsafe fn gesture(
    ed: *mut TwigEditor,
    out_change: *mut TwigChange,
    op: impl FnOnce(&mut EngineEditor) -> Result<(), engine_editor::Error>,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if let Err(err) = op(e) {
            return status_of_editor_error(err);
        }
        if let Some(c) = e.last_change() {
            unsafe { put(out_change, change_c(c)) };
        }
        TWIG_STATUS_OK
    })
}

/// `TwigInlineKind`.
fn inline_kind_from_int(v: c_int) -> Option<engine_editor::InlineKind> {
    use engine_editor::InlineKind as K;
    Some(match v {
        0 => K::Strong,
        1 => K::Emph,
        2 => K::Verbatim,
        3 => K::Mark,
        4 => K::Superscript,
        5 => K::Subscript,
        6 => K::Insert,
        7 => K::Delete,
        _ => return None,
    })
}

/// `TwigBlockContainerKind`.
fn container_kind_from_int(v: c_int) -> Option<engine_editor::ContainerKind> {
    use engine_editor::ContainerKind as K;
    Some(match v {
        0 => K::BlockQuote,
        1 => K::BulletList,
        2 => K::OrderedList,
        _ => return None,
    })
}

/// `TwigAlignment`.
pub(crate) fn alignment_of(v: c_int) -> Option<engine::Alignment> {
    Some(match v {
        TWIG_ALIGN_DEFAULT => engine::Alignment::Default,
        TWIG_ALIGN_LEFT => engine::Alignment::Left,
        TWIG_ALIGN_RIGHT => engine::Alignment::Right,
        TWIG_ALIGN_CENTER => engine::Alignment::Center,
        _ => return None,
    })
}

/// An optional string in this ABI's `(ptr, len, has_*)` spelling: `Ok(None)`
/// when `has` is 0, `Err` for a NULL pointer with a length.
unsafe fn optional<'a>(ptr: *const u8, len: usize, has: c_int) -> Result<Option<&'a [u8]>, ()> {
    if has == 0 {
        return Ok(None);
    }
    unsafe { slice_of(ptr, len) }.map(Some).ok_or(())
}

/// A caller's `TwigKeyVal` array decoded into owned engine pairs.
/// `attrs_len == 0` is none, whatever the pointer.
pub(crate) unsafe fn key_vals(attrs_ptr: *const TwigKeyVal, attrs_len: usize) -> Option<Vec<KeyVal>> {
    let raw = unsafe { array_of(attrs_ptr, attrs_len) }?;
    raw.iter()
        .map(|c| {
            let key = unsafe { slice_of(c.key, c.key_len) }?;
            let value = if c.value.is_null() {
                None
            } else {
                Some(unsafe { std::slice::from_raw_parts(c.value, c.value_len) })
            };
            Some(KeyVal::new(key, value))
        })
        .collect()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_wrap_range(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    kind: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    let Some(k) = inline_kind_from_int(kind) else { return TWIG_STATUS_INVALID_ARGUMENT };
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    unsafe { gesture(ed, out_change, |e| e.wrap_range(Span::new(start, end), k)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_toggle_inline(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    kind: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    let Some(k) = inline_kind_from_int(kind) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| e.toggle_inline(Span::new(start, end), k)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_mark_color(
    ed: *mut TwigEditor,
    offset: usize,
    color_ptr: *const u8,
    color_len: usize,
    has_color: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Ok(color) = (unsafe { optional(color_ptr, color_len, has_color) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| e.set_mark_color(offset, color)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_block(
    ed: *mut TwigEditor,
    offset: usize,
    block_kind: c_int,
    level: u32,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let kind = match block_kind {
        0 => engine_editor::BlockKind::Paragraph,
        1 => engine_editor::BlockKind::Heading,
        _ => return TWIG_STATUS_INVALID_ARGUMENT,
    };
    unsafe { gesture(ed, out_change, |e| e.set_block(offset, kind, level)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_toggle_block_container(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    container_kind: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Some(k) = container_kind_from_int(container_kind) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| e.toggle_block_container(Span::new(start, end), k)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_renumber_ordered_lists(
    ed: *mut TwigEditor,
    offset: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.renumber_ordered_lists(offset)) }
}

/// `TwigTableOp`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_table_edit(
    ed: *mut TwigEditor,
    offset: usize,
    op: c_int,
    arg: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let side = arg != 0;
    match op {
        0 => unsafe { gesture(ed, out_change, |e| e.table_insert_row(offset, side)) },
        1 => unsafe { gesture(ed, out_change, |e| e.table_delete_row(offset)) },
        2 => unsafe { gesture(ed, out_change, |e| e.table_insert_column(offset, side)) },
        3 => unsafe { gesture(ed, out_change, |e| e.table_delete_column(offset)) },
        4 => {
            let Some(a) = alignment_of(arg) else { return TWIG_STATUS_INVALID_ARGUMENT };
            unsafe { gesture(ed, out_change, |e| e.table_set_alignment(offset, a)) }
        }
        5 => unsafe { gesture(ed, out_change, |e| e.table_move_row(offset, side)) },
        6 => unsafe { gesture(ed, out_change, |e| e.table_move_column(offset, side)) },
        _ => TWIG_STATUS_INVALID_ARGUMENT,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_table(
    ed: *mut TwigEditor,
    offset: usize,
    rows: usize,
    cols: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.insert_table(offset, rows, cols)) }
}

/// A NULL `label_ptr` with a zero length is NO label; a non-NULL one with a
/// zero length is an EMPTY label.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_directive(
    ed: *mut TwigEditor,
    offset: usize,
    name_ptr: *const u8,
    name_len: usize,
    label_ptr: *const u8,
    label_len: usize,
    attrs_ptr: *const TwigKeyVal,
    attrs_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Some(name) = (unsafe { slice_of(name_ptr, name_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    let label = if !label_ptr.is_null() {
        Some(unsafe { std::slice::from_raw_parts(label_ptr, label_len) })
    } else if label_len == 0 {
        None
    } else {
        return TWIG_STATUS_INVALID_ARGUMENT;
    };
    let Some(attrs) = (unsafe { key_vals(attrs_ptr, attrs_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| e.insert_directive(offset, name, label, &attrs)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_block_attrs(
    ed: *mut TwigEditor,
    offset: usize,
    attrs_ptr: *const TwigKeyVal,
    attrs_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Some(attrs) = (unsafe { key_vals(attrs_ptr, attrs_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| e.set_block_attrs(offset, &attrs)) }
}

/// A no-op clear (no attributes to remove) leaves no change, so the slot
/// reports an empty change at 0 rather than the previous edit's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_node_attrs(
    ed: *mut TwigEditor,
    node_id: u32,
    attrs_ptr: *const TwigKeyVal,
    attrs_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    guard(|| {
        let Some(e) = (unsafe { editor(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(attrs) = (unsafe { key_vals(attrs_ptr, attrs_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if let Err(err) = e.set_node_attrs(node_id, &attrs) {
            return status_of_editor_error(err);
        }
        unsafe { put(out_change, e.last_change().map(change_c).unwrap_or_default()) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_wrap_range_attrs(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    attrs_ptr: *const TwigKeyVal,
    attrs_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Some(attrs) = (unsafe { key_vals(attrs_ptr, attrs_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| e.wrap_range_attrs(Span::new(start, end), &attrs)) }
}

/// The gestures taking one `(ptr, len)` string: NULL with a length is
/// INVALID_ARGUMENT.
unsafe fn with_bytes(
    ed: *mut TwigEditor,
    ptr: *const u8,
    len: usize,
    out_change: *mut TwigChange,
    op: impl FnOnce(&mut EngineEditor, &[u8]) -> Result<(), engine_editor::Error>,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Some(bytes) = (unsafe { slice_of(ptr, len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe { gesture(ed, out_change, |e| op(e, bytes)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_link(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    destination_ptr: *const u8,
    destination_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { with_bytes(ed, destination_ptr, destination_len, out_change, |e, d| e.insert_link(Span::new(start, end), d)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_image(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    destination_ptr: *const u8,
    destination_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe {
        with_bytes(ed, destination_ptr, destination_len, out_change, |e, d| e.insert_image(Span::new(start, end), d))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_literal(
    ed: *mut TwigEditor,
    offset: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { with_bytes(ed, text_ptr, text_len, out_change, |e, t| e.insert_literal(offset, t)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_line_break(ed: *mut TwigEditor, offset: usize, out_change: *mut TwigChange) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.insert_line_break(offset)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_thematic_break(
    ed: *mut TwigEditor,
    offset: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.insert_thematic_break(offset)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_split_block(ed: *mut TwigEditor, offset: usize, out_change: *mut TwigChange) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.split_block(offset)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_join_blocks(ed: *mut TwigEditor, offset: usize, out_change: *mut TwigChange) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.join_blocks(offset)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_move_block(
    ed: *mut TwigEditor,
    from: usize,
    to: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.move_block(from, to)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_toggle_code_block(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    language_ptr: *const u8,
    language_len: usize,
    has_language: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Ok(lang) = (unsafe { optional(language_ptr, language_len, has_language) }) else {
        return TWIG_STATUS_INVALID_ARGUMENT;
    };
    unsafe { gesture(ed, out_change, |e| e.toggle_code_block(Span::new(start, end), lang)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_code_language(
    ed: *mut TwigEditor,
    offset: usize,
    language_ptr: *const u8,
    language_len: usize,
    has_language: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    if ed.is_null() {
        return TWIG_STATUS_INVALID_ARGUMENT;
    }
    let Ok(lang) = (unsafe { optional(language_ptr, language_len, has_language) }) else {
        return TWIG_STATUS_INVALID_ARGUMENT;
    };
    unsafe { gesture(ed, out_change, |e| e.set_code_language(offset, lang)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_toggle_task_item(ed: *mut TwigEditor, offset: usize, out_change: *mut TwigChange) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.toggle_task_item(offset)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_task_checked(
    ed: *mut TwigEditor,
    offset: usize,
    checked: c_int,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.set_task_checked(offset, checked != 0)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_toggle_task_checked(
    ed: *mut TwigEditor,
    offset: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.toggle_task_checked(offset)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_footnote(
    ed: *mut TwigEditor,
    offset: usize,
    label_ptr: *const u8,
    label_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { with_bytes(ed, label_ptr, label_len, out_change, |e, l| e.insert_footnote(offset, l)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_inline_math(
    ed: *mut TwigEditor,
    offset: usize,
    formula_ptr: *const u8,
    formula_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { with_bytes(ed, formula_ptr, formula_len, out_change, |e, f| e.insert_inline_math(offset, f)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_insert_display_math(
    ed: *mut TwigEditor,
    offset: usize,
    formula_ptr: *const u8,
    formula_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { with_bytes(ed, formula_ptr, formula_len, out_change, |e, f| e.insert_display_math(offset, f)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_toggle_line_block(
    ed: *mut TwigEditor,
    start: usize,
    end: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    unsafe { gesture(ed, out_change, |e| e.toggle_line_block(start, end)) }
}

// ── format capability ───────────────────────────────────────────────────────

/// `gestureFromInt` + `gestureOf`: the gesture a `(gesture, kind)` pair
/// names, `kind` read in that gesture's own space; `None` for a code naming
/// nothing or a stray kind on a kindless gesture.
fn gesture_of(gesture: c_int, kind: c_int) -> Option<engine_editor::Gesture> {
    use engine_editor::Gesture as G;
    let kindless = |g: G| if kind != 0 { None } else { Some(g) };
    match gesture {
        0 => inline_kind_from_int(kind).map(G::WrapRange),
        1 => inline_kind_from_int(kind).map(G::ToggleInline),
        2 => kindless(G::SetBlock),
        3 => container_kind_from_int(kind).map(G::ToggleBlockContainer),
        4 => kindless(G::InsertThematicBreak),
        5 => kindless(G::ToggleCodeBlock),
        6 => kindless(G::SetCodeLanguage),
        7 => kindless(G::ToggleTaskItem),
        8 => kindless(G::SetTaskChecked),
        9 => kindless(G::ToggleTaskChecked),
        10 => kindless(G::InsertLink),
        11 => kindless(G::InsertImage),
        12 => kindless(G::InsertFootnote),
        13 => kindless(G::InsertLiteral),
        14 => kindless(G::InsertLineBreak),
        15 => kindless(G::SplitBlock),
        16 => kindless(G::RenumberOrderedLists),
        17 => kindless(G::TableInsertRow),
        18 => kindless(G::TableDeleteRow),
        19 => kindless(G::TableInsertColumn),
        20 => kindless(G::TableDeleteColumn),
        21 => kindless(G::TableSetAlignment),
        22 => kindless(G::TableMoveRow),
        23 => kindless(G::TableMoveColumn),
        24 => kindless(G::SetMarkColor),
        25 => kindless(G::InsertTable),
        26 => kindless(G::InsertDirective),
        27 => kindless(G::SetBlockAttrs),
        28 => kindless(G::WrapRangeAttrs),
        29 => kindless(G::JoinBlocks),
        30 => kindless(G::SetNodeAttrs),
        31 => kindless(G::MoveBlock),
        32 => kindless(G::InsertInlineMath),
        33 => kindless(G::InsertDisplayMath),
        34 => kindless(G::ToggleLineBlock),
        _ => None,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_supports(format: c_int, gesture: c_int, kind: c_int, out_supported: *mut c_int) -> TwigStatus {
    unsafe { twig_format_supports_ext(format, 0, gesture, kind, out_supported) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_supports_ext(
    format: c_int,
    md_flags: u32,
    gesture: c_int,
    kind: c_int,
    out_supported: *mut c_int,
) -> TwigStatus {
    guard(|| {
        if out_supported.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let Some(g) = gesture_of(gesture, kind) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let cfg = config_from_flags(fmt, md_flags);
        let yes = engine_editor::supports(reg::syntax_for_config(fmt, &cfg), g);
        unsafe { put(out_supported, yes as c_int) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_is_authorable(format: c_int, out_authorable: *mut c_int) -> TwigStatus {
    guard(|| {
        if out_authorable.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        unsafe { put(out_authorable, reg::syntax_for(fmt).authorable() as c_int) };
        TWIG_STATUS_OK
    })
}
