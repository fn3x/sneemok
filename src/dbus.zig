const std = @import("std");
const c = @import("c.zig").c;

pub const DBus = struct {
    conn: *c.struct_DBusConnection,

    const Self = @This();

    pub fn init() !Self {
        const conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, null);
        if (conn == null) {
            std.debug.print("Failed to connect to D-Bus\n", .{});
            return error.DBusConnectionNull;
        }

        return Self{
            .conn = conn.?,
        };
    }

    pub fn deinit(self: *Self) void {
        c.dbus_connection_unref(self.conn);
    }

    pub fn checkScreenshotPortal(self: *Self) !bool {
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

        const reply = c.dbus_connection_send_with_reply_and_block(self.conn, msg, 1000, null);
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

    fn getScreenshotRequestHandle(self: *Self) ![*c]const u8 {
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

        const reply = c.dbus_connection_send_with_reply_and_block(self.conn, msg, -1, null);
        if (reply == null) {
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

    pub fn getScreenshotURI(self: *Self) ![*c]const u8 {
        const start = std.time.milliTimestamp();

        const request_handle = try self.getScreenshotRequestHandle();

        const t1 = std.time.milliTimestamp();
        std.log.info("[0.1] Got screenshot request handle: {d}ms", .{t1 - start});

        var buf: [512]u8 = undefined;
        const match_rule = try std.fmt.bufPrintZ(&buf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{request_handle});

        c.dbus_bus_add_match(self.conn, match_rule.ptr, null);
        c.dbus_connection_flush(self.conn);

        const t2 = std.time.milliTimestamp();
        std.log.info("[0.2] Added bus match rule: {d}ms", .{t2 - t1});

        while (c.dbus_connection_read_write(self.conn, @intCast(2000)) != 0) {
            const message = c.dbus_connection_pop_message(self.conn);
            if (message == null) {
                continue;
            }
            defer c.dbus_message_unref(message);

            if (c.dbus_message_is_signal(message, "org.freedesktop.portal.Request", "Response") == 0) {
                continue;
            }

            const t3 = std.time.milliTimestamp();
            std.log.info("[0.3] Got portal response signal: {d}ms", .{t3 - t2});

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

                const t4 = std.time.milliTimestamp();
                std.log.info("[0.4] Checking name: {d}ms", .{t4 - t3});

                if (std.mem.eql(u8, std.mem.span(key), "uri")) {
                    var variant_iter: c.DBusMessageIter = undefined;
                    c.dbus_message_iter_recurse(&entry_iter, &variant_iter);

                    var uri: [*c]const u8 = undefined;
                    c.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&uri));

                    const t5 = std.time.milliTimestamp();
                    std.log.info("[0.5] Gor URI: {d}ms", .{t5 - t4});

                    return uri;
                }

                _ = c.dbus_message_iter_next(&dict_iter);
            }
        }

        return error.DbusTimeout;
    }
};

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
