package main

import (
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestPolicyProductionNeedsConfirmation(t *testing.T) {
	dir := t.TempDir()
	p := newPolicy(dir, []string{"prod-eu"})
	req := httptest.NewRequest("POST", "/api/action", nil)
	// Unknown context counts as production.
	if p.check(req, "new-ctx") == nil {
		t.Fatal("unknown context must need a confirmation")
	}
	if err := p.setKind("lab", "sandbox"); err != nil {
		t.Fatal(err)
	}
	if err := p.check(req, "lab"); err != nil {
		t.Fatalf("sandbox must not need a confirmation: %v", err)
	}
	if p.check(req, "prod-eu") == nil {
		t.Fatal("production without the header must be refused")
	}
	req.Header.Set(ConfirmHeader, "prod-eu")
	if err := p.check(req, "prod-eu"); err != nil {
		t.Fatalf("confirmed change refused: %v", err)
	}
	req.Header.Set(ConfirmHeader, "other")
	if p.check(req, "prod-eu") == nil {
		t.Fatal("a confirmation for another context must not count")
	}
	if p.setKind("prod-eu", "sandbox") == nil {
		t.Fatal("--production contexts can't be changed from the game")
	}
	// Kinds persist.
	if k, _ := newPolicy(dir, nil).kind("lab"); k != "sandbox" {
		t.Fatalf("kind not saved: %q", k)
	}
}

func TestAuditLog(t *testing.T) {
	a := newAuditLog(filepath.Join(t.TempDir(), "actions.log"))
	a.record(AuditEntry{Context: "c1", What: "action", Target: "Deployment shop/web", Detail: "restart", OK: true})
	a.record(AuditEntry{Context: "c2", What: "kubectl", Detail: "kubectl -n x create secret generic s --from-literal=password=hunter22", OK: true})
	if got := a.last(10, ""); len(got) != 2 || got[0].Context != "c2" {
		t.Fatalf("newest first: %+v", got)
	}
	if got := a.last(10, "c1"); len(got) != 1 {
		t.Fatalf("filter by context: %+v", got)
	}
	if strings.Contains(a.last(1, "c2")[0].Detail, "hunter22") {
		t.Fatal("audit detail must be redacted")
	}
	// Reloaded from disk.
	if b := newAuditLog(a.path); len(b.last(10, "")) != 2 {
		t.Fatal("audit log not reloaded")
	}
}

func TestRedact(t *testing.T) {
	cases := []string{
		"Authorization: Bearer abcdefghijklmnop123",
		"DB_PASSWORD=supersecret123",
		`{"api_key": "sk-live-1234567890"}`,
		"AKIAABCDEFGHIJKLMNOP",
		"postgres://admin:s3cr3tpass@db:5432/app",
		"token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
		"-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----",
	}
	secrets := []string{"abcdefghijklmnop123", "supersecret123", "sk-live-1234567890", "AKIAABCDEFGHIJKLMNOP", "s3cr3tpass", "dozjgNryP4J3jVmNHl0w5N", "MIIEow"}
	for i, c := range cases {
		if out := redact(c); strings.Contains(out, secrets[i]) {
			t.Errorf("not redacted: %q -> %q", c, out)
		}
	}
	if out := redact("pod web-1 is Running, 3 restarts"); out != "pod web-1 is Running, 3 restarts" {
		t.Errorf("harmless text changed: %q", out)
	}
}

// Changes to a production (or unmarked) context are refused before touching
// the cluster, and the refusal is in the audit log.
func TestHandlersRefuseUnconfirmedProduction(t *testing.T) {
	p := newPolicy(t.TempDir(), nil)
	b := &Bridge{contextName: "prod", pol: p}
	rec := httptest.NewRecorder()
	b.handleAction(rec, httptest.NewRequest("POST", "/api/action", strings.NewReader(`{"action":"delete_pod","ns":"shop","name":"web-1"}`)))
	if rec.Code != 403 || !strings.Contains(rec.Body.String(), "production") {
		t.Fatalf("action: %d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	b.handleKubectl(rec, httptest.NewRequest("POST", "/api/kubectl", strings.NewReader(`{"line":"-n shop delete pod web-1"}`)))
	if !strings.Contains(rec.Body.String(), "production") {
		t.Fatalf("kubectl delete: %s", rec.Body.String())
	}
	rec = httptest.NewRecorder()
	b.handleScenario(rec, httptest.NewRequest("POST", "/api/scenario", strings.NewReader(`{"name":"complex"}`)))
	if rec.Code != 403 {
		t.Fatalf("scenario on production: %d", rec.Code)
	}
	got := p.audit.last(10, "prod")
	if len(got) != 3 || got[0].OK || got[0].Confirmed {
		t.Fatalf("refusals must be audited: %+v", got)
	}
}
