//! The resolved shape of a command line: what each verb in `actions` runs
//! over, once `args` has turned argv into it.

use twig::format::{Format, ParseConfig, Target};

use crate::format::OutputMode;

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

#[derive(Clone, Debug, PartialEq)]
pub enum LangOptions {
    Table(ConvertOptions),
    Syntax(Format),
    List,
    Check(CheckOptions),
}

/// What the parsed command line asks for, with its input format resolved.
#[derive(Clone, Debug, PartialEq)]
pub enum CliActionOptions {
    Version,
    Convert(ConvertOptions),
    Identify(IdentifyOptions),
    Edit(EditOptions),
    Query(QueryOptions),
    Filter(FilterOptions),
    Lang(LangOptions),
}

/// Why a command line that clap accepted still names no runnable action. The
/// diagnostic is written where the problem is detected; this only unwinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArgError {
    UnknownFeature,
    InvalidEditIndex,
    BadLangCheck,
    StdinRequiresInputFormat,
    UnknownExtension,
}
