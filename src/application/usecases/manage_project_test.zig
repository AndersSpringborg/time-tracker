const std = @import("std");
const FakeProjectRepository = @import("fake_project_repository").FakeProjectRepository;
const ManageProjectUseCase = @import("manage_project.zig").ManageProjectUseCase;

test "ManageProjectUseCase can start a project" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = ManageProjectUseCase.init(repo.repository());

    try usecase.startProject(42);

    try std.testing.expect(try repo.isProjectActive(42));
}

test "ManageProjectUseCase can stop a project" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = ManageProjectUseCase.init(repo.repository());

    try usecase.startProject(42);
    try usecase.stopProject(42);

    try std.testing.expect(!try repo.isProjectActive(42));
}

test "ManageProjectUseCase can stop all projects" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = ManageProjectUseCase.init(repo.repository());

    try usecase.startProject(1);
    try usecase.startProject(2);
    try usecase.stopAllProjects();

    try std.testing.expect(!try repo.hasActiveProjects());
}

test "ManageProjectUseCase getActiveProjects returns current projects" {
    var repo = FakeProjectRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = ManageProjectUseCase.init(repo.repository());

    try usecase.startProject(10);
    try usecase.startProject(20);

    const ids = try usecase.getActiveProjects();
    defer usecase.freeProjectIds(ids);

    try std.testing.expectEqual(@as(usize, 2), ids.len);
}
