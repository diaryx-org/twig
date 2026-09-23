//! The helper runner: a language served by another process, registered as a
//! [`Format`] this process can parse and write with.
//!
//! A helper is any executable that speaks the helper wire on its stdin and
//! stdout — newline-delimited JSON, one request line to one response line:
//!
//! ```text
//! {"op":"describe"}                                  {"ok":true,"description":{…}}
//! {"op":"parse","dialect":"org","input":"…"}         {"ok":true,"table":{…}}
//! {"op":"print","dialect":"org","table":{…}}         {"ok":true,"output":"…"}
//!                                                     {"ok":false,"message":"…"}
//! ```
//!
//! The library speaks the wire; this module only moves the lines, through
//! `twig_language_register_transport`, so a helper reached from Rust and one
//! reached from the `twig` CLI are held to the same codec. [`spawn`] starts
//! the helper, asks it to describe itself, and registers what it describes —
//! the load check runs, as for any runtime language.
//!
//! A host that lives longer than one command outlives its helpers sometimes.
//! A helper that exits is started again on the next request, and the request
//! is sent to the new one; if that one exits on the same request too, the
//! request fails with a message saying so, and the next request starts a
//! third. The helper's stderr is this process's.

use std::ffi::{c_void, CStr, OsStr, OsString};
use std::io::{BufRead, BufReader, Write};
use std::os::raw::{c_char, c_int};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

use crate::language::{bytes, free_trampoline, give};
use crate::{ffi, Error, Format, RegisterError, RuntimeId};

struct Running {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One helper: its command, and the process currently answering for it.
struct Helper {
    command: Vec<OsString>,
    running: Mutex<Option<Running>>,
}

impl Helper {
    fn start(&self) -> Result<Running, String> {
        let (program, args) = self.command.split_first().ok_or("an empty command")?;
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("could not start `{}`: {e}", program.to_string_lossy()))?;
        let stdin = child.stdin.take().ok_or("the helper has no stdin")?;
        let stdout = BufReader::new(child.stdout.take().ok_or("the helper has no stdout")?);
        Ok(Running {
            child,
            stdin,
            stdout,
        })
    }

    /// One request line to one response line on `running`; `None` when the
    /// process is gone — a write that fails, or a read that finds the end.
    fn trade(running: &mut Running, request: &[u8]) -> Option<Vec<u8>> {
        running.stdin.write_all(request).ok()?;
        running.stdin.write_all(b"\n").ok()?;
        running.stdin.flush().ok()?;
        let mut line = Vec::new();
        match running.stdout.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => {
                if line.last() == Some(&b'\n') {
                    line.pop();
                }
                Some(line)
            }
        }
    }

    fn exchange(&self, request: &[u8]) -> Result<Vec<u8>, String> {
        let mut slot = self
            .running
            .lock()
            .map_err(|_| "the helper's lock is poisoned")?;
        for attempt in 0..2 {
            if slot.is_none() {
                *slot = Some(self.start()?);
            }
            if let Some(line) = Self::trade(slot.as_mut().unwrap(), request) {
                return Ok(line);
            }
            // Gone: forget it, and the next pass starts another.
            *slot = None;
            if attempt == 1 {
                break;
            }
        }
        Err("the helper exited, and exited again when restarted on the same request".to_owned())
    }
}

unsafe extern "C" fn exchange_trampoline(
    user_data: *mut c_void,
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    let helper = unsafe { &*(user_data as *const Helper) };
    let request = unsafe { bytes(request, request_len) };
    let result =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| helper.exchange(request)));
    match result {
        Ok(Ok(line)) => {
            unsafe { give(line, out, out_len) };
            0
        }
        Ok(Err(message)) => {
            unsafe { give(message.into_bytes(), out, out_len) };
            1
        }
        Err(_) => {
            unsafe { give(b"the helper runner panicked".to_vec(), out, out_len) };
            1
        }
    }
}

/// Start the helper `command` (the program, then its arguments), ask it to
/// describe itself, and register what it describes. The helper runs for as
/// long as this process uses it; on refusal it is stopped and nothing is
/// registered.
pub fn spawn<I, S>(command: I) -> Result<Format, RegisterError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let command: Vec<OsString> = command.into_iter().map(|s| s.as_ref().to_owned()).collect();
    let helper = Box::into_raw(Box::new(Helper {
        command,
        running: Mutex::new(None),
    }));
    let transport = ffi::TwigTransport {
        version: ffi::TWIG_TRANSPORT_VERSION,
        user_data: helper as *mut c_void,
        exchange: Some(exchange_trampoline),
        free: Some(free_trampoline),
    };
    let mut code: c_int = 0;
    let mut err = [0 as c_char; 512];
    let status = unsafe {
        ffi::twig_language_register_transport(&transport, &mut code, err.as_mut_ptr(), err.len())
    };
    match Error::from_status(status) {
        Ok(()) => Ok(Format::Runtime(RuntimeId(code))),
        Err(error) => {
            // Refused: nothing kept a pointer to it, and dropping it stops
            // the process.
            drop(unsafe { Box::from_raw(helper) });
            let message = unsafe { CStr::from_ptr(err.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            Err(RegisterError { error, message })
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{Document, Target};

    /// A read-only language in `sh` whose every document is `x`; `once`
    /// answers one request and exits, which is what a crashing helper looks
    /// like to its host.
    fn script(name: &str, once: bool) -> String {
        let answer = format!(
            r#"case "$line" in
  *describe*) printf '%s\n' '{{"ok":true,"description":{{"name":"{name}","caps":{{"read":true}},"samples":["x"]}}}}' ;;
  *parse*) printf '%s\n' '{{"ok":true,"table":{{"nodes":[{{"kind":"doc","span":[0,1]}},{{"kind":"para","parent":0,"span":[0,1]}},{{"kind":"str","parent":1,"span":[0,1],"text":"x"}}]}}}}' ;;
  *) printf '%s\n' '{{"ok":false,"message":"{name} only reads"}}' ;;
esac"#
        );
        if once {
            format!("IFS= read -r line\n{answer}\n")
        } else {
            format!("while IFS= read -r line; do\n{answer}\ndone\n")
        }
    }

    #[test]
    fn a_spawned_helper_is_a_format() {
        let format = spawn(["sh", "-c", &script("rust-shx", false)]).expect("spawn");
        assert_eq!(format.name(), "rust-shx");
        let mut doc = Document::parse_str("x", format).expect("parse");
        assert_eq!(doc.render_html().unwrap(), b"<p>x</p>\n");
        assert_eq!(doc.serialize_to(Target::Markdown).unwrap(), b"x\n");
        assert_eq!(
            doc.serialize_to(Target::from(format)).err(),
            Some(Error::UnsupportedFormat)
        );
    }

    #[test]
    fn a_helper_that_exits_is_started_again() {
        // Every process answers one line: describe, the load check's parse,
        // and this test's parse are each a new one.
        let format = spawn(["sh", "-c", &script("rust-shx-once", true)]).expect("spawn");
        let mut doc = Document::parse_str("x", format).expect("parse after a restart");
        assert_eq!(doc.render_html().unwrap(), b"<p>x</p>\n");
    }

    #[test]
    fn a_helper_that_cannot_answer_is_refused_with_why() {
        let err = spawn(["sh", "-c", "exit 0"]).unwrap_err();
        assert_eq!(err.error, Error::InvalidLanguage);
        assert!(err.message.contains("exited again"), "{}", err.message);
        let err = spawn(["/nonexistent/twig-helper"]).unwrap_err();
        assert!(err.message.contains("could not start"), "{}", err.message);
    }
}
