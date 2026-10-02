package main

import (
	"context"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// What Kubi (the local model) is told about the thing the player asks about.
func TestAssistantContext(t *testing.T) {
	crash := runningPod("shop", "api-1", "worker-a", map[string]string{"app": "api"}, false)
	crash.OwnerReferences = controller("ReplicaSet", "api-x")
	crash.Spec.NodeSelector = map[string]string{"disk": "ssd"}
	crash.Spec.Tolerations = []corev1.Toleration{{Key: "gpu", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
		{Key: "node.kubernetes.io/not-ready", Operator: corev1.TolerationOpExists}}
	crash.Status.Conditions = append(crash.Status.Conditions, corev1.PodCondition{Type: corev1.ContainersReady, Status: corev1.ConditionFalse, Reason: "ContainersNotReady"})
	crash.Status.ContainerStatuses[0].RestartCount = 7
	crash.Status.ContainerStatuses[0].State = corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff", Message: "back-off"}}
	crash.Status.ContainerStatuses[0].LastTerminationState = corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{Reason: "OOMKilled", ExitCode: 137}}
	ok := runningPod("shop", "web-1", "worker-a", nil, true)
	node := &corev1.Node{ObjectMeta: objMeta("", "worker-a", t0),
		Spec: corev1.NodeSpec{Taints: []corev1.Taint{{Key: "gpu", Value: "a100", Effect: corev1.TaintEffectNoSchedule}}},
		Status: corev1.NodeStatus{Allocatable: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("2")},
			Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue, Reason: "KubeletReady"}}}}
	node.Labels = map[string]string{"pool": "gpu", "kubernetes.io/hostname": "worker-a"}
	dep := &appsv1.Deployment{ObjectMeta: objMeta("shop", "api", t0), Spec: appsv1.DeploymentSpec{Replicas: ptr(int32(2)),
		Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Image: "shop/api:2"}}}}},
		Status: appsv1.DeploymentStatus{ReadyReplicas: 1}}
	newer := func(name, reason string, at time.Time) *corev1.Event {
		return &corev1.Event{ObjectMeta: metav1.ObjectMeta{Namespace: "shop", Name: name}, InvolvedObject: corev1.ObjectReference{Name: "api-1"},
			Type: "Warning", Reason: reason, Count: 3, Message: reason + " happened", LastTimestamp: metav1.NewTime(at)}
	}
	b := newTestBridge(t, crash, ok, node, dep, &corev1.Namespace{ObjectMeta: objMeta("", "shop", t0)},
		newer("e1", "BackOff", t0.Add(time.Minute)), newer("e2", "Pulled", t0))
	ctx := context.Background()

	got := b.assistantContext(ctx, assistantRequest{Kind: "Pod", NS: "shop", Name: "api-1"})
	for _, want := range []string{"pod shop/api-1 phase=Running status=CrashLoopBackOff", "restarts=7", "owner ReplicaSet/api-x",
		"nodeSelector map[disk:ssd]", "toleration gpu Exists", "condition ContainersReady=False", "waiting=CrashLoopBackOff back-off",
		"lastTerminated=OOMKilled exit=137", "recent events:\n- Warning BackOff x3", "last log lines of app"} {
		if !strings.Contains(got, want) {
			t.Errorf("pod context lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "not-ready") {
		t.Error("the default tolerations are noise")
	}
	if i, j := strings.Index(got, "BackOff"), strings.Index(got, "Pulled"); i > j {
		t.Error("newest events first")
	}
	if got := b.assistantContext(ctx, assistantRequest{Kind: "Pod", NS: "shop", Name: "gone"}); !strings.Contains(got, "not found") {
		t.Errorf("missing pod: %q", got)
	}

	got = b.assistantContext(ctx, assistantRequest{Kind: "Node", Name: "worker-a"})
	if !strings.Contains(got, "node worker-a unschedulable=false allocatable cpu=2") || !strings.Contains(got, "taint gpu=a100:NoSchedule") ||
		!strings.Contains(got, "condition Ready=True KubeletReady") {
		t.Errorf("node context:\n%s", got)
	}
	if got := b.assistantContext(ctx, assistantRequest{Kind: "Node", Name: "nope"}); !strings.Contains(got, "node nope not found") {
		t.Errorf("missing node: %q", got)
	}

	got = b.assistantContext(ctx, assistantRequest{Kind: "Deployment", NS: "shop", Name: "api"})
	if !strings.Contains(got, "desired=2 ready=1") || !strings.Contains(got, "image=shop/api:2") ||
		!strings.Contains(got, "pods with problems:\n- shop/api-1 CrashLoopBackOff restarts=7") || strings.Contains(got, "web-1") {
		t.Errorf("deployment context:\n%s", got)
	}

	got = b.assistantContext(ctx, assistantRequest{})
	if !strings.Contains(got, "1 nodes, 1 namespaces, 2 pods, 1 workloads") || !strings.Contains(got, "label=pool=gpu") ||
		strings.Contains(got, "hostname") || !strings.Contains(got, "pods(2)=shop/api-1,shop/web-1") || !strings.Contains(got, "Deployment shop/api 1/2 ready") {
		t.Errorf("summary:\n%s", got)
	}
	if got := b.assistantContext(ctx, assistantRequest{NS: "empty"}); !strings.Contains(got, "no pods with problems") {
		t.Errorf("healthy namespace:\n%s", got)
	}

	got = b.namespaceSummary("shop")
	if !strings.Contains(got, "NAMESPACE shop:") || !strings.Contains(got, "pod api-1 status=CrashLoopBackOff ready=0/1 restarts=7 node=worker-a") ||
		!strings.Contains(got, "Deployment api 1/2 ready") {
		t.Errorf("namespace summary:\n%s", got)
	}
	if clip("abcdef", 3) != "abc..." || clip("abc", 3) != "abc" {
		t.Error("clip")
	}
}

func TestEventTime(t *testing.T) {
	created := corev1.Event{ObjectMeta: metav1.ObjectMeta{CreationTimestamp: metav1.NewTime(t0)}}
	micro := corev1.Event{EventTime: metav1.NewMicroTime(t0.Add(time.Second))}
	if !eventTime(created).Equal(t0) || !eventTime(micro).Equal(t0.Add(time.Second)) {
		t.Error("eventTime falls back to EventTime, then creation")
	}
}
