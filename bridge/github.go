package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pmezard/go-difflib/difflib"
	"sigs.k8s.io/yaml"
)

// GitOps with GitHub: for a workload an Argo CD Application deploys, find
// the YAML that defines it in the app's GitHub repo, show how the cluster
// differs from git, preview what Argo would change if you edit it, and
// propose the change as a pull request.
//
// The token (a fine-grained personal access token) stays with the bridge:
// ~/.kubecraft/github-token (0600) when you connect from the game, or a file
// mounted from a Secret (--github-token-file) on a shared bridge. It is never
// sent to the game or to the AI.

var githubREST = "https://api.github.com" // a var: the tests point it at a fake GitHub

type githubConn struct {
	mu    sync.Mutex
	path  string // where a token set from the game is kept ("" = can't set it)
	token string
	login string
}

func newGithubConn(dataDir, tokenFile string, shared bool) *githubConn {
	g := &githubConn{}
	if tokenFile != "" {
		if b, err := os.ReadFile(tokenFile); err == nil {
			g.token = strings.TrimSpace(string(b))
		}
	} else if !shared {
		g.path = filepath.Join(dataDir, "github-token")
		if b, err := os.ReadFile(g.path); err == nil {
			g.token = strings.TrimSpace(string(b))
		}
	}
	return g
}

func (g *githubConn) get() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.token
}

// call is one GitHub API request with the token.
func (g *githubConn) call(ctx context.Context, method, path string, body any, out any) error {
	tok := g.get()
	if tok == "" {
		return errors.New("GitHub is not connected (connect it from the game: GITHUB)")
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, method, githubREST+path, rd)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode >= 300 {
		var e struct {
			Message string `json:"message"`
		}
		json.Unmarshal(raw, &e)
		switch resp.StatusCode {
		case 401:
			return errors.New("GitHub says the token is not valid (expired or revoked?)")
		case 403, 404:
			return fmt.Errorf("GitHub: %s (does the token have access to this repository, with the right permissions?)", e.Message)
		}
		return fmt.Errorf("GitHub: %s %s", resp.Status, e.Message)
	}
	if out != nil {
		return json.Unmarshal(raw, out)
	}
	return nil
}

// GET /api/github: connected? as whom? POST {token}: connect. DELETE: forget it.
func (h *Hub) handleGithub(w http.ResponseWriter, r *http.Request) {
	g := h.gh
	switch r.Method {
	case http.MethodPost, http.MethodDelete:
		if g.path == "" {
			writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "on a shared bridge the GitHub token comes from its Secret (--github-token-file)"})
			return
		}
		tok := ""
		if r.Method == http.MethodPost {
			var req struct {
				Token string `json:"token"`
			}
			json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req)
			tok = strings.TrimSpace(req.Token)
			if tok == "" {
				writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "empty token"})
				return
			}
		}
		g.mu.Lock()
		old := g.token
		g.token, g.login = tok, ""
		g.mu.Unlock()
		if tok != "" {
			var u struct {
				Login string `json:"login"`
			}
			if err := g.call(r.Context(), "GET", "/user", nil, &u); err != nil {
				g.mu.Lock()
				g.token = old
				g.mu.Unlock()
				writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			g.mu.Lock()
			g.login = u.Login
			g.mu.Unlock()
			os.MkdirAll(filepath.Dir(g.path), 0o700)
			if err := os.WriteFile(g.path, []byte(tok+"\n"), 0o600); err != nil {
				writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
				return
			}
		} else {
			os.Remove(g.path)
		}
	}
	g.mu.Lock()
	login, has := g.login, g.token != ""
	g.mu.Unlock()
	if has && login == "" {
		var u struct {
			Login string `json:"login"`
		}
		if g.call(r.Context(), "GET", "/user", nil, &u) == nil {
			g.mu.Lock()
			g.login, login = u.Login, u.Login
			g.mu.Unlock()
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "connected": has, "login": login, "can_set": g.path != ""})
}

var ghRepo = regexp.MustCompile(`github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$`)

// parseGithubRepo: owner and name from an Argo CD repoURL.
func parseGithubRepo(u string) (string, string, bool) {
	m := ghRepo.FindStringSubmatch(strings.TrimSpace(u))
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// splitDocs splits a multi-document YAML file (--- separators).
var docSep = regexp.MustCompile(`(?m)^---[ \t]*$`)

func splitDocs(text string) []string {
	return docSep.Split(text, -1)
}

// findDoc: the index of the document for kind/name (and namespace, when the
// document says one) in a file, -1 if it isn't there.
func findDoc(docs []string, kind, ns, name string) int {
	for i, d := range docs {
		var m struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"metadata"`
		}
		if yaml.Unmarshal([]byte(d), &m) != nil {
			continue
		}
		if m.Kind == kind && m.Metadata.Name == name && (m.Metadata.Namespace == "" || m.Metadata.Namespace == ns) {
			return i
		}
	}
	return -1
}

// gitSource locates a workload's definition in its Argo CD app's repo.
type gitSource struct {
	App      string `json:"app"`
	Owner    string `json:"owner"`
	Repo     string `json:"repo"`
	Ref      string `json:"ref"`
	Path     string `json:"path"` // the app's folder
	File     string `json:"file"` // the file with the object ("" = not found)
	Doc      int    `json:"doc"`  // which document of the file
	YAML     string `json:"yaml"` // that document
	SHA      string `json:"sha"`  // the file's blob (to update it)
	URL      string `json:"url"`  // on github.com
	Tool     string `json:"tool"` // plain | kustomize | helm
	CanWrite bool   `json:"can_write"`
	text     string // the whole file
}

func (b *Bridge) findGitSource(ctx context.Context, kind, ns, name string) (*gitSource, error) {
	var meta *gitOpsMetaRef
	switch kind {
	case "Deployment", "StatefulSet", "DaemonSet":
		meta = b.gitopsOf(kind, ns, name)
	}
	if meta == nil {
		return nil, errors.New("this object isn't managed by an Argo CD Application the bridge can see")
	}
	var app *ArgoApp
	for _, a := range b.argoApps() {
		if a.Name == meta.Name {
			a := a
			app = &a
		}
	}
	if app == nil {
		return nil, fmt.Errorf("Argo CD app %s not found (the bridge may not be allowed to read Applications)", meta.Name)
	}
	owner, repo, ok := parseGithubRepo(app.Repo)
	if !ok {
		return nil, fmt.Errorf("the app's repository (%s) is not on github.com", app.Repo)
	}
	src := &gitSource{App: app.Name, Owner: owner, Repo: repo, Path: strings.Trim(app.Path, "/"), Doc: -1, Tool: "plain"}
	var info struct {
		DefaultBranch string `json:"default_branch"`
		Permissions   struct {
			Push bool `json:"push"`
		} `json:"permissions"`
	}
	if err := b.gh.call(ctx, "GET", fmt.Sprintf("/repos/%s/%s", owner, repo), nil, &info); err != nil {
		return nil, err
	}
	src.CanWrite = info.Permissions.Push
	src.Ref = b.appRevision(app.Name)
	if src.Ref == "" || src.Ref == "HEAD" {
		src.Ref = info.DefaultBranch
	}
	var tree struct {
		Tree []struct {
			Path string `json:"path"`
			Type string `json:"type"`
		} `json:"tree"`
	}
	if err := b.gh.call(ctx, "GET", fmt.Sprintf("/repos/%s/%s/git/trees/%s?recursive=1", owner, repo, url.PathEscape(src.Ref)), nil, &tree); err != nil {
		return nil, err
	}
	var files []string
	for _, t := range tree.Tree {
		if t.Type != "blob" || (src.Path != "" && !strings.HasPrefix(t.Path, src.Path+"/")) {
			continue
		}
		base := filepath.Base(t.Path)
		switch base {
		case "kustomization.yaml", "kustomization.yml", "Kustomization":
			src.Tool = "kustomize"
		case "Chart.yaml":
			src.Tool = "helm"
		}
		if strings.HasSuffix(base, ".yaml") || strings.HasSuffix(base, ".yml") {
			files = append(files, t.Path)
		}
	}
	sort.Strings(files)
	src.URL = fmt.Sprintf("https://github.com/%s/%s/tree/%s/%s", owner, repo, src.Ref, src.Path)
	for i, f := range files {
		if i >= 60 {
			break
		}
		var c struct {
			Content string `json:"content"`
			SHA     string `json:"sha"`
		}
		if err := b.gh.call(ctx, "GET", fmt.Sprintf("/repos/%s/%s/contents/%s?ref=%s", owner, repo, escapePath(f), url.QueryEscape(src.Ref)), nil, &c); err != nil {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(c.Content, "\n", ""))
		if err != nil {
			continue
		}
		docs := splitDocs(string(raw))
		if i := findDoc(docs, kind, ns, name); i >= 0 {
			src.File, src.Doc, src.SHA, src.text = f, i, c.SHA, string(raw)
			src.YAML = strings.TrimLeft(docs[i], "\n")
			src.URL = fmt.Sprintf("https://github.com/%s/%s/blob/%s/%s", owner, repo, src.Ref, f)
			return src, nil
		}
	}
	return src, nil
}

func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i := range parts {
		parts[i] = url.PathEscape(parts[i])
	}
	return strings.Join(parts, "/")
}

type gitOpsMetaRef struct{ Name string }

func (b *Bridge) gitopsOf(kind, ns, name string) *gitOpsMetaRef {
	var g *GitOps
	switch kind {
	case "Deployment":
		if d, err := b.depLister.Deployments(ns).Get(name); err == nil {
			g = gitOpsOf(d.ObjectMeta)
		}
	case "StatefulSet":
		if d, err := b.stsLister.StatefulSets(ns).Get(name); err == nil {
			g = gitOpsOf(d.ObjectMeta)
		}
	case "DaemonSet":
		if d, err := b.dsLister.DaemonSets(ns).Get(name); err == nil {
			g = gitOpsOf(d.ObjectMeta)
		}
	}
	if g == nil || g.Tool != "argocd" {
		return nil
	}
	return &gitOpsMetaRef{Name: g.Name}
}

// appRevision: the app's targetRevision (branch, tag or commit).
func (b *Bridge) appRevision(app string) string {
	for _, u := range b.dynList("apps") {
		if u.GetName() == app {
			if r, ok := u.Object["spec"].(map[string]any); ok {
				if s, ok := r["source"].(map[string]any); ok {
					v, _ := s["targetRevision"].(string)
					return v
				}
			}
		}
	}
	return ""
}

// GET /api/gitops/source?kind=&ns=&name=: the object in git, and how the
// cluster differs from it.
func (b *Bridge) handleGitSource(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	src, err := b.findGitSource(r.Context(), q.Get("kind"), q.Get("ns"), q.Get("name"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	out := map[string]any{"ok": true, "source": src}
	if src.File != "" {
		// Drift: what the cluster has that git doesn't say (or vice versa).
		if d, err := b.previewApply(r.Context(), src.YAML, q.Get("ns")); err == nil {
			out["drift"] = d
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// previewApply: live object vs what `kubectl apply` of this YAML would leave
// (a server dry run), as a unified diff. That's what Argo CD would do.
func (b *Bridge) previewApply(ctx context.Context, doc, ns string) (string, error) {
	var obj map[string]any
	if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
		return "", fmt.Errorf("the YAML doesn't parse: %v", err)
	}
	md, _ := obj["metadata"].(map[string]any)
	if md == nil {
		return "", errors.New("no metadata")
	}
	if _, ok := md["namespace"]; !ok && ns != "" {
		md["namespace"] = ns
	}
	kind, _ := obj["kind"].(string)
	name, _ := md["name"].(string)
	js, _ := json.Marshal(obj)
	get := []string{"get", strings.ToLower(kind) + "/" + name, "-o", "json"}
	if ns != "" {
		get = append(get, "-n", ns)
	}
	before, err := b.kubectlRun(ctx, nil, get...)
	if err != nil {
		return "", errors.New(strings.TrimSpace(string(before)))
	}
	after, err := b.kubectlRun(ctx, js, "apply", "-f", "-", "--dry-run=server", "-o", "json")
	if err != nil {
		return "", errors.New(strings.TrimSpace(string(after)))
	}
	d, _ := difflib.GetUnifiedDiffString(difflib.UnifiedDiff{A: difflib.SplitLines(diffYAML(before)), B: difflib.SplitLines(diffYAML(after)),
		FromFile: "cluster", ToFile: "after sync", Context: 3})
	return redact(d), nil
}

type gitChange struct {
	Kind    string `json:"kind"`
	NS      string `json:"ns"`
	Name    string `json:"name"`
	YAML    string `json:"yaml"` // the edited document
	Title   string `json:"title"`
	Propose bool   `json:"propose"` // false = only preview
}

// POST /api/gitops/change: preview an edit of the object's git YAML (git
// diff + what Argo would change in the cluster), or propose it as a PR.
func (b *Bridge) handleGitChange(w http.ResponseWriter, r *http.Request) {
	var req gitChange
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	src, err := b.findGitSource(r.Context(), req.Kind, req.NS, req.Name)
	if err == nil && src.File == "" {
		err = fmt.Errorf("its YAML wasn't found in %s/%s:%s (a %s app: the object is generated, edit its sources there)", src.Owner, src.Repo, src.Path, src.Tool)
	}
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	edited := strings.TrimRight(req.YAML, "\n") + "\n"
	gd, _ := difflib.GetUnifiedDiffString(difflib.UnifiedDiff{A: difflib.SplitLines(src.YAML), B: difflib.SplitLines(edited),
		FromFile: src.File + " (git)", ToFile: src.File + " (yours)", Context: 3})
	cluster, perr := b.previewApply(r.Context(), edited, req.NS)
	out := map[string]any{"ok": true, "git_diff": gd, "cluster_diff": cluster, "source": src}
	if perr != nil {
		out["cluster_error"] = perr.Error()
	}
	if !req.Propose {
		writeJSON(w, http.StatusOK, out)
		return
	}
	if gd == "" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "nothing changed"})
		return
	}
	if !src.CanWrite {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "the token can't write to this repository: give it Contents and Pull requests: Read and write to propose changes"})
		return
	}
	pr, err := b.proposePR(r.Context(), src, edited, req)
	b.audit(r, "gitops", fmt.Sprintf("%s %s/%s", req.Kind, req.NS, req.Name), "pull request "+pr, err)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	out["pr"] = pr
	writeJSON(w, http.StatusOK, out)
}

// proposePR: a branch from the app's revision, the file with the document
// replaced, and a pull request back to it.
func (b *Bridge) proposePR(ctx context.Context, src *gitSource, edited string, req gitChange) (string, error) {
	content := replaceDoc(src.text, src.Doc, edited)
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	if err := b.gh.call(ctx, "GET", fmt.Sprintf("/repos/%s/%s/git/ref/heads/%s", src.Owner, src.Repo, url.PathEscape(src.Ref)), nil, &ref); err != nil {
		return "", fmt.Errorf("the app follows %q, not a branch a PR can target: %v", src.Ref, err)
	}
	branch := fmt.Sprintf("kubiverse/%s-%s-%d", strings.ToLower(req.Kind), req.Name, time.Now().Unix())
	if err := b.gh.call(ctx, "POST", fmt.Sprintf("/repos/%s/%s/git/refs", src.Owner, src.Repo), map[string]any{"ref": "refs/heads/" + branch, "sha": ref.Object.SHA}, nil); err != nil {
		return "", err
	}
	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = fmt.Sprintf("Update %s %s/%s", req.Kind, req.NS, req.Name)
	}
	if err := b.gh.call(ctx, "PUT", fmt.Sprintf("/repos/%s/%s/contents/%s", src.Owner, src.Repo, escapePath(src.File)), map[string]any{
		"message": title, "content": base64.StdEncoding.EncodeToString([]byte(content)), "sha": src.SHA, "branch": branch}, nil); err != nil {
		return "", err
	}
	var pr struct {
		HTMLURL string `json:"html_url"`
	}
	body := fmt.Sprintf("Proposed from Kubiverse for Argo CD app `%s`.\n\nChanges `%s %s/%s` in `%s`. After merging, Argo CD syncs it to the cluster.", src.App, req.Kind, req.NS, req.Name, src.File)
	if err := b.gh.call(ctx, "POST", fmt.Sprintf("/repos/%s/%s/pulls", src.Owner, src.Repo), map[string]any{
		"title": title, "head": branch, "base": src.Ref, "body": body}, &pr); err != nil {
		return "", err
	}
	return pr.HTMLURL, nil
}

// replaceDoc puts edited in place of document i of a multi-document file,
// leaving the rest of the file as it was.
func replaceDoc(text string, i int, edited string) string {
	docs := splitDocs(text)
	if i < 0 || i >= len(docs) {
		return text
	}
	lead := ""
	if i > 0 || strings.HasPrefix(docs[i], "\n") {
		lead = "\n"
	}
	docs[i] = lead + edited
	return strings.Join(docs, "---")
}
