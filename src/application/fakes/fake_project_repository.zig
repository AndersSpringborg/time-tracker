const std = @import("std");
const project_repository = @import("project_repository");
const ProjectRepository = project_repository.ProjectRepository;
const ProjectRepositoryError = project_repository.ProjectRepositoryError;

/// In-memory fake implementation of ProjectRepository for testing.
pub const FakeProjectRepository = struct {
    active_projects: std.ArrayListUnmanaged(i64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FakeProjectRepository {
        return .{
            .active_projects = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FakeProjectRepository) void {
        self.active_projects.deinit(self.allocator);
    }

    pub fn addProject(self: *FakeProjectRepository, project_id: i64) ProjectRepositoryError!void {
        // Idempotent - check if already active
        for (self.active_projects.items) |id| {
            if (id == project_id) return;
        }
        self.active_projects.append(self.allocator, project_id) catch return ProjectRepositoryError.OutOfMemory;
    }

    pub fn endProject(self: *FakeProjectRepository, project_id: i64) ProjectRepositoryError!void {
        for (self.active_projects.items, 0..) |id, i| {
            if (id == project_id) {
                _ = self.active_projects.orderedRemove(i);
                return;
            }
        }
    }

    pub fn endAllProjects(self: *FakeProjectRepository) ProjectRepositoryError!void {
        self.active_projects.clearRetainingCapacity();
    }

    pub fn getActiveProjectIds(self: *FakeProjectRepository) ProjectRepositoryError![]i64 {
        // Return a copy so caller can free it
        const copy = self.allocator.alloc(i64, self.active_projects.items.len) catch return ProjectRepositoryError.OutOfMemory;
        @memcpy(copy, self.active_projects.items);
        return copy;
    }

    pub fn hasActiveProjects(self: *FakeProjectRepository) ProjectRepositoryError!bool {
        return self.active_projects.items.len > 0;
    }

    pub fn isProjectActive(self: *FakeProjectRepository, project_id: i64) ProjectRepositoryError!bool {
        for (self.active_projects.items) |id| {
            if (id == project_id) return true;
        }
        return false;
    }

    pub fn freeProjectIds(self: *FakeProjectRepository, ids: []i64) void {
        self.allocator.free(ids);
    }

    /// Convert to the interface type.
    pub fn repository(self: *FakeProjectRepository) ProjectRepository {
        return ProjectRepository{
            .ptr = self,
            .vtable = &.{
                .addProject = addProjectVtable,
                .endProject = endProjectVtable,
                .endAllProjects = endAllProjectsVtable,
                .getActiveProjectIds = getActiveProjectIdsVtable,
                .hasActiveProjects = hasActiveProjectsVtable,
                .isProjectActive = isProjectActiveVtable,
                .freeProjectIds = freeProjectIdsVtable,
            },
        };
    }

    fn addProjectVtable(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!void {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        return self.addProject(project_id);
    }

    fn endProjectVtable(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!void {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        return self.endProject(project_id);
    }

    fn endAllProjectsVtable(ptr: *anyopaque) ProjectRepositoryError!void {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        return self.endAllProjects();
    }

    fn getActiveProjectIdsVtable(ptr: *anyopaque) ProjectRepositoryError![]i64 {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        return self.getActiveProjectIds();
    }

    fn hasActiveProjectsVtable(ptr: *anyopaque) ProjectRepositoryError!bool {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        return self.hasActiveProjects();
    }

    fn isProjectActiveVtable(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!bool {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        return self.isProjectActive(project_id);
    }

    fn freeProjectIdsVtable(ptr: *anyopaque, ids: []i64) void {
        const self: *FakeProjectRepository = @ptrCast(@alignCast(ptr));
        self.freeProjectIds(ids);
    }
};

test "FakeProjectRepository adds and tracks projects" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    try std.testing.expect(!try repo.hasActiveProjects());

    try repo.addProject(1);
    try repo.addProject(2);

    try std.testing.expect(try repo.hasActiveProjects());
    try std.testing.expect(try repo.isProjectActive(1));
    try std.testing.expect(try repo.isProjectActive(2));
    try std.testing.expect(!try repo.isProjectActive(3));
}

test "FakeProjectRepository addProject is idempotent" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    try repo.addProject(1);
    try repo.addProject(1); // Should be no-op

    const ids = try repo.getActiveProjectIds();
    defer repo.freeProjectIds(ids);

    try std.testing.expectEqual(@as(usize, 1), ids.len);
}

test "FakeProjectRepository ends projects" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    try repo.addProject(1);
    try repo.addProject(2);

    try repo.endProject(1);

    try std.testing.expect(!try repo.isProjectActive(1));
    try std.testing.expect(try repo.isProjectActive(2));
}

test "FakeProjectRepository ends all projects" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    try repo.addProject(1);
    try repo.addProject(2);

    try repo.endAllProjects();

    try std.testing.expect(!try repo.hasActiveProjects());
}

test "FakeProjectRepository works through interface" {
    var fake = FakeProjectRepository.init(std.testing.allocator);
    defer fake.deinit();

    const repo = fake.repository();

    try repo.addProject(42);
    try std.testing.expect(try repo.isProjectActive(42));
}
