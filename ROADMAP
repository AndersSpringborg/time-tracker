# Time Tracker Roadmap (Code-Aligned)

Last updated: 2026-02-10

## 1. Current Architecture (Source of Truth)

This project is **not** a greenfield Rust/Tauri app. The current production architecture is:

- **Swift (`src/bridge/macos_bridge.swift`)**
  - macOS collector bridge using Accessibility + workspace notifications + WiFi context.
- **Zig Worker (`src/entrypoint/main.zig`)**
  - Daemon process receives activity callbacks, computes event durations, writes buffered events.
- **Go App (`cmd/tt/main.go`)**
  - CLI (`internal/external/cli/runner.go`), HTTP/HTMX UI (`internal/external/api/server.go`), application usecases (`internal/application/usecases/*`).
- **DuckDB (`internal/external/duckdb/store.go`, `migrations/sql/*`)**
  - Embedded local database for rules, events, projects, reports, suggestions, and review flows.

## 2. Gap Analysis Against Previous ROADMAP

### 2.1 In the old plan and already implemented

- [x] Local-first storage and processing.
- [x] Background watcher/collector and event ingestion.
- [x] Coalesced timeline/event durations (not raw pulse reporting to UI).
- [x] Rule-based mapping from app/title to project/activity.
- [x] Rule precedence via priority + pattern matching.
- [x] Retroactive rule apply for historical events.
- [x] Review workflow for uncategorized/unmapped events.

### 2.2 In the old plan but currently missing

- [ ] Polling-based 1s watcher loop (current implementation is event-driven callbacks).
- [ ] AFK/idle detection based on keyboard/mouse inactivity threshold.
- [ ] Private/incognito redaction at capture time.
- [ ] Collector-side app blacklist (capture-time exclusion).
- [ ] Time-proximity clustering auto-inference ("sandwiched" events).
- [ ] Bayesian/ML classifier for project/activity prediction.
- [ ] Git branch scraper integration.
- [ ] Calendar meeting inference integration.

### 2.3 Implemented features not called out in old plan

- [x] Full Go-powered web UI with HTMX pages:
  - Dashboard, Reports, Rules, Suggestions, Projects, Settings, Integrations.
- [x] Suggestion pipeline and feedback loop:
  - suggest, accept/reject, auto-apply, bootstrap group labeling.
- [x] Rules draft/staging workflow with preview and save/discard.
- [x] Noise filtering + weighted reporting controls in settings.
- [x] Work WiFi gating (tracking enabled/disabled by configured SSIDs).
- [x] Project/activity lifecycle management:
  - create/archive/restore projects, per-project activity lists.
- [x] Tidsreg import integration (session, project preview, import flow).
- [x] CLI preset + LLM-friendly commands for rule and project setup:
  - `rules time-tracker`, `rules targets`, `projects create/activities/add-activity`.

## 3. Corrected Product Direction

### 3.1 Architecture direction

Keep and extend current architecture:

- Swift bridge for macOS sensors.
- Zig worker for low-overhead ingestion and buffering.
- Go for application layer, API, CLI, and web UI.
- DuckDB as embedded local database.

Do **not** roadmap a Rust/Tauri rewrite unless explicitly decided later.

### 3.2 Terminology (current domain language)

- **Event**: captured activity with app/window/time/wifi context (`internal/domain/types.go`).
- **Rule**: mapping instruction with action type and priority (`internal/domain/types.go`, `internal/domain/rules.go`).
- **Project / Activity**: assignment dimensions used for time mapping and reporting.
- **Suggestion**: generated candidate rule/mapping with confidence/score.
- **Grouped Event**: review/bootstrapping unit for unmapped event clusters.

## 4. Updated Roadmap (Next Steps)

### Phase A: Privacy + Capture Safety (Missing from current code)

Goal: close core privacy and data-quality gaps in collector behavior.

- Add idle/AFK detection with configurable threshold.
- Add private/incognito title redaction strategy.
- Add collector-side capture blacklist (app patterns).
- Add tests around redaction/blacklist/idle transitions.

Acceptance criteria:

- AFK periods are marked or skipped consistently.
- Private sessions never persist sensitive titles.
- Blacklisted apps are excluded before persistence.

### Phase B: Mapping Intelligence V1 (Heuristic, no ML)

Goal: improve auto-categorization using deterministic behavior before ML.

- Implement time-proximity inheritance heuristic for short uncategorized events.
- Add explicit confidence/reason fields for heuristic matches.
- Make heuristic behavior previewable in reports/rules preview.

Acceptance criteria:

- Measurable reduction in unmapped short browser/context-switch events.
- Users can inspect and override inferred mappings.

### Phase C: Mapping Intelligence V2 (Optional ML)

Goal: add optional classifier only if Phase B is insufficient.

- Define feature extraction from app/title/history.
- Train from accepted/rejected suggestion feedback.
- Run classifier as assistive signal, not auto-authoritative.

Acceptance criteria:

- Classifier improves precision/recall over heuristic baseline.
- Predictions are explainable and reversible.

### Phase D: Integrations

Goal: enrich mapping with contextual data where available.

- Git context integration (repo + branch hints).
- Calendar integration for meeting context.
- Integrations must be optional and privacy-controlled.

Acceptance criteria:

- Integrations can be enabled/disabled independently.
- Captured external metadata is minimal and transparent in UI.

## 5. Work Already Completed (Recent)

- Rules can map to **current project activity by name**.
- UI surfaces project/activity names in rule targets.
- Rules apply preview/dry-run is available on reports page.
- CLI now supports LLM-friendly project/activity management and rule presets.

## 6. Non-Goals (for now)

- Full stack rewrite to Rust/Tauri/Electron.
- Cloud-first event ingestion.
- Mandatory external integrations for core functionality.
