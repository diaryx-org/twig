const std = @import("std");
const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch
    @compileError("invalid `.version` in build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(u8, "version_major", @intCast(version.major));
    options.addOption(u8, "version_minor", @intCast(version.minor));
    options.addOption(u8, "version_patch", @intCast(version.patch));
    const options_mod = options.createModule();

    const mod = b.addModule("twig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "twig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "twig", .module = mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const c_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "twig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_abi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !target.result.cpu.arch.isWasm(),
        }),
    });
    c_lib.root_module.addImport("build_options", options_mod);
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    const install_c_header = b.addInstallHeaderFile(b.path("bindings/c/include/twig.h"), "twig.h");
    b.getInstallStep().dependOn(&install_c_lib.step);
    b.getInstallStep().dependOn(&install_c_header.step);

    const install_c_lib_step = b.step("install-c-lib", "Install the C ABI static library");
    install_c_lib_step.dependOn(&install_c_lib.step);
    install_c_lib_step.dependOn(&install_c_header.step);

    // WebAssembly build of the C ABI, for future JS/TS bindings: compile the
    // same `src/c_abi.zig` to a freestanding `reactor` module (no `_start`;
    // `rdynamic` keeps every exported `twig_*` symbol). `c_abi.zig` already
    // selects `wasm_allocator` over `c_allocator` on wasm targets (see
    // `activeAllocator`) and `c_lib`'s `link_libc` is already gated off for
    // wasm above, so no libc is needed here. `zig build wasm` writes
    // `twig.wasm` into the install prefix's `bin/`.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "twig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_abi.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    wasm.root_module.addImport("build_options", options_mod);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build the WebAssembly module for future JS/TS bindings");
    wasm_step.dependOn(&install_wasm.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // `zig build bench -- <file>`: parse a document under a counting allocator
    // and report allocation counts/bytes. Force ReleaseFast unless the user
    // overrode `-Doptimize` — bench numbers from a Debug build are noise.
    const bench = b.addExecutable(.{
        .name = "twig-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseFast,
            .imports = &.{
                .{ .name = "twig", .module = mod },
            },
        }),
    });
    const bench_step = b.step("bench", "Parse a file under a counting allocator (bench [--format f] [--iters N] <file>)");
    const bench_cmd = b.addRunArtifact(bench);
    bench_step.dependOn(&bench_cmd.step);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    // The C ABI (`src/c_abi.zig`) isn't imported by `mod` or `exe`, so it
    // needs its own test artifact to be covered by `zig build test`.
    const c_lib_tests = b.addTest(.{
        .root_module = c_lib.root_module,
    });

    const run_c_lib_tests = b.addRunArtifact(c_lib_tests);

    // The bench harness (`src/bench/`) isn't reachable from `mod`/`exe`, so its
    // own `test {}` blocks (e.g. the counting allocator's) need a dedicated
    // artifact to run under `zig build test`.
    const bench_tests = b.addTest(.{
        .root_module = bench.root_module,
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    // `bindings/c/include/twig.h` is hand-written and installed verbatim, so
    // nothing above ever runs a C compiler over it — the Zig and Rust sides
    // both hand-maintain their own view of the ABI. This test compiles the
    // header as C and links it against c_lib, which is the only thing that
    // catches a header that isn't valid C (it once wasn't: TWIG_ALIGN_* were
    // both macros and TwigAlignment enumerators) or codes that drift from what
    // the library returns. Skipped for wasm, which has no host C runner.
    const c_header_tests = b.addExecutable(.{
        .name = "twig-c-header-test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_header_tests.root_module.addCSourceFile(.{
        .file = b.path("bindings/c/test/header_test.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic" },
    });
    c_header_tests.root_module.addIncludePath(b.path("bindings/c/include"));
    c_header_tests.root_module.linkLibrary(c_lib);
    const run_c_header_tests = b.addRunArtifact(c_header_tests);

    // The release tool's changelog cut and version arithmetic
    // (`scripts/release.zig`). It lives in scripts/ rather than src/, but it is
    // the one maintenance tool that rewrites a file by hand instead of shelling
    // out to something that owns the format, and a mistake in it is only
    // visible once a release is already history — so its `test` blocks run with
    // everything else. `addTest` compiles the file for those blocks; the tool's
    // `main` is not run.
    const release_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/release.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_release_tool_tests = b.addRunArtifact(release_tool_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_c_lib_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_release_tool_tests.step);
    if (!target.result.cpu.arch.isWasm()) {
        test_step.dependOn(&run_c_header_tests.step);
    }

    // ---- version, changelog, release ---------------------------------------
    //
    // The maintenance side of the build: the three commands a release is made
    // of, and the one that runs all of them. See docs/RELEASING.md.
    //
    // Every one of these is `has_side_effects` — they rewrite the real tree or
    // ask git and the network questions whose answers are not build inputs, so
    // none of them may ever be served from the cache.

    const version_sync_run = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/sync-version.sh") });
    version_sync_run.has_side_effects = true;
    const version_sync_step = b.step("sync-version", "Copy build.zig.zon's version into the Rust manifests");
    version_sync_step.dependOn(&version_sync_run.step);

    const version_check_run = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/sync-version.sh"), "--check" });
    version_check_run.has_side_effects = true;
    const version_check_step = b.step("sync-version-check", "Fail if the Rust manifests' version has drifted from build.zig.zon");
    version_check_step.dependOn(&version_check_run.step);

    const changelog_run = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/changelog.sh"), "--write" });
    changelog_run.has_side_effects = true;
    const changelog_step = b.step("changelog", "Regenerate docs/CHANGELOG.md's Unreleased region from the commits since the last tag");
    changelog_step.dependOn(&changelog_run.step);

    const changelog_check_run = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/changelog.sh"), "--check" });
    changelog_check_run.has_side_effects = true;
    const changelog_check_step = b.step("changelog-check", "Fail if docs/CHANGELOG.md's Unreleased region is stale");
    changelog_check_step.dependOn(&changelog_check_run.step);

    // The pre-release gate: what CI runs, in one command. Deliberately NOT
    // including `changelog-check` — `release` regenerates the region itself,
    // after this runs, so a stale region is not a reason to refuse a release.
    const rust_check_run = b.addSystemCommand(&.{ "sh", b.pathFromRoot("scripts/rust-check.sh") });
    rust_check_run.has_side_effects = true;
    const check_step = b.step("check", "Pre-release gate: version sync + zig build + tests + C ABI library + the Rust binding suite (skipped with a note if cargo is missing)");
    check_step.dependOn(version_check_step);
    check_step.dependOn(b.getInstallStep());
    check_step.dependOn(test_step);
    check_step.dependOn(install_c_lib_step);
    check_step.dependOn(&rust_check_run.step);

    // The whole release, as one command: preflight, bump (via
    // `scripts/sync-version.sh --set`, so this file stays the only place that
    // knows which files carry a version), `zig build check`, the changelog
    // regen + cut, the release commit, the annotated tag, and a stop before the
    // push. See docs/RELEASING.md.
    //
    // The nested `zig build check` it runs is a separate top-level build
    // against the same cache — which is exactly what a maintainer would type —
    // and it has to run AFTER the bump, so it cannot be a dependency here.
    const release = b.addExecutable(.{
        .name = "release",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/release.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const release_run = b.addRunArtifact(release);
    release_run.addArg(b.pathFromRoot("."));
    release_run.addArg(b.graph.zig_exe);
    if (b.args) |args| release_run.addArgs(args);
    release_run.has_side_effects = true;
    const release_step = b.step("release", "Cut a release: bump, verify, cut the changelog, commit, tag (push only with --push)");
    release_step.dependOn(&release_run.step);
}
