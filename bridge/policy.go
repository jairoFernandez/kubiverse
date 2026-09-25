package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ConfirmHeader must carry the context name on every change to a production
// cluster: the game sends it only after the player said yes in a dialog that
// says PRODUCTION. Enforced here, so no client can skip it.
const ConfirmHeader = "X-Kubiverse-Confirm"

// policy keeps the kind of each context (prod | sandbox), shared by every
// client of this bridge, and the audit log of what clients changed.
type policy struct {
	mu     sync.Mutex
	path   string            // cluster-kinds.json
	kinds  map[string]string // context -> prod | sandbox
	locked map[string]bool   // set with --production: the game can't change them
	audit  *auditLog
}

func newPolicy(dataDir string, production []string) *policy {
	p := &policy{path: filepath.Join(dataDir, "cluster-kinds.json"), kinds: map[string]string{}, locked: map[string]bool{},
		audit: newAuditLog(filepath.Join(dataDir, "actions.log"))}
	if raw, err := os.ReadFile(p.path); err == nil {
		_ = json.Unmarshal(raw, &p.kinds)
	}
	for _, c := range production {
		if c = strings.TrimSpace(c); c != "" {
			p.kinds[c] = "prod"
			p.locked[c] = true
		}
	}
	return p
}

// kind of a context: "prod", "sandbox" or "" (not set yet: treated as prod).
func (p *policy) kind(ctx string) (string, bool) {
	if p == nil {
		return "", false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.kinds[ctx], p.locked[ctx]
}

func (p *policy) setKind(ctx, kind string) error {
	if kind != "prod" && kind != "sandbox" {
		return errors.New("kind must be prod or sandbox")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.locked[ctx] {
		return errors.New("this context is marked production by the bridge (--production)")
	}
	p.kinds[ctx] = kind
	raw, _ := json.MarshalIndent(p.kinds, "", "  ")
	_ = os.MkdirAll(filepath.Dir(p.path), 0o700)
	return os.WriteFile(p.path, raw, 0o600)
}

// check allows a change: sandboxes always, production (or unknown) only with
// the confirmation header naming that context.
func (p *policy) check(r *http.Request, ctx string) error {
	if p == nil {
		return nil // no policy (unit tests, embedded use): nothing enforced
	}
	kind, _ := p.kind(ctx)
	if kind == "sandbox" {
		return nil
	}
	if r.Header.Get(ConfirmHeader) == ctx {
		return nil
	}
	return errors.New("production cluster: this change needs a confirmation (the game asks; API clients send " + ConfirmHeader + ": " + ctx + ")")
}

// confirmed reports whether a change carried the production confirmation.
func confirmed(r *http.Request, ctx string) bool {
	return r.Header.Get(ConfirmHeader) == ctx
}

// ---------------------------------------------------------------- audit

// AuditEntry is one line of ~/.kubecraft/actions.log (JSON lines).
type AuditEntry struct {
	Time      string `json:"time"`
	Context   string `json:"context"`
	Kind      string `json:"cluster_kind"` // prod | sandbox | "" (unknown = prod)
	Client    string `json:"client"`       // IP of the game / API client
	Agent     string `json:"agent"`
	User      string `json:"user,omitempty"` // impersonated user (team mode)
	What      string `json:"what"`           // action | manifest | kubectl | scenario | portforward | kind
	Target    string `json:"target"`
	Detail    string `json:"detail,omitempty"`
	OK        bool   `json:"ok"`
	Error     string `json:"error,omitempty"`
	Confirmed bool   `json:"confirmed"`
}

type auditLog struct {
	mu   sync.Mutex
	path string
	ring []AuditEntry // the last few hundred, for /api/audit
}

const auditMaxBytes = 5 << 20

func newAuditLog(path string) *auditLog {
	a := &auditLog{path: path}
	// Load the tail of an existing log so the game shows history after a restart.
	if f, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			var e AuditEntry
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				a.ring = append(a.ring, e)
				if len(a.ring) > 500 {
					a.ring = a.ring[len(a.ring)-500:]
				}
			}
		}
		f.Close()
	}
	return a
}

func (a *auditLog) record(e AuditEntry) {
	e.Time = time.Now().Format(time.RFC3339)
	e.Detail = clip(redact(e.Detail), 500)
	e.Error = clip(e.Error, 300)
	a.mu.Lock()
	defer a.mu.Unlock()
	a.ring = append(a.ring, e)
	if len(a.ring) > 500 {
		a.ring = a.ring[len(a.ring)-500:]
	}
	if st, err := os.Stat(a.path); err == nil && st.Size() > auditMaxBytes {
		_ = os.Rename(a.path, a.path+".1")
	}
	_ = os.MkdirAll(filepath.Dir(a.path), 0o700)
	f, err := os.OpenFile(a.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("audit log: %v", err)
		return
	}
	defer f.Close()
	line, _ := json.Marshal(e)
	f.Write(append(line, '\n'))
}

func (a *auditLog) last(n int, ctx string) []AuditEntry {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := []AuditEntry{}
	for i := len(a.ring) - 1; i >= 0 && len(out) < n; i-- {
		if ctx == "" || a.ring[i].Context == ctx {
			out = append(out, a.ring[i])
		}
	}
	return out
}

// audit records a change made through this bridge (and logs it).
func (b *Bridge) audit(r *http.Request, what, target, detail string, err error) {
	if b.pol == nil {
		return
	}
	kind, _ := b.pol.kind(b.contextName)
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	e := AuditEntry{Context: b.contextName, Kind: kind, Client: ip, Agent: shortAgent(r.UserAgent()), User: identityFrom(r.Context()).User,
		What: what, Target: target, Detail: detail, OK: err == nil, Confirmed: confirmed(r, b.contextName)}
	if err != nil {
		e.Error = err.Error()
	}
	b.pol.audit.record(e)
}

// GET /api/kind?context=  ·  POST /api/kind {"context","kind"}
func (h *Hub) handleKind(w http.ResponseWriter, r *http.Request) {
	ctx := r.URL.Query().Get("context")
	if r.Method == http.MethodPost {
		var req struct {
			Context string `json:"context"`
			Kind    string `json:"kind"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
			return
		}
		ctx = req.Context
		if ctx == "" {
			ctx = h.defaultCtx
		}
		if err := h.pol.setKind(ctx, req.Kind); err != nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		ip, _, _ := net.SplitHostPort(r.RemoteAddr)
		h.pol.audit.record(AuditEntry{Context: ctx, Kind: req.Kind, Client: ip, Agent: shortAgent(r.UserAgent()), What: "kind", Target: ctx, Detail: "marked as " + req.Kind, OK: true})
	}
	if ctx == "" {
		ctx = h.defaultCtx
	}
	kind, locked := h.pol.kind(ctx)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "context": ctx, "kind": kind, "locked": locked})
}

// GET /api/audit?limit=&context=
func (h *Hub) handleAudit(w http.ResponseWriter, r *http.Request) {
	n, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if n <= 0 || n > 500 {
		n = 100
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "entries": h.pol.audit.last(n, r.URL.Query().Get("context")), "file": h.pol.audit.path})
}

// ---------------------------------------------------------------- redaction

var redactions = []struct {
	re   *regexp.Regexp
	with string
}{
	{regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`), "[REDACTED PRIVATE KEY]"},
	{regexp.MustCompile(`(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}`), "$1 [REDACTED]"},
	{regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b`), "[REDACTED JWT]"},
	{regexp.MustCompile(`\b(AKIA|ASIA)[0-9A-Z]{16}\b`), "[REDACTED AWS KEY]"},
	{regexp.MustCompile(`\b(ghp|gho|ghs|github_pat|glpat|xox[abpr])[-_][A-Za-z0-9_-]{10,}`), "[REDACTED TOKEN]"},
	{regexp.MustCompile(`(?i)\b([a-z0-9_.-]*(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)[a-z0-9_.-]*)(\s*[:=]\s*|"\s*:\s*")("?)[^\s"',}]{3,}`), "$1$3$4[REDACTED]"},
	{regexp.MustCompile(`(?i)(://[^:/\s@]+:)[^@/\s]+@`), "$1[REDACTED]@"},
}

// redact hides credentials in text that leaves the bridge (to the AI model,
// to the audit log): tokens, passwords, keys, JWTs, credentials in URLs.
func redact(s string) string {
	for _, r := range redactions {
		s = r.re.ReplaceAllString(s, r.with)
	}
	return s
}
