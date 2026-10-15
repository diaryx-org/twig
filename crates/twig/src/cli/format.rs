//! The CLI's view of the format registry: names that also reach the
//! configured runtime languages, the output modes, and the help listings.
//! Port of `src/cli/format.zig`.

use std::io::Write;

use crate::cli::args::ArgError;
use crate::cli::languages;
use crate::format::{self, Format, Target, target_for};

pub fn parse_format_name(name: &str) -> Option<Format> {
    format::parse_format_name(name).or_else(|| languages::resolve_name(name))
}

pub fn parse_target_name(name: &str) -> Option<Target> {
    if let Some(t) = format::parse_target_name(name) {
        return Some(t);
    }
    languages::resolve_name(name).map(target_for)
}

pub fn detect_from_extension(file_path: &str) -> Option<Format> {
    if let Some(f) = format::detect_from_extension(file_path) {
        return Some(f);
    }
    let dot = file_path.rfind('.')?;
    let ext = &file_path[dot + 1..];
    if ext.is_empty() {
        return None;
    }
    languages::resolve_extension(ext)
}

fn print_configured(w: &mut dyn Write) {
    for c in languages::configured() {
        let _ = write!(w, "  - {} (configured", c.name);
        for x in &c.extensions {
            let _ = write!(w, " .{x}");
        }
        let _ = w.write_all(b")\n");
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputMode {
    Html,
    Ast,
    Table,
    Canonical,
}

impl OutputMode {
    pub const ALL: [OutputMode; 4] = [OutputMode::Html, OutputMode::Ast, OutputMode::Table, OutputMode::Canonical];
    pub fn name(self) -> &'static str {
        match self {
            OutputMode::Html => "html",
            OutputMode::Ast => "ast",
            OutputMode::Table => "table",
            OutputMode::Canonical => "canonical",
        }
    }
}

pub fn parse_output_mode(name: &str) -> Option<OutputMode> {
    OutputMode::ALL.into_iter().find(|m| m.name() == name)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutputSelection {
    pub mode: OutputMode,
    pub target: Option<Target>,
}

pub fn parse_output_selection(name: &str) -> Option<OutputSelection> {
    if let Some(mode) = parse_output_mode(name) {
        return Some(OutputSelection { mode, target: None });
    }
    parse_target_name(name).map(|t| OutputSelection { mode: OutputMode::Canonical, target: Some(t) })
}

pub fn print_supported_input_formats(w: &mut dyn Write) {
    let _ = w.write_all(b"supported input formats:\n");
    for f in Format::COMPILED {
        let _ = write!(w, "  - {}", f.name());
        for alias in f.aliases() {
            let _ = write!(w, " ({alias})");
        }
        if let Some(lang) = f.dialect_of() {
            let _ = write!(w, " \u{2014} a {} dialect", lang.name());
        }
        let _ = w.write_all(b"\n");
    }
    print_configured(w);
}

pub fn print_supported_output_targets(w: &mut dyn Write) {
    let _ = w.write_all(b"supported output values:\n");
    for m in OutputMode::ALL {
        let _ = writeln!(w, "  - {}", m.name());
    }
    for t in Target::COMPILED {
        if parse_output_mode(t.static_name()).is_some() {
            continue;
        }
        let _ = write!(w, "  - {}", t.name());
        if let Some(f) = t.as_format() {
            for alias in f.aliases() {
                let _ = write!(w, " ({alias})");
            }
        }
        let _ = w.write_all(b"\n");
    }
    print_configured(w);
}

pub fn resolve_input_format(stderr: &mut dyn Write, file_path: &str, over: Option<Format>) -> Result<Format, ArgError> {
    if let Some(f) = over {
        return Ok(f);
    }
    if file_path == "-" {
        let _ = stderr.write_all(b"error: reading from stdin ('-') requires an explicit --input/-i format (there is no file extension to infer one from).\n");
        let _ = stderr.flush();
        return Err(ArgError::StdinRequiresInputFormat);
    }
    if let Some(f) = detect_from_extension(file_path) {
        return Ok(f);
    }
    let _ = writeln!(stderr, "error: could not infer an input format for '{file_path}' from its extension.");
    let _ = stderr.write_all(b"Try using --input/-i <format> to specify one explicitly.\n");
    print_supported_input_formats(stderr);
    let _ = stderr.flush();
    Err(ArgError::UnknownExtension)
}
