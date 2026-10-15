//! Inline scanning: the full CommonMark inline grammar plus twig's inline
//! extensions. Port of `src/languages/markdown/inline.zig`.
//!
//! ── Strategy ─────────────────────────────────────────────────────────────
//! Mirrors the strategy of CommonMark's spec appendix ("A parsing strategy")
//! and `cmark`'s `inlines.c`: a single left-to-right scan produces a flat
//! sequence of inline "items" (`Scanner::items`, a doubly-linked list built
//! over an arena array) — most items are already-finished AST nodes, but
//! `*`/`_` delimiter runs and `[`/`![` brackets are pushed as PLACEHOLDER
//! text items alongside a side-table entry on a delimiter stack or bracket
//! stack. Links/images resolve eagerly, right when their closing `]` is
//! scanned; emphasis resolves lazily, via the bottom-up `process_emphasis`
//! pass over the delimiter stack, run once over each link/image's contents
//! and once more over whatever's left at the very end of the scan.
//!
//! ── Reference links resolve at PARSE time ───────────────────────────────
//! CommonMark reference links/images are resolved HERE, against the
//! document's `labels.references` (threaded in as `link_refs`), producing a
//! `link`/`image` node with `destination` set and `reference == None`. The
//! block parser defers calling the scanner until the WHOLE document's block
//! structure has been parsed, so forward references resolve correctly.
//!
//! ── Documented approximations ───────────────────────────────────────────
//! - Emphasis flanking classifies "Unicode whitespace"/"punctuation" fully
//!   for ASCII but only approximately (a curated table) for non-ASCII.
//! - `process_emphasis` omits cmark's `openers_bottom` memoization.
//! - Reference-form fallback: an invalid second `[...]` falls back to the
//!   SHORTCUT form.

use std::collections::HashMap;

use crate::ast::{Attrs, Builder, Container, Form, InlineMark, KeyVal, Kind, Link, NodeId, TextLeafKind};
use crate::document::{ContainerOrigin, Document, HighlightPrefix, Spelling};
use crate::span::Span;

use super::attributes as attrs_mod;
use super::entities;
use super::highlight;
use super::options::ParseOptions;

/// Normalized label -> the `reference` node holding that definition.
pub type LinkRefs = HashMap<Vec<u8>, NodeId>;

/// One contiguous run of a leaf block's assembled `text` that maps 1:1 onto
/// real source bytes: `text[buf_offset..buf_offset+len]` is byte-for-byte
/// identical to `source[src_offset..src_offset+len]`. A `text` byte not
/// covered by any segment (e.g. a synthetic line-join separator) has no
/// source mapping.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Segment {
    pub buf_offset: usize,
    pub src_offset: usize,
    pub len: usize,
}

// ── bridges to the HTML module ──────────────────────────────────────────

/// Parse `src` with the shared HTML parser (`languages/html`'s `parse`).
pub(crate) fn html_parse(src: &[u8]) -> Document {
    crate::languages::html::parse(src)
}

/// `languages/html/serializer.zig`'s `isVoidElement`.
pub(crate) fn is_void_element(name: &[u8]) -> bool {
    crate::languages::html::is_void_element(name)
}

// ── Zig `std` helpers, byte-faithful ────────────────────────────────────

pub(crate) fn trim<'s>(s: &'s [u8], chars: &[u8]) -> &'s [u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && chars.contains(&s[a]) {
        a += 1;
    }
    while b > a && chars.contains(&s[b - 1]) {
        b -= 1;
    }
    &s[a..b]
}

pub(crate) fn trim_start<'s>(s: &'s [u8], chars: &[u8]) -> &'s [u8] {
    let mut a = 0;
    while a < s.len() && chars.contains(&s[a]) {
        a += 1;
    }
    &s[a..]
}

pub(crate) fn trim_end<'s>(s: &'s [u8], chars: &[u8]) -> &'s [u8] {
    let mut b = s.len();
    while b > 0 && chars.contains(&s[b - 1]) {
        b -= 1;
    }
    &s[..b]
}

pub(crate) fn index_of(hay: &[u8], start: usize, needle: &[u8]) -> Option<usize> {
    if start > hay.len() {
        return None;
    }
    if needle.is_empty() {
        return Some(start);
    }
    hay[start..].windows(needle.len()).position(|w| w == needle).map(|p| p + start)
}

pub(crate) fn index_of_scalar(hay: &[u8], start: usize, c: u8) -> Option<usize> {
    if start > hay.len() {
        return None;
    }
    hay[start..].iter().position(|&x| x == c).map(|p| p + start)
}

/// `std.ascii.isWhitespace`: space, `\t`, `\n`, `\r`, VT, FF.
pub(crate) fn is_ascii_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0B | 0x0C)
}

/// `std.unicode.utf8ByteSequenceLength`.
pub(crate) fn utf8_seq_len(b: u8) -> Option<usize> {
    match b {
        0x00..=0x7F => Some(1),
        0xC0..=0xDF => Some(2),
        0xE0..=0xEF => Some(3),
        0xF0..=0xF7 => Some(4),
        _ => None,
    }
}

/// `std.unicode.utf8Decode` (asserts ignored, as in a release build).
pub(crate) fn utf8_decode(bytes: &[u8]) -> Option<u32> {
    let cont = |b: u8| b & 0xC0 == 0x80;
    match bytes.len() {
        1 => Some(bytes[0] as u32),
        2 => {
            let mut v = (bytes[0] & 0x1F) as u32;
            if !cont(bytes[1]) {
                return None;
            }
            v = (v << 6) | (bytes[1] & 0x3F) as u32;
            if v < 0x80 {
                return None;
            }
            Some(v)
        }
        3 => {
            let mut v = (bytes[0] & 0x0F) as u32;
            if !cont(bytes[1]) {
                return None;
            }
            v = (v << 6) | (bytes[1] & 0x3F) as u32;
            if !cont(bytes[2]) {
                return None;
            }
            v = (v << 6) | (bytes[2] & 0x3F) as u32;
            if v < 0x800 {
                return None;
            }
            if (0xD800..=0xDFFF).contains(&v) {
                return None;
            }
            Some(v)
        }
        4 => {
            let mut v = (bytes[0] & 0x07) as u32;
            for &b in &bytes[1..4] {
                if !cont(b) {
                    return None;
                }
                v = (v << 6) | (b & 0x3F) as u32;
            }
            if v < 0x10000 || v > 0x10FFFF {
                return None;
            }
            Some(v)
        }
        _ => None,
    }
}

/// `std.unicode.utf8Encode`; `None` for a surrogate or out-of-range value.
pub(crate) fn utf8_encode(cp: u32, out: &mut Vec<u8>) -> bool {
    if cp < 0x80 {
        out.push(cp as u8);
    } else if cp < 0x800 {
        out.push(0xC0 | (cp >> 6) as u8);
        out.push(0x80 | (cp & 0x3F) as u8);
    } else if cp < 0x10000 {
        if (0xD800..=0xDFFF).contains(&cp) {
            return false;
        }
        out.push(0xE0 | (cp >> 12) as u8);
        out.push(0x80 | ((cp >> 6) & 0x3F) as u8);
        out.push(0x80 | (cp & 0x3F) as u8);
    } else if cp < 0x110000 {
        out.push(0xF0 | (cp >> 18) as u8);
        out.push(0x80 | ((cp >> 12) & 0x3F) as u8);
        out.push(0x80 | ((cp >> 6) & 0x3F) as u8);
        out.push(0x80 | (cp & 0x3F) as u8);
    } else {
        return false;
    }
    true
}

// ── entry points ────────────────────────────────────────────────────────

/// One-shot inline parse of `text` (a single leaf block's assembled content)
/// into a flat sequence of inline children added to `b` but not yet attached
/// to any parent. `link_refs` must already be COMPLETE. `segments` maps
/// `text` offsets back to absolute source offsets.
pub fn parse_inline(
    b: &mut Builder,
    text: &[u8],
    segments: &[Segment],
    link_refs: &LinkRefs,
    options: ParseOptions,
) -> Vec<NodeId> {
    let mut sc = Scanner::new(b, link_refs, options);
    sc.segments = segments.to_vec();
    run_scan(&mut sc, text)
}

/// A reusable inline `Scanner` (Zig's `initScanner`).
pub fn init_scanner<'a>(b: &'a mut Builder, link_refs: &'a LinkRefs, options: ParseOptions) -> Scanner<'a> {
    Scanner::new(b, link_refs, options)
}

/// Parse one inline block reusing `sc`'s buffers.
pub fn scan_reuse(sc: &mut Scanner<'_>, text: &[u8], segments: &[Segment]) -> Vec<NodeId> {
    sc.reset(segments);
    run_scan(sc, text)
}

/// A `str` node holding only ASCII whitespace — the HTML parser's layout text.
pub(crate) fn is_blank_str_node(kind: &Kind) -> bool {
    match kind {
        Kind::Str(t) => trim(t, b" \t\r\n\x0c").is_empty(),
        _ => false,
    }
}

/// Kinds a *self-contained* inline tag may promote to.
fn inline_safe_kind(kind: &Kind) -> bool {
    match kind {
        Kind::Image(_) | Kind::HardBreak => true,
        Kind::Container(c) => is_void_element(&c.name),
        _ => false,
    }
}

/// True when `tag` is a bare `<br>` void element in any of its spellings.
fn is_br_tag(tag: &[u8]) -> bool {
    if tag.len() < 4 || tag[0] != b'<' || tag[tag.len() - 1] != b'>' {
        return false;
    }
    if tag[1].to_ascii_lowercase() != b'b' || tag[2].to_ascii_lowercase() != b'r' {
        return false;
    }
    let mut j = 3;
    while j < tag.len() - 1 && (tag[j] == b' ' || tag[j] == b'\t') {
        j += 1;
    }
    if j < tag.len() - 1 && tag[j] == b'/' {
        j += 1;
    }
    while j < tag.len() - 1 && (tag[j] == b' ' || tag[j] == b'\t') {
        j += 1;
    }
    j == tag.len() - 1
}

struct MathMatch {
    kind: Kind,
    end: usize,
    content_start: usize,
    content_end: usize,
}

fn run_scan(sc: &mut Scanner<'_>, text: &[u8]) -> Vec<NodeId> {
    let mut i: usize = 0;
    while i < text.len() {
        if sc.buf.is_empty() {
            sc.buf_start = i;
            sc.buf_pure = true;
        }
        let c = text[i];
        match c {
            b'\\' => {
                if i + 1 < text.len() && text[i + 1] == b'\n' {
                    sc.flush_buf(i);
                    let id = sc.b.add_leaf(Kind::HardBreak);
                    sc.set_span_if_mapped(id, i, i + 2);
                    sc.append_item(id);
                    i += 2;
                    i = skip_leading_line_space(text, i);
                    continue;
                }
                if i + 1 < text.len() && is_ascii_punct(text[i + 1]) {
                    sc.buf.push(text[i + 1]);
                    sc.buf_pure = false;
                    i += 2;
                    continue;
                }
                sc.buf.push(b'\\');
                i += 1;
            }
            b'\n' => {
                let hard = trailing_hard_break_spaces(&sc.buf);
                let nl = sc.buf.len() - hard;
                sc.buf.truncate(nl);
                sc.flush_buf(i - hard);
                let kind = if hard >= 2 { Kind::HardBreak } else { Kind::SoftBreak };
                let id = sc.b.add_leaf(kind);
                sc.set_span_if_mapped(id, i - hard, i + 1);
                sc.append_item(id);
                i += 1;
                i = skip_leading_line_space(text, i);
            }
            b'`' => {
                if let Some(span) = scan_code_span(text, i) {
                    sc.flush_buf(i);
                    let content = normalize_code_span(&text[span.content_start..span.content_end]);
                    let id = sc.b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::Verbatim, text: content });
                    sc.set_span_if_mapped(id, i, span.end);
                    sc.set_content_span_if_mapped(id, span.content_start, span.content_end);
                    sc.append_item(id);
                    i = span.end;
                } else {
                    let mut run_end = i;
                    while run_end < text.len() && text[run_end] == b'`' {
                        run_end += 1;
                    }
                    sc.buf.extend_from_slice(&text[i..run_end]);
                    i = run_end;
                }
            }
            b'&' => {
                if let Some((rtext, end)) = decode_char_ref(text, i) {
                    sc.buf.extend_from_slice(&rtext);
                    sc.buf_pure = false;
                    i = end;
                } else {
                    sc.buf.push(b'&');
                    i += 1;
                }
            }
            b'<' => {
                let paired = if sc.options.html_elements { try_paired_tag(sc, text, i) } else { None };
                if let Some(end) = paired {
                    i = end;
                } else if let Some(end) = scan_autolink_uri(text, i) {
                    sc.flush_buf(i);
                    let id = sc
                        .b
                        .add_leaf(Kind::TextLeaf { kind: TextLeafKind::Url, text: text[i + 1..end - 1].to_vec() });
                    sc.set_span_if_mapped(id, i, end);
                    sc.set_content_span_if_mapped(id, i + 1, end - 1);
                    sc.append_item(id);
                    i = end;
                } else if let Some(end) = scan_autolink_email(text, i) {
                    sc.flush_buf(i);
                    let id = sc
                        .b
                        .add_leaf(Kind::TextLeaf { kind: TextLeafKind::Email, text: text[i + 1..end - 1].to_vec() });
                    sc.set_span_if_mapped(id, i, end);
                    sc.set_content_span_if_mapped(id, i + 1, end - 1);
                    sc.append_item(id);
                    i = end;
                } else if let Some(end) = scan_html_tag(text, i) {
                    sc.flush_buf(i);
                    let promote = sc.options.html_elements || (sc.in_cell && is_br_tag(&text[i..end]));
                    if !(promote && sc.promote_inline_html(text, i, end)) {
                        let id = sc
                            .b
                            .add_leaf(Kind::RawInline { format: b"html".to_vec(), text: text[i..end].to_vec() });
                        sc.set_span_if_mapped(id, i, end);
                        sc.append_item(id);
                    }
                    i = end;
                } else {
                    sc.buf.push(b'<');
                    i += 1;
                }
            }
            b'*' | b'_' => {
                let mut run_end = i;
                while run_end < text.len() && text[run_end] == c {
                    run_end += 1;
                }
                let flank = compute_flanking(text, i, run_end, c);
                if flank.can_open || flank.can_close {
                    sc.flush_buf(i);
                    let run_id = sc.b.add_leaf(Kind::Str(text[i..run_end].to_vec()));
                    sc.set_span_if_mapped(run_id, i, run_end);
                    let item_idx = sc.append_item(run_id);
                    sc.delims.push(Delim {
                        item: item_idx,
                        ch: c,
                        count: run_end - i,
                        color: None,
                        can_open: flank.can_open,
                        can_close: flank.can_close,
                        range_start: i,
                        range_end: run_end,
                    });
                } else {
                    sc.buf.extend_from_slice(&text[i..run_end]);
                }
                i = run_end;
            }
            b'[' => {
                if sc.options.footnotes {
                    if let Some(fr) = try_footnote_reference(text, i) {
                        sc.flush_buf(i);
                        let norm = normalize_ref_label(fr.label);
                        let id = sc.b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::FootnoteReference, text: norm });
                        sc.set_span_if_mapped(id, i, fr.end);
                        sc.set_content_span_if_mapped(id, i + 2, fr.end - 1);
                        sc.append_item(id);
                        i = fr.end;
                        continue;
                    }
                }
                sc.flush_buf(i);
                let open_id = sc.b.add_leaf(Kind::Str(b"[".to_vec()));
                sc.set_span_if_mapped(open_id, i, i + 1);
                let item_idx = sc.append_item(open_id);
                let dl = sc.delims.len();
                sc.brackets.push(Bracket {
                    item: item_idx,
                    is_image: false,
                    active: true,
                    open_start: i,
                    content_start: i + 1,
                    delim_stack_len: dl,
                });
                i += 1;
            }
            b'!' => {
                if i + 1 < text.len() && text[i + 1] == b'[' {
                    sc.flush_buf(i);
                    let open_id = sc.b.add_leaf(Kind::Str(b"![".to_vec()));
                    sc.set_span_if_mapped(open_id, i, i + 2);
                    let item_idx = sc.append_item(open_id);
                    let dl = sc.delims.len();
                    sc.brackets.push(Bracket {
                        item: item_idx,
                        is_image: true,
                        active: true,
                        open_start: i,
                        content_start: i + 2,
                        delim_stack_len: dl,
                    });
                    i += 2;
                } else {
                    sc.buf.push(b'!');
                    i += 1;
                }
            }
            b']' => {
                sc.flush_buf(i);
                i = handle_close_bracket(sc, text, i);
            }
            b'~' => {
                let mut run_end = i;
                while run_end < text.len() && text[run_end] == b'~' {
                    run_end += 1;
                }
                let run_len = run_end - i;
                let flank = if sc.options.strikethrough {
                    compute_flanking(text, i, run_end, b'~')
                } else {
                    Flank { can_open: false, can_close: false }
                };
                if run_len <= 2 && (flank.can_open || flank.can_close) {
                    sc.flush_buf(i);
                    let run_id = sc.b.add_leaf(Kind::Str(text[i..run_end].to_vec()));
                    sc.set_span_if_mapped(run_id, i, run_end);
                    let item_idx = sc.append_item(run_id);
                    sc.delims.push(Delim {
                        item: item_idx,
                        ch: b'~',
                        count: run_len,
                        color: None,
                        can_open: flank.can_open,
                        can_close: flank.can_close,
                        range_start: i,
                        range_end: run_end,
                    });
                } else {
                    sc.buf.extend_from_slice(&text[i..run_end]);
                }
                i = run_end;
            }
            b'=' => {
                let mut run_end = i;
                while run_end < text.len() && text[run_end] == b'=' {
                    run_end += 1;
                }
                let run_len = run_end - i;
                let flank = if sc.options.highlight && run_len == 2 {
                    compute_flanking(text, i, run_end, b'=')
                } else {
                    Flank { can_open: false, can_close: false }
                };
                if flank.can_open || flank.can_close {
                    sc.flush_buf(i);
                    let run_id = sc.b.add_leaf(Kind::Str(text[i..run_end].to_vec()));
                    sc.set_span_if_mapped(run_id, i, run_end);
                    let item_idx = sc.append_item(run_id);
                    let mut color: Option<ColorPrefix> = None;
                    if sc.options.highlight_colors && flank.can_open {
                        if let Some(p) = highlight::parse_prefix(&text[run_end..]) {
                            let pfx_end = run_end + p.len;
                            let pfx_id = sc.b.add_leaf(Kind::Str(text[run_end..pfx_end].to_vec()));
                            sc.set_span_if_mapped(pfx_id, run_end, pfx_end);
                            let pfx_item = sc.append_item(pfx_id);
                            color = Some(ColorPrefix {
                                item: pfx_item,
                                color: p.color,
                                spaced: p.spaced,
                                start: run_end,
                                end: pfx_end,
                            });
                            run_end = pfx_end;
                        }
                    }
                    sc.delims.push(Delim {
                        item: item_idx,
                        ch: b'=',
                        count: run_len,
                        color,
                        can_open: flank.can_open,
                        can_close: flank.can_close,
                        range_start: i,
                        range_end: i + run_len,
                    });
                } else {
                    sc.buf.extend_from_slice(&text[i..run_end]);
                }
                i = run_end;
            }
            b'$' => {
                let mut matched: Option<MathMatch> = None;
                if sc.options.math {
                    if i + 1 < text.len() && text[i + 1] == b'$' {
                        if let Some(m) = scan_display_math(text, i) {
                            matched = Some(MathMatch {
                                kind: Kind::TextLeaf {
                                    kind: TextLeafKind::DisplayMath,
                                    text: text[i + 2..m.content_end].to_vec(),
                                },
                                end: m.end,
                                content_start: i + 2,
                                content_end: m.content_end,
                            });
                        }
                    } else if let Some(m) = scan_inline_math(text, i) {
                        matched = Some(MathMatch {
                            kind: Kind::TextLeaf {
                                kind: TextLeafKind::InlineMath,
                                text: text[i + 1..m.content_end].to_vec(),
                            },
                            end: m.end,
                            content_start: i + 1,
                            content_end: m.content_end,
                        });
                    }
                }
                if let Some(m) = matched {
                    sc.flush_buf(i);
                    let id = sc.b.add_leaf(m.kind);
                    sc.set_span_if_mapped(id, i, m.end);
                    sc.set_content_span_if_mapped(id, m.content_start, m.content_end);
                    sc.append_item(id);
                    i = m.end;
                } else {
                    sc.buf.push(b'$');
                    i += 1;
                }
            }
            b'h' | b'f' | b'w' => {
                let auto_end = if sc.options.autolinks && !sc.in_bracket() {
                    if c == b'w' {
                        try_ext_www_autolink(sc, text, i)
                    } else {
                        try_ext_url_autolink(sc, text, i)
                    }
                } else {
                    None
                };
                if let Some(end) = auto_end {
                    i = end;
                } else {
                    sc.buf.push(c);
                    i += 1;
                }
            }
            b'@' => {
                let auto_end = if sc.options.autolinks { try_ext_email_autolink(sc, text, i) } else { None };
                if let Some(end) = auto_end {
                    i = end;
                } else {
                    sc.buf.push(b'@');
                    i += 1;
                }
            }
            b':' => {
                let nestable = sc.directive_depth < MAX_DIRECTIVE_NESTING;
                let td = if sc.options.directives && nestable { scan_text_directive(text, i) } else { None };
                if let Some(d) = td {
                    sc.flush_buf(i);
                    let end = d.end;
                    let label = d.label;
                    let id = build_text_directive(sc, d);
                    sc.set_span_if_mapped(id, i, end);
                    if let Some(lab) = label {
                        sc.set_content_span_if_mapped(id, lab.start, lab.end);
                    }
                    sc.append_item(id);
                    i = end;
                } else {
                    sc.buf.push(b':');
                    i += 1;
                }
            }
            _ => {
                sc.buf.push(c);
                i += 1;
            }
        }
    }
    sc.flush_buf(text.len());
    sc.process_emphasis(0);

    let mut out = Vec::new();
    let mut cur = sc.head;
    while let Some(ci) = cur {
        out.push(sc.items[ci as usize].node);
        cur = sc.items[ci as usize].next;
    }
    out
}

/// Backslash-escape and entity/numeric-character-reference decoding only —
/// for info strings, link destinations/titles.
pub fn decode_text(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        let c = text[i];
        if c == b'\\' && i + 1 < text.len() && is_ascii_punct(text[i + 1]) {
            out.push(text[i + 1]);
            i += 2;
        } else if c == b'&' {
            if let Some((r, end)) = decode_char_ref(text, i) {
                out.extend_from_slice(&r);
                i = end;
            } else {
                out.push(c);
                i += 1;
            }
        } else {
            out.push(c);
            i += 1;
        }
    }
    out
}

// ── the item list / delimiter stack / bracket stack ─────────────────────

type ItemIdx = u32;

#[derive(Clone, Copy, Debug)]
struct Item {
    node: NodeId,
    prev: Option<ItemIdx>,
    next: Option<ItemIdx>,
}

/// Whether `ch` is an EXTENSION delimiter on the emphasis stack (`~`, `=`).
fn is_ext_delim_char(ch: u8) -> bool {
    ch == b'~' || ch == b'='
}

fn ext_delim_mark(ch: u8) -> InlineMark {
    match ch {
        b'~' => InlineMark::Delete,
        b'=' => InlineMark::Mark,
        _ => unreachable!(),
    }
}

#[derive(Clone, Copy, Debug)]
struct Delim {
    item: ItemIdx,
    ch: u8,
    count: usize,
    color: Option<ColorPrefix>,
    can_open: bool,
    can_close: bool,
    range_start: usize,
    range_end: usize,
}

#[derive(Clone, Copy, Debug)]
struct ColorPrefix {
    item: ItemIdx,
    color: highlight::Color,
    spaced: bool,
    start: usize,
    end: usize,
}

#[derive(Clone, Copy, Debug)]
struct Bracket {
    item: ItemIdx,
    is_image: bool,
    active: bool,
    open_start: usize,
    content_start: usize,
    delim_stack_len: usize,
}

/// The inline scanner. `b`, `link_refs`, `options` are document-constant.
pub struct Scanner<'a> {
    pub b: &'a mut Builder,
    pub link_refs: &'a LinkRefs,
    pub options: ParseOptions,
    /// True while scanning a table cell's inline content: a `<br>` raw
    /// inline promotes to a `hard_break` there.
    pub in_cell: bool,
    /// How many text directives enclose this scan.
    pub directive_depth: u8,
    segments: Vec<Segment>,
    buf: Vec<u8>,
    buf_start: usize,
    buf_pure: bool,
    items: Vec<Item>,
    head: Option<ItemIdx>,
    tail: Option<ItemIdx>,
    delims: Vec<Delim>,
    brackets: Vec<Bracket>,
    ext_emails: Vec<NodeId>,
}

impl<'a> Scanner<'a> {
    fn new(b: &'a mut Builder, link_refs: &'a LinkRefs, options: ParseOptions) -> Scanner<'a> {
        Scanner {
            b,
            link_refs,
            options,
            in_cell: false,
            directive_depth: 0,
            segments: Vec::new(),
            buf: Vec::new(),
            buf_start: 0,
            buf_pure: true,
            items: Vec::new(),
            head: None,
            tail: None,
            delims: Vec::new(),
            brackets: Vec::new(),
            ext_emails: Vec::new(),
        }
    }

    fn reset(&mut self, segments: &[Segment]) {
        self.buf.clear();
        self.items.clear();
        self.delims.clear();
        self.brackets.clear();
        self.ext_emails.clear();
        self.buf_start = 0;
        self.buf_pure = true;
        self.head = None;
        self.tail = None;
        self.segments.clear();
        self.segments.extend_from_slice(segments);
    }

    /// Whether an UNCLOSED `[`/`![` sits to the left in this block (ignores
    /// `Bracket::active`, matching cmark's `in_bracket`).
    fn in_bracket(&self) -> bool {
        !self.brackets.is_empty()
    }

    fn map_span(&self, local_start: usize, local_end: usize) -> Option<Span> {
        if local_end < local_start {
            return None;
        }
        for seg in &self.segments {
            if local_start >= seg.buf_offset && local_end <= seg.buf_offset + seg.len {
                let delta = local_start - seg.buf_offset;
                return Some(Span::new(seg.src_offset + delta, seg.src_offset + delta + (local_end - local_start)));
            }
        }
        let src_start = map_point(&self.segments, local_start, false)?;
        let src_end = map_point(&self.segments, local_end, true)?;
        if src_end < src_start {
            return None;
        }
        Some(Span::new(src_start, src_end))
    }

    fn set_span_if_mapped(&mut self, id: NodeId, s: usize, e: usize) {
        if let Some(sp) = self.map_span(s, e) {
            self.b.set_span(id, sp);
        }
    }

    fn set_content_span_if_mapped(&mut self, id: NodeId, s: usize, e: usize) {
        if let Some(sp) = self.map_span(s, e) {
            self.b.set_content_span(id, sp);
        }
    }

    fn set_marker_span_if_mapped(&mut self, id: NodeId, s: usize, e: usize) {
        if let Some(sp) = self.map_span(s, e) {
            self.b.set_marker_span(id, sp);
        }
    }

    /// `options.html_elements`: promote a self-contained raw inline HTML tag
    /// into a real AST node. Returns `true` on success.
    fn promote_inline_html(&mut self, text: &[u8], tag_start: usize, tag_end: usize) -> bool {
        let tag_doc = html_parse(&text[tag_start..tag_end]);
        let mut chosen: Option<NodeId> = None;
        for child in tag_doc.ast.children(tag_doc.ast.root) {
            if is_blank_str_node(&child.kind) {
                continue;
            }
            if chosen.is_some() {
                return false;
            }
            chosen = Some(child.id);
        }
        let Some(src_id) = chosen else { return false };
        if !inline_safe_kind(&tag_doc.ast.nodes[src_id as usize].kind) {
            return false;
        }
        let base = self.b.nodes.len() as NodeId;
        self.b.graft_document(&tag_doc, 0);
        for idx in base as usize..self.b.nodes.len() {
            let span = self.b.spans[idx];
            if let Some(sp) = self.map_span(span.start + tag_start, span.end + tag_start) {
                self.b.spans[idx] = sp;
            }
            if let Some(cs) = self.b.content_spans[idx] {
                if let Some(sp) = self.map_span(cs.start + tag_start, cs.end + tag_start) {
                    self.b.content_spans[idx] = Some(sp);
                }
            }
        }
        let grafted = base + src_id;
        self.b.nodes[grafted as usize].next_sibling = None;
        self.append_item(grafted);
        true
    }

    fn flush_buf(&mut self, end: usize) {
        if self.buf.is_empty() {
            return;
        }
        let id = self.b.add_leaf(Kind::Str(self.buf.clone()));
        self.set_span_if_mapped(id, self.buf_start, end);
        self.append_item(id);
        self.buf.clear();
    }

    fn flush_buf_no_span(&mut self) {
        if self.buf.is_empty() {
            return;
        }
        let id = self.b.add_leaf(Kind::Str(self.buf.clone()));
        self.append_item(id);
        self.buf.clear();
    }

    fn append_item(&mut self, node: NodeId) -> ItemIdx {
        self.insert_item_between(self.tail, None, node)
    }

    fn insert_item_between(&mut self, left: Option<ItemIdx>, right: Option<ItemIdx>, node: NodeId) -> ItemIdx {
        let idx = self.items.len() as ItemIdx;
        self.items.push(Item { node, prev: left, next: right });
        match left {
            Some(l) => self.items[l as usize].next = Some(idx),
            None => self.head = Some(idx),
        }
        match right {
            Some(r) => self.items[r as usize].prev = Some(idx),
            None => self.tail = Some(idx),
        }
        idx
    }

    fn remove_delim_range(&mut self, start: usize, end: usize) {
        if end <= start {
            return;
        }
        self.delims.drain(start..end);
    }

    /// CommonMark's `process_emphasis` over `delims[stack_bottom..]`.
    fn process_emphasis(&mut self, stack_bottom: usize) {
        let mut closer_idx = stack_bottom;
        while closer_idx < self.delims.len() {
            let closer = self.delims[closer_idx];
            if !closer.can_close {
                closer_idx += 1;
                continue;
            }

            let mut opener_idx: Option<usize> = None;
            if closer_idx > stack_bottom {
                let mut k = closer_idx;
                while k > stack_bottom {
                    k -= 1;
                    let cand = self.delims[k];
                    if cand.can_open && cand.ch == closer.ch {
                        if is_ext_delim_char(closer.ch) {
                            if cand.count != closer.count {
                                continue;
                            }
                            opener_idx = Some(k);
                            break;
                        }
                        if (cand.can_open && cand.can_close) || (closer.can_open && closer.can_close) {
                            let sum = cand.count + closer.count;
                            if sum % 3 == 0 && !(cand.count % 3 == 0 && closer.count % 3 == 0) {
                                continue;
                            }
                        }
                        opener_idx = Some(k);
                        break;
                    }
                }
            }

            if let Some(oi) = opener_idx {
                let use_delims = if is_ext_delim_char(closer.ch) {
                    closer.count
                } else if self.delims[oi].count >= 2 && closer.count >= 2 {
                    2
                } else {
                    1
                };
                let ch = closer.ch;
                let opener_item = self.delims[oi].item;
                let closer_item = self.delims[closer_idx].item;

                let color = if ch == b'=' { self.delims[oi].color } else { None };
                let mut kids = Vec::new();
                let mut cur = match color {
                    Some(c) => self.items[c.item as usize].next,
                    None => self.items[opener_item as usize].next,
                };
                while let Some(ci) = cur {
                    if ci == closer_item {
                        break;
                    }
                    kids.push(self.items[ci as usize].node);
                    cur = self.items[ci as usize].next;
                }
                let kind = if is_ext_delim_char(ch) {
                    ext_delim_mark(ch)
                } else if use_delims == 2 {
                    InlineMark::Strong
                } else {
                    InlineMark::Emph
                };
                let new_node = self.b.add_container(Kind::InlineMark(kind), &kids);
                if let Some(c) = color {
                    self.b.set_attrs(
                        new_node,
                        Attrs { entries: vec![KeyVal::new(highlight::ATTR_KEY.as_bytes(), Some(c.color.name().as_bytes()))] },
                    );
                    self.b.set_spelling(
                        new_node,
                        Spelling::HighlightPrefix(if c.spaced { HighlightPrefix::Spaced } else { HighlightPrefix::Tight }),
                    );
                    self.set_marker_span_if_mapped(new_node, c.start, c.end);
                }

                let content_start = match color {
                    Some(c) => c.end,
                    None => self.delims[oi].range_end,
                };
                let content_end = self.delims[closer_idx].range_start;

                self.delims[oi].count -= use_delims;
                self.delims[closer_idx].count -= use_delims;
                self.delims[oi].range_end -= use_delims;
                self.delims[closer_idx].range_start += use_delims;
                let opener_count = self.delims[oi].count;
                let closer_count = self.delims[closer_idx].count;

                let (ore, crs) = (self.delims[oi].range_end, self.delims[closer_idx].range_start);
                self.set_span_if_mapped(new_node, ore, crs);
                self.set_content_span_if_mapped(new_node, content_start, content_end);

                let o = self.delims[oi];
                let cl = self.delims[closer_idx];
                self.splice_emphasis(
                    opener_item,
                    opener_count,
                    o.range_start,
                    o.range_end,
                    closer_item,
                    closer_count,
                    cl.range_start,
                    cl.range_end,
                    ch,
                    new_node,
                );

                let del_start = if opener_count > 0 { oi + 1 } else { oi };
                let del_end = if closer_count > 0 { closer_idx } else { closer_idx + 1 };
                self.remove_delim_range(del_start, del_end);
                closer_idx = del_start;
            } else if !closer.can_open {
                self.remove_delim_range(closer_idx, closer_idx + 1);
            } else {
                closer_idx += 1;
            }
        }
        self.delims.truncate(stack_bottom);
    }

    #[allow(clippy::too_many_arguments)]
    fn splice_emphasis(
        &mut self,
        opener_item: ItemIdx,
        opener_count: usize,
        opener_range_start: usize,
        opener_range_end: usize,
        closer_item: ItemIdx,
        closer_count: usize,
        closer_range_start: usize,
        closer_range_end: usize,
        ch: u8,
        new_node: NodeId,
    ) {
        let left = if opener_count > 0 {
            let run_id = self.b.add_leaf(Kind::Str(vec![ch; opener_count]));
            self.set_span_if_mapped(run_id, opener_range_start, opener_range_end);
            self.items[opener_item as usize].node = run_id;
            Some(opener_item)
        } else {
            self.items[opener_item as usize].prev
        };
        let right = if closer_count > 0 {
            let run_id = self.b.add_leaf(Kind::Str(vec![ch; closer_count]));
            self.set_span_if_mapped(run_id, closer_range_start, closer_range_end);
            self.items[closer_item as usize].node = run_id;
            Some(closer_item)
        } else {
            self.items[closer_item as usize].next
        };
        self.insert_item_between(left, right, new_node);
    }

    fn finish_link_or_image(&mut self, br: Bracket, dest: &[u8], title: Option<&[u8]>, close_i: usize, end: usize) {
        self.process_emphasis(br.delim_stack_len);

        let mut kids = Vec::new();
        let mut cur = self.items[br.item as usize].next;
        while let Some(ci) = cur {
            kids.push(self.items[ci as usize].node);
            cur = self.items[ci as usize].next;
        }
        let link = Link { destination: Some(dest.to_vec()), reference: None };
        let kind = if br.is_image { Kind::Image(link) } else { Kind::Link(link) };
        let node_id = self.b.add_container(kind, &kids);
        self.set_span_if_mapped(node_id, br.open_start, end);
        self.set_content_span_if_mapped(node_id, br.content_start, close_i);
        if let Some(t) = title {
            self.b.set_attrs(node_id, Attrs { entries: vec![KeyVal::new(b"title", Some(t))] });
        }

        let left = self.items[br.item as usize].prev;
        self.insert_item_between(left, None, node_id);

        self.brackets.pop();
        if !br.is_image {
            for outer in self.brackets.iter_mut() {
                if !outer.is_image {
                    outer.active = false;
                }
            }
            self.demote_ext_emails(node_id);
        }
    }

    /// Turn every EXTENDED email autolink in `id`'s subtree back into text.
    fn demote_ext_emails(&mut self, id: NodeId) {
        if self.ext_emails.is_empty() {
            return;
        }
        let mut child = self.b.nodes[id as usize].first_child;
        while let Some(cid) = child {
            self.demote_ext_emails(cid);
            child = self.b.nodes[cid as usize].next_sibling;
        }
        let is_email = matches!(&self.b.nodes[id as usize].kind, Kind::TextLeaf { kind: TextLeafKind::Email, .. });
        if !is_email {
            return;
        }
        if self.ext_emails.contains(&id) {
            let node = &mut self.b.nodes[id as usize];
            if let Kind::TextLeaf { text, .. } = &mut node.kind {
                let t = std::mem::take(text);
                node.kind = Kind::Str(t);
            }
        }
    }
}

fn map_point(segments: &[Segment], local: usize, is_end: bool) -> Option<usize> {
    for seg in segments {
        let lo = seg.buf_offset;
        let hi = seg.buf_offset + seg.len;
        let hit = if is_end { local > lo && local <= hi } else { local >= lo && local < hi };
        if hit {
            return Some(seg.src_offset + (local - lo));
        }
    }
    for seg in segments {
        if local >= seg.buf_offset && local <= seg.buf_offset + seg.len {
            return Some(seg.src_offset + (local - seg.buf_offset));
        }
    }
    None
}

// ── links / images ───────────────────────────────────────────────────────

/// Unicode simple case fold for the common bicameral scripts (must stay in
/// sync with `block.rs`'s copy — both feed the same label keys).
pub(crate) fn fold_codepoint_into(out: &mut Vec<u8>, cp: u32) {
    if cp == 0x00DF || cp == 0x1E9E {
        out.extend_from_slice(b"ss");
        return;
    }
    let folded = match cp {
        0x41..=0x5A => cp + 32,
        0x00C0..=0x00D6 | 0x00D8..=0x00DE => cp + 32,
        0x0391..=0x03A1 | 0x03A3..=0x03AB => cp + 32,
        0x0410..=0x042F => cp + 32,
        _ => cp,
    };
    let _ = utf8_encode(folded, out);
}

/// Trim + collapse internal whitespace runs to a single space + Unicode case
/// fold. Shared by link labels, footnote labels and reference definitions.
pub(crate) fn normalize_ref_label(s: &[u8]) -> Vec<u8> {
    let trimmed = trim(s, b" \t\r\n");
    let mut out = Vec::with_capacity(trimmed.len());
    let mut in_ws = false;
    let mut i = 0;
    while i < trimmed.len() {
        let c = trimmed[i];
        if c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' {
            if !in_ws {
                out.push(b' ');
            }
            in_ws = true;
            i += 1;
        } else if c < 0x80 {
            out.push(c.to_ascii_lowercase());
            in_ws = false;
            i += 1;
        } else {
            let len = utf8_seq_len(c).unwrap_or(1);
            let end = (i + len).min(trimmed.len());
            match utf8_decode(&trimmed[i..end]) {
                Some(cp) => {
                    fold_codepoint_into(&mut out, cp);
                    in_ws = false;
                    i = end;
                }
                None => {
                    out.push(c);
                    in_ws = false;
                    i += 1;
                }
            }
        }
    }
    out
}

/// Handle a `]` at `text[close_i]`. Returns the index to resume scanning.
fn handle_close_bracket(sc: &mut Scanner<'_>, text: &[u8], close_i: usize) -> usize {
    if sc.brackets.is_empty() {
        sc.buf.push(b']');
        return close_i + 1;
    }
    let br = *sc.brackets.last().unwrap();
    if !br.active {
        sc.brackets.pop();
        sc.buf.push(b']');
        return close_i + 1;
    }

    if close_i + 1 < text.len() && text[close_i + 1] == b'(' {
        if let Some(raw) = scan_inline_link_tail(text, close_i + 1) {
            let dest = decode_text(raw.dest_raw);
            let title = raw.title_raw.map(decode_text);
            sc.finish_link_or_image(br, &dest, title.as_deref(), close_i, raw.end);
            return raw.end;
        }
    }

    let mut label_raw: &[u8] = &text[br.content_start..close_i];
    let mut ref_end = close_i + 1;
    if close_i + 1 < text.len() && text[close_i + 1] == b'[' {
        if let Some(lbl) = scan_bracket_label(text, close_i + 1) {
            ref_end = lbl.end;
            if !lbl.content.is_empty() {
                label_raw = lbl.content;
            }
        }
    }
    let norm = normalize_ref_label(label_raw);
    if !norm.is_empty() {
        if let Some(&ref_id) = sc.link_refs.get(&norm) {
            let dest = match &sc.b.nodes[ref_id as usize].kind {
                Kind::Reference { destination, .. } => destination.clone(),
                _ => Vec::new(),
            };
            let title = sc.b.attrs_of(ref_id).and_then(|a| a.get(b"title")).map(|t| t.to_vec());
            sc.finish_link_or_image(br, &dest, title.as_deref(), close_i, ref_end);
            return ref_end;
        }
    }

    sc.brackets.pop();
    sc.buf.push(b']');
    close_i + 1
}

struct RawLinkTail<'t> {
    dest_raw: &'t [u8],
    title_raw: Option<&'t [u8]>,
    end: usize,
}

/// `text[start] == '('`: scans an inline link/image tail.
fn scan_inline_link_tail(text: &[u8], start: usize) -> Option<RawLinkTail<'_>> {
    let mut i = start + 1;
    i = skip_ws(text, i);
    let dest_raw: &[u8];
    if i < text.len() && text[i] == b')' {
        return Some(RawLinkTail { dest_raw: b"", title_raw: None, end: i + 1 });
    }
    if i < text.len() && text[i] == b'<' {
        let dstart = i + 1;
        let mut j = dstart;
        while j < text.len() && text[j] != b'>' && text[j] != b'\n' {
            if text[j] == b'\\' && j + 1 < text.len() {
                j += 1;
            }
            j += 1;
        }
        if j >= text.len() || text[j] != b'>' {
            return None;
        }
        dest_raw = &text[dstart..j];
        i = j + 1;
    } else {
        let dstart = i;
        let mut depth: usize = 0;
        let mut j = i;
        while j < text.len() {
            let ch = text[j];
            if ch == b'\\' && j + 1 < text.len() && is_ascii_punct(text[j + 1]) {
                j += 2;
                continue;
            }
            if ch == b' ' || ch == b'\t' || ch == b'\n' || ch.is_ascii_control() {
                break;
            }
            if ch == b'(' {
                depth += 1;
            }
            if ch == b')' {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            j += 1;
        }
        if j == dstart || depth != 0 {
            return None;
        }
        dest_raw = &text[dstart..j];
        i = j;
    }

    let after_dest = i;
    let ws_end = skip_ws(text, after_dest);
    let mut title_raw = None;
    if ws_end > after_dest
        && ws_end < text.len()
        && (text[ws_end] == b'"' || text[ws_end] == b'\'' || text[ws_end] == b'(')
    {
        let open = text[ws_end];
        let close = if open == b'(' { b')' } else { open };
        let mut j = ws_end + 1;
        while j < text.len() && text[j] != close {
            if text[j] == b'\\' && j + 1 < text.len() {
                j += 1;
            }
            j += 1;
        }
        if j >= text.len() {
            return None;
        }
        title_raw = Some(&text[ws_end + 1..j]);
        i = j + 1;
    } else {
        i = after_dest;
    }
    i = skip_ws(text, i);
    if i >= text.len() || text[i] != b')' {
        return None;
    }
    Some(RawLinkTail { dest_raw, title_raw, end: i + 1 })
}

/// A bracketed label's content and the index just past its `]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawLabel<'t> {
    pub content: &'t [u8],
    pub end: usize,
}

/// `text[start] == '['`. Scans a link LABEL (no nested brackets).
pub fn scan_bracket_label(text: &[u8], start: usize) -> Option<RawLabel<'_>> {
    let mut i = start + 1;
    let content_start = i;
    while i < text.len() {
        let c = text[i];
        if c == b'\\' && i + 1 < text.len() {
            i += 2;
            continue;
        }
        if c == b'[' {
            return None;
        }
        if c == b']' {
            break;
        }
        i += 1;
    }
    if i >= text.len() || text[i] != b']' {
        return None;
    }
    if i - content_start > 999 {
        return None;
    }
    Some(RawLabel { content: &text[content_start..i], end: i + 1 })
}

/// `text[start] == '['`. Scans a DIRECTIVE label, allowing BALANCED nested
/// brackets.
pub fn scan_directive_label(text: &[u8], start: usize) -> Option<RawLabel<'_>> {
    let mut i = start + 1;
    let content_start = i;
    let mut depth: usize = 0;
    while i < text.len() {
        let c = text[i];
        if c == b'\\' && i + 1 < text.len() {
            i += 2;
            continue;
        }
        if c == b'[' {
            depth += 1;
        } else if c == b']' {
            if depth == 0 {
                break;
            }
            depth -= 1;
        }
        i += 1;
    }
    if i >= text.len() || text[i] != b']' {
        return None;
    }
    if i - content_start > 999 {
        return None;
    }
    Some(RawLabel { content: &text[content_start..i], end: i + 1 })
}

// ── text directives ──────────────────────────────────────────────────────

/// How deep text directives (and paired tags) may nest before a `:` stops
/// being read as one.
const MAX_DIRECTIVE_NESTING: u8 = 32;

#[derive(Clone, Copy)]
struct DirectiveLabel<'t> {
    text: &'t [u8],
    start: usize,
    end: usize,
}

struct TextDirective<'t> {
    name: &'t [u8],
    label: Option<DirectiveLabel<'t>>,
    attrs: Option<attrs_mod::Parsed>,
    end: usize,
}

/// `text[at] == ':'`. Recognize a text directive `:name[label]{attrs}`.
fn scan_text_directive(text: &[u8], at: usize) -> Option<TextDirective<'_>> {
    let name_end = attrs_mod::scan_name(text, at + 1)?;
    let name = &text[at + 1..name_end];
    let mut i = name_end;
    let mut label = None;
    if i < text.len() && text[i] == b'[' {
        let raw = scan_directive_label(text, i)?;
        label = Some(DirectiveLabel { text: raw.content, start: i + 1, end: raw.end - 1 });
        i = raw.end;
    }
    let mut attrs = None;
    if i < text.len() && text[i] == b'{' {
        if let Some(p) = attrs_mod::parse(text, i) {
            i = p.end;
            attrs = Some(p);
        }
    }
    Some(TextDirective { name, label, attrs, end: i })
}

/// The scanner's segments restricted to `text[start..end)` and rebased.
fn label_segments(segments: &[Segment], start: usize, end: usize) -> Vec<Segment> {
    let mut out = Vec::new();
    for seg in segments {
        let lo = seg.buf_offset.max(start);
        let hi = (seg.buf_offset + seg.len).min(end);
        if lo >= hi {
            continue;
        }
        out.push(Segment { buf_offset: lo - start, src_offset: seg.src_offset + (lo - seg.buf_offset), len: hi - lo });
    }
    out
}

fn build_text_directive(sc: &mut Scanner<'_>, d: TextDirective<'_>) -> NodeId {
    let children = match d.label {
        Some(lab) => {
            let segs = label_segments(&sc.segments, lab.start, lab.end);
            let depth = sc.directive_depth + 1;
            let mut nested = Scanner::new(&mut *sc.b, sc.link_refs, sc.options);
            nested.segments = segs;
            nested.directive_depth = depth;
            run_scan(&mut nested, lab.text)
        }
        None => Vec::new(),
    };
    let id = sc.b.add_container(Kind::Container(Container::with_form(d.name, Form::InlineText)), &children);
    sc.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
    if let Some(p) = d.attrs {
        sc.b.set_attrs(id, Attrs { entries: p.entries });
    }
    id
}

// ── paired <span> and <u> (`html_elements`) ─────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum PairedTag {
    Span,
    U,
}

impl PairedTag {
    fn name(self) -> &'static [u8] {
        match self {
            PairedTag::Span => b"span",
            PairedTag::U => b"u",
        }
    }

    fn names(self, tag: &[u8], closing: bool) -> bool {
        let name = self.name();
        let start = if closing { 2 } else { 1 };
        if tag.len() < start + name.len() + 1 {
            return false;
        }
        if !tag[start..start + name.len()].eq_ignore_ascii_case(name) {
            return false;
        }
        let after = tag[start + name.len()];
        after == b' ' || after == b'\t' || after == b'\n' || after == b'/' || after == b'>'
    }

    fn opening(tag: &[u8]) -> Option<PairedTag> {
        if tag[tag.len() - 2] == b'/' {
            return None;
        }
        if PairedTag::Span.names(tag, false) {
            return Some(PairedTag::Span);
        }
        if PairedTag::U.names(tag, false) {
            let rest = trim(&tag[2..tag.len() - 1], b" \t\n");
            return if rest.is_empty() { Some(PairedTag::U) } else { None };
        }
        None
    }
}

/// `text[at] == '<'`, under `html_elements`: a `<span …>` or a bare `<u>`
/// whose closer lies in this run.
fn try_paired_tag(sc: &mut Scanner<'_>, text: &[u8], at: usize) -> Option<usize> {
    if sc.directive_depth >= MAX_DIRECTIVE_NESTING {
        return None;
    }
    let open_end = scan_html_open_tag(text, at)?;
    let which = PairedTag::opening(&text[at..open_end])?;

    let mut depth: usize = 0;
    let mut i = open_end;
    let mut close_start = None;
    while i < text.len() {
        if text[i] != b'<' {
            i += 1;
            continue;
        }
        if let Some(e) = scan_html_open_tag(text, i) {
            if which.names(&text[i..e], false) && text[e - 2] != b'/' {
                depth += 1;
            }
            i = e - 1;
        } else if let Some(e) = scan_html_close_tag(text, i) {
            if which.names(&text[i..e], true) {
                if depth == 0 {
                    close_start = Some(i);
                    break;
                }
                depth -= 1;
            }
            i = e - 1;
        }
        i += 1;
    }
    let cs = close_start?;
    let close_end = scan_html_close_tag(text, cs).unwrap();

    sc.flush_buf(at);
    let segs = label_segments(&sc.segments, open_end, cs);
    let children = {
        let depth = sc.directive_depth + 1;
        let mut nested = Scanner::new(&mut *sc.b, sc.link_refs, sc.options);
        nested.segments = segs;
        nested.directive_depth = depth;
        run_scan(&mut nested, &text[open_end..cs])
    };

    let id = match which {
        PairedTag::U => sc.b.add_container(Kind::InlineMark(InlineMark::Insert), &children),
        PairedTag::Span => {
            let cid = sc.b.add_container(Kind::Container(Container::with_form(b"span", Form::InlineText)), &children);
            sc.b.set_spelling(cid, Spelling::ContainerOrigin(ContainerOrigin::Element));
            let tag_doc = html_parse(&text[at..open_end]);
            for child in tag_doc.ast.children(tag_doc.ast.root) {
                if !matches!(child.kind, Kind::Container(_)) {
                    continue;
                }
                let attrs = tag_doc.ast.attrs_of(child.id);
                if !attrs.is_empty() {
                    sc.b.set_attrs(cid, attrs.clone());
                }
                break;
            }
            cid
        }
    };
    sc.set_span_if_mapped(id, at, close_end);
    sc.set_content_span_if_mapped(id, open_end, cs);
    sc.append_item(id);
    Some(close_end)
}

// ── footnote references ──────────────────────────────────────────────────

struct FootnoteRefLabel<'t> {
    label: &'t [u8],
    end: usize,
}

/// `text[at] == '['`. `[^label]`.
fn try_footnote_reference(text: &[u8], at: usize) -> Option<FootnoteRefLabel<'_>> {
    if at + 1 >= text.len() || text[at + 1] != b'^' {
        return None;
    }
    let raw = scan_bracket_label(text, at)?;
    let label = &raw.content[1..];
    if trim(label, b" \t\r\n").is_empty() {
        return None;
    }
    Some(FootnoteRefLabel { label, end: raw.end })
}

fn skip_ws(text: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < text.len() && (text[i] == b' ' || text[i] == b'\t' || text[i] == b'\n') {
        i += 1;
    }
    i
}

// ── autolinks ────────────────────────────────────────────────────────────

/// `text[at] == '<'`. An absolute-URI autolink `<scheme:rest>`; the index
/// just past the `>`.
pub fn scan_autolink_uri(text: &[u8], at: usize) -> Option<usize> {
    let mut i = at + 1;
    if i >= text.len() || !text[i].is_ascii_alphabetic() {
        return None;
    }
    let scheme_start = i;
    i += 1;
    while i < text.len()
        && (i - scheme_start) < 32
        && (text[i].is_ascii_alphanumeric() || text[i] == b'+' || text[i] == b'-' || text[i] == b'.')
    {
        i += 1;
    }
    if i - scheme_start < 2 {
        return None;
    }
    if i >= text.len() || text[i] != b':' {
        return None;
    }
    i += 1;
    while i < text.len() && text[i] != b'>' && text[i] != b'<' && text[i] != b' ' && !text[i].is_ascii_control() {
        i += 1;
    }
    if i >= text.len() || text[i] != b'>' {
        return None;
    }
    Some(i + 1)
}

fn is_email_local_char(c: u8) -> bool {
    if c.is_ascii_alphanumeric() {
        return true;
    }
    matches!(
        c,
        b'.' | b'!'
            | b'#'
            | b'$'
            | b'%'
            | b'&'
            | b'\''
            | b'*'
            | b'+'
            | b'/'
            | b'='
            | b'?'
            | b'^'
            | b'_'
            | b'`'
            | b'{'
            | b'|'
            | b'}'
            | b'~'
            | b'-'
    )
}

fn scan_email_domain_label(text: &[u8], i: &mut usize) -> bool {
    let start = *i;
    if start >= text.len() || !text[start].is_ascii_alphanumeric() {
        return false;
    }
    let mut j = start + 1;
    let mut end = j;
    while j < text.len() && (j - start) < 63 && (text[j].is_ascii_alphanumeric() || text[j] == b'-') {
        if text[j].is_ascii_alphanumeric() {
            end = j + 1;
        }
        j += 1;
    }
    *i = end;
    true
}

/// `text[at] == '<'`. An email autolink per CommonMark's grammar.
pub fn scan_autolink_email(text: &[u8], at: usize) -> Option<usize> {
    let mut i = at + 1;
    let local_start = i;
    while i < text.len() && is_email_local_char(text[i]) {
        i += 1;
    }
    if i == local_start {
        return None;
    }
    if i >= text.len() || text[i] != b'@' {
        return None;
    }
    i += 1;
    if !scan_email_domain_label(text, &mut i) {
        return None;
    }
    while i < text.len() && text[i] == b'.' {
        let save = i;
        i += 1;
        if !scan_email_domain_label(text, &mut i) {
            i = save;
            break;
        }
    }
    if i >= text.len() || text[i] != b'>' {
        return None;
    }
    Some(i + 1)
}

// ── inline/display math ─────────────────────────────────────────────────

struct MathSpan {
    content_end: usize,
    end: usize,
}

fn scan_display_math(text: &[u8], at: usize) -> Option<MathSpan> {
    let mut j = at + 2;
    while j + 1 < text.len() {
        if text[j] == b'$' && text[j + 1] == b'$' {
            if j == at + 2 {
                return None;
            }
            return Some(MathSpan { content_end: j, end: j + 2 });
        }
        j += 1;
    }
    None
}

fn scan_inline_math(text: &[u8], at: usize) -> Option<MathSpan> {
    if at + 1 >= text.len() {
        return None;
    }
    let first = text[at + 1];
    if first == b' ' || first == b'\t' || first == b'\n' || first == b'$' {
        return None;
    }
    let mut j = at + 1;
    while j < text.len() {
        let ch = text[j];
        if ch == b'\\' && j + 1 < text.len() {
            j += 2;
            continue;
        }
        if ch == b'\n' {
            return None;
        }
        if ch == b'$' && text[j - 1] != b' ' && text[j - 1] != b'\t' {
            return Some(MathSpan { content_end: j, end: j + 1 });
        }
        j += 1;
    }
    None
}

// ── GFM extended autolinks ───────────────────────────────────────────────

fn is_word_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// Trim trailing punctuation off an autolink candidate (cmark-gfm's
/// `autolink_delim`). Returns the kept length.
fn trim_trailing_autolink_punct(s: &[u8]) -> usize {
    let mut open = 0usize;
    let mut close = 0usize;
    for &ch in s {
        if ch == b'(' {
            open += 1;
        }
        if ch == b')' {
            close += 1;
        }
    }
    let mut end = s.len();
    while end > 0 {
        let c = s[end - 1];
        if c == b')' {
            if close <= open {
                break;
            }
            close -= 1;
            end -= 1;
            continue;
        }
        if c == b';' {
            let mut k = end - 1;
            while k > 0 && s[k - 1].is_ascii_alphabetic() {
                k -= 1;
            }
            if k < end - 1 && k > 0 && s[k - 1] == b'&' {
                end = k - 1;
            } else {
                end -= 1;
            }
            continue;
        }
        match c {
            b'?' | b'!' | b'.' | b',' | b':' | b'*' | b'_' | b'~' | b'\'' | b'"' => {
                end -= 1;
                continue;
            }
            _ => break,
        }
    }
    end
}

fn scan_ext_autolink_body(text: &[u8], start: usize) -> usize {
    let mut j = start;
    while j < text.len() && text[j] != b' ' && text[j] != b'\t' && text[j] != b'\n' && text[j] != b'<' {
        j += 1;
    }
    j
}

fn try_ext_url_autolink(sc: &mut Scanner<'_>, text: &[u8], i: usize) -> Option<usize> {
    if i > 0 && is_word_char(text[i - 1]) {
        return None;
    }
    let rest = &text[i..];
    let prefix_len = if rest.starts_with(b"https://") {
        8
    } else if rest.starts_with(b"http://") {
        7
    } else if rest.starts_with(b"ftp://") {
        6
    } else {
        return None;
    };
    let raw_end = scan_ext_autolink_body(text, i + prefix_len);
    if raw_end == i + prefix_len {
        return None;
    }
    let trimmed_len = trim_trailing_autolink_punct(&text[i..raw_end]);
    if trimmed_len <= prefix_len {
        return None;
    }
    let final_end = i + trimmed_len;
    sc.flush_buf(i);
    let id = sc.b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::Url, text: text[i..final_end].to_vec() });
    sc.set_span_if_mapped(id, i, final_end);
    sc.append_item(id);
    Some(final_end)
}

fn try_ext_www_autolink(sc: &mut Scanner<'_>, text: &[u8], i: usize) -> Option<usize> {
    if i > 0 && is_word_char(text[i - 1]) {
        return None;
    }
    if !text[i..].starts_with(b"www.") {
        return None;
    }
    let raw_end = scan_ext_autolink_body(text, i + 4);
    if raw_end == i + 4 {
        return None;
    }
    let trimmed_len = trim_trailing_autolink_punct(&text[i..raw_end]);
    if trimmed_len <= 4 {
        return None;
    }
    let final_end = i + trimmed_len;
    sc.flush_buf(i);
    let mut dest = b"http://".to_vec();
    dest.extend_from_slice(&text[i..final_end]);
    let text_node = sc.b.add_leaf(Kind::Str(text[i..final_end].to_vec()));
    sc.set_span_if_mapped(text_node, i, final_end);
    let link_node =
        sc.b.add_container(Kind::Link(Link { destination: Some(dest), reference: None }), &[text_node]);
    sc.set_span_if_mapped(link_node, i, final_end);
    sc.append_item(link_node);
    Some(final_end)
}

fn is_ext_email_local_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'.' || c == b'+' || c == b'-' || c == b'_'
}

fn scan_ext_email_segment(text: &[u8], i: &mut usize) -> bool {
    let start = *i;
    while *i < text.len() && (text[*i].is_ascii_alphanumeric() || text[*i] == b'-' || text[*i] == b'_') {
        *i += 1;
    }
    *i > start
}

fn scan_ext_email_domain(text: &[u8], start: usize) -> Option<usize> {
    let mut j = start;
    if !scan_ext_email_segment(text, &mut j) {
        return None;
    }
    let mut has_dot = false;
    while j < text.len() && text[j] == b'.' {
        let save = j;
        j += 1;
        if !scan_ext_email_segment(text, &mut j) {
            j = save;
            break;
        }
        has_dot = true;
    }
    if !has_dot {
        return None;
    }
    let last = text[j - 1];
    if last == b'-' || last == b'_' {
        return None;
    }
    Some(j)
}

fn try_ext_email_autolink(sc: &mut Scanner<'_>, text: &[u8], at: usize) -> Option<usize> {
    let buf_len = sc.buf.len();
    let mut local_start = buf_len;
    while local_start > 0 && is_ext_email_local_char(sc.buf[local_start - 1]) {
        local_start -= 1;
    }
    while local_start < buf_len && !sc.buf[local_start].is_ascii_alphanumeric() {
        local_start += 1;
    }
    if local_start == buf_len {
        return None;
    }
    let final_end = scan_ext_email_domain(text, at + 1)?;

    let mut email = sc.buf[local_start..].to_vec();
    email.push(b'@');
    email.extend_from_slice(&text[at + 1..final_end]);

    let local_part_src_start = if sc.buf_pure { Some(sc.buf_start + local_start) } else { None };
    sc.buf.truncate(local_start);
    match local_part_src_start {
        Some(lps) => sc.flush_buf(lps),
        None => sc.flush_buf_no_span(),
    }
    let email_id = sc.b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::Email, text: email });
    if let Some(lps) = local_part_src_start {
        sc.set_span_if_mapped(email_id, lps, final_end);
    }
    sc.ext_emails.push(email_id);
    sc.append_item(email_id);
    Some(final_end)
}

// ── raw inline HTML ─────────────────────────────────────────────────────

fn is_attr_name_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_' || c == b':'
}

fn is_attr_name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b':' || c == b'-'
}

fn scan_html_tag(text: &[u8], at: usize) -> Option<usize> {
    if at + 1 >= text.len() {
        return None;
    }
    match text[at + 1] {
        b'/' => scan_html_close_tag(text, at),
        b'?' => scan_html_pi(text, at),
        b'!' => {
            if text[at..].starts_with(b"<!--") {
                return scan_html_comment(text, at);
            }
            if text[at..].starts_with(b"<![CDATA[") {
                return scan_html_cdata(text, at);
            }
            scan_html_declaration(text, at)
        }
        _ => scan_html_open_tag(text, at),
    }
}

fn scan_html_open_tag(text: &[u8], at: usize) -> Option<usize> {
    let mut i = at + 1;
    if i >= text.len() || !text[i].is_ascii_alphabetic() {
        return None;
    }
    i += 1;
    while i < text.len() && (text[i].is_ascii_alphanumeric() || text[i] == b'-') {
        i += 1;
    }
    loop {
        let before_ws = i;
        let after_ws = skip_ws(text, i);
        if after_ws == before_ws {
            break;
        }
        if after_ws < text.len() && is_attr_name_start(text[after_ws]) {
            let mut j = after_ws + 1;
            while j < text.len() && is_attr_name_char(text[j]) {
                j += 1;
            }
            let name_end = j;
            let after_name_ws = skip_ws(text, name_end);
            if after_name_ws < text.len() && text[after_name_ws] == b'=' {
                let mut k = skip_ws(text, after_name_ws + 1);
                if k >= text.len() {
                    return None;
                }
                let qc = text[k];
                if qc == b'"' || qc == b'\'' {
                    k += 1;
                    while k < text.len() && text[k] != qc {
                        k += 1;
                    }
                    if k >= text.len() {
                        return None;
                    }
                    i = k + 1;
                } else {
                    let vstart = k;
                    while k < text.len()
                        && !is_ascii_ws(text[k])
                        && text[k] != b'"'
                        && text[k] != b'\''
                        && text[k] != b'='
                        && text[k] != b'<'
                        && text[k] != b'>'
                        && text[k] != b'`'
                    {
                        k += 1;
                    }
                    if k == vstart {
                        return None;
                    }
                    i = k;
                }
            } else {
                i = name_end;
            }
        } else {
            i = before_ws;
            break;
        }
    }
    i = skip_ws(text, i);
    if i < text.len() && text[i] == b'/' {
        i += 1;
    }
    if i >= text.len() || text[i] != b'>' {
        return None;
    }
    Some(i + 1)
}

fn scan_html_close_tag(text: &[u8], at: usize) -> Option<usize> {
    let mut i = at + 2;
    if i >= text.len() || !text[i].is_ascii_alphabetic() {
        return None;
    }
    i += 1;
    while i < text.len() && (text[i].is_ascii_alphanumeric() || text[i] == b'-') {
        i += 1;
    }
    i = skip_ws(text, i);
    if i >= text.len() || text[i] != b'>' {
        return None;
    }
    Some(i + 1)
}

fn scan_html_comment(text: &[u8], at: usize) -> Option<usize> {
    let mut j = at + 4;
    if j < text.len() && text[j] == b'>' {
        return Some(j + 1);
    }
    if j + 1 < text.len() && text[j] == b'-' && text[j + 1] == b'>' {
        return Some(j + 2);
    }
    while j + 2 < text.len() {
        if text[j] == b'-' && text[j + 1] == b'-' && text[j + 2] == b'>' {
            return Some(j + 3);
        }
        j += 1;
    }
    None
}

fn scan_html_pi(text: &[u8], at: usize) -> Option<usize> {
    index_of(text, at + 2, b"?>").map(|i| i + 2)
}

fn scan_html_declaration(text: &[u8], at: usize) -> Option<usize> {
    let mut i = at + 2;
    let name_start = i;
    while i < text.len() && text[i].is_ascii_uppercase() {
        i += 1;
    }
    if i == name_start {
        return None;
    }
    if i >= text.len() || !is_ascii_ws(text[i]) {
        return None;
    }
    index_of_scalar(text, i, b'>').map(|g| g + 1)
}

fn scan_html_cdata(text: &[u8], at: usize) -> Option<usize> {
    index_of(text, at + b"<![CDATA[".len(), b"]]>").map(|i| i + 3)
}

// ── emphasis flanking ───────────────────────────────────────────────────

#[derive(Clone, Copy)]
struct Flank {
    can_open: bool,
    can_close: bool,
}

fn compute_flanking(text: &[u8], run_start: usize, run_end: usize, ch: u8) -> Flank {
    let before_cp = codepoint_before(text, run_start);
    let after_cp = codepoint_after(text, run_end);

    let before_is_ws = before_cp.is_none_or(is_unicode_whitespace_cp);
    let before_is_punct = before_cp.is_some_and(is_unicode_punctuation_cp);
    let after_is_ws = after_cp.is_none_or(is_unicode_whitespace_cp);
    let after_is_punct = after_cp.is_some_and(is_unicode_punctuation_cp);

    let left_flanking = !after_is_ws && (!after_is_punct || before_is_ws || before_is_punct);
    let right_flanking = !before_is_ws && (!before_is_punct || after_is_ws || after_is_punct);

    if ch == b'_' {
        return Flank {
            can_open: left_flanking && (!right_flanking || before_is_punct),
            can_close: right_flanking && (!left_flanking || after_is_punct),
        };
    }
    Flank { can_open: left_flanking, can_close: right_flanking }
}

fn codepoint_at(text: &[u8], i: usize) -> u32 {
    let Some(len) = utf8_seq_len(text[i]) else { return text[i] as u32 };
    if i + len > text.len() {
        return text[i] as u32;
    }
    utf8_decode(&text[i..i + len]).unwrap_or(text[i] as u32)
}

fn codepoint_after(text: &[u8], i: usize) -> Option<u32> {
    if i >= text.len() {
        return None;
    }
    Some(codepoint_at(text, i))
}

fn codepoint_before(text: &[u8], i: usize) -> Option<u32> {
    if i == 0 {
        return None;
    }
    let mut start = i - 1;
    let mut back = 0;
    while start > 0 && (text[start] & 0xC0) == 0x80 && back < 3 {
        start -= 1;
        back += 1;
    }
    Some(codepoint_at(text, start))
}

fn is_unicode_whitespace_cp(cp: u32) -> bool {
    if cp < 0x80 {
        return is_ascii_ws(cp as u8);
    }
    matches!(cp, 0xA0 | 0x1680 | 0x2000..=0x200A | 0x202F | 0x205F | 0x3000)
}

fn is_unicode_punctuation_cp(cp: u32) -> bool {
    if cp < 0x80 {
        return is_ascii_punct(cp as u8);
    }
    matches!(
        cp,
        0x00A1
            | 0x00A7
            | 0x00B6
            | 0x00BF
            | 0x00A2..=0x00A6
            | 0x00A8
            | 0x00A9
            | 0x00AC
            | 0x00AE
            | 0x00AF
            | 0x00AB
            | 0x00BB
            | 0x00B0
            | 0x00B1
            | 0x00B4
            | 0x00B7
            | 0x00B8
            | 0x00D7
            | 0x00F7
            | 0x2010..=0x2027
            | 0x2030..=0x205E
            | 0x20A0..=0x20BF
            | 0x3001..=0x303F
            | 0xFF01..=0xFF0F
            | 0xFF1A..=0xFF20
            | 0xFF3B..=0xFF40
            | 0xFF5B..=0xFF65
    )
}

fn skip_leading_line_space(text: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < text.len() && (text[i] == b' ' || text[i] == b'\t') {
        i += 1;
    }
    i
}

fn trailing_hard_break_spaces(buf: &[u8]) -> usize {
    let mut n = 0;
    while n < buf.len() && buf[buf.len() - 1 - n] == b' ' {
        n += 1;
    }
    n
}

pub(crate) fn is_ascii_punct(c: u8) -> bool {
    matches!(
        c,
        b'!' | b'"'
            | b'#'
            | b'$'
            | b'%'
            | b'&'
            | b'\''
            | b'('
            | b')'
            | b'*'
            | b'+'
            | b','
            | b'-'
            | b'.'
            | b'/'
            | b':'
            | b';'
            | b'<'
            | b'='
            | b'>'
            | b'?'
            | b'@'
            | b'['
            | b'\\'
            | b']'
            | b'^'
            | b'_'
            | b'`'
            | b'{'
            | b'|'
            | b'}'
            | b'~'
    )
}

// ── code spans ───────────────────────────────────────────────────────────

struct CodeSpan {
    end: usize,
    content_start: usize,
    content_end: usize,
}

fn scan_code_span(text: &[u8], start: usize) -> Option<CodeSpan> {
    let mut i = start;
    while i < text.len() && text[i] == b'`' {
        i += 1;
    }
    let open_len = i - start;
    let content_start = i;
    let mut j = i;
    while j < text.len() {
        if text[j] == b'`' {
            let run_start = j;
            while j < text.len() && text[j] == b'`' {
                j += 1;
            }
            if j - run_start == open_len {
                return Some(CodeSpan { end: j, content_start, content_end: run_start });
            }
        } else {
            j += 1;
        }
    }
    None
}

fn normalize_code_span(raw: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = raw.iter().map(|&c| if c == b'\n' { b' ' } else { c }).collect();
    if out.len() >= 2 && out[0] == b' ' && out[out.len() - 1] == b' ' && !out.iter().all(|&c| c == b' ') {
        out.remove(0);
        out.pop();
    }
    out
}

// ── entity / numeric character references ──────────────────────────────

/// `text[at] == '&'`: the decoded replacement and the index past it.
fn decode_char_ref(text: &[u8], at: usize) -> Option<(Vec<u8>, usize)> {
    let mut i = at + 1;
    if i < text.len() && text[i] == b'#' {
        i += 1;
        let hex = i < text.len() && (text[i] == b'x' || text[i] == b'X');
        if hex {
            i += 1;
        }
        let digits_start = i;
        while i < text.len() && (if hex { text[i].is_ascii_hexdigit() } else { text[i].is_ascii_digit() }) {
            i += 1;
        }
        let digits = &text[digits_start..i];
        let max_digits = if hex { 6 } else { 7 };
        if digits.is_empty() || digits.len() > max_digits {
            return None;
        }
        if i >= text.len() || text[i] != b';' {
            return None;
        }
        let s = std::str::from_utf8(digits).ok()?;
        let value = u32::from_str_radix(s, if hex { 16 } else { 10 }).ok()?;
        let cp = if value == 0 || value > 0x10FFFF || (0xD800..=0xDFFF).contains(&value) { 0xFFFD } else { value };
        let mut out = Vec::with_capacity(4);
        if !utf8_encode(cp, &mut out) {
            out.clear();
            utf8_encode(0xFFFD, &mut out);
        }
        return Some((out, i + 1));
    }
    let name_start = i;
    while i < text.len() && text[i].is_ascii_alphanumeric() {
        i += 1;
    }
    let name = &text[name_start..i];
    if name.is_empty() || i >= text.len() || text[i] != b';' {
        return None;
    }
    let replacement = entities::lookup(name)?;
    Some((replacement.to_vec(), i + 1))
}

#[cfg(test)]
#[path = "inline_tests.rs"]
mod tests;
