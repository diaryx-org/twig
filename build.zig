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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_c_lib_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    if (!target.result.cpu.arch.isWasm()) {
        test_step.dependOn(&run_c_header_tests.step);
    }
}
