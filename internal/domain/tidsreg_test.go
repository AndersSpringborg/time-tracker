package domain

import "testing"

func TestBuildProjectTitleNormalizesSegments(t *testing.T) {
	title := BuildProjectTitle(" Trifork ", " Portal\nApp ", " Development ")
	if title != "Trifork > Portal App > Development" {
		t.Fatalf("unexpected title: %s", title)
	}
}

func TestNormalizeTidsregActivitiesRemovesDuplicatesAndInvalid(t *testing.T) {
	activities := NormalizeTidsregActivities([]TidsregActivity{
		{ActivityID: 2, Name: "Meeting"},
		{ActivityID: 1, Name: " Coding "},
		{ActivityID: 1, Name: "Coding duplicate"},
		{ActivityID: 0, Name: "invalid"},
	})
	if len(activities) != 2 {
		t.Fatalf("expected 2 activities, got %d", len(activities))
	}
	if activities[0].ActivityID != 1 {
		t.Fatalf("expected sorted activities")
	}
}

func TestFilterImportCandidates(t *testing.T) {
	preview := TidsregImportPreview{Candidates: []TidsregImportCandidate{{Key: "a"}, {Key: "b"}}}
	filtered := FilterImportCandidates(preview, []string{"b"})
	if len(filtered) != 1 || filtered[0].Key != "b" {
		t.Fatalf("unexpected filtered candidates: %+v", filtered)
	}
}
