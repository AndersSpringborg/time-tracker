package migrations

import "testing"

func TestLoadReturnsSortedMigrations(t *testing.T) {
	migs, err := Load()
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}
	if len(migs) < 12 {
		t.Fatalf("expected at least 12 migrations, got %d", len(migs))
	}

	if migs[0].Version != 1 {
		t.Fatalf("expected first version 1, got %d", migs[0].Version)
	}
	if migs[len(migs)-1].Version != 12 {
		t.Fatalf("expected last version 12, got %d", migs[len(migs)-1].Version)
	}
}

func TestLoadHasNonEmptySQL(t *testing.T) {
	migs, err := Load()
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}
	for _, m := range migs {
		if m.Name == "" {
			t.Fatalf("migration %d has empty name", m.Version)
		}
		if m.SQL == "" {
			t.Fatalf("migration %d has empty sql", m.Version)
		}
	}
}
