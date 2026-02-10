# Project Planning for Release 1.0

Last updated: 2026-02-10

## Goal

Ship a stable **1.0** release of the current Swift + Zig + Go + DuckDB architecture with:

- Safe upgrades and migration consistency.
- Reliable event persistence during runtime and shutdown.
- Better release diagnostics and observability.
- Stronger WiFi-based work-site determination.

## Execution Model

- Keep tasks small and isolated.
- Prefer parallel work across independent workstreams.
- Every task must include tests or explicit manual verification steps.

## Workstream A: Release Safety (P0)

### A1. Zig/Go migration parity
- Priority: P0
- Why: Prevent schema mismatch when worker migrates DB.
- Scope:
  - Add SQL migrations `014`-`018` to Zig migration pipeline.
  - Align migration version assertions with Go side.
- Files:
  - `src/external/duckdb/migrations.zig`
  - `src/external/duckdb/migrations_test.zig`
- Acceptance:
  - Zig migration tests pass with final version matching Go (`18`).
  - Fresh DB and migrated legacy DB both succeed under Zig worker.
- Dependencies: None

### A2. Migration drift guard test
- Priority: P0
- Why: Prevent future divergence between Go and Zig migration sets.
- Scope:
  - Add automated test that compares migration filenames and contents across both stacks.
- Files:
  - `migrations/migrations_test.go`
- Acceptance:
  - Test fails if any migration is missing or differs.
- Dependencies: A1 recommended first

### A3. Pre-migration DB backup
- Priority: P0
- Why: Safe rollback path for user DBs during upgrades.
- Scope:
  - Before applying migrations to file-based DB, create timestamped backup.
  - Document backup location/retention behavior.
- Files:
  - `internal/external/duckdb/open.go`
  - `src/external/duckdb/legacy_repository.zig`
  - `internal/external/api/content/getting-started.md`
- Acceptance:
  - Backup file is created before schema changes for non-`:memory:` DBs.
  - Tests verify backup creation path.
- Dependencies: None

## Workstream B: Reliability (P0)

### B1. Buffered write failure handling
- Priority: P0
- Why: Avoid silent event loss on transient DB errors.
- Scope:
  - Make buffered save path propagate write errors.
  - Keep failed events in buffer and retry on next flush.
- Files:
  - `src/external/duckdb/legacy_repository.zig`
  - `src/external/duckdb/buffered_repository.zig`
  - `src/external/duckdb/buffered_repository_test.zig`
- Acceptance:
  - Simulated insert failures do not drop events.
  - Events are persisted after retry when DB is healthy.
- Dependencies: None

### B2. Graceful shutdown flush
- Priority: P0
- Why: Ensure in-memory events are not lost on stop/restart.
- Scope:
  - Add worker shutdown flow that flushes buffer before process exit.
  - Coordinate bridge stop and worker stop semantics.
- Files:
  - `src/entrypoint/main.zig`
  - `src/external/duckdb/buffered_repository.zig`
  - `src/bridge/macos_bridge.swift`
- Acceptance:
  - On controlled stop, pending events are flushed.
  - Integration test verifies persisted events after shutdown.
- Dependencies: B1

## Workstream C: WiFi Work-Site Determination (P0/P1)

### C1. Periodic WiFi refresh independent of app changes
- Priority: P0
- Why: WiFi changes currently can be missed until app/title changes.
- Scope:
  - Add timer-based refresh calling SSID detection + tracking state update.
- Files:
  - `src/bridge/macos_bridge.swift`
- Acceptance:
  - Tracking state reacts to WiFi changes even while focused app/title is unchanged.
- Dependencies: None

### C2. Unknown WiFi state semantics
- Priority: P0
- Why: Empty SSID handling should be explicit and diagnosable.
- Scope:
  - Define explicit `(unknown)` WiFi handling and tracking behavior.
  - Add clear logs/status for permission/fallback failure.
- Files:
  - `src/bridge/macos_bridge.swift`
- Acceptance:
  - User can distinguish “not on work site” from “WiFi unknown”.
  - Behavior is deterministic when patterns are configured.
- Dependencies: None

### C3. Menu/status visibility for current WiFi + work-site state
- Priority: P1
- Why: Users need immediate confidence in work-site detection.
- Scope:
  - Show current SSID and site status in menu bar status text/menu item.
- Files:
  - `src/bridge/macos_bridge.swift`
- Acceptance:
  - Status text shows one of: `tracking`, `paused (non-work WiFi)`, `unknown WiFi`.
  - Includes current SSID when available.
- Dependencies: C1, C2

### C4. Optional WiFi-change event boundary
- Priority: P1
- Why: Improve historical “where was I working” fidelity.
- Scope:
  - Treat WiFi changes as event boundaries or annotate events with transition markers.
- Files:
  - `src/domain/event.zig`
  - `src/application/services/tracker.zig`
  - `src/bridge/macos_bridge.swift`
- Acceptance:
  - Timeline can distinguish sessions across different work sites.
  - No regression in event coalescing behavior.
- Dependencies: C1

## Workstream D: Observability + Operability (P1)

### D1. API request ID + health endpoint
- Priority: P1
- Why: Improve production diagnostics and readiness checks.
- Scope:
  - Add request ID middleware.
  - Add `/healthz` endpoint with basic readiness signal.
- Files:
  - `internal/external/api/server.go`
  - `internal/external/api/server_test.go`
- Acceptance:
  - Every API log line includes request ID.
  - `/healthz` returns 200 when service is ready.
- Dependencies: None

### D2. Install/upgrade path for worker replacement
- Priority: P1
- Why: 1.0 needs explicit upgrade path for trusted worker binary updates.
- Scope:
  - Add `install --replace-worker` (or `--force`) behavior.
  - Document expected Accessibility/permission implications.
- Files:
  - `internal/external/cli/runner.go`
  - `internal/external/launchd/service.go`
  - `internal/application/usecases/help_usecase.go`
  - `internal/external/api/content/getting-started.md`
- Acceptance:
  - User can force worker refresh during upgrade.
  - CLI help and docs clearly describe behavior.
- Dependencies: None

## Workstream E: Test Completion for 1.0 Confidence (P1)

### E1. Review usecase tests
- Priority: P1
- Why: Core manual correction flow needs direct usecase coverage.
- Scope:
  - Add tests for list dates/groups, map-group, discard-group and error paths.
- Files:
  - `internal/application/usecases/review_usecase_test.go`
- Acceptance:
  - All review usecase methods are covered for success and failure.
- Dependencies: None

### E2. Lifecycle and settings usecase tests
- Priority: P1
- Why: Startup/runtime controls are critical for release quality.
- Scope:
  - Add tests for lifecycle actions and settings load/save error propagation.
- Files:
  - `internal/application/usecases/lifecycle_usecase_test.go`
  - `internal/application/usecases/settings_usecase_test.go`
- Acceptance:
  - Usecase boundaries fully covered with port fakes.
- Dependencies: None

### E3. CLI review/settings/reports command tests
- Priority: P1
- Why: 1.0 CLI should be dependable for both users and LLM tooling.
- Scope:
  - Expand parser/output/exit-code coverage for review, settings, and reports commands.
- Files:
  - `internal/external/cli/runner_test.go`
- Acceptance:
  - Commands return deterministic outputs for `text|json|yaml` and fail clearly on invalid inputs.
- Dependencies: None

## Suggested Parallel Assignment (First Sprint)

- Developer 1: A1 + A2
- Developer 2: B1 + B2
- Developer 3: C1 + C2
- Developer 4: D1 + E1
- Developer 5: D2 + E2 + E3

## Definition of Done for 1.0

- All P0 tasks completed.
- P1 tasks completed or explicitly deferred with documented risk acceptance.
- `go test -mod=readonly ./...` and Zig test suites pass in CI.
- Release notes include upgrade/backward-compatibility notes and WiFi work-site behavior.
