class_name TrafficView
extends PanelContainer
## Live traffic of a Service, the way Kubernetes lets you see it: a Service
## is only a network rule (kube-proxy) and records nothing, so this reads
## the logs of the pods behind it every 2 s and picks out the requests
## (access-log lines: Apache/nginx combined, JSON, or "GET /x 200 12ms").
## Each request travels in the world from the loading dock to the robot
## that served it (green 2xx, yellow 4xx, red 5xx) and is listed here.

const POLL := 2.0
const MAX_PODS := 8
const METHOD := "GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS"

var hud: Node
var svc := {}                 # the Service dict (ns, name, pods...)
var _t := 0.0
var _last := {}               # pod -> last log line seen
var _reqs: Array = []         # newest first: {pod, method, path, status, ms, raw}
var _times: Array = []        # request timestamps, for req/s
var _counts := {"2xx": 0, "3xx": 0, "4xx": 0, "5xx": 0, "other": 0}
var _raw_only := true         # no request line recognised yet
var _title: Label
var _stats: RichTextLabel
var _list: RichTextLabel
var _re_combined := RegEx.create_from_string("\"(%s) (\\S+)[^\"]*\" (\\d{3})" % METHOD)
var _re_plain := RegEx.create_from_string("\\b(%s)\\s+(/\\S*)\\s+(?:HTTP/[\\d.]+\\s+)?(\\d{3})\\b(?:\\s+(\\d+(?:\\.\\d+)?)\\s*ms)?" % METHOD)
var _re_jm := RegEx.create_from_string("\"(?:method|http_method|request_method)\"\\s*:\\s*\"(%s)\"" % METHOD)
var _re_jp := RegEx.create_from_string("\"(?:path|uri|url|request_uri)\"\\s*:\\s*\"([^\"]+)\"")
var _re_js := RegEx.create_from_string("\"(?:status|status_code|statusCode|code)\"\\s*:\\s*\"?(\\d{3})")


func _init(h: Node) -> void:
	hud = h
	visible = false
	add_theme_stylebox_override("panel", h._flat(Color(0.05, 0.08, 0.14, 0.94), Vox.BLUE, 3, 12))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.custom_minimum_size = Vector2(470, 0)
	add_child(v)
	var hh := HBoxContainer.new()
	_title = h._label("", 22, Vox.BLUE)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	hh.add_child(_title)
	hh.add_child(h._button("X", stop))
	v.add_child(hh)
	var note: Label = h._label("A Service records nothing (it is a network rule): this is what its pods log, one line per request.", 18, Vox.LAVENDER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(note)
	_stats = h._rich(20)
	v.add_child(_stats)
	_list = h._rich(19)
	_list.fit_content = false
	_list.custom_minimum_size = Vector2(0, 230)
	_list.scroll_following = false
	v.add_child(_list)


func start(d: Dictionary) -> void:
	svc = d
	_last.clear()
	_reqs.clear()
	_times.clear()
	for k in _counts:
		_counts[k] = 0
	_raw_only = true
	_t = POLL  # first poll right away
	_title.text = tr("TRAFFIC  service %s") % d.name
	visible = true
	_render()


func stop() -> void:
	visible = false
	svc = {}


func active_key() -> String:
	return "%s/%s" % [svc.ns, svc.name] if visible and not svc.is_empty() else ""


func _process(delta: float) -> void:
	if not visible or svc.is_empty():
		return
	_t += delta
	if _t < POLL:
		return
	_t = 0.0
	# The Service's current endpoints (they change as pods come and go).
	for sv in K8s.state.get("services", []):
		if sv.ns == svc.ns and sv.name == svc.name:
			svc = sv
	var names: Array = svc.get("pods", []) if svc.get("pods") != null else []
	if K8s.is_demo():
		_demo_tick(names)
		return
	for pn in names.slice(0, MAX_PODS):
		var ctr := ""
		for p in K8s.state.get("pods", []):
			if p.ns == svc.ns and p.name == pn:
				var cs: Array = p.get("containers", []) if p.get("containers") != null else []
				ctr = str(cs[0]) if not cs.is_empty() else ""
		K8s.fetch_logs(svc.ns, str(pn), ctr, false, func(ok: bool, text: String):
			if ok and visible:
				_ingest(str(pn), text), 40)


## New lines since the last poll of this pod.
func _ingest(pod: String, text: String) -> void:
	var lines := Array(text.strip_edges().split("\n", false))
	var last: String = _last.get(pod, "")
	var start := 0
	if last != "":
		var i := lines.rfind(last)
		start = i + 1 if i >= 0 else 0
	else:
		start = maxi(0, lines.size() - 3)  # first look: only the latest few
	for i in range(start, lines.size()):
		_line(pod, str(lines[i]))
	if not lines.is_empty():
		_last[pod] = lines[-1]
	_render()


func _line(pod: String, raw: String) -> void:
	var r := parse(raw)
	if r.is_empty():
		if _raw_only:
			_reqs.push_front({"pod": pod, "raw": raw.strip_edges().left(90)})
			_reqs = _reqs.slice(0, 14)
		return
	if _raw_only:
		_reqs = _reqs.filter(func(x): return x.has("status"))
		_raw_only = false
	r.pod = pod
	_reqs.push_front(r)
	_reqs = _reqs.slice(0, 14)
	var now := Time.get_ticks_msec() / 1000.0
	_times.append(now)
	var st := int(r.status)
	_counts[_bucket(st)] += 1
	if hud.world:
		hud.world.traffic_packet("%s/%s" % [svc.ns, svc.name], "%s/%s" % [svc.ns, pod], st, "%s %s %d" % [r.method, str(r.path).left(28), st])


## {method, path, status, ms} from an access-log line, or {}.
func parse(line: String) -> Dictionary:
	var m := _re_combined.search(line)
	if m:
		return {"method": m.get_string(1), "path": m.get_string(2), "status": int(m.get_string(3)), "ms": -1.0}
	m = _re_plain.search(line)
	if m:
		return {"method": m.get_string(1), "path": m.get_string(2), "status": int(m.get_string(3)),
			"ms": float(m.get_string(4)) if m.get_string(4) != "" else -1.0}
	var jm := _re_jm.search(line)
	var js := _re_js.search(line)
	if jm and js:
		var jp := _re_jp.search(line)
		return {"method": jm.get_string(1), "path": jp.get_string(1) if jp else "/", "status": int(js.get_string(1)), "ms": -1.0}
	return {}


static func _bucket(st: int) -> String:
	if st >= 200 and st < 300: return "2xx"
	if st >= 300 and st < 400: return "3xx"
	if st >= 400 and st < 500: return "4xx"
	if st >= 500: return "5xx"
	return "other"


static func status_color(st: int) -> Color:
	match _bucket(st):
		"2xx": return Vox.GREEN
		"3xx": return Vox.BLUE
		"4xx": return Vox.YELLOW
		"5xx": return Vox.RED
	return Vox.SILVER


func _render() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_times = _times.filter(func(t): return now - t < 30.0)
	var n: int = (svc.get("pods", []) as Array).size() if svc.get("pods") != null else 0
	var t := tr("%d pods behind it · %.1f req/s (last 30 s)") % [n, _times.size() / 30.0]
	t += "   [color=#00e436]2xx %d[/color]  [color=#29adff]3xx %d[/color]  [color=#ffec27]4xx %d[/color]  [color=#ff004d]5xx %d[/color]" % [
		_counts["2xx"], _counts["3xx"], _counts["4xx"], _counts["5xx"]]
	if n == 0:
		t += "\n[color=#ff004d]%s[/color]" % tr("No ready pods: requests to this Service fail (connection refused / 503).")
	elif _raw_only and not _reqs.is_empty():
		t += "\n[color=#ffec27]%s[/color]" % tr("Its pods don't log requests (no access log): showing their last lines. Enable access logs in the app to see traffic here.")
	elif _reqs.is_empty():
		t += "\n[color=#83769c]%s[/color]" % tr("Waiting for requests... (send some: port-forward it and open it in the browser)")
	_stats.text = t
	var rows := []
	for r in _reqs:
		if not r.has("status"):
			rows.append("[color=#83769c]%s[/color]  %s" % [r.pod.right(12), hud._esc(r.raw)])
			continue
		var col := status_color(int(r.status)).to_html(false)
		var ms := ("  %dms" % int(r.ms)) if float(r.get("ms", -1)) >= 0.0 else ""
		rows.append("[color=#%s]%d[/color]  [color=#fff1e8]%s %s[/color][color=#83769c]%s  <- %s[/color]" % [col, int(r.status), r.method, hud._esc(str(r.path).left(40)), ms, r.pod.right(14)])
	_list.text = "\n".join(rows)


## Demo: the simulated pods don't log requests, so make up plausible ones.
func _demo_tick(names: Array) -> void:
	if names.is_empty():
		_render()
		return
	var paths := ["/", "/api/cart", "/api/products?page=2", "/api/checkout", "/healthz", "/static/app.js", "/api/login", "/favicon.ico"]
	for i in randi_range(0, 3):
		var st: int = [200, 200, 200, 200, 201, 304, 404, 500].pick_random()
		var pod: String = names.pick_random()
		_line(pod, "%s - - \"%s %s HTTP/1.1\" %d %d" % ["10.244.0.1", ["GET", "GET", "POST"].pick_random(), paths.pick_random(), st, randi_range(200, 9000)])
	_render()
