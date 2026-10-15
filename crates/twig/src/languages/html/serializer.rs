//! `Ast` -> HTML text. Port of `src/languages/html/serializer.zig`.
//!
//! A GENERIC printer: it renders the shared `Ast` alone and covers the ENTIRE
//! shared kind vocabulary — both the semantic core (`para`, `heading`,
//! `emph`, ...) and the generic-markup escape hatch (`container`, `comment`,
//! `doctype`, `processing_instruction`, `cdata`).
//!
//! ── Reference/footnote resolution without importing djot ──────────────────
//! Djot defers `link`/`image`/`footnote_reference` resolution to render time
//! against the label tables in `Document.labels`. This printer takes an
//! `&Ast` (so it cannot reach a byte offset) plus those tables on their own
//! as an optional [`Context`] (which IS [`Labels`]). `None` means "no tables":
//! unresolved references warn and fall back to no `href`/`src`; an empty
//! footnote table yields an empty, but structurally valid, endnotes section
//! for any stray `footnote_reference`.
//!
//! ── Generic markup kinds ───────────────────────────────────────────────────
//!   - `container`: HTML **void elements** are looked up by NAME and always
//!     render as `<name attrs>` with no children and no close tag. A non-void
//!     element always renders as an explicit `<name>...</name>` pair, because
//!     HTML has no self-closing syntax for ordinary elements.
//!   - `comment`: `<!--text-->`, payload verbatim.
//!   - `doctype`: `<!DOCTYPE` + payload + `>`.
//!   - `processing_instruction`: the HTML5 tokenizer's "bogus comment" shape
//!     `<?target data>`.
//!   - `cdata`: rendered as escaped TEXT.
//!   - Attributes: a bare (`value == None`) entry renders as just its key.

use std::collections::{HashMap, HashSet};
use std::fmt;

use crate::ast::{Alignment, Ast, Form, InlineMark, Kind, Link, ListNumbering, MarkupLeafKind, NodeId, SmartPunctuationKind, TextLeafKind};
use crate::document::Labels;

/// Render conventions. The defaults (`RenderOptions::DEFAULT`, also
/// `Default::default()`) are djot's.
#[derive(Clone, Copy, Debug)]
pub struct RenderOptions {
    pub warn: Option<fn(&str)>,
    /// Emit void elements XHTML-style, with a ` />` self-close. CommonMark's
    /// reference output is XHTML (`<br />`); djot's is HTML (`<br>`).
    pub xhtml_void: bool,
    /// Emit an image's synthesized attributes in CommonMark order (`src`,
    /// `alt`, `title`) rather than djot's (`alt`, `src`, `title`).
    pub commonmark_image_attrs: bool,
    /// Percent-encode link/image destinations (and autolink URLs) the way
    /// CommonMark's reference `houdini_escape_href` does.
    pub percent_encode_urls: bool,
    /// Escape `"` to `&quot;` in text content, not just in attribute values.
    pub escape_text_quotes: bool,
    /// Render list items the CommonMark way (tight items hug their content).
    pub commonmark_lists: bool,
    /// Group a table's rows into `<thead>`/`<tbody>` sections.
    pub table_sections: bool,
    /// Render a cell's alignment as GFM's presentational `align="center"`.
    pub gfm_cell_align_attr: bool,
    /// Render task list items GFM's way (plain `<ul>`, cmark-gfm's `<input>`).
    pub gfm_task_list_items: bool,
    /// GFM's "Disallowed Raw HTML" extension: in raw HTML output, escape the
    /// leading `<` of a blacklisted tag to `&lt;`.
    pub tagfilter: bool,
}

impl RenderOptions {
    /// djot's conventions — the bare defaults.
    pub const DEFAULT: RenderOptions = RenderOptions {
        warn: None,
        xhtml_void: false,
        commonmark_image_attrs: false,
        percent_encode_urls: false,
        escape_text_quotes: false,
        commonmark_lists: false,
        table_sections: false,
        gfm_cell_align_attr: false,
        gfm_task_list_items: false,
        tagfilter: false,
    };
}

impl Default for RenderOptions {
    fn default() -> RenderOptions {
        RenderOptions::DEFAULT
    }
}

/// The render-time label tables — `Document.labels`.
pub type Context = Labels;

/// One `key="value"` pair to render ahead of a node's own attributes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KV<'k> {
    pub key: &'k [u8],
    pub value: &'k [u8],
}

const fn kv<'k>(key: &'k [u8], value: &'k [u8]) -> KV<'k> {
    KV { key, value }
}

/// `UnsafeMetadata`: a `metadata` node's body contains `</script`, which
/// cannot be represented in a raw-text `<script>` data island. The printer
/// refuses rather than emit unsafe HTML.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderError {
    UnsafeMetadata,
}

impl fmt::Display for RenderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("metadata contains </script; unsafe to embed in HTML")
    }
}

impl std::error::Error for RenderError {}

impl From<RenderError> for crate::Error {
    fn from(_: RenderError) -> crate::Error {
        crate::Error::UnsafeMetadata
    }
}

/// The `…Alloc` wrappers' error: only the content refusal remains.
pub type RenderAllocError = RenderError;

const VOID_ELEMENTS: [&[u8]; 14] = [
    b"area", b"base", b"br", b"col", b"embed", b"hr", b"img", b"input", b"link", b"meta", b"param", b"source",
    b"track", b"wbr",
];

/// Whether `name` is an HTML5 void element. Names match exactly as stored on
/// a node (lowercase, as the parser produces).
pub fn is_void_element(name: &[u8]) -> bool {
    VOID_ELEMENTS.contains(&name)
}

/// CommonMark's `houdini_escape_href` "safe" set.
fn href_safe_byte(c: u8) -> bool {
    matches!(c,
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
        | b'-' | b'_' | b'.' | b'~'
        | b'!' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'(' | b')' | b'*' | b'+' | b',' | b'/' | b':' | b';'
        | b'=' | b'?' | b'@')
}

/// Percent-encode a URL destination the way CommonMark's reference renderer
/// does. An existing `%` passes through, so a pre-encoded destination is not
/// double-encoded.
fn percent_encode_href(url: &[u8]) -> Vec<u8> {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = Vec::with_capacity(url.len());
    for &c in url {
        if href_safe_byte(c) {
            out.push(c);
        } else {
            out.push(b'%');
            out.push(HEX[(c >> 4) as usize]);
            out.push(HEX[(c & 0x0F) as usize]);
        }
    }
    out
}

const RAW_TEXT_ELEMENTS: [&[u8]; 7] = [b"script", b"style", b"xmp", b"iframe", b"noembed", b"noframes", b"plaintext"];

/// Elements whose content is *raw text* (no character-reference escaping).
/// RCDATA elements (`textarea`/`title`) are deliberately absent.
fn is_raw_text_element(name: &[u8]) -> bool {
    RAW_TEXT_ELEMENTS.contains(&name)
}

/// Write the text body of element `name` as HTML: verbatim for a raw-text
/// element, entity-escaped (`&<>`) for any other.
pub fn write_element_text(w: &mut Vec<u8>, name: &[u8], text: &[u8]) {
    if is_raw_text_element(name) {
        w.extend_from_slice(text);
        return;
    }
    for &c in text {
        match c {
            b'&' => w.extend_from_slice(b"&amp;"),
            b'<' => w.extend_from_slice(b"&lt;"),
            b'>' => w.extend_from_slice(b"&gt;"),
            _ => w.push(c),
        }
    }
}

/// GFM's tagfilter blacklist, verbatim from cmark-gfm.
const TAGFILTER_BLACKLIST: [&[u8]; 9] =
    [b"title", b"textarea", b"style", b"xmp", b"iframe", b"noembed", b"noframes", b"script", b"plaintext"];

/// Zig's `std.ascii.isWhitespace`: space, \t, \n, \r, VT, FF.
fn is_ascii_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0B | 0x0C)
}

/// Whether `text[at] == '<'` opens a blacklisted tag.
fn is_filtered_tag(text: &[u8], at: usize) -> bool {
    let mut i = at + 1;
    if i < text.len() && text[i] == b'/' {
        i += 1;
    }
    for name in TAGFILTER_BLACKLIST {
        if text.len() - i < name.len() {
            continue;
        }
        if !text[i..i + name.len()].eq_ignore_ascii_case(name) {
            continue;
        }
        let j = i + name.len();
        if j == text.len() || text[j] == b'>' || text[j] == b'/' || is_ascii_ws(text[j]) {
            return true;
        }
    }
    false
}

fn find_ignore_case(hay: &[u8], needle: &[u8]) -> bool {
    hay.len() >= needle.len() && hay.windows(needle.len()).any(|w| w.eq_ignore_ascii_case(needle))
}

fn smart_punct(kind: SmartPunctuationKind) -> &'static str {
    match kind {
        SmartPunctuationKind::RightSingleQuote => "\u{2019}",
        SmartPunctuationKind::LeftSingleQuote => "\u{2018}",
        SmartPunctuationKind::RightDoubleQuote => "\u{201D}",
        SmartPunctuationKind::LeftDoubleQuote => "\u{201C}",
        SmartPunctuationKind::Ellipses => "\u{2026}",
        SmartPunctuationKind::EmDash => "\u{2014}",
        SmartPunctuationKind::EnDash => "\u{2013}",
    }
}

fn ordered_list_type(numbering: ListNumbering) -> &'static [u8] {
    match numbering {
        ListNumbering::Decimal => b"1",
        ListNumbering::LowerAlpha => b"a",
        ListNumbering::UpperAlpha => b"A",
        ListNumbering::LowerRoman => b"i",
        ListNumbering::UpperRoman => b"I",
    }
}

fn align_style(a: Alignment) -> &'static [u8] {
    match a {
        Alignment::Left => b"text-align: left;",
        Alignment::Right => b"text-align: right;",
        Alignment::Center => b"text-align: center;",
        Alignment::Default => b"",
    }
}

fn align_name(a: Alignment) -> &'static [u8] {
    match a {
        Alignment::Left => b"left",
        Alignment::Right => b"right",
        Alignment::Center => b"center",
        Alignment::Default => b"",
    }
}

fn has_key(kvs: &[KV<'_>], key: &[u8]) -> bool {
    kvs.iter().any(|kv| kv.key == key)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Section {
    None,
    Head,
    Body,
}

/// The generic HTML printer. Writes into the borrowed `out` buffer.
///
/// ```ignore
/// let mut out = Vec::new();
/// let mut r = Renderer::new(&doc.ast, &mut out, Some(&doc.labels), options);
/// r.render_node(doc.ast.root)?;
/// ```
pub struct Renderer<'a> {
    pub ast: &'a Ast,
    pub out: &'a mut Vec<u8>,
    labels: Option<&'a Context>,
    tight: bool,
    footnote_index: HashMap<Vec<u8>, usize>,
    next_footnote_index: usize,
    fnref_id_emitted: HashSet<Vec<u8>>,
    pub options: RenderOptions,
}

impl<'a> Renderer<'a> {
    pub fn new(ast: &'a Ast, out: &'a mut Vec<u8>, ctx: Option<&'a Context>, options: RenderOptions) -> Renderer<'a> {
        Renderer {
            ast,
            out,
            labels: ctx,
            tight: false,
            footnote_index: HashMap::new(),
            next_footnote_index: 1,
            fnref_id_emitted: HashSet::new(),
            options,
        }
    }

    fn warn(&self, msg: &str) {
        if let Some(f) = self.options.warn {
            f(msg);
        }
    }

    #[inline]
    fn w(&mut self, s: &[u8]) {
        self.out.extend_from_slice(s);
    }

    #[inline]
    fn wb(&mut self, c: u8) {
        self.out.push(c);
    }

    // ── escaping ─────────────────────────────────────────────────────────

    fn write_escaped(&mut self, s: &[u8]) {
        let q = self.options.escape_text_quotes;
        for &c in s {
            match c {
                b'&' => self.out.extend_from_slice(b"&amp;"),
                b'<' => self.out.extend_from_slice(b"&lt;"),
                b'>' => self.out.extend_from_slice(b"&gt;"),
                b'"' if q => self.out.extend_from_slice(b"&quot;"),
                _ => self.out.push(c),
            }
        }
    }

    fn write_escaped_attr(&mut self, s: &[u8]) {
        for &c in s {
            match c {
                b'&' => self.out.extend_from_slice(b"&amp;"),
                b'<' => self.out.extend_from_slice(b"&lt;"),
                b'>' => self.out.extend_from_slice(b"&gt;"),
                b'"' => self.out.extend_from_slice(b"&quot;"),
                _ => self.out.push(c),
            }
        }
    }

    // ── attribute / tag rendering ────────────────────────────────────────

    /// Render `id`'s attributes (plus `extra`, written first). `class` from
    /// both is space-joined (extra's first); any other key an `extra` already
    /// emitted is not repeated from the node's own attributes.
    fn render_attributes(&mut self, id: NodeId, extra: &[KV<'_>]) {
        let ast = self.ast;
        let attrs = ast.attrs_of(id);
        let node_class = attrs.get(b"class");
        for kv in extra {
            if kv.key == b"class" {
                self.w(b" class=\"");
                self.write_escaped_attr(kv.value);
                if let Some(nc) = node_class {
                    self.wb(b' ');
                    self.write_escaped_attr(nc);
                }
                self.wb(b'"');
            } else {
                self.wb(b' ');
                self.w(kv.key);
                self.w(b"=\"");
                self.write_escaped_attr(kv.value);
                self.wb(b'"');
            }
        }
        for kv in &attrs.entries {
            if has_key(extra, &kv.key) {
                continue;
            }
            self.wb(b' ');
            self.w(&kv.key);
            if let Some(value) = &kv.value {
                self.w(b"=\"");
                self.write_escaped_attr(value);
                self.wb(b'"');
            }
        }
    }

    fn has_attrs_or_extra(&self, id: NodeId, extra: &[KV<'_>]) -> bool {
        !extra.is_empty() || !self.ast.attrs_of(id).is_empty()
    }

    fn render_tag(&mut self, tag: &[u8], id: NodeId, extra: &[KV<'_>]) {
        self.wb(b'<');
        self.w(tag);
        if self.has_attrs_or_extra(id, extra) {
            self.render_attributes(id, extra);
        }
        if self.options.xhtml_void && is_void_element(tag) {
            self.w(b" />");
        } else {
            self.wb(b'>');
        }
    }

    fn render_close_tag(&mut self, tag: &[u8]) {
        self.w(b"</");
        self.w(tag);
        self.wb(b'>');
    }

    /// `newlines`: 2 = newline after the open tag AND after the close tag; 1
    /// = only after the close tag; 0 = none.
    fn in_tags(&mut self, tag: &[u8], id: NodeId, newlines: u8, extra: &[KV<'_>]) -> Result<(), RenderError> {
        self.render_tag(tag, id, extra);
        if newlines >= 2 {
            self.wb(b'\n');
        }
        self.render_children(id)?;
        self.render_close_tag(tag);
        if newlines >= 1 {
            self.wb(b'\n');
        }
        Ok(())
    }

    // ── children / tight-list tracking ──────────────────────────────────

    pub fn render_children(&mut self, id: NodeId) -> Result<(), RenderError> {
        let old_tight = self.tight;
        match self.ast.kind(id) {
            Kind::BulletList { tight } | Kind::OrderedList { tight, .. } | Kind::TaskList { tight } => {
                self.tight = *tight
            }
            // Tightness belongs to a list item's DIRECT paragraphs only; reset
            // at any other block container so it doesn't leak past it.
            Kind::BlockQuote | Kind::Section | Kind::Container(_) => self.tight = false,
            _ => {}
        }
        let mut c = self.ast.node(id).first_child;
        while let Some(cid) = c {
            self.render_node(cid)?;
            c = self.ast.node(cid).next_sibling;
        }
        self.tight = old_tight;
        Ok(())
    }

    /// Render one `<li>` the CommonMark way, writing `prefix` immediately
    /// after the `<li>`. A tight paragraph hugs the content; every other child
    /// is a block preceded by a newline only when not already at line start.
    fn render_commonmark_list_item_prefixed(&mut self, id: NodeId, prefix: &[u8]) -> Result<(), RenderError> {
        self.w(b"<li>");
        self.w(prefix);
        let mut at_line_start = false;
        let mut c = self.ast.node(id).first_child;
        while let Some(cid) = c {
            if self.tight && *self.ast.kind(cid) == Kind::Para {
                self.render_children(cid)?;
                at_line_start = false;
            } else {
                if !at_line_start {
                    self.wb(b'\n');
                }
                self.render_node(cid)?;
                at_line_start = true;
            }
            c = self.ast.node(cid).next_sibling;
        }
        self.w(b"</li>\n");
        Ok(())
    }

    /// Write raw HTML through, applying GFM's tagfilter when it's on. Only
    /// the leading `<` of a blacklisted tag becomes `&lt;`.
    fn write_raw_html(&mut self, text: &[u8]) {
        if !self.options.tagfilter {
            self.w(text);
            return;
        }
        let mut flushed = 0;
        for lt in 0..text.len() {
            if text[lt] == b'<' && is_filtered_tag(text, lt) {
                self.w(&text[flushed..lt]);
                self.w(b"&lt;");
                flushed = lt + 1;
            }
        }
        self.w(&text[flushed..]);
    }

    /// A table's rows grouped into `<thead>`/`<tbody>` runs by each row's
    /// `head` flag. Non-`row` children render in place, outside any section.
    fn render_sectioned_table(&mut self, id: NodeId) -> Result<(), RenderError> {
        self.render_tag(b"table", id, &[]);
        self.wb(b'\n');
        let mut section = Section::None;
        let mut c = self.ast.node(id).first_child;
        while let Some(cid) = c {
            if let Kind::Row { head } = self.ast.kind(cid) {
                let want = if *head { Section::Head } else { Section::Body };
                if section != want {
                    self.close_table_section(section);
                    self.w(if want == Section::Head { b"<thead>\n" } else { b"<tbody>\n" });
                    section = want;
                }
            }
            self.render_node(cid)?;
            c = self.ast.node(cid).next_sibling;
        }
        self.close_table_section(section);
        self.render_close_tag(b"table");
        self.wb(b'\n');
        Ok(())
    }

    fn close_table_section(&mut self, section: Section) {
        match section {
            Section::None => {}
            Section::Head => self.w(b"</thead>\n"),
            Section::Body => self.w(b"</tbody>\n"),
        }
    }

    fn write_element_text(&mut self, tag: &[u8], text: &[u8]) {
        if is_raw_text_element(tag) {
            self.w(text);
        } else {
            self.write_escaped(text);
        }
    }

    /// Write a raw-text element's children literally (no escaping).
    fn render_raw_text_children(&mut self, id: NodeId) -> Result<(), RenderError> {
        let ast = self.ast;
        for child in ast.children(id) {
            match &child.kind {
                Kind::Str(t) => self.w(t),
                Kind::TextLeaf { kind: TextLeafKind::Verbatim, text } => self.w(text),
                _ => self.render_node(child.id)?,
            }
        }
        Ok(())
    }

    // ── footnotes ────────────────────────────────────────────────────────

    fn add_backlink(&mut self, note: &[u8], ident: usize) {
        let mut end = note.len();
        while end > 0 && (note[end - 1] == b'\r' || note[end - 1] == b'\n') {
            end -= 1;
        }
        let trimmed_end = &note[..end];
        if trimmed_end.ends_with(b"</p>") {
            self.w(&trimmed_end[..trimmed_end.len() - 4]);
            self.write_backlink_anchor(ident);
            self.w(b"</p>");
            self.w(&note[end..]);
        } else {
            self.w(note);
            self.w(b"<p>");
            self.write_backlink_anchor(ident);
            self.w(b"</p>\n");
        }
    }

    fn write_backlink_anchor(&mut self, ident: usize) {
        self.w(format!("<a href=\"#fnref{ident}\" role=\"doc-backlink\">\u{21A9}\u{FE0E}</a>").as_bytes());
    }

    fn render_notes(&mut self) -> Result<(), RenderError> {
        // Render every footnote's children into a scratch buffer first, in
        // node-id (definition) order, so the first occurrence of a nested
        // reference deterministically claims its `id="fnrefN"`.
        let mut entries: Vec<(Vec<u8>, NodeId)> = match self.labels {
            Some(l) => l.footnotes.iter().map(|(k, v)| (k.clone(), *v)).collect(),
            None => Vec::new(),
        };
        entries.sort_by_key(|e| e.1);

        let mut rendered: HashMap<Vec<u8>, Vec<u8>> = HashMap::new();
        for (key, id) in entries {
            let saved = std::mem::take(self.out);
            let res = self.render_children(id);
            let note = std::mem::replace(self.out, saved);
            res?;
            rendered.insert(key, note);
        }

        self.w(b"<section role=\"doc-endnotes\">\n<hr>\n<ol>\n");
        let n = self.next_footnote_index;
        if n > 1 {
            let mut order: Vec<Option<Vec<u8>>> = vec![None; n];
            for (k, &v) in &self.footnote_index {
                if v < n {
                    order[v] = Some(k.clone());
                }
            }
            for (i, lab) in order.iter().enumerate().skip(1) {
                self.w(format!("<li id=\"fn{i}\">\n").as_bytes());
                let note: &[u8] = match lab {
                    Some(lab) => rendered.get(lab).map(|v| v.as_slice()).unwrap_or(b""),
                    None => b"",
                };
                self.add_backlink(note, i);
                self.w(b"</li>\n");
            }
        }
        self.w(b"</ol>\n</section>\n");
        Ok(())
    }

    fn footnote_index_for(&mut self, label: &[u8]) -> usize {
        if let Some(&i) = self.footnote_index.get(label) {
            return i;
        }
        let idx = self.next_footnote_index;
        self.footnote_index.insert(label.to_vec(), idx);
        self.next_footnote_index += 1;
        idx
    }

    // ── the big dispatch ─────────────────────────────────────────────────

    pub fn render_node(&mut self, id: NodeId) -> Result<(), RenderError> {
        let ast = self.ast;
        match ast.kind(id) {
            Kind::Doc => {
                self.render_children(id)?;
                if self.next_footnote_index > 1 {
                    self.render_notes()?;
                }
            }
            Kind::Para => {
                if self.tight {
                    self.render_children(id)?;
                    self.wb(b'\n');
                } else {
                    self.in_tags(b"p", id, 1, &[])?;
                }
            }
            Kind::BlockQuote => self.in_tags(b"blockquote", id, 2, &[])?,
            Kind::Container(c) => {
                let block = c.form.map(|f| f.is_block_form()).unwrap_or(false);
                // An anonymous container renders as the generic wrapper for
                // its level, which is what djot.js emits too.
                let tag: &[u8] = if !c.name.is_empty() {
                    &c.name
                } else if block {
                    b"div"
                } else {
                    b"span"
                };
                self.render_tag(tag, id, &[]);
                if is_void_element(tag) {
                    return Ok(());
                }
                if let Some(text) = &c.text {
                    self.write_element_text(tag, text);
                    self.render_close_tag(tag);
                    return Ok(());
                }
                if is_raw_text_element(tag) {
                    self.render_raw_text_children(id)?;
                    self.render_close_tag(tag);
                    return Ok(());
                }
                let newlines: u8 = match c.form {
                    Some(Form::InlineText) => 0,
                    Some(Form::BlockLeaf) => 1,
                    Some(Form::BlockFenced) => 2,
                    None => 0,
                };
                if newlines >= 2 {
                    self.wb(b'\n');
                }
                self.render_children(id)?;
                self.render_close_tag(tag);
                if newlines >= 1 {
                    self.wb(b'\n');
                }
            }
            Kind::Section => self.in_tags(b"section", id, 2, &[])?,
            Kind::ListItem => {
                if self.options.commonmark_lists {
                    self.render_commonmark_list_item_prefixed(id, b"")?;
                } else {
                    self.in_tags(b"li", id, 2, &[])?;
                }
            }
            Kind::TaskListItem { checked } => {
                if self.options.gfm_task_list_items {
                    // cmark-gfm's tasklist extension writes this `<input>` as
                    // a literal string; reproduce it verbatim.
                    let prefix: &[u8] = if *checked {
                        b"<input checked=\"\" disabled=\"\" type=\"checkbox\"> "
                    } else {
                        b"<input disabled=\"\" type=\"checkbox\"> "
                    };
                    self.render_commonmark_list_item_prefixed(id, prefix)?;
                } else {
                    self.w(b"<li>\n");
                    if *checked {
                        self.w(b"<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\n");
                    } else {
                        self.w(b"<input disabled=\"\" type=\"checkbox\"/>\n");
                    }
                    self.render_children(id)?;
                    self.render_close_tag(b"li");
                    self.wb(b'\n');
                }
            }
            Kind::DefinitionListItem => self.render_children(id)?,
            Kind::Definition => self.in_tags(b"dd", id, 2, &[])?,
            Kind::Term => self.in_tags(b"dt", id, 1, &[])?,
            Kind::DefinitionList => self.in_tags(b"dl", id, 2, &[])?,
            Kind::LineBlock => self.render_line_block(id)?,
            Kind::BulletList { .. } => self.in_tags(b"ul", id, 2, &[])?,
            Kind::TaskList { .. } => {
                if self.options.gfm_task_list_items {
                    self.in_tags(b"ul", id, 2, &[])?;
                } else {
                    self.in_tags(b"ul", id, 2, &[kv(b"class", b"task-list")])?;
                }
            }
            Kind::OrderedList { numbering, start, .. } => {
                let start_text = match start {
                    Some(s) if *s != 1 => Some(s.to_string().into_bytes()),
                    _ => None,
                };
                let mut extra: Vec<KV<'_>> = Vec::with_capacity(2);
                if let Some(t) = &start_text {
                    extra.push(kv(b"start", t));
                }
                if *numbering != ListNumbering::Decimal {
                    extra.push(kv(b"type", ordered_list_type(*numbering)));
                }
                self.in_tags(b"ol", id, 2, &extra)?;
            }
            Kind::Heading { level } => {
                // Zig formats into a 4-byte buffer and falls back to `h1`.
                let mut tag = format!("h{level}").into_bytes();
                if tag.len() > 4 {
                    tag = b"h1".to_vec();
                }
                self.in_tags(&tag, id, 1, &[])?;
            }
            Kind::TextLeaf { kind, text } => match kind {
                TextLeafKind::Symb => {
                    self.wb(b':');
                    self.write_escaped(text);
                    self.wb(b':');
                }
                TextLeafKind::Verbatim => {
                    self.render_tag(b"code", id, &[]);
                    self.write_escaped(text);
                    self.render_close_tag(b"code");
                }
                TextLeafKind::InlineMath => {
                    self.render_tag(b"span", id, &[kv(b"class", b"math inline")]);
                    self.w(b"\\(");
                    self.write_escaped(text);
                    self.w(b"\\)");
                    self.render_close_tag(b"span");
                }
                TextLeafKind::DisplayMath => {
                    self.render_tag(b"span", id, &[kv(b"class", b"math display")]);
                    self.w(b"\\[");
                    self.write_escaped(text);
                    self.w(b"\\]");
                    self.render_close_tag(b"span");
                }
                TextLeafKind::Url => self.render_url_or_email(id, text, false),
                TextLeafKind::Email => self.render_url_or_email(id, text, true),
                TextLeafKind::FootnoteReference => {
                    let label = text;
                    let idx = self.footnote_index_for(label);
                    let id_text = format!("fnref{idx}").into_bytes();
                    let href_text = format!("#fn{idx}").into_bytes();
                    let mut extra: Vec<KV<'_>> = Vec::with_capacity(3);
                    if !self.fnref_id_emitted.contains(label.as_slice()) {
                        extra.push(kv(b"id", &id_text));
                        self.fnref_id_emitted.insert(label.clone());
                    }
                    extra.push(kv(b"href", &href_text));
                    extra.push(kv(b"role", b"doc-noteref"));
                    self.render_tag(b"a", id, &extra);
                    self.w(b"<sup>");
                    self.w(idx.to_string().as_bytes());
                    self.w(b"</sup></a>");
                }
                // A citation reference links to the in-place `.citation`
                // block by its label — the label IS the marker.
                TextLeafKind::CitationReference => {
                    let mut href = b"#".to_vec();
                    href.extend_from_slice(text);
                    self.render_tag(b"a", id, &[kv(b"href", &href), kv(b"role", b"doc-biblioref")]);
                    self.wb(b'[');
                    self.write_escaped(text);
                    self.w(b"]</a>");
                }
                // Unresolved: written back in its rST spelling.
                TextLeafKind::SubstitutionReference => {
                    self.wb(b'|');
                    self.write_escaped(text);
                    self.wb(b'|');
                }
            },
            Kind::Table => {
                if self.options.table_sections {
                    self.render_sectioned_table(id)?;
                } else {
                    self.in_tags(b"table", id, 2, &[])?;
                }
            }
            Kind::Caption => {
                if ast.node(id).first_child.is_some() {
                    self.in_tags(b"caption", id, 1, &[])?;
                }
            }
            Kind::Row { .. } => self.in_tags(b"tr", id, 2, &[])?,
            Kind::Cell(v) => {
                let col = v.colspan.to_string().into_bytes();
                let row = v.rowspan.to_string().into_bytes();
                let mut extra: Vec<KV<'_>> = Vec::with_capacity(3);
                if v.alignment != Alignment::Default {
                    extra.push(if self.options.gfm_cell_align_attr {
                        kv(b"align", align_name(v.alignment))
                    } else {
                        kv(b"style", align_style(v.alignment))
                    });
                }
                // An extent of 1 is the default; written only when it isn't.
                if v.colspan != 1 {
                    extra.push(kv(b"colspan", &col));
                }
                if v.rowspan != 1 {
                    extra.push(kv(b"rowspan", &row));
                }
                self.in_tags(if v.head { b"th" } else { b"td" }, id, 1, &extra)?;
            }
            Kind::ThematicBreak => {
                self.render_tag(b"hr", id, &[]);
                self.wb(b'\n');
            }
            Kind::CodeBlock { lang, text } => {
                self.render_tag(b"pre", id, &[]);
                self.w(b"<code");
                if let Some(lang) = lang {
                    self.w(b" class=\"language-");
                    self.write_escaped_attr(lang);
                    self.wb(b'"');
                }
                self.wb(b'>');
                self.write_escaped(text);
                self.render_close_tag(b"code");
                self.render_close_tag(b"pre");
                self.wb(b'\n');
            }
            Kind::RawBlock { format, text } => {
                if format == b"html" {
                    self.write_raw_html(text);
                }
            }
            Kind::Metadata { lang, text } => {
                // Raw-text refusal guard: a `</script` in the body would end
                // the element early. Raw text has no escape, so refuse.
                if find_ignore_case(text, b"</script") {
                    return Err(RenderError::UnsafeMetadata);
                }
                // Inert, self-describing data island: `application/<lang>`.
                self.w(b"<script type=\"application/");
                self.write_escaped_attr(lang);
                self.w(b"\">\n");
                self.w(text);
                self.w(b"</script>\n");
            }
            Kind::Str(text) => {
                if !ast.attrs_of(id).is_empty() {
                    self.render_tag(b"span", id, &[]);
                    self.write_escaped(text);
                    self.w(b"</span>");
                } else {
                    self.write_escaped(text);
                }
            }
            Kind::SmartPunctuation(v) => self.w(smart_punct(*v).as_bytes()),
            Kind::InlineMark(m) => match m {
                InlineMark::Emph => self.in_tags(b"em", id, 0, &[])?,
                InlineMark::Strong => self.in_tags(b"strong", id, 0, &[])?,
                InlineMark::Mark => self.in_tags(b"mark", id, 0, &[])?,
                InlineMark::Superscript => self.in_tags(b"sup", id, 0, &[])?,
                InlineMark::Subscript => self.in_tags(b"sub", id, 0, &[])?,
                InlineMark::Insert => self.in_tags(b"ins", id, 0, &[])?,
                InlineMark::Delete => self.in_tags(b"del", id, 0, &[])?,
                InlineMark::DoubleQuoted => {
                    self.w(smart_punct(SmartPunctuationKind::LeftDoubleQuote).as_bytes());
                    self.render_children(id)?;
                    self.w(smart_punct(SmartPunctuationKind::RightDoubleQuote).as_bytes());
                }
                InlineMark::SingleQuoted => {
                    self.w(smart_punct(SmartPunctuationKind::LeftSingleQuote).as_bytes());
                    self.render_children(id)?;
                    self.w(smart_punct(SmartPunctuationKind::RightSingleQuote).as_bytes());
                }
            },
            Kind::RawInline { format, text } => {
                if format == b"html" {
                    self.write_raw_html(text);
                }
            }
            Kind::SoftBreak => self.wb(b'\n'),
            Kind::HardBreak => {
                let s: &[u8] = if self.options.xhtml_void { b"<br />\n" } else { b"<br>\n" };
                self.w(s);
            }
            Kind::NonBreakingSpace => self.w(b"&nbsp;"),
            Kind::Link(v) => self.render_link_or_image(id, v, false)?,
            Kind::Image(v) => self.render_link_or_image(id, v, true)?,
            Kind::MarkupLeaf { kind, text } => match kind {
                MarkupLeafKind::Comment => {
                    self.w(b"<!--");
                    self.w(text);
                    self.w(b"-->");
                }
                MarkupLeafKind::Doctype => {
                    self.w(b"<!DOCTYPE");
                    self.w(text);
                    self.wb(b'>');
                }
                MarkupLeafKind::Cdata => self.write_escaped(text),
            },
            Kind::ProcessingInstruction { target, data } => {
                self.w(b"<?");
                self.w(target);
                if !data.is_empty() {
                    self.wb(b' ');
                    self.w(data);
                }
                self.wb(b'>');
            }
            // A citation is rendered IN PLACE, unlike a footnote (docutils'
            // HTML5 writer shape).
            Kind::Citation { label } => {
                self.w(b"<div class=\"citation\" role=\"doc-biblioentry\" id=\"");
                self.write_escaped(label);
                self.w(b"\">\n<span class=\"label\">[");
                self.write_escaped(label);
                self.w(b"]</span>\n");
                self.render_children(id)?;
                self.w(b"</div>\n");
            }
            // `footnote`/`reference` definitions render via the side tables;
            // `substitution` and `column` produce nothing.
            Kind::Footnote { .. }
            | Kind::Reference { .. }
            | Kind::Substitution { .. }
            | Kind::Column
            | Kind::Line { .. } => {}
        }
        Ok(())
    }

    /// docutils' HTML5 writer's spelling: `<div class="line-block">` around
    /// the whole thing, `<div class="line">` per line, the indent spelled as
    /// extra nested `line-block` divs.
    fn render_line_block(&mut self, id: NodeId) -> Result<(), RenderError> {
        const LINE_BLOCK_DIV: &[u8] = b"<div class=\"line-block\">\n";
        self.render_tag(b"div", id, &[kv(b"class", b"line-block")]);
        self.wb(b'\n');
        let mut depth: u32 = 0;
        let mut c = self.ast.node(id).first_child;
        while let Some(cid) = c {
            let indent = match self.ast.kind(cid) {
                Kind::Line { indent } => *indent,
                _ => 0,
            };
            while depth < indent {
                self.w(LINE_BLOCK_DIV);
                depth += 1;
            }
            while depth > indent {
                self.w(b"</div>\n");
                depth -= 1;
            }
            self.w(b"<div class=\"line\">");
            self.render_children(cid)?;
            self.w(b"</div>\n");
            c = self.ast.node(cid).next_sibling;
        }
        while depth > 0 {
            self.w(b"</div>\n");
            depth -= 1;
        }
        self.render_close_tag(b"div");
        self.wb(b'\n');
        Ok(())
    }

    /// The plain-text content of a node's children (an image's `alt` text),
    /// excluding footnote references — djot.js's `getStringContent`.
    pub fn string_content(&self, id: NodeId) -> Vec<u8> {
        let mut buf = Vec::new();
        self.add_string_content(id, &mut buf);
        buf
    }

    fn add_string_content(&self, id: NodeId, buf: &mut Vec<u8>) {
        for child in self.ast.children(id) {
            match &child.kind {
                Kind::Str(t) => buf.extend_from_slice(t),
                Kind::TextLeaf { kind, text } => {
                    if *kind != TextLeafKind::FootnoteReference {
                        buf.extend_from_slice(text)
                    }
                }
                Kind::RawInline { text, .. } => buf.extend_from_slice(text),
                Kind::CodeBlock { text, .. } => buf.extend_from_slice(text),
                Kind::RawBlock { text, .. } => buf.extend_from_slice(text),
                Kind::SmartPunctuation(v) => buf.extend_from_slice(v.ascii().as_bytes()),
                Kind::SoftBreak | Kind::HardBreak => buf.push(b'\n'),
                _ => self.add_string_content(child.id, buf),
            }
        }
    }

    /// Percent-encode a URL per `RenderOptions::percent_encode_urls`.
    fn href_value(&self, raw: &[u8]) -> Vec<u8> {
        if !self.options.percent_encode_urls {
            return raw.to_vec();
        }
        percent_encode_href(raw)
    }

    fn render_link_or_image(&mut self, id: NodeId, v: &Link, is_image: bool) -> Result<(), RenderError> {
        let ast = self.ast;
        let dest: Option<&[u8]> = v.destination.as_deref();
        // Owned values first, so the `KV`s can borrow them.
        let mut src_val: Option<Vec<u8>> = None;
        let mut alt: Option<Vec<u8>> = None;
        let mut ref_extra: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
        // 0: nothing; 1: href; 2: alt,src; 3: src,alt; 4: alt only
        let mut shape = 0u8;

        if let Some(r) = &v.reference {
            let resolved = self.labels.and_then(|l| l.reference(r));
            if let Some(ref_id) = resolved {
                let ref_attrs = ast.attrs_of(ref_id);
                let ref_dest: &[u8] = match ast.kind(ref_id) {
                    Kind::Reference { destination, .. } => destination,
                    _ => panic!("label resolved to a non-reference node"),
                };
                src_val = Some(self.href_value(ref_dest));
                if is_image {
                    alt = Some(self.string_content(id));
                    shape = if self.options.commonmark_image_attrs { 3 } else { 2 };
                } else {
                    shape = 1;
                }
                let own_attrs = ast.attrs_of(id);
                for kvp in &ref_attrs.entries {
                    if own_attrs.get(&kvp.key).is_none() {
                        // Reference-definition attrs come from djot syntax,
                        // which can't express a bare attribute.
                        let value = kvp.value.clone().expect("reference attr has a value");
                        ref_extra.push((kvp.key.clone(), value));
                    }
                }
            } else {
                self.warn("reference not found");
            }
        } else if is_image {
            alt = Some(self.string_content(id));
            if let Some(d) = dest {
                src_val = Some(self.href_value(d));
                shape = if self.options.commonmark_image_attrs { 3 } else { 2 };
            } else {
                shape = 4;
            }
        } else if let Some(d) = dest {
            src_val = Some(self.href_value(d));
            shape = 1;
        }

        let mut extra: Vec<KV<'_>> = Vec::new();
        match shape {
            1 => extra.push(kv(b"href", src_val.as_deref().unwrap())),
            2 => {
                extra.push(kv(b"alt", alt.as_deref().unwrap()));
                extra.push(kv(b"src", src_val.as_deref().unwrap()));
            }
            3 => {
                extra.push(kv(b"src", src_val.as_deref().unwrap()));
                extra.push(kv(b"alt", alt.as_deref().unwrap()));
            }
            4 => extra.push(kv(b"alt", alt.as_deref().unwrap())),
            _ => {}
        }
        for (k, val) in &ref_extra {
            extra.push(kv(k, val));
        }

        if is_image {
            self.render_tag(b"img", id, &extra);
            Ok(())
        } else {
            self.in_tags(b"a", id, 0, &extra)
        }
    }

    fn render_url_or_email(&mut self, id: NodeId, text: &[u8], is_email: bool) {
        // Zig formats `mailto:` into a 512-byte buffer and falls back to the
        // bare text when it doesn't fit.
        let raw_href: Vec<u8> = if is_email && 7 + text.len() <= 512 {
            let mut v = b"mailto:".to_vec();
            v.extend_from_slice(text);
            v
        } else {
            text.to_vec()
        };
        let href = self.href_value(&raw_href);
        self.render_tag(b"a", id, &[kv(b"href", &href)]);
        self.write_escaped(text);
        self.render_close_tag(b"a");
    }
}

/// Write `id` (and its descendants) as HTML to `out`. `ctx` is the
/// document's `labels` when the tree resolves anything by label.
pub fn serialize_node(ast: &Ast, id: NodeId, out: &mut Vec<u8>, ctx: Option<&Context>) -> Result<(), RenderError> {
    serialize_node_opts(ast, id, out, ctx, RenderOptions::DEFAULT)
}

/// Like [`serialize_node`], with explicit render-convention `options`.
pub fn serialize_node_opts(
    ast: &Ast,
    id: NodeId,
    out: &mut Vec<u8>,
    ctx: Option<&Context>,
    options: RenderOptions,
) -> Result<(), RenderError> {
    let mut r = Renderer::new(ast, out, ctx, options);
    r.render_node(id)
}

/// Serialize the whole tree (from `ast.root`) to `out`.
pub fn serialize(ast: &Ast, out: &mut Vec<u8>, ctx: Option<&Context>) -> Result<(), RenderError> {
    serialize_node_opts(ast, ast.root, out, ctx, RenderOptions::DEFAULT)
}

/// Like [`serialize`], with explicit render-convention `options`.
pub fn serialize_opts(ast: &Ast, out: &mut Vec<u8>, ctx: Option<&Context>, options: RenderOptions) -> Result<(), RenderError> {
    serialize_node_opts(ast, ast.root, out, ctx, options)
}

/// Convenience wrapper: serialize to an owned buffer.
pub fn serialize_alloc(ast: &Ast, ctx: Option<&Context>) -> Result<Vec<u8>, RenderAllocError> {
    serialize_alloc_opts(ast, ctx, RenderOptions::DEFAULT)
}

/// Like [`serialize_alloc`], with explicit render-convention `options`.
pub fn serialize_alloc_opts(ast: &Ast, ctx: Option<&Context>, options: RenderOptions) -> Result<Vec<u8>, RenderAllocError> {
    let mut out = Vec::new();
    serialize_opts(ast, &mut out, ctx, options)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Attrs, Builder, Cell, Container, KeyVal};

    fn s(b: &mut Builder, t: &str) -> NodeId {
        b.add_leaf(Kind::Str(t.as_bytes().to_vec()))
    }

    fn render(b: Builder, root: NodeId) -> String {
        let ast = b.finish(root);
        String::from_utf8(serialize_alloc(&ast, None).unwrap()).unwrap()
    }

    #[test]
    fn renders_a_simple_paragraph_with_emphasis() {
        let mut b = Builder::new();
        let s1 = s(&mut b, "hello ");
        let t = s(&mut b, "world");
        let em = b.add_container(Kind::InlineMark(InlineMark::Emph), &[t]);
        let para = b.add_container(Kind::Para, &[s1, em]);
        let root = b.add_container(Kind::Doc, &[para]);
        assert_eq!(render(b, root), "<p>hello <em>world</em></p>\n");
    }

    #[test]
    fn element_with_children_round_trips_as_an_open_close_pair() {
        let mut b = Builder::new();
        let t = s(&mut b, "hi");
        let el = b.add_container(Kind::Container(Container::named(b"video")), &[t]);
        b.set_content_span(el, crate::span::Span::new(0, 2));
        assert_eq!(render(b, el), "<video>hi</video>");
    }

    #[test]
    fn self_closing_non_void_element_gets_explicit_close_tag() {
        let mut b = Builder::new();
        let el = b.add_leaf(Kind::Container(Container::named(b"video")));
        assert_eq!(render(b, el), "<video></video>");
    }

    #[test]
    fn void_element_renders_with_no_close_tag() {
        let mut b = Builder::new();
        let el = b.add_leaf(Kind::Container(Container::named(b"br")));
        assert_eq!(render(b, el), "<br>");
    }

    #[test]
    fn bare_attribute_on_generic_element_renders_as_just_its_key() {
        let mut b = Builder::new();
        let el = b.add_leaf(Kind::Container(Container::named(b"input")));
        b.set_attrs(el, Attrs { entries: vec![KeyVal::new(b"disabled", None), KeyVal::new(b"type", Some(b"checkbox"))] });
        assert_eq!(render(b, el), "<input disabled type=\"checkbox\">");
    }

    #[test]
    fn bare_attribute_on_para() {
        let mut b = Builder::new();
        let t = s(&mut b, "x");
        let para = b.add_container(Kind::Para, &[t]);
        b.set_attrs(para, Attrs { entries: vec![KeyVal::new(b"disabled", None), KeyVal::new(b"id", Some(b"y"))] });
        assert_eq!(render(b, para), "<p disabled id=\"y\">x</p>\n");
    }

    #[test]
    fn comment_renders_verbatim() {
        let mut b = Builder::new();
        let c = b.add_leaf(Kind::MarkupLeaf { kind: MarkupLeafKind::Comment, text: b" a <b> & c ".to_vec() });
        assert_eq!(render(b, c), "<!-- a <b> & c -->");
    }

    #[test]
    fn doctype_renders() {
        let mut b = Builder::new();
        let c = b.add_leaf(Kind::MarkupLeaf { kind: MarkupLeafKind::Doctype, text: b" html".to_vec() });
        assert_eq!(render(b, c), "<!DOCTYPE html>");
    }

    #[test]
    fn processing_instruction_renders_bogus_comment_shape() {
        let mut b = Builder::new();
        let c = b.add_leaf(Kind::ProcessingInstruction {
            target: b"xml-stylesheet".to_vec(),
            data: b"href=\"x.xsl\"".to_vec(),
        });
        assert_eq!(render(b, c), "<?xml-stylesheet href=\"x.xsl\">");
    }

    #[test]
    fn cdata_renders_escaped() {
        let mut b = Builder::new();
        let c = b.add_leaf(Kind::MarkupLeaf { kind: MarkupLeafKind::Cdata, text: b"a < b & c".to_vec() });
        assert_eq!(render(b, c), "a &lt; b &amp; c");
    }

    #[test]
    fn merged_cell_writes_colspan_rowspan() {
        let mut b = Builder::new();
        let mt = s(&mut b, "wide");
        let merged = b.add_container(
            Kind::Cell(Cell { head: false, alignment: Alignment::Center, colspan: 2, rowspan: 3 }),
            &[mt],
        );
        let pt = s(&mut b, "one");
        let plain = b.add_container(Kind::Cell(Cell::new(false, Alignment::Default)), &[pt]);
        let row = b.add_container(Kind::Row { head: false }, &[merged, plain]);
        let table = b.add_container(Kind::Table, &[row]);
        assert_eq!(
            render(b, table),
            "<table>\n<tr>\n<td style=\"text-align: center;\" colspan=\"2\" rowspan=\"3\">wide</td>\n<td>one</td>\n</tr>\n</table>\n"
        );
    }

    #[test]
    fn line_block_indents_render_as_nested_divs() {
        let mut b = Builder::new();
        let t0 = s(&mut b, "flush");
        let l0 = b.add_container(Kind::Line { indent: 0 }, &[t0]);
        let t2 = s(&mut b, "deep");
        let l2 = b.add_container(Kind::Line { indent: 2 }, &[t2]);
        let t1 = s(&mut b, "less");
        let l1 = b.add_container(Kind::Line { indent: 1 }, &[t1]);
        let gap = b.add_container(Kind::Line { indent: 0 }, &[]);
        let block = b.add_container(Kind::LineBlock, &[l0, l2, l1, gap]);
        let doc = b.add_container(Kind::Doc, &[block]);
        assert_eq!(
            render(b, doc),
            "<div class=\"line-block\">\n<div class=\"line\">flush</div>\n<div class=\"line-block\">\n<div class=\"line-block\">\n<div class=\"line\">deep</div>\n</div>\n<div class=\"line\">less</div>\n</div>\n<div class=\"line\"></div>\n</div>\n"
        );
    }

    #[test]
    fn citation_renders_in_place() {
        let mut b = Builder::new();
        let r = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::CitationReference, text: b"CIT2002".to_vec() });
        let see = s(&mut b, "see ");
        let body = b.add_container(Kind::Para, &[see, r]);
        let dt = s(&mut b, "Deep Thought.");
        let note = b.add_container(Kind::Para, &[dt]);
        let cit = b.add_container(Kind::Citation { label: b"CIT2002".to_vec() }, &[note]);
        let doc = b.add_container(Kind::Doc, &[body, cit]);
        assert_eq!(
            render(b, doc),
            "<p>see <a href=\"#CIT2002\" role=\"doc-biblioref\">[CIT2002]</a></p>\n<div class=\"citation\" role=\"doc-biblioentry\" id=\"CIT2002\">\n<span class=\"label\">[CIT2002]</span>\n<p>Deep Thought.</p>\n</div>\n"
        );
    }

    #[test]
    fn unresolved_substitution_keeps_rst_spelling() {
        let mut b = Builder::new();
        let r = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::SubstitutionReference, text: b"RST".to_vec() });
        let rules = s(&mut b, " rules");
        let body = b.add_container(Kind::Para, &[r, rules]);
        let rt = s(&mut b, "reStructuredText");
        let def = b.add_container(Kind::Substitution { label: b"RST".to_vec() }, &[rt]);
        let doc = b.add_container(Kind::Doc, &[body, def]);
        assert_eq!(render(b, doc), "<p>|RST| rules</p>\n");
    }

    #[test]
    fn metadata_with_script_close_is_refused() {
        let mut b = Builder::new();
        let m = b.add_leaf(Kind::Metadata { lang: b"yaml".to_vec(), text: b"a: </SCRIPT>\n".to_vec() });
        let doc = b.add_container(Kind::Doc, &[m]);
        let ast = b.finish(doc);
        assert_eq!(serialize_alloc(&ast, None), Err(RenderError::UnsafeMetadata));
    }

    #[test]
    fn tagfilter_escapes_only_blacklisted_tags() {
        let mut b = Builder::new();
        let r = b.add_leaf(Kind::RawInline { format: b"html".to_vec(), text: b"<title><titlepage></SCRIPT>".to_vec() });
        let p = b.add_container(Kind::Para, &[r]);
        let ast = b.finish(p);
        let out = serialize_alloc_opts(&ast, None, super::super::GFM_RENDER_OPTIONS).unwrap();
        assert_eq!(out, b"<p>&lt;title><titlepage>&lt;/SCRIPT></p>\n");
    }

    #[test]
    fn footnotes_render_in_reference_order() {
        let mut b = Builder::new();
        let r1 = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::FootnoteReference, text: b"b".to_vec() });
        let r2 = b.add_leaf(Kind::TextLeaf { kind: TextLeafKind::FootnoteReference, text: b"a".to_vec() });
        let p = b.add_container(Kind::Para, &[r1, r2]);
        let ta = s(&mut b, "A");
        let pa = b.add_container(Kind::Para, &[ta]);
        let fa = b.add_container(Kind::Footnote { label: b"a".to_vec() }, &[pa]);
        let tb = s(&mut b, "B");
        let pb = b.add_container(Kind::Para, &[tb]);
        let fb = b.add_container(Kind::Footnote { label: b"b".to_vec() }, &[pb]);
        let doc = b.add_container(Kind::Doc, &[p]);
        let ast = b.finish(doc);
        let mut labels = Labels::default();
        labels.footnotes.insert(b"a".to_vec(), fa);
        labels.footnotes.insert(b"b".to_vec(), fb);
        let out = String::from_utf8(serialize_alloc(&ast, Some(&labels)).unwrap()).unwrap();
        assert_eq!(
            out,
            "<p><a id=\"fnref1\" href=\"#fn1\" role=\"doc-noteref\"><sup>1</sup></a><a id=\"fnref2\" href=\"#fn2\" role=\"doc-noteref\"><sup>2</sup></a></p>\n<section role=\"doc-endnotes\">\n<hr>\n<ol>\n<li id=\"fn1\">\n<p>B<a href=\"#fnref1\" role=\"doc-backlink\">\u{21A9}\u{FE0E}</a></p>\n</li>\n<li id=\"fn2\">\n<p>A<a href=\"#fnref2\" role=\"doc-backlink\">\u{21A9}\u{FE0E}</a></p>\n</li>\n</ol>\n</section>\n"
        );
    }
}
