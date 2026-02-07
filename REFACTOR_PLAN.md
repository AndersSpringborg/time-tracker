# Refactor Plan: FlatBuffers DTO Contract + Shared SQL Migrations

## 1. Purpose

Refactor the Zig worker and Go manager integration so event structure drift cannot happen silently.

This plan introduces:

1. A shared FlatBuffers DTO contract for event payload shape.
2. A shared SQL migrations folder consumed by both Zig and Go.
3. Strict boundary mapping so FlatBuffers does not leak into domain logic.

## 2. Goals

1. Keep Zig and Go event structure synchronized by contract.
2. Use FlatBuffers only as DTO at boundaries (not in domain entities/usecases).
3. Remove duplicated migration SQL definitions and read from one shared folder.
4. Preserve existing app behavior and current DB compatibility.
5. Add tests that fail immediately on schema drift.

## 3. Non-Goals

1. No domain rewrite.
2. No replacement of all HTTP/CLI responses with FlatBuffers in this phase.
3. No destructive migration rewrite of existing tables.

## 4. Final Architecture

### 4.1 Contract Layers

1. `contracts/event.fbs` defines canonical event DTO structure.
2. Generated DTO code exists in Zig external layer and Go external layer only.
3. Domain keeps native structs with no FlatBuffers imports.
4. Explicit mapper functions convert:
   - DTO -> domain event
   - domain event -> DTO

### 4.2 Migration Layers

1. SQL files live in `migrations/sql/*.sql`.
2. Both Zig and Go migration runners read and apply the same files.
3. `schema_migrations` remains the applied-state ledger.

## 5. Repository Changes

## 5.1 Add shared contract

1. Create `contracts/event.fbs`.
2. Include DTO fields required by both stacks:
   - `timestamp_ms: long`
   - `app_name: string`
   - `window_title: string`
   - `wifi_ssid: string`
   - `duration_ms: long`
   - `activity_id: long`
   - `has_activity_id: bool`
   - `kind_id: long`
   - `has_kind_id: bool`
   - `manually_mapped: bool`

### 5.2 Add DTO generated code targets

1. Zig generated target path:
   - `src/external/dto/flatbuffers/event_generated.zig`
2. Go generated target path:
   - `internal/external/dto/flatbuffers/event_generated.go`

### 5.3 Add DTO mapping adapters (handwritten)

1. Zig mappers:
   - `src/external/dto/event_mapper.zig`
2. Go mappers:
   - `internal/external/dto/event_mapper.go`

Mapper package responsibilities:

1. Decode validation (required fields, defaults).
2. Conversion to/from domain event model.
3. Handling nullable `activity_id`/`kind_id` via presence flags.

### 5.4 Introduce shared migrations folder

1. Create:
   - `migrations/sql/001_create_events_table.sql`
   - `migrations/sql/002_add_wifi_ssid.sql`
   - ...
   - `migrations/sql/009_add_follow_previous_rules.sql`
2. Keep SQL content equivalent to current effective migrations.
3. Migration version derives from numeric filename prefix.

### 5.5 Refactor migration runners

1. Zig `src/external/duckdb/migrations.zig`:
   - Remove hardcoded migration array.
   - Load SQL files from `migrations/sql/`.
   - Apply in sorted version order.
2. Go `internal/external/duckdb/migrations.go`:
   - Remove hardcoded migration slice.
   - Load SQL files from `migrations/sql/`.
   - Apply in sorted version order.

## 6. Dependency + Build Integration

### 6.1 Zig dependency

1. Add dependency exactly as requested:
   - `zig fetch --save git+https://github.com/travisstaloch/flatbufferz`
2. Wire dependency only in DTO/external modules in `build.zig`.
3. Do not import FlatBuffers in domain/application core modules.

### 6.2 Go dependency

1. Use `github.com/google/flatbuffers` in external DTO package only.
2. Keep domain and usecases independent of this dependency.

### 6.3 Code generation workflow

Add Make targets:

1. `make gen-dto`
   - Generate Zig + Go code from `contracts/event.fbs`.
2. `make verify-dto`
   - Fails if generated artifacts differ from checked-in files.
3. `make verify-migrations`
   - Validates migration filenames and monotonic versions.

## 7. TDD Implementation Sequence

## 7.1 Step A: Migration loader tests first

Write failing tests before implementation in Zig and Go:

1. Loads SQL files in numeric order.
2. Applies unapplied versions only.
3. Correctly records applied versions in `schema_migrations`.
4. Handles empty folder and malformed filenames with clear errors.

Then implement loader + applier in each runtime.

## 7.2 Step B: DTO mapper tests first

Write failing tests:

1. DTO encode/decode roundtrip preserves all event fields.
2. Optional IDs obey `has_*` flags.
3. Invalid payload returns explicit parse/validation error.
4. Domain mapping remains unchanged semantically.

Then implement mapper code in external layers.

## 7.3 Step C: Cross-language compatibility tests

Write failing tests:

1. Bytes encoded in Zig decode correctly in Go.
2. Bytes encoded in Go decode correctly in Zig.
3. Shared fixture payloads remain stable.

Then implement any normalization needed for exact parity.

## 7.4 Step D: Integration tests

1. Zig worker write path still persists valid rows.
2. Go store/read/report paths continue to function.
3. Rule/application logic unaffected by DTO transport layer.

## 8. Rollout Plan

## 8.1 Phase 1: Introduce contracts/migrations in parallel

1. Add shared migration folder.
2. Update loaders to use folder.
3. Keep behavior equivalent.

### 8.2 Phase 2: Introduce DTO boundary code

1. Add FlatBuffers schema + generated code + mappers.
2. Route worker ingest boundary through DTO mapper.
3. Keep domain APIs unchanged.

### 8.3 Phase 3: Enforce drift guards

1. Enable `verify-dto` and `verify-migrations` in CI.
2. Add cross-language contract tests to CI.

## 9. Validation Checklist

1. `zig build` passes.
2. `zig build test` passes.
3. `go test -mod=mod ./...` passes.
4. `make gen-dto` generates no unexpected diffs after commit.
5. `make verify-dto` passes.
6. `make verify-migrations` passes.
7. Zig and Go both migrate the same DB to same final version.

## 10. Commit Strategy (Conventional Commits)

1. `feat: add shared flatbuffers event dto contract`
2. `chore: add shared sql migration files`
3. `refactor: load migrations from shared folder in zig`
4. `refactor: load migrations from shared folder in go`
5. `feat: add zig dto mapper and boundary integration`
6. `feat: add go dto mapper and boundary integration`
7. `test: add cross-language dto compatibility tests`
8. `chore: add dto and migration verification targets`

Each commit should keep tests green.

## 11. Acceptance Criteria

1. FlatBuffers schema exists and is authoritative for event DTO shape.
2. No FlatBuffers imports in domain packages (Zig or Go).
3. Both runtimes consume migrations from `migrations/sql/` only.
4. Cross-language DTO tests pass.
5. Existing functionality remains intact.
6. Drift is caught by tests/CI before merge.

## 12. Risks + Mitigations

1. Risk: Optional ID semantics diverge.
   - Mitigation: Presence-flag tests + fixture parity tests.
2. Risk: Runtime path assumptions for migration folder differ.
   - Mitigation: Centralized path resolution helper + startup diagnostics.
3. Risk: Generated code drift from local tooling versions.
   - Mitigation: Pinned generation commands + `verify-dto`.
4. Risk: Existing DB edge-cases in old installs.
   - Mitigation: Integration tests against migrated real DB snapshots.

## 13. Done Definition

The refactor is complete when:

1. Shared migration SQL folder is the single source of truth.
2. FlatBuffers DTO contract is generated and used at boundaries.
3. Domain remains clean and FlatBuffers-free.
4. All build/test/verification gates pass locally and in CI.
