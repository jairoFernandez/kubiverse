extends Node
## Autoload "K8s": talks to k8s-bridge over HTTP + WebSocket, or drives the
## offline MockCluster in demo mode. The rest of the game only sees signals.

signal state_updated(state: Dictionary)
signal cluster_event(ev: Dictionary)
signal connection_changed(status: String, detail: String)
signal action_started(req: Dictionary)
signal action_done(ok: bool, message: String, req: Dictionary)
signal watch_updated(data: Dictionary)   # WATCHTOWER: visitors + recent actions

enum Mode { OFFLINE, BRIDGE, DEMO }

var mode := Mode.OFFLINE
var base_url := ""
var token := ""
var context := ""   # kubeconfig context on the bridge ("" = bridge default)
var state: Dictionary = {}

var _ws: WebSocketPeer
var _ws_last_state := -1
var _reconnect_in := 0.0
var _mock: MockCluster


func default_bridge_url() -> String:
	var q := web_query_param("bridge")
	if q != "":
		return q
	if OS.has_feature("web"):
		var origin = JavaScriptBridge.eval("window.location.origin", true)
		if origin != null and str(origin).begins_with("http"):
			return str(origin)
	return "http://127.0.0.1:8088"


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
	for k in ["nodes", "namespaces", "pods", "workloads", "services"]:
		if s.get(k) == null:
			s[k] = []
	state = s
	state_updated.emit(s)


## Performs a mutating action. req = {action, kind?, ns?, name, replicas?, image?}
func action(req: Dictionary) -> void:
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


## cb(ok: bool, text: String)
func fetch_logs(ns: String, pod: String, container: String, previous: bool, cb: Callable) -> void:
	if mode == Mode.DEMO:
		cb.call(true, _mock.logs(ns, pod, container, previous))
		return
	var path := "/api/logs?ns=%s&pod=%s&container=%s&tail=200%s" % [
		ns.uri_encode(), pod.uri_encode(), container.uri_encode(), "&previous=1" if previous else ""] + _q(false)
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
