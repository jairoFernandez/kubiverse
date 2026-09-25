extends Node
## Autoload "K8s": talks to k8s-bridge over HTTP + WebSocket, or drives the
## offline MockCluster in demo mode. The rest of the game only sees signals.

signal state_updated(state: Dictionary)
signal cluster_event(ev: Dictionary)
signal connection_changed(status: String, detail: String)
signal action_started(req: Dictionary)
signal action_done(ok: bool, message: String, req: Dictionary)
signal watch_updated(data: Dictionary)   # WATCHTOWER: visitors + recent actions
signal cluster_kind_needed               # a cluster seen for the first time: ask prod or sandbox
signal cluster_kind_changed(kind: String)
signal prod_confirm_requested(req: Dictionary)  # a change on a production cluster needs a yes
signal forwards_updated(list: Array)    # port-forwards open on the bridge (with traffic counters)

enum Mode { OFFLINE, BRIDGE, DEMO }

var mode := Mode.OFFLINE
var base_url := ""
var token := ""
var context := ""   # kubeconfig context on the bridge ("" = bridge default)
var state: Dictionary = {}

## What kind of cluster this is, chosen by the player the first time:
## "prod" (look, diagnose, careful changes) or "sandbox" (break things).
## Unknown counts as production until they answer.
var cluster_kind := ""
var _kind_key := ""
## Set while a confirmed change runs, so the production guard lets it through.
var prod_ok := false

## Port-forwards: [{id, kind, ns, name, port, pod, target, local, url,
## bytes_in, bytes_out, conns, total, status, error}]
var forwards: Array = []
var _demo_fw_t := 0.0

var _ws: WebSocketPeer
var _ws_last_state := -1
var _reconnect_in := 0.0
var _mock: MockCluster


func default_bridge_url() -> String:
	var q := web_query_param("bridge")
	if q != "":
		return q
	if OS.has_feature("web"):
		# Served by the bridge itself (localhost or `--lan`): same origin.
		# From a public static host (the GitHub Pages demo) the bridge runs
		# on the player's machine instead.
		var origin = JavaScriptBridge.eval("window.location.origin", true)
		if origin != null and str(origin).begins_with("http") and WebHost.is_local(str(origin)):
			return str(origin)
	return "http://127.0.0.1:8088"


## True when this web page comes from a k8s-bridge (localhost or `--lan`), so
## a bridge is already running. False natively and on a public static host.
func served_by_bridge() -> bool:
	if not OS.has_feature("web"):
		return false
	var origin = JavaScriptBridge.eval("window.location.origin", true)
	return origin != null and WebHost.is_local(str(origin))


const GET_BRIDGE := "https://raw.githubusercontent.com/jairoFernandez/kubiverse/main/bridge/get-bridge"

## One-liners that download the latest k8s-bridge release, check its SHA256
## and run it; on the web they also trust this page's origin. [label, command].
func bridge_install_commands() -> Array:
	var args := ""
	if OS.has_feature("web"):
		var origin = JavaScriptBridge.eval("window.location.origin", true)
		if origin != null and str(origin).begins_with("https://"):
			args = " --allow-origin " + str(origin)
	return [
		["macOS / Linux", "curl -fsSL %s.sh | sh -s --%s" % [GET_BRIDGE, args]],
		["Windows (PowerShell)", "& ([scriptblock]::Create((irm %s.ps1)))%s" % [GET_BRIDGE, args]],
	]


const RELEASE_DOWNLOAD := "https://github.com/jairoFernandez/kubiverse/releases/latest/download/"

## Native builds from the latest release: [label, url, how to run it].
func native_downloads() -> Array:
	return [
		["macOS", RELEASE_DOWNLOAD + "kubiverse-macos.zip",
			"Unzip and move Kubiverse.app to Applications. It is not notarized: the first time, right-click > Open (or System Settings > Privacy & Security > Open Anyway)."],
		["Windows", RELEASE_DOWNLOAD + "kubiverse-windows-x86_64.zip",
			"Unzip and run Kubiverse.exe. If SmartScreen stops it: More info > Run anyway."],
		["Linux", RELEASE_DOWNLOAD + "kubiverse-linux-x86_64.tar.gz",
			"tar xzf kubiverse-linux-x86_64.tar.gz && ./kubiverse.x86_64"],
	]


func web_query_param(name: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var v = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('%s') || ''" % name.c_escape(), true)
	return "" if v == null else str(v)


func connect_bridge(url: String, tok: String, ctx := "") -> void:
	disconnect_all()
	mode = Mode.BRIDGE
	base_url = normalize_url(url)
	token = tok.strip_edges()
	context = ctx.strip_edges()
	_open_ws()


static func normalize_url(url: String) -> String:
	var u := url.strip_edges().trim_suffix("/")
	return u if u.begins_with("http") else "http://" + u


## Query string selecting the context (and token) on the bridge.
func _q(first := true) -> String:
	var parts := []
	if context != "":
		parts.append("context=" + context.uri_encode())
	if token != "":
		parts.append("token=" + token.uri_encode())
	if parts.is_empty():
		return ""
	return ("?" if first else "&") + "&".join(parts)


## Lists the contexts a bridge can serve. cb(ok, data: {default, contexts} or error)
func list_contexts(url: String, tok: String, cb: Callable) -> void:
	_http_to(normalize_url(url), tok, HTTPClient.METHOD_GET, "/api/contexts", "", cb)


## Sends a pasted kubeconfig to the bridge (stored there with 0600). cb(ok, data)
func add_kubeconfig(url: String, tok: String, name: String, content: String, cb: Callable) -> void:
	_http_to(normalize_url(url), tok, HTTPClient.METHOD_POST, "/api/kubeconfig",
		JSON.stringify({"name": name, "content": content}), cb)


## Starts (or reuses) a context on the bridge and reports whether the
## cluster answers. cb(ok, error)
func check_context(url: String, tok: String, ctx: String, cb: Callable) -> void:
	var path := "/api/state?context=%s" % ctx.uri_encode()
	_http_to(normalize_url(url), tok, HTTPClient.METHOD_GET, path, "", func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		elif data.has("error"):
			cb.call(false, str(data.error))
		else:
			cb.call(true, ""), 40.0)


func start_demo() -> void:
	disconnect_all()
	mode = Mode.DEMO
	_mock = MockCluster.new()
	add_child(_mock)
	_mock.state_changed.connect(_on_state)
	_mock.event.connect(func(ev): cluster_event.emit(ev))
	_mock.watch.connect(func(w): watch_updated.emit(w))
	connection_changed.emit("online", "demo cluster (simulated)")
	_mock.start()


func disconnect_all() -> void:
	if _ws:
		_ws.close()
		_ws = null
	if _mock:
		_mock.queue_free()
		_mock = null
	_ws_last_state = -1
	mode = Mode.OFFLINE
	state = {}
	_kind_key = ""
	cluster_kind = ""
	forwards = []
	forwards_updated.emit(forwards)


func is_readonly() -> bool:
	return bool(state.get("readonly", false))


func _open_ws() -> void:
	var ws_url := ("ws" + base_url.substr(4)) + "/api/ws" + _q()
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 24 # snapshots of big clusters can be several MB
	_ws.max_queued_packets = 64
	var err := _ws.connect_to_url(ws_url)
	_ws_last_state = -1
	if err != OK:
		connection_changed.emit("error", "cannot open %s (err %d)" % [ws_url, err])
		_ws = null
		_reconnect_in = 3.0
	else:
		connection_changed.emit("connecting", base_url)


func _process(delta: float) -> void:
	if mode == Mode.DEMO and not forwards.is_empty():
		_demo_traffic(delta)
	if mode != Mode.BRIDGE:
		return
	if _ws == null:
		_reconnect_in -= delta
		if _reconnect_in <= 0.0:
			_open_ws()
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st != _ws_last_state:
		_ws_last_state = st
		match st:
			WebSocketPeer.STATE_OPEN:
				connection_changed.emit("online", base_url)
			WebSocketPeer.STATE_CLOSED:
				var reason := _ws.get_close_reason()
				connection_changed.emit("offline", "bridge unreachable at %s %s — retrying" % [base_url, reason])
	if st == WebSocketPeer.STATE_OPEN:
		while _ws.get_available_packet_count() > 0:
			var txt := _ws.get_packet().get_string_from_utf8()
			var msg = JSON.parse_string(txt)
			if typeof(msg) != TYPE_DICTIONARY:
				continue
			match msg.get("type", ""):
				"state":
					_on_state(msg["data"])
				"event":
					cluster_event.emit(msg["data"])
				"forwards":
					forwards = msg["data"] if msg["data"] != null else []
					forwards_updated.emit(forwards)
				"watch":
					var w: Dictionary = msg["data"]
					for k in ["visitors", "actions"]:
						if w.get(k) == null:
							w[k] = []
					watch_updated.emit(w)
	elif st == WebSocketPeer.STATE_CLOSED:
		_ws = null
		_reconnect_in = 2.0


func _on_state(s: Dictionary) -> void:
	# Go encodes empty slices as null; normalise so callers can iterate.
	for k in ["nodes", "namespaces", "pods", "workloads", "services", "ingresses"]:
		if s.get(k) == null:
			s[k] = []
	state = s
	_resolve_kind()
	state_updated.emit(s)


## Saved choice for this bridge + context; the demo is always a sandbox.
func kind_key() -> String:
	if mode == Mode.DEMO:
		return "demo"
	return "%s|%s" % [base_url, state.get("context", context)]


func _resolve_kind() -> void:
	var key := kind_key()
	if key == _kind_key:
		return
	_kind_key = key
	if mode == Mode.DEMO:
		cluster_kind = "sandbox"
	else:
		cluster_kind = str(Settings.cluster_kinds.get(key, ""))
	cluster_kind_changed.emit(cluster_kind)
	if cluster_kind == "":
		cluster_kind_needed.emit()


func set_cluster_kind(k: String) -> void:
	cluster_kind = k
	if mode != Mode.DEMO:
		Settings.cluster_kinds[kind_key()] = k
		Settings.save()
	cluster_kind_changed.emit(k)


func is_prod() -> bool:
	return cluster_kind != "sandbox"


func is_demo() -> bool:
	return mode == Mode.DEMO


## Performs a mutating action. req = {action, kind?, ns?, name, replicas?, image?}
func action(req: Dictionary) -> void:
	# Production: every change goes through a confirmation that says so.
	if is_prod() and not prod_ok:
		prod_confirm_requested.emit(req)
		return
	action_started.emit(req)
	if mode == Mode.DEMO:
		var res: Dictionary = _mock.action(req)
		action_done.emit(res.ok, res.get("message", res.get("error", "")), req)
		return
	if mode != Mode.BRIDGE:
		action_done.emit(false, "not connected", req)
		return
	_http(HTTPClient.METHOD_POST, "/api/action" + _q(), JSON.stringify(req), func(ok: bool, data):
		if not ok:
			action_done.emit(false, str(data), req)
		else:
			action_done.emit(bool(data.get("ok", false)), str(data.get("message", data.get("error", ""))), req)
	)


## Runs a kubectl command line in the in-game terminal. cb(ok, output)
func run_kubectl(line: String, cb: Callable) -> void:
	if mode == Mode.DEMO:
		var res: Dictionary = _mock.kubectl(line)
		cb.call(res.ok, res.output)
		return
	if mode != Mode.BRIDGE:
		cb.call(false, "not connected")
		return
	_http(HTTPClient.METHOD_POST, "/api/kubectl" + _q(), JSON.stringify({"line": line}), func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		else:
			cb.call(bool(data.get("ok", false)), str(data.get("output", ""))))


## Assistant (Kubi) status: engines, models, catalog, downloads. cb(dict)
func assistant_status(cb: Callable) -> void:
	if mode != Mode.BRIDGE:
		cb.call({"llm": false, "demo": mode == Mode.DEMO})
		return
	_http(HTTPClient.METHOD_GET, "/api/assistant" + _q(), "", func(ok: bool, data):
		cb.call(data if ok else {"llm": false, "why": str(data)}))


## Saves Kubi's settings on the bridge. cb(ok, error)
func assistant_config(cfg: Dictionary, cb: Callable) -> void:
	_http(HTTPClient.METHOD_POST, "/api/assistant/config" + _q(), JSON.stringify(cfg), func(ok: bool, data):
		cb.call(ok and data.get("ok", false), str(data.get("error", "")) if ok else str(data)))


## Starts a download on the bridge: kind = llamacpp | gguf | ollama. cb(ok, error)
func assistant_download(kind: String, id: String, cb: Callable) -> void:
	_http(HTTPClient.METHOD_POST, "/api/assistant/download" + _q(), JSON.stringify({"kind": kind, "id": id}), func(ok: bool, data):
		cb.call(ok and data.get("ok", false), str(data.get("error", "")) if ok else str(data)))


func assistant_delete_model(id: String, cb: Callable) -> void:
	_http(HTTPClient.METHOD_DELETE, "/api/assistant/model?id=%s" % id.uri_encode() + _q(false), "", func(ok: bool, data):
		cb.call(ok and data.get("ok", false), str(data.get("error", "")) if ok else str(data)))


## Asks the bridge's language model. req = {question, kind, ns, name, lang,
## diagnosis}. cb(ok, answer_or_error). Small local models take a while.
func ask_assistant(req: Dictionary, cb: Callable) -> void:
	if mode != Mode.BRIDGE:
		cb.call(false, "no bridge")
		return
	_http_to(base_url, token, HTTPClient.METHOD_POST, "/api/assistant" + _q(), JSON.stringify(req), func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		elif data.get("ok", false):
			cb.call(true, str(data.get("answer", "")))
		else:
			cb.call(false, str(data.get("error", "unknown error"))), 150.0)


## YAML of an object for the in-game editor. cb(ok, yaml_or_error, readonly)
func get_manifest(kind: String, ns: String, name: String, cb: Callable) -> void:
	if mode == Mode.DEMO:
		var r: Dictionary = _mock.manifest(kind, ns, name)
		cb.call(r.ok, r.get("yaml", r.get("error", "")), false)
		return
	var path := "/api/manifest?kind=%s&ns=%s&name=%s" % [kind.uri_encode(), ns.uri_encode(), name.uri_encode()] + _q(false)
	_http(HTTPClient.METHOD_GET, path, "", func(ok: bool, data):
		if not ok:
			cb.call(false, str(data), true)
		else:
			cb.call(bool(data.get("ok", false)), str(data.get("yaml", data.get("error", ""))), bool(data.get("readonly", false))))


## Replaces an object with edited YAML (dry = server-side dry run). cb(ok, message)
func put_manifest(kind: String, ns: String, name: String, yaml: String, dry: bool, cb: Callable) -> void:
	if mode == Mode.DEMO:
		var r: Dictionary = _mock.apply_manifest(kind, ns, name, yaml, dry)
		cb.call(r.ok, r.get("message", "") if r.ok else r.get("error", ""))
		return
	var body := JSON.stringify({"kind": kind, "ns": ns, "name": name, "yaml": yaml, "dry_run": dry})
	_http(HTTPClient.METHOD_POST, "/api/manifest" + _q(), body, func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		else:
			cb.call(bool(data.get("ok", false)), str(data.get("output", data.get("error", "")))))


## Deploys (or removes) the sample scenario the sandbox missions use: broken
## images, pods with no room, crash loops, OOM... cb(ok, message)
func scenario(remove: bool, cb: Callable) -> void:
	if mode != Mode.BRIDGE:
		cb.call(false, "the demo cluster already has it")
		return
	if is_prod():
		cb.call(false, "only on a sandbox cluster")
		return
	_http(HTTPClient.METHOD_POST, "/api/scenario" + _q(), JSON.stringify({"name": "complex", "remove": remove}), func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		else:
			cb.call(bool(data.get("ok", false)), str(data.get("output", data.get("error", "")))))


## Opens a port-forward on the bridge host: 127.0.0.1:<local> -> a pod's port
## or a Service's port. local 0 = the same port (8000+port below 1024).
## cb(ok, forward_or_error)
func port_forward(kind: String, ns: String, name: String, port: int, local := 0, cb := Callable()) -> void:
	var done := func(ok: bool, r):
		if cb.is_valid():
			cb.call(ok, r)
	if mode == Mode.DEMO:
		var f := {"id": str(Time.get_ticks_msec()), "kind": kind, "ns": ns, "name": name, "port": port,
			"pod": name if kind == "pod" else "%s-demo" % name, "target": port, "local": local if local > 0 else (port + 8000 if port < 1024 else port),
			"bytes_in": 0, "bytes_out": 0, "conns": 0, "total": 0, "status": "open", "error": "", "demo": true}
		f.url = "http://127.0.0.1:%d" % f.local
		forwards.append(f)
		forwards_updated.emit(forwards)
		done.call(true, f)
		return
	if mode != Mode.BRIDGE:
		done.call(false, "not connected")
		return
	var body := JSON.stringify({"kind": kind, "ns": ns, "name": name, "port": port, "local_port": local})
	_http(HTTPClient.METHOD_POST, "/api/portforward" + _q(), body, func(ok: bool, data):
		if not ok:
			done.call(false, str(data))
		elif not data.get("ok", false):
			done.call(false, str(data.get("error", "")))
		else:
			done.call(true, data.get("forward", {})))


func close_forward(id: String) -> void:
	if mode == Mode.DEMO:
		forwards = forwards.filter(func(f): return f.id != id)
		forwards_updated.emit(forwards)
		return
	_http(HTTPClient.METHOD_DELETE, "/api/portforward" + _q() + ("&" if _q() != "" else "?") + "id=" + id.uri_encode(), "", func(_ok, _d): pass)


## Demo: fake requests through the tunnels so the packets move.
func _demo_traffic(delta: float) -> void:
	_demo_fw_t += delta
	if _demo_fw_t < 1.0:
		return
	_demo_fw_t = 0.0
	for f in forwards:
		if randf() < 0.6:
			var n := randi_range(1, 4)
			f.total = int(f.total) + n
			f.bytes_out = int(f.bytes_out) + n * randi_range(200, 600)
			f.bytes_in = int(f.bytes_in) + n * randi_range(800, 40000)
		f.conns = randi_range(0, 2)
	forwards_updated.emit(forwards)


## Everything inside a pod (containers, probes, volumes, events). cb(ok, detail_or_error)
func get_pod(ns: String, name: String, cb: Callable) -> void:
	if mode == Mode.DEMO:
		var d: Dictionary = _mock.pod_detail(ns, name)
		cb.call(not d.is_empty(), d if not d.is_empty() else "pod not found")
		return
	if mode != Mode.BRIDGE:
		cb.call(false, "not connected")
		return
	_http(HTTPClient.METHOD_GET, "/api/pod?ns=%s&name=%s" % [ns.uri_encode(), name.uri_encode()] + _q(false), "", func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		elif data.get("ok", false):
			cb.call(true, data.get("pod", {}))
		else:
			cb.call(false, str(data.get("error", ""))))


## cb(ok: bool, text: String)
func fetch_logs(ns: String, pod: String, container: String, previous: bool, cb: Callable, tail := 200) -> void:
	if mode == Mode.DEMO:
		cb.call(true, _mock.logs(ns, pod, container, previous))
		return
	var path := "/api/logs?ns=%s&pod=%s&container=%s&tail=%d%s" % [
		ns.uri_encode(), pod.uri_encode(), container.uri_encode(), tail, "&previous=1" if previous else ""] + _q(false)
	_http(HTTPClient.METHOD_GET, path, "", func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		elif data.get("ok", false):
			cb.call(true, str(data.get("logs", "")))
		else:
			cb.call(false, str(data.get("error", "unknown error")))
	)


func _http(method: int, path: String, body: String, cb: Callable) -> void:
	_http_to(base_url, token, method, path, body, cb)


func _http_to(url: String, tok: String, method: int, path: String, body: String, cb: Callable, timeout := 20.0) -> void:
	var req := HTTPRequest.new()
	req.timeout = timeout
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _headers, raw: PackedByteArray):
		req.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			cb.call(false, "request failed (result %d)" % result)
			return
		var data = JSON.parse_string(raw.get_string_from_utf8())
		if typeof(data) != TYPE_DICTIONARY:
			cb.call(false, "HTTP %d: %s" % [code, raw.get_string_from_utf8().left(200)])
			return
		cb.call(true, data)
	)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if tok != "":
		headers.append("X-Bridge-Token: " + tok)
	var err := req.request(url + path, headers, method, body)
	if err != OK:
		req.queue_free()
		cb.call(false, "cannot send request (err %d)" % err)
