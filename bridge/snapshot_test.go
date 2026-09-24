package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestPodStatus(t *testing.T) {
	now := metav1.Now()
	cases := []struct {
		name string
		pod  corev1.Pod
		want string
	}{
		{"running", corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodRunning}}, "Running"},
		{"terminating", corev1.Pod{ObjectMeta: metav1.ObjectMeta{DeletionTimestamp: &now}, Status: corev1.PodStatus{Phase: corev1.PodRunning}}, "Terminating"},
		{"crashloop", corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodRunning, ContainerStatuses: []corev1.ContainerStatus{
			{State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff"}}},
		}}}, "CrashLoopBackOff"},
		{"completed", corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodSucceeded, ContainerStatuses: []corev1.ContainerStatus{
			{State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{Reason: "Completed"}}},
		}}}, "Completed"},
		{"init error", corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodPending, InitContainerStatuses: []corev1.ContainerStatus{
			{State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 1}}},
		}}}, "Init:Error"},
	}
	for _, c := range cases {
		if got := podStatus(&c.pod); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestGuard(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	h := guard(ok, "")
	cases := []struct {
		host, origin string
		want         int
	}{
		{"127.0.0.1:8088", "", 200},                      // native game / curl
		{"127.0.0.1:8088", "http://127.0.0.1:8088", 200}, // web build served by bridge
		{"localhost:8088", "http://localhost:8060", 200}, // local dev server
		{"127.0.0.1:8088", "https://evil.example", 403},  // drive-by from another site
		{"evil.example:8088", "", 403},                   // DNS rebinding
	}
	for _, c := range cases {
		r := httptest.NewRequest("POST", "http://"+c.host+"/api/action", nil)
		r.Host = c.host
		if c.origin != "" {
			r.Header.Set("Origin", c.origin)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != c.want {
			t.Errorf("host=%s origin=%s: got %d want %d", c.host, c.origin, w.Code, c.want)
		}
	}
}

func TestTerminalValidation(t *testing.T) {
	ok := []string{"get pods -A", "kubectl -n shop scale deployment/frontend --replicas=2", `get pods -l "app=cart"`, "logs cart-1 --previous"}
	for _, l := range ok {
		args, err := splitArgs(l)
		if err == nil && args[0] == "kubectl" {
			args = args[1:]
		}
		if err == nil {
			err = validateArgs(args, false)
		}
		if err != nil {
			t.Errorf("%q should be allowed: %v", l, err)
		}
	}
	bad := []string{"exec -it x -- sh", "get pods; rm -rf /", "get pods --kubeconfig=/tmp/x", "apply -f /etc/passwd",
		"config view --raw", "logs x -f", "get pods $(whoami)", "edit deploy x", ""}
	for _, l := range bad {
		args, err := splitArgs(l)
		if err == nil {
			err = validateArgs(args, false)
		}
		if err == nil {
			t.Errorf("%q should be refused", l)
		}
	}
	if err := validateArgs([]string{"delete", "pod", "x"}, true); err == nil {
		t.Error("read-only bridge must refuse delete")
	}
	if err := validateArgs([]string{"get", "pods"}, true); err != nil {
		t.Errorf("read-only bridge must allow get: %v", err)
	}
}
