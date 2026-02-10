# Web UI Agent Guide

HTMX + Go templates + Tailwind CSS web application.

## Stack

- **Go**: `server.go` handlers, `chi` router
- **HTMX**: Partial updates via `hx-get/post/target/swap`
- **Tailwind**: CDN loaded in `templates/layout.html`
- **Templates**: `html/template` with partials in `templates/partials/`

## File Structure

```
templates/
├── layout.html          # Base layout, nav, Tailwind CDN
├── *.html               # Full pages (extend layout)
└── partials/*.html      # HTMX fragments (no layout)
```

## Patterns

**Page handler**: Render full template with layout
```go
s.render(w, r, "reports.html", pageData{...})
```

**HTMX partial**: Render fragment only
```go
s.render(w, r, "partials/report_table.html", data)
```

**HTMX attributes**: `hx-get`, `hx-post`, `hx-target`, `hx-swap`, `hx-trigger`, `hx-indicator`

## Tailwind Classes

- **Buttons primary**: `bg-tt-accent text-white px-3 py-1.5 rounded-lg`
- **Buttons secondary**: `border border-slate-300 bg-white px-3 py-1.5 rounded-lg`
- **Cards**: `rounded-2xl border border-slate-200 bg-white p-5 shadow-sm`
- **Tables**: `divide-y divide-slate-100` on tbody
- **Custom colors**: `tt-ink`, `tt-accent`, `tt-warm`

## Testing

```bash
go test ./internal/external/api/... -count=1
```

Tests use `httptest` and check response bodies for expected text.
