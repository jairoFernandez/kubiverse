package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func TestForwardTarget(t *testing.T) {
	ready := runningPod("shop", "api-b", "n", map[string]string{"app": "api"}, true)
	notReady := runningPod("shop", "api-a", "n", map[string]string{"app": "api"}, false)
	pending := runningPod("shop", "job", "n", nil, false)
	pending.Status.Phase = corev1.PodPending
	svcObj := func(name string, sel map[string]string, tp intstr.IntOrString) *corev1.Service {
		return &corev1.Service{ObjectMeta: objMeta("shop", name, t0), Spec: corev1.ServiceSpec{Selector: sel,
			Ports: []corev1.ServicePort{{Port: 80, TargetPort: tp}}}}
	}
	b := newTestBridge(t, ready, notReady, pending,
		svcObj("api", map[string]string{"app": "api"}, intstr.FromString("http")),
		svcObj("external", nil, intstr.FromInt32(80)),
		svcObj("nobody", map[string]string{"app": "gone"}, intstr.FromInt32(80)))
	p, port, err := b.forwardTarget(forwardRequest{Kind: "service", NS: "shop", Name: "api", Port: 80})
	if err != nil || p.Name != "api-b" || port != 8080 {
		t.Errorf("service -> its ready pod's named port: %v %d %v", p, port, err)
	}
	if p, port, err := b.forwardTarget(forwardRequest{Kind: "pod", NS: "shop", Name: "api-a", Port: 9090}); err != nil || p.Name != "api-a" || port != 9090 {
		t.Errorf("pod: %v %d %v", p, port, err)
	}
	for _, c := range []struct {
		req  forwardRequest
		want string
	}{
		{forwardRequest{Kind: "pod", NS: "shop", Name: "job", Port: 80}, "not Running"},
		{forwardRequest{Kind: "pod", NS: "shop", Name: "nope", Port: 80}, "not found"},
		{forwardRequest{Kind: "service", NS: "shop", Name: "nope", Port: 80}, "not found"},
		{forwardRequest{Kind: "service", NS: "shop", Name: "api", Port: 443}, "no port 443"},
		{forwardRequest{Kind: "service", NS: "shop", Name: "external", Port: 80}, "no selector"},
		{forwardRequest{Kind: "service", NS: "shop", Name: "nobody", Port: 80}, "no ready pods"},
	} {
		if _, _, err := b.forwardTarget(c.req); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%+v: %v, want %q", c.req, err, c.want)
		}
	}
}

// A forward opens a loopback port at once, reports why it can't connect
// (no REST config here), and closes on DELETE.
func TestForwardLifecycle(t *testing.T) {
	b := newTestBridge(t, runningPod("shop", "api-1", "n", nil, true))
	rec := httptest.NewRecorder()
	b.handleForwards(rec, httptest.NewRequest("POST", "/api/forwards", strings.NewReader(`{"kind":"pod","ns":"shop","name":"api-1","port":80}`)))
	var out struct {
		OK      bool    `json:"ok"`
		Forward Forward `json:"forward"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || !out.OK {
		t.Fatalf("open: %s", rec.Body.String())
	}
	f := out.Forward
	if f.ID == "" || f.Local == 0 || !strings.HasPrefix(f.URL, "http://127.0.0.1:") || f.Kind != "pod" {
		t.Errorf("forward: %+v", f)
	}
	// The tunnel can't come up: it says why.
	deadline := time.Now().Add(3 * time.Second)
	for {
		l := b.forwardList()
		if len(l) == 1 && l[0].Status == "error" && strings.Contains(l[0].Error, "no REST config") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("status: %+v", l)
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Meanwhile a connection to the local port is closed right away.
	if c, err := net.Dial("tcp", strings.TrimPrefix(f.URL, "http://")); err == nil {
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		if n, _ := c.Read(make([]byte, 1)); n != 0 {
			t.Error("no tunnel: nothing to read")
		}
		c.Close()
	}
	rec = httptest.NewRecorder()
	b.handleForwards(rec, httptest.NewRequest("GET", "/api/forwards", nil))
	if !strings.Contains(rec.Body.String(), `"id":"`+f.ID+`"`) {
		t.Errorf("list: %s", rec.Body.String())
	}
	rec = httptest.NewRecorder()
	b.handleForwards(rec, httptest.NewRequest("DELETE", "/api/forwards?id="+f.ID, nil))
	if rec.Code != 200 || len(b.forwardList()) != 0 {
		t.Errorf("close: %d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	b.handleForwards(rec, httptest.NewRequest("DELETE", "/api/forwards?id="+f.ID, nil))
	if rec.Code != 404 {
		t.Errorf("closing twice: %d", rec.Code)
	}
	// Shared bridges refuse: the port would open inside the bridge's pod.
	b.inCluster = true
	rec = httptest.NewRecorder()
	b.handleForwards(rec, httptest.NewRequest("POST", "/api/forwards", strings.NewReader(`{}`)))
	if !strings.Contains(rec.Body.String(), "own machine") {
		t.Errorf("in-cluster: %s", rec.Body.String())
	}
	b.inCluster = false
	rec = httptest.NewRecorder()
	b.handleForwards(rec, httptest.NewRequest("POST", "/api/forwards", strings.NewReader(`{`)))
	if rec.Code != 400 {
		t.Errorf("bad json: %d", rec.Code)
	}
}

// serveForward pipes each connection to the internal forwarder and counts
// the bytes both ways.
func TestServeForwardCountsBytes(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	f := &forwarder{ln: ln}
	f.internal.Store(echo.Addr().String())
	go serveForward(f)
	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c.Write([]byte("hello"))
	c.(*net.TCPConn).CloseWrite()
	got, _ := io.ReadAll(c)
	c.Close()
	if string(got) != "hello" {
		t.Errorf("echo: %q", got)
	}
	deadline := time.Now().Add(2 * time.Second)
	for s := f.snapshot(); s.Total != 1 || s.BytesIn != 5 || s.BytesOut != 5 || s.Conns != 0; s = f.snapshot() {
		if time.Now().After(deadline) {
			t.Fatalf("counters: %+v", s)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
