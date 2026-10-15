//! The C ABI of Twig — `bindings/c/include/twig.h` — implemented in Rust over
//! the `twig-doc` engine. Port of `src/c_abi.zig`: the same handles, the same
//! ownership rules (every buffer handed out is owned by its handle and stays
//! valid until the next call to the same accessor or the handle's
//! destruction), the same status codes.
//!
//! `unsafe` is confined to the boundary: turning caller pointers into slices
//! and references, and handles into boxes. Everything past that is the engine.
//!
//! Every exported function that returns a `TwigStatus` runs its body under
//! `catch_unwind`, so an engine panic surfaces as
//! `TWIG_STATUS_INTERNAL_ERROR` instead of unwinding into C (which Rust turns
//! into an abort).

#![allow(clippy::missing_safety_doc)]
#![allow(non_camel_case_types)]

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, OnceLock};

use twig::format as reg;
use twig::runtime;

mod builder;
mod document;
mod editor;
mod language;

pub use builder::*;
pub use document::*;
pub use editor::*;
pub use language::*;

// ── status ──────────────────────────────────────────────────────────────────

/// `TwigStatus`. A plain `c_int` rather than a Rust enum: C may hand back any
/// integer, and the values are the wire contract.
pub type TwigStatus = c_int;

pub const TWIG_STATUS_OK: TwigStatus = 0;
pub const TWIG_STATUS_INVALID_ARGUMENT: TwigStatus = 1;
pub const TWIG_STATUS_PARSE_ERROR: TwigStatus = 2;
pub const TWIG_STATUS_OUT_OF_MEMORY: TwigStatus = 3;
pub const TWIG_STATUS_UNSUPPORTED_FORMAT: TwigStatus = 4;
pub const TWIG_STATUS_NOT_FOUND: TwigStatus = 5;
pub const TWIG_STATUS_AMBIGUOUS: TwigStatus = 6;
pub const TWIG_STATUS_NOT_EDITABLE: TwigStatus = 7;
pub const TWIG_STATUS_EDIT_CONFLICT: TwigStatus = 8;
pub const TWIG_STATUS_UNSAFE_METADATA: TwigStatus = 9;
pub const TWIG_STATUS_INVALID_LANGUAGE: TwigStatus = 10;
pub const TWIG_STATUS_INTERNAL_ERROR: TwigStatus = 255;

// ── constants ───────────────────────────────────────────────────────────────

pub const TWIG_ABI_VERSION: u32 = 6;

pub const TWIG_FORMAT_DJOT: c_int = 1;
pub const TWIG_FORMAT_MARKDOWN: c_int = 2;
pub const TWIG_FORMAT_XML: c_int = 3;
pub const TWIG_FORMAT_HTML: c_int = 4;
pub const TWIG_FORMAT_ASCIIDOC: c_int = 5;
pub const TWIG_FORMAT_COMMONMARK: c_int = 6;
pub const TWIG_FORMAT_GFM: c_int = 7;
pub const TWIG_FORMAT_SVG: c_int = 8;
pub const TWIG_FORMAT_RUNTIME_BASE: c_int = 4096;

pub const TWIG_MD_DIRECTIVES: u32 = 1 << 0;
pub const TWIG_MD_MATH: u32 = 1 << 1;
pub const TWIG_MD_HTML_ELEMENTS: u32 = 1 << 2;
pub const TWIG_MD_HIGHLIGHT: u32 = 1 << 3;
pub const TWIG_MD_HIGHLIGHT_COLORS: u32 = 1 << 4;

pub const TWIG_NO_NODE: u32 = u32::MAX;
pub const TWIG_TASK_CHECKED_NONE: c_int = -1;
pub const TWIG_HEAD_NONE: c_int = -1;
pub const TWIG_ALIGN_NONE: c_int = -1;
pub const TWIG_ALIGN_DEFAULT: c_int = 0;
pub const TWIG_ALIGN_LEFT: c_int = 1;
pub const TWIG_ALIGN_RIGHT: c_int = 2;
pub const TWIG_ALIGN_CENTER: c_int = 3;
pub const TWIG_DIRECTIVE_NONE: c_int = -1;
pub const TWIG_DIRECTIVE_TEXT: c_int = 0;
pub const TWIG_DIRECTIVE_LEAF: c_int = 1;
pub const TWIG_DIRECTIVE_CONTAINER: c_int = 2;
pub const TWIG_CONTAINER_ORIGIN_NONE: c_int = -1;
pub const TWIG_CONTAINER_ORIGIN_ELEMENT: c_int = 0;
pub const TWIG_CONTAINER_ORIGIN_DIRECTIVE: c_int = 1;

pub const TWIG_FIDELITY_FAITHFUL: c_int = 0;
pub const TWIG_FIDELITY_DEGRADED: c_int = 1;
pub const TWIG_FIDELITY_DROPPED: c_int = 2;
pub const TWIG_FIDELITY_ATTRS_DEGRADED: c_int = 3;
pub const TWIG_FIDELITY_ATTRS_DROPPED: c_int = 4;

// ── structs (layouts frozen by twig.h) ──────────────────────────────────────

/// A byte range `[start, end)` into the source.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TwigSpan {
    pub start: usize,
    pub end: usize,
}

/// One node matched by a query; `kind` is static, NUL-terminated.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigQueryMatch {
    pub node_id: u32,
    pub span: TwigSpan,
    pub content_span: TwigSpan,
    pub has_content_span: c_int,
    pub kind: *const c_char,
}

/// The byte effect of an edit.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TwigChange {
    pub old_span: TwigSpan,
    pub new_span: TwigSpan,
}

/// One attribute pair; a NULL `value` is a bare attribute.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigKeyVal {
    pub key: *const u8,
    pub key_len: usize,
    pub value: *const u8,
    pub value_len: usize,
}

/// One node of a flat snapshot.
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
    pub name_ptr: *const u8,
    pub name_len: usize,
    pub attrs_ptr: *const TwigKeyVal,
    pub attrs_len: usize,
    pub directive_form: c_int,
    pub container_origin: c_int,
    pub marker_span: TwigSpan,
    pub has_marker_span: c_int,
    pub checked: c_int,
}

/// One thing a conversion would silently lose.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TwigWarning {
    pub fidelity: c_int,
    pub path_ptr: *const u8,
    pub path_len: usize,
    pub kind: *const c_char,
}

// The canonical 64-bit layout, as the header assumes it.
#[cfg(target_pointer_width = "64")]
const _: () = {
    use std::mem::{offset_of, size_of};
    assert!(size_of::<TwigSpan>() == 16);
    assert!(size_of::<TwigQueryMatch>() == 56);
    assert!(offset_of!(TwigQueryMatch, span) == 8);
    assert!(offset_of!(TwigQueryMatch, content_span) == 24);
    assert!(offset_of!(TwigQueryMatch, has_content_span) == 40);
    assert!(offset_of!(TwigQueryMatch, kind) == 48);
    assert!(size_of::<TwigChange>() == 32);
    assert!(offset_of!(TwigChange, new_span) == 16);
    assert!(size_of::<TwigFlatNode>() == 168);
    assert!(offset_of!(TwigFlatNode, span) == 16);
    assert!(offset_of!(TwigFlatNode, content_span) == 32);
    assert!(offset_of!(TwigFlatNode, has_content_span) == 48);
    assert!(offset_of!(TwigFlatNode, level) == 52);
    assert!(offset_of!(TwigFlatNode, kind) == 56);
    assert!(offset_of!(TwigFlatNode, text_ptr) == 64);
    assert!(offset_of!(TwigFlatNode, destination_ptr) == 80);
    assert!(offset_of!(TwigFlatNode, head) == 96);
    assert!(offset_of!(TwigFlatNode, alignment) == 100);
    assert!(offset_of!(TwigFlatNode, name_ptr) == 104);
    assert!(offset_of!(TwigFlatNode, attrs_ptr) == 120);
    assert!(offset_of!(TwigFlatNode, attrs_len) == 128);
    assert!(offset_of!(TwigFlatNode, directive_form) == 136);
    assert!(offset_of!(TwigFlatNode, container_origin) == 140);
    assert!(offset_of!(TwigFlatNode, marker_span) == 144);
    assert!(offset_of!(TwigFlatNode, has_marker_span) == 160);
    assert!(offset_of!(TwigFlatNode, checked) == 164);
    assert!(size_of::<TwigKeyVal>() == 32);
    assert!(offset_of!(TwigKeyVal, value) == 16);
    assert!(size_of::<TwigWarning>() == 32);
};

// ── boundary helpers ────────────────────────────────────────────────────────

/// Run `body`, turning a panic into `TWIG_STATUS_INTERNAL_ERROR`.
pub(crate) fn guard(body: impl FnOnce() -> TwigStatus) -> TwigStatus {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(TWIG_STATUS_INTERNAL_ERROR)
}

/// `sliceOf`: a caller's `(ptr, len)` as bytes. NULL with a zero length is
/// the empty slice; NULL with a length is no slice at all.
pub(crate) unsafe fn slice_of<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if !ptr.is_null() {
        // SAFETY: the caller promises `ptr` addresses `len` readable bytes.
        Some(unsafe { std::slice::from_raw_parts(ptr, len) })
    } else if len == 0 {
        Some(&[])
    } else {
        None
    }
}

/// A caller's `(ptr, len)` array of `T`, with `sliceOf`'s NULL rule.
pub(crate) unsafe fn array_of<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        // SAFETY: the caller promises `ptr` addresses `len` readable `T`s.
        Some(unsafe { std::slice::from_raw_parts(ptr, len) })
    }
}

/// Write through an out-pointer the caller may have left NULL.
pub(crate) unsafe fn put<T>(out: *mut T, value: T) {
    if !out.is_null() {
        // SAFETY: a non-NULL out-pointer addresses a writable `T`.
        unsafe { out.write(value) }
    }
}

/// A borrowed byte buffer as the `(ptr, len)` the ABI hands out: NULL for an
/// empty one.
pub(crate) fn out_bytes(bytes: &[u8]) -> (*const u8, usize) {
    if bytes.is_empty() { (std::ptr::null(), 0) } else { (bytes.as_ptr(), bytes.len()) }
}

/// A static kind name as the NUL-terminated C string the ABI promises lives
/// for the process. Interned once per name.
pub(crate) fn kind_cstr(name: &'static str) -> *const c_char {
    static NAMES: OnceLock<Mutex<HashMap<&'static str, &'static CStr>>> = OnceLock::new();
    let mut map = NAMES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    map.entry(name)
        .or_insert_with(|| Box::leak(CString::new(name).unwrap_or_default().into_boxed_c_str()))
        .as_ptr()
}

/// `intToFormat`: a wire code to the engine row, or `None` for a code this
/// build does not know (and a runtime code no registration holds).
pub(crate) fn int_to_format(format: c_int) -> Option<reg::Format> {
    if format >= TWIG_FORMAT_RUNTIME_BASE {
        return runtime::format_from_code(format as i64);
    }
    Some(match format {
        TWIG_FORMAT_DJOT => reg::Format::Djot,
        TWIG_FORMAT_MARKDOWN => reg::Format::Markdown,
        TWIG_FORMAT_XML => reg::Format::Xml,
        TWIG_FORMAT_HTML => reg::Format::Html,
        TWIG_FORMAT_ASCIIDOC => reg::Format::Asciidoc,
        TWIG_FORMAT_COMMONMARK => reg::Format::Commonmark,
        TWIG_FORMAT_GFM => reg::Format::Gfm,
        TWIG_FORMAT_SVG => reg::Format::Svg,
        _ => return None,
    })
}

/// `intToTarget`: a dialect code writes as its language's target.
pub(crate) fn int_to_target(format: c_int) -> Option<reg::Target> {
    int_to_format(format).map(reg::target_for)
}

/// `formatToInt`: `intToFormat` read backward.
pub(crate) fn format_to_int(fmt: reg::Format) -> c_int {
    match fmt {
        reg::Format::Djot => TWIG_FORMAT_DJOT,
        reg::Format::Markdown => TWIG_FORMAT_MARKDOWN,
        reg::Format::Xml => TWIG_FORMAT_XML,
        reg::Format::Html => TWIG_FORMAT_HTML,
        reg::Format::Asciidoc => TWIG_FORMAT_ASCIIDOC,
        reg::Format::Commonmark => TWIG_FORMAT_COMMONMARK,
        reg::Format::Gfm => TWIG_FORMAT_GFM,
        reg::Format::Svg => TWIG_FORMAT_SVG,
        reg::Format::Runtime(c) => c as c_int,
    }
}

/// `configFromFlags`: the flags are the row's features in order.
pub(crate) fn config_from_flags(fmt: reg::Format, flags: u32) -> reg::ParseConfig {
    reg::ParseConfig::for_features(fmt, flags)
}

// ── version ─────────────────────────────────────────────────────────────────

const fn parse_u32(s: &str) -> u32 {
    let b = s.as_bytes();
    let mut i = 0;
    let mut n = 0u32;
    while i < b.len() {
        n = n * 10 + (b[i] - b'0') as u32;
        i += 1;
    }
    n
}

/// `(major << 16) | (minor << 8) | patch`.
#[unsafe(no_mangle)]
pub extern "C" fn twig_version() -> u32 {
    (parse_u32(env!("CARGO_PKG_VERSION_MAJOR")) << 16)
        | (parse_u32(env!("CARGO_PKG_VERSION_MINOR")) << 8)
        | parse_u32(env!("CARGO_PKG_VERSION_PATCH"))
}

/// `"major.minor.patch"`, NUL-terminated, static.
#[unsafe(no_mangle)]
pub extern "C" fn twig_version_string() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

#[unsafe(no_mangle)]
pub extern "C" fn twig_abi_version() -> u32 {
    TWIG_ABI_VERSION
}

// ── format names ────────────────────────────────────────────────────────────

/// The code a format name resolves to.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_by_name(name_ptr: *const u8, name_len: usize, out_format: *mut c_int) -> TwigStatus {
    guard(|| {
        let Some(name) = (unsafe { slice_of(name_ptr, name_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_format.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(fmt) = std::str::from_utf8(name).ok().and_then(reg::parse_format_name) else {
            return TWIG_STATUS_UNSUPPORTED_FORMAT;
        };
        unsafe { put(out_format, format_to_int(fmt)) };
        TWIG_STATUS_OK
    })
}

/// A runtime row's name, leaked once so it lives for the process.
fn interned_name(fmt: reg::Format) -> &'static str {
    match fmt {
        reg::Format::Runtime(code) => {
            static NAMES: OnceLock<Mutex<HashMap<(u16, String), &'static str>>> = OnceLock::new();
            let name = runtime::name_of(code);
            let mut map = NAMES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
            map.entry((code, name.clone())).or_insert_with(|| Box::leak(name.into_boxed_str()))
        }
        f => f.static_name(),
    }
}

/// The name a format code answers to — the library's bytes, not
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_name(format: c_int, out_ptr: *mut *const u8, out_len: *mut usize) -> TwigStatus {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let name = interned_name(fmt);
        unsafe {
            put(out_ptr, name.as_ptr());
            put(out_len, name.len());
        }
        TWIG_STATUS_OK
    })
}

/// The language a format code is a dialect of.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_dialect_of(format: c_int, out_format: *mut c_int) -> TwigStatus {
    guard(|| {
        if out_format.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        let Some(parent) = fmt.dialect_of() else { return TWIG_STATUS_NOT_FOUND };
        unsafe { put(out_format, format_to_int(parent)) };
        TWIG_STATUS_OK
    })
}

/// The bit the feature `name` takes over `format`'s row.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_format_feature_bit(
    format: c_int,
    name_ptr: *const u8,
    name_len: usize,
    out_bit: *mut u32,
) -> TwigStatus {
    guard(|| {
        let Some(name) = (unsafe { slice_of(name_ptr, name_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_bit.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(fmt) = int_to_format(format) else { return TWIG_STATUS_UNSUPPORTED_FORMAT };
        if reg::features(fmt).is_empty() && !runtime::is_registered(fmt) {
            return TWIG_STATUS_UNSUPPORTED_FORMAT;
        }
        let Some(bit) = std::str::from_utf8(name).ok().and_then(|n| reg::feature_bit(fmt, n)) else {
            return TWIG_STATUS_NOT_FOUND;
        };
        unsafe { put(out_bit, bit) };
        TWIG_STATUS_OK
    })
}

#[allow(dead_code)]
pub(crate) type UserData = *mut c_void;

#[cfg(test)]
mod tests;
