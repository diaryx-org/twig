//! Languages registered at runtime: a format this library did not compile in,
//! supplied as a Rust [`Language`] and registered with [`register`].
//!
//! A language **reads**: its [`Language::parse`] turns source into the node
//! table — the JSON `twig convert -o table` prints for a compiled format, one
//! row per node in pre-order, each naming its parent, with its spans and its
//! kind's fields. It may **write**: [`Language::print`] turns a node table
//! (without positions) back into source. It may **author**: its
//! [`Description::syntax`] is the table an [`Editor`]'s gestures write with —
//! `twig lang syntax <format>` prints a compiled format's — and
//! [`Language::render`] answers the renderers that table names.
//!
//! A language may declare [`Feature`]s, switches its parser reads, and
//! [`Set`]s, each a name for a list of them registered as a [`Format`] of
//! its own. Every call says which row it is through and which features are on
//! ([`Call`]); a caller lays more on with [`Document::parse_with_features`]
//! and [`Editor::new_with_features`].
//!
//! Registration runs the load check over the language before it exists —
//! every sample parses to a table the library accepts, a language that prints
//! reparses every sample's print to the same tree, a language that authors
//! keeps every promise the engine holds a compiled format to, under each row's
//! features, each with one more, and all of them; and the fidelity probe
//! measures what a conversion into it loses — and after that the returned
//! [`Format`] works everywhere a compiled one does: [`Document::parse`],
//! [`Document::render_html`], [`Document::serialize_to`], the diagnostics, the
//! editor.
//!
//! [`Server`] and [`serve`] are the other end: the same language answering
//! the helper wire, which is how a Rust program becomes a helper the `twig`
//! command line spawns.
//!
//! [`Editor`]: crate::Editor
//! [`Editor::new_with_features`]: crate::Editor::new_with_features
//! [`Document::parse`]: crate::Document::parse
//! [`Document::parse_with_features`]: crate::Document::parse_with_features
//! [`Document::render_html`]: crate::Document::render_html
//! [`Document::serialize_to`]: crate::Document::serialize_to

use std::ffi::{c_void, CStr};
use std::fmt;
use std::io::{BufRead, Write};
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::{ffi, Error, Format, RuntimeId};

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
    /// The `describe` document the C ABI reads. `syntax` goes in as written.
    fn to_json(&self) -> String {
        let mut out = String::from("{\"name\":");
        json_string(&self.name, &mut out);
        for (key, list) in [
            ("extensions", &self.extensions),
            ("aliases", &self.aliases),
        ] {
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
            for (key, list) in [
                ("extensions", &set.extensions),
                ("aliases", &set.aliases),
                ("features", &set.features),
            ] {
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
/// language's name, or a set's — and the features in force, the row's own
/// and whatever the caller laid over them, in declaration order.
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
///
/// A language implements [`Language::parse`], or [`Language::parse_with`]
/// when it reads features; the same for printing.
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
    /// request is JSON, as the node tables are:
    ///
    /// - `{"which":"render_text","text":…,"position":…}` — spell `text` so it
    ///   reparses as itself, at `position` `inline_text`, `block_start` or
    ///   `verbatim`;
    /// - `{"which":"render_block","table":{…}}` — spell a fragment: a node
    ///   table without positions, rooted at the node to print;
    /// - `{"which":"spells_autolink","text":"<…>"}` — answer `true` or
    ///   `false`.
    ///
    /// The default answers `render_block` with [`Language::print_with`] —
    /// so a language whose print spells every fragment a gesture builds names
    /// `render_block` and writes nothing more — and refuses the rest. One
    /// whose table states `text_escapes` names no `render_text`.
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

/// A language behind the C table: the language, and its features' names in
/// the order a call's mask counts them.
struct Hosted<L> {
    language: L,
    features: Vec<String>,
}

/// The C table over `hosted`, whose description is `json`.
fn vtable<L: Language>(hosted: *mut Hosted<L>, json: &str, description: &Description) -> ffi::TwigLanguageVTable {
    ffi::TwigLanguageVTable {
        version: ffi::TWIG_LANGUAGE_VTABLE_VERSION,
        user_data: hosted as *mut c_void,
        description: json.as_ptr(),
        description_len: json.len(),
        parse: Some(parse_trampoline::<L>),
        print: if description.write {
            Some(print_trampoline::<L>)
        } else {
            None
        },
        render: Some(render_trampoline::<L>),
        free: Some(free_trampoline),
    }
}

fn host<L: Language>(language: L, description: &Description) -> *mut Hosted<L> {
    Box::into_raw(Box::new(Hosted {
        language,
        features: description.features.iter().map(|f| f.name.clone()).collect(),
    }))
}

fn message(err: &[c_char]) -> String {
    unsafe { CStr::from_ptr(err.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

/// Register `language` and return the [`Format`] of its own row in this
/// process; each of its sets is a format too, found with [`Format::by_name`].
/// On refusal nothing is registered and the language is dropped.
pub fn register<L: Language>(language: L) -> Result<Format, RegisterError> {
    let description = language.describe();
    let json = description.to_json();
    let hosted = host(language, &description);
    let vtable = vtable(hosted, &json, &description);
    let mut code: c_int = 0;
    let mut err = [0 as c_char; 512];
    let status =
        unsafe { ffi::twig_language_register(&vtable, &mut code, err.as_mut_ptr(), err.len()) };
    match Error::from_status(status) {
        Ok(()) => Ok(Format::Runtime(RuntimeId(code))),
        Err(error) => {
            // Refused: the library kept nothing that points at it.
            drop(unsafe { Box::from_raw(hosted) });
            Err(RegisterError {
                error,
                message: message(&err),
            })
        }
    }
}

/// A language answering the helper wire — one request line to one response
/// line, the codec the library's own. What [`serve`] loops over, and what a
/// host with its own transport hands lines to.
pub struct Server {
    raw: NonNull<ffi::TwigServer>,
    /// The language, kept alive as long as the library may call it.
    free: unsafe fn(*mut c_void),
    hosted: *mut c_void,
}

// The library's server is used from one thread at a time through `&mut`, and
// the language it calls is `Send + Sync`.
unsafe impl Send for Server {}

unsafe fn drop_hosted<L>(p: *mut c_void) {
    drop(unsafe { Box::from_raw(p as *mut Hosted<L>) });
}

impl Server {
    /// Serve `language`. A description the library cannot read is refused,
    /// with why; the load check is the calling end's.
    pub fn new<L: Language>(language: L) -> Result<Server, RegisterError> {
        let description = language.describe();
        let json = description.to_json();
        let hosted = host(language, &description);
        let vtable = vtable(hosted, &json, &description);
        let mut raw = std::ptr::null_mut();
        let mut err = [0 as c_char; 512];
        let status =
            unsafe { ffi::twig_server_create(&vtable, &mut raw, err.as_mut_ptr(), err.len()) };
        match Error::from_status(status).and_then(|()| NonNull::new(raw).ok_or(Error::Internal)) {
            Ok(raw) => Ok(Server {
                raw,
                free: drop_hosted::<L>,
                hosted: hosted as *mut c_void,
            }),
            Err(error) => {
                drop(unsafe { Box::from_raw(hosted) });
                Err(RegisterError {
                    error,
                    message: message(&err),
                })
            }
        }
    }

    /// One request line, without its newline, to one response line, without
    /// its newline. A request the server cannot read, and the language's own
    /// refusal, are answered `{"ok":false,"message":…}`.
    pub fn handle(&mut self, request: &[u8]) -> Result<Vec<u8>, Error> {
        let mut ptr: *const u8 = std::ptr::null();
        let mut len = 0usize;
        let status = unsafe {
            ffi::twig_server_handle(self.raw.as_ptr(), request.as_ptr(), request.len(), &mut ptr, &mut len)
        };
        Error::from_status(status)?;
        Ok(unsafe { bytes(ptr, len) }.to_vec())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        unsafe {
            ffi::twig_server_destroy(self.raw.as_ptr());
            (self.free)(self.hosted);
        }
    }
}

/// Serve `language` on this process's stdin and stdout until stdin ends —
/// the whole of a helper's `main`:
///
/// ```no_run
/// # struct Org;
/// # impl twig::Language for Org { fn describe(&self) -> twig::Description { unimplemented!() } }
/// fn main() -> std::io::Result<()> {
///     twig::serve(Org)
/// }
/// ```
///
/// A description the library cannot read is an `InvalidData` error before
/// any line is read.
pub fn serve<L: Language>(language: L) -> std::io::Result<()> {
    let mut server = Server::new(language)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().split(b'\n') {
        let mut line = line?;
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        let response = server
            .handle(&line)
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        stdout.write_all(&response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }
    Ok(())
}

pub(crate) unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 || ptr.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

pub(crate) unsafe fn give(bytes: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let boxed = bytes.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
    }
}

/// Run one of the language's functions across the C boundary: its answer or
/// its message out through `out`, and a panic turned into a failure rather
/// than unwound into the library.
unsafe fn call(
    f: impl FnOnce() -> Result<Vec<u8>, String>,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(answer)) => {
            unsafe { give(answer, out, out_len) };
            0
        }
        Ok(Err(message)) => {
            unsafe { give(message.into_bytes(), out, out_len) };
            1
        }
        Err(_) => {
            unsafe { give(b"the language panicked".to_vec(), out, out_len) };
            1
        }
    }
}

/// The language, and the call record read into a [`Call`] for `f`.
unsafe fn with_call<L: Language>(
    user_data: *mut c_void,
    record: *const ffi::TwigLanguageCall,
    out: *mut *mut u8,
    out_len: *mut usize,
    f: impl FnOnce(&L, &Call<'_>, &[u8]) -> Result<Vec<u8>, String>,
) -> c_int {
    let hosted = unsafe { &*(user_data as *const Hosted<L>) };
    let record = unsafe { &*record };
    let row = std::str::from_utf8(unsafe { bytes(record.row, record.row_len) }).unwrap_or("");
    let input = unsafe { bytes(record.input, record.input_len) };
    let features: Vec<&str> = hosted
        .features
        .iter()
        .enumerate()
        .filter(|(i, _)| *i < 32 && record.features & (1u32 << i) != 0)
        .map(|(_, name)| name.as_str())
        .collect();
    let c = Call {
        row,
        features: &features,
    };
    unsafe { call(|| f(&hosted.language, &c, input), out, out_len) }
}

unsafe extern "C" fn parse_trampoline<L: Language>(
    user_data: *mut c_void,
    record: *const ffi::TwigLanguageCall,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    unsafe { with_call::<L>(user_data, record, out, out_len, |l, c, input| l.parse_with(c, input)) }
}

unsafe extern "C" fn print_trampoline<L: Language>(
    user_data: *mut c_void,
    record: *const ffi::TwigLanguageCall,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    unsafe { with_call::<L>(user_data, record, out, out_len, |l, c, input| l.print_with(c, input)) }
}

unsafe extern "C" fn render_trampoline<L: Language>(
    user_data: *mut c_void,
    record: *const ffi::TwigLanguageCall,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    unsafe { with_call::<L>(user_data, record, out, out_len, |l, c, input| l.render(c, input)) }
}

pub(crate) unsafe extern "C" fn free_trampoline(_: *mut c_void, ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Document, Gesture, Target};

    /// Every non-empty line a paragraph of one `str`; printed back one per
    /// line. Reads the print table with a scan for `"text":` values, which is
    /// enough for the tables it prints from.
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
                    rows.push(format!(
                        "{{\"kind\":\"para\",\"parent\":0,\"span\":[{start},{end}]}}"
                    ));
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
        assert_eq!(Format::by_name("rust-lines"), Some(format));
        assert_eq!(Format::by_name("gfm"), Some(Format::Gfm));
        assert_eq!(Format::Gfm.name(), "gfm");
        assert_eq!(Target::from(format).as_format(), Some(format));

        let mut doc = Document::parse_str("alpha\nbeta\n", format).expect("parse");
        assert_eq!(doc.render_html().unwrap(), b"<p>alpha</p>\n<p>beta</p>\n");
        assert_eq!(
            doc.serialize_to(Target::Markdown).unwrap(),
            b"alpha\n\nbeta\n"
        );
        assert_eq!(
            doc.serialize_to(Target::from(format)).unwrap(),
            b"alpha\nbeta\n"
        );

        let mut md = Document::parse_str("# T\n\nx\n", Format::Markdown).expect("markdown");
        assert_eq!(md.serialize_to(Target::from(format)).unwrap(), b"T\nx\n");

        // It reads and writes, and does not author.
        assert!(!format.supports(Gesture::SetBlock));
        assert!(!format.supports(Gesture::InsertLink));

        // The language's own refusal is a parse error.
        assert_eq!(
            Document::parse_str("a\0b", format).err(),
            Some(Error::ParseError)
        );
    }

    #[test]
    fn a_refusal_says_why_and_registers_nothing() {
        struct Taken;
        impl Language for Taken {
            fn describe(&self) -> Description {
                Description {
                    name: "markdown".into(),
                    samples: vec!["x".into()],
                    ..Description::default()
                }
            }
            fn parse(&self, _: &str, _: &[u8]) -> Result<Vec<u8>, String> {
                Ok(br#"{"nodes":[{"kind":"doc","span":[0,1]}]}"#.to_vec())
            }
        }
        let err = register(Taken).unwrap_err();
        assert_eq!(err.error, Error::InvalidLanguage);
        assert!(
            err.message.contains("already a format's"),
            "{}",
            err.message
        );

        struct Panics;
        impl Language for Panics {
            fn describe(&self) -> Description {
                Description {
                    name: "rust-panics".into(),
                    samples: vec!["x".into()],
                    ..Description::default()
                }
            }
            fn parse(&self, _: &str, _: &[u8]) -> Result<Vec<u8>, String> {
                panic!("boom")
            }
        }
        let err = register(Panics).unwrap_err();
        assert!(
            err.message.contains("the language panicked"),
            "{}",
            err.message
        );
        assert_eq!(Format::by_name("rust-panics"), None);
    }

    /// [`Lines`] with a `crlf` feature that prints `\r\n` line ends — which
    /// the parse reads back the same — a set that has it on, and a literal
    /// spelled by a renderer: all a table needs to author with.
    struct CrlfLines;

    impl Language for CrlfLines {
        fn describe(&self) -> Description {
            Description {
                name: "rust-crlf".into(),
                write: true,
                author: true,
                syntax: Some(r#"{"renderers":["render_text"]}"#.into()),
                features: vec![Feature {
                    name: "crlf".into(),
                    ..Feature::default()
                }],
                sets: vec![Set {
                    name: "rust-crlf-crlf".into(),
                    features: vec!["crlf".into()],
                    ..Set::default()
                }],
                samples: vec!["one\ntwo\n".into()],
                feature_samples: vec![Sample {
                    text: "x\n".into(),
                    features: vec!["crlf".into()],
                }],
                ..Description::default()
            }
        }

        fn parse_with(&self, call: &Call<'_>, source: &[u8]) -> Result<Vec<u8>, String> {
            Lines("rust-crlf").parse(call.row, source)
        }

        fn print_with(&self, call: &Call<'_>, table: &[u8]) -> Result<Vec<u8>, String> {
            let out = Lines("rust-crlf").print(call.row, table)?;
            Ok(if call.has("crlf") {
                String::from_utf8_lossy(&out).replace('\n', "\r\n").into_bytes()
            } else {
                out
            })
        }

        /// A literal is itself. The request's `text` is read with a scan
        /// that undoes the two escapes the load check's literal needs.
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
        let set = Format::by_name("rust-crlf-crlf").expect("the set is a format");
        assert_ne!(set, format);
        assert_eq!(format.feature_flags(&["crlf"]), Ok(1));
        assert_eq!(format.feature_flags(&["tabs"]), Err(Error::NotFound));
        assert_eq!(Format::Markdown.feature_flags(&["math"]), Err(Error::UnsupportedFormat));

        let mut doc = Document::parse_with_features(b"a\nb\n", format, &["crlf"]).unwrap();
        assert_eq!(doc.serialize_to(Target::from(format)).unwrap(), b"a\r\nb\r\n");
        let mut doc = Document::parse_str("a\nb\n", set).unwrap();
        assert_eq!(doc.serialize_to(Target::from(set)).unwrap(), b"a\r\nb\r\n");
        let mut doc = Document::parse_str("a\nb\n", format).unwrap();
        assert_eq!(doc.serialize_to(Target::from(format)).unwrap(), b"a\nb\n");

        // It authors: a literal goes in through the renderer.
        assert!(format.supports(Gesture::InsertLiteral));
        assert!(format.supports_with_features(&["crlf"], Gesture::InsertLiteral));
        assert!(!format.supports_with_features(&["tabs"], Gesture::InsertLiteral));
        let mut editor = crate::Editor::new_with_features(b"a\n", format, &["crlf"]).unwrap();
        editor.insert_literal(0, "*x* ").unwrap();
        assert_eq!(editor.source().unwrap(), b"*x* a\n");
    }

    #[test]
    fn a_server_answers_the_wire_for_a_language() {
        let mut server = Server::new(CrlfLines).expect("serve");
        let described = server.handle(br#"{"op":"describe"}"#).unwrap();
        let described = String::from_utf8(described).unwrap();
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
