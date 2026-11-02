//! `cargo run --release --example bench_corpus -- [--docs N] [--rounds R]` —
//! time a consumer that parses many small documents, as prov does a
//! workspace: N Markdown documents (10,101 by default) of ~300 words of prose
//! under YAML frontmatter, each with one inline link. Every pass is run R
//! times (5) and its fastest and median round reported, with the
//! allocations one document costs.
//!
//! - `body`: `Document::parse_str` over each body, the frontmatter cut off;
//! - `body+nodes`: that, then the spans of its links, images and code read
//!   off `Document::nodes`, which is what prov's link scan does;
//! - `parse_host+find`: `meta::parse_host` over each whole document, then
//!   `meta::find(.., Where::Front)`, which is how prov located frontmatter;
//! - `body, threaded`: `body` split across `--threads` threads (all the
//!   machine's by default), as prov's census parses on rayon's pool. Its
//!   `µs/doc` is wall time over the corpus; it counts no allocations.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::time::{Duration, Instant};

/// A pass-through allocator that counts allocations while [`COUNTING`] is
/// on. Off, it adds no shared write, which would serialize threads.
struct Counting;

static ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);
static COUNTING: AtomicBool = AtomicBool::new(true);

fn count() {
    if COUNTING.load(Relaxed) {
        ALLOC_COUNT.fetch_add(1, Relaxed);
    }
}

// SAFETY: every method forwards to `System` unchanged; the counter is an
// atomic and never touches the memory itself.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count();
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        count();
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

const WORDS: &[&str] = &[
    "the", "of", "and", "a", "to", "in", "is", "that", "it", "was", "for", "on", "are", "with", "as", "document",
    "workspace", "parser", "block", "inline", "provenance", "record", "every", "small", "which", "would", "there",
    "their", "about", "between", "through", "without", "because", "another", "question", "answer", "reading",
    "written", "change", "history", "commit", "release", "server", "client", "number", "letter", "window",
];

/// A deterministic word stream (a 64-bit LCG), so every run parses the same
/// corpus.
struct Words(u64);

impl Words {
    fn next(&mut self) -> &'static str {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        WORDS[(self.0 >> 33) as usize % WORDS.len()]
    }
}

/// Document `i`: its frontmatter and its body, separately.
fn document(i: usize, words: &mut Words) -> (String, String) {
    let front = format!(
        "---\ntitle: Note {i}\nauthor: someone\ncreated: 2026-10-{:02}\npart_of: '[Index](/index.md)'\ntags:\n- notes\n- corpus\n---\n",
        i % 28 + 1
    );
    let mut body = format!("\n# Note {i}\n\n");
    let link_at = 150;
    for w in 0..300 {
        if w > 0 && w % 60 == 0 {
            body.push_str(".\n\n");
        } else if w > 0 && w % 12 == 0 {
            body.push_str(",\n");
        } else if w > 0 {
            body.push(' ');
        }
        if w == link_at {
            body.push_str(&format!("[note {}](/notes/note-{}.md)", (i + 1) % 10_101, (i + 1) % 10_101));
        } else {
            body.push_str(words.next());
        }
    }
    body.push_str(".\n");
    (front, body)
}

struct Pass {
    name: &'static str,
    rounds: Vec<Duration>,
    allocs: u64,
}

fn run(name: &'static str, rounds: usize, docs: usize, mut each: impl FnMut() -> usize) -> Pass {
    let mut times = Vec::new();
    let mut allocs = 0;
    let mut check = 0;
    for _ in 0..rounds {
        let a0 = ALLOC_COUNT.load(Relaxed);
        let t = Instant::now();
        check = each();
        times.push(t.elapsed());
        allocs = ALLOC_COUNT.load(Relaxed) - a0;
    }
    std::hint::black_box(check);
    times.sort();
    Pass { name, rounds: times, allocs: allocs / docs as u64 }
}

fn fail(msg: String) -> ! {
    eprintln!("bench_corpus: {msg}");
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut docs = 10_101usize;
    let mut rounds = 5usize;
    let mut threads = std::thread::available_parallelism().map_or(4, |n| n.get());
    let mut i = 0;
    while i < args.len() {
        let v = args.get(i + 1).unwrap_or_else(|| fail(format!("{} needs a value", args[i])));
        let n: usize = v.parse().unwrap_or_else(|_| fail(format!("bad value '{v}'")));
        match args[i].as_str() {
            "--docs" | "-n" => docs = n.max(1),
            "--rounds" | "-r" => rounds = n.max(1),
            "--threads" | "-t" => threads = n.max(1),
            a => fail(format!("unexpected argument '{a}'")),
        }
        i += 2;
    }
    let md = twig_markdown::format();
    let mut words = Words(0x5eed);
    let corpus: Vec<(String, String)> = (0..docs).map(|i| document(i, &mut words)).collect();
    let whole: Vec<String> = corpus.iter().map(|(f, b)| format!("{f}{b}")).collect();
    let bytes: usize = whole.iter().map(String::len).sum();

    let passes = [
        run("body", rounds, docs, || {
            corpus.iter().map(|(_, b)| drop(twig::Document::parse_str(b, md).unwrap())).count()
        }),
        run("body+nodes", rounds, docs, || {
            let mut n = 0;
            for (_, b) in &corpus {
                let mut doc = twig::Document::parse_str(b, md).unwrap();
                for node in doc.nodes().unwrap() {
                    if matches!(
                        node.kind,
                        twig::Kind::Link
                            | twig::Kind::Image
                            | twig::Kind::Verbatim
                            | twig::Kind::CodeBlock
                            | twig::Kind::RawInline
                            | twig::Kind::RawBlock
                    ) {
                        n += node.span.len();
                    }
                }
            }
            n
        }),
        run("parse_host+find", rounds, docs, || {
            let mut n = 0;
            for w in &whole {
                let parsed = twig::meta::parse_host(w.as_bytes(), md).unwrap();
                n += twig::meta::find(&parsed.doc, twig::meta::Where::Front).unwrap().span.len();
            }
            n
        }),
        run("body, threaded", rounds, docs, || {
            COUNTING.store(false, Relaxed);
            let chunk = corpus.len().div_ceil(threads);
            std::thread::scope(|s| {
                let handles: Vec<_> = corpus
                    .chunks(chunk)
                    .map(|part| {
                        s.spawn(move || part.iter().map(|(_, b)| drop(twig::Document::parse_str(b, md).unwrap())).count())
                    })
                    .collect();
                let n = handles.into_iter().map(|h| h.join().unwrap()).sum();
                COUNTING.store(true, Relaxed);
                n
            })
        }),
    ];

    println!("{docs} documents, {bytes} bytes, {rounds} rounds, {threads} threads");
    println!("{:<18} {:>10} {:>10} {:>10} {:>12}", "pass", "min ms", "median ms", "µs/doc", "allocs/doc");
    for p in &passes {
        let min = p.rounds[0];
        let median = p.rounds[p.rounds.len() / 2];
        println!(
            "{:<18} {:>10.1} {:>10.1} {:>10.2} {:>12}",
            p.name,
            min.as_secs_f64() * 1e3,
            median.as_secs_f64() * 1e3,
            min.as_secs_f64() * 1e6 / docs as f64,
            p.allocs
        );
    }
}
