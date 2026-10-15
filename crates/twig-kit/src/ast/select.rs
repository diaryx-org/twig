//! Selectors — a friendly, content-based way to address AST nodes, so callers
//! (and `twig query`/`twig edit`) don't have to speak in raw child indices. A
//! CSS-lite language: a *kind name* plus optional predicates. Port of
//! `src/ast/select.zig`.
//!
//! ── Grammar ──────────────────────────────────────────────────────────────
//!   selector  := step (combinator step)*
//!   combinator := ">"                          direct child
//!              |  (whitespace)                 descendant (any depth)
//!   step      := kind predicate*
//!   kind      := ident        e.g. heading, para, link, item, list, code,
//!                             emph, strong, table, cell, div, section, text;
//!                             friendly aliases (h/p/a/img/em/bold/quote…) and
//!                             any raw kind name also work; `*` = any
//!   predicate := "(" str ")"                  text contains (shorthand)
//!              | ":contains(" str ")"          text contains
//!              | ":nth(" N ")"  |  "[" N "]"   the N-th match (1-based)
//!              | "[" key (op value)? "]"       attribute/payload test
//!   op        := "=" "^=" "$=" "*=" "~="       eq / prefix / suffix /
//!                                              substring / whitespace-word
//!
//! Each step's `:nth`/`[k]` applies *within that step's scope* — it picks the
//! k-th candidate matched under the current scope, and that pick becomes the
//! scope for the next step.

use crate::ast::{Ast, Kind, NodeId};
use crate::document::Document;
use crate::span::Span;

/// A comparison a `[key op value]` predicate performs. `Present` is the bare
/// `[key]` form; `Word` is CSS's `~=`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Present,
    Eq,
    Prefix,
    Suffix,
    Substr,
    Word,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AttrPred {
    pub key: Vec<u8>,
    pub op: Op,
    pub value: Vec<u8>,
}

/// The parsed predicate set for one selector step (all ANDed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Matcher {
    /// Friendly kind name, a raw kind name, or `"*"` for any.
    pub kind_name: Vec<u8>,
    /// `:contains`/shorthand text — a node matches if its concatenated
    /// descendant text contains this (case-sensitive).
    pub contains: Option<Vec<u8>>,
    /// `:nth(k)`/`[k]` — keep only the k-th match (1-based) in document order.
    pub nth: Option<usize>,
    pub attrs: Vec<AttrPred>,
}

/// How a step relates to the scope established by the previous step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Combinator {
    Descendant,
    Child,
}

/// One link in a selector chain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub combinator: Combinator,
    pub matcher: Matcher,
}

/// A parsed selector: a chain of one or more `Step`s.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selector {
    pub steps: Vec<Step>,
}

/// A resolved node: its id plus the spans an editor would splice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match {
    pub id: NodeId,
    pub span: Span,
    pub content_span: Option<Span>,
}

/// `parse` failed: the text is not a selector.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidSelector;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResolveOneError {
    NoMatch,
    AmbiguousMatch,
}

// ── parsing ────────────────────────────────────────────────────────────────

struct Parser<'a> {
    text: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn skip_spaces(&mut self) {
        while self.i < self.text.len() && self.text[self.i] == b' ' {
            self.i += 1;
        }
    }

    fn ident(&mut self) -> &'a [u8] {
        let start = self.i;
        while self.i < self.text.len() {
            let c = self.text[self.i];
            if c.is_ascii_alphanumeric() || c == b'_' || c == b'-' || c == b'*' {
                self.i += 1;
                continue;
            }
            break;
        }
        &self.text[start..self.i]
    }

    /// Read a `"..."`/`'...'` quoted string (the inner bytes) or, unquoted,
    /// everything up to `stop`.
    fn value(&mut self, stop: u8) -> Result<&'a [u8], InvalidSelector> {
        if self.i < self.text.len() && (self.text[self.i] == b'"' || self.text[self.i] == b'\'') {
            let q = self.text[self.i];
            self.i += 1;
            let start = self.i;
            while self.i < self.text.len() && self.text[self.i] != q {
                self.i += 1;
            }
            if self.i >= self.text.len() {
                return Err(InvalidSelector);
            }
            let s = &self.text[start..self.i];
            self.i += 1;
            return Ok(s);
        }
        let start = self.i;
        while self.i < self.text.len() && self.text[self.i] != stop {
            self.i += 1;
        }
        Ok(&self.text[start..self.i])
    }

    fn expect(&mut self, c: u8) -> Result<(), InvalidSelector> {
        if self.i >= self.text.len() || self.text[self.i] != c {
            return Err(InvalidSelector);
        }
        self.i += 1;
        Ok(())
    }

    fn parse_matcher(&mut self) -> Result<Matcher, InvalidSelector> {
        let name = self.ident();
        if name.is_empty() {
            return Err(InvalidSelector);
        }
        let mut contains: Option<Vec<u8>> = None;
        let mut nth: Option<usize> = None;
        let mut attrs: Vec<AttrPred> = Vec::new();

        while self.i < self.text.len() {
            match self.text[self.i] {
                b'(' => {
                    self.i += 1;
                    contains = Some(self.value(b')')?.to_vec());
                    self.expect(b')')?;
                }
                b':' => {
                    self.i += 1;
                    let pseudo = self.ident();
                    self.expect(b'(')?;
                    if pseudo == b"contains" {
                        contains = Some(self.value(b')')?.to_vec());
                    } else if pseudo == b"nth" {
                        nth = Some(parse_usize(self.value(b')')?).ok_or(InvalidSelector)?);
                    } else {
                        return Err(InvalidSelector);
                    }
                    self.expect(b')')?;
                }
                b'[' => {
                    self.i += 1;
                    let inner_start = self.i;
                    while self.i < self.text.len() && self.text[self.i] != b']' {
                        self.i += 1;
                    }
                    let inner = &self.text[inner_start..self.i];
                    self.expect(b']')?;
                    if !inner.is_empty() && inner.iter().all(u8::is_ascii_digit) {
                        nth = Some(parse_usize(inner).ok_or(InvalidSelector)?);
                    } else {
                        attrs.push(parse_attr(inner)?);
                    }
                }
                _ => break,
            }
        }
        Ok(Matcher { kind_name: name.to_vec(), contains, nth, attrs })
    }
}

/// Zig's `std.fmt.parseInt(usize, s, 10)`: an optional sign (`-` only for a
/// zero), then digits with underscores allowed between them, no overflow.
fn parse_usize(s: &[u8]) -> Option<usize> {
    let (neg, body) = match s.first() {
        Some(b'+') => (false, &s[1..]),
        Some(b'-') => (true, &s[1..]),
        _ => (false, s),
    };
    if body.is_empty() || body[0] == b'_' || body[body.len() - 1] == b'_' {
        return None;
    }
    let mut n: usize = 0;
    for &c in body {
        if c == b'_' {
            continue;
        }
        if !c.is_ascii_digit() {
            return None;
        }
        n = n.checked_mul(10)?.checked_add((c - b'0') as usize)?;
        if neg && n != 0 {
            return None;
        }
    }
    Some(n)
}

fn trim_spaces(s: &[u8]) -> &[u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && s[a] == b' ' {
        a += 1;
    }
    while b > a && s[b - 1] == b' ' {
        b -= 1;
    }
    &s[a..b]
}

/// Parse the inside of a `[...]` attribute predicate. Quotes around the value
/// are stripped.
fn parse_attr(inner: &[u8]) -> Result<AttrPred, InvalidSelector> {
    let mut op = Op::Present;
    let mut op_at: Option<usize> = None;
    let mut op_len = 0;
    for i in 0..inner.len() {
        if inner[i] == b'=' {
            if i > 0 && matches!(inner[i - 1], b'^' | b'$' | b'*' | b'~') {
                op = match inner[i - 1] {
                    b'^' => Op::Prefix,
                    b'$' => Op::Suffix,
                    b'~' => Op::Word,
                    _ => Op::Substr,
                };
                op_at = Some(i - 1);
                op_len = 2;
            } else {
                op = Op::Eq;
                op_at = Some(i);
                op_len = 1;
            }
            break;
        }
    }

    let Some(at) = op_at else {
        let key = trim_spaces(inner);
        if key.is_empty() {
            return Err(InvalidSelector);
        }
        return Ok(AttrPred { key: key.to_vec(), op: Op::Present, value: Vec::new() });
    };

    let key = trim_spaces(&inner[..at]);
    let mut val = trim_spaces(&inner[at + op_len..]);
    if val.len() >= 2 && (val[0] == b'"' || val[0] == b'\'') && val[val.len() - 1] == val[0] {
        val = &val[1..val.len() - 1];
    }
    if key.is_empty() {
        return Err(InvalidSelector);
    }
    Ok(AttrPred { key: key.to_vec(), op, value: val.to_vec() })
}

/// Parse `text` into a `Selector`: whitespace-separated steps, a `>` between
/// steps (optionally space-padded) meaning `Child`.
pub fn parse(text: &[u8]) -> Result<Selector, InvalidSelector> {
    let mut p = Parser { text, i: 0 };
    let mut steps = Vec::new();

    p.skip_spaces();
    let first = p.parse_matcher()?;
    steps.push(Step { combinator: Combinator::Descendant, matcher: first });
    p.skip_spaces();

    while p.i < text.len() {
        let mut comb = Combinator::Descendant;
        if text[p.i] == b'>' {
            comb = Combinator::Child;
            p.i += 1;
            p.skip_spaces();
        }
        if p.i >= text.len() {
            return Err(InvalidSelector);
        }
        let m = p.parse_matcher()?;
        steps.push(Step { combinator: comb, matcher: m });
        p.skip_spaces();
    }
    Ok(Selector { steps })
}

// ── resolving ──────────────────────────────────────────────────────────────

/// Every node (in document order) the selector's step chain matches.
pub fn resolve_all(doc: &Document, selector: &Selector) -> Vec<Match> {
    let ast = &doc.ast;
    let mut current = vec![false; ast.nodes.len()];
    current[ast.root as usize] = true;

    let mut ordered: Vec<NodeId> = Vec::new();
    for step in &selector.steps {
        ordered.clear();
        collect_step(ast, ast.root, false, &current, step, &mut ordered);

        if let Some(k) = step.matcher.nth {
            if k >= 1 && k <= ordered.len() {
                let picked = ordered[k - 1];
                ordered.clear();
                ordered.push(picked);
            } else {
                ordered.clear();
            }
        }

        current.iter_mut().for_each(|c| *c = false);
        for &id in &ordered {
            current[id as usize] = true;
        }
    }

    ordered.iter().map(|&id| Match { id, span: doc.span(id), content_span: doc.content_span(id) }).collect()
}

/// Pre-order DFS over `id`'s subtree collecting candidates of `step`. Only
/// children are ever tested, so the root is a scope but never a candidate.
fn collect_step(ast: &Ast, id: NodeId, ancestor_in_current: bool, current: &[bool], step: &Step, out: &mut Vec<NodeId>) {
    let parent_in_current = current[id as usize];
    let child_ancestor_in_current = ancestor_in_current || parent_in_current;
    let mut c = ast.nodes[id as usize].first_child;
    while let Some(cid) = c {
        let scoped = match step.combinator {
            Combinator::Child => parent_in_current,
            Combinator::Descendant => child_ancestor_in_current,
        };
        if scoped && matches(ast, cid, &step.matcher) {
            out.push(cid);
        }
        collect_step(ast, cid, child_ancestor_in_current, current, step, out);
        c = ast.nodes[cid as usize].next_sibling;
    }
}

fn matches(ast: &Ast, id: NodeId, m: &Matcher) -> bool {
    if !kind_name_matches(&m.kind_name, &ast.nodes[id as usize].kind) {
        return false;
    }
    if !m.attrs.iter().all(|pred| attr_matches(ast, id, pred)) {
        return false;
    }
    if let Some(needle) = &m.contains {
        let text = text_of(ast, id);
        if find(&text, needle).is_none() {
            return false;
        }
    }
    true
}

/// The single node the selector matches, or `NoMatch`/`AmbiguousMatch`.
pub fn resolve_one(doc: &Document, selector: &Selector) -> Result<NodeId, ResolveOneError> {
    let all = resolve_all(doc, selector);
    match all.len() {
        0 => Err(ResolveOneError::NoMatch),
        1 => Ok(all[0].id),
        _ => Err(ResolveOneError::AmbiguousMatch),
    }
}

// ── kind names, attributes, text ───────────────────────────────────────────

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn eq_any(name: &[u8], options: &[&str]) -> bool {
    options.iter().any(|o| o.as_bytes() == name)
}

/// Takes a whole `Kind`, not just its tag: `div`/`span` are tag-plus-name
/// tests on a `container`.
fn kind_name_matches(name: &[u8], kind: &Kind) -> bool {
    use crate::ast::{InlineMark, Tag};
    let tag = kind.tag();
    if name == b"*" || name == b"any" {
        return true;
    }
    if eq_any(name, &["heading", "h"]) {
        return tag == Tag::Heading;
    }
    if eq_any(name, &["para", "paragraph", "p"]) {
        return tag == Tag::Para;
    }
    if eq_any(name, &["link", "a"]) {
        return tag == Tag::Link;
    }
    if eq_any(name, &["image", "img"]) {
        return tag == Tag::Image;
    }
    if eq_any(name, &["list"]) {
        return matches!(tag, Tag::BulletList | Tag::OrderedList | Tag::TaskList | Tag::DefinitionList);
    }
    if eq_any(name, &["item"]) {
        return matches!(tag, Tag::ListItem | Tag::TaskListItem | Tag::DefinitionListItem);
    }
    if eq_any(name, &["code"]) {
        return tag == Tag::CodeBlock;
    }
    if eq_any(name, &["metadata", "meta", "frontmatter"]) {
        return tag == Tag::Metadata;
    }
    if eq_any(name, &["emph", "em", "emphasis", "italic"]) {
        return kind.is_inline_mark(InlineMark::Emph);
    }
    if eq_any(name, &["strong", "bold", "b"]) {
        return kind.is_inline_mark(InlineMark::Strong);
    }
    if eq_any(name, &["quote", "blockquote"]) {
        return tag == Tag::BlockQuote;
    }
    if eq_any(name, &["table"]) {
        return tag == Tag::Table;
    }
    if eq_any(name, &["cell"]) {
        return tag == Tag::Cell;
    }
    if eq_any(name, &["row"]) {
        return tag == Tag::Row;
    }
    if eq_any(name, &["section"]) {
        return tag == Tag::Section;
    }
    if eq_any(name, &["text", "str"]) {
        return tag == Tag::Str;
    }
    if eq_any(name, &["div", "span"]) {
        return matches!(kind, Kind::Container(c) if c.name == name);
    }
    if eq_any(name, &["container", "element", "directive"]) {
        return tag == Tag::Container;
    }
    name == kind.kind_name().as_bytes()
}

fn op_match(op: Op, actual: &[u8], want: &[u8]) -> bool {
    match op {
        Op::Present => true,
        Op::Eq => actual == want,
        Op::Prefix => actual.starts_with(want),
        Op::Suffix => actual.ends_with(want),
        Op::Substr => find(actual, want).is_some(),
        Op::Word => {
            if want.is_empty() {
                return false;
            }
            actual.split(|c| b" \t\r\n".contains(c)).filter(|t| !t.is_empty()).any(|t| t == want)
        }
    }
}

fn attr_matches(ast: &Ast, id: NodeId, pred: &AttrPred) -> bool {
    let kind = &ast.nodes[id as usize].kind;
    if pred.key == b"level" {
        let Kind::Heading { level } = kind else { return false };
        if pred.op == Op::Present {
            return true;
        }
        return op_match(pred.op, level.to_string().as_bytes(), &pred.value);
    }
    if eq_any(&pred.key, &["dest", "href", "src", "destination"]) {
        let d = match kind {
            Kind::Link(l) | Kind::Image(l) => l.destination.as_deref(),
            _ => None,
        };
        return d.is_some_and(|dd| op_match(pred.op, dd, &pred.value));
    }
    if pred.key == b"lang" {
        let l = match kind {
            Kind::CodeBlock { lang, .. } => lang.as_deref(),
            Kind::Metadata { lang, .. } => Some(&lang[..]),
            _ => None,
        };
        return l.is_some_and(|ll| op_match(pred.op, ll, &pred.value));
    }
    if pred.key == b"name" {
        if let Kind::Container(c) = kind {
            return pred.op == Op::Present || op_match(pred.op, &c.name, &pred.value);
        }
        return false;
    }
    if pred.key == b"ordered" {
        return matches!(kind, Kind::OrderedList { .. });
    }
    if pred.key == b"checked" {
        return matches!(kind, Kind::TaskListItem { checked: true });
    }
    if pred.op == Op::Present {
        return ast.attrs_of(id).find(&pred.key).is_some();
    }
    ast.attrs_of(id).get(&pred.key).is_some_and(|v| op_match(pred.op, v, &pred.value))
}

/// A node's text content: every descendant text payload concatenated (what
/// `:contains` tests against, and how a `query` preview is built).
pub fn text_of(ast: &Ast, id: NodeId) -> Vec<u8> {
    let mut buf = Vec::new();
    text_into(ast, id, &mut buf);
    buf
}

fn text_into(ast: &Ast, id: NodeId, buf: &mut Vec<u8>) {
    match &ast.nodes[id as usize].kind {
        Kind::Str(s) => buf.extend_from_slice(s),
        Kind::TextLeaf { text, .. } => buf.extend_from_slice(text),
        Kind::SmartPunctuation(v) => buf.extend_from_slice(v.ascii().as_bytes()),
        Kind::RawInline { text, .. } => buf.extend_from_slice(text),
        Kind::CodeBlock { text, .. } => buf.extend_from_slice(text),
        Kind::RawBlock { text, .. } => buf.extend_from_slice(text),
        Kind::NonBreakingSpace | Kind::SoftBreak | Kind::HardBreak => buf.push(b' '),
        _ => {
            let mut c = ast.nodes[id as usize].first_child;
            while let Some(cid) = c {
                text_into(ast, cid, buf);
                c = ast.nodes[cid as usize].next_sibling;
            }
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;


    fn sel(s: &str) -> Selector {
        parse(s.as_bytes()).unwrap()
    }

    #[test]
    fn parse_kind_contains_nth_and_attribute_predicates() {
        let s1 = sel("heading");
        assert_eq!(s1.steps.len(), 1);
        assert_eq!(s1.steps[0].combinator, Combinator::Descendant);
        assert_eq!(s1.steps[0].matcher.kind_name, b"heading");

        let s2 = sel("heading[level=2]");
        assert_eq!(s2.steps[0].matcher.attrs.len(), 1);
        assert_eq!(s2.steps[0].matcher.attrs[0].key, b"level");
        assert_eq!(s2.steps[0].matcher.attrs[0].op, Op::Eq);
        assert_eq!(s2.steps[0].matcher.attrs[0].value, b"2");

        assert_eq!(sel("item[2]").steps[0].matcher.nth, Some(2));

        let s4 = sel("link[dest^=\"http\"]");
        assert_eq!(s4.steps[0].matcher.attrs[0].op, Op::Prefix);
        assert_eq!(s4.steps[0].matcher.attrs[0].value, b"http");

        assert_eq!(sel("heading(\"Status\")").steps[0].matcher.contains.as_deref(), Some(&b"Status"[..]));

        assert_eq!(parse(b""), Err(InvalidSelector));
    }

    #[test]
    fn parse_multi_step_chains_distinguish_descendant_and_child() {
        let s1 = sel("list > item");
        assert_eq!(s1.steps.len(), 2);
        assert_eq!(s1.steps[0].combinator, Combinator::Descendant);
        assert_eq!(s1.steps[1].combinator, Combinator::Child);
        assert_eq!(s1.steps[0].matcher.kind_name, b"list");
        assert_eq!(s1.steps[1].matcher.kind_name, b"item");

        let s2 = sel("blockquote para");
        assert_eq!(s2.steps.len(), 2);
        assert_eq!(s2.steps[1].combinator, Combinator::Descendant);

        let s3 = sel("list>item");
        assert_eq!(s3.steps.len(), 2);
        assert_eq!(s3.steps[1].combinator, Combinator::Child);

        let s4 = sel("list:nth(2) > item(\"dishes\")");
        assert_eq!(s4.steps[0].matcher.nth, Some(2));
        assert_eq!(s4.steps[1].matcher.contains.as_deref(), Some(&b"dishes"[..]));
    }

    #[test]
    fn parse_dangling_gt_and_trailing_junk_are_rejected() {
        assert_eq!(parse(b"list >"), Err(InvalidSelector));
        assert_eq!(parse(b"list > "), Err(InvalidSelector));
        assert_eq!(parse(b"list !bad"), Err(InvalidSelector));
    }









}
