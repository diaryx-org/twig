//! The public, binding-compatible API: the same types and methods the FFI
//! crate `twig-doc` 4.x exposed over the C ABI (`bindings/rust/twig`), now
//! implemented directly over the Rust engine. Re-exported at the crate root.
//!
//! Each method is the port of the `twig_*` function in `src/c_abi.zig` the
//! binding called: the same engine calls, the same status-to-[`Error`]
//! mapping, the same answers for "no such node".

mod builder;
mod document;
mod editor;
mod format;
mod kind;

pub use builder::{Builder, BulletStyle, NodeId, OrderedDelim, OrderedNumbering, SmartPunctuation, TextKind, VoidKind};
pub use document::{
    Alignment, ContainerOrigin, DirectiveForm, Document, DocumentView, Fidelity, FlatNode, LinePrefix, QueryMatch,
    Warning,
};
pub use editor::{Change, Editor, Op};
pub use format::{
    abi_version, version, version_string, BlockContainerKind, BlockKind, Format, Gesture, InlineKind, MarkColor,
    Target, Version, ABI_VERSION, FORMAT_RUNTIME_BASE,
};
pub use kind::Kind;

/// A byte range `[start, end)` into the source — the binding's re-export of
/// the C ABI's `TwigSpan`.
pub use crate::span::Span;

#[allow(unused_imports)]
use crate::error::Error; // for the intra-doc links above
