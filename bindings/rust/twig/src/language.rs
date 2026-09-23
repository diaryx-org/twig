//! Languages registered at runtime: a format this library did not compile in,
//! supplied as a Rust [`Language`] and registered with [`register`].
//!
//! A language **reads**: its [`Language::parse`] turns source into the node
//! table — the JSON `twig convert -o table` prints for a compiled format, one
//! row per node in pre-order, each naming its parent, with its spans and its
//! kind's fields. It may **write**: [`Language::print`] turns a node table
//! (without positions) back into source. It does not author; an [`Editor`]
//! opens over it with every gesture unsupported.
//!
//! Registration runs the load check over the language before it exists —
//! every sample parses to a table the library accepts, a language that prints
//! reparses every sample's print to the same tree, and the fidelity probe
//! measures what a conversion into it loses — and after that the returned
//! [`Format`] works everywhere a compiled one does: [`Document::parse`],
//! [`Document::render_html`], [`Document::serialize_to`], the diagnostics.
//!
//! [`Editor`]: crate::Editor
//! [`Document::parse`]: crate::Document::parse
//! [`Document::render_html`]: crate::Document::render_html
//! [`Document::serialize_to`]: crate::Document::serialize_to

use std::ffi::{c_void, CStr};
use std::fmt;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};

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
    /// Small documents the load check holds the language to. At least one.
    pub samples: Vec<String>,
}

impl Description {
    /// The `describe` document the C ABI reads.
    fn to_json(&self) -> String {
        let mut out = String::from("{\"name\":");
        json_string(&self.name, &mut out);
        for (key, list) in [
            ("extensions", &self.extensions),
            ("aliases", &self.aliases),
            ("samples", &self.samples),
        ] {
            out.push_str(",\"");
            out.push_str(key);
            out.push_str("\":[");
            for (i, item) in list.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                json_string(item, &mut out);
            }
            out.push(']');
        }
        out.push_str(",\"caps\":{\"read\":true,\"write\":");
        out.push_str(if self.write { "true" } else { "false" });
        out.push_str("}}");
        out
    }
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

/// A language supplied at runtime. Called from whichever thread parses or
/// prints, hence `Send + Sync`; kept for the life of the process, since there
/// is no unregistration.
pub trait Language: Send + Sync + 'static {
    fn describe(&self) -> Description;

    /// `source` to the node table of its parse, as JSON. `row` is the name
    /// the language registered under. An `Err` is a parse error whose message
    /// the library reports.
    fn parse(&self, row: &str, source: &[u8]) -> Result<Vec<u8>, String>;

    /// A node table without positions to source. Called only for a language
    /// whose description declares `write`.
    fn print(&self, row: &str, table: &[u8]) -> Result<Vec<u8>, String> {
        let _ = (row, table);
        Err("this language does not print".to_owned())
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

/// Register `language` and return the [`Format`] it answers to in this
/// process. On refusal nothing is registered and the language is dropped.
pub fn register<L: Language>(language: L) -> Result<Format, RegisterError> {
    let description = language.describe();
    let json = description.to_json();
    let user_data = Box::into_raw(Box::new(language)) as *mut c_void;
    let vtable = ffi::TwigLanguageVTable {
        version: ffi::TWIG_LANGUAGE_VTABLE_VERSION,
        user_data,
        description: json.as_ptr(),
        description_len: json.len(),
        parse: Some(parse_trampoline::<L>),
        print: if description.write {
            Some(print_trampoline::<L>)
        } else {
            None
        },
        free: Some(free_trampoline),
    };
    let mut code: c_int = 0;
    let mut err = [0 as c_char; 512];
    let status =
        unsafe { ffi::twig_language_register(&vtable, &mut code, err.as_mut_ptr(), err.len()) };
    match Error::from_status(status) {
        Ok(()) => Ok(Format::Runtime(RuntimeId(code))),
        Err(error) => {
            // Refused: the library kept nothing that points at it.
            drop(unsafe { Box::from_raw(user_data as *mut L) });
            let message = unsafe { CStr::from_ptr(err.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            Err(RegisterError { error, message })
        }
    }
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

unsafe extern "C" fn parse_trampoline<L: Language>(
    user_data: *mut c_void,
    row: *const u8,
    row_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let language = unsafe { &*(user_data as *const L) };
    let row = std::str::from_utf8(unsafe { bytes(row, row_len) }).unwrap_or("");
    let input = unsafe { bytes(input, input_len) };
    unsafe { call(|| language.parse(row, input), out, out_len) }
}

unsafe extern "C" fn print_trampoline<L: Language>(
    user_data: *mut c_void,
    row: *const u8,
    row_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let language = unsafe { &*(user_data as *const L) };
    let row = std::str::from_utf8(unsafe { bytes(row, row_len) }).unwrap_or("");
    let input = unsafe { bytes(input, input_len) };
    unsafe { call(|| language.print(row, input), out, out_len) }
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
                let text = line.trim_end_matches('\n');
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
}
