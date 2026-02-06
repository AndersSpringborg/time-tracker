package worker

import _ "embed"

// Replace this placeholder with a real worker binary via `make sync-worker` before release.
//
//go:embed assets/tt-worker
var EmbeddedBinary []byte
