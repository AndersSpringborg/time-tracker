const std = @import("std");

/// A work item kind (most granular level).
/// Example: "Development", "Testing", "Documentation"
pub const Kind = struct {
    kind_id: i64,
    name: []const u8,
    billable: bool,
};

/// An activity contains multiple kinds.
/// Example: "Billable Work", "Not billable - Internal"
pub const Activity = struct {
    activity_id: i64,
    name: []const u8,
    kinds: []Kind,

    /// Determine if this activity is billable based on its name.
    /// Activities containing "Not billable", "non billable", or "non-billable" are not billable.
    pub fn isBillable(self: Activity) bool {
        return !std.mem.containsAtLeast(u8, self.name, 1, "Not billable") and
            !std.mem.containsAtLeast(u8, self.name, 1, "non billable") and
            !std.mem.containsAtLeast(u8, self.name, 1, "non-billable");
    }
};

/// A project contains multiple activities.
/// Example: "Website Redesign", "Mobile App v2"
pub const Project = struct {
    project_id: i64,
    name: []const u8,
    activities: []Activity,
};

/// A customer contains multiple projects.
/// Example: "Acme Corp", "Beta Inc"
pub const Customer = struct {
    customer_id: i64,
    name: []const u8,
    projects: []Project,
};

/// Statistics from an import operation.
pub const ImportStats = struct {
    customers: u32 = 0,
    projects: u32 = 0,
    activities: u32 = 0,
    kinds: u32 = 0,

    /// Returns the total number of items imported.
    pub fn total(self: ImportStats) u32 {
        return self.customers + self.projects + self.activities + self.kinds;
    }
};

/// A flat representation of a hierarchy path for display purposes.
/// Example: "Acme Corp > Website Redesign > Billable > Development"
pub const HierarchyPath = struct {
    customer_name: []const u8,
    project_name: []const u8,
    activity_name: []const u8,
    kind_name: []const u8,
    activity_id: i64,
    kind_id: i64,

    /// Format as a display string using the provided buffer.
    /// Returns a slice of the buffer with the formatted path.
    pub fn format(self: HierarchyPath, buf: []u8) []const u8 {
        const result = std.fmt.bufPrint(buf, "{s} > {s} > {s} > {s}", .{
            self.customer_name,
            self.project_name,
            self.activity_name,
            self.kind_name,
        }) catch return "";
        return result;
    }
};
