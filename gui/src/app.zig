const std = @import("std");
const math = std.math;

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");

const Oven = @import("OvenController");

const widgets = @import("widgets.zig");

const roboto_font = @embedFile("Roboto-Medium.ttf");

const ActiveLayer = enum { curve_maker, monitor, pid_editor, testing };

const App = @This();
allocator: std.mem.Allocator,
gctx: *zgpu.GraphicsContext,
window: *zglfw.Window,
draw_list: zgui.DrawList,
font: zgui.Font,
active: ActiveLayer = .curve_maker,
is_open: bool = true,
oven: Oven,

pub fn init(allocator: std.mem.Allocator) !App {
    zglfw.init() catch |e| {
        std.log.err("Failed to initialize GLFW library.", .{});
        return e;
    };
    errdefer zglfw.terminate();

    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.os.chdir(path) catch {};
    }

    const window = zglfw.Window.create(1600, 1000, "Test", null) catch |e| {
        std.log.err("Failed to create demo window.", .{});
        return e;
    };
    errdefer window.destroy();

    window.setSizeLimits(400, 400, -1, -1);
    const gctx = try zgpu.GraphicsContext.create(allocator, window, .{});
    errdefer gctx.destroy(allocator);

    zgui.init(allocator);
    zgui.plot.init();
    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    const font_size = 16.0 * scale_factor;
    const font = zgui.io.addFontFromMemory(roboto_font, math.floor(font_size * 1.1));
    std.debug.assert(zgui.io.getFont(0) == font);

    // This needs to be called *after* adding your custom fonts.
    zgui.backend.initWithConfig(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        .{ .texture_filter_mode = .linear, .pipeline_multisample_count = 1 },
    );

    zgui.io.setDefaultFont(font);

    {
        zgui.plot.getStyle().line_weight = 3.0;
        const plot_style = zgui.plot.getStyle();
        plot_style.marker = .circle;
        plot_style.marker_size = 5.0;
    }

    const draw_list = zgui.createDrawList();

    setStyle();

    return .{
        .allocator = allocator,
        .gctx = gctx,
        .window = window,
        .draw_list = draw_list,
        .font = font,
        .oven = Oven.init(allocator),
    };
}

pub fn deinit(self: *App) void {
    zgui.backend.deinit();
    zgui.plot.deinit();
    zgui.destroyDrawList(self.draw_list);
    zgui.deinit();
    self.gctx.destroy(self.allocator);
    self.window.destroy();
    zglfw.terminate();
    self.oven.deinit();
}

pub fn run(self: *App) !void {
    while (!self.window.shouldClose() and self.is_open) {
        zglfw.pollEvents();
        try self.update();
        self.draw();
    }
}

pub fn update(self: *App) !void {
    zgui.backend.newFrame(
        self.gctx.swapchain_descriptor.width,
        self.gctx.swapchain_descriptor.height,
    );

    widgets.modal("ZeroSizePopup", "La curva esta vacia!", .{});
    widgets.modal("BadCurvePopup", "Curva invalida!", .{});
    widgets.modal("GradTooHighPopup", "La pendiente de la curva es demasiado alta", .{});
    widgets.modal("NoConnectionPopup", "Conexion inexistente", .{});
    widgets.modal("SuccessPopup", "Un exito!", .{});

    self.mainWindow() catch |e| {
        std.debug.print("{any}\n", .{e});
        switch (e) {
            Oven.TemperatureCurve.Error.NotEnoughPoints => zgui.openPopup("ZeroSizePopup", .{}),
            Oven.TemperatureCurve.Error.BadCurve => zgui.openPopup("BadCurvePopup", .{}),
            Oven.TemperatureCurve.Error.GradientTooHigh => zgui.openPopup("GradTooHighPopup", .{}),
            Oven.Connection.Error.NoConnection => zgui.openPopup("NoConnectionPopup", .{}),
            else => return e,
        }
        return;
    };
}

fn mainWindow(self: *App) !void {
    const viewport = zgui.getMainViewport();
    const pos = viewport.getWorkPos();
    const size = viewport.getWorkSize();
    zgui.setNextWindowPos(.{ .x = pos[0], .y = pos[1] });
    zgui.setNextWindowSize(.{ .w = size[0], .h = size[1] });

    const windowFlags: zgui.WindowFlags = .{
        .no_title_bar = true,
        .no_collapse = true,
        .no_resize = true,
        .no_move = true,
        .no_bring_to_front_on_focus = true,
        .no_nav_focus = true,
        .menu_bar = true,
    };

    _ = zgui.begin("Oven One Controller", .{ .popen = &self.is_open, .flags = windowFlags });
    defer zgui.end();
    const S = struct {
        var config_open: bool = false;
        var show_demo: bool = false;
    };

    if (zgui.beginMenuBar()) {
        if (self.oven.connection) |con| {
            if (zgui.beginMenu(@ptrCast(&con.port_name), true)) {
                if (zgui.menuItem("Modo programacion", .{})) {
                    try self.oven.sendSingle(u8, Oven.Commands.Talk);
                }

                if (zgui.menuItem("Modo normal", .{})) {
                    try self.oven.sendSingle(u8, Oven.Commands.Stop);
                }

                if (zgui.menuItem("Desconectar", .{})) {
                    self.oven.disconnect();
                }
                zgui.endMenu();
            }

            zgui.text("Conectado", .{});
        } else {
            var buf: [50]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            var it = try Oven.Connection.list();

            if (zgui.beginMenu("Puerto", true)) {
                while (try it.next()) |port| {
                    const pn = try fba.allocator().dupeZ(u8, port.display_name);
                    defer fba.reset();

                    if (zgui.menuItem(pn, .{})) {
                        try self.oven.connect(port);
                    }
                }
                zgui.endMenu();
            }

            zgui.text("Desconectado", .{});
        }

        if (zgui.beginMenu("Herramientas", true)) {
            if (zgui.menuItem("Crear curva", .{})) {
                if (self.active == .monitor) {
                    try self.oven.stopMonitor();
                }
                self.active = .curve_maker;
            }

            if (zgui.menuItem("Monitor", .{})) {
                if (self.active == .curve_maker) {
                    self.oven.curve.reset();
                }
                self.active = .monitor;
            }

            if (zgui.menuItem("Editor PID", .{})) {
                self.oven.getPID() catch {};
                self.active = .pid_editor;
                if (self.active == .curve_maker) {
                    self.oven.curve.reset();
                } else if (self.active == .monitor) {
                    try self.oven.stopMonitor();
                }
            }

            if (zgui.menuItem("Testing", .{})) {
                if (self.active == .curve_maker) {
                    self.oven.curve.reset();
                } else if (self.active == .monitor) {
                    try self.oven.stopMonitor();
                }
                self.active = .testing;
            }

            zgui.endMenu();
        }

        if (zgui.beginMenu("Configuracion", true)) {
            if (zgui.menuItem("Editar", .{})) {
                S.config_open = true;
            }

            if (zgui.menuItem("Mostrar demo", .{})) {
                S.show_demo = true;
            }
            zgui.endMenu();
        }

        zgui.endMenuBar();
    }

    const avail = zgui.getContentRegionAvail();
    if (self.active == .curve_maker) {
        if (try curveMaker(&self.oven.curve, avail[0], avail[1])) |index| {
            try self.oven.sendCurve(index);

            zgui.openPopup("SuccessPopup", .{});
        }
    } else if (self.active == .monitor) {
        if (monitor(&self.oven.curve, &self.oven.expected_curve, avail[0], avail[1])) |index| {
            try self.oven.startMonitor(index);
        }
    } else if (self.active == .pid_editor) {
        if (pidEditor(&self.oven.pid, avail[0], avail[1])) {
            try self.oven.sendPID();
        }
    } else if (self.active == .testing) {
        const Testing = struct {
            var char: u8 = 0;
            var hw: u16 = 0;
            var w: u32 = 0;
        };
        if (testing(&Testing.char, &Testing.hw, &Testing.w)) |index| {
            switch (index) {
                0 => {
                    try self.oven.sendSingle(u8, Testing.char);
                },
                1 => {
                    try self.oven.sendSingle(u16, Testing.hw);
                },
                2 => {
                    try self.oven.sendSingle(u32, Testing.w);
                },
                else => {},
            }
        }
    }

    if (S.config_open) {
        zgui.setNextWindowPos(.{ .x = pos[0] + 300, .y = pos[1] + 20, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 550, .h = 680, .cond = .first_use_ever });
        if (zgui.begin("Configuracion", .{ .popen = &S.config_open, .flags = .{} })) {}
        zgui.end();
    }

    if (S.show_demo) {
        zgui.showDemoWindow(&S.show_demo);
    }
}

pub fn draw(self: App) void {
    const gctx = self.gctx;

    const swapchain_texv = gctx.swapchain.getCurrentTextureView();
    defer swapchain_texv.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Gui pass.
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}

fn setStyle() void {
    var style = zgui.getStyle();
    style.window_padding = [2]f32{ 10, 10 };
    style.window_rounding = 0;
    style.window_border_size = 1;
    style.frame_padding = [2]f32{ 10, 5 };
    style.frame_rounding = 3;
    style.cell_padding = [2]f32{ 10, 5 };
    style.grab_rounding = 3;
}

fn curveMaker(curve: *Oven.TemperatureCurve, w: f32, h: f32) !?u8 {
    const plotSize = 0.8;
    var p = false;
    var index: usize = 0;

    {
        var to_delete: ?usize = null;
        _ = zgui.beginChild("table", .{ .w = w * (1 - plotSize), .h = h });
        defer zgui.endChild();

        try tablePoints(curve, &to_delete);

        if (to_delete) |i| {
            curve.removePoint(i);
        }

        zgui.setCursorPosY(h * 0.7);

        zgui.separatorText("Programacion");

        index = curveSelector();

        if (zgui.button("Programar", .{})) {
            p = true;
        }
    }

    zgui.sameLine(.{ .spacing = 10 });

    {
        _ = zgui.beginChild("grafico", .{ .w = w * plotSize, .h = h });
        defer zgui.endChild();

        plotSetup("Crear Curva", h, false);
        defer plotDone();

        plot("curva", curve);
    }

    const i: u8 = @truncate(index);
    return if (p) i else null;
}

fn monitor(actual: *const Oven.TemperatureCurve, expected: *const Oven.TemperatureCurve, w: f32, h: f32) ?u8 {
    actual.ensureSameSize();
    expected.ensureSameSize();

    const style = zgui.getStyle();
    const selectorSize = zgui.calcTextSize("AA", .{})[1] + style.frame_padding[1] * 3;
    var p = false;
    var index: usize = 0;

    {
        _ = zgui.beginChild("curveSelector", .{ .w = w * 0.2, .h = selectorSize });
        defer zgui.endChild();

        index = curveSelector();

        zgui.sameLine(.{});

        p = zgui.button("Empezar", .{});
    }

    {
        const ph = h - selectorSize - style.window_padding[1] * 2;
        _ = zgui.beginChild("grafico", .{ .w = w, .h = ph });
        defer zgui.endChild();

        plotSetup("Monitor", ph, true);
        defer plotDone();

        plot("Target", expected);
        plot("Temperatura", actual);
    }

    const i: u8 = @truncate(index);
    return if (p) i else null;
}

fn pidEditor(pid: *Oven.PID, w: f32, h: f32) bool {
    _ = w;
    _ = h;
    _ = zgui.inputScalar("P", u32, .{ .v = &pid.p });
    _ = zgui.inputScalar("I", u32, .{ .v = &pid.i });
    _ = zgui.inputScalar("D", u32, .{ .v = &pid.d });

    return zgui.button("Programar", .{});
}

fn testing(char: *u8, hw: *u16, w: *u32) ?u8 {
    var send: ?u8 = null;

    _ = zgui.inputScalar("u8     ", u8, .{ .v = char });
    zgui.sameLine(.{});
    if (zgui.button("Enviar##u8", .{})) {
        send = 0;
    }

    _ = zgui.inputScalar("u16   ", u16, .{ .v = hw });
    zgui.sameLine(.{});
    if (zgui.button("Enviar##u16", .{})) {
        send = 1;
    }

    _ = zgui.inputScalar("u32   ", u32, .{ .v = w });
    zgui.sameLine(.{});
    if (zgui.button("Enviar##u32", .{})) {
        send = 2;
    }

    return send;
}

const headers = .{ "Tiempo [s]", "Temperatura [°C]", "Opciones" };

fn tablePoints(curve: *Oven.TemperatureCurve, to_delete: *?usize) !void {
    {
        _ = zgui.beginTable("puntos", .{ .column = headers.len });
        defer zgui.endTable();

        const color = zgui.getStyle().getColor(.window_bg);

        inline for (headers) |header| {
            zgui.tableSetupColumn(header, .{});
        }
        zgui.tableHeadersRow();

        var buf: [15:0]u8 = undefined;
        for (curve.time.items, 0..) |_, index| {
            zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = color });

            _ = zgui.tableNextColumn();
            _ = try std.fmt.bufPrint(&buf, "##time-{}", .{index});
            var time: i32 = @intCast(curve.time.items[index]);
            _ = zgui.inputInt(&buf, .{ .v = &time, .step = 0 });
            curve.time.items[index] = @truncate(@as(u32, @intCast(time)));

            _ = zgui.tableNextColumn();
            _ = try std.fmt.bufPrint(&buf, "##temp-{}", .{index});
            var temp: i32 = @intCast(curve.temperature.items[index]);
            _ = zgui.inputInt(&buf, .{ .v = &temp, .step = 0 });
            curve.temperature.items[index] = @truncate(@as(u32, @intCast(temp)));

            zgui.popStyleColor(.{ .count = 1 });

            _ = zgui.tableNextColumn();
            _ = try std.fmt.bufPrint(&buf, "Eliminar##{}", .{index});
            if (zgui.button(&buf, .{})) {
                to_delete.* = index;
            }
        }
    }

    zgui.separator();

    const buttons = &.{"Agregar punto"};

    var w: f32 = 0;
    w += zgui.calcTextSize(buttons[0], .{})[0];
    w += widgets.xPadding();
    widgets.alignForWidth(w, 0.5);

    if (zgui.button(buttons[0], .{})) {
        try curve.addPoint(0, 0);
    }
}

fn plotSetup(label: [:0]const u8, h: f32, legend: bool) void {
    const flags: zgui.plot.Flags = .{ .no_legend = !legend };

    zgui.plot.pushStyleVar1f(.{ .idx = .marker_size, .v = 3.0 });
    zgui.plot.pushStyleVar1f(.{ .idx = .marker_weight, .v = 1.0 });
    defer zgui.plot.popStyleVar(.{ .count = 2 });

    _ = zgui.plot.beginPlot(label, .{ .h = h, .flags = flags });

    zgui.plot.setupAxis(.x1, .{ .label = headers[0] });
    zgui.plot.setupAxis(.y1, .{ .label = headers[1] });
    zgui.plot.setupAxisLimits(.x1, .{ .min = 0, .max = 300 });
    zgui.plot.setupAxisLimits(.y1, .{ .min = 0, .max = 300 });
    zgui.plot.setupFinish();
}

fn plotDone() void {
    zgui.plot.endPlot();
}

fn plotEditable(label: [:0]const u8, curve: *Oven.TemperatureCurve) void {
    if (zgui.plot.isHovered() and zgui.isMouseClicked(.left) and zgui.isKeyDown(.mod_ctrl)) {
        const pt = zgui.plot.getMousePos();
        if (pt[0] > 0 and pt[1] > 0) {
            curve.addPoint(@intFromFloat(pt[0]), @intFromFloat(pt[1])) catch {};
        }
    }

    zgui.plot.plotLine(label, u16, .{
        .xv = curve.time.items,
        .yv = curve.temperature.items,
    });
}

fn plot(label: [:0]const u8, curve: *const Oven.TemperatureCurve) void {
    zgui.plot.plotLine(label, u16, .{
        .xv = curve.time.items,
        .yv = curve.temperature.items,
    });
}

fn curveSelector() usize {
    const S = struct {
        var current: usize = 0;
    };

    const items = [_][:0]const u8{ "1", "2", "3" };
    var preview = items[S.current];

    if (zgui.beginCombo("Curva", .{ .preview_value = preview })) {
        for (items, 0..) |item, n| {
            const is_selected = (S.current == n);
            if (zgui.selectable(item, .{ .selected = is_selected }))
                S.current = n;

            // Set the initial focus when opening the combo (scrolling + keyboard navigation focus)
            if (is_selected)
                zgui.setItemDefaultFocus();
        }
        zgui.endCombo();
    }

    return S.current;
}

// fn config() void {
//         if (zgui.collapsingHeader("Style")) {
//         }
//
//
//     if (zgui.collapsingHeader("Window options"))
//     {
//         if (zgui.beginTable("split", .{ .column = 3 })) {
//             zgui.tableNextColumn(); zgui.checkbox("No titlebar", &no_titlebar);
//             zgui.tableNextColumn(); zgui.checkbox("No scrollbar", &no_scrollbar);
//             zgui.tableNextColumn(); zgui.checkbox("No menu", &no_menu);
//             zgui.tableNextColumn(); zgui.checkbox("No move", &no_move);
//             zgui.tableNextColumn(); zgui.checkbox("No resize", &no_resize);
//             zgui.tableNextColumn(); zgui.checkbox("No collapse", &no_collapse);
//             zgui.tableNextColumn(); zgui.checkbox("No close", &no_close);
//             zgui.tableNextColumn(); zgui.checkbox("No nav", &no_nav);
//             zgui.tableNextColumn(); zgui.checkbox("No background", &no_background);
//             zgui.tableNextColumn(); zgui.checkbox("No bring to front", &no_bring_to_front);
//             zgui.tableNextColumn(); zgui.checkbox("Unsaved document", &unsaved_document);
//             zgui.endTable();
//         }
//     }
//
//
// }
