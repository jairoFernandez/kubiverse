package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

func actionBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("body %q: %v", rec.Body.String(), err)
	}
	return out
}

func TestHandleActionGuards(t *testing.T) {
	b := newTestBridge(t)
	// Bad JSON never reaches the cluster.
	rec := httptest.NewRecorder()
	b.handleAction(rec, httptest.NewRequest("POST", "/api/action", strings.NewReader(`{"action":`)))
	if rec.Code != 400 {
		t.Errorf("bad json: %d", rec.Code)
	}
	// Read-only bridge: refused, whatever the action.
	b.readOnly = true
	rec = httptest.NewRecorder()
	b.handleAction(rec, httptest.NewRequest("POST", "/api/action", strings.NewReader(`{"action":"delete_pod","ns":"a","name":"b"}`)))
	if rec.Code != 403 || !strings.Contains(rec.Body.String(), "read-only") {
		t.Errorf("readonly: %d %s", rec.Code, rec.Body.String())
	}
	// Production: goes through only with the confirmation header, and is audited.
	b.readOnly = false
	b.pol = newPolicy(t.TempDir(), []string{"test"})
	req := httptest.NewRequest("POST", "/api/action", strings.NewReader(`{"action":"cordon","name":"worker-a"}`))
	req.Header.Set(ConfirmHeader, "test")
	rec = httptest.NewRecorder()
	b.handleAction(rec, req)
	if out := actionBody(t, rec); rec.Code != 200 || out["ok"] != false || !strings.Contains(out["error"].(string), "not found") {
		t.Errorf("confirmed cordon of a missing node reaches the API: %d %v", rec.Code, out)
	}
	got := b.pol.audit.last(5, "test")
	if len(got) != 1 || !got[0].Confirmed || got[0].OK || got[0].Target != "worker-a" {
		t.Errorf("audit: %+v", got)
	}
	// --production pins the kind: the game cannot turn it into a sandbox.
	if err := b.pol.setKind("test", "sandbox"); err == nil {
		t.Error("a --production context cannot become a sandbox")
	}
}

func TestDoActionValidation(t *testing.T) {
	b := newTestBridge(t)
	ctx := context.Background()
	for _, req := range []ActionRequest{
		{Action: "scale", Kind: "Deployment", NS: "a", Name: "b", Replicas: -1},
		{Action: "scale", Kind: "Deployment", NS: "a", Name: "b", Replicas: 51},
		{Action: "scale", Kind: "DaemonSet", NS: "a", Name: "b", Replicas: 2},
		{Action: "restart", Kind: "Job", NS: "a", Name: "b"},
		{Action: "pause", Kind: "StatefulSet", NS: "a", Name: "b"},
		{Action: "rollout_undo", Kind: "DaemonSet", NS: "a", Name: "b"},
		{Action: "create_deployment", NS: "Bad_NS", Name: "web"},
		{Action: "create_deployment", NS: "shop", Name: "-web"},
		{Action: "delete_workload", Kind: "Pod", NS: "a", Name: "b"},
		{Action: "launch_missiles"},
	} {
		if _, err := b.doAction(ctx, req); err == nil {
			t.Errorf("%+v: expected an error", req)
		}
	}
}

func TestDoActionAgainstTheAPI(t *testing.T) {
	dep := &appsv1.Deployment{ObjectMeta: objMeta("shop", "api", t0)}
	dep.Annotations = map[string]string{"argocd.argoproj.io/tracking-id": "shop:apps/Deployment:shop/api"}
	sts := &appsv1.StatefulSet{ObjectMeta: objMeta("shop", "db", t0)}
	ds := &appsv1.DaemonSet{ObjectMeta: objMeta("kube-system", "proxy", t0)}
	hpa := &autoscalingv2.HorizontalPodAutoscaler{ObjectMeta: objMeta("shop", "api", t0),
		Spec: autoscalingv2.HorizontalPodAutoscalerSpec{ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{Kind: "Deployment", Name: "api"}, MinReplicas: ptr(int32(2)), MaxReplicas: 5}}
	b := newTestBridge(t, dep, sts, ds, hpa,
		&corev1.Node{ObjectMeta: objMeta("", "worker-a", t0)},
		runningPod("shop", "api-1", "worker-a", nil, true),
		&corev1.Service{ObjectMeta: objMeta("shop", "api", t0)})
	cs := b.cs.(*fake.Clientset)
	ctx := context.Background()
	do := func(req ActionRequest) string {
		t.Helper()
		msg, err := b.doAction(ctx, req)
		if err != nil {
			t.Fatalf("%+v: %v", req, err)
		}
		return msg
	}

	// Scaling a Deployment an HPA and Argo CD own says so.
	msg := do(ActionRequest{Action: "scale", Kind: "Deployment", NS: "shop", Name: "api", Replicas: 4})
	if !strings.Contains(msg, "scaled to 4") || !strings.Contains(msg, "HPA api owns the replicas (2-5)") || !strings.Contains(msg, "Argo CD") {
		t.Errorf("scale note: %q", msg)
	}
	if d, _ := cs.AppsV1().Deployments("shop").Get(ctx, "api", metav1.GetOptions{}); d.Spec.Replicas == nil || *d.Spec.Replicas != 4 {
		t.Errorf("replicas not patched: %+v", d.Spec.Replicas)
	}
	do(ActionRequest{Action: "scale", Kind: "StatefulSet", NS: "shop", Name: "db", Replicas: 0})
	for _, k := range []string{"Deployment", "StatefulSet", "DaemonSet"} {
		name := map[string]string{"Deployment": "api", "StatefulSet": "db", "DaemonSet": "proxy"}[k]
		ns := map[string]string{"DaemonSet": "kube-system"}[k]
		if ns == "" {
			ns = "shop"
		}
		if m := do(ActionRequest{Action: "restart", Kind: k, NS: ns, Name: name}); !strings.Contains(m, "rollout restarted") {
			t.Errorf("restart %s: %q", k, m)
		}
	}
	d, _ := cs.AppsV1().Deployments("shop").Get(ctx, "api", metav1.GetOptions{})
	if d.Spec.Template.Annotations["kubectl.kubernetes.io/restartedAt"] == "" {
		t.Error("restart leaves restartedAt on the template")
	}
	if m := do(ActionRequest{Action: "pause", Kind: "Deployment", NS: "shop", Name: "api"}); !strings.Contains(m, "paused") {
		t.Errorf("pause: %q", m)
	}
	if d, _ := cs.AppsV1().Deployments("shop").Get(ctx, "api", metav1.GetOptions{}); !d.Spec.Paused {
		t.Error("not paused")
	}
	if m := do(ActionRequest{Action: "resume", Kind: "Deployment", NS: "shop", Name: "api"}); !strings.Contains(m, "resumed") {
		t.Errorf("resume: %q", m)
	}
	if m := do(ActionRequest{Action: "cordon", Name: "worker-a"}); m != "node worker-a cordoned" {
		t.Errorf("cordon: %q", m)
	}
	if n, _ := cs.CoreV1().Nodes().Get(ctx, "worker-a", metav1.GetOptions{}); !n.Spec.Unschedulable {
		t.Error("not cordoned")
	}
	do(ActionRequest{Action: "uncordon", Name: "worker-a"})

	// Create: a new namespace when needed, default image and replicas, a Service.
	if m := do(ActionRequest{Action: "create_deployment", NS: "lab", Name: "hello", Replicas: 99, Service: true}); m != "deployment and service lab/hello created" {
		t.Errorf("create: %q", m)
	}
	nd, err := cs.AppsV1().Deployments("lab").Get(ctx, "hello", metav1.GetOptions{})
	if err != nil || *nd.Spec.Replicas != 1 || nd.Spec.Template.Spec.Containers[0].Image != "nginx:alpine" {
		t.Errorf("created deployment: %+v %v", nd, err)
	}
	if _, err := cs.CoreV1().Namespaces().Get(ctx, "lab", metav1.GetOptions{}); err != nil {
		t.Errorf("namespace not created: %v", err)
	}
	if _, err := cs.CoreV1().Services("lab").Get(ctx, "hello", metav1.GetOptions{}); err != nil {
		t.Errorf("service not created: %v", err)
	}
	if m := do(ActionRequest{Action: "create_deployment", NS: "lab", Name: "solo", Image: "busybox"}); m != "deployment lab/solo created" {
		t.Errorf("create without service: %q", m)
	}
	if _, err := b.doAction(ctx, ActionRequest{Action: "create_deployment", NS: "lab", Name: "solo"}); !apierrors.IsAlreadyExists(err) {
		t.Errorf("creating twice: %v", err)
	}

	// Deletes.
	do(ActionRequest{Action: "delete_pod", NS: "shop", Name: "api-1"})
	do(ActionRequest{Action: "delete_service", NS: "shop", Name: "api"})
	for _, req := range []ActionRequest{{Kind: "Deployment", NS: "shop", Name: "api"}, {Kind: "StatefulSet", NS: "shop", Name: "db"}, {Kind: "DaemonSet", NS: "kube-system", Name: "proxy"}} {
		req.Action = "delete_workload"
		do(req)
	}
	if l, _ := cs.AppsV1().Deployments("shop").List(ctx, metav1.ListOptions{}); len(l.Items) != 0 {
		t.Errorf("deployment still there: %d", len(l.Items))
	}
}

func TestRollback(t *testing.T) {
	tpl := func(img string) corev1.PodTemplateSpec {
		return corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "api", appsv1.DefaultDeploymentUniqueLabelKey: "h"}},
			Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "api", Image: img}}}}
	}
	rsAt := func(name, rev, img string) *appsv1.ReplicaSet {
		rs := &appsv1.ReplicaSet{ObjectMeta: objMeta("shop", name, t0), Spec: appsv1.ReplicaSetSpec{Template: tpl(img)}}
		rs.Annotations = map[string]string{"deployment.kubernetes.io/revision": rev, "kubernetes.io/change-cause": "set image " + img}
		rs.OwnerReferences = controller("Deployment", "api")
		return rs
	}
	dep := &appsv1.Deployment{ObjectMeta: objMeta("shop", "api", t0), Spec: appsv1.DeploymentSpec{Template: tpl("api:3")}}
	dep.Annotations = map[string]string{"deployment.kubernetes.io/revision": "3"}
	paused := dep.DeepCopy()
	paused.Name, paused.Spec.Paused = "frozen", true
	lone := dep.DeepCopy()
	lone.Name = "lone"
	b := newTestBridge(t, dep, paused, lone, rsAt("api-1", "1", "api:1"), rsAt("api-2", "2", "api:2"), rsAt("api-3", "3", "api:3"))
	ctx := context.Background()

	h := b.history(dep)
	if len(h) != 3 || h[0].Revision != 3 || !h[0].Current || h[2].Images[0] != "api:1" || h[1].Cause != "set image api:2" {
		t.Errorf("history: %+v", h)
	}
	msg, err := b.rollback(ctx, "shop", "api", 0)
	if err != nil || msg != "deployment api rolled back to revision 2" {
		t.Fatalf("undo: %q %v", msg, err)
	}
	d, _ := b.cs.AppsV1().Deployments("shop").Get(ctx, "api", metav1.GetOptions{})
	if d.Spec.Template.Spec.Containers[0].Image != "api:2" {
		t.Errorf("template not rolled back: %s", d.Spec.Template.Spec.Containers[0].Image)
	}
	if _, ok := d.Spec.Template.Labels[appsv1.DefaultDeploymentUniqueLabelKey]; ok {
		t.Error("pod-template-hash must not be copied back")
	}
	if msg, err := b.rollback(ctx, "shop", "api", 1); err != nil || !strings.HasSuffix(msg, "revision 1") {
		t.Errorf("to revision 1: %q %v", msg, err)
	}
	for _, c := range []struct {
		name string
		to   int64
		want string
	}{{"api", 3, "already the current"}, {"api", 9, "not found"}, {"frozen", 0, "paused"}, {"lone", 0, "no previous revision"}, {"missing", 0, "not found"}} {
		if _, err := b.rollback(ctx, "shop", c.name, c.to); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("rollback %s to %d: %v, want %q", c.name, c.to, err, c.want)
		}
	}
	// Through the action, with its notes.
	if _, err := b.doAction(ctx, ActionRequest{Action: "rollout_undo", Kind: "Deployment", NS: "shop", Name: "api", Revision: 2}); err != nil {
		t.Errorf("rollout_undo action: %v", err)
	}
}

func TestDrain(t *testing.T) {
	ds := runningPod("kube-system", "proxy-x", "worker-a", nil, true)
	ds.OwnerReferences = controller("DaemonSet", "proxy")
	mirror := runningPod("kube-system", "etcd-worker-a", "worker-a", nil, true)
	mirror.Annotations = map[string]string{corev1.MirrorPodAnnotationKey: "x"}
	done := runningPod("batch", "job-1", "worker-a", nil, false)
	done.Status.Phase = corev1.PodSucceeded
	objs := []runtime.Object{&corev1.Node{ObjectMeta: objMeta("", "worker-a", t0)}, ds, mirror, done,
		runningPod("shop", "api-1", "worker-a", nil, true), runningPod("shop", "db-0", "worker-a", nil, true),
		runningPod("shop", "web-1", "worker-a", nil, true), runningPod("shop", "elsewhere", "worker-b", nil, true)}
	b := newTestBridge(t, objs...)
	cs := b.cs.(*fake.Clientset)
	var evicted []string
	cs.PrependReactor("create", "pods", func(a k8stesting.Action) (bool, runtime.Object, error) {
		if a.GetSubresource() != "eviction" {
			return false, nil, nil
		}
		name := a.(k8stesting.CreateAction).GetObject().(metav1.Object).GetName()
		switch name {
		case "db-0":
			return true, nil, apierrors.NewTooManyRequests("budget", 10)
		case "web-1":
			return true, nil, apierrors.NewNotFound(corev1.Resource("pods"), name)
		}
		evicted = append(evicted, name)
		return true, nil, nil
	})
	msg, err := b.doAction(context.Background(), ActionRequest{Action: "drain", Name: "worker-a"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(evicted, ",") != "api-1" || !strings.Contains(msg, "1 pods evicted") || !strings.Contains(msg, "2 DaemonSet/static pods stay") ||
		!strings.Contains(msg, "1 blocked by a PodDisruptionBudget") || !strings.Contains(msg, "shop/db-0") {
		t.Errorf("drain: %q (evicted %v)", msg, evicted)
	}
	if n, _ := cs.CoreV1().Nodes().Get(context.Background(), "worker-a", metav1.GetOptions{}); !n.Spec.Unschedulable {
		t.Error("drain cordons first")
	}
	// Any other eviction error fails the drain, saying which pods.
	cs.PrependReactor("create", "pods", func(a k8stesting.Action) (bool, runtime.Object, error) {
		return a.GetSubresource() == "eviction", nil, apierrors.NewForbidden(corev1.Resource("pods"), "x", nil)
	})
	if _, err := b.drain(context.Background(), "worker-a"); err == nil || !strings.Contains(err.Error(), "; failed: ") || !strings.Contains(err.Error(), "shop/api-1") {
		t.Errorf("forbidden eviction: %v", err)
	}
	if _, err := b.drain(context.Background(), "no-such-node"); err == nil {
		t.Error("draining a missing node")
	}
	if got := short([]string{"a", "b", "c", "d"}, 2); got != "a, b and 2 more" {
		t.Errorf("short: %q", got)
	}
}

// GET /api/rollout: history, HPA, PDB and GitOps owner of a Deployment.
func TestHandleRollout(t *testing.T) {
	dep := &appsv1.Deployment{ObjectMeta: objMeta("shop", "api", t0)}
	b := newTestBridge(t, dep)
	rec := httptest.NewRecorder()
	b.handleRollout(rec, httptest.NewRequest("GET", "/api/rollout?ns=shop&name=api", nil))
	if out := actionBody(t, rec); out["ok"] != true || out["paused"] != false {
		t.Errorf("rollout: %v", out)
	}
	rec = httptest.NewRecorder()
	b.handleRollout(rec, httptest.NewRequest("GET", "/api/rollout?ns=shop&name=nope", nil))
	if out := actionBody(t, rec); out["ok"] != false {
		t.Errorf("missing deployment: %v", out)
	}
}

func TestHandleLogs(t *testing.T) {
	b := newTestBridge(t, runningPod("shop", "api-1", "n", nil, true))
	rec := httptest.NewRecorder()
	b.handleLogs(rec, httptest.NewRequest("GET", "/api/logs?ns=shop&pod=api-1&tail=99999&previous=1", nil))
	if out := actionBody(t, rec); out["ok"] != true || out["logs"] != "fake logs" {
		t.Errorf("logs: %v", out)
	}
}
