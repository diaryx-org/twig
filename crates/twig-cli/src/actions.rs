//! The verbs. Each prints its diagnostics at the site that detects them and
//! returns `Err(ActionFailed)` to unwind.

use std::io::{Read, Write};

use twig::ast::{Ast, NodeId, select};
use twig::document::Document;
use twig::format::{self, Format, ParseConfig, Target};

use crate::format::OutputMode;
use crate::options::{ConvertOptions, EditOp, EditOptions, FilterOptions, IdentifyOptions, LangOptions, QueryOptions};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionFailed;

pub type ActionResult = Result<(), ActionFailed>;

const MAX_SOURCE_BYTES: u64 = 16 * 1024 * 1024;

pub fn run_version(stdout: &mut dyn Write) {
    let _ = writeln!(stdout, "twig {}", env!("CARGO_PKG_VERSION"));
}

pub fn run_lang(stdout: &mut dyn Write, stderr: &mut dyn Write, opts: &LangOptions) -> ActionResult {
    match opts {
        LangOptions::Table(c) => run_convert(stdout, stderr, c),
        LangOptions::Syntax(f) => {
            let mut out = Vec::new();
            twig::syntax_json::encode(&mut out, format::syntax_for(*f), Default::default());
            out.push(b'\n');
            stdout.write_all(&out).map_err(|_| ActionFailed)
        }
        LangOptions::List => crate::languages::list(stdout).map_err(|_| ActionFailed),
        LangOptions::Check(c) => {
            use crate::languages::CheckError;
            match crate::languages::check(stdout, stderr, c.name.as_deref(), &c.command, c.against, &c.files) {
                Ok(()) => Ok(()),
                Err(CheckError::CheckFailed) => Err(ActionFailed),
                Err(CheckError::Write(e)) => {
                    let _ = writeln!(stderr, "error: failed to write output: {}", io_error_name(&e));
                    Err(ActionFailed)
                }
            }
        }
    }
}

pub fn run_identify(stdout: &mut dyn Write, opts: &IdentifyOptions) {
    let _ = writeln!(stdout, "{}", opts.input.name());
}

pub fn run_convert(stdout: &mut dyn Write, stderr: &mut dyn Write, opts: &ConvertOptions) -> ActionResult {
    let source = read_source(&opts.file, stderr)?;
    convert_source(
        &source,
        &opts.file,
        opts.input,
        &opts.parse_config,
        opts.output,
        opts.output_target,
        opts.warn,
        stdout,
        stderr,
    )
}

fn warn_about_loss(
    doc: &format::ParsedDoc,
    output: OutputMode,
    output_target: Option<Target>,
    input: Format,
    stderr: &mut dyn Write,
) {
    let target = match output {
        OutputMode::Ast | OutputMode::Table => return,
        OutputMode::Html => Target::Html,
        OutputMode::Canonical => output_target.unwrap_or_else(|| format::target_for(input)),
    };
    let Ok(warnings) = twig::diagnostics::analyze(&doc.doc.ast, doc.doc.ast.root, target) else { return };
    for w in warnings {
        let _ = writeln!(stderr, "warning: {}", w.render(target));
    }
}

#[allow(clippy::too_many_arguments)]
pub fn convert_source(
    source: &[u8],
    display_name: &str,
    input: Format,
    parse_config: &ParseConfig,
    output: OutputMode,
    output_target: Option<Target>,
    warn: bool,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> ActionResult {
    let doc = match format::parse(input, parse_config, source) {
        Ok(d) => d,
        Err(e) => {
            let _ = writeln!(stderr, "error: failed to parse '{display_name}' as {}: {}", input.name(), e.name());
            return Err(ActionFailed);
        }
    };

    if warn {
        warn_about_loss(&doc, output, output_target, input, stderr);
    }

    let out = match output {
        OutputMode::Html => match format::render_html(&doc) {
            Ok(o) => o,
            Err(e) => {
                let _ = writeln!(stderr, "error: failed to render '{display_name}' to html: {}", e.name());
                return Err(ActionFailed);
            }
        },
        OutputMode::Ast => twig::ast::json::encode(&doc.doc),
        OutputMode::Table => twig::ast::table::encode(&doc.doc, Default::default()),
        OutputMode::Canonical => {
            let target = output_target.unwrap_or_else(|| format::target_for(input));
            if format::writes_own_syntax(input, target) {
                match format::serialize_canonical(&doc) {
                    Ok(o) => o,
                    Err(format::PrintFailure::UnsupportedFormat) => {
                        let _ = writeln!(
                            stderr,
                            "error: canonical output is not supported for {} yet: no serializer",
                            input.name()
                        );
                        return Err(ActionFailed);
                    }
                    Err(e) => {
                        let _ = writeln!(stderr, "error: failed to serialize '{display_name}' to canonical form: {}", e.name());
                        return Err(ActionFailed);
                    }
                }
            } else {
                if !format::target_serializes_from_ast(target) {
                    let _ = writeln!(stderr, "error: conversion to {} is not supported yet: no serializer", target.name());
                    return Err(ActionFailed);
                }
                match format::serialize_converted(&doc, target) {
                    Ok(o) => o,
                    Err(e) => {
                        let _ = writeln!(
                            stderr,
                            "error: failed to convert '{display_name}' from {} to {}: {}",
                            input.name(),
                            target.name(),
                            e.name()
                        );
                        return Err(ActionFailed);
                    }
                }
            }
        }
    };
    if let Err(e) = stdout.write_all(&out) {
        let _ = writeln!(stderr, "error: failed to write output: {}", io_error_name(&e));
        return Err(ActionFailed);
    }
    Ok(())
}

pub fn run_query(stdout: &mut dyn Write, stderr: &mut dyn Write, opts: &QueryOptions) -> ActionResult {
    let source = read_source(&opts.file, stderr)?;
    let doc = match format::parse_to_ast(opts.input, &opts.parse_config, &source) {
        Ok(d) => d,
        Err(e) => {
            let _ = writeln!(stderr, "error: failed to parse '{}' as {}: {}", opts.file, opts.input.name(), e.name());
            return Err(ActionFailed);
        }
    };
    let selector = match select::parse(opts.selector.as_bytes()) {
        Ok(s) => s,
        Err(_) => {
            let _ = writeln!(stderr, "error: could not parse selector '{}': InvalidSelector", opts.selector);
            return Err(ActionFailed);
        }
    };
    let matches = select::resolve_all(&doc, &selector);
    if matches.is_empty() {
        let _ = writeln!(stderr, "no matches for selector '{}'", opts.selector);
        return Ok(());
    }
    let mut out = Vec::new();
    for m in matches {
        print_match_line(&doc.ast, m.id, &mut out);
    }
    stdout.write_all(&out).map_err(|_| ActionFailed)
}

fn print_match_line(ast: &Ast, id: NodeId, out: &mut Vec<u8>) {
    out.push(b'[');
    if let Some(path) = ast.path_of(id) {
        for (i, seg) in path.iter().enumerate() {
            if i != 0 {
                out.push(b'.');
            }
            out.extend_from_slice(seg.to_string().as_bytes());
        }
    }
    out.extend_from_slice(b"]\t");
    out.extend_from_slice(ast.nodes[id as usize].kind.kind_name().as_bytes());
    out.push(b'\t');
    let text = select::text_of(ast, id);
    out.push(b'"');
    let limit = 60;
    let n = text.len().min(limit);
    for &c in &text[..n] {
        out.push(if c == b'\n' || c == b'\t' || c == b'\r' { b' ' } else { c });
    }
    if text.len() > limit {
        out.extend_from_slice("…".as_bytes());
    }
    out.extend_from_slice(b"\"\n");
}

fn write_result(stdout: &mut dyn Write, stderr: &mut dyn Write, file: &str, dry_run: bool, bytes: &[u8]) -> ActionResult {
    if dry_run || file == "-" {
        if let Err(e) = stdout.write_all(bytes) {
            let _ = writeln!(stderr, "error: failed to write output: {}", io_error_name(&e));
            return Err(ActionFailed);
        }
        return Ok(());
    }
    if let Err(e) = std::fs::write(file, bytes) {
        let _ = writeln!(stderr, "error: could not write '{file}': {}", io_error_name(&e));
        return Err(ActionFailed);
    }
    Ok(())
}

pub fn run_edit(stdout: &mut dyn Write, stderr: &mut dyn Write, opts: &EditOptions) -> ActionResult {
    let source = read_source(&opts.file, stderr)?;
    let edited = apply_edit_by_locator(&source, opts, stderr)?;
    write_result(stdout, stderr, &opts.file, opts.dry_run, &edited)
}

pub fn run_filter(stdout: &mut dyn Write, stderr: &mut dyn Write, opts: &FilterOptions) -> ActionResult {
    let source = read_source(&opts.file, stderr)?;
    let filtered = filter_source(&source, opts, stderr)?;
    write_result(stdout, stderr, &opts.file, opts.dry_run, &filtered)
}

/// A splicer over `source` that reparses as `input` under `cfg`.
fn new_splicer(source: &[u8], input: Format, cfg: &ParseConfig) -> Result<twig::ast::splicer::Splicer, String> {
    let cfg = *cfg;
    let parse: twig::ast::splicer::ParseFn = Box::new(move |src: &[u8]| {
        format::parse_to_ast(input, &cfg, src).map_err(|e| twig::ast::splicer::ParseError::new(e.name()))
    });
    twig::ast::splicer::Splicer::new(source, parse).map_err(|e| e.name)
}

fn filter_source(source: &[u8], opts: &FilterOptions, stderr: &mut dyn Write) -> Result<Vec<u8>, ActionFailed> {
    let mut editor = match new_splicer(source, opts.input, &opts.parse_config) {
        Ok(e) => e,
        Err(why) => {
            let _ = writeln!(stderr, "error: failed to parse input as {}: {why}", opts.input.name());
            return Err(ActionFailed);
        }
    };
    let options = twig::ast::filter::Options {
        drop: opts.drop.as_bytes(),
        keep: opts.keep.as_deref().map(str::as_bytes),
        unwrap_kept: opts.unwrap_kept,
    };
    if let Err(err) = twig::ast::filter::apply(&mut editor, &options) {
        use twig::ast::filter::Error as F;
        match err {
            F::InvalidSelector => {
                let _ = writeln!(stderr, "error: could not parse a --drop/--keep selector");
            }
            F::FilterDidNotConverge => {
                let _ = writeln!(stderr, "error: filter did not converge (an edit kept failing to apply)");
            }
            other => {
                let _ = writeln!(stderr, "error: filter failed: {}", other.name());
            }
        }
        return Err(ActionFailed);
    }
    Ok(editor.source_bytes().to_vec())
}

fn apply_edit_by_locator(source: &[u8], opts: &EditOptions, stderr: &mut dyn Write) -> Result<Vec<u8>, ActionFailed> {
    let mut editor = match new_splicer(source, opts.input, &opts.parse_config) {
        Ok(e) => e,
        Err(why) => {
            let _ = writeln!(stderr, "error: failed to parse input as {}: {why}", opts.input.name());
            return Err(ActionFailed);
        }
    };
    let id = resolve_locator(&editor.doc, &opts.path_str, stderr)?;
    let text = opts.text.as_bytes();
    let result = match opts.op {
        EditOp::Replace => editor.replace_node_by_id(id, text),
        EditOp::ReplaceContent => editor.replace_content_by_id(id, text),
        EditOp::InsertBefore => editor.insert_before_by_id(id, text),
        EditOp::InsertAfter => editor.insert_after_by_id(id, text),
        EditOp::InsertChild => editor.insert_child_by_id(id, opts.child_index, text),
        EditOp::Delete => editor.delete_node_smart_by_id(id),
        EditOp::Unwrap => editor.unwrap_node_by_id(id),
    };
    if let Err(err) = result {
        use twig::ast::splicer::Error as E;
        match err {
            E::NoContentSpan => {
                let _ = writeln!(stderr, "error: that node has no editable interior (it's a leaf, or a container the parser left without a known interior)");
            }
            E::NoNodeSpan => {
                let _ = writeln!(stderr, "error: that node has no source span yet — spans aren't tracked for its kind (e.g. Markdown inline nodes like links/emphasis); edit its enclosing block instead");
            }
            other => {
                let _ = writeln!(stderr, "error: the edit produced a document that no longer parses ({}); nothing was changed", other.name());
            }
        }
        return Err(ActionFailed);
    }
    Ok(editor.source_bytes().to_vec())
}

fn resolve_locator(doc: &Document, locator: &str, stderr: &mut dyn Write) -> Result<NodeId, ActionFailed> {
    use twig::ast::locator::{self, Error as L};
    let is_path = locator::is_index_path(locator.as_bytes());
    match locator::resolve(doc, locator.as_bytes()) {
        Ok(id) => Ok(id),
        Err(L::InvalidLocator) => {
            if is_path {
                let _ = writeln!(stderr, "error: invalid index path '{locator}' (expected dot-separated indices like 0.3.1)");
            } else {
                let _ = writeln!(stderr, "error: could not parse selector '{locator}'");
            }
            Err(ActionFailed)
        }
        Err(L::NotFound) => {
            if is_path {
                let _ = writeln!(stderr, "error: no node at path '{locator}' (index out of bounds)");
            } else {
                let _ = writeln!(stderr, "error: no node matches selector '{locator}'");
            }
            Err(ActionFailed)
        }
        Err(L::Ambiguous) => {
            let Ok(selector) = select::parse(locator.as_bytes()) else { return Err(ActionFailed) };
            let matches = select::resolve_all(doc, &selector);
            let _ = writeln!(
                stderr,
                "error: selector '{locator}' is ambiguous — {} nodes match. Refine it, add :nth(k), or use an index path:",
                matches.len()
            );
            let mut out = Vec::new();
            for m in matches {
                print_match_line(&doc.ast, m.id, &mut out);
            }
            let _ = stderr.write_all(&out);
            Err(ActionFailed)
        }
    }
}

/// The Zig error name a failed file operation prints as (`{t}`).
pub fn io_error_name(e: &std::io::Error) -> &'static str {
    use std::io::ErrorKind as K;
    match e.kind() {
        K::NotFound => "FileNotFound",
        K::PermissionDenied => "AccessDenied",
        K::IsADirectory => "IsDir",
        K::NotADirectory => "NotDir",
        K::BrokenPipe => "BrokenPipe",
        K::InvalidFilename => "BadPathName",
        K::FileTooLarge => "FileTooBig",
        _ => "Unexpected",
    }
}

pub fn read_source(path: &str, stderr: &mut dyn Write) -> Result<Vec<u8>, ActionFailed> {
    let mut out = Vec::new();
    if path == "-" {
        let r = std::io::stdin().lock().take(MAX_SOURCE_BYTES + 1).read_to_end(&mut out);
        if let Err(e) = r {
            let _ = writeln!(stderr, "error: could not read stdin: {}", io_error_name(&e));
            return Err(ActionFailed);
        }
        if out.len() as u64 > MAX_SOURCE_BYTES {
            let _ = writeln!(stderr, "error: could not read stdin: StreamTooLong");
            return Err(ActionFailed);
        }
        return Ok(out);
    }
    let file = std::fs::File::open(path).and_then(|f| {
        if f.metadata()?.is_dir() {
            return Err(std::io::Error::from(std::io::ErrorKind::IsADirectory));
        }
        Ok(f)
    });
    let r = file.and_then(|f| f.take(MAX_SOURCE_BYTES + 1).read_to_end(&mut out));
    if let Err(e) = r {
        let _ = writeln!(stderr, "error: could not read '{path}': {}", io_error_name(&e));
        return Err(ActionFailed);
    }
    if out.len() as u64 > MAX_SOURCE_BYTES {
        let _ = writeln!(stderr, "error: could not read '{path}': StreamTooLong");
        return Err(ActionFailed);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn convert(src: &str, input: Format, output: OutputMode, target: Option<Target>, warn: bool) -> (String, String) {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let _ = convert_source(src.as_bytes(), "-", input, &ParseConfig::default(), output, target, warn, &mut out, &mut err);
        (String::from_utf8(out).unwrap(), String::from_utf8(err).unwrap())
    }

    #[test]
    fn identify() {
        let mut out = Vec::new();
        run_identify(&mut out, &IdentifyOptions { file: "post.md".into(), input: Format::Markdown });
        assert_eq!(out, b"markdown\n");
    }

    #[test]
    fn warn_reports_loss_on_stderr_only() {
        let (o, e) = convert("a^b^ c\n", Format::Djot, OutputMode::Canonical, Some(Target::Markdown), true);
        assert_eq!(o, "a^b^ c\n");
        assert!(e.contains("`superscript`") && e.contains("markdown"));
        let (o, e) = convert("a^b^ c\n", Format::Djot, OutputMode::Canonical, Some(Target::Markdown), false);
        assert_eq!(o, "a^b^ c\n");
        assert_eq!(e, "");
    }

    #[test]
    fn djot_html_resolves_footnotes_and_table_reads_back() {
        let (o, _) = convert("hi[^1]\n\n[^1]: a note\n", Format::Djot, OutputMode::Html, None, false);
        assert!(o.contains("doc-endnotes") && o.contains("id=\"fn1\""));
        let src = "hi[^1]\n\n[^1]: a note\n";
        let (o, _) = convert(src, Format::Djot, OutputMode::Table, None, false);
        let doc = twig::ast::table::decode(src.as_bytes(), o.as_bytes()).unwrap();
        assert!(twig::languages::djot::parse(src.as_bytes()).ast.eql(&doc.ast));
    }

    #[test]
    fn canonical_and_cross_conversion() {
        assert_eq!(convert("<a><b/></a>", Format::Xml, OutputMode::Canonical, None, false).0, "<a><b/></a>");
        assert!(convert("hello *world*\n", Format::Djot, OutputMode::Canonical, None, false).0.contains("*world*"));
        assert!(convert("[x][a]\n\n[a]: /u\n", Format::Markdown, OutputMode::Canonical, None, false).0.contains("[a]: /u"));
        assert!(convert("This is *markdown*.\n", Format::Markdown, OutputMode::Canonical, Some(Target::Djot), false).0.contains("_markdown_"));
        assert!(convert("This is _djot emphasis_.\n", Format::Djot, OutputMode::Canonical, Some(Target::Markdown), false).0.contains("*djot emphasis*"));
        assert!(convert("hello\n", Format::Djot, OutputMode::Ast, None, false).0.contains("\"kind\": \"doc\""));
    }

    #[test]
    fn locator_failures_name_their_form() {
        let doc = twig::languages::xml::parse(b"<r><a/><a/></r>").unwrap();
        for (loc, want) in [
            ("0..1", "index path"),
            ("0.x.1", "selector"),
            ("0.9", "no node at path"),
            ("element(", "parse selector"),
            ("element[name=a]", "2 nodes match"),
        ] {
            let mut err = Vec::new();
            assert!(resolve_locator(&doc, loc, &mut err).is_err());
            assert!(String::from_utf8(err).unwrap().contains(want), "{loc}");
        }
    }
}
