//! A byte range `[start, end)` into a document's source.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub const fn new(start: usize, end: usize) -> Span {
        Span { start, end }
    }

    pub const fn len(self) -> usize {
        self.end - self.start
    }

    pub const fn is_empty(self) -> bool {
        self.end == self.start
    }

    /// The bytes of `slice` this span addresses.
    pub fn of(self, slice: &[u8]) -> &[u8] {
        &slice[self.start..self.end]
    }

    pub fn range(self) -> std::ops::Range<usize> {
        self.start..self.end
    }
}

impl From<std::ops::Range<usize>> for Span {
    fn from(r: std::ops::Range<usize>) -> Span {
        Span::new(r.start, r.end)
    }
}
