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

    if (target.isWindows()) {
        exe.want_lto = false;
    }

    const controller = b.createModule(.{
        .source_file = .{ .path = "core/src/controller.zig" },
    });

    exe.addModule("OvenController", controller);

    @import("gui/build.zig").linkLibs(exe);

    const triple = target.zigTriple(b.allocator) catch "unknown";
    const optimize_str = switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };

    const dir = b.fmt("{s}/{s}", .{ triple, optimize_str });

    const artifact = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = dir } } });

    b.getInstallStep().dependOn(&artifact.step);

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
