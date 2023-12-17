const std = @import("std");

const zgui = @import("libs/zgui/build.zig");
const zglfw = @import("libs/zglfw/build.zig");
const zgpu = @import("libs/zgpu/build.zig");
const zpool = @import("libs/zpool/build.zig");

pub fn linkLibs(exe: *std.Build.Step.Compile) void {
    const b = exe.step.owner;
    const target = exe.target;
    const optimize = exe.optimize;

    const zgui_pkg = zgui.package(b, target, optimize, .{
        .options = .{ .backend = .glfw_wgpu },
    });

    zgui_pkg.link(exe);

    const zglfw_pkg = zglfw.package(b, target, optimize, .{});
    const zpool_pkg = zpool.package(b, target, optimize, .{});
    const zgpu_pkg = zgpu.package(b, target, optimize, .{
        .deps = .{ .zpool = zpool_pkg.zpool, .zglfw = zglfw_pkg.zglfw },
    });

    zglfw_pkg.link(exe);
    zgpu_pkg.link(exe);
}
