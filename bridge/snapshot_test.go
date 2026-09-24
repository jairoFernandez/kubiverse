package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

func TestPickModel(t *testing.T) {
	old := llm.Model
	defer func() { llm.Model = old }()
	llm.Model = "auto"
	installed := []string{"minimax-m2.1:cloud", "nomic-embed-text:latest", "llama3.2:3b", "gemma4:latest"}
	if got := pickModel(installed); got != "gemma4:latest" {
		t.Fatalf("auto: got %q", got)
	}
	if got := pickModel([]string{"minimax-m2.1:cloud"}); got != "" {
		t.Fatalf("cloud models must never be picked automatically, got %q", got)
	}
	llm.Model = "llama3.2:3b"
	if got := pickModel(installed); got != "llama3.2:3b" {
		t.Fatalf("explicit: got %q", got)
	}
}

func TestShortAgentAndIgnored(t *testing.T) {
	if got := shortAgent("kubectl/v1.33.9 (darwin/arm64) kubernetes/abc"); got != "kubectl/v1.33.9" {
		t.Fatalf("shortAgent: %q", got)
	}
	if shortAgent("Mozilla/5.0 (X11)") != "browser" {
		t.Fatal("browser agent")
	}
	if !ignoredUser("system:node:kind-worker") || !ignoredUser("system:serviceaccount:kube-system:coredns") || ignoredUser("alice") {
		t.Fatal("ignoredUser")
	}
}

func TestAuditTail(t *testing.T) {
	dir := t.TempDir()
	lines := `{"stage":"ResponseComplete","verb":"delete","user":{"username":"alice","groups":["dev"]},"sourceIPs":["10.0.0.5"],"userAgent":"kubectl/v1.33.0 (linux)","objectRef":{"resource":"pods","namespace":"shop","name":"web-1"},"responseStatus":{"code":200},"stageTimestamp":"2026-09-24T10:00:00Z"}
{"stage":"ResponseComplete","verb":"list","user":{"username":"system:node:w1"},"userAgent":"kubelet/v1.37","objectRef":{"resource":"pods"},"responseStatus":{"code":200},"stageTimestamp":"2026-09-24T10:00:01Z"}
{"stage":"ResponseComplete","verb":"list","user":{"username":"mallory"},"sourceIPs":["203.0.113.66"],"userAgent":"curl/8.7.1","objectRef":{"resource":"secrets","namespace":"kube-system"},"responseStatus":{"code":403},"stageTimestamp":"2026-09-24T10:00:02Z"}
{"stage":"ResponseComplete","verb":"get","user":{"username":"kubernetes-admin"},"userAgent":"k8sgame-bridge","objectRef":{"resource":"pods"},"responseStatus":{"code":200},"stageTimestamp":"2026-09-24T10:00:03Z"}
{"partial":`
	path := filepath.Join(dir, "audit.log")
	if err := os.WriteFile(path, []byte(lines), 0o600); err != nil {
		t.Fatal(err)
	}
	b := &Bridge{watch: &watchState{visitors: map[string]*Visitor{}, seenMF: map[string]bool{}}}
	off := b.readAudit(path, 0)
	if off == 0 || off == int64(len(lines)) {
		t.Fatalf("offset %d should stop before the incomplete last line", off)
	}
	v := b.watch.visitors
	if len(v) != 3 {
		t.Fatalf("want alice, mallory and the bridge itself, got %d: %v", len(v), v)
	}
	a := v["audit|alice|kubectl/v1.33.0"]
	if a == nil || a.Writes != 1 || a.LastNS != "shop" || a.IPs[0] != "10.0.0.5" {
		t.Fatalf("alice: %+v", a)
	}
	m := v["audit|mallory|curl/8.7.1"]
	if m == nil || m.Denied != 1 || !m.Secrets {
		t.Fatalf("mallory: %+v", m)
	}
	if s := v["audit|kubernetes-admin|k8sgame-bridge"]; s == nil || !s.Self {
		t.Fatalf("bridge must be marked as self: %+v", s)
	}
	if len(b.watch.actions) != 3 {
		t.Fatalf("actions: %v", b.watch.actions)
	}
}
