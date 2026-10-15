//! Event = the flat intermediate representation between scanning
//! (`block.rs` + `inline.rs`) and tree-building (`parser.rs`). Mirrors
//! djot.js's `src/event.ts` (`{startpos, endpos, annot}`) plus the full
//! vocabulary of `annot` strings the scanners emit and the parser dispatches
//! on.
//!
//! A whole document parses to one flat `Vec<Event>`. Container structure is
//! carried by *paired* annotations (`EmphOpen` / `EmphClose`) rather than
//! nesting; `parser.rs` turns matched pairs into a tree. Forward
//! references/footnotes and tight/loose list determination both need to see
//! the *whole* stream before they can be resolved.
//!
//! Where djot.js packs extra data onto an annot string via `|`-joined
//! suffixes (`"+list|-|*"`), `Event` carries that data in a typed side field
//! (`list_styles`).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub start: u32,
    pub end: u32,
    pub annot: Annotation,
    /// Only meaningful when `annot` is `ListOpen` or `ListItemOpen`: the
    /// candidate marker styles remaining after narrowing.
    pub list_styles: ListStyleCandidates,
}

impl Event {
    pub fn new(start: u32, end: u32, annot: Annotation) -> Event {
        Event { start, end, annot, list_styles: ListStyleCandidates::default() }
    }
}

pub type EventList = Vec<Event>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Numbering {
    Decimal,
    LowerAlpha,
    UpperAlpha,
    LowerRoman,
    UpperRoman,
}

/// Which punctuation wraps the number/letter: `1.`, `1)`, or `(1)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delim {
    Period,
    ParenAfter,
    ParenBoth,
}

/// A list item marker's possible interpretations. At most two ever arise (a
/// lone `i.`/`I.` is ambiguous between roman numeral one and the first letter
/// of the alphabet — roman first, so it wins if never narrowed).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListMarkerStyle {
    Dash,
    Plus,
    Star,
    Colon,
    DashTask,
    PlusTask,
    StarTask,
    Ordered { numbering: Numbering, delim: Delim },
}

impl ListMarkerStyle {
    pub fn eql(self, b: ListMarkerStyle) -> bool {
        self == b
    }

    pub fn is_task(self) -> bool {
        matches!(self, ListMarkerStyle::DashTask | ListMarkerStyle::PlusTask | ListMarkerStyle::StarTask)
    }
}

/// At most two candidate styles for one marker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ListStyleCandidates {
    pub items: [ListMarkerStyle; 2],
    pub len: u8,
}

impl Default for ListStyleCandidates {
    fn default() -> Self {
        ListStyleCandidates { items: [ListMarkerStyle::Dash; 2], len: 0 }
    }
}

impl ListStyleCandidates {
    pub fn single(s: ListMarkerStyle) -> Self {
        ListStyleCandidates { items: [s, s], len: 1 }
    }

    pub fn two(a: ListMarkerStyle, b: ListMarkerStyle) -> Self {
        ListStyleCandidates { items: [a, b], len: 2 }
    }

    pub fn slice(&self) -> &[ListMarkerStyle] {
        &self.items[..self.len as usize]
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn contains(&self, s: ListMarkerStyle) -> bool {
        self.slice().iter().any(|c| c.eql(s))
    }

    /// Intersect two candidate sets, preserving `self`'s order — so a
    /// still-ambiguous result keeps its original tie-break preference (roman
    /// before alpha).
    pub fn intersect(&self, other: &ListStyleCandidates) -> ListStyleCandidates {
        let mut result = ListStyleCandidates::default();
        for &c in self.slice() {
            if other.contains(c) {
                result.items[result.len as usize] = c;
                result.len += 1;
            }
        }
        result
    }
}

/// Every distinct event annotation the scanners emit and the parser
/// dispatches on. `*Open`/`*Close` pairs are djot.js's `"+x"`/`"-x"` strings;
/// everything else is a leaf.
///
/// `DestinationOpen` and `ReferenceOpen` don't open a new container (the
/// container was already pushed by a preceding `LinktextOpen`/
/// `ImagetextOpen`) — they only toggle the parser's literal-text mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Annotation {
    // ── Containers ──
    ReferenceDefinitionOpen,
    ReferenceDefinitionClose,
    EmphOpen,
    EmphClose,
    StrongOpen,
    StrongClose,
    SpanOpen,
    SpanClose,
    MarkOpen,
    MarkClose,
    SuperscriptOpen,
    SuperscriptClose,
    SubscriptOpen,
    SubscriptClose,
    DeleteOpen,
    DeleteClose,
    InsertOpen,
    InsertClose,
    DoubleQuotedOpen,
    DoubleQuotedClose,
    SingleQuotedOpen,
    SingleQuotedClose,
    AttributesOpen,
    AttributesClose,
    BlockAttributesOpen,
    BlockAttributesClose,
    LinktextOpen,
    LinktextClose,
    ImagetextOpen,
    ImagetextClose,
    DestinationOpen,
    DestinationClose,
    ReferenceOpen,
    ReferenceClose,
    VerbatimOpen,
    VerbatimClose,
    DisplayMathOpen,
    DisplayMathClose,
    InlineMathOpen,
    InlineMathClose,
    UrlOpen,
    UrlClose,
    EmailOpen,
    EmailClose,
    ParaOpen,
    ParaClose,
    HeadingOpen,
    HeadingClose,
    ListOpen,
    ListClose,
    ListItemOpen,
    ListItemClose,
    BlockQuoteOpen,
    BlockQuoteClose,
    TableOpen,
    TableClose,
    RowOpen,
    RowClose,
    CellOpen,
    CellClose,
    CaptionOpen,
    CaptionClose,
    FootnoteOpen,
    FootnoteClose,
    CodeBlockOpen,
    CodeBlockClose,
    DivOpen,
    DivClose,

    // ── Leaves ──
    Str,
    SoftBreak,
    /// The backslash itself, immediately before an escaped char/newline/space.
    Escape,
    HardBreak,
    NonBreakingSpace,
    /// A `:name:` symbol shortcode (span covers the surrounding colons).
    Symb,
    /// `[^label]` used inline (span covers the whole thing, incl. brackets).
    FootnoteReference,
    ReferenceKey,
    ReferenceValue,
    CheckboxChecked,
    CheckboxUnchecked,
    NoteLabel,
    CodeLanguage,
    RawFormat,
    /// A fenced div's bare class name, and the attribute parser's `.class`.
    Class,
    ThematicBreak,
    LeftSingleQuote,
    RightSingleQuote,
    LeftDoubleQuote,
    RightDoubleQuote,
    Ellipses,
    EnDash,
    EmDash,
    /// Recorded so `parser.rs` can determine tight/loose lists.
    Blankline,
    SeparatorDefault,
    SeparatorLeft,
    SeparatorRight,
    SeparatorCenter,
    /// The `!` before an image's `[`.
    ImageMarker,
    /// An explicit `{` open/close marker for a brace-delimited construct.
    OpenMarker,

    // ── Attribute-parser leaves ──
    AttrSpace,
    AttrIdMarker,
    Id,
    AttrClassMarker,
    Key,
    AttrEqualMarker,
    AttrQuoteMarker,
    Value,
    /// `%...%` comment inside an attribute block (discarded).
    Comment,
}
