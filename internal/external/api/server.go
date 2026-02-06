package api

import (
	"bytes"
	"context"
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
		if _, err := s.app.Rules.AddRule(r.Context(), in); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if isHTMX(r) {
			s.renderRulesTable(w, r.Context())
			return
		}
		http.Redirect(w, r, "/rules?flash=Rule+added", http.StatusSeeOther)
		return
	}
	s.render(w, "layout", pageData{Title: "Rules", Page: "rules", Body: "rules", Flash: r.URL.Query().Get("flash")})
}

func (s *Server) handleRulesPartial(w http.ResponseWriter, r *http.Request) {
	s.renderRulesTable(w, r.Context())
}

func (s *Server) renderRulesTable(w http.ResponseWriter, ctx context.Context) {
	rules, err := s.app.Rules.ListRules(ctx)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.render(w, "partials/rules_table", pageData{Rules: rules})
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
	s.renderRulesTable(w, r.Context())
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
	activityID, err := parseNullableInt64(r.Form.Get("activity_id"))
	if err != nil {
		return domain.RuleInput{}, fmt.Errorf("invalid activity_id")
	}
	kindID, err := parseNullableInt64(r.Form.Get("kind_id"))
	if err != nil {
		return domain.RuleInput{}, fmt.Errorf("invalid kind_id")
	}
	return domain.RuleInput{Priority: priority, AppPattern: r.Form.Get("app_pattern"), TitlePattern: r.Form.Get("title_pattern"), ActivityID: activityID, KindID: kindID, FollowPrevious: r.Form.Get("follow_previous") != "", IsGlobal: r.Form.Get("is_global") != "", KindName: r.Form.Get("kind_name")}, nil
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
	activityID, err := strconv.ParseInt(strings.TrimSpace(r.Form.Get("activity_id")), 10, 64)
	if err != nil {
		return domain.RuleSuggestion{}, fmt.Errorf("invalid activity_id")
	}
	kindID, err := strconv.ParseInt(strings.TrimSpace(r.Form.Get("kind_id")), 10, 64)
	if err != nil {
		return domain.RuleSuggestion{}, fmt.Errorf("invalid kind_id")
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
	return domain.RuleSuggestion{SuggestionType: st, AppPattern: r.Form.Get("app_pattern"), TitlePattern: titlePtr, ActivityID: activityID, KindID: kindID, DisplayPath: r.Form.Get("display_path"), Confidence: conf, ImpactCount: impactCount, ImpactDurationMS: impactDur, EvidenceCount: evidence}, nil
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
