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
    pub const Talk: u8 = 0xAA;
    pub const CurveSet: u8 = 0xCC;
    pub const CurveGet: u8 = 0xCE;
    pub const PIDGet: u8 = 0xDD;
    pub const PIDSet: u8 = 0xDE;
    pub const Start: u8 = 0xFF;
    pub const Stop: u8 = 0xFE;
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
    self.expected_curve.deinit();
}

pub fn connect(self: *Oven, port: Connection.SerialPortDescription) !void {
    const con = try Connection.open(port);
    try con.send(Commands.Talk);
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

pub fn send(self: Oven, data: anytype) !void {
    const con = self.connection orelse return Connection.Error.NoConnection;
    try con.send(data);
}

pub fn startMonitor(self: *Oven, curve_index: u8) !void {
    log.debug("Starting monitor", .{});
    var con = self.connection orelse return Connection.Error.NoConnection;
    try con.send(Commands.Start);
    try con.send(curve_index);

    const Monitor = struct {
        const Self = @This();

        const HEADER: u16 = 0xAAAA;
        const ENDING: u16 = 0xABAB;

        const State = enum { header, time, temp0, temp1 };

        actual: *TemperatureCurve,
        expected: *TemperatureCurve,
        state: State = .header,
        time: u16 = 0,

        pub fn put(s: *Self, data: u16) !Connection.ReceiverAction {
            log.debug("got {}, {}", .{ data, s.state });
            if (data == Self.ENDING) {
                return .Stop;
            }

            switch (s.state) {
                .header => {
                    if (data == Self.HEADER) {
                        s.state = .time;
                    }
                },
                .time => {
                    s.time = data;
                    s.state = .temp0;
                },
                .temp0 => {
                    try s.actual.addPoint(s.time, data);
                    s.state = .temp1;
                },
                .temp1 => {
                    try s.expected.addPoint(s.time, data);
                    s.state = .header;
                },
            }

            return .Continue;
        }
    };

    const mon: Monitor = .{ .actual = &self.curve, .expected = &self.expected_curve };

    try con.startReceive(u16, mon);
}

pub fn stopMonitor(self: *Oven) !void {
    log.debug("stoping monitor", .{});
    self.curve.reset();
    self.expected_curve.reset();

    if (self.connection) |*con| {
        try con.send(Commands.Stop);
    }
}

pub fn getPID(self: *Oven) !void {
    log.debug("getting PID", .{});
    var con = self.connection orelse return Connection.Error.NoConnection;
    try con.send(Commands.PIDGet);

    const Getter = struct {
        const Self = @This();

        const State = enum { P, I, D };

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
    log.debug("sending PID", .{});
    const con = self.connection orelse return Connection.Error.NoConnection;

    try con.send(Commands.PIDSet);

    try con.send(self.pid.p);
    try con.send(self.pid.i);
    try con.send(self.pid.d);
}

pub fn getCurve(self: *Oven, curve_index: u8) !void {
    log.debug("getting curve {}", .{curve_index});
    var con = self.connection orelse return Connection.Error.NoConnection;
    try con.send(Commands.CurveGet);
    try con.send(curve_index);

    const CurveGetter = struct {
        const Self = @This();

        const HEADER: u16 = 0xAAAA;
        const ENDING: u16 = 0xABAB;

        const State = enum { header, time, temp };

        curve: *TemperatureCurve,
        state: State = .header,
        time: u16 = 0,

        pub fn put(s: *Self, data: u16) !Connection.ReceiverAction {
            log.debug("got {}, {}", .{ data, s.state });
            if (data == Self.ENDING) {
                return .Stop;
            }

            switch (s.state) {
                .header => {
                    if (data == Self.HEADER) {
                        s.state = .time;
                    }
                },
                .time => {
                    s.time = data;
                    s.state = .temp0;
                },
                .temp => {
                    try s.curve.addPoint(s.time, data);
                    s.state = .header;
                },
            }

            return .Continue;
        }
    };

    const getter: CurveGetter = .{ .curve = &self.curve };

    try con.startReceive(u16, getter);
}

pub fn sendCurve(self: Oven, curve_index: u8) !void {
    log.debug("sending curve {}", .{curve_index});
    const con = self.connection orelse return Connection.Error.NoConnection;

    var points: [CurvePoints]u16 = undefined;
    try self.curve.getSamples(&points);

    try con.send(Commands.CurveSet);
    try con.send(curve_index);
    try con.send(points);
}
