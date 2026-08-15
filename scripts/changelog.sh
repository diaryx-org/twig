#!/usr/bin/env bash
# Regenerate the git-cliff-owned region inside CHANGELOG.md's `## Unreleased`
# section from the commits since the last `v*` tag.
#
#   scripts/changelog.sh            print the region that would be written
#   scripts/changelog.sh --write    splice it into CHANGELOG.md
#   scripts/changelog.sh --check    exit 1 if CHANGELOG.md is out of date
#
# Only the bytes between the BEGIN and END markers are touched. Curated prose —
# including the **Behavioural changes** section, which no commit subject can
# tell you about — belongs BELOW the END marker, where regeneration cannot
# reach it. Everything above `## Unreleased` and every released section below
# is likewise left byte-for-byte alone.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
changelog="$repo_root/CHANGELOG.md"
config="$repo_root/cliff.toml"

BEGIN_MARKER='<!-- git-cliff:begin — generated; edits here are overwritten -->'
END_MARKER='<!-- git-cliff:end -->'

mode="print"
case "${1:-}" in
  "") ;;
  --write) mode="write" ;;
  --check) mode="check" ;;
  -h | --help)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "error: unknown argument '$1' (expected --write, --check, or nothing)" >&2
    exit 2
    ;;
esac

if ! command -v git-cliff >/dev/null 2>&1; then
  echo "error: git-cliff not found on PATH" >&2
  echo "hint: nix profile install nixpkgs#git-cliff, or cargo install git-cliff" >&2
  exit 127
fi

for marker in "$BEGIN_MARKER" "$END_MARKER"; do
  if ! grep -qF -- "$marker" "$changelog"; then
    echo "error: marker not found in CHANGELOG.md:" >&2
    echo "  $marker" >&2
    exit 1
  fi
done

# `|| true` because git-cliff exits non-zero when there is nothing unreleased,
# which is a normal state right after a tag rather than a failure.
generated="$(git-cliff --config "$config" --unreleased --strip all 2>/dev/null || true)"
generated="$(printf '%s\n' "$generated" | sed -e 's/[[:space:]]*$//' -e '/./,$!d')"

if [ -z "$generated" ]; then
  generated="_No commits since the last tag._"
fi

region="$(
  printf '%s\n\n' "$BEGIN_MARKER"
  printf '%s\n\n' "$generated"
  printf '%s\n' "$END_MARKER"
)"

if [ "$mode" = "print" ]; then
  printf '%s\n' "$region"
  exit 0
fi

# Splice: everything before BEGIN, the fresh region, everything after END.
spliced="$(
  BEGIN_MARKER="$BEGIN_MARKER" END_MARKER="$END_MARKER" REGION="$region" \
    awk '
      $0 == ENVIRON["BEGIN_MARKER"] { print ENVIRON["REGION"]; skip = 1; next }
      $0 == ENVIRON["END_MARKER"]   { skip = 0; next }
      !skip { print }
    ' "$changelog"
)"

if [ "$mode" = "check" ]; then
  if ! printf '%s\n' "$spliced" | diff -u "$changelog" - >/dev/null; then
    echo "error: CHANGELOG.md's generated region is stale" >&2
    printf '%s\n' "$spliced" | diff -u "$changelog" - >&2 || true
    echo "hint: run scripts/changelog.sh --write" >&2
    exit 1
  fi
  echo "CHANGELOG.md generated region is up to date"
  exit 0
fi

printf '%s\n' "$spliced" >"$changelog"
echo "wrote $changelog"
