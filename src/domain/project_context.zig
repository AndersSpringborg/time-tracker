const std = @import("std");

/// Represents an active project assignment in the user's current context.
/// Used to narrow down suggestions and rule matching to relevant projects.
pub const ProjectAssignment = struct {
    id: i64,
    project_id: i64,
    started_at: ?i64, // Timestamp in ms
    ended_at: ?i64, // Timestamp in ms, null if active

    /// Returns true if this assignment is currently active (not ended).
    pub fn isActive(self: ProjectAssignment) bool {
        return self.ended_at == null;
    }
};
