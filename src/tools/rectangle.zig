const std = @import("std");
const Canvas = @import("../canvas/canvas.zig").Canvas;
const Element = @import("../canvas/element.zig").Element;
const RectElement = @import("../canvas/element.zig").RectElement;
const Color = @import("../canvas/element.zig").Color;
const c = @import("../c.zig").c;
const CursorType = @import("tool.zig").CursorType;

pub const RectangleTool = struct {
    start_x: ?i32 = null,
    start_y: ?i32 = null,
    current_x: i32 = 0,
    current_y: i32 = 0,
    is_drawing: bool = false,
    thickness: f64 = 2.0,

    pub fn init() RectangleTool {
        return .{};
    }

    pub fn onPointerPress(self: *RectangleTool, _: *Canvas, x: i32, y: i32) void {
        self.start_x = x;
        self.start_y = y;
        self.current_x = x;
        self.current_y = y;
        self.is_drawing = true;
    }

    pub fn onPointerMove(self: *RectangleTool, _: *Canvas, x: i32, y: i32) void {
        if (self.is_drawing) {
            self.current_x = x;
            self.current_y = y;
        }
    }

    pub fn onPointerRelease(self: *RectangleTool, canvas: *Canvas, x: i32, y: i32) void {
        if (!self.is_drawing or self.start_x == null) return;

        const rect_x = @min(self.start_x.?, x);
        const rect_y = @min(self.start_y.?, y);
        const rect_w = @abs(x - self.start_x.?);
        const rect_h = @abs(y - self.start_y.?);

        if (rect_w > 5 and rect_h > 5) {
            const rect = RectElement{
                .x = rect_x,
                .y = rect_y,
                .width = @intCast(rect_w),
                .height = @intCast(rect_h),
                .fill = false,
                .thickness = self.thickness,
            };

            canvas.addElement(Element{ .rectangle = rect }) catch {
                std.log.err("Failed to add rectangle element", .{});
            };
        }

        self.is_drawing = false;
        self.start_x = null;
        self.start_y = null;
    }

    pub fn render(self: *const RectangleTool, cr: *c.cairo_t, _: *const Canvas, offset_x: i32, offset_y: i32) void {
        if (self.is_drawing and self.start_x != null) {
            const rect_x: i32 = @min(self.start_x.?, self.current_x);
            const rect_y: i32 = @min(self.start_y.?, self.current_y);
            const rect_w = @abs(self.current_x - self.start_x.?);
            const rect_h = @abs(self.current_y - self.start_y.?);

            const preview = RectElement{
                .x = rect_x,
                .y = rect_y,
                .width = @intCast(rect_w),
                .height = @intCast(rect_h),
                .fill = false,
                .thickness = self.thickness,
            };
            preview.render(cr, offset_x, offset_y);
        }
    }

    pub fn getCursor(_: *const RectangleTool, _: *const Canvas, _: i32, _: i32) CursorType {
        return .crosshair;
    }

    pub fn increaseThickness(self: *RectangleTool, value: f64) void {
        self.thickness = @max(20.0, self.thickness + value);
    }

    pub fn decreaseThickness(self: *RectangleTool, value: f64) void {
        self.thickness = @min(2.0, self.thickness - value);
    }
};
