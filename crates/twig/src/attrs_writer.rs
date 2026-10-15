//! The ONE algorithm that spells a node's attributes back into source — the
//! serializer-side counterpart to `ast/editor`. Port of `src/attrs_writer.zig`.
//!
//! `syntax::AttrSpelling` is the alphabet; this is the algorithm that reads
//! it, and neither knows which format it is serving. It replaced djot's
//! `writeDjotAttrs` and Markdown's `writeDirectiveAttrs`: two walks over the
//! same side table differing only in a quoting policy. rST's option block is
//! the same walk again with no braces and a newline between entries.
//!
//! HTML is deliberately NOT a client: `html::serializer`'s
//! `render_attributes` merges a synthesized `extra` list and dedups keys,
//! which is HTML-output machinery rather than surface spelling.

use crate::ast::{Attrs, KeyVal};

// TODO(port): `AttrSpelling`/`Quoting` belong to `crate::syntax` (port of
// `src/syntax.zig`, another agent's module). Defined here until it lands;
// switch to a `pub use crate::syntax::{AttrSpelling, Quoting};` then.

/// Whether a value needs `"` around it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum Quoting {
    #[default]
    Never,
    Always,
    WhenNeeded,
}

/// How a format spells an attribute block. See `syntax.zig`'s `AttrSpelling`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AttrSpelling {
    /// Opens and closes the whole block (`{`/`}`), both empty for field lines.
    pub open: &'static str,
    pub close: &'static str,
    /// Written between two entries.
    pub between: &'static str,
    /// Written before every key.
    pub key_prefix: &'static str,
    /// Written between a key and its value (omitted for a bare entry).
    pub key_value: &'static str,
    pub quoting: Quoting,
    /// Bytes to backslash-escape inside a quoted value.
    pub quote_escapes: &'static str,
    /// The `#name` shorthand for the `id` key.
    pub id_sigil: Option<&'static str>,
    /// The `.name` shorthand, written once per space-separated class.
    pub class_sigil: Option<&'static str>,
}

impl AttrSpelling {
    pub const DEFAULT: AttrSpelling = AttrSpelling {
        open: "",
        close: "",
        between: " ",
        key_prefix: "",
        key_value: "=",
        quoting: Quoting::Never,
        quote_escapes: "",
        id_sigil: None,
        class_sigil: None,
    };
}

impl Default for AttrSpelling {
    fn default() -> AttrSpelling {
        AttrSpelling::DEFAULT
    }
}

/// Spell `attrs` per `sp`, writing nothing at all when there is nothing to say.
///
/// `indent` is written after every `between` — the continuation prefix a
/// line-per-entry form needs. It is a property of the POSITION being written
/// into, not of the format.
pub fn write(w: &mut Vec<u8>, attrs: &Attrs, sp: &AttrSpelling, indent: &[u8]) {
    if attrs.is_empty() {
        return;
    }
    // An entry can spell NOTHING (see `will_write`), so the opener and the
    // separators are emitted only once the entry is known to write.
    let mut wrote_any = false;
    for kv in &attrs.entries {
        if !will_write(kv, sp) {
            continue;
        }
        if !wrote_any {
            w.extend_from_slice(sp.open.as_bytes());
        } else {
            w.extend_from_slice(sp.between.as_bytes());
            w.extend_from_slice(indent);
        }
        wrote_any = true;
        write_entry(w, kv, sp, indent);
    }
    if wrote_any {
        w.extend_from_slice(sp.close.as_bytes());
    }
}

/// Spell `attrs` as an HTML tag's interior — ` key="value"`, or a bare ` key`
/// — with `&<>"` escaped. Writes nothing for an empty set. The fallback
/// spelling for an UNCLASSIFIED container (an HTML/XML element) passing
/// through a lightweight target.
pub fn write_html_attrs(w: &mut Vec<u8>, attrs: &Attrs) {
    for kv in &attrs.entries {
        w.push(b' ');
        w.extend_from_slice(&kv.key);
        let Some(value) = &kv.value else { continue };
        w.extend_from_slice(b"=\"");
        for &c in value {
            match c {
                b'&' => w.extend_from_slice(b"&amp;"),
                b'<' => w.extend_from_slice(b"&lt;"),
                b'>' => w.extend_from_slice(b"&gt;"),
                b'"' => w.extend_from_slice(b"&quot;"),
                _ => w.push(c),
            }
        }
        w.push(b'"');
    }
}

fn class_tokens(v: &[u8]) -> impl Iterator<Item = &[u8]> {
    v.split(|&c| c == b' ').filter(|t| !t.is_empty())
}

/// Whether `kv` spells anything under `sp`: an `id` with no value and a
/// `class` holding no classes would emit a dangling sigil, so they spell
/// nothing (unreachable from a parser; a hand-built tree can produce them).
fn will_write(kv: &KeyVal, sp: &AttrSpelling) -> bool {
    if sp.id_sigil.is_some() && kv.key == b"id" {
        return matches!(&kv.value, Some(v) if !v.is_empty());
    }
    if sp.class_sigil.is_some() && kv.key == b"class" {
        return match &kv.value {
            Some(v) => class_tokens(v).next().is_some(),
            None => false,
        };
    }
    true
}

fn write_entry(w: &mut Vec<u8>, kv: &KeyVal, sp: &AttrSpelling, indent: &[u8]) {
    if let Some(sigil) = sp.id_sigil {
        if kv.key == b"id" {
            w.extend_from_slice(sigil.as_bytes());
            w.extend_from_slice(kv.value.as_ref().unwrap());
            return;
        }
    }
    if let Some(sigil) = sp.class_sigil {
        if kv.key == b"class" {
            // `class="a b"` is ONE entry holding several classes; they come
            // back apart here, each taking the outer separator-plus-indent.
            let mut first = true;
            for cls in class_tokens(kv.value.as_ref().unwrap()) {
                if !first {
                    w.extend_from_slice(sp.between.as_bytes());
                    w.extend_from_slice(indent);
                }
                first = false;
                w.extend_from_slice(sigil.as_bytes());
                w.extend_from_slice(cls);
            }
            return;
        }
    }

    w.extend_from_slice(sp.key_prefix.as_bytes());
    w.extend_from_slice(&kv.key);
    // A bare attribute is the key alone — HTML's `disabled`.
    let Some(value) = &kv.value else { return };
    w.extend_from_slice(sp.key_value.as_bytes());
    if quotes(sp.quoting, value) {
        w.push(b'"');
        for &c in value {
            if sp.quote_escapes.as_bytes().contains(&c) {
                w.push(b'\\');
            }
            w.push(c);
        }
        w.push(b'"');
    } else {
        w.extend_from_slice(value);
    }
}

fn quotes(q: Quoting, value: &[u8]) -> bool {
    match q {
        Quoting::Never => false,
        Quoting::Always => true,
        Quoting::WhenNeeded => needs_quoting(value),
    }
}

/// A bare value may hold only name characters; empty or anything else must
/// be quoted. Matches `markdown/attributes`' `is_name_char`.
fn needs_quoting(v: &[u8]) -> bool {
    if v.is_empty() {
        return true;
    }
    v.iter().any(|&c| !(c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b':'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spell(sp: &AttrSpelling, entries: &[(&str, Option<&str>)], indent: &str) -> String {
        let attrs = Attrs {
            entries: entries.iter().map(|(k, v)| KeyVal::new(k.as_bytes(), v.map(|v| v.as_bytes()))).collect(),
        };
        let mut out = Vec::new();
        write(&mut out, &attrs, sp, indent.as_bytes());
        String::from_utf8(out).unwrap()
    }

    const DJOT: AttrSpelling = AttrSpelling {
        open: "{",
        close: "}",
        quoting: Quoting::Always,
        id_sigil: Some("#"),
        class_sigil: Some("."),
        ..AttrSpelling::DEFAULT
    };

    const MARKDOWN: AttrSpelling = AttrSpelling {
        open: "{",
        close: "}",
        quoting: Quoting::WhenNeeded,
        quote_escapes: "\"\\",
        id_sigil: Some("#"),
        class_sigil: Some("."),
        ..AttrSpelling::DEFAULT
    };

    const RST: AttrSpelling = AttrSpelling { between: "\n", key_prefix: ":", key_value: ": ", ..AttrSpelling::DEFAULT };

    #[test]
    fn djot_quotes_every_value_and_spells_the_shorthands() {
        let out = spell(&DJOT, &[("id", Some("intro")), ("class", Some("lead wide")), ("lang", Some("en"))], "");
        assert_eq!(out, "{#intro .lead .wide lang=\"en\"}");
    }

    #[test]
    fn markdown_quotes_only_what_the_bare_grammar_cannot_hold() {
        let out = spell(&MARKDOWN, &[("key", Some("val")), ("title", Some("two words"))], "");
        assert_eq!(out, "{key=val title=\"two words\"}");
    }

    #[test]
    fn a_quoted_value_escapes_per_the_tables_alphabet() {
        assert_eq!(spell(&MARKDOWN, &[("t", Some("a\"b"))], ""), "{t=\"a\\\"b\"}");
        assert_eq!(spell(&DJOT, &[("t", Some("a\"b"))], ""), "{t=\"a\"b\"}");
    }

    #[test]
    fn a_bare_attribute_is_the_key_alone() {
        assert_eq!(spell(&MARKDOWN, &[("disabled", None)], ""), "{disabled}");
    }

    #[test]
    fn an_rst_shaped_option_block_is_the_same_walk_with_no_braces() {
        let out = spell(
            &RST,
            &[("width", Some("50%")), ("class", Some("new")), ("name", Some("eq:Eulers law"))],
            "   ",
        );
        assert_eq!(out, ":width: 50%\n   :class: new\n   :name: eq:Eulers law");
    }

    #[test]
    fn nothing_is_written_for_an_empty_or_degenerate_set() {
        assert_eq!(spell(&DJOT, &[], ""), "");
        assert_eq!(spell(&DJOT, &[("id", None), ("class", Some(""))], ""), "");
    }

    #[test]
    fn html_attrs_escape_and_bare() {
        let attrs = Attrs { entries: vec![KeyVal::new(b"controls", None), KeyVal::new(b"title", Some(b"a\"<&>"))] };
        let mut out = Vec::new();
        write_html_attrs(&mut out, &attrs);
        assert_eq!(out, b" controls title=\"a&quot;&lt;&amp;&gt;\"");
    }
}
