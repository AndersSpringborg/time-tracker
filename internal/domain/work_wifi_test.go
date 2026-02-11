package domain

import "testing"

func TestIsWorkWifi(t *testing.T) {
	tests := []struct {
		name     string
		ssid     string
		patterns []string
		want     bool
	}{
		{
			name:     "matches exact case insensitive",
			ssid:     "OfficeNet",
			patterns: []string{"officenet"},
			want:     true,
		},
		{
			name:     "matches wildcard",
			ssid:     "Trifork-Guest",
			patterns: []string{"Trifork*"},
			want:     true,
		},
		{
			name:     "does not match empty ssid",
			ssid:     "",
			patterns: []string{"Office*"},
			want:     false,
		},
		{
			name:     "matches all when no patterns configured",
			ssid:     "Office",
			patterns: nil,
			want:     true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := IsWorkWifi(tc.ssid, tc.patterns)
			if got != tc.want {
				t.Fatalf("IsWorkWifi(%q, %v)=%v, want %v", tc.ssid, tc.patterns, got, tc.want)
			}
		})
	}
}
