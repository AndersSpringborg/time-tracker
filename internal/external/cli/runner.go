package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

type Runner struct {
	App             *usecases.App
	Serve           func(addr string) error
	DBPath          string
	ConfigPath      string
	WorkerPath      string
	LaunchAgentPath string
}

func (r *Runner) Run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		r.printHelp(stdout)
		return 0
	}

	switch args[0] {
	case "help", "-h", "--help":
		return r.runHelp(args[1:], stdout, stderr)
	case "schema":
		return r.runSchema(args[1:], stdout, stderr)
	case "install":
		if err := r.App.Lifecycle.Install(ctx); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "installed and started launchd worker")
		return 0
	case "uninstall":
		if err := r.App.Lifecycle.Uninstall(ctx); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "uninstalled worker and launch agent")
		return 0
	case "start":
		if err := r.App.Lifecycle.Start(ctx); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "collector started")
		return 0
	case "stop":
		if err := r.App.Lifecycle.Stop(ctx); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "collector stopped")
		return 0
	case "status":
		st := r.App.Lifecycle.Status(ctx)
		fmt.Fprintf(stdout, "loaded=%v state=%s pid=%s\n", st.Loaded, st.State, st.PID)
		if st.Raw != "" {
			fmt.Fprintln(stdout, st.Raw)
		}
		return 0
	case "doctor":
		fmt.Fprintf(stdout, "db: %s\n", r.DBPath)
		fmt.Fprintf(stdout, "config: %s\n", r.ConfigPath)
		fmt.Fprintf(stdout, "worker: %s\n", r.WorkerPath)
		fmt.Fprintf(stdout, "launch-agent: %s\n", r.LaunchAgentPath)
		st := r.App.Lifecycle.Status(ctx)
		fmt.Fprintf(stdout, "collector: loaded=%v state=%s pid=%s\n", st.Loaded, st.State, st.PID)
		return 0
	case "serve":
		fs := flag.NewFlagSet("serve", flag.ContinueOnError)
		fs.SetOutput(stderr)
		addr := fs.String("addr", "127.0.0.1:8080", "listen address")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if r.Serve == nil {
			fmt.Fprintln(stderr, "error: serve adapter not configured")
			return 1
		}
		if err := r.Serve(*addr); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		return 0
	case "rules":
		return r.runRules(ctx, args[1:], stdout, stderr)
	case "projects":
		return r.runProjects(ctx, args[1:], stdout, stderr)
	case "reports", "report", "summary":
		return r.runReports(ctx, args, stdout, stderr)
	case "settings", "config":
		return r.runSettings(ctx, args[1:], stdout, stderr)
	case "review":
		return r.runReview(ctx, args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n\n", args[0])
		r.printHelp(stderr)
		return 2
	}
}

func (r *Runner) runHelp(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("help", flag.ContinueOnError)
	fs.SetOutput(stderr)
	format := fs.String("format", "text", "text|json|yaml")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	remaining := fs.Args()
	if len(remaining) == 0 {
		if *format == "text" {
			r.printHelp(stdout)
			return 0
		}
		schemas := r.App.Help.ListSchemas()
		return emit(stdout, *format, map[string]any{"commands": schemas}, stderr)
	}
	s, err := r.App.Help.Schema(remaining[0])
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 2
	}
	if *format == "text" {
		fmt.Fprintf(stdout, "Command: %s\nDescription: %s\nUsage: %s\n", s.Command, s.Description, s.Usage)
		fmt.Fprintf(stdout, "Flags: %s\n", strings.Join(s.Flags, ", "))
		fmt.Fprintf(stdout, "Side effects: %s\n", strings.Join(s.SideEffects, ", "))
		fmt.Fprintln(stdout, "Examples:")
		for _, e := range s.Examples {
			fmt.Fprintf(stdout, "  %s\n", e)
		}
		return 0
	}
	return emit(stdout, *format, s, stderr)
}

func (r *Runner) runSchema(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 {
		fmt.Fprintln(stderr, "usage: tt schema <command>")
		return 2
	}
	b, err := r.App.Help.SchemaJSON(args[0])
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 2
	}
	_, _ = stdout.Write(b)
	_, _ = stdout.Write([]byte("\n"))
	return 0
}

func (r *Runner) runRules(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt rules <list|add|delete|suggest|accept|auto-apply|apply-rules>")
		return 2
	}
	sub := args[0]
	switch sub {
	case "list":
		format, rest := extractFormat(args[1:])
		rules, err := r.App.Rules.ListRules(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if format == "text" {
			if len(rules) == 0 {
				fmt.Fprintln(stdout, "No mapping rules defined.")
				return 0
			}
			for _, rule := range rules {
				fmt.Fprintf(stdout, "[%d] p=%d app=%q title=%q target=%s\n", rule.ID, rule.Priority, rule.AppPattern, rule.TitlePattern, rule.DisplayTarget)
			}
			_ = rest
			return 0
		}
		return emit(stdout, format, map[string]any{"rules": rules}, stderr)
	case "add":
		fs := flag.NewFlagSet("rules add", flag.ContinueOnError)
		fs.SetOutput(stderr)
		priority := fs.Int("priority", 100, "priority")
		appPattern := fs.String("app-pattern", "*", "app glob pattern")
		titlePattern := fs.String("title-pattern", "*", "title glob pattern")
		activityID := fs.Int64("activity-id", 0, "activity id")
		kindID := fs.Int64("kind-id", 0, "kind id")
		followPrevious := fs.Bool("follow-previous", false, "follow current project mapping")
		isGlobal := fs.Bool("global", false, "global kind-name rule")
		kindName := fs.String("kind-name", "", "kind name for global rules")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var aid, kid *int64
		if *activityID > 0 {
			aid = activityID
		}
		if *kindID > 0 {
			kid = kindID
		}
		id, err := r.App.Rules.AddRule(ctx, domain.RuleInput{Priority: *priority, AppPattern: *appPattern, TitlePattern: *titlePattern, ActivityID: aid, KindID: kid, FollowPrevious: *followPrevious, IsGlobal: *isGlobal, KindName: *kindName})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "rule added: %d\n", id)
		return 0
	case "delete":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: tt rules delete <id>")
			return 2
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintln(stderr, "invalid id")
			return 2
		}
		if err := r.App.Rules.DeleteRule(ctx, id); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "rule deleted: %d\n", id)
		return 0
	case "suggest":
		fs := flag.NewFlagSet("rules suggest", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		date := fs.String("date", "", "date filter YYYY-MM-DD")
		minDur := fs.Int64("min-duration-ms", 2000, "minimum event duration")
		limit := fs.Int("limit", 50, "max suggestions")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var datePtr *string
		if strings.TrimSpace(*date) != "" {
			datePtr = date
		}
		items, err := r.App.Rules.AnalyzeSuggestions(ctx, domain.SuggestionQuery{Date: datePtr, MinDurationMS: *minDur, Limit: *limit})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			for _, s := range items {
				title := "*"
				if s.TitlePattern != nil {
					title = *s.TitlePattern
				}
				fmt.Fprintf(stdout, "%s app=%q title=%q conf=%d%% impact=%d/%s target=%s\n", s.SuggestionType, s.AppPattern, title, s.Confidence, s.ImpactCount, domain.FormatDuration(s.ImpactDurationMS), s.DisplayPath)
			}
			if len(items) == 0 {
				fmt.Fprintln(stdout, "No suggestions")
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"suggestions": items}, stderr)
	case "accept":
		fs := flag.NewFlagSet("rules accept", flag.ContinueOnError)
		fs.SetOutput(stderr)
		appPattern := fs.String("app-pattern", "", "app pattern")
		titlePattern := fs.String("title-pattern", "", "title pattern")
		activityID := fs.Int64("activity-id", 0, "activity id")
		kindID := fs.Int64("kind-id", 0, "kind id")
		applyNow := fs.Bool("apply-now", true, "apply immediately")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *appPattern == "" || *activityID == 0 || *kindID == 0 {
			fmt.Fprintln(stderr, "app-pattern, activity-id and kind-id are required")
			return 2
		}
		var tp *string
		if strings.TrimSpace(*titlePattern) != "" {
			tp = titlePattern
		}
		res, err := r.App.Rules.AcceptSuggestion(ctx, domain.ApplySuggestionInput{Suggestion: domain.RuleSuggestion{SuggestionType: domain.SuggestionTypeAppOnly, AppPattern: *appPattern, TitlePattern: tp, ActivityID: *activityID, KindID: *kindID}, ApplyNow: *applyNow})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "accepted: rule_created=%v mapped_events=%d\n", res.RuleCreated, res.MappedEvents)
		return 0
	case "auto-apply":
		fs := flag.NewFlagSet("rules auto-apply", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		minConf := fs.Int("min-confidence", 85, "minimum confidence")
		applyNow := fs.Bool("apply-now", true, "apply after creating rules")
		minDur := fs.Int64("min-duration-ms", 2000, "minimum duration")
		limit := fs.Int("limit", 100, "max suggestions")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		res, err := r.App.Rules.AutoApplySuggestions(ctx, domain.AutoApplySuggestionsInput{MinConfidence: *minConf, ApplyNow: *applyNow, MinDurationMS: *minDur, Limit: *limit})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			fmt.Fprintf(stdout, "analyzed=%d accepted=%d mapped=%d\n", res.Analyzed, res.Accepted, res.MappedEvents)
			return 0
		}
		return emit(stdout, *format, res, stderr)
	case "apply-rules":
		fs := flag.NewFlagSet("rules apply-rules", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		dryRun := fs.Bool("dry-run", false, "do not write")
		date := fs.String("date", "", "optional date")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var datePtr *string
		if strings.TrimSpace(*date) != "" {
			datePtr = date
		}
		res, err := r.App.Rules.ApplyRules(ctx, domain.ApplyRulesInput{Date: datePtr, DryRun: *dryRun})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			fmt.Fprintf(stdout, "unmapped=%d matched=%d dry_run=%v\n", res.UnmappedEvents, res.MatchedEvents, *dryRun)
			return 0
		}
		return emit(stdout, *format, res, stderr)
	default:
		fmt.Fprintf(stderr, "unknown rules subcommand: %s\n", sub)
		return 2
	}
}

func (r *Runner) runProjects(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt projects <list|add|end|clear|current>")
		return 2
	}
	sub := args[0]
	format, _ := extractFormat(args[1:])
	switch sub {
	case "list":
		items, err := r.App.Projects.ListActive(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if format == "text" {
			if len(items) == 0 {
				fmt.Fprintln(stdout, "No active projects")
				return 0
			}
			for _, p := range items {
				fmt.Fprintf(stdout, "%d %s > %s (started %s)\n", p.ProjectID, p.Customer, p.Name, p.StartedAt)
			}
			return 0
		}
		return emit(stdout, format, map[string]any{"projects": items}, stderr)
	case "add":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: tt projects add <project_id>")
			return 2
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintln(stderr, "invalid project id")
			return 2
		}
		if err := r.App.Projects.Activate(ctx, id); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "project activated: %d\n", id)
		return 0
	case "end":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: tt projects end <project_id>")
			return 2
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil {
			fmt.Fprintln(stderr, "invalid project id")
			return 2
		}
		if err := r.App.Projects.End(ctx, id); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "project ended: %d\n", id)
		return 0
	case "clear":
		if err := r.App.Projects.EndAll(ctx); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "all projects ended")
		return 0
	case "current":
		name, id, err := r.App.Projects.Current(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if format == "text" {
			if id == nil {
				fmt.Fprintln(stdout, "No current project")
			} else {
				fmt.Fprintf(stdout, "Current project: %d %s\n", *id, name)
			}
			return 0
		}
		return emit(stdout, format, map[string]any{"project_id": id, "name": name}, stderr)
	default:
		fmt.Fprintf(stderr, "unknown projects subcommand: %s\n", sub)
		return 2
	}
}

func (r *Runner) runReports(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("reports", flag.ContinueOnError)
	fs.SetOutput(stderr)
	format := fs.String("format", "text", "text|json|yaml")
	rangeKey := fs.String("range", "today", "today|week|all")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	rep, err := r.App.Reports.Report(ctx, usecases.NormalizeRange(*rangeKey))
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	if *format == "text" {
		fmt.Fprintf(stdout, "range=%s total=%s excluded=%d\n", rep.Range, domain.FormatDuration(rep.TotalMS), rep.ExcludedEvents)
		fmt.Fprintln(stdout, "By project:")
		for _, p := range rep.ByProject {
			fmt.Fprintf(stdout, "  %s: %s\n", p.Name, domain.FormatDuration(p.TotalMS))
		}
		fmt.Fprintln(stdout, "By app:")
		for _, p := range rep.ByApp {
			fmt.Fprintf(stdout, "  %s: %s\n", p.Name, domain.FormatDuration(p.TotalMS))
		}
		return 0
	}
	return emit(stdout, *format, rep, stderr)
}

func (r *Runner) runSettings(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt settings <list|get|set|unset>")
		return 2
	}
	sub := args[0]
	cfg, _, err := r.App.Settings.Load(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	switch sub {
	case "list":
		b, _ := json.MarshalIndent(cfg, "", "  ")
		fmt.Fprintln(stdout, string(b))
		return 0
	case "get":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: tt settings get <key>")
			return 2
		}
		key := args[1]
		return printSettingValue(stdout, stderr, cfg, key)
	case "set":
		if len(args) < 3 {
			fmt.Fprintln(stderr, "usage: tt settings set <key> <value>")
			return 2
		}
		if err := setSetting(&cfg, args[1], args[2]); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 2
		}
		if _, err := r.App.Settings.Save(ctx, cfg); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "setting updated")
		return 0
	case "unset":
		if len(args) < 2 {
			fmt.Fprintln(stderr, "usage: tt settings unset <key>")
			return 2
		}
		defaults, _, _ := r.App.Settings.Load(context.Background())
		if err := unsetSetting(&cfg, defaults, args[1]); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 2
		}
		if _, err := r.App.Settings.Save(ctx, cfg); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "setting reset")
		return 0
	default:
		fmt.Fprintf(stderr, "unknown settings subcommand: %s\n", sub)
		return 2
	}
}

func printSettingValue(stdout, stderr io.Writer, cfg domain.Settings, key string) int {
	switch key {
	case "enabled":
		fmt.Fprintln(stdout, cfg.Enabled)
	case "weighted_bucket_minutes":
		fmt.Fprintln(stdout, cfg.WeightedBucketMinutes)
	case "weighted_switch_minutes":
		fmt.Fprintln(stdout, cfg.WeightedSwitchMinutes)
	case "noise_bucket_minutes":
		fmt.Fprintln(stdout, cfg.NoiseBucketMinutes)
	case "noise_switch_minutes":
		fmt.Fprintln(stdout, cfg.NoiseSwitchMinutes)
	case "noise_app_patterns":
		fmt.Fprintln(stdout, strings.Join(cfg.NoiseAppPatterns, ","))
	case "work_wifis":
		fmt.Fprintln(stdout, strings.Join(cfg.WorkWifis, ","))
	default:
		fmt.Fprintf(stderr, "unknown key: %s\n", key)
		return 2
	}
	return 0
}

func setSetting(cfg *domain.Settings, key, value string) error {
	switch key {
	case "enabled":
		cfg.Enabled = value == "true" || value == "1"
	case "weighted_bucket_minutes":
		v, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return err
		}
		cfg.WeightedBucketMinutes = v
	case "weighted_switch_minutes":
		v, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return err
		}
		cfg.WeightedSwitchMinutes = v
	case "noise_bucket_minutes":
		v, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return err
		}
		cfg.NoiseBucketMinutes = v
	case "noise_switch_minutes":
		v, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return err
		}
		cfg.NoiseSwitchMinutes = v
	case "noise_app_patterns":
		cfg.NoiseAppPatterns = splitList(value)
	case "work_wifis":
		cfg.WorkWifis = splitList(value)
	default:
		return fmt.Errorf("unknown key: %s", key)
	}
	return nil
}

func unsetSetting(cfg *domain.Settings, def domain.Settings, key string) error {
	switch key {
	case "enabled":
		cfg.Enabled = def.Enabled
	case "weighted_bucket_minutes":
		cfg.WeightedBucketMinutes = def.WeightedBucketMinutes
	case "weighted_switch_minutes":
		cfg.WeightedSwitchMinutes = def.WeightedSwitchMinutes
	case "noise_bucket_minutes":
		cfg.NoiseBucketMinutes = def.NoiseBucketMinutes
	case "noise_switch_minutes":
		cfg.NoiseSwitchMinutes = def.NoiseSwitchMinutes
	case "noise_app_patterns":
		cfg.NoiseAppPatterns = def.NoiseAppPatterns
	case "work_wifis":
		cfg.WorkWifis = def.WorkWifis
	default:
		return fmt.Errorf("unknown key: %s", key)
	}
	return nil
}

func splitList(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

func (r *Runner) runReview(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt review <dates|groups|map-group|discard-group>")
		return 2
	}
	sub := args[0]
	switch sub {
	case "dates":
		minDur := int64(2000)
		if len(args) > 1 {
			if v, err := strconv.ParseInt(args[1], 10, 64); err == nil {
				minDur = v
			}
		}
		dates, err := r.App.Review.Dates(ctx, minDur)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		for _, d := range dates {
			fmt.Fprintln(stdout, d)
		}
		return 0
	case "groups":
		fs := flag.NewFlagSet("review groups", flag.ContinueOnError)
		fs.SetOutput(stderr)
		date := fs.String("date", "", "YYYY-MM-DD")
		minDur := fs.Int64("min-duration-ms", 2000, "minimum duration")
		format := fs.String("format", "text", "text|json|yaml")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *date == "" {
			fmt.Fprintln(stderr, "--date is required")
			return 2
		}
		groups, err := r.App.Review.Groups(ctx, *date, *minDur)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			for _, g := range groups {
				fmt.Fprintf(stdout, "%s | %s | %d events | %s\n", g.AppName, g.WindowTitle, g.EventCount, domain.FormatDuration(g.TotalDurationMS))
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"groups": groups}, stderr)
	case "map-group":
		fs := flag.NewFlagSet("review map-group", flag.ContinueOnError)
		fs.SetOutput(stderr)
		date := fs.String("date", "", "date")
		app := fs.String("app", "", "app")
		title := fs.String("title", "", "title")
		activity := fs.Int64("activity-id", 0, "activity")
		kind := fs.Int64("kind-id", 0, "kind")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *date == "" || *app == "" || *title == "" || *activity == 0 || *kind == 0 {
			fmt.Fprintln(stderr, "--date --app --title --activity-id --kind-id are required")
			return 2
		}
		n, err := r.App.Review.MapGroup(ctx, *date, *app, *title, *activity, *kind)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "mapped events: %d\n", n)
		return 0
	case "discard-group":
		fs := flag.NewFlagSet("review discard-group", flag.ContinueOnError)
		fs.SetOutput(stderr)
		date := fs.String("date", "", "date")
		app := fs.String("app", "", "app")
		title := fs.String("title", "", "title")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *date == "" || *app == "" || *title == "" {
			fmt.Fprintln(stderr, "--date --app --title are required")
			return 2
		}
		n, err := r.App.Review.DiscardGroup(ctx, *date, *app, *title)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "discarded events: %d\n", n)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown review subcommand: %s\n", sub)
		return 2
	}
}

func extractFormat(args []string) (string, []string) {
	format := "text"
	rest := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == "--format" && i+1 < len(args) {
			format = args[i+1]
			i++
			continue
		}
		rest = append(rest, args[i])
	}
	return format, rest
}

func emit(out io.Writer, format string, v any, stderr io.Writer) int {
	switch format {
	case "json":
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		_, _ = out.Write(b)
		_, _ = out.Write([]byte("\n"))
		return 0
	case "yaml":
		b, err := yaml.Marshal(v)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		_, _ = out.Write(b)
		return 0
	case "text":
		fmt.Fprintf(stderr, "error: text output is command-specific\n")
		return 2
	default:
		fmt.Fprintf(stderr, "error: unsupported format %q\n", format)
		return 2
	}
}

func (r *Runner) printHelp(out io.Writer) {
	fmt.Fprint(out, `Usage: tt <command> [options]

Commands:
  install        Install worker and launchd agent
  uninstall      Remove worker and launchd agent
  start          Start collector via launchd
  stop           Stop collector via launchd
  status         Show launchd collector status
  serve          Start web UI (HTMX)
  doctor         Print local paths and collector status
  rules          Manage rules and auto-categorization suggestions
  projects       Manage current project context
  reports        Show report summaries (noise-filtered)
  settings       Manage configuration key-values
  review         Review/match/discard unmapped events
  help           Show help (supports --format json|yaml)
  schema         Print JSON command schema for LLM/tools

Global conventions for LLM/tooling:
  - Use --format json for machine parsing
  - Use --dry-run for non-mutating preview when available
  - Use help --format json and schema <command> for deterministic command docs

Examples:
  tt help rules --format json
  tt schema rules
  tt rules suggest --format json --limit 20
  tt rules auto-apply --min-confidence 90 --apply-now
  tt review groups --date 2026-02-06 --format json
  tt reports --range week --format json
`)
}

var _ = os.Args
