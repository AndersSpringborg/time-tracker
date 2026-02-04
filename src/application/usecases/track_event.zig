const Event = @import("domain_event").Event;
const event_repository = @import("event_repository");
const EventRepository = event_repository.EventRepository;
const RuleMatch = event_repository.RuleMatch;
const RuleRepository = @import("rule_repository").RuleRepository;

/// Use case for tracking window change events.
/// Computes duration between events, applies rules, and saves to repository.
pub const TrackEventUseCase = struct {
    event_repository: EventRepository,
    rule_repository: RuleRepository,
    last_event: ?Event,

    pub fn init(event_repository_: EventRepository, rule_repository_: RuleRepository) TrackEventUseCase {
        return .{
            .event_repository = event_repository_,
            .rule_repository = rule_repository_,
            .last_event = null,
        };
    }

    /// Handle a new window event.
    /// Saves the previous event with computed duration when a new event arrives.
    /// Applies matching rules to map events to activities/kinds.
    pub fn handle(self: *TrackEventUseCase, event: Event) void {
        // If we have a previous event and it's different, save it
        if (self.last_event) |last| {
            if (!last.eql(event)) {
                const duration_ms = event.timestamp_ms - last.timestamp_ms;

                // Try to find a matching rule
                const domain_match = self.rule_repository.findMatch(last.app_name, last.window_title) catch null;

                // Convert domain Match to repository RuleMatch
                const match: ?RuleMatch = if (domain_match) |m| RuleMatch{
                    .rule_id = m.rule_id,
                    .activity_id = m.activity_id,
                    .kind_id = m.kind_id,
                } else null;

                self.event_repository.save(last, duration_ms, match);
            }
        }

        // Update last event (even if same, to track timestamp)
        self.last_event = event;
    }
};
