use std::fmt;

use crate::ffi;

/// Error is non_exhaustive so future additions
/// are not major semver bumps
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
    /// The edit produced a document that no longer parses; it was rolled back
    /// (editor).
    EditConflict,
    /// A metadata block's body contains `</script`, so it can't be emitted into
    /// a raw-text `<script>` HTML data island without an injection risk; the
    /// HTML printer refused (render/serialize-to-HTML).
    UnsafeMetadata,
    Internal,
}

impl Error {
    pub(crate) fn from_status(status: ffi::TwigStatus) -> Result<(), Self> {
        match status.0 {
            ffi::TwigStatus::OK => Ok(()),
            ffi::TwigStatus::INVALID_ARGUMENT => Err(Self::InvalidArgument),
            ffi::TwigStatus::PARSE_ERROR => Err(Self::ParseError),
            ffi::TwigStatus::OUT_OF_MEMORY => Err(Self::OutOfMemory),
            ffi::TwigStatus::UNSUPPORTED_FORMAT => Err(Self::UnsupportedFormat),
            ffi::TwigStatus::NOT_FOUND => Err(Self::NotFound),
            ffi::TwigStatus::AMBIGUOUS => Err(Self::Ambiguous),
            ffi::TwigStatus::NOT_EDITABLE => Err(Self::NotEditable),
            ffi::TwigStatus::EDIT_CONFLICT => Err(Self::EditConflict),
            ffi::TwigStatus::UNSAFE_METADATA => Err(Self::UnsafeMetadata),
            _ => Err(Self::Internal),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidArgument => f.write_str("invalid argument"),
            Error::ParseError => f.write_str("parse error"),
            Error::OutOfMemory => f.write_str("out of memory"),
            Error::UnsupportedFormat => f.write_str("unsupported format"),
            Error::NotFound => f.write_str("locator matched no node"),
            Error::Ambiguous => f.write_str("selector matched more than one node"),
            Error::NotEditable => f.write_str("node has no editable span"),
            Error::EditConflict => f.write_str("edit produced an unparseable document"),
            Error::UnsafeMetadata => {
                f.write_str("metadata contains </script; unsafe to embed in HTML")
            }
            Error::Internal => f.write_str("internal error"),
        }
    }
}

impl std::error::Error for Error {}
