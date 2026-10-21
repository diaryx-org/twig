//! A document's metadata block — its frontmatter or endmatter, or an HTML
//! page's `<script type="application/<lang>">` data island — located, read
//! as JSON, and replaced, over `twig::meta`. The body is config, so editing
//! it in place, comments kept, is fig's: a caller edits the body with fig and
//! hands the result to `twig_editor_set_metadata`.

use std::ffi::c_int;

use twig::meta::{self, Where};
use twig::span::Span;

use crate::document::{handle, span_c};
use crate::editor::{change_c, editor_handle};
use crate::*;

pub const TWIG_META_FRONT: c_int = 0;
pub const TWIG_META_END: c_int = 1;

fn where_of(at: c_int) -> Option<Where> {
    match at {
        TWIG_META_FRONT => Some(Where::Front),
        TWIG_META_END => Some(Where::End),
        _ => None,
    }
}

fn status_of_meta_error(e: meta::Error) -> TwigStatus {
    match e {
        meta::Error::NoMetadata => TWIG_STATUS_NOT_FOUND,
        meta::Error::UnsupportedLanguage(_) => TWIG_STATUS_UNSUPPORTED_FORMAT,
        meta::Error::Fig(_) => TWIG_STATUS_PARSE_ERROR,
        meta::Error::UnsafeIslandBody | meta::Error::BodyEscapesBlock => TWIG_STATUS_UNSAFE_METADATA,
        meta::Error::Twig(twig::Error::UnsupportedFormat) => TWIG_STATUS_UNSUPPORTED_FORMAT,
        meta::Error::Twig(_) => TWIG_STATUS_PARSE_ERROR,
        _ => TWIG_STATUS_INTERNAL_ERROR,
    }
}

/// Where `doc`'s metadata block at `at` sits, and its language tag.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_metadata(
    doc: *mut TwigDocument,
    at: c_int,
    out_span: *mut TwigSpan,
    out_body: *mut TwigSpan,
    out_lang_ptr: *mut *const u8,
    out_lang_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(at) = where_of(at) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(block) = meta::find(h.doc(), at) else { return TWIG_STATUS_NOT_FOUND };
        h.meta_lang = block.lang.into_bytes();
        let (lang_ptr, lang_len) = out_bytes(&h.meta_lang);
        unsafe {
            put(out_span, span_c(Span::new(block.span.start, block.span.end)));
            put(out_body, span_c(Span::new(block.body.start, block.body.end)));
            put(out_lang_ptr, lang_ptr);
            put(out_lang_len, lang_len);
        }
        TWIG_STATUS_OK
    })
}

/// The body of `doc`'s metadata block at `at`, read by fig and written as
/// compact JSON.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_document_metadata_json(
    doc: *mut TwigDocument,
    at: c_int,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { handle(doc) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(at) = where_of(at) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let body = match meta::read(h.doc(), at) {
            Ok(Some(body)) => body,
            Ok(None) => return TWIG_STATUS_NOT_FOUND,
            Err(e) => return status_of_meta_error(e),
        };
        let Some(json) = meta::dialect_for("json") else { return TWIG_STATUS_INTERNAL_ERROR };
        // Lossless: a value JSON has no spelling for comes back as fig's
        // `$fig` envelope rather than failing the whole read.
        let Ok(text) = body.serialize_with(json, fig::SerializeOptions::compact().lossless()) else {
            return TWIG_STATUS_UNSUPPORTED_FORMAT;
        };
        h.meta_json = text.into_bytes();
        let (ptr, len) = out_bytes(&h.meta_json);
        unsafe {
            put(out_ptr, ptr);
            put(out_len, len);
        }
        TWIG_STATUS_OK
    })
}

/// Replace the body of the editor's metadata block at `at` with `body`, or
/// for `TWIG_META_FRONT` on a document with none, write a new block of
/// `lang` (YAML when empty) holding it. One splice, one undo step.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_editor_set_metadata(
    ed: *mut TwigEditor,
    at: c_int,
    lang_ptr: *const u8,
    lang_len: usize,
    body_ptr: *const u8,
    body_len: usize,
    out_change: *mut TwigChange,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { editor_handle(ed) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        // SAFETY: a non-NULL `TwigEditor` is a live boxed `EditorHandle`.
        let h = unsafe { &mut *h };
        let Some(at) = where_of(at) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(lang) = (unsafe { slice_of(lang_ptr, lang_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(body) = (unsafe { slice_of(body_ptr, body_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Ok(lang) = std::str::from_utf8(lang) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let lang = if lang.is_empty() { "yaml" } else { lang };
        let source = h.editor.source_bytes();
        let after = match meta::replace_body(source, h.format, at, lang, body) {
            Ok(after) => after,
            Err(e) => return status_of_meta_error(e),
        };
        // The one range the two differ in, so the change a caret re-anchors
        // by is the block's and not the whole document's.
        let before = source;
        let prefix = before.iter().zip(&after).take_while(|(a, b)| a == b).count();
        let room = before.len().min(after.len()) - prefix;
        let suffix = before.iter().rev().zip(after.iter().rev()).take(room).take_while(|(a, b)| a == b).count();
        let span = Span::new(prefix, before.len() - suffix);
        let text = after[prefix..after.len() - suffix].to_vec();
        if h.editor.splicer.replace_at_span(span, &text).is_err() {
            return TWIG_STATUS_EDIT_CONFLICT;
        }
        if let Some(c) = h.editor.splicer.last_change {
            unsafe { put(out_change, change_c(c)) };
        }
        TWIG_STATUS_OK
    })
}
