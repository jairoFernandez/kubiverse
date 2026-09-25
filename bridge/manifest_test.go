package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPrepareEdited(t *testing.T) {
	ok := "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 3\n"
	js, err := prepareEdited(ok, "Deployment", "shop", "web")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(js), `"namespace":"shop"`) {
		t.Fatalf("namespace not set: %s", js)
	}
	for name, src := range map[string]string{
		"rename":    strings.Replace(ok, "name: web", "name: other", 1),
		"kind":      strings.Replace(ok, "kind: Deployment", "kind: Secret", 1),
		"namespace": strings.Replace(ok, "  name: web\n", "  name: web\n  namespace: kube-system\n", 1),
		"yaml":      "kind: [",
		"list":      "- a\n- b\n",
	} {
		if _, err := prepareEdited(src, "Deployment", "shop", "web"); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, _, err := manifestTarget("secret", "shop", "db"); err == nil {
		t.Error("secrets must not be editable")
	}
	if k, ns, err := manifestTarget("node", "x", "n1"); err != nil || k != "Node" || ns != "" {
		t.Errorf("node: %q %q %v", k, ns, err)
	}
}

func TestCleanAndRestoreLastApplied(t *testing.T) {
	cur := map[string]any{"status": map[string]any{"x": 1}, "metadata": map[string]any{"name": "web",
		"managedFields": []any{1}, "annotations": map[string]any{lastApplied: "{...}"}}}
	cleanObject(cur)
	if _, has := cur["status"]; has {
		t.Fatal("status kept")
	}
	md := cur["metadata"].(map[string]any)
	if _, has := md["managedFields"]; has {
		t.Fatal("managedFields kept")
	}
	if _, has := md["annotations"]; has {
		t.Fatal("empty annotations kept")
	}
	orig := map[string]any{"metadata": map[string]any{"annotations": map[string]any{lastApplied: "{orig}"}}}
	out := restoreLastApplied([]byte(`{"metadata":{"name":"web"}}`), orig)
	var obj map[string]any
	json.Unmarshal(out, &obj)
	if obj["metadata"].(map[string]any)["annotations"].(map[string]any)[lastApplied] != "{orig}" {
		t.Fatalf("not restored: %s", out)
	}
}
