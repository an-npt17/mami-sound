const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: every engine piece lives here so it can be unit tested
    // without spawning aplay or touching any device.
    const mod = b.addModule("mami_sound", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mami_sound",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mami_sound", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Play the installation through aplay");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const core_mod = b.addModule("mami_sound_core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    const application_mod = b.addModule("mami_sound_application", .{
        .root_source_file = b.path("src/application_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const application_tests = b.addTest(.{ .root_module = application_mod });
    const run_application_tests = b.addRunArtifact(application_tests);

    const adapters_mod = b.addModule("mami_sound_adapters", .{
        .root_source_file = b.path("src/adapters_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const adapters_tests = b.addTest(.{ .root_module = adapters_mod });
    const run_adapters_tests = b.addRunArtifact(adapters_tests);

    const cli_mod = b.addModule("mami_sound_cli", .{
        .root_source_file = b.path("src/cli_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_tests = b.addTest(.{ .root_module = cli_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_application_tests.step);
    test_step.dependOn(&run_adapters_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    const adapter_test_step = b.step(
        "test-adapters",
        "Run adapter tests from the adapter root",
    );
    adapter_test_step.dependOn(&run_adapters_tests.step);
}
