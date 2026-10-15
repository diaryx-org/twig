//! The authoring gestures' tests — port of `src/ast/editor_test.zig`, the
//! spec for the editor.
//!
//! Mostly they check THE REPARSED TREE, not the source bytes: source that
//! merely looks right can still have ended a link early. Djot and Markdown
//! both, nearly everywhere, because their spans differ in exactly the places
//! these gestures read them.

#![allow(clippy::bool_assert_comparison)]

use super::*;
use crate::format::{self, Format, ParseConfig};
use crate::languages::markdown::Extensions;
use crate::ast::MarkupLeafKind;

fn highlight_cfg() -> ParseConfig {
    ParseConfig { markdown: Extensions { highlight: true, ..Default::default() }, ..Default::default() }
}
fn highlight_colors_cfg() -> ParseConfig {
    ParseConfig {
        markdown: Extensions { highlight: true, highlight_colors: true, ..Default::default() },
        ..Default::default()
    }
}
fn directives_cfg() -> ParseConfig {
    ParseConfig { markdown: Extensions { directives: true, ..Default::default() }, ..Default::default() }
}
fn html_elements_cfg() -> ParseConfig {
    ParseConfig { markdown: Extensions { html_elements: true, ..Default::default() }, ..Default::default() }
}
fn math_cfg() -> ParseConfig {
    ParseConfig { markdown: Extensions { math: true, ..Default::default() }, ..Default::default() }
}

struct Fixture {
    ed: Editor,
}

fn mk(source: impl AsRef<[u8]>, fmt: Format) -> Fixture {
    mk_with(source, fmt, ParseConfig::default())
}

/// A document parsed with `cfg`, the spelling from `syntax_for_config` — the
/// same pairing a C caller gets.
fn mk_with(source: impl AsRef<[u8]>, fmt: Format, cfg: ParseConfig) -> Fixture {
    let syntax = format::syntax_for_config(fmt, &cfg);
    let parse: ParseFn =
        Box::new(move |s: &[u8]| format::parse_to_ast(fmt, &cfg, s).map_err(|e| ParseError::new(e.name())));
    Fixture { ed: Editor::new(source.as_ref(), parse, syntax).unwrap() }
}

#[track_caller]
fn eq_str(a: impl AsRef<[u8]>, b: impl AsRef<[u8]>) {
    assert_eq!(String::from_utf8_lossy(a.as_ref()), String::from_utf8_lossy(b.as_ref()));
}

impl Fixture {
    #[track_caller]
    fn expect(&self, expected: &str) {
        eq_str(expected, self.ed.source_bytes());
    }

    fn src(&self) -> &[u8] {
        self.ed.source_bytes()
    }

    fn ast(&self) -> &Ast {
        self.ed.ast_view()
    }

    fn kind(&self, id: NodeId) -> &Kind {
        self.ed.ast_view().kind(id)
    }

    /// The first node of `kind` in the reparsed tree.
    fn find(&self, kind: KindRef) -> Option<NodeId> {
        self.ed.ast_view().nodes.iter().find(|n| kind.matches(&n.kind)).map(|n| n.id)
    }

    fn count(&self, kind: KindRef) -> usize {
        self.ed.ast_view().nodes.iter().filter(|n| kind.matches(&n.kind)).count()
    }

    /// The destination the parser reads back out of the EDITED source.
    #[track_caller]
    fn expect_link_dest(&self, expected: &str) {
        let id = self.find(KindRef::Tag(Tag::Link)).expect("NoLink");
        let Kind::Link(l) = self.kind(id) else { unreachable!() };
        eq_str(expected, l.destination.as_ref().expect("NoDestination"));
    }

    /// The reparsed KIND with its payload.
    #[track_caller]
    fn expect_spelled(&self, kind: KindRef, payload: &str) {
        let id = self.find(kind).expect("KindNotFound");
        let got: &[u8] = match self.kind(id) {
            Kind::Link(l) | Kind::Image(l) => l.destination.as_deref().expect("NoPayload"),
            Kind::Str(t) => t,
            Kind::TextLeaf { text, .. } => text,
            _ => panic!("NoPayload"),
        };
        eq_str(payload, got);
    }

    #[track_caller]
    fn expect_no_node_of_kind(&self, kind: KindRef) {
        assert!(self.find(kind).is_none(), "UnexpectedKind");
    }

    /// The destination read back off whichever node the op chose to spell.
    #[track_caller]
    fn expect_dest_round_trip(&self, expected: &str) {
        for n in &self.ast().nodes {
            let got: &[u8] = match &n.kind {
                Kind::Link(l) => l.destination.as_deref().expect("NoDestination"),
                Kind::TextLeaf { text, .. } => text,
                _ => continue,
            };
            eq_str(expected, got);
            return;
        }
        panic!("NoLinkOfAnyKind");
    }

    /// A `link`'s VISIBLE text: its `str` children joined.
    #[track_caller]
    fn expect_link_text(&self, expected: &str) {
        let link = self.find(KindRef::Tag(Tag::Link)).expect("NoLink");
        let mut buf = Vec::new();
        for child in self.ast().children(link) {
            match &child.kind {
                Kind::Str(s) => buf.extend_from_slice(s),
                _ => panic!("TextNotLiteral"),
            }
        }
        eq_str(expected, buf);
    }
}

fn toggle_container(fx: &mut Fixture, start: usize, end: usize, kind: ContainerKind) -> R {
    fx.ed.toggle_block_container(Span::new(start, end), kind)
}

fn insert_link(fx: &mut Fixture, start: usize, end: usize, dest: impl AsRef<[u8]>) -> R {
    fx.ed.insert_link(Span::new(start, end), dest.as_ref())
}

fn insert_image(fx: &mut Fixture, start: usize, end: usize, dest: impl AsRef<[u8]>) -> R {
    fx.ed.insert_image(Span::new(start, end), dest.as_ref())
}

fn insert_literal(fx: &mut Fixture, offset: usize, text: impl AsRef<[u8]>) -> R {
    fx.ed.insert_literal(offset, text.as_ref())
}

/// The document's VISIBLE text: every `str` payload joined, in node order.
#[track_caller]
fn expect_visible_text(fx: &Fixture, expected: impl AsRef<[u8]>) {
    let mut buf = Vec::new();
    for n in &fx.ast().nodes {
        if let Kind::Str(s) = &n.kind {
            buf.extend_from_slice(s);
        }
    }
    eq_str(expected, buf);
}

/// Field access on a `Kind`, as the Zig tests spell it (`kind.code_block.text`).
trait KindFields {
    fn code_block_text(&self) -> &[u8];
    fn code_block_lang(&self) -> Option<&[u8]>;
    fn bullet_list_tight(&self) -> bool;
    fn ordered_list_tight(&self) -> bool;
    fn heading_level(&self) -> u32;
    fn row_head(&self) -> bool;
    fn container_form(&self) -> Option<Form>;
    fn container_name(&self) -> &[u8];
    fn str_(&self) -> &[u8];
    fn text_leaf_text(&self) -> &[u8];
    fn footnote_label(&self) -> &[u8];
    fn task_list_item_checked(&self) -> bool;
    fn line_indent(&self) -> u32;
}

impl KindFields for Kind {
    fn code_block_text(&self) -> &[u8] {
        match self { Kind::CodeBlock { text, .. } => text, k => panic!("not a code_block: {k:?}") }
    }
    fn code_block_lang(&self) -> Option<&[u8]> {
        match self { Kind::CodeBlock { lang, .. } => lang.as_deref(), k => panic!("not a code_block: {k:?}") }
    }
    fn bullet_list_tight(&self) -> bool {
        match self { Kind::BulletList { tight } => *tight, k => panic!("not a bullet_list: {k:?}") }
    }
    fn ordered_list_tight(&self) -> bool {
        match self { Kind::OrderedList { tight, .. } => *tight, k => panic!("not an ordered_list: {k:?}") }
    }
    fn heading_level(&self) -> u32 {
        match self { Kind::Heading { level } => *level, k => panic!("not a heading: {k:?}") }
    }
    fn row_head(&self) -> bool {
        match self { Kind::Row { head } => *head, k => panic!("not a row: {k:?}") }
    }
    fn container_form(&self) -> Option<Form> {
        match self { Kind::Container(c) => c.form, k => panic!("not a container: {k:?}") }
    }
    fn container_name(&self) -> &[u8] {
        match self { Kind::Container(c) => &c.name, k => panic!("not a container: {k:?}") }
    }
    fn str_(&self) -> &[u8] {
        match self { Kind::Str(t) => t, k => panic!("not a str: {k:?}") }
    }
    fn text_leaf_text(&self) -> &[u8] {
        match self { Kind::TextLeaf { text, .. } => text, k => panic!("not a text_leaf: {k:?}") }
    }
    fn footnote_label(&self) -> &[u8] {
        match self { Kind::Footnote { label } => label, k => panic!("not a footnote: {k:?}") }
    }
    fn task_list_item_checked(&self) -> bool {
        match self { Kind::TaskListItem { checked } => *checked, k => panic!("not a task_list_item: {k:?}") }
    }
    fn line_indent(&self) -> u32 {
        match self { Kind::Line { indent } => *indent, k => panic!("not a line: {k:?}") }
    }
}

fn kv(key: &str, value: &str) -> KeyVal {
    KeyVal::new(key.as_bytes(), Some(value.as_bytes()))
}

fn find_sub(hay: impl AsRef<[u8]>, needle: impl AsRef<[u8]>) -> Option<usize> {
    let (hay, needle) = (hay.as_ref(), needle.as_ref());
    hay.windows(needle.len()).position(|w| w == needle)
}


/// The `data-color` of the first `mark` in the reparsed tree.
fn mark_color(fx: &Fixture) -> Option<Vec<u8>> {
    let id = fx.find(KindRef::Mark(InlineMark::Mark))?;
    fx.ast().attrs_of(id).get(b"data-color").map(|v| v.to_vec())
}

/// A container named `name`, or one carrying it as a class (djot's anonymous
/// fence, AsciiDoc's open block).
#[track_caller]
fn expect_container_carrying(fx: &Fixture, name: &str) {
    let ast = fx.ast();
    for n in &ast.nodes {
        let Kind::Container(c) = &n.kind else { continue };
        if c.name == name.as_bytes() {
            return;
        }
        let Some(class) = ast.attrs_of(n.id).get(b"class") else { continue };
        if find_sub(class, name.as_bytes()).is_some() {
            return;
        }
    }
    panic!("NoContainerCarrying {name}");
}

#[track_caller]
fn expect_code_lang(fx: &Fixture, expected: Option<&str>) {
    let id = fx.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
    let Kind::CodeBlock { lang, .. } = fx.kind(id) else { unreachable!() };
    match expected {
        Some(want) => eq_str(want, lang.as_ref().expect("NoLang")),
        None => assert!(lang.as_ref().is_none_or(|l| l.is_empty())),
    }
}

#[track_caller]
fn expect_code_within(fx: &Fixture, tag: Tag, text: Option<&str>) {
    let ast = fx.ast();
    let cb = fx.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
    if let Some(t) = text {
        let Kind::CodeBlock { text: body, .. } = ast.kind(cb) else { unreachable!() };
        eq_str(t, body);
    }
    let doc = fx.ed.doc();
    let inner = doc.span(cb);
    for n in &ast.nodes[..cb as usize] {
        if n.kind.tag() != tag {
            continue;
        }
        let outer = doc.span(n.id);
        if outer.start <= inner.start && inner.end <= outer.end {
            return;
        }
    }
    panic!("CodeBlockOutsideContainer");
}

#[track_caller]
fn expect_code_round_trip(fmt: Format, source: &str, on: usize, fenced: &str, within: Tag, text: Option<&str>, off: usize) {
    let mut fx = mk(source, fmt);
    fx.ed.toggle_code_block(Span::new(on, on), None).unwrap();
    fx.expect(fenced);
    expect_code_within(&fx, within, text);
    fx.ed.toggle_code_block(Span::new(off, off), None).unwrap();
    fx.expect(source);
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
    fx.ed.splicer.undo().unwrap();
    fx.expect(fenced);
    fx.ed.splicer.undo().unwrap();
    fx.expect(source);
}

#[track_caller]
fn expect_task_checked(fx: &Fixture, expected: bool) {
    let id = fx.find(KindRef::Tag(Tag::TaskListItem)).expect("NoTaskItem");
    let Kind::TaskListItem { checked } = fx.kind(id) else { unreachable!() };
    assert_eq!(expected, *checked);
}

#[track_caller]
fn expect_formula(fx: &Fixture, kind: TextLeafKind, formula: &str) {
    let id = fx.find(KindRef::TextLeaf(kind)).expect("NoFormula");
    let Kind::TextLeaf { text, .. } = fx.kind(id) else { unreachable!() };
    eq_str(formula, text);
}

fn minimal_source(fmt: Format) -> &'static str {
    match fmt {
        Format::Xml | Format::Svg | Format::Html => "<r>ab</r>",
        _ => "ab\n",
    }
}

fn run_gesture(ed: &mut Editor, g: Gesture) -> R {
    let whole = Span::new(0, ed.source_bytes().len());
    use Gesture::*;
    match g {
        WrapRange(k) => ed.wrap_range(whole, k),
        ToggleInline(k) => ed.toggle_inline(whole, k),
        SetMarkColor => ed.set_mark_color(0, Some(b"red")),
        SetBlock => ed.set_block(0, BlockKind::Heading, 1),
        ToggleBlockContainer(k) => ed.toggle_block_container(whole, k),
        InsertThematicBreak => ed.insert_thematic_break(0),
        ToggleCodeBlock => ed.toggle_code_block(whole, None),
        SetCodeLanguage => ed.set_code_language(0, None),
        ToggleTaskItem => ed.toggle_task_item(0),
        SetTaskChecked => ed.set_task_checked(0, true),
        ToggleTaskChecked => ed.toggle_task_checked(0),
        InsertLink => ed.insert_link(whole, b"https://example.com"),
        InsertImage => ed.insert_image(whole, b"https://example.com/a.png"),
        InsertFootnote => ed.insert_footnote(0, b"n"),
        InsertLiteral => ed.insert_literal(0, b"x"),
        InsertLineBreak => ed.insert_line_break(0),
        SplitBlock => ed.split_block(0),
        JoinBlocks => ed.join_blocks(0),
        RenumberOrderedLists => ed.renumber_ordered_lists(0),
        TableInsertRow => ed.table_insert_row(0, true),
        TableDeleteRow => ed.table_delete_row(0),
        TableInsertColumn => ed.table_insert_column(0, true),
        TableDeleteColumn => ed.table_delete_column(0),
        TableSetAlignment => ed.table_set_alignment(0, Alignment::Center),
        TableMoveRow => ed.table_move_row(0, true),
        TableMoveColumn => ed.table_move_column(0, true),
        InsertTable => ed.insert_table(0, 1, 1),
        InsertDirective => ed.insert_directive(0, b"page-break", None, &[]),
        SetBlockAttrs => ed.set_block_attrs(0, &[kv("class", "c")]),
        WrapRangeAttrs => ed.wrap_range_attrs(whole, &[kv("class", "c")]),
        SetNodeAttrs => ed.set_node_attrs(0, &[kv("class", "c")]),
        MoveBlock => {
            let end = ed.source_bytes().len();
            ed.move_block(0, end)
        }
        InsertInlineMath => ed.insert_inline_math(0, b"x"),
        InsertDisplayMath => ed.insert_display_math(0, b"x"),
        ToggleLineBlock => ed.toggle_line_block(0, 0),
    }
}

fn find_line_block(fx: &Fixture) -> Option<NodeId> {
    fx.find(KindRef::Tag(Tag::LineBlock))
}

// ── inline marks ───────────────────────────────────────────────────────────

#[test]
fn toggleinline_bold_on_then_off_round_trips_in_both_formats() {
    // The delimiters differ (`**` vs `*`) — the whole reason the table exists.
    let mut md = mk("a word b\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(2, 6), InlineKind::Strong).unwrap();
    md.expect("a **word** b\n");
    md.ed.toggle_inline(Span::new(4, 8), InlineKind::Strong).unwrap();
    md.expect("a word b\n");

    let mut dj = mk("a word b\n", Format::Djot);
    dj.ed.toggle_inline(Span::new(2, 6), InlineKind::Strong).unwrap();
    dj.expect("a *word* b\n");
    dj.ed.toggle_inline(Span::new(3, 7), InlineKind::Strong).unwrap();
    dj.expect("a word b\n");
}

#[test]
fn toggleinline_a_selection_that_reaches_into_a_mark_s_delimiters_is_still_that_mark() {
    // A rich view draws no delimiters, so a drag that ends after the `d` of
    // `**bold**` ends before its closing `**` or after it — both are the
    // bold, and the second used to be wrapped again as `****bold****`.
    let mut md = mk("**bold** plain\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(2, 8), InlineKind::Strong).unwrap();
    md.expect("bold plain\n");

    let mut md2 = mk("**bold** plain\n", Format::Markdown);
    md2.ed.toggle_inline(Span::new(0, 6), InlineKind::Strong).unwrap();
    md2.expect("bold plain\n");

    // Short of the interior is not the mark: `bol` alone is a new selection.
    let mut md3 = mk("**bold** plain\n", Format::Markdown);
    md3.ed.toggle_inline(Span::new(2, 5), InlineKind::Strong).unwrap();
    md3.expect("****bol**d** plain\n");
}

#[test]
fn toggleinline_bold_over_emphasis_toggles_off_again_from_the_whole_span() {
    // `***word***` is an emph whose whole interior is a strong. The second
    // press over the same span is the strong coming off, not a third pair.
    let mut md = mk("*word*\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(0, 6), InlineKind::Strong).unwrap();
    md.expect("***word***\n");
    md.ed.toggle_inline(Span::new(0, 10), InlineKind::Strong).unwrap();
    md.expect("*word*\n");
    // The same from the interior alone, and from the strong's own span.
    md.ed.toggle_inline(Span::new(1, 5), InlineKind::Strong).unwrap();
    md.expect("***word***\n");
    md.ed.toggle_inline(Span::new(1, 9), InlineKind::Strong).unwrap();
    md.expect("*word*\n");
}

#[test]
fn toggleinline_a_whole_paragraph_that_is_one_mark_is_that_mark() {
    let mut md = mk("**bold**\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(0, 8), InlineKind::Strong).unwrap();
    md.expect("bold\n");
}

#[test]
fn toggleinline_a_selection_inside_a_code_span_marks_the_whole_code_span() {
    // `**` inside the backticks is code; the mark closes around them, and
    // comes off again from the span it left selected.
    let mut md = mk("a `word` b\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(3, 7), InlineKind::Strong).unwrap();
    md.expect("a **`word`** b\n");
    md.ed.toggle_inline(Span::new(2, 12), InlineKind::Strong).unwrap();
    md.expect("a `word` b\n");
    // A selection that cuts into the code span from outside takes it whole.
    md.ed.toggle_inline(Span::new(0, 4), InlineKind::Emph).unwrap();
    md.expect("*a `word`* b\n");
    // Toggling code itself from inside the span strips it.
    let mut md2 = mk("a `word` b\n", Format::Markdown);
    md2.ed.toggle_inline(Span::new(3, 7), InlineKind::Verbatim).unwrap();
    md2.expect("a word b\n");
}

#[test]
fn toggleinline_a_kind_the_format_can_t_spell_is_refused_not_mis_spelled() {
    // Djot spells `{=mark=}`; Markdown has no mark at all. This is the raggedness
    // `Syntax`'s optional table exists to carry.
    let mut dj = mk("a word b\n", Format::Djot);
    dj.ed.toggle_inline(Span::new(2, 6), InlineKind::Mark).unwrap();
    dj.expect("a {=word=} b\n");

    let mut md = mk("a word b\n", Format::Markdown);
    assert_eq!(md.ed.toggle_inline(Span::new(2, 6), InlineKind::Mark), Err(Error::UnsupportedFormat));
    md.expect("a word b\n");
}

#[test]
fn toggleinline_underline_is_u_in_markdown_authorable_only_under_html_elements() {
    // Only `html_elements` pairs `<u>…</u>` back into an `insert`; without it
    // the tags reparse as two raw inlines, so the gesture is refused.
    let mut plain = mk("a word b\n", Format::Markdown);
    assert_eq!(plain.ed.toggle_inline(Span::new(2, 6), InlineKind::Insert), Err(Error::UnsupportedFormat));
    plain.expect("a word b\n");

    let mut fx = mk_with("a word b\n", Format::Markdown, html_elements_cfg());
    fx.ed.toggle_inline(Span::new(2, 6), InlineKind::Insert).unwrap();
    fx.expect("a <u>word</u> b\n");
    fx.ed.toggle_inline(Span::new(5, 9), InlineKind::Insert).unwrap();
    fx.expect("a word b\n");
}

#[test]
fn toggleinline_a_parse_only_format_spells_no_inline_mark_at_all() {
    let mut fx = mk("<r>ab</r>", Format::Xml);
    assert_eq!(fx.ed.toggle_inline(Span::new(3, 5), InlineKind::Strong), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.wrap_range(Span::new(3, 5), InlineKind::Emph), Err(Error::UnsupportedFormat));
}

#[test]
fn toggleinline_html_spells_a_mark_as_a_tag_pair() {
    // A `Delims` is a tag pair, so the same gesture that writes `**` writes
    // `<strong>` — no HTML-specific code path anywhere. The assertion is on the
    // reparsed KIND, not just the bytes: it is what proves the toggle reverses.
    let mut fx = mk("<p>a word b</p>\n", Format::Html);
    fx.ed.toggle_inline(Span::new(5, 9), InlineKind::Strong).unwrap();
    fx.expect("<p>a <strong>word</strong> b</p>\n");
    assert!(fx.find(KindRef::Mark(InlineMark::Strong)).is_some());

    // Off again, selecting the interior the reparse now reports.
    fx.ed.toggle_inline(Span::new(13, 17), InlineKind::Strong).unwrap();
    fx.expect("<p>a word b</p>\n");
    assert!(fx.find(KindRef::Mark(InlineMark::Strong)).is_none());
}

#[test]
fn toggleinline_html_toggles_an_alias_tag_off_and_normalizes_on_the_way_back() {
    // `<b>` parses as `strong` but is not what the table spells. Stripping still
    // works, because `Splicer.toggleInline` recovers the interior from the
    // parser's `content_span` rather than by matching the table's bytes — so an
    // alias needs no entry. The visible consequence is the normalization: what
    // comes back is `<strong>`, not the `<b>` that was there.
    let mut fx = mk("<p><b>word</b></p>\n", Format::Html);
    fx.ed.toggle_inline(Span::new(6, 10), InlineKind::Strong).unwrap();
    fx.expect("<p>word</p>\n");
    fx.ed.toggle_inline(Span::new(3, 7), InlineKind::Strong).unwrap();
    fx.expect("<p><strong>word</strong></p>\n");
}

#[test]
fn toggleinline_html_spells_every_kind_the_toolbar_vocabulary_names() {
    // `verbatim` is the text leaf in the vocabulary; `<code>` upgrades only when
    // the element holds one text child, which is what a wrap produces.
    let mut fx = mk("<p>a x b</p>\n", Format::Html);
    fx.ed.toggle_inline(Span::new(5, 6), InlineKind::Verbatim).unwrap();
    fx.expect("<p>a <code>x</code> b</p>\n");
    assert!(fx.find(KindRef::TextLeaf(TextLeafKind::Verbatim)).is_some());

    // Unlike Markdown — which refuses five of the eight — HTML spells all of
    // them, so no toolbar button is dark. (The two quote containers it cannot
    // spell are not in this vocabulary: the parser produces them, no gesture
    // does. See `html/syntax.zig`.)
    for k in InlineKind::ALL {
        let mut one = mk("<p>a x b</p>\n", Format::Html);
        one.ed.wrap_range(Span::new(5, 6), k).unwrap();
    }
}

#[test]
fn toggleinline_html_s_raggedness_stops_at_what_has_no_native_spelling() {
    // The gestures whose construct HTML has no element for (a task box is a
    // form control, a footnote is a convention). All refused through the one
    // uniform path, none of them with a hand-written HTML arm. A heading, a
    // literal, the containers, the code block and the link used to be on this
    // list; they go through the renderers now — see the `… html` tests of
    // each gesture.
    let mut fx = mk("<p>ab</p>\n", Format::Html);
    assert_eq!(fx.ed.toggle_task_item(3), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.insert_footnote(3, b"a"), Err(Error::UnsupportedFormat));
    fx.expect("<p>ab</p>\n");
}

#[test]
fn wraprange_always_adds_even_over_an_existing_mark() {
    let mut fx = mk("a *word* b\n", Format::Djot);
    fx.ed.wrap_range(Span::new(3, 7), InlineKind::Emph).unwrap();
    fx.expect("a *_word_* b\n");
}

// ── inline marks across block boundaries ───────────────────────────────────

#[test]
fn toggleinline_a_range_crossing_a_blank_line_marks_each_block_not_the_gap() {
    // The bug this replaced: one pair around the whole range put the opener in
    // the first paragraph and the closer in the second, which reparses fine —
    // as two paragraphs carrying four literal asterisks and no mark at all.
    let mut md = mk("one two\n\nthree four\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(0, 19), InlineKind::Strong).unwrap();
    md.expect("**one two**\n\n**three four**\n");

    // Two marks, not one — and the pin is the reparsed tree, because the point
    // is what the parser reads back rather than what the bytes look like.
    let mut strongs: usize = 0;
    for n in &md.ed.ast_view().nodes {
        if KindRef::Mark(InlineMark::Strong).matches(&n.kind) { strongs += 1; }
    }
    assert_eq!(2usize, strongs);

    // And the second press removes BOTH, because each piece is decided on its
    // own: it finds a mark around each and strips it, rather than nesting a
    // second pair around the first.
    md.ed.toggle_inline(Span::new(0, 27), InlineKind::Strong).unwrap();
    md.expect("one two\n\nthree four\n");
}

#[test]
fn toggleinline_djot_cuts_at_the_same_boundaries_with_its_own_delimiters() {
    let mut dj = mk("one two\n\nthree four\n", Format::Djot);
    dj.ed.toggle_inline(Span::new(0, 19), InlineKind::Emph).unwrap();
    dj.expect("_one two_\n\n_three four_\n");
    dj.ed.toggle_inline(Span::new(0, 23), InlineKind::Emph).unwrap();
    dj.expect("one two\n\nthree four\n");
}

#[test]
fn toggleinline_each_list_item_is_its_own_block_and_its_marker_is_not_in_it() {
    // The bytes between the pieces — the newline and the next item's `- ` — are
    // copied through untouched, which is what keeps this a list rather than one
    // paragraph with a stray bullet in the middle of a bold run.
    let mut md = mk("- alpha\n- beta\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(2, 14), InlineKind::Strong).unwrap();
    md.expect("- **alpha**\n- **beta**\n");
    assert!(md.find(KindRef::Tag(Tag::BulletList)).is_some());
}

#[test]
fn toggleinline_out_of_a_quote_and_into_the_paragraph_after_it() {
    // Djot and Markdown disagree about where a quoted block STARTS (Djot at its
    // text, Markdown at column zero), which is exactly the kind of span
    // difference a rule derived from one format gets wrong on the other. Both
    // are pinned because the piece comes from the paragraph's interior, which
    // is the one thing they agree on.
    let mut md = mk("> one\n\ntwo\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(2, 10), InlineKind::Strong).unwrap();
    md.expect("> **one**\n\n**two**\n");
    assert!(md.find(KindRef::Tag(Tag::BlockQuote)).is_some());

    let mut dj = mk("> one\n\ntwo\n", Format::Djot);
    dj.ed.toggle_inline(Span::new(2, 10), InlineKind::Emph).unwrap();
    dj.expect("> _one_\n\n_two_\n");
    assert!(dj.find(KindRef::Tag(Tag::BlockQuote)).is_some());
}

#[test]
fn toggleinline_a_heading_s_marker_stays_outside_the_mark() {
    // The selection is the whole line, `# ` included. The piece is the
    // heading's `content_span`, so the marker is not what gets wrapped —
    // `**# Title**` is a bold paragraph, not a bold heading.
    let mut md = mk("# Title\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(0, 7), InlineKind::Strong).unwrap();
    md.expect("# **Title**\n");
    assert!(md.find(KindRef::Tag(Tag::Heading)).is_some());
}

#[test]
fn toggleinline_a_code_block_inside_the_range_is_stepped_over_not_marked() {
    let mut md = mk("a\n\n```\nx\n```\n\nb\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(0, 15), InlineKind::Emph).unwrap();
    md.expect("*a*\n\n```\nx\n```\n\n*b*\n");
    // Still a fence, and its body is byte-for-byte what it was: an asterisk
    // in a program is an asterisk.
    let fence = md.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
    eq_str("x\n", md.ed.ast_view().kind(fence).code_block_text());
}

#[test]
fn toggleinline_a_range_with_nowhere_to_put_a_mark_is_refused_not_mis_spelled() {
    // Wholly inside the fence. There is no inline host in the range, so there
    // is no honest place for a delimiter — and reporting success after writing
    // two asterisks into someone's program is the failure `NotEditable` exists
    // to prevent.
    let mut md = mk("```\nx y\n```\n", Format::Markdown);
    assert_eq!(md.ed.toggle_inline(Span::new(4, 7), InlineKind::Strong), Err(Error::NotEditable));
    assert_eq!(md.ed.wrap_range(Span::new(4, 7), InlineKind::Strong), Err(Error::NotEditable));
    md.expect("```\nx y\n```\n");
}

#[test]
fn wraprange_a_caret_is_not_a_range_and_still_opens_an_empty_pair() {
    // Zero-width: it crosses no boundary, and clipping it to a host would find
    // a zero-width share and drop it. "Turn bold on, then type" survives.
    let mut md = mk("ab\n", Format::Markdown);
    md.ed.wrap_range(Span::new(1, 1), InlineKind::Strong).unwrap();
    md.expect("a****b\n");
}

#[test]
fn wraprange_a_crossing_range_gets_one_pair_per_block_too() {
    // `wrapRange` always adds — but "adds" still has to mean a mark, so it cuts
    // at the same boundaries the toggle does.
    let mut md = mk("one\n\ntwo\n", Format::Markdown);
    md.ed.wrap_range(Span::new(0, 8), InlineKind::Emph).unwrap();
    md.expect("*one*\n\n*two*\n");
}

#[test]
fn toggleinline_one_splice_so_one_undo_step_however_many_blocks_it_touched() {
    // The reason the pieces are assembled into a single buffer rather than
    // spliced one at a time: a three-paragraph selection is one Cmd-Z, not
    // three, and one `Change` for the host to re-anchor its caret against.
    let mut md = mk("a\n\nb\n\nc\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(0, 7), InlineKind::Strong).unwrap();
    md.expect("**a**\n\n**b**\n\n**c**\n");
    md.ed.splicer.undo().unwrap();
    md.expect("a\n\nb\n\nc\n");
}

#[test]
fn a_range_past_the_source_is_refused_before_it_can_reach_the_splicer_s_assert() {
    let mut fx = mk("ab\n", Format::Djot);
    assert_eq!(fx.ed.toggle_inline(Span::new(0, 99), InlineKind::Strong), Err(Error::InvalidRange));
    assert_eq!(fx.ed.wrap_range(Span::new(2, 1), InlineKind::Strong), Err(Error::InvalidRange));
    assert_eq!(toggle_container(&mut fx, 0, 99, ContainerKind::BlockQuote), Err(Error::InvalidRange));
}

#[test]
fn toggleinline_gfm_strikethrough_is_authorable_under_twig_s_defaults() {
    // `~~x~~` reads back as a `delete` because `ParseOptions.strikethrough`
    // defaults ON — so unlike `==x==`, the DEFAULT editor is the one that can
    // write it, and turning the extension off is what takes it away.
    let mut md = mk("a word b\n", Format::Markdown);
    md.ed.toggle_inline(Span::new(2, 6), InlineKind::Delete).unwrap();
    md.expect("a ~~word~~ b\n");
    assert!(md.find(KindRef::Mark(InlineMark::Delete)).is_some());
    md.ed.toggle_inline(Span::new(4, 8), InlineKind::Delete).unwrap();
    md.expect("a word b\n");

    // Strict CommonMark has no strikethrough, so the same gesture over a
    // document parsed as that dialect would mint two literal tildes. Refused.
    let mut strict = mk("a word b\n", Format::Commonmark);
    assert_eq!(strict.ed.toggle_inline(Span::new(2, 6), InlineKind::Delete), Err(Error::UnsupportedFormat));
    assert_eq!(strict.ed.wrap_range(Span::new(2, 6), InlineKind::Delete), Err(Error::UnsupportedFormat));
    strict.expect("a word b\n");

    // The two axes are independent: the CommonMark row with the highlight
    // extension laid over it authors `==x==` and still refuses `~~x~~`.
    let mut mixed = mk_with("a word b\n", Format::Commonmark, highlight_cfg());
    assert_eq!(mixed.ed.toggle_inline(Span::new(2, 6), InlineKind::Delete), Err(Error::UnsupportedFormat));
    mixed.ed.toggle_inline(Span::new(2, 6), InlineKind::Mark).unwrap();
    mixed.expect("a ==word== b\n");
}

// ── highlights and their colours ───────────────────────────────────────────
//
// The pair of gestures whose availability is a fact about the PARSE CONFIG
// rather than about the format: `==x==` is literal text under default options
// (so a toggle that wrote it could not unwrite it) and a `mark` under
// `ParseOptions.highlight`, and the colour prefix is content until
// `highlight_colors` says otherwise. Every fixture here therefore goes through
// `initWith`, and the assertions are on the reparsed KIND — the only thing that
// proves the bytes came back as what they were meant to be.

/// The `data-color` of the first `mark` in the reparsed tree, or None.

#[test]
fn toggleinline_a_highlight_is_authorable_exactly_where_the_reparse_reads_it_back() {
    // Default options: `==x==` is emit-only, and the toggle refuses rather than
    // minting bytes that come back as a `str`.
    let mut off = mk("a word b\n", Format::Markdown);
    assert_eq!(off.ed.toggle_inline(Span::new(2, 6), InlineKind::Mark), Err(Error::UnsupportedFormat));
    off.expect("a word b\n");

    // Same format, same gesture, `highlight` on: written, reparsed as a mark,
    // and reversible — which is the whole of what `authorable` claims.
    let mut on = mk_with("a word b\n", Format::Markdown, highlight_cfg());
    on.ed.toggle_inline(Span::new(2, 6), InlineKind::Mark).unwrap();
    on.expect("a ==word== b\n");
    assert!(on.find(KindRef::Mark(InlineMark::Mark)).is_some());
    on.ed.toggle_inline(Span::new(4, 8), InlineKind::Mark).unwrap();
    on.expect("a word b\n");
}

#[test]
fn setmarkcolor_colours_a_highlight_recolours_it_and_clears_it() {
    let mut fx = mk_with("a ==word== b\n", Format::Markdown, highlight_colors_cfg());
    assert!(mark_color(&fx).is_none());

    // A first colour is written spaced, and lands INSIDE the delimiters.
    fx.ed.set_mark_color(6, Some(b"red")).unwrap();
    fx.expect("a ==\u{1F534} word== b\n");
    eq_str("red", mark_color(&fx).unwrap());

    // Recolouring replaces the prefix rather than stacking a second one.
    fx.ed.set_mark_color(9, Some(b"blue")).unwrap();
    fx.expect("a ==\u{1F535} word== b\n");
    eq_str("blue", mark_color(&fx).unwrap());

    // Clearing takes the space the prefix absorbed with it: it was spelling.
    fx.ed.set_mark_color(9, None).unwrap();
    fx.expect("a ==word== b\n");
    assert!(fx.find(KindRef::Mark(InlineMark::Mark)).is_some());
    assert!(mark_color(&fx).is_none());
}

#[test]
fn setmarkcolor_a_tight_prefix_stays_tight_because_that_spacing_is_the_author_s() {
    let mut fx = mk_with("==\u{1F534}word==\n", Format::Markdown, highlight_colors_cfg());
    eq_str("red", mark_color(&fx).unwrap());
    fx.ed.set_mark_color(7, Some(b"green")).unwrap();
    fx.expect("==\u{1F7E2}word==\n");
    eq_str("green", mark_color(&fx).unwrap());

    // And clearing a tight one leaves the text alone.
    fx.ed.set_mark_color(7, None).unwrap();
    fx.expect("==word==\n");
}

#[test]
fn setmarkcolor_clearing_a_colourless_highlight_is_a_no_op_that_succeeds() {
    let mut fx = mk_with("==word==\n", Format::Markdown, highlight_colors_cfg());
    fx.ed.set_mark_color(3, None).unwrap();
    fx.expect("==word==\n");
    // Nothing was spliced, so there is no change to report.
    assert!(fx.ed.last_change().is_none());
}

#[test]
fn setmarkcolor_the_caret_picks_the_innermost_highlight() {
    let mut fx = mk_with("*a ==b== c*\n", Format::Markdown, highlight_colors_cfg());
    // Inside the emphasis but outside the mark: nothing to colour.
    assert_eq!(fx.ed.set_mark_color(2, Some(b"red")), Err(Error::NotEditable));
    fx.ed.set_mark_color(6, Some(b"red")).unwrap();
    fx.expect("*a ==\u{1F534} b== c*\n");
    eq_str("red", mark_color(&fx).unwrap());
}

#[test]
fn setmarkcolor_a_colour_the_format_cannot_spell_is_refused_not_written() {
    let mut fx = mk_with("==word==\n", Format::Markdown, highlight_colors_cfg());
    // Obsidian's palette is the circle emoji, and `pink` is not one of them —
    // writing something for it would edit the highlighted TEXT.
    assert_eq!(fx.ed.set_mark_color(3, Some(b"pink")), Err(Error::InvalidColor));
    fx.expect("==word==\n");
    assert_eq!(fx.ed.set_mark_color(3, Some(b"")), Err(Error::InvalidColor));
    fx.expect("==word==\n");
}

#[test]
fn a_highlight_across_two_blocks_becomes_two_highlights_the_palette_can_reach() {
    // The observation this whole per-block cut came from. A selection crossing
    // a blank line used to produce `==one two\n\nthree four==`, which is not a
    // highlight — so `setMarkColor` correctly refused, because there was no
    // mark for it to colour. Now there are two, and each one is a caret away.
    let mut fx = mk_with("one two\n\nthree four\n", Format::Markdown, highlight_colors_cfg());
    fx.ed.toggle_inline(Span::new(0, 19), InlineKind::Mark).unwrap();
    fx.expect("==one two==\n\n==three four==\n");

    // Inside the first: `start + 2`, the `==` being two bytes.
    fx.ed.set_mark_color(2, Some(b"red")).unwrap();
    fx.expect("==\u{1F534} one two==\n\n==three four==\n");

    // And inside the second, whose start the first colour has moved along by
    // the four-byte emoji and its space.
    fx.ed.set_mark_color(20, Some(b"purple")).unwrap();
    fx.expect("==\u{1F534} one two==\n\n==\u{1F7E3} three four==\n");
}

#[test]
fn setmarkcolor_unsupported_where_the_config_spells_no_colour_or_the_format_doesn_t() {
    // `highlight` alone: the mark is authorable, the colour is not — the emoji
    // would be the first character of the highlighted text.
    let mut hi = mk_with("==word==\n", Format::Markdown, highlight_cfg());
    assert_eq!(hi.ed.set_mark_color(3, Some(b"red")), Err(Error::UnsupportedFormat));
    hi.expect("==word==\n");

    // Djot authors a mark but spells its colour as an attribute, not a prefix.
    let mut dj = mk("{=word=}\n", Format::Djot);
    assert_eq!(dj.ed.set_mark_color(3, Some(b"red")), Err(Error::UnsupportedFormat));

    // And clearing is refused the same way: an unsupported format is not a
    // format where the answer happens to be "no colour".
    assert_eq!(dj.ed.set_mark_color(3, None), Err(Error::UnsupportedFormat));
}

#[test]
fn setmarkcolor_a_caret_outside_any_highlight_edits_nothing() {
    let mut fx = mk_with("a ==b== c\n", Format::Markdown, highlight_colors_cfg());
    assert_eq!(fx.ed.set_mark_color(0, Some(b"red")), Err(Error::NotEditable));
    assert_eq!(fx.ed.set_mark_color(9, Some(b"red")), Err(Error::NotEditable));
    fx.expect("a ==b== c\n");
    // Past the end is a range error, as everywhere else.
    assert_eq!(fx.ed.set_mark_color(99, Some(b"red")), Err(Error::InvalidRange));
}

#[test]
fn authoring_a_coloured_highlight_is_the_two_gestures_in_order() {
    // The composition the API promises instead of a colour parameter on
    // `toggleInline`: wrap, then colour at an offset inside the new mark —
    // `start + 2`, the `==` being two bytes.
    let mut fx = mk_with("a word b\n", Format::Markdown, highlight_colors_cfg());
    fx.ed.toggle_inline(Span::new(2, 6), InlineKind::Mark).unwrap();
    fx.expect("a ==word== b\n");
    fx.ed.set_mark_color(4, Some(b"purple")).unwrap();
    fx.expect("a ==\u{1F7E3} word== b\n");
    eq_str("purple", mark_color(&fx).unwrap());

    // And un-highlighting takes the colour with it: the emoji was never text.
    // The interior now starts after the prefix — `a ` + `==` + the four-byte
    // emoji + its space — which is where the reparse reports the content.
    fx.ed.toggle_inline(Span::new(9, 13), InlineKind::Mark).unwrap();
    fx.expect("a word b\n");
    assert!(fx.find(KindRef::Mark(InlineMark::Mark)).is_none());
}

#[test]
fn editor_supports_the_inline_gates_move_with_the_parse_config_in_both_directions() {
    let plain = format::syntax_for(Format::Markdown);
    let hi = format::syntax_for_config(Format::Markdown, &highlight_cfg());
    let colors = format::syntax_for_config(Format::Markdown, &highlight_colors_cfg());
    let strict = format::syntax_for(Format::Commonmark);

    // Strikethrough defaults ON, so the DEFAULT answer is yes and turning the
    // extension off is what makes it no — the opposite direction from the
    // highlight below, and the reason this is a table per config rather than a
    // list of opt-in extras.
    assert!(supports(plain, Gesture::ToggleInline(InlineKind::Delete)));
    assert!(supports(plain, Gesture::WrapRange(InlineKind::Delete)));
    assert!(!supports(strict, Gesture::ToggleInline(InlineKind::Delete)));
    assert!(!supports(strict, Gesture::WrapRange(InlineKind::Delete)));
    // And what neither flag touches is untouched.
    assert!(supports(strict, Gesture::ToggleInline(InlineKind::Strong)));
    assert!(!supports(strict, Gesture::ToggleInline(InlineKind::Superscript)));
    assert!(!supports(plain, Gesture::ToggleInline(InlineKind::Superscript)));

    assert!(!supports(plain, Gesture::ToggleInline(InlineKind::Mark)));
    assert!(supports(hi, Gesture::ToggleInline(InlineKind::Mark)));
    assert!(supports(colors, Gesture::ToggleInline(InlineKind::Mark)));

    // The palette is the narrower gate: a toolbar grays it while the highlight
    // button beside it stays live.
    assert!(!supports(plain, Gesture::SetMarkColor));
    assert!(!supports(hi, Gesture::SetMarkColor));
    assert!(supports(colors, Gesture::SetMarkColor));

    // No other format spells a colour prefix, including the one that spells
    // every mark.
    assert!(!supports(format::syntax_for(Format::Djot), Gesture::SetMarkColor));
    assert!(!supports(format::syntax_for(Format::Html), Gesture::SetMarkColor));
    assert!(!supports(format::syntax_for(Format::Asciidoc), Gesture::SetMarkColor));
    assert!(!supports(format::syntax_for(Format::Xml), Gesture::SetMarkColor));
}

// ── block kind ─────────────────────────────────────────────────────────────

#[test]
fn setblock_paragraph_to_heading_and_back_both_formats() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("hello\n", fmt);
        fx.ed.set_block(0, BlockKind::Heading, 2).unwrap();
        fx.expect("## hello\n");
        fx.ed.set_block(4, BlockKind::Paragraph, 0).unwrap();
        fx.expect("hello\n");
    }
}

#[test]
fn setblock_a_block_keeps_the_quote_it_is_in_and_the_attribute_line_above_it() {
    // Markdown's span for a paragraph in a quote begins at its `> `, which
    // is the quote's, not the paragraph's to rewrite. Found by the gesture
    // check (`contract.gestures`): the quote was lost on the way to a heading.
    let mut md = mk("> Quote\n", Format::Markdown);
    md.ed.set_block(2, BlockKind::Heading, 2).unwrap();
    md.expect("> ## Quote\n");
    md.ed.set_block(5, BlockKind::Paragraph, 0).unwrap();
    md.expect("> Quote\n");
    assert_eq!(1usize, md.count(KindRef::Tag(Tag::BlockQuote)));

    // Nor anything else outside its own marker and text: a djot attribute
    // line above the block stays where it is.
    let mut dj = mk("{.note}\nA paragraph.\n", Format::Djot);
    dj.ed.set_block(8, BlockKind::Heading, 2).unwrap();
    dj.expect("{.note}\n## A paragraph.\n");
}

#[test]
fn setblock_a_setext_heading_s_underline_collapses_away() {
    // Rebuilding from `content_span` drops the `===` line for free.
    let mut fx = mk("hello\n=====\n", Format::Markdown);
    fx.ed.set_block(0, BlockKind::Heading, 3).unwrap();
    fx.expect("### hello\n");
}

#[test]
fn setblock_a_markdown_paragraph_of_several_lines_becomes_one_heading_its_soft_breaks_joined() {
    // `docs/tasks/closed/markdown-set-block-multi-line-paragraph.md`: the marker
    // before the first line alone made `## a` a heading and `b` a paragraph,
    // and reported success. An ATX heading is one line.
    let mut md = mk("a\nb\n", Format::Markdown);
    md.ed.set_block(0, BlockKind::Heading, 2).unwrap();
    md.expect("## a b\n");
    assert_eq!(1usize, md.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, md.count(KindRef::Tag(Tag::Para)));

    // The continuation prefix goes with the line end, trailing spaces and
    // lazy lines included, and the quote stays.
    let mut quoted = mk("> a \n> *b\nc*\n", Format::Markdown);
    quoted.ed.set_block(2, BlockKind::Heading, 1).unwrap();
    quoted.expect("> # a *b c*\n");
    assert_eq!(1usize, quoted.count(KindRef::Tag(Tag::BlockQuote)));

    // A hard break has no one-line spelling, and a code span run over two
    // lines is not folded: both refused, the source untouched.
    for src in ["a  \nb\n", "a\\\nb\n", "`a\nb`\n"] {
        let mut fx = mk(src, Format::Markdown);
        assert_eq!(fx.ed.set_block(0, BlockKind::Heading, 2), Err(Error::NotEditable));
        fx.expect(src);
    }

    // Djot's heading continues onto its next line, so its line breaks stay.
    let mut dj = mk("a\nb\n", Format::Djot);
    dj.ed.set_block(0, BlockKind::Heading, 2).unwrap();
    dj.expect("## a\nb\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Heading)));
}

#[test]
fn setblock_a_heading_the_reparse_reads_differently_is_refused() {
    // `#` after a space closes an ATX heading, so `## Number #` would be a
    // heading over `Number` — text the paragraph had, cut.
    let mut fx = mk("Number #\n", Format::Markdown);
    assert_eq!(fx.ed.set_block(0, BlockKind::Heading, 2), Err(Error::NotEditable));
    fx.expect("Number #\n");
}

#[test]
fn setblock_an_out_of_range_level_is_refused_and_a_parse_only_format_too() {
    let mut fx = mk("hello\n", Format::Djot);
    assert_eq!(fx.ed.set_block(0, BlockKind::Heading, 0), Err(Error::InvalidLevel));
    assert_eq!(fx.ed.set_block(0, BlockKind::Heading, 7), Err(Error::InvalidLevel));
    assert_eq!(fx.ed.set_block(99, BlockKind::Heading, 1), Err(Error::InvalidRange));

    let mut xml = mk("<r>ab</r>", Format::Xml);
    assert_eq!(xml.ed.set_block(3, BlockKind::Heading, 1), Err(Error::UnsupportedFormat));
}

// ── block containers ───────────────────────────────────────────────────────

#[test]
fn toggle_block_container_quote_on_then_off_round_trips_djot() {
    let mut fx = mk("a\n", Format::Djot);

    toggle_container(&mut fx, 0, 1, ContainerKind::BlockQuote).unwrap();
    fx.expect("> a\n");

    // "a" now sits at [2,3); the range covers the whole quote -> toggle off.
    toggle_container(&mut fx, 2, 3, ContainerKind::BlockQuote).unwrap();
    fx.expect("a\n");
}

#[test]
fn toggle_block_container_quote_on_then_off_round_trips_markdown() {
    let mut fx = mk("a\n", Format::Markdown);

    toggle_container(&mut fx, 0, 1, ContainerKind::BlockQuote).unwrap();
    fx.expect("> a\n");
    toggle_container(&mut fx, 2, 3, ContainerKind::BlockQuote).unwrap();
    fx.expect("a\n");
}

#[test]
fn toggle_block_container_a_multi_block_range_becomes_one_quote_blanks_marked() {
    let mut fx = mk("a\n\nb\n", Format::Djot);

    // The blank line between the paragraphs must carry a `>` too, or the result
    // is two quotes instead of one.
    toggle_container(&mut fx, 0, 4, ContainerKind::BlockQuote).unwrap();
    fx.expect("> a\n>\n> b\n");

    toggle_container(&mut fx, 2, 9, ContainerKind::BlockQuote).unwrap();
    fx.expect("a\n\nb\n");
}

#[test]
fn toggle_block_container_quoting_inside_a_quote_nests_and_off_peels_one_level() {
    let mut fx = mk("> a\n>\n> b\n", Format::Djot);

    // Only the first paragraph is selected, so the enclosing quote is NOT fully
    // covered: the toggle nests rather than unquoting `b` along with it.
    toggle_container(&mut fx, 2, 3, ContainerKind::BlockQuote).unwrap();
    fx.expect("> > a\n>\n> b\n");

    // "a" is now at [4,5); toggling again peels the inner level only.
    toggle_container(&mut fx, 4, 5, ContainerKind::BlockQuote).unwrap();
    fx.expect("> a\n>\n> b\n");
}

#[test]
fn toggle_block_container_each_covered_block_becomes_its_own_list_item() {
    let mut fx = mk("a\n\nb\n", Format::Djot);
    toggle_container(&mut fx, 0, 4, ContainerKind::BulletList).unwrap();
    fx.expect("- a\n\n- b\n");
}

#[test]
fn toggle_block_container_an_ordered_list_numbers_a_multi_item_range() {
    let mut fx = mk("a\n\nb\n", Format::Djot);
    toggle_container(&mut fx, 0, 4, ContainerKind::OrderedList).unwrap();
    fx.expect("1. a\n\n2. b\n");
}

#[test]
fn toggle_block_container_unlisting_keeps_the_items_as_separate_blocks() {
    // A tight `- a\n- b\n` stripped naively is `a\nb\n` — ONE two-line paragraph,
    // not two. The blank line is what preserves the structure.
    let mut fx = mk("- a\n- b\n", Format::Djot);
    toggle_container(&mut fx, 2, 7, ContainerKind::BulletList).unwrap();
    fx.expect("a\n\nb\n");
}

#[test]
fn toggle_block_container_toggling_the_other_list_kind_converts_in_place() {
    let mut fx = mk("- a\n- b\n", Format::Djot);
    toggle_container(&mut fx, 2, 7, ContainerKind::OrderedList).unwrap();
    fx.expect("1. a\n2. b\n");
}

#[test]
fn toggle_block_container_a_nested_quote_peels_one_level_markdown() {
    let mut fx = mk("> > a\n", Format::Markdown);
    toggle_container(&mut fx, 4, 5, ContainerKind::BlockQuote).unwrap();
    fx.expect("> a\n");
}

#[test]
fn toggle_block_container_a_list_s_continuation_lines_follow_the_new_marker_width() {
    let mut fx = mk("- a\n  b\n", Format::Djot);
    // `1. ` is a byte wider than `- `, so the second line has to re-indent or it
    // falls out of the item.
    toggle_container(&mut fx, 2, 7, ContainerKind::OrderedList).unwrap();
    fx.expect("1. a\n   b\n");
}

#[test]
fn renumberorderedlists_makes_a_drifted_sequence_sequential() {
    // The `1. 2. 2. 3.` a caret editor leaves after inserting an item mid-list.
    let mut fx = mk("1. a\n2. x\n2. b\n3. c\n", Format::Markdown);
    fx.ed.renumber_ordered_lists(0).unwrap();
    fx.expect("1. a\n2. x\n3. b\n4. c\n");
}

#[test]
fn renumberorderedlists_each_nesting_level_restarts_at_1() {
    let mut fx = mk("1. a\n   5. b\n   9. c\n3. d\n", Format::Markdown);
    fx.ed.renumber_ordered_lists(0).unwrap();
    fx.expect("1. a\n   1. b\n   2. c\n2. d\n");
}

#[test]
fn toggle_block_container_html_wraps_the_covered_blocks_in_a_quote_the_parser_reads_back() {
    // No line prefix to write — `<blockquote>` wraps — so the covered blocks
    // go under a fresh `block_quote` node and `renderBlock` prints it. Both
    // paragraphs, with the mark re-spelled from the tree.
    let mut fx = mk("<p>a <em>b</em></p>\n<p>c</p>\n<p>d</p>\n", Format::Html);
    toggle_container(&mut fx, 3, 21, ContainerKind::BlockQuote).unwrap();
    fx.expect("<blockquote>\n<p>a <em>b</em></p>\n<p>c</p>\n</blockquote>\n<p>d</p>\n");
    let q = fx.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
    let ast = fx.ed.ast_view();
    let mut n: usize = 0;
    let mut c = ast.nodes[q as usize].first_child;
    while let Some(id) = c {
        n += 1;
        c = ast.nodes[id as usize].next_sibling;
    }
    assert_eq!(2usize, n);
    assert!(fx.find(KindRef::Mark(InlineMark::Emph)).is_some());
}

#[test]
fn toggle_block_container_html_quote_on_then_off_round_trips() {
    let mut fx = mk("<p>a</p>\n<p>b</p>\n", Format::Html);
    toggle_container(&mut fx, 3, 12, ContainerKind::BlockQuote).unwrap();
    fx.expect("<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n");
    // Off: the range reaches both of the quote's blocks, so they are printed
    // in its place.
    let src = fx.ed.source_bytes();
    let a = find_sub(src, b"a</p>").unwrap();
    let b = find_sub(src, b"b</p>").unwrap();
    toggle_container(&mut fx, a, b + 1, ContainerKind::BlockQuote).unwrap();
    fx.expect("<p>a</p>\n<p>b</p>\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::BlockQuote));
}

#[test]
fn toggle_block_container_html_quoting_part_of_a_quote_nests_and_off_peels_one_level() {
    let mut fx = mk("<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n", Format::Html);
    let a = find_sub(fx.ed.source_bytes(), b"a</p>").unwrap();
    toggle_container(&mut fx, a, a + 1, ContainerKind::BlockQuote).unwrap();
    fx.expect("<blockquote>\n<blockquote>\n<p>a</p>\n</blockquote>\n<p>b</p>\n</blockquote>\n");
    let a2 = find_sub(fx.ed.source_bytes(), b"a</p>").unwrap();
    toggle_container(&mut fx, a2, a2 + 1, ContainerKind::BlockQuote).unwrap();
    fx.expect("<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n");
}

#[test]
fn toggle_block_container_html_makes_each_covered_block_an_item_tight_when_they_are_paragraph() {
    let mut fx = mk("<p>a</p>\n<p>b</p>\n", Format::Html);
    toggle_container(&mut fx, 3, 12, ContainerKind::BulletList).unwrap();
    fx.expect("<ul>\n<li>\na\n</li>\n<li>\nb\n</li>\n</ul>\n");
    let l = fx.find(KindRef::Tag(Tag::BulletList)).expect("NoList");
    assert!(fx.ed.ast_view().kind(l).bullet_list_tight());
    // Off: each item's blocks, as paragraphs again.
    let src = fx.ed.source_bytes();
    let a = find_sub(src, b"a\n").unwrap();
    let b = find_sub(src, b"b\n").unwrap();
    toggle_container(&mut fx, a, b + 1, ContainerKind::BulletList).unwrap();
    fx.expect("<p>a</p>\n<p>b</p>\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::ListItem));
}

#[test]
fn toggle_block_container_html_converts_between_the_list_kinds_in_place_tightness_kept() {
    let mut fx = mk("<ul class=\"x\">\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n", Format::Html);
    let src = fx.ed.source_bytes();
    let a = find_sub(src, b"a</p>").unwrap();
    let b = find_sub(src, b"b</p>").unwrap();
    toggle_container(&mut fx, a, b + 1, ContainerKind::OrderedList).unwrap();
    fx.expect("<ol class=\"x\">\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ol>\n");
    let l = fx.find(KindRef::Tag(Tag::OrderedList)).expect("NoList");
    assert!(!fx.ed.ast_view().kind(l).ordered_list_tight());
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::BulletList));
    // A range reaching only one item nests a list inside it instead.
    let a2 = find_sub(fx.ed.source_bytes(), b"a</p>").unwrap();
    toggle_container(&mut fx, a2, a2 + 1, ContainerKind::BulletList).unwrap();
    assert!(fx.find(KindRef::Tag(Tag::BulletList)).is_some());
    assert!(fx.find(KindRef::Tag(Tag::OrderedList)).is_some());
}

#[test]
fn toggle_block_container_html_opens_a_container_over_an_empty_paragraph_on_a_blank_line() {
    let mut fx = mk("<p>a</p>\n\n<p>b</p>\n", Format::Html);
    toggle_container(&mut fx, 9, 9, ContainerKind::OrderedList).unwrap();
    fx.expect("<p>a</p>\n<ol>\n<li>\n<p></p>\n</li>\n</ol>\n<p>b</p>\n");
    // The press that made it un-makes it, through the ordinary toggle-off.
    let p = find_sub(fx.ed.source_bytes(), b"<p></p>").unwrap() + 3;
    toggle_container(&mut fx, p, p, ContainerKind::OrderedList).unwrap();
    fx.expect("<p>a</p>\n<p></p>\n<p>b</p>\n");
    // And a quote, over a blank line at the end.
    let mut q = mk("<p>a</p>\n\n", Format::Html);
    toggle_container(&mut q, 9, 9, ContainerKind::BlockQuote).unwrap();
    q.expect("<p>a</p>\n<blockquote>\n<p></p>\n</blockquote>\n");
    // Inside a `<pre>` body a blank line is the listing's, not a gap: the
    // caret resolves to the code block, which is wrapped whole — the marker
    // path's rule for the same caret.
    let mut pre = mk("<pre><code>x\n\ny</code></pre>\n", Format::Html);
    let inner = find_sub(pre.ed.source_bytes(), b"\n\n").unwrap() + 1;
    toggle_container(&mut pre, inner, inner, ContainerKind::BlockQuote).unwrap();
    pre.expect("<blockquote>\n<pre><code>x\n\ny</code></pre>\n</blockquote>\n");
}

#[test]
fn toggle_block_container_html_takes_an_empty_container_back_off() {
    let mut fx = mk("<p>a</p>\n<blockquote></blockquote>\n", Format::Html);
    let inner = find_sub(fx.ed.source_bytes(), b"</blockquote>").unwrap();
    toggle_container(&mut fx, inner, inner, ContainerKind::BlockQuote).unwrap();
    fx.expect("<p>a</p>\n\n");
    let mut li = mk("<ul><li></li></ul>\n", Format::Html);
    toggle_container(&mut li, 8, 8, ContainerKind::BulletList).unwrap();
    li.expect("\n");
    // The other kind on that line is a press with nothing to do.
    let mut other = mk("<ul><li></li></ul>\n", Format::Html);
    assert_eq!(toggle_container(&mut other, 8, 8, ContainerKind::BlockQuote), Err(Error::NotEditable));
}

#[test]
fn setblock_html_builds_the_heading_and_prints_it_inline_content_and_attributes_along() {
    // No marker to rewrite — `<h2>` carries its level in both ends — so the
    // paragraph's children go under a fresh heading node and `renderBlock`
    // spells it. The `<em>` survives because it is re-spelled from the tree,
    // and the `class` because the node's attributes ride along.
    let mut fx = mk("<p class=\"lead\">hello <em>x</em></p>\n<p>two</p>\n", Format::Html);
    fx.ed.set_block(20, BlockKind::Heading, 2).unwrap();
    fx.expect("<h2 class=\"lead\">hello <em>x</em></h2>\n<p>two</p>\n");
    let h = fx.find(KindRef::Tag(Tag::Heading)).expect("NoHeading");
    assert_eq!(2u32, fx.ed.ast_view().kind(h).heading_level());
    assert!(fx.find(KindRef::Mark(InlineMark::Emph)).is_some());
    // And back: the same path, printing a paragraph.
    fx.ed.set_block(20, BlockKind::Paragraph, 0).unwrap();
    fx.expect("<p class=\"lead\">hello <em>x</em></p>\n<p>two</p>\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
}

#[test]
fn setblock_html_re_levels_a_heading_in_place() {
    let mut fx = mk("<h1>t</h1>\n", Format::Html);
    fx.ed.set_block(5, BlockKind::Heading, 3).unwrap();
    fx.expect("<h3>t</h3>\n");
    assert_eq!(fx.ed.set_block(5, BlockKind::Heading, 7), Err(Error::InvalidLevel));
    assert_eq!(fx.ed.set_block(99, BlockKind::Heading, 1), Err(Error::InvalidRange));
}

#[test]
fn setblock_html_opens_an_empty_heading_on_a_blank_line_and_nothing_inside_a_leaf() {
    let mut fx = mk("<p>a</p>\n\n<p>b</p>\n", Format::Html);
    fx.ed.set_block(9, BlockKind::Heading, 2).unwrap();
    fx.expect("<p>a</p>\n<h2></h2>\n<p>b</p>\n");
    assert!(fx.find(KindRef::Tag(Tag::Heading)).is_some());
    // A paragraph on a blank line is the state it is already in.
    let mut blank = mk("<p>a</p>\n\n", Format::Html);
    blank.ed.set_block(9, BlockKind::Paragraph, 0).unwrap();
    blank.expect("<p>a</p>\n\n");
    // A blank line inside a `<pre>` body is inside the listing, not between
    // blocks.
    let mut pre = mk("<pre><code>x\n\ny</code></pre>\n", Format::Html);
    let inner = find_sub(pre.ed.source_bytes(), b"\n\n").unwrap() + 1;
    assert_eq!(pre.ed.set_block(inner, BlockKind::Heading, 1), Err(Error::NotEditable));
    pre.expect("<pre><code>x\n\ny</code></pre>\n");
}

#[test]
fn setblock_opens_a_heading_on_a_blank_line() {
    // No node to convert — no format spells an empty paragraph — so the marker
    // is opened rather than rewritten. Without this a caller had to spell `#`
    // itself, and spell it per format. The caret is on the empty line left by
    // pressing Enter twice, which is where the gesture is actually reached from.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a\n\n", f);
        fx.ed.set_block(3, BlockKind::Heading, 2).unwrap();
        fx.expect("a\n\n## ");
        assert!(fx.find(KindRef::Tag(Tag::Heading)).is_some());
    }
}

#[test]
fn setblock_a_marker_never_lands_flush_under_a_paragraph() {
    // Djot does not let a heading interrupt a paragraph, so `## ` written on the
    // line directly under one is read there as that paragraph's own text — the
    // document gains no heading and `##` shows up literally. Markdown reads the
    // same bytes as a heading. The minted blank is what makes one spelling work
    // in both, and the REPARSE is what proves it rather than the bytes.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a\n\n", f);
        // The caret is on the separator line itself, so writing the marker
        // where it sits would consume the separator.
        fx.ed.set_block(2, BlockKind::Heading, 2).unwrap();
        fx.expect("a\n\n## \n");
        assert!(fx.find(KindRef::Tag(Tag::Heading)).is_some());
        assert!(fx.find(KindRef::Tag(Tag::Para)).is_some());
    }
}

#[test]
fn setblock_opens_a_heading_in_an_empty_document() {
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("", f);
        fx.ed.set_block(0, BlockKind::Heading, 1).unwrap();
        fx.expect("# ");
    }
}

#[test]
fn setblock_a_quote_s_blank_line_keeps_the_quote_with_the_space_djot_needs() {
    // The blank line is spelled `>`, and `>#` is NOT a quoted heading in both
    // formats — Markdown reads one, djot reads the whole line as a paragraph.
    // Re-emitting the marker with a space is what makes one spelling work in
    // both, and the reparse is what proves it.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("> a\n>\n", f);
        fx.ed.set_block(4, BlockKind::Heading, 1).unwrap();
        fx.expect("> a\n>\n> # \n");
        assert!(fx.find(KindRef::Tag(Tag::Heading)).is_some());
        assert!(fx.find(KindRef::Tag(Tag::BlockQuote)).is_some());
    }
}

#[test]
fn setblock_a_blank_line_inside_a_code_block_is_refused() {
    // `innermostBlock` reports `None` here exactly as it does between blocks,
    // and only the line's OWNER tells them apart. Writing `# ` in would add no
    // heading and corrupt the listing.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("```\nx\n\ny\n```\n", f);
        let blank = find_sub(fx.ed.source_bytes(), b"\n\n").unwrap() + 1;
        assert_eq!(fx.ed.set_block(blank, BlockKind::Heading, 1), Err(Error::NotEditable));
        fx.expect("```\nx\n\ny\n```\n");
    }
}

#[test]
fn setblock_paragraph_on_a_blank_line_is_a_no_op_not_an_error() {
    // The state asked for is the state it is in: a blank line holds no marker.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a\n\n", f);
        fx.ed.set_block(2, BlockKind::Paragraph, 0).unwrap();
        fx.expect("a\n\n");
    }
}

#[test]
fn renumberorderedlists_a_quoted_list_renumbers_behind_its_prefix() {
    // The markers sit behind `> `, so a scan from column zero finds `>` where it
    // wants a digit. Every line failed the test, the region was copied verbatim,
    // and the gesture returned OK having changed nothing.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("> 1. a\n> 2. b\n> 2. c\n", f);
        fx.ed.renumber_ordered_lists(2).unwrap();
        fx.expect("> 1. a\n> 2. b\n> 3. c\n");
    }
}

#[test]
fn renumberorderedlists_a_quote_prefix_is_not_nesting_depth() {
    // The `> ` is two columns wide, but it is the QUOTE's width, not the list's
    // indentation — a quoted top-level item is still top-level, and counting the
    // prefix would open a phantom level whose siblings never resume.
    //
    // Blank-separated because djot does not let a list marker interrupt a
    // paragraph: without the blanks `>    7. b` is a continuation line of item
    // `a` there and a nested item in Markdown, so the two formats would be
    // renumbering different documents. That divergence has its own test below.
    for f in [Format::Markdown, Format::Djot] {
        let mut fx = mk("> 3. a\n>\n>    7. b\n>\n> 9. c\n", f);
        fx.ed.renumber_ordered_lists(2).unwrap();
        fx.expect("> 1. a\n>\n>    1. b\n>\n> 2. c\n");
    }
}

#[test]
fn renumberorderedlists_djot_s_literal_2_line_is_prose_not_an_item() {
    // Djot doesn't let a list marker interrupt a paragraph, so `   2. b` is a
    // continuation line of item `a` — the author's own text, four bytes of which
    // happen to spell a marker. Markdown reads the same bytes as a nested item.
    let mut fx = mk("1. a\n   2. b\n2. c\n", Format::Djot);
    let mut items: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::ListItem { items += 1; }
    }
    assert_eq!(2usize, items); // 2, not markdown's 3
    fx.ed.renumber_ordered_lists(0).unwrap();
    fx.expect("1. a\n   2. b\n2. c\n");

    let mut md = mk("1. a\n   2. b\n2. c\n", Format::Markdown);
    md.ed.renumber_ordered_lists(0).unwrap();
    md.expect("1. a\n   1. b\n2. c\n");
}

#[test]
fn renumberorderedlists_a_numbered_line_inside_a_code_block_is_left_alone() {
    // The same question the djot case asks, with an unambiguous answer: these
    // digits are the program's, and the tree is the only thing that says so.
    let mut fx = mk("1. a\n\n   ```\n   7. not an item\n   ```\n\n5. b\n", Format::Markdown);
    fx.ed.renumber_ordered_lists(0).unwrap();
    fx.expect("1. a\n\n   ```\n   7. not an item\n   ```\n\n2. b\n");
}

#[test]
fn renumberorderedlists_leaves_bullets_and_already_sequential_lists_alone() {
    let mut fx = mk("- a\n- b\n", Format::Markdown);
    // A bullet list at the offset isn't an ordered list: nothing to do.
    assert_eq!(fx.ed.renumber_ordered_lists(0), Err(Error::NoBlock));
}

#[test]
fn renumberorderedlists_not_inside_an_ordered_list_is_noblock() {
    let mut fx = mk("just a paragraph\n", Format::Markdown);
    assert_eq!(fx.ed.renumber_ordered_lists(3), Err(Error::NoBlock));
}

#[test]
fn renumberorderedlists_a_format_that_spells_no_numbered_marker_refuses() {
    // An HTML `<ol>` parses into the same `ordered_list`/`list_item` nodes a
    // Markdown one does, so the pass ran, found no `N.` run to rewrite, and
    // reported the no-op as a success — a gesture that can only ever do nothing,
    // answering as though it had done something. The number is in the tag here,
    // not in the line.
    let src = "<ol><li>a</li><li>b</li></ol>";
    let mut fx = mk(src, Format::Html);
    assert_eq!(fx.ed.renumber_ordered_lists(8), Err(Error::UnsupportedFormat));
    fx.expect(src);
}

// ── Tables ───────────────────────────────────────────────────────────────────

const TABLE_SRC: &str = "| a | b |\n| --- | --- |\n| 1 | 2 |\n";

#[test]
fn tableinsertrow_adds_an_empty_body_row_below_the_caret_s_row() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    fx.ed.table_insert_row(2, true).unwrap(); // caret in header cell `a`
    fx.expect("| a | b |\n| --- | --- |\n|  |  |\n| 1 | 2 |\n");
}

#[test]
fn tabledeleterow_removes_the_caret_s_body_row() {
    let mut fx = mk("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n", Format::Markdown);
    fx.ed.table_delete_row(24).unwrap(); // caret in the `1` cell (first body row)
    fx.expect("| a | b |\n| --- | --- |\n| 3 | 4 |\n");
}

#[test]
fn tabledeleterow_refuses_the_header_row() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    assert_eq!(fx.ed.table_delete_row(2), Err(Error::NotEditable));
}

#[test]
fn tableinsertcolumn_adds_an_empty_column_to_every_row_and_the_delimiter() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    fx.ed.table_insert_column(2, true).unwrap(); // right of column `a`
    fx.expect("| a |  | b |\n| --- | --- | --- |\n| 1 |  | 2 |\n");
}

#[test]
fn tabledeletecolumn_drops_the_caret_s_column_from_every_row() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    fx.ed.table_delete_column(6).unwrap(); // caret in column `b`
    fx.expect("| a |\n| --- |\n| 1 |\n");
}

#[test]
fn tabledeletecolumn_refuses_the_last_column() {
    let mut fx = mk("| a |\n| --- |\n| 1 |\n", Format::Markdown);
    assert_eq!(fx.ed.table_delete_column(2), Err(Error::NotEditable));
}

#[test]
fn tablesetalignment_respells_the_delimiter_for_the_caret_s_column() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    fx.ed.table_set_alignment(6, Alignment::Center).unwrap(); // column `b`
    fx.expect("| a | b |\n| --- | :---: |\n| 1 | 2 |\n");
}

#[test]
fn tablemovecolumn_swaps_two_columns_content_and_alignment_together() {
    let mut fx = mk("| a | b |\n| :--- | ---: |\n| 1 | 2 |\n", Format::Markdown);
    fx.ed.table_move_column(2, true).unwrap(); // move `a` right
    fx.expect("| b | a |\n| ---: | :--- |\n| 2 | 1 |\n");
}

#[test]
fn tablemoverow_swaps_two_body_rows() {
    let mut fx = mk("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n", Format::Markdown);
    fx.ed.table_move_row(24, true).unwrap(); // move first body row down
    fx.expect("| a | b |\n| --- | --- |\n| 3 | 4 |\n| 1 | 2 |\n");
}

#[test]
fn table_ops_off_a_table_are_noblock() {
    let mut fx = mk("just a paragraph\n", Format::Markdown);
    assert_eq!(fx.ed.table_insert_row(3, true), Err(Error::NoBlock));
}

#[test]
fn table_edits_re_spell_in_the_format_s_own_dialect_not_gfm_s() {
    // Djot's delimiter row carries no padding and keeps every cell three wide
    // (`|:-:|`, never `| :---: |`): djot.js steps one byte past the bar before
    // matching the dashes, so the Markdown spelling reads there as an ordinary
    // data row and the table loses its header. Before `Syntax.table_spelling`
    // this file wrote Markdown's skeleton into every format it could extract.
    let mut fx = mk("|a|b|\n|---|---|\n|1|2|\n", Format::Djot);
    fx.ed.table_set_alignment(1, Alignment::Center).unwrap(); // caret in column `a`
    fx.expect("| a | b |\n|:-:|---|\n| 1 | 2 |\n");
    // The rows ARE padded — only the delimiter isn't — and the result is still
    // one table with a header row, which is the property the padding protects.
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
    let head = fx.find(KindRef::Tag(Tag::Row)).expect("NoRow");
    assert!(fx.ed.ast_view().kind(head).row_head());
}

#[test]
fn table_gestures_refuse_a_format_with_no_table_spelling_and_touch_nothing() {
    // The destructive case the gate exists for, and the reason it is checked
    // BEFORE the grid is extracted. HTML's parser lowers `<table>/<tr>/<td>` to
    // the same `table`/`row`/`cell` nodes a pipe table produces, so extraction
    // used to succeed and the rebuilt pipe text was spliced over the elements —
    // which HTML reparses as a paragraph. A document that still parses is one
    // the splicer will not roll back, so there was no `EditConflict` and no
    // error at all: the table was simply gone.
    let src = "<table><tr><td>a</td><td>b</td></tr><tr><td>1</td><td>2</td></tr></table>";
    let mut fx = mk(src, Format::Html);
    let caret = find_sub(src, b"a").unwrap(); // inside the first cell
    assert_eq!(fx.ed.table_insert_row(caret, true), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.table_delete_row(caret), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.table_insert_column(caret, true), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.table_delete_column(caret), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.table_set_alignment(caret, Alignment::Center), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.table_move_row(caret, true), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.table_move_column(caret, true), Err(Error::UnsupportedFormat));
    // The assertion that matters: not one byte moved, and the table is still a
    // table rather than a paragraph of pipes.
    fx.expect(src);
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
}

#[test]
fn inserttable_a_header_rows_empty_body_rows_and_cols_columns_after_the_caret_s_block() {
    let mut fx = mk("a\n\nb\n", Format::Markdown);
    fx.ed.insert_table(0, 2, 3).unwrap();
    fx.expect("a\n\n|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n\nb\n");
    // A table the parser reads as one, with its header — not a paragraph of
    // pipes. That is what the delimiter row and the blank above it buy.
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
    let head = fx.find(KindRef::Tag(Tag::Row)).expect("NoRow");
    assert!(fx.ed.ast_view().kind(head).row_head());
}

#[test]
fn inserttable_the_blank_line_above_keeps_the_header_out_of_the_paragraph() {
    // GFM reads a delimiter row against the paragraph line above it, so a table
    // written flush under `a` would take `a` for its header. The reparsed shape
    // is the assertion: `a` is still a paragraph, and the table's header is the
    // empty row this wrote.
    let mut fx = mk("a\n", Format::Markdown);
    fx.ed.insert_table(0, 1, 2).unwrap();
    fx.expect("a\n\n|  |  |\n| --- | --- |\n|  |  |\n");
    assert!(fx.find(KindRef::Tag(Tag::Para)).is_some());
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
}

#[test]
fn inserttable_an_unterminated_last_line_is_ended_before_the_blank_above() {
    // The same line-ending as the rule's, and it matters more here: GFM reads
    // a header row out of the paragraph a table is written flush under, so
    // `a` followed directly by the delimiter row is a table whose header is
    // the paragraph.
    let mut fx = mk("a", Format::Markdown);
    fx.ed.insert_table(1, 1, 1).unwrap();
    fx.expect("a\n\n|  |\n| --- |\n|  |\n");
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
    assert!(fx.find(KindRef::Tag(Tag::Para)).is_some());
}

#[test]
fn inserttable_spelled_in_the_format_s_own_dialect() {
    // Djot's delimiter row is unpadded; see `table edits re-spell in the
    // format's OWN dialect` for why that is a fact and not a style.
    let mut fx = mk("a\n", Format::Djot);
    fx.ed.insert_table(0, 1, 2).unwrap();
    fx.expect("a\n\n|  |  |\n|---|---|\n|  |  |\n");
    let head = fx.find(KindRef::Tag(Tag::Row)).expect("NoRow");
    assert!(fx.ed.ast_view().kind(head).row_head());
}

#[test]
fn inserttable_inside_a_quote_every_line_carries_the_marker() {
    // A rule is one line and inherits the prefix once; a table is several, and
    // a marker on the first alone would end the quote after the header.
    let mut fx = mk("> a\n", Format::Markdown);
    fx.ed.insert_table(2, 1, 1).unwrap();
    fx.expect("> a\n>\n> |  |\n> | --- |\n> |  |\n");
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
    // One quote, and the table is a child of it rather than a block after it.
    let quote = fx.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
    let ast = fx.ed.ast_view();
    let mut inside = false;
    let mut c = ast.nodes[quote as usize].first_child;
    while let Some(id) = c {
        if ast.kind(id).tag() == Tag::Table {
            inside = true;
        }
        c = ast.nodes[id as usize].next_sibling;
    }
    assert!(inside);
}

#[test]
fn inserttable_a_caret_on_a_blank_line_between_blocks_puts_the_table_on_that_line() {
    // The shared placement, so the same correction: one blank each side.
    let mut fx = mk("a\n\nb\n", Format::Markdown);
    fx.ed.insert_table(2, 1, 1).unwrap();
    fx.expect("a\n\n|  |\n| --- |\n|  |\n\nb\n");
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
}

#[test]
fn inserttable_an_empty_document_is_a_legitimate_place_for_one() {
    let mut fx = mk("", Format::Markdown);
    fx.ed.insert_table(0, 1, 1).unwrap();
    fx.expect("|  |\n| --- |\n|  |\n");
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
}

#[test]
fn inserttable_the_table_it_writes_is_one_the_table_ops_can_edit() {
    // The point of going through `table_edit.emit`: what is minted is what
    // `extract` reads back, so a row can go in without a hand-typed table.
    let mut fx = mk("", Format::Markdown);
    fx.ed.insert_table(0, 1, 2).unwrap();
    fx.ed.table_insert_row(2, true).unwrap(); // caret in the first header cell
    fx.expect("|  |  |\n| --- | --- |\n|  |  |\n|  |  |\n");
}

#[test]
fn inserttable_zero_rows_or_zero_columns_is_invalidshape_and_touches_nothing() {
    let mut fx = mk("a\n", Format::Markdown);
    assert_eq!(fx.ed.insert_table(0, 0, 2), Err(Error::InvalidShape));
    assert_eq!(fx.ed.insert_table(0, 2, 0), Err(Error::InvalidShape));
    fx.expect("a\n");
}

#[test]
fn inserttable_a_format_with_no_table_spelling_refuses_before_it_reads_anything() {
    let mut fx = mk("<p>ab</p>\n", Format::Html);
    assert_eq!(fx.ed.insert_table(4, 1, 1), Err(Error::UnsupportedFormat));
    fx.expect("<p>ab</p>\n");
}

/// The name a reparsed container carries, wherever the format put it: its own
/// `name`, or the `class` that holds it where the format has no other place
/// (djot's fence is anonymous, AsciiDoc's open block carries a style). The
/// disjunction `Syntax.names_leaf_containers` claims, asked of a real tree.

#[test]
fn insertdirective_a_named_leaf_container_of_its_own_after_the_caret_s_block() {
    let mut fx = mk_with("a\n\nb\n", Format::Markdown, directives_cfg());
    fx.ed.insert_directive(0, b"page-break", None, &[]).unwrap();
    fx.expect("a\n\n::page-break\n\nb\n");
    // A directive to the parser, not a paragraph that starts with two colons —
    // which is what the same bytes are without the extension, and the whole
    // reason the gate exists.
    let id = fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).expect("NoDirective");
    assert_eq!(Form::BlockLeaf, fx.ed.ast_view().kind(id).container_form().unwrap());
}

#[test]
fn insertdirective_a_caret_on_the_blank_line_between_blocks_adds_no_second_blank() {
    // The separator that is already there is the one the block gets; the
    // gesture writes what is missing and nothing more (`insertBlockAfter`).
    let mut fx = mk_with("a\n\nb\n", Format::Markdown, directives_cfg());
    fx.ed.insert_directive(2, b"page-break", None, &[]).unwrap();
    fx.expect("a\n\n::page-break\n\nb\n");
    assert!(fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).is_some());
}

#[test]
fn insertdirective_an_unterminated_last_line_is_ended_before_the_blank() {
    let mut fx = mk_with("a", Format::Markdown, directives_cfg());
    fx.ed.insert_directive(0, b"page-break", None, &[]).unwrap();
    fx.expect("a\n\n::page-break\n");
    assert!(fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).is_some());
}

#[test]
fn insertdirective_inside_a_quote_every_line_carries_the_marker() {
    let mut md = mk_with("> a\n", Format::Markdown, directives_cfg());
    md.ed.insert_directive(2, b"page-break", None, &[]).unwrap();
    md.expect("> a\n>\n> ::page-break\n");
    assert!(md.find(KindRef::ContainerNamed(b"page-break".to_vec())).is_some());

    // Djot's spelling is TWO lines, which is the case a prefix written once
    // would get wrong: a marker on the opener alone ends the quote before the
    // closing fence, leaving `:::` outside it as a block of its own.
    let mut dj = mk("> a\n", Format::Djot);
    dj.ed.insert_directive(2, b"page-break", None, &[]).unwrap();
    dj.expect("> a\n>\n> ::: page-break\n> :::\n");
    let quote = dj.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
    let ast = dj.ed.ast_view();
    let mut inside = false;
    let mut c = ast.nodes[quote as usize].first_child;
    while let Some(id) = c {
        if ast.kind(id).tag() == Tag::Container {
            inside = true;
        }
        c = ast.nodes[id as usize].next_sibling;
    }
    assert!(inside);
}

#[test]
fn insertdirective_an_empty_document_is_a_legitimate_place_for_one() {
    let mut fx = mk_with("", Format::Markdown, directives_cfg());
    fx.ed.insert_directive(0, b"page-break", None, &[]).unwrap();
    fx.expect("::page-break\n");
    assert!(fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).is_some());
}

#[test]
fn insertdirective_a_label_and_attributes_ride_into_the_format_s_own_spelling() {
    let mut fx = mk_with("a\n", Format::Markdown, directives_cfg());
    fx.ed.insert_directive(0, b"embed", Some(b"Contents"), &[kv("src", "x.html")]).unwrap();
    // The serializer quotes a value it cannot read back bare; the assertion is
    // its spelling, not a second guess at one.
    fx.expect("a\n\n::embed[Contents]{src=\"x.html\"}\n");
    let id = fx.find(KindRef::ContainerNamed(b"embed".to_vec())).expect("NoDirective");
    let ast = fx.ed.ast_view();
    eq_str("x.html", ast.attrs_of(id).get(b"src").unwrap());
    // The label is the container's inline children, which is where the
    // brackets printed it from.
    let child = ast.nodes[id as usize].first_child.expect("NoLabel");
    eq_str("Contents", ast.kind(child).str_());
}

#[test]
fn insertdirective_without_the_directives_extension_markdown_refuses_and_touches_nothing() {
    // The gate's whole point: these bytes reparse as a paragraph of colons
    // there, so writing them would be a gesture the document cannot hold.
    let mut fx = mk("a\n", Format::Markdown);
    assert_eq!(fx.ed.insert_directive(0, b"page-break", None, &[]), Err(Error::UnsupportedFormat));
    fx.expect("a\n");

    let mut cm = mk("a\n", Format::Commonmark);
    assert_eq!(cm.ed.insert_directive(0, b"page-break", None, &[]), Err(Error::UnsupportedFormat));
    cm.expect("a\n");
}

#[test]
fn insertdirective_djot_spells_an_empty_fence_whose_name_comes_back_as_a_class() {
    let mut fx = mk("a\n", Format::Djot);
    fx.ed.insert_directive(0, b"page-break", None, &[]).unwrap();
    fx.expect("a\n\n::: page-break\n:::\n");
    // Djot's div is ANONYMOUS — it carries its identity as a class — so the
    // reparsed container is nameless and the class is where the name is. That
    // is the caveat `Syntax.names_leaf_containers` states.
    expect_container_carrying(&fx, "page-break");
    let id = fx.find(KindRef::Tag(Tag::Container)).expect("NoContainer");
    eq_str("", fx.ed.ast_view().kind(id).container_name());
}

#[test]
fn insertdirective_html_spells_a_tag_pair_its_parser_names() {
    let mut fx = mk("<p>a</p>\n", Format::Html);
    fx.ed.insert_directive(0, b"page-break", None, &[]).unwrap();
    fx.expect("<p>a</p>\n\n<page-break></page-break>\n");
    // An unknown element is a container named for its tag — no table needed,
    // which is why HTML claims the field while spelling no directive syntax.
    assert!(fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).is_some());
}

#[test]
fn insertdirective_asciidoc_writes_the_spelling_it_has_and_an_open_block_where_it_has_none() {
    // `page-break` is a name AsciiDoc spells natively — `<<<` — and the
    // serializer writes that rather than a generic block. The gesture does not
    // know or care: it hands the node over and splices what comes back.
    let mut fx = mk("a\n", Format::Asciidoc);
    fx.ed.insert_directive(0, b"page-break", None, &[]).unwrap();
    fx.expect("a\n\n<<<\n");
    assert!(fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).is_some());

    // A name it has no spelling for becomes an open block carrying the name as
    // its STYLE, which reparses as a class — djot's caveat in AsciiDoc's
    // spelling.
    let mut em = mk("a\n", Format::Asciidoc);
    em.ed.insert_directive(0, b"embed", None, &[kv("src", "x.html")]).unwrap();
    em.expect("a\n\n[embed,src=x.html]\n--\n--\n");
    expect_container_carrying(&em, "embed");
    let id = em.find(KindRef::Tag(Tag::Container)).expect("NoContainer");
    eq_str("x.html", em.ed.ast_view().attrs_of(id).get(b"src").unwrap());
}

#[test]
fn insertdirective_a_name_outside_the_directive_grammar_is_refused_and_touches_nothing() {
    let mut fx = mk_with("a\n", Format::Markdown, directives_cfg());
    // There is no `::` without a name, so an empty one is the caller's error
    // rather than a nameless directive.
    assert_eq!(fx.ed.insert_directive(0, b"", None, &[]), Err(Error::InvalidName));
    // A line end would end the block inside its own opener, leaving the tail as
    // ordinary text — the same reason `insertLink` refuses one in a destination.
    assert_eq!(fx.ed.insert_directive(0, b"a\nb", None, &[]), Err(Error::InvalidName));
    // And the three that look harmless and are not. Each one is a DIFFERENT
    // wrong document per format, which is why the grammar is checked in the
    // editor rather than left to the serializer: `::a b` is a paragraph
    // holding an INLINE directive named `a`, `::]{` is no container at all,
    // and `::1x` is a paragraph (a name starts with a letter, which is what
    // keeps `:30` from being one).
    assert_eq!(fx.ed.insert_directive(0, b"a b", None, &[]), Err(Error::InvalidName));
    assert_eq!(fx.ed.insert_directive(0, b"]{", None, &[]), Err(Error::InvalidName));
    assert_eq!(fx.ed.insert_directive(0, b"1x", None, &[]), Err(Error::InvalidName));
    // A colon is the one Markdown's own `scanName` would take and djot would
    // not — `::: a:b` reparses as a paragraph — so a format-neutral gesture
    // refuses it too.
    assert_eq!(fx.ed.insert_directive(0, b"a:b", None, &[]), Err(Error::InvalidName));
    assert_eq!(fx.ed.insert_directive(9, b"a", None, &[]), Err(Error::InvalidRange));
    fx.expect("a\n");

    // What the grammar DOES admit, in every claiming format: letters, digits,
    // `-` and `_` after a leading letter.
    for fmt in [Format::Djot, Format::Html, Format::Asciidoc] {
        let mut ok = mk(if fmt == Format::Html { "<p>a</p>\n" } else { "a\n" }, fmt);
        ok.ed.insert_directive(0, b"x_embed-9", None, &[]).unwrap();
        expect_container_carrying(&ok, "x_embed-9");
    }
}

#[test]
fn insertdirective_a_label_the_brackets_cannot_hold_is_refused_and_touches_nothing() {
    let mut fx = mk_with("a\n", Format::Markdown, directives_cfg());
    assert_eq!(fx.ed.insert_directive(0, b"a", Some(b"x\ny"), &[]), Err(Error::InvalidLabel));
    // A bracket closes the `[…]` early: `::page-break[]]` reparses as an
    // INLINE directive with a stray `]` beside it, not as the block that was
    // asked for. Same reasoning as `insertFootnote`'s reference brackets.
    assert_eq!(fx.ed.insert_directive(0, b"page-break", Some(b"]"), &[]), Err(Error::InvalidLabel));
    assert_eq!(fx.ed.insert_directive(0, b"page-break", Some(b"[x"), &[]), Err(Error::InvalidLabel));
    fx.expect("a\n");

    // An EMPTY label is legitimate, and is a different document from no label.
    fx.ed.insert_directive(0, b"note", Some(b""), &[]).unwrap();
    fx.expect("a\n\n::note[]\n");
    assert!(fx.find(KindRef::ContainerNamed(b"note".to_vec())).is_some());
}

#[test]
fn insertdirective_asciidoc_s_native_spelling_keeps_the_name_and_drops_the_attributes() {
    // `<<<` is three characters with nowhere to hang a `src`, so the claim
    // `Syntax.names_leaf_containers` makes is the NAME's and not the
    // attributes'. Pinned here so the loss is stated rather than discovered:
    // the same name written as an open block (`insertDirective: AsciiDoc
    // writes the spelling it has`) carries them fine.
    let mut fx = mk("a\n", Format::Asciidoc);
    fx.ed.insert_directive(0, b"page-break", None, &[kv("src", "x.html")]).unwrap();
    fx.expect("a\n\n<<<\n");
    let id = fx.find(KindRef::ContainerNamed(b"page-break".to_vec())).expect("NoDirective");
    assert!(fx.ed.ast_view().attrs_of(id).get(b"src").is_none());
}

#[test]
fn insertlinebreak_splices_an_in_cell_br_that_reparses_as_a_hard_break_markdown() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    fx.ed.insert_line_break(3).unwrap(); // caret just after `a` in the header cell
    fx.expect("| a<br> | b |\n| --- | --- |\n| 1 | 2 |\n");
    // The point of the whole feature: a semantic break, not opaque raw HTML.
    assert!(fx.find(KindRef::Tag(Tag::HardBreak)).is_some());
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::RawInline));
}

#[test]
fn insertlinebreak_the_spliced_break_round_trips_the_source_re_serializes_byte_for_byte() {
    let mut fx = mk(TABLE_SRC, Format::Markdown);
    fx.ed.insert_line_break(3).unwrap();
    // A second identical op is refused only by geometry, not spelling; here we
    // just assert the edited source is itself a fixed point of a reparse — the
    // `<br>` the serializer would emit for the hard_break equals what we spliced.
    fx.expect("| a<br> | b |\n| --- | --- |\n| 1 | 2 |\n");
}

#[test]
fn insertlinebreak_outside_a_table_cell_is_noblock() {
    let mut fx = mk("just a paragraph\n", Format::Markdown);
    assert_eq!(fx.ed.insert_line_break(3), Err(Error::NoBlock));
}

#[test]
fn insertlinebreak_a_format_with_no_in_cell_break_spelling_is_refused_djot() {
    // Djot's `cell_line_break` is deliberately None — it has no idiomatic in-cell
    // break, so the gesture is a clean UnsupportedFormat regardless of the caret.
    let mut fx = mk("| a | b |\n| --- | --- |\n", Format::Djot);
    assert_eq!(fx.ed.insert_line_break(3), Err(Error::UnsupportedFormat));
}

#[test]
fn insertlinebreak_html_spells_the_in_cell_break_natively() {
    // `<br>` is not borrowed here the way it is in a GFM cell — it is simply how
    // HTML spells a break, and the parser reads it straight back.
    let mut fx = mk("<table><tr><td>a</td></tr></table>\n", Format::Html);
    // Caret just after the cell's `a`, which sits at 15.
    fx.ed.insert_line_break(16).unwrap();
    fx.expect("<table><tr><td>a<br></td></tr></table>\n");
    assert!(fx.find(KindRef::Tag(Tag::HardBreak)).is_some());
}

#[test]
fn insertlinebreak_off_cell_is_noblock_even_where_the_format_spells_one() {
    let mut fx = mk("<p>ab</p>\n", Format::Html);
    assert_eq!(fx.ed.insert_line_break(4), Err(Error::NoBlock));
}

// ── opening a container on a blank line ────────────────────────────────────
// `setBlock` has always opened `# ` where there is no block to convert; these
// are the same gesture for the three container buttons beside it, which used to
// answer `error.NoBlock` there and do nothing. See `openContainerOnBlankLine`.

#[test]
fn toggle_block_container_a_blank_line_opens_an_empty_container() {
    for fmt in [Format::Djot, Format::Markdown] {
        // Offset 2 is the blank line between the paragraphs: no block owns it.
        let mut q = mk("a\n\nb\n", fmt);
        toggle_container(&mut q, 2, 2, ContainerKind::BlockQuote).unwrap();
        q.expect("a\n\n> \nb\n");

        let mut b = mk("a\n\nb\n", fmt);
        toggle_container(&mut b, 2, 2, ContainerKind::BulletList).unwrap();
        b.expect("a\n\n- \nb\n");

        let mut o = mk("a\n\nb\n", fmt);
        toggle_container(&mut o, 2, 2, ContainerKind::OrderedList).unwrap();
        o.expect("a\n\n1. \nb\n");
    }
}

#[test]
fn toggle_block_container_an_opened_container_reparses_as_one() {
    // Source that merely looks right isn't enough — an empty list item cannot
    // interrupt a paragraph, so a marker written flush under one is read as
    // that paragraph's own text and the document gains no list at all. This is
    // what the blank line above the marker is for.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("a\n\nb\n", fmt);
        toggle_container(&mut fx, 2, 2, ContainerKind::BulletList).unwrap();
        assert!(fx.find(KindRef::Tag(Tag::BulletList)).is_some());
        // And the paragraph below stays its own block rather than being adopted
        // as the empty item's lazy continuation.
        assert!(fx.find(KindRef::Tag(Tag::Para)).is_some());
    }
}

#[test]
fn toggle_block_container_a_bullet_opened_on_a_quote_s_blank_line_stays_in_the_quote() {
    // The line's own `>` is kept and the marker written after it, with the
    // space djot needs after the last `>` even though the blank line carries
    // none — `openBlockOnBlankLine`'s rule, for the same reason.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("> a\n>\n", fmt);
        toggle_container(&mut fx, 4, 4, ContainerKind::BulletList).unwrap();
        fx.expect("> a\n>\n> - \n");
        assert!(fx.find(KindRef::Tag(Tag::BlockQuote)).is_some());
        assert!(fx.find(KindRef::Tag(Tag::BulletList)).is_some());
    }
}

#[test]
fn toggle_block_container_no_blank_line_is_added_when_one_is_already_above() {
    // `a\n\n\n\nb\n` — the caret's blank line already has a blank above it, so
    // the marker is written in place rather than pushed down another line.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("a\n\n\n\nb\n", fmt);
        toggle_container(&mut fx, 3, 3, ContainerKind::BulletList).unwrap();
        fx.expect("a\n\n- \n\nb\n");
    }
}

#[test]
fn toggle_block_container_the_same_button_twice_takes_the_empty_container_back_off() {
    // A toggle has to go both ways. Quote pressed twice used to nest `> > ` and
    // Bulleted pressed twice failed outright, leaving a button that could not be
    // un-pressed until the author typed something into it.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut q = mk("a\n\nb\n", fmt);
        toggle_container(&mut q, 2, 2, ContainerKind::BlockQuote).unwrap();
        q.expect("a\n\n> \nb\n");
        toggle_container(&mut q, 5, 5, ContainerKind::BlockQuote).unwrap();
        q.expect("a\n\n\nb\n");

        let mut b = mk("a\n\nb\n", fmt);
        toggle_container(&mut b, 2, 2, ContainerKind::BulletList).unwrap();
        b.expect("a\n\n- \nb\n");
        toggle_container(&mut b, 5, 5, ContainerKind::BulletList).unwrap();
        b.expect("a\n\n\nb\n");
    }
}

#[test]
fn toggle_block_container_the_other_list_button_converts_an_empty_marker() {
    // What the non-empty path already does for a real list, at the one size it
    // could not reach.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("a\n\nb\n", fmt);
        toggle_container(&mut fx, 2, 2, ContainerKind::BulletList).unwrap();
        toggle_container(&mut fx, 5, 5, ContainerKind::OrderedList).unwrap();
        fx.expect("a\n\n1. \nb\n");
        toggle_container(&mut fx, 6, 6, ContainerKind::BulletList).unwrap();
        fx.expect("a\n\n- \nb\n");
    }
}

#[test]
fn toggle_block_container_un_quoting_an_empty_nested_quote_leaves_the_outer_one() {
    // The innermost marker comes off, and the line it leaves behind is spelled
    // `>` — a quote's own blank line — not `> ` with a stranded space.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("> a\n> > \n", fmt);
        toggle_container(&mut fx, 8, 8, ContainerKind::BlockQuote).unwrap();
        fx.expect("> a\n>\n");
    }
}

#[test]
fn toggle_block_container_a_blank_line_inside_a_code_block_wraps_the_block_not_the_line() {
    // The other half of "a blank line opens a container": this blank is the
    // listing's own body, and `coveredBlocks` resolves it to the code block
    // rather than to nothing — so the gesture wraps the whole fence and never
    // reaches `openContainerOnBlankLine`. Writing a marker into the blank
    // instead would add no list and corrupt the code.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("```\na\n\nb\n```\n", fmt);
        toggle_container(&mut fx, 6, 6, ContainerKind::BulletList).unwrap();
        fx.expect("- ```\n  a\n\n  b\n  ```\n");
        assert!(fx.find(KindRef::Tag(Tag::CodeBlock)).is_some());
    }
}

#[test]
fn toggle_block_container_a_inside_a_code_block_is_not_a_quote() {
    // The AST has no block_quote here — the `> a` is code_block TEXT. Detection
    // by string-matching the line prefix would "toggle off" a quote that was
    // never there and corrupt the code; the AST walk quotes the block instead.
    let mut fx = mk("```\n> a\n```\n", Format::Djot);
    toggle_container(&mut fx, 4, 7, ContainerKind::BlockQuote).unwrap();
    fx.expect("> ```\n> > a\n> ```\n");
}

#[test]
fn toggle_block_container_rejects_a_format_with_no_line_marker_spelling() {
    let mut fx = mk("<r>ab</r>", Format::Xml);
    assert_eq!(toggle_container(&mut fx, 3, 5, ContainerKind::BlockQuote), Err(Error::UnsupportedFormat));
}

// ── links ──────────────────────────────────────────────────────────────────

#[test]
fn insert_link_wraps_a_range_as_link_text() {
    let mut fx = mk("a word b\n", Format::Djot);
    insert_link(&mut fx, 2, 6, "http://x.dev").unwrap();
    fx.expect("a [word](http://x.dev) b\n");
}

// The autolinkable/not split, across both formats. A childless `[](dest)` has no
// text to render or put a caret in, so an empty range spells the destination
// canonically instead — and only the reparsed KIND proves which spelling landed.

#[test]
fn insert_link_an_empty_range_autolinks_an_absolute_url_both_formats() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("ab\n", fmt);
        insert_link(&mut fx, 1, 1, "https://x.dev").unwrap();
        fx.expect("a<https://x.dev>b\n");
        fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "https://x.dev");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::Link));
    }
}

#[test]
fn insert_link_an_empty_range_autolinks_a_bare_email_both_formats() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("ab\n", fmt);
        insert_link(&mut fx, 1, 1, "a@b.dev").unwrap();
        fx.expect("a<a@b.dev>b\n");
        fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Email), "a@b.dev");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::Link));
    }
}

#[test]
fn insert_link_the_formats_disagree_on_what_a_mailto_autolink_is() {
    // Markdown reads `mailto:a@b.dev` as a URI (it has a scheme); djot classifies
    // on content and sees the `@` first. Both autolink it — as different kinds.
    // This is why `autolinkCovering` matches url AND email in both formats.
    let mut md = mk("ab\n", Format::Markdown);
    insert_link(&mut md, 1, 1, "mailto:a@b.dev").unwrap();
    md.expect("a<mailto:a@b.dev>b\n");
    md.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "mailto:a@b.dev");

    let mut dj = mk("ab\n", Format::Djot);
    insert_link(&mut dj, 1, 1, "mailto:a@b.dev").unwrap();
    dj.expect("a<mailto:a@b.dev>b\n");
    dj.expect_spelled(KindRef::TextLeaf(TextLeafKind::Email), "mailto:a@b.dev");
}

#[test]
fn insert_link_a_bare_word_is_not_autolinkable_foo_would_be_raw_html() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("ab\n", fmt);
        insert_link(&mut fx, 1, 1, "foo").unwrap();
        // Falls back to the doubled spelling, destination as text.
        fx.expect("a[foo](foo)b\n");
        fx.expect_link_dest("foo");
    }
}

#[test]
fn insert_link_a_relative_path_is_not_autolinkable_it_would_go_literal() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("ab\n", fmt);
        insert_link(&mut fx, 1, 1, "foo/bar").unwrap();
        fx.expect("a[foo/bar](foo/bar)b\n");
        fx.expect_link_dest("foo/bar");
    }
}

#[test]
fn insert_link_a_destination_with_a_space_falls_back_escaped_per_format() {
    // `<x dev>` is an autolink in neither format (the space ends the scan), so
    // this lands on `[dest](dest)` — where Markdown still needs its angle form
    // for the destination itself.
    let mut dj = mk("ab\n", Format::Djot);
    insert_link(&mut dj, 1, 1, "x dev").unwrap();
    dj.expect("a[x dev](x dev)b\n");
    dj.expect_spelled(KindRef::Tag(Tag::Link), "x dev");
    dj.expect_link_text("x dev");

    let mut md = mk("ab\n", Format::Markdown);
    insert_link(&mut md, 1, 1, "x dev").unwrap();
    md.expect("a[x dev](<x dev>)b\n");
    md.expect_spelled(KindRef::Tag(Tag::Link), "x dev");
    md.expect_link_text("x dev");
}

#[test]
fn insert_link_re_pointing_a_text_less_link_also_gets_the_canonical_spelling() {
    // Keyed on the TEXT being empty, not the range — a `[](old)` left by an
    // older twig has the same childless-link problem a bare caret does.
    let mut fx = mk("a [](old) b\n", Format::Djot);
    insert_link(&mut fx, 3, 3, "https://x.dev").unwrap();
    fx.expect("a <https://x.dev> b\n");
    fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "https://x.dev");
}

#[test]
fn insert_link_an_email_autolink_re_points_like_a_url_one() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("see <a@b.dev> ok\n", fmt);
        insert_link(&mut fx, 8, 8, "c@d.dev").unwrap();
        fx.expect("see <c@d.dev> ok\n");
        fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Email), "c@d.dev");
    }
}

#[test]
fn insert_link_a_mailto_autolink_re_points_though_the_formats_disagree_on_its_kind() {
    // The node kind is not a property of the destination: djot calls this an
    // `email`, Markdown a `url`. Matching one kind per format would leave the
    // other format's `<mailto:…>` to be corrupted exactly as before.
    let mut dj = mk("see <mailto:a@b.dev> ok\n", Format::Djot);
    insert_link(&mut dj, 10, 10, "mailto:c@d.dev").unwrap();
    dj.expect("see <mailto:c@d.dev> ok\n");
    dj.expect_spelled(KindRef::TextLeaf(TextLeafKind::Email), "mailto:c@d.dev");

    let mut md = mk("see <mailto:a@b.dev> ok\n", Format::Markdown);
    insert_link(&mut md, 10, 10, "mailto:c@d.dev").unwrap();
    md.expect("see <mailto:c@d.dev> ok\n");
    md.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "mailto:c@d.dev");
}

#[test]
fn insert_link_an_autolink_s_boundaries_read_like_a_link_s_start_in_end_out() {
    // The chain's own half-open rule, so both re-point paths agree: a caret AT
    // `span.start` is inside the node, one at `span.end` belongs to the next
    // sibling and means "a new link here".
    for fmt in [Format::Djot, Format::Markdown] {
        let mut at_start = mk("see <https://x.dev> ok\n", fmt);
        insert_link(&mut at_start, 4, 4, "https://y.dev").unwrap();
        at_start.expect("see <https://y.dev> ok\n");

        let mut at_end = mk("see <https://x.dev> ok\n", fmt);
        insert_link(&mut at_end, 19, 19, "https://y.dev").unwrap();
        at_end.expect("see <https://x.dev><https://y.dev> ok\n");
    }
}

#[test]
fn insert_link_a_selection_over_half_an_autolink_s_url_re_points_it_never_splices_into_it() {
    // The repro: selecting the back half of the URL used to splice a link into
    // the middle of it — `see <https://x[.dev](https://y.dev)> ok`. The `<…>`
    // still closes, so that reparsed as ONE `url` whose destination was the
    // garbage in between: the caller's link silently gone, replaced by a URL
    // pointing somewhere nobody asked for, with the autolink intact to hide it.
    for fmt in [Format::Djot, Format::Markdown] {
        // bytes 14..18 are `.dev`, inside the URL.
        let mut back = mk("see <https://x.dev> ok\n", fmt);
        insert_link(&mut back, 14, 18, "https://y.dev").unwrap();
        back.expect("see <https://y.dev> ok\n");

        // …and the front half (`https://x`, 5..14), which mangled the autolink
        // into literal text instead.
        let mut front = mk("see <https://x.dev> ok\n", fmt);
        insert_link(&mut front, 5, 14, "https://y.dev").unwrap();
        front.expect("see <https://y.dev> ok\n");
    }
}

#[test]
fn insert_link_a_selection_containing_an_autolink_whole_still_wraps() {
    // The boundary case of the refusal: this splices at the autolink's EDGES, so
    // nothing is corrupted and the autolink stays as the link's text. The
    // refusal must not swallow ordinary selections that happen to contain a URL.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("see <https://x.dev> ok\n", fmt);
        insert_link(&mut fx, 0, 22, "https://y.dev").unwrap();
        fx.expect("[see <https://x.dev> ok](https://y.dev)\n");
    }
}

#[test]
fn insert_link_re_points_an_existing_link_instead_of_nesting_one() {
    let mut fx = mk("a [word](old) b\n", Format::Djot);
    insert_link(&mut fx, 3, 7, "new").unwrap();
    fx.expect("a [word](new) b\n");
    fx.expect_link_dest("new");
}

#[test]
fn insert_link_a_caret_in_an_autolink_re_points_it_not_its_url_text() {
    // Without the autolink path this splices into the middle of the URL:
    // `see <https<https://y.dev>://x.dev> ok`.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("see <https://x.dev> ok\n", fmt);
        insert_link(&mut fx, 10, 10, "https://y.dev").unwrap();
        fx.expect("see <https://y.dev> ok\n");
        fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "https://y.dev");
    }
}

#[test]
fn insert_link_re_pointing_an_autolink_respells_it_for_the_new_destination() {
    // The new destination isn't autolinkable, so the node has to become a link —
    // a `<foo/bar>` would go literal.
    let mut fx = mk("see <https://x.dev> ok\n", Format::Djot);
    insert_link(&mut fx, 10, 10, "foo/bar").unwrap();
    fx.expect("see [foo/bar](foo/bar) ok\n");
    fx.expect_link_dest("foo/bar");
}

#[test]
fn insert_link_a_selection_of_a_whole_autolink_re_points_it_like_a_caret() {
    let mut fx = mk("see <https://x.dev> ok\n", Format::Djot);
    insert_link(&mut fx, 4, 19, "https://y.dev").unwrap();
    fx.expect("see <https://y.dev> ok\n");
    fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "https://y.dev");
}

#[test]
fn insert_link_a_selection_running_from_text_into_the_middle_of_a_url_is_refused() {
    // Not contained, so there is nothing to re-point — half the selection is real
    // text — and no spelling that leaves the URL intact. Both ends are checked:
    // the offset landing inside can be either one, and only `start` is on the
    // caller's own ancestor chain.
    for fmt in [Format::Djot, Format::Markdown] {
        // `[see <https` — ends strictly inside the URL.
        let mut left = mk("see <https://x.dev> ok\n", fmt);
        assert_eq!(insert_link(&mut left, 0, 10, "https://y.dev"), Err(Error::NotEditable));
        left.expect("see <https://x.dev> ok\n");

        // `.dev> ok` — starts strictly inside the URL.
        let mut right = mk("see <https://x.dev> ok\n", fmt);
        assert_eq!(insert_link(&mut right, 14, 22, "https://y.dev"), Err(Error::NotEditable));
        right.expect("see <https://x.dev> ok\n");
    }
}

#[test]
fn insert_link_a_caret_in_an_autolink_inside_a_link_re_points_the_link() {
    // A link's text is separable from its destination, so re-pointing it keeps
    // text that re-pointing the autolink would discard.
    let mut fx = mk("a [<https://x.dev>](d) b\n", Format::Djot);
    insert_link(&mut fx, 10, 10, "new").unwrap();
    fx.expect_link_dest("new");
    // The autolink survives as the link's text.
    fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::Url), "https://x.dev");
}

// The escaping tests. Each asserts on the DESTINATION THE PARSER READS BACK, not
// the bytes: an unescaped `)` ends the link early and leaves the tail as literal
// text, which source-only assertions cheerfully miss.

#[test]
fn insert_link_escapes_parens_so_the_destination_survives_djot() {
    let mut fx = mk("ab\n", Format::Djot);
    insert_link(&mut fx, 0, 2, "http://x.dev/a(b)c").unwrap();
    fx.expect_link_dest("http://x.dev/a(b)c");
}

#[test]
fn insert_link_escapes_parens_so_the_destination_survives_markdown() {
    let mut fx = mk("ab\n", Format::Markdown);
    insert_link(&mut fx, 0, 2, "http://x.dev/a(b)c").unwrap();
    fx.expect_link_dest("http://x.dev/a(b)c");
}

#[test]
fn insert_link_carries_whitespace_per_format_djot_literal_markdown_angled() {
    // Markdown ends a destination at the first space, so it must move into the
    // `<…>` form. Djot gives `<…>` no meaning there, so wrapping would corrupt
    // the URL — it escapes in place instead. Same input, two right answers.
    let mut md = mk("ab\n", Format::Markdown);
    insert_link(&mut md, 0, 2, "a b").unwrap();
    md.expect("[ab](<a b>)\n");
    md.expect_link_dest("a b");

    let mut dj = mk("ab\n", Format::Djot);
    insert_link(&mut dj, 0, 2, "a b").unwrap();
    dj.expect_link_dest("a b");
}

#[test]
fn insert_link_escapes_the_angle_form_s_own_delimiters_markdown() {
    let mut fx = mk("ab\n", Format::Markdown);
    insert_link(&mut fx, 0, 2, "a <b> c").unwrap();
    fx.expect_link_dest("a <b> c");
}

#[test]
fn insert_link_handles_whitespace_and_a_paren_together_markdown() {
    // Inside the angle form the parens need NO escape — the destination ends at
    // the `>` — so escaping them there would put a literal backslash in the URL.
    let mut fx = mk("ab\n", Format::Markdown);
    insert_link(&mut fx, 0, 2, "a (b) c").unwrap();
    fx.expect_link_dest("a (b) c");
}

#[test]
fn insert_link_escapes_the_non_paren_bytes_that_also_end_a_destination() {
    // Markdown reads a `<` as the START of the angle form even mid-destination;
    // djot's destination is still scanned for inline openers, so a `[` or a
    // backtick there swallows the `)`.
    let mut md = mk("ab\n", Format::Markdown);
    insert_link(&mut md, 0, 2, "http://x.dev/a<b").unwrap();
    md.expect_link_dest("http://x.dev/a<b");

    let mut dj = mk("ab\n", Format::Djot);
    insert_link(&mut dj, 0, 2, "http://x.dev/a[b`c").unwrap();
    dj.expect_link_dest("http://x.dev/a[b`c");
}

#[test]
fn insert_link_escapes_an_entity_so_markdown_can_t_decode_the_destination() {
    // `a&amp;b` handed in would come back out as `a&b` — corrupting the URL
    // rather than breaking the link, the quieter of the two failures. Djot has no
    // entities and leaves `&` alone.
    let mut fx = mk("ab\n", Format::Markdown);
    insert_link(&mut fx, 0, 2, "http://x.dev/?a=1&amp;b=2").unwrap();
    fx.expect_link_dest("http://x.dev/?a=1&amp;b=2");
}

#[test]
fn insert_link_round_trips_a_backslash_in_the_destination() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("ab\n", fmt);
        insert_link(&mut fx, 0, 2, "http://x.dev/a\\b").unwrap();
        fx.expect_link_dest("http://x.dev/a\\b");
    }
}

#[test]
fn insert_link_the_doubled_destination_is_escaped_for_the_text_position_too() {
    // `dest` repurposed as text needs the TEXT alphabet, not the destination one
    // — an unescaped `*` there would open emphasis and eat the link's text.
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("ab\n", fmt);
        insert_link(&mut fx, 1, 1, "a*b*c").unwrap();
        fx.expect_link_dest("a*b*c");
        fx.expect_link_text("a*b*c");
    }
}

#[test]
fn insert_link_an_empty_range_round_trips_any_destination_both_formats() {
    // The property both escape sets exist to hold: whichever spelling the op
    // picks, the destination the parser reads back is the one handed in. Every
    // ASCII metacharacter either format has an opinion about is in here.
    let dests = [
        "https://x.dev", "mailto:a@b.dev",   "a@b.dev",                 "foo",
        "./rel/path.md", "x dev",            "a)b(c",                   "a[b",
        "a`b",           "a<b",              "a>b",                     "#anchor",
        "../up.md",      "path/to/f (1).md", "a\\b",                    "a{b}c",
        "a*b*c",         "a_b_c",            "a]b",                     "a&amp;b",
        "a b)c",         "a~b",              "a^b",                     "a\"b",
        "a'b",           "a--b",             "a...b",                   "a:b",
        "a$b",           "a!b",              "a|b",                     "a%20b",
        "a b<c>d",       "a=b+c",            "https://x.dev?a=1&b=2#f",
    ];
    for fmt in [Format::Djot, Format::Markdown] {
        for d in dests {
            let mut fx = mk("ab\n", fmt);
            insert_link(&mut fx, 1, 1, d).unwrap();
            fx.expect_dest_round_trip(d);
        }
    }
}

#[test]
fn insert_link_rejects_a_newline_in_the_destination_and_an_unspellable_format() {
    let mut fx = mk("ab\n", Format::Djot);
    assert_eq!(insert_link(&mut fx, 0, 2, "a\nb"), Err(Error::InvalidDestination));
    assert_eq!(insert_link(&mut fx, 0, 2, "a\rb"), Err(Error::InvalidDestination));
    fx.expect("ab\n");

    let mut xml = mk("<r>ab</r>", Format::Xml);
    assert_eq!(insert_link(&mut xml, 3, 5, "http://x.dev"), Err(Error::UnsupportedFormat));
}

// ── images ─────────────────────────────────────────────────────────────────
// An image destination is the same grammar production as a link's, so these
// mirror the link-destination cases above. The point of the op existing at all is
// that a caller cannot spell them: the correct answer differs per format, and
// getting it wrong yields text rather than an image.

#[test]
fn insert_image_spells_an_image_with_the_selection_as_alt_text() {
    let mut fx = mk("a word b\n", Format::Djot);
    insert_image(&mut fx, 2, 6, "cat.png").unwrap();
    fx.expect("a ![word](cat.png) b\n");
    fx.expect_spelled(KindRef::Tag(Tag::Image), "cat.png");
}

#[test]
fn insert_image_an_empty_range_is_a_perfectly_good_image() {
    // Unlike a link, where `[](dest)` has nothing to click and `insert_link`
    // therefore spells an autolink instead.
    let mut fx = mk("ab\n", Format::Markdown);
    insert_image(&mut fx, 1, 1, "cat.png").unwrap();
    fx.expect("a![](cat.png)b\n");
    fx.expect_spelled(KindRef::Tag(Tag::Image), "cat.png");
}

#[test]
fn insert_image_whitespace_in_the_destination_takes_the_format_s_spelling() {
    // The bug this op exists to make impossible. Markdown ends a destination at
    // the first space, so `![](my cat.png)` is not an image at all; djot gives
    // `<…>` no meaning, so wrapping there would point at the literal characters.
    let mut md = mk("w\n", Format::Markdown);
    insert_image(&mut md, 0, 1, "my cat.png").unwrap();
    md.expect("![w](<my cat.png>)\n");
    md.expect_spelled(KindRef::Tag(Tag::Image), "my cat.png");

    let mut dj = mk("w\n", Format::Djot);
    insert_image(&mut dj, 0, 1, "my cat.png").unwrap();
    dj.expect("![w](my cat.png)\n");
    dj.expect_spelled(KindRef::Tag(Tag::Image), "my cat.png");
}

#[test]
fn insert_image_a_paren_in_the_destination_is_escaped_not_left_to_close_early() {
    let mut fx = mk("w\n", Format::Djot);
    insert_image(&mut fx, 0, 1, "a)b.png").unwrap();
    fx.expect("![w](a\\)b.png)\n");
    fx.expect_spelled(KindRef::Tag(Tag::Image), "a)b.png");
}

#[test]
fn insert_image_refuses_a_newline_destination_and_a_parse_only_format() {
    let mut fx = mk("ab\n", Format::Djot);
    assert_eq!(insert_image(&mut fx, 0, 2, "a\nb.png"), Err(Error::InvalidDestination));
    assert_eq!(insert_image(&mut fx, 0, 2, "a\rb.png"), Err(Error::InvalidDestination));
    fx.expect("ab\n");

    let mut xml = mk("<r>ab</r>", Format::Xml);
    assert_eq!(insert_image(&mut xml, 3, 5, "cat.png"), Err(Error::UnsupportedFormat));
}

#[test]
fn insert_link_html_builds_the_link_over_the_selection_and_prints_it() {
    // No `[text](dest)` alphabet — the destination lives in an attribute — so
    // the covered inline nodes go under a `link` node and `renderBlock` prints
    // it. The mark is re-spelled from the tree and the destination is read
    // back out of the attribute.
    let mut fx = mk("<p>see <em>this</em> now</p>\n", Format::Html);
    let start = find_sub(fx.ed.source_bytes(), b"<em>").unwrap();
    insert_link(&mut fx, start, start + 13, "https://x.dev/a?b=c&d").unwrap();
    fx.expect("<p>see <a href=\"https://x.dev/a?b=c&amp;d\"><em>this</em></a> now</p>\n");
    fx.expect_link_dest("https://x.dev/a?b=c&d");
    assert!(fx.find(KindRef::Mark(InlineMark::Emph)).is_some());
}

#[test]
fn insert_link_html_takes_the_covered_part_of_a_text_run_and_refuses_a_cut_through_anything_e() {
    let mut fx = mk("<p>a word b</p>\n", Format::Html);
    insert_link(&mut fx, 5, 9, "d").unwrap();
    fx.expect("<p>a <a href=\"d\">word</a> b</p>\n");
    // Into the middle of a mark: the mark's text cannot be half a link.
    let mut em = mk("<p>a <em>word</em> b</p>\n", Format::Html);
    assert_eq!(insert_link(&mut em, 3, 11, "d"), Err(Error::NotEditable));
    em.expect("<p>a <em>word</em> b</p>\n");
    // Into a run spelling a character as an entity: a byte offset names no
    // character there, so the slice is refused rather than guessed.
    let mut ent = mk("<p>a &amp; b</p>\n", Format::Html);
    assert_eq!(insert_link(&mut ent, 3, 4, "d"), Err(Error::NotEditable));
    // Whole, the same run links fine.
    insert_link(&mut ent, 3, 12, "d").unwrap();
    ent.expect("<p><a href=\"d\">a &amp; b</a></p>\n");
    // Across two paragraphs there is no inline to cover.
    let mut two = mk("<p>a</p>\n<p>b</p>\n", Format::Html);
    assert_eq!(insert_link(&mut two, 3, 12, "d"), Err(Error::NotEditable));
}

#[test]
fn insert_link_html_re_points_an_existing_link_its_text_and_attributes_kept() {
    let mut fx = mk("<p><a class=\"x\" href=\"old\">t <em>e</em></a></p>\n", Format::Html);
    let t = find_sub(fx.ed.source_bytes(), b"t <em>").unwrap();
    insert_link(&mut fx, t, t + 1, "new").unwrap();
    // The destination is printed first: it is the node's, and `class` an
    // attribute that rode along.
    fx.expect("<p><a href=\"new\" class=\"x\">t <em>e</em></a></p>\n");
    fx.expect_link_dest("new");
    eq_str("x", fx.ed.ast_view().attrs_of(fx.find(KindRef::Tag(Tag::Link)).unwrap()).get(b"class").unwrap());
}

#[test]
fn insert_link_html_spells_an_empty_selection_as_a_link_whose_text_is_the_destination() {
    let mut fx = mk("<p>ab</p>\n", Format::Html);
    insert_link(&mut fx, 4, 4, "https://x.dev").unwrap();
    fx.expect("<p>a<a href=\"https://x.dev\">https://x.dev</a>b</p>\n");
    fx.expect_link_dest("https://x.dev");
    assert_eq!(insert_link(&mut fx, 4, 4, "a\nb"), Err(Error::InvalidDestination));
}

#[test]
fn insert_image_html_spells_the_selection_as_alt_text_the_destination_as_src() {
    let mut fx = mk("<p>a cat b</p>\n", Format::Html);
    insert_image(&mut fx, 5, 8, "cat & dog.png").unwrap();
    fx.expect("<p>a <img alt=\"cat\" src=\"cat &amp; dog.png\"> b</p>\n");
    fx.expect_spelled(KindRef::Tag(Tag::Image), "cat & dog.png");
    let mut empty = mk("<p>ab</p>\n", Format::Html);
    insert_image(&mut empty, 4, 4, "c.png").unwrap();
    empty.expect("<p>a<img alt=\"\" src=\"c.png\">b</p>\n");
}

#[test]
fn insert_link_asciidoc_prints_dest_text_through_its_renderer_and_reads_it_back() {
    // The alphabet path writes `[text](dest)`, which is not AsciiDoc's shape —
    // but the serializer's is, and the render path asks it.
    let mut fx = mk("see *this* now\n", Format::Asciidoc);
    insert_link(&mut fx, 4, 10, "https://x.dev").unwrap();
    fx.expect_link_dest("https://x.dev");
    assert!(fx.find(KindRef::Mark(InlineMark::Strong)).is_some());
    let mut img = mk("a cat b\n", Format::Asciidoc);
    insert_image(&mut img, 2, 5, "cat.png").unwrap();
    img.expect_spelled(KindRef::Tag(Tag::Image), "cat.png");
}

// ── literal text ─────────────────────────────────────────────────────────────
// The assertions read the REPARSED tree (via `expectVisibleText`), not the
// spelled source: source that merely holds a `\*` still has to prove it reparses
// to a literal `*` and not to emphasis. Both formats, because their inline
// alphabets diverge in exactly the bytes these escape.

#[test]
fn insert_literal_typed_markdown_specials_all_stay_literal() {
    let mut fx = mk("z\n", Format::Markdown);
    // Balanced emphasis, a code span, a full link, raw HTML and an entity — every
    // one would mint markup unescaped.
    let typed = "*b* _i_ `c` [t](u) <x> &amp;";
    insert_literal(&mut fx, 0, typed).unwrap();
    expect_visible_text(&fx, format!("{}{}", typed, "z"));
    for k in [KindRef::Mark(InlineMark::Emph), KindRef::Mark(InlineMark::Strong), KindRef::TextLeaf(TextLeafKind::Verbatim), KindRef::Tag(Tag::Link), KindRef::Tag(Tag::Image), KindRef::Tag(Tag::RawInline)] {
        fx.expect_no_node_of_kind(k);
    }
}

#[test]
fn insert_literal_a_typed_dollar_stays_literal_under_the_math_extension_and_bare_without_it() {
    let typed = "$x$ and $$y$$";
    let mut fx = mk_with("a \n", Format::Markdown, math_cfg());
    insert_literal(&mut fx, 2, typed).unwrap();
    fx.expect("a \\$x\\$ and \\$\\$y\\$\\$\n");
    expect_visible_text(&fx, format!("{}{}", "a ", typed));
    fx.expect_no_node_of_kind(KindRef::TextLeaf(TextLeafKind::InlineMath));
    fx.expect_no_node_of_kind(KindRef::TextLeaf(TextLeafKind::DisplayMath));

    // Without the extension a `$` is text, and a backslash before it would
    // only be noise in the source.
    let mut plain = mk("a \n", Format::Markdown);
    insert_literal(&mut plain, 2, typed).unwrap();
    plain.expect("a $x$ and $$y$$\n");
    expect_visible_text(&plain, format!("{}{}", "a ", typed));
}

#[test]
fn insert_link_a_destination_shown_as_text_keeps_its_dollars_literal_under_math() {
    let mut fx = mk_with("a \n", Format::Markdown, math_cfg());
    insert_link(&mut fx, 2, 2, "u$x$").unwrap();
    fx.expect_link_text("u$x$");
    fx.expect_link_dest("u$x$");
}

#[test]
fn insert_literal_typed_djot_specials_all_stay_literal() {
    let mut fx = mk("z\n", Format::Djot);
    // Djot's own marks plus its attribute braces and smart punctuation.
    let typed = "*b* _i_ `c` ^s^ ~t~ {=m=} \"q\" ...";
    insert_literal(&mut fx, 0, typed).unwrap();
    expect_visible_text(&fx, format!("{}{}", typed, "z"));
    for k in [KindRef::Mark(InlineMark::Emph), KindRef::Mark(InlineMark::Strong), KindRef::TextLeaf(TextLeafKind::Verbatim), KindRef::Mark(InlineMark::Superscript), KindRef::Mark(InlineMark::Subscript), KindRef::Mark(InlineMark::Mark)] {
        fx.expect_no_node_of_kind(k);
    }
}

#[test]
fn insert_literal_a_block_marker_escapes_at_a_line_start_in_both_formats() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("z\n", fmt);
        insert_literal(&mut fx, 0, "# ").unwrap();
        fx.expect("\\# z\n");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
    }
}

#[test]
fn insert_literal_the_same_marker_mid_line_is_ordinary_text_left_unescaped() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("az\n", fmt);
        insert_literal(&mut fx, 1, "# ").unwrap();
        // No backslash: a `#` after other text on the line opens nothing.
        fx.expect("a# z\n");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
    }
}

#[test]
fn insert_literal_leading_whitespace_still_counts_as_a_line_start() {
    // Markdown lets up to three spaces precede a block marker, so an insertion
    // sitting in that indent is still at a line start.
    let mut fx = mk("  z\n", Format::Markdown);
    insert_literal(&mut fx, 2, "# ").unwrap();
    fx.expect("  \\# z\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
}

#[test]
fn insert_literal_an_embedded_newline_re_enters_the_line_start_zone() {
    let mut fx = mk("z\n", Format::Markdown);
    // The first `#` is mid-line (after "a"); the second opens its own line.
    insert_literal(&mut fx, 0, "a # b\n# c").unwrap();
    fx.expect("a # b\n\\# cz\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
}

#[test]
fn insert_literal_a_lone_backslash_round_trips_as_a_backslash() {
    for fmt in [Format::Djot, Format::Markdown] {
        let mut fx = mk("z\n", fmt);
        insert_literal(&mut fx, 0, "a\\b").unwrap();
        fx.expect("a\\\\bz\n");
        expect_visible_text(&fx, "a\\bz");
    }
}

#[test]
fn insert_literal_html_spells_a_literal_with_entities_and_reads_it_back() {
    // No backslash to spell a literal with, so `renderText` is HTML's own:
    // the reparse decodes the entities back to the bytes that went in, and no
    // tag was minted on the way.
    // (No trailing newline: HTML's parser keeps inter-block whitespace as a
    // `str`, which would join the visible text below.)
    let mut fx = mk("<p>ab</p>", Format::Html);
    let typed = "<em>x</em> & 1 < 2 \\ # *y*";
    insert_literal(&mut fx, 4, typed).unwrap();
    fx.expect("<p>a&lt;em&gt;x&lt;/em&gt; &amp; 1 &lt; 2 \\ # *y*b</p>");
    expect_visible_text(&fx, format!("{}{}{}", "a", typed, "b"));
    fx.expect_no_node_of_kind(KindRef::Mark(InlineMark::Emph));
}

#[test]
fn insert_literal_a_parse_only_format_spells_no_literal() {
    let mut fx = mk("<r>ab</r>", Format::Xml);
    assert_eq!(insert_literal(&mut fx, 3, "x"), Err(Error::UnsupportedFormat));
}

#[test]
fn insert_literal_inside_a_code_span_the_bytes_are_written_as_they_are() {
    // A backslash inside a code span is a backslash — an escape there would
    // SHOW. The engine reports `verbatim` and the alphabet renderer writes the
    // run raw; the reparse proves the `*` is the code's text, not emphasis.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a `cd` e\n", fmt);
        insert_literal(&mut fx, 4, "*_").unwrap();
        fx.expect("a `c*_d` e\n");
        fx.expect_no_node_of_kind(KindRef::Mark(InlineMark::Emph));
        let id = fx.find(KindRef::TextLeaf(TextLeafKind::Verbatim)).expect("NoCode");
        eq_str("c*_d", fx.ed.ast_view().kind(id).text_leaf_text());
    }
    // A fenced body likewise, block markers included: `#` at column zero of a
    // listing is a `#`.
    let mut md = mk("```\nx\n```\n", Format::Markdown);
    insert_literal(&mut md, 4, "# ").unwrap();
    md.expect("```\n# x\n```\n");
    md.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
    // And HTML still escapes there, because `<pre>` decodes entities too.
    let mut html = mk("<pre><code>x</code></pre>\n", Format::Html);
    insert_literal(&mut html, 11, "<b>").unwrap();
    html.expect("<pre><code>&lt;b&gt;x</code></pre>\n");
}

#[test]
fn insert_literal_flush_against_a_code_span_s_delimiter_is_still_outside_it() {
    // `offset` at the opening backtick is BEFORE the span, so the `*` needs its
    // escape; the content span is what decides, not the node span.
    let mut fx = mk("a `c` e\n", Format::Markdown);
    insert_literal(&mut fx, 2, "*").unwrap();
    fx.expect("a \\*`c` e\n");
}

#[test]
fn insert_literal_an_offset_past_the_source_is_invalidrange() {
    let mut fx = mk("ab\n", Format::Markdown);
    assert_eq!(insert_literal(&mut fx, 99, "x"), Err(Error::InvalidRange));
    fx.expect("ab\n");
}

// ── thematic break ───────────────────────────────────────────────────────────

#[test]
fn thematic_break_lands_after_the_caret_s_block_blank_separated() {
    let mut md = mk("a\n\nb\n", Format::Markdown);
    md.ed.insert_thematic_break(0).unwrap();
    md.expect("a\n\n---\n\nb\n");

    let mut dj = mk("a\n\nb\n", Format::Djot);
    dj.ed.insert_thematic_break(0).unwrap();
    dj.expect("a\n\n* * *\n\nb\n");
}

#[test]
fn thematic_break_the_blank_line_above_is_what_keeps_from_being_a_setext_heading() {
    // Markdown's spelling is only a rule when a blank line precedes it: flush
    // against the paragraph, `---` underlines it into an `<h2>` and the
    // paragraph disappears into the heading. The reparsed KIND is the assertion,
    // not the bytes — both spellings "look right" in the source.
    let mut fx = mk("a\n", Format::Markdown);
    fx.ed.insert_thematic_break(0).unwrap();
    fx.expect("a\n\n---\n");
    assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
}

#[test]
fn thematic_break_an_unterminated_last_line_is_ended_before_the_blank_above() {
    // A document being typed has no newline after its last line yet. The blank
    // above was written as a bare `\n`, which on such a line only terminates
    // it: `a` gained `\n---\n` flush underneath and became a setext heading —
    // the failure the previous test exists to prevent, reachable from the
    // commonest caret of all, the end of what was just typed.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a", fmt);
        fx.ed.insert_thematic_break(1).unwrap();
        let rule = if fmt == Format::Markdown { "---" } else { "* * *" };
        fx.expect(&format!("a\n\n{}\n", rule));
        assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
        assert!(fx.find(KindRef::Tag(Tag::Para)).is_some());
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::Heading));
    }
}

#[test]
fn thematic_break_after_a_multi_line_paragraph_not_inside_it() {
    // A rule is a block, so it goes after the whole paragraph the caret is in —
    // the caret's own line is not a boundary.
    let mut fx = mk("a\nb\n", Format::Markdown);
    fx.ed.insert_thematic_break(0).unwrap();
    fx.expect("a\nb\n\n---\n");
}

#[test]
fn thematic_break_inside_a_quote_it_stays_inside_the_quote() {
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("> a\n", fmt);
        fx.ed.insert_thematic_break(2).unwrap();
        let rule = if fmt == Format::Markdown { "---" } else { "* * *" };
        fx.expect(&format!("> a\n>\n> {}\n", rule));
        // The blank continuation line is `>`, not `> `, and the rule carries the
        // quote's marker — so the break is the quote's child, not the doc's.
        let id = fx.find(KindRef::Tag(Tag::ThematicBreak)).expect("NoRule");
        let quote = fx.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
        assert!(id > quote);
    }
}

#[test]
fn thematic_break_inside_a_list_it_splits_the_list_rather_than_corrupting_it() {
    // `containerPrefix` reproduces quote markers but not a list item's indent,
    // so the rule lands at column zero after the caret's item. Nothing is
    // swallowed — the list becomes two lists with a rule between — which is why
    // this is allowed rather than refused.
    let mut fx = mk("- a\n- b\n", Format::Markdown);
    fx.ed.insert_thematic_break(2).unwrap();
    fx.expect("- a\n\n---\n\n- b\n");
    assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
    // Both items survive AS items: the markers were not eaten.
    let mut items: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::ListItem { items += 1; }
    }
    assert_eq!(2usize, items);
}

#[test]
fn thematic_break_inside_a_code_fence_it_lands_after_the_fence_not_in_the_body() {
    // `innermostBlock` knew only `para`/`heading`, so a caret in a code block
    // read as "no block here" and the rule went at the caret's LINE end — inside
    // the fence, where `---` is just text. The document gained no rule at all and
    // the code body silently grew a line. `lineOwningBlock` sees the code block.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("```\nabc\ndef\n```\n", fmt);
        fx.ed.insert_thematic_break(5).unwrap(); // caret inside `abc`
        let rule = if fmt == Format::Markdown { "---" } else { "* * *" };
        fx.expect(&format!("```\nabc\ndef\n```\n\n{}\n", rule));
        // The rule is a real node, and the code block still holds both its lines.
        assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
        let code = fx.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
        eq_str("abc\ndef\n", fx.ed.ast_view().kind(code).code_block_text());
    }
}

#[test]
fn thematic_break_inside_a_table_it_lands_after_the_table_which_survives() {
    // The worst of the fallback's cases: a rule written between the header row
    // and the delimiter row stops the table being a table. A node is lost.
    let mut fx = mk("| a | b |\n|---|---|\n| c | d |\n", Format::Markdown);
    fx.ed.insert_thematic_break(3).unwrap(); // caret in the header's first cell
    fx.expect("| a | b |\n|---|---|\n| c | d |\n\n---\n");
    assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
    assert!(fx.find(KindRef::Tag(Tag::Table)).is_some());
}

#[test]
fn thematic_break_a_fence_inside_a_quote_keeps_both_the_quote_and_the_fence() {
    // Both corrections at once: the anchor escapes the fence, and the prefix is
    // still the quote's, so the rule stays in the quote instead of ending it.
    let mut fx = mk("> ```\n> abc\n> ```\n", Format::Markdown);
    fx.ed.insert_thematic_break(8).unwrap(); // caret inside `abc`
    fx.expect("> ```\n> abc\n> ```\n>\n> ---\n");
    let id = fx.find(KindRef::Tag(Tag::ThematicBreak)).expect("NoRule");
    let quote = fx.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
    assert!(id > quote);
    assert!(fx.find(KindRef::Tag(Tag::CodeBlock)).is_some());
}

#[test]
fn thematic_break_an_existing_blank_line_below_is_not_doubled() {
    let mut fx = mk("a\n\nb\n", Format::Markdown);
    fx.ed.insert_thematic_break(0).unwrap();
    fx.ed.insert_thematic_break(0).unwrap();
    // The second rule lands after the paragraph again, above the first.
    fx.expect("a\n\n---\n\n---\n\nb\n");
}

#[test]
fn thematic_break_a_caret_on_a_blank_line_between_blocks_puts_the_rule_on_that_line() {
    // With no block owning a blank line, the rule used to go after it and
    // then add its own blank above — two blanks over the rule, one under.
    // The blank the caret sits on is a separator, and the rule takes its
    // place: one blank each side, in whichever format.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a\n\nb\n", fmt);
        fx.ed.insert_thematic_break(2).unwrap();
        let rule = if fmt == Format::Markdown { "---" } else { "* * *" };
        fx.expect(&format!("a\n\n{}\n\nb\n", rule));
        assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
    }
}

#[test]
fn thematic_break_a_blank_line_the_document_ends_on_stays_below_the_rule() {
    // The rule is written at the blank's start, so the blank becomes the
    // separator under it and the document still ends the way its author left
    // it. Eating the line to end on the rule would be the fold this gesture
    // does not do.
    let mut fx = mk("a\n\n", Format::Markdown);
    fx.ed.insert_thematic_break(2).unwrap();
    fx.expect("a\n\n---\n\n");
}

#[test]
fn thematic_break_a_blank_first_line_takes_the_rule_with_no_blank_above_it() {
    // What a split at a paragraph's start leaves — `\npara` with the caret on
    // the new blank — and where a consumer aiming "before the paragraph"
    // through a gesture that only knows "after" ends up. Before, `\n\n---`.
    let mut fx = mk("\npara\n", Format::Markdown);
    fx.ed.insert_thematic_break(0).unwrap();
    fx.expect("---\n\npara\n");
    assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
    assert!(fx.find(KindRef::Tag(Tag::Para)).is_some());
}

#[test]
fn thematic_break_a_run_of_blank_lines_is_not_folded_only_not_added_to() {
    // The gesture writes what is missing and nothing more: an author's extra
    // blank lines are theirs. On the middle of three blanks the rule takes
    // that line's start, nothing is added because both neighbours are already
    // separators, and the two blanks that were below the caret are still
    // below it.
    let mut fx = mk("a\n\n\n\nb\n", Format::Markdown);
    fx.ed.insert_thematic_break(3).unwrap();
    fx.expect("a\n\n---\n\n\nb\n");
}

#[test]
fn thematic_break_an_empty_document_is_a_legitimate_place_for_one() {
    let mut fx = mk("", Format::Markdown);
    fx.ed.insert_thematic_break(0).unwrap();
    fx.expect("---\n");
    assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
}

#[test]
fn thematic_break_a_parse_only_format_spells_none() {
    let mut fx = mk("<r>ab</r>", Format::Xml);
    assert_eq!(fx.ed.insert_thematic_break(3), Err(Error::UnsupportedFormat));
}

#[test]
fn thematic_break_html_spells_it_hr_after_the_caret_s_block() {
    let mut fx = mk("<p>ab</p>\n", Format::Html);
    fx.ed.insert_thematic_break(4).unwrap();
    // The blank line is the shared gesture's unconditional separation — needed
    // in Markdown, where `---` after a paragraph line is a setext underline
    // instead of a rule. In HTML it is inert whitespace between two blocks, so
    // the one spelling stays safe for every format.
    fx.expect("<p>ab</p>\n\n<hr>\n");
    assert!(fx.find(KindRef::Tag(Tag::ThematicBreak)).is_some());
}

// ── split block ──────────────────────────────────────────────────────────────

#[test]
fn split_block_a_list_item_splits_at_the_caret_into_two_items() {
    // The gesture's defining case: `- this is |a list item` becomes two items,
    // the marker repeated and NO blank line between them (a blank would loosen
    // the list and change how every sibling renders).
    let mut fx = mk("- this is a list item\n", Format::Markdown);
    fx.ed.split_block(10).unwrap(); // caret before `a list item`
    fx.expect("- this is \n- a list item\n");

    let mut items: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::ListItem { items += 1; }
    }
    assert_eq!(2usize, items);
}

#[test]
fn split_block_at_the_end_of_a_list_item_it_opens_an_empty_sibling() {
    // Enter at the end of an item — the empty block IS the point, and a list is
    // one of the few places a format can spell one.
    let mut fx = mk("- this is a list item\n", Format::Markdown);
    fx.ed.split_block(21).unwrap(); // caret at the item's end
    fx.expect("- this is a list item\n- \n");

    let mut items: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::ListItem { items += 1; }
    }
    assert_eq!(2usize, items);
}

#[test]
fn split_block_a_nested_item_s_new_sibling_keeps_its_nesting_depth() {
    // `listMarkerAt` puts `start` at the bullet, so taking the marker from there
    // dropped the indent and dumped the new item at column zero — out of its own
    // list and into the enclosing one. The indent between the quote prefix and
    // the bullet IS the nesting.
    let mut two = mk("- a\n  - b c\n", Format::Markdown);
    two.ed.split_block(9).unwrap();
    two.expect("- a\n  - b\n  - c\n");

    let mut four = mk("- a\n    - b c\n", Format::Markdown);
    four.ed.split_block(11).unwrap();
    four.expect("- a\n    - b\n    - c\n");

    // Djot needs the blank line to nest at all: without one, `  - b` is literal
    // text continuing the paragraph, which the reference corpus asserts
    // (djot.js/test/lists.test) and twig matches. So the djot case is spelled
    // the way djot actually nests, not the way Markdown does.
    let mut dj = mk("- a\n\n  - b c\n", Format::Djot);
    dj.ed.split_block(10).unwrap();
    dj.expect("- a\n\n  - b\n  - c\n");
}

#[test]
fn split_block_djot_s_non_nesting_continuation_splits_at_the_outer_level() {
    // `- a\n  - b c` is ONE djot item whose paragraph reads `a`, a soft break,
    // then the literal text `- b c`. Splitting it repeats the OUTER marker,
    // which looks like the nesting bug above and is not one — there is no inner
    // list in the tree to keep.
    let mut fx = mk("- a\n  - b c\n", Format::Djot);
    assert!(fx.find(KindRef::Tag(Tag::BulletList)).is_some());
    let mut lists: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::BulletList { lists += 1; }
    }
    assert_eq!(1usize, lists);

    fx.ed.split_block(9).unwrap();
    fx.expect("- a\n  - b\n- c\n");

    // And the outer marker is not merely faithful to the tree, it is the only
    // spelling that WORKS: an indented `  - ` there would continue the same
    // paragraph as more literal text, so the gesture would add no item at all.
    // Column zero is what actually opens one.
    let mut items: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::ListItem { items += 1; }
    }
    assert_eq!(2usize, items);

    let indented = mk("- a\n  - b\n  - c\n", Format::Djot);
    let mut indented_items: usize = 0;
    for n in &indented.ed.ast_view().nodes {
        if n.kind.tag() == Tag::ListItem { indented_items += 1; }
    }
    assert_eq!(1usize, indented_items);
}

#[test]
fn split_block_nesting_and_a_quote_prefix_compose() {
    // The prefix is re-minted from the quote markers and the indent is taken
    // from between them and the bullet, so both survive at once.
    let mut fx = mk("> - a\n>   - b c\n", Format::Markdown);
    fx.ed.split_block(13).unwrap();
    fx.expect("> - a\n>   - b\n>   - c\n");
}

#[test]
fn split_block_the_second_half_sheds_leading_spaces_but_not_in_code() {
    // At the start of a block, spaces are structure rather than content: keeping
    // them would write `-  c`, setting that item's content indent to three.
    let mut item = mk("- a b\n", Format::Markdown);
    item.ed.split_block(3).unwrap();
    item.expect("- a\n- b\n");

    let mut para = mk("a   b\n", Format::Markdown);
    para.ed.split_block(1).unwrap();
    para.expect("a\n\nb\n");

    // Inside a fence leading whitespace IS the content, so nothing is shed.
    let mut code = mk("```\na  b\n```\n", Format::Markdown);
    code.ed.split_block(5).unwrap();
    code.expect("```\na\n```\n\n```\n  b\n```\n");
}

#[test]
fn split_block_enter_at_an_item_s_end_works_with_a_sibling_following() {
    // Markdown's `list_item` span STOPS BEFORE its trailing newline while djot's
    // covers it, so in Markdown a caret at the item's end is in the gap between
    // items — inside the `bullet_list` and inside no item. The deepest hit is
    // then the list, which is not splittable, so the retry has to key on "not
    // splittable" rather than on "nothing found".
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("- one\n- two\n", fmt);
        fx.ed.split_block(5).unwrap();
        fx.expect("- one\n- \n- two\n");

        let mut items: usize = 0;
        for n in &fx.ed.ast_view().nodes {
            if n.kind.tag() == Tag::ListItem { items += 1; }
        }
        assert_eq!(3usize, items);
    }

    // Ordered items too, marker repeated verbatim as everywhere else.
    let mut ord = mk("1. one\n2. two\n", Format::Markdown);
    ord.ed.split_block(6).unwrap();
    ord.expect("1. one\n1. \n2. two\n");
}

#[test]
fn split_block_a_refusal_still_reports_against_the_block_pointed_at() {
    // The retry must not turn a genuine `NotEditable` into `NoBlock` by walking
    // back off the construct the caller actually named.
    let mut fx = mk("| a | b |\n|---|---|\n| c | d |\n", Format::Markdown);
    assert_eq!(fx.ed.split_block(9), Err(Error::NotEditable));
}

#[test]
fn split_block_a_list_marker_is_repeated_as_written_not_rebuilt() {
    // `*` stays `*` and `1)` stays `1)` — the author's spelling survives. An
    // ordered split repeats the NUMBER too; both formats renumber on render, and
    // `renumberOrderedLists` is the gesture for fixing the source.
    let mut star = mk("* ab\n", Format::Markdown);
    star.ed.split_block(3).unwrap();
    star.expect("* a\n* b\n");

    let mut ord = mk("1) ab\n", Format::Markdown);
    ord.ed.split_block(4).unwrap();
    ord.expect("1) a\n1) b\n");
}

#[test]
fn split_block_a_task_item_s_new_half_is_unchecked() {
    // Splitting one done thing in two does not make the remainder done.
    let mut fx = mk("- [x] ab\n", Format::Markdown);
    fx.ed.split_block(7).unwrap();
    fx.expect("- [x] a\n- [ ] b\n");
}

#[test]
fn split_block_a_paragraph_splits_on_a_blank_line() {
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("ab\n", fmt);
        fx.ed.split_block(1).unwrap();
        fx.expect("a\n\nb\n");

        let mut paras: usize = 0;
        for n in &fx.ed.ast_view().nodes {
            if n.kind.tag() == Tag::Para { paras += 1; }
        }
        assert_eq!(2usize, paras);
    }
}

#[test]
fn split_block_a_caret_at_a_line_start_doesn_t_add_a_redundant_blank() {
    // Splitting a soft-wrapped paragraph at the wrap point: the line end already
    // there is the separator's first newline, so only the blank is minted.
    let mut fx = mk("a\nb\n", Format::Markdown);
    fx.ed.split_block(2).unwrap();
    fx.expect("a\n\nb\n");
    let mut paras: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::Para { paras += 1; }
    }
    assert_eq!(2usize, paras);
}

#[test]
fn split_block_inside_a_quote_the_split_stays_inside_the_quote() {
    // The blank line carries the quote's marker (`>`, not `> `) and the second
    // half its full prefix, so the quote holds both halves instead of ending.
    let mut fx = mk("> ab\n", Format::Markdown);
    fx.ed.split_block(3).unwrap();
    fx.expect("> a\n>\n> b\n");

    let mut quotes: usize = 0;
    let mut paras: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        match n.kind.tag() {
            Tag::BlockQuote => quotes += 1,
            Tag::Para => paras += 1,
            _ => {}
        }
    }
    assert_eq!(1usize, quotes);
    assert_eq!(2usize, paras);
}

#[test]
fn split_block_a_heading_repeats_its_own_marker_at_its_own_level() {
    let mut fx = mk("### ab\n", Format::Markdown);
    fx.ed.split_block(5).unwrap();
    fx.expect("### a\n\n### b\n");

    let mut headings: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::Heading {
            headings += 1;
            assert_eq!(3u32, n.kind.heading_level());
        }
    }
    assert_eq!(2usize, headings);
}

#[test]
fn split_block_a_code_block_becomes_two_the_info_string_surviving() {
    // The opening fence line is reproduced verbatim from the fence character on,
    // so both the width and the language ride along.
    let mut fx = mk("```rust\nabc\ndef\n```\n", Format::Markdown);
    fx.ed.split_block(10).unwrap(); // caret inside `abc`
    fx.expect("```rust\nab\n```\n\n```rust\nc\ndef\n```\n");

    let mut blocks: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::CodeBlock {
            blocks += 1;
            eq_str("rust", n.kind.code_block_lang().expect("NoLang"));
        }
    }
    assert_eq!(2usize, blocks);
}

#[test]
fn split_block_a_measured_fence_keeps_its_width_across_the_split() {
    // The body holds a ``` run, so the block was fenced with four; splitting must
    // not reopen with three, which would close at the first inner run.
    let mut fx = mk("````\na ``` b\nc\n````\n", Format::Markdown);
    // The caret is at the START of the `c` line, so the separator opens on the
    // line already there rather than adding a blank one inside the first body.
    fx.ed.split_block(13).unwrap();
    fx.expect("````\na ``` b\n````\n\n````\nc\n````\n");
    let mut blocks: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::CodeBlock { blocks += 1; }
    }
    assert_eq!(2usize, blocks);
}

#[test]
fn split_block_a_table_is_noteditable() {
    // A newline mid-cell doesn't divide a table, it destroys one. Splitting a
    // table into two tables is a table gesture, not this one.
    let mut fx = mk("| a | b |\n|---|---|\n| c | d |\n", Format::Markdown);
    assert_eq!(fx.ed.split_block(3), Err(Error::NotEditable));
    fx.expect("| a | b |\n|---|---|\n| c | d |\n");
}

#[test]
fn split_block_a_setext_heading_is_noteditable_not_silently_normalised() {
    // Its `---` underline belongs to a block that would no longer be under it.
    // `setBlock` converts one to ATX, which makes the split work.
    let mut fx = mk("ab\n---\n", Format::Markdown);
    assert_eq!(fx.ed.split_block(1), Err(Error::NotEditable));
    fx.expect("ab\n---\n");
}

#[test]
fn split_block_an_indented_code_block_is_noteditable() {
    // A blank line inside one is interior, not a separator — the "split" would
    // parse back as a single block, so refusing beats pretending.
    let mut fx = mk("    abc\n", Format::Markdown);
    assert_eq!(fx.ed.split_block(6), Err(Error::NotEditable));
    fx.expect("    abc\n");
}

#[test]
fn split_block_an_empty_document_has_no_block_to_divide() {
    let mut fx = mk("", Format::Markdown);
    assert_eq!(fx.ed.split_block(0), Err(Error::NoBlock));
}

#[test]
fn split_block_an_offset_past_the_source_is_invalidrange() {
    let mut fx = mk("ab\n", Format::Markdown);
    assert_eq!(fx.ed.split_block(99), Err(Error::InvalidRange));
    fx.expect("ab\n");
}

#[test]
fn split_block_at_a_paragraph_s_end_the_empty_block_is_unrepresentable() {
    // No format spells an empty paragraph, so this is the one boundary case that
    // cannot produce a second node. The blank line is written and the caret sits
    // where the next paragraph begins; the node appears when there is text.
    let mut fx = mk("a\n", Format::Markdown);
    fx.ed.split_block(1).unwrap();
    fx.expect("a\n\n\n");
    let mut paras: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::Para { paras += 1; }
    }
    assert_eq!(1usize, paras);
}

#[test]
fn split_block_a_format_that_doesn_t_divide_blocks_with_a_blank_line_refuses() {
    // The separator every case above writes means "two blocks" only where a
    // blank line separates blocks. Inside an HTML `<p>` it is insignificant
    // whitespace: the gesture wrote its newlines, the reparse gave back the one
    // paragraph it started with, and success was reported for an edit that had
    // changed nothing about the document's shape. The refusal is checked before
    // a byte is read, so the source is untouched rather than merely restored.
    let src = "<p>ab</p>";
    let mut fx = mk(src, Format::Html);
    assert_eq!(fx.ed.split_block(4), Err(Error::UnsupportedFormat)); // between `a` and `b`
    fx.expect(src);

    // Not a property of the caret: a format with no block separator refuses
    // everywhere in the document, including a position with no block at all.
    assert_eq!(fx.ed.split_block(0), Err(Error::UnsupportedFormat));
}

// ── join blocks ──────────────────────────────────────────────────────────────
// The inverse of the split. Every case asserts the EXACT BYTES, because what
// this gesture gets right or wrong is markup a rendering assertion cannot see —
// a `</div>` that moved, a list item's continuation indent, a heading's closing
// `#` run — and then asserts the REPARSE, because the whole claim is that two
// text blocks became one.

/// How many nodes of `tag` the reparsed tree holds. The join's claim is a claim
/// about the count: two paragraphs where there was one, one heading where there
/// was a heading and a paragraph.

#[test]
fn join_blocks_two_paragraphs_become_one_in_every_format_that_has_them() {
    let mut md = mk("above\n\nbelow\n", Format::Markdown);
    md.ed.join_blocks(7).unwrap();
    md.expect("above\nbelow\n");
    assert_eq!(1usize, md.count(KindRef::Tag(Tag::Para)));

    // Djot's paragraph span covers its own trailing newline and Markdown's does
    // not, which is exactly the asymmetry the removal has to survive.
    let mut dj = mk("above\n\nbelow\n", Format::Djot);
    dj.ed.join_blocks(7).unwrap();
    dj.expect("above\nbelow\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Para)));

    // AsciiDoc records no content span at all; the marker is what reconstructs
    // one, and a paragraph has none, so the block IS its content.
    let mut adoc = mk("above\n\nbelow\n", Format::Asciidoc);
    adoc.ed.join_blocks(7).unwrap();
    adoc.expect("above\nbelow\n");
    assert_eq!(1usize, adoc.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_a_marker_heading_is_one_line_so_what_continues_it_is_a_space() {
    let mut fx = mk("# Title\n\nbelow\n", Format::Markdown);
    fx.ed.join_blocks(9).unwrap();
    fx.expect("# Title below\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, fx.count(KindRef::Tag(Tag::Para)));

    // The closing `#` run is A's TAIL: it travels past the joined text rather
    // than being left in the middle of it.
    let mut closed = mk("# Title #\n\nbelow\n", Format::Markdown);
    closed.ed.join_blocks(11).unwrap();
    closed.expect("# Title below #\n");
    assert_eq!(1usize, closed.count(KindRef::Tag(Tag::Heading)));

    let mut adoc = mk("== Title\n\nbelow\n", Format::Asciidoc);
    adoc.ed.join_blocks(10).unwrap();
    adoc.expect("== Title below\n");
    assert_eq!(1usize, adoc.count(KindRef::Tag(Tag::Heading)));

    // Djot puts the heading in a `section`, so the two blocks' lowest common
    // ancestor is that section rather than the document — and the answer is the
    // same, which is what the LCA is for.
    let mut dj = mk("# Title\n\nbelow\n", Format::Djot);
    dj.ed.join_blocks(9).unwrap();
    dj.expect("# Title below\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, dj.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_a_multi_line_b_joined_into_a_marker_heading_becomes_one_line() {
    // A marker heading is ONE LINE by its own spelling, so B's own line ends
    // cannot survive into it: `# T` + `xx`/`yy` wrote `# T xx`/`yy` — a
    // heading and a paragraph, two blocks, from a gesture reporting it had
    // made one.
    let mut fx = mk("# T\n\nxx\nyy\n", Format::Markdown);
    fx.ed.join_blocks(6).unwrap();
    fx.expect("# T xx yy\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, fx.count(KindRef::Tag(Tag::Para)));

    let mut adoc = mk("== T\n\naa\nbb\n", Format::Asciidoc);
    adoc.ed.join_blocks(7).unwrap();
    adoc.expect("== T aa bb\n");
    assert_eq!(1usize, adoc.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, adoc.count(KindRef::Tag(Tag::Para)));

    // The CONTINUATION PREFIX each of B's lines sits behind goes with the line
    // end it follows — the heading's line carries its own prefix already.
    let mut quoted = mk("# T\n\n> xx\n> yy\n", Format::Markdown);
    quoted.ed.join_blocks(8).unwrap();
    quoted.expect("# T xx yy\n");
    assert_eq!(1usize, quoted.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, quoted.count(KindRef::Tag(Tag::BlockQuote)));
}

#[test]
fn join_blocks_b_s_first_line_may_not_become_a_s_setext_underline() {
    // The one line-start construct that rewrites the block ABOVE it instead of
    // opening one of its own. `above` + `===` wrote `above\n===\n`, which
    // reparses as a heading and no paragraph at all — B's text became A's
    // spelling, and the caller's two paragraphs became one heading.
    let mut fx = mk("above\n\n===\n", Format::Markdown);
    fx.ed.join_blocks(8).unwrap();
    fx.expect("above\n\\===\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Para)));
    assert_eq!(0usize, fx.count(KindRef::Tag(Tag::Heading)));

    // The level-two spelling is the same trap, and `-` is also a thematic
    // break, so the escape is on the run rather than on the byte.
    let mut dashes = mk("above\n\n--\n", Format::Markdown);
    dashes.ed.join_blocks(8).unwrap();
    dashes.expect("above\n\\--\n");
    assert_eq!(1usize, dashes.count(KindRef::Tag(Tag::Para)));
    assert_eq!(0usize, dashes.count(KindRef::Tag(Tag::Heading)));

    // It is B's CONTENT that lands on the new line, so a heading B whose text
    // is a run of `=` is the same trap wearing a `# ` that goes with the rest
    // of B's markup.
    let mut heading = mk("above\n\n# ===\n", Format::Markdown);
    heading.ed.join_blocks(9).unwrap();
    heading.expect("above\n\\===\n");
    assert_eq!(1usize, heading.count(KindRef::Tag(Tag::Para)));
    assert_eq!(0usize, heading.count(KindRef::Tag(Tag::Heading)));

    // And nothing wider than that: the run is the whole test, so text that
    // merely holds an `=` keeps the bytes the caller typed.
    let mut ordinary = mk("above\n\na = b\n", Format::Markdown);
    ordinary.ed.join_blocks(7).unwrap();
    ordinary.expect("above\na = b\n");
    assert_eq!(1usize, ordinary.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_a_s_tail_carries_closing_markup_never_separator_lines() {
    // A Markdown `block_quote`'s span covers its own trailing marker lines, so
    // the tail of `a` in `> a\n>\n` is `"\n>\n"` — which is not closing markup
    // at all. Written past the joined text it left a stray `>` line below it,
    // and a second join piled up another.
    let mut fx = mk("> a\n>\n\n> b\n", Format::Markdown);
    fx.ed.join_blocks(8).unwrap();
    fx.expect("> a\n> b\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::BlockQuote)));
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Para)));

    // Several of them, and one with trailing space: every trailing line that
    // only separates goes, and the whole LINE goes — a byte-wise trim over the
    // same alphabet would eat the `>` that closes a `</div>`.
    let mut several = mk("> a\n>\n> \n\nb\n", Format::Markdown);
    several.ed.join_blocks(10).unwrap();
    several.expect("> a\n> b\n");
    assert_eq!(1usize, several.count(KindRef::Tag(Tag::Para)));

    // djot's `section` ends at its last child, so A's tail there is the line
    // end of its own last line and nothing more. Two blocks under ONE section,
    // where the heading that was B used to be copied out past the joined text
    // as well as left where it stood.
    let mut dj = mk("# H\n\npara\n\n# H2\n\nx\n", Format::Djot);
    dj.ed.join_blocks(13).unwrap();
    dj.expect("# H\n\npara\nH2\n\nx\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Section)));
    assert_eq!(2usize, dj.count(KindRef::Tag(Tag::Para)));
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Heading)));

    // And the same two sections with nothing between the headings.
    let mut headings = mk("# alpha\n\n# beta\n", Format::Djot);
    headings.ed.join_blocks(9).unwrap();
    headings.expect("# alpha beta\n");
    assert_eq!(1usize, headings.count(KindRef::Tag(Tag::Section)));
    assert_eq!(1usize, headings.count(KindRef::Tag(Tag::Heading)));
}

#[test]
fn join_blocks_a_setext_heading_a_carries_its_underline_past_the_joined_text() {
    // Its content may already span lines, so it takes the line end like a
    // paragraph — and the `===` is tail, which is what keeps the result a
    // heading instead of leaving the underline over the wrong half.
    let mut fx = mk("Title\n===\n\nbelow\n", Format::Markdown);
    fx.ed.join_blocks(11).unwrap();
    fx.expect("Title\nbelow\n===\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, fx.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_b_s_markers_go_and_the_joined_text_takes_a_s_presentation() {
    // A heading joined UPWARD into a paragraph is a paragraph: the marker is
    // B's own opening markup, and everything between A's block and B's content
    // vanishes.
    let mut fx = mk("above\n\n# Title\n\nafter\n", Format::Markdown);
    fx.ed.join_blocks(9).unwrap();
    fx.expect("above\nTitle\n\nafter\n");
    assert_eq!(0usize, fx.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(2usize, fx.count(KindRef::Tag(Tag::Para)));

    // Djot's attribute line is B's markup too, so it goes with the marker it
    // would otherwise re-attach to A's text.
    let mut dj = mk("above\n\n{.center}\nhello\n\nbelow\n", Format::Djot);
    dj.ed.join_blocks(17).unwrap();
    dj.expect("above\nhello\n\nbelow\n");
    assert_eq!(2usize, dj.count(KindRef::Tag(Tag::Para)));

    // The other direction: B is the plain one, and A KEEPS its attributes.
    let mut into = mk("above\n\n{.center}\nhello\n\nbelow\n", Format::Djot);
    into.ed.join_blocks(24).unwrap();
    into.expect("above\n\n{.center}\nhello\nbelow\n");
    assert_eq!(2usize, into.count(KindRef::Tag(Tag::Para)));

    // AsciiDoc puts B's metadata INSIDE B's own span and records no content
    // span to divide it from the text, so the whole span came through as
    // content and `[.lead]` landed in the joined paragraph as literal text.
    // The inline children are where the text is when no span table says.
    let mut attr = mk("above\n\n[.lead]\nbelow\n", Format::Asciidoc);
    attr.ed.join_blocks(15).unwrap();
    attr.expect("above\nbelow\n");
    assert_eq!(1usize, attr.count(KindRef::Tag(Tag::Para)));

    // A block TITLE is the same shape and the same answer.
    let mut title = mk("above\n\n.Cap\nbelow\n", Format::Asciidoc);
    title.ed.join_blocks(12).unwrap();
    title.expect("above\nbelow\n");
    assert_eq!(1usize, title.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_the_container_prefix_is_what_keeps_the_joined_line_inside() {
    // A quote repeats its marker; there is no lazy continuation in djot, and
    // Markdown's would end the quote at the joined line in the general case.
    let mut quote = mk("> a\n\n> b\n", Format::Markdown);
    quote.ed.join_blocks(7).unwrap();
    quote.expect("> a\n> b\n");
    assert_eq!(1usize, quote.count(KindRef::Tag(Tag::BlockQuote)));
    assert_eq!(1usize, quote.count(KindRef::Tag(Tag::Para)));

    // Two paragraphs of ONE quote: the LCA is the quote itself, so nothing of
    // its markup travels.
    let mut inside = mk("> a\n>\n> b\n", Format::Markdown);
    inside.ed.join_blocks(8).unwrap();
    inside.expect("> a\n> b\n");
    assert_eq!(1usize, inside.count(KindRef::Tag(Tag::Para)));

    // A list item's marker is NOT repeated — repeating it would open a second
    // item — so what the continuation carries is the marker's width in spaces.
    let mut bullet = mk("- a\n- b\n", Format::Markdown);
    bullet.ed.join_blocks(6).unwrap();
    bullet.expect("- a\n  b\n");
    assert_eq!(1usize, bullet.count(KindRef::Tag(Tag::ListItem)));

    let mut dj = mk("- a\n- b\n", Format::Djot);
    dj.ed.join_blocks(6).unwrap();
    dj.expect("- a\n  b\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::ListItem)));

    // A paragraph joined INTO a one-item list lands inside the item, indented
    // to the item's content column — three for `1. `, two for `- `.
    let mut after_bullet = mk("- a\n\nbelow\n", Format::Markdown);
    after_bullet.ed.join_blocks(5).unwrap();
    after_bullet.expect("- a\n  below\n");
    assert_eq!(1usize, after_bullet.count(KindRef::Tag(Tag::ListItem)));

    let mut after_ordered = mk("1. a\n\nbelow\n", Format::Markdown);
    after_ordered.ed.join_blocks(6).unwrap();
    after_ordered.expect("1. a\n   below\n");
    assert_eq!(1usize, after_ordered.count(KindRef::Tag(Tag::ListItem)));
}

#[test]
fn join_blocks_a_delimited_container_s_closers_travel_in_both_directions() {
    // The case the gesture exists for. A host that joined by deleting one
    // newline here would eat the blank line the `<div>` needs and break it.
    //
    // Joining `below` UP into the div's last paragraph: A is `hello`, three
    // levels down and not a sibling of B at all, and the `</div>` A sits
    // behind is carried past the text that was pulled in.
    let mut into = mk_with(
        "above\n\n<div class=\"center\">\n\nhello\n\n</div>\n\nbelow\n",
        Format::Markdown,
        html_elements_cfg(),
    );
    into.ed.join_blocks(44).unwrap();
    into.expect("above\n\n<div class=\"center\">\n\nhello\nbelow\n\n</div>\n");
    assert_eq!(1usize, into.count(KindRef::Tag(Tag::Container)));
    assert_eq!(2usize, into.count(KindRef::Tag(Tag::Para)));

    // And out of it: B leaves the div, so the div's own closers go with B's
    // markup — B was the only thing in it.
    let mut out_of = mk_with(
        "above\n\n<div class=\"center\">\n\nhello\n\n</div>\n\nbelow\n",
        Format::Markdown,
        html_elements_cfg(),
    );
    out_of.ed.join_blocks(29).unwrap();
    out_of.expect("above\nhello\n\nbelow\n");
    assert_eq!(0usize, out_of.count(KindRef::Tag(Tag::Container)));
    assert_eq!(2usize, out_of.count(KindRef::Tag(Tag::Para)));

    // Djot spells the same shape with a fence. Its `:::` line is A's tail here,
    // and the document keeps the line terminator B's removal took with it.
    let mut dj = mk("::: note\nhello\n:::\n\nbelow\n", Format::Djot);
    dj.ed.join_blocks(20).unwrap();
    dj.expect("::: note\nhello\nbelow\n:::\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Container)));
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_inside_a_delimited_container_only_the_last_block_may_leave() {
    let src = "above\n\n<div class=\"center\">\n\nhello\n\nworld\n\n</div>\n";

    // `hello` is the FIRST of two: pulling it out would have to move the div's
    // closers up past `world`, which is still inside. The one shape the gesture
    // refuses rather than guesses at.
    let mut first = mk_with(src, Format::Markdown, html_elements_cfg());
    assert_eq!(first.ed.join_blocks(29), Err(Error::NotEditable));
    first.expect(src);

    // `world` is the last, so it joins into `hello` and the div stays whole —
    // the LCA is the div itself, so none of its markup travels at all.
    let mut last = mk_with(src, Format::Markdown, html_elements_cfg());
    last.ed.join_blocks(36).unwrap();
    last.expect("above\n\n<div class=\"center\">\n\nhello\nworld\n\n</div>\n");
    assert_eq!(1usize, last.count(KindRef::Tag(Tag::Container)));
    assert_eq!(2usize, last.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_a_gap_it_cannot_see_across_is_refused_not_destroyed() {
    // Everything between A and B that is on neither chain is destroyed by the
    // splice, and neither walk that finds them can see all of it.
    //
    // A Markdown LINK REFERENCE DEFINITION is not a node — the parser keeps it
    // as a lookup table — so no tree walk could be written that sees one. This
    // joined to `alpha\nbeta\n` and took the definition, and every link that
    // resolved through it, with it.
    let r#ref = "alpha\n\n[ref]: /zed\n\nbeta\n";
    let mut ref_fx = mk(r#ref, Format::Markdown);
    assert_eq!(ref_fx.ed.join_blocks(20), Err(Error::NotEditable));
    ref_fx.expect(r#ref);

    let note = "alpha\n\n[^n]: note\n\nbeta\n";
    let mut note_fx = mk(note, Format::Markdown);
    assert_eq!(note_fx.ed.join_blocks(19), Err(Error::NotEditable));
    note_fx.expect(note);

    // A djot CAPTION is dropped by the parser rather than recorded, which is
    // the same position from the other side: bytes with no node over them.
    let caption = "alpha\n\n^ caption\n\nbeta\n";
    let mut caption_fx = mk(caption, Format::Djot);
    assert_eq!(caption_fx.ed.join_blocks(18), Err(Error::NotEditable));
    caption_fx.expect(caption);

    // The other half: a container HOLDING NO LEAF BLOCK is in the tree, and
    // `precedingLeafBlock` steps straight over it looking for text.
    let div = "alpha\n\n<div>\n\n</div>\n\nbeta\n";
    let mut div_fx = mk_with(div, Format::Markdown, html_elements_cfg());
    assert_eq!(div_fx.ed.join_blocks(22), Err(Error::NotEditable));
    div_fx.expect(div);

    let fence = "alpha\n\n:::\n:::\n\nbeta\n";
    let mut fence_fx = mk(fence, Format::Djot);
    assert_eq!(fence_fx.ed.join_blocks(16), Err(Error::NotEditable));
    fence_fx.expect(fence);

    // An empty QUOTE is why the guard is not bytes alone: `>` is exactly what
    // a quote holding both blocks puts between its own paragraphs, so these
    // gap bytes are indistinguishable from the ones the test above joins
    // across. The tree tells them apart.
    let quote = "alpha\n\n>\n\nbeta\n";
    let mut quote_fx = mk(quote, Format::Markdown);
    assert_eq!(quote_fx.ed.join_blocks(10), Err(Error::NotEditable));
    quote_fx.expect(quote);

    let bullet = "alpha\n\n-\n\nbeta\n";
    let mut bullet_fx = mk(bullet, Format::Markdown);
    assert_eq!(bullet_fx.ed.join_blocks(10), Err(Error::NotEditable));
    bullet_fx.expect(bullet);
}

#[test]
fn join_blocks_a_prefix_container_leaves_what_follows_b_where_it_is() {
    // A list has no closing bytes, so joining the first item's text out of it
    // does not drag the rest along — the remaining items are still a list. Two
    // items in, one item out, and the second item's text is now the first's.
    let mut fx = mk("- a\n- b\n- c\n", Format::Markdown);
    fx.ed.join_blocks(6).unwrap();
    fx.expect("- a\n  b\n- c\n");
    assert_eq!(2usize, fx.count(KindRef::Tag(Tag::ListItem)));
}

#[test]
fn join_blocks_a_container_closed_by_tags_keeps_b_unless_b_is_all_that_is_in_it() {
    // HTML's `<blockquote>` and `<ul>` are spelled as tag pairs, not as a
    // `container`, and a join that took B out of one with more after it
    // deleted the opening tag and left the closer. Found by the gesture check.
    let mut quote = mk("<p>a</p>\n<blockquote>\n<p>b</p>\n<p>c</p>\n</blockquote>\n", Format::Html);
    assert_eq!(quote.ed.join_blocks(25), Err(Error::NotEditable));

    let mut list = mk("<p>a</p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", Format::Html);
    assert_eq!(list.ed.join_blocks(18), Err(Error::NotEditable));
}

#[test]
fn join_blocks_the_rest_of_a_prefix_container_is_kept_apart_from_a_by_a_blank_line() {
    // B leaves a quote that goes on after it. The quote's blank line that
    // separated B from the rest separates A from it now, and A is outside
    // the quote — so it is written at A's level, or djot's paragraph runs on
    // into the quote's lines. Found by the gesture check.
    let mut dj = mk("alpha\n\n> quoted\n>\n> more\n", Format::Djot);
    dj.ed.join_blocks(9).unwrap();
    dj.expect("alpha\nquoted\n\n> more\n");
    assert_eq!(1usize, dj.count(KindRef::Tag(Tag::BlockQuote)));
    assert_eq!(2usize, dj.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_html_joins_where_it_cannot_split() {
    // The gate's whole point. A blank line between two `<p>`s is not what
    // separates them, so `splitBlock` refuses; a newline INSIDE a `<p>` is
    // exactly the break a join needs, and the reparse gives back one paragraph.
    let mut fx = mk("<p>a</p>\n<p class=\"x\">b</p>\n", Format::Html);
    assert_eq!(fx.ed.split_block(4), Err(Error::UnsupportedFormat));
    fx.ed.join_blocks(22).unwrap();
    fx.expect("<p>a\nb</p>\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Para)));

    // An `<h1>` records no marker, so it takes the line end rather than the
    // space a `#` heading takes — and `<h1>a\nb</h1>` is the one heading it
    // should be. This is why the space case keys on the MARKER and not on the
    // kind.
    let mut heading = mk("<h1>a</h1>\n<p>b</p>\n", Format::Html);
    heading.ed.join_blocks(14).unwrap();
    heading.expect("<h1>a\nb</h1>\n");
    assert_eq!(1usize, heading.count(KindRef::Tag(Tag::Heading)));
    assert_eq!(0usize, heading.count(KindRef::Tag(Tag::Para)));

    // And the nesting case: `c` joins into the `<div>`'s last paragraph, so the
    // `</p>` and the `</div>` both travel past it.
    let mut nested = mk("<div>\n<p>a</p>\n<p>b</p>\n</div>\n<p>c</p>\n", Format::Html);
    nested.ed.join_blocks(34).unwrap();
    nested.expect("<div>\n<p>a</p>\n<p>b\nc</p>\n</div>\n");
    assert_eq!(1usize, nested.count(KindRef::Tag(Tag::Container)));
    assert_eq!(2usize, nested.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_a_is_the_leaf_block_above_in_document_order_not_the_sibling() {
    // AsciiDoc puts each heading and the blocks under it in a `section`, so the
    // block above `x` is the `== Two` heading, inside the section B is in —
    // while the sibling above B's section is the FIRST section. Joining into
    // that one would pull `x` up past a heading it belongs under.
    let mut fx = mk("== Title\n\nbelow\n\n== Two\n\nx\n", Format::Asciidoc);
    fx.ed.join_blocks(25).unwrap();
    fx.expect("== Title\n\nbelow\n\n== Two x\n");
    assert_eq!(2usize, fx.count(KindRef::Tag(Tag::Section)));
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_a_block_with_no_text_to_join_into_is_noteditable() {
    // A code block, a rule, a table: each is a leaf block above B, and none is
    // a `para` or a `heading`. Pulling B's prose into a fence would change what
    // the fence holds; into a rule there is nowhere to put it at all.
    let mut code = mk("```\nx\n```\n\nbelow\n", Format::Markdown);
    assert_eq!(code.ed.join_blocks(11), Err(Error::NotEditable));
    code.expect("```\nx\n```\n\nbelow\n");

    let mut rule = mk("above\n\n***\n\nbelow\n", Format::Markdown);
    assert_eq!(rule.ed.join_blocks(12), Err(Error::NotEditable));
    rule.expect("above\n\n***\n\nbelow\n");

    // A paragraph under a TABLE is this same refusal and not the table rule:
    // the leaf block above it is the last cell's `str`, and a `str` is neither
    // a `para` nor a `heading`. What the table rules answer is a caret INSIDE
    // one, which is the test below.
    let after_table = "| a | b |\n|---|---|\n| c | d |\n\nbelow\n";
    let mut below = mk(after_table, Format::Markdown);
    assert_eq!(below.ed.join_blocks(31), Err(Error::NotEditable));
    below.expect(after_table);
}

#[test]
fn join_blocks_a_caret_in_a_table_is_noteditable_not_noblock() {
    // A cell's blocks are not the document's lines. The refusal is checked on
    // the POSITION rather than on the block, because a pipe table's cell holds
    // its text with no `para` under it — so "the innermost block here" is None,
    // and the honest answer is still that this is a table.
    let src = "| a | b |\n|---|---|\n| c | d |\n";
    let mut fx = mk(src, Format::Markdown);
    assert_eq!(fx.ed.join_blocks(22), Err(Error::NotEditable));
    fx.expect(src);

    // Every row of it, header included, and whichever cell: the position
    // answer does not depend on where in the grid the caret is.
    let mut header = mk(src, Format::Markdown);
    assert_eq!(header.ed.join_blocks(2), Err(Error::NotEditable));
    assert_eq!(header.ed.join_blocks(26), Err(Error::NotEditable));
    header.expect(src);

    // And in the other format that has a grid, whose cells are spelled
    // differently and answer the same. `passesThroughTable` sits behind this
    // as a chain test rather than a position one, for a format whose cells
    // hold a `para`: none here does, so the position rule is what fires, and
    // the chain rule is the backstop that keeps the answer right if one ever
    // does.
    let adoc = "|===\na| para here\n|===\n\nbelow\n";
    let mut cell = mk(adoc, Format::Asciidoc);
    assert_eq!(cell.ed.join_blocks(10), Err(Error::NotEditable));
    assert_eq!(cell.ed.join_blocks(25), Err(Error::NotEditable));
    cell.expect(adoc);
}

#[test]
fn join_blocks_a_setext_heading_b_is_noteditable_not_silently_unwritten() {
    // Its underline is how it is spelled at all, and dropping it is a rewrite
    // of the half the caller didn't point at. `setBlock` normalises one to ATX,
    // which makes this work — the same escape hatch `splitBlock` documents.
    let src = "above\n\nTitle\n===\n";
    let mut fx = mk(src, Format::Markdown);
    assert_eq!(fx.ed.join_blocks(7), Err(Error::NotEditable));
    fx.expect(src);
}

#[test]
fn join_blocks_the_first_block_of_a_document_has_nothing_above_it() {
    let mut fx = mk("above\n", Format::Markdown);
    assert_eq!(fx.ed.join_blocks(0), Err(Error::NoBlock));
    fx.expect("above\n");

    // Including when it is nested: the div's first paragraph is the document's
    // first leaf block, so there is nothing above it to join into.
    let nested = "<div class=\"center\">\n\nhello\n\nworld\n\n</div>\n";
    let mut inside = mk_with(nested, Format::Markdown, html_elements_cfg());
    assert_eq!(inside.ed.join_blocks(22), Err(Error::NoBlock));
    inside.expect(nested);

    // And a position no block covers at all.
    let mut empty = mk("", Format::Markdown);
    assert_eq!(empty.ed.join_blocks(0), Err(Error::NoBlock));
}

#[test]
fn join_blocks_an_offset_past_the_source_is_invalidrange() {
    let mut fx = mk("a\n\nb\n", Format::Markdown);
    assert_eq!(fx.ed.join_blocks(99), Err(Error::InvalidRange));
    fx.expect("a\n\nb\n");
}

#[test]
fn join_blocks_a_format_with_no_line_join_refuses_before_it_reads_a_byte() {
    // XML spells nothing: it is parse-and-render only, and the refusal is a
    // property of the format rather than of the caret, so it holds at a
    // position with no block at all.
    let src = "<r>ab</r>";
    let mut fx = mk(src, Format::Xml);
    assert_eq!(fx.ed.join_blocks(4), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.join_blocks(0), Err(Error::UnsupportedFormat));
    fx.expect(src);
}

#[test]
fn join_blocks_the_split_s_inverse_round_tripped() {
    // Split a paragraph and join it back: the source is what it was. Not a
    // property the gesture promises in general (a split writes a blank line, a
    // join writes a line break, and only one of those is what the other
    // removes) but it is the shape a caret editor's Enter/Backspace pair has to
    // have for the commonest case of all.
    let mut fx = mk("one two\n", Format::Markdown);
    fx.ed.split_block(3).unwrap();
    fx.expect("one\n\ntwo\n");
    assert_eq!(2usize, fx.count(KindRef::Tag(Tag::Para)));
    fx.ed.join_blocks(5).unwrap();
    fx.expect("one\ntwo\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::Para)));
}

#[test]
fn join_blocks_one_splice_so_one_undo() {
    // The whole edit is a single `commitSplice` over `[A.ce, R_end)`, which is
    // what makes it one entry in the undo stack rather than a delete and an
    // insert a caller would have to undo twice.
    let mut fx = mk("above\n\nbelow\n", Format::Markdown);
    fx.ed.join_blocks(7).unwrap();
    fx.expect("above\nbelow\n");
    fx.ed.splicer.undo().unwrap();
    fx.expect("above\n\nbelow\n");
}

// ── move block ───────────────────────────────────────────────────────────────
// The offset-addressed move. Every case asserts the EXACT BYTES, because what
// this gesture exists for is the markup a byte move gets wrong — a `> ` that
// has to be dropped or written, a list item's continuation indent, the blank
// line that keeps a block apart from its new neighbour — and the four moves
// the harness makes over every authorable format are not repeated here.

#[test]
fn move_block_a_block_leaves_a_quote_and_its_prefixes_stay_behind() {
    // The paragraph, its `> `, and the `>` blank line that separated it all
    // go; what lands at the end is the paragraph alone, blank-separated.
    let mut fx = mk("> a\n>\n> y\n\nb\n", Format::Markdown);
    fx.ed.move_block(8, 13).unwrap();
    fx.expect("> a\n\nb\n\ny\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::BlockQuote)));

    // A quote whose only paragraph leaves goes with it, however deep — the
    // inner quote here has no lines of its own once `a` is out of it.
    let mut sole = mk("> > a\n>\n> b\n\nc\n", Format::Markdown);
    sole.ed.move_block(4, 13).unwrap();
    sole.expect("> b\n\na\n\nc\n");
    assert_eq!(1usize, sole.count(KindRef::Tag(Tag::BlockQuote)));

    // A lazy continuation line carried no prefix and sheds none; the block
    // still comes out whole.
    let mut lazy = mk("> a\nb\n\nc\n", Format::Markdown);
    lazy.ed.move_block(2, 9).unwrap();
    lazy.expect("c\n\na\nb\n");
}

#[test]
fn move_block_a_block_entering_a_quote_takes_its_prefix_on_every_line() {
    // A fenced code block with a blank line inside: the blank is `>` and
    // every other line `> `, which is the spelling `toggleBlockContainer`
    // writes for the same block.
    let mut fx = mk("```\nx\n\ny\n```\n\n> q\n", Format::Markdown);
    fx.ed.move_block(4, 17).unwrap();
    fx.expect("> q\n>\n> ```\n> x\n>\n> y\n> ```\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::CodeBlock)));

    // `to` at the start of the quote's first paragraph is INSIDE the quote —
    // the innermost container holding the boundary — so the heading is quoted
    // and keeps its own marker behind the quote's.
    let mut head = mk("# T\n\n> q\n", Format::Markdown);
    head.ed.move_block(2, 7).unwrap();
    head.expect("> # T\n>\n> q\n");
    assert_eq!(1usize, head.count(KindRef::Tag(Tag::Heading)));
}

#[test]
fn move_block_a_list_item_s_first_block_is_the_item_and_an_item_is_always_a_sibling() {
    // Dragging a bullet's text drags the bullet, children and all; between
    // two items of a tight list no blank is written.
    let mut reorder = mk("- a\n  - b\n- c\n", Format::Markdown);
    reorder.ed.move_block(12, 0).unwrap();
    reorder.expect("- c\n- a\n  - b\n");

    // A nested item dropped at a sibling's boundary joins that list at that
    // level: its own indent went with the parent's prefix.
    let mut up = mk("- a\n  - b\n\nc\n", Format::Markdown);
    up.ed.move_block(8, 0).unwrap();
    up.expect("- b\n- a\n\nc\n");

    // Out of its list altogether it is a one-item list, blank-separated —
    // and into a quote it is a quoted bullet.
    let mut out = mk("- a\n  - b\n\nc\n", Format::Markdown);
    out.ed.move_block(8, 12).unwrap();
    out.expect("- a\n\nc\n\n- b\n");
    let mut quoted = mk("- [ ] a\n\n> q\n", Format::Markdown);
    quoted.ed.move_block(6, 12).unwrap();
    quoted.expect("> q\n>\n> - [ ] a\n");
    assert_eq!(1usize, quoted.count(KindRef::Tag(Tag::TaskListItem)));

    // A loose list's items stay blank-separated where a tight list's did not.
    let mut loose = mk("- b\n- c\n\n- d\n", Format::Markdown);
    loose.ed.move_block(10, 0).unwrap();
    loose.expect("- d\n\n- b\n- c\n");
}

#[test]
fn move_block_a_block_beside_an_item_s_text_is_beside_the_item_after_it_in_its_tail() {
    // Before an item's first block is before the ITEM, at the list's level:
    // between two items that splits the list, which is what the bytes say
    // and what a person who typed a paragraph there would get.
    let mut split = mk("- x\n- z\n\ny\n", Format::Markdown);
    split.ed.move_block(9, 4).unwrap();
    split.expect("- x\n\ny\n\n- z\n");
    assert_eq!(2usize, split.count(KindRef::Tag(Tag::BulletList)));

    // After the item's text is the item's tail: the continuation indent and
    // the blank line that makes it a second block of the item.
    let mut tail = mk("- x\n- z\n\ny\n", Format::Markdown);
    tail.ed.move_block(9, 3).unwrap();
    tail.expect("- x\n\n  y\n- z\n");
    assert_eq!(1usize, tail.count(KindRef::Tag(Tag::BulletList)));

    // Nested: the indent composes, a quote's prefix inside it composes too.
    let mut nested = mk("- a\n  - b\n\nc\n", Format::Markdown);
    nested.ed.move_block(12, 9).unwrap();
    nested.expect("- a\n  - b\n\n    c\n");
    let mut in_quote = mk("- x\n\n  > q\n\nc\n", Format::Markdown);
    in_quote.ed.move_block(12, 9).unwrap();
    in_quote.expect("- x\n\n  > c\n  >\n  > q\n");

    // A table is a block like any other, and goes in whole.
    let mut table = mk("- x\n\n| a |\n|---|\n| b |\n", Format::Markdown);
    table.ed.move_block(6, 3).unwrap();
    table.expect("- x\n\n  | a |\n  |---|\n  | b |\n");
    assert_eq!(1usize, table.count(KindRef::Tag(Tag::Table)));

    // Before the first item of a list is before the list — where the block
    // already is, here, which is a move of nothing.
    let mut already = mk("a\n\n- b\n", Format::Markdown);
    assert_eq!(already.ed.move_block(0, 5), Err(Error::InvalidArgument));
}

#[test]
fn move_block_within_one_container_it_is_what_movenode_writes() {
    // Same lines, same order, same separators — the prefix path is a no-op
    // at the top level, and the byte move is the whole answer.
    let mut gesture = mk("a\n\nb\n\nc\n", Format::Markdown);
    gesture.ed.move_block(6, 3).unwrap();
    let mut node = mk("a\n\nb\n\nc\n", Format::Markdown);
    let p = node.find(KindRef::Tag(Tag::Para)).unwrap();
    node.ed.splicer.move_node_by_id(p + 4, p, splicer::Placement::After).unwrap();
    eq_str(node.src(), gesture.src());
    gesture.expect("a\n\nc\n\nb\n");

    // To the document's end, and to its start.
    let mut end = mk("a\n\nb\n\nc\n", Format::Markdown);
    end.ed.move_block(0, 8).unwrap();
    end.expect("b\n\nc\n\na\n");
    let mut start = mk("a\n\nb\n\nc\n", Format::Markdown);
    start.ed.move_block(6, 0).unwrap();
    start.expect("c\n\na\n\nb\n");

    // A document with no final line end does not gain one for a block
    // landing at its end, nor for one leaving it.
    let mut bare = mk("a\n\nb", Format::Markdown);
    bare.ed.move_block(0, 4).unwrap();
    bare.expect("b\n\na");
    bare.ed.move_block(3, 0).unwrap();
    bare.expect("a\n\nb");
}

#[test]
fn move_block_the_boundary_is_between_blocks_or_the_move_is_refused() {
    let mut fx = mk("a\n\nbb cc\n\n```\ncode\n```\n", Format::Markdown);
    // Inside a paragraph's text, inside a fence's body.
    assert_eq!(fx.ed.move_block(0, 5), Err(Error::NotEditable));
    assert_eq!(fx.ed.move_block(0, 16), Err(Error::NotEditable));
    // Inside the block being moved, and at the boundary it already sits on —
    // before the next block, after the previous one, on the blank line.
    assert_eq!(fx.ed.move_block(3, 4), Err(Error::InvalidArgument));
    assert_eq!(fx.ed.move_block(3, 10), Err(Error::InvalidArgument));
    assert_eq!(fx.ed.move_block(3, 1), Err(Error::InvalidArgument));
    assert_eq!(fx.ed.move_block(3, 2), Err(Error::InvalidArgument));
    // Nothing on a blank line to move; nothing past the source.
    assert_eq!(fx.ed.move_block(2, 0), Err(Error::NoBlock));
    assert_eq!(fx.ed.move_block(0, 99), Err(Error::InvalidRange));
    assert_eq!(fx.ed.move_block(99, 0), Err(Error::InvalidRange));
    fx.expect("a\n\nbb cc\n\n```\ncode\n```\n");

    // A block that shares a line with another is not a run of lines.
    let mut shared = mk("<p>a</p><p>b</p>\n<p>c</p>\n", Format::Html);
    assert_eq!(shared.ed.move_block(12, 26), Err(Error::NotEditable));
    // A parse-only format has no blocks a caret could name.
    let mut xml = mk("<r><a/><b/></r>", Format::Xml);
    assert_eq!(xml.ed.move_block(3, 11), Err(Error::UnsupportedFormat));
}

#[test]
fn move_block_a_delimited_container_takes_a_block_by_its_lines_and_stands_when_emptied() {
    // A djot fence and an HTML blockquote have lines of their own; a block
    // landing inside gets no prefix and a blank line only where the format
    // has one, and a block leaving does not take the container with it — it
    // may carry attributes the move has no business dropping.
    let mut dj = mk("::: note\nx\n:::\n\nb\n", Format::Djot);
    dj.ed.move_block(16, 10).unwrap();
    dj.expect("::: note\nx\n\nb\n:::\n");
    dj.ed.move_block(9, 18).unwrap();
    dj.expect("::: note\nb\n:::\n\nx\n");

    let mut html = mk("<blockquote>\n<p>a</p>\n</blockquote>\n<p>c</p>\n", Format::Html);
    html.ed.move_block(40, 20).unwrap();
    html.expect("<blockquote>\n<p>a</p>\n<p>c</p>\n</blockquote>\n");
    html.ed.move_block(17, 45).unwrap();
    html.expect("<blockquote>\n<p>c</p>\n</blockquote>\n<p>a</p>\n");
}

#[test]
fn move_block_an_html_item_carries_its_list_s_tags_and_a_tight_item_s_text_gains_its_p() {
    // The `<ul>`/`</ul>` are the item's spelling: an only item moved out of
    // its list takes them along rather than leaving an empty pair behind and
    // arriving as a bare `<li>`.
    let mut only = mk("<ul>\n<li>\n<p>x</p>\n</li>\n</ul>\n<p>y</p>\n", Format::Html);
    only.ed.move_block(15, 39).unwrap();
    only.expect("<p>y</p>\n<ul>\n<li>\n<p>x</p>\n</li>\n</ul>\n");

    // A tight `<li>` holds its text without a `<p>`; a block joining it makes
    // the item loose, which HTML spells by wrapping the text.
    let mut tight = mk("<ul>\n<li>\nx\n</li>\n<li>\nz\n</li>\n</ul>\n<p>y</p>\n", Format::Html);
    tight.ed.move_block(40, 11).unwrap();
    tight.expect("<ul>\n<li>\n<p>x</p>\n<p>y</p>\n</li>\n<li>\nz\n</li>\n</ul>\n");
    assert_eq!(2usize, tight.count(KindRef::Tag(Tag::ListItem)));

    // `<li>x</li>` on one line has no line after its text inside the item.
    let mut one_line = mk("<ul>\n<li>x</li>\n</ul>\n<p>y</p>\n", Format::Html);
    assert_eq!(one_line.ed.move_block(26, 10), Err(Error::NotEditable));
}

#[test]
fn move_block_asciidoc_attaches_a_block_to_an_item_by_its_line() {
    // In an item's tail the block sits at column zero under a `+`, not
    // behind an indent — an indented line after a blank is a literal
    // paragraph there. The `+` is a separator line, so it travels with the
    // block and is written between it and an already-attached one.
    let mut fx = mk("* x\n\ny\n", Format::Asciidoc);
    fx.ed.move_block(5, 3).unwrap();
    fx.expect("* x\n+\ny\n");
    assert_eq!(1usize, fx.count(KindRef::Tag(Tag::ListItem)));
    fx.ed.move_block(6, 8).unwrap();
    fx.expect("* x\n\ny\n");

    let mut two = mk("* x\n+\ny\n\nc\n", Format::Asciidoc);
    two.ed.move_block(10, 6).unwrap();
    two.expect("* x\n+\nc\n+\ny\n");

    // Its `> ` quote is a prefix container like Markdown's.
    let mut quote = mk("> a\n\nc\n", Format::Asciidoc);
    quote.ed.move_block(5, 2).unwrap();
    quote.expect("> c\n>\n> a\n");
}

#[test]
fn move_block_one_splice_so_one_undo() {
    let mut fx = mk("> a\n>\n> y\n\nb\n", Format::Markdown);
    fx.ed.move_block(8, 13).unwrap();
    fx.expect("> a\n\nb\n\ny\n");
    fx.ed.splicer.undo().unwrap();
    fx.expect("> a\n>\n> y\n\nb\n");
}

// ── code blocks ──────────────────────────────────────────────────────────────

/// The info string the parser reads back off the edited source — the only thing
/// that proves a fence was tagged rather than merely written.

#[test]
fn togglecodeblock_fences_a_paragraph_and_unfences_it_back() {
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a\n", fmt);
        fx.ed.toggle_code_block(Span::new(0, 1), Some(b"zig")).unwrap();
        fx.expect("```zig\na\n```\n");
        expect_code_lang(&fx, Some("zig"));

        fx.ed.toggle_code_block(Span::new(0, 0), None).unwrap();
        fx.expect("a\n");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
    }
}

#[test]
fn togglecodeblock_an_untagged_fence_is_fine() {
    let mut fx = mk("a\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(0, 1), None).unwrap();
    fx.expect("```\na\n```\n");
    expect_code_lang(&fx, None);
}

#[test]
fn togglecodeblock_the_fence_outgrows_a_run_in_the_body() {
    // Three backticks in the text would close a three-backtick fence on the
    // body's own line, leaving the tail as prose. The fence is measured, so it
    // opens with four and the whole body survives as code.
    let mut fx = mk("a ``` b\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(0, 7), None).unwrap();
    fx.expect("````\na ``` b\n````\n");
    let id = fx.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
    eq_str("a ``` b\n", fx.ed.ast_view().kind(id).code_block_text());
}

#[test]
fn togglecodeblock_fencing_inside_a_quote_keeps_the_quote() {
    let mut fx = mk("> a\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(2, 3), None).unwrap();
    // Only the two fence lines are minted; the body line keeps the `> ` it
    // already had, which is what keeps the block inside the quote.
    fx.expect("> ```\n> a\n> ```\n");
    let quote = fx.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
    let code = fx.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
    assert!(code > quote);
}

/// Whether the (first) code block in the reparsed tree sits inside a node of
/// `tag` — the proof a fence stayed in its container rather than ending it.


/// Toggle a code block on at `on` and expect `fenced`, holding `text` inside
/// a `within`; toggle it off again at `off` and expect `source` back.

#[test]
fn togglecodeblock_inside_a_list_item_the_fence_sits_at_the_item_s_content_column() {
    // A fence at column zero would pull the item's `- ` into the code body and
    // the document would lose the item. The marker stays on the opening fence's
    // line instead, and every other line takes the item's continuation — the
    // same shape `toggleBlockContainer` writes when it wraps a list around a
    // code block.
    for fmt in [Format::Markdown, Format::Djot] {
        expect_code_round_trip(fmt, "- hello\n", 4, "- ```\n  hello\n  ```\n", Tag::ListItem, Some("hello\n"), 9);
        // Only the item the caret is in; its siblings keep their markers.
        let mut fx = mk("- a\n- b\n- c\n", fmt);
        fx.ed.toggle_code_block(Span::new(6, 7), Some(b"zig")).unwrap();
        fx.expect("- a\n- ```zig\n  b\n  ```\n- c\n");
        expect_code_lang(&fx, Some("zig"));
        assert_eq!(3usize, fx.count(KindRef::Tag(Tag::ListItem)));
        assert_eq!(1usize, fx.count(KindRef::Tag(Tag::BulletList)));
    }
}

#[test]
fn togglecodeblock_a_code_block_already_in_a_list_item_unfences_into_it() {
    // The other direction from a document that arrived with one — the shape
    // wrapping a list around a code block leaves — at the offset of its text.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("- ```\n  hello\n  ```\n", fmt);
        fx.ed.toggle_code_block(Span::new(9, 9), None).unwrap();
        fx.expect("- hello\n");
        assert!(fx.find(KindRef::Tag(Tag::ListItem)).is_some());
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
    }
    // Wrap a list around a code block, then take the code block out of it.
    let mut fx = mk("```\nhello\n```\n", Format::Markdown);
    fx.ed.toggle_block_container(Span::new(4, 9), ContainerKind::BulletList).unwrap();
    fx.expect("- ```\n  hello\n  ```\n");
    fx.ed.toggle_code_block(Span::new(9, 9), None).unwrap();
    fx.expect("- hello\n");
}

#[test]
fn togglecodeblock_ordered_nested_task_and_quoted_items_keep_their_columns() {
    for fmt in [Format::Markdown, Format::Djot] {
        // An ordered marker is wider, and so is the continuation.
        expect_code_round_trip(fmt, "1. hello\n", 4, "1. ```\n   hello\n   ```\n", Tag::ListItem, Some("hello\n"), 10);
        expect_code_round_trip(fmt, "10. hello\n", 5, "10. ```\n    hello\n    ```\n", Tag::ListItem, Some("hello\n"), 12);
        // A nested item: both markers' columns. Djot opens a sublist only
        // after a blank line.
        if fmt == Format::Markdown {
            expect_code_round_trip(fmt, "- a\n  - b\n", 8, "- a\n  - ```\n    b\n    ```\n", Tag::ListItem, Some("b\n"), 16);
        } else {
            expect_code_round_trip(fmt, "- a\n\n  - b\n", 9, "- a\n\n  - ```\n    b\n    ```\n", Tag::ListItem, Some("b\n"), 17);
        }
        expect_code_round_trip(fmt, "- a\n\n  1. b\n", 10, "- a\n\n  1. ```\n     b\n     ```\n", Tag::ListItem, Some("b\n"), 19);
        // A task item keeps its box on the fence line; the body is at the
        // item's content column, not the box's.
        expect_code_round_trip(fmt, "- [ ] hello\n", 8, "- [ ] ```\n  hello\n  ```\n", Tag::TaskListItem, Some("hello\n"), 12);
        // An item in a quote, and a quote in an item.
        expect_code_round_trip(fmt, "> - a\n", 4, "> - ```\n>   a\n>   ```\n", Tag::ListItem, Some("a\n"), 12);
        expect_code_round_trip(fmt, "- > a\n", 4, "- > ```\n  > a\n  > ```\n", Tag::BlockQuote, Some("a\n"), 12);
    }
    // The task item is still one, with the code block as its child.
    let mut fx = mk("- [x] hello\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(8, 8), None).unwrap();
    fx.expect("- [x] ```\n  hello\n  ```\n");
    let item = fx.find(KindRef::Tag(Tag::TaskListItem)).expect("NoTaskItem");
    assert!(fx.ed.ast_view().kind(item).task_list_item_checked());
    expect_code_within(&fx, Tag::TaskListItem, Some("hello\n"));
}

#[test]
fn togglecodeblock_an_item_s_later_block_and_a_lazy_line_stay_in_the_item() {
    for fmt in [Format::Markdown, Format::Djot] {
        // Not the item's first block: no marker on its line, so the fence
        // takes the continuation both ends.
        expect_code_round_trip(fmt, "- a\n\n  b\n", 7, "- a\n\n  ```\n  b\n  ```\n", Tag::ListItem, Some("b\n"), 12);
    }
    // A paragraph may leave its container's prefix off a continuation line; a
    // code body may not, so the lazy line is given it.
    let mut lazy = mk("- a\nb\n", Format::Markdown);
    lazy.ed.toggle_code_block(Span::new(2, 2), None).unwrap();
    lazy.expect("- ```\n  a\n  b\n  ```\n");
    expect_code_within(&lazy, Tag::ListItem, Some("a\nb\n"));
    let mut quoted = mk("> a\nb\n", Format::Markdown);
    quoted.ed.toggle_code_block(Span::new(2, 2), None).unwrap();
    quoted.expect("> ```\n> a\n> b\n> ```\n");
    expect_code_within(&quoted, Tag::BlockQuote, Some("a\nb\n"));
}

#[test]
fn togglecodeblock_a_selection_across_items_fences_the_whole_list() {
    // The blocks two items share are the list's, so the list is what is
    // fenced — at its own column, where it sits whole — and comes back whole.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("- a\n- b\n\nc\n", fmt);
        fx.ed.toggle_code_block(Span::new(2, 7), None).unwrap();
        fx.expect("```\n- a\n- b\n```\n\nc\n");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::ListItem));
        fx.ed.toggle_code_block(Span::new(4, 4), None).unwrap();
        fx.expect("- a\n- b\n\nc\n");
    }
}

#[test]
fn togglecodeblock_an_indented_code_block_in_a_quote_dedents_inside_it() {
    // Its four columns are counted after the quote's own marker.
    let mut fx = mk(">     code\n>     more\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(6, 6), None).unwrap();
    fx.expect("> code\n> more\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
    assert!(fx.find(KindRef::Tag(Tag::BlockQuote)).is_some());
}

#[test]
fn togglecodeblock_unfencing_an_item_s_first_block_never_leaves_its_first_line_blank() {
    // An item whose first line is blank holds nothing past a blank line after
    // it, so what would be left on that line is taken from further down.
    for fmt in [Format::Markdown, Format::Djot] {
        // An empty body keeps the item, empty.
        let mut empty = mk("- ```\n  ```\n- b\n", fmt);
        empty.ed.toggle_code_block(Span::new(2, 2), None).unwrap();
        empty.expect("-\n- b\n");
        assert_eq!(2usize, empty.count(KindRef::Tag(Tag::ListItem)));
        // ...and brings a block after it in the item up under the marker.
        let mut next = mk("- ```\n  ```\n\n  b\n", fmt);
        next.ed.toggle_code_block(Span::new(2, 2), None).unwrap();
        next.expect("-\n  b\n");
        assert_eq!(1usize, next.count(KindRef::Tag(Tag::ListItem)));
        assert!(next.find(KindRef::Tag(Tag::Para)).unwrap() > next.find(KindRef::Tag(Tag::ListItem)).unwrap());
        // A body's leading blank lines are passed over to its first content.
        let mut blanks = mk("- ```\n\n\n  a\n  ```\n", fmt);
        blanks.ed.toggle_code_block(Span::new(2, 2), None).unwrap();
        blanks.expect("- a\n");
    }
}

#[test]
fn togglecodeblock_a_tab_at_an_item_s_content_column_is_the_column_not_past_it() {
    // The tab reaches column four, past the item's two: the fence is written
    // at the item's column and the tab's line is left as it was. (How much of
    // the tab the body keeps is the parser's to say, not this gesture's.)
    for fmt in [Format::Markdown, Format::Djot] {
        expect_code_round_trip(fmt, "- a\n\n\tb\n", 6, "- a\n\n  ```\n\tb\n  ```\n", Tag::ListItem, None, 13);
    }
}

#[test]
fn togglecodeblock_an_asciidoc_admonition_s_label_is_not_a_container_prefix() {
    // `NOTE: ` is the paragraph's own marker, not a prefix its lines carry, so
    // the fence goes round the whole line — as it always has.
    let mut fx = mk("NOTE: a\n", Format::Asciidoc);
    fx.ed.toggle_code_block(Span::new(6, 6), None).unwrap();
    fx.expect("```\nNOTE: a\n```\n");
    fx.ed.toggle_code_block(Span::new(4, 4), None).unwrap();
    fx.expect("NOTE: a\n");
}

#[test]
fn togglecodeblock_asciidoc_fences_an_item_s_attached_block_not_its_principal_text() {
    // AsciiDoc attaches a block to an item by a `+` line, at column zero; the
    // item's own first line is its principal text, where a fence is text too.
    let mut fx = mk("* a\n+\nb\n", Format::Asciidoc);
    assert_eq!(fx.ed.toggle_code_block(Span::new(2, 2), None), Err(Error::NotEditable));
    fx.expect("* a\n+\nb\n");
    fx.ed.toggle_code_block(Span::new(6, 6), None).unwrap();
    fx.expect("* a\n+\n```\nb\n```\n");
    expect_code_within(&fx, Tag::ListItem, Some("b"));
    fx.ed.toggle_code_block(Span::new(10, 10), None).unwrap();
    fx.expect("* a\n+\nb\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
}

#[test]
fn togglecodeblock_unfencing_an_indented_markdown_code_block_dedents_it() {
    // The older spelling carries no fence to peel, so the toggle has to know its
    // framing IS the indentation — otherwise it would eat two lines of code.
    let mut fx = mk("    code\n    more\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(0, 0), None).unwrap();
    fx.expect("code\nmore\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
}

#[test]
fn togglecodeblock_an_unterminated_fence_keeps_its_last_line() {
    // No closing fence means the last line is content, not framing.
    let mut fx = mk("```\na\nb\n", Format::Markdown);
    fx.ed.toggle_code_block(Span::new(4, 4), None).unwrap();
    fx.expect("a\nb\n");
}

#[test]
fn setcodelanguage_retags_and_clears_the_info_string_fence_width_untouched() {
    let mut fx = mk("````zig\na ``` b\n````\n", Format::Markdown);
    fx.ed.set_code_language(0, Some(b"rust")).unwrap();
    fx.expect("````rust\na ``` b\n````\n");
    expect_code_lang(&fx, Some("rust"));

    fx.ed.set_code_language(0, None).unwrap();
    fx.expect("````\na ``` b\n````\n");
    expect_code_lang(&fx, None);
}

#[test]
fn setcodelanguage_an_indented_code_block_has_nowhere_to_carry_one() {
    let mut fx = mk("    code\n", Format::Markdown);
    assert_eq!(fx.ed.set_code_language(0, Some(b"zig")), Err(Error::NotEditable));
    fx.expect("    code\n");
}

#[test]
fn setcodelanguage_outside_a_code_block_is_noblock() {
    let _fx = mk("a\n", Format::Markdown);
    let mut off = mk("<p>a</p>\n<pre><code>x</code></pre>\n", Format::Html);
    assert_eq!(off.ed.set_code_language(3, Some(b"zig")), Err(Error::NoBlock));
}

#[test]
fn code_fence_an_info_string_the_fence_can_t_carry_is_refused() {
    // The fence byte would widen or close the fence in either format...
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("a\n", fmt);
        assert_eq!(fx.ed.toggle_code_block(Span::new(0, 1), Some(b"a`b")), Err(Error::InvalidLanguage));
        assert_eq!(fx.ed.toggle_code_block(Span::new(0, 1), Some(b"a\nb")), Err(Error::InvalidLanguage));
        fx.expect("a\n");
    }
    // ...but only Markdown ends its info string at whitespace, so only Markdown
    // refuses a space. Djot's runs to the end of the line.
    let mut md = mk("a\n", Format::Markdown);
    assert_eq!(md.ed.toggle_code_block(Span::new(0, 1), Some(b"a b")), Err(Error::InvalidLanguage));

    let mut dj = mk("a\n", Format::Djot);
    dj.ed.toggle_code_block(Span::new(0, 1), Some(b"a b")).unwrap();
    dj.expect("```a b\na\n```\n");
}

#[test]
fn togglecodeblock_html_makes_a_listing_of_the_covered_text_and_a_paragraph_of_a_listing() {
    // No fence to measure — `<pre><code>` entity-escapes a body — so the
    // covered blocks' TEXT becomes a `code_block` node's payload and
    // `renderBlock` prints it. Marks are dropped, which is what a listing
    // means; the entity is decoded on the way in and re-spelled on the way
    // out.
    let mut fx = mk("<p>a &lt; <em>b</em></p>\n<p>c</p>\n<p>d</p>\n", Format::Html);
    fx.ed.toggle_code_block(Span::new(3, 27), Some(b"zig")).unwrap();
    fx.expect("<pre><code class=\"language-zig\">a &lt; b\nc</code></pre>\n<p>d</p>\n");
    let cb = fx.find(KindRef::Tag(Tag::CodeBlock)).expect("NoCodeBlock");
    eq_str("zig", fx.kind(cb).code_block_lang().unwrap());
    eq_str("a < b\nc", fx.kind(cb).code_block_text());
    // Off: the listing's text under a paragraph, `<` and all, minting nothing.
    fx.ed.toggle_code_block(Span::new(12, 12), None).unwrap();
    fx.expect("<p>a &lt; b\nc</p>\n<p>d</p>\n");
    fx.expect_no_node_of_kind(KindRef::Tag(Tag::CodeBlock));
    // Plain prose toggled twice is the document it was.
    let mut plain = mk("<p>x &amp; y</p>\n", Format::Html);
    plain.ed.toggle_code_block(Span::new(3, 4), None).unwrap();
    plain.expect("<pre><code>x &amp; y</code></pre>\n");
    plain.ed.toggle_code_block(Span::new(12, 12), None).unwrap();
    plain.expect("<p>x &amp; y</p>\n");
}

#[test]
fn togglecodeblock_html_works_inside_a_list_item_where_a_fence_could_not() {
    let mut fx = mk("<ul>\n<li>\n<p>a</p>\n</li>\n</ul>\n", Format::Html);
    let a = find_sub(fx.ed.source_bytes(), b"a</p>").unwrap();
    fx.ed.toggle_code_block(Span::new(a, a + 1), None).unwrap();
    fx.expect("<ul>\n<li>\n<pre><code>a</code></pre>\n</li>\n</ul>\n");
    assert!(fx.find(KindRef::Tag(Tag::ListItem)).is_some());
}

#[test]
fn setcodelanguage_html_retags_and_clears_the_class_attributes_kept() {
    let mut fx = mk("<pre id=\"x\"><code class=\"language-zig\">a &lt; b</code></pre>\n", Format::Html);
    fx.ed.set_code_language(20, Some(b"rust")).unwrap();
    fx.expect("<pre id=\"x\"><code class=\"language-rust\">a &lt; b</code></pre>\n");
    fx.ed.set_code_language(20, None).unwrap();
    fx.expect("<pre id=\"x\"><code>a &lt; b</code></pre>\n");
    assert!(fx.ed.ast_view().kind(fx.find(KindRef::Tag(Tag::CodeBlock)).unwrap()).code_block_lang().is_none());
    // A language is one token in every format: whitespace would split the class.
    assert_eq!(fx.ed.set_code_language(20, Some(b"a b")), Err(Error::InvalidLanguage));
    assert_eq!(fx.ed.toggle_code_block(Span::new(20, 20), Some(b"a\nb")), Err(Error::InvalidLanguage));
    let mut off = mk("<p>a</p>\n<pre><code>x</code></pre>\n", Format::Html);
    assert_eq!(off.ed.set_code_language(3, Some(b"zig")), Err(Error::NoBlock));
}

#[test]
fn code_blocks_a_parse_only_format_spells_no_fence_and_prints_no_fragment() {
    let mut fx = mk("<r>ab</r>", Format::Xml);
    assert_eq!(fx.ed.toggle_code_block(Span::new(3, 5), None), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.set_code_language(3, Some(b"zig")), Err(Error::UnsupportedFormat));
}

// ── task list checkboxes ─────────────────────────────────────────────────────

/// The checked state the parser reads back — the box's meaning, not its bytes.

#[test]
fn toggletaskitem_a_bullet_gains_a_box_and_loses_it_again() {
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("- a\n", fmt);
        fx.ed.toggle_task_item(2).unwrap();
        fx.expect("- [ ] a\n");
        expect_task_checked(&fx, false);

        fx.ed.toggle_task_item(6).unwrap();
        fx.expect("- a\n");
        fx.expect_no_node_of_kind(KindRef::Tag(Tag::TaskListItem));
        assert!(fx.find(KindRef::Tag(Tag::ListItem)).is_some());
    }
}

#[test]
fn settaskchecked_ticks_and_unticks_and_is_a_no_op_when_already_there() {
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("- [ ] a\n", fmt);
        fx.ed.set_task_checked(6, true).unwrap();
        fx.expect("- [x] a\n");
        expect_task_checked(&fx, true);

        // Already checked: no edit at all, so no undo step to burn.
        let before = fx.ed.last_change();
        fx.ed.set_task_checked(6, true).unwrap();
        assert_eq!(before, fx.ed.last_change());

        fx.ed.set_task_checked(6, false).unwrap();
        fx.expect("- [ ] a\n");
        expect_task_checked(&fx, false);
    }
}

#[test]
fn toggletaskchecked_flips_whichever_way_the_box_is_pointing() {
    let mut fx = mk("- [ ] a\n- [x] b\n", Format::Markdown);
    fx.ed.toggle_task_checked(6).unwrap();
    fx.expect("- [x] a\n- [x] b\n");
    fx.ed.toggle_task_checked(14).unwrap();
    fx.expect("- [x] a\n- [ ] b\n");
}

#[test]
fn task_boxes_a_capital_x_is_a_checked_box_not_a_second_one_to_add() {
    // Source in the wild spells it both ways. Matching the box's INTERIOR rather
    // than the canonical spelling is what keeps the toggle from writing
    // `- [ ] [X] a`.
    let mut fx = mk("- [X] a\n", Format::Markdown);
    fx.ed.toggle_task_checked(6).unwrap();
    fx.expect("- [ ] a\n");
    expect_task_checked(&fx, false);
}

#[test]
fn task_boxes_an_item_inside_a_quote_is_found_past_the_quote_markers() {
    // The list marker doesn't start the line here, which is the whole reason
    // `listMarkerAt` takes a starting offset.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("> - [ ] a\n", fmt);
        fx.ed.set_task_checked(8, true).unwrap();
        fx.expect("> - [x] a\n");
        expect_task_checked(&fx, true);
    }
}

#[test]
fn task_boxes_an_item_s_continuation_lines_are_untouched() {
    // The box is inline content of the item's first paragraph, not part of the
    // marker, so the content column never moves — unlike a container toggle,
    // which has to re-indent.
    let mut fx = mk("- a\n  b\n", Format::Markdown);
    fx.ed.toggle_task_item(2).unwrap();
    fx.expect("- [ ] a\n  b\n");
    expect_task_checked(&fx, false);
}

#[test]
fn settaskchecked_a_plain_bullet_has_no_box_to_tick() {
    // Minting one here would make "set checked" silently convert the item;
    // `toggleTaskItem` is how a caller asks for that.
    let mut fx = mk("- a\n", Format::Markdown);
    assert_eq!(fx.ed.set_task_checked(2, true), Err(Error::NotEditable));
    assert_eq!(fx.ed.toggle_task_checked(2), Err(Error::NotEditable));
    fx.expect("- a\n");
}

#[test]
fn task_boxes_a_caret_in_no_list_item_is_noblock() {
    let mut fx = mk("a\n", Format::Markdown);
    assert_eq!(fx.ed.toggle_task_item(0), Err(Error::NoBlock));
    assert_eq!(fx.ed.set_task_checked(0, true), Err(Error::NoBlock));
}

#[test]
fn task_boxes_a_parse_only_format_spells_none() {
    for fmt in [Format::Xml, Format::Html] {
        let mut fx = mk("<r>ab</r>", fmt);
        assert_eq!(fx.ed.toggle_task_item(3), Err(Error::UnsupportedFormat));
        assert_eq!(fx.ed.set_task_checked(3, true), Err(Error::UnsupportedFormat));
    }
}

// ── footnotes ────────────────────────────────────────────────────────────────

#[test]
fn insertfootnote_writes_the_reference_and_the_definition() {
    // Half a footnote is not a footnote: a bare `[^a]` renders as four literal
    // characters. So the reparse has to show both nodes, not just the bytes.
    for fmt in [Format::Markdown, Format::Djot] {
        let mut fx = mk("see\n", fmt);
        fx.ed.insert_footnote(3, b"a").unwrap();
        fx.expect("see[^a]\n\n[^a]: \n");
        fx.expect_spelled(KindRef::TextLeaf(TextLeafKind::FootnoteReference), "a");
        let def = fx.find(KindRef::Tag(Tag::Footnote)).expect("NoDefinition");
        eq_str("a", fx.ed.ast_view().kind(def).footnote_label());
    }
}

#[test]
fn insertfootnote_a_second_reference_to_the_same_label_adds_no_second_definition() {
    let mut fx = mk("see\n", Format::Markdown);
    fx.ed.insert_footnote(3, b"a").unwrap();
    fx.ed.insert_footnote(7, b"a").unwrap();
    fx.expect("see[^a][^a]\n\n[^a]: \n");

    let mut defs: usize = 0;
    for n in &fx.ed.ast_view().nodes {
        if n.kind.tag() == Tag::Footnote { defs += 1; }
    }
    assert_eq!(1usize, defs);
}

#[test]
fn insertfootnote_a_distinct_label_gets_its_own_definition_below_the_first() {
    let mut fx = mk("see\n", Format::Markdown);
    fx.ed.insert_footnote(3, b"a").unwrap();
    fx.ed.insert_footnote(7, b"b").unwrap();
    fx.expect("see[^a][^b]\n\n[^a]: \n\n[^b]: \n");
}

#[test]
fn insertfootnote_a_source_with_no_trailing_newline_still_gets_a_whole_block() {
    let mut fx = mk("see", Format::Markdown);
    fx.ed.insert_footnote(3, b"a").unwrap();
    fx.expect("see[^a]\n\n[^a]: \n");
}

#[test]
fn insertfootnote_it_is_one_edit_so_one_undo_takes_both_halves_back() {
    // The two halves sit at opposite ends of the document but are one gesture:
    // two splices would need two undos and would report only half the change.
    let mut fx = mk("see\n", Format::Markdown);
    fx.ed.insert_footnote(3, b"a").unwrap();
    fx.ed.splicer.undo().unwrap();
    fx.expect("see\n");
}

#[test]
fn insertfootnote_a_label_the_reference_brackets_can_t_hold_is_refused() {
    let mut fx = mk("see\n", Format::Markdown);
    assert_eq!(fx.ed.insert_footnote(3, b""), Err(Error::InvalidLabel));
    assert_eq!(fx.ed.insert_footnote(3, b"a\nb"), Err(Error::InvalidLabel));
    assert_eq!(fx.ed.insert_footnote(3, b"a]b"), Err(Error::InvalidLabel));
    fx.expect("see\n");
}

#[test]
fn insertfootnote_a_parse_only_format_spells_none() {
    for fmt in [Format::Xml, Format::Html] {
        let mut fx = mk("<r>ab</r>", fmt);
        assert_eq!(fx.ed.insert_footnote(3, b"a"), Err(Error::UnsupportedFormat));
    }
}

// ── Math ────────────────────────────────────────────────────────────────────

/// The formula of `kind` the reparse holds, or an error when there is none.

#[test]
fn insertinlinemath_markdown_under_math_writes_at_the_caret() {
    let mut fx = mk_with("a  b\n", Format::Markdown, math_cfg());
    fx.ed.insert_inline_math(2, b"x^2").unwrap();
    fx.expect("a $x^2$ b\n");
    expect_formula(&fx, TextLeafKind::InlineMath, "x^2");
}

#[test]
fn insertinlinemath_the_formula_is_written_as_it_is_backslashes_and_all() {
    // A math body is read literally, so `insertLiteral`'s escapes would be
    // bytes of TeX: `\frac` must not become `\\frac`.
    let mut fx = mk_with("a  b\n", Format::Markdown, math_cfg());
    fx.ed.insert_inline_math(2, b"\\frac{1}{2}").unwrap();
    fx.expect("a $\\frac{1}{2}$ b\n");
    expect_formula(&fx, TextLeafKind::InlineMath, "\\frac{1}{2}");
}

#[test]
fn insertinlinemath_djot_s_run_widens_around_a_backtick_in_the_formula() {
    let mut fx = mk("a  b\n", Format::Djot);
    fx.ed.insert_inline_math(2, b"x^2").unwrap();
    fx.expect("a $`x^2` b\n");
    expect_formula(&fx, TextLeafKind::InlineMath, "x^2");

    let mut tick = mk("a  b\n", Format::Djot);
    tick.ed.insert_inline_math(2, b"a`b").unwrap();
    tick.expect("a $``a`b`` b\n");
    expect_formula(&tick, TextLeafKind::InlineMath, "a`b");
}

#[test]
fn insertinlinemath_asciidoc_writes_the_stem_macro() {
    let mut fx = mk("a  b\n", Format::Asciidoc);
    fx.ed.insert_inline_math(2, b"x^2").unwrap();
    fx.expect("a stem:[x^2] b\n");
    expect_formula(&fx, TextLeafKind::InlineMath, "x^2");
}

#[test]
fn insertinlinemath_without_the_math_extension_markdown_refuses_and_touches_nothing() {
    // `$x$` is four characters of text there, which is the gate's reason.
    let mut fx = mk("a\n", Format::Markdown);
    assert_eq!(fx.ed.insert_inline_math(0, b"x"), Err(Error::UnsupportedFormat));
    assert_eq!(fx.ed.insert_display_math(0, b"x"), Err(Error::UnsupportedFormat));
    fx.expect("a\n");

    let mut html = mk("<p>a</p>", Format::Html);
    assert_eq!(html.ed.insert_inline_math(3, b"x"), Err(Error::UnsupportedFormat));
    assert_eq!(html.ed.insert_display_math(3, b"x"), Err(Error::UnsupportedFormat));
}

#[test]
fn insertinlinemath_a_formula_markdown_s_dollars_cannot_hold_is_refused_and_touches_nothing() {
    let mut fx = mk_with("a  b\n", Format::Markdown, math_cfg());
    // No empty formula, no space against either dollar, no dollar inside, no
    // line end: each prints bytes that come back as something else.
    for f in ["", " x", "x ", "a$b", "a\nb"] {
        assert_eq!(fx.ed.insert_inline_math(2, f.as_bytes()), Err(Error::InvalidFormula));
        fx.expect("a  b\n");
    }
    // Djot's run holds the same formulas as themselves.
    let mut dj = mk("a  b\n", Format::Djot);
    dj.ed.insert_inline_math(2, b"a$b").unwrap();
    expect_formula(&dj, TextLeafKind::InlineMath, "a$b");
}

#[test]
fn insertinlinemath_in_a_code_span_the_bytes_are_code_so_it_refuses_and_touches_nothing() {
    let mut fx = mk_with("`code`\n", Format::Markdown, math_cfg());
    assert_eq!(fx.ed.insert_inline_math(3, b"x"), Err(Error::NotEditable));
    fx.expect("`code`\n");

    let mut block = mk("```\ncode\n```\n", Format::Djot);
    assert_eq!(block.ed.insert_inline_math(6, b"x"), Err(Error::NotEditable));
    block.expect("```\ncode\n```\n");
}

#[test]
fn insertinlinemath_flush_against_a_dollar_markdown_pairs_differently_it_refuses() {
    // `$5` then the formula: the first `$` would open against the formula's
    // own, which is not the formula the gesture wrote.
    let mut fx = mk_with("costs $5\n", Format::Markdown, math_cfg());
    assert_eq!(fx.ed.insert_inline_math(8, b"x"), Err(Error::NotEditable));
    fx.expect("costs $5\n");
}

#[test]
fn insertinlinemath_it_is_one_edit_so_one_undo_takes_it_back() {
    let mut fx = mk("a  b\n", Format::Djot);
    fx.ed.insert_inline_math(2, b"x").unwrap();
    fx.ed.splicer.undo().unwrap();
    fx.expect("a  b\n");
}

#[test]
fn insertdisplaymath_a_paragraph_of_its_own_after_the_caret_s_block() {
    let mut md = mk_with("a\n\nb\n", Format::Markdown, math_cfg());
    md.ed.insert_display_math(0, b"x^2").unwrap();
    md.expect("a\n\n$$x^2$$\n\nb\n");
    expect_formula(&md, TextLeafKind::DisplayMath, "x^2");

    let mut dj = mk("a\n", Format::Djot);
    dj.ed.insert_display_math(0, b"x^2").unwrap();
    dj.expect("a\n\n$$`x^2`\n");
    expect_formula(&dj, TextLeafKind::DisplayMath, "x^2");
}

#[test]
fn insertdisplaymath_inside_a_quote_every_line_of_the_formula_carries_the_marker() {
    let mut fx = mk_with("> a\n", Format::Markdown, math_cfg());
    fx.ed.insert_display_math(2, b"a \\\\\nb").unwrap();
    fx.expect("> a\n>\n> $$a \\\\\n> b$$\n");
    expect_formula(&fx, TextLeafKind::DisplayMath, "a \\\\\nb");
    // One quote, holding both paragraphs: the formula did not end it.
    let quote = fx.find(KindRef::Tag(Tag::BlockQuote)).expect("NoQuote");
    let q = fx.ed.splicer.doc.span(quote);
    assert_eq!(0usize, q.start);
    assert!(q.end >= fx.ed.source_bytes().len() - 1);
}

#[test]
fn insertdisplaymath_an_empty_document_is_a_legitimate_place_for_one() {
    let mut fx = mk_with("", Format::Markdown, math_cfg());
    fx.ed.insert_display_math(0, b"x").unwrap();
    fx.expect("$$x$$\n");
    expect_formula(&fx, TextLeafKind::DisplayMath, "x");
}

#[test]
fn insertdisplaymath_asciidoc_reads_its_one_spelling_back_inline_so_it_authors_only_that() {
    let mut fx = mk("a\n", Format::Asciidoc);
    assert_eq!(fx.ed.insert_display_math(0, b"x"), Err(Error::UnsupportedFormat));
    fx.expect("a\n");
    assert!(supports(format::syntax_for(Format::Asciidoc), Gesture::InsertInlineMath));
    assert!(!supports(format::syntax_for(Format::Asciidoc), Gesture::InsertDisplayMath));
}

#[test]
fn insertdisplaymath_a_formula_markdown_cannot_hold_is_refused_and_touches_nothing() {
    let mut fx = mk_with("a\n", Format::Markdown, math_cfg());
    // A blank line ends the paragraph the formula sits in.
    for f in ["", "a\n\nb", "a$$b"] {
        assert_eq!(fx.ed.insert_display_math(0, f.as_bytes()), Err(Error::InvalidFormula));
        fx.expect("a\n");
    }
}

#[test]
fn math_gestures_supports_follows_markdown_s_math_flag() {
    let md = format::syntax_for(Format::Markdown);
    assert!(!supports(md, Gesture::InsertInlineMath));
    assert!(!supports(md, Gesture::InsertDisplayMath));
    let with = format::syntax_for_config(Format::Markdown, &math_cfg());
    assert!(supports(with, Gesture::InsertInlineMath));
    assert!(supports(with, Gesture::InsertDisplayMath));
    assert!(supports(format::syntax_for(Format::Djot), Gesture::InsertDisplayMath));
}

// ── Capability ──────────────────────────────────────────────────────────────
// `Editor.supports` reports, without a document, whether a gesture will refuse
// on FORMAT. It is a second reading of the same `Syntax` fields the gestures
// gate on, so the thing worth testing is not what it returns but that it cannot
// drift from them — the same measured-not-asserted discipline
// `diagnostics.zig`'s fidelity table uses, for the same reason: a hand-written
// capability table is wrong the moment a gesture's gate moves.

/// A minimal document each format actually parses. The gestures below are run
/// against it only to reach their gate — every one of them checks the `Syntax`
/// table before it reads a single byte of source (that ordering is deliberate
/// and documented per gesture), so the content only has to parse, not to be a
/// place the gesture would succeed.

/// Every `Gesture`, with both kind vocabularies enumerated in full — so a new
/// `InlineKind` or `ContainerKind` widens the sweep with no edit here.
fn all_gestures() -> Vec<Gesture> {
    use Gesture::*;
    let mut list = Vec::new();
    for k in InlineKind::ALL {
        list.push(WrapRange(k));
        list.push(ToggleInline(k));
    }
    for k in ContainerKind::ALL {
        list.push(ToggleBlockContainer(k));
    }
    list.extend([
        SetMarkColor,
        SetBlock,
        InsertThematicBreak,
        ToggleCodeBlock,
        SetCodeLanguage,
        ToggleTaskItem,
        SetTaskChecked,
        ToggleTaskChecked,
        InsertLink,
        InsertImage,
        InsertFootnote,
        InsertLiteral,
        InsertLineBreak,
        SplitBlock,
        JoinBlocks,
        RenumberOrderedLists,
        TableInsertRow,
        TableDeleteRow,
        TableInsertColumn,
        TableDeleteColumn,
        TableSetAlignment,
        TableMoveRow,
        TableMoveColumn,
        InsertTable,
        InsertDirective,
        SetBlockAttrs,
        WrapRangeAttrs,
        SetNodeAttrs,
        MoveBlock,
        InsertInlineMath,
        InsertDisplayMath,
        ToggleLineBlock,
    ]);
    list
}

const COMPILED_FORMATS: [Format; 8] = [
    Format::Djot,
    Format::Markdown,
    Format::Xml,
    Format::Html,
    Format::Asciidoc,
    Format::Commonmark,
    Format::Gfm,
    Format::Svg,
];

#[test]
fn supports_matches_what_every_gesture_s_gate_actually_does() {
    // The pin. For every (format, gesture) pair: run the real gesture and
    // assert it reports `UnsupportedFormat` EXACTLY when `supports` says false.
    // (Every `Gesture` variant is in `all_gestures`: `run_gesture`'s match is
    // exhaustive, so a new variant fails to compile until it is listed.)
    for fmt in COMPILED_FORMATS {
        let syntax = format::syntax_for(fmt);
        for g in all_gestures() {
            let mut fx = mk(minimal_source(fmt), fmt);
            let claimed = supports(syntax, g);
            let observed = run_gesture(&mut fx.ed, g) != Err(Error::UnsupportedFormat);
            assert_eq!(claimed, observed, "supports({fmt:?}, {g:?}) claims {claimed}, the gesture disagrees");
        }
    }
}

#[test]
fn supports_is_the_per_gesture_answer_authorable_cannot_give() {
    // HTML is the case that motivates the whole query: `authorable()` is true
    // for it (see `format.zig`), yet a toolbar enabled on that predicate would
    // show a heading button, a quote button and a code-block button that all
    // fail. Per gesture, the answer is ragged — and this is what a caller needs.
    let html = format::syntax_for(Format::Html);
    assert!(html.authorable());
    assert!(supports(html, Gesture::ToggleInline(InlineKind::Strong)));
    // The two that moved from refused to supported when the renderers landed:
    // a heading through `renderBlock`, a literal through `renderText`.
    assert!(supports(html, Gesture::SetBlock));
    assert!(supports(html, Gesture::InsertLiteral));
    // And the five that followed them through `renderBlock`, once the HTML
    // block-elements proposal admitted every block the parser reads back.
    assert!(supports(html, Gesture::ToggleBlockContainer(ContainerKind::BlockQuote)));
    assert!(supports(html, Gesture::ToggleBlockContainer(ContainerKind::OrderedList)));
    assert!(supports(html, Gesture::ToggleCodeBlock));
    assert!(supports(html, Gesture::SetCodeLanguage));
    assert!(supports(html, Gesture::InsertLink));
    assert!(supports(html, Gesture::InsertImage));
    // What has no native HTML spelling stays refused.
    assert!(!supports(html, Gesture::ToggleTaskItem));
    assert!(!supports(html, Gesture::InsertFootnote));
    // The three that used to answer nothing at all, because they consulted no
    // `Syntax` field: HTML has a table its parser reads and no table spelling to
    // write one back with, no blank-line block separation, and no numbered list
    // marker. A toolbar can gray all nine out now instead of offering an edit
    // that destroyed the table it was aimed at.
    assert!(!supports(html, Gesture::TableInsertRow));
    assert!(!supports(html, Gesture::TableSetAlignment));
    assert!(!supports(html, Gesture::SplitBlock));
    // And the one that goes the OTHER way, which is why `line_join` is a field
    // of its own rather than a second reading of `block_separator`: HTML
    // cannot be split at a blank line and CAN be joined at a newline inside a
    // `<p>`. A toolbar grays out Enter-splits-the-block here and leaves
    // Backspace-joins-it live.
    assert!(supports(html, Gesture::JoinBlocks));
    assert!(!supports(html, Gesture::RenumberOrderedLists));

    // A format that spells no prose answers false to every caret gesture, so
    // `authorable()` and `supports` agree there — the coarse predicate is only
    // ever misleading in the middle of the range. The one gesture XML does
    // support is the node-addressed one, which no caret ever asks for and
    // which `authorable()` deliberately does not count: a tree editor asks
    // `supports` for it, and a prose editor still opens XML read-only.
    assert!(!format::syntax_for(Format::Xml).authorable());
    for g in all_gestures() {
        assert_eq!(g == Gesture::SetNodeAttrs, supports(format::syntax_for(Format::Xml), g));
    }

    // AsciiDoc sits in the middle of the range the other way round from
    // HTML: every block gesture works, a link and an image print through its
    // renderer (`dest[text]` is no alphabet's shape, but it is a serializer's),
    // and it is the two whose shape neither can write — a footnote (one
    // macro), a table (`|===`-fenced, no delimiter row) — that a toolbar
    // grays out.
    let adoc = format::syntax_for(Format::Asciidoc);
    assert!(adoc.authorable());
    assert!(supports(adoc, Gesture::ToggleInline(InlineKind::Mark)));
    assert!(supports(adoc, Gesture::ToggleInline(InlineKind::Superscript)));
    assert!(!supports(adoc, Gesture::ToggleInline(InlineKind::Insert)));
    assert!(supports(adoc, Gesture::SetBlock));
    assert!(supports(adoc, Gesture::ToggleBlockContainer(ContainerKind::BlockQuote)));
    assert!(supports(adoc, Gesture::ToggleBlockContainer(ContainerKind::OrderedList)));
    assert!(supports(adoc, Gesture::ToggleCodeBlock));
    assert!(supports(adoc, Gesture::ToggleTaskItem));
    assert!(supports(adoc, Gesture::InsertLiteral));
    assert!(supports(adoc, Gesture::SplitBlock));
    assert!(supports(adoc, Gesture::JoinBlocks));
    assert!(supports(adoc, Gesture::RenumberOrderedLists));
    assert!(supports(adoc, Gesture::InsertLink));
    assert!(supports(adoc, Gesture::InsertImage));
    assert!(!supports(adoc, Gesture::InsertFootnote));
    assert!(!supports(adoc, Gesture::InsertLineBreak));
    assert!(!supports(adoc, Gesture::TableInsertRow));

    // And the two authorable formats differ from each other, which is the other
    // half of why one boolean can't serve: djot spells all eight inline marks,
    // Markdown three. `==mark==` is emit-only there (`Delims.authorable`), so
    // the query refuses it exactly as `toggleInline` does.
    assert!(supports(format::syntax_for(Format::Djot), Gesture::ToggleInline(InlineKind::Mark)));
    assert!(!supports(format::syntax_for(Format::Markdown), Gesture::ToggleInline(InlineKind::Mark)));
    assert!(supports(format::syntax_for(Format::Markdown), Gesture::InsertLineBreak));
    assert!(!supports(format::syntax_for(Format::Djot), Gesture::InsertLineBreak));
}

// ── setBlockAttrs ──────────────────────────────────────────────────────────

fn class_c() -> [KeyVal; 1] {
    [kv("class", "c")]
}
fn size_large() -> [KeyVal; 1] {
    [kv("data-size", "large")]
}

#[test]
fn setblockattrs_djot_writes_the_attribute_line_before_the_block_rewrites_it_and_removes_it() {
    let mut fx = mk("hello _em_\n", Format::Djot);
    fx.ed.set_block_attrs(0, &class_c()).unwrap();
    fx.expect("{.c}\nhello _em_\n");
    let para = fx.find(KindRef::Tag(Tag::Para)).unwrap();
    eq_str("c", fx.ed.ast_view().attrs_of(para).get(b"class").unwrap());

    // Replace, not merge: the class goes, the size arrives; the block's own
    // bytes are untouched throughout.
    fx.ed.set_block_attrs(6, &size_large()).unwrap();
    fx.expect("{data-size=\"large\"}\nhello _em_\n");
    fx.ed.set_block_attrs(22, &[]).unwrap();
    fx.expect("hello _em_\n");
    // Clearing what is already clear is a no-op.
    fx.ed.set_block_attrs(0, &[]).unwrap();
    fx.expect("hello _em_\n");
}

#[test]
fn setblockattrs_djot_carries_a_quote_s_marker_onto_the_line_and_takes_it_away_with_it() {
    let mut fx = mk("> hello\n", Format::Djot);
    fx.ed.set_block_attrs(3, &class_c()).unwrap();
    fx.expect("> {.c}\n> hello\n");
    fx.ed.set_block_attrs(10, &[]).unwrap();
    fx.expect("> hello\n");
}

#[test]
fn setblockattrs_djot_refuses_a_block_that_starts_on_a_list_item_s_marker_line() {
    // The line above is the list's, not the paragraph's: a `{…}` written
    // there would attach to the list.
    let mut fx = mk("- hello\n", Format::Djot);
    assert_eq!(fx.ed.set_block_attrs(3, &class_c()), Err(Error::NotEditable));
    fx.expect("- hello\n");
}

#[test]
fn setblockattrs_djot_refuses_attributes_assembled_from_more_than_one_block() {
    let mut fx = mk("{.a}\n{.b}\nhello\n", Format::Djot);
    assert_eq!(fx.ed.set_block_attrs(12, &class_c()), Err(Error::NotEditable));
}

#[test]
fn setnodeattrs_xml_rewrites_the_start_tag_s_interior_and_nothing_else() {
    // The children — a nested element, a comment, the whitespace text runs
    // that hold the indentation — are not re-printed: only the bytes between
    // the name and the closer move.
    let mut fx = mk("<svg>\n  <g  id=\"a\"  fill='red' >\n    <rect x=\"1\"/><!-- c -->\n  </g>\n</svg>\n", Format::Xml);
    let g = fx.find(KindRef::ContainerNamed(b"g".to_vec())).unwrap();
    fx.ed.set_node_attrs(g, &[kv("id", "a"), kv("transform", "translate(2 3)")]).unwrap();
    fx.expect("<svg>\n  <g id=\"a\" transform=\"translate(2 3)\">\n    <rect x=\"1\"/><!-- c -->\n  </g>\n</svg>\n");
    let g2 = fx.find(KindRef::ContainerNamed(b"g".to_vec())).unwrap();
    eq_str("translate(2 3)", fx.ed.ast_view().attrs_of(g2).get(b"transform").unwrap());
    assert!(fx.ed.ast_view().attrs_of(g2).get(b"fill").is_none());

    // A self-closing element keeps its closer; a value's specials come back
    // as entities and reparse to the bytes that were asked for.
    let rect = fx.find(KindRef::ContainerNamed(b"rect".to_vec())).unwrap();
    fx.ed.set_node_attrs(rect, &[kv("data-note", "a < b & c")]).unwrap();
    fx.expect("<svg>\n  <g id=\"a\" transform=\"translate(2 3)\">\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
    let rect2 = fx.find(KindRef::ContainerNamed(b"rect".to_vec())).unwrap();
    eq_str("a < b & c", fx.ed.ast_view().attrs_of(rect2).get(b"data-note").unwrap());

    // An empty set removes the run, whitespace and all; clearing an element
    // that has none is a no-op; and a first attribute lands after the name.
    fx.ed.set_node_attrs(fx.find(KindRef::ContainerNamed(b"g".to_vec())).unwrap(), &[]).unwrap();
    fx.expect("<svg>\n  <g>\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
    fx.ed.set_node_attrs(fx.find(KindRef::ContainerNamed(b"svg".to_vec())).unwrap(), &[]).unwrap();
    fx.expect("<svg>\n  <g>\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
    fx.ed.set_node_attrs(fx.find(KindRef::ContainerNamed(b"svg".to_vec())).unwrap(), &[kv("viewBox", "0 0 10 10")]).unwrap();
    fx.expect("<svg viewBox=\"0 0 10 10\">\n  <g>\n    <rect data-note=\"a &lt; b &amp; c\"/><!-- c -->\n  </g>\n</svg>\n");
}

#[test]
fn setnodeattrs_refuses_what_is_not_an_element_an_unknown_id_and_an_attribute_no_format_reads() {
    let mut fx = mk("<r>text<!-- c --></r>", Format::Xml);
    let text = fx.find(KindRef::Tag(Tag::Str)).unwrap();
    assert_eq!(fx.ed.set_node_attrs(text, &class_c()), Err(Error::NotEditable));
    let comment = fx.find(KindRef::MarkupLeaf(MarkupLeafKind::Comment)).unwrap();
    assert_eq!(fx.ed.set_node_attrs(comment, &class_c()), Err(Error::NotEditable));
    let past = fx.ed.ast_view().nodes.len() as NodeId;
    assert_eq!(fx.ed.set_node_attrs(past, &class_c()), Err(Error::InvalidRange));
    let r = fx.find(KindRef::ContainerNamed(b"r".to_vec())).unwrap();
    assert_eq!(fx.ed.set_node_attrs(r, &[kv("1x", "v")]), Err(Error::InvalidAttribute));
    assert_eq!(fx.ed.set_node_attrs(r, &[KeyVal::new(b"x", None)]), Err(Error::InvalidAttribute));
    fx.expect("<r>text<!-- c --></r>");
    // A prose format spells a block's attributes and not a node's: the gate
    // answers before an id is looked at.
    let mut md = mk("hello\n", Format::Djot);
    assert_eq!(md.ed.set_node_attrs(0, &class_c()), Err(Error::UnsupportedFormat));
}

#[test]
fn setblockattrs_html_re_prints_the_element_with_the_new_set() {
    let mut fx = mk("<p>a <em>b</em></p>\n", Format::Html);
    fx.ed.set_block_attrs(4, &class_c()).unwrap();
    fx.expect("<p class=\"c\">a <em>b</em></p>\n");
    fx.ed.set_block_attrs(4, &[]).unwrap();
    fx.expect("<p>a <em>b</em></p>\n");
}

#[test]
fn setblockattrs_asciidoc_writes_its_attribute_line_and_a_heading_keeps_its_level() {
    let mut fx = mk("hello\n", Format::Asciidoc);
    fx.ed.set_block_attrs(0, &class_c()).unwrap();
    fx.expect("[.c]\nhello\n");
    let para = fx.find(KindRef::Tag(Tag::Para)).unwrap();
    eq_str("c", fx.ed.ast_view().attrs_of(para).get(b"class").unwrap());
    fx.ed.set_block_attrs(6, &[]).unwrap();
    fx.expect("hello\n");
}

#[test]
fn setblockattrs_markdown_wraps_the_block_in_a_div_rewrites_the_div_and_unwraps_it() {
    let mut fx = mk_with("hello\n", Format::Markdown, html_elements_cfg());
    fx.ed.set_block_attrs(0, &class_c()).unwrap();
    fx.expect("<div class=\"c\">\n\nhello\n\n</div>\n");
    // The reparse pairs the tags: a div whose sole child is the paragraph.
    let div = fx.find(KindRef::ContainerNamed(b"div".to_vec())).unwrap();
    eq_str("c", fx.ed.ast_view().attrs_of(div).get(b"class").unwrap());
    let para = fx.ed.ast_view().nodes[div as usize].first_child.unwrap();
    assert!(*fx.kind(para) == Kind::Para);
    assert!(fx.ed.ast_view().nodes[para as usize].next_sibling.is_none());

    // A second call from inside the paragraph rewrites the wrapper, and
    // does not nest a second one.
    fx.ed.set_block_attrs(20, &size_large()).unwrap();
    fx.expect("<div data-size=\"large\">\n\nhello\n\n</div>\n");
    fx.ed.set_block_attrs(26, &[]).unwrap();
    fx.expect("hello\n");
}

#[test]
fn setblockattrs_markdown_s_wrap_carries_a_quote_s_marker_on_every_line_the_blanks_included() {
    let mut fx = mk_with("> hello\n", Format::Markdown, html_elements_cfg());
    fx.ed.set_block_attrs(3, &class_c()).unwrap();
    fx.expect("> <div class=\"c\">\n>\n> hello\n>\n> </div>\n");
    fx.ed.set_block_attrs(22, &[]).unwrap();
    fx.expect("> hello\n");
}

#[test]
fn setblockattrs_a_directive_origin_div_is_not_the_wrapper_a_block_sits_in() {
    // `:::div{.c}` is the author's directive; a block inside it gets a div of
    // its own rather than the directive's attributes rewritten.
    let cfg = || ParseConfig {
        markdown: Extensions { directives: true, html_elements: true, ..Default::default() },
        ..Default::default()
    };
    let mut fx = mk_with(":::div{.c}\nhello\n:::\n", Format::Markdown, cfg());
    fx.ed.set_block_attrs(12, &size_large()).unwrap();
    fx.expect(":::div{.c}\n<div data-size=\"large\">\n\nhello\n\n</div>\n:::\n");
}

#[test]
fn setblockattrs_without_html_elements_markdown_refuses_and_touches_nothing() {
    let mut fx = mk("hello\n", Format::Markdown);
    assert_eq!(fx.ed.set_block_attrs(0, &class_c()), Err(Error::UnsupportedFormat));
    fx.expect("hello\n");
}

#[test]
fn setblockattrs_the_caret_must_be_in_a_paragraph_or_heading_and_the_attributes_must_be_reada() {
    let mut fx = mk("", Format::Djot);
    assert_eq!(fx.ed.set_block_attrs(0, &class_c()), Err(Error::NoBlock));
    assert_eq!(fx.ed.set_block_attrs(1, &class_c()), Err(Error::InvalidRange));

    let mut dj = mk("hello\n", Format::Djot);
    assert_eq!(dj.ed.set_block_attrs(0, &[kv("a b", "x")]), Err(Error::InvalidAttribute));
    assert_eq!(dj.ed.set_block_attrs(0, &[kv("", "x")]), Err(Error::InvalidAttribute));
    assert_eq!(dj.ed.set_block_attrs(0, &[KeyVal::new(b"k", None)]), Err(Error::InvalidAttribute));
    assert_eq!(dj.ed.set_block_attrs(0, &[kv("k", "a\nb")]), Err(Error::InvalidAttribute));
    assert_eq!(dj.ed.set_block_attrs(0, &[kv("k", "a\"b")]), Err(Error::InvalidAttribute));
    dj.expect("hello\n");
}

// ── wrapRangeAttrs ─────────────────────────────────────────────────────────

fn class_l() -> [KeyVal; 1] {
    [kv("class", "large")]
}
fn class_s() -> [KeyVal; 1] {
    [kv("class", "small")]
}

#[test]
fn wraprangeattrs_djot_brackets_the_range_re_styles_it_from_inside_and_unwraps_it() {
    let mut fx = mk("a big _text_ b\n", Format::Djot);
    fx.ed.wrap_range_attrs(Span::new(2, 12), &class_l()).unwrap();
    fx.expect("a [big _text_]{.large} b\n");
    let span = fx.find(KindRef::Tag(Tag::Container)).unwrap();
    eq_str("large", fx.ed.ast_view().attrs_of(span).get(b"class").unwrap());
    // Replace, not nest: a range inside the span re-styles the span.
    fx.ed.wrap_range_attrs(Span::new(4, 6), &class_s()).unwrap();
    fx.expect("a [big _text_]{.small} b\n");
    // Unwrapping keeps the content bytes as they are.
    fx.ed.wrap_range_attrs(Span::new(4, 6), &[]).unwrap();
    fx.expect("a big _text_ b\n");
}

#[test]
fn wraprangeattrs_html_and_markdown_spell_a_span_and_read_the_name_back_as_the_same_node() {
    let mut h = mk("<p>a big b</p>\n", Format::Html);
    h.ed.wrap_range_attrs(Span::new(5, 8), &class_l()).unwrap();
    h.expect("<p>a <span class=\"large\">big</span> b</p>\n");
    h.ed.wrap_range_attrs(Span::new(25, 28), &class_s()).unwrap();
    h.expect("<p>a <span class=\"small\">big</span> b</p>\n");
    h.ed.wrap_range_attrs(Span::new(25, 28), &[]).unwrap();
    h.expect("<p>a big b</p>\n");

    let mut md = mk_with("a *big* b\n", Format::Markdown, html_elements_cfg());
    md.ed.wrap_range_attrs(Span::new(2, 7), &class_l()).unwrap();
    md.expect("a <span class=\"large\">*big*</span> b\n");
    let span = md.find(KindRef::ContainerNamed(b"span".to_vec())).unwrap();
    eq_str("large", md.ed.ast_view().attrs_of(span).get(b"class").unwrap());
    // The mark inside rode along.
    let em = md.ed.ast_view().nodes[span as usize].first_child.unwrap();
    assert!(md.kind(em).tag() == Tag::InlineMark);
    md.ed.wrap_range_attrs(Span::new(23, 26), &class_s()).unwrap();
    md.expect("a <span class=\"small\">*big*</span> b\n");
    md.ed.wrap_range_attrs(Span::new(23, 26), &[]).unwrap();
    md.expect("a *big* b\n");
}

#[test]
fn wraprangeattrs_a_directive_origin_span_is_not_the_span_a_range_re_styles() {
    let cfg = || ParseConfig {
        markdown: Extensions { directives: true, html_elements: true, ..Default::default() },
        ..Default::default()
    };
    let mut fx = mk_with("a :span[big]{.a} b\n", Format::Markdown, cfg());
    fx.ed.wrap_range_attrs(Span::new(8, 11), &class_l()).unwrap();
    fx.expect("a :span[<span class=\"large\">big</span>]{.a} b\n");
}

#[test]
fn wraprangeattrs_refused_where_the_format_does_not_read_the_span_back_and_touches_nothing() {
    let mut md = mk("a big b\n", Format::Markdown);
    assert_eq!(md.ed.wrap_range_attrs(Span::new(2, 5), &class_l()), Err(Error::UnsupportedFormat));
    md.expect("a big b\n");
    let mut adoc = mk("a big b\n", Format::Asciidoc);
    assert_eq!(adoc.ed.wrap_range_attrs(Span::new(2, 5), &class_l()), Err(Error::UnsupportedFormat));
}

#[test]
fn wraprangeattrs_an_empty_range_with_no_span_to_re_style_a_bad_range_a_bad_attribute() {
    let mut fx = mk("a big b\n", Format::Djot);
    assert_eq!(fx.ed.wrap_range_attrs(Span::new(2, 2), &class_l()), Err(Error::NotEditable));
    assert_eq!(fx.ed.wrap_range_attrs(Span::new(5, 2), &class_l()), Err(Error::InvalidRange));
    assert_eq!(fx.ed.wrap_range_attrs(Span::new(0, 99), &class_l()), Err(Error::InvalidRange));
    assert_eq!(fx.ed.wrap_range_attrs(Span::new(2, 5), &[KeyVal::new(b"k", None)]), Err(Error::InvalidAttribute));
    fx.expect("a big b\n");
}

#[test]
fn move_block_a_boundary_that_closes_a_container_is_read_outside_it_for_the_block_that_closes() {
    // The last block of a quote dropped at its own end — the one offset that
    // is both after it and after the quote — leaves the quote; and dropped
    // on the blank line after a quote it was the only content of, where the
    // lines that go with it include that blank.
    let mut last = mk("x\n\n> a\n>\n> b\n\ny\n", Format::Markdown);
    last.ed.move_block(11, 12).unwrap();
    last.expect("x\n\n> a\n\nb\n\ny\n");
    let mut sole = mk("> b\n\ny\n", Format::Markdown);
    sole.ed.move_block(2, 4).unwrap();
    sole.expect("b\n\ny\n");
    assert_eq!(0usize, sole.count(KindRef::Tag(Tag::BlockQuote)));

    // The same for a nested quote's first block at its own start, and for
    // the last block of an item's tail and the last item of a list — a
    // sibling, so a one-item list of its own.
    let mut first = mk("> > a\n", Format::Markdown);
    first.ed.move_block(4, 4).unwrap();
    first.expect("> a\n");
    let mut tail = mk("- a\n\n  c\n", Format::Markdown);
    tail.ed.move_block(7, 8).unwrap();
    tail.expect("- a\n\nc\n");
    let mut item = mk("- a\n- b\n", Format::Markdown);
    item.ed.move_block(6, 7).unwrap();
    item.expect("- a\n\n- b\n");

    // A block that does not close its container sits on nothing but its own
    // boundary there: before the second of two, after the first of two.
    let mut mid = mk("x\n\n> a\n>\n> b\n", Format::Markdown);
    assert_eq!(mid.ed.move_block(11, 9), Err(Error::InvalidArgument));
    assert_eq!(mid.ed.move_block(11, 11), Err(Error::InvalidArgument));
    assert_eq!(mid.ed.move_block(5, 6), Err(Error::InvalidArgument));
    let mut items = mk("- a\n- b\n", Format::Markdown);
    assert_eq!(items.ed.move_block(2, 3), Err(Error::InvalidArgument));
}

#[test]
fn move_block_a_container_s_marker_is_before_the_container_its_first_content_byte_is_inside() {
    // Above a quote that opens the document, which no other offset names.
    let mut opens = mk("> a\n\ny\n", Format::Markdown);
    opens.ed.move_block(5, 0).unwrap();
    opens.expect("y\n\n> a\n");

    // The marker byte and the content byte, one offset apart, are the two
    // boundaries: the block lands before the quote or in it.
    let mut marker = mk("x\n\n> a\n", Format::Markdown);
    assert_eq!(marker.ed.move_block(0, 3), Err(Error::InvalidArgument));
    marker.ed.move_block(0, 5).unwrap();
    marker.expect("> x\n>\n> a\n");
    let mut out = mk("x\n\n> a\n>\n> b\n", Format::Markdown);
    out.ed.move_block(11, 3).unwrap();
    out.expect("x\n\nb\n\n> a\n");

    // Nested: the outermost container opening at the offset, so `> > a` at
    // 0 is before both quotes and at 2 before the inner one alone.
    let mut both = mk("> > a\n", Format::Markdown);
    both.ed.move_block(4, 0).unwrap();
    both.expect("a\n");
    let mut inner = mk("> > a\n", Format::Markdown);
    inner.ed.move_block(4, 2).unwrap();
    inner.expect("> a\n");

    // A delimited container opens at its first byte, and stands emptied.
    let mut html = mk("<blockquote>\n<p>a</p>\n</blockquote>\n<p>c</p>\n", Format::Html);
    html.ed.move_block(17, 0).unwrap();
    html.expect("<p>a</p>\n<blockquote>\n</blockquote>\n<p>c</p>\n");
}

#[test]
fn move_block_the_source_s_length_is_the_document_s_end_terminated_or_not() {
    // Behind a trailing list with no final line end, the length is the last
    // item's last byte too; it still names the end of the document.
    let mut bare = mk("p\n\n- a\n- b", Format::Markdown);
    bare.ed.move_block(0, 10).unwrap();
    bare.expect("- a\n- b\n\np");
    let mut quote = mk("x\n\n> a", Format::Markdown);
    quote.ed.move_block(0, 6).unwrap();
    quote.expect("> a\n\nx");
}

// ── toggleLineBlock ────────────────────────────────────────────────────────

/// The first `line_block` in the fixture's tree, or None — `KindRef` names
/// inline and container kinds, not this one.

#[test]
fn togglelineblock_two_markdown_paragraphs_become_one_verse_of_two_stanzas_and_back() {
    let mut fx = mk_with("before\n\nRoses are red,\nviolets blue.\n\nSugar is sweet.\n\nafter\n", Format::Markdown, html_elements_cfg());
    let start = find_sub(fx.ed.source_bytes(), b"Roses").unwrap();
    let end = find_sub(fx.ed.source_bytes(), b"sweet").unwrap();
    fx.ed.toggle_line_block(start, end).unwrap();
    fx.expect("before\n\n<div class=\"verse\">\n\nRoses are red,\\\nviolets blue.\n\nSugar is sweet.\n\n</div>\n\nafter\n");
    assert!(find_line_block(&fx).is_some());

    // Off again, from anywhere inside: one paragraph per stanza, the lines
    // joined by plain breaks.
    let inside = find_sub(fx.ed.source_bytes(), b"violets").unwrap();
    fx.ed.toggle_line_block(inside, inside).unwrap();
    fx.expect("before\n\nRoses are red,\nviolets blue.\n\nSugar is sweet.\n\nafter\n");
    assert!(find_line_block(&fx).is_none());
}

#[test]
fn togglelineblock_a_centred_paragraph_s_wrapper_becomes_the_verse_and_keeps_its_class() {
    let mut fx = mk_with("<div class=\"center\">\n\nOne\nTwo\n\n</div>\n", Format::Markdown, html_elements_cfg());
    let at = find_sub(fx.ed.source_bytes(), b"One").unwrap();
    fx.ed.toggle_line_block(at, at).unwrap();
    fx.expect("<div class=\"verse center\">\n\nOne\\\nTwo\n\n</div>\n");
    let lb = find_line_block(&fx).unwrap();
    eq_str("center", fx.ed.ast_view().attrs_of(lb).get(b"class").unwrap());

    // And off: the class comes back on a div around the paragraph.
    fx.ed.toggle_line_block(at, at).unwrap();
    fx.expect("<div class=\"center\">\n\nOne\nTwo\n\n</div>\n");
}

#[test]
fn togglelineblock_an_indent_survives_the_round_trip_as_em_spaces() {
    let mut fx = mk_with("<div class=\"verse\">\n\nzero\n\u{2003}one\n\n</div>\n", Format::Markdown, html_elements_cfg());
    let at = find_sub(fx.ed.source_bytes(), b"zero").unwrap();
    fx.ed.toggle_line_block(at, at).unwrap();
    fx.expect("zero\n\u{2003}one\n");
    fx.ed.toggle_line_block(0, 0).unwrap();
    fx.expect("<div class=\"verse\">\n\nzero\\\n\u{2003}one\n\n</div>\n");
    let lb = find_line_block(&fx).unwrap();
    let mut it = fx.ed.ast_view().children(lb);
    _ = it.next();
    let second = it.next().unwrap();
    assert_eq!(1u32, fx.ed.ast_view().kind(second.id).line_indent());
}

#[test]
fn togglelineblock_djot_writes_verse_and_a_wrapper_s_attribute_line_is_replaced_not_doubled() {
    let mut fx = mk("{.center}\n::: c\nOne\nTwo\n:::\n", Format::Djot);
    let at = find_sub(fx.ed.source_bytes(), b"One").unwrap();
    fx.ed.toggle_line_block(at, at).unwrap();
    let lb = find_line_block(&fx).unwrap();
    eq_str("center c", fx.ed.ast_view().attrs_of(lb).get(b"class").unwrap());
    assert_eq!(1usize, fx.src().iter().filter(|&&c| c == b'{').count());
    assert!(find_sub(fx.src(), b"::: verse\nOne\\\nTwo\n:::").is_some());
}

#[test]
fn togglelineblock_refused_across_a_heading_and_unsupported_where_a_verse_cannot_be_read_back() {
    let mut fx = mk_with("one\n\n# Heading\n\ntwo\n", Format::Markdown, html_elements_cfg());
    let end = find_sub(fx.ed.source_bytes(), b"two").unwrap();
    assert_eq!(fx.ed.toggle_line_block(0, end), Err(Error::NotEditable));
    fx.expect("one\n\n# Heading\n\ntwo\n");

    let mut plain = mk("one\n", Format::Markdown);
    assert_eq!(plain.ed.toggle_line_block(0, 0), Err(Error::UnsupportedFormat));
    let mut html = mk("<p>one</p>\n", Format::Html);
    assert_eq!(html.ed.toggle_line_block(0, 0), Err(Error::UnsupportedFormat));
}

