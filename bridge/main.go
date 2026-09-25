// k8s-bridge connects to a real Kubernetes cluster (using your kubeconfig)
// and exposes a small, game-friendly HTTP + WebSocket API for KubeCraft.
//
// Browsers cannot talk to the kube-apiserver directly (CORS, client certs,
// exec auth plugins), so both the native and the web build of the game go
// through this bridge.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	appslisters "k8s.io/client-go/listers/apps/v1"
	corelisters "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

type Bridge struct {
	cs          kubernetes.Interface
	contextName string
	server      string
	readOnly    bool

	kubeconfigPath string             // explicit --kubeconfig, passed on to kubectl
	stop           context.CancelFunc // stops this cluster's informers
	metrics        Metrics

	nodeLister corelisters.NodeLister
	nsLister   corelisters.NamespaceLister
	podLister  corelisters.PodLister
	svcLister  corelisters.ServiceLister
	depLister  appslisters.DeploymentLister
	rsLister   appslisters.ReplicaSetLister
	stsLister  appslisters.StatefulSetLister
	dsLister   appslisters.DaemonSetLister

	mu      sync.Mutex
	dirty   bool
	last    []byte // last encoded snapshot message
	clients map[*client]struct{}
	watch   *watchState
}

type client struct {
	send  chan []byte
	addr  string
	ip    string
	agent string
	since time.Time
}

func main() {
	var (
		kubeconfig = flag.String("kubeconfig", "", "path to kubeconfig (default: $KUBECONFIG or ~/.kube/config)")
		kubectx    = flag.String("context", "", "default kubeconfig context (default: current-context)")
		addr       = flag.String("addr", "127.0.0.1:8088", "listen address")
		readOnly   = flag.Bool("readonly", false, "reject every mutating action")
		token      = flag.String("token", os.Getenv("K8SGAME_TOKEN"), "optional shared token required by clients")
		webDir     = flag.String("web", "", "optional directory with the Godot web export to serve at /")
		origins    = flag.String("allow-origin", "", "extra comma-separated browser origins allowed to call the API (localhost is always allowed)")
		dataDir    = flag.String("data", defaultDataDir(), "where kubeconfigs added from the game are stored")
		llmURL     = flag.String("llm-url", llm.URL, "Ollama URL for the in-game assistant (\"\" disables it); keep it local: cluster data is sent to it")
		llmModel   = flag.String("llm-model", llm.Model, "Ollama model for the in-game assistant (auto = best installed local model)")
		audit      = flag.String("audit-dir", auditDir, "directory with API server audit logs (<dir>/<context>/**/audit.log) for WATCHTOWER mode")
	)
	lan := flag.Bool("lan", false, "serve on the local network (phones/tablets): listens on all interfaces, requires a token (random if not given) and prints the URLs to open")
	flag.Parse()
	var lanURLs []string
	if *lan {
		lanURLs = lanSetup(addr, token, origins)
	}
	if exposed(*addr) && *token == "" {
		log.Fatalf("refusing to listen on %s without --token: anyone on the network could control your cluster (use --lan for a random token)", *addr)
	}
	llm.URL, llm.Model, auditDir = *llmURL, *llmModel, *audit
	if u, err := url.Parse(llm.URL); llm.URL != "" && (err != nil || !isLoopback(u.Hostname())) {
		log.Printf("WARNING: assistant LLM at %s is not on this machine: questions send cluster data (status, events, log lines) there", llm.URL)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	hub := newHub(ctx, *kubeconfig, *kubectx, *dataDir, *readOnly, *token)
	ai.init(ctx, filepath.Dir(*dataDir))
	log.Printf("default context %q, extra kubeconfigs in %s", hub.defaultCtx, hub.dir)
	// Warm up the default cluster so the first client connects instantly.
	go func() {
		if _, err := hub.get(""); err != nil {
			log.Printf("default context not available yet: %v", err)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /api/contexts", hub.auth(hub.handleContexts))
	mux.HandleFunc("POST /api/kubeconfig", hub.auth(hub.handleAddKubeconfig))
	mux.HandleFunc("DELETE /api/kubeconfig", hub.auth(hub.handleDeleteKubeconfig))
	mux.HandleFunc("GET /api/state", hub.cluster((*Bridge).handleState))
	mux.HandleFunc("GET /api/ws", hub.cluster((*Bridge).handleWS))
	mux.HandleFunc("GET /api/logs", hub.cluster((*Bridge).handleLogs))
	mux.HandleFunc("POST /api/action", hub.cluster((*Bridge).handleAction))
	mux.HandleFunc("POST /api/kubectl", hub.cluster((*Bridge).handleKubectl))
	mux.HandleFunc("GET /api/manifest", hub.cluster((*Bridge).handleManifestGet))
	mux.HandleFunc("POST /api/manifest", hub.cluster((*Bridge).handleManifestPut))
	mux.HandleFunc("GET /api/assistant", hub.auth(hub.handleAIStatus))
	mux.HandleFunc("POST /api/assistant", hub.cluster((*Bridge).handleAssistant))
	mux.HandleFunc("POST /api/assistant/config", hub.auth(hub.handleAIConfig))
	mux.HandleFunc("POST /api/assistant/download", hub.auth(hub.handleAIDownload))
	mux.HandleFunc("DELETE /api/assistant/model", hub.auth(hub.handleAIDeleteModel))
	if *webDir != "" {
		// Always revalidated (a rebuilt game never runs from a stale cache), gzipped.
		mux.Handle("/", webHandler(*webDir))
		log.Printf("serving web build from %s", *webDir)
	}

	srv := &http.Server{Addr: *addr, Handler: guard(mux, *origins)}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	scheme := "http"
	if *lan {
		scheme = "https"
	}
	log.Printf("k8s-bridge listening on %s://%s (readonly=%v)", scheme, *addr, *readOnly)
	if len(lanURLs) > 0 {
		log.Printf("LAN mode (HTTPS): open one of these on your phone/tablet (same Wi-Fi). The browser warns once about the self-signed certificate: accept it. The token is in the URL: share it only with people you trust.")
		for _, u := range lanURLs {
			log.Printf("   %s", u)
		}
	}
	var err error
	if *lan {
		// Browsers only run the Godot web build in a secure context: HTTPS
		// with a self-signed certificate (accept it once on the phone).
		cert, key, cerr := lanCert(filepath.Join(filepath.Dir(*dataDir), "tls"))
		if cerr != nil {
			log.Fatalf("LAN certificate: %v", cerr)
		}
		err = srv.ListenAndServeTLS(cert, key)
	} else {
		err = srv.ListenAndServe()
	}
	if err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// startBridge connects to one cluster (informers + metrics) and returns it
// once its caches are synced, or an error if the cluster is unreachable.
func startBridge(root context.Context, cc clientcmd.ClientConfig, ctxName, kubeconfigPath string, readOnly bool) (*Bridge, error) {
	cfg, err := cc.ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("client config: %w", err)
	}
	cfg.UserAgent = "k8sgame-bridge"
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("clientset: %w", err)
	}
	b := &Bridge{
		cs: cs, contextName: ctxName, server: cfg.Host, readOnly: readOnly,
		clients: map[*client]struct{}{}, kubeconfigPath: kubeconfigPath,
	}
	ctx, cancel := context.WithCancel(root)
	b.stop = cancel
	f := informers.NewSharedInformerFactory(cs, 10*time.Minute)
	b.nodeLister = f.Core().V1().Nodes().Lister()
	b.nsLister = f.Core().V1().Namespaces().Lister()
	b.podLister = f.Core().V1().Pods().Lister()
	b.svcLister = f.Core().V1().Services().Lister()
	b.depLister = f.Apps().V1().Deployments().Lister()
	b.rsLister = f.Apps().V1().ReplicaSets().Lister()
	b.stsLister = f.Apps().V1().StatefulSets().Lister()
	b.dsLister = f.Apps().V1().DaemonSets().Lister()
	markDirty := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { b.markDirty() },
		UpdateFunc: func(any, any) { b.markDirty() },
		DeleteFunc: func(any) { b.markDirty() },
	}
	for _, inf := range []cache.SharedIndexInformer{
		f.Core().V1().Nodes().Informer(),
		f.Core().V1().Namespaces().Informer(),
		f.Core().V1().Pods().Informer(),
		f.Core().V1().Services().Informer(),
		f.Apps().V1().Deployments().Informer(),
		f.Apps().V1().ReplicaSets().Informer(),
		f.Apps().V1().StatefulSets().Informer(),
		f.Apps().V1().DaemonSets().Informer(),
	} {
		if _, err := inf.AddEventHandler(markDirty); err != nil {
			cancel()
			return nil, err
		}
	}
	b.watchEvents(ctx, f)
	b.startWatch(ctx, f)
	log.Printf("[%s] connecting to %s ...", ctxName, cfg.Host)
	f.Start(ctx.Done())
	syncCtx, syncCancel := context.WithTimeout(ctx, 25*time.Second)
	defer syncCancel()
	for typ, ok := range f.WaitForCacheSync(syncCtx.Done()) {
		if !ok {
			cancel()
			return nil, fmt.Errorf("cluster %s unreachable (cache sync failed for %v)", cfg.Host, typ)
		}
	}
	log.Printf("[%s] cluster cache synced", ctxName)
	b.markDirty()
	go b.publishLoop(ctx)
	go b.pollMetrics(ctx)
	return b, nil
}

// guard protects the API from drive-by browser requests: any web page you
// visit could otherwise POST to 127.0.0.1:8088 and delete your pods. Only
// requests without an Origin (native game, curl) or from allowed origins
// (localhost, --allow-origin) get through. The Host check blocks DNS rebinding.
func guard(h http.Handler, extra string) http.Handler {
	allowed := map[string]bool{}
	for _, o := range strings.Split(extra, ",") {
		if o = strings.TrimSpace(o); o != "" {
			allowed[strings.TrimSuffix(o, "/")] = true
		}
	}
	isLocal := func(host string) bool {
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		host = strings.Trim(host, "[]")
		return host == "localhost" || host == "127.0.0.1" || host == "::1"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(allowed) == 0 && !isLocal(r.Host) {
			http.Error(w, "forbidden host (use --allow-origin to expose the bridge)", http.StatusForbidden)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			u, err := url.Parse(origin)
			if err != nil || !(allowed[origin] || isLocal(u.Host)) {
				http.Error(w, "forbidden origin", http.StatusForbidden)
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Bridge-Token")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func (b *Bridge) markDirty() {
	b.mu.Lock()
	b.dirty = true
	b.mu.Unlock()
}

// publishLoop coalesces bursts of informer events into at most ~3 snapshots/s.
func (b *Bridge) publishLoop(ctx context.Context) {
	t := time.NewTicker(300 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		b.mu.Lock()
		dirty := b.dirty
		b.dirty = false
		b.mu.Unlock()
		if !dirty {
			continue
		}
		snap, err := b.buildSnapshot()
		if err != nil {
			log.Printf("snapshot: %v", err)
			continue
		}
		msg, _ := json.Marshal(map[string]any{"type": "state", "data": snap})
		b.mu.Lock()
		b.last = msg
		b.mu.Unlock()
		b.broadcast(msg)
	}
}

func (b *Bridge) broadcast(msg []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for c := range b.clients {
		select {
		case c.send <- msg:
		default: // slow client: drop message, next snapshot will catch it up
		}
	}
}

func (b *Bridge) handleState(w http.ResponseWriter, r *http.Request) {
	snap, err := b.buildSnapshot()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

func (b *Bridge) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true} /* origin checked in guard */)
	if err != nil {
		return
	}
	conn.SetReadLimit(1 << 20)
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	c := &client{send: make(chan []byte, 16), addr: r.RemoteAddr, ip: ip, agent: shortAgent(r.UserAgent()), since: time.Now()}
	b.mu.Lock()
	b.clients[c] = struct{}{}
	last := b.last
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.clients, c)
		b.mu.Unlock()
		conn.CloseNow()
	}()
	log.Printf("game client connected from %s (%s)", r.RemoteAddr, shortAgent(r.UserAgent()))
	since := time.Now()
	defer func() {
		log.Printf("game client %s disconnected after %s", r.RemoteAddr, time.Since(since).Round(time.Second))
	}()

	ctx := conn.CloseRead(r.Context())
	if last != nil {
		c.send <- last
	}
	if b.watch != nil {
		if wm := b.watchMessage(true); wm != nil {
			b.broadcast(wm)
		}
	}
	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-c.send:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				return
			}
		case <-ping.C:
			if err := conn.Ping(ctx); err != nil {
				return
			}
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func cacheHandler(fn func(any)) cache.ResourceEventHandlerFuncs {
	return cache.ResourceEventHandlerFuncs{
		AddFunc:    fn,
		UpdateFunc: func(_, n any) { fn(n) },
	}
}

func isLoopback(host string) bool {
	host = strings.Trim(host, "[]")
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
