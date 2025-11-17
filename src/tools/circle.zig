const std = @import("std");
const Canvas = @import("../canvas/canvas.zig").Canvas;
const Element = @import("../canvas/element.zig").Element;
const CircleElement = @import("../canvas/element.zig").CircleElement;
const Color = @import("../canvas/element.zig").Color;
const c = @import("../c.zig").c;
const CursorType = @import("tool.zig").CursorType;

pub const CircleTool = struct {
    center_x: ?i32 = null,
    center_y: ?i32 = null,
    current_x: i32 = 0,
    current_y: i32 = 0,
    is_drawing: bool = false,

    pub fn init() CircleTool {
        return .{};
    }

    pub fn onPointerPress(self: *CircleTool, _: *Canvas, x: i32, y: i32) void {
        self.center_x = x;
        self.center_y = y;
        self.current_x = x;
        self.current_y = y;
        self.is_drawing = true;
    }

    pub fn onPointerMove(self: *CircleTool, _: *Canvas, x: i32, y: i32) void {
        if (self.is_drawing) {
            self.current_x = x;
            self.current_y = y;
        }
    }

    pub fn onPointerRelease(self: *CircleTool, canvas: *Canvas, x: i32, y: i32) void {
        if (!self.is_drawing or self.center_x == null) return;

        const dx = x - self.center_x.?;
        const dy = y - self.center_y.?;
        const radius: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy))));

        if (radius > 5) {
            const circle = CircleElement{
                .center_x = self.center_x.?,
                .center_y = self.center_y.?,
                .radius = radius,
                .fill = false,
                .thickness = 2.0,
            };

            canvas.addElement(Element{ .circle = circle }) catch {
                std.log.err("Failed to add circle element", .{});
            };
        }

        self.is_drawing = false;
        self.center_x = null;
        self.center_y = null;
    }

    pub fn render(self: *const CircleTool, cr: *c.cairo_t, _: *const Canvas, offset_x: i32, offset_y: i32) void {
        if (self.is_drawing and self.center_x != null) {
            const dx = self.current_x - self.center_x.?;
            const dy = self.current_y - self.center_y.?;
            const radius: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy))));

            const preview = CircleElement{
                .center_x = self.center_x.?,
                .center_y = self.center_y.?,
                .radius = radius,
                .fill = false,
                .thickness = 2.0,
            };
            preview.render(cr, offset_x, offset_y);
        }
    }

    pub fn getCursor(_: *const CircleTool, _: *const Canvas, _: i32, _: i32) CursorType {
        return .crosshair;
    }
};
