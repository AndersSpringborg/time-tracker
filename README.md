# Time Tracker (Go Clean Architecture + Zig Worker)

A local-first time tracker with:

- `tracker` (Go): manager CLI + HTMX web UI
- `tt-worker` (Zig): macOS collector daemon
- DuckDB: local storage at `~/.local/share/time-tracker/tracker.db`

## Clean Architecture (Go)

- `internal/domain`: pure business rules and models
- `internal/application`: usecases + ports (interfaces)
- `internal/external`: adapters
  - `api` (HTMX web)
  - `cli` (Go CLI)
  - `duckdb`, `launchd`, `configfs`, `workerembed`

Both CLI and API call the same `application` usecases.

## Build

```bash
make build
```

This does:

1. `zig build`
2. `make sync-worker` (embed worker binary)
3. `go build -mod=mod -o tracker ./cmd/tt`

## Install CLI Binary

```bash
make install
```

This builds the project and installs `tracker` to `~/.local/bin/tracker`.

## Test (TDD workflow)

```bash
make test
```

Includes:

- Zig unit and DuckDB adapter tests (`zig build test`)
- domain tests
- usecase tests
- duckdb integration tests
- API route tests
- CLI LLM-help tests
- clean-architecture boundary tests
- race detection and shuffled Go package order (`go test -race -shuffle=on -count=1`)

Fast local loop:

```bash
make test-fast
```

## CLI Commands

```bash
./tracker help
./tracker help --format json
./tracker schema rules

./tracker install
./tracker status
./tracker serve --addr 127.0.0.1:8080
./tracker start
./tracker stop
./tracker uninstall

./tracker rules list
./tracker rules suggest --format json
./tracker rules auto-apply --min-confidence 90 --apply-now
./tracker rules apply-rules --dry-run

./tracker review dates
./tracker review groups --date 2026-02-06 --format json
```

## UI

Run:

```bash
./tracker serve
```

Open `http://127.0.0.1:8080`.

Pages:

- Dashboard
- Reports
- Timeline
- Rules
- Suggestions (auto-categorization)
- Projects
- Settings

## Notes

- For distribution, run `make sync-worker` before final `go build`.
- During development, `install` falls back to `zig-out/bin/tt` if embedded worker is placeholder.
- If macOS blocks downloaded binaries:

```bash
xattr -d com.apple.quarantine ./tracker
```
