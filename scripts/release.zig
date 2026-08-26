//! Dev tool: cut a release, as one command.
//!
//! twig releases on a tag: pushing `vX.Y.Z` starts `release.yml` (the seven
//! crates, bottom-up, to crates.io, plus the GitHub release and its notes) and
//! `homebrew.yml` (the CLI binaries, the wasm32-wasi build, and the tap).
//! Everything before that push is mechanical and easy to get half-right by
//! hand — the version lives in `build.zig.zon` and is copied into two Rust
//! manifests, the changelog's generated region has to be regenerated and then
//! cut into a released section with a fresh empty one opened above it, and the
//! tag has to match the number in the tree — so it lives here instead of in a
//! checklist:
//!
//!   zig build release -- <version|major|minor|patch|as-is> [flags]
//!
//!     as-is  : release the version the tree already holds, bumping nothing
//!     flags  : --push       also push the branch and the tag
//!              --no-verify  skip `zig build check`
//!
//! `as-is` is for the case a bump-first tool otherwise handles badly: a version
//! that was raised in an earlier commit and never released. The number is
//! already right; what is missing is the tag, the changelog cut, and the
//! publish. Bumping again to release it would spend a version number to fix a
//! bookkeeping gap.
//!
//! The order is: preflight, bump, verify, changelog, commit, tag, stop.
//!
//! `release` stops at the tag unless it is given `--push`. That asymmetry is
//! the whole safety model: everything before the push is a local commit that
//! can be thrown away (the tool prints the two-command undo), and the push is
//! the one that puts a version number on crates.io, where it can be yanked but
//! never reused. So the push is asked for explicitly, each time, and a run
//! without it ends by printing the commands it did not run.
//!
//! Preflight refuses a release that is already doomed — dirty tree, wrong
//! branch, behind origin, no git-cliff, a tag that exists, a version crates.io
//! has already seen, a changelog whose markers aren't where the cut expects
//! them — because a half-applied release is a working tree to untangle by hand,
//! and not doing that is the point. After the bump, any failure restores the
//! tree (preflight proved it was clean, so `git checkout -- .` is exact).

const std = @import("std");
const Dir = std.Io.Dir;

const max_file = 1 * 1024 * 1024;

const changelog_rel = "docs/CHANGELOG.md";
const changelog_script_rel = "scripts/changelog.sh";
const sync_version_rel = "scripts/sync-version.sh";
const zon_rel = "build.zig.zon";
const cargo_lock_rel = "bindings/rust/Cargo.lock";

// The generated region inside the `## Unreleased` section. Only these two lines
// locate the cut; the bytes between them are git-cliff's, and the bytes after
// them (a handwritten release intro, when a release wants one) are the author's
// and move into the released section untouched.
const begin_marker = "<!-- git-cliff:begin — generated; edits here are overwritten -->";
const end_marker = "<!-- git-cliff:end -->";
/// What the region says when there is nothing unreleased — the state the cut
/// leaves behind, and `scripts/changelog.sh`'s own empty-case text.
const empty_region = "_No commits since the last tag._";
const unreleased_heading = "## Unreleased";
/// git-cliff's bucket for a commit whose subject it could not parse. Not fatal —
/// the release is still shippable — but it is the one thing in the region that
/// wants a human's eye before it becomes permanent.
const uncategorised_needle = "Uncategorised";

/// Every file a release may move. Named explicitly so the release commit holds
/// the bump and the changelog and nothing else, and so an unexpected edit is
/// caught rather than swept in.
const release_paths = [_][]const u8{
    zon_rel,
    "bindings/rust/Cargo.toml",
    cargo_lock_rel,
    changelog_rel,
};

/// The spec that bumps nothing: release whatever the tree already says.
const as_is = "as-is";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // argv0
    // Injected by build.zig via addArg, not passed through `--`. `zig_exe` is
    // the compiler running this build rather than whatever `zig` is first on
    // PATH: the verify step below is a nested top-level build, and it should be
    // the same toolchain that got this far.
    const repo_root = args.next() orelse return usage("missing <repo-root>");
    const zig_exe = args.next() orelse return usage("missing <zig-exe>");

    var push = false;
    var verify = true;
    var spec: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--push")) {
            push = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            verify = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(std.fmt.allocPrint(arena, "unknown flag `{s}`", .{arg}) catch "unknown flag");
        } else if (spec == null) {
            spec = arg;
        } else {
            return usage(std.fmt.allocPrint(arena, "unexpected second version `{s}` — twig has one version", .{arg}) catch "too many versions");
        }
    }
    const want = spec orelse return usage("nothing to release — say which version");

    const cwd = Dir.cwd();
    const sh = Sh{ .gpa = gpa, .io = io, .root = repo_root };

    const current = readVersion(io, arena, cwd, repo_root) catch
        fail("could not read `.version` from {s}", .{zon_rel});
    const bumping = !std.mem.eql(u8, want, as_is);
    const next = if (bumping)
        current.bump(want) catch |err| fail("{s}", .{bumpError(err, want, current, arena)})
    else
        current;
    const tag = try std.fmt.allocPrint(arena, "v{f}", .{next});

    // ---- preflight: everything that can say no, before anything is written --
    step("preflight");
    try preflight(sh, arena, cwd, repo_root, next, tag);

    // ---- bump ---------------------------------------------------------------
    step("bump");
    if (bumping) {
        const script = try std.fs.path.join(arena, &.{ repo_root, sync_version_rel });
        const version_text = try std.fmt.allocPrint(arena, "{f}", .{next});
        if (!try sh.stream(&.{ "sh", script, "--set", version_text }))
            fail("`{s} --set {s}` failed — the tree is untouched by anything after it", .{ sync_version_rel, version_text });
    } else {
        std.debug.print("as-is — releasing {f}, no bump\n", .{current});
    }

    std.debug.print("\nrelease: twig {f}  (tag {s})\n", .{ next, tag });

    // From here on the tree may be dirty, so every exit restores it.
    errdefer sh.restore();

    // ---- verify -------------------------------------------------------------
    if (verify) {
        step("verify (zig build check)");
        if (!try sh.stream(&.{ zig_exe, "build", "check" })) {
            sh.restore();
            fail("`zig build check` failed — tree restored, nothing committed", .{});
        }
    } else {
        step("verify — SKIPPED (--no-verify)");
    }

    // ---- changelog ----------------------------------------------------------
    step("changelog");
    const script = try std.fs.path.join(arena, &.{ repo_root, changelog_script_rel });
    if (!try sh.stream(&.{ "sh", script, "--write" })) {
        sh.restore();
        fail("`{s} --write` failed — tree restored, nothing committed", .{changelog_script_rel});
    }
    const changelog_path = try std.fs.path.join(arena, &.{ repo_root, changelog_rel });
    const changelog = cwd.readFileAlloc(io, changelog_path, arena, .limited(max_file)) catch {
        sh.restore();
        fail("could not re-read {s} — tree restored", .{changelog_rel});
    };
    const cut = cutReleaseFull(arena, changelog, try std.fmt.allocPrint(arena, "{f}", .{next})) catch |err| {
        sh.restore();
        fail("could not cut {s}: {s} — tree restored", .{ changelog_rel, explain(err) });
    };
    // Checked after the regeneration rather than before it: a region that was
    // merely stale is not an empty release, and the run above is what tells the
    // two apart.
    if (std.mem.eql(u8, std.mem.trim(u8, cut.released_body, " \n\r"), empty_region)) {
        sh.restore();
        fail("no commits since the last tag — there is nothing to release; tree restored", .{});
    }
    try writeFile(io, cwd, changelog_path, cut.text);
    std.debug.print("{s}: `## Unreleased` -> `## {f}`, fresh empty region above it\n", .{ changelog_rel, next });
    if (std.mem.indexOf(u8, cut.released_body, uncategorised_needle) != null)
        std.debug.print(
            \\
            \\  WARNING: the cut section still has an "Uncategorised — triage before release"
            \\  bucket. Those are commits whose subject git-conventional could not read. They
            \\  are shipped as-is; the region is generated, so fixing them means an amended
            \\  subject, not an edit here. Look before you push.
            \\
        , .{});

    // ---- commit + tag -------------------------------------------------------
    step("commit + tag");
    try commit(sh, arena, cwd, repo_root, next);
    if (!try sh.stream(&.{ "git", "-C", repo_root, "tag", "-a", tag, "-m", try std.fmt.allocPrint(arena, "twig {f}", .{next}) }))
        // The commit is already made; leave it and say so rather than guessing
        // which half to unwind.
        fail("could not create tag {s} — the release COMMIT is in place; finish or undo by hand", .{tag});

    // ---- push, or the commands not run --------------------------------------
    const branch = try sh.capture(arena, &.{ "git", "-C", repo_root, "rev-parse", "--abbrev-ref", "HEAD" });
    if (!push) {
        step("done — nothing has left this machine");
        std.debug.print(
            \\To release:
            \\
            \\    git push origin {s}
            \\    git push origin {s}
            \\
            \\What the tag sets off:
            \\  release.yml   ->  crates.io (the payload crates, twig-sys, twig-doc) and the GitHub release
            \\  homebrew.yml  ->  the CLI binaries, the wasm32-wasi build, and diaryx-org/homebrew-tap
            \\
            \\None of it can be undone — a published version number is spent even after a
            \\yank. To undo locally instead:
            \\
            \\    git tag -d {s} && git reset --hard HEAD~1
            \\
            \\
        , .{ branch, tag, tag });
        return;
    }

    step("push");
    if (!try sh.stream(&.{ "git", "-C", repo_root, "push", "origin", branch }))
        fail("could not push {s} — the commit and tag are still local", .{branch});
    if (!try sh.stream(&.{ "git", "-C", repo_root, "push", "origin", tag }))
        fail("could not push {s} — the branch is pushed; the tag is not", .{tag});
    std.debug.print("\nrelease: pushed. The release workflows are running:\n  https://github.com/diaryx-org/twig/actions\n\n", .{});
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

/// A semver triple, which is all twig has ever used. Pre-release and build
/// metadata are deliberately unparsed rather than silently dropped: a version
/// this cannot read is a version it must not rewrite.
const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn parse(text: []const u8) !Version {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '.');
        const major = it.next() orelse return error.NotAVersion;
        const minor = it.next() orelse return error.NotAVersion;
        const patch = it.next() orelse return error.NotAVersion;
        if (it.next() != null) return error.NotAVersion;
        return .{
            .major = std.fmt.parseInt(u32, major, 10) catch return error.NotAVersion,
            .minor = std.fmt.parseInt(u32, minor, 10) catch return error.NotAVersion,
            .patch = std.fmt.parseInt(u32, patch, 10) catch return error.NotAVersion,
        };
    }

    /// `patch`, `minor`, `major`, or a literal version to move to. A literal is
    /// checked against the current version rather than trusted: a release that
    /// goes backwards is a typo every time, and the tag it would cut is the one
    /// thing that cannot be taken back.
    fn bump(self: Version, spec: []const u8) !Version {
        if (std.mem.eql(u8, spec, "patch"))
            return .{ .major = self.major, .minor = self.minor, .patch = self.patch + 1 };
        if (std.mem.eql(u8, spec, "minor"))
            return .{ .major = self.major, .minor = self.minor + 1, .patch = 0 };
        if (std.mem.eql(u8, spec, "major"))
            return .{ .major = self.major + 1, .minor = 0, .patch = 0 };
        const literal = try Version.parse(spec);
        if (literal.order(self) != .gt) return error.NotAhead;
        return literal;
    }

    fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

fn bumpError(err: anyerror, spec: []const u8, current: Version, arena: std.mem.Allocator) []const u8 {
    return switch (err) {
        error.NotAhead => std.fmt.allocPrint(
            arena,
            "{s} is not ahead of the current {f}\nhint: releases only move forward — a published version number can never be reused",
            .{ spec, current },
        ) catch "that version is not ahead of the current one",
        else => std.fmt.allocPrint(
            arena,
            "`{s}` is neither an x.y.z version nor one of major|minor|patch|as-is",
            .{spec},
        ) catch "unreadable version spec",
    };
}

/// The canonical version: the `.version = "x.y.z",` line in build.zig.zon, which
/// is also what `scripts/sync-version.sh` reads and what the C ABI's
/// `twig_version` is built from.
fn readVersion(io: std.Io, arena: std.mem.Allocator, cwd: Dir, root: []const u8) !Version {
    const text = try readRel(io, arena, cwd, root, zon_rel);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".version = \"")) continue;
        const rest = trimmed[".version = \"".len..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NotAVersion;
        return Version.parse(rest[0..close]);
    }
    return error.NotAVersion;
}

/// The crates a release publishes, read off the lockfile rather than listed
/// here: the workspace is the authority on what its members are called, and a
/// payload crate added for a new target should not need an edit in this file to
/// be checked against the registry.
fn crateNames(arena: std.mem.Allocator, lock: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, lock, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "name = \"")) continue;
        const rest = line["name = \"".len..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        try names.append(arena, rest[0..close]);
    }
    return names.items;
}

/// The sparse-index path for a crate name: `tw/ig/twig-doc`. Only the shape
/// every twig crate has (four characters or more) is handled; a shorter name
/// would need the 1/, 2/, 3/ prefixes, and there is no such crate here.
fn indexPath(arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (name.len < 4) return null;
    return try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ name[0..2], name[2..4], name });
}

// ---------------------------------------------------------------------------
// Preflight
// ---------------------------------------------------------------------------

fn preflight(sh: Sh, arena: std.mem.Allocator, cwd: Dir, root: []const u8, next: Version, tag: []const u8) !void {
    // git-cliff writes the region the cut then moves; finding it missing after
    // the bump would mean unwinding a bump for a missing dependency.
    if (!try sh.quiet(&.{ "git-cliff", "--version" }))
        fail("git-cliff is not on PATH — `nix develop` (it is in the dev shell), or `cargo install git-cliff`", .{});

    const dirty = try sh.capture(arena, &.{ "git", "-C", root, "status", "--porcelain" });
    if (dirty.len != 0)
        fail("the working tree is dirty — commit or stash first, so the release commit holds only the bump and the changelog:\n{s}", .{dirty});

    const branch = try sh.capture(arena, &.{ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" });
    if (!std.mem.eql(u8, branch, "main"))
        fail("on branch `{s}`, and twig releases from `main`", .{branch});

    // A release cut on a stale main is a release missing commits. Advisory: a
    // laptop offline enough to fail the fetch can still cut the commit and push
    // later.
    if (try sh.quiet(&.{ "git", "-C", root, "fetch", "--quiet", "origin", "main" })) {
        const behind = try sh.capture(arena, &.{ "git", "-C", root, "rev-list", "--count", "HEAD..origin/main" });
        if (!std.mem.eql(u8, behind, "0"))
            fail("main is {s} commit(s) behind origin/main — pull first", .{behind});
    } else {
        std.debug.print("  WARNING: could not reach origin; releasing against the local main\n", .{});
    }

    // A tag that exists is a release that already happened, whatever this
    // checkout knows.
    const ref = try std.fmt.allocPrint(arena, "refs/tags/{s}", .{tag});
    if (try sh.quiet(&.{ "git", "-C", root, "rev-parse", "-q", "--verify", ref }))
        fail("tag {s} already exists locally", .{tag});
    if (try sh.tryCapture(arena, &.{ "git", "-C", root, "ls-remote", "--tags", "origin", ref })) |remote| {
        if (remote.len != 0) fail("tag {s} already exists on origin — that release already happened", .{tag});
    }

    // The tag is not the only way a version gets spent: a crate can go to
    // crates.io from a laptop, untagged. So ask the registry too. Advisory when
    // there is no curl or no network — an unanswered question is not a "no".
    try registryIsFree(sh, arena, cwd, root, next);

    // The cut is a text rewrite of one section, so its shape is a precondition,
    // not something to discover with a bumped tree on the floor.
    const text = try readRel(io_of(sh), arena, cwd, root, changelog_rel);
    _ = parseUnreleased(text) catch |err| fail("{s}: {s}", .{ changelog_rel, explain(err) });

    std.debug.print("  clean tree, on main, up to date with origin, git-cliff present\n", .{});
    std.debug.print("  {s} is free locally and on origin\n", .{tag});
    std.debug.print("  {s}: one marker pair, in `## Unreleased`\n", .{changelog_rel});
}

/// Refuse a version crates.io has already seen. Asked of the sparse index
/// rather than the API: it is a plain CDN, needs no User-Agent, and answers 404
/// for a crate that has never been published at all.
fn registryIsFree(sh: Sh, arena: std.mem.Allocator, cwd: Dir, root: []const u8, next: Version) !void {
    if (!try sh.quiet(&.{ "curl", "--version" })) {
        std.debug.print("  WARNING: no curl; skipping the crates.io check\n", .{});
        return;
    }
    const lock = try readRel(io_of(sh), arena, cwd, root, cargo_lock_rel);
    const needle = try std.fmt.allocPrint(arena, "\"vers\":\"{f}\"", .{next});
    var asked: usize = 0;
    for (try crateNames(arena, lock)) |name| {
        const path = (try indexPath(arena, name)) orelse continue;
        const url = try std.fmt.allocPrint(arena, "https://index.crates.io/{s}", .{path});
        // A 404 is a crate that has never been published; `--fail` turns that
        // into a non-zero exit, which tryCapture reports as "no answer", which
        // is the right answer here.
        const body = (try sh.tryCapture(arena, &.{ "curl", "--silent", "--fail", "--max-time", "10", url })) orelse continue;
        asked += 1;
        if (std.mem.indexOf(u8, body, needle) != null)
            fail(
                "{s} {f} is already on crates.io\nhint: a published version number can never be reused; release {d}.{d}.{d} instead",
                .{ name, next, next.major, next.minor, next.patch + 1 },
            );
    }
    std.debug.print("  crates.io: {f} is unpublished ({d} crate(s) asked)\n", .{ next, asked });
}

fn explain(err: CutError) []const u8 {
    return switch (err) {
        error.NoBeginMarker => "the git-cliff begin marker is missing",
        error.NoEndMarker => "the git-cliff end marker is missing",
        error.DuplicateMarker => "more than one git-cliff marker pair — the cut strips them from released sections, so exactly one pair should exist, in `## Unreleased`",
        error.NotUnreleased => "the generated region is not inside a `## Unreleased` section — a previous release was cut by hand and left the markers behind",
        error.OutOfMemory => "out of memory",
    };
}

// ---------------------------------------------------------------------------
// The changelog cut
// ---------------------------------------------------------------------------

const CutError = error{
    NoBeginMarker,
    NoEndMarker,
    DuplicateMarker,
    NotUnreleased,
    OutOfMemory,
};

/// Where the `## Unreleased` section is, and what is in it.
const Unreleased = struct {
    /// Byte offset of the `## Unreleased` line.
    heading_start: usize,
    /// The generated bytes between the markers (git-cliff's).
    body: []const u8,
    /// Anything written by hand between the end marker and the next `## `
    /// heading — a release intro, which the cut carries down with the section.
    tail: []const u8,
    /// Byte offset of the next `## ` heading (the previous release), or the end
    /// of the file.
    section_end: usize,
};

fn parseUnreleased(text: []const u8) CutError!Unreleased {
    const begin = std.mem.indexOf(u8, text, begin_marker) orelse return error.NoBeginMarker;
    const after_begin = begin + begin_marker.len;
    if (std.mem.indexOf(u8, text[after_begin..], begin_marker) != null) return error.DuplicateMarker;
    const end = std.mem.indexOfPos(u8, text, after_begin, end_marker) orelse return error.NoEndMarker;
    if (std.mem.indexOfPos(u8, text, end + end_marker.len, end_marker) != null) return error.DuplicateMarker;

    // The last `## ` heading above the region. The file's preamble has several
    // (`## Behavioural changes are their own section`, …), so this must be the
    // nearest one, and it must be `## Unreleased` — anything else means a
    // previous release was cut by hand and the markers were left inside it.
    const heading_start = lastHeadingStart(text[0..begin]) orelse return error.NotUnreleased;
    const heading_line = lineAt(text, heading_start);
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, heading_line, " \r"), unreleased_heading)) return error.NotUnreleased;

    const end_of_end_line = lineEnd(text, end + end_marker.len);
    const section_end = nextHeadingStart(text, end_of_end_line) orelse text.len;
    return .{
        .heading_start = heading_start,
        .body = std.mem.trim(u8, text[lineEnd(text, after_begin)..end], " \n\r"),
        .tail = std.mem.trim(u8, text[end_of_end_line..section_end], " \n\r"),
        .section_end = section_end,
    };
}

const Cut = struct {
    text: []const u8,
    /// The bytes that became the released section's body — what the caller
    /// scans for a triage bucket, and for "there was nothing to release".
    released_body: []const u8,
};

/// Rename `## Unreleased` to `## <heading>`, drop the two marker lines from the
/// section that just became history (so exactly one marker pair is ever in the
/// file, and the next `zig build changelog` cannot rewrite a released section),
/// and open a fresh empty `## Unreleased` above it.
fn cutRelease(arena: std.mem.Allocator, text: []const u8, heading: []const u8) CutError![]const u8 {
    const cut = try cutReleaseFull(arena, text, heading);
    return cut.text;
}

fn cutReleaseFull(arena: std.mem.Allocator, text: []const u8, heading: []const u8) CutError!Cut {
    const u = try parseUnreleased(text);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text[0..u.heading_start]);
    // The fresh, empty Unreleased section — the same shape scripts/changelog.sh
    // writes, so the next `--write` lands exactly here.
    try out.print(arena, "{s}\n\n{s}\n\n{s}\n\n{s}\n\n", .{ unreleased_heading, begin_marker, empty_region, end_marker });
    // The section that just became history, markers stripped.
    try out.print(arena, "## {s}\n\n{s}\n", .{ heading, u.body });
    if (u.tail.len != 0) try out.print(arena, "\n{s}\n", .{u.tail});
    if (u.section_end < text.len) try out.print(arena, "\n{s}", .{text[u.section_end..]});
    return .{ .text = try out.toOwnedSlice(arena), .released_body = u.body };
}

/// Start offset of the last line beginning with `## ` in `text`.
fn lastHeadingStart(text: []const u8) ?usize {
    var i = text.len;
    while (i > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0 .. i - 1], '\n')) |nl| nl + 1 else 0;
        if (std.mem.startsWith(u8, text[line_start..], "## ")) return line_start;
        if (line_start == 0) return null;
        i = line_start;
    }
    return null;
}

/// Start offset of the first line beginning with `## ` at or after `from`.
fn nextHeadingStart(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "## ")) return i;
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return null;
        i = nl + 1;
    }
    return null;
}

/// The line containing `at`, without its newline.
fn lineAt(text: []const u8, at: usize) []const u8 {
    const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return text[at..nl];
}

/// The offset just past the newline ending the line that contains `at`.
fn lineEnd(text: []const u8, at: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return text.len;
    return nl + 1;
}

// ---------------------------------------------------------------------------
// Commit
// ---------------------------------------------------------------------------

/// Stage exactly the files a release moves, refuse if anything else changed,
/// and commit. `chore: release …` is skipped by `.config/cliff.toml`, so the
/// release commit never appears in the next release's changelog.
fn commit(sh: Sh, arena: std.mem.Allocator, cwd: Dir, root: []const u8, next: Version) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "-C", root, "add", "--" });
    for (release_paths) |rel| {
        const path = try std.fs.path.join(arena, &.{ root, rel });
        // A path that doesn't exist is a repo-layout change, not a release
        // problem; skip it rather than failing the whole cut on `git add`.
        if (cwd.access(io_of(sh), path, .{})) |_| {
            try argv.append(arena, rel);
        } else |_| {}
    }
    if (!try sh.stream(argv.items)) fail("`git add` failed", .{});

    // Anything still unstaged is something this tool did not mean to write —
    // a file `check` regenerated, most likely. Say so instead of committing a
    // release with a stranger in it.
    const leftover = try sh.capture(arena, &.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" });
    var it = std.mem.splitScalar(u8, leftover, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // Staged-only entries have a space in the second status column.
        if (line.len > 1 and line[1] != ' ')
            fail("unexpected change outside the release files: `{s}` — commit or discard it, then re-run", .{line});
    }

    const message = try std.fmt.allocPrint(arena, "chore: release {f}", .{next});
    if (!try sh.stream(&.{ "git", "-C", root, "commit", "-m", message })) fail("`git commit` failed", .{});
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

/// Child processes, in the two shapes this tool needs: `stream` for the long
/// ones whose output the maintainer should watch (the bump, `check`, git), and
/// `capture`/`quiet` for the short questions asked of git and the registry.
const Sh = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    /// Run with the parent's stdio; `true` if it exited 0.
    fn stream(sh: Sh, argv: []const []const u8) !bool {
        var child = try std.process.spawn(sh.io, .{ .argv = argv, .cwd = .{ .path = sh.root } });
        return ok(try child.wait(sh.io));
    }

    /// Run silently; `true` if it exited 0. For "is this tool here" and for
    /// commands whose failure is not itself news (`git fetch` offline).
    fn quiet(sh: Sh, argv: []const []const u8) !bool {
        const res = std.process.run(sh.gpa, sh.io, .{ .argv = argv, .cwd = .{ .path = sh.root } }) catch return false;
        defer sh.gpa.free(res.stdout);
        defer sh.gpa.free(res.stderr);
        return ok(res.term);
    }

    /// Run and return trimmed stdout, failing the release if the command does.
    fn capture(sh: Sh, arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
        const res = std.process.run(sh.gpa, sh.io, .{ .argv = argv, .cwd = .{ .path = sh.root } }) catch
            fail("could not run `{s}`", .{argv[0]});
        defer sh.gpa.free(res.stdout);
        defer sh.gpa.free(res.stderr);
        if (!ok(res.term))
            fail("`{s} …` failed:\n{s}", .{ argv[0], res.stderr });
        return arena.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n")) catch fail("out of memory", .{});
    }

    /// Trimmed stdout, or null if the command could not run or failed — for
    /// questions asked of the network, where "no answer" is not "no".
    fn tryCapture(sh: Sh, arena: std.mem.Allocator, argv: []const []const u8) !?[]const u8 {
        const res = std.process.run(sh.gpa, sh.io, .{ .argv = argv, .cwd = .{ .path = sh.root } }) catch return null;
        defer sh.gpa.free(res.stdout);
        defer sh.gpa.free(res.stderr);
        if (!ok(res.term)) return null;
        return try arena.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    }

    /// Put the tree back. Sound because preflight proved it was clean: nothing
    /// but this tool's own writes can be lost.
    fn restore(sh: Sh) void {
        _ = sh.quiet(&.{ "git", "-C", sh.root, "checkout", "--", "." }) catch {};
    }
};

/// A process that finished the way a tool is supposed to.
fn ok(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn io_of(sh: Sh) std.Io {
    return sh.io;
}

// ---------------------------------------------------------------------------
// Files, messages
// ---------------------------------------------------------------------------

fn readRel(io: std.Io, arena: std.mem.Allocator, cwd: Dir, root: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(arena, &.{ root, rel });
    return cwd.readFileAlloc(io, path, arena, .limited(max_file));
}

fn writeFile(io: std.Io, cwd: Dir, path: []const u8, text: []const u8) !void {
    const file = try cwd.createFile(io, path, .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, text, 0);
    try file.setLength(io, text.len);
}

fn step(title: []const u8) void {
    std.debug.print("\n━━ {s} ━━\n", .{title});
}

fn usage(why: []const u8) noreturn {
    std.debug.print(
        \\release: {s}
        \\
        \\usage: zig build release -- <version|major|minor|patch|as-is> [--push] [--no-verify]
        \\  version : an explicit SemVer (e.g. 3.3.0), a bump keyword, or `as-is`
        \\            to release the version build.zig.zon already holds
        \\
        \\examples:
        \\  zig build release -- minor
        \\  zig build release -- 4.0.0
        \\  zig build release -- patch --push
        \\
        \\Preview the changelog region without releasing: zig build changelog
        \\
    , .{why});
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("release: FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Tests — the cut and the version arithmetic, which are the parts that rewrite
// a file by hand rather than shelling out to something that owns the format,
// and whose mistakes are only visible once a release is already history.
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\# Twig — changelog
    \\
    \\## How the Unreleased section is written
    \\
    \\Preamble prose with its own `## ` heading.
    \\
    \\## Unreleased
    \\
    \\<!-- git-cliff:begin — generated; edits here are overwritten -->
    \\
    \\### Added
    \\
    \\- **editor** — a thing ([`abc1234`](https://example.com))
    \\
    \\<!-- git-cliff:end -->
    \\
    \\## 3.1.0
    \\
    \\### Added
    \\
    \\- an older thing
    \\
;

test "cut renames Unreleased and opens a fresh empty one above it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try cutRelease(arena_state.allocator(), sample, "3.2.0");

    // Exactly one marker pair survives, and it is in the new Unreleased.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, begin_marker));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, end_marker));
    const parsed = try parseUnreleased(out);
    try testing.expectEqualStrings(empty_region, parsed.body);

    // The released section holds the bullets, and no markers.
    const released = std.mem.indexOf(u8, out, "## 3.2.0").?;
    try testing.expect(std.mem.indexOf(u8, out[released..], begin_marker) == null);
    try testing.expect(std.mem.indexOf(u8, out[released..], "**editor** — a thing") != null);

    // Order: preamble, Unreleased, the new release, the old one.
    try testing.expect(std.mem.indexOf(u8, out, "Preamble prose").? < std.mem.indexOf(u8, out, unreleased_heading).?);
    try testing.expect(std.mem.indexOf(u8, out, unreleased_heading).? < released);
    try testing.expect(released < std.mem.indexOf(u8, out, "## 3.1.0").?);
    try testing.expect(std.mem.indexOf(u8, out, "- an older thing") != null);
}

test "a handwritten intro below the end marker rides down into the release" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const with_intro = try std.mem.replaceOwned(
        u8,
        arena_state.allocator(),
        sample,
        "<!-- git-cliff:end -->\n",
        "<!-- git-cliff:end -->\n\nWhy this release is a major.\n",
    );
    const out = try cutRelease(arena_state.allocator(), with_intro, "4.0.0");
    const released = std.mem.indexOf(u8, out, "## 4.0.0").?;
    const intro = std.mem.indexOf(u8, out, "Why this release is a major.").?;
    try testing.expect(released < intro);
    try testing.expect(intro < std.mem.indexOf(u8, out, "## 3.1.0").?);
}

test "cutting twice is refused rather than rewriting a released section" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const once = try cutRelease(arena, sample, "3.2.0");
    // The second cut has an empty region to move, which is a "nothing to
    // release" the caller catches — but it must still parse, and it must not
    // find the 3.2.0 section's markers, because there are none.
    const twice = try cutRelease(arena, once, "3.3.0");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, twice, begin_marker));
    try testing.expect(std.mem.indexOf(u8, twice, "**editor** — a thing") != null);
}

test "markers left inside a released section are refused" {
    const hand_cut = try std.mem.replaceOwned(u8, testing.allocator, sample, unreleased_heading, "## 3.2.0");
    defer testing.allocator.free(hand_cut);
    try testing.expectError(error.NotUnreleased, parseUnreleased(hand_cut));
}

test "a missing or doubled marker is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const no_begin = try std.mem.replaceOwned(u8, arena, sample, begin_marker, "");
    try testing.expectError(error.NoBeginMarker, parseUnreleased(no_begin));

    const no_end = try std.mem.replaceOwned(u8, arena, sample, end_marker, "");
    try testing.expectError(error.NoEndMarker, parseUnreleased(no_end));

    const doubled = try std.fmt.allocPrint(arena, "{s}\n{s}\n{s}\n", .{ sample, begin_marker, end_marker });
    try testing.expectError(error.DuplicateMarker, parseUnreleased(doubled));
}

test "version arithmetic, and the refusal to go backwards" {
    const v = Version{ .major = 3, .minor = 2, .patch = 0 };
    try testing.expectEqual(Version{ .major = 3, .minor = 2, .patch = 1 }, try v.bump("patch"));
    try testing.expectEqual(Version{ .major = 3, .minor = 3, .patch = 0 }, try v.bump("minor"));
    try testing.expectEqual(Version{ .major = 4, .minor = 0, .patch = 0 }, try v.bump("major"));
    try testing.expectEqual(Version{ .major = 5, .minor = 1, .patch = 2 }, try v.bump("5.1.2"));

    try testing.expectError(error.NotAhead, v.bump("3.2.0"));
    try testing.expectError(error.NotAhead, v.bump("3.1.9"));
    try testing.expectError(error.NotAVersion, v.bump("3.2"));
    try testing.expectError(error.NotAVersion, v.bump("v3.3.0"));
    try testing.expectError(error.NotAVersion, v.bump("later"));
}

test "the crate list comes off the lockfile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lock =
        \\version = 4
        \\
        \\[[package]]
        \\name = "twig-doc"
        \\version = "3.2.0"
        \\dependencies = [
        \\ "twig-sys",
        \\]
        \\
        \\[[package]]
        \\name = "twig-sys"
        \\version = "3.2.0"
        \\
    ;
    const names = try crateNames(arena, lock);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("twig-doc", names[0]);
    try testing.expectEqualStrings("twig-sys", names[1]);
    try testing.expectEqualStrings("tw/ig/twig-doc", (try indexPath(arena, "twig-doc")).?);
}
