const std = @import("std");
const ProjectAssignment = @import("domain_project_context").ProjectAssignment;

/// Error type for project repository operations.
pub const ProjectRepositoryError = error{
    QueryFailed,
    InsertFailed,
    OutOfMemory,
};

/// Interface for managing active project assignments.
/// Implementations: DuckDbProjectRepository, FakeProjectRepository
pub const ProjectRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        addProject: *const fn (*anyopaque, i64) ProjectRepositoryError!void,
        endProject: *const fn (*anyopaque, i64) ProjectRepositoryError!void,
        endAllProjects: *const fn (*anyopaque) ProjectRepositoryError!void,
        getActiveProjectIds: *const fn (*anyopaque) ProjectRepositoryError![]i64,
        hasActiveProjects: *const fn (*anyopaque) ProjectRepositoryError!bool,
        isProjectActive: *const fn (*anyopaque, i64) ProjectRepositoryError!bool,
        freeProjectIds: *const fn (*anyopaque, []const i64) void,
    };

    /// Add a project to the active context. Idempotent - won't add if already active.
    pub fn addProject(self: ProjectRepository, project_id: i64) ProjectRepositoryError!void {
        return self.vtable.addProject(self.ptr, project_id);
    }

    /// End a project assignment (set ended_at to now).
    pub fn endProject(self: ProjectRepository, project_id: i64) ProjectRepositoryError!void {
        return self.vtable.endProject(self.ptr, project_id);
    }

    /// End all active project assignments.
    pub fn endAllProjects(self: ProjectRepository) ProjectRepositoryError!void {
        return self.vtable.endAllProjects(self.ptr);
    }

    /// Get just the IDs of active projects.
    /// Caller must call freeProjectIds() when done.
    pub fn getActiveProjectIds(self: ProjectRepository) ProjectRepositoryError![]i64 {
        return self.vtable.getActiveProjectIds(self.ptr);
    }

    /// Check if any projects are currently active.
    pub fn hasActiveProjects(self: ProjectRepository) ProjectRepositoryError!bool {
        return self.vtable.hasActiveProjects(self.ptr);
    }

    /// Check if a specific project is currently active.
    pub fn isProjectActive(self: ProjectRepository, project_id: i64) ProjectRepositoryError!bool {
        return self.vtable.isProjectActive(self.ptr, project_id);
    }

    /// Free project IDs returned by getActiveProjectIds().
    pub fn freeProjectIds(self: ProjectRepository, ids: []const i64) void {
        self.vtable.freeProjectIds(self.ptr, ids);
    }
};
