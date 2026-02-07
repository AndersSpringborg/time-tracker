package domain

import (
	"fmt"
	"sort"
	"strings"
)

type TidsregMode int

const (
	TidsregModeTime    TidsregMode = 0
	TidsregModeVoucher TidsregMode = 2
)

type TidsregCustomer struct {
	CustomerID int64  `json:"customer_id"`
	Name       string `json:"name"`
}

type TidsregProject struct {
	ProjectID    int64  `json:"project_id"`
	CustomerID   int64  `json:"customer_id"`
	Name         string `json:"name"`
	CustomerName string `json:"customer_name,omitempty"`
}

type TidsregPhase struct {
	PhaseID     int64  `json:"phase_id"`
	ProjectID   int64  `json:"project_id"`
	Name        string `json:"name"`
	ProjectName string `json:"project_name,omitempty"`
}

type TidsregActivity struct {
	ActivityID int64  `json:"activity_id"`
	PhaseID    int64  `json:"phase_id"`
	Name       string `json:"name"`
}

type TidsregImportCandidate struct {
	Key          string            `json:"key"`
	CustomerID   int64             `json:"customer_id"`
	CustomerName string            `json:"customer_name"`
	ProjectID    int64             `json:"project_id"`
	ProjectName  string            `json:"project_name"`
	PhaseID      int64             `json:"phase_id"`
	PhaseName    string            `json:"phase_name"`
	TargetTitle  string            `json:"target_title"`
	Activities   []TidsregActivity `json:"activities"`
}

type TidsregImportPreview struct {
	Mode          TidsregMode              `json:"mode"`
	Customers     []TidsregCustomer        `json:"customers"`
	Candidates    []TidsregImportCandidate `json:"candidates"`
	GeneratedAtMS int64                    `json:"generated_at_ms"`
}

type TidsregImportResult struct {
	ImportedCandidates int `json:"imported_candidates"`
	ProjectsCreated    int `json:"projects_created"`
	ProjectsUpdated    int `json:"projects_updated"`
	ActivitiesCreated  int `json:"activities_created"`
	ActivitiesUpdated  int `json:"activities_updated"`
	ActivitiesDeleted  int `json:"activities_deleted"`
}

type ImportedProjectUpsert struct {
	Source             string
	ExternalCustomerID int64
	ExternalProjectID  int64
	ExternalPhaseID    int64
	Title              string
	Metadata           string
}

type ImportedProjectUpsertResult struct {
	ProjectID int64
	Created   bool
	Updated   bool
}

type ImportedActivityUpsert struct {
	Source             string
	ExternalActivityID int64
	Title              string
}

type ImportedActivitySyncResult struct {
	Created int
	Updated int
	Deleted int
}

func ParseTidsregMode(v string) TidsregMode {
	if strings.TrimSpace(v) == "2" {
		return TidsregModeVoucher
	}
	return TidsregModeTime
}

func BuildTidsregImportKey(customerID, projectID, phaseID int64) string {
	return fmt.Sprintf("%d:%d:%d", customerID, projectID, phaseID)
}

func BuildProjectTitle(customerName, projectName, phaseName string) string {
	parts := []string{normalizeSegment(customerName), normalizeSegment(projectName), normalizeSegment(phaseName)}
	return strings.Join(parts, " > ")
}

func BuildProjectMetadata(customerID, projectID, phaseID int64) string {
	return fmt.Sprintf("source=tidsreg customer_id=%d project_id=%d phase_id=%d", customerID, projectID, phaseID)
}

func normalizeSegment(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return "Unknown"
	}
	v = strings.ReplaceAll(v, "\n", " ")
	v = strings.ReplaceAll(v, "\t", " ")
	return strings.Join(strings.Fields(v), " ")
}

func NormalizeTidsregActivities(items []TidsregActivity) []TidsregActivity {
	out := make([]TidsregActivity, 0, len(items))
	seen := make(map[int64]struct{}, len(items))
	for _, item := range items {
		if item.ActivityID <= 0 {
			continue
		}
		if _, ok := seen[item.ActivityID]; ok {
			continue
		}
		name := normalizeSegment(item.Name)
		if strings.EqualFold(name, "Unknown") {
			continue
		}
		item.Name = name
		out = append(out, item)
		seen[item.ActivityID] = struct{}{}
	}
	sort.Slice(out, func(i, j int) bool {
		if strings.EqualFold(out[i].Name, out[j].Name) {
			return out[i].ActivityID < out[j].ActivityID
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func FilterImportCandidates(preview TidsregImportPreview, selectedKeys []string) []TidsregImportCandidate {
	if len(selectedKeys) == 0 {
		return nil
	}
	allowed := make(map[string]struct{}, len(selectedKeys))
	for _, key := range selectedKeys {
		key = strings.TrimSpace(key)
		if key != "" {
			allowed[key] = struct{}{}
		}
	}
	out := make([]TidsregImportCandidate, 0, len(preview.Candidates))
	for _, candidate := range preview.Candidates {
		if _, ok := allowed[candidate.Key]; ok {
			out = append(out, candidate)
		}
	}
	return out
}
