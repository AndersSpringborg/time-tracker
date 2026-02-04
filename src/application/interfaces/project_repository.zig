const std = @import("std");
const ProjectAssignment = @import("../../domain/project_context.zig").ProjectAssignment;

/// Error type for project repository operations.
pub const ProjectRepositoryError = error{
    QueryFailed,
    InsertFailed,
    OutOfMemory,
};

/// Interface for managing active project assignments.
/// Implementations: DuckDbProjectRepository
pub const ProjectRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        addProject: *const fn (*anyopaque, i64) ProjectRepositoryError!void,
        endProject: *const fn (*anyopaque, i64) ProjectRepositoryError!void,
        endAllProjects: *const fn (*anyopaque) ProjectRepositoryError!void,
        getActiveProjects: *const fn (*anyopaque) ProjectRepositoryError![]ProjectAssignment,
        getActiveProjectIds: *const fn (*anyopaque) ProjectRepositoryError![]i64,
        hasActiveProjects: *const fn (*anyopaque) ProjectRepositoryError!bool,
        isProjectActive: *const fn (*anyopaque, i64) ProjectRepositoryError!bool,
        freeAssignments: *const fn (*anyopaque, []ProjectAssignment) void,
        freeProjectIds: *const fn (*anyopaque, []i64) void,
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

    /// Get all active project assignments (ended_at IS NULL).
    /// Caller must call freeAssignments() when done.
    pub fn getActiveProjects(self: ProjectRepository) ProjectRepositoryError![]ProjectAssignment {
        return self.vtable.getActiveProjects(self.ptr);
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

    /// Free assignments returned by getActiveProjects().
    pub fn freeAssignments(self: ProjectRepository, assignments: []ProjectAssignment) void {
        self.vtable.freeAssignments(self.ptr, assignments);
    }

    /// Free project IDs returned by getActiveProjectIds().
    pub fn freeProjectIds(self: ProjectRepository, ids: []i64) void {
        self.vtable.freeProjectIds(self.ptr, ids);
    }

    /// Create a ProjectRepository from any type that implements the required methods.
    pub fn init(impl: anytype) ProjectRepository {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn addProject(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.addProject(project_id);
            }

            fn endProject(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.endProject(project_id);
            }

            fn endAllProjects(ptr: *anyopaque) ProjectRepositoryError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.endAllProjects();
            }

            fn getActiveProjects(ptr: *anyopaque) ProjectRepositoryError![]ProjectAssignment {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getActiveProjects();
            }

            fn getActiveProjectIds(ptr: *anyopaque) ProjectRepositoryError![]i64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getActiveProjectIds();
            }

            fn hasActiveProjects(ptr: *anyopaque) ProjectRepositoryError!bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.hasActiveProjects();
            }

            fn isProjectActive(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.isProjectActive(project_id);
            }

            fn freeAssignments(ptr: *anyopaque, assignments: []ProjectAssignment) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeAssignments(assignments);
            }

            fn freeProjectIds(ptr: *anyopaque, ids: []i64) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeProjectIds(ids);
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .addProject = gen.addProject,
                .endProject = gen.endProject,
                .endAllProjects = gen.endAllProjects,
                .getActiveProjects = gen.getActiveProjects,
                .getActiveProjectIds = gen.getActiveProjectIds,
                .hasActiveProjects = gen.hasActiveProjects,
                .isProjectActive = gen.isProjectActive,
                .freeAssignments = gen.freeAssignments,
                .freeProjectIds = gen.freeProjectIds,
            },
        };
    }
};
