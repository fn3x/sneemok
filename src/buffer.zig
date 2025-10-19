const std = @import("std");
const wayland = @import("wayland");
const c = @import("c.zig").c;

const wl = wayland.client.wl;

const os = std.os;

pub const PoolBuffer = struct {
    buffer: ?*wl.Buffer = null,
    surface: ?*c.cairo_surface_t = null,
    cairo: ?*c.cairo_t = null,
    width: u32 = 0,
    height: u32 = 0,
    data: ?*anyopaque = null,
    size: usize = 0,
    busy: bool = false,

    const Self = @This();

    pub fn createBuffer(self: *Self, shm: *wl.Shm, width: i32, height: i32) !void {
        const wl_fmt = wl.Shm.Format.argb8888;
        const cairo_fmt = c.CAIRO_FORMAT_ARGB32;
        const stride: u32 = @intCast(c.cairo_format_stride_for_width(cairo_fmt, width));
        const size: usize = stride * @as(usize, @intCast(height));

        const fd = os.linux.memfd_create("/overlay", 0);
        defer _ = os.linux.close(@intCast(fd));

        _ = os.linux.ftruncate(@intCast(fd), @intCast(size));

        const data = os.linux.mmap(
            null,
            size,
            os.linux.PROT.READ | os.linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            @intCast(fd),
            0,
        );

        const pool = try shm.createPool(@intCast(fd), @intCast(size));
        self.buffer = try pool.createBuffer(0, width, height, @intCast(stride), wl_fmt);
        self.buffer.?.setListener(*PoolBuffer, bufferHandleRelease, self);
        pool.destroy();

        self.data = @ptrFromInt(data);
        self.size = size;
        self.width = @intCast(width);
        self.height = @intCast(height);
        self.surface = c.cairo_image_surface_create_for_data(
            @ptrCast(self.data),
            cairo_fmt,
            width,
            height,
            @intCast(stride),
        );
        self.cairo = c.cairo_create(self.surface);
    }

    pub fn finishBuffer(self: *Self) void {
        if (self.buffer) |b| {
            b.destroy();
        }
        if (self.cairo) |cr| {
            c.cairo_destroy(cr);
        }
        if (self.surface) |s| {
            c.cairo_surface_destroy(s);
        }
        if (self.data) |data| {
            const aligned_data: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(data));
            _ = os.linux.munmap(aligned_data, self.size);
        }
        self.* = .{};
    }

    pub fn bufferHandleRelease(_: *wl.Buffer, _: wl.Buffer.Event, buffer: *PoolBuffer) void {
        buffer.busy = false;
    }
};
