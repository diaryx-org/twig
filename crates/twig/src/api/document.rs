//! [`Document`] — a one-shot parse and its whole read surface — and the read
//! types it hands out. Port of the `twig_document_*` half of `src/c_abi.zig`:
//! what was a borrowed C buffer is an owned Rust value here, built by the same
//! walk over the same engine calls.

use std::marker::PhantomData;
use std::ops::Range;

use crate::ast::{self as engine, locate, select, NodeId as EngineId};
use crate::diagnostics;
use crate::document::{self as edoc, Document as EngineDoc};
use crate::error::Error;
use crate::format as reg;

use super::format::{config_from_flags, Format, MarkdownExtensions, Target};
use super::kind::Kind;
use super::{Editor, NodeId};

/// One node returned by [`Document::query`]: its AST id, byte spans, and kind.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryMatch {
    /// The node's id in the shared AST.
    pub node_id: u32,
    /// The node's whole byte range in the source.
    pub span: Range<usize>,
    /// The node's interior byte range (between its delimiters), or `None` for
    /// a leaf / a container with no known interior.
    pub content_span: Option<Range<usize>>,
    /// The node's kind.
    pub kind: Kind,
}

/// One node of a [`Document::nodes`] snapshot — the flat AST arena as owned
/// Rust data. `id` indexes the snapshot; `parent`, `first_child`, and
/// `next_sibling` link the tree (`None` where absent).
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub struct FlatNode {
    pub id: NodeId,
    pub parent: Option<NodeId>,
    pub first_child: Option<NodeId>,
    pub next_sibling: Option<NodeId>,
    pub span: Range<usize>,
    pub content_span: Option<Range<usize>>,
    /// A heading's level, or a verse `line`'s indent when it is indented;
    /// `None` for every other kind and for a line at the margin.
    pub level: Option<u32>,
    pub kind: Kind,
    /// The node's text payload — a `str`'s bytes, a `code_block`'s body, a
    /// raw-text container's body — and `None` for a node whose content is its
    /// children.
    pub text: Option<String>,
    pub destination: Option<String>,
    /// Whether a `row`/`cell` belongs to the table head; `None` for every other
    /// kind.
    pub head: Option<bool>,
    /// A `cell`'s column alignment; `None` for every other kind.
    pub alignment: Option<Alignment>,
    /// The name a generic container carries in its own payload: an HTML/XML
    /// tag or a directive type. `None` for every semantic kind.
    pub name: Option<String>,
    /// Which of the three generic-container SPELLINGS this node's producer
    /// draws; `None` when it draws none. Does not answer "is it a directive?"
    /// — use [`origin`](Self::origin).
    pub directive_form: Option<DirectiveForm>,
    /// Whether a generic container was WRITTEN as a tag or as a directive;
    /// `None` when nothing recorded it.
    pub origin: Option<ContainerOrigin>,
    /// The node's own leading MARKER on its opening line, or `None`.
    pub marker_span: Option<Range<usize>>,
    /// A task list item's checkbox state; `None` for every other kind.
    pub checked: Option<bool>,
    /// The node's attributes as `(key, value)` pairs in source order. A bare
    /// attribute has a `None` value.
    pub attrs: Vec<(String, Option<String>)>,
}

/// A synthesized line prefix — what [`Document::continuation_prefix`] and
/// [`Document::blank_line_prefix`] build. `columns` is not `text.len()`: a
/// tab advances to a tab stop.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LinePrefix {
    /// The bytes to write at the head of the line.
    pub text: String,
    /// Their width in columns.
    pub columns: usize,
}

/// Table-cell alignment: written via
/// [`Builder::add_cell`](crate::Builder::add_cell), read back on
/// [`FlatNode::alignment`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Alignment {
    Default,
    Left,
    Right,
    Center,
}

impl Alignment {
    pub(crate) fn to_engine(self) -> engine::Alignment {
        match self {
            Alignment::Default => engine::Alignment::Default,
            Alignment::Left => engine::Alignment::Left,
            Alignment::Right => engine::Alignment::Right,
            Alignment::Center => engine::Alignment::Center,
        }
    }

    fn from_engine(a: engine::Alignment) -> Alignment {
        match a {
            engine::Alignment::Default => Alignment::Default,
            engine::Alignment::Left => Alignment::Left,
            engine::Alignment::Right => Alignment::Right,
            engine::Alignment::Center => Alignment::Center,
        }
    }
}

/// One thing a conversion would silently lose. See [`Document::diagnostics`].
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Warning {
    pub fidelity: Fidelity,
    /// A slash-separated child-index trail from the document root (`"1/0/2"`),
    /// EMPTY for the root itself.
    pub path: String,
    /// The affected node's kind, with family members reported as themselves.
    pub kind: Kind,
}

/// How much of a node survives a conversion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Fidelity {
    /// Emitted, but read back as a DIFFERENT kind.
    Degraded,
    /// Nothing is emitted at all.
    Dropped,
    /// Some of the node's attributes are written where the target's parser
    /// does not read them back as that node's.
    AttrsDegraded,
    /// Some of the node's attributes are not written at all.
    AttrsDropped,
}

/// Whether a generic container was written as a TAG or as a DIRECTIVE.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum ContainerOrigin {
    /// An HTML or XML tag: `<div>`, `<video>`, `<svg:rect>`.
    Element,
    /// A lightweight-markup generic container.
    Directive,
}

/// The surface form of a generic directive for
/// [`Builder::add_directive`](crate::Builder::add_directive).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DirectiveForm {
    Text,
    Leaf,
    Container,
}

impl DirectiveForm {
    pub(crate) fn to_engine(self) -> engine::Form {
        match self {
            DirectiveForm::Text => engine::Form::InlineText,
            DirectiveForm::Leaf => engine::Form::BlockLeaf,
            DirectiveForm::Container => engine::Form::BlockFenced,
        }
    }
}

// ── The document handle ─────────────────────────────────────────────────────

/// What a [`Document`] is a view OF (`DocumentView` in `c_abi.zig`): a parse
/// it owns, with the format and config it was parsed under, or a snapshot of
/// an editor's live tree, which cannot render or serialize.
#[derive(Clone, Debug)]
enum View {
    Owned(reg::ParsedDoc),
    Borrowed(EngineDoc),
}

/// A parsed document and its read surface.
#[derive(Debug)]
pub struct Document {
    view: View,
}

impl Document {
    pub fn parse(input: &[u8], format: Format) -> Result<Self, Error> {
        Self::parse_with(input, format, MarkdownExtensions::default())
    }

    pub fn parse_str(input: &str, format: Format) -> Result<Self, Error> {
        Self::parse(input.as_bytes(), format)
    }

    /// Like [`Document::parse`], plus Markdown `extensions` to enable
    /// (ignored for other formats).
    pub fn parse_with(input: &[u8], format: Format, extensions: MarkdownExtensions) -> Result<Self, Error> {
        parse_flags(input, format, extensions.to_flags())
    }

    /// Like [`Document::parse`] over a runtime row, with `features` laid over
    /// the row's own.
    pub fn parse_with_features(input: &[u8], format: Format, features: &[&str]) -> Result<Self, Error> {
        let flags = format.feature_flags(features)?;
        parse_flags(input, format, flags)
    }

    /// [`Document::parse_with`] for a `&str`.
    pub fn parse_str_with(input: &str, format: Format, extensions: MarkdownExtensions) -> Result<Self, Error> {
        Self::parse_with(input.as_bytes(), format, extensions)
    }

    pub(crate) fn borrowed(doc: EngineDoc) -> Document {
        Document { view: View::Borrowed(doc) }
    }

    /// The tree this handle reads.
    fn doc(&self) -> &EngineDoc {
        match &self.view {
            View::Owned(p) => &p.doc,
            View::Borrowed(d) => d,
        }
    }

    fn owned(&self) -> Result<&reg::ParsedDoc, Error> {
        match &self.view {
            View::Owned(p) => Ok(p),
            View::Borrowed(_) => Err(Error::UnsupportedFormat),
        }
    }

    /// Render the document to HTML with its format's renderer.
    pub fn render_html(&mut self) -> Result<Vec<u8>, Error> {
        let parsed = self.owned()?;
        reg::render_html(parsed).map_err(|e| match e {
            reg::PrintFailure::UnsafeMetadata => Error::UnsafeMetadata,
            // The registry's other failures cannot happen over an
            // already-parsed tree; Zig folds them into OutOfMemory.
            _ => Error::OutOfMemory,
        })
    }

    /// Serialize the document to `target`'s own syntax: a round-trip when
    /// `target` names the document's own format, cross-format conversion
    /// otherwise. [`Error::UnsupportedFormat`] when the direction has no
    /// serializer.
    pub fn serialize_to(&mut self, target: Target) -> Result<Vec<u8>, Error> {
        let target = target.resolve()?;
        let parsed = self.owned()?;
        let result = if reg::writes_own_syntax(parsed.format, target) {
            reg::serialize_canonical(parsed)
        } else {
            reg::serialize_converted(parsed, target)
        };
        result.map_err(|e| match e {
            reg::PrintFailure::UnsupportedFormat => Error::UnsupportedFormat,
            reg::PrintFailure::UnsafeMetadata => Error::UnsafeMetadata,
            reg::PrintFailure::Language(_) | reg::PrintFailure::UnsupportedNode => Error::Internal,
        })
    }

    /// Serialize the document to `format`'s own source syntax — the original
    /// spelling of [`Document::serialize_to`].
    pub fn serialize(&mut self, format: Format) -> Result<Vec<u8>, Error> {
        self.serialize_to(format.into())
    }

    /// Encode the document's AST as pretty-printed JSON (`twig convert -o ast`).
    pub fn ast_json(&mut self) -> Result<Vec<u8>, Error> {
        Ok(crate::ast::json::encode(self.doc()))
    }

    /// Resolve a CSS-lite selector against the document, one [`QueryMatch`]
    /// per matching node in document order. A malformed selector yields
    /// [`Error::InvalidArgument`].
    pub fn query(&mut self, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        query_matches(self.doc(), selector)
    }

    /// The whole source span of `node`.
    pub fn span(&mut self, node: NodeId) -> Result<Range<usize>, Error> {
        let d = self.doc();
        check_id(d, node.0)?;
        Ok(range(d.span(node.0)))
    }

    /// The interior span of `node`, or `None` when it has none.
    pub fn content_span(&mut self, node: NodeId) -> Result<Option<Range<usize>>, Error> {
        let d = self.doc();
        check_id(d, node.0)?;
        Ok(d.content_span(node.0).map(range))
    }

    /// The span of `node`'s own leading MARKER, or `None` when it has none.
    pub fn marker_span(&mut self, node: NodeId) -> Result<Option<Range<usize>>, Error> {
        let d = self.doc();
        check_id(d, node.0)?;
        Ok(d.marker_span(node.0).map(range))
    }

    /// The source span of the `{...}` attribute block attached to `node`, or
    /// `None` when it has no single recorded range.
    pub fn attrs_span(&mut self, node: NodeId) -> Result<Option<Range<usize>>, Error> {
        let d = self.doc();
        check_id(d, node.0)?;
        Ok(d.attrs_span(node.0).map(range))
    }

    /// Everything HIDDEN before the content on the line byte `offset` sits on,
    /// as one range from the line start; `None` on a continuation line.
    pub fn line_prefix(&mut self, offset: usize) -> Result<Option<Range<usize>>, Error> {
        let d = self.doc();
        if offset > d.source.len() {
            return Err(Error::InvalidArgument);
        }
        Ok(locate::line_prefix_span(d, offset).map(range))
    }

    /// What a CONTINUATION LINE at `offset` must open with to stay inside
    /// every container holding it.
    pub fn continuation_prefix(&mut self, offset: usize) -> Result<LinePrefix, Error> {
        self.prefix_via(offset, false)
    }

    /// What a BLANK line inside the containers at `offset` must carry.
    pub fn blank_line_prefix(&mut self, offset: usize) -> Result<LinePrefix, Error> {
        self.prefix_via(offset, true)
    }

    fn prefix_via(&mut self, offset: usize, blank: bool) -> Result<LinePrefix, Error> {
        let d = self.doc();
        if offset > d.source.len() {
            return Err(Error::InvalidArgument);
        }
        let mut buf = Vec::new();
        let columns = if blank {
            locate::blank_line_prefix(d, offset, &mut buf)
        } else {
            locate::continuation_prefix(d, offset, &mut buf)
        };
        let text = String::from_utf8(buf).map_err(|_| Error::Internal)?;
        Ok(LinePrefix { text, columns })
    }

    /// The grid extent `(columns, rows)` of the cell at `node`, or `None`
    /// when the node is not a cell.
    pub fn cell_extent(&mut self, node: NodeId) -> Result<Option<(u32, u32)>, Error> {
        let d = self.doc();
        check_id(d, node.0)?;
        Ok(match &d.ast.nodes[node.0 as usize].kind {
            engine::Kind::Cell(c) => Some((c.colspan, c.rowspan)),
            _ => None,
        })
    }

    /// Snapshot the whole tree as a flat [`FlatNode`] array, indexed so
    /// `nodes[i].id == NodeId(i)`.
    pub fn nodes(&mut self) -> Result<Vec<FlatNode>, Error> {
        Ok(flat_nodes(self.doc()))
    }

    /// The document-level **definitions**: every node that hangs off no
    /// parent and is not the document root, in arena order.
    pub fn definitions(&mut self) -> Result<Vec<QueryMatch>, Error> {
        let d = self.doc();
        Ok(d.ast.definition_roots().into_iter().map(|id| flat_match(d, id)).collect())
    }

    /// What converting this document to `target` would silently **lose**.
    /// [`Error::UnsupportedFormat`] for a target with no serializer at all.
    pub fn diagnostics(&mut self, target: Target) -> Result<Vec<Warning>, Error> {
        let target = target.resolve()?;
        let d = self.doc();
        let warnings = diagnostics::analyze(&d.ast, d.ast.root, target).map_err(|e| match e {
            diagnostics::AnalyzeError::UnsupportedFormat => Error::UnsupportedFormat,
        })?;
        Ok(warnings
            .into_iter()
            .map(|w| Warning {
                fidelity: match (w.subject, w.fidelity) {
                    (diagnostics::Subject::Node, diagnostics::Fidelity::Dropped) => Fidelity::Dropped,
                    (diagnostics::Subject::Attrs, diagnostics::Fidelity::Degraded) => Fidelity::AttrsDegraded,
                    (diagnostics::Subject::Attrs, diagnostics::Fidelity::Dropped) => Fidelity::AttrsDropped,
                    _ => Fidelity::Degraded,
                },
                path: w.path,
                kind: Kind::from(w.kind),
            })
            .collect())
    }

    /// The direct children of `node` — `None` enumerates the root's.
    pub fn children(&mut self, node: Option<NodeId>) -> Result<Vec<QueryMatch>, Error> {
        children_of(self.doc(), node)
    }

    /// Snapshot the subtree rooted at `node` with *local* ids.
    pub fn subtree(&mut self, node: NodeId) -> Result<Vec<FlatNode>, Error> {
        subtree_of(self.doc(), node)
    }

    /// The deepest node whose span contains byte `offset`.
    pub fn node_at(&mut self, offset: usize) -> Result<Option<QueryMatch>, Error> {
        node_at(self.doc(), offset)
    }

    /// The chain of nodes containing byte `offset`, root-first.
    pub fn ancestors_at(&mut self, offset: usize) -> Result<Vec<QueryMatch>, Error> {
        ancestors_at(self.doc(), offset)
    }

    /// [`Document::node_at`] under CARET containment.
    pub fn node_at_caret(&mut self, offset: usize) -> Result<Option<QueryMatch>, Error> {
        let d = self.doc();
        if offset > d.source.len() {
            return Err(Error::InvalidArgument);
        }
        Ok(locate::deepest_containing_for_caret(d, offset).map(|id| flat_match(d, id)))
    }

    /// [`Document::ancestors_at`] under caret containment.
    pub fn ancestors_at_caret(&mut self, offset: usize) -> Result<Vec<QueryMatch>, Error> {
        let d = self.doc();
        if offset > d.source.len() {
            return Err(Error::InvalidArgument);
        }
        if d.ast.nodes.is_empty() {
            return Ok(Vec::new());
        }
        let mut cur = d.ast.root;
        let mut chain = vec![flat_match(d, cur)];
        while let Some(child) = locate::caret_child_containing(d, cur, offset) {
            cur = child;
            chain.push(flat_match(d, cur));
        }
        Ok(chain)
    }
}

fn parse_flags(input: &[u8], format: Format, flags: u32) -> Result<Document, Error> {
    let fmt = format.resolve()?;
    let cfg = config_from_flags(fmt, flags);
    let parsed = reg::parse(fmt, &cfg, input).map_err(|_| Error::ParseError)?;
    Ok(Document { view: View::Owned(parsed) })
}

/// A [`Document`] borrowed from an [`Editor`] (see
/// [`Editor::document`](crate::Editor::document)): the editor's live tree
/// behind the whole document read surface. It holds the editor mutably
/// borrowed, so the tree cannot change underneath it.
/// [`Document::render_html`] and [`Document::serialize`] answer
/// [`Error::UnsupportedFormat`] through it.
#[derive(Debug)]
pub struct DocumentView<'a> {
    pub(crate) doc: Document,
    pub(crate) _editor: PhantomData<&'a mut Editor>,
}

impl std::ops::Deref for DocumentView<'_> {
    type Target = Document;

    fn deref(&self) -> &Document {
        &self.doc
    }
}

impl std::ops::DerefMut for DocumentView<'_> {
    fn deref_mut(&mut self) -> &mut Document {
        &mut self.doc
    }
}

// ── The shared read walks (document and editor alike) ───────────────────────

fn range(s: crate::span::Span) -> Range<usize> {
    s.start..s.end
}

fn check_id(d: &EngineDoc, id: u32) -> Result<(), Error> {
    if (id as usize) >= d.ast.nodes.len() {
        return Err(Error::InvalidArgument);
    }
    Ok(())
}

/// `flatMatch`: a node id as a [`QueryMatch`].
pub(crate) fn flat_match(d: &EngineDoc, id: EngineId) -> QueryMatch {
    QueryMatch {
        node_id: id,
        span: range(d.span(id)),
        content_span: d.content_span(id).map(range),
        kind: Kind::from(d.ast.nodes[id as usize].kind.kind_name()),
    }
}

/// `buildQueryMatches`.
pub(crate) fn query_matches(d: &EngineDoc, selector: &str) -> Result<Vec<QueryMatch>, Error> {
    let sel = select::parse(selector.as_bytes()).map_err(|_| Error::InvalidArgument)?;
    Ok(select::resolve_all(d, &sel)
        .into_iter()
        .map(|m| QueryMatch {
            node_id: m.id,
            span: range(m.span),
            content_span: m.content_span.map(range),
            kind: Kind::from(d.ast.nodes[m.id as usize].kind.kind_name()),
        })
        .collect())
}

pub(crate) fn children_of(d: &EngineDoc, node: Option<NodeId>) -> Result<Vec<QueryMatch>, Error> {
    // `None` is the C ABI's `TWIG_NO_NODE`, which `u32::MAX` also spells.
    let id = node.map_or(u32::MAX, |n| n.0);
    let parent = if id == u32::MAX {
        d.ast.root
    } else if (id as usize) < d.ast.nodes.len() {
        id
    } else {
        return Err(Error::InvalidArgument);
    };
    Ok(d.ast.children(parent).map(|c| flat_match(d, c.id)).collect())
}

pub(crate) fn node_at(d: &EngineDoc, offset: usize) -> Result<Option<QueryMatch>, Error> {
    if offset > d.source.len() {
        return Err(Error::InvalidArgument);
    }
    Ok(locate::deepest_containing(d, offset).map(|id| flat_match(d, id)))
}

pub(crate) fn ancestors_at(d: &EngineDoc, offset: usize) -> Result<Vec<QueryMatch>, Error> {
    if offset > d.source.len() {
        return Err(Error::InvalidArgument);
    }
    // Rebuild the exact root→deepest descent, so the chain's last element is
    // always what `node_at` returns. The root is the outermost breadcrumb
    // even when its own span is unset.
    let Some(deepest) = locate::deepest_containing(d, offset) else {
        return Ok(Vec::new());
    };
    let mut cur = d.ast.root;
    let mut chain = vec![flat_match(d, cur)];
    while cur != deepest {
        match locate::child_containing(d, cur, offset) {
            Some(c) => cur = c,
            None => break,
        }
        chain.push(flat_match(d, cur));
    }
    Ok(chain)
}

fn bytes_string(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// `flatNodeOf` plus `fillAttrs` for one node.
fn flat_node_of(
    d: &EngineDoc,
    arena_id: EngineId,
    id: u32,
    parent: Option<u32>,
    first_child: Option<u32>,
    next_sibling: Option<u32>,
) -> FlatNode {
    let node = &d.ast.nodes[arena_id as usize];
    let kind = &node.kind;
    use engine::Kind as K;
    let text: Option<String> = match kind {
        K::Str(s) => Some(bytes_string(s)),
        K::TextLeaf { text, .. } | K::MarkupLeaf { text, .. } => Some(bytes_string(text)),
        K::CodeBlock { text, .. } | K::RawBlock { text, .. } | K::RawInline { text, .. } | K::Metadata { text, .. } => {
            Some(bytes_string(text))
        }
        K::Container(c) => c.text.as_deref().map(bytes_string),
        K::SmartPunctuation(p) => Some(p.ascii().to_string()),
        _ => None,
    };
    let destination = match kind {
        K::Link(l) | K::Image(l) => l.destination.as_deref().map(bytes_string),
        _ => None,
    };
    let level = match kind {
        K::Heading { level } => *level,
        K::Line { indent } => *indent,
        _ => 0,
    };
    let head = match kind {
        K::Row { head } => Some(*head),
        K::Cell(c) => Some(c.head),
        _ => None,
    };
    let alignment = match kind {
        K::Cell(c) => Some(Alignment::from_engine(c.alignment)),
        _ => None,
    };
    let (name, directive_form) = match kind {
        K::Container(c) => (
            Some(bytes_string(&c.name)),
            c.form.map(|f| match f {
                engine::Form::InlineText => DirectiveForm::Text,
                engine::Form::BlockLeaf => DirectiveForm::Leaf,
                engine::Form::BlockFenced => DirectiveForm::Container,
            }),
        ),
        _ => (None, None),
    };
    let origin = d.container_origin(arena_id).map(|o| match o {
        edoc::ContainerOrigin::Element => ContainerOrigin::Element,
        edoc::ContainerOrigin::Directive => ContainerOrigin::Directive,
    });
    let checked = match kind {
        K::TaskListItem { checked } => Some(*checked),
        _ => None,
    };
    let attrs = d
        .ast
        .attrs_of(arena_id)
        .entries
        .iter()
        .map(|kv| (bytes_string(&kv.key), kv.value.as_deref().map(bytes_string)))
        .collect();
    FlatNode {
        id: NodeId(id),
        parent: parent.map(NodeId),
        first_child: first_child.map(NodeId),
        next_sibling: next_sibling.map(NodeId),
        span: range(d.span(arena_id)),
        content_span: d.content_span(arena_id).map(range),
        level: if level != 0 { Some(level) } else { None },
        kind: Kind::from(kind.kind_name()),
        text,
        destination,
        head,
        alignment,
        name,
        directive_form,
        origin,
        marker_span: d.marker_span(arena_id).map(range),
        checked,
        attrs,
    }
}

/// `twig_document_nodes`.
pub(crate) fn flat_nodes(d: &EngineDoc) -> Vec<FlatNode> {
    let nodes = &d.ast.nodes;
    // A `Node` stores children, not its parent: derive it by stamping each
    // node's children with its own id.
    let mut parents: Vec<Option<u32>> = vec![None; nodes.len()];
    for (i, node) in nodes.iter().enumerate() {
        let mut child = node.first_child;
        while let Some(c) = child {
            parents[c as usize] = Some(i as u32);
            child = nodes[c as usize].next_sibling;
        }
    }
    nodes
        .iter()
        .enumerate()
        .map(|(i, node)| flat_node_of(d, i as u32, i as u32, parents[i], node.first_child, node.next_sibling))
        .collect()
}

/// `twig_document_subtree`: local ids, absolute spans.
pub(crate) fn subtree_of(d: &EngineDoc, node: NodeId) -> Result<Vec<FlatNode>, Error> {
    let ast = &d.ast;
    check_id(d, node.0)?;
    let ids = ast.subtree_ids(node.0);
    let mut local: Vec<Option<u32>> = vec![None; ast.nodes.len()];
    for (i, &old) in ids.iter().enumerate() {
        local[old as usize] = Some(i as u32);
    }
    let map = |maybe: Option<EngineId>| maybe.and_then(|id| local[id as usize]);
    let mut parents: Vec<Option<u32>> = vec![None; ids.len()];
    for (i, &old) in ids.iter().enumerate() {
        let mut child = ast.nodes[old as usize].first_child;
        while let Some(c) = child {
            if let Some(l) = local[c as usize] {
                parents[l as usize] = Some(i as u32);
            }
            child = ast.nodes[c as usize].next_sibling;
        }
    }
    Ok(ids
        .iter()
        .enumerate()
        .map(|(i, &old)| {
            let n = &ast.nodes[old as usize];
            flat_node_of(d, old, i as u32, parents[i], map(n.first_child), map(n.next_sibling))
        })
        .collect())
}

