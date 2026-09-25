package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
)

// Observability with history: Prometheus (trends: "since when?"),
// Alertmanager (the alerts the team already wrote) and Loki (logs of a whole
// namespace or workload). Found by themselves among the cluster's Services
// (kube-prometheus-stack, the Prometheus and Loki charts) or given with
// --prometheus / --alertmanager / --loki. From a laptop they are reached
// through the API server's service proxy (the kubeconfig's own credentials,
// no port-forward); from inside the cluster, by their Service DNS name.

// obsTarget: one backend and how to reach it.
type obsTarget struct {
	URL   string `json:"url,omitempty"`   // direct (flag or in-cluster DNS)
	NS    string `json:"ns,omitempty"`    // or through the API server proxy
	Svc   string `json:"svc,omitempty"`   //
	Port  string `json:"port,omitempty"`  //
	Found string `json:"found,omitempty"` // how it was found (for the UI)
}

func (t *obsTarget) ok() bool { return t != nil && (t.URL != "" || t.Svc != "") }

type observability struct {
	mu       sync.Mutex
	flags    map[string]string // prometheus/alertmanager/loki -> URL ("" = discover, "off")
	targets  map[string]*obsTarget
	checked  time.Time
	alerts   []Alert
	alertsAt time.Time
	volUse   map[string][2]float64 // "ns/claim" -> used, capacity (kubelet stats)
}

// Alert: a firing alert (Alertmanager, or a Prometheus rule).
type Alert struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Severity    string `json:"severity"` // critical | warning | info | none
	NS          string `json:"ns,omitempty"`
	Pod         string `json:"pod,omitempty"`
	Workload    string `json:"workload,omitempty"` // "Kind/name" when the labels say
	Node        string `json:"node,omitempty"`
	Summary     string `json:"summary,omitempty"`
	Description string `json:"description,omitempty"`
	Runbook     string `json:"runbook,omitempty"`
	Since       int64  `json:"since"` // seconds firing
	Source      string `json:"source"`
}

var obsCandidates = map[string][]struct{ name, port string }{
	"prometheus": {{"prometheus-operated", "9090"}, {"kube-prometheus-stack-prometheus", "9090"}, {"prometheus-kube-prometheus-prometheus", "9090"},
		{"prometheus-server", "80"}, {"prometheus", "9090"}, {"prometheus-k8s", "9090"}},
	"alertmanager": {{"alertmanager-operated", "9093"}, {"kube-prometheus-stack-alertmanager", "9093"},
		{"prometheus-kube-prometheus-alertmanager", "9093"}, {"prometheus-alertmanager", "9093"}, {"alertmanager-main", "9093"}, {"alertmanager", "9093"}},
	"loki": {{"loki-gateway", "80"}, {"loki", "3100"}, {"loki-read", "3100"}},
}

// discover finds the backends among the Services (at most every 5 minutes).
func (b *Bridge) discover() map[string]*obsTarget {
	o := &b.obs
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.targets != nil && time.Since(o.checked) < 5*time.Minute {
		return o.targets
	}
	o.checked = time.Now()
	out := map[string]*obsTarget{}
	svcs, _ := b.svcLister.List(labels.Everything())
	for kind := range obsCandidates {
		flag := o.flags[kind]
		if flag == "off" {
			continue
		}
		if flag != "" && flag != "auto" {
			out[kind] = &obsTarget{URL: strings.TrimRight(flag, "/"), Found: "--" + kind}
			continue
		}
		best, bestPort := pickService(kind, svcs)
		if best == nil {
			continue
		}
		t := &obsTarget{Found: best.Namespace + "/" + best.Name + ":" + bestPort}
		if b.inCluster {
			t.URL = fmt.Sprintf("http://%s.%s.svc:%s", best.Name, best.Namespace, bestPort)
		} else {
			t.NS, t.Svc, t.Port = best.Namespace, best.Name, bestPort
		}
		out[kind] = t
	}
	o.targets = out
	return out
}

// pickService: known names first (kube-prometheus-stack, the community
// charts), then any Service named like it on the usual port.
func pickService(kind string, svcs []*corev1.Service) (*corev1.Service, string) {
	cands := obsCandidates[kind]
	var best *corev1.Service
	bestPort := ""
	rank := 1 << 30
	for _, s := range svcs {
		for i, c := range cands {
			if (s.Name == c.name || strings.HasSuffix(s.Name, "-"+c.name)) && hasPort(s, c.port) && i < rank {
				best, bestPort, rank = s, c.port, i
			}
		}
	}
	if best != nil {
		return best, bestPort
	}
	want := map[string]int32{"prometheus": 9090, "alertmanager": 9093, "loki": 3100}[kind]
	for _, s := range svcs {
		if !strings.Contains(s.Name, kind) || noisy(s.Name) || (kind == "prometheus" && strings.Contains(s.Name, "alertmanager")) {
			continue
		}
		for _, p := range s.Spec.Ports {
			if p.Port == want {
				return s, strconv.Itoa(int(p.Port))
			}
		}
	}
	return nil, ""
}

func hasPort(s *corev1.Service, port string) bool {
	for _, p := range s.Spec.Ports {
		if strconv.Itoa(int(p.Port)) == port {
			return true
		}
	}
	return false
}

// noisy: services with the name that are not the server itself.
func noisy(name string) bool {
	for _, w := range []string{"operator", "node-exporter", "kube-state", "pushgateway", "adapter", "blackbox", "canary", "memberlist", "headless", "discovery"} {
		if strings.Contains(name, w) {
			return true
		}
	}
	return false
}

// obsGet performs a GET on a backend (directly or through the API server).
func (b *Bridge) obsGet(ctx context.Context, kind, path string, q url.Values) ([]byte, error) {
	t := b.discover()[kind]
	if !t.ok() {
		return nil, fmt.Errorf("no %s found in the cluster (install it, or start the bridge with --%s URL)", kind, kind)
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if t.URL != "" {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, t.URL+path+"?"+q.Encode(), nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		if resp.StatusCode >= 300 {
			return nil, fmt.Errorf("%s: %s %s", kind, resp.Status, strings.TrimSpace(string(body)))
		}
		return body, nil
	}
	params := map[string]string{}
	for k, v := range q {
		params[k] = v[0]
	}
	// The bridge's own identity: metrics and logs are shown to whoever sees
	// the cluster (like the rest of the world), not changed.
	return b.cs.CoreV1().Services(t.NS).ProxyGet("http", t.Svc, t.Port, path, params).DoRaw(ctx)
}

// GET /api/obs: what was found.
func (b *Bridge) handleObs(w http.ResponseWriter, r *http.Request) {
	t := b.discover()
	out := map[string]any{"ok": true}
	for _, k := range []string{"prometheus", "alertmanager", "loki"} {
		out[k] = t[k]
	}
	writeJSON(w, http.StatusOK, out)
}

// --- Prometheus: trends ------------------------------------------------------

type point [2]float64 // unix time, value

var ranges = map[string]time.Duration{"1h": time.Hour, "6h": 6 * time.Hour, "24h": 24 * time.Hour, "7d": 7 * 24 * time.Hour}

// seriesQueries: PromQL for a pod, a workload or a node (cAdvisor +
// kube-state-metrics, as kube-prometheus-stack ships them).
func seriesQueries(kind, ns, name string) (map[string]string, error) {
	if !dnsName.MatchString(name) || (ns != "" && !dnsName.MatchString(ns)) {
		return nil, errors.New("bad name")
	}
	var sel string
	switch kind {
	case "pod":
		sel = fmt.Sprintf(`namespace=%q,pod=%q`, ns, name)
	case "workload":
		// Pods of a Deployment (name-rs-hash), a StatefulSet (name-0) or a
		// DaemonSet (name-hash).
		sel = fmt.Sprintf(`namespace=%q,pod=~%q`, ns, name+"-([a-z0-9]+-)?[a-z0-9]+")
	case "node":
		cpu := fmt.Sprintf(`sum(rate(container_cpu_usage_seconds_total{container!=""}[5m]) * on(namespace,pod) group_left(node) max by(namespace,pod,node) (kube_pod_info{node=%q}))`, name)
		mem := fmt.Sprintf(`sum(container_memory_working_set_bytes{container!=""} * on(namespace,pod) group_left(node) max by(namespace,pod,node) (kube_pod_info{node=%q}))`, name)
		return map[string]string{"cpu": cpu, "mem": mem}, nil
	default:
		return nil, errors.New("kind must be pod, workload or node")
	}
	return map[string]string{
		"cpu":      fmt.Sprintf(`sum(rate(container_cpu_usage_seconds_total{%s,container!=""}[5m]))`, sel),
		"mem":      fmt.Sprintf(`sum(container_memory_working_set_bytes{%s,container!=""})`, sel),
		"restarts": fmt.Sprintf(`sum(kube_pod_container_status_restarts_total{%s})`, sel),
	}, nil
}

// GET /api/series?kind=pod|workload|node&ns=&name=&range=1h: history from Prometheus.
func (b *Bridge) handleSeries(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	span, ok := ranges[q.Get("range")]
	if !ok {
		span = time.Hour
	}
	qs, err := seriesQueries(q.Get("kind"), q.Get("ns"), q.Get("name"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	end := time.Now()
	step := span / 60
	out := map[string]any{"ok": true, "range": q.Get("range"), "step": step.Seconds()}
	var errs []string
	for k, pq := range qs {
		pts, err := b.promRange(r.Context(), pq, end.Add(-span), end, step)
		if err != nil {
			errs = append(errs, k+": "+err.Error())
			continue
		}
		out[k] = pts
	}
	if len(errs) == len(qs) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": strings.Join(errs, "; ")})
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (b *Bridge) promRange(ctx context.Context, query string, start, end time.Time, step time.Duration) ([]point, error) {
	v := url.Values{"query": {query}, "start": {strconv.FormatInt(start.Unix(), 10)}, "end": {strconv.FormatInt(end.Unix(), 10)},
		"step": {strconv.Itoa(max(15, int(step.Seconds())))}}
	raw, err := b.obsGet(ctx, "prometheus", "/api/v1/query_range", v)
	if err != nil {
		return nil, err
	}
	var res struct {
		Status string `json:"status"`
		Error  string `json:"error"`
		Data   struct {
			Result []struct {
				Values [][2]any `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, fmt.Errorf("prometheus answered something else: %.120s", raw)
	}
	if res.Status != "success" {
		return nil, errors.New(res.Error)
	}
	pts := []point{}
	if len(res.Data.Result) == 0 {
		return pts, nil
	}
	for _, v := range res.Data.Result[0].Values {
		t, _ := v[0].(float64)
		s, _ := v[1].(string)
		f, err := strconv.ParseFloat(s, 64)
		if err == nil {
			pts = append(pts, point{t, f})
		}
	}
	return pts, nil
}

// --- Alerts ------------------------------------------------------------------

// alertLoop keeps the firing alerts fresh (every 30 s) for the snapshot.
func (b *Bridge) alertLoop(ctx context.Context) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		b.fetchVolumeUse(ctx)
		list, err := b.fetchAlerts(ctx)
		if err == nil {
			b.obs.mu.Lock()
			changed := !sameAlerts(b.obs.alerts, list)
			b.obs.alerts, b.obs.alertsAt = list, time.Now()
			b.obs.mu.Unlock()
			if changed {
				b.markDirty()
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func (b *Bridge) currentAlerts() []Alert {
	b.obs.mu.Lock()
	defer b.obs.mu.Unlock()
	return append([]Alert(nil), b.obs.alerts...)
}

func sameAlerts(a, c []Alert) bool {
	if len(a) != len(c) {
		return false
	}
	for i := range a {
		if a[i].ID != c[i].ID || a[i].Summary != c[i].Summary {
			return false
		}
	}
	return true
}

// fetchAlerts asks Alertmanager (silenced and inhibited ones are left out),
// or else Prometheus's firing rules.
func (b *Bridge) fetchAlerts(ctx context.Context) ([]Alert, error) {
	t := b.discover()
	var list []Alert
	if t["alertmanager"].ok() {
		raw, err := b.obsGet(ctx, "alertmanager", "/api/v2/alerts", url.Values{"active": {"true"}, "silenced": {"false"}, "inhibited": {"false"}})
		if err != nil {
			return nil, err
		}
		var am []struct {
			Fingerprint string            `json:"fingerprint"`
			Labels      map[string]string `json:"labels"`
			Annotations map[string]string `json:"annotations"`
			StartsAt    time.Time         `json:"startsAt"`
		}
		if err := json.Unmarshal(raw, &am); err != nil {
			return nil, err
		}
		for _, a := range am {
			list = append(list, makeAlert(a.Fingerprint, a.Labels, a.Annotations, a.StartsAt, "alertmanager"))
		}
	} else if t["prometheus"].ok() {
		raw, err := b.obsGet(ctx, "prometheus", "/api/v1/alerts", url.Values{})
		if err != nil {
			return nil, err
		}
		var pr struct {
			Data struct {
				Alerts []struct {
					Labels      map[string]string `json:"labels"`
					Annotations map[string]string `json:"annotations"`
					State       string            `json:"state"`
					ActiveAt    time.Time         `json:"activeAt"`
				} `json:"alerts"`
			} `json:"data"`
		}
		if err := json.Unmarshal(raw, &pr); err != nil {
			return nil, err
		}
		for _, a := range pr.Data.Alerts {
			if a.State != "firing" {
				continue
			}
			list = append(list, makeAlert("", a.Labels, a.Annotations, a.ActiveAt, "prometheus"))
		}
	} else {
		return nil, nil
	}
	// Watchdog / InfoInhibitor are plumbing, not problems.
	kept := list[:0]
	for _, a := range list {
		if a.Name != "Watchdog" && a.Name != "InfoInhibitor" {
			kept = append(kept, a)
		}
	}
	sevRank := map[string]int{"critical": 0, "warning": 1, "info": 2}
	sort.Slice(kept, func(i, j int) bool {
		ri, ok1 := sevRank[kept[i].Severity]
		rj, ok2 := sevRank[kept[j].Severity]
		if !ok1 {
			ri = 3
		}
		if !ok2 {
			rj = 3
		}
		if ri != rj {
			return ri < rj
		}
		return kept[i].ID < kept[j].ID
	})
	return kept, nil
}

func makeAlert(id string, l, an map[string]string, since time.Time, src string) Alert {
	if id == "" {
		keys := make([]string, 0, len(l))
		for k := range l {
			keys = append(keys, k+"="+l[k])
		}
		sort.Strings(keys)
		id = strings.Join(keys, ",")
	}
	a := Alert{ID: id, Name: l["alertname"], Severity: l["severity"], NS: l["namespace"], Pod: l["pod"], Node: l["node"],
		Summary: an["summary"], Description: an["description"], Runbook: an["runbook_url"], Source: src}
	if a.Summary == "" {
		a.Summary = an["message"]
	}
	for _, k := range []string{"deployment", "statefulset", "daemonset"} {
		if v := l[k]; v != "" {
			a.Workload = map[string]string{"deployment": "Deployment", "statefulset": "StatefulSet", "daemonset": "DaemonSet"}[k] + "/" + v
		}
	}
	if !since.IsZero() {
		a.Since = int64(time.Since(since).Seconds())
	}
	a.Summary, a.Description = redact(a.Summary), redact(a.Description)
	return a
}

// --- Loki: logs of many pods -------------------------------------------------

type logLine struct {
	T         int64  `json:"t"` // unix ms
	Pod       string `json:"pod"`
	Container string `json:"container"`
	Line      string `json:"line"`
}

// GET /api/logsearch?ns=&workload=&q=&since=1h&limit=300: newest first.
func (b *Bridge) handleLogSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	ns, wl := q.Get("ns"), q.Get("workload")
	if !dnsName.MatchString(ns) || (wl != "" && !dnsName.MatchString(wl)) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "bad namespace or workload"})
		return
	}
	span, ok := ranges[q.Get("since")]
	if !ok {
		span = time.Hour
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 1000 {
		limit = 300
	}
	sel := fmt.Sprintf(`namespace=%q`, ns)
	if wl != "" {
		sel += fmt.Sprintf(`,pod=~%q`, wl+"-([a-z0-9]+-)?[a-z0-9]+")
	}
	logql := "{" + sel + "}"
	if text := q.Get("q"); text != "" {
		logql += fmt.Sprintf(" |= %q", text)
	}
	end := time.Now()
	v := url.Values{"query": {logql}, "start": {strconv.FormatInt(end.Add(-span).UnixNano(), 10)}, "end": {strconv.FormatInt(end.UnixNano(), 10)},
		"limit": {strconv.Itoa(limit)}, "direction": {"backward"}}
	raw, err := b.obsGet(r.Context(), "loki", "/loki/api/v1/query_range", v)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	var res struct {
		Data struct {
			Result []struct {
				Stream map[string]string `json:"stream"`
				Values [][2]string       `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": fmt.Sprintf("loki answered something else: %.120s", raw)})
		return
	}
	var lines []logLine
	for _, s := range res.Data.Result {
		for _, v := range s.Values {
			ns, _ := strconv.ParseInt(v[0], 10, 64)
			lines = append(lines, logLine{T: ns / 1e6, Pod: s.Stream["pod"], Container: s.Stream["container"], Line: v[1]})
		}
	}
	sort.Slice(lines, func(i, j int) bool { return lines[i].T > lines[j].T })
	if len(lines) > limit {
		lines = lines[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "query": logql, "lines": lines})
}
