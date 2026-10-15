//! The configured runtime languages (`languages` files). Port of
//! `src/cli/languages.zig` — the lookup surface first; loading is ported with
//! the runtime registry.

use crate::format::Format;

#[derive(Clone, Debug, Default)]
pub struct Configured {
    pub name: String,
    pub extensions: Vec<String>,
    pub command: Vec<String>,
}

pub fn configured() -> Vec<Configured> {
    Vec::new()
}

pub fn resolve_name(_name: &str) -> Option<Format> {
    None
}

pub fn resolve_extension(_ext: &str) -> Option<Format> {
    None
}
