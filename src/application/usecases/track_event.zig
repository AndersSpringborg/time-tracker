const Event = @import("domain_event").Event;
const EventRepository = @import("event_repository").EventRepository;

/// Use case for tracking window change events.
/// Computes duration between events and saves to repository.
pub const TrackEventUseCase = struct {
    event_repository: EventRepository,
    last_event: ?Event,

    pub fn init(event_repository: EventRepository) TrackEventUseCase {
        return .{
            .event_repository = event_repository,
            .last_event = null,
        };
    }

    /// Handle a new window event.
    /// Saves the previous event with computed duration when a new event arrives.
    pub fn handle(self: *TrackEventUseCase, event: Event) void {
        // If we have a previous event and it's different, save it
        if (self.last_event) |last| {
            if (!last.eql(event)) {
                const duration_ms = event.timestamp_ms - last.timestamp_ms;
                self.event_repository.save(last, duration_ms);
            }
        }

        // Update last event (even if same, to track timestamp)
        self.last_event = event;
    }
};
