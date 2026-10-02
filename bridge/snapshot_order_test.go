package main

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/tools/cache"
)

func dynLister(t *testing.T, objs ...map[string]any) cache.GenericLister {
	t.Helper()
	idx := cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{})
	for _, o := range objs {
		if err := idx.Add(&unstructured.Unstructured{Object: o}); err != nil {
			t.Fatal(err)
		}
	}
	return cache.NewGenericLister(idx, schema.GroupResource{})
}

func meta(ns, name string) map[string]any {
	return map[string]any{"namespace": ns, "name": name}
}

// Lists built from several sources (Argo CD + Flux apps, Ingresses +
// Gateway API routes) still come in one order, the one the game rebuilds
// after a patch: a full state and a patched one must look the same.
func TestSnapshotMergedListsKeepOneOrder(t *testing.T) {
	b := newTestBridge(t, snapshotFixture()...)
	b.res.dyn = map[string]cache.GenericLister{
		"apps":     dynLister(t, map[string]any{"metadata": meta("zz-argo", "shop")}),
		"fluxks":   dynLister(t, map[string]any{"metadata": meta("flux-system", "apps")}),
		"routes":   dynLister(t, map[string]any{"metadata": meta("shop", "api"), "spec": map[string]any{}}),
		"gateways": dynLister(t),
	}
	s, err := b.buildSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	assertSnapshotInvariants(t, s)
	if len(s.Apps) != 2 || s.Apps[0].Namespace != "flux-system" || s.Apps[1].Tool != "argocd" {
		t.Errorf("apps: %+v", s.Apps)
	}
	var names []string
	for _, in := range s.Ingresses {
		names = append(names, in.Namespace+"/"+in.Name)
	}
	if len(names) != 2 || names[0] != "shop/httproute/api" || names[1] != "shop/web" {
		t.Errorf("ingresses + routes: %v", names)
	}
}
