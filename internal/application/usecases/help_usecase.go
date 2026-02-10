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
			Description: "Manage mapping rules and auto-categorization suggestions",
			Usage:       "tt rules <list|targets|time-tracker|add|delete|suggest|accept|reject|auto-apply|bootstrap|label-group|apply-rules>",
			Flags:       []string{"--format text|json|yaml", "--date YYYY-MM-DD", "--project-id N", "--activity-id N", "--activity NAME", "--dev-activity NAME", "--meeting-activity NAME", "--include-meeting", "--min-confidence N", "--min-evidence N", "--dry-run"},
			SideEffects: []string{"reads database", "writes mapping_rules", "updates event mappings", "records suggestion feedback"},
			Examples: []string{
				"tt rules suggest --format json",
				"tt rules targets --format json",
				"tt rules time-tracker --dry-run",
				"tt rules time-tracker --dev-activity development --meeting-activity meeting",
				"tt rules auto-apply --min-confidence 90 --apply-now",
				"tt rules bootstrap --date 2026-02-06 --format json",
				"tt rules label-group --date 2026-02-06 --app Arc --title 'Daily sync' --activity development --create-rule --apply-now",
				"tt rules apply-rules --dry-run",
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
