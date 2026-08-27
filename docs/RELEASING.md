---
part_of: '[Twig](/README.md)'
---
# Twig — cutting a release

One command:

```
release release <version|major|minor|patch|as-is> [--push] [--no-verify]
```

`release` is the shared tooling in [diaryx-org/devtools][devtools], which twig,
prov, leaf, flower, and the historica repos all cut releases with. What makes
twig twig is [`.config/release.toml`](../.config/release.toml) and nothing else:
that the version is decided in `build.zig.zon` rather than a Cargo manifest,
that `bindings/rust/Cargo.toml` mirrors it, that the changelog heads its
sections `## 3.2.1` rather than `## v3.2.1 — date` and begins at 2.7.0, and that
the verify step runs after the bump. It used to be `zig build release`, one of
six copies of the same program.

[devtools]: https://github.com/diaryx-org/devtools

It stops at the tag. **Nothing has left the machine until you push**, and it
ends by printing the two commands it did not run.

```
$ release release minor

━━ preflight ━━
  clean tree, on main, up to date with origin, git-cliff present
  v3.3.0 is free locally and on origin
  crates.io: 3.3.0 is unpublished (7 crate(s) asked)
  docs/CHANGELOG.md: one marker pair, in `## Unreleased`
━━ bump ━━ … ━━ verify (zig build check) ━━ … ━━ changelog ━━ … ━━ commit + tag ━━
━━ done — nothing has left this machine ━━

To release:

    git push origin main
    git push origin v3.3.0
```

## What the one command does

| step | what it does |
|---|---|
| preflight | refuses a release that is already doomed (see below) |
| bump | `build.zig.zon`, then the mirror — `bindings/rust/Cargo.toml` (package + internal pins) and its `Cargo.lock` |
| verify | `zig build check` — what CI runs |
| changelog | regenerate the region, then the **cut** |
| commit | `chore: release X.Y.Z`, holding exactly the four files above |
| tag | annotated `vX.Y.Z` |
| push | **only** with `--push` |

The order is deliberate: verify runs *after* the bump, because what is being
released is the tree with the new version in it — `zig build check` depends on
`sync-version-check`, which would otherwise be checking the versions this
release replaces. That is `verify_after_bump = true` in the config; everywhere
else in the org the check is about the code and runs first.

The **cut** renames `## Unreleased` to `## X.Y.Z`, strips the two `git-cliff`
marker lines out of the section that just became history, and opens a fresh
empty `## Unreleased` above it. A handwritten release intro below the end marker
rides down into the released section, where regeneration cannot reach it.
Exactly one marker pair is ever in the file, which is what stops a later
`--write` from rewriting a released section. (It once did: 3.2.0 was cut by hand
and left the markers behind.)

## What preflight refuses

- a dirty working tree — the release commit holds the bump and the changelog and
  nothing else
- a branch other than `main`
- a `main` behind `origin/main` (advisory when origin is unreachable)
- no `git-cliff` on `PATH`
- a tag that already exists, locally or on origin
- a version already on crates.io, asked of the sparse index for every crate in
  `bindings/rust/Cargo.lock` (advisory when there is no `curl`) — the tag is not
  the only way a version gets spent, and a published number can never be reused
- a `CHANGELOG.md` whose marker pair is missing, doubled, or not inside
  `## Unreleased`

After the bump, any failure runs `git checkout -- .`. That is exact rather than
approximate because preflight proved the tree was clean, so nothing but this
tool's own writes can be lost. The one point of no automatic return is between
the commit and the tag; the tool says so and leaves it for a human.

## `as-is`

`release release as-is` releases the version the tree already holds,
bumping nothing. It is for the case where a bump landed in an earlier commit and
was never released: the number is already right, and what is missing is the tag,
the changelog cut, and the publish. Bumping again would spend a version number
to fix a bookkeeping gap. What a bump has to clear is the highest existing tag,
not the manifest, which is what makes that possible.

## What the push sets off

Both workflows fire on the same `v*` tag and neither can be undone.

- **`release.yml`** — cross-builds the payload libraries, re-runs the Zig and
  Rust suites, checks the tag against `build.zig.zon`, vendors the Zig source
  into `twig-sys`, then publishes bottom-up to crates.io (the five
  `twig-sys-<target>` payload crates, then `twig-sys`, then `twig-doc`) and cuts
  the GitHub release with `git-cliff`-generated notes.
- **`homebrew.yml`** — builds the CLI binaries and a `wasm32-wasi` build,
  attaches them to the same release, and writes `diaryx-org/homebrew-tap`.

A crates.io version number is spent even after a yank, which is why `--push` is
asked for every time rather than being the default.

## The pieces, on their own

Each step of the release is also a command, for the times a release is not what
you want:

| command | what it does |
|---|---|
| `zig build check` | the pre-release gate: version sync, build, `zig build test`, the C ABI library, and the Rust binding suite (skipped with a note when there is no `cargo`) |
| `release changelog` | print the `## Unreleased` region |
| `release changelog --write` | splice it into `docs/CHANGELOG.md` |
| `release changelog --check` | fail if that region is stale |
| `release bump <spec>` | move `build.zig.zon` and the mirror, and stop there |
| `release version` | the canonical version |
| `zig build sync-version-check` | fail on version drift (what CI runs) |
| `scripts/sync-version.sh --print` | the canonical version, without nu |

`build.zig.zon`'s `.version` is the single source of truth: it drives the C
ABI's `twig_version`, and `mirrors` in `.config/release.toml` names the Cargo
workspace that copies it. Adding a file that carries the version is an edit to
that config.

`scripts/sync-version.sh` used to write it too, and `zig build release` bumped
through its `--set`. It is a checker now — `--check` and `--print` — and that is
deliberate: a writer and an independent checker that disagree fail loudly, where
two writers would quietly produce different bytes. The two were verified
byte-identical on a 3.2.1 -> 3.3.0 bump before the writing half was removed.

## When it goes wrong

The tool prints the undo, but for reference:

```
git tag -d vX.Y.Z && git reset --hard HEAD~1     # before the push
```

After the push there is no undo. A partial crates.io publish is the one
recoverable case: `release.yml`'s publish loop treats "already uploaded" as
success, so re-running the failed job finishes it.
