const std = @import("std");

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

    time: []u16,
    temperature: []u16,
    len: usize,
    index: usize = 0,

    pub fn init(curve: TemperatureCurve) Self {
        return .{
            .time = curve.time.items,
            .temperature = curve.temperature.items,
            .len = curve.len(),
        };
    }

    pub fn next(self: *Self) ?Point {
        if (self.index >= self.len) {
            return null;
        }

        const i = self.index;
        self.index += 1;

        return .{
            .time = self.time[i],
            .temperature = self.temperature[i],
        };
    }
};
