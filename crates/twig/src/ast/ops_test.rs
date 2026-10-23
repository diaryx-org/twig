use super::*;

fn ins(s: &str) -> Op {
    Op::Insert(s.as_bytes().to_vec())
}

fn run(source: &str, ops: &[Op]) -> String {
    String::from_utf8(apply(source.as_bytes(), ops).expect("ops fit the source")).unwrap()
}

/// A small deterministic generator, so a failure names its seed.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    /// A short text over a few one-, two- and three-byte characters, so
    /// runs repeat and character boundaries matter.
    fn text(&mut self, max: usize) -> String {
        const CHARS: [char; 7] = ['a', 'b', '*', '\n', 'é', 'è', '中'];
        (0..self.below(max + 1)).map(|_| CHARS[self.below(CHARS.len())]).collect()
    }

    /// Random ops over `source`, every position on a character boundary.
    fn ops(&mut self, source: &str) -> Vec<Op> {
        let bounds: Vec<usize> = source.char_indices().map(|(i, _)| i).chain([source.len()]).collect();
        let mut out = Vec::new();
        let mut at = 0;
        for _ in 0..self.below(5) {
            let later: Vec<usize> = bounds.iter().copied().filter(|&b| b >= at).collect();
            let to = later[self.below(later.len())];
            match self.below(3) {
                0 => out.push(Op::Retain(to - at)),
                1 => out.push(Op::Delete(to - at)),
                _ => {
                    out.push(Op::Insert(self.text(3).into_bytes()));
                    continue;
                }
            }
            at = to;
        }
        out
    }
}

fn on_char_boundaries(source: &str, ops: &[Op]) -> bool {
    let mut at = 0;
    for op in ops {
        if !source.is_char_boundary(at) {
            return false;
        }
        match op {
            Op::Retain(n) | Op::Delete(n) => at += n,
            Op::Insert(t) => {
                if std::str::from_utf8(t).is_err() {
                    return false;
                }
            }
        }
    }
    source.is_char_boundary(at)
}

#[test]
fn canonical_merges_drops_and_puts_an_insert_before_a_delete() {
    let ops = canonical([
        Op::Retain(1),
        Op::Retain(2),
        Op::Delete(1),
        ins(""),
        ins("x"),
        Op::Delete(2),
        ins("y"),
        Op::Retain(0),
        Op::Retain(4),
    ]);
    assert_eq!(ops, vec![Op::Retain(3), ins("xy"), Op::Delete(3)]);
}

#[test]
fn apply_reads_from_the_start_and_keeps_what_the_ops_do_not_reach() {
    assert_eq!(run("hello world", &[Op::Retain(6), Op::Delete(5), ins("there")]), "hello there");
    assert_eq!(run("abc", &[ins(">")]), ">abc");
    assert_eq!(apply(b"abc", &[Op::Retain(2), Op::Delete(2)]), None);
}

#[test]
fn splice_deletes_the_whole_span_and_inserts_the_whole_text() {
    assert_eq!(splice(Span::new(2, 5), b"abc"), vec![Op::Retain(2), ins("abc"), Op::Delete(3)]);
    assert_eq!(splice(Span::new(4, 4), b""), Vec::<Op>::new());
}

#[test]
fn bounds_spans_the_first_change_to_the_last() {
    let c = bounds(&[Op::Retain(1), ins("**"), Op::Retain(4), ins("**")]);
    assert_eq!((c.old, c.new), (Span::new(1, 5), Span::new(1, 9)));
    let c = bounds(&[Op::Retain(2), Op::Delete(3)]);
    assert_eq!((c.old, c.new), (Span::new(2, 5), Span::new(2, 2)));
    let c = bounds(&[Op::Retain(5)]);
    assert_eq!((c.old, c.new), (Span::new(5, 5), Span::new(5, 5)));
}

#[test]
fn diff_wraps_a_word_with_two_inserts_and_keeps_the_word() {
    assert_eq!(diff(b"word", b"**word**"), vec![ins("**"), Op::Retain(4), ins("**")]);
    assert_eq!(diff(b"**word**", b"word"), vec![Op::Delete(2), Op::Retain(4), Op::Delete(2)]);
}

#[test]
fn diff_never_cuts_a_character() {
    // é is C3 A9 and è is C3 A8: a byte diff would keep the C3.
    assert_eq!(diff("é".as_bytes(), "è".as_bytes()), vec![ins("è"), Op::Delete(2)]);
    assert_eq!(diff("aéb".as_bytes(), "aèb".as_bytes()), vec![Op::Retain(1), ins("è"), Op::Delete(2)]);
}

#[test]
fn diff_past_its_bound_is_one_splice_between_the_common_ends() {
    let old = format!("<{}>", "a".repeat(MAX_EDITS));
    let new = format!("<{}>", "b".repeat(MAX_EDITS));
    let ops = diff(old.as_bytes(), new.as_bytes());
    assert_eq!(ops, vec![Op::Retain(1), ins(&"b".repeat(MAX_EDITS)), Op::Delete(MAX_EDITS)]);
    assert_eq!(run(&old, &ops), new);
}

#[test]
fn diff_applies_back_to_the_new_text_on_character_boundaries() {
    for seed in 1..2000u64 {
        let mut rng = Rng(seed);
        let old = rng.text(12);
        let new = rng.text(12);
        let ops = diff(old.as_bytes(), new.as_bytes());
        assert_eq!(run(&old, &ops), new, "seed {seed}: {old:?} -> {new:?} by {ops:?}");
        assert!(on_char_boundaries(&old, &ops), "seed {seed}: {ops:?}");
        assert_eq!(ops, canonical(ops.clone()), "seed {seed}");
    }
}

#[test]
fn diff_is_minimal_in_characters() {
    // The edits counted in characters never exceed what a plain LCS needs.
    fn lcs(a: &[char], b: &[char]) -> usize {
        let mut row = vec![0; b.len() + 1];
        for x in a {
            let mut diag = 0;
            for (j, y) in b.iter().enumerate() {
                let up = row[j + 1];
                row[j + 1] = if x == y { diag + 1 } else { row[j + 1].max(row[j]) };
                diag = up;
            }
        }
        row[b.len()]
    }
    for seed in 1..500u64 {
        let mut rng = Rng(seed);
        let old = rng.text(10);
        let new = rng.text(10);
        let ops = diff(old.as_bytes(), new.as_bytes());
        let mut edits = 0;
        let mut at = 0;
        for op in &ops {
            match op {
                Op::Retain(n) => at += n,
                Op::Delete(n) => {
                    edits += old[at..at + n].chars().count();
                    at += n;
                }
                Op::Insert(t) => edits += std::str::from_utf8(t).unwrap().chars().count(),
            }
        }
        let (a, b): (Vec<char>, Vec<char>) = (old.chars().collect(), new.chars().collect());
        assert_eq!(edits, a.len() + b.len() - 2 * lcs(&a, &b), "seed {seed}: {old:?} -> {new:?} by {ops:?}");
    }
}

#[test]
fn invert_gives_the_source_back() {
    for seed in 1..2000u64 {
        let mut rng = Rng(seed);
        let source = rng.text(10);
        let ops = rng.ops(&source);
        let made = run(&source, &ops);
        let back = invert(source.as_bytes(), &ops);
        assert_eq!(run(&made, &back), source, "seed {seed}: {ops:?}");
    }
}

#[test]
fn compose_is_one_then_the_other() {
    for seed in 1..2000u64 {
        let mut rng = Rng(seed);
        let source = rng.text(10);
        let first = rng.ops(&source);
        let middle = run(&source, &first);
        let then = rng.ops(&middle);
        let both = compose(&first, &then);
        assert_eq!(run(&source, &both), run(&middle, &then), "seed {seed}: {first:?} then {then:?} = {both:?}");
        assert_eq!(both, canonical(both.clone()), "seed {seed}");
    }
}

#[test]
fn compose_cancels_an_insert_the_second_edit_deletes() {
    let first = [Op::Retain(3), ins("xyz")];
    let then = [Op::Retain(4), Op::Delete(1)];
    assert_eq!(compose(&first, &then), vec![Op::Retain(3), ins("xz")]);
}
