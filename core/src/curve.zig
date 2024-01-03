const std = @import("std");

const CURVE_LENGTH = 50;

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

pub fn len(self: TemperatureCurve) usize {
    return if (self.time.items.len < self.temperature.items.len)
        self.time.items.len
    else
        self.temperature.items.len;
}

pub fn clear(self: *TemperatureCurve) void {
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
        if (self.index >= self.curve.len()) {
            return null;
        }

        const i = self.index;
        self.index += 1;

        return .{
            .time = self.curve.time.items[i],
            .temperature = self.curve.temperature.items[i],
        };
    }

    pub fn complete(self: *Self) ?Point {
        if (self.index >= CURVE_LENGTH) {
            return null;
        }

        if (self.next()) |p| {
            return p;
        }

        self.index += 1;

        const i = self.curve.len() - 1;
        return .{
            .time = self.curve.time.items[i],
            .temperature = self.curve.temperature.items[i],
        };
    }
};
