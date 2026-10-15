//! The FFI binding's own tests for this module (bindings/rust/twig/src/helper.rs),
//! run unchanged against the pure-Rust crate as an outside consumer.

    use twig::helper::spawn;
use twig::Error;
    use twig::{Document, Target};

    /// A read-only language in `sh` whose every document is `x`; `once`
    /// answers one request and exits, which is what a crashing helper looks
    /// like to its host.
    fn script(name: &str, once: bool) -> String {
        let answer = format!(
            r#"case "$line" in
  *describe*) printf '%s\n' '{{"ok":true,"description":{{"name":"{name}","caps":{{"read":true}},"samples":["x"]}}}}' ;;
  *parse*) printf '%s\n' '{{"ok":true,"table":{{"nodes":[{{"kind":"doc","span":[0,1]}},{{"kind":"para","parent":0,"span":[0,1]}},{{"kind":"str","parent":1,"span":[0,1],"text":"x"}}]}}}}' ;;
  *) printf '%s\n' '{{"ok":false,"message":"{name} only reads"}}' ;;
esac"#
        );
        if once {
            format!("IFS= read -r line\n{answer}\n")
        } else {
            format!("while IFS= read -r line; do\n{answer}\ndone\n")
        }
    }

    #[test]
    fn a_spawned_helper_is_a_format() {
        let format = spawn(["sh", "-c", &script("rust-shx", false)]).expect("spawn");
        assert_eq!(format.name(), "rust-shx");
        let mut doc = Document::parse_str("x", format).expect("parse");
        assert_eq!(doc.render_html().unwrap(), b"<p>x</p>\n");
        assert_eq!(doc.serialize_to(Target::Markdown).unwrap(), b"x\n");
        assert_eq!(
            doc.serialize_to(Target::from(format)).err(),
            Some(Error::UnsupportedFormat)
        );
    }

    #[test]
    fn a_helper_that_exits_is_started_again() {
        // Every process answers one line: describe, the load check's parse,
        // and this test's parse are each a new one.
        let format = spawn(["sh", "-c", &script("rust-shx-once", true)]).expect("spawn");
        let mut doc = Document::parse_str("x", format).expect("parse after a restart");
        assert_eq!(doc.render_html().unwrap(), b"<p>x</p>\n");
    }

    #[test]
    fn a_helper_that_cannot_answer_is_refused_with_why() {
        let err = spawn(["sh", "-c", "exit 0"]).unwrap_err();
        assert_eq!(err.error, Error::InvalidLanguage);
        assert!(err.message.contains("exited again"), "{}", err.message);
        let err = spawn(["/nonexistent/twig-helper"]).unwrap_err();
        assert!(err.message.contains("could not start"), "{}", err.message);
    }

