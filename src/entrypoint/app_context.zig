//! Composition Root / Application Context
//!
//! This module is the "composition root" - the single place where all the pieces
//! of the clean architecture are wired together:
//!
//! - External layer implementations (DuckDB repositories)
//! - Application layer use cases (TrackEvent, ManageProject)
//! - Configuration (database path, etc.)
//!
//! Usage:
//!   var ctx = try AppContext.init(allocator);
//!   defer ctx.deinit();
//!
//!   // Access use cases
//!   const event = Event{ ... };
//!   ctx.trackEvent.track(event, timestamp);
//!
//!   // Access repositories directly if needed
//!   const rules = ctx.ruleRepo.repository();

const std = @import("std");
const migrations = @import("migrations");
const c = migrations.c;

// Use cases
const TrackEventUseCase = @import("track_event").TrackEventUseCase;
const ManageProjectUseCase = @import("manage_project").ManageProjectUseCase;

// External layer implementations
const DuckDbEventRepository = @import("duckdb_event_repository").DuckDbEventRepository;
const DuckDbRuleRepository = @import("duckdb_rule_repository").DuckDbRuleRepository;
const DuckDbProjectRepository = @import("duckdb_project_repository").DuckDbProjectRepository;
const DuckDbHierarchyRepository = @import("duckdb_hierarchy_repository").DuckDbHierarchyRepository;
const DuckDbQueryRepository = @import("duckdb_query_repository").DuckDbQueryRepository;

pub const AppContextError = error{
    DatabaseOpenFailed,
    DatabaseConnectFailed,
    MigrationFailed,
    PathTooLong,
    OutOfMemory,
};

/// The application context holds all the wired-up components.
/// Create one at startup, use throughout the application lifetime.
///
/// IMPORTANT: Use cases must be created AFTER the struct is in its final location
/// because they contain pointers to the repository fields. Call wireUseCases()
/// after construction or use the init() functions which return a pointer.
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    db_path: [:0]const u8,

    // Database connection (owned)
    db: c.duckdb_database,
    conn: c.duckdb_connection,

    // External layer: DuckDB implementations
    eventRepo: DuckDbEventRepository,
    ruleRepo: DuckDbRuleRepository,
    projectRepo: DuckDbProjectRepository,
    hierarchyRepo: DuckDbHierarchyRepository,
    queryRepo: DuckDbQueryRepository,

    // Application layer: Use cases (wired after struct is placed)
    trackEvent: TrackEventUseCase,
    manageProject: ManageProjectUseCase,

    /// Initialize the application context with default database path.
    /// Returns a heap-allocated context to ensure stable pointers.
    pub fn init(allocator: std.mem.Allocator) AppContextError!*AppContext {
        const db_path = getDbPath(allocator) catch return error.PathTooLong;
        return initWithPath(allocator, db_path);
    }

    /// Initialize with a specific database path.
    /// Returns a heap-allocated context to ensure stable pointers.
    pub fn initWithPath(allocator: std.mem.Allocator, db_path: [:0]const u8) AppContextError!*AppContext {
        // Open database
        var db: c.duckdb_database = undefined;
        var conn: c.duckdb_connection = undefined;

        if (c.duckdb_open(db_path.ptr, &db) == c.DuckDBError) {
            return error.DatabaseOpenFailed;
        }
        errdefer c.duckdb_close(&db);

        if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
            return error.DatabaseConnectFailed;
        }
        errdefer c.duckdb_disconnect(&conn);

        // Run migrations
        var migrator = migrations.Migrator.init(conn) catch return error.MigrationFailed;
        migrator.run() catch return error.MigrationFailed;

        // Allocate context on heap so pointers remain stable
        const self = allocator.create(AppContext) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        // Initialize fields
        self.* = .{
            .allocator = allocator,
            .db_path = db_path,
            .db = db,
            .conn = conn,
            .eventRepo = DuckDbEventRepository.init(conn, allocator),
            .ruleRepo = DuckDbRuleRepository.init(conn, allocator),
            .projectRepo = DuckDbProjectRepository.init(conn, allocator),
            .hierarchyRepo = DuckDbHierarchyRepository.init(conn, allocator),
            .queryRepo = DuckDbQueryRepository.init(conn, allocator),
            // Use cases will be wired below
            .trackEvent = undefined,
            .manageProject = undefined,
        };

        // Wire use cases now that struct is in its final location
        self.wireUseCases();

        return self;
    }

    /// Initialize with in-memory database (for testing).
    pub fn initInMemory(allocator: std.mem.Allocator) AppContextError!*AppContext {
        return initWithPath(allocator, ":memory:");
    }

    /// Wire use cases to repository interfaces.
    /// Called automatically by init functions. Only call manually if struct was moved.
    pub fn wireUseCases(self: *AppContext) void {
        self.trackEvent = TrackEventUseCase.init(
            self.eventRepo.repository(),
            self.ruleRepo.repository(),
        );
        self.manageProject = ManageProjectUseCase.init(
            self.projectRepo.repository(),
        );
    }

    pub fn deinit(self: *AppContext) void {
        const allocator = self.allocator;
        c.duckdb_disconnect(&self.conn);
        c.duckdb_close(&self.db);
        if (!std.mem.eql(u8, self.db_path, ":memory:")) {
            allocator.free(self.db_path);
        }
        allocator.destroy(self);
    }

    /// Get the raw database connection for legacy code.
    /// Prefer using use cases instead.
    pub fn getConnection(self: *AppContext) c.duckdb_connection {
        return self.conn;
    }
};

/// Get the default database path (~/.local/share/time-tracker/tracker.db).
fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const xdg_data = std.posix.getenv("XDG_DATA_HOME");

    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;

    if (xdg_data) |data_dir| {
        path_len = (std.fmt.bufPrint(&path_buf, "{s}/time-tracker", .{data_dir}) catch return error.PathTooLong).len;
    } else {
        path_len = (std.fmt.bufPrint(&path_buf, "{s}/.local/share/time-tracker", .{home}) catch return error.PathTooLong).len;
    }

    // Create directory if it doesn't exist
    const dir_path = path_buf[0..path_len];
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            // Continue anyway - the database open will fail if there's a real problem
        }
    };

    // Append database filename and null terminator
    const full_path = std.fmt.allocPrint(allocator, "{s}/tracker.db\x00", .{dir_path}) catch return error.OutOfMemory;
    return full_path[0 .. full_path.len - 1 :0];
}
