use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    // docs.rs builds documentation in a sandbox with no Zig toolchain. `cargo
    // doc` type-checks the crate but never links the static library, so skip the
    // native build entirely there — the bindings still document cleanly.
    if env::var_os("DOCS_RS").is_some() {
        return;
    }

    println!("cargo:rerun-if-env-changed=TWIG_SYS_FORCE_SOURCE");

    let cargo_target = env::var("TARGET").expect("Cargo should set TARGET");
    let cargo_host = env::var("HOST").expect("Cargo should set HOST");

    // Preferred path: link the prebuilt archive shipped by the `twig-sys-<target>`
    // payload crate for this target — no Zig toolchain required. Cargo activates
    // the matching payload as a target-gated dependency (see Cargo.toml); its
    // build script hands us the archive directory via `links` metadata.
    //
    // Set TWIG_SYS_FORCE_SOURCE=1 to skip this and always compile from source.
    // (twig has no native-affecting cargo features, so the prebuilt archive
    // always matches the requested build; fig gates this additionally on its
    // per-language features.)
    if env::var_os("TWIG_SYS_FORCE_SOURCE").is_none() {
        if let Some(libdir) = prebuilt_libdir(&cargo_target) {
            println!("cargo:rustc-link-search=native={}", libdir.display());
            println!("cargo:rustc-link-lib=static=twig");
            println!("cargo:rerun-if-changed={}", libdir.display());
            return;
        }
    }

    build_from_source(&cargo_target, &cargo_host);
}

/// Directory holding the prebuilt `libtwig.a`/`twig.lib` for `target`, if a
/// payload crate is providing one. The active `twig-sys-<target>` payload
/// crate publishes its `lib/` directory as `DEP_TWIG_PREBUILT_<KEY>_LIBDIR`
/// (via its `links` key); we resolve `<KEY>` from the target triple.
fn prebuilt_libdir(target: &str) -> Option<PathBuf> {
    let key = payload_env_key(target)?;
    let dir = PathBuf::from(env::var_os(format!("DEP_TWIG_PREBUILT_{key}_LIBDIR"))?);
    // Defensive: only take the prebuilt path if the archive is really present,
    // so a payload crate with an empty `lib/` degrades to the source build
    // rather than linking nothing.
    let has_archive = ["libtwig.a", "twig.lib"]
        .iter()
        .any(|name| dir.join(name).is_file());
    has_archive.then_some(dir)
}

/// Map a Rust target triple to its payload crate's env-var key, or `None` for
/// targets with no prebuilt library (which use the source build). Mirror of
/// `../prebuilt-targets.tsv` and the cfg-gated deps in `Cargo.toml`.
fn payload_env_key(target: &str) -> Option<&'static str> {
    Some(match target {
        "aarch64-apple-darwin" => "MACOS_ARM64",
        "x86_64-unknown-linux-gnu" => "LINUX_X64_GNU",
        "aarch64-unknown-linux-gnu" => "LINUX_ARM64_GNU",
        "x86_64-pc-windows-msvc" => "WINDOWS_X64_MSVC",
        "wasm32-unknown-unknown" => "WASM32",
        _ => return None,
    })
}

/// Compile `libtwig.a` from the vendored/repo Zig source with the `zig`
/// toolchain. The fallback for targets without a prebuilt payload crate (or
/// when `TWIG_SYS_FORCE_SOURCE` is set).
fn build_from_source(cargo_target: &str, cargo_host: &str) {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let source_root = zig_source_root(&manifest_dir);
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let prefix = out_dir.join("zig-prefix");

    let mut command = Command::new("zig");
    command
        .arg("build")
        .arg("install-c-lib")
        .arg("-Doptimize=ReleaseFast")
        // Pin the CPU to the portable baseline. Without this, `zig build` for a
        // host target (no `-Dtarget`) compiles for the *build machine's* native
        // CPU, baking in whatever vector ISA it happens to have (AVX2/AVX-512:
        // `ymm`/`zmm`/`kmov`). The resulting `libtwig.a` gets cached (e.g. by
        // Swatinem/rust-cache) and later restored onto a different, older CPU —
        // GitHub's x86_64 Linux runner fleet is heterogeneous — where the first
        // wide-vector instruction faults with SIGILL. Baseline codegen runs
        // everywhere; the parser is not vector-bound, so the cost is negligible.
        .arg("-Dcpu=baseline");

    if let Some(zig_target) = zig_target_for_cargo_target(cargo_target, cargo_host) {
        command.arg(format!("-Dtarget={zig_target}"));
    }

    let status = command
        .arg("--prefix")
        .arg(&prefix)
        .current_dir(&source_root)
        .status()
        .unwrap_or_else(|e| {
            panic!(
                "twig-sys: target `{cargo_target}` has no prebuilt library, and running \
                 `zig` to build from source failed: {e}.\n\
                 Prebuilt targets need no Zig: aarch64-apple-darwin, x86_64-unknown-linux-gnu, \
                 aarch64-unknown-linux-gnu, x86_64-pc-windows-msvc, wasm32-unknown-unknown.\n\
                 For any other target install Zig 0.16+ (https://ziglang.org/download/)."
            )
        });

    if !status.success() {
        panic!("`zig build` failed with status {status}");
    }

    // Apple's `ld` rejects static-archive members that aren't 8-byte aligned,
    // and Zig 0.16's built-in archiver can emit an unaligned `libtwig_zcu.o`
    // (whether it trips depends on the object's size, so it surfaces as the
    // library grows). Repack the archive with the system `ar`, which writes
    // aligned members, on Apple targets; other linkers accept Zig's archive
    // as-is.
    let lib_dir = prefix.join("lib");
    let link_dir = if cargo_target.contains("apple") {
        repack_archive_for_apple_ld(&lib_dir.join("libtwig.a"), &out_dir)
    } else {
        lib_dir
    };

    println!("cargo:rustc-link-search=native={}", link_dir.display());
    println!("cargo:rustc-link-lib=static=twig");

    println!("cargo:rerun-if-env-changed=TWIG_ZIG_ROOT");
    println!(
        "cargo:rerun-if-changed={}",
        source_root.join("build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        source_root.join("src").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        source_root.join("bindings/c/include/twig.h").display()
    );
}

/// Rebuild `libtwig.a` with the system `ar` so every member is 8-byte aligned
/// (see the call site). Returns a directory containing the repacked
/// `libtwig.a` for `rustc-link-search`. Falls back to the original archive's
/// directory if any step fails, so a missing `ar` degrades to the (possibly
/// failing) direct link rather than a confusing build-script panic.
fn repack_archive_for_apple_ld(orig: &Path, out_dir: &Path) -> PathBuf {
    let fallback = || orig.parent().unwrap().to_path_buf();

    let work = out_dir.join("repack");
    let _ = fs::remove_dir_all(&work);
    if fs::create_dir_all(&work).is_err() {
        return fallback();
    }

    // Extract, then repack. Zig writes members with no permission bits, so the
    // extracted objects must be made readable before `ar` can re-add them.
    if !run_ok(Command::new("ar").arg("x").arg(orig).current_dir(&work)) {
        return fallback();
    }

    let mut objects = Vec::new();
    let Ok(entries) = fs::read_dir(&work) else {
        return fallback();
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "o") {
            make_readable(&path);
            objects.push(path);
        }
    }
    if objects.is_empty() {
        return fallback();
    }

    let repacked = work.join("libtwig.a");
    let _ = fs::remove_file(&repacked);
    let mut cmd = Command::new("ar");
    cmd.arg("crs").arg(&repacked).args(&objects);
    if !run_ok(&mut cmd) || !repacked.is_file() {
        return fallback();
    }
    work
}

fn run_ok(cmd: &mut Command) -> bool {
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

#[cfg(unix)]
fn make_readable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(meta) = fs::metadata(path) {
        let mut perms = meta.permissions();
        perms.set_mode(perms.mode() | 0o600);
        let _ = fs::set_permissions(path, perms);
    }
}

#[cfg(not(unix))]
fn make_readable(_path: &Path) {}

fn zig_source_root(manifest_dir: &Path) -> PathBuf {
    if let Some(dir) = env::var_os("TWIG_ZIG_ROOT") {
        let dir = PathBuf::from(dir);
        assert!(
            is_twig_zig_root(&dir),
            "TWIG_ZIG_ROOT={} is not a twig Zig source tree (no build.zig + src/c_abi.zig)",
            dir.display()
        );
        return dir;
    }

    for ancestor in manifest_dir.ancestors() {
        if is_twig_zig_root(ancestor) {
            return ancestor.to_path_buf();
        }
    }

    let vendored = manifest_dir.join("zig");
    if is_twig_zig_root(&vendored) {
        return vendored;
    }

    panic!(
        "could not locate twig's Zig source. In a checkout it is found by walking up \
         from {}; in a published crate it is vendored at ./zig.",
        manifest_dir.display()
    );
}

fn is_twig_zig_root(dir: &Path) -> bool {
    dir.join("build.zig").is_file()
        && dir.join("build.zig.zon").is_file()
        && dir.join("src/c_abi.zig").is_file()
}

fn zig_target_for_cargo_target(target: &str, host: &str) -> Option<&'static str> {
    if target == host {
        return None;
    }

    match target {
        "aarch64-apple-darwin" => Some("aarch64-macos"),
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "aarch64-apple-ios" => Some("aarch64-ios"),
        "aarch64-apple-ios-sim" => Some("aarch64-ios-simulator"),
        "x86_64-apple-ios" => Some("x86_64-ios-simulator"),
        "aarch64-pc-windows-msvc" => Some("aarch64-windows-msvc"),
        "x86_64-pc-windows-msvc" => Some("x86_64-windows-msvc"),
        "aarch64-pc-windows-gnu" => Some("aarch64-windows-gnu"),
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "i686-pc-windows-gnu" => Some("x86-windows-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        "aarch64-unknown-linux-musl" => Some("aarch64-linux-musl"),
        "arm-unknown-linux-gnueabi" => Some("arm-linux-gnueabi"),
        "arm-unknown-linux-gnueabihf" => Some("arm-linux-gnueabihf"),
        "arm-unknown-linux-musleabi" => Some("arm-linux-musleabi"),
        "arm-unknown-linux-musleabihf" => Some("arm-linux-musleabihf"),
        "i686-unknown-linux-gnu" => Some("x86-linux-gnu"),
        "i686-unknown-linux-musl" => Some("x86-linux-musl"),
        "powerpc64le-unknown-linux-gnu" => Some("powerpc64le-linux-gnu"),
        "powerpc64le-unknown-linux-musl" => Some("powerpc64le-linux-musl"),
        "riscv64gc-unknown-linux-gnu" => Some("riscv64-linux-gnu"),
        "riscv64gc-unknown-linux-musl" => Some("riscv64-linux-musl"),
        "wasm32-unknown-unknown" => Some("wasm32-freestanding"),
        // Rust's WASI targets are `wasm32-wasip1` (née `wasm32-wasi`) and
        // `wasm32-wasip2`; Zig has no separate preview1/preview2 tag, just
        // `wasi` (preview1). `wasm32-wasip2` maps to the same Zig target:
        // twig's C ABI surface (src/c_abi.zig) does no I/O of its own (no
        // filesystem, no host calls) — only the CLI/bench/conformance code
        // does, and none of that is in libtwig.a — so a preview1-ABI static
        // lib links and runs correctly under Rust's wasip2 sysroot, which
        // supplies the actual environment surface itself. Verified against
        // fig (identical shape) by linking+running `fig/examples/wasm_smoke.rs`
        // for both targets under wasmtime; revisit if twig ever grows real I/O
        // in the C ABI surface.
        "wasm32-wasip1" => Some("wasm32-wasi"),
        "wasm32-wasip2" => Some("wasm32-wasi"),
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "x86_64-unknown-linux-musl" => Some("x86_64-linux-musl"),
        _ => panic!(
            "unsupported Rust target `{target}` for twig's bundled Zig static library; \
             add a Cargo-to-Zig target mapping in bindings/rust/twig/build.rs"
        ),
    }
}
