const std = @import("std");
const c = @import("../c.zig").c;
const Element = @import("element.zig").Element;

pub const Canvas = struct {
    allocator: std.mem.Allocator,

    image: ?[*c]u8 = null,
    image_width: i32 = 0,
    image_height: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    selection: ?Selection = null,

    elements: std.ArrayList(Element),

    active_element_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Canvas {
        return .{
            .allocator = allocator,
            .elements = std.ArrayList(Element).empty,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.elements.deinit(self.allocator);
    }

    pub fn setImage(self: *Canvas, image: [*c]u8, width: i32, height: i32) void {
        self.image = image;
        self.image_width = width;
        self.image_height = height;
        self.width = width;
        self.height = height;
    }

    pub fn addElement(self: *Canvas, element: Element) !void {
        try self.elements.append(self.allocator, element);
    }

    pub fn getActiveElement(self: *Canvas) ?*Element {
        if (self.active_element_index) |idx| {
            if (idx < self.elements.items.len) {
                return &self.elements.items[idx];
            }
        }
        return null;
    }

    pub fn writeToPngFd(self: *const Canvas, fd: std.posix.fd_t) !void {
        const sel = self.selection orelse return error.NoSelection;

        const surface = c.cairo_image_surface_create(
            c.CAIRO_FORMAT_ARGB32,
            sel.width,
            sel.height,
        );
        defer c.cairo_surface_destroy(surface);

        const cr = c.cairo_create(surface);
        defer c.cairo_destroy(cr);

        if (self.image) |image| {
            const img_surface = c.cairo_image_surface_create_for_data(
                @ptrCast(@constCast(image)),
                c.CAIRO_FORMAT_ARGB32,
                self.width,
                self.height,
                self.width * 4,
            );
            defer c.cairo_surface_destroy(img_surface);

            c.cairo_set_source_surface(cr, img_surface, @floatFromInt(-sel.x), @floatFromInt(-sel.y));
            c.cairo_paint(cr);
        }

        for (self.elements.items) |*element| {
            element.render(cr.?, sel.x, sel.y);
        }

        const FdWrapper = struct {
            fd: std.posix.fd_t,
        };

        var wrapper = FdWrapper{ .fd = fd };

        const result = c.cairo_surface_write_to_png_stream(
            surface,
            cairoWriteCallback,
            @ptrCast(&wrapper),
        );

        if (result != c.CAIRO_STATUS_SUCCESS) {
            return error.CairoWriteFailed;
        }
    }

    pub fn clearPixels(self: *const Canvas, pixels: *[]u8) void {
        self.allocator.free(pixels);
    }
};

pub const Selection = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    interaction: InteractionMode = .none,

    drag_offset_x: i32 = 0,
    drag_offset_y: i32 = 0,

    pub const InteractionMode = enum {
        none,
        moving,
        resizing_nw,
        resizing_ne,
        resizing_sw,
        resizing_se,
        resizing_n,
        resizing_s,
        resizing_e,
        resizing_w,
    };

    pub const HandleType = enum {
        none,
        move,
        nw,
        ne,
        sw,
        se,
        n,
        s,
        e,
        w,
    };

    const HANDLE_SIZE: i32 = 15;

    pub fn getHandleAt(self: *const Selection, x: i32, y: i32) HandleType {
        if (isPointInHandle(x, y, self.x, self.y)) return .nw;
        if (isPointInHandle(x, y, self.x + self.width, self.y)) return .ne;
        if (isPointInHandle(x, y, self.x, self.y + self.height)) return .sw;
        if (isPointInHandle(x, y, self.x + self.width, self.y + self.height)) return .se;

        if (isPointInHandle(x, y, self.x + @divTrunc(self.width, 2), self.y)) return .n;
        if (isPointInHandle(x, y, self.x + @divTrunc(self.width, 2), self.y + self.height)) return .s;
        if (isPointInHandle(x, y, self.x, self.y + @divTrunc(self.height, 2))) return .w;
        if (isPointInHandle(x, y, self.x + self.width, self.y + @divTrunc(self.height, 2))) return .e;

        if (isPointInRect(x, y, self.x, self.y, self.width, self.height)) return .move;

        return .none;
    }

    fn isPointInHandle(px: i32, py: i32, hx: i32, hy: i32) bool {
        const half: i32 = @divTrunc(HANDLE_SIZE, 2);
        return px >= hx - half and px < hx + half and
            py >= hy - half and py < hy + half;
    }

    fn isPointInRect(px: i32, py: i32, x: i32, y: i32, w: i32, h: i32) bool {
        return px >= x and px < x + w and py >= y and py < y + h;
    }

    pub fn handleToInteraction(handle: HandleType) InteractionMode {
        return switch (handle) {
            .move => .moving,
            .nw => .resizing_nw,
            .ne => .resizing_ne,
            .sw => .resizing_sw,
            .se => .resizing_se,
            .n => .resizing_n,
            .s => .resizing_s,
            .e => .resizing_e,
            .w => .resizing_w,
            .none => .none,
        };
    }

    pub fn resize(self: *Selection, dx: i32, dy: i32) void {
        switch (self.interaction) {
            .resizing_se => {
                self.width = @max(1, self.width + dx);
                self.height = @max(1, self.height + dy);
            },
            .resizing_nw => {
                const new_w = self.width - dx;
                const new_h = self.height - dy;
                if (new_w > 0 and new_h > 0) {
                    self.x += dx;
                    self.y += dy;
                    self.width = new_w;
                    self.height = new_h;
                }
            },
            .resizing_ne => {
                self.width = @max(1, self.width + dx);
                const new_h = self.height - dy;
                if (new_h > 0) {
                    self.y += dy;
                    self.height = new_h;
                }
            },
            .resizing_sw => {
                const new_w = self.width - dx;
                if (new_w > 0) {
                    self.x += dx;
                    self.width = new_w;
                }
                self.height = @max(1, self.height + dy);
            },
            .resizing_n => {
                const new_h = self.height - dy;
                if (new_h > 0) {
                    self.y += dy;
                    self.height = new_h;
                }
            },
            .resizing_s => {
                self.height = @max(1, self.height + dy);
            },
            .resizing_w => {
                const new_w = self.width - dx;
                if (new_w > 0) {
                    self.x += dx;
                    self.width = new_w;
                }
            },
            .resizing_e => {
                self.width = @max(1, self.width + dx);
            },
            else => {},
        }
    }

    pub fn move(self: *Selection, new_x: i32, new_y: i32, canvas_width: i32, canvas_height: i32) void {
        self.x = clamp(new_x, 0, canvas_width - self.width);
        self.y = clamp(new_y, 0, canvas_height - self.height);
    }

    fn clamp(value: i32, min: i32, max: i32) i32 {
        return @max(min, @min(max, value));
    }
};

fn cairoWriteCallback(
    closure: ?*anyopaque,
    data: [*c]const u8,
    length: c_uint,
) callconv(.c) c.cairo_status_t {
    const FdWrapper = struct {
        fd: std.posix.fd_t,
    };

    const wrapper: *FdWrapper = @ptrCast(@alignCast(closure));
    const fd = wrapper.fd;

    const slice = data[0..length];

    var written: usize = 0;
    while (written < slice.len) {
        const n = std.posix.write(fd, slice[written..]) catch {
            return c.CAIRO_STATUS_WRITE_ERROR;
        };
        written += n;
    }

    return c.CAIRO_STATUS_SUCCESS;
}
