package main

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestFluxKustomization(t *testing.T) {
	u := &unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{"namespace": "flux-system", "name": "apps"},
		"spec": map[string]any{"path": "./apps/prod", "targetNamespace": "shop",
			"sourceRef": map[string]any{"kind": "GitRepository", "name": "platform"}},
		"status": map[string]any{
			"lastAppliedRevision":   "main@sha1:4f1c2e9a77b0c1d2",
			"lastAttemptedRevision": "main@sha1:9d8e7f6a5b4c3d2e",
			"inventory":             map[string]any{"entries": []any{map[string]any{}, map[string]any{}, map[string]any{}}},
			"conditions": []any{
				map[string]any{"type": "Ready", "status": "False", "reason": "ReconciliationFailed", "message": "Deployment/shop/cart dry-run failed"},
			},
		},
	}}
	a := fluxApp(u, "Kustomization", map[string]string{"GitRepository/flux-system/platform": "https://github.com/acme/platform"})
	if a.Tool != "flux" || a.Kind != "Kustomization" || a.DestNS != "shop" || a.Path != "./apps/prod" {
		t.Errorf("where: %+v", a)
	}
	if a.Repo != "https://github.com/acme/platform" || a.Revision != "main@4f1c2e9" || a.Resources != 3 {
		t.Errorf("source: %+v", a)
	}
	if a.Sync != "OutOfSync" || a.Health != "Degraded" || a.Operation != "Failed" || a.Message == "" || !a.SelfHeal {
		t.Errorf("state: %+v", a)
	}
}

func TestFluxHelmRelease(t *testing.T) {
	u := &unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{"namespace": "monitoring", "name": "grafana"},
		"spec": map[string]any{"suspend": true, "chart": map[string]any{"spec": map[string]any{"chart": "grafana",
			"sourceRef": map[string]any{"kind": "HelmRepository", "name": "grafana", "namespace": "flux-system"}}}},
		"status": map[string]any{
			"history":    []any{map[string]any{"chartVersion": "8.5.1"}},
			"conditions": []any{map[string]any{"type": "Ready", "status": "True"}, map[string]any{"type": "Reconciling", "status": "True"}},
		},
	}}
	a := fluxApp(u, "HelmRelease", map[string]string{"HelmRepository/flux-system/grafana": "https://grafana.github.io/helm-charts"})
	if a.DestNS != "monitoring" || a.Path != "grafana" || a.Repo != "https://grafana.github.io/helm-charts" || a.Revision != "8.5.1" {
		t.Errorf("where: %+v", a)
	}
	if a.Sync != "Synced" || a.Health != "Suspended" || a.Operation != "Running" || a.AutoSync || a.Message != "" {
		t.Errorf("state: %+v", a)
	}
}
