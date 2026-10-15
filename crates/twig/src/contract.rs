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
use crate::languages;
use crate::languages::markdown::options::Extensions;
use crate::runtime;
use crate::syntax::{BlockAttrs, Syntax};

/// A broken promise; the [`Report`] says which.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Broken;

pub type CheckResult = Result<(), Broken>;

type ParseBox<'a> = Box<dyn Fn(&ParseConfig, &[u8]) -> Result<ParsedDoc, String> + 'a>;
type ParseAstBox<'a> = Box<dyn Fn(&ParseConfig, &[u8]) -> Result<Document, String> + 'a>;
type CanonicalBox<'a> = Box<dyn Fn(&ParsedDoc) -> Result<Vec<u8>, String> + 'a>;
type FromAstBox<'a> = Box<dyn Fn(&Ast) -> Result<Vec<u8>, String> + 'a>;
type SyntaxForBox<'a> = Box<dyn Fn(&ParseConfig) -> &'static Syntax + 'a>;

/// One row as the checks see it (Zig's `format.Entry`, with its target's
/// `serializeFromAst` beside it). Every failing call answers with a reason:
/// the error's name for a compiled row, the language's own for a runtime one.
pub struct Entry<'a> {
    pub id: Format,
    pub samples: Vec<Vec<u8>>,
    pub parse: ParseBox<'a>,
    pub parse_to_ast: ParseAstBox<'a>,
    pub serialize_canonical: Option<CanonicalBox<'a>>,
    /// The row's target's printer from a bare tree.
    pub serialize_from_ast: Option<FromAstBox<'a>>,
    pub syntax: &'static Syntax,
    pub syntax_for: Option<SyntaxForBox<'a>>,
}

impl Entry<'static> {
    /// A compiled row, as the format registry has it — or a registered
    /// runtime row.
    pub fn of(fmt: Format) -> Entry<'static> {
        if let Format::Runtime(c) = fmt {
            if let Some(e) = runtime::contract_entry(c) {
                return e;
            }
        }
        let samples: Vec<Vec<u8>> = match fmt {
            Format::Djot => languages::djot::SAMPLES.iter().map(|s| s.to_vec()).collect(),
            Format::Markdown => languages::markdown::SAMPLES.iter().map(|s| s.to_vec()).collect(),
            Format::Commonmark => languages::markdown::COMMONMARK_SAMPLES.iter().map(|s| s.to_vec()).collect(),
            Format::Gfm => languages::markdown::GFM_SAMPLES.iter().map(|s| s.to_vec()).collect(),
            Format::Xml => languages::xml::SAMPLES.iter().map(|s| s.as_bytes().to_vec()).collect(),
            Format::Svg => languages::xml::SVG_SAMPLES.iter().map(|s| s.as_bytes().to_vec()).collect(),
            Format::Html => languages::html::SAMPLES.iter().map(|s| s.to_vec()).collect(),
            Format::Asciidoc => languages::asciidoc::SAMPLES.iter().map(|s| s.to_vec()).collect(),
            Format::Runtime(_) => Vec::new(),
        };
        let target = format::target_for(fmt);
        Entry {
            id: fmt,
            samples,
            parse: Box::new(move |cfg, src| format::parse(fmt, cfg, src).map_err(|e| e.name())),
            parse_to_ast: Box::new(move |cfg, src| format::parse_to_ast(fmt, cfg, src).map_err(|e| e.name())),
            serialize_canonical: Some(Box::new(|doc| format::serialize_canonical(doc).map_err(|e| e.name()))),
            serialize_from_ast: if format::target_serializes_from_ast(target) {
                Some(Box::new(move |ast| format::serialize_from_ast(target, ast).map_err(|e| e.name())))
            } else {
                None
            },
            syntax: format::syntax_for(fmt),
            syntax_for: Some(Box::new(move |cfg| format::syntax_for_config(fmt, cfg))),
        }
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
        // TODO(port): the editor half — an Editor over the sample reads the
        // parse's tree, and a zero-length splice is the identity — waits for
        // crate::ast::editor.
    }
    Ok(())
}

fn columns(doc: &Document, r: &mut Report, name: &str, what: &str, index: usize) -> CheckResult {
    node_table::check_columns(doc)
        .map_err(|problem| r.fail(format!("{name}: {what} {index}: the columns are refused: {}", problem.render())))
}

// ── Renderers and claims ────────────────────────────────────────────────────

/// The parse configs a per-table claim can be made under. A claim is a claim
/// about a TABLE, and Markdown has one table per option combination, so every
/// table the row can produce for these is asked, and parsed with the very
/// config it came from. Every other row answers the same table for all four,
/// and is checked once.
fn claim_configs() -> [ParseConfig; 4] {
    let ext = |directives, html_elements| ParseConfig {
        markdown: Extensions { directives, html_elements, ..Default::default() },
        features: 0,
    };
    [ext(false, false), ext(true, false), ext(false, true), ext(true, true)]
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
    for cfg in claim_configs() {
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
pub fn render_text(_entry: &Entry, _r: &mut Report) -> CheckResult {
    // TODO(port): waits for crate::ast::editor (Editor::init + insert_literal).
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
pub fn node_attrs(_entry: &Entry, _cfg: &ParseConfig, _r: &mut Report) -> CheckResult {
    // TODO(port): waits for crate::ast::editor (Editor::set_node_attrs).
    Ok(())
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

/// What `Editor::move_block` assumes of every format whose table offers it.
pub fn move_block(_entry: &Entry, _r: &mut Report) -> CheckResult {
    // TODO(port): waits for crate::ast::editor.
    Ok(())
}

/// Every gesture `entry`'s table supports, run at every place it applies in
/// every document the format reaches.
pub fn gestures(_entry: &Entry, _r: &mut Report) -> CheckResult {
    // TODO(port): waits for crate::ast::editor.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_compiled_row_keeps_the_non_editor_promises() {
        for fmt in Format::COMPILED {
            let entry = Entry::of(fmt);
            let mut r = Report::default();
            samples(&entry, &mut r).unwrap_or_else(|_| panic!("{}", r.message()));
            renderers(&entry, &mut r).unwrap_or_else(|_| panic!("{}", r.message()));
        }
    }

    #[test]
    fn a_render_block_that_prints_nothing_is_caught() {
        fn nothing(_: &Syntax, _: &Ast, _: NodeId, _: &mut Vec<u8>) -> Result<(), crate::Error> {
            Ok(())
        }
        let mut table = *format::syntax_for(Format::Djot);
        table.render_block = Some(nothing);
        let leaked: &'static Syntax = Box::leak(Box::new(table));
        let mut entry = Entry::of(Format::Djot);
        entry.syntax = leaked;
        let mut r = Report::default();
        assert_eq!(render_block(&entry, &mut r), Err(Broken));
        assert!(r.message().contains("djot: renderBlock: a level-2 heading"), "{}", r.message());
    }
}
