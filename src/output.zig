const std = @import("std");
const wayland = @import("wayland");
const c = @import("c.zig").c;
const Buffer = @import("buffer.zig");
const AppState = @import("state.zig").AppState;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

pub const Output = struct {
    wl_output: ?*wl.Output = null,
    state: ?*AppState = null,

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
        const cr = buffer.cairo orelse return;

        c.cairo_identity_matrix(cr);
        c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));

        const img_x = self.geometry.x;
        const img_y = self.geometry.y;
        const img_w = self.geometry.width;
        const img_h = self.geometry.height;

        if (img_x < state.canvas.width and img_y < state.canvas.height) {
            const src_x = @max(0, img_x);
            const src_y = @max(0, img_y);
            const src_w = @min(state.canvas.width - src_x, img_w);
            const src_h = @min(state.canvas.height - src_y, img_h);

            if (src_w > 0 and src_h > 0) {
                if (state.canvas.image) |image| {
                    const img_surface = c.cairo_image_surface_create_for_data(
                        @ptrCast(image),
                        c.CAIRO_FORMAT_ARGB32,
                        state.canvas.width,
                        state.canvas.height,
                        state.canvas.width * 4,
                    );
                    defer c.cairo_surface_destroy(img_surface);

                    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                    c.cairo_set_source_surface(cr, img_surface, @floatFromInt(-img_x), @floatFromInt(-img_y));
                    c.cairo_paint(cr);
                }
            }
        }

        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.50);
        c.cairo_paint(cr);

        if (state.current_tool == .selection) {
            const sel_tool = &state.current_tool.selection;

            if (sel_tool.is_selecting) {
                const sel_x = @min(sel_tool.anchor_x, sel_tool.last_pointer_x);
                const sel_y = @min(sel_tool.anchor_y, sel_tool.last_pointer_y);
                const sel_w = @abs(sel_tool.last_pointer_x - sel_tool.anchor_x) + 1;
                const sel_h = @abs(sel_tool.last_pointer_y - sel_tool.anchor_y) + 1;

                const local_x: u32 = @intCast(sel_x - self.geometry.x);
                const local_y: u32 = @intCast(sel_y - self.geometry.y);

                if (sel_w >= 1 and sel_h >= 1 and
                    local_x < self.width and local_y < self.height and
                    local_x + sel_w > 0 and local_y + sel_h > 0)
                {
                    if (state.canvas.image) |image| {
                        const img_surface = c.cairo_image_surface_create_for_data(
                            @ptrCast(image),
                            c.CAIRO_FORMAT_ARGB32,
                            state.canvas.width,
                            state.canvas.height,
                            state.canvas.width * 4,
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
                }
            }
        }

        if (state.canvas.selection) |sel| {
            if (state.canvas.image) |image| {
                const local_x = sel.x - self.geometry.x;
                const local_y = sel.y - self.geometry.y;

                if (sel.width >= 1 and sel.height >= 1 and
                    local_x < self.width and local_y < self.height and
                    local_x + sel.width > 0 and local_y + sel.height > 0)
                {
                    const img_surface = c.cairo_image_surface_create_for_data(
                        @ptrCast(image),
                        c.CAIRO_FORMAT_ARGB32,
                        state.canvas.width,
                        state.canvas.height,
                        state.canvas.width * 4,
                    );
                    defer c.cairo_surface_destroy(img_surface);

                    c.cairo_save(cr);
                    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                    c.cairo_set_source_surface(cr, img_surface, @floatFromInt(-img_x), @floatFromInt(-img_y));
                    c.cairo_rectangle(
                        cr,
                        @floatFromInt(local_x),
                        @floatFromInt(local_y),
                        @floatFromInt(sel.width),
                        @floatFromInt(sel.height),
                    );
                    c.cairo_fill(cr);
                    c.cairo_restore(cr);

                    c.cairo_set_source_rgba(cr, 0.0, 1.0, 0.0, 1.0);
                    c.cairo_set_line_width(cr, 1.0);
                    c.cairo_rectangle(
                        cr,
                        @floatFromInt(local_x),
                        @floatFromInt(local_y),
                        @floatFromInt(sel.width),
                        @floatFromInt(sel.height),
                    );
                    c.cairo_stroke(cr);
                }
            }
        }

        for (state.canvas.elements.items) |*element| {
            element.render(cr, self.geometry.x, self.geometry.y);
        }

        state.current_tool.render(cr, &state.canvas, self.geometry.x, self.geometry.y);
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
            state.shm.?,
            &self.buffers,
            buffer_width,
            buffer_height,
        );

        if (self.current_buffer == null) {
            return;
        }
        self.current_buffer.?.busy = true;

        self.renderOutput();

        self.surface.?.attach(self.current_buffer.?.buffer, 0, 0);
        self.surface.?.damage(0, 0, self.width, self.height);
        self.surface.?.setBufferScale(self.scale);
        self.surface.?.commit();
        self.dirty = false;
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
