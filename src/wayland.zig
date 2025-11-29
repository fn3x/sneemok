const std = @import("std");
const WaylandLib = @import("wayland");
const AppState = @import("state.zig").AppState;
const Output = @import("output.zig").Output;

const Allocator = std.mem.Allocator;
const wl = WaylandLib.client.wl;
const zwlr = WaylandLib.client.zwlr;

const EventInterfaces = enum {
    wl_compositor,
    wl_output,
    wl_shm,
    wl_seat,
    zwlr_layer_shell_v1,
    wl_data_device_manager,
};

pub const KeyboardModifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const Wayland = struct {
    allocator: Allocator,

    state: *AppState,

    display: ?*wl.Display = null,
    registry: ?*wl.Registry = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,
    serial: ?u32 = null,
    pointer: ?*wl.Pointer = null,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_surface: ?*wl.Surface = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    data_device: ?*wl.DataDevice = null,
    data_source: ?*wl.DataSource = null,
    keyboard_modifiers: KeyboardModifiers = .{ .alt = false, .ctrl = false, .shift = false, .super = false },

    outputs: std.ArrayList(*Output),

    const Self = @This();

    pub fn init(allocator: Allocator, state: *AppState) Self {
        return .{
            .allocator = allocator,
            .outputs = std.ArrayList(*Output).empty,
            .state = state,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.outputs.items) |output| {
            if (output.layer_surface) |ls| ls.destroy();
            if (output.surface) |surf| surf.destroy();
            if (output.wl_output) |wo| wo.release();
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);

        if (self.keyboard) |kb| kb.release();
        if (self.pointer) |ptr| ptr.release();
        if (self.cursor_surface) |surface| surface.destroy();
        if (self.cursor_theme) |theme| theme.destroy();
        if (self.seat) |seat| seat.release();
        if (self.data_device) |dd| dd.release();
        if (self.data_device_manager) |ddm| ddm.destroy();

        if (self.layer_shell) |ls| ls.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.compositor) |comp| comp.destroy();
        if (self.registry) |reg| reg.destroy();
        if (self.display) |disp| disp.disconnect();
    }

    pub fn cleanupAfterCopy(self: *Wayland) void {
        std.log.info("Destroying GUI surfaces, keeping Wayland connection...", .{});

        // Destroy surfaces but KEEP the output objects and wl_output
        for (self.outputs.items) |output| {
            if (output.layer_surface) |ls| {
                ls.destroy();
                output.layer_surface = null;
            }
            if (output.surface) |surf| {
                surf.destroy();
                output.surface = null;
            }
        }

        if (self.keyboard) |kb| kb.release();
        self.keyboard = null;
        if (self.pointer) |ptr| ptr.release();
        self.pointer = null;
        if (self.cursor_surface) |surf| surf.destroy();
        self.cursor_surface = null;
        if (self.cursor_theme) |theme| theme.destroy();
        self.cursor_theme = null;

        // KEEP: display, registry, compositor, shm, layer_shell, seat,
        // data_device_manager, data_device, outputs list

        std.log.info("Surfaces destroyed, Wayland connection alive", .{});
    }

    pub fn start(self: *Self) !void {
        self.display = try wl.Display.connect(null);
        const display = self.display.?;

        self.registry = try display.getRegistry();
        self.registry.?.setListener(*Wayland, registryListener, self);

        _ = display.roundtrip();

        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            return error.MissingWaylandProtocols;
        }

        self.cursor_surface = try self.compositor.?.createSurface();
        self.cursor_theme = try wl.CursorTheme.load(null, 24, self.shm.?);

        for (self.outputs.items) |output| {
            output.state = self.state;
            output.surface = try self.compositor.?.createSurface();
            output.layer_surface = try self.layer_shell.?.getLayerSurface(
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
    }

    pub fn restoreAfterClipboard(self: *Wayland) !void {
        std.log.info("Creating fresh surfaces for new screenshot...", .{});

        if (self.seat) |seat| {
            self.keyboard = try seat.getKeyboard();
            self.keyboard.?.setListener(*Wayland, keyboardListener, self);

            self.pointer = try seat.getPointer();
            self.pointer.?.setListener(*Wayland, pointerListener, self);
        } else {
            return error.SeatLost;
        }

        if (self.compositor) |comp| {
            self.cursor_surface = try comp.createSurface();
        }
        if (self.shm) |shm| {
            self.cursor_theme = try wl.CursorTheme.load(null, 24, shm);
        }

        for (self.outputs.items) |output| {
            for (&output.buffers) |*buffer| {
                buffer.finishBuffer();
            }
            output.current_buffer = null;
            output.dirty = false;
            output.frame_callback = null;

            output.configured = false;

            output.surface = try self.compositor.?.createSurface();
            output.layer_surface = try self.layer_shell.?.getLayerSurface(
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

        std.log.info("Waiting for surfaces to configure...", .{});
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            _ = self.display.?.dispatchPending();
            _ = self.display.?.flush();

            var all_configured = true;
            for (self.outputs.items) |output| {
                if (!output.configured) {
                    all_configured = false;
                    break;
                }
            }

            if (all_configured) {
                std.log.info("All surfaces configured successfully", .{});
                break;
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        std.log.info("Wayland resources restored", .{});
    }

    pub fn setAllOutputsDirty(self: *Wayland) void {
        for (self.outputs.items) |output| {
            output.setOutputDirty();
        }
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, wayland: *Wayland) void {
    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, std.mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_compositor => {
                    wayland.compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        wl.Compositor.generated_version,
                    ) catch @panic("Failed to bind wl_compositor");
                    std.log.info("Binded wl_compositor", .{});
                },
                .wl_output => {
                    const output = wayland.allocator.create(Output) catch return;
                    output.* = .{};
                    output.wl_output = registry.bind(global.name, wl.Output, 3) catch return;
                    output.wl_output.?.setListener(*Output, outputListener, output);
                    wayland.outputs.append(wayland.allocator, output) catch return;

                    std.log.info("Binded wl_output", .{});
                },
                .wl_shm => {
                    wayland.shm = registry.bind(
                        global.name,
                        wl.Shm,
                        wl.Shm.generated_version,
                    ) catch @panic("Failed to bind wl_shm");
                    std.log.info("Binded wl_shm", .{});
                },
                .wl_seat => {
                    wayland.seat = registry.bind(
                        global.name,
                        wl.Seat,
                        wl.Seat.generated_version,
                    ) catch @panic("Failed to bind wl_seat");
                    wayland.seat.?.setListener(*Wayland, seatListener, wayland);
                    std.log.info("Binded wl_seat", .{});
                },
                .zwlr_layer_shell_v1 => {
                    wayland.layer_shell = registry.bind(
                        global.name,
                        zwlr.LayerShellV1,
                        zwlr.LayerShellV1.generated_version,
                    ) catch @panic("Failed to bind zwlr_layer_shell_v1");
                    std.log.info("Binded zwlr_layer_shell_v1", .{});
                },
                .wl_data_device_manager => {
                    wayland.data_device_manager = registry.bind(
                        global.name,
                        wl.DataDeviceManager,
                        wl.DataDeviceManager.generated_version,
                    ) catch @panic("Failed to bind wl_data_device_manager");
                    std.log.info("Binded wl_data_device_manager", .{});
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
            output.state.?.running.store(false, .release);
        },
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, wayland: *Wayland) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard) {
                wayland.keyboard = seat.getKeyboard() catch return;
                wayland.keyboard.?.setListener(*Wayland, keyboardListener, wayland);
                std.log.info("Keyboard capability available", .{});

                if (wayland.data_device_manager) |ddm| {
                    wayland.data_device = ddm.getDataDevice(seat) catch @panic("Error on getting wl_data_device");
                    std.log.info("Created data device", .{});
                }
            }

            if (caps.capabilities.pointer) {
                wayland.pointer = seat.getPointer() catch return;
                wayland.pointer.?.setListener(*Wayland, pointerListener, wayland);
                std.log.info("Pointer capability available", .{});
            }
        },
        .name => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, wayland: *Wayland) void {
    switch (event) {
        .key => |key| {
            wayland.serial = key.serial;

            if (key.state != .pressed) {
                return;
            }

            const ctrl_pressed = wayland.keyboard_modifiers.ctrl;

            if (ctrl_pressed and key.key == 46) { // 46 = 'c' key
                copySelectionToClipboard(wayland.state) catch |wayland_error| {
                    std.log.warn("Native Wayland clipboard failed ({})", .{wayland_error});
                };
                return;
            }

            if (key.state == .pressed) {
                switch (key.key) {
                    1 => { // ESC
                        if (wayland.state.current_tool != .selection) {
                            wayland.state.setTool(.selection);
                        } else {
                            wayland.state.running.store(false, .release);
                        }
                    },
                    31 => wayland.state.setTool(.selection), // 's' key
                    30 => wayland.state.setTool(.draw_arrow), // 'a' key
                    19 => wayland.state.setTool(.draw_rectangle), // 'r' key
                    46 => wayland.state.setTool(.draw_circle), // 'c' key
                    38 => wayland.state.setTool(.draw_line), // 'l' key
                    20 => wayland.state.setTool(.draw_text), // 't' key
                    else => {},
                }
                wayland.setAllOutputsDirty();
                updateCursorForTool(wayland.state);
            }
        },
        .modifiers => |mods| {
            wayland.keyboard_modifiers = .{
                .shift = (mods.mods_depressed & 1) != 0,
                .ctrl = (mods.mods_depressed & 4) != 0,
                .alt = (mods.mods_depressed & 8) != 0,
                .super = (mods.mods_depressed & 64) != 0,
            };
        },
        else => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, wayland: *Wayland) void {
    switch (event) {
        .enter => |enter| {
            wayland.state.pointer_x = @intCast(enter.surface_x.toInt());
            wayland.state.pointer_y = @intCast(enter.surface_y.toInt());
            wayland.serial = enter.serial;

            setCursor(wayland, "default");
        },
        .motion => |motion| {
            wayland.state.pointer_x = @intCast(motion.surface_x.toInt());
            wayland.state.pointer_y = @intCast(motion.surface_y.toInt());
            wayland.state.current_tool.onPointerMove(&wayland.state.canvas, wayland.state.pointer_x, wayland.state.pointer_y);

            updateCursorForTool(wayland.state);

            if (wayland.state.current_tool == .selection) {
                const sel_tool = &wayland.state.current_tool.selection;
                if (sel_tool.is_selecting or
                    (wayland.state.canvas.selection != null and wayland.state.canvas.selection.?.interaction != .none))
                {
                    wayland.setAllOutputsDirty();
                }
            } else {
                const is_drawing = switch (wayland.state.current_tool) {
                    .arrow => |tool| tool.is_drawing,
                    .rectangle => |tool| tool.is_drawing,
                    .circle => |tool| tool.is_drawing,
                    .line => |tool| tool.is_drawing,
                    else => false,
                };
                if (is_drawing) {
                    wayland.setAllOutputsDirty();
                }
            }
        },
        .button => |button| {
            wayland.serial = button.serial;

            if (button.button != 0x110) { // BTN_LEFT
                return;
            }

            switch (button.state) {
                .pressed => {
                    wayland.state.mouse_pressed = true;
                    wayland.state.current_tool.onPointerPress(&wayland.state.canvas, wayland.state.pointer_x, wayland.state.pointer_y);
                },
                .released => {
                    wayland.state.mouse_pressed = false;
                    wayland.state.current_tool.onPointerRelease(&wayland.state.canvas, wayland.state.pointer_x, wayland.state.pointer_y);
                },
                else => {},
            }

            wayland.setAllOutputsDirty();
            updateCursorForTool(wayland.state);
        },
        .axis => |axis| {
            const value = axis.value.toDouble();

            if (axis.axis != .vertical_scroll) {
                return;
            }

            if (wayland.state.tool_mode == .selection or wayland.state.tool_mode == .draw_text) {
                return;
            }

            if (value < 0.0) {
                wayland.state.current_tool.increaseThickness(2);
            } else {
                wayland.state.current_tool.decreaseThickness(2);
            }
        },
        .leave => |leave| {
            wayland.serial = leave.serial;
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

                if (state.clipboard_mode.load(.acquire)) {
                    state.canvas.writeCachedPngToFd(send.fd) catch |err| {
                        std.log.err("Failed to write cached PNG: {}", .{err});
                    };
                } else {
                    state.canvas.writeToPngFd(send.fd) catch |err| {
                        std.log.err("Error on writing selection to png fd {}", .{err});
                    };
                }
                std.log.debug("wl_data_source::copied to clipboard fd={d}", .{send.fd});
            }
        },
        .cancelled => {
            std.log.info("wl_data_source::clipboard selection cancelled (replaced by another copy)", .{});
            data_source.destroy();
            state.wayland.?.data_source = null;
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

    try state.canvas.cacheClipboardPng();

    const data_source = try state.wayland.?.data_device_manager.?.createDataSource();

    data_source.offer("image/png");
    data_source.setListener(*AppState, dataSourceListener, state);
    state.wayland.?.data_device.?.setSelection(data_source, state.wayland.?.serial.?);

    if (!state.clipboard_mode.load(.acquire)) {
        state.enterClipboardMode();
    } else {
        std.log.info("Already in clipboard mode, clipboard data updated", .{});
    }
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

fn setCursor(wayland: *Wayland, name: [:0]const u8) void {
    const theme = wayland.cursor_theme orelse return;
    const cursor_surface = wayland.cursor_surface orelse return;
    const pointer = wayland.pointer orelse return;

    const cursor = theme.getCursor(name) orelse return;
    const image = cursor.images[0];

    const buffer = image.getBuffer() catch return;

    cursor_surface.attach(buffer, 0, 0);
    cursor_surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    cursor_surface.commit();

    pointer.setCursor(
        wayland.serial.?,
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
        .draw_arrow, .draw_rectangle, .draw_circle, .draw_line => "crosshair",
    };

    setCursor(state.wayland.?, cursor_name);
}
