//! AsciiDoc — the parser. Port of `src/languages/asciidoc/parser.zig`.
//!
//! Source bytes to twig's shared `Ast`, judged by `conformance.rs`'s corpus
//! comparison (`asg::encode(parse(source)) == case.asg`, structurally)
//! against the vendored TCK corpus and twig's own authored one.
//!
//! Blocks: the document header (title, the author and revision lines, the
//! attribute entries below them), front matter, paragraphs in every style the
//! `[style]` line can give them, `NOTE: ` admonition paragraphs, indented
//! literal paragraphs, sections by `=` count, `[discrete]` headings, every
//! delimited block (plus Markdown-style backtick fences and `> ` quotes),
//! tables (`|===`), unordered, ordered, callout and description lists with
//! marker-driven nesting, list continuation (`+`), block metadata in all its
//! spellings, the four block macros, body attribute entries, line comments,
//! thematic and page breaks.
//!
//! Inlines: the four spans in both forms, superscript and subscript, curved
//! quotes, `[.role]`-prefixed spans, links in every spelling, cross
//! references, inline images, footnotes, inline anchors, attribute
//! references, character references, passthroughs, math macros,
//! `kbd:[]`/`btn:[]`, hard line breaks, `%hardbreaks`, the text replacements
//! and backslash escapes. What is not recognized degrades to LITERAL SOURCE
//! TEXT.
//!
//! ── Where the AsciiDoc-only facts go ────────────────────────────────────────
//! Block metadata lands in `attrs` as the document's REAL attributes (`id`,
//! `class` for roles and unrecognized styles, `title`, `options`, every named
//! entry). The ASG's own bookkeeping (`form`, `delimiter`, a block's
//! `metadata` object) is DERIVED from the node's own source by `asg.rs` on
//! the way out, which is why `match_meta_line`, `AttrIter` and the
//! author-line scanner are `pub`.
//!
//! ── Position matters ────────────────────────────────────────────────────────
//! A block's span starts at its FIRST METADATA LINE (`.Title`, `[attrs]`,
//! `[[id]]`) and runs to its last content line; that is what lets the codec
//! find the metadata again.
//!
//! ── Why this shape ─────────────────────────────────────────────────────────
//! Bottom-up onto `Builder`. Section nesting is spelled directly by the
//! marker's `=` count. List nesting is Asciidoctor's own rule — an item whose
//! marker differs from every list on the stack opens a nested list, one whose
//! marker matches an ancestor closes back to it — carried on `list_stack`
//! rather than on indentation, which AsciiDoc ignores.

use crate::ast::{
    compact, Alignment, Attrs, Builder, Cell, Container, Form, InlineMark, KeyVal, Kind, Link, ListNumbering,
    NodeId, SmartPunctuationKind, TextLeafKind,
};
use crate::document::{Bullet, ContainerOrigin, Document, OrderedDelim, Spelling};
use twig_kit::entities;
use crate::span::Span;

// ── byte-slice helpers (Zig's `std.mem` vocabulary) ─────────────────────────

pub(crate) fn trim<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    trim_start(trim_end(s, set), set)
}

pub(crate) fn trim_end<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    let mut e = s.len();
    while e > 0 && set.contains(&s[e - 1]) {
        e -= 1;
    }
    &s[..e]
}

pub(crate) fn trim_start<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    let mut b = 0;
    while b < s.len() && set.contains(&s[b]) {
        b += 1;
    }
    &s[b..]
}

pub(crate) fn index_of_scalar(s: &[u8], c: u8) -> Option<usize> {
    s.iter().position(|&x| x == c)
}

pub(crate) fn index_of_scalar_pos(s: &[u8], pos: usize, c: u8) -> Option<usize> {
    if pos >= s.len() {
        return None;
    }
    s[pos..].iter().position(|&x| x == c).map(|p| p + pos)
}

pub(crate) fn last_index_of_scalar(s: &[u8], c: u8) -> Option<usize> {
    s.iter().rposition(|&x| x == c)
}

pub(crate) fn index_of_any(s: &[u8], set: &[u8]) -> Option<usize> {
    s.iter().position(|x| set.contains(x))
}

pub(crate) fn index_of_none(s: &[u8], set: &[u8]) -> Option<usize> {
    s.iter().position(|x| !set.contains(x))
}

/// `std.mem.indexOf`: an empty needle matches at 0.
pub(crate) fn index_of(hay: &[u8], needle: &[u8]) -> Option<usize> {
    index_of_pos(hay, 0, needle)
}

pub(crate) fn index_of_pos(hay: &[u8], pos: usize, needle: &[u8]) -> Option<usize> {
    if pos > hay.len() {
        return None;
    }
    if needle.is_empty() {
        return Some(pos);
    }
    if needle.len() > hay.len() {
        return None;
    }
    (pos..=hay.len() - needle.len()).find(|&i| &hay[i..i + needle.len()] == needle)
}

pub(crate) fn last_index_of(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > hay.len() {
        return None;
    }
    (0..=hay.len() - needle.len()).rev().find(|&i| &hay[i..i + needle.len()] == needle)
}

/// `std.mem.tokenizeAny`: the non-empty pieces between any of `delims`.
pub(crate) fn tokenize<'a>(s: &'a [u8], delims: &'a [u8]) -> impl Iterator<Item = &'a [u8]> + 'a {
    s.split(move |c| delims.contains(c)).filter(|p| !p.is_empty())
}

/// Zig's `std.fmt.parseInt` for an unsigned type whose maximum is `max`:
/// a leading `+`/`-`, `_` digit separators (not at either end), and a
/// negative number only when it is zero.
pub(crate) fn zig_parse_uint(buf: &[u8], base: u32, max: u64) -> Option<u64> {
    if buf.is_empty() {
        return None;
    }
    let (neg, body) = match buf[0] {
        b'+' => (false, &buf[1..]),
        b'-' => (true, &buf[1..]),
        _ => (false, buf),
    };
    if body.is_empty() {
        return None;
    }
    if body[0] == b'_' || body[body.len() - 1] == b'_' {
        return None;
    }
    let mut acc: u64 = 0;
    for &c in body {
        if c == b'_' {
            continue;
        }
        let digit = match c {
            b'0'..=b'9' => (c - b'0') as u32,
            b'A'..=b'Z' => (c - b'A') as u32 + 10,
            b'a'..=b'z' => (c - b'a') as u32 + 10,
            _ => return None,
        };
        if digit >= base {
            return None;
        }
        if acc != 0 {
            acc = acc.checked_mul(base as u64)?;
            if acc > max {
                return None;
            }
        } else if neg {
            if digit != 0 {
                return None;
            }
            continue;
        }
        acc = acc.checked_add(digit as u64)?;
        if acc > max {
            return None;
        }
    }
    Some(acc)
}

fn parse_u32(s: &[u8]) -> Option<u32> {
    zig_parse_uint(s, 10, u32::MAX as u64).map(|v| v as u32)
}

fn parse_usize(s: &[u8]) -> Option<usize> {
    zig_parse_uint(s, 10, u64::MAX).map(|v| v as usize)
}

fn kv(key: &[u8], value: &[u8]) -> KeyVal {
    KeyVal::new(key, Some(value))
}

// ── entry points ────────────────────────────────────────────────────────────

pub fn parse(source: &[u8]) -> Document {
    let mut p = Parser::new(source);
    let root = p.parse_document();
    finish(p.b, source, root)
}

/// Freeze the build into a `Document` the way every parse ends: the detached
/// footnote definitions indexed by label (first definition wins), then the
/// arena compacted — without the label entry compaction would sweep a
/// definition, which is attached to nothing.
fn finish(b: Builder, source: &[u8], root: NodeId) -> Document {
    let mut doc = b.finish_document(source, root);
    for n in &doc.ast.nodes {
        if let Kind::Footnote { label } = &n.kind {
            doc.labels.footnotes.entry(label.clone()).or_insert(n.id);
        }
    }
    compact::run(doc)
}

/// The TCK's `inline`-level entry point: `source` (a single line, e.g.
/// `"*s*\n"`) is scanned for inline markup directly, with no block structure
/// at all, and the resulting nodes are wrapped in a synthetic `doc` root —
/// mirroring `asg::decode`'s own `inlines` case.
pub fn parse_inline_list(source: &[u8]) -> Document {
    let mut b = Builder::new();
    let mut footnotes: u32 = 0;
    let text = trim_end(source, b"\n");
    let ids = parse_inlines(&mut InlineCtx { b: &mut b, footnotes: &mut footnotes, hardbreaks: false }, text, 0);
    let root = b.add_container(Kind::Doc, &ids);
    finish(b, source, root)
}

// ── shared source scanners (used by asg.rs too) ─────────────────────────────

/// One classified block-metadata line. See [`match_meta_line`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MetaLine<'a> {
    /// `[…]` — the interior, brackets excluded.
    Attrs(&'a [u8]),
    /// `[[id]]` / `[[id,reftext]]`.
    Anchor { id: &'a [u8], reftext: Option<&'a [u8]> },
    /// `.Title` — the text after the dot.
    Title(&'a [u8]),
}

/// Classify `line` (one source line, newline excluded) as block metadata, or
/// `None`. Asciidoctor's own three rules: a block attribute line is `[…]`
/// whose interior is empty or starts with a name/shorthand byte; a block
/// anchor is `[[…]]`; a block title is a `.` followed by anything but
/// whitespace or a second dot. All three must sit at column 0.
pub fn match_meta_line(line: &[u8]) -> Option<MetaLine<'_>> {
    let t = trim_end(line, b" \t");
    if t.len() < 2 {
        return None;
    }
    if t[0] == b'[' {
        if t[t.len() - 1] != b']' {
            return None;
        }
        if t.len() >= 4 && t[1] == b'[' && t[t.len() - 2] == b']' {
            let inner = &t[2..t.len() - 2];
            if inner.is_empty() || index_of_any(inner, b"[]").is_some() {
                return None;
            }
            let comma = index_of_scalar(inner, b',');
            let id = match comma {
                Some(c) => &inner[..c],
                None => inner,
            };
            if id.is_empty() || index_of_any(id, b" \t").is_some() {
                return None;
            }
            return Some(MetaLine::Anchor { id, reftext: comma.map(|c| trim(&inner[c + 1..], b" \t")) });
        }
        let inner = &t[1..t.len() - 1];
        if inner.is_empty() {
            return Some(MetaLine::Attrs(inner));
        }
        let first = inner[0];
        let ok = first.is_ascii_alphanumeric() || b"_.#%{,\"'".contains(&first);
        if !ok {
            return None;
        }
        return Some(MetaLine::Attrs(inner));
    }
    if t[0] == b'.' && t[1] != b' ' && t[1] != b'\t' && t[1] != b'.' {
        return Some(MetaLine::Title(&t[1..]));
    }
    None
}

/// One entry of a `[…]` attribute list — positional (`key == None`, `index`
/// 1-based) or named. `value` has its quotes removed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AttrEntry<'a> {
    pub key: Option<&'a [u8]>,
    pub value: &'a [u8],
    pub index: usize,
}

/// Walks an attribute list's interior entry by entry: comma-separated, each
/// `key=value` or positional, values optionally `"`- or `'`-quoted (a comma
/// inside quotes does not split).
#[derive(Clone, Debug)]
pub struct AttrIter<'a> {
    rest: &'a [u8],
    index: usize,
    done: bool,
}

impl<'a> AttrIter<'a> {
    pub fn new(interior: &'a [u8]) -> AttrIter<'a> {
        AttrIter { rest: interior, index: 0, done: false }
    }
}

impl<'a> Iterator for AttrIter<'a> {
    type Item = AttrEntry<'a>;
    fn next(&mut self) -> Option<AttrEntry<'a>> {
        if self.done {
            return None;
        }
        // Find the entry's end: the first comma outside quotes.
        let rest = self.rest;
        let mut i = 0;
        let mut quote: u8 = 0;
        while i < rest.len() {
            let c = rest[i];
            if quote != 0 {
                if c == b'\\' && i + 1 < rest.len() {
                    i += 1;
                } else if c == quote {
                    quote = 0;
                }
                i += 1;
                continue;
            }
            if c == b'"' || c == b'\'' {
                // Only a quote that starts a value (after `=` or at entry start) quotes.
                let before = trim(&rest[..i], b" \t");
                if before.is_empty() || before[before.len() - 1] == b'=' {
                    quote = c;
                }
                i += 1;
                continue;
            }
            if c == b',' {
                break;
            }
            i += 1;
        }
        let raw = &rest[..i];
        if i < rest.len() {
            self.rest = &rest[i + 1..];
        } else {
            self.rest = b"";
            self.done = true;
        }
        self.index += 1;
        let entry = trim(raw, b" \t");
        if let Some(e) = index_of_scalar(entry, b'=') {
            let key = trim(&entry[..e], b" \t");
            if !key.is_empty() && is_attr_name(key) {
                return Some(AttrEntry {
                    key: Some(key),
                    value: unquote(trim(&entry[e + 1..], b" \t")),
                    index: self.index,
                });
            }
        }
        Some(AttrEntry { key: None, value: unquote(entry), index: self.index })
    }
}

fn is_attr_name(s: &[u8]) -> bool {
    s.iter().all(|&c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-' || c == b'.')
}

fn unquote(v: &[u8]) -> &[u8] {
    if v.len() >= 2 && (v[0] == b'"' || v[0] == b'\'') && v[v.len() - 1] == v[0] {
        return &v[1..v.len() - 1];
    }
    v
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShorthandKind {
    Style,
    Id,
    Role,
    Option,
}

/// One piece of the first positional attribute's shorthand: `style#id.role%option`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShorthandPiece<'a> {
    pub kind: ShorthandKind,
    pub text: &'a [u8],
}

/// Splits the block-style shorthand (`quote#id.role1.role2%opt`). The style is
/// whatever precedes the first sigil; an empty style piece is not reported.
#[derive(Clone, Debug)]
pub struct ShorthandIter<'a> {
    rest: &'a [u8],
    first: bool,
}

impl<'a> ShorthandIter<'a> {
    pub fn new(s: &'a [u8]) -> ShorthandIter<'a> {
        ShorthandIter { rest: s, first: true }
    }
}

impl<'a> Iterator for ShorthandIter<'a> {
    type Item = ShorthandPiece<'a>;
    fn next(&mut self) -> Option<ShorthandPiece<'a>> {
        loop {
            if self.rest.is_empty() {
                return None;
            }
            let mut kind = ShorthandKind::Style;
            let mut start = 0;
            if !self.first || b"#.%".contains(&self.rest[0]) {
                kind = match self.rest[0] {
                    b'#' => ShorthandKind::Id,
                    b'.' => ShorthandKind::Role,
                    b'%' => ShorthandKind::Option,
                    _ => ShorthandKind::Style,
                };
                if kind != ShorthandKind::Style {
                    start = 1;
                }
            }
            self.first = false;
            let mut end = start;
            while end < self.rest.len() && !b"#.%".contains(&self.rest[end]) {
                end += 1;
            }
            let text = &self.rest[start..end];
            self.rest = &self.rest[end..];
            if text.is_empty() {
                continue;
            }
            return Some(ShorthandPiece { kind, text });
        }
    }
}

/// One author from the header's author line. Names are as written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Author<'a> {
    pub fullname: &'a [u8],
    pub firstname: &'a [u8],
    pub middlename: Option<&'a [u8]>,
    pub lastname: Option<&'a [u8]>,
    pub email: Option<&'a [u8]>,
}

impl Author<'_> {
    pub fn initials(&self) -> Vec<u8> {
        let mut out = vec![self.firstname[0]];
        if let Some(m) = self.middlename {
            out.push(m[0]);
        }
        if let Some(l) = self.lastname {
            out.push(l[0]);
        }
        out
    }
}

/// Walks the `;`-separated authors of a header author line. Each author is up
/// to three space-separated names and an optional `<address>`; a line that
/// does not fit (four or more names) yields one author whose full name is the
/// whole text and whose first/last names are its first and last words.
#[derive(Clone, Debug)]
pub struct AuthorIter<'a> {
    rest: &'a [u8],
    done: bool,
}

impl<'a> AuthorIter<'a> {
    pub fn new(line: &'a [u8]) -> AuthorIter<'a> {
        AuthorIter { rest: line, done: false }
    }
}

impl<'a> Iterator for AuthorIter<'a> {
    type Item = Author<'a>;
    fn next(&mut self) -> Option<Author<'a>> {
        while !self.done {
            let mut piece;
            if let Some(semi) = index_of_scalar(self.rest, b';') {
                piece = &self.rest[..semi];
                self.rest = &self.rest[semi + 1..];
            } else {
                piece = self.rest;
                self.done = true;
            }
            piece = trim(piece, b" \t");
            if piece.is_empty() {
                continue;
            }
            let mut email = None;
            let mut names = piece;
            if let Some(lt) = index_of_scalar(piece, b'<') {
                if let Some(gt) = index_of_scalar_pos(piece, lt, b'>') {
                    email = Some(trim(&piece[lt + 1..gt], b" \t"));
                    names = trim(&piece[..lt], b" \t");
                }
            }
            if names.is_empty() {
                continue;
            }
            let words: Vec<&[u8]> = tokenize(names, b" \t").collect();
            let n = words.len();
            if n == 0 {
                continue;
            }
            if n > 3 {
                return Some(Author {
                    fullname: names,
                    firstname: words[0],
                    middlename: None,
                    lastname: Some(words[n - 1]),
                    email,
                });
            }
            return Some(Author {
                fullname: names,
                firstname: words[0],
                middlename: if n == 3 { Some(words[1]) } else { None },
                lastname: if n >= 2 { Some(words[n - 1]) } else { None },
                email,
            });
        }
        None
    }
}

/// `true` for a line of the header (after the title) that Asciidoctor reads
/// as the author line: non-blank, not an attribute entry, not a comment.
pub fn is_author_line(line: &[u8]) -> bool {
    let t = trim(line, b" \t");
    if t.is_empty() {
        return false;
    }
    if t[0] == b':' {
        return false;
    }
    if t.starts_with(b"//") {
        return false;
    }
    true
}

/// One `:name: value` attribute entry, borrowed from the line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AttrEntryLine<'a> {
    pub key: &'a [u8],
    /// `None` for the two negated spellings (`:!name:`, `:name!:`).
    pub value: Option<&'a [u8]>,
}

/// One `:name: value` attribute entry. `value` is trimmed of surrounding
/// whitespace but not internally; a bare `:name:` yields an empty but
/// NON-null value, while the two negated spellings yield `None`.
pub fn match_attr_entry(line: &[u8]) -> Option<AttrEntryLine<'_>> {
    let t = line;
    if t.len() < 2 || t[0] != b':' {
        return None;
    }
    let mut j = 1;
    while j < t.len() && t[j] != b':' {
        j += 1;
    }
    if j >= t.len() || j == 1 {
        return None;
    }
    let mut key = &t[1..j];
    let mut unset = false;
    if key[0] == b'!' {
        key = &key[1..];
        unset = true;
    } else if key[key.len() - 1] == b'!' {
        key = &key[..key.len() - 1];
        unset = true;
    }
    if key.is_empty() {
        return None;
    }
    if !key.iter().all(|&c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-') {
        return None;
    }
    // `::` right after the name (`term:: desc`) is a description list, not an entry.
    if j + 1 < t.len() && t[j + 1] == b':' {
        return None;
    }
    if j + 1 < t.len() && t[j + 1] != b' ' && t[j + 1] != b'\t' {
        return None;
    }
    Some(AttrEntryLine { key, value: if unset { None } else { Some(trim(&t[j + 1..], b" \t")) } })
}

/// The five admonition labels, as `NOTE: text` spells them.
pub const ADMONITIONS: [&[u8]; 5] = [b"NOTE", b"TIP", b"IMPORTANT", b"WARNING", b"CAUTION"];
const ADMONITION_NAMES: [&[u8]; 5] = [b"note", b"tip", b"important", b"warning", b"caution"];

/// The lowercase container name an admonition label or style becomes.
pub fn admonition_name(label: &[u8]) -> Option<&'static [u8]> {
    ADMONITIONS.iter().position(|&l| l == label).map(|i| ADMONITION_NAMES[i])
}

/// `note` -> `NOTE`; anything else unchanged.
pub(crate) fn upper_label(name: &[u8]) -> &[u8] {
    match ADMONITION_NAMES.iter().position(|&l| l == name) {
        Some(i) => ADMONITIONS[i],
        None => name,
    }
}

/// The block styles that name a LEAF block in the ASG.
pub fn is_leaf_style(style: &[u8]) -> bool {
    [&b"listing"[..], b"source", b"literal", b"pass", b"stem", b"latexmath", b"asciimath", b"verse"].contains(&style)
}

/// The ASG leaf-block name a style spells — `source`, `latexmath` and
/// `asciimath` are aliases the ASG does not distinguish.
pub fn leaf_name_for_style(style: &[u8]) -> &[u8] {
    if style == b"source" {
        return b"listing";
    }
    if style == b"latexmath" || style == b"asciimath" {
        return b"stem";
    }
    style
}

/// Block styles that turn a paragraph or an open block into a PARENT block.
pub fn is_parent_style(style: &[u8]) -> bool {
    if [&b"quote"[..], b"sidebar", b"example", b"abstract", b"partintro", b"open"].contains(&style) {
        return true;
    }
    admonition_name(style).is_some()
}

/// A `|===` table delimiter: the bar and three or more `=`.
pub fn is_table_delimiter_line(t: &[u8]) -> bool {
    if t.len() < 4 || t[0] != b'|' {
        return false;
    }
    t[1..].iter().all(|&c| c == b'=')
}

/// A Markdown-style fence line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FenceLine<'a> {
    pub fence: &'a [u8],
    pub info: &'a [u8],
}

/// A Markdown-style fence line: three or more backticks, then an optional
/// info string.
pub fn match_fence_line(t: &[u8]) -> Option<FenceLine<'_>> {
    if t.len() < 3 || t[0] != b'`' {
        return None;
    }
    let mut n = 0;
    while n < t.len() && t[n] == b'`' {
        n += 1;
    }
    if n < 3 {
        return None;
    }
    let info = trim(&t[n..], b" \t");
    if index_of_scalar(info, b'`').is_some() {
        return None;
    }
    Some(FenceLine { fence: &t[..n], info })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListMarkerKind {
    Unordered,
    Ordered,
    Callout,
    Description,
}

/// The marker of a list item line, classified, on a line whose leading
/// whitespace is already stripped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ListMarker<'a> {
    pub kind: ListMarkerKind,
    /// The marker's bytes as written (`**`, `1.`, `<1>`, `::`).
    pub text: &'a [u8],
    /// Where the principal text begins, relative to the line's start.
    pub text_at: usize,
    pub numbering: ListNumbering,
    pub start: Option<u32>,
    pub delim: OrderedDelim,
    /// Description lists only: the term and where it starts on the line.
    pub term: &'a [u8],
    pub term_at: usize,
}

impl<'a> ListMarker<'a> {
    fn new(kind: ListMarkerKind, text: &'a [u8], text_at: usize) -> ListMarker<'a> {
        ListMarker {
            kind,
            text,
            text_at,
            numbering: ListNumbering::Decimal,
            start: None,
            delim: OrderedDelim::Period,
            term: b"",
            term_at: 0,
        }
    }

    /// The identity two markers are compared by when deciding whether a line
    /// continues, nests under, or closes a list: the marker text itself,
    /// except that every explicit ordinal of one family is the same list.
    pub fn key(&self) -> &'a [u8] {
        match self.kind {
            ListMarkerKind::Unordered | ListMarkerKind::Description => self.text,
            ListMarkerKind::Callout => b"<1>",
            ListMarkerKind::Ordered => {
                if self.text[0] == b'.' {
                    self.text
                } else {
                    match self.numbering {
                        ListNumbering::Decimal => b"1.",
                        ListNumbering::LowerAlpha => b"a.",
                        ListNumbering::UpperAlpha => b"A.",
                        ListNumbering::LowerRoman => b"i)",
                        ListNumbering::UpperRoman => b"I)",
                    }
                }
            }
        }
    }
}

fn marker_text_end(t: &[u8], marker_end: usize) -> Option<usize> {
    // At least one space, then something that is not whitespace.
    if marker_end >= t.len() || t[marker_end] != b' ' {
        return None;
    }
    let mut j = marker_end;
    while j < t.len() && t[j] == b' ' {
        j += 1;
    }
    if j >= t.len() {
        return None;
    }
    Some(j)
}

fn roman_value(s: &[u8]) -> Option<u32> {
    let mut total: u32 = 0;
    let mut prev: u32 = 0;
    let mut i = s.len();
    while i > 0 {
        i -= 1;
        let v: u32 = match s[i].to_ascii_lowercase() {
            b'i' => 1,
            b'v' => 5,
            b'x' => 10,
            _ => return None,
        };
        if v < prev {
            total = total.wrapping_sub(v);
        } else {
            total = total.wrapping_add(v);
        }
        prev = v;
    }
    Some(total)
}

/// Classify a bare marker as written (`.`, `3.`, `b.`, `iv)`, `<1>`, `*`,
/// `::`) — `match_list_marker_text` on the marker followed by one word. Only
/// the classification (kind, numbering, start, delimiter) is meaningful on
/// the result; its `term` is not kept.
pub fn classify_marker(marker: &[u8]) -> Option<ListMarker<'_>> {
    if marker.len() + 2 > 40 {
        return None;
    }
    let mut buf = marker.to_vec();
    buf.extend_from_slice(b" x");
    let m = match_list_marker_text(&buf)?;
    Some(ListMarker {
        kind: m.kind,
        text: marker,
        text_at: m.text_at,
        numbering: m.numbering,
        start: m.start,
        delim: m.delim,
        term: b"",
        term_at: m.term_at,
    })
}

/// Match a list marker at the start of `t` (leading whitespace already
/// stripped): `*`{1,5} or `-`, `.`{1,5} / `N.` / `a.` / `i)`, `<N>` / `<.>`,
/// or a description term followed by `::`…`::::` / `;;`.
pub fn match_list_marker_text(t: &[u8]) -> Option<ListMarker<'_>> {
    if t.is_empty() {
        return None;
    }
    // Unordered.
    if t[0] == b'*' {
        let mut n = 0;
        while n < t.len() && t[n] == b'*' {
            n += 1;
        }
        if n <= 5 {
            if let Some(at) = marker_text_end(t, n) {
                return Some(ListMarker::new(ListMarkerKind::Unordered, &t[..n], at));
            }
        }
    } else if t[0] == b'-' {
        if let Some(at) = marker_text_end(t, 1) {
            return Some(ListMarker::new(ListMarkerKind::Unordered, &t[..1], at));
        }
    } else if t[0] == b'.' {
        let mut n = 0;
        while n < t.len() && t[n] == b'.' {
            n += 1;
        }
        if n <= 5 {
            if let Some(at) = marker_text_end(t, n) {
                return Some(ListMarker::new(ListMarkerKind::Ordered, &t[..n], at));
            }
        }
    } else if t[0] == b'<' {
        let mut j = 1;
        if j < t.len() && t[j] == b'.' {
            j += 1;
        } else {
            while j < t.len() && t[j].is_ascii_digit() {
                j += 1;
            }
            if j == 1 {
                return None;
            }
        }
        if j < t.len() && t[j] == b'>' {
            if let Some(at) = marker_text_end(t, j + 1) {
                return Some(ListMarker::new(ListMarkerKind::Callout, &t[..j + 1], at));
            }
        }
    }
    // Explicit ordinals: digits+`.`, letter+`.`, roman+`)`.
    if t[0].is_ascii_digit() {
        let mut j = 0;
        while j < t.len() && t[j].is_ascii_digit() {
            j += 1;
        }
        if j < t.len() && t[j] == b'.' && j <= 9 {
            if let Some(at) = marker_text_end(t, j + 1) {
                let n = parse_u32(&t[..j]).unwrap_or(1);
                let mut m = ListMarker::new(ListMarkerKind::Ordered, &t[..j + 1], at);
                m.start = Some(n);
                return Some(m);
            }
        }
    } else if t[0].is_ascii_alphabetic() && t.len() >= 2 {
        if t[1] == b'.' {
            if let Some(at) = marker_text_end(t, 2) {
                let lower = t[0].is_ascii_lowercase();
                let mut m = ListMarker::new(ListMarkerKind::Ordered, &t[..2], at);
                m.numbering = if lower { ListNumbering::LowerAlpha } else { ListNumbering::UpperAlpha };
                m.start = Some((t[0].to_ascii_lowercase() - b'a' + 1) as u32);
                return Some(m);
            }
        }
        let mut j = 0;
        while j < t.len() && b"ivxIVX".contains(&t[j]) {
            j += 1;
        }
        if j > 0 && j < t.len() && t[j] == b')' {
            if let Some(at) = marker_text_end(t, j + 1) {
                if let Some(v) = roman_value(&t[..j]) {
                    let mut m = ListMarker::new(ListMarkerKind::Ordered, &t[..j + 1], at);
                    m.numbering =
                        if t[0].is_ascii_lowercase() { ListNumbering::LowerRoman } else { ListNumbering::UpperRoman };
                    m.start = Some(v);
                    m.delim = OrderedDelim::ParenAfter;
                    return Some(m);
                }
            }
        }
    }
    match_description_term(t)
}

fn match_description_term(t: &[u8]) -> Option<ListMarker<'_>> {
    if t.len() < 3 || t.starts_with(b"//") {
        return None;
    }
    if t[0] == b':' && match_attr_entry(t).is_some() {
        return None;
    }
    let mut i = 0;
    while i < t.len() {
        let c = t[i];
        if c != b':' && c != b';' {
            i += 1;
            continue;
        }
        let mut n = i;
        while n < t.len() && t[n] == c {
            n += 1;
        }
        let run = n - i;
        let is_marker = (c == b':' && (2..=4).contains(&run)) || (c == b';' && run == 2);
        if !is_marker {
            i = n;
            continue;
        }
        if n < t.len() && t[n] != b' ' && t[n] != b'\t' {
            i = n;
            continue;
        }
        let term = trim(&t[..i], b" \t");
        if term.is_empty() {
            return None;
        }
        let mut text_at = n;
        while text_at < t.len() && (t[text_at] == b' ' || t[text_at] == b'\t') {
            text_at += 1;
        }
        let mut term_at = 0;
        while term_at < i && (t[term_at] == b' ' || t[term_at] == b'\t') {
            term_at += 1;
        }
        let mut m = ListMarker::new(ListMarkerKind::Description, &t[i..n], text_at);
        m.term = term;
        m.term_at = term_at;
        return Some(m);
    }
    None
}

/// A block macro line: `name::target[attrs]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockMacro<'a> {
    pub name: &'static [u8],
    pub target: &'a [u8],
    pub attrs: &'a [u8],
}

pub fn match_block_macro_text(t: &[u8]) -> Option<BlockMacro<'_>> {
    for name in [&b"image"[..], b"audio", b"video", b"toc"] {
        if t.starts_with(name) && t[name.len()..].starts_with(b"::") {
            let rest = &t[name.len() + 2..];
            let open = index_of_scalar(rest, b'[')?;
            if t[t.len() - 1] != b']' {
                return None;
            }
            let target = &rest[..open];
            if index_of_any(target, b" \t").is_some() {
                return None;
            }
            return Some(BlockMacro { name, target, attrs: &rest[open + 1..rest.len() - 1] });
        }
    }
    None
}

/// The numbering an ordered list's style names, or `None` for any other style.
pub fn numbering_for_style(style: &[u8]) -> Option<ListNumbering> {
    Some(match style {
        b"arabic" => ListNumbering::Decimal,
        b"loweralpha" => ListNumbering::LowerAlpha,
        b"upperalpha" => ListNumbering::UpperAlpha,
        b"lowerroman" => ListNumbering::LowerRoman,
        b"upperroman" => ListNumbering::UpperRoman,
        _ => return None,
    })
}

fn bullet_from_char(ch: u8) -> Bullet {
    match ch {
        b'*' => Bullet::Star,
        b'-' => Bullet::Dash,
        _ => Bullet::Plus,
    }
}

pub(crate) fn is_word_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

pub(crate) fn is_space_byte(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\n'
}

// ── line-level types ────────────────────────────────────────────────────────

/// One line of source, as a byte range excluding its terminating `\n`.
#[derive(Clone, Copy, Debug)]
struct LineInfo {
    start: usize,
    end: usize,
}

/// A recognized `=`-prefixed title line. A trailing ` [[id]]` anchor is
/// peeled off into `anchor_id`.
#[derive(Clone, Copy, Debug)]
struct HeadingMatch<'a> {
    level: i32,
    text: &'a [u8],
    text_span: Span,
    span_start: usize,
    marker_end: usize,
    /// End of the trimmed title line — past a trailing `[[anchor]]`.
    title_end: usize,
    next_line: usize,
    anchor_id: Option<&'a [u8]>,
}

#[derive(Clone, Copy, Debug)]
struct BlockResult {
    id: Option<NodeId>,
    next: usize,
    start_offset: usize,
    end_offset: usize,
}

/// A run of parsed blocks, plus the source extent they cover.
struct FlatResult {
    items: Vec<NodeId>,
    stopped_at: usize,
    first_start: usize,
    last_end: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DelimContent {
    Verbatim,
    Compound,
    Dropped,
}

/// One row of the delimited-block table.
#[derive(Clone, Copy, Debug)]
struct Delimiter {
    ch: u8,
    name: &'static [u8],
    content: DelimContent,
}

const OPEN_DELIM: Delimiter = Delimiter { ch: b'-', name: b"open", content: DelimContent::Compound };

const DELIMITERS: [Delimiter; 7] = [
    Delimiter { ch: b'-', name: b"listing", content: DelimContent::Verbatim },
    Delimiter { ch: b'.', name: b"literal", content: DelimContent::Verbatim },
    Delimiter { ch: b'+', name: b"pass", content: DelimContent::Verbatim },
    Delimiter { ch: b'=', name: b"example", content: DelimContent::Compound },
    Delimiter { ch: b'_', name: b"quote", content: DelimContent::Compound },
    Delimiter { ch: b'*', name: b"sidebar", content: DelimContent::Compound },
    Delimiter { ch: b'/', name: b"comment", content: DelimContent::Dropped },
];

const ROOT_LEVEL: i32 = -1;

/// Block metadata waiting for the block it belongs to.
#[derive(Clone, Debug, Default)]
struct Pending<'a> {
    start: Option<usize>,
    attr_start: Option<usize>,
    attr_end: usize,
    title: Option<&'a [u8]>,
    id: Option<&'a [u8]>,
    reftext: Option<&'a [u8]>,
    style: Option<&'a [u8]>,
    roles: Vec<&'a [u8]>,
    options: Vec<&'a [u8]>,
    /// Positional attributes from the second onward (`positional[0]` is `$2`);
    /// `None` once a block has consumed one into a semantic field.
    positional: Vec<Option<&'a [u8]>>,
    named: Vec<KeyVal>,
}

impl<'a> Pending<'a> {
    fn clear(&mut self) {
        *self = Pending::default();
    }

    fn has_option(&self, name: &[u8]) -> bool {
        self.options.contains(&name)
    }

    fn get(&self, key: &[u8]) -> Option<&[u8]> {
        for kv in &self.named {
            if kv.key == key {
                return kv.value.as_deref();
            }
        }
        None
    }

    /// The `n`th positional (2-based), consumed.
    fn take_positional(&mut self, n: usize) -> Option<&'a [u8]> {
        let idx = n - 2;
        if idx >= self.positional.len() {
            return None;
        }
        self.positional[idx].take()
    }

    fn take_style(&mut self) -> Option<&'a [u8]> {
        self.style.take()
    }

    fn style_is(&self, name: &[u8]) -> bool {
        self.style == Some(name)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BlockKind<'a> {
    Leaf(&'a [u8]),
    Quote,
    Parent(&'a [u8]),
}

struct CellSpec {
    colspan: u32,
    rowspan: u32,
    alignment: Alignment,
    /// Where the spec begins (the `2+` before the bar), for the cell's span.
    start: usize,
}

impl CellSpec {
    fn at(start: usize) -> CellSpec {
        CellSpec { colspan: 1, rowspan: 1, alignment: Alignment::Default, start }
    }
}

/// The cell spec directly before a bar at `bar` in `text`, if any:
/// `[N*|N+][.N+][<^>][.<^>][style]`.
fn cell_spec_before(text: &[u8], bar: usize, floor: usize) -> CellSpec {
    let mut s = bar;
    while s > floor && b"0123456789.+*<^>aehlmsdv".contains(&text[s - 1]) {
        s -= 1;
    }
    let mut spec = CellSpec::at(bar);
    let raw = &text[s..bar];
    if raw.is_empty() {
        return spec;
    }
    let mut i = 0;
    let mut num: u32 = 0;
    let mut have_num = false;
    while i < raw.len() && raw[i].is_ascii_digit() {
        num = num.wrapping_mul(10).wrapping_add((raw[i] - b'0') as u32);
        have_num = true;
        i += 1;
    }
    if have_num {
        if i < raw.len() && raw[i] == b'+' {
            spec.colspan = num.max(1);
            i += 1;
        } else if i < raw.len() && raw[i] == b'*' {
            i += 1; // duplication is not modelled; the cell still parses
        } else {
            return CellSpec::at(bar);
        }
    }
    if i < raw.len() && raw[i] == b'.' {
        let mut j = i + 1;
        let mut rnum: u32 = 0;
        let mut have_r = false;
        while j < raw.len() && raw[j].is_ascii_digit() {
            rnum = rnum.wrapping_mul(10).wrapping_add((raw[j] - b'0') as u32);
            have_r = true;
            j += 1;
        }
        if have_r && j < raw.len() && raw[j] == b'+' {
            spec.rowspan = rnum.max(1);
            i = j + 1;
        }
    }
    if i < raw.len() && b"<^>".contains(&raw[i]) {
        spec.alignment = match raw[i] {
            b'<' => Alignment::Left,
            b'^' => Alignment::Center,
            _ => Alignment::Right,
        };
        i += 1;
    }
    if i < raw.len() && raw[i] == b'.' && i + 1 < raw.len() && b"<^>".contains(&raw[i + 1]) {
        i += 2;
    }
    if i < raw.len() && b"aehlmsdv".contains(&raw[i]) {
        i += 1;
    }
    if i != raw.len() {
        return CellSpec::at(bar);
    }
    spec.start = s;
    spec
}

struct Parser<'a> {
    source: &'a [u8],
    lines: Vec<LineInfo>,
    b: Builder,
    pending: Pending<'a>,
    footnote_count: u32,
    /// Marker keys of every list currently open, innermost last.
    list_stack: Vec<&'a [u8]>,
}

struct ItemResult {
    id: NodeId,
    next: usize,
    end_offset: usize,
    checked: Option<bool>,
    box_span: Option<Span>,
}

impl<'a> Parser<'a> {
    fn new(source: &'a [u8]) -> Parser<'a> {
        Parser {
            source,
            lines: compute_lines(source),
            b: Builder::new(),
            pending: Pending::default(),
            footnote_count: 0,
            list_stack: Vec::new(),
        }
    }

    fn inlines(&mut self, text: &[u8], base: usize, hardbreaks: bool) -> Vec<NodeId> {
        let mut ctx = InlineCtx { b: &mut self.b, footnotes: &mut self.footnote_count, hardbreaks };
        parse_inlines(&mut ctx, text, base)
    }

    // ── line helpers ─────────────────────────────────────────────────────

    fn line_text(&self, i: usize) -> &'a [u8] {
        &self.source[self.lines[i].start..self.lines[i].end]
    }

    fn line_trimmed(&self, i: usize) -> &'a [u8] {
        trim_end(self.line_text(i), b" \t")
    }

    fn leading_spaces(&self, i: usize) -> usize {
        let t = self.line_text(i);
        let mut n = 0;
        while n < t.len() && (t[n] == b' ' || t[n] == b'\t') {
            n += 1;
        }
        n
    }

    fn is_blank_line(&self, i: usize) -> bool {
        self.line_text(i).iter().all(|&c| c == b' ' || c == b'\t')
    }

    fn first_non_blank_line(&self, from: usize) -> usize {
        let mut i = from;
        while i < self.lines.len() && self.is_blank_line(i) {
            i += 1;
        }
        i
    }

    // ── title / heading recognition ─────────────────────────────────────

    fn match_heading_line(&self, i: usize) -> Option<HeadingMatch<'a>> {
        if i >= self.lines.len() {
            return None;
        }
        if self.leading_spaces(i) != 0 {
            return None;
        }
        let t = self.line_text(i);
        let mut n = 0;
        while n < t.len() && t[n] == b'=' {
            n += 1;
        }
        if n == 0 || n > 6 || n >= t.len() || t[n] != b' ' {
            return None;
        }
        let mut text = trim(&t[n + 1..], b" \t");
        if text.is_empty() {
            return None;
        }
        let title_end = self.lines[i].start + trim_end(t, b" \t").len();
        // A trailing anchor: `== Title [[id]]`.
        let mut anchor = None;
        if text.ends_with(b"]]") {
            if let Some(at) = last_index_of(text, b" [[") {
                let inner = &text[at + 3..text.len() - 2];
                if !inner.is_empty() && index_of_any(inner, b"[] \t").is_none() {
                    anchor = Some(match index_of_scalar(inner, b',') {
                        Some(c) => &inner[..c],
                        None => inner,
                    });
                    text = trim_end(&text[..at], b" \t");
                }
            }
        }
        let text_start = self.lines[i].start + n + 1 + index_of(&t[n + 1..], text).unwrap_or(0);
        Some(HeadingMatch {
            level: (n - 1) as i32,
            text,
            text_span: Span::new(text_start, text_start + text.len()),
            span_start: self.lines[i].start,
            marker_end: self.lines[i].start + n + 1,
            title_end,
            next_line: i + 1,
            anchor_id: anchor,
        })
    }

    // ── block-start recognition ─────────────────────────────────────────

    fn match_delimiter(&self, i: usize) -> Option<(Delimiter, &'a [u8])> {
        if i >= self.lines.len() {
            return None;
        }
        if self.leading_spaces(i) != 0 {
            return None;
        }
        let t = self.line_trimmed(i);
        if t.len() < 2 {
            return None;
        }
        if t == b"--" {
            return Some((OPEN_DELIM, t));
        }
        if t.len() < 4 {
            return None;
        }
        if !t[1..].iter().all(|&c| c == t[0]) {
            return None;
        }
        DELIMITERS.iter().find(|d| d.ch == t[0]).map(|d| (*d, t))
    }

    fn matches_delim(&self, i: usize, opening: &[u8]) -> bool {
        if self.leading_spaces(i) != 0 {
            return false;
        }
        self.line_trimmed(i) == opening
    }

    fn match_fence(&self, i: usize) -> Option<FenceLine<'a>> {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return None;
        }
        match_fence_line(self.line_trimmed(i))
    }

    fn is_table_open(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        is_table_delimiter_line(self.line_trimmed(i))
    }

    fn match_list_marker(&self, i: usize) -> Option<ListMarker<'a>> {
        if i >= self.lines.len() {
            return None;
        }
        let t = self.line_text(i);
        let indent = self.leading_spaces(i);
        let mut m = match_list_marker_text(&t[indent..])?;
        // Description terms sit at column 0 only; the other markers may be indented.
        if m.kind == ListMarkerKind::Description && indent != 0 {
            return None;
        }
        m.text_at += indent;
        m.term_at += indent;
        Some(m)
    }

    /// A list marker that is NOT a description term.
    fn is_list_line(&self, i: usize) -> bool {
        match self.match_list_marker(i) {
            Some(m) => m.kind != ListMarkerKind::Description,
            None => false,
        }
    }

    fn is_continuation(&self, i: usize) -> bool {
        i < self.lines.len() && self.line_trimmed(i) == b"+"
    }

    /// `'''`, and Asciidoctor's Markdown-style `---`, `***`, `- - -`, `* * *`.
    fn is_thematic_break(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        let t = self.line_trimmed(i);
        if t.len() < 3 {
            return false;
        }
        if t.iter().all(|&c| c == b'\'') {
            return true;
        }
        [&b"---"[..], b"***", b"- - -", b"* * *"].contains(&t)
    }

    fn is_page_break(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        self.line_trimmed(i) == b"<<<"
    }

    fn is_line_comment(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        let t = self.line_text(i);
        t.len() >= 2 && t[0] == b'/' && t[1] == b'/' && !(t.len() >= 4 && t[2] == b'/' && t[3] == b'/')
    }

    fn is_meta_line(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        match_meta_line(self.line_text(i)).is_some()
    }

    /// `[…]` and `[[…]]` lines: the two metadata spellings that interrupt a
    /// paragraph (a `.Title` line does not — a sentence may start with a dot).
    fn is_attr_or_anchor_line(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        match match_meta_line(self.line_text(i)) {
            Some(MetaLine::Title(_)) | None => false,
            Some(_) => true,
        }
    }

    fn match_block_macro(&self, i: usize) -> Option<BlockMacro<'a>> {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return None;
        }
        match_block_macro_text(self.line_trimmed(i))
    }

    fn is_quote_line(&self, i: usize) -> bool {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return false;
        }
        let t = self.line_text(i);
        !t.is_empty() && t[0] == b'>'
    }

    fn match_admonition_para(&self, i: usize) -> Option<(&'static [u8], usize)> {
        if i >= self.lines.len() || self.leading_spaces(i) != 0 {
            return None;
        }
        let t = self.line_text(i);
        for label in ADMONITIONS {
            if t.len() > label.len() + 2 && t.starts_with(label) && t[label.len()] == b':' && t[label.len() + 1] == b' '
            {
                let mut at = label.len() + 2;
                while at < t.len() && t[at] == b' ' {
                    at += 1;
                }
                if at >= t.len() {
                    return None;
                }
                return Some((admonition_name(label).unwrap(), at));
            }
        }
        None
    }

    /// What ends a paragraph (or a list item's principal text) other than a
    /// blank line.
    fn is_block_start(&self, i: usize) -> bool {
        let list_line =
            if !self.list_stack.is_empty() { self.match_list_marker(i).is_some() } else { self.is_list_line(i) };
        self.match_heading_line(i).is_some()
            || self.match_delimiter(i).is_some()
            || self.match_fence(i).is_some()
            || self.is_table_open(i)
            || list_line
            || self.is_thematic_break(i)
            || self.is_page_break(i)
            || self.is_line_comment(i)
            || self.is_attr_or_anchor_line(i)
            || self.match_block_macro(i).is_some()
            || self.is_continuation(i)
    }

    // ── the top-level document scan ─────────────────────────────────────

    fn skip_preamble(&self, from: usize) -> usize {
        let mut i = from;
        while i < self.lines.len() {
            if self.is_blank_line(i) || self.is_line_comment(i) {
                i += 1;
                continue;
            }
            if let Some((d, text)) = self.match_delimiter(i) {
                if d.content == DelimContent::Dropped {
                    let mut j = i + 1;
                    while j < self.lines.len() && !self.matches_delim(j, text) {
                        j += 1;
                    }
                    i = if j < self.lines.len() { j + 1 } else { j };
                    continue;
                }
            }
            break;
        }
        i
    }

    fn parse_front_matter(&mut self) -> Option<(NodeId, usize)> {
        if self.lines.len() < 2 || self.line_trimmed(0) != b"---" {
            return None;
        }
        let mut j = 1;
        while j < self.lines.len() && self.line_trimmed(j) != b"---" {
            j += 1;
        }
        if j >= self.lines.len() {
            return None;
        }
        let content = if j > 1 {
            Span::new(self.lines[1].start, self.lines[j - 1].end)
        } else {
            Span::new(self.lines[1].start, self.lines[1].start)
        };
        let text = content.of(self.source).to_vec();
        let id = self.b.add_leaf(Kind::Metadata { lang: b"yaml".to_vec(), text });
        self.b.set_span(id, Span::new(self.lines[0].start, self.lines[j].end));
        if j > 1 {
            self.b.set_content_span(id, content);
        }
        Some((id, j + 1))
    }

    fn parse_document(&mut self) -> NodeId {
        let mut children: Vec<NodeId> = Vec::new();
        let mut start_offset = 0;
        let mut end_offset = 0;
        let mut have_start = false;

        let mut body_start_line = 0;
        if let Some((fm, next)) = self.parse_front_matter() {
            children.push(fm);
            start_offset = self.b.spans[fm as usize].start;
            end_offset = self.b.spans[fm as usize].end;
            have_start = true;
            body_start_line = next;
        }

        // The header, if any, is at the first non-blank, non-comment line.
        body_start_line = self.skip_preamble(body_start_line);
        let doc_title = self.match_heading_line(body_start_line).filter(|hm| hm.level == 0);

        let mut header_id = None;
        let mut attrs_id = None;
        if let Some(dt) = doc_title {
            let mut line = dt.next_line;
            let mut header_end_offset = self.lines[body_start_line].end;
            let mut attr_buf: Vec<KeyVal> = Vec::new();

            // The author line, then the revision line, then attribute entries.
            if line < self.lines.len()
                && !self.is_blank_line(line)
                && is_author_line(self.line_text(line))
                && match_meta_line(self.line_text(line)).is_none()
            {
                collect_authors(&mut attr_buf, self.line_text(line));
                header_end_offset = self.lines[line].end;
                line += 1;
                if line < self.lines.len()
                    && !self.is_blank_line(line)
                    && is_author_line(self.line_text(line))
                    && match_attr_entry(self.line_text(line)).is_none()
                {
                    collect_revision(&mut attr_buf, self.line_text(line));
                    header_end_offset = self.lines[line].end;
                    line += 1;
                }
            }
            while line < self.lines.len() && !self.is_blank_line(line) {
                if self.is_line_comment(line) {
                    line += 1;
                    continue;
                }
                let Some(entry) = match_attr_entry(self.line_text(line)) else { break };
                attr_buf.push(KeyVal::new(entry.key, entry.value));
                header_end_offset = self.lines[line].end;
                line += 1;
            }

            let title_ids = self.inlines(dt.text, dt.text_span.start, false);
            // `level = 1`, not the ASG's own `0`: twig's shared
            // `heading.level` is 1-based across every language.
            let heading_id = self.b.add_container(Kind::Heading { level: 1 }, &title_ids);
            self.b.set_span(heading_id, Span::new(dt.span_start, header_end_offset));
            self.b.set_marker_span(heading_id, Span::new(dt.span_start, dt.marker_end));
            if let Some(aid) = dt.anchor_id {
                self.b.set_attrs(heading_id, Attrs { entries: vec![kv(b"id", aid)] });
            }
            header_id = Some(heading_id);
            if !have_start {
                start_offset = dt.span_start;
                have_start = true;
            }
            end_offset = header_end_offset;

            // The attributes marker is present whenever a header is, even with
            // zero entries.
            let marker = self.b.add_node(Kind::Container(Container::named(b"document-attributes")));
            self.b.set_spelling(marker, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            if !attr_buf.is_empty() {
                self.b.set_attrs(marker, Attrs { entries: attr_buf });
            }
            attrs_id = Some(marker);
            body_start_line = line;
        }

        let body = self.parse_sections_loop(body_start_line, self.lines.len(), ROOT_LEVEL);

        if let Some(aid) = attrs_id {
            children.push(aid);
        }
        if let Some(hid) = header_id {
            children.push(hid);
        }
        children.extend_from_slice(&body.items);

        if !body.items.is_empty() {
            if !have_start {
                start_offset = body.first_start;
            }
            end_offset = body.last_end;
        }
        let root = self.b.add_container(Kind::Doc, &children);
        self.b.set_span(root, Span::new(start_offset, end_offset));
        root
    }

    // ── section nesting ───────────────────────────────────────────────────

    fn parse_sections_loop(&mut self, lo: usize, hi: usize, current_level: i32) -> FlatResult {
        let mut children: Vec<NodeId> = Vec::new();
        let mut i = lo;
        let mut first_start = 0;
        let mut last_end = 0;
        loop {
            let flat = self.parse_flat_blocks(i, hi);
            if !flat.items.is_empty() {
                if children.is_empty() {
                    first_start = flat.first_start;
                }
                last_end = flat.last_end;
            }
            children.extend_from_slice(&flat.items);
            i = flat.stopped_at;
            if i >= hi {
                self.pending.clear();
                break;
            }
            // `parse_flat_blocks` only stops early for a heading.
            let hm = self.match_heading_line(i).expect("flat scan stops at a heading");
            if hm.level <= current_level {
                break;
            }
            let (id, next, start_offset, end_offset) = self.parse_section(hm, hi);
            if children.is_empty() {
                first_start = start_offset;
            }
            children.push(id);
            last_end = end_offset;
            i = next;
        }
        FlatResult { items: children, stopped_at: i, first_start, last_end }
    }

    fn parse_section(&mut self, hm: HeadingMatch<'a>, hi: usize) -> (NodeId, usize, usize, usize) {
        // The metadata above the title (and the anchor inside it) is the
        // section's; the body's first block must not inherit it.
        let mut meta = self.take_pending();
        if let Some(aid) = hm.anchor_id {
            if meta.id.is_none() {
                meta.id = Some(aid);
            }
        }

        let title_ids = self.inlines(hm.text, hm.text_span.start, false);
        let heading_id = self.b.add_container(Kind::Heading { level: (hm.level + 1) as u32 }, &title_ids);
        self.b.set_span(heading_id, Span::new(hm.span_start, hm.title_end));
        self.b.set_marker_span(heading_id, Span::new(hm.span_start, hm.marker_end));

        let inner = self.parse_sections_loop(hm.next_line, hi, hm.level);

        let mut all = vec![heading_id];
        all.extend_from_slice(&inner.items);

        let id = self.b.add_container(Kind::Section, &all);
        let meta_start = self.apply_meta(&mut meta, id, &[]);
        let start = meta_start.unwrap_or(hm.span_start);
        let end_offset = if !inner.items.is_empty() { inner.last_end } else { hm.title_end };
        self.b.set_span(id, Span::new(start, end_offset));
        (id, inner.stopped_at, start, end_offset)
    }

    // ── the flat block scan ────────────────────────────────────────────

    /// Record one metadata line into `pending`.
    fn collect_meta(&mut self, i: usize) {
        let line = self.line_text(i);
        let m = match_meta_line(line).expect("a metadata line");
        if self.pending.start.is_none() {
            self.pending.start = Some(self.lines[i].start);
        }
        match m {
            MetaLine::Title(t) => self.pending.title = Some(t),
            MetaLine::Anchor { id, reftext } => {
                self.pending.id = Some(id);
                self.pending.reftext = reftext;
                if self.pending.attr_start.is_none() {
                    self.pending.attr_start = Some(self.lines[i].start);
                }
                self.pending.attr_end = self.lines[i].end;
            }
            MetaLine::Attrs(interior) => {
                if self.pending.attr_start.is_none() {
                    self.pending.attr_start = Some(self.lines[i].start);
                }
                self.pending.attr_end = self.lines[i].end;
                for e in AttrIter::new(interior) {
                    if let Some(k) = e.key {
                        if k == b"id" {
                            self.pending.id = Some(e.value);
                        } else if k == b"role" {
                            self.pending.roles.extend(tokenize(e.value, b" "));
                        } else if k == b"options" || k == b"opts" {
                            self.pending.options.extend(tokenize(e.value, b", "));
                        } else if k == b"title" {
                            self.pending.title = Some(e.value);
                        } else {
                            self.pending.named.push(kv(k, e.value));
                        }
                    } else if e.index == 1 {
                        for p in ShorthandIter::new(e.value) {
                            match p.kind {
                                ShorthandKind::Style => self.pending.style = Some(p.text),
                                ShorthandKind::Id => self.pending.id = Some(p.text),
                                ShorthandKind::Role => self.pending.roles.push(p.text),
                                ShorthandKind::Option => self.pending.options.push(p.text),
                            }
                        }
                    } else {
                        // Positional `$N` for N >= 2, in order; a skipped slot
                        // (`[a,,c]`) stays present and empty.
                        while self.pending.positional.len() < e.index - 1 {
                            self.pending.positional.push(None);
                        }
                        self.pending.positional[e.index - 2] = Some(e.value);
                    }
                }
            }
        }
    }

    /// Move the pending metadata out, leaving none pending.
    fn take_pending(&mut self) -> Pending<'a> {
        std::mem::take(&mut self.pending)
    }

    /// Attach the pending metadata to `id` as its attributes, then clear it.
    fn apply_pending(&mut self, id: NodeId, extra: &[KeyVal]) -> Option<usize> {
        let mut p = std::mem::take(&mut self.pending);
        let r = self.apply_meta(&mut p, id, extra);
        self.pending = p;
        r
    }

    /// `apply_pending` over an explicit `Pending`. `extra` entries are written
    /// first. Returns the block's metadata start offset.
    fn apply_meta(&mut self, p: &mut Pending<'a>, id: NodeId, extra: &[KeyVal]) -> Option<usize> {
        let start = p.start;
        let mut attr_buf: Vec<KeyVal> = extra.to_vec();
        if let Some(i) = p.id {
            attr_buf.push(kv(b"id", i));
        }
        let mut class_buf: Vec<u8> = Vec::new();
        if let Some(st) = p.style {
            class_buf.extend_from_slice(st);
        }
        for r in &p.roles {
            if !class_buf.is_empty() {
                class_buf.push(b' ');
            }
            class_buf.extend_from_slice(r);
        }
        if !class_buf.is_empty() {
            attr_buf.push(kv(b"class", &class_buf));
        }
        if let Some(t) = p.title {
            attr_buf.push(kv(b"title", t));
        }
        if !p.options.is_empty() {
            let joined = p.options.join(&b","[..]);
            attr_buf.push(kv(b"options", &joined));
        }
        attr_buf.extend(p.named.iter().cloned());
        for (k, slot) in p.positional.iter().enumerate() {
            let Some(v) = slot else { continue };
            if v.is_empty() {
                continue;
            }
            attr_buf.push(kv(format!("${}", k + 2).as_bytes(), v));
        }
        self.b.set_attrs(id, Attrs { entries: attr_buf });
        if let Some(s) = p.attr_start {
            self.b.set_attrs_span(id, Span::new(s, p.attr_end));
        }
        p.clear();
        start
    }

    /// Parses blocks in `[lo, hi)`, stopping at `hi` or at the first section
    /// heading (any level).
    fn parse_flat_blocks(&mut self, lo: usize, hi: usize) -> FlatResult {
        let mut children = Vec::new();
        let mut i = lo;
        let mut first_start = 0;
        let mut last_end = 0;
        while i < hi {
            if self.is_blank_line(i) {
                i += 1;
                continue;
            }
            if self.is_meta_line(i) {
                self.collect_meta(i);
                i += 1;
                continue;
            }
            let Some(r) = self.parse_block_at(i, hi) else { break };
            if let Some(id) = r.id {
                if children.is_empty() {
                    first_start = r.start_offset;
                }
                children.push(id);
                last_end = r.end_offset;
            }
            i = r.next;
        }
        FlatResult { items: children, stopped_at: i, first_start, last_end }
    }

    /// One block starting at (non-blank, non-metadata) line `i`. `None` when
    /// the line is a section heading, which only `parse_sections_loop` may
    /// consume. `id` is `None` for a block that produces no node.
    fn parse_block_at(&mut self, i: usize, hi: usize) -> Option<BlockResult> {
        if let Some(hm) = self.match_heading_line(i) {
            if self.pending.style_is(b"discrete") || self.pending.style_is(b"float") {
                return Some(self.parse_discrete_heading(hm));
            }
            return None;
        }
        if self.is_line_comment(i) {
            return Some(BlockResult { id: None, next: i + 1, start_offset: 0, end_offset: 0 });
        }
        if self.is_thematic_break(i) || self.is_page_break(i) {
            return Some(self.parse_break(i));
        }
        if let Some((d, text)) = self.match_delimiter(i) {
            return Some(self.parse_delimited(i, hi, d, text));
        }
        if let Some(f) = self.match_fence(i) {
            return Some(self.parse_fence(i, hi, f.fence, f.info));
        }
        if self.is_table_open(i) {
            return Some(self.parse_table(i, hi));
        }
        if self.is_quote_line(i) {
            return Some(self.parse_markdown_quote(i, hi));
        }
        if let Some(m) = self.match_block_macro(i) {
            return Some(self.parse_block_macro(i, m));
        }
        if let Some(m) = self.match_list_marker(i) {
            return Some(self.parse_list(i, hi, m));
        }
        if self.leading_spaces(i) == 0 {
            if let Some(e) = match_attr_entry(self.line_text(i)) {
                return Some(self.parse_attr_entry(i, e));
            }
        }
        if let Some((name, text_at)) = self.match_admonition_para(i) {
            return Some(self.parse_admonition_para(i, hi, name, text_at));
        }
        if self.is_continuation(i) {
            // A stray `+` outside a list is a paragraph of its own.
            return Some(self.parse_paragraph_block(i, i + 1));
        }
        if self.leading_spaces(i) > 0 && !self.pending.style_is(b"normal") && self.pending.style.is_none() {
            return Some(self.parse_indented_literal(i, hi));
        }
        let end = self.paragraph_end(i, hi);
        Some(self.parse_paragraph_block(i, end))
    }

    fn paragraph_end(&self, lo: usize, hi: usize) -> usize {
        let mut i = lo + 1;
        while i < hi {
            if self.is_blank_line(i) || self.is_block_start(i) {
                break;
            }
            i += 1;
        }
        i
    }

    fn parse_break(&mut self, i: usize) -> BlockResult {
        let id = if self.is_thematic_break(i) {
            self.b.add_node(Kind::ThematicBreak)
        } else {
            let pb = self.b.add_node(Kind::Container(Container::named(b"page-break")));
            self.b.set_spelling(pb, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            pb
        };
        let meta_start = self.apply_pending(id, &[]);
        let span = Span::new(meta_start.unwrap_or(self.lines[i].start), self.lines[i].end);
        self.b.set_span(id, span);
        BlockResult { id: Some(id), next: i + 1, start_offset: span.start, end_offset: span.end }
    }

    fn parse_discrete_heading(&mut self, hm: HeadingMatch<'a>) -> BlockResult {
        self.pending.take_style();
        let ids = self.inlines(hm.text, hm.text_span.start, false);
        let id = self.b.add_container(Kind::Heading { level: (hm.level + 1) as u32 }, &ids);
        if let Some(aid) = hm.anchor_id {
            if self.pending.id.is_none() {
                self.pending.id = Some(aid);
            }
        }
        let meta_start = self.apply_pending(id, &[]);
        let span = Span::new(meta_start.unwrap_or(hm.span_start), hm.title_end);
        self.b.set_span(id, span);
        self.b.set_marker_span(id, Span::new(hm.span_start, hm.marker_end));
        BlockResult { id: Some(id), next: hm.next_line, start_offset: span.start, end_offset: span.end }
    }

    fn parse_attr_entry(&mut self, i: usize, e: AttrEntryLine<'a>) -> BlockResult {
        let mut ids = Vec::new();
        if let Some(v) = e.value {
            if !v.is_empty() {
                let at = self.lines[i].start + index_of(self.line_text(i), v).unwrap_or(0);
                ids = self.inlines(v, at, false);
            }
        }
        let id = self.b.add_container(Kind::Substitution { label: e.key.to_vec() }, &ids);
        let extra: Vec<KeyVal> =
            if e.value.is_none() { vec![KeyVal::new(b"unset", None)] } else { Vec::new() };
        let meta_start = self.apply_pending(id, &extra);
        let span = Span::new(meta_start.unwrap_or(self.lines[i].start), self.lines[i].end);
        self.b.set_span(id, span);
        BlockResult { id: Some(id), next: i + 1, start_offset: span.start, end_offset: span.end }
    }

    // ── paragraphs and their styles ──────────────────────────────────────

    /// The paragraph at `[lo, end_ex)`, dispatched on the pending style.
    fn parse_paragraph_block(&mut self, lo: usize, end_ex: usize) -> BlockResult {
        let span = Span::new(self.lines[lo].start, self.lines[end_ex - 1].end);
        if let Some(style) = self.pending.style {
            if is_leaf_style(style) {
                return self.parse_leaf_paragraph(span, end_ex, style);
            }
            if let Some(name) = admonition_name(style) {
                self.pending.take_style();
                return self.wrap_paragraph(span, end_ex, Kind::Container(Container::with_form(name, Form::BlockFenced)));
            }
            if style == b"quote" {
                self.pending.take_style();
                self.take_quote_attribution();
                return self.wrap_paragraph(span, end_ex, Kind::BlockQuote);
            }
            if is_parent_style(style) {
                self.pending.take_style();
                return self.wrap_paragraph(span, end_ex, Kind::Container(Container::with_form(style, Form::BlockFenced)));
            }
            if style == b"normal" {
                self.pending.take_style();
            }
        }
        let hardbreaks = self.pending.has_option(b"hardbreaks");
        let id = self.build_para(span, hardbreaks);
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(span.start);
        self.b.set_span(id, Span::new(start, span.end));
        BlockResult { id: Some(id), next: end_ex, start_offset: start, end_offset: span.end }
    }

    fn build_para(&mut self, span: Span, hardbreaks: bool) -> NodeId {
        let text = span.of(self.source);
        let ids = self.inlines(text, span.start, hardbreaks);
        let id = self.b.add_container(Kind::Para, &ids);
        self.b.set_span(id, span);
        id
    }

    /// `[quote, attribution, citetitle]`'s two positionals become named
    /// attributes, which is what they are.
    fn take_quote_attribution(&mut self) {
        if let Some(a) = self.pending.take_positional(2) {
            if !a.is_empty() {
                self.pending.named.push(kv(b"attribution", a));
            }
        }
        if let Some(c) = self.pending.take_positional(3) {
            if !c.is_empty() {
                self.pending.named.push(kv(b"citetitle", c));
            }
        }
    }

    /// A styled paragraph that becomes a parent block holding the paragraph.
    fn wrap_paragraph(&mut self, span: Span, end_ex: usize, kind: Kind) -> BlockResult {
        let hardbreaks = self.pending.has_option(b"hardbreaks");
        let para = self.build_para(span, hardbreaks);
        let is_container = matches!(kind, Kind::Container(_));
        let id = self.b.add_container(kind, &[para]);
        if is_container {
            self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
        }
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(span.start);
        self.b.set_span(id, Span::new(start, span.end));
        self.b.set_content_span(id, span);
        BlockResult { id: Some(id), next: end_ex, start_offset: start, end_offset: span.end }
    }

    /// `[source]`/`[listing]`/`[literal]`/`[pass]`/`[stem]`/`[verse]` on a
    /// paragraph: the paragraph's lines are the block's opaque content.
    fn parse_leaf_paragraph(&mut self, span: Span, end_ex: usize, style: &'a [u8]) -> BlockResult {
        self.pending.take_style();
        let id = self.build_leaf_block(style, span);
        self.leaf_extra(style);
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(span.start);
        self.b.set_span(id, Span::new(start, span.end));
        BlockResult { id: Some(id), next: end_ex, start_offset: start, end_offset: span.end }
    }

    /// The semantic projection of a leaf style's positionals: a `verse`'s
    /// attribution is folded into the named entries here.
    fn leaf_extra(&mut self, style: &[u8]) {
        if style == b"verse" {
            self.take_quote_attribution();
        }
    }

    /// Build the leaf-block node a (style, content) pair means. `content` is
    /// the opaque interior (empty for an empty block).
    fn build_leaf_block(&mut self, style: &[u8], content: Span) -> NodeId {
        let text = content.of(self.source);
        let has_content = content.end > content.start;
        if style == b"verse" {
            return self.build_verse(content);
        }
        if style == b"pass" {
            let id = self.b.add_leaf(Kind::RawBlock { format: b"html".to_vec(), text: text.to_vec() });
            if has_content {
                self.b.set_content_span(id, content);
            }
            return id;
        }
        let mut lang: Option<Vec<u8>> = None;
        if style == b"source" || style == b"listing" {
            lang = self.take_lang_owned();
        } else if style == b"stem" || style == b"latexmath" || style == b"asciimath" {
            lang = Some(style.to_vec());
        }
        let id = self.b.add_leaf(Kind::CodeBlock { lang, text: text.to_vec() });
        if has_content {
            self.b.set_content_span(id, content);
        }
        id
    }

    /// `take_lang`, owned: a `language=` named entry wins, else the second
    /// positional (consumed).
    fn take_lang_owned(&mut self) -> Option<Vec<u8>> {
        if let Some(l) = self.pending.get(b"language") {
            return Some(l.to_vec());
        }
        let p = self.pending.take_positional(2)?;
        if !p.is_empty() {
            Some(p.to_vec())
        } else {
            None
        }
    }

    /// A verse: one `line` per source line, holding that line's inlines, with
    /// `indent` as the line's depth among the block's distinct indentations.
    fn build_verse(&mut self, content: Span) -> NodeId {
        let mut lines_out = Vec::new();
        let text = content.of(self.source);
        let widths = indent_widths(text);
        let mut offset = content.start;
        for l in text.split(|&c| c == b'\n') {
            let w = l.len() - trim_start(l, b" \t").len();
            let body = &l[w..];
            let depth: u32 =
                if body.is_empty() { 0 } else { widths.iter().position(|&x| x == w).unwrap() as u32 };
            let ids = self.inlines(body, offset + w, false);
            let line_id = self.b.add_container(Kind::Line { indent: depth }, &ids);
            self.b.set_span(line_id, Span::new(offset, offset + l.len()));
            lines_out.push(line_id);
            offset += l.len() + 1;
        }
        let id = self.b.add_container(Kind::LineBlock, &lines_out);
        if content.end > content.start {
            self.b.set_content_span(id, content);
        }
        id
    }

    /// `NOTE: text` — an admonition paragraph.
    fn parse_admonition_para(&mut self, i: usize, hi: usize, name: &'static [u8], text_at: usize) -> BlockResult {
        let end = self.paragraph_end(i, hi);
        let para_span = Span::new(self.lines[i].start + text_at, self.lines[end - 1].end);
        let hardbreaks = self.pending.has_option(b"hardbreaks");
        let para = self.build_para(para_span, hardbreaks);
        let id = self.b.add_container(Kind::Container(Container::with_form(name, Form::BlockFenced)), &[para]);
        self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(self.lines[i].start);
        self.b.set_span(id, Span::new(start, para_span.end));
        self.b.set_content_span(id, para_span);
        self.b.set_marker_span(id, Span::new(self.lines[i].start, self.lines[i].start + text_at));
        BlockResult { id: Some(id), next: end, start_offset: start, end_offset: para_span.end }
    }

    /// An indented paragraph is a literal block; the common indentation is
    /// stripped from its text, the content span keeps it.
    fn parse_indented_literal(&mut self, i: usize, hi: usize) -> BlockResult {
        let mut end = i + 1;
        while end < hi && !self.is_blank_line(end) && !self.is_block_start(end) {
            end += 1;
        }
        let content = Span::new(self.lines[i].start, self.lines[end - 1].end);
        let min = (i..end).map(|k| self.leading_spaces(k)).min().unwrap_or(usize::MAX);
        let mut text = Vec::new();
        for k in i..end {
            if k > i {
                text.push(b'\n');
            }
            text.extend_from_slice(&self.line_text(k)[min..]);
        }
        let id = self.b.add_leaf(Kind::CodeBlock { lang: None, text });
        self.b.set_content_span(id, content);
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(content.start);
        self.b.set_span(id, Span::new(start, content.end));
        BlockResult { id: Some(id), next: end, start_offset: start, end_offset: content.end }
    }

    // ── delimited blocks ─────────────────────────────────────────────────

    /// One delimited block, from its opening delimiter line. The pending
    /// STYLE can override what the delimiter says. An UNCLOSED block runs to
    /// `hi`, ending at its last content line.
    fn parse_delimited(&mut self, delim_line: usize, hi: usize, delim: Delimiter, opening: &'a [u8]) -> BlockResult {
        let mut close_line = delim_line + 1;
        while close_line < hi && !self.matches_delim(close_line, opening) {
            close_line += 1;
        }
        let closed = close_line < hi;
        let content_lo = delim_line + 1;
        let content_hi = close_line;
        let has_content = content_hi > content_lo;
        let next = if closed { close_line + 1 } else { content_hi };
        let end_offset = if closed {
            self.lines[close_line].end
        } else if has_content {
            self.lines[content_hi - 1].end
        } else {
            self.lines[delim_line].end
        };

        if delim.content == DelimContent::Dropped {
            return BlockResult { id: None, next, start_offset: 0, end_offset: 0 };
        }

        let content = if has_content {
            Span::new(self.lines[content_lo].start, self.lines[content_hi - 1].end)
        } else {
            Span::new(self.lines[delim_line].end, self.lines[delim_line].end)
        };

        // What the block IS: the style first, then the delimiter.
        let style = self.pending.style;
        let mut kind = match delim.content {
            DelimContent::Verbatim => BlockKind::Leaf(delim.name),
            DelimContent::Compound => {
                if delim.name == b"quote" {
                    BlockKind::Quote
                } else {
                    BlockKind::Parent(delim.name)
                }
            }
            DelimContent::Dropped => unreachable!(),
        };
        if let Some(s) = style {
            if is_leaf_style(s) {
                kind = BlockKind::Leaf(s);
                self.pending.take_style();
            } else if let Some(name) = admonition_name(s) {
                kind = BlockKind::Parent(name);
                self.pending.take_style();
            } else if s == b"quote" {
                kind = BlockKind::Quote;
                self.pending.take_style();
            } else if is_parent_style(s) {
                kind = BlockKind::Parent(s);
                self.pending.take_style();
            } else if delim.name == b"listing" && (s == b"source" || !self.pending.positional.is_empty()) {
                self.pending.take_style();
            }
        }
        // `[,ruby]` on a listing is a source block with a language.
        if kind == BlockKind::Leaf(b"listing") && style.is_none() {
            kind = BlockKind::Leaf(b"source");
        }

        let id;
        let meta_start;
        match kind {
            BlockKind::Leaf(s) => {
                id = self.build_leaf_block(s, content);
                self.leaf_extra(s);
                meta_start = self.apply_pending(id, &[]);
            }
            BlockKind::Quote | BlockKind::Parent(_) => {
                if kind == BlockKind::Quote {
                    self.take_quote_attribution();
                }
                // The metadata is this block's; the interior's first block
                // must not inherit it.
                let mut meta = self.take_pending();
                let inner = self.parse_flat_blocks(content_lo, content_hi);
                if let BlockKind::Parent(name) = kind {
                    id = self.b.add_container(Kind::Container(Container::with_form(name, Form::BlockFenced)), &inner.items);
                    self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
                } else {
                    id = self.b.add_container(Kind::BlockQuote, &inner.items);
                }
                if has_content {
                    self.b.set_content_span(id, content);
                }
                meta_start = self.apply_meta(&mut meta, id, &[]);
            }
        }
        let start = meta_start.unwrap_or(self.lines[delim_line].start);
        self.b.set_span(id, Span::new(start, end_offset));
        BlockResult { id: Some(id), next, start_offset: start, end_offset }
    }

    /// A Markdown-style fenced code block, which Asciidoctor reads as a
    /// source listing.
    fn parse_fence(&mut self, fence_line: usize, hi: usize, fence: &'a [u8], info: &'a [u8]) -> BlockResult {
        let mut close_line = fence_line + 1;
        while close_line < hi && !self.matches_delim(close_line, fence) {
            close_line += 1;
        }
        let closed = close_line < hi;
        let has_content = close_line > fence_line + 1;
        let content = if has_content {
            Span::new(self.lines[fence_line + 1].start, self.lines[close_line - 1].end)
        } else {
            Span::new(self.lines[fence_line].end, self.lines[fence_line].end)
        };
        let lang = if !info.is_empty() { Some(info.to_vec()) } else { self.take_lang_owned() };
        let id = self.b.add_leaf(Kind::CodeBlock { lang, text: content.of(self.source).to_vec() });
        if has_content {
            self.b.set_content_span(id, content);
        }
        if self.pending.style_is(b"source") {
            self.pending.take_style();
        }
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(self.lines[fence_line].start);
        let end_offset = if closed {
            self.lines[close_line].end
        } else if has_content {
            content.end
        } else {
            self.lines[fence_line].end
        };
        self.b.set_span(id, Span::new(start, end_offset));
        BlockResult { id: Some(id), next: if closed { close_line + 1 } else { close_line }, start_offset: start, end_offset }
    }

    /// `> ` quotes: the marker is stripped from every line and the interior
    /// parsed as blocks. The interior is not contiguous source, so it is
    /// parsed from a copy and grafted back at the right offsets.
    fn parse_markdown_quote(&mut self, lo: usize, hi: usize) -> BlockResult {
        let mut end = lo;
        while end < hi && self.is_quote_line(end) {
            end += 1;
        }
        let mut scratch: Vec<u8> = Vec::new();
        let mut offsets: Vec<usize> = Vec::new();
        for k in lo..end {
            let t = self.line_text(k);
            let mut strip = 1;
            if t.len() > 1 && t[1] == b' ' {
                strip = 2;
            }
            offsets.push(self.lines[k].start + strip);
            scratch.extend_from_slice(&t[strip..]);
            scratch.push(b'\n');
        }
        // Parse the scratch as its own document and graft its blocks in.
        let inner = parse(&scratch);
        let kids: Vec<NodeId> = inner.ast.child_ids(inner.ast.root);
        let mut children = Vec::new();
        for c in kids {
            children.push(self.graft_shifted(&inner, c, &offsets, &scratch));
        }
        let id = self.b.add_container(Kind::BlockQuote, &children);
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(self.lines[lo].start);
        let end_offset = self.lines[end - 1].end;
        self.b.set_span(id, Span::new(start, end_offset));
        // The first line's `> ` is the quote's marker, as Markdown records it.
        self.b.set_marker_span(id, Span::new(self.lines[lo].start, offsets[0]));
        BlockResult { id: Some(id), next: end, start_offset: start, end_offset }
    }

    /// Copy a subtree parsed from a stripped scratch source into this
    /// builder, mapping every scratch offset to its real one.
    fn graft_shifted(&mut self, src: &Document, id: NodeId, offsets: &[usize], scratch: &[u8]) -> NodeId {
        let kids: Vec<NodeId> = src.ast.child_ids(id);
        let mut out = Vec::new();
        for c in kids {
            out.push(self.graft_shifted(src, c, offsets, scratch));
        }
        let node = &src.ast.nodes[id as usize];
        let nid = self.b.add_container(node.kind.clone(), &out);
        let sp = src.span(id);
        self.b.set_span(nid, Span::new(map_offset(offsets, scratch, sp.start), map_offset(offsets, scratch, sp.end)));
        if let Some(cs) = src.content_span(id) {
            self.b
                .set_content_span(nid, Span::new(map_offset(offsets, scratch, cs.start), map_offset(offsets, scratch, cs.end)));
        }
        if let Some(s) = src.spelling(id) {
            self.b.set_spelling(nid, s);
        }
        if let Some(ms) = src.marker_span(id) {
            self.b
                .set_marker_span(nid, Span::new(map_offset(offsets, scratch, ms.start), map_offset(offsets, scratch, ms.end)));
        }
        let attrs = src.ast.attrs_of(id);
        if !attrs.is_empty() {
            self.b.set_attrs(nid, attrs.clone());
        }
        nid
    }

    // ── block macros ─────────────────────────────────────────────────────

    fn parse_block_macro(&mut self, i: usize, m: BlockMacro<'a>) -> BlockResult {
        let line_start = self.lines[i].start;
        let t = self.line_text(i);
        let attrs_at = line_start + index_of_scalar(t, b'[').unwrap_or(t.len());
        let id;
        if m.name == b"image" {
            let mut alt: Option<&[u8]> = None;
            let mut width: Option<&[u8]> = None;
            let mut height: Option<&[u8]> = None;
            for e in AttrIter::new(m.attrs) {
                if let Some(k) = e.key {
                    if k == b"alt" {
                        alt = Some(e.value);
                    } else if k == b"width" {
                        width = Some(e.value);
                    } else if k == b"height" {
                        height = Some(e.value);
                    } else {
                        self.pending.named.push(kv(k, e.value));
                    }
                } else {
                    match e.index {
                        1 => alt = Some(e.value),
                        2 => width = Some(e.value),
                        3 => height = Some(e.value),
                        _ => {}
                    }
                }
            }
            let mut kids = Vec::new();
            if let Some(a) = alt {
                if !a.is_empty() {
                    let s = self.b.add_leaf(Kind::Str(a.to_vec()));
                    let at = attrs_at + 1 + index_of(m.attrs, a).unwrap_or(0);
                    self.b.set_span(s, Span::new(at, at + a.len()));
                    kids.push(s);
                }
            }
            let img = self.b.add_container(
                Kind::Image(Link { destination: Some(m.target.to_vec()), reference: None }),
                &kids,
            );
            self.b.set_span(img, Span::new(line_start, self.lines[i].end));
            let mut attr_buf = Vec::new();
            if let Some(w) = width {
                attr_buf.push(kv(b"width", w));
            }
            if let Some(h) = height {
                attr_buf.push(kv(b"height", h));
            }
            if !attr_buf.is_empty() {
                self.b.set_attrs(img, Attrs { entries: attr_buf });
            }
            id = self.b.add_container(Kind::Para, &[img]);
        } else {
            // audio / video / toc: a leaf directive whose argument is the target.
            id = self.b.add_node(Kind::Container(Container {
                name: m.name.to_vec(),
                form: Some(Form::BlockLeaf),
                argument: if !m.target.is_empty() { Some(m.target.to_vec()) } else { None },
                text: None,
            }));
            self.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
            let positional_names: &[&[u8]] =
                if m.name == b"video" { &[b"poster", b"width", b"height"] } else { &[] };
            for e in AttrIter::new(m.attrs) {
                if let Some(k) = e.key {
                    self.pending.named.push(kv(k, e.value));
                } else if e.index <= positional_names.len() {
                    if !e.value.is_empty() {
                        self.pending.named.push(kv(positional_names[e.index - 1], e.value));
                    }
                } else if e.index == 1 {
                    // A first positional the macro gives no name — `toc::[x]`,
                    // `audio::a.mp3[x]`. `pending.positional` is numbered from
                    // `$2` (a block list's `$1` is its shorthand), so it keeps
                    // its number here instead, as a leftover one does.
                    if !e.value.is_empty() {
                        self.pending.named.push(kv(b"$1", e.value));
                    }
                } else if !e.value.is_empty() {
                    while self.pending.positional.len() < e.index - 1 {
                        self.pending.positional.push(None);
                    }
                    self.pending.positional[e.index - 2] = Some(e.value);
                }
            }
        }
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(line_start);
        self.b.set_span(id, Span::new(start, self.lines[i].end));
        BlockResult { id: Some(id), next: i + 1, start_offset: start, end_offset: self.lines[i].end }
    }

    // ── tables ───────────────────────────────────────────────────────────

    fn parse_table(&mut self, open_line: usize, hi: usize) -> BlockResult {
        let opening = self.line_trimmed(open_line);
        let mut close_line = open_line + 1;
        while close_line < hi && !self.matches_delim(close_line, opening) {
            close_line += 1;
        }
        let closed = close_line < hi;
        let content_lo = open_line + 1;
        let content_hi = close_line;

        // Column count: `cols`, else the first line's cell count.
        let mut ncols: usize = 0;
        if let Some(cols) = self.pending.get(b"cols") {
            let cols = cols.to_vec();
            for c in cols.split(|&x| x == b',').filter(|p| !p.is_empty()) {
                let spec = trim(c, b" ");
                // `3*` or `3*<` repeats; a bare number is a width.
                if let Some(star) = index_of_scalar(spec, b'*') {
                    ncols += parse_usize(&spec[..star]).unwrap_or(1);
                } else {
                    ncols += 1;
                }
            }
            if ncols == 1 {
                let only = trim(&cols, b" ");
                if let Some(n) = parse_usize(only) {
                    ncols = n;
                }
            }
        }

        // Every cell in the body, in order.
        struct TCell {
            spec: CellSpec,
            text_start: usize,
            text_end: usize,
            line: usize,
        }
        let mut cells: Vec<TCell> = Vec::new();
        if content_hi > content_lo {
            let region = Span::new(self.lines[content_lo].start, self.lines[content_hi - 1].end);
            let text = region.of(self.source);
            let mut i = 0;
            let mut current: Option<usize> = None;
            let mut line_floor = 0;
            let mut line_no = content_lo;
            while i < text.len() {
                let c = text[i];
                if c == b'\n' {
                    line_floor = i + 1;
                    line_no += 1;
                    i += 1;
                    continue;
                }
                if c == b'\\' && i + 1 < text.len() && text[i + 1] == b'|' {
                    i += 2;
                    continue;
                }
                if c != b'|' {
                    i += 1;
                    continue;
                }
                let spec = cell_spec_before(text, i, line_floor);
                if let Some(ci) = current {
                    cells[ci].text_end = region.start + spec.start;
                }
                cells.push(TCell {
                    spec: CellSpec {
                        colspan: spec.colspan,
                        rowspan: spec.rowspan,
                        alignment: spec.alignment,
                        start: region.start + spec.start,
                    },
                    text_start: region.start + i + 1,
                    text_end: region.end,
                    line: line_no,
                });
                current = Some(cells.len() - 1);
                i += 1;
            }
            if ncols == 0 {
                for cell in &cells {
                    if cell.line != content_lo {
                        break;
                    }
                    ncols += cell.spec.colspan as usize;
                }
            }
        }
        if ncols == 0 {
            ncols = 1;
        }

        // Header: the `header` option, or an implicit one — the first row on a
        // single line followed by a blank line.
        let mut header = self.pending.has_option(b"header");
        if !header && !cells.is_empty() && content_hi > content_lo + 1 {
            let mut first_line_cols = 0usize;
            for cell in &cells {
                if cell.line != content_lo {
                    break;
                }
                first_line_cols += cell.spec.colspan as usize;
            }
            if first_line_cols == ncols && self.is_blank_line(content_lo + 1) {
                header = true;
            }
        }

        let mut rows: Vec<NodeId> = Vec::new();
        let mut row_cells: Vec<NodeId> = Vec::new();
        let mut filled: usize = 0;
        let mut row_start = 0;
        let mut row_index = 0;
        for k in 0..cells.len() {
            let cell = &cells[k];
            let is_head = header && row_index == 0;
            let raw = &self.source[cell.text_start..cell.text_end];
            let trimmed = trim(raw, b" \t\n");
            let text_at = cell.text_start + index_of(raw, trimmed).unwrap_or(0);
            let (colspan, rowspan, alignment, spec_start, text_start) =
                (cell.spec.colspan, cell.spec.rowspan, cell.spec.alignment, cell.spec.start, cell.text_start);
            let ids = self.inlines(trimmed, text_at, false);
            let cid = self.b.add_container(Kind::Cell(Cell { head: is_head, alignment, colspan, rowspan }), &ids);
            let cell_end = if !trimmed.is_empty() { text_at + trimmed.len() } else { text_start };
            self.b.set_span(cid, Span::new(spec_start, cell_end));
            if !trimmed.is_empty() {
                self.b.set_content_span(cid, Span::new(text_at, cell_end));
            }
            if row_cells.is_empty() {
                row_start = spec_start;
            }
            row_cells.push(cid);
            filled += colspan as usize;
            if filled >= ncols || k + 1 == cells.len() {
                let rid = self.b.add_container(Kind::Row { head: is_head }, &row_cells);
                self.b.set_span(rid, Span::new(row_start, cell_end));
                rows.push(rid);
                row_cells.clear();
                filled = 0;
                row_index += 1;
            }
        }

        let mut children = Vec::new();
        if let Some(title) = self.pending.title {
            // A table's title is its caption.
            let cap_text = self.b.add_leaf(Kind::Str(title.to_vec()));
            let cap = self.b.add_container(Kind::Caption, &[cap_text]);
            children.push(cap);
            self.pending.title = None;
        }
        children.extend_from_slice(&rows);
        let id = self.b.add_container(Kind::Table, &children);
        let meta_start = self.apply_pending(id, &[]);
        let start = meta_start.unwrap_or(self.lines[open_line].start);
        let end_offset = if closed {
            self.lines[close_line].end
        } else if content_hi > content_lo {
            self.lines[content_hi - 1].end
        } else {
            self.lines[open_line].end
        };
        self.b.set_span(id, Span::new(start, end_offset));
        if content_hi > content_lo {
            self.b.set_content_span(id, Span::new(self.lines[content_lo].start, self.lines[content_hi - 1].end));
        }
        BlockResult { id: Some(id), next: if closed { close_line + 1 } else { close_line }, start_offset: start, end_offset }
    }

    // ── lists ────────────────────────────────────────────────────────────

    /// One list from its first item at line `lo`; every item shares the
    /// first item's marker identity (`ListMarker::key`).
    fn parse_list(&mut self, lo: usize, hi: usize, first: ListMarker<'a>) -> BlockResult {
        // The metadata above the list belongs to the LIST.
        let mut meta = self.take_pending();
        let key = first.key();
        self.list_stack.push(key);

        let mut items: Vec<NodeId> = Vec::new();
        let mut checks: Vec<Option<bool>> = Vec::new();
        let mut boxes: Vec<Option<Span>> = Vec::new();
        let mut i = lo;
        let mut last_end = self.lines[lo].end;
        let mut next_line = lo;
        while i < hi {
            let Some(m) = self.match_list_marker(i) else { break };
            if m.key() != key {
                break;
            }
            let r = self.parse_list_item(i, hi, m, key);
            items.push(r.id);
            checks.push(r.checked);
            boxes.push(r.box_span);
            last_end = r.end_offset;
            next_line = r.next;
            i = self.first_non_blank_line(r.next);
        }

        // A checklist is a list whose every item carries a box.
        let mut all_boxed = first.kind == ListMarkerKind::Unordered && !items.is_empty();
        if checks.iter().any(|c| c.is_none()) {
            all_boxed = false;
        }
        if all_boxed {
            for (item, c) in items.iter().zip(checks.iter()) {
                *self.b.kind_mut(*item) = Kind::TaskListItem { checked: c.unwrap() };
            }
        } else {
            // A box on an item of a list that is not a checklist is text, and
            // is put back in front of the item's principal.
            for (item, box_opt) in items.iter().zip(boxes.iter()) {
                let Some(bx) = box_opt else { continue };
                let box_str = self.b.add_leaf(Kind::Str(bx.of(self.source).to_vec()));
                self.b.set_span(box_str, *bx);
                let mut kids = vec![box_str];
                let mut c = self.b.nodes[*item as usize].first_child;
                while let Some(cid) = c {
                    kids.push(cid);
                    c = self.b.nodes[cid as usize].next_sibling;
                }
                self.b.set_children(*item, &kids);
            }
        }

        // An ordered list's numbering style and start may be attributes on
        // the list (`[loweralpha,start=3]`) as well as spelled by its marker.
        let mut numbering = first.numbering;
        let mut start_at = first.start;
        if first.kind == ListMarkerKind::Ordered {
            if let Some(st) = meta.style {
                if let Some(n) = numbering_for_style(st) {
                    numbering = n;
                    meta.take_style();
                }
            }
            if let Some(v) = meta.get(b"start") {
                if let Some(n) = parse_u32(v) {
                    start_at = Some(n);
                    if let Some(k) = meta.named.iter().position(|kv| kv.key == b"start") {
                        meta.named.remove(k);
                    }
                }
            }
        }
        let kind = match first.kind {
            ListMarkerKind::Unordered => {
                if all_boxed {
                    Kind::TaskList { tight: true }
                } else {
                    Kind::BulletList { tight: true }
                }
            }
            ListMarkerKind::Ordered => Kind::OrderedList { numbering, tight: true, start: start_at },
            ListMarkerKind::Callout => {
                Kind::OrderedList { numbering: ListNumbering::Decimal, tight: true, start: None }
            }
            ListMarkerKind::Description => Kind::DefinitionList,
        };
        let id = self.b.add_container(kind, &items);
        match first.kind {
            ListMarkerKind::Unordered => self.b.set_spelling(id, Spelling::Bullet(bullet_from_char(first.text[0]))),
            ListMarkerKind::Ordered => self.b.set_spelling(id, Spelling::OrderedDelim(first.delim)),
            _ => {}
        }
        let meta_start = self.apply_meta(&mut meta, id, &[]);
        let start = meta_start.unwrap_or(self.lines[lo].start);
        self.b.set_span(id, Span::new(start, last_end));
        self.list_stack.pop();
        BlockResult { id: Some(id), next: next_line, start_offset: start, end_offset: last_end }
    }

    fn parse_list_item(&mut self, i: usize, hi: usize, m: ListMarker<'a>, list_key: &'a [u8]) -> ItemResult {
        let line_start = self.lines[i].start;
        let mut kids: Vec<NodeId> = Vec::new();
        let mut terms: Vec<NodeId> = Vec::new();

        let mut cur = i;
        let mut text_start: Option<usize> = None;
        let mut checked: Option<bool> = None;
        let mut box_span: Option<Span> = None;
        let mut marker_span = Span::new(line_start + self.leading_spaces(i), line_start + m.text_at);

        if m.kind == ListMarkerKind::Description {
            let mut mm = m;
            loop {
                let base = self.lines[cur].start + mm.term_at;
                let term_ids = self.inlines(mm.term, base, false);
                let term_id = self.b.add_container(Kind::Term, &term_ids);
                self.b.set_span(term_id, Span::new(base, base + mm.term.len()));
                terms.push(term_id);
                marker_span = Span::new(base + mm.term.len(), self.lines[cur].start + mm.text_at);
                if mm.text_at < self.line_text(cur).len() {
                    text_start = Some(self.lines[cur].start + mm.text_at);
                    break;
                }
                cur += 1;
                if cur < hi {
                    if let Some(nm) = self.match_list_marker(cur) {
                        if nm.kind == ListMarkerKind::Description && nm.key() == list_key {
                            mm = nm;
                            continue;
                        }
                    }
                }
                // The description on the following line(s), possibly after a blank.
                let q = self.first_non_blank_line(cur);
                if q < hi && self.match_list_marker(q).is_none() && !self.is_block_start(q) {
                    cur = q;
                    text_start = Some(self.lines[q].start + self.leading_spaces(q));
                }
                break;
            }
        } else {
            let mut at = m.text_at;
            let t = self.line_text(i);
            if m.kind == ListMarkerKind::Unordered
                && t.len() >= at + 4
                && t[at] == b'['
                && t[at + 2] == b']'
                && t[at + 3] == b' '
                && b" xX*".contains(&t[at + 1])
            {
                checked = Some(t[at + 1] != b' ');
                let box_start = line_start + at;
                at += 4;
                while at < t.len() && t[at] == b' ' {
                    at += 1;
                }
                box_span = Some(Span::new(box_start, line_start + at));
            }
            text_start = Some(line_start + at);
        }

        let mut end_offset;
        let end_line;
        if let Some(ts) = text_start {
            // The principal text runs onto following lines that are neither
            // blank nor the start of another block or list item.
            let mut el = cur + 1;
            while el < hi && !self.is_blank_line(el) && !self.is_block_start(el) && self.match_list_marker(el).is_none() {
                el += 1;
            }
            end_line = el;
            let text = trim_end(&self.source[ts..self.lines[end_line - 1].end], b" \t");
            let ids = self.inlines(text, ts, false);
            kids.extend_from_slice(&ids);
            end_offset = ts + text.len();
        } else {
            end_line = cur;
            end_offset = marker_span.end;
        }

        // Attached blocks: nested lists, `+` continuations, and blank-separated
        // indented literals.
        let mut j = end_line;
        while j < hi {
            let q = self.first_non_blank_line(j);
            if q >= hi {
                break;
            }
            if self.is_continuation(q) {
                let mut k = self.first_non_blank_line(q + 1);
                if k >= hi {
                    break;
                }
                while k < hi && self.is_meta_line(k) {
                    self.collect_meta(k);
                    k += 1;
                }
                if k >= hi {
                    break;
                }
                let Some(r) = self.parse_block_at(k, hi) else { break };
                if let Some(bid) = r.id {
                    kids.push(bid);
                    end_offset = r.end_offset;
                }
                j = r.next;
                continue;
            }
            if let Some(nm) = self.match_list_marker(q) {
                let nk = nm.key();
                if nk == list_key {
                    break;
                }
                if self.list_stack.contains(&nk) {
                    break;
                }
                let r = self.parse_list(q, hi, nm);
                kids.push(r.id.unwrap());
                end_offset = r.end_offset;
                j = r.next;
                continue;
            }
            if q > j && self.leading_spaces(q) > 0 && !self.is_block_start(q) {
                let r = self.parse_indented_literal(q, hi);
                kids.push(r.id.unwrap());
                end_offset = r.end_offset;
                j = r.next;
                continue;
            }
            break;
        }

        let id;
        if m.kind == ListMarkerKind::Description {
            let mut all = terms.clone();
            if !kids.is_empty() {
                let def = self.b.add_container(Kind::Definition, &kids);
                let def_start = text_start.unwrap_or(self.b.spans[kids[0] as usize].start);
                self.b.set_span(def, Span::new(def_start, end_offset));
                all.push(def);
            }
            id = self.b.add_container(Kind::DefinitionListItem, &all);
        } else {
            id = self.b.add_container(Kind::ListItem, &kids);
            match m.kind {
                ListMarkerKind::Unordered => self.b.set_spelling(id, Spelling::Bullet(bullet_from_char(m.text[0]))),
                ListMarkerKind::Ordered => self.b.set_spelling(id, Spelling::OrderedDelim(m.delim)),
                _ => {}
            }
        }
        self.b.set_span(id, Span::new(line_start + self.leading_spaces(i), end_offset));
        self.b.set_marker_span(id, marker_span);
        ItemResult { id, next: j, end_offset, checked, box_span }
    }
}

/// Distinct indentation widths of a verse's non-blank lines, ascending, so
/// depth is an index.
pub(crate) fn indent_widths(text: &[u8]) -> Vec<usize> {
    let mut widths: Vec<usize> = Vec::new();
    for l in text.split(|&c| c == b'\n') {
        let w = l.len() - trim_start(l, b" \t").len();
        if l.len() == w {
            continue;
        }
        if !widths.contains(&w) {
            widths.push(w);
        }
    }
    widths.sort_unstable();
    widths
}

/// The author line's implicit attributes, as Asciidoctor names them
/// (`author`, `firstname`, …, with `_2`, `_3` suffixes past the first).
fn collect_authors(attr_buf: &mut Vec<KeyVal>, line: &[u8]) {
    let mut n = 0;
    for a in AuthorIter::new(line) {
        n += 1;
        push_author_attr(attr_buf, b"author", a.fullname, n);
        push_author_attr(attr_buf, b"firstname", a.firstname, n);
        if let Some(m) = a.middlename {
            push_author_attr(attr_buf, b"middlename", m, n);
        }
        if let Some(l) = a.lastname {
            push_author_attr(attr_buf, b"lastname", l, n);
        }
        if let Some(e) = a.email {
            push_author_attr(attr_buf, b"email", e, n);
        }
    }
}

fn push_author_attr(attr_buf: &mut Vec<KeyVal>, key: &[u8], value: &[u8], n: usize) {
    if n == 1 {
        attr_buf.push(kv(key, value));
        return;
    }
    let mut k = key.to_vec();
    k.extend_from_slice(format!("_{}", n).as_bytes());
    attr_buf.push(kv(&k, value));
}

fn collect_revision(attr_buf: &mut Vec<KeyVal>, line: &[u8]) {
    let mut t = trim(line, b" \t");
    let mut number: Option<&[u8]> = None;
    let mut date: Option<&[u8]> = None;
    let mut remark: Option<&[u8]> = None;
    if let Some(comma) = index_of_scalar(t, b',') {
        number = Some(trim(&t[..comma], b" \t"));
        t = trim(&t[comma + 1..], b" \t");
        if let Some(colon) = index_of_scalar(t, b':') {
            date = Some(trim(&t[..colon], b" \t"));
            remark = Some(trim(&t[colon + 1..], b" \t"));
        } else {
            date = Some(t);
        }
    } else if let Some(colon) = index_of_scalar(t, b':') {
        number = Some(trim(&t[..colon], b" \t"));
        remark = Some(trim(&t[colon + 1..], b" \t"));
    } else if !t.is_empty() && t[0] == b'v' {
        number = Some(t);
    } else {
        date = Some(t);
    }
    if let Some(nn) = number {
        let v = if nn.len() > 1 && nn[0] == b'v' && nn[1].is_ascii_digit() { &nn[1..] } else { nn };
        if !v.is_empty() {
            attr_buf.push(kv(b"revnumber", v));
        }
    }
    if let Some(d) = date {
        if !d.is_empty() {
            attr_buf.push(kv(b"revdate", d));
        }
    }
    if let Some(r) = remark {
        if !r.is_empty() {
            attr_buf.push(kv(b"revremark", r));
        }
    }
}

// ── inlines ──────────────────────────────────────────────────────────────

/// What the inline scanner needs beyond the text: the builder, and the
/// document-wide footnote counter that numbers `footnote:[]` macros.
pub struct InlineCtx<'b> {
    pub b: &'b mut Builder,
    pub footnotes: &'b mut u32,
    /// The `%hardbreaks` option: every newline is a hard break.
    pub hardbreaks: bool,
}

/// Scan `text` (a slice of the source starting at byte offset `base`) for
/// inline markup, returning the resulting run of nodes.
pub fn parse_inlines(ctx: &mut InlineCtx<'_>, text: &[u8], base: usize) -> Vec<NodeId> {
    let mut s = Scanner {
        ctx,
        text,
        base,
        i: 0,
        ids: Vec::new(),
        buf: Vec::new(),
        run_start: 0,
        run_end: 0,
        pending_attrs: None,
    };
    s.run();
    s.ids
}

fn mark_for_char(c: u8) -> Option<InlineMark> {
    match c {
        b'*' => Some(InlineMark::Strong),
        b'_' => Some(InlineMark::Emph),
        b'#' => Some(InlineMark::Mark),
        _ => None,
    }
}

const MONOSPACE_CHAR: u8 = b'`';

fn is_span_delimiter(c: u8) -> bool {
    mark_for_char(c).is_some() || c == MONOSPACE_CHAR
}

/// May `text[i]`, a candidate delimiter byte, OPEN a constrained span? Not
/// preceded by a word character, not followed by whitespace or end of text.
fn opens_constrained(text: &[u8], i: usize) -> bool {
    if i > 0 && is_word_byte(text[i - 1]) {
        return false;
    }
    if i + 1 >= text.len() {
        return false;
    }
    !is_space_byte(text[i + 1])
}

/// The index of the delimiter byte that CLOSES a constrained span opened at
/// `open_idx`: not preceded by whitespace, not followed by a word character.
/// The interior is at least one byte.
fn find_constrained_close(text: &[u8], delim: u8, open_idx: usize) -> Option<usize> {
    let mut j = open_idx + 2;
    while j < text.len() {
        if text[j] == delim {
            let before_space = is_space_byte(text[j - 1]);
            let after_word = j + 1 < text.len() && is_word_byte(text[j + 1]);
            if !before_space && !after_word {
                return Some(j);
            }
        }
        j += 1;
    }
    None
}

/// The index of the FIRST byte of the doubled delimiter that closes an
/// UNCONSTRAINED span opened at `open_idx`, non-greedy, non-empty interior.
fn find_unconstrained_close(text: &[u8], delim: u8, open_idx: usize) -> Option<usize> {
    let mut j = open_idx + 3;
    while j + 1 < text.len() {
        if text[j] == delim && text[j + 1] == delim {
            return Some(j);
        }
        j += 1;
    }
    None
}

/// Asciidoctor's intrinsic character-replacement attributes.
fn intrinsic(name: &[u8]) -> Option<&'static [u8]> {
    Some(match name {
        b"sp" => b" ",
        b"empty" => b"",
        b"blank" => b"",
        b"plus" => b"+",
        b"caret" => b"^",
        b"tilde" => b"~",
        b"startsb" => b"[",
        b"endsb" => b"]",
        b"vbar" => b"|",
        b"amp" => b"&",
        b"lt" => b"<",
        b"gt" => b">",
        b"backslash" => b"\\",
        b"apos" => b"'",
        b"quot" => b"\"",
        b"deg" => "\u{b0}".as_bytes(),
        b"two-colons" => b"::",
        b"two-semicolons" => b";;",
        b"cpp" => b"C++",
        b"zwsp" => "\u{200b}".as_bytes(),
        b"wj" => "\u{2060}".as_bytes(),
        b"lsquo" => "\u{2018}".as_bytes(),
        b"rsquo" => "\u{2019}".as_bytes(),
        b"ldquo" => "\u{201c}".as_bytes(),
        b"rdquo" => "\u{201d}".as_bytes(),
        b"brvbar" => "\u{a6}".as_bytes(),
        b"pp" => b"++",
        b"asterisk" => b"*",
        _ => return None,
    })
}

struct Scanner<'c, 'b, 't> {
    ctx: &'c mut InlineCtx<'b>,
    text: &'t [u8],
    base: usize,
    i: usize,
    ids: Vec<NodeId>,
    /// The plain-text run being accumulated, and the source extent it covers.
    buf: Vec<u8>,
    run_start: usize,
    run_end: usize,
    /// The interior of a `[…]` attribute list parsed just before a span
    /// opener, applied to the span it precedes.
    pending_attrs: Option<&'t [u8]>,
}

impl<'c, 'b, 't> Scanner<'c, 'b, 't> {
    fn plain(&mut self, from: usize, to: usize) {
        if from >= to {
            return;
        }
        let t = self.text;
        self.literal(&t[from..to], from, to);
    }

    /// Append `bytes` to the text run as the reading of source `[from, to)`.
    fn literal(&mut self, bytes: &[u8], from: usize, to: usize) {
        if self.buf.is_empty() {
            self.run_start = self.base + from;
        }
        self.buf.extend_from_slice(bytes);
        self.run_end = self.base + to;
    }

    fn flush(&mut self) {
        if self.buf.is_empty() {
            return;
        }
        let id = self.ctx.b.add_leaf(Kind::Str(std::mem::take(&mut self.buf)));
        self.ctx.b.set_span(id, Span::new(self.run_start, self.run_end));
        self.ids.push(id);
    }

    fn emit(&mut self, id: NodeId) {
        self.flush();
        self.ids.push(id);
    }

    fn span(&self, from: usize, to: usize) -> Span {
        Span::new(self.base + from, self.base + to)
    }

    fn leaf(&mut self, kind: Kind, from: usize, to: usize) -> NodeId {
        let id = self.ctx.b.add_leaf(kind);
        let sp = self.span(from, to);
        self.ctx.b.set_span(id, sp);
        id
    }

    fn container(&mut self, kind: Kind, kids: &[NodeId], from: usize, to: usize) -> NodeId {
        let id = self.ctx.b.add_container(kind, kids);
        let sp = self.span(from, to);
        self.ctx.b.set_span(id, sp);
        id
    }

    /// Parse `[from, to)` of this text as a nested inline run.
    fn sub(&mut self, from: usize, to: usize) -> Vec<NodeId> {
        let t = self.text;
        let base = self.base;
        parse_inlines(self.ctx, &t[from..to], base + from)
    }

    fn str_at(&mut self, from: usize, to: usize) -> NodeId {
        let t = self.text;
        self.leaf(Kind::Str(t[from..to].to_vec()), from, to)
    }

    fn set_content_span(&mut self, id: NodeId, from: usize, to: usize) {
        let sp = self.span(from, to);
        self.ctx.b.set_content_span(id, sp);
    }

    fn set_directive(&mut self, id: NodeId) {
        self.ctx.b.set_spelling(id, Spelling::ContainerOrigin(ContainerOrigin::Directive));
    }

    fn run(&mut self) {
        while self.i < self.text.len() {
            let c = self.text[self.i];
            let handled = match c {
                b'\\' => self.try_escape(),
                b'+' => self.try_pass(),
                b'`' | b'*' | b'_' | b'#' => self.try_span(),
                b'^' | b'~' => self.try_sup_sub(),
                b'"' | b'\'' => self.try_curved(),
                b'<' => self.try_angle(),
                b'[' => self.try_bracket(),
                b'{' => self.try_attr_ref(),
                b'&' => self.try_charref(),
                b'(' | b'-' | b'=' | b'.' => self.try_replacement(),
                b' ' => self.try_hard_break(),
                b'\n' => self.try_newline(),
                _ => {
                    if c.is_ascii_alphanumeric() {
                        self.try_word()
                    } else {
                        false
                    }
                }
            };
            if !handled {
                self.plain(self.i, self.i + 1);
                self.i += 1;
            }
        }
        self.flush();
    }

    // ── escapes, passthroughs, replacements ───────────────────────────────

    /// `\` before a byte that would otherwise open a construct reads as that
    /// byte; `\` before a macro or URL scheme suppresses the macro.
    fn try_escape(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        if i + 1 >= t.len() {
            return false;
        }
        let n = t[i + 1];
        if b"\\*_`#^~+{}[]<>&|(-=.'\"/:".contains(&n) {
            self.literal(&t[i + 1..i + 2], i, i + 2);
            self.i = i + 2;
            return true;
        }
        if n.is_ascii_alphabetic() {
            let mut j = i + 1;
            while j < t.len() && (t[j].is_ascii_alphanumeric() || t[j] == b'-') {
                j += 1;
            }
            if j < t.len() && t[j] == b':' {
                self.literal(&t[i + 1..j + 1], i, j + 1);
                self.i = j + 1;
                return true;
            }
        }
        false
    }

    fn try_pass(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        if t[i..].starts_with(b"+++") {
            if let Some(close) = index_of_pos(t, i + 3, b"+++") {
                if close > i + 3 {
                    let id = self.leaf(
                        Kind::RawInline { format: b"html".to_vec(), text: t[i + 3..close].to_vec() },
                        i,
                        close + 3,
                    );
                    self.set_content_span(id, i + 3, close);
                    self.emit(id);
                    self.i = close + 3;
                    return true;
                }
            }
        }
        if t[i..].starts_with(b"++") {
            if let Some(close) = find_unconstrained_close(t, b'+', i) {
                let id = self.leaf(Kind::Str(t[i + 2..close].to_vec()), i, close + 2);
                self.emit(id);
                self.i = close + 2;
                return true;
            }
        }
        if !opens_constrained(t, i) {
            return false;
        }
        let Some(close) = find_constrained_close(t, b'+', i) else { return false };
        let id = self.leaf(Kind::Str(t[i + 1..close].to_vec()), i, close + 1);
        self.emit(id);
        self.i = close + 1;
        true
    }

    fn try_replacement(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        let rest = &t[i..];
        let reps: [(&[u8], &str); 5] =
            [(b"(C)", "\u{a9}"), (b"(R)", "\u{ae}"), (b"(TM)", "\u{2122}"), (b"->", "\u{2192}"), (b"=>", "\u{21d2}")];
        for (from, to) in reps {
            if rest.starts_with(from) {
                self.literal(to.as_bytes(), i, i + from.len());
                self.i = i + from.len();
                return true;
            }
        }
        if rest.starts_with(b"--") && !(rest.len() > 2 && rest[2] == b'-') && !(i > 0 && t[i - 1] == b'-') {
            let before_ok = i == 0 || is_word_byte(t[i - 1]) || t[i - 1] == b' ';
            let after_ok = i + 2 >= t.len() || is_word_byte(t[i + 2]) || t[i + 2] == b' ' || t[i + 2] == b'\n';
            if before_ok && after_ok {
                let id = self.leaf(Kind::SmartPunctuation(SmartPunctuationKind::EmDash), i, i + 2);
                self.emit(id);
                self.i = i + 2;
                return true;
            }
        }
        if rest.starts_with(b"...") && !(rest.len() > 3 && rest[3] == b'.') {
            let id = self.leaf(Kind::SmartPunctuation(SmartPunctuationKind::Ellipses), i, i + 3);
            self.emit(id);
            self.i = i + 3;
            return true;
        }
        false
    }

    /// `&name;`, `&#NNN;`, `&#xHH;` — its own `str` node holding the decoded
    /// character, so the codec can tell it from surrounding text.
    fn try_charref(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        let Some(semi) = index_of_scalar_pos(t, i + 1, b';') else { return false };
        let Some(value) = decode_charref(&t[i..semi + 1]) else { return false };
        let id = self.leaf(Kind::Str(value), i, semi + 1);
        self.emit(id);
        self.i = semi + 1;
        true
    }

    /// `{name}` — an attribute reference, or one of the intrinsic character
    /// attributes, which are text.
    fn try_attr_ref(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        let Some(close) = index_of_scalar_pos(t, i + 1, b'}') else { return false };
        let name = &t[i + 1..close];
        if name.is_empty() {
            return false;
        }
        for (k, &c) in name.iter().enumerate() {
            if !(c.is_ascii_alphanumeric() || c == b'_' || (k > 0 && c == b'-')) {
                return false;
            }
        }
        if name == b"nbsp" {
            let id = self.leaf(Kind::NonBreakingSpace, i, close + 1);
            self.emit(id);
        } else if let Some(rep) = intrinsic(name) {
            self.literal(rep, i, close + 1);
        } else {
            let id = self.leaf(
                Kind::TextLeaf { kind: TextLeafKind::SubstitutionReference, text: name.to_vec() },
                i,
                close + 1,
            );
            self.set_content_span(id, i + 1, close);
            self.emit(id);
        }
        self.i = close + 1;
        true
    }

    fn try_hard_break(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        if i + 1 >= t.len() || t[i + 1] != b'+' {
            return false;
        }
        if i + 2 == t.len() {
            let id = self.leaf(Kind::HardBreak, i, i + 2);
            self.emit(id);
            self.i = i + 2;
            return true;
        }
        if t[i + 2] == b'\n' {
            let id = self.leaf(Kind::HardBreak, i, i + 3);
            self.emit(id);
            self.i = i + 3;
            return true;
        }
        false
    }

    fn try_newline(&mut self) -> bool {
        if !self.ctx.hardbreaks {
            return false;
        }
        let id = self.leaf(Kind::HardBreak, self.i, self.i + 1);
        self.emit(id);
        self.i += 1;
        true
    }

    // ── spans ─────────────────────────────────────────────────────────────

    /// `*strong*`, `_emphasis_`, `#mark#`, `` `mono` `` in both forms.
    /// Unconstrained is tried FIRST, as asciidoctor does; a doubled opener
    /// with no doubled close falls through to the constrained scan.
    fn try_span(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        let delim = t[i];
        let doubled = i + 1 < t.len() && t[i + 1] == delim;
        if doubled {
            if let Some(close) = find_unconstrained_close(t, delim, i) {
                self.emit_span(delim, i + 2, close, i, close + 2);
                self.i = close + 2;
                return true;
            }
        }
        if !opens_constrained(t, i) {
            return false;
        }
        let Some(close) = find_constrained_close(t, delim, i) else { return false };
        self.emit_span(delim, i + 1, close, i, close + 1);
        self.i = close + 1;
        true
    }

    /// Build the one node a span delimiter produces over `[ifrom, ito)`, with
    /// any pending `[.role]` attributes applied.
    fn emit_span(&mut self, delim: u8, ifrom: usize, ito: usize, from: usize, to: usize) {
        let attrs = self.pending_attrs.take();
        let id;
        if delim == MONOSPACE_CHAR {
            let t = self.text;
            id = self.leaf(Kind::TextLeaf { kind: TextLeafKind::Verbatim, text: t[ifrom..ito].to_vec() }, from, to);
            self.set_content_span(id, ifrom, ito);
        } else {
            let kids = self.sub(ifrom, ito);
            // A role on a `#` span makes it a plain styled span.
            let kind = if delim == b'#' && attrs.is_some() {
                Kind::Container(Container::with_form(b"", Form::InlineText))
            } else {
                Kind::InlineMark(mark_for_char(delim).unwrap())
            };
            let is_container = matches!(kind, Kind::Container(_));
            id = self.container(kind, &kids, from, to);
            if is_container {
                self.set_directive(id);
            }
            self.set_content_span(id, ifrom, ito);
        }
        if let Some(a) = attrs {
            self.apply_inline_attrs(id, a);
        }
        self.emit(id);
    }

    /// The `[…]` before a span: `[.role]`, `[#id.role]`, `[role]`,
    /// `[role=x]`, `[id=x]`.
    fn apply_inline_attrs(&mut self, id: NodeId, interior: &[u8]) {
        let mut entries: Vec<KeyVal> = Vec::new();
        let mut class: Vec<u8> = Vec::new();
        let mut anchor: Option<&[u8]> = None;
        for e in AttrIter::new(interior) {
            if let Some(k) = e.key {
                if k == b"role" {
                    if !class.is_empty() {
                        class.push(b' ');
                    }
                    class.extend_from_slice(e.value);
                } else if k == b"id" {
                    anchor = Some(e.value);
                } else {
                    entries.push(kv(k, e.value));
                }
            } else if e.index == 1 {
                for p in ShorthandIter::new(e.value) {
                    match p.kind {
                        ShorthandKind::Id => anchor = Some(p.text),
                        ShorthandKind::Style | ShorthandKind::Role => {
                            if !class.is_empty() {
                                class.push(b' ');
                            }
                            class.extend_from_slice(p.text);
                        }
                        ShorthandKind::Option => {}
                    }
                }
            }
        }
        let mut all: Vec<KeyVal> = Vec::new();
        if let Some(a) = anchor {
            all.push(kv(b"id", a));
        }
        if !class.is_empty() {
            all.push(kv(b"class", &class));
        }
        all.extend(entries);
        if !all.is_empty() {
            self.ctx.b.set_attrs(id, Attrs { entries: all });
        }
    }

    /// `^sup^` and `~sub~`: unconstrained, single delimiter, no whitespace
    /// inside.
    fn try_sup_sub(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        let delim = t[i];
        let mut j = i + 1;
        while j < t.len() && t[j] != delim {
            if is_space_byte(t[j]) {
                return false;
            }
            j += 1;
        }
        if j >= t.len() || j == i + 1 {
            return false;
        }
        let attrs = self.pending_attrs.take();
        let kids = self.sub(i + 1, j);
        let mark = if delim == b'^' { InlineMark::Superscript } else { InlineMark::Subscript };
        let id = self.container(Kind::InlineMark(mark), &kids, i, j + 1);
        self.set_content_span(id, i + 1, j);
        if let Some(a) = attrs {
            self.apply_inline_attrs(id, a);
        }
        self.emit(id);
        self.i = j + 1;
        true
    }

    /// Asciidoctor's curved quotes: `"`text`"` and `'`text`'`.
    fn try_curved(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        if i + 1 >= t.len() || t[i + 1] != b'`' {
            return false;
        }
        let closer: &[u8] = if t[i] == b'"' { b"`\"" } else { b"`'" };
        let Some(close) = index_of_pos(t, i + 2, closer) else { return false };
        if close == i + 2 {
            return false;
        }
        let kids = self.sub(i + 2, close);
        let mark = if t[i] == b'"' { InlineMark::DoubleQuoted } else { InlineMark::SingleQuoted };
        let id = self.container(Kind::InlineMark(mark), &kids, i, close + 2);
        self.set_content_span(id, i + 2, close);
        self.emit(id);
        self.i = close + 2;
        true
    }

    // ── references ────────────────────────────────────────────────────────

    fn try_angle(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        if t[i..].starts_with(b"<<") {
            let Some(close) = index_of_pos(t, i + 2, b">>") else { return false };
            let interior = &t[i + 2..close];
            if interior.is_empty() || interior[0] == b'<' {
                return false;
            }
            let comma = index_of_scalar(interior, b',');
            let target = trim(
                match comma {
                    Some(c) => &interior[..c],
                    None => interior,
                },
                b" \t",
            );
            if target.is_empty() || index_of_any(target, b" \t\n").is_some() {
                return false;
            }
            let text_from = comma.map(|c| i + 2 + c + 1);
            self.emit_xref(target, text_from, close, i, close + 2, i + 2, i + 2 + target.len());
            self.i = close + 2;
            return true;
        }
        if t[i..].starts_with(b"<-") {
            self.literal("\u{2190}".as_bytes(), i, i + 2);
            self.i = i + 2;
            return true;
        }
        if t[i..].starts_with(b"<=") {
            self.literal("\u{21d0}".as_bytes(), i, i + 2);
            self.i = i + 2;
            return true;
        }
        // `<https://…>` — the angle autolink.
        let Some(close) = index_of_scalar_pos(t, i + 1, b'>') else { return false };
        let interior = &t[i + 1..close];
        if !is_url_start(interior) || index_of_any(interior, b" \t\n<").is_some() {
            return false;
        }
        let id = self.leaf(Kind::TextLeaf { kind: TextLeafKind::Url, text: interior.to_vec() }, i, close + 1);
        self.set_content_span(id, i + 1, close);
        self.emit(id);
        self.i = close + 1;
        true
    }

    /// A cross reference to `target`, with the visible text at
    /// `[text_from, text_to)` or — when `text_from` is `None` — the target
    /// itself, whose bytes sit at `[tfrom, tto)`.
    #[allow(clippy::too_many_arguments)]
    fn emit_xref(
        &mut self,
        target: &[u8],
        text_from: Option<usize>,
        text_to: usize,
        from: usize,
        to: usize,
        tfrom: usize,
        tto: usize,
    ) {
        let dest = if index_of_scalar(target, b'#').is_some() {
            target.to_vec()
        } else {
            let mut d = b"#".to_vec();
            d.extend_from_slice(target);
            d
        };
        let kids = match text_from {
            Some(tf) => {
                let trimmed_from = tf + index_of_none(&self.text[tf..text_to], b" \t").unwrap_or(0);
                self.sub(trimmed_from, text_to)
            }
            None => vec![self.str_at(tfrom, tto)],
        };
        let id = self.container(Kind::Link(Link { destination: Some(dest), reference: None }), &kids, from, to);
        if let Some(tf) = text_from {
            self.set_content_span(id, tf, text_to);
        }
        self.emit(id);
    }

    fn try_bracket(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        if t[i..].starts_with(b"[[") {
            let Some(close) = index_of_pos(t, i + 2, b"]]") else { return false };
            let interior = &t[i + 2..close];
            if interior.is_empty() || index_of_any(interior, b" \t\n[").is_some() {
                return false;
            }
            let id_text = match index_of_scalar(interior, b',') {
                Some(c) => &interior[..c],
                None => interior,
            };
            if id_text.is_empty() {
                return false;
            }
            let id = self.container(Kind::Container(Container::with_form(b"", Form::InlineText)), &[], i, close + 2);
            self.set_directive(id);
            self.ctx.b.set_attrs(id, Attrs { entries: vec![kv(b"id", id_text)] });
            self.emit(id);
            self.i = close + 2;
            return true;
        }
        // `[.role]` directly before a span opener.
        let Some(close) = index_of_scalar_pos(t, i + 1, b']') else { return false };
        let interior = &t[i + 1..close];
        if interior.is_empty() || index_of_any(interior, b"\n[").is_some() {
            return false;
        }
        if close + 1 >= t.len() {
            return false;
        }
        let opener = t[close + 1];
        if !(is_span_delimiter(opener) || opener == b'^' || opener == b'~') {
            return false;
        }
        // The list must be roles/ids only, not arbitrary text.
        for e in AttrIter::new(interior) {
            if let Some(k) = e.key {
                if k != b"role" && k != b"id" {
                    return false;
                }
            } else if e.index == 1 {
                if index_of_any(e.value, b" \t").is_some() {
                    return false;
                }
            } else {
                return false;
            }
        }
        self.pending_attrs = Some(interior);
        self.i = close + 1;
        let ok = if is_span_delimiter(opener) { self.try_span() } else { self.try_sup_sub() };
        if ok {
            // The attribute list is part of the span it styles: the node's
            // extent grows to cover it, and its own range is recorded.
            let id = *self.ids.last().unwrap();
            self.ctx.b.spans[id as usize].start = self.base + i;
            let sp = self.span(i, close + 1);
            self.ctx.b.set_attrs_span(id, sp);
            return true;
        }
        self.pending_attrs = None;
        self.i = i;
        false
    }

    fn try_word(&mut self) -> bool {
        let i = self.i;
        let t = self.text;
        let mut j = i;
        while j < t.len() && (t[j].is_ascii_alphanumeric() || t[j] == b'-' || t[j] == b'_') {
            j += 1;
        }
        let name = &t[i..j];
        let at_boundary = i == 0 || !is_word_byte(t[i - 1]);
        if j < t.len() && t[j] == b':' {
            // A URL wants a word boundary before it; a macro does not.
            if at_boundary && is_url_start(&t[i..]) {
                return self.try_url(i);
            }
            if self.try_macro(name, i, j + 1) {
                return true;
            }
        }
        if !at_boundary {
            return false;
        }
        self.try_email(i)
    }

    /// A bare or bracketed URL starting at `start`.
    fn try_url(&mut self, start: usize) -> bool {
        let t = self.text;
        let mut k = start;
        while k < t.len() && !is_space_byte(t[k]) && !b"[]<".contains(&t[k]) {
            k += 1;
        }
        if k < t.len() && t[k] == b'[' {
            let Some(close) = find_bracket_close(t, k) else { return false };
            self.emit_link(&t[start..k], k + 1, close, start, close + 1, start, k);
            self.i = close + 1;
            return true;
        }
        // Trailing punctuation belongs to the sentence, not the URL.
        while k > start && b",.?!;:)\"'".contains(&t[k - 1]) {
            k -= 1;
        }
        let url = &t[start..k];
        if url.ends_with(b"://") {
            return false;
        }
        let id = self.leaf(Kind::TextLeaf { kind: TextLeafKind::Url, text: url.to_vec() }, start, k);
        self.emit(id);
        self.i = k;
        true
    }

    /// A `link` whose text is `[tfrom, tto)` (the bracket interior) or, when
    /// that is empty, the destination's own bytes at `[dfrom, dto)`.
    #[allow(clippy::too_many_arguments)]
    fn emit_link(&mut self, dest: &[u8], tfrom: usize, tto: usize, from: usize, to: usize, dfrom: usize, dto: usize) {
        let t = self.text;
        let mut text_to = tto;
        let mut interior = &t[tfrom..tto];
        let mut window: Option<&[u8]> = None;
        let mut role: Option<&[u8]> = None;
        // `[text,key=value]`: a trailing named-attribute list; `[text^]`: a new window.
        if let Some(comma) = index_of_scalar(interior, b',') {
            let rest = trim(&interior[comma + 1..], b" \t");
            if looks_like_attr_list(rest) {
                for e in AttrIter::new(rest) {
                    if let Some(k) = e.key {
                        if k == b"window" {
                            window = Some(e.value);
                        } else if k == b"role" {
                            role = Some(e.value);
                        }
                    }
                }
                text_to = tfrom + comma;
                interior = &t[tfrom..text_to];
            }
        }
        if interior.ends_with(b"^") {
            window = Some(b"_blank");
            text_to -= 1;
            interior = &t[tfrom..text_to];
        }
        let has_text = !trim(interior, b" \t").is_empty();
        let kids = if has_text { self.sub(tfrom, text_to) } else { vec![self.str_at(dfrom, dto)] };
        let id = self.container(Kind::Link(Link { destination: Some(dest.to_vec()), reference: None }), &kids, from, to);
        if has_text {
            self.set_content_span(id, tfrom, text_to);
        }
        let mut attrs = Vec::new();
        if let Some(r) = role {
            attrs.push(kv(b"class", r));
        }
        if let Some(w) = window {
            attrs.push(kv(b"window", w));
        }
        if !attrs.is_empty() {
            self.ctx.b.set_attrs(id, Attrs { entries: attrs });
        }
        self.emit(id);
    }

    fn try_macro(&mut self, name: &[u8], start: usize, target_from: usize) -> bool {
        let t = self.text;
        let mut k = target_from;
        while k < t.len() && !is_space_byte(t[k]) && t[k] != b'[' && t[k] != b']' {
            k += 1;
        }
        if k >= t.len() || t[k] != b'[' {
            return false;
        }
        let target = &t[target_from..k];
        let Some(close) = find_bracket_close(t, k) else { return false };
        let ifrom = k + 1;
        let ito = close;
        let interior = &t[ifrom..ito];
        let to = close + 1;

        match name {
            b"link" => {
                if target.is_empty() {
                    return false;
                }
                self.emit_link(target, ifrom, ito, start, to, target_from, k);
            }
            b"mailto" => {
                if target.is_empty() {
                    return false;
                }
                let mut dest = b"mailto:".to_vec();
                dest.extend_from_slice(target);
                // Only the first positional is the text; subject and body are dropped.
                let mut text_to = ito;
                if let Some(c) = index_of_scalar(interior, b',') {
                    text_to = ifrom + c;
                }
                self.emit_link(&dest, ifrom, text_to, start, to, target_from, k);
            }
            b"xref" => {
                if target.is_empty() {
                    return false;
                }
                self.emit_xref(target, if !interior.is_empty() { Some(ifrom) } else { None }, ito, start, to, target_from, k);
            }
            b"image" => {
                if target.is_empty() {
                    return false;
                }
                self.emit_image(target, interior, ifrom, start, to);
            }
            b"footnote" => self.emit_footnote(target, ifrom, ito, start, to),
            b"anchor" => {
                if target.is_empty() {
                    return false;
                }
                let id = self.container(Kind::Container(Container::with_form(b"", Form::InlineText)), &[], start, to);
                self.set_directive(id);
                self.ctx.b.set_attrs(id, Attrs { entries: vec![kv(b"id", target)] });
                self.emit(id);
            }
            b"pass" => {
                let id = self.leaf(Kind::RawInline { format: b"html".to_vec(), text: interior.to_vec() }, start, to);
                if ito > ifrom {
                    self.set_content_span(id, ifrom, ito);
                }
                self.emit(id);
            }
            b"stem" | b"latexmath" | b"asciimath" => {
                let id =
                    self.leaf(Kind::TextLeaf { kind: TextLeafKind::InlineMath, text: interior.to_vec() }, start, to);
                if ito > ifrom {
                    self.set_content_span(id, ifrom, ito);
                }
                self.emit(id);
            }
            b"kbd" | b"btn" => {
                if !target.is_empty() || interior.is_empty() {
                    return false;
                }
                let label = self.str_at(ifrom, ito);
                let kbd = name == b"kbd";
                let id = self.container(
                    Kind::Container(Container::with_form(if kbd { b"kbd" } else { b"b" }, Form::InlineText)),
                    &[label],
                    start,
                    to,
                );
                self.set_directive(id);
                self.set_content_span(id, ifrom, ito);
                if !kbd {
                    self.ctx.b.set_attrs(id, Attrs { entries: vec![kv(b"class", b"button")] });
                }
                self.emit(id);
            }
            _ => return false,
        }
        self.i = to;
        true
    }

    fn emit_image(&mut self, target: &[u8], interior: &[u8], ifrom: usize, from: usize, to: usize) {
        let mut alt: Option<&[u8]> = None;
        let mut width: Option<&[u8]> = None;
        let mut height: Option<&[u8]> = None;
        let mut title: Option<&[u8]> = None;
        for e in AttrIter::new(interior) {
            if let Some(k) = e.key {
                if k == b"alt" {
                    alt = Some(e.value);
                } else if k == b"width" {
                    width = Some(e.value);
                } else if k == b"height" {
                    height = Some(e.value);
                } else if k == b"title" {
                    title = Some(e.value);
                }
            } else {
                match e.index {
                    1 => alt = Some(e.value),
                    2 => width = Some(e.value),
                    3 => height = Some(e.value),
                    _ => {}
                }
            }
        }
        let mut kids = Vec::new();
        if let Some(a) = alt {
            if !a.is_empty() {
                let at = ifrom + index_of(interior, a).unwrap_or(0);
                kids.push(self.str_at(at, at + a.len()));
            }
        }
        let id = self.container(Kind::Image(Link { destination: Some(target.to_vec()), reference: None }), &kids, from, to);
        let mut attrs = Vec::new();
        if let Some(w) = width {
            attrs.push(kv(b"width", w));
        }
        if let Some(h) = height {
            attrs.push(kv(b"height", h));
        }
        if let Some(tt) = title {
            attrs.push(kv(b"title", tt));
        }
        if !attrs.is_empty() {
            self.ctx.b.set_attrs(id, Attrs { entries: attrs });
        }
        self.emit(id);
    }

    /// `footnote:[text]` / `footnote:id[text]` / `footnote:id[]`: a
    /// `footnote_reference` leaf at the use, and — when there is text — a
    /// detached `footnote` definition holding it, labelled by the id or by the
    /// document-order number.
    fn emit_footnote(&mut self, target: &[u8], ifrom: usize, ito: usize, from: usize, to: usize) {
        let label: Vec<u8> = if target.is_empty() {
            *self.ctx.footnotes += 1;
            self.ctx.footnotes.to_string().into_bytes()
        } else {
            target.to_vec()
        };
        if ito > ifrom {
            let kids = self.sub(ifrom, ito);
            let para = self.container(Kind::Para, &kids, ifrom, ito);
            let def = self.container(Kind::Footnote { label: label.clone() }, &[para], ifrom, ito);
            self.set_content_span(def, ifrom, ito);
        }
        let r = self.leaf(Kind::TextLeaf { kind: TextLeafKind::FootnoteReference, text: label }, from, to);
        if ito > ifrom {
            self.set_content_span(r, ifrom, ito);
        }
        self.emit(r);
    }

    fn try_email(&mut self, start: usize) -> bool {
        let t = self.text;
        let mut k = start;
        while k < t.len() && (t[k].is_ascii_alphanumeric() || b"._%+-".contains(&t[k])) {
            k += 1;
        }
        if k == start || k >= t.len() || t[k] != b'@' {
            return false;
        }
        k += 1;
        let dom_start = k;
        let mut last_dot: Option<usize> = None;
        while k < t.len() && (t[k].is_ascii_alphanumeric() || t[k] == b'.' || t[k] == b'-') {
            if t[k] == b'.' {
                last_dot = Some(k);
            }
            k += 1;
        }
        // Trailing dots belong to the sentence.
        while k > dom_start && t[k - 1] == b'.' {
            k -= 1;
        }
        let Some(ld) = last_dot else { return false };
        if ld <= dom_start || ld + 2 > k {
            return false;
        }
        if k - ld - 1 < 2 {
            return false;
        }
        if !t[ld + 1..k].iter().all(|c| c.is_ascii_alphabetic()) {
            return false;
        }
        if k < t.len() && is_word_byte(t[k]) {
            return false;
        }
        let id = self.leaf(Kind::TextLeaf { kind: TextLeafKind::Email, text: t[start..k].to_vec() }, start, k);
        self.emit(id);
        self.i = k;
        true
    }
}

/// Decode a character reference spelled `&name;`, `&#NNN;` or `&#xHH;`
/// (delimiters included) into the character it names, or `None` when `r`
/// is not one.
pub fn decode_charref(r: &[u8]) -> Option<Vec<u8>> {
    if r.len() < 3 || r[0] != b'&' || r[r.len() - 1] != b';' {
        return None;
    }
    let body = &r[1..r.len() - 1];
    if body.is_empty() || body.len() > 32 {
        return None;
    }
    if body[0] == b'#' {
        let max = (1u64 << 21) - 1;
        let num = if body.len() > 1 && (body[1] == b'x' || body[1] == b'X') {
            zig_parse_uint(&body[2..], 16, max)?
        } else {
            zig_parse_uint(&body[1..], 10, max)?
        } as u32;
        let cp = if num == 0 { 0xfffd } else { num };
        // `std.unicode.utf8Encode`: no surrogate halves, nothing past U+10FFFF.
        let ch = char::from_u32(cp)?;
        let mut buf = [0u8; 4];
        return Some(ch.encode_utf8(&mut buf).as_bytes().to_vec());
    }
    if !body.iter().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    entities::lookup(body).map(|v| v.to_vec())
}

fn is_url_start(s: &[u8]) -> bool {
    [&b"https://"[..], b"http://", b"ftp://", b"irc://", b"file://"].iter().any(|scheme| s.starts_with(scheme))
}

/// Does `s` (the part of a link's bracket after its first comma) read as an
/// attribute list — its first entry a `key=value` pair?
fn looks_like_attr_list(s: &[u8]) -> bool {
    match AttrIter::new(s).next() {
        Some(first) => first.key.is_some(),
        None => false,
    }
}

/// The index of the `]` matching the `[` at `open`, honouring `\]` and
/// nested brackets, or `None`.
fn find_bracket_close(t: &[u8], open: usize) -> Option<usize> {
    let mut depth: usize = 0;
    let mut k = open;
    while k < t.len() {
        let c = t[k];
        if c == b'\\' && k + 1 < t.len() {
            k += 2;
            continue;
        }
        if c == b'[' {
            depth += 1;
        }
        if c == b']' {
            depth = depth.wrapping_sub(1);
            if depth == 0 {
                return Some(k);
            }
        }
        k += 1;
    }
    None
}

fn compute_lines(source: &[u8]) -> Vec<LineInfo> {
    let mut list = Vec::new();
    let mut start = 0;
    for (i, &c) in source.iter().enumerate() {
        if c == b'\n' {
            list.push(LineInfo { start, end: i });
            start = i + 1;
        }
    }
    // Only a source that does NOT end in a newline has a final partial line.
    if start < source.len() {
        list.push(LineInfo { start, end: source.len() });
    }
    list
}

/// Map an offset in a stripped scratch source back to the real source,
/// through the real offset of each scratch line.
fn map_offset(offsets: &[usize], scratch: &[u8], off: usize) -> usize {
    let mut line = 0;
    let mut line_start = 0;
    let mut k = 0;
    while k < off && k < scratch.len() {
        if scratch[k] == b'\n' {
            line += 1;
            line_start = k + 1;
        }
        k += 1;
    }
    if line >= offsets.len() {
        return offsets[offsets.len() - 1] + (off - line_start);
    }
    offsets[line] + (off - line_start)
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// The corpora (`conformance.rs`) judge every shape the ASG schema has a name
// for. What is tested here is the rest: the constructs draft-01 does not
// model, the tree-side facts the ASG comparison cannot see, and the parser's
// own edge cases.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Ast;
    use crate::asg;

    fn first_block(doc: &Document) -> NodeId {
        doc.ast.nodes[doc.ast.root as usize].first_child.unwrap()
    }

    #[test]
    fn a_macros_unnamed_first_positional_keeps_its_number() {
        let doc = parse(b"toc::[foo]\n\naudio::a.mp3[bar,baz]\n");
        let toc = first_block(&doc);
        assert_eq!(doc.ast.attrs_of(toc).get(b"$1"), Some(&b"foo"[..]));
        let audio = doc.ast.nodes[toc as usize].next_sibling.unwrap();
        assert_eq!(doc.ast.attrs_of(audio).get(b"$1"), Some(&b"bar"[..]));
        assert_eq!(doc.ast.attrs_of(audio).get(b"$2"), Some(&b"baz"[..]));
    }

    #[test]
    fn an_author_line_of_more_than_four_names_takes_its_last_word() {
        let a = AuthorIter::new(b"A B C D E F <a@b.c>").next().unwrap();
        assert_eq!(a.fullname, b"A B C D E F");
        assert_eq!(a.firstname, b"A");
        assert_eq!(a.middlename, None);
        assert_eq!(a.lastname, Some(&b"F"[..]));
        assert_eq!(a.email, Some(&b"a@b.c"[..]));
    }

    fn nth(doc: &Document, parent: NodeId, n: usize) -> NodeId {
        let mut id = doc.ast.nodes[parent as usize].first_child.unwrap();
        for _ in 0..n {
            id = doc.ast.nodes[id as usize].next_sibling.unwrap();
        }
        id
    }

    fn next(doc: &Document, id: NodeId) -> NodeId {
        doc.ast.nodes[id as usize].next_sibling.unwrap()
    }

    fn first_child(doc: &Document, id: NodeId) -> NodeId {
        doc.ast.nodes[id as usize].first_child.unwrap()
    }

    fn kind(doc: &Document, id: NodeId) -> &Kind {
        &doc.ast.nodes[id as usize].kind
    }

    fn str_of(doc: &Document, id: NodeId) -> &str {
        match kind(doc, id) {
            Kind::Str(s) => std::str::from_utf8(s).unwrap(),
            k => panic!("not a str: {:?}", k),
        }
    }

    fn text(doc: &Document, id: NodeId) -> &str {
        std::str::from_utf8(doc.text(id)).unwrap()
    }

    fn attr<'d>(ast: &'d Ast, id: NodeId, key: &str) -> Option<&'d str> {
        ast.attrs_of(id).get(key.as_bytes()).map(|v| std::str::from_utf8(v).unwrap())
    }

    fn container(doc: &Document, id: NodeId) -> &Container {
        match kind(doc, id) {
            Kind::Container(c) => c,
            k => panic!("not a container: {:?}", k),
        }
    }

    fn text_leaf(doc: &Document, id: NodeId) -> (TextLeafKind, &[u8]) {
        match kind(doc, id) {
            Kind::TextLeaf { kind, text } => (*kind, text),
            k => panic!("not a text leaf: {:?}", k),
        }
    }

    #[test]
    fn a_single_paragraph() {
        let doc = parse(b"A paragraph that consists of a single line.\n");
        let para = first_block(&doc);
        assert_eq!(*kind(&doc, para), Kind::Para);
        assert_eq!(str_of(&doc, first_child(&doc, para)), "A paragraph that consists of a single line.");
    }

    #[test]
    fn a_document_title_becomes_the_top_level_heading_attribute_entries_attach_to_the_document() {
        let doc = parse(b"= Document Title\n:icons: font\n:toc:\n");
        let marker = first_block(&doc);
        assert_eq!(container(&doc, marker).name, b"document-attributes");
        assert_eq!(attr(&doc.ast, marker, "icons"), Some("font"));
        assert_eq!(attr(&doc.ast, marker, "toc"), Some(""));
        let heading = next(&doc, marker);
        // 1, not the ASG's 0: twig's shared `heading.level` is 1-based.
        assert_eq!(*kind(&doc, heading), Kind::Heading { level: 1 });
        assert_eq!(doc.marker_text(heading), Some(&b"= "[..]));
    }

    #[test]
    fn the_author_and_revision_lines_become_the_documents_implicit_attributes() {
        let doc = parse(b"= Title\nDoc Writer <doc@example.org>; Ann B. Lee\nv2.1, 2024-05-01: Remark\n:toc:\n");
        let m = first_block(&doc);
        let a = |k| attr(&doc.ast, m, k);
        assert_eq!(a("author"), Some("Doc Writer"));
        assert_eq!(a("firstname"), Some("Doc"));
        assert_eq!(a("lastname"), Some("Writer"));
        assert_eq!(a("email"), Some("doc@example.org"));
        assert_eq!(a("author_2"), Some("Ann B. Lee"));
        assert_eq!(a("middlename_2"), Some("B."));
        assert_eq!(a("revnumber"), Some("2.1"));
        assert_eq!(a("revdate"), Some("2024-05-01"));
        assert_eq!(a("revremark"), Some("Remark"));
        assert_eq!(a("toc"), Some(""));
        // The header's span runs through its last line.
        let heading = next(&doc, m);
        assert_eq!(text(&doc, heading), "= Title\nDoc Writer <doc@example.org>; Ann B. Lee\nv2.1, 2024-05-01: Remark\n:toc:");
    }

    #[test]
    fn front_matter_is_a_metadata_block_and_the_title_still_follows_it() {
        let doc = parse(b"---\ntitle: x\n---\n= Title\n\nbody\n");
        let fm = first_block(&doc);
        assert_eq!(*kind(&doc, fm), Kind::Metadata { lang: b"yaml".to_vec(), text: b"title: x".to_vec() });
        assert_eq!(text(&doc, fm), "---\ntitle: x\n---");
        let marker = next(&doc, fm);
        assert_eq!(container(&doc, marker).name, b"document-attributes");
    }

    #[test]
    fn a_section_nests_a_paragraph_inside_it_and_a_same_level_heading_closes_it() {
        let doc = parse(b"== One\n\n=== Two\n\npar\n\n== Three\n");
        let sec_one = first_block(&doc);
        assert_eq!(*kind(&doc, sec_one), Kind::Section);
        let heading_one = first_child(&doc, sec_one);
        assert_eq!(*kind(&doc, heading_one), Kind::Heading { level: 2 });
        let sec_two = next(&doc, heading_one);
        assert_eq!(*kind(&doc, sec_two), Kind::Section);
        let sec_three = next(&doc, sec_one);
        assert_eq!(doc.ast.nodes[sec_three as usize].next_sibling, None);
    }

    #[test]
    fn section_metadata_lands_on_the_section_and_the_titles_anchor_is_its_id() {
        let doc = parse(b"[.classy]\n== One [[one]]\n\npar\n");
        let sec = first_block(&doc);
        assert_eq!(attr(&doc.ast, sec, "id"), Some("one"));
        assert_eq!(attr(&doc.ast, sec, "class"), Some("classy"));
        // The paragraph did not inherit the section's metadata.
        let para = nth(&doc, sec, 1);
        assert!(doc.ast.attrs_of(para).is_empty());
        let heading = nth(&doc, sec, 0);
        assert_eq!(str_of(&doc, first_child(&doc, heading)), "One");
    }

    #[test]
    fn block_metadata_becomes_the_blocks_attrs() {
        let doc = parse(b".A title\n[#the-id.a.b%opt,key=val]\ntext\n");
        let para = first_block(&doc);
        assert_eq!(attr(&doc.ast, para, "id"), Some("the-id"));
        assert_eq!(attr(&doc.ast, para, "class"), Some("a b"));
        assert_eq!(attr(&doc.ast, para, "title"), Some("A title"));
        assert_eq!(attr(&doc.ast, para, "options"), Some("opt"));
        assert_eq!(attr(&doc.ast, para, "key"), Some("val"));
        // The block's span starts at its first metadata line; the attribute
        // line's own span is recorded too.
        assert_eq!(text(&doc, para), ".A title\n[#the-id.a.b%opt,key=val]\ntext");
        assert_eq!(doc.attrs_text(para), Some(&b"[#the-id.a.b%opt,key=val]"[..]));
    }

    #[test]
    fn an_unrecognized_style_is_a_class_a_leftover_positional_keeps_its_number() {
        let doc = parse(b"[lead,second]\ntext\n");
        let b = first_block(&doc);
        assert_eq!(attr(&doc.ast, b, "class"), Some("lead"));
        assert_eq!(attr(&doc.ast, b, "$2"), Some("second"));
    }

    #[test]
    fn a_source_blocks_language_rides_in_the_code_block_not_in_attrs() {
        let doc = parse(b"[source,ruby]\n----\nputs 1\n----\n");
        let b = first_block(&doc);
        assert_eq!(*kind(&doc, b), Kind::CodeBlock { lang: Some(b"ruby".to_vec()), text: b"puts 1".to_vec() });
        assert!(doc.ast.attrs_of(b).is_empty());
    }

    #[test]
    fn a_lang_listing_and_a_markdown_fence_both_carry_the_language() {
        let doc = parse(b"[,js]\n----\nx\n----\n\n```py\ny\n```\n");
        let a = first_block(&doc);
        assert_eq!(*kind(&doc, a), Kind::CodeBlock { lang: Some(b"js".to_vec()), text: b"x".to_vec() });
        let b = next(&doc, a);
        assert_eq!(*kind(&doc, b), Kind::CodeBlock { lang: Some(b"py".to_vec()), text: b"y".to_vec() });
    }

    #[test]
    fn a_pass_block_is_a_raw_block_not_a_code_block() {
        let doc = parse(b"++++\n<div>x</div>\n++++\n");
        assert_eq!(
            *kind(&doc, first_block(&doc)),
            Kind::RawBlock { format: b"html".to_vec(), text: b"<div>x</div>".to_vec() }
        );
    }

    #[test]
    fn an_admonition_is_the_container_named_by_its_variant_in_all_three_spellings() {
        let doc = parse(b"NOTE: remember\n\n[TIP]\nhandy\n\n[WARNING]\n====\ncareful\n====\n");
        let note = first_block(&doc);
        assert_eq!(container(&doc, note).name, b"note");
        assert_eq!(container(&doc, note).form, Some(Form::BlockFenced));
        assert_eq!(doc.marker_text(note), Some(&b"NOTE: "[..]));
        let para = first_child(&doc, note);
        assert_eq!(str_of(&doc, first_child(&doc, para)), "remember");
        let tip = next(&doc, note);
        assert_eq!(container(&doc, tip).name, b"tip");
        assert!(doc.ast.attrs_of(tip).is_empty());
        let warning = next(&doc, tip);
        assert_eq!(container(&doc, warning).name, b"warning");
        assert_eq!(text(&doc, warning), "[WARNING]\n====\ncareful\n====");
    }

    #[test]
    fn a_quote_paragraph_is_a_block_quote_verse_is_a_line_block_with_depths() {
        let doc = parse(b"[quote,Someone]\nwords\n\n[verse]\n____\nRoses\n    deep\n  mid\n____\n");
        let quote = first_block(&doc);
        assert_eq!(*kind(&doc, quote), Kind::BlockQuote);
        assert_eq!(attr(&doc.ast, quote, "attribution"), Some("Someone"));
        let verse = next(&doc, quote);
        assert_eq!(*kind(&doc, verse), Kind::LineBlock);
        assert_eq!(*kind(&doc, nth(&doc, verse, 0)), Kind::Line { indent: 0 });
        assert_eq!(*kind(&doc, nth(&doc, verse, 1)), Kind::Line { indent: 2 });
        assert_eq!(*kind(&doc, nth(&doc, verse, 2)), Kind::Line { indent: 1 });
        assert_eq!(str_of(&doc, first_child(&doc, nth(&doc, verse, 1))), "deep");
    }

    #[test]
    fn a_markdown_style_quote_parses_its_interior_as_blocks_at_their_real_offsets() {
        let doc = parse(b"> one *two*\n> \n> - item\n");
        let quote = first_block(&doc);
        assert_eq!(*kind(&doc, quote), Kind::BlockQuote);
        let para = nth(&doc, quote, 0);
        assert_eq!(*kind(&doc, para), Kind::Para);
        let strong = nth(&doc, para, 1);
        assert_eq!(*kind(&doc, strong), Kind::InlineMark(InlineMark::Strong));
        assert_eq!(text(&doc, strong), "*two*");
        let list = nth(&doc, quote, 1);
        assert_eq!(*kind(&doc, list), Kind::BulletList { tight: true });
        assert_eq!(text(&doc, list), "- item");
    }

    #[test]
    fn a_discrete_heading_is_a_heading_in_the_flow_not_a_section() {
        let doc = parse(b"[discrete]\n== Title\n\npar\n");
        let h = first_block(&doc);
        assert_eq!(*kind(&doc, h), Kind::Heading { level: 2 });
        assert_eq!(*kind(&doc, next(&doc, h)), Kind::Para);
        assert!(doc.ast.attrs_of(h).is_empty());
    }

    #[test]
    fn block_macros_image_is_a_paragraph_holding_an_image_audio_video_and_toc_are_leaf_directives() {
        let doc = parse(b"image::a.png[Alt,200,100]\n\nvideo::v.mp4[poster.png]\n\ntoc::[]\n");
        let p = first_block(&doc);
        assert_eq!(*kind(&doc, p), Kind::Para);
        let img = first_child(&doc, p);
        assert_eq!(*kind(&doc, img), Kind::Image(Link { destination: Some(b"a.png".to_vec()), reference: None }));
        assert_eq!(str_of(&doc, first_child(&doc, img)), "Alt");
        assert_eq!(attr(&doc.ast, img, "width"), Some("200"));
        assert_eq!(attr(&doc.ast, img, "height"), Some("100"));
        let video = next(&doc, p);
        let vc = container(&doc, video);
        assert_eq!(vc.name, b"video");
        assert_eq!(vc.form, Some(Form::BlockLeaf));
        assert_eq!(vc.argument.as_deref(), Some(&b"v.mp4"[..]));
        assert_eq!(attr(&doc.ast, video, "poster"), Some("poster.png"));
        assert_eq!(doc.container_origin(video), Some(ContainerOrigin::Directive));
        let toc = next(&doc, video);
        assert_eq!(container(&doc, toc).name, b"toc");
        assert_eq!(container(&doc, toc).argument, None);
    }

    #[test]
    fn a_body_attribute_entry_is_a_substitution_definition_a_reference_is_its_use() {
        let doc = parse(b":name: Twig\n\nHello {name} and {nbsp}there {undefined-one}\n");
        let def = first_block(&doc);
        assert_eq!(*kind(&doc, def), Kind::Substitution { label: b"name".to_vec() });
        assert_eq!(str_of(&doc, first_child(&doc, def)), "Twig");
        let para = next(&doc, def);
        let u = nth(&doc, para, 1);
        assert_eq!(text_leaf(&doc, u), (TextLeafKind::SubstitutionReference, &b"name"[..]));
        assert_eq!(text(&doc, u), "{name}");
        assert_eq!(*kind(&doc, nth(&doc, para, 3)), Kind::NonBreakingSpace);
    }

    #[test]
    fn intrinsic_character_attributes_are_text() {
        let doc = parse_inline_list(b"a{sp}b{startsb}c{endsb}\n");
        let s = first_block(&doc);
        assert_eq!(str_of(&doc, s), "a b[c]");
        assert_eq!(doc.ast.nodes[s as usize].next_sibling, None);
    }

    #[test]
    fn an_unordered_list_item_carries_its_bullet_spelling_and_marker_span() {
        let doc = parse(b"* water\n");
        let list = first_block(&doc);
        assert_eq!(*kind(&doc, list), Kind::BulletList { tight: true });
        let item = first_child(&doc, list);
        assert_eq!(doc.spelling(item), Some(Spelling::Bullet(Bullet::Star)));
        assert_eq!(doc.marker_text(item), Some(&b"* "[..]));
        assert_eq!(str_of(&doc, first_child(&doc, item)), "water");
    }

    #[test]
    fn ordered_markers_carry_numbering_start_and_delimiter_spelling() {
        // An empty attribute line keeps the two lists apart.
        let doc = parse(b"c. one\nd. two\n\n[]\niv) four\n");
        let alpha = first_block(&doc);
        assert_eq!(
            *kind(&doc, alpha),
            Kind::OrderedList { numbering: ListNumbering::LowerAlpha, tight: true, start: Some(3) }
        );
        assert_eq!(doc.spelling(alpha), Some(Spelling::OrderedDelim(OrderedDelim::Period)));
        let roman = next(&doc, alpha);
        assert_eq!(
            *kind(&doc, roman),
            Kind::OrderedList { numbering: ListNumbering::LowerRoman, tight: true, start: Some(4) }
        );
        assert_eq!(doc.spelling(roman), Some(Spelling::OrderedDelim(OrderedDelim::ParenAfter)));
    }

    #[test]
    fn a_list_whose_every_item_carries_a_box_is_a_task_list() {
        let doc = parse(b"* [x] done\n* [ ] todo\n\n[]\n* [x] a\n* b\n");
        let tasks = first_block(&doc);
        assert_eq!(*kind(&doc, tasks), Kind::TaskList { tight: true });
        assert_eq!(*kind(&doc, nth(&doc, tasks, 0)), Kind::TaskListItem { checked: true });
        assert_eq!(*kind(&doc, nth(&doc, tasks, 1)), Kind::TaskListItem { checked: false });
        assert_eq!(str_of(&doc, first_child(&doc, nth(&doc, tasks, 0))), "done");
        // One item without a box: a plain list, the box literal text.
        let plain = next(&doc, tasks);
        assert_eq!(*kind(&doc, plain), Kind::BulletList { tight: true });
        let boxed = nth(&doc, plain, 0);
        assert_eq!(str_of(&doc, nth(&doc, boxed, 0)), "[x] ");
        assert_eq!(str_of(&doc, nth(&doc, boxed, 1)), "a");
    }

    #[test]
    fn list_continuation_attaches_blocks_the_items_principal_stays_inline() {
        let doc = parse(b"* one\n+\n[source]\n----\ncode\n----\n+\nmore\n* two\n");
        let list = first_block(&doc);
        let item = nth(&doc, list, 0);
        assert!(matches!(kind(&doc, nth(&doc, item, 0)), Kind::Str(_)));
        let code = nth(&doc, item, 1);
        assert!(matches!(kind(&doc, code), Kind::CodeBlock { .. }));
        assert_eq!(text(&doc, code), "[source]\n----\ncode\n----");
        assert_eq!(*kind(&doc, nth(&doc, item, 2)), Kind::Para);
        assert_eq!(text(&doc, nth(&doc, list, 1)), "* two");
    }

    #[test]
    fn a_description_list_terms_a_definition_nesting_and_a_nested_list() {
        let doc = parse(b"CPU:: brain\nRAM::\n  memory\n+\nextra\nGPU::\n* fast\n");
        let dl = first_block(&doc);
        assert_eq!(*kind(&doc, dl), Kind::DefinitionList);
        let cpu = nth(&doc, dl, 0);
        assert_eq!(*kind(&doc, nth(&doc, cpu, 0)), Kind::Term);
        assert_eq!(doc.marker_text(cpu), Some(&b":: "[..]));
        let cpu_def = nth(&doc, cpu, 1);
        assert_eq!(*kind(&doc, cpu_def), Kind::Definition);
        assert_eq!(str_of(&doc, first_child(&doc, cpu_def)), "brain");
        let ram = nth(&doc, dl, 1);
        let ram_def = nth(&doc, ram, 1);
        assert_eq!(str_of(&doc, nth(&doc, ram_def, 0)), "memory");
        assert_eq!(*kind(&doc, nth(&doc, ram_def, 1)), Kind::Para);
        let gpu = nth(&doc, dl, 2);
        let gpu_def = nth(&doc, gpu, 1);
        assert_eq!(*kind(&doc, nth(&doc, gpu_def, 0)), Kind::BulletList { tight: true });
    }

    #[test]
    fn a_table_cells_header_detection_spans_alignment_and_a_caption() {
        let src = b".Fruit\n[cols=\"1,1\",options=\"header\"]\n|===\n|Name |Count\n\n|Apple\n^|3\n\n2+|wide\n|===\n";
        let doc = parse(src);
        let table = first_block(&doc);
        assert_eq!(*kind(&doc, table), Kind::Table);
        assert_eq!(doc.text(table), &src[..src.len() - 1]);
        let cap = nth(&doc, table, 0);
        assert_eq!(*kind(&doc, cap), Kind::Caption);
        assert_eq!(str_of(&doc, first_child(&doc, cap)), "Fruit");
        let head = nth(&doc, table, 1);
        assert_eq!(*kind(&doc, head), Kind::Row { head: true });
        assert!(matches!(kind(&doc, nth(&doc, head, 0)), Kind::Cell(c) if c.head));
        assert_eq!(str_of(&doc, first_child(&doc, nth(&doc, head, 0))), "Name");
        let body = nth(&doc, table, 2);
        assert_eq!(*kind(&doc, body), Kind::Row { head: false });
        let count = nth(&doc, body, 1);
        assert!(matches!(kind(&doc, count), Kind::Cell(c) if c.alignment == Alignment::Center));
        assert_eq!(str_of(&doc, first_child(&doc, count)), "3");
        let wide = nth(&doc, nth(&doc, table, 3), 0);
        assert!(matches!(kind(&doc, wide), Kind::Cell(c) if c.colspan == 2));
        assert_eq!(attr(&doc.ast, table, "cols"), Some("1,1"));
    }

    #[test]
    fn an_implicit_header_the_first_row_on_one_line_followed_by_a_blank_line() {
        let doc = parse(b"|===\n|A |B\n\n|1 |2\n|===\n");
        let table = first_block(&doc);
        assert_eq!(*kind(&doc, nth(&doc, table, 0)), Kind::Row { head: true });
        assert_eq!(*kind(&doc, nth(&doc, table, 1)), Kind::Row { head: false });
        let doc2 = parse(b"|===\n|A |B\n|1 |2\n|===\n");
        assert_eq!(*kind(&doc2, nth(&doc2, first_block(&doc2), 0)), Kind::Row { head: false });
    }

    #[test]
    fn a_tables_cells_may_span_lines_and_hold_escaped_bars() {
        let doc = parse(b"|===\n|one\nline two \\| kept\n|three\n|===\n");
        let row = nth(&doc, first_block(&doc), 0);
        let first = first_child(&doc, nth(&doc, row, 0));
        assert_eq!(str_of(&doc, first), "one\nline two | kept");
    }

    #[test]
    fn spans_constrained_unconstrained_monospace_superscript_subscript_and_curved_quotes() {
        let doc = parse_inline_list(b"*s* **u** `m` ^up^ ~down~ \"`dq`\" '`sq`'\n");
        let root = doc.ast.root;
        assert_eq!(*kind(&doc, nth(&doc, root, 0)), Kind::InlineMark(InlineMark::Strong));
        assert_eq!(*kind(&doc, nth(&doc, root, 2)), Kind::InlineMark(InlineMark::Strong));
        assert_eq!(text(&doc, nth(&doc, root, 2)), "**u**");
        assert_eq!(text_leaf(&doc, nth(&doc, root, 4)).0, TextLeafKind::Verbatim);
        assert_eq!(*kind(&doc, nth(&doc, root, 6)), Kind::InlineMark(InlineMark::Superscript));
        assert_eq!(*kind(&doc, nth(&doc, root, 8)), Kind::InlineMark(InlineMark::Subscript));
        assert_eq!(*kind(&doc, nth(&doc, root, 10)), Kind::InlineMark(InlineMark::DoubleQuoted));
        assert_eq!(*kind(&doc, nth(&doc, root, 12)), Kind::InlineMark(InlineMark::SingleQuoted));
        assert_eq!(str_of(&doc, first_child(&doc, nth(&doc, root, 10))), "dq");
    }

    #[test]
    fn a_superscript_may_not_contain_whitespace_a_doubled_opener_with_no_doubled_close_is_constrained() {
        let doc = parse_inline_list(b"^a b^ and **bold*\n");
        let first = first_block(&doc);
        assert_eq!(str_of(&doc, first), "^a b^ and ");
        let span = next(&doc, first);
        assert_eq!(*kind(&doc, span), Kind::InlineMark(InlineMark::Strong));
        assert_eq!(str_of(&doc, first_child(&doc, span)), "*bold");
    }

    #[test]
    fn a_constrained_spans_interior_is_never_empty() {
        let doc = parse_inline_list(b"****\n");
        let span = first_block(&doc);
        assert_eq!(*kind(&doc, span), Kind::InlineMark(InlineMark::Strong));
        assert_eq!(str_of(&doc, first_child(&doc, span)), "*");
    }

    #[test]
    fn a_role_before_a_span_is_its_class_a_role_on_a_hash_span_makes_it_a_styled_span() {
        let doc = parse_inline_list(b"[.big]*x* [.red#r]#y# [#only]_z_\n");
        let root = doc.ast.root;
        let x = nth(&doc, root, 0);
        assert_eq!(*kind(&doc, x), Kind::InlineMark(InlineMark::Strong));
        assert_eq!(attr(&doc.ast, x, "class"), Some("big"));
        assert_eq!(text(&doc, x), "[.big]*x*");
        let y = nth(&doc, root, 2);
        assert_eq!(container(&doc, y).name, b"");
        assert_eq!(container(&doc, y).form, Some(Form::InlineText));
        assert_eq!(attr(&doc.ast, y, "class"), Some("red"));
        assert_eq!(attr(&doc.ast, y, "id"), Some("r"));
        let z = nth(&doc, root, 4);
        assert_eq!(*kind(&doc, z), Kind::InlineMark(InlineMark::Emph));
        assert_eq!(attr(&doc.ast, z, "id"), Some("only"));
    }

    #[test]
    fn a_macro_needs_no_word_boundary_before_it_a_url_does() {
        let doc = parse_inline_list(b"xfootnote:[n] xhttps://a.org\n");
        let root = doc.ast.root;
        assert_eq!(str_of(&doc, nth(&doc, root, 0)), "x");
        assert_eq!(text_leaf(&doc, nth(&doc, root, 1)).0, TextLeafKind::FootnoteReference);
        assert_eq!(str_of(&doc, nth(&doc, root, 2)), " xhttps://a.org");
    }

    #[test]
    fn a_bracket_that_precedes_nothing_spannable_is_literal_text() {
        let doc = parse_inline_list(b"see [1] and [.x]plain\n");
        assert_eq!(str_of(&doc, first_block(&doc)), "see [1] and [.x]plain");
    }

    #[test]
    fn links_bare_url_angle_url_bracketed_text_link_macro_attributes_email() {
        let doc = parse_inline_list(
            b"https://a.org <https://b.org> https://c.org[C^] link:d.html[D,window=_blank,role=ext] x@y.org\n",
        );
        let root = doc.ast.root;
        let a = nth(&doc, root, 0);
        assert_eq!(text_leaf(&doc, a), (TextLeafKind::Url, &b"https://a.org"[..]));
        let b = nth(&doc, root, 2);
        assert_eq!(text(&doc, b), "<https://b.org>");
        assert_eq!(doc.content_text(b), Some(&b"https://b.org"[..]));
        let c = nth(&doc, root, 4);
        assert_eq!(*kind(&doc, c), Kind::Link(Link { destination: Some(b"https://c.org".to_vec()), reference: None }));
        assert_eq!(str_of(&doc, first_child(&doc, c)), "C");
        assert_eq!(attr(&doc.ast, c, "window"), Some("_blank"));
        let d = nth(&doc, root, 6);
        assert_eq!(*kind(&doc, d), Kind::Link(Link { destination: Some(b"d.html".to_vec()), reference: None }));
        assert_eq!(str_of(&doc, first_child(&doc, d)), "D");
        assert_eq!(attr(&doc.ast, d, "class"), Some("ext"));
        assert_eq!(attr(&doc.ast, d, "window"), Some("_blank"));
        let e = nth(&doc, root, 8);
        assert_eq!(text_leaf(&doc, e), (TextLeafKind::Email, &b"x@y.org"[..]));
    }

    #[test]
    fn a_cross_reference_is_a_link_to_a_fragment() {
        let doc = parse_inline_list(b"<<sec>> <<sec,Text>> xref:other#frag[]\n");
        let root = doc.ast.root;
        let a = nth(&doc, root, 0);
        assert_eq!(*kind(&doc, a), Kind::Link(Link { destination: Some(b"#sec".to_vec()), reference: None }));
        assert_eq!(str_of(&doc, first_child(&doc, a)), "sec");
        let b = nth(&doc, root, 2);
        assert_eq!(str_of(&doc, first_child(&doc, b)), "Text");
        let c = nth(&doc, root, 4);
        assert_eq!(*kind(&doc, c), Kind::Link(Link { destination: Some(b"other#frag".to_vec()), reference: None }));
    }

    #[test]
    fn an_inline_image_carries_its_alt_text_as_children_and_its_size_in_attrs() {
        let doc = parse_inline_list(b"see image:a.png[Alt,50] here\n");
        let img = nth(&doc, doc.ast.root, 1);
        assert_eq!(*kind(&doc, img), Kind::Image(Link { destination: Some(b"a.png".to_vec()), reference: None }));
        assert_eq!(str_of(&doc, first_child(&doc, img)), "Alt");
        assert_eq!(attr(&doc.ast, img, "width"), Some("50"));
        assert_eq!(text(&doc, img), "image:a.png[Alt,50]");
    }

    #[test]
    fn footnotes_a_reference_at_the_use_and_a_detached_definition_numbered_in_order() {
        let doc = parse(b"a footnote:[first] b footnote:named[second] c footnote:named[]\n");
        let para = first_block(&doc);
        let r1 = nth(&doc, para, 1);
        assert_eq!(text_leaf(&doc, r1), (TextLeafKind::FootnoteReference, &b"1"[..]));
        assert_eq!(doc.content_text(r1), Some(&b"first"[..]));
        let r2 = nth(&doc, para, 3);
        assert_eq!(text_leaf(&doc, r2).1, b"named");
        let r3 = nth(&doc, para, 5);
        assert_eq!(text_leaf(&doc, r3).1, b"named");
        assert_eq!(doc.content_span(r3), None);
        // Two definitions, unattached, found the way djot's and Markdown's are.
        let roots = doc.ast.definition_roots();
        assert_eq!(roots.len(), 2);
        assert_eq!(*kind(&doc, roots[0]), Kind::Footnote { label: b"1".to_vec() });
        assert_eq!(*kind(&doc, roots[1]), Kind::Footnote { label: b"named".to_vec() });
        let body = first_child(&doc, roots[1]);
        assert_eq!(*kind(&doc, body), Kind::Para);
        assert_eq!(str_of(&doc, first_child(&doc, body)), "second");
    }

    #[test]
    fn passthroughs_math_kbd_btn_and_an_inline_anchor() {
        let doc =
            parse_inline_list(b"+++<b>+++ pass:[<i>] stem:[x^2] kbd:[Ctrl+C] btn:[OK] [[here]] anchor:there[]\n");
        let root = doc.ast.root;
        assert_eq!(*kind(&doc, nth(&doc, root, 0)), Kind::RawInline { format: b"html".to_vec(), text: b"<b>".to_vec() });
        assert_eq!(*kind(&doc, nth(&doc, root, 2)), Kind::RawInline { format: b"html".to_vec(), text: b"<i>".to_vec() });
        assert_eq!(text_leaf(&doc, nth(&doc, root, 4)), (TextLeafKind::InlineMath, &b"x^2"[..]));
        let kbd = nth(&doc, root, 6);
        assert_eq!(container(&doc, kbd).name, b"kbd");
        assert_eq!(str_of(&doc, first_child(&doc, kbd)), "Ctrl+C");
        let btn = nth(&doc, root, 8);
        assert_eq!(container(&doc, btn).name, b"b");
        assert_eq!(attr(&doc.ast, btn, "class"), Some("button"));
        let here = nth(&doc, root, 10);
        assert_eq!(attr(&doc.ast, here, "id"), Some("here"));
        assert_eq!(doc.ast.nodes[here as usize].first_child, None);
        let there = nth(&doc, root, 12);
        assert_eq!(attr(&doc.ast, there, "id"), Some("there"));
    }

    #[test]
    fn hard_breaks_a_trailing_plus_and_every_newline_under_hardbreaks() {
        let doc = parse(b"a +\nb\n\n[%hardbreaks]\nc\nd\n");
        let p1 = first_block(&doc);
        assert_eq!(str_of(&doc, nth(&doc, p1, 0)), "a");
        assert_eq!(*kind(&doc, nth(&doc, p1, 1)), Kind::HardBreak);
        assert_eq!(text(&doc, nth(&doc, p1, 1)), " +\n");
        assert_eq!(str_of(&doc, nth(&doc, p1, 2)), "b");
        let p2 = next(&doc, p1);
        assert_eq!(*kind(&doc, nth(&doc, p2, 1)), Kind::HardBreak);
        assert_eq!(text(&doc, nth(&doc, p2, 1)), "\n");
    }

    #[test]
    fn replacements_symbols_arrows_an_em_dash_and_an_ellipsis() {
        let doc = parse_inline_list(b"(C) a->b x--y wait...\n");
        let root = doc.ast.root;
        assert_eq!(str_of(&doc, nth(&doc, root, 0)), "\u{a9} a\u{2192}b x");
        assert_eq!(*kind(&doc, nth(&doc, root, 1)), Kind::SmartPunctuation(SmartPunctuationKind::EmDash));
        assert_eq!(str_of(&doc, nth(&doc, root, 2)), "y wait");
        assert_eq!(*kind(&doc, nth(&doc, root, 3)), Kind::SmartPunctuation(SmartPunctuationKind::Ellipses));
    }

    #[test]
    fn escapes_a_backslash_before_a_mark_a_macro_a_scheme_or_a_backslash() {
        let doc = parse_inline_list(b"\\*a* \\link:x[y] \\https://z.org \\\\ \\q\n");
        let s = first_block(&doc);
        assert_eq!(str_of(&doc, s), "*a* link:x[y] https://z.org \\ \\q");
        assert_eq!(doc.ast.nodes[s as usize].next_sibling, None);
    }

    #[test]
    fn a_character_reference_is_its_own_str_decoded() {
        let doc = parse_inline_list(b"a &amp; &#x41; &bogus; b\n");
        let root = doc.ast.root;
        assert_eq!(str_of(&doc, nth(&doc, root, 1)), "&");
        assert_eq!(text(&doc, nth(&doc, root, 1)), "&amp;");
        assert_eq!(str_of(&doc, nth(&doc, root, 3)), "A");
        assert_eq!(str_of(&doc, nth(&doc, root, 4)), " &bogus; b");
    }

    #[test]
    fn an_indented_paragraph_is_a_literal_block_with_its_common_indent_stripped() {
        let doc = parse(b"    one\n      two\n");
        let b = first_block(&doc);
        assert_eq!(*kind(&doc, b), Kind::CodeBlock { lang: None, text: b"one\n  two".to_vec() });
        assert_eq!(doc.content_text(b), Some(&b"    one\n      two"[..]));
    }

    #[test]
    fn degenerate_inputs_parse_and_encode_without_crashing() {
        for source in [
            &b""[..], b"\n", b"   \n", b"\n\n\n", b"= \n", b"----\n", b"****\n", b"*\n", b"|===\n", b"|===\n|\n",
            b"[[\n", b"[]\n", b".\n", b"..\n", b"term::\n", b"* \n", b"+\n", b"footnote:[]\n", b"image::[]\n",
            b"<<>>\n", b"[.]*x*\n", b"> \n", b"```\n", b"[verse]\n____\n____\n", b"NOTE: \n", b"---\n",
            b"---\n---\n", b"&#0;\n", b"{}\n", b"1. \n", b"= T\nA <\n", b"[source]\n", b"[quote]\n\n", b"\\\n",
            b"*a\n**b\n", b"|===\n2+|a\n|===\n", b"toc::[foo]\n", b"audio::a.mp3[x,y]\n",
        ] {
            let doc = parse(source);
            let _ = asg::encode(&doc, asg::Root::Document);
        }
    }

    #[test]
    fn every_construct_the_parser_produces_encodes_as_an_asg() {
        let src = b"= T\nA B <a@b.org>\n\nNOTE: x^2^ ~s~ \"`q`\" [.r]#y# image:i.png[] footnote:[f] {v} {nbsp} +++r+++ pass:[p] stem:[m] kbd:[K] [[a]] a +\nb\n\n:e: v\n\n[quote]\nq\n\n> md\n\n|===\n|c\n|===\n\n* [x] t\n\n[verse]\nv\n";
        let doc = parse(src);
        let json = asg::encode(&doc, asg::Root::Document);
        let parsed = twig_kit::json::parse(&json).expect("valid JSON");
        assert!(matches!(parsed, twig_kit::json::Value::Object(_)));
    }

    #[test]
    fn delimited_blocks_carry_no_asg_bookkeeping_in_attrs() {
        let doc = parse(b"----\ncode\n----\n\n[source,ruby]\n----\nx\n----\n");
        for id in 0..doc.ast.nodes.len() {
            assert!(doc.ast.attrs_of(id as NodeId).entries.is_empty());
        }
    }

    #[test]
    fn zig_parse_int_semantics() {
        assert_eq!(zig_parse_uint(b"+10", 10, u32::MAX as u64), Some(10));
        assert_eq!(zig_parse_uint(b"-0", 10, u32::MAX as u64), Some(0));
        assert_eq!(zig_parse_uint(b"-5", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"1_0", 10, u32::MAX as u64), Some(10));
        assert_eq!(zig_parse_uint(b"_10", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"+", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"4294967296", 10, u32::MAX as u64), None);
        assert_eq!(zig_parse_uint(b"fF", 16, 0x1f_ffff), Some(255));
    }
}
