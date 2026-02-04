const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Always use vendored DuckDB
    const duckdb_include_path: std.Build.LazyPath = .{ .cwd_relative = "vendor/duckdb/include" };
    const duckdb_lib_path: std.Build.LazyPath = .{ .cwd_relative = "vendor/duckdb/lib" };

    // =======================================================================
    // NEW DOMAIN LAYER MODULES (Clean Architecture)
    // =======================================================================

    // Glob matching - pure algorithm
    const domain_glob_module = b.createModule(.{
        .root_source_file = b.path("src/domain/glob.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Event - core domain type (new location)
    const domain_event_module = b.createModule(.{
        .root_source_file = b.path("src/domain/event.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Scoring - pure algorithm using glob
    const domain_scoring_module = b.createModule(.{
        .root_source_file = b.path("src/domain/scoring.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Rule types - pure domain types using glob
    const domain_rule_module = b.createModule(.{
        .root_source_file = b.path("src/domain/rule.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Hierarchy types - pure domain types
    const domain_hierarchy_module = b.createModule(.{
        .root_source_file = b.path("src/domain/hierarchy.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Project context types - pure domain types
    const domain_project_context_module = b.createModule(.{
        .root_source_file = b.path("src/domain/project_context.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =======================================================================
    // LEGACY MODULES (still in src/core/ - will be migrated later)
    // =======================================================================

    // Event module (old location - still used by existing code)
    const event_module = b.createModule(.{
        .root_source_file = b.path("src/core/domain/event.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Scoring module (old location - still used by existing code)
    const scoring_module = b.createModule(.{
        .root_source_file = b.path("src/core/domain/scoring.zig"),
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

    const migrations_module = b.createModule(.{
        .root_source_file = b.path("src/core/storage/migrations.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrations_module.addIncludePath(duckdb_include_path);
    migrations_module.addLibraryPath(duckdb_lib_path);

    const duckdb_repo_module = b.createModule(.{
        .root_source_file = b.path("src/core/storage/duckdb_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "event", .module = event_module },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    duckdb_repo_module.addIncludePath(duckdb_include_path);
    duckdb_repo_module.addLibraryPath(duckdb_lib_path);

    const query_module = b.createModule(.{
        .root_source_file = b.path("src/core/cli/query.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_module.addIncludePath(duckdb_include_path);
    query_module.addLibraryPath(duckdb_lib_path);

    const hierarchy_module = b.createModule(.{
        .root_source_file = b.path("src/core/import/hierarchy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    hierarchy_module.addIncludePath(duckdb_include_path);
    hierarchy_module.addLibraryPath(duckdb_lib_path);

    const rules_module = b.createModule(.{
        .root_source_file = b.path("src/core/mapping/rules.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    rules_module.addIncludePath(duckdb_include_path);
    rules_module.addLibraryPath(duckdb_lib_path);

    const review_module = b.createModule(.{
        .root_source_file = b.path("src/core/cli/review.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    review_module.addIncludePath(duckdb_include_path);
    review_module.addLibraryPath(duckdb_lib_path);

    const terminal_module = b.createModule(.{
        .root_source_file = b.path("src/core/cli/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const picker_module = b.createModule(.{
        .root_source_file = b.path("src/core/cli/picker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "terminal", .module = terminal_module },
        },
    });

    const context_module = b.createModule(.{
        .root_source_file = b.path("src/core/context/context.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    context_module.addIncludePath(duckdb_include_path);
    context_module.addLibraryPath(duckdb_lib_path);

    const suggestions_module = b.createModule(.{
        .root_source_file = b.path("src/core/suggestions/suggestions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
            .{ .name = "scoring", .module = scoring_module },
        },
    });
    suggestions_module.addIncludePath(duckdb_include_path);
    suggestions_module.addLibraryPath(duckdb_lib_path);

    const buffered_repo_module = b.createModule(.{
        .root_source_file = b.path("src/core/storage/buffered_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "event", .module = event_module },
            .{ .name = "duckdb_repository", .module = duckdb_repo_module },
        },
    });
    buffered_repo_module.addIncludePath(duckdb_include_path);
    buffered_repo_module.addLibraryPath(duckdb_lib_path);

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
                .{ .name = "query", .module = query_module },
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "hierarchy", .module = hierarchy_module },
                .{ .name = "rules", .module = rules_module },
                .{ .name = "review", .module = review_module },
                .{ .name = "terminal", .module = terminal_module },
                .{ .name = "picker", .module = picker_module },
                .{ .name = "context", .module = context_module },
                .{ .name = "scoring", .module = scoring_module },
                .{ .name = "suggestions", .module = suggestions_module },
                .{ .name = "buffered_repository", .module = buffered_repo_module },
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

    // --- 3. Link everything with swiftc ---
    const link_cmd = b.addSystemCommand(&.{"swiftc"});

    // Add Zig object file
    link_cmd.addArtifactArg(zig_obj);

    // Add Swift object file
    link_cmd.addFileArg(swift_obj);

    // Link frameworks and vendored DuckDB static libraries
    link_cmd.addArgs(&.{
        "-framework",           "Foundation",
        "-framework",           "Cocoa",
        "-framework",           "ApplicationServices",
        "-framework",           "CoreWLAN",
        "-L",                   "vendor/duckdb/lib",
        // DuckDB core static library
        "-lduckdb_static",
        // DuckDB extensions (required by static build)
             "-lcore_functions_extension",
        "-licu_extension",      "-ljson_extension",
        "-lparquet_extension",  "-lautocomplete_extension",
        // DuckDB dependencies
        "-lduckdb_fastpforlib", "-lduckdb_fmt",
        "-lduckdb_fsst",        "-lduckdb_hyperloglog",
        "-lduckdb_mbedtls",     "-lduckdb_miniz",
        "-lduckdb_pg_query",    "-lduckdb_re2",
        "-lduckdb_skiplistlib", "-lduckdb_utf8proc",
        "-lduckdb_yyjson",      "-lduckdb_zstd",
        "-lc++",
    });

    // Output binary
    link_cmd.addArg("-o");
    const exe_output = link_cmd.addOutputFileArg("time_tracker");

    // --- 4. Install the binary ---
    const install = b.addInstallBinFile(exe_output, "time_tracker");
    b.getInstallStep().dependOn(&install.step);

    // --- Run step ---
    const run_step = b.step("run", "Run the tracker");
    const run_cmd = std.Build.Step.Run.create(b, &.{});
    run_cmd.addFileArg(exe_output);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(&install.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // =======================================================================
    // TEST STEP
    // =======================================================================
    const test_step = b.step("test", "Run unit tests");

    // -----------------------------------------------------------------------
    // NEW DOMAIN LAYER TESTS
    // -----------------------------------------------------------------------

    // Glob tests
    const domain_glob_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/domain/glob_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(domain_glob_tests).step);

    // Domain Event tests
    const domain_event_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/domain/event_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(domain_event_tests).step);

    // Domain Scoring tests
    const domain_scoring_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/domain/scoring_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(domain_scoring_tests).step);

    // Domain Rule tests
    const domain_rule_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/domain/rule_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(domain_rule_tests).step);

    // -----------------------------------------------------------------------
    // LEGACY TESTS (still in src/core/)
    // -----------------------------------------------------------------------

    // Event tests (old location)
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

    // Scoring tests (old location)
    const scoring_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/domain/scoring_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scoring", .module = scoring_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(scoring_tests).step);

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
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "duckdb_repository", .module = duckdb_repo_module },
            },
        }),
    });
    duckdb_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(duckdb_repo_tests);
    test_step.dependOn(&b.addRunArtifact(duckdb_repo_tests).step);

    // Migrations tests
    const migrations_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/storage/migrations_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    migrations_tests.root_module.addIncludePath(duckdb_include_path);
    migrations_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(migrations_tests);
    test_step.dependOn(&b.addRunArtifact(migrations_tests).step);

    // Hierarchy import tests
    const hierarchy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/import/hierarchy_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "hierarchy", .module = hierarchy_module },
            },
        }),
    });
    hierarchy_tests.root_module.addIncludePath(duckdb_include_path);
    hierarchy_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(hierarchy_tests);
    test_step.dependOn(&b.addRunArtifact(hierarchy_tests).step);

    // Rules engine tests
    const rules_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/mapping/rules_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "rules", .module = rules_module },
            },
        }),
    });
    rules_tests.root_module.addIncludePath(duckdb_include_path);
    rules_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(rules_tests);
    test_step.dependOn(&b.addRunArtifact(rules_tests).step);

    // Review tests
    const review_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/cli/review_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "review", .module = review_module },
            },
        }),
    });
    review_tests.root_module.addIncludePath(duckdb_include_path);
    review_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(review_tests);
    test_step.dependOn(&b.addRunArtifact(review_tests).step);

    // Terminal tests
    const terminal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/cli/terminal_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "terminal", .module = terminal_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);

    // Context tests
    const context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/context/context_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "context", .module = context_module },
            },
        }),
    });
    context_tests.root_module.addIncludePath(duckdb_include_path);
    context_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(context_tests);
    test_step.dependOn(&b.addRunArtifact(context_tests).step);

    // Suggestions tests
    const suggestions_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/suggestions/suggestions_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "suggestions", .module = suggestions_module },
            },
        }),
    });
    suggestions_tests.root_module.addIncludePath(duckdb_include_path);
    suggestions_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(suggestions_tests);
    test_step.dependOn(&b.addRunArtifact(suggestions_tests).step);

    // Buffered Repository tests
    const buffered_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/storage/buffered_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "event", .module = event_module },
                .{ .name = "buffered_repository", .module = buffered_repo_module },
            },
        }),
    });
    buffered_repo_tests.root_module.addIncludePath(duckdb_include_path);
    buffered_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(buffered_repo_tests);
    test_step.dependOn(&b.addRunArtifact(buffered_repo_tests).step);

    // Suppress unused variable warnings for new domain modules
    // (they will be used in later phases)
    _ = domain_glob_module;
    _ = domain_event_module;
    _ = domain_scoring_module;
    _ = domain_rule_module;
    _ = domain_hierarchy_module;
    _ = domain_project_context_module;
}

fn linkDuckDbStatic(compile: *std.Build.Step.Compile) void {
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_static.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libcore_functions_extension.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libicu_extension.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libjson_extension.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libparquet_extension.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libautocomplete_extension.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_fastpforlib.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_fmt.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_fsst.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_hyperloglog.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_mbedtls.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_miniz.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_pg_query.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_re2.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_skiplistlib.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_utf8proc.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_yyjson.a" });
    compile.addObjectFile(.{ .cwd_relative = "vendor/duckdb/lib/libduckdb_zstd.a" });
    compile.linkLibCpp();
}
