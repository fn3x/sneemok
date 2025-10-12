const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 1);
    scanner.generate("ext_image_copy_capture_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

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
    wayway.root_module.addImport("wayland", wayland);

    b.installArtifact(wayway);
    const run_exe = b.addRunArtifact(wayway);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
