package tidsreg

import (
	"fmt"
	"sort"
	"strings"
)

type Mode int

const (
	ModeTime    Mode = 0
	ModeVoucher Mode = 2
)

type Customer struct {
	CustomerID int64
	Name       string
}

type Project struct {
	ProjectID    int64
	CustomerID   int64
	Name         string
	CustomerName string
}

type Phase struct {
	PhaseID     int64
	ProjectID   int64
	Name        string
	ProjectName string
}

type Activity struct {
	ActivityID int64
	PhaseID    int64
	Name       string
}

type ImportCandidate struct {
	Key          string
	CustomerID   int64
	CustomerName string
	ProjectID    int64
	ProjectName  string
	PhaseID      int64
	PhaseName    string
	TargetTitle  string
	Activities   []Activity
}

type ImportPreview struct {
	Mode          Mode
	Customers     []Customer
	Candidates    []ImportCandidate
	GeneratedAtMS int64
}

type ImportResult struct {
	ImportedCandidates int
	ProjectsCreated    int
	ProjectsUpdated    int
	ActivitiesCreated  int
	ActivitiesUpdated  int
	ActivitiesDeleted  int
}

func ParseMode(v string) Mode {
	if strings.TrimSpace(v) == "2" {
		return ModeVoucher
	}
	return ModeTime
}

func BuildImportKey(customerID, projectID, phaseID int64) string {
	return fmt.Sprintf("%d:%d:%d", customerID, projectID, phaseID)
}

func BuildProjectTitle(customerName, projectName, phaseName string) string {
	parts := []string{normalizeSegment(customerName), normalizeSegment(projectName), normalizeSegment(phaseName)}
	return strings.Join(parts, " > ")
}

func BuildProjectMetadata(customerID, projectID, phaseID int64) string {
	return fmt.Sprintf(
		"source=tidsreg customer_id=%d project_id=%d variant_key=%s",
		customerID,
		projectID,
		BuildImportKey(customerID, projectID, phaseID),
	)
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

func NormalizeActivities(items []Activity) []Activity {
	out := make([]Activity, 0, len(items))
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

func FilterImportCandidates(preview ImportPreview, selectedKeys []string) []ImportCandidate {
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
	out := make([]ImportCandidate, 0, len(preview.Candidates))
	for _, candidate := range preview.Candidates {
		if _, ok := allowed[candidate.Key]; ok {
			out = append(out, candidate)
		}
	}
	return out
}
