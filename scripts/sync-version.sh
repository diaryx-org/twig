#!/usr/bin/env bash
#
# Check that the project's version is in one place. `build.zig.zon` is the single
# source of truth (it already drives the C ABI's twig_version); the Rust
# workspace copies it — bindings/rust/Cargo.toml, whose [workspace.package]
# version every crate inherits and whose [workspace.dependencies] pin the
# intra-workspace crates by version, and bindings/rust/Cargo.lock, which records
# the members' own versions.
#
#   scripts/sync-version.sh --check      # verify they match; exit 1 if not (CI)
#   scripts/sync-version.sh --print      # print the canonical version and stop
#
# This used to write as well, and `zig build release` bumped through its `--set`.
# Writing moved to the shared release tooling (diaryx-org/devtools), which reads
# `.config/release.toml` to learn that `bindings/rust/Cargo.toml` mirrors the
# zon. Checking stayed here on purpose: a writer and an independent checker that
# disagree fail loudly, where two writers would quietly produce different bytes.
# The two were verified byte-identical on a 3.2.1 -> 3.3.0 bump before the
# writing half was removed.
#
# Deliberately pure bash + sed/awk so it runs identically on a dev box and a
# bare CI runner — no fig, cargo-edit, or even cargo required.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zon="$root/build.zig.zon"
cargo="$root/bindings/rust/Cargo.toml"
lock="$root/bindings/rust/Cargo.lock"

case "${1:-}" in
    --check) mode="check" ;;
    --print) mode="print" ;;
    -h | --help)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")
        echo "sync-version: --check or --print (writing is \`release bump\`, from diaryx-org/devtools)" >&2
        exit 2
        ;;
    *)
        echo "sync-version: unknown argument '$1' (expected --check or --print)" >&2
        exit 2
        ;;
esac

# Canonical version: the `.version = "x.y.z",` line in build.zig.zon.
version="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' "$zon" | head -1)"
if [ -z "$version" ]; then
    echo "sync-version: could not read .version from $zon" >&2
    exit 1
fi

if [ "$mode" = print ]; then
    echo "$version"
    exit 0
fi

# What each derived file should say, given that version. Built in full and then
# diffed, which is the whole of what `--check` means.
#
# Cargo.toml: the [workspace.package] `version = "…"` (anchored at line start),
# and the version inside each internal `{ path = "…", version = "…" }` entry in
# [workspace.dependencies]. Every intra-workspace crate shares the one project
# version (twig-doc -> twig-sys -> the per-target payload crates all resolve by
# version at publish time), so those move together or the publish breaks.
want_cargo="$(
    sed -e 's/^version = "[^"]*"/version = "'"$version"'"/' \
        -e 's/\(path = "[^"]*", version = "\)[^"]*"/\1'"$version"'"/' \
        "$cargo"
)"

# Cargo.lock: the `version = "…"` inside each `[[package]]` block whose name is
# one of ours. Scoped by the preceding `name = "…"` rather than rewritten
# blanket-wise, so the day an external dependency lands in this lockfile its
# pinned version is left alone. (The header's `version = 4` is unquoted and so
# matches nothing here either way.)
want_lock="$(
    awk -v v="$version" '
        /^name = "/ { pkg = $0; sub(/^name = "/, "", pkg); sub(/"$/, "", pkg) }
        /^version = "/ && pkg ~ /^twig(-|$)/ { print "version = \"" v "\""; next }
        { print }
    ' "$lock"
)"

if [ "$mode" = check ]; then
    drift=false
    if ! printf '%s\n' "$want_cargo" | diff -u "$cargo" - >/dev/null; then
        echo "sync-version: version drift — build.zig.zon is $version but $cargo disagrees:" >&2
        printf '%s\n' "$want_cargo" | diff -u "$cargo" - >&2 || true
        drift=true
    fi
    if ! printf '%s\n' "$want_lock" | diff -u "$lock" - >/dev/null; then
        echo "sync-version: version drift — build.zig.zon is $version but $lock disagrees:" >&2
        printf '%s\n' "$want_lock" | diff -u "$lock" - >&2 || true
        drift=true
    fi
    if [ "$drift" = true ]; then
        echo "              Run \`release bump as-is\` and commit the result." >&2
        exit 1
    fi
    echo "sync-version: in sync ($version)"
    exit 0
fi
