//go:build e2e

// End-to-end: a real bridge against a real cluster (kind in CI).
//
//	KUBIVERSE_E2E_CONTEXT=kind-kubiverse-e2e go test -tags e2e -run E2E -v ./...
//
// It creates the namespace kv-e2e (testdata/e2e.yaml) and deletes it at the end.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const e2eNS = "kv-e2e"

type e2e struct {
	t    *testing.T
	ctx  string
	base string
}

func (e *e2e) kubectl(args ...string) string {
	e.t.Helper()
	out, err := exec.Command("kubectl", append([]string{"--context", e.ctx}, args...)...).CombinedOutput()
	if err != nil {
		e.t.Fatalf("kubectl %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// call does a request; confirm adds the production confirmation header.
func (e *e2e) call(method, path string, body any, confirm bool) map[string]any {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.base+path, rd)
	if confirm {
		req.Header.Set(ConfirmHeader, e.ctx)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(raw, &out); err != nil {
		e.t.Fatalf("%s %s: not json (%d): %s", method, path, resp.StatusCode, raw)
	}
	return out
}

func (e *e2e) action(req map[string]any) map[string]any {
	return e.call("POST", "/api/action", req, true)
}

func (e *e2e) image() string {
	return strings.TrimSpace(e.kubectl("-n", e2eNS, "get", "deploy/web", "-o", "jsonpath={.spec.template.spec.containers[0].image}"))
}

func TestE2E(t *testing.T) {
	kctx := os.Getenv("KUBIVERSE_E2E_CONTEXT")
	if kctx == "" {
		t.Skip("set KUBIVERSE_E2E_CONTEXT to a disposable cluster's context")
	}
	e := &e2e{t: t, ctx: kctx}
	e.kubectl("apply", "-f", "testdata/e2e.yaml")
	t.Cleanup(func() { exec.Command("kubectl", "--context", kctx, "delete", "ns", e2eNS, "--wait=false").Run() })
	e.kubectl("-n", e2eNS, "rollout", "status", "deploy/web", "--timeout=180s")
	// A second revision to roll back from.
	e.kubectl("-n", e2eNS, "set", "image", "deploy/web", "pause=registry.k8s.io/pause:3.10")
	e.kubectl("-n", e2eNS, "rollout", "status", "deploy/web", "--timeout=180s")

	// The bridge itself, as users run it.
	dir := t.TempDir()
	bin := filepath.Join(dir, "kubiverse-bridge")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	port, err := freePort()
	if err != nil {
		t.Fatal(err)
	}
	e.base = fmt.Sprintf("http://127.0.0.1:%d", port)
	cmd := exec.Command(bin, "--addr", fmt.Sprintf("127.0.0.1:%d", port), "--context", kctx,
		"--data", filepath.Join(dir, "kubeconfigs"), "--prometheus", "off", "--alertmanager", "off", "--loki", "off")
	var logs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &logs, &logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill()
		if t.Failed() {
			t.Logf("bridge log:\n%s", logs.String())
		}
	})
	for i := 0; ; i++ {
		if r, err := http.Get(e.base + "/healthz"); err == nil && r.StatusCode == 200 {
			break
		}
		if i > 100 {
			t.Fatal("bridge didn't start")
		}
		time.Sleep(200 * time.Millisecond)
	}

	t.Run("state", func(t *testing.T) {
		s := e.call("GET", "/api/state", nil, false)
		found := false
		for _, w := range s["workloads"].([]any) {
			m := w.(map[string]any)
			if m["ns"] == e2eNS && m["name"] == "web" {
				found = m["pdb"] != nil && m["revision"].(float64) == 2
			}
		}
		if !found {
			t.Fatalf("web with its PDB and revision 2 not in the state")
		}
	})

	t.Run("an unmarked cluster counts as production", func(t *testing.T) {
		r := e.call("POST", "/api/action", map[string]any{"action": "scale", "kind": "Deployment", "ns": e2eNS, "name": "solo", "replicas": 2}, false)
		if r["ok"] == true || !strings.Contains(fmt.Sprint(r["error"]), "confirmation") {
			t.Fatalf("a change without confirmation went through: %v", r)
		}
		e.call("POST", "/api/kind", map[string]any{"context": kctx, "kind": "sandbox"}, false)
	})

	t.Run("patches over the websocket", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		ws, _, err := websocket.Dial(ctx, strings.Replace(e.base, "http", "ws", 1)+"/api/ws?patch=1", nil)
		if err != nil {
			t.Fatal(err)
		}
		defer ws.CloseNow()
		ws.SetReadLimit(1 << 26)
		var seq float64 = -1
		scaled := false
		for {
			_, raw, err := ws.Read(ctx)
			if err != nil {
				t.Fatalf("no patch with the new replicas: %v", err)
			}
			var m map[string]any
			json.Unmarshal(raw, &m)
			switch m["type"] {
			case "state":
				seq = m["seq"].(float64)
				if !scaled {
					scaled = true
					if r := e.action(map[string]any{"action": "scale", "kind": "Deployment", "ns": e2eNS, "name": "solo", "replicas": 2}); r["ok"] != true {
						t.Fatal(r)
					}
				}
			case "patch":
				p := m["data"].(map[string]any)
				if p["base"].(float64) != seq {
					t.Fatalf("patch on %v, we have %v", p["base"], seq)
				}
				seq = p["seq"].(float64)
				set, _ := p["set"].(map[string]any)
				for _, w := range asList(set["workloads"]) {
					w := w.(map[string]any)
					if w["name"] == "solo" && w["desired"].(float64) == 2 {
						return
					}
				}
			}
		}
	})

	t.Run("rollout pause, resume and undo", func(t *testing.T) {
		for _, a := range []string{"pause", "resume"} {
			if r := e.action(map[string]any{"action": a, "kind": "Deployment", "ns": e2eNS, "name": "web"}); r["ok"] != true {
				t.Fatalf("%s: %v", a, r)
			}
		}
		h := e.call("GET", "/api/rollout?ns="+e2eNS+"&name=web", nil, false)
		if len(asList(h["revisions"])) < 2 {
			t.Fatalf("history: %v", h)
		}
		if r := e.action(map[string]any{"action": "rollout_undo", "kind": "Deployment", "ns": e2eNS, "name": "web"}); r["ok"] != true {
			t.Fatal(r)
		}
		if img := e.image(); img != "registry.k8s.io/pause:3.9" {
			t.Fatalf("after undo: %s", img)
		}
		e.kubectl("-n", e2eNS, "rollout", "status", "deploy/web", "--timeout=180s")
	})

	t.Run("diff before applying changes nothing", func(t *testing.T) {
		m := e.call("GET", "/api/manifest?kind=Deployment&ns="+e2eNS+"&name=web", nil, false)
		yaml := strings.Replace(m["yaml"].(string), "pause:3.9", "pause:3.8", 1)
		d := e.call("POST", "/api/manifest", map[string]any{"kind": "Deployment", "ns": e2eNS, "name": "web", "yaml": yaml, "diff": true}, false)
		if d["changed"] != true || !strings.Contains(d["diff"].(string), "+      - image: registry.k8s.io/pause:3.8") {
			t.Fatalf("diff: %v", d)
		}
		if img := e.image(); img != "registry.k8s.io/pause:3.9" {
			t.Fatalf("the diff changed the object: %s", img)
		}
	})

	t.Run("permissions and kubectl", func(t *testing.T) {
		if c := e.call("GET", "/api/cani?ns="+e2eNS, nil, false); c["ok"] != true {
			t.Fatal(c)
		}
		k := e.call("POST", "/api/kubectl", map[string]any{"line": "-n " + e2eNS + " get pods"}, false)
		if k["ok"] != true || !strings.Contains(k["output"].(string), "web-") {
			t.Fatalf("kubectl: %v", k)
		}
	})

	t.Run("drain honours the PodDisruptionBudget", func(t *testing.T) {
		nodes := strings.Fields(e.kubectl("-n", e2eNS, "get", "pods", "-l", "app=web", "-o", "jsonpath={.items[*].spec.nodeName}"))
		node := nodes[0]
		for _, n := range nodes { // rather a worker than the control-plane
			if !strings.Contains(n, "control-plane") {
				node = n
			}
		}
		defer e.kubectl("uncordon", node)
		r := e.action(map[string]any{"action": "drain", "name": node})
		if r["ok"] != true || !strings.Contains(fmt.Sprint(r["message"]), "blocked by a PodDisruptionBudget") {
			t.Fatalf("drain: %v", r)
		}
		if n := e.kubectl("-n", e2eNS, "get", "pods", "-l", "app=web", "--no-headers"); strings.Count(n, "Running") < 2 {
			t.Fatalf("the budget didn't hold:\n%s", n)
		}
	})

	t.Run("every change is in the audit log", func(t *testing.T) {
		a := e.call("GET", "/api/audit?limit=50&context="+kctx, nil, false)
		if len(asList(a["entries"])) < 5 {
			t.Fatalf("audit: %v", a)
		}
	})
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}
