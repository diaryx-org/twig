//! Turn argv into a [`CliConfig`]. Port of `src/cli/args.zig`. Diagnostics
//! are written to `stderr` at the site that detects the problem.

use std::io::Write;

use crate::cli::format::{self as cf, OutputMode};
use crate::cli::languages;
use crate::format::{self, Format, ParseConfig, Target};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Help,
    Version,
    Convert,
    Identify,
    Edit,
    Query,
    Filter,
    Lang,
}

pub fn command_usage(action: Action) -> &'static str {
    match action {
        Action::Convert => "convert [-i <format>] [-o <format>] [--feature <name>]... [--warn] <file|->",
        Action::Identify => "identify [-i <format>] <file>",
        Action::Query => "query [-i <format>] <file> <selector>",
        Action::Edit => "edit [-i <format>] <file|-> <operation>",
        Action::Filter => "filter [-i <format>] <file|-> --drop <sel> [--keep <sel>] [--unwrap]",
        Action::Lang => "lang list | lang table [-i <format>] <file|-> | lang syntax <format> | lang check <name> [--against <format>] [file...] | lang check [--against <format>] -- <command> [arg...]",
        Action::Help | Action::Version => "<command> [options] <file>",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditOp {
    Replace,
    ReplaceContent,
    InsertBefore,
    InsertAfter,
    InsertChild,
    Delete,
    Unwrap,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ConvertOptions {
    pub file: String,
    pub input: Format,
    pub output: OutputMode,
    pub output_target: Option<Target>,
    pub parse_config: ParseConfig,
    pub warn: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct IdentifyOptions {
    pub file: String,
    pub input: Format,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditOptions {
    pub file: String,
    pub input: Format,
    pub parse_config: ParseConfig,
    pub op: EditOp,
    pub path_str: String,
    pub child_index: usize,
    pub text: String,
    pub dry_run: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct QueryOptions {
    pub file: String,
    pub input: Format,
    pub selector: String,
    pub parse_config: ParseConfig,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FilterOptions {
    pub file: String,
    pub input: Format,
    pub drop: String,
    pub keep: Option<String>,
    pub unwrap_kept: bool,
    pub dry_run: bool,
    pub parse_config: ParseConfig,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CheckOptions {
    pub name: Option<String>,
    pub command: Vec<String>,
    pub against: Option<Format>,
    pub files: Vec<String>,
}

impl CheckOptions {
    pub const MAX_FILES: usize = 256;
    pub const MAX_COMMAND: usize = 32;
}

#[derive(Clone, Debug, PartialEq)]
pub enum LangOptions {
    Table(ConvertOptions),
    Syntax(Format),
    List,
    Check(CheckOptions),
}

#[derive(Clone, Debug, PartialEq)]
pub enum CliActionOptions {
    Help,
    Version,
    Convert(ConvertOptions),
    Identify(IdentifyOptions),
    Edit(EditOptions),
    Query(QueryOptions),
    Filter(FilterOptions),
    Lang(LangOptions),
}

#[derive(Clone, Debug, PartialEq)]
pub struct CliConfig {
    pub action: Action,
    pub options: CliActionOptions,
    pub binary_name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArgError {
    UnsupportedFormat,
    MissingFormatValue,
    MissingFile,
    TooManyPositionals,
    MissingEditArgument,
    MissingEditOperation,
    InvalidEditIndex,
    MissingSelector,
    MissingFilterSelector,
    UnknownLangCommand,
    BadLangCheck,
    UnknownFeature,
    StdinRequiresInputFormat,
    UnknownExtension,
}

pub struct Args {
    items: Vec<String>,
    i: usize,
}

impl Args {
    pub fn new<I: IntoIterator<Item = S>, S: Into<String>>(items: I) -> Args {
        Args { items: items.into_iter().map(Into::into).collect(), i: 0 }
    }
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<String> {
        let v = self.items.get(self.i).cloned();
        if v.is_some() {
            self.i += 1;
        }
        v
    }
}

fn arg_fail(stderr: &mut dyn Write, binary_name: &str, action: Action, message: &str, err: ArgError) -> ArgError {
    let _ = write!(stderr, "error: {message}\nusage: {binary_name} {}\n", command_usage(action));
    let _ = stderr.flush();
    err
}

fn unsupported_input(stderr: &mut dyn Write, name: &str) -> ArgError {
    let _ = writeln!(stderr, "error: unsupported input format '{name}'");
    cf::print_supported_input_formats(stderr);
    let _ = stderr.flush();
    ArgError::UnsupportedFormat
}

#[derive(Default)]
struct Features {
    names: Vec<String>,
}

impl Features {
    fn apply(&self, stderr: &mut dyn Write, input: Format, cfg: &mut ParseConfig) -> Result<(), ArgError> {
        let mut mask = 0u32;
        for name in &self.names {
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
                    let _ = stderr.flush();
                    return Err(ArgError::UnknownFeature);
                }
            }
        }
        if mask == 0 {
            return Ok(());
        }
        let more = ParseConfig::for_features(input, mask);
        cfg.features |= more.features;
        let (m, o) = (&mut cfg.markdown, more.markdown);
        m.directives |= o.directives;
        m.math |= o.math;
        m.html_elements |= o.html_elements;
        m.highlight |= o.highlight;
        m.highlight_colors |= o.highlight_colors;
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
fn apply_ext_flag(
    arg: &str,
    args: &mut Args,
    stderr: &mut dyn Write,
    binary_name: &str,
    action: Action,
    input: &mut Option<Format>,
    cfg: &mut ParseConfig,
    feats: &mut Features,
) -> Result<bool, ArgError> {
    match arg {
        "--feature" => {
            let Some(name) = args.next() else {
                return Err(arg_fail(stderr, binary_name, action, "--feature needs a feature's name", ArgError::MissingFormatValue));
            };
            if feats.names.len() == 32 {
                return Err(arg_fail(
                    stderr,
                    binary_name,
                    action,
                    "--feature given more often than a row has features",
                    ArgError::UnknownFeature,
                ));
            }
            feats.names.push(name);
        }
        "--directives" => cfg.markdown.directives = true,
        "--no-directives" => cfg.markdown.directives = false,
        "--math" => cfg.markdown.math = true,
        "--no-math" => cfg.markdown.math = false,
        "--html-elements" => cfg.markdown.html_elements = true,
        "--no-html-elements" => cfg.markdown.html_elements = false,
        "--highlight" => cfg.markdown.highlight = true,
        "--no-highlight" => cfg.markdown.highlight = false,
        "--highlight-colors" => {
            cfg.markdown.highlight = true;
            cfg.markdown.highlight_colors = true;
        }
        "--no-highlight-colors" => cfg.markdown.highlight_colors = false,
        "--commonmark" => *input = Some(Format::Commonmark),
        "--gfm" => *input = Some(Format::Gfm),
        _ => return Ok(false),
    }
    Ok(true)
}

fn input_flag(args: &mut Args, stderr: &mut dyn Write, binary_name: &str, action: Action, verb: &str) -> Result<Format, ArgError> {
    let Some(name) = args.next() else {
        return Err(arg_fail(
            stderr,
            binary_name,
            action,
            &format!("{verb}: -i/--input needs a format value"),
            ArgError::MissingFormatValue,
        ));
    };
    cf::parse_format_name(&name).ok_or_else(|| unsupported_input(stderr, &name))
}

fn lang_flag(args: &mut Args, stderr: &mut dyn Write, binary_name: &str, action: Action) -> Result<Format, ArgError> {
    let Some(name) = args.next() else {
        return Err(arg_fail(stderr, binary_name, action, "--lang needs a language name", ArgError::MissingFormatValue));
    };
    if let Some(f) = format::parse_format_name(&name) {
        if crate::runtime::is_registered(f) {
            return Ok(f);
        }
        let _ = writeln!(stderr, "error: '{name}' is compiled in; --lang names a runtime language, and -i takes '{name}'");
        let _ = stderr.flush();
        return Err(ArgError::UnsupportedFormat);
    }
    languages::resolve_name(&name).ok_or_else(|| {
        let _ = writeln!(stderr, "error: no runtime language named '{name}' is configured (see `twig lang list`)");
        let _ = stderr.flush();
        ArgError::UnsupportedFormat
    })
}

pub fn parse_config(args: &mut Args, stderr: &mut dyn Write) -> Result<CliConfig, ArgError> {
    let binary_name = args.next().unwrap_or_else(|| "twig".to_string());
    let help = |b: String| CliConfig { action: Action::Help, options: CliActionOptions::Help, binary_name: b };
    let Some(action_str) = args.next() else { return Ok(help(binary_name)) };
    match action_str.as_str() {
        "help" | "--help" | "-h" => Ok(help(binary_name)),
        "version" | "--version" | "-v" => {
            Ok(CliConfig { action: Action::Version, options: CliActionOptions::Version, binary_name })
        }
        "convert" => parse_convert(args, stderr, &binary_name),
        "identify" => parse_identify(args, stderr, &binary_name),
        "edit" => parse_edit(args, stderr, &binary_name),
        "query" => parse_query(args, stderr, &binary_name),
        "filter" => parse_filter(args, stderr, &binary_name),
        "lang" => parse_lang(args, stderr, &binary_name),
        _ => Ok(help(binary_name)),
    }
}

fn parse_convert(args: &mut Args, stderr: &mut dyn Write, binary_name: &str) -> Result<CliConfig, ArgError> {
    let mut input_override: Option<Format> = None;
    let mut output = OutputMode::Html;
    let mut output_target: Option<Target> = None;
    let mut warn = false;
    let mut file: Option<String> = None;
    let mut parse_config = ParseConfig::default();
    let mut feats = Features::default();
    let a = Action::Convert;

    while let Some(arg) = args.next() {
        if apply_ext_flag(&arg, args, stderr, binary_name, a, &mut input_override, &mut parse_config, &mut feats)? {
        } else if arg == "--lang" {
            input_override = Some(lang_flag(args, stderr, binary_name, a)?);
        } else if arg == "--input" || arg == "-i" {
            input_override = Some(input_flag(args, stderr, binary_name, a, "convert")?);
        } else if arg == "--warn" {
            warn = true;
        } else if arg == "--output" || arg == "-o" {
            let Some(name) = args.next() else {
                return Err(arg_fail(stderr, binary_name, a, "convert: -o/--output needs a format value", ArgError::MissingFormatValue));
            };
            let Some(sel) = cf::parse_output_selection(&name) else {
                let _ = writeln!(stderr, "error: unsupported output value '{name}'");
                cf::print_supported_output_targets(stderr);
                let _ = stderr.flush();
                return Err(ArgError::UnsupportedFormat);
            };
            output = sel.mode;
            output_target = sel.target;
        } else if file.is_none() {
            file = Some(arg);
        } else {
            return Err(arg_fail(
                stderr,
                binary_name,
                a,
                "convert: unexpected extra argument (only one input file is accepted)",
                ArgError::TooManyPositionals,
            ));
        }
    }

    let Some(path) = file else {
        return Err(arg_fail(stderr, binary_name, a, "convert: missing input file", ArgError::MissingFile));
    };
    let resolved = cf::resolve_input_format(stderr, &path, input_override)?;
    feats.apply(stderr, resolved, &mut parse_config)?;
    Ok(CliConfig {
        action: Action::Convert,
        binary_name: binary_name.to_string(),
        options: CliActionOptions::Convert(ConvertOptions {
            file: path,
            input: resolved,
            output,
            output_target,
            parse_config,
            warn,
        }),
    })
}

fn parse_lang(args: &mut Args, stderr: &mut dyn Write, binary_name: &str) -> Result<CliConfig, ArgError> {
    let a = Action::Lang;
    let mk = |o: LangOptions| CliConfig { action: Action::Lang, binary_name: binary_name.to_string(), options: CliActionOptions::Lang(o) };
    let Some(sub) = args.next() else {
        return Err(arg_fail(stderr, binary_name, a, "lang: missing subcommand", ArgError::UnknownLangCommand));
    };
    match sub.as_str() {
        "table" => {
            let parsed = parse_convert(args, stderr, binary_name)?;
            let CliActionOptions::Convert(mut c) = parsed.options else { unreachable!() };
            if c.output != OutputMode::Html || c.output_target.is_some() {
                return Err(arg_fail(stderr, binary_name, a, "lang table: prints the table; -o does not apply", ArgError::TooManyPositionals));
            }
            c.output = OutputMode::Table;
            Ok(mk(LangOptions::Table(c)))
        }
        "syntax" => {
            let Some(name) = args.next() else {
                return Err(arg_fail(stderr, binary_name, a, "lang syntax: name a compiled format", ArgError::MissingFormatValue));
            };
            if args.next().is_some() {
                return Err(arg_fail(stderr, binary_name, a, "lang syntax: takes one format", ArgError::TooManyPositionals));
            }
            let Some(f) = format::parse_format_name(&name) else {
                let _ = writeln!(stderr, "error: lang syntax names a compiled format; '{name}' is not one");
                cf::print_supported_input_formats(stderr);
                let _ = stderr.flush();
                return Err(ArgError::UnsupportedFormat);
            };
            Ok(mk(LangOptions::Syntax(f)))
        }
        "list" => {
            if args.next().is_some() {
                return Err(arg_fail(stderr, binary_name, a, "lang list: takes no arguments", ArgError::TooManyPositionals));
            }
            Ok(mk(LangOptions::List))
        }
        "check" => {
            let mut c = CheckOptions::default();
            let mut in_command = false;
            while let Some(arg) = args.next() {
                if in_command {
                    if c.command.len() == CheckOptions::MAX_COMMAND {
                        return Err(arg_fail(stderr, binary_name, a, "lang check: the command has too many arguments", ArgError::BadLangCheck));
                    }
                    c.command.push(arg);
                } else if arg == "--" {
                    in_command = true;
                } else if arg == "--against" {
                    let Some(name) = args.next() else {
                        return Err(arg_fail(stderr, binary_name, a, "lang check: --against needs a compiled format", ArgError::MissingFormatValue));
                    };
                    let Some(f) = format::parse_format_name(&name) else {
                        let _ = writeln!(stderr, "error: --against names a compiled format; '{name}' is not one");
                        cf::print_supported_input_formats(stderr);
                        let _ = stderr.flush();
                        return Err(ArgError::UnsupportedFormat);
                    };
                    c.against = Some(f);
                } else if c.name.is_none() && c.command.is_empty() && c.files.is_empty() && !arg.starts_with('-') {
                    c.name = Some(arg);
                } else {
                    if c.files.len() == CheckOptions::MAX_FILES {
                        return Err(arg_fail(stderr, binary_name, a, "lang check: too many files; loop over a corpus in the shell", ArgError::BadLangCheck));
                    }
                    c.files.push(arg);
                }
            }
            if in_command && c.command.is_empty() {
                return Err(arg_fail(stderr, binary_name, a, "lang check: -- is followed by the helper's command", ArgError::BadLangCheck));
            }
            if in_command {
                if let Some(name) = c.name.take() {
                    if c.files.len() == CheckOptions::MAX_FILES {
                        return Err(arg_fail(stderr, binary_name, a, "lang check: too many files", ArgError::BadLangCheck));
                    }
                    c.files.insert(0, name);
                }
            }
            if c.name.is_none() && c.command.is_empty() {
                return Err(arg_fail(
                    stderr,
                    binary_name,
                    a,
                    "lang check: name a configured language, or give a helper's command after --",
                    ArgError::BadLangCheck,
                ));
            }
            Ok(mk(LangOptions::Check(c)))
        }
        _ => {
            let _ = writeln!(stderr, "error: lang: unknown subcommand '{sub}'");
            Err(arg_fail(stderr, binary_name, a, "lang: the subcommands are list, table, syntax and check", ArgError::UnknownLangCommand))
        }
    }
}

fn parse_identify(args: &mut Args, stderr: &mut dyn Write, binary_name: &str) -> Result<CliConfig, ArgError> {
    let a = Action::Identify;
    let mut input_override = None;
    let mut file: Option<String> = None;
    while let Some(arg) = args.next() {
        if arg == "--lang" {
            input_override = Some(lang_flag(args, stderr, binary_name, a)?);
        } else if arg == "--input" || arg == "-i" {
            input_override = Some(input_flag(args, stderr, binary_name, a, "identify")?);
        } else if file.is_none() {
            file = Some(arg);
        } else {
            return Err(arg_fail(
                stderr,
                binary_name,
                a,
                "identify: unexpected extra argument (only one input file is accepted)",
                ArgError::TooManyPositionals,
            ));
        }
    }
    let Some(path) = file else {
        return Err(arg_fail(stderr, binary_name, a, "identify: missing input file", ArgError::MissingFile));
    };
    let resolved = cf::resolve_input_format(stderr, &path, input_override)?;
    Ok(CliConfig {
        action: a,
        binary_name: binary_name.to_string(),
        options: CliActionOptions::Identify(IdentifyOptions { file: path, input: resolved }),
    })
}

fn parse_query(args: &mut Args, stderr: &mut dyn Write, binary_name: &str) -> Result<CliConfig, ArgError> {
    let a = Action::Query;
    let mut input_override = None;
    let mut file: Option<String> = None;
    let mut selector: Option<String> = None;
    let mut parse_config = ParseConfig::default();
    let mut feats = Features::default();
    while let Some(arg) = args.next() {
        if apply_ext_flag(&arg, args, stderr, binary_name, a, &mut input_override, &mut parse_config, &mut feats)? {
        } else if arg == "--lang" {
            input_override = Some(lang_flag(args, stderr, binary_name, a)?);
        } else if arg == "--input" || arg == "-i" {
            input_override = Some(input_flag(args, stderr, binary_name, a, "query")?);
        } else if file.is_none() {
            file = Some(arg);
        } else if selector.is_none() {
            selector = Some(arg);
        } else {
            return Err(arg_fail(
                stderr,
                binary_name,
                a,
                "query: unexpected extra argument (expected just <file> and <selector>)",
                ArgError::TooManyPositionals,
            ));
        }
    }
    let Some(path) = file else {
        return Err(arg_fail(stderr, binary_name, a, "query: missing input file", ArgError::MissingFile));
    };
    let Some(sel) = selector else {
        return Err(arg_fail(stderr, binary_name, a, "query: missing selector", ArgError::MissingSelector));
    };
    let resolved = cf::resolve_input_format(stderr, &path, input_override)?;
    feats.apply(stderr, resolved, &mut parse_config)?;
    Ok(CliConfig {
        action: a,
        binary_name: binary_name.to_string(),
        options: CliActionOptions::Query(QueryOptions { file: path, input: resolved, selector: sel, parse_config }),
    })
}

fn parse_filter(args: &mut Args, stderr: &mut dyn Write, binary_name: &str) -> Result<CliConfig, ArgError> {
    let a = Action::Filter;
    let mut input_override = None;
    let mut file: Option<String> = None;
    let mut drop: Option<String> = None;
    let mut keep: Option<String> = None;
    let mut unwrap_kept = false;
    let mut dry_run = false;
    let mut parse_config = ParseConfig::default();
    let mut feats = Features::default();
    while let Some(arg) = args.next() {
        if apply_ext_flag(&arg, args, stderr, binary_name, a, &mut input_override, &mut parse_config, &mut feats)? {
        } else if arg == "--lang" {
            input_override = Some(lang_flag(args, stderr, binary_name, a)?);
        } else if arg == "--input" || arg == "-i" {
            input_override = Some(input_flag(args, stderr, binary_name, a, "filter")?);
        } else if arg == "--drop" {
            drop = Some(args.next().ok_or_else(|| {
                arg_fail(stderr, binary_name, a, "filter: --drop needs a selector value", ArgError::MissingFilterSelector)
            })?);
        } else if arg == "--keep" {
            keep = Some(args.next().ok_or_else(|| {
                arg_fail(stderr, binary_name, a, "filter: --keep needs a selector value", ArgError::MissingFilterSelector)
            })?);
        } else if arg == "--unwrap" {
            unwrap_kept = true;
        } else if arg == "--dry-run" {
            dry_run = true;
        } else if file.is_none() {
            file = Some(arg);
        } else {
            return Err(arg_fail(
                stderr,
                binary_name,
                a,
                "filter: unexpected extra argument (only one input file is accepted)",
                ArgError::TooManyPositionals,
            ));
        }
    }
    let Some(path) = file else {
        return Err(arg_fail(stderr, binary_name, a, "filter: missing input file", ArgError::MissingFile));
    };
    let Some(drop) = drop else {
        return Err(arg_fail(stderr, binary_name, a, "filter: missing required --drop <selector>", ArgError::MissingFilterSelector));
    };
    let resolved = cf::resolve_input_format(stderr, &path, input_override)?;
    feats.apply(stderr, resolved, &mut parse_config)?;
    Ok(CliConfig {
        action: a,
        binary_name: binary_name.to_string(),
        options: CliActionOptions::Filter(FilterOptions {
            file: path,
            input: resolved,
            drop,
            keep,
            unwrap_kept,
            dry_run,
            parse_config,
        }),
    })
}

fn parse_edit(args: &mut Args, stderr: &mut dyn Write, binary_name: &str) -> Result<CliConfig, ArgError> {
    let a = Action::Edit;
    let mut input_override = None;
    let mut file: Option<String> = None;
    let mut op: Option<EditOp> = None;
    let mut path_str = String::new();
    let mut child_index = 0usize;
    let mut text = String::new();
    let mut dry_run = false;
    let mut parse_config = ParseConfig::default();
    let mut feats = Features::default();

    macro_rules! need {
        ($msg:expr) => {
            match args.next() {
                Some(v) => v,
                None => return Err(arg_fail(stderr, binary_name, a, $msg, ArgError::MissingEditArgument)),
            }
        };
    }

    while let Some(arg) = args.next() {
        if apply_ext_flag(&arg, args, stderr, binary_name, a, &mut input_override, &mut parse_config, &mut feats)? {
            continue;
        }
        match arg.as_str() {
            "--lang" => input_override = Some(lang_flag(args, stderr, binary_name, a)?),
            "--input" | "-i" => input_override = Some(input_flag(args, stderr, binary_name, a, "edit")?),
            "--dry-run" => dry_run = true,
            "--replace" => {
                op = Some(EditOp::Replace);
                path_str = need!("edit: --replace needs a <path> and <text>");
                text = need!("edit: --replace needs a <text> after its <path>");
            }
            "--replace-content" => {
                op = Some(EditOp::ReplaceContent);
                path_str = need!("edit: --replace-content needs a <path> and <text>");
                text = need!("edit: --replace-content needs a <text> after its <path>");
            }
            "--insert-before" => {
                op = Some(EditOp::InsertBefore);
                path_str = need!("edit: --insert-before needs a <path> and <text>");
                text = need!("edit: --insert-before needs a <text> after its <path>");
            }
            "--insert-after" => {
                op = Some(EditOp::InsertAfter);
                path_str = need!("edit: --insert-after needs a <path> and <text>");
                text = need!("edit: --insert-after needs a <text> after its <path>");
            }
            "--insert-child" => {
                op = Some(EditOp::InsertChild);
                path_str = need!("edit: --insert-child needs a <path>, <index>, and <text>");
                let idx_str = need!("edit: --insert-child needs an <index> and <text> after its <path>");
                child_index = match parse_usize(&idx_str) {
                    Some(v) => v,
                    None => {
                        let _ = write!(
                            stderr,
                            "error: edit: invalid child index '{idx_str}' (expected a non-negative integer)\nusage: {binary_name} {}\n",
                            command_usage(a)
                        );
                        let _ = stderr.flush();
                        return Err(ArgError::InvalidEditIndex);
                    }
                };
                text = need!("edit: --insert-child needs a <text> after its <index>");
            }
            "--delete" => {
                op = Some(EditOp::Delete);
                path_str = need!("edit: --delete needs a <path>");
            }
            "--unwrap" => {
                op = Some(EditOp::Unwrap);
                path_str = need!("edit: --unwrap needs a <path>");
            }
            _ => {
                if file.is_none() {
                    file = Some(arg);
                } else {
                    return Err(arg_fail(stderr, binary_name, a, "edit: unexpected extra argument", ArgError::TooManyPositionals));
                }
            }
        }
    }

    let Some(path) = file else {
        return Err(arg_fail(stderr, binary_name, a, "edit: missing input file", ArgError::MissingFile));
    };
    let Some(op) = op else {
        return Err(arg_fail(
            stderr,
            binary_name,
            a,
            "edit: missing an operation (e.g. --replace, --delete, --insert-child)",
            ArgError::MissingEditOperation,
        ));
    };
    let resolved = cf::resolve_input_format(stderr, &path, input_override)?;
    feats.apply(stderr, resolved, &mut parse_config)?;
    Ok(CliConfig {
        action: a,
        binary_name: binary_name.to_string(),
        options: CliActionOptions::Edit(EditOptions {
            file: path,
            input: resolved,
            parse_config,
            op,
            path_str,
            child_index,
            text,
            dry_run,
        }),
    })
}

/// Zig's `std.fmt.parseInt(usize, s, 10)`: an optional `+`, digits, and `_`
/// separators between digits.
fn parse_usize(s: &str) -> Option<usize> {
    let s = s.strip_prefix('+').unwrap_or(s);
    if s.is_empty() || s.starts_with('_') || s.ends_with('_') {
        return None;
    }
    let mut v: usize = 0;
    for c in s.chars() {
        if c == '_' {
            continue;
        }
        let d = c.to_digit(10)? as usize;
        v = v.checked_mul(10)?.checked_add(d)?;
    }
    Some(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(argv: &[&str]) -> (Result<CliConfig, ArgError>, String) {
        let mut err = Vec::new();
        let mut a = Args::new(argv.iter().copied());
        let r = parse_config(&mut a, &mut err);
        (r, String::from_utf8(err).unwrap())
    }

    fn ok(argv: &[&str]) -> CliConfig {
        parse(argv).0.expect("parses")
    }

    #[test]
    fn help_and_version() {
        for argv in [&["twig"][..], &["twig", "help"], &["twig", "--help"], &["twig", "-h"], &["twig", "frobnicate"]] {
            assert_eq!(ok(argv).action, Action::Help);
        }
        assert_eq!(ok(&["twig", "version"]).action, Action::Version);
    }

    #[test]
    fn convert_infers_and_overrides() {
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "doc.dj"]).options else { panic!() };
        assert_eq!(c.input, Format::Djot);
        assert_eq!(c.output, OutputMode::Html);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "-i", "md", "-o", "ast", "weird.ext"]).options else { panic!() };
        assert_eq!(c.input, Format::Markdown);
        assert_eq!(c.output, OutputMode::Ast);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--output", "canonical", "--input", "xml", "f"]).options else {
            panic!()
        };
        assert_eq!(c.input, Format::Xml);
        assert_eq!(c.output, OutputMode::Canonical);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "-o", "gfm", "x.dj"]).options else { panic!() };
        assert_eq!(c.output, OutputMode::Canonical);
        assert_eq!(c.output_target, Some(Target::Markdown));
    }

    #[test]
    fn convert_errors() {
        let (r, e) = parse(&["twig", "convert", "-"]);
        assert_eq!(r.unwrap_err(), ArgError::StdinRequiresInputFormat);
        assert!(e.contains("requires an explicit --input/-i"));
        assert_eq!(parse(&["twig", "convert", "x.unknown"]).0.unwrap_err(), ArgError::UnknownExtension);
        assert_eq!(parse(&["twig", "convert", "-i", "nope", "x"]).0.unwrap_err(), ArgError::UnsupportedFormat);
        assert_eq!(parse(&["twig", "convert", "-o", "nope", "x.dj"]).0.unwrap_err(), ArgError::UnsupportedFormat);
        assert_eq!(parse(&["twig", "convert"]).0.unwrap_err(), ArgError::MissingFile);
        let (r, e) = parse(&["twig", "convert", "a.dj", "b.dj"]);
        assert_eq!(r.unwrap_err(), ArgError::TooManyPositionals);
        assert!(e.contains("usage: twig convert"));
    }

    #[test]
    fn markdown_flags_and_features() {
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--math", "--directives", "--highlight", "x.md"]).options else {
            panic!()
        };
        assert!(c.parse_config.markdown.math && c.parse_config.markdown.directives && c.parse_config.markdown.highlight);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "x.md", "--feature", "html_elements"]).options else { panic!() };
        assert!(c.parse_config.markdown.html_elements);
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--highlight-colors", "x.md"]).options else { panic!() };
        assert!(c.parse_config.markdown.highlight && c.parse_config.markdown.highlight_colors);
        let (r, e) = parse(&["twig", "convert", "--feature", "nope", "x.dj"]);
        assert_eq!(r.unwrap_err(), ArgError::UnknownFeature);
        assert_eq!(e, "error: 'djot' has no feature 'nope'; it declares none\n");
        let CliActionOptions::Convert(c) = ok(&["twig", "convert", "--gfm", "--math", "x.md"]).options else { panic!() };
        assert_eq!(c.input, Format::Gfm);
        assert!(c.parse_config.markdown.math);
    }

    #[test]
    fn lang_subcommands() {
        assert_eq!(ok(&["twig", "lang", "list"]).options, CliActionOptions::Lang(LangOptions::List));
        let CliActionOptions::Lang(LangOptions::Check(c)) =
            ok(&["twig", "lang", "check", "org", "--against", "djot", "a.org", "b.org"]).options
        else {
            panic!()
        };
        assert_eq!(c.name.as_deref(), Some("org"));
        assert_eq!(c.against, Some(Format::Djot));
        assert_eq!(c.files.len(), 2);
        let CliActionOptions::Lang(LangOptions::Check(c)) =
            ok(&["twig", "lang", "check", "--against", "djot", "x.dj", "--", "twig-quickjs", "djot.mjs"]).options
        else {
            panic!()
        };
        assert!(c.name.is_none());
        assert_eq!(c.files[0], "x.dj");
        assert_eq!(c.command[1], "djot.mjs");
        assert_eq!(parse(&["twig", "lang", "check"]).0.unwrap_err(), ArgError::BadLangCheck);
        let CliActionOptions::Lang(LangOptions::Table(c)) = ok(&["twig", "lang", "table", "x.dj"]).options else { panic!() };
        assert_eq!(c.output, OutputMode::Table);
        assert_eq!(ok(&["twig", "lang", "syntax", "md"]).options, CliActionOptions::Lang(LangOptions::Syntax(Format::Markdown)));
        let (r, e) = parse(&["twig", "lang", "--lang", "djot", "x"]);
        assert_eq!(r.unwrap_err(), ArgError::UnknownLangCommand);
        assert!(e.starts_with("error: lang: unknown subcommand"));
    }

    #[test]
    fn lang_flag_refuses_compiled_name() {
        let (r, e) = parse(&["twig", "convert", "--lang", "djot", "x.dj"]);
        assert_eq!(r.unwrap_err(), ArgError::UnsupportedFormat);
        assert!(e.contains("is compiled in; --lang names a runtime language"));
    }

    #[test]
    fn query_filter_edit() {
        let CliActionOptions::Query(q) = ok(&["twig", "query", "-i", "md", "f", "heading"]).options else { panic!() };
        assert_eq!(q.selector, "heading");
        assert_eq!(parse(&["twig", "query", "x.md"]).0.unwrap_err(), ArgError::MissingSelector);
        let CliActionOptions::Filter(f) =
            ok(&["twig", "filter", "a.md", "--drop", "x", "--keep", "y", "--unwrap", "--dry-run"]).options
        else {
            panic!()
        };
        assert_eq!(f.keep.as_deref(), Some("y"));
        assert!(f.unwrap_kept && f.dry_run);
        assert_eq!(parse(&["twig", "filter", "a.md"]).0.unwrap_err(), ArgError::MissingFilterSelector);
        let CliActionOptions::Edit(e) = ok(&["twig", "edit", "--replace", "0.1", "hi", "x.dj"]).options else { panic!() };
        assert_eq!((e.op, e.path_str.as_str(), e.text.as_str()), (EditOp::Replace, "0.1", "hi"));
        let CliActionOptions::Edit(e) =
            ok(&["twig", "edit", "-i", "md", "--insert-child", "0", "2", "x", "--dry-run", "f"]).options
        else {
            panic!()
        };
        assert_eq!((e.child_index, e.dry_run), (2, true));
        assert_eq!(parse(&["twig", "edit", "x.dj"]).0.unwrap_err(), ArgError::MissingEditOperation);
        assert_eq!(parse(&["twig", "edit", "x.dj", "--delete"]).0.unwrap_err(), ArgError::MissingEditArgument);
        assert_eq!(parse(&["twig", "edit", "x.dj", "--insert-child", "0", "-1", "t"]).0.unwrap_err(), ArgError::InvalidEditIndex);
    }
}
