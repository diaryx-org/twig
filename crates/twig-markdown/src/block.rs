//! CommonMark block structure: source text -> `Document`, via an incremental
//! line-by-line scan that mirrors the CommonMark spec's "Appendix: A parsing
//! strategy". Port of `src/languages/markdown/block.zig`.
//!
//! Maintain a stack of currently OPEN block containers (the document, plus
//! any block quotes / list items nested inside it) and, for each input line,
//! (1) match as much of the line as possible against that stack's markers,
//! (2) decide whether the containers that failed to match should really
//! close (vs. a *lazy continuation* line of an open paragraph), (3) either
//! continue an open leaf block or scan the remaining text for a new block
//! start. Builds purely bottom-up onto a [`Builder`].
//!
//! ── Documented simplifications ───────────────────────────────────────────
//!   - Tabs: a tab advances to the next multiple of 4; a straddling tab is
//!     split via `Cursor::spent`.
//!   - HTML block type 7 uses a hand-rolled tag grammar (`parse_complete_tag`).
//!   - Link reference definitions: a malformed same-line title rejects the
//!     whole definition.
//!   - Label normalization case-folds a curated subset of Unicode.
//!
//! ── Inline spans ─────────────────────────────────────────────────────────
//! Block nodes get their `span` from `line_start`/`line_end`. Inline content
//! is handed to the scanner as an ASSEMBLED buffer plus a list of
//! [`Segment`]s mapping its runs back to the source (`append_mapped_source`
//! records one; a synthetic byte such as the line-join `\n` is appended
//! unmapped). Source offsets are recovered from borrowed slices of the source
//! by pointer arithmetic, exactly as the Zig original does.

use std::collections::HashMap;

use crate::ast::{Alignment, Attrs, Builder, Cell, Container as AstContainer, Form, KeyVal, Kind, ListNumbering, NodeId};
use crate::document::{Bullet, ContainerOrigin, Document, Labels, OrderedDelim, Spelling};
use crate::span::Span;

use super::attributes as attrs_mod;
use super::inline as inline_mod;
use super::inline::{index_of, index_of_scalar, is_blank_str_node, normalize_ref_label, trim, trim_end, trim_start, Segment};
use super::options::ParseOptions;

// ── low-level line/column helpers ───────────────────────────────────────

/// A position on the current line. `col` is the visual column of the byte at
/// `pos`; `spent > 0` means `line[pos]` is a `\t` whose first `spent` columns
/// have already been consumed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Cursor {
    pos: usize,
    col: usize,
    spent: usize,
}

fn is_unset_span(s: Span) -> bool {
    s.start == 0 && s.end == 0
}

fn is_blank_line(s: &[u8]) -> bool {
    s.iter().all(|&c| c == b' ' || c == b'\t')
}

/// A frontmatter language tag (`figl`, `toml`, `ld+json`).
fn is_lang_tag(s: &[u8]) -> bool {
    if s.is_empty() || !s[0].is_ascii_alphabetic() {
        return false;
    }
    s.iter().all(|&c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b'.' || c == b'+')
}

/// Columns of leading whitespace from `cur`'s logical position.
fn indent_cols(line: &[u8], cur: Cursor) -> usize {
    let mut col = cur.col;
    let mut i = cur.pos;
    while i < line.len() {
        if line[i] == b' ' {
            col += 1;
            i += 1;
        } else if line[i] == b'\t' {
            col += 4 - (col % 4);
            i += 1;
        } else {
            break;
        }
    }
    col - (cur.col + cur.spent)
}

/// Consume up to `max_cols` columns of leading whitespace, splitting a tab
/// that straddles the limit.
fn skip_ws_up_to_cols(line: &[u8], cur: Cursor, max_cols: usize) -> Cursor {
    let mut col = cur.col;
    let mut i = cur.pos;
    let mut spent = cur.spent;
    let mut consumed = 0;
    while i < line.len() && consumed < max_cols {
        let c = line[i];
        if c == b' ' {
            col += 1;
            i += 1;
            consumed += 1;
            spent = 0;
        } else if c == b'\t' {
            let avail = (4 - (col % 4)) - spent;
            if consumed + avail <= max_cols {
                consumed += avail;
                col += 4 - (col % 4);
                i += 1;
                spent = 0;
            } else {
                spent += max_cols - consumed;
                break;
            }
        } else {
            break;
        }
    }
    Cursor { pos: i, col, spent }
}

/// Consume leading whitespace until the logical column reaches `target_col`.
fn skip_ws_to_target(line: &[u8], cur: Cursor, target_col: usize) -> Cursor {
    let mut col = cur.col;
    let mut i = cur.pos;
    let mut spent = cur.spent;
    while i < line.len() && (col + spent) < target_col {
        let c = line[i];
        if c == b' ' {
            col += 1;
            i += 1;
            spent = 0;
        } else if c == b'\t' {
            let tab_end = col + (4 - (col % 4));
            if tab_end <= target_col {
                col = tab_end;
                i += 1;
                spent = 0;
            } else {
                spent = target_col - col;
                break;
            }
        } else {
            break;
        }
    }
    Cursor { pos: i, col, spent }
}

fn strip_up_to3_indent(s: &[u8]) -> &[u8] {
    let c = skip_ws_up_to_cols(s, Cursor::default(), 3);
    &s[c.pos..]
}

fn trim_leading_ws(s: &[u8]) -> &[u8] {
    let mut i = 0;
    while i < s.len() && (s[i] == b' ' || s[i] == b'\t') {
        i += 1;
    }
    &s[i..]
}

fn is_ascii_letter(c: u8) -> bool {
    c.is_ascii_alphabetic()
}

fn is_ascii_letter_or_digit(c: u8) -> bool {
    c.is_ascii_alphanumeric()
}

// ── block-start pattern matchers ─────────────────────────────────────────

fn is_thematic_break(s: &[u8]) -> bool {
    let mut count = 0;
    let mut ch = 0u8;
    for &c in s {
        if c == b'*' || c == b'-' || c == b'_' {
            if ch == 0 {
                ch = c;
            } else if c != ch {
                return false;
            }
            count += 1;
        } else if c == b' ' || c == b'\t' {
        } else {
            return false;
        }
    }
    count >= 3
}

struct AtxHeading<'t> {
    level: u32,
    content: &'t [u8],
    marker_len: usize,
}

fn try_atx_heading(s: &[u8]) -> Option<AtxHeading<'_>> {
    let mut i = 0;
    while i < s.len() && s[i] == b'#' {
        i += 1;
    }
    if i == 0 || i > 6 {
        return None;
    }
    if i < s.len() && s[i] != b' ' && s[i] != b'\t' {
        return None;
    }
    let mut content_start = i;
    while content_start < s.len() && (s[content_start] == b' ' || s[content_start] == b'\t') {
        content_start += 1;
    }
    let mut end = s.len();
    while end > content_start && (s[end - 1] == b' ' || s[end - 1] == b'\t') {
        end -= 1;
    }
    let mut hash_start = end;
    while hash_start > content_start && s[hash_start - 1] == b'#' {
        hash_start -= 1;
    }
    if hash_start < end && (hash_start == content_start || s[hash_start - 1] == b' ' || s[hash_start - 1] == b'\t') {
        end = hash_start;
        while end > content_start && (s[end - 1] == b' ' || s[end - 1] == b'\t') {
            end -= 1;
        }
    }
    Some(AtxHeading { level: i as u32, content: &s[content_start..end], marker_len: content_start })
}

fn try_setext_underline(s: &[u8]) -> Option<u32> {
    if s.is_empty() {
        return None;
    }
    let ch = s[0];
    if ch != b'=' && ch != b'-' {
        return None;
    }
    let mut i = 0;
    while i < s.len() && s[i] == ch {
        i += 1;
    }
    while i < s.len() && (s[i] == b' ' || s[i] == b'\t') {
        i += 1;
    }
    if i != s.len() {
        return None;
    }
    Some(if ch == b'=' { 1 } else { 2 })
}

struct FenceOpen<'t> {
    ch: u8,
    len: usize,
    info: &'t [u8],
}

fn try_fence_open(s: &[u8]) -> Option<FenceOpen<'_>> {
    if s.is_empty() {
        return None;
    }
    let c = s[0];
    if c != b'`' && c != b'~' {
        return None;
    }
    let mut i = 0;
    while i < s.len() && s[i] == c {
        i += 1;
    }
    if i < 3 {
        return None;
    }
    let rest = &s[i..];
    if c == b'`' && rest.contains(&b'`') {
        return None;
    }
    Some(FenceOpen { ch: c, len: i, info: trim(rest, b" \t") })
}

fn is_fence_close(s: &[u8], fence_char: u8, fence_len: usize) -> bool {
    let mut i = 0;
    while i < s.len() && s[i] == fence_char {
        i += 1;
    }
    if i < fence_len {
        return false;
    }
    s[i..].iter().all(|&c| c == b' ' || c == b'\t')
}

#[derive(Clone, Copy, Debug)]
struct ListMarker {
    ordered: bool,
    bullet_char: u8,
    delim: OrderedDelim,
    start: Option<u32>,
    marker_len: usize,
}

fn try_list_marker(s: &[u8]) -> Option<ListMarker> {
    if s.is_empty() {
        return None;
    }
    let c = s[0];
    if c == b'-' || c == b'+' || c == b'*' {
        if s.len() > 1 && s[1] != b' ' && s[1] != b'\t' {
            return None;
        }
        return Some(ListMarker { ordered: false, bullet_char: c, delim: OrderedDelim::Period, start: None, marker_len: 1 });
    }
    if c.is_ascii_digit() {
        let mut i = 0;
        while i < s.len() && s[i].is_ascii_digit() {
            i += 1;
        }
        if i > 9 {
            return None;
        }
        if i >= s.len() {
            return None;
        }
        let delim_ch = s[i];
        if delim_ch != b'.' && delim_ch != b')' {
            return None;
        }
        let marker_len = i + 1;
        if marker_len < s.len() && s[marker_len] != b' ' && s[marker_len] != b'\t' {
            return None;
        }
        let num: u32 = std::str::from_utf8(&s[..i]).ok()?.parse().ok()?;
        return Some(ListMarker {
            ordered: true,
            bullet_char: 0,
            delim: if delim_ch == b'.' { OrderedDelim::Period } else { OrderedDelim::ParenAfter },
            start: Some(num),
            marker_len,
        });
    }
    None
}

struct TaskMarker<'t> {
    checked: bool,
    rest: &'t [u8],
}

fn try_task_list_marker(after_marker: &[u8]) -> Option<TaskMarker<'_>> {
    if after_marker.len() < 3 {
        return None;
    }
    if after_marker[0] != b'[' {
        return None;
    }
    let c = after_marker[1];
    if c != b' ' && c != b'x' && c != b'X' {
        return None;
    }
    if after_marker[2] != b']' {
        return None;
    }
    if after_marker.len() == 3 {
        return Some(TaskMarker { checked: c != b' ', rest: &after_marker[3..] });
    }
    if after_marker[3] != b' ' && after_marker[3] != b'\t' {
        return None;
    }
    Some(TaskMarker { checked: c != b' ', rest: &after_marker[4..] })
}

/// True when `s` looks like the start of some OTHER block construct.
fn looks_like_new_block_start(s: &[u8], media_blocks: bool) -> bool {
    if s.is_empty() {
        return false;
    }
    if s[0] == b'>' {
        return true;
    }
    if is_thematic_break(s) {
        return true;
    }
    if try_atx_heading(s).is_some() {
        return true;
    }
    if try_fence_open(s).is_some() {
        return true;
    }
    if try_list_marker(s).is_some() {
        return true;
    }
    if s[0] == b'<' && detect_html_block_start(s, media_blocks).is_some() {
        return true;
    }
    false
}

fn is_definition_marker_line(s: &[u8]) -> bool {
    if s.is_empty() || s[0] != b':' {
        return false;
    }
    s.len() == 1 || s[1] == b' ' || s[1] == b'\t'
}

// ── GFM table row / delimiter-row parsing ────────────────────────────────

fn contains_unescaped_pipe(s: &[u8]) -> bool {
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'\\' && i + 1 < s.len() {
            i += 2;
            continue;
        }
        if s[i] == b'|' {
            return true;
        }
        i += 1;
    }
    false
}

fn strip_edge_pipes(s: &[u8]) -> &[u8] {
    let mut t = s;
    if !t.is_empty() && t[0] == b'|' {
        t = &t[1..];
    }
    if !t.is_empty() && t[t.len() - 1] == b'|' {
        let mut backslashes = 0;
        let mut k = t.len() - 1;
        while k > 0 && t[k - 1] == b'\\' {
            backslashes += 1;
            k -= 1;
        }
        if backslashes % 2 == 0 {
            t = &t[..t.len() - 1];
        }
    }
    t
}

fn split_table_row(s: &[u8]) -> Vec<&[u8]> {
    let trimmed_outer = trim(s, b" \t");
    let inner = strip_edge_pipes(trimmed_outer);
    let mut cells = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < inner.len() {
        if inner[i] == b'\\' && i + 1 < inner.len() {
            i += 2;
            continue;
        }
        if inner[i] == b'|' {
            cells.push(trim(&inner[start..i], b" \t"));
            start = i + 1;
        }
        i += 1;
    }
    cells.push(trim(&inner[start..], b" \t"));
    cells
}

fn offset_in(outer: &[u8], sub: &[u8]) -> usize {
    sub.as_ptr() as usize - outer.as_ptr() as usize
}

fn table_cell_extents(s: &[u8]) -> Vec<[usize; 2]> {
    let trimmed_outer = trim(s, b" \t");
    let lead = offset_in(s, trimmed_outer);
    let inner = strip_edge_pipes(trimmed_outer);
    let inner_at = offset_in(trimmed_outer, inner);
    let mut out = Vec::new();
    let mut start = lead;
    let mut i = 0;
    while i < inner.len() {
        if inner[i] == b'\\' && i + 1 < inner.len() {
            i += 2;
            continue;
        }
        if inner[i] == b'|' {
            let at = lead + inner_at + i;
            out.push([start, at]);
            start = at;
        }
        i += 1;
    }
    out.push([start, lead + inner_at + inner.len()]);
    out
}

fn parse_delimiter_row(s: &[u8]) -> Option<Vec<Alignment>> {
    let cells = split_table_row(s);
    if cells.is_empty() {
        return None;
    }
    for cell in &cells {
        let mut c: &[u8] = cell;
        if c.is_empty() {
            return None;
        }
        if c[0] == b':' {
            c = &c[1..];
        }
        if !c.is_empty() && c[c.len() - 1] == b':' {
            c = &c[..c.len() - 1];
        }
        if c.is_empty() {
            return None;
        }
        if c.iter().any(|&ch| ch != b'-') {
            return None;
        }
    }
    let mut aligns = Vec::with_capacity(cells.len());
    for cell in &cells {
        let mut c: &[u8] = cell;
        let mut left = false;
        let mut right = false;
        if c[0] == b':' {
            left = true;
            c = &c[1..];
        }
        if !c.is_empty() && c[c.len() - 1] == b':' {
            right = true;
        }
        aligns.push(if left && right {
            Alignment::Center
        } else if left {
            Alignment::Left
        } else if right {
            Alignment::Right
        } else {
            Alignment::Default
        });
    }
    Some(aligns)
}

// ── HTML block start detection ──────────────────────────────────────────

const HTML_TYPE1_TAGS: [&[u8]; 4] = [b"script", b"pre", b"style", b"textarea"];

/// Block-level media elements added to the type-6 list only under
/// `options.html_elements`.
const HTML_MEDIA_TAGS: [&[u8]; 3] = [b"video", b"audio", b"picture"];

const HTML_TYPE6_TAGS: [&[u8]; 61] = [
    b"address", b"article", b"aside", b"base", b"basefont", b"blockquote", b"body", b"caption", b"center", b"col",
    b"colgroup", b"dd", b"details", b"dialog", b"dir", b"div", b"dl", b"dt", b"fieldset", b"figcaption", b"figure",
    b"footer", b"form", b"frame", b"frameset", b"h1", b"h2", b"h3", b"h4", b"h5", b"h6", b"head", b"header", b"hr",
    b"html", b"iframe", b"legend", b"li", b"link", b"main", b"menu", b"menuitem", b"nav", b"noframes", b"ol",
    b"optgroup", b"option", b"p", b"param", b"section", b"summary", b"table", b"tbody", b"td", b"tfoot", b"th",
    b"thead", b"title", b"tr", b"track", b"ul",
];

/// If `s` starts with `name` (case-insensitive), the index just past it.
fn match_tag_name_ci(s: &[u8], name: &[u8]) -> Option<usize> {
    if s.len() < name.len() {
        return None;
    }
    for (i, &c) in name.iter().enumerate() {
        if s[i].to_ascii_lowercase() != c {
            return None;
        }
    }
    Some(name.len())
}

fn is_unquoted_value_stop(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'"' | b'\'' | b'=' | b'<' | b'>' | b'`')
}

/// A minimal HTML tag grammar for HTML block type 7.
fn parse_complete_tag(s: &[u8], closing: bool, name_end: usize) -> Option<usize> {
    let mut i = name_end;
    if closing {
        while i < s.len() && (s[i] == b' ' || s[i] == b'\t') {
            i += 1;
        }
        if i < s.len() && s[i] == b'>' {
            return Some(i + 1);
        }
        return None;
    }
    loop {
        let before = i;
        while i < s.len() && (s[i] == b' ' || s[i] == b'\t' || s[i] == b'\n') {
            i += 1;
        }
        if i < s.len() && s[i] == b'/' {
            if i + 1 < s.len() && s[i + 1] == b'>' {
                return Some(i + 2);
            }
            return None;
        }
        if i < s.len() && s[i] == b'>' {
            return Some(i + 1);
        }
        if i == before {
            return None;
        }
        if i >= s.len() || !(is_ascii_letter(s[i]) || s[i] == b'_' || s[i] == b':') {
            return None;
        }
        while i < s.len()
            && (is_ascii_letter_or_digit(s[i]) || s[i] == b'_' || s[i] == b':' || s[i] == b'.' || s[i] == b'-')
        {
            i += 1;
        }
        let mut j = i;
        while j < s.len() && (s[j] == b' ' || s[j] == b'\t' || s[j] == b'\n') {
            j += 1;
        }
        if j < s.len() && s[j] == b'=' {
            j += 1;
            while j < s.len() && (s[j] == b' ' || s[j] == b'\t' || s[j] == b'\n') {
                j += 1;
            }
            if j >= s.len() {
                return None;
            }
            if s[j] == b'"' {
                let close = index_of_scalar(s, j + 1, b'"')?;
                j = close + 1;
            } else if s[j] == b'\'' {
                let close = index_of_scalar(s, j + 1, b'\'')?;
                j = close + 1;
            } else {
                let vstart = j;
                while j < s.len() && !is_unquoted_value_stop(s[j]) {
                    j += 1;
                }
                if j == vstart {
                    return None;
                }
            }
            i = j;
        } else {
            i = j;
        }
    }
}

/// `s` is exactly one complete, non-self-closing `<div …>` open tag plus
/// trailing whitespace: the index just past the tag's `>`.
fn div_opener_end(s: &[u8]) -> Option<usize> {
    if s.len() < 4 || s[0] != b'<' {
        return None;
    }
    match_tag_name_ci(&s[1..], b"div")?;
    if s.len() > 4 && !(s[4] == b' ' || s[4] == b'\t' || s[4] == b'>') {
        return None;
    }
    let end = parse_complete_tag(s, false, 4)?;
    if end >= 2 && s[end - 2] == b'/' {
        return None;
    }
    if !is_blank_line(&s[end..]) {
        return None;
    }
    Some(end)
}

/// `s` is exactly one `</div>` close tag plus trailing whitespace.
fn div_closer_end(s: &[u8]) -> Option<usize> {
    if s.len() < 6 || s[0] != b'<' || s[1] != b'/' {
        return None;
    }
    match_tag_name_ci(&s[2..], b"div")?;
    let end = parse_complete_tag(s, true, 5)?;
    if !is_blank_line(&s[end..]) {
        return None;
    }
    Some(end)
}

/// `s` is indent-stripped and starts with `<`: the HTML block type (1-7).
fn detect_html_block_start(s: &[u8], media_blocks: bool) -> Option<u8> {
    if s.is_empty() || s[0] != b'<' {
        return None;
    }
    if s.starts_with(b"<!--") {
        return Some(2);
    }
    if s.starts_with(b"<?") {
        return Some(3);
    }
    if s.starts_with(b"<![CDATA[") {
        return Some(5);
    }
    if s.len() >= 3 && s[1] == b'!' && is_ascii_letter(s[2]) {
        return Some(4);
    }
    for name in HTML_TYPE1_TAGS {
        if let Some(n) = match_tag_name_ci(&s[1..], name) {
            let after = 1 + n;
            if after == s.len() || s[after] == b' ' || s[after] == b'\t' || s[after] == b'\n' || s[after] == b'>' {
                return Some(1);
            }
        }
    }

    let mut i = 1;
    let mut closing = false;
    if i < s.len() && s[i] == b'/' {
        closing = true;
        i += 1;
    }
    let name_start = i;
    if i >= s.len() || !is_ascii_letter(s[i]) {
        return None;
    }
    while i < s.len() && (is_ascii_letter_or_digit(s[i]) || s[i] == b'-') {
        i += 1;
    }
    let name = &s[name_start..i];

    if name.len() <= 32 {
        let lname = name.to_ascii_lowercase();
        let l = lname.as_slice();
        if HTML_TYPE6_TAGS.contains(&l) || (media_blocks && HTML_MEDIA_TAGS.contains(&l)) {
            if i == s.len() {
                return Some(6);
            }
            let c = s[i];
            if c == b' ' || c == b'\t' || c == b'>' {
                return Some(6);
            }
            if c == b'/' && i + 1 < s.len() && s[i + 1] == b'>' {
                return Some(6);
            }
            return None;
        }
    }

    if let Some(end) = parse_complete_tag(s, closing, i) {
        if is_blank_line(&s[end..]) {
            return Some(7);
        }
    }
    None
}

/// Lowercase only the first 4096 bytes, then search (Zig's `containsAnyCI`).
fn contains_any_ci(haystack: &[u8], needles: &[&[u8]]) -> bool {
    let n = haystack.len().min(4096);
    let lower = haystack[..n].to_ascii_lowercase();
    needles.iter().any(|nd| index_of(&lower, 0, nd).is_some())
}

fn html_block_ends(t: u8, remainder: &[u8]) -> bool {
    match t {
        1 => contains_any_ci(remainder, &[b"</script>", b"</pre>", b"</style>", b"</textarea>"]),
        2 => index_of(remainder, 0, b"-->").is_some(),
        3 => index_of(remainder, 0, b"?>").is_some(),
        4 => remainder.contains(&b'>'),
        5 => index_of(remainder, 0, b"]]>").is_some(),
        _ => false,
    }
}

// ── container / leaf staging types ──────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ContainerKind {
    Document,
    BlockQuote,
    List,
    ListItem,
    FootnoteDef,
    Directive,
    HtmlDiv,
}

struct Container<'s> {
    kind: ContainerKind,
    children: Vec<NodeId>,
    start_line: usize,
    end_line: usize,
    content_col: usize,
    marker_start: usize,
    marker_end: usize,
    footnote_label: &'s [u8],
    is_task: bool,
    task_checked: bool,
    ordered: bool,
    bullet_char: u8,
    delim: OrderedDelim,
    start_num: Option<u32>,
    tight: bool,
    blank_pending: bool,
    any_task: bool,
    directive_name: &'s [u8],
    directive_fence_len: usize,
    directive_attrs: Option<attrs_mod::Parsed>,
    directive_attrs_span: Option<Span>,
    div_tag: Span,
}

impl<'s> Container<'s> {
    fn new(kind: ContainerKind, start_line: usize, end_line: usize) -> Container<'s> {
        Container {
            kind,
            children: Vec::new(),
            start_line,
            end_line,
            content_col: 0,
            marker_start: 0,
            marker_end: 0,
            footnote_label: b"",
            is_task: false,
            task_checked: false,
            ordered: false,
            bullet_char: 0,
            delim: OrderedDelim::Period,
            start_num: None,
            tight: true,
            blank_pending: false,
            any_task: false,
            directive_name: b"",
            directive_fence_len: 0,
            directive_attrs: None,
            directive_attrs_span: None,
            div_tag: Span::new(0, 0),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LeafKind {
    Paragraph,
    IndentedCode,
    FencedCode,
    HtmlBlock,
}

struct Leaf {
    kind: LeafKind,
    text: Vec<u8>,
    text_segs: Vec<Segment>,
    start_line: usize,
    end_line: usize,
    line_count: usize,
    fence_char: u8,
    fence_len: usize,
    fence_col: usize,
    lang: Option<Vec<u8>>,
    html_type: u8,
    trailing_blanks: usize,
    body_start: Option<usize>,
    body_end: usize,
}

impl Leaf {
    fn new(kind: LeafKind, start_line: usize, end_line: usize) -> Leaf {
        Leaf {
            kind,
            text: Vec::new(),
            text_segs: Vec::new(),
            start_line,
            end_line,
            line_count: 0,
            fence_char: 0,
            fence_len: 0,
            fence_col: 0,
            lang: None,
            html_type: 0,
            trailing_blanks: 0,
            body_start: None,
            body_end: 0,
        }
    }
}

/// A leaf text block whose inline content parsing has been deferred until
/// the whole document's link reference definitions are known.
struct PendingInline {
    id: NodeId,
    text: Vec<u8>,
    segments: Vec<Segment>,
}

/// The Markdown block parser.
pub struct Parser<'s> {
    source: &'s [u8],
    lines: Vec<&'s [u8]>,
    line_starts: Vec<usize>,
    builder: Builder,
    stack: Vec<Container<'s>>,
    leaf: Option<Leaf>,
    link_references: HashMap<Vec<u8>, NodeId>,
    footnotes: HashMap<Vec<u8>, NodeId>,
    pending_inline: Vec<PendingInline>,
    options: ParseOptions,
    /// Multi-line constructs consume several lines at once and set this to
    /// the first line they DIDN'T consume.
    skip_until_line: usize,
    /// `process_line` no-ops for any index at or above this (endmatter).
    stop_at_line: usize,
    endmatter_id: Option<NodeId>,
}

impl<'s> Parser<'s> {
    pub fn new(source: &'s [u8], options: ParseOptions) -> Parser<'s> {
        let mut lines = Vec::new();
        let mut starts = Vec::new();
        let mut start = 0;
        let mut i = 0;
        while i < source.len() {
            if source[i] == b'\n' {
                let mut end = i;
                if end > start && source[end - 1] == b'\r' {
                    end -= 1;
                }
                lines.push(&source[start..end]);
                starts.push(start);
                i += 1;
                start = i;
            } else {
                i += 1;
            }
        }
        if start < source.len() {
            let mut end = source.len();
            if end > start && source[end - 1] == b'\r' {
                end -= 1;
            }
            lines.push(&source[start..end]);
            starts.push(start);
        }
        Parser {
            source,
            lines,
            line_starts: starts,
            builder: Builder::new(),
            stack: vec![Container::new(ContainerKind::Document, 0, 0)],
            leaf: None,
            link_references: HashMap::new(),
            footnotes: HashMap::new(),
            pending_inline: Vec::new(),
            options,
            skip_until_line: 0,
            stop_at_line: usize::MAX,
            endmatter_id: None,
        }
    }

    pub fn parse(mut self) -> Document {
        if self.options.frontmatter {
            self.try_consume_frontmatter();
            self.try_consume_endmatter();
        }
        for idx in 0..self.lines.len() {
            let line = self.lines[idx];
            self.process_line(line, idx);
        }
        let close_idx = if self.endmatter_id.is_some() {
            self.stop_at_line - 1
        } else if self.lines.is_empty() {
            0
        } else {
            self.lines.len() - 1
        };
        self.close_leaf(close_idx);
        while self.stack.len() > 1 {
            self.pop_container(close_idx);
        }
        self.resolve_pending_inline();

        if let Some(id) = self.endmatter_id {
            self.append_to_top(id);
        }

        let root = self.stack.pop().unwrap();
        let doc_id = self.builder.add_container(Kind::Doc, &root.children);
        self.builder.set_span(doc_id, Span::new(0, self.source.len()));
        set_content_span_from_children(&mut self.builder, doc_id);

        let mut raw = self.builder.finish_document(self.source, doc_id);
        raw.labels = Labels {
            references: std::mem::take(&mut self.link_references),
            auto_references: HashMap::new(),
            footnotes: std::mem::take(&mut self.footnotes),
        };
        // A `<div class="verse">` of paragraphs is a `line_block`.
        let raw = crate::ast::verse::run(raw);
        crate::ast::compact::run(raw)
    }

    fn resolve_pending_inline(&mut self) {
        let pending = std::mem::take(&mut self.pending_inline);
        let mut sc = inline_mod::init_scanner(&mut self.builder, &self.link_references, self.options);
        for p in pending {
            sc.in_cell = matches!(sc.b.nodes[p.id as usize].kind, Kind::Cell(_));
            let kids = inline_mod::scan_reuse(&mut sc, &p.text, &p.segments);
            sc.b.set_children(p.id, &kids);
            set_content_span_from_children(sc.b, p.id);
        }
    }

    // ── span helpers ─────────────────────────────────────────────────────

    fn line_start(&self, idx: usize) -> usize {
        self.line_starts[idx]
    }

    fn line_end(&self, idx: usize) -> usize {
        self.line_starts[idx] + self.lines[idx].len()
    }

    /// Absolute offset of a borrowed slice of `self.source`.
    fn src_off(&self, slice: &[u8]) -> usize {
        slice.as_ptr() as usize - self.source.as_ptr() as usize
    }

    fn attrs_span_in(&self, text: &[u8], p: &attrs_mod::Parsed) -> Span {
        let base = self.src_off(text);
        Span::new(base + p.start, base + p.end)
    }

    fn append_mapped_source(&self, buf: &mut Vec<u8>, segs: &mut Vec<Segment>, slice: &[u8]) {
        if slice.is_empty() {
            return;
        }
        let buf_offset = buf.len();
        buf.extend_from_slice(slice);
        segs.push(Segment { buf_offset, src_offset: self.src_off(slice), len: slice.len() });
    }

    fn single_segment(&self, slice: &[u8]) -> [Segment; 1] {
        let src_offset = if slice.is_empty() { 0 } else { self.src_off(slice) };
        [Segment { buf_offset: 0, src_offset, len: slice.len() }]
    }

    fn extend_quotes_to(&mut self, matched_index: usize, idx: usize) {
        for c in self.stack[1..matched_index].iter_mut() {
            if c.kind == ContainerKind::BlockQuote {
                c.end_line = idx;
            }
        }
    }

    fn top(&mut self) -> &mut Container<'s> {
        self.stack.last_mut().unwrap()
    }

    fn append_to_top(&mut self, id: NodeId) {
        self.top().children.push(id);
    }

    /// A blank line makes exactly ONE list loose: the deepest still-open
    /// list with a pending blank.
    fn mark_lists_loose(&mut self) {
        for c in self.stack.iter_mut().rev() {
            if c.kind == ContainerKind::List && c.blank_pending {
                c.tight = false;
                break;
            }
        }
        for c in self.stack.iter_mut() {
            if c.kind == ContainerKind::List {
                c.blank_pending = false;
            }
        }
    }

    // ── container open/close ────────────────────────────────────────────

    fn push_container(&mut self, kind: ContainerKind, line_idx: usize) {
        self.stack.push(Container::new(kind, line_idx, line_idx));
    }

    fn syntactic_span(&self, c: &Container<'s>, line_idx: usize) -> Span {
        Span::new(self.line_start(c.start_line), self.line_end(c.end_line.min(line_idx)))
    }

    fn pop_container(&mut self, line_idx: usize) {
        let c = self.stack.pop().unwrap();
        if c.kind == ContainerKind::FootnoteDef {
            self.finish_footnote_def(&c, line_idx);
            return;
        }
        if c.kind == ContainerKind::Directive {
            let id = self.builder.add_container(
                Kind::Container(AstContainer::with_form(c.directive_name, Form::BlockFenced)),
                &c.children,
            );
            let syntactic = self.syntactic_span(&c, line_idx);
            let sp = container_span_extended(&self.builder, id, syntactic);
            self.builder.set_span(id, sp);
            set_content_span_from_children(&mut self.builder, id);
            self.builder.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            if let Some(p) = c.directive_attrs {
                self.builder.set_attrs(id, Attrs { entries: p.entries });
                if let Some(sp) = c.directive_attrs_span {
                    self.builder.set_attrs_span(id, sp);
                }
            }
            self.append_to_top(id);
            return;
        }
        if c.kind == ContainerKind::HtmlDiv {
            let id = self
                .builder
                .add_container(Kind::Container(AstContainer::with_form(b"div", Form::BlockFenced)), &c.children);
            let syntactic = self.syntactic_span(&c, line_idx);
            let sp = container_span_extended(&self.builder, id, syntactic);
            self.builder.set_span(id, sp);
            set_content_span_from_children(&mut self.builder, id);
            self.builder.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Element));
            let tag_doc = inline_mod::html_parse(c.div_tag.of(self.source));
            for child in tag_doc.ast.children(tag_doc.ast.root) {
                if !matches!(child.kind, Kind::Container(_)) {
                    continue;
                }
                let attrs = tag_doc.ast.attrs_of(child.id);
                if !attrs.is_empty() {
                    self.builder.set_attrs(id, attrs.clone());
                }
                break;
            }
            self.append_to_top(id);
            return;
        }
        let kind = match c.kind {
            ContainerKind::BlockQuote => Kind::BlockQuote,
            ContainerKind::ListItem => {
                if c.is_task {
                    Kind::TaskListItem { checked: c.task_checked }
                } else {
                    Kind::ListItem
                }
            }
            ContainerKind::List => {
                if c.ordered {
                    Kind::OrderedList { numbering: ListNumbering::Decimal, tight: c.tight, start: c.start_num }
                } else if c.any_task {
                    Kind::TaskList { tight: c.tight }
                } else {
                    Kind::BulletList { tight: c.tight }
                }
            }
            _ => unreachable!(),
        };
        let id = self.builder.add_container(kind, &c.children);
        if c.kind == ContainerKind::List {
            if c.ordered {
                self.builder.set_spelling(id, Spelling::OrderedDelim(c.delim));
            } else if !c.any_task {
                self.builder.set_spelling(id, Spelling::Bullet(bullet_style(c.bullet_char)));
            }
        }
        let syntactic = self.syntactic_span(&c, line_idx);
        let sp = container_span_extended(&self.builder, id, syntactic);
        self.builder.set_span(id, sp);
        set_content_span_from_children(&mut self.builder, id);
        if c.marker_end > c.marker_start {
            self.builder.set_marker_span(id, Span::new(c.marker_start, c.marker_end));
        }
        self.append_to_top(id);
    }

    fn close_to_depth(&mut self, matched_index: usize, line_idx: usize) {
        self.close_leaf(line_idx);
        while self.stack.len() > matched_index {
            self.pop_container(line_idx);
        }
    }

    // ── leaf open/close ──────────────────────────────────────────────────

    fn leaf_kind(&self) -> Option<LeafKind> {
        self.leaf.as_ref().map(|l| l.kind)
    }

    fn close_leaf(&mut self, _line_idx: usize) {
        let Some(lf) = self.leaf.take() else { return };
        match lf.kind {
            LeafKind::Paragraph => self.finish_paragraph(lf),
            LeafKind::IndentedCode => self.finish_indented_code(lf),
            LeafKind::FencedCode => self.finish_fenced_code(lf),
            LeafKind::HtmlBlock => self.finish_html_block(lf),
        }
    }

    fn finish_paragraph(&mut self, mut lf: Leaf) {
        while let Some(&last) = lf.text.last() {
            if last == b' ' || last == b'\t' {
                lf.text.pop();
            } else {
                break;
            }
        }
        let text = &lf.text[..];
        let remaining = self.strip_link_reference_definitions(text, &lf.text_segs);
        let trimmed = trim(remaining, b" \t\r\n");
        if trimmed.is_empty() {
            return;
        }
        let segs = rebase_segments(&lf.text_segs, text, trimmed);
        self.emit_text_block(Kind::Para, trimmed, &segs, lf.start_line, lf.end_line);
    }

    fn emit_text_block(&mut self, kind: Kind, text: &[u8], segs: &[Segment], start_line: usize, end_line: usize) {
        let id = self.add_deferred_text_node(kind, text, segs, start_line, end_line);
        self.append_to_top(id);
    }

    fn add_deferred_text_node(
        &mut self,
        kind: Kind,
        text: &[u8],
        segs: &[Segment],
        start_line: usize,
        end_line: usize,
    ) -> NodeId {
        let id = self.builder.add_node(kind);
        let sp = Span::new(self.line_start(start_line), self.line_end(end_line));
        self.builder.set_span(id, sp);
        self.pending_inline.push(PendingInline { id, text: text.to_vec(), segments: segs.to_vec() });
        id
    }

    fn finish_indented_code(&mut self, mut lf: Leaf) {
        let mut len = lf.text.len();
        let mut n = lf.trailing_blanks;
        while n > 0 {
            match lf.text[..len].iter().rposition(|&c| c == b'\n') {
                Some(nl) => len = nl,
                None => len = 0,
            }
            n -= 1;
        }
        lf.text.truncate(len);
        if !lf.text.is_empty() && *lf.text.last().unwrap() != b'\n' {
            lf.text.push(b'\n');
        }
        let id = self.builder.add_leaf(Kind::CodeBlock { lang: None, text: lf.text });
        let end_line = lf.start_line.max(lf.end_line.saturating_sub(lf.trailing_blanks));
        let span = Span::new(self.line_start(lf.start_line), self.line_end(end_line));
        self.builder.set_span(id, span);
        self.builder.set_content_span(id, span);
        self.append_to_top(id);
    }

    fn finish_fenced_code(&mut self, mut lf: Leaf) {
        if !lf.text.is_empty() {
            lf.text.push(b'\n');
        }
        let id = self.builder.add_leaf(Kind::CodeBlock { lang: lf.lang, text: lf.text });
        let sp = Span::new(self.line_start(lf.start_line), self.line_end(lf.end_line));
        self.builder.set_span(id, sp);
        if let Some(bs) = lf.body_start {
            self.builder.set_content_span(id, Span::new(bs, lf.body_end));
        }
        self.append_to_top(id);
    }

    fn finish_html_block(&mut self, mut lf: Leaf) {
        if self.options.html_elements && self.promote_html_block(&lf) {
            return;
        }
        if !lf.text.is_empty() {
            lf.text.push(b'\n');
        }
        let id = self.builder.add_leaf(Kind::RawBlock { format: b"html".to_vec(), text: lf.text });
        let sp = Span::new(self.line_start(lf.start_line), self.line_end(lf.end_line));
        self.builder.set_span(id, sp);
        self.append_to_top(id);
    }

    /// Parse an HTML block's text through the shared HTML parser and splice
    /// its nodes into the current container. `false` when it can't be
    /// promoted safely.
    fn promote_html_block(&mut self, lf: &Leaf) -> bool {
        let start = self.line_start(lf.start_line);
        let text = &lf.text[..];
        if start + text.len() > self.source.len() {
            return false;
        }
        if &self.source[start..start + text.len()] != text {
            return false;
        }
        let html_doc = inline_mod::html_parse(text);
        let root = self.builder.graft_document(&html_doc, start);
        let mut child = self.builder.nodes[root as usize].first_child;
        let mut promoted_any = false;
        while let Some(cid) = child {
            let next = self.builder.nodes[cid as usize].next_sibling;
            if !is_blank_str_node(&self.builder.nodes[cid as usize].kind) {
                self.builder.nodes[cid as usize].next_sibling = None;
                self.append_to_top(cid);
                promoted_any = true;
            }
            child = next;
        }
        promoted_any
    }

    // ── the per-line driver ──────────────────────────────────────────────

    fn match_containers(&self, line: &[u8]) -> (usize, Cursor) {
        let mut cur = Cursor::default();
        let mut i = 1;
        while i < self.stack.len() {
            let c = &self.stack[i];
            match c.kind {
                ContainerKind::Document => unreachable!(),
                ContainerKind::List | ContainerKind::Directive | ContainerKind::HtmlDiv => {}
                ContainerKind::BlockQuote => match match_block_quote(line, cur) {
                    Some(nc) => cur = nc,
                    None => break,
                },
                ContainerKind::ListItem | ContainerKind::FootnoteDef => match match_list_item(line, cur, c.content_col) {
                    Some(nc) => cur = nc,
                    None => break,
                },
            }
            i += 1;
        }
        (i, cur)
    }

    fn process_line(&mut self, line: &'s [u8], idx: usize) {
        if idx < self.skip_until_line {
            return;
        }
        if idx >= self.stop_at_line {
            return;
        }
        let (matched_index, cur) = self.match_containers(line);
        self.extend_quotes_to(matched_index, idx);

        if matched_index < self.stack.len() {
            let remainder0 = &line[cur.pos..];
            if !is_blank_line(remainder0)
                && self.leaf_kind() == Some(LeafKind::Paragraph)
                && !self.can_interrupt_paragraph(remainder0)
            {
                self.append_paragraph_line(remainder0, idx);
                return;
            }
            self.close_to_depth(matched_index, idx);
        }

        let remainder = &line[cur.pos..];
        if is_blank_line(remainder) {
            self.handle_blank_line(line, cur, idx);
            return;
        }

        if let Some(kind) = self.leaf_kind() {
            match kind {
                LeafKind::FencedCode => {
                    self.continue_fenced_code(line, cur, idx);
                    return;
                }
                LeafKind::HtmlBlock => {
                    self.continue_html_block(remainder, idx);
                    return;
                }
                LeafKind::IndentedCode => {
                    if indent_cols(line, cur) >= 4 {
                        self.continue_indented_code(line, cur, idx);
                        return;
                    }
                    self.close_leaf(idx);
                }
                LeafKind::Paragraph => {
                    let single = {
                        let lf = self.leaf.as_ref().unwrap();
                        lf.start_line == lf.end_line
                    };
                    if self.options.definition_lists && single && self.try_start_definition_list(line, cur, idx) {
                        return;
                    }
                    if let Some(level) = try_setext_underline(strip_up_to3_indent(remainder)) {
                        if self.close_paragraph_as_heading(level, idx) {
                            return;
                        }
                    }
                }
            }
        }

        let interrupting = self.leaf_kind() == Some(LeafKind::Paragraph);
        if self.try_start_blocks(line, cur, idx, interrupting) {
            return;
        }

        if self.leaf_kind() == Some(LeafKind::Paragraph) {
            self.append_paragraph_line(remainder, idx);
        } else {
            self.open_paragraph(remainder, idx);
        }
    }

    fn handle_blank_line(&mut self, line: &'s [u8], cur: Cursor, idx: usize) {
        let remainder = &line[cur.pos..];
        let mut interior_of_leaf = false;
        if let Some(kind) = self.leaf_kind() {
            match kind {
                LeafKind::Paragraph => self.close_leaf(idx),
                LeafKind::IndentedCode => {
                    let lf = self.leaf.as_mut().unwrap();
                    if lf.line_count > 0 {
                        lf.text.push(b'\n');
                    }
                    let stripped = skip_ws_up_to_cols(remainder, Cursor::default(), 4);
                    lf.text.extend_from_slice(&remainder[stripped.pos..]);
                    lf.line_count += 1;
                    lf.trailing_blanks += 1;
                    lf.end_line = idx;
                }
                LeafKind::FencedCode => {
                    self.continue_fenced_code(line, cur, idx);
                    interior_of_leaf = true;
                }
                LeafKind::HtmlBlock => {
                    let t = self.leaf.as_ref().unwrap().html_type;
                    if t == 6 || t == 7 {
                        self.close_leaf(idx);
                    } else {
                        let lf = self.leaf.as_mut().unwrap();
                        if !lf.text.is_empty() {
                            lf.text.push(b'\n');
                        }
                        lf.text.extend_from_slice(remainder);
                        lf.end_line = idx;
                        interior_of_leaf = true;
                    }
                }
            }
        }
        if !interior_of_leaf {
            {
                let top_c = self.stack.last().unwrap();
                if top_c.kind == ContainerKind::ListItem && top_c.children.is_empty() && self.leaf.is_none() {
                    self.pop_container(idx);
                }
            }
            let top_kind = self.stack.last().unwrap().kind;
            if top_kind != ContainerKind::BlockQuote && top_kind != ContainerKind::FootnoteDef {
                for c in self.stack.iter_mut() {
                    if c.kind == ContainerKind::List {
                        c.blank_pending = true;
                    }
                }
            }
        }
    }

    // ── paragraph accumulation ──────────────────────────────────────────

    fn open_paragraph(&mut self, remainder: &'s [u8], idx: usize) {
        self.maybe_close_top_list(idx, None);
        self.mark_lists_loose();
        let mut lf = Leaf::new(LeafKind::Paragraph, idx, idx);
        let mut text = Vec::new();
        let mut segs = Vec::new();
        self.append_mapped_source(&mut text, &mut segs, trim_leading_ws(remainder));
        lf.text = text;
        lf.text_segs = segs;
        self.leaf = Some(lf);
    }

    fn append_paragraph_line(&mut self, remainder: &'s [u8], idx: usize) {
        let slice = trim_leading_ws(remainder);
        let src_offset = if slice.is_empty() { 0 } else { self.src_off(slice) };
        let lf = self.leaf.as_mut().unwrap();
        lf.text.push(b'\n');
        if !slice.is_empty() {
            let buf_offset = lf.text.len();
            lf.text.extend_from_slice(slice);
            lf.text_segs.push(Segment { buf_offset, src_offset, len: slice.len() });
        }
        lf.end_line = idx;
    }

    fn close_paragraph_as_heading(&mut self, level: u32, idx: usize) -> bool {
        let lf = self.leaf.take().unwrap();
        let text = &lf.text[..];
        let remaining = self.strip_link_reference_definitions(text, &lf.text_segs);
        let trimmed = trim(remaining, b" \t\r\n");
        if trimmed.is_empty() {
            return false;
        }
        let segs = rebase_segments(&lf.text_segs, text, trimmed);
        self.emit_text_block(Kind::Heading { level }, trimmed, &segs, lf.start_line, idx);
        true
    }

    // ── indented code ────────────────────────────────────────────────────

    fn append_indented_content(buf: &mut Vec<u8>, line: &[u8], cur: Cursor) {
        let mut col = cur.col;
        let mut i = cur.pos;
        let mut spent = cur.spent;
        let mut consumed = 0;
        while i < line.len() && consumed < 4 {
            let c = line[i];
            if c == b' ' {
                col += 1;
                i += 1;
                consumed += 1;
                spent = 0;
            } else if c == b'\t' {
                let avail = (4 - (col % 4)) - spent;
                if consumed + avail <= 4 {
                    consumed += avail;
                    col += 4 - (col % 4);
                    i += 1;
                    spent = 0;
                } else {
                    let leftover = avail - (4 - consumed);
                    buf.extend(std::iter::repeat_n(b' ', leftover));
                    i += 1;
                    buf.extend_from_slice(&line[i..]);
                    return;
                }
            } else {
                break;
            }
        }
        buf.extend_from_slice(&line[i..]);
    }

    fn continue_indented_code(&mut self, line: &[u8], cur: Cursor, idx: usize) {
        let lf = self.leaf.as_mut().unwrap();
        if lf.line_count > 0 {
            lf.text.push(b'\n');
        }
        Self::append_indented_content(&mut lf.text, line, cur);
        lf.line_count += 1;
        lf.trailing_blanks = 0;
        lf.end_line = idx;
    }

    // ── fenced code ──────────────────────────────────────────────────────

    fn continue_fenced_code(&mut self, line: &[u8], cur: Cursor, idx: usize) {
        let remainder = &line[cur.pos..];
        let (fence_char, fence_len, fence_col) = {
            let lf = self.leaf.as_ref().unwrap();
            (lf.fence_char, lf.fence_len, lf.fence_col)
        };
        if indent_cols(remainder, Cursor::default()) < 4
            && is_fence_close(strip_up_to3_indent(remainder), fence_char, fence_len)
        {
            self.leaf.as_mut().unwrap().end_line = idx;
            self.close_leaf(idx);
            return;
        }
        let ls = self.line_start(idx);
        let le = self.line_end(idx);
        let lf = self.leaf.as_mut().unwrap();
        if lf.line_count > 0 {
            lf.text.push(b'\n');
        }
        let strip_cols = fence_col.saturating_sub(cur.col);
        let stripped = skip_ws_up_to_cols(line, cur, strip_cols);
        lf.text.extend_from_slice(&line[stripped.pos..]);
        lf.line_count += 1;
        lf.end_line = idx;
        if lf.body_start.is_none() {
            lf.body_start = Some(ls);
        }
        lf.body_end = le;
    }

    // ── html block ───────────────────────────────────────────────────────

    fn continue_html_block(&mut self, remainder: &[u8], idx: usize) {
        let lf = self.leaf.as_mut().unwrap();
        if !lf.text.is_empty() {
            lf.text.push(b'\n');
        }
        lf.text.extend_from_slice(remainder);
        lf.end_line = idx;
        let ends = html_block_ends(lf.html_type, remainder);
        if ends {
            self.close_leaf(idx);
        }
    }

    // ── new block start scanning ────────────────────────────────────────

    fn can_interrupt_paragraph(&self, remainder: &[u8]) -> bool {
        let indent = indent_cols(remainder, Cursor::default());
        if indent >= 4 {
            return false;
        }
        let s = strip_up_to3_indent(remainder);
        if !s.is_empty() && s[0] == b'>' {
            return true;
        }
        if self.options.directives && self.looks_like_directive(s) {
            return true;
        }
        if is_thematic_break(s) {
            return true;
        }
        if try_atx_heading(s).is_some() {
            return true;
        }
        if try_fence_open(s).is_some() {
            return true;
        }
        if let Some(mk) = try_list_marker(s) {
            let after = &s[mk.marker_len..];
            if self.is_inside_list_item() {
                return true;
            }
            if !is_blank_line(after) && (!mk.ordered || mk.start.unwrap() == 1) {
                return true;
            }
        }
        if self.options.footnotes && self.is_inside_footnote_def() && try_footnote_def_marker(s).is_some() {
            return true;
        }
        if !s.is_empty() && s[0] == b'<' {
            if let Some(t) = detect_html_block_start(s, self.options.html_elements) {
                if t != 7 {
                    return true;
                }
            }
        }
        false
    }

    // ── generic directives ──────────────────────────────────────────────

    fn looks_like_directive(&self, s: &[u8]) -> bool {
        let n = count_colons(s);
        if n >= 3 {
            if is_blank_line(&s[n..]) {
                return self.innermost_directive_index(n).is_some();
            }
            return attrs_mod::scan_name(s, n).is_some();
        }
        if n == 2 {
            return attrs_mod::scan_name(s, 2).is_some();
        }
        false
    }

    fn innermost_directive_index(&self, close_len: usize) -> Option<usize> {
        let mut i = self.stack.len();
        while i > 0 {
            i -= 1;
            let c = &self.stack[i];
            if c.kind == ContainerKind::Directive {
                return if c.directive_fence_len <= close_len { Some(i) } else { None };
            }
        }
        None
    }

    // ── paired <div> ─────────────────────────────────────────────────────

    fn try_div_fence(&mut self, s: &'s [u8], idx: usize, interrupting: bool) -> bool {
        if div_closer_end(s).is_some() {
            if !self.next_line_is_blank(idx) {
                return false;
            }
            let Some(d_idx) = self.innermost_div_index() else { return false };
            self.stack[d_idx].end_line = idx;
            self.close_to_depth(d_idx, idx);
            return true;
        }
        let Some(tag_end) = div_opener_end(s) else { return false };
        if !self.next_line_is_blank(idx) {
            return false;
        }
        if !self.has_bare_div_closer(idx + 1) {
            return false;
        }
        if interrupting {
            self.close_leaf(idx);
        }
        self.maybe_close_top_list(idx, None);
        self.mark_lists_loose();
        self.push_container(ContainerKind::HtmlDiv, idx);
        let base = self.src_off(s);
        self.top().div_tag = Span::new(base, base + tag_end);
        true
    }

    fn next_line_is_blank(&self, idx: usize) -> bool {
        let next = idx + 1;
        if next >= self.lines.len() || next >= self.stop_at_line {
            return true;
        }
        let (mi, cur) = self.match_containers(self.lines[next]);
        if mi < self.stack.len() {
            return false;
        }
        is_blank_line(&self.lines[next][cur.pos..])
    }

    fn has_bare_div_closer(&self, from: usize) -> bool {
        let mut depth = 0usize;
        let stop = self.lines.len().min(self.stop_at_line);
        let mut i = from;
        while i < stop {
            let t = trim_start(self.lines[i], b" \t>");
            let bare = i + 1 >= stop || is_blank_line(trim_start(self.lines[i + 1], b" \t>"));
            if bare {
                if div_opener_end(t).is_some() {
                    depth += 1;
                } else if div_closer_end(t).is_some() {
                    if depth == 0 {
                        return true;
                    }
                    depth -= 1;
                }
            }
            i += 1;
        }
        false
    }

    fn innermost_div_index(&self) -> Option<usize> {
        self.stack.iter().rposition(|c| c.kind == ContainerKind::HtmlDiv)
    }

    fn parse_directive_open(&self, s: &'s [u8], n: usize) -> Option<(&'s [u8], Option<attrs_mod::Parsed>)> {
        let name_end = attrs_mod::scan_name(s, n)?;
        let name = &s[n..name_end];
        let mut i = name_end;
        if i < s.len() && s[i] == b'[' {
            if let Some(raw) = inline_mod::scan_directive_label(s, i) {
                i = raw.end;
            }
        }
        let mut attrs = None;
        if i < s.len() && s[i] == b'{' {
            if let Some(p) = attrs_mod::parse(s, i) {
                i = p.end;
                attrs = Some(p);
            }
        }
        if !is_blank_line(&s[i..]) {
            return None;
        }
        Some((name, attrs))
    }

    fn parse_leaf_directive(&mut self, s: &'s [u8], idx: usize, interrupting: bool) -> bool {
        let Some(name_end) = attrs_mod::scan_name(s, 2) else { return false };
        let name = &s[2..name_end];
        let mut i = name_end;
        let mut label: Option<&'s [u8]> = None;
        if i < s.len() && s[i] == b'[' {
            if let Some(raw) = inline_mod::scan_directive_label(s, i) {
                label = Some(raw.content);
                i = raw.end;
            }
        }
        let mut attrs = None;
        if i < s.len() && s[i] == b'{' {
            if let Some(p) = attrs_mod::parse(s, i) {
                i = p.end;
                attrs = Some(p);
            }
        }
        if !is_blank_line(&s[i..]) {
            return false;
        }

        if interrupting {
            self.close_leaf(idx);
        }
        self.maybe_close_top_list(idx, None);
        self.mark_lists_loose();

        let kind = Kind::Container(AstContainer::with_form(name, Form::BlockLeaf));
        let id = match label {
            Some(lab) => {
                let seg = self.single_segment(lab);
                self.add_deferred_text_node(kind, lab, &seg, idx, idx)
            }
            None => {
                let nid = self.builder.add_node(kind);
                let sp = Span::new(self.line_start(idx), self.line_end(idx));
                self.builder.set_span(nid, sp);
                nid
            }
        };
        self.builder.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
        if let Some(p) = attrs {
            let sp = self.attrs_span_in(s, &p);
            self.builder.set_attrs(id, Attrs { entries: p.entries });
            self.builder.set_attrs_span(id, sp);
        }
        self.append_to_top(id);
        true
    }

    fn try_start_directive(&mut self, s: &'s [u8], idx: usize, interrupting: bool) -> bool {
        let n = count_colons(s);
        if n < 2 {
            return false;
        }
        if n >= 3 {
            if is_blank_line(&s[n..]) {
                let Some(d_idx) = self.innermost_directive_index(n) else { return false };
                self.stack[d_idx].end_line = idx;
                self.close_to_depth(d_idx, idx);
                return true;
            }
            if let Some((name, attrs)) = self.parse_directive_open(s, n) {
                if interrupting {
                    self.close_leaf(idx);
                }
                self.maybe_close_top_list(idx, None);
                self.mark_lists_loose();
                self.push_container(ContainerKind::Directive, idx);
                let span = attrs.as_ref().map(|p| self.attrs_span_in(s, p));
                let c = self.top();
                c.directive_name = name;
                c.directive_fence_len = n;
                c.directive_attrs = attrs;
                c.directive_attrs_span = span;
                return true;
            }
            return false;
        }
        self.parse_leaf_directive(s, idx, interrupting)
    }

    fn try_start_blocks(&mut self, line: &'s [u8], cur_in: Cursor, idx: usize, interrupting_paragraph: bool) -> bool {
        let mut cur = cur_in;
        let mut interrupting = interrupting_paragraph;
        let mut pushed_any = false;
        loop {
            let remainder = &line[cur.pos..];
            let indent = indent_cols(line, cur);

            if indent < 4 {
                let s = strip_up_to3_indent(remainder);
                let indent_bytes = remainder.len() - s.len();

                if self.options.directives && self.try_start_directive(s, idx, interrupting) {
                    return true;
                }

                if !s.is_empty() && s[0] == b'>' {
                    if interrupting {
                        self.close_leaf(idx);
                    }
                    self.maybe_close_top_list(idx, None);
                    self.mark_lists_loose();
                    self.push_container(ContainerKind::BlockQuote, idx);
                    let line_at = self.line_start(idx);
                    let bq_marker_start = line_at + cur.pos + indent_bytes;
                    cur = match_block_quote(line, cur).unwrap();
                    self.top().marker_start = bq_marker_start;
                    self.top().marker_end = line_at + cur.pos;
                    interrupting = false;
                    pushed_any = true;
                    continue;
                }

                if is_thematic_break(s) {
                    if interrupting {
                        self.close_leaf(idx);
                    }
                    self.maybe_close_top_list(idx, None);
                    self.mark_lists_loose();
                    let id = self.builder.add_leaf(Kind::ThematicBreak);
                    let sp = Span::new(self.line_start(idx), self.line_end(idx));
                    self.builder.set_span(id, sp);
                    self.append_to_top(id);
                    return true;
                }

                if let Some(h) = try_atx_heading(s) {
                    if interrupting {
                        self.close_leaf(idx);
                    }
                    self.maybe_close_top_list(idx, None);
                    self.mark_lists_loose();
                    let heading_text = trim(h.content, b" \t");
                    let seg = self.single_segment(heading_text);
                    let hid = self.add_deferred_text_node(Kind::Heading { level: h.level }, heading_text, &seg, idx, idx);
                    let h_start = self.line_start(idx) + cur.pos + indent_bytes;
                    self.builder.set_marker_span(hid, Span::new(h_start, h_start + h.marker_len));
                    self.append_to_top(hid);
                    return true;
                }

                if let Some(f) = try_fence_open(s) {
                    if interrupting {
                        self.close_leaf(idx);
                    }
                    self.maybe_close_top_list(idx, None);
                    self.mark_lists_loose();
                    let mut lf = Leaf::new(LeafKind::FencedCode, idx, idx);
                    lf.fence_char = f.ch;
                    lf.fence_len = f.len;
                    lf.fence_col = cur.col + indent_bytes;
                    if !f.info.is_empty() {
                        let decoded = inline_mod::decode_text(f.info);
                        let mut word_end = 0;
                        while word_end < decoded.len() && decoded[word_end] != b' ' && decoded[word_end] != b'\t' {
                            word_end += 1;
                        }
                        lf.lang = Some(decoded[..word_end].to_vec());
                    }
                    self.leaf = Some(lf);
                    return true;
                }

                if let Some(mk) = try_list_marker(s) {
                    let after = &s[mk.marker_len..];
                    let item_blank = is_blank_line(after);
                    let eligible = !interrupting
                        || self.is_inside_list_item()
                        || (!item_blank && (!mk.ordered || mk.start.unwrap() == 1));
                    if eligible {
                        if interrupting {
                            self.close_leaf(idx);
                        }
                        let reuse = self.top_is_compatible_list(&mk);
                        if !reuse {
                            self.maybe_close_top_list(idx, Some(mk));
                            self.mark_lists_loose();
                            self.push_container(ContainerKind::List, idx);
                            let lc = self.top();
                            lc.ordered = mk.ordered;
                            lc.bullet_char = mk.bullet_char;
                            lc.delim = mk.delim;
                            lc.start_num = mk.start;
                            lc.tight = true;
                        } else {
                            self.mark_lists_loose();
                        }
                        let item_marker_start = self.line_start(idx) + cur.pos + indent_bytes;
                        let marker_col = cur.col + indent_bytes;
                        let after_marker_col = marker_col + mk.marker_len;
                        let content_col = if item_blank {
                            after_marker_col + 1
                        } else {
                            let spaces = indent_cols(after, Cursor { pos: 0, col: after_marker_col, spent: 0 });
                            if (1..=4).contains(&spaces) { after_marker_col + spaces } else { after_marker_col + 1 }
                        };
                        self.push_container(ContainerKind::ListItem, idx);
                        self.top().content_col = content_col.saturating_sub(cur.col + cur.spent);
                        let after_marker_cursor =
                            Cursor { pos: cur.pos + indent_bytes + mk.marker_len, col: after_marker_col, spent: 0 };
                        cur = skip_ws_to_target(line, after_marker_cursor, content_col);
                        if self.options.task_lists && !mk.ordered {
                            if let Some(tm) = try_task_list_marker(&line[cur.pos..]) {
                                self.top().is_task = true;
                                self.top().task_checked = tm.checked;
                                let n = self.stack.len();
                                if n >= 2 {
                                    self.stack[n - 2].any_task = true;
                                }
                                let consumed = line[cur.pos..].len() - tm.rest.len();
                                cur = Cursor { pos: cur.pos + consumed, col: cur.col + consumed, spent: 0 };
                            }
                        }
                        let me = self.line_start(idx) + cur.pos;
                        self.top().marker_start = item_marker_start;
                        self.top().marker_end = me;
                        interrupting = false;
                        pushed_any = true;
                        continue;
                    }
                }

                if self.options.tables && !interrupting && self.try_start_table(line, cur, idx) {
                    return true;
                }

                if self.options.footnotes && !interrupting && self.try_start_footnote_def(line, cur, idx) {
                    return true;
                }

                if self.options.html_elements && !s.is_empty() && s[0] == b'<' && self.try_div_fence(s, idx, interrupting) {
                    return true;
                }

                if !s.is_empty() && s[0] == b'<' {
                    if let Some(t) = detect_html_block_start(s, self.options.html_elements) {
                        if !interrupting || t != 7 {
                            if interrupting {
                                self.close_leaf(idx);
                            }
                            self.maybe_close_top_list(idx, None);
                            self.mark_lists_loose();
                            let mut lf = Leaf::new(LeafKind::HtmlBlock, idx, idx);
                            lf.html_type = t;
                            lf.text.extend_from_slice(remainder);
                            self.leaf = Some(lf);
                            if html_block_ends(t, remainder) {
                                self.close_leaf(idx);
                            }
                            return true;
                        }
                    }
                }
            } else if !interrupting {
                self.maybe_close_top_list(idx, None);
                let mut lf = Leaf::new(LeafKind::IndentedCode, idx, idx);
                lf.line_count = 1;
                Self::append_indented_content(&mut lf.text, line, cur);
                self.mark_lists_loose();
                self.leaf = Some(lf);
                return true;
            }

            if !pushed_any {
                return false;
            }
            let final_remainder = &line[cur.pos..];
            if !is_blank_line(final_remainder) {
                self.open_paragraph(final_remainder, idx);
            }
            return true;
        }
    }

    fn maybe_close_top_list(&mut self, idx: usize, mk: Option<ListMarker>) {
        if self.stack.last().unwrap().kind != ContainerKind::List {
            return;
        }
        if let Some(m) = mk {
            if self.top_is_compatible_list(&m) {
                return;
            }
        }
        self.pop_container(idx);
    }

    fn top_is_compatible_list(&self, mk: &ListMarker) -> bool {
        list_compatible(self.stack.last().unwrap(), mk)
    }

    fn is_inside_list_item(&self) -> bool {
        self.stack.last().unwrap().kind == ContainerKind::ListItem
    }

    fn is_inside_footnote_def(&self) -> bool {
        self.stack.last().unwrap().kind == ContainerKind::FootnoteDef
    }

    // ── frontmatter ──────────────────────────────────────────────────────

    fn try_consume_frontmatter(&mut self) {
        if self.lines.is_empty() {
            return;
        }
        let first = trim_end(self.lines[0], b" \t");
        let delim: &[u8] = if first.starts_with(b"---") {
            b"---"
        } else if first.starts_with(b"+++") {
            b"+++"
        } else {
            return;
        };
        let rest = trim(&first[3..], b" \t");
        let lang: &[u8] = if rest.is_empty() {
            if delim[0] == b'-' { b"yaml" } else { b"toml" }
        } else if is_lang_tag(rest) {
            rest
        } else {
            return;
        };

        for i in 1..self.lines.len() {
            let line = trim_end(self.lines[i], b" \t");
            if line != delim {
                continue;
            }
            let mut text = Vec::new();
            for content_line in &self.lines[1..i] {
                text.extend_from_slice(content_line);
                text.push(b'\n');
            }
            let id = self.builder.add_leaf(Kind::Metadata { lang: lang.to_vec(), text });
            let sp = Span::new(self.line_start(0), self.line_end(i));
            self.builder.set_span(id, sp);
            if i > 1 {
                let cs = Span::new(self.line_start(1), self.line_end(i - 1));
                self.builder.set_content_span(id, cs);
            }
            self.append_to_top(id);
            self.skip_until_line = i + 1;
            return;
        }
    }

    fn try_consume_endmatter(&mut self) {
        if self.lines.is_empty() {
            return;
        }
        let mut last = self.lines.len();
        while last > 0 {
            if !is_blank_line(self.lines[last - 1]) {
                break;
            }
            last -= 1;
        }
        if last == 0 {
            return;
        }
        last -= 1;
        if trim_end(self.lines[last], b" \t") != b"---" {
            return;
        }
        if last < self.skip_until_line + 2 {
            return;
        }

        let mut open = last;
        let lo = self.skip_until_line;
        while open > lo {
            open -= 1;
            let t = trim_end(self.lines[open], b" \t");
            if !t.starts_with(b"---") {
                continue;
            }
            let rest = trim(&t[3..], b" \t");
            if !is_lang_tag(rest) {
                continue;
            }
            if open == 0 || open - 1 < self.skip_until_line {
                return;
            }
            if !is_blank_line(self.lines[open - 1]) {
                return;
            }
            let mut text = Vec::new();
            for content_line in &self.lines[open + 1..last] {
                text.extend_from_slice(content_line);
                text.push(b'\n');
            }
            let id = self.builder.add_leaf(Kind::Metadata { lang: rest.to_vec(), text });
            let sp = Span::new(self.line_start(open), self.line_end(last));
            self.builder.set_span(id, sp);
            if last > open + 1 {
                let cs = Span::new(self.line_start(open + 1), self.line_end(last - 1));
                self.builder.set_content_span(id, cs);
            }
            self.endmatter_id = Some(id);
            self.stop_at_line = open;
            return;
        }
    }

    // ── GFM tables ───────────────────────────────────────────────────────

    fn try_start_table(&mut self, line: &'s [u8], cur: Cursor, idx: usize) -> bool {
        let remainder = &line[cur.pos..];
        let s = strip_up_to3_indent(remainder);
        if is_blank_line(s) {
            return false;
        }
        if !contains_unescaped_pipe(s) {
            return false;
        }
        if idx + 1 >= self.lines.len() {
            return false;
        }
        let next_line = self.lines[idx + 1];
        let (nmi, ncur) = self.match_containers(next_line);
        if nmi != self.stack.len() {
            return false;
        }
        let next_remainder = &next_line[ncur.pos..];
        if indent_cols(next_remainder, Cursor::default()) >= 4 {
            return false;
        }
        let next_s = strip_up_to3_indent(next_remainder);

        let header_cells = split_table_row(s);
        if header_cells.is_empty() {
            return false;
        }
        let Some(aligns) = parse_delimiter_row(next_s) else { return false };
        if aligns.len() != header_cells.len() {
            return false;
        }

        self.maybe_close_top_list(idx, None);
        self.mark_lists_loose();

        let mut row_ids = Vec::new();
        let header_row_id = self.build_table_row(s, &header_cells, &aligns, true, idx, idx);
        row_ids.push(header_row_id);

        let mut last_idx = idx + 1;
        let mut scan = idx + 2;
        while scan < self.lines.len() {
            let row_line = self.lines[scan];
            let (rmi, rcur) = self.match_containers(row_line);
            if rmi != self.stack.len() {
                break;
            }
            let row_remainder = &row_line[rcur.pos..];
            if is_blank_line(row_remainder) {
                break;
            }
            if indent_cols(row_remainder, Cursor::default()) >= 4 {
                break;
            }
            let row_s = strip_up_to3_indent(row_remainder);
            if looks_like_new_block_start(row_s, self.options.html_elements) {
                break;
            }
            let raw_cells = split_table_row(row_s);
            let row_id = self.build_table_row(row_s, &raw_cells, &aligns, false, scan, scan);
            row_ids.push(row_id);
            last_idx = scan;
            scan += 1;
        }

        let caption_id = self.builder.add_container(Kind::Caption, &[]);
        let mut all_children = vec![caption_id];
        all_children.extend_from_slice(&row_ids);
        let table_id = self.builder.add_container(Kind::Table, &all_children);
        let sp = Span::new(self.line_start(idx), self.line_end(last_idx));
        self.builder.set_span(table_id, sp);
        set_content_span_from_children(&mut self.builder, table_id);
        self.append_to_top(table_id);

        self.skip_until_line = last_idx + 1;
        true
    }

    /// GFM: a `\|` inside a table cell is an ESCAPED pipe, unescaped here up
    /// front (with a segment list mapping the rewritten text back).
    fn unescape_cell_pipes(&self, cell: &[u8], out: &mut Vec<u8>, segs: &mut Vec<Segment>) {
        let src_base = self.src_off(cell);
        let mut run_start = 0;
        let mut i = 0;
        while i < cell.len() {
            if cell[i] == b'\\' && i + 1 < cell.len() && cell[i + 1] == b'|' {
                append_cell_run(cell, run_start, i, src_base, out, segs);
                run_start = i + 1;
                i += 2;
                continue;
            }
            i += 1;
        }
        append_cell_run(cell, run_start, cell.len(), src_base, out, segs);
    }

    fn build_table_row(
        &mut self,
        row: &'s [u8],
        cells: &[&'s [u8]],
        aligns: &[Alignment],
        head: bool,
        start_line: usize,
        end_line: usize,
    ) -> NodeId {
        let mut cell_ids = Vec::new();
        let extents = table_cell_extents(row);
        let row_base = self.src_off(row);
        for (i, &al) in aligns.iter().enumerate() {
            let text: &[u8] = if i < cells.len() { cells[i] } else { b"" };
            let kind = Kind::Cell(Cell::new(head, al));
            let cell_id = if index_of(text, 0, b"\\|").is_none() {
                let seg = self.single_segment(text);
                self.add_deferred_text_node(kind, text, &seg, start_line, end_line)
            } else {
                let mut out = Vec::new();
                let mut segs = Vec::new();
                self.unescape_cell_pipes(text, &mut out, &mut segs);
                self.add_deferred_text_node(kind, &out, &segs, start_line, end_line)
            };
            let ext = if i < extents.len() {
                extents[i]
            } else {
                let end = if !extents.is_empty() { extents[extents.len() - 1][1] } else { row.len() };
                [end, end]
            };
            self.builder.set_span(cell_id, Span::new(row_base + ext[0], row_base + ext[1]));
            cell_ids.push(cell_id);
        }
        let row_id = self.builder.add_container(Kind::Row { head }, &cell_ids);
        let sp = Span::new(self.line_start(start_line), self.line_end(end_line));
        self.builder.set_span(row_id, sp);
        row_id
    }

    // ── definition lists ─────────────────────────────────────────────────

    fn try_start_definition_list(&mut self, line: &'s [u8], cur: Cursor, idx: usize) -> bool {
        let s = strip_up_to3_indent(&line[cur.pos..]);
        if !is_definition_marker_line(s) {
            return false;
        }
        let (term_text, term_segs, lf_start_line) = {
            let lf = self.leaf.as_ref().unwrap();
            let trimmed_term = trim(&lf.text, b" \t\r\n");
            if trimmed_term.is_empty() {
                return false;
            }
            let segs = rebase_segments(&lf.text_segs, &lf.text, trimmed_term);
            (trimmed_term.to_vec(), segs, lf.start_line)
        };
        let mut term_start_line = lf_start_line;
        let list_start_line = lf_start_line;
        self.leaf = None;

        self.maybe_close_top_list(idx, None);
        self.mark_lists_loose();

        let mut item_ids = Vec::new();
        let mut scan = idx;
        let mut last_idx = idx;
        let mut current_term: Vec<u8> = term_text;
        let mut current_term_segs: Vec<Segment> = term_segs;

        loop {
            let term_id =
                self.add_deferred_text_node(Kind::Term, &current_term, &current_term_segs, term_start_line, term_start_line);
            let mut def_ids = Vec::new();

            while scan < self.lines.len() {
                let dline = self.lines[scan];
                let (dmi, dcur) = self.match_containers(dline);
                if dmi != self.stack.len() {
                    break;
                }
                let ds = strip_up_to3_indent(&dline[dcur.pos..]);
                if !is_definition_marker_line(ds) {
                    break;
                }
                let mut content = Vec::new();
                let mut content_segs = Vec::new();
                self.append_mapped_source(&mut content, &mut content_segs, trim_leading_ws(&ds[1..]));
                let def_start = scan;
                let mut def_end = scan;
                scan += 1;
                while scan < self.lines.len() {
                    let cline = self.lines[scan];
                    let (cmi, ccur) = self.match_containers(cline);
                    if cmi != self.stack.len() {
                        break;
                    }
                    let crem = &cline[ccur.pos..];
                    if is_blank_line(crem) {
                        break;
                    }
                    let cs = strip_up_to3_indent(crem);
                    if is_definition_marker_line(cs) {
                        break;
                    }
                    if looks_like_new_block_start(cs, self.options.html_elements) {
                        break;
                    }
                    content.push(b'\n');
                    self.append_mapped_source(&mut content, &mut content_segs, trim_leading_ws(crem));
                    def_end = scan;
                    scan += 1;
                }
                let def_id = self.add_deferred_text_node(Kind::Definition, &content, &content_segs, def_start, def_end);
                def_ids.push(def_id);
                last_idx = def_end;
            }
            if def_ids.is_empty() {
                break;
            }

            let mut item_children = vec![term_id];
            item_children.extend_from_slice(&def_ids);
            let item_id = self.builder.add_container(Kind::DefinitionListItem, &item_children);
            let sp = Span::new(self.line_start(term_start_line), self.line_end(last_idx));
            self.builder.set_span(item_id, sp);
            item_ids.push(item_id);

            let mut next_idx = scan;
            if next_idx < self.lines.len() {
                let bl = self.lines[next_idx];
                let (bmi, bcur) = self.match_containers(bl);
                if bmi == self.stack.len() && is_blank_line(&bl[bcur.pos..]) {
                    next_idx += 1;
                }
            }
            if next_idx >= self.lines.len() || next_idx + 1 >= self.lines.len() {
                break;
            }
            let tl = self.lines[next_idx];
            let (tmi, tcur) = self.match_containers(tl);
            if tmi != self.stack.len() {
                break;
            }
            let trem = &tl[tcur.pos..];
            if is_blank_line(trem) || indent_cols(trem, Cursor::default()) >= 4 {
                break;
            }
            let ts = strip_up_to3_indent(trem);
            if is_definition_marker_line(ts) || looks_like_new_block_start(ts, self.options.html_elements) {
                break;
            }
            let dl2 = self.lines[next_idx + 1];
            let (dmi2, dcur2) = self.match_containers(dl2);
            if dmi2 != self.stack.len() {
                break;
            }
            let ds2 = strip_up_to3_indent(&dl2[dcur2.pos..]);
            if !is_definition_marker_line(ds2) {
                break;
            }
            let next_term_text = trim(ts, b" \t\r\n");
            current_term = next_term_text.to_vec();
            current_term_segs = self.single_segment(next_term_text).to_vec();
            term_start_line = next_idx;
            scan = next_idx + 1;
        }

        let list_id = self.builder.add_container(Kind::DefinitionList, &item_ids);
        let sp = Span::new(self.line_start(list_start_line), self.line_end(last_idx));
        self.builder.set_span(list_id, sp);
        set_content_span_from_children(&mut self.builder, list_id);
        self.append_to_top(list_id);
        self.skip_until_line = last_idx + 1;
        true
    }

    // ── footnote definitions ────────────────────────────────────────────

    fn try_start_footnote_def(&mut self, line: &'s [u8], cur: Cursor, idx: usize) -> bool {
        let remainder = &line[cur.pos..];
        let s = strip_up_to3_indent(remainder);
        let indent_bytes = remainder.len() - s.len();
        let Some(m) = try_footnote_def_marker(s) else { return false };

        self.maybe_close_top_list(idx, None);
        self.mark_lists_loose();

        let marker_col = cur.col + indent_bytes;
        let after_marker_col = marker_col + m.marker_len;
        let after = &s[m.marker_len..];
        let item_blank = is_blank_line(after);
        let content_col = if item_blank {
            after_marker_col + 1
        } else {
            let spaces = indent_cols(after, Cursor { pos: 0, col: after_marker_col, spent: 0 });
            if (1..=4).contains(&spaces) { after_marker_col + spaces } else { after_marker_col + 1 }
        };

        self.push_container(ContainerKind::FootnoteDef, idx);
        self.top().content_col = content_col.saturating_sub(cur.col + cur.spent);
        self.top().footnote_label = m.label;

        let after_marker_cursor = Cursor { pos: cur.pos + indent_bytes + m.marker_len, col: after_marker_col, spent: 0 };
        let content_cur = skip_ws_to_target(line, after_marker_cursor, content_col);
        let final_remainder = &line[content_cur.pos..];
        if !is_blank_line(final_remainder) {
            self.open_paragraph(final_remainder, idx);
        }
        true
    }

    fn finish_footnote_def(&mut self, c: &Container<'s>, line_idx: usize) {
        let label_owned = normalize_ref_label(c.footnote_label);
        let id = self.builder.add_container(Kind::Footnote { label: label_owned.clone() }, &c.children);
        let syntactic = self.syntactic_span(c, line_idx);
        let sp = container_span_extended(&self.builder, id, syntactic);
        self.builder.set_span(id, sp);
        set_content_span_from_children(&mut self.builder, id);
        self.footnotes.entry(label_owned).or_insert(id);
    }

    // ── link reference definitions ───────────────────────────────────────

    /// Strip as many consecutive link reference definitions as possible from
    /// the FRONT of `raw`, registering each. Returns what's left.
    fn strip_link_reference_definitions<'r>(&mut self, raw: &'r [u8], segs: &[Segment]) -> &'r [u8] {
        let mut text = raw;
        while let Some((consumed, id)) = self.try_parse_link_ref_def(text) {
            let start = offset_in(raw, text);
            if let Some(sp) = map_buf_range(segs, start, start + consumed) {
                self.builder.set_span(id, sp);
            }
            text = &text[consumed..];
            if !text.is_empty() && text[0] == b'\n' {
                text = &text[1..];
            }
        }
        text
    }

    fn try_parse_link_ref_def(&mut self, text: &[u8]) -> Option<(usize, NodeId)> {
        let mut i = 0;
        while i < text.len() && (text[i] == b' ' || text[i] == b'\t') {
            i += 1;
        }
        if i >= text.len() || text[i] != b'[' {
            return None;
        }
        i += 1;
        let label_start = i;
        let mut escaped = false;
        while i < text.len() {
            let c = text[i];
            if escaped {
                escaped = false;
                i += 1;
                continue;
            }
            if c == b'\\' {
                escaped = true;
                i += 1;
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
        let label = &text[label_start..i];
        if trim(label, b" \t\r\n").is_empty() {
            return None;
        }
        i += 1;
        if i >= text.len() || text[i] != b':' {
            return None;
        }
        i += 1;
        i = skip_lrd_ws(text, i);
        if i >= text.len() {
            return None;
        }

        let dest: &[u8];
        if text[i] == b'<' {
            let start = i + 1;
            let mut j = start;
            while j < text.len() && text[j] != b'>' && text[j] != b'\n' {
                if text[j] == b'\\' && j + 1 < text.len() {
                    j += 1;
                }
                j += 1;
            }
            if j >= text.len() || text[j] != b'>' {
                return None;
            }
            dest = &text[start..j];
            i = j + 1;
        } else {
            let start = i;
            let mut depth = 0usize;
            let mut j = i;
            while j < text.len() {
                let c = text[j];
                if c == b'\\' && j + 1 < text.len() {
                    j += 2;
                    continue;
                }
                if c == b' ' || c == b'\t' || c == b'\n' {
                    break;
                }
                if c == b'(' {
                    depth += 1;
                }
                if c == b')' {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                }
                j += 1;
            }
            if j == start {
                return None;
            }
            dest = &text[start..j];
            i = j;
        }

        let label_owned = normalize_ref_label(label);
        let dest_decoded = inline_mod::decode_text(dest);

        let after_dest = i;
        let dest_line_end = index_of_scalar(text, after_dest, b'\n').unwrap_or(text.len());
        let ws_end = skip_lrd_ws(text, after_dest);
        let title_on_new_line = index_of_scalar(text, after_dest, b'\n').is_some() && dest_line_end < ws_end;
        let dest_line_blank = is_blank_line(&text[after_dest..dest_line_end]);
        let mut title: Option<&[u8]> = None;
        let end;
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
            let mut tentative_end = after_dest;
            let malformed = if j >= text.len() {
                true
            } else {
                let rest_start = j + 1;
                let line_end = index_of_scalar(text, rest_start, b'\n').unwrap_or(text.len());
                if !is_blank_line(&text[rest_start..line_end]) {
                    true
                } else {
                    title = Some(&text[ws_end + 1..j]);
                    tentative_end = line_end;
                    false
                }
            };
            if malformed {
                if title_on_new_line && dest_line_blank {
                    end = dest_line_end;
                } else {
                    return None;
                }
            } else {
                end = tentative_end;
            }
        } else {
            if !dest_line_blank {
                return None;
            }
            end = dest_line_end;
        }

        let ref_id = self.builder.add_leaf(Kind::Reference { label: label_owned.clone(), destination: dest_decoded });
        if let Some(t) = title {
            let title_decoded = inline_mod::decode_text(t);
            self.builder.set_attrs(ref_id, Attrs { entries: vec![KeyVal::new(b"title", Some(&title_decoded))] });
        }
        self.link_references.entry(label_owned).or_insert(ref_id);
        Some((end, ref_id))
    }
}

fn append_cell_run(cell: &[u8], from: usize, to: usize, src_base: usize, out: &mut Vec<u8>, segs: &mut Vec<Segment>) {
    if to == from {
        return;
    }
    segs.push(Segment { buf_offset: out.len(), src_offset: src_base + from, len: to - from });
    out.extend_from_slice(&cell[from..to]);
}

fn bullet_style(c: u8) -> Bullet {
    match c {
        b'+' => Bullet::Plus,
        b'*' => Bullet::Star,
        _ => Bullet::Dash,
    }
}

fn list_compatible(c: &Container<'_>, mk: &ListMarker) -> bool {
    if c.kind != ContainerKind::List {
        return false;
    }
    if c.ordered != mk.ordered {
        return false;
    }
    if mk.ordered {
        return c.delim == mk.delim;
    }
    c.bullet_char == mk.bullet_char
}

fn count_colons(s: &[u8]) -> usize {
    s.iter().take_while(|&&c| c == b':').count()
}

fn match_block_quote(line: &[u8], cur: Cursor) -> Option<Cursor> {
    let after_indent = skip_ws_up_to_cols(line, cur, 3);
    if after_indent.pos >= line.len() || line[after_indent.pos] != b'>' {
        return None;
    }
    let mut c2 = Cursor { pos: after_indent.pos + 1, col: after_indent.col + 1, spent: 0 };
    if c2.pos < line.len() {
        if line[c2.pos] == b' ' {
            c2 = Cursor { pos: c2.pos + 1, col: c2.col + 1, spent: 0 };
        } else if line[c2.pos] == b'\t' {
            if 4 - (c2.col % 4) == 1 {
                c2 = Cursor { pos: c2.pos + 1, col: c2.col + 1, spent: 0 };
            } else {
                c2 = Cursor { pos: c2.pos, col: c2.col, spent: 1 };
            }
        }
    }
    Some(c2)
}

fn match_list_item(line: &[u8], cur: Cursor, content_col: usize) -> Option<Cursor> {
    if is_blank_line(&line[cur.pos..]) {
        return Some(cur);
    }
    let target = cur.col + cur.spent + content_col;
    let t = skip_ws_to_target(line, cur, target);
    if t.col + t.spent < target {
        return None;
    }
    Some(t)
}

struct FootnoteDefMarker<'t> {
    marker_len: usize,
    label: &'t [u8],
}

/// `\[\^([^\]\r\n]*)\]:([ \t]|$)`.
fn try_footnote_def_marker(s: &[u8]) -> Option<FootnoteDefMarker<'_>> {
    if s.len() < 2 || s[0] != b'[' || s[1] != b'^' {
        return None;
    }
    let mut i = 2;
    let label_start = i;
    while i < s.len() && s[i] != b']' && s[i] != b'\r' && s[i] != b'\n' {
        i += 1;
    }
    let label_end = i;
    if i >= s.len() || s[i] != b']' {
        return None;
    }
    i += 1;
    if i >= s.len() || s[i] != b':' {
        return None;
    }
    i += 1;
    if i < s.len() && s[i] != b' ' && s[i] != b'\t' {
        return None;
    }
    let label = &s[label_start..label_end];
    if trim(label, b" \t\r\n").is_empty() {
        return None;
    }
    Some(FootnoteDefMarker { marker_len: i, label })
}

fn skip_lrd_ws(text: &[u8], start: usize) -> usize {
    let mut i = start;
    let mut seen_nl = false;
    while i < text.len() {
        let c = text[i];
        if c == b' ' || c == b'\t' {
            i += 1;
            continue;
        }
        if c == b'\n' && !seen_nl {
            seen_nl = true;
            i += 1;
            continue;
        }
        break;
    }
    i
}

/// Re-express `segs` (relative to `orig`) relative to `sub`, a sub-slice.
fn rebase_segments(segs: &[Segment], orig: &[u8], sub: &[u8]) -> Vec<Segment> {
    let k = offset_in(orig, sub);
    let mut out = Vec::new();
    for seg in segs {
        let seg_end = seg.buf_offset + seg.len;
        let lo = seg.buf_offset.max(k);
        let hi = seg_end.min(k + sub.len());
        if lo >= hi {
            continue;
        }
        let front_trim = lo - seg.buf_offset;
        out.push(Segment { buf_offset: lo - k, src_offset: seg.src_offset + front_trim, len: hi - lo });
    }
    out
}

fn set_content_span_from_children(b: &mut Builder, id: NodeId) {
    let Some(first) = b.nodes[id as usize].first_child else { return };
    let mut last = first;
    while let Some(next) = b.nodes[last as usize].next_sibling {
        last = next;
    }
    if is_unset_span(b.spans[first as usize]) || is_unset_span(b.spans[last as usize]) {
        return;
    }
    let sp = Span::new(b.spans[first as usize].start, b.spans[last as usize].end);
    b.set_content_span(id, sp);
}

fn container_span_extended(b: &Builder, id: NodeId, syntactic: Span) -> Span {
    let Some(first) = b.nodes[id as usize].first_child else { return syntactic };
    let mut last = first;
    while let Some(next) = b.nodes[last as usize].next_sibling {
        last = next;
    }
    if is_unset_span(b.spans[last as usize]) {
        return syntactic;
    }
    Span::new(syntactic.start, syntactic.end.max(b.spans[last as usize].end))
}

fn map_buf_range(segs: &[Segment], start: usize, end: usize) -> Option<Span> {
    let src_start = map_buf_point(segs, start, false)?;
    let src_end = map_buf_point(segs, end, true)?;
    if src_end < src_start {
        return None;
    }
    Some(Span::new(src_start, src_end))
}

fn map_buf_point(segs: &[Segment], local: usize, is_end: bool) -> Option<usize> {
    for seg in segs {
        let lo = seg.buf_offset;
        let hi = seg.buf_offset + seg.len;
        let hit = if is_end { local > lo && local <= hi } else { local >= lo && local < hi };
        if hit {
            return Some(seg.src_offset + (local - lo));
        }
    }
    for seg in segs {
        if local >= seg.buf_offset && local <= seg.buf_offset + seg.len {
            return Some(seg.src_offset + (local - seg.buf_offset));
        }
    }
    None
}

/// Parse `source` into a `Document`.
pub fn parse(source: &[u8], options: ParseOptions) -> Document {
    Parser::new(source, options).parse()
}
