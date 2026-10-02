package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
)

// Helm, from what the cluster already says about it:
//   - a release is a Secret "sh.helm.release.v1.<name>.v<revision>" whose
//     labels (name, status, version, modifiedAt) are read; never its data,
//     which holds the values (passwords included);
//   - which chart made each object, from its helm.sh/chart label: a release
//     with objects from several charts is an umbrella chart (the parent and
//     its subcharts / dependencies);
//   - chart repositories running in the cluster (ChartMuseum), whose charts
//     are listed on demand (GET /api/charts).

// HelmRelease: one installed release (its latest revision).
type HelmRelease struct {
	Namespace string      `json:"ns"`
	Name      string      `json:"name"`
	Revision  int         `json:"revision"`
	Status    string      `json:"status"`            // deployed | failed | pending-upgrade | superseded...
	Updated   int64       `json:"updated,omitempty"` // unix seconds of the last change
	Chart     string      `json:"chart,omitempty"`   // the parent chart, "name-version", when it can be told
	Charts    []HelmChart `json:"charts"`            // every chart with objects in the release
	Umbrella  bool        `json:"umbrella"`          // objects from more than one chart
}

// HelmChart: a chart (or subchart) of a release and what it made.
type HelmChart struct {
	Name      string   `json:"name"`
	Version   string   `json:"version"`
	Workloads []string `json:"workloads"` // "Kind/name"
	Services  []string `json:"services"`
}

// ChartRepo: a chart repository served from the cluster.
type ChartRepo struct {
	Namespace string `json:"ns"`
	Service   string `json:"service"`
	Port      int32  `json:"port"`
	Kind      string `json:"kind"` // chartmuseum
}

const helmReleasePrefix = "sh.helm.release.v1."

// helmOf: the release and chart an object belongs to ("", "" when none).
func helmOf(m metav1.ObjectMeta) (release, chart string) {
	chart = m.Labels["helm.sh/chart"]
	release = m.Annotations["meta.helm.sh/release-name"]
	if release == "" && m.Labels["app.kubernetes.io/managed-by"] == "Helm" {
		release = m.Labels["app.kubernetes.io/instance"]
	}
	if release == "" {
		chart = ""
	}
	return release, chart
}

func rel(m metav1.ObjectMeta) string   { r, _ := helmOf(m); return r }
func chart(m metav1.ObjectMeta) string { _, c := helmOf(m); return c }

// splitChart: "redis-17.3.2" -> ("redis", "17.3.2"); the version starts at
// the last dash followed by a digit or "v<digit>" (names have dashes too).
func splitChart(c string) (string, string) {
	for i := len(c) - 1; i > 0; i-- {
		digit := c[i] >= '0' && c[i] <= '9'
		vDigit := c[i] == 'v' && i+1 < len(c) && c[i+1] >= '0' && c[i+1] <= '9' // cert-manager-v1.16.1
		if c[i-1] == '-' && (digit || vDigit) {
			return c[:i-1], c[i:]
		}
	}
	return c, ""
}

// keepHelmLabels: the metadata-only Secret informer drops every label, but
// a Helm release's few labels say its status and revision (no values).
func keepHelmLabels(m *metav1.PartialObjectMetadata) map[string]string {
	if m.Labels["owner"] != "helm" || !strings.HasPrefix(m.Name, helmReleasePrefix) {
		return nil
	}
	out := map[string]string{}
	for _, k := range []string{"owner", "name", "status", "version", "modifiedAt"} {
		if v, ok := m.Labels[k]; ok {
			out[k] = v
		}
	}
	return out
}

type helmObj struct {
	kind, name, release, chart string
	isService                  bool
}

// helmReleases: the releases, with the charts each one deployed.
func (b *Bridge) helmReleases(deps []*appsv1.Deployment, sts []*appsv1.StatefulSet, dss []*appsv1.DaemonSet, svcs []*corev1.Service) []HelmRelease {
	byKey := map[string]*HelmRelease{}
	get := func(ns, name string) *HelmRelease {
		k := ns + "/" + name
		r := byKey[k]
		if r == nil {
			r = &HelmRelease{Namespace: ns, Name: name, Charts: []HelmChart{}}
			byKey[k] = r
		}
		return r
	}
	// The release Secrets: the latest revision of each.
	if b.store.secretMeta != nil {
		objs, _ := b.store.secretMeta.List(labels.Everything())
		for _, o := range objs {
			m, ok := o.(*metav1.PartialObjectMetadata)
			if !ok || !strings.HasPrefix(m.Name, helmReleasePrefix) {
				continue
			}
			rest := strings.TrimPrefix(m.Name, helmReleasePrefix)
			i := strings.LastIndex(rest, ".v")
			if i <= 0 {
				continue
			}
			name := rest[:i]
			rev, err := strconv.Atoi(rest[i+2:])
			if err != nil {
				continue
			}
			r := get(m.Namespace, name)
			if rev < r.Revision {
				continue
			}
			r.Revision, r.Status = rev, m.Labels["status"]
			if t, err := strconv.ParseInt(m.Labels["modifiedAt"], 10, 64); err == nil {
				r.Updated = t
			} else {
				r.Updated = m.CreationTimestamp.Unix()
			}
		}
	}
	// What each chart made.
	var objs []helmObj
	add := func(kind string, m metav1.ObjectMeta, svc bool) {
		if rel, chart := helmOf(m); rel != "" {
			objs = append(objs, helmObj{kind: kind, name: m.Name, release: m.Namespace + "/" + rel, chart: chart, isService: svc})
		}
	}
	for _, d := range deps {
		add("Deployment", d.ObjectMeta, false)
	}
	for _, d := range sts {
		add("StatefulSet", d.ObjectMeta, false)
	}
	for _, d := range dss {
		add("DaemonSet", d.ObjectMeta, false)
	}
	for _, s := range svcs {
		add("Service", s.ObjectMeta, true)
	}
	for _, o := range objs {
		ns, rel, _ := strings.Cut(o.release, "/")
		r := get(ns, rel)
		if r.Status == "" && r.Revision == 0 {
			r.Status = "deployed" // seen only through its objects' labels
		}
		if o.chart == "" {
			continue
		}
		name, ver := splitChart(o.chart)
		var c *HelmChart
		for i := range r.Charts {
			if r.Charts[i].Name == name && r.Charts[i].Version == ver {
				c = &r.Charts[i]
			}
		}
		if c == nil {
			r.Charts = append(r.Charts, HelmChart{Name: name, Version: ver, Workloads: []string{}, Services: []string{}})
			c = &r.Charts[len(r.Charts)-1]
		}
		if o.isService {
			c.Services = append(c.Services, o.name)
		} else {
			c.Workloads = append(c.Workloads, o.kind+"/"+o.name)
		}
	}
	out := make([]HelmRelease, 0, len(byKey))
	for _, r := range byKey {
		names := map[string]bool{}
		for _, c := range r.Charts {
			names[c.Name] = true
			sort.Strings(c.Workloads)
			sort.Strings(c.Services)
		}
		r.Umbrella = len(names) > 1
		r.Chart = parentChart(r)
		// The parent first, then its subcharts by name.
		sort.SliceStable(r.Charts, func(i, j int) bool {
			pi, pj := r.Charts[i].Name+"-"+r.Charts[i].Version == r.Chart, r.Charts[j].Name+"-"+r.Charts[j].Version == r.Chart
			if pi != pj {
				return pi
			}
			return r.Charts[i].Name < r.Charts[j].Name
		})
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Namespace+"/"+out[i].Name < out[j].Namespace+"/"+out[j].Name })
	return out
}

// parentChart: the chart named like the release (or that the release name
// ends with); with one chart, that one; an umbrella without templates of
// its own has no parent among its objects ("").
func parentChart(r *HelmRelease) string {
	if len(r.Charts) == 1 {
		return r.Charts[0].Name + "-" + r.Charts[0].Version
	}
	for _, c := range r.Charts {
		if c.Name == r.Name || strings.HasSuffix(r.Name, "-"+c.Name) || strings.HasPrefix(r.Name, c.Name+"-") {
			return c.Name + "-" + c.Version
		}
	}
	return ""
}

// chartRepos: ChartMuseum services (by name, or selecting pods of a
// workload whose image is chartmuseum).
func chartRepos(deps []*appsv1.Deployment, svcs []*corev1.Service) []ChartRepo {
	out := []ChartRepo{}
	seen := map[string]bool{}
	addSvc := func(s *corev1.Service) {
		k := s.Namespace + "/" + s.Name
		if seen[k] || len(s.Spec.Ports) == 0 {
			return
		}
		seen[k] = true
		out = append(out, ChartRepo{Namespace: s.Namespace, Service: s.Name, Port: s.Spec.Ports[0].Port, Kind: "chartmuseum"})
	}
	for _, s := range svcs {
		if strings.Contains(s.Name, "chartmuseum") {
			addSvc(s)
		}
	}
	for _, d := range deps {
		if !strings.Contains(firstImage(d.Spec.Template.Spec), "chartmuseum") {
			continue
		}
		for _, s := range svcs {
			if s.Namespace == d.Namespace && len(s.Spec.Selector) > 0 &&
				labels.SelectorFromSet(s.Spec.Selector).Matches(labels.Set(d.Spec.Template.Labels)) {
				addSvc(s)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Namespace+"/"+out[i].Service < out[j].Namespace+"/"+out[j].Service })
	return out
}

// RepoChart: a chart in a repository (its latest version).
type RepoChart struct {
	Name        string `json:"name"`
	Version     string `json:"version"`
	AppVersion  string `json:"app_version,omitempty"`
	Description string `json:"description,omitempty"`
	Versions    int    `json:"versions"`
	Created     string `json:"created,omitempty"`
}

// parseChartMuseum: ChartMuseum's GET /api/charts is {name: [versions...]},
// newest first.
func parseChartMuseum(raw []byte) ([]RepoChart, error) {
	var idx map[string][]struct {
		Name        string `json:"name"`
		Version     string `json:"version"`
		AppVersion  string `json:"appVersion"`
		Description string `json:"description"`
		Created     string `json:"created"`
	}
	if err := json.Unmarshal(raw, &idx); err != nil {
		return nil, err
	}
	out := []RepoChart{}
	for name, vs := range idx {
		if len(vs) == 0 {
			continue
		}
		v := vs[0]
		desc := v.Description
		if len(desc) > 140 {
			desc = desc[:140] + "…"
		}
		out = append(out, RepoChart{Name: name, Version: v.Version, AppVersion: v.AppVersion, Description: desc, Versions: len(vs), Created: v.Created})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if len(out) > 300 {
		out = out[:300]
	}
	return out, nil
}

// GET /api/charts?ns=&svc=: the charts of a repository found in the cluster
// (only those: this is not a general proxy), through the API server's
// service proxy, as the player.
func (b *Bridge) handleCharts(w http.ResponseWriter, r *http.Request) {
	ns, svc := r.URL.Query().Get("ns"), r.URL.Query().Get("svc")
	var repo *ChartRepo
	deps, _ := b.depLister.List(labels.Everything())
	svcs, _ := b.svcLister.List(labels.Everything())
	for _, c := range chartRepos(deps, svcs) {
		if c.Namespace == ns && c.Service == svc {
			c := c
			repo = &c
		}
	}
	if repo == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "no chart repository " + ns + "/" + svc + " in this cluster"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	raw, err := b.clientFor(r.Context()).CoreV1().Services(ns).ProxyGet("http", svc, strconv.Itoa(int(repo.Port)), "/api/charts", nil).DoRaw(ctx)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": redact(err.Error())})
		return
	}
	charts, err := parseChartMuseum(raw)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "not a ChartMuseum index: " + err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "repo": repo, "charts": charts})
}
