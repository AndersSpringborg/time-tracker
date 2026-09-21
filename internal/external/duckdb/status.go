package duckdb

import "context"

// UnmappedEventCount counts the events still waiting for review, using the
// same definition as ListUnmappedEvents so the menubar badge and the review
// list cannot disagree.
func (s *Store) UnmappedEventCount(ctx context.Context) (int64, error) {
	const query = `
SELECT COUNT(*)
FROM events
WHERE project_activity_id IS NULL
  AND project_id IS NULL
  AND activity_id IS NULL
  AND manually_mapped = false
`
	var count int64
	if err := s.db.QueryRowContext(ctx, query).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
}
