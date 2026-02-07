package usecases

import (
	"context"
	"testing"

	"time-tracker/internal/application/contracts"
)

func TestHelpUsecaseGetSchema(t *testing.T) {
	uc := NewHelpUsecase()
	res, err := uc.GetSchema(context.Background(), contracts.HelpGetSchemaRequest{Command: "rules"})
	if err != nil {
		t.Fatalf("get schema failed: %v", err)
	}
	if res.Schema.Command != "rules" {
		t.Fatalf("expected command rules, got %s", res.Schema.Command)
	}
	if len(res.Schema.SideEffects) == 0 {
		t.Fatalf("expected side effects")
	}
}

func TestHelpUsecaseListSchemas(t *testing.T) {
	uc := NewHelpUsecase()
	res, err := uc.ListSchemas(context.Background(), contracts.HelpListSchemasRequest{})
	if err != nil {
		t.Fatalf("list schemas failed: %v", err)
	}
	if len(res.Schemas) == 0 {
		t.Fatalf("expected schemas")
	}
}
