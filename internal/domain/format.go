package domain

import "fmt"

func FormatDuration(ms int64) string {
	sec := ms / 1000
	h := sec / 3600
	m := (sec % 3600) / 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}
