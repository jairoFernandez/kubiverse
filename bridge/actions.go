package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/informers"
)

type ActionRequest struct {
	Action   string `json:"action"`
	Kind     string `json:"kind"`
	NS       string `json:"ns"`
	Name     string `json:"name"`
	Replicas int32  `json:"replicas"`
	Image    string `json:"image"`
	Service  bool   `json:"service"`
	Revision int64  `json:"revision"` // rollout_undo: 0 = the previous one
}

var dnsName = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

func (b *Bridge) handleAction(w http.ResponseWriter, r *http.Request) {
	var req ActionRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	if b.readOnly {
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "bridge is in read-only mode"})
		return
	}
	target := strings.Trim(req.Kind+" "+req.NS+"/"+req.Name, " /")
	if err := b.pol.check(r, b.contextName); err != nil {
		b.audit(r, "action", target, req.Action, err)
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	msg, err := b.doAction(ctx, req) // ctx carries the player (team mode)
	log.Printf("action %s %s %s/%s -> %v %s", req.Action, req.Kind, req.NS, req.Name, err, msg)
	b.audit(r, "action", target, req.Action, err)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": msg})
}

func (b *Bridge) doAction(ctx context.Context, req ActionRequest) (string, error) {
	cs := b.clientFor(ctx) // the player, in team mode

	switch req.Action {
	case "delete_pod":
		err := cs.CoreV1().Pods(req.NS).Delete(ctx, req.Name, metav1.DeleteOptions{})
		return "pod " + req.Name + " deleted", err

	case "scale":
		if req.Replicas < 0 || req.Replicas > 50 {
			return "", fmt.Errorf("replicas must be between 0 and 50")
		}
		patch := []byte(fmt.Sprintf(`{"spec":{"replicas":%d}}`, req.Replicas))
		var err error
		switch req.Kind {
		case "Deployment":
			_, err = cs.AppsV1().Deployments(req.NS).Patch(ctx, req.Name, types.MergePatchType, patch, metav1.PatchOptions{})
		case "StatefulSet":
			_, err = cs.AppsV1().StatefulSets(req.NS).Patch(ctx, req.Name, types.MergePatchType, patch, metav1.PatchOptions{})
		default:
			return "", fmt.Errorf("cannot scale %s", req.Kind)
		}
		return fmt.Sprintf("%s %s scaled to %d", req.Kind, req.Name, req.Replicas) + b.notes(req.Kind, req.NS, req.Name, "scale"), err

	case "restart":
		patch := []byte(fmt.Sprintf(`{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":%q}}}}}`,
			time.Now().Format(time.RFC3339)))
		var err error
		switch req.Kind {
		case "Deployment":
			_, err = cs.AppsV1().Deployments(req.NS).Patch(ctx, req.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
		case "StatefulSet":
			_, err = cs.AppsV1().StatefulSets(req.NS).Patch(ctx, req.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
		case "DaemonSet":
			_, err = cs.AppsV1().DaemonSets(req.NS).Patch(ctx, req.Name, types.StrategicMergePatchType, patch, metav1.PatchOptions{})
		default:
			return "", fmt.Errorf("cannot restart %s", req.Kind)
		}
		return req.Kind + " " + req.Name + " rollout restarted", err

	case "pause", "resume":
		if req.Kind != "Deployment" {
			return "", fmt.Errorf("only Deployments can pause their rollout")
		}
		patch := []byte(fmt.Sprintf(`{"spec":{"paused":%v}}`, req.Action == "pause"))
		_, err := cs.AppsV1().Deployments(req.NS).Patch(ctx, req.Name, types.MergePatchType, patch, metav1.PatchOptions{})
		return "deployment " + req.Name + " rollout " + map[bool]string{true: "paused", false: "resumed"}[req.Action == "pause"] + b.notes(req.Kind, req.NS, req.Name, req.Action), err

	case "rollout_undo":
		if req.Kind != "Deployment" {
			return "", fmt.Errorf("rollback works on Deployments")
		}
		msg, err := b.rollback(ctx, req.NS, req.Name, req.Revision)
		return msg + b.notes(req.Kind, req.NS, req.Name, req.Action), err

	case "drain":
		return b.drain(ctx, req.Name)

	case "cordon", "uncordon":
		patch := []byte(fmt.Sprintf(`{"spec":{"unschedulable":%v}}`, req.Action == "cordon"))
		_, err := cs.CoreV1().Nodes().Patch(ctx, req.Name, types.MergePatchType, patch, metav1.PatchOptions{})
		return "node " + req.Name + " " + req.Action + "ed", err

	case "create_deployment":
		if !dnsName.MatchString(req.Name) || !dnsName.MatchString(req.NS) {
			return "", fmt.Errorf("invalid name or namespace")
		}
		if req.Image == "" {
			req.Image = "nginx:alpine"
		}
		replicas := req.Replicas
		if replicas <= 0 || replicas > 20 {
			replicas = 1
		}
		if _, err := cs.CoreV1().Namespaces().Get(ctx, req.NS, metav1.GetOptions{}); err != nil {
			ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: req.NS, Labels: map[string]string{"app.kubernetes.io/created-by": "k8sgame"}}}
			if _, err := cs.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{}); err != nil {
				return "", err
			}
		}
		lbl := map[string]string{"app": req.Name, "app.kubernetes.io/created-by": "k8sgame"}
		dep := &appsv1.Deployment{
			ObjectMeta: metav1.ObjectMeta{Name: req.Name, Namespace: req.NS, Labels: lbl},
			Spec: appsv1.DeploymentSpec{
				Replicas: &replicas,
				Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": req.Name}},
				Template: corev1.PodTemplateSpec{
					ObjectMeta: metav1.ObjectMeta{Labels: lbl},
					Spec:       corev1.PodSpec{Containers: []corev1.Container{{Name: req.Name, Image: req.Image}}},
				},
			},
		}
		if _, err := cs.AppsV1().Deployments(req.NS).Create(ctx, dep, metav1.CreateOptions{}); err != nil {
			return "", err
		}
		if req.Service {
			svc := &corev1.Service{
				ObjectMeta: metav1.ObjectMeta{Name: req.Name, Namespace: req.NS, Labels: lbl},
				Spec: corev1.ServiceSpec{
					Selector: map[string]string{"app": req.Name},
					Ports:    []corev1.ServicePort{{Port: 80, TargetPort: intstr.FromInt32(80)}},
				},
			}
			if _, err := cs.CoreV1().Services(req.NS).Create(ctx, svc, metav1.CreateOptions{}); err != nil {
				return "deployment created, but service failed", err
			}
			return "deployment and service " + req.NS + "/" + req.Name + " created", nil
		}
		return "deployment " + req.NS + "/" + req.Name + " created", nil

	case "delete_service":
		err := cs.CoreV1().Services(req.NS).Delete(ctx, req.Name, metav1.DeleteOptions{})
		return "service " + req.Name + " deleted", err

	case "delete_workload":
		var err error
		switch req.Kind {
		case "Deployment":
			err = cs.AppsV1().Deployments(req.NS).Delete(ctx, req.Name, metav1.DeleteOptions{})
		case "StatefulSet":
			err = cs.AppsV1().StatefulSets(req.NS).Delete(ctx, req.Name, metav1.DeleteOptions{})
		case "DaemonSet":
			err = cs.AppsV1().DaemonSets(req.NS).Delete(ctx, req.Name, metav1.DeleteOptions{})
		default:
			return "", fmt.Errorf("cannot delete %s", req.Kind)
		}
		return req.Kind + " " + req.Name + " deleted", err
	}
	return "", fmt.Errorf("unknown action %q", req.Action)
}

func (b *Bridge) handleLogs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	tail, _ := strconv.ParseInt(q.Get("tail"), 10, 64)
	if tail <= 0 || tail > 1000 {
		tail = 100
	}
	opts := &corev1.PodLogOptions{TailLines: &tail, Container: q.Get("container")}
	if q.Get("previous") == "1" {
		opts.Previous = true
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	data, err := b.cs.CoreV1().Pods(q.Get("ns")).GetLogs(q.Get("pod"), opts).DoRaw(ctx)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "logs": string(data)})
}

// watchEvents streams fresh Kubernetes Events (scheduling, pulls, crashes...)
// to the game so they can be shown as an in-game feed.
func (b *Bridge) watchEvents(ctx context.Context, f informers.SharedInformerFactory) {
	start := time.Now().Add(-5 * time.Second)
	send := func(obj any) {
		e, ok := obj.(*corev1.Event)
		if !ok {
			return
		}
		ts := e.LastTimestamp.Time
		if ts.IsZero() {
			ts = e.EventTime.Time
		}
		if ts.IsZero() {
			ts = e.CreationTimestamp.Time
		}
		if ts.Before(start) {
			return
		}
		msg, _ := json.Marshal(map[string]any{"type": "event", "data": map[string]any{
			"ns": e.Namespace, "kind": e.InvolvedObject.Kind, "name": e.InvolvedObject.Name,
			"reason": e.Reason, "message": e.Message, "etype": e.Type, "count": e.Count,
		}})
		b.broadcast(msg)
	}
	inf := f.Core().V1().Events().Informer()
	inf.AddEventHandler(cacheHandler(send))
}
