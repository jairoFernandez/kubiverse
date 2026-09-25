package main

import (
	"bytes"
	"encoding/json"
)

// Big clusters: instead of the whole snapshot three times a second, a game
// that asks for it (?patch=1 on the WebSocket) gets the full state once and
// then only what changed: {"type":"patch","seq","base","time",..., "set":
// {"pods":[...]}, "del":{"pods":["ns/name"]}}. Ages (pods, nodes) don't
// count as a change: the game moves them on with "time". A game that misses
// a patch (base != its seq) reconnects and starts again from a full state.

type patchMsg struct {
	Seq      int64                        `json:"seq"`
	Base     int64                        `json:"base"`
	Time     int64                        `json:"time"`
	Context  string                       `json:"context"`
	Server   string                       `json:"server"`
	ReadOnly bool                         `json:"readonly"`
	Metrics  *Metrics                     `json:"metrics,omitempty"` // only when it changed
	Set      map[string][]json.RawMessage `json:"set,omitempty"`
	Del      map[string][]string          `json:"del,omitempty"`
}

// stateDiff remembers what the games were last sent.
type stateDiff struct {
	seq     int64
	items   map[string]map[string][]byte // collection -> key -> item without its age
	metrics []byte
}

// next encodes s as a full "state" message and as a patch on top of the
// previous one (nil the first time).
func (d *stateDiff) next(s *Snapshot) (full, patch []byte) {
	d.seq++
	full, _ = json.Marshal(map[string]any{"type": "state", "seq": d.seq, "data": s})
	first := d.items == nil
	if first {
		d.items = map[string]map[string][]byte{}
	}
	p := &patchMsg{Seq: d.seq, Base: d.seq - 1, Time: s.Time, Context: s.Context, Server: s.Server, ReadOnly: s.ReadOnly,
		Set: map[string][]json.RawMessage{}, Del: map[string][]string{}}
	diffList(d, p, "nodes", s.Nodes, func(n Node) string { return n.Name }, func(n Node) Node { n.Age = 0; return n })
	diffList(d, p, "namespaces", s.Namespaces, func(n Namespace) string { return n.Name }, nil)
	diffList(d, p, "pods", s.Pods, func(x Pod) string { return x.Namespace + "/" + x.Name }, func(x Pod) Pod { x.Age = 0; return x })
	diffList(d, p, "workloads", s.Workloads, func(w Workload) string { return w.Namespace + "/" + w.Kind + "/" + w.Name }, nil)
	diffList(d, p, "services", s.Services, func(x Service) string { return x.Namespace + "/" + x.Name }, nil)
	diffList(d, p, "ingresses", s.Ingresses, func(x Ingress) string { return x.Namespace + "/" + x.Name }, nil)
	diffList(d, p, "alerts", s.Alerts, func(a Alert) string { return a.ID }, func(a Alert) Alert { a.Since = 0; return a })
	m, _ := json.Marshal(s.Metrics)
	if !bytes.Equal(m, d.metrics) {
		d.metrics = m
		p.Metrics = &s.Metrics
	}
	if first {
		return full, nil
	}
	patch, _ = json.Marshal(map[string]any{"type": "patch", "data": p})
	return full, patch
}

func diffList[T any](d *stateDiff, p *patchMsg, name string, list []T, key func(T) string, noAge func(T) T) {
	prev := d.items[name]
	cur := make(map[string][]byte, len(list))
	for _, it := range list {
		k := key(it)
		cmp := it
		if noAge != nil {
			cmp = noAge(it)
		}
		b, _ := json.Marshal(cmp)
		cur[k] = b
		if old, ok := prev[k]; !ok || !bytes.Equal(old, b) {
			full, _ := json.Marshal(it)
			p.Set[name] = append(p.Set[name], full)
		}
	}
	for k := range prev {
		if _, ok := cur[k]; !ok {
			p.Del[name] = append(p.Del[name], k)
		}
	}
	d.items[name] = cur
}
