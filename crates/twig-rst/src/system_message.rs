//! The docutils `<system_message>` projection — everything about matching
//! docutils' ERROR OUTPUT FORMAT, kept apart from twig's own diagnostics.
//! Port of `src/languages/rst/system_message.zig`.
//!
//! `diagnostic` holds twig's record of a parse problem. This file holds the
//! facts about docutils rather than about the error: its exact message
//! wording ([`write`]) and the doctree node a message becomes ([`subtree`]).
//!
//! [`recognize`] goes the other way — docutils' wording back into a
//! `(Code, Args)` pair — so the corpus can assert `write(recognize(m)) == m`
//! for every message it claims. It is a HARNESS direction, not a parser one.
//!
//! Placement (which container a message is appended to) is deliberately not
//! implemented: it is per-code knowledge about docutils that needs a parser to
//! be testable. `ids`/`backrefs` are carried verbatim in [`Extras`].

use crate::ast::{Attrs, Builder, KeyVal, Kind, NodeId};

use super::diagnostic::{Args, BlockConstruct, Code, InlineConstruct, Severity, TableDefect};

// ── docutils' wording ──────────────────────────────────────────────────────

/// docutils' spelling of an inline construct inside
/// `Inline %s start-string without end-string.`
fn inline_name(c: InlineConstruct) -> &'static str {
    match c {
        InlineConstruct::Emphasis => "emphasis",
        InlineConstruct::Strong => "strong",
        InlineConstruct::Literal => "literal",
        InlineConstruct::InterpretedText => "interpreted text or phrase reference",
        InlineConstruct::Target => "target",
        // Spelled with the underscore — it is the node name, not prose.
        InlineConstruct::SubstitutionReference => "substitution_reference",
    }
}

/// docutils' spelling of a block construct inside
/// `%s ends without a blank line; unexpected unindent.` — sentence-cased.
fn block_name(c: BlockConstruct) -> &'static str {
    match c {
        BlockConstruct::ExplicitMarkup => "Explicit markup",
        BlockConstruct::BulletList => "Bullet list",
        BlockConstruct::EnumeratedList => "Enumerated list",
        BlockConstruct::DefinitionList => "Definition list",
        BlockConstruct::FieldList => "Field list",
        BlockConstruct::BlockQuote => "Block quote",
        BlockConstruct::LiteralBlock => "Literal block",
    }
}

/// The detail docutils appends after a bare `Malformed table.`
fn table_detail(d: TableDefect) -> &'static str {
    match d {
        TableDefect::Unspecified => "",
        // Not a typo: this detail repeats the phrase.
        TableDefect::ParseIncomplete => "Malformed table; parse incomplete.",
        TableDefect::NoBottomBorder => "No bottom table border found.",
        TableDefect::NoBottomBorderOrBlankLine => "No bottom table border found or no blank line after table bottom.",
        TableDefect::BottomHeaderBorderMismatch => "Bottom/header table border does not match top border.",
        TableDefect::TextInColumnMargin => "Text in column margin in table line {d}.",
        TableDefect::ColumnSpanAlignment => "Column span alignment problem in table line {d}.",
        TableDefect::ColumnSpanIncomplete => "Column span incomplete in table line {d}.",
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn rfind(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > hay.len() {
        return None;
    }
    hay.windows(needle.len()).rposition(|w| w == needle)
}

fn wrong_args(code: Code) -> ! {
    panic!("system_message::write: arguments do not match {code:?}")
}

/// Write docutils' exact message text for `code`/`args` — what goes in the
/// `<system_message>`'s first `<paragraph>`. docutils' own inconsistencies
/// (missing periods, a lowercase opener) are reproduced deliberately.
pub fn write(w: &mut Vec<u8>, code: Code, args: &Args) {
    use Code::*;
    match code {
        InlineStartStringWithoutEndString => {
            let Args::InlineConstruct(c) = args else { wrong_args(code) };
            w.extend_from_slice(format!("Inline {} start-string without end-string.", inline_name(*c)).as_bytes());
        }
        UnexpectedUnindent => {
            let Args::BlockConstruct(c) = args else { wrong_args(code) };
            w.extend_from_slice(
                format!("{} ends without a blank line; unexpected unindent.", block_name(*c)).as_bytes(),
            );
        }
        LineBlockWithoutBlankLine => w.extend_from_slice(b"Line block ends without a blank line."),
        UnexpectedIndentation => w.extend_from_slice(b"Unexpected indentation."),
        BlankLineRequiredAfterTable => w.extend_from_slice(b"Blank line required after table."),
        LiteralBlockExpected => w.extend_from_slice(b"Literal block expected; none found."),
        InconsistentLiteralBlockQuoting => w.extend_from_slice(b"Inconsistent literal block quoting."),
        LiteralBlockHintAfterDefinition => {
            let Args::Name(name) = args else { wrong_args(code) };
            w.extend_from_slice(b"Blank line missing before literal block (after the \"");
            w.extend_from_slice(name);
            w.extend_from_slice(b"\")? Interpreted as a definition list item.");
        }

        UnexpectedSectionTitle => w.extend_from_slice(b"Unexpected section title."),
        UnexpectedSectionTitleOrTransition => w.extend_from_slice(b"Unexpected section title or transition."),
        IncompleteSectionTitle => w.extend_from_slice(b"Incomplete section title."),
        PossibleIncompleteSectionTitle => w.extend_from_slice(
            b"Possible incomplete section title.\nTreating the overline as ordinary text because it's so short.",
        ),
        TitleUnderlineTooShort => w.extend_from_slice(b"Title underline too short."),
        PossibleTitleUnderlineTooShort => w.extend_from_slice(
            b"Possible title underline, too short for the title.\nTreating it as ordinary text because it's so short.",
        ),
        TitleOverlineTooShort => w.extend_from_slice(b"Title overline too short."),
        TitleOverlineUnderlineMismatch => w.extend_from_slice(b"Title overline & underline mismatch."),
        MissingMatchingUnderlineForOverline => {
            w.extend_from_slice(b"Missing matching underline for section title overline.")
        }
        InvalidSectionTitleOrTransitionMarker => w.extend_from_slice(b"Invalid section title or transition marker."),
        // No period; docutils follows it with the offending literal block.
        TitleLevelInconsistent => w.extend_from_slice(b"Title level inconsistent:"),
        PossibleTitleOverlineOrTransition => w.extend_from_slice(
            b"Unexpected possible title overline or transition.\nTreating it as ordinary text because it's so short.",
        ),

        // No trailing period, and the parenthetical is docutils' own.
        EnumeratedListStartNotOrdinal => {
            let Args::Ordinal { expected, text, actual } = args else { wrong_args(code) };
            w.extend_from_slice(format!("Enumerated list start value not ordinal-{expected}: \"").as_bytes());
            w.extend_from_slice(text);
            w.extend_from_slice(format!("\" (ordinal {actual})").as_bytes());
        }

        DuplicateExplicitTargetName => {
            let Args::Name(name) = args else { wrong_args(code) };
            w.extend_from_slice(b"Duplicate explicit target name: \"");
            w.extend_from_slice(name);
            w.extend_from_slice(b"\".");
        }
        DuplicateImplicitTargetName => {
            let Args::Name(name) = args else { wrong_args(code) };
            w.extend_from_slice(b"Duplicate implicit target name: \"");
            w.extend_from_slice(name);
            w.extend_from_slice(b"\".");
        }
        // Lowercase in docutils, unlike every sibling message.
        MalformedHyperlinkTarget => w.extend_from_slice(b"malformed hyperlink target."),

        MalformedTable => {
            let Args::Table { defect, line } = args else { wrong_args(code) };
            w.extend_from_slice(b"Malformed table.");
            let detail = table_detail(*defect);
            if detail.is_empty() {
                return;
            }
            w.push(b'\n');
            if defect.has_line() {
                let at = detail.find("{d}").expect("line-bearing detail has a {d}");
                w.extend_from_slice(&detail.as_bytes()[..at]);
                w.extend_from_slice(line.to_string().as_bytes());
                w.extend_from_slice(&detail.as_bytes()[at + 3..]);
            } else {
                w.extend_from_slice(detail.as_bytes());
            }
        }
        TableWidthsMismatch => {
            let Args::Widths { value, columns } = args else { wrong_args(code) };
            w.push(b'"');
            w.extend_from_slice(value);
            w.extend_from_slice(
                format!("\" widths do not match the number of columns in table ({columns}).").as_bytes(),
            );
        }
        FigureCaptionMustBeParagraph => w.extend_from_slice(b"Figure caption must be a paragraph or empty comment."),
    }
}

/// `write` into an owned buffer.
pub fn write_alloc(code: Code, args: &Args) -> Vec<u8> {
    let mut out = Vec::new();
    write(&mut out, code, args);
    out
}

// ── the inverse, for validation ────────────────────────────────────────────

/// A message parsed back out of docutils' wording.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recognized {
    pub code: Code,
    pub args: Args,
}

/// Messages with no interpolation: an exact-match table, kept as data so
/// `recognize` and `write` cannot drift.
const LITERALS: [(Code, &str); 19] = [
    (Code::LineBlockWithoutBlankLine, "Line block ends without a blank line."),
    (Code::UnexpectedIndentation, "Unexpected indentation."),
    (Code::BlankLineRequiredAfterTable, "Blank line required after table."),
    (Code::LiteralBlockExpected, "Literal block expected; none found."),
    (Code::InconsistentLiteralBlockQuoting, "Inconsistent literal block quoting."),
    (Code::UnexpectedSectionTitle, "Unexpected section title."),
    (Code::UnexpectedSectionTitleOrTransition, "Unexpected section title or transition."),
    (Code::IncompleteSectionTitle, "Incomplete section title."),
    (
        Code::PossibleIncompleteSectionTitle,
        "Possible incomplete section title.\nTreating the overline as ordinary text because it's so short.",
    ),
    (Code::TitleUnderlineTooShort, "Title underline too short."),
    (
        Code::PossibleTitleUnderlineTooShort,
        "Possible title underline, too short for the title.\nTreating it as ordinary text because it's so short.",
    ),
    (Code::TitleOverlineTooShort, "Title overline too short."),
    (Code::TitleOverlineUnderlineMismatch, "Title overline & underline mismatch."),
    (Code::MissingMatchingUnderlineForOverline, "Missing matching underline for section title overline."),
    (Code::InvalidSectionTitleOrTransitionMarker, "Invalid section title or transition marker."),
    (Code::TitleLevelInconsistent, "Title level inconsistent:"),
    (
        Code::PossibleTitleOverlineOrTransition,
        "Unexpected possible title overline or transition.\nTreating it as ordinary text because it's so short.",
    ),
    (Code::MalformedHyperlinkTarget, "malformed hyperlink target."),
    (Code::FigureCaptionMustBeParagraph, "Figure caption must be a paragraph or empty comment."),
];

/// Everything between `prefix` and `suffix`, or `None` if `text` isn't that
/// shape.
fn between<'a>(text: &'a [u8], prefix: &[u8], suffix: &[u8]) -> Option<&'a [u8]> {
    if text.len() < prefix.len() + suffix.len() {
        return None;
    }
    if !text.starts_with(prefix) || !text.ends_with(suffix) {
        return None;
    }
    Some(&text[prefix.len()..text.len() - suffix.len()])
}

fn parse_u32(raw: &[u8]) -> Option<u32> {
    super::doctree::parse_u32_zig(raw)
}

/// Parse docutils' wording back into a code and its arguments. `None` means
/// twig has no Tier A code for this message.
pub fn recognize(text: &[u8]) -> Option<Recognized> {
    for (code, lit) in LITERALS {
        if text == lit.as_bytes() {
            return Some(Recognized { code, args: Args::None });
        }
    }

    if let Some(name) = between(text, b"Inline ", b" start-string without end-string.") {
        for c in InlineConstruct::ALL {
            if name == inline_name(c).as_bytes() {
                return Some(Recognized {
                    code: Code::InlineStartStringWithoutEndString,
                    args: Args::InlineConstruct(c),
                });
            }
        }
        return None;
    }

    if let Some(name) = between(text, b"", b" ends without a blank line; unexpected unindent.") {
        for c in BlockConstruct::ALL {
            if name == block_name(c).as_bytes() {
                return Some(Recognized { code: Code::UnexpectedUnindent, args: Args::BlockConstruct(c) });
            }
        }
        return None;
    }

    if let Some(name) = between(text, b"Duplicate explicit target name: \"", b"\".") {
        return Some(Recognized { code: Code::DuplicateExplicitTargetName, args: Args::Name(name.to_vec()) });
    }
    if let Some(name) = between(text, b"Duplicate implicit target name: \"", b"\".") {
        return Some(Recognized { code: Code::DuplicateImplicitTargetName, args: Args::Name(name.to_vec()) });
    }
    if let Some(name) = between(
        text,
        b"Blank line missing before literal block (after the \"",
        b"\")? Interpreted as a definition list item.",
    ) {
        return Some(Recognized { code: Code::LiteralBlockHintAfterDefinition, args: Args::Name(name.to_vec()) });
    }

    if let Some(rest) = between(text, b"Enumerated list start value not ordinal-", b")") {
        // `<expected>: "<text>" (ordinal <actual>`
        let colon = find(rest, b": \"")?;
        let expected = parse_u32(&rest[..colon])?;
        let tail = &rest[colon + 3..];
        let close = rfind(tail, b"\" (ordinal ")?;
        let actual = parse_u32(&tail[close + 11..])?;
        return Some(Recognized {
            code: Code::EnumeratedListStartNotOrdinal,
            args: Args::Ordinal { expected, text: tail[..close].to_vec(), actual },
        });
    }

    const WIDTHS_MID: &[u8] = b"\" widths do not match the number of columns in table (";
    if let Some(rest) = between(text, b"\"", b").") {
        if let Some(at) = find(rest, WIDTHS_MID) {
            let columns = parse_u32(&rest[at + WIDTHS_MID.len()..])?;
            return Some(Recognized {
                code: Code::TableWidthsMismatch,
                args: Args::Widths { value: rest[..at].to_vec(), columns },
            });
        }
    }

    if text.starts_with(b"Malformed table.") {
        let rest = &text[b"Malformed table.".len()..];
        if rest.is_empty() {
            return Some(Recognized {
                code: Code::MalformedTable,
                args: Args::Table { defect: TableDefect::Unspecified, line: 0 },
            });
        }
        if rest.len() < 2 || rest[0] != b'\n' {
            return None;
        }
        let detail = &rest[1..];
        for d in TableDefect::ALL {
            let pattern = table_detail(d);
            if pattern.is_empty() {
                continue;
            }
            if d.has_line() {
                let at = pattern.find("{d}").unwrap();
                if let Some(num) = between(detail, &pattern.as_bytes()[..at], &pattern.as_bytes()[at + 3..]) {
                    let line = parse_u32(num)?;
                    return Some(Recognized { code: Code::MalformedTable, args: Args::Table { defect: d, line } });
                }
            } else if detail == pattern.as_bytes() {
                return Some(Recognized { code: Code::MalformedTable, args: Args::Table { defect: d, line: 0 } });
            }
        }
        return None;
    }

    None
}

// ── the doctree node ───────────────────────────────────────────────────────

/// The doctree-only facts a `<system_message>` carries that a `Diagnostic`
/// does not. Carried verbatim rather than derived.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Extras {
    /// docutils' `line` attribute (1-based) — `parse_diagnostic::line_of`
    /// over a diagnostic's span.
    pub line: u32,
    /// docutils' `source` attribute — `"test data"` throughout the corpus.
    pub source: Vec<u8>,
    /// Space-joined id lists linking the message to its `<problematic>` node.
    /// Empty when absent.
    pub ids: Vec<u8>,
    pub backrefs: Vec<u8>,
    /// The quoted offending source docutils attaches as a `<literal_block>`.
    /// Empty when the message has none.
    pub excerpt: Vec<u8>,
}

/// Build the `<system_message>` subtree for one diagnostic, returning its id in
/// `b`. The caller chooses the parent.
pub fn subtree(b: &mut Builder, code: Code, severity: Severity, args: &Args, extras: &Extras) -> NodeId {
    let message = write_alloc(code, args);

    let text = b.add_leaf(Kind::Str(message));
    let para = b.add_container(Kind::Para, &[text]);

    let mut kids = vec![para];
    if !extras.excerpt.is_empty() {
        let block = b.add_container(Kind::CodeBlock { lang: None, text: extras.excerpt.clone() }, &[]);
        b.set_attrs(block, Attrs { entries: vec![KeyVal::new(b"xml:space", Some(b"preserve"))] });
        kids.push(block);
    }

    let id = b.add_container(Kind::Container(crate::ast::Container::named(b"system_message")), &kids);

    // Written in docutils' sorted order; `doctree::encode` sorts anyway.
    let mut entries = Vec::new();
    if !extras.backrefs.is_empty() {
        entries.push(KeyVal::new(b"backrefs", Some(&extras.backrefs)));
    }
    if !extras.ids.is_empty() {
        entries.push(KeyVal::new(b"ids", Some(&extras.ids)));
    }
    entries.push(KeyVal::new(b"level", Some(severity.level().to_string().as_bytes())));
    entries.push(KeyVal::new(b"line", Some(extras.line.to_string().as_bytes())));
    entries.push(KeyVal::new(b"source", Some(&extras.source)));
    entries.push(KeyVal::new(b"type", Some(severity.type_name().as_bytes())));
    b.set_attrs(id, Attrs { entries });
    id
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::doctree;

    #[test]
    fn write_and_recognize_agree_for_every_code() {
        let samples = [
            (Code::InlineStartStringWithoutEndString, Args::InlineConstruct(InlineConstruct::InterpretedText)),
            (Code::UnexpectedUnindent, Args::BlockConstruct(BlockConstruct::BlockQuote)),
            (Code::LiteralBlockHintAfterDefinition, Args::Name(b"::".to_vec())),
            (Code::EnumeratedListStartNotOrdinal, Args::Ordinal { expected: 1, text: b"b".to_vec(), actual: 2 }),
            (Code::DuplicateExplicitTargetName, Args::Name(b"target".to_vec())),
            (Code::DuplicateImplicitTargetName, Args::Name(b"title".to_vec())),
            (Code::MalformedTable, Args::Table { defect: TableDefect::Unspecified, line: 0 }),
            (Code::MalformedTable, Args::Table { defect: TableDefect::NoBottomBorder, line: 0 }),
            (Code::MalformedTable, Args::Table { defect: TableDefect::ColumnSpanAlignment, line: 4 }),
            (Code::TableWidthsMismatch, Args::Widths { value: b"widths".to_vec(), columns: 2 }),
        ];
        for (code, args) in samples {
            let text = write_alloc(code, &args);
            let back = recognize(&text).expect("recognized");
            assert_eq!(back.code, code);
            assert_eq!(write_alloc(back.code, &back.args), text);
        }
        for (code, lit) in LITERALS {
            let text = write_alloc(code, &Args::None);
            assert_eq!(text, lit.as_bytes());
            assert_eq!(recognize(&text).unwrap().code, code);
        }
    }

    #[test]
    fn docutils_inconsistencies_are_reproduced_not_tidied() {
        assert_eq!(write_alloc(Code::MalformedHyperlinkTarget, &Args::None), b"malformed hyperlink target.");
        assert_eq!(
            write_alloc(
                Code::EnumeratedListStartNotOrdinal,
                &Args::Ordinal { expected: 1, text: b"b".to_vec(), actual: 2 }
            ),
            b"Enumerated list start value not ordinal-1: \"b\" (ordinal 2)"
        );
        assert_eq!(
            write_alloc(Code::MalformedTable, &Args::Table { defect: TableDefect::ParseIncomplete, line: 0 }),
            b"Malformed table.\nMalformed table; parse incomplete."
        );
    }

    #[test]
    fn recognize_declines_a_tier_b_message_rather_than_guessing() {
        assert_eq!(recognize(b"Unknown directive type \"foo\"."), None);
        assert_eq!(recognize(b"Content block expected for the \"note\" directive; none found."), None);
    }

    #[test]
    fn subtree_builds_a_system_message_node_that_encodes_as_docutils_writes_it() {
        let mut b = Builder::new();
        let msg = subtree(
            &mut b,
            Code::UnexpectedIndentation,
            Severity::Err,
            &Args::None,
            &Extras { line: 3, source: b"test data".to_vec(), ..Default::default() },
        );
        let root = b.add_container(Kind::Doc, &[msg]);
        b.set_attrs(root, Attrs { entries: vec![KeyVal::new(b"source", Some(b"test data"))] });
        let ast = b.finish(root);
        let out = doctree::encode_alloc(&ast).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "<document source=\"test data\">\n    <system_message level=\"3\" line=\"3\" source=\"test data\" type=\"ERROR\">\n        <paragraph>\n            Unexpected indentation.\n"
        );
    }

    #[test]
    fn an_excerpt_becomes_the_literal_block_docutils_quotes() {
        let mut b = Builder::new();
        let msg = subtree(
            &mut b,
            Code::TitleLevelInconsistent,
            Severity::Severe,
            &Args::None,
            &Extras { line: 5, source: b"test data".to_vec(), excerpt: b"Title\n-----".to_vec(), ..Default::default() },
        );
        let ast = b.finish(msg);
        let out = doctree::encode_alloc(&ast).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "<system_message level=\"4\" line=\"5\" source=\"test data\" type=\"SEVERE\">\n    <paragraph>\n        Title level inconsistent:\n    <literal_block xml:space=\"preserve\">\n        Title\n        -----\n"
        );
    }
}
