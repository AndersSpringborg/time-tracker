package usecases

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"time-tracker/internal/application/contracts"
	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
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

func (u *TidsregImportUsecase) AuthenticateAndListCustomers(ctx context.Context, req contracts.TidsregAuthenticateRequest) (contracts.TidsregAuthenticateResponse, error) {
	if strings.TrimSpace(req.Username) == "" || strings.TrimSpace(req.Password) == "" {
		return contracts.TidsregAuthenticateResponse{}, fmt.Errorf("username and password are required")
	}
	cookie, err := u.gateway.Authenticate(ctx, req.Username, req.Password)
	if err != nil {
		return contracts.TidsregAuthenticateResponse{}, err
	}
	customers, err := u.gateway.ListCustomers(ctx, cookie, req.Mode)
	if err != nil {
		return contracts.TidsregAuthenticateResponse{}, err
	}
	sort.Slice(customers, func(i, j int) bool {
		if strings.EqualFold(customers[i].Name, customers[j].Name) {
			return customers[i].CustomerID < customers[j].CustomerID
		}
		return strings.ToLower(customers[i].Name) < strings.ToLower(customers[j].Name)
	})
	return contracts.TidsregAuthenticateResponse{
		SessionCookie: cookie,
		Customers:     customers,
	}, nil
}

func (u *TidsregImportUsecase) BuildProjects(ctx context.Context, req contracts.TidsregBuildProjectsRequest) (contracts.TidsregBuildProjectsResponse, error) {
	if strings.TrimSpace(req.SessionCookie) == "" {
		return contracts.TidsregBuildProjectsResponse{}, fmt.Errorf("missing tidsreg session")
	}
	if len(req.SelectedCustomerIDs) == 0 {
		return contracts.TidsregBuildProjectsResponse{}, fmt.Errorf("select at least one customer")
	}

	selectedCustomerSet := make(map[int64]struct{}, len(req.SelectedCustomerIDs))
	for _, id := range req.SelectedCustomerIDs {
		if id > 0 {
			selectedCustomerSet[id] = struct{}{}
		}
	}
	if len(selectedCustomerSet) == 0 {
		return contracts.TidsregBuildProjectsResponse{}, fmt.Errorf("select at least one valid customer")
	}

	selectedCustomers := make([]tidsregmodel.Customer, 0, len(selectedCustomerSet))
	for _, customer := range req.Customers {
		if _, ok := selectedCustomerSet[customer.CustomerID]; ok {
			selectedCustomers = append(selectedCustomers, customer)
		}
	}
	if len(selectedCustomers) == 0 {
		return contracts.TidsregBuildProjectsResponse{}, fmt.Errorf("selected customers were not found in session")
	}

	sort.Slice(selectedCustomers, func(i, j int) bool {
		if strings.EqualFold(selectedCustomers[i].Name, selectedCustomers[j].Name) {
			return selectedCustomers[i].CustomerID < selectedCustomers[j].CustomerID
		}
		return strings.ToLower(selectedCustomers[i].Name) < strings.ToLower(selectedCustomers[j].Name)
	})

	projects := make([]tidsregmodel.Project, 0)
	for _, customer := range selectedCustomers {
		customerProjects, err := u.gateway.ListProjects(ctx, req.SessionCookie, customer.CustomerID, req.Mode)
		if err != nil {
			return contracts.TidsregBuildProjectsResponse{}, err
		}
		sort.Slice(customerProjects, func(i, j int) bool {
			if strings.EqualFold(customerProjects[i].Name, customerProjects[j].Name) {
				return customerProjects[i].ProjectID < customerProjects[j].ProjectID
			}
			return strings.ToLower(customerProjects[i].Name) < strings.ToLower(customerProjects[j].Name)
		})
		for _, project := range customerProjects {
			project.CustomerName = customer.Name
			projects = append(projects, project)
		}
	}

	sort.Slice(projects, func(i, j int) bool {
		if strings.EqualFold(projects[i].CustomerName, projects[j].CustomerName) {
			if strings.EqualFold(projects[i].Name, projects[j].Name) {
				return projects[i].ProjectID < projects[j].ProjectID
			}
			return strings.ToLower(projects[i].Name) < strings.ToLower(projects[j].Name)
		}
		return strings.ToLower(projects[i].CustomerName) < strings.ToLower(projects[j].CustomerName)
	})

	return contracts.TidsregBuildProjectsResponse{Projects: projects}, nil
}

func (u *TidsregImportUsecase) BuildPreview(ctx context.Context, req contracts.TidsregBuildPreviewRequest) (contracts.TidsregBuildPreviewResponse, error) {
	if strings.TrimSpace(req.SessionCookie) == "" {
		return contracts.TidsregBuildPreviewResponse{}, fmt.Errorf("missing tidsreg session")
	}
	if len(req.SelectedProjectIDs) == 0 {
		return contracts.TidsregBuildPreviewResponse{}, fmt.Errorf("select at least one project")
	}

	selectedProjectSet := make(map[int64]struct{}, len(req.SelectedProjectIDs))
	for _, id := range req.SelectedProjectIDs {
		if id > 0 {
			selectedProjectSet[id] = struct{}{}
		}
	}
	if len(selectedProjectSet) == 0 {
		return contracts.TidsregBuildPreviewResponse{}, fmt.Errorf("select at least one valid project")
	}

	selectedProjects := make([]tidsregmodel.Project, 0, len(selectedProjectSet))
	for _, project := range req.Projects {
		if _, ok := selectedProjectSet[project.ProjectID]; ok {
			selectedProjects = append(selectedProjects, project)
		}
	}
	if len(selectedProjects) == 0 {
		return contracts.TidsregBuildPreviewResponse{}, fmt.Errorf("selected projects were not found in session")
	}

	sort.Slice(selectedProjects, func(i, j int) bool {
		if strings.EqualFold(selectedProjects[i].CustomerName, selectedProjects[j].CustomerName) {
			if strings.EqualFold(selectedProjects[i].Name, selectedProjects[j].Name) {
				return selectedProjects[i].ProjectID < selectedProjects[j].ProjectID
			}
			return strings.ToLower(selectedProjects[i].Name) < strings.ToLower(selectedProjects[j].Name)
		}
		return strings.ToLower(selectedProjects[i].CustomerName) < strings.ToLower(selectedProjects[j].CustomerName)
	})

	customerMap := make(map[int64]tidsregmodel.Customer)
	for _, project := range selectedProjects {
		customerMap[project.CustomerID] = tidsregmodel.Customer{
			CustomerID: project.CustomerID,
			Name:       project.CustomerName,
		}
	}
	selectedCustomers := make([]tidsregmodel.Customer, 0, len(customerMap))
	for _, customer := range customerMap {
		selectedCustomers = append(selectedCustomers, customer)
	}
	sort.Slice(selectedCustomers, func(i, j int) bool {
		if strings.EqualFold(selectedCustomers[i].Name, selectedCustomers[j].Name) {
			return selectedCustomers[i].CustomerID < selectedCustomers[j].CustomerID
		}
		return strings.ToLower(selectedCustomers[i].Name) < strings.ToLower(selectedCustomers[j].Name)
	})

	preview := tidsregmodel.ImportPreview{
		Mode:          req.Mode,
		Customers:     selectedCustomers,
		Candidates:    make([]tidsregmodel.ImportCandidate, 0),
		GeneratedAtMS: time.Now().UnixMilli(),
	}

	for _, project := range selectedProjects {
		projectName := project.Name
		phases, err := u.gateway.ListPhases(ctx, req.SessionCookie, project.ProjectID, req.Mode)
		if err != nil {
			return contracts.TidsregBuildPreviewResponse{}, err
		}
		sort.Slice(phases, func(i, j int) bool {
			if strings.EqualFold(phases[i].Name, phases[j].Name) {
				return phases[i].PhaseID < phases[j].PhaseID
			}
			return strings.ToLower(phases[i].Name) < strings.ToLower(phases[j].Name)
		})

		for _, phase := range phases {
			activities, err := u.gateway.ListActivities(ctx, req.SessionCookie, phase.PhaseID, req.Mode)
			if err != nil {
				return contracts.TidsregBuildPreviewResponse{}, err
			}
			activities = tidsregmodel.NormalizeActivities(activities)
			candidate := tidsregmodel.ImportCandidate{
				Key:          tidsregmodel.BuildImportKey(project.CustomerID, project.ProjectID, phase.PhaseID),
				CustomerID:   project.CustomerID,
				CustomerName: project.CustomerName,
				ProjectID:    project.ProjectID,
				ProjectName:  projectName,
				PhaseID:      phase.PhaseID,
				PhaseName:    phase.Name,
				TargetTitle:  tidsregmodel.BuildProjectTitle(project.CustomerName, projectName, phase.Name),
				Activities:   activities,
			}
			preview.Candidates = append(preview.Candidates, candidate)
		}
	}

	sort.Slice(preview.Candidates, func(i, j int) bool {
		if strings.EqualFold(preview.Candidates[i].TargetTitle, preview.Candidates[j].TargetTitle) {
			return preview.Candidates[i].Key < preview.Candidates[j].Key
		}
		return strings.ToLower(preview.Candidates[i].TargetTitle) < strings.ToLower(preview.Candidates[j].TargetTitle)
	})
	return contracts.TidsregBuildPreviewResponse{Preview: preview}, nil
}

func (u *TidsregImportUsecase) Commit(ctx context.Context, req contracts.TidsregCommitRequest) (contracts.TidsregCommitResponse, error) {
	candidates := tidsregmodel.FilterImportCandidates(req.Preview, req.SelectedKeys)
	if len(candidates) == 0 {
		return contracts.TidsregCommitResponse{}, fmt.Errorf("select at least one project variant to import")
	}

	result := tidsregmodel.ImportResult{ImportedCandidates: len(candidates)}
	for _, candidate := range candidates {
		upsert, err := u.repo.UpsertImportedProject(ctx, domain.ImportedProjectUpsert{
			Source:             tidsregSource,
			ExternalCustomerID: candidate.CustomerID,
			ExternalProjectID:  candidate.ProjectID,
			ExternalVariantKey: tidsregmodel.BuildImportKey(candidate.CustomerID, candidate.ProjectID, candidate.PhaseID),
			Title:              candidate.TargetTitle,
			Metadata:           tidsregmodel.BuildProjectMetadata(candidate.CustomerID, candidate.ProjectID, candidate.PhaseID),
		})
		if err != nil {
			return contracts.TidsregCommitResponse{}, err
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
			return contracts.TidsregCommitResponse{}, err
		}
		result.ActivitiesCreated += syncResult.Created
		result.ActivitiesUpdated += syncResult.Updated
		result.ActivitiesDeleted += syncResult.Deleted
	}
	return contracts.TidsregCommitResponse{Result: result}, nil
}
