const std = @import("std");
const mode = @import("builtin").mode;

pub const Error = error{
    NoConnection,
    AlreadyRunning,
};

const CurvePoints = 500;

const log = std.log.scoped(.Controller);

pub const Commands = struct {
    pub const Talk: u8 = 0xAA;
    pub const Curve: u8 = 0xCC;
    pub const PIDGet: u8 = 0xDD;
    pub const PIDSet: u8 = 0xDE;
    pub const Start: u8 = 0xFF;
    pub const Stop: u8 = 0xFE;
};

pub const list = serial.list;

const Controller = @This();
port_name: [std.fs.MAX_PATH_BYTES]u8 = undefined,
fd: std.fs.File,
ctx: SinkContext = .{},

pub fn connect(port: Controller.SerialPortDescription) !Controller {
    log.debug("Opening connection {s}", .{port.display_name});

    const fd = try std.fs.cwd().openFile(port.file_name, .{ .mode = .read_write });
    errdefer fd.close();

    var s: Controller = .{ .fd = fd };

    @memset(s.port_name[0..], 0);
    @memcpy(s.port_name[0..port.display_name.len], port.file_name);

    try serial.configureSerialPort(fd, serial.SerialConfig{
        .baud_rate = 9600,
        .word_size = 8,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    return s;
}

pub fn disconnect(self: *Controller) void {
    log.debug("Closing connection", .{});
    self.stopReceptionAndWait() catch {};
    self.fd.close();
    self.* = undefined;
}

pub fn startMonitor(self: *Controller, curve_index: u8, actual: *TemperatureCurve, expected: *TemperatureCurve) !void {
    log.debug("Starting monitor", .{});
    try self.send(Commands.Start);
    try self.send(curve_index);

    const Monitor = struct {
        const Self = @This();

        const HEADER: u16 = 0xAAAA;
        const ENDING: u16 = 0xABAB;

        const State = enum { header, time, temp0, temp1 };

        actual: *TemperatureCurve,
        expected: *TemperatureCurve,
        state: State = .header,
        time: u16 = 0,

        pub fn put(s: *Self, data: u16) !Controller.ReceiverAction {
            if (data == Self.ENDING) {
                return .Stop;
            }

            switch (s.state) {
                .header => {
                    if (data == Self.HEADER) {
                        log.debug("Header", .{});
                        s.state = .time;
                    }
                },
                .time => {
                    s.time = data;
                    s.state = .temp0;
                },
                .temp0 => {
                    log.debug("{} {}", .{ s.time, data });
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

    const mon: Monitor = .{ .actual = actual, .expected = expected };
    try self.startReceive(u16, mon);
}

pub fn isReceiving(self: Controller) bool {
    return self.ctx.running;
}

pub fn stopReception(self: *Controller) !void {
    log.debug("stoping reception", .{});
    if (!self.ctx.running) return;
    try self.send(Commands.Stop);
    self.ctx.active = false;
}

pub fn stopReceptionAndWait(self: *Controller) !void {
    try self.stopReception();
    while (self.ctx.running) {}
}

pub fn getPID(self: *Controller, pid: *PID) !void {
    log.debug("getting PID", .{});
    try self.send(Commands.PIDGet);

    const Getter = struct {
        const Self = @This();

        const State = enum { P, I, D };

        pid: *PID,
        state: State = .P,

        pub fn put(g: *Self, data: u32) !Controller.ReceiverAction {
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

    const getter: Getter = .{ .pid = pid };

    try self.startReceive(u32, getter);
}

pub fn sendPID(self: Controller, pid: PID) !void {
    log.debug("Sending PID", .{});
    if (comptime mode == .Debug) {
        pid.format(std.io.getStdOut().writer(), 10000) catch {};
        log.debug("Done", .{});
    }

    try self.send(Commands.PIDSet);

    try self.send(pid.p);
    try self.send(pid.i);
    try self.send(pid.d);
}

pub fn sendCurve(self: Controller, curve_index: u8, curve: *const TemperatureCurve) !void {
    log.debug("sending curve {}", .{curve_index});

    var points: [CurvePoints]u16 = undefined;
    try curve.getSamples(&points);

    try self.send(Commands.Curve);
    try self.send(curve_index);
    try self.send(points);
}

pub fn send(self: Controller, data: anytype) !void {
    const T = @TypeOf(data);

    switch (@typeInfo(T)) {
        .Pointer => |p| return if (p.size == .Slice)
            try self.sendSlice(p.child, data)
        else
            @compileError("Invalid type " ++ @typeName(T)),
        .Array => |a| return try self.sendSlice(a.child, &data),
        .Int => return try self.sendSingle(T, data),
        else => @compileError("Invalid type " ++ @typeName(T)),
    }
}

fn sendSlice(self: Controller, comptime T: type, data: []const T) !void {
    log.debug("[slice] {any}", .{data});
    for (data) |elem| {
        try sendSingle(self, T, elem);
    }
}

fn sendSingle(self: Controller, comptime T: type, data: T) !void {
    log.debug("[single] {any} {}", .{ @typeName(T), data });
    const size = @sizeOf(T);
    switch (size) {
        0 => return,
        1 => try self.fd.writer().writeByte(@bitCast(data)),
        else => {
            const bytes: [size]u8 = @bitCast(data);
            inline for (0..size) |i| {
                const j = comptime switch (native_endian) {
                    .Little => i,
                    .Big => size - i - 1,
                };
                try self.fd.writer().writeByte(bytes[j]);
            }
        },
    }
}

pub fn startReceive(self: *Controller, comptime D: type, sink: anytype) !void {
    log.debug("Starting reception", .{});
    if (self.ctx.running) return Error.AlreadyRunning;

    try serial.flushSerialPort(self.fd, true, false);

    self.ctx.active = true;

    const t = try std.Thread.spawn(.{}, receive, .{ D, self.fd, sink, &self.ctx });
    t.detach();
}

const ReceiverAction = enum { Continue, Stop };

const SinkContext = struct {
    running: bool = false,
    active: bool = false,
};

fn receive(comptime D: type, fd: std.fs.File, sink: anytype) void {
    receiveImpl(D, fd, sink) catch |e| {
        log.err("Error at receiving thread {s}", .{@errorName(e)});
    };
}

fn receiveImpl(comptime D: type, fd: std.fs.File, sink: anytype, ctx: *SinkContext) !void {
    ctx.running = true;
    defer ctx.running = false;

    log.debug("Entering receiving thread", .{});
    defer log.debug("Leaving receiving thread", .{});

    const size = @sizeOf(D);

    var buf: [size]u8 = undefined;
    var i: usize = 0;

    var s = sink;
    var action: ReceiverAction = .Continue;

    while (action == .Continue and sink.ctx.active) {
        const ba = try serial.bytesAvailable(fd);
        if (ba == 0) {
            std.time.sleep(100);
            continue;
        }

        const b = try fd.reader().readByte();
        const j = switch (native_endian) {
            .Little => i,
            .Big => size - i - 1,
        };
        buf[j] = b;

        i += 1;
        if (i == size) {
            action = try s.put(@bitCast(buf));
            i = 0;
        }
    }
}

pub const TemperatureCurve = @import("curve.zig");

const native_endian = @import("builtin").target.cpu.arch.endian();

const serial = @import("serial.zig");
pub const SerialPortDescription = serial.SerialPortDescription;
pub const PortIterator = serial.PortIterator;

pub const PID = struct {
    const SHIFT = 16;
    const SCALE = 1 << SHIFT;
    const MASK = SCALE - 1;

    p: u32 = 0,
    i: u32 = 0,
    d: u32 = 0,

    pub fn fromFloat(values: [3]f32) PID {
        return .{
            .p = @intFromFloat(values[0] * PID.SCALE),
            .i = @intFromFloat(values[1] * PID.SCALE),
            .d = @intFromFloat(values[2] * PID.SCALE),
        };
    }

    pub fn toFloat(pid: PID) [3]f32 {
        var buf: [3]f32 = undefined;

        buf[0] = @floatFromInt(pid.p);
        buf[1] = @floatFromInt(pid.i);
        buf[2] = @floatFromInt(pid.d);

        buf[0] /= PID.SCALE;
        buf[1] /= PID.SCALE;
        buf[2] /= PID.SCALE;

        return buf;
    }

    pub fn format(pid: PID, writer: anytype, precision: u32) !void {
        const pd = PID.decimal(pid.p);
        const pf = PID.frac(pid.p, precision);
        const id = PID.decimal(pid.i);
        const ifr = PID.frac(pid.i, precision);
        const dd = PID.decimal(pid.d);
        const df = PID.frac(pid.d, precision);

        const fts = pid.toFloat();

        if (fts[1] < 0.1) {
            try std.fmt.format(writer, "P={}.{}, I={}.0{}, D={}.{}\n", .{
                pd, pf,
                id, ifr,
                dd, df,
            });
        } else {
            try std.fmt.format(writer, "P={}.{}, I={}.{}, D={}.{}\n", .{
                pd, pf,
                id, ifr,
                dd, df,
            });
        }
    }

    fn decimal(n: u32) u32 {
        return n >> PID.SHIFT;
    }

    fn frac(n: u32, precision: u32) u32 {
        const f = (n & PID.MASK) * precision;
        return f >> PID.SHIFT;
    }
};
