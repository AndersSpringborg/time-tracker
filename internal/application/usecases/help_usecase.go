package usecases

import (
	"encoding/json"
	"fmt"
	"sort"
)

type CommandSchema struct {
	Command     string   `json:"command"`
	Description string   `json:"description"`
	Usage       string   `json:"usage"`
	Flags       []string `json:"flags"`
	Examples    []string `json:"examples"`
	SideEffects []string `json:"side_effects"`
}

type HelpUsecase struct {
	schemas map[string]CommandSchema
}

func NewHelpUsecase() *HelpUsecase {
	s := map[string]CommandSchema{
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
			Usage:       "tt rules <list|add|delete|suggest|accept|auto-apply|apply-rules>",
			Flags:       []string{"--format text|json|yaml", "--date YYYY-MM-DD", "--project-id N", "--activity-id N", "--min-confidence N", "--dry-run"},
			SideEffects: []string{"reads database", "writes mapping_rules", "updates event mappings"},
			Examples: []string{
				"tt rules suggest --format json",
				"tt rules auto-apply --min-confidence 90 --apply-now",
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

func (u *HelpUsecase) Schema(command string) (CommandSchema, error) {
	if command == "" {
		return CommandSchema{}, fmt.Errorf("command is required")
	}
	s, ok := u.schemas[command]
	if !ok {
		return CommandSchema{}, fmt.Errorf("unknown command: %s", command)
	}
	return s, nil
}

func (u *HelpUsecase) SchemaJSON(command string) ([]byte, error) {
	s, err := u.Schema(command)
	if err != nil {
		return nil, err
	}
	return json.MarshalIndent(s, "", "  ")
}

func (u *HelpUsecase) ListSchemas() []CommandSchema {
	out := make([]CommandSchema, 0, len(u.schemas))
	for _, s := range u.schemas {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Command < out[j].Command })
	return out
}
