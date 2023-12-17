const std = @import("std");

const MAX_GRAD = 1;

pub const Error = error{
    NotEnoughPoints,
    GradientTooHigh,
    BadCurve,
};

const TemperatureCurve = @This();
time: std.ArrayList(u16),
temperature: std.ArrayList(u16),

pub fn init(allocator: std.mem.Allocator) TemperatureCurve {
    return .{
        .time = std.ArrayList(u16).init(allocator),
        .temperature = std.ArrayList(u16).init(allocator),
    };
}

pub fn deinit(self: TemperatureCurve) void {
    self.time.deinit();
    self.temperature.deinit();
}

pub fn reset(self: *TemperatureCurve) void {
    self.time.clearRetainingCapacity();
    self.temperature.clearRetainingCapacity();
}

pub fn addPoint(self: *TemperatureCurve, time: u16, temperature: u16) !void {
    try self.time.append(time);
    try self.temperature.append(temperature);
}

pub fn removePoint(self: *TemperatureCurve, i: usize) void {
    _ = self.time.orderedRemove(i);
    _ = self.temperature.orderedRemove(i);
}

pub fn ready(self: TemperatureCurve) bool {
    return self.time.items.len > 0 and self.temperature.items.len == self.time.items.len;
}

pub fn ensureReady(self: TemperatureCurve) void {
    while (!self.ready()) {}
}

pub fn ensureSameSize(self: TemperatureCurve) void {
    while (self.temperature.items.len != self.time.items.len) {}
}

pub fn getSamples(self: TemperatureCurve, buf: []u16) !void {
    if (buf.len < 2) {
        return Error.NotEnoughPoints;
    }

    if (!self.ready()) {
        return Error.NotEnoughPoints;
    }

    if (self.time.items.len < 2) {
        return Error.NotEnoughPoints;
    }

    var it = self.iterator();
    var start = it.next().?;

    for (0..start.time) |i| {
        buf[i] = start.temperature;
    }

    while (it.next()) |end| {
        defer start = end;

        const start_time: f32 = @floatFromInt(start.time);
        const end_time: f32 = @floatFromInt(end.time);

        const start_temp: f32 = @floatFromInt(start.temperature);
        const end_temp: f32 = @floatFromInt(end.temperature);

        const start_index: usize = @intCast(start.time);
        const end_index: usize = @intCast(end.time);

        if (start_index >= end_index) {
            return Error.BadCurve;
        }

        try sample(buf[start_index..end_index], start_time, start_temp, end_time, end_temp);
    }

    for (start.time..buf.len) |i| {
        buf[i] = start.temperature;
    }
}

pub fn iterator(self: TemperatureCurve) CurveIterator {
    return CurveIterator.init(self);
}

pub const CurveIterator = struct {
    const Self = @This();

    pub const Point = struct {
        time: u16,
        temperature: u16,
    };

    curve: TemperatureCurve,
    index: usize = 0,

    pub fn init(curve: TemperatureCurve) Self {
        return .{ .curve = curve };
    }

    pub fn next(self: *Self) ?Point {
        while (true) {
            if (self.index < self.curve.time.items.len) {
                const i = self.index;
                self.index += 1;

                return .{
                    .time = self.curve.time.items[i],
                    .temperature = self.curve.temperature.items[i],
                };
            } else {
                return null;
            }
        }
        return null;
    }
};

fn sample(buf: []u16, s_time: f32, s_temp: f32, e_time: f32, e_temp: f32) !void {
    const grad = (e_temp - s_temp) / (e_time - s_time);
    if (grad > MAX_GRAD) {
        return Error.GradientTooHigh;
    }

    var temp = s_temp;

    for (0..buf.len) |i| {
        buf[i] = @intFromFloat(temp);
        temp += grad;
    }
}
