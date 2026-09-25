package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	autoscalinglisters "k8s.io/client-go/listers/autoscaling/v2"
	policylisters "k8s.io/client-go/listers/policy/v1"
)

// Safe operations: who else manages a workload (GitOps, an HPA), what
// protects its pods (a PodDisruptionBudget), rollout history and undo, and
// draining a node through the Eviction API (which honours the budgets).

// GitOps: the tool that owns an object and will put it back as it is in git
// (or in its chart) if someone changes it by hand.
type GitOps struct {
	Tool string `json:"tool"` // argocd | flux | helm
	Name string `json:"name"` // the Argo CD app, the Flux object, the Helm release
	Hint string `json:"hint"` // where the change has to be made instead
}

// HPARef: an autoscaler that owns the replica count.
type HPARef struct {
	Name    string `json:"name"`
	Min     int32  `json:"min"`
	Max     int32  `json:"max"`
	Current int32  `json:"current"`
	Desired int32  `json:"desired"`
}

// PDBRef: how many of its pods may be down at once (voluntary disruptions:
// evictions, drains).
type PDBRef struct {
	Name           string `json:"name"`
	Allowed        int32  `json:"allowed"` // disruptions allowed right now
	MinAvailable   string `json:"min_available,omitempty"`
	MaxUnavailable string `json:"max_unavailable,omitempty"`
}

type opsListers struct {
	hpa autoscalinglisters.HorizontalPodAutoscalerLister // nil if not allowed
	pdb policylisters.PodDisruptionBudgetLister          // nil if not allowed
}

// gitOpsOf reads the labels and annotations Argo CD, Flux and Helm leave.
func gitOpsOf(m metav1.ObjectMeta) *GitOps {
	a, l := m.Annotations, m.Labels
	if id := a["argocd.argoproj.io/tracking-id"]; id != "" {
		app := strings.SplitN(id, ":", 2)[0]
		return &GitOps{Tool: "argocd", Name: app, Hint: "Argo CD app " + app + ": change it in its git repo (a manual change is reverted on the next sync if self-heal is on, or shows as OutOfSync)"}
	}
	if app := l["argocd.argoproj.io/instance"]; app != "" {
		return &GitOps{Tool: "argocd", Name: app, Hint: "Argo CD app " + app + ": change it in its git repo"}
	}
	if n := l["kustomize.toolkit.fluxcd.io/name"]; n != "" {
		ref := l["kustomize.toolkit.fluxcd.io/namespace"] + "/" + n
		return &GitOps{Tool: "flux", Name: "Kustomization " + ref, Hint: "Flux Kustomization " + ref + ": change it in git (Flux reverts manual changes on its next reconcile)"}
	}
	if n := l["helm.toolkit.fluxcd.io/name"]; n != "" {
		ref := l["helm.toolkit.fluxcd.io/namespace"] + "/" + n
		return &GitOps{Tool: "flux", Name: "HelmRelease " + ref, Hint: "Flux HelmRelease " + ref + ": change its values in git"}
	}
	if l["app.kubernetes.io/managed-by"] == "Helm" {
		rel := a["meta.helm.sh/release-name"]
		if rel == "" {
			rel = l["app.kubernetes.io/instance"]
		}
		return &GitOps{Tool: "helm", Name: rel, Hint: "Helm release " + rel + ": the next helm upgrade puts back what its values say"}
	}
	return nil
}

// hpaFor finds the autoscaler that targets a workload.
func (b *Bridge) hpaFor(kind, ns, name string) *HPARef {
	if b.ops.hpa == nil {
		return nil
	}
	list, _ := b.ops.hpa.HorizontalPodAutoscalers(ns).List(labels.Everything())
	for _, h := range list {
		if h.Spec.ScaleTargetRef.Kind == kind && h.Spec.ScaleTargetRef.Name == name {
			return hpaRef(h)
		}
	}
	return nil
}

func hpaRef(h *autoscalingv2.HorizontalPodAutoscaler) *HPARef {
	min := int32(1)
	if h.Spec.MinReplicas != nil {
		min = *h.Spec.MinReplicas
	}
	return &HPARef{Name: h.Name, Min: min, Max: h.Spec.MaxReplicas, Current: h.Status.CurrentReplicas, Desired: h.Status.DesiredReplicas}
}

// pdbFor finds a budget whose selector matches a pod template's labels.
func (b *Bridge) pdbFor(ns string, podLabels map[string]string) *PDBRef {
	if b.ops.pdb == nil || len(podLabels) == 0 {
		return nil
	}
	list, _ := b.ops.pdb.PodDisruptionBudgets(ns).List(labels.Everything())
	for _, p := range list {
		sel, err := metav1.LabelSelectorAsSelector(p.Spec.Selector)
		if err != nil || sel.Empty() || !sel.Matches(labels.Set(podLabels)) {
			continue
		}
		r := &PDBRef{Name: p.Name, Allowed: p.Status.DisruptionsAllowed}
		if p.Spec.MinAvailable != nil {
			r.MinAvailable = p.Spec.MinAvailable.String()
		}
		if p.Spec.MaxUnavailable != nil {
			r.MaxUnavailable = p.Spec.MaxUnavailable.String()
		}
		return r
	}
	return nil
}

// Revision is one step of a Deployment's rollout history (a ReplicaSet).
type Revision struct {
	Revision int64    `json:"revision"`
	Images   []string `json:"images"`
	Cause    string   `json:"cause"` // kubernetes.io/change-cause, if someone set it
	Age      int64    `json:"age"`
	Replicas int32    `json:"replicas"`
	Current  bool     `json:"current"`
}

func revisionOf(m metav1.ObjectMeta) int64 {
	n, _ := strconv.ParseInt(m.Annotations["deployment.kubernetes.io/revision"], 10, 64)
	return n
}

// history lists a Deployment's revisions, newest first.
func (b *Bridge) history(d *appsv1.Deployment) []Revision {
	rss, _ := b.rsLister.ReplicaSets(d.Namespace).List(labels.Everything())
	cur := revisionOf(d.ObjectMeta)
	var out []Revision
	for _, rs := range rss {
		owned := false
		for _, o := range rs.OwnerReferences {
			if o.Kind == "Deployment" && o.Name == d.Name {
				owned = true
			}
		}
		n := revisionOf(rs.ObjectMeta)
		if !owned || n == 0 {
			continue
		}
		var imgs []string
		for _, c := range rs.Spec.Template.Spec.Containers {
			imgs = append(imgs, c.Image)
		}
		out = append(out, Revision{Revision: n, Images: imgs, Cause: rs.Annotations["kubernetes.io/change-cause"],
			Age: int64(time.Since(rs.CreationTimestamp.Time).Seconds()), Replicas: rs.Status.Replicas, Current: n == cur})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Revision > out[j].Revision })
	return out
}

// GET /api/rollout?ns=&name=: a Deployment's history, its HPA, PDB and GitOps owner.
func (b *Bridge) handleRollout(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	d, err := b.depLister.Deployments(q.Get("ns")).Get(q.Get("name"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "revisions": b.history(d), "paused": d.Spec.Paused,
		"hpa": b.hpaFor("Deployment", d.Namespace, d.Name), "pdb": b.pdbFor(d.Namespace, d.Spec.Template.Labels), "gitops": gitOpsOf(d.ObjectMeta)})
}

// rollback puts a Deployment's pod template back to a revision (0 = the one
// before the current), like `kubectl rollout undo`.
func (b *Bridge) rollback(ctx context.Context, ns, name string, to int64) (string, error) {
	cs := b.clientFor(ctx)
	d, err := cs.AppsV1().Deployments(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", err
	}
	if d.Spec.Paused {
		return "", fmt.Errorf("deployment %s is paused: resume it before rolling back", name)
	}
	revs := b.history(d)
	var target *appsv1.ReplicaSet
	cur := revisionOf(d.ObjectMeta)
	want := to
	if want == 0 {
		for _, r := range revs { // newest first: the first one older than the current
			if r.Revision < cur {
				want = r.Revision
				break
			}
		}
	}
	if want == 0 {
		return "", fmt.Errorf("no previous revision to roll back to")
	}
	if want == cur {
		return "", fmt.Errorf("revision %d is already the current one", want)
	}
	rss, _ := b.rsLister.ReplicaSets(ns).List(labels.Everything())
	for _, rs := range rss {
		for _, o := range rs.OwnerReferences {
			if o.Kind == "Deployment" && o.Name == name && revisionOf(rs.ObjectMeta) == want {
				target = rs
			}
		}
	}
	if target == nil {
		return "", fmt.Errorf("revision %d not found (its ReplicaSet may have been cleaned up)", want)
	}
	tpl := target.Spec.Template.DeepCopy()
	delete(tpl.Labels, appsv1.DefaultDeploymentUniqueLabelKey) // pod-template-hash
	// A patch of just the template: an HPA or a controller changing other
	// fields meanwhile doesn't make it conflict.
	patch, _ := json.Marshal([]map[string]any{{"op": "replace", "path": "/spec/template", "value": tpl}})
	if _, err := cs.AppsV1().Deployments(ns).Patch(ctx, name, types.JSONPatchType, patch, metav1.PatchOptions{}); err != nil {
		return "", err
	}
	return fmt.Sprintf("deployment %s rolled back to revision %d", name, want), nil
}

// drain cordons a node and evicts its pods through the Eviction API, so
// PodDisruptionBudgets are honoured. DaemonSet and static (mirror) pods stay.
// It doesn't wait: what a budget blocks is reported to try again later.
func (b *Bridge) drain(ctx context.Context, node string) (string, error) {
	cs := b.clientFor(ctx)
	if _, err := cs.CoreV1().Nodes().Patch(ctx, node, types.MergePatchType, []byte(`{"spec":{"unschedulable":true}}`), metav1.PatchOptions{}); err != nil {
		return "", err
	}
	pods, err := b.podLister.List(labels.Everything())
	if err != nil {
		return "", err
	}
	var evicted, blocked, skipped []string
	var failed []string
	for _, p := range pods {
		if p.Spec.NodeName != node || p.DeletionTimestamp != nil || p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed {
			continue
		}
		if _, mirror := p.Annotations[corev1.MirrorPodAnnotationKey]; mirror || ownedBy(p, "DaemonSet") {
			skipped = append(skipped, p.Name)
			continue
		}
		ev := &policyv1.Eviction{ObjectMeta: metav1.ObjectMeta{Name: p.Name, Namespace: p.Namespace}}
		err := cs.CoreV1().Pods(p.Namespace).EvictV1(ctx, ev)
		switch {
		case err == nil:
			evicted = append(evicted, p.Namespace+"/"+p.Name)
		case apierrors.IsTooManyRequests(err):
			blocked = append(blocked, p.Namespace+"/"+p.Name)
		case apierrors.IsNotFound(err):
		default:
			failed = append(failed, p.Namespace+"/"+p.Name+": "+err.Error())
		}
	}
	msg := fmt.Sprintf("node %s cordoned; %d pods evicted", node, len(evicted))
	if len(skipped) > 0 {
		msg += fmt.Sprintf(", %d DaemonSet/static pods stay", len(skipped))
	}
	if len(blocked) > 0 {
		msg += fmt.Sprintf("; %d blocked by a PodDisruptionBudget (drain again once their replacements are ready): %s", len(blocked), short(blocked, 5))
	}
	if len(failed) > 0 {
		return msg, errors.New(msg + "; failed: " + short(failed, 3))
	}
	return msg, nil
}

func ownedBy(p *corev1.Pod, kind string) bool {
	for _, o := range p.OwnerReferences {
		if o.Kind == kind {
			return true
		}
	}
	return false
}

func short(list []string, n int) string {
	if len(list) <= n {
		return strings.Join(list, ", ")
	}
	return strings.Join(list[:n], ", ") + fmt.Sprintf(" and %d more", len(list)-n)
}

// notes: what a change to a workload should know (added to its message).
func (b *Bridge) notes(kind, ns, name, action string) string {
	var out []string
	if action == "scale" {
		if h := b.hpaFor(kind, ns, name); h != nil {
			out = append(out, fmt.Sprintf("HPA %s owns the replicas (%d-%d): it will change them back", h.Name, h.Min, h.Max))
		}
	}
	var meta *metav1.ObjectMeta
	switch kind {
	case "Deployment":
		if d, err := b.depLister.Deployments(ns).Get(name); err == nil {
			meta = &d.ObjectMeta
		}
	case "StatefulSet":
		if d, err := b.stsLister.StatefulSets(ns).Get(name); err == nil {
			meta = &d.ObjectMeta
		}
	case "DaemonSet":
		if d, err := b.dsLister.DaemonSets(ns).Get(name); err == nil {
			meta = &d.ObjectMeta
		}
	}
	if meta != nil && action != "restart" {
		if g := gitOpsOf(*meta); g != nil && g.Tool != "helm" {
			out = append(out, "managed by "+g.Hint)
		}
	}
	if len(out) == 0 {
		return ""
	}
	return " (note: " + strings.Join(out, "; ") + ")"
}
