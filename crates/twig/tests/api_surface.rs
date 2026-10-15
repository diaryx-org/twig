//! Compile-only proof that every public item of the crate's surface exists
//! at its root with the SAME signature: each method is coerced to the exact
//! function-pointer type the binding declared, so a changed parameter or
//! return type is a compile error here. The runtime-language items
//! (`Language`, `register`, `serve`, `helper`, …) belong to the runtime layer
//! and are pinned there.

#![allow(clippy::type_complexity)]

use std::ops::Range;

use twig::{
    abi_version, version, version_string, Alignment, Builder, BlockContainerKind, BlockKind, BulletStyle, Change,
    ContainerOrigin, DirectiveForm, Document, DocumentView, Editor, Error, Fidelity, FlatNode, Format, Gesture,
    InlineKind, Kind, LinePrefix, MarkColor, NodeId, OrderedDelim, OrderedNumbering, QueryMatch,
    SmartPunctuation, Span, Target, TextKind, Version, VoidKind, Warning, ABI_VERSION,
};

type R<T> = Result<T, Error>;
type Attrs<'a> = &'a [(&'a str, Option<&'a str>)];

fn assert_traits<T: Clone + std::fmt::Debug + Eq + PartialEq>() {}
fn assert_copy<T: Copy>() {}
fn assert_debug<T: std::fmt::Debug>() {}

#[test]
fn every_binding_item_exists_with_its_signature() {
    // ── Format / Target: handles to registry rows ──────────────────────
    let _: fn(Format) -> u16 = Format::code;
    let _: fn(i64) -> Option<Format> = Format::from_code;
    let _: fn(&str) -> Option<Format> = Format::by_name;
    let _: fn(Format, &[&str]) -> R<u32> = Format::feature_flags;
    let _: fn(Format, &[&str], Gesture) -> bool = Format::supports_with_features;
    let _: fn(Format, u32, Gesture) -> bool = Format::supports_flags;
    let _: fn(Format) -> &'static str = Format::name;
    let _: fn(Format) -> Option<Format> = Format::dialect_of;
    let _: fn(Format) -> bool = Format::is_runtime;
    let _: fn(Format) -> bool = Format::is_registered;
    let _: fn(Format) -> Target = Format::target;
    let _: fn(Format, Gesture) -> bool = Format::supports;
    let _: fn(Format) -> bool = Format::is_authorable;
    let _: fn(Target) -> Option<Format> = Target::as_format;
    let _: fn(Target) -> u16 = Target::code;
    let _: fn(Target) -> &'static str = Target::name;
    let _: fn(Format) -> Target = Target::from;
    let _: fn(twig_markdown::Markdown) -> Result<Format, twig::NativeRegisterError> = twig::register;
    assert_copy::<Format>();
    assert_copy::<Target>();
    assert_traits::<Format>();
    assert_traits::<Target>();
    let _ = |f: Format| std::collections::HashSet::from([f]);

    // ── Kind ─────────────────────────────────────────────────────────────
    let _: for<'a> fn(&'a Kind) -> &'a str = Kind::as_str;
    let _: fn(&Kind) -> bool = Kind::is_unknown;
    let _ = |s: &str| -> Kind { Kind::from(s) };
    let _ = |k: &Kind| k.to_string();
    let _ = |k: Kind| std::collections::HashSet::from([k]);
    let _ = Kind::Other(String::new());
    let _ = [
        Kind::Doc,
        Kind::Para,
        Kind::Heading,
        Kind::ThematicBreak,
        Kind::Section,
        Kind::CodeBlock,
        Kind::RawBlock,
        Kind::Metadata,
        Kind::BlockQuote,
        Kind::BulletList,
        Kind::OrderedList,
        Kind::TaskList,
        Kind::DefinitionList,
        Kind::LineBlock,
        Kind::Table,
        Kind::ListItem,
        Kind::TaskListItem,
        Kind::DefinitionListItem,
        Kind::Term,
        Kind::Definition,
        Kind::Line,
        Kind::Row,
        Kind::Cell,
        Kind::Column,
        Kind::Caption,
        Kind::Footnote,
        Kind::Reference,
        Kind::Citation,
        Kind::Substitution,
        Kind::Str,
        Kind::SoftBreak,
        Kind::HardBreak,
        Kind::NonBreakingSpace,
        Kind::RawInline,
        Kind::SmartPunctuation,
        Kind::Link,
        Kind::Image,
        Kind::Emph,
        Kind::Strong,
        Kind::Mark,
        Kind::Superscript,
        Kind::Subscript,
        Kind::Insert,
        Kind::Delete,
        Kind::DoubleQuoted,
        Kind::SingleQuoted,
        Kind::Symb,
        Kind::Verbatim,
        Kind::InlineMath,
        Kind::DisplayMath,
        Kind::Url,
        Kind::Email,
        Kind::FootnoteReference,
        Kind::CitationReference,
        Kind::SubstitutionReference,
        Kind::Container,
        Kind::ProcessingInstruction,
        Kind::Comment,
        Kind::Doctype,
        Kind::Cdata,
    ];

    // ── Plain data types, field for field ────────────────────────────────
    let _ = |m: QueryMatch| -> (u32, Range<usize>, Option<Range<usize>>, Kind) {
        (m.node_id, m.span, m.content_span, m.kind)
    };
    assert_traits::<QueryMatch>();
    let _ = Change { old: 0..0, new: 0..0 };
    let _: fn(&Change) -> isize = Change::delta;
    assert_traits::<Change>();
    let _ = |n: FlatNode| {
        let _: NodeId = n.id;
        let _: Option<NodeId> = n.parent;
        let _: Option<NodeId> = n.first_child;
        let _: Option<NodeId> = n.next_sibling;
        let _: Range<usize> = n.span;
        let _: Option<Range<usize>> = n.content_span;
        let _: Option<u32> = n.level;
        let _: Kind = n.kind;
        let _: Option<String> = n.text;
        let _: Option<String> = n.destination;
        let _: Option<bool> = n.head;
        let _: Option<Alignment> = n.alignment;
        let _: Option<String> = n.name;
        let _: Option<DirectiveForm> = n.directive_form;
        let _: Option<ContainerOrigin> = n.origin;
        let _: Option<Range<usize>> = n.marker_span;
        let _: Option<bool> = n.checked;
        let _: Vec<(String, Option<String>)> = n.attrs;
    };
    assert_traits::<FlatNode>();
    let _ = LinePrefix { text: String::new(), columns: 0 };
    let _ = LinePrefix::default();
    assert_traits::<LinePrefix>();
    let _ = |w: Warning| -> (Fidelity, String, Kind) { (w.fidelity, w.path, w.kind) };
    assert_traits::<Warning>();
    let _ = |f: Fidelity| match f {
        Fidelity::Degraded | Fidelity::Dropped | Fidelity::AttrsDegraded | Fidelity::AttrsDropped => (),
        _ => (),
    };
    let _ = |o: ContainerOrigin| match o {
        ContainerOrigin::Element | ContainerOrigin::Directive => (),
        _ => (),
    };
    let _ = [DirectiveForm::Text, DirectiveForm::Leaf, DirectiveForm::Container];
    let _ = [Alignment::Default, Alignment::Left, Alignment::Right, Alignment::Center];
    let _ = Span { start: 0, end: 0 };
    assert_copy::<Span>();
    assert_traits::<Span>();
    let _ = NodeId(0).0;
    assert_copy::<NodeId>();
    let _ = |n: NodeId| std::collections::HashSet::from([n]);

    // ── The authoring vocabulary ─────────────────────────────────────────
    let _ = [
        InlineKind::Strong,
        InlineKind::Emph,
        InlineKind::Verbatim,
        InlineKind::Mark,
        InlineKind::Superscript,
        InlineKind::Subscript,
        InlineKind::Insert,
        InlineKind::Delete,
    ];
    let _ = [BlockKind::Paragraph, BlockKind::Heading(1)];
    let _ = [BlockContainerKind::BlockQuote, BlockContainerKind::BulletList, BlockContainerKind::OrderedList];
    let _: fn(MarkColor) -> &'static str = MarkColor::as_str;
    let _: fn(&str) -> Option<MarkColor> = MarkColor::from_str;
    let _ = [
        MarkColor::Red,
        MarkColor::Orange,
        MarkColor::Yellow,
        MarkColor::Green,
        MarkColor::Blue,
        MarkColor::Purple,
        MarkColor::Brown,
    ];
    let _ = |g: Gesture| match g {
        Gesture::WrapRange(_)
        | Gesture::ToggleInline(_)
        | Gesture::SetBlock
        | Gesture::ToggleBlockContainer(_)
        | Gesture::InsertThematicBreak
        | Gesture::ToggleCodeBlock
        | Gesture::SetCodeLanguage
        | Gesture::ToggleTaskItem
        | Gesture::SetTaskChecked
        | Gesture::ToggleTaskChecked
        | Gesture::InsertLink
        | Gesture::InsertImage
        | Gesture::InsertFootnote
        | Gesture::InsertLiteral
        | Gesture::InsertLineBreak
        | Gesture::SplitBlock
        | Gesture::RenumberOrderedLists
        | Gesture::TableInsertRow
        | Gesture::TableDeleteRow
        | Gesture::TableInsertColumn
        | Gesture::TableDeleteColumn
        | Gesture::TableSetAlignment
        | Gesture::TableMoveRow
        | Gesture::TableMoveColumn
        | Gesture::SetMarkColor
        | Gesture::InsertTable
        | Gesture::InsertDirective
        | Gesture::SetBlockAttrs
        | Gesture::WrapRangeAttrs
        | Gesture::JoinBlocks
        | Gesture::SetNodeAttrs
        | Gesture::MoveBlock
        | Gesture::InsertInlineMath
        | Gesture::InsertDisplayMath
        | Gesture::ToggleLineBlock => (),
        _ => (),
    };
    assert_copy::<InlineKind>();
    assert_copy::<BlockKind>();
    assert_copy::<BlockContainerKind>();
    assert_copy::<MarkColor>();
    assert_copy::<Gesture>();

    // ── Version ──────────────────────────────────────────────────────────
    let _: fn() -> Version = version;
    let _: fn() -> u32 = abi_version;
    let _: fn() -> &'static str = version_string;
    let _: u32 = ABI_VERSION;
    let _ = |v: Version| -> (u8, u8, u8) { (v.major, v.minor, v.patch) };

    // ── Document ─────────────────────────────────────────────────────────
    assert_debug::<Document>();
    let _: fn(&[u8], Format) -> R<Document> = Document::parse;
    let _: fn(&str, Format) -> R<Document> = Document::parse_str;
    let _: fn(&[u8], Format, u32) -> R<Document> = Document::parse_with_flags;
    let _: fn(&[u8], Format, &[&str]) -> R<Document> = Document::parse_with_features;
    let _: fn(&mut Document) -> R<Vec<u8>> = Document::render_html;
    let _: fn(&mut Document, Target) -> R<Vec<u8>> = Document::serialize_to;
    let _: fn(&mut Document, Format) -> R<Vec<u8>> = Document::serialize;
    let _: fn(&mut Document) -> R<Vec<u8>> = Document::ast_json;
    let _: fn(&mut Document, &str) -> R<Vec<QueryMatch>> = Document::query;
    let _: fn(&mut Document, NodeId) -> R<Range<usize>> = Document::span;
    let _: fn(&mut Document, NodeId) -> R<Option<Range<usize>>> = Document::content_span;
    let _: fn(&mut Document, NodeId) -> R<Option<Range<usize>>> = Document::marker_span;
    let _: fn(&mut Document, NodeId) -> R<Option<Range<usize>>> = Document::attrs_span;
    let _: fn(&mut Document, usize) -> R<Option<Range<usize>>> = Document::line_prefix;
    let _: fn(&mut Document, usize) -> R<LinePrefix> = Document::continuation_prefix;
    let _: fn(&mut Document, usize) -> R<LinePrefix> = Document::blank_line_prefix;
    let _: fn(&mut Document, NodeId) -> R<Option<(u32, u32)>> = Document::cell_extent;
    let _: fn(&mut Document) -> R<Vec<FlatNode>> = Document::nodes;
    let _: fn(&mut Document) -> R<Vec<QueryMatch>> = Document::definitions;
    let _: fn(&mut Document, Target) -> R<Vec<Warning>> = Document::diagnostics;
    let _: fn(&mut Document, Option<NodeId>) -> R<Vec<QueryMatch>> = Document::children;
    let _: fn(&mut Document, NodeId) -> R<Vec<FlatNode>> = Document::subtree;
    let _: fn(&mut Document, usize) -> R<Option<QueryMatch>> = Document::node_at;
    let _: fn(&mut Document, usize) -> R<Vec<QueryMatch>> = Document::ancestors_at;
    let _: fn(&mut Document, usize) -> R<Option<QueryMatch>> = Document::node_at_caret;
    let _: fn(&mut Document, usize) -> R<Vec<QueryMatch>> = Document::ancestors_at_caret;
    let _ = |v: &mut DocumentView<'_>| -> R<Vec<FlatNode>> { v.nodes() };
    assert_debug::<DocumentView<'static>>();

    // ── Editor ───────────────────────────────────────────────────────────
    assert_debug::<Editor>();
    let _: fn(&[u8], Format) -> R<Editor> = Editor::new;
    let _: fn(&str, Format) -> R<Editor> = Editor::new_str;
    let _: fn(&[u8], Format, u32) -> R<Editor> = Editor::new_with_flags;
    let _: fn(&[u8], Format, &[&str]) -> R<Editor> = Editor::new_with_features;
    let _: fn(&mut Editor, &str, &str) -> R<()> = Editor::replace;
    let _: fn(&mut Editor, &str, &str) -> R<()> = Editor::replace_content;
    let _: fn(&mut Editor, &str, &str) -> R<()> = Editor::insert_before;
    let _: fn(&mut Editor, &str, &str) -> R<()> = Editor::insert_after;
    let _: fn(&mut Editor, &str, usize, &str) -> R<()> = Editor::insert_child;
    let _: fn(&mut Editor, &str) -> R<()> = Editor::delete;
    let _: fn(&mut Editor, &str) -> R<()> = Editor::delete_smart;
    let _: fn(&mut Editor, &str) -> R<()> = Editor::unwrap_node;
    let _: fn(&mut Editor, &str, &str) -> R<()> = Editor::move_before;
    let _: fn(&mut Editor, &str, &str) -> R<()> = Editor::move_after;
    let _: fn(&mut Editor, &str, Option<&str>, bool) -> R<()> = Editor::filter;
    let _: fn(&mut Editor) -> R<Vec<u8>> = Editor::source;
    let _: fn(&mut Editor) -> R<String> = Editor::source_str;
    let _: fn(&mut Editor) -> R<Vec<u8>> = Editor::ast_json;
    let _: fn(&mut Editor, &str) -> R<Vec<QueryMatch>> = Editor::query;
    let _: fn(&mut Editor, usize, usize, &str) -> R<Change> = Editor::edit_range;
    let _: fn(&mut Editor) -> Option<Change> = Editor::last_change;
    let _: fn(&mut Editor) -> R<Option<Change>> = Editor::undo;
    let _: fn(&mut Editor) -> R<Option<Change>> = Editor::redo;
    let _: fn(&mut Editor) -> R<()> = Editor::coalesce_last_undo;
    let _: fn(&mut Editor) -> u64 = Editor::revision;
    let _: fn(&mut Editor) -> Option<Range<usize>> = Editor::dirty_range;
    let _: fn(&mut Editor) = Editor::clear_dirty;
    let _: fn(&mut Editor, &[u8]) -> R<()> = Editor::set_caret_blob;
    let _: fn(&mut Editor) -> R<Vec<u8>> = Editor::caret_blob;
    let _: for<'a> fn(&'a mut Editor) -> R<DocumentView<'a>> = Editor::document;
    let _: fn(&mut Editor) -> R<Vec<FlatNode>> = Editor::nodes;
    let _: fn(&mut Editor, Option<NodeId>) -> R<Vec<QueryMatch>> = Editor::child_spans;
    let _: fn(&mut Editor, NodeId) -> R<Vec<FlatNode>> = Editor::subtree;
    let _: fn(&mut Editor, usize) -> R<Option<QueryMatch>> = Editor::node_at;
    let _: fn(&mut Editor, usize) -> R<Vec<QueryMatch>> = Editor::ancestors_at;
    let _: fn(&mut Editor, usize, usize, InlineKind) -> R<Change> = Editor::wrap_range;
    let _: fn(&mut Editor, usize, usize, InlineKind) -> R<Change> = Editor::toggle_inline;
    let _: fn(&mut Editor, usize, Option<MarkColor>) -> R<Change> = Editor::set_mark_color;
    let _: fn(&mut Editor, usize, BlockKind) -> R<Change> = Editor::set_block;
    let _: fn(&mut Editor, usize, usize, BlockContainerKind) -> R<Change> = Editor::toggle_block_container;
    let _: fn(&mut Editor, usize) -> R<()> = Editor::renumber_ordered_lists;
    let _: fn(&mut Editor, usize, bool) -> R<()> = Editor::table_insert_row;
    let _: fn(&mut Editor, usize) -> R<()> = Editor::table_delete_row;
    let _: fn(&mut Editor, usize, bool) -> R<()> = Editor::table_insert_column;
    let _: fn(&mut Editor, usize) -> R<()> = Editor::table_delete_column;
    let _: fn(&mut Editor, usize, Alignment) -> R<()> = Editor::table_set_alignment;
    let _: fn(&mut Editor, usize, bool) -> R<()> = Editor::table_move_row;
    let _: fn(&mut Editor, usize, bool) -> R<()> = Editor::table_move_column;
    let _: fn(&mut Editor, usize, usize, usize) -> R<Change> = Editor::insert_table;
    let _: for<'a> fn(&mut Editor, usize, &str, Option<&str>, Attrs<'a>) -> R<Change> = Editor::insert_directive;
    let _: for<'a> fn(&mut Editor, usize, Attrs<'a>) -> R<Change> = Editor::set_block_attrs;
    let _: for<'a> fn(&mut Editor, NodeId, Attrs<'a>) -> R<Change> = Editor::set_node_attrs;
    let _: for<'a> fn(&mut Editor, usize, usize, Attrs<'a>) -> R<Change> = Editor::wrap_range_attrs;
    let _: fn(&mut Editor, usize, usize, &str) -> R<Change> = Editor::insert_link;
    let _: fn(&mut Editor, usize, usize, &str) -> R<Change> = Editor::insert_image;
    let _: fn(&mut Editor, usize, &str) -> R<Change> = Editor::insert_literal;
    let _: fn(&mut Editor, usize) -> R<Change> = Editor::insert_line_break;
    let _: fn(&mut Editor, usize) -> R<Change> = Editor::insert_thematic_break;
    let _: fn(&mut Editor, usize) -> R<Change> = Editor::split_block;
    let _: fn(&mut Editor, usize) -> R<Change> = Editor::join_blocks;
    let _: fn(&mut Editor, usize, usize) -> R<Change> = Editor::move_block;
    let _: fn(&mut Editor, usize, usize, Option<&str>) -> R<Change> = Editor::toggle_code_block;
    let _: fn(&mut Editor, usize, Option<&str>) -> R<Change> = Editor::set_code_language;
    let _: fn(&mut Editor, usize) -> R<Change> = Editor::toggle_task_item;
    let _: fn(&mut Editor, usize, bool) -> R<()> = Editor::set_task_checked;
    let _: fn(&mut Editor, usize) -> R<Change> = Editor::toggle_task_checked;
    let _: fn(&mut Editor, usize, &str) -> R<Change> = Editor::insert_footnote;
    let _: fn(&mut Editor, usize, &str) -> R<Change> = Editor::insert_inline_math;
    let _: fn(&mut Editor, usize, &str) -> R<Change> = Editor::insert_display_math;
    let _: fn(&mut Editor, usize, usize) -> R<Change> = Editor::toggle_line_block;

    // ── Builder ──────────────────────────────────────────────────────────
    assert_debug::<Builder>();
    let _: fn() -> R<Builder> = Builder::new;
    let _: fn(&mut Builder, VoidKind) -> R<NodeId> = Builder::add;
    let _: fn(&mut Builder, TextKind, &str) -> R<NodeId> = Builder::add_text;
    let _: fn(&mut Builder, u32) -> R<NodeId> = Builder::add_heading;
    let _: fn(&mut Builder, Option<&str>, &str) -> R<NodeId> = Builder::add_code_block;
    let _: fn(&mut Builder, &str, &str) -> R<NodeId> = Builder::add_raw_block;
    let _: fn(&mut Builder, &str, &str) -> R<NodeId> = Builder::add_metadata;
    let _: fn(&mut Builder, &str, &str) -> R<NodeId> = Builder::add_raw_inline;
    let _: fn(&mut Builder, SmartPunctuation, &str) -> R<NodeId> = Builder::add_smart_punctuation;
    let _: fn(&mut Builder, Option<&str>, Option<&str>) -> R<NodeId> = Builder::add_link;
    let _: fn(&mut Builder, Option<&str>, Option<&str>) -> R<NodeId> = Builder::add_image;
    let _: fn(&mut Builder, DirectiveForm, &str) -> R<NodeId> = Builder::add_directive;
    let _: fn(&mut Builder, &str) -> R<NodeId> = Builder::add_element;
    let _: fn(&mut Builder, &str, &str) -> R<NodeId> = Builder::add_processing_instruction;
    let _: fn(&mut Builder, &str) -> R<NodeId> = Builder::add_footnote;
    let _: fn(&mut Builder, &str) -> R<NodeId> = Builder::add_citation;
    let _: fn(&mut Builder, &str) -> R<NodeId> = Builder::add_substitution;
    let _: fn(&mut Builder, &str, &str) -> R<NodeId> = Builder::add_reference;
    let _: fn(&mut Builder, BulletStyle, bool) -> R<NodeId> = Builder::add_bullet_list;
    let _: fn(&mut Builder, OrderedNumbering, OrderedDelim, bool, Option<u32>) -> R<NodeId> = Builder::add_ordered_list;
    let _: fn(&mut Builder, bool) -> R<NodeId> = Builder::add_task_list;
    let _: fn(&mut Builder, bool) -> R<NodeId> = Builder::add_task_list_item;
    let _: fn(&mut Builder, bool) -> R<NodeId> = Builder::add_row;
    let _: fn(&mut Builder, bool, Alignment) -> R<NodeId> = Builder::add_cell;
    let _: fn(&mut Builder, bool, Alignment, u32, u32) -> R<NodeId> = Builder::add_cell_spanning;
    let _: fn(&mut Builder, NodeId, &[NodeId]) -> R<()> = Builder::set_children;
    let _: for<'a> fn(&mut Builder, NodeId, Attrs<'a>) -> R<()> = Builder::set_attrs;
    let _: fn(&mut Builder, NodeId) -> R<Vec<u8>> = Builder::render_html;
    let _: fn(&mut Builder, NodeId, Target) -> R<Vec<u8>> = Builder::serialize_to;
    let _: fn(&mut Builder, NodeId, Format) -> R<Vec<u8>> = Builder::serialize;
    let _: fn(&mut Builder, NodeId) -> R<Vec<u8>> = Builder::ast_json;
    let _: fn(&mut Builder, NodeId, &str) -> R<Vec<QueryMatch>> = Builder::query;
    let _ = [
        VoidKind::Doc,
        VoidKind::Para,
        VoidKind::ThematicBreak,
        VoidKind::Section,
        VoidKind::Div,
        VoidKind::BlockQuote,
        VoidKind::DefinitionList,
        VoidKind::Table,
        VoidKind::ListItem,
        VoidKind::DefinitionListItem,
        VoidKind::Term,
        VoidKind::Definition,
        VoidKind::Caption,
        VoidKind::SoftBreak,
        VoidKind::HardBreak,
        VoidKind::NonBreakingSpace,
        VoidKind::Emph,
        VoidKind::Strong,
        VoidKind::Span,
        VoidKind::Mark,
        VoidKind::Superscript,
        VoidKind::Subscript,
        VoidKind::Insert,
        VoidKind::Delete,
        VoidKind::DoubleQuoted,
        VoidKind::SingleQuoted,
    ];
    let _ = [
        TextKind::Str,
        TextKind::Symb,
        TextKind::Verbatim,
        TextKind::InlineMath,
        TextKind::DisplayMath,
        TextKind::Url,
        TextKind::Email,
        TextKind::FootnoteReference,
        TextKind::CitationReference,
        TextKind::SubstitutionReference,
        TextKind::Comment,
        TextKind::Doctype,
        TextKind::Cdata,
    ];
    let _ = [BulletStyle::Dash, BulletStyle::Plus, BulletStyle::Star];
    let _ = [
        OrderedNumbering::Decimal,
        OrderedNumbering::LowerAlpha,
        OrderedNumbering::UpperAlpha,
        OrderedNumbering::LowerRoman,
        OrderedNumbering::UpperRoman,
    ];
    let _ = [OrderedDelim::Period, OrderedDelim::ParenAfter, OrderedDelim::ParenBoth];
    let _ = [
        SmartPunctuation::LeftSingleQuote,
        SmartPunctuation::RightSingleQuote,
        SmartPunctuation::LeftDoubleQuote,
        SmartPunctuation::RightDoubleQuote,
        SmartPunctuation::Ellipses,
        SmartPunctuation::EmDash,
        SmartPunctuation::EnDash,
    ];

    // ── Error: the binding's variants, all of them ───────────────────────
    let _ = |e: Error| match e {
        Error::InvalidArgument
        | Error::ParseError
        | Error::OutOfMemory
        | Error::UnsupportedFormat
        | Error::NotFound
        | Error::Ambiguous
        | Error::NotEditable
        | Error::EditConflict
        | Error::UnsafeMetadata
        | Error::InvalidLanguage
        | Error::Internal => (),
        _ => (),
    };
    let _ = |e: Error| -> Box<dyn std::error::Error> { Box::new(e) };
}

