const std = @import("std");
const math = std.math;

const log = std.log.scoped(.App);

const Oven = @import("OvenController");

const widgets = @import("widgets.zig");

const ActiveLayer = enum { curve_maker, monitor, pid_editor };

const Error = error{Exit};

const App = @This();
graphics: Graphics,
active: ActiveLayer = .curve_maker,
curve0: Oven.TemperatureCurve,
curve1: Oven.TemperatureCurve,
pid: Oven.PID = .{},
is_open: bool = true,
oven: ?Oven = null,

pub fn init(allocator: std.mem.Allocator) !App {
    const graphics = try Graphics.create(allocator);

    setStyle();

    return .{
        .graphics = graphics,
        .curve0 = Oven.TemperatureCurve.init(allocator),
        .curve1 = Oven.TemperatureCurve.init(allocator),
    };
}

pub fn deinit(self: *App) void {
    self.graphics.destroy();
    if (self.oven) |*oven| {
        oven.disconnect();
    }
    self.curve0.deinit();
    self.curve1.deinit();
}

fn onUnknownError() !void {
    return Error.Exit;
}

pub fn run(self: *App) !void {
    while (!self.graphics.shouldClose() and self.is_open) {
        zglfw.pollEvents();
        try self.update();
        self.graphics.draw();
    }
}

pub fn update(self: *App) !void {
    self.graphics.newFrame();

    const S = struct {
        var err: [:0]const u8 = undefined;
    };

    try widgets.modal("ZeroSizePopup", "La curva esta vacia!", .{}, .{});
    try widgets.modal("BadCurvePopup", "Curva invalida!", .{}, .{});
    try widgets.modal("GradTooHighPopup", "La pendiente de la curva es demasiado alta", .{}, .{});
    try widgets.modal("NoConnectionPopup", "Conexion inexistente", .{}, .{});
    try widgets.modal("SuccessPopup", "Un exito!", .{}, .{});
    try widgets.modal("UnknownError", "Unknown Error: {s}", .{S.err}, .{ .on_close = onUnknownError });

    self.mainWindow() catch |e| {
        switch (e) {
            Oven.TemperatureCurve.Error.NotEnoughPoints => zgui.openPopup("ZeroSizePopup", .{}),
            Oven.TemperatureCurve.Error.BadCurve => zgui.openPopup("BadCurvePopup", .{}),
            Oven.TemperatureCurve.Error.GradientTooHigh => zgui.openPopup("GradTooHighPopup", .{}),
            Oven.Error.NoConnection => zgui.openPopup("NoConnectionPopup", .{}),
            else => {
                S.err = @errorName(e);
                zgui.openPopup("UnknownError", .{});
            },
        }
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
        var show_demo: bool = false;
    };

    if (zgui.beginMenuBar()) {
        defer zgui.endMenuBar();
        if (self.oven) |con| {
            if (zgui.beginMenu(@ptrCast(&con.port_name), true)) {
                defer zgui.endMenu();
                if (zgui.menuItem("Modo programacion", .{})) {
                    try con.send(Oven.Commands.Talk);
                }

                if (zgui.menuItem("Modo normal", .{})) {
                    try con.send(Oven.Commands.Stop);
                }

                if (zgui.menuItem("Desconectar", .{})) {
                    if (self.oven) |*oven| {
                        oven.disconnect();
                    }
                    self.oven = null;
                }
            }

            zgui.text("Conectado", .{});
        } else {
            var buf: [50]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            var it = try Oven.list();

            if (zgui.beginMenu("Puerto", true)) {
                defer zgui.endMenu();
                while (try it.next()) |port| {
                    const pn = try fba.allocator().dupeZ(u8, port.display_name);
                    defer fba.reset();

                    if (zgui.menuItem(pn, .{})) {
                        self.oven = try Oven.connect(port);
                    }
                }
            }

            zgui.text("Desconectado", .{});
        }

        if (zgui.beginMenu("Herramientas", true)) {
            defer zgui.endMenu();
            if (zgui.menuItem("Crear curva", .{})) {
                try self.changeState(.curve_maker);
            }

            if (zgui.menuItem("Monitor", .{})) {
                try self.changeState(.monitor);
            }

            if (zgui.menuItem("Editor PID", .{})) {
                try self.changeState(.pid_editor);
            }
        }

        if (zgui.beginMenu("Configuracion", true)) {
            defer zgui.endMenu();
            if (zgui.menuItem("Mostrar demo", .{})) {
                S.show_demo = true;
            }
        }
    }

    const avail = zgui.getContentRegionAvail();
    switch (self.active) {
        .curve_maker => try self.curveMaker(avail[0], avail[1]),
        .monitor => try self.monitor(avail[0], avail[1]),
        .pid_editor => try self.pidEditor(avail[0], avail[1]),
    }

    if (S.show_demo) {
        zgui.showDemoWindow(&S.show_demo);
    }
}

fn changeState(self: *App, to: ActiveLayer) !void {
    log.debug("changing state", .{});
    if (to == self.active) return;

    self.curve0.clear();
    self.curve1.clear();

    if (self.active == .monitor) {
        if (self.oven) |oven| {
            try oven.stopMonitor();
        }
    }

    if (to == .pid_editor) {
        if (self.oven) |oven| {
            oven.getPID(&self.pid) catch {};
        }
    }

    self.active = to;
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

fn curveMaker(self: *App, w: f32, h: f32) !void {
    const plotSize = 0.8;

    {
        _ = zgui.beginChild("table", .{ .w = w * (1 - plotSize), .h = h });
        defer zgui.endChild();

        const to_delete = try tablePoints(&self.curve0);

        if (to_delete) |i| {
            self.curve0.removePoint(i);
        }

        zgui.setCursorPosY(h * 0.7);

        zgui.separatorText("Programacion");

        const index: u8 = @truncate(curveSelector());

        if (zgui.button("Programar", .{})) {
            const oven = self.oven orelse return Oven.Error.NoConnection;
            try oven.sendCurve(index, &self.curve0);
            zgui.openPopup("SuccessPopup", .{});
        }

        zgui.sameLine(.{});

        if (zgui.button("Leer", .{})) {
            self.curve0.clear();
            const oven = self.oven orelse return Oven.Error.NoConnection;
            try oven.getCurve(index, &self.curve0);
        }
    }

    zgui.sameLine(.{ .spacing = 10 });

    {
        _ = zgui.beginChild("grafico", .{ .w = w * plotSize, .h = h });
        defer zgui.endChild();

        plotSetup("Crear Curva", h, false);
        defer plotDone();

        plotEditable("curva", &self.curve0);
    }
}

fn monitor(self: *App, w: f32, h: f32) !void {
    self.curve0.ensureSameSize();
    self.curve1.ensureSameSize();

    const style = zgui.getStyle();
    const selectorSize = zgui.calcTextSize("AA", .{})[1] + style.frame_padding[1] * 3;

    _ = zgui.beginChild("curveSelector", .{ .w = w * 0.2, .h = selectorSize });
    const index: u8 = @truncate(curveSelector());
    zgui.endChild();

    zgui.sameLine(.{});

    if (zgui.button("Empezar", .{})) {
        const oven = self.oven orelse return Oven.Error.NoConnection;
        try oven.startMonitor(index, &self.curve0, &self.curve1);
    }

    zgui.sameLine(.{});

    if (zgui.button("Limpiar", .{})) {
        self.curve0.clear();
        self.curve1.clear();
    }

    {
        const ph = h - selectorSize - style.window_padding[1] * 2;
        _ = zgui.beginChild("grafico", .{ .w = w, .h = ph });
        defer zgui.endChild();

        plotSetup("Monitor", ph, true);
        defer plotDone();

        plot("Target", &self.curve1);
        plot("Temperatura", &self.curve0);
    }
}

fn pidEditor(self: *App, w: f32, h: f32) !void {
    _ = w;
    _ = h;

    const S = struct {
        var pid: [3]f32 = [_]f32{ 0, 0, 0 };
    };

    S.pid = self.pid.toFloat();
    _ = zgui.inputFloat3("PID", .{ .v = &S.pid });
    self.pid = Oven.PID.fromFloat(S.pid);

    if (zgui.button("Programar", .{})) {
        const oven = self.oven orelse return Oven.Error.NoConnection;
        try oven.sendPID(self.pid);
    }
}

const headers = .{ "Tiempo [s]", "Temperatura [°C]", "Opciones" };

fn tablePoints(curve: *Oven.TemperatureCurve) !?usize {
    var to_delete: ?usize = null;
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
                to_delete = index;
            }
        }
    }

    if (zgui.button("Agregar punto", .{})) {
        try curve.addPoint(0, 0);
    }

    zgui.sameLine(.{});

    if (zgui.button("Limpiar", .{})) {
        curve.clear();
    }

    return to_delete;
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

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");

const roboto_font = @embedFile("Roboto-Medium.ttf");

const Graphics = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    window: *zglfw.Window,
    draw_list: zgui.DrawList,
    font: zgui.Font,

    fn create(allocator: std.mem.Allocator) !Self {
        zglfw.init() catch |e| {
            log.err("Failed to initialize GLFW library.", .{});
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
            log.err("Failed to create demo window.", .{});
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

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .window = window,
            .draw_list = draw_list,
            .font = font,
        };
    }

    fn destroy(self: *Self) void {
        zgui.backend.deinit();
        zgui.plot.deinit();
        zgui.destroyDrawList(self.draw_list);
        zgui.deinit();
        self.gctx.destroy(self.allocator);
        self.window.destroy();
        zglfw.terminate();
    }

    fn shouldClose(self: Self) bool {
        return self.window.shouldClose();
    }

    fn newFrame(self: Self) void {
        zgui.backend.newFrame(
            self.gctx.swapchain_descriptor.width,
            self.gctx.swapchain_descriptor.height,
        );
    }

    fn draw(self: Self) void {
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
};
