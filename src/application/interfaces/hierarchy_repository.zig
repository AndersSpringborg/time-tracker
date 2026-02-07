const std = @import("std");
const hierarchy = @import("domain_hierarchy");
const ImportStats = hierarchy.ImportStats;
const HierarchyPath = hierarchy.HierarchyPath;

/// Error type for hierarchy repository operations.
pub const HierarchyRepositoryError = error{
    ParseError,
    FileReadError,
    InsertFailed,
    QueryFailed,
    OutOfMemory,
};

/// A search result from the hierarchy.
pub const HierarchyMatch = struct {
    activity_id: i64,
    kind_id: i64,
    display_path: []const u8, // Allocated, caller must free
};

/// Interface for importing and querying the customer/project hierarchy.
/// Implementations: DuckDbHierarchyRepository
pub const HierarchyRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        importFromFile: *const fn (*anyopaque, []const u8) HierarchyRepositoryError!ImportStats,
        importFromJson: *const fn (*anyopaque, []const u8) HierarchyRepositoryError!ImportStats,
        searchFullHierarchy: *const fn (*anyopaque, []const u8) HierarchyRepositoryError![]HierarchyMatch,
        getKindPath: *const fn (*anyopaque, i64) HierarchyRepositoryError![]const u8,
        freeMatches: *const fn (*anyopaque, []HierarchyMatch) void,
        freePath: *const fn (*anyopaque, []const u8) void,
    };

    /// Import hierarchy from a JSON file.
    pub fn importFromFile(self: HierarchyRepository, file_path: []const u8) HierarchyRepositoryError!ImportStats {
        return self.vtable.importFromFile(self.ptr, file_path);
    }

    /// Import hierarchy from JSON content.
    pub fn importFromJson(self: HierarchyRepository, json_content: []const u8) HierarchyRepositoryError!ImportStats {
        return self.vtable.importFromJson(self.ptr, json_content);
    }

    /// Search the hierarchy for matches.
    /// Caller must call freeMatches() when done.
    pub fn searchFullHierarchy(self: HierarchyRepository, search_term: []const u8) HierarchyRepositoryError![]HierarchyMatch {
        return self.vtable.searchFullHierarchy(self.ptr, search_term);
    }

    /// Get the full path for a kind (e.g., "Customer > Project > Activity > Kind").
    /// Caller must call freePath() when done.
    pub fn getKindPath(self: HierarchyRepository, kind_id: i64) HierarchyRepositoryError![]const u8 {
        return self.vtable.getKindPath(self.ptr, kind_id);
    }

    /// Free matches returned by searchFullHierarchy().
    pub fn freeMatches(self: HierarchyRepository, matches: []HierarchyMatch) void {
        self.vtable.freeMatches(self.ptr, matches);
    }

    /// Free path returned by getKindPath().
    pub fn freePath(self: HierarchyRepository, path: []const u8) void {
        self.vtable.freePath(self.ptr, path);
    }

    /// Create a HierarchyRepository from any type that implements the required methods.
    pub fn init(impl: anytype) HierarchyRepository {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn importFromFile(ptr: *anyopaque, file_path: []const u8) HierarchyRepositoryError!ImportStats {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.importFromFile(file_path);
            }

            fn importFromJson(ptr: *anyopaque, json_content: []const u8) HierarchyRepositoryError!ImportStats {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.importFromJson(json_content);
            }

            fn searchFullHierarchy(ptr: *anyopaque, search_term: []const u8) HierarchyRepositoryError![]HierarchyMatch {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.searchFullHierarchy(search_term);
            }

            fn getKindPath(ptr: *anyopaque, kind_id: i64) HierarchyRepositoryError![]const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getKindPath(kind_id);
            }

            fn freeMatches(ptr: *anyopaque, matches: []HierarchyMatch) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeMatches(matches);
            }

            fn freePath(ptr: *anyopaque, path: []const u8) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freePath(path);
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .importFromFile = gen.importFromFile,
                .importFromJson = gen.importFromJson,
                .searchFullHierarchy = gen.searchFullHierarchy,
                .getKindPath = gen.getKindPath,
                .freeMatches = gen.freeMatches,
                .freePath = gen.freePath,
            },
        };
    }
};
