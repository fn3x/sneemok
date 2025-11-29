const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const DBus = @import("dbus.zig").DBus;
const AppState = @import("state.zig").AppState;
const Wayland = @import("wayland.zig").Wayland;

var shutdown_requested = std.atomic.Value(bool).init(false);

fn signalHandler(sig: i32) callconv(.c) void {
    shutdown_requested.store(true, .release);
    std.log.info("Shutdown signal ({d}) received", .{ sig });
}

pub fn main() !void {
    var sa = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &sa, null); // Ctrl+C
    posix.sigaction(posix.SIG.TERM, &sa, null); // kill/systemd
    posix.sigaction(posix.SIG.HUP, &sa, null); // terminal closed

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

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    var is_daemon: bool = false;
    var is_screenshot: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            is_daemon = true;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            is_screenshot = true;
        }
    }

    if (is_daemon and is_screenshot) {
        std.log.err("Called with mutually excluding arguments --daemon and --screenshot. Please, choose one or the other.", .{});
        std.process.exit(1);
        return;
    }

    if (!is_daemon or is_screenshot) {
        try sendCommand("Screenshot");
        return;
    }

    try runDaemon(allocator);
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

const DaemonContext = struct {
    allocator: Allocator,
    state: ?*AppState = null,
    wayland: ?*Wayland = null,
    dbus: *DBus,
    mutex: std.Thread.Mutex = .{},
};

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
        std.log.warn("Service already running", .{});
        return error.AlreadyRunning;
    }
    c.dbus_bus_add_match(
        dbus.conn,
        "type='method_call',destination='org.sneemok.Service'",
        null,
    );
    c.dbus_connection_flush(dbus.conn);

    std.log.info("Daemon running...", .{});

    var context = DaemonContext{
        .allocator = allocator,
        .dbus = &dbus,
    };

    const dbus_thread = try std.Thread.spawn(.{}, dbusListenerThread, .{&context});

    while (context.state == null or context.wayland == null) {
        if (shutdown_requested.load(.acquire)) {
            std.log.info("Shutdown requested before initialization", .{});
            dbus_thread.join();
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    std.log.info("State initialized, starting Wayland event loop", .{});

    while (context.state.?.running.load(.acquire) and !shutdown_requested.load(.acquire)) {
        const wayland_fd = context.state.?.wayland.?.display.?.getFd();

        _ = context.state.?.wayland.?.display.?.flush();

        var pollfds = [_]posix.pollfd{
            .{ .fd = wayland_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&pollfds, 100) catch break;

        if (ready > 0 and pollfds[0].revents & posix.POLL.IN != 0) {
            _ = context.state.?.wayland.?.display.?.dispatch();
        }
    }

    std.log.info("Daemon exiting...", .{});

    dbus_thread.join();

    context.mutex.lock();

    const state = context.state;
    const wayland = context.wayland;

    context.state = null;
    context.wayland = null;

    context.mutex.unlock();

    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (wayland) |w| {
        w.deinit();
        context.allocator.destroy(w);
    }
    if (state) |s| {
        s.deinit();
        context.allocator.destroy(s);
    }

    std.log.info("Cleanup complete", .{});
}

fn dbusListenerThread(context: *DaemonContext) void {
    std.log.info("D-Bus listener thread started", .{});

    while (!shutdown_requested.load(.acquire)) {
        _ = c.dbus_connection_read_write(context.dbus.conn, 100);

        while (c.dbus_connection_pop_message(context.dbus.conn)) |msg| {
            defer c.dbus_message_unref(msg);

            if (c.dbus_message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect") != 0) {
                const reply = c.dbus_message_new_method_return(msg);
                if (reply != null) {
                    var iter: c.DBusMessageIter = undefined;
                    c.dbus_message_iter_init_append(reply, &iter);
                    const xml_ptr: [*c]const u8 = introspect_xml.ptr;
                    _ = c.dbus_message_iter_append_basic(&iter, c.DBUS_TYPE_STRING, @ptrCast(&xml_ptr));
                    _ = c.dbus_connection_send(context.dbus.conn, reply, null);
                    c.dbus_message_unref(reply);
                    c.dbus_connection_flush(context.dbus.conn);
                }
                continue;
            }

            if (c.dbus_message_is_method_call(msg, "org.sneemok.Service", "Screenshot") != 0) {
                std.log.debug("Screenshot triggered!\n", .{});

                const reply = c.dbus_message_new_method_return(msg);
                if (reply != null) {
                    _ = c.dbus_connection_send(context.dbus.conn, reply, null);
                    c.dbus_message_unref(reply);
                    c.dbus_connection_flush(context.dbus.conn);
                }

                handleScreenshotRequest(context) catch |err| {
                    std.log.err("Failed to handle screenshot: {}", .{err});
                };
            }
        }
    }

    std.log.info("D-Bus listener thread exiting", .{});
}

fn handleScreenshotRequest(context: *DaemonContext) !void {
    context.mutex.lock();
    defer context.mutex.unlock();

    if (context.state) |state| {
        if (state.clipboard_mode.load(.acquire)) {
            std.log.info("Restoring from clipboard mode...", .{});

            const uri = try context.dbus.getScreenshotURI();
            const uri_str = std.mem.span(uri);
            const file_path = uri_str[7..];

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path});

            const surface = c.cairo_image_surface_create_from_png(path_z.ptr);
            if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
                return error.LoadFailed;
            }

            state.canvas.setImageSurface(surface.?);
            state.canvas.selection = null;
            state.canvas.elements.clearRetainingCapacity();

            if (state.canvas.cached_clipboard_png) |old_png| {
                state.allocator.free(old_png);
                state.canvas.cached_clipboard_png = null;
            }

            state.setTool(.selection);

            try state.exitClipboardMode();

            if (state.wayland) |wayland| {
                wayland.setAllOutputsDirty();
            }

            std.log.debug("New screenshot loaded", .{});
            return;
        }
    }

    const uri = try context.dbus.getScreenshotURI();
    std.log.debug("Screenshot URI: {s}", .{uri});

    const state = try context.allocator.create(AppState);
    state.* = AppState.init(context.allocator);
    context.state = state;

    const uri_str = std.mem.span(uri);
    const file_path = uri_str[7..];

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{file_path});

    const surface = c.cairo_image_surface_create_from_png(path_z.ptr);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        return error.LoadFailed;
    }

    state.canvas.setImageSurface(surface.?);

    const wayland = try context.allocator.create(Wayland);
    wayland.* = Wayland.init(context.allocator, state);
    state.wayland = wayland;
    context.wayland = wayland;

    try state.wayland.?.start();

    std.log.info("GUI initialized", .{});
}
