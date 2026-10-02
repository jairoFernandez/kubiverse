package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// metrics-server answers: node and pod usage (pods summed over containers).
func TestFetchMetrics(t *testing.T) {
	var off atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if off.Load() {
			http.NotFound(w, r)
			return
		}
		switch r.URL.Path {
		case "/apis/metrics.k8s.io/v1beta1/nodes":
			w.Write([]byte(`{"items":[{"metadata":{"name":"worker-a"},"usage":{"cpu":"1500m","memory":"2Gi"}}]}`))
		case "/apis/metrics.k8s.io/v1beta1/pods":
			w.Write([]byte(`{"items":[{"metadata":{"name":"api-1","namespace":"shop"},"containers":[
				{"name":"app","usage":{"cpu":"250m","memory":"100Mi"}},{"name":"sidecar","usage":{"cpu":"5m","memory":"20Mi"}}]}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	cs, err := kubernetes.NewForConfig(&rest.Config{Host: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	b := &Bridge{cs: cs}
	b.fetchMetrics(context.Background())
	m := b.metrics
	if !m.Available || m.Nodes["worker-a"] != (Usage{CPUm: 1500, MemBytes: 2 << 30}) {
		t.Errorf("nodes: %+v", m)
	}
	if m.Pods["shop/api-1"] != (Usage{CPUm: 255, MemBytes: 120 << 20}) || b.ctrUsage["shop/api-1"]["sidecar"].CPUm != 5 {
		t.Errorf("pods: %+v %+v", m.Pods, b.ctrUsage)
	}
	if !b.dirty {
		t.Error("new metrics mark the snapshot dirty")
	}

	// No metrics-server: not available, the game falls back to requests.
	off.Store(true)
	b.fetchMetrics(context.Background())
	if b.metrics.Available || len(b.metrics.Nodes) != 0 {
		t.Errorf("without metrics-server: %+v", b.metrics)
	}
	if u := parseUsage(map[string]string{"cpu": "bogus"}); u != (Usage{}) {
		t.Errorf("unparseable usage: %+v", u)
	}
}
