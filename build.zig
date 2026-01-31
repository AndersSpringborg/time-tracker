const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // DuckDB paths for development (dynamic linking)
    const duckdb_include_path: std.Build.LazyPath = .{ .cwd_relative = "/opt/homebrew/opt/duckdb/include" };
    const duckdb_lib_path: std.Build.LazyPath = .{ .cwd_relative = "/opt/homebrew/opt/duckdb/lib" };

    // --- Shared modules ---
    const event_module = b.createModule(.{
        .root_source_file = b.path("src/core/domain/event.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tracker_module = b.createModule(.{
        .root_source_file = b.path("src/core/tracking/tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "event", .module = event_module },
        },
    });

    const duckdb_repo_module = b.createModule(.{
        .root_source_file = b.path("src/core/storage/duckdb_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "event", .module = event_module },
        },
    });
    duckdb_repo_module.addIncludePath(duckdb_include_path);
    duckdb_repo_module.addLibraryPath(duckdb_lib_path);

    // --- 1. Compile Zig to object file ---
    const zig_obj = b.addObject(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "event", .module = event_module },
                .{ .name = "tracker", .module = tracker_module },
                .{ .name = "duckdb_repository", .module = duckdb_repo_module },
            },
        }),
    });
    zig_obj.root_module.addIncludePath(duckdb_include_path);
    zig_obj.root_module.addLibraryPath(duckdb_lib_path);

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
        "-L",         "/opt/homebrew/opt/duckdb/lib",
        "-lduckdb",   "-lc++",
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

    // --- Test step ---
    const test_step = b.step("test", "Run unit tests");

    // Event tests
    const event_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/domain/event_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "event", .module = event_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(event_tests).step);

    // Tracker tests
    const tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/tracking/tracker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "event", .module = event_module },
                .{ .name = "tracker", .module = tracker_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tracker_tests).step);

    // DuckDB Repository tests
    const duckdb_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/storage/duckdb_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "event", .module = event_module },
            },
        }),
    });
    duckdb_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    duckdb_repo_tests.linkSystemLibrary2("duckdb", .{ .preferred_link_mode = .dynamic });
    duckdb_repo_tests.linkLibCpp();
    test_step.dependOn(&b.addRunArtifact(duckdb_repo_tests).step);
}
