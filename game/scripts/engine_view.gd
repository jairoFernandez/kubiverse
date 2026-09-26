class_name EngineView
extends PanelContainer
## ENGINE ROOM panel, with two tabs:
##  - LESSONS: a course from zero to expert (EngineLessons). A lesson plays
##    step by step: each step sends a work order between the machines and
##    explains it. Play / pause, previous / next, and a timeline you can drag
##    to rewind; every step replays its animation. A quiz closes it and the
##    progress is kept. "The life of a pod" can run for real on a sandbox (a
##    small Deployment whose real events drive the steps) or, on production,
##    replay the last pod the cluster started.
##  - WHAT JUST HAPPENED: every cluster event (and every change you make) as
##    a work order and a sentence.
## The panel can be dragged by its title and resized from its borders.

const TOUR_NAME := "engine-tour"
const TOUR_NS := "academia"
const STEP_SECS := 9.0          # auto-advance while playing (time to read)
const COLORS := {"green": Vox.GREEN, "orange": Vox.ORANGE, "yellow": Vox.YELLOW, "blue": Vox.BLUE, "red": Vox.RED}

var hud: Node
var drag: DragResize
var _events: Array = []        # last cluster events (for the production replay)
var _feed: Array = []          # narration lines, newest first
var _list: RichTextLabel       # the feed
var _body: VBoxContainer
var _tabs: Array = []          # [lessons button, feed button]
var _tab := "lessons"
# lessons
var _catalog: VBoxContainer
var _player: VBoxContainer
var _l_title: Label
var _l_step: RichTextLabel     # the current step, big
var _l_steps: RichTextLabel    # every step (click to jump)
var _l_slider: HSlider
var _l_play: Button
var _l_quiz: VBoxContainer
var _l_live: Button
var _clean: Button
var _lesson := {}              # the lesson being played
var _idx := 0
var _playing := false
var _t := 0.0
var _live := {}                # the real life-of-a-pod tour: {mode: live|replay, name, queue, t}


func _init(h: Node) -> void:
	hud = h
	visible = false
	add_theme_stylebox_override("panel", h._flat(Color(0.12, 0.08, 0.06, 0.95), Vox.ORANGE, 3, 12))
	custom_minimum_size = Vector2(560, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var hh := HBoxContainer.new()
	var t: Label = h._label("ENGINE ROOM", 22, Vox.ORANGE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(t)
	for tab in [["LESSONS", "lessons"], ["WHAT JUST HAPPENED", "feed"]]:
		var b: Button = h._button(tab[0], func(): _show_tab(tab[1]))
		_tabs.append(b)
		hh.add_child(b)
	hh.add_child(h._button("_", func(): _body.visible = not _body.visible))
	v.add_child(hh)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_body)
	_build_catalog()
	_build_player()
	_list = h._rich(19)
	_list.fit_content = false
	_list.custom_minimum_size = Vector2(0, 260)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_list)
	drag = DragResize.new().attach(self, t)
	drag.min_size = Vector2(460, 240)
	K8s.cluster_event.connect(_on_event)
	K8s.action_started.connect(_on_action)
	_show_tab("lessons")


func _show_tab(tab: String) -> void:
	_tab = tab
	_tabs[0].theme_type_variation = "GoButton" if tab == "lessons" else ""
	_tabs[1].theme_type_variation = "GoButton" if tab == "feed" else ""
	_list.visible = tab == "feed"
	_catalog.visible = tab == "lessons" and _lesson.is_empty()
	_player.visible = tab == "lessons" and not _lesson.is_empty()
	if _catalog.visible:
		_fill_catalog()


# ---------------------------------------------------------------- catalog

func _build_catalog() -> void:
	_catalog = VBoxContainer.new()
	_catalog.add_theme_constant_override("separation", 4)
	_body.add_child(_catalog)


func _fill_catalog() -> void:
	for c in _catalog.get_children():
		c.queue_free()
	var done := 0
	for l in EngineLessons.LESSONS:
		if Settings.lessons_done.has(l.id):
			done += 1
	var head: Label = hud._label(tr("From zero to expert: %d of %d lessons done") % [done, EngineLessons.LESSONS.size()], 19, Vox.LAVENDER)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_catalog.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 320)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_catalog.add_child(scroll)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.add_theme_constant_override("separation", 4)
	scroll.add_child(lv)
	for lvl in EngineLessons.LEVELS.size():
		lv.add_child(hud._section(EngineLessons.t(EngineLessons.LEVELS[lvl])))
		for l in EngineLessons.LESSONS:
			if int(l.level) != lvl:
				continue
			var ok := Settings.lessons_done.has(l.id)
			var b: Button = hud._button(("[x] " if ok else "[ ] ") + EngineLessons.t(l.title), func(): open_lesson(l.id), "GoButton" if ok else "")
			b.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			lv.add_child(b)


# ----------------------------------------------------------------- player

func _build_player() -> void:
	_player = VBoxContainer.new()
	_player.add_theme_constant_override("separation", 6)
	_player.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_player)
	var ph := HBoxContainer.new()
	_l_title = hud._label("", 20, Vox.YELLOW)
	_l_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_l_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_l_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	ph.add_child(_l_title)
	ph.add_child(hud._button("ALL LESSONS", _close_lesson))
	_player.add_child(ph)
	# The step being explained, in a scrollable box.
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 130)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_player.add_child(sc)
	_l_step = hud._rich(21)
	_l_step.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_l_step)
	# The timeline: drag it to rewind or jump.
	_l_slider = HSlider.new()
	_l_slider.step = 1
	_l_slider.custom_minimum_size = Vector2(0, 28)
	_l_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_l_slider.tooltip_text = tr("Drag to rewind or jump to any step")
	_l_slider.value_changed.connect(func(val: float):
		if int(val) != _idx:
			_goto_step(int(val), true))
	_player.add_child(_l_slider)
	var ctl := HFlowContainer.new()
	ctl.add_theme_constant_override("h_separation", 6)
	ctl.add_theme_constant_override("v_separation", 6)
	ctl.add_child(hud._button("|<", func(): _goto_step(0, true)))
	ctl.add_child(hud._button("< PREV", func(): _goto_step(_idx - 1, true)))
	_l_play = hud._button("PLAY", _toggle_play, "GoButton")
	ctl.add_child(_l_play)
	ctl.add_child(hud._button("NEXT >", func(): _goto_step(_idx + 1, true)))
	ctl.add_child(hud._button("REPLAY STEP", func(): _animate(_idx)))
	_l_live = hud._button("RUN IT FOR REAL", _run_live, "GoButton")
	ctl.add_child(_l_live)
	_clean = hud._button("REMOVE engine-tour", _cleanup, "DangerButton")
	_clean.visible = false
	ctl.add_child(_clean)
	_player.add_child(ctl)
	# Every step, clickable.
	var sc2 := ScrollContainer.new()
	sc2.custom_minimum_size = Vector2(0, 150)
	sc2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc2.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_player.add_child(sc2)
	_l_steps = hud._rich(18)
	_l_steps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_l_steps.meta_clicked.connect(func(m): _goto_step(int(str(m)), true))
	_l_steps.meta_underlined = false
	sc2.add_child(_l_steps)
	_l_quiz = VBoxContainer.new()
	_l_quiz.add_theme_constant_override("separation", 4)
	_player.add_child(_l_quiz)


func open_lesson(id: String) -> void:
	_lesson = EngineLessons.by_id(id)
	if _lesson.is_empty():
		return
	_live = {}
	_idx = -1
	_l_title.text = "%s · %s" % [EngineLessons.t(EngineLessons.LEVELS[int(_lesson.level)]), EngineLessons.t(_lesson.title)]
	_l_slider.max_value = _lesson.steps.size()   # the last position is the quiz
	_l_live.visible = _lesson.get("live", false)
	_l_live.text = tr("REPLAY THE LAST REAL POD") if K8s.is_prod() else tr("RUN IT FOR REAL")
	for c in _l_quiz.get_children():
		c.queue_free()
	_show_tab("lessons")
	_playing = true
	_goto_step(0, true)


func _close_lesson() -> void:
	_lesson = {}
	_live = {}
	_playing = false
	_show_tab("lessons")


func _toggle_play() -> void:
	_playing = not _playing
	if _playing and _idx >= _lesson.steps.size():
		_goto_step(0, true)
	_t = 0.0
	_refresh_controls()


## Shows step i (and plays its animation when animate).
func _goto_step(i: int, animate: bool) -> void:
	if _lesson.is_empty():
		return
	var n: int = _lesson.steps.size()
	i = clampi(i, 0, n)
	_idx = i
	_t = 0.0
	_l_slider.set_value_no_signal(i)
	if i >= n:
		_playing = false
		_show_quiz()
	else:
		for c in _l_quiz.get_children():
			c.queue_free()
		var st: Dictionary = _lesson.steps[i]
		_l_step.text = "[color=#ffec27]%s %d / %d[/color]\n%s" % [tr("STEP"), i + 1, n, hud._esc(EngineLessons.t(st.text))]
		if animate:
			_animate(i)
	_render_steps()
	_refresh_controls()


func _render_steps() -> void:
	var rows := []
	var n: int = _lesson.steps.size()
	for i in n:
		var col := "#00e436" if i < _idx else ("#ffec27" if i == _idx else "#83769c")
		var txt := EngineLessons.t(_lesson.steps[i].text)
		rows.append("[url=%d][color=%s]%d. %s[/color][/url]" % [i, col, i + 1, hud._esc(txt.left(90) + ("..." if txt.length() > 90 else ""))])
	rows.append("[url=%d][color=%s]%d. %s[/color][/url]" % [n, "#ffec27" if _idx >= n else "#83769c", n + 1, tr("Quiz")])
	_l_steps.text = "\n".join(rows)


func _refresh_controls() -> void:
	_l_play.text = tr("PAUSE") if _playing else tr("PLAY")


## The step's work order, travelling between its machines.
func _animate(i: int) -> void:
	if _lesson.is_empty() or i < 0 or i >= _lesson.steps.size() or _world() == null:
		return
	var st: Dictionary = _lesson.steps[i]
	var hops := []
	for h in st.flow:
		hops.append(_kubelet_for({}) if h == "kubelet" else h)
	_world().engine_flow(hops, str(st.tag), COLORS.get(st.col, Vox.ORANGE))


func _show_quiz() -> void:
	for c in _l_quiz.get_children():
		c.queue_free()
	var q: Dictionary = _lesson.quiz
	_l_step.text = "[color=#ffec27]%s[/color]\n%s" % [tr("QUIZ"), hud._esc(EngineLessons.t(q.q))]
	for k in q.options.size():
		var b: Button = hud._button(EngineLessons.t(q.options[k]), func(): _answer(k))
		b.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_l_quiz.add_child(b)


func _answer(k: int) -> void:
	var q: Dictionary = _lesson.quiz
	var right := k == int(q.answer)
	for c in _l_quiz.get_children():
		c.queue_free()
	if right:
		Settings.lessons_done[_lesson.id] = true
		Settings.save()
		Sfx.play("jingle")
	else:
		Sfx.play("error")
	var res: Label = hud._label((tr("Right! %s") if right else tr("Not quite: %s")) % EngineLessons.t(q.why), 20, Vox.GREEN if right else Vox.RED)
	res.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	res.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_l_quiz.add_child(res)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if not right:
		row.add_child(hud._button("TRY AGAIN", _show_quiz))
	row.add_child(hud._button("REPLAY THE LESSON", func(): _goto_step(0, true)))
	var next := _next_lesson()
	if next != "":
		row.add_child(hud._button("NEXT LESSON", func(): open_lesson(next), "GoButton"))
	_l_quiz.add_child(row)


func _next_lesson() -> String:
	var ids: Array = EngineLessons.LESSONS.map(func(l): return l.id)
	var i := ids.find(_lesson.id)
	return ids[i + 1] if i >= 0 and i + 1 < ids.size() else ""


func _process(delta: float) -> void:
	if _lesson.is_empty() or _world() == null or _world().level != "engine":
		return
	if not _live.is_empty():
		_live_tick(delta)
		return
	if not _playing or _idx >= _lesson.steps.size():
		return
	_t += delta
	if _t >= STEP_SECS:
		_goto_step(_idx + 1, true)


# ------------------------------------------------------------------- feed

func _world() -> World:
	return hud.world


func _on_event(ev: Dictionary) -> void:
	_events.append(ev)
	if _events.size() > 120:
		_events.pop_front()
	if _world() == null or _world().level != "engine":
		return
	if _live.is_empty():
		play(ev)
	if not _live.is_empty() and _live.mode == "live" and str(ev.get("name", "")).begins_with(TOUR_NAME):
		_live_seen(str(ev.get("reason", "")), ev)


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
	_feed = _feed.slice(0, 40)
	_list.text = "\n".join(_feed)


# ------------------------------------------------- the life of a pod, for real

## TEACH ME (old entry point): opens the life-of-a-pod lesson.
func teach() -> void:
	open_lesson("pod-life")


func _run_live() -> void:
	if K8s.is_prod():
		_replay()
		return
	hud.confirm(tr("Create a small Deployment '%s' in namespace '%s' (1 nginx pod) and follow its life through the machines?") % [TOUR_NAME, TOUR_NS], func():
		_live = {"mode": "live", "name": TOUR_NAME, "t": 0.0}
		_playing = false
		_goto_step(0, true)
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
	_live = {"mode": "replay", "queue": q, "name": pod.get_slice("/", 1) if pod != "" else "example-pod", "t": 0.0}
	_say(tr("Replaying the last pod the cluster started (%s): nothing is created on production.") % (pod if pod != "" else tr("none seen yet: an example")))
	_playing = false
	_goto_step(0, true)


## A real event of the tour pod moves the lesson on (and shows the real one).
func _live_seen(reason: String, ev: Dictionary) -> void:
	var st: Dictionary = _lesson.steps[_idx] if _idx < _lesson.steps.size() else {}
	if st.get("reason", "") == reason:
		play(ev)
		_goto_step(_idx + 1, false)


func _live_tick(delta: float) -> void:
	_live.t += delta
	if _idx >= _lesson.steps.size():
		_live = {}
		return
	var wait := 3.0 if _live.mode == "replay" or _idx == 0 else 8.0
	if _live.t < wait:
		return
	_live.t = 0.0
	# The real event didn't come (or this is a replay): play the step.
	var reason: String = _lesson.steps[_idx].get("reason", "")
	for e in _live.get("queue", []):
		if e.get("reason", "") == reason:
			play(e)
			_goto_step(_idx + 1, false)
			return
	_goto_step(_idx + 1, true)
