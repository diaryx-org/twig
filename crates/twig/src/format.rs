//! The two format axes: [`Format`] (what Twig can PARSE) and [`Target`] (what
//! it can WRITE), and the registry tying each to its parser and printers.
//! See `docs/DESIGN.md`'s "two format axes" and
//! `docs/proposals/language-crates.md`.
//!
//! ── The registry starts empty ──────────────────────────────────────────────
//! Core names no language. A program registers the languages it uses —
//! each a crate on `twig-kit` (`twig_markdown::register()`, or
//! [`register`] with the crate's language value) — and a format is a handle
//! to a row of the registry from then on. Two kinds of row share it:
//!
//! - a NATIVE row, from a compiled [`Language`]: twig's own language crates
//!   claim the `TWIG_FORMAT_*` code they have always had; any other is
//!   numbered from [`NATIVE_BASE`] as it registers;
//! - a RUNTIME row, from a language that exchanges node tables
//!   (`crate::language`, `runtime`), numbered from [`runtime::BASE`].
//!
//! Every dispatch below finds the row by its code and asks it; no function
//! here matches on a language.

use std::any::TypeId;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use crate::ast::Ast;
use crate::document::Document;
use crate::error::Error;
use crate::runtime;
use crate::syntax::{self, Syntax};

pub use twig_kit::language::{Language, PrintFailure, Row};

/// The first code a native row with no code of its own is given.
pub const NATIVE_BASE: u16 = 2048;

/// A format Twig can parse: a row of the registry, by its wire code (a
/// `TWIG_FORMAT_*` value, or a code the registry gave out). A dialect
/// (`commonmark`, `gfm`, `svg`) is a format of its own over its language's
/// parser. Only the registry hands one out, so a `Format` names a row that
/// is registered — persist [`Format::name`], not the code, for a language
/// with no `TWIG_FORMAT_*` code.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Format(u16);

/// A place output bytes can go: a language's own row, by its code.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Target(u16);

// ── Native rows ─────────────────────────────────────────────────────────────

#[derive(Clone)]
struct NativeRow {
    code: u16,
    lang: Arc<dyn Language>,
    /// The row's index among its language's rows.
    index: usize,
    /// The code of the language's own row (row 0).
    own: u16,
}

impl NativeRow {
    fn row(&self) -> &'static Row {
        &self.lang.rows()[self.index]
    }
}

struct Natives {
    rows: Vec<NativeRow>,
    /// Each registered language's type, and its own row's code.
    types: Vec<(TypeId, u16)>,
    next: u16,
}

static NATIVES: RwLock<Natives> = RwLock::new(Natives { rows: Vec::new(), types: Vec::new(), next: NATIVE_BASE });

fn natives() -> std::sync::RwLockReadGuard<'static, Natives> {
    NATIVES.read().unwrap_or_else(|e| e.into_inner())
}

fn native(code: u16) -> Option<NativeRow> {
    natives().rows.iter().find(|r| r.code == code).cloned()
}

fn native_rows() -> Vec<NativeRow> {
    natives().rows.clone()
}

/// The compiled language whose own row `target` is.
pub(crate) fn native_language(target: Target) -> Option<Arc<dyn Language>> {
    native(target.0).map(|r| r.lang)
}

/// Why a language was not registered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NativeRegisterError(pub String);

impl std::fmt::Display for NativeRegisterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NativeRegisterError {}

/// Register a compiled language: a row for each of its [`Language::rows`],
/// returning the `Format` of its own (row 0). Registering the same language
/// type again returns the format it already has. Refused, and nothing
/// registered, when a row's name, alias, extension or code is already a
/// format's.
pub fn register<L: Language>(language: L) -> Result<Format, NativeRegisterError> {
    let ty = TypeId::of::<L>();
    let _guard = runtime::register_lock();
    if let Some((_, own)) = natives().types.iter().find(|(t, _)| *t == ty) {
        return Ok(Format(*own));
    }
    let lang: Arc<dyn Language> = Arc::new(language);
    let rows = lang.rows();
    if rows.is_empty() {
        return Err(NativeRegisterError("a language has at least one row".into()));
    }
    let mut seen_names: Vec<&str> = Vec::new();
    let mut seen_exts: Vec<&str> = Vec::new();
    let mut next = natives().next;
    let mut codes = Vec::new();
    for row in rows {
        for name in std::iter::once(&row.name).chain(row.aliases) {
            if parse_format_name(name).is_some() || seen_names.contains(name) {
                return Err(NativeRegisterError(format!("the name \"{name}\" is already a format's")));
            }
            seen_names.push(name);
        }
        for e in row.extensions {
            if let Some(owner) = detect_from_extension(&format!("x.{e}")) {
                return Err(NativeRegisterError(format!("{}: the extension \"{e}\" is {}'s", row.name, owner.name())));
            }
            if seen_exts.contains(e) {
                return Err(NativeRegisterError(format!("{}: the extension \"{e}\" is given twice", row.name)));
            }
            seen_exts.push(e);
        }
        let code = match row.code {
            Some(c) => {
                if c == 0 || c >= NATIVE_BASE || native(c).is_some() || codes.contains(&c) {
                    return Err(NativeRegisterError(format!("{}: the code {c} is not free", row.name)));
                }
                c
            }
            None => {
                if next >= runtime::BASE {
                    return Err(NativeRegisterError("the registry is full".into()));
                }
                next += 1;
                next - 1
            }
        };
        codes.push(code);
    }
    let own = codes[0];
    let mut n = NATIVES.write().unwrap_or_else(|e| e.into_inner());
    for (index, code) in codes.into_iter().enumerate() {
        n.rows.push(NativeRow { code, lang: lang.clone(), index, own });
    }
    n.types.push((ty, own));
    n.next = next;
    Ok(Format(own))
}

// ── Format ──────────────────────────────────────────────────────────────────

impl Format {
    /// The format a wire code names, if a row holds it.
    pub fn from_code(code: i64) -> Option<Format> {
        let c = u16::try_from(code).ok()?;
        if native(c).is_some() {
            return Some(Format(c));
        }
        runtime::format_from_code(code)
    }

    /// A format for a code the caller knows a row holds or is loading.
    pub(crate) fn from_raw(code: u16) -> Format {
        Format(code)
    }

    /// The wire code: a `TWIG_FORMAT_*` value, or one the registry gave out.
    pub fn code(self) -> u16 {
        self.0
    }

    /// The format a name resolves to — the lookup `twig convert -i` does: a
    /// native row's name, then its alias, then a runtime language's name or
    /// alias.
    pub fn by_name(name: &str) -> Option<Format> {
        parse_format_name(name)
    }

    /// The name this format answers to: `"markdown"`, `"gfm"`, or the name a
    /// runtime language registered under; `"unregistered"` for none.
    pub fn name(self) -> &'static str {
        if let Some(r) = native(self.0) {
            return r.row().name;
        }
        if self.is_runtime() {
            return intern(self.0);
        }
        "unregistered"
    }

    /// Whether a registration through the node-table contract made the row.
    pub fn is_runtime(self) -> bool {
        self.0 >= runtime::BASE
    }

    /// Whether the registry holds this format.
    pub fn is_registered(self) -> bool {
        native(self.0).is_some() || runtime::is_registered(self)
    }

    /// The language this format is a dialect of, or `None` for a language
    /// itself.
    pub fn dialect_of(self) -> Option<Format> {
        if let Some(r) = native(self.0) {
            return (r.index != 0).then_some(Format(r.own));
        }
        if self.is_runtime() {
            return runtime::dialect_of(self.0);
        }
        None
    }

    /// The file extensions that select this row.
    pub fn extensions(self) -> Vec<String> {
        if let Some(r) = native(self.0) {
            return r.row().extensions.iter().map(|s| s.to_string()).collect();
        }
        runtime::row(self.0).map(|r| r.extensions).unwrap_or_default()
    }

    /// The further names this row answers to.
    pub fn aliases(self) -> Vec<String> {
        if let Some(r) = native(self.0) {
            return r.row().aliases.iter().map(|s| s.to_string()).collect();
        }
        runtime::row(self.0).map(|r| r.aliases).unwrap_or_default()
    }

    /// Where this format's own syntax is written: its language's target.
    pub fn target(self) -> Target {
        target_for(self)
    }

    /// The registered format, or [`Error::UnsupportedFormat`] for a code no
    /// row holds — the gate every entry point passes first.
    pub(crate) fn resolve(self) -> Result<Format, Error> {
        if self.is_registered() { Ok(self) } else { Err(Error::UnsupportedFormat) }
    }

    /// The flags that turn `features` on over this row — what
    /// [`Document::parse_with_features`](crate::Document::parse_with_features)
    /// and [`Editor::new_with_features`](crate::Editor::new_with_features)
    /// pass. [`Error::UnsupportedFormat`] for a format with no features;
    /// [`Error::NotFound`] for a name the row does not declare.
    pub fn feature_flags(self, features: &[&str]) -> Result<u32, Error> {
        let fmt = self.resolve()?;
        let declared = self::features(fmt);
        let mut flags = 0u32;
        for name in features {
            if declared.is_empty() && !fmt.is_runtime() {
                return Err(Error::UnsupportedFormat);
            }
            flags |= feature_bit(fmt, name).ok_or(Error::NotFound)?;
        }
        Ok(flags)
    }

    /// Whether this format can spell `gesture` — the toolbar's gray-out
    /// question, answered **without a document**. `true` means the gesture
    /// will not fail with [`Error::UnsupportedFormat`]; it is not a promise
    /// the call succeeds.
    pub fn supports(self, gesture: crate::api::Gesture) -> bool {
        self.supports_flags(0, gesture)
    }

    /// [`Format::supports`] for a row with `features` laid over it. `false`
    /// for a name the language does not declare.
    pub fn supports_with_features(self, features: &[&str], gesture: crate::api::Gesture) -> bool {
        let Ok(flags) = self.feature_flags(features) else {
            return false;
        };
        self.supports_flags(flags, gesture)
    }

    /// [`Format::supports`] under a feature mask.
    pub fn supports_flags(self, flags: u32, gesture: crate::api::Gesture) -> bool {
        let Ok(fmt) = self.resolve() else { return false };
        let cfg = ParseConfig::for_features(fmt, flags);
        crate::ast::editor::supports(syntax_for_config(fmt, &cfg), gesture.to_engine())
    }

    /// Whether this format can be authored into **at all** — `false` for a
    /// parse-only format (XML). Use [`Format::supports`] per button.
    pub fn is_authorable(self) -> bool {
        match self.resolve() {
            Ok(f) => syntax_for(f).authorable(),
            Err(_) => false,
        }
    }
}

impl std::fmt::Display for Format {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// A runtime row's name, leaked once so it can be handed out as `&'static`
/// (the C ABI's "the library's bytes, for the life of the process").
fn intern(code: u16) -> &'static str {
    static NAMES: OnceLock<Mutex<HashMap<(u16, String), &'static str>>> = OnceLock::new();
    let name = runtime::name_of(code);
    let mut map = NAMES.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    map.entry((code, name.clone())).or_insert_with(|| Box::leak(name.into_boxed_str()))
}

// ── Target ──────────────────────────────────────────────────────────────────

impl Target {
    /// The wire code: the code of the language's own row.
    pub fn code(self) -> u16 {
        self.0
    }

    /// The name this target answers to: its language's.
    pub fn name(self) -> &'static str {
        Format(self.0).name()
    }

    /// The format whose parser reads this target's own output back.
    pub fn as_format(self) -> Option<Format> {
        let f = Format(self.0);
        f.is_registered().then_some(f)
    }

    /// The registered target, or [`Error::UnsupportedFormat`].
    pub(crate) fn resolve(self) -> Result<Target, Error> {
        Format(self.0).resolve().map(target_for)
    }
}

impl std::fmt::Display for Target {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// Total: every input format is also an output target. A dialect lands on
/// its language's target.
impl From<Format> for Target {
    fn from(f: Format) -> Target {
        target_for(f)
    }
}

pub fn target_for(fmt: Format) -> Target {
    if let Some(r) = native(fmt.0) {
        return Target(r.own);
    }
    if fmt.is_runtime() {
        return Target(runtime::target_code_of(fmt.0));
    }
    Target(fmt.0)
}

pub fn writes_own_syntax(fmt: Format, target: Target) -> bool {
    target_for(fmt) == target
}

/// Whether `target` can be written from a bare tree (its `serializeFromAst`
/// slot). XML's printer needs the `Document` it parsed, so it cannot.
pub fn target_serializes_from_ast(target: Target) -> bool {
    if let Some(r) = native(target.0) {
        return r.lang.serializes_from_ast();
    }
    target.0 >= runtime::BASE && runtime::prints(target.0)
}

// ── Features ────────────────────────────────────────────────────────────────

/// A named switch a row's parser reads, as Markdown's extensions are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Feature {
    pub name: String,
    pub requires: Vec<String>,
}

/// The features `fmt`'s language declares, in bit order.
pub fn features(fmt: Format) -> Vec<Feature> {
    if let Some(r) = native(fmt.0) {
        return r
            .lang
            .features()
            .iter()
            .map(|f| Feature { name: f.name.to_string(), requires: f.requires.iter().map(|s| s.to_string()).collect() })
            .collect();
    }
    runtime::features_of(fmt)
}

pub fn feature_bit(fmt: Format, name: &str) -> Option<u32> {
    features(fmt).iter().position(|f| f.name == name).map(|i| 1u32 << i)
}

/// `mask` restricted to the declared features and closed under `requires`.
pub fn close_features(fmt: Format, mask: u32) -> u32 {
    let fs = features(fmt);
    let declared: u32 = if fs.len() >= 32 { !0 } else { (1u32 << fs.len()) - 1 };
    let mut out = mask & declared;
    loop {
        let mut grown = out;
        for (i, f) in fs.iter().enumerate() {
            if out & (1 << i) == 0 {
                continue;
            }
            for r in &f.requires {
                grown |= feature_bit(fmt, r).unwrap_or(0);
            }
        }
        if grown == out {
            return out;
        }
        out = grown;
    }
}

/// What a caller lays over the row it chose: a feature mask, in the order
/// the row's language declares its features.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct ParseConfig {
    pub features: u32,
}

impl ParseConfig {
    /// The config `mask` says over `fmt`: a native row's mask closed under
    /// `requires`; a runtime row's as given (the runtime closes it per call).
    pub fn for_features(fmt: Format, mask: u32) -> ParseConfig {
        if native(fmt.0).is_some() {
            return ParseConfig { features: close_features(fmt, mask) };
        }
        ParseConfig { features: mask }
    }
}

/// The features a call through native row `r` has on.
fn effective(r: &NativeRow, cfg: &ParseConfig) -> u32 {
    r.lang.row_features(r.index) | cfg.features
}

// ── Names ───────────────────────────────────────────────────────────────────

/// An input name to a `Format`: a native row's own name, then an alias, then
/// a runtime language's name.
pub fn parse_format_name(name: &str) -> Option<Format> {
    let rows = native_rows();
    if let Some(r) = rows.iter().find(|r| r.row().name == name) {
        return Some(Format(r.code));
    }
    if let Some(r) = rows.iter().find(|r| r.row().aliases.contains(&name)) {
        return Some(Format(r.code));
    }
    runtime::by_name(name)
}

pub fn parse_target_name(name: &str) -> Option<Target> {
    parse_format_name(name).map(target_for)
}

pub fn detect_from_extension(file_path: &str) -> Option<Format> {
    let dot = file_path.rfind('.')?;
    let ext = &file_path[dot + 1..];
    if ext.is_empty() {
        return None;
    }
    for r in native_rows() {
        if r.row().extensions.iter().any(|k| k.eq_ignore_ascii_case(ext)) {
            return Some(Format(r.code));
        }
    }
    runtime::by_extension(ext)
}

/// Every registered format, natives first, each in registration order.
pub fn registered() -> Vec<Format> {
    let mut out: Vec<Format> = native_rows().iter().map(|r| Format(r.code)).collect();
    out.extend(runtime::entries().iter().map(|r| r.format));
    out
}

/// Every registered target: each language's own row.
pub fn registered_targets() -> Vec<Target> {
    registered().into_iter().filter(|f| f.dialect_of().is_none()).map(target_for).collect()
}

// ── The registry ────────────────────────────────────────────────────────────

/// A parse plus the row and config that produced it — what the CLI and the
/// public API hold, since rendering depends on the dialect (GFM's HTML) and
/// the features.
#[derive(Clone, Debug)]
pub struct ParsedDoc {
    pub format: Format,
    pub config: ParseConfig,
    pub doc: Document,
}

/// Why a parse failed: the language's reason, for a message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseFailure(pub String);

impl ParseFailure {
    /// The reason a message prints.
    pub fn name(&self) -> String {
        self.0.clone()
    }
}

fn unregistered(fmt: Format) -> ParseFailure {
    ParseFailure(format!("{} is not a registered format", fmt.0))
}

/// Parse `source` as `fmt` into a bare `Document` — the splicer's reparse.
pub fn parse_to_ast(fmt: Format, cfg: &ParseConfig, source: &[u8]) -> Result<Document, ParseFailure> {
    if let Some(r) = native(fmt.0) {
        return r.lang.parse(r.index, effective(&r, cfg), source).map_err(ParseFailure);
    }
    if fmt.is_runtime() {
        return runtime::parse(fmt.0, cfg, source).map_err(ParseFailure);
    }
    Err(unregistered(fmt))
}

/// Parse `source[range]` as the run of whole blocks it is inside `source`,
/// the text of `doc` after an edit, under `fmt` and `cfg`
/// ([`Language::parse_fragment`]). `None` when the row's language cannot, a
/// runtime row's always, and the caller parses the whole document instead.
pub fn parse_fragment(
    fmt: Format,
    cfg: &ParseConfig,
    source: &[u8],
    range: std::ops::Range<usize>,
    doc: &Document,
) -> Option<Document> {
    let r = native(fmt.0)?;
    r.lang.parse_fragment(r.index, effective(&r, cfg), source, range, doc)
}

/// Parse `source` as `fmt`, remembering the row and config.
pub fn parse(fmt: Format, cfg: &ParseConfig, source: &[u8]) -> Result<ParsedDoc, ParseFailure> {
    Ok(ParsedDoc { format: fmt, config: *cfg, doc: parse_to_ast(fmt, cfg, source)? })
}

/// Whether `source` can carry `twig` settings: a frontmatter block opens the
/// document, and every fence twig reads one with is `---` or `+++`.
#[cfg(feature = "fig")]
fn could_hold_settings(source: &[u8]) -> bool {
    source.starts_with(b"---") || source.starts_with(b"+++")
}

/// Parse `source` as it asks to be read: as `fmt` under `cfg`, unless its
/// frontmatter's `twig` settings name a dialect of the same language or
/// features to lay over the caller's (`crate::meta::settings`), in which
/// case as they say. Without the `fig` feature, [`parse`].
pub fn parse_as_asked(fmt: Format, cfg: &ParseConfig, source: &[u8]) -> Result<ParsedDoc, ParseFailure> {
    let parsed = parse(fmt, cfg, source)?;
    #[cfg(feature = "fig")]
    if could_hold_settings(source) {
        if let Some((f, c)) = crate::meta::settings_override(&parsed.doc, fmt, cfg) {
            return parse(f, &c, source);
        }
    }
    Ok(parsed)
}

/// The row and config `source` asks to be read with ([`parse_as_asked`]),
/// for a caller that parses it itself — an editor, whose every reparse
/// keeps what the document asked for when it was opened.
pub fn resolve_as_asked(fmt: Format, cfg: &ParseConfig, source: &[u8]) -> (Format, ParseConfig) {
    #[cfg(feature = "fig")]
    if could_hold_settings(source) {
        if let Ok(doc) = parse_to_ast(fmt, cfg, source) {
            if let Some(over) = crate::meta::settings_override(&doc, fmt, cfg) {
                return over;
            }
        }
    }
    let _ = source;
    (fmt, *cfg)
}

/// Render a parse to HTML with its row's renderer.
pub fn render_html(doc: &ParsedDoc) -> Result<Vec<u8>, PrintFailure> {
    if let Some(r) = native(doc.format.0) {
        return r.lang.render_html(r.index, effective(&r, &doc.config), &doc.doc);
    }
    if doc.format.is_runtime() {
        return runtime::render_html(doc.format.0, doc);
    }
    Err(PrintFailure::UnsupportedFormat)
}

/// Serialize a parse back to its own format (`-o canonical`).
pub fn serialize_canonical(doc: &ParsedDoc) -> Result<Vec<u8>, PrintFailure> {
    if let Some(r) = native(doc.format.0) {
        return r.lang.serialize(r.index, effective(&r, &doc.config), &doc.doc);
    }
    if doc.format.is_runtime() {
        return runtime::serialize_canonical(doc.format.0, doc);
    }
    Err(PrintFailure::UnsupportedFormat)
}

/// Write a bare tree as `target` (a cross-format conversion).
pub fn serialize_from_ast(target: Target, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
    if let Some(r) = native(target.0) {
        return r.lang.serialize_ast(ast);
    }
    if target.0 >= runtime::BASE {
        return runtime::serialize_from_ast(target.0, ast);
    }
    Err(PrintFailure::UnsupportedFormat)
}

/// Write a `Document` as `target`, keeping what only the document carries
/// (spelling, labels). `UnsupportedFormat` where the target has no such
/// printer.
pub fn serialize_from_document(target: Target, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
    if let Some(r) = native(target.0) {
        return r.lang.serialize_document(doc);
    }
    if target.0 >= runtime::BASE {
        return runtime::serialize_from_document(target.0, doc);
    }
    Err(PrintFailure::UnsupportedFormat)
}

/// Write a tree a builder made as `target`, with the spelling it recorded.
pub fn serialize_built(target: Target, doc: &Document) -> Result<Vec<u8>, PrintFailure> {
    if let Some(r) = native(target.0) {
        return r.lang.serialize_built(doc);
    }
    serialize_from_ast(target, &doc.ast)
}

/// Convert a parse into `target`: the bare tree, except that a runtime row's
/// parse keeps its labels and spelling when the target can take them.
pub fn serialize_converted(doc: &ParsedDoc, target: Target) -> Result<Vec<u8>, PrintFailure> {
    if !target_serializes_from_ast(target) {
        return Err(PrintFailure::UnsupportedFormat);
    }
    if runtime::is_registered(doc.format) {
        match serialize_from_document(target, &doc.doc) {
            Err(PrintFailure::UnsupportedFormat) => {}
            other => return other,
        }
    }
    serialize_from_ast(target, &doc.doc.ast)
}

/// The spelling table a row's editor gestures write, under default options.
pub fn syntax_for(fmt: Format) -> &'static Syntax {
    syntax_for_config(fmt, &ParseConfig::default())
}

/// The spelling table for a row under a parse config — Markdown's depends on
/// which extensions are on.
pub fn syntax_for_config(fmt: Format, cfg: &ParseConfig) -> &'static Syntax {
    if let Some(r) = native(fmt.0) {
        return r.lang.syntax(r.index, effective(&r, cfg));
    }
    if fmt.is_runtime() {
        return runtime::syntax_for(fmt.0, cfg);
    }
    syntax::none()
}

/// The small documents a row is held to.
pub fn samples_of(fmt: Format) -> Vec<Vec<u8>> {
    if let Some(r) = native(fmt.0) {
        return r.lang.samples(r.index);
    }
    runtime::samples_of(fmt.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_languages as tl;

    #[test]
    fn markdown_extensions_are_features_in_flag_order() {
        for row in [tl::markdown(), tl::gfm(), tl::commonmark()] {
            assert_eq!(feature_bit(row, "math"), Some(1 << 1));
            assert_eq!(feature_bit(row, "highlight_colors"), Some(1 << 4));
        }
        let md = tl::markdown();
        assert_eq!(feature_bit(md, "tables"), None);
        assert!(features(tl::djot()).is_empty());
        let colors = feature_bit(md, "highlight_colors").unwrap();
        assert_eq!(close_features(md, colors), colors | feature_bit(md, "highlight").unwrap());
        let gfm = tl::gfm();
        let cfg = ParseConfig::for_features(gfm, colors | feature_bit(gfm, "math").unwrap());
        let ext = twig_markdown::language::extensions_from_mask(cfg.features);
        assert!(ext.highlight && ext.highlight_colors && ext.math);
        assert!(!ext.directives && !ext.html_elements);
        assert_eq!(close_features(tl::djot(), 0b111), 0);
    }

    #[test]
    fn names_and_extensions_resolve() {
        tl::all();
        assert_eq!(parse_format_name("dj"), Some(tl::djot()));
        assert_eq!(parse_format_name("markdown"), Some(tl::markdown()));
        assert_eq!(parse_format_name("gfm"), Some(tl::gfm()));
        assert_eq!(parse_format_name("adoc"), Some(tl::asciidoc()));
        assert_eq!(parse_format_name("nope"), None);
        assert_eq!(detect_from_extension("a/b.MD"), Some(tl::markdown()));
        assert_eq!(detect_from_extension("guide.ADOC"), Some(tl::asciidoc()));
        assert_eq!(detect_from_extension("drawing.svg"), Some(tl::svg()));
        assert_eq!(detect_from_extension("noext"), None);
        assert_eq!(parse_target_name("gfm"), Some(tl::markdown().target()));
        assert_eq!(parse_target_name("svg"), Some(tl::xml().target()));
        assert_eq!(parse_target_name("dj"), Some(tl::djot().target()));
        assert_eq!(parse_target_name("nope"), None);
    }

    #[test]
    fn every_format_is_a_target_and_they_agree() {
        for f in tl::all() {
            let t = target_for(f);
            let lang = f.dialect_of().unwrap_or(f);
            assert_eq!(lang.name(), t.name());
            assert_eq!(t.as_format(), Some(lang));
            assert!(writes_own_syntax(f, t));
        }
    }

    #[test]
    fn the_shipped_languages_keep_their_wire_codes() {
        let codes: Vec<u16> = tl::all().iter().map(|f| f.code()).collect();
        assert_eq!(codes, [1, 2, 6, 7, 3, 8, 4, 5]);
        assert_eq!(Format::from_code(2), Some(tl::markdown()));
        assert_eq!(Format::from_code(0), None);
    }

    #[test]
    fn a_language_registers_once_and_refuses_a_taken_name() {
        assert_eq!(register(twig_markdown::Markdown), Ok(tl::markdown()));
        struct Imposter;
        impl Language for Imposter {
            fn rows(&self) -> &'static [Row] {
                &[Row { name: "md", code: None, extensions: &[], aliases: &[] }]
            }
            fn samples(&self, _: usize) -> Vec<Vec<u8>> {
                Vec::new()
            }
            fn parse(&self, _: usize, _: u32, _: &[u8]) -> Result<Document, String> {
                Err("never".into())
            }
            fn serialize(&self, _: usize, _: u32, _: &Document) -> Result<Vec<u8>, PrintFailure> {
                Err(PrintFailure::UnsupportedFormat)
            }
            fn syntax(&self, _: usize, _: u32) -> &'static Syntax {
                syntax::none()
            }
        }
        tl::markdown();
        assert!(register(Imposter).unwrap_err().0.contains("already a format's"));
    }
}
