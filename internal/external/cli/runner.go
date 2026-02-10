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

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
	clidto "time-tracker/internal/external/cli/dto"
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
		if _, err := r.App.Lifecycle.Install(ctx, contracts.LifecycleInstallRequest{}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "installed and started launchd worker")
		r.printAccessibilityHint(stdout)
		return 0
	case "uninstall":
		if _, err := r.App.Lifecycle.Uninstall(ctx, contracts.LifecycleUninstallRequest{}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "uninstalled worker and launch agent")
		return 0
	case "start":
		if _, err := r.App.Lifecycle.Start(ctx, contracts.LifecycleStartRequest{}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "collector started")
		return 0
	case "stop":
		if _, err := r.App.Lifecycle.Stop(ctx, contracts.LifecycleStopRequest{}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "collector stopped")
		return 0
	case "status":
		statusRes, err := r.App.Lifecycle.Status(ctx, contracts.LifecycleStatusRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		st := statusRes.Status
		fmt.Fprintf(stdout, "loaded=%v state=%s pid=%s\n", st.Loaded, st.State, st.PID)
		if st.Loaded && st.PID == "" {
			r.printAccessibilityHint(stdout)
		}
		if workerLogHasAccessibilityError() {
			fmt.Fprintln(stdout, "warning: recent worker logs indicate Accessibility permission is still denied")
			fmt.Fprintln(stdout, "recovery: remove and re-add the worker entry in Accessibility after your latest install, then run `./tracker start`")
		}
		if st.Raw != "" {
			fmt.Fprintln(stdout, st.Raw)
		}
		return 0
	case "doctor":
		fmt.Fprintf(stdout, "db: %s\n", r.DBPath)
		fmt.Fprintf(stdout, "config: %s\n", r.ConfigPath)
		fmt.Fprintf(stdout, "worker: %s\n", r.WorkerPath)
		fmt.Fprintf(stdout, "launch-agent: %s\n", r.LaunchAgentPath)
		statusRes, err := r.App.Lifecycle.Status(ctx, contracts.LifecycleStatusRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		st := statusRes.Status
		fmt.Fprintf(stdout, "collector: loaded=%v state=%s pid=%s\n", st.Loaded, st.State, st.PID)
		r.printAccessibilityHint(stdout)
		if workerLogHasAccessibilityError() {
			fmt.Fprintln(stdout, "collector stderr: /tmp/time-tracker-worker.err.log (Accessibility permission still denied)")
			fmt.Fprintln(stdout, "collector quick-fix: remove and re-add the worker binary in Accessibility, then run `./tracker start`")
			r.printAccessibilityTroubleshootingGuide(stdout)
		}
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
		listRes, err := r.App.Help.ListSchemas(context.Background(), contracts.HelpListSchemasRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 2
		}
		return emit(stdout, *format, map[string]any{"commands": clidto.SchemasFromContracts(listRes.Schemas)}, stderr)
	}
	schemaRes, err := r.App.Help.GetSchema(context.Background(), contracts.HelpGetSchemaRequest{Command: remaining[0]})
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 2
	}
	s := schemaRes.Schema
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
	return emit(stdout, *format, clidto.SchemaFromContract(s), stderr)
}

func (r *Runner) runSchema(args []string, stdout, stderr io.Writer) int {
	if len(args) < 1 {
		fmt.Fprintln(stderr, "usage: tt schema <command>")
		return 2
	}
	schemaRes, err := r.App.Help.GetSchema(context.Background(), contracts.HelpGetSchemaRequest{Command: args[0]})
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 2
	}
	b, err := json.MarshalIndent(clidto.SchemaFromContract(schemaRes.Schema), "", "  ")
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	_, _ = stdout.Write(b)
	_, _ = stdout.Write([]byte("\n"))
	return 0
}

func (r *Runner) runRules(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt rules <list|targets|time-tracker|add|delete|suggest|accept|reject|auto-apply|bootstrap|label-group|apply-rules>")
		return 2
	}
	sub := args[0]
	switch sub {
	case "list":
		format, rest := extractFormat(args[1:])
		rulesRes, err := r.App.Rules.ListRules(ctx, contracts.RulesListRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		rules := rulesRes.Rules
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
		return emit(stdout, format, map[string]any{"rules": clidto.RulesFromDomain(rules)}, stderr)
	case "targets":
		fs := flag.NewFlagSet("rules targets", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		targetsRes, err := r.App.Rules.ListAssignmentTargets(ctx, contracts.RulesAssignmentTargetsRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		targets := targetsRes.Targets
		if *format == "text" {
			if len(targets) == 0 {
				fmt.Fprintln(stdout, "No assignment targets available")
				return 0
			}
			for _, target := range targets {
				fmt.Fprintln(stdout, target.DisplayPath())
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"targets": targets}, stderr)
	case "time-tracker":
		fs := flag.NewFlagSet("rules time-tracker", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		devActivity := fs.String("dev-activity", "development", "activity name for coding/dev work")
		meetingActivity := fs.String("meeting-activity", "meeting", "activity name for meetings")
		includeMeeting := fs.Bool("include-meeting", true, "include a communication app meeting rule")
		dryRun := fs.Bool("dry-run", false, "preview without writing rules")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}

		rules := buildTimeTrackerRulesPreset(*devActivity, *meetingActivity, *includeMeeting)
		existingRes, err := r.App.Rules.ListRules(ctx, contracts.RulesListRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		existingKeys := make(map[string]struct{}, len(existingRes.Rules))
		for _, existing := range existingRes.Rules {
			key := strings.TrimSpace(existing.RuleKey)
			if key == "" {
				continue
			}
			existingKeys[key] = struct{}{}
		}

		type presetResult struct {
			RuleKey string `json:"rule_key" yaml:"rule_key"`
			Status  string `json:"status" yaml:"status"`
			RuleID  int64  `json:"rule_id,omitempty" yaml:"rule_id,omitempty"`
			Target  string `json:"target" yaml:"target"`
		}
		results := make([]presetResult, 0, len(rules))
		created := 0
		skipped := 0

		for _, rule := range rules {
			if _, ok := existingKeys[rule.RuleKey]; ok {
				results = append(results, presetResult{
					RuleKey: rule.RuleKey,
					Status:  "skipped_existing",
					Target:  fmt.Sprintf("Current project > %s", rule.ActionActivityName),
				})
				skipped++
				continue
			}
			if *dryRun {
				results = append(results, presetResult{
					RuleKey: rule.RuleKey,
					Status:  "would_create",
					Target:  fmt.Sprintf("Current project > %s", rule.ActionActivityName),
				})
				created++
				continue
			}

			addRes, err := r.App.Rules.AddRule(ctx, contracts.RulesAddRequest{Rule: rule})
			if err != nil {
				fmt.Fprintf(stderr, "error creating %s: %v\n", rule.RuleKey, err)
				return 1
			}
			results = append(results, presetResult{
				RuleKey: rule.RuleKey,
				Status:  "created",
				RuleID:  addRes.RuleID,
				Target:  fmt.Sprintf("Current project > %s", rule.ActionActivityName),
			})
			created++
		}

		if *format == "text" {
			for _, item := range results {
				if item.RuleID > 0 {
					fmt.Fprintf(stdout, "%s rule_key=%s rule_id=%d target=%s\n", item.Status, item.RuleKey, item.RuleID, item.Target)
					continue
				}
				fmt.Fprintf(stdout, "%s rule_key=%s target=%s\n", item.Status, item.RuleKey, item.Target)
			}
			fmt.Fprintf(stdout, "time-tracker preset: %s=%d skipped=%d\n", map[bool]string{true: "would_create", false: "created"}[*dryRun], created, skipped)
			return 0
		}
		return emit(stdout, *format, map[string]any{
			"dry_run":      *dryRun,
			"created":      created,
			"skipped":      skipped,
			"preset_rules": results,
		}, stderr)
	case "add":
		fs := flag.NewFlagSet("rules add", flag.ContinueOnError)
		fs.SetOutput(stderr)
		priority := fs.Int("priority", 100, "priority")
		appPattern := fs.String("app-pattern", "*", "app glob pattern")
		titlePattern := fs.String("title-pattern", "*", "title glob pattern")
		projectID := fs.Int64("project-id", 0, "project id")
		activityID := fs.Int64("activity-id", 0, "activity id")
		followPrevious := fs.Bool("follow-previous", false, "follow current project mapping")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var pid, aid *int64
		if *projectID > 0 {
			pid = projectID
		}
		if *activityID > 0 {
			aid = activityID
		}
		if !*followPrevious && (pid == nil || aid == nil) {
			fmt.Fprintln(stderr, "project-id and activity-id are required unless --follow-previous is set")
			return 2
		}
		addRes, err := r.App.Rules.AddRule(ctx, contracts.RulesAddRequest{Rule: domain.RuleInput{
			Priority:       *priority,
			AppPattern:     *appPattern,
			TitlePattern:   *titlePattern,
			ProjectID:      pid,
			ActivityID:     aid,
			FollowPrevious: *followPrevious,
		}})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "rule added: %d\n", addRes.RuleID)
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
		if _, err := r.App.Rules.DeleteRule(ctx, contracts.RulesDeleteRequest{RuleID: id}); err != nil {
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
		minEvidence := fs.Int("min-evidence", 2, "minimum mapped evidence")
		includeContext := fs.Bool("include-context", true, "include context hints")
		excludeApps := fs.String("exclude-apps", "", "comma-separated app names to exclude")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var datePtr *string
		if strings.TrimSpace(*date) != "" {
			datePtr = date
		}
		suggestionsRes, err := r.App.Rules.AnalyzeSuggestions(ctx, contracts.RulesAnalyzeSuggestionsRequest{
			Query: domain.SuggestionQuery{
				Date:           datePtr,
				MinDurationMS:  *minDur,
				Limit:          *limit,
				MinEvidence:    *minEvidence,
				IncludeContext: *includeContext,
				ExcludeApps:    splitCSVNormalized(*excludeApps),
			},
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if suggestionsRes.Stats.IsColdStart {
			fmt.Fprintf(stdout, "cold_start: %s\n", suggestionsRes.Stats.Message)
		}
		items := suggestionsRes.Suggestions
		if *format == "text" {
			for _, s := range items {
				title := "*"
				if s.TitlePattern != nil {
					title = *s.TitlePattern
				}
				contextSummary := ""
				if len(s.ContextHints) > 0 {
					contextSummary = " context=" + strings.Join(s.ContextHints, ",")
				}
				fmt.Fprintf(
					stdout,
					"%s app=%q title=%q conf=%d%% score=%.1f ambiguity=%.2f impact=%d/%s evidence=%d target=%s reason=%q%s\n",
					s.SuggestionType,
					s.AppPattern,
					title,
					s.Confidence,
					s.Score,
					s.Ambiguity,
					s.ImpactCount,
					domain.FormatDuration(s.ImpactDurationMS),
					s.EvidenceCount,
					s.DisplayPath,
					s.ConfidenceReason,
					contextSummary,
				)
			}
			if len(items) == 0 {
				fmt.Fprintln(stdout, "No suggestions")
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{
			"suggestions": clidto.SuggestionsFromDomain(items),
			"stats":       suggestionsRes.Stats,
		}, stderr)
	case "accept":
		fs := flag.NewFlagSet("rules accept", flag.ContinueOnError)
		fs.SetOutput(stderr)
		appPattern := fs.String("app-pattern", "", "app pattern")
		titlePattern := fs.String("title-pattern", "", "title pattern")
		projectID := fs.Int64("project-id", 0, "project id")
		activityID := fs.Int64("activity-id", 0, "activity id")
		applyNow := fs.Bool("apply-now", true, "apply immediately")
		date := fs.String("date", "", "optional date scope")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *appPattern == "" || *projectID == 0 || *activityID == 0 {
			fmt.Fprintln(stderr, "app-pattern, project-id and activity-id are required")
			return 2
		}
		var tp *string
		if strings.TrimSpace(*titlePattern) != "" {
			tp = titlePattern
		}
		var datePtr *string
		if strings.TrimSpace(*date) != "" {
			datePtr = date
		}
		res, err := r.App.Rules.AcceptSuggestion(ctx, contracts.RulesAcceptSuggestionRequest{Input: domain.ApplySuggestionInput{
			Suggestion: domain.RuleSuggestion{
				SuggestionType: domain.SuggestionTypeAppOnly,
				AppPattern:     *appPattern,
				TitlePattern:   tp,
				ProjectID:      *projectID,
				ActivityID:     *activityID,
			},
			ApplyNow: *applyNow,
			Date:     datePtr,
		}})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if strings.TrimSpace(res.Result.Warning) != "" {
			fmt.Fprintf(stdout, "accepted: rule_created=%v mapped_events=%d warning=%q\n", res.Result.RuleCreated, res.Result.MappedEvents, res.Result.Warning)
			return 0
		}
		fmt.Fprintf(stdout, "accepted: rule_created=%v mapped_events=%d\n", res.Result.RuleCreated, res.Result.MappedEvents)
		return 0
	case "reject":
		fs := flag.NewFlagSet("rules reject", flag.ContinueOnError)
		fs.SetOutput(stderr)
		appPattern := fs.String("app-pattern", "", "app pattern")
		titlePattern := fs.String("title-pattern", "", "title pattern")
		suggestionType := fs.String("suggestion-type", string(domain.SuggestionTypeAppOnly), "app_only|app_and_title")
		projectID := fs.Int64("project-id", 0, "project id")
		activityID := fs.Int64("activity-id", 0, "activity id")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if strings.TrimSpace(*appPattern) == "" {
			fmt.Fprintln(stderr, "--app-pattern is required")
			return 2
		}
		var tp *string
		if strings.TrimSpace(*titlePattern) != "" {
			tp = titlePattern
		}
		if _, err := r.App.Rules.RejectSuggestion(ctx, contracts.RulesRejectSuggestionRequest{
			Input: domain.RuleSuggestion{
				SuggestionType: domain.SuggestionType(*suggestionType),
				AppPattern:     *appPattern,
				TitlePattern:   tp,
				ProjectID:      *projectID,
				ActivityID:     *activityID,
			},
		}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "suggestion rejected")
		return 0
	case "auto-apply":
		fs := flag.NewFlagSet("rules auto-apply", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		minConf := fs.Int("min-confidence", 85, "minimum confidence")
		applyNow := fs.Bool("apply-now", true, "apply after creating rules")
		date := fs.String("date", "", "optional date scope YYYY-MM-DD")
		minDur := fs.Int64("min-duration-ms", 2000, "minimum duration")
		limit := fs.Int("limit", 100, "max suggestions")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var datePtr *string
		if strings.TrimSpace(*date) != "" {
			datePtr = date
		}
		res, err := r.App.Rules.AutoApplySuggestions(ctx, contracts.RulesAutoApplySuggestionsRequest{
			Input: domain.AutoApplySuggestionsInput{
				Date:          datePtr,
				MinConfidence: *minConf,
				ApplyNow:      *applyNow,
				MinDurationMS: *minDur,
				Limit:         *limit,
			},
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			fmt.Fprintf(stdout, "analyzed=%d accepted=%d mapped=%d\n", res.Result.Analyzed, res.Result.Accepted, res.Result.MappedEvents)
			return 0
		}
		return emit(stdout, *format, clidto.AutoApplyResultFromDomain(res.Result), stderr)
	case "bootstrap":
		fs := flag.NewFlagSet("rules bootstrap", flag.ContinueOnError)
		fs.SetOutput(stderr)
		date := fs.String("date", "", "optional date scope YYYY-MM-DD")
		minDur := fs.Int64("min-duration-ms", 2000, "minimum duration")
		limit := fs.Int("limit", 20, "max groups")
		format := fs.String("format", "text", "text|json|yaml")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		var datePtr *string
		if strings.TrimSpace(*date) != "" {
			datePtr = date
		}
		res, err := r.App.Rules.BootstrapGroups(ctx, contracts.RulesBootstrapGroupsRequest{
			Query: domain.SuggestionQuery{
				Date:          datePtr,
				MinDurationMS: *minDur,
				Limit:         *limit,
			},
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			if res.Stats.IsColdStart {
				fmt.Fprintf(stdout, "cold_start: %s\n", res.Stats.Message)
			}
			for _, g := range res.Groups {
				fmt.Fprintf(stdout, "%s | %s | %d events | %s\n", g.AppName, g.WindowTitle, g.EventCount, domain.FormatDuration(g.TotalDurationMS))
			}
			if len(res.Groups) == 0 {
				fmt.Fprintln(stdout, "No bootstrap groups")
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"groups": clidto.GroupedEventsFromDomain(res.Groups), "stats": res.Stats}, stderr)
	case "label-group":
		fs := flag.NewFlagSet("rules label-group", flag.ContinueOnError)
		fs.SetOutput(stderr)
		date := fs.String("date", "", "date YYYY-MM-DD")
		appName := fs.String("app", "", "app name")
		windowTitle := fs.String("title", "", "window title")
		activityName := fs.String("activity", "", "activity name in current project")
		projectID := fs.Int64("project-id", 0, "project id (legacy explicit mapping)")
		activityID := fs.Int64("activity-id", 0, "activity id (legacy explicit mapping)")
		createRule := fs.Bool("create-rule", true, "create a reusable rule")
		applyNow := fs.Bool("apply-now", true, "map events now")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *date == "" || *appName == "" {
			fmt.Fprintln(stderr, "--date and --app are required")
			return 2
		}
		activityNameValue := strings.TrimSpace(*activityName)
		if activityNameValue == "" && (*projectID <= 0 || *activityID <= 0) {
			fmt.Fprintln(stderr, "either --activity or --project-id/--activity-id is required")
			return 2
		}
		input := domain.BootstrapLabelInput{
			Date:        *date,
			AppName:     *appName,
			WindowTitle: *windowTitle,
			CreateRule:  *createRule,
			ApplyNow:    *applyNow,
		}
		if activityNameValue != "" {
			input.ActivityName = activityNameValue
		} else {
			input.ProjectID = *projectID
			input.ActivityID = *activityID
		}
		res, err := r.App.Rules.LabelBootstrapGroup(ctx, contracts.RulesBootstrapLabelRequest{
			Input: input,
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if strings.TrimSpace(res.Result.Warning) != "" {
			fmt.Fprintf(stdout, "label-group: rule_created=%v mapped_events=%d warning=%q\n", res.Result.RuleCreated, res.Result.MappedEvents, res.Result.Warning)
			return 0
		}
		fmt.Fprintf(stdout, "label-group: rule_created=%v mapped_events=%d\n", res.Result.RuleCreated, res.Result.MappedEvents)
		return 0
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
		res, err := r.App.Rules.ApplyRules(ctx, contracts.RulesApplyRequest{
			Input: domain.ApplyRulesInput{Date: datePtr, DryRun: *dryRun},
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			fmt.Fprintf(stdout, "unmapped=%d matched=%d dry_run=%v\n", res.Result.UnmappedEvents, res.Result.MatchedEvents, *dryRun)
			return 0
		}
		return emit(stdout, *format, clidto.ApplyRulesResultFromDomain(res.Result), stderr)
	default:
		fmt.Fprintf(stderr, "unknown rules subcommand: %s\n", sub)
		return 2
	}
}

func buildTimeTrackerRulesPreset(devActivity, meetingActivity string, includeMeeting bool) []domain.RuleInput {
	devActivity = strings.TrimSpace(devActivity)
	if devActivity == "" {
		devActivity = "development"
	}
	meetingActivity = strings.TrimSpace(meetingActivity)
	if meetingActivity == "" {
		meetingActivity = "meeting"
	}

	titlePattern := "(?i)^.*time[- ]tracker.*$"
	rules := []domain.RuleInput{
		{
			RuleKey:            "preset.time_tracker.editor_development",
			Source:             domain.RuleSourceUser,
			Priority:           330,
			AppPattern:         "(?i)^(Code|Cursor|VSCodium|Codium|Zed|IntelliJ IDEA|GoLand)$",
			TitlePattern:       titlePattern,
			ActionType:         domain.RuleActionAssignActivityCurrent,
			ActionActivityName: devActivity,
		},
		{
			RuleKey:            "preset.time_tracker.terminal_development",
			Source:             domain.RuleSourceUser,
			Priority:           320,
			AppPattern:         "(?i)^(Terminal|iTerm2|Warp|Ghostty|Alacritty|kitty|WezTerm)$",
			TitlePattern:       titlePattern,
			ActionType:         domain.RuleActionAssignActivityCurrent,
			ActionActivityName: devActivity,
		},
		{
			RuleKey:            "preset.time_tracker.browser_development",
			Source:             domain.RuleSourceUser,
			Priority:           310,
			AppPattern:         "(?i)^(Arc|Firefox|Google Chrome|Chrome|Safari)$",
			TitlePattern:       titlePattern,
			ActionType:         domain.RuleActionAssignActivityCurrent,
			ActionActivityName: devActivity,
		},
	}
	if includeMeeting {
		rules = append(rules, domain.RuleInput{
			RuleKey:            "preset.time_tracker.communication_meeting",
			Source:             domain.RuleSourceUser,
			Priority:           300,
			AppPattern:         "(?i)^(Slack|Microsoft Teams|zoom\\.us|Zoom)$",
			TitlePattern:       titlePattern,
			ActionType:         domain.RuleActionAssignActivityCurrent,
			ActionActivityName: meetingActivity,
		})
	}
	return rules
}

func (r *Runner) runProjects(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt projects <list|create|activities|add-activity|add|end|clear|current>")
		return 2
	}
	sub := args[0]
	switch sub {
	case "list":
		fs := flag.NewFlagSet("projects list", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		scope := fs.String("scope", "active", "active|all|archived")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}

		scopeValue := strings.ToLower(strings.TrimSpace(*scope))
		var items []domain.Project
		switch scopeValue {
		case "active":
			listRes, err := r.App.Projects.ListActive(ctx, contracts.ProjectsListActiveRequest{})
			if err != nil {
				fmt.Fprintf(stderr, "error: %v\n", err)
				return 1
			}
			items = listRes.Projects
		case "all":
			listRes, err := r.App.Projects.ListAll(ctx, contracts.ProjectsListAllRequest{})
			if err != nil {
				fmt.Fprintf(stderr, "error: %v\n", err)
				return 1
			}
			items = listRes.Projects
		case "archived":
			listRes, err := r.App.Projects.ListArchived(ctx, contracts.ProjectsListArchivedRequest{})
			if err != nil {
				fmt.Fprintf(stderr, "error: %v\n", err)
				return 1
			}
			items = listRes.Projects
		default:
			fmt.Fprintln(stderr, "--scope must be one of active|all|archived")
			return 2
		}

		if *format == "text" {
			if len(items) == 0 {
				fmt.Fprintf(stdout, "No %s projects\n", scopeValue)
				return 0
			}
			for _, p := range items {
				if strings.TrimSpace(p.Metadata) != "" {
					fmt.Fprintf(stdout, "%d %s | %s\n", p.ProjectID, p.Title, p.Metadata)
					continue
				}
				fmt.Fprintf(stdout, "%d %s\n", p.ProjectID, p.Title)
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"scope": scopeValue, "projects": clidto.ProjectsFromDomain(items)}, stderr)
	case "create":
		fs := flag.NewFlagSet("projects create", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		title := fs.String("title", "", "project title")
		metadata := fs.String("metadata", "", "project metadata")
		activate := fs.Bool("activate", false, "activate created project")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		titleValue := strings.TrimSpace(*title)
		if titleValue == "" {
			fmt.Fprintln(stderr, "--title is required")
			return 2
		}
		createRes, err := r.App.Projects.Create(ctx, contracts.ProjectsCreateRequest{
			Title:    titleValue,
			Metadata: *metadata,
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}

		activated := false
		if *activate {
			if _, err := r.App.Projects.Activate(ctx, contracts.ProjectsActivateRequest{ProjectID: createRes.Project.ProjectID}); err != nil {
				fmt.Fprintf(stderr, "error: %v\n", err)
				return 1
			}
			activated = true
		}

		if *format == "text" {
			fmt.Fprintf(stdout, "project created: %d %s\n", createRes.Project.ProjectID, createRes.Project.Title)
			if activated {
				fmt.Fprintf(stdout, "project activated: %d %s\n", createRes.Project.ProjectID, createRes.Project.Title)
			}
			return 0
		}
		projectDTOs := clidto.ProjectsFromDomain([]domain.Project{createRes.Project})
		projectDTO := clidto.Project{}
		if len(projectDTOs) > 0 {
			projectDTO = projectDTOs[0]
		}
		return emit(stdout, *format, map[string]any{"project": projectDTO, "activated": activated}, stderr)
	case "activities":
		fs := flag.NewFlagSet("projects activities", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		projectID := fs.Int64("project-id", 0, "project id")
		projectTitle := fs.String("project", "", "project title")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		resolvedProjectID, resolvedProjectTitle, err := r.resolveProjectReference(ctx, *projectID, *projectTitle)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}

		listRes, err := r.App.Projects.ListActivitiesByProject(ctx, contracts.ProjectsListActivitiesRequest{
			ProjectID: resolvedProjectID,
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			if len(listRes.Activities) == 0 {
				fmt.Fprintf(stdout, "No activities in project: %s\n", resolvedProjectTitle)
				return 0
			}
			for _, activity := range listRes.Activities {
				fmt.Fprintf(stdout, "%d %s\n", activity.ActivityID, activity.Title)
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{
			"project_id":    resolvedProjectID,
			"project_title": resolvedProjectTitle,
			"activities":    clidto.ActivitiesFromDomain(listRes.Activities),
		}, stderr)
	case "add-activity":
		fs := flag.NewFlagSet("projects add-activity", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		projectID := fs.Int64("project-id", 0, "project id")
		projectTitle := fs.String("project", "", "project title")
		title := fs.String("title", "", "activity title")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		titleValue := strings.TrimSpace(*title)
		if titleValue == "" {
			fmt.Fprintln(stderr, "--title is required")
			return 2
		}
		resolvedProjectID, resolvedProjectTitle, err := r.resolveProjectReference(ctx, *projectID, *projectTitle)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}

		addRes, err := r.App.Projects.AddActivity(ctx, contracts.ProjectsAddActivityRequest{
			ProjectID: resolvedProjectID,
			Title:     titleValue,
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if *format == "text" {
			fmt.Fprintf(stdout, "activity added: %d %s (project: %s)\n", addRes.Activity.ActivityID, addRes.Activity.Title, resolvedProjectTitle)
			return 0
		}
		activityDTOs := clidto.ActivitiesFromDomain([]domain.Activity{addRes.Activity})
		activityDTO := clidto.Activity{}
		if len(activityDTOs) > 0 {
			activityDTO = activityDTOs[0]
		}
		return emit(stdout, *format, map[string]any{
			"project_id":    resolvedProjectID,
			"project_title": resolvedProjectTitle,
			"activity":      activityDTO,
		}, stderr)
	case "add":
		fs := flag.NewFlagSet("projects add", flag.ContinueOnError)
		fs.SetOutput(stderr)
		projectID := fs.Int64("project-id", 0, "project id")
		projectTitle := fs.String("project", "", "project title")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}

		resolvedProjectID := *projectID
		if resolvedProjectID <= 0 && strings.TrimSpace(*projectTitle) == "" {
			if fs.NArg() < 1 {
				fmt.Fprintln(stderr, "usage: tt projects add <project_id> OR tt projects add --project <title>")
				return 2
			}
			parsedID, err := strconv.ParseInt(fs.Arg(0), 10, 64)
			if err != nil {
				fmt.Fprintln(stderr, "invalid project id")
				return 2
			}
			resolvedProjectID = parsedID
		}

		resolvedProjectID, resolvedProjectTitle, err := r.resolveProjectReference(ctx, resolvedProjectID, *projectTitle)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if _, err := r.App.Projects.Activate(ctx, contracts.ProjectsActivateRequest{ProjectID: resolvedProjectID}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "project activated: %d %s\n", resolvedProjectID, resolvedProjectTitle)
		return 0
	case "end":
		fs := flag.NewFlagSet("projects end", flag.ContinueOnError)
		fs.SetOutput(stderr)
		projectID := fs.Int64("project-id", 0, "project id")
		projectTitle := fs.String("project", "", "project title")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}

		resolvedProjectID := *projectID
		if resolvedProjectID <= 0 && strings.TrimSpace(*projectTitle) == "" {
			if fs.NArg() < 1 {
				fmt.Fprintln(stderr, "usage: tt projects end <project_id> OR tt projects end --project <title>")
				return 2
			}
			parsedID, err := strconv.ParseInt(fs.Arg(0), 10, 64)
			if err != nil {
				fmt.Fprintln(stderr, "invalid project id")
				return 2
			}
			resolvedProjectID = parsedID
		}

		resolvedProjectID, resolvedProjectTitle, err := r.resolveProjectReference(ctx, resolvedProjectID, *projectTitle)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		if _, err := r.App.Projects.End(ctx, contracts.ProjectsEndRequest{ProjectID: resolvedProjectID}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "project ended: %d %s\n", resolvedProjectID, resolvedProjectTitle)
		return 0
	case "clear":
		if _, err := r.App.Projects.EndAll(ctx, contracts.ProjectsEndAllRequest{}); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "all projects ended")
		return 0
	case "current":
		fs := flag.NewFlagSet("projects current", flag.ContinueOnError)
		fs.SetOutput(stderr)
		format := fs.String("format", "text", "text|json|yaml")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		currentRes, err := r.App.Projects.Current(ctx, contracts.ProjectsCurrentRequest{})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		name := currentRes.Name
		id := currentRes.ProjectID
		if *format == "text" {
			if id == nil {
				fmt.Fprintln(stdout, "No current project")
			} else {
				fmt.Fprintf(stdout, "Current project: %d %s\n", *id, name)
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"project_id": id, "name": name}, stderr)
	default:
		fmt.Fprintf(stderr, "unknown projects subcommand: %s\n", sub)
		return 2
	}
}

func (r *Runner) resolveProjectReference(ctx context.Context, projectID int64, projectTitle string) (int64, string, error) {
	titleValue := strings.TrimSpace(projectTitle)
	if projectID > 0 && titleValue != "" {
		return 0, "", fmt.Errorf("use either --project-id or --project, not both")
	}
	projectsRes, err := r.App.Projects.ListAll(ctx, contracts.ProjectsListAllRequest{})
	if err != nil {
		return 0, "", err
	}
	projects := projectsRes.Projects
	if projectID > 0 {
		for _, project := range projects {
			if project.ProjectID == projectID {
				return project.ProjectID, project.Title, nil
			}
		}
		return 0, "", domain.ErrProjectNotFound
	}
	if titleValue != "" {
		for _, project := range projects {
			if strings.EqualFold(strings.TrimSpace(project.Title), titleValue) {
				return project.ProjectID, project.Title, nil
			}
		}
		return 0, "", domain.ErrProjectNotFound
	}
	return 0, "", fmt.Errorf("project reference is required")
}

func (r *Runner) runReports(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("reports", flag.ContinueOnError)
	fs.SetOutput(stderr)
	format := fs.String("format", "text", "text|json|yaml")
	rangeKey := fs.String("range", "today", "today|week|all")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	repRes, err := r.App.Reports.Report(ctx, contracts.ReportsBuildRequest{RangeKey: usecases.NormalizeRange(*rangeKey)})
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	rep := repRes.Report
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
	return emit(stdout, *format, clidto.ReportFromDomain(rep), stderr)
}

func (r *Runner) runSettings(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: tt settings <list|get|set|unset>")
		return 2
	}
	sub := args[0]
	loadRes, err := r.App.Settings.Load(ctx, contracts.SettingsLoadRequest{})
	if err != nil {
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
	cfg := loadRes.Settings
	switch sub {
	case "list":
		b, _ := json.MarshalIndent(clidto.SettingsFromDomain(cfg), "", "  ")
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
		if _, err := r.App.Settings.Save(ctx, contracts.SettingsSaveRequest{Settings: cfg}); err != nil {
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
		defaultsRes, _ := r.App.Settings.Load(context.Background(), contracts.SettingsLoadRequest{})
		defaults := defaultsRes.Settings
		if err := unsetSetting(&cfg, defaults, args[1]); err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 2
		}
		if _, err := r.App.Settings.Save(ctx, contracts.SettingsSaveRequest{Settings: cfg}); err != nil {
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

func splitCSVNormalized(s string) []string {
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
		datesRes, err := r.App.Review.Dates(ctx, contracts.ReviewDatesRequest{MinDurationMS: minDur})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		dates := datesRes.Dates
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
		groupsRes, err := r.App.Review.Groups(ctx, contracts.ReviewGroupsRequest{Date: *date, MinDurationMS: *minDur})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		groups := groupsRes.Groups
		if *format == "text" {
			for _, g := range groups {
				fmt.Fprintf(stdout, "%s | %s | %d events | %s\n", g.AppName, g.WindowTitle, g.EventCount, domain.FormatDuration(g.TotalDurationMS))
			}
			return 0
		}
		return emit(stdout, *format, map[string]any{"groups": clidto.GroupedEventsFromDomain(groups)}, stderr)
	case "map-group":
		fs := flag.NewFlagSet("review map-group", flag.ContinueOnError)
		fs.SetOutput(stderr)
		date := fs.String("date", "", "date")
		app := fs.String("app", "", "app")
		title := fs.String("title", "", "title")
		project := fs.Int64("project-id", 0, "project")
		activity := fs.Int64("activity-id", 0, "activity")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *date == "" || *app == "" || *title == "" || *project == 0 || *activity == 0 {
			fmt.Fprintln(stderr, "--date --app --title --project-id --activity-id are required")
			return 2
		}
		mapRes, err := r.App.Review.MapGroup(ctx, contracts.ReviewMapGroupRequest{
			Date:        *date,
			AppName:     *app,
			WindowTitle: *title,
			ProjectID:   *project,
			ActivityID:  *activity,
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "mapped events: %d\n", mapRes.Mapped)
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
		discardRes, err := r.App.Review.DiscardGroup(ctx, contracts.ReviewDiscardGroupRequest{
			Date:        *date,
			AppName:     *app,
			WindowTitle: *title,
		})
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "discarded events: %d\n", discardRes.Discarded)
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
  install        Install worker and launchd agent (prints Accessibility steps)
  uninstall      Remove worker and launchd agent
  start          Start collector via launchd
  stop           Stop collector via launchd
  status         Show launchd collector status and permission hints
  serve          Start web UI (HTMX)
  doctor         Print local paths, collector status, and known startup hints
  rules          Manage rules and auto-categorization suggestions
  projects       Manage projects, activities, and current project context
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
  tt rules targets --format json
  tt rules time-tracker --dry-run
  tt rules time-tracker --dev-activity development --meeting-activity meeting
  tt rules suggest --format json --limit 20 --min-evidence 2
  tt rules auto-apply --min-confidence 90 --apply-now
  tt rules bootstrap --date 2026-02-06 --format json
  tt rules label-group --date 2026-02-06 --app Arc --title "Daily standup" --activity development --create-rule --apply-now
  tt projects create --title "time-tracker" --metadata "local repo"
  tt projects add --project "time-tracker"
  tt projects add-activity --project "time-tracker" --title development
  tt projects activities --project "time-tracker" --format json
  tt review groups --date 2026-02-06 --format json
  tt reports --range week --format json
`)
}

var _ = os.Args

func (r *Runner) printAccessibilityHint(out io.Writer) {
	workerPath := strings.TrimSpace(r.WorkerPath)
	if workerPath == "" {
		workerPath = "~/.local/bin/tt-worker"
	}
	fmt.Fprintln(out, "accessibility: grant permission to the worker binary in System Settings -> Privacy & Security -> Accessibility")
	fmt.Fprintf(out, "accessibility-worker: %s\n", workerPath)
	fmt.Fprintln(out, "accessibility-note: keep the worker running; tracking starts automatically after permission is granted")
}

func (r *Runner) printAccessibilityTroubleshootingGuide(out io.Writer) {
	workerPath := strings.TrimSpace(r.WorkerPath)
	if workerPath == "" {
		workerPath = "~/.local/bin/tt-worker"
	}

	fmt.Fprintln(out, "accessibility-troubleshooting:")
	fmt.Fprintln(out, "  quick-fix: remove and re-add the worker binary in Accessibility, then run `./tracker start`")
	fmt.Fprintln(out, "  1) verify tccd decision for current worker pid:")
	fmt.Fprintln(out, "     ./tracker status")
	fmt.Fprintln(out, "     log show --style compact --last 5m --predicate 'process == \"tccd\" AND eventMessage CONTAINS \"sender_pid=<PID>\"'")
	fmt.Fprintln(out, "  2) if log shows AUTHREQ_RESULT ... authValue=0 for tt-worker, permission is denied despite toggle")
	fmt.Fprintln(out, "  3) fix sequence:")
	fmt.Fprintln(out, "     ./tracker stop")
	fmt.Fprintf(out, "     remove and re-add %s in Accessibility settings\n", workerPath)
	fmt.Fprintln(out, "     ./tracker start")
	fmt.Fprintln(out, "  4) avoid running an older tracker binary that overwrites the worker after permission is granted")
}

var workerErrLogPath = "/tmp/time-tracker-worker.err.log"

func workerLogHasAccessibilityError() bool {
	b, err := os.ReadFile(workerErrLogPath)
	if err != nil || len(b) == 0 {
		return false
	}
	if len(b) > 64*1024 {
		b = b[len(b)-64*1024:]
	}
	return strings.Contains(string(b), "Accessibility permission required")
}
