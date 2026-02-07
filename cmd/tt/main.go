package main

import (
	"context"
	"errors"
	"fmt"
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
	ctx := context.Background()
	app, store, err := buildApp()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	defer store.Close()

	dbPath, _ := configfs.DBPath()
	cfgPath, _ := configfs.ConfigPath()
	workerPath, _ := workerembed.WorkerPath()
	launchPath, _ := workerembed.LaunchAgentPath()

	runner := &cli.Runner{
		App:             app,
		Serve:           func(addr string) error { return runServer(addr, app) },
		DBPath:          dbPath,
		ConfigPath:      cfgPath,
		WorkerPath:      workerPath,
		LaunchAgentPath: launchPath,
	}

	code := runner.Run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	os.Exit(code)
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

	settingsRepo := configfs.New()
	lifecycle := launchd.New()

	app := &usecases.App{
		Rules:     usecases.NewRulesUsecase(store),
		Projects:  usecases.NewProjectsUsecase(store),
		Settings:  usecases.NewSettingsUsecase(settingsRepo),
		Lifecycle: usecases.NewLifecycleUsecase(lifecycle),
		Review:    usecases.NewReviewUsecase(store),
		Reports:   usecases.NewReportsUsecase(store, store, settingsRepo),
		Help:      usecases.NewHelpUsecase(),
		Tidsreg:   usecases.NewTidsregImportUsecase(tidsreg.New(), store),
	}
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
