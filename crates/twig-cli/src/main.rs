//! The `twig` command-line tool, over the `twig-doc` engine.

mod actions;
mod args;
mod format;
mod languages;
mod options;
#[cfg(test)]
mod test_formats;

use std::io::Write;
use std::process::ExitCode;

use clap::Parser;

use args::Cli;
use options::CliActionOptions;

fn main() -> ExitCode {
    ExitCode::from(run(std::env::args_os()))
}

/// Run the CLI over `argv` (its first element the binary name); returns the
/// exit status: 0 on success, 1 when an action fails, 2 on a usage error.
fn run<I, T>(argv: I) -> u8
where
    I: IntoIterator<Item = T>,
    T: Into<std::ffi::OsString> + Clone,
{
    let mut stderr = std::io::stderr().lock();

    // Every language twig ships, then — before parsing, so `-i`, `--lang`
    // and the extension table reach them — the configured runtime languages.
    format::register_languages();
    languages::init(&mut stderr);

    let cli = match Cli::try_parse_from(argv) {
        Ok(cli) => cli,
        Err(e) => {
            let _ = e.print();
            return e.exit_code() as u8;
        }
    };
    let options = match cli.resolve(&mut stderr) {
        Ok(o) => o,
        Err(_) => return 2,
    };

    let stdout = std::io::stdout();
    let mut stdout = std::io::BufWriter::new(stdout.lock());
    let result = match &options {
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
        Err(_) => 1,
    }
}
