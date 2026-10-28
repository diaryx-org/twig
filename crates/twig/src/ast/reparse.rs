//! The reparse after an edit, of only the blocks it touched: what lets a
//! keystroke in a large document cost the size of its block rather than the
//! size of the document.
//!
//! ── The cut ────────────────────────────────────────────────────────────────
//! A document's BLOCKS here are the children of its root, with every
//! `section` opened into its own children (djot's sections are made from its
//! headings, not written). The edit touches a run of them, `E`, which may be
//! empty. `L` is the last block that ends before the edit starts and `R` the
//! first that starts after it ends: both are untouched. The FRAGMENT is the
//! new source from `L`'s start to the start of the block after `R`, and the
//! language parses it as the blocks it is inside the document
//! ([`twig_kit::Language::parse_fragment`]), with what it names resolved
//! against the document's own definitions.
//!
//! ── Why the fragment is the document's parse ───────────────────────────────
//! Everything before `L` is unchanged, and a block starts at `L` in the old
//! parse, so the whole new parse starts a block at `L` as the fragment's
//! parse does. From there both read the same bytes. If the fragment's parse
//! gives back `L` and `R` exactly as they were — kinds, spans, attributes,
//! every node beneath — then the edit's effect closed before `R`: a fence it
//! opened, a list it continued, a setext underline or lazy line it made would
//! have changed one of them. And `R` began a block in the old parse with the
//! same bytes after it, so the rest of the document parses as before,
//! shifted. What is between the two in the fragment is what the edit made.
//!
//! ── What parses the whole document instead ─────────────────────────────────
//! Anything a cut cannot vouch for: a language without a fragment parser, or
//! one that declines; `L` or `R` coming back different; a reference or
//! footnote definition, or anything a label table points at, in the edited
//! run (definitions are document-wide); a node with attributes there (the
//! attribute table is numbered in the parser's own order); a section's
//! heading there (it moves every section's extent); a section whose extent
//! cannot be read off its children; a document whose attribute table holds an
//! entry no node owns ([`attrs_dense`]). And whatever the language refuses:
//! Markdown a fragment that defines a link reference, or that a frontmatter
//! or endmatter reaches across; djot one that names an identifier, which
//! every later heading's is made unique against. Each refusal comes
//! before anything changes.
//!
//! ── The splice ─────────────────────────────────────────────────────────────
//! Both parses are compacted (`ast::compact`): the arena is the tree in
//! pre-order, then what only a label table reaches. So `E`'s nodes are one
//! run of ids, and the fragment's new blocks another: the run is replaced,
//! the ids after it move by the difference in count, and the spans after the
//! edit move by its difference in length. A keystroke that adds no node moves
//! no node.

use std::ops::Range;

use crate::ast::{Kind, NodeId};
use crate::document::Document;
use crate::span::Span;

/// Parses a fragment of a document's edited source as the blocks it is
/// inside that document: the format's [`twig_kit::Language::parse_fragment`],
/// under the editor's parse configuration. `None` when it cannot.
pub type FragmentFn = Box<dyn Fn(&[u8], Range<usize>, &Document) -> Option<Document>>;

/// [`FragmentFn`], borrowed.
pub type Fragment = dyn Fn(&[u8], Range<usize>, &Document) -> Option<Document>;

/// What an edit did to the source: the old `start..old_end` is now
/// `start..new_end`, and the bytes either side are the same.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Edit {
    pub start: usize,
    pub old_end: usize,
    pub new_end: usize,
}

/// Bring `doc` up to date with `new_src` by reparsing only the blocks `edit`
/// touched. `false`, with `doc` untouched, when that cannot be shown to give
/// what a parse of the whole of `new_src` would; the caller parses it all.
///
/// `dense` caches [`attrs_dense`] of `doc`: `None` has it worked out (once,
/// over the whole tree), and a reparse in place keeps it true. A caller that
/// replaces `doc` resets it to `None`.
pub fn reparse(doc: &mut Document, new_src: &[u8], edit: Edit, fragment: &Fragment, dense: &mut Option<bool>) -> bool {
    if !*dense.get_or_insert_with(|| attrs_dense(doc)) {
        return false;
    }
    match plan(doc, new_src, edit, fragment) {
        Some(p) => {
            apply(doc, new_src, p);
            true
        }
        None => false,
    }
}

/// Whether every entry of `doc`'s attribute table belongs to a node. A
/// parser that drops a node it made (a second definition of a label) leaves
/// that node's attributes behind, numbered among the rest; where such an
/// entry was made cannot be told from the tree, so an edit to a document
/// that has one parses it whole.
pub fn attrs_dense(doc: &Document) -> bool {
    let mut used = vec![false; doc.ast.attrs.len()];
    for n in &doc.ast.nodes {
        if let Some(a) = n.attrs {
            match used.get_mut(a as usize) {
                Some(u) => *u = true,
                None => return false,
            }
        }
    }
    used.into_iter().all(|u| u)
}

/// A block, and the node it is a child of.
#[derive(Clone, Copy, Debug)]
struct Block {
    id: NodeId,
    parent: NodeId,
}

/// Everything [`apply`] needs, found and checked without changing anything.
struct Plan {
    frag: Document,
    /// Where the fragment starts, in both sources.
    f0: usize,
    /// The old edited run's ids, `lo..hi`, and the fragment's, `flo..fhi`.
    lo: usize,
    hi: usize,
    flo: usize,
    fhi: usize,
    /// The fragment's new blocks, by its ids.
    new_blocks: Vec<NodeId>,
    /// The parent of the run, the sibling before it and the one after.
    parent: NodeId,
    prev: Option<NodeId>,
    next: Option<NodeId>,
    /// The parent and every node above it, with its new span, interior and
    /// marker.
    ancestors: Vec<(NodeId, Span, Option<Span>, Option<Span>)>,
    /// Old positions past `old_end` move by `delta`; the rest stay.
    old_end: usize,
    delta: isize,
}

fn kind(doc: &Document, id: NodeId) -> &Kind {
    &doc.ast.nodes[id as usize].kind
}

fn first_child(doc: &Document, id: NodeId) -> Option<NodeId> {
    doc.ast.nodes[id as usize].first_child
}

fn next_sibling(doc: &Document, id: NodeId) -> Option<NodeId> {
    doc.ast.nodes[id as usize].next_sibling
}

/// `s` moved by `by`; the unset `(0,0)` stays unset.
fn shifted(s: Span, by: isize) -> Span {
    if s.start == 0 && s.end == 0 {
        return s;
    }
    Span::new(s.start.wrapping_add_signed(by), s.end.wrapping_add_signed(by))
}

/// Whether the side tables are one entry per node, as a compacted parse's
/// are, and the root is node 0.
fn canonical(doc: &Document) -> bool {
    let n = doc.ast.nodes.len();
    n > 0
        && doc.ast.root == 0
        && doc.node_spans.len() == n
        && doc.node_content_spans.len() == n
        && doc.node_spelling.len() == n
        && doc.node_marker_spans.len() == n
}

/// The document's blocks in order, sections opened, up to the second that
/// starts after `until`; and the parent of each section passed.
fn blocks(doc: &Document, until: usize) -> (Vec<Block>, Vec<(NodeId, NodeId)>) {
    let mut out = Vec::new();
    let mut sections = Vec::new();
    let root = doc.ast.root;
    let mut stack = vec![(root, first_child(doc, root))];
    let mut past = 0;
    while let Some(top) = stack.last_mut() {
        let Some(c) = top.1 else {
            stack.pop();
            continue;
        };
        let parent = top.0;
        top.1 = next_sibling(doc, c);
        if matches!(kind(doc, c), Kind::Section) {
            sections.push((c, parent));
            stack.push((c, first_child(doc, c)));
        } else {
            out.push(Block { id: c, parent });
            if doc.span(c).start > until {
                past += 1;
                if past == 2 {
                    break;
                }
            }
        }
    }
    (out, sections)
}

/// Whether the blocks' spans are in order and do not overlap.
fn ordered(doc: &Document, blocks: &[Block]) -> bool {
    let mut at = 0;
    blocks.iter().all(|b| {
        let s = doc.span(b.id);
        let ok = s.start >= at && s.start <= s.end;
        at = s.end;
        ok
    })
}

/// Walk the subtrees of `roots`, consecutive siblings, in pre-order: their
/// ids must run on from `roots[0]` without a gap, and none may carry
/// attributes or define a label. The id after the last, or `None`.
fn run_end(doc: &Document, roots: &[NodeId]) -> Option<usize> {
    let mut expect = roots[0] as usize;
    let mut stack: Vec<NodeId> = Vec::new();
    for &r in roots {
        stack.push(r);
        while let Some(id) = stack.pop() {
            if id as usize != expect {
                return None;
            }
            expect += 1;
            let node = &doc.ast.nodes[id as usize];
            if node.attrs.is_some() || matches!(node.kind, Kind::Reference { .. } | Kind::Footnote { .. }) {
                return None;
            }
            // Children pushed last-first, so they pop in order.
            let at = stack.len();
            let mut c = node.first_child;
            while let Some(k) = c {
                stack.push(k);
                c = next_sibling(doc, k);
            }
            stack[at..].reverse();
        }
    }
    Some(expect)
}

/// Whether the subtree at `a` in `da`, its spans moved by `sa`, is the one at
/// `b` in `db` moved by `sb`: kinds, attributes, spelling and every span.
fn same_subtree(da: &Document, a: NodeId, sa: isize, db: &Document, b: NodeId, sb: isize) -> bool {
    let opt = |s: Option<Span>, by: isize| s.map(|s| shifted(s, by));
    let mut stack = vec![(a, b)];
    while let Some((x, y)) = stack.pop() {
        let (nx, ny) = (&da.ast.nodes[x as usize], &db.ast.nodes[y as usize]);
        if nx.kind != ny.kind
            || shifted(da.span(x), sa) != shifted(db.span(y), sb)
            || opt(da.content_span(x), sa) != opt(db.content_span(y), sb)
            || opt(da.marker_span(x), sa) != opt(db.marker_span(y), sb)
            || da.spelling(x) != db.spelling(y)
            || nx.attrs.map(|i| &da.ast.attrs[i as usize]) != ny.attrs.map(|i| &db.ast.attrs[i as usize])
            || opt(da.attrs_span(x), sa) != opt(db.attrs_span(y), sb)
        {
            return false;
        }
        let (mut cx, mut cy) = (nx.first_child, ny.first_child);
        loop {
            match (cx, cy) {
                (None, None) => break,
                (Some(p), Some(q)) => {
                    stack.push((p, q));
                    cx = next_sibling(da, p);
                    cy = next_sibling(db, q);
                }
                _ => return false,
            }
        }
    }
    true
}

/// The id that follows `id`'s subtree in pre-order, given the chain of its
/// ancestors from its parent up: its next sibling, or the nearest ancestor's.
/// `None` at the end of the tree.
fn after_subtree(doc: &Document, id: NodeId, ancestors: &[NodeId]) -> Option<NodeId> {
    next_sibling(doc, id).or_else(|| ancestors.iter().find_map(|&a| next_sibling(doc, a)))
}

/// How many nodes `id`'s subtree holds.
fn subtree_len(doc: &Document, id: NodeId) -> usize {
    let mut n = 0;
    let mut stack = vec![id];
    while let Some(x) = stack.pop() {
        n += 1;
        let mut c = first_child(doc, x);
        while let Some(k) = c {
            stack.push(k);
            c = next_sibling(doc, k);
        }
    }
    n
}

fn plan(doc: &Document, new_src: &[u8], edit: Edit, fragment: &Fragment) -> Option<Plan> {
    let old_len = doc.source.len();
    let Edit { start: s, old_end: eo, new_end: en } = edit;
    if s > eo || s > en || eo > old_len || new_src.len() + eo != old_len + en || !canonical(doc) {
        return None;
    }
    let delta = en as isize - eo as isize;
    let root = doc.ast.root;
    if doc.span(root) != Span::new(0, old_len) {
        return None;
    }

    // ── the cut, in the old tree ──
    let (ob, sections) = blocks(doc, eo);
    if !ordered(doc, &ob) {
        return None;
    }
    let l = ob.partition_point(|b| doc.span(b.id).end < s);
    let r = ob.partition_point(|b| doc.span(b.id).start <= eo);
    let left = l.checked_sub(1).map(|i| ob[i]);
    let right = ob.get(r).copied();
    let run = &ob[l..r];
    let b0 = left.map_or(0, |b| doc.span(b.id).end);
    let b1 = right.map_or(old_len, |b| doc.span(b.id).start);
    let f0 = left.map_or(0, |b| doc.span(b.id).start);
    let f1 = match right {
        Some(_) => ob.get(r + 1).map_or(old_len, |b| doc.span(b.id).start),
        None => old_len,
    };

    let parent = match (run.first(), left) {
        (Some(e), _) => e.parent,
        (None, Some(lb)) => lb.parent,
        (None, None) => root,
    };
    if run.iter().any(|b| b.parent != parent) {
        return None;
    }
    // The sibling before the run is `L` itself, or the run opens the root.
    let prev = match left {
        Some(lb) => {
            if lb.parent != parent {
                return None;
            }
            Some(lb.id)
        }
        None if parent == root => None,
        None => return None,
    };
    let head = match prev {
        Some(p) => next_sibling(doc, p),
        None => first_child(doc, parent),
    };
    if let Some(e) = run.first() {
        if head != Some(e.id) {
            return None;
        }
    }
    let next = match run.last() {
        Some(e) => next_sibling(doc, e.id),
        None => head,
    };
    if run.windows(2).any(|w| next_sibling(doc, w[0].id) != Some(w[1].id)) {
        return None;
    }
    // The parent's ancestors, up to the root.
    let mut chain = vec![parent];
    while *chain.last().unwrap() != root {
        let c = *chain.last().unwrap();
        let (_, up) = *sections.iter().find(|(id, _)| *id == c)?;
        chain.push(up);
    }

    let roots: Vec<NodeId> = run.iter().map(|b| b.id).collect();
    let (lo, hi) = if roots.is_empty() {
        let at = match prev {
            Some(p) => match after_subtree(doc, p, &chain) {
                Some(n) => n as usize,
                None => p as usize + subtree_len(doc, p),
            },
            None => parent as usize + 1,
        };
        (at, at)
    } else {
        (roots[0] as usize, run_end(doc, &roots)?)
    };

    // Nothing a label points at may be in the edited run. A definition only
    // a label table reaches (a footnote's) sits between blocks: one in the
    // stretch the fragment rereads is kept if the edit did not touch it and
    // the fragment reads it back the same.
    // The stretch is what lies between `L`'s end and `R`'s start.
    let in_stretch = |sp: Span| sp.end > b0 && sp.start < b1;
    let mut kept: Vec<(usize, &[u8], NodeId)> = Vec::new();
    for (mi, m) in doc.labels.maps().into_iter().enumerate() {
        for (label, &v) in m {
            let sp = doc.span(v);
            if (lo..hi).contains(&(v as usize)) {
                return None;
            }
            if in_stretch(sp) {
                if sp.end >= s && sp.start <= eo {
                    return None;
                }
                kept.push((mi, label, v));
            }
        }
    }
    if doc.attrs_spans.iter().flatten().any(|&sp| in_stretch(sp)) {
        return None;
    }

    // ── the fragment ──
    let frag_end = f1.checked_add_signed(delta)?;
    let frag = fragment(new_src, f0..frag_end, doc)?;
    if !canonical(&frag) || frag.span(frag.ast.root) != Span::new(0, frag_end - f0) || !attrs_dense(&frag) {
        return None;
    }
    let (fb, _) = blocks(&frag, usize::MAX);
    let n_left = left.is_some() as usize;
    let n_right = right.is_some() as usize;
    if fb.len() < n_left + n_right || !ordered(&frag, &fb) {
        return None;
    }
    let f0i = f0 as isize;
    if let Some(lb) = left {
        if !same_subtree(doc, lb.id, 0, &frag, fb[0].id, f0i) {
            return None;
        }
    }
    if let Some(rb) = right {
        if !same_subtree(doc, rb.id, delta, &frag, fb[fb.len() - 1].id, f0i) {
            return None;
        }
    }
    let new_run = &fb[n_left..fb.len() - n_right];
    let new_blocks: Vec<NodeId> = new_run.iter().map(|b| b.id).collect();
    let (flo, fhi) = match new_run.first() {
        None => (0, 0),
        Some(first) => {
            let fparent = first.parent;
            if new_run.iter().any(|b| b.parent != fparent)
                || new_run.windows(2).any(|w| next_sibling(&frag, w[0].id) != Some(w[1].id))
            {
                return None;
            }
            // Under what `L` is under, or the root when there is no `L`.
            let expected = if n_left == 1 { fb[0].parent } else { frag.ast.root };
            if fparent != expected {
                return None;
            }
            if matches!(kind(&frag, fparent), Kind::Section) && first_child(&frag, fparent) == Some(first.id) {
                return None;
            }
            (first.id as usize, run_end(&frag, &new_blocks)?)
        }
    };
    let new_b1 = b1.wrapping_add_signed(delta);
    let in_new_stretch = |sp: Span| sp.end + f0 > b0 && sp.start + f0 < new_b1;
    // Attributes written in the stretch belong to what is in it, and that
    // has none: they went to a block outside it, or a section.
    if frag.attrs_spans.iter().flatten().any(|&sp| in_new_stretch(sp)) {
        return None;
    }
    let mut matched = 0;
    for (mi, m) in frag.labels.maps().into_iter().enumerate() {
        for (label, &w) in m {
            let sp = frag.span(w);
            if (flo..fhi).contains(&(w as usize)) {
                return None;
            }
            if in_new_stretch(sp) {
                let &(_, _, v) = kept.iter().find(|(km, kl, _)| *km == mi && *kl == label.as_slice())?;
                let by = if doc.span(v).end < s { 0 } else { delta };
                if !same_subtree(doc, v, by, &frag, w, f0i) {
                    return None;
                }
                matched += 1;
            }
        }
    }
    if matched != kept.len() {
        return None;
    }
    if prev.is_none() && next.is_none() && new_blocks.is_empty() {
        return None;
    }

    // ── the parent and its ancestors, from what their children became ──
    let pos = |x: usize| -> Option<usize> {
        if x <= b0 {
            Some(x)
        } else if x >= b1 {
            x.checked_add_signed(delta)
        } else {
            None
        }
    };
    let new_len = new_src.len();
    let mut ancestors = Vec::with_capacity(chain.len());
    // The child on the path to the edit, and its new span.
    let mut below: Option<(NodeId, Span)> = None;
    for &a in &chain {
        let first = first_child(doc, a)?;
        // Where the first child starts now, and — when the last child is
        // what changed — where it ended and ends now. A last child after
        // the edit moves as any position after it does.
        let (new_first, last) = match below {
            None => {
                let new_first = match (prev, new_blocks.first(), next) {
                    (Some(_), _, _) => doc.span(first).start,
                    (None, Some(&f), _) => frag.span(f).start + f0,
                    (None, None, Some(n)) => pos(doc.span(n).start)?,
                    (None, None, None) => return None,
                };
                let last = match next {
                    Some(_) => None,
                    None => {
                        let old = run.last().map(|b| b.id).or(prev)?;
                        let new = match new_blocks.last() {
                            Some(&f) => frag.span(f).end + f0,
                            None => doc.span(prev?).end,
                        };
                        Some((doc.span(old).end, new))
                    }
                };
                (new_first, last)
            }
            Some((c, sp)) => {
                let new_first = if first == c { sp.start } else { doc.span(first).start };
                (new_first, next_sibling(doc, c).is_none().then(|| (doc.span(c).end, sp.end)))
            }
        };
        let old_first = doc.span(first).start;
        let start = |x: usize| if x == old_first { Some(new_first) } else { pos(x) };
        let end = |x: usize| match last {
            Some((old, new)) if x == old => Some(new),
            _ => pos(x),
        };
        let sp = doc.span(a);
        let span = if a == root {
            Span::new(0, new_len)
        } else {
            let e = if sp.end == old_len { new_len } else { end(sp.end)? };
            Span::new(start(sp.start)?, e)
        };
        let content = match doc.content_span(a) {
            Some(c) => Some(Span::new(start(c.start)?, end(c.end)?)),
            None => None,
        };
        let marker = match doc.marker_span(a) {
            Some(m) => Some(Span::new(pos(m.start)?, pos(m.end)?)),
            None => None,
        };
        ancestors.push((a, span, content, marker));
        below = Some((a, span));
    }

    Some(Plan { frag, f0, lo, hi, flo, fhi, new_blocks, parent, prev, next, ancestors, old_end: eo, delta })
}

fn apply(doc: &mut Document, new_src: &[u8], p: Plan) {
    let Plan { mut frag, f0, lo, hi, flo, fhi, new_blocks, parent, prev, next, ancestors, old_end, delta } = p;
    let n_new = fhi - flo;
    let dn = n_new as isize - (hi - lo) as isize;
    let moved = |id: NodeId| (id as isize + dn) as NodeId;
    let local = |id: NodeId| (lo + id as usize - flo) as NodeId;
    let next_new = next.map(moved);

    // The fragment's new nodes, renumbered into the run they take over.
    let in_run = |id: NodeId| (flo..fhi).contains(&(id as usize));
    let mut nodes: Vec<_> = frag.ast.nodes.drain(flo..fhi).collect();
    for n in &mut nodes {
        n.id = local(n.id);
        n.first_child = n.first_child.map(local);
        n.next_sibling = n.next_sibling.filter(|&s| in_run(s)).map(local);
    }
    if let Some(&last) = new_blocks.last() {
        nodes[last as usize - flo].next_sibling = next_new;
    }
    let at_f0 = |s: Span| shifted(s, f0 as isize);
    let spans: Vec<Span> = frag.node_spans[flo..fhi].iter().map(|&s| at_f0(s)).collect();
    let contents: Vec<Option<Span>> = frag.node_content_spans[flo..fhi].iter().map(|s| s.map(at_f0)).collect();
    let markers: Vec<Option<Span>> = frag.node_marker_spans[flo..fhi].iter().map(|s| s.map(at_f0)).collect();
    let spellings = frag.node_spelling[flo..fhi].to_vec();

    doc.ast.nodes.splice(lo..hi, nodes);
    doc.node_spans.splice(lo..hi, spans);
    doc.node_content_spans.splice(lo..hi, contents);
    doc.node_marker_spans.splice(lo..hi, markers);
    doc.node_spelling.splice(lo..hi, spellings);

    // What follows the run: ids move by the count, spans by the length.
    let tail = lo + n_new;
    if dn != 0 {
        for n in &mut doc.ast.nodes[tail..] {
            n.id = moved(n.id);
            n.first_child = n.first_child.map(moved);
            n.next_sibling = n.next_sibling.map(moved);
        }
        for m in doc.labels.maps_mut() {
            for v in m.values_mut() {
                if *v as usize >= hi {
                    *v = moved(*v);
                }
            }
        }
    }
    // A node after the run lies after the edit, unless only a label reaches
    // it: then it is wholly before or wholly after.
    let pos = |x: usize| if x > old_end { x.wrapping_add_signed(delta) } else { x };
    let pos_span = |s: Span| Span::new(pos(s.start), pos(s.end));
    if delta != 0 {
        for s in &mut doc.node_spans[tail..] {
            *s = pos_span(*s);
        }
        for s in doc.node_content_spans[tail..].iter_mut().flatten() {
            *s = pos_span(*s);
        }
        for s in doc.node_marker_spans[tail..].iter_mut().flatten() {
            *s = pos_span(*s);
        }
        for s in doc.attrs_spans.iter_mut().flatten() {
            *s = pos_span(*s);
        }
    }

    // The links into the run, from before it.
    let head = new_blocks.first().map(|&f| local(f)).or(next_new);
    match prev {
        Some(p) => doc.ast.nodes[p as usize].next_sibling = head,
        None => doc.ast.nodes[parent as usize].first_child = head,
    }
    for (a, span, content, marker) in ancestors {
        let n = &mut doc.ast.nodes[a as usize];
        n.next_sibling = n.next_sibling.map(moved);
        doc.node_spans[a as usize] = span;
        doc.node_content_spans[a as usize] = content;
        doc.node_marker_spans[a as usize] = marker;
    }

    doc.source.clear();
    doc.source.extend_from_slice(new_src);
}
