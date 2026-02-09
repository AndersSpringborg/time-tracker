package api

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"time-tracker/internal/application/contracts"
	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
	apidto "time-tracker/internal/external/api/dto"
)

//go:embed templates/*.html templates/partials/*.html static/* content/*.md
var assets embed.FS

type Server struct {
	app            *usecases.App
	templates      *template.Template
	tidsregSession *tidsregSessionStore
	logger         *log.Logger
}

type pageData struct {
	Title             string
	Page              string
	Body              string
	BodyHTML          template.HTML
	Flash             string
	Range             string
	ReportDate        string
	ReportDateActive  bool
	PrevReportDate    string
	Config            domain.Settings
	NoisePatternsText string
	WorkWifisText     string
	Dashboard         domain.Dashboard
	Report            domain.Report
	Rules             []domain.Rule
	ActiveProjects    []domain.Project
	AllProjects       []domain.Project
	Suggestions       []domain.RuleSuggestion
	SuggestionStats   domain.SuggestionStats
	SuggestionQuery   domain.SuggestionQuery
	AutoApplySummary  string
	BootstrapSummary  string
	BootstrapGroups   []domain.GroupedEvent
	DraftPreview      domain.RuleDraftPreview
	DraftDate         string
	DraftMinDuration  int64
	DraftGroups       []domain.GroupedEvent
	RuleTargets       []ruleTargetOption
	RuleSummary       string
	TidsregCustomers  []tidsregmodel.Customer
	TidsregProjects   []tidsregmodel.Project
	TidsregPreview    tidsregmodel.ImportPreview
	TidsregResult     tidsregmodel.ImportResult
	TidsregSummary    string
	TidsregError      string
	TidsregMode       string
}

type ruleTargetOption struct {
	Value string
	Label string
}

func New(app *usecases.App) (*Server, error) {
	funcs := template.FuncMap{
		"formatDuration":   domain.FormatDuration,
		"formatActivities": formatActivities,
	}
	tpl, err := template.New("root").Funcs(funcs).ParseFS(assets, "templates/*.html", "templates/partials/*.html")
	if err != nil {
		return nil, err
	}
	return &Server{
		app:            app,
		templates:      tpl,
		tidsregSession: newTidsregSessionStore(),
		logger:         log.New(os.Stderr, "api ", log.LstdFlags),
	}, nil
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	staticFS, _ := fs.Sub(assets, "static")
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))

	mux.HandleFunc("/", s.redirect("/dashboard"))
	mux.HandleFunc("/docs", s.handleDocs)
	mux.HandleFunc("/dashboard", s.handleDashboard)
	mux.HandleFunc("/partials/dashboard", s.handleDashboardPartial)
	mux.HandleFunc("/reports", s.handleReports)
	mux.HandleFunc("/partials/reports", s.handleReportsPartial)
	mux.HandleFunc("/rules", s.handleRules)
	mux.HandleFunc("/partials/rules", s.handleRulesPartial)
	mux.HandleFunc("/rules/draft/add", s.handleRulesDraftAdd)
	mux.HandleFunc("/rules/draft/delete", s.handleRulesDraftDelete)
	mux.HandleFunc("/rules/draft/readd-defaults", s.handleRulesDraftReAddDefaults)
	mux.HandleFunc("/rules/draft/save", s.handleRulesDraftSave)
	mux.HandleFunc("/rules/draft/discard", s.handleRulesDraftDiscard)
	mux.HandleFunc("/rules/draft/add-from-selection", s.handleRulesDraftAddFromSelection)
	mux.HandleFunc("/rules/", s.handleRuleDelete)
	mux.HandleFunc("/suggestions", s.handleSuggestionsPage)
	mux.HandleFunc("/partials/suggestions", s.handleSuggestionsPartial)
	mux.HandleFunc("/suggestions/accept", s.handleSuggestionAccept)
	mux.HandleFunc("/suggestions/reject", s.handleSuggestionReject)
	mux.HandleFunc("/suggestions/auto-apply", s.handleSuggestionAutoApply)
	mux.HandleFunc("/partials/suggestions/bootstrap", s.handleSuggestionsBootstrapPartial)
	mux.HandleFunc("/suggestions/bootstrap/map", s.handleSuggestionsBootstrapMap)
	mux.HandleFunc("/projects", s.handleProjects)
	mux.HandleFunc("/partials/projects", s.handleProjectsPartial)
	mux.HandleFunc("/projects/activate", s.handleProjectActivate)
	mux.HandleFunc("/projects/clear", s.handleProjectClear)
	mux.HandleFunc("/projects/", s.handleProjectEnd)
	mux.HandleFunc("/integrations", s.handleIntegrationsPage)
	mux.HandleFunc("/integrations/tidsreg", s.handleTidsregPage)
	mux.HandleFunc("/partials/tidsreg/login", s.handleTidsregLoginPartial)
	mux.HandleFunc("/integrations/tidsreg/session", s.handleTidsregSession)
	mux.HandleFunc("/integrations/tidsreg/session/clear", s.handleTidsregSessionClear)
	mux.HandleFunc("/integrations/tidsreg/projects", s.handleTidsregProjects)
	mux.HandleFunc("/integrations/tidsreg/preview", s.handleTidsregPreview)
	mux.HandleFunc("/integrations/tidsreg/import", s.handleTidsregImport)
	mux.HandleFunc("/settings", s.handleSettings)
	mux.HandleFunc("/collector/start", s.handleCollectorStart)
	mux.HandleFunc("/collector/stop", s.handleCollectorStop)
	mux.HandleFunc("/collector/status", s.handleCollectorStatus)
	return s.requestLoggingMiddleware(s.recoverMiddleware(mux))
}

type loggingResponseWriter struct {
	http.ResponseWriter
	statusCode int
	bodyBytes  []byte
}

func (w *loggingResponseWriter) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *loggingResponseWriter) Write(p []byte) (int, error) {
	if w.statusCode == 0 {
		w.statusCode = http.StatusOK
	}
	const maxBodyLog = 512
	if len(w.bodyBytes) < maxBodyLog {
		remaining := maxBodyLog - len(w.bodyBytes)
		if remaining > len(p) {
			remaining = len(p)
		}
		w.bodyBytes = append(w.bodyBytes, p[:remaining]...)
	}
	return w.ResponseWriter.Write(p)
}

func (w *loggingResponseWriter) status() int {
	if w.statusCode == 0 {
		return http.StatusOK
	}
	return w.statusCode
}

func (s *Server) requestLoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lrw := &loggingResponseWriter{ResponseWriter: w}
		next.ServeHTTP(lrw, r)
		duration := time.Since(start)
		status := lrw.status()
		if status >= 400 {
			body := strings.TrimSpace(strings.ReplaceAll(string(lrw.bodyBytes), "\n", " "))
			s.logf(
				"request method=%s path=%s status=%d duration_ms=%d remote=%s ua=%q error_body=%q",
				r.Method,
				r.URL.RequestURI(),
				status,
				duration.Milliseconds(),
				r.RemoteAddr,
				r.UserAgent(),
				body,
			)
			return
		}
		s.logf("request method=%s path=%s status=%d duration_ms=%d remote=%s", r.Method, r.URL.RequestURI(), status, duration.Milliseconds(), r.RemoteAddr)
	})
}

func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.logf("panic method=%s path=%s err=%v", r.Method, r.URL.RequestURI(), rec)
				http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) logf(format string, args ...any) {
	if s.logger != nil {
		s.logger.Printf(format, args...)
	}
}

func (s *Server) internalError(w http.ResponseWriter, r *http.Request, err error) {
	s.logf("handler_error method=%s path=%s err=%v", r.Method, r.URL.RequestURI(), err)
	http.Error(w, err.Error(), http.StatusInternalServerError)
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	res, err := s.app.Reports.Dashboard(r.Context(), contracts.ReportsDashboardRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "layout", pageData{Title: "Dashboard", Page: "dashboard", Body: "dashboard", Flash: r.URL.Query().Get("flash"), Dashboard: res.Dashboard})
}

func (s *Server) handleDashboardPartial(w http.ResponseWriter, r *http.Request) {
	res, err := s.app.Reports.Dashboard(r.Context(), contracts.ReportsDashboardRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/dashboard_panel", pageData{Dashboard: res.Dashboard})
}

func (s *Server) handleReports(w http.ResponseWriter, r *http.Request) {
	rangeKey := usecases.NormalizeRange(r.URL.Query().Get("range"))
	requestDate := usecases.NormalizeReportDate(r.URL.Query().Get("date"))
	dateActive := requestDate != nil
	if !dateActive && strings.TrimSpace(r.URL.Query().Get("range")) == "" {
		today := time.Now().Format("2006-01-02")
		requestDate = &today
		dateActive = true
	}

	reportDate := time.Now().Format("2006-01-02")
	if requestDate != nil {
		reportDate = *requestDate
	}

	s.render(w, "layout", pageData{
		Title:            "Reports",
		Page:             "reports",
		Body:             "reports",
		Range:            rangeKey,
		ReportDate:       reportDate,
		ReportDateActive: dateActive,
		PrevReportDate:   usecases.PreviousDate(reportDate),
	})
}

func (s *Server) handleReportsPartial(w http.ResponseWriter, r *http.Request) {
	rangeKey := usecases.NormalizeRange(r.URL.Query().Get("range"))
	requestDate := usecases.NormalizeReportDate(r.URL.Query().Get("date"))
	res, err := s.app.Reports.Report(r.Context(), contracts.ReportsBuildRequest{RangeKey: rangeKey, Date: requestDate})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	reportDate := time.Now().Format("2006-01-02")
	if requestDate != nil {
		reportDate = *requestDate
	}

	s.render(w, "partials/report_table", pageData{
		Report:           res.Report,
		Range:            rangeKey,
		ReportDate:       reportDate,
		ReportDateActive: requestDate != nil,
		PrevReportDate:   usecases.PreviousDate(reportDate),
	})
}

func (s *Server) handleRules(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		if err := r.ParseForm(); err != nil {
			http.Error(w, "invalid form", 400)
			return
		}
		in, targetProjectName, targetActivityName, err := parseRuleDraftInput(r)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if _, err := s.app.Rules.AddRuleToDraftFromForm(r.Context(), contracts.RulesDraftAddFromFormRequest{
			Rule:              in,
			TargetProjectName: targetProjectName,
			TargetActivity:    targetActivityName,
		}); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if isHTMX(r) {
			s.renderRulesEditor(w, r, "")
			return
		}
		http.Redirect(w, r, "/rules?flash=Rule+staged", http.StatusSeeOther)
		return
	}
	s.render(w, "layout", pageData{Title: "Rules", Page: "rules", Body: "rules", Flash: r.URL.Query().Get("flash")})
}

func (s *Server) handleRulesPartial(w http.ResponseWriter, r *http.Request) {
	s.renderRulesEditor(w, r, "")
}

func (s *Server) renderRulesEditor(w http.ResponseWriter, r *http.Request, summary string) {
	draftRes, err := s.app.Rules.DraftPreview(r.Context(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	targetRes, err := s.app.Rules.ListAssignmentTargets(r.Context(), contracts.RulesAssignmentTargetsRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	date, minDuration := rulesDraftFiltersFromRequest(r)
	if date == "" {
		datesRes, err := s.app.Rules.ListUnmappedDates(r.Context(), contracts.RulesUnmappedDatesRequest{MinDurationMS: minDuration})
		if err == nil && len(datesRes.Dates) > 0 {
			date = datesRes.Dates[0]
		}
	}
	groups := make([]domain.GroupedEvent, 0)
	if date != "" {
		groupsRes, err := s.app.Rules.ListGroupedUnmappedEvents(r.Context(), contracts.RulesUnmappedGroupsRequest{
			Date:          date,
			MinDurationMS: minDuration,
		})
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		groups = groupsRes.Groups
	}

	targets := make([]ruleTargetOption, 0, len(targetRes.Targets))
	for _, target := range targetRes.Targets {
		targets = append(targets, ruleTargetOption{
			Value: encodeRuleTargetPath(target.ProjectTitle, target.ActivityTitle),
			Label: target.DisplayPath(),
		})
	}

	s.render(w, "partials/rules_editor", pageData{
		DraftPreview:     draftRes.Preview,
		DraftDate:        date,
		DraftMinDuration: minDuration,
		DraftGroups:      groups,
		RuleTargets:      targets,
		RuleSummary:      summary,
	})
}

func (s *Server) handleRulesDraftAdd(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	in, targetProjectName, targetActivityName, err := parseRuleDraftInput(r)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	if _, err := s.app.Rules.AddRuleToDraftFromForm(r.Context(), contracts.RulesDraftAddFromFormRequest{
		Rule:              in,
		TargetProjectName: targetProjectName,
		TargetActivity:    targetActivityName,
	}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.renderRulesEditor(w, r, "Rule staged")
}

func (s *Server) handleRulesDraftDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	id, err := strconv.ParseInt(strings.TrimSpace(r.Form.Get("rule_id")), 10, 64)
	if err != nil {
		http.Error(w, "invalid rule id", 400)
		return
	}
	if _, err := s.app.Rules.DeleteRuleFromDraft(r.Context(), contracts.RulesDraftDeleteRequest{RuleID: id}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.renderRulesEditor(w, r, "Rule removed from draft")
}

func (s *Server) handleRulesDraftReAddDefaults(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	readdRes, err := s.app.Rules.ReAddDefaultRulesToDraft(r.Context(), contracts.RulesDraftReAddDefaultsRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	warnings := readdRes.Warnings
	summary := "Default rules staged"
	if len(warnings) > 0 {
		summary = fmt.Sprintf("Default rules staged with %d warning(s)", len(warnings))
	}
	s.renderRulesEditor(w, r, summary)
}

func (s *Server) handleRulesDraftSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	saveRes, err := s.app.Rules.SaveDraft(r.Context(), contracts.RulesDraftSaveRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	result := saveRes.Result
	summary := fmt.Sprintf("Saved changes: +%d updated %d deleted %d", result.Added, result.Updated, result.Deleted)
	s.renderRulesEditor(w, r, summary)
}

func (s *Server) handleRulesDraftDiscard(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	if _, err := s.app.Rules.DiscardDraft(r.Context(), contracts.RulesDraftDiscardRequest{}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.renderRulesEditor(w, r, "Draft discarded")
}

func (s *Server) handleRulesDraftAddFromSelection(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	in, targetProjectName, targetActivityName, err := parseRuleDraftInput(r)
	if err != nil {
		s.logf("rules_add_from_selection invalid_rule_input err=%v", err)
		http.Error(w, err.Error(), 400)
		return
	}
	groups := parseSelectedGroups(r)
	s.logf(
		"rules_add_from_selection parsed selected_idx=%d groups=%d action_type=%s target_project=%q target_activity=%q sample=%q",
		len(r.Form["selected_idx"]),
		len(groups),
		string(in.ActionType),
		targetProjectName,
		targetActivityName,
		summarizeGroups(groups, 3),
	)
	if len(groups) == 0 {
		http.Error(w, "select at least one event group", 400)
		return
	}
	if _, err := s.app.Rules.AddRegexRuleFromGroupsToDraftFromForm(r.Context(), contracts.RulesDraftAddFromGroupsFormRequest{
		Groups:             groups,
		Rule:               in,
		TargetProjectName:  targetProjectName,
		TargetActivityName: targetActivityName,
	}); err != nil {
		s.internalError(w, r, fmt.Errorf("add regex rule from selection failed: %w", err))
		return
	}
	s.renderRulesEditor(w, r, "Regex rule staged from selected events")
}

func (s *Server) handleRuleDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/delete") {
		http.NotFound(w, r)
		return
	}
	idStr := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/rules/"), "/delete")
	id, err := strconv.ParseInt(strings.Trim(idStr, "/"), 10, 64)
	if err != nil {
		http.Error(w, "invalid rule id", 400)
		return
	}
	if _, err := s.app.Rules.DeleteRule(r.Context(), contracts.RulesDeleteRequest{RuleID: id}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.renderRulesEditor(w, r, "Rule deleted")
}

func (s *Server) handleSuggestionsPage(w http.ResponseWriter, r *http.Request) {
	q := suggestionQueryFromRequest(r)
	s.render(w, "layout", pageData{
		Title:           "Suggestions",
		Page:            "suggestions",
		Body:            "suggestions",
		SuggestionQuery: q,
	})
}

func (s *Server) handleSuggestionsPartial(w http.ResponseWriter, r *http.Request) {
	q := suggestionQueryFromRequest(r)
	res, err := s.app.Rules.AnalyzeSuggestions(r.Context(), contracts.RulesAnalyzeSuggestionsRequest{Query: q})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/suggestions_table", pageData{
		Suggestions:     res.Suggestions,
		SuggestionStats: res.Stats,
		SuggestionQuery: q,
	})
}

func (s *Server) handleSuggestionAccept(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	q := suggestionQueryFromForm(r)
	sug, err := parseSuggestionFromForm(r)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	var datePtr *string
	if q.Date != nil {
		dateCopy := strings.TrimSpace(*q.Date)
		if dateCopy != "" {
			datePtr = &dateCopy
		}
	}
	_, err = s.app.Rules.AcceptSuggestion(r.Context(), contracts.RulesAcceptSuggestionRequest{Input: domain.ApplySuggestionInput{
		Suggestion: sug,
		ApplyNow:   r.Form.Get("apply_now") != "",
		Date:       datePtr,
	}})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	suggestionsRes, _ := s.app.Rules.AnalyzeSuggestions(r.Context(), contracts.RulesAnalyzeSuggestionsRequest{Query: q})
	s.render(w, "partials/suggestions_table", pageData{
		Suggestions:      suggestionsRes.Suggestions,
		SuggestionStats:  suggestionsRes.Stats,
		SuggestionQuery:  q,
		AutoApplySummary: "Suggestion accepted",
	})
}

func (s *Server) handleSuggestionReject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	q := suggestionQueryFromForm(r)
	sug, err := parseSuggestionFromForm(r)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	if _, err := s.app.Rules.RejectSuggestion(r.Context(), contracts.RulesRejectSuggestionRequest{Input: sug}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	suggestionsRes, _ := s.app.Rules.AnalyzeSuggestions(r.Context(), contracts.RulesAnalyzeSuggestionsRequest{Query: q})
	s.render(w, "partials/suggestions_table", pageData{
		Suggestions:      suggestionsRes.Suggestions,
		SuggestionStats:  suggestionsRes.Stats,
		SuggestionQuery:  q,
		AutoApplySummary: "Suggestion hidden for 7 days",
	})
}

func (s *Server) handleSuggestionAutoApply(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	q := suggestionQueryFromForm(r)
	minConf := int(parseIntDefault(r.Form.Get("min_confidence"), 85))
	var datePtr *string
	if q.Date != nil {
		dateCopy := strings.TrimSpace(*q.Date)
		if dateCopy != "" {
			datePtr = &dateCopy
		}
	}
	res, err := s.app.Rules.AutoApplySuggestions(r.Context(), contracts.RulesAutoApplySuggestionsRequest{Input: domain.AutoApplySuggestionsInput{
		Date:          datePtr,
		MinConfidence: minConf,
		ApplyNow:      r.Form.Get("apply_now") != "",
		MinDurationMS: q.MinDurationMS,
		Limit:         q.Limit,
	}})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	suggestionsRes, _ := s.app.Rules.AnalyzeSuggestions(r.Context(), contracts.RulesAnalyzeSuggestionsRequest{Query: q})
	summary := fmt.Sprintf("Analyzed %d suggestions, accepted %d, mapped %d events", res.Result.Analyzed, res.Result.Accepted, res.Result.MappedEvents)
	s.render(w, "partials/suggestions_table", pageData{
		Suggestions:      suggestionsRes.Suggestions,
		SuggestionStats:  suggestionsRes.Stats,
		SuggestionQuery:  q,
		AutoApplySummary: summary,
	})
}

func (s *Server) handleSuggestionsBootstrapPartial(w http.ResponseWriter, r *http.Request) {
	q := suggestionQueryFromRequest(r)
	q.Limit = int(parseIntDefault(r.URL.Query().Get("bootstrap_limit"), 20))
	res, err := s.app.Rules.BootstrapGroups(r.Context(), contracts.RulesBootstrapGroupsRequest{Query: q})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/suggestions_bootstrap_table", pageData{
		BootstrapGroups: res.Groups,
		SuggestionStats: res.Stats,
		SuggestionQuery: q,
	})
}

func (s *Server) handleSuggestionsBootstrapMap(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	q := suggestionQueryFromForm(r)
	q.Limit = int(parseIntDefault(r.Form.Get("bootstrap_limit"), 20))
	projectID := parseIntDefault(r.Form.Get("project_id"), 0)
	activityID := parseIntDefault(r.Form.Get("activity_id"), 0)
	date := strings.TrimSpace(r.Form.Get("date"))
	appName := strings.TrimSpace(r.Form.Get("app_name"))
	windowTitle := r.Form.Get("window_title")
	if date == "" || appName == "" || projectID <= 0 || activityID <= 0 {
		http.Error(w, "date, app_name, project_id and activity_id are required", 400)
		return
	}
	labelRes, err := s.app.Rules.LabelBootstrapGroup(r.Context(), contracts.RulesBootstrapLabelRequest{
		Input: domain.BootstrapLabelInput{
			Date:        date,
			AppName:     appName,
			WindowTitle: windowTitle,
			ProjectID:   projectID,
			ActivityID:  activityID,
			CreateRule:  r.Form.Get("create_rule") != "",
			ApplyNow:    r.Form.Get("apply_now") != "",
		},
	})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	res, err := s.app.Rules.BootstrapGroups(r.Context(), contracts.RulesBootstrapGroupsRequest{Query: q})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	summary := fmt.Sprintf("Bootstrap label applied: mapped %d events, rule created=%v", labelRes.Result.MappedEvents, labelRes.Result.RuleCreated)
	s.render(w, "partials/suggestions_bootstrap_table", pageData{
		BootstrapGroups:  res.Groups,
		SuggestionStats:  res.Stats,
		SuggestionQuery:  q,
		BootstrapSummary: summary,
	})
}

func (s *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	s.render(w, "layout", pageData{Title: "Projects", Page: "projects", Body: "projects", Flash: r.URL.Query().Get("flash")})
}

func (s *Server) handleProjectsPartial(w http.ResponseWriter, r *http.Request) {
	activeRes, err := s.app.Projects.ListActive(r.Context(), contracts.ProjectsListActiveRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	allRes, err := s.app.Projects.ListAll(r.Context(), contracts.ProjectsListAllRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/projects_panel", pageData{ActiveProjects: activeRes.Projects, AllProjects: allRes.Projects})
}

func (s *Server) handleProjectActivate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	_ = r.ParseForm()
	id, err := strconv.ParseInt(r.Form.Get("project_id"), 10, 64)
	if err != nil {
		http.Error(w, "invalid project id", 400)
		return
	}
	if _, err := s.app.Projects.Activate(r.Context(), contracts.ProjectsActivateRequest{ProjectID: id}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.handleProjectsPartial(w, r)
}

func (s *Server) handleProjectClear(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if _, err := s.app.Projects.EndAll(r.Context(), contracts.ProjectsEndAllRequest{}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.handleProjectsPartial(w, r)
}

func (s *Server) handleProjectEnd(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/end") {
		http.NotFound(w, r)
		return
	}
	idStr := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/projects/"), "/end")
	id, err := strconv.ParseInt(strings.Trim(idStr, "/"), 10, 64)
	if err != nil {
		http.Error(w, "invalid project id", 400)
		return
	}
	if _, err := s.app.Projects.End(r.Context(), contracts.ProjectsEndRequest{ProjectID: id}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.handleProjectsPartial(w, r)
}

func (s *Server) handleSettings(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		if err := r.ParseForm(); err != nil {
			http.Error(w, "invalid form", 400)
			return
		}
		loadRes, err := s.app.Settings.Load(r.Context(), contracts.SettingsLoadRequest{})
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		cfg := loadRes.Settings
		cfg.Enabled = r.Form.Get("enabled") != ""
		cfg.WeightedBucketMinutes = parseIntDefault(r.Form.Get("weighted_bucket_minutes"), cfg.WeightedBucketMinutes)
		cfg.WeightedSwitchMinutes = parseIntDefault(r.Form.Get("weighted_switch_minutes"), cfg.WeightedSwitchMinutes)
		cfg.NoiseBucketMinutes = parseIntDefault(r.Form.Get("noise_bucket_minutes"), cfg.NoiseBucketMinutes)
		cfg.NoiseSwitchMinutes = parseIntDefault(r.Form.Get("noise_switch_minutes"), cfg.NoiseSwitchMinutes)
		cfg.NoiseAppPatterns = parseLines(r.Form.Get("noise_app_patterns"))
		cfg.WorkWifis = parseLines(r.Form.Get("work_wifis"))
		if _, err := s.app.Settings.Save(r.Context(), contracts.SettingsSaveRequest{Settings: cfg}); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		http.Redirect(w, r, "/settings?flash=Settings+saved", http.StatusSeeOther)
		return
	}
	loadRes, err := s.app.Settings.Load(r.Context(), contracts.SettingsLoadRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cfg := loadRes.Settings
	pd := pageData{Title: "Settings", Page: "settings", Body: "settings", Flash: r.URL.Query().Get("flash"), Config: cfg, NoisePatternsText: strings.Join(cfg.NoiseAppPatterns, "\n"), WorkWifisText: strings.Join(cfg.WorkWifis, "\n")}
	s.render(w, "layout", pd)
}

func (s *Server) handleCollectorStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if _, err := s.app.Lifecycle.Start(r.Context(), contracts.LifecycleStartRequest{}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.handleCollectorStatus(w, r)
}

func (s *Server) handleCollectorStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if _, err := s.app.Lifecycle.Stop(r.Context(), contracts.LifecycleStopRequest{}); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.handleCollectorStatus(w, r)
}

func (s *Server) handleCollectorStatus(w http.ResponseWriter, r *http.Request) {
	statusRes, err := s.app.Lifecycle.Status(r.Context(), contracts.LifecycleStatusRequest{})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	st := statusRes.Status
	stateClass := "loaded"
	if st.State == "running" {
		stateClass = "running"
	}
	if !st.Loaded {
		stateClass = "not_loaded"
	}
	s.render(w, "partials/collector_status", struct {
		State      string
		StateClass string
		PID        string
	}{State: st.State, StateClass: stateClass, PID: st.PID})
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if name == "layout" {
		pd, ok := data.(pageData)
		if !ok {
			http.Error(w, "invalid layout data", 500)
			return
		}
		if pd.BodyHTML == "" {
			var body bytes.Buffer
			if err := s.templates.ExecuteTemplate(&body, pd.Body, pd); err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			pd.BodyHTML = template.HTML(body.String())
		}
		if err := s.templates.ExecuteTemplate(w, name, pd); err != nil {
			http.Error(w, err.Error(), 500)
		}
		return
	}
	if err := s.templates.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), 500)
	}
}

func (s *Server) redirect(path string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, path, http.StatusSeeOther)
	}
}

func parseRuleInput(r *http.Request) (domain.RuleInput, error) {
	priority := int(parseIntDefault(r.Form.Get("priority"), 100))
	projectID, err := parseNullableInt64(r.Form.Get("project_id"))
	if err != nil {
		return domain.RuleInput{}, fmt.Errorf("invalid project_id")
	}
	activityID, err := parseNullableInt64(r.Form.Get("activity_id"))
	if err != nil {
		return domain.RuleInput{}, fmt.Errorf("invalid activity_id")
	}
	actionType := domain.RuleAction(strings.TrimSpace(r.Form.Get("action_type")))
	if actionType == "" && r.Form.Get("follow_previous") != "" {
		actionType = domain.RuleActionFollowCurrentContext
	}
	dto := apidto.RuleInput{
		RuleKey:            strings.TrimSpace(r.Form.Get("rule_key")),
		Source:             strings.TrimSpace(r.Form.Get("source")),
		Priority:           priority,
		AppPattern:         r.Form.Get("app_pattern"),
		TitlePattern:       r.Form.Get("title_pattern"),
		ProjectID:          projectID,
		ActivityID:         activityID,
		FollowPrevious:     r.Form.Get("follow_previous") != "",
		ActionType:         string(actionType),
		ActionProjectTitle: strings.TrimSpace(r.Form.Get("action_project_title")),
		ActionActivityName: strings.TrimSpace(r.Form.Get("action_activity_name")),
	}
	return dto.ToDomain(), nil
}

func parseRuleDraftInput(r *http.Request) (domain.RuleInput, string, string, error) {
	in, err := parseRuleInput(r)
	if err != nil {
		return domain.RuleInput{}, "", "", err
	}
	projectTitle, activityTitle, err := decodeRuleTargetPath(r.Form.Get("target_path"))
	if err != nil {
		return domain.RuleInput{}, "", "", fmt.Errorf("invalid target_path")
	}
	return in, projectTitle, activityTitle, nil
}

func encodeRuleTargetPath(projectTitle, activityTitle string) string {
	projectTitle = strings.TrimSpace(projectTitle)
	activityTitle = strings.TrimSpace(activityTitle)
	if projectTitle == "" && activityTitle == "" {
		return ""
	}
	return url.QueryEscape(projectTitle) + "|" + url.QueryEscape(activityTitle)
}

func decodeRuleTargetPath(raw string) (string, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "", nil
	}
	parts := strings.SplitN(raw, "|", 2)
	if len(parts) != 2 {
		return "", "", fmt.Errorf("invalid target format")
	}
	projectTitle, err := url.QueryUnescape(parts[0])
	if err != nil {
		return "", "", err
	}
	activityTitle, err := url.QueryUnescape(parts[1])
	if err != nil {
		return "", "", err
	}
	return strings.TrimSpace(projectTitle), strings.TrimSpace(activityTitle), nil
}

func rulesDraftFiltersFromRequest(r *http.Request) (string, int64) {
	date := strings.TrimSpace(r.FormValue("date"))
	if date == "" {
		date = strings.TrimSpace(r.URL.Query().Get("date"))
	}
	minDuration := parseIntDefault(r.FormValue("min_duration_ms"), 2000)
	if raw := strings.TrimSpace(r.URL.Query().Get("min_duration_ms")); raw != "" {
		minDuration = parseIntDefault(raw, minDuration)
	}
	return date, minDuration
}

func parseSelectedGroups(r *http.Request) []domain.GroupedEvent {
	indexes := r.Form["selected_idx"]
	out := make([]domain.GroupedEvent, 0, len(indexes))
	for _, idx := range indexes {
		idx = strings.TrimSpace(idx)
		if idx == "" {
			continue
		}
		app := r.Form.Get("group_app_" + idx)
		title := r.Form.Get("group_title_" + idx)
		if strings.TrimSpace(app) == "" {
			continue
		}
		out = append(out, domain.GroupedEvent{
			AppName:     app,
			WindowTitle: title,
		})
	}
	return out
}

func summarizeGroups(groups []domain.GroupedEvent, limit int) string {
	if len(groups) == 0 {
		return ""
	}
	if limit <= 0 {
		limit = 1
	}
	parts := make([]string, 0, limit)
	for i, g := range groups {
		if i >= limit {
			break
		}
		parts = append(parts, fmt.Sprintf("%s|%s", strings.TrimSpace(g.AppName), strings.TrimSpace(g.WindowTitle)))
	}
	return strings.Join(parts, "; ")
}

func suggestionQueryFromRequest(r *http.Request) domain.SuggestionQuery {
	q := domain.SuggestionQuery{
		MinDurationMS:  parseIntDefault(r.URL.Query().Get("min_duration_ms"), 2000),
		Limit:          int(parseIntDefault(r.URL.Query().Get("limit"), 50)),
		MinEvidence:    int(parseIntDefault(r.URL.Query().Get("min_evidence"), 2)),
		IncludeContext: strings.TrimSpace(r.URL.Query().Get("include_context")) != "0",
		ExcludeApps:    parseCSV(r.URL.Query().Get("exclude_apps")),
	}
	date := strings.TrimSpace(r.URL.Query().Get("date"))
	if date != "" {
		q.Date = &date
	}
	return q
}

func suggestionQueryFromForm(r *http.Request) domain.SuggestionQuery {
	q := domain.SuggestionQuery{
		MinDurationMS:  parseIntDefault(r.Form.Get("min_duration_ms"), 2000),
		Limit:          int(parseIntDefault(r.Form.Get("limit"), 50)),
		MinEvidence:    int(parseIntDefault(r.Form.Get("min_evidence"), 2)),
		IncludeContext: strings.TrimSpace(r.Form.Get("include_context")) != "0",
		ExcludeApps:    parseCSV(r.Form.Get("exclude_apps")),
	}
	date := strings.TrimSpace(r.Form.Get("date"))
	if date != "" {
		q.Date = &date
	}
	return q
}

func parseSuggestionFromForm(r *http.Request) (domain.RuleSuggestion, error) {
	projectID, err := strconv.ParseInt(strings.TrimSpace(r.Form.Get("project_id")), 10, 64)
	if err != nil {
		return domain.RuleSuggestion{}, fmt.Errorf("invalid project_id")
	}
	activityID, err := strconv.ParseInt(strings.TrimSpace(r.Form.Get("activity_id")), 10, 64)
	if err != nil {
		return domain.RuleSuggestion{}, fmt.Errorf("invalid activity_id")
	}
	conf := int(parseIntDefault(r.Form.Get("confidence"), 0))
	score := parseFloatDefault(r.Form.Get("score"), 0)
	ambiguity := parseFloatDefault(r.Form.Get("ambiguity"), 0)
	impactCount := int(parseIntDefault(r.Form.Get("impact_count"), 0))
	impactDur := parseIntDefault(r.Form.Get("impact_duration_ms"), 0)
	evidence := int(parseIntDefault(r.Form.Get("evidence_count"), 0))
	lastSeen := parseIntDefault(r.Form.Get("last_seen_ms"), 0)
	st := r.Form.Get("suggestion_type")
	title := strings.TrimSpace(r.Form.Get("title_pattern"))
	var titlePtr *string
	if title != "" {
		titlePtr = &title
	}
	dto := apidto.SuggestionInput{
		SuggestionType:   st,
		AppPattern:       r.Form.Get("app_pattern"),
		TitlePattern:     titlePtr,
		ProjectID:        projectID,
		ActivityID:       activityID,
		DisplayPath:      r.Form.Get("display_path"),
		Confidence:       conf,
		Score:            score,
		ConfidenceReason: strings.TrimSpace(r.Form.Get("confidence_reason")),
		Ambiguity:        ambiguity,
		ImpactCount:      impactCount,
		ImpactDurationMS: impactDur,
		EvidenceCount:    evidence,
		LastSeenMS:       lastSeen,
		ContextHints:     parseCSV(r.Form.Get("context_hints")),
	}
	return dto.ToDomain(), nil
}

func parseLines(v string) []string {
	parts := strings.Split(v, "\n")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func parseIntDefault(s string, fallback int64) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return fallback
	}
	if v <= 0 {
		return fallback
	}
	return v
}

func parseFloatDefault(s string, fallback float64) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return fallback
	}
	return v
}

func parseCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

func parseNullableInt64(s string) (*int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return nil, err
	}
	return &v, nil
}

func isHTMX(r *http.Request) bool { return r.Header.Get("HX-Request") == "true" }

func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func formatActivities(items []tidsregmodel.Activity) string {
	if len(items) == 0 {
		return "0"
	}
	names := make([]string, 0, len(items))
	for _, item := range items {
		name := strings.TrimSpace(item.Name)
		if name == "" {
			continue
		}
		names = append(names, name)
	}
	if len(names) == 0 {
		return "0"
	}
	return strings.Join(names, ", ")
}
