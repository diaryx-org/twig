#!/usr/bin/env bash
#
# The Rust binding half of `zig build check`: what .github/workflows/ci.yml's
# `rust binding` job runs, on a dev box.
#
#   scripts/rust-check.sh
#
# `TWIG_SYS_FORCE_SOURCE=1` is not optional here. Without it, twig-sys's
# build.rs prefers a prebuilt `libtwig.a` from a payload crate's lib/ when one
# is lying around from an earlier `build-payload-lib.sh` run — so a local
# `cargo test` can link an archive built from source that is now several commits
# old and pass against code that no longer exists. Forcing the source build is
# what makes this check a check of the working tree. (CI has no stale archive to
# find, which is why the workflow does not need the variable.)
#
# Skips with a note rather than failing when there is no cargo: `check` is a
# pre-release gate a Zig-only contributor should still be able to run, and a
# missing toolchain is not a red build. CI always has one.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v cargo >/dev/null 2>&1; then
    echo "rust-check: no cargo on PATH — SKIPPING the Rust binding suite"
    echo '            (install Rust, or run `nix develop`, to have it covered)' 
    exit 0
fi

cd "$root/bindings/rust"
export TWIG_SYS_FORCE_SOURCE=1
echo "rust-check: cargo build --workspace --all-targets"
cargo build --workspace --all-targets
echo "rust-check: cargo test --workspace"
cargo test --workspace
