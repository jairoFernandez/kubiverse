package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"time"
)

// The in-game terminal runs real kubectl commands on the bridge host, always
// against the bridge's kubeconfig/context. No shell is involved: the line is
// split into arguments and passed straight to the kubectl binary. Commands
// that are interactive, stream forever, switch clusters or read local files
// are refused.

const maxOutput = 256 << 10

var blockedVerbs = map[string]string{
	"edit":         "interactive editor",
	"exec":         "interactive (use the Logs viewer or a real terminal)",
	"attach":       "interactive",
	"port-forward": "long-running",
	"proxy":        "long-running",
	"debug":        "interactive",
	"cp":           "reads/writes local files",
	"config":       "could reveal credentials",
	"plugin":       "runs local binaries",
	"completion":   "not useful here",
	"kustomize":    "reads local files",
	"alpha":        "not supported",
}

// Read-only verbs allowed when the bridge runs with --readonly.
var readOnlyVerbs = map[string]bool{
	"get": true, "describe": true, "logs": true, "top": true, "explain": true,
	"api-resources": true, "api-versions": true, "version": true,
	"cluster-info": true, "events": true, "auth": true, "wait": true,
}

var blockedFlags = []string{
	"--kubeconfig", "--context", "--cluster", "--user", "--token", "--server", "-s",
	"--as", "--as-group", "--as-uid", "--certificate-authority", "--client-key",
	"--client-certificate", "--insecure-skip-tls-verify", "-f", "--filename",
	"-k", "--kustomize", "-w", "--watch", "--watch-only", "-i", "--stdin", "-t", "--tty",
	"--follow", "-R", "--recursive",
}

type kubectlRequest struct {
	Line string `json:"line"`
}

// splitArgs splits a command line into arguments, honouring single and
// double quotes and backslash escapes (like a shell, but without expansion).
func splitArgs(line string) ([]string, error) {
	var args []string
	var cur strings.Builder
	inArg := false
	var quote rune
	escaped := false
	for _, r := range line {
		switch {
		case escaped:
			cur.WriteRune(r)
			escaped = false
		case r == '\\' && quote != '\'':
			escaped = true
			inArg = true
		case quote != 0:
			if r == quote {
				quote = 0
			} else {
				cur.WriteRune(r)
			}
		case r == '\'' || r == '"':
			quote = r
			inArg = true
		case r == ' ' || r == '\t' || r == '\n':
			if inArg {
				args = append(args, cur.String())
				cur.Reset()
				inArg = false
			}
		case strings.ContainsRune("|;&`$<>", r):
			return nil, fmt.Errorf("shell syntax (%q) is not supported: one kubectl command at a time", r)
		default:
			cur.WriteRune(r)
			inArg = true
		}
	}
	if quote != 0 {
		return nil, errors.New("unterminated quote")
	}
	if inArg {
		args = append(args, cur.String())
	}
	return args, nil
}

// validateArgs checks a kubectl argument list (without the leading "kubectl").
func validateArgs(args []string, readOnly bool) error {
	if len(args) == 0 {
		return errors.New("empty command")
	}
	verb := ""
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			verb = a
			break
		}
	}
	if verb == "" {
		return errors.New("missing command, e.g. 'get pods'")
	}
	if why, ok := blockedVerbs[verb]; ok {
		return fmt.Errorf("'kubectl %s' is not available in the game terminal (%s)", verb, why)
	}
	if readOnly && !readOnlyVerbs[verb] {
		return fmt.Errorf("the bridge is read-only: 'kubectl %s' is not allowed", verb)
	}
	for _, a := range args {
		name := a
		if i := strings.Index(a, "="); i > 0 {
			name = a[:i]
		}
		for _, b := range blockedFlags {
			// "-f" also matches "-f" for logs --follow, which is intended.
			if name == b {
				return fmt.Errorf("flag %s is not allowed in the game terminal", b)
			}
		}
	}
	return nil
}

func (b *Bridge) handleKubectl(w http.ResponseWriter, r *http.Request) {
	var req kubectlRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<14)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "output": "bad json"})
		return
	}
	args, err := splitArgs(strings.TrimSpace(req.Line))
	if err == nil && len(args) > 0 && args[0] == "kubectl" {
		args = args[1:]
	}
	if err == nil {
		err = validateArgs(args, b.readOnly)
	}
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "output": "error: " + err.Error()})
		return
	}
	// Commands that change the cluster: production needs the confirmation,
	// and every one of them goes to the audit log.
	mutating := validateArgs(args, true) != nil
	if mutating {
		if perr := b.pol.check(r, b.contextName); perr != nil {
			b.audit(r, "kubectl", strings.Join(args, " "), "kubectl "+strings.Join(args, " "), perr)
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "output": "error: " + perr.Error()})
			return
		}
	}
	bin, err := exec.LookPath("kubectl")
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "output": "error: kubectl is not installed on the bridge host"})
		return
	}
	full := b.kubectlBase(r.Context(), "15s")
	full = append(full, args...)
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, full...)
	var out bytes.Buffer
	cmd.Stdout = &limitWriter{w: &out, n: maxOutput}
	cmd.Stderr = cmd.Stdout
	runErr := cmd.Run()
	code := 0
	var ee *exec.ExitError
	if errors.As(runErr, &ee) {
		code = ee.ExitCode()
	} else if runErr != nil {
		code = -1
		out.WriteString(runErr.Error())
	}
	log.Printf("terminal: kubectl %s -> exit %d", strings.Join(args, " "), code)
	if mutating {
		var aerr error
		if code != 0 {
			aerr = fmt.Errorf("exit %d: %s", code, clip(out.String(), 200))
		}
		b.audit(r, "kubectl", strings.Join(args, " "), "kubectl "+strings.Join(args, " "), aerr)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": code == 0, "exit_code": code, "output": out.String()})
}

type limitWriter struct {
	w *bytes.Buffer
	n int
}

func (l *limitWriter) Write(p []byte) (int, error) {
	if room := l.n - l.w.Len(); room > 0 {
		if len(p) > room {
			l.w.Write(p[:room])
			l.w.WriteString("\n... (output truncated)")
		} else {
			l.w.Write(p)
		}
	}
	return len(p), nil
}
