package api

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"strconv"
	"strings"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

//go:embed templates/*.html templates/partials/*.html static/*
var assets embed.FS

type Server struct {
	app       *usecases.App
	templates *template.Template
}

type pageData struct {
	Title             string
	Page              string
	Body              string
	BodyHTML          template.HTML
	Flash             string
	Range             string
	Config            domain.Settings
	NoisePatternsText string
	WorkWifisText     string
	Dashboard         domain.Dashboard
	Report            domain.Report
	Rules             []domain.Rule
	ActiveProjects    []domain.Project
	AllProjects       []domain.Project
	Suggestions       []domain.RuleSuggestion
	AutoApplySummary  string
	DraftPreview      domain.RuleDraftPreview
	DraftDate         string
	DraftMinDuration  int64
	DraftGroups       []domain.GroupedEvent
	RuleSummary       string
}

func New(app *usecases.App) (*Server, error) {
	funcs := template.FuncMap{"formatDuration": domain.FormatDuration}
	tpl, err := template.New("root").Funcs(funcs).ParseFS(assets, "templates/*.html", "templates/partials/*.html")
	if err != nil {
		return nil, err
	}
	return &Server{app: app, templates: tpl}, nil
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	staticFS, _ := fs.Sub(assets, "static")
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))

	mux.HandleFunc("/", s.redirect("/dashboard"))
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
	mux.HandleFunc("/suggestions/auto-apply", s.handleSuggestionAutoApply)
	mux.HandleFunc("/projects", s.handleProjects)
	mux.HandleFunc("/partials/projects", s.handleProjectsPartial)
	mux.HandleFunc("/projects/activate", s.handleProjectActivate)
	mux.HandleFunc("/projects/clear", s.handleProjectClear)
	mux.HandleFunc("/projects/", s.handleProjectEnd)
	mux.HandleFunc("/settings", s.handleSettings)
	mux.HandleFunc("/collector/start", s.handleCollectorStart)
	mux.HandleFunc("/collector/stop", s.handleCollectorStop)
	mux.HandleFunc("/collector/status", s.handleCollectorStatus)
	return mux
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	d, err := s.app.Reports.Dashboard(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "layout", pageData{Title: "Dashboard", Page: "dashboard", Body: "dashboard", Flash: r.URL.Query().Get("flash"), Dashboard: d})
}

func (s *Server) handleDashboardPartial(w http.ResponseWriter, r *http.Request) {
	d, err := s.app.Reports.Dashboard(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/dashboard_panel", pageData{Dashboard: d})
}

func (s *Server) handleReports(w http.ResponseWriter, r *http.Request) {
	rangeKey := usecases.NormalizeRange(r.URL.Query().Get("range"))
	s.render(w, "layout", pageData{Title: "Reports", Page: "reports", Body: "reports", Range: rangeKey})
}

func (s *Server) handleReportsPartial(w http.ResponseWriter, r *http.Request) {
	rangeKey := usecases.NormalizeRange(r.URL.Query().Get("range"))
	rep, err := s.app.Reports.Report(r.Context(), rangeKey)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/report_table", pageData{Report: rep})
}

func (s *Server) handleRules(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		if err := r.ParseForm(); err != nil {
			http.Error(w, "invalid form", 400)
			return
		}
		in, err := parseRuleInput(r)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if err := s.app.Rules.AddRuleToDraft(r.Context(), in); err != nil {
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
	draft, err := s.app.Rules.DraftPreview(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	date, minDuration := rulesDraftFiltersFromRequest(r)
	if date == "" {
		dates, err := s.app.Rules.ListUnmappedDates(r.Context(), minDuration)
		if err == nil && len(dates) > 0 {
			date = dates[0]
		}
	}
	groups := make([]domain.GroupedEvent, 0)
	if date != "" {
		groups, err = s.app.Rules.ListGroupedUnmappedEvents(r.Context(), date, minDuration)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
	}
	s.render(w, "partials/rules_editor", pageData{
		DraftPreview:     draft,
		DraftDate:        date,
		DraftMinDuration: minDuration,
		DraftGroups:      groups,
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
	in, err := parseRuleInput(r)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	if err := s.app.Rules.AddRuleToDraft(r.Context(), in); err != nil {
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
	if err := s.app.Rules.DeleteRuleFromDraft(r.Context(), id); err != nil {
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
	warnings, err := s.app.Rules.ReAddDefaultRulesToDraft(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
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
	result, err := s.app.Rules.SaveDraft(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
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
	s.app.Rules.DiscardDraft()
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
	in, err := parseRuleInput(r)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	groups := parseSelectedGroups(r)
	if len(groups) == 0 {
		http.Error(w, "select at least one event group", 400)
		return
	}
	if err := s.app.Rules.AddRegexRuleFromGroupsToDraft(r.Context(), groups, in); err != nil {
		http.Error(w, err.Error(), 500)
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
	if err := s.app.Rules.DeleteRule(r.Context(), id); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.renderRulesEditor(w, r, "Rule deleted")
}

func (s *Server) handleSuggestionsPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "layout", pageData{Title: "Suggestions", Page: "suggestions", Body: "suggestions"})
}

func (s *Server) handleSuggestionsPartial(w http.ResponseWriter, r *http.Request) {
	q := suggestionQueryFromRequest(r)
	items, err := s.app.Rules.AnalyzeSuggestions(r.Context(), q)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/suggestions_table", pageData{Suggestions: items})
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
	sug, err := parseSuggestionFromForm(r)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	_, err = s.app.Rules.AcceptSuggestion(r.Context(), domain.ApplySuggestionInput{
		Suggestion: sug,
		ApplyNow:   r.Form.Get("apply_now") != "",
	})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	items, _ := s.app.Rules.AnalyzeSuggestions(r.Context(), domain.SuggestionQuery{MinDurationMS: 2000, Limit: 50})
	s.render(w, "partials/suggestions_table", pageData{Suggestions: items, AutoApplySummary: "Suggestion accepted"})
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
	minConf := int(parseIntDefault(r.Form.Get("min_confidence"), 85))
	res, err := s.app.Rules.AutoApplySuggestions(r.Context(), domain.AutoApplySuggestionsInput{MinConfidence: minConf, ApplyNow: r.Form.Get("apply_now") != "", MinDurationMS: 2000, Limit: 100})
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	items, _ := s.app.Rules.AnalyzeSuggestions(r.Context(), domain.SuggestionQuery{MinDurationMS: 2000, Limit: 50})
	summary := fmt.Sprintf("Analyzed %d suggestions, accepted %d, mapped %d events", res.Analyzed, res.Accepted, res.MappedEvents)
	s.render(w, "partials/suggestions_table", pageData{Suggestions: items, AutoApplySummary: summary})
}

func (s *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	s.render(w, "layout", pageData{Title: "Projects", Page: "projects", Body: "projects", Flash: r.URL.Query().Get("flash")})
}

func (s *Server) handleProjectsPartial(w http.ResponseWriter, r *http.Request) {
	active, err := s.app.Projects.ListActive(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	all, err := s.app.Projects.ListAll(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/projects_panel", pageData{ActiveProjects: active, AllProjects: all})
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
	if err := s.app.Projects.Activate(r.Context(), id); err != nil {
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
	if err := s.app.Projects.EndAll(r.Context()); err != nil {
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
	if err := s.app.Projects.End(r.Context(), id); err != nil {
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
		cfg, _, err := s.app.Settings.Load(r.Context())
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		cfg.Enabled = r.Form.Get("enabled") != ""
		cfg.WeightedBucketMinutes = parseIntDefault(r.Form.Get("weighted_bucket_minutes"), cfg.WeightedBucketMinutes)
		cfg.WeightedSwitchMinutes = parseIntDefault(r.Form.Get("weighted_switch_minutes"), cfg.WeightedSwitchMinutes)
		cfg.NoiseBucketMinutes = parseIntDefault(r.Form.Get("noise_bucket_minutes"), cfg.NoiseBucketMinutes)
		cfg.NoiseSwitchMinutes = parseIntDefault(r.Form.Get("noise_switch_minutes"), cfg.NoiseSwitchMinutes)
		cfg.NoiseAppPatterns = parseLines(r.Form.Get("noise_app_patterns"))
		cfg.WorkWifis = parseLines(r.Form.Get("work_wifis"))
		if _, err := s.app.Settings.Save(r.Context(), cfg); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		http.Redirect(w, r, "/settings?flash=Settings+saved", http.StatusSeeOther)
		return
	}
	cfg, _, err := s.app.Settings.Load(r.Context())
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	pd := pageData{Title: "Settings", Page: "settings", Body: "settings", Flash: r.URL.Query().Get("flash"), Config: cfg, NoisePatternsText: strings.Join(cfg.NoiseAppPatterns, "\n"), WorkWifisText: strings.Join(cfg.WorkWifis, "\n")}
	s.render(w, "layout", pd)
}

func (s *Server) handleCollectorStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if err := s.app.Lifecycle.Start(r.Context()); err != nil {
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
	if err := s.app.Lifecycle.Stop(r.Context()); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.handleCollectorStatus(w, r)
}

func (s *Server) handleCollectorStatus(w http.ResponseWriter, r *http.Request) {
	st := s.app.Lifecycle.Status(r.Context())
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
		var body bytes.Buffer
		if err := s.templates.ExecuteTemplate(&body, pd.Body, pd); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		pd.BodyHTML = template.HTML(body.String())
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
	return domain.RuleInput{
		RuleKey:            strings.TrimSpace(r.Form.Get("rule_key")),
		Source:             domain.RuleSource(strings.TrimSpace(r.Form.Get("source"))),
		Priority:           priority,
		AppPattern:         r.Form.Get("app_pattern"),
		TitlePattern:       r.Form.Get("title_pattern"),
		ProjectID:          projectID,
		ActivityID:         activityID,
		FollowPrevious:     r.Form.Get("follow_previous") != "",
		ActionType:         actionType,
		ActionProjectTitle: strings.TrimSpace(r.Form.Get("action_project_title")),
		ActionActivityName: strings.TrimSpace(r.Form.Get("action_activity_name")),
	}, nil
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

func suggestionQueryFromRequest(r *http.Request) domain.SuggestionQuery {
	q := domain.SuggestionQuery{MinDurationMS: parseIntDefault(r.URL.Query().Get("min_duration_ms"), 2000), Limit: int(parseIntDefault(r.URL.Query().Get("limit"), 50))}
	date := strings.TrimSpace(r.URL.Query().Get("date"))
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
	impactCount := int(parseIntDefault(r.Form.Get("impact_count"), 0))
	impactDur := parseIntDefault(r.Form.Get("impact_duration_ms"), 0)
	evidence := int(parseIntDefault(r.Form.Get("evidence_count"), 0))
	st := domain.SuggestionType(r.Form.Get("suggestion_type"))
	title := strings.TrimSpace(r.Form.Get("title_pattern"))
	var titlePtr *string
	if title != "" {
		titlePtr = &title
	}
	return domain.RuleSuggestion{
		SuggestionType:   st,
		AppPattern:       r.Form.Get("app_pattern"),
		TitlePattern:     titlePtr,
		ProjectID:        projectID,
		ActivityID:       activityID,
		DisplayPath:      r.Form.Get("display_path"),
		Confidence:       conf,
		ImpactCount:      impactCount,
		ImpactDurationMS: impactDur,
		EvidenceCount:    evidence,
	}, nil
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
