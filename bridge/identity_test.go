package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"k8s.io/client-go/rest"
)

func TestTeamModeRequiresSignIn(t *testing.T) {
	h := &Hub{userHeader: "X-Auth-Request-Email", groupsHeader: "X-Auth-Request-Groups"}
	var got identity
	next := h.auth(func(w http.ResponseWriter, r *http.Request) { got = identityFrom(r.Context()) })
	rec := httptest.NewRecorder()
	next(rec, httptest.NewRequest("GET", "/api/state", nil))
	if rec.Code != 401 {
		t.Fatalf("no user header must be refused, got %d", rec.Code)
	}
	req := httptest.NewRequest("GET", "/api/state", nil)
	req.Header.Set("X-Auth-Request-Email", "ana@example.com")
	req.Header.Set("X-Auth-Request-Groups", "devs, sre")
	rec = httptest.NewRecorder()
	next(rec, req)
	if rec.Code != 200 || got.User != "ana@example.com" || len(got.Groups) != 2 || got.Groups[1] != "sre" {
		t.Fatalf("identity: %d %+v", rec.Code, got)
	}
}

func TestChangesImpersonateThePlayer(t *testing.T) {
	b := &Bridge{restCfg: &rest.Config{Host: "https://k8s.example"}, contextName: "c", kubectlContext: "c"}
	r := withIdentity(httptest.NewRequest("POST", "/", nil), identity{User: "ana@example.com", Groups: []string{"devs"}})
	cfg := b.restFor(r.Context())
	if cfg.Impersonate.UserName != "ana@example.com" || cfg.Impersonate.Groups[0] != "devs" {
		t.Fatalf("rest config not impersonating: %+v", cfg.Impersonate)
	}
	if b.restCfg.Impersonate.UserName != "" {
		t.Fatal("the bridge's own config must stay untouched")
	}
	args := strings.Join(b.kubectlBase(r.Context(), "15s"), " ")
	if !strings.Contains(args, "--as ana@example.com") || !strings.Contains(args, "--as-group devs") || !strings.Contains(args, "--context c") {
		t.Fatalf("kubectl args: %s", args)
	}
	b.inCluster = true
	if strings.Contains(strings.Join(b.kubectlBase(r.Context(), "15s"), " "), "--context") {
		t.Fatal("in the cluster kubectl uses the pod's ServiceAccount, no --context")
	}
	if strings.Contains(strings.Join(b.kubectlBase(httptest.NewRequest("GET", "/", nil).Context(), "15s"), " "), "--as") {
		t.Fatal("no player (local mode): no impersonation")
	}
}

func TestSharedBridgeRefusesKubeconfigs(t *testing.T) {
	h := &Hub{inCluster: true}
	rec := httptest.NewRecorder()
	h.handleAddKubeconfig(rec, httptest.NewRequest("POST", "/api/kubeconfig", strings.NewReader(`{"name":"x","content":"y"}`)))
	if rec.Code != 403 {
		t.Fatalf("in-cluster bridge must refuse kubeconfigs: %d", rec.Code)
	}
}
