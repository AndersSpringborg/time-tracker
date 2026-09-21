package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/external/api"
	"time-tracker/internal/external/cli"
	"time-tracker/internal/external/configfs"
	"time-tracker/internal/external/duckdb"
	"time-tracker/internal/external/launchd"
	"time-tracker/internal/external/localipc"
	"time-tracker/internal/external/tidsreg"
	"time-tracker/internal/external/workerembed"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	// Stopping the service must close the database and remove the IPC socket,
	// so shutdown runs through a cancelled context instead of an abrupt exit.
	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	app := buildLocalApp()
	if len(args) > 0 {
		switch args[0] {
		case "rules", "projects", "reports", "report", "summary", "review":
			var store *duckdb.Store
			var err error
			app, store, err = buildApp()
			if err != nil {
				fmt.Fprintf(stderr, "error: %v\n", err)
				return 1
			}
			defer store.Close()
		case "maintenance":
			// Retention reads and rewrites rows, so it needs an open database.
			// Status and compaction act on the file itself and must not hold
			// it open — compaction needs the file to itself.
			if len(args) > 1 && strings.HasPrefix(args[1], "retention") {
				var store *duckdb.Store
				var err error
				app, store, err = buildApp()
				if err != nil {
					fmt.Fprintf(stderr, "error: %v\n", err)
					return 1
				}
				defer store.Close()
			}
		}
	}

	dbPath, _ := configfs.DBPath()
	cfgPath, _ := configfs.ConfigPath()
	workerPath, _ := workerembed.WorkerPath()
	launchPath, _ := workerembed.LaunchAgentPath()

	runner := &cli.Runner{
		App: app,
		Serve: func(addr string) error {
			serverApp, store, err := buildApp()
			if err != nil {
				return err
			}
			defer store.Close()
			return runServer(ctx, addr, serverApp, store)
		},
		DBPath:          dbPath,
		ConfigPath:      cfgPath,
		WorkerPath:      workerPath,
		LaunchAgentPath: launchPath,
	}

	return runner.Run(ctx, args, stdout, stderr)
}

func buildLocalApp() *usecases.App {
	app := &usecases.App{
		Settings:  usecases.NewSettingsUsecase(configfs.New()),
		Lifecycle: usecases.NewLifecycleUsecase(launchd.NewAgents()),
		Help:      usecases.NewHelpUsecase(),
	}
	// Maintenance owns the database file rather than a connection, so it must
	// not open DuckDB here: compaction needs the file to itself.
	if dbPath, err := configfs.DBPath(); err == nil {
		app.Maintenance = usecases.NewMaintenanceUsecase(duckdb.NewMaintainer(dbPath))
	}
	return app
}

func buildApp() (*usecases.App, *duckdb.Store, error) {
	dbPath, err := configfs.DBPath()
	if err != nil {
		return nil, nil, err
	}
	store, err := duckdb.Open(dbPath)
	if err != nil {
		return nil, nil, err
	}

	app := buildLocalApp()
	app.Rules = usecases.NewRulesUsecase(store)
	app.Projects = usecases.NewProjectsUsecase(store)
	app.Review = usecases.NewReviewUsecase(store)
	app.Reports = usecases.NewReportsUsecase(store, store, configfs.New()).WithSummaries(store)
	app.Tidsreg = usecases.NewTidsregImportUsecase(tidsreg.New(), store)
	app.Retention = usecases.NewRetentionUsecase(store)
	return app, store, nil
}

// runServer serves the browser UI on loopback and the private collector IPC on
// a user-restricted socket from the single process that owns the database.
func runServer(ctx context.Context, addr string, app *usecases.App, store *duckdb.Store) error {
	srv, err := api.New(app)
	if err != nil {
		return err
	}
	socketPath, err := configfs.SocketPath()
	if err != nil {
		return err
	}
	go watchRetention(ctx, app)

	ipcCtx, stopIPC := context.WithCancel(ctx)
	defer stopIPC()
	ipcDone := make(chan error, 1)
	go func() {
		handler := localipc.NewHandler(
			usecases.NewIngestionUsecase(store),
			usecases.NewStatusUsecase(store),
		)
		ipcDone <- localipc.Serve(ipcCtx, socketPath, handler)
	}()

	log.Printf("api serve addr=%s ipc=%s", addr, socketPath)
	browser := &http.Server{Addr: addr, Handler: srv.Routes()}
	httpDone := make(chan error, 1)
	go func() {
		httpErr := browser.ListenAndServe()
		if errors.Is(httpErr, http.ErrServerClosed) {
			httpErr = nil
		}
		httpDone <- httpErr
	}()

	// Losing either endpoint stops the service: a socket owned by another
	// process means something else is already serving this user's database.
	select {
	case err = <-httpDone:
		stopIPC()
		<-ipcDone
	case err = <-ipcDone:
		shutdownBrowser(browser)
		<-httpDone
	case <-ctx.Done():
		shutdownBrowser(browser)
		<-httpDone
		stopIPC()
		err = <-ipcDone
	}
	return err
}

func shutdownBrowser(browser *http.Server) {
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := browser.Shutdown(shutdownCtx); err != nil {
		log.Printf("browser shutdown: %v", err)
	}
}

// watchRetention reports when stored detail passes the retention cap. It never
// deletes on its own: summarisation is an explicit `tt maintenance
// retention-run --yes`, so history is never lost unattended.
func watchRetention(ctx context.Context, app *usecases.App) {
	if app.Retention == nil {
		return
	}
	ticker := time.NewTicker(24 * time.Hour)
	defer ticker.Stop()
	for {
		plan, err := app.Retention.Plan(ctx)
		switch {
		case err != nil:
			log.Printf("retention check failed: %v", err)
		case len(plan.Days) > 0:
			log.Printf("retention: %d bytes of detail exceeds the %d byte cap; %d day(s) eligible for `tt maintenance retention-run`",
				plan.DataBytes, plan.CapBytes, len(plan.Days))
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
