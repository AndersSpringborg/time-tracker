package domain

import "testing"

func TestBuildNoiseMaskSuppressesShortBlip(t *testing.T) {
	events := []Event{
		{TimestampMS: 0, DurationMS: 60_000, AppName: "Code"},
		{TimestampMS: 60_000, DurationMS: 60_000, AppName: "Spotify"},
		{TimestampMS: 120_000, DurationMS: 60_000, AppName: "Code"},
	}

	mask := BuildNoiseMask(events, []string{"Spotify"}, 1, 2)
	if len(mask) != 3 {
		t.Fatalf("expected mask len 3, got %d", len(mask))
	}
	if mask[1] {
		t.Fatalf("expected short noise blip to be suppressed")
	}
}

func TestBuildNoiseMaskFlipsAfterThreshold(t *testing.T) {
	events := []Event{
		{TimestampMS: 0, DurationMS: 60_000, AppName: "Code"},
		{TimestampMS: 60_000, DurationMS: 60_000, AppName: "Slack"},
		{TimestampMS: 120_000, DurationMS: 60_000, AppName: "Slack"},
		{TimestampMS: 180_000, DurationMS: 60_000, AppName: "Slack"},
	}

	mask := BuildNoiseMask(events, []string{"Slack"}, 1, 2)
	if !mask[2] || !mask[3] {
		t.Fatalf("expected sustained noise to flip state after threshold")
	}
}
