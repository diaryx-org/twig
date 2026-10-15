//! `TwigBuilder` — programmatic construction of a document, and the
//! render / serialize / dump / query of any subtree of it. Port of the
//! builder half of `src/c_abi.zig` over the engine's `ast::Builder`.

use std::ffi::c_int;

use twig::ast::{self as engine, Attrs, Builder as EngineBuilder, Cell, Container, Link, MarkupLeafKind, TextLeafKind};
use twig::document::{self as edoc, Document, Spelling};
use twig::format as reg;
use twig::languages;

use crate::document::build_query_matches;
use crate::editor::{alignment_of, key_vals};
use crate::*;

/// The opaque C handle.
pub enum TwigBuilder {}

struct BuilderHandle {
    builder: EngineBuilder,
    rendered: Vec<u8>,
    serialized: Vec<u8>,
    ast_json: Vec<u8>,
    query_matches: Vec<TwigQueryMatch>,
}

unsafe fn builder<'a>(b: *mut TwigBuilder) -> Option<&'a mut BuilderHandle> {
    // SAFETY: every `TwigBuilder` is a boxed `BuilderHandle`.
    unsafe { (b as *mut BuilderHandle).as_mut() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_create(out_builder: *mut *mut TwigBuilder) -> TwigStatus {
    guard(|| {
        if out_builder.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let handle = Box::new(BuilderHandle {
            builder: EngineBuilder::new(),
            rendered: Vec::new(),
            serialized: Vec::new(),
            ast_json: Vec::new(),
            query_matches: Vec::new(),
        });
        unsafe { put(out_builder, Box::into_raw(handle) as *mut TwigBuilder) };
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_destroy(b: *mut TwigBuilder) {
    if !b.is_null() {
        // SAFETY: the handle came from `Box::into_raw` in create.
        drop(unsafe { Box::from_raw(b as *mut BuilderHandle) });
    }
}

/// Add a node and write its id: the shape every constructor shares.
unsafe fn emit_node(b: *mut TwigBuilder, out_id: *mut u32, kind: impl FnOnce() -> Option<engine::Kind>) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { builder(b) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let Some(kind) = kind() else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_id.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let id = h.builder.add_node(kind);
        unsafe { put(out_id, id) };
        TWIG_STATUS_OK
    })
}

/// `voidKind`: the void-payload kind a `TwigNodeKind` code names. `div` and
/// `span` build the containers they always did.
fn void_kind(kind: c_int) -> Option<engine::Kind> {
    use engine::{Form, InlineMark as M, Kind as K};
    Some(match kind {
        0 => K::Doc,
        1 => K::Para,
        3 => K::ThematicBreak,
        4 => K::Section,
        5 => K::Container(Container::with_form(b"div", Form::BlockFenced)),
        42 => K::Container(Container::with_form(b"span", Form::InlineText)),
        9 => K::BlockQuote,
        13 => K::DefinitionList,
        14 => K::Table,
        15 => K::ListItem,
        17 => K::DefinitionListItem,
        18 => K::Term,
        19 => K::Definition,
        22 => K::Caption,
        60 => K::Column,
        61 => K::LineBlock,
        26 => K::SoftBreak,
        27 => K::HardBreak,
        28 => K::NonBreakingSpace,
        38 => K::InlineMark(M::Emph),
        39 => K::InlineMark(M::Strong),
        43 => K::InlineMark(M::Mark),
        44 => K::InlineMark(M::Superscript),
        45 => K::InlineMark(M::Subscript),
        46 => K::InlineMark(M::Insert),
        47 => K::InlineMark(M::Delete),
        48 => K::InlineMark(M::DoubleQuoted),
        49 => K::InlineMark(M::SingleQuoted),
        _ => return None,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add(b: *mut TwigBuilder, kind: c_int, out_id: *mut u32) -> TwigStatus {
    unsafe { emit_node(b, out_id, || void_kind(kind)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_text(
    b: *mut TwigBuilder,
    kind: c_int,
    text_ptr: *const u8,
    text_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            use engine::Kind as K;
            let t = slice_of(text_ptr, text_len)?.to_vec();
            let leaf = |kind: TextLeafKind, text: Vec<u8>| K::TextLeaf { kind, text };
            Some(match kind {
                25 => K::Str(t),
                29 => leaf(TextLeafKind::Symb, t),
                30 => leaf(TextLeafKind::Verbatim, t),
                32 => leaf(TextLeafKind::InlineMath, t),
                33 => leaf(TextLeafKind::DisplayMath, t),
                34 => leaf(TextLeafKind::Url, t),
                35 => leaf(TextLeafKind::Email, t),
                36 => leaf(TextLeafKind::FootnoteReference, t),
                58 => leaf(TextLeafKind::CitationReference, t),
                59 => leaf(TextLeafKind::SubstitutionReference, t),
                52 => K::MarkupLeaf { kind: MarkupLeafKind::Comment, text: t },
                53 => K::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: t },
                55 => K::MarkupLeaf { kind: MarkupLeafKind::Cdata, text: t },
                _ => return None,
            })
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_heading(b: *mut TwigBuilder, level: u32, out_id: *mut u32) -> TwigStatus {
    unsafe { emit_node(b, out_id, || Some(engine::Kind::Heading { level })) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_code_block(
    b: *mut TwigBuilder,
    lang_ptr: *const u8,
    lang_len: usize,
    has_lang: c_int,
    text_ptr: *const u8,
    text_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            let text = slice_of(text_ptr, text_len)?.to_vec();
            let lang = if has_lang != 0 { Some(slice_of(lang_ptr, lang_len)?.to_vec()) } else { None };
            Some(engine::Kind::CodeBlock { lang, text })
        })
    }
}

/// The two-string constructors: `(format|lang, text)`.
unsafe fn two_strings(
    b: *mut TwigBuilder,
    a_ptr: *const u8,
    a_len: usize,
    t_ptr: *const u8,
    t_len: usize,
    out_id: *mut u32,
    make: impl FnOnce(Vec<u8>, Vec<u8>) -> engine::Kind,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            let a = slice_of(a_ptr, a_len)?.to_vec();
            let t = slice_of(t_ptr, t_len)?.to_vec();
            Some(make(a, t))
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_raw_block(
    b: *mut TwigBuilder,
    format_ptr: *const u8,
    format_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        two_strings(b, format_ptr, format_len, text_ptr, text_len, out_id, |format, text| engine::Kind::RawBlock {
            format,
            text,
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_metadata(
    b: *mut TwigBuilder,
    lang_ptr: *const u8,
    lang_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        two_strings(b, lang_ptr, lang_len, text_ptr, text_len, out_id, |lang, text| engine::Kind::Metadata { lang, text })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_raw_inline(
    b: *mut TwigBuilder,
    format_ptr: *const u8,
    format_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        two_strings(b, format_ptr, format_len, text_ptr, text_len, out_id, |format, text| engine::Kind::RawInline {
            format,
            text,
        })
    }
}

/// `text` is validated as a slice and otherwise ignored: the spelling is
/// always the canonical one for `punct_kind`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_smart_punctuation(
    b: *mut TwigBuilder,
    punct_kind: c_int,
    text_ptr: *const u8,
    text_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            use engine::SmartPunctuationKind as P;
            let p = match punct_kind {
                0 => P::LeftSingleQuote,
                1 => P::RightSingleQuote,
                2 => P::LeftDoubleQuote,
                3 => P::RightDoubleQuote,
                4 => P::Ellipses,
                5 => P::EmDash,
                6 => P::EnDash,
                _ => return None,
            };
            slice_of(text_ptr, text_len)?;
            Some(engine::Kind::SmartPunctuation(p))
        })
    }
}

unsafe fn link_of(
    dest_ptr: *const u8,
    dest_len: usize,
    has_destination: c_int,
    ref_ptr: *const u8,
    ref_len: usize,
    has_reference: c_int,
) -> Option<Link> {
    let destination = if has_destination != 0 { Some(unsafe { slice_of(dest_ptr, dest_len) }?.to_vec()) } else { None };
    let reference = if has_reference != 0 { Some(unsafe { slice_of(ref_ptr, ref_len) }?.to_vec()) } else { None };
    Some(Link { destination, reference })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_link(
    b: *mut TwigBuilder,
    dest_ptr: *const u8,
    dest_len: usize,
    has_destination: c_int,
    ref_ptr: *const u8,
    ref_len: usize,
    has_reference: c_int,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            link_of(dest_ptr, dest_len, has_destination, ref_ptr, ref_len, has_reference).map(engine::Kind::Link)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_image(
    b: *mut TwigBuilder,
    dest_ptr: *const u8,
    dest_len: usize,
    has_destination: c_int,
    ref_ptr: *const u8,
    ref_len: usize,
    has_reference: c_int,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            link_of(dest_ptr, dest_len, has_destination, ref_ptr, ref_len, has_reference).map(engine::Kind::Image)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_directive(
    b: *mut TwigBuilder,
    form: c_int,
    name_ptr: *const u8,
    name_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            let f = match form {
                TWIG_DIRECTIVE_TEXT => engine::Form::InlineText,
                TWIG_DIRECTIVE_LEAF => engine::Form::BlockLeaf,
                TWIG_DIRECTIVE_CONTAINER => engine::Form::BlockFenced,
                _ => return None,
            };
            let name = slice_of(name_ptr, name_len)?;
            Some(engine::Kind::Container(Container::with_form(name, f)))
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_element(
    b: *mut TwigBuilder,
    name_ptr: *const u8,
    name_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || Some(engine::Kind::Container(Container::named(slice_of(name_ptr, name_len)?))))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_processing_instruction(
    b: *mut TwigBuilder,
    target_ptr: *const u8,
    target_len: usize,
    data_ptr: *const u8,
    data_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        two_strings(b, target_ptr, target_len, data_ptr, data_len, out_id, |target, data| {
            engine::Kind::ProcessingInstruction { target, data }
        })
    }
}

/// The one-label constructors.
unsafe fn labelled(
    b: *mut TwigBuilder,
    label_ptr: *const u8,
    label_len: usize,
    out_id: *mut u32,
    make: impl FnOnce(Vec<u8>) -> engine::Kind,
) -> TwigStatus {
    unsafe { emit_node(b, out_id, || Some(make(slice_of(label_ptr, label_len)?.to_vec()))) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_footnote(
    b: *mut TwigBuilder,
    label_ptr: *const u8,
    label_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe { labelled(b, label_ptr, label_len, out_id, |label| engine::Kind::Footnote { label }) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_citation(
    b: *mut TwigBuilder,
    label_ptr: *const u8,
    label_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe { labelled(b, label_ptr, label_len, out_id, |label| engine::Kind::Citation { label }) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_substitution(
    b: *mut TwigBuilder,
    label_ptr: *const u8,
    label_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe { labelled(b, label_ptr, label_len, out_id, |label| engine::Kind::Substitution { label }) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_reference(
    b: *mut TwigBuilder,
    label_ptr: *const u8,
    label_len: usize,
    dest_ptr: *const u8,
    dest_len: usize,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        two_strings(b, label_ptr, label_len, dest_ptr, dest_len, out_id, |label, destination| {
            engine::Kind::Reference { label, destination }
        })
    }
}

/// The list constructors also record their SPELLING (a bullet style, an
/// ordered delimiter) in the builder's spelling side-table.
unsafe fn emit_spelled(b: *mut TwigBuilder, out_id: *mut u32, kind: Option<engine::Kind>, spelling: Option<Spelling>) -> TwigStatus {
    let (Some(kind), Some(spelling)) = (kind, spelling) else {
        return TWIG_STATUS_INVALID_ARGUMENT;
    };
    let status = unsafe { emit_node(b, out_id, || Some(kind)) };
    if status == TWIG_STATUS_OK {
        // SAFETY: OK means both pointers were non-NULL and `out_id` written.
        unsafe {
            let id = *out_id;
            builder(b).expect("checked by emit_node").builder.set_spelling(id, spelling);
        }
    }
    status
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_bullet_list(b: *mut TwigBuilder, style: c_int, tight: c_int, out_id: *mut u32) -> TwigStatus {
    let bullet = match style {
        0 => Some(edoc::Bullet::Dash),
        1 => Some(edoc::Bullet::Plus),
        2 => Some(edoc::Bullet::Star),
        _ => None,
    };
    unsafe {
        emit_spelled(b, out_id, Some(engine::Kind::BulletList { tight: tight != 0 }), bullet.map(Spelling::Bullet))
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_ordered_list(
    b: *mut TwigBuilder,
    numbering: c_int,
    delim: c_int,
    tight: c_int,
    start: u32,
    has_start: c_int,
    out_id: *mut u32,
) -> TwigStatus {
    use engine::ListNumbering as N;
    let numbering = match numbering {
        0 => Some(N::Decimal),
        1 => Some(N::LowerAlpha),
        2 => Some(N::UpperAlpha),
        3 => Some(N::LowerRoman),
        4 => Some(N::UpperRoman),
        _ => None,
    };
    let delim = match delim {
        0 => Some(edoc::OrderedDelim::Period),
        1 => Some(edoc::OrderedDelim::ParenAfter),
        2 => Some(edoc::OrderedDelim::ParenBoth),
        _ => None,
    };
    let kind = numbering.map(|numbering| engine::Kind::OrderedList {
        numbering,
        tight: tight != 0,
        start: if has_start != 0 { Some(start) } else { None },
    });
    unsafe { emit_spelled(b, out_id, kind, delim.map(Spelling::OrderedDelim)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_task_list(b: *mut TwigBuilder, tight: c_int, out_id: *mut u32) -> TwigStatus {
    unsafe { emit_node(b, out_id, || Some(engine::Kind::TaskList { tight: tight != 0 })) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_task_list_item(b: *mut TwigBuilder, checked: c_int, out_id: *mut u32) -> TwigStatus {
    unsafe { emit_node(b, out_id, || Some(engine::Kind::TaskListItem { checked: checked != 0 })) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_row(b: *mut TwigBuilder, head: c_int, out_id: *mut u32) -> TwigStatus {
    unsafe { emit_node(b, out_id, || Some(engine::Kind::Row { head: head != 0 })) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_line(b: *mut TwigBuilder, indent: u32, out_id: *mut u32) -> TwigStatus {
    unsafe { emit_node(b, out_id, || Some(engine::Kind::Line { indent })) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_cell(b: *mut TwigBuilder, head: c_int, alignment: c_int, out_id: *mut u32) -> TwigStatus {
    unsafe { twig_builder_add_cell_spanning(b, head, alignment, 1, 1, out_id) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_add_cell_spanning(
    b: *mut TwigBuilder,
    head: c_int,
    alignment: c_int,
    colspan: u32,
    rowspan: u32,
    out_id: *mut u32,
) -> TwigStatus {
    unsafe {
        emit_node(b, out_id, || {
            let alignment = alignment_of(alignment)?;
            if colspan == 0 || rowspan == 0 {
                return None;
            }
            Some(engine::Kind::Cell(Cell { head: head != 0, alignment, colspan, rowspan }))
        })
    }
}

// ── structure & attributes ──────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_set_children(
    b: *mut TwigBuilder,
    parent: u32,
    ids_ptr: *const u32,
    ids_len: usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { builder(b) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        let count = h.builder.len();
        if parent as usize >= count {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(ids) = (unsafe { array_of(ids_ptr, ids_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if ids.iter().any(|&id| id as usize >= count) {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        h.builder.set_children(parent, ids);
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_set_attrs(
    b: *mut TwigBuilder,
    id: u32,
    kvs_ptr: *const TwigKeyVal,
    kvs_len: usize,
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { builder(b) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if id as usize >= h.builder.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        let Some(entries) = (unsafe { key_vals(kvs_ptr, kvs_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        h.builder.set_attrs(id, Attrs { entries });
        TWIG_STATUS_OK
    })
}

// ── render / serialize / inspect ────────────────────────────────────────────

/// `viewDocument("", root)`: the subtree at `root` over no source.
fn view_document(h: &BuilderHandle, root: u32) -> Document {
    h.builder.clone().finish_document(b"", root)
}


/// `serializeBuiltAst`: always from the bare tree, carrying the builder's
/// spelling table where the target reads one.
fn serialize_built_ast(doc: &Document, target: reg::Target) -> Result<Vec<u8>, TwigStatus> {
    let ast = &doc.ast;
    Ok(match target {
        reg::Target::Djot => languages::djot::serializer::serialize_ast_spelled(ast, &doc.node_spelling),
        reg::Target::Markdown => languages::markdown::serializer::serialize_ast_spelled(ast, &doc.node_spelling),
        reg::Target::Html => languages::html::serialize_alloc(ast, None).map_err(|_| TWIG_STATUS_UNSAFE_METADATA)?,
        // XML's printer spells only the generic-markup kinds its own parser
        // produces, so a built tree holding a semantic kind is refused —
        // the unsupported-format the C ABI promises.
        reg::Target::Xml => languages::xml::serialize(doc).map_err(|_| TWIG_STATUS_UNSUPPORTED_FORMAT)?,
        reg::Target::Asciidoc => languages::asciidoc::serializer::serialize_ast_spelled(ast, &doc.node_spelling),
        reg::Target::Runtime(_) => reg::serialize_from_ast(target, ast).map_err(|e| match e {
            reg::PrintFailure::UnsafeMetadata => TWIG_STATUS_UNSAFE_METADATA,
            _ => TWIG_STATUS_UNSUPPORTED_FORMAT,
        })?,
    })
}

/// The shape every builder read shares: a valid handle, out-pointers, and a
/// root in range.
unsafe fn builder_read<T>(
    b: *mut TwigBuilder,
    root: u32,
    out_ptr: *mut *const T,
    out_len: *mut usize,
    read: impl FnOnce(&mut BuilderHandle) -> Result<(), TwigStatus>,
    buffer: impl FnOnce(&BuilderHandle) -> &[T],
) -> TwigStatus {
    guard(|| {
        let Some(h) = (unsafe { builder(b) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
        if out_ptr.is_null() || out_len.is_null() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        if root as usize >= h.builder.len() {
            return TWIG_STATUS_INVALID_ARGUMENT;
        }
        if let Err(status) = read(h) {
            return status;
        }
        let buf = buffer(h);
        unsafe {
            put(out_ptr, if buf.is_empty() { std::ptr::null() } else { buf.as_ptr() });
            put(out_len, buf.len());
        }
        TWIG_STATUS_OK
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_render_html(
    b: *mut TwigBuilder,
    root: u32,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe {
        builder_read(
            b,
            root,
            out_ptr,
            out_len,
            |h| {
                let ast = h.builder.view(root);
                h.rendered = languages::html::serialize_alloc(&ast, None).map_err(|_| TWIG_STATUS_UNSAFE_METADATA)?;
                Ok(())
            },
            |h| &h.rendered,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_serialize(
    b: *mut TwigBuilder,
    root: u32,
    format: c_int,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    if !b.is_null() && !out_ptr.is_null() && !out_len.is_null() && int_to_target(format).is_none() {
        return TWIG_STATUS_UNSUPPORTED_FORMAT;
    }
    unsafe {
        builder_read(
            b,
            root,
            out_ptr,
            out_len,
            |h| {
                let target = int_to_target(format).ok_or(TWIG_STATUS_UNSUPPORTED_FORMAT)?;
                let doc = view_document(h, root);
                h.serialized = serialize_built_ast(&doc, target)?;
                Ok(())
            },
            |h| &h.serialized,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_ast_json(
    b: *mut TwigBuilder,
    root: u32,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> TwigStatus {
    unsafe {
        builder_read(
            b,
            root,
            out_ptr,
            out_len,
            |h| {
                h.ast_json = twig::ast::json::encode(&view_document(h, root));
                Ok(())
            },
            |h| &h.ast_json,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twig_builder_query(
    b: *mut TwigBuilder,
    root: u32,
    selector_ptr: *const u8,
    selector_len: usize,
    out_ptr: *mut *const TwigQueryMatch,
    out_len: *mut usize,
) -> TwigStatus {
    let Some(selector) = (unsafe { slice_of(selector_ptr, selector_len) }) else { return TWIG_STATUS_INVALID_ARGUMENT };
    unsafe {
        builder_read(
            b,
            root,
            out_ptr,
            out_len,
            |h| {
                h.query_matches =
                    build_query_matches(&view_document(h, root), selector).ok_or(TWIG_STATUS_INVALID_ARGUMENT)?;
                Ok(())
            },
            |h| &h.query_matches,
        )
    }
}
