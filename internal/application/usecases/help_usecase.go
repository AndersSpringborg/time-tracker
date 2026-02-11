package usecases

import (
	"context"
	"fmt"
	"sort"

	"time-tracker/internal/application/contracts"
)

type HelpUsecase struct {
	schemas map[string]contracts.HelpCommandSchema
}

func NewHelpUsecase() *HelpUsecase {
	s := map[string]contracts.HelpCommandSchema{
		"install": {
			Command:     "install",
			Description: "Install embedded worker and launchd agent",
			Usage:       "tt install",
			SideEffects: []string{"writes filesystem", "launchctl bootstrap", "launchctl kickstart"},
			Examples:    []string{"tt install"},
		},
		"serve": {
			Command:     "serve",
			Description: "Serve HTMX web UI",
			Usage:       "tt serve [--addr 127.0.0.1:8080]",
			Flags:       []string{"--addr"},
			SideEffects: []string{"opens http listener", "reads database"},
			Examples:    []string{"tt serve --addr 127.0.0.1:8090"},
		},
		"rules": {
			Command:     "rules",
			Description: "Manage event-to-project/activity mapping rules",
			Usage:       "tt rules <list|targets|time-tracker|add|delete|apply-rules>",
			Flags:       []string{"--format text|json|yaml", "--date YYYY-MM-DD", "--project-id N", "--activity-id N", "--dev-activity NAME", "--meeting-activity NAME", "--include-meeting", "--dry-run"},
			SideEffects: []string{"reads database", "writes mapping_rules", "updates event mappings"},
			Examples: []string{
				"tt rules targets --format json",
				"tt rules time-tracker --dry-run",
				"tt rules time-tracker --dev-activity development --meeting-activity meeting",
				"tt rules add --app-pattern 'IntelliJ IDEA' --title-pattern '*project a*' --follow-previous",
				"tt rules apply-rules --dry-run",
			},
		},
		"projects": {
			Command:     "projects",
			Description: "Manage project context and project activities from CLI",
			Usage:       "tt projects <list|create|activities|add-activity|add|end|clear|current>",
			Flags:       []string{"--format text|json|yaml", "--scope active|all|archived", "--project-id N", "--project TITLE", "--title NAME", "--metadata TEXT", "--activate"},
			SideEffects: []string{"reads database", "writes projects", "writes activities", "updates project assignments"},
			Examples: []string{
				"tt projects list --scope all --format json",
				"tt projects create --title time-tracker --metadata \"local dev\"",
				"tt projects add --project time-tracker",
				"tt projects add-activity --project time-tracker --title development",
				"tt projects activities --project time-tracker --format json",
			},
		},
		"review": {
			Command:     "review",
			Description: "Review unmapped events by date/group and apply mappings",
			Usage:       "tt review <dates|groups|map-group|discard-group>",
			Flags:       []string{"--date YYYY-MM-DD", "--project-id N", "--activity-id N", "--min-duration-ms N", "--format text|json|yaml"},
			SideEffects: []string{"reads database", "updates event mappings"},
			Examples:    []string{"tt review dates", "tt review groups --date 2026-02-06"},
		},
	}
	return &HelpUsecase{schemas: s}
}

func (u *HelpUsecase) GetSchema(_ context.Context, req contracts.HelpGetSchemaRequest) (contracts.HelpGetSchemaResponse, error) {
	if req.Command == "" {
		return contracts.HelpGetSchemaResponse{}, fmt.Errorf("command is required")
	}
	s, ok := u.schemas[req.Command]
	if !ok {
		return contracts.HelpGetSchemaResponse{}, fmt.Errorf("unknown command: %s", req.Command)
	}
	return contracts.HelpGetSchemaResponse{Schema: s}, nil
}

func (u *HelpUsecase) ListSchemas(_ context.Context, _ contracts.HelpListSchemasRequest) (contracts.HelpListSchemasResponse, error) {
	out := make([]contracts.HelpCommandSchema, 0, len(u.schemas))
	for _, s := range u.schemas {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Command < out[j].Command })
	return contracts.HelpListSchemasResponse{Schemas: out}, nil
}
