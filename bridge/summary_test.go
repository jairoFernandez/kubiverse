package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

// /api/summary answers with the small JSON, built from the live snapshot.
func TestHandleSummary(t *testing.T) {
	b := newTestBridge(t)
	b.ingLister = nil
	rec := httptest.NewRecorder()
	b.handleSummary(rec, httptest.NewRequest("GET", "/api/summary", nil))
	if rec.Code != 200 {
		t.Fatalf("/api/summary: %d %s", rec.Code, rec.Body.String())
	}
	var got Summary
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Context != "test" || got.Worst == nil || got.Time == 0 {
		t.Errorf("summary: %+v", got)
	}
}

// The control room's summary counts what matters and lists the worst first.
func TestSummarize(t *testing.T) {
	s := &Snapshot{
		Context: "staging",
		Time:    1700000000,
		Nodes: []Node{
			{Name: "n1", Ready: true},
			{Name: "n2", Ready: false},
			{Name: "n3", Ready: true, Conditions: []string{"DiskPressure"}},
		},
		Pods: []Pod{
			{Namespace: "shop", Name: "api-1", Status: "Running", Ready: 1, Total: 1},
			{Namespace: "shop", Name: "web-1", Status: "Running", Ready: 0, Total: 1},
			{Namespace: "shop", Name: "db-0", Status: "Pending"},
			{Namespace: "shop", Name: "cart-1", Status: "CrashLoopBackOff"},
			{Namespace: "ads", Name: "img-1", Status: "ImagePullBackOff"},
			{Namespace: "jobs", Name: "batch-1", Status: "Completed"},
			{Namespace: "jobs", Name: "old-1", Status: "Running", Ready: 1, Total: 1, Deleting: true},
		},
		Alerts: []Alert{{Name: "KubeAPIDown", Severity: "critical"}, {Name: "HighLatency", Severity: "warning"}, {Name: "Watchdog", Severity: "none"}},
	}
	got := summarize(s)
	if got.Context != "staging" || got.Time != 1700000000 {
		t.Fatalf("context/time not carried: %+v", got)
	}
	if got.Nodes != 3 || got.NodesDown != 1 || got.NodesPressure != 1 {
		t.Errorf("nodes = %d down %d pressure %d, want 3/1/1", got.Nodes, got.NodesDown, got.NodesPressure)
	}
	if got.Pods != 5 || got.PodsBad != 2 || got.PodsWaiting != 2 {
		t.Errorf("pods = %d bad %d waiting %d, want 5/2/2 (finished and deleting left out)", got.Pods, got.PodsBad, got.PodsWaiting)
	}
	if got.AlertsCritical != 1 || got.AlertsWarning != 1 {
		t.Errorf("alerts = %d critical %d warning, want 1/1", got.AlertsCritical, got.AlertsWarning)
	}
	want := []string{"node n2 NotReady", "node n3 DiskPressure", "alert KubeAPIDown", "ads/img-1 ImagePullBackOff", "shop/cart-1 CrashLoopBackOff"}
	if strings.Join(got.Worst, "|") != strings.Join(want, "|") {
		t.Errorf("worst = %q, want %q", got.Worst, want)
	}
}

// A healthy (or empty) cluster: zeros and an empty list, never JSON null.
func TestSummarizeEmpty(t *testing.T) {
	got := summarize(&Snapshot{Context: "dev"})
	raw, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"worst":[]`) {
		t.Errorf("worst must be a list, got %s", raw)
	}
	if got.Pods != 0 || got.PodsBad != 0 || got.NodesDown != 0 {
		t.Errorf("empty cluster counted something: %+v", got)
	}
}

// Worst never grows past what fits on a TV.
func TestSummarizeWorstCapped(t *testing.T) {
	s := &Snapshot{}
	for i := 0; i < 20; i++ {
		s.Pods = append(s.Pods, Pod{Namespace: "x", Name: strings.Repeat("p", i+1), Status: "Error"})
	}
	got := summarize(s)
	if got.PodsBad != 20 || len(got.Worst) != summaryWorst {
		t.Errorf("bad %d worst %d, want 20 and %d lines", got.PodsBad, len(got.Worst), summaryWorst)
	}
}

// The bridge sorts pods the same way the game does.
func TestPodCategory(t *testing.T) {
	cases := map[string]Pod{
		"ok":      {Status: "Running", Ready: 2, Total: 2},
		"warn":    {Status: "Running", Ready: 1, Total: 2},
		"pending": {Status: "ContainerCreating"},
		"crash":   {Status: "OOMKilled"},
		"pull":    {Status: "ErrImagePull"},
		"failed":  {Status: "Evicted"},
		"done":    {Status: "Succeeded"},
		"term":    {Status: "Terminating"},
	}
	for want, p := range cases {
		if got := podCategory(p); got != want {
			t.Errorf("podCategory(%q) = %q, want %q", p.Status, got, want)
		}
	}
	if podCategory(Pod{Status: "CrashLoopBackOff", Deleting: true}) != "term" {
		t.Error("a pod being deleted is leaving, whatever its status")
	}
}
