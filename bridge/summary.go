package main

import (
	"fmt"
	"net/http"
	"sort"
)

// Summary is a cluster's health in a few numbers: what the game's control
// room shows on one TV for every saved cluster at once, without pulling the
// whole state of each one.
type Summary struct {
	Context        string   `json:"context"`
	Time           int64    `json:"time"`
	Nodes          int      `json:"nodes"`
	NodesDown      int      `json:"nodes_down"`     // not Ready
	NodesPressure  int      `json:"nodes_pressure"` // Ready, but with MemoryPressure, DiskPressure...
	Pods           int      `json:"pods"`           // finished ones (Completed) left out
	PodsBad        int      `json:"pods_bad"`       // crashing, image pull errors, failed
	PodsWaiting    int      `json:"pods_waiting"`   // pending, or running but not ready
	AlertsCritical int      `json:"alerts_critical"`
	AlertsWarning  int      `json:"alerts_warning"`
	Worst          []string `json:"worst"` // a few short lines: the first things to look at
}

// summaryWorst is how many lines Worst carries: what fits on a small screen.
const summaryWorst = 5

// podCategory sorts a pod like the game does (PodBot.categorize): ok, warn,
// pending, crash, pull, failed, done or term.
func podCategory(p Pod) string {
	if p.Deleting {
		return "term"
	}
	switch p.Status {
	case "Terminating":
		return "term"
	case "CrashLoopBackOff", "Error", "OOMKilled", "RunContainerError", "CreateContainerError", "Init:Error", "Init:CrashLoopBackOff":
		return "crash"
	case "ErrImagePull", "ImagePullBackOff", "InvalidImageName", "Init:ErrImagePull", "Init:ImagePullBackOff":
		return "pull"
	case "Completed", "Succeeded":
		return "done"
	case "Failed", "Evicted", "Unknown", "NodeLost", "ContainerStatusUnknown":
		return "failed"
	case "Running":
		if p.Ready >= p.Total {
			return "ok"
		}
		return "warn"
	}
	return "pending"
}

func summarize(s *Snapshot) Summary {
	out := Summary{Context: s.Context, Time: s.Time, Worst: []string{}}
	// Worst first: nodes down, critical alerts, then broken pods.
	var down, crit, bad []string
	for _, n := range s.Nodes {
		out.Nodes++
		switch {
		case !n.Ready:
			out.NodesDown++
			down = append(down, "node "+n.Name+" NotReady")
		case len(n.Conditions) > 0:
			out.NodesPressure++
			down = append(down, fmt.Sprintf("node %s %s", n.Name, n.Conditions[0]))
		}
	}
	for _, a := range s.Alerts {
		switch a.Severity {
		case "critical":
			out.AlertsCritical++
			crit = append(crit, "alert "+a.Name)
		case "warning":
			out.AlertsWarning++
		}
	}
	for _, p := range s.Pods {
		switch podCategory(p) {
		case "done", "term":
			continue
		case "crash", "pull", "failed":
			out.PodsBad++
			bad = append(bad, fmt.Sprintf("%s/%s %s", p.Namespace, p.Name, p.Status))
		case "pending", "warn":
			out.PodsWaiting++
		}
		out.Pods++
	}
	sort.Strings(bad)
	for _, l := range [][]string{down, crit, bad} {
		for _, line := range l {
			if len(out.Worst) < summaryWorst {
				out.Worst = append(out.Worst, line)
			}
		}
	}
	return out
}

func (b *Bridge) handleSummary(w http.ResponseWriter, r *http.Request) {
	snap, err := b.buildSnapshot()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, summarize(snap))
}
