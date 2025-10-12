const std = @import("std");
const wayland = @import("wayland");
const c = @cImport({
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

const Wayway = struct {
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

    var display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();

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

    var wayway: Wayway = .{
        .currentRect = &rect,
    };

    registry.setListener(*Wayway, registry_listener, &wayway);

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    std.log.info("connection established!", .{});

    wayway.wl_surface = try wayway.wl_compositor.?.createSurface();

    wayway.xdg_surface = try wayway.xdg_wm_base.?.getXdgSurface(wayway.wl_surface.?);
    wayway.xdg_surface.?.setListener(*Wayway, xdg_surface_listener, &wayway);

    wayway.xdg_toplevel = try wayway.xdg_surface.?.getToplevel();
    wayway.xdg_toplevel.?.setListener(*Wayway, xdg_toplevel_listener, &wayway);
    wayway.xdg_toplevel.?.setTitle("Wayland Rectangle");

    wayway.wl_surface.?.commit();

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundTripFailed;
    }

    while (true) {
        _ = display.dispatch();
    }
}

fn draw(wayway: *Wayway) !void {
    const shm_name = "/wayland-shm-XXXXXX";
    const fd = os.linux.memfd_create(shm_name, 0);
    defer _ = os.linux.close(@intCast(fd));

    _ = os.linux.ftruncate(@intCast(fd), wayway.currentRect.size);

    const data = os.linux.mmap(
        null,
        @intCast(wayway.currentRect.size),
        os.linux.PROT.READ | os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED },
        @intCast(fd),
        0,
    );
    defer _ = os.linux.munmap(@ptrFromInt(data), @intCast(wayway.currentRect.size));

    const byte_slice = @as([*]u8, @ptrFromInt(data))[0..@intCast(wayway.currentRect.size)];
    const pixels = std.mem.bytesAsSlice(u32, byte_slice);
    for (pixels) |*pixel| {
        pixel.* = wayway.currentRect.color;
    }

    const pool = try wayway.wl_shm.?.createPool(@intCast(fd), wayway.currentRect.size);
    const buffer = try pool.createBuffer(0, wayway.currentRect.width, wayway.currentRect.height, wayway.currentRect.stride, .argb8888);

    pool.destroy();

    buffer.setListener(*Wayway, wl_buffer_listener, wayway);

    wayway.wl_surface.?.attach(buffer, 0, 0);
    wayway.wl_surface.?.damage(0, 0, wayway.currentRect.width, wayway.currentRect.height);
    wayway.wl_surface.?.commit();
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, wayshot: *Wayway) void {
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
                    wayshot.wl_seat.?.setListener(*Wayway, seat_listener, wayshot);
                    std.log.info("wl_seat event", .{});
                },
                .xdg_wm_base => {
                    wayshot.xdg_wm_base = registry.bind(
                        global.name,
                        xdg.WmBase,
                        xdg.WmBase.generated_version,
                    ) catch @panic("Failed to bind xdg_wm_base");
                    wayshot.xdg_wm_base.?.setListener(*Wayway, wm_base_listener, wayshot);
                    std.log.info("xdg_wm_base event", .{});
                },
            }
        },
        .global_remove => {},
    }
}

fn wl_buffer_listener(buffer: *wl.Buffer, event: wl.Buffer.Event, _: *Wayway) void {
    switch (event) {
        .release => {
            buffer.destroy();
        },
    }
}

fn wm_base_listener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Wayway) void {
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
        },
    }
}

fn xdg_surface_listener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, wayway: *Wayway) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            draw(wayway) catch return;
        },
    }
}

fn xdg_toplevel_listener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, _: *Wayway) void {
    switch (event) {
        .configure => {},
        .close => {
            std.process.exit(0);
        },
    }
}

fn seat_listener(seat: *wl.Seat, event: wl.Seat.Event, wayway: *Wayway) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard) {
                wayway.wl_keyboard = seat.getKeyboard() catch return;
                wayway.wl_keyboard.?.setListener(*Wayway, keyboard_listener, wayway);
            }
        },
        .name => {},
    }
}

fn keyboard_listener(_: *wl.Keyboard, event: wl.Keyboard.Event, _: *Wayway) void {
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
