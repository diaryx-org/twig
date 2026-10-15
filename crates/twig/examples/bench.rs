//! `cargo run --release --example bench -- [--format <fmt>] [--iters N] <file>`
//! — parse a document under a counting global allocator and report exactly how
//! many allocations and how many bytes it costs. Port of `src/bench/main.zig`.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering::Relaxed};

/// A pass-through allocator that counts every call and tracks live bytes.
struct Counting;

static ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);
static FREE_COUNT: AtomicU64 = AtomicU64::new(0);
static RESIZE_COUNT: AtomicU64 = AtomicU64::new(0);
static BYTES_ALLOCATED: AtomicU64 = AtomicU64::new(0);
static BYTES_LIVE: AtomicUsize = AtomicUsize::new(0);
static BYTES_PEAK: AtomicUsize = AtomicUsize::new(0);

fn grow_live(n: usize) {
    let live = BYTES_LIVE.fetch_add(n, Relaxed) + n;
    BYTES_PEAK.fetch_max(live, Relaxed);
}

// SAFETY: every method forwards to `System` unchanged; the counters are
// atomics and never touch the memory itself.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOC_COUNT.fetch_add(1, Relaxed);
        BYTES_ALLOCATED.fetch_add(layout.size() as u64, Relaxed);
        grow_live(layout.size());
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        FREE_COUNT.fetch_add(1, Relaxed);
        BYTES_LIVE.fetch_sub(layout.size(), Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        RESIZE_COUNT.fetch_add(1, Relaxed);
        if new_size > layout.size() {
            BYTES_ALLOCATED.fetch_add((new_size - layout.size()) as u64, Relaxed);
            grow_live(new_size - layout.size());
        } else {
            BYTES_LIVE.fetch_sub(layout.size() - new_size, Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

#[derive(Clone, Copy, Debug)]
enum Format {
    Djot,
    Markdown,
    Html,
    Xml,
}

fn infer_format(path: &str) -> Option<Format> {
    let ext = path.rsplit_once('.')?.1.to_ascii_lowercase();
    match ext.as_str() {
        "dj" | "djot" => Some(Format::Djot),
        "md" | "markdown" => Some(Format::Markdown),
        "html" | "htm" => Some(Format::Html),
        "xml" => Some(Format::Xml),
        _ => None,
    }
}

fn fail(msg: String) -> ! {
    eprintln!("bench: {msg}");
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut path: Option<String> = None;
    let mut forced: Option<Format> = None;
    let mut iters: usize = 1;
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--format" || a == "-f" {
            i += 1;
            let v = args.get(i).unwrap_or_else(|| fail("--format needs a value".into()));
            forced = Some(match v.as_str() {
                "djot" => Format::Djot,
                "markdown" => Format::Markdown,
                "html" => Format::Html,
                "xml" => Format::Xml,
                _ => fail(format!("unknown format '{v}' (djot|markdown|html|xml)")),
            });
        } else if a == "--iters" || a == "-n" {
            i += 1;
            let v = args.get(i).unwrap_or_else(|| fail("--iters needs a value".into()));
            iters = v.parse().unwrap_or_else(|_| fail(format!("bad --iters '{v}'")));
            if iters == 0 {
                fail("--iters must be >= 1".into());
            }
        } else if path.is_none() {
            path = Some(a.clone());
        } else {
            fail(format!("unexpected extra argument '{a}'"));
        }
        i += 1;
    }
    let file = path.unwrap_or_else(|| fail("usage: bench [--format <fmt>] [--iters N] <file>".into()));
    let fmt = forced.or_else(|| infer_format(&file)).unwrap_or_else(|| fail(format!("cannot infer format of '{file}'; pass --format")));
    let source = std::fs::read(&file).unwrap_or_else(|e| fail(format!("could not read '{file}': {e}")));

    let base = (ALLOC_COUNT.load(Relaxed), FREE_COUNT.load(Relaxed), RESIZE_COUNT.load(Relaxed), BYTES_ALLOCATED.load(Relaxed));
    let live0 = BYTES_LIVE.load(Relaxed);
    BYTES_PEAK.store(live0, Relaxed);
    for _ in 0..iters {
        match fmt {
            Format::Djot => drop(twig::languages::djot::parse(&source)),
            Format::Markdown => drop(twig::languages::markdown::parse(&source, Default::default())),
            Format::Html => drop(twig::languages::html::parse(&source)),
            Format::Xml => match twig::languages::xml::parse(&source) {
                Ok(d) => drop(d),
                Err(e) => fail(format!("xml parse failed: {}", e.name())),
            },
        }
    }
    let alloc_count = ALLOC_COUNT.load(Relaxed) - base.0;
    let free_count = FREE_COUNT.load(Relaxed) - base.1;
    let resize_count = RESIZE_COUNT.load(Relaxed) - base.2;
    let bytes_allocated = BYTES_ALLOCATED.load(Relaxed) - base.3;
    let live = BYTES_LIVE.load(Relaxed) as i64 - live0 as i64;
    let peak = BYTES_PEAK.load(Relaxed) - live0;
    let fi = iters as f64;
    println!("file        : {file}");
    println!("format      : {}", format!("{fmt:?}").to_lowercase());
    println!("source      : {} bytes", source.len());
    println!("iterations  : {iters}");
    println!();
    println!("── totals over all iterations ──");
    println!("allocs      : {alloc_count}");
    println!("frees       : {free_count}");
    println!("resizes     : {resize_count}");
    println!("bytes alloc : {bytes_allocated}");
    println!("bytes peak  : {peak}");
    println!();
    println!("── per iteration ──");
    println!("allocations : {:.1}", alloc_count as f64 / fi);
    println!("bytes alloc : {:.0}", bytes_allocated as f64 / fi);
    let per = if source.is_empty() { 0.0 } else { bytes_allocated as f64 / (fi * source.len() as f64) };
    println!("bytes/byte  : {per:.2}  (alloc'd bytes per source byte)");
    if live != 0 {
        println!("\nWARNING: {live} bytes still live after drop (leak?)");
    }
}
