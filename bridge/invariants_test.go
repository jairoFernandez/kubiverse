package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"
)

// assertSnapshotInvariants: what must hold for ANY snapshot the bridge
// sends, whatever a test expects of its particular fixture. A test that
// asserts something contradicting these is wrong, and code that breaks one
// breaks the game (patches keyed by these keys, lists it iterates, order it
// rebuilds after a patch: game/scripts/k8s_client.gd).
func assertSnapshotInvariants(t *testing.T, s *Snapshot) {
	t.Helper()
	for _, e := range snapshotViolations(s) {
		t.Errorf("snapshot invariant: %s", e)
	}
}

func snapshotViolations(s *Snapshot) []string {
	var errs []string
	bad := func(f string, a ...any) { errs = append(errs, fmt.Sprintf(f, a...)) }

	// Unique keys, in the order the game rebuilds after a patch: the delta
	// keys of delta.go, sorted like k8s_client.gd's _sort_key.
	keyed := func(coll string, n int, key func(int) string, sortKey func(int) string) {
		seen := map[string]bool{}
		for i := 0; i < n; i++ {
			k := key(i)
			if k == "" || strings.HasPrefix(k, "/") || strings.HasSuffix(k, "/") {
				bad("%s[%d]: empty name in key %q", coll, i, k)
			}
			if seen[k] {
				bad("%s: duplicate key %q", coll, k)
			}
			seen[k] = true
			if i > 0 && !(sortKey(i-1) < sortKey(i)) {
				bad("%s: %q comes after %q (want sorted)", coll, key(i), key(i-1))
			}
		}
	}
	same := func(f func(int) string) func(int) string { return f }
	nodeKey := func(i int) string { return s.Nodes[i].Name }
	keyed("nodes", len(s.Nodes), nodeKey, same(nodeKey))
	nsKey := func(i int) string { return s.Namespaces[i].Name }
	keyed("namespaces", len(s.Namespaces), nsKey, same(nsKey))
	keyed("pods", len(s.Pods), func(i int) string { return s.Pods[i].Namespace + "/" + s.Pods[i].Name },
		func(i int) string { return s.Pods[i].Namespace + "\x01" + s.Pods[i].Name })
	wlKey := func(i int) string {
		w := s.Workloads[i]
		return w.Namespace + "/" + w.Kind + "/" + w.Name
	}
	keyed("workloads", len(s.Workloads), wlKey, same(wlKey))
	svcKey := func(i int) string { return s.Services[i].Namespace + "/" + s.Services[i].Name }
	keyed("services", len(s.Services), svcKey, same(svcKey))
	ingKey := func(i int) string { return s.Ingresses[i].Namespace + "/" + s.Ingresses[i].Name }
	keyed("ingresses", len(s.Ingresses), ingKey, same(ingKey))
	keyed("alerts", len(s.Alerts), func(i int) string { return s.Alerts[i].ID },
		func(i int) string { return fmt.Sprint(severityRank(s.Alerts[i].Severity)) + s.Alerts[i].ID })
	volKey := func(i int) string { return s.Volumes[i].Namespace + "/" + s.Volumes[i].Name }
	keyed("volumes", len(s.Volumes), volKey, same(volKey))
	scKey := func(i int) string { return s.StorageClasses[i].Name }
	keyed("storage_classes", len(s.StorageClasses), scKey, same(scKey))
	appKey := func(i int) string { return s.Apps[i].Namespace + "/" + s.Apps[i].Name }
	keyed("apps", len(s.Apps), appKey, same(appKey))
	pvKey := func(i int) string { return s.PVs[i].Name }
	keyed("pvs", len(s.PVs), pvKey, same(pvKey))
	keyed("configs", len(s.Configs), func(i int) string { c := s.Configs[i]; return c.Kind + "/" + c.Namespace + "/" + c.Name },
		func(i int) string { c := s.Configs[i]; return c.Namespace + "/" + c.Kind + "/" + c.Name })
	helmKey := func(i int) string { return s.Helm[i].Namespace + "/" + s.Helm[i].Name }
	keyed("helm", len(s.Helm), helmKey, same(helmKey))
	repoKey := func(i int) string { return s.ChartRepos[i].Namespace + "/" + s.ChartRepos[i].Service }
	keyed("chart_repos", len(s.ChartRepos), repoKey, same(repoKey))
	certKey := func(i int) string { return s.Certs[i].Namespace + "/" + s.Certs[i].Name }
	keyed("certs", len(s.Certs), certKey, same(certKey))

	// Lists the game iterates are lists, never JSON null.
	raw, err := json.Marshal(s)
	if err != nil {
		bad("does not marshal: %v", err)
		return errs
	}
	var top map[string]any
	_ = json.Unmarshal(raw, &top)
	for _, c := range []string{"nodes", "namespaces", "pods", "workloads", "services", "ingresses", "alerts", "volumes",
		"storage_classes", "apps", "certs", "pvs", "configs", "helm", "chart_repos"} {
		if v, ok := top[c]; !ok || v == nil {
			bad("%q is null (the game iterates it)", c)
		}
	}
	nonNil := func(what string, v []string) {
		if v == nil {
			bad("%s is null", what)
		}
	}

	ns := map[string]bool{}
	for _, n := range s.Namespaces {
		ns[n.Name] = true
		if n.Created > s.Time {
			bad("namespace %s created after the snapshot (%d > %d)", n.Name, n.Created, s.Time)
		}
	}
	nodes := map[string]bool{}
	for _, n := range s.Nodes {
		nodes[n.Name] = true
		nonNil("node "+n.Name+" roles", n.Roles)
		nonNil("node "+n.Name+" taints", n.Taints)
		nonNil("node "+n.Name+" conditions", n.Conditions)
		if !sort.StringsAreSorted(n.Roles) {
			bad("node %s roles not sorted: %v", n.Name, n.Roles)
		}
		if n.Age < 0 {
			bad("node %s has a negative age", n.Name)
		}
	}
	wl := map[string]bool{}
	for _, w := range s.Workloads {
		wl[w.Namespace+"/"+w.Kind+"/"+w.Name] = true
		if w.Kind != "Deployment" && w.Kind != "StatefulSet" && w.Kind != "DaemonSet" {
			bad("workload %s/%s: unknown kind %q", w.Namespace, w.Name, w.Kind)
		}
		if w.Created > s.Time {
			bad("workload %s/%s created after the snapshot", w.Namespace, w.Name)
		}
		if w.Desired < 0 || w.Ready < 0 || w.Updated < 0 || w.Available < 0 {
			bad("workload %s/%s: negative replicas %+v", w.Namespace, w.Name, w)
		}
	}
	pods := map[string]bool{}
	for _, p := range s.Pods {
		k := p.Namespace + "/" + p.Name
		pods[k] = true
		// Owned by a workload: it is in the snapshot (the game puts the pod
		// on its line), or the pod is going away with it. Other owners
		// (Jobs, bare ReplicaSets, operators) and no owner: loose pods.
		switch p.OwnerKind {
		case "Deployment", "StatefulSet", "DaemonSet":
			if !wl[p.Namespace+"/"+p.OwnerKind+"/"+p.OwnerName] && !p.Deleting {
				bad("pod %s: owner %s/%s is not in the snapshot", k, p.OwnerKind, p.OwnerName)
			}
		}
		if p.Ready < 0 || p.Ready > p.Total {
			bad("pod %s: %d/%d ready", k, p.Ready, p.Total)
		}
		if len(p.Containers) != p.Total || len(p.Images) != p.Total {
			bad("pod %s: %d containers, %d images, total %d", k, len(p.Containers), len(p.Images), p.Total)
		}
		if p.Restarts < 0 || p.Age < 0 {
			bad("pod %s: negative restarts/age", k)
		}
		if p.Deleting && p.Status != "Terminating" {
			bad("pod %s is being deleted but says %q", k, p.Status)
		}
		if p.Node != "" && len(s.Nodes) > 0 && !nodes[p.Node] {
			bad("pod %s on unknown node %q", k, p.Node)
		}
	}
	for _, sv := range s.Services {
		k := sv.Namespace + "/" + sv.Name
		nonNil("service "+k+" pods", sv.Pods)
		if !sort.StringsAreSorted(sv.Pods) {
			bad("service %s: pods not sorted %v", k, sv.Pods)
		}
		if sv.Ready < 0 || sv.Ready > len(sv.Pods) {
			bad("service %s: %d ready of %d pods", k, sv.Ready, len(sv.Pods))
		}
		for _, p := range sv.Pods {
			if !pods[sv.Namespace+"/"+p] {
				bad("service %s selects pod %s that is not in the snapshot", k, p)
			}
		}
		if sv.Created > s.Time {
			bad("service %s created after the snapshot", k)
		}
	}
	for _, in := range s.Ingresses {
		if in.Rules == nil {
			bad("ingress %s/%s: rules null", in.Namespace, in.Name)
		}
		if in.Created > s.Time {
			bad("ingress %s/%s created after the snapshot", in.Namespace, in.Name)
		}
	}
	for _, v := range s.Volumes {
		nonNil("volume "+v.Name+" pods", v.Pods)
		nonNil("volume "+v.Name+" access", v.Access)
		if v.Age < 0 {
			bad("volume %s/%s: negative age", v.Namespace, v.Name)
		}
	}
	for _, c := range s.Configs {
		k := c.Kind + "/" + c.Namespace + "/" + c.Name
		nonNil(k+" keys", c.Keys)
		nonNil(k+" pods", c.Pods)
		nonNil(k+" how", c.How)
		if c.Kind != "Secret" && c.Kind != "ConfigMap" {
			bad("config %s: kind", k)
		}
	}
	for _, c := range s.Certs {
		nonNil("cert "+c.Name+" dns", c.DNS)
	}
	for _, r := range s.Helm {
		k := r.Namespace + "/" + r.Name
		if r.Charts == nil {
			bad("helm %s: charts null", k)
		}
		names := map[string]bool{}
		parent := -1
		for i, c := range r.Charts {
			if c.Name == "" {
				bad("helm %s: a chart without a name", k)
			}
			names[c.Name] = true
			if c.Workloads == nil || c.Services == nil {
				bad("helm %s chart %s: null workloads/services", k, c.Name)
			}
			if !sort.StringsAreSorted(c.Workloads) || !sort.StringsAreSorted(c.Services) {
				bad("helm %s chart %s: objects not sorted", k, c.Name)
			}
			for _, w := range c.Workloads {
				if !wl[r.Namespace+"/"+w] {
					bad("helm %s chart %s: workload %s not in the snapshot", k, c.Name, w)
				}
			}
			if r.Chart != "" && c.Name+"-"+c.Version == r.Chart {
				parent = i
			}
		}
		if r.Umbrella != (len(names) > 1) {
			bad("helm %s: umbrella=%v with %d distinct charts", k, r.Umbrella, len(names))
		}
		if r.Chart != "" && parent != 0 {
			bad("helm %s: parent chart %q is not first among %d", k, r.Chart, len(r.Charts))
		}
		if len(r.Charts) == 1 && r.Chart != r.Charts[0].Name+"-"+r.Charts[0].Version {
			bad("helm %s: one chart %s-%s but parent %q", k, r.Charts[0].Name, r.Charts[0].Version, r.Chart)
		}
		start := 0
		if parent == 0 {
			start = 1
		}
		for i := start + 1; i < len(r.Charts); i++ { // subcharts by name after the parent
			if r.Charts[i-1].Name > r.Charts[i].Name {
				bad("helm %s: subcharts not by name", k)
			}
		}
		if r.Revision < 0 {
			bad("helm %s: negative revision", k)
		}
	}
	for _, a := range s.Alerts {
		if a.Since < 0 {
			bad("alert %s firing for negative time", a.ID)
		}
	}
	return errs
}

func severityRank(s string) int {
	if r, ok := map[string]int{"critical": 0, "warning": 1, "info": 2}[s]; ok {
		return r
	}
	return 3
}

// The invariants themselves catch what they claim to (a wrong invariant
// would let every test pass).
func TestSnapshotInvariantsCatchBrokenSnapshots(t *testing.T) {
	good := func() *Snapshot {
		return &Snapshot{Time: 100,
			Nodes:      []Node{{Name: "a", Roles: []string{}, Taints: []string{}, Conditions: []string{}}, {Name: "b", Roles: []string{}, Taints: []string{}, Conditions: []string{}}},
			Namespaces: []Namespace{{Name: "shop", Created: 50}},
			Pods: []Pod{{Namespace: "shop", Name: "api-1", OwnerKind: "Deployment", OwnerName: "api", Total: 1, Ready: 1, Containers: []string{"c"}, Images: []string{"i"}, Node: "a"},
				{Namespace: "shop", Name: "debug", Total: 0}},
			Workloads: []Workload{{Kind: "Deployment", Namespace: "shop", Name: "api", Desired: 1}},
			Services:  []Service{{Namespace: "shop", Name: "api", Pods: []string{"api-1"}, Ready: 1}},
			Ingresses: []Ingress{}, Alerts: []Alert{{ID: "x", Severity: "critical"}, {ID: "a", Severity: "warning"}},
			Volumes: []Volume{}, StorageClasses: []StorageClass{}, Apps: []ArgoApp{}, Certs: []Cert{}, PVs: []PV{}, Configs: []ConfigRef{},
			Helm: []HelmRelease{{Namespace: "shop", Name: "web", Chart: "web-1.0", Umbrella: true, Charts: []HelmChart{
				{Name: "web", Version: "1.0", Workloads: []string{"Deployment/api"}, Services: []string{}},
				{Name: "redis", Version: "2", Workloads: []string{}, Services: []string{}}}}},
			ChartRepos: []ChartRepo{}}
	}
	if v := snapshotViolations(good()); len(v) != 0 {
		t.Fatalf("a good snapshot fails: %v", v)
	}
	for name, breakIt := range map[string]func(s *Snapshot){
		"duplicate pod":     func(s *Snapshot) { s.Pods = append(s.Pods, s.Pods[1]) },
		"unsorted nodes":    func(s *Snapshot) { s.Nodes[0], s.Nodes[1] = s.Nodes[1], s.Nodes[0] },
		"orphaned pod":      func(s *Snapshot) { s.Pods[0].OwnerName = "gone" },
		"null pods":         func(s *Snapshot) { s.Pods = nil },
		"null roles":        func(s *Snapshot) { s.Nodes[0].Roles = nil },
		"future namespace":  func(s *Snapshot) { s.Namespaces[0].Created = 101 },
		"umbrella lies":     func(s *Snapshot) { s.Helm[0].Umbrella = false },
		"nameless chart":    func(s *Snapshot) { s.Helm[0].Charts[1].Name = "" },
		"parent not first":  func(s *Snapshot) { s.Helm[0].Charts[0], s.Helm[0].Charts[1] = s.Helm[0].Charts[1], s.Helm[0].Charts[0] },
		"alerts by id only": func(s *Snapshot) { s.Alerts[0], s.Alerts[1] = s.Alerts[1], s.Alerts[0] },
		"ready > total":     func(s *Snapshot) { s.Pods[0].Ready = 2 },
		"ghost endpoint":    func(s *Snapshot) { s.Services[0].Pods = []string{"nope"}; s.Services[0].Ready = 0 },
		"unknown node":      func(s *Snapshot) { s.Pods[0].Node = "c" },
	} {
		s := good()
		breakIt(s)
		if len(snapshotViolations(s)) == 0 {
			t.Errorf("%s: not caught", name)
		}
	}
}
