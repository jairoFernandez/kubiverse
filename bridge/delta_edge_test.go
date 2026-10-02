package main

import (
	"encoding/json"
	"testing"
)

func decodePatch(t *testing.T, raw []byte) patchMsg {
	t.Helper()
	var m struct {
		Type string   `json:"type"`
		Data patchMsg `json:"data"`
	}
	if err := json.Unmarshal(raw, &m); err != nil || m.Type != "patch" {
		t.Fatalf("patch: %v %s", err, raw)
	}
	return m.Data
}

func TestPatchEdgeCases(t *testing.T) {
	var d stateDiff
	s := &Snapshot{Context: "c", Time: 1,
		Alerts:  []Alert{{ID: "a1", Name: "Down", Since: 100}},
		Certs:   []Cert{{Namespace: "shop", Name: "tls", ExpiresIn: 10*3600 + 1800}},
		Volumes: []Volume{{Namespace: "shop", Name: "data", Age: 5}},
		Helm:    []HelmRelease{{Namespace: "shop", Name: "redis", Revision: 1}},
		Metrics: Metrics{Available: true, Nodes: map[string]Usage{"n1": {CPUm: 100}}}}
	if _, patch := d.next(s); patch != nil {
		t.Fatal("first is full only")
	}
	// Nothing really changed: the alert's "since", a cert a few minutes closer
	// to expiry and a volume's age are not changes. Same metrics: not resent.
	s2 := *s
	s2.Time = 2
	s2.Alerts = []Alert{{ID: "a1", Name: "Down", Since: 160}}
	s2.Certs = []Cert{{Namespace: "shop", Name: "tls", ExpiresIn: 10*3600 + 1500}}
	s2.Volumes = []Volume{{Namespace: "shop", Name: "data", Age: 6}}
	full, patch := d.next(&s2)
	p := decodePatch(t, patch)
	if len(p.Set) != 0 || len(p.Del) != 0 || p.Metrics != nil || p.Seq != 2 || p.Base != 1 {
		t.Errorf("no-op patch: %+v", p)
	}
	var f struct {
		Seq int64 `json:"seq"`
	}
	if json.Unmarshal(full, &f); f.Seq != 2 {
		t.Errorf("the full state carries the same seq: %d", f.Seq)
	}
	// A whole collection goes away, metrics change, a release is upgraded.
	s3 := s2
	s3.Time = 3
	s3.Alerts = nil
	s3.Helm = []HelmRelease{{Namespace: "shop", Name: "redis", Revision: 2}}
	s3.Metrics = Metrics{Available: true, Nodes: map[string]Usage{"n1": {CPUm: 900}}}
	p = decodePatch(t, mustPatch(d.next(&s3)))
	if len(p.Del["alerts"]) != 1 || p.Del["alerts"][0] != "a1" || len(p.Set["helm"]) != 1 || p.Metrics == nil || p.Metrics.Nodes["n1"].CPUm != 900 {
		t.Errorf("changes: %+v", p)
	}
	// A cert crossing an hour is news (the game shows days/hours left).
	s4 := s3
	s4.Certs = []Cert{{Namespace: "shop", Name: "tls", ExpiresIn: 8 * 3600}}
	if p = decodePatch(t, mustPatch(d.next(&s4))); len(p.Set["certs"]) != 1 {
		t.Errorf("cert: %+v", p)
	}
}

func mustPatch(_, patch []byte) []byte { return patch }
