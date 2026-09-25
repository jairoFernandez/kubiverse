package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

// Forward is a port-forward the bridge keeps open: localhost:Local on the
// bridge host reaches Port of a pod (or of a Service, through one of its
// ready pods). The game draws it as a glass tube from "your PC" to the pod.
type Forward struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"` // pod | service
	NS       string `json:"ns"`
	Name     string `json:"name"`
	Port     int    `json:"port"`   // the pod's or the Service's port
	Pod      string `json:"pod"`    // pod currently behind it
	Target   int    `json:"target"` // container port on that pod
	Local    int    `json:"local"`  // 127.0.0.1:Local on the bridge host
	URL      string `json:"url"`
	BytesIn  int64  `json:"bytes_in"`  // cluster -> you
	BytesOut int64  `json:"bytes_out"` // you -> cluster
	Conns    int32  `json:"conns"`     // open connections right now
	Total    int64  `json:"total"`     // connections so far
	Status   string `json:"status"`    // connecting | open | error
	Error    string `json:"error,omitempty"`
	Started  int64  `json:"started"`
}

type forwarder struct {
	mu       sync.Mutex
	info     Forward
	ln       net.Listener
	internal atomic.Value // "127.0.0.1:port" of client-go's forwarder, or ""
	in, out  atomic.Int64
	conns    atomic.Int32
	total    atomic.Int64
	cancel   context.CancelFunc
}

type forwards struct {
	mu   sync.Mutex
	list map[string]*forwarder
	seq  int
	tick bool // the 1 s traffic broadcaster is running
}

type forwardRequest struct {
	Kind  string `json:"kind"`
	NS    string `json:"ns"`
	Name  string `json:"name"`
	Port  int    `json:"port"`
	Local int    `json:"local_port"` // 0 = Port (8000+Port below 1024) if free, else any
}

func (f *forwarder) snapshot() Forward {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.info
	out.BytesIn, out.BytesOut = f.in.Load(), f.out.Load()
	out.Conns, out.Total = f.conns.Load(), f.total.Load()
	return out
}

func (f *forwarder) set(fn func(*Forward)) {
	f.mu.Lock()
	fn(&f.info)
	f.mu.Unlock()
}

func (b *Bridge) forwardList() []Forward {
	b.fw.mu.Lock()
	defer b.fw.mu.Unlock()
	out := make([]Forward, 0, len(b.fw.list))
	for _, f := range b.fw.list {
		out = append(out, f.snapshot())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Started < out[j].Started })
	return out
}

func (b *Bridge) forwardsMessage() []byte {
	msg, _ := json.Marshal(map[string]any{"type": "forwards", "data": b.forwardList()})
	return msg
}

// handleForwards: GET lists, POST opens one, DELETE ?id= closes it.
func (b *Bridge) handleForwards(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "forwards": b.forwardList()})
	case http.MethodDelete:
		id := r.URL.Query().Get("id")
		b.fw.mu.Lock()
		f := b.fw.list[id]
		delete(b.fw.list, id)
		b.fw.mu.Unlock()
		if f == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "no such port-forward"})
			return
		}
		f.cancel()
		f.ln.Close()
		log.Printf("port-forward %s closed", f.info.URL)
		b.audit(r, "portforward", f.info.NS+"/"+f.info.Name, "close "+f.info.URL, nil)
		b.broadcast(b.forwardsMessage())
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case http.MethodPost:
		if b.inCluster || identityFrom(r.Context()).User != "" {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "port-forward needs the bridge on your own machine: on a shared (team / in-cluster) bridge it would open the port inside the bridge's pod. Run the bridge locally (the command is on the start screen) or use kubectl port-forward."})
			return
		}
		var req forwardRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
			return
		}
		f, err := b.startForward(req, identityFrom(r.Context()))
		b.audit(r, "portforward", req.NS+"/"+req.Name, fmt.Sprintf("open %s port %d", req.Kind, req.Port), err)
		if err != nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "forward": f.snapshot()})
	}
}

func (b *Bridge) startForward(req forwardRequest, who identity) (*forwarder, error) {
	if req.Kind != "pod" && req.Kind != "service" {
		return nil, errors.New("kind must be pod or service")
	}
	if req.Port < 1 || req.Port > 65535 || req.Local < 0 || req.Local > 65535 {
		return nil, errors.New("invalid port")
	}
	// Resolve once now so an obvious mistake fails right away.
	if _, _, err := b.forwardTarget(req); err != nil {
		return nil, err
	}
	// Always on loopback: a port-forward is a private door for this machine.
	local := req.Local
	if local == 0 {
		local = req.Port
		if local < 1024 {
			local += 8000 // 80 -> 8080, 443 -> 8443: no root needed
		}
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(local)))
	if err != nil && req.Local == 0 {
		ln, err = net.Listen("tcp", "127.0.0.1:0") // the usual port is taken: any free one
	}
	if err != nil {
		return nil, fmt.Errorf("local port %d: %w", local, err)
	}
	local = ln.Addr().(*net.TCPAddr).Port
	// The tunnel lives past this request, but keeps acting as its player.
	ctx, cancel := context.WithCancel(context.WithValue(context.Background(), identityKey{}, who))
	f := &forwarder{ln: ln, cancel: cancel}
	f.internal.Store("")
	b.fw.mu.Lock()
	if b.fw.list == nil {
		b.fw.list = map[string]*forwarder{}
	}
	b.fw.seq++
	f.info = Forward{ID: strconv.Itoa(b.fw.seq), Kind: req.Kind, NS: req.NS, Name: req.Name, Port: req.Port,
		Local: local, URL: fmt.Sprintf("http://127.0.0.1:%d", local), Status: "connecting", Started: time.Now().Unix()}
	b.fw.list[f.info.ID] = f
	startTick := !b.fw.tick
	b.fw.tick = true
	b.fw.mu.Unlock()
	log.Printf("port-forward %s -> %s %s/%s:%d", f.info.URL, req.Kind, req.NS, req.Name, req.Port)
	go b.keepForward(ctx, f, req)
	go serveForward(f)
	if startTick {
		go b.forwardTicker()
	}
	return f, nil
}

// forwardTarget picks the pod and container port behind a request.
func (b *Bridge) forwardTarget(req forwardRequest) (*corev1.Pod, int, error) {
	if req.Kind == "pod" {
		p, err := b.podLister.Pods(req.NS).Get(req.Name)
		if err != nil {
			return nil, 0, err
		}
		if p.Status.Phase != corev1.PodRunning {
			return nil, 0, fmt.Errorf("pod %s is %s, not Running", req.Name, p.Status.Phase)
		}
		return p, req.Port, nil
	}
	svc, err := b.svcLister.Services(req.NS).Get(req.Name)
	if err != nil {
		return nil, 0, err
	}
	var sp *corev1.ServicePort
	for i := range svc.Spec.Ports {
		if int(svc.Spec.Ports[i].Port) == req.Port {
			sp = &svc.Spec.Ports[i]
		}
	}
	if sp == nil {
		return nil, 0, fmt.Errorf("service %s has no port %d", req.Name, req.Port)
	}
	if len(svc.Spec.Selector) == 0 {
		return nil, 0, fmt.Errorf("service %s has no selector (no pods to forward to)", req.Name)
	}
	pods, err := b.podLister.Pods(req.NS).List(labels.SelectorFromSet(svc.Spec.Selector))
	if err != nil {
		return nil, 0, err
	}
	sort.Slice(pods, func(i, j int) bool { return pods[i].Name < pods[j].Name })
	for _, p := range pods {
		if !podReady(p) {
			continue
		}
		if t := targetPort(p, sp.TargetPort, sp.Port); t > 0 {
			return p, t, nil
		}
	}
	return nil, 0, fmt.Errorf("service %s has no ready pods", req.Name)
}

// targetPort maps a Service targetPort (number or container port name).
func targetPort(p *corev1.Pod, tp intstr.IntOrString, port int32) int {
	if tp.Type == intstr.String {
		for _, c := range p.Spec.Containers {
			for _, cp := range c.Ports {
				if cp.Name == tp.StrVal {
					return int(cp.ContainerPort)
				}
			}
		}
		return 0
	}
	if tp.IntVal == 0 {
		return int(port)
	}
	return int(tp.IntVal)
}

// keepForward runs client-go's forwarder on an internal loopback port and
// restarts it when the pod goes away (for a Service it picks another pod).
func (b *Bridge) keepForward(ctx context.Context, f *forwarder, req forwardRequest) {
	for ctx.Err() == nil {
		pod, port, err := b.forwardTarget(req)
		if err == nil {
			f.set(func(i *Forward) { i.Pod, i.Target, i.Status, i.Error = pod.Name, port, "connecting", "" })
			b.broadcast(b.forwardsMessage())
			err = b.runPortForward(ctx, f, pod, port)
		}
		f.internal.Store("")
		if ctx.Err() != nil {
			return
		}
		f.set(func(i *Forward) { i.Status, i.Error = "error", err.Error() })
		b.broadcast(b.forwardsMessage())
		select {
		case <-ctx.Done():
			return
		case <-time.After(3 * time.Second):
		}
	}
}

func (b *Bridge) runPortForward(ctx context.Context, f *forwarder, pod *corev1.Pod, port int) error {
	if b.restCfg == nil {
		return errors.New("no REST config for port-forward")
	}
	transport, upgrader, err := spdy.RoundTripperFor(b.restFor(ctx))
	if err != nil {
		return err
	}
	u := b.clientFor(ctx).CoreV1().RESTClient().Post().Resource("pods").Namespace(pod.Namespace).Name(pod.Name).SubResource("portforward").URL()
	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, u)
	stop := make(chan struct{})
	ready := make(chan struct{})
	pf, err := portforward.NewOnAddresses(dialer, []string{"127.0.0.1"}, []string{"0:" + strconv.Itoa(port)}, stop, ready, io.Discard, io.Discard)
	if err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- pf.ForwardPorts() }()
	select {
	case <-ready:
	case err := <-done:
		return fmt.Errorf("port-forward to %s: %w", pod.Name, err)
	case <-ctx.Done():
		close(stop)
		return ctx.Err()
	}
	ports, err := pf.GetPorts()
	if err != nil || len(ports) == 0 {
		close(stop)
		return fmt.Errorf("port-forward to %s: no local port", pod.Name)
	}
	f.internal.Store(net.JoinHostPort("127.0.0.1", strconv.Itoa(int(ports[0].Local))))
	f.set(func(i *Forward) { i.Status, i.Error = "open", "" })
	b.broadcast(b.forwardsMessage())
	select {
	case err := <-done:
		if err == nil {
			err = errors.New("the pod closed the connection")
		}
		return fmt.Errorf("lost %s: %w", pod.Name, err)
	case <-ctx.Done():
		close(stop)
		return ctx.Err()
	}
}

// serveForward accepts on the public local port and pipes each connection
// to client-go's forwarder, counting the bytes for the game's animation.
func serveForward(f *forwarder) {
	for {
		c, err := f.ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			addr, _ := f.internal.Load().(string)
			if addr == "" {
				return // reconnecting to a pod: refuse for now
			}
			up, err := net.DialTimeout("tcp", addr, 5*time.Second)
			if err != nil {
				return
			}
			defer up.Close()
			f.conns.Add(1)
			f.total.Add(1)
			defer f.conns.Add(-1)
			done := make(chan struct{}, 2)
			go func() {
				io.Copy(up, countingReader{c, &f.out})
				if tc, ok := up.(*net.TCPConn); ok {
					tc.CloseWrite()
				}
				done <- struct{}{}
			}()
			go func() { io.Copy(c, countingReader{up, &f.in}); done <- struct{}{} }()
			<-done
			<-done
		}()
	}
}

// countingReader counts bytes as they arrive, so long downloads animate live.
type countingReader struct {
	r io.Reader
	n *atomic.Int64
}

func (c countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n.Add(int64(n))
	return n, err
}

// forwardTicker sends the traffic counters once a second while forwards exist.
func (b *Bridge) forwardTicker() {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for range t.C {
		b.fw.mu.Lock()
		n := len(b.fw.list)
		if n == 0 {
			b.fw.tick = false
		}
		b.fw.mu.Unlock()
		b.broadcast(b.forwardsMessage())
		if n == 0 {
			return
		}
	}
}
