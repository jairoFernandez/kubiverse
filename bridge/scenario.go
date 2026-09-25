package main

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os/exec"
	"time"
)

// Sample workloads for the sandbox missions (broken image, a pod with no
// room, crash loops, OOM, a broken ingress route...). Same file as
// `make scenario`.
//
//go:embed scenarios/*.yaml
var scenarios embed.FS

type scenarioRequest struct {
	Name   string `json:"name"`
	Remove bool   `json:"remove"`
}

// handleScenario applies (or deletes) a bundled scenario with kubectl, so it
// works on any cluster the bridge reaches. The game only offers it on
// clusters the player marked as a sandbox.
func (b *Bridge) handleScenario(w http.ResponseWriter, r *http.Request) {
	var req scenarioRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	if b.readOnly {
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "bridge is in read-only mode"})
		return
	}
	if b.pol != nil {
		if kind, _ := b.pol.kind(b.contextName); kind != "sandbox" {
			err := errors.New("the sample scenario is only deployed on clusters marked sandbox")
			b.audit(r, "scenario", req.Name, "apply", err)
			writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": err.Error()})
			return
		}
	}
	manifest, err := scenarios.ReadFile("scenarios/" + req.Name + ".yaml")
	if err != nil || req.Name == "" {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "unknown scenario"})
		return
	}
	bin, err := exec.LookPath("kubectl")
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "kubectl is not installed on the bridge host"})
		return
	}
	args := []string{"--context", b.kubectlCtx(), "--request-timeout=30s"}
	if b.kubeconfigPath != "" {
		args = append(args, "--kubeconfig", b.kubeconfigPath)
	}
	if req.Remove {
		args = append(args, "delete", "--ignore-not-found", "--wait=false", "-f", "-")
	} else {
		args = append(args, "apply", "-f", "-")
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stdin = bytes.NewReader(manifest)
	var out bytes.Buffer
	cmd.Stdout = &limitWriter{w: &out, n: maxOutput}
	cmd.Stderr = cmd.Stdout
	runErr := cmd.Run()
	var ee *exec.ExitError
	if runErr != nil && !errors.As(runErr, &ee) {
		out.WriteString(runErr.Error())
	}
	log.Printf("scenario %s (remove=%v) -> %v", req.Name, req.Remove, runErr)
	b.audit(r, "scenario", req.Name, map[bool]string{true: "delete", false: "apply"}[req.Remove], runErr)
	writeJSON(w, http.StatusOK, map[string]any{"ok": runErr == nil, "output": out.String()})
}
