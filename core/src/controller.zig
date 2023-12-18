const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Connection = @import("connection.zig");
pub const TemperatureCurve = @import("curve.zig");

const CurvePoints = 500;

const log = std.log.scoped(.Controller);

pub const PID = struct {
    p: u32 = 0,
    i: u32 = 0,
    d: u32 = 0,
};

pub const Commands = struct {
    pub const Talk = 0xAA;
    pub const Curve = 0xCC;
    pub const PIDGet = 0xDD;
    pub const PIDSet = 0xDE;
    pub const Start = 0xFF;
    pub const Stop = 0xFE;
};

const Oven = @This();
curve: TemperatureCurve,
expected_curve: TemperatureCurve,
pid: PID = .{},
connection: ?Connection = null,

pub fn init(allocator: std.mem.Allocator) Oven {
    return .{
        .curve = TemperatureCurve.init(allocator),
        .expected_curve = TemperatureCurve.init(allocator),
    };
}

pub fn deinit(self: *Oven) void {
    self.disconnect();
    self.curve.deinit();
}

pub fn connect(self: *Oven, port: Connection.SerialPortDescription) !void {
    const con = try Connection.open(port);
    try con.sendByte(Commands.Talk);
    self.connection = con;
}

pub fn disconnect(self: *Oven) void {
    if (self.connection) |*con| {
        con.close();
    }
    self.connection = null;
    self.curve.reset();
    self.expected_curve.reset();
}

pub fn send(self: Oven, comptime T: type, data: []T) !void {
    const con = self.connection orelse return Connection.Error.NoConnection;

    try con.send(T, data);
}

pub fn sendSingle(self: Oven, comptime T: type, data: T) !void {
    const con = self.connection orelse return Connection.Error.NoConnection;

    const buf = [_]T{data};
    try con.send(T, &buf);
}

pub fn startMonitor(self: *Oven, curve_index: u8) !void {
    var con = self.connection orelse return Connection.Error.NoConnection;

    try con.sendByte(Commands.Start);
    try con.sendByte(curve_index);

    const Monitor = struct {
        const Self = @This();

        const State = enum { time0, temp0, time1, temp1 };

        actual: *TemperatureCurve,
        expected: *TemperatureCurve,
        state: State = .time0,
        time: u16 = 0,

        pub fn put(s: *Self, data: u16) !Connection.ReceiverAction {
            switch (s.state) {
                .time0 => {
                    s.time = data;
                    s.state = .temp0;
                },
                .temp0 => {
                    try s.actual.addPoint(s.time, data);
                    s.state = .time1;
                },
                .time1 => {
                    s.time = data;
                    s.state = .temp1;
                },
                .temp1 => {
                    try s.expected.addPoint(s.time, data);
                    s.state = .time0;
                },
            }

            return .Continue;
        }
    };

    const mon: Monitor = .{ .actual = &self.curve, .expected = &self.expected_curve };

    try con.startReceive(u16, mon);
}

pub fn stopMonitor(self: *Oven) !void {
    self.curve.reset();
    self.expected_curve.reset();

    if (self.connection) |*con| {
        con.stopReceive();
        try con.sendByte(Commands.Stop);
    }
}

pub fn getPID(self: *Oven) !void {
    var con = self.connection orelse return Connection.Error.NoConnection;

    try con.sendByte(Commands.PIDGet);

    const Getter = struct {
        const Self = @This();

        const State = enum { P, I, D, DONE };

        pid: *PID,
        state: State = .P,

        pub fn put(g: *Self, data: u32) !Connection.ReceiverAction {
            log.debug("PID got {}", .{data});
            switch (g.state) {
                .P => {
                    g.pid.p = data;
                    g.state = .I;
                },
                .I => {
                    g.pid.i = data;
                    g.state = .D;
                },
                .D => {
                    g.pid.d = data;
                    g.state = .DONE;
                },
                .DONE => {
                    return .Stop;
                },
            }
            return .Continue;
        }
    };

    const getter: Getter = .{ .pid = &self.pid };

    try con.startReceive(u32, getter);
}

pub fn sendPID(self: Oven) !void {
    const con = self.connection orelse return Connection.Error.NoConnection;

    try con.sendByte(Commands.PIDSet);

    const buf = [_]u32{ self.pid.p, self.pid.i, self.pid.d };
    try con.send(u32, &buf);
}

pub fn sendCurve(self: Oven, curve_index: u8) !void {
    const con = self.connection orelse return Connection.Error.NoConnection;

    var points: [CurvePoints]u16 = undefined;
    try self.curve.getSamples(&points);

    try con.sendByte(Commands.Curve);
    try con.sendByte(curve_index);
    try con.send(u16, &points);
}
