package usecases

import (
	"encoding/json"
	"testing"
)

func TestHelpUsecaseSchemaJSON(t *testing.T) {
	uc := NewHelpUsecase()
	b, err := uc.SchemaJSON("rules")
	if err != nil {
		t.Fatalf("schema json failed: %v", err)
	}

	var payload map[string]any
	if err := json.Unmarshal(b, &payload); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if payload["command"] != "rules" {
		t.Fatalf("expected command rules, got %v", payload["command"])
	}
	if _, ok := payload["side_effects"]; !ok {
		t.Fatalf("expected side_effects in schema")
	}
}
