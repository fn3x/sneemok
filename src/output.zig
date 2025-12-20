const std = @import("std");
const wayland = @import("wayland");
const c = @import("c.zig").c;
const Buffer = @import("buffer.zig");
const AppState = @import("state.zig").AppState;

const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;

pub const Output = struct {
    wl_output: ?*wl.Output = null,
    state: ?*AppState = null,

    scale: f32 = 1.0,
    buffer_scale: i32 = 1.0,
    geometry: struct {
        x: i32 = 0,
        y: i32 = 0,
        width: i32 = 0,
        height: i32 = 0,
    } = .{},

    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    fractional_scale: ?*wp.FractionalScaleV1 = null,
    viewport: ?*wp.Viewport = null,
    scale_ready: bool = false,

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

        const s: f64 = @floatCast(self.scale);
        const phys_x = @as(f64, @floatFromInt(self.geometry.x)) * s;
        const phys_y = @as(f64, @floatFromInt(self.geometry.y)) * s;

        c.cairo_identity_matrix(cr);

        // 1. Background
        if (state.canvas.image_surface) |img_surface| {
            c.cairo_save(cr);
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
            c.cairo_set_source_surface(cr, img_surface, -phys_x, -phys_y);
            c.cairo_paint(cr);
            c.cairo_restore(cr);
        }

        // 2. Dark Overlay
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.50);
        c.cairo_paint(cr);

        // 3. Clear Selection (Punch through)
        if (state.canvas.image_surface) |img_surface| {
            var active_sel: ?struct { x: i32, y: i32, w: i32, h: i32 } = null;
            if (state.current_tool == .selection and state.current_tool.selection.is_selecting) {
                const tool = state.current_tool.selection;
                active_sel = .{
                    .x = @min(tool.anchor_x, tool.last_pointer_x),
                    .y = @min(tool.anchor_y, tool.last_pointer_y),
                    .w = @intCast(@abs(tool.last_pointer_x - tool.anchor_x)),
                    .h = @intCast(@abs(tool.last_pointer_y - tool.anchor_y)),
                };
            } else if (state.canvas.selection) |sel| {
                active_sel = .{ .x = sel.x, .y = sel.y, .w = sel.width, .h = sel.height };
            }

            if (active_sel) |sel| {
                c.cairo_save(cr);
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                // Must use physical offsets and identity matrix to stay 1:1
                c.cairo_set_source_surface(cr, img_surface, -phys_x, -phys_y);

                const rect_x = @as(f64, @floatFromInt(sel.x - self.geometry.x)) * s;
                const rect_y = @as(f64, @floatFromInt(sel.y - self.geometry.y)) * s;
                const rect_w = @as(f64, @floatFromInt(sel.w)) * s;
                const rect_h = @as(f64, @floatFromInt(sel.h)) * s;

                c.cairo_rectangle(cr, rect_x, rect_y, rect_w, rect_h);
                c.cairo_fill(cr);
                c.cairo_restore(cr);
            }
        }

        // 4. UI Scaling
        c.cairo_scale(cr, s, s);

        // 5. Tool Borders and Elements
        if (state.canvas.selection) |sel| {
            const local_x: f64 = @floatFromInt(sel.x - self.geometry.x);
            const local_y: f64 = @floatFromInt(sel.y - self.geometry.y);
            c.cairo_set_source_rgba(cr, 0.0, 1.0, 0.0, 1.0);
            c.cairo_set_line_width(cr, 1.0 / s); // Keeps border thin on HiDPI
            c.cairo_rectangle(cr, local_x, local_y, @floatFromInt(sel.width), @floatFromInt(sel.height));
            c.cairo_stroke(cr);
        }

        for (state.canvas.elements.items) |*element| {
            element.render(cr, self.geometry.x, self.geometry.y);
        }
        state.current_tool.render(cr, &state.canvas, self.geometry.x, self.geometry.y);
    }

    pub fn setOutputDirty(self: *Self) void {
        self.dirty = true;

        if (self.frame_callback != null or self.surface == null) {
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

        // --- The Anti-Flicker Fix ---
        // If we have a fractional scale manager but haven't received the event yet,
        // attach a 1x1 dummy buffer to "poke" the compositor to send the scale.
        if (!self.scale_ready and state.wayland.?.fractional_scale_manager != null) {
            const dummy = Buffer.getNextBuffer(state.wayland.?.shm.?, &self.buffers, 1, 1) orelse return;

            if (dummy.cairo) |cr| {
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
                c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
                c.cairo_paint(cr);
            }

            self.surface.?.attach(dummy.buffer, 0, 0);
            self.surface.?.commit();
            return;
        }

        const buffer_width: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(self.width)) * self.scale));
        const buffer_height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(self.height)) * self.scale));

        self.current_buffer = Buffer.getNextBuffer(
            state.wayland.?.shm.?,
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
        self.surface.?.setBufferScale(1);

        if (self.viewport) |viewport| {
            viewport.setDestination(self.width, self.height);
        }

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
