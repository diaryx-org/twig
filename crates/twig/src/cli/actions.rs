//! The verbs. Port of `src/cli/actions.zig`: each prints its diagnostics at
//! the site that detects them and returns `Err(ActionFailed)` to unwind.

use std::io::{Read, Write};

use crate::ast::{Ast, NodeId, select};
use crate::cli::args::{ConvertOptions, EditOp, EditOptions, FilterOptions, IdentifyOptions, LangOptions, QueryOptions};
use crate::cli::format::OutputMode;
use crate::document::Document;
use crate::format::{self, Format, ParseConfig, Target};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionFailed;

pub type ActionResult = Result<(), ActionFailed>;

const MAX_SOURCE_BYTES: u64 = 16 * 1024 * 1024;

pub fn run_version(stdout: &mut dyn Write) {
    let _ = writeln!(stdout, "twig {}", env!("CARGO_PKG_VERSION"));
}

pub fn run_help(w: &mut dyn Write, b: &str) {
    let _ = write!(
        w,
        "usage: {b} <command> [options] <file>

commands:
  convert [-i <format>] [-o <format>] <file|->
      Convert a document. `-o` selects the output; default is `html`.
        html       render to HTML (default)
        ast        dump the shared AST as pretty-printed JSON
        table      dump the node table: flat pre-order rows, the
                   encoding a language outside twig parses into
        canonical  round-trip serialize back to the source format
                   (only formats with a serializer support this)
      --warn reports to stderr what the conversion will silently
      lose -- a node the target has no spelling for is degraded or
      dropped without failing, which is what makes it easy to miss.

  identify <file>
      Detect and print a file's input format; performs no conversion.

  query [-i <format>] <file> <selector>
      List nodes matching a CSS-lite selector, one per line:
      `[index.path]  kind  \"text preview\"`. Feed a printed path
      straight to `edit`. Selector examples:
        heading            heading[level=2]    heading(\"Status\")
        item[2]            link[dest^=\"http\"]  code[lang=zig]

  edit [-i <format>] <file|-> <operation>
      Losslessly edit a document in place. A <path> is either a
      dot-separated index path (e.g. 0.3.1) or a selector that matches
      exactly one node (e.g. 'heading(\"Status\")'). Use `query` to find
      nodes and `convert -o ast` to see the whole tree. Operations:
        --replace <path> <text>          replace a node's whole source
        --replace-content <path> <text>  replace a container's interior
        --insert-before <path> <text>    insert text before a node
        --insert-after <path> <text>     insert text after a node
        --insert-child <path> <i> <text> insert as a container's i-th child
        --delete <path>                  remove a node (tidies blank lines)
        --unwrap <path>                  drop a wrapper, keep its contents
      Writes back in place; pass --dry-run to print the result instead.

  filter [-i <format>] <file|-> --drop <sel> [--keep <sel>] [--unwrap]
      Prune a document: remove every node matching --drop, except those
      also matching --keep; with --unwrap, peel the kept wrappers down
      to their contents. E.g. keep only the public audience:
        filter archive.md --directives \\
          --drop 'directive[name=vis]' --keep 'directive[class~=public]' --unwrap
      Writes back in place; pass --dry-run to print the result instead.

  lang table [-i <format>] <file|->
      Print the node table a parse of <file> produces -- what a
      language outside twig writes for the same document.
  lang syntax <format>
      Print a compiled format's syntax table as JSON -- the spellings
      its editing gestures write.
  lang list
      List the compiled formats and the configured languages.
  lang check <name> [--against <format>] [file...]
  lang check [--against <format>] [file...] -- <command> [arg...]
      Load a runtime language -- every sample parses, prints and
      reparses -- and, with --against, hold its node tables to a
      compiled format's over its samples and the files.

runtime languages:
  A format twig does not compile in is a helper process a
  `languages` file names, one per line: name, extensions (a,b or
  -), command. Read from $TWIG_LANGUAGES, .twig/languages here
  and upward, then ~/.config/twig/languages. `-i <name>`, a file's
  extension, or `--lang <name>` reaches one.

  help              show this message
  version           show the version

options:
  -i, --input <format>   override input-format detection
                         (djot/dj, markdown/md, commonmark, gfm, xml, svg,
                         html/htm, asciidoc/adoc)
  -o, --output <format>  select convert's output (html, ast, table, canonical)
  --lang <name>          read the input as a runtime language
  --feature <name>       turn on a feature the input's row declares
                         (see `lang list`); repeatable
  --dry-run              (edit) print the result instead of writing it

markdown extension flags (convert/query/edit; ignored for other inputs;
each is also --feature <name>, e.g. --feature html_elements):
  --directives           enable generic directives (:name, ::name, :::name)
  --math                 enable $…$ / $$…$$ math
  --highlight            enable ==…== highlight (a `mark` node)
  --highlight-colors     enable ==🔴 …== coloured highlights (implies --highlight)
  --commonmark           same as -i commonmark: strict CommonMark
  --gfm                  same as -i gfm: GFM's extensions and HTML output

Input format is normally inferred from the file extension
(.dj/.djot, .md/.markdown, .xml, .html/.htm, .adoc/.asciidoc). A `.md` file is
twig's default Markdown; say `-i gfm` or `-i commonmark` for a dialect. Pass `-` as the file to read from
stdin — this requires an explicit `-i`, since there is no extension
to infer from.

examples:
  {b} convert doc.dj
  {b} convert -o ast doc.dj
  {b} convert -o canonical feed.xml
  {b} identify doc.md
  {b} convert -i markdown - < doc.md
  {b} convert -i gfm --math README.md
"
    );
}

pub fn run_lang(stdout: &mut dyn Write, stderr: &mut dyn Write, opts: &LangOptions) -> ActionResult {
    match opts {
        LangOptions::Table(c) => run_convert(stdout, stderr, c),
        LangOptions::Syntax(f) => {
            let mut out = Vec::new();
            crate::syntax_json::encode(&mut out, format::syntax_for(*f), Default::default());
            out.push(b'\n');
            stdout.write_all(&out).map_err(|_| ActionFailed)
        }
        LangOptions::List => pending::list(stdout).map_err(|_| ActionFailed),
        LangOptions::Check(c) => {
            pending::check(stdout, stderr, c.name.as_deref(), &c.command, c.against, &c.files).map_err(|_| ActionFailed)
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
    let Ok(warnings) = crate::diagnostics::analyze(&doc.doc.ast, doc.doc.ast.root, target) else { return };
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
        OutputMode::Ast => crate::ast::json::encode(&doc.doc),
        OutputMode::Table => crate::ast::table::encode(&doc.doc, Default::default()),
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
fn new_splicer(source: &[u8], input: Format, cfg: &ParseConfig) -> Result<crate::ast::splicer::Splicer, String> {
    let cfg = *cfg;
    let parse: crate::ast::splicer::ParseFn = Box::new(move |src: &[u8]| {
        format::parse_to_ast(input, &cfg, src).map_err(|e| crate::ast::splicer::ParseError::new(e.name()))
    });
    crate::ast::splicer::Splicer::new(source, parse).map_err(|e| e.name)
}

fn filter_source(source: &[u8], opts: &FilterOptions, stderr: &mut dyn Write) -> Result<Vec<u8>, ActionFailed> {
    let mut editor = match new_splicer(source, opts.input, &opts.parse_config) {
        Ok(e) => e,
        Err(why) => {
            let _ = writeln!(stderr, "error: failed to parse input as {}: {why}", opts.input.name());
            return Err(ActionFailed);
        }
    };
    let options = crate::ast::filter::Options {
        drop: opts.drop.as_bytes(),
        keep: opts.keep.as_deref().map(str::as_bytes),
        unwrap_kept: opts.unwrap_kept,
    };
    if let Err(err) = crate::ast::filter::apply(&mut editor, &options) {
        use crate::ast::filter::Error as F;
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
        use crate::ast::splicer::Error as E;
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
    use crate::ast::locator::{self, Error as L};
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

/// TODO(port): the configured-language commands route here until
/// `cli::languages` is ported.
mod pending {
    use std::io::Write;

    use crate::format::Format;

    pub fn list(out: &mut dyn Write) -> std::io::Result<()> {
        out.write_all(b"compiled:\n")
    }

    pub fn check(
        _out: &mut dyn Write,
        err: &mut dyn Write,
        _name: Option<&str>,
        _command: &[String],
        _against: Option<Format>,
        _files: &[String],
    ) -> Result<(), ()> {
        let _ = writeln!(err, "error: lang check is not ported yet");
        Err(())
    }
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
    fn identify_and_help() {
        let mut out = Vec::new();
        run_identify(&mut out, &IdentifyOptions { file: "post.md".into(), input: Format::Markdown });
        assert_eq!(out, b"markdown\n");
        let mut h = Vec::new();
        run_help(&mut h, "twig");
        let h = String::from_utf8(h).unwrap();
        assert!(h.contains("lang table") && h.contains("identify") && h.contains("-o"));
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
        let doc = crate::ast::table::decode(src.as_bytes(), o.as_bytes()).unwrap();
        assert!(crate::languages::djot::parse(src.as_bytes()).ast.eql(&doc.ast));
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
        let doc = crate::languages::xml::parse(b"<r><a/><a/></r>").unwrap();
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
