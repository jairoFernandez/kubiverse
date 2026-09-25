package main

import (
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func svc(ns, name string, ports ...int32) *corev1.Service {
	s := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name}}
	for _, p := range ports {
		s.Spec.Ports = append(s.Spec.Ports, corev1.ServicePort{Port: p})
	}
	return s
}

func TestFindsTheBackends(t *testing.T) {
	svcs := []*corev1.Service{
		svc("monitoring", "kps-kube-prometheus-stack-operator", 443),
		svc("monitoring", "kps-prometheus-node-exporter", 9100),
		svc("monitoring", "prometheus-operated", 9090),
		svc("monitoring", "kps-kube-prometheus-stack-prometheus", 9090, 8080),
		svc("monitoring", "alertmanager-operated", 9093, 9094),
		svc("logging", "loki-canary", 3500),
		svc("logging", "loki-gateway", 80),
		svc("logging", "loki", 3100),
	}
	for kind, want := range map[string]string{"prometheus": "prometheus-operated", "alertmanager": "alertmanager-operated", "loki": "loki-gateway"} {
		got, _ := pickService(kind, svcs)
		if got == nil || got.Name != want {
			t.Errorf("%s: got %v, want %s", kind, got, want)
		}
	}
	// Unknown name, usual port.
	if got, port := pickService("prometheus", []*corev1.Service{svc("obs", "my-prometheus", 9090)}); got == nil || port != "9090" {
		t.Errorf("fallback: %v %s", got, port)
	}
	if got, _ := pickService("prometheus", []*corev1.Service{svc("obs", "prometheus-operator", 9090)}); got != nil {
		t.Errorf("the operator is not Prometheus")
	}
}

func TestSeriesQueriesAreSafe(t *testing.T) {
	if _, err := seriesQueries("pod", "shop", `x"}) or vector(1`); err == nil {
		t.Fatal("names are validated")
	}
	q, err := seriesQueries("workload", "shop", "api")
	if err != nil || !strings.Contains(q["cpu"], `pod=~"api-([a-z0-9]+-)?[a-z0-9]+"`) {
		t.Fatalf("%v %v", q, err)
	}
	if q, _ := seriesQueries("node", "", "worker-a"); !strings.Contains(q["cpu"], `kube_pod_info{node="worker-a"}`) {
		t.Fatal(q)
	}
}

func TestAlertFromLabels(t *testing.T) {
	a := makeAlert("", map[string]string{"alertname": "KubePodCrashLooping", "severity": "warning", "namespace": "shop", "pod": "api-1", "deployment": "api"},
		map[string]string{"description": "token=abc123secret is failing", "runbook_url": "https://runbooks/x"}, time.Now().Add(-time.Minute), "prometheus")
	if a.Name != "KubePodCrashLooping" || a.Workload != "Deployment/api" || a.Since < 59 || a.ID == "" {
		t.Fatalf("%+v", a)
	}
	if strings.Contains(a.Description, "abc123secret") {
		t.Fatal("secrets are redacted")
	}
}
