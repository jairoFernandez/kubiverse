class_name MockCluster
extends Node
## A tiny simulated Kubernetes: reconciles workloads into pods, schedules
## them onto nodes, crash-loops the flaky ones and emits events. Used for
## "demo mode" (e.g. the web build without a bridge) and for testing.

signal state_changed(state: Dictionary)
signal event(ev: Dictionary)
signal watch(data: Dictionary)   # simulated WATCHTOWER visitors (demo only)

var nodes := {}      # name -> {name, ready, unschedulable, roles, ...}
var workloads := {}  # "ns/kind/name" -> {kind, ns, name, desired, image, behaviour, containers}
var pods := {}       # "ns/name" -> pod dict + private "_t" timers
var services := {}   # "ns/name" -> {ns, name, type, cluster_ip, ports, app}
var namespaces := ["default", "kube-system", "shop", "payments", "monitoring", "ml", "data"]

var _clock := 0.0
var _tick := 0.0
var _dirty := true
var _ip := 10
var _chaos_t := 15.0
var _field_node := ""
var _watch_t := 2.0
var _visitors := {}
# Demo cast for WATCHTOWER mode: [user, agent, ip, groups, delay before arriving]
const CAST := [
	["kubernetes-admin", "kubectl/v1.33.9", "127.0.0.1", ["system:masters"], 0.0],
	["alice@dev-team", "kubectl/v1.32.2", "10.0.4.21", ["developers"], 6.0],
	["system:serviceaccount:argocd:argocd-application-controller", "argocd-application-controller/v2.13", "10.244.1.7", ["system:serviceaccounts"], 12.0],
	["ci-deployer", "helm/v3.16.2", "172.18.0.9", ["ci"], 25.0],
	["unknown", "curl/8.7.1", "203.0.113.66", ["system:authenticated"], 45.0],
]


func start() -> void:
	_node("control-plane", ["control-plane"])
	_node("worker-a", [])
	_node("worker-b", [])
	_node("worker-c", [])
	_node("gpu-1", [])
	nodes["gpu-1"]["gpu"] = true
	_wl("Deployment", "kube-system", "coredns", 2, "coredns/coredns:1.11", "ok")
	_wl("DaemonSet", "kube-system", "kube-proxy", 0, "registry.k8s.io/kube-proxy:v1.31", "ok")
	_wl("Deployment", "shop", "frontend", 3, "nginx:alpine", "ok")
	_wl("Deployment", "shop", "cart", 2, "busybox:1.36", "ok", ["cart", "sidecar"])
	_wl("StatefulSet", "shop", "redis", 1, "redis:7-alpine", "ok")
	_wl("Deployment", "payments", "ledger", 2, "busybox:1.36", "crash")
	_wl("Deployment", "payments", "fraud-ai", 1, "registry.invalid/fraud-ai:v9", "pullfail")
	_wl("DaemonSet", "monitoring", "node-exporter", 0, "prom/node-exporter", "ok")
	_wl("Deployment", "ml", "trainer", 2, "pytorch/trainer:latest", "gpu")
	_wl("Deployment", "ml", "giant-experiment", 1, "busybox", "unschedulable")
	_wl("StatefulSet", "data", "broker", 3, "busybox", "ok")
	_svc("data", "broker", "ClusterIP", "broker", ["9092/TCP"], true)
	# CI namespace full of finished Argo Workflow steps (they pile up in real clusters).
	namespaces.append("ci")
	var steps := ["checkout", "build", "test", "push-image", "deploy"]
	for i in 45:
		var wf := "release-%d" % (100 + i / 5)
		var n := "%s-%s-%d" % [wf, steps[i % 5], 1400000000 + i * 7919]
		pods["ci/" + n] = {"ns": "ci", "name": n, "node": ["worker-a", "worker-b", "worker-c"][i % 3], "phase": "Succeeded",
			"status": "Completed", "ready": 0, "total": 2, "restarts": 0, "owner_kind": "Workflow", "owner_name": wf,
			"containers": ["wait", "main"], "images": ["quay.io/argoproj/argoexec:v3.5", "alpine:3.20"], "ip": "",
			"age": 3600.0 * (45 - i), "deleting": false, "_t": 0.0, "_wl": "", "_want_node": "", "cpu_req_m": 100, "mem_req": 64 * 1024 * 1024, "message": ""}
	_svc("kube-system", "kube-dns", "ClusterIP", "coredns", ["53/UDP", "53/TCP"])
	_svc("shop", "frontend", "LoadBalancer", "frontend", ["80/TCP"])
	_svc("shop", "cart", "ClusterIP", "cart", ["8080/TCP"])
	_svc("shop", "redis", "ClusterIP", "redis", ["6379/TCP"], true)
	_svc("payments", "ledger", "NodePort", "ledger", ["9000/TCP"])
	_svc("monitoring", "prometheus", "ClusterIP", "node-exporter", ["9100/TCP"])
	# Warm up so the world starts populated.
	for i in 40:
		_reconcile(0.25)
	_emit()


func _node(n: String, roles: Array) -> void:
	nodes[n] = {"name": n, "ready": true, "unschedulable": false, "roles": roles, "cpu": "4",
		"memory": "8Gi", "pod_capacity": 110, "kubelet": "v1.31.0-demo", "os": "linux", "arch": "amd64", "age": 86400 * 12,
		"cpu_m": 4000, "mem_bytes": 8 * 1024 * 1024 * 1024}


func _wl(kind: String, ns: String, n: String, desired: int, image: String, behaviour: String, containers := []) -> void:
	if containers.is_empty():
		containers = [n]
	workloads[ns + "/" + kind + "/" + n] = {"kind": kind, "ns": ns, "name": n, "desired": desired,
		"image": image, "behaviour": behaviour, "containers": containers, "gen": 0}


func _svc(ns: String, n: String, type: String, app: String, ports: Array, headless := false) -> void:
	services[ns + "/" + n] = {"ns": ns, "name": n, "type": type, "app": app, "ports": ports,
		"cluster_ip": "None" if headless else "10.96.%d.%d" % [randi() % 250, randi() % 250]}


func _process(delta: float) -> void:
	_clock += delta
	_tick += delta
	_chaos_t -= delta
	if _chaos_t <= 0.0:
		_chaos_t = randf_range(12.0, 25.0)
		_random_chaos()
	if _tick >= 0.25:
		_reconcile(_tick)
		_tick = 0.0
	if _dirty:
		_emit()
	_watch_t -= delta
	if _watch_t <= 0.0:
		_watch_t = randf_range(2.0, 4.0)
		_watch_tick()


func _random_chaos() -> void:
	# Occasionally something happens on its own, like in a real cluster.
	var running := pods.values().filter(func(p): return p.status == "Running" and not p.deleting)
	if running.is_empty():
		return
	var p: Dictionary = running.pick_random()
	p.restarts += 1
	p.status = "OOMKilled"
	p.ready = 0
	p._t = 0.0
	_ev(p.ns, "Pod", p.name, "BackOff", "Container %s was OOMKilled, restarting" % p.containers[0], "Warning")


func _reconcile(dt: float) -> void:
	for p in pods.values():
		p._t += dt
		p.age += dt
	# Pod lifecycle.
	for key in pods.keys():
		var p: Dictionary = pods[key]
		var wl: Dictionary = workloads.get(p._wl, {})
		var behaviour: String = wl.get("behaviour", "ok")
		if p.deleting:
			if p._t > 1.6:
				pods.erase(key)
				_dirty = true
			continue
		match p.status:
			"Pending":
				if p._t > 0.6:
					var node := _schedule(p)
					if node != "":
						p.node = node
						p.status = "ContainerCreating"
						p.ip = "10.244.%d.%d" % [randi() % 3, _next_ip()]
						p._t = 0.0
						_ev(p.ns, "Pod", p.name, "Scheduled", "Successfully assigned %s/%s to %s" % [p.ns, p.name, node], "Normal")
						_dirty = true
			"ContainerCreating":
				if p._t > 1.4:
					p._t = 0.0
					if behaviour == "pullfail":
						p.status = "ErrImagePull"
						_ev(p.ns, "Pod", p.name, "Failed", "Failed to pull image \"%s\": not found" % wl.image, "Warning")
					else:
						p.status = "Running"
						p.ready = p.total if behaviour in ["ok", "gpu"] else 0
						_ev(p.ns, "Pod", p.name, "Started", "Started container %s" % p.containers[0], "Normal")
					_dirty = true
			"ErrImagePull":
				if p._t > 2.0:
					p.status = "ImagePullBackOff"
					p._t = 0.0
					_ev(p.ns, "Pod", p.name, "BackOff", "Back-off pulling image \"%s\"" % wl.image, "Warning")
					_dirty = true
			"ImagePullBackOff":
				if p._t > 8.0:
					p.status = "ErrImagePull"
					p._t = 0.0
					_dirty = true
			"Running":
				if behaviour == "crash" and p._t > 4.0:
					p.status = "Error"
					p.ready = 0
					p._t = 0.0
					_dirty = true
				elif p.ready < p.total and behaviour in ["ok", "gpu"] and p._t > 0.5:
					p.ready = p.total
					_dirty = true
			"Error", "OOMKilled":
				if p._t > 1.5:
					p.status = "CrashLoopBackOff"
					p.restarts += 1
					p._t = 0.0
					_ev(p.ns, "Pod", p.name, "BackOff", "Back-off restarting failed container %s" % p.containers[0], "Warning")
					_dirty = true
			"CrashLoopBackOff":
				if p._t > 3.0 + min(p.restarts, 5):
					p.status = "Running"
					p.ready = p.total if behaviour in ["ok", "gpu"] else 0
					p._t = 0.0
					_dirty = true
	# Workload reconciliation.
	for wkey in workloads:
		var wl: Dictionary = workloads[wkey]
		var mine := pods.values().filter(func(p): return p._wl == wkey and not p.deleting)
		if wl.kind == "DaemonSet":
			for n in nodes:
				if not mine.any(func(p): return p.node == n or p.get("_want_node", "") == n):
					_new_pod(wkey, wl, n)
			continue
		if mine.size() < wl.desired:
			for i in wl.desired - mine.size():
				_new_pod(wkey, wl, "")
		elif mine.size() > wl.desired:
			mine.sort_custom(func(a, b): return a.age < b.age)
			for i in mine.size() - wl.desired:
				_kill(mine[i])


func _new_pod(wkey: String, wl: Dictionary, want_node: String) -> void:
	var n: String
	if wl.kind == "StatefulSet":
		var i := 0
		while pods.has(wl.ns + "/%s-%d" % [wl.name, i]):
			i += 1
		n = "%s-%d" % [wl.name, i]
	else:
		var hash_part: String = ("%x" % (wl.gen * 7919 + wl.name.hash())).right(5) if wl.kind == "Deployment" else ""
		n = wl.name + ("-" + hash_part if hash_part != "" else "") + "-" + _rand_suffix()
	pods[wl.ns + "/" + n] = {
		"ns": wl.ns, "name": n, "node": "", "phase": "Pending", "status": "Pending",
		"ready": 0, "total": wl.containers.size(), "restarts": 0, "owner_kind": wl.kind,
		"owner_name": wl.name, "containers": wl.containers, "images": wl.containers.map(func(_c): return wl.image),
		"ip": "", "age": 0.0, "deleting": false, "_t": 0.0, "_wl": wkey, "_want_node": want_node,
		"cpu_req_m": (64000 if wl.behaviour == "unschedulable" else 100 * wl.containers.size()), "mem_req": 128 * 1024 * 1024 * wl.containers.size(),
		"message": ("0/%d nodes are available: %d Insufficient cpu, 1 node(s) had untolerated taint(s)." % [nodes.size(), nodes.size() - 1]) if wl.behaviour == "unschedulable" else "",
	}
	_dirty = true


func _schedule(p: Dictionary) -> String:
	if p._want_node != "":
		return p._want_node if nodes.has(p._want_node) else ""
	var beh: String = workloads.get(p._wl, {}).get("behaviour", "ok")
	if beh == "unschedulable":
		return ""  # asks for more CPU than any node has
	var best := ""
	var best_n := 1 << 30
	for n in nodes:
		var nd: Dictionary = nodes[n]
		if not nd.ready or nd.unschedulable or "control-plane" in nd.roles:
			continue
		# GPU node is tainted: only gpu workloads go there, and they only go there.
		if nd.get("gpu", false) != (beh == "gpu"):
			continue
		var cnt := pods.values().filter(func(q): return q.node == n).size()
		if cnt < best_n:
			best_n = cnt
			best = n
	if best == "" and p._t > 3.0 and int(p._t * 4) % 20 == 0:
		_ev(p.ns, "Pod", p.name, "FailedScheduling", "0/%d nodes are available" % nodes.size(), "Warning")
	return best


func _kill(p: Dictionary) -> void:
	if p.deleting:
		return
	p.deleting = true
	p.status = "Terminating"
	p._t = 0.0
	_ev(p.ns, "Pod", p.name, "Killing", "Stopping container %s" % p.containers[0], "Normal")
	_dirty = true


func _rand_suffix() -> String:
	var chars := "bcdfghjklmnpqrstvwxz2456789"
	var s := ""
	for i in 5:
		s += chars[randi() % chars.length()]
	return s


func _next_ip() -> int:
	_ip = (_ip + 1) % 250
	return _ip + 2


func _ev(ns: String, kind: String, n: String, reason: String, message: String, etype: String) -> void:
	event.emit({"ns": ns, "kind": kind, "name": n, "reason": reason, "message": message, "etype": etype, "count": 1})


func action(req: Dictionary) -> Dictionary:
	var ns: String = req.get("ns", "")
	var n: String = req.get("name", "")
	var kind: String = req.get("kind", "")
	match req.get("action", ""):
		"delete_pod":
			var p = pods.get(ns + "/" + n)
			if p == null:
				return {"ok": false, "error": "pods \"%s\" not found" % n}
			_kill(p)
			return {"ok": true, "message": "pod %s deleted" % n}
		"scale":
			var wl = workloads.get(ns + "/" + kind + "/" + n)
			if wl == null or kind == "DaemonSet":
				return {"ok": false, "error": "cannot scale %s" % kind}
			wl.desired = clampi(int(req.get("replicas", 1)), 0, 50)
			_ev(ns, kind, n, "ScalingReplicaSet", "Scaled to %d" % wl.desired, "Normal")
			_dirty = true
			return {"ok": true, "message": "%s %s scaled to %d" % [kind, n, wl.desired]}
		"restart":
			var wkey := ns + "/" + kind + "/" + n
			var wl = workloads.get(wkey)
			if wl == null:
				return {"ok": false, "error": "not found"}
			wl.gen += 1
			for p in pods.values():
				if p._wl == wkey:
					_kill(p)
			return {"ok": true, "message": "%s %s rollout restarted" % [kind, n]}
		"cordon", "uncordon":
			if not nodes.has(n):
				return {"ok": false, "error": "node not found"}
			nodes[n].unschedulable = req.action == "cordon"
			_ev("", "Node", n, "NodeNotSchedulable" if nodes[n].unschedulable else "NodeSchedulable", "Node %s %sed" % [n, req.action], "Normal")
			_dirty = true
			return {"ok": true, "message": "node %s %sed" % [n, req.action]}
		"create_deployment":
			var image: String = req.get("image", "nginx:alpine")
			if image == "":
				image = "nginx:alpine"
			if not ns in namespaces:
				namespaces.append(ns)
			_wl("Deployment", ns, n, clampi(int(req.get("replicas", 1)), 1, 20), image, "pullfail" if image.contains("invalid") else "ok")
			if req.get("service", false):
				_svc(ns, n, "ClusterIP", n, ["80/TCP"])
			_dirty = true
			return {"ok": true, "message": "deployment %s/%s created" % [ns, n]}
		"add_control_plane":
			var i := 2
			while nodes.has("control-plane-%d" % i):
				i += 1
			var nn := "control-plane-%d" % i
			_node(nn, ["control-plane"])
			_ev("", "Node", nn, "RegisteredNode", "Node %s joined as control-plane (kubeadm join --control-plane)" % nn, "Normal")
			_ev("kube-system", "Pod", "etcd-" + nn, "Started", "etcd member added: the cluster now has %d members" % nodes.values().filter(func(n): return "control-plane" in n.roles).size(), "Normal")
			_dirty = true
			return {"ok": true, "message": "node %s joined as control-plane" % nn}
		"delete_service":
			if not services.has(ns + "/" + n):
				return {"ok": false, "error": "services \"%s\" not found" % n}
			services.erase(ns + "/" + n)
			_dirty = true
			return {"ok": true, "message": "service %s deleted" % n}
		"delete_workload":
			var wkey := ns + "/" + kind + "/" + n
			if not workloads.has(wkey):
				return {"ok": false, "error": "not found"}
			workloads.erase(wkey)
			for p in pods.values():
				if p._wl == wkey:
					_kill(p)
			_dirty = true
			return {"ok": true, "message": "%s %s deleted" % [kind, n]}
	return {"ok": false, "error": "unknown action"}


func logs(ns: String, pod: String, container: String, previous: bool) -> String:
	var p = pods.get(ns + "/" + pod)
	if p == null:
		return "error: pod not found"
	var wl: Dictionary = workloads.get(p._wl, {})
	var lines := PackedStringArray()
	var t: float = Time.get_unix_time_from_system() - p.age
	for i in 25:
		var ts := Time.get_datetime_string_from_unix_time(int(t + i * 2))
		match wl.get("behaviour", "ok"):
			"crash":
				lines.append("%s ledger starting (attempt %d)" % [ts, p.restarts + 1])
				if i % 3 == 2:
					lines.append("%s FATAL: db connection refused" % ts)
			"pullfail":
				return "Error from server (BadRequest): container \"%s\" is waiting to start: trying and failing to pull image" % container
			_:
				lines.append("%s [%s] GET /healthz 200 %dms" % [ts, container, randi() % 40 + 1])
	if previous:
		lines.insert(0, "--- previous instance ---")
	return "\n".join(lines)


func _emit() -> void:
	_dirty = false
	var s := {"context": "demo", "server": "simulated://kubecraft", "readonly": false,
		"time": int(Time.get_unix_time_from_system()), "nodes": [], "namespaces": [], "pods": [],
		"workloads": [], "services": []}
	for n in nodes.values():
		s.nodes.append(n.duplicate())
	for ns in namespaces:
		s.namespaces.append({"name": ns, "phase": "Active"})
	for p in pods.values():
		var out := {}
		for k in p:
			if not k.begins_with("_"):
				out[k] = p[k]
		out.phase = "Running" if p.status == "Running" else "Pending"
		s.pods.append(out)
	for wkey in workloads:
		var wl: Dictionary = workloads[wkey]
		var mine := pods.values().filter(func(p): return p._wl == wkey and not p.deleting)
		var ready := mine.filter(func(p): return p.status == "Running" and p.ready == p.total).size()
		var desired: int = nodes.size() if wl.kind == "DaemonSet" else wl.desired
		s.workloads.append({"kind": wl.kind, "ns": wl.ns, "name": wl.name, "desired": desired,
			"ready": ready, "updated": mine.size(), "available": ready, "image": wl.image})
	for sv in services.values():
		var mine := pods.values().filter(func(p): return p.ns == sv.ns and p.owner_name == sv.app)
		var backends := mine.map(func(p): return p.name)
		var ready := mine.filter(func(p): return p.status == "Running" and p.ready == p.total and not p.deleting).size()
		var ext := []
		var nps := []
		if sv.type == "LoadBalancer":
			ext = ["203.0.113.%d" % (10 + abs(sv.name.hash()) % 200)]
		if sv.type in ["LoadBalancer", "NodePort"]:
			nps = [30000 + abs(sv.name.hash()) % 2700]
		s.services.append({"ns": sv.ns, "name": sv.name, "type": sv.type, "cluster_ip": sv.cluster_ip,
			"ports": sv.ports, "selector": {"app": sv.app}, "pods": backends, "ready": ready, "external": ext, "node_ports": nps})
	# Ingresses: domains of the demo shop, one route pointing to a Service that doesn't exist.
	s["ingresses"] = [
		{"ns": "shop", "name": "storefront", "class": "nginx", "tls": ["shop.kubiverse.dev"], "address": ["198.51.100.7"],
			"rules": [{"host": "shop.kubiverse.dev", "path": "/", "service": "frontend", "port": "80"},
				{"host": "shop.kubiverse.dev", "path": "/cart", "service": "cart", "port": "8080"}]},
		{"ns": "payments", "name": "payments-api", "class": "nginx", "tls": [], "address": ["198.51.100.7"],
			"rules": [{"host": "pay.kubiverse.dev", "path": "/", "service": "ledger", "port": "9000"},
				{"host": "pay.kubiverse.dev", "path": "/fraud", "service": "fraud-ai", "port": "8501"}]},
		{"ns": "monitoring", "name": "grafana", "class": "nginx", "tls": ["grafana.kubiverse.dev"], "address": ["198.51.100.7"],
			"rules": [{"host": "grafana.kubiverse.dev", "path": "/", "service": "prometheus", "port": "9100"}]},
	]
	if "--many-hosts" in OS.get_cmdline_user_args():  # dev: stress the city layout
		for i in 11:
			var h := "app%d.%s.kubiverse.dev" % [i, ["eu", "us", "lab"][i % 3]]
			s.ingresses.append({"ns": "shop", "name": "extra%d" % i, "class": "nginx", "tls": [h] if i % 2 == 0 else [], "address": [],
				"rules": [{"host": h, "path": "/", "service": "frontend", "port": "80"}, {"host": h, "path": "/api", "service": "cart", "port": "8080"}]})
	# Fake but plausible metrics-server data.
	var m := {"available": true, "nodes": {}, "pods": {}}
	for p in pods.values():
		if p.status != "Running":
			continue
		var cpu: int = 20 + int(abs(sin(_clock * 0.3 + p.name.hash() % 100)) * 180)
		var mem: int = (40 + (p.name.hash() % 80)) * 1024 * 1024
		m.pods[p.ns + "/" + p.name] = {"cpu_m": cpu, "mem_bytes": mem}
		var nu: Dictionary = m.nodes.get(p.node, {"cpu_m": 150, "mem_bytes": 700 * 1024 * 1024})
		nu.cpu_m += cpu
		nu.mem_bytes += mem
		m.nodes[p.node] = nu
	s["metrics"] = m
	state_changed.emit(s)


# ------------------------------------------------------------ terminal

## A small kubectl emulator for demo mode: get/describe/logs plus every
## mutating command the game supports.
func kubectl(line: String) -> Dictionary:
	var c := Kubectl.parse(line)
	var ns: String = c.ns if c.ns != "" else "default"
	var all_ns: bool = c.all_ns
	var wide: bool = c.flags.get("o", c.flags.get("output", "")) == "wide"
	if c.verb == "delete" and str(c.flags.get("field-selector", "")).contains("status.phase==Succeeded"):
		var gone := []
		for k in pods.keys():
			if pods[k].ns == ns and pods[k].status == "Completed":
				gone.append("pod \"%s\" deleted" % pods[k].name)
				pods.erase(k)
		_dirty = true
		return {"ok": true, "output": "\n".join(gone) if gone else "No resources found"}
	var act := Kubectl.to_action(line, ns)
	if not act.is_empty():
		var res := action(act)
		return {"ok": res.ok, "output": res.get("message", "error: " + str(res.get("error", "")))}
	match c.verb:
		"", "help":
			return {"ok": true, "output": "demo kubectl: get, describe, logs, scale, delete, rollout restart, cordon, uncordon, create deployment"}
		"version":
			return {"ok": true, "output": "Client Version: v1.31.0-kubecraft\nServer Version: v1.31.0-demo"}
		"get":
			_field_node = ""
			var fs: String = c.flags.get("field-selector", "")
			if fs.begins_with("spec.nodeName="):
				_field_node = fs.substr(14)
			return {"ok": true, "output": _kget(c.pos, ns, all_ns, wide)}
		"describe":
			return _describe(c.pos, ns)
		"logs":
			if c.pos.is_empty():
				return {"ok": false, "output": "error: expected 'logs POD'"}
			var pod: String = c.pos[0].trim_prefix("pod/")
			if not pods.has(ns + "/" + pod):
				return {"ok": false, "output": "Error from server (NotFound): pods \"%s\" not found" % pod}
			return {"ok": true, "output": logs(ns, pod, c.flags.get("c", c.flags.get("container", "")), c.flags.has("previous") or c.flags.has("p"))}
	return {"ok": false, "output": "error: 'kubectl %s' is not supported in demo mode (connect a real cluster for full kubectl)" % c.verb}


func _table(rows: Array) -> String:
	var widths := []
	for r in rows:
		for i in r.size():
			if widths.size() <= i:
				widths.append(0)
			widths[i] = maxi(widths[i], str(r[i]).length())
	var out := PackedStringArray()
	for r in rows:
		var line := ""
		for i in r.size():
			line += str(r[i]).rpad(widths[i] + 3) if i < r.size() - 1 else str(r[i])
		out.append(line)
	return "\n".join(out)


func _age(s: float) -> String:
	var t := int(s)
	return "%ds" % t if t < 120 else ("%dm" % (t / 60) if t < 7200 else "%dh" % (t / 3600))


func _kget(pos: Array, ns: String, all_ns: bool, wide: bool) -> String:
	var what: String = pos[0].to_lower() if not pos.is_empty() else ""
	var ns_col := all_ns
	match what:
		"pods", "pod", "po":
			var rows := [(["NAMESPACE"] if ns_col else []) + ["NAME", "READY", "STATUS", "RESTARTS", "AGE"] + (["IP", "NODE"] if wide else [])]
			for p in pods.values():
				if (all_ns or p.ns == ns) and (_field_node == "" or p.node == _field_node):
					rows.append(([p.ns] if ns_col else []) + [p.name, "%d/%d" % [p.ready, p.total], p.status, p.restarts, _age(p.age)] + ([p.ip if p.ip != "" else "<none>", p.node if p.node != "" else "<none>"] if wide else []))
			return _table(rows) if rows.size() > 1 else "No resources found in %s namespace." % ns
		"nodes", "node", "no":
			var rows := [["NAME", "STATUS", "ROLES", "AGE", "VERSION"]]
			for n in nodes.values():
				var st := "Ready" if n.ready else "NotReady"
				if n.unschedulable:
					st += ",SchedulingDisabled"
				rows.append([n.name, st, ",".join(n.roles) if n.roles else "<none>", "12d", n.kubelet])
			return _table(rows)
		"deployments", "deployment", "deploy", "statefulsets", "sts", "daemonsets", "ds":
			var kind: String = Kubectl.KIND_ALIASES.get(what, "Deployment")
			var rows := [(["NAMESPACE"] if ns_col else []) + ["NAME", "READY", "UP-TO-DATE", "AVAILABLE"]]
			for wkey in workloads:
				var wl: Dictionary = workloads[wkey]
				if wl.kind == kind and (all_ns or wl.ns == ns):
					var mine := pods.values().filter(func(p): return p._wl == wkey and not p.deleting)
					var ready := mine.filter(func(p): return p.status == "Running" and p.ready == p.total).size()
					var desired: int = nodes.size() if kind == "DaemonSet" else wl.desired
					rows.append(([wl.ns] if ns_col else []) + [wl.name, "%d/%d" % [ready, desired], mine.size(), ready])
			return _table(rows) if rows.size() > 1 else "No resources found in %s namespace." % ns
		"services", "service", "svc":
			var rows := [(["NAMESPACE"] if ns_col else []) + ["NAME", "TYPE", "CLUSTER-IP", "PORT(S)"]]
			for sv in services.values():
				if all_ns or sv.ns == ns:
					rows.append(([sv.ns] if ns_col else []) + [sv.name, sv.type, sv.cluster_ip, ",".join(sv.ports)])
			return _table(rows) if rows.size() > 1 else "No resources found in %s namespace." % ns
		"namespaces", "namespace", "ns":
			var rows := [["NAME", "STATUS"]]
			for n in namespaces:
				rows.append([n, "Active"])
			return _table(rows)
		"all":
			return "\n\n".join([_kget(["pods"], ns, all_ns, wide), _kget(["svc"], ns, all_ns, wide), _kget(["deploy"], ns, all_ns, wide)])
	return "error: the server doesn't have a resource type \"%s\" (demo supports pods, nodes, deploy, sts, ds, svc, ns, all)" % what


func _describe(pos: Array, ns: String) -> Dictionary:
	var kn := Kubectl.kind_name(pos)
	var n: String = kn[1]
	if pos.size() >= 1 and pos[0] in ["pod", "pods", "po"] or str(pos[0]).begins_with("pod/"):
		var p = pods.get(ns + "/" + n)
		if p == null:
			return {"ok": false, "output": "Error from server (NotFound): pods \"%s\" not found" % n}
		var out := "Name:         %s\nNamespace:    %s\nNode:         %s\nStatus:       %s\nIP:           %s\nControlled By: %s/%s\nContainers:\n" % [
			p.name, p.ns, p.node if p.node != "" else "<none>", p.status, p.ip, p.owner_kind, p.owner_name]
		for i in p.containers.size():
			out += "  %s:\n    Image:  %s\n    Restart Count:  %d\n" % [p.containers[i], p.images[i], p.restarts]
		return {"ok": true, "output": out}
	if pos.size() >= 1 and pos[0] in ["node", "nodes", "no"]:
		var nd = nodes.get(n)
		if nd == null:
			return {"ok": false, "output": "Error from server (NotFound): nodes \"%s\" not found" % n}
		var here := pods.values().filter(func(p): return p.node == n).size()
		return {"ok": true, "output": "Name:          %s\nRoles:         %s\nUnschedulable: %s\nConditions:\n  Ready  %s\nCapacity:\n  cpu:   %s\n  memory: %s\nNon-terminated Pods: (%d in total)" % [
			n, ",".join(nd.roles) if nd.roles else "<none>", nd.unschedulable, nd.ready, nd.cpu, nd.memory, here]}
	return {"ok": false, "output": "error: demo 'describe' supports pods and nodes"}


# ------------------------------------------------------------ watchtower

## Simulated people using the demo cluster, in the bridge's format.
func _watch_tick() -> void:
	var now := int(Time.get_unix_time_from_system())
	var actions := []
	for c in CAST:
		if _clock < c[4]:
			continue
		var key: String = "audit|%s|%s" % [c[0], c[1]]
		var v: Dictionary = _visitors.get(key, {})
		var fresh := v.is_empty()
		if fresh:
			v = {"key": key, "user": c[0], "groups": c[3], "agent": c[1], "ips": [c[2]], "source": "audit",
				"first": now, "last": now, "requests": 0, "writes": 0, "denied": 0, "secrets": false, "self": false,
				"last_action": "", "last_ns": "", "last_resource": "", "last_name": ""}
			_visitors[key] = v
		elif randf() < 0.5:
			continue
		var a := _visitor_action(c[0])
		v.requests += 1
		v.last = now
		v.last_action = a.verb
		v.last_resource = a.resource
		v.last_ns = a.ns
		v.last_name = a.name
		if a.write:
			v.writes += 1
		if a.code == 403:
			v.denied += 1
		if a.resource == "secrets":
			v.secrets = true
		if fresh or a.write or a.code == 403 or a.resource == "secrets":
			a.merge({"key": key, "user": c[0], "agent": c[1], "ip": c[2], "time": now, "source": "audit", "self": false, "new": fresh})
			actions.append(a)
	watch.emit({"audit": true, "audit_dir": "(demo)", "visitors": _visitors.values(), "actions": actions})


func _visitor_action(user: String) -> Dictionary:
	var pick := func(ns: String) -> String:
		var ps := pods.values().filter(func(p): return p.ns == ns)
		return "" if ps.is_empty() else ps.pick_random().name
	match user:
		"alice@dev-team":
			if randf() < 0.3:
				return {"verb": "delete", "resource": "pods", "ns": "shop", "name": pick.call("shop"), "code": 200, "write": true}
			return {"verb": ["get", "list"].pick_random(), "resource": "pods", "ns": "shop", "name": "", "code": 200, "write": false}
		"system:serviceaccount:argocd:argocd-application-controller":
			return {"verb": "patch", "resource": "deployments", "ns": "shop", "name": "frontend", "code": 200, "write": true}
		"ci-deployer":
			return {"verb": ["update", "get"].pick_random(), "resource": "deployments", "ns": "payments", "name": "ledger", "code": 200, "write": randf() < 0.5}
		"unknown":
			return {"verb": "list", "resource": "secrets", "ns": ["payments", "kube-system", "default"].pick_random(), "name": "", "code": 403, "write": false}
	return {"verb": ["get", "list"].pick_random(), "resource": ["pods", "nodes", "deployments"].pick_random(), "ns": "", "name": "", "code": 200, "write": false}


# ------------------------------------------------------------ manifests

## YAML of an object, like `kubectl get -o yaml` without the noise.
func manifest(kind: String, ns: String, n: String) -> Dictionary:
	match kind:
		"Deployment", "StatefulSet", "DaemonSet":
			var wl = workloads.get(ns + "/" + kind + "/" + n)
			if wl == null:
				return {"ok": false, "error": "%s %s not found" % [kind, n]}
			var cpu := "64" if wl.behaviour == "unschedulable" else "100m"
			var lines := ["apiVersion: apps/v1", "kind: " + kind, "metadata:", "  labels:", "    app: " + n,
				"  name: " + n, "  namespace: " + ns, "spec:"]
			if kind != "DaemonSet":
				lines.append("  replicas: %d" % wl.desired)
			lines.append_array(["  selector:", "    matchLabels:", "      app: " + n, "  template:", "    metadata:",
				"      labels:", "        app: " + n, "    spec:", "      containers:"])
			for c in wl.containers:
				lines.append_array(["      - image: " + wl.image, "        name: " + c, "        resources:", "          requests:",
					"            cpu: " + cpu, "            memory: 128Mi", "          limits:", "            memory: 256Mi"])
			if wl.behaviour == "gpu":
				lines.append_array(["      nodeSelector:", "        accelerator: gpu", "      tolerations:", "      - effect: NoSchedule",
					"        key: gpu", "        operator: Equal", "        value: \"true\""])
			return {"ok": true, "yaml": "\n".join(lines) + "\n"}
		"Service":
			var sv = services.get(ns + "/" + n)
			if sv == null:
				return {"ok": false, "error": "service %s not found" % n}
			var lines := ["apiVersion: v1", "kind: Service", "metadata:", "  name: " + n, "  namespace: " + ns, "spec:",
				"  clusterIP: " + sv.cluster_ip, "  ports:"]
			for pt in sv.ports:
				lines.append_array(["  - port: %s" % str(pt).get_slice("/", 0), "    protocol: " + str(pt).get_slice("/", 1),
					"    targetPort: %s" % str(pt).get_slice("/", 0)])
			lines.append_array(["  selector:", "    app: " + sv.app, "  type: " + sv.type])
			return {"ok": true, "yaml": "\n".join(lines) + "\n"}
		"Pod":
			var p = pods.get(ns + "/" + n)
			if p == null:
				return {"ok": false, "error": "pod %s not found" % n}
			var lines := ["apiVersion: v1", "kind: Pod", "metadata:", "  name: " + n, "  namespace: " + ns, "spec:", "  containers:"]
			for i in p.containers.size():
				lines.append_array(["  - image: " + p.images[i], "    name: " + p.containers[i]])
			lines.append("  nodeName: " + p.node)
			return {"ok": true, "yaml": "\n".join(lines) + "\n"}
		"Node":
			var nd = nodes.get(n)
			if nd == null:
				return {"ok": false, "error": "node %s not found" % n}
			var lines := ["apiVersion: v1", "kind: Node", "metadata:", "  labels:", "    kubernetes.io/hostname: " + n]
			if nd.get("gpu", false):
				lines.append("    accelerator: gpu")
			lines.append_array(["  name: " + n, "spec:", "  unschedulable: %s" % str(nd.unschedulable).to_lower()])
			if nd.get("gpu", false):
				lines.append_array(["  taints:", "  - effect: NoSchedule", "    key: gpu", "    value: \"true\""])
			return {"ok": true, "yaml": "\n".join(lines) + "\n"}
	return {"ok": false, "error": "%s can't be edited in demo mode" % kind}


## Applies an edited manifest: the demo understands replicas, image, CPU
## requests and unschedulable (fixing the image or the CPU fixes the pods).
func apply_manifest(kind: String, ns: String, n: String, yaml: String, dry: bool) -> Dictionary:
	var get_val := func(key: String) -> String:
		var re := RegEx.new()
		re.compile("(?m)^\\s*-?\\s*" + key + ":\\s*(.+)$")
		var m := re.search(yaml)
		return m.get_string(1).strip_edges().trim_prefix("\"").trim_suffix("\"") if m else ""
	if get_val.call("kind") != kind or get_val.call("name") != n:
		return {"ok": false, "error": "kind and metadata.name must stay %s %s" % [kind, n]}
	var label := "%s/%s" % [kind.to_lower(), n]
	match kind:
		"Deployment", "StatefulSet", "DaemonSet":
			var wkey := ns + "/" + kind + "/" + n
			var wl = workloads.get(wkey)
			if wl == null:
				return {"ok": false, "error": "not found"}
			var reps: String = get_val.call("replicas")
			if reps != "" and not reps.is_valid_int():
				return {"ok": false, "error": "spec.replicas: Invalid value: \"%s\": must be an integer" % reps}
			var image: String = get_val.call("image")
			if image == "":
				return {"ok": false, "error": "spec.template.spec.containers[0].image: Required value"}
			if dry:
				return {"ok": true, "message": label + " (server dry run)"}
			var changed := false
			if reps != "" and kind != "DaemonSet":
				wl.desired = int(reps)
			if image != wl.image:
				wl.image = image
				changed = true
				if wl.behaviour == "pullfail" and not image.contains("invalid"):
					wl.behaviour = "ok"
			var cpu: String = get_val.call("cpu")
			if wl.behaviour == "unschedulable" and cpu != "" and cpu != "64":
				wl.behaviour = "ok"
				changed = true
			if changed:
				wl.gen += 1
				for p in pods.values():
					if p._wl == wkey:
						_kill(p)
			_ev(ns, kind, n, "Replaced", "%s replaced from the in-game editor" % label, "Normal")
			_dirty = true
			return {"ok": true, "message": label + " replaced"}
		"Node":
			if dry:
				return {"ok": true, "message": label + " (server dry run)"}
			nodes[n].unschedulable = get_val.call("unschedulable") == "true"
			_dirty = true
			return {"ok": true, "message": label + " replaced"}
	return {"ok": dry, "message": label + " (server dry run)", "error": "the demo can't apply %s changes" % kind}
