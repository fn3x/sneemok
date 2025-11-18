const std = @import("std");
const Canvas = @import("../canvas/canvas.zig").Canvas;
const c = @import("../c.zig").c;

pub const CursorType = enum {
    default,
    crosshair,
    move,
    resize_nw,
    resize_ne,
    resize_sw,
    resize_se,
    resize_n,
    resize_s,
    resize_e,
    resize_w,
};

pub const ToolType = enum {
    selection,
    arrow,
    rectangle,
    circle,
    line,
    text,
};

pub const Tool = union(ToolType) {
    selection: @import("selection.zig").SelectionTool,
    arrow: @import("arrow.zig").ArrowTool,
    rectangle: @import("rectangle.zig").RectangleTool,
    circle: @import("circle.zig").CircleTool,
    line: @import("line.zig").LineTool,
    text: @import("text.zig").TextTool,

    pub fn onPointerPress(self: *Tool, canvas: *Canvas, x: i32, y: i32) void {
        switch (self.*) {
            inline else => |*tool| tool.onPointerPress(canvas, x, y),
        }
    }

    pub fn onPointerMove(self: *Tool, canvas: *Canvas, x: i32, y: i32) void {
        switch (self.*) {
            inline else => |*tool| tool.onPointerMove(canvas, x, y),
        }
    }

    pub fn onPointerRelease(self: *Tool, canvas: *Canvas, x: i32, y: i32) void {
        switch (self.*) {
            inline else => |*tool| tool.onPointerRelease(canvas, x, y),
        }
    }

    pub fn render(self: *const Tool, cr: *c.cairo_t, canvas: *const Canvas, local_offset_x: i32, local_offset_y: i32) void {
        switch (self.*) {
            inline else => |*tool| tool.render(cr, canvas, local_offset_x, local_offset_y),
        }
    }

    pub fn getCursor(self: *const Tool, canvas: *const Canvas, x: i32, y: i32) CursorType {
        return switch (self.*) {
            inline else => |*tool| tool.getCursor(canvas, x, y),
        };
    }

    pub fn increaseThickness(self: *Tool, value: f64) void {
        std.log.debug("tool increase", .{});
        switch (self.*) {
            .selection => {},
            .text => {},
            .arrow => |*tool| {
                std.log.debug("arrow tool increase", .{});
                tool.increaseThickness(value);
            },
            else => {},
        }
    }

    pub fn decreaseThickness(self: *Tool, value: f64) void {
        switch (self.*) {
            .selection => {},
            .text => {},
            .arrow => |*tool| {
                std.log.debug("arrow tool increase", .{});
                tool.decreaseThickness(value);
            },
            else => {},
        }
    }
};
