package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGithubRepoURLs(t *testing.T) {
	for in, want := range map[string]string{
		"https://github.com/acme/platform.git": "acme/platform",
		"https://github.com/acme/platform":     "acme/platform",
		"git@github.com:acme/platform.git":     "acme/platform",
	} {
		o, r, ok := parseGithubRepo(in)
		if !ok || o+"/"+r != want {
			t.Errorf("%s: %s/%s %v", in, o, r, ok)
		}
	}
	if _, _, ok := parseGithubRepo("https://gitlab.com/acme/platform.git"); ok {
		t.Error("gitlab is not github")
	}
}

const multiDoc = `apiVersion: v1
kind: Service
metadata:
  name: api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: shop
spec:
  replicas: 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
`

func TestFindAndReplaceDoc(t *testing.T) {
	docs := splitDocs(multiDoc)
	i := findDoc(docs, "Deployment", "shop", "api")
	if i != 1 || findDoc(docs, "Deployment", "other", "api") != -1 || findDoc(docs, "Deployment", "shop", "worker") != 2 {
		t.Fatalf("findDoc: %d", i)
	}
	edited := strings.Replace(strings.TrimLeft(docs[1], "\n"), "replicas: 2", "replicas: 4", 1)
	out := replaceDoc(multiDoc, i, edited)
	if !strings.Contains(out, "replicas: 4") || !strings.Contains(out, "name: worker") || !strings.HasPrefix(out, "apiVersion: v1\nkind: Service") {
		t.Fatalf("replaceDoc:\n%s", out)
	}
	if strings.Count(out, "---") != 2 {
		t.Fatalf("separators:\n%s", out)
	}
}

// The pull request flow against a fake GitHub: branch, file, PR.
func TestProposePR(t *testing.T) {
	var calls []string
	var put map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(401)
			return
		}
		switch {
		case r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/git/ref/heads/main"):
			w.Write([]byte(`{"object":{"sha":"abc"}}`))
		case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/git/refs"):
			w.WriteHeader(201)
			w.Write([]byte(`{}`))
		case r.Method == "PUT":
			json.NewDecoder(r.Body).Decode(&put)
			w.Write([]byte(`{}`))
		case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/pulls"):
			w.WriteHeader(201)
			w.Write([]byte(`{"html_url":"https://github.com/acme/platform/pull/7"}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	old := githubREST
	githubREST = srv.URL
	defer func() { githubREST = old }()
	b := &Bridge{gh: &githubConn{token: "tok"}}
	src := &gitSource{App: "shop", Owner: "acme", Repo: "platform", Ref: "main", File: "apps/shop/api.yaml", Doc: 1, SHA: "blob1", text: multiDoc, CanWrite: true}
	pr, err := b.proposePR(t.Context(), src, "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api\nspec:\n  replicas: 4\n", gitChange{Kind: "Deployment", NS: "shop", Name: "api"})
	if err != nil || pr != "https://github.com/acme/platform/pull/7" {
		t.Fatalf("%v %s (calls %v)", err, pr, calls)
	}
	content, _ := base64.StdEncoding.DecodeString(put["content"].(string))
	if put["sha"] != "blob1" || !strings.HasPrefix(put["branch"].(string), "kubiverse/deployment-api-") || !strings.Contains(string(content), "replicas: 4") || !strings.Contains(string(content), "name: worker") {
		t.Fatalf("put: %v\n%s", put, content)
	}
}
