const std = @import("std");
const wayland = @import("wayland");
const c = @import("c.zig").c;
const DBus = @import("dbus.zig").DBus;
const Buffer = @import("buffer.zig");
const State = @import("main.zig").State;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const mem = std.mem;
const os = std.os;

pub const HANDLE_SIZE: f64 = 30.0;

const HandleType = enum {
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

pub const Output = struct {
    wl_output: ?*wl.Output,
    state: ?*State,

    scale: i32 = 1,
    geometry: struct {
        x: i32 = 0,
        y: i32 = 0,
        width: i32 = 0,
        height: i32 = 0,
    } = .{},

    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,

    frame_callback: ?*wl.Callback = null,
    configured: bool = false,
    dirty: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    buffers: [2]Buffer.PoolBuffer = [_]Buffer.PoolBuffer{.{}} ** 2,
    current_buffer: ?*Buffer.PoolBuffer = null,

    const Self = @This();

    pub fn renderOutput(self: *Self) void {
        const state = self.state.?;
        const buffer = self.current_buffer orelse return;
        const cr = buffer.cairo;

        if (buffer.cairo == null) {
            return;
        }

        c.cairo_identity_matrix(cr);
        c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));

        const img_x = self.geometry.x;
        const img_y = self.geometry.y;
        const img_w = self.geometry.width;
        const img_h = self.geometry.height;

        if (img_x < state.image_width and img_y < state.image_height) {
            const src_x = @max(0, img_x);
            const src_y = @max(0, img_y);
            const src_w = @min(state.image_width - src_x, img_w);
            const src_h = @min(state.image_height - src_y, img_h);

            if (src_w > 0 and src_h > 0) {
                const img_surface = c.cairo_image_surface_create_for_data(
                    @ptrCast(state.image),
                    c.CAIRO_FORMAT_ARGB32,
                    state.image_width,
                    state.image_height,
                    state.image_width * 4,
                );
                defer c.cairo_surface_destroy(img_surface);

                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                c.cairo_set_source_surface(cr, img_surface, @floatFromInt(-img_x), @floatFromInt(-img_y));
                c.cairo_rectangle(cr, 0, 0, @floatFromInt(src_w), @floatFromInt(src_h));
                c.cairo_fill(cr);
            }
        }

        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.50);
        c.cairo_paint(cr);

        if (state.interaction_mode == .selecting) {
            const sel_x = @min(state.anchor_x, state.pointer_x);
            const sel_y = @min(state.anchor_y, state.pointer_y);
            const sel_w = @abs(state.pointer_x - state.anchor_x) + 1;
            const sel_h = @abs(state.pointer_y - state.anchor_y) + 1;

            const local_x: u32 = @intCast(sel_x - self.geometry.x);
            const local_y: u32 = @intCast(sel_y - self.geometry.y);

            if (sel_w > 1 and sel_h > 1 and
                local_x < self.width and local_y < self.height and
                local_x + sel_w > 0 and local_y + sel_h > 0)
            {
                const img_surface = c.cairo_image_surface_create_for_data(
                    @ptrCast(state.image),
                    c.CAIRO_FORMAT_ARGB32,
                    state.image_width,
                    state.image_height,
                    state.image_width * 4,
                );
                defer c.cairo_surface_destroy(img_surface);

                c.cairo_save(cr);
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                c.cairo_set_source_surface(cr, img_surface, @floatFromInt(-img_x), @floatFromInt(-img_y));
                c.cairo_rectangle(cr, @floatFromInt(local_x), @floatFromInt(local_y), @floatFromInt(sel_w), @floatFromInt(sel_h));
                c.cairo_fill(cr);
                c.cairo_restore(cr);

                c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);
                c.cairo_set_line_width(cr, 2.0);
                c.cairo_rectangle(cr, @floatFromInt(local_x), @floatFromInt(local_y), @floatFromInt(sel_w), @floatFromInt(sel_h));
                c.cairo_stroke(cr);
            }
        } else if (state.has_last_selection) {
            const local_x = state.last_selection_x - self.geometry.x;
            const local_y = state.last_selection_y - self.geometry.y;
            const sel_w = state.last_selection_width;
            const sel_h = state.last_selection_height;

            if (sel_w > 1 and sel_h > 1 and
                local_x < self.width and local_y < self.height and
                local_x + sel_w > 0 and local_y + sel_h > 0)
            {
                const img_surface = c.cairo_image_surface_create_for_data(
                    @ptrCast(state.image),
                    c.CAIRO_FORMAT_ARGB32,
                    state.image_width,
                    state.image_height,
                    state.image_width * 4,
                );
                defer c.cairo_surface_destroy(img_surface);

                c.cairo_save(cr);
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                c.cairo_set_source_surface(cr, img_surface, @floatFromInt(-img_x), @floatFromInt(-img_y));
                c.cairo_rectangle(cr, @floatFromInt(local_x), @floatFromInt(local_y), @floatFromInt(sel_w), @floatFromInt(sel_h));
                c.cairo_fill(cr);
                c.cairo_restore(cr);

                c.cairo_set_source_rgba(cr, 0.0, 1.0, 0.0, 1.0);
                c.cairo_set_line_width(cr, 1.0);
                c.cairo_rectangle(cr, @floatFromInt(local_x), @floatFromInt(local_y), @floatFromInt(sel_w), @floatFromInt(sel_h));
                c.cairo_stroke(cr);

                self.drawSelectionGUI(cr.?, local_x, local_y, sel_w, sel_h);
            }
        }
    }

    pub fn setOutputDirty(self: *Self) void {
        self.dirty = true;
        if (self.frame_callback != null) {
            return;
        }

        self.frame_callback = self.surface.?.frame() catch return;
        self.frame_callback.?.setListener(*Self, frameListener, self);
        self.surface.?.commit();
    }

    pub fn sendFrame(self: *Self) void {
        const state = self.state.?;

        if (!self.configured) {
            return;
        }

        const buffer_width = self.width * self.scale;
        const buffer_height = self.height * self.scale;

        self.current_buffer = Buffer.getNextBuffer(
            state.wl_shm.?,
            &self.buffers,
            buffer_width,
            buffer_height,
        );

        if (self.current_buffer == null) {
            return;
        }
        self.current_buffer.?.busy = true;

        self.renderOutput();

        if (state.selecting) {
            self.frame_callback = self.surface.?.frame() catch return;
            self.frame_callback.?.setListener(*Self, frameListener, self);
        }

        self.surface.?.attach(self.current_buffer.?.buffer, 0, 0);
        self.surface.?.damage(0, 0, self.width, self.height);
        self.surface.?.setBufferScale(self.scale);
        self.surface.?.commit();
        self.dirty = false;
    }

    pub fn drawSelectionGUI(
        _: *Self,
        cr: *c.cairo_t,
        local_x: i32,
        local_y: i32,
        sel_w: i32,
        sel_h: i32,
    ) void {
        const half_handle: f64 = HANDLE_SIZE / 2.0;

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

        // const state = self.state.?;

        for (handles) |handle| {
            const handle_type: HandleType = blk: {
                break :blk .normal;
            };

            drawHandle(cr, handle.x, handle.y, HANDLE_SIZE, handle_type);
        }

        drawDimensionsLabel(cr, lx, ly, w, h);
    }
};

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, output: *Output) void {
    switch (event) {
        .done => {
            callback.destroy();
            output.frame_callback = null;

            if (output.dirty) {
                output.sendFrame();
            }
        },
    }
}

fn drawHandle(cr: *c.cairo_t, x: f64, y: f64, size: f64, handle_type: HandleType) void {
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
