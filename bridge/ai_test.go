package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func sum(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

func tarGz(t *testing.T, files map[string]string, links map[string]string) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, body := range files {
		tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg})
		tw.Write([]byte(body))
	}
	for name, target := range links {
		tw.WriteHeader(&tar.Header{Name: name, Linkname: target, Typeflag: tar.TypeSymlink})
	}
	tw.Close()
	gz.Close()
	return buf.Bytes()
}

func TestFetchVerified(t *testing.T) {
	body := []byte("pretend this is a GGUF model")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	defer srv.Close()
	dir := t.TempDir()
	d := &download{}
	if err := fetchVerified(context.Background(), srv.URL, filepath.Join(dir, "ok"), sum(body), int64(len(body)), d); err != nil {
		t.Fatal(err)
	}
	if d.Done != int64(len(body)) {
		t.Fatalf("progress %d", d.Done)
	}
	err := fetchVerified(context.Background(), srv.URL, filepath.Join(dir, "bad"), sum([]byte("other")), int64(len(body)), &download{})
	if err == nil || !strings.Contains(err.Error(), "SHA256 mismatch") {
		t.Fatalf("a wrong hash must fail, got %v", err)
	}
	if err := fetchVerified(context.Background(), srv.URL, filepath.Join(dir, "size"), sum(body), 999, &download{}); err == nil {
		t.Fatal("a wrong size must fail")
	}
}

func TestUntarSafe(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.tgz")
	os.WriteFile(good, tarGz(t, map[string]string{"build/bin/llama-server": "bin", "build/bin/libllama.1.dylib": "lib"},
		map[string]string{"build/bin/libllama.dylib": "libllama.1.dylib"}), 0o600)
	if err := untarSafe(good, filepath.Join(dir, "out")); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(filepath.Join(dir, "out/build/bin/llama-server")); err != nil || st.Mode()&0o100 == 0 {
		t.Fatalf("binary missing or not executable: %v", err)
	}
	for name, archive := range map[string][]byte{
		"traversal": tarGz(t, map[string]string{"../../evil": "x"}, nil),
		"abs link":  tarGz(t, nil, map[string]string{"lib.dylib": "/etc/passwd"}),
		"up link":   tarGz(t, nil, map[string]string{"lib.dylib": "../../../etc/passwd"}),
	} {
		p := filepath.Join(dir, name+".tgz")
		os.WriteFile(p, archive, 0o600)
		if err := untarSafe(p, filepath.Join(dir, "x-"+name)); err == nil {
			t.Fatalf("%s: unsafe archive accepted", name)
		}
	}
}

func TestInstallLlamaFromRelease(t *testing.T) {
	suffix := llamaAssetSuffix()
	if suffix == "" || strings.HasSuffix(suffix, ".zip") {
		t.Skip("tar.gz platforms only")
	}
	name := "llama-server"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	archive := tarGz(t, map[string]string{"llama-b9/" + name: "#!/bin/sh\n"}, nil)
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api" {
			asset := "llama-b9-" + suffix
			json.NewEncoder(w).Encode([]map[string]any{
				{"tag_name": "v0.5.0", "assets": []any{}}, // non-build tags are skipped
				{"tag_name": "b9", "assets": []map[string]any{{"name": asset, "size": len(archive),
					"browser_download_url": srv.URL + "/dl/" + asset, "digest": "sha256:" + sum(archive)}}},
			})
			return
		}
		w.Write(archive)
	}))
	defer srv.Close()
	oldAPI, oldPrefix := githubAPI, llamaReleasePrefix
	defer func() { githubAPI, llamaReleasePrefix = oldAPI, oldPrefix }()
	githubAPI, llamaReleasePrefix = srv.URL+"/api", srv.URL+"/dl/"
	t.Setenv("PATH", t.TempDir()) // no system llama-server
	a := &aiState{dir: t.TempDir(), root: context.Background(), downloads: map[string]*download{}}
	if err := a.installLlama(&download{}); err != nil {
		t.Fatal(err)
	}
	if bin, ver := a.llamaBinary(); bin == "" || ver != "b9" {
		t.Fatalf("installed binary not found: %q %q", bin, ver)
	}
	// An asset outside the official download URL is refused.
	llamaReleasePrefix = "https://github.com/ggml-org/llama.cpp/releases/download/"
	a2 := &aiState{dir: t.TempDir(), root: context.Background(), downloads: map[string]*download{}}
	if err := a2.installLlama(&download{}); err == nil {
		t.Fatal("non-official asset URL accepted")
	}
}

func TestOpenAIChat(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Messages []chatMsg }
		json.NewDecoder(r.Body).Decode(&req)
		fmt.Fprintf(w, `{"choices":[{"message":{"role":"assistant","content":"<think>hmm</think> %d messages"}}]}`, len(req.Messages))
	}))
	defer srv.Close()
	got, err := openAIChat(context.Background(), srv.URL, []chatMsg{{"system", "s"}, {"user", "hola"}}, 0.2, 100)
	if err != nil || got != "2 messages" {
		t.Fatalf("%q %v", got, err)
	}
}

func TestAIConfigRejectsCloud(t *testing.T) {
	ai.dir = t.TempDir()
	h := &Hub{}
	rec := httptest.NewRecorder()
	h.handleAIConfig(rec, httptest.NewRequest("POST", "/", strings.NewReader(`{"provider":"ollama","ollama_model":"minimax-m2.1:cloud"}`)))
	if !strings.Contains(rec.Body.String(), `"ok":false`) {
		t.Fatalf("cloud model accepted: %s", rec.Body.String())
	}
}
