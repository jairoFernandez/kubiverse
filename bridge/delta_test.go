package main

import (
	"encoding/json"
	"testing"
)

func TestPatchesCarryOnlyChanges(t *testing.T) {
	var d stateDiff
	s := &Snapshot{Context: "c", Time: 100,
		Nodes: []Node{{Name: "n1", Ready: true, Age: 50}},
		Pods:  []Pod{{Namespace: "a", Name: "p1", Status: "Running", Age: 10}, {Namespace: "a", Name: "p2", Status: "Running", Age: 10}}}
	full, patch := d.next(s)
	if patch != nil || full == nil {
		t.Fatal("first message must be a full state only")
	}
	// A second later: only ages moved, p2 crashed, p1 is gone, p3 is new.
	s2 := &Snapshot{Context: "c", Time: 101,
		Nodes: []Node{{Name: "n1", Ready: true, Age: 51}},
		Pods:  []Pod{{Namespace: "a", Name: "p2", Status: "CrashLoopBackOff", Age: 11}, {Namespace: "a", Name: "p3", Status: "Pending"}}}
	_, patch = d.next(s2)
	var m struct {
		Type string   `json:"type"`
		Data patchMsg `json:"data"`
	}
	if err := json.Unmarshal(patch, &m); err != nil || m.Type != "patch" {
		t.Fatalf("patch: %v %s", err, patch)
	}
	p := m.Data
	if p.Seq != 2 || p.Base != 1 || p.Time != 101 {
		t.Fatalf("seq/base/time: %+v", p)
	}
	if len(p.Set["nodes"]) != 0 {
		t.Fatalf("an age alone is not a change: %s", p.Set["nodes"])
	}
	if len(p.Set["pods"]) != 2 || len(p.Del["pods"]) != 1 || p.Del["pods"][0] != "a/p1" {
		t.Fatalf("pods: set %d del %v", len(p.Set["pods"]), p.Del["pods"])
	}
	if p.Metrics != nil {
		t.Fatal("unchanged metrics must not be resent")
	}
}
