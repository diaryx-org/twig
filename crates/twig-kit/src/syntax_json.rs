//! A `Syntax` written down as JSON, and read back. Port of
//! `src/syntax_json.zig`.
//!
//! A runtime language that authors has to hand core the table its gestures
//! read, so `Syntax` crosses the boundary as data, and the compiled formats
//! cross it first: every compiled table, encoded and decoded, is the table it
//! was.
//!
//! ── The shape ──────────────────────────────────────────────────────────────
//! One object, keyed by `Syntax`'s field names:
//!
//!   * a byte string is a JSON string; a single byte (`heading_marker`,
//!     `code_fence.char`) is a one-byte string;
//!   * an enum is its tag name, a flag a bool, a count an integer;
//!   * an enum-indexed table is an object keyed by the enum's tag names — a
//!     table of optionals names only the keys it spells, a table of values
//!     names all;
//!   * a nested struct is an object, and a list of them an array;
//!   * a member left at its default is omitted, and a member omitted takes its
//!     default, so `{}` is `syntax::none()`.
//!
//! The three renderers are functions and do not cross. What crosses is which
//! ones the language answers itself, as `renderers`. A table that states
//! `text_escapes` renders literals by the alphabet renderer, so it names no
//! `render_text`.
//!
//! Decoding does not validate — `Syntax::validate` does, once the renderers
//! are bound. Decoding refuses what is not a `Syntax` at all, filling a
//! `Problem` with the key path at fault.
//!
//! Zig derives the encoding from the struct by reflection; Rust has none, so
//! each struct's members are written out here in declaration order. The
//! identity test (every compiled table round-trips) is what keeps the two in
//! step.

use crate::ast::{InlineMark, TextLeafKind};
use crate::json::{self, Stringify, Value};
use crate::syntax::{
    AlignmentCells, AngleEscapes, AttrSpelling, BlockAttrs, CodeFence, ContainerKind, ContainerSpelling, Delims,
    DestEscapes, FootnoteSpelling, MarkColor, MarkColors, NodeAttrs, Quoting, Syntax, TableSpelling, TaskMarker,
    TextRenderer, ALIGNMENTS,
};

/// Which renderers a table's language answers itself.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Renderers {
    pub render_text: bool,
    pub render_block: bool,
    pub spells_autolink: bool,
}

impl Renderers {
    /// What `s` answers itself: every renderer it carries, except the alphabet
    /// renderer, which its `text_escapes` already says.
    pub fn of(s: &Syntax) -> Renderers {
        Renderers {
            render_text: matches!(s.render_text, Some(TextRenderer::Custom(_))),
            render_block: s.render_block.is_some(),
            spells_autolink: s.spells_autolink.is_some(),
        }
    }
}

/// A decoded table: every spelling, the alphabet renderer bound where an
/// alphabet is stated, and the other renderers named but unbound.
#[derive(Clone, Copy, Debug)]
pub struct Decoded {
    pub syntax: Syntax,
    pub renderers: Renderers,
}

/// Why a description's `syntax` was refused: the key path at fault, and what
/// is wrong with it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Problem {
    pub path: String,
    pub what: &'static str,
}

#[derive(Clone, Copy, Debug)]
pub struct Options {
    pub pretty: bool,
}

impl Default for Options {
    fn default() -> Options {
        Options { pretty: true }
    }
}

// ── Encoding ────────────────────────────────────────────────────────────────

pub fn encode(out: &mut Vec<u8>, s: &Syntax, options: Options) {
    let mut w = if options.pretty { Stringify::pretty(out) } else { Stringify::compact(out) };
    w.begin_object();
    write_syntax_members(&mut w, s);
    let r = Renderers::of(s);
    if r.render_text || r.render_block || r.spells_autolink {
        w.field("renderers");
        w.begin_array();
        if r.render_text {
            w.str(b"render_text");
        }
        if r.render_block {
            w.str(b"render_block");
        }
        if r.spells_autolink {
            w.str(b"spells_autolink");
        }
        w.end_array();
    }
    w.end_object();
}

pub fn encode_alloc(s: &Syntax, options: Options) -> Vec<u8> {
    let mut out = Vec::new();
    encode(&mut out, s, options);
    out
}

fn bytes_field(w: &mut Stringify, name: &str, v: &[u8], default: Option<&[u8]>) {
    if default == Some(v) {
        return;
    }
    w.field(name);
    w.str(v);
}

fn opt_bytes_field(w: &mut Stringify, name: &str, v: Option<&[u8]>) {
    if let Some(v) = v {
        w.field(name);
        w.str(v);
    }
}

fn bool_field(w: &mut Stringify, name: &str, v: bool, default: bool) {
    if v != default {
        w.field(name);
        w.bool(v);
    }
}

fn write_delims(w: &mut Stringify, d: &Delims) {
    w.begin_object();
    bytes_field(w, "open", d.open, None);
    bytes_field(w, "close", d.close, None);
    bool_field(w, "authorable", d.authorable, true);
    w.end_object();
}

/// An enum-indexed table of optionals: only the keys it spells.
fn write_delims_table(w: &mut Stringify, name: &str, table: &[Option<Delims>], names: &[&str]) {
    if table.iter().all(|d| d.is_none()) {
        return;
    }
    w.field(name);
    w.begin_object();
    for (d, n) in table.iter().zip(names) {
        if let Some(d) = d {
            w.field(n);
            write_delims(w, d);
        }
    }
    w.end_object();
}

fn write_syntax_members(w: &mut Stringify, s: &Syntax) {
    let marks: Vec<&str> = InlineMark::ALL.iter().map(|m| m.name()).collect();
    let leaves: Vec<&str> = TextLeafKind::ALL.iter().map(|m| m.name()).collect();
    write_delims_table(w, "inline_delims", &s.inline_delims, &marks);
    write_delims_table(w, "text_leaf_delims", &s.text_leaf_delims, &leaves);
    if let Some(mc) = &s.mark_colors {
        w.field("mark_colors");
        w.begin_object();
        bytes_field(w, "attr_key", mc.attr_key, None);
        w.field("colors");
        w.begin_array();
        for c in mc.colors {
            w.begin_object();
            bytes_field(w, "name", c.name, None);
            bytes_field(w, "prefix", c.prefix, None);
            w.end_object();
        }
        w.end_array();
        bytes_field(w, "space", mc.space, Some(b" "));
        w.end_object();
    }
    if s.container_spelling.iter().any(|c| c.is_some()) {
        w.field("container_spelling");
        w.begin_object();
        for k in ContainerKind::ALL {
            if let Some(c) = s.container(k) {
                w.field(k.name());
                w.begin_object();
                bytes_field(w, "marker", c.marker, None);
                bytes_field(w, "cont", c.cont, None);
                bytes_field(w, "blank", c.blank, None);
                bool_field(w, "numbered", c.numbered, false);
                w.end_object();
            }
        }
        w.end_object();
    }
    if let Some(a) = &s.attr_spelling {
        w.field("attr_spelling");
        w.begin_object();
        let d = AttrSpelling::DEFAULT;
        bytes_field(w, "open", a.open, Some(d.open));
        bytes_field(w, "close", a.close, Some(d.close));
        bytes_field(w, "between", a.between, Some(d.between));
        bytes_field(w, "key_prefix", a.key_prefix, Some(d.key_prefix));
        bytes_field(w, "key_value", a.key_value, Some(d.key_value));
        if a.quoting != d.quoting {
            w.field("quoting");
            w.str(a.quoting.name().as_bytes());
        }
        bytes_field(w, "quote_escapes", a.quote_escapes, Some(d.quote_escapes));
        opt_bytes_field(w, "id_sigil", a.id_sigil);
        opt_bytes_field(w, "class_sigil", a.class_sigil);
        w.end_object();
    }
    if let Some(h) = s.heading_marker {
        w.field("heading_marker");
        w.str(&[h]);
    }
    bool_field(w, "heading_continues", s.heading_continues, false);
    opt_bytes_field(w, "thematic_break", s.thematic_break);
    if let Some(f) = &s.code_fence {
        w.field("code_fence");
        w.begin_object();
        w.field("char");
        w.str(&[f.char]);
        if f.min != 3 {
            w.field("min");
            w.int(f.min as u64);
        }
        bytes_field(w, "info_forbids", f.info_forbids, Some(b""));
        w.end_object();
    }
    if let Some(t) = &s.task_marker {
        w.field("task_marker");
        w.begin_object();
        bytes_field(w, "unchecked", t.unchecked, None);
        bytes_field(w, "checked", t.checked, None);
        bytes_field(w, "space", t.space, Some(b" "));
        bytes_field(w, "checked_chars", t.checked_chars, Some(b"xX"));
        w.end_object();
    }
    if let Some(f) = &s.footnote {
        w.field("footnote");
        w.begin_object();
        bytes_field(w, "ref_open", f.ref_open, None);
        bytes_field(w, "ref_close", f.ref_close, None);
        bytes_field(w, "def_suffix", f.def_suffix, None);
        bytes_field(w, "label_forbids", f.label_forbids, Some(b"[]"));
        w.end_object();
    }
    if let Some(t) = &s.table_spelling {
        w.field("table_spelling");
        w.begin_object();
        bytes_field(w, "bar", t.bar, None);
        bytes_field(w, "pad", t.pad, Some(b" "));
        bytes_field(w, "delim_pad", t.delim_pad, None);
        w.field("delim");
        w.begin_object();
        for a in ALIGNMENTS {
            w.field(a.name());
            w.str(t.delim.get(a));
        }
        w.end_object();
        w.end_object();
    }
    opt_bytes_field(w, "block_separator", s.block_separator);
    opt_bytes_field(w, "line_join", s.line_join);
    opt_bytes_field(w, "list_attach", s.list_attach);
    opt_bytes_field(w, "link_text_escapes", s.link_text_escapes);
    if let Some(d) = &s.link_dest_escapes {
        w.field("link_dest_escapes");
        w.begin_object();
        bytes_field(w, "plain", d.plain, None);
        if let Some(a) = &d.angle {
            w.field("angle");
            w.begin_object();
            bytes_field(w, "escapes", a.escapes, None);
            w.end_object();
        }
        w.end_object();
    }
    opt_bytes_field(w, "text_escapes", s.text_escapes);
    opt_bytes_field(w, "block_start_escapes", s.block_start_escapes);
    opt_bytes_field(w, "cell_line_break", s.cell_line_break);
    bool_field(w, "names_leaf_containers", s.names_leaf_containers, false);
    if let Some(b) = s.block_attrs {
        w.field("block_attrs");
        w.str(b.name().as_bytes());
    }
    if let Some(n) = &s.node_attrs {
        w.field("node_attrs");
        w.begin_object();
        bytes_field(w, "open", n.open, Some(b"<"));
        w.end_object();
    }
    bool_field(w, "inline_attrs", s.inline_attrs, false);
    bool_field(w, "line_blocks", s.line_blocks, false);
}

// ── Equality ────────────────────────────────────────────────────────────────

/// Two tables spell the same: every byte string equal by content, every
/// renderer the same function.
pub fn eql(a: &Syntax, b: &Syntax) -> bool {
    let renderers = match (a.render_text, b.render_text) {
        (None, None) | (Some(TextRenderer::Alphabet), Some(TextRenderer::Alphabet)) => true,
        (Some(TextRenderer::Custom(x)), Some(TextRenderer::Custom(y))) => std::ptr::fn_addr_eq(x, y),
        _ => false,
    } && match (a.render_block, b.render_block) {
        (None, None) => true,
        (Some(x), Some(y)) => std::ptr::fn_addr_eq(x, y),
        _ => false,
    } && match (a.spells_autolink, b.spells_autolink) {
        (None, None) => true,
        (Some(x), Some(y)) => std::ptr::fn_addr_eq(x, y),
        _ => false,
    } && match (a.renderer_context, b.renderer_context) {
        (None, None) => true,
        (Some(x), Some(y)) => std::ptr::addr_eq(x, y),
        _ => false,
    };
    renderers
        && a.inline_delims == b.inline_delims
        && a.text_leaf_delims == b.text_leaf_delims
        && a.mark_colors == b.mark_colors
        && a.container_spelling == b.container_spelling
        && a.attr_spelling == b.attr_spelling
        && a.heading_marker == b.heading_marker
        && a.heading_continues == b.heading_continues
        && a.thematic_break == b.thematic_break
        && a.code_fence == b.code_fence
        && a.task_marker == b.task_marker
        && a.footnote == b.footnote
        && a.table_spelling == b.table_spelling
        && a.block_separator == b.block_separator
        && a.line_join == b.line_join
        && a.list_attach == b.list_attach
        && a.link_text_escapes == b.link_text_escapes
        && a.link_dest_escapes == b.link_dest_escapes
        && a.text_escapes == b.text_escapes
        && a.block_start_escapes == b.block_start_escapes
        && a.cell_line_break == b.cell_line_break
        && a.names_leaf_containers == b.names_leaf_containers
        && a.block_attrs == b.block_attrs
        && a.node_attrs == b.node_attrs
        && a.inline_attrs == b.inline_attrs
        && a.line_blocks == b.line_blocks
}

// ── Decoding ────────────────────────────────────────────────────────────────

/// Read a `Syntax` from its JSON value. Strings are leaked into `'static`
/// storage (a decoded table lives as long as the language it describes — the
/// Zig decoder copies into an arena the registry keeps for the process). The
/// alphabet renderer is bound where `text_escapes` is stated; the renderers
/// `renderers` names are left `None` for the caller.
pub fn from_value(value: &Value) -> Result<Decoded, Problem> {
    let obj = object(value, "")?;
    let mut syntax = members_syntax(&obj)?;
    let mut renderers = Renderers::default();
    if let Some(list) = obj.get("renderers") {
        let Some(items) = list.as_array() else { return fail("renderers", "is not an array") };
        for item in items {
            let Some(name) = item.as_str() else {
                return fail("renderers", "holds a value that is not a renderer's name");
            };
            match name {
                b"render_text" => renderers.render_text = true,
                b"render_block" => renderers.render_block = true,
                b"spells_autolink" => renderers.spells_autolink = true,
                _ => {
                    return fail(
                        "renderers",
                        "names a renderer that is not render_text, render_block or spells_autolink",
                    );
                }
            }
        }
    }
    if syntax.text_escapes.is_some() {
        syntax.render_text = Some(TextRenderer::Alphabet);
    }
    Ok(Decoded { syntax, renderers })
}

/// `from_value` over JSON text.
pub fn decode(text: &[u8]) -> Result<Decoded, Problem> {
    let value = json::parse(text).map_err(|_| Problem { path: String::new(), what: "is not JSON" })?;
    from_value(&value)
}

fn fail<T>(path: &str, what: &'static str) -> Result<T, Problem> {
    Err(Problem { path: path.to_string(), what })
}

fn join(path: &str, key: &str) -> String {
    if path.is_empty() { key.to_string() } else { format!("{path}.{key}") }
}

fn leak(s: &[u8]) -> &'static [u8] {
    Box::leak(s.to_vec().into_boxed_slice())
}

/// An object being read: its entries and its key path.
struct Obj<'v> {
    entries: &'v [(Vec<u8>, Value)],
    path: String,
}

fn object<'v>(v: &'v Value, path: &str) -> Result<Obj<'v>, Problem> {
    match v.as_object() {
        Some(entries) => Ok(Obj { entries, path: path.to_string() }),
        None => fail(path, "is not an object"),
    }
}

impl<'v> Obj<'v> {
    fn get(&self, key: &str) -> Option<&'v Value> {
        self.entries.iter().rev().find(|(k, _)| k == key.as_bytes()).map(|(_, v)| v)
    }

    fn sub(&self, key: &str) -> String {
        join(&self.path, key)
    }

    /// A member with no default: present, or refused.
    fn req<T>(&self, key: &str, f: impl Fn(&'v Value, &str) -> Result<T, Problem>) -> Result<T, Problem> {
        let path = self.sub(key);
        match self.get(key) {
            Some(v) => f(v, &path),
            None => fail(&path, "is missing, and has no default"),
        }
    }

    /// A member with a default.
    fn or<T>(&self, key: &str, default: T, f: impl Fn(&'v Value, &str) -> Result<T, Problem>) -> Result<T, Problem> {
        match self.get(key) {
            Some(v) => f(v, &self.sub(key)),
            None => Ok(default),
        }
    }

    /// An optional member (default `None`); JSON `null` is `None` too.
    fn opt<T>(&self, key: &str, f: impl Fn(&'v Value, &str) -> Result<T, Problem>) -> Result<Option<T>, Problem> {
        match self.get(key) {
            Some(Value::Null) | None => Ok(None),
            Some(v) => f(v, &self.sub(key)).map(Some),
        }
    }

    /// Refuse a key that is no member of this table.
    fn only(&self, known: &[&str]) -> Result<(), Problem> {
        for (k, _) in self.entries {
            if !known.iter().any(|n| n.as_bytes() == k.as_slice()) {
                return fail(&self.sub(&String::from_utf8_lossy(k)), "is not a member of this table");
            }
        }
        Ok(())
    }
}

fn bytes(v: &Value, path: &str) -> Result<&'static [u8], Problem> {
    match v.as_str() {
        Some(s) => Ok(leak(s)),
        None => fail(path, "is not a string"),
    }
}

fn byte(v: &Value, path: &str) -> Result<u8, Problem> {
    match v.as_str() {
        Some(s) if s.len() == 1 => Ok(s[0]),
        _ => fail(path, "is not a one-byte string"),
    }
}

fn boolean(v: &Value, path: &str) -> Result<bool, Problem> {
    match v.as_bool() {
        Some(b) => Ok(b),
        None => fail(path, "is not a bool"),
    }
}

fn count(v: &Value, path: &str) -> Result<usize, Problem> {
    match v {
        Value::Int(i) => usize::try_from(*i).or_else(|_| fail(path, "is out of range")),
        _ => fail(path, "is not an integer"),
    }
}

fn name<T>(v: &Value, path: &str, from: impl Fn(&[u8]) -> Option<T>) -> Result<T, Problem> {
    let Some(s) = v.as_str() else { return fail(path, "is not a name") };
    match from(s) {
        Some(t) => Ok(t),
        None => fail(path, "names no value this member takes"),
    }
}

fn delims(v: &Value, path: &str) -> Result<Delims, Problem> {
    let o = object(v, path)?;
    let d = Delims { open: o.req("open", bytes)?, close: o.req("close", bytes)?, authorable: o.or("authorable", true, boolean)? };
    o.only(&["open", "close", "authorable"])?;
    Ok(d)
}

/// An enum-indexed table of optionals.
fn delims_table<const N: usize>(v: &Value, path: &str, names: [&str; N]) -> Result<[Option<Delims>; N], Problem> {
    let o = object(v, path)?;
    let mut out = [None; N];
    for (slot, n) in out.iter_mut().zip(names) {
        if let Some(item) = o.get(n) {
            *slot = Some(delims(item, &o.sub(n))?);
        }
    }
    for (k, _) in o.entries {
        if !names.iter().any(|n| n.as_bytes() == k.as_slice()) {
            return fail(&o.sub(&String::from_utf8_lossy(k)), "is not a key of this table");
        }
    }
    Ok(out)
}

fn mark_colors(v: &Value, path: &str) -> Result<MarkColors, Problem> {
    let o = object(v, path)?;
    let attr_key = o.req("attr_key", bytes)?;
    let colors = o.req("colors", |v, p| {
        let Some(items) = v.as_array() else { return fail(p, "is not an array") };
        let mut out = Vec::with_capacity(items.len());
        for (i, item) in items.iter().enumerate() {
            let ip = format!("{p}[{i}]");
            let c = object(item, &ip)?;
            let color = MarkColor { name: c.req("name", bytes)?, prefix: c.req("prefix", bytes)? };
            c.only(&["name", "prefix"])?;
            out.push(color);
        }
        Ok(&*Box::leak(out.into_boxed_slice()))
    })?;
    let space = o.or("space", &b" "[..], bytes)?;
    o.only(&["attr_key", "colors", "space"])?;
    Ok(MarkColors { attr_key, colors, space })
}

fn container_table(v: &Value, path: &str) -> Result<[Option<ContainerSpelling>; 3], Problem> {
    let o = object(v, path)?;
    let mut out = [None; 3];
    for k in ContainerKind::ALL {
        if let Some(item) = o.get(k.name()) {
            let c = object(item, &o.sub(k.name()))?;
            let sp = ContainerSpelling {
                marker: c.req("marker", bytes)?,
                cont: c.req("cont", bytes)?,
                blank: c.req("blank", bytes)?,
                numbered: c.or("numbered", false, boolean)?,
            };
            c.only(&["marker", "cont", "blank", "numbered"])?;
            out[k as usize] = Some(sp);
        }
    }
    for (k, _) in o.entries {
        if ContainerKind::from_name(&String::from_utf8_lossy(k)).is_none() {
            return fail(&o.sub(&String::from_utf8_lossy(k)), "is not a key of this table");
        }
    }
    Ok(out)
}

fn attr_spelling(v: &Value, path: &str) -> Result<AttrSpelling, Problem> {
    let o = object(v, path)?;
    let d = AttrSpelling::DEFAULT;
    let a = AttrSpelling {
        open: o.or("open", d.open, bytes)?,
        close: o.or("close", d.close, bytes)?,
        between: o.or("between", d.between, bytes)?,
        key_prefix: o.or("key_prefix", d.key_prefix, bytes)?,
        key_value: o.or("key_value", d.key_value, bytes)?,
        quoting: o.or("quoting", d.quoting, |v, p| name(v, p, Quoting::from_name))?,
        quote_escapes: o.or("quote_escapes", d.quote_escapes, bytes)?,
        id_sigil: o.opt("id_sigil", bytes)?,
        class_sigil: o.opt("class_sigil", bytes)?,
    };
    o.only(&[
        "open",
        "close",
        "between",
        "key_prefix",
        "key_value",
        "quoting",
        "quote_escapes",
        "id_sigil",
        "class_sigil",
    ])?;
    Ok(a)
}

fn code_fence(v: &Value, path: &str) -> Result<CodeFence, Problem> {
    let o = object(v, path)?;
    let f = CodeFence { char: o.req("char", byte)?, min: o.or("min", 3, count)?, info_forbids: o.or("info_forbids", &b""[..], bytes)? };
    o.only(&["char", "min", "info_forbids"])?;
    Ok(f)
}

fn task_marker(v: &Value, path: &str) -> Result<TaskMarker, Problem> {
    let o = object(v, path)?;
    let t = TaskMarker {
        unchecked: o.req("unchecked", bytes)?,
        checked: o.req("checked", bytes)?,
        space: o.or("space", &b" "[..], bytes)?,
        checked_chars: o.or("checked_chars", &b"xX"[..], bytes)?,
    };
    o.only(&["unchecked", "checked", "space", "checked_chars"])?;
    Ok(t)
}

fn footnote(v: &Value, path: &str) -> Result<FootnoteSpelling, Problem> {
    let o = object(v, path)?;
    let f = FootnoteSpelling {
        ref_open: o.req("ref_open", bytes)?,
        ref_close: o.req("ref_close", bytes)?,
        def_suffix: o.req("def_suffix", bytes)?,
        label_forbids: o.or("label_forbids", &b"[]"[..], bytes)?,
    };
    o.only(&["ref_open", "ref_close", "def_suffix", "label_forbids"])?;
    Ok(f)
}

fn table_spelling(v: &Value, path: &str) -> Result<TableSpelling, Problem> {
    let o = object(v, path)?;
    let bar = o.req("bar", bytes)?;
    let pad = o.or("pad", &b" "[..], bytes)?;
    let delim_pad = o.req("delim_pad", bytes)?;
    let delim = o.req("delim", |v, p| {
        let d = object(v, p)?;
        let mut cells = AlignmentCells::new("", "", "", "");
        for a in ALIGNMENTS {
            match d.get(a.name()) {
                Some(item) => *cells.get_mut(a) = bytes(item, &d.sub(a.name()))?,
                None => return fail(&d.sub(a.name()), "is missing"),
            }
        }
        for (k, _) in d.entries {
            if !ALIGNMENTS.iter().any(|a| a.name().as_bytes() == k.as_slice()) {
                return fail(&d.sub(&String::from_utf8_lossy(k)), "is not a key of this table");
            }
        }
        Ok(cells)
    })?;
    o.only(&["bar", "pad", "delim_pad", "delim"])?;
    Ok(TableSpelling { bar, pad, delim_pad, delim })
}

fn dest_escapes(v: &Value, path: &str) -> Result<DestEscapes, Problem> {
    let o = object(v, path)?;
    let plain = o.req("plain", bytes)?;
    let angle = o.opt("angle", |v, p| {
        let a = object(v, p)?;
        let e = AngleEscapes { escapes: a.req("escapes", bytes)? };
        a.only(&["escapes"])?;
        Ok(e)
    })?;
    o.only(&["plain", "angle"])?;
    Ok(DestEscapes { plain, angle })
}

fn node_attrs(v: &Value, path: &str) -> Result<NodeAttrs, Problem> {
    let o = object(v, path)?;
    let n = NodeAttrs { open: o.or("open", &b"<"[..], bytes)? };
    o.only(&["open"])?;
    Ok(n)
}

const SYNTAX_MEMBERS: [&str; 25] = [
    "inline_delims",
    "text_leaf_delims",
    "mark_colors",
    "container_spelling",
    "attr_spelling",
    "heading_marker",
    "heading_continues",
    "thematic_break",
    "code_fence",
    "task_marker",
    "footnote",
    "table_spelling",
    "block_separator",
    "line_join",
    "list_attach",
    "link_text_escapes",
    "link_dest_escapes",
    "text_escapes",
    "block_start_escapes",
    "cell_line_break",
    "names_leaf_containers",
    "block_attrs",
    "node_attrs",
    "inline_attrs",
    "line_blocks",
];

fn members_syntax(o: &Obj) -> Result<Syntax, Problem> {
    let marks = InlineMark::ALL.map(|m| m.name());
    let leaves = TextLeafKind::ALL.map(|m| m.name());
    let s = Syntax {
        inline_delims: o.or("inline_delims", [None; 9], |v, p| delims_table(v, p, marks))?,
        text_leaf_delims: o.or("text_leaf_delims", [None; 9], |v, p| delims_table(v, p, leaves))?,
        mark_colors: o.opt("mark_colors", mark_colors)?,
        container_spelling: o.or("container_spelling", [None; 3], container_table)?,
        attr_spelling: o.opt("attr_spelling", attr_spelling)?,
        heading_marker: o.opt("heading_marker", byte)?,
        heading_continues: o.or("heading_continues", false, boolean)?,
        thematic_break: o.opt("thematic_break", bytes)?,
        code_fence: o.opt("code_fence", code_fence)?,
        task_marker: o.opt("task_marker", task_marker)?,
        footnote: o.opt("footnote", footnote)?,
        table_spelling: o.opt("table_spelling", table_spelling)?,
        block_separator: o.opt("block_separator", bytes)?,
        line_join: o.opt("line_join", bytes)?,
        list_attach: o.opt("list_attach", bytes)?,
        link_text_escapes: o.opt("link_text_escapes", bytes)?,
        link_dest_escapes: o.opt("link_dest_escapes", dest_escapes)?,
        text_escapes: o.opt("text_escapes", bytes)?,
        block_start_escapes: o.opt("block_start_escapes", bytes)?,
        cell_line_break: o.opt("cell_line_break", bytes)?,
        names_leaf_containers: o.or("names_leaf_containers", false, boolean)?,
        block_attrs: o.opt("block_attrs", |v, p| name(v, p, BlockAttrs::from_name))?,
        node_attrs: o.opt("node_attrs", node_attrs)?,
        inline_attrs: o.or("inline_attrs", false, boolean)?,
        line_blocks: o.or("line_blocks", false, boolean)?,
        ..Syntax::NONE
    };
    let mut known: Vec<&str> = SYNTAX_MEMBERS.to_vec();
    known.push("renderers");
    o.only(&known)?;
    Ok(s)
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax;

    #[test]
    fn the_empty_object_is_the_table_that_spells_nothing() {
        let decoded = decode(b"{}").unwrap();
        assert!(eql(syntax::none(), &decoded.syntax));
        assert_eq!(encode_alloc(syntax::none(), Options { pretty: false }), b"{}");
    }

    #[test]
    fn a_description_states_only_what_it_spells() {
        let decoded = decode(
            br#"{"inline_delims":{"strong":{"open":"*","close":"*"},"mark":{"open":"==","close":"==","authorable":false}},
 "heading_marker":"=","code_fence":{"char":"~"},
 "text_escapes":"*\\","block_start_escapes":"=",
 "table_spelling":{"bar":"|","delim_pad":" ","delim":{"default":"---","left":":--","right":"--:","center":":-:"}},
 "renderers":["render_block"]}"#,
        )
        .unwrap();
        let s = decoded.syntax;
        assert_eq!(s.inline_delim(InlineMark::Strong).unwrap().open, b"*");
        assert!(s.inline_delim(InlineMark::Strong).unwrap().authorable);
        assert!(!s.inline_delim(InlineMark::Mark).unwrap().authorable);
        assert!(s.inline_delim(InlineMark::Emph).is_none());
        assert_eq!(s.heading_marker, Some(b'='));
        assert_eq!(s.code_fence.unwrap().char, b'~');
        assert_eq!(s.code_fence.unwrap().min, 3);
        assert_eq!(s.table_spelling.unwrap().pad, b" ");
        assert!(s.renders_text_by_alphabet());
        assert!(decoded.renderers.render_block && !decoded.renderers.render_text);
        assert!(s.render_block.is_none());
    }

    #[test]
    fn what_is_not_a_syntax_is_refused_at_its_path() {
        let cases: [(&[u8], &str); 9] = [
            (br###"{"heading_markr":"#"}"###, "heading_markr"),
            (br###"{"heading_marker":"##"}"###, "heading_marker"),
            (br#"{"inline_delims":{"bold":{"open":"*","close":"*"}}}"#, "inline_delims.bold"),
            (br#"{"inline_delims":{"strong":{"open":"*"}}}"#, "inline_delims.strong.close"),
            (br#"{"attr_spelling":{"quoting":"sometimes"}}"#, "attr_spelling.quoting"),
            (br#"{"table_spelling":{"bar":"|","delim_pad":"","delim":{"default":"---"}}}"#, "table_spelling.delim.left"),
            (br#"{"mark_colors":{"attr_key":"c","colors":[{"name":"red"}]}}"#, "mark_colors.colors[0].prefix"),
            (br#"{"renderers":["render_html"]}"#, "renderers"),
            (b"[]", ""),
        ];
        for (text, path) in cases {
            let p = decode(text).unwrap_err();
            assert_eq!(p.path, path, "case {}", String::from_utf8_lossy(text));
        }
    }
}
