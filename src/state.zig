const std = @import("std");
const Wayland = @import("wayland.zig").Wayland;
const Canvas = @import("canvas/canvas.zig").Canvas;
const Tool = @import("tools/tool.zig").Tool;
const SelectionTool = @import("tools/selection.zig").SelectionTool;
const ArrowTool = @import("tools/arrow.zig").ArrowTool;
const RectangleTool = @import("tools/rectangle.zig").RectangleTool;
const CircleTool = @import("tools/circle.zig").CircleTool;
const LineTool = @import("tools/line.zig").LineTool;
const TextTool = @import("tools/text.zig").TextTool;

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

    wayland: ?*Wayland = null,

    canvas: Canvas,

    current_tool: Tool,
    tool_mode: ToolMode = .selection,

    mouse_pressed: bool = false,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .canvas = Canvas.init(allocator),
            .current_tool = Tool{ .selection = SelectionTool.init() },
        };
    }

    pub fn deinit(self: *AppState) void {
        self.canvas.deinit();
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
};
