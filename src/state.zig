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
    allocator: std.mem.Allocator,

    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,

    outputs: std.ArrayList(*Output),

    canvas: Canvas,

    current_tool: Tool,
    tool_mode: ToolMode = .selection,

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
        self.canvas.deinit();
        for (self.outputs.items) |output| {
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);
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
