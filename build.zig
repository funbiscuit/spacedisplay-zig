const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip the binary");

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const clap_mod = clap.module("clap");

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis.module("vaxis");

    // The library: all application code.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addAnonymousImport("build_info", .{
        .root_source_file = b.path("build.zig.zon"),
    });
    lib_mod.addImport("clap", clap_mod);
    lib_mod.addImport("vaxis", vaxis_mod);

    // The executable: entry point only, all code comes from the library.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    exe_mod.addImport("spacedisplay", lib_mod);

    const exe = b.addExecutable(.{
        .name = "spacedisplay",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // End-to-end tests, seeing only the public API.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("spacedisplay", lib_mod);
    // the UI harness constructs vaxis Screen/Window and input events directly
    tests_mod.addImport("vaxis", vaxis_mod);

    const test_options = b.addOptions();
    test_options.addOptionPathDirectory("snapshot_dir", b.path("tests/snapshots"));
    test_options.addOptionPath("exe_path", exe.getEmittedBin());
    tests_mod.addImport("test_options", test_options.createModule());

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const e2e_tests = b.addTest(.{ .root_module = tests_mod });

    const test_step = b.step("test", "Run tests");
    // The emitted binaries run as plain processes, not through
    // addRunArtifact: its zig 0.17.0 test-server protocol can fail a step
    // after a clean run with no diagnostics and still exit 0 (caching the
    // failed run as a success). A plain run checks the standalone
    // runner's exit code, which already covers test failures, leaks, and
    // intercepted error logs.
    const lib_test_run = b.addRunFile(lib_tests.getEmittedBin());
    const e2e_test_run = b.addRunFile(e2e_tests.getEmittedBin());
    test_step.dependOn(&lib_test_run.step);
    test_step.dependOn(&e2e_test_run.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
