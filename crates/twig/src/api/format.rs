//! The two format axes ([`Format`], [`Target`]), the authoring vocabulary
//! ([`Gesture`] and the kinds it carries), the capability queries, and the
//! version surface. Port of the `twig_format_*` half of `src/c_abi.zig` and of
//! the binding's matching types.

use std::collections::HashMap;
use std::os::raw::c_int;
use std::sync::{Mutex, OnceLock};

use crate::ast::editor as engine_editor;
use crate::error::Error;
use crate::format as reg;
use crate::runtime;

/// Every format Twig can **parse** — the input axis, as opposed to [`Target`],
/// which is where output bytes can go. `#[non_exhaustive]`: match with a `_`
/// arm.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Format {
    Djot,
    Markdown,
    Xml,
    Html,
    /// Parsed, rendered, serialized and authored into; the footnote and table
    /// gestures report [`Error::UnsupportedFormat`].
    Asciidoc,
    /// Strict CommonMark 0.31.2: a **dialect** of [`Format::Markdown`].
    Commonmark,
    /// GitHub-Flavored Markdown, a dialect of [`Format::Markdown`].
    Gfm,
    /// SVG: a **dialect** of [`Format::Xml`].
    Svg,
    /// A language registered at runtime: a format this library did not
    /// compile in. Its id is valid for this process only; persist
    /// [`Format::name`] and resolve it again with [`Format::by_name`].
    Runtime(RuntimeId),
}

/// A registered language's handle: its format code in this process, at or
/// above the runtime base (4096). Assigned in registration order and never
/// stable across processes.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct RuntimeId(c_int);

impl RuntimeId {
    /// The format code this language is known by.
    pub fn code(self) -> c_int {
        self.0
    }

    /// The handle for an engine runtime code (for the runtime-language layer).
    pub(crate) fn from_engine(code: u16) -> RuntimeId {
        RuntimeId(code as c_int)
    }

    pub(crate) fn engine_code(self) -> u16 {
        self.0 as u16
    }
}

/// The C ABI's `TWIG_FORMAT_RUNTIME_BASE`.
#[allow(dead_code)]
pub(crate) const FORMAT_RUNTIME_BASE: c_int = runtime::BASE as c_int;

impl Format {
    /// The wire code for this format — a `TWIG_FORMAT_*` value, or a
    /// registered language's runtime code.
    pub fn code(self) -> c_int {
        match self {
            Format::Djot => 1,
            Format::Markdown => 2,
            Format::Xml => 3,
            Format::Html => 4,
            Format::Asciidoc => 5,
            Format::Commonmark => 6,
            Format::Gfm => 7,
            Format::Svg => 8,
            Format::Runtime(id) => id.0,
        }
    }

    /// The format a code names, if any: a compiled code, or a runtime code a
    /// registration holds (`intToFormat`).
    #[allow(dead_code)]
    pub(crate) fn from_code(code: c_int) -> Option<Format> {
        Some(match code {
            1 => Format::Djot,
            2 => Format::Markdown,
            3 => Format::Xml,
            4 => Format::Html,
            5 => Format::Asciidoc,
            6 => Format::Commonmark,
            7 => Format::Gfm,
            8 => Format::Svg,
            c if c >= FORMAT_RUNTIME_BASE => {
                return runtime::format_from_code(c as i64).map(Format::from_engine);
            }
            _ => return None,
        })
    }

    /// The engine's row for this format.
    pub(crate) fn to_engine(self) -> reg::Format {
        match self {
            Format::Djot => reg::Format::Djot,
            Format::Markdown => reg::Format::Markdown,
            Format::Xml => reg::Format::Xml,
            Format::Html => reg::Format::Html,
            Format::Asciidoc => reg::Format::Asciidoc,
            Format::Commonmark => reg::Format::Commonmark,
            Format::Gfm => reg::Format::Gfm,
            Format::Svg => reg::Format::Svg,
            Format::Runtime(id) => reg::Format::Runtime(id.engine_code()),
        }
    }

    /// This format for an engine row.
    pub(crate) fn from_engine(f: reg::Format) -> Format {
        match f {
            reg::Format::Djot => Format::Djot,
            reg::Format::Markdown => Format::Markdown,
            reg::Format::Xml => Format::Xml,
            reg::Format::Html => Format::Html,
            reg::Format::Asciidoc => Format::Asciidoc,
            reg::Format::Commonmark => Format::Commonmark,
            reg::Format::Gfm => Format::Gfm,
            reg::Format::Svg => Format::Svg,
            reg::Format::Runtime(c) => Format::Runtime(RuntimeId::from_engine(c)),
        }
    }

    /// The engine row, refusing a runtime id no registration holds — the
    /// `intToFormat` gate every C entry point passes first.
    pub(crate) fn resolve(self) -> Result<reg::Format, Error> {
        match self {
            Format::Runtime(id) => {
                runtime::format_from_code(id.0 as i64).ok_or(Error::UnsupportedFormat)
            }
            f => Ok(f.to_engine()),
        }
    }

    /// The format a name resolves to, the lookup `twig convert -i` does: a
    /// compiled format's name or alias (`"md"`, `"gfm"`), or a registered
    /// language's name or alias.
    pub fn by_name(name: &str) -> Option<Format> {
        reg::parse_format_name(name).map(Format::from_engine)
    }

    /// The flags that turn `features` on over this row — what
    /// [`Document::parse_with_features`](crate::Document::parse_with_features)
    /// and [`Editor::new_with_features`](crate::Editor::new_with_features)
    /// pass. [`Error::UnsupportedFormat`] for a compiled format with no
    /// features; [`Error::NotFound`] for a name the row does not declare.
    pub fn feature_flags(self, features: &[&str]) -> Result<u32, Error> {
        let mut flags = 0u32;
        for name in features {
            flags |= feature_bit(self, name)?;
        }
        Ok(flags)
    }

    /// [`Format::supports`] for a runtime row with `features` laid over it.
    /// `false` for a name the language does not declare.
    pub fn supports_with_features(self, features: &[&str], gesture: Gesture) -> bool {
        let Ok(flags) = self.feature_flags(features) else {
            return false;
        };
        supports_ext(self, flags, gesture).unwrap_or(false)
    }

    /// The name this format answers to: `"markdown"`, `"gfm"`, or the name a
    /// runtime language registered under.
    pub fn name(self) -> &'static str {
        match self.resolve() {
            Ok(reg::Format::Runtime(c)) => intern(c),
            Ok(f) => f.static_name(),
            Err(_) => "unregistered",
        }
    }

    /// The language this format is a dialect of, or `None` for a language
    /// itself.
    pub fn dialect_of(self) -> Option<Format> {
        match self {
            Format::Commonmark | Format::Gfm => Some(Format::Markdown),
            Format::Svg => Some(Format::Xml),
            Format::Runtime(_) => {
                let f = self.resolve().ok()?;
                f.dialect_of().map(Format::from_engine)
            }
            _ => None,
        }
    }

    /// Whether this format can spell `gesture` — the toolbar's gray-out
    /// question, answered **without a document**. `true` means the gesture
    /// will not fail with [`Error::UnsupportedFormat`]; it is not a promise
    /// the call succeeds.
    pub fn supports(self, gesture: Gesture) -> bool {
        supports_ext(self, 0, gesture).unwrap_or(false)
    }

    /// [`Format::supports`] for a document parsed with `extensions` — the
    /// question asked of the table an [`Editor`](crate::Editor) created with
    /// them actually holds.
    pub fn supports_with(self, extensions: MarkdownExtensions, gesture: Gesture) -> bool {
        supports_ext(self, extensions.to_flags(), gesture).unwrap_or(false)
    }

    /// Whether this format can be authored into **at all** — `false` for a
    /// parse-only format ([`Format::Xml`]). Use [`Format::supports`] per
    /// button.
    pub fn is_authorable(self) -> bool {
        match self.resolve() {
            Ok(f) => reg::syntax_for(f).authorable(),
            Err(_) => false,
        }
    }
}

/// `twig_format_feature_bit`.
fn feature_bit(format: Format, name: &str) -> Result<u32, Error> {
    let fmt = format.resolve()?;
    if reg::features(fmt).is_empty() && !runtime::is_registered(fmt) {
        return Err(Error::UnsupportedFormat);
    }
    reg::feature_bit(fmt, name).ok_or(Error::NotFound)
}

/// `twig_format_supports_ext`: the engine's `supports` over the table the
/// flags move the row to.
fn supports_ext(format: Format, flags: u32, gesture: Gesture) -> Result<bool, Error> {
    let fmt = format.resolve()?;
    let cfg = reg::ParseConfig::for_features(fmt, flags);
    Ok(engine_editor::supports(reg::syntax_for_config(fmt, &cfg), gesture.to_engine()))
}

/// A runtime row's name, leaked once so it can be handed out as `&'static`
/// (the C ABI's "the library's bytes, for the life of the process").
fn intern(code: u16) -> &'static str {
    static NAMES: OnceLock<Mutex<HashMap<(u16, String), &'static str>>> = OnceLock::new();
    let name = runtime::name_of(code);
    let mut map = NAMES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    map.entry((code, name.clone())).or_insert_with(|| Box::leak(name.into_boxed_str()))
}

/// Every format Twig can **write** — the output axis. `#[non_exhaustive]`:
/// a future export-only target is an additive change.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Target {
    Djot,
    Markdown,
    Xml,
    Html,
    /// AsciiDoc source, in Asciidoctor's idiomatic spellings.
    Asciidoc,
    /// A registered language, as a place to write to.
    Runtime(RuntimeId),
}

impl Target {
    /// The [`Format`] whose parser reads this target's own output back, or
    /// `None` for an export-only target. Always `Some` today.
    pub fn as_format(self) -> Option<Format> {
        match self {
            Target::Djot => Some(Format::Djot),
            Target::Markdown => Some(Format::Markdown),
            Target::Xml => Some(Format::Xml),
            Target::Html => Some(Format::Html),
            Target::Asciidoc => Some(Format::Asciidoc),
            Target::Runtime(id) => Some(Format::Runtime(id)),
        }
    }

    /// The wire code for this target. See [`Format::code`].
    pub fn code(self) -> c_int {
        match self {
            Target::Djot => 1,
            Target::Markdown => 2,
            Target::Xml => 3,
            Target::Html => 4,
            Target::Asciidoc => 5,
            Target::Runtime(id) => id.0,
        }
    }

    /// The name this target answers to. See [`Format::name`].
    pub fn name(self) -> &'static str {
        match self.as_format() {
            Some(f) => f.name(),
            None => "unregistered",
        }
    }

    /// `intToTarget`: the engine target, through the format the code names.
    pub(crate) fn resolve(self) -> Result<reg::Target, Error> {
        let fmt = self.as_format().ok_or(Error::UnsupportedFormat)?.resolve()?;
        Ok(reg::target_for(fmt))
    }
}

/// Total: every input format is also an output target. A dialect lands on
/// its language's target.
impl From<Format> for Target {
    fn from(value: Format) -> Self {
        match value {
            Format::Djot => Target::Djot,
            Format::Markdown | Format::Commonmark | Format::Gfm => Target::Markdown,
            Format::Xml | Format::Svg => Target::Xml,
            Format::Html => Target::Html,
            Format::Asciidoc => Target::Asciidoc,
            Format::Runtime(id) => Target::Runtime(id),
        }
    }
}

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
    /// Needs [`MarkdownExtensions::highlight_colors`] in Markdown: ask
    /// [`Format::supports_with`].
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

/// Opt-in Markdown extensions for a parse — the read path
/// ([`Document::parse_with`](crate::Document::parse_with)) or the edit path
/// ([`Editor::new_ext`](crate::Editor::new_ext)). Ignored for non-Markdown
/// formats. Each field is the Markdown row's feature of its name.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MarkdownExtensions {
    /// Generic directives: `:name`, `::name`, `:::name`.
    pub directives: bool,
    /// `$...$` / `$$...$$` math.
    pub math: bool,
    /// Parse recognized raw HTML into semantic AST nodes.
    pub html_elements: bool,
    /// `==text==` highlight, parsed as a `mark` node.
    pub highlight: bool,
    /// Coloured highlights on top of `highlight` (`==🔴 text==`). Turns
    /// `highlight` on with it.
    pub highlight_colors: bool,
}

/// `TWIG_MD_*` — the Markdown row's features, in order.
const TWIG_MD_DIRECTIVES: u32 = 1 << 0;
const TWIG_MD_MATH: u32 = 1 << 1;
const TWIG_MD_HTML_ELEMENTS: u32 = 1 << 2;
const TWIG_MD_HIGHLIGHT: u32 = 1 << 3;
const TWIG_MD_HIGHLIGHT_COLORS: u32 = 1 << 4;

impl MarkdownExtensions {
    pub(crate) fn to_flags(self) -> u32 {
        let mut flags = 0;
        if self.directives {
            flags |= TWIG_MD_DIRECTIVES;
        }
        if self.math {
            flags |= TWIG_MD_MATH;
        }
        if self.html_elements {
            flags |= TWIG_MD_HTML_ELEMENTS;
        }
        if self.highlight {
            flags |= TWIG_MD_HIGHLIGHT;
        }
        if self.highlight_colors {
            flags |= TWIG_MD_HIGHLIGHT_COLORS;
        }
        flags
    }
}

/// The parse config `flags` say over `fmt`'s row (`configFromFlags`).
pub(crate) fn config_from_flags(fmt: reg::Format, flags: u32) -> reg::ParseConfig {
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
