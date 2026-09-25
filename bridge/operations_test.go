package main

import (
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestGitOpsOwners(t *testing.T) {
	cases := []struct {
		meta metav1.ObjectMeta
		tool string
		name string
	}{
		{metav1.ObjectMeta{Annotations: map[string]string{"argocd.argoproj.io/tracking-id": "shop:apps/Deployment:shop/api"}}, "argocd", "shop"},
		{metav1.ObjectMeta{Labels: map[string]string{"kustomize.toolkit.fluxcd.io/name": "apps", "kustomize.toolkit.fluxcd.io/namespace": "flux-system"}}, "flux", "Kustomization flux-system/apps"},
		{metav1.ObjectMeta{Labels: map[string]string{"app.kubernetes.io/managed-by": "Helm"}, Annotations: map[string]string{"meta.helm.sh/release-name": "redis"}}, "helm", "redis"},
	}
	for _, c := range cases {
		g := gitOpsOf(c.meta)
		if g == nil || g.Tool != c.tool || g.Name != c.name {
			t.Errorf("%v: got %+v", c.meta, g)
		}
	}
	// app.kubernetes.io/instance alone is too common to mean Argo CD.
	if g := gitOpsOf(metav1.ObjectMeta{Labels: map[string]string{"app.kubernetes.io/instance": "x"}}); g != nil {
		t.Errorf("plain instance label is not GitOps: %+v", g)
	}
}

func TestDiffYAMLDropsNoise(t *testing.T) {
	raw := []byte(`{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"api","resourceVersion":"9","generation":3,
		"managedFields":[{"manager":"kubectl"}],"annotations":{"deployment.kubernetes.io/revision":"4"}},"spec":{"replicas":2},"status":{"replicas":2}}`)
	y := diffYAML(raw)
	for _, noise := range []string{"resourceVersion", "managedFields", "generation", "status", "revision"} {
		if strings.Contains(y, noise) {
			t.Errorf("%q should be gone:\n%s", noise, y)
		}
	}
	if !strings.Contains(y, "replicas: 2") {
		t.Errorf("spec lost:\n%s", y)
	}
}
