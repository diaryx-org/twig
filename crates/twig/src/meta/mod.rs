//! The config a document carries, read and edited through fig — behind the
//! default `fig` feature.
//!
//! twig finds a document's metadata — a `metadata` node: the frontmatter or
//! endmatter block the Markdown parser reads, or the
//! `<script type="application/<lang>">` data island the HTML parser reads —
//! and fig edits what is inside it. The block's body is handed to
//! [`fig::Editor`] as a config document of its own, and whatever the editor
//! leaves in its source is spliced back between the block's fences. Every
//! byte outside the body, the fences included, is the host's as it was.
//!
//! This is what fig's `Embed` did before 6.0, which took embedding out of fig
//! (fig's `docs/migrating-to-6.md`, "Embedding has left fig"). It was the
//! `twig-meta` crate; it is core's now, so that every parse can honour a
//! document's own `twig` settings ([`settings`]): `Document::parse`,
//! `Editor::new` and the CLI read a document as its frontmatter asks. See
//! `docs/proposals/fig-in-twig.md`.
//!
//! ```
//! use twig::meta::{Embed, Where};
//!
//! let host = b"---\ntitle: Hi # kept\n---\n# Body\n";
//! let parsed = twig::meta::parse_host(host, twig_markdown::format()).unwrap();
//! let block = twig::meta::find(&parsed.doc, Where::Front).unwrap();
//! let mut e = Embed::open(host, &block).unwrap();
//! e.editor_mut().set_value(&["title".into()], "Hello").unwrap();
//! assert_eq!(e.render().unwrap(), b"---\ntitle: Hello # kept\n---\n# Body\n");
//! ```

use std::fmt;
use std::ops::Range;
use std::sync::Once;

use crate::ast::Kind;
use crate::document::Document;
use crate::format::{self as reg, Format, ParseConfig, ParsedDoc};

pub mod settings;
pub use settings::Settings;

/// Which of a document's metadata blocks: the one it opens with, or the
/// trailing one.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Where {
    Front,
    End,
}

/// A located metadata block: where its fences and body sit in the host.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Block {
    /// The `metadata` node in the tree it was found in.
    pub node: crate::ast::NodeId,
    pub at: Where,
    /// The language tag as written on the fence (`yaml` for a bare `---`).
    pub lang: String,
    /// The whole block, both fence lines included.
    pub span: Range<usize>,
    /// The bytes between the fences: every body line, each with its line
    /// ending. Empty, at the start of the closing fence, for a block with no
    /// body. This is what fig edits, and where its result goes back.
    pub body: Range<usize>,
}

/// Why a block could not be read or edited.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// The document has no metadata block where one was asked for.
    NoMetadata,
    /// The block's language is not one fig has registered.
    UnsupportedLanguage(String),
    /// twig refused: a format it does not know, a feature its row does not
    /// declare, or a host it could not parse.
    Twig(crate::Error),
    /// fig refused: a body that does not parse, or an edit it cannot make.
    Fig(fig::Error),
    /// An HTML data island's edited body holds `</script` or `<!--`. Raw text
    /// has no escape: the first would end the island early and let what
    /// follows run as a page script, the second would stop `</script>` from
    /// closing it. The HTML printer refuses the same bodies.
    UnsafeIslandBody,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NoMetadata => f.write_str("the document has no metadata block there"),
            Error::UnsupportedLanguage(lang) => {
                write!(f, "fig has no language registered as `{lang}`")
            }
            Error::Twig(e) => write!(f, "twig: {e}"),
            Error::Fig(e) => write!(f, "fig: {e}"),
            Error::UnsafeIslandBody => {
                f.write_str("the edited metadata holds </script or <!--, unsafe in an HTML <script> island")
            }
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Twig(e) => Some(e),
            Error::Fig(e) => Some(e),
            _ => None,
        }
    }
}

impl From<crate::Error> for Error {
    fn from(e: crate::Error) -> Self {
        Error::Twig(e)
    }
}

impl From<fig::Error> for Error {
    fn from(e: fig::Error) -> Self {
        Error::Fig(e)
    }
}

/// The document's metadata block at `at`, or `None` when it has none.
/// `doc` is a parsed document ([`parse_host`]). Markdown's parser reads
/// frontmatter and endmatter as `metadata` nodes; HTML's reads a
/// `<script type="application/<lang>">` data island as one, wherever in the
/// page it sits (typically `<head>`), and the first such island is the
/// document's front block. An island is never endmatter.
pub fn find(doc: &Document, at: Where) -> Option<Block> {
    let nodes = &doc.ast.nodes;
    let first = nodes.get(doc.ast.root as usize)?.first_child?;
    let id = match at {
        Where::Front => first,
        Where::End => {
            let mut last = first;
            while let Some(n) = nodes[last as usize].next_sibling {
                last = n;
            }
            last
        }
    };
    if let Kind::Metadata { lang, .. } = &nodes[id as usize].kind {
        let span = doc.span(id);
        let span = span.start..span.end;
        if is_island(doc, &span) {
            return (at == Where::Front).then(|| island(doc, id, lang, span));
        }
        // Frontmatter is the document's first block and endmatter its last; a
        // document holding only one block of metadata has it as both, and it
        // is the one at the position the source puts it.
        let leads = span.start == 0;
        if leads != (at == Where::Front) {
            return None;
        }
        return Some(Block {
            node: id,
            at,
            lang: String::from_utf8_lossy(lang).into_owned(),
            body: body_of(&doc.source, span.clone()),
            span,
        });
    }
    if at == Where::End {
        return None;
    }
    // Not leading the document: an island may still sit deeper, in `<head>`.
    let id = first_island(doc, first)?;
    let Kind::Metadata { lang, .. } = &nodes[id as usize].kind else {
        return None;
    };
    let span = doc.span(id);
    Some(island(doc, id, lang, span.start..span.end))
}

/// Whether the metadata node spanning `span` is an HTML data island rather
/// than a fenced block: its source opens a tag.
fn is_island(doc: &Document, span: &Range<usize>) -> bool {
    doc.source.get(span.start) == Some(&b'<')
}

/// The first data island at or after `from` in document order, descending
/// into each node's children before its next sibling.
fn first_island(doc: &Document, from: crate::ast::NodeId) -> Option<crate::ast::NodeId> {
    let nodes = &doc.ast.nodes;
    let mut next = Some(from);
    while let Some(id) = next {
        let node = &nodes[id as usize];
        if matches!(node.kind, Kind::Metadata { .. }) {
            let span = doc.span(id);
            if is_island(doc, &(span.start..span.end)) {
                return Some(id);
            }
        }
        if let Some(found) = node.first_child.and_then(|c| first_island(doc, c)) {
            return Some(found);
        }
        next = node.next_sibling;
    }
    None
}

/// The block a data island makes: its body is the content span the HTML
/// parser gives it, between the open tag's line and the close tag.
fn island(doc: &Document, id: crate::ast::NodeId, lang: &[u8], span: Range<usize>) -> Block {
    let body = doc
        .content_span(id)
        .map_or(span.end..span.end, |c| c.start..c.end);
    Block {
        node: id,
        at: Where::Front,
        lang: String::from_utf8_lossy(lang).into_owned(),
        span,
        body,
    }
}

/// The body of a fenced block spanning `span`: from past the opening fence's
/// line ending to the start of the closing fence's line.
fn body_of(host: &[u8], span: Range<usize>) -> Range<usize> {
    let block = &host[span.clone()];
    let open_end = block
        .iter()
        .position(|&b| b == b'\n')
        .map_or(span.end, |i| span.start + i + 1);
    let close_start = block
        .iter()
        .rposition(|&b| b == b'\n')
        .map_or(span.end, |i| span.start + i + 1);
    open_end..open_end.max(close_start)
}

/// Register the languages this crate brings with it, once per process. A
/// language already registered (by the program, through the same crate) is
/// found, not registered twice.
fn register_bundled() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // A refusal leaves the language unregistered, and its tag then reads
        // as `UnsupportedLanguage`, which says as much.
        let _ = fig_yaml::format();
        let _ = fig_toml::format();
        let _ = fig_json::format();
        let _ = fig_figl::format();
    });
}

/// The fig dialect a fence's language tag names, or `None` when fig has none
/// registered under it. Tags are matched case-insensitively, and the
/// spellings fig's `Embed` read before 6.0 still read: `fig` is figl, `yml`
/// is YAML.
pub fn dialect_for(lang: &str) -> Option<fig::Format> {
    register_bundled();
    let lower = lang.to_ascii_lowercase();
    let name = match lower.as_str() {
        "fig" => "figl",
        "yml" => "yaml",
        other => other,
    };
    fig::Format::by_name(name)
}


/// Parse `host` as `format` with its default extensions (frontmatter is
/// always read).
pub fn parse_host(host: &[u8], format: crate::Format) -> Result<ParsedDoc, Error> {
    parse_host_with(host, format, &[])
}

/// [`parse_host`] with `features` (the row's feature names) turned on.
pub fn parse_host_with(
    host: &[u8],
    format: crate::Format,
    features: &[&str],
) -> Result<ParsedDoc, Error> {
    let flags = format.feature_flags(features)?;
    if !format.is_registered() {
        return Err(Error::Twig(crate::Error::UnsupportedFormat));
    }
    let fmt = format;
    let cfg = reg::ParseConfig::for_features(fmt, flags);
    reg::parse(fmt, &cfg, host).map_err(|_| Error::Twig(crate::Error::ParseError))
}

/// Read the document's metadata block at `at` as a fig [`fig::Document`], or
/// `None` when it has none.
pub fn read(doc: &Document, at: Where) -> Result<Option<fig::Document>, Error> {
    let Some(block) = find(doc, at) else {
        return Ok(None);
    };
    let dialect =
        dialect_for(&block.lang).ok_or_else(|| Error::UnsupportedLanguage(block.lang.clone()))?;
    Ok(Some(fig::Document::parse(
        &doc.source[block.body],
        dialect,
    )?))
}

/// A fig [`Editor`](fig::Editor) over a document's metadata block. Edit
/// through [`editor_mut`](Embed::editor_mut); [`render`](Embed::render) gives
/// the host back with the edited body in place.
#[derive(Debug)]
pub struct Embed {
    /// The host before the body, the opening fence included.
    before: Vec<u8>,
    /// The host after the body, from the closing fence on.
    after: Vec<u8>,
    /// The body, as a config document. Its source is the body now.
    editor: fig::Editor,
    /// The dialect the body is edited as.
    dialect: fig::Format,
    lang: String,
    /// The block is an HTML `<script>` island, whose raw-text body
    /// [`render`](Embed::render) refuses to let close it early.
    island: bool,
}

impl Embed {
    /// Open the block `block` locates in `host`.
    pub fn open(host: &[u8], block: &Block) -> Result<Embed, Error> {
        let dialect = dialect_for(&block.lang)
            .ok_or_else(|| Error::UnsupportedLanguage(block.lang.clone()))?;
        Embed::open_parts(
            &host[..block.body.start],
            &host[block.body.clone()],
            &host[block.body.end..],
            dialect,
            &block.lang,
            host.get(block.span.start) == Some(&b'<'),
        )
    }

    /// Open `host`'s metadata block at `at`, parsing it as `format`.
    /// [`Error::NoMetadata`] when it has none there.
    pub fn open_in(host: &[u8], format: crate::Format, at: Where) -> Result<Embed, Error> {
        let parsed = parse_host(host, format)?;
        let block = find(&parsed.doc, at).ok_or(Error::NoMetadata)?;
        Embed::open(host, &block)
    }

    /// Open `host`'s frontmatter, or — when it has none — a new block of
    /// `lang` above its first line, empty until an edit writes to it. In an
    /// HTML host (`format` named `html`) the block found or written is a
    /// `<script type="application/<lang>">` data island, since a `---` fence
    /// is text to a browser.
    pub fn open_or_init(host: &[u8], format: crate::Format, lang: &str) -> Result<Embed, Error> {
        let parsed = parse_host(host, format)?;
        if let Some(block) = find(&parsed.doc, Where::Front) {
            return Embed::open(host, &block);
        }
        let dialect =
            dialect_for(lang).ok_or_else(|| Error::UnsupportedLanguage(lang.to_string()))?;
        if format.name() == "html" {
            // Inside `<head>`, or past a leading doctype: a block above
            // `<!doctype html>` would put the page in quirks mode.
            let at = island_home(&parsed.doc);
            let mut before = host[..at].to_vec();
            if before.last().is_some_and(|&b| b != b'\n') {
                before.push(b'\n');
            }
            before.extend_from_slice(format!("<script type=\"application/{lang}\">\n").as_bytes());
            let mut after = b"</script>\n".to_vec();
            after.extend_from_slice(&host[at..]);
            return Embed::open_parts(&before, b"", &after, dialect, lang, true);
        }
        let before = format!("{}\n", fence_for(lang));
        let mut after = format!("{}\n", closer_for(lang)).into_bytes();
        after.extend_from_slice(host);
        Embed::open_parts(before.as_bytes(), b"", &after, dialect, lang, false)
    }

    fn open_parts(
        before: &[u8],
        content: &[u8],
        after: &[u8],
        dialect: fig::Format,
        lang: &str,
        island: bool,
    ) -> Result<Embed, Error> {
        Ok(Embed {
            before: before.to_vec(),
            after: after.to_vec(),
            editor: fig::Editor::open(content, dialect)?,
            dialect,
            lang: lang.to_string(),
            island,
        })
    }

    /// The editor over the body.
    pub fn editor(&self) -> &fig::Editor {
        &self.editor
    }

    /// The editor over the body, to edit it through.
    pub fn editor_mut(&mut self) -> &mut fig::Editor {
        &mut self.editor
    }

    /// The fig dialect the body is edited as.
    pub fn dialect(&self) -> fig::Format {
        self.dialect
    }

    /// The fence's language tag, as written (`yaml` for a bare `---`).
    pub fn lang(&self) -> &str {
        &self.lang
    }

    /// The body as the editor holds it now.
    pub fn body(&self) -> Result<&str, Error> {
        Ok(self.editor.source()?)
    }

    /// The host with the edited body between its fences. A body that does
    /// not end its last line is given a line ending, so the closing fence
    /// stays on a line of its own. An HTML island's body holding `</script`
    /// or `<!--` is [`Error::UnsafeIslandBody`].
    pub fn render(&self) -> Result<Vec<u8>, Error> {
        let body = self.body()?.as_bytes();
        if self.island && (contains_ignore_case(body, b"</script") || contains_ignore_case(body, b"<!--")) {
            return Err(Error::UnsafeIslandBody);
        }
        let mut out = Vec::with_capacity(self.before.len() + body.len() + 1 + self.after.len());
        out.extend_from_slice(&self.before);
        out.extend_from_slice(body);
        if body.last().is_some_and(|&b| b != b'\n') {
            out.push(b'\n');
        }
        out.extend_from_slice(&self.after);
        Ok(out)
    }
}

/// Whether `hay` holds `needle`, ASCII case folded.
fn contains_ignore_case(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w.eq_ignore_ascii_case(needle))
}

/// Where a new island goes in an HTML page: past the line of its `<head>`
/// open tag when it has one, else past the line of a leading doctype, else
/// at its first byte.
fn island_home(doc: &Document) -> usize {
    let nodes = &doc.ast.nodes;
    let past_line = |at: usize| match doc.source.get(at..) {
        Some(rest) if rest.starts_with(b"\r\n") => at + 2,
        Some(rest) if rest.starts_with(b"\n") => at + 1,
        _ => at,
    };
    let mut stack: Vec<crate::ast::NodeId> = nodes[doc.ast.root as usize].first_child.into_iter().collect();
    while let Some(id) = stack.pop() {
        let node = &nodes[id as usize];
        if let Kind::Container(c) = &node.kind {
            if c.name.eq_ignore_ascii_case(b"head") {
                if let Some(content) = doc.content_span(id) {
                    return past_line(content.start);
                }
            }
        }
        if let Some(n) = node.next_sibling {
            stack.push(n);
        }
        if let Some(c) = node.first_child {
            stack.push(c);
        }
    }
    let mut doctype_end = 0;
    let mut next = nodes[doc.ast.root as usize].first_child;
    while let Some(id) = next {
        let node = &nodes[id as usize];
        match &node.kind {
            Kind::MarkupLeaf { kind: crate::ast::MarkupLeafKind::Doctype, .. } => {
                doctype_end = past_line(doc.span(id).end);
                break;
            }
            Kind::MarkupLeaf { .. } => next = node.next_sibling,
            _ => break,
        }
    }
    doctype_end
}

/// The opening fence a new frontmatter block of `lang` is written with: a
/// bare `---` for YAML, the convention twig reads as YAML, a bare `+++` for
/// TOML, and `---<lang>` for any other.
fn fence_for(lang: &str) -> String {
    if lang.eq_ignore_ascii_case("yaml") {
        "---".to_string()
    } else if lang.eq_ignore_ascii_case("toml") {
        "+++".to_string()
    } else {
        format!("---{lang}")
    }
}

fn closer_for(lang: &str) -> &'static str {
    if lang.eq_ignore_ascii_case("toml") {
        "+++"
    } else {
        "---"
    }
}

/// How `host` asks to be read: the format and features its frontmatter's
/// `twig` settings ([`Settings`]) lay over the caller's, and the names among
/// them twig did not act on. A host with no frontmatter, or frontmatter in a
/// language fig has not registered, or frontmatter that does not parse, is
/// read as asked.
#[derive(Debug)]
pub struct Resolved {
    pub format: crate::Format,
    /// Every feature to turn on: the caller's, then the document's, each
    /// once, all of them declared by `format`'s row.
    pub features: Vec<String>,
    /// What the document's `twig` key asked for, `ignored` included: names
    /// this twig did not act on, never an error.
    pub settings: Settings,
    /// The frontmatter, as fig read it; `None` when there was none to read.
    pub meta: Option<fig::Value>,
}

impl Resolved {
    /// The names twig did not act on; empty when nothing was ignored.
    pub fn ignored(&self) -> &[String] {
        &self.settings.ignored
    }


    /// Parse `host` as it asks to be read.
    pub fn parse(&self, host: &[u8]) -> Result<crate::Document, Error> {
        let features: Vec<&str> = self.features.iter().map(String::as_str).collect();
        Ok(crate::Document::parse_with_features(
            host,
            self.format,
            &features,
        )?)
    }
}

/// Resolve `host`'s settings (see [`Resolved`]). The frontmatter is found
/// with `format`'s own row and the caller's `features`, which every Markdown
/// row reads alike, so the settings cannot change where they themselves are.
/// A caller's feature `format` does not declare is [`crate::Error::NotFound`].
pub fn resolve(host: &[u8], format: crate::Format, features: &[&str]) -> Result<Resolved, Error> {
    let parsed = parse_host_with(host, format, features)?;
    let mut out = Resolved {
        format,
        features: dedup(features.iter().map(|s| s.to_string())),
        settings: Settings::default(),
        meta: None,
    };
    let Some(block) = find(&parsed.doc, Where::Front) else {
        return Ok(out);
    };
    let Some(dialect) = dialect_for(&block.lang) else {
        return Ok(out);
    };
    // Frontmatter that does not parse holds no settings: the document is
    // still read, as asked.
    let Ok(meta) = fig::Document::parse(&host[block.body], dialect).and_then(|d| d.to_value())
    else {
        return Ok(out);
    };
    out.settings = Settings::read(&meta, format);
    out.meta = Some(meta);
    let (format, features) = out.settings.apply(format, features);
    out.format = format;
    out.features = features;
    Ok(out)
}

fn dedup(names: impl Iterator<Item = String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for n in names {
        if !out.contains(&n) {
            out.push(n);
        }
    }
    out
}

/// The row and config `doc`'s own `twig` settings ask for, over the row
/// `format` and the caller's `cfg` it was parsed with: the dialect it names,
/// and its features laid over the caller's. `None` when it asks for nothing
/// different — no frontmatter, frontmatter fig cannot read, no `twig` key,
/// or only names this twig does not act on.
pub(crate) fn settings_override(doc: &Document, format: Format, cfg: &ParseConfig) -> Option<(Format, ParseConfig)> {
    let block = find(doc, Where::Front)?;
    let dialect = dialect_for(&block.lang)?;
    let meta = fig::Document::parse(&doc.source[block.body], dialect).and_then(|d| d.to_value()).ok()?;
    let settings = Settings::read(&meta, format);
    let to = settings.dialect.unwrap_or(format);
    let mut mask = cfg.features;
    for name in &settings.features {
        if let Some(bit) = reg::feature_bit(to, name) {
            mask |= bit;
        }
    }
    let resolved = ParseConfig::for_features(to, mask);
    (to != format || resolved != *cfg).then_some((to, resolved))
}
