const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");

    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.19", .{});

    const wayway = b.addExecutable(.{
        .name = "wayway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("wayway/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    wayway.linkLibC();
    wayway.linkSystemLibrary("wayland-client");
    wayway.linkSystemLibrary("dbus-1");
    wayway.linkSystemLibrary("wayland-cursor");

    wayway.root_module.addImport("wayland", wayland);
    wayway.root_module.addImport("xkbcommon", xkbcommon);
    wayway.root_module.addImport("pixman", pixman);
    wayway.root_module.addImport("wlroots", wlroots);

    wayway.addIncludePath(.{ .cwd_relative = "/usr/include/dbus-1.0" });
    wayway.addIncludePath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/dbus-1.0/include" });
    wayway.addIncludePath(.{ .cwd_relative = "/usr/lib/dbus-1.0/include" });

    b.installArtifact(wayway);
    const run_exe = b.addRunArtifact(wayway);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
