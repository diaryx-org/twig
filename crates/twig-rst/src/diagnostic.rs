//! reStructuredText parse diagnostics — twig's OWN record of what went wrong,
//! kept out of the tree. Port of `src/languages/rst/diagnostic.zig`.
//!
//! docutils reports parse problems by building `<system_message>` nodes into
//! the doctree. Twig does not: the tree stays markup, and problems are
//! collected in a [`Report`] sidecar — a typed `code` plus a byte span plus
//! whatever arguments the message interpolates (the shape an editor or a
//! language server wants, since LSP diagnostics are ranges).
//!
//! docutils' exact wording and the tree placement of a message are facts about
//! DOCUTILS' OUTPUT, so they live in `system_message`, not here.
//!
//! Scope: Tier A, the core-parser messages. Tier B (directive/role machinery,
//! generated from a directive schema twig does not have yet) and Tier C
//! (Python implementation leakage) are deliberately absent — see `mod.rs`.
//!
//! docutils separates a two-sentence message with a NEWLINE, not a space.

use crate::parse_diagnostic::{self, Location};
use crate::span::Span;

pub use crate::parse_diagnostic::Rendered;

/// How bad a problem is. Four levels because docutils' reporter grades every
/// message 1–4 and the corpus exercises all of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Severity {
    Info,
    Warning,
    Err,
    Severe,
}

impl Severity {
    pub const ALL: [Severity; 4] = [Severity::Info, Severity::Warning, Severity::Err, Severity::Severe];

    /// docutils' numeric `level` attribute.
    pub fn level(self) -> u8 {
        match self {
            Severity::Info => 1,
            Severity::Warning => 2,
            Severity::Err => 3,
            Severity::Severe => 4,
        }
    }

    pub fn from_level(n: u8) -> Option<Severity> {
        match n {
            1 => Some(Severity::Info),
            2 => Some(Severity::Warning),
            3 => Some(Severity::Err),
            4 => Some(Severity::Severe),
            _ => None,
        }
    }

    /// docutils' `type` attribute — the uppercase name.
    pub fn type_name(self) -> &'static str {
        match self {
            Severity::Info => "INFO",
            Severity::Warning => "WARNING",
            Severity::Err => "ERROR",
            Severity::Severe => "SEVERE",
        }
    }
}

/// An inline construct whose start-string never found its end-string. One
/// enum rather than six codes because docutils generates all six from one
/// template.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InlineConstruct {
    Emphasis,
    Strong,
    Literal,
    /// `` `x` `` / `` :role:`x` `` — docutils' "interpreted text or phrase
    /// reference".
    InterpretedText,
    Target,
    SubstitutionReference,
}

impl InlineConstruct {
    pub const ALL: [InlineConstruct; 6] = [
        InlineConstruct::Emphasis,
        InlineConstruct::Strong,
        InlineConstruct::Literal,
        InlineConstruct::InterpretedText,
        InlineConstruct::Target,
        InlineConstruct::SubstitutionReference,
    ];
}

/// A block construct that ended by dedenting instead of by a blank line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BlockConstruct {
    ExplicitMarkup,
    BulletList,
    EnumeratedList,
    DefinitionList,
    FieldList,
    BlockQuote,
    LiteralBlock,
}

impl BlockConstruct {
    pub const ALL: [BlockConstruct; 7] = [
        BlockConstruct::ExplicitMarkup,
        BlockConstruct::BulletList,
        BlockConstruct::EnumeratedList,
        BlockConstruct::DefinitionList,
        BlockConstruct::FieldList,
        BlockConstruct::BlockQuote,
        BlockConstruct::LiteralBlock,
    ];
}

/// Which way a grid/simple table was malformed — one code with a detail.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TableDefect {
    /// No detail — a bare `Malformed table.`
    Unspecified,
    ParseIncomplete,
    NoBottomBorder,
    NoBottomBorderOrBlankLine,
    BottomHeaderBorderMismatch,
    /// These three carry the offending table-relative line number.
    TextInColumnMargin,
    ColumnSpanAlignment,
    ColumnSpanIncomplete,
}

impl TableDefect {
    pub const ALL: [TableDefect; 8] = [
        TableDefect::Unspecified,
        TableDefect::ParseIncomplete,
        TableDefect::NoBottomBorder,
        TableDefect::NoBottomBorderOrBlankLine,
        TableDefect::BottomHeaderBorderMismatch,
        TableDefect::TextInColumnMargin,
        TableDefect::ColumnSpanAlignment,
        TableDefect::ColumnSpanIncomplete,
    ];

    /// Whether the defect interpolates a line number.
    pub fn has_line(self) -> bool {
        matches!(
            self,
            TableDefect::TextInColumnMargin | TableDefect::ColumnSpanAlignment | TableDefect::ColumnSpanIncomplete
        )
    }
}

/// What a code interpolates. A tagged union so that a code and its arguments
/// cannot disagree. String members are owned bytes (Zig borrows).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub enum Args {
    #[default]
    None,
    InlineConstruct(InlineConstruct),
    BlockConstruct(BlockConstruct),
    /// A hyperlink target name, or the `::` spelling in the literal-block hint.
    Name(Vec<u8>),
    /// `Enumerated list start value not ordinal-1: "b" (ordinal 2)`.
    Ordinal {
        expected: u32,
        text: Vec<u8>,
        actual: u32,
    },
    Table {
        defect: TableDefect,
        line: u32,
    },
    /// `"widths" widths do not match the number of columns in table (2).`
    Widths {
        value: Vec<u8>,
        columns: u32,
    },
}

/// Tier A: the core-parser problems twig's rST parser reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Code {
    // ── inline markup ──
    InlineStartStringWithoutEndString,

    // ── block structure ──
    UnexpectedUnindent,
    LineBlockWithoutBlankLine,
    UnexpectedIndentation,
    BlankLineRequiredAfterTable,
    LiteralBlockExpected,
    InconsistentLiteralBlockQuoting,
    LiteralBlockHintAfterDefinition,

    // ── section titles and transitions ──
    UnexpectedSectionTitle,
    UnexpectedSectionTitleOrTransition,
    IncompleteSectionTitle,
    PossibleIncompleteSectionTitle,
    TitleUnderlineTooShort,
    PossibleTitleUnderlineTooShort,
    TitleOverlineTooShort,
    TitleOverlineUnderlineMismatch,
    MissingMatchingUnderlineForOverline,
    InvalidSectionTitleOrTransitionMarker,
    TitleLevelInconsistent,
    PossibleTitleOverlineOrTransition,

    // ── enumerated lists ──
    EnumeratedListStartNotOrdinal,

    // ── hyperlink targets ──
    DuplicateExplicitTargetName,
    DuplicateImplicitTargetName,
    MalformedHyperlinkTarget,

    // ── tables and figures ──
    MalformedTable,
    TableWidthsMismatch,
    FigureCaptionMustBeParagraph,
}

impl Code {
    pub const ALL: [Code; 27] = [
        Code::InlineStartStringWithoutEndString,
        Code::UnexpectedUnindent,
        Code::LineBlockWithoutBlankLine,
        Code::UnexpectedIndentation,
        Code::BlankLineRequiredAfterTable,
        Code::LiteralBlockExpected,
        Code::InconsistentLiteralBlockQuoting,
        Code::LiteralBlockHintAfterDefinition,
        Code::UnexpectedSectionTitle,
        Code::UnexpectedSectionTitleOrTransition,
        Code::IncompleteSectionTitle,
        Code::PossibleIncompleteSectionTitle,
        Code::TitleUnderlineTooShort,
        Code::PossibleTitleUnderlineTooShort,
        Code::TitleOverlineTooShort,
        Code::TitleOverlineUnderlineMismatch,
        Code::MissingMatchingUnderlineForOverline,
        Code::InvalidSectionTitleOrTransitionMarker,
        Code::TitleLevelInconsistent,
        Code::PossibleTitleOverlineOrTransition,
        Code::EnumeratedListStartNotOrdinal,
        Code::DuplicateExplicitTargetName,
        Code::DuplicateImplicitTargetName,
        Code::MalformedHyperlinkTarget,
        Code::MalformedTable,
        Code::TableWidthsMismatch,
        Code::FigureCaptionMustBeParagraph,
    ];

    /// The severity a code carries unless the parser overrides it.
    /// `DuplicateExplicitTargetName` is graded two ways by docutils, which is
    /// why `Diagnostic::severity` is a stored field.
    pub fn default_severity(self) -> Severity {
        use Code::*;
        match self {
            PossibleIncompleteSectionTitle
            | PossibleTitleUnderlineTooShort
            | PossibleTitleOverlineOrTransition
            | EnumeratedListStartNotOrdinal
            | DuplicateImplicitTargetName
            | LiteralBlockHintAfterDefinition => Severity::Info,

            InlineStartStringWithoutEndString
            | UnexpectedUnindent
            | LineBlockWithoutBlankLine
            | BlankLineRequiredAfterTable
            | LiteralBlockExpected
            | TitleUnderlineTooShort
            | TitleOverlineTooShort
            | MalformedHyperlinkTarget
            | DuplicateExplicitTargetName => Severity::Warning,

            UnexpectedIndentation
            | InconsistentLiteralBlockQuoting
            | InvalidSectionTitleOrTransitionMarker
            | MalformedTable
            | TableWidthsMismatch
            | FigureCaptionMustBeParagraph => Severity::Err,

            UnexpectedSectionTitle
            | UnexpectedSectionTitleOrTransition
            | IncompleteSectionTitle
            | TitleOverlineUnderlineMismatch
            | MissingMatchingUnderlineForOverline
            | TitleLevelInconsistent => Severity::Severe,
        }
    }
}

/// TWIG's teaching message for a code — not docutils'. Says what happened AND
/// what to write instead.
pub fn describe(code: Code) -> &'static str {
    use Code::*;
    match code {
        InlineStartStringWithoutEndString => {
            "this inline markup was opened but never closed, so it stays literal text; add the matching end-string, or escape the opener with a backslash if you meant it literally"
        }
        UnexpectedUnindent => {
            "this block ended by dedenting rather than with a blank line; insert a blank line before the following text"
        }
        LineBlockWithoutBlankLine => {
            "a line block must be followed by a blank line; insert one before the following text"
        }
        UnexpectedIndentation => {
            "this line is indented but nothing opened an indented block, so it was read as a block quote; remove the indentation, or add a blank line before it to make the block quote deliberate"
        }
        BlankLineRequiredAfterTable => "a table must be followed by a blank line; insert one before the following text",
        LiteralBlockExpected => {
            "a paragraph ended with `::` but no indented block followed; indent the literal block, or remove the `::`"
        }
        InconsistentLiteralBlockQuoting => {
            "a quoted literal block must use one quoting character throughout; make every line's leading character match the first"
        }
        LiteralBlockHintAfterDefinition => {
            "this looks like a literal block introduced by `::`, but with no blank line it was read as a definition list item; add a blank line if you meant a literal block"
        }
        UnexpectedSectionTitle => {
            "a section title appeared where the enclosing construct cannot contain one; move it to the document body"
        }
        UnexpectedSectionTitleOrTransition => {
            "a section title or transition appeared where the enclosing construct cannot contain one; move it to the document body"
        }
        IncompleteSectionTitle => {
            "a section title's overline or underline is missing its other half; supply both, or drop the overline"
        }
        PossibleIncompleteSectionTitle => {
            "this overline is shorter than the title text, so it was read as ordinary text rather than a section title; extend it to at least the title's width"
        }
        TitleUnderlineTooShort => {
            "a section title's underline is shorter than the title; extend it to at least the title's width"
        }
        PossibleTitleUnderlineTooShort => {
            "this looks like a section underline but is too short for the title, so it was read as ordinary text; extend it to at least the title's width"
        }
        TitleOverlineTooShort => {
            "a section title's overline is shorter than the title; extend it to at least the title's width"
        }
        TitleOverlineUnderlineMismatch => {
            "a section title's overline and underline use different characters or lengths; make them match"
        }
        MissingMatchingUnderlineForOverline => {
            "a section title has an overline but no underline; add an underline of the same character and length"
        }
        InvalidSectionTitleOrTransitionMarker => {
            "this punctuation run is neither a valid section underline nor a valid transition; a transition needs at least four repeated characters on its own line"
        }
        TitleLevelInconsistent => {
            "this title's underline character implies a section level that does not follow from the preceding sections; reuse the character that already marks this level"
        }
        PossibleTitleOverlineOrTransition => {
            "this punctuation run is too short to be a title overline or a transition, so it was read as ordinary text; use at least four characters"
        }
        EnumeratedListStartNotOrdinal => {
            "this list's first item is not the first ordinal, so it was read as ordinary text; start the list at the first ordinal, or use `#` for auto-numbering"
        }
        DuplicateExplicitTargetName => {
            "two explicit hyperlink targets share a name, so references to it are ambiguous; rename one"
        }
        DuplicateImplicitTargetName => {
            "two section titles produce the same implicit target name, so references to it are ambiguous; add an explicit target to disambiguate"
        }
        MalformedHyperlinkTarget => {
            "this explicit markup starts like a hyperlink target but does not parse as one; check the `.. _name: link` form"
        }
        MalformedTable => {
            "this table's borders do not form a consistent grid; check that every row's `+` and `|` line up with the column borders"
        }
        TableWidthsMismatch => {
            "the `:widths:` option lists a different number of entries than the table has columns; supply one width per column"
        }
        FigureCaptionMustBeParagraph => {
            "a figure's first body element must be a paragraph (the caption) or an empty comment; make it one"
        }
    }
}

/// A short noun phrase for a caret annotation, rustc-style.
pub fn short_label(code: Code) -> &'static str {
    use Code::*;
    match code {
        InlineStartStringWithoutEndString => "unclosed inline markup",
        UnexpectedUnindent => "unexpected unindent",
        LineBlockWithoutBlankLine => "missing blank line",
        UnexpectedIndentation => "unexpected indentation",
        BlankLineRequiredAfterTable => "missing blank line",
        LiteralBlockExpected => "no literal block",
        InconsistentLiteralBlockQuoting => "inconsistent quoting",
        LiteralBlockHintAfterDefinition => "read as a definition",
        UnexpectedSectionTitle => "unexpected section title",
        UnexpectedSectionTitleOrTransition => "unexpected title or transition",
        IncompleteSectionTitle => "incomplete section title",
        PossibleIncompleteSectionTitle => "overline too short",
        TitleUnderlineTooShort => "underline too short",
        PossibleTitleUnderlineTooShort => "underline too short",
        TitleOverlineTooShort => "overline too short",
        TitleOverlineUnderlineMismatch => "overline/underline mismatch",
        MissingMatchingUnderlineForOverline => "missing underline",
        InvalidSectionTitleOrTransitionMarker => "invalid marker",
        TitleLevelInconsistent => "inconsistent title level",
        PossibleTitleOverlineOrTransition => "too short for a transition",
        EnumeratedListStartNotOrdinal => "not the first ordinal",
        DuplicateExplicitTargetName => "duplicate target name",
        DuplicateImplicitTargetName => "duplicate implicit name",
        MalformedHyperlinkTarget => "malformed target",
        MalformedTable => "malformed table",
        TableWidthsMismatch => "widths/columns mismatch",
        FigureCaptionMustBeParagraph => "caption must be a paragraph",
    }
}

/// One reported problem. `span` is the offending source range — the caret
/// anchor, the LSP range, and the source of docutils' quoted excerpt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub code: Code,
    pub span: Span,
    /// Stored rather than derived from `code` (see `Code::default_severity`).
    pub severity: Severity,
    pub args: Args,
}

impl Diagnostic {
    /// A diagnostic taking the code's default severity.
    pub fn new(code: Code, span: Span, args: Args) -> Diagnostic {
        Diagnostic { code, span, severity: code.default_severity(), args }
    }

    /// 1-based line/column of the span's start, plus the offending line.
    pub fn locate<'a>(&self, source: &'a [u8]) -> Location<'a> {
        parse_diagnostic::locate_offset(source, self.span.start)
    }

    /// The offending source text — what docutils quotes into a message's
    /// `<literal_block>` child.
    pub fn excerpt<'a>(&self, source: &'a [u8]) -> &'a [u8] {
        self.span.of(source)
    }

    /// Render `file:line:col: <severity>: <twig's message>` + source line +
    /// caret.
    pub fn render_alloc(&self, source: &[u8], file: &[u8]) -> Vec<u8> {
        let label: &[u8] = match self.severity {
            Severity::Info => b"info",
            Severity::Warning => b"warning",
            Severity::Err => b"error",
            Severity::Severe => b"error",
        };
        parse_diagnostic::render_report_alloc(source, self.span.start, file, label, describe(self.code).as_bytes())
    }
}

/// Everything a parse reports besides the tree. One list in source order;
/// severity is a field to filter on.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
    pub diagnostics: Vec<Diagnostic>,
}

impl Report {
    pub fn count(&self, severity: Severity) -> usize {
        self.diagnostics.iter().filter(|d| d.severity == severity).count()
    }

    /// Whether anything at or above `severity` was reported — the question a
    /// `--strict` flag asks.
    pub fn has_at_least(&self, severity: Severity) -> bool {
        self.diagnostics.iter().any(|d| d.severity >= severity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_code_has_a_describe_and_a_short_label_and_they_are_distinct() {
        for a in Code::ALL {
            assert!(!describe(a).is_empty());
            assert!(!short_label(a).is_empty());
            for b in Code::ALL {
                if a == b {
                    continue;
                }
                assert_ne!(describe(a), describe(b));
            }
        }
    }

    #[test]
    fn severity_maps_to_docutils_levels_and_back() {
        for s in Severity::ALL {
            assert_eq!(Severity::from_level(s.level()), Some(s));
        }
        assert_eq!(Severity::Severe.type_name(), "SEVERE");
        assert_eq!(Severity::from_level(0), None);
    }

    #[test]
    fn init_takes_the_codes_default_severity_which_stays_overridable() {
        let mut d = Diagnostic::new(Code::DuplicateExplicitTargetName, Span::new(4, 9), Args::Name(b"target".to_vec()));
        assert_eq!(d.severity, Severity::Warning);
        d.severity = Severity::Info;
        assert_eq!(d.severity, Severity::Info);
    }

    #[test]
    fn a_diagnostics_excerpt_is_the_offending_source() {
        let src = b"Line 1.\n    Indented.\n";
        let d = Diagnostic::new(Code::UnexpectedIndentation, Span::new(8, 21), Args::None);
        assert_eq!(d.excerpt(src), b"    Indented.");
        assert_eq!(d.locate(src).line, 2);
    }

    #[test]
    fn report_filters_by_severity() {
        let r = Report {
            diagnostics: vec![
                Diagnostic::new(Code::UnexpectedIndentation, Span::new(0, 1), Args::None),
                Diagnostic::new(Code::DuplicateImplicitTargetName, Span::new(2, 3), Args::Name(b"x".to_vec())),
            ],
        };
        assert_eq!(r.count(Severity::Err), 1);
        assert_eq!(r.count(Severity::Info), 1);
        assert!(r.has_at_least(Severity::Err));
        assert!(!r.has_at_least(Severity::Severe));
    }

    #[test]
    fn render_alloc_uses_twigs_wording_not_docutils() {
        let src = b"Line 1.\n    Indented.\n";
        let d = Diagnostic::new(Code::UnexpectedIndentation, Span::new(8, 21), Args::None);
        let out = String::from_utf8(d.render_alloc(src, b"test.rst")).unwrap();
        assert!(out.contains("test.rst:2:1: error:"));
        assert!(out.contains("add a blank line"));
    }
}
