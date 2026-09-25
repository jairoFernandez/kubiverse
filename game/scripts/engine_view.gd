class_name EngineView
extends PanelContainer
## ENGINE ROOM narrator. Every cluster event (and every change you make)
## becomes a work order that travels between the machines, with a sentence
## saying what that component just did. TEACH ME walks a pod's whole life:
## on a sandbox it creates a small Deployment and follows its real events;
## on production it replays the last pod the cluster started (nothing is
## created). A step whose real event doesn't show up is played anyway.

const TOUR_NAME := "engine-tour"
const TOUR_NS := "academia"
const STEPS := [
	["you", "You ask for a Deployment. The API server checks who you are (authentication), whether you may (RBAC) and validates it, then stores it in etcd."],
	["ScalingReplicaSet", "The Deployment controller (in the controller manager) sees it and creates a ReplicaSet for it, through the API server."],
	["SuccessfulCreate", "The ReplicaSet controller sees 0 of 1 pods and creates a Pod object. It has no node yet: it is Pending."],
	["Scheduled", "The scheduler sees a pod without a node, scores the nodes (free CPU / memory, taints, affinity) and binds it to one."],
	["Pulling", "The kubelet on that node sees a pod assigned to it and asks the container runtime to pull the image."],
	["Started", "The runtime starts the container; the kubelet reports Running and Ready back to the API server. Done: desired = actual."],
]

var hud: Node
var _events: Array = []        # last cluster events (for the production replay)
var _feed: Array = []          # narration lines, newest first
var _list: RichTextLabel
var _steps_lbl: RichTextLabel
var _teach: Button
var _clean: Button
var _tour := {}                # {idx, t, name, mode: "live" | "replay", queue}


func _init(h: Node) -> void:
	hud = h
	visible = false
	add_theme_stylebox_override("panel", h._flat(Color(0.12, 0.08, 0.06, 0.94), Vox.ORANGE, 3, 12))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.custom_minimum_size = Vector2(480, 0)
	add_child(v)
	var hh := HBoxContainer.new()
	var t: Label = h._label("ENGINE ROOM: WHAT JUST HAPPENED", 22, Vox.ORANGE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(t)
	hh.add_child(h._button("_", func(): _list.visible = not _list.visible))
	v.add_child(hh)
	var note: Label = h._label("Every event of the cluster travels between the machines. Click a machine to see what it is.", 18, Vox.LAVENDER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(note)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 8)
	_teach = h._button("TEACH ME: THE LIFE OF A POD", teach, "GoButton")
	bh.add_child(_teach)
	_clean = h._button("REMOVE engine-tour", _cleanup, "DangerButton")
	_clean.visible = false
	bh.add_child(_clean)
	v.add_child(bh)
	_steps_lbl = h._rich(19)
	_steps_lbl.visible = false
	v.add_child(_steps_lbl)
	_list = h._rich(19)
	_list.fit_content = false
	_list.custom_minimum_size = Vector2(0, 220)
	v.add_child(_list)
	K8s.cluster_event.connect(_on_event)
	K8s.action_started.connect(_on_action)


func _world() -> World:
	return hud.world


func _on_event(ev: Dictionary) -> void:
	_events.append(ev)
	if _events.size() > 120:
		_events.pop_front()
	if _world() == null or _world().level != "engine":
		return
	play(ev)
	if not _tour.is_empty() and _tour.mode == "live" and str(ev.get("name", "")).begins_with(TOUR_NAME):
		_tour_seen(str(ev.get("reason", "")))


func _on_action(req: Dictionary) -> void:
	if _world() == null or _world().level != "engine":
		return
	var cmd: String = Kubectl.for_action(req).get_slice("\n", 0)
	_world().engine_flow(["you", "api", "etcd"], cmd.trim_prefix("kubectl ").left(34), Vox.GREEN)
	_say(tr("You: %s. The API server authenticates you, checks RBAC, validates the object and saves it in etcd; controllers react to the change.") % cmd)


## A longer explanation of each machine, for its inspector.
static func explain(comp: String) -> String:
	match comp:
		"api": return "kube-apiserver is the only component that talks to etcd. Everything else (kubectl, the scheduler, controllers, every kubelet) reads and writes through its REST API and WATCHES it for changes. Each request goes through authentication, authorization (RBAC) and admission (validation, defaults, policies) before it is stored."
		"etcd": return "etcd is a consistent key-value store (Raft). It holds every object: Deployments, Pods, Secrets, ConfigMaps... With 3 or 5 members it survives losing 1 or 2. Back it up: it IS the cluster."
		"controllers": return "kube-controller-manager runs dozens of control loops: Deployment, ReplicaSet, Node, Job, EndpointSlice, ServiceAccount... Each one watches the API server, compares desired and actual state and acts to close the gap. That's why a deleted pod comes back."
		"scheduler": return "kube-scheduler watches for pods with no node. It filters the nodes that can run it (resources, taints/tolerations, node selectors, affinity) and scores the rest, then writes the binding to the API server. It never starts anything itself."
		"kubelet": return "The kubelet runs on every node. It watches the API server for pods bound to its node, asks the container runtime (containerd, CRI-O) to pull images and start containers, runs the probes and reports status back."
		"you": return "kubectl (or Helm, Argo CD, your CI) only talks to the API server: it sends the desired state. Nothing happens directly: controllers, the scheduler and kubelets react to what is stored."
		"dns": return "CoreDNS runs as pods in kube-system and answers cluster names: my-svc.my-namespace.svc.cluster.local resolves to the Service's IP. Every pod uses it as its DNS server."
		"proxy": return "kube-proxy runs on every node and turns Services into network rules (iptables / IPVS): traffic to a Service IP is sent to one of its ready pods. Some CNIs (Cilium) replace it with eBPF."
		"cni": return "The CNI plugin (Calico, Cilium, Flannel, kindnet...) gives each pod an IP and routes traffic between pods on different nodes; network policies are enforced here."
	return ""


## One event -> one work order and one sentence.
func play(ev: Dictionary) -> void:
	var w := _world()
	var who := "%s/%s" % [ev.get("ns", ""), ev.get("name", "")]
	var msg := str(ev.get("message", ""))
	var kl := _kubelet_for(ev)
	match str(ev.get("reason", "")):
		"ScalingReplicaSet":
			w.engine_flow(["controllers", "api", "etcd"], "scale " + str(ev.name).left(24), Vox.ORANGE)
			_say(tr("Controller manager (Deployment controller): %s — %s. Saved in etcd through the API server.") % [who, msg])
		"SuccessfulCreate":
			w.engine_flow(["controllers", "api", "etcd"], "create pod", Vox.ORANGE)
			_say(tr("Controller manager: %s — %s. The new pod has no node yet (Pending).") % [who, msg])
		"Scheduled":
			w.engine_flow(["scheduler", "api", "etcd", kl], str(ev.name).left(22) + " -> " + kl.get_slice(":", 1), Vox.YELLOW)
			_say(tr("Scheduler: %s. The binding is saved in etcd; the kubelet of that node picks it up.") % msg)
		"Pulling", "Pulled":
			w.engine_flow([kl], "image", Vox.BLUE)
			_say(tr("Kubelet + container runtime on %s: %s") % [kl.get_slice(":", 1), msg])
		"Created", "Started":
			w.engine_flow([kl, "api", "etcd"], str(ev.reason).to_lower(), Vox.GREEN)
			_say(tr("Kubelet on %s: %s. It reports the pod status to the API server.") % [kl.get_slice(":", 1), msg])
		"Killing":
			w.engine_flow(["api", kl], "stop " + str(ev.name).left(20), Vox.SILVER)
			_say(tr("Kubelet on %s stops a container of %s (%s).") % [kl.get_slice(":", 1), who, msg])
		"FailedScheduling":
			w.engine_flow(["scheduler", "api"], "no node!", Vox.RED)
			_say(tr("Scheduler can't place %s: %s") % [who, msg])
		"BackOff", "Failed", "Unhealthy", "FailedMount":
			w.engine_flow([kl, "api"], str(ev.reason), Vox.RED)
			_say(tr("Kubelet on %s reports a problem with %s: %s") % [kl.get_slice(":", 1), who, msg])
		"NodeNotSchedulable", "NodeSchedulable", "NodeNotReady", "NodeReady", "RegisteredNode":
			w.engine_flow(["api", _kubelet_for({"kind": "Node", "name": ev.name})], str(ev.reason), Vox.LAVENDER)
			_say(tr("Node %s: %s") % [ev.name, msg])
		_:
			if str(ev.get("kind", "")) in ["Deployment", "ReplicaSet", "StatefulSet", "DaemonSet", "Job"]:
				w.engine_flow(["controllers", "api"], str(ev.reason), Vox.ORANGE)
			_say("%s %s: %s" % [ev.get("reason", ""), who, msg])


## The kubelet machine of the node an event is about (pods: their node).
func _kubelet_for(ev: Dictionary) -> String:
	var node := ""
	if str(ev.get("kind", "")) == "Node":
		node = str(ev.get("name", ""))
	else:
		var m := RegEx.create_from_string("to (\\S+)$").search(str(ev.get("message", "")))
		if m:
			node = m.get_string(1)
		for p in K8s.state.get("pods", []):
			if p.ns == ev.get("ns", "") and p.name == ev.get("name", "") and str(p.get("node", "")) != "":
				node = p.node
	var w := _world()
	if w and w.machines.has("kubelet:" + node):
		return "kubelet:" + node
	for k in (w.machines.keys() if w else []):
		if str(k).begins_with("kubelet:"):
			return k
	return "api"


func _say(line: String) -> void:
	var t := Time.get_time_string_from_system().left(8)
	_feed.push_front("[color=#83769c]%s[/color] %s" % [t, hud._esc(line)])
	_feed = _feed.slice(0, 30)
	_list.text = "\n".join(_feed)


# ------------------------------------------------------------------ tour

func teach() -> void:
	if K8s.is_prod():
		_replay()
		return
	hud.confirm(tr("Create a small Deployment '%s' in namespace '%s' (1 nginx pod) and follow its life through the machines?") % [TOUR_NAME, TOUR_NS], func():
		_tour = {"idx": 0, "t": 0.0, "mode": "live", "name": TOUR_NAME}
		_render_steps()
		K8s.action({"action": "create_deployment", "ns": TOUR_NS, "name": TOUR_NAME, "image": "nginx:alpine", "replicas": 1, "service": false})
		_clean.visible = true,
		"kubectl -n %s create deployment %s --image=nginx:alpine" % [TOUR_NS, TOUR_NAME])


func _cleanup() -> void:
	hud.confirm(tr("Delete the tour Deployment %s/%s?") % [TOUR_NS, TOUR_NAME], func():
		K8s.action({"action": "delete_workload", "kind": "Deployment", "ns": TOUR_NS, "name": TOUR_NAME})
		_clean.visible = false, "kubectl -n %s delete deployment %s" % [TOUR_NS, TOUR_NAME])


## Production: replay the last pod the cluster started (its real events).
func _replay() -> void:
	var pod := ""
	for i in range(_events.size() - 1, -1, -1):
		if _events[i].get("reason", "") == "Scheduled":
			pod = "%s/%s" % [_events[i].ns, _events[i].name]
			break
	var q := []
	if pod != "":
		for ev in _events:
			var k := "%s/%s" % [ev.get("ns", ""), ev.get("name", "")]
			if (k == pod or (ev.get("reason", "") == "SuccessfulCreate" and str(ev.get("message", "")).ends_with(pod.get_slice("/", 1)))) and ev.get("reason", "") in ["SuccessfulCreate", "Scheduled", "Pulling", "Pulled", "Created", "Started"]:
				q.append(ev)
	_tour = {"idx": 0, "t": 0.0, "mode": "replay", "queue": q, "name": pod.get_slice("/", 1) if pod != "" else "example-pod"}
	_say(tr("Replaying the last pod the cluster started (%s): nothing is created on production.") % (pod if pod != "" else tr("none seen yet: an example")))
	_render_steps()


func _tour_seen(reason: String) -> void:
	var i := int(_tour.idx)
	if i < STEPS.size() and (STEPS[i][0] == reason or (STEPS[i][0] == "Started" and reason == "Started")):
		_tour.idx = i + 1
		_tour.t = 0.0
		_render_steps()


func _process(delta: float) -> void:
	if _tour.is_empty() or _world() == null or _world().level != "engine":
		return
	_tour.t += delta
	var i := int(_tour.idx)
	if i >= STEPS.size():
		if _tour.t > 6.0:
			_tour = {}
			_render_steps()
		return
	var wait := 2.5 if _tour.mode == "replay" or i == 0 else 7.0
	if _tour.t < wait:
		return
	# The real event didn't come (or this is a replay): play the step.
	var reason: String = STEPS[i][0]
	var ev := {"ns": TOUR_NS, "name": _tour.name, "kind": "Pod", "reason": reason, "message": ""}
	if _tour.mode == "replay":
		for e in _tour.get("queue", []):
			if e.get("reason", "") == reason:
				ev = e
	if reason == "you":
		_world().engine_flow(["you", "api", "etcd"], "create deployment", Vox.GREEN)
	elif ev.get("message", "") == "" and reason != "you":
		ev.message = {"ScalingReplicaSet": "Scaled up replica set to 1", "SuccessfulCreate": "Created pod: %s" % _tour.name,
			"Scheduled": "Successfully assigned %s to a node" % _tour.name, "Pulling": "Pulling image \"nginx:alpine\"",
			"Started": "Started container"}.get(reason, "")
		play(ev)
	else:
		play(ev)
	_tour.idx = i + 1
	_tour.t = 0.0
	_render_steps()


func _render_steps() -> void:
	_steps_lbl.visible = not _tour.is_empty()
	if _tour.is_empty():
		return
	var rows := []
	for i in STEPS.size():
		var col := "#00e436" if i < int(_tour.idx) else ("#ffec27" if i == int(_tour.idx) else "#5f574f")
		rows.append("[color=%s]%d. %s[/color]" % [col, i + 1, tr(STEPS[i][1])])
	_steps_lbl.text = "\n".join(rows)
