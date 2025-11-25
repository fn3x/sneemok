const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const DBus = @import("dbus.zig").DBus;
const AppState = @import("state.zig").AppState;
const Wayland = @import("wayland.zig").Wayland;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaks = gpa.deinit();
        switch (leaks) {
            .ok => {},
            .leak => {
                std.log.err("Memory leaks detected!", .{});
            },
        }
    }

    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch return;
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--daemon")) {
            try runDaemon(allocator);
        } else if (std.mem.eql(u8, args[1], "--screenshot")) {
            try sendCommand("Screenshot");
        } else if (std.mem.eql(u8, args[1], "--help")) {}
    } else {}
}

fn sendCommand(method: [*c]const u8) !void {
    const conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, null);
    if (conn == null) return error.ConnectionFailed;
    defer c.dbus_connection_unref(conn);

    const msg = c.dbus_message_new_method_call(
        "org.sneemok.Service",
        "/org/sneemok/service",
        "org.sneemok.Service",
        method,
    );
    if (msg == null) return error.MessageFailed;
    defer c.dbus_message_unref(msg);

    const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, 1000, null);
    if (reply != null) {
        c.dbus_message_unref(reply);
    }
}

const introspect_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect">
    \\      <arg name="xml" type="s" direction="out"/>
    \\    </method>
    \\  </interface>
    \\  <interface name="org.sneemok.Service">
    \\    <method name="Screenshot"/>
    \\  </interface>
    \\</node>
;

fn runDaemon(allocator: Allocator) !void {
    var dbus = try DBus.init();
    defer dbus.deinit();

    const available = try dbus.checkScreenshotPortal();
    if (!available) {
        return error.ScreenshotPortalNotAvailable;
    }

    const ret = c.dbus_bus_request_name(
        dbus.conn,
        "org.sneemok.Service",
        c.DBUS_NAME_FLAG_REPLACE_EXISTING,
        null,
    );
    if (ret != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        std.debug.print("Service already running\n", .{});
        return error.AlreadyRunning;
    }
    c.dbus_bus_add_match(
        dbus.conn,
        "type='method_call',destination='org.sneemok.Service'",
        null,
    );
    c.dbus_connection_flush(dbus.conn);

    std.debug.print("Daemon running...\n", .{});

    while (true) {
        _ = c.dbus_connection_read_write(dbus.conn, 100);

        while (c.dbus_connection_pop_message(dbus.conn)) |msg| {
            defer c.dbus_message_unref(msg);

            if (c.dbus_message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect") != 0) {
                // Reply with minimal introspection data
                const reply = c.dbus_message_new_method_return(msg);
                if (reply != null) {
                    var iter: c.DBusMessageIter = undefined;
                    c.dbus_message_iter_init_append(reply, &iter);
                    const xml_ptr: [*c]const u8 = introspect_xml.ptr;
                    _ = c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_STRING, @ptrCast(&xml_ptr));
                    _ = c.dbus_connection_send(dbus.conn, reply, null);
                    c.dbus_message_unref(reply);
                    c.dbus_connection_flush(dbus.conn);
                }
                continue;
            }

            if (c.dbus_message_is_method_call(msg, "org.sneemok.Service", "Screenshot") != 0) {
                std.debug.print("Screenshot triggered!\n", .{});

                const reply = c.dbus_message_new_method_return(msg);
                if (reply != null) {
                    _ = c.dbus_connection_send(dbus.conn, reply, null);
                    c.dbus_message_unref(reply);
                    c.dbus_connection_flush(dbus.conn);
                }

                gui(allocator, &dbus) catch |err| {
                    std.debug.print("GUI error: {}\n", .{err});
                };
            }
        }
    }
}

pub fn gui(allocator: Allocator, dbus: *DBus) !void {
    const uri = try dbus.getScreenshotURI();

    std.log.info("Screenshot URI: {s}", .{uri});

    var state = AppState.init(allocator);
    defer state.deinit();

    const uri_str = std.mem.span(uri);
    const file_path = uri_str[7..]; // Remove "file://" prefix

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path});

    const surface = c.cairo_image_surface_create_from_png(path_z.ptr);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        return error.LoadFailed;
    }

    state.canvas.setImageSurface(surface.?);

    var wayland = Wayland.init(allocator, &state);
    state.wayland = &wayland;
    defer state.wayland.?.deinit();

    try state.wayland.?.start();

    while (state.running) {
        _ = state.wayland.?.display.?.dispatch();
    }
}

