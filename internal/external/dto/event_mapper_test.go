package dto

import (
	"errors"
	"testing"

	"time-tracker/internal/domain"
)

func TestEncodeDecodeEventRoundTrip(t *testing.T) {
	dto := EventDTO{
		TimestampMS:    1700000000000,
		DurationMS:     3000,
		AppName:        "Code",
		WindowTitle:    "main.zig",
		WifiSSID:       "Office-5G",
		HasProjectID:   true,
		ProjectID:      42,
		HasActivityID:  true,
		ActivityID:     1001,
		ManuallyMapped: true,
	}

	payload, err := EncodeEvent(dto)
	if err != nil {
		t.Fatalf("EncodeEvent failed: %v", err)
	}
	decoded, err := DecodeEvent(payload)
	if err != nil {
		t.Fatalf("DecodeEvent failed: %v", err)
	}

	if decoded.TimestampMS != dto.TimestampMS {
		t.Fatalf("timestamp mismatch: got %d want %d", decoded.TimestampMS, dto.TimestampMS)
	}
	if decoded.DurationMS != dto.DurationMS {
		t.Fatalf("duration mismatch: got %d want %d", decoded.DurationMS, dto.DurationMS)
	}
	if decoded.AppName != dto.AppName {
		t.Fatalf("app mismatch: got %q want %q", decoded.AppName, dto.AppName)
	}
	if decoded.WindowTitle != dto.WindowTitle {
		t.Fatalf("title mismatch: got %q want %q", decoded.WindowTitle, dto.WindowTitle)
	}
	if decoded.WifiSSID != dto.WifiSSID {
		t.Fatalf("wifi mismatch: got %q want %q", decoded.WifiSSID, dto.WifiSSID)
	}
	if decoded.HasProjectID != dto.HasProjectID || decoded.ProjectID != dto.ProjectID {
		t.Fatalf("project mismatch: got (%t,%d) want (%t,%d)", decoded.HasProjectID, decoded.ProjectID, dto.HasProjectID, dto.ProjectID)
	}
	if decoded.HasActivityID != dto.HasActivityID || decoded.ActivityID != dto.ActivityID {
		t.Fatalf("activity mismatch: got (%t,%d) want (%t,%d)", decoded.HasActivityID, decoded.ActivityID, dto.HasActivityID, dto.ActivityID)
	}
	if decoded.ManuallyMapped != dto.ManuallyMapped {
		t.Fatalf("manual flag mismatch: got %t want %t", decoded.ManuallyMapped, dto.ManuallyMapped)
	}
}

func TestEncodeEventRejectsMissingRequiredFields(t *testing.T) {
	_, err := EncodeEvent(EventDTO{
		TimestampMS: 1,
		AppName:     "",
		WindowTitle: "title",
	})
	if !errors.Is(err, ErrMissingFields) {
		t.Fatalf("expected ErrMissingFields, got %v", err)
	}
}

func TestDomainMappingRoundTrip(t *testing.T) {
	projectID := int64(7)
	activityID := int64(99)
	original := domain.Event{
		TimestampMS:  12345,
		DurationMS:   60000,
		AppName:      "Terminal",
		WindowTitle:  "build",
		ProjectID:    &projectID,
		ActivityID:   &activityID,
		ProjectTitle: "Tracker",
	}

	dto := DomainToDTO(original, "Home", false)
	back := DTOToDomain(dto)

	if back.TimestampMS != original.TimestampMS || back.DurationMS != original.DurationMS {
		t.Fatalf("time fields mismatch after mapping")
	}
	if back.AppName != original.AppName || back.WindowTitle != original.WindowTitle {
		t.Fatalf("identity fields mismatch after mapping")
	}
	if back.ProjectID == nil || *back.ProjectID != *original.ProjectID {
		t.Fatalf("project id mismatch after mapping")
	}
	if back.ActivityID == nil || *back.ActivityID != *original.ActivityID {
		t.Fatalf("activity id mismatch after mapping")
	}
}
