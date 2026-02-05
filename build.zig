const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Always use vendored DuckDB
    const duckdb_include_path: std.Build.LazyPath = .{ .cwd_relative = "vendor/duckdb/include" };
    const duckdb_lib_path: std.Build.LazyPath = .{ .cwd_relative = "vendor/duckdb/lib" };

    // =======================================================================
    // EXTERNAL DEPENDENCIES
    // =======================================================================

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_module = vaxis_dep.module("vaxis");

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
        .imports = &.{
            .{ .name = "glob", .module = domain_glob_module },
        },
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
    // APPLICATION LAYER MODULES (Clean Architecture)
    // =======================================================================

    // Event repository interface
    const event_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/event_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
        },
    });

    // Rule repository interface
    const rule_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/rule_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_rule", .module = domain_rule_module },
        },
    });

    // Fake event repository for testing
    const fake_event_repository = b.createModule(.{
        .root_source_file = b.path("src/application/fakes/fake_event_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "event_repository", .module = event_repository_interface },
        },
    });

    // Fake rule repository for testing
    const fake_rule_repository = b.createModule(.{
        .root_source_file = b.path("src/application/fakes/fake_rule_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_rule", .module = domain_rule_module },
            .{ .name = "rule_repository", .module = rule_repository_interface },
        },
    });

    // Track event use case
    const track_event_usecase = b.createModule(.{
        .root_source_file = b.path("src/application/usecases/track_event.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
            .{ .name = "event_repository", .module = event_repository_interface },
            .{ .name = "rule_repository", .module = rule_repository_interface },
        },
    });

    // Project repository interface
    const project_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/project_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_project_context", .module = domain_project_context_module },
        },
    });

    // Fake project repository for testing
    const fake_project_repository = b.createModule(.{
        .root_source_file = b.path("src/application/fakes/fake_project_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "project_repository", .module = project_repository_interface },
        },
    });

    // Manage project use case
    const manage_project_usecase = b.createModule(.{
        .root_source_file = b.path("src/application/usecases/manage_project.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "project_repository", .module = project_repository_interface },
        },
    });

    // =======================================================================
    // EXTERNAL LAYER MODULES (DuckDB implementations)
    // =======================================================================

    // Migrations module (shared by all DuckDB-using modules)
    const migrations_module = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/migrations.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrations_module.addIncludePath(duckdb_include_path);
    migrations_module.addLibraryPath(duckdb_lib_path);

    // DuckDB Event Repository
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

    // DuckDB Rule Repository
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

    // DuckDB Project Repository
    const duckdb_project_repository = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/project_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "project_repository", .module = project_repository_interface },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    duckdb_project_repository.addIncludePath(duckdb_include_path);
    duckdb_project_repository.addLibraryPath(duckdb_lib_path);

    // Hierarchy repository interface
    const hierarchy_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/hierarchy_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_hierarchy", .module = domain_hierarchy_module },
        },
    });

    // DuckDB Hierarchy Repository
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

    // Query repository interface
    const query_repository_interface = b.createModule(.{
        .root_source_file = b.path("src/application/interfaces/query_repository.zig"),
        .target = target,
        .optimize = optimize,
    });

    // DuckDB Query Repository
    const duckdb_query_repository = b.createModule(.{
        .root_source_file = b.path("src/external/duckdb/query_repository.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "query_repository", .module = query_repository_interface },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    duckdb_query_repository.addIncludePath(duckdb_include_path);
    duckdb_query_repository.addLibraryPath(duckdb_lib_path);

    // =======================================================================
    // ENTRYPOINT LAYER (Composition Root)
    // =======================================================================

    // Config module - user settings
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glob", .module = domain_glob_module },
        },
    });

    // App Context - wires everything together
    const app_context_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/app_context.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // Migrations for database setup
            .{ .name = "migrations", .module = migrations_module },
            // Use cases
            .{ .name = "track_event", .module = track_event_usecase },
            .{ .name = "manage_project", .module = manage_project_usecase },
            // External layer implementations
            .{ .name = "duckdb_event_repository", .module = duckdb_event_repository },
            .{ .name = "duckdb_rule_repository", .module = duckdb_rule_repository },
            .{ .name = "duckdb_project_repository", .module = duckdb_project_repository },
            .{ .name = "duckdb_hierarchy_repository", .module = duckdb_hierarchy_repository },
            .{ .name = "duckdb_query_repository", .module = duckdb_query_repository },
        },
    });
    app_context_module.addIncludePath(duckdb_include_path);
    app_context_module.addLibraryPath(duckdb_lib_path);

    // =======================================================================
    // APPLICATION LAYER SERVICES (Tracker, Suggestions)
    // =======================================================================

    const tracker_module = b.createModule(.{
        .root_source_file = b.path("src/application/services/tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "domain_event", .module = domain_event_module },
        },
    });

    const suggestions_module = b.createModule(.{
        .root_source_file = b.path("src/application/services/suggestions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
            .{ .name = "domain_scoring", .module = domain_scoring_module },
        },
    });
    suggestions_module.addIncludePath(duckdb_include_path);
    suggestions_module.addLibraryPath(duckdb_lib_path);

    // =======================================================================
    // EXTERNAL LAYER - DAEMON-SPECIFIC MODULES
    // =======================================================================

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

    // =======================================================================
    // ENTRYPOINT LAYER - CLI UTILITIES
    // =======================================================================

    const review_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/cli/review.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    review_module.addIncludePath(duckdb_include_path);
    review_module.addLibraryPath(duckdb_lib_path);

    // Review TUI - interactive event review with libvaxis
    const review_tui_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/cli/review_tui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_module },
            .{ .name = "review", .module = review_module },
            .{ .name = "migrations", .module = migrations_module },
        },
    });
    review_tui_module.addIncludePath(duckdb_include_path);
    review_tui_module.addLibraryPath(duckdb_lib_path);

    const terminal_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/cli/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const picker_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/cli/picker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "terminal", .module = terminal_module },
        },
    });

    picker_module.addIncludePath(duckdb_include_path);
    picker_module.addLibraryPath(duckdb_lib_path);

    // =======================================================================
    // UNIFIED BINARY (CLI + Daemon with Swift integration)
    // =======================================================================

    // --- 1. Compile Zig to object file with all modules ---
    const unified_module = b.createModule(.{
        .root_source_file = b.path("src/entrypoint/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // Clean architecture modules
            .{ .name = "app_context", .module = app_context_module },
            .{ .name = "query_repository", .module = query_repository_interface },
            .{ .name = "hierarchy_repository", .module = hierarchy_repository_interface },
            .{ .name = "domain_rule", .module = domain_rule_module },
            .{ .name = "config", .module = config_module },
            // Legacy CLI modules
            .{ .name = "review", .module = review_module },
            .{ .name = "review_tui", .module = review_tui_module },
            .{ .name = "picker", .module = picker_module },
            .{ .name = "migrations", .module = migrations_module },
            // Daemon modules
            .{ .name = "tracker", .module = tracker_module },
            .{ .name = "buffered_repository", .module = buffered_repo_module },
            // DuckDB repositories for menubar rule matching
            .{ .name = "duckdb_rule_repository", .module = duckdb_rule_repository },
            .{ .name = "duckdb_hierarchy_repository", .module = duckdb_hierarchy_repository },
            .{ .name = "duckdb_event_repository", .module = duckdb_event_repository },
        },
    });
    unified_module.addIncludePath(duckdb_include_path);
    unified_module.addLibraryPath(duckdb_lib_path);

    const zig_obj = b.addObject(.{
        .name = "main",
        .root_module = unified_module,
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
    const exe_output = link_cmd.addOutputFileArg("tt");

    // --- 4. Install the binary ---
    const install = b.addInstallBinFile(exe_output, "tt");
    b.getInstallStep().dependOn(&install.step);

    // --- Run step ---
    const run_step = b.step("run", "Run the time tracker");
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
            .imports = &.{
                .{ .name = "glob", .module = domain_glob_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(domain_rule_tests).step);

    // -----------------------------------------------------------------------
    // APPLICATION LAYER TESTS
    // -----------------------------------------------------------------------

    // Fake event repository tests
    const fake_event_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/fakes/fake_event_repository.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_event", .module = domain_event_module },
                .{ .name = "event_repository", .module = event_repository_interface },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fake_event_repo_tests).step);

    // Fake rule repository tests
    const fake_rule_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/fakes/fake_rule_repository.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_rule", .module = domain_rule_module },
                .{ .name = "rule_repository", .module = rule_repository_interface },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fake_rule_repo_tests).step);

    // Fake project repository tests
    const fake_project_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/fakes/fake_project_repository.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "project_repository", .module = project_repository_interface },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fake_project_repo_tests).step);

    // Track event use case tests
    const track_event_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/usecases/track_event_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_event", .module = domain_event_module },
                .{ .name = "domain_rule", .module = domain_rule_module },
                .{ .name = "event_repository", .module = event_repository_interface },
                .{ .name = "rule_repository", .module = rule_repository_interface },
                .{ .name = "fake_event_repository", .module = fake_event_repository },
                .{ .name = "fake_rule_repository", .module = fake_rule_repository },
                .{ .name = "track_event", .module = track_event_usecase },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(track_event_tests).step);

    // Manage project use case tests
    const manage_project_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/usecases/manage_project_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "project_repository", .module = project_repository_interface },
                .{ .name = "fake_project_repository", .module = fake_project_repository },
                .{ .name = "manage_project", .module = manage_project_usecase },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(manage_project_tests).step);

    // -----------------------------------------------------------------------
    // EXTERNAL LAYER TESTS (DuckDB implementations)
    // -----------------------------------------------------------------------

    // DuckDB Event Repository tests
    const duckdb_event_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/event_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_event", .module = domain_event_module },
                .{ .name = "event_repository", .module = event_repository_interface },
                .{ .name = "duckdb_event_repository", .module = duckdb_event_repository },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    duckdb_event_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_event_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(duckdb_event_repo_tests);
    test_step.dependOn(&b.addRunArtifact(duckdb_event_repo_tests).step);

    // DuckDB Rule Repository tests
    const duckdb_rule_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/rule_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_rule", .module = domain_rule_module },
                .{ .name = "rule_repository", .module = rule_repository_interface },
                .{ .name = "duckdb_rule_repository", .module = duckdb_rule_repository },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    duckdb_rule_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_rule_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(duckdb_rule_repo_tests);
    test_step.dependOn(&b.addRunArtifact(duckdb_rule_repo_tests).step);

    // DuckDB Project Repository tests
    const duckdb_project_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/project_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "project_repository", .module = project_repository_interface },
                .{ .name = "duckdb_project_repository", .module = duckdb_project_repository },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    duckdb_project_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_project_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(duckdb_project_repo_tests);
    test_step.dependOn(&b.addRunArtifact(duckdb_project_repo_tests).step);

    // DuckDB Hierarchy Repository tests
    const duckdb_hierarchy_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/hierarchy_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "duckdb_hierarchy_repository", .module = duckdb_hierarchy_repository },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    duckdb_hierarchy_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_hierarchy_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(duckdb_hierarchy_repo_tests);
    test_step.dependOn(&b.addRunArtifact(duckdb_hierarchy_repo_tests).step);

    // DuckDB Query Repository tests
    const duckdb_query_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/query_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "duckdb_query_repository", .module = duckdb_query_repository },
                .{ .name = "query_repository", .module = query_repository_interface },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    duckdb_query_repo_tests.root_module.addIncludePath(duckdb_include_path);
    duckdb_query_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(duckdb_query_repo_tests);
    test_step.dependOn(&b.addRunArtifact(duckdb_query_repo_tests).step);

    // -----------------------------------------------------------------------
    // ENTRYPOINT LAYER TESTS
    // -----------------------------------------------------------------------

    // Config tests
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entrypoint/config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glob", .module = domain_glob_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(config_tests).step);

    // App Context tests (Composition Root)
    const app_context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entrypoint/app_context_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app_context", .module = app_context_module },
                .{ .name = "domain_event", .module = domain_event_module },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    app_context_tests.root_module.addIncludePath(duckdb_include_path);
    app_context_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(app_context_tests);
    test_step.dependOn(&b.addRunArtifact(app_context_tests).step);

    // -----------------------------------------------------------------------
    // MIGRATED TESTS (formerly in src/core/)
    // -----------------------------------------------------------------------

    // Tracker tests (now in application/services/)
    const tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/services/tracker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_event", .module = domain_event_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tracker_tests).step);

    // Legacy Repository tests (now in external/duckdb/)
    const legacy_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/legacy_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_event", .module = domain_event_module },
                .{ .name = "migrations", .module = migrations_module },
            },
        }),
    });
    legacy_repo_tests.root_module.addIncludePath(duckdb_include_path);
    legacy_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(legacy_repo_tests);
    test_step.dependOn(&b.addRunArtifact(legacy_repo_tests).step);

    // Migrations tests (now in external/duckdb/)
    const migrations_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/migrations_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    migrations_tests.root_module.addIncludePath(duckdb_include_path);
    migrations_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(migrations_tests);
    test_step.dependOn(&b.addRunArtifact(migrations_tests).step);

    // Review tests (now in entrypoint/cli/)
    const review_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entrypoint/cli/review_test.zig"),
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

    // Terminal tests (now in entrypoint/cli/)
    const terminal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entrypoint/cli/terminal_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "terminal", .module = terminal_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);

    // Suggestions tests (now in application/services/)
    const suggestions_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application/services/suggestions_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "migrations", .module = migrations_module },
                .{ .name = "domain_scoring", .module = domain_scoring_module },
            },
        }),
    });
    suggestions_tests.root_module.addIncludePath(duckdb_include_path);
    suggestions_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(suggestions_tests);
    test_step.dependOn(&b.addRunArtifact(suggestions_tests).step);

    // Buffered Repository tests (now in external/duckdb/)
    const buffered_repo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external/duckdb/buffered_repository_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain_event", .module = domain_event_module },
            },
        }),
    });
    buffered_repo_tests.root_module.addIncludePath(duckdb_include_path);
    buffered_repo_tests.root_module.addLibraryPath(duckdb_lib_path);
    linkDuckDbStatic(buffered_repo_tests);
    test_step.dependOn(&b.addRunArtifact(buffered_repo_tests).step);
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
