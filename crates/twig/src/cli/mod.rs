//! The command-line interface (port of `src/main.zig` and `src/cli/`).

pub mod actions;
pub mod args;
pub mod format;
pub mod languages;

use std::io::Write;

use args::CliActionOptions;

/// Run the CLI over the process's arguments; returns the exit status.
pub fn main() -> i32 {
    let argv: Vec<String> = std::env::args_os().map(|a| a.to_string_lossy().into_owned()).collect();
    run(argv)
}

/// Run the CLI over `argv` (its first element the binary name).
pub fn run(argv: Vec<String>) -> i32 {
    let stdout = std::io::stdout();
    let mut stdout = std::io::BufWriter::new(stdout.lock());
    let mut stderr = std::io::stderr().lock();

    let mut it = args::Args::new(argv);
    let config = match args::parse_config(&mut it, &mut stderr) {
        Ok(c) => c,
        Err(_) => return 2,
    };

    let result = match &config.options {
        CliActionOptions::Help => {
            actions::run_help(&mut stdout, &config.binary_name);
            Ok(())
        }
        CliActionOptions::Version => {
            actions::run_version(&mut stdout);
            Ok(())
        }
        CliActionOptions::Identify(o) => {
            actions::run_identify(&mut stdout, o);
            Ok(())
        }
        CliActionOptions::Convert(o) => actions::run_convert(&mut stdout, &mut stderr, o),
        CliActionOptions::Edit(o) => actions::run_edit(&mut stdout, &mut stderr, o),
        CliActionOptions::Query(o) => actions::run_query(&mut stdout, &mut stderr, o),
        CliActionOptions::Filter(o) => actions::run_filter(&mut stdout, &mut stderr, o),
        CliActionOptions::Lang(o) => actions::run_lang(&mut stdout, &mut stderr, o),
    };
    match result {
        Ok(()) => {
            if let Err(e) = stdout.flush() {
                let _ = writeln!(stderr, "error: failed to write output: {}", actions::io_error_name(&e));
                return 1;
            }
            0
        }
        Err(_) => {
            // Zig exits without flushing its buffered stdout on a failed action.
            1
        }
    }
}
