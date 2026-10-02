package main

import (
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/cache"
)

func TestSplitChart(t *testing.T) {
	for in, want := range map[string][2]string{
		"redis-17.3.2":                  {"redis", "17.3.2"},
		"kube-prometheus-stack-65.1.0":  {"kube-prometheus-stack", "65.1.0"},
		"cert-manager-v1.16.1":          {"cert-manager", "v1.16.1"},
		"prometheus-node-exporter-4.39": {"prometheus-node-exporter", "4.39"},
	} {
		if n, v := splitChart(in); n != want[0] || v != want[1] {
			t.Errorf("%s: %s %s", in, n, v)
		}
	}
}

type secretMetaLister struct{ objs []runtime.Object }

func (l secretMetaLister) List(labels.Selector) ([]runtime.Object, error) { return l.objs, nil }
func (l secretMetaLister) Get(string) (runtime.Object, error)             { return nil, nil }
func (l secretMetaLister) ByNamespace(string) cache.GenericNamespaceLister {
	return nil
}

// An umbrella: the release secret's latest revision, its parent chart and a
// subchart found through the objects' labels.
func TestHelmUmbrella(t *testing.T) {
	sec := func(name, status string) *metav1.PartialObjectMetadata {
		m := &metav1.PartialObjectMetadata{ObjectMeta: metav1.ObjectMeta{Namespace: "monitoring", Name: name, CreationTimestamp: metav1.NewTime(time.Unix(1000, 0)),
			Labels: map[string]string{"owner": "helm", "status": status, "name": "kps", "modifiedAt": "1700000000", "secret-data": "x"}}}
		m.Labels = keepHelmLabels(m)
		return m
	}
	b := &Bridge{store: storeListers{secretMeta: secretMetaLister{objs: []runtime.Object{
		sec("sh.helm.release.v1.kube-prometheus-stack.v6", "superseded"), sec("sh.helm.release.v1.kube-prometheus-stack.v7", "deployed")}}}}
	meta := func(name, chart string) metav1.ObjectMeta {
		return metav1.ObjectMeta{Namespace: "monitoring", Name: name, Labels: map[string]string{"helm.sh/chart": chart, "app.kubernetes.io/managed-by": "Helm"},
			Annotations: map[string]string{"meta.helm.sh/release-name": "kube-prometheus-stack"}}
	}
	deps := []*appsv1.Deployment{{ObjectMeta: meta("kps-operator", "kube-prometheus-stack-65.1.0")}, {ObjectMeta: meta("kps-kube-state-metrics", "kube-state-metrics-5.25.1")}}
	dss := []*appsv1.DaemonSet{{ObjectMeta: meta("kps-node-exporter", "prometheus-node-exporter-4.39.0")}}
	svcs := []*corev1.Service{{ObjectMeta: meta("kps-kube-state-metrics", "kube-state-metrics-5.25.1")}}
	rs := b.helmReleases(deps, nil, dss, svcs)
	if len(rs) != 1 {
		t.Fatalf("releases: %+v", rs)
	}
	r := rs[0]
	if r.Revision != 7 || r.Status != "deployed" || r.Updated != 1700000000 || !r.Umbrella || r.Chart != "kube-prometheus-stack-65.1.0" {
		t.Errorf("release: %+v", r)
	}
	if len(r.Charts) != 3 || r.Charts[0].Name != "kube-prometheus-stack" || r.Charts[1].Name != "kube-state-metrics" || r.Charts[1].Services[0] != "kps-kube-state-metrics" {
		t.Errorf("charts: %+v", r.Charts)
	}
	if _, leaked := sec("sh.helm.release.v1.x.v1", "deployed").Labels["secret-data"]; leaked {
		t.Error("only Helm's own labels are kept")
	}
}

func TestChartMuseumIndex(t *testing.T) {
	cs, err := parseChartMuseum([]byte(`{"web":[{"name":"web","version":"1.2.0","appVersion":"2.0","description":"our site"},{"name":"web","version":"1.1.0"}],"api":[{"name":"api","version":"0.3.1"}]}`))
	if err != nil || len(cs) != 2 || cs[0].Name != "api" || cs[1].Version != "1.2.0" || cs[1].Versions != 2 {
		t.Errorf("%v %+v", err, cs)
	}
	repos := chartRepos(nil, []*corev1.Service{{ObjectMeta: metav1.ObjectMeta{Namespace: "charts", Name: "chartmuseum"}, Spec: corev1.ServiceSpec{Ports: []corev1.ServicePort{{Port: 8080}}}}})
	if len(repos) != 1 || repos[0].Port != 8080 {
		t.Errorf("repos: %+v", repos)
	}
}
