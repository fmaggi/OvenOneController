const std = @import("std");
const zgui = @import("zgui");

pub const ModalArgs = struct {
    on_close: *const fn () anyerror!void = doNothing,
};

fn doNothing() !void {}

pub fn modal(
    label: [:0]const u8,
    comptime fmt: []const u8,
    args: anytype,
    modal_args: ModalArgs,
) !void {
    const flags: zgui.WindowFlags = .{ .no_resize = true };
    if (zgui.beginPopupModal(label, .{ .flags = flags })) {
        zgui.text(fmt, args);
        const w = zgui.calcTextSize("Ok", .{})[0] + xPadding();
        alignForWidth(w, 0.5);
        if (zgui.button("Ok", .{})) {
            try modal_args.on_close();
            zgui.closeCurrentPopup();
        }
        zgui.endPopup();
    }
}

pub fn alignForWidth(width: f32, alignment: f32) void {
    const avail = zgui.getContentRegionAvail()[0];
    const off = (avail - width) * alignment;
    if (off > 0.0) {
        zgui.setCursorPosX(zgui.getCursorPosX() + off);
    }
}

pub fn xPadding() f32 {
    const style = zgui.getStyle();
    return style.frame_padding[0] * 2;
}
