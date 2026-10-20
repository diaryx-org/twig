//! The engine contract: what `Editor`, the serializers and the node table
//! assume of a format, as checks that report rather than assert. Port of
//! `src/contract.zig`.
//!
//! ── Why a library ──────────────────────────────────────────────────────────
//! A compiled format has its test suite, and the suite's registry-wide half is
//! the list of promises the engine rests on: every sample parses, prints and
//! reparses; a declared renderer's print reparses to what it was given; a
//! claim a table makes is kept; a block moves across containers the way a
//! person would have typed it. A runtime language has no test suite. It has
//! registration, and registration has to hold it to the same list. So the
//! list lives here, as functions that return [`Broken`] with a [`Report`]
//! saying which promise and over which source. Compiled and runtime formats
//! are held to literally the same checks.

use crate::ast::{select, table as node_table, Ast, Attrs, Builder, Form, Kind, KeyVal, ListNumbering, Link, NodeId, Tag};
use crate::document::Document;
use crate::format::{self, Format, ParseConfig, ParsedDoc};
use crate::runtime;
use crate::syntax::{BlockAttrs, Syntax};
use crate::ast::editor::{self, BlockKind, ContainerKind, Editor, Gesture, InlineKind};
use crate::ast::splicer::{ParseError, ParseFn};
use crate::ast::{Alignment, KindRef, TextLeafKind};
use crate::document::ContainerOrigin;
use crate::span::Span;
use std::sync::Arc;

/// A broken promise; the [`Report`] says which.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Broken;

pub type CheckResult = Result<(), Broken>;

type ParseArc = Arc<dyn Fn(&ParseConfig, &[u8]) -> Result<ParsedDoc, String>>;
type ParseAstArc = Arc<dyn Fn(&ParseConfig, &[u8]) -> Result<Document, String>>;
type CanonicalArc = Arc<dyn Fn(&ParsedDoc) -> Result<Vec<u8>, String>>;
type FromAstArc = Arc<dyn Fn(&Ast) -> Result<Vec<u8>, String>>;
type SyntaxForArc = Arc<dyn Fn(&ParseConfig) -> &'static Syntax>;

/// One row as the checks see it (Zig's `format.Entry`, with its target's
/// `serializeFromAst` beside it). Every failing call answers with a reason:
/// the error's name for a compiled row, the language's own for a runtime one.
#[derive(Clone)]
pub struct Entry {
    pub id: Format,
    pub samples: Vec<Vec<u8>>,
    pub parse: ParseArc,
    pub parse_to_ast: ParseAstArc,
    pub serialize_canonical: Option<CanonicalArc>,
    /// The row's target's printer from a bare tree.
    pub serialize_from_ast: Option<FromAstArc>,
    pub syntax: &'static Syntax,
    pub syntax_for: Option<SyntaxForArc>,
}

impl Entry {
    /// A compiled row, as the format registry has it — or a registered
    /// runtime row.
    pub fn of(fmt: Format) -> Entry {
        if fmt.is_runtime() {
            if let Some(e) = runtime::contract_entry(fmt.code()) {
                return e;
            }
        }
        let samples = format::samples_of(fmt);
        let target = format::target_for(fmt);
        Entry {
            id: fmt,
            samples,
            parse: Arc::new(move |cfg, src| format::parse(fmt, cfg, src).map_err(|e| e.name())),
            parse_to_ast: Arc::new(move |cfg, src| format::parse_to_ast(fmt, cfg, src).map_err(|e| e.name())),
            serialize_canonical: Some(Arc::new(|doc| format::serialize_canonical(doc).map_err(|e| e.name()))),
            serialize_from_ast: if format::target_serializes_from_ast(target) {
                Some(Arc::new(move |ast| format::serialize_from_ast(target, ast).map_err(|e| e.name())))
            } else {
                None
            },
            syntax: format::syntax_for(fmt),
            syntax_for: Some(Arc::new(move |cfg| format::syntax_for_config(fmt, cfg))),
        }
    }

    /// The splicer's parse function over this row, under `cfg`.
    fn parse_fn(&self, cfg: ParseConfig) -> ParseFn {
        let p = self.parse_to_ast.clone();
        Box::new(move |src| p(&cfg, src).map_err(ParseError::new))
    }

    fn editor(&self, source: &[u8], cfg: ParseConfig, table: &'static Syntax) -> Result<Editor, ParseError> {
        Editor::new(source, self.parse_fn(cfg), table)
    }
}

const REPORT_CAP: usize = 4096;

/// Why a check failed: one message, naming the promise, the format and the
/// source it was broken over. Truncated at 4096 bytes, as Zig's buffer is.
#[derive(Clone, Debug, Default)]
pub struct Report {
    buf: Vec<u8>,
    /// Where `gestures` logs every broken promise and carries on, rather
    /// than stopping at the first. Each message ends in a zero byte; `found`
    /// counts them.
    pub log: Option<Vec<u8>>,
    pub found: usize,
}

impl Report {
    /// A report that logs every broken gesture promise.
    pub fn logging() -> Report {
        Report { log: Some(Vec::new()), ..Default::default() }
    }

    pub fn message(&self) -> String {
        String::from_utf8_lossy(&self.buf).into_owned()
    }

    pub fn message_bytes(&self) -> &[u8] {
        &self.buf
    }

    fn set(&mut self, bytes: Vec<u8>) {
        let mut bytes = bytes;
        bytes.truncate(REPORT_CAP);
        self.buf = bytes;
    }

    pub fn fail(&mut self, message: impl Into<Vec<u8>>) -> Broken {
        self.set(message.into());
        Broken
    }

    /// `fail`, for a call that failed with `err`: with the language's own
    /// reason where a runtime language gave one.
    fn broke(&mut self, entry: &Entry, err: &str, message: impl Into<Vec<u8>>) -> Broken {
        let mut m = message.into();
        // By code rather than `is_registered`: registration runs these
        // checks over a row it has filled and not yet published.
        let why = runtime::last_failure();
        if entry.id.code() >= runtime::BASE && !why.is_empty() {
            m.extend_from_slice(format!(": {why}").as_bytes());
        } else {
            m.extend_from_slice(format!(": {err}").as_bytes());
        }
        self.set(m);
        Broken
    }
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// Every check that applies to `entry`: its samples, its renderers and the
/// claims each of its tables makes, and — where it can be authored — a block
/// moved across its containers and every gesture run everywhere it applies.
pub fn all(entry: &Entry, r: &mut Report) -> CheckResult {
    samples(entry, r)?;
    renderers(entry, r)?;
    if entry.syntax.authorable() {
        move_block(entry, r)?;
        gestures(entry, r)?;
    }
    Ok(())
}

// ── Samples ─────────────────────────────────────────────────────────────────

/// Every declared sample meets `sample`; a format that declares none is
/// refused.
pub fn samples(entry: &Entry, r: &mut Report) -> CheckResult {
    if entry.samples.is_empty() {
        return Err(r.fail(format!("{}: no samples are declared", entry.id.name())));
    }
    for (i, source) in entry.samples.iter().enumerate() {
        sample(entry, i, source, r)?;
    }
    Ok(())
}

/// One sample: it parses to a document holding exactly its source, whose
/// columns meet `check_columns`; where the format prints, the print reparses
/// to an equal tree; where it can be authored, an editor opens over it with
/// the same tree, and a zero-length splice is the identity.
pub fn sample(entry: &Entry, index: usize, source: &[u8], r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let config = ParseConfig::default();
    let first = (entry.parse)(&config, source)
        .map_err(|e| r.broke(entry, &e, format!("{name}: sample {index} does not parse")))?;
    if source != &first.doc.source[..] {
        return Err(r.fail(format!("{name}: sample {index}'s parse does not hold its source")));
    }
    columns(&first.doc, r, &name, "sample", index)?;

    if let Some(serialize) = &entry.serialize_canonical {
        let printed = serialize(&first).map_err(|e| r.broke(entry, &e, format!("{name}: sample {index} does not print")))?;
        let second = (entry.parse)(&config, &printed)
            .map_err(|e| r.broke(entry, &e, format!("{name}: sample {index}'s print does not reparse")))?;
        columns(&second.doc, r, &name, "the print of sample", index)?;
        if !first.doc.ast.eql(&second.doc.ast) {
            let mut m = format!("{name}: sample {index} prints to source that reparses to a different tree:\n").into_bytes();
            m.extend_from_slice(&printed);
            return Err(r.fail(m));
        }
    }

    if entry.syntax.authorable() {
        let mut e = entry
            .editor(source, config, entry.syntax)
            .map_err(|err| r.broke(entry, &err.name, format!("{name}: no editor opens over sample {index}")))?;
        if !first.doc.ast.eql(e.ast_view()) {
            return Err(r.fail(format!("{name}: an editor over sample {index} reads a different tree from a parse")));
        }
        columns(e.doc(), r, &name, "the editor's view of sample", index)?;
        if let Err(err) = e.splicer.replace_at_span(Span::new(0, 0), b"") {
            return Err(r.broke(entry, err.name(), format!("{name}: a zero-length splice at the head of sample {index} is refused")));
        }
        if source != e.source_bytes() || source != &e.splicer.doc.source[..] {
            return Err(r.fail(format!("{name}: a zero-length splice changed sample {index}")));
        }
        if !first.doc.ast.eql(e.ast_view()) {
            return Err(r.fail(format!("{name}: a zero-length splice changed sample {index}'s tree")));
        }
        columns(e.doc(), r, &name, "sample, after a zero-length splice,", index)?;
    }
    Ok(())
}

fn columns(doc: &Document, r: &mut Report, name: &str, what: &str, index: usize) -> CheckResult {
    node_table::check_columns(doc)
        .map_err(|problem| r.fail(format!("{name}: {what} {index}: the columns are refused: {}", problem.render())))
}

// ── Renderers and claims ────────────────────────────────────────────────────

/// The parse configs a per-table claim can be made under. A claim is a claim
/// about a TABLE, and a row with features has one table per combination
/// (Markdown's), so the table under no features, under each feature alone
/// and under every feature is asked, and parsed with the very config it came
/// from. A row with no features answers one table, and is checked once.
fn claim_configs(fmt: Format) -> Vec<ParseConfig> {
    let n = if fmt.is_runtime() { 0 } else { format::features(fmt).len().min(31) };
    let mut masks = vec![0u32];
    masks.extend((0..n).map(|i| 1u32 << i));
    masks.push((1u32 << n) - 1);
    masks.into_iter().map(|m| ParseConfig::for_features(fmt, m)).collect()
}

/// Every renderer `entry` declares keeps the engine's promise, and every
/// claim each of its tables makes is kept.
pub fn renderers(entry: &Entry, r: &mut Report) -> CheckResult {
    if entry.syntax.render_text.is_some() {
        render_text(entry, r)?;
    }
    if entry.syntax.render_block.is_some() {
        render_block(entry, r)?;
    }
    // Per table rather than per row — and each table only once.
    let mut seen: Vec<*const Syntax> = Vec::new();
    for cfg in claim_configs(entry.id) {
        let t = table_for(entry, &cfg);
        if seen.contains(&(t as *const Syntax)) {
            continue;
        }
        seen.push(t);
        if t.names_leaf_containers {
            named_leaf_container(entry, &cfg, r)?;
        }
        if let Some(shape) = t.block_attrs {
            block_attrs(entry, &cfg, shape, r)?;
        }
        if t.inline_attrs {
            inline_attrs(entry, &cfg, r)?;
        }
        if t.node_attrs.is_some() {
            node_attrs(entry, &cfg, r)?;
        }
        if t.line_blocks {
            line_blocks(entry, &cfg, r)?;
        }
    }
    Ok(())
}

/// The table `entry` holds for `cfg`.
fn table_for(entry: &Entry, cfg: &ParseConfig) -> &'static Syntax {
    match &entry.syntax_for {
        Some(f) => f(cfg),
        None => entry.syntax,
    }
}

/// A specials run every format's literal renderer must carry across a
/// reparse: the inline metacharacters, a block opener at column zero, HTML's
/// three, and a backslash.
pub const LITERAL_SPECIALS: &str = "# *a* _b_ `c` [d] <e> & \\ ~f~";

/// What `Editor` assumes of a declared `render_text`: a run inserted through
/// it at the head of an empty document reparses to visible text equal to the
/// run, with no markup minted.
pub fn render_text(entry: &Entry, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let mut e = entry
        .editor(b"", ParseConfig::default(), entry.syntax)
        .map_err(|err| r.broke(entry, &err.name, format!("{name}: no editor opens over an empty document")))?;
    if let Err(err) = e.insert_literal(0, LITERAL_SPECIALS.as_bytes()) {
        return Err(r.broke(entry, err.name(), format!("{name}: renderText: inserting a literal is refused")));
    }
    let mut visible = Vec::new();
    for n in &e.ast_view().nodes {
        match &n.kind {
            Kind::Str(t) => visible.extend_from_slice(t),
            Kind::InlineMark(_) | Kind::TextLeaf { .. } | Kind::Link(_) | Kind::Image(_) | Kind::RawInline { .. } | Kind::Heading { .. } => {
                return Err(r.fail(with_printed(
                    format!("{name}: renderText: a literal reparses with markup in it:\n").into_bytes(),
                    e.source_bytes(),
                )));
            }
            _ => {}
        }
    }
    if LITERAL_SPECIALS.as_bytes() != &visible[..] {
        return Err(r.fail(with_printed(
            format!("{name}: renderText: a literal reparses as \"{}\":\n", lossy(&visible)).into_bytes(),
            e.source_bytes(),
        )));
    }
    Ok(())
}

fn error_name(e: crate::Error) -> String {
    format!("{e:?}")
}

fn str_leaf(b: &mut Builder, text: &str) -> NodeId {
    b.add_leaf(Kind::Str(text.as_bytes().to_vec()))
}

fn para_of(b: &mut Builder, text: &str) -> NodeId {
    let s = str_leaf(b, text);
    b.add_container(Kind::Para, &[s])
}

/// What `Editor` assumes of a declared `render_block`: a heading fragment it
/// builds prints as source the format parses back to a heading of that level
/// over that text. And the same of every other fragment a gesture builds: a
/// quote and a list over paragraphs, a code block, a link and an image over
/// text — each reparses to its kind with its text intact.
pub fn render_block(entry: &Entry, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    {
        let mut b = Builder::new();
        let text = str_leaf(&mut b, "title");
        let heading = b.add_container(Kind::Heading { level: 2 }, &[text]);
        let printed = print(entry, &b, heading, r, "heading")?;
        let parsed = (entry.parse)(&ParseConfig::default(), &printed)
            .map_err(|e| r.broke(entry, &e, format!("{name}: renderBlock: a heading's print does not reparse")))?;
        let nodes = &parsed.doc.ast.nodes;
        let found = nodes.iter().find_map(|n| match n.kind {
            Kind::Heading { level } => Some(match n.first_child {
                None => false,
                Some(child) => {
                    let c = &nodes[child as usize];
                    level == 2 && matches!(&c.kind, Kind::Str(s) if s == b"title") && c.next_sibling.is_none()
                }
            }),
            _ => None,
        });
        if found != Some(true) {
            let mut m = format!("{name}: renderBlock: a level-2 heading over \"title\" reparses as something else:\n").into_bytes();
            m.extend_from_slice(&printed);
            return Err(r.fail(m));
        }
    }

    // The gesture fragments, each built the way its gesture builds it.
    let mut q = Builder::new();
    let one = para_of(&mut q, "one");
    let two = para_of(&mut q, "two");
    let quote = q.add_container(Kind::BlockQuote, &[one, two]);
    fragment_reparses(entry, &q, quote, Tag::BlockQuote, "onetwo", r)?;

    let mut l = Builder::new();
    let p1 = para_of(&mut l, "one");
    let i1 = l.add_container(Kind::ListItem, &[p1]);
    let p2 = para_of(&mut l, "two");
    let i2 = l.add_container(Kind::ListItem, &[p2]);
    let list = l.add_container(Kind::OrderedList { numbering: ListNumbering::Decimal, tight: true, start: None }, &[i1, i2]);
    fragment_reparses(entry, &l, list, Tag::OrderedList, "onetwo", r)?;

    let mut c = Builder::new();
    let code = c.add_leaf(Kind::CodeBlock { lang: Some(b"zig".to_vec()), text: b"a < b\n".to_vec() });
    fragment_reparses(entry, &c, code, Tag::CodeBlock, "a < b\n", r)?;

    let mut k = Builder::new();
    let here = str_leaf(&mut k, "here");
    let link = k.add_container(
        Kind::Link(Link { destination: Some(b"https://x.dev/?a=1&b=2".to_vec()), reference: None }),
        &[here],
    );
    fragment_reparses(entry, &k, link, Tag::Link, "here", r)?;

    let mut m = Builder::new();
    let cat = str_leaf(&mut m, "a cat");
    let image = m.add_container(Kind::Image(Link { destination: Some(b"cat.png".to_vec()), reference: None }), &[cat]);
    fragment_reparses(entry, &m, image, Tag::Image, "a cat", r)
}

/// `root` of `b` printed through `entry`'s `render_block`.
fn print(entry: &Entry, b: &Builder, root: NodeId, r: &mut Report, what: &str) -> Result<Vec<u8>, Broken> {
    print_with(entry, entry.syntax, b, root, r, what)
}

fn print_with(entry: &Entry, table: &Syntax, b: &Builder, root: NodeId, r: &mut Report, what: &str) -> Result<Vec<u8>, Broken> {
    let render = table.render_block.expect("a table with render_block");
    let view = b.view(root);
    let mut out = Vec::new();
    render(table, &view, root, &mut out).map_err(|e| {
        r.broke(entry, &error_name(e), format!("{}: renderBlock: a {what} fragment does not print", entry.id.name()))
    })?;
    Ok(out)
}

fn trim_end_newlines(s: &[u8]) -> &[u8] {
    let mut end = s.len();
    while end > 0 && s[end - 1] == b'\n' {
        end -= 1;
    }
    &s[..end]
}

/// Print `root` of `b` through `render_block`, parse the print, and find a
/// node of `tag` whose text is `text`. A link or image also has to read its
/// destination back, and a code block its language.
fn fragment_reparses(entry: &Entry, b: &Builder, root: NodeId, tag: Tag, text: &str, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let printed = print(entry, b, root, r, tag.name())?;
    let parsed = (entry.parse)(&ParseConfig::default(), &printed).map_err(|e| {
        r.broke(entry, &e, format!("{name}: renderBlock: a {} fragment's print does not reparse", tag.name()))
    })?;
    let ast = &parsed.doc.ast;
    for (i, n) in ast.nodes.iter().enumerate() {
        if n.kind.tag() != tag {
            continue;
        }
        let got = select::text_of(ast, i as NodeId);
        // Whether a listing's payload ends in a line end is the format's
        // convention, not part of the promise.
        let intact = trim_end_newlines(text.as_bytes()) == trim_end_newlines(&got)
            && match &n.kind {
                Kind::Link(v) => v.destination.as_deref() == Some(b"https://x.dev/?a=1&b=2"),
                Kind::Image(v) => v.destination.as_deref() == Some(b"cat.png"),
                Kind::CodeBlock { lang, .. } => lang.as_deref() == Some(b"zig"),
                _ => true,
            };
        if !intact {
            let mut m = format!("{name}: renderBlock: a {} fragment reparses with its text or target changed:\n", tag.name()).into_bytes();
            m.extend_from_slice(&printed);
            return Err(r.fail(m));
        }
        return Ok(());
    }
    let mut m = format!("{name}: renderBlock: a {} fragment does not reparse as one:\n", tag.name()).into_bytes();
    m.extend_from_slice(&printed);
    Err(r.fail(m))
}

/// The three attributes every attribute claim is measured with.
pub fn claim_attrs() -> Attrs {
    Attrs {
        entries: vec![
            KeyVal::new(b"id", Some(b"intro")),
            KeyVal::new(b"class", Some(b"lead")),
            KeyVal::new(b"data-size", Some(b"large")),
        ],
    }
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    needle.is_empty() || hay.windows(needle.len()).any(|w| w == needle)
}

/// Every key of `claim_attrs` is on `id`, values intact. A class is looked
/// for rather than compared.
fn has_claim_attrs(ast: &Ast, id: NodeId) -> bool {
    let a = ast.attrs_of(id);
    claim_attrs().entries.iter().all(|kv| {
        let want = kv.value.as_deref().unwrap_or_default();
        match a.get(&kv.key) {
            None => false,
            Some(v) if kv.key == b"class" => contains(v, want),
            Some(v) => v == want,
        }
    })
}

fn with_printed(mut m: Vec<u8>, printed: &[u8]) -> Vec<u8> {
    m.extend_from_slice(printed);
    m
}

/// What `Editor::set_block_attrs` assumes of a table claiming
/// `Syntax::block_attrs`: a paragraph carrying `claim_attrs`, printed through
/// `render_block`, reparses to a paragraph carrying them (`native`), or to a
/// container whose SOLE CHILD is that paragraph and which carries them
/// (`wrapped`).
pub fn block_attrs(entry: &Entry, cfg: &ParseConfig, shape: BlockAttrs, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let mut b = Builder::new();
    let para = para_of(&mut b, "text");
    b.set_attrs(para, claim_attrs());
    let printed = print_with(entry, table_for(entry, cfg), &b, para, r, "attributed block")?;
    let parsed = (entry.parse)(cfg, &printed)
        .map_err(|e| r.broke(entry, &e, format!("{name}: block_attrs: an attributed block's print does not reparse")))?;
    let ast = &parsed.doc.ast;
    for (i, n) in ast.nodes.iter().enumerate() {
        if n.kind != Kind::Para {
            continue;
        }
        let id = i as NodeId;
        let kept = match shape {
            BlockAttrs::Native => has_claim_attrs(ast, id),
            BlockAttrs::Wrapped => {
                n.next_sibling.is_none()
                    && ast.nodes.iter().enumerate().find(|(_, p)| matches!(p.kind, Kind::Container(_)) && p.first_child == Some(id)).is_some_and(
                        |(j, p)| matches!(&p.kind, Kind::Container(c) if c.form == Some(Form::BlockFenced)) && has_claim_attrs(ast, j as NodeId),
                    )
            }
        };
        if !kept {
            return Err(r.fail(with_printed(
                format!("{name}: block_attrs = {}: the attributes do not come back that way:\n", shape.name()).into_bytes(),
                &printed,
            )));
        }
        return Ok(());
    }
    Err(r.fail(with_printed(format!("{name}: block_attrs: an attributed paragraph does not reparse as one:\n").into_bytes(), &printed)))
}

/// What `Editor::toggle_line_block` assumes of a table claiming
/// `Syntax::line_blocks`: a verse — two stanzas, an indented line, a class —
/// printed through `render_block` reparses as a `line_block` with the same
/// lines in the same order, the same indents, the stanza break where it was,
/// and the class.
pub fn line_blocks(entry: &Entry, cfg: &ParseConfig, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let mut b = Builder::new();
    let want_text: [&[u8]; 4] = [b"first", b"second", b"", b"third"];
    let want_indent: [u32; 4] = [0, 1, 0, 0];
    let mut lines = Vec::new();
    for (t, ind) in want_text.iter().zip(want_indent) {
        lines.push(if t.is_empty() {
            b.add_container(Kind::Line { indent: 0 }, &[])
        } else {
            let s = b.add_leaf(Kind::Str(t.to_vec()));
            b.add_container(Kind::Line { indent: ind }, &[s])
        });
    }
    let block = b.add_container(Kind::LineBlock, &lines);
    b.set_attrs(block, Attrs { entries: vec![KeyVal::new(b"class", Some(b"c"))] });
    let printed = print_with(entry, table_for(entry, cfg), &b, block, r, "verse")?;
    let parsed = (entry.parse)(cfg, &printed)
        .map_err(|e| r.broke(entry, &e, format!("{name}: line_blocks: a verse's print does not reparse")))?;
    let ast = &parsed.doc.ast;
    for (i, n) in ast.nodes.iter().enumerate() {
        if n.kind != Kind::LineBlock {
            continue;
        }
        let id = i as NodeId;
        let class = ast.attrs_of(id).get(b"class").unwrap_or_default();
        if trim_spaces(class) != b"c" {
            return Err(r.fail(with_printed(format!("{name}: line_blocks: the verse comes back without its class:\n").into_bytes(), &printed)));
        }
        let mut k = 0usize;
        let mut child = ast.nodes[id as usize].first_child;
        while let Some(line) = child {
            if k >= want_text.len() {
                break;
            }
            let indent = match ast.nodes[line as usize].kind {
                Kind::Line { indent } => indent,
                _ => {
                    return Err(r.fail(with_printed(format!("{name}: line_blocks: a verse child is not a line:\n").into_bytes(), &printed)));
                }
            };
            let text: &[u8] = match ast.nodes[line as usize].first_child {
                Some(f) => match &ast.nodes[f as usize].kind {
                    Kind::Str(s) => s,
                    _ => b"?",
                },
                None => b"",
            };
            if indent != want_indent[k] || text != want_text[k] {
                return Err(r.fail(with_printed(
                    format!(
                        "{name}: line_blocks: line {k} comes back as {indent}×\"{}\", not {}×\"{}\":\n",
                        lossy(text),
                        want_indent[k],
                        lossy(want_text[k])
                    )
                    .into_bytes(),
                    &printed,
                )));
            }
            k += 1;
            child = ast.nodes[line as usize].next_sibling;
        }
        if k != want_text.len() {
            return Err(r.fail(with_printed(
                format!("{name}: line_blocks: the verse comes back with {k} lines, not {}:\n", want_text.len()).into_bytes(),
                &printed,
            )));
        }
        return Ok(());
    }
    Err(r.fail(with_printed(format!("{name}: line_blocks: a verse does not reparse as one:\n").into_bytes(), &printed)))
}

/// Zig's `std.mem.trim(u8, s, " ")`.
fn trim_spaces(s: &[u8]) -> &[u8] {
    let start = s.iter().position(|&c| c != b' ').unwrap_or(s.len());
    let end = s.iter().rposition(|&c| c != b' ').map_or(start, |e| e + 1);
    &s[start..end.max(start)]
}

/// What `Editor::set_node_attrs` assumes of a table claiming
/// `Syntax::node_attrs`: over every sample, the first element given
/// `claim_attrs` reparses carrying them, and given none reparses carrying
/// none.
pub fn node_attrs(entry: &Entry, cfg: &ParseConfig, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let table = table_for(entry, cfg);
    for (index, source) in entry.samples.iter().enumerate() {
        let mut e = entry
            .editor(source, *cfg, table)
            .map_err(|err| r.broke(entry, &err.name, format!("{name}: no editor opens over sample {index}")))?;
        let Some(first) = first_element(e.doc()) else { continue };
        if let Err(err) = e.set_node_attrs(first, &claim_attrs().entries) {
            return Err(r.broke(entry, err.name(), format!("{name}: node_attrs: setting attributes on sample {index}'s first element is refused")));
        }
        let lost = |e: &Editor| with_printed(format!("{name}: node_attrs: sample {index} lost its element:\n").into_bytes(), e.source_bytes());
        let Some(set) = first_element(e.doc()) else { return Err(r.fail(lost(&e))) };
        if !has_claim_attrs(e.ast_view(), set) {
            return Err(r.fail(with_printed(
                format!("{name}: node_attrs: sample {index}'s element does not carry what was set:\n").into_bytes(),
                e.source_bytes(),
            )));
        }
        if let Err(err) = e.set_node_attrs(set, &[]) {
            return Err(r.broke(entry, err.name(), format!("{name}: node_attrs: clearing sample {index}'s element is refused")));
        }
        let Some(cleared) = first_element(e.doc()) else { return Err(r.fail(lost(&e))) };
        if !e.ast_view().attrs_of(cleared).is_empty() {
            return Err(r.fail(with_printed(
                format!("{name}: node_attrs: sample {index}'s element keeps attributes once cleared:\n").into_bytes(),
                e.source_bytes(),
            )));
        }
    }
    Ok(())
}

/// The first element-origin container of `doc` — what a parser made of a
/// tag, as opposed to a directive or a fenced div.
fn first_element(doc: &Document) -> Option<NodeId> {
    (0..doc.ast.nodes.len() as NodeId)
        .find(|&id| matches!(doc.ast.kind(id), Kind::Container(_)) && doc.container_origin(id) == Some(ContainerOrigin::Element))
}

/// What `Editor::wrap_range_attrs` assumes of a table claiming
/// `Syntax::inline_attrs`: an ANONYMOUS inline container carrying
/// `claim_attrs`, printed through `render_block` as the fragment root,
/// reparses to an inline container, anonymous or named `span`, carrying them.
pub fn inline_attrs(entry: &Entry, cfg: &ParseConfig, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let mut b = Builder::new();
    let text = str_leaf(&mut b, "text");
    let span = b.add_container(Kind::Container(crate::ast::Container::with_form(b"", Form::InlineText)), &[text]);
    b.set_attrs(span, claim_attrs());
    let printed = print_with(entry, table_for(entry, cfg), &b, span, r, "attributed span")?;
    let parsed = (entry.parse)(cfg, &printed)
        .map_err(|e| r.broke(entry, &e, format!("{name}: inline_attrs: an attributed span's print does not reparse")))?;
    let ast = &parsed.doc.ast;
    for (i, n) in ast.nodes.iter().enumerate() {
        let Kind::Container(c) = &n.kind else { continue };
        if c.form != Some(Form::InlineText) {
            continue;
        }
        if !c.name.is_empty() && c.name != b"span" {
            continue;
        }
        let kept = has_claim_attrs(ast, i as NodeId)
            && n.first_child.is_some_and(|ch| matches!(&ast.nodes[ch as usize].kind, Kind::Str(s) if s == b"text"));
        if !kept {
            return Err(r.fail(with_printed(
                format!("{name}: inline_attrs: the span comes back without its attributes or text:\n").into_bytes(),
                &printed,
            )));
        }
        return Ok(());
    }
    Err(r.fail(with_printed(format!("{name}: inline_attrs: an attributed span does not reparse as one:\n").into_bytes(), &printed)))
}

/// What `Editor::insert_directive` assumes of a table claiming
/// `Syntax::names_leaf_containers`: a named LEAF CONTAINER carrying an
/// attribute, printed through `render_block`, reparses to a container that
/// still carries the name — as its own `name`, or as a `class` — with its
/// attributes intact. The name is `x-embed`, not `embed`, which is a VOID
/// element in HTML.
pub fn named_leaf_container(entry: &Entry, cfg: &ParseConfig, r: &mut Report) -> CheckResult {
    let name = entry.id.name();
    let mut b = Builder::new();
    let label = str_leaf(&mut b, "Contents");
    let root = b.add_container(Kind::Container(crate::ast::Container::with_form(b"x-embed", Form::BlockLeaf)), &[label]);
    b.set_attrs(root, Attrs { entries: vec![KeyVal::new(b"src", Some(b"x.html"))] });
    let printed = print_with(entry, table_for(entry, cfg), &b, root, r, "directive")?;
    let parsed = (entry.parse)(cfg, &printed)
        .map_err(|e| r.broke(entry, &e, format!("{name}: names_leaf_containers: a directive's print does not reparse")))?;
    let ast = &parsed.doc.ast;
    for (i, n) in ast.nodes.iter().enumerate() {
        let Kind::Container(c) = &n.kind else { continue };
        let attrs = ast.attrs_of(i as NodeId);
        let named = c.name == b"x-embed" || attrs.get(b"class").is_some_and(|class| contains(class, b"x-embed"));
        if !named {
            continue;
        }
        if attrs.get(b"src") != Some(b"x.html") {
            return Err(r.fail(with_printed(
                format!("{name}: names_leaf_containers: the directive comes back without its attributes:\n").into_bytes(),
                &printed,
            )));
        }
        return Ok(());
    }
    Err(r.fail(with_printed(
        format!("{name}: names_leaf_containers: a named leaf container does not come back named:\n").into_bytes(),
        &printed,
    )))
}

// ── Moving a block, and every gesture everywhere ────────────────────────────

/// Where `Editor::move_block` puts the block in a `MoveCase`, named by the
/// text of the block it lands beside — or the document's two ends.
#[derive(Clone, Copy)]
enum MoveTo {
    After(&'static str),
    Before(&'static str),
    DocStart,
    DocEnd,
}

/// One move over a tree every authorable format can spell: the document as
/// built, the block to move (by its text), where it goes, and the document
/// that should result. Both trees are printed through the format's own
/// serializer, so no case carries a per-format string.
struct MoveCase {
    name: &'static str,
    start: fn(&mut Builder) -> NodeId,
    expected: fn(&mut Builder) -> NodeId,
    block: &'static str,
    to: MoveTo,
    /// Both documents without their final line end.
    unterminated: bool,
}

fn item_of(b: &mut Builder, blocks: &[NodeId]) -> NodeId {
    b.add_container(Kind::ListItem, blocks)
}

fn list_of(b: &mut Builder, tight: bool, items: &[NodeId]) -> NodeId {
    b.add_container(Kind::BulletList { tight }, items)
}

fn quote_of(b: &mut Builder, texts: &[&str]) -> NodeId {
    let paras: Vec<NodeId> = texts.iter().map(|t| para_of(b, t)).collect();
    b.add_container(Kind::BlockQuote, &paras)
}

fn doc_of(b: &mut Builder, blocks: &[NodeId]) -> NodeId {
    b.add_container(Kind::Doc, blocks)
}

const MOVE_CASES: [MoveCase; 7] = [
    MoveCase {
        name: "out of a quote, to the top level",
        start: |b| {
            let q = quote_of(b, &["a", "y"]);
            let p = para_of(b, "b");
            doc_of(b, &[q, p])
        },
        expected: |b| {
            let q = quote_of(b, &["a"]);
            let p = para_of(b, "b");
            let y = para_of(b, "y");
            doc_of(b, &[q, p, y])
        },
        block: "y",
        to: MoveTo::DocEnd,
        unterminated: false,
    },
    MoveCase {
        name: "into a quote",
        start: |b| {
            let q = quote_of(b, &["a"]);
            let y = para_of(b, "y");
            doc_of(b, &[q, y])
        },
        expected: |b| {
            let q = quote_of(b, &["a", "y"]);
            doc_of(b, &[q])
        },
        block: "y",
        to: MoveTo::After("a"),
        unterminated: false,
    },
    MoveCase {
        name: "into a list item's tail",
        start: |b| {
            let x = para_of(b, "x");
            let i = item_of(b, &[x]);
            let l = list_of(b, true, &[i]);
            let y = para_of(b, "y");
            doc_of(b, &[l, y])
        },
        expected: |b| {
            let x = para_of(b, "x");
            let y = para_of(b, "y");
            let i = item_of(b, &[x, y]);
            let l = list_of(b, false, &[i]);
            doc_of(b, &[l])
        },
        block: "y",
        to: MoveTo::After("x"),
        unterminated: false,
    },
    MoveCase {
        name: "between two top-level paragraphs",
        start: |b| {
            let a = para_of(b, "a");
            let bb = para_of(b, "b");
            let y = para_of(b, "y");
            doc_of(b, &[a, bb, y])
        },
        expected: |b| {
            let a = para_of(b, "a");
            let y = para_of(b, "y");
            let bb = para_of(b, "b");
            doc_of(b, &[a, y, bb])
        },
        block: "y",
        to: MoveTo::Before("b"),
        unterminated: false,
    },
    // The three boundaries that read as a place the block already is, or as
    // inside a container it is not: each moves the block out.
    MoveCase {
        name: "past its own end, out of the quote it closes",
        start: |b| {
            let q = quote_of(b, &["a", "y"]);
            let p = para_of(b, "b");
            doc_of(b, &[q, p])
        },
        expected: |b| {
            let q = quote_of(b, &["a"]);
            let y = para_of(b, "y");
            let p = para_of(b, "b");
            doc_of(b, &[q, y, p])
        },
        block: "y",
        to: MoveTo::After("y"),
        unterminated: false,
    },
    MoveCase {
        name: "above a quote that opens the document",
        start: |b| {
            let q = quote_of(b, &["a"]);
            let y = para_of(b, "y");
            doc_of(b, &[q, y])
        },
        expected: |b| {
            let q = quote_of(b, &["a"]);
            let y = para_of(b, "y");
            doc_of(b, &[y, q])
        },
        block: "y",
        to: MoveTo::DocStart,
        unterminated: false,
    },
    MoveCase {
        name: "to the unterminated end, behind a trailing list",
        start: |b| {
            let y = para_of(b, "y");
            let a = para_of(b, "a");
            let ia = item_of(b, &[a]);
            let bb = para_of(b, "b");
            let ib = item_of(b, &[bb]);
            let l = list_of(b, true, &[ia, ib]);
            doc_of(b, &[y, l])
        },
        expected: |b| {
            let a = para_of(b, "a");
            let ia = item_of(b, &[a]);
            let bb = para_of(b, "b");
            let ib = item_of(b, &[bb]);
            let l = list_of(b, true, &[ia, ib]);
            let y = para_of(b, "y");
            doc_of(b, &[l, y])
        },
        block: "y",
        to: MoveTo::DocEnd,
        unterminated: true,
    },
];

/// `build` printed as `entry`'s own syntax — the canonical spelling of a
/// tree, which is what a move must leave behind.
fn print_tree(entry: &Entry, build: fn(&mut Builder) -> NodeId, r: &mut Report) -> Result<Vec<u8>, Broken> {
    let mut b = Builder::new();
    let root = build(&mut b);
    let view = b.view(root);
    let Some(serialize) = &entry.serialize_from_ast else {
        return Err(r.fail(format!(
            "{}: moveBlock: an authorable format prints from a tree, and this one does not",
            entry.id.name()
        )));
    };
    serialize(&view).map_err(|e| r.broke(entry, &e, format!("{}: moveBlock: a tree does not print", entry.id.name())))
}

/// The span of the `str` reading `text` in `doc`.
fn text_span(doc: &Document, text: &str) -> Option<Span> {
    doc.ast
        .nodes
        .iter()
        .position(|n| matches!(&n.kind, Kind::Str(t) if t == text.as_bytes()))
        .map(|i| doc.span(i as NodeId))
}

fn trim_end_lf(s: &[u8]) -> &[u8] {
    trim_end_newlines(s)
}

/// What `Editor::move_block` assumes of every format whose table offers it:
/// over each of `MOVE_CASES`, the start tree printed as the format's own
/// syntax, the block moved by offset, comes out as the format's own print of
/// the expected tree — byte for byte.
pub fn move_block(entry: &Entry, r: &mut Report) -> CheckResult {
    if !editor::supports(entry.syntax, Gesture::MoveBlock) {
        return Ok(());
    }
    let name = entry.id.name();
    let config = ParseConfig::default();
    for c in &MOVE_CASES {
        let start_print = print_tree(entry, c.start, r)?;
        let expected_print = print_tree(entry, c.expected, r)?;
        let start = if c.unterminated { trim_end_lf(&start_print) } else { &start_print[..] };
        let expected = if c.unterminated { trim_end_lf(&expected_print) } else { &expected_print[..] };
        let mut e = entry
            .editor(start, config, entry.syntax)
            .map_err(|err| r.broke(entry, &err.name, format!("{name}: moveBlock {}: no editor opens over the start", c.name)))?;
        let missing = |r: &mut Report| {
            r.fail(with_printed(format!("{name}: moveBlock {}: the start does not hold its text:\n", c.name).into_bytes(), start))
        };
        let Some(from) = text_span(e.doc(), c.block).map(|s| s.start) else { return Err(missing(r)) };
        let to = match c.to {
            MoveTo::After(t) => match text_span(e.doc(), t) {
                Some(s) => s.end,
                None => return Err(missing(r)),
            },
            MoveTo::Before(t) => match text_span(e.doc(), t) {
                Some(s) => s.start,
                None => return Err(missing(r)),
            },
            MoveTo::DocStart => 0,
            MoveTo::DocEnd => start.len(),
        };
        if let Err(err) = e.move_block(from, to) {
            return Err(r.broke(
                entry,
                err.name(),
                with_printed(format!("{name}: moveBlock {}: from {from} to {to} is refused over:\n", c.name).into_bytes(), start),
            ));
        }
        if expected != e.source_bytes() {
            let mut m = format!("{name}: moveBlock {}: from {from} to {to} over\n", c.name).into_bytes();
            m.extend_from_slice(start);
            m.extend_from_slice(b"\n--- gave ---\n");
            m.extend_from_slice(e.source_bytes());
            m.extend_from_slice(b"\n--- not ---\n");
            m.extend_from_slice(expected);
            return Err(r.fail(m));
        }
    }
    Ok(())
}

// ── Every gesture, everywhere ───────────────────────────────────────────────
//
// The checks above hold a format to one fragment per gesture family. This one
// holds it to every gesture `supports` answers yes for, at every place in
// every document it can reach: the format's samples, and a richer document
// printed in the format's own syntax. Each run either refuses cleanly,
// leaving the source as it was and with some reason other than
// "unsupported", or succeeds and
//
//   * leaves a document whose tree is a fresh parse of its source;
//   * changes nothing outside the bytes it wrote;
//   * has the shape the gesture promised.

/// The richer document, as a tree every authorable format can spell; a table
/// and a task list join it where `table` spells them.
fn build_rich(b: &mut Builder, table: &Syntax) -> NodeId {
    let mut blocks = Vec::new();
    let t = str_leaf(b, "Title here");
    blocks.push(b.add_container(Kind::Heading { level: 1 }, &[t]));
    blocks.push(para_of(b, "alpha beta gamma"));
    blocks.push(quote_of(b, &["quoted words", "more quoted"]));
    let one = para_of(b, "one item");
    let i1 = item_of(b, &[one]);
    let two = para_of(b, "two item");
    let i2 = item_of(b, &[two]);
    blocks.push(list_of(b, true, &[i1, i2]));
    let f = para_of(b, "first step");
    let s1 = item_of(b, &[f]);
    let s = para_of(b, "second step");
    let s2 = item_of(b, &[s]);
    blocks.push(b.add_container(Kind::OrderedList { numbering: ListNumbering::Decimal, tight: true, start: None }, &[s1, s2]));
    blocks.push(b.add_leaf(Kind::CodeBlock { lang: Some(b"zig".to_vec()), text: b"const x = 1;\n".to_vec() }));
    if table.task_marker.is_some() {
        let d = para_of(b, "done task");
        let t1 = b.add_container(Kind::TaskListItem { checked: true }, &[d]);
        let o = para_of(b, "open task");
        let t2 = b.add_container(Kind::TaskListItem { checked: false }, &[o]);
        blocks.push(b.add_container(Kind::TaskList { tight: true }, &[t1, t2]));
    }
    if table.table_spelling.is_some() {
        let cell = |bb: &mut Builder, head: bool, text: &str| {
            let s = str_leaf(bb, text);
            bb.add_container(Kind::Cell(crate::ast::Cell::new(head, Alignment::Default)), &[s])
        };
        let ha = cell(b, true, "ha");
        let hb = cell(b, true, "hb");
        let r0 = b.add_container(Kind::Row { head: true }, &[ha, hb]);
        let c1 = cell(b, false, "c1");
        let c2 = cell(b, false, "c2");
        let r1 = b.add_container(Kind::Row { head: false }, &[c1, c2]);
        let c3 = cell(b, false, "c3");
        let c4 = cell(b, false, "c4");
        let r2 = b.add_container(Kind::Row { head: false }, &[c3, c4]);
        blocks.push(b.add_container(Kind::Table, &[r0, r1, r2]));
    }
    blocks.push(para_of(b, "closing words here"));
    doc_of(b, &blocks)
}

/// Every gesture `entry`'s table supports, run at every place it applies in
/// every document the format reaches.
pub fn gestures(entry: &Entry, r: &mut Report) -> CheckResult {
    if !entry.syntax.authorable() {
        return Ok(());
    }
    for (i, source) in entry.samples.iter().enumerate() {
        gestures_over(entry, source, &format!("sample {i}"), r)?;
    }
    let Some(serialize) = &entry.serialize_from_ast else { return Ok(()) };
    let mut b = Builder::new();
    let root = build_rich(&mut b, entry.syntax);
    let view = b.view(root);
    let rich = serialize(&view)
        .map_err(|e| r.broke(entry, &e, format!("{}: gestures: the richer document does not print", entry.id.name())))?;
    gestures_over(entry, &rich, "the richer document", r)?;
    if r.found != 0 {
        return Err(r.fail(format!("{}: gestures: {} broken promises, logged", entry.id.name(), r.found)));
    }
    Ok(())
}

/// A leaf block, and the chain of containers it sits in.
#[derive(Clone)]
struct Leaf {
    id: NodeId,
    span: Span,
    /// Ancestors, innermost first, without sections.
    chain: Vec<NodeId>,
}

const LEAF_CAP: usize = 512;
const CHAIN_CAP: usize = 16;

fn is_leaf_block(k: &Kind) -> bool {
    matches!(
        k,
        Kind::Para | Kind::Heading { .. } | Kind::CodeBlock { .. } | Kind::RawBlock { .. } | Kind::ThematicBreak | Kind::Table | Kind::Metadata { .. }
    )
}

/// The document's leaf blocks in order, each with its containers. Sections
/// are left out of the chain.
fn leaves(doc: &Document) -> Vec<Leaf> {
    let mut out = Vec::new();
    let mut chain = Vec::new();
    walk_leaves(doc, doc.ast.root, &mut chain, &mut out);
    out
}

fn walk_leaves(doc: &Document, parent: NodeId, chain: &mut Vec<NodeId>, out: &mut Vec<Leaf>) {
    let ast = &doc.ast;
    let mut c = ast.nodes[parent as usize].first_child;
    while let Some(id) = c {
        let k = &ast.nodes[id as usize].kind;
        if is_leaf_block(k) {
            if out.len() == LEAF_CAP {
                return;
            }
            out.push(Leaf { id, span: doc.span(id), chain: chain.iter().rev().copied().collect() });
        } else if matches!(k, Kind::Section | Kind::Doc) {
            walk_leaves(doc, id, chain, out);
        } else if chain.len() < CHAIN_CAP {
            chain.push(id);
            walk_leaves(doc, id, chain, out);
            chain.pop();
        }
        c = ast.nodes[id as usize].next_sibling;
    }
}

/// A node's kind for the container comparison: a bullet list whose items
/// carry boxes is a task list.
fn list_kind(k: &Kind) -> Tag {
    match k {
        Kind::TaskList { .. } => Tag::BulletList,
        Kind::TaskListItem { .. } => Tag::ListItem,
        k => k.tag(),
    }
}

fn leaf_eql(a: &Ast, x: &Leaf, b: &Ast, y: &Leaf) -> bool {
    if x.chain.len() != y.chain.len() {
        return false;
    }
    if !subtree_eql(a, x.id, b, y.id) {
        return false;
    }
    // By kind, not payload.
    x.chain.iter().zip(&y.chain).all(|(p, q)| list_kind(a.kind(*p)) == list_kind(b.kind(*q)))
}

fn subtree_eql(a: &Ast, ai: NodeId, b: &Ast, bi: NodeId) -> bool {
    if a.kind(ai) != b.kind(bi) {
        return false;
    }
    if a.attrs_of(ai).entries != b.attrs_of(bi).entries {
        return false;
    }
    let mut ca = a.nodes[ai as usize].first_child;
    let mut cb = b.nodes[bi as usize].first_child;
    while let (Some(x), Some(y)) = (ca, cb) {
        if !subtree_eql(a, x, b, y) {
            return false;
        }
        ca = a.nodes[x as usize].next_sibling;
        cb = b.nodes[y as usize].next_sibling;
    }
    ca.is_none() && cb.is_none()
}

fn count(ast: &Ast, pred: fn(&Kind) -> bool) -> usize {
    ast.nodes.iter().filter(|n| pred(&n.kind)).count()
}

fn is_rule(k: &Kind) -> bool {
    matches!(k, Kind::ThematicBreak)
}
fn is_para(k: &Kind) -> bool {
    matches!(k, Kind::Para)
}
fn is_table(k: &Kind) -> bool {
    matches!(k, Kind::Table)
}
fn is_markup(k: &Kind) -> bool {
    matches!(k, Kind::InlineMark(_) | Kind::TextLeaf { .. } | Kind::Link(_) | Kind::Image(_) | Kind::RawInline { .. })
}
fn is_verbatimish(k: &Kind) -> bool {
    matches!(
        k,
        Kind::CodeBlock { .. }
            | Kind::RawBlock { .. }
            | Kind::RawInline { .. }
            | Kind::TextLeaf { .. }
            | Kind::Link(_)
            | Kind::Image(_)
            | Kind::Table
            | Kind::Cell(_)
            | Kind::Heading { .. }
    )
}
fn is_cell(k: &Kind) -> bool {
    matches!(k, Kind::Cell(_))
}
fn is_markup_node(k: &Kind) -> bool {
    matches!(k, Kind::InlineMark(_) | Kind::Container(_))
}
fn is_container_block(k: &Kind) -> bool {
    matches!(
        k,
        Kind::BlockQuote | Kind::BulletList { .. } | Kind::OrderedList { .. } | Kind::TaskList { .. } | Kind::ListItem | Kind::TaskListItem { .. }
    )
}
fn is_para_or_item(k: &Kind) -> bool {
    matches!(k, Kind::Para | Kind::ListItem)
}
fn is_link(k: &Kind) -> bool {
    matches!(k, Kind::Link(_))
}
fn is_image(k: &Kind) -> bool {
    matches!(k, Kind::Image(_))
}
fn is_heading(k: &Kind) -> bool {
    matches!(k, Kind::Heading { .. })
}

/// Whether `id` sits inside a node for which `pred` holds. Like Zig's, it
/// sees the first 512 nodes.
fn within(ast: &Ast, id: NodeId, pred: fn(&Kind) -> bool) -> bool {
    let n = ast.nodes.len().min(512);
    let mut parents: Vec<Option<NodeId>> = vec![None; n];
    for (i, node) in ast.nodes[..n].iter().enumerate() {
        let mut c = node.first_child;
        while let Some(ch) = c {
            if (ch as usize) < n {
                parents[ch as usize] = Some(i as NodeId);
            }
            c = ast.nodes[ch as usize].next_sibling;
        }
    }
    let mut at = if (id as usize) < n { parents[id as usize] } else { None };
    while let Some(p) = at {
        if pred(ast.kind(p)) {
            return true;
        }
        at = parents[p as usize];
    }
    false
}

fn trim_set<'s>(s: &'s [u8], set: &[u8]) -> &'s [u8] {
    let start = s.iter().position(|c| !set.contains(c)).unwrap_or(s.len());
    let end = s.iter().rposition(|c| !set.contains(c)).map_or(start, |e| e + 1);
    &s[start..end.max(start)]
}

/// The node of `ast` matching `pred` whose text is `text`, if any.
fn find_text(ast: &Ast, pred: fn(&Kind) -> bool, text: &[u8]) -> Option<NodeId> {
    (0..ast.nodes.len() as NodeId)
        .find(|&i| pred(ast.kind(i)) && trim_set(&select::text_of(ast, i), b" \n") == trim_set(text, b" \n"))
}

/// The word sites, and the block sites.
fn sites_of(doc: &Document) -> (Vec<Span>, Vec<NodeId>) {
    let ast = &doc.ast;
    let mut words = Vec::new();
    let mut blocks = Vec::new();
    for (i, n) in ast.nodes.iter().enumerate() {
        let id = i as NodeId;
        match &n.kind {
            Kind::Str(text) => {
                if within(ast, id, is_verbatimish) || within(ast, id, is_markup_node) {
                    continue;
                }
                let sp = doc.span(id);
                if sp.end - sp.start != text.len() {
                    continue; // escaped or entity-spelled: not a plain run
                }
                let mut start = 0;
                while start < text.len() && text[start] == b' ' {
                    start += 1;
                }
                let mut end = start;
                while end < text.len() && text[end].is_ascii_alphanumeric() {
                    end += 1;
                }
                if end > start {
                    words.push(Span::new(sp.start + start, sp.start + end));
                }
            }
            Kind::Para | Kind::Heading { .. } | Kind::CodeBlock { .. } => blocks.push(id),
            _ => {}
        }
    }
    (words, blocks)
}

fn is_descendant(ast: &Ast, ancestor: NodeId, id: NodeId) -> bool {
    let mut c = ast.nodes[ancestor as usize].first_child;
    while let Some(ch) = c {
        if ch == id || is_descendant(ast, ch, id) {
            return true;
        }
        c = ast.nodes[ch as usize].next_sibling;
    }
    false
}

/// The first text offset inside `id` — where a caret in that block sits.
fn caret_in(doc: &Document, id: NodeId) -> usize {
    let ast = &doc.ast;
    for i in id as usize..ast.nodes.len() {
        if matches!(ast.nodes[i].kind, Kind::Str(_)) && (i == id as usize || is_descendant(ast, id, i as NodeId)) {
            return doc.span(i as NodeId).start;
        }
    }
    doc.content_span(id).unwrap_or_else(|| doc.span(id)).start
}

fn within_tag(ast: &Ast, id: NodeId, tag: Tag) -> bool {
    (0..ast.nodes.len() as NodeId).any(|i| ast.kind(i).tag() == tag && is_descendant(ast, i, id))
}

/// The node `ref` names whose text is `text`.
fn find_ref(ast: &Ast, r: &KindRef, text: &[u8]) -> Option<NodeId> {
    (0..ast.nodes.len() as NodeId).find(|&i| {
        let matches = match (r, ast.kind(i)) {
            (KindRef::Mark(m), Kind::InlineMark(x)) => m == x,
            (KindRef::TextLeaf(l), Kind::TextLeaf { kind, .. }) => l == kind,
            _ => false,
        };
        matches && select::text_of(ast, i) == text
    })
}

fn count_non_space(s: &[u8]) -> usize {
    s.iter().filter(|c| !matches!(c, b' ' | b'\t' | b'\n' | b'\r' | 0x0B | 0x0C)).count()
}

fn holds_soft_break(ast: &Ast, id: NodeId) -> bool {
    let mut c = ast.nodes[id as usize].first_child;
    while let Some(ch) = c {
        if matches!(ast.kind(ch), Kind::SoftBreak) || holds_soft_break(ast, ch) {
            return true;
        }
        c = ast.nodes[ch as usize].next_sibling;
    }
    false
}

/// Whether `id` sits in a task item whose box is ticked.
fn ticked_item(ast: &Ast, id: NodeId) -> bool {
    (0..ast.nodes.len() as NodeId).any(|i| matches!(ast.kind(i), Kind::TaskListItem { checked: true }) && is_descendant(ast, i, id))
}

/// Whether `body` is `text` with some of its spaces line ends.
fn lines_are(body: &[u8], text: &[u8]) -> bool {
    body.len() == text.len() && body.iter().zip(text).all(|(x, y)| x == y || (*x == b'\n' && *y == b' '))
}

/// The formula both math probes write.
const PROBE_FORMULA: &[u8] = b"\\alpha+1";

fn holds_formula(ast: &Ast, kind: TextLeafKind) -> bool {
    ast.nodes.iter().any(|n| matches!(&n.kind, Kind::TextLeaf { kind: k, text } if *k == kind && text == PROBE_FORMULA))
}

/// A block a gesture runs at, with what the probes read about it.
struct BlockSite {
    id: NodeId,
    kind: Kind,
    /// The first text offset inside it.
    caret: usize,
    span: Span,
    text: Vec<u8>,
}

struct Trial<'t> {
    entry: &'t Entry,
    source: &'t [u8],
    label: &'t str,
    before: &'t Document,
    r: &'t mut Report,
    config: ParseConfig,
    /// The block a block probe aims at, whose own change is the point.
    target: Option<NodeId>,
    /// The probe joins its target into the block before it.
    joins: bool,
}

type ER = Result<(), editor::Error>;

impl Trial<'_> {
    fn name(&self) -> String {
        self.entry.id.name().to_string()
    }

    /// One probe's outcome: a broken promise is the check's answer, unless
    /// the report is collecting every one.
    fn keep(&mut self, result: CheckResult) -> CheckResult {
        if result.is_err() {
            let msg = self.r.buf.clone();
            match &mut self.r.log {
                None => return Err(Broken),
                Some(log) => {
                    log.extend_from_slice(&msg);
                    log.push(0);
                    self.r.found += 1;
                }
            }
        }
        Ok(())
    }

    fn open(&mut self) -> Result<Editor, Broken> {
        let name = self.name();
        let label = self.label;
        self.entry
            .editor(self.source, self.config, self.entry.syntax)
            .map_err(|err| self.r.broke(self.entry, &err.name, format!("{name}: gestures: no editor opens over {label}")))
    }

    /// A refusal: the source is as it was, and the reason is not one
    /// `supports` promised away.
    fn refused(&mut self, e: &Editor, what: &str, err: editor::Error) -> CheckResult {
        let (name, label) = (self.name(), self.label);
        if err == editor::Error::UnsupportedFormat {
            return Err(self.r.fail(with_printed(
                format!("{name}: {what} over {label}: supports() answers yes and the gesture answers unsupported:\n").into_bytes(),
                self.source,
            )));
        }
        if self.source != e.source_bytes() {
            return Err(self.r.fail(with_printed(
                format!("{name}: {what} over {label}: refused ({}) and changed the source anyway:\n", err.name()).into_bytes(),
                e.source_bytes(),
            )));
        }
        Ok(())
    }

    fn broken(&mut self, e: &Editor, what: &str, why: &str) -> Broken {
        let mut m = format!("{}: {what} over {}: {why}", self.name(), self.label).into_bytes();
        m.extend_from_slice(b"\n--- before ---\n");
        m.extend_from_slice(self.source);
        m.extend_from_slice(b"\n--- after ---\n");
        m.extend_from_slice(e.source_bytes());
        self.r.fail(m)
    }

    /// What every success owes: a tree that is a parse of its source, and
    /// every top-level block outside the changed bytes as it was.
    fn succeeded(&mut self, e: &Editor, what: &str) -> CheckResult {
        let after = e.source_bytes();
        let fresh = match (self.entry.parse_to_ast)(&self.config, after) {
            Ok(d) => d,
            Err(err) => {
                let m = format!("{}: {what} over {}: the result does not parse", self.name(), self.label);
                return Err(self.r.broke(self.entry, &err, m));
            }
        };
        if !fresh.ast.eql(e.ast_view()) {
            return Err(self.broken(e, what, "the editor's tree is not a parse of its source"));
        }
        if let Err(problem) = node_table::check_columns(e.doc()) {
            return Err(self.broken(e, what, &format!("the columns are refused: {} {}", problem.field, problem.what)));
        }

        // The changed region, as the bytes say it.
        let old = self.source;
        let mut p = 0;
        while p < old.len() && p < after.len() && old[p] == after[p] {
            p += 1;
        }
        let mut s = 0;
        while s < old.len() - p && s < after.len() - p && old[old.len() - 1 - s] == after[after.len() - 1 - s] {
            s += 1;
        }
        let old_ast = &self.before.ast;
        let new_ast = e.ast_view();
        let ol = leaves(self.before);
        let nl = leaves(e.doc());
        // Before: leaf blocks ending inside the common prefix, paired by
        // position.
        let mut i = 0;
        while i < ol.len() && ol[i].span.end < p {
            let skip = self.target == Some(ol[i].id)
                || (self.joins && i + 1 < ol.len() && self.target.is_some() && Some(ol[i + 1].id) == self.target);
            if !skip && (i >= nl.len() || !leaf_eql(old_ast, &ol[i], new_ast, &nl[i])) {
                let sp = ol[i].span;
                let why = format!(
                    "the block before every byte it wrote, \"{}\", reads differently",
                    lossy(&self.before.source[sp.start..sp.end])
                );
                return Err(self.broken(e, what, &why));
            }
            i += 1;
        }
        // After: leaf blocks starting strictly inside the common suffix,
        // paired from the end.
        let mut j = 0;
        while j < ol.len() && ol[ol.len() - 1 - j].span.start > old.len() - s {
            let ob = &ol[ol.len() - 1 - j];
            if self.target != Some(ob.id) && (j >= nl.len() || !leaf_eql(old_ast, ob, new_ast, &nl[nl.len() - 1 - j])) {
                let why = format!(
                    "the block after every byte it wrote, \"{}\", reads differently",
                    lossy(&self.before.source[ob.span.start..ob.span.end])
                );
                return Err(self.broken(e, what, &why));
            }
            j += 1;
        }
        Ok(())
    }

    /// Run one gesture: a refusal checked as one, a success held to what
    /// every success owes, then `then` for the gesture's own promise.
    fn run(
        &mut self,
        what: &str,
        gesture: impl FnOnce(&mut Editor) -> ER,
        then: impl FnOnce(&mut Self, &mut Editor) -> CheckResult,
    ) -> CheckResult {
        let mut e = self.open()?;
        if let Err(err) = gesture(&mut e) {
            return self.refused(&e, what, err);
        }
        self.succeeded(&e, what)?;
        then(self, &mut e)
    }
}

fn gestures_over(entry: &Entry, source: &[u8], label: &str, r: &mut Report) -> CheckResult {
    let table = entry.syntax;
    let config = ParseConfig::default();
    let before = match (entry.parse_to_ast)(&config, source) {
        Ok(d) => d,
        Err(err) => return Err(r.broke(entry, &err, format!("{}: gestures: {label} does not parse", entry.id.name()))),
    };
    let mut t = Trial { entry, source, label, before: &before, r, config, target: None, joins: false };
    let (words, blocks) = sites_of(&before);
    let ast = &before.ast;
    let sup = |g: Gesture| editor::supports(table, g);

    for &w in &words {
        for k in InlineKind::ALL {
            if !sup(Gesture::ToggleInline(k)) {
                continue;
            }
            let res = probe_inline(&mut t, w, k, true);
            t.keep(res)?;
            let res = probe_inline(&mut t, w, k, false);
            t.keep(res)?;
        }
        if sup(Gesture::InsertLink) {
            let res = probe_link(&mut t, w);
            t.keep(res)?;
        }
        if sup(Gesture::InsertImage) {
            let res = probe_image(&mut t, w);
            t.keep(res)?;
        }
        if sup(Gesture::InsertFootnote) {
            let res = probe_footnote(&mut t, w);
            t.keep(res)?;
        }
        if sup(Gesture::InsertInlineMath) {
            let res = probe_inline_math(&mut t, w);
            t.keep(res)?;
        }
        if sup(Gesture::InsertLiteral) {
            let res = probe_literal(&mut t, w);
            t.keep(res)?;
        }
        if sup(Gesture::SplitBlock) && w.end - w.start >= 2 {
            let res = probe_split(&mut t, w);
            t.keep(res)?;
        }
        if sup(Gesture::WrapRangeAttrs) {
            let res = probe_wrap_attrs(&mut t, w);
            t.keep(res)?;
        }
    }

    for &id in &blocks {
        let b = BlockSite {
            id,
            kind: ast.kind(id).clone(),
            caret: caret_in(&before, id),
            span: before.span(id),
            text: select::text_of(ast, id),
        };
        let in_cell = within(ast, id, is_cell);
        t.target = Some(id);
        if in_cell {
            if b.kind == Kind::Para {
                table_gestures(&mut t, b.caret)?;
            }
            t.target = None;
            continue;
        }
        if b.kind == Kind::Para {
            if sup(Gesture::SetBlock) {
                let res = probe_set_block(&mut t, &b);
                t.keep(res)?;
            }
            for k in ContainerKind::ALL {
                if sup(Gesture::ToggleBlockContainer(k)) {
                    let res = probe_container(&mut t, &b, k);
                    t.keep(res)?;
                }
            }
            if sup(Gesture::ToggleCodeBlock) {
                let res = probe_code_block(&mut t, &b);
                t.keep(res)?;
            }
            let in_item = within_tag(ast, id, Tag::ListItem) || within_tag(ast, id, Tag::TaskListItem);
            if sup(Gesture::ToggleTaskItem) && in_item {
                let res = probe_task_item(&mut t, &b);
                t.keep(res)?;
            }
            if sup(Gesture::ToggleTaskChecked) && within_tag(ast, id, Tag::TaskListItem) {
                let res = probe_task_checked(&mut t, &b);
                t.keep(res)?;
            }
        }
        if matches!(b.kind, Kind::CodeBlock { .. }) && sup(Gesture::SetCodeLanguage) {
            let res = probe_code_language(&mut t, &b);
            t.keep(res)?;
        }
        let block_probes: [(bool, fn(&mut Trial, &BlockSite) -> CheckResult); 8] = [
            (sup(Gesture::InsertThematicBreak), probe_rule),
            (sup(Gesture::JoinBlocks) && b.span.start > 0, probe_join),
            (sup(Gesture::InsertTable), probe_insert_table),
            (sup(Gesture::InsertDirective), probe_directive),
            (sup(Gesture::InsertDisplayMath), probe_display_math),
            (sup(Gesture::SetBlockAttrs), probe_block_attrs),
            (sup(Gesture::ToggleLineBlock) && b.kind == Kind::Para, probe_line_block),
            (sup(Gesture::MoveBlock), probe_move),
        ];
        for (on, p) in block_probes {
            if on {
                let res = p(&mut t, &b);
                t.keep(res)?;
            }
        }
        t.target = None;
    }

    if sup(Gesture::RenumberOrderedLists) {
        for (i, n) in ast.nodes.iter().enumerate() {
            if !matches!(n.kind, Kind::OrderedList { .. }) {
                continue;
            }
            let caret = caret_in(&before, i as NodeId);
            let res = t.run("renumber_ordered_lists", |e| e.renumber_ordered_lists(caret), |_, _| Ok(()));
            t.keep(res)?;
        }
    }

    // Cells whose text is a direct `str` rather than a paragraph.
    for n in &ast.nodes {
        if !matches!(n.kind, Kind::Cell(_)) {
            continue;
        }
        let Some(first) = n.first_child else { continue };
        if !matches!(ast.kind(first), Kind::Str(_)) {
            continue;
        }
        table_gestures(&mut t, before.span(first).start)?;
    }
    Ok(())
}

fn word_of<'a>(t: &Trial<'a>, w: Span) -> &'a [u8] {
    &t.source[w.start..w.end]
}

fn probe_inline(t: &mut Trial, w: Span, k: InlineKind, toggle: bool) -> CheckResult {
    let word = word_of(t, w);
    let what = if toggle { "toggle_inline" } else { "wrap_range" };
    t.run(
        what,
        |e| if toggle { e.toggle_inline(w, k) } else { e.wrap_range(w, k) },
        |t, e| {
            let Some(got) = find_ref(e.ast_view(), &k.kind_ref(), word) else {
                return Err(t.broken(e, what, &format!("no {} over \"{}\" came back", k.name(), lossy(word))));
            };
            if !toggle {
                return Ok(());
            }
            let inner = e.doc().content_span(got).unwrap_or_else(|| e.doc().span(got));
            if let Err(err) = e.toggle_inline(inner, k) {
                return Err(t.broken(e, what, &format!("toggling {} off again is refused: {}", k.name(), err.name())));
            }
            if t.source != e.source_bytes() {
                return Err(t.broken(e, what, &format!("toggling {} over \"{}\" twice does not give the source back", k.name(), lossy(word))));
            }
            Ok(())
        },
    )
}

fn probe_link(t: &mut Trial, w: Span) -> CheckResult {
    let word = word_of(t, w);
    t.run(
        "insert_link",
        |e| e.insert_link(w, b"https://x.dev/a"),
        |t, e| {
            let Some(id) = find_text(e.ast_view(), is_link, word) else {
                return Err(t.broken(e, "insert_link", &format!("no link over \"{}\" came back", lossy(word))));
            };
            let ok = matches!(e.ast_view().kind(id), Kind::Link(l) if l.destination.as_deref() == Some(b"https://x.dev/a"));
            if !ok {
                return Err(t.broken(e, "insert_link", &format!("the link over \"{}\" lost its destination", lossy(word))));
            }
            Ok(())
        },
    )
}

fn probe_image(t: &mut Trial, w: Span) -> CheckResult {
    let word = word_of(t, w);
    t.run(
        "insert_image",
        |e| e.insert_image(w, b"cat.png"),
        |t, e| match find_text(e.ast_view(), is_image, word) {
            Some(_) => Ok(()),
            None => Err(t.broken(e, "insert_image", &format!("no image over \"{}\" came back", lossy(word)))),
        },
    )
}

fn probe_footnote(t: &mut Trial, w: Span) -> CheckResult {
    t.run(
        "insert_footnote",
        |e| e.insert_footnote(w.end, b"n1"),
        |t, e| {
            if e.ast_view().nodes.iter().any(|n| matches!(&n.kind, Kind::Footnote { label } if label == b"n1")) {
                return Ok(());
            }
            Err(t.broken(e, "insert_footnote", "no definition labelled n1 came back"))
        },
    )
}

fn probe_inline_math(t: &mut Trial, w: Span) -> CheckResult {
    t.run(
        "insert_inline_math",
        |e| e.insert_inline_math(w.end, PROBE_FORMULA),
        |t, e| {
            if holds_formula(e.ast_view(), TextLeafKind::InlineMath) {
                return Ok(());
            }
            Err(t.broken(e, "insert_inline_math", &format!("no inline formula holding {} came back", lossy(PROBE_FORMULA))))
        },
    )
}

fn probe_display_math(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run(
        "insert_display_math",
        |e| e.insert_display_math(caret, PROBE_FORMULA),
        |t, e| {
            if holds_formula(e.ast_view(), TextLeafKind::DisplayMath) {
                return Ok(());
            }
            Err(t.broken(e, "insert_display_math", &format!("no display formula holding {} came back", lossy(PROBE_FORMULA))))
        },
    )
}

fn probe_literal(t: &mut Trial, w: Span) -> CheckResult {
    t.run(
        "insert_literal",
        |e| e.insert_literal(w.end, LITERAL_SPECIALS.as_bytes()),
        |t, e| {
            let ast = &t.before.ast;
            if count(e.ast_view(), is_markup) != count(ast, is_markup) {
                return Err(t.broken(e, "insert_literal", "a literal minted markup"));
            }
            let was = select::text_of(ast, ast.root);
            let now = select::text_of(e.ast_view(), e.ast_view().root);
            let lit = LITERAL_SPECIALS.as_bytes();
            let at = now.windows(lit.len()).position(|x| x == lit);
            let kept = match at {
                Some(at) => {
                    now.len() == was.len() + lit.len()
                        && was.len() >= at
                        && now[..at] == was[..at]
                        && now[at + lit.len()..] == was[at..]
                }
                None => false,
            };
            if !kept {
                return Err(t.broken(e, "insert_literal", "the text is not the old text with the literal in it"));
            }
            Ok(())
        },
    )
}

fn probe_split(t: &mut Trial, w: Span) -> CheckResult {
    let mid = w.start + 1;
    t.run(
        "split_block",
        |e| e.split_block(mid),
        |t, e| {
            let ast = &t.before.ast;
            let was = select::text_of(ast, ast.root);
            let now = select::text_of(e.ast_view(), e.ast_view().root);
            if count_non_space(&was) != count_non_space(&now) {
                return Err(t.broken(e, "split_block", "the text changed"));
            }
            if !editor::supports(t.entry.syntax, Gesture::JoinBlocks) {
                return Ok(());
            }
            // The second half starts where the first ended, past the separator.
            let half = &t.source[mid..w.end];
            let after = e.source_bytes();
            let second = if mid <= after.len() {
                after[mid..].windows(half.len()).position(|x| x == half).map(|i| i + mid)
            } else {
                None
            };
            let Some(second) = second else {
                return Err(t.broken(e, "split_block", "the second half is not in the source"));
            };
            if let Err(err) = e.join_blocks(second) {
                return Err(t.broken(e, "split_block", &format!("joining the halves back is refused: {}", err.name())));
            }
            t.succeeded(e, "split_block, then join_blocks")?;
            if count(e.ast_view(), is_para) != count(ast, is_para) {
                return Err(t.broken(e, "split_block", "joining the halves back does not give one block"));
            }
            let joined = select::text_of(e.ast_view(), e.ast_view().root);
            if count_non_space(&joined) != count_non_space(&was) {
                return Err(t.broken(e, "split_block", "joining the halves back changed the text"));
            }
            Ok(())
        },
    )
}

fn probe_wrap_attrs(t: &mut Trial, w: Span) -> CheckResult {
    t.run("wrap_range_attrs", |e| e.wrap_range_attrs(w, &claim_attrs().entries), |_, _| Ok(()))
}

fn probe_set_block(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let table = t.entry.syntax;
    // A paragraph of several lines, which a marker heading of one line
    // holds with its soft breaks joined.
    let lines = holds_soft_break(&t.before.ast, b.id);
    let folds = lines && table.heading_marker.is_some() && !table.heading_continues;
    let what = "set_block heading";
    let mut e = t.open()?;
    if let Err(err) = e.set_block(b.caret, BlockKind::Heading, 2) {
        if lines && table.heading_continues && err == editor::Error::NotEditable {
            return Err(t.broken(&e, what, "the table claims heading_continues, and a paragraph of several lines is refused"));
        }
        return t.refused(&e, what, err);
    }
    t.succeeded(&e, what)?;
    let ast = &t.before.ast;
    let Some(h) = find_text(e.ast_view(), is_heading, &b.text) else {
        return Err(t.broken(&e, what, &format!("no heading over \"{}\" came back", lossy(&b.text))));
    };
    if !matches!(e.ast_view().kind(h), Kind::Heading { level: 2 }) {
        return Err(t.broken(&e, what, "the heading is not level 2"));
    }
    if count(e.ast_view(), is_container_block) != count(ast, is_container_block) {
        return Err(t.broken(&e, what, "a container around the block was lost"));
    }
    let caret = caret_in(e.doc(), h);
    if let Err(err) = e.set_block(caret, BlockKind::Paragraph, 0) {
        return Err(t.broken(&e, what, &format!("setting it back to a paragraph is refused: {}", err.name())));
    }
    if folds {
        if count(e.ast_view(), is_para) != count(ast, is_para) || find_text(e.ast_view(), is_para, &b.text).is_none() {
            return Err(t.broken(&e, what, "setting it back to a paragraph does not give the text back"));
        }
    } else if !e.ast_view().eql(ast) {
        return Err(t.broken(&e, what, "setting it back to a paragraph does not give the tree back"));
    }
    Ok(())
}

fn probe_container(t: &mut Trial, b: &BlockSite, k: ContainerKind) -> CheckResult {
    let span = b.span;
    t.run(
        "toggle_block_container",
        |e| e.toggle_block_container(span, k),
        |t, e| {
            let what = "toggle_block_container";
            let found = find_text(e.ast_view(), is_para, &b.text).or_else(|| find_text(e.ast_view(), is_para_or_item, &b.text));
            let Some(p) = found else {
                return Err(t.broken(e, what, &format!("the paragraph \"{}\" is gone", lossy(&b.text))));
            };
            // A bullet list whose items carry boxes is a task list.
            let inside = within_tag(e.ast_view(), p, k.tag())
                || (k == ContainerKind::BulletList && within_tag(e.ast_view(), p, Tag::TaskList));
            if !inside && !within_tag(&t.before.ast, b.id, k.tag()) {
                return Err(t.broken(e, what, &format!("\"{}\" is not inside a {}", lossy(&b.text), k.name())));
            }
            Ok(())
        },
    )
}

fn probe_code_block(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let span = b.span;
    t.run(
        "toggle_code_block",
        |e| e.toggle_code_block(span, Some(b"zig")),
        |t, e| {
            let bytes = trim_set(&t.source[b.span.start..b.span.end], b"\n");
            for n in &e.ast_view().nodes {
                if let Kind::CodeBlock { lang: Some(lang), text } = &n.kind {
                    if lang == b"zig" {
                        let body = trim_set(text, b"\n");
                        if body == bytes || body == &b.text[..] || lines_are(body, &b.text) {
                            return Ok(());
                        }
                    }
                }
            }
            Err(t.broken(e, "toggle_code_block", "no zig code block holding the paragraph came back"))
        },
    )
}

fn probe_code_language(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let start = b.span.start;
    let Kind::CodeBlock { text: was, .. } = &b.kind else { return Ok(()) };
    t.run(
        "set_code_language",
        |e| e.set_code_language(start, Some(b"py")),
        |t, e| {
            let ok = e
                .ast_view()
                .nodes
                .iter()
                .any(|n| matches!(&n.kind, Kind::CodeBlock { lang: Some(l), text } if l == b"py" && text == was));
            if ok { Ok(()) } else { Err(t.broken(e, "set_code_language", "no py code block with the same text came back")) }
        },
    )
}

fn probe_task_item(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run(
        "toggle_task_item",
        |e| e.toggle_task_item(caret),
        |t, e| {
            let what = "toggle_task_item";
            let Some(moved) = e.source_bytes().windows(b.text.len().max(1)).position(|x| x == &b.text[..]) else {
                return Err(t.broken(e, what, "the item's text is gone"));
            };
            if let Err(err) = e.toggle_task_item(moved) {
                return Err(t.broken(e, what, &format!("toggling it back is refused: {}", err.name())));
            }
            // A box is added unchecked, so a ticked one comes back unticked.
            if ticked_item(&t.before.ast, b.id) {
                return Ok(());
            }
            if !e.ast_view().eql(&t.before.ast) {
                return Err(t.broken(e, what, "toggling twice does not give the tree back"));
            }
            Ok(())
        },
    )
}

fn probe_task_checked(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run(
        "toggle_task_checked",
        |e| e.toggle_task_checked(caret),
        |t, e| {
            let what = "toggle_task_checked";
            if let Err(err) = e.toggle_task_checked(caret) {
                return Err(t.broken(e, what, &format!("toggling it back is refused: {}", err.name())));
            }
            if t.source != e.source_bytes() {
                return Err(t.broken(e, what, "toggling twice does not give the source back"));
            }
            Ok(())
        },
    )
}

fn probe_rule(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run(
        "insert_thematic_break",
        |e| e.insert_thematic_break(caret),
        |t, e| {
            let ast = &t.before.ast;
            if count(e.ast_view(), is_rule) != count(ast, is_rule) + 1 {
                return Err(t.broken(e, "insert_thematic_break", "there is not one rule more"));
            }
            if count(e.ast_view(), is_para) != count(ast, is_para) {
                return Err(t.broken(e, "insert_thematic_break", "a paragraph became something else"));
            }
            Ok(())
        },
    )
}

fn probe_join(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let mut e = t.open()?;
    if let Err(err) = e.join_blocks(b.caret) {
        return t.refused(&e, "join_blocks", err);
    }
    t.joins = true;
    let res = t.succeeded(&e, "join_blocks");
    t.joins = false;
    res?;
    let ast = &t.before.ast;
    let was = select::text_of(ast, ast.root);
    let now = select::text_of(e.ast_view(), e.ast_view().root);
    if count_non_space(&was) != count_non_space(&now) {
        return Err(t.broken(&e, "join_blocks", "the text changed"));
    }
    Ok(())
}

fn probe_insert_table(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run(
        "insert_table",
        |e| e.insert_table(caret, 2, 2),
        |t, e| {
            let ast = &t.before.ast;
            if count(e.ast_view(), is_table) != count(ast, is_table) + 1 {
                return Err(t.broken(e, "insert_table", "there is not one table more"));
            }
            if count(e.ast_view(), is_para) != count(ast, is_para) {
                return Err(t.broken(e, "insert_table", "a paragraph became something else"));
            }
            Ok(())
        },
    )
}

fn probe_directive(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run(
        "insert_directive",
        |e| e.insert_directive(caret, b"x-embed", None, &[KeyVal::new(b"src", Some(b"x.html"))]),
        |_, _| Ok(()),
    )
}

fn probe_block_attrs(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run("set_block_attrs", |e| e.set_block_attrs(caret, &claim_attrs().entries), |_, _| Ok(()))
}

/// On and off again: a paragraph made a verse.
fn probe_line_block(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    t.run("toggle_line_block", |e| e.toggle_line_block(caret, caret), |_, _| Ok(()))
}

fn probe_move(t: &mut Trial, b: &BlockSite) -> CheckResult {
    let caret = b.caret;
    let end = t.source.len();
    t.run(
        "move_block",
        |e| e.move_block(caret, end),
        |t, e| {
            let ast = &t.before.ast;
            let was = select::text_of(ast, ast.root);
            let now = select::text_of(e.ast_view(), e.ast_view().root);
            if count_non_space(&was) != count_non_space(&now) {
                return Err(t.broken(e, "move_block", "text was lost or gained"));
            }
            Ok(())
        },
    )
}

/// A table's shape: its rows, and its first row's cells.
fn shape_of(ast: &Ast, id: NodeId) -> (usize, usize) {
    let mut rows = 0;
    let mut cols = 0;
    let mut row = ast.nodes[id as usize].first_child;
    while let Some(rid) = row {
        if matches!(ast.kind(rid), Kind::Row { .. }) {
            if rows == 0 {
                let mut c = ast.nodes[rid as usize].first_child;
                while let Some(cid) = c {
                    cols += 1;
                    c = ast.nodes[cid as usize].next_sibling;
                }
            }
            rows += 1;
        }
        row = ast.nodes[rid as usize].next_sibling;
    }
    (rows, cols)
}

/// The table holding `offset`.
fn table_at(doc: &Document, offset: usize) -> Option<NodeId> {
    (0..doc.ast.nodes.len() as NodeId).find(|&i| {
        let sp = doc.span(i);
        matches!(doc.ast.kind(i), Kind::Table) && offset >= sp.start && offset <= sp.end
    })
}

fn table_starting_at(doc: &Document, start: usize) -> Option<NodeId> {
    (0..doc.ast.nodes.len() as NodeId).find(|&i| matches!(doc.ast.kind(i), Kind::Table) && doc.span(i).start == start)
}

fn table_gestures(t: &mut Trial, caret: usize) -> CheckResult {
    if !editor::supports(t.entry.syntax, Gesture::TableInsertRow) {
        return Ok(());
    }
    for n in 0..8 {
        let res = probe_table(t, caret, n);
        t.keep(res)?;
    }
    Ok(())
}

fn probe_table(t: &mut Trial, caret: usize, n: usize) -> CheckResult {
    let Some(id) = table_at(t.before, caret) else { return Ok(()) };
    let shape = shape_of(&t.before.ast, id);
    let start = t.before.span(id).start;
    const NAMES: [&str; 8] = [
        "table_insert_row",
        "table_delete_row",
        "table_insert_column",
        "table_delete_column",
        "table_set_alignment",
        "table_move_row",
        "table_move_column",
        "insert_line_break",
    ];
    const DROWS: [isize; 8] = [1, -1, 0, 0, 0, 0, 0, 0];
    const DCOLS: [isize; 8] = [0, 0, 1, -1, 0, 0, 0, 0];
    let what = NAMES[n];
    if n == 7 && !editor::supports(t.entry.syntax, Gesture::InsertLineBreak) {
        return Ok(());
    }
    // The table is the target: its own bytes are the ones a table edit
    // rewrites.
    let was_target = t.target;
    t.target = Some(id);
    let res = t.run(
        what,
        |e| match n {
            0 => e.table_insert_row(caret, true),
            1 => e.table_delete_row(caret),
            2 => e.table_insert_column(caret, true),
            3 => e.table_delete_column(caret),
            4 => e.table_set_alignment(caret, Alignment::Center),
            5 => e.table_move_row(caret, true),
            6 => e.table_move_column(caret, true),
            _ => e.insert_line_break(caret),
        },
        |t, e| {
            let Some(now) = table_starting_at(e.doc(), start) else {
                return Err(t.broken(e, what, "the table is gone"));
            };
            let after = shape_of(e.ast_view(), now);
            if after.0 as isize != shape.0 as isize + DROWS[n] || after.1 as isize != shape.1 as isize + DCOLS[n] {
                return Err(t.broken(e, what, &format!("the table is {}x{}, from {}x{}", after.0, after.1, shape.0, shape.1)));
            }
            Ok(())
        },
    );
    t.target = was_target;
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_compiled_row_keeps_the_non_editor_promises() {
        for fmt in crate::test_languages::all() {
            let entry = Entry::of(fmt);
            let mut r = Report::default();
            samples(&entry, &mut r).unwrap_or_else(|_| panic!("{}", r.message()));
            renderers(&entry, &mut r).unwrap_or_else(|_| panic!("{}", r.message()));
        }
    }

    #[test]
    fn every_compiled_row_moves_a_block_as_typed() {
        for fmt in crate::test_languages::all() {
            let entry = Entry::of(fmt);
            let mut r = Report::default();
            move_block(&entry, &mut r).unwrap_or_else(|_| panic!("{}", r.message()));
        }
    }

    /// Broken promises the gesture check knows of (the Zig harness's
    /// `known_findings`). A finding here is tolerated; one that stops being
    /// found fails the test, so the list only shrinks.
    const KNOWN_FINDINGS: [&str; 0] = [];

    #[test]
    fn every_gesture_everywhere_over_every_authorable_format() {
        let mut log = Vec::new();
        for fmt in crate::test_languages::all() {
            let entry = Entry::of(fmt);
            let mut report = Report::logging();
            let _ = gestures(&entry, &mut report);
            log.extend_from_slice(report.log.as_deref().unwrap());
        }
        let mut seen = [false; KNOWN_FINDINGS.len()];
        let mut unknown = Vec::new();
        for m in log.split(|&c| c == 0) {
            if m.is_empty() {
                continue;
            }
            match KNOWN_FINDINGS.iter().position(|k| m.starts_with(k.as_bytes())) {
                Some(i) => seen[i] = true,
                None => unknown.push(String::from_utf8_lossy(m).into_owned()),
            }
        }
        for (k, s) in KNOWN_FINDINGS.iter().zip(seen) {
            if !s {
                unknown.push(format!("no longer found — remove it: {k}"));
            }
        }
        assert!(unknown.is_empty(), "{}", unknown.join("\n\n"));
    }

    #[test]
    fn the_traps_recorded_in_syntaxs_doc_comments_are_caught() {
        // HTML with a pipe-table spelling: its parser lowers `<table>` to the
        // same nodes a pipe table produces, so a table edit splices pipes
        // over the elements — which reparse as a paragraph.
        {
            let mut table = *format::syntax_for(crate::test_languages::html());
            table.table_spelling = format::syntax_for(crate::test_languages::markdown()).table_spelling;
            let mut entry = Entry::of(crate::test_languages::html());
            entry.syntax = Box::leak(Box::new(table));
            entry.syntax_for = None;
            let mut report = Report::logging();
            assert_eq!(gestures(&entry, &mut report), Err(Broken));
            let log = String::from_utf8_lossy(report.log.as_deref().unwrap()).into_owned();
            assert!(log.contains("insert_table over sample 1: there is not one table more"), "{log}");
            assert!(log.contains("table_insert_row over the richer document: the table is gone"), "{log}");
        }
        // A rule spelled in bytes the parser does not read back as one.
        {
            let mut table = *format::syntax_for(crate::test_languages::djot());
            table.thematic_break = Some(b"~ ~ ~");
            let mut entry = Entry::of(crate::test_languages::djot());
            entry.syntax = Box::leak(Box::new(table));
            let mut report = Report::default();
            assert_eq!(gestures(&entry, &mut report), Err(Broken));
            assert!(report.message().contains("insert_thematic_break"), "{}", report.message());
        }
    }

    #[test]
    fn a_render_block_that_prints_nothing_is_caught() {
        fn nothing(_: &Syntax, _: &Ast, _: NodeId, _: &mut Vec<u8>) -> Result<(), crate::Error> {
            Ok(())
        }
        let mut table = *format::syntax_for(crate::test_languages::djot());
        table.render_block = Some(nothing);
        let leaked: &'static Syntax = Box::leak(Box::new(table));
        let mut entry = Entry::of(crate::test_languages::djot());
        entry.syntax = leaked;
        let mut r = Report::default();
        assert_eq!(render_block(&entry, &mut r), Err(Broken));
        assert!(r.message().contains("djot: renderBlock: a level-2 heading"), "{}", r.message());
    }
}
