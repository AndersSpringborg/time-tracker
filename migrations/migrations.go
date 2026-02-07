package migrations

import (
	"embed"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
)

//go:embed sql/*.sql
var sqlFiles embed.FS

type FileMigration struct {
	Version int
	Name    string
	SQL     string
}

func Load() ([]FileMigration, error) {
	entries, err := fs.ReadDir(sqlFiles, "sql")
	if err != nil {
		return nil, fmt.Errorf("read migrations dir: %w", err)
	}

	out := make([]FileMigration, 0, len(entries))
	seen := map[int]struct{}{}

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".sql") {
			continue
		}
		if len(name) < 8 || name[3] != '_' {
			return nil, fmt.Errorf("invalid migration filename: %s", name)
		}

		version, err := strconv.Atoi(name[:3])
		if err != nil {
			return nil, fmt.Errorf("invalid migration version %q: %w", name[:3], err)
		}
		if _, ok := seen[version]; ok {
			return nil, fmt.Errorf("duplicate migration version: %03d", version)
		}
		seen[version] = struct{}{}

		content, err := fs.ReadFile(sqlFiles, "sql/"+name)
		if err != nil {
			return nil, fmt.Errorf("read migration %s: %w", name, err)
		}

		baseName := strings.TrimSuffix(name[4:], ".sql")
		out = append(out, FileMigration{
			Version: version,
			Name:    baseName,
			SQL:     string(content),
		})
	}

	sort.Slice(out, func(i, j int) bool {
		return out[i].Version < out[j].Version
	})

	return out, nil
}
