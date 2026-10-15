//! The command line, declared with clap, and its resolution into the
//! [`CliActionOptions`] the verbs run over. Clap owns the grammar, `--help` and
//! the usage errors; what it cannot know (an input format inferred from a file's
//! extension, a feature its format does not declare) is checked in
//! [`Cli::resolve`], which writes its diagnostic to `stderr` where it detects it.

use std::io::Write;

use clap::{ArgAction, Args, Parser, Subcommand};
use twig::format::{self, Format, ParseConfig};

use crate::format::{self as cf, OutputMode, OutputSelection};
use crate::languages;
use crate::options::{
    ArgError, CheckOptions, CliActionOptions, ConvertOptions, EditOp, EditOptions, FilterOptions, IdentifyOptions,
    LangOptions, QueryOptions,
};

const AFTER_HELP: &str = "\
Input format is normally inferred from the file extension (.dj/.djot,
.md/.markdown, .xml, .html/.htm, .adoc/.asciidoc). A `.md` file is twig's
default Markdown; say `-i gfm` or `-i commonmark` for a dialect. Pass `-` as
the file to read from stdin; this requires an explicit `-i`, since there is no
extension to infer from.

Runtime languages:
  A format twig does not compile in is a helper process a `languages` file
  names, one per line: name, extensions (a,b or -), command. Read from
  $TWIG_LANGUAGES, .twig/languages here and upward, then
  ~/.config/twig/languages. `-i <name>`, a file's extension, or
  `--lang <name>` reaches one.

Examples:
  twig convert doc.dj
  twig convert -o ast doc.dj
  twig convert -o canonical feed.xml
  twig identify doc.md
  twig convert -i markdown - < doc.md
  twig convert -i gfm --math README.md";

#[derive(Parser, Debug)]
#[command(
    name = "twig",
    version,
    about = "Parse, query, edit, and losslessly round-trip Djot, Markdown, HTML, XML, and AsciiDoc documents.",
    after_help = AFTER_HELP,
    arg_required_else_help = true,
    disable_version_flag = true
)]
pub struct Cli {
    /// Print version
    #[arg(short = 'V', long, short_alias = 'v', action = ArgAction::Version)]
    version: Option<bool>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Convert a document; renders HTML unless `-o` says otherwise
    #[command(long_about = CONVERT_ABOUT)]
    Convert(ConvertArgs),

    /// Detect and print a file's input format; performs no conversion
    Identify(IdentifyArgs),

    /// List the nodes matching a CSS-lite selector, one per line
    #[command(long_about = QUERY_ABOUT)]
    Query(QueryArgs),

    /// Losslessly edit a document in place
    #[command(long_about = EDIT_ABOUT)]
    Edit(EditArgs),

    /// Prune a document: drop the nodes a selector matches
    #[command(long_about = FILTER_ABOUT)]
    Filter(FilterArgs),

    /// Inspect formats and runtime languages
    #[command(subcommand)]
    Lang(LangCommand),

    /// Print the version
    Version,
}

const CONVERT_ABOUT: &str = "\
Convert a document; renders HTML unless `-o` says otherwise.

`-o` takes an output mode or a target format:
  html       render to HTML (the default)
  ast        dump the shared AST as pretty-printed JSON
  table      dump the node table: flat pre-order rows, the encoding a
             language outside twig parses into
  canonical  round-trip serialize back to the source format
  <format>   serialize into another format, e.g. `-o markdown`";

const QUERY_ABOUT: &str = "\
List the nodes matching a CSS-lite selector, one per line:
`[index.path]  kind  \"text preview\"`. Feed a printed path straight to
`edit`. Selector examples:
  heading            heading[level=2]    heading(\"Status\")
  item[2]            link[dest^=\"http\"]  code[lang=rust]";

const EDIT_ABOUT: &str = "\
Losslessly edit a document in place.

A PATH is either a dot-separated index path (e.g. 0.3.1) or a selector that
matches exactly one node (e.g. 'heading(\"Status\")'). Use `query` to find
nodes and `convert -o ast` to see the whole tree. Writes back in place; pass
--dry-run to print the result instead.";

const FILTER_ABOUT: &str = "\
Prune a document: remove every node matching --drop, except those also
matching --keep; with --unwrap, peel the kept wrappers down to their contents.
E.g. keep only the public audience:

  twig filter archive.md --directives \\
    --drop 'directive[name=vis]' --keep 'directive[class~=public]' --unwrap

Writes back in place; pass --dry-run to print the result instead.";

/// How the input is read: its format, when the extension should not decide.
/// The four spellings override one another; the last one given wins.
#[derive(Args, Debug)]
struct InputArgs {
    /// Read the input as FORMAT instead of inferring it from the extension
    /// (djot/dj, markdown/md, commonmark, gfm, xml, svg, html/htm,
    /// asciidoc/adoc, or a configured language)
    #[arg(short = 'i', long = "input", value_name = "FORMAT", value_parser = parse_input_format,
          overrides_with_all = ["lang", "commonmark", "gfm"])]
    input: Option<Format>,

    /// Read the input as a runtime language (see `twig lang list`)
    #[arg(long, value_name = "NAME", value_parser = parse_runtime_language,
          overrides_with_all = ["input", "commonmark", "gfm"])]
    lang: Option<Format>,

    /// Same as `-i commonmark`: strict CommonMark
    #[arg(long, overrides_with_all = ["input", "lang", "gfm"])]
    commonmark: bool,

    /// Same as `-i gfm`: GFM's extensions and HTML output
    #[arg(long, overrides_with_all = ["input", "lang", "commonmark"])]
    gfm: bool,
}

impl InputArgs {
    fn format(&self) -> Option<Format> {
        if self.commonmark {
            return Some(Format::Commonmark);
        }
        if self.gfm {
            return Some(Format::Gfm);
        }
        self.input.or(self.lang)
    }

    /// The format `file` is read as: the one named, else its extension's.
    fn resolve(&self, stderr: &mut dyn Write, file: &str) -> Result<Format, ArgError> {
        cf::resolve_input_format(stderr, file, self.format())
    }
}

/// The parse's optional features. Each Markdown flag has a `--no-` form; the
/// last of a pair wins.
#[derive(Args, Debug)]
struct FeatureArgs {
    /// Turn on a feature the input's format declares (see `twig lang list`);
    /// repeatable
    #[arg(long = "feature", value_name = "NAME")]
    features: Vec<String>,

    /// Enable generic directives (:name, ::name, :::name)
    #[arg(long, help_heading = "Markdown extensions", overrides_with = "no_directives")]
    directives: bool,
    #[arg(long, hide = true, overrides_with = "directives")]
    no_directives: bool,

    /// Enable $…$ / $$…$$ math
    #[arg(long, help_heading = "Markdown extensions", overrides_with = "no_math")]
    math: bool,
    #[arg(long, hide = true, overrides_with = "math")]
    no_math: bool,

    /// Enable inline HTML elements as divs, spans, underline and verse
    #[arg(long, help_heading = "Markdown extensions", overrides_with = "no_html_elements")]
    html_elements: bool,
    #[arg(long, hide = true, overrides_with = "html_elements")]
    no_html_elements: bool,

    /// Enable ==…== highlight (a `mark` node)
    #[arg(long, help_heading = "Markdown extensions", overrides_with = "no_highlight")]
    highlight: bool,
    #[arg(long, hide = true, overrides_with = "highlight")]
    no_highlight: bool,

    /// Enable ==🔴 …== coloured highlights (implies --highlight)
    #[arg(long, help_heading = "Markdown extensions", overrides_with = "no_highlight_colors")]
    highlight_colors: bool,
    #[arg(long, hide = true, overrides_with = "highlight_colors")]
    no_highlight_colors: bool,
}

impl FeatureArgs {
    /// The parse configuration these flags ask of `input`. Only the Markdown
    /// rows read the Markdown flags; `--feature` is checked against the row.
    fn parse_config(&self, stderr: &mut dyn Write, input: Format) -> Result<ParseConfig, ArgError> {
        let mut cfg = ParseConfig::default();
        let m = &mut cfg.markdown;
        let pairs = [
            (&mut m.directives, self.directives, self.no_directives),
            (&mut m.math, self.math, self.no_math),
            (&mut m.html_elements, self.html_elements, self.no_html_elements),
            (&mut m.highlight, self.highlight, self.no_highlight),
            (&mut m.highlight_colors, self.highlight_colors, self.no_highlight_colors),
        ];
        for (field, on, off) in pairs {
            if on {
                *field = true;
            } else if off {
                *field = false;
            }
        }
        if self.highlight_colors {
            m.highlight = true;
        }

        let mut mask = 0u32;
        for name in &self.features {
            match format::feature_bit(input, name) {
                Some(b) => mask |= b,
                None => {
                    let declared = format::features(input);
                    let _ = write!(stderr, "error: '{}' has no feature '{}'", input.name(), name);
                    if declared.is_empty() {
                        let _ = stderr.write_all(b"; it declares none\n");
                    } else {
                        let _ = stderr.write_all(b"; it declares");
                        for (i, f) in declared.iter().enumerate() {
                            let _ = write!(stderr, "{} {}", if i == 0 { "" } else { "," }, f.name);
                        }
                        let _ = stderr.write_all(b"\n");
                    }
                    return Err(ArgError::UnknownFeature);
                }
            }
        }
        if mask != 0 {
            let more = ParseConfig::for_features(input, mask);
            cfg.features |= more.features;
            let (m, o) = (&mut cfg.markdown, more.markdown);
            m.directives |= o.directives;
            m.math |= o.math;
            m.html_elements |= o.html_elements;
            m.highlight |= o.highlight;
            m.highlight_colors |= o.highlight_colors;
        }
        Ok(cfg)
    }
}

#[derive(Args, Debug)]
struct ConvertArgs {
    /// The document to read, or `-` for stdin (which needs `-i`)
    #[arg(value_name = "FILE")]
    file: String,

    /// Select the output: html, ast, table, canonical, or a target format
    #[arg(short = 'o', long = "output", value_name = "FORMAT", value_parser = parse_output)]
    output: Option<OutputSelection>,

    /// Report on stderr what the conversion will silently lose: a node the
    /// target has no spelling for is degraded or dropped without failing
    #[arg(long)]
    warn: bool,

    #[command(flatten)]
    input: InputArgs,

    #[command(flatten)]
    features: FeatureArgs,
}

#[derive(Args, Debug)]
struct IdentifyArgs {
    /// The document whose format to print
    #[arg(value_name = "FILE")]
    file: String,

    #[command(flatten)]
    input: InputArgs,
}

#[derive(Args, Debug)]
struct QueryArgs {
    /// The document to search, or `-` for stdin (which needs `-i`)
    #[arg(value_name = "FILE")]
    file: String,

    /// The CSS-lite selector to match
    #[arg(value_name = "SELECTOR")]
    selector: String,

    #[command(flatten)]
    input: InputArgs,

    #[command(flatten)]
    features: FeatureArgs,
}

#[derive(Args, Debug)]
struct EditArgs {
    /// The document to edit, or `-` for stdin (which needs `-i`)
    #[arg(value_name = "FILE")]
    file: String,

    #[command(flatten)]
    op: EditOpArgs,

    /// Print the result instead of writing it back
    #[arg(long)]
    dry_run: bool,

    #[command(flatten)]
    input: InputArgs,

    #[command(flatten)]
    features: FeatureArgs,
}

/// Exactly one edit. Values may start with `-` (a Markdown list item does).
#[derive(Args, Debug)]
#[group(required = true, multiple = false)]
struct EditOpArgs {
    /// Replace a node's whole source
    #[arg(long, num_args = 2, value_names = ["PATH", "TEXT"], allow_hyphen_values = true,
          help_heading = "Operations")]
    replace: Option<Vec<String>>,

    /// Replace a container's interior
    #[arg(long, num_args = 2, value_names = ["PATH", "TEXT"], allow_hyphen_values = true,
          help_heading = "Operations")]
    replace_content: Option<Vec<String>>,

    /// Insert text before a node
    #[arg(long, num_args = 2, value_names = ["PATH", "TEXT"], allow_hyphen_values = true,
          help_heading = "Operations")]
    insert_before: Option<Vec<String>>,

    /// Insert text after a node
    #[arg(long, num_args = 2, value_names = ["PATH", "TEXT"], allow_hyphen_values = true,
          help_heading = "Operations")]
    insert_after: Option<Vec<String>>,

    /// Insert text as a container's INDEX-th child
    #[arg(long, num_args = 3, value_names = ["PATH", "INDEX", "TEXT"], allow_hyphen_values = true,
          help_heading = "Operations")]
    insert_child: Option<Vec<String>>,

    /// Remove a node, tidying the blank lines around it
    #[arg(long, value_name = "PATH", allow_hyphen_values = true, help_heading = "Operations")]
    delete: Option<String>,

    /// Drop a wrapper, keeping its contents
    #[arg(long, value_name = "PATH", allow_hyphen_values = true, help_heading = "Operations")]
    unwrap: Option<String>,
}

impl EditOpArgs {
    /// The operation, its path, the child index and the text.
    fn into_parts(self) -> (EditOp, String, Option<String>, String) {
        let two = |op, v: Vec<String>| {
            let [path, text]: [String; 2] = v.try_into().expect("clap takes two values");
            (op, path, None, text)
        };
        if let Some(v) = self.replace {
            return two(EditOp::Replace, v);
        }
        if let Some(v) = self.replace_content {
            return two(EditOp::ReplaceContent, v);
        }
        if let Some(v) = self.insert_before {
            return two(EditOp::InsertBefore, v);
        }
        if let Some(v) = self.insert_after {
            return two(EditOp::InsertAfter, v);
        }
        if let Some(v) = self.insert_child {
            let [path, index, text]: [String; 3] = v.try_into().expect("clap takes three values");
            return (EditOp::InsertChild, path, Some(index), text);
        }
        if let Some(path) = self.delete {
            return (EditOp::Delete, path, None, String::new());
        }
        if let Some(path) = self.unwrap {
            return (EditOp::Unwrap, path, None, String::new());
        }
        unreachable!("clap requires one operation")
    }
}

#[derive(Args, Debug)]
struct FilterArgs {
    /// The document to prune, or `-` for stdin (which needs `-i`)
    #[arg(value_name = "FILE")]
    file: String,

    /// Remove every node this selector matches
    #[arg(long, value_name = "SELECTOR")]
    drop: String,

    /// Spare the dropped nodes this selector also matches
    #[arg(long, value_name = "SELECTOR")]
    keep: Option<String>,

    /// Peel the kept wrappers down to their contents
    #[arg(long)]
    unwrap: bool,

    /// Print the result instead of writing it back
    #[arg(long)]
    dry_run: bool,

    #[command(flatten)]
    input: InputArgs,

    #[command(flatten)]
    features: FeatureArgs,
}

#[derive(Subcommand, Debug)]
enum LangCommand {
    /// List the compiled formats and the configured languages
    List,

    /// Print the node table a parse of FILE produces: what a language outside
    /// twig writes for the same document
    Table(TableArgs),

    /// Print a compiled format's syntax table as JSON: the spellings its
    /// editing gestures write
    Syntax {
        /// The compiled format
        #[arg(value_name = "FORMAT", value_parser = parse_compiled_format)]
        format: Format,
    },

    /// Load a runtime language (every sample parses, prints and reparses)
    /// and, with --against, hold its node tables to a compiled format's
    #[command(
        override_usage = "twig lang check <NAME> [--against <FORMAT>] [FILE]...\n       \
                          twig lang check [--against <FORMAT>] [FILE]... -- <COMMAND>...",
        long_about = "Load a runtime language: every sample parses, prints and reparses. With \
                      --against, also hold its node tables to a compiled format's over its \
                      samples and the FILEs.\n\nName a configured language, or give a helper's \
                      command after `--` to check one that is not configured yet."
    )]
    Check(CheckArgs),
}

#[derive(Args, Debug)]
struct TableArgs {
    /// The document to parse, or `-` for stdin (which needs `-i`)
    #[arg(value_name = "FILE")]
    file: String,

    #[command(flatten)]
    input: InputArgs,

    #[command(flatten)]
    features: FeatureArgs,
}

#[derive(Args, Debug)]
struct CheckArgs {
    /// Compare against this compiled format's node tables
    #[arg(long, value_name = "FORMAT", value_parser = parse_compiled_format)]
    against: Option<Format>,

    /// The configured language's name, then the files to check; only files
    /// when a command follows `--`
    #[arg(value_name = "NAME|FILE")]
    args: Vec<String>,

    /// The helper's command and its arguments
    #[arg(last = true, value_name = "COMMAND")]
    command: Vec<String>,
}

fn listing(print: fn(&mut dyn Write)) -> String {
    let mut out = Vec::new();
    print(&mut out);
    String::from_utf8_lossy(&out).trim_end().to_string()
}

fn parse_input_format(name: &str) -> Result<Format, String> {
    cf::parse_format_name(name).ok_or_else(|| format!("unsupported input format\n\n{}", listing(cf::print_supported_input_formats)))
}

fn parse_compiled_format(name: &str) -> Result<Format, String> {
    format::parse_format_name(name)
        .ok_or_else(|| format!("not a compiled format\n\n{}", listing(cf::print_supported_input_formats)))
}

fn parse_runtime_language(name: &str) -> Result<Format, String> {
    if let Some(f) = format::parse_format_name(name) {
        if twig::runtime::is_registered(f) {
            return Ok(f);
        }
        return Err(format!("'{name}' is compiled in; --lang names a runtime language, and -i takes '{name}'"));
    }
    languages::resolve_name(name)
        .ok_or_else(|| format!("no runtime language named '{name}' is configured (see `twig lang list`)"))
}

fn parse_output(name: &str) -> Result<OutputSelection, String> {
    cf::parse_output_selection(name)
        .ok_or_else(|| format!("unsupported output value\n\n{}", listing(cf::print_supported_output_targets)))
}

/// Rust's `usize` parse, plus the `+` sign and `_` digit separators the
/// original CLI accepted in a child index.
fn parse_usize(s: &str) -> Option<usize> {
    let s = s.strip_prefix('+').unwrap_or(s);
    if s.is_empty() || s.starts_with('_') || s.ends_with('_') {
        return None;
    }
    s.replace('_', "").parse().ok()
}

impl Cli {
    /// Settle what clap could not: the input format, the features it
    /// declares, and the shape of `lang check`'s arguments.
    pub fn resolve(self, stderr: &mut dyn Write) -> Result<CliActionOptions, ArgError> {
        let convert = |stderr: &mut dyn Write, file: String, input: &InputArgs, features: &FeatureArgs| {
            let resolved = input.resolve(stderr, &file)?;
            let parse_config = features.parse_config(stderr, resolved)?;
            Ok::<_, ArgError>(ConvertOptions {
                file,
                input: resolved,
                output: OutputMode::Html,
                output_target: None,
                parse_config,
                warn: false,
            })
        };
        Ok(match self.command {
            Command::Version => CliActionOptions::Version,
            Command::Convert(a) => {
                let mut c = convert(stderr, a.file, &a.input, &a.features)?;
                if let Some(sel) = a.output {
                    c.output = sel.mode;
                    c.output_target = sel.target;
                }
                c.warn = a.warn;
                CliActionOptions::Convert(c)
            }
            Command::Identify(a) => {
                let input = a.input.resolve(stderr, &a.file)?;
                CliActionOptions::Identify(IdentifyOptions { file: a.file, input })
            }
            Command::Query(a) => {
                let input = a.input.resolve(stderr, &a.file)?;
                let parse_config = a.features.parse_config(stderr, input)?;
                CliActionOptions::Query(QueryOptions { file: a.file, input, selector: a.selector, parse_config })
            }
            Command::Filter(a) => {
                let input = a.input.resolve(stderr, &a.file)?;
                let parse_config = a.features.parse_config(stderr, input)?;
                CliActionOptions::Filter(FilterOptions {
                    file: a.file,
                    input,
                    drop: a.drop,
                    keep: a.keep,
                    unwrap_kept: a.unwrap,
                    dry_run: a.dry_run,
                    parse_config,
                })
            }
            Command::Edit(a) => {
                let (op, path_str, index, text) = a.op.into_parts();
                let child_index = match index {
                    None => 0,
                    Some(s) => parse_usize(&s).ok_or_else(|| {
                        let _ = writeln!(stderr, "error: edit: invalid child index '{s}' (expected a non-negative integer)");
                        ArgError::InvalidEditIndex
                    })?,
                };
                let input = a.input.resolve(stderr, &a.file)?;
                let parse_config = a.features.parse_config(stderr, input)?;
                CliActionOptions::Edit(EditOptions {
                    file: a.file,
                    input,
                    parse_config,
                    op,
                    path_str,
                    child_index,
                    text,
                    dry_run: a.dry_run,
                })
            }
            Command::Lang(LangCommand::List) => CliActionOptions::Lang(LangOptions::List),
            Command::Lang(LangCommand::Syntax { format }) => CliActionOptions::Lang(LangOptions::Syntax(format)),
            Command::Lang(LangCommand::Table(a)) => {
                let mut c = convert(stderr, a.file, &a.input, &a.features)?;
                c.output = OutputMode::Table;
                CliActionOptions::Lang(LangOptions::Table(c))
            }
            Command::Lang(LangCommand::Check(a)) => {
                let mut args = a.args.into_iter();
                let name = if a.command.is_empty() { args.next() } else { None };
                if name.is_none() && a.command.is_empty() {
                    let _ = writeln!(
                        stderr,
                        "error: lang check: name a configured language, or give a helper's command after --"
                    );
                    return Err(ArgError::BadLangCheck);
                }
                CliActionOptions::Lang(LangOptions::Check(CheckOptions {
                    name,
                    command: a.command,
                    against: a.against,
                    files: args.collect(),
                }))
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;
    use clap::error::ErrorKind;
    use twig::format::Target;

    use super::*;

    fn parse(argv: &[&str]) -> (Result<CliActionOptions, ArgError>, String) {
        let cli = Cli::try_parse_from(argv).unwrap_or_else(|e| panic!("clap rejected {argv:?}: {e}"));
        let mut err = Vec::new();
        let r = cli.resolve(&mut err);
        (r, String::from_utf8(err).unwrap())
    }

    fn ok(argv: &[&str]) -> CliActionOptions {
        parse(argv).0.expect("resolves")
    }

    fn clap_error(argv: &[&str]) -> ErrorKind {
        Cli::try_parse_from(argv).expect_err("clap rejects").kind()
    }

    #[test]
    fn the_command_is_well_formed() {
        Cli::command().debug_assert();
    }

    #[test]
    fn help_and_version() {
        assert_eq!(clap_error(&["twig"]), ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand);
        assert_eq!(clap_error(&["twig", "--help"]), ErrorKind::DisplayHelp);
        assert_eq!(clap_error(&["twig", "help"]), ErrorKind::DisplayHelp);
        for flag in ["-V", "-v", "--version"] {
            assert_eq!(clap_error(&["twig", flag]), ErrorKind::DisplayVersion);
        }
        assert_eq!(clap_error(&["twig", "frobnicate"]), ErrorKind::InvalidSubcommand);
        assert_eq!(ok(&["twig", "version"]), CliActionOptions::Version);
    }

    #[test]
    fn convert_infers_and_overrides() {
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "doc.dj"]) else { panic!() };
        assert_eq!(c.input, Format::Djot);
        assert_eq!(c.output, OutputMode::Html);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "-i", "md", "-o", "ast", "weird.ext"]) else { panic!() };
        assert_eq!(c.input, Format::Markdown);
        assert_eq!(c.output, OutputMode::Ast);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--output", "canonical", "--input", "xml", "f"]) else {
            panic!()
        };
        assert_eq!(c.input, Format::Xml);
        assert_eq!(c.output, OutputMode::Canonical);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "-o", "gfm", "x.dj"]) else { panic!() };
        assert_eq!(c.output, OutputMode::Canonical);
        assert_eq!(c.output_target, Some(Target::Markdown));
        // The input's spellings override one another; the last wins.
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--gfm", "-i", "djot", "x.md"]) else { panic!() };
        assert_eq!(c.input, Format::Djot);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "-i", "djot", "--commonmark", "x.md"]) else { panic!() };
        assert_eq!(c.input, Format::Commonmark);
    }

    #[test]
    fn convert_errors() {
        let (r, e) = parse(&["twig", "convert", "-"]);
        assert_eq!(r.unwrap_err(), ArgError::StdinRequiresInputFormat);
        assert!(e.contains("requires an explicit --input/-i"));
        assert_eq!(parse(&["twig", "convert", "x.unknown"]).0.unwrap_err(), ArgError::UnknownExtension);
        assert_eq!(clap_error(&["twig", "convert", "-i", "nope", "x"]), ErrorKind::ValueValidation);
        assert_eq!(clap_error(&["twig", "convert", "-o", "nope", "x.dj"]), ErrorKind::ValueValidation);
        assert_eq!(clap_error(&["twig", "convert"]), ErrorKind::MissingRequiredArgument);
        assert_eq!(clap_error(&["twig", "convert", "a.dj", "b.dj"]), ErrorKind::UnknownArgument);
    }

    #[test]
    fn markdown_flags_and_features() {
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--math", "--directives", "--highlight", "x.md"]) else {
            panic!()
        };
        let m = c.parse_config.markdown;
        assert!(m.math && m.directives && m.highlight);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "x.md", "--feature", "html_elements"]) else { panic!() };
        assert!(c.parse_config.markdown.html_elements);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--highlight-colors", "x.md"]) else { panic!() };
        assert!(c.parse_config.markdown.highlight && c.parse_config.markdown.highlight_colors);
        let (r, e) = parse(&["twig", "convert", "--feature", "nope", "x.dj"]);
        assert_eq!(r.unwrap_err(), ArgError::UnknownFeature);
        assert_eq!(e, "error: 'djot' has no feature 'nope'; it declares none\n");
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--gfm", "--math", "x.md"]) else { panic!() };
        assert_eq!(c.input, Format::Gfm);
        assert!(c.parse_config.markdown.math);
        // The last of a pair wins.
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--math", "--no-math", "x.md"]) else { panic!() };
        assert!(!c.parse_config.markdown.math);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--no-math", "--math", "x.md"]) else { panic!() };
        assert!(c.parse_config.markdown.math);
    }

    #[test]
    fn lang_subcommands() {
        assert_eq!(ok(&["twig", "lang", "list"]), CliActionOptions::Lang(LangOptions::List));
        let CliActionOptions::Lang(LangOptions::Check(c)) =
            ok(&["twig", "lang", "check", "org", "--against", "djot", "a.org", "b.org"])
        else {
            panic!()
        };
        assert_eq!(c.name.as_deref(), Some("org"));
        assert_eq!(c.against, Some(Format::Djot));
        assert_eq!(c.files, ["a.org", "b.org"]);
        let CliActionOptions::Lang(LangOptions::Check(c)) =
            ok(&["twig", "lang", "check", "--against", "djot", "x.dj", "--", "twig-quickjs", "djot.mjs"])
        else {
            panic!()
        };
        assert!(c.name.is_none());
        assert_eq!(c.files, ["x.dj"]);
        assert_eq!(c.command, ["twig-quickjs", "djot.mjs"]);
        assert_eq!(parse(&["twig", "lang", "check"]).0.unwrap_err(), ArgError::BadLangCheck);
        let CliActionOptions::Lang(LangOptions::Table(c)) = ok(&["twig", "lang", "table", "x.dj"]) else { panic!() };
        assert_eq!(c.output, OutputMode::Table);
        assert_eq!(clap_error(&["twig", "lang", "table", "-o", "ast", "x.dj"]), ErrorKind::UnknownArgument);
        assert_eq!(ok(&["twig", "lang", "syntax", "md"]), CliActionOptions::Lang(LangOptions::Syntax(Format::Markdown)));
        assert_eq!(clap_error(&["twig", "lang", "frobnicate"]), ErrorKind::InvalidSubcommand);
    }

    #[test]
    fn lang_flag_refuses_compiled_name() {
        let e = Cli::try_parse_from(["twig", "convert", "--lang", "djot", "x.dj"]).unwrap_err();
        assert_eq!(e.kind(), ErrorKind::ValueValidation);
        assert!(e.to_string().contains("is compiled in; --lang names a runtime language"));
    }

    #[test]
    fn query_filter_edit() {
        let CliActionOptions::Query(q) = ok(&["twig", "query", "-i", "md", "f", "heading"]) else { panic!() };
        assert_eq!(q.selector, "heading");
        assert_eq!(clap_error(&["twig", "query", "x.md"]), ErrorKind::MissingRequiredArgument);
        let CliActionOptions::Filter(f) = ok(&["twig", "filter", "a.md", "--drop", "x", "--keep", "y", "--unwrap", "--dry-run"])
        else {
            panic!()
        };
        assert_eq!(f.keep.as_deref(), Some("y"));
        assert!(f.unwrap_kept && f.dry_run);
        assert_eq!(clap_error(&["twig", "filter", "a.md"]), ErrorKind::MissingRequiredArgument);
        let CliActionOptions::Edit(e) = ok(&["twig", "edit", "--replace", "0.1", "hi", "x.dj"]) else { panic!() };
        assert_eq!((e.op, e.path_str.as_str(), e.text.as_str()), (EditOp::Replace, "0.1", "hi"));
        let CliActionOptions::Edit(e) = ok(&["twig", "edit", "-i", "md", "--insert-child", "0", "2", "x", "--dry-run", "f"]) else {
            panic!()
        };
        assert_eq!((e.child_index, e.dry_run), (2, true));
        // Text may look like a flag: a Markdown list item does.
        let CliActionOptions::Edit(e) = ok(&["twig", "edit", "x.md", "--insert-after", "0", "- item"]) else { panic!() };
        assert_eq!(e.text, "- item");
        assert_eq!(clap_error(&["twig", "edit", "x.dj"]), ErrorKind::MissingRequiredArgument);
        assert_eq!(clap_error(&["twig", "edit", "x.dj", "--delete"]), ErrorKind::InvalidValue);
        assert_eq!(clap_error(&["twig", "edit", "x.dj", "--delete", "0", "--unwrap", "1"]), ErrorKind::ArgumentConflict);
        let (r, e) = parse(&["twig", "edit", "x.dj", "--insert-child", "0", "-1", "t"]);
        assert_eq!(r.unwrap_err(), ArgError::InvalidEditIndex);
        assert!(e.contains("invalid child index '-1'"));
        assert_eq!(parse_usize("+1_000"), Some(1000));
        assert_eq!(parse_usize("_1"), None);
    }
}
