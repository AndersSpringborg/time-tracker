package domain

import (
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func BuildNoiseMask(events []Event, patterns []string, bucketMinutes, switchMinutes int64) []bool {
	mask := make([]bool, len(events))
	if len(events) == 0 {
		return mask
	}
	if bucketMinutes <= 0 || switchMinutes <= 0 {
		for i, e := range events {
			mask[i] = IsNoiseApp(e.AppName, patterns)
		}
		return mask
	}

	// keep deterministic even if caller does not pre-sort
	sorted := make([]Event, len(events))
	copy(sorted, events)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].TimestampMS < sorted[j].TimestampMS })

	minTs := sorted[0].TimestampMS
	maxTs := sorted[0].TimestampMS
	for _, e := range sorted {
		if e.TimestampMS < minTs {
			minTs = e.TimestampMS
		}
		end := e.TimestampMS + e.DurationMS
		if end > maxTs {
			maxTs = end
		}
	}
	if maxTs <= minTs {
		for i, e := range events {
			mask[i] = IsNoiseApp(e.AppName, patterns)
		}
		return mask
	}

	bucketMS := bucketMinutes * int64(time.Minute/time.Millisecond)
	switchMS := switchMinutes * int64(time.Minute/time.Millisecond)
	type bucket struct {
		start   int64
		end     int64
		noiseMS int64
		normMS  int64
		state   bool
	}
	buckets := []bucket{}
	for start := minTs; start < maxTs; start += bucketMS {
		buckets = append(buckets, bucket{start: start, end: start + bucketMS})
	}
	for _, e := range sorted {
		if e.DurationMS <= 0 {
			continue
		}
		eventStart := e.TimestampMS
		eventEnd := e.TimestampMS + e.DurationMS
		noise := IsNoiseApp(e.AppName, patterns)
		for i := range buckets {
			overlap := overlapMS(eventStart, eventEnd, buckets[i].start, buckets[i].end)
			if overlap <= 0 {
				continue
			}
			if noise {
				buckets[i].noiseMS += overlap
			} else {
				buckets[i].normMS += overlap
			}
		}
	}

	for i := range buckets {
		buckets[i].state = buckets[i].noiseMS >= buckets[i].normMS
	}

	stableState := buckets[0].state
	pendingState := stableState
	pendingMS := int64(0)
	for i := range buckets {
		if buckets[i].state == stableState {
			pendingState = stableState
			pendingMS = 0
		} else {
			if buckets[i].state != pendingState {
				pendingState = buckets[i].state
				pendingMS = bucketMS
			} else {
				pendingMS += bucketMS
			}
			if pendingMS >= switchMS {
				stableState = pendingState
				pendingMS = 0
			}
		}
		buckets[i].state = stableState
	}

	for i, e := range events {
		if e.DurationMS <= 0 {
			mask[i] = IsNoiseApp(e.AppName, patterns)
			continue
		}
		mid := e.TimestampMS + e.DurationMS/2
		idx := int((mid - minTs) / bucketMS)
		if idx < 0 || idx >= len(buckets) {
			mask[i] = IsNoiseApp(e.AppName, patterns)
			continue
		}
		mask[i] = buckets[idx].state
	}
	return mask
}

func IsNoiseApp(app string, patterns []string) bool {
	app = strings.TrimSpace(app)
	if app == "" {
		return false
	}
	for _, p := range patterns {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		ok, err := filepath.Match(p, app)
		if err == nil && ok {
			return true
		}
	}
	return false
}

func overlapMS(startA, endA, startB, endB int64) int64 {
	start := max(startA, startB)
	end := min(endA, endB)
	if end <= start {
		return 0
	}
	return end - start
}

func min(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func max(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
