package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/tools/cache"
)

// WATCHTOWER mode: who is using the cluster. Kubernetes has no "who is
// connected" API, so three sources are combined:
//   audit   the API server's audit log (real identities: user, groups, source
//           IP, client). Needs audit logging enabled on the cluster; the
//           bridge tails <audit-dir>/<context>/**/audit.log.
//   fields  managedFields on objects: which *tool* last changed something
//           (kubectl-edit, helm, argocd...). Works on any cluster, no identity.
//   player  Kubiverse clients connected to this bridge.

var auditDir = defaultAuditDir()

func defaultAuditDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".kubecraft", "audit")
}

type Visitor struct {
	Key        string   `json:"key"`
	User       string   `json:"user"`
	Groups     []string `json:"groups,omitempty"`
	Agent      string   `json:"agent"`
	IPs        []string `json:"ips,omitempty"`
	Source     string   `json:"source"` // audit | fields | player
	First      int64    `json:"first"`
	Last       int64    `json:"last"`
	Requests   int      `json:"requests"`
	Writes     int      `json:"writes"`
	Denied     int      `json:"denied"`
	LastAction string   `json:"last_action"`
	LastNS     string   `json:"last_ns"`
	LastRes    string   `json:"last_resource"`
	LastName   string   `json:"last_name"`
	Secrets    bool     `json:"secrets"` // has read or changed Secrets
	Self       bool     `json:"self"`    // this bridge (Kubiverse itself)
}

type watchState struct {
	mu       sync.Mutex
	visitors map[string]*Visitor
	actions  []map[string]any // not yet broadcast
	audit    bool
	auditLog string
	changed  bool
	seenMF   map[string]bool // uid|manager|time already reported
}

var ignoredUsers = []string{"system:node:", "system:kube-", "system:apiserver", "system:serviceaccount:kube-system:",
	"system:serviceaccount:local-path-storage:", "system:serviceaccount:kube-node-lease:", "system:volume-scheduler", "system:bootstrap:"}

var ignoredManagers = map[string]bool{"kube-controller-manager": true, "kube-scheduler": true, "kubelet": true,
	"kube-apiserver": true, "kindnetd": true, "k3s": true, "metrics-server": true, "before-first-apply": true}

var writeVerbs = map[string]bool{"create": true, "update": true, "patch": true, "delete": true, "deletecollection": true}

// shortAgent: "kubectl/v1.33.1 (darwin/arm64) kubernetes/8adc0f0" -> "kubectl/v1.33.1".
func shortAgent(ua string) string {
	ua = strings.TrimSpace(ua)
	if i := strings.IndexByte(ua, ' '); i > 0 {
		ua = ua[:i]
	}
	if strings.HasPrefix(ua, "Mozilla/") {
		return "browser"
	}
	return clip(ua, 60)
}

func ignoredUser(u string) bool {
	for _, p := range ignoredUsers {
		if strings.HasPrefix(u, p) {
			return true
		}
	}
	return false
}

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func (b *Bridge) startWatch(ctx context.Context, f informers.SharedInformerFactory) {
	b.watch = &watchState{visitors: map[string]*Visitor{}, seenMF: map[string]bool{}}
	h := cacheHandler(func(obj any) { b.onManagedFields(obj) })
	for _, inf := range []cache.SharedIndexInformer{
		f.Apps().V1().Deployments().Informer(), f.Apps().V1().StatefulSets().Informer(),
		f.Apps().V1().DaemonSets().Informer(), f.Core().V1().Services().Informer(),
		f.Core().V1().Namespaces().Informer(), f.Core().V1().Nodes().Informer(),
	} {
		inf.AddEventHandler(h)
	}
	go b.tailAudit(ctx, filepath.Join(auditDir, unsafeName.ReplaceAllString(b.contextName, "_")))
	go b.watchLoop(ctx)
}

// onManagedFields reports recent changes made by non-controller tools.
func (b *Bridge) onManagedFields(obj any) {
	m, ok := obj.(metav1.Object)
	if !ok {
		return
	}
	kind := fmt.Sprintf("%T", obj) // "*v1.Deployment"
	kind = strings.ToLower(kind[strings.LastIndexByte(kind, '.')+1:])
	var newest *metav1.ManagedFieldsEntry
	for i, e := range m.GetManagedFields() {
		if e.Time != nil && (newest == nil || e.Time.After(newest.Time.Time)) {
			newest = &m.GetManagedFields()[i]
		}
	}
	if newest == nil || ignoredManagers[newest.Manager] || time.Since(newest.Time.Time) > 90*time.Second {
		return
	}
	w := b.watch
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.audit {
		return // the audit log already says who did it, with identity
	}
	key := string(m.GetUID()) + "|" + newest.Manager + "|" + newest.Time.String()
	if w.seenMF[key] {
		return
	}
	w.seenMF[key] = true
	self := newest.Manager == "k8sgame-bridge"
	verb := strings.ToLower(string(newest.Operation))
	if newest.Subresource != "" {
		verb += " " + newest.Subresource
	}
	w.record("fields|"+newest.Manager, "", nil, newest.Manager, "", "fields", verb, kind+"s", m.GetNamespace(), m.GetName(), 200, newest.Time.Time, self)
}

// record updates a visitor and queues the action for the game. Caller holds w.mu.
func (w *watchState) record(key, user string, groups []string, agent, ip, source, verb, res, ns, name string, code int, at time.Time, self bool) {
	v := w.visitors[key]
	if v == nil {
		v = &Visitor{Key: key, User: user, Groups: groups, Agent: agent, Source: source, First: at.Unix(), Self: self}
		w.visitors[key] = v
	}
	if ip != "" && !contains(v.IPs, ip) && len(v.IPs) < 4 {
		v.IPs = append(v.IPs, ip)
	}
	v.Last = at.Unix()
	v.Requests++
	write := writeVerbs[strings.Fields(verb + " x")[0]] || source == "fields"
	if write {
		v.Writes++
	}
	if code == 401 || code == 403 {
		v.Denied++
	}
	if strings.HasPrefix(res, "secrets") {
		v.Secrets = true
	}
	v.LastAction, v.LastRes, v.LastNS, v.LastName = verb, res, ns, name
	w.changed = true
	// Reads are only counted; writes, denials, secrets and new faces are shown.
	if (write || code == 401 || code == 403 || strings.HasPrefix(res, "secrets") || v.Requests == 1) && len(w.actions) < 200 {
		w.actions = append(w.actions, map[string]any{"key": key, "user": user, "agent": agent, "ip": ip, "verb": verb,
			"resource": res, "ns": ns, "name": name, "code": code, "time": at.Unix(), "source": source, "self": self,
			"write": write, "new": v.Requests == 1})
	}
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

type auditEvent struct {
	Stage string `json:"stage"`
	Verb  string `json:"verb"`
	User  struct {
		Username string   `json:"username"`
		Groups   []string `json:"groups"`
	} `json:"user"`
	ImpersonatedUser *struct {
		Username string `json:"username"`
	} `json:"impersonatedUser"`
	SourceIPs []string `json:"sourceIPs"`
	UserAgent string   `json:"userAgent"`
	ObjectRef *struct {
		Resource    string `json:"resource"`
		Namespace   string `json:"namespace"`
		Name        string `json:"name"`
		Subresource string `json:"subresource"`
	} `json:"objectRef"`
	ResponseStatus *struct {
		Code int `json:"code"`
	} `json:"responseStatus"`
	RequestURI     string    `json:"requestURI"`
	StageTimestamp time.Time `json:"stageTimestamp"`
}

// tailAudit follows every audit.log under dir (one per API server).
func (b *Bridge) tailAudit(ctx context.Context, dir string) {
	offsets := map[string]int64{}
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		files, _ := filepath.Glob(filepath.Join(dir, "audit.log"))
		more, _ := filepath.Glob(filepath.Join(dir, "*", "audit.log"))
		files = append(files, more...)
		b.watch.mu.Lock()
		if len(files) > 0 && !b.watch.audit {
			b.watch.audit = true
			b.watch.auditLog = dir
			b.watch.changed = true
		}
		b.watch.mu.Unlock()
		for _, f := range files {
			offsets[f] = b.readAudit(f, offsets[f])
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// readAudit parses new lines from off; returns the new offset. On first sight
// (off 0) only the last 256 KiB are read, so a huge old log doesn't flood.
func (b *Bridge) readAudit(path string, off int64) int64 {
	fh, err := os.Open(path)
	if err != nil {
		return off
	}
	defer fh.Close()
	st, err := fh.Stat()
	if err != nil {
		return off
	}
	first := off == 0
	if st.Size() < off {
		off = 0 // rotated
	}
	if first && st.Size() > 256<<10 {
		off = st.Size() - 256<<10
	}
	if _, err := fh.Seek(off, io.SeekStart); err != nil {
		return off
	}
	r := bufio.NewReaderSize(fh, 1<<20)
	skipPartial := first && off > 0
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return off // incomplete last line: read it next time
		}
		off += int64(len(line))
		if skipPartial {
			skipPartial = false
			continue
		}
		var ev auditEvent
		if json.Unmarshal(line, &ev) != nil || ev.Stage != "ResponseComplete" && ev.Stage != "Panic" {
			continue
		}
		b.onAudit(ev)
	}
}

func (b *Bridge) onAudit(ev auditEvent) {
	u := ev.User.Username
	if ignoredUser(u) {
		return
	}
	if ev.ImpersonatedUser != nil {
		u += " as " + ev.ImpersonatedUser.Username
	}
	agent := shortAgent(ev.UserAgent)
	if u == "system:anonymous" && strings.HasPrefix(agent, "kubelet/") {
		return // nodes probing the API while they join
	}
	self := strings.HasPrefix(agent, "k8sgame-bridge")
	ip := ""
	if len(ev.SourceIPs) > 0 {
		ip = ev.SourceIPs[0]
	}
	res, ns, name := "", "", ""
	if o := ev.ObjectRef; o != nil {
		res, ns, name = o.Resource, o.Namespace, o.Name
		if o.Subresource != "" {
			res += "/" + o.Subresource
		}
	} else {
		res = clip(ev.RequestURI, 60)
	}
	code := 0
	if ev.ResponseStatus != nil {
		code = ev.ResponseStatus.Code
	}
	b.watch.mu.Lock()
	b.watch.record("audit|"+u+"|"+agent, u, ev.User.Groups, agent, ip, "audit", ev.Verb, res, ns, name, code, ev.StageTimestamp, self)
	b.watch.mu.Unlock()
}

// watchLoop pushes visitors + new actions to the game about once a second.
func (b *Bridge) watchLoop(ctx context.Context) {
	t := time.NewTicker(1200 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		msg := b.watchMessage(false)
		if msg != nil {
			b.broadcast(msg)
		}
	}
}

// watchMessage encodes the watchtower state; nil if nothing changed (unless force).
func (b *Bridge) watchMessage(force bool) []byte {
	w := b.watch
	players := b.players()
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.changed && len(w.actions) == 0 && !force && len(players) == 0 {
		return nil
	}
	w.changed = false
	cutoff := time.Now().Add(-30 * time.Minute).Unix()
	list := players
	for k, v := range w.visitors {
		if v.Last < cutoff {
			delete(w.visitors, k)
			continue
		}
		list = append(list, *v)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Last > list[j].Last })
	msg, _ := json.Marshal(map[string]any{"type": "watch", "data": map[string]any{
		"audit": w.audit, "audit_dir": filepath.Join(auditDir, unsafeName.ReplaceAllString(b.contextName, "_")),
		"visitors": list, "actions": w.actions,
	}})
	w.actions = nil
	if len(w.seenMF) > 5000 {
		w.seenMF = map[string]bool{}
	}
	return msg
}

func (b *Bridge) players() []Visitor {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []Visitor
	for c := range b.clients {
		agent := c.agent
		if agent == "" {
			agent = "Kubiverse"
		}
		who := "Kubiverse player"
		if c.user != "" {
			who = c.user
		}
		out = append(out, Visitor{Key: "player|" + c.addr, User: who, Agent: agent, IPs: []string{c.ip},
			Source: "player", First: c.since.Unix(), Last: time.Now().Unix()})
	}
	return out
}
