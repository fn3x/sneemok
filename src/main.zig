const std = @import("std");
const wayland = @import("wayland");
const c = @cImport({
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STBI_ONLY_PNG", "1");
    @cDefine("STBI_NO_SIMD", "1");
    @cInclude("stb_image.h");
    @cInclude("cairo/cairo.h");
});
const DBus = @import("dbus.zig").DBus;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const mem = std.mem;
const os = std.os;

const EventInterfaces = enum {
    wl_compositor,
    wl_output,
    wl_shm,
    wl_seat,
    zwlr_layer_shell_v1,
};

const PoolBuffer = struct {
    buffer: ?*wl.Buffer = null,
    surface: ?*c.cairo_surface_t = null,
    cairo: ?*c.cairo_t = null,
    width: u32 = 0,
    height: u32 = 0,
    data: ?*anyopaque = null,
    size: usize = 0,
    busy: bool = false,
};

const Output = struct {
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
    buffers: [2]PoolBuffer = [_]PoolBuffer{.{}} ** 2,
    current_buffer: ?*PoolBuffer = null,
};

const State = struct {
    allocator: std.mem.Allocator,
    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    wl_compositor: ?*wl.Compositor = null,
    wl_shm: ?*wl.Shm = null,
    wl_seat: ?*wl.Seat = null,
    wl_keyboard: ?*wl.Keyboard = null,
    wl_pointer: ?*wl.Pointer = null,
    zwlr_layer_shell: ?*zwlr.LayerShellV1 = null,

    outputs: std.ArrayList(*Output),

    image: ?[*c]u8 = null,
    image_width: i32 = 0,
    image_height: i32 = 0,

    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    selecting: bool = false,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,

    has_last_selection: bool = false,
    last_selection_x: i32 = 0,
    last_selection_y: i32 = 0,
    last_selection_width: i32 = 0,
    last_selection_height: i32 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus: DBus = try .init();
    defer dbus.deinit();

    const uri = try dbus.getScreenshotURI();
    std.log.info("uri: {s}", .{uri});

    var state = State{
        .allocator = allocator,
        .outputs = std.ArrayList(*Output).empty,
    };
    defer state.outputs.deinit(allocator);

    var image_width: c_int = undefined;
    var image_height: c_int = undefined;
    var channels: c_int = undefined;

    const uri_str = std.mem.span(uri);
    const file_path = uri_str[7..];

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path});

    state.image = c.stbi_load(path_z.ptr, &image_width, &image_height, &channels, 4);
    if (state.image == null) {
        return error.ImageLoadFailed;
    }

    std.debug.print("Loaded screenshot: {}x{}\n", .{ image_width, image_height });

    state.image_width = @intCast(image_width);
    state.image_height = @intCast(image_height);

    const pixel_count: usize = @intCast(image_width * image_height);
    const img_bytes: [*]u8 = @ptrCast(state.image);
    for (0..pixel_count) |i| {
        const idx = i * 4;
        const temp = img_bytes[idx];
        img_bytes[idx] = img_bytes[idx + 2];
        img_bytes[idx + 2] = temp;
    }

    var display = try wl.Display.connect(null);
    defer display.disconnect();

    state.display = display;

    const registry = try display.getRegistry();
    defer registry.destroy();

    registry.setListener(*State, registryListener, &state);

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    std.log.info("Wayland connection established", .{});

    for (state.outputs.items) |output| {
        output.surface = try state.wl_compositor.?.createSurface();

        output.layer_surface = try state.zwlr_layer_shell.?.getLayerSurface(
            output.surface.?,
            output.wl_output,
            .overlay,
            "screenshot-tool",
        );

        output.layer_surface.?.setListener(*Output, layerSurfaceListener, output);
        output.layer_surface.?.setSize(0, 0);
        output.layer_surface.?.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        output.layer_surface.?.setKeyboardInteractivity(.exclusive);
        output.layer_surface.?.setExclusiveZone(-1);

        output.surface.?.commit();
    }

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    while (true) {
        _ = display.dispatch();
    }
}

fn bufferHandleRelease(_: *wl.Buffer, _: wl.Buffer.Event, buffer: *PoolBuffer) void {
    buffer.busy = false;
}

fn createBuffer(shm: *wl.Shm, buf: *PoolBuffer, width: i32, height: i32) !void {
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
    buf.buffer = try pool.createBuffer(0, width, height, @intCast(stride), wl_fmt);
    buf.buffer.?.setListener(*PoolBuffer, bufferHandleRelease, buf);
    pool.destroy();

    buf.data = @ptrFromInt(data);
    buf.size = size;
    buf.width = @intCast(width);
    buf.height = @intCast(height);
    buf.surface = c.cairo_image_surface_create_for_data(
        @ptrCast(buf.data),
        cairo_fmt,
        width,
        height,
        @intCast(stride),
    );
    buf.cairo = c.cairo_create(buf.surface);
}

fn finishBuffer(buffer: *PoolBuffer) void {
    if (buffer.buffer) |b| {
        b.destroy();
    }
    if (buffer.cairo) |cr| {
        c.cairo_destroy(cr);
    }
    if (buffer.surface) |s| {
        c.cairo_surface_destroy(s);
    }
    if (buffer.data) |data| {
        const aligned_data: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(data));
        _ = os.linux.munmap(aligned_data, buffer.size);
    }
    buffer.* = .{};
}

fn getNextBuffer(shm: *wl.Shm, pool: []PoolBuffer, width: i32, height: i32) ?*PoolBuffer {
    var buffer: ?*PoolBuffer = null;
    for (pool) |*b| {
        if (b.busy) {
            continue;
        }
        buffer = b;
        break;
    }
    if (buffer == null) {
        return null;
    }

    if (buffer.?.width != width or buffer.?.height != height) {
        finishBuffer(buffer.?);
    }

    if (buffer.?.buffer == null) {
        createBuffer(shm, buffer.?, width, height) catch return null;
    }
    return buffer;
}

fn renderOutput(output: *Output) void {
    const state = output.state.?;
    const buffer = output.current_buffer orelse return;
    const cr = buffer.cairo orelse return;

    c.cairo_identity_matrix(cr);
    c.cairo_scale(cr, @floatFromInt(output.scale), @floatFromInt(output.scale));

    const img_x = output.geometry.x;
    const img_y = output.geometry.y;
    const img_w = output.geometry.width;
    const img_h = output.geometry.height;

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

    if (state.selecting) {
        const sel_x = @min(state.anchor_x, state.pointer_x);
        const sel_y = @min(state.anchor_y, state.pointer_y);
        const sel_w = @abs(state.pointer_x - state.anchor_x) + 1;
        const sel_h = @abs(state.pointer_y - state.anchor_y) + 1;

        const local_x: u32 = @intCast(sel_x - output.geometry.x);
        const local_y: u32 = @intCast(sel_y - output.geometry.y);

        if (sel_w > 1 and sel_h > 1 and
            local_x < output.width and local_y < output.height and
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
        const local_x = state.last_selection_x - output.geometry.x;
        const local_y = state.last_selection_y - output.geometry.y;
        const sel_w = state.last_selection_width;
        const sel_h = state.last_selection_height;

        if (sel_w > 1 and sel_h > 1 and
            local_x < output.width and local_y < output.height and
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
        }
    }
}

fn setOutputDirty(output: *Output) void {
    output.dirty = true;
    if (output.frame_callback != null) {
        return;
    }

    output.frame_callback = output.surface.?.frame() catch return;
    output.frame_callback.?.setListener(*Output, frameListener, output);
    output.surface.?.commit();
}

fn sendFrame(output: *Output) void {
    const state = output.state.?;

    if (!output.configured) {
        return;
    }

    const buffer_width = output.width * output.scale;
    const buffer_height = output.height * output.scale;

    output.current_buffer = getNextBuffer(
        state.wl_shm.?,
        &output.buffers,
        buffer_width,
        buffer_height,
    );
    if (output.current_buffer == null) {
        return;
    }
    output.current_buffer.?.busy = true;

    renderOutput(output);

    if (state.selecting) {
        output.frame_callback = output.surface.?.frame() catch return;
        output.frame_callback.?.setListener(*Output, frameListener, output);
    }

    output.surface.?.attach(output.current_buffer.?.buffer, 0, 0);
    output.surface.?.damage(0, 0, output.width, output.height);
    output.surface.?.setBufferScale(output.scale);
    output.surface.?.commit();
    output.dirty = false;
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, output: *Output) void {
    switch (event) {
        .done => {
            callback.destroy();
            output.frame_callback = null;

            if (output.dirty) {
                sendFrame(output);
            }
        },
    }
}

fn setAllOutputsDirty(state: *State) void {
    for (state.outputs.items) |output| {
        setOutputDirty(output);
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *State) void {
    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_compositor => {
                    state.wl_compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        wl.Compositor.generated_version,
                    ) catch @panic("Failed to bind wl_compositor");
                    std.log.info("Got compositor", .{});
                },
                .wl_output => {
                    const wl_output = registry.bind(
                        global.name,
                        wl.Output,
                        wl.Output.generated_version,
                    ) catch @panic("Failed to bind wl_output");

                    const output = state.allocator.create(Output) catch @panic("OOM");
                    output.* = .{
                        .wl_output = wl_output,
                        .state = state,
                    };
                    state.outputs.append(state.allocator, output) catch @panic("OOM");

                    wl_output.setListener(*Output, outputListener, output);
                    std.log.info("Got wl_output", .{});
                },
                .wl_shm => {
                    state.wl_shm = registry.bind(
                        global.name,
                        wl.Shm,
                        wl.Shm.generated_version,
                    ) catch @panic("Failed to bind wl_shm");
                    std.log.info("Got wl_shm", .{});
                },
                .wl_seat => {
                    state.wl_seat = registry.bind(
                        global.name,
                        wl.Seat,
                        wl.Seat.generated_version,
                    ) catch @panic("Failed to bind wl_seat");
                    state.wl_seat.?.setListener(*State, seatListener, state);
                    std.log.info("Got wl_seat", .{});
                },
                .zwlr_layer_shell_v1 => {
                    state.zwlr_layer_shell = registry.bind(
                        global.name,
                        zwlr.LayerShellV1,
                        zwlr.LayerShellV1.generated_version,
                    ) catch @panic("Failed to bind zwlr_layer_shell_v1");
                    std.log.info("Got zwlr_layer_shell_v1", .{});
                },
            }
        },
        .global_remove => {},
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .geometry => |geom| {
            output.geometry.x = geom.x;
            output.geometry.y = geom.y;
        },
        .mode => |mode| {
            if (mode.flags.current) {
                output.geometry.width = mode.width;
                output.geometry.height = mode.height;
            }
        },
        .scale => |scale| {
            output.scale = scale.factor;
        },
        .done => {},
        else => {},
    }
}

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, output: *Output) void {
    switch (event) {
        .configure => |configure| {
            std.log.debug("Layer surface configured: {}x{}", .{ configure.width, configure.height });
            layer_surface.ackConfigure(configure.serial);

            output.configured = true;
            output.width = @intCast(configure.width);
            output.height = @intCast(configure.height);

            sendFrame(output);
        },
        .closed => {
            std.process.exit(0);
        },
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, state: *State) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard) {
                state.wl_keyboard = seat.getKeyboard() catch return;
                state.wl_keyboard.?.setListener(*State, keyboardListener, state);
                std.log.info("Keyboard capability available", .{});
            }

            if (caps.capabilities.pointer) {
                state.wl_pointer = seat.getPointer() catch return;
                state.wl_pointer.?.setListener(*State, pointerListener, state);
                std.log.info("Pointer capability available", .{});
            }
        },
        .name => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, state: *State) void {
    switch (event) {
        .key => |key| {
            if (key.state == .pressed) {
                if (key.key == 1) { // ESC
                    std.debug.print("ESC pressed, exiting\n", .{});
                    std.process.exit(0);
                } else if (key.key == 28) { // ENTER
                    if (state.has_last_selection) {
                        std.debug.print("{d},{d} {d}x{d}\n", .{
                            state.last_selection_x,
                            state.last_selection_y,
                            state.last_selection_width,
                            state.last_selection_height,
                        });
                        std.process.exit(0);
                    }
                }
            }
        },
        else => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, state: *State) void {
    switch (event) {
        .enter => |enter| {
            state.pointer_x = @intCast(enter.surface_x.toInt());
            state.pointer_y = @intCast(enter.surface_y.toInt());
        },
        .motion => |motion| {
            state.pointer_x = @intCast(motion.surface_x.toInt());
            state.pointer_y = @intCast(motion.surface_y.toInt());

            if (state.selecting) {
                setAllOutputsDirty(state);
            }
        },
        .button => |button| {
            if (button.button == 0x110) { // BTN_LEFT
                if (button.state == .pressed) {
                    state.selecting = true;
                    state.anchor_x = state.pointer_x;
                    state.anchor_y = state.pointer_y;
                    setAllOutputsDirty(state);
                } else if (button.state == .released and state.selecting) {
                    state.selecting = false;

                    const x = @min(state.anchor_x, state.pointer_x);
                    const y = @min(state.anchor_y, state.pointer_y);
                    const w = @abs(state.pointer_x - state.anchor_x) + 1;
                    const h = @abs(state.pointer_y - state.anchor_y) + 1;

                    if (w > 1 and h > 1) {
                        state.has_last_selection = true;
                        state.last_selection_x = x;
                        state.last_selection_y = y;
                        state.last_selection_width = @intCast(w);
                        state.last_selection_height = @intCast(h);

                        std.log.info("Selection: {d},{d} {d}x{d}", .{ x, y, w, h });
                        setAllOutputsDirty(state);
                    }
                }
            }
        },
        .frame => {},
        else => {},
    }
}
