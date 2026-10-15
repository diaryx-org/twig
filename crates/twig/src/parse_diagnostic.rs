//! Shared parse-diagnostic machinery — the language-agnostic half of a
//! diagnostic system: locating a byte offset in source text, and rendering the
//! compiler-style `file:line:col: label: message` report with a caret.
//! Port of `src/parse_diagnostic.zig`.
//!
//! Each language keeps its OWN `Code` enums and `describe()`/`short_label()`
//! teaching messages and its own `Diagnostic`/`Report` shapes; only the
//! code-independent machinery lives here, so there is exactly one
//! implementation of "find line/col for a byte offset".
//!
//! This is PARSE-time (the input is malformed or suspicious), not
//! conversion-time lossiness, which lives in `diagnostics`: a parse diagnostic
//! anchors to a byte span in the SOURCE, a conversion warning to a node PATH.

/// 1-based line/column plus the full offending source line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Location<'a> {
    pub line: usize,
    pub column: usize,
    pub line_text: &'a [u8],
}

/// Locate `offset` in `source`. A cursor resting exactly past a newline is
/// ambiguous: it could mean "noticed while finishing the previous line" (an
/// unclosed construct discovered only at EOF) — report end-of-that-line — OR a
/// token that genuinely STARTS at column 1 of a real next line (common in rST:
/// section underlines, `.. ` explicit markup, transitions). Only backtrack in the
/// FORMER case, when there is nothing at `at` to point at (EOF, or another
/// blank line).
pub fn locate_offset(source: &[u8], offset: usize) -> Location<'_> {
    let mut at = offset.min(source.len());
    if at > 0 && source[at - 1] == b'\n' && (at >= source.len() || source[at] == b'\n' || source[at] == b'\r') {
        at -= 1;
    }
    let mut line = 1;
    let mut line_start = 0;
    for (i, &c) in source[..at].iter().enumerate() {
        if c == b'\n' {
            line += 1;
            line_start = i + 1;
        }
    }
    let line_end = source[line_start..].iter().position(|&c| c == b'\n').map_or(source.len(), |p| line_start + p);
    Location { line, column: at - line_start + 1, line_text: &source[line_start..line_end] }
}

/// The 1-based line number `offset` falls on — docutils records exactly this
/// on every `<system_message>` (`line="3"`).
pub fn line_of(source: &[u8], offset: usize) -> usize {
    locate_offset(source, offset).line
}

/// The compiler-style report every language shares: `file:line:col: <label>:
/// <message>`, then the offending source line and a caret marking the column.
pub fn render_report(w: &mut Vec<u8>, loc: Location<'_>, file: &[u8], label: &[u8], message: &[u8]) {
    w.extend_from_slice(file);
    w.extend_from_slice(format!(":{}:{}: ", loc.line, loc.column).as_bytes());
    w.extend_from_slice(label);
    w.extend_from_slice(b": ");
    w.extend_from_slice(message);
    w.push(b'\n');
    // The offending line, capped so a pathological line can't flood the
    // terminal. The caret line mirrors tabs so it stays aligned under them.
    const MAX_SHOWN: usize = 160;
    let shown = &loc.line_text[..loc.line_text.len().min(MAX_SHOWN)];
    if shown.is_empty() {
        return; // EOF/blank line: nothing to point into
    }
    w.extend_from_slice(b"    ");
    w.extend_from_slice(shown);
    if shown.len() < loc.line_text.len() {
        w.extend_from_slice("…".as_bytes());
    }
    w.push(b'\n');
    if loc.column - 1 <= shown.len() {
        w.extend_from_slice(b"    ");
        for &c in &shown[..loc.column - 1] {
            w.push(if c == b'\t' { b'\t' } else { b' ' });
        }
        w.extend_from_slice(b"^\n");
    }
}

/// `render_report`, returning the bytes.
pub fn render_report_alloc(source: &[u8], offset: usize, file: &[u8], label: &[u8], message: &[u8]) -> Vec<u8> {
    let loc = locate_offset(source, offset);
    let mut out = Vec::new();
    render_report(&mut out, loc, file, label, message);
    out
}

/// A fully-resolved diagnostic ready for CLI/LSP rendering — language-agnostic.
/// Pairs a parse-time `[offset, end)` span with the language's own
/// `describe(code)` and `short_label(code)` strings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rendered {
    pub offset: usize,
    pub end: Option<usize>,
    pub message: Vec<u8>,
    pub short_label: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locate_offset_finds_line_column_and_backtracks_past_a_trailing_newline() {
        let src = b"abc\ndef\nghi";
        let loc = locate_offset(src, 5);
        assert_eq!(loc.line, 2);
        assert_eq!(loc.column, 2);
        assert_eq!(loc.line_text, b"def");

        let loc = locate_offset(b"abc\n", 4);
        assert_eq!(loc.line, 1);
        assert_eq!(loc.column, 4);

        let loc = locate_offset(b"Title\n=====\n", 6);
        assert_eq!(loc.line, 2);
        assert_eq!(loc.column, 1);
        assert_eq!(loc.line_text, b"=====");
    }

    #[test]
    fn line_of_is_locate_offsets_line_number() {
        assert_eq!(line_of(b"a\nb\nc\n", 4), 3);
    }

    #[test]
    fn render_report_alloc_renders_file_line_col_plus_the_source_line_and_caret() {
        let rendered =
            render_report_alloc(b"Line 1.\n    Indented.\n", 8, b"test.rst", b"error", b"Unexpected indentation.");
        assert_eq!(
            String::from_utf8(rendered).unwrap(),
            "test.rst:2:1: error: Unexpected indentation.\n        Indented.\n    ^\n"
        );
    }
}
