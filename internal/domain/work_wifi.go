package domain

import (
	"path/filepath"
	"strings"
)

func IsWorkWifi(ssid string, patterns []string) bool {
	ssid = strings.ToLower(strings.TrimSpace(ssid))
	if ssid == "" {
		return false
	}
	for _, pattern := range patterns {
		pattern = strings.ToLower(strings.TrimSpace(pattern))
		if pattern == "" {
			continue
		}
		matched, err := filepath.Match(pattern, ssid)
		if err == nil && matched {
			return true
		}
	}
	return false
}
