//! [`Builder`] — programmatic construction of a document. Port of the
//! `twig_builder_*` half of `src/c_abi.zig` over `ast::Builder`.

use crate::ast::{self as engine, Attrs, Builder as EngineBuilder, Cell, Container, KeyVal, Link, TextLeafKind};
use crate::document::{self as edoc, Document as EngineDoc, Spelling};
use crate::error::Error;
use crate::format as reg;
use crate::languages;

use super::document::{query_matches, Alignment, DirectiveForm, QueryMatch};
use super::format::{Format, Target};

/// The id of a node added to a [`Builder`] (and of a node in any snapshot).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct NodeId(pub u32);

/// The void-payload node kinds, addable via [`Builder::add`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VoidKind {
    Doc,
    Para,
    ThematicBreak,
    Section,
    Div,
    BlockQuote,
    DefinitionList,
    Table,
    ListItem,
    DefinitionListItem,
    Term,
    Definition,
    Caption,
    SoftBreak,
    HardBreak,
    NonBreakingSpace,
    Emph,
    Strong,
    Span,
    Mark,
    Superscript,
    Subscript,
    Insert,
    Delete,
    DoubleQuoted,
    SingleQuoted,
}

impl VoidKind {
    /// `voidKind`: `div`/`span` build the containers they always did.
    fn to_engine(self) -> engine::Kind {
        use engine::{Form, InlineMark as M, Kind as K};
        match self {
            VoidKind::Doc => K::Doc,
            VoidKind::Para => K::Para,
            VoidKind::ThematicBreak => K::ThematicBreak,
            VoidKind::Section => K::Section,
            VoidKind::Div => K::Container(Container::with_form(b"div", Form::BlockFenced)),
            VoidKind::Span => K::Container(Container::with_form(b"span", Form::InlineText)),
            VoidKind::BlockQuote => K::BlockQuote,
            VoidKind::DefinitionList => K::DefinitionList,
            VoidKind::Table => K::Table,
            VoidKind::ListItem => K::ListItem,
            VoidKind::DefinitionListItem => K::DefinitionListItem,
            VoidKind::Term => K::Term,
            VoidKind::Definition => K::Definition,
            VoidKind::Caption => K::Caption,
            VoidKind::SoftBreak => K::SoftBreak,
            VoidKind::HardBreak => K::HardBreak,
            VoidKind::NonBreakingSpace => K::NonBreakingSpace,
            VoidKind::Emph => K::InlineMark(M::Emph),
            VoidKind::Strong => K::InlineMark(M::Strong),
            VoidKind::Mark => K::InlineMark(M::Mark),
            VoidKind::Superscript => K::InlineMark(M::Superscript),
            VoidKind::Subscript => K::InlineMark(M::Subscript),
            VoidKind::Insert => K::InlineMark(M::Insert),
            VoidKind::Delete => K::InlineMark(M::Delete),
            VoidKind::DoubleQuoted => K::InlineMark(M::DoubleQuoted),
            VoidKind::SingleQuoted => K::InlineMark(M::SingleQuoted),
        }
    }
}

/// The single-string-payload node kinds, addable via [`Builder::add_text`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextKind {
    Str,
    Symb,
    Verbatim,
    InlineMath,
    DisplayMath,
    Url,
    Email,
    FootnoteReference,
    /// reStructuredText's `[CIT2002]_`; the payload is the label as WRITTEN.
    CitationReference,
    /// reStructuredText's `|name|`.
    SubstitutionReference,
    Comment,
    Doctype,
    Cdata,
}

impl TextKind {
    fn to_engine(self, text: &str) -> engine::Kind {
        use engine::{Kind as K, MarkupLeafKind as Mk};
        let t = text.as_bytes().to_vec();
        let leaf = |kind: TextLeafKind| K::TextLeaf { kind, text: t.clone() };
        match self {
            TextKind::Str => K::Str(t),
            TextKind::Symb => leaf(TextLeafKind::Symb),
            TextKind::Verbatim => leaf(TextLeafKind::Verbatim),
            TextKind::InlineMath => leaf(TextLeafKind::InlineMath),
            TextKind::DisplayMath => leaf(TextLeafKind::DisplayMath),
            TextKind::Url => leaf(TextLeafKind::Url),
            TextKind::Email => leaf(TextLeafKind::Email),
            TextKind::FootnoteReference => leaf(TextLeafKind::FootnoteReference),
            TextKind::CitationReference => leaf(TextLeafKind::CitationReference),
            TextKind::SubstitutionReference => leaf(TextLeafKind::SubstitutionReference),
            TextKind::Comment => K::MarkupLeaf { kind: Mk::Comment, text: t },
            TextKind::Doctype => K::MarkupLeaf { kind: Mk::Doctype, text: t },
            TextKind::Cdata => K::MarkupLeaf { kind: Mk::Cdata, text: t },
        }
    }
}

/// Bullet marker style for [`Builder::add_bullet_list`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BulletStyle {
    Dash,
    Plus,
    Star,
}

/// Numbering scheme for [`Builder::add_ordered_list`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrderedNumbering {
    Decimal,
    LowerAlpha,
    UpperAlpha,
    LowerRoman,
    UpperRoman,
}

/// Delimiter around an ordered-list number (`1.`, `1)`, `(1)`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrderedDelim {
    Period,
    ParenAfter,
    ParenBoth,
}

/// The smart-punctuation kind for [`Builder::add_smart_punctuation`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SmartPunctuation {
    LeftSingleQuote,
    RightSingleQuote,
    LeftDoubleQuote,
    RightDoubleQuote,
    Ellipses,
    EmDash,
    EnDash,
}

/// Programmatic construction of a document — the write-path mirror of
/// [`Document::parse`](crate::Document::parse). Build bottom-up (children,
/// then the container, wired with [`Builder::set_children`]); then render,
/// serialize, query, or dump the subtree rooted at any id, without consuming
/// the builder.
#[derive(Debug)]
pub struct Builder {
    builder: EngineBuilder,
}

impl Builder {
    /// Create an empty builder.
    pub fn new() -> Result<Self, Error> {
        Ok(Builder { builder: EngineBuilder::new() })
    }

    fn emit(&mut self, kind: engine::Kind) -> Result<NodeId, Error> {
        Ok(NodeId(self.builder.add_node(kind)))
    }

    /// Add a void-payload node.
    pub fn add(&mut self, kind: VoidKind) -> Result<NodeId, Error> {
        self.emit(kind.to_engine())
    }

    /// Add a single-string-payload node.
    pub fn add_text(&mut self, kind: TextKind, text: &str) -> Result<NodeId, Error> {
        self.emit(kind.to_engine(text))
    }

    /// Add a heading of the given level.
    pub fn add_heading(&mut self, level: u32) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Heading { level })
    }

    /// Add a code block, with an optional info-string language.
    pub fn add_code_block(&mut self, lang: Option<&str>, text: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::CodeBlock { lang: lang.map(|l| l.as_bytes().to_vec()), text: text.as_bytes().to_vec() })
    }

    /// Add a raw block targeting `format` (e.g. `"html"`).
    pub fn add_raw_block(&mut self, format: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::RawBlock { format: format.as_bytes().to_vec(), text: text.as_bytes().to_vec() })
    }

    /// Add a document-metadata block written in config language `lang`.
    pub fn add_metadata(&mut self, lang: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Metadata { lang: lang.as_bytes().to_vec(), text: text.as_bytes().to_vec() })
    }

    /// Add a raw inline targeting `format`.
    pub fn add_raw_inline(&mut self, format: &str, text: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::RawInline { format: format.as_bytes().to_vec(), text: text.as_bytes().to_vec() })
    }

    /// Add a smart-punctuation node of `kind`. `text` is accepted for
    /// compatibility and ignored: the spelling is always the canonical one.
    pub fn add_smart_punctuation(&mut self, kind: SmartPunctuation, text: &str) -> Result<NodeId, Error> {
        let _ = text;
        use engine::SmartPunctuationKind as P;
        self.emit(engine::Kind::SmartPunctuation(match kind {
            SmartPunctuation::LeftSingleQuote => P::LeftSingleQuote,
            SmartPunctuation::RightSingleQuote => P::RightSingleQuote,
            SmartPunctuation::LeftDoubleQuote => P::LeftDoubleQuote,
            SmartPunctuation::RightDoubleQuote => P::RightDoubleQuote,
            SmartPunctuation::Ellipses => P::Ellipses,
            SmartPunctuation::EmDash => P::EmDash,
            SmartPunctuation::EnDash => P::EnDash,
        }))
    }

    /// Add a link with an optional destination and/or reference label.
    pub fn add_link(&mut self, destination: Option<&str>, reference: Option<&str>) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Link(link(destination, reference)))
    }

    /// Add an image — like [`Builder::add_link`], children are the alt text.
    pub fn add_image(&mut self, destination: Option<&str>, reference: Option<&str>) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Image(link(destination, reference)))
    }

    /// Add a generic directive of the given form and name.
    pub fn add_directive(&mut self, form: DirectiveForm, name: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Container(Container::with_form(name.as_bytes(), form.to_engine())))
    }

    /// Add a generic named element.
    pub fn add_element(&mut self, name: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Container(Container::named(name.as_bytes())))
    }

    /// Add an XML processing instruction (`<?target data?>`).
    pub fn add_processing_instruction(&mut self, target: &str, data: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::ProcessingInstruction {
            target: target.as_bytes().to_vec(),
            data: data.as_bytes().to_vec(),
        })
    }

    /// Add a footnote definition with the given label.
    pub fn add_footnote(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Footnote { label: label.as_bytes().to_vec() })
    }

    /// Add a citation definition — reStructuredText's `.. [CIT2002] ...`.
    pub fn add_citation(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Citation { label: label.as_bytes().to_vec() })
    }

    /// Add a substitution definition — its children are INLINE nodes.
    pub fn add_substitution(&mut self, label: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Substitution { label: label.as_bytes().to_vec() })
    }

    /// Add a link/image reference definition (`label` → `destination`).
    pub fn add_reference(&mut self, label: &str, destination: &str) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Reference {
            label: label.as_bytes().to_vec(),
            destination: destination.as_bytes().to_vec(),
        })
    }

    /// Add a bullet list. The style is SPELLING, recorded in the builder's
    /// spelling side-table.
    pub fn add_bullet_list(&mut self, style: BulletStyle, tight: bool) -> Result<NodeId, Error> {
        let id = self.emit(engine::Kind::BulletList { tight })?;
        self.builder.set_spelling(
            id.0,
            Spelling::Bullet(match style {
                BulletStyle::Dash => edoc::Bullet::Dash,
                BulletStyle::Plus => edoc::Bullet::Plus,
                BulletStyle::Star => edoc::Bullet::Star,
            }),
        );
        Ok(id)
    }

    /// Add an ordered list, with an optional explicit start number.
    pub fn add_ordered_list(
        &mut self,
        numbering: OrderedNumbering,
        delim: OrderedDelim,
        tight: bool,
        start: Option<u32>,
    ) -> Result<NodeId, Error> {
        use engine::ListNumbering as N;
        let numbering = match numbering {
            OrderedNumbering::Decimal => N::Decimal,
            OrderedNumbering::LowerAlpha => N::LowerAlpha,
            OrderedNumbering::UpperAlpha => N::UpperAlpha,
            OrderedNumbering::LowerRoman => N::LowerRoman,
            OrderedNumbering::UpperRoman => N::UpperRoman,
        };
        let id = self.emit(engine::Kind::OrderedList { numbering, tight, start })?;
        self.builder.set_spelling(
            id.0,
            Spelling::OrderedDelim(match delim {
                OrderedDelim::Period => edoc::OrderedDelim::Period,
                OrderedDelim::ParenAfter => edoc::OrderedDelim::ParenAfter,
                OrderedDelim::ParenBoth => edoc::OrderedDelim::ParenBoth,
            }),
        );
        Ok(id)
    }

    /// Add a task list.
    pub fn add_task_list(&mut self, tight: bool) -> Result<NodeId, Error> {
        self.emit(engine::Kind::TaskList { tight })
    }

    /// Add a task-list item with the given checkbox state.
    pub fn add_task_list_item(&mut self, checked: bool) -> Result<NodeId, Error> {
        self.emit(engine::Kind::TaskListItem { checked })
    }

    /// Add a table row (`head` marks a header row).
    pub fn add_row(&mut self, head: bool) -> Result<NodeId, Error> {
        self.emit(engine::Kind::Row { head })
    }

    /// Add a one-square table cell.
    pub fn add_cell(&mut self, head: bool, alignment: Alignment) -> Result<NodeId, Error> {
        self.add_cell_spanning(head, alignment, 1, 1)
    }

    /// Add a table cell occupying `colspan` columns and `rowspan` rows. Both
    /// must be at least 1 ([`Error::InvalidArgument`] otherwise).
    pub fn add_cell_spanning(
        &mut self,
        head: bool,
        alignment: Alignment,
        colspan: u32,
        rowspan: u32,
    ) -> Result<NodeId, Error> {
        if colspan == 0 || rowspan == 0 {
            return Err(Error::InvalidArgument);
        }
        self.emit(engine::Kind::Cell(Cell { head, alignment: alignment.to_engine(), colspan, rowspan }))
    }

    fn check(&self, id: u32) -> Result<(), Error> {
        if (id as usize) >= self.builder.len() {
            return Err(Error::InvalidArgument);
        }
        Ok(())
    }

    /// Set `parent`'s children to `children` (in order), replacing any it had.
    /// Every id must name a node already added, else
    /// [`Error::InvalidArgument`].
    pub fn set_children(&mut self, parent: NodeId, children: &[NodeId]) -> Result<(), Error> {
        self.check(parent.0)?;
        for c in children {
            self.check(c.0)?;
        }
        let ids: Vec<u32> = children.iter().map(|n| n.0).collect();
        self.builder.set_children(parent.0, &ids);
        Ok(())
    }

    /// Attach `{...}` attributes to `id` (`(key, None)` is a bare attribute),
    /// replacing any it had. An empty slice clears them.
    pub fn set_attrs(&mut self, id: NodeId, attrs: &[(&str, Option<&str>)]) -> Result<(), Error> {
        self.check(id.0)?;
        self.builder.set_attrs(id.0, Attrs { entries: key_vals(attrs) });
        Ok(())
    }

    /// The subtree at `root` as a document over no source (`viewDocument`).
    fn view_document(&self, root: u32) -> EngineDoc {
        self.builder.clone().finish_document(b"", root)
    }

    /// Render the subtree rooted at `root` to HTML (the generic printer).
    pub fn render_html(&mut self, root: NodeId) -> Result<Vec<u8>, Error> {
        self.check(root.0)?;
        let ast = self.builder.view(root.0);
        languages::html::serialize_alloc(&ast, None).map_err(|_| Error::UnsafeMetadata)
    }

    /// Serialize the subtree rooted at `root` to `target`'s syntax.
    /// [`Error::UnsupportedFormat`] when the target can't represent the
    /// built tree.
    pub fn serialize_to(&mut self, root: NodeId, target: Target) -> Result<Vec<u8>, Error> {
        let target = target.resolve()?;
        self.check(root.0)?;
        let doc = self.view_document(root.0);
        serialize_built_ast(&doc, target)
    }

    /// Serialize the subtree rooted at `root` to `format`'s source syntax.
    pub fn serialize(&mut self, root: NodeId, format: Format) -> Result<Vec<u8>, Error> {
        self.serialize_to(root, format.into())
    }

    /// Encode the subtree rooted at `root` as pretty-printed JSON.
    pub fn ast_json(&mut self, root: NodeId) -> Result<Vec<u8>, Error> {
        self.check(root.0)?;
        Ok(crate::ast::json::encode(&self.view_document(root.0)))
    }

    /// Resolve a selector against the subtree rooted at `root`.
    pub fn query(&mut self, root: NodeId, selector: &str) -> Result<Vec<QueryMatch>, Error> {
        self.check(root.0)?;
        query_matches(&self.view_document(root.0), selector)
    }
}

fn link(destination: Option<&str>, reference: Option<&str>) -> Link {
    Link {
        destination: destination.map(|d| d.as_bytes().to_vec()),
        reference: reference.map(|r| r.as_bytes().to_vec()),
    }
}

pub(crate) fn key_vals(attrs: &[(&str, Option<&str>)]) -> Vec<KeyVal> {
    attrs.iter().map(|(k, v)| KeyVal::new(k.as_bytes(), v.map(str::as_bytes))).collect()
}

/// `serializeBuiltAst`: always from the bare tree, carrying the builder's
/// spelling table where the target reads one.
fn serialize_built_ast(doc: &EngineDoc, target: reg::Target) -> Result<Vec<u8>, Error> {
    let ast = &doc.ast;
    Ok(match target {
        reg::Target::Djot => languages::djot::serializer::serialize_ast_spelled(ast, &doc.node_spelling),
        reg::Target::Markdown => languages::markdown::serializer::serialize_ast_spelled(ast, &doc.node_spelling),
        reg::Target::Html => languages::html::serialize_alloc(ast, None).map_err(|_| Error::UnsafeMetadata)?,
        reg::Target::Xml => {
            // XML's printer handles only the generic-markup kinds its own
            // parser produces; Zig panics on anything else, and the C ABI
            // promises `UnsupportedFormat`.
            if !ast.subtree_ids(ast.root).iter().all(|&id| xml_prints(&ast.nodes[id as usize].kind)) {
                return Err(Error::UnsupportedFormat);
            }
            languages::xml::serialize(doc)
        }
        reg::Target::Asciidoc => languages::asciidoc::serializer::serialize_ast_spelled(ast, &doc.node_spelling),
        reg::Target::Runtime(_) => reg::serialize_from_ast(target, ast).map_err(|e| match e {
            reg::PrintFailure::UnsafeMetadata => Error::UnsafeMetadata,
            _ => Error::UnsupportedFormat,
        })?,
    })
}

/// The kinds XML's serializer prints.
fn xml_prints(kind: &engine::Kind) -> bool {
    matches!(
        kind,
        engine::Kind::Doc
            | engine::Kind::Str(_)
            | engine::Kind::Container(_)
            | engine::Kind::MarkupLeaf { .. }
            | engine::Kind::ProcessingInstruction { .. }
    )
}
