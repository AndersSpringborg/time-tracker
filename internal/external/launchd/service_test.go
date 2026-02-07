package launchd

import "testing"

func TestLaunchdDomainTargetForUID(t *testing.T) {
	got, err := launchdDomainTargetForUID(501)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "gui/501" {
		t.Fatalf("expected gui/501, got %q", got)
	}
}

func TestLaunchdDomainTargetForUIDRejectsRoot(t *testing.T) {
	_, err := launchdDomainTargetForUID(0)
	if err == nil {
		t.Fatalf("expected error for uid 0")
	}
}

func TestRejectSudoInstallForEUID(t *testing.T) {
	if err := rejectSudoInstallForEUID(501); err != nil {
		t.Fatalf("unexpected error for user euid: %v", err)
	}
	if err := rejectSudoInstallForEUID(0); err == nil {
		t.Fatalf("expected error for root euid")
	}
}
