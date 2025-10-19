const std = @import("std");
const wayland = @import("wayland");

const c = @import("c.zig").c;
const DBus = @import("dbus.zig").DBus;
const PoolBuffer = @import("buffer.zig").PoolBuffer;
const Output = @import("output.zig").Output;

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

pub const State = struct {
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

fn setAllOutputsDirty(state: *State) void {
    for (state.outputs.items) |output| {
        output.setOutputDirty();
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

            output.sendFrame();
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
