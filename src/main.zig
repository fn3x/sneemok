const std = @import("std");
const wayland = @import("wayland");
const c = @cImport({
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STBI_ONLY_PNG", "1");
    @cDefine("STBI_NO_SIMD", "1");
    @cInclude("stb_image.h");
    @cInclude("dbus/dbus.h");
});

const wl = wayland.client.wl;
const wl_server = wayland.server.wl;
const zwlr = wayland.client.zwlr;

const mem = std.mem;
const os = std.os;

const EventInterfaces = enum {
    wl_compositor,
    wl_output,
    wl_shm,
    wl_seat,
    zwlr_layer_shell_v1,
    wl_subcompositor,
};

const Context = struct {
    wl_compositor: ?*wl.Compositor = null,
    wl_shm: ?*wl.Shm = null,
    wl_surface: ?*wl.Surface = null,
    wl_output: ?*wl.Output = null,
    wl_pointer: ?*wl.Pointer = null,
    wl_subcompositor: ?*wl.Subcompositor = null,
    wl_subsurface: ?*wl.Subsurface = null,
    wl_subsurface_surface: ?*wl.Surface = null,

    wl_seat: ?*wl.Seat = null,
    wl_keyboard: ?*wl.Keyboard = null,
    zwlr_layer_shell: ?*zwlr.LayerShellV1 = null,

    image: ?[*c]u8 = null,
    width: i32 = 0,
    height: i32 = 0,

    mouse_state: wl.Pointer.ButtonState = .released,

    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
};

pub fn main() !void {
    const conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, null);
    if (conn == null) {
        std.debug.print("Failed to connect to D-Bus\n", .{});
        return error.DBusConnectionNull;
    }
    defer c.dbus_connection_unref(conn);

    const available = try checkScreenshotPortal(conn);
    if (!available) {
        return error.ScreenshotPortalNotAvailable;
    }

    const uri = try getScreenshotURI(conn);
    std.log.info("uri: {s}", .{uri});

    var context: Context = .{};

    var image_width: c_int = undefined;
    var image_height: c_int = undefined;
    var channels: c_int = undefined;

    // Strip "file://" prefix (7 characters)
    const uri_str = std.mem.span(uri);
    const file_path = uri_str[7..];

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path});

    context.image = c.stbi_load(path_z.ptr, &image_width, &image_height, &channels, 4);
    if (context.image == null) {
        return error.ImageLoadFailed;
    }

    std.debug.print("Loaded screenshot: {}x{}\n", .{ image_width, image_height });

    context.width = @intCast(image_width);
    context.height = @intCast(image_height);

    var display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();

    registry.setListener(*Context, registry_listener, &context);

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    std.log.info("Wayland connection established", .{});

    context.wl_surface = try context.wl_compositor.?.createSurface();

    if (context.zwlr_layer_shell) |layer_shell| {
        const layer_surface = try layer_shell.getLayerSurface(
            context.wl_surface.?,
            null,
            .overlay,
            "screenshot-tool",
        );

        layer_surface.setListener(*Context, layer_surface_listener, &context);
        layer_surface.setSize(0, 0);
        layer_surface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        layer_surface.setKeyboardInteractivity(.exclusive);
        layer_surface.setExclusiveZone(-1);

        context.layer_surface = layer_surface;
    }

    const region = context.wl_compositor.?.createRegion() catch return;
    region.add(0, 0, context.width, context.height);
    context.wl_surface.?.setInputRegion(region);
    region.destroy();

    context.wl_surface.?.commit();

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    while (true) {
        _ = display.dispatch();
        std.log.debug("Pointer state: {any}", .{context.mouse_state});
    }
}

fn draw(context: *Context) !void {
    std.log.debug("Drawing main surface: {}x{}", .{ context.width, context.height });

    const shm_name = "/wayland-shm-main";
    const fd = os.linux.memfd_create(shm_name, 0);
    defer _ = os.linux.close(@intCast(fd));

    const width = context.width;
    const height = context.height;
    const stride = width * 4;
    const size = stride * height;

    _ = os.linux.ftruncate(@intCast(fd), size);

    const data = os.linux.mmap(
        null,
        @intCast(size),
        os.linux.PROT.READ | os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED },
        @intCast(fd),
        0,
    );
    defer _ = os.linux.munmap(@ptrFromInt(data), @intCast(size));

    const byte_slice = @as([*]u8, @ptrFromInt(data))[0..@intCast(size)];
    const image_bytes = @as([*]u8, @ptrCast(context.image))[0..@intCast(size)];
    @memcpy(byte_slice, image_bytes);

    const pool = try context.wl_shm.?.createPool(@intCast(fd), size);
    const buffer = try pool.createBuffer(0, width, height, stride, .abgr8888);

    pool.destroy();

    buffer.setListener(*Context, wl_buffer_listener, context);

    context.wl_surface.?.attach(buffer, 0, 0);
    context.wl_surface.?.damage(0, 0, context.width, context.height);
    context.wl_surface.?.commit();
}

fn drawOverlay(context: *Context) !void {
    std.log.debug("Drawing overlay surface: {}x{}", .{ context.width, context.height });

    const fd = os.linux.memfd_create("/wayland-shm-overlay", 0);
    defer _ = os.linux.close(@intCast(fd));

    const size = context.width * context.height * 4;
    _ = os.linux.ftruncate(@intCast(fd), size);

    const data = os.linux.mmap(
        null,
        @intCast(size),
        os.linux.PROT.READ | os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED },
        @intCast(fd),
        0,
    );
    defer _ = os.linux.munmap(@ptrFromInt(data), @intCast(size));

    const pixels = std.mem.bytesAsSlice(u32, @as([*]u8, @ptrFromInt(data))[0..@intCast(size)]);

    for (pixels) |*pixel| {
        pixel.* = 0x40000000;
    }

    const pool = try context.wl_shm.?.createPool(@intCast(fd), size);
    const buffer = try pool.createBuffer(0, context.width, context.height, context.width * 4, .argb8888);
    pool.destroy();

    context.wl_subsurface_surface.?.attach(buffer, 0, 0);
    context.wl_subsurface_surface.?.damage(0, 0, context.width, context.height);
    context.wl_subsurface_surface.?.commit();
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_compositor => {
                    context.wl_compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        wl.Compositor.generated_version,
                    ) catch @panic("Failed to bind wl_compositor");
                    std.log.info("Got compositor event", .{});
                },
                .wl_output => {
                    context.wl_output = registry.bind(
                        global.name,
                        wl.Output,
                        wl.Output.generated_version,
                    ) catch @panic("Failed to bind wl_output");
                    std.log.info("Got wl_output event", .{});
                },
                .wl_shm => {
                    context.wl_shm = registry.bind(
                        global.name,
                        wl.Shm,
                        wl.Shm.generated_version,
                    ) catch @panic("Failed to bind wl_shm");
                    std.log.info("Got wl_shm event", .{});
                },
                .wl_seat => {
                    context.wl_seat = registry.bind(
                        global.name,
                        wl.Seat,
                        wl.Seat.generated_version,
                    ) catch @panic("Failed to bind wl_seat");
                    context.wl_seat.?.setListener(*Context, seat_listener, context);
                    std.log.info("wl_seat event", .{});
                },
                .wl_subcompositor => {
                    context.wl_subcompositor = registry.bind(
                        global.name,
                        wl.Subcompositor,
                        wl.Subcompositor.generated_version,
                    ) catch @panic("Failed to bind wl_subcompositor");
                    std.log.info("Got wl_subcompositor", .{});
                },
                .zwlr_layer_shell_v1 => {
                    context.zwlr_layer_shell = registry.bind(
                        global.name,
                        zwlr.LayerShellV1,
                        zwlr.LayerShellV1.generated_version,
                    ) catch @panic("Failed to bind zwlr_layer_shell_v1");
                    std.log.info("zwlr_layer_shell_v1 event", .{});
                },
            }
        },
        .global_remove => {},
    }
}

fn wl_buffer_listener(buffer: *wl.Buffer, event: wl.Buffer.Event, _: *Context) void {
    switch (event) {
        .release => {
            buffer.destroy();
        },
    }
}

fn layer_surface_listener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, context: *Context) void {
    switch (event) {
        .configure => |configure| {
            std.log.debug("Layer surface configured: {}x{}", .{ configure.width, configure.height });
            layer_surface.ackConfigure(configure.serial);

            draw(context) catch return;

            if (context.wl_subsurface == null) {
                context.wl_subsurface_surface = context.wl_compositor.?.createSurface() catch return;
                context.wl_subsurface = context.wl_subcompositor.?.getSubsurface(context.wl_subsurface_surface.?, context.wl_surface.?) catch return;
                context.wl_subsurface.?.setPosition(0, 0);
                context.wl_subsurface.?.setDesync();

                drawOverlay(context) catch return;
            }
        },
        .closed => {
            std.process.exit(0);
        },
    }
}

fn seat_listener(seat: *wl.Seat, event: wl.Seat.Event, context: *Context) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard) {
                context.wl_keyboard = seat.getKeyboard() catch return;
                context.wl_keyboard.?.setListener(*Context, keyboard_listener, context);
                std.log.info("Keyboard capability available", .{});
            }

            if (caps.capabilities.pointer) {
                context.wl_pointer = seat.getPointer() catch return;
                context.wl_pointer.?.setListener(*Context, pointer_listener, context);
                std.log.info("Pointer capability available", .{});
            }
        },
        .name => {},
    }
}

fn keyboard_listener(_: *wl.Keyboard, event: wl.Keyboard.Event, _: *Context) void {
    switch (event) {
        .key => |key| {
            if (key.state == .pressed and key.key == 1) { // ESC key
                std.debug.print("ESC pressed, closing window", .{});
                std.process.exit(0);
            }
        },
        else => {},
    }
}

fn pointer_listener(_: *wl.Pointer, event: wl.Pointer.Event, context: *Context) void {
    switch (event) {
        .enter => |_| {},
        .leave => {},
        .motion => |_| {},
        .button => |button| {
            context.mouse_state = button.state;
        },
        .axis => {},
        .frame => {},
        else => {},
    }
}

fn checkScreenshotPortal(conn: ?*c.DBusConnection) !bool {
    std.log.debug("Checking screenshot portal", .{});

    const msg = c.dbus_message_new_method_call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames",
    );
    if (msg == null) {
        return error.MessageCreateFailed;
    }

    defer c.dbus_message_unref(msg);

    const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, 1000, null);
    if (reply == null) {
        return error.NoReply;
    }

    defer c.dbus_message_unref(reply);

    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &iter) == 0) {
        return false;
    }

    var array_iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&iter, &array_iter);

    while (c.dbus_message_iter_get_arg_type(&array_iter) != c.DBUS_TYPE_INVALID) {
        var name: [*c]const u8 = undefined;
        c.dbus_message_iter_get_basic(&array_iter, @ptrCast(&name));
        if (std.mem.eql(u8, std.mem.span(name), "org.freedesktop.portal.Desktop")) {
            return true;
        }
        _ = c.dbus_message_iter_next(&array_iter);
    }

    return false;
}

fn getScreenshotRequestHandle(conn: ?*c.DBusConnection) ![*c]const u8 {
    std.log.debug("Requesting screenshot handle via d-bus", .{});

    const msg = c.dbus_message_new_method_call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot",
        "Screenshot",
    );
    if (msg == null) {
        return error.MessageCreateFailed;
    }

    defer c.dbus_message_unref(msg);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(msg, &iter);

    const parent_window: [*c]const u8 = "";
    if (c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_STRING, @ptrCast(&parent_window)) == 0) {
        return error.AppendFailed;
    }

    var dict_iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&iter, c.DBUS_TYPE_ARRAY, "{sv}", &dict_iter) == 0) {
        return error.ContainerOpenFailed;
    }

    try appendDictBoolEntry(&dict_iter, "interactive", false);
    try appendDictBoolEntry(&dict_iter, "modal", false);

    if (c.dbus_message_iter_close_container(&iter, &dict_iter) == 0) {
        return error.ContainerCloseFailed;
    }

    const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, -1, null);
    if (reply == null) {
        std.log.err("Failed to get reply\n", .{});
        return error.NoReply;
    }
    defer c.dbus_message_unref(reply);

    var reply_iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &reply_iter) == 0) {
        return error.NoResponseData;
    }

    var request_handle: [*c]const u8 = undefined;
    c.dbus_message_iter_get_basic(&reply_iter, @ptrCast(&request_handle));

    return request_handle;
}

fn appendDictBoolEntry(dict_iter: *c.DBusMessageIter, key: [*c]const u8, value: bool) !void {
    var entry_iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(dict_iter, c.DBUS_TYPE_DICT_ENTRY, null, &entry_iter) == 0) {
        return error.DictEntryOpenFailed;
    }

    if (c.dbus_message_iter_append_basic(&entry_iter, c.DBUS_TYPE_STRING, @ptrCast(&key)) == 0) {
        return error.AppendKeyFailed;
    }

    var variant_iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_open_container(&entry_iter, c.DBUS_TYPE_VARIANT, "b", &variant_iter) == 0) {
        return error.VariantOpenFailed;
    }

    const bool_val: u32 = if (value) 1 else 0;
    if (c.dbus_message_iter_append_basic(&variant_iter, c.DBUS_TYPE_BOOLEAN, @ptrCast(&bool_val)) == 0) {
        return error.AppendValueFailed;
    }

    if (c.dbus_message_iter_close_container(&entry_iter, &variant_iter) == 0) {
        return error.VariantCloseFailed;
    }

    if (c.dbus_message_iter_close_container(dict_iter, &entry_iter) == 0) {
        return error.DictEntryCloseFailed;
    }
}

fn getScreenshotURI(conn: ?*c.DBusConnection) ![*c]const u8 {
    const request_handle = try getScreenshotRequestHandle(conn);
    std.log.debug("Request handle: {s}\n", .{request_handle});

    var buf: [512]u8 = undefined;
    const match_rule = try std.fmt.bufPrintZ(&buf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{request_handle});

    c.dbus_bus_add_match(conn, match_rule.ptr, null);
    c.dbus_connection_flush(conn);

    while (c.dbus_connection_read_write(conn, @intCast(2000)) != 0) {
        const message = c.dbus_connection_pop_message(conn);
        if (message == null) {
            continue;
        }
        defer c.dbus_message_unref(message);

        if (c.dbus_message_is_signal(message, "org.freedesktop.portal.Request", "Response") == 0) {
            continue;
        }

        var iter: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(message, &iter) == 0) {
            return error.DbusNoArguments;
        }

        var response_code: u32 = undefined;
        c.dbus_message_iter_get_basic(&iter, @ptrCast(&response_code));

        _ = c.dbus_message_iter_next(&iter);

        var dict_iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&iter, &dict_iter);

        while (c.dbus_message_iter_get_arg_type(&dict_iter) != c.DBUS_TYPE_INVALID) {
            var entry_iter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&dict_iter, &entry_iter);

            var key: [*c]const u8 = undefined;
            c.dbus_message_iter_get_basic(&entry_iter, @ptrCast(&key));

            _ = c.dbus_message_iter_next(&entry_iter);

            if (std.mem.eql(u8, std.mem.span(key), "uri")) {
                var variant_iter: c.DBusMessageIter = undefined;
                c.dbus_message_iter_recurse(&entry_iter, &variant_iter);

                var uri: [*c]const u8 = undefined;
                c.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&uri));

                return uri;
            }

            _ = c.dbus_message_iter_next(&dict_iter);
        }
    }

    return error.DbusTimeout;
}
