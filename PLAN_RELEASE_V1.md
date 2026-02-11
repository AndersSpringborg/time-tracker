# Simplify Tracker to Core Workflow (Events + WiFi Work Hours + Rules + Time-Proximity)

## Summary
Refocus the product on a single deterministic flow:

1. Collect events continuously (including WiFi SSID).
2. Compute **work hours** from events where `wifi_ssid` matches configured `work_wifis`.
3. Map events to project/activity via explicit rules plus default “follow previous project+activity” behavior.
4. Show project/activity outcomes by **name** everywhere in UI text output (never raw IDs as display target).

This plan hard-removes Suggestions and Noise Filtering from user workflows and code paths.

## Product Scope Locked
- Remove: suggestions, bootstrap labeling, auto-apply suggestions, suggestion feedback/runs, noise filtering.
- Keep: events, projects, activities, rules, apply-rules, work WiFi config, time-proximity heuristics.
- Default mapping: follow previous project+activity when no explicit mapping rule applies.
- Work-hours metric: only events on configured work WiFi patterns count as worked time.

## Public API / Interface Changes

### Domain types (`internal/domain/types.go`)
- Remove suggestion-related types:
  - `SuggestionType`, `RuleSuggestion`, `SuggestionQuery`, `SuggestionStats`, `SuggestionFeedback`, `SuggestionRun`, `BootstrapLabelInput/Result`, `ApplySuggestionInput/Result`, `AutoApplySuggestionsInput/Result`.
- Remove noise settings fields:
  - `NoiseAppPatterns`, `NoiseBucketMinutes`, `NoiseSwitchMinutes`.
- Extend reporting/dashboard types for WiFi work-hours:
  - `Dashboard`: replace `ExcludedEvents` with `WorkEvents`; keep `TrackedEvents`; add `WorkTodayMS`.
  - `Report`: remove `IncludedEvents` and `ExcludedEvents`; add `WorkEvents` and `WorkMS`.
- Keep `WeightedSwitchMinutes` as time-proximity carry window (now actively used).
- Keep `WeightedBucketMinutes` only if reused by proximity logic; otherwise deprecate then remove in same pass.

### Contracts (`internal/application/contracts/contracts.go`)
- Remove all suggestion/bootstrap/auto-apply request/response contracts.
- Keep rules list/add/delete/draft/apply/preview/targets contracts.
- Update reports contracts to reflect new `Dashboard`/`Report` fields.

### Ports (`internal/application/ports/ports.go`)
- `RulesRepository`: remove suggestion methods (`ListAppSuggestions`, `ListTitleSuggestions`, `ListBootstrapGroups`, `RecordSuggestionFeedback`, `RecordSuggestionRun`, `CountMappedEvents`, `CountActivities`).
- `ReportsRepository`: no signature change; filtering behavior changes in usecase.
- `SettingsRepository`: unchanged signatures; payload changed by removed noise fields.

### CLI surface (`internal/external/cli/runner.go`)
- `tt rules` usage becomes: `list|targets|time-tracker|add|delete|apply-rules`.
- Remove subcommands:
  - `suggest`, `accept`, `reject`, `auto-apply`, `bootstrap`, `label-group`.
- Update settings keys to remove noise keys.
- Text outputs that currently print IDs as user-facing labels should print names/paths where available (especially rule target displays).

### Web API routes/UI (`internal/external/api/server.go`, templates)
- Remove routes:
  - `/suggestions`, `/partials/suggestions`, `/suggestions/accept`, `/suggestions/reject`, `/suggestions/auto-apply`, `/partials/suggestions/bootstrap`, `/suggestions/bootstrap/map`.
- Remove suggestions data from `pageData`.
- Remove noise controls from Settings page.
- Dashboard/Reports UI labels updated:
  - “Worked today” (WiFi-based), “Tracked events”, “Work events”.
- Any rule target label in UI must render by name (or “Unmapped”), never `id > id`.

## Implementation Workstreams

1. **Remove Suggestion Stack**
- Delete suggestion logic in:
  - `internal/application/usecases/rules_usecase.go`
  - `internal/domain/rules.go` (suggestion ranking/matching helpers)
  - `internal/external/duckdb/store.go` suggestion query sections
  - `internal/external/api/templates/suggestions*.html`
  - relevant DTO structs/tests.
- Keep DB tables as legacy (no runtime use) unless a migration cleanup is desired later.

2. **Remove Noise Filtering**
- Remove `domain.BuildNoiseMask` usage from `ReportsUsecase.Dashboard` and `ReportsUsecase.Report`.
- Remove noise settings from config defaults/normalize/save/load:
  - `internal/external/configfs/repository.go`
  - settings CLI/API read-write paths.
- Remove UI/report strings referencing “Excluded noisy”.

3. **WiFi Work Hours Calculation**
- Add domain helper: pattern match `wifi_ssid` against `WorkWifis` (case-insensitive wildcard semantics consistent with config behavior).
- In reports/dashboard usecases:
  - `TrackedEvents`/`TotalEvents` remain all events.
  - `WorkMS`/`WorkTodayMS` and `WorkEvents` count only WiFi-matching events.
  - Project/activity/app/window summaries for “worked” view are built from WiFi-matching events.
- If `work_wifis` is empty: `WorkMS=0`, `WorkEvents=0` (explicit, deterministic).

4. **Default Follow-Previous + Time-Proximity Heuristics**
- Ensure default fallback rule exists in defaults as lowest-priority catch-all:
  - action `follow_current_context`, app/title match-any.
- Apply time-proximity guard in rule matching:
  - clear previous context if gap between consecutive events exceeds carry window (`WeightedSwitchMinutes`, default 10 min).
- Keep explicit rules higher priority than fallback.
- Preserve existing action types that resolve by project/activity names.

5. **Name-Only UI Rule Targets**
- Update `Rule.DisplayTargetText()` to avoid numeric fallback (`%d > %d`).
- Ensure display path comes from resolved names or semantic labels:
  - `Follow current project/activity`
  - `Current project > <activity>`
  - `<project> > <activity>`
  - `Unmapped` when names unavailable
- Align CLI and web templates to show display names, not raw target IDs as labels.

6. **Help/Docs Cleanup**
- Update help schema and examples:
  - remove suggestion commands and wording.
- Update getting-started docs to core workflow only.

## Test Cases and Scenarios

1. **Rules + fallback**
- No explicit match + prior mapped context within carry window => maps to previous project/activity.
- Gap greater than carry window => previous context not reused.
- Explicit IntelliJ/Ghostty title rule (`assign_project_activity_by_title`) maps to named project/activity.

2. **WiFi work-hours**
- Work WiFi match => counted in `WorkMS`.
- Non-work WiFi / empty SSID => excluded from `WorkMS`.
- `work_wifis` empty => `WorkMS` always zero.

3. **Reports/dashboard totals**
- `TotalMS` and `TrackedEvents` remain raw tracked totals.
- `WorkMS`/`WorkEvents` reflect WiFi-filtered totals.
- By-project/activity summaries reflect WiFi-filtered data.

4. **No suggestion/noise surfacing**
- CLI `tt rules suggest` and other removed subcommands return unknown usage.
- Web suggestions routes removed (404 / not registered).
- Settings persistence excludes removed noise keys.

5. **Name-only display**
- Rules list/draft preview never render `id > id` target text.
- Explicit ID-backed rules still display resolved names through joined titles.

## Assumptions and Defaults
- Chosen: **hard remove** suggestions and noise from product surface and active code paths.
- Chosen: work hours are **only** WiFi-matching event durations.
- Chosen: default mapping is **follow previous project+activity**.
- Default carry window for time proximity: `WeightedSwitchMinutes = 10` (existing default), now enforced in matching logic.
- Legacy DB suggestion tables are retained for backward compatibility but unused by runtime.
