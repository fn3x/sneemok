const std = @import("std");
const Canvas = @import("../canvas/canvas.zig").Canvas;
const c = @import("../c.zig").c;
const CursorType = @import("tool.zig").CursorType;

// TODO: Text tool needs keyboard input integration
pub const TextTool = struct {
    pub fn init() TextTool {
        return .{};
    }

    pub fn onPointerPress(_: *TextTool, _: *Canvas, _: i32, _: i32) void {
        // TODO: Start text input at position
    }

    pub fn onPointerMove(_: *TextTool, _: *Canvas, _: i32, _: i32) void {
        // No-op for text tool
    }

    pub fn onPointerRelease(_: *TextTool, _: *Canvas, _: i32, _: i32) void {
        // TODO: Finalize text input
    }

    pub fn render(_: *const TextTool, _: *c.cairo_t, _: *const Canvas, _: i32, _: i32) void {
        // TODO: Draw text cursor or preview
    }

    pub fn getCursor(_: *const TextTool, _: *const Canvas, _: i32, _: i32) CursorType {
        return .default;
    }
};
