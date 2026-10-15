//! Render settings a document carries in its own metadata.
//!
//! A document says how it should be read under a `twig` key:
//!
//! ```yaml
//! ---
//! title: Notes
//! twig:
//!   dialect: gfm
//!   features: [math, highlight]
//! ---
//! ```
//!
//! `dialect` names a row of the host's language (`gfm`, `commonmark`), and
//! `features` names the features that row lays over its own — Markdown's
//! extensions, or a runtime language's declared features — by the names
//! [`twig::Format::feature_flags`] reads. Settings only add: a caller's own
//! features are laid under them ([`Settings::apply`]), and a name twig does
//! not know is reported in `ignored`, never an error, since a document read
//! by an older twig should still render.

/// What a document's `twig` key asks for.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Settings {
    /// The row the document asks to be read as, when it names one of its own
    /// language's rows.
    pub dialect: Option<twig::Format>,
    /// The features it asks for, by name.
    pub features: Vec<String>,
    /// Names under `twig` this twig does not act on: unknown keys, a dialect
    /// of another language, a feature value that is not a string, a feature
    /// the row does not declare.
    pub ignored: Vec<String>,
}

impl Settings {
    /// The settings `meta` — a document's parsed metadata — holds for a host
    /// of format `host`. A document with no `twig` key has none.
    pub fn read(meta: &fig::Value, host: twig::Format) -> Settings {
        let mut out = Settings::default();
        let Some(root) = meta.get("twig") else {
            return out;
        };
        let Some(entries) = root.as_mapping() else {
            out.ignored.push("twig".to_string());
            return out;
        };
        for (key, value) in entries {
            let name = key.as_str().unwrap_or("");
            match name {
                "dialect" => {
                    out.dialect = value.as_str().and_then(|s| dialect_of(host, s));
                    if out.dialect.is_none() {
                        out.ignored.push(name.to_string());
                    }
                }
                "features" => out.read_features(value),
                _ => out.ignored.push(name.to_string()),
            }
        }
        out
    }

    fn read_features(&mut self, value: &fig::Value) {
        // A single feature may be written on its own, without a list.
        if let Some(s) = value.as_str() {
            self.features.push(s.to_string());
            return;
        }
        let Some(items) = value.as_seq() else {
            self.ignored.push("features".to_string());
            return;
        };
        for item in items {
            match item.as_str() {
                Some(s) => self.features.push(s.to_string()),
                None => self.ignored.push("features".to_string()),
            }
        }
    }

    /// The format and features to read a document of `host` with, given the
    /// caller's own `features`: the document's dialect, when it names one,
    /// and its features laid over the caller's. A feature the resulting row
    /// does not declare is added to `ignored`.
    pub fn apply(&mut self, host: twig::Format, features: &[&str]) -> (twig::Format, Vec<String>) {
        let format = self.dialect.unwrap_or(host);
        let mut on: Vec<String> = Vec::new();
        let names = features
            .iter()
            .copied()
            .chain(self.features.iter().map(String::as_str));
        let mut ignored = Vec::new();
        for name in names {
            if on.iter().any(|n| n == name) {
                continue;
            }
            if format.feature_flags(&[name]).is_ok() {
                on.push(name.to_string());
            } else if !ignored.iter().any(|n: &String| n == name) {
                ignored.push(name.to_string());
            }
        }
        self.ignored.extend(ignored);
        (format, on)
    }
}

/// `name` as a row of `host`'s language: `host` itself, or a dialect of the
/// same language. `None` for an unknown name or another language's row.
fn dialect_of(host: twig::Format, name: &str) -> Option<twig::Format> {
    let f = twig::Format::by_name(name)?;
    (language_of(f) == language_of(host)).then_some(f)
}

fn language_of(f: twig::Format) -> twig::Format {
    f.dialect_of().unwrap_or(f)
}
