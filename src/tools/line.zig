const std = @import("std");
const Canvas = @import("../canvas/canvas.zig").Canvas;
const Element = @import("../canvas/element.zig").Element;
const LineElement = @import("../canvas/element.zig").LineElement;
const Color = @import("../canvas/element.zig").Color;
const c = @import("../c.zig").c;
const CursorType = @import("tool.zig").CursorType;

pub const LineTool = struct {
    start_x: ?i32 = null,
    start_y: ?i32 = null,
    current_x: i32 = 0,
    current_y: i32 = 0,
    is_drawing: bool = false,

    pub fn init() LineTool {
        return .{};
    }

    pub fn onPointerPress(self: *LineTool, _: *Canvas, x: i32, y: i32) void {
        self.start_x = x;
        self.start_y = y;
        self.current_x = x;
        self.current_y = y;
        self.is_drawing = true;
    }

    pub fn onPointerMove(self: *LineTool, _: *Canvas, x: i32, y: i32) void {
        if (self.is_drawing) {
            self.current_x = x;
            self.current_y = y;
        }
    }

    pub fn onPointerRelease(self: *LineTool, canvas: *Canvas, x: i32, y: i32) void {
        if (!self.is_drawing or self.start_x == null) return;

        const dx = @abs(x - self.start_x.?);
        const dy = @abs(y - self.start_y.?);
        if (dx > 5 or dy > 5) {
            const line = LineElement{
                .start_x = self.start_x.?,
                .start_y = self.start_y.?,
                .end_x = x,
                .end_y = y,
                .thickness = 2.0,
            };

            canvas.addElement(Element{ .line = line }) catch {
                std.log.err("Failed to add line element", .{});
            };
        }

        self.is_drawing = false;
        self.start_x = null;
        self.start_y = null;
    }

    pub fn render(self: *const LineTool, cr: *c.cairo_t, _: *const Canvas, offset_x: i32, offset_y: i32) void {
        if (self.is_drawing and self.start_x != null) {
            const preview = LineElement{
                .start_x = self.start_x.?,
                .start_y = self.start_y.?,
                .end_x = self.current_x,
                .end_y = self.current_y,
                .thickness = 2.0,
            };
            preview.render(cr, offset_x, offset_y);
        }
    }

    pub fn getCursor(_: *const LineTool, _: *const Canvas, _: i32, _: i32) CursorType {
        return .crosshair;
    }
};
