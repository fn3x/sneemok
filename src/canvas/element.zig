const std = @import("std");
const c = @import("../c.zig").c;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const white = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const black = Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const red = Color{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const green = Color{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const blue = Color{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const ElementType = enum {
    arrow,
    rectangle,
    circle,
    line,
    text,
};

pub const Element = union(ElementType) {
    arrow: ArrowElement,
    rectangle: RectElement,
    circle: CircleElement,
    line: LineElement,
    text: TextElement,

    pub fn render(self: *const Element, cr: *c.cairo_t, offset_x: i32, offset_y: i32) void {
        switch (self.*) {
            .arrow => |*arrow| arrow.render(cr, offset_x, offset_y),
            .rectangle => |*rect| rect.render(cr, offset_x, offset_y),
            .circle => |*circle| circle.render(cr, offset_x, offset_y),
            .line => |*line| line.render(cr, offset_x, offset_y),
            .text => |*text| text.render(cr, offset_x, offset_y),
        }
    }

    pub fn hitTest(self: *const Element, x: i32, y: i32) bool {
        return switch (self.*) {
            .arrow => |*arrow| arrow.hitTest(x, y),
            .rectangle => |*rect| rect.hitTest(x, y),
            .circle => |*circle| circle.hitTest(x, y),
            .line => |*line| line.hitTest(x, y),
            .text => |*text| text.hitTest(x, y),
        };
    }

    pub fn getBounds(self: *const Element) Rect {
        return switch (self.*) {
            .arrow => |*arrow| arrow.getBounds(),
            .rectangle => |*rect| rect.getBounds(),
            .circle => |*circle| circle.getBounds(),
            .line => |*line| line.getBounds(),
            .text => |*text| text.getBounds(),
        };
    }
};

pub const ArrowElement = struct {
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    color: Color = Color.red,
    thickness: f64 = 2.0,
    arrow_size: f32 = 15.0,

    pub fn render(self: *const ArrowElement, cr: *c.cairo_t, offset_x: i32, offset_y: i32) void {
        const sx: f64 = @floatFromInt(self.start_x - offset_x);
        const sy: f64 = @floatFromInt(self.start_y - offset_y);
        const ex: f64 = @floatFromInt(self.end_x - offset_x);
        const ey: f64 = @floatFromInt(self.end_y - offset_y);

        c.cairo_set_source_rgba(cr, self.color.r, self.color.g, self.color.b, self.color.a);
        c.cairo_set_line_width(cr, self.thickness);
        c.cairo_move_to(cr, sx, sy);
        c.cairo_line_to(cr, ex, ey);
        c.cairo_stroke(cr);

        const angle = std.math.atan2(ey - sy, ex - sx) + std.math.pi;
        const arrow_degrees: f64 = 0.5;

        const xA = ex + self.arrow_size * @cos(angle - arrow_degrees);
        const yA = ey + self.arrow_size * @sin(angle - arrow_degrees);
        const xB = ex + self.arrow_size * @cos(angle + arrow_degrees);
        const yB = ey + self.arrow_size * @sin(angle + arrow_degrees);

        c.cairo_move_to(cr, ex, ey);
        c.cairo_line_to(cr, xA, yA);
        c.cairo_line_to(cr, xB, yB);
        c.cairo_close_path(cr);
        c.cairo_fill(cr);
    }

    pub fn hitTest(self: *const ArrowElement, x: i32, y: i32) bool {
        const dx = self.end_x - self.start_x;
        const dy = self.end_y - self.start_y;
        const length_sq = dx * dx + dy * dy;

        if (length_sq == 0) {
            const dist_x = x - self.start_x;
            const dist_y = y - self.start_y;
            return (dist_x * dist_x + dist_y * dist_y) < 25;
        }

        const px = x - self.start_x;
        const py = y - self.start_y;
        const t = @max(0, @min(length_sq, px * dx + py * dy)) / length_sq;

        const proj_x = self.start_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(t * dx))));
        const proj_y = self.start_y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(t * dy))));

        const dist_x = x - proj_x;
        const dist_y = y - proj_y;
        return (dist_x * dist_x + dist_y * dist_y) < 25;
    }

    pub fn getBounds(self: *const ArrowElement) Rect {
        const x = @min(self.start_x, self.end_x);
        const y = @min(self.start_y, self.end_y);
        const width = @abs(self.end_x - self.start_x);
        const height = @abs(self.end_y - self.start_y);
        return .{ .x = x, .y = y, .width = width, .height = height };
    }
};

pub const RectElement = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    color: Color = Color.red,
    fill: bool = false,
    thickness: f64 = 2.0,

    pub fn render(self: *const RectElement, cr: *c.cairo_t, offset_x: i32, offset_y: i32) void {
        const x: f64 = @floatFromInt(self.x - offset_x);
        const y: f64 = @floatFromInt(self.y - offset_y);
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);

        c.cairo_set_source_rgba(cr, self.color.r, self.color.g, self.color.b, self.color.a);
        c.cairo_rectangle(cr, x, y, w, h);

        if (self.fill) {
            c.cairo_fill(cr);
        } else {
            c.cairo_set_line_width(cr, self.thickness);
            c.cairo_stroke(cr);
        }
    }

    pub fn hitTest(self: *const RectElement, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + self.width and
            y >= self.y and y < self.y + self.height;
    }

    pub fn getBounds(self: *const RectElement) Rect {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height };
    }
};

pub const CircleElement = struct {
    center_x: i32,
    center_y: i32,
    radius: i32,
    color: Color = Color.red,
    fill: bool = false,
    thickness: f64 = 2.0,

    pub fn render(self: *const CircleElement, cr: *c.cairo_t, offset_x: i32, offset_y: i32) void {
        const cx: f64 = @floatFromInt(self.center_x - offset_x);
        const cy: f64 = @floatFromInt(self.center_y - offset_y);
        const r: f64 = @floatFromInt(self.radius);

        c.cairo_set_source_rgba(cr, self.color.r, self.color.g, self.color.b, self.color.a);
        c.cairo_arc(cr, cx, cy, r, 0, 2 * std.math.pi);

        if (self.fill) {
            c.cairo_fill(cr);
        } else {
            c.cairo_set_line_width(cr, self.thickness);
            c.cairo_stroke(cr);
        }
    }

    pub fn hitTest(self: *const CircleElement, x: i32, y: i32) bool {
        const dx = x - self.center_x;
        const dy = y - self.center_y;
        return (dx * dx + dy * dy) <= (self.radius * self.radius);
    }

    pub fn getBounds(self: *const CircleElement) Rect {
        return .{
            .x = self.center_x - self.radius,
            .y = self.center_y - self.radius,
            .width = self.radius * 2,
            .height = self.radius * 2,
        };
    }
};

pub const LineElement = struct {
    start_x: i32,
    start_y: i32,
    end_x: i32,
    end_y: i32,
    color: Color = Color.red,
    thickness: f64 = 2.0,

    pub fn render(self: *const LineElement, cr: *c.cairo_t, offset_x: i32, offset_y: i32) void {
        const sx: f64 = @floatFromInt(self.start_x - offset_x);
        const sy: f64 = @floatFromInt(self.start_y - offset_y);
        const ex: f64 = @floatFromInt(self.end_x - offset_y);
        const ey: f64 = @floatFromInt(self.end_y - offset_y);

        c.cairo_set_source_rgba(cr, self.color.r, self.color.g, self.color.b, self.color.a);
        c.cairo_set_line_width(cr, self.thickness);
        c.cairo_move_to(cr, sx, sy);
        c.cairo_line_to(cr, ex, ey);
        c.cairo_stroke(cr);
    }

    pub fn hitTest(self: *const LineElement, x: i32, y: i32) bool {
        const dx = self.end_x - self.start_x;
        const dy = self.end_y - self.start_y;
        const length_sq = dx * dx + dy * dy;

        if (length_sq == 0) {
            const dist_x = x - self.start_x;
            const dist_y = y - self.start_y;
            return (dist_x * dist_x + dist_y * dist_y) < 25;
        }

        const px = x - self.start_x;
        const py = y - self.start_y;
        const t = @max(0, @min(length_sq, px * dx + py * dy)) / length_sq;

        const proj_x = self.start_x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(t * dx))));
        const proj_y = self.start_y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(t * dy))));

        const dist_x = x - proj_x;
        const dist_y = y - proj_y;
        return (dist_x * dist_x + dist_y * dist_y) < 25;
    }

    pub fn getBounds(self: *const LineElement) Rect {
        const x = @min(self.start_x, self.end_x);
        const y = @min(self.start_y, self.end_y);
        const width = @abs(self.end_x - self.start_x);
        const height = @abs(self.end_y - self.start_y);
        return .{ .x = x, .y = y, .width = width, .height = height };
    }
};

pub const TextElement = struct {
    x: i32,
    y: i32,
    text: []const u8,
    color: Color = Color.red,
    font_size: f32 = 12.0,

    pub fn render(self: *const TextElement, cr: *c.cairo_t, offset_x: i32, offset_y: i32) void {
        const x: f64 = @floatFromInt(self.x - offset_x);
        const y: f64 = @floatFromInt(self.y - offset_y);

        c.cairo_set_source_rgba(cr, self.color.r, self.color.g, self.color.b, self.color.a);
        c.cairo_select_font_face(cr, "sans-serif", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, self.font_size);
        c.cairo_move_to(cr, x, y);
        c.cairo_show_text(cr, self.text.ptr);
    }

    pub fn hitTest(self: *const TextElement, x: i32, y: i32) bool {
        const dx = x - self.x;
        const dy = y - self.y;
        return dx >= 0 and dx < 100 and dy >= -20 and dy < 20;
    }

    pub fn getBounds(self: *const TextElement) Rect {
        const width: i32 = @intFromFloat(@as(f32, @floatFromInt(self.text.len)) * self.font_size * 0.6);
        const height: i32 = @intFromFloat(self.font_size * 1.2);
        return .{ .x = self.x, .y = self.y - height, .width = width, .height = height };
    }
};
