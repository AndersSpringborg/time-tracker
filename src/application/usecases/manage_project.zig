const project_repository = @import("project_repository");
const ProjectRepository = project_repository.ProjectRepository;
const ProjectRepositoryError = project_repository.ProjectRepositoryError;

/// Use case for managing active project context.
/// Allows starting/stopping projects to narrow rule matching scope.
pub const ManageProjectUseCase = struct {
    project_repository: ProjectRepository,

    pub fn init(project_repository_: ProjectRepository) ManageProjectUseCase {
        return .{
            .project_repository = project_repository_,
        };
    }

    /// Start working on a project. Idempotent.
    pub fn startProject(self: *ManageProjectUseCase, project_id: i64) ProjectRepositoryError!void {
        return self.project_repository.addProject(project_id);
    }

    /// Stop working on a specific project.
    pub fn stopProject(self: *ManageProjectUseCase, project_id: i64) ProjectRepositoryError!void {
        return self.project_repository.endProject(project_id);
    }

    /// Stop working on all projects.
    pub fn stopAllProjects(self: *ManageProjectUseCase) ProjectRepositoryError!void {
        return self.project_repository.endAllProjects();
    }

    /// Get all currently active project IDs.
    /// Caller must call freeProjectIds() when done.
    pub fn getActiveProjects(self: *ManageProjectUseCase) ProjectRepositoryError![]i64 {
        return self.project_repository.getActiveProjectIds();
    }

    /// Check if any projects are active.
    pub fn hasActiveProjects(self: *ManageProjectUseCase) ProjectRepositoryError!bool {
        return self.project_repository.hasActiveProjects();
    }

    /// Free project IDs returned by getActiveProjects().
    pub fn freeProjectIds(self: *ManageProjectUseCase, ids: []i64) void {
        self.project_repository.freeProjectIds(ids);
    }
};
