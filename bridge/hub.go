package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"k8s.io/client-go/tools/clientcmd"
)

// Hub serves many clusters from one bridge: every kubeconfig context (from
// the usual kubeconfig plus files added from the game) gets its own Bridge,
// started on first use. Clients pick one with ?context=NAME.
type Hub struct {
	root       context.Context
	explicit   string // --kubeconfig
	dir        string // added kubeconfigs (~/.kubecraft/kubeconfigs)
	defaultCtx string
	readOnly   bool
	token      string
	pol        *policy

	mu       sync.Mutex
	clusters map[string]*Bridge
	starting map[string]chan struct{}
	errs     map[string]error
}

type ContextInfo struct {
	Name    string `json:"name"`
	Cluster string `json:"cluster"`
	Server  string `json:"server"`
	Source  string `json:"source"` // "kubeconfig" or the added file's name
	Default bool   `json:"default"`
	Running bool   `json:"running"`
}

func defaultDataDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".kubecraft"
	}
	return filepath.Join(home, ".kubecraft", "kubeconfigs")
}

func newHub(root context.Context, explicit, defaultCtx, dir string, readOnly bool, token string) *Hub {
	h := &Hub{root: root, explicit: explicit, dir: dir, readOnly: readOnly, token: token,
		clusters: map[string]*Bridge{}, starting: map[string]chan struct{}{}, errs: map[string]error{}}
	h.defaultCtx = defaultCtx
	if h.defaultCtx == "" {
		if raw, err := h.defaultRules().Load(); err == nil {
			h.defaultCtx = raw.CurrentContext
		}
	}
	return h
}

func (h *Hub) defaultRules() *clientcmd.ClientConfigLoadingRules {
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	if h.explicit != "" {
		rules.ExplicitPath = h.explicit
	}
	return rules
}

// contexts lists every context the bridge can serve and, for each, the
// kubeconfig file it comes from ("" = the default kubeconfig).
// ctxRef: where a listed context really lives (file "" = default kubeconfig)
// and its name inside that file.
type ctxRef struct {
	path string
	ctx  string
}

func (h *Hub) contexts() ([]ContextInfo, map[string]ctxRef) {
	var out []ContextInfo
	files := map[string]ctxRef{}
	seen := map[string]bool{}
	if raw, err := h.defaultRules().Load(); err == nil {
		for name, c := range raw.Contexts {
			srv := ""
			if cl, ok := raw.Clusters[c.Cluster]; ok {
				srv = cl.Server
			}
			out = append(out, ContextInfo{Name: name, Cluster: c.Cluster, Server: srv, Source: "kubeconfig"})
			seen[name] = true
			files[name] = ctxRef{"", name}
		}
	}
	entries, _ := os.ReadDir(h.dir)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".yaml") {
			continue
		}
		path := filepath.Join(h.dir, e.Name())
		raw, err := clientcmd.LoadFromFile(path)
		if err != nil {
			continue
		}
		for ctx, c := range raw.Contexts {
			// Many kubeconfigs reuse names like "default": on a clash the
			// added one is listed as "<file>/<context>" instead of hidden.
			name := ctx
			if seen[name] {
				name = strings.TrimSuffix(e.Name(), ".yaml") + "/" + ctx
			}
			if seen[name] {
				continue
			}
			srv := ""
			if cl, ok := raw.Clusters[c.Cluster]; ok {
				srv = cl.Server
			}
			out = append(out, ContextInfo{Name: name, Cluster: c.Cluster, Server: srv, Source: e.Name()})
			seen[name] = true
			files[name] = ctxRef{path, ctx}
		}
	}
	h.mu.Lock()
	for i := range out {
		out[i].Default = out[i].Name == h.defaultCtx
		_, out[i].Running = h.clusters[out[i].Name]
	}
	h.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, files
}

// get returns the running Bridge for a context, starting it if needed.
func (h *Hub) get(name string) (*Bridge, error) {
	if name == "" {
		name = h.defaultCtx
	}
	for {
		h.mu.Lock()
		if b, ok := h.clusters[name]; ok {
			h.mu.Unlock()
			return b, nil
		}
		if ch, ok := h.starting[name]; ok {
			h.mu.Unlock()
			<-ch
			h.mu.Lock()
			err := h.errs[name]
			h.mu.Unlock()
			if err != nil {
				return nil, err
			}
			continue
		}
		ch := make(chan struct{})
		h.starting[name] = ch
		h.mu.Unlock()

		b, err := h.start(name)
		h.mu.Lock()
		delete(h.starting, name)
		if err == nil {
			h.clusters[name] = b
			delete(h.errs, name)
		} else {
			h.errs[name] = err
		}
		h.mu.Unlock()
		close(ch)
		return b, err
	}
}

func (h *Hub) start(name string) (*Bridge, error) {
	_, files := h.contexts()
	ref, ok := files[name]
	if !ok {
		return nil, fmt.Errorf("unknown context %q", name)
	}
	rules := h.defaultRules()
	kubectlPath := h.explicit
	if ref.path != "" {
		rules = &clientcmd.ClientConfigLoadingRules{ExplicitPath: ref.path}
		kubectlPath = ref.path
	}
	cc := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, &clientcmd.ConfigOverrides{CurrentContext: ref.ctx})
	b, err := startBridge(h.root, cc, name, kubectlPath, h.readOnly)
	if b != nil {
		b.kubectlContext = ref.ctx
		b.pol = h.pol
	}
	return b, err
}

func (h *Hub) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if h.token != "" {
			t := r.Header.Get("X-Bridge-Token")
			if t == "" {
				t = r.URL.Query().Get("token")
			}
			if t != h.token {
				http.Error(w, "invalid token", http.StatusUnauthorized)
				return
			}
		}
		next(w, r)
	}
}

// cluster adapts a per-cluster handler: it picks the Bridge for ?context=.
func (h *Hub) cluster(fn func(*Bridge, http.ResponseWriter, *http.Request)) http.HandlerFunc {
	return h.auth(func(w http.ResponseWriter, r *http.Request) {
		b, err := h.get(r.URL.Query().Get("context"))
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"ok": false, "error": err.Error(), "output": "error: " + err.Error()})
			return
		}
		fn(b, w, r)
	})
}

func (h *Hub) handleContexts(w http.ResponseWriter, r *http.Request) {
	list, _ := h.contexts()
	if list == nil {
		list = []ContextInfo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "default": h.defaultCtx, "contexts": list})
}

var fileName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$`)

// handleAddKubeconfig stores a pasted kubeconfig (0600, in the data dir) so
// its contexts can be played. Only localhost clients reach this (see guard).
func (h *Hub) handleAddKubeconfig(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name    string `json:"name"`
		Content string `json:"content"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	req.Name = strings.TrimSuffix(strings.TrimSpace(req.Name), ".yaml")
	if !fileName.MatchString(req.Name) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "invalid name (letters, digits, . _ -)"})
		return
	}
	cfg, err := clientcmd.Load([]byte(req.Content))
	if err == nil && len(cfg.Contexts) == 0 {
		err = errors.New("the kubeconfig has no contexts")
	}
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "invalid kubeconfig: " + err.Error()})
		return
	}
	if err := os.MkdirAll(h.dir, 0o700); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	path := filepath.Join(h.dir, req.Name+".yaml")
	if err := os.WriteFile(path, []byte(req.Content), 0o600); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	// The names as the game will see them (renamed on clashes).
	var names []string
	list, _ := h.contexts()
	for _, c := range list {
		if c.Source == req.Name+".yaml" {
			names = append(names, c.Name)
		}
	}
	sort.Strings(names)
	log.Printf("kubeconfig %s added with contexts %v", path, names)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "contexts": names})
}

func (h *Hub) handleDeleteKubeconfig(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSuffix(r.URL.Query().Get("name"), ".yaml")
	if !fileName.MatchString(name) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "invalid name"})
		return
	}
	if err := os.Remove(filepath.Join(h.dir, name+".yaml")); err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
