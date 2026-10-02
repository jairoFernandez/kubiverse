package main

import (
	"testing"
	"time"
)

// 0 means "unknown" in Cert.ExpiresIn, so a known expiry never is 0.
func TestExpiresInNeverUnknownWhenKnown(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cases := []struct {
		at   time.Time
		want int64
	}{
		{now.Add(90 * time.Second), 90},
		{now.Add(-90 * time.Second), -90},
		{now, -1},
		{now.Add(400 * time.Millisecond), -1},
		{now.Add(-400 * time.Millisecond), -1},
	}
	for _, c := range cases {
		if got := expiresIn(c.at, now); got != c.want {
			t.Errorf("expiresIn(now%+v) = %d, want %d", c.at.Sub(now), got, c.want)
		}
	}
}
