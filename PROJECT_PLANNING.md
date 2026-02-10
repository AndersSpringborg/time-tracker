# Release 1.0 Project Planning (Aligned with `ROADMAP.md`)

Last updated: 2026-02-10

## 1. Planning Inputs

This plan is aligned to the current roadmap in `ROADMAP.md` and focuses on shipping a stable 1.0 from the existing architecture (Swift bridge + Zig worker + Go CLI/API + DuckDB).

Key roadmap alignment:

- Keep architecture as-is (no rewrite).
- Focus 1.0 on reliability + operational safety + WiFi work-site determination.
- Deliver mapping intelligence V1 (heuristic improvements).
- Move Bayesian/ML classification to release 2.

## 2. Release 1.0 Scope

### In scope for 1.0

- Migration and upgrade safety.
- Event persistence reliability (including shutdown behavior).
- WiFi work-site detection quality and visibility.
- Idle/AFK detection.
- Time-proximity heuristic mapping.
- Observability and release readiness checks.

### Explicitly out of scope for 1.0

- Bayesian/ML classifier (release 2).
- Large architectural rewrite.

## 3. Task Board (Small, Isolated, Parallelizable)

Each task is intentionally small so a developer can start immediately.

## Track A: Release Safety (P0)

### A1. Zig migration parity to v18
- Priority: P0
- Scope: Add migrations `014`-`018` to Zig migration runner.
- Files: `src/external/duckdb/migrations.zig`, `src/external/duckdb/migrations_test.zig`
- Acceptance: Zig migration version equals Go migration version (`18`), tests pass.

### A2. Migration drift guard test
- Priority: P0
- Scope: Add test to compare migration sets between Go and Zig.
- Files: `migrations/migrations_test.go`
- Acceptance: test fails on missing/changed migration file across stacks.
- Depends on: A1

### A3. Pre-migration backup (file DB)
- Priority: P0
- Scope: Create timestamped DB backup before schema migration for file-based DB.
- Files: `internal/external/duckdb/open.go`, `src/external/duckdb/legacy_repository.zig`
- Acceptance: backup created before migration; behavior documented.

## Track B: Runtime Reliability (P0)

### B1. Buffered write error retention
- Priority: P0
- Scope: Do not drop buffered events on write failure; keep for retry.
- Files: `src/external/duckdb/legacy_repository.zig`, `src/external/duckdb/buffered_repository.zig`, `src/external/duckdb/buffered_repository_test.zig`
- Acceptance: simulated insert failures do not lose events.

### B2. Graceful stop flush
- Priority: P0
- Scope: Flush buffered events during controlled shutdown.
- Files: `src/entrypoint/main.zig`, `src/external/duckdb/buffered_repository.zig`, `src/bridge/macos_bridge.swift`
- Acceptance: pending events persist after stop/restart.
- Depends on: B1

## Track C: WiFi Work-Site Determination (P0/P1)

### C1. Periodic WiFi refresh loop
- Priority: P0
- Scope: Update WiFi/track-state on timer, not only on app/title changes.
- Files: `src/bridge/macos_bridge.swift`
- Acceptance: state changes when WiFi changes without focus change.

### C2. Unknown WiFi semantics
- Priority: P0
- Scope: Define and surface explicit unknown state (`(unknown)`), not silent non-match.
- Files: `src/bridge/macos_bridge.swift`
- Acceptance: user can distinguish "unknown" vs "not work site".

### C3. Work-site status in menu
- Priority: P1
- Scope: Show current SSID + tracking/work-site state in menu/status.
- Files: `src/bridge/macos_bridge.swift`
- Acceptance: menu clearly shows `tracking`, `paused (non-work WiFi)`, or `unknown WiFi`.
- Depends on: C1, C2

### C4. WiFi transition boundary support
- Priority: P1
- Scope: Treat WiFi transitions as event/session boundary (or explicit marker).
- Files: `src/domain/event.zig`, `src/application/services/tracker.zig`, `src/bridge/macos_bridge.swift`
- Acceptance: history can show where work happened per session/site.
- Depends on: C1

## Track D: Mapping Intelligence V1 (P1)

### D1. Idle/AFK detection
- Priority: P1
- Scope: Add configurable inactivity threshold and state handling.
- Files: `src/bridge/macos_bridge.swift`, `internal/domain/types.go` (if state exposed), `internal/external/api/templates/settings.html` (if configurable)
- Acceptance: inactivity is reflected and prevents false active tracking.

### D2. Time-proximity heuristic mapping
- Priority: P1
- Scope: Map short unmapped events between same-project mapped events.
- Files: `internal/application/usecases/rules_usecase.go`, `internal/domain/rules.go`, `internal/application/usecases/rules_usecase_test.go`
- Acceptance: measurable reduction of short unmapped context-switch events.

### D3. Heuristic explainability
- Priority: P1
- Scope: Include reason/confidence metadata for heuristic assignments.
- Files: `internal/domain/types.go`, `internal/external/api/templates/partials/report_table.html`, `internal/external/api/server.go`
- Acceptance: user can inspect why an event was auto-assigned.
- Depends on: D2

## Track E: Observability + Operability (P1)

### E1. Request IDs and `/healthz`
- Priority: P1
- Scope: Add request-id middleware and health endpoint.
- Files: `internal/external/api/server.go`, `internal/external/api/server_test.go`
- Acceptance: each request log includes request ID; health endpoint returns ready status.

### E2. Worker replacement upgrade path
- Priority: P1
- Scope: Add `install --replace-worker` (or `--force`) for safe worker upgrades.
- Files: `internal/external/cli/runner.go`, `internal/external/launchd/service.go`, `internal/application/usecases/help_usecase.go`, `internal/external/api/content/getting-started.md`
- Acceptance: user can explicitly refresh worker binary during upgrade.

## Track F: Test Completion for 1.0 Confidence (P1)

### F1. Review usecase test suite
- Priority: P1
- Scope: Add success/error tests for list/map/discard review flows.
- Files: `internal/application/usecases/review_usecase_test.go`
- Acceptance: review usecase fully covered.

### F2. Lifecycle/settings usecase tests
- Priority: P1
- Scope: Add tests for lifecycle operations and settings load/save errors.
- Files: `internal/application/usecases/lifecycle_usecase_test.go`, `internal/application/usecases/settings_usecase_test.go`
- Acceptance: full usecase boundary coverage.

### F3. CLI review/settings/reports coverage
- Priority: P1
- Scope: Expand CLI parser/output/exit-code tests.
- Files: `internal/external/cli/runner_test.go`
- Acceptance: deterministic behavior across `text|json|yaml` and invalid input handling.

## 4. Suggested Team Start Plan (Parallel)

- Dev 1: A1, A2
- Dev 2: B1, B2
- Dev 3: C1, C2
- Dev 4: D1, F1
- Dev 5: D2, D3
- Dev 6: E1, F2, F3
- Dev 7: E2, C3, C4

## 5. Release Gates

## Gate G1 (must pass before beta)
- A1, A2, A3 complete.
- B1, B2 complete.
- C1, C2 complete.

## Gate G2 (must pass before 1.0 tag)
- D1 and D2 complete.
- E1 complete.
- F1/F2/F3 complete.
- `go test -mod=readonly ./...` and Zig test suites green in CI.

## 6. Post-1.0 Backlog (Release 2)

- Bayesian/ML classifier for suggestion quality improvements.
- Broader integration intelligence (git/calendar auto-context expansion).
