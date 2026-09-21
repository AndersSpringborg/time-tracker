# Time tracker client redesign

Status: in progress. Existing production database and installed services have not
been changed.

## Work log

### In progress

- Phase 2: reliable ingestion and exclusive ownership. The ingestion foundation
  is complete; the client still writes directly to DuckDB until outbox and
  service cutover are implemented together.

### Done

- Completed static architecture review and documented target ownership,
  durability, retention, and acceptance criteria.
- Legacy collector batches now return insert/transaction errors, roll back
  partial writes, and retain buffered data until commit succeeds. Real DuckDB
  tests verify retry without duplicate inserts. The buffer is still memory-only.
- Top-level help/schema, settings, and lifecycle commands no longer open DuckDB.
  Database close now runs before process exit. Regression tests cover commands
  against an unusable database path and normal database-open failure reporting.
- Added validated ingestion domain types, application use case/port, migration
  019, and transactional event/cursor persistence. Tests cover partial replay,
  sequence gaps, concurrent retries, rollback, reopening, and raw-event deletion.
- Added a bounded `/v1/events` JSON handler for private local IPC, with tests for
  malformed/oversized requests, unknown fields, trailing data, replay, and
  storage failure. It is deliberately not mounted on the browser server or
  bound to a production socket yet.

### Pending

- Durable client outbox, sole-owner service/CLI cutover, native capture/UI
  isolation, retention/reporting, and live performance measurements.
- Backend ingestion currently serializes only other ingestion requests. The
  broader write coordination and classification policy remain part of cutover.

### Verification of first milestone

- PASS: `go test -race -shuffle=on -count=1 ./cmd/... ./internal/... ./migrations/...`
- PASS: `go vet ./cmd/... ./internal/... ./migrations/...`
- PASS: `/opt/homebrew/opt/zig@0.15/bin/zig build test --summary all` — 69 tests.
- PASS: `/opt/homebrew/opt/zig@0.15/bin/zig build` (includes Swift worker link).
- PASS: Go/Zig formatting and `git diff --check`.
- Environment: default `zig` is 0.16 and fails on existing 0.15 build/dependency
  APIs. The installed 0.15 toolchain works. Broad Go `./...` includes unrelated
  fixtures in the pre-existing untracked `zig-pkg/` directory; use the explicit
  application package roots above. No dependency upgrades were retained.
- Existing linker warnings were emitted for race-test object metadata and the
  worker macOS deployment target; builds/tests still succeeded.
- No live database migration, service installation/restart, retention deletion,
  or GUI profiling was performed.

## Goal

Keep the personal, local-first, two-component system while fixing native UI
blocking, competing DuckDB connections, and unlimited data retention. Preserve
the existing Swift/Zig collector and Go backend rather than rewriting them.

## Findings from code inspection

- App and window callbacks execute on the AppKit main thread and synchronously
  call Zig. `src/entrypoint/main.zig` refreshes menu state on every event by
  opening DuckDB and counting unmatched events across all history.
- `src/bridge/macos_bridge.swift` can synchronously run `system_profiler` for
  WiFi discovery. It waits without a timeout before draining stdout.
- Repository flushing holds the buffer mutex during database work. Sampling
  can wait for that mutex while holding the tracker mutex needed by UI callbacks.
- The worker opens DuckDB for flushes and menu refreshes. `cmd/tt/main.go` opens
  the database before command dispatch and retains it while serving HTTP.
- The Go backend also writes rules, mappings, projects, and imports; it cannot
  simply become a read-only database consumer.
- A steady active window remains pending in memory until its dominant window
  changes or the tracker finishes. Periodic repository flushing does not persist
  that pending interval.
- Insert and transaction failures are logged without returning errors, so a
  flush can clear buffered events without a successful commit.
- Reports currently depend on raw events. Deleting old events alone would
  remove historical totals, timelines, and review evidence.

These are static findings, not measurements of the running application. Profile
the blocking paths before implementation and use those measurements as a baseline.

## Target architecture

```text
macOS notifications
        |
        v
Swift/Zig client ----> cached native menu
        |
        v
durable local outbox
        |
        | asynchronous batches / committed acknowledgements
        v
Go backend <-------- web UI and CLI
        |
        v
DuckDB (exclusively owned by the Go backend)
```

### macOS client

- Capture app/window changes and produce timed activity intervals.
- Retain the five-second dominant-window behavior initially.
- Persist completed portions of long-running intervals periodically.
- Store unsent intervals in a bounded, durable outbox and retry delivery.
- Render cached status immediately without required I/O when opening the menu.
- Keep AppKit work on main; run Accessibility queries on a dedicated capture
  executor/run loop and WiFi discovery independently with bounded timeouts.
- Copy callback strings before asynchronous dispatch: Swift `withCString`
  pointers do not remain valid after the callback returns.
- Never hold capture/UI locks while doing storage or transport work.
- Handle pause, lock, sleep, resume, permissions, and shutdown explicitly.
- Use monotonic elapsed time for duration and wall time for reporting timestamps.

The menu shows tracking/permission state, current app/window, backend connection,
pending sync, pause/resume, open web UI, and quit. Project and unmatched counts
come from an asynchronously refreshed backend snapshot with stale state indicated.

### Go backend

- Run as an always-on per-user LaunchAgent, independently of the browser.
- Own all DuckDB access, migrations, ingestion, classification, edits, imports,
  reporting, retention, and maintenance.
- Serialize writes through an application-owned path; use bounded read
  connections within the same process for reports.
- Provide user-restricted local IPC for client and CLI operations, preferably
  a Unix socket. Keep browser HTTP bound to loopback.
- Keep domain behavior and application ports independent of transport/storage.
- Route CLI database operations through the service. Help and lifecycle commands
  must not require opening DuckDB.
- Opening or closing the browser must not affect collection or persistence.

### Delivery contract

- Version the protocol and outbox format.
- Give each producer a persistent identity and each interval a monotonic sequence.
- Use append-only, bounded outbox segments with explicit disk synchronization
  and recovery from an incomplete trailing record.
- Send batches every 5–10 seconds initially, with bounded sizes and retry backoff.
- Commit inserted intervals and the acknowledged producer sequence together.
- Acknowledge only after commit; remove local data only after acknowledgement.
- Retain deduplication cursors independently of event retention so replay cannot
  recreate deleted history or duplicate totals.
- Specify ordering, sequence gaps, invalid batches, expired records, and protocol
  incompatibility explicitly. Do not silently acknowledge discarded data.
- Target at most five seconds of unpersisted activity, including the active
  interval; verify this through crash tests.
- Bound disk and memory use. When the outbox cannot accept more data, expose a
  recording error instead of silently dropping unsent activity.

## Retention policy

The following are proposed configurable defaults, not approved deletion actions:

| Data | Retention |
| --- | --- |
| Detailed events, including window titles and WiFi | 90 days |
| Daily historical summaries | 2 years |
| Acknowledged client batches | Remove after acknowledgement |
| Diagnostic logs | Rotate and retain 7 days |
| Rules and project configuration | Until explicitly removed |

Before detailed events expire, materialize daily summaries and delete their raw
events in the same transaction. Summaries retain project/activity/app totals,
mapped/unmapped duration, relevant counts, and finalized work-time classification.
Define event-count semantics when intervals are split; do not inflate counts
merely because a long interval is periodically persisted.

- Split intervals at local-day boundaries using a defined reporting timezone,
  including daylight-saving transitions.
- Recent history supports timelines, window details, corrections, and rule
  reapplication. Older history supports totals and trends only.
- Freeze work classification when summarizing. Later WiFi-setting changes do
  not recalculate finalized history.
- Combine summaries and raw events using non-overlapping coverage boundaries.
- Update dimension deletion guards to preserve projects/activities referenced
  by historical summaries.
- Run maintenance daily in bounded transactions and catch up after downtime.
- Persist the completed retention cutoff and define how late events interact
  with finalized days. Outbox expiry and retention must have compatible horizons.
- Expire summaries, operational history, logs, and backups under explicit
  policies; do not accidentally retain raw details in another store.
- Schedule checkpoints and measure physical file size separately from row
  deletion. Do not assume `VACUUM` reclaims DuckDB storage.
- Provide a retention preview showing affected dates, counts, and lost detail
  before first enabling deletion on existing data.

## Implementation checklist

### 1. Baseline and behavioral contracts

- [ ] Measure main-thread callback time, AX query time, WiFi lookup time,
      database open/count/close time, and menu opening latency.
- [ ] Record idle CPU, memory, wakeups, database size, and event freshness.
- [ ] Define capture interval, pause/sleep, counting, and timestamp semantics.
- [ ] Finalize outbox limits, durability target, reporting timezone, and retention
      defaults before enabling destructive maintenance.
- [ ] Define protocol validation, sequencing, acknowledgements, and recovery.

### 2. Reliable ingestion and exclusive database ownership

- [x] Write failing tests for committed acknowledgement, duplicate replay,
      sequence handling, and transaction failures.
- [x] Add backend ingestion use cases and persistence ports.
- [x] Implement transactional event insertion and durable producer cursors.
- [x] Add and test the bounded v1 ingestion handler (socket binding pending).
- [ ] Add versioned local IPC with bounded requests and useful errors.
- [ ] Implement and test durable client outbox recovery and delivery retries.
- [ ] Replace worker DuckDB writes and menu queries with delivery/status IPC.
- [ ] Route CLI database operations through the backend.
- [ ] Make backend startup the sole migration owner; remove competing opens and
      ineffective database coordination attempts.
- [ ] Configure both per-user services and independent restart behavior.
- [ ] Verify collection continues while the backend is unavailable and catches
      up without duplicated time after it returns.

### 3. Responsive native client and correct capture

- [ ] Write behavioral tests for long unchanged windows and pause/lock/sleep.
- [ ] Separate capture, persistence/delivery, and AppKit state ownership.
- [ ] Move blocking AX/WiFi work off main, with timeouts and stale-result handling.
- [ ] Remove storage-related lock dependencies from the callback path.
- [ ] Persist active intervals periodically without overlap or duration inflation.
- [ ] Publish immutable cached menu snapshots and refresh backend status
      asynchronously.
- [ ] Add visible pending-sync, stale-state, permission, and recording-error states.
- [ ] Implement graceful shutdown while retaining crash-safe recovery.
- [ ] Measure responsiveness and resource use against the baseline.

### 4. Historical summaries and retention

- [ ] Write tests for aggregation, mixed raw/summary reports, boundary dates,
      daylight-saving transitions, and frozen work classification.
- [ ] Add summary schema, coverage metadata, and configuration.
- [ ] Adapt reports to query summaries plus recent detail without double counting.
- [ ] Clearly indicate when timeline/detail/reclassification is no longer available.
- [ ] Update project/activity deletion guards for historical references.
- [ ] Implement transactional summarize-and-delete with bounded daily work.
- [ ] Test retries, crashes, late delivery, and summary expiration.
- [ ] Add retention preview, maintenance status, log rotation, and checkpoint policy.
- [ ] Verify logical retention and physical disk behavior on representative data.

### 5. Cutover and final validation

- [ ] Back up the database with existing owners stopped before migration.
- [ ] Ensure the old collector cannot restart and reopen the database after cutover.
- [ ] Validate installed worker/backend versions and upgrade behavior; the current
      installer can preserve an existing worker binary.
- [ ] Compare report totals before and after migration on a database copy.
- [ ] Document rollback with both services stopped and a consistent backup.
- [ ] Run focused tests, relevant formatting/lint, then project-wide checks.
- [ ] Review the final diff for unrelated changes and confirm the design remains
      proportionate to a personal-use application.

## Acceptance criteria

- Delaying AX, WiFi, storage, or backend responses by several seconds does not
  make opening the native menu wait for those operations. Target menu opening
  under 100 ms on the development machine, verified by measurement.
- Backend and client restarts, failed commits, and lost acknowledgements do not
  duplicate time or lose acknowledged records.
- Long unchanged windows are persisted within the chosen durability interval.
- Pause, lock, and sleep do not extend active time; resume starts a valid interval.
- Ingestion, reporting, edits, and CLI operations coexist without competing
  process ownership of DuckDB.
- Outbox and memory use stay bounded during extended backend outages, with a
  visible error if recording cannot continue.
- Retention is retry-safe, preserves historical totals, handles timezone
  boundaries, and makes the loss of old detail explicit.
- Idle CPU, memory, and wakeups are measured against baseline and regressions
  are explained before release.

Use Chicago-style TDD for behavioral changes, real objects and temporary databases
where practical, and boundary fakes only for clocks, macOS services, and transport
failure injection. Use file-backed databases for crash/durability tests; in-memory
database tests alone cannot establish persistence guarantees.

## References

- [DuckDB concurrency](https://duckdb.org/docs/stable/connect/concurrency.html)
- [DuckDB space reclamation](https://duckdb.org/docs/current/operations_manual/footprint_of_duckdb/reclaiming_space)
