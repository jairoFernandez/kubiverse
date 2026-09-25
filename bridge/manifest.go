package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"sigs.k8s.io/yaml"
)

// The in-game manifest editor. GET returns an object as YAML without the
// noise (status, managedFields, the last-applied annotation); POST replaces
// it with the edited YAML (optionally as a server-side dry run first). The
// edit must stay on the same object: kind, name and namespace can't change.
// Secrets are not editable here (their values would be shown on screen).

var editableKinds = map[string]string{
	"deployment": "Deployment", "statefulset": "StatefulSet", "daemonset": "DaemonSet",
	"service": "Service", "configmap": "ConfigMap", "pod": "Pod", "job": "Job",
	"cronjob": "CronJob", "node": "Node", "namespace": "Namespace",
}

var clusterScoped = map[string]bool{"Node": true, "Namespace": true}

const lastApplied = "kubectl.kubernetes.io/last-applied-configuration"

func (b *Bridge) kubectlRun(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	bin, err := exec.LookPath("kubectl")
	if err != nil {
		return nil, errors.New("kubectl is not installed on the bridge host")
	}
	full := []string{"--context", b.contextName, "--request-timeout=15s"}
	if b.kubeconfigPath != "" {
		full = append(full, "--kubeconfig", b.kubeconfigPath)
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, append(full, args...)...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &limitWriter{w: &out, n: maxOutput}
	cmd.Stderr = cmd.Stdout
	err = cmd.Run()
	return out.Bytes(), err
}

func manifestTarget(kind, ns, name string) (string, string, error) {
	k, ok := editableKinds[strings.ToLower(kind)]
	if !ok {
		return "", "", fmt.Errorf("%s objects can't be edited here", kind)
	}
	if name == "" || strings.ContainsAny(name+ns, " /\\") {
		return "", "", errors.New("bad name")
	}
	if clusterScoped[k] {
		ns = ""
	}
	return k, ns, nil
}

func (b *Bridge) getObject(ctx context.Context, kind, ns, name string) (map[string]any, error) {
	args := []string{"get", strings.ToLower(kind) + "/" + name, "-o", "json"}
	if ns != "" {
		args = append(args, "-n", ns)
	}
	raw, err := b.kubectlRun(ctx, nil, args...)
	if err != nil {
		return nil, errors.New(strings.TrimSpace(string(raw)))
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, err
	}
	return obj, nil
}

// cleanObject removes what a human doesn't edit.
func cleanObject(obj map[string]any) {
	delete(obj, "status")
	if md, ok := obj["metadata"].(map[string]any); ok {
		delete(md, "managedFields")
		if an, ok := md["annotations"].(map[string]any); ok {
			delete(an, lastApplied)
			if len(an) == 0 {
				delete(md, "annotations")
			}
		}
	}
}

func (b *Bridge) handleManifestGet(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kind, ns, err := manifestTarget(q.Get("kind"), q.Get("ns"), q.Get("name"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	obj, err := b.getObject(r.Context(), kind, ns, q.Get("name"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	cleanObject(obj)
	js, _ := json.Marshal(obj)
	y, err := yaml.JSONToYAML(js)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "yaml": string(y), "readonly": b.readOnly})
}

type manifestPut struct {
	Kind   string `json:"kind"`
	NS     string `json:"ns"`
	Name   string `json:"name"`
	YAML   string `json:"yaml"`
	DryRun bool   `json:"dry_run"`
}

func (b *Bridge) handleManifestPut(w http.ResponseWriter, r *http.Request) {
	var req manifestPut
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	if b.readOnly && !req.DryRun {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "the bridge is read-only"})
		return
	}
	kind, ns, err := manifestTarget(req.Kind, req.NS, req.Name)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	js, err := prepareEdited(req.YAML, kind, ns, req.Name)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	// Keep the hidden last-applied annotation so later `kubectl apply` works.
	if cur, err := b.getObject(r.Context(), kind, ns, req.Name); err == nil {
		js = restoreLastApplied(js, cur)
	}
	args := []string{"replace", "-f", "-", "-o", "name"}
	if req.DryRun {
		args = append(args, "--dry-run=server")
	}
	out, err := b.kubectlRun(r.Context(), js, args...)
	msg := strings.TrimSpace(string(out))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": msg})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": msg, "dry_run": req.DryRun})
}

// prepareEdited parses the edited YAML and checks it is still the same object.
func prepareEdited(src, kind, ns, name string) ([]byte, error) {
	js, err := yaml.YAMLToJSON([]byte(src))
	if err != nil {
		return nil, fmt.Errorf("YAML error: %v", err)
	}
	var obj map[string]any
	if err := json.Unmarshal(js, &obj); err != nil || obj == nil {
		return nil, errors.New("the manifest must be a single YAML object")
	}
	if k, _ := obj["kind"].(string); k != kind {
		return nil, fmt.Errorf("kind must stay %s", kind)
	}
	md, _ := obj["metadata"].(map[string]any)
	if md == nil {
		return nil, errors.New("metadata is missing")
	}
	if n, _ := md["name"].(string); n != name {
		return nil, fmt.Errorf("metadata.name must stay %s (create a new object instead)", name)
	}
	if !clusterScoped[kind] {
		if n, _ := md["namespace"].(string); n != "" && n != ns {
			return nil, fmt.Errorf("metadata.namespace must stay %s", ns)
		}
		md["namespace"] = ns
	}
	return json.Marshal(obj)
}

func restoreLastApplied(js []byte, cur map[string]any) []byte {
	cmd, _ := cur["metadata"].(map[string]any)
	can, _ := cmd["annotations"].(map[string]any)
	la, ok := can[lastApplied]
	if !ok {
		return js
	}
	var obj map[string]any
	if json.Unmarshal(js, &obj) != nil {
		return js
	}
	md, _ := obj["metadata"].(map[string]any)
	an, _ := md["annotations"].(map[string]any)
	if an == nil {
		an = map[string]any{}
		md["annotations"] = an
	}
	if _, has := an[lastApplied]; !has {
		an[lastApplied] = la
	}
	out, _ := json.Marshal(obj)
	return out
}
