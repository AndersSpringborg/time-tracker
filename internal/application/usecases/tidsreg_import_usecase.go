package usecases

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

const tidsregSource = "tidsreg"

type TidsregImportUsecase struct {
	gateway ports.TidsregGateway
	repo    ports.TidsregImportRepository
}

func NewTidsregImportUsecase(gateway ports.TidsregGateway, repo ports.TidsregImportRepository) *TidsregImportUsecase {
	return &TidsregImportUsecase{gateway: gateway, repo: repo}
}

func (u *TidsregImportUsecase) AuthenticateAndListCustomers(ctx context.Context, username, password string, mode domain.TidsregMode) (string, []domain.TidsregCustomer, error) {
	if strings.TrimSpace(username) == "" || strings.TrimSpace(password) == "" {
		return "", nil, fmt.Errorf("username and password are required")
	}
	cookie, err := u.gateway.Authenticate(ctx, username, password)
	if err != nil {
		return "", nil, err
	}
	customers, err := u.gateway.ListCustomers(ctx, cookie, mode)
	if err != nil {
		return "", nil, err
	}
	sort.Slice(customers, func(i, j int) bool {
		if strings.EqualFold(customers[i].Name, customers[j].Name) {
			return customers[i].CustomerID < customers[j].CustomerID
		}
		return strings.ToLower(customers[i].Name) < strings.ToLower(customers[j].Name)
	})
	return cookie, customers, nil
}

func (u *TidsregImportUsecase) BuildPreview(ctx context.Context, cookie string, mode domain.TidsregMode, customers []domain.TidsregCustomer, selectedCustomerIDs []int64) (domain.TidsregImportPreview, error) {
	if strings.TrimSpace(cookie) == "" {
		return domain.TidsregImportPreview{}, fmt.Errorf("missing tidsreg session")
	}
	if len(selectedCustomerIDs) == 0 {
		return domain.TidsregImportPreview{}, fmt.Errorf("select at least one customer")
	}

	selectedSet := make(map[int64]struct{}, len(selectedCustomerIDs))
	for _, id := range selectedCustomerIDs {
		if id > 0 {
			selectedSet[id] = struct{}{}
		}
	}
	if len(selectedSet) == 0 {
		return domain.TidsregImportPreview{}, fmt.Errorf("select at least one valid customer")
	}

	selectedCustomers := make([]domain.TidsregCustomer, 0, len(selectedSet))
	for _, customer := range customers {
		if _, ok := selectedSet[customer.CustomerID]; ok {
			selectedCustomers = append(selectedCustomers, customer)
		}
	}
	if len(selectedCustomers) == 0 {
		return domain.TidsregImportPreview{}, fmt.Errorf("selected customers were not found in session")
	}

	sort.Slice(selectedCustomers, func(i, j int) bool {
		if strings.EqualFold(selectedCustomers[i].Name, selectedCustomers[j].Name) {
			return selectedCustomers[i].CustomerID < selectedCustomers[j].CustomerID
		}
		return strings.ToLower(selectedCustomers[i].Name) < strings.ToLower(selectedCustomers[j].Name)
	})

	preview := domain.TidsregImportPreview{
		Mode:          mode,
		Customers:     selectedCustomers,
		Candidates:    make([]domain.TidsregImportCandidate, 0),
		GeneratedAtMS: time.Now().UnixMilli(),
	}

	for _, customer := range selectedCustomers {
		projects, err := u.gateway.ListProjects(ctx, cookie, customer.CustomerID, mode)
		if err != nil {
			return domain.TidsregImportPreview{}, err
		}
		sort.Slice(projects, func(i, j int) bool {
			if strings.EqualFold(projects[i].Name, projects[j].Name) {
				return projects[i].ProjectID < projects[j].ProjectID
			}
			return strings.ToLower(projects[i].Name) < strings.ToLower(projects[j].Name)
		})

		for _, project := range projects {
			projectName := project.Name
			phases, err := u.gateway.ListPhases(ctx, cookie, project.ProjectID, mode)
			if err != nil {
				return domain.TidsregImportPreview{}, err
			}
			sort.Slice(phases, func(i, j int) bool {
				if strings.EqualFold(phases[i].Name, phases[j].Name) {
					return phases[i].PhaseID < phases[j].PhaseID
				}
				return strings.ToLower(phases[i].Name) < strings.ToLower(phases[j].Name)
			})

			for _, phase := range phases {
				activities, err := u.gateway.ListActivities(ctx, cookie, phase.PhaseID, mode)
				if err != nil {
					return domain.TidsregImportPreview{}, err
				}
				activities = domain.NormalizeTidsregActivities(activities)
				candidate := domain.TidsregImportCandidate{
					Key:          domain.BuildTidsregImportKey(customer.CustomerID, project.ProjectID, phase.PhaseID),
					CustomerID:   customer.CustomerID,
					CustomerName: customer.Name,
					ProjectID:    project.ProjectID,
					ProjectName:  projectName,
					PhaseID:      phase.PhaseID,
					PhaseName:    phase.Name,
					TargetTitle:  domain.BuildProjectTitle(customer.Name, projectName, phase.Name),
					Activities:   activities,
				}
				preview.Candidates = append(preview.Candidates, candidate)
			}
		}
	}

	sort.Slice(preview.Candidates, func(i, j int) bool {
		if strings.EqualFold(preview.Candidates[i].TargetTitle, preview.Candidates[j].TargetTitle) {
			return preview.Candidates[i].Key < preview.Candidates[j].Key
		}
		return strings.ToLower(preview.Candidates[i].TargetTitle) < strings.ToLower(preview.Candidates[j].TargetTitle)
	})
	return preview, nil
}

func (u *TidsregImportUsecase) Commit(ctx context.Context, preview domain.TidsregImportPreview, selectedKeys []string) (domain.TidsregImportResult, error) {
	candidates := domain.FilterImportCandidates(preview, selectedKeys)
	if len(candidates) == 0 {
		return domain.TidsregImportResult{}, fmt.Errorf("select at least one project phase to import")
	}

	result := domain.TidsregImportResult{ImportedCandidates: len(candidates)}
	for _, candidate := range candidates {
		upsert, err := u.repo.UpsertImportedProject(ctx, domain.ImportedProjectUpsert{
			Source:             tidsregSource,
			ExternalCustomerID: candidate.CustomerID,
			ExternalProjectID:  candidate.ProjectID,
			ExternalPhaseID:    candidate.PhaseID,
			Title:              candidate.TargetTitle,
			Metadata:           domain.BuildProjectMetadata(candidate.CustomerID, candidate.ProjectID, candidate.PhaseID),
		})
		if err != nil {
			return result, err
		}
		if upsert.Created {
			result.ProjectsCreated++
		}
		if upsert.Updated {
			result.ProjectsUpdated++
		}

		activities := make([]domain.ImportedActivityUpsert, 0, len(candidate.Activities))
		for _, activity := range candidate.Activities {
			activities = append(activities, domain.ImportedActivityUpsert{
				Source:             tidsregSource,
				ExternalActivityID: activity.ActivityID,
				Title:              activity.Name,
			})
		}
		syncResult, err := u.repo.SyncImportedActivities(ctx, upsert.ProjectID, activities)
		if err != nil {
			return result, err
		}
		result.ActivitiesCreated += syncResult.Created
		result.ActivitiesUpdated += syncResult.Updated
		result.ActivitiesDeleted += syncResult.Deleted
	}
	return result, nil
}
