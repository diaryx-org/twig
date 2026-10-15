//! The shared node vocabulary and the tree-level operations. The vocabulary,
//! the tree, the selectors and the node table are the kit's
//! ([`twig_kit::ast`], re-exported here); the splicer, the editor and the
//! locators that drive it are core's.

pub use twig_kit::ast::*;

pub mod editor;
pub mod filter;
pub mod locate;
pub mod locator;
pub mod splicer;
pub mod table_edit;
