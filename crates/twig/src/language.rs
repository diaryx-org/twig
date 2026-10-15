//! Languages registered at runtime: a format this library did not compile in,
//! supplied as a Rust [`Language`] and registered with [`register`]. The
//! pure-Rust counterpart of the FFI binding's `twig::language` module
//! (`bindings/rust/twig/src/language.rs`), with the same names and
//! semantics, implemented over `crate::runtime` instead of the C ABI.
//!
//! A language **reads**: its [`Language::parse`] turns source into the node
//! table — the JSON `twig convert -o table` prints for a compiled format. It
//! may **write**: [`Language::print`] turns a node table (without positions)
//! back into source. It may **author**: its [`Description::syntax`] is the
//! table an editor's gestures write with, and [`Language::render`] answers
//! the renderers that table names.
//!
//! A language may declare [`Feature`]s and [`Set`]s. Every call says which
//! row it is through and which features are on ([`Call`]).
//!
//! Registration runs the load check over the language before it exists, and
//! after that the returned [`Format`] works everywhere a compiled one does.
//!
//! [`Server`] and [`serve`] are the other end: the same language answering
//! the helper wire, which is how a Rust program becomes a helper the `twig`
//! command line spawns.

use std::fmt;
use std::io::{BufRead, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use crate::format::Format;
use crate::runtime::{self, Render};
use crate::{wire, Error};

/// What a language says about itself.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Description {
    /// A lowercase identifier no format already answers to.
    pub name: String,
    /// Dot-less and lowercase, and no format's already.
    pub extensions: Vec<String>,
    pub aliases: Vec<String>,
    /// Whether the language prints — [`Language::print`] is then called.
    pub write: bool,
    /// Whether the language authors: [`Description::syntax`] is then its
    /// table.
    pub author: bool,
    /// The table an editor writes with, as a JSON object — the shape
    /// `twig lang syntax <format>` prints. Its `renderers` name what
    /// [`Language::render`] answers.
    pub syntax: Option<String>,
    pub features: Vec<Feature>,
    pub sets: Vec<Set>,
    /// Small documents the load check holds the language to. At least one,
    /// across this and [`Description::feature_samples`], and at least one here.
    pub samples: Vec<String>,
    /// Samples that need features on to mean what they say.
    pub feature_samples: Vec<Sample>,
}

/// A switch the language's parser reads.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Feature {
    /// A lowercase identifier.
    pub name: String,
    /// Whether the language's own row has it on.
    pub default: bool,
    /// Features that come on with this one.
    pub requires: Vec<String>,
    /// A JSON object of the table's members this feature replaces while it
    /// is on — per key in `inline_delims`, `text_leaf_delims` and
    /// `container_spelling`. No two features may patch the same one.
    pub syntax: Option<String>,
}

/// A named list of features, registered as a [`Format`] of its own.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Set {
    pub name: String,
    pub extensions: Vec<String>,
    pub aliases: Vec<String>,
    pub features: Vec<String>,
}

/// A sample, and the features it needs.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Sample {
    pub text: String,
    pub features: Vec<String>,
}

impl Description {
    /// The `describe` document the library reads. `syntax` goes in as written.
    pub fn to_json(&self) -> String {
        let mut out = String::from("{\"name\":");
        json_string(&self.name, &mut out);
        for (key, list) in [("extensions", &self.extensions), ("aliases", &self.aliases)] {
            out.push_str(",\"");
            out.push_str(key);
            out.push_str("\":");
            json_strings(list, &mut out);
        }
        out.push_str(",\"caps\":{\"read\":true,\"write\":");
        out.push_str(if self.write { "true" } else { "false" });
        out.push_str(",\"author\":");
        out.push_str(if self.author { "true" } else { "false" });
        out.push('}');
        if let Some(syntax) = &self.syntax {
            out.push_str(",\"syntax\":");
            out.push_str(syntax);
        }
        out.push_str(",\"features\":[");
        for (i, f) in self.features.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"name\":");
            json_string(&f.name, &mut out);
            out.push_str(",\"default\":");
            out.push_str(if f.default { "true" } else { "false" });
            out.push_str(",\"requires\":");
            json_strings(&f.requires, &mut out);
            if let Some(syntax) = &f.syntax {
                out.push_str(",\"syntax\":");
                out.push_str(syntax);
            }
            out.push('}');
        }
        out.push_str("],\"sets\":[");
        for (i, set) in self.sets.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"name\":");
            json_string(&set.name, &mut out);
            for (key, list) in [("extensions", &set.extensions), ("aliases", &set.aliases), ("features", &set.features)] {
                out.push_str(",\"");
                out.push_str(key);
                out.push_str("\":");
                json_strings(list, &mut out);
            }
            out.push('}');
        }
        out.push_str("],\"samples\":[");
        let mut first = true;
        for text in &self.samples {
            if !first {
                out.push(',');
            }
            first = false;
            json_string(text, &mut out);
        }
        for sample in &self.feature_samples {
            if !first {
                out.push(',');
            }
            first = false;
            out.push_str("{\"text\":");
            json_string(&sample.text, &mut out);
            out.push_str(",\"features\":");
            json_strings(&sample.features, &mut out);
            out.push('}');
        }
        out.push_str("]}");
        out
    }
}

fn json_strings(list: &[String], out: &mut String) {
    out.push('[');
    for (i, item) in list.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        json_string(item, out);
    }
    out.push(']');
}

fn json_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Which call a language is answering: the row it is through — the
/// language's name, or a set's — and the features in force, in declaration
/// order.
#[derive(Clone, Copy, Debug)]
pub struct Call<'a> {
    pub row: &'a str,
    pub features: &'a [&'a str],
}

impl Call<'_> {
    /// Whether `feature` is on.
    pub fn has(&self, feature: &str) -> bool {
        self.features.contains(&feature)
    }
}

/// A language supplied at runtime. Called from whichever thread parses or
/// prints, hence `Send + Sync`; kept for the life of the process, since there
/// is no unregistration.
pub trait Language: Send + Sync + 'static {
    fn describe(&self) -> Description;

    /// `source` to the node table of its parse, as JSON. `row` is the name
    /// the call is through. An `Err` is a parse error whose message the
    /// library reports.
    fn parse(&self, row: &str, source: &[u8]) -> Result<Vec<u8>, String> {
        let _ = (row, source);
        Err("this language implements neither parse nor parse_with".to_owned())
    }

    /// A node table without positions to source. Called only for a language
    /// whose description declares `write`.
    fn print(&self, row: &str, table: &[u8]) -> Result<Vec<u8>, String> {
        let _ = (row, table);
        Err("this language does not print".to_owned())
    }

    /// [`Language::parse`], told the features in force.
    fn parse_with(&self, call: &Call<'_>, source: &[u8]) -> Result<Vec<u8>, String> {
        self.parse(call.row, source)
    }

    /// [`Language::print`], told the features in force.
    fn print_with(&self, call: &Call<'_>, table: &[u8]) -> Result<Vec<u8>, String> {
        self.print(call.row, table)
    }

    /// Answer one of the renderers the description's `syntax` names. The
    /// request is JSON:
    ///
    /// - `{"which":"render_text","text":…,"position":…}`;
    /// - `{"which":"render_block","table":{…}}`;
    /// - `{"which":"spells_autolink","text":"<…>"}` — answer `true` or
    ///   `false`.
    ///
    /// The default answers `render_block` with [`Language::print_with`] and
    /// refuses the rest.
    fn render(&self, call: &Call<'_>, request: &[u8]) -> Result<Vec<u8>, String> {
        // The library writes a render_block request as exactly this prefix,
        // the table, and a closing brace.
        const BLOCK: &[u8] = br#"{"which":"render_block","table":"#;
        if request.starts_with(BLOCK) && request.ends_with(b"}") {
            return self.print_with(call, &request[BLOCK.len()..request.len() - 1]);
        }
        Err("this language names no renderers but render_block".to_owned())
    }
}

/// Why [`register`] refused a language.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RegisterError {
    /// [`Error::InvalidLanguage`] for a refusal; otherwise what the call
    /// failed with.
    pub error: Error,
    /// The library's reason, naming the field or sample at fault.
    pub message: String,
}

impl fmt::Display for RegisterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.message.is_empty() {
            write!(f, "{}", self.error)
        } else {
            write!(f, "{}: {}", self.error, self.message)
        }
    }
}

impl std::error::Error for RegisterError {}

fn refused(message: String) -> RegisterError {
    RegisterError { error: Error::InvalidLanguage, message }
}

/// One of the language's functions, its answer or its message, a panic
/// turned into a failure — as the binding's trampolines do — and an empty
/// message read as the C ABI reads one.
fn guarded(f: impl FnOnce() -> Result<Vec<u8>, String>) -> Result<Vec<u8>, String> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(answer)) => Ok(answer),
        Ok(Err(message)) if message.is_empty() => Err("the host's function returned a failure".to_owned()),
        Ok(Err(message)) => Err(message),
        Err(_) => Err("the language panicked".to_owned()),
    }
}

fn call_of<'a>(c: &'a runtime::Call<'a>) -> Call<'a> {
    Call { row: c.row, features: c.feature_names }
}

/// The request `render` is handed: the wire's `render` without the members
/// the call carries.
fn render_request(request: &Render) -> Vec<u8> {
    let mut out = Vec::new();
    match request {
        Render::RenderText { text, position } => {
            out.extend_from_slice(b"{\"which\":\"render_text\",\"text\":");
            crate::json::write_string(&mut out, text);
            out.extend_from_slice(b",\"position\":");
            crate::json::write_string(&mut out, runtime::position_name(*position).as_bytes());
            out.push(b'}');
        }
        Render::RenderBlock(table) => {
            out.extend_from_slice(b"{\"which\":\"render_block\",\"table\":");
            out.extend_from_slice(table);
            out.push(b'}');
        }
        Render::SpellsAutolink(angled) => {
            out.extend_from_slice(b"{\"which\":\"spells_autolink\",\"text\":");
            crate::json::write_string(&mut out, angled);
            out.push(b'}');
        }
    }
    out
}

/// `language` as the runtime registry takes one.
fn runtime_language<L: Language>(language: Arc<L>, write: bool) -> runtime::Language {
    let (a, b, c) = (language.clone(), language.clone(), language);
    runtime::Language {
        parse: Box::new(move |call, source| guarded(|| a.parse_with(&call_of(call), source))),
        print: if write {
            Some(Box::new(move |call, table| guarded(|| b.print_with(&call_of(call), table))))
        } else {
            None
        },
        render: Some(Box::new(move |call, request| {
            let r = render_request(request);
            guarded(|| c.render(&call_of(call), &r))
        })),
    }
}

/// Register `language` and return the [`Format`] of its own row in this
/// process; each of its sets is a format too, found with
/// `format::parse_format_name`. On refusal nothing is registered and the
/// language is dropped.
pub fn register<L: Language>(language: L) -> Result<Format, RegisterError> {
    let description = language.describe();
    let json = description.to_json();
    let mut diag = String::new();
    let parsed = runtime::Description::parse(json.as_bytes(), &mut diag).map_err(|_| refused(diag.clone()))?;
    let lang = runtime_language(Arc::new(language), description.write);
    runtime::register(lang, parsed, &mut diag).map_err(|_| refused(diag))
}

/// A language answering the helper wire — one request line to one response
/// line. What [`serve`] loops over, and what a host with its own transport
/// hands lines to.
pub struct Server {
    server: wire::Server,
}

impl Server {
    /// Serve `language`. A description the library cannot read is refused,
    /// with why; the load check is the calling end's.
    pub fn new<L: Language>(language: L) -> Result<Server, RegisterError> {
        let description = language.describe();
        let json = description.to_json();
        let lang = runtime_language(Arc::new(language), description.write);
        let mut diag = String::new();
        let server = wire::Server::new(lang, json.as_bytes(), &mut diag).map_err(|_| refused(diag))?;
        Ok(Server { server })
    }

    /// One request line, without its newline, to one response line, without
    /// its newline. A request the server cannot read, and the language's own
    /// refusal, are answered `{"ok":false,"message":…}`.
    pub fn handle(&mut self, request: &[u8]) -> Result<Vec<u8>, Error> {
        Ok(self.server.handle(request))
    }
}

/// Serve `language` on this process's stdin and stdout until stdin ends —
/// the whole of a helper's `main`. A description the library cannot read is
/// an `InvalidData` error before any line is read.
pub fn serve<L: Language>(language: L) -> std::io::Result<()> {
    let mut server =
        Server::new(language).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().split(b'\n') {
        let mut line = line?;
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        let response = server.handle(&line).map_err(|e| std::io::Error::other(e.to_string()))?;
        stdout.write_all(&response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format::{self, ParseConfig, Target};


    fn editor_over(fmt: Format, cfg: ParseConfig, src: &[u8]) -> crate::ast::editor::Editor {
        let pf: crate::ast::splicer::ParseFn = Box::new(move |s| {
            format::parse_to_ast(fmt, &cfg, s).map_err(|e| crate::ast::splicer::ParseError::new(e.name()))
        });
        crate::ast::editor::Editor::new(src, pf, format::syntax_for_config(fmt, &cfg)).unwrap()
    }

    /// Every non-empty line a paragraph of one `str`; printed back one per
    /// line.
    struct Lines(&'static str);

    fn escape(s: &str) -> String {
        let mut out = String::new();
        json_string(s, &mut out);
        out
    }

    impl Language for Lines {
        fn describe(&self) -> Description {
            Description {
                name: self.0.to_owned(),
                extensions: vec![format!("{}-ext", self.0)],
                write: true,
                samples: vec!["one\ntwo\n".to_owned(), "x\n".to_owned()],
                ..Description::default()
            }
        }

        fn parse(&self, _row: &str, source: &[u8]) -> Result<Vec<u8>, String> {
            let src = std::str::from_utf8(source).map_err(|_| "not UTF-8".to_owned())?;
            if src.contains('\0') {
                return Err("a NUL byte is not a line".to_owned());
            }
            let mut rows = vec![format!("{{\"kind\":\"doc\",\"span\":[0,{}]}}", src.len())];
            let mut start = 0;
            for line in src.split_inclusive('\n') {
                let text = line.trim_end_matches('\n').trim_end_matches('\r');
                if !text.is_empty() {
                    let para = rows.len();
                    let end = start + text.len();
                    rows.push(format!("{{\"kind\":\"para\",\"parent\":0,\"span\":[{start},{end}]}}"));
                    rows.push(format!(
                        "{{\"kind\":\"str\",\"parent\":{para},\"span\":[{start},{end}],\"text\":{}}}",
                        escape(text)
                    ));
                }
                start += line.len();
            }
            Ok(format!("{{\"nodes\":[{}]}}", rows.join(",")).into_bytes())
        }

        fn print(&self, _row: &str, table: &[u8]) -> Result<Vec<u8>, String> {
            let table = std::str::from_utf8(table).map_err(|e| e.to_string())?;
            let mut out = String::new();
            let mut rest = table;
            while let Some(at) = rest.find("\"text\":\"") {
                rest = &rest[at + 8..];
                let end = rest.find('"').ok_or("unterminated text")?;
                out.push_str(&rest[..end]);
                out.push('\n');
                rest = &rest[end..];
            }
            Ok(out.into_bytes())
        }
    }

    #[test]
    fn a_registered_language_is_a_format_like_any_other() {
        let format = register(Lines("rust-lines")).expect("register");
        assert!(matches!(format, Format::Runtime(_)));
        assert_eq!(format.name(), "rust-lines");
        assert_eq!(format::parse_format_name("rust-lines"), Some(format));
        assert_eq!(format::parse_format_name("gfm"), Some(Format::Gfm));
        assert_eq!(Target::from(format).as_format(), Some(format));

        let cfg = ParseConfig::default();
        let doc = format::parse(format, &cfg, b"alpha\nbeta\n").expect("parse");
        assert_eq!(format::render_html(&doc).unwrap(), b"<p>alpha</p>\n<p>beta</p>\n");
        assert_eq!(format::serialize_converted(&doc, Target::Markdown).unwrap(), b"alpha\n\nbeta\n");
        assert_eq!(format::serialize_canonical(&doc).unwrap(), b"alpha\nbeta\n");

        let md = format::parse(Format::Markdown, &cfg, b"# T\n\nx\n").expect("markdown");
        assert_eq!(format::serialize_converted(&md, Target::from(format)).unwrap(), b"T\nx\n");

        // It reads and writes, and does not author.
        assert!(!format::syntax_for(format).authorable());

        // The language's own refusal is a parse error, with its reason.
        let err = format::parse(format, &cfg, b"a\0b").unwrap_err();
        assert_eq!(err.name(), "rust-lines: parse failed: a NUL byte is not a line");
    }

    #[test]
    fn a_refusal_says_why_and_registers_nothing() {
        struct Taken;
        impl Language for Taken {
            fn describe(&self) -> Description {
                Description { name: "markdown".into(), samples: vec!["x".into()], ..Description::default() }
            }
            fn parse(&self, _: &str, _: &[u8]) -> Result<Vec<u8>, String> {
                Ok(br#"{"nodes":[{"kind":"doc","span":[0,1]}]}"#.to_vec())
            }
        }
        let err = register(Taken).unwrap_err();
        assert_eq!(err.error, Error::InvalidLanguage);
        assert!(err.message.contains("already a format's"), "{}", err.message);

        struct Panics;
        impl Language for Panics {
            fn describe(&self) -> Description {
                Description { name: "rust-panics".into(), samples: vec!["x".into()], ..Description::default() }
            }
            fn parse(&self, _: &str, _: &[u8]) -> Result<Vec<u8>, String> {
                panic!("boom")
            }
        }
        let err = register(Panics).unwrap_err();
        assert!(err.message.contains("the language panicked"), "{}", err.message);
        assert_eq!(format::parse_format_name("rust-panics"), None);
    }

    /// [`Lines`] with a `crlf` feature that prints `\r\n` line ends, a set
    /// that has it on, and a literal spelled by a renderer.
    struct CrlfLines;

    impl Language for CrlfLines {
        fn describe(&self) -> Description {
            Description {
                name: "rust-crlf".into(),
                write: true,
                author: true,
                syntax: Some(r#"{"renderers":["render_text"]}"#.into()),
                features: vec![Feature { name: "crlf".into(), ..Feature::default() }],
                sets: vec![Set { name: "rust-crlf-crlf".into(), features: vec!["crlf".into()], ..Set::default() }],
                samples: vec!["one\ntwo\n".into()],
                feature_samples: vec![Sample { text: "x\n".into(), features: vec!["crlf".into()] }],
                ..Description::default()
            }
        }

        fn parse_with(&self, call: &Call<'_>, source: &[u8]) -> Result<Vec<u8>, String> {
            Lines("rust-crlf").parse(call.row, source)
        }

        fn print_with(&self, call: &Call<'_>, table: &[u8]) -> Result<Vec<u8>, String> {
            let out = Lines("rust-crlf").print(call.row, table)?;
            Ok(if call.has("crlf") { String::from_utf8_lossy(&out).replace('\n', "\r\n").into_bytes() } else { out })
        }

        /// A literal is itself.
        fn render(&self, _: &Call<'_>, request: &[u8]) -> Result<Vec<u8>, String> {
            let request = std::str::from_utf8(request).map_err(|e| e.to_string())?;
            let at = request.find("\"text\":\"").ok_or("no text")? + 8;
            let mut out = String::new();
            let mut chars = request[at..].chars();
            while let Some(c) = chars.next() {
                match c {
                    '"' => return Ok(out.into_bytes()),
                    '\\' => out.push(chars.next().ok_or("unterminated escape")?),
                    c => out.push(c),
                }
            }
            Err("unterminated text".to_owned())
        }
    }

    #[test]
    fn features_sets_and_renderers_reach_every_entry_point() {
        let format = register(CrlfLines).expect("register");
        let set = format::parse_format_name("rust-crlf-crlf").expect("the set is a format");
        assert_ne!(set, format);
        assert_eq!(set.dialect_of(), Some(format));
        assert_eq!(format.dialect_of(), None);
        assert_eq!(format::feature_bit(format, "crlf"), Some(1));
        assert_eq!(format::feature_bit(format, "tabs"), None);

        let crlf = ParseConfig::for_features(format, 1);
        let doc = format::parse(format, &crlf, b"a\nb\n").unwrap();
        assert_eq!(format::serialize_canonical(&doc).unwrap(), b"a\r\nb\r\n");
        let doc = format::parse(set, &ParseConfig::default(), b"a\nb\n").unwrap();
        assert_eq!(format::serialize_canonical(&doc).unwrap(), b"a\r\nb\r\n");
        let doc = format::parse(format, &ParseConfig::default(), b"a\nb\n").unwrap();
        assert_eq!(format::serialize_canonical(&doc).unwrap(), b"a\nb\n");

        // It authors: a literal goes in through the renderer.
        let table = format::syntax_for(format);
        assert!(table.authorable());
        let mut out = Vec::new();
        table.render_text(b"*x* ", crate::syntax::TextPosition::InlineText, &mut out).unwrap();
        assert_eq!(out, b"*x* ");
        use crate::ast::editor::{supports, Gesture};
        assert!(supports(table, Gesture::InsertLiteral));
        assert!(supports(format::syntax_for_config(format, &crlf), Gesture::InsertLiteral));
        let mut editor = editor_over(format, crlf, b"a\n");
        editor.insert_literal(0, b"*x* ").unwrap();
        assert_eq!(editor.source_bytes(), b"*x* a\n");
    }

    #[test]
    fn a_server_answers_the_wire_for_a_language() {
        let mut server = Server::new(CrlfLines).expect("serve");
        let described = String::from_utf8(server.handle(br#"{"op":"describe"}"#).unwrap()).unwrap();
        assert!(described.starts_with(r#"{"ok":true,"description":{"name":"rust-crlf""#), "{described}");
        let printed = server
            .handle(br#"{"op":"print","dialect":"rust-crlf","features":["crlf"],"table":{"nodes":[{"kind":"doc"},{"kind":"para","parent":0},{"kind":"str","parent":1,"text":"hi"}]}}"#)
            .unwrap();
        assert_eq!(printed, br#"{"ok":true,"output":"hi\r\n"}"#);
        let refused = server.handle(b"not json").unwrap();
        assert!(refused.starts_with(br#"{"ok":false"#));

        struct Unreadable;
        impl Language for Unreadable {
            fn describe(&self) -> Description {
                Description {
                    name: "rust-unreadable".into(),
                    syntax: Some("not json".into()),
                    samples: vec!["x".into()],
                    ..Description::default()
                }
            }
        }
        let err = Server::new(Unreadable).err().expect("refused");
        assert_eq!(err.error, Error::InvalidLanguage);
    }
}
