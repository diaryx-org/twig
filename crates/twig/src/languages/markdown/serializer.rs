//! `Document` (a Markdown parse) -> canonical-ish Markdown text. Port of
//! `src/languages/markdown/serializer.zig`.
//!
//! This is a structural printer from the shared `Ast`, not a source-preserving
//! re-emitter: it writes one stable representation for each node kind.

use crate::ast::verse;
use crate::ast::{Ast, KindRef, Container, Form, InlineMark, KeyVal, Attrs, Kind, MarkupLeafKind, NodeId, TextLeafKind, Alignment};
use crate::attrs_writer::{self, AttrSpelling, Quoting};
use crate::document::{Bullet, Document, HighlightPrefix, Labels, OrderedDelim, Spelling, ContainerOrigin};
use crate::languages::html::serializer::write_element_text;
use crate::languages::markdown::highlight;

// ── Markdown's spelling table (the parts this printer reads) ───────────────
// Delimiters come from `crate::syntax::markdown::table()`, NOT from a switch
// here: one table, one answer.

fn md_table() -> &'static crate::syntax::Syntax {
    crate::syntax::markdown::table()
}

// TODO(port): `attrs_writer::write` still takes its own `AttrSpelling` type
// rather than `crate::syntax::AttrSpelling`; until they are one type, the
// markdown table's `attr_spelling` is restated here (verbatim from
// `languages/markdown/syntax.zig`).
/// `md_syntax.table.attr_spelling`.
const ATTR_SPELLING: AttrSpelling = AttrSpelling {
    open: "{",
    close: "}",
    quoting: Quoting::WhenNeeded,
    quote_escapes: "\"\\",
    id_sigil: Some("#"),
    class_sigil: Some("."),
    ..AttrSpelling::DEFAULT
};

/// One segment of a block's continuation prefix: `"> "` for a block quote, or
/// the spaces that indent a list item / definition / div body. Chained
/// parent→child on the call stack so the prefix is emitted in *nesting order*
/// — a block quote inside a list item needs `  > `, a list inside a block
/// quote needs `> ` — so the two must be interleaved as encountered.
struct Prefix<'p> {
    parent: Option<&'p Prefix<'p>>,
    segment: &'static [u8],
}

#[derive(Clone, Copy, Default)]
struct Ctx<'p> {
    prefix: Option<&'p Prefix<'p>>,
    /// True while rendering the inline children of a table `cell`: a row is a
    /// single source line, so a `hard_break` here must be spelled as the
    /// in-cell break (`<br>`) rather than `  \n`.
    in_cell: bool,
}

impl<'p> Ctx<'p> {
    fn with_prefix(prefix: &'p Prefix<'p>) -> Ctx<'p> {
        Ctx { prefix: Some(prefix), in_cell: false }
    }
}

/// Where a backslash goes so that `text`, opening a line, reads back as text
/// and not as the block syntax it starts with — before the byte at the
/// returned index — or `None` when it needs none. A run of digits then `.`
/// or `)` is an ordered-list marker, escaped at the punctuation; every other
/// case is the first byte.
fn verse_escape_at(text: &[u8]) -> Option<usize> {
    if text.is_empty() {
        return None;
    }
    match text[0] {
        b'#' | b'>' | b'-' | b'+' | b'*' | b'=' | b'<' | b'`' | b'~' | b'_' | b'|' => Some(0),
        b':' => {
            if text.len() == 1 || text[1] == b' ' || text[1] == b'\t' {
                Some(0)
            } else {
                None
            }
        }
        b'[' => Some(0),
        b'0'..=b'9' => {
            let mut i = 0;
            while i < text.len() && i < 9 && text[i].is_ascii_digit() {
                i += 1;
            }
            if i < text.len() && (text[i] == b'.' || text[i] == b')') {
                Some(i)
            } else {
                None
            }
        }
        _ => None,
    }
}

fn write_prefix_node_to(node: Option<&Prefix<'_>>, w: &mut Vec<u8>) {
    let Some(p) = node else { return };
    write_prefix_node_to(p.parent, w);
    w.extend_from_slice(p.segment);
}

fn fence_ticks(text: &[u8], min: usize) -> usize {
    let mut best = min;
    let mut i = 0;
    while i < text.len() {
        if text[i] != b'`' {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < text.len() && text[j] == b'`' {
            j += 1;
        }
        let run = j - i;
        if run >= best {
            best = run + 1;
        }
        // Zig's `i = j` followed by the loop's `i += 1`.
        i = j + 1;
    }
    best
}

fn trim_end_bytes<'a>(s: &'a [u8], set: &[u8]) -> &'a [u8] {
    let mut end = s.len();
    while end > 0 && set.contains(&s[end - 1]) {
        end -= 1;
    }
    &s[..end]
}

struct Renderer<'a> {
    doc: &'a Document,
    ast: &'a Ast,
    out: &'a mut Vec<u8>,
}

impl<'a> Renderer<'a> {
    fn w(&mut self, s: &[u8]) {
        self.out.extend_from_slice(s);
    }

    fn byte(&mut self, b: u8) {
        self.out.push(b);
    }

    fn write_prefix(&mut self, ctx: Ctx<'_>) {
        write_prefix_node_to(ctx.prefix, self.out);
    }

    fn render_blocks(&mut self, parent: NodeId, ctx: Ctx<'_>, blank_between: bool) {
        let first = self.ast.node(parent).first_child;
        self.render_blocks_from(first, ctx, blank_between, true);
    }

    /// Like `render_blocks`, but starting at `next` rather than a parent's
    /// first child. `first` marks whether `next` is the first block of the
    /// item/container overall: when it isn't (the list-item case, where a
    /// leading paragraph was already written on the marker's line),
    /// `blank_between` still puts a blank line before it.
    fn render_blocks_from(&mut self, mut next: Option<NodeId>, ctx: Ctx<'_>, blank_between: bool, first: bool) {
        let mut is_first = first;
        while let Some(child) = next {
            if !is_first && blank_between {
                self.write_blank_line(ctx);
            }
            self.render_block(child, ctx);
            is_first = false;
            next = self.ast.node(child).next_sibling;
        }
    }

    /// A blank line between two blocks of the same container, which inside a
    /// quote is spelled `>` and not nothing: a bare blank line ENDS the quote.
    /// The prefix is written with its trailing space trimmed — a list item's
    /// indentation trims to nothing.
    fn write_blank_line(&mut self, ctx: Ctx<'_>) {
        let mut line = Vec::new();
        write_prefix_node_to(ctx.prefix, &mut line);
        self.w(trim_end_bytes(&line, b" "));
        self.byte(b'\n');
    }

    fn render_inline_children(&mut self, parent: NodeId, ctx: Ctx<'_>) {
        let mut c = self.ast.node(parent).first_child;
        while let Some(id) = c {
            self.render_inline(id, ctx);
            c = self.ast.node(id).next_sibling;
        }
    }

    /// Write inline text, re-emitting `ctx`'s block prefix after each embedded
    /// newline so a soft-wrapped line stays inside its list item / block
    /// quote. A trailing newline gets no prefix.
    fn write_inline_text(&mut self, s: &[u8], ctx: Ctx<'_>) {
        let mut rest = s;
        while let Some(nl) = rest.iter().position(|&c| c == b'\n') {
            self.w(&rest[..nl + 1]);
            rest = &rest[nl + 1..];
            if !rest.is_empty() {
                self.write_prefix(ctx);
            }
        }
        self.w(rest);
    }

    /// Re-emit a directive's `{#id .class key=val}` attribute shorthand from
    /// the node's attrs (nothing if it has none).
    fn write_directive_attrs(&mut self, id: NodeId) {
        attrs_writer::write(self.out, self.ast.attrs_of(id), &ATTR_SPELLING, b"");
    }

    /// One `| a | b |` line for `row`'s cells.
    fn write_table_row(&mut self, ctx: Ctx<'_>, row: NodeId) {
        self.write_prefix(ctx);
        self.byte(b'|');
        let mut cell_ctx = ctx;
        cell_ctx.in_cell = true;
        for cell in self.ast.child_ids(row) {
            self.byte(b' ');
            self.render_inline_children(cell, cell_ctx);
            self.w(b" |");
        }
        self.byte(b'\n');
    }

    /// The `|:---|---:|` line, one entry per cell of `row`, carrying that
    /// cell's alignment.
    fn write_table_delimiter(&mut self, ctx: Ctx<'_>, row: NodeId) {
        self.write_prefix(ctx);
        self.byte(b'|');
        for cell in self.ast.child_ids(row) {
            let alignment = match self.ast.kind(cell) {
                Kind::Cell(c) => c.alignment,
                // Zig reads `.cell` unchecked, which in the release oracle
                // is an untagged read of another payload (an HTML `<pre>`
                // directly inside a `<tr>` lands here). The oracle prints the
                // default delimiter for it; so do we.
                _ => Alignment::Default,
            };
            let delim: &[u8] = match alignment {
                Alignment::Left => b":---",
                Alignment::Right => b"---:",
                Alignment::Center => b":---:",
                Alignment::Default => b"---",
            };
            self.byte(b' ');
            self.w(delim);
            self.w(b" |");
        }
        self.byte(b'\n');
    }

    /// A `|  |  |` line as wide as `row` — the synthesized header a
    /// headerless table needs to stay a table.
    fn write_table_empty_header(&mut self, ctx: Ctx<'_>, row: NodeId) {
        self.write_prefix(ctx);
        self.byte(b'|');
        for _ in self.ast.child_ids(row) {
            self.w(b"  |");
        }
        self.byte(b'\n');
    }

    fn write_code_fence(&mut self, ctx: Ctx<'_>, info: Option<&[u8]>, text: &[u8]) {
        let ticks = fence_ticks(text, 3);
        self.write_prefix(ctx);
        for _ in 0..ticks {
            self.byte(b'`');
        }
        // The info string directly abuts the fence (```fig, not ``` fig).
        if let Some(s) = info {
            if !s.is_empty() {
                self.w(s);
            }
        }
        self.byte(b'\n');
        if !text.is_empty() {
            self.w(text);
        }
        if text.last() != Some(&b'\n') {
            self.byte(b'\n');
        }
        self.write_prefix(ctx);
        for _ in 0..ticks {
            self.byte(b'`');
        }
        self.byte(b'\n');
    }

    /// Front/end matter: `---<lang>` … `---`. A bare `---` fence is emitted
    /// for `yaml`; every other language carries its self-describing tag.
    fn write_metadata(&mut self, ctx: Ctx<'_>, lang: &[u8], text: &[u8]) {
        self.write_prefix(ctx);
        if lang == b"yaml" {
            self.w(b"---\n");
        } else {
            self.w(b"---");
            self.w(lang);
            self.byte(b'\n');
        }
        if !text.is_empty() {
            self.w(text);
        }
        if text.last() != Some(&b'\n') {
            self.byte(b'\n');
        }
        self.write_prefix(ctx);
        self.w(b"---\n");
    }

    fn render_list_item(&mut self, item_id: NodeId, marker: &[u8], ctx: Ctx<'_>, tight: bool) {
        self.write_prefix(ctx);
        self.w(marker);

        let Some(first) = self.ast.node(item_id).first_child else {
            self.byte(b'\n');
            return;
        };
        let item_prefix = Prefix { parent: ctx.prefix, segment: b"  " };
        let item_ctx = Ctx::with_prefix(&item_prefix);
        // A leading paragraph always starts on the marker's own line.
        if *self.ast.kind(first) == Kind::Para {
            self.render_inline_children(first, item_ctx);
            self.byte(b'\n');
            let next = self.ast.node(first).next_sibling;
            if tight && next.is_none() {
                return;
            }
            self.render_blocks_from(next, item_ctx, !tight, false);
            return;
        }

        self.byte(b'\n');
        self.render_blocks(item_id, item_ctx, !tight);
    }

    fn render_reference_defs(&mut self) {
        let mut saw_any = false;
        for n in &self.ast.nodes {
            let Kind::Reference { label, destination } = &n.kind else { continue };
            let Some(&id) = self.doc.labels.references.get(label) else { continue };
            if id != n.id {
                continue;
            }
            if !saw_any {
                saw_any = true;
            } else {
                self.out.push(b'\n');
            }
            self.out.push(b'[');
            self.out.extend_from_slice(label);
            self.out.extend_from_slice(b"]: ");
            self.out.extend_from_slice(destination);
            if let Some(title) = self.ast.attrs_of(id).get(b"title") {
                self.out.extend_from_slice(b" \"");
                self.out.extend_from_slice(title);
                self.out.push(b'"');
            }
            self.out.push(b'\n');
        }
    }

    /// Footnote definitions, and citations flattened into them — Markdown has
    /// the one registry. A `substitution` writes nothing at all.
    fn render_footnote_defs(&mut self) {
        let mut saw_any = false;
        for n in &self.ast.nodes {
            let lab: &[u8] = match &n.kind {
                Kind::Footnote { label } => {
                    // Picks ONE definition when several share a label.
                    let Some(id) = self.doc.labels.footnote(label) else { continue };
                    if id != n.id {
                        continue;
                    }
                    label
                }
                Kind::Citation { label } => label,
                _ => continue,
            };
            if !saw_any {
                saw_any = true;
            } else {
                self.out.push(b'\n');
            }
            self.out.extend_from_slice(b"[^");
            self.out.extend_from_slice(lab);
            self.out.extend_from_slice(b"]: ");
            if n.first_child.is_some() {
                // Keep definitions parseable while staying simple.
                let mut body = Vec::new();
                let mut inner = Renderer { doc: self.doc, ast: self.ast, out: &mut body };
                inner.render_blocks(n.id, Ctx::default(), false);
                self.out.extend_from_slice(trim_end_bytes(&body, b"\n"));
            }
            self.out.push(b'\n');
        }
    }

    /// Whether a `div`- or `span`-named container, or an anonymous one, is
    /// written as its HTML tag — unless the Markdown parser itself read it as
    /// a DIRECTIVE (`Document::container_origin`), which is written back as
    /// it was found.
    fn spells_as_tag(&self, id: NodeId, c: &Container) -> bool {
        let Some(form) = c.form else { return false };
        let html_name = match form {
            Form::BlockFenced => c.name.is_empty() || c.name == b"div",
            Form::InlineText => c.name.is_empty() || c.name == b"span",
            Form::BlockLeaf => false,
        };
        if !html_name {
            return false;
        }
        self.doc.container_origin(id) != Some(ContainerOrigin::Directive)
    }

    /// Whether `kind`'s attributes have to ride on a `<div>` around it: every
    /// block Markdown spells natively.
    fn wraps_for_attrs(kind: &Kind) -> bool {
        matches!(
            kind,
            Kind::Para
                | Kind::Heading { .. }
                | Kind::ThematicBreak
                | Kind::Section
                | Kind::CodeBlock { .. }
                | Kind::RawBlock { .. }
                | Kind::BlockQuote
                | Kind::BulletList { .. }
                | Kind::OrderedList { .. }
                | Kind::TaskList { .. }
                | Kind::DefinitionList
                | Kind::Table
        )
    }

    /// `<tag attrs>`, on its own line under the prefix, or `</tag>`.
    fn write_tag_line(&mut self, ctx: Ctx<'_>, tag: &[u8], attrs: Option<NodeId>) {
        self.write_prefix(ctx);
        if let Some(id) = attrs {
            self.byte(b'<');
            self.w(tag);
            attrs_writer::write_html_attrs(self.out, self.ast.attrs_of(id));
            self.w(b">\n");
        } else {
            self.w(b"</");
            self.w(tag);
            self.w(b">\n");
        }
    }

    /// A block that carries attributes Markdown has no spelling for is written
    /// inside a `<div>` that carries them, blank-separated from its content.
    fn render_block(&mut self, id: NodeId, ctx: Ctx<'_>) {
        let kind = self.ast.kind(id);
        if !Self::wraps_for_attrs(kind) || self.ast.attrs_of(id).is_empty() {
            return self.render_block_bare(id, ctx);
        }
        self.write_tag_line(ctx, b"div", Some(id));
        self.write_blank_line(ctx);
        self.render_block_bare(id, ctx);
        self.write_blank_line(ctx);
        self.write_tag_line(ctx, b"div", None);
    }

    /// A `line_block`, as `ast::verse` reads back: a `<div>` whose class
    /// leads with `verse`, each stanza a paragraph, each line inside one
    /// ended by a `\` hard break, and a line's `indent` written as that many
    /// em spaces at its start.
    fn render_verse(&mut self, id: NodeId, ctx: Ctx<'_>) {
        self.write_prefix(ctx);
        self.w(b"<div");
        self.write_verse_attrs(id);
        self.w(b">\n");
        self.write_blank_line(ctx);
        let mut in_stanza = false;
        for line in self.ast.child_ids(id) {
            if self.ast.node(line).first_child.is_none() {
                if in_stanza {
                    self.byte(b'\n');
                    self.write_blank_line(ctx);
                    in_stanza = false;
                }
                continue;
            }
            if in_stanza {
                self.w(b"\\\n");
            }
            self.write_prefix(ctx);
            let indent = match self.ast.kind(line) {
                Kind::Line { indent } => *indent,
                _ => 0,
            };
            for _ in 0..indent {
                self.w(verse::EM_SPACE);
            }
            self.render_verse_line(line, ctx, indent == 0);
            in_stanza = true;
        }
        if in_stanza {
            self.byte(b'\n');
            self.write_blank_line(ctx);
        }
        self.write_tag_line(ctx, b"div", None);
    }

    /// The tag's attributes: the block's own, with `verse` first in its class.
    fn write_verse_attrs(&mut self, id: NodeId) {
        let attrs = self.ast.attrs_of(id);
        let mut entries: Vec<KeyVal> = Vec::new();
        let mut class: Vec<u8> = verse::CLASS_TOKEN.to_vec();
        let mut placed = false;
        for kv in &attrs.entries {
            if kv.key == b"class" {
                if let Some(v) = &kv.value {
                    for t in v.split(|c| matches!(c, b' ' | b'\t' | b'\r' | b'\n')).filter(|t| !t.is_empty()) {
                        if t == verse::CLASS_TOKEN {
                            continue;
                        }
                        class.push(b' ');
                        class.extend_from_slice(t);
                    }
                }
                // Zig stores the buffer's slice as it stands NOW, so the
                // value is a snapshot at the first `class` entry.
                if !placed {
                    entries.push(KeyVal { key: b"class".to_vec(), value: Some(class.clone()) });
                }
                placed = true;
                continue;
            }
            entries.push(kv.clone());
        }
        if !placed {
            entries.insert(0, KeyVal { key: b"class".to_vec(), value: Some(class) });
        }
        attrs_writer::write_html_attrs(self.out, &Attrs { entries });
    }

    /// One verse line's inlines. At the margin, a `str` that opens with
    /// something a line start reads as block syntax takes a backslash.
    fn render_verse_line(&mut self, line: NodeId, ctx: Ctx<'_>, at_margin: bool) {
        let Some(first) = self.ast.node(line).first_child else { return };
        let ast: &'a Ast = self.ast;
        if at_margin {
            if let Kind::Str(text) = ast.kind(first) {
                if let Some(at) = verse_escape_at(text) {
                    self.w(&text[..at]);
                    self.byte(b'\\');
                    self.write_inline_text(&text[at..], ctx);
                    let mut c = ast.node(first).next_sibling;
                    while let Some(cid) = c {
                        self.render_inline(cid, ctx);
                        c = ast.node(cid).next_sibling;
                    }
                    return;
                }
            }
        }
        self.render_inline_children(line, ctx);
    }

    fn render_block_bare(&mut self, id: NodeId, ctx: Ctx<'_>) {
        let ast: &'a Ast = self.ast;
        match ast.kind(id) {
            Kind::Doc | Kind::Section => self.render_blocks(id, ctx, true),
            Kind::Para => {
                self.write_prefix(ctx);
                self.render_inline_children(id, ctx);
                self.byte(b'\n');
            }
            Kind::Heading { level } => {
                self.write_prefix(ctx);
                for _ in 0..*level {
                    self.byte(b'#');
                }
                self.byte(b' ');
                self.render_inline_children(id, ctx);
                self.byte(b'\n');
            }
            Kind::ThematicBreak => {
                self.write_prefix(ctx);
                self.w(b"---\n");
            }
            Kind::BlockQuote => {
                let p = Prefix { parent: ctx.prefix, segment: b"> " };
                self.render_blocks(id, Ctx::with_prefix(&p), true);
            }
            Kind::BulletList { tight } => {
                // The marker character is spelling, not meaning: recorded in
                // the Document's side table when the source is known.
                let marker: &[u8] = match bullet_of(self.doc.spelling(id)) {
                    Bullet::Dash => b"- ",
                    Bullet::Plus => b"+ ",
                    Bullet::Star => b"* ",
                };
                let mut first = true;
                for item in ast.child_ids(id) {
                    if !first && !tight {
                        self.byte(b'\n');
                    }
                    self.render_list_item(item, marker, ctx, *tight);
                    first = false;
                }
            }
            Kind::OrderedList { start, tight, .. } => {
                let mut n: u32 = start.unwrap_or(1);
                let mut first = true;
                for item in ast.child_ids(id) {
                    if !first && !tight {
                        self.byte(b'\n');
                    }
                    let marker = match delim_of(self.doc.spelling(id)) {
                        OrderedDelim::Period => format!("{n}. "),
                        OrderedDelim::ParenAfter => format!("{n}) "),
                        OrderedDelim::ParenBoth => format!("({n}) "),
                    };
                    self.render_list_item(item, marker.as_bytes(), ctx, *tight);
                    // Zig's `n += 1` on a u32 traps on overflow.
                    n = n.checked_add(1).expect("ordered list number overflow");
                    first = false;
                }
            }
            Kind::TaskList { tight } => {
                let mut first = true;
                for item in ast.child_ids(id) {
                    if !first && !tight {
                        self.byte(b'\n');
                    }
                    let checked = matches!(ast.kind(item), Kind::TaskListItem { checked: true });
                    let marker: &[u8] = if checked { b"- [x] " } else { b"- [ ] " };
                    self.render_list_item(item, marker, ctx, *tight);
                    first = false;
                }
            }
            // A verse — see `ast::verse`, which reads this spelling back.
            Kind::LineBlock => self.render_verse(id, ctx),
            Kind::DefinitionList => {
                for dli in ast.child_ids(id) {
                    for cid in ast.child_ids(dli) {
                        match ast.kind(cid) {
                            Kind::Term => {
                                self.write_prefix(ctx);
                                self.render_inline_children(cid, ctx);
                                self.byte(b'\n');
                            }
                            Kind::Definition => {
                                self.write_prefix(ctx);
                                self.w(b": ");
                                match ast.node(cid).first_child {
                                    Some(f) => {
                                        if *ast.kind(f) == Kind::Para && ast.node(f).next_sibling.is_none() {
                                            self.render_inline_children(f, ctx);
                                            self.byte(b'\n');
                                        } else {
                                            self.byte(b'\n');
                                            let p = Prefix { parent: ctx.prefix, segment: b"  " };
                                            self.render_blocks(cid, Ctx::with_prefix(&p), true);
                                        }
                                    }
                                    None => self.byte(b'\n'),
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Kind::Table => {
                // GFM's delimiter row must follow the first row and nothing
                // else, so it is written after the first row unconditionally,
                // and a first row that is not a header gets a synthesized
                // empty header above it.
                let rows: Vec<_> = ast.table_rows(id).collect();
                let Some(first) = rows.first() else { return };
                let mut wrote_delim = false;
                if !first.head {
                    self.write_table_empty_header(ctx, first.id);
                    self.write_table_delimiter(ctx, first.id);
                    wrote_delim = true;
                }
                for row in &rows {
                    self.write_table_row(ctx, row.id);
                    if !wrote_delim {
                        wrote_delim = true;
                        self.write_table_delimiter(ctx, row.id);
                    }
                }
            }
            Kind::CodeBlock { lang, text } => self.write_code_fence(ctx, lang.as_deref(), text),
            Kind::RawBlock { format, text } => self.write_code_fence(ctx, Some(format), text),
            Kind::Metadata { lang, text } => self.write_metadata(ctx, lang, text),
            Kind::Container(c) => {
                let Some(form) = c.form else {
                    // Unclassified: an HTML/XML element passing through, with
                    // its attributes.
                    self.write_prefix(ctx);
                    self.byte(b'<');
                    self.w(&c.name);
                    attrs_writer::write_html_attrs(self.out, ast.attrs_of(id));
                    self.byte(b'>');
                    // A text body is the tag's to spell, raw or escaped.
                    match &c.text {
                        Some(text) => write_element_text(self.out, &c.name, text),
                        None => self.render_blocks(id, ctx, false),
                    }
                    self.w(b"</");
                    self.w(&c.name);
                    self.w(b">\n");
                    return;
                };
                match form {
                    // A `text` container only appears inline; route a stray one
                    // there defensively.
                    Form::InlineText => {
                        self.write_prefix(ctx);
                        self.render_inline(id, ctx);
                        self.byte(b'\n');
                    }
                    Form::BlockLeaf => {
                        self.write_prefix(ctx);
                        self.w(b"::");
                        self.w(&c.name);
                        if ast.node(id).first_child.is_some() {
                            self.byte(b'[');
                            self.render_inline_children(id, ctx);
                            self.byte(b']');
                        }
                        self.write_directive_attrs(id);
                        self.byte(b'\n');
                    }
                    Form::BlockFenced => {
                        if self.spells_as_tag(id, c) {
                            self.write_tag_line(ctx, b"div", Some(id));
                            if let Some(text) = &c.text {
                                write_element_text(self.out, b"div", text);
                            } else if ast.node(id).first_child.is_some() {
                                self.write_blank_line(ctx);
                                self.render_blocks(id, ctx, true);
                                self.write_blank_line(ctx);
                            }
                            self.write_tag_line(ctx, b"div", None);
                            return;
                        }
                        self.write_prefix(ctx);
                        self.w(b":::");
                        self.w(&c.name);
                        self.write_directive_attrs(id);
                        self.byte(b'\n');
                        self.render_blocks(id, ctx, true);
                        self.write_prefix(ctx);
                        self.w(b":::\n");
                    }
                }
            }
            // The named definitions are written once, together.
            Kind::Reference { .. } | Kind::Footnote { .. } | Kind::Citation { .. } | Kind::Substitution { .. } => {}
            Kind::MarkupLeaf { kind, text } => {
                self.write_prefix(ctx);
                match kind {
                    MarkupLeafKind::Comment => {
                        self.w(b"<!--");
                        self.w(text);
                        self.w(b"-->\n");
                    }
                    MarkupLeafKind::Doctype => {
                        self.w(b"<!DOCTYPE");
                        self.w(text);
                        self.w(b">\n");
                    }
                    MarkupLeafKind::Cdata => {
                        self.w(b"<![CDATA[");
                        self.w(text);
                        self.w(b"]]>\n");
                    }
                }
            }
            Kind::ProcessingInstruction { target, data } => {
                self.write_prefix(ctx);
                self.w(b"<?");
                self.w(target);
                if !data.is_empty() {
                    self.byte(b' ');
                    self.w(data);
                }
                self.w(b"?>\n");
            }
            Kind::ListItem
            | Kind::TaskListItem { .. }
            | Kind::DefinitionListItem
            | Kind::Term
            | Kind::Definition
            | Kind::Row { .. }
            | Kind::Cell(_)
            | Kind::Caption => self.render_blocks(id, ctx, false),
            _ => {
                self.write_prefix(ctx);
                self.render_inline(id, ctx);
                self.byte(b'\n');
            }
        }
    }

    fn render_inline(&mut self, id: NodeId, ctx: Ctx<'_>) {
        let ast: &'a Ast = self.ast;
        let node = ast.node(id);
        match &node.kind {
            // Text may carry embedded newlines; re-emit the block prefix on
            // each continuation line.
            Kind::Str(s) => self.write_inline_text(s, ctx),
            Kind::SoftBreak => {
                self.byte(b'\n');
                self.write_prefix(ctx);
            }
            Kind::HardBreak => {
                if ctx.in_cell {
                    // A row is one source line: spell the break as `<br>`.
                    // Markdown always has this spelling (asserted coherent).
                    self.w(md_table().cell_line_break.expect("markdown spells an in-cell break"));
                } else {
                    self.w(b"  \n");
                    self.write_prefix(ctx);
                }
            }
            Kind::NonBreakingSpace => self.w(b"&nbsp;"),
            Kind::InlineMark(m) => {
                let Some(d) = md_table().delims_for(&KindRef::Mark(*m)) else { return };
                let (open, close) = (d.open, d.close);
                self.w(open);
                // A coloured highlight: the colour attribute spells back as its
                // circle emoji right after the opening `==`, with the space the
                // source had. A colour name the table doesn't know prints
                // nothing.
                if *m == InlineMark::Mark {
                    if let Some(name) = ast.attrs_of(id).get(highlight::ATTR_KEY.as_bytes()) {
                        if let Some(c) = highlight::Color::from_name(name) {
                            self.w(c.emoji().as_bytes());
                            if highlight_prefix_of(self.doc.spelling(id)) == HighlightPrefix::Spaced {
                                self.byte(b' ');
                            }
                        }
                    }
                }
                self.render_inline_children(id, ctx);
                self.w(close);
            }
            Kind::TextLeaf { kind, text } => match kind {
                TextLeafKind::Symb => {
                    self.byte(b':');
                    self.w(text);
                    self.byte(b':');
                }
                TextLeafKind::Verbatim => {
                    let ticks = fence_ticks(text, 1);
                    for _ in 0..ticks {
                        self.byte(b'`');
                    }
                    self.w(text);
                    for _ in 0..ticks {
                        self.byte(b'`');
                    }
                }
                TextLeafKind::InlineMath => {
                    self.byte(b'$');
                    self.w(text);
                    self.byte(b'$');
                }
                // Tight, as the formula came.
                TextLeafKind::DisplayMath => {
                    self.w(b"$$");
                    self.w(text);
                    self.w(b"$$");
                }
                TextLeafKind::Url | TextLeafKind::Email => {
                    self.byte(b'<');
                    self.w(text);
                    self.byte(b'>');
                }
                // A citation reference goes into Markdown's one footnote
                // registry; a substitution reference keeps its rST spelling.
                TextLeafKind::FootnoteReference | TextLeafKind::CitationReference => {
                    self.w(b"[^");
                    self.w(text);
                    self.byte(b']');
                }
                TextLeafKind::SubstitutionReference => {
                    self.byte(b'|');
                    self.w(text);
                    self.byte(b'|');
                }
            },
            Kind::RawInline { text, .. } => self.w(text),
            Kind::SmartPunctuation(sp) => self.w(sp.ascii().as_bytes()),
            Kind::Link(l) => {
                self.byte(b'[');
                self.render_inline_children(id, ctx);
                self.byte(b']');
                self.write_link_target(l.destination.as_deref(), l.reference.as_deref());
            }
            Kind::Image(im) => {
                self.w(b"![");
                self.render_inline_children(id, ctx);
                self.byte(b']');
                self.write_link_target(im.destination.as_deref(), im.reference.as_deref());
            }
            Kind::Container(c) => {
                // A span — HTML's, or djot's bracketed span — is the tag. An
                // anonymous one with NO attributes yields its text.
                if self.spells_as_tag(id, c) {
                    if c.name.is_empty() && ast.attrs_of(id).is_empty() {
                        self.render_inline_children(id, ctx);
                        return;
                    }
                    self.w(b"<span");
                    attrs_writer::write_html_attrs(self.out, ast.attrs_of(id));
                    self.byte(b'>');
                    match &c.text {
                        Some(text) => write_element_text(self.out, b"span", text),
                        None => self.render_inline_children(id, ctx),
                    }
                    self.w(b"</span>");
                    return;
                }
                // An UNCLASSIFIED container is an HTML/XML element: pass it
                // through as its tag, never as a directive.
                if c.form.is_none() {
                    self.byte(b'<');
                    self.w(&c.name);
                    attrs_writer::write_html_attrs(self.out, ast.attrs_of(id));
                    self.byte(b'>');
                    match &c.text {
                        Some(text) => write_element_text(self.out, &c.name, text),
                        None => self.render_inline_children(id, ctx),
                    }
                    self.w(b"</");
                    self.w(&c.name);
                    self.byte(b'>');
                    return;
                }
                // A real inline directive `:name[label]{attrs}`; a stray block
                // form emits the single-colon spelling as a lossy fallback.
                self.byte(b':');
                self.w(&c.name);
                if node.first_child.is_some() {
                    self.byte(b'[');
                    self.render_inline_children(id, ctx);
                    self.byte(b']');
                }
                self.write_directive_attrs(id);
            }
            _ => self.render_inline_children(id, ctx),
        }
    }

    fn write_link_target(&mut self, destination: Option<&[u8]>, reference: Option<&[u8]>) {
        if let Some(dest) = destination {
            self.byte(b'(');
            self.w(dest);
            self.byte(b')');
        } else if let Some(lab) = reference {
            self.byte(b'[');
            self.w(lab);
            self.byte(b']');
        }
    }
}

/// A coloured highlight's recorded prefix form, `Tight` when the spelling
/// table has nothing (or something else) for the node.
fn highlight_prefix_of(sp: Option<Spelling>) -> HighlightPrefix {
    match sp {
        Some(Spelling::HighlightPrefix(p)) => p,
        _ => HighlightPrefix::Tight,
    }
}

/// A `bullet_list`'s recorded marker character, canonical `-` otherwise.
fn bullet_of(sp: Option<Spelling>) -> Bullet {
    match sp {
        Some(Spelling::Bullet(b)) => b,
        _ => Bullet::Dash,
    }
}

/// An `ordered_list`'s recorded marker punctuation, canonical `1.` otherwise.
fn delim_of(sp: Option<Spelling>) -> OrderedDelim {
    match sp {
        Some(Spelling::OrderedDelim(d)) => d,
        _ => OrderedDelim::Period,
    }
}

/// Serialize `doc` as Markdown, appending to `out`.
pub fn serialize_into(doc: &Document, out: &mut Vec<u8>) {
    let mut r = Renderer { doc, ast: &doc.ast, out };
    r.render_block(doc.ast.root, Ctx::default());

    let mut tail = Vec::new();
    let mut defs = Renderer { doc, ast: &doc.ast, out: &mut tail };
    defs.render_reference_defs();
    defs.render_footnote_defs();
    if !tail.is_empty() {
        if doc.ast.node(doc.ast.root).first_child.is_some() {
            out.push(b'\n');
        }
        out.extend_from_slice(&tail);
    }
}

/// Serialize `doc` as Markdown (Zig's `serializeAlloc`).
pub fn serialize(doc: &Document) -> Vec<u8> {
    let mut out = Vec::new();
    serialize_into(doc, &mut out);
    out
}

/// Serialize a bare, language-agnostic `Ast` (e.g. one produced by a
/// DIFFERENT format's parser, for `twig convert -o markdown`) as Markdown
/// text (Zig's `serializeAstAlloc`). No parsed `Document` names the winning
/// definitions, so this builds a throwaway one over [`Labels::index`].
pub fn serialize_ast(ast: &Ast) -> Vec<u8> {
    serialize_ast_spelled(ast, &[])
}

/// [`serialize_ast`] plus a spelling table, so a caller that DOES know how its
/// lists were spelled round-trips them (Zig's `serializeAstSpelledAlloc`).
pub fn serialize_ast_spelled(ast: &Ast, node_spelling: &[Option<Spelling>]) -> Vec<u8> {
    let mut doc = Document::from_ast(b"", ast.clone());
    doc.node_spelling = node_spelling.to_vec();
    doc.labels = Labels::index(ast);
    serialize(&doc)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Builder, Cell};
    use crate::languages::markdown::{parse, ParseOptions};

    fn s(v: Vec<u8>) -> String {
        String::from_utf8(v).unwrap()
    }

    fn contains(hay: &str, needle: &str) -> bool {
        hay.contains(needle)
    }

    fn default_opts() -> ParseOptions {
        ParseOptions::markdown()
    }

    fn directives_on() -> ParseOptions {
        ParseOptions { directives: true, ..default_opts() }
    }

    fn serialize_with(source: &str, options: ParseOptions) -> String {
        let doc = parse(source.as_bytes(), options);
        s(serialize(&doc))
    }

    fn str_leaf(b: &mut Builder, text: &str) -> NodeId {
        b.add_leaf(Kind::Str(text.as_bytes().to_vec()))
    }

    // ── tests that need only a built tree ──────────────────────────────

    #[test]
    fn a_line_block_is_a_verse_div() {
        let mut b = Builder::new();
        let t0 = str_leaf(&mut b, "Roses are red,");
        let l0 = b.add_container(Kind::Line { indent: 0 }, &[t0]);
        let gap = b.add_container(Kind::Line { indent: 0 }, &[]);
        let t1 = str_leaf(&mut b, "violets are blue.");
        let l1 = b.add_container(Kind::Line { indent: 1 }, &[t1]);
        let t2 = str_leaf(&mut b, "1. not a list");
        let l2 = b.add_container(Kind::Line { indent: 0 }, &[t2]);
        let block = b.add_container(Kind::LineBlock, &[l0, gap, l1, l2]);
        b.set_attrs(block, Attrs { entries: vec![KeyVal::new(b"class", Some(b"center"))] });
        let root = b.add_container(Kind::Doc, &[block]);
        let ast = b.finish(root);
        let out = s(serialize_ast(&ast));
        assert_eq!(
            out,
            "<div class=\"verse center\">\n\nRoses are red,\n\n\u{2003}violets are blue.\\\n1\\. not a list\n\n</div>\n"
        );
    }

    #[test]
    fn a_header_less_table_gets_an_empty_header_and_a_delimiter() {
        let mut b = Builder::new();
        let a = str_leaf(&mut b, "a");
        let c1 = b.add_container(Kind::Cell(Cell::new(false, Alignment::Default)), &[a]);
        let bb = str_leaf(&mut b, "b");
        let c2 = b.add_container(Kind::Cell(Cell::new(false, Alignment::Default)), &[bb]);
        let row = b.add_container(Kind::Row { head: false }, &[c1, c2]);
        let table = b.add_container(Kind::Table, &[row]);
        let root = b.add_container(Kind::Doc, &[table]);
        let ast = b.finish(root);
        assert_eq!(s(serialize_ast(&ast)), "|  |  |\n| --- | --- |\n| a | b |\n");
    }

    #[test]
    fn an_unclassified_container_passes_through_as_a_tag() {
        let mut b = Builder::new();
        let y = str_leaf(&mut b, "y");
        let el = b.add_container(Kind::Container(Container::named(b"my-widget")), &[y]);
        let x = str_leaf(&mut b, "x ");
        let para = b.add_container(Kind::Para, &[x, el]);
        let root = b.add_container(Kind::Doc, &[para]);
        let src = s(serialize_ast(&b.finish(root)));
        assert!(contains(&src, "<my-widget>y</my-widget>"));
        assert!(!contains(&src, ":my-widget"));
    }

    #[test]
    fn an_unclassified_container_keeps_its_attributes() {
        let mut b = Builder::new();
        let hi = str_leaf(&mut b, "hi");
        let p = b.add_container(Kind::Para, &[hi]);
        let el = b.add_container(Kind::Container(Container::named(b"video")), &[p]);
        b.set_attrs(
            el,
            Attrs { entries: vec![KeyVal::new(b"controls", None), KeyVal::new(b"src", Some(b"a.mp4"))] },
        );
        let root = b.add_container(Kind::Doc, &[el]);
        let src = s(serialize_ast(&b.finish(root)));
        assert!(contains(&src, "<video controls src=\"a.mp4\">"));
    }

    #[test]
    fn an_insert_converted_from_elsewhere_prints_as_u() {
        let mut b = Builder::new();
        let x = str_leaf(&mut b, "x");
        let ins = b.add_container(Kind::InlineMark(InlineMark::Insert), &[x]);
        let para = b.add_container(Kind::Para, &[ins]);
        let root = b.add_container(Kind::Doc, &[para]);
        assert_eq!(s(serialize_ast(&b.finish(root))), "<u>x</u>\n");
    }

    #[test]
    fn highlight_colors_a_mark_converted_from_elsewhere_prints_tight() {
        let mut b = Builder::new();
        let x = str_leaf(&mut b, "x");
        let mark = b.add_container(Kind::InlineMark(InlineMark::Mark), &[x]);
        b.set_attrs(mark, Attrs { entries: vec![KeyVal::new(b"data-color", Some(b"blue"))] });
        let para = b.add_container(Kind::Para, &[mark]);
        let root = b.add_container(Kind::Doc, &[para]);
        assert_eq!(s(serialize_ast(&b.finish(root))), "==\u{1F535}x==\n");
    }

    #[test]
    fn an_anonymous_span_with_nothing_to_say_still_yields_its_text() {
        let mut b = Builder::new();
        let x = str_leaf(&mut b, "x");
        let span = b.add_container(Kind::Container(Container::with_form(b"", Form::InlineText)), &[x]);
        let para = b.add_container(Kind::Para, &[span]);
        let root = b.add_container(Kind::Doc, &[para]);
        assert_eq!(s(serialize_ast(&b.finish(root))), "x\n");
    }

    #[test]
    fn a_named_fenced_container_that_is_not_a_div_keeps_the_fence() {
        let mut b = Builder::new();
        let x = str_leaf(&mut b, "x");
        let p = b.add_container(Kind::Para, &[x]);
        let bx = b.add_container(Kind::Container(Container::with_form(b"box", Form::BlockFenced)), &[p]);
        b.set_attrs(bx, Attrs { entries: vec![KeyVal::new(b"class", Some(b"c"))] });
        let root = b.add_container(Kind::Doc, &[bx]);
        assert_eq!(s(serialize_ast(&b.finish(root))), ":::box{.c}\nx\n:::\n");
    }

    #[test]
    fn fence_ticks_clears_runs() {
        assert_eq!(fence_ticks(b"", 3), 3);
        assert_eq!(fence_ticks(b"a ``` b", 3), 4);
        assert_eq!(fence_ticks(b"`", 1), 2);
        assert_eq!(fence_ticks(b"x``y`", 1), 3);
    }

    // ── tests that need the Markdown parser ────────────────────────────

    #[test]
    fn serialize_renders_basic_markdown_blocks() {
        let out = serialize_with("# hi\n\ntext\n", ParseOptions::commonmark());
        assert!(contains(&out, "# hi"));
        assert!(contains(&out, "text"));
    }

    #[test]
    fn non_canonical_list_markers_survive_the_document_path_canonicalize_on_the_ast_path() {
        let doc = parse(b"* a\n* b\n\n1) x\n", ParseOptions::commonmark());
        let spelled = s(serialize(&doc));
        assert!(contains(&spelled, "* a"));
        assert!(contains(&spelled, "1) x"));
        let canonical = s(serialize_ast(&doc.ast));
        assert!(contains(&canonical, "- a"));
        assert!(contains(&canonical, "1. x"));
        assert!(!contains(&canonical, "* a"));
    }

    #[test]
    fn verse_reads_back_under_html_elements() {
        let mut b = Builder::new();
        let t0 = str_leaf(&mut b, "Roses are red,");
        let l0 = b.add_container(Kind::Line { indent: 0 }, &[t0]);
        let gap = b.add_container(Kind::Line { indent: 0 }, &[]);
        let t1 = str_leaf(&mut b, "violets are blue.");
        let l1 = b.add_container(Kind::Line { indent: 1 }, &[t1]);
        let t2 = str_leaf(&mut b, "1. not a list");
        let l2 = b.add_container(Kind::Line { indent: 0 }, &[t2]);
        let block = b.add_container(Kind::LineBlock, &[l0, gap, l1, l2]);
        b.set_attrs(block, Attrs { entries: vec![KeyVal::new(b"class", Some(b"center"))] });
        let root = b.add_container(Kind::Doc, &[block]);
        let out = serialize_ast(&b.finish(root));

        let back = parse(&out, ParseOptions { html_elements: true, ..default_opts() });
        let lb = back.ast.node(back.ast.root).first_child.unwrap();
        assert_eq!(*back.ast.kind(lb), Kind::LineBlock);
        assert_eq!(back.ast.attrs_of(lb).get(b"class"), Some(&b"center"[..]));
        let lines = back.ast.child_ids(lb);
        assert_eq!(lines.len(), 4);
        for (n, &line) in lines.iter().enumerate() {
            let want = if n == 2 { 1 } else { 0 };
            assert_eq!(*back.ast.kind(line), Kind::Line { indent: want });
        }

        let plain = parse(&out, ParseOptions::commonmark());
        let hard = plain.ast.nodes.iter().filter(|n| n.kind == Kind::HardBreak).count();
        assert_eq!(hard, 1);
    }

    #[test]
    fn fenced_code_info_string_abuts_the_fence() {
        let out = serialize_with("```fig\nx = 1\n```\n", ParseOptions::commonmark());
        assert!(out.starts_with("```fig\n"));
        assert!(!contains(&out, "``` fig"));
    }

    #[test]
    fn nested_block_prefixes_are_emitted_in_nesting_order() {
        let out = serialize_with("- > q one\n  > q two\n", ParseOptions::commonmark());
        assert!(contains(&out, "  > q one"));
        assert!(!contains(&out, ">   q one"));
        let out = serialize_with("> - item one\n> - item two\n", ParseOptions::commonmark());
        assert!(contains(&out, "> - item one"));
    }

    #[test]
    fn a_quotes_blank_line_between_paragraphs_keeps_its_marker() {
        let doc = parse(b"> one\n>\n> two\n", ParseOptions::commonmark());
        let out = serialize(&doc);
        assert_eq!(s(out.clone()), "> one\n>\n> two\n");
        let back = parse(&out, ParseOptions::commonmark());
        assert!(doc.ast.eql(&back.ast));
        assert_eq!(serialize_with("- one\n\n  two\n", ParseOptions::commonmark()), "- one\n\n  two\n");
    }

    #[test]
    fn serialize_includes_detached_link_reference_definitions() {
        let out = serialize_with("[x][a]\n\n[a]: /u \"t\"\n", ParseOptions::commonmark());
        assert!(contains(&out, "[a]: /u"));
    }

    #[test]
    fn a_loose_bullet_lists_first_paragraph_starts_on_the_markers_line() {
        let out = serialize_with("- one\n  two\n\n- three\n", ParseOptions::commonmark());
        assert!(contains(&out, "- one\n  two\n\n- three\n"));
        assert!(!contains(&out, "- \n"));
    }

    #[test]
    fn a_header_less_table_reparses_as_a_table() {
        let mut b = Builder::new();
        let a = str_leaf(&mut b, "a");
        let c1 = b.add_container(Kind::Cell(Cell::new(false, Alignment::Default)), &[a]);
        let bb = str_leaf(&mut b, "b");
        let c2 = b.add_container(Kind::Cell(Cell::new(false, Alignment::Default)), &[bb]);
        let row = b.add_container(Kind::Row { head: false }, &[c1, c2]);
        let table = b.add_container(Kind::Table, &[row]);
        let root = b.add_container(Kind::Doc, &[table]);
        let src = serialize_ast(&b.finish(root));
        let back = parse(&src, default_opts());
        let found_table = back.ast.nodes.iter().any(|n| n.kind == Kind::Table);
        let body_cells = back.ast.nodes.iter().filter(|n| matches!(n.kind, Kind::Cell(c) if !c.head)).count();
        assert!(found_table);
        assert_eq!(body_cells, 2);
    }

    #[test]
    fn an_unclassified_container_never_reparses_as_a_directive() {
        let mut b = Builder::new();
        let y = str_leaf(&mut b, "y");
        let el = b.add_container(Kind::Container(Container::named(b"my-widget")), &[y]);
        let x = str_leaf(&mut b, "x ");
        let para = b.add_container(Kind::Para, &[x, el]);
        let root = b.add_container(Kind::Doc, &[para]);
        let src = serialize_ast(&b.finish(root));
        let doc = parse(&src, directives_on());
        assert!(doc.ast.nodes.iter().all(|n| n.kind.tag() != crate::ast::Tag::Container));
    }

    #[test]
    fn highlight_round_trips() {
        let opts = ParseOptions { highlight: true, ..default_opts() };
        assert_eq!(serialize_with("some ==lit== *and ==more==*\n", opts), "some ==lit== *and ==more==*\n");
    }

    #[test]
    fn underline_round_trips_under_html_elements() {
        let src = "some <u>lit</u> *and <u>more</u>*\n";
        assert_eq!(serialize_with(src, ParseOptions { html_elements: true, ..default_opts() }), src);
    }

    #[test]
    fn highlight_colors_round_trip() {
        let opts = ParseOptions { highlight: true, highlight_colors: true, ..default_opts() };
        for src in ["a ==\u{1F534} red== b\n", "a ==\u{1F7E2}green== b\n", "==\u{1F535} *blue* and ==\u{1F7E3}purple==\n"]
        {
            assert_eq!(serialize_with(src, opts), src);
        }
    }

    #[test]
    fn directives_serialize_back() {
        assert_eq!(serialize_with(":::note{#n .box}\nHello\n:::\n", directives_on()), ":::note{#n .box}\nHello\n:::\n");
        assert_eq!(serialize_with("::youtube[A caption]{#v}\n", directives_on()), "::youtube[A caption]{#v}\n");
        assert_eq!(
            serialize_with("See :abbr[HTML]{title=HyperText} ok.\n", directives_on()),
            "See :abbr[HTML]{title=HyperText} ok.\n"
        );
        assert_eq!(serialize_with(":span[x]{title=\"a b\"}\n", directives_on()), ":span[x]{title=\"a b\"}\n");
    }

    #[test]
    fn directive_round_trips_are_stable() {
        for src in [":::warning\ntext\n:::\n", "::hr\n", ":here\n", ":::box{.a .b key=val}\n- x\n- y\n:::\n"] {
            let first = serialize_with(src, directives_on());
            let second = serialize_with(&first, directives_on());
            assert_eq!(first, second);
        }
    }

    #[test]
    fn a_div_or_span_read_as_a_directive_is_written_back_as_one() {
        assert_eq!(serialize_with(":::div{.c}\nx\n:::\n", directives_on()), ":::div{.c}\nx\n:::\n");
        assert_eq!(serialize_with("a :span[x]{.l} b\n", directives_on()), "a :span[x]{.l} b\n");
    }

    // TODO(port): the djot/HTML → Markdown tests ("an attributed paragraph is
    // written inside a div…", "djot's anonymous div is a <div>…", …) need the
    // djot and HTML parsers; they are covered by the cross-format
    // differential test in `markdown::html`'s test module once those land.
}
