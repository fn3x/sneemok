const c = @import("../c.zig").c;
const std = @import("std");
const math = std.math;

pub const Arrow = struct {
    start_x: f64,
    start_y: f64,
    end_x: f64,
    end_y: f64,
    length: f64,
};

pub fn drawArrow(cr: ?*c.cairo_t, pos: Arrow) void {
    const angle = math.atan2(pos.end_y - pos.start_y, pos.end_x - pos.start_x) + math.pi;
    const arrow_degrees: f64 = 0.5;

    const xA = pos.end_x + pos.length * @cos(angle - arrow_degrees);
    const yA = pos.end_y + pos.length * @sin(angle - arrow_degrees);
    const xB = pos.end_x + pos.length * @cos(angle + arrow_degrees);
    const yB = pos.end_y + pos.length * @sin(angle + arrow_degrees);

    c.cairo_move_to(cr, pos.end_x, pos.end_y);
    c.cairo_line_to(cr, xA, yA);
    c.cairo_line_to(cr, xB, yB);
    c.cairo_line_to(cr, pos.end_x, pos.end_y);

    c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    c.cairo_fill_preserve(cr);

    const middle_x = (xA + xB) / 2;
    const middle_y = (yA + yB) / 2;

    const arrow_line_x: f64 = middle_x + pos.length / 16 * (2 * middle_x - pos.end_x - middle_x);
    const arrow_line_y: f64 = middle_y + pos.length / 16 * (2 * middle_y - pos.end_y - middle_y);

    c.cairo_move_to(cr, middle_x, middle_y);
    c.cairo_line_to(cr, arrow_line_x, arrow_line_y);

    c.cairo_stroke(cr);
}

pub fn drawArrowHandle(cr: ?*c.cairo_t, _: f64, _: f64, pos: Arrow, size: f64) void {
    const angle = math.atan2(pos.end_y - pos.start_y, pos.end_x - pos.start_x) + math.pi;
    const arrow_degrees: f64 = 0.5;

    const xA = pos.end_x + pos.length * @cos(angle - arrow_degrees);
    const yA = pos.end_y + pos.length * @sin(angle - arrow_degrees);
    const xB = pos.end_x + pos.length * @cos(angle + arrow_degrees);
    const yB = pos.end_y + pos.length * @sin(angle + arrow_degrees);

    c.cairo_move_to(cr, pos.end_x, pos.end_y);
    c.cairo_line_to(cr, xA, yA);
    c.cairo_line_to(cr, xB, yB);
    c.cairo_line_to(cr, pos.end_x, pos.end_y);

    c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    c.cairo_fill_preserve(cr);

    const middle_x = (xA + xB) / 2;
    const middle_y = (yA + yB) / 2;

    const arrow_line_x: f64 = middle_x + pos.length / 20 * (2 * middle_x - pos.end_x - middle_x);
    const arrow_line_y: f64 = middle_y + pos.length / 20 * (2 * middle_y - pos.end_y - middle_y);

    c.cairo_set_line_width(cr, 3.0);
    c.cairo_move_to(cr, middle_x, middle_y);
    c.cairo_line_to(cr, arrow_line_x, arrow_line_y);
    c.cairo_stroke(cr);

    c.cairo_set_line_width(cr, 1.5);
    c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    c.cairo_arc(cr, middle_x, middle_y, size, 0, 2 * std.math.pi);

    c.cairo_stroke(cr);
}
