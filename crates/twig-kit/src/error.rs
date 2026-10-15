//! The error vocabulary of the public API (the C ABI's status codes).

use std::fmt;

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
#[non_exhaustive]
pub enum Error {
    InvalidArgument,
    ParseError,
    OutOfMemory,
    UnsupportedFormat,
    /// A locator resolved to no node (editor).
    NotFound,
    /// A selector locator matched more than one node (editor).
    Ambiguous,
    /// The target node has no editable span/interior (editor).
    NotEditable,
    /// The edit produced a document that no longer parses; it was rolled back.
    EditConflict,
    /// A metadata block's body contains `</script`; the HTML printer refused.
    UnsafeMetadata,
    /// A language was refused at registration.
    InvalidLanguage,
    Internal,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Error::InvalidArgument => "invalid argument",
            Error::ParseError => "parse error",
            Error::OutOfMemory => "out of memory",
            Error::UnsupportedFormat => "unsupported format",
            Error::NotFound => "locator matched no node",
            Error::Ambiguous => "selector matched more than one node",
            Error::NotEditable => "node has no editable span",
            Error::EditConflict => "edit produced an unparseable document",
            Error::UnsafeMetadata => "metadata contains </script; unsafe to embed in HTML",
            Error::InvalidLanguage => "language refused at registration",
            Error::Internal => "internal error",
        })
    }
}

impl std::error::Error for Error {}
