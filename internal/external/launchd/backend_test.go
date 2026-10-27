package launchd

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestBackendAndWorkerAreSeparateAgents(t *testing.T) {
	worker := New()
	backend := NewBackend()

	if worker.label == backend.label {
		t.Fatalf("both services would target the same launchd label %q", worker.label)
	}
	if backend.label != "com.time-tracker.backend" {
		t.Fatalf("unexpected backend label %q", backend.label)
	}
}

func TestBackendServiceTargetsItsOwnLabel(t *testing.T) {
	backend := NewBackend()

	target, err := backend.serviceTarget()
	if err != nil {
		t.Fatalf("service target: %v", err)
	}
	if !strings.HasSuffix(target, "/com.time-tracker.backend") {
		t.Fatalf("unexpected target %q", target)
	}
}

func TestBackendPlistRunsServeAndStaysUp(t *testing.T) {
	plist, err := renderBackendPlist("/Users/someone/.local/bin/tracker", "/Users/someone")
	if err != nil {
		t.Fatalf("render: %v", err)
	}

	for _, want := range []string{
		"<string>com.time-tracker.backend</string>",
		"<string>/Users/someone/.local/bin/tracker</string>",
		"<string>serve</string>",
		"<key>RunAtLoad</key><true/>",
		// Ingestion must always be listening, so launchd restarts it.
		"<key>KeepAlive</key><true/>",
		"/tmp/time-tracker-backend.log",
		"/tmp/time-tracker-backend.err.log",
	} {
		if !strings.Contains(plist, want) {
			t.Fatalf("plist is missing %q:\n%s", want, plist)
		}
	}
}

func TestBackendPlistDoesNotRunTheWorkerDaemon(t *testing.T) {
	plist, err := renderBackendPlist("/Users/someone/.local/bin/tracker", "/Users/someone")
	if err != nil {
		t.Fatalf("render: %v", err)
	}

	if strings.Contains(plist, "<string>daemon</string>") {
		t.Fatalf("the backend agent must not start the collector:\n%s", plist)
	}
}

func TestBackendLaunchAgentPathIsItsOwnFile(t *testing.T) {
	backendPath, err := BackendLaunchAgentPath()
	if err != nil {
		t.Fatalf("path: %v", err)
	}
	if filepath.Base(backendPath) != "com.time-tracker.backend.plist" {
		t.Fatalf("unexpected plist path %q", backendPath)
	}
}

func TestAgentPathsDoNotCollide(t *testing.T) {
	workerPlist, err := workerLaunchAgentPathForTest()
	if err != nil {
		t.Fatalf("worker plist path: %v", err)
	}
	backendPlist, err := BackendLaunchAgentPath()
	if err != nil {
		t.Fatalf("backend plist path: %v", err)
	}
	if workerPlist == backendPlist {
		t.Fatalf("both agents would be written to %q", workerPlist)
	}
}
