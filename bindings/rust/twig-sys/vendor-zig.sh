#!/usr/bin/env bash
#
# Sync Twig's Zig source into ./zig so that `cargo publish` produces a
# self-contained crate. `build.rs` locates the Zig tree by walking up from the
# crate to the repo root during in-repo development; once the crate is published
# and unpacked standalone on a consumer's machine there is no such ancestor, so
# it falls back to this vendored ./zig copy (see `zig_source_root` in build.rs).
#
# This copy is intentionally NOT committed (it is .gitignore'd) — it would only
# drift from the real source. The release workflow runs this immediately before
# `cargo publish --allow-dirty`, so every published crate carries a fresh copy.
#
# Only what `zig build install-c-lib` needs is vendored: the build scripts, the
# whole `src/` tree, and the hand-written C header. Every language's
# `testdata/` is dropped — those are conformance corpora (CommonMark, docutils,
# the AsciiDoc TCK, djot.js) `@embedFile`'d solely from `test {}` blocks, which
# the C-library build never compiles. Together they are ~900 KB of the crate,
# so this is most of the published tarball, not a rounding error.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
dest="$here/zig"

if [ ! -f "$root/build.zig" ] || [ ! -f "$root/src/c_abi.zig" ]; then
    echo "vendor-zig: $root does not look like the Twig Zig root" >&2
    exit 1
fi

rm -rf "$dest"
mkdir -p "$dest/bindings/c/include"
cp "$root/build.zig" "$root/build.zig.zon" "$dest/"
cp -R "$root/src" "$dest/src"
rm -rf "$dest"/src/languages/*/testdata
cp "$root/bindings/c/include/twig.h" "$dest/bindings/c/include/twig.h"

echo "vendor-zig: synced Zig source into $dest"
