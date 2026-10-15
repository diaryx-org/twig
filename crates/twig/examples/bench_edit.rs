//! `cargo run --release --example bench_edit -- [--keys N] <file.dj>` — what
//! a keystroke costs through a runtime row, against the compiled row it
//! twins. Port of `src/bench/edit.zig`: the twin is djot's own parser written
//! out as a node table and read back, so the difference between the two rows
//! is what the runtime contract costs.

#[path = "../tests/common/mod.rs"]
mod common;

use std::time::{Duration, Instant};

use twig::ast::splicer::{ParseError, Splicer};
use twig::ast::table;
use twig::format::{self, Format, ParseConfig};
use twig::runtime;

struct Result {
    parse: Duration,
    p50: Duration,
    p95: Duration,
}

fn measure(fmt: Format, source: &[u8], keys: usize) -> Result {
    let cfg = ParseConfig::default();
    let parse = (0..5)
        .map(|_| {
            let t0 = Instant::now();
            let doc = format::parse_to_ast(fmt, &cfg, source).expect("parse");
            let t = t0.elapsed();
            drop(doc);
            t
        })
        .min()
        .unwrap();
    let reparse = Box::new(move |src: &[u8]| format::parse_to_ast(fmt, &cfg, src).map_err(|e| ParseError::new(e.name())));
    let mut splicer = Splicer::new(source, reparse).expect("splicer");
    let mut times: Vec<Duration> = (0..keys)
        .map(|_| {
            let at = splicer.source_bytes().len() / 2;
            let t0 = Instant::now();
            splicer.replace_at_span(twig::span::Span::new(at, at), b"x").expect("keystroke");
            t0.elapsed()
        })
        .collect();
    times.sort();
    Result { parse, p50: times[keys / 2], p95: times[(keys - 1).min(keys * 95 / 100)] }
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn ratio(a: Duration, b: Duration) -> f64 {
    a.as_secs_f64() / b.as_secs_f64().max(1e-9)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut keys = 200usize;
    let mut path = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--keys" {
            i += 1;
            keys = args.get(i).and_then(|v| v.parse().ok()).expect("--keys needs a number");
        } else {
            path = Some(args[i].clone());
        }
        i += 1;
    }
    let Some(file) = path else {
        eprintln!("usage: bench-edit [--keys N] <file.dj>");
        std::process::exit(1);
    };
    let keys = keys.max(1);
    let source = std::fs::read(&file).expect("read the file");

    let lang = runtime::Language::new(|_call, source| {
        let doc = twig_djot::parse(source);
        Ok(table::encode(&doc, table::Options { pretty: false, positions: true }))
    });
    let description = runtime::Description {
        name: "djot-bench-twin".into(),
        samples: vec![runtime::Sample::plain(b"# T\n\nA *b* c.\n")],
        ..Default::default()
    };
    let mut diag = String::new();
    let twin = match runtime::register(lang, description, &mut diag) {
        Ok(f) => f,
        Err(_) => {
            eprintln!("the twin was refused: {diag}");
            std::process::exit(1);
        }
    };

    println!("file      : {file}\nsource    : {} bytes\nkeystrokes: {keys}\n", source.len());
    println!("{:<10} {:>12} {:>12} {:>12}", "row", "parse", "key p50", "key p95");
    let compiled = measure(common::djot(), &source, keys);
    println!("{:<10} {:>10.3}ms {:>10.3}ms {:>10.3}ms", "compiled", ms(compiled.parse), ms(compiled.p50), ms(compiled.p95));
    let r = measure(twin, &source, keys);
    println!("{:<10} {:>10.3}ms {:>10.3}ms {:>10.3}ms", "runtime", ms(r.parse), ms(r.p50), ms(r.p95));
    println!(
        "{:<10} {:>11.2}x {:>11.2}x {:>11.2}x",
        "ratio",
        ratio(r.parse, compiled.parse),
        ratio(r.p50, compiled.p50),
        ratio(r.p95, compiled.p95)
    );

    let mut best = [Duration::MAX; 3];
    let mut table_len = usize::MAX;
    for _ in 0..5 {
        let t0 = Instant::now();
        let doc = twig_djot::parse(&source);
        let t1 = Instant::now();
        let text = table::encode(&doc, table::Options { pretty: false, positions: true });
        let t2 = Instant::now();
        drop(doc);
        let back = table::decode(&source, &text).expect("the table reads back");
        let t3 = Instant::now();
        drop(back);
        best[0] = best[0].min(t1 - t0);
        best[1] = best[1].min(t2 - t1);
        best[2] = best[2].min(t3 - t2);
        table_len = table_len.min(text.len());
    }
    println!(
        "\nruntime row, by part: language parse {:.3}ms, table encode {:.3}ms, table decode {:.3}ms; table {} bytes ({:.1}x the source)",
        ms(best[0]),
        ms(best[1]),
        ms(best[2]),
        table_len,
        table_len as f64 / source.len().max(1) as f64
    );
}
