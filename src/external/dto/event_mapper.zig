const std = @import("std");
const fb = @import("flatbufferz");
const domain_event = @import("domain_event");
const generated = @import("event_dto_generated");

pub const EventDto = struct {
    timestamp_ms: i64,
    app_name: []const u8,
    window_title: []const u8,
    wifi_ssid: []const u8,
    duration_ms: i64 = 0,
    has_project_id: bool = false,
    project_id: i64 = 0,
    has_activity_id: bool = false,
    activity_id: i64 = 0,
    manually_mapped: bool = false,
};

pub const DtoError = error{
    OutOfMemory,
    InvalidPayload,
    MissingRequiredField,
};

/// Encode EventDto to flatbuffer payload.
pub fn encode(allocator: std.mem.Allocator, dto: EventDto) DtoError![]u8 {
    if (dto.app_name.len == 0 or dto.window_title.len == 0) {
        return error.MissingRequiredField;
    }

    var builder = fb.Builder.init(allocator);
    defer builder.deinitAll();

    const to_pack = generated.EventDTOT{
        .timestamp_ms = dto.timestamp_ms,
        .app_name = dto.app_name,
        .window_title = dto.window_title,
        .wifi_ssid = dto.wifi_ssid,
        .duration_ms = dto.duration_ms,
        .has_project_id = dto.has_project_id,
        .project_id = dto.project_id,
        .has_activity_id = dto.has_activity_id,
        .activity_id = dto.activity_id,
        .manually_mapped = dto.manually_mapped,
    };

    const root = to_pack.Pack(&builder, .{}) catch return error.OutOfMemory;
    builder.finish(root) catch return error.OutOfMemory;
    const payload = builder.finishedBytes() catch return error.OutOfMemory;
    return allocator.dupe(u8, payload) catch return error.OutOfMemory;
}

/// Decode payload to EventDto. Returned string slices reference input payload bytes.
pub fn decode(payload: []u8) DtoError!EventDto {
    if (payload.len < 4) {
        return error.InvalidPayload;
    }
    const mutable_payload: []u8 = @constCast(payload);
    const root = generated.EventDTO.GetRootAs(mutable_payload, 0);
    const app_name = root.AppName();
    const window_title = root.WindowTitle();
    if (app_name.len == 0 or window_title.len == 0) {
        return error.MissingRequiredField;
    }

    return .{
        .timestamp_ms = root.TimestampMs(),
        .app_name = app_name,
        .window_title = window_title,
        .wifi_ssid = root.WifiSsid(),
        .duration_ms = root.DurationMs(),
        .has_project_id = root.HasProjectId(),
        .project_id = root.ProjectId(),
        .has_activity_id = root.HasActivityId(),
        .activity_id = root.ActivityId(),
        .manually_mapped = root.ManuallyMapped(),
    };
}

pub fn toDomain(dto: EventDto) domain_event.Event {
    return .{
        .timestamp_ms = dto.timestamp_ms,
        .app_name = dto.app_name,
        .window_title = dto.window_title,
        .wifi_ssid = dto.wifi_ssid,
    };
}
