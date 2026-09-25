package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// Team mode: the bridge runs in the cluster behind an OIDC proxy (oauth2-proxy,
// an ingress with external auth...) that sets the signed-in user and groups
// in headers. Everything the bridge SHOWS comes from its own ServiceAccount
// (read-only), and everything a player CHANGES is done impersonating that
// player, so the cluster's RBAC decides and the API server's audit log names
// the real person.

type identity struct {
	User   string
	Groups []string
}

type identityKey struct{}

func withIdentity(r *http.Request, id identity) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), identityKey{}, id))
}

func identityFrom(ctx context.Context) identity {
	id, _ := ctx.Value(identityKey{}).(identity)
	return id
}

// identityFromHeaders reads the proxy's headers (empty user = not signed in).
func identityFromHeaders(r *http.Request, userHeader, groupsHeader string) identity {
	id := identity{User: strings.TrimSpace(r.Header.Get(userHeader))}
	if groupsHeader != "" {
		for _, g := range strings.Split(r.Header.Get(groupsHeader), ",") {
			if g = strings.TrimSpace(g); g != "" {
				id.Groups = append(id.Groups, g)
			}
		}
	}
	return id
}

// impersonation clients, per user+groups (built on first use).
type impersonators struct {
	mu   sync.Mutex
	list map[string]kubernetes.Interface
}

// restFor: the bridge's REST config, impersonating the request's user.
func (b *Bridge) restFor(ctx context.Context) *rest.Config {
	id := identityFrom(ctx)
	if id.User == "" || b.restCfg == nil {
		return b.restCfg
	}
	cfg := rest.CopyConfig(b.restCfg)
	cfg.Impersonate = rest.ImpersonationConfig{UserName: id.User, Groups: id.Groups}
	return cfg
}

// clientFor: the clientset changes are made with (the player, in team mode).
func (b *Bridge) clientFor(ctx context.Context) kubernetes.Interface {
	id := identityFrom(ctx)
	if id.User == "" || b.restCfg == nil {
		return b.cs
	}
	key := id.User + "|" + strings.Join(id.Groups, ",")
	b.imp.mu.Lock()
	defer b.imp.mu.Unlock()
	if b.imp.list == nil {
		b.imp.list = map[string]kubernetes.Interface{}
	}
	if cs, ok := b.imp.list[key]; ok {
		return cs
	}
	cs, err := kubernetes.NewForConfig(b.restFor(ctx))
	if err != nil {
		return b.cs
	}
	b.imp.list[key] = cs
	return cs
}

// kubectlBase: the flags every kubectl run starts with: the cluster (not in
// the cluster itself), the kubeconfig, the player to impersonate, a timeout.
func (b *Bridge) kubectlBase(ctx context.Context, timeout string) []string {
	var args []string
	if !b.inCluster {
		args = append(args, "--context", b.kubectlCtx())
	}
	args = append(args, "--request-timeout="+timeout)
	if b.kubeconfigPath != "" {
		args = append(args, "--kubeconfig", b.kubeconfigPath)
	}
	if id := identityFrom(ctx); id.User != "" {
		args = append(args, "--as", id.User)
		for _, g := range id.Groups {
			args = append(args, "--as-group", g)
		}
	}
	return args
}

// GET /api/whoami: who the game is acting as.
func (h *Hub) handleWhoami(w http.ResponseWriter, r *http.Request) {
	id := identityFrom(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "team": h.userHeader != "", "user": id.User, "groups": id.Groups, "in_cluster": h.inCluster})
}

// inClusterKubeconfig writes a kubeconfig for kubectl that points at the
// ServiceAccount's token and CA files (no secret copied): kubectl only falls
// back to the in-cluster config when no flag changes it, and we pass --as.
func inClusterKubeconfig(cfg *rest.Config) (string, error) {
	tokenFile := cfg.BearerTokenFile
	if tokenFile == "" {
		tokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	}
	body := fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: %q
    certificate-authority: %q
users:
- name: bridge
  user:
    tokenFile: %q
contexts:
- name: in-cluster
  context: {cluster: in-cluster, user: bridge}
current-context: in-cluster
`, cfg.Host, cfg.TLSClientConfig.CAFile, tokenFile)
	path := filepath.Join(os.TempDir(), "kubiverse-in-cluster.kubeconfig")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		return "", fmt.Errorf("kubectl kubeconfig: %w", err)
	}
	return path, nil
}
