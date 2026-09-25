package main

import (
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestPrepareEdited(t *testing.T) {
	ok := "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 3\n"
	js, err := prepareEdited(ok, "Deployment", "shop", "web")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(js), `"namespace":"shop"`) {
		t.Fatalf("namespace not set: %s", js)
	}
	for name, src := range map[string]string{
		"rename":    strings.Replace(ok, "name: web", "name: other", 1),
		"kind":      strings.Replace(ok, "kind: Deployment", "kind: Secret", 1),
		"namespace": strings.Replace(ok, "  name: web\n", "  name: web\n  namespace: kube-system\n", 1),
		"yaml":      "kind: [",
		"list":      "- a\n- b\n",
	} {
		if _, err := prepareEdited(src, "Deployment", "shop", "web"); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, _, err := manifestTarget("secret", "shop", "db"); err == nil {
		t.Error("secrets must not be editable")
	}
	if k, ns, err := manifestTarget("node", "x", "n1"); err != nil || k != "Node" || ns != "" {
		t.Errorf("node: %q %q %v", k, ns, err)
	}
}

func TestCleanAndRestoreLastApplied(t *testing.T) {
	cur := map[string]any{"status": map[string]any{"x": 1}, "metadata": map[string]any{"name": "web",
		"managedFields": []any{1}, "annotations": map[string]any{lastApplied: "{...}"}}}
	cleanObject(cur)
	if _, has := cur["status"]; has {
		t.Fatal("status kept")
	}
	md := cur["metadata"].(map[string]any)
	if _, has := md["managedFields"]; has {
		t.Fatal("managedFields kept")
	}
	if _, has := md["annotations"]; has {
		t.Fatal("empty annotations kept")
	}
	orig := map[string]any{"metadata": map[string]any{"annotations": map[string]any{lastApplied: "{orig}"}}}
	out := restoreLastApplied([]byte(`{"metadata":{"name":"web"}}`), orig)
	var obj map[string]any
	json.Unmarshal(out, &obj)
	if obj["metadata"].(map[string]any)["annotations"].(map[string]any)[lastApplied] != "{orig}" {
		t.Fatalf("not restored: %s", out)
	}
}

func TestLanSetup(t *testing.T) {
	addr, token, origins := "127.0.0.1:9000", "", "https://example.com"
	urls := lanSetup(&addr, &token, &origins)
	if addr != "0.0.0.0:9000" {
		t.Fatalf("addr %s", addr)
	}
	if len(token) != 24 {
		t.Fatalf("a random token is required, got %q", token)
	}
	if !strings.Contains(origins, "https://example.com") {
		t.Fatalf("user origins lost: %s", origins)
	}
	for _, u := range urls {
		if !strings.Contains(u, "?token="+token) || !strings.HasPrefix(u, "https://") {
			t.Fatalf("bad url %s", u)
		}
	}
	if !exposed("0.0.0.0:8088") || exposed("127.0.0.1:8088") || exposed("localhost:8088") {
		t.Fatal("exposed()")
	}
}

func TestLanCert(t *testing.T) {
	dir := t.TempDir()
	c1, k1, err := lanCert(dir)
	if err != nil {
		t.Fatal(err)
	}
	st, _ := os.Stat(k1)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("key permissions %v", st.Mode().Perm())
	}
	raw1, _ := os.ReadFile(c1)
	c2, _, _ := lanCert(dir) // reused, not regenerated
	raw2, _ := os.ReadFile(c2)
	if string(raw1) != string(raw2) {
		t.Fatal("certificate regenerated although it still covers the IPs")
	}
}

func TestWebHandlerGzip(t *testing.T) {
	dir := t.TempDir()
	body := strings.Repeat("wasm wasm wasm ", 5000)
	os.WriteFile(dir+"/index.wasm", []byte(body), 0o600)
	h := webHandler(dir)
	req := httptest.NewRequest("GET", "/index.wasm", nil)
	req.Header.Set("Accept-Encoding", "gzip, br")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Content-Encoding") != "gzip" || rec.Header().Get("Content-Type") != "application/wasm" {
		t.Fatalf("headers %v", rec.Header())
	}
	zr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(zr)
	if string(got) != body || rec.Body.Len() > len(body)/10 {
		t.Fatalf("bad gzip body (%d bytes)", rec.Body.Len())
	}
	req = httptest.NewRequest("GET", "/../../etc/passwd", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code == 200 {
		t.Fatal("path traversal served")
	}
}
