package main

import (
	"regexp"
	"strconv"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// Startup is how long a pod took to get going, phase by phase: the game
// draws it as a bar inside the pod (scheduling, init, image + create, app +
// probes) to show where the time went. Times are seconds since the pod was
// created; -1 when that step hasn't happened (or can't be known).
type Startup struct {
	Scheduled    float64 `json:"scheduled"`
	Initialized  float64 `json:"initialized"` // init containers done (= scheduled when there are none)
	Started      float64 `json:"started"`     // the last main container started running
	Ready        float64 `json:"ready"`
	Pull         float64 `json:"pull"`       // seconds pulling images (from Pulled events), -1 unknown
	PullBytes    int64   `json:"pull_bytes"` // size of what was pulled
	Pulled       int     `json:"pulled"`     // images downloaded
	Cached       int     `json:"cached"`     // images already on the node
	Restarted    bool    `json:"restarted"`  // times are from the last start, not the first
	ReadyDelay   int32   `json:"ready_delay"`
	ReadyPeriod  int32   `json:"ready_period"`
	StartupProbe bool    `json:"startup_probe"`
	CPULimitM    int64   `json:"cpu_limit_m"` // smallest CPU limit of the main containers (0 = none)
}

var (
	pulledIn   = regexp.MustCompile(`pulled image "[^"]*" in ((?:[0-9.]+(?:ms|µs|us|ns|h|m|s))+)`)
	pulledSize = regexp.MustCompile(`Image size: (\d+) bytes`)
)

func startupTimeline(p *corev1.Pod, events []corev1.Event) Startup {
	st := Startup{Scheduled: -1, Initialized: -1, Started: -1, Ready: -1, Pull: -1}
	born := p.CreationTimestamp.Time
	since := func(t time.Time) float64 {
		if t.IsZero() || t.Before(born) {
			return 0
		}
		return t.Sub(born).Seconds()
	}
	for _, c := range p.Status.Conditions {
		if c.Status != corev1.ConditionTrue {
			continue
		}
		switch c.Type {
		case corev1.PodScheduled:
			st.Scheduled = since(c.LastTransitionTime.Time)
		case corev1.PodInitialized:
			st.Initialized = since(c.LastTransitionTime.Time)
		case corev1.PodReady:
			st.Ready = since(c.LastTransitionTime.Time)
		}
	}
	running := 0
	var last time.Time
	for _, cs := range p.Status.ContainerStatuses {
		if cs.RestartCount > 0 {
			st.Restarted = true
		}
		if r := cs.State.Running; r != nil {
			running++
			if r.StartedAt.After(last) {
				last = r.StartedAt.Time
			}
		}
	}
	if running > 0 && running == len(p.Spec.Containers) {
		st.Started = since(last)
	}
	for _, c := range p.Spec.Containers {
		if lim := c.Resources.Limits.Cpu().MilliValue(); lim > 0 && (st.CPULimitM == 0 || lim < st.CPULimitM) {
			st.CPULimitM = lim
		}
		if c.StartupProbe != nil {
			st.StartupProbe = true
		}
		if rp := c.ReadinessProbe; rp != nil {
			st.ReadyDelay = max(st.ReadyDelay, rp.InitialDelaySeconds)
			st.ReadyPeriod = max(st.ReadyPeriod, rp.PeriodSeconds)
		}
	}
	for _, e := range events {
		if e.Reason != "Pulled" {
			continue
		}
		if m := pulledIn.FindStringSubmatch(e.Message); m != nil {
			if d, err := time.ParseDuration(m[1]); err == nil {
				st.Pull = max(st.Pull, 0) + d.Seconds()
				st.Pulled++
			}
			if s := pulledSize.FindStringSubmatch(e.Message); s != nil {
				n, _ := strconv.ParseInt(s[1], 10, 64)
				st.PullBytes += n
			}
		} else {
			// "Container image "x" already present on machine"
			st.Cached++
			st.Pull = max(st.Pull, 0)
		}
	}
	return st
}
