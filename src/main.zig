const std = @import("std");
const wayland = @import("wayland");
const c = @cImport({
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STBI_ONLY_PNG", "1");  // Only PNG support
    @cDefine("STBI_NO_SIMD", "1");
    @cInclude("stb_image.h");
    @cInclude("dbus/dbus.h");
});

const wl = wayland.client.wl;
const wl_server = wayland.server.wl;
const xdg = wayland.client.xdg;

const mem = std.mem;
const os = std.os;

const EventInterfaces = enum {
    wl_compositor,
    wl_output,
    wl_shm,
    xdg_wm_base,
    wl_seat,
};

const Context = struct {
    const Self = @This();

    wl_compositor: ?*wl.Compositor = null,
    wl_shm: ?*wl.Shm = null,
    wl_surface: ?*wl.Surface = null,
    wl_output: ?*wl.Output = null,
    xdg_surface: ?*xdg.Surface = null,
    xdg_toplevel: ?*xdg.Toplevel = null,
    xdg_wm_base: ?*xdg.WmBase = null,
    wl_seat: ?*wl.Seat = null,
    wl_keyboard: ?*wl.Keyboard = null,

    currentRect: *const Rectangle,
    image: ?[*c]u8 = null,
};

const Rectangle = struct {
    width: i32,
    height: i32,
    stride: i32,
    size: i32,
    color: u32,
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

    const width: i32 = 400;
    const height: i32 = 400;
    const stride: i32 = width * 4;
    const size: i32 = stride * height;
    const color: u32 = 0x0000FF;

    const rect: Rectangle = .{
        .width = width,
        .height = height,
        .stride = stride,
        .size = size,
        .color = color,
    };
    var context: Context = .{
        .currentRect = &rect,
    };

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

    std.debug.print("Loaded screenshot: {}x{}\n", .{image_width, image_height});

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

    context.xdg_surface = try context.xdg_wm_base.?.getXdgSurface(context.wl_surface.?);
    context.xdg_surface.?.setListener(*Context, xdg_surface_listener, &context);

    context.xdg_toplevel = try context.xdg_surface.?.getToplevel();
    context.xdg_toplevel.?.setListener(*Context, xdg_toplevel_listener, &context);
    context.xdg_toplevel.?.setTitle("Wayland Rectangle");

    context.wl_surface.?.commit();

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    while (true) {
        _ = display.dispatch();
    }
}

fn draw(context: *Context) !void {
    const shm_name = "/wayland-shm-XXXXXX";
    const fd = os.linux.memfd_create(shm_name, 0);
    defer _ = os.linux.close(@intCast(fd));

    _ = os.linux.ftruncate(@intCast(fd), context.currentRect.size);

    const data = os.linux.mmap(
        null,
        @intCast(context.currentRect.size),
        os.linux.PROT.READ | os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED },
        @intCast(fd),
        0,
    );
    defer _ = os.linux.munmap(@ptrFromInt(data), @intCast(context.currentRect.size));

    const byte_slice = @as([*]u8, @ptrFromInt(data))[0..@intCast(context.currentRect.size)];
    const pixels = std.mem.bytesAsSlice(u32, byte_slice);
    for (pixels) |*pixel| {
        pixel.* = context.currentRect.color;
    }

    const pool = try context.wl_shm.?.createPool(@intCast(fd), context.currentRect.size);
    const buffer = try pool.createBuffer(0, context.currentRect.width, context.currentRect.height, context.currentRect.stride, .argb8888);

    pool.destroy();

    buffer.setListener(*Context, wl_buffer_listener, context);

    context.wl_surface.?.attach(buffer, 0, 0);
    context.wl_surface.?.damage(0, 0, context.currentRect.width, context.currentRect.height);
    context.wl_surface.?.commit();
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, wayshot: *Context) void {
    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_compositor => {
                    wayshot.wl_compositor = registry.bind(
                        global.name,
                        wl.Compositor,
                        wl.Compositor.generated_version,
                    ) catch @panic("Failed to bind wl_compositor");
                    std.log.info("Got compositor event", .{});
                },
                .wl_output => {
                    wayshot.wl_output = registry.bind(
                        global.name,
                        wl.Output,
                        wl.Output.generated_version,
                    ) catch @panic("Failed to bind wl_output");
                    std.log.info("Got wl_output event", .{});
                },
                .wl_shm => {
                    wayshot.wl_shm = registry.bind(
                        global.name,
                        wl.Shm,
                        wl.Shm.generated_version,
                    ) catch @panic("Failed to bind wl_shm");
                    std.log.info("Got wl_shm event", .{});
                },
                .wl_seat => {
                    wayshot.wl_seat = registry.bind(
                        global.name,
                        wl.Seat,
                        wl.Seat.generated_version,
                    ) catch @panic("Failed to bind wl_seat");
                    wayshot.wl_seat.?.setListener(*Context, seat_listener, wayshot);
                    std.log.info("wl_seat event", .{});
                },
                .xdg_wm_base => {
                    wayshot.xdg_wm_base = registry.bind(
                        global.name,
                        xdg.WmBase,
                        xdg.WmBase.generated_version,
                    ) catch @panic("Failed to bind xdg_wm_base");
                    wayshot.xdg_wm_base.?.setListener(*Context, wm_base_listener, wayshot);
                    std.log.info("xdg_wm_base event", .{});
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

fn wm_base_listener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Context) void {
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
        },
    }
}

fn xdg_surface_listener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, shutter: *Context) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            draw(shutter) catch return;
        },
    }
}

fn xdg_toplevel_listener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, _: *Context) void {
    switch (event) {
        .configure => {},
        .close => {
            std.process.exit(0);
        },
    }
}

fn seat_listener(seat: *wl.Seat, event: wl.Seat.Event, shutter: *Context) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard) {
                shutter.wl_keyboard = seat.getKeyboard() catch return;
                shutter.wl_keyboard.?.setListener(*Context, keyboard_listener, shutter);
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
