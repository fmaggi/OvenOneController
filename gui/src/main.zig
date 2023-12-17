const std = @import("std");

const App = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer app.deinit();

    try app.run();
}
