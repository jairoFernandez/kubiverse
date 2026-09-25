package main

import (
	"context"
	"encoding/json"
	"time"

	"k8s.io/apimachinery/pkg/api/resource"
)

// Usage is CPU in millicores and memory in bytes.
type Usage struct {
	CPUm     int64 `json:"cpu_m"`
	MemBytes int64 `json:"mem_bytes"`
}

// Metrics is live usage from metrics-server (metrics.k8s.io). When the API
// is not installed, Available is false and the game falls back to requests.
type Metrics struct {
	Available bool             `json:"available"`
	Nodes     map[string]Usage `json:"nodes"`
	Pods      map[string]Usage `json:"pods"` // "ns/name"
}

type metricsList struct {
	Items []struct {
		Metadata struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Usage      map[string]string `json:"usage"`
		Containers []struct {
			Name  string            `json:"name"`
			Usage map[string]string `json:"usage"`
		} `json:"containers"`
	} `json:"items"`
}

func parseUsage(u map[string]string) Usage {
	var out Usage
	if q, err := resource.ParseQuantity(u["cpu"]); err == nil {
		out.CPUm = q.MilliValue()
	}
	if q, err := resource.ParseQuantity(u["memory"]); err == nil {
		out.MemBytes = q.Value()
	}
	return out
}

// pollMetrics refreshes node/pod usage every 15s (metrics-server's own
// resolution) and marks the snapshot dirty when it changes.
func (b *Bridge) pollMetrics(ctx context.Context) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		b.fetchMetrics(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (b *Bridge) fetchMetrics(ctx context.Context) {
	rc := b.cs.Discovery().RESTClient()
	m := Metrics{Nodes: map[string]Usage{}, Pods: map[string]Usage{}}
	perCtr := map[string]map[string]Usage{} // "ns/pod" -> container -> usage (for /api/pod)
	c, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	raw, err := rc.Get().AbsPath("/apis/metrics.k8s.io/v1beta1/nodes").DoRaw(c)
	if err == nil {
		var nl metricsList
		if json.Unmarshal(raw, &nl) == nil {
			m.Available = true
			for _, it := range nl.Items {
				m.Nodes[it.Metadata.Name] = parseUsage(it.Usage)
			}
		}
		if raw, err := rc.Get().AbsPath("/apis/metrics.k8s.io/v1beta1/pods").DoRaw(c); err == nil {
			var pl metricsList
			if json.Unmarshal(raw, &pl) == nil {
				for _, it := range pl.Items {
					var sum Usage
					key := it.Metadata.Namespace + "/" + it.Metadata.Name
					perCtr[key] = map[string]Usage{}
					for _, ct := range it.Containers {
						u := parseUsage(ct.Usage)
						sum.CPUm += u.CPUm
						sum.MemBytes += u.MemBytes
						perCtr[key][ct.Name] = u
					}
					m.Pods[key] = sum
				}
			}
		}
	}
	b.mu.Lock()
	b.metrics = m
	b.ctrUsage = perCtr
	b.mu.Unlock()
	b.markDirty()
}
