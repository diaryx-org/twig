//! Languages the CLI did not compile in: the `languages` file that names
//! them, the helper runner that speaks to each as a child process, and
//! `twig lang list` and `twig lang check`. Port of `src/cli/languages.zig`;
//! `docs/proposals/runtime-languages.md` is the argument, `crate::wire` the
//! codec.
//!
//! ── The file ───────────────────────────────────────────────────────────────
//! One language per line: its name, a comma-separated list of extensions or
//! `-` for none, then the command and its arguments, separated by
//! whitespace. A `#` that begins a word comments out the rest of the line; a
//! leading `~` in any argument is `$HOME`. There is no quoting.
//!
//! ```text
//! # name   extensions   command…
//! org      org          twig-quickjs ~/.config/twig/org.mjs
//! wiki     wiki,mw      /usr/local/bin/wiki-helper --strict
//! ```
//!
//! Found in this order, the earlier file winning a name: `$TWIG_LANGUAGES`;
//! `.twig/languages` in the working directory and each ancestor;
//! `$XDG_CONFIG_HOME/twig/languages`, which is `~/.config/twig/languages`
//! when the variable is unset.
//!
//! ── When a helper runs ─────────────────────────────────────────────────────
//! Only when `-i`, `-o`, `--lang` or a file's extension names nothing built
//! in: the CLI's resolvers fall through to [`resolve_name`] and
//! [`resolve_extension`] here, which read the file once and spawn only the
//! helper that answers — or, for a name or extension no line gives, which may
//! be one of a language's sets, the helpers in turn until one does. `lang
//! list` and `lang check` spawn on purpose.
//!
//! ── What a helper is registered as ─────────────────────────────────────────
//! Every command the CLI has reads, writes or splices; none authors. So a
//! helper is registered at the tiers it declares less `author`, with its
//! `syntax` and its features' patches set aside, and the load check skips the
//! gestures it would only run for a table nothing here writes with. `lang
//! check` and `lang list`, which say what a language authors, register it
//! whole and run everything.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::ast::table as node_table;
use crate::format::{self, Format, ParseConfig};
use crate::runtime::{self, Description, RegisterError};
use crate::wire;

/// One configured language, as its line states it.
#[derive(Clone, Debug, Default)]
pub struct Configured {
    pub name: String,
    pub extensions: Vec<String>,
    pub command: Vec<String>,
    /// The file it came from, for `lang list` and for a message.
    pub source: String,
    /// Set once the helper has been spawned and registered.
    pub format: Option<Format>,
    /// Why it was refused, when it was, so a second ask does not spawn again.
    pub failure: Option<String>,
}

/// The process-wide state, set by [`init`] before arguments are parsed.
#[derive(Default)]
struct State {
    initialized: bool,
    loaded: bool,
    configured: Vec<Configured>,
    /// Whether a helper is registered at the author tier it declares. Only
    /// `lang check` and `lang list` turn this on.
    author_tier: bool,
    /// What `report` wrote, when a test asked to collect it.
    captured: Option<Vec<u8>>,
}

static STATE: Mutex<State> = Mutex::new(State {
    initialized: false,
    loaded: false,
    configured: Vec::new(),
    author_tier: false,
    captured: None,
});

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

/// Ready the module: called once from `main` before arguments are parsed,
/// which is where names and extensions resolve. The files are read lazily,
/// on the first resolution. Warnings and refusals are written to the
/// process's stderr as they happen (unbuffered), so flush `stderr` before
/// anything here may run.
pub fn init(stderr: &mut dyn Write) {
    let _ = stderr.flush();
    state().initialized = true;
}

impl State {
    fn report(&mut self, message: &str) {
        match &mut self.captured {
            Some(buf) => buf.extend_from_slice(message.as_bytes()),
            None => {
                let mut e = std::io::stderr().lock();
                let _ = e.write_all(message.as_bytes());
                let _ = e.flush();
            }
        }
    }

    fn warn(&mut self, message: &str) {
        self.report(&format!("warning: languages: {message}\n"));
    }

    /// Read every `languages` file in the search order, once. A missing file
    /// is not an error; a malformed line is reported and skipped.
    fn load(&mut self) {
        if self.loaded {
            return;
        }
        self.loaded = true;
        if !self.initialized {
            return;
        }
        if let Some(path) = std::env::var_os("TWIG_LANGUAGES") {
            self.load_file(Path::new(&path));
        }
        if let Ok(cwd) = std::env::current_dir() {
            let mut dir: &Path = &cwd;
            loop {
                self.load_file(&dir.join(".twig").join("languages"));
                match dir.parent() {
                    Some(p) => dir = p,
                    None => break,
                }
            }
        }
        let user: PathBuf = if let Some(h) = std::env::var_os("XDG_CONFIG_HOME") {
            Path::new(&h).join("twig").join("languages")
        } else if let Some(home) = std::env::var_os("HOME") {
            Path::new(&home).join(".config").join("twig").join("languages")
        } else {
            return;
        };
        self.load_file(&user);
    }

    fn load_file(&mut self, path: &Path) {
        let shown = path.to_string_lossy().into_owned();
        match std::fs::read(path) {
            Ok(content) if content.len() > 1 << 20 => self.warn(&format!("could not read {shown}: StreamTooLong")),
            Ok(content) => self.parse_file(&shown, &String::from_utf8_lossy(&content)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => self.warn(&format!("could not read {shown}: {}", io_error_name(&e))),
        }
    }

    /// Add every line of one file, skipping a name an earlier file gave.
    fn parse_file(&mut self, source: &str, content: &str) {
        for (n, raw) in content.split('\n').enumerate() {
            let mut words: Vec<&str> = Vec::new();
            for w in raw.split([' ', '\t', '\r']).filter(|w| !w.is_empty()) {
                if w.starts_with('#') {
                    break;
                }
                words.push(w);
            }
            if words.is_empty() {
                continue;
            }
            if words.len() < 3 {
                self.warn(&format!("{source}:{}: a line is a name, its extensions (or -), and a command", n + 1));
                continue;
            }
            let name = words[0];
            if self.find(name).is_some() {
                continue;
            }
            let extensions = if words[1] == "-" {
                Vec::new()
            } else {
                words[1].split(',').filter(|p| !p.is_empty()).map(String::from).collect()
            };
            self.configured.push(Configured {
                name: name.to_string(),
                extensions,
                command: words[2..].iter().map(|s| s.to_string()).collect(),
                source: source.to_string(),
                format: None,
                failure: None,
            });
        }
    }

    fn find(&self, name: &str) -> Option<usize> {
        self.configured.iter().position(|c| c.name == name)
    }

    /// Spawn and register configured language `i` if it has not been. A
    /// refusal is kept and not retried.
    fn ensure(&mut self, i: usize) -> Option<Format> {
        let c = &self.configured[i];
        if let Some(f) = c.format {
            return Some(f);
        }
        if c.failure.is_some() {
            return None;
        }
        let (name, command) = (c.name.clone(), c.command.clone());
        let mut diag = String::new();
        match spawn_and_register(Some(&name), &command, self.author_tier, &mut diag) {
            Ok(f) => {
                self.configured[i].format = Some(f);
                Some(f)
            }
            Err(_) => {
                self.configured[i].failure = Some(if diag.is_empty() { "refused".to_string() } else { diag });
                None
            }
        }
    }

    fn ensure_logged(&mut self, i: usize) -> Option<Format> {
        let already = self.configured[i].failure.is_some();
        let f = self.ensure(i);
        if f.is_none() && !already {
            let c = &self.configured[i];
            let message = format!("error: language `{}` ({}): {}\n", c.name, c.source, c.failure.as_deref().unwrap_or(""));
            self.report(&message);
        }
        f
    }

    fn resolve_name(&mut self, name: &str) -> Option<Format> {
        self.load();
        if let Some(i) = self.find(name) {
            return self.ensure_logged(i);
        }
        self.sweep(name, runtime::by_name)
    }

    fn resolve_extension(&mut self, ext: &str) -> Option<Format> {
        self.load();
        if let Some(i) = self.configured.iter().position(|c| c.extensions.iter().any(|x| x.eq_ignore_ascii_case(ext))) {
            return self.ensure_logged(i);
        }
        self.sweep(ext, runtime::by_extension)
    }

    /// Load configured languages until `find(key)` answers: those whose name
    /// is a prefix of `key` before a `-` first, then the rest, in file order.
    fn sweep(&mut self, key: &str, find: fn(&str) -> Option<Format>) -> Option<Format> {
        if let Some(f) = find(key) {
            return Some(f);
        }
        for prefixed in [true, false] {
            for i in 0..self.configured.len() {
                let c = &self.configured[i];
                let named = key.len() > c.name.len() && key.starts_with(&c.name) && key.as_bytes()[c.name.len()] == b'-';
                if named != prefixed || c.format.is_some() || c.failure.is_some() {
                    continue;
                }
                if self.ensure_logged(i).is_none() {
                    continue;
                }
                if let Some(f) = find(key) {
                    return Some(f);
                }
            }
        }
        None
    }
}

/// Zig's name for an I/O error, as messages print it.
fn io_error_name(e: &std::io::Error) -> String {
    use std::io::ErrorKind::*;
    match e.kind() {
        NotFound => "FileNotFound".into(),
        PermissionDenied => "AccessDenied".into(),
        IsADirectory => "IsDir".into(),
        NotADirectory => "NotDir".into(),
        BrokenPipe => "BrokenPipe".into(),
        k => format!("{k:?}"),
    }
}

/// Every configured language, the file read if it had not been.
pub fn configured() -> Vec<Configured> {
    let mut s = state();
    s.load();
    s.configured.clone()
}

/// The format a configured language named `name` answers to, spawning and
/// registering its helper on first ask; `None` when no line names it, or
/// when its helper was refused (the refusal is printed the first time).
pub fn resolve_name(name: &str) -> Option<Format> {
    state().resolve_name(name)
}

/// The format of the configured language owning `ext`, spawning as above.
pub fn resolve_extension(ext: &str) -> Option<Format> {
    state().resolve_extension(ext)
}

// ── the helper runner ───────────────────────────────────────────────────────

struct Pipes {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    #[allow(dead_code)]
    child: Child,
}

/// One spawned helper: the process and its pipes. Lives for the process; it
/// is never respawned.
struct Helper {
    pipes: Mutex<Pipes>,
}

impl wire::Transport for Helper {
    fn exchange(&self, request: &[u8], _diag: &mut String) -> Result<Vec<u8>, String> {
        let mut p = self.pipes.lock().unwrap_or_else(|e| e.into_inner());
        let sent = p.stdin.write_all(request).and_then(|_| p.stdin.write_all(b"\n")).and_then(|_| p.stdin.flush());
        if sent.is_err() {
            return Err("WriteFailed".into());
        }
        let mut line = Vec::new();
        match p.stdout.read_until(b'\n', &mut line) {
            Err(_) => Err("ReadFailed".into()),
            Ok(0) => Err("HelperExited".into()),
            Ok(_) => {
                if line.last() == Some(&b'\n') {
                    line.pop();
                }
                Ok(line)
            }
        }
    }
}

/// Why a helper was not registered; the reason is in the `diag`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpawnError {
    Register(RegisterError),
    SpawnFailed,
    NameMismatch,
}

/// Start `command`, ask it to describe itself, hold it to `name` when one is
/// given, and register it — whole when `author_tier`, else without its author
/// tier.
pub fn spawn_and_register(name: Option<&str>, command: &[String], author_tier: bool, diag: &mut String) -> Result<Format, SpawnError> {
    let argv = expand_argv(command, std::env::var("HOME").ok().as_deref());
    let Some((program, args)) = argv.split_first() else {
        diag.push_str("could not start ``: FileNotFound");
        return Err(SpawnError::SpawnFailed);
    };
    let mut child = match Command::new(program).args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn() {
        Ok(c) => c,
        Err(e) => {
            diag.push_str(&format!("could not start `{program}`: {}", io_error_name(&e)));
            return Err(SpawnError::SpawnFailed);
        }
    };
    let stdin = child.stdin.take().expect("piped stdin");
    let stdout = BufReader::new(child.stdout.take().expect("piped stdout"));
    let helper: Arc<dyn wire::Transport> = Arc::new(Helper { pipes: Mutex::new(Pipes { stdin, stdout, child }) });

    let description = wire::describe(&*helper, diag).map_err(|_| SpawnError::Register(RegisterError::InvalidLanguage))?;
    if let Some(want) = name {
        if description.name != want {
            diag.push_str(&format!("the helper describes itself as `{}`, but its line calls it `{want}`", description.name));
            return Err(SpawnError::NameMismatch);
        }
    }
    let registered = if author_tier { description } else { without_author_tier(description) };
    runtime::register(wire::language(helper), registered, diag).map_err(SpawnError::Register)
}

/// `d` as a language that reads and writes: no `author`, no `syntax`, and no
/// feature patching one.
fn without_author_tier(d: Description) -> Description {
    if !d.author {
        return d;
    }
    let mut out = d;
    out.author = false;
    out.syntax = None;
    for f in &mut out.features {
        f.syntax = None;
    }
    out
}

/// `command` with a leading `~` in any argument expanded to `$HOME`.
fn expand_argv(command: &[String], home: Option<&str>) -> Vec<String> {
    command
        .iter()
        .map(|arg| match (arg.strip_prefix('~'), home) {
            (Some(rest), Some(h)) => format!("{h}{rest}"),
            _ => arg.clone(),
        })
        .collect()
}

// ── `twig lang` ─────────────────────────────────────────────────────────────

fn caps_word(fmt: Format) -> &'static str {
    let writes = match fmt {
        Format::Runtime(c) => runtime::row(c).is_some_and(|r| r.write),
        _ => true,
    };
    let authors = format::syntax_for(fmt).authorable();
    match (writes, authors) {
        (true, true) => "read write author",
        (true, false) => "read write",
        (false, true) => "read author",
        (false, false) => "read",
    }
}

fn write_extensions(w: &mut dyn Write, exts: &[String]) -> std::io::Result<()> {
    for x in exts {
        write!(w, " .{x}")?;
    }
    Ok(())
}

/// `fmt`'s features on a line of their own, the ones its row has on marked
/// and each requirement named; nothing for a row with none.
fn write_features(w: &mut dyn Write, fmt: Format, indent: &str) -> std::io::Result<()> {
    let features = format::features(fmt);
    if features.is_empty() {
        return Ok(());
    }
    let declared = runtime::declared_features(fmt);
    write!(w, "{indent}features:")?;
    for (i, f) in features.iter().enumerate() {
        write!(w, "{} {}", if i == 0 { "" } else { "," }, f.name)?;
        if declared.get(i).is_some_and(|d| d.default) {
            w.write_all(b" (on)")?;
        }
        if !f.requires.is_empty() {
            w.write_all(b" (with")?;
            for r in &f.requires {
                write!(w, " {r}")?;
            }
            w.write_all(b")")?;
        }
    }
    w.write_all(b"\n")
}

const FEATURE_INDENT: &str = "               ";

/// `twig lang list`: every compiled format and every configured language,
/// with what each can do. A configured language is spawned to be asked.
pub fn list(out: &mut dyn Write) -> std::io::Result<()> {
    let mut s = state();
    s.author_tier = true;
    out.write_all(b"compiled:\n")?;
    for f in Format::COMPILED {
        write!(out, "  {:<12} {:<18}", f.name(), caps_word(f))?;
        let exts: Vec<String> = f.extensions().iter().map(|e| e.to_string()).collect();
        write_extensions(out, &exts)?;
        if let Some(lang) = f.dialect_of() {
            write!(out, "  (a {} dialect)", lang.name())?;
        }
        out.write_all(b"\n")?;
        if f.dialect_of().is_none() {
            write_features(out, f, FEATURE_INDENT)?;
        }
    }
    s.load();
    if s.configured.is_empty() {
        return out.write_all(b"configured: none (no languages file found)\n");
    }
    out.write_all(b"configured:\n")?;
    for i in 0..s.configured.len() {
        match s.ensure(i) {
            Some(f) => {
                let c = &s.configured[i];
                write!(out, "  {:<12} {:<18}", c.name, caps_word(f))?;
                let exts = match f {
                    Format::Runtime(code) => runtime::row(code).map(|r| r.extensions).unwrap_or_default(),
                    _ => Vec::new(),
                };
                write_extensions(out, &exts)?;
                writeln!(out, "  ({})", c.source)?;
                write_features(out, f, FEATURE_INDENT)?;
                for row in runtime::entries() {
                    if row.dialect_of != Some(f) {
                        continue;
                    }
                    write!(out, "  {:<12} {:<18}", row.name, caps_word(row.format))?;
                    write_extensions(out, &row.extensions)?;
                    writeln!(out, "  (a {} set)", c.name)?;
                }
            }
            None => {
                let c = &s.configured[i];
                writeln!(out, "  {:<12} refused: {}  ({})", c.name, c.failure.as_deref().unwrap_or(""), c.source)?;
            }
        }
    }
    Ok(())
}

/// Why `lang check` failed.
#[derive(Debug)]
pub enum CheckError {
    /// A refusal or a difference, already reported.
    CheckFailed,
    /// Writing the report failed.
    Write(std::io::Error),
}

impl From<std::io::Error> for CheckError {
    fn from(e: std::io::Error) -> CheckError {
        CheckError::Write(e)
    }
}

/// `twig lang check`: load a language — which is the load check over its
/// samples — and, given a compiled format to hold it to, parse each sample
/// and each file with both and compare the node tables row for row. Reports
/// the first difference in each and fails if there was one.
pub fn check(
    out: &mut dyn Write,
    err: &mut dyn Write,
    name: Option<&str>,
    command: &[String],
    against: Option<Format>,
    files: &[String],
) -> Result<(), CheckError> {
    let fmt = {
        let mut s = state();
        s.author_tier = true;
        match name {
            Some(n) => {
                if let Some(f) = format::parse_format_name(n) {
                    if !runtime::is_registered(f) {
                        writeln!(err, "error: `{n}` is compiled in; lang check checks a runtime language")?;
                        return Err(CheckError::CheckFailed);
                    }
                    f
                } else {
                    s.load();
                    let Some(i) = s.find(n) else {
                        writeln!(err, "error: no language named `{n}` is configured")?;
                        return Err(CheckError::CheckFailed);
                    };
                    match s.ensure(i) {
                        Some(f) => f,
                        None => {
                            writeln!(out, "{n}: refused: {}", s.configured[i].failure.as_deref().unwrap_or(""))?;
                            return Err(CheckError::CheckFailed);
                        }
                    }
                }
            }
            None => {
                let mut diag = String::new();
                match spawn_and_register(None, command, true, &mut diag) {
                    Ok(f) => f,
                    Err(_) => {
                        writeln!(out, "{}: refused: {diag}", command.first().map(String::as_str).unwrap_or(""))?;
                        return Err(CheckError::CheckFailed);
                    }
                }
            }
        }
    };
    let Format::Runtime(code) = fmt else { return Err(CheckError::CheckFailed) };
    let row = runtime::row(code).expect("a registered row");
    write!(out, "{}: registered ({}); every sample parsed", fmt.name(), caps_word(fmt))?;
    if row.write {
        out.write_all(b", printed and reparsed to the same tree")?;
    }
    if format::syntax_for(fmt).authorable() {
        out.write_all(b"; every gesture kept its promise")?;
    }
    if row.write {
        out.write_all(b"; fidelity measured")?;
    }
    out.write_all(b"\n")?;
    let features = runtime::features_of(fmt);
    write_features(out, fmt, "  ")?;
    for s in runtime::entries() {
        if s.dialect_of != Some(fmt) {
            continue;
        }
        write!(out, "  set {}:", s.name)?;
        for (i, f) in features.iter().enumerate() {
            if s.mask & (1u32 << i) != 0 {
                write!(out, " {}", f.name)?;
            }
        }
        out.write_all(b"\n")?;
    }

    let Some(sibling) = against else { return Ok(()) };
    let mut inputs: Vec<(String, Vec<u8>)> =
        row.samples.iter().enumerate().map(|(i, s)| (format!("sample {i}"), s.clone())).collect();
    for f in files {
        match std::fs::read(f) {
            Ok(content) => inputs.push((f.clone(), content)),
            Err(e) => {
                writeln!(err, "error: could not read {f}: {}", io_error_name(&e))?;
                return Err(CheckError::CheckFailed);
            }
        }
    }
    let mut failed = false;
    let cfg = ParseConfig::default();
    for (label, content) in &inputs {
        let mine = match format::parse(fmt, &cfg, content) {
            Ok(d) => d,
            Err(e) => {
                writeln!(out, "{label}: `{}` does not parse it: {}", fmt.name(), failure_of(&e.name()))?;
                failed = true;
                continue;
            }
        };
        let theirs = match format::parse(sibling, &cfg, content) {
            Ok(d) => d,
            Err(e) => {
                writeln!(out, "{label}: `{}` does not parse it: {}", sibling.name(), e.name())?;
                failed = true;
                continue;
            }
        };
        match first_difference(&mine.doc, &theirs.doc) {
            Some(d) => {
                write!(
                    out,
                    "{label}: differs from `{}` at row {}:\n  {}: {}\n  {}: {}\n",
                    sibling.name(),
                    d.row,
                    fmt.name(),
                    d.mine,
                    sibling.name(),
                    d.theirs
                )?;
                failed = true;
            }
            None => writeln!(out, "{label}: same table as `{}` ({} rows)", sibling.name(), mine.doc.ast.nodes.len())?,
        }
    }
    if failed {
        return Err(CheckError::CheckFailed);
    }
    Ok(())
}

/// Why a runtime call failed, as the registry recorded it; `err` (the error's
/// name) when it recorded nothing.
pub fn failure_of(err: &str) -> String {
    let why = runtime::last_failure();
    if why.is_empty() { err.to_string() } else { why }
}

struct Difference {
    row: usize,
    mine: String,
    theirs: String,
}

/// The first row at which two documents' tables differ, each row as its JSON
/// line; `None` when every row and the label table agree.
fn first_difference(mine: &crate::document::Document, theirs: &crate::document::Document) -> Option<Difference> {
    let x = node_table::encode(mine, node_table::Options::default());
    let y = node_table::encode(theirs, node_table::Options::default());
    let x = String::from_utf8_lossy(&x);
    let y = String::from_utf8_lossy(&y);
    let mut xs = x.split('\n');
    let mut ys = y.split('\n');
    // The first two lines open the table; rows follow one a line.
    let mut line = 0usize;
    loop {
        let (l, r) = (xs.next(), ys.next());
        if l.is_none() && r.is_none() {
            return None;
        }
        let trim = |s: &str| s.trim_matches([' ', ',']).to_string();
        let lt = trim(l.unwrap_or("(no row)"));
        let rt = trim(r.unwrap_or("(no row)"));
        if lt != rt {
            return Some(Difference { row: line.saturating_sub(2), mine: lt, theirs: rt });
        }
        line += 1;
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn test_state() -> State {
        State { initialized: true, loaded: true, captured: Some(Vec::new()), ..Default::default() }
    }

    #[test]
    fn one_line_a_language_an_earlier_file_wins_a_name() {
        let mut s = test_state();
        s.parse_file(
            "first",
            "# name   exts      command\norg      org       twig-quickjs ~/org.mjs   # the Org twin\nwiki     wiki,mw   wiki-helper --strict\n\nbroken   x",
        );
        s.parse_file("second", "wiki     -         other\nbare     -         bare-helper");
        let langs = &s.configured;
        let captured = String::from_utf8(s.captured.clone().unwrap()).unwrap();
        assert!(captured.contains("first:5: a line is a name"), "{captured}");
        assert_eq!(langs.len(), 3);
        assert_eq!(langs[0].name, "org");
        assert_eq!(langs[0].command.len(), 2);
        assert_eq!(langs[0].command[1], "~/org.mjs");
        assert_eq!(langs[1].extensions[1], "mw");
        assert_eq!(langs[1].source, "first");
        assert_eq!(langs[1].command.len(), 2);
        assert_eq!(langs[2].extensions.len(), 0);
    }

    #[test]
    fn a_leading_tilde_in_any_argument_is_home() {
        let argv = expand_argv(&["helper".into(), "~/x.mjs".into(), "not~here".into()], Some("/home/adam"));
        assert_eq!(argv[1], "/home/adam/x.mjs");
        assert_eq!(argv[2], "not~here");
    }

    /// A helper in `sh`: it reads one language whose every document is the
    /// one-character `x`.
    fn sh_helper(name: &str, caps: &str, syntax: &str) -> String {
        format!(
            r#"while IFS= read -r line; do
  case "$line" in
    *describe*) printf '%s\n' '{{"ok":true,"description":{{"name":"{name}","extensions":["{name}"],"caps":{caps}{syntax},"samples":["x"]}}}}' ;;
    *parse*) printf '%s\n' '{{"ok":true,"table":{{"nodes":[{{"kind":"doc","span":[0,1]}},{{"kind":"para","parent":0,"span":[0,1]}},{{"kind":"str","parent":1,"span":[0,1],"text":"x"}}]}}}}' ;;
    *) printf '%s\n' '{{"ok":false,"message":"{name} only reads"}}' ;;
  esac
done"#
        )
    }

    fn sh(script: String) -> Vec<String> {
        vec!["sh".into(), "-c".into(), script]
    }

    #[test]
    #[cfg(unix)]
    fn a_helper_process_is_spawned_described_registered_and_asked() {
        let mut s = test_state();
        s.configured.push(Configured {
            name: "shx".into(),
            extensions: vec!["shx".into()],
            command: sh(sh_helper("shx", r#"{"read":true}"#, "")),
            source: "test".into(),
            ..Default::default()
        });
        let fmt = s.resolve_extension("shx").unwrap_or_else(|| panic!("refused: {:?}", s.configured[0].failure));
        assert_eq!(s.resolve_name("shx"), Some(fmt));
        assert_eq!(fmt.name(), "shx");
        let doc = format::parse(fmt, &ParseConfig::default(), b"x").unwrap();
        assert_eq!(format::render_html(&doc).unwrap(), b"<p>x</p>\n");

        // A line whose helper calls itself something else is refused, once.
        s.configured.push(Configured {
            name: "notshx".into(),
            command: sh(sh_helper("shx", r#"{"read":true}"#, "")),
            source: "test".into(),
            ..Default::default()
        });
        assert_eq!(s.ensure(1), None);
        assert!(s.configured[1].failure.as_ref().unwrap().contains("describes itself as `shx`"));

        // A helper that exits without answering, and one that cannot start.
        let mut diag = String::new();
        assert_eq!(
            spawn_and_register(None, &sh("exit 0".into()), false, &mut diag),
            Err(SpawnError::Register(RegisterError::InvalidLanguage))
        );
        assert!(diag.contains("did not answer"), "{diag}");
        diag.clear();
        assert_eq!(spawn_and_register(None, &["/nonexistent/twig-helper".into()], false, &mut diag), Err(SpawnError::SpawnFailed));
        assert_eq!(diag, "could not start `/nonexistent/twig-helper`: FileNotFound");
    }

    #[test]
    #[cfg(unix)]
    fn a_helper_is_registered_without_its_author_tier_unless_lang_check_or_list_asks() {
        let script = sh(sh_helper("shy", r#"{"read":true,"author":true}"#, r##","syntax":{"heading_markr":"#"}"##));
        // With the full check, the table is decoded and refused.
        let mut diag = String::new();
        assert!(spawn_and_register(None, &script, true, &mut diag).is_err());
        assert!(diag.contains("heading_markr"), "{diag}");

        // Without it, the language reads, and authors nothing.
        diag.clear();
        let fmt = spawn_and_register(None, &script, false, &mut diag).unwrap_or_else(|e| panic!("{e:?}: {diag}"));
        assert!(!format::syntax_for(fmt).authorable());
        let doc = format::parse(fmt, &ParseConfig::default(), b"x").unwrap();
        assert_eq!(doc.doc.ast.nodes.len(), 3);
    }

    #[test]
    #[cfg(unix)]
    fn lang_check_reports_a_helper_and_compares_it_to_a_sibling() {
        let script = sh(sh_helper("shz", r#"{"read":true}"#, ""));
        let mut out = Vec::new();
        let mut err = Vec::new();
        let result = check(&mut out, &mut err, None, &script, Some(Format::Djot), &[]);
        let out = String::from_utf8(out).unwrap();
        // As the Zig CLI prints it: djot records the doc's content span, and
        // the helper's table does not.
        assert!(matches!(result, Err(CheckError::CheckFailed)), "{out}");
        assert_eq!(
            out,
            "shz: registered (read); every sample parsed\nsample 0: differs from `djot` at row 0:\n  shz: {\"kind\":\"doc\",\"parent\":null,\"span\":[0,1]}\n  djot: {\"kind\":\"doc\",\"parent\":null,\"span\":[0,1],\"content_span\":[0,1]}\n"
        );
    }
}
