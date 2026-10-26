//! Edit ops: an edit as a list of retain, insert and delete over the whole
//! source, rather than a span and the bytes that replace it.
//!
//! ── Why ops ────────────────────────────────────────────────────────────────
//! A replacement says "these bytes go, and these come", even where most of
//! what comes is what went: Cmd-B over a word replaces the word with itself in
//! delimiters. A merge that takes that edit against a concurrent one inside the
//! word has to drop one of them. Ops say only what changed — two inserts, and
//! the word retained — so a merge keeps both. They are also what an undo step
//! keeps instead of a copy of the whole source.
//!
//! ── The shape ──────────────────────────────────────────────────────────────
//! Ops read the source from its start: `Retain(n)` keeps the next `n` bytes,
//! `Delete(n)` removes them, `Insert(bytes)` writes bytes at the place
//! reached. Whatever the ops do not reach is kept, so a retain at the end is
//! left out. [`canonical`] gives one change one spelling: no zero-length op,
//! no two ops of a kind side by side, and an insert before a delete at one
//! place.

use crate::ast::splicer::Change;
use crate::span::Span;

/// One step of an edit, read against the source from its start.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Op {
    /// Keep the next `n` bytes.
    Retain(usize),
    /// Write these bytes here.
    Insert(Vec<u8>),
    /// Remove the next `n` bytes.
    Delete(usize),
}

/// How many bytes of the source `ops` read: their retains and deletes. Held
/// at `usize::MAX` rather than wrapping, since no source is that long.
pub fn input_len(ops: &[Op]) -> usize {
    ops.iter().fold(0, |sum, op| match op {
        Op::Retain(n) | Op::Delete(n) => sum.saturating_add(*n),
        Op::Insert(_) => sum,
    })
}

/// `ops` in their one spelling. Between two retains, every insert is written
/// first, as one, and every delete after it, as one. A run that would pass
/// `usize::MAX` is held there: it reads past any source either way.
pub fn canonical(ops: impl IntoIterator<Item = Op>) -> Vec<Op> {
    let mut out = Vec::new();
    let mut retain = 0usize;
    let mut insert: Vec<u8> = Vec::new();
    let mut delete = 0usize;
    for op in ops {
        match op {
            Op::Retain(0) | Op::Delete(0) => {}
            Op::Insert(t) if t.is_empty() => {}
            Op::Retain(n) => {
                flush_run(&mut out, &mut insert, &mut delete);
                retain = retain.saturating_add(n);
            }
            Op::Insert(t) => {
                flush_retain(&mut out, &mut retain);
                insert.extend_from_slice(&t);
            }
            Op::Delete(n) => {
                flush_retain(&mut out, &mut retain);
                delete = delete.saturating_add(n);
            }
        }
    }
    flush_run(&mut out, &mut insert, &mut delete);
    out
}

fn flush_retain(out: &mut Vec<Op>, retain: &mut usize) {
    if *retain > 0 {
        out.push(Op::Retain(std::mem::take(retain)));
    }
}

fn flush_run(out: &mut Vec<Op>, insert: &mut Vec<u8>, delete: &mut usize) {
    if !insert.is_empty() {
        out.push(Op::Insert(std::mem::take(insert)));
    }
    if *delete > 0 {
        out.push(Op::Delete(std::mem::take(delete)));
    }
}

/// The ops that replace `[span.start, span.end)` with `text`, as asked: the
/// whole span deleted and the whole of `text` inserted.
pub fn splice(span: Span, text: &[u8]) -> Vec<Op> {
    canonical([Op::Retain(span.start), Op::Insert(text.to_vec()), Op::Delete(span.len())])
}

/// `source` with `ops` applied, or `None` when they read past its end.
pub fn apply(source: &[u8], ops: &[Op]) -> Option<Vec<u8>> {
    if input_len(ops) > source.len() {
        return None;
    }
    let mut out = Vec::with_capacity(source.len());
    let mut at = 0;
    for op in ops {
        match op {
            Op::Retain(n) => {
                out.extend_from_slice(&source[at..at + n]);
                at += n;
            }
            Op::Insert(t) => out.extend_from_slice(t),
            Op::Delete(n) => at += n,
        }
    }
    out.extend_from_slice(&source[at..]);
    Some(out)
}

/// The ops that undo `ops`: read against the text `ops` made from `source`,
/// they give `source` back. A delete becomes an insert of the bytes it took,
/// so `source` must be the text `ops` were applied to.
pub fn invert(source: &[u8], ops: &[Op]) -> Vec<Op> {
    let mut out = Vec::with_capacity(ops.len());
    let mut at = 0;
    for op in ops {
        match op {
            Op::Retain(n) => {
                out.push(Op::Retain(*n));
                at += n;
            }
            Op::Insert(t) => out.push(Op::Delete(t.len())),
            Op::Delete(n) => {
                out.push(Op::Insert(source[at..at + n].to_vec()));
                at += n;
            }
        }
    }
    canonical(out)
}

/// The one list of ops that does `first` and then `then`, where `then` reads
/// the text `first` made.
pub fn compose(first: &[Op], then: &[Op]) -> Vec<Op> {
    let mut a = Cursor::new(first);
    let mut b = Cursor::new(then);
    let mut out = Vec::new();
    loop {
        // What `first` deleted never reaches `then`; what `then` inserts
        // reads nothing of `first`.
        if let Some(Op::Delete(n)) = a.peek() {
            out.push(Op::Delete(n));
            a.take(n);
            continue;
        }
        if let Some(Op::Insert(t)) = b.peek() {
            b.take(t.len());
            out.push(Op::Insert(t));
            continue;
        }
        // Past their ends both keep what is left, so once both are spent
        // the rest is a retain, which is left out.
        let (x, y) = match (a.peek(), b.peek()) {
            (None, None) => break,
            (x, y) => (x.unwrap_or(Op::Retain(usize::MAX)), y.unwrap_or(Op::Retain(usize::MAX))),
        };
        let n = op_len(&x).min(op_len(&y));
        match (x, y) {
            (Op::Retain(_), Op::Retain(_)) => out.push(Op::Retain(n)),
            (Op::Retain(_), Op::Delete(_)) => out.push(Op::Delete(n)),
            (Op::Insert(t), Op::Retain(_)) => out.push(Op::Insert(t[..n].to_vec())),
            // `then` deletes what `first` inserted: neither reaches the result.
            (Op::Insert(_), Op::Delete(_)) => {}
            _ => unreachable!("deletes of `first` and inserts of `then` are taken above"),
        }
        a.take(n);
        b.take(n);
    }
    canonical(out)
}

fn op_len(op: &Op) -> usize {
    match op {
        Op::Retain(n) | Op::Delete(n) => *n,
        Op::Insert(t) => t.len(),
    }
}

/// A walk over a list of ops that can take part of one.
struct Cursor<'a> {
    ops: &'a [Op],
    /// How much of `ops[0]` is already taken.
    used: usize,
}

impl<'a> Cursor<'a> {
    fn new(ops: &'a [Op]) -> Cursor<'a> {
        Cursor { ops, used: 0 }
    }

    /// What is left of the current op, or `None` past the end.
    fn peek(&self) -> Option<Op> {
        let op = self.ops.first()?;
        Some(match op {
            Op::Retain(n) => Op::Retain(n - self.used),
            Op::Delete(n) => Op::Delete(n - self.used),
            Op::Insert(t) => Op::Insert(t[self.used..].to_vec()),
        })
    }

    /// Take `n` of the current op, moving on when it is spent. Past the end
    /// it does nothing.
    fn take(&mut self, n: usize) {
        let Some(op) = self.ops.first() else { return };
        self.used += n;
        if self.used >= op_len(op) {
            self.ops = &self.ops[1..];
            self.used = 0;
        }
    }
}

/// The span `ops` change, as a [`Change`]: `old` from the first byte they
/// insert at or delete to the end of the last, `new` the same edit in the
/// text they make. Ops that change nothing give an empty change where they
/// stop reading.
pub fn bounds(ops: &[Op]) -> Change {
    let (mut old_at, mut new_at) = (0, 0);
    // Only retains come before the first change, so it starts at one offset
    // in both texts.
    let mut start: Option<usize> = None;
    let (mut old_end, mut new_end) = (0, 0);
    for op in ops {
        match op {
            Op::Retain(n) => {
                old_at += n;
                new_at += n;
                continue;
            }
            Op::Insert(t) if t.is_empty() => continue,
            Op::Delete(0) => continue,
            _ => {}
        }
        start.get_or_insert(old_at);
        match op {
            Op::Insert(t) => new_at += t.len(),
            Op::Delete(n) => old_at += n,
            Op::Retain(_) => unreachable!(),
        }
        old_end = old_at;
        new_end = new_at;
    }
    match start {
        None => Change { old: Span::new(old_at, old_at), new: Span::new(new_at, new_at) },
        Some(s) => Change { old: Span::new(s, old_end), new: Span::new(s, new_end) },
    }
}

// ── the fewest ops between two texts ───────────────────────────────────────

/// The most edits [`diff`] looks for before it settles for one splice of
/// whatever lies between the common prefix and suffix. It bounds the walk's
/// memory (about `MAX_EDITS² / 2` words) and its time.
pub const MAX_EDITS: usize = 512;

/// A ceiling on the bytes compared along matching runs, with the same purpose.
const MAX_WORK: usize = 4_000_000;

/// The fewest ops that turn `old` into `new`, cut on character boundaries:
/// no op ends inside a UTF-8 sequence of either text. Past [`MAX_EDITS`]
/// edits, one splice of what lies between the common prefix and suffix.
pub fn diff(old: &[u8], new: &[u8]) -> Vec<Op> {
    let (pre, suf) = common_ends(old, new);
    let a = tokens(&old[pre..old.len() - suf]);
    let b = tokens(&new[pre..new.len() - suf]);
    let mut out = vec![Op::Retain(pre)];
    match myers(&a, &b) {
        Some(script) => {
            let (mut i, mut j) = (0, 0);
            for (kind, n) in script {
                match kind {
                    Step::Keep => {
                        out.push(Op::Retain(a[i..i + n].iter().map(|t| t.len()).sum()));
                        i += n;
                        j += n;
                    }
                    Step::Remove => {
                        out.push(Op::Delete(a[i..i + n].iter().map(|t| t.len()).sum()));
                        i += n;
                    }
                    Step::Add => {
                        out.push(Op::Insert(b[j..j + n].concat()));
                        j += n;
                    }
                }
            }
        }
        None => {
            out.push(Op::Insert(new[pre..new.len() - suf].to_vec()));
            out.push(Op::Delete(old.len() - suf - pre));
        }
    }
    canonical(out)
}

/// A UTF-8 continuation byte: one that never begins a character.
fn continues(b: u8) -> bool {
    b & 0xC0 == 0x80
}

/// Whether byte offset `at` of `s` lies between two characters.
fn on_boundary(s: &[u8], at: usize) -> bool {
    at == s.len() || !continues(s[at])
}

/// The common prefix and suffix of `old` and `new`, in bytes, each ending on
/// a character boundary of both and not overlapping.
fn common_ends(old: &[u8], new: &[u8]) -> (usize, usize) {
    let min = old.len().min(new.len());
    let mut pre = old.iter().zip(new).take_while(|(x, y)| x == y).count();
    while pre > 0 && !(on_boundary(old, pre) && on_boundary(new, pre)) {
        pre -= 1;
    }
    let mut suf = old.iter().rev().zip(new.iter().rev()).take(min - pre).take_while(|(x, y)| x == y).count();
    while suf > 0 && !(on_boundary(old, old.len() - suf) && on_boundary(new, new.len() - suf)) {
        suf -= 1;
    }
    (pre, suf)
}

/// `s` cut into characters: each token is a byte that is not a continuation
/// byte and the continuation bytes after it.
fn tokens(s: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < s.len() {
        let mut j = i + 1;
        while j < s.len() && continues(s[j]) {
            j += 1;
        }
        out.push(&s[i..j]);
        i = j;
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    Keep,
    Remove,
    Add,
}

/// Unreached, in a round's furthest-x table.
const NONE: i64 = -1;

/// Myers' greedy shortest edit script from `a` to `b`, as runs of steps, or
/// `None` when it takes more than [`MAX_EDITS`] edits or [`MAX_WORK`]
/// comparisons. Round `d` keeps, for each diagonal `k = x - y` in `-d..=d` of
/// its parity, the furthest `x` reached with `d` edits.
fn myers<T: PartialEq>(a: &[T], b: &[T]) -> Option<Vec<(Step, usize)>> {
    let (n, m) = (a.len() as i64, b.len() as i64);
    if n == 0 || m == 0 {
        let mut script = Vec::new();
        if n > 0 {
            script.push((Step::Remove, a.len()));
        }
        if m > 0 {
            script.push((Step::Add, b.len()));
        }
        return Some(script);
    }
    // Furthest x on diagonal k after round d, from that round's table.
    fn at(round: &[i64], d: i64, k: i64) -> i64 {
        if k < -d || k > d {
            return NONE;
        }
        round[((k + d) / 2) as usize]
    }
    // Where round d reaches diagonal k from, given round d - 1: down from
    // k + 1 (an add) or right from k - 1 (a remove), whichever goes further.
    // `None` when neither move stays in the grid.
    let step = |prev: &[i64], d: i64, k: i64| -> Option<(Step, i64)> {
        let down = at(prev, d - 1, k + 1);
        let down = (down != NONE && down - (k + 1) < m).then_some(down);
        let right = at(prev, d - 1, k - 1);
        let right = (right != NONE && right < n).then_some(right + 1);
        match (down, right) {
            (Some(x), Some(y)) if x >= y => Some((Step::Add, x)),
            (_, Some(y)) => Some((Step::Remove, y)),
            (Some(x), None) => Some((Step::Add, x)),
            (None, None) => None,
        }
    };
    let mut rounds: Vec<Vec<i64>> = Vec::new();
    let mut work = 0usize;
    for d in 0..=(MAX_EDITS as i64).min(n + m) {
        let mut round = vec![NONE; d as usize + 1];
        for i in 0..=d {
            let k = 2 * i - d;
            let mut x = if d == 0 {
                0
            } else {
                match step(&rounds[d as usize - 1], d, k) {
                    Some((_, x)) => x,
                    None => continue,
                }
            };
            let mut y = x - k;
            if y < 0 || y > m {
                continue;
            }
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
                work += 1;
            }
            round[i as usize] = x;
            if x == n && y == m {
                rounds.push(round);
                return Some(backtrack(&rounds, n, m, step));
            }
        }
        work += d as usize + 1;
        if work > MAX_WORK {
            return None;
        }
        rounds.push(round);
    }
    None
}

/// The script, read back from the last round to the first.
fn backtrack(
    rounds: &[Vec<i64>],
    n: i64,
    m: i64,
    step: impl Fn(&[i64], i64, i64) -> Option<(Step, i64)>,
) -> Vec<(Step, usize)> {
    let mut rev: Vec<(Step, usize)> = Vec::new();
    let push = |rev: &mut Vec<(Step, usize)>, s: Step, len: usize| {
        if len == 0 {
            return;
        }
        match rev.last_mut() {
            Some((last, l)) if *last == s => *l += len,
            _ => rev.push((s, len)),
        }
    };
    let (mut x, mut y) = (n, m);
    for d in (1..rounds.len() as i64).rev() {
        let k = x - y;
        let (s, from_x) = step(&rounds[d as usize - 1], d, k).expect("a reached diagonal was reached from somewhere");
        // The move lands at (from_x, from_x - k); the run of matches after it
        // reaches (x, y).
        push(&mut rev, Step::Keep, (x - from_x) as usize);
        push(&mut rev, s, 1);
        let (px, py) = match s {
            Step::Add => (from_x, from_x - k - 1),
            _ => (from_x - 1, from_x - k),
        };
        x = px;
        y = py;
    }
    push(&mut rev, Step::Keep, x as usize);
    debug_assert_eq!(x, y);
    rev.reverse();
    rev
}

#[cfg(test)]
#[path = "ops_test.rs"]
mod ops_test;
