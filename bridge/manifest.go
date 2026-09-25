package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/pmezard/go-difflib/difflib"
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
	full := b.kubectlBase(ctx, "15s")
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
	Diff   bool   `json:"diff"` // what would change (a server dry-run), nothing applied
}

func (b *Bridge) handleManifestPut(w http.ResponseWriter, r *http.Request) {
	var req manifestPut
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	if req.Diff {
		req.DryRun = true
	}
	if b.readOnly && !req.DryRun {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "the bridge is read-only"})
		return
	}
	if !req.DryRun {
		if err := b.pol.check(r, b.contextName); err != nil {
			b.audit(r, "manifest", req.Kind+" "+req.NS+"/"+req.Name, "replace", err)
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
			return
		}
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
	if req.Diff {
		b.manifestDiff(w, r, js, kind, ns, req.Name)
		return
	}
	args := []string{"replace", "-f", "-", "-o", "name"}
	if req.DryRun {
		args = append(args, "--dry-run=server")
	}
	out, err := b.kubectlRun(r.Context(), js, args...)
	msg := strings.TrimSpace(string(out))
	if !req.DryRun {
		var aerr error
		if err != nil {
			aerr = errors.New(msg)
		}
		b.audit(r, "manifest", req.Kind+" "+req.NS+"/"+req.Name, "replace (in-game YAML editor)", aerr)
	}
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

// manifestDiff: the object now and as the server would leave it (dry-run),
// as a unified diff of their YAML without the fields that always move.
func (b *Bridge) manifestDiff(w http.ResponseWriter, r *http.Request, js []byte, kind, ns, name string) {
	get := []string{"get", strings.ToLower(kind) + "/" + name, "-o", "json"}
	if ns != "" {
		get = append(get, "-n", ns)
	}
	before, err := b.kubectlRun(r.Context(), nil, get...)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": strings.TrimSpace(string(before))})
		return
	}
	// Against what is live now: the editor's resourceVersion may be old (the
	// controllers write status all the time) and a diff changes nothing.
	var obj map[string]any
	if json.Unmarshal(js, &obj) == nil {
		if md, ok := obj["metadata"].(map[string]any); ok {
			delete(md, "resourceVersion")
		}
		js, _ = json.Marshal(obj)
	}
	after, err := b.kubectlRun(r.Context(), js, "replace", "-f", "-", "--dry-run=server", "-o", "json")
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": strings.TrimSpace(string(after))})
		return
	}
	a, b2 := diffYAML(before), diffYAML(after)
	d, _ := difflib.GetUnifiedDiffString(difflib.UnifiedDiff{A: difflib.SplitLines(a), B: difflib.SplitLines(b2),
		FromFile: "live", ToFile: "edited", Context: 3})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "diff": redact(d), "changed": d != ""})
}

// diffYAML: an object as YAML minus what changes on every write.
func diffYAML(raw []byte) string {
	var obj map[string]any
	if json.Unmarshal(raw, &obj) != nil {
		return string(raw)
	}
	delete(obj, "status")
	if md, ok := obj["metadata"].(map[string]any); ok {
		for _, k := range []string{"managedFields", "resourceVersion", "generation", "uid", "creationTimestamp"} {
			delete(md, k)
		}
		if an, ok := md["annotations"].(map[string]any); ok {
			delete(an, lastApplied)
			delete(an, "deployment.kubernetes.io/revision")
			if len(an) == 0 {
				delete(md, "annotations")
			}
		}
	}
	out, err := yaml.Marshal(obj)
	if err != nil {
		return string(raw)
	}
	return string(out)
}
