#!/usr/bin/env bash
#
# Keep the project's version in one place. `build.zig.zon` is the single source
# of truth (it already drives the C ABI's twig_version); this propagates that
# version into the Rust workspace — bindings/rust/Cargo.toml, whose
# [workspace.package] version every crate inherits and whose
# [workspace.dependencies] pin the intra-workspace crates by version, and
# bindings/rust/Cargo.lock, which records the members' own versions.
#
#   scripts/sync-version.sh              # write: copy zon version -> Cargo.{toml,lock}
#   scripts/sync-version.sh --check      # verify they match; exit 1 if not (CI)
#   scripts/sync-version.sh --set X.Y.Z  # move the zon to X.Y.Z, then propagate
#   scripts/sync-version.sh --print      # print the canonical version and stop
#
# `--set` is what `zig build release` bumps with: one program owns which files
# carry a version, so the release tool never has to know. It takes a literal
# version rather than `patch`/`minor`/`major` — the arithmetic lives in the
# release tool, which is also what refuses a version that goes backwards.
#
# Deliberately pure bash + sed/awk so it runs identically on a dev box and a
# bare CI runner — no fig, cargo-edit, or even cargo required.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zon="$root/build.zig.zon"
cargo="$root/bindings/rust/Cargo.toml"
lock="$root/bindings/rust/Cargo.lock"

mode="write"
case "${1:-}" in
    "") ;;
    --check) mode="check" ;;
    --print) mode="print" ;;
    --set)
        mode="set"
        set_to="${2:-}"
        if ! [[ "$set_to" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "sync-version: --set wants an x.y.z version, got '${set_to:-<nothing>}'" >&2
            exit 2
        fi
        ;;
    -h | --help)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "sync-version: unknown argument '$1' (expected --check, --set X.Y.Z, --print, or nothing)" >&2
        exit 2
        ;;
esac

# `--set` moves the source of truth first; everything below then propagates it
# exactly as a plain run would, so the two paths cannot drift apart.
if [ "$mode" = set ]; then
    tmp="$(mktemp)"
    sed 's/^\([[:space:]]*\.version = "\)[^"]*"/\1'"$set_to"'"/' "$zon" > "$tmp"
    mv "$tmp" "$zon"
    echo "sync-version: build.zig.zon -> $set_to"
    mode="write"
fi

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
# either written or diffed, so `--check` and the write path can never disagree
# about what "in sync" means.
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
        echo "              Run scripts/sync-version.sh and commit the result." >&2
        exit 1
    fi
    echo "sync-version: in sync ($version)"
    exit 0
fi

wrote=false
if ! printf '%s\n' "$want_cargo" | diff -q "$cargo" - >/dev/null 2>&1; then
    printf '%s\n' "$want_cargo" > "$cargo"
    echo "sync-version: bindings/rust/Cargo.toml -> $version (package + internal deps)"
    wrote=true
fi
if ! printf '%s\n' "$want_lock" | diff -q "$lock" - >/dev/null 2>&1; then
    printf '%s\n' "$want_lock" > "$lock"
    echo "sync-version: bindings/rust/Cargo.lock -> $version"
    wrote=true
fi
if [ "$wrote" = false ]; then
    echo "sync-version: already in sync ($version)"
fi
