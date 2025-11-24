const std = @import("std");
const wayland = @import("wayland");
const Canvas = @import("canvas/canvas.zig").Canvas;
const Tool = @import("tools/tool.zig").Tool;
const SelectionTool = @import("tools/selection.zig").SelectionTool;
const ArrowTool = @import("tools/arrow.zig").ArrowTool;
const RectangleTool = @import("tools/rectangle.zig").RectangleTool;
const CircleTool = @import("tools/circle.zig").CircleTool;
const LineTool = @import("tools/line.zig").LineTool;
const TextTool = @import("tools/text.zig").TextTool;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

pub const Output = @import("output.zig").Output;

pub const ToolMode = enum {
    selection,
    draw_arrow,
    draw_rectangle,
    draw_circle,
    draw_line,
    draw_text,

    pub fn toName(self: ToolMode) []const u8 {
        return switch (self) {
            .selection => "Selection",
            .draw_arrow => "Arrow",
            .draw_rectangle => "Rectangle",
            .draw_circle => "Circle",
            .draw_line => "Line",
            .draw_text => "Text",
        };
    }
};

pub const AppState = struct {
    running: bool = true,

    allocator: std.mem.Allocator,

    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,
    keyboard_modifiers: KeyboardModifiers = .{},
    serial: ?u32 = null,
    pointer: ?*wl.Pointer = null,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_surface: ?*wl.Surface = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    data_source: ?*wl.DataSource = null,

    outputs: std.ArrayList(*Output),

    canvas: Canvas,

    current_tool: Tool,
    tool_mode: ToolMode = .selection,

    mouse_pressed: bool = false,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .outputs = std.ArrayList(*Output).empty,
            .canvas = Canvas.init(allocator),
            .current_tool = Tool{ .selection = SelectionTool.init() },
        };
    }

    pub fn deinit(self: *AppState) void {
        for (self.outputs.items) |output| {
            if (output.layer_surface) |ls| ls.destroy();
            if (output.surface) |surf| surf.destroy();
            if (output.wl_output) |wo| wo.release();
            self.allocator.destroy(output);
        }

        self.outputs.deinit(self.allocator);
        self.canvas.deinit();

        if (self.keyboard) |kb| kb.release();
        if (self.pointer) |ptr| ptr.release();
        if (self.cursor_surface) |surface| surface.destroy();
        if (self.cursor_theme) |theme| theme.destroy();
        if (self.seat) |seat| seat.release();
        if (self.data_device) |dd| dd.release();
        if (self.data_device_manager) |ddm| ddm.destroy();

        if (self.layer_shell) |ls| ls.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.compositor) |comp| comp.destroy();
        if (self.registry) |reg| reg.destroy();
        if (self.display) |disp| disp.disconnect();
    }

    pub fn setTool(self: *AppState, mode: ToolMode) void {
        self.tool_mode = mode;
        self.current_tool = switch (mode) {
            .selection => Tool{ .selection = SelectionTool.init() },
            .draw_arrow => Tool{ .arrow = ArrowTool.init() },
            .draw_rectangle => Tool{ .rectangle = RectangleTool.init() },
            .draw_circle => Tool{ .circle = CircleTool.init() },
            .draw_line => Tool{ .line = LineTool.init() },
            .draw_text => Tool{ .text = TextTool.init() },
        };
        std.log.info("Switched to tool: {s}", .{mode.toName()});
    }

    pub fn setAllOutputsDirty(self: *AppState) void {
        for (self.outputs.items) |output| {
            output.setOutputDirty();
        }
    }
};

pub const KeyboardModifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};
