//! The CLI's stdout honours the descriptor it is given: opened for appending
//! (`twig … >> out`), it writes after what the file already held rather than
//! over its start.

use std::fs::{self, OpenOptions};
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("stdout-append-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn convert_appending(input: &PathBuf, out: &PathBuf) {
    let file = OpenOptions::new().append(true).open(out).unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_twig"))
        .arg("convert")
        .arg(input)
        .stdout(Stdio::from(file))
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn appended_stdout_keeps_what_the_file_held() {
    let input = scratch("a.dj");
    let out = scratch("out");
    fs::write(&input, "Hello *world*\n").unwrap();
    fs::write(&out, "old\n").unwrap();

    convert_appending(&input, &out);
    convert_appending(&input, &out);

    let para = "<p>Hello <strong>world</strong></p>\n";
    assert_eq!(fs::read_to_string(&out).unwrap(), format!("old\n{para}{para}"));
}
