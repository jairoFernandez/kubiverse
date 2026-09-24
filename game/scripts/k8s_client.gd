extends Node
## Autoload "K8s": talks to k8s-bridge over HTTP + WebSocket, or drives the
## offline MockCluster in demo mode. The rest of the game only sees signals.

signal state_updated(state: Dictionary)
signal cluster_event(ev: Dictionary)
signal connection_changed(status: String, detail: String)
signal action_started(req: Dictionary)
signal action_done(ok: bool, message: String, req: Dictionary)

enum Mode { OFFLINE, BRIDGE, DEMO }

var mode := Mode.OFFLINE
var base_url := ""
var token := ""
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


func connect_bridge(url: String, tok: String) -> void:
	disconnect_all()
	mode = Mode.BRIDGE
	base_url = url.strip_edges().trim_suffix("/")
	if not base_url.begins_with("http"):
		base_url = "http://" + base_url
	token = tok.strip_edges()
	_open_ws()


func start_demo() -> void:
	disconnect_all()
	mode = Mode.DEMO
	_mock = MockCluster.new()
	add_child(_mock)
	_mock.state_changed.connect(_on_state)
	_mock.event.connect(func(ev): cluster_event.emit(ev))
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
	var ws_url := ("ws" + base_url.substr(4)) + "/api/ws"
	if token != "":
		ws_url += "?token=" + token.uri_encode()
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
	_http(HTTPClient.METHOD_POST, "/api/action", JSON.stringify(req), func(ok: bool, data):
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
	_http(HTTPClient.METHOD_POST, "/api/kubectl", JSON.stringify({"line": line}), func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		else:
			cb.call(bool(data.get("ok", false)), str(data.get("output", ""))))


## cb(ok: bool, text: String)
func fetch_logs(ns: String, pod: String, container: String, previous: bool, cb: Callable) -> void:
	if mode == Mode.DEMO:
		cb.call(true, _mock.logs(ns, pod, container, previous))
		return
	var path := "/api/logs?ns=%s&pod=%s&container=%s&tail=200%s" % [
		ns.uri_encode(), pod.uri_encode(), container.uri_encode(), "&previous=1" if previous else ""]
	_http(HTTPClient.METHOD_GET, path, "", func(ok: bool, data):
		if not ok:
			cb.call(false, str(data))
		elif data.get("ok", false):
			cb.call(true, str(data.get("logs", "")))
		else:
			cb.call(false, str(data.get("error", "unknown error")))
	)


func _http(method: int, path: String, body: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 20.0
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
	if token != "":
		headers.append("X-Bridge-Token: " + token)
	var err := req.request(base_url + path, headers, method, body)
	if err != OK:
		req.queue_free()
		cb.call(false, "cannot send request (err %d)" % err)
