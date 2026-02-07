package worker

import "embed"

// EmbeddedBinary is populated when assets/tt-worker exists.
// In source checkouts, only assets/.keep may be present and this stays empty.
//
//go:embed assets/*
var embeddedAssets embed.FS

var EmbeddedBinary []byte

func init() {
	b, err := embeddedAssets.ReadFile("assets/tt-worker")
	if err == nil {
		EmbeddedBinary = b
		return
	}
	EmbeddedBinary = nil
}
