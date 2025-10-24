const c = @import("../c.zig").c;
const std = @import("std");
const math = std.math;

pub fn draw(cr: ?*c.cairo_t, x1: f64, y1: f64, x2: f64, y2: f64) void {
    const angle = math.atan2(y2 - y1, x2 - x1) + math.pi;
    const arrow_degrees: f64 = 0.5;
    const arrow_length: f64 = 25;

    const xA = x2 + arrow_length * @cos(angle - arrow_degrees);
    const yA = y2 + arrow_length * @sin(angle - arrow_degrees);
    const xB = x2 + arrow_length * @cos(angle + arrow_degrees);
    const yB = y2 + arrow_length * @sin(angle + arrow_degrees);

    c.cairo_move_to(cr, x2, y2);
    c.cairo_line_to(cr, xA, yA);
    c.cairo_line_to(cr, xB, yB);
    c.cairo_line_to(cr, x2, y2);

    c.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    c.cairo_fill_preserve(cr);

    const middle_x = (xA + xB) / 2;
    const middle_y = (yA + yB) / 2;

    const arrow_line_x: f64 = middle_x + arrow_length / 16 * (2 * middle_x - x2 - middle_x);
    const arrow_line_y: f64 = middle_y + arrow_length / 16 * (2 * middle_y - y2 - middle_y);

    c.cairo_move_to(cr, middle_x, middle_y);
    c.cairo_line_to(cr, arrow_line_x, arrow_line_y);

    c.cairo_stroke(cr);
}
