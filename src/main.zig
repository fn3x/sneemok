const std = @import("std");
const wayland = @import("wayland");
const c = @import("c.zig").c;
const DBus = @import("dbus.zig").DBus;
const AppState = @import("state.zig").AppState;
const Output = @import("state.zig").Output;
const ToolMode = @import("state.zig").ToolMode;

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const EventInterfaces = enum {
    wl_compositor,
    wl_output,
    wl_shm,
    wl_seat,
    zwlr_layer_shell_v1,
    wl_data_device_manager,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dbus: DBus = try .init();
    defer dbus.deinit();

    const uri = try dbus.getScreenshotURI();
    std.log.info("Screenshot URI: {s}", .{uri});

    var state = AppState.init(allocator);
    defer state.deinit();

    var image_width: c_int = undefined;
    var image_height: c_int = undefined;
    var channels: c_int = undefined;

    const uri_str = std.mem.span(uri);
    const file_path = uri_str[7..]; // Remove "file://" prefix

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path});

    const image = c.stbi_load(path_z.ptr, &image_width, &image_height, &channels, 4);
    if (image == null) {
        return error.ImageLoadFailed;
    }

    // Convert RGBA to BGRA for Cairo
    const pixel_count: usize = @intCast(image_width * image_height);
    const img_bytes: [*]u8 = @ptrCast(image);
    for (0..pixel_count) |i| {
        const idx = i * 4;
        const temp = img_bytes[idx];
        img_bytes[idx] = img_bytes[idx + 2];
        img_bytes[idx + 2] = temp;
    }

    state.canvas.setImage(image, image_width, image_height);
    std.log.info("Loaded image: {}x{}", .{ image_width, image_height });

    state.display = try wl.Display.connect(null);
    const display = state.display.?;

    state.registry = try display.getRegistry();
    state.registry.?.setListener(*AppState, registryListener, &state);

    _ = display.roundtrip();

    if (state.compositor == null or state.shm == null or state.layer_shell == null) {
        return error.MissingWaylandProtocols;
    }

    state.cursor_surface = try state.compositor.?.createSurface();
    state.cursor_theme = try wl.CursorTheme.load(null, 24, state.shm.?);

    for (state.outputs.items) |output| {
        output.state = &state;
        output.surface = try state.compositor.?.createSurface();
        output.layer_surface = try state.layer_shell.?.getLayerSurface(
            output.surface.?,
            output.wl_output,
            .overlay,
            "screenshot",
        );

        output.layer_surface.?.setListener(*Output, layerSurfaceListener, output);
        output.layer_surface.?.setSize(0, 0);
        output.layer_surface.?.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        output.layer_surface.?.setExclusiveZone(-1);
        output.layer_surface.?.setKeyboardInteractivity(.exclusive);

        output.surface.?.commit();
    }

    _ = display.roundtrip();

    while (state.running) {
        _ = display.dispatch();
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *AppState) void {
    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, std.mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_compositor => {
                    state.compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        wl.Compositor.generated_version,
                    ) catch @panic("Failed to bind wl_compositor");
                    std.log.info("Got compositor", .{});
                },
                .wl_output => {
                    const output = state.allocator.create(Output) catch return;
                    output.* = .{};
                    output.wl_output = registry.bind(global.name, wl.Output, 3) catch return;
                    output.wl_output.?.setListener(*Output, outputListener, output);
                    state.outputs.append(state.allocator, output) catch return;

                    std.log.info("Got wl_output", .{});
                },
                .wl_shm => {
                    state.shm = registry.bind(
                        global.name,
                        wl.Shm,
                        wl.Shm.generated_version,
                    ) catch @panic("Failed to bind wl_shm");
                    std.log.info("Got wl_shm", .{});
                },
                .wl_seat => {
                    state.seat = registry.bind(
                        global.name,
                        wl.Seat,
                        wl.Seat.generated_version,
                    ) catch @panic("Failed to bind wl_seat");
                    state.seat.?.setListener(*AppState, seatListener, state);
                    std.log.info("Got wl_seat", .{});
                },
                .zwlr_layer_shell_v1 => {
                    state.layer_shell = registry.bind(
                        global.name,
                        zwlr.LayerShellV1,
                        zwlr.LayerShellV1.generated_version,
                    ) catch @panic("Failed to bind zwlr_layer_shell_v1");
                    std.log.info("Got zwlr_layer_shell_v1", .{});
                },
                .wl_data_device_manager => {
                    state.data_device_manager = registry.bind(
                        global.name,
                        wl.DataDeviceManager,
                        wl.DataDeviceManager.generated_version,
                    ) catch @panic("Failed to bind wl_data_device_manager");
                    std.log.info("Got wl_data_device_manager", .{});
                },
            }
        },
        .global_remove => {},
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .geometry => |geo| {
            output.geometry.x = geo.x;
            output.geometry.y = geo.y;
            output.geometry.width = geo.physical_width;
            output.geometry.height = geo.physical_height;
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
            std.log.debug("Layer surface configured ({d}): {}x{}", .{ configure.serial, configure.width, configure.height });
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

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, state: *AppState) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard) {
                state.keyboard = seat.getKeyboard() catch return;
                state.keyboard.?.setListener(*AppState, keyboardListener, state);
                std.log.info("Keyboard capability available", .{});

                if (state.data_device_manager) |ddm| {
                    state.data_device = ddm.getDataDevice(seat) catch @panic("Error on getting wl_data_device");
                    std.log.info("Created data device", .{});
                }
            }

            if (caps.capabilities.pointer) {
                state.pointer = seat.getPointer() catch return;
                state.pointer.?.setListener(*AppState, pointerListener, state);
                std.log.info("Pointer capability available", .{});
            }
        },
        .name => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, state: *AppState) void {
    switch (event) {
        .key => |key| {
            state.serial = key.serial;

            if (key.state != .pressed) {
                return;
            }

            const ctrl_pressed = state.keyboard_modifiers.ctrl;

            if (ctrl_pressed and key.key == 46) { // 46 = 'c' key
                copySelectionToClipboardPersistent(state) catch |wlcopy_error| {
                    std.log.warn("wl-copy failed ({}), falling back to native Wayland clipboard", .{wlcopy_error});

                    // Fallback to native Wayland clipboard
                    copySelectionToClipboard(state) catch |wayland_error| {
                        std.log.warn("Native Wayland clipboard failed ({})", .{wayland_error});
                    };
                };
                state.running = false;
                return;
            }

            if (key.state == .pressed) {
                switch (key.key) {
                    1 => { // ESC
                        if (state.current_tool != .selection) {
                            state.setTool(.selection);
                        } else {
                            state.running = false;
                        }
                    },
                    31 => state.setTool(.selection), // 's' key
                    30 => state.setTool(.draw_arrow), // 'a' key
                    19 => state.setTool(.draw_rectangle), // 'r' key
                    46 => state.setTool(.draw_circle), // 'c' key
                    38 => state.setTool(.draw_line), // 'l' key
                    20 => state.setTool(.draw_text), // 't' key
                    else => {},
                }
                state.setAllOutputsDirty();
            }
        },
        .modifiers => |mods| {
            state.keyboard_modifiers = .{
                .shift = (mods.mods_depressed & 1) != 0,
                .ctrl = (mods.mods_depressed & 4) != 0,
                .alt = (mods.mods_depressed & 8) != 0,
                .super = (mods.mods_depressed & 64) != 0,
            };
        },
        else => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, state: *AppState) void {
    switch (event) {
        .enter => |enter| {
            state.pointer_x = @intCast(enter.surface_x.toInt());
            state.pointer_y = @intCast(enter.surface_y.toInt());
            state.serial = enter.serial;

            setCursor(state, "default");
        },
        .motion => |motion| {
            state.pointer_x = @intCast(motion.surface_x.toInt());
            state.pointer_y = @intCast(motion.surface_y.toInt());
            state.current_tool.onPointerMove(&state.canvas, state.pointer_x, state.pointer_y);

            updateCursorForTool(state);

            if (state.current_tool == .selection) {
                const sel_tool = &state.current_tool.selection;
                if (sel_tool.is_selecting or
                    (state.canvas.selection != null and state.canvas.selection.?.interaction != .none))
                {
                    state.setAllOutputsDirty();
                }
            } else {
                const is_drawing = switch (state.current_tool) {
                    .arrow => |tool| tool.is_drawing,
                    .rectangle => |tool| tool.is_drawing,
                    .circle => |tool| tool.is_drawing,
                    .line => |tool| tool.is_drawing,
                    else => false,
                };
                if (is_drawing) {
                    state.setAllOutputsDirty();
                }
            }
        },
        .button => |button| {
            state.serial = button.serial;

            if (button.button != 0x110) { // BTN_LEFT
                return;
            }

            switch (button.state) {
                .pressed => {
                    state.mouse_pressed = true;
                    state.current_tool.onPointerPress(&state.canvas, state.pointer_x, state.pointer_y);
                },
                .released => {
                    state.mouse_pressed = false;
                    state.current_tool.onPointerRelease(&state.canvas, state.pointer_x, state.pointer_y);
                },
                else => {},
            }

            state.setAllOutputsDirty();
            updateCursorForTool(state);
        },
        .axis => |axis| {
            const value = axis.value.toDouble();

            if (axis.axis != .vertical_scroll) {
                return;
            }

            if (state.tool_mode == .selection or state.tool_mode == .draw_text) {
                return;
            }

            if (value < 0.0) {
                state.current_tool.increaseThickness(2);
            } else {
                state.current_tool.decreaseThickness(2);
            }
        },
        .leave => |leave| {
            state.serial = leave.serial;
        },
        .frame => {},
        else => {},
    }
}

fn dataSourceListener(data_source: *wl.DataSource, event: wl.DataSource.Event, state: *AppState) void {
    switch (event) {
        .send => |send| {
            if (std.mem.eql(u8, std.mem.span(send.mime_type), "image/png")) {
                defer std.posix.close(send.fd);
                state.canvas.writeToPngFd(send.fd) catch |err| {
                    std.log.err("Error on writing selection to png fd {}", .{err});
                };
                std.log.debug("wl_data_source::copied to clipboard fd={d}", .{send.fd});
            }
        },
        .cancelled => {
            std.log.info("wl_data_source::clipboard selection cancelled (replaced by another copy)", .{});
            data_source.destroy();
        },
        else => |ev| {
            std.log.debug("wl_data_source::event {}", .{ev});
        },
    }
}

pub fn copySelectionToClipboard(state: *AppState) !void {
    if (state.canvas.selection == null) {
        return;
    }

    const data_source = try state.data_device_manager.?.createDataSource();

    data_source.offer("image/png");
    data_source.setListener(*AppState, dataSourceListener, state);
    state.data_device.?.setSelection(data_source, state.serial.?);
}

pub fn copySelectionToClipboardPersistent(state: *AppState) !void {
    if (state.canvas.selection == null) return;

    const argv = [_][]const u8{ "wl-copy", "--type", "image/png" };

    var child = std.process.Child.init(&argv, state.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    if (child.stdin) |stdin| {
        state.canvas.writeToPngFd(stdin.handle) catch {};
        stdin.close();
        child.stdin = null;
    }

    _ = try child.wait();
}

fn setCursor(state: *AppState, name: [:0]const u8) void {
    const theme = state.cursor_theme orelse return;
    const cursor_surface = state.cursor_surface orelse return;
    const pointer = state.pointer orelse return;

    const cursor = theme.getCursor(name) orelse return;
    const image = cursor.images[0];

    const buffer = image.getBuffer() catch return;

    cursor_surface.attach(buffer, 0, 0);
    cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    cursor_surface.commit();

    pointer.setCursor(
        state.serial.?,
        cursor_surface,
        @intCast(image.hotspot_x),
        @intCast(image.hotspot_y),
    );
}

fn updateCursorForTool(state: *AppState) void {
    const cursor_name = switch (state.tool_mode) {
        .selection, .draw_text => blk: {
            if (state.mouse_pressed) {
                if (state.canvas.selection) |sel| {
                    const handle = sel.getHandleAt(state.pointer_x, state.pointer_y);

                    break :blk switch (handle) {
                        .none => "left_ptr",
                        .nw => "bottom_right_corner",
                        .se => "bottom_right_corner",
                        .ne => "bottom_left_corner",
                        .sw => "bottom_left_corner",
                        .n => "sb_up_arrow",
                        .s => "sb_down_arrow",
                        .w => "sb_left_arrow",
                        .e => "sb_right_arrow",
                        .move => "hand1",
                    };
                }
            }
            break :blk "left_ptr";
        },
        .draw_arrow, .draw_rectangle, .draw_circle, .draw_line => "diamond_cross",
    };

    setCursor(state, cursor_name);
}
