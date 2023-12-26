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

pub const list = serial.list;

pub fn open(port: SerialPortDescription) !Connection {
    log.debug("Opening connection {s}", .{port.display_name});

    const fd = try std.fs.cwd().openFile(port.file_name, .{ .mode = .read_write });
    errdefer fd.close();

    var s: Connection = .{ .fd = fd };

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

pub fn close(self: *Connection) void {
    log.debug("Closing connection", .{});
    self.fd.close();
    self.* = undefined;
}

pub fn send(self: Connection, data: anytype) !void {
    const T = @TypeOf(data);

    switch (@typeInfo(T)) {
        .Pointer => |p| return if (p.size == .Slice)
            self.sendSlice(p.child, data)
        else
            @compileError("Invalid type " ++ @typeName(T)),
        .Array => |a| return self.sendSlice(a.child, &data),
        .Int => return self.sendSingle(T, data),
        else => @compileError("Invalid type " ++ @typeName(T)),
    }
}

fn sendSlice(self: Connection, comptime T: type, data: []const T) !void {
    log.debug("[slice] {any}", .{data});
    for (data) |elem| {
        try sendSingle(self, T, elem);
    }
}

fn sendSingle(self: Connection, comptime T: type, data: T) !void {
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

pub fn startReceive(self: Connection, comptime D: type, sink: anytype) !void {
    log.debug("Starting reception", .{});
    const t = try std.Thread.spawn(.{}, receive, .{ D, self.fd, sink });
    t.detach();
}

pub const ReceiverAction = enum { Continue, Stop };

fn receive(comptime D: type, fd: std.fs.File, sink: anytype) void {
    log.debug("Entering receiving thread", .{});
    defer log.debug("Leaving receiving thread", .{});
    const size = @sizeOf(D);

    var buf: [size]u8 = undefined;
    var i: usize = 0;

    var s = sink;
    var action: ReceiverAction = .Continue;

    while (action == .Continue) {
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
            action = s.put(@bitCast(buf)) catch |e| {
                log.err("Error at receiver thread {any}", .{e});
                continue;
            };
            i = 0;
        }
    }
}
