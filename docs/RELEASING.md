---
part_of: '[Twig](/README.md)'
---
# Twig — cutting a release

One command:

```
zig build release -- <version|major|minor|patch|as-is> [--push] [--no-verify]
```

It stops at the tag. **Nothing has left the machine until you push**, and it
ends by printing the two commands it did not run.

```
$ zig build release -- minor

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
| bump | `scripts/sync-version.sh --set X.Y.Z` — `build.zig.zon`, then `bindings/rust/Cargo.toml` and `Cargo.lock` |
| verify | `zig build check` — what CI runs |
| changelog | `scripts/changelog.sh --write`, then the **cut** |
| commit | `chore: release X.Y.Z`, holding exactly the four files above |
| tag | annotated `vX.Y.Z` |
| push | **only** with `--push` |

The order is deliberate: verify runs *after* the bump, because what is being
released is the tree with the new version in it.

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

`zig build release -- as-is` releases the version the tree already holds,
bumping nothing. It is for the case where a bump landed in an earlier commit and
was never released: the number is already right, and what is missing is the tag,
the changelog cut, and the publish. Bumping again would spend a version number
to fix a bookkeeping gap.

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
| `zig build changelog` | regenerate the `## Unreleased` region |
| `zig build changelog-check` | fail if that region is stale |
| `zig build sync-version` | copy `build.zig.zon`'s version into the Rust manifests |
| `zig build sync-version-check` | fail on version drift (what CI runs) |
| `scripts/sync-version.sh --print` | the canonical version |

`build.zig.zon`'s `.version` is the single source of truth: it drives the C
ABI's `twig_version`, and `scripts/sync-version.sh` is the only thing that knows
which other files carry a copy. `release` bumps by calling it, so adding a file
that carries the version means editing that script and nothing else.

## When it goes wrong

The tool prints the undo, but for reference:

```
git tag -d vX.Y.Z && git reset --hard HEAD~1     # before the push
```

After the push there is no undo. A partial crates.io publish is the one
recoverable case: the publish loop treats "already uploaded" as success, so
re-running the failed `release.yml` job finishes it.
