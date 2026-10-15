//! `Document` (a djot parse) -> canonical-ish Djot text. Port of
//! `djot/serializer.zig`.

use crate::ast::select::text_of;
use crate::ast::{verse, Alignment, Ast, Attrs, Form, KeyVal, Kind, KindRef, NodeId, TextLeafKind};
use crate::attrs_writer;
use crate::document::{Bullet, Document, Labels, OrderedDelim, Spelling};
use crate::syntax::djot::table as dj_table;

use super::parser::slugify;

/// A block's continuation prefix: `"> "` for a block quote, or the spaces that
/// indent a list item / definition / div body, outermost first. A block quote
/// inside a list item needs `  > `, a list inside a block quote needs `> `, so
/// the segments are kept in nesting order rather than summed.
#[derive(Clone, Debug, Default)]
struct Ctx {
    prefix: Vec<&'static [u8]>,
}

impl Ctx {
    fn push(&self, segment: &'static [u8]) -> Ctx {
        let mut prefix = self.prefix.clone();
        prefix.push(segment);
        Ctx { prefix }
    }
}

/// Djot strips one space adjacent to a backtick at each end of verbatim text,
/// so text that starts or ends with a backtick is padded on that side.
fn verbatim_pad(text: &[u8]) -> (bool, bool) {
    (text.first() == Some(&b'`'), text.last() == Some(&b'`'))
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
        // Zig's `i = j` followed by the loop's own `i += 1`.
        i = j + 1;
    }
    best
}

/// Whether `id` is what `slugify` and its uniquifier would have made of a
/// title whose slug is `slug`: the slug itself, or the slug and a `-N` suffix.
fn is_generated_id(id: &[u8], slug: &[u8]) -> bool {
    let base: &[u8] = if slug.is_empty() { b"s" } else { slug };
    if id == base {
        return !slug.is_empty();
    }
    if id.len() < base.len() + 2 || !id.starts_with(base) || id[base.len()] != b'-' {
        return false;
    }
    id[base.len() + 1..].iter().all(|c| c.is_ascii_digit())
}

/// Where a backslash goes so that `text`, opening a paragraph, reads back as
/// text and not as the block it starts — before the byte at the returned
/// index — or `None`.
fn verse_escape_at(text: &[u8]) -> Option<usize> {
    if text.is_empty() {
        return None;
    }
    if matches!(
        text[0],
        b'#' | b'>' | b'-' | b'+' | b'*' | b':' | b'|' | b'^' | b'[' | b'{' | b'`' | b'~' | b'(' | b'=' | b'_'
    ) {
        return Some(0);
    }
    let mut i = 0;
    while i < text.len() && i < 9 && text[i].is_ascii_alphanumeric() {
        i += 1;
    }
    if i == 0 || i + 1 >= text.len() {
        return None;
    }
    if text[i] != b'.' && text[i] != b')' {
        return None;
    }
    if text[i + 1] != b' ' && text[i + 1] != b'\t' {
        return None;
    }
    let word = &text[..i];
    let digits = word.iter().all(|c| c.is_ascii_digit());
    let roman = word.iter().all(|c| b"ivxlcdmIVXLCDM".contains(c));
    if !(digits || roman || word.len() == 1) {
        return None;
    }
    Some(i)
}

fn trim_ws(s: &[u8]) -> &[u8] {
    let is = |c: &u8| matches!(c, b' ' | b'\t' | b'\r' | b'\n');
    let a = s.iter().position(|c| !is(c)).unwrap_or(s.len());
    let b = s.iter().rposition(|c| !is(c)).map(|i| i + 1).unwrap_or(a);
    &s[a..b.max(a)]
}

fn write_attrs_with(w: &mut Vec<u8>, attrs: &Attrs) {
    if let Some(sp) = &dj_table().attr_spelling {
        attrs_writer::write(w, attrs, sp, b"");
    }
}

struct Renderer<'d> {
    doc: &'d Document,
    ast: &'d Ast,
    w: Vec<u8>,
}

impl<'d> Renderer<'d> {
    fn new(doc: &'d Document) -> Self {
        Renderer { doc, ast: &doc.ast, w: Vec::new() }
    }

    fn write_prefix(&mut self, ctx: &Ctx) {
        for seg in &ctx.prefix {
            self.w.extend_from_slice(seg);
        }
    }

    /// Re-emit `{#id .class key="val"}` from the node's attrs.
    fn write_djot_attrs(&mut self, id: NodeId) {
        write_attrs_with(&mut self.w, self.ast.attrs_of(id));
    }

    /// A section's attributes are written as the line before its heading.
    fn write_section_attrs(&mut self, id: NodeId, ctx: &Ctx) {
        let Some(heading) = self.ast.nodes[id as usize].first_child else { return };
        if !matches!(self.ast.nodes[heading as usize].kind, Kind::Heading { .. }) {
            return;
        }
        self.write_title_attrs(id, heading, ctx);
    }

    /// The attribute line above a heading, for the set `owner` carries. An id
    /// that still reads as the parser's derivation from the title is left out.
    fn write_title_attrs(&mut self, owner: NodeId, heading: NodeId, ctx: &Ctx) {
        let attrs = self.ast.attrs_of(owner);
        if attrs.is_empty() {
            return;
        }
        let mut kept: Vec<KeyVal> = Vec::new();
        for kv in &attrs.entries {
            if kv.key == b"id" {
                let text = text_of(self.ast, heading);
                let slug = slugify(trim_ws(&text));
                if let Some(v) = &kv.value {
                    if is_generated_id(v, &slug) {
                        continue;
                    }
                }
            }
            kept.push(kv.clone());
        }
        if kept.is_empty() {
            return;
        }
        if dj_table().attr_spelling.is_none() {
            return;
        }
        self.write_prefix(ctx);
        write_attrs_with(&mut self.w, &Attrs { entries: kept });
        self.w.push(b'\n');
    }

    fn render_blocks(&mut self, parent: NodeId, ctx: &Ctx, blank_between: bool) {
        let first = self.ast.nodes[parent as usize].first_child;
        self.render_blocks_from(first, ctx, blank_between, true);
    }

    /// Like `render_blocks`, but starting at sibling `start`. `first` marks
    /// whether `start` is the first block of the container overall.
    fn render_blocks_from(&mut self, start: Option<NodeId>, ctx: &Ctx, blank_between: bool, first: bool) {
        let mut is_first = first;
        let mut cur = start;
        while let Some(child) = cur {
            if !is_first && blank_between {
                self.write_blank_line(ctx);
            }
            self.render_block(child, ctx);
            is_first = false;
            cur = self.ast.nodes[child as usize].next_sibling;
        }
    }

    /// A blank line between two blocks of the same container: the prefix with
    /// its trailing spaces trimmed (`>` inside a quote, nothing in a list).
    fn write_blank_line(&mut self, ctx: &Ctx) {
        let mut line: Vec<u8> = Vec::new();
        for seg in &ctx.prefix {
            line.extend_from_slice(seg);
        }
        while line.last() == Some(&b' ') {
            line.pop();
        }
        self.w.extend_from_slice(&line);
        self.w.push(b'\n');
    }

    fn render_inline_children(&mut self, parent: NodeId, ctx: &Ctx) {
        let mut cur = self.ast.nodes[parent as usize].first_child;
        while let Some(c) = cur {
            self.render_inline(c, ctx);
            cur = self.ast.nodes[c as usize].next_sibling;
        }
    }

    /// Write inline text, re-emitting `ctx`'s block prefix after each embedded
    /// newline. A trailing newline gets no prefix.
    fn write_inline_text(&mut self, s: &[u8], ctx: &Ctx) {
        let mut rest = s;
        while let Some(nl) = rest.iter().position(|&c| c == b'\n') {
            self.w.extend_from_slice(&rest[..nl + 1]);
            rest = &rest[nl + 1..];
            if !rest.is_empty() {
                self.write_prefix(ctx);
            }
        }
        self.w.extend_from_slice(rest);
    }

    /// A backtick-delimited inline span, widened past any backtick run in
    /// `text` and padded per `verbatim_pad`.
    fn write_tick_fenced(&mut self, text: &[u8]) {
        let ticks = fence_ticks(text, 1);
        let (left, right) = verbatim_pad(text);
        self.w.extend(std::iter::repeat_n(b'`', ticks));
        if left {
            self.w.push(b' ');
        }
        self.w.extend_from_slice(text);
        if right {
            self.w.push(b' ');
        }
        self.w.extend(std::iter::repeat_n(b'`', ticks));
    }

    /// `raw` writes the info string as djot's raw-block form (```` ```=html ````).
    fn write_code_fence(&mut self, ctx: &Ctx, info: Option<&[u8]>, text: &[u8], raw: bool) {
        let ticks = fence_ticks(text, 3);
        self.write_prefix(ctx);
        self.w.extend(std::iter::repeat_n(b'`', ticks));
        if raw {
            self.w.push(b'=');
        }
        if let Some(lang) = info {
            self.w.extend_from_slice(lang);
        }
        self.w.push(b'\n');
        self.w.extend_from_slice(text);
        if text.last() != Some(&b'\n') {
            self.w.push(b'\n');
        }
        self.write_prefix(ctx);
        self.w.extend(std::iter::repeat_n(b'`', ticks));
        self.w.push(b'\n');
    }

    fn render_list_item(&mut self, item_id: NodeId, marker: &[u8], ctx: &Ctx, tight: bool) {
        self.write_prefix(ctx);
        self.w.extend_from_slice(marker);
        let Some(first) = self.ast.nodes[item_id as usize].first_child else {
            self.w.push(b'\n');
            return;
        };
        let item_ctx = ctx.push(b"  ");
        // A leading paragraph always starts on the marker's own line.
        if self.ast.nodes[first as usize].kind == Kind::Para {
            self.render_inline_children(first, &item_ctx);
            self.w.push(b'\n');
            let next = self.ast.nodes[first as usize].next_sibling;
            if tight && next.is_none() {
                return;
            }
            self.render_blocks_from(next, &item_ctx, !tight, false);
            return;
        }
        self.w.push(b'\n');
        self.render_blocks(item_id, &item_ctx, !tight);
    }

    fn row_has_alignment(&self, row_id: NodeId) -> bool {
        self.ast.children(row_id).any(|c| matches!(&c.kind, Kind::Cell(cell) if cell.alignment != Alignment::Default))
    }

    /// `|---|:--|` — written without padding spaces, the spelling djot.js reads
    /// back as a separator.
    fn write_table_separator(&mut self, row_id: NodeId, ctx: &Ctx) {
        if self.ast.nodes[row_id as usize].first_child.is_none() {
            return;
        }
        self.write_prefix(ctx);
        self.w.push(b'|');
        let cells: Vec<Alignment> = self
            .ast
            .children(row_id)
            .map(|c| match &c.kind {
                Kind::Cell(cell) => cell.alignment,
                _ => Alignment::Default,
            })
            .collect();
        for a in cells {
            self.w.extend_from_slice(match a {
                Alignment::Default => b"---",
                Alignment::Left => b":--",
                Alignment::Right => b"--:",
                Alignment::Center => b":-:",
            });
            self.w.push(b'|');
        }
        self.w.push(b'\n');
    }

    fn render_detached_definitions(&mut self) {
        let mut wrote_any = false;
        for n in &self.ast.nodes {
            match &n.kind {
                Kind::Reference { label, destination } => {
                    let in_refs = self.doc.labels.references.get(label) == Some(&n.id);
                    // Headings recreate their implicit references on reparse.
                    if !in_refs {
                        continue;
                    }
                    if wrote_any {
                        self.w.push(b'\n');
                    }
                    if !self.ast.attrs_of(n.id).entries.is_empty() {
                        self.write_djot_attrs(n.id);
                        self.w.push(b'\n');
                    }
                    self.w.push(b'[');
                    self.w.extend_from_slice(label);
                    self.w.extend_from_slice(b"]: ");
                    self.w.extend_from_slice(destination);
                    self.w.push(b'\n');
                    wrote_any = true;
                }
                Kind::Footnote { label } => {
                    let Some(id) = self.doc.labels.footnote(label) else { continue };
                    if id != n.id {
                        continue;
                    }
                    if wrote_any {
                        self.w.push(b'\n');
                    }
                    self.write_footnote_definition(n.id, label);
                    wrote_any = true;
                }
                // A citation is written as a djot footnote definition.
                Kind::Citation { label } => {
                    if wrote_any {
                        self.w.push(b'\n');
                    }
                    self.write_footnote_definition(n.id, label);
                    wrote_any = true;
                }
                _ => {}
            }
        }
    }

    /// `[^label]: body`.
    fn write_footnote_definition(&mut self, id: NodeId, label: &[u8]) {
        self.w.extend_from_slice(b"[^");
        self.w.extend_from_slice(label);
        self.w.extend_from_slice(b"]: ");
        if self.ast.nodes[id as usize].first_child.is_some() {
            let mut inner = Renderer::new(self.doc);
            inner.render_blocks(id, &Ctx::default(), false);
            let mut body = &inner.w[..];
            while body.last() == Some(&b'\n') {
                body = &body[..body.len() - 1];
            }
            self.w.extend_from_slice(body);
        }
        self.w.push(b'\n');
    }

    /// A `line_block` as the verse `ast::verse` reads back: a `::: verse` div
    /// whose paragraphs are the stanzas.
    fn render_verse(&mut self, id: NodeId, ctx: &Ctx) {
        let attrs = self.ast.attrs_of(id);
        let mut kept: Vec<KeyVal> = Vec::new();
        for kv in &attrs.entries {
            if kv.key == b"class" {
                let mut class: Vec<u8> = Vec::new();
                if let Some(v) = &kv.value {
                    for t in v.split(|c| matches!(c, b' ' | b'\t' | b'\r' | b'\n')).filter(|t| !t.is_empty()) {
                        if t == verse::CLASS_TOKEN {
                            continue;
                        }
                        if !class.is_empty() {
                            class.push(b' ');
                        }
                        class.extend_from_slice(t);
                    }
                }
                if !class.is_empty() {
                    kept.push(KeyVal { key: b"class".to_vec(), value: Some(class) });
                }
                continue;
            }
            kept.push(kv.clone());
        }
        if !kept.is_empty() && dj_table().attr_spelling.is_some() {
            self.write_prefix(ctx);
            write_attrs_with(&mut self.w, &Attrs { entries: kept });
            self.w.push(b'\n');
        }
        self.write_prefix(ctx);
        self.w.extend_from_slice(b"::: ");
        self.w.extend_from_slice(verse::CLASS_TOKEN);
        self.w.push(b'\n');
        let mut in_stanza = false;
        let lines = self.ast.child_ids(id);
        for line in lines {
            if self.ast.nodes[line as usize].first_child.is_none() {
                if in_stanza {
                    self.w.push(b'\n');
                    self.write_prefix(ctx);
                    self.w.push(b'\n');
                    in_stanza = false;
                }
                continue;
            }
            if in_stanza {
                self.w.extend_from_slice(b"\\\n");
            }
            self.write_prefix(ctx);
            let indent = match self.ast.nodes[line as usize].kind {
                Kind::Line { indent } => indent,
                _ => 0,
            };
            for _ in 0..indent {
                self.w.extend_from_slice(verse::EM_SPACE);
            }
            self.render_verse_line(line, ctx, indent == 0 && !in_stanza);
            in_stanza = true;
        }
        if in_stanza {
            self.w.push(b'\n');
        }
        self.write_prefix(ctx);
        self.w.extend_from_slice(b":::\n");
    }

    /// One verse line's inlines; a stanza's first line, at the margin, takes a
    /// backslash before what djot would read as the start of a block.
    fn render_verse_line(&mut self, line: NodeId, ctx: &Ctx, opens_stanza: bool) {
        let Some(first) = self.ast.nodes[line as usize].first_child else { return };
        if opens_stanza {
            if let Kind::Str(text) = &self.ast.nodes[first as usize].kind {
                if let Some(at) = verse_escape_at(text) {
                    self.w.extend_from_slice(&text[..at]);
                    self.w.push(b'\\');
                    self.write_inline_text(&text[at..], ctx);
                    let mut cur = self.ast.nodes[first as usize].next_sibling;
                    while let Some(c) = cur {
                        self.render_inline(c, ctx);
                        cur = self.ast.nodes[c as usize].next_sibling;
                    }
                    return;
                }
            }
        }
        self.render_inline_children(line, ctx);
    }

    fn render_block(&mut self, id: NodeId, ctx: &Ctx) {
        let ast = self.ast;
        match &ast.nodes[id as usize].kind {
            Kind::Doc => self.render_blocks(id, ctx, true),
            Kind::Section => {
                self.write_section_attrs(id, ctx);
                self.render_blocks(id, ctx, true);
            }
            Kind::Para => {
                if !ast.attrs_of(id).entries.is_empty() {
                    self.write_prefix(ctx);
                    self.write_djot_attrs(id);
                    self.w.push(b'\n');
                }
                self.write_prefix(ctx);
                self.render_inline_children(id, ctx);
                self.w.push(b'\n');
            }
            Kind::Heading { level } => {
                self.write_title_attrs(id, id, ctx);
                self.write_prefix(ctx);
                for _ in 0..*level {
                    self.w.push(b'#');
                }
                self.w.push(b' ');
                self.render_inline_children(id, ctx);
                self.w.push(b'\n');
            }
            Kind::ThematicBreak => {
                self.write_prefix(ctx);
                self.w.extend_from_slice(b"* * *\n");
            }
            Kind::BlockQuote => {
                let p = ctx.push(b"> ");
                self.render_blocks(id, &p, true);
            }
            Kind::Container(c) => {
                // An inline container reaching block position is its inline
                // spelling on a line of its own.
                if c.form == Some(Form::InlineText) {
                    self.write_prefix(ctx);
                    self.render_inline(id, ctx);
                    self.w.push(b'\n');
                    return;
                }
                // A div's attributes attach to the line BEFORE the fence.
                if !ast.attrs_of(id).entries.is_empty() {
                    self.write_prefix(ctx);
                    self.write_djot_attrs(id);
                    self.w.push(b'\n');
                }
                self.write_prefix(ctx);
                self.w.extend_from_slice(b":::");
                // A NAMED container rides on the fence's class line.
                if !c.name.is_empty() {
                    self.w.push(b' ');
                    self.w.extend_from_slice(&c.name);
                }
                self.w.push(b'\n');
                let p = ctx.push(b"  ");
                if let Some(text) = &c.text {
                    self.write_prefix(&p);
                    self.write_inline_text(text, &p);
                    if text.last() != Some(&b'\n') {
                        self.w.push(b'\n');
                    }
                } else {
                    self.render_blocks(id, &p, true);
                }
                self.write_prefix(ctx);
                self.w.extend_from_slice(b":::\n");
            }
            Kind::CodeBlock { lang, text } => self.write_code_fence(ctx, lang.as_deref(), text, false),
            // A formatless raw block falls back to a bare fence.
            Kind::RawBlock { format, text } => self.write_code_fence(ctx, Some(format), text, !format.is_empty()),
            Kind::Metadata { lang, text } => {
                self.write_prefix(ctx);
                if lang == b"yaml" {
                    self.w.extend_from_slice(b"---\n");
                } else {
                    self.w.extend_from_slice(b"---");
                    self.w.extend_from_slice(lang);
                    self.w.push(b'\n');
                }
                self.w.extend_from_slice(text);
                if text.last() != Some(&b'\n') {
                    self.w.push(b'\n');
                }
                self.write_prefix(ctx);
                self.w.extend_from_slice(b"---\n");
            }
            Kind::BulletList { tight } => {
                let marker: &[u8] = match bullet_of(self.doc.spelling(id)) {
                    Bullet::Dash => b"- ",
                    Bullet::Plus => b"+ ",
                    Bullet::Star => b"* ",
                };
                let tight = *tight;
                for (i, item) in ast.child_ids(id).into_iter().enumerate() {
                    if i > 0 && !tight {
                        self.w.push(b'\n');
                    }
                    self.render_list_item(item, marker, ctx, tight);
                }
            }
            Kind::OrderedList { tight, start, .. } => {
                let tight = *tight;
                let mut n: u32 = start.unwrap_or(1);
                let delim = delim_of(self.doc.spelling(id));
                for (i, item) in ast.child_ids(id).into_iter().enumerate() {
                    if i > 0 && !tight {
                        self.w.push(b'\n');
                    }
                    let marker = match delim {
                        OrderedDelim::Period => format!("{n}. "),
                        OrderedDelim::ParenAfter => format!("{n}) "),
                        OrderedDelim::ParenBoth => format!("({n}) "),
                    };
                    self.render_list_item(item, marker.as_bytes(), ctx, tight);
                    n = n.wrapping_add(1);
                }
            }
            Kind::TaskList { tight } => {
                let tight = *tight;
                for (i, item) in ast.child_ids(id).into_iter().enumerate() {
                    if i > 0 && !tight {
                        self.w.push(b'\n');
                    }
                    let checked = matches!(ast.nodes[item as usize].kind, Kind::TaskListItem { checked: true });
                    let marker: &[u8] = if checked { b"- [x] " } else { b"- [ ] " };
                    self.render_list_item(item, marker, ctx, tight);
                }
            }
            Kind::DefinitionList => {
                for dli in ast.child_ids(id) {
                    for cid in ast.child_ids(dli) {
                        match &ast.nodes[cid as usize].kind {
                            Kind::Term => {
                                self.write_prefix(ctx);
                                self.render_inline_children(cid, ctx);
                                self.w.push(b'\n');
                            }
                            Kind::Definition => {
                                self.write_prefix(ctx);
                                self.w.extend_from_slice(b": ");
                                match ast.nodes[cid as usize].first_child {
                                    Some(f) => {
                                        if ast.nodes[f as usize].kind == Kind::Para
                                            && ast.nodes[f as usize].next_sibling.is_none()
                                        {
                                            self.render_inline_children(f, ctx);
                                            self.w.push(b'\n');
                                        } else {
                                            self.w.push(b'\n');
                                            let p = ctx.push(b"  ");
                                            self.render_blocks(cid, &p, true);
                                        }
                                    }
                                    None => self.w.push(b'\n'),
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Kind::LineBlock => self.render_verse(id, ctx),
            Kind::Table => {
                // The caption is written AFTER the rows; an emptied caption
                // node means "no caption".
                let caption_id = ast
                    .children(id)
                    .find(|c| c.kind == Kind::Caption && c.first_child.is_some())
                    .map(|c| c.id);
                let rows: Vec<_> = ast.table_rows(id).collect();
                let mut is_first = true;
                for row in rows {
                    // Alignment on a table that opens with a body row can only
                    // be spelled as a leading separator.
                    if is_first && !row.head && self.row_has_alignment(row.id) {
                        self.write_table_separator(row.id, ctx);
                    }
                    is_first = false;
                    self.write_prefix(ctx);
                    self.w.push(b'|');
                    for cell in ast.child_ids(row.id) {
                        self.w.push(b' ');
                        self.render_inline_children(cell, ctx);
                        self.w.extend_from_slice(b" |");
                    }
                    self.w.push(b'\n');
                    // A row is a header because a separator line follows it.
                    if row.head {
                        self.write_table_separator(row.id, ctx);
                    }
                }
                if let Some(cid) = caption_id {
                    self.write_prefix(ctx);
                    self.w.extend_from_slice(b"^ ");
                    self.render_inline_children(cid, ctx);
                    self.w.push(b'\n');
                }
            }
            // Written once, together, by `render_detached_definitions`.
            Kind::Reference { .. } | Kind::Footnote { .. } | Kind::Citation { .. } | Kind::Substitution { .. } => {}
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
                self.w.push(b'\n');
            }
        }
    }

    fn render_inline(&mut self, id: NodeId, ctx: &Ctx) {
        let ast = self.ast;
        match &ast.nodes[id as usize].kind {
            Kind::Str(s) => self.write_inline_text(s, ctx),
            Kind::SoftBreak => {
                self.w.push(b'\n');
                self.write_prefix(ctx);
            }
            Kind::HardBreak => {
                self.w.extend_from_slice(b"\\\n");
                self.write_prefix(ctx);
            }
            Kind::NonBreakingSpace => self.w.extend_from_slice(b"\\ "),
            // Delimiters come from the djot syntax table.
            Kind::InlineMark(m) => {
                let Some(d) = dj_table().delims_for(&KindRef::Mark(*m)).copied() else { return };
                self.w.extend_from_slice(d.open);
                self.render_inline_children(id, ctx);
                self.w.extend_from_slice(d.close);
            }
            Kind::TextLeaf { kind, text } => match kind {
                TextLeafKind::Symb => {
                    self.w.push(b':');
                    self.w.extend_from_slice(text);
                    self.w.push(b':');
                }
                TextLeafKind::Verbatim => self.write_tick_fenced(text),
                TextLeafKind::InlineMath => {
                    self.w.push(b'$');
                    self.write_tick_fenced(text);
                }
                TextLeafKind::DisplayMath => {
                    self.w.extend_from_slice(b"$$");
                    self.write_tick_fenced(text);
                }
                TextLeafKind::Url | TextLeafKind::Email => {
                    self.w.push(b'<');
                    self.w.extend_from_slice(text);
                    self.w.push(b'>');
                }
                TextLeafKind::FootnoteReference | TextLeafKind::CitationReference => {
                    self.w.extend_from_slice(b"[^");
                    self.w.extend_from_slice(text);
                    self.w.push(b']');
                }
                TextLeafKind::SubstitutionReference => {
                    self.w.push(b'|');
                    self.w.extend_from_slice(text);
                    self.w.push(b'|');
                }
            },
            // Djot spells raw inline content `` `<br>`{=html} ``.
            Kind::RawInline { format, text } => {
                self.write_tick_fenced(text);
                if !format.is_empty() {
                    self.w.extend_from_slice(b"{=");
                    self.w.extend_from_slice(format);
                    self.w.push(b'}');
                }
            }
            Kind::SmartPunctuation(sp) => self.w.extend_from_slice(sp.ascii().as_bytes()),
            Kind::Link(l) | Kind::Image(l) => {
                if matches!(ast.nodes[id as usize].kind, Kind::Image(_)) {
                    self.w.extend_from_slice(b"![");
                } else {
                    self.w.push(b'[');
                }
                self.render_inline_children(id, ctx);
                self.w.push(b']');
                if let Some(dest) = &l.destination {
                    self.w.push(b'(');
                    self.w.extend_from_slice(dest);
                    self.w.push(b')');
                } else if let Some(lab) = &l.reference {
                    self.w.push(b'[');
                    self.w.extend_from_slice(lab);
                    self.w.push(b']');
                }
            }
            Kind::Container(c) => {
                // A container with neither a name nor attributes has nothing to
                // spell: `[x]` without a brace block is literal text.
                let attrs = ast.attrs_of(id);
                if c.name.is_empty() && attrs.entries.is_empty() {
                    self.render_inline_children(id, ctx);
                    return;
                }
                self.w.push(b'[');
                match &c.text {
                    Some(text) => self.write_inline_text(text, ctx),
                    None => self.render_inline_children(id, ctx),
                }
                self.w.push(b']');
                if !c.name.is_empty() {
                    self.w.extend_from_slice(b"{.");
                    self.w.extend_from_slice(&c.name);
                    self.w.push(b'}');
                }
                self.write_djot_attrs(id);
            }
            _ => self.render_inline_children(id, ctx),
        }
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

/// Serialize a djot `Document` (canonical round trip), appending to `out`.
pub fn serialize_into(doc: &Document, out: &mut Vec<u8>) {
    let mut r = Renderer::new(doc);
    r.render_block(doc.ast.root, &Ctx::default());
    out.extend_from_slice(&r.w);

    let mut tail = Renderer::new(doc);
    tail.render_detached_definitions();
    if !tail.w.is_empty() {
        if doc.ast.nodes[doc.ast.root as usize].first_child.is_some() {
            out.push(b'\n');
        }
        out.extend_from_slice(&tail.w);
    }
}

/// Serialize a djot `Document` (`serializeAlloc` in Zig).
pub fn serialize(doc: &Document) -> Vec<u8> {
    let mut out = Vec::new();
    serialize_into(doc, &mut out);
    out
}

/// Serialize a bare, language-agnostic `Ast` (e.g. another format's parse, for
/// cross-format conversion). The label tables are rebuilt with
/// `Labels::index`, so every reference is printed explicitly.
pub fn serialize_ast(ast: &Ast) -> Vec<u8> {
    serialize_ast_spelled(ast, &[])
}

/// `serialize_ast` plus a spelling table, for a caller that knows how its
/// lists were spelled.
pub fn serialize_ast_spelled(ast: &Ast, node_spelling: &[Option<Spelling>]) -> Vec<u8> {
    let labels = Labels::index(ast);
    let mut doc = Document::from_ast(b"", ast.clone());
    doc.node_spelling = node_spelling.to_vec();
    doc.labels = labels;
    serialize(&doc)
}

#[cfg(test)]
mod tests {
    use super::super::parse;
    use super::*;
    use crate::ast::{Builder, Container};

    fn ser(src: &[u8]) -> String {
        String::from_utf8(serialize(&parse(src))).unwrap()
    }

    #[test]
    fn renders_basic_djot_content() {
        let out = ser(b"# Title\n\nhello *world*\n");
        assert!(out.contains("# Title"));
        assert!(out.contains("*world*"));
    }

    #[test]
    fn non_canonical_list_markers_survive_document_path_only() {
        let doc = parse(b"+ a\n+ b\n\n(1) x\n");
        let spelled = String::from_utf8(serialize(&doc)).unwrap();
        assert!(spelled.contains("+ a"));
        assert!(spelled.contains("(1) x"));
        let canonical = String::from_utf8(serialize_ast(&doc.ast)).unwrap();
        assert!(canonical.contains("- a"));
        assert!(canonical.contains("1. x"));
        assert!(!canonical.contains("+ a"));
    }

    #[test]
    fn fenced_code_language_abuts_the_fence() {
        let out = ser(b"```fig\nx = 1\n```\n");
        assert!(out.starts_with("```fig\n"));
        assert!(!out.contains("``` fig"));
    }

    #[test]
    fn nested_block_prefixes_in_nesting_order() {
        let out = ser(b"- > q one\n  > q two\n");
        assert!(out.contains("  > q one"));
        assert!(!out.contains(">   q one"));
        assert!(ser(b"> - item one\n> - item two\n").contains("> - item one"));
    }

    #[test]
    fn quote_blank_line_keeps_its_marker() {
        let doc = parse(b"> one\n>\n> two\n");
        let out = serialize(&doc);
        assert_eq!(out, b"> one\n>\n> two\n");
        assert!(doc.ast.eql(&parse(&out).ast));
        assert_eq!(ser(b"- one\n\n  two\n"), "- one\n\n  two\n");
    }

    #[test]
    fn includes_detached_reference_definitions() {
        assert!(ser(b"[x][a]\n\n[a]: /u\n").contains("[a]: /u"));
    }

    #[test]
    fn header_row_written_with_separator() {
        assert_eq!(ser(b"|a|b|\n|---|---|\n|c|d|\n"), "| a | b |\n|---|---|\n| c | d |\n");
    }

    #[test]
    fn each_header_gets_its_own_separator() {
        assert_eq!(
            ser(b"|a|b|\n|:-|---:|\n|c|d|\n|cc|dd|\n|-:|:-:|\n|e|f|\n"),
            "| a | b |\n|:--|--:|\n| c | d |\n| cc | dd |\n|--:|:-:|\n| e | f |\n"
        );
    }

    #[test]
    fn table_caption_written_after_the_table() {
        assert_eq!(
            ser(b"| a |\n|---|\n\n^ With a _caption_\nand another line.\n"),
            "| a |\n|---|\n^ With a _caption_\nand another line.\n"
        );
    }

    #[test]
    fn captionless_table_gets_no_caret_line() {
        assert_eq!(ser(b"| a |\n|---|\n"), "| a |\n|---|\n");
    }

    #[test]
    fn nested_table_caption_keeps_prefix() {
        let out = serialize(&parse(b"> | a |\n> |---|\n>\n> ^ Cap\n"));
        assert_eq!(out, b"> | a |\n> |---|\n> ^ Cap\n");
        let rendered = super::super::html::render(&parse(&out), &Default::default()).unwrap();
        let rendered = String::from_utf8(rendered).unwrap();
        assert!(rendered.contains("<caption>Cap</caption>"));
        assert!(!rendered.contains("<blockquote>\n</blockquote>"));
    }

    #[test]
    fn table_opening_with_separator_keeps_alignment() {
        assert_eq!(ser(b"|:--|---:|\n| x | 2 |\n"), "|:--|--:|\n| x | 2 |\n");
    }

    #[test]
    fn raw_inline_keeps_raw_spelling() {
        assert_eq!(ser(b"x `<sub>`{=html}y`</sub>`{=html} z\n"), "x `<sub>`{=html}y`</sub>`{=html} z\n");
    }

    #[test]
    fn raw_block_keeps_eq_form() {
        assert_eq!(ser(b"``` =html\n<hr>\n```\n"), "```=html\n<hr>\n```\n");
    }

    #[test]
    fn backtick_edged_verbatim_is_padded() {
        assert_eq!(ser(b"`` ` ``\n"), "`` ` ``\n");
        assert_eq!(ser(b"`` `x` ``{=html}\n"), "`` `x` ``{=html}\n");
    }

    fn line(b: &mut Builder, indent: u32, text: Option<&str>) -> NodeId {
        let kids: Vec<NodeId> = text.map(|t| b.add_leaf(Kind::Str(t.as_bytes().to_vec()))).into_iter().collect();
        b.add_container(Kind::Line { indent }, &kids)
    }

    #[test]
    fn line_block_is_a_verse_div_and_reads_back() {
        let mut b = Builder::new();
        let l0 = line(&mut b, 0, Some("Roses are red,"));
        let l1 = line(&mut b, 1, Some("violets are blue."));
        let gap = line(&mut b, 0, None);
        let last = line(&mut b, 0, Some("Fin."));
        let block = b.add_container(Kind::LineBlock, &[l0, l1, gap, last]);
        let root = b.add_container(Kind::Doc, &[block]);
        let ast = b.finish(root);
        let out = serialize_ast(&ast);
        assert_eq!(out, "::: verse\nRoses are red,\\\n\u{2003}violets are blue.\n\nFin.\n:::\n".as_bytes());
        let back = parse(&out);
        let lb = back.ast.nodes[back.ast.root as usize].first_child.unwrap();
        assert_eq!(back.ast.kind(lb), &Kind::LineBlock);
        let lines = back.ast.child_ids(lb);
        let indents: Vec<u32> = lines
            .iter()
            .map(|&l| match back.ast.kind(l) {
                Kind::Line { indent } => *indent,
                _ => 99,
            })
            .collect();
        assert_eq!(indents, vec![0, 1, 0, 0]);
        let empties: Vec<bool> = lines.iter().map(|&l| back.ast.nodes[l as usize].first_child.is_none()).collect();
        assert_eq!(empties, vec![false, false, true, false]);
    }

    #[test]
    fn verse_line_opening_stanza_with_block_syntax_is_escaped() {
        let mut b = Builder::new();
        let l0 = line(&mut b, 0, Some("# not a heading"));
        let l1 = line(&mut b, 0, Some("- mid-stanza, left alone"));
        let gap = line(&mut b, 0, None);
        let l2 = line(&mut b, 0, Some("iv. not a list"));
        let block = b.add_container(Kind::LineBlock, &[l0, l1, gap, l2]);
        let root = b.add_container(Kind::Doc, &[block]);
        let out = serialize_ast(&b.finish(root));
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "::: verse\n\\# not a heading\\\n- mid-stanza, left alone\n\niv\\. not a list\n:::\n"
        );
    }

    #[test]
    fn loose_list_first_paragraph_on_marker_line() {
        let out = ser(b"- one\n  two\n\n- three\n");
        assert!(out.contains("- one\n  two\n\n- three\n"));
        assert!(!out.contains("- \n"));
    }

    #[test]
    fn div_attributes_go_above_the_fence() {
        let out = serialize(&parse(b"{#i .c}\n:::\nhi\n:::\n"));
        let back = parse(&out);
        let mut found = false;
        for (i, n) in back.ast.nodes.iter().enumerate() {
            if !matches!(n.kind, Kind::Container(_)) {
                continue;
            }
            found = true;
            let a = back.ast.attrs_of(i as NodeId);
            assert_eq!(a.get(b"id"), Some(&b"i"[..]));
            assert_eq!(a.get(b"class"), Some(&b"c"[..]));
        }
        assert!(found);
    }

    #[test]
    fn named_container_keeps_name_as_class() {
        let mut b = Builder::new();
        let s = b.add_leaf(Kind::Str(b"hi".to_vec()));
        let p = b.add_container(Kind::Para, &[s]);
        let div = b.add_container(Kind::Container(Container::with_form(b"note", Form::BlockFenced)), &[p]);
        let root = b.add_container(Kind::Doc, &[div]);
        let back = parse(&serialize_ast(&b.finish(root)));
        let mut found = false;
        for (i, n) in back.ast.nodes.iter().enumerate() {
            if !matches!(n.kind, Kind::Container(_)) {
                continue;
            }
            found = true;
            assert_eq!(back.ast.attrs_of(i as NodeId).get(b"class"), Some(&b"note"[..]));
        }
        assert!(found);
    }

    #[test]
    fn bare_inline_container_writes_no_brackets() {
        let mut b = Builder::new();
        let x = b.add_leaf(Kind::Str(b"x".to_vec()));
        let span = b.add_container(Kind::Container(Container::with_form(b"", Form::InlineText)), &[x]);
        let para = b.add_container(Kind::Para, &[span]);
        let root = b.add_container(Kind::Doc, &[para]);
        assert_eq!(serialize_ast(&b.finish(root)), b"x\n");
    }

    #[test]
    fn heading_attributes_go_above_and_generated_id_is_not_written() {
        let src = b"{.x #h}\n## t\n\n## t\n\n## t\n\n{.z}\n### sub\n\n> ## quoted\n";
        let doc = parse(src);
        let out = serialize(&doc);
        assert_eq!(String::from_utf8_lossy(&out), String::from_utf8_lossy(src));
        let back = parse(&out);
        let mut seen_sections = 0;
        let mut seen_z = false;
        for (i, n) in back.ast.nodes.iter().enumerate() {
            let attrs = back.ast.attrs_of(i as NodeId);
            match &n.kind {
                Kind::Section => {
                    seen_sections += 1;
                    if let Some(c) = attrs.get(b"class") {
                        assert_eq!(c, b"x");
                        assert_eq!(attrs.get(b"id"), Some(&b"h"[..]));
                    }
                }
                Kind::Heading { .. } => {
                    if let Some(c) = attrs.get(b"class") {
                        assert_eq!(c, b"z");
                        seen_z = true;
                    }
                }
                Kind::Str(_) => assert!(attrs.is_empty()),
                _ => {}
            }
        }
        assert_eq!(seen_sections, 4);
        assert!(seen_z);
    }

    #[test]
    fn reference_definition_attributes_go_above() {
        let doc = parse(b"[a][label]\n\n{.x #r}\n[label]: /dest\n");
        let out = serialize(&doc);
        assert_eq!(out, b"[a][label]\n\n{.x #r}\n[label]: /dest\n");
        let back = parse(&out);
        let id = *back.labels.references.get(&b"label"[..]).unwrap();
        assert!(matches!(back.ast.kind(id), Kind::Reference { destination, .. } if destination == b"/dest"));
        assert_eq!(back.ast.attrs_of(id).get(b"class"), Some(&b"x"[..]));
        assert_eq!(back.ast.attrs_of(id).get(b"id"), Some(&b"r"[..]));
    }
}
