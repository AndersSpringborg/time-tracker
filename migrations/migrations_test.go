package migrations

import "testing"

func TestLoadReturnsSortedMigrations(t *testing.T) {
	migs, err := Load()
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}
	if len(migs) < 19 {
		t.Fatalf("expected at least 19 migrations, got %d", len(migs))
	}

	// Assert the property rather than today's highest version, which every new
	// migration would otherwise break: versions run from 1 upwards, in order.
	for i, m := range migs {
		if m.Version != i+1 {
			t.Fatalf("migration %d is version %d; versions must be sorted and contiguous from 1", i, m.Version)
		}
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
