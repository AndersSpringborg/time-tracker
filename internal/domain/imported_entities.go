package domain

type ImportedProjectUpsert struct {
	Source             string
	ExternalCustomerID int64
	ExternalProjectID  int64
	ExternalVariantKey string
	Title              string
	Metadata           string
}

type ImportedProjectUpsertResult struct {
	ProjectID int64
	Created   bool
	Updated   bool
}

type ImportedActivityUpsert struct {
	Source             string
	ExternalActivityID int64
	Title              string
}

type ImportedActivitySyncResult struct {
	Created int
	Updated int
	Deleted int
}
