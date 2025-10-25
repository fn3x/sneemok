const c = @import("../c.zig").c;
const std = @import("std");
const Arrow = @import("arrow.zig");

pub const HANDLE_SIZE: f64 = 30.0;

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

pub fn drawResizeHandles(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    const half_handle: f64 = HANDLE_SIZE / 2.0;

    const handles = [_]struct { x: f64, y: f64, type: ResizeType }{
        .{ .x = x - half_handle, .y = y - half_handle, .type = .nw },
        .{ .x = x + w / 2 - half_handle, .y = y - half_handle, .type = .n },
        .{ .x = x + w - half_handle, .y = y - half_handle, .type = .ne },
        .{ .x = x - half_handle, .y = y + h / 2 - half_handle, .type = .w },
        .{ .x = x + w - half_handle, .y = y + h / 2 - half_handle, .type = .e },
        .{ .x = x - half_handle, .y = y + h - half_handle, .type = .sw },
        .{ .x = x + w / 2 - half_handle, .y = y + h - half_handle, .type = .s },
        .{ .x = x + w - half_handle, .y = y + h - half_handle, .type = .se },
    };

    for (handles) |handle| {
        const handle_type: HandleType = blk: {
            break :blk .normal;
        };

        const half = HANDLE_SIZE / 2.0;
        const center_x = handle.x + half;
        const center_y = handle.y + half;

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
}

pub fn drawArrowHandle(cr: ?*c.cairo_t, x: f64, y: f64, _: f64, h: f64) void {
    const arrow: Arrow.Arrow = .{
        .start_x = x + HANDLE_SIZE,
        .start_y = y + HANDLE_SIZE / 2 + h,
        .end_x = x + HANDLE_SIZE / 2 + 5,
        .end_y = y + HANDLE_SIZE / 4 + h,
        .length = 15.0,
    };

    Arrow.drawArrowHandle(cr, arrow, HANDLE_SIZE / 2);
}

pub fn drawArrow(cr: ?*c.cairo_t, arrow_pos: Arrow.Arrow) void {
    Arrow.drawArrow(cr, arrow_pos);
}

pub fn drawDimensionsLabel(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
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
