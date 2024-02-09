const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // steps:
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    // options:
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // dependencies:

    const args_dep = b.dependency("args", .{});

    // modules:
    const args_mod = args_dep.module("args");

    // waveform executable:
    const exe = b.addExecutable(.{
        .name = "waveform",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("args", args_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Unit tests:

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
