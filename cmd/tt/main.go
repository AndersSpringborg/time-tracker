package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/external/api"
	"time-tracker/internal/external/cli"
	"time-tracker/internal/external/configfs"
	"time-tracker/internal/external/duckdb"
	"time-tracker/internal/external/launchd"
	"time-tracker/internal/external/tidsreg"
	"time-tracker/internal/external/workerembed"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	ctx := context.Background()
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
			return runServer(addr, serverApp)
		},
		DBPath:          dbPath,
		ConfigPath:      cfgPath,
		WorkerPath:      workerPath,
		LaunchAgentPath: launchPath,
	}

	return runner.Run(ctx, args, stdout, stderr)
}

func buildLocalApp() *usecases.App {
	return &usecases.App{
		Settings:  usecases.NewSettingsUsecase(configfs.New()),
		Lifecycle: usecases.NewLifecycleUsecase(launchd.New()),
		Help:      usecases.NewHelpUsecase(),
	}
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
	app.Reports = usecases.NewReportsUsecase(store, store, configfs.New())
	app.Tidsreg = usecases.NewTidsregImportUsecase(tidsreg.New(), store)
	return app, store, nil
}

func runServer(addr string, app *usecases.App) error {
	srv, err := api.New(app)
	if err != nil {
		return err
	}
	log.Printf("api serve addr=%s", addr)
	err = http.ListenAndServe(addr, srv.Routes())
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
