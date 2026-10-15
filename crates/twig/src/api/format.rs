//! The two format axes ([`Format`], [`Target`] — the registry's handles,
//! re-exported from [`crate::format`]), the authoring vocabulary
//! ([`Gesture`] and the kinds it carries), and the version surface. Port of
//! the `twig_format_*` half of `src/c_abi.zig` and of the binding's matching
//! types.

use crate::ast::editor as engine_editor;
use crate::format as reg;

pub use crate::format::{Format, Target};

/// The C ABI's `TWIG_FORMAT_RUNTIME_BASE`.
pub const FORMAT_RUNTIME_BASE: u16 = crate::runtime::BASE;

// ── The authoring vocabulary ────────────────────────────────────────────────

/// An inline mark for [`Editor::wrap_range`](crate::Editor::wrap_range) /
/// [`Editor::toggle_inline`](crate::Editor::toggle_inline).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineKind {
    Strong,
    Emph,
    Verbatim,
    Mark,
    Superscript,
    Subscript,
    Insert,
    Delete,
}

impl InlineKind {
    pub(crate) fn to_engine(self) -> engine_editor::InlineKind {
        use engine_editor::InlineKind as E;
        match self {
            InlineKind::Strong => E::Strong,
            InlineKind::Emph => E::Emph,
            InlineKind::Verbatim => E::Verbatim,
            InlineKind::Mark => E::Mark,
            InlineKind::Superscript => E::Superscript,
            InlineKind::Subscript => E::Subscript,
            InlineKind::Insert => E::Insert,
            InlineKind::Delete => E::Delete,
        }
    }
}

/// A block target for [`Editor::set_block`](crate::Editor::set_block).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockKind {
    Paragraph,
    /// A heading of the given level (1–6; out of range is
    /// [`Error::InvalidArgument`]).
    Heading(u32),
}

/// A block container for
/// [`Editor::toggle_block_container`](crate::Editor::toggle_block_container).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockContainerKind {
    BlockQuote,
    BulletList,
    OrderedList,
}

impl BlockContainerKind {
    pub(crate) fn to_engine(self) -> engine_editor::ContainerKind {
        use engine_editor::ContainerKind as E;
        match self {
            BlockContainerKind::BlockQuote => E::BlockQuote,
            BlockContainerKind::BulletList => E::BulletList,
            BlockContainerKind::OrderedList => E::OrderedList,
        }
    }
}

/// The colour of a highlight — the palette
/// [`Editor::set_mark_color`](crate::Editor::set_mark_color) writes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MarkColor {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Brown,
}

impl MarkColor {
    /// The `data-color` value — `"red"`.
    pub fn as_str(self) -> &'static str {
        match self {
            MarkColor::Red => "red",
            MarkColor::Orange => "orange",
            MarkColor::Yellow => "yellow",
            MarkColor::Green => "green",
            MarkColor::Blue => "blue",
            MarkColor::Purple => "purple",
            MarkColor::Brown => "brown",
        }
    }

    /// The colour a `data-color` attribute names, or `None` for a value this
    /// build has no spelling for.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        Some(match s {
            "red" => MarkColor::Red,
            "orange" => MarkColor::Orange,
            "yellow" => MarkColor::Yellow,
            "green" => MarkColor::Green,
            "blue" => MarkColor::Blue,
            "purple" => MarkColor::Purple,
            "brown" => MarkColor::Brown,
            _ => return None,
        })
    }
}

/// One authoring gesture, named with whatever kind it takes — the question
/// [`Format::supports`] answers. `#[non_exhaustive]`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Gesture {
    WrapRange(InlineKind),
    ToggleInline(InlineKind),
    SetBlock,
    ToggleBlockContainer(BlockContainerKind),
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
    RenumberOrderedLists,
    TableInsertRow,
    TableDeleteRow,
    TableInsertColumn,
    TableDeleteColumn,
    TableSetAlignment,
    TableMoveRow,
    TableMoveColumn,
    /// Needs Markdown's `highlight_colors` feature: ask
    /// [`Format::supports_with_features`].
    SetMarkColor,
    InsertTable,
    InsertDirective,
    SetBlockAttrs,
    WrapRangeAttrs,
    JoinBlocks,
    SetNodeAttrs,
    MoveBlock,
    InsertInlineMath,
    InsertDisplayMath,
    ToggleLineBlock,
}

impl Gesture {
    pub(crate) fn to_engine(self) -> engine_editor::Gesture {
        use engine_editor::Gesture as E;
        match self {
            Gesture::WrapRange(k) => E::WrapRange(k.to_engine()),
            Gesture::ToggleInline(k) => E::ToggleInline(k.to_engine()),
            Gesture::SetBlock => E::SetBlock,
            Gesture::ToggleBlockContainer(k) => E::ToggleBlockContainer(k.to_engine()),
            Gesture::InsertThematicBreak => E::InsertThematicBreak,
            Gesture::ToggleCodeBlock => E::ToggleCodeBlock,
            Gesture::SetCodeLanguage => E::SetCodeLanguage,
            Gesture::ToggleTaskItem => E::ToggleTaskItem,
            Gesture::SetTaskChecked => E::SetTaskChecked,
            Gesture::ToggleTaskChecked => E::ToggleTaskChecked,
            Gesture::InsertLink => E::InsertLink,
            Gesture::InsertImage => E::InsertImage,
            Gesture::InsertFootnote => E::InsertFootnote,
            Gesture::InsertLiteral => E::InsertLiteral,
            Gesture::InsertLineBreak => E::InsertLineBreak,
            Gesture::SplitBlock => E::SplitBlock,
            Gesture::RenumberOrderedLists => E::RenumberOrderedLists,
            Gesture::TableInsertRow => E::TableInsertRow,
            Gesture::TableDeleteRow => E::TableDeleteRow,
            Gesture::TableInsertColumn => E::TableInsertColumn,
            Gesture::TableDeleteColumn => E::TableDeleteColumn,
            Gesture::TableSetAlignment => E::TableSetAlignment,
            Gesture::TableMoveRow => E::TableMoveRow,
            Gesture::TableMoveColumn => E::TableMoveColumn,
            Gesture::SetMarkColor => E::SetMarkColor,
            Gesture::InsertTable => E::InsertTable,
            Gesture::InsertDirective => E::InsertDirective,
            Gesture::SetBlockAttrs => E::SetBlockAttrs,
            Gesture::WrapRangeAttrs => E::WrapRangeAttrs,
            Gesture::JoinBlocks => E::JoinBlocks,
            Gesture::SetNodeAttrs => E::SetNodeAttrs,
            Gesture::MoveBlock => E::MoveBlock,
            Gesture::InsertInlineMath => E::InsertInlineMath,
            Gesture::InsertDisplayMath => E::InsertDisplayMath,
            Gesture::ToggleLineBlock => E::ToggleLineBlock,
        }
    }
}

/// The parse config `flags` say over `fmt`'s row (`configFromFlags`).
pub(crate) fn config_from_flags(fmt: Format, flags: u32) -> reg::ParseConfig {
    reg::ParseConfig::for_features(fmt, flags)
}

// ── Version ─────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
}

const fn parse_u8(s: &str) -> u8 {
    let b = s.as_bytes();
    let mut i = 0;
    let mut n: u32 = 0;
    while i < b.len() {
        n = n * 10 + (b[i] - b'0') as u32;
        i += 1;
    }
    n as u8
}

/// This library's semantic version.
pub fn version() -> Version {
    Version {
        major: parse_u8(env!("CARGO_PKG_VERSION_MAJOR")),
        minor: parse_u8(env!("CARGO_PKG_VERSION_MINOR")),
        patch: parse_u8(env!("CARGO_PKG_VERSION_PATCH")),
    }
}

/// The ABI contract version this crate's surface mirrors. There is no C
/// layer under this crate any more; it is kept so code that checks it keeps
/// compiling, and always agrees with [`abi_version`].
pub const ABI_VERSION: u32 = 6;

/// The ABI contract version of the "linked library" — this crate itself, so
/// always [`ABI_VERSION`].
pub fn abi_version() -> u32 {
    ABI_VERSION
}

/// `"MAJOR.MINOR.PATCH"`.
pub fn version_string() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
