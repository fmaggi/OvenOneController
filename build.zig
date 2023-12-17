const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "gui-controller",
        .root_source_file = .{ .path = "gui/src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const controller = b.createModule(.{
        .source_file = .{ .path = "core/src/controller.zig" },
    });

    // const cli_op = b.option(bool, "cli", "Build a cli app");
    //
    // const cli = cli_op orelse false;
    //
    // const exe = switch (cli) {
    //     false => @import("gui/build.zig").getExe(b, target, optimize),
    //     true => {
    //         std.debug.print("Build not supported yet");
    //         return;
    //     },
    // };

    exe.addModule("OvenController", controller);

    @import("gui/build.zig").linkLibs(exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "core/src/controller.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
