const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

const serial = @import("serial.zig");

pub const SerialPortDescription = serial.SerialPortDescription;
pub const PortIterator = serial.PortIterator;

const log = std.log.scoped(.Connection);

pub const Error = error{
    NoConnection,
};

pub const Connection = @This();
port_name: [std.fs.MAX_PATH_BYTES]u8 = undefined,
fd: std.fs.File,
ctx: Context,

pub const list = serial.list;

pub fn open(port: SerialPortDescription) !Connection {
    log.info("Opening connection {s}", .{port.display_name});

    const fd = try std.fs.cwd().openFile(port.file_name, .{ .mode = .read_write });
    errdefer fd.close();

    var s: Connection = .{ .fd = fd, .ctx = .{} };

    @memset(s.port_name[0..], 0);
    @memcpy(s.port_name[0..port.display_name.len], port.display_name);

    try serial.configureSerialPort(fd, serial.SerialConfig{
        .baud_rate = 9600,
        .word_size = 8,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    return s;
}

pub fn close(self: *Connection) void {
    self.ctx.active = false;
    while (self.ctx.running) {}
    self.fd.close();
    self.* = undefined;
}

pub fn send(self: Connection, comptime T: type, data: []const T) !void {
    log.info("Sending {any}", .{data});

    const size = @sizeOf(T);

    for (data) |elem| {
        const bytes: [size]u8 = @bitCast(elem);
        inline for (0..size) |i| {
            const j = comptime switch (native_endian) {
                .Little => i,
                .Big => size - i - 1,
            };
            try self.fd.writer().writeByte(bytes[j]);
        }
    }
}

pub fn sendByte(self: Connection, data: u8) !void {
    log.info("Sending {any}", .{data});
    try self.fd.writer().writeByte(data);
}

pub fn startReceive(self: *Connection, comptime D: type, sink: anytype) !void {
    log.info("Starting reception", .{});

    self.ctx.active = false;
    while (self.ctx.running) {}

    self.ctx.active = true;

    const t = try std.Thread.spawn(.{}, Receiver(D).receive, .{ self.fd, &self.ctx, sink });
    t.detach();
}

pub fn stopReceive(self: *Connection) void {
    log.info("Stoping reception", .{});
    self.ctx.active = false;
}

const Context = struct {
    active: bool = false,
    running: bool = false,
};

pub const ReceiverAction = enum { Continue, Stop };

fn Receiver(comptime D: type) type {
    return struct {
        pub fn receive(fd: std.fs.File, ctx: *Context, sink: anytype) void {
            log.info("Entering receiver thread {}", .{ctx.active});

            ctx.running = true;
            defer ctx.running = false;

            const size = @sizeOf(D);

            var buf: [size]u8 = undefined;
            var i: usize = 0;

            var s = sink;

            while (ctx.active) {
                const b = fd.reader().readByte() catch |e| {
                    log.err("Error at receiver thread {any}", .{e});
                    continue;
                };
                const j = switch (native_endian) {
                    .Little => i,
                    .Big => size - i - 1,
                };
                buf[j] = b;

                i += 1;
                if (i == size) {
                    const action = s.put(@bitCast(buf)) catch |e| {
                        log.err("Error at receiver thread {any}", .{e});
                        continue;
                    };
                    if (action == .Stop) {
                        return;
                    }
                    i = 0;
                }
            }

            log.info("Leaving receiver thread", .{});
        }
    };
}
