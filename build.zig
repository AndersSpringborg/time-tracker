const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- 1. Compile Zig to object file ---
    const zig_obj = b.addObject(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // --- 2. Compile Swift Bridge to object file ---
    const swift_cmd = b.addSystemCommand(&.{
        "swiftc",
        "-emit-object",
        "-parse-as-library",
        "-O",
        "-o",
    });
    const swift_obj = swift_cmd.addOutputFileArg("macos_bridge.o");
    swift_cmd.addFileArg(b.path("src/bridge/macos_bridge.swift"));

    // --- 3. Link everything with swiftc (it knows how to find Swift runtime) ---
    const link_cmd = b.addSystemCommand(&.{"swiftc"});

    // Add Zig object file
    link_cmd.addArtifactArg(zig_obj);

    // Add Swift object file
    link_cmd.addFileArg(swift_obj);

    // Link frameworks
    link_cmd.addArgs(&.{
        "-framework", "Foundation",
        "-framework", "Cocoa",
        "-framework", "ApplicationServices",
    });

    // Output binary
    link_cmd.addArg("-o");
    const exe_output = link_cmd.addOutputFileArg("time_tracker");

    // --- 4. Install the binary ---
    const install = b.addInstallBinFile(exe_output, "time_tracker");
    b.getInstallStep().dependOn(&install.step);

    // --- Run step ---
    const run_step = b.step("run", "Run the tracker demo");
    const run_cmd = std.Build.Step.Run.create(b, &.{});
    run_cmd.addFileArg(exe_output);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(&install.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
