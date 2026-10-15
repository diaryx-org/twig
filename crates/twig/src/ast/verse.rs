//! Verse — read a div classed `verse` as the `line_block` it spells. Port of
//! `src/ast/verse.zig`.
//!
//! Markdown's `<div class="verse">` (under `html_elements`) and djot's
//! `::: verse` are rewritten, in place, into the `line_block` AsciiDoc's
//! `[verse]` and rST's `| ` already parse to.
//!
//! ── The reading ────────────────────────────────────────────────────────────
//!   * Each paragraph is a STANZA. Every break inside it — hard or soft —
//!     ends a `line`.
//!   * Between two paragraphs an EMPTY `line` is the stanza break.
//!   * A line's leading EM SPACES (U+2003, raw or as `&emsp;`, `&#8195;`,
//!     `&#x2003;`) are its `indent`, one step each, taken out of its text.
//!   * `verse` leaves the div's class; any other class and attribute stays.
//!
//! A div that holds anything but paragraphs is left a div.
//!
//! ── Mechanics ──────────────────────────────────────────────────────────────
//! Runs on a raw parse, BEFORE `compact`. The div's node is rewritten to
//! `line_block` (keeping its id, span and interior), the `line` nodes are
//! appended to the arena, and a line's first `str` is replaced by a trimmed
//! copy when its indent is taken off. Abandoned paragraphs and breaks are left
//! unattached for compaction to sweep.

use crate::ast::{Attrs, Form, Kind, KeyVal, Node, NodeId};
use crate::document::Document;
use crate::span::Span;

/// The class token that makes a div a verse.
pub const CLASS_TOKEN: &[u8] = b"verse";

/// U+2003 EM SPACE — one step of a verse line's indent.
pub const EM_SPACE: &[u8] = "\u{2003}".as_bytes();

/// Every source spelling of one em space, longest first.
const EM_SPACE_SPELLINGS: [&[u8]; 5] = [b"&#x2003;", b"&#X2003;", b"&#8195;", b"&emsp;", EM_SPACE];

/// Rewrite every verse div in `doc` into a `line_block`.
pub fn run(doc: Document) -> Document {
    let original_len = doc.ast.nodes.len();
    let Some(start) = (0..original_len).find(|&i| is_verse_div(&doc, i as NodeId)) else {
        return doc;
    };
    let mut w = Rewriter { doc, lines: Vec::new(), kids: Vec::new() };
    for i in start..original_len {
        let id = i as NodeId;
        if !is_verse_div(&w.doc, id) {
            continue;
        }
        w.rewrite(id);
    }
    w.doc
}

/// Whether `id` is a fenced div, classed `verse`, whose children are one or
/// more paragraphs and nothing else.
fn is_verse_div(doc: &Document, id: NodeId) -> bool {
    let node = &doc.ast.nodes[id as usize];
    let Kind::Container(c) = &node.kind else { return false };
    if c.form != Some(Form::BlockFenced) {
        return false;
    }
    if !c.name.is_empty() && c.name != b"div" {
        return false;
    }
    if c.text.is_some() {
        return false;
    }
    let Some(class) = doc.ast.attrs_of(id).get(b"class") else { return false };
    if !has_token(class, CLASS_TOKEN) {
        return false;
    }
    let Some(mut child) = node.first_child else { return false };
    loop {
        if doc.ast.nodes[child as usize].kind != Kind::Para {
            return false;
        }
        match doc.ast.nodes[child as usize].next_sibling {
            Some(n) => child = n,
            None => return true,
        }
    }
}

fn is_tok_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\r' | b'\n' | 0x0C)
}

fn tokens(list: &[u8]) -> impl Iterator<Item = &[u8]> {
    list.split(|&c| is_tok_ws(c)).filter(|t| !t.is_empty())
}

fn has_token(list: &[u8], token: &[u8]) -> bool {
    tokens(list).any(|t| t == token)
}

struct Rewriter {
    doc: Document,
    lines: Vec<NodeId>,
    kids: Vec<NodeId>,
}

impl Rewriter {
    fn add_node(&mut self, kind: Kind, span: Span) -> NodeId {
        let id = self.doc.ast.nodes.len() as NodeId;
        self.doc.ast.nodes.push(Node { id, kind, first_child: None, next_sibling: None, attrs: None });
        self.doc.node_spans.push(span);
        self.doc.node_content_spans.push(None);
        id
    }

    fn set_children(&mut self, parent: NodeId, ids: &[NodeId]) {
        let nodes = &mut self.doc.ast.nodes;
        nodes[parent as usize].first_child = ids.first().copied();
        if ids.is_empty() {
            return;
        }
        for w in ids.windows(2) {
            nodes[w[0] as usize].next_sibling = Some(w[1]);
        }
        nodes[*ids.last().unwrap() as usize].next_sibling = None;
    }

    fn rewrite(&mut self, div: NodeId) {
        self.lines.clear();
        let mut prev_para: Option<NodeId> = None;
        let mut para_it = self.doc.ast.nodes[div as usize].first_child;
        while let Some(para) = para_it {
            if let Some(p) = prev_para {
                // The stanza break, placed on the blank line between the two
                // paragraphs: just past the newline that ends the first's
                // last line.
                let end = match self.lines.last() {
                    Some(&l) => self.doc.node_spans[l as usize].end,
                    None => self.doc.node_spans[p as usize].end,
                };
                let next_start = self.doc.node_spans[para as usize].start;
                let src = &self.doc.source;
                let nl = if end <= src.len() {
                    src[end..].iter().position(|&c| c == b'\n').map(|i| i + end).unwrap_or(end)
                } else {
                    end
                };
                let at = (nl + 1).max(end).min(next_start.max(end));
                let id = self.add_node(Kind::Line { indent: 0 }, Span::new(at, at));
                self.lines.push(id);
            }
            prev_para = Some(para);

            self.kids.clear();
            let mut child = self.doc.ast.nodes[para as usize].first_child;
            while let Some(c) = child {
                match self.doc.ast.nodes[c as usize].kind {
                    Kind::SoftBreak | Kind::HardBreak => self.close_line(),
                    _ => self.kids.push(c),
                }
                child = self.doc.ast.nodes[c as usize].next_sibling;
            }
            self.close_line();
            para_it = self.doc.ast.nodes[para as usize].next_sibling;
        }

        // The div becomes the block: same id, span and interior.
        self.doc.ast.nodes[div as usize].kind = Kind::LineBlock;
        let lines = std::mem::take(&mut self.lines);
        self.set_children(div, &lines);
        self.lines = lines;
        if (div as usize) < self.doc.node_spelling.len() {
            self.doc.node_spelling[div as usize] = None;
        }
        self.drop_class_token(div);
    }

    /// End the line `kids` holds, taking its indent off its first text.
    fn close_line(&mut self) {
        if self.kids.is_empty() {
            return;
        }
        let line_start = self.doc.node_spans[self.kids[0] as usize].start;
        let line_end = self.doc.node_spans[*self.kids.last().unwrap() as usize].end;

        // The indent is counted in the DECODED text and located in the
        // source: `&emsp;` is one step and six bytes.
        let mut indent: u32 = 0;
        let mut src_pos = line_start;
        while !self.kids.is_empty() {
            let first = self.kids[0];
            let Kind::Str(text) = &self.doc.ast.nodes[first as usize].kind else { break };
            let mut n = 0usize;
            while text[n * EM_SPACE.len()..].starts_with(EM_SPACE) {
                n += 1;
            }
            if n == 0 {
                break;
            }
            let mut advanced = 0usize;
            let mut pos = src_pos;
            while advanced < n {
                let Some(step) = spelling_at(&self.doc.source, pos) else { break };
                pos += step;
                advanced += 1;
            }
            if advanced != n {
                break; // the source disagrees; leave it alone
            }
            indent += n as u32;
            src_pos = pos;
            let rest = text[n * EM_SPACE.len()..].to_vec();
            if rest.is_empty() {
                self.kids.remove(0);
                continue;
            }
            let first_end = self.doc.node_spans[first as usize].end;
            let trimmed = self.add_node(Kind::Str(rest), Span::new(src_pos, first_end));
            self.kids[0] = trimmed;
            break;
        }

        let id = self.add_node(Kind::Line { indent }, Span::new(line_start, line_start.max(line_end)));
        let kids = std::mem::take(&mut self.kids);
        self.set_children(id, &kids);
        self.kids = kids;
        self.kids.clear();
        self.lines.push(id);
    }

    /// Take `verse` out of `div`'s class, dropping the class (and the whole
    /// attribute set) when nothing else is left.
    fn drop_class_token(&mut self, div: NodeId) {
        let Some(aid) = self.doc.ast.nodes[div as usize].attrs else { return };
        let attrs = &self.doc.ast.attrs[aid as usize];
        let mut entries: Vec<KeyVal> = Vec::new();
        for kv in &attrs.entries {
            let Some(value) = (if kv.key == b"class" { kv.value.as_ref() } else { None }) else {
                entries.push(kv.clone());
                continue;
            };
            let mut rest: Vec<u8> = Vec::new();
            for t in tokens(value) {
                if t == CLASS_TOKEN {
                    continue;
                }
                if !rest.is_empty() {
                    rest.push(b' ');
                }
                rest.extend_from_slice(t);
            }
            if rest.is_empty() {
                continue;
            }
            entries.push(KeyVal { key: kv.key.clone(), value: Some(rest) });
        }
        let empty = entries.is_empty();
        self.doc.ast.attrs[aid as usize] = Attrs { entries };
        if empty {
            self.doc.ast.nodes[div as usize].attrs = None;
        }
    }
}

/// The byte length of the em-space spelling `src` holds at `pos`, or `None`.
fn spelling_at(src: &[u8], pos: usize) -> Option<usize> {
    if pos >= src.len() {
        return None;
    }
    EM_SPACE_SPELLINGS.iter().find(|s| src[pos..].starts_with(s)).map(|s| s.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Builder, Container};
    use crate::languages::markdown::{self, ParseOptions};

    /// Each line's source text, from its first child to its last.
    fn line_texts<'d>(doc: &'d Document, block: NodeId) -> Vec<&'d [u8]> {
        doc.ast
            .children(block)
            .map(|line| {
                let kids = doc.ast.child_ids(line.id);
                match (kids.first(), kids.last()) {
                    (Some(&f), Some(&l)) => &doc.source[doc.span(f).start..doc.span(l).end],
                    _ => &b""[..],
                }
            })
            .collect()
    }

    fn html_elements() -> ParseOptions {
        ParseOptions { html_elements: true, ..ParseOptions::default() }
    }

    /// TODO(port): the Markdown block parser is still a stub in places; these
    /// tests run once it parses a paragraph.
    fn markdown_ready() -> bool {
        let doc = markdown::parse(b"a\n", ParseOptions::default());
        let ready = doc.ast.node(doc.ast.root).first_child.is_some();
        if !ready {
            eprintln!("markdown parser not ported yet; skipping");
        }
        ready
    }

    #[test]
    fn markdown_every_line_break_is_a_line_and_a_blank_line_a_stanza() {
        if !markdown_ready() {
            return;
        }
        let src = b"<div class=\"verse\">\n\nOne line\nsoft-broken\\\nhard-broken\n\nstanza two\n\n</div>\n";
        let doc = markdown::parse(src, html_elements());
        let block = doc.ast.node(doc.ast.root).first_child.unwrap();
        assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
        assert!(doc.ast.attrs_of(block).is_empty());
        let texts = line_texts(&doc, block);
        let want: [&[u8]; 5] = [b"One line", b"soft-broken", b"hard-broken", b"", b"stanza two"];
        assert_eq!(texts, want);
        let gap = doc.ast.child_ids(block)[3];
        let at = src.windows(8).position(|w| w == b"\n\nstanza").unwrap() + 1;
        assert_eq!(doc.span(gap).start, at);
    }

    #[test]
    fn markdown_em_spaces_are_the_indent_raw_or_as_an_entity() {
        if !markdown_ready() {
            return;
        }
        let src = "<div class=\"verse center\">\n\nzero\n\u{2003}one\n&emsp;&#8195;two\n\n</div>\n";
        let s = src.as_bytes();
        let doc = markdown::parse(s, html_elements());
        let block = doc.ast.node(doc.ast.root).first_child.unwrap();
        assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
        assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"center"[..]));
        let lines = doc.ast.child_ids(block);
        assert_eq!(lines.len(), 3);
        let want_text: [&[u8]; 3] = [b"zero", b"one", b"two"];
        let want_start: [&[u8]; 3] = [b"zero", "\u{2003}".as_bytes(), b"&emsp;"];
        for (i, &line) in lines.iter().enumerate() {
            assert_eq!(doc.ast.kind(line), &Kind::Line { indent: i as u32 });
            let str_id = doc.ast.node(line).first_child.unwrap();
            assert_eq!(doc.ast.kind(str_id), &Kind::Str(want_text[i].to_vec()));
            assert_eq!(doc.span(str_id).of(s), want_text[i]);
            assert!(s[doc.span(line).start..].starts_with(want_start[i]));
        }
    }

    #[test]
    fn markdown_a_div_holding_more_than_paragraphs_or_without_html_elements_is_not_a_verse() {
        if !markdown_ready() {
            return;
        }
        let mixed = b"<div class=\"verse\">\n\n# A heading\n\nA line\n\n</div>\n";
        let doc = markdown::parse(mixed, html_elements());
        let block = doc.ast.node(doc.ast.root).first_child.unwrap();
        assert!(matches!(doc.ast.kind(block), Kind::Container(_)));
        assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"verse"[..]));

        let plain = b"<div class=\"verse\">\n\nA line\n\n</div>\n";
        let raw = markdown::parse(plain, ParseOptions::COMMONMARK);
        assert!(raw.ast.nodes.iter().all(|n| n.kind != Kind::LineBlock));
    }

    #[test]
    fn djot_a_verse_div_is_a_line_block_its_other_classes_kept() {
        let src = "{.center}\n::: verse\nOne\\\n\u{2003}two\n\nthree\n:::\n";
        let doc = crate::languages::djot::parse(src.as_bytes());
        let block = doc.ast.node(doc.ast.root).first_child.unwrap();
        assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
        assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"center"[..]));
        let want: [&[u8]; 4] = [b"One", b"two", b"", b"three"];
        assert_eq!(line_texts(&doc, block), want);
    }

    #[test]
    fn the_rewrite_leaves_nothing_behind_for_compaction_to_miss() {
        if !markdown_ready() {
            return;
        }
        let doc = markdown::parse(b"<div class=\"verse\">\n\na\nb\n\nc\n\n</div>\n", html_elements());
        let mut seen = vec![false; doc.ast.nodes.len()];
        let mut stack = vec![doc.ast.root];
        while let Some(id) = stack.pop() {
            seen[id as usize] = true;
            stack.extend(doc.ast.child_ids(id));
        }
        assert!(seen.iter().all(|&s| s));
        assert!(doc.ast.nodes.iter().all(|n| n.kind != Kind::Para && n.kind != Kind::SoftBreak));
    }

    /// `<div class="verse center">` with "a\n\u{2003}b" and "&emsp;c",
    /// hand-built with source positions.
    #[test]
    fn rewrites_a_hand_built_verse_div() {
        let src = "a\n\u{2003}b\n\n&emsp;c\n";
        let s = src.as_bytes();
        let mut b = Builder::new();
        let a = b.add_leaf(Kind::Str(b"a".to_vec()));
        b.set_span(a, Span::new(0, 1));
        let sb = b.add_leaf(Kind::SoftBreak);
        b.set_span(sb, Span::new(1, 2));
        let bb = b.add_leaf(Kind::Str("\u{2003}b".as_bytes().to_vec()));
        b.set_span(bb, Span::new(2, 6));
        let p1 = b.add_container(Kind::Para, &[a, sb, bb]);
        b.set_span(p1, Span::new(0, 7));
        let c = b.add_leaf(Kind::Str("\u{2003}c".as_bytes().to_vec()));
        b.set_span(c, Span::new(8, 15));
        let p2 = b.add_container(Kind::Para, &[c]);
        b.set_span(p2, Span::new(8, 16));
        let div = b.add_container(Kind::Container(Container::with_form(b"div", Form::BlockFenced)), &[p1, p2]);
        b.set_attrs(div, Attrs { entries: vec![KeyVal::new(b"class", Some(b"verse center"))] });
        b.set_span(div, Span::new(0, 16));
        let root = b.add_container(Kind::Doc, &[div]);
        let doc = crate::ast::compact::run(run(b.finish_document(s, root)));

        let block = doc.ast.node(doc.ast.root).first_child.unwrap();
        assert_eq!(doc.ast.kind(block), &Kind::LineBlock);
        assert_eq!(doc.ast.attrs_of(block).get(b"class"), Some(&b"center"[..]));
        let lines = doc.ast.child_ids(block);
        assert_eq!(lines.len(), 4);
        let want = [(0u32, Some("a")), (1, Some("b")), (0, None), (1, Some("c"))];
        for (line, (ind, text)) in lines.iter().zip(want) {
            assert_eq!(doc.ast.kind(*line), &Kind::Line { indent: ind });
            match text {
                Some(t) => {
                    let str_id = doc.ast.node(*line).first_child.unwrap();
                    assert_eq!(doc.ast.kind(str_id), &Kind::Str(t.as_bytes().to_vec()));
                    assert_eq!(doc.text(str_id), t.as_bytes());
                }
                None => assert!(doc.ast.node(*line).first_child.is_none()),
            }
        }
        // The stanza break sits on the blank line.
        assert_eq!(doc.span(lines[2]).start, 7);
        // Nothing left behind once compacted.
        assert!(doc.ast.nodes.iter().all(|n| n.kind != Kind::Para && n.kind != Kind::SoftBreak));
    }

    #[test]
    fn a_div_holding_more_than_paragraphs_is_not_a_verse() {
        let mut b = Builder::new();
        let t = b.add_leaf(Kind::Str(b"x".to_vec()));
        let h = b.add_container(Kind::Heading { level: 1 }, &[t]);
        let div = b.add_container(Kind::Container(Container::with_form(b"div", Form::BlockFenced)), &[h]);
        b.set_attrs(div, Attrs { entries: vec![KeyVal::new(b"class", Some(b"verse"))] });
        let root = b.add_container(Kind::Doc, &[div]);
        let doc = run(b.finish_document(b"", root));
        assert!(matches!(doc.ast.kind(div), Kind::Container(_)));
    }

    #[test]
    fn class_verse_alone_drops_the_attribute_set() {
        let mut b = Builder::new();
        let t = b.add_leaf(Kind::Str(b"x".to_vec()));
        b.set_span(t, Span::new(0, 1));
        let p = b.add_container(Kind::Para, &[t]);
        let div = b.add_container(Kind::Container(Container::with_form(b"", Form::BlockFenced)), &[p]);
        b.set_attrs(div, Attrs { entries: vec![KeyVal::new(b"class", Some(b"verse"))] });
        let root = b.add_container(Kind::Doc, &[div]);
        let doc = run(b.finish_document(b"x", root));
        assert_eq!(doc.ast.kind(div), &Kind::LineBlock);
        assert!(doc.ast.attrs_of(div).is_empty());
    }
}
