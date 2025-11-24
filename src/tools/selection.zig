const std = @import("std");
const Canvas = @import("../canvas/canvas.zig").Canvas;
const Selection = @import("../canvas/canvas.zig").Selection;
const c = @import("../c.zig").c;
const CursorType = @import("tool.zig").CursorType;

pub const SelectionTool = struct {
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    is_selecting: bool = false,
    last_pointer_x: i32 = 0,
    last_pointer_y: i32 = 0,

    pub fn init() SelectionTool {
        return .{};
    }

    pub fn onPointerPress(self: *SelectionTool, canvas: *Canvas, x: i32, y: i32) void {
        if (canvas.selection) |*sel| {
            const handle = sel.getHandleAt(x, y);
            if (handle != .none) {
                sel.interaction = Selection.handleToInteraction(handle);
                sel.drag_offset_x = x - sel.x;
                sel.drag_offset_y = y - sel.y;
                self.last_pointer_x = x;
                self.last_pointer_y = y;
                return;
            }
        }

        self.anchor_x = x;
        self.anchor_y = y;
        self.last_pointer_x = x;
        self.last_pointer_y = y;
        self.is_selecting = true;
        canvas.selection = null;
    }

    pub fn onPointerMove(self: *SelectionTool, canvas: *Canvas, x: i32, y: i32) void {
        if (canvas.selection) |*sel| {
            if (sel.interaction == .none) {
                self.last_pointer_x = x;
                self.last_pointer_y = y;
                return;
            }

            const dx = x - self.last_pointer_x;
            const dy = y - self.last_pointer_y;

            if (sel.interaction == .moving) {
                const new_x = x - sel.drag_offset_x;
                const new_y = y - sel.drag_offset_y;
                sel.move(new_x, new_y, canvas.width, canvas.height);
            } else {
                sel.resize(dx, dy);
            }
        }

        self.last_pointer_x = x;
        self.last_pointer_y = y;
    }

    pub fn onPointerRelease(self: *SelectionTool, canvas: *Canvas, x: i32, y: i32) void {
        if (canvas.selection) |*sel| {
            if (sel.interaction != .none) {
                sel.interaction = .none;
                return;
            }
        }

        if (self.is_selecting) {
            const sel_x = @min(self.anchor_x, x);
            const sel_y = @min(self.anchor_y, y);
            const sel_w = @abs(x - self.anchor_x);
            const sel_h = @abs(y - self.anchor_y);

            if (sel_w > 1 and sel_h > 1) {
                canvas.selection = Selection{
                    .x = sel_x,
                    .y = sel_y,
                    .width = @intCast(sel_w),
                    .height = @intCast(sel_h),
                };
            }

            self.is_selecting = false;
        }
    }

    pub fn render(self: *const SelectionTool, cr: *c.cairo_t, canvas: *const Canvas, offset_x: i32, offset_y: i32) void {
        if (canvas.selection) |sel| {
            drawSelection(cr, sel, offset_x, offset_y);
        }

        if (self.is_selecting) {
            drawTempSelection(cr, self.anchor_x, self.anchor_y, self.last_pointer_x, self.last_pointer_y, offset_x, offset_y);
        }
    }

    pub fn getCursor(_: *const SelectionTool, canvas: *const Canvas, x: i32, y: i32) CursorType {
        if (canvas.selection) |sel| {
            if (sel.getHandleAt(x, y)) |handle| {
                return switch (handle) {
                    .move => .move,
                    .nw => .resize_nw,
                    .ne => .resize_ne,
                    .sw => .resize_sw,
                    .se => .resize_se,
                    .n => .resize_n,
                    .s => .resize_s,
                    .e => .resize_e,
                    .w => .resize_w,
                    .none => .default,
                };
            }
        }
        return .crosshair;
    }
};

const HANDLE_SIZE: f64 = 30.0;

fn drawSelection(cr: *c.cairo_t, sel: Selection, offset_x: i32, offset_y: i32) void {
    const x: f64 = @floatFromInt(sel.x - offset_x);
    const y: f64 = @floatFromInt(sel.y - offset_y);
    const w: f64 = @floatFromInt(sel.width);
    const h: f64 = @floatFromInt(sel.height);

    c.cairo_set_source_rgba(cr, 0.0, 1.0, 0.0, 1.0);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_stroke(cr);

    drawResizeHandles(cr, x, y, w, h);
    drawDimensionsLabel(cr, x, y, w, h);
}

fn drawTempSelection(cr: *c.cairo_t, anchor_x: i32, anchor_y: i32, pointer_x: i32, pointer_y: i32, offset_x: i32, offset_y: i32) void {
    const x1: f64 = @floatFromInt(anchor_x - offset_x);
    const y1: f64 = @floatFromInt(anchor_y - offset_y);
    const x2: f64 = @floatFromInt(pointer_x - offset_x);
    const y2: f64 = @floatFromInt(pointer_y - offset_y);

    const x = @min(x1, x2);
    const y = @min(y1, y2);
    const w = @abs(x2 - x1);
    const h = @abs(y2 - y1);

    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);
    c.cairo_set_line_width(cr, 2.0);
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_stroke(cr);
}

fn drawResizeHandles(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    const half_handle: f64 = HANDLE_SIZE / 2.0;

    const handles = [_]struct { x: f64, y: f64 }{
        .{ .x = x, .y = y }, // nw
        .{ .x = x + w / 2, .y = y }, // n
        .{ .x = x + w, .y = y }, // ne
        .{ .x = x, .y = y + h / 2 }, // w
        .{ .x = x + w, .y = y + h / 2 }, // e
        .{ .x = x, .y = y + h }, // sw
        .{ .x = x + w / 2, .y = y + h }, // s
        .{ .x = x + w, .y = y + h }, // se
    };

    for (handles) |handle| {
        c.cairo_arc(cr, handle.x + 1, handle.y + 1, half_handle + 1, 0, 2 * std.math.pi);
        c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.3);
        c.cairo_fill(cr);

        c.cairo_arc(cr, handle.x, handle.y, half_handle, 0, 2 * std.math.pi);
        c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        c.cairo_fill_preserve(cr);

        c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.9);
        c.cairo_set_line_width(cr, 1.5);
        c.cairo_stroke(cr);
    }
}

fn drawDimensionsLabel(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{d} × {d}", .{
        @as(i32, @intFromFloat(w)),
        @as(i32, @intFromFloat(h)),
    }) catch return;

    const text_len: f64 = @floatFromInt(text.len);
    const text_center_offset = text_len / 2;
    const label_x = x + w / 2;
    const label_y = y - 20;
    const font_size: f64 = 12;

    c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.7);
    c.cairo_rectangle(cr, label_x - text_center_offset * font_size / 2, label_y - 15, text_center_offset * font_size, 20);
    c.cairo_fill(cr);

    c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    c.cairo_select_font_face(cr, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 12.0);
    c.cairo_move_to(cr, label_x - text_center_offset * font_size / 2, label_y);
    c.cairo_show_text(cr, text.ptr);
}
