package architecture

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

func TestDomainDoesNotDependOnApplicationOrExternal(t *testing.T) {
	files, err := filepath.Glob("../domain/*.go")
	if err != nil {
		t.Fatalf("glob domain files: %v", err)
	}
	for _, file := range files {
		checkFileImports(t, file, []string{"time-tracker/internal/application", "time-tracker/internal/external"})
	}
}

func TestApplicationDoesNotDependOnExternal(t *testing.T) {
	patterns := []string{"../application/ports/*.go", "../application/usecases/*.go"}
	for _, p := range patterns {
		files, err := filepath.Glob(p)
		if err != nil {
			t.Fatalf("glob application files: %v", err)
		}
		for _, file := range files {
			checkFileImports(t, file, []string{"time-tracker/internal/external"})
		}
	}
}

func checkFileImports(t *testing.T, file string, forbiddenPrefixes []string) {
	t.Helper()
	fset := token.NewFileSet()
	node, err := parser.ParseFile(fset, file, nil, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("parse %s: %v", file, err)
	}
	for _, imp := range node.Imports {
		path := strings.Trim(imp.Path.Value, "\"")
		for _, prefix := range forbiddenPrefixes {
			if strings.HasPrefix(path, prefix) {
				t.Fatalf("forbidden import %q in %s", path, file)
			}
		}
	}
	_ = ast.File{}
}
