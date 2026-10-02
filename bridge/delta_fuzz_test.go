package main

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

// The property behind ?patch=1: whatever the cluster does, a game that
// applies each patch to the state it has ends up with exactly the next full
// state. gameApplyPatch mirrors game/scripts/k8s_client.gd (_on_patch,
// item_key, _sort_key): change one, change the other.

var gameCollections = []string{"nodes", "namespaces", "pods", "workloads", "services", "ingresses", "alerts", "volumes",
	"storage_classes", "apps", "certs", "pvs", "configs", "helm", "chart_repos"}

func str(m map[string]any, k string) (string, error) {
	v, ok := m[k]
	if !ok {
		// GDScript: "Invalid access to property or key" (the patch is lost).
		return "", fmt.Errorf("no key %q in %v", k, m)
	}
	return fmt.Sprint(v), nil
}

// gameItemKey mirrors K8s.item_key.
func gameItemKey(coll string, it map[string]any) (string, error) {
	join := func(keys ...string) (string, error) {
		parts := make([]string, len(keys))
		for i, k := range keys {
			v, err := str(it, k)
			if err != nil {
				return "", fmt.Errorf("%s: %w", coll, err)
			}
			parts[i] = v
		}
		return strings.Join(parts, "/"), nil
	}
	switch coll {
	case "nodes", "namespaces", "storage_classes", "pvs":
		return join("name")
	case "configs":
		return join("kind", "ns", "name")
	case "workloads":
		return join("ns", "kind", "name")
	case "alerts":
		return join("id")
	case "chart_repos":
		return join("ns", "service")
	}
	return join("ns", "name")
}

// gameSortKey mirrors K8s._sort_key.
func gameSortKey(coll string, it map[string]any) (string, error) {
	switch coll {
	case "configs":
		return strings.Join([]string{fmt.Sprint(it["ns"]), fmt.Sprint(it["kind"]), fmt.Sprint(it["name"])}, "/"), nil
	case "alerts":
		sev, _ := it["severity"].(string)
		return fmt.Sprint(severityRank(sev)) + fmt.Sprint(it["id"]), nil
	case "pods":
		return fmt.Sprint(it["ns"]) + "\x01" + fmt.Sprint(it["name"]), nil
	}
	return gameItemKey(coll, it)
}

func num(v any) float64 { f, _ := v.(float64); return f }

// gameOnState mirrors K8s._on_state: null collections become lists.
func gameOnState(s map[string]any) {
	for _, c := range gameCollections {
		if s[c] == nil {
			s[c] = []any{}
		}
	}
}

// gameApplyPatch mirrors K8s._on_patch on the decoded JSON state.
func gameApplyPatch(state map[string]any, seq *int64, p map[string]any) error {
	if int64(num(p["base"])) != *seq {
		return fmt.Errorf("patch on base %v, the game has %d", p["base"], *seq)
	}
	*seq = int64(num(p["seq"]))
	dt := num(p["time"]) - num(state["time"])
	for _, k := range []string{"context", "server", "readonly", "time"} {
		state[k] = p[k]
	}
	if dt != 0 {
		age := func(coll, field string, sign float64) {
			for _, it := range state[coll].([]any) {
				m := it.(map[string]any)
				m[field] = num(m[field]) + sign*dt
			}
		}
		age("nodes", "age", 1)
		age("pods", "age", 1)
		age("alerts", "since", 1)
		age("volumes", "age", 1)
		for _, it := range state["certs"].([]any) {
			if m := it.(map[string]any); num(m["expires_in"]) != 0 {
				m["expires_in"] = num(m["expires_in"]) - dt
			}
		}
	}
	if p["metrics"] != nil {
		state["metrics"] = p["metrics"]
	}
	sets, _ := p["set"].(map[string]any)
	dels, _ := p["del"].(map[string]any)
	for _, coll := range gameCollections {
		add, _ := sets[coll].([]any)
		del, _ := dels[coll].([]any)
		if len(add) == 0 && len(del) == 0 {
			continue
		}
		list := state[coll].([]any)
		at := map[string]int{}
		for i, it := range list {
			k, err := gameItemKey(coll, it.(map[string]any))
			if err != nil {
				return err
			}
			at[k] = i
		}
		moved := len(del) > 0
		for _, it := range add {
			k, err := gameItemKey(coll, it.(map[string]any))
			if err != nil {
				return err
			}
			if i, ok := at[k]; ok {
				list[i] = it
			} else {
				list = append(list, it)
				moved = true
			}
		}
		if len(del) > 0 {
			gone := map[string]bool{}
			for _, k := range del {
				gone[fmt.Sprint(k)] = true
			}
			kept := []any{}
			for _, it := range list {
				k, _ := gameItemKey(coll, it.(map[string]any))
				if !gone[k] {
					kept = append(kept, it)
				}
			}
			list = kept
		}
		if moved {
			var serr error
			sort.SliceStable(list, func(i, j int) bool {
				a, err1 := gameSortKey(coll, list[i].(map[string]any))
				b, err2 := gameSortKey(coll, list[j].(map[string]any))
				if err1 != nil || err2 != nil {
					serr = fmt.Errorf("sort %s: %v %v", coll, err1, err2)
				}
				return a < b
			})
			if serr != nil {
				return serr
			}
		}
		state[coll] = list
	}
	return nil
}

// --- random clusters --------------------------------------------------------

// choices: the fuzzer's bytes first (so its mutations steer the cluster),
// then a PRNG seeded by them.
type choices struct {
	b []byte
	r *rand.Rand
}

func newChoices(data []byte) *choices {
	h := fnv.New64a()
	h.Write(data)
	return &choices{b: data, r: rand.New(rand.NewPCG(h.Sum64(), uint64(len(data))))}
}

func (c *choices) n(k int) int {
	if k <= 1 {
		return 0
	}
	if len(c.b) > 0 {
		v := int(c.b[0])
		c.b = c.b[1:]
		return v % k
	}
	return c.r.IntN(k)
}

func (c *choices) pick(xs ...string) string { return xs[c.n(len(xs))] }
func (c *choices) chance(pct int) bool      { return c.n(100) < pct }

// genCluster keeps what is stable about objects across snapshots (when they
// were created), so ages move with the clock like in a real cluster.
type genCluster struct {
	c       *choices
	time    int64
	born    map[string]int64 // "coll|key" -> created (unix)
	expires map[string]int64 // cert key -> expiry (0 unknown)
}

// Names that sort differently as "ns/name" and as (ns, name): "a" vs "a-b".
var genNS = []string{"a", "a-b", "b"}

func (g *genCluster) created(coll, key string) int64 {
	k := coll + "|" + key
	if t, ok := g.born[k]; ok {
		return t
	}
	t := g.time - int64(g.c.n(5000))
	g.born[k] = t
	return t
}

// present: each candidate object exists with a high chance; when gone it
// forgets its birth (a new object with the same name is new).
func (g *genCluster) present(coll, key string) bool {
	if g.c.chance(80) {
		return true
	}
	delete(g.born, coll+"|"+key)
	return false
}

func (g *genCluster) snapshot() *Snapshot {
	c := g.c
	s := &Snapshot{Context: c.pick("ctx", "ctx2"), Server: "https://127.0.0.1:6443", ReadOnly: c.chance(10), Time: g.time,
		Nodes: []Node{}, Namespaces: []Namespace{}, Pods: []Pod{}, Workloads: []Workload{}, Services: []Service{}, Ingresses: []Ingress{},
		Alerts: []Alert{}, Volumes: []Volume{}, StorageClasses: []StorageClass{}, Apps: []ArgoApp{}, Certs: []Cert{}, PVs: []PV{},
		Configs: []ConfigRef{}, Helm: []HelmRelease{}, ChartRepos: []ChartRepo{}}
	s.Metrics = Metrics{Available: c.chance(70), Nodes: map[string]Usage{}, Pods: map[string]Usage{}}
	for _, n := range []string{"n1", "n2", "n3"} {
		if !g.present("nodes", n) {
			continue
		}
		s.Nodes = append(s.Nodes, Node{Name: n, Ready: c.chance(80), Unschedulable: c.chance(10), Roles: []string{}, Taints: []string{},
			Conditions: []string{}, Age: g.time - g.created("nodes", n), CPUm: int64(1000 * (1 + c.n(2)))})
		if s.Metrics.Available {
			s.Metrics.Nodes[n] = Usage{CPUm: int64(100 * c.n(3))}
		}
	}
	for _, ns := range genNS {
		if !g.present("namespaces", ns) {
			continue
		}
		s.Namespaces = append(s.Namespaces, Namespace{Name: ns, Phase: c.pick("Active", "Terminating"), Created: g.created("namespaces", ns)})
		for _, kind := range []string{"Deployment", "StatefulSet"} {
			for _, name := range []string{"api", "web"} {
				if !g.present("workloads", ns+kind+name) {
					continue
				}
				s.Workloads = append(s.Workloads, Workload{Kind: kind, Namespace: ns, Name: name, Desired: int32(c.n(3)), Ready: int32(c.n(3)),
					Image: c.pick("x:1", "x:2"), Created: g.created("workloads", ns+kind+name)})
			}
		}
		for _, name := range []string{"api", "web"} {
			if g.present("services", ns+name) {
				s.Services = append(s.Services, Service{Namespace: ns, Name: name, Type: c.pick("ClusterIP", "LoadBalancer"), Pods: []string{}})
			}
			if g.present("ingresses", ns+name) {
				s.Ingresses = append(s.Ingresses, Ingress{Namespace: ns, Name: name, Rules: []IngressRule{{Host: c.pick("", "x.example.com"), Path: "/"}}})
			}
			if g.present("ingresses", ns+"route"+name) {
				s.Ingresses = append(s.Ingresses, Ingress{Namespace: ns, Name: "httproute/" + name, Class: "gateway", Rules: []IngressRule{}})
			}
			if g.present("volumes", ns+name) {
				s.Volumes = append(s.Volumes, Volume{Namespace: ns, Name: name, Status: c.pick("Bound", "Pending"), Access: []string{}, Pods: []string{},
					Age: g.time - g.created("volumes", ns+name)})
			}
			if g.present("apps", ns+name) {
				s.Apps = append(s.Apps, ArgoApp{Tool: c.pick("argocd", "flux"), Namespace: ns, Name: name, Sync: c.pick("Synced", "OutOfSync")})
			}
			if g.present("certs", ns+name) {
				key := ns + "/" + name
				if _, ok := g.expires[key]; !ok {
					g.expires[key] = 0
					if c.chance(80) {
						g.expires[key] = g.time + int64(c.n(4*24*3600)) - 3600
					}
				}
				exp := g.expires[key]
				left := int64(0)
				if exp != 0 {
					left = expiresIn(time.Unix(exp, 0), time.Unix(g.time, 0))
				}
				s.Certs = append(s.Certs, Cert{Namespace: ns, Name: name, DNS: []string{}, Ready: c.chance(80), ExpiresIn: left})
			} else {
				delete(g.expires, ns+"/"+name)
			}
			for _, kind := range []string{"ConfigMap", "Secret"} {
				if g.present("configs", kind+ns+name) {
					s.Configs = append(s.Configs, ConfigRef{Kind: kind, Namespace: ns, Name: name, Keys: []string{}, Pods: []string{}, How: []string{},
						Exists: c.pick("yes", "no"), Age: g.time - g.created("configs", kind+ns+name)})
				}
			}
		}
		if g.present("helm", ns) {
			s.Helm = append(s.Helm, HelmRelease{Namespace: ns, Name: "rel", Revision: 1 + c.n(3), Status: "deployed", Charts: []HelmChart{}})
		}
		if g.present("chart_repos", ns) {
			s.ChartRepos = append(s.ChartRepos, ChartRepo{Namespace: ns, Service: "chartmuseum", Port: int32(8080 + c.n(2)), Kind: "chartmuseum"})
		}
	}
	// Pods of the workloads (and a loose one), with their owners.
	for _, w := range s.Workloads {
		for i := 0; i < 2; i++ {
			name := fmt.Sprintf("%s-%d", w.Name, i)
			if w.Kind == "Deployment" {
				name = fmt.Sprintf("%s-%s-%d", w.Name, strings.ToLower(w.Kind[:3]), i)
			}
			key := w.Namespace + "/" + name
			if !g.present("pods", key) {
				continue
			}
			node := ""
			if len(s.Nodes) > 0 && c.chance(80) {
				node = s.Nodes[c.n(len(s.Nodes))].Name
			}
			p := Pod{Namespace: w.Namespace, Name: name, Node: node, Status: c.pick("Running", "Pending", "CrashLoopBackOff"),
				Total: 1, Containers: []string{"c"}, Images: []string{w.Image}, OwnerKind: w.Kind, OwnerName: w.Name,
				Restarts: int32(c.n(3)), Age: g.time - g.created("pods", key)}
			p.Ready = c.n(2)
			s.Pods = append(s.Pods, p)
			if s.Metrics.Available {
				s.Metrics.Pods[key] = Usage{MemBytes: int64(c.n(3)) << 20}
			}
		}
	}
	for _, name := range []string{"a", "b"} {
		if g.present("storage_classes", name) {
			s.StorageClasses = append(s.StorageClasses, StorageClass{Name: name, Default: c.chance(50)})
		}
		if g.present("pvs", name) {
			s.PVs = append(s.PVs, PV{Name: "pv-" + name, Status: c.pick("Bound", "Released"), Age: g.time - g.created("pvs", name)})
		}
	}
	for _, id := range []string{"a1", "a2", "b1"} {
		if g.present("alerts", id) {
			// The severity is one of the labels the ID is made of (makeAlert,
			// Alertmanager fingerprints): it never changes under one ID.
			sev := []string{"critical", "warning", "info", "none"}[(g.created("alerts", id)%4+4)%4]
			s.Alerts = append(s.Alerts, Alert{ID: id, Name: "X", Severity: sev,
				Since: g.time - g.created("alerts", id), Source: "prometheus"})
		}
	}
	sortLikeTheBridge(s)
	return s
}

// sortLikeTheBridge: the orders buildSnapshot produces (checked on real
// builds by assertSnapshotInvariants).
func sortLikeTheBridge(s *Snapshot) {
	by := func(n int, less func(i, j int) bool, swap func(i, j int)) {
		sort.Sort(sorter{n, less, swap})
	}
	by(len(s.Pods), func(i, j int) bool {
		if s.Pods[i].Namespace != s.Pods[j].Namespace {
			return s.Pods[i].Namespace < s.Pods[j].Namespace
		}
		return s.Pods[i].Name < s.Pods[j].Name
	}, func(i, j int) { s.Pods[i], s.Pods[j] = s.Pods[j], s.Pods[i] })
	key := func(parts ...string) string { return strings.Join(parts, "/") }
	by(len(s.Workloads), func(i, j int) bool {
		a, b := s.Workloads[i], s.Workloads[j]
		return key(a.Namespace, a.Kind, a.Name) < key(b.Namespace, b.Kind, b.Name)
	}, func(i, j int) { s.Workloads[i], s.Workloads[j] = s.Workloads[j], s.Workloads[i] })
	by(len(s.Services), func(i, j int) bool {
		return key(s.Services[i].Namespace, s.Services[i].Name) < key(s.Services[j].Namespace, s.Services[j].Name)
	}, func(i, j int) { s.Services[i], s.Services[j] = s.Services[j], s.Services[i] })
	by(len(s.Ingresses), func(i, j int) bool {
		return key(s.Ingresses[i].Namespace, s.Ingresses[i].Name) < key(s.Ingresses[j].Namespace, s.Ingresses[j].Name)
	}, func(i, j int) { s.Ingresses[i], s.Ingresses[j] = s.Ingresses[j], s.Ingresses[i] })
	by(len(s.Volumes), func(i, j int) bool {
		return key(s.Volumes[i].Namespace, s.Volumes[i].Name) < key(s.Volumes[j].Namespace, s.Volumes[j].Name)
	}, func(i, j int) { s.Volumes[i], s.Volumes[j] = s.Volumes[j], s.Volumes[i] })
	by(len(s.Apps), func(i, j int) bool {
		return key(s.Apps[i].Namespace, s.Apps[i].Name) < key(s.Apps[j].Namespace, s.Apps[j].Name)
	}, func(i, j int) { s.Apps[i], s.Apps[j] = s.Apps[j], s.Apps[i] })
	by(len(s.Certs), func(i, j int) bool {
		return key(s.Certs[i].Namespace, s.Certs[i].Name) < key(s.Certs[j].Namespace, s.Certs[j].Name)
	}, func(i, j int) { s.Certs[i], s.Certs[j] = s.Certs[j], s.Certs[i] })
	by(len(s.Configs), func(i, j int) bool {
		a, b := s.Configs[i], s.Configs[j]
		return key(a.Namespace, a.Kind, a.Name) < key(b.Namespace, b.Kind, b.Name)
	}, func(i, j int) { s.Configs[i], s.Configs[j] = s.Configs[j], s.Configs[i] })
	by(len(s.Helm), func(i, j int) bool {
		return key(s.Helm[i].Namespace, s.Helm[i].Name) < key(s.Helm[j].Namespace, s.Helm[j].Name)
	}, func(i, j int) { s.Helm[i], s.Helm[j] = s.Helm[j], s.Helm[i] })
	by(len(s.ChartRepos), func(i, j int) bool {
		return key(s.ChartRepos[i].Namespace, s.ChartRepos[i].Service) < key(s.ChartRepos[j].Namespace, s.ChartRepos[j].Service)
	}, func(i, j int) { s.ChartRepos[i], s.ChartRepos[j] = s.ChartRepos[j], s.ChartRepos[i] })
	by(len(s.Alerts), func(i, j int) bool {
		ri, rj := severityRank(s.Alerts[i].Severity), severityRank(s.Alerts[j].Severity)
		if ri != rj {
			return ri < rj
		}
		return s.Alerts[i].ID < s.Alerts[j].ID
	}, func(i, j int) { s.Alerts[i], s.Alerts[j] = s.Alerts[j], s.Alerts[i] })
	// nodes, namespaces, storage classes, PVs: generated in name order.
}

type sorter struct {
	n    int
	less func(i, j int) bool
	swap func(i, j int)
}

func (s sorter) Len() int           { return s.n }
func (s sorter) Less(i, j int) bool { return s.less(i, j) }
func (s sorter) Swap(i, j int)      { s.swap(i, j) }

// --- the property ---------------------------------------------------------------

func decodeMsg(t *testing.T, raw []byte, typ string) (map[string]any, int64) {
	t.Helper()
	var m struct {
		Type string         `json:"type"`
		Seq  int64          `json:"seq"`
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal(raw, &m); err != nil || m.Type != typ {
		t.Fatalf("%s message: %v %.200s", typ, err, raw)
	}
	return m.Data, m.Seq
}

// comparable: what the game doesn't track drops out: PV and Secret /
// ConfigMap ages (neither moved with the clock nor sent as changes).
func comparable(state map[string]any) map[string]any {
	raw, _ := json.Marshal(state)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	gameOnState(out)
	for _, coll := range []string{"pvs", "configs"} {
		for _, it := range out[coll].([]any) {
			delete(it.(map[string]any), "age")
		}
	}
	return out
}

func checkDeltaSequence(t *testing.T, data []byte) {
	c := newChoices(data)
	g := &genCluster{c: c, time: 1_700_000_000, born: map[string]int64{}, expires: map[string]int64{}}
	var d stateDiff
	var state map[string]any
	var seq int64
	steps := 2 + c.n(7)
	for step := 0; step < steps; step++ {
		s := g.snapshot()
		if v := snapshotViolations(s); len(v) > 0 {
			t.Fatalf("step %d: the generator broke an invariant: %v", step, v)
		}
		full, patch := d.next(s)
		want, wantSeq := decodeMsg(t, full, "state")
		if step == 0 {
			if patch != nil {
				t.Fatal("the first message must be a full state only")
			}
			state, seq = want, wantSeq
			gameOnState(state)
		} else {
			p, _ := decodeMsg(t, patch, "patch")
			if err := gameApplyPatch(state, &seq, p); err != nil {
				t.Fatalf("step %d: the game can't apply the patch: %v", step, err)
			}
			if seq != wantSeq {
				t.Fatalf("step %d: game at seq %d, full state %d", step, seq, wantSeq)
			}
			got, exp := comparable(state), comparable(want)
			if !reflect.DeepEqual(got, exp) {
				for k := range exp {
					if !reflect.DeepEqual(got[k], exp[k]) {
						gv, ev := firstDiff(got[k], exp[k])
						t.Errorf("step %d: %q differs after the patch\n  game: %s\n  full: %s", step, k, gv, ev)
					}
				}
				t.FailNow()
			}
		}
		// The clock moves (sometimes past an hour: certificates count hours).
		g.time += int64(1 + c.n(3*3600))
	}
}

// firstDiff: the first differing item of two lists (whole values otherwise).
func firstDiff(a, b any) (string, string) {
	la, ok1 := a.([]any)
	lb, ok2 := b.([]any)
	if ok1 && ok2 && len(la) == len(lb) {
		for i := range la {
			if !reflect.DeepEqual(la[i], lb[i]) {
				ja, _ := json.Marshal(la[i])
				jb, _ := json.Marshal(lb[i])
				return fmt.Sprintf("[%d] %s", i, ja), fmt.Sprintf("[%d] %s", i, jb)
			}
		}
	}
	ja, _ := json.Marshal(a)
	jb, _ := json.Marshal(b)
	return string(ja), string(jb)
}

// A fixed sample of random clusters on every go test.
func TestDeltaPatchesRebuildTheFullState(t *testing.T) {
	for i := 0; i < 150; i++ {
		data := []byte(fmt.Sprintf("seed-%d", i))
		t.Run(fmt.Sprint(i), func(t *testing.T) { checkDeltaSequence(t, data) })
		if t.Failed() {
			return
		}
	}
}

// go test -run '^$' -fuzz FuzzDelta -fuzztime 20s
func FuzzDelta(f *testing.F) {
	for _, seed := range [][]byte{
		{},
		[]byte("seed-0"),
		{6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, // everything present, long run
		{1, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99}, // things vanish
		[]byte("ns a vs a-b: pods sort by (ns, name), the rest by ns/name"),
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		checkDeltaSequence(t, data)
	})
}
