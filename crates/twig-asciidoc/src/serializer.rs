//! Twig's shared `Ast` -> AsciiDoc text — `convert -o asciidoc`, and
//! `-o canonical` for a document that came from AsciiDoc. Port of
//! `src/languages/asciidoc/serializer.zig`.
//!
//! A structural printer: one stable spelling per node kind, never a
//! source-preserving re-emit. It reads only MEANING plus the `Document`'s
//! spelling table; never a span, so a bare tree built by another parser
//! serializes exactly as a parsed one does.
//!
//! ── The spellings ───────────────────────────────────────────────────────────
//! Inline delimiters come from AsciiDoc's syntax table, which holds the
//! UNCONSTRAINED forms (`**`, `__`, `##`, ` `` `); this file writes the
//! constrained single-delimiter form whenever the span sits on word
//! boundaries, and falls back to the doubled form mid-word.
//!
//! Blocks take AsciiDoc's own delimited forms: `====` for an example or an
//! admonition, `____` for a quote or a `[verse]`, `****` for a sidebar,
//! `----` for a listing (widened past any run of dashes in its content),
//! `++++` for a pass block, `|===` for a table, `--` for an open block. Lists
//! use marker DEPTH for nesting and `+` continuation for an attached block.
//!
//! ── What degrades ───────────────────────────────────────────────────────────
//! An `insert`/`delete` mark becomes a role span, a citation an anchor plus
//! its body, a line block a `[verse]`, generic markup a comment block or
//! nothing, a `column` nothing at all.

use std::collections::HashSet;

use crate::ast::{Alignment, Ast, Attrs, Container, Form, InlineMark, KeyVal, Kind, Level, ListNumbering, MarkupLeafKind, NodeId, SmartPunctuationKind, TextLeafKind};
use crate::document::{Bullet, Document, Spelling};

use super::parser::{admonition_name, is_space_byte, is_word_byte, trim, upper_label};

use twig_kit::html::write_element_text;
use twig_kit::syntax::Delims;

/// AsciiDoc's syntax table — the serializer reads its delimiters from it so
/// the serializer and the editor's gestures cannot drift apart.
fn table() -> &'static twig_kit::syntax::Syntax {
    crate::syntax_table::table()
}

fn mark_delims(m: InlineMark) -> Delims {
    *table().inline_delim(m).expect("asciidoc spells every mark")
}

fn verbatim_delims() -> Delims {
    *table().text_leaf_delim(TextLeafKind::Verbatim).expect("asciidoc spells verbatim")
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ListKind {
    Bullet,
    Task,
    Ordered,
}

struct Renderer<'d> {
    ast: &'d Ast,
    spellings: &'d [Option<Spelling>],
    out: Vec<u8>,
    /// The last byte written — what decides whether a constrained span may
    /// open here (not after a word character).
    last: u8,
    bullet_depth: u32,
    ordered_depth: u32,
    dlist_depth: u32,
    /// Enclosing delimited blocks per delimiter byte, so a nested block of
    /// the same kind gets a longer delimiter.
    delim_depth: [u8; 256],
    /// Footnote labels whose body has been written at a reference already.
    footnotes_written: HashSet<Vec<u8>>,
}

const SHORTHAND_KEYS: [&[u8]; 4] = [b"id", b"class", b"options", b"title"];

fn is_skipped(key: &[u8], skip: &[&[u8]]) -> bool {
    SHORTHAND_KEYS.contains(&key) || skip.contains(&key)
}

fn append_attr_value(line: &mut Vec<u8>, v: &[u8]) {
    let needs_quotes = v.iter().any(|c| b", ]\"".contains(c)) || v.is_empty();
    if !needs_quotes {
        line.extend_from_slice(v);
        return;
    }
    line.push(b'"');
    for &c in v {
        if c == b'"' {
            line.push(b'\\');
        }
        line.push(c);
    }
    line.push(b'"');
}

fn tokens<'a>(s: &'a [u8], delims: &'a [u8]) -> impl Iterator<Item = &'a [u8]> + 'a {
    s.split(move |c| delims.contains(c)).filter(|p| !p.is_empty())
}

fn is_list(kind: &Kind) -> bool {
    matches!(kind, Kind::BulletList { .. } | Kind::OrderedList { .. } | Kind::TaskList { .. } | Kind::DefinitionList)
}

fn is_stem_lang(lang: &[u8]) -> bool {
    lang == b"stem" || lang == b"latexmath" || lang == b"asciimath"
}

fn is_all_digits(s: &[u8]) -> bool {
    !s.is_empty() && s.iter().all(|c| c.is_ascii_digit())
}

/// Whether the parser would read `dest` back as a bare URL.
fn is_autolinkable(dest: &[u8]) -> bool {
    for scheme in [&b"https://"[..], b"http://", b"ftp://", b"irc://", b"file://"] {
        if dest.starts_with(scheme) && dest.len() > scheme.len() && !dest.iter().any(|c| b" \t\n[]<>".contains(c)) {
            return true;
        }
    }
    false
}

/// A `bullet_list`'s recorded marker character, canonical `*` when the
/// spelling table has nothing for the node.
fn bullet_of(sp: Option<Spelling>) -> Bullet {
    match sp {
        Some(Spelling::Bullet(b)) => b,
        _ => Bullet::Star,
    }
}

impl<'d> Renderer<'d> {
    fn new(ast: &'d Ast, spellings: &'d [Option<Spelling>]) -> Renderer<'d> {
        Renderer {
            ast,
            spellings,
            out: Vec::new(),
            last: b'\n',
            bullet_depth: 0,
            ordered_depth: 0,
            dlist_depth: 0,
            delim_depth: [0; 256],
            footnotes_written: HashSet::new(),
        }
    }

    fn spelling(&self, id: NodeId) -> Option<Spelling> {
        self.spellings.get(id as usize).copied().flatten()
    }

    fn kind(&self, id: NodeId) -> &'d Kind {
        &self.ast.nodes[id as usize].kind
    }

    fn first_child(&self, id: NodeId) -> Option<NodeId> {
        self.ast.nodes[id as usize].first_child
    }

    fn next_sibling(&self, id: NodeId) -> Option<NodeId> {
        self.ast.nodes[id as usize].next_sibling
    }

    fn children(&self, id: NodeId) -> Vec<NodeId> {
        self.ast.child_ids(id)
    }

    fn attrs(&self, id: NodeId) -> &'d Attrs {
        self.ast.attrs_of(id)
    }

    fn emit(&mut self, s: &[u8]) {
        if s.is_empty() {
            return;
        }
        self.out.extend_from_slice(s);
        self.last = s[s.len() - 1];
    }

    fn emit_byte(&mut self, c: u8) {
        self.out.push(c);
        self.last = c;
    }

    /// A passed-through element's text body, by the tag's HTML rule, with
    /// `last` kept honest.
    fn emit_element_text(&mut self, name: &[u8], text: &[u8]) {
        write_element_text(&mut self.out, name, text);
        if !text.is_empty() {
            self.last = text[text.len() - 1];
        }
    }

    fn emit_repeat(&mut self, c: u8, n: usize) {
        for _ in 0..n {
            self.emit_byte(c);
        }
    }

    fn emit_int(&mut self, n: u32) {
        self.emit(n.to_string().as_bytes());
    }

    // ── blocks ───────────────────────────────────────────────────────────

    fn render_blocks(&mut self, parent: NodeId) {
        let mut prev: Option<NodeId> = None;
        for c in self.children(parent) {
            if let Some(p) = prev {
                self.separate(p, c);
            }
            self.render_block(c);
            prev = Some(c);
        }
    }

    /// The blank line between two blocks — and, between two lists, the empty
    /// attribute line that keeps them apart.
    fn separate(&mut self, prev: NodeId, cur: NodeId) {
        self.emit_byte(b'\n');
        if is_list(self.kind(prev)) && is_list(self.kind(cur)) {
            self.emit(b"[]\n");
        }
    }

    /// The document: a title with its attribute entries directly under it,
    /// then the body.
    fn render_document(&mut self, id: NodeId) {
        let mut pending_attrs: Option<NodeId> = None;
        let mut prev: Option<NodeId> = None;
        for c in self.children(id) {
            let kind = self.kind(c);
            if let Kind::Container(cn) = kind {
                if cn.name == b"document-attributes" {
                    pending_attrs = Some(c);
                    continue;
                }
            }
            if let Some(p) = prev {
                self.separate(p, c);
            }
            prev = Some(c);
            if let Kind::Heading { level: 1 } = kind {
                if let Some(pa) = pending_attrs {
                    self.render_block(c);
                    self.write_attr_entries(pa);
                    pending_attrs = None;
                    continue;
                }
            }
            if let Some(pa) = pending_attrs {
                // Entries with no title to sit under: body attribute entries.
                self.write_attr_entries(pa);
                pending_attrs = None;
                self.emit_byte(b'\n');
            }
            self.render_block(c);
        }
        if let Some(pa) = pending_attrs {
            if prev.is_some() {
                self.emit_byte(b'\n');
            }
            self.write_attr_entries(pa);
        }
    }

    fn write_attr_entries(&mut self, marker: NodeId) {
        for kv in &self.attrs(marker).entries {
            // The author line's implicit attributes are written back as
            // entries too: Asciidoctor accepts `:author:` and friends.
            self.emit_byte(b':');
            if kv.value.is_none() {
                self.emit_byte(b'!');
            }
            self.emit(&kv.key);
            self.emit_byte(b':');
            if let Some(v) = &kv.value {
                if !v.is_empty() {
                    self.emit_byte(b' ');
                    self.emit(v);
                }
            }
            self.emit_byte(b'\n');
        }
    }

    fn write_block_attrs(&mut self, id: NodeId, style: Option<&[u8]>, positional: &[Option<&[u8]>], skip: &[&[u8]]) {
        self.write_block_attrs_with(id, style, positional, skip, &[]);
    }

    /// `.Title` and `[style#id.role%opt,pos2,pos3,key=value]` for `id`, from
    /// its attributes, plus named entries of the caller's own (`start=3`).
    fn write_block_attrs_with(
        &mut self,
        id: NodeId,
        style: Option<&[u8]>,
        positional: &[Option<&[u8]>],
        skip: &[&[u8]],
        extra: &[KeyVal],
    ) {
        let a = self.attrs(id);
        if let Some(t) = a.get(b"title") {
            self.emit_byte(b'.');
            self.emit(t);
            self.emit_byte(b'\n');
        }
        let mut line: Vec<u8> = Vec::new();
        if let Some(s) = style {
            line.extend_from_slice(s);
        }
        if let Some(i) = a.get(b"id") {
            line.push(b'#');
            line.extend_from_slice(i);
        }
        if let Some(cls) = a.get(b"class") {
            for r in tokens(cls, b" ") {
                line.push(b'.');
                line.extend_from_slice(r);
            }
        }
        if let Some(opts) = a.get(b"options") {
            for o in tokens(opts, b", ") {
                line.push(b'%');
                line.extend_from_slice(o);
            }
        }
        // Positional slots two onward: the caller's, then any `$N` the parser kept.
        let mut slots: Vec<Option<&[u8]>> = positional.to_vec();
        for kv in &a.entries {
            if kv.key.len() < 2 || kv.key[0] != b'$' {
                continue;
            }
            let Some(n) = super::parser::zig_parse_uint(&kv.key[1..], 10, u64::MAX) else { continue };
            let n = n as usize;
            if n < 2 {
                continue;
            }
            while slots.len() < n - 1 {
                slots.push(None);
            }
            if slots[n - 2].is_none() {
                slots[n - 2] = kv.value.as_deref();
            }
        }
        // Trailing empty slots are dropped; interior ones stay as `,,`.
        let mut used = slots.len();
        while used > 0 && slots[used - 1].is_none() {
            used -= 1;
        }
        for slot in &slots[..used] {
            line.push(b',');
            if let Some(v) = slot {
                append_attr_value(&mut line, v);
            }
        }
        for kv in extra {
            if !line.is_empty() {
                line.push(b',');
            }
            line.extend_from_slice(&kv.key);
            if let Some(v) = &kv.value {
                line.push(b'=');
                append_attr_value(&mut line, v);
            }
        }
        for kv in &a.entries {
            if !kv.key.is_empty() && kv.key[0] == b'$' {
                continue;
            }
            if is_skipped(&kv.key, skip) {
                continue;
            }
            if !line.is_empty() {
                line.push(b',');
            }
            line.extend_from_slice(&kv.key);
            if let Some(v) = &kv.value {
                line.push(b'=');
                append_attr_value(&mut line, v);
            }
        }
        if line.is_empty() {
            return;
        }
        self.emit_byte(b'[');
        self.emit(&line);
        self.emit(b"]\n");
    }

    /// A delimiter line of `c`, one longer per enclosing block of the same
    /// byte, and — for a listing — longer than any run of `c` in `body`.
    fn delimiter(&mut self, c: u8, body: Option<&[u8]>) {
        let mut n: usize = 4 + self.delim_depth[c as usize] as usize;
        if let Some(b) = body {
            let mut i = 0;
            while i < b.len() {
                if b[i] != c {
                    i += 1;
                    continue;
                }
                let at_line_start = i == 0 || b[i - 1] == b'\n';
                let mut j = i;
                while j < b.len() && b[j] == c {
                    j += 1;
                }
                if at_line_start && j - i >= n {
                    n = j - i + 1;
                }
                i = j + 1;
            }
        }
        self.emit_repeat(c, n);
        self.emit_byte(b'\n');
    }

    /// `[style]` line, opening delimiter, the children as blocks, closing
    /// delimiter.
    fn delimited_parent(&mut self, id: NodeId, c: u8, style: Option<&[u8]>, positional: &[Option<&[u8]>], skip: &[&[u8]]) {
        self.write_block_attrs(id, style, positional, skip);
        self.delimiter(c, None);
        self.delim_depth[c as usize] = self.delim_depth[c as usize].wrapping_add(1);
        self.render_blocks(id);
        self.delim_depth[c as usize] = self.delim_depth[c as usize].wrapping_sub(1);
        self.delimiter(c, None);
    }

    fn delimited_leaf(&mut self, id: NodeId, c: u8, style: Option<&[u8]>, positional: &[Option<&[u8]>], text: &[u8]) {
        self.write_block_attrs(id, style, positional, &[]);
        self.delimiter(c, Some(text));
        if !text.is_empty() {
            self.emit(text);
        }
        if text.is_empty() || text[text.len() - 1] != b'\n' {
            self.emit_byte(b'\n');
        }
        self.delimiter(c, Some(text));
    }

    fn render_block(&mut self, id: NodeId) {
        let kind = self.kind(id);
        match kind {
            Kind::Doc => self.render_document(id),
            Kind::Section => self.render_blocks(id),
            Kind::Para => {
                // A paragraph holding one image is the block macro.
                if let Some(only) = self.first_child(id) {
                    if self.next_sibling(only).is_none() && matches!(self.kind(only), Kind::Image(_)) {
                        self.write_block_attrs(id, None, &[], &[]);
                        self.emit(b"image::");
                        self.image_macro(only);
                        self.emit_byte(b'\n');
                        return;
                    }
                }
                self.write_block_attrs(id, None, &[], &[]);
                self.render_inline_children(id);
                self.emit_byte(b'\n');
            }
            Kind::Heading { level } => {
                self.write_block_attrs(id, None, &[], &[]);
                self.emit_repeat(b'=', *level as usize);
                self.emit_byte(b' ');
                self.render_inline_children(id);
                self.emit_byte(b'\n');
            }
            Kind::ThematicBreak => {
                self.write_block_attrs(id, None, &[], &[]);
                self.emit(table().thematic_break.expect("asciidoc spells a thematic break"));
                self.emit_byte(b'\n');
            }
            Kind::BlockQuote => {
                // `____` already means a quote; the style word is only needed
                // to position an attribution after it.
                let a = self.attrs(id);
                let cited = a.get(b"attribution").is_some() || a.get(b"citetitle").is_some();
                self.delimited_parent(
                    id,
                    b'_',
                    if cited { Some(b"quote") } else { None },
                    &[a.get(b"attribution"), a.get(b"citetitle")],
                    &[b"attribution", b"citetitle"],
                );
            }
            Kind::BulletList { .. } => self.render_list(id, ListKind::Bullet),
            Kind::TaskList { .. } => self.render_list(id, ListKind::Task),
            Kind::OrderedList { .. } => self.render_list(id, ListKind::Ordered),
            Kind::DefinitionList => {
                self.write_block_attrs(id, None, &[], &[]);
                self.dlist_depth += 1;
                for item in self.children(id) {
                    self.render_definition_item(item);
                }
                self.dlist_depth -= 1;
            }
            Kind::LineBlock => {
                let a = self.attrs(id);
                self.write_block_attrs(
                    id,
                    Some(b"verse"),
                    &[a.get(b"attribution"), a.get(b"citetitle")],
                    &[b"attribution", b"citetitle"],
                );
                self.delimiter(b'_', None);
                for line in self.children(id) {
                    let indent = match self.kind(line) {
                        Kind::Line { indent } => *indent,
                        _ => 0,
                    };
                    self.emit_repeat(b' ', (indent * 2) as usize);
                    self.render_inline_children(line);
                    self.emit_byte(b'\n');
                }
                self.delimiter(b'_', None);
            }
            Kind::Table => self.render_table(id),
            Kind::CodeBlock { lang, text } => match lang {
                Some(lang) => {
                    if is_stem_lang(lang) {
                        self.delimited_leaf(id, b'+', Some(lang), &[], text);
                    } else {
                        self.delimited_leaf(id, b'-', Some(b"source"), &[Some(lang)], text);
                    }
                }
                None => self.delimited_leaf(id, b'-', None, &[], text),
            },
            Kind::RawBlock { text, .. } => self.delimited_leaf(id, b'+', None, &[], text),
            Kind::Metadata { text, .. } => {
                // Front matter, in the one spelling Asciidoctor skips over.
                self.emit(b"---\n");
                if !text.is_empty() {
                    self.emit(text);
                }
                if text.is_empty() || text[text.len() - 1] != b'\n' {
                    self.emit_byte(b'\n');
                }
                self.emit(b"---\n");
            }
            Kind::Container(c) => self.render_container_block(id, c),
            // Written at their uses (footnotes) or resolved into them
            // (references); a citation is an anchor over its body.
            Kind::Footnote { .. } | Kind::Reference { .. } => {}
            Kind::Citation { label } => {
                self.emit(b"[[");
                self.emit(label);
                self.emit(b"]]\n");
                self.render_blocks(id);
            }
            Kind::Substitution { label } => {
                self.emit_byte(b':');
                if self.attrs(id).find(b"unset").is_some() {
                    self.emit_byte(b'!');
                }
                self.emit(label);
                self.emit_byte(b':');
                if self.first_child(id).is_some() {
                    self.emit_byte(b' ');
                    self.render_inline_children(id);
                }
                self.emit_byte(b'\n');
            }
            Kind::MarkupLeaf { kind: lk, text } => match lk {
                MarkupLeafKind::Comment => {
                    self.emit(b"////\n");
                    self.emit(trim(text, b"\n"));
                    self.emit(b"\n////\n");
                }
                // No AsciiDoc spelling: the text of a CDATA section is kept,
                // a doctype is not.
                MarkupLeafKind::Cdata => {
                    self.emit(text);
                    self.emit_byte(b'\n');
                }
                MarkupLeafKind::Doctype => {}
            },
            Kind::ProcessingInstruction { .. } | Kind::Column => {}
            Kind::ListItem
            | Kind::TaskListItem { .. }
            | Kind::DefinitionListItem
            | Kind::Term
            | Kind::Definition
            | Kind::Row { .. }
            | Kind::Cell(_)
            | Kind::Caption
            | Kind::Line { .. } => self.render_blocks(id),
            _ => {
                self.render_inline(id);
                self.emit_byte(b'\n');
            }
        }
    }

    fn render_container_block(&mut self, id: NodeId, c: &Container) {
        let name: &[u8] = &c.name;
        if name == b"page-break" {
            self.emit(b"<<<\n");
            return;
        }
        if name == b"document-attributes" {
            self.write_attr_entries(id);
            return;
        }
        let Some(form) = c.form else {
            // An HTML/XML element passing through: written as a tag.
            self.emit_byte(b'<');
            self.emit(name);
            self.write_html_attrs(id);
            self.emit(b">\n");
            match &c.text {
                Some(text) => self.emit_element_text(name, text),
                None => self.render_blocks(id),
            }
            self.emit(b"</");
            self.emit(name);
            self.emit(b">\n");
            return;
        };
        if form == Form::InlineText {
            self.render_inline(id);
            self.emit_byte(b'\n');
            return;
        }
        // Admonitions: the container named by its variant.
        if admonition_name(upper_label(name)).is_some() {
            self.delimited_parent(id, b'=', Some(upper_label(name)), &[], &[]);
            return;
        }
        if name == b"example" {
            return self.delimited_parent(id, b'=', None, &[], &[]);
        }
        if name == b"sidebar" {
            return self.delimited_parent(id, b'*', None, &[], &[]);
        }
        if name == b"open" {
            return self.open_block(id, None);
        }
        if form == Form::BlockLeaf && (name == b"audio" || name == b"video" || name == b"toc") {
            self.write_block_attrs(id, None, &[], &[b"poster", b"width", b"height"]);
            self.emit(name);
            self.emit(b"::");
            if let Some(arg) = &c.argument {
                self.emit(arg);
            }
            self.emit_byte(b'[');
            let a = self.attrs(id);
            if name == b"video" {
                self.emit_positional(&[a.get(b"poster"), a.get(b"width"), a.get(b"height")]);
            } else {
                // The parser keeps a first positional these macros give no
                // name as `$1`; only the macro's own brackets can spell it,
                // a block list's first slot being its style.
                self.emit_positional(&[a.get(b"$1")]);
            }
            self.emit(b"]\n");
            return;
        }
        // Anything else: an open block carrying the name as its style.
        if form == Form::BlockLeaf {
            self.write_block_attrs(id, Some(name), &[], &[]);
            self.emit(b"--\n--\n");
            return;
        }
        self.open_block(id, Some(name));
    }

    fn open_block(&mut self, id: NodeId, style: Option<&[u8]>) {
        self.write_block_attrs(id, style, &[], &[]);
        self.emit(b"--\n");
        self.render_blocks(id);
        self.emit(b"--\n");
    }

    fn write_html_attrs(&mut self, id: NodeId) {
        for kv in &self.attrs(id).entries {
            self.emit_byte(b' ');
            self.emit(&kv.key);
            if let Some(v) = &kv.value {
                self.emit(b"=\"");
                self.emit(v);
                self.emit_byte(b'"');
            }
        }
    }

    /// Positional macro attributes, trailing empties dropped.
    fn emit_positional(&mut self, slots: &[Option<&[u8]>]) {
        let mut used = slots.len();
        while used > 0 && slots[used - 1].is_none() {
            used -= 1;
        }
        for (i, slot) in slots[..used].iter().enumerate() {
            if i > 0 {
                self.emit_byte(b',');
            }
            if let Some(v) = slot {
                self.emit(v);
            }
        }
    }

    // ── lists ────────────────────────────────────────────────────────────

    fn render_list(&mut self, id: NodeId, kind: ListKind) {
        let mut style: Option<&[u8]> = None;
        let mut extra: Vec<KeyVal> = Vec::new();
        if kind == ListKind::Ordered {
            if let Kind::OrderedList { numbering, start, .. } = self.kind(id) {
                style = match numbering {
                    ListNumbering::Decimal => None,
                    ListNumbering::LowerAlpha => Some(b"loweralpha"),
                    ListNumbering::UpperAlpha => Some(b"upperalpha"),
                    ListNumbering::LowerRoman => Some(b"lowerroman"),
                    ListNumbering::UpperRoman => Some(b"upperroman"),
                };
                if let Some(st) = start {
                    if *st != 1 {
                        // A named attribute rather than an ordinal marker, so
                        // nesting by dot depth keeps working.
                        extra.push(KeyVal::new(b"start", Some(st.to_string().as_bytes())));
                    }
                }
            }
        }
        self.write_block_attrs_with(id, style, &[], &[b"start"], &extra);
        if kind == ListKind::Ordered {
            self.ordered_depth += 1;
        } else {
            self.bullet_depth += 1;
        }
        for item in self.children(id) {
            // The marker: `*`/`-` at depth one (the spelling, if recorded),
            // `**`… deeper, since only `*` and `.` nest by repetition.
            if kind == ListKind::Ordered {
                self.emit_repeat(b'.', self.ordered_depth as usize);
            } else if self.bullet_depth == 1 && bullet_of(self.spelling(id)) == Bullet::Dash {
                self.emit_byte(b'-');
            } else {
                self.emit_repeat(b'*', self.bullet_depth as usize);
            }
            self.emit_byte(b' ');
            if kind == ListKind::Task {
                let checked = match self.kind(item) {
                    Kind::TaskListItem { checked } => *checked,
                    _ => false,
                };
                self.emit(if checked { b"[x] " } else { b"[ ] " });
            }
            self.render_item_body(item);
        }
        if kind == ListKind::Ordered {
            self.ordered_depth -= 1;
        } else {
            self.bullet_depth -= 1;
        }
    }

    /// An item's principal (its leading inlines, or its first paragraph's) on
    /// the marker line, then each further block: a nested list directly, any
    /// other block after a `+` continuation line.
    fn render_item_body(&mut self, item: NodeId) {
        let mut child = self.first_child(item);
        let mut wrote_principal = false;
        // Leading inlines.
        while let Some(cid) = child {
            if self.kind(cid).level() == Level::Block {
                break;
            }
            self.render_inline(cid);
            wrote_principal = true;
            child = self.next_sibling(cid);
        }
        if !wrote_principal {
            if let Some(cid) = child {
                if matches!(self.kind(cid), Kind::Para) {
                    self.render_inline_children(cid);
                    child = self.next_sibling(cid);
                }
            }
        }
        self.emit_byte(b'\n');
        while let Some(cid) = child {
            if is_list(self.kind(cid)) {
                self.render_block(cid);
            } else {
                self.emit(b"+\n");
                self.render_block(cid);
            }
            child = self.next_sibling(cid);
        }
    }

    fn render_definition_item(&mut self, item: NodeId) {
        let mut definition: Option<NodeId> = None;
        let mut terms = 0;
        let colons = (2 + self.dlist_depth - 1).min(4) as usize;
        for c in self.children(item) {
            match self.kind(c) {
                Kind::Term => {
                    if terms > 0 {
                        self.emit_byte(b'\n');
                    }
                    self.render_inline_children(c);
                    self.emit_repeat(b':', colons);
                    terms += 1;
                }
                Kind::Definition => definition = Some(c),
                _ => {}
            }
        }
        if terms == 0 {
            self.emit_repeat(b':', colons);
        }
        let Some(def) = definition else {
            self.emit_byte(b'\n');
            return;
        };
        if self.first_child(def).is_none() {
            self.emit_byte(b'\n');
            return;
        }
        self.emit_byte(b' ');
        self.render_item_body(def);
    }

    // ── tables ───────────────────────────────────────────────────────────

    fn render_table(&mut self, id: NodeId) {
        // Width: the widest row in columns.
        let mut ncols: u32 = 0;
        let mut header = false;
        let mut first = true;
        let rows: Vec<_> = self.ast.table_rows(id).collect();
        for row in &rows {
            let mut n: u32 = 0;
            for cell in self.children(row.id) {
                n += match self.kind(cell) {
                    Kind::Cell(c) => c.colspan,
                    _ => 1,
                };
            }
            ncols = ncols.max(n);
            if first && row.head {
                header = true;
            }
            first = false;
        }
        if ncols == 0 {
            ncols = 1;
        }
        // The caption is the table's title — when it says anything.
        let mut titled = false;
        for c in self.children(id) {
            if matches!(self.kind(c), Kind::Caption) {
                let text = self.edges(c).2;
                if text.is_empty() {
                    continue;
                }
                self.emit_byte(b'.');
                self.emit(&text);
                self.emit_byte(b'\n');
                titled = true;
            }
        }
        let a = self.attrs(id);
        // A `title` attribute is the same line when no caption took it.
        if !titled {
            if let Some(t) = a.get(b"title") {
                self.emit_byte(b'.');
                self.emit(t);
                self.emit_byte(b'\n');
            }
        }
        let cols = format!("cols={}", ncols);
        let mut line: Vec<u8> = Vec::new();
        if header {
            line.extend_from_slice(b"%header");
        }
        if let Some(i) = a.get(b"id") {
            line.push(b'#');
            line.extend_from_slice(i);
        }
        if let Some(cls) = a.get(b"class") {
            for r in tokens(cls, b" ") {
                line.push(b'.');
                line.extend_from_slice(r);
            }
        }
        if !line.is_empty() {
            line.push(b',');
        }
        line.extend_from_slice(cols.as_bytes());
        for kv in &a.entries {
            if is_skipped(&kv.key, &[b"cols", b"options"]) {
                continue;
            }
            if !kv.key.is_empty() && kv.key[0] == b'$' {
                continue;
            }
            line.push(b',');
            line.extend_from_slice(&kv.key);
            if let Some(v) = &kv.value {
                line.push(b'=');
                append_attr_value(&mut line, v);
            }
        }
        self.emit_byte(b'[');
        self.emit(&line);
        self.emit(b"]\n");
        self.emit(b"|===\n");
        let mut first_row = true;
        for row in &rows {
            if !first_row {
                self.emit_byte(b'\n');
            }
            first_row = false;
            for cell in self.children(row.id) {
                if let Kind::Cell(c) = self.kind(cell) {
                    if c.colspan > 1 {
                        self.emit_int(c.colspan);
                        self.emit_byte(b'+');
                    }
                    if c.rowspan > 1 {
                        self.emit_byte(b'.');
                        self.emit_int(c.rowspan);
                        self.emit_byte(b'+');
                    }
                    match c.alignment {
                        Alignment::Left => self.emit_byte(b'<'),
                        Alignment::Center => self.emit_byte(b'^'),
                        Alignment::Right => self.emit_byte(b'>'),
                        Alignment::Default => {}
                    }
                }
                self.emit_byte(b'|');
                self.render_cell_content(cell);
                self.emit_byte(b'\n');
            }
        }
        self.emit(b"|===\n");
    }

    /// A cell's inlines. A cell holding blocks has them flattened to their
    /// inlines.
    fn render_cell_content(&mut self, cell: NodeId) {
        for c in self.children(cell) {
            if self.kind(c).level() == Level::Block {
                self.render_inline_children(c);
            } else {
                self.render_inline(c);
            }
        }
    }

    // ── inlines ──────────────────────────────────────────────────────────

    fn render_inline_children(&mut self, parent: NodeId) {
        for c in self.children(parent) {
            self.render_inline(c);
        }
    }

    /// The first byte the next sibling of `id` will write, or `None` at the
    /// end of the run — what decides whether a constrained span may CLOSE.
    fn next_byte(&self, id: NodeId) -> Option<u8> {
        let next = self.next_sibling(id)?;
        match self.kind(next) {
            Kind::Str(s) => s.first().copied(),
            Kind::SoftBreak | Kind::HardBreak => Some(b'\n'),
            Kind::SmartPunctuation(sp) => Some(sp.ascii().as_bytes()[0]),
            _ => Some(b'<'),
        }
    }

    /// A fresh renderer with no state but the tree.
    fn fresh(&self) -> Renderer<'d> {
        Renderer::new(self.ast, self.spellings)
    }

    /// First and last bytes of the text an inline run would produce.
    fn edges(&self, id: NodeId) -> (Option<u8>, Option<u8>, Vec<u8>) {
        let mut inner = self.fresh();
        inner.last = self.last;
        inner.bullet_depth = self.bullet_depth;
        inner.ordered_depth = self.ordered_depth;
        inner.dlist_depth = self.dlist_depth;
        inner.delim_depth = self.delim_depth;
        inner.render_inline_children(id);
        let text = inner.out;
        (text.first().copied(), text.last().copied(), text)
    }

    /// Wrap `id`'s rendered children in `d`, constrained where the boundaries
    /// allow and the table entry has a constrained half (a doubled
    /// delimiter), unconstrained otherwise.
    fn wrap_span(&mut self, id: NodeId, d: Delims, attrs_prefix: bool) {
        let (first, last, text) = self.edges(id);
        let doubled = d.open.len() == 2 && d.open[0] == d.open[1] && d.open == d.close;
        // A `[.role]` prefix, when one is written, is what precedes the opener.
        let a = self.attrs(id);
        let has_prefix = attrs_prefix && (a.get(b"class").is_some() || a.get(b"id").is_some());
        let mut constrained = false;
        if doubled {
            if let (Some(f), Some(l)) = (first, last) {
                let prev_ok = !is_word_byte(self.last) || has_prefix;
                let next = self.next_byte(id);
                let next_ok = next.is_none_or(|n| !is_word_byte(n));
                constrained = prev_ok && next_ok && !is_space_byte(f) && !is_space_byte(l) && !text.contains(&d.open[0]);
            }
        }
        if attrs_prefix {
            self.write_inline_attrs(id);
        }
        if text.is_empty() {
            self.emit(d.open);
            self.emit(d.close);
            return;
        }
        if constrained {
            self.emit(&d.open[..1]);
            self.emit(&text);
            self.emit(&d.close[..1]);
        } else {
            self.emit(d.open);
            self.emit(&text);
            self.emit(d.close);
        }
    }

    /// `[#id.role]` before a styled span.
    fn write_inline_attrs(&mut self, id: NodeId) {
        let a = self.attrs(id);
        let cls = a.get(b"class");
        let anchor = a.get(b"id");
        if cls.is_none() && anchor.is_none() {
            return;
        }
        self.emit_byte(b'[');
        if let Some(i) = anchor {
            self.emit_byte(b'#');
            self.emit(i);
        }
        if let Some(c) = cls {
            for r in tokens(c, b" ") {
                self.emit_byte(b'.');
                self.emit(r);
            }
        }
        self.emit_byte(b']');
    }

    fn image_macro(&mut self, id: NodeId) {
        let Kind::Image(im) = self.kind(id) else { return };
        let dest: Vec<u8> = match &im.destination {
            Some(d) => d.clone(),
            None => im.reference.as_ref().and_then(|r| self.resolve_reference(r)).map(|d| d.to_vec()).unwrap_or_default(),
        };
        self.emit(&dest);
        self.emit_byte(b'[');
        let a = self.attrs(id);
        let mut inner = self.fresh();
        inner.render_inline_children(id);
        let alt = inner.out;
        self.emit_positional(&[if !alt.is_empty() { Some(&alt[..]) } else { None }, a.get(b"width"), a.get(b"height")]);
        let mut any = !alt.is_empty() || a.get(b"width").is_some() || a.get(b"height").is_some();
        for kv in &a.entries {
            if kv.key == b"width" || kv.key == b"height" {
                continue;
            }
            if any {
                self.emit_byte(b',');
            }
            any = true;
            self.emit(&kv.key);
            self.emit_byte(b'=');
            if let Some(v) = &kv.value {
                self.emit(v);
            }
        }
        self.emit_byte(b']');
    }

    fn resolve_reference(&self, label: &[u8]) -> Option<&'d [u8]> {
        for n in &self.ast.nodes {
            if let Kind::Reference { label: l, destination } = &n.kind {
                if l == label {
                    return Some(destination);
                }
            }
        }
        None
    }

    fn footnote_definition(&self, label: &[u8]) -> Option<NodeId> {
        for n in &self.ast.nodes {
            if let Kind::Footnote { label: l } = &n.kind {
                if l == label {
                    return Some(n.id);
                }
            }
        }
        None
    }

    fn render_inline(&mut self, id: NodeId) {
        let kind = self.kind(id);
        match kind {
            Kind::Str(s) => self.emit(s),
            Kind::SoftBreak => self.emit_byte(b'\n'),
            Kind::HardBreak => self.emit(b" +\n"),
            Kind::NonBreakingSpace => self.emit(b"{nbsp}"),
            Kind::SmartPunctuation(sp) => self.emit(match sp {
                SmartPunctuationKind::EmDash => b"--",
                SmartPunctuationKind::EnDash => b"&#8211;",
                SmartPunctuationKind::Ellipses => b"...",
                SmartPunctuationKind::LeftSingleQuote | SmartPunctuationKind::RightSingleQuote => b"'",
                SmartPunctuationKind::LeftDoubleQuote | SmartPunctuationKind::RightDoubleQuote => b"\"",
            }),
            Kind::InlineMark(m) => self.wrap_span(id, mark_delims(*m), true),
            Kind::TextLeaf { kind: lk, text } => match lk {
                TextLeafKind::Verbatim => {
                    // A backtick pair cannot hold a doubled backtick; the pass
                    // macro can hold anything.
                    if text.windows(2).any(|w| w == b"``") {
                        self.emit(b"pass:c[<code>");
                        self.emit(text);
                        self.emit(b"</code>]");
                        return;
                    }
                    self.write_inline_attrs(id);
                    let d = verbatim_delims();
                    let prev_ok = !is_word_byte(self.last);
                    let next = self.next_byte(id);
                    let next_ok = next.is_none_or(|n| !is_word_byte(n));
                    let t = text;
                    let constrained = !t.is_empty()
                        && prev_ok
                        && next_ok
                        && !is_space_byte(t[0])
                        && !is_space_byte(t[t.len() - 1])
                        && !t.contains(&b'`');
                    if constrained {
                        self.emit(&d.open[..1]);
                        self.emit(t);
                        self.emit(&d.close[..1]);
                    } else {
                        self.emit(d.open);
                        self.emit(t);
                        self.emit(d.close);
                    }
                }
                TextLeafKind::InlineMath | TextLeafKind::DisplayMath => {
                    self.emit(b"stem:[");
                    self.emit(text);
                    self.emit_byte(b']');
                }
                TextLeafKind::Url => {
                    // A bare URL autolinks only from a scheme the parser
                    // knows; anything else needs the macro.
                    if is_autolinkable(text) {
                        self.emit(text);
                    } else {
                        self.emit(b"link:");
                        self.emit(text);
                        self.emit(b"[]");
                    }
                }
                TextLeafKind::Email => self.emit(text),
                TextLeafKind::Symb => {
                    self.emit_byte(b':');
                    self.emit(text);
                    self.emit_byte(b':');
                }
                TextLeafKind::FootnoteReference => {
                    self.emit(b"footnote:");
                    let auto = is_all_digits(text);
                    if !auto {
                        self.emit(text);
                    }
                    self.emit_byte(b'[');
                    let written = self.footnotes_written.contains(text.as_slice());
                    if !written {
                        if let Some(def) = self.footnote_definition(text) {
                            self.footnotes_written.insert(text.clone());
                            // The body: one paragraph's inlines, or blocks flattened.
                            let mut first = true;
                            for c in self.children(def) {
                                if !first {
                                    self.emit_byte(b' ');
                                }
                                first = false;
                                if self.kind(c).level() == Level::Block {
                                    self.render_inline_children(c);
                                } else {
                                    self.render_inline(c);
                                }
                            }
                        }
                    }
                    self.emit_byte(b']');
                }
                TextLeafKind::CitationReference => {
                    self.emit(b"<<");
                    self.emit(text);
                    self.emit(b">>");
                }
                TextLeafKind::SubstitutionReference => {
                    self.emit_byte(b'{');
                    self.emit(text);
                    self.emit_byte(b'}');
                }
            },
            Kind::RawInline { text, .. } => {
                if text.windows(3).any(|w| w == b"+++") {
                    self.emit(b"pass:[");
                    self.emit(text);
                    self.emit_byte(b']');
                } else {
                    self.emit(b"+++");
                    self.emit(text);
                    self.emit(b"+++");
                }
            }
            Kind::Link(l) => self.render_link(id, l),
            Kind::Image(_) => {
                self.emit(b"image:");
                self.image_macro(id);
            }
            Kind::Container(c) => {
                let Some(_) = c.form else {
                    self.emit_byte(b'<');
                    self.emit(&c.name);
                    self.write_html_attrs(id);
                    self.emit_byte(b'>');
                    match &c.text {
                        Some(text) => self.emit_element_text(&c.name, text),
                        None => self.render_inline_children(id),
                    }
                    self.emit(b"</");
                    self.emit(&c.name);
                    self.emit_byte(b'>');
                    return;
                };
                let a = self.attrs(id);
                if c.name == b"kbd" {
                    self.emit(b"kbd:[");
                    self.render_inline_children(id);
                    self.emit_byte(b']');
                    return;
                }
                if c.name == b"b" && a.get(b"class") == Some(b"button") {
                    self.emit(b"btn:[");
                    self.render_inline_children(id);
                    self.emit_byte(b']');
                    return;
                }
                // An anchor: an anonymous span with an id and nothing inside.
                if c.name.is_empty() && self.first_child(id).is_none() {
                    if let Some(i) = a.get(b"id") {
                        self.emit(b"[[");
                        self.emit(i);
                        self.emit(b"]]");
                        return;
                    }
                }
                // A styled span: `[.role]#text#`, the name as a role.
                self.emit_byte(b'[');
                if let Some(i) = a.get(b"id") {
                    self.emit_byte(b'#');
                    self.emit(i);
                }
                if !c.name.is_empty() {
                    self.emit_byte(b'.');
                    self.emit(&c.name);
                }
                if let Some(cls) = a.get(b"class") {
                    for r in tokens(cls, b" ") {
                        self.emit_byte(b'.');
                        self.emit(r);
                    }
                }
                self.emit(b"]##");
                self.render_inline_children(id);
                self.emit(b"##");
            }
            // A block reaching the inline path: its inlines, flattened.
            _ => self.render_inline_children(id),
        }
    }

    fn render_link(&mut self, id: NodeId, l: &crate::ast::Link) {
        let dest: &[u8] = match &l.destination {
            Some(d) => d,
            None => match l.reference.as_ref().and_then(|r| self.resolve_reference(r)) {
                Some(d) => d,
                None => {
                    // Unresolvable: the text alone.
                    self.render_inline_children(id);
                    return;
                }
            },
        };
        let a = self.attrs(id);
        let mut inner = self.fresh();
        inner.render_inline_children(id);
        let t = inner.out;
        let same = t == dest;
        if dest.len() > 1 && dest[0] == b'#' {
            // A fragment: a cross reference.
            self.emit(b"<<");
            self.emit(&dest[1..]);
            if !same && !t.is_empty() && t[..] != dest[1..] {
                self.emit_byte(b',');
                self.emit(&t);
            }
            self.emit(b">>");
            return;
        }
        if dest.starts_with(b"mailto:") || is_autolinkable(dest) {
            self.emit(dest);
        } else {
            self.emit(b"link:");
            self.emit(dest);
        }
        self.emit_byte(b'[');
        if !same && !(dest.starts_with(b"mailto:") && t[..] == dest[7..]) {
            self.emit(&t);
        }
        let mut any = !same;
        if let Some(w) = a.get(b"window") {
            if w == b"_blank" && !any {
                self.emit_byte(b'^');
            } else {
                if any {
                    self.emit_byte(b',');
                }
                self.emit(b"window=");
                self.emit(w);
                any = true;
            }
        }
        if let Some(c) = a.get(b"class") {
            if any {
                self.emit_byte(b',');
            }
            self.emit(b"role=");
            self.emit(c);
        }
        self.emit_byte(b']');
    }
}

/// Serialize a `Document` (spellings honoured) as AsciiDoc text.
pub fn serialize(doc: &Document) -> Vec<u8> {
    serialize_ast_spelled(&doc.ast, &doc.node_spelling)
}

/// Serialize a bare, language-agnostic `Ast` (one produced by a DIFFERENT
/// format's parser, for `convert -o asciidoc`). No spellings: every list
/// takes the canonical marker.
pub fn serialize_ast(ast: &Ast) -> Vec<u8> {
    serialize_ast_spelled(ast, &[])
}

/// `serialize_ast` plus a spelling table — the builder path, whose tree has
/// no source but does have caller-declared spellings.
pub fn serialize_ast_spelled(ast: &Ast, node_spelling: &[Option<Spelling>]) -> Vec<u8> {
    let mut r = Renderer::new(ast, node_spelling);
    r.render_block(ast.root);
    r.out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Builder, Link as AstLink};
    use crate::parser;

    fn round_trip(src: &[u8]) -> Vec<u8> {
        serialize(&parser::parse(src))
    }

    fn s(b: &[u8]) -> &str {
        std::str::from_utf8(b).unwrap()
    }

    #[test]
    fn a_macros_unnamed_first_positional_round_trips_inside_its_brackets() {
        assert_eq!(s(&round_trip(b"toc::[foo]\n\naudio::a.mp3[bar]\n")), "toc::[foo]\n\naudio::a.mp3[bar]\n");
    }

    #[test]
    fn a_document_with_a_title_entries_sections_and_paragraphs_is_stable() {
        let src = b"= Title\n:toc:\n:icons: font\n\nIntro *bold* and _em_.\n\n== Section\n\nBody.\n";
        let out = round_trip(src);
        assert_eq!(s(src), s(&out));
        let again = round_trip(&out);
        assert_eq!(s(&out), s(&again));
    }

    #[test]
    fn spans_are_constrained_on_word_boundaries_and_unconstrained_inside_a_word() {
        let out = round_trip(b"a **b** c sub**str**ing `m` x``y``z ##h## ^s^ ~t~\n");
        assert_eq!("a *b* c sub**str**ing `m` x``y``z #h# ^s^ ~t~\n", s(&out));
    }

    #[test]
    fn lists_nest_by_marker_depth_attach_blocks_with_a_continuation_and_keep_their_spelling() {
        let src = b"- one\n- two\n** deep\n+\nattached\n\n[]\n. first\n.. inner\n\n[]\nterm:: desc\nother::: nested\n";
        assert_eq!(s(src), s(&round_trip(src)));
    }

    #[test]
    fn a_checklist_a_numbered_start_and_a_letter_numbering_survive() {
        let out = round_trip(b"* [x] done\n* [ ] todo\n\n[loweralpha,start=3]\n. c\n. d\n");
        assert_eq!("* [x] done\n* [ ] todo\n\n[]\n[loweralpha,start=3]\n. c\n. d\n", s(&out));
        let back = parser::parse(&out);
        let first = back.ast.nodes[back.ast.root as usize].first_child.unwrap();
        let list = back.ast.nodes[first as usize].next_sibling.unwrap();
        match back.ast.kind(list) {
            Kind::OrderedList { numbering, start, .. } => {
                assert_eq!(*numbering, ListNumbering::LowerAlpha);
                assert_eq!(*start, Some(3));
            }
            k => panic!("{:?}", k),
        }
    }

    #[test]
    fn delimited_blocks_listing_with_language_admonition_quote_with_attribution_verse_table() {
        let src = b"[source,ruby]\n----\nputs 1\n----\n\n[NOTE]\n====\ncareful\n====\n\n[quote,Someone,Somewhere]\n____\nwords\n____\n\n[verse]\n____\nRoses\n  red\n____\n\n.Fruit\n[%header,cols=2]\n|===\n|Name\n|Count\n\n|Apple\n^|3\n|===\n";
        assert_eq!(s(src), s(&round_trip(src)));
    }

    #[test]
    fn block_metadata_round_trips() {
        let src = b".A title\n[#the-id.a.b%opt,key=val]\ntext\n";
        assert_eq!(s(src), s(&round_trip(src)));
    }

    #[test]
    fn links_xrefs_images_footnotes_anchors_math_and_passthroughs() {
        let src = b"See https://x.org[X] and <<sec,There>> and image:i.png[Alt,50] and footnote:[note] and [[a]] and stem:[x] and +++<b>+++ and {name}.\n";
        assert_eq!(s(src), s(&round_trip(src)));
    }

    #[test]
    fn a_listing_widens_its_delimiter_past_a_run_of_dashes_in_its_content() {
        let mut b = Builder::new();
        let cb = b.add_leaf(Kind::CodeBlock { lang: None, text: b"----\nx\n".to_vec() });
        let root = b.add_container(Kind::Doc, &[cb]);
        let ast = b.finish(root);
        let out = serialize_ast(&ast);
        assert_eq!("-----\n----\nx\n-----\n", s(&out));
        let back = parser::parse(&out);
        let first = back.ast.nodes[back.ast.root as usize].first_child.unwrap();
        match back.ast.kind(first) {
            Kind::CodeBlock { text, .. } => assert_eq!(s(text), "----\nx"),
            k => panic!("{:?}", k),
        }
    }

    #[test]
    fn a_mark_next_to_a_word_falls_back_to_the_unconstrained_form_so_it_still_reparses() {
        let mut b = Builder::new();
        let s1 = b.add_leaf(Kind::Str(b"pre".to_vec()));
        let fix = b.add_leaf(Kind::Str(b"fix".to_vec()));
        let strong = b.add_container(Kind::InlineMark(InlineMark::Strong), &[fix]);
        let p = b.add_container(Kind::Para, &[s1, strong]);
        let root = b.add_container(Kind::Doc, &[p]);
        let ast = b.finish(root);
        let out = serialize_ast(&ast);
        assert_eq!("pre**fix**\n", s(&out));
        let back = parser::parse(&out);
        assert!(back.ast.nodes.iter().any(|n| n.kind == Kind::InlineMark(InlineMark::Strong)));
    }

    #[test]
    fn an_unresolvable_link_writes_its_text_alone() {
        let mut b = Builder::new();
        let t = b.add_leaf(Kind::Str(b"text".to_vec()));
        let l = b.add_container(Kind::Link(AstLink { destination: None, reference: Some(b"nope".to_vec()) }), &[t]);
        let p = b.add_container(Kind::Para, &[l]);
        let root = b.add_container(Kind::Doc, &[p]);
        assert_eq!("text\n", s(&serialize_ast(&b.finish(root))));
    }

    #[test]
    fn a_markdown_tree_converts_headings_marks_a_fenced_code_block_a_task_list_a_table() {
        let md = twig_markdown::parse(
            b"# T\n\nsome **bold** `code` [link](https://x.org)\n\n```py\nx\n```\n\n- [x] a\n\n| h |\n|---|\n| c |\n",
            Default::default(),
        );
        let out = serialize_ast(&md.ast);
        assert_eq!(
            "= T\n\nsome *bold* `code` https://x.org[link]\n\n[source,py]\n----\nx\n----\n\n* [x] a\n\n[%header,cols=1]\n|===\n|h\n\n|c\n|===\n",
            s(&out)
        );
    }

    #[test]
    fn a_tables_title_attribute_is_its_title_line_unless_a_caption_already_is() {
        // The parser reads the line back as a caption, the way it reads every
        // `.Title` on a table.
        let doc = twig_html::parse(
            b"<table title=\"Figures\"><tr><td>a</td></tr></table><table title=\"Lost\"><caption>Cap</caption><tr><td>b</td></tr></table>",
        );
        let out = serialize_ast(&doc.ast);
        assert_eq!(".Figures\n[cols=1]\n|===\n|a\n|===\n\n.Cap\n[cols=1]\n|===\n|b\n|===\n", s(&out));
        let back = parser::parse(&out);
        assert_eq!(back.ast.nodes.iter().filter(|n| n.kind == Kind::Caption).count(), 2);
    }
}
