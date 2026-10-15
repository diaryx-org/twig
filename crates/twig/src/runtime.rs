//! Languages registered at runtime: a format twig did not compile in, carried
//! by a table of functions that parse into the node table (`ast/table.rs`)
//! and print from it. Port of `src/runtime.zig`;
//! `docs/proposals/runtime-languages.md` is the argument.
//!
//! ── What a registration becomes ────────────────────────────────────────────
//! Rows like any other. [`register`] hands back a `Format::Runtime(code)`
//! whose code is the language's C wire code, [`BASE`] and up, and from then on
//! the format layer's dispatch (`format::parse`, `render_html`,
//! `serialize_*`, `syntax_for_config`) reaches it through the functions here:
//! `parse` calls the language and decodes its table, `render_html` is the
//! shared printer over that table with core's labels, and a language that
//! prints serializes canonically and from a bare tree.
//!
//! ── Features and sets ──────────────────────────────────────────────────────
//! A language may declare FEATURES — named switches its parser reads, as
//! Markdown's extensions are — and SETS, each a name for a list of them, as
//! `gfm` is a name for Markdown's. The language's own row parses with the
//! features it declares on by default; each set is a row of its own, with a
//! `Format` of its own, `dialect_of` the language's row. A caller lays more
//! features over a row through `ParseConfig::features`, a mask in declaration
//! order, and can only turn features on. A feature may require others, which
//! come on with it. The language is told the features in force on every call,
//! by mask and by name ([`Call`]).
//!
//! ── The author tier ────────────────────────────────────────────────────────
//! A language that declares `caps.author` hands over a `syntax` — the table
//! `syntax_json` reads — and, per feature, a PATCH: a partial table whose
//! members replace the base's while the feature is on. A patch replaces a
//! member whole, except in the three keyed tables (`inline_delims`,
//! `text_leaf_delims`, `container_spelling`), where it replaces per key. Two
//! features may not patch the same member or key. The table for a combination
//! of features is built on first use, validated, and kept; one that breaks a
//! rule spells nothing, and [`last_failure`] says why.
//!
//! ── Load is the validation moment ──────────────────────────────────────────
//! `register` holds a language to what it declares before any row exists: the
//! description is well-formed and claims no name or extension a row already
//! has; then `contract::all` over every row's own features, each with one
//! feature more, and with every feature on. The fidelity probe runs over each
//! row that prints.
//!
//! ── Concurrency ────────────────────────────────────────────────────────────
//! Append-only. A registration fills its slots under a registration lock and
//! publishes them by bumping the published count; a slot never changes once
//! published but for its cache of combinations, which is append-only under
//! its own lock. There is no unregistration.

use std::cell::RefCell;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use crate::ast::{table as node_table, Ast, NodeId};
use crate::contract;
use crate::diagnostics::{self, Measured};
use crate::document::Document;
use crate::format::{self, Format, ParseConfig, ParsedDoc, PrintFailure, Target};
use crate::json::{self, Value};
use crate::syntax::{self, Syntax, TextPosition, TextRenderer};
use crate::syntax_json::{self, Renderers};

/// The first `Format`/`Target` code — and C wire code — a registration is
/// given.
pub const BASE: u16 = 4096;

/// How many rows one process may register: a language's own, and one per set.
pub const CAPACITY: usize = 64;

/// How many features one language may declare: one bit each of a `u32`.
pub const MAX_FEATURES: usize = 32;

/// Which call a language is answering: the row it registered under, and the
/// features in force — the row's own and whatever the caller laid over them.
#[derive(Clone, Copy, Debug)]
pub struct Call<'a> {
    /// The language's name, or a set's.
    pub row: &'a str,
    /// Bit `i` is the description's `features[i]`.
    pub features: u32,
    /// The same features, by name, in declaration order.
    pub feature_names: &'a [&'a str],
}

/// One renderer's question, as the table names it (`syntax_json::Renderers`).
#[derive(Clone, Copy, Debug)]
pub enum Render<'a> {
    /// Spell `text` so it reparses as itself in `position`.
    RenderText { text: &'a [u8], position: TextPosition },
    /// Spell a fragment: a node table without positions, rooted at the node
    /// to print.
    RenderBlock(&'a [u8]),
    /// Whether a `<dest>` run, brackets included, spells an autolink.
    /// Answered `true` or `false`.
    SpellsAutolink(&'a [u8]),
}

impl Render<'_> {
    /// The Zig tag name, which messages print.
    pub fn tag_name(&self) -> &'static str {
        match self {
            Render::RenderText { .. } => "render_text",
            Render::RenderBlock(_) => "render_block",
            Render::SpellsAutolink(_) => "spells_autolink",
        }
    }
}

/// The wire name of a text position.
pub fn position_name(p: TextPosition) -> &'static str {
    match p {
        TextPosition::InlineText => "inline_text",
        TextPosition::BlockStart => "block_start",
        TextPosition::Verbatim => "verbatim",
    }
}

pub fn position_from_name(s: &[u8]) -> Option<TextPosition> {
    TextPosition::ALL.into_iter().find(|p| position_name(*p).as_bytes() == s)
}

/// A language function: its answer, or its reason (Zig's `diag` writer
/// beside `error.LanguageFailed`; may be empty).
pub type LanguageFn = Box<dyn Fn(&Call, &[u8]) -> Result<Vec<u8>, String> + Send + Sync>;
pub type RenderFn = Box<dyn Fn(&Call, &Render) -> Result<Vec<u8>, String> + Send + Sync>;

/// The functions a runtime language supplies. Each exchanges the node table
/// as JSON text; `call` names the row and the features, so one set of
/// functions serves every row a language registers.
pub struct Language {
    /// `source` to the node table of its parse.
    pub parse: LanguageFn,
    /// A node table to source. `None` for a language that only reads.
    pub print: Option<LanguageFn>,
    /// The renderers the description's `syntax` names. `None` for a
    /// language that names none — or only `render_block`, which `print`
    /// then answers.
    pub render: Option<RenderFn>,
}

impl Language {
    pub fn new(parse: impl Fn(&Call, &[u8]) -> Result<Vec<u8>, String> + Send + Sync + 'static) -> Language {
        Language { parse: Box::new(parse), print: None, render: None }
    }
    pub fn with_print(mut self, print: impl Fn(&Call, &[u8]) -> Result<Vec<u8>, String> + Send + Sync + 'static) -> Language {
        self.print = Some(Box::new(print));
        self
    }
    pub fn with_render(mut self, render: impl Fn(&Call, &Render) -> Result<Vec<u8>, String> + Send + Sync + 'static) -> Language {
        self.render = Some(Box::new(render));
        self
    }
}

/// A document the load check holds a language to, and the features it needs
/// on to mean what it says.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Sample {
    pub text: Vec<u8>,
    pub features: Vec<String>,
}

impl Sample {
    pub fn plain(text: &[u8]) -> Sample {
        Sample { text: text.to_vec(), features: Vec::new() }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Feature {
    pub name: String,
    /// Whether the language's own row has it on.
    pub default: bool,
    /// Features that come on with this one.
    pub requires: Vec<String>,
    /// The patch over the language's `syntax` while it is on, as JSON text.
    pub syntax: Option<Vec<u8>>,
}

/// A named list of features, registered as a row of its own.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Set {
    pub name: String,
    pub extensions: Vec<String>,
    pub aliases: Vec<String>,
    pub features: Vec<String>,
}

/// What a language says about itself — the `describe` document.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Description {
    pub name: String,
    /// Lowercase and dot-less.
    pub extensions: Vec<String>,
    pub aliases: Vec<String>,
    /// Whether the language prints — the write tier.
    pub write: bool,
    /// Whether the language authors — `syntax` is its table.
    pub author: bool,
    /// The table an editor writes with, as JSON text.
    pub syntax: Option<Vec<u8>>,
    pub features: Vec<Feature>,
    pub sets: Vec<Set>,
    /// Small documents the load check holds the language to.
    pub samples: Vec<Sample>,
}

/// A description, sample or table the registry refuses; the reason is in the
/// `diag` the call was handed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidLanguage;

fn refuse(diag: &mut String, msg: impl AsRef<str>) -> InvalidLanguage {
    diag.push_str(msg.as_ref());
    InvalidLanguage
}

fn lossy(s: &[u8]) -> String {
    String::from_utf8_lossy(s).into_owned()
}

type Obj = [(Vec<u8>, Value)];

fn obj_get<'v>(obj: &'v Obj, key: &str) -> Option<&'v Value> {
    obj.iter().rev().find(|(k, _)| k == key.as_bytes()).map(|(_, v)| v)
}

impl Description {
    /// Read a `describe` document. Unknown keys are ignored; `dialects` is
    /// refused by name, since a language declaring them expects rows this
    /// carrier spells as `sets`.
    pub fn parse(text: &[u8], diag: &mut String) -> Result<Description, InvalidLanguage> {
        let value = json::parse(text).map_err(|_| refuse(diag, "the description is not a JSON document"))?;
        Description::from_value(&value, diag)
    }

    /// `parse` over an already-parsed value.
    pub fn from_value(value: &Value, diag: &mut String) -> Result<Description, InvalidLanguage> {
        let Some(obj) = value.as_object() else { return Err(refuse(diag, "the description is a JSON object")) };
        if obj_get(obj, "dialects").is_some() {
            return Err(refuse(
                diag,
                "\"dialects\" is not a runtime language's: a named configuration is a set (\"sets\") of the language's \"features\"",
            ));
        }
        let mut write = false;
        let mut author = false;
        if let Some(caps_value) = obj_get(obj, "caps") {
            let Some(caps) = caps_value.as_object() else { return Err(refuse(diag, "\"caps\" is an object of booleans")) };
            if obj_get(caps, "read").is_some() && !flag(caps, "read", "caps.read", diag)? {
                return Err(refuse(diag, "caps.read is every language's"));
            }
            write = flag(caps, "write", "caps.write", diag)?;
            author = flag(caps, "author", "caps.author", diag)?;
        }

        let mut features = Vec::new();
        for (i, v) in array(obj, "features", "\"features\"", diag)?.iter().enumerate() {
            let label = format!("features[{i}]");
            let fo = object(v, &label, diag)?;
            features.push(Feature {
                name: string(fo, "name", &label, diag)?,
                default: flag(fo, "default", &label, diag)?,
                requires: strings(fo, "requires", &label, diag)?,
                syntax: syntax_text(fo, &label, diag)?,
            });
        }

        let mut sets = Vec::new();
        for (i, v) in array(obj, "sets", "\"sets\"", diag)?.iter().enumerate() {
            let label = format!("sets[{i}]");
            let so = object(v, &label, diag)?;
            sets.push(Set {
                name: string(so, "name", &label, diag)?,
                extensions: strings(so, "extensions", &label, diag)?,
                aliases: strings(so, "aliases", &label, diag)?,
                features: strings(so, "features", &label, diag)?,
            });
        }

        let mut samples = Vec::new();
        for (i, v) in array(obj, "samples", "\"samples\"", diag)?.iter().enumerate() {
            samples.push(match v {
                Value::String(t) => Sample { text: t.clone(), features: Vec::new() },
                Value::Object(so) => {
                    let label = format!("samples[{i}]");
                    Sample {
                        text: match obj_get(so, "text") {
                            Some(Value::String(s)) => s.clone(),
                            _ => return Err(refuse(diag, format!("{label}: \"text\" is a string"))),
                        },
                        features: strings(so, "features", &label, diag)?,
                    }
                }
                _ => {
                    return Err(refuse(
                        diag,
                        format!("samples[{i}] is a string, or an object with \"text\" and \"features\""),
                    ));
                }
            });
        }

        Ok(Description {
            name: string(obj, "name", "the description", diag)?,
            extensions: strings(obj, "extensions", "the description", diag)?,
            aliases: strings(obj, "aliases", "the description", diag)?,
            write,
            author,
            syntax: syntax_text(obj, "the description", diag)?,
            features,
            sets,
            samples,
        })
    }
}

fn flag(obj: &Obj, key: &str, label: &str, diag: &mut String) -> Result<bool, InvalidLanguage> {
    match obj_get(obj, key) {
        None => Ok(false),
        Some(Value::Bool(b)) => Ok(*b),
        Some(_) => Err(refuse(diag, format!("{label}: \"{key}\" is a boolean"))),
    }
}

fn string(obj: &Obj, key: &str, label: &str, diag: &mut String) -> Result<String, InvalidLanguage> {
    match obj_get(obj, key) {
        Some(Value::String(s)) => Ok(lossy(s)),
        _ => Err(refuse(diag, format!("{label}: \"{key}\" is a string"))),
    }
}

fn object<'v>(v: &'v Value, label: &str, diag: &mut String) -> Result<&'v Obj, InvalidLanguage> {
    v.as_object().ok_or_else(|| refuse(diag, format!("{label} is an object")))
}

fn array<'v>(obj: &'v Obj, key: &str, label: &str, diag: &mut String) -> Result<&'v [Value], InvalidLanguage> {
    match obj_get(obj, key) {
        None => Ok(&[]),
        Some(Value::Array(a)) => Ok(a),
        Some(_) => Err(refuse(diag, format!("{label} is an array"))),
    }
}

fn strings(obj: &Obj, key: &str, label: &str, diag: &mut String) -> Result<Vec<String>, InvalidLanguage> {
    let items = match obj_get(obj, key) {
        None => return Ok(Vec::new()),
        Some(Value::Array(a)) => a,
        Some(_) => return Err(refuse(diag, format!("{label}: \"{key}\" is an array of strings"))),
    };
    let mut out = Vec::new();
    for item in items {
        match item {
            Value::String(s) => out.push(lossy(s)),
            _ => return Err(refuse(diag, format!("{label}: \"{key}\" is an array of strings"))),
        }
    }
    Ok(out)
}

/// A `syntax` member, as compact JSON text: what is kept, and read again
/// when a table is built.
fn syntax_text(obj: &Obj, label: &str, diag: &mut String) -> Result<Option<Vec<u8>>, InvalidLanguage> {
    match obj_get(obj, "syntax") {
        None | Some(Value::Null) => Ok(None),
        Some(v @ Value::Object(_)) => Ok(Some(v.to_compact())),
        Some(_) => Err(refuse(diag, format!("{label}: \"syntax\" is an object"))),
    }
}

// ── the registry ────────────────────────────────────────────────────────────

/// One registration: the language, what it declared, and what was worked out
/// from that once. Shared by its rows.
pub struct Lang {
    language: Language,
    description: Description,
    /// Each feature's bit with every bit it requires, transitively.
    closure: [u32; MAX_FEATURES],
    /// Every declared feature's bit.
    declared: u32,
    /// The base table and each feature's patch, as parsed JSON. `None` for a
    /// language that does not author, and for a feature with no patch.
    base_syntax: Option<Vec<(Vec<u8>, Value)>>,
    patches: Vec<Option<Vec<(Vec<u8>, Value)>>>,
    #[allow(dead_code)]
    renderers: Renderers,
}

impl Lang {
    fn new(language: Language, description: Description) -> Lang {
        Lang {
            language,
            description,
            closure: [0; MAX_FEATURES],
            declared: 0,
            base_syntax: None,
            patches: Vec::new(),
            renderers: Renderers::default(),
        }
    }

    /// `mask`, with what each of its features requires.
    fn close(&self, mask: u32) -> u32 {
        let mut out = 0;
        let mut rest = mask & self.declared;
        while rest != 0 {
            let i = rest.trailing_zeros() as usize;
            out |= self.closure[i];
            rest &= rest - 1;
        }
        out
    }

    /// The features in `mask`, by name.
    fn names(&self, mask: u32) -> Vec<&str> {
        self.description
            .features
            .iter()
            .enumerate()
            .filter(|(i, _)| mask & (1u32 << i) != 0)
            .map(|(_, f)| f.name.as_str())
            .collect()
    }

    fn parse_text(&self, row: &str, mask: u32, source: &[u8]) -> Result<Vec<u8>, String> {
        let names = self.names(mask);
        let call = Call { row, features: mask, feature_names: &names };
        (self.language.parse)(&call, source).map_err(|why| {
            fail(format!("{row}: parse failed: {why}"));
            last_failure()
        })
    }

    fn print_table(&self, row: &str, mask: u32, text: &[u8]) -> Result<Vec<u8>, PrintFailure> {
        let Some(print) = &self.language.print else { return Err(PrintFailure::UnsupportedFormat) };
        let names = self.names(mask);
        let call = Call { row, features: mask, feature_names: &names };
        print(&call, text).map_err(|why| {
            fail(format!("{row}: print failed: {why}"));
            PrintFailure::Language(last_failure())
        })
    }

    fn render(&self, row: &str, mask: u32, request: &Render) -> Result<Vec<u8>, PrintFailure> {
        let Some(f) = &self.language.render else { return Err(PrintFailure::UnsupportedFormat) };
        let names = self.names(mask);
        let call = Call { row, features: mask, feature_names: &names };
        f(&call, request).map_err(|why| {
            fail(format!("{row}: {} failed: {why}", request.tag_name()));
            PrintFailure::Language(last_failure())
        })
    }
}

/// What a combination's renderers find their language by: the syntax's
/// `renderer_context`.
struct ComboCtx {
    lang: Arc<Lang>,
    row: String,
    mask: u32,
}

/// One table a row's language authors with, for one combination of features,
/// built on first use and kept for the life of the process.
pub struct Combination {
    pub syntax: Syntax,
    pub mask: u32,
    /// Why the table spells nothing, when its rules refused it.
    pub failure: Option<String>,
}

/// One registered row.
pub struct Slot {
    lang: Arc<Lang>,
    code: u16,
    /// The language's name, or a set's.
    name: String,
    extensions: Vec<String>,
    aliases: Vec<String>,
    /// The features the row has on before a caller lays any over it.
    mask: u32,
    dialect_of: Option<u16>,
    /// The samples whose features the row has on.
    samples: Vec<Vec<u8>>,
    /// The table under the row's own features.
    syntax: OnceLock<&'static Syntax>,
    /// What a conversion into this row keeps, measured at load.
    measured: OnceLock<Arc<Measured>>,
    /// Features the load check lays over every call through this row while
    /// it checks a combination — only before the row is published.
    load_features: AtomicU32,
    /// The tables built so far.
    combos: Mutex<Vec<&'static Combination>>,
}

impl Slot {
    /// The features a call through this row has on, given a caller's.
    fn effective(&self, extra: u32) -> u32 {
        self.mask | self.lang.close(extra) | self.load_features.load(Ordering::Acquire)
    }

    fn format(&self) -> Format {
        Format::Runtime(self.code)
    }

    fn parse_document(&self, mask: u32, source: &[u8]) -> Result<Document, String> {
        let text = self.lang.parse_text(&self.name, mask, source)?;
        node_table::decode(source, &text).map_err(|problem| {
            fail(format!("{}: the table is refused: {}", self.name, problem.render()));
            last_failure()
        })
    }

    fn serialize_canonical(&self, doc: &ParsedDoc) -> Result<Vec<u8>, PrintFailure> {
        if !self.lang.description.write {
            return Err(PrintFailure::UnsupportedFormat);
        }
        let text = node_table::encode(&doc.doc, node_table::Options { pretty: false, positions: false });
        self.lang.print_table(&self.name, self.effective(doc.config.features), &text)
    }

    fn serialize_from_ast(&self, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
        if !self.lang.description.write {
            return Err(PrintFailure::UnsupportedFormat);
        }
        let text = node_table::encode_ast(ast, node_table::Options { pretty: false, positions: true });
        self.lang.print_table(&self.name, self.effective(0), &text)
    }

    /// The table this row authors with under `mask` — built, validated and
    /// kept the first time it is asked for. `syntax::none()` for a language
    /// that does not author; a table that spells nothing, with its failure
    /// recorded, for one whose combination breaks a rule.
    fn syntax_for(&self, mask: u32) -> &'static Syntax {
        let Some(c) = self.combination(mask) else { return syntax::none() };
        if let Some(why) = &c.failure {
            fail(format!("{}: {}", self.name, why));
        }
        &c.syntax
    }

    fn combination(&self, mask: u32) -> Option<&'static Combination> {
        self.lang.base_syntax.as_ref()?;
        let mut combos = self.combos.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(c) = combos.iter().find(|c| c.mask == mask) {
            return Some(c);
        }
        let c: &'static Combination = Box::leak(Box::new(build_table(&self.lang, &self.name, mask)));
        combos.push(c);
        Some(c)
    }

    /// The row as the contract checks it.
    fn contract_entry(self: &Arc<Slot>, syntax: &'static Syntax, samples: Vec<Vec<u8>>, syntax_for: bool) -> contract::Entry<'static> {
        let fmt = self.format();
        let write = self.lang.description.write;
        let (a, b, c, d, e) = (self.clone(), self.clone(), self.clone(), self.clone(), self.clone());
        contract::Entry {
            id: fmt,
            samples,
            syntax,
            parse: Box::new(move |cfg, src| {
                a.parse_document(a.effective(cfg.features), src).map(|doc| ParsedDoc { format: fmt, config: *cfg, doc })
            }),
            parse_to_ast: Box::new(move |cfg, src| b.parse_document(b.effective(cfg.features), src)),
            serialize_canonical: if write {
                Some(Box::new(move |doc| c.serialize_canonical(doc).map_err(|f| f.name())))
            } else {
                None
            },
            serialize_from_ast: if write {
                Some(Box::new(move |ast| d.serialize_from_ast(ast).map_err(|f| f.name())))
            } else {
                None
            },
            syntax_for: if syntax_for {
                Some(Box::new(move |cfg| e.syntax_for(e.effective(cfg.features))))
            } else {
                None
            },
        }
    }
}

struct Registry {
    slots: Vec<Arc<Slot>>,
    /// How many of `slots` are published; the rest are being loaded.
    published: usize,
}

static REGISTRY: RwLock<Registry> = RwLock::new(Registry { slots: Vec::new(), published: 0 });
static REGISTER_LOCK: Mutex<()> = Mutex::new(());

fn registry() -> std::sync::RwLockReadGuard<'static, Registry> {
    REGISTRY.read().unwrap_or_else(|e| e.into_inner())
}

fn registry_mut() -> std::sync::RwLockWriteGuard<'static, Registry> {
    REGISTRY.write().unwrap_or_else(|e| e.into_inner())
}

/// The published slot holding `code`.
fn slot_of(code: u16) -> Option<Arc<Slot>> {
    if code < BASE {
        return None;
    }
    let r = registry();
    let i = (code - BASE) as usize;
    if i < r.published { Some(r.slots[i].clone()) } else { None }
}

/// `slot_of`, or a row being loaded: its code reaches no caller before it is
/// published, but the load check reaches it — through `Format::name` for its
/// messages, and through the format layer where a check prints into it.
fn slot_or_loading(code: u16) -> Option<Arc<Slot>> {
    if code < BASE {
        return None;
    }
    registry().slots.get((code - BASE) as usize).cloned()
}

fn published() -> Vec<Arc<Slot>> {
    let r = registry();
    r.slots[..r.published].to_vec()
}

/// Whether `fmt` names a registered row — false for a compiled row, and for
/// a code in the runtime range that no registration has been given.
pub fn is_registered(fmt: Format) -> bool {
    matches!(fmt, Format::Runtime(c) if slot_of(c).is_some())
}

/// The `Format` a wire code names, if a row holds it.
pub fn format_from_code(code: i64) -> Option<Format> {
    let c = u16::try_from(code).ok()?;
    slot_of(c).map(|_| Format::Runtime(c))
}

/// The name a runtime code was registered under, or `"unregistered"` for a
/// code in the range no row holds.
pub fn name_of(code: u16) -> String {
    slot_or_loading(code).map(|s| s.name.clone()).unwrap_or_else(|| "unregistered".to_string())
}

pub fn dialect_of(code: u16) -> Option<Format> {
    slot_or_loading(code)?.dialect_of.map(Format::Runtime)
}

/// A runtime row's target has the row's own code.
pub fn target_code_of(code: u16) -> u16 {
    code
}

pub fn reads_back_as(code: u16) -> Option<Format> {
    slot_or_loading(code).map(|_| Format::Runtime(code))
}

/// The features `fmt`'s language declares, in bit order; empty for a
/// compiled row.
pub fn features_of(fmt: Format) -> Vec<format::Feature> {
    declared_features(fmt)
        .into_iter()
        .map(|f| format::Feature { name: f.name, requires: f.requires })
        .collect()
}

/// `features_of` with everything the description said about each.
pub fn declared_features(fmt: Format) -> Vec<Feature> {
    match fmt {
        Format::Runtime(c) => slot_of(c).map(|s| s.lang.description.features.clone()).unwrap_or_default(),
        _ => Vec::new(),
    }
}

/// The bit `ParseConfig::features` turns `name` on with for `fmt`'s
/// language, or `None` when `fmt` is not a registered row or its language
/// declares no such feature.
pub fn feature_bit(fmt: Format, name: &str) -> Option<u32> {
    let Format::Runtime(c) = fmt else { return None };
    let s = slot_of(c)?;
    s.lang.description.features.iter().position(|f| f.name == name).map(|i| 1u32 << i)
}

pub fn by_name(name: &str) -> Option<Format> {
    published()
        .iter()
        .find(|s| s.name == name || s.aliases.iter().any(|a| a == name))
        .map(|s| s.format())
}

pub fn by_extension(ext: &str) -> Option<Format> {
    published()
        .iter()
        .find(|s| s.extensions.iter().any(|k| k.eq_ignore_ascii_case(ext)))
        .map(|s| s.format())
}

/// Whether a runtime target prints.
pub fn prints(code: u16) -> bool {
    slot_or_loading(code).is_some_and(|s| s.lang.description.write)
}

/// What a conversion into `t` keeps, as the load-time probe measured it.
pub fn measured(target: Target) -> Option<Arc<Measured>> {
    let Target::Runtime(c) = target else { return None };
    slot_of(c)?.measured.get().cloned()
}

/// One registered row, as `lang list` and `lang check` show it.
#[derive(Clone, Debug)]
pub struct RowInfo {
    pub format: Format,
    pub name: String,
    pub extensions: Vec<String>,
    pub aliases: Vec<String>,
    pub dialect_of: Option<Format>,
    /// The features the row has on before a caller lays any over it.
    pub mask: u32,
    /// The samples the row is held to.
    pub samples: Vec<Vec<u8>>,
    pub write: bool,
}

/// Every registered row, in registration order.
pub fn entries() -> Vec<RowInfo> {
    published()
        .iter()
        .map(|s| RowInfo {
            format: s.format(),
            name: s.name.clone(),
            extensions: s.extensions.clone(),
            aliases: s.aliases.clone(),
            dialect_of: s.dialect_of.map(Format::Runtime),
            mask: s.mask,
            samples: s.samples.clone(),
            write: s.lang.description.write,
        })
        .collect()
}

/// The row `code` names, published or being loaded.
pub fn row(code: u16) -> Option<RowInfo> {
    let s = slot_or_loading(code)?;
    Some(RowInfo {
        format: s.format(),
        name: s.name.clone(),
        extensions: s.extensions.clone(),
        aliases: s.aliases.clone(),
        dialect_of: s.dialect_of.map(Format::Runtime),
        mask: s.mask,
        samples: s.samples.clone(),
        write: s.lang.description.write,
    })
}

// ── the row functions ───────────────────────────────────────────────────────

fn no_such_row(code: u16) -> String {
    format!("{} is not a registered language", code)
}

/// Parse through the row `code`, with the caller's features laid over the
/// row's own. The error is why, as [`last_failure`] also says.
pub fn parse(code: u16, cfg: &ParseConfig, source: &[u8]) -> Result<Document, String> {
    let s = slot_or_loading(code).ok_or_else(|| no_such_row(code))?;
    s.parse_document(s.effective(cfg.features), source)
}

/// The shared printer, with the labels the table carried or core indexed
/// from it.
pub fn render_html(code: u16, doc: &ParsedDoc) -> Result<Vec<u8>, PrintFailure> {
    if slot_or_loading(code).is_none() {
        return Err(PrintFailure::UnsupportedFormat);
    }
    crate::languages::html::serialize_alloc(&doc.doc.ast, Some(&doc.doc.labels)).map_err(|_| PrintFailure::UnsafeMetadata)
}

/// The parse's own table without its positions, with the spelling and
/// labels the parse recorded, printed with the features the document was
/// parsed with.
pub fn serialize_canonical(code: u16, doc: &ParsedDoc) -> Result<Vec<u8>, PrintFailure> {
    slot_or_loading(code).ok_or(PrintFailure::UnsupportedFormat)?.serialize_canonical(doc)
}

pub fn serialize_from_ast(code: u16, ast: &Ast) -> Result<Vec<u8>, PrintFailure> {
    slot_or_loading(code).ok_or(PrintFailure::UnsupportedFormat)?.serialize_from_ast(ast)
}

/// A runtime target has no Document-aware printer.
pub fn serialize_from_document(_code: u16, _doc: &Document) -> Result<Vec<u8>, PrintFailure> {
    Err(PrintFailure::UnsupportedFormat)
}

/// The table a row authors with under `cfg`'s features.
pub fn syntax_for(code: u16, cfg: &ParseConfig) -> &'static Syntax {
    let Some(s) = slot_or_loading(code) else { return syntax::none() };
    if s.lang.description.author {
        s.syntax_for(s.effective(cfg.features))
    } else {
        s.syntax.get().copied().unwrap_or(syntax::none())
    }
}

/// The samples a row is held to.
pub fn samples_of(code: u16) -> Vec<Vec<u8>> {
    slot_or_loading(code).map(|s| s.samples.clone()).unwrap_or_default()
}

/// The contract's view of a registered row.
pub fn contract_entry(code: u16) -> Option<contract::Entry<'static>> {
    let s = slot_or_loading(code)?;
    let syntax = s.syntax.get().copied().unwrap_or(syntax::none());
    let author = s.lang.description.author;
    Some(s.contract_entry(syntax, s.samples.clone(), author))
}

// ── why the last call failed ────────────────────────────────────────────────

const FAILURE_CAP: usize = 1024;

thread_local! {
    static FAILURE: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

/// Why the most recent failed call into a runtime language on this thread
/// failed: the language's own message, or the table rule its output broke.
/// Truncated, as Zig's buffer is, at 1024 bytes.
pub fn last_failure() -> String {
    FAILURE.with(|f| lossy(&f.borrow()))
}

fn fail(message: String) {
    let mut bytes = message.into_bytes();
    bytes.truncate(FAILURE_CAP);
    FAILURE.with(|f| *f.borrow_mut() = bytes);
}

// ── the renderers ───────────────────────────────────────────────────────────
//
// One set for every runtime table: each finds its language, row and features
// through the table it was found in.

fn ctx_of(s: &Syntax) -> Result<&'static ComboCtx, crate::Error> {
    s.renderer_context.and_then(|c| c.downcast_ref::<ComboCtx>()).ok_or(crate::Error::Internal)
}

fn language_error(_: PrintFailure) -> crate::Error {
    crate::Error::ParseError
}

fn render_text(s: &Syntax, text: &[u8], position: TextPosition, out: &mut Vec<u8>) -> Result<(), crate::Error> {
    let c = ctx_of(s)?;
    let spelled = c.lang.render(&c.row, c.mask, &Render::RenderText { text, position }).map_err(language_error)?;
    out.extend_from_slice(&spelled);
    Ok(())
}

/// The fragment `root` of `ast` as a node table without positions.
fn fragment_table(ast: &Ast, root: NodeId) -> Vec<u8> {
    node_table::encode_ast(&syntax::fragment(ast, root), node_table::Options { pretty: false, positions: true })
}

fn render_block(s: &Syntax, ast: &Ast, root: NodeId, out: &mut Vec<u8>) -> Result<(), crate::Error> {
    let c = ctx_of(s)?;
    let table = fragment_table(ast, root);
    let spelled = c.lang.render(&c.row, c.mask, &Render::RenderBlock(&table)).map_err(language_error)?;
    out.extend_from_slice(&spelled);
    Ok(())
}

/// `render_block` for a language that names it and answers it with `print`.
fn render_block_by_print(s: &Syntax, ast: &Ast, root: NodeId, out: &mut Vec<u8>) -> Result<(), crate::Error> {
    let c = ctx_of(s)?;
    let table = fragment_table(ast, root);
    let spelled = c.lang.print_table(&c.row, c.mask, &table).map_err(language_error)?;
    out.extend_from_slice(&spelled);
    Ok(())
}

/// A language that fails to answer has not spelled an autolink; `last_failure`
/// keeps why.
fn spells_autolink(s: &Syntax, angled: &[u8]) -> bool {
    let Ok(c) = ctx_of(s) else { return false };
    match c.lang.render(&c.row, c.mask, &Render::SpellsAutolink(angled)) {
        Ok(answer) => answer.trim_ascii() == b"true",
        Err(_) => false,
    }
}

// ── building a table ────────────────────────────────────────────────────────

/// The `Syntax` members a patch replaces per key rather than whole.
const KEYED_MEMBERS: [&str; 3] = ["inline_delims", "text_leaf_delims", "container_spelling"];

fn is_keyed(member: &[u8]) -> bool {
    KEYED_MEMBERS.iter().any(|k| k.as_bytes() == member)
}

/// An ordered map's `put`: replace in place, or append.
fn put(map: &mut Vec<(Vec<u8>, Value)>, key: &[u8], value: Value) {
    match map.iter_mut().find(|(k, _)| k == key) {
        Some(slot) => slot.1 = value,
        None => map.push((key.to_vec(), value)),
    }
}

fn map_get<'a>(map: &'a [(Vec<u8>, Value)], key: &[u8]) -> Option<&'a Value> {
    map.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// The base table with every patch `mask` turns on laid over it, decoded,
/// bound to the language's renderers, and validated; `failure` says why when
/// the rules refuse it.
fn build_table(lang: &Arc<Lang>, row: &str, mask: u32) -> Combination {
    let mut merged = lang.base_syntax.clone().unwrap_or_default();
    for (i, patch) in lang.patches.iter().enumerate() {
        if mask & (1u32 << i) == 0 {
            continue;
        }
        let Some(patch) = patch else { continue };
        for (key, value) in patch {
            let into = map_get(&merged, key);
            match (is_keyed(key), into, value) {
                (true, Some(Value::Object(table)), Value::Object(add)) => {
                    let mut table = table.clone();
                    for (k, v) in add {
                        put(&mut table, k, v.clone());
                    }
                    put(&mut merged, key, Value::Object(table));
                }
                _ => put(&mut merged, key, value.clone()),
            }
        }
    }
    let decoded = match syntax_json::from_value(&Value::Object(merged)) {
        Ok(d) => d,
        // Each part decoded alone at load, so a merge that does not is a
        // table whose parts disagree on a member's shape.
        Err(problem) => {
            return Combination {
                syntax: Syntax::NONE,
                mask,
                failure: Some(format!(
                    "the table for these features is refused: {}: {}",
                    problem.path, problem.what
                )),
            };
        }
    };
    let ctx: &'static ComboCtx = Box::leak(Box::new(ComboCtx { lang: lang.clone(), row: row.to_string(), mask }));
    let mut s = decoded.syntax;
    s.renderer_context = Some(ctx);
    if decoded.renderers.render_text {
        s.render_text = Some(TextRenderer::Custom(render_text));
    }
    if decoded.renderers.render_block {
        s.render_block = Some(if lang.language.render.is_some() { render_block } else { render_block_by_print });
    }
    if decoded.renderers.spells_autolink {
        s.spells_autolink = Some(spells_autolink);
    }
    if let Err(why) = s.validate() {
        return Combination {
            syntax: Syntax::NONE,
            mask,
            failure: Some(format!(
                "the table for these features breaks a rule at {}: {}",
                why.field,
                why.rule.describe()
            )),
        };
    }
    Combination { syntax: s, mask, failure: None }
}

// ── registration ────────────────────────────────────────────────────────────

/// Why `register` refused; the reason is in its `diag`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegisterError {
    InvalidLanguage,
    RegistryFull,
}

impl From<InvalidLanguage> for RegisterError {
    fn from(_: InvalidLanguage) -> RegisterError {
        RegisterError::InvalidLanguage
    }
}

impl RegisterError {
    pub fn name(self) -> &'static str {
        match self {
            RegisterError::InvalidLanguage => "InvalidLanguage",
            RegisterError::RegistryFull => "RegistryFull",
        }
    }
}

/// Names a runtime language may not take: the CLI's `-o` words.
const RESERVED_NAMES: [&str; 3] = ["ast", "table", "canonical"];

/// Register `language` under `description` — a row for the language, and
/// one per set — run the load check over it, and return the `Format` of the
/// language's own row; a set's is found by its name. On refusal nothing is
/// registered, and `diag` says why.
pub fn register(language: Language, description: Description, diag: &mut String) -> Result<Format, RegisterError> {
    let _guard = REGISTER_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let first = registry().slots.len();
    let result = register_locked(first, language, description, diag);
    let mut r = registry_mut();
    match result {
        Ok(fmt) => {
            r.published = r.slots.len();
            Ok(fmt)
        }
        Err(e) => {
            r.slots.truncate(first);
            Err(e)
        }
    }
}

fn register_locked(first: usize, language: Language, description: Description, diag: &mut String) -> Result<Format, RegisterError> {
    check_description(&description, &language, diag)?;
    let row_count = 1 + description.sets.len();
    if first + row_count > CAPACITY {
        diag.push_str(&format!("the registry holds {CAPACITY} rows and is full"));
        return Err(RegisterError::RegistryFull);
    }
    let mut lang = Lang::new(language, description);
    prepare(&mut lang, diag)?;
    let lang = Arc::new(lang);
    let d = &lang.description;

    let mut default_mask = 0u32;
    for (i, f) in d.features.iter().enumerate() {
        if f.default {
            default_mask |= lang.closure[i];
        }
    }
    let own_code = BASE + first as u16;
    for r in 0..row_count {
        let code = BASE + (first + r) as u16;
        let set = if r == 0 { None } else { Some(&d.sets[r - 1]) };
        let mask = match set {
            Some(s) => lang.close(mask_of(d, &s.features)),
            None => default_mask,
        };
        let slot = Arc::new(Slot {
            lang: lang.clone(),
            code,
            name: set.map_or(&d.name, |s| &s.name).clone(),
            extensions: set.map_or(&d.extensions, |s| &s.extensions).clone(),
            aliases: set.map_or(&d.aliases, |s| &s.aliases).clone(),
            mask,
            dialect_of: if r == 0 { None } else { Some(own_code) },
            samples: samples_under(d, &lang, mask),
            syntax: OnceLock::new(),
            measured: OnceLock::new(),
            load_features: AtomicU32::new(0),
            combos: Mutex::new(Vec::new()),
        });
        // The row, filled and not yet published: the checks below reach it
        // by its code, while no other reader is handed that code.
        registry_mut().slots.push(slot.clone());
        let _ = slot.syntax.set(slot.syntax_for(mask));
        if d.author {
            if let Some(why) = slot.combination(mask).and_then(|c| c.failure.as_ref()) {
                return Err(refuse(diag, format!("{}: {}", slot.name, why)).into());
            }
        }
    }

    let slots: Vec<Arc<Slot>> = registry().slots[first..first + row_count].to_vec();
    check_rows(&lang, &slots, diag)?;
    // A print that fails on a probe is measured as dropping it, not as a
    // reason to refuse the language: it declared the write tier, not the
    // whole vocabulary.
    if d.write {
        for s in &slots {
            let ser = |ast: &Ast| s.serialize_from_ast(ast).map_err(|_| ());
            let par = |src: &[u8]| s.parse_document(s.effective(0), src).map_err(|_| ());
            let _ = s.measured.set(Arc::new(diagnostics::measure(&ser, &par)));
        }
    }
    Ok(Format::Runtime(own_code))
}

fn is_identifier(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() || b.len() > 64 || !b[0].is_ascii_lowercase() {
        return false;
    }
    b.iter().all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-' || c == b'_')
}

/// Whether a compiled row or a registered one already answers to `name`.
fn name_taken(name: &str) -> bool {
    format::parse_format_name(name).is_some() || format::parse_target_name(name).is_some() || RESERVED_NAMES.contains(&name)
}

fn feature_index(d: &Description, name: &str) -> Option<usize> {
    d.features.iter().position(|f| f.name == name)
}

fn mask_of(d: &Description, names: &[String]) -> u32 {
    names.iter().fold(0, |m, n| m | (1u32 << feature_index(d, n).expect("a checked feature name")))
}

/// The names and extensions one row claims, held to what is already taken
/// and to what the description's other rows claim.
fn check_row_names(
    d: &Description,
    name: &str,
    aliases: &[String],
    extensions: &[String],
    seen_names: &mut Vec<String>,
    seen_exts: &mut Vec<String>,
    diag: &mut String,
) -> Result<(), InvalidLanguage> {
    if !is_identifier(name) {
        return Err(refuse(diag, format!("the name \"{name}\" is not a lowercase identifier")));
    }
    if name_taken(name) {
        return Err(refuse(diag, format!("the name \"{name}\" is already a format's")));
    }
    if seen_names.iter().any(|n| n == name) {
        return Err(refuse(diag, format!("{}: the name \"{name}\" is given twice", d.name)));
    }
    seen_names.push(name.to_string());
    for al in aliases {
        if !is_identifier(al) {
            return Err(refuse(diag, format!("{name}: the alias \"{al}\" is not a lowercase identifier")));
        }
        if name_taken(al) || seen_names.iter().any(|n| n == al) {
            return Err(refuse(diag, format!("{name}: the alias \"{al}\" is already a format's")));
        }
        seen_names.push(al.clone());
    }
    for e in extensions {
        if e.is_empty() || e.contains('.') {
            return Err(refuse(diag, format!("{name}: the extension \"{e}\" is written without its dot")));
        }
        if e.bytes().any(|c| c.is_ascii_uppercase()) {
            return Err(refuse(diag, format!("{name}: the extension \"{e}\" is written in lowercase")));
        }
        // Zig probes `x.<ext>` in an 80-byte buffer.
        if e.len() + 2 > 80 {
            return Err(refuse(diag, format!("{name}: the extension \"{e}\" is too long")));
        }
        if let Some(owner) = format::detect_from_extension(&format!("x.{e}")) {
            return Err(refuse(diag, format!("{name}: the extension \"{e}\" is {}'s", owner.name())));
        }
        if seen_exts.iter().any(|x| x == e) {
            return Err(refuse(diag, format!("{name}: the extension \"{e}\" is given twice")));
        }
        seen_exts.push(e.clone());
    }
    Ok(())
}

fn check_feature_names(d: &Description, names: &[String], label: &str, diag: &mut String) -> Result<(), InvalidLanguage> {
    for n in names {
        if feature_index(d, n).is_none() {
            return Err(refuse(diag, format!("{}: {label} names \"{n}\", which is not a declared feature", d.name)));
        }
    }
    Ok(())
}

fn check_description(d: &Description, language: &Language, diag: &mut String) -> Result<(), InvalidLanguage> {
    let mut seen_names = Vec::new();
    let mut seen_exts = Vec::new();
    check_row_names(d, &d.name, &d.aliases, &d.extensions, &mut seen_names, &mut seen_exts, diag)?;
    for s in &d.sets {
        check_row_names(d, &s.name, &s.aliases, &s.extensions, &mut seen_names, &mut seen_exts, diag)?;
    }

    if d.write && language.print.is_none() {
        return Err(refuse(diag, format!("{}: caps.write needs a print function", d.name)));
    }
    if d.author && d.syntax.is_none() {
        return Err(refuse(diag, format!("{}: caps.author needs a \"syntax\", the table its gestures write with", d.name)));
    }
    if !d.author && d.syntax.is_some() {
        return Err(refuse(diag, format!("{}: a \"syntax\" is the author tier's, and caps.author is not declared", d.name)));
    }

    if d.features.len() > MAX_FEATURES {
        return Err(refuse(diag, format!("{}: a language declares at most {MAX_FEATURES} features", d.name)));
    }
    for (i, f) in d.features.iter().enumerate() {
        if !is_identifier(&f.name) {
            return Err(refuse(diag, format!("{}: the feature \"{}\" is not a lowercase identifier", d.name, f.name)));
        }
        if feature_index(d, &f.name) != Some(i) {
            return Err(refuse(diag, format!("{}: the feature \"{}\" is declared twice", d.name, f.name)));
        }
        check_feature_names(d, &f.requires, &f.name, diag)?;
        if f.syntax.is_some() && !d.author {
            return Err(refuse(
                diag,
                format!("{}: the feature \"{}\" patches a \"syntax\", and caps.author is not declared", d.name, f.name),
            ));
        }
    }
    for s in &d.sets {
        check_feature_names(d, &s.features, &s.name, diag)?;
    }

    if d.samples.is_empty() {
        return Err(refuse(
            diag,
            format!("{}: a language declares at least one sample, which is the whole of what the load check holds it to", d.name),
        ));
    }
    let mut plain = false;
    for (i, s) in d.samples.iter().enumerate() {
        check_feature_names(d, &s.features, &format!("sample {i}"), diag)?;
        if s.features.is_empty() {
            plain = true;
        }
    }
    if !plain {
        return Err(refuse(
            diag,
            format!("{}: at least one sample needs no feature, so every row has one to be held to", d.name),
        ));
    }
    Ok(())
}

/// What `register` works out from a checked description once: each
/// feature's closure, and — for a language that authors — the base table and
/// the patches, each decoded alone so a mistake is refused at its own path,
/// and no two patches spelling the same member.
fn prepare(lang: &mut Lang, diag: &mut String) -> Result<(), InvalidLanguage> {
    let n = lang.description.features.len();
    for i in 0..n {
        lang.declared |= 1u32 << i;
        lang.closure[i] = (1u32 << i) | mask_of(&lang.description, &lang.description.features[i].requires);
    }
    // Requirements of requirements: grow every closure until none moves.
    let mut moved = true;
    while moved {
        moved = false;
        for i in 0..n {
            let mut grown = lang.closure[i];
            let mut rest = lang.closure[i];
            while rest != 0 {
                grown |= lang.closure[rest.trailing_zeros() as usize];
                rest &= rest - 1;
            }
            if grown != lang.closure[i] {
                lang.closure[i] = grown;
                moved = true;
            }
        }
    }

    let d = &lang.description;
    if !d.author {
        return Ok(());
    }
    let base_value = parse_syntax(d.syntax.as_deref().unwrap_or_default(), "syntax", diag)?;
    let decoded = syntax_json::from_value(&Value::Object(base_value.clone()))
        .map_err(|p| refuse(diag, format!("{}: syntax.{} {}", d.name, p.path, p.what)))?;
    let r = decoded.renderers;
    if (r.render_text || r.spells_autolink) && lang.language.render.is_none() {
        return Err(refuse(diag, format!("{}: the syntax names renderers, and the language has no render function", d.name)));
    }
    if r.render_block && lang.language.render.is_none() && !d.write {
        return Err(refuse(diag, format!("{}: the syntax names render_block, and the language neither renders nor prints", d.name)));
    }

    let mut patches = Vec::new();
    for f in &d.features {
        let Some(text) = &f.syntax else {
            patches.push(None);
            continue;
        };
        let label = format!("the feature \"{}\"'s syntax", f.name);
        let patch = parse_syntax(text, &label, diag)?;
        if map_get(&patch, b"renderers").is_some() {
            return Err(refuse(diag, format!("{}: {label} names renderers, which are the language's and not a feature's", d.name)));
        }
        if let Err(p) = syntax_json::from_value(&Value::Object(patch.clone())) {
            return Err(refuse(diag, format!("{}: {label}: {} {}", d.name, p.path, p.what)));
        }
        patches.push(Some(patch));
    }
    // No two patches spell the same member, or the same key of a keyed one.
    for (i, p) in patches.iter().enumerate() {
        let Some(one) = p else { continue };
        for (j, q) in patches.iter().enumerate().skip(i + 1) {
            let Some(other) = q else { continue };
            if let Some(path) = overlap(one, other) {
                return Err(refuse(
                    diag,
                    format!(
                        "{}: the features \"{}\" and \"{}\" both patch {}",
                        d.name, d.features[i].name, d.features[j].name, path
                    ),
                ));
            }
        }
    }
    lang.base_syntax = Some(base_value);
    lang.renderers = r;
    lang.patches = patches;
    Ok(())
}

fn parse_syntax(text: &[u8], label: &str, diag: &mut String) -> Result<Vec<(Vec<u8>, Value)>, InvalidLanguage> {
    match json::parse(text) {
        Err(_) => Err(refuse(diag, format!("{label} is not JSON"))),
        Ok(Value::Object(o)) => Ok(o),
        Ok(_) => Err(refuse(diag, format!("{label} is not an object"))),
    }
}

/// The first member, or key of a keyed member, that both patches spell.
fn overlap(x: &[(Vec<u8>, Value)], y: &[(Vec<u8>, Value)]) -> Option<String> {
    for (key, value) in x {
        let Some(other) = map_get(y, key) else { continue };
        if let (true, Value::Object(a), Value::Object(b)) = (is_keyed(key), value, other) {
            if a.iter().any(|(k, _)| map_get(b, k).is_some()) {
                return Some(lossy(key));
            }
            continue;
        }
        return Some(lossy(key));
    }
    None
}

/// The samples whose features `mask` has on.
fn samples_under(d: &Description, lang: &Lang, mask: u32) -> Vec<Vec<u8>> {
    d.samples
        .iter()
        .filter(|s| lang.close(mask_of(d, &s.features)) & !mask == 0)
        .map(|s| s.text.clone())
        .collect()
}

/// The engine contract over each combination of features a row can be asked
/// for that is worth asking: every row's own features, each with one feature
/// more, and every feature on. A combination two rows share is checked once,
/// through the first row that has it.
fn check_rows(lang: &Lang, slots: &[Arc<Slot>], diag: &mut String) -> Result<(), RegisterError> {
    let all = lang.declared;
    let mut seen: Vec<u32> = Vec::new();
    for slot in slots {
        let mut candidates = vec![slot.mask];
        for f in 0..lang.description.features.len() {
            let more = slot.mask | lang.closure[f];
            if more != slot.mask {
                candidates.push(more);
            }
        }
        candidates.push(slot.mask | all);
        for mask in candidates {
            if seen.contains(&mask) {
                continue;
            }
            seen.push(mask);
            check_under(slot, mask, diag)?;
        }
    }
    Ok(())
}

fn check_under(slot: &Arc<Slot>, mask: u32, diag: &mut String) -> Result<(), RegisterError> {
    let lang = &slot.lang;
    let table = slot.syntax_for(mask);
    let samples = samples_under(&lang.description, lang, mask);
    let names: Vec<String> = lang.names(mask & !slot.mask).into_iter().map(String::from).collect();
    if lang.description.author {
        if let Some(why) = slot.combination(mask).and_then(|c| c.failure.as_ref()) {
            return Err(refuse_under(diag, &slot.name, &names, why).into());
        }
    }
    slot.load_features.store(mask & !slot.mask, Ordering::Release);
    let entry = slot.contract_entry(table, samples, false);
    let mut report = contract::Report::default();
    let result = contract::all(&entry, &mut report);
    slot.load_features.store(0, Ordering::Release);
    result.map_err(|_| refuse_under(diag, &slot.name, &names, &report.message()).into())
}

/// A refusal that says which features were on, when any beyond the row's
/// own were.
fn refuse_under(diag: &mut String, row: &str, names: &[String], message: &str) -> InvalidLanguage {
    if !names.is_empty() {
        diag.push_str(&format!("{row} with {}: ", names.join(", ")));
    }
    refuse(diag, message)
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// The registry is process-global and append-only, so the tests below share
// it: each registers under a name of its own and never assumes a count.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::languages::{djot, markdown};

    fn plain_samples(texts: &[&str]) -> Vec<Sample> {
        texts.iter().map(|t| Sample::plain(t.as_bytes())).collect()
    }

    fn desc(name: &str, samples: &[&str]) -> Description {
        Description { name: name.into(), samples: plain_samples(samples), ..Default::default() }
    }

    fn djot_parse(_: &Call, source: &[u8]) -> Result<Vec<u8>, String> {
        let doc = djot::parse(source);
        Ok(node_table::encode(&doc, node_table::Options { pretty: false, positions: true }))
    }

    fn djot_print(_: &Call, text: &[u8]) -> Result<Vec<u8>, String> {
        let doc = node_table::decode_bare(text).map_err(|_| "the table did not decode".to_string())?;
        // The Document-aware print, as the compiled row's canonical path.
        Ok(djot::serialize(&doc))
    }

    fn djot_render(_: &Call, request: &Render) -> Result<Vec<u8>, String> {
        match request {
            Render::RenderText { .. } => Err("djot spells a literal by its alphabet".into()),
            Render::RenderBlock(text) => {
                let doc = node_table::decode_bare(text).map_err(|_| String::new())?;
                Ok(djot::serialize_ast(&doc.ast))
            }
            Render::SpellsAutolink(angled) => {
                let t = format::syntax_for(Format::Djot);
                Ok(if (t.spells_autolink.unwrap())(t, angled) { b"true".to_vec() } else { b"false".to_vec() })
            }
        }
    }

    fn djot_twin() -> Language {
        Language::new(djot_parse).with_print(djot_print)
    }

    fn register_ok(language: Language, d: Description) -> Format {
        let mut diag = String::new();
        match register(language, d, &mut diag) {
            Ok(f) => f,
            Err(e) => panic!("refused ({e:?}): {diag}"),
        }
    }

    #[test]
    fn a_registered_language_is_a_row_every_consumer_reaches() {
        let fmt = register_ok(
            djot_twin(),
            Description {
                name: "djot-twin".into(),
                extensions: vec!["djtwin".into()],
                aliases: vec!["djt".into()],
                write: true,
                samples: plain_samples(&["# Title\n\nSome _emphasis_ and a [link](/u).\n", "- a\n- b\n"]),
                ..Default::default()
            },
        );
        assert!(is_registered(fmt));
        assert_eq!(fmt.name(), "djot-twin");
        assert_eq!(format::parse_format_name("djot-twin"), Some(fmt));
        assert_eq!(format::parse_format_name("djt"), Some(fmt));
        assert_eq!(format::detect_from_extension("notes.DJTWIN"), Some(fmt));
        assert_eq!(format::target_for(fmt).code(), fmt.code());

        let src = b"Hello *world*.\n";
        let cfg = ParseConfig::default();
        let doc = format::parse(fmt, &cfg, src).unwrap();
        assert_eq!(doc.format, fmt);
        let real = djot::parse(src);
        assert!(real.ast.eql(&doc.doc.ast));

        assert_eq!(format::render_html(&doc).unwrap(), b"<p>Hello <strong>world</strong>.</p>\n");
        assert_eq!(format::serialize_canonical(&doc).unwrap(), src);

        // Into the runtime target from a compiled parse, and out of it.
        let md = format::parse(Format::Markdown, &cfg, b"# T\n\n*x*\n").unwrap();
        assert_eq!(format::serialize_from_ast(format::target_for(fmt), &md.doc.ast).unwrap(), b"# T\n\n_x_\n");

        // The probe measured it, and it measures what djot's table declares.
        let t = format::target_for(fmt);
        assert_eq!(
            diagnostics::fidelity(t, &crate::ast::Kind::Heading { level: 2 }),
            diagnostics::Fidelity::Faithful
        );
        let sup = crate::ast::Kind::InlineMark(crate::ast::InlineMark::Superscript);
        assert_eq!(diagnostics::fidelity(Target::Djot, &sup), diagnostics::fidelity(t, &sup));
        // A plain paragraph costs nothing.
        let plain = djot::parse(b"Just a paragraph.\n\n| a |\n|---|\n| 1 |\n\n^ cap\n\n- [x] done\n");
        let warnings = diagnostics::analyze(&plain.ast, plain.ast.root, t).unwrap();
        assert!(warnings.is_empty(), "{warnings:?}");

        // It has nothing to author with.
        assert!(!format::syntax_for(fmt).authorable());
    }

    #[test]
    fn converting_a_twins_parse_to_its_compiled_sibling_reads_as_the_siblings_own() {
        let src = "# Heading\n\nSee [Heading].\n\n+ a\n+ b\n\n1) one\n2) two\n";
        let fmt = register_ok(
            djot_twin(),
            Description {
                name: "djot-converting".into(),
                extensions: vec!["djconv".into()],
                write: true,
                samples: plain_samples(&[src]),
                ..Default::default()
            },
        );
        let cfg = ParseConfig::default();
        let twin = format::parse(fmt, &cfg, src.as_bytes()).unwrap();
        let real = format::parse(Format::Djot, &cfg, src.as_bytes()).unwrap();
        let from_real = format::serialize_canonical(&real).unwrap();
        let from_twin = format::serialize_converted(&twin, Target::Djot).unwrap();
        assert_eq!(from_real, from_twin);
        assert_eq!(src.as_bytes(), &from_twin[..]);

        // A compiled row's document still crosses as a bare tree.
        let md = format::parse(Format::Markdown, &cfg, b"+ a\n").unwrap();
        assert_eq!(format::serialize_converted(&md, Target::Djot).unwrap(), b"- a\n");
    }

    #[test]
    fn a_language_that_authors_is_given_djots_table() {
        let syntax = syntax_json::encode_alloc(format::syntax_for(Format::Djot), syntax_json::Options { pretty: false });
        let fmt = register_ok(
            djot_twin().with_render(djot_render),
            Description {
                name: "djot-author".into(),
                extensions: vec!["djauth".into()],
                write: true,
                author: true,
                syntax: Some(syntax),
                samples: plain_samples(&["# Title\n\nSome _emphasis_ and a [link](/u).\n", "- a\n- b\n\n> q\n"]),
                ..Default::default()
            },
        );
        let table = format::syntax_for(fmt);
        assert!(table.authorable());
        assert!(table.renderer_context.is_some());
        // TODO(port): the editor half of this test (gestures through the
        // row edit as djot's do) waits for crate::ast::editor.
        let mut out = Vec::new();
        let mut b = crate::ast::Builder::new();
        let s = b.add_leaf(crate::ast::Kind::Str(b"x".to_vec()));
        let h = b.add_container(crate::ast::Kind::Heading { level: 2 }, &[s]);
        let ast = b.finish(h);
        (table.render_block.unwrap())(table, &ast, h, &mut out).unwrap();
        assert_eq!(out, b"## x\n");
        assert!((table.spells_autolink.unwrap())(table, b"<https://x.dev>"));
    }

    #[test]
    fn a_language_that_names_render_block_and_has_no_render_prints_its_fragments() {
        let mut table = *format::syntax_for(Format::Djot);
        table.spells_autolink = None;
        let fmt = register_ok(
            djot_twin(),
            Description {
                name: "djot-printing".into(),
                write: true,
                author: true,
                syntax: Some(syntax_json::encode_alloc(&table, syntax_json::Options { pretty: false })),
                samples: plain_samples(&["# Title\n\nSome _emphasis_.\n"]),
                ..Default::default()
            },
        );
        let t = format::syntax_for(fmt);
        let mut b = crate::ast::Builder::new();
        let s = b.add_leaf(crate::ast::Kind::Str(b"q".to_vec()));
        let p = b.add_container(crate::ast::Kind::Para, &[s]);
        let q = b.add_container(crate::ast::Kind::BlockQuote, &[p]);
        let ast = b.finish(q);
        let mut out = Vec::new();
        (t.render_block.unwrap())(t, &ast, q, &mut out).unwrap();
        assert_eq!(out, b"> q\n");
    }

    /// Markdown, with two of its extensions as features a caller turns on.
    fn md_options(call: &Call) -> markdown::ParseOptions {
        let mut o = markdown::ParseOptions::default();
        for n in call.feature_names {
            if *n == "math" {
                o.math = true;
            }
            if *n == "highlight" {
                o.highlight = true;
            }
        }
        o
    }

    fn md_parse(call: &Call, source: &[u8]) -> Result<Vec<u8>, String> {
        let doc = markdown::parse(source, md_options(call));
        Ok(node_table::encode(&doc, node_table::Options { pretty: false, positions: true }))
    }

    fn md_print(_: &Call, text: &[u8]) -> Result<Vec<u8>, String> {
        let doc = node_table::decode_bare(text).map_err(|_| String::new())?;
        Ok(markdown::serializer::serialize(&doc))
    }

    pub(crate) fn md_render(_: &Call, request: &Render) -> Result<Vec<u8>, String> {
        match request {
            Render::RenderText { .. } => Err(String::new()),
            Render::RenderBlock(text) => {
                let doc = node_table::decode_bare(text).map_err(|_| String::new())?;
                Ok(markdown::serializer::serialize_ast(&doc.ast))
            }
            Render::SpellsAutolink(angled) => {
                Ok(if markdown::spells_autolink(angled) { b"true".to_vec() } else { b"false".to_vec() })
            }
        }
    }

    fn json_str(s: &[u8]) -> String {
        let mut out = Vec::new();
        json::write_string(&mut out, s);
        String::from_utf8(out).unwrap()
    }

    /// Markdown's default table as the base, and as each feature's patch
    /// exactly the members Markdown's own table for that option moves.
    fn markdown_features_description(name: &str) -> Description {
        let b = crate::syntax::markdown::table();
        let math = format!(
            "{{\"text_leaf_delims\":{{\"inline_math\":{{\"open\":\"$\",\"close\":\"$\"}},\"display_math\":{{\"open\":\"$$\",\"close\":\"$$\"}}}},\n \"text_escapes\":{},\"link_text_escapes\":{}}}",
            json_str(&[b.text_escapes.unwrap(), b"$"].concat()),
            json_str(&[b.link_text_escapes.unwrap(), b"$"].concat()),
        );
        Description {
            name: name.into(),
            write: true,
            author: true,
            syntax: Some(syntax_json::encode_alloc(b, syntax_json::Options { pretty: false })),
            features: vec![
                Feature { name: "math".into(), syntax: Some(math.into_bytes()), ..Default::default() },
                Feature {
                    name: "highlight".into(),
                    syntax: Some(b"{\"inline_delims\":{\"mark\":{\"open\":\"==\",\"close\":\"==\"}}}".to_vec()),
                    ..Default::default()
                },
            ],
            sets: vec![Set { name: format!("{name}-math"), features: vec!["math".into()], ..Default::default() }],
            samples: vec![
                Sample::plain(b"# Title\n\nSome *emphasis* and\n==marks==.\n"),
                Sample { text: b"A formula, $x^2$, and\n$$\ny\n$$\n".to_vec(), features: vec!["math".into()] },
                Sample { text: b"A ==highlight== here.\n".to_vec(), features: vec!["highlight".into()] },
            ],
            ..Default::default()
        }
    }

    /// `s` as JSON, without its renderers.
    fn spelling(s: &Syntax) -> Vec<u8> {
        let mut bare = *s;
        bare.render_text = if s.text_escapes.is_some() { Some(TextRenderer::Alphabet) } else { None };
        bare.render_block = None;
        bare.spells_autolink = None;
        syntax_json::encode_alloc(&bare, syntax_json::Options { pretty: false })
    }

    #[test]
    fn features_move_a_table_as_markdowns_options_move_its_own_and_a_set_is_a_row() {
        let lang = Language::new(md_parse).with_print(md_print).with_render(md_render);
        let fmt = register_ok(lang, markdown_features_description("mdf"));
        let math_bit = feature_bit(fmt, "math").unwrap();
        let highlight_bit = feature_bit(fmt, "highlight").unwrap();
        assert_eq!(math_bit, 1);
        assert_eq!(highlight_bit, 2);
        assert_eq!(feature_bit(fmt, "tables"), None);

        for (mask, math, highlight) in [(0, false, false), (1, true, false), (2, false, true), (3, true, true)] {
            let opts = markdown::ParseOptions { math, highlight, ..Default::default() };
            let cfg = ParseConfig { features: mask, ..Default::default() };
            assert_eq!(
                String::from_utf8(spelling(crate::syntax::markdown::for_options(&opts))).unwrap(),
                String::from_utf8(spelling(format::syntax_for_config(fmt, &cfg))).unwrap(),
            );
        }

        // The parse reads the features too: `$x$` is a formula only with math.
        let src = b"Cost $x$.\n";
        let plain = ParseConfig::default();
        let without = format::parse(fmt, &plain, src).unwrap();
        let with_math = ParseConfig { features: math_bit, ..Default::default() };
        let with = format::parse(fmt, &with_math, src).unwrap();
        let count = |d: &ParsedDoc| d.doc.ast.nodes.iter().filter(|n| matches!(n.kind, crate::ast::Kind::TextLeaf { .. })).count();
        assert_eq!((count(&without), count(&with)), (0, 1));

        // The set is a row of its own, a dialect of the language's.
        let set = format::parse_format_name("mdf-math").unwrap();
        assert_ne!(set, fmt);
        assert_eq!(set.dialect_of(), Some(fmt));
        assert_eq!(set.name(), "mdf-math");
        let opts = markdown::ParseOptions { math: true, ..Default::default() };
        assert_eq!(spelling(crate::syntax::markdown::for_options(&opts)), spelling(format::syntax_for(set)));
        let through_set = format::parse(set, &plain, src).unwrap();
        assert!(with.doc.ast.eql(&through_set.doc.ast));
        // TODO(port): the editor half (insert_literal escapes the dollar)
        // waits for crate::ast::editor.
    }

    fn failing_parse(_: &Call, source: &[u8]) -> Result<Vec<u8>, String> {
        if source.starts_with(b"bad") {
            return Err("this language does not read \"bad\"".into());
        }
        // A table whose paragraph claims a span past the source.
        if source.starts_with(b"wide") {
            return Ok(b"{\"nodes\":[{\"kind\":\"doc\",\"span\":[0,1]},{\"kind\":\"para\",\"parent\":0,\"span\":[0,99]}]}".to_vec());
        }
        Ok(format!("{{\"nodes\":[{{\"kind\":\"doc\",\"span\":[0,{}]}}]}}", source.len()).into_bytes())
    }

    fn expect_refusal(d: Description, language: Language, want: &str) {
        let mut diag = String::new();
        match register(language, d, &mut diag) {
            Ok(_) => panic!("registered; wanted a refusal with {want:?}"),
            Err(e) => {
                assert_eq!(e, RegisterError::InvalidLanguage);
                assert!(diag.contains(want), "wanted {want:?} in {diag:?}");
            }
        }
    }

    #[test]
    fn load_refuses_what_the_description_or_the_samples_get_wrong() {
        let lang = || Language::new(failing_parse);
        let x = || plain_samples(&["x"]);
        let d = |name: &str| Description { name: name.into(), samples: x(), ..Default::default() };
        expect_refusal(d("Org"), lang(), "lowercase identifier");
        expect_refusal(d("markdown"), lang(), "already a format's");
        expect_refusal(d("table"), lang(), "already a format's");
        expect_refusal(Description { aliases: vec!["md".into()], ..d("orgish") }, lang(), "alias \"md\"");
        expect_refusal(Description { extensions: vec!["md".into()], ..d("orgish") }, lang(), "is markdown's");
        expect_refusal(Description { extensions: vec![".org".into()], ..d("orgish") }, lang(), "without its dot");
        expect_refusal(Description { samples: vec![], ..d("orgish") }, lang(), "at least one sample");
        expect_refusal(Description { write: true, ..d("orgish") }, lang(), "needs a print");
        expect_refusal(
            Description { samples: plain_samples(&["x", "bad"]), ..d("orgish") },
            lang(),
            "orgish: sample 1 does not parse: orgish: parse failed: this language does not read \"bad\"",
        );
        expect_refusal(Description { samples: plain_samples(&["wide"]), ..d("orgish") }, lang(), "row 1: span: ends past the source");
        expect_refusal(Description { author: true, ..d("orgish") }, lang(), "caps.author needs a \"syntax\"");
        expect_refusal(Description { syntax: Some(b"{}".to_vec()), ..d("orgish") }, lang(), "caps.author is not declared");
        expect_refusal(
            Description { sets: vec![Set { name: "orgish-x".into(), features: vec!["nope".into()], ..Default::default() }], ..d("orgish") },
            lang(),
            "\"nope\", which is not a declared feature",
        );
        expect_refusal(
            Description { sets: vec![Set { name: "orgish".into(), ..Default::default() }], ..d("orgish") },
            lang(),
            "\"orgish\" is given twice",
        );
        let feat = |n: &str| Feature { name: n.into(), ..Default::default() };
        expect_refusal(Description { features: vec![feat("a"), feat("a")], ..d("orgish") }, lang(), "\"a\" is declared twice");
        expect_refusal(
            Description {
                features: vec![feat("a")],
                samples: vec![Sample { text: b"x".to_vec(), features: vec!["a".into()] }],
                ..d("orgish")
            },
            lang(),
            "at least one sample needs no feature",
        );
        expect_refusal(
            Description { author: true, syntax: Some(b"{\"heading_markr\":\"#\"}".to_vec()), ..d("orgish") },
            lang(),
            "orgish: syntax.heading_markr is not a member of this table",
        );
        expect_refusal(
            Description {
                author: true,
                syntax: Some(b"{}".to_vec()),
                features: vec![
                    Feature {
                        name: "a".into(),
                        syntax: Some(b"{\"inline_delims\":{\"strong\":{\"open\":\"*\",\"close\":\"*\"}}}".to_vec()),
                        ..Default::default()
                    },
                    Feature {
                        name: "b".into(),
                        syntax: Some(
                            b"{\"inline_delims\":{\"emph\":{\"open\":\"_\",\"close\":\"_\"},\"strong\":{\"open\":\"**\",\"close\":\"**\"}}}"
                                .to_vec(),
                        ),
                        ..Default::default()
                    },
                ],
                ..d("orgish")
            },
            lang(),
            "the features \"a\" and \"b\" both patch inline_delims",
        );
        expect_refusal(
            Description { author: true, syntax: Some(b"{\"renderers\":[\"spells_autolink\"]}".to_vec()), ..d("orgish") },
            lang(),
            "has no render function",
        );
        expect_refusal(
            Description { author: true, syntax: Some(b"{\"renderers\":[\"render_block\"]}".to_vec()), ..d("orgish") },
            lang(),
            "neither renders nor prints",
        );
        // A table that breaks a rule is refused with the rule's name.
        expect_refusal(
            Description { author: true, syntax: Some(b"{\"link_text_escapes\":\"[]\"}".to_vec()), ..d("orgish") },
            lang(),
            "breaks a rule at",
        );
        // Nothing above registered anything.
        assert_eq!(format::parse_format_name("orgish"), None);
        assert_eq!(format::parse_format_name("orgish-x"), None);

        // And a read-tier language that passes is a row with no writer.
        let fmt = register_ok(lang(), d("blank-reader"));
        let cfg = ParseConfig::default();
        let doc = format::parse(fmt, &cfg, b"x").unwrap();
        assert_eq!(format::serialize_canonical(&doc), Err(PrintFailure::UnsupportedFormat));
        assert!(!format::target_serializes_from_ast(format::target_for(fmt)));
        assert!(measured(format::target_for(fmt)).is_none());
        // A later parse that breaks the table is an error with a reason.
        let err = format::parse(fmt, &cfg, b"wide").unwrap_err();
        assert!(err.name().contains("blank-reader: the table is refused: row 1: span"), "{}", err.name());
        assert!(last_failure().contains("blank-reader: the table is refused: row 1: span"));
    }

    #[test]
    fn a_renderer_that_lies_is_refused_at_load_under_the_features_it_lies_under() {
        let liar = |call: &Call, request: &Render| -> Result<Vec<u8>, String> {
            // Honest until math is on; then a fragment prints as nothing.
            if matches!(request, Render::RenderBlock(_)) && call.features & 1 != 0 {
                return Ok(Vec::new());
            }
            md_render(call, request)
        };
        let lang = Language::new(md_parse).with_print(md_print).with_render(liar);
        expect_refusal(markdown_features_description("mdf-liar"), lang, "renderBlock");
        assert_eq!(format::parse_format_name("mdf-liar"), None);
    }

    #[test]
    fn a_liars_refusal_names_the_features_it_lies_under() {
        let liar = |call: &Call, request: &Render| -> Result<Vec<u8>, String> {
            if matches!(request, Render::RenderBlock(_)) && call.features & 2 != 0 {
                return Ok(Vec::new());
            }
            md_render(call, request)
        };
        let lang = Language::new(md_parse).with_print(md_print).with_render(liar);
        expect_refusal(markdown_features_description("mdf-liar-two"), lang, "mdf-liar-two with highlight: mdf-liar-two: renderBlock");
    }

    #[test]
    fn a_combinations_table_is_built_once_and_one_that_breaks_a_rule_spells_nothing() {
        let mut diag = String::new();
        let mut lang = Lang::new(Language::new(failing_parse), desc("by-hand", &[]));
        lang.base_syntax = Some(
            parse_syntax(b"{\"heading_marker\":\"#\",\"inline_delims\":{\"strong\":{\"open\":\"*\",\"close\":\"*\"}}}", "syntax", &mut diag)
                .unwrap(),
        );
        lang.patches = vec![
            Some(parse_syntax(b"{\"inline_delims\":{\"emph\":{\"open\":\"_\",\"close\":\"_\"}}}", "a", &mut diag).unwrap()),
            Some(parse_syntax(b"{\"link_text_escapes\":\"[]\"}", "b", &mut diag).unwrap()),
        ];
        let slot = Slot {
            lang: Arc::new(lang),
            code: 0,
            name: "by-hand".into(),
            extensions: vec![],
            aliases: vec![],
            mask: 0,
            dialect_of: None,
            samples: vec![],
            syntax: OnceLock::new(),
            measured: OnceLock::new(),
            load_features: AtomicU32::new(0),
            combos: Mutex::new(Vec::new()),
        };

        // A keyed member merges per key.
        let one = slot.combination(1).unwrap();
        assert!(one.failure.is_none());
        assert!(one.syntax.inline_delim(crate::ast::InlineMark::Strong).is_some());
        assert!(one.syntax.inline_delim(crate::ast::InlineMark::Emph).is_some());
        assert_eq!(one.syntax.heading_marker, Some(b'#'));
        assert!(std::ptr::eq(one, slot.combination(1).unwrap()));
        assert!(one.syntax.renderer_context.is_some());

        // Half a link's spelling is refused by name, and the table spells nothing.
        let two = slot.combination(3).unwrap();
        assert!(two.failure.as_ref().unwrap().contains("breaks a rule at link_text_escapes"));
        assert!(!two.syntax.authorable());
        assert!(!slot.syntax_for(3).authorable());
        assert!(last_failure().contains("by-hand: the table for these features breaks a rule"));
    }

    #[test]
    fn a_description_reads_from_its_describe_document() {
        let mut diag = String::new();
        let d = Description::parse(
            br#"{"name":"org","extensions":["org"],"caps":{"read":true,"write":true,"author":true},
 "syntax":{"heading_marker":"*"},
 "features":[{"name":"math","requires":["tex"],"syntax":{"text_escapes":"$"}},{"name":"tex","default":true}],
 "sets":[{"name":"org-plain","extensions":["orgp"],"features":[]}],
 "samples":["* x\n",{"text":"$x$\n","features":["math"]}],"future":1}"#,
            &mut diag,
        )
        .unwrap();
        assert_eq!(d.name, "org");
        assert_eq!(d.extensions[0], "org");
        assert!(d.write && d.author);
        assert_eq!(d.syntax.as_deref(), Some(&b"{\"heading_marker\":\"*\"}"[..]));
        assert!(d.aliases.is_empty());
        assert_eq!(d.features[0].requires[0], "tex");
        assert_eq!(d.features[0].syntax.as_deref(), Some(&b"{\"text_escapes\":\"$\"}"[..]));
        assert!(d.features[1].default && d.features[1].syntax.is_none());
        assert_eq!(d.sets[0].extensions[0], "orgp");
        assert_eq!(d.samples[1].features[0], "math");

        assert!(Description::parse(br#"{"name":"org","dialects":[],"samples":["x"]}"#, &mut diag).is_err());
        assert!(diag.contains("a set (\"sets\")"));
        diag.clear();
        assert!(Description::parse(br#"{"name":"org","samples":[1]}"#, &mut diag).is_err());
        assert!(diag.contains("samples[0] is a string"));
    }

    #[test]
    fn what_a_feature_requires_comes_on_with_it() {
        static LAST: AtomicU32 = AtomicU32::new(0);
        let seen = |call: &Call, source: &[u8]| {
            LAST.store(call.features, Ordering::SeqCst);
            failing_parse(call, source)
        };
        let fmt = register_ok(
            Language::new(seen),
            Description {
                name: "requiring".into(),
                features: vec![
                    Feature { name: "colors".into(), requires: vec!["marks".into()], ..Default::default() },
                    Feature { name: "marks".into(), ..Default::default() },
                    Feature { name: "loud".into(), default: true, ..Default::default() },
                ],
                sets: vec![Set { name: "requiring-colors".into(), features: vec!["colors".into()], ..Default::default() }],
                samples: plain_samples(&["x"]),
                ..Default::default()
            },
        );
        format::parse(fmt, &ParseConfig { features: 1, ..Default::default() }, b"x").unwrap();
        assert_eq!(LAST.load(Ordering::SeqCst), 0b111);
        let set = format::parse_format_name("requiring-colors").unwrap();
        format::parse(set, &ParseConfig::default(), b"x").unwrap();
        assert_eq!(LAST.load(Ordering::SeqCst), 0b011);
        // A bit no feature holds is not a feature.
        format::parse(fmt, &ParseConfig { features: 1 << 20, ..Default::default() }, b"x").unwrap();
        assert_eq!(LAST.load(Ordering::SeqCst), 0b100);
    }
}
