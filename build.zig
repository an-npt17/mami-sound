const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plant_mod = b.createModule(.{
        .root_source_file = b.path("src/plant.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ui = b.addExecutable(.{
        .name = "sensor-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plant", .module = plant_mod },
            },
        }),
    });
    b.installArtifact(ui);

    const pi = b.addExecutable(.{
        .name = "sensor-pi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pi/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plant", .module = plant_mod },
            },
        }),
    });
    b.installArtifact(pi);

    const run_ui = b.addRunArtifact(ui);
    run_ui.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_ui.addArgs(args);
    const run_ui_step = b.step("run-ui", "Run sensor-ui");
    run_ui_step.dependOn(&run_ui.step);

    const run_pi = b.addRunArtifact(pi);
    run_pi.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_pi.addArgs(args);
    const run_pi_step = b.step("run-pi", "Run sensor-pi");
    run_pi_step.dependOn(&run_pi.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plant", .module = plant_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    if (b.args) |args| run_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const lib_sources = [_][]const u8{
        "src/sensor.zig",
        "src/synth.zig",
        "src/net.zig",
        "src/voices.zig",
        "src/track.zig",
    };
    for (lib_sources) |src| {
        const lib_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_lib_tests = b.addRunArtifact(lib_tests);
        test_step.dependOn(&run_lib_tests.step);
    }
}
