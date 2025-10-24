const c = @import("../c.zig").c;
const std = @import("std");
const Arrow = @import("arrow.zig");

pub const RESIZE_HANDLE_SIZE: f64 = 30.0;

pub const HandleType = enum {
    normal,
    hovered,
    active,
};

pub const ResizeType = enum {
    nw,
    n,
    ne,
    w,
    e,
    sw,
    s,
    se,
};

pub const GUI = struct {
    const Self = @This();

    pub fn draw(_: *Self, cr: *c.cairo_t, local_x: i32, local_y: i32, sel_w: i32, sel_h: i32) void {
        const half_handle: f64 = RESIZE_HANDLE_SIZE / 2.0;

        const lx: f64 = @floatFromInt(local_x);
        const ly: f64 = @floatFromInt(local_y);
        const w: f64 = @floatFromInt(sel_w);
        const h: f64 = @floatFromInt(sel_h);

        const handles = [_]struct { x: f64, y: f64, type: ResizeType }{
            .{ .x = lx - half_handle, .y = ly - half_handle, .type = .nw },
            .{ .x = lx + w / 2 - half_handle, .y = ly - half_handle, .type = .n },
            .{ .x = lx + w - half_handle, .y = ly - half_handle, .type = .ne },
            .{ .x = lx - half_handle, .y = ly + h / 2 - half_handle, .type = .w },
            .{ .x = lx + w - half_handle, .y = ly + h / 2 - half_handle, .type = .e },
            .{ .x = lx - half_handle, .y = ly + h - half_handle, .type = .sw },
            .{ .x = lx + w / 2 - half_handle, .y = ly + h - half_handle, .type = .s },
            .{ .x = lx + w - half_handle, .y = ly + h - half_handle, .type = .se },
        };

        for (handles) |handle| {
            const handle_type: HandleType = blk: {
                break :blk .normal;
            };

            drawResizeHandle(cr, handle.x, handle.y, RESIZE_HANDLE_SIZE, handle_type);
        }

        drawDimensionsLabel(cr, lx, ly, w, h);
        Arrow.draw(cr, lx + w / 2, ly + 30 + h, lx + 5 + w / 2, ly + 25 + h);
    }
};

fn drawResizeHandle(cr: *c.cairo_t, x: f64, y: f64, size: f64, handle_type: HandleType) void {
    const half = size / 2.0;
    const center_x = x + half;
    const center_y = y + half;

    c.cairo_arc(cr, center_x + 1, center_y + 1, half + 1, 0, 2 * std.math.pi);
    c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.3);
    c.cairo_fill(cr);

    c.cairo_arc(cr, center_x, center_y, half, 0, 2 * std.math.pi);

    switch (handle_type) {
        .normal => c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0),
        .hovered => c.cairo_set_source_rgb(cr, 0.4, 0.7, 1.0),
        .active => c.cairo_set_source_rgb(cr, 0.2, 0.5, 0.9),
    }
    c.cairo_fill_preserve(cr);

    c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.9);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_stroke(cr);
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
