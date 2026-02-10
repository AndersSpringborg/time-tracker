package domain

import (
	"fmt"
	"time"
)

func FormatDuration(ms int64) string {
	sec := ms / 1000
	h := sec / 3600
	m := (sec % 3600) / 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}

// FormatTimestamp converts a Unix millisecond timestamp to "15:04" format
func FormatTimestamp(ms int64) string {
	t := time.UnixMilli(ms)
	return t.Format("15:04")
}
