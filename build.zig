const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const flatbufferz_dep = b.dependency("flatbufferz", .{
        .target = target,
        .optimize = optimize,
    });
    const flatbufferz_module = flatbufferz_dep.module("flatbufferz");

    const duckdb_include_path: std.Build.LazyPath = .{ .cwd_relative = "vendor/duckdb/include" };
    const duckdb_lib_path: std.Build.LazyPath = .{ .cwd_relative = "vendor/duckdb/lib" };

    const domain_glob_module = b.createModule(.{
        .root_source_file = b.path("src/domain/glob.zig"),
        .target = target,
        .optimize = optimize,
    });

    const domain_event_module = b.createModule(.{
        .root_source_file = b.path("src/domain/event.zig"),
        .target = target,
        .optimize = optimize,
    });

    const domain_rule_module = b.createModule(.{
        .root_source_file = b.path("src/domain/rule.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glob", .module = domain_glob_module },
        },
    });

    const domain_hierarchy_module = b.createModule(.{
        .root_source_file = b.path("src/domain/hierarchy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rule_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/rule_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_rule", .module = domain_rule_module },
        },
    });

    const hierarchy_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/hierarchy_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_hierarchy", .module = domain_hierarchy_module },
        },
    });

    const event_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/event_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
        },
    });

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glob", .module = domain_glob_module },
        },
    });

    const tracker_module = b.createModule(.{
        .root_source_file = b.path("src/application/services/tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
        },
    });

    const event_dto_generated_module = b.createModule(.{
        .root_source_file = b.path("src/external/dto/flatbuffers/EventDTO.fb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flatbufferz", .module = flatbufferz_module },
        },
    });

    const event_dto_mapper_module = b.createModule(.{
        .root_source_file = b.path("src/external/dto/event_mapper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flatbufferz", .module = flatbufferz_module },
            .{ .name = "event_dto_generated", .module = event_dto_generated_module },
            .{ .name = "domain_event", .module = domain_event_module },
        },
    });

    const migrations_module = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/migrations.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrations_module.addIncludePath(duckdb_include_path);
    migrations_module.addLibraryPath(duckdb_lib_path);

    const legacy_repo_module = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/legacy_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    legacy_repo_module.addIncludePath(duckdb_include_path);
    legacy_repo_module.addLibraryPath(duckdb_lib_path);

    const buffered_repo_module = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/buffered_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "legacy_repository", .module = legacy_repo_module },
        },
    });
    buffered_repo_module.addIncludePath(duckdb_include_path);
    buffered_repo_module.addLibraryPath(duckdb_lib_path);

    const duckdb_rule_repository = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/rule_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_rule", .module = domain_rule_module },
            .{ .name = "rule_repository", .module = rule_repository_interface },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    duckdb_rule_repository.addIncludePath(duckdb_include_path);
    duckdb_rule_repository.addLibraryPath(duckdb_lib_path);

    const duckdb_hierarchy_repository = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/hierarchy_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hierarchy_repository", .module = hierarchy_repository_interface },
            .{ .name = "domain_hierarchy", .module = domain_hierarchy_module },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    duckdb_hierarchy_repository.addIncludePath(duckdb_include_path);
    duckdb_hierarchy_repository.addLibraryPath(duckdb_lib_path);

    const duckdb_event_repository = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/event_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "event_repository", .module = event_repository_interface },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    duckdb_event_repository.addIncludePath(duckdb_include_path);
    duckdb_event_repository.addLibraryPath(duckdb_lib_path);

    const worker_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_module },
            .{ .name = "migrations", .module = migrations_module },
            .{ .name = "tracker", .module = tracker_module },
            .{ .name = "buffered_repository", .module = buffered_repo_module },
            .{ .name = "duckdb_rule_repository", .module = duckdb_rule_repository },
            .{ .name = "duckdb_hierarchy_repository", .module = duckdb_hierarchy_repository },
            .{ .name = "duckdb_event_repository", .module = duckdb_event_repository },
            .{ .name = "event_dto_mapper", .module = event_dto_mapper_module },
        },
    });
    worker_module.addIncludePath(duckdb_include_path);
    worker_module.addLibraryPath(duckdb_lib_path);

    const zig_obj = b.addObject(.{
        .name = "main",
        .root_module = worker_module,
    });

    const swift_cmd = b.addSystemCommand(&.{
        "swiftc",
        "-emit-object",
        "-parse-as-library",
        "-O",
        "-o",
    });
    const swift_obj = swift_cmd.addOutputFileArg("macos_bridge.o");
    swift_cmd.addFileArg(b.path("src/bridge/macos_bridge.swift"));

    const link_cmd = b.addSystemCommand(&.{"swiftc"});
    link_cmd.addArtifactArg(zig_obj);
    link_cmd.addFileArg(swift_obj);
    link_cmd.addArgs(&.{
        "-framework", "Foundation",
        "-framework", "Cocoa",
        "-framework", "ApplicationServices",
        "-framework", "CoreWLAN",
        "-L", "vendor/duckdb/lib",
        "-lduckdb_static",
        "-lcore_functions_extension",
        "-licu_extension",
        "-ljson_extension",
        "-lparquet_extension",
        "-lautocomplete_extension",
        "-lduckdb_fastpforlib",
        "-lduckdb_fmt",
        "-lduckdb_fsst",
        "-lduckdb_hyperloglog",
        "-lduckdb_mbedtls",
        "-lduckdb_miniz",
        "-lduckdb_pg_query",
        "-lduckdb_re2",
        "-lduckdb_skiplistlib",
        "-lduckdb_utf8proc",
        "-lduckdb_yyjson",
        "-lduckdb_zstd",
        "-lc++",
    });

    link_cmd.addArg("-o");
    const exe_output = link_cmd.addOutputFileArg("tt");

    const install = b.addInstallBinFile(exe_output, "tt");
    b.getInstallStep().dependOn(&install.step);

    const run_step = b.step("run", "Run the worker");
    const run_cmd = std.Build.Step.Run.create(b, &.{});
    run_cmd.addFileArg(exe_output);
    run_cmd.step.dependOn(&install.step);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run all Zig unit and adapter tests");

    const add_zig_test = struct {
        fn linkDuckDbStaticLibs(step: *std.Build.Step.Compile) void {
            const libs = [_][]const u8{
                "duckdb_static",
                "core_functions_extension",
                "icu_extension",
                "json_extension",
                "parquet_extension",
                "autocomplete_extension",
                "duckdb_fastpforlib",
                "duckdb_fmt",
                "duckdb_fsst",
                "duckdb_hyperloglog",
                "duckdb_mbedtls",
                "duckdb_miniz",
                "duckdb_pg_query",
                "duckdb_re2",
                "duckdb_skiplistlib",
                "duckdb_utf8proc",
                "duckdb_yyjson",
                "duckdb_zstd",
            };
            inline for (libs) |lib_name| {
                step.root_module.linkSystemLibrary(lib_name, .{});
            }
            step.linkLibCpp();
        }

        fn run(
            build_ctx: *std.Build,
            suite_step: *std.Build.Step,
            root_source_file: std.Build.LazyPath,
            build_target: std.Build.ResolvedTarget,
            build_optimize: std.builtin.OptimizeMode,
            imports: []const std.Build.Module.Import,
            include_path: std.Build.LazyPath,
            lib_path: std.Build.LazyPath,
            link_duckdb: bool,
        ) void {
            const root_module = build_ctx.createModule(.{
                .root_source_file = root_source_file,
                .target = build_target,
                .optimize = build_optimize,
                .imports = imports,
            });

            if (link_duckdb) {
                root_module.addIncludePath(include_path);
                root_module.addLibraryPath(lib_path);
            }

            const test_artifact = build_ctx.addTest(.{ .root_module = root_module });
            if (link_duckdb) {
                linkDuckDbStaticLibs(test_artifact);
            }

            suite_step.dependOn(&build_ctx.addRunArtifact(test_artifact).step);
        }
    }.run;

    add_zig_test(b, test_step, b.path("src/domain/glob_test.zig"), target, optimize, &.{}, duckdb_include_path, duckdb_lib_path, false);
    add_zig_test(b, test_step, b.path("src/domain/event_test.zig"), target, optimize, &.{}, duckdb_include_path, duckdb_lib_path, false);
    add_zig_test(
        b,
        test_step,
        b.path("src/domain/rule_test.zig"),
        target,
        optimize,
        &.{
            .{ .name = "glob", .module = domain_glob_module },
        },
        duckdb_include_path,
        duckdb_lib_path,
        false,
    );
    add_zig_test(
        b,
        test_step,
        b.path("src/application/services/tracker_test.zig"),
        target,
        optimize,
        &.{
            .{ .name = "domain_event", .module = domain_event_module },
        },
        duckdb_include_path,
        duckdb_lib_path,
        false,
    );
    add_zig_test(
        b,
        test_step,
        b.path("src/external/dto/event_mapper_test.zig"),
        target,
        optimize,
        &.{
            .{ .name = "flatbufferz", .module = flatbufferz_module },
            .{ .name = "event_dto_generated", .module = event_dto_generated_module },
            .{ .name = "domain_event", .module = domain_event_module },
        },
        duckdb_include_path,
        duckdb_lib_path,
        false,
    );

    add_zig_test(b, test_step, b.path("src/external/duckdb/migrations_test.zig"), target, optimize, &.{}, duckdb_include_path, duckdb_lib_path, true);
    add_zig_test(
        b,
        test_step,
        b.path("src/external/duckdb/legacy_repository_test.zig"),
        target,
        optimize,
        &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "migrations", .module = migrations_module },
        },
        duckdb_include_path,
        duckdb_lib_path,
        true,
    );
    add_zig_test(
        b,
        test_step,
        b.path("src/external/duckdb/buffered_repository_test.zig"),
        target,
        optimize,
        &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "legacy_repository", .module = legacy_repo_module },
        },
        duckdb_include_path,
        duckdb_lib_path,
        true,
    );
    add_zig_test(
        b,
        test_step,
        b.path("src/external/duckdb/event_repository_test.zig"),
        target,
        optimize,
        &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "event_repository", .module = event_repository_interface },
            .{ .name = "duckdb_event_repository", .module = duckdb_event_repository },
            .{ .name = "migrations", .module = migrations_module },
        },
        duckdb_include_path,
        duckdb_lib_path,
        true,
    );
    // NOTE: rule_repository_test.zig and hierarchy_repository_test.zig still
    // target pre-v10 hierarchy schema (kinds/customers/phases relationships).
    // Keep them out of the strict default suite until they are migrated.
}
