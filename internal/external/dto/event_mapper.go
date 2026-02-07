package dto

import (
	"errors"

	flatbuffers "github.com/google/flatbuffers/go"

	"time-tracker/internal/domain"
	eventdto "time-tracker/internal/external/dto/flatbuffers"
)

var (
	ErrInvalidPayload = errors.New("invalid event dto payload")
	ErrMissingFields  = errors.New("event dto missing required fields")
)

type EventDTO struct {
	TimestampMS    int64
	DurationMS     int64
	AppName        string
	WindowTitle    string
	WifiSSID       string
	HasProjectID   bool
	ProjectID      int64
	HasActivityID  bool
	ActivityID     int64
	ManuallyMapped bool
}

func EncodeEvent(dto EventDTO) ([]byte, error) {
	if dto.AppName == "" || dto.WindowTitle == "" {
		return nil, ErrMissingFields
	}

	builder := flatbuffers.NewBuilder(256)
	appNameOff := builder.CreateString(dto.AppName)
	windowTitleOff := builder.CreateString(dto.WindowTitle)
	wifiSSIDOff := builder.CreateString(dto.WifiSSID)

	eventdto.EventDTOStart(builder)
	eventdto.EventDTOAddTimestampMs(builder, dto.TimestampMS)
	eventdto.EventDTOAddAppName(builder, appNameOff)
	eventdto.EventDTOAddWindowTitle(builder, windowTitleOff)
	eventdto.EventDTOAddWifiSsid(builder, wifiSSIDOff)
	eventdto.EventDTOAddDurationMs(builder, dto.DurationMS)
	eventdto.EventDTOAddHasProjectId(builder, dto.HasProjectID)
	eventdto.EventDTOAddProjectId(builder, dto.ProjectID)
	eventdto.EventDTOAddHasActivityId(builder, dto.HasActivityID)
	eventdto.EventDTOAddActivityId(builder, dto.ActivityID)
	eventdto.EventDTOAddManuallyMapped(builder, dto.ManuallyMapped)
	root := eventdto.EventDTOEnd(builder)
	eventdto.FinishEventDTOBuffer(builder, root)

	out := make([]byte, len(builder.FinishedBytes()))
	copy(out, builder.FinishedBytes())
	return out, nil
}

func DecodeEvent(payload []byte) (EventDTO, error) {
	if len(payload) < flatbuffers.SizeUint32 {
		return EventDTO{}, ErrInvalidPayload
	}

	view := eventdto.GetRootAsEventDTO(payload, 0)
	dto := EventDTO{
		TimestampMS:    view.TimestampMs(),
		DurationMS:     view.DurationMs(),
		AppName:        string(view.AppName()),
		WindowTitle:    string(view.WindowTitle()),
		WifiSSID:       string(view.WifiSsid()),
		HasProjectID:   view.HasProjectId(),
		ProjectID:      view.ProjectId(),
		HasActivityID:  view.HasActivityId(),
		ActivityID:     view.ActivityId(),
		ManuallyMapped: view.ManuallyMapped(),
	}
	if dto.AppName == "" || dto.WindowTitle == "" {
		return EventDTO{}, ErrMissingFields
	}
	return dto, nil
}

func DomainToDTO(event domain.Event, wifiSSID string, manuallyMapped bool) EventDTO {
	dto := EventDTO{
		TimestampMS:    event.TimestampMS,
		DurationMS:     event.DurationMS,
		AppName:        event.AppName,
		WindowTitle:    event.WindowTitle,
		WifiSSID:       wifiSSID,
		ManuallyMapped: manuallyMapped,
	}
	if event.ProjectID != nil {
		dto.HasProjectID = true
		dto.ProjectID = *event.ProjectID
	}
	if event.ActivityID != nil {
		dto.HasActivityID = true
		dto.ActivityID = *event.ActivityID
	}
	return dto
}

func DTOToDomain(dto EventDTO) domain.Event {
	event := domain.Event{
		TimestampMS: dto.TimestampMS,
		DurationMS:  dto.DurationMS,
		AppName:     dto.AppName,
		WindowTitle: dto.WindowTitle,
	}
	if dto.HasProjectID {
		projectID := dto.ProjectID
		event.ProjectID = &projectID
	}
	if dto.HasActivityID {
		activityID := dto.ActivityID
		event.ActivityID = &activityID
	}
	return event
}
