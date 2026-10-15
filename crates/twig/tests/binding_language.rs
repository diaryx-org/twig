//! The FFI binding's own tests for this module (bindings/rust/twig/src/language.rs),
//! run unchanged against the pure-Rust crate as an outside consumer.

mod common;

    use twig::*;
    

    /// Every non-empty line a paragraph of one `str`; printed back one per
    /// line. Reads the print table with a scan for `"text":` values, which is
    /// enough for the tables it prints from.
    struct Lines(&'static str);

    fn escape(s: &str) -> String {
        let mut out = String::new();
        json_string(s, &mut out);
        out
    }

    impl TableLanguage for Lines {
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
        let format = register_table(Lines("rust-lines")).expect("register");
        assert!(format.is_runtime());
        assert_eq!(format.name(), "rust-lines");
        assert_eq!(Format::by_name("rust-lines"), Some(format));
        assert_eq!(Format::by_name("gfm"), Some(common::gfm()));
        assert_eq!(common::gfm().name(), "gfm");
        assert_eq!(Target::from(format).as_format(), Some(format));

        let mut doc = Document::parse_str("alpha\nbeta\n", format).expect("parse");
        assert_eq!(doc.render_html().unwrap(), b"<p>alpha</p>\n<p>beta</p>\n");
        assert_eq!(
            doc.serialize_to(common::markdown().target()).unwrap(),
            b"alpha\n\nbeta\n"
        );
        assert_eq!(
            doc.serialize_to(Target::from(format)).unwrap(),
            b"alpha\nbeta\n"
        );

        let mut md = Document::parse_str("# T\n\nx\n", common::markdown()).expect("markdown");
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
        // Markdown's name is taken once Markdown is registered.
        common::markdown();
        struct Taken;
        impl TableLanguage for Taken {
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
        let err = register_table(Taken).unwrap_err();
        assert_eq!(err.error, Error::InvalidLanguage);
        assert!(
            err.message.contains("already a format's"),
            "{}",
            err.message
        );

        struct Panics;
        impl TableLanguage for Panics {
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
        let err = register_table(Panics).unwrap_err();
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

    impl TableLanguage for CrlfLines {
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
        let format = register_table(CrlfLines).expect("register");
        let set = Format::by_name("rust-crlf-crlf").expect("the set is a format");
        assert_ne!(set, format);
        assert_eq!(set.dialect_of(), Some(format));
        assert_eq!(format.dialect_of(), None);
        assert_eq!(format.feature_flags(&["crlf"]), Ok(1));
        assert_eq!(format.feature_flags(&["tabs"]), Err(Error::NotFound));
        assert_eq!(common::djot().feature_flags(&["math"]), Err(Error::UnsupportedFormat));

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
        impl TableLanguage for Unreadable {
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


/// The binding's private JSON string writer, which its tests reach for.
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
