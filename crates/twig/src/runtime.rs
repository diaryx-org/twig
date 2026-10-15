//! Languages registered at run time (port of `src/runtime.zig`).
//!
//! The registry itself is ported later; these are the lookups the format
//! layer asks of it, answering "no such language" until then.

use crate::format::{Feature, Format};

/// The first wire code that names a runtime language.
pub const BASE: u16 = 4096;

pub fn is_registered(fmt: Format) -> bool {
    matches!(fmt, Format::Runtime(c) if slot_exists(c))
}

fn slot_exists(_code: u16) -> bool {
    false
}

pub fn format_from_code(code: i64) -> Option<Format> {
    let c = u16::try_from(code).ok()?;
    if c >= BASE && slot_exists(c) { Some(Format::Runtime(c)) } else { None }
}

pub fn name_of(_code: u16) -> String {
    String::new()
}

pub fn dialect_of(_code: u16) -> Option<Format> {
    None
}

pub fn target_code_of(code: u16) -> u16 {
    code
}

pub fn reads_back_as(code: u16) -> Option<Format> {
    if slot_exists(code) { Some(Format::Runtime(code)) } else { None }
}

pub fn features_of(_fmt: Format) -> Vec<Feature> {
    Vec::new()
}

pub fn by_name(_name: &str) -> Option<Format> {
    None
}

pub fn by_extension(_ext: &str) -> Option<Format> {
    None
}

/// Whether a runtime target prints.
pub fn prints(_code: u16) -> bool {
    false
}

/// What the fidelity probe measured for a runtime target.
pub fn measured(_target: crate::format::Target) -> Option<std::sync::Arc<crate::diagnostics::Measured>> {
    None
}
