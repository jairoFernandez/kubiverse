class_name LocalBridge
extends Node
## Native builds: the game runs its own kubiverse-bridge, so nobody has to
## start one in a terminal. On launch it looks for a bridge already answering
## (on our port, then on the classic 127.0.0.1:8088 of a hand-started one);
## if there is none it finds the newest binary (PATH, Homebrew, ~/.kubecraft/bin) and
## starts it on 127.0.0.1:<Settings.bridge_port>, then stops it on exit.
## A bridge we didn't start is never stopped.

signal status_changed(status: String, detail: String)

## A port few things use (8088 is a common dev port): below the Linux
## ephemeral range (32768+) so outgoing connections never grab it.
const DEFAULT_PORT := 28088
const CLASSIC_PORT := 8088
const BIN := "kubiverse-bridge"
## At launch the game is busy loading the world, so a health check can time
## out although a bridge answers: it gets a long timeout, and a port that is
## taken is asked again a few times before giving up (never started twice).
const PROBE_TIMEOUT := 4.0
const BUSY_RETRIES := 5

## idle | probing | running (found one) | started (ours) | missing | failed
var status := "idle"
var detail := ""
var url := ""
var pid := -1
var _wait := 0.0
var _probe_left := 0
var _gen := 0           # bumped by start()/stop(): late answers of an older search are ignored


static func valid_port(p: int) -> bool:
	return p >= 1024 and p <= 65535


static func url_for(port: int) -> String:
	return "http://127.0.0.1:%d" % port


## Arguments to start it on 127.0.0.1 only (never on the network).
static func args_for(port: int) -> PackedStringArray:
	return PackedStringArray(["--addr", "127.0.0.1:%d" % port])


## Where the binary may be, in order. Apps opened from the Finder/Dock get a
## bare PATH (/usr/bin:/bin...), so Homebrew's folders are listed too.
static func candidates(path_env: String, home: String, windows: bool) -> PackedStringArray:
	var exe := BIN + (".exe" if windows else "")
	var dirs := PackedStringArray()
	for d in path_env.split(";" if windows else ":", false):
		dirs.append(d)
	if home != "":
		dirs.append(home.path_join(".kubecraft/bin"))
	if not windows:
		dirs.append_array(extra_dirs(home))
	var out := PackedStringArray()
	for d in dirs:
		var p := d.trim_suffix("/").trim_suffix("\\").path_join(exe)
		if not out.has(p):
			out.append(p)
	return out


## Folders the bridge needs on its PATH too: it runs kubectl and the
## kubeconfig's exec plugins (aws, gke-gcloud-auth-plugin, kubelogin...).
static func extra_dirs(home: String) -> PackedStringArray:
	var d := PackedStringArray(["/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin", "/snap/bin"])
	if home != "":
		d.append(home.path_join(".local/bin"))
		d.append(home.path_join("bin"))
		d.append(home.path_join(".krew/bin"))
	return d


## PATH with the extra folders appended (the ones it already has keep their order).
static func widen_path(path_env: String, home: String) -> String:
	var parts := path_env.split(":", false)
	for d in extra_dirs(home):
		if not parts.has(d):
			parts.append(d)
	return ":".join(parts)


## URLs of a hand-started bridge on this machine (what saved clusters used
## before the game ran its own).
static func classic_urls() -> PackedStringArray:
	return PackedStringArray(["http://127.0.0.1:%d" % CLASSIC_PORT, "http://localhost:%d" % CLASSIC_PORT])


## Saved clusters [{name, url, token, context}] that pointed at the classic
## local bridge now point at `to`. Returns a new array; true in [1] if any moved.
static func rehome_servers(servers: Array, to: String) -> Array:
	var out := []
	var moved := false
	for sv in servers:
		var c: Dictionary = sv.duplicate()
		if str(c.get("url", "")).trim_suffix("/") in classic_urls():
			c.url = to
			moved = true
		out.append(c)
	return [out, moved]


## Per-cluster settings keyed "bridge url|context": keys of the classic local
## bridge move to `to` (an entry already under the new key wins).
static func rehome_keys(d: Dictionary, to: String) -> Dictionary:
	var out := {}
	for k in d:
		if not out.has(k):
			out[k] = d[k]
	for k in d:
		var key := str(k)
		for old in classic_urls():
			if key.begins_with(old + "|"):
				var nk := to + key.substr(old.length())
				if not d.has(nk):
					out[nk] = d[k]
				out.erase(k)
	return out


static func home_dir() -> String:
	return OS.get_environment("USERPROFILE" if OS.has_feature("windows") else "HOME")


## The newest of the binaries found, [[path, version], ...] in candidates()
## order: an old copy in ~/.kubecraft/bin must not win over an upgraded
## Homebrew one just because it comes first. Unknown versions lose; ties keep
## the order.
static func pick(found: Array) -> String:
	var best := ""
	var best_v := ""
	for f in found:
		var v := str(f[1])
		if best == "" or (Updates.is_known(v) and (not Updates.is_known(best_v) or Updates.compare(v, best_v) > 0)):
			best = str(f[0])
			best_v = v
	return best


static func find_binary() -> String:
	var found := []
	for p in candidates(OS.get_environment("PATH"), home_dir(), OS.has_feature("windows")):
		if FileAccess.file_exists(p):
			var out := []
			OS.execute(p, ["--version"], out, true)
			found.append([p, str(out[0]).strip_edges() if out.size() > 0 else ""])
	return pick(found)


## Only native desktop builds manage a bridge (the web can't run programs);
## headless runs (tests, CI) never start one.
static func supported() -> bool:
	return not OS.has_feature("web") and not OS.has_feature("mobile") \
		and DisplayServer.get_name() != "headless"


func _set_status(st: String, d := "") -> void:
	status = st
	detail = d
	status_changed.emit(st, d)


func ready_url() -> String:
	return url if status in ["running", "started"] else ""


## What to do after a health check of our port: "use" the bridge there,
## "retry" (something listens: likely a bridge still busy, or the check timed
## out while the game loads), "fail" (the port stays taken by something else)
## or "spawn" ours (nothing listens).
static func after_probe(healthy: bool, port_busy: bool, retries_left: int) -> String:
	if healthy:
		return "use"
	if port_busy:
		return "retry" if retries_left > 0 else "fail"
	return "spawn"


## Finds or starts the bridge on `port`. Safe to call again (port changed).
func start(port: int) -> void:
	if not supported():
		return
	stop()
	if not valid_port(port):
		_set_status("failed", tr("Port %d is not valid (1024-65535).") % port)
		return
	_set_status("probing", url_for(port))
	_find(port, BUSY_RETRIES)


func _find(port: int, retries_left: int) -> void:
	var gen := _gen
	_probe(url_for(port), func(ok: bool): _checked(port, retries_left, gen, ok))


func _checked(port: int, retries_left: int, gen: int, ok: bool) -> void:
	if gen != _gen:
		return  # started again meanwhile (port changed)
	var busy := false
	if not ok:
		busy = await _port_busy(port)
	if gen != _gen:
		return
	var next := after_probe(ok, busy, retries_left)
	if next == "use":
		url = url_for(port)
		_set_status("running", url)
	elif next == "retry":
		await get_tree().create_timer(1.0).timeout
		if gen == _gen:
			_find(port, retries_left - 1)
	elif next == "fail":
		_set_status("failed", tr("Port %d is used by another program: try another port.") % port)
	else:
		_probe(url_for(CLASSIC_PORT), func(ok2: bool):
			if gen != _gen:
				return
			if ok2:
				url = url_for(CLASSIC_PORT)
				_set_status("running", url)
			else:
				_spawn(port))


## True if something accepts connections on 127.0.0.1:port.
func _port_busy(port: int) -> bool:
	var t := StreamPeerTCP.new()
	if t.connect_to_host("127.0.0.1", port) != OK:
		return false
	var until := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < until:
		t.poll()
		var st := t.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			t.disconnect_from_host()
			return true
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			return false
		await get_tree().process_frame
	return false


func _spawn(port: int) -> void:
	var bin := find_binary()
	if bin == "":
		_set_status("missing")
		return
	if not OS.has_feature("windows"):
		OS.set_environment("PATH", widen_path(OS.get_environment("PATH"), home_dir()))
	# It stops by itself if the game dies without stopping it (crash, force quit).
	OS.set_environment("KUBIVERSE_EXIT_WITH_PARENT", "1")
	pid = OS.create_process(bin, args_for(port))
	if pid <= 0:
		pid = -1
		_set_status("failed", tr("Could not start %s") % bin)
		return
	url = url_for(port)
	_set_status("probing", url)
	_probe_left = 40  # ~10 s
	_wait = 0.25


func _process(delta: float) -> void:
	if _probe_left <= 0:
		return
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = 1e9  # one probe in flight
	if pid > 0 and not OS.is_process_running(pid):
		_probe_left = 0
		pid = -1
		# Port taken: often by a bridge the first probe missed (it can time
		# out while the game is still loading). If it answers, use that one.
		_probe(url, func(ok: bool):
			if ok:
				_set_status("running", url)
			else:
				_set_status("failed", tr("The bridge stopped right away: is port %s taken? Try another port.") % url.get_slice(":", 2)))
		return
	_probe(url, func(ok: bool):
		_probe_left -= 1
		if ok:
			_probe_left = 0
			_set_status("started", url)
		elif _probe_left <= 0:
			_set_status("failed", tr("The bridge doesn't answer on %s") % url)
		else:
			_wait = 0.25)


func _probe(u: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = PROBE_TIMEOUT
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h, body: PackedByteArray):
		req.queue_free()
		cb.call(result == HTTPRequest.RESULT_SUCCESS and code == 200 and body.get_string_from_utf8() == "ok"))
	if req.request(u + "/healthz") != OK:
		req.queue_free()
		cb.call(false)


## Stops the bridge only if we started it.
func stop() -> void:
	_gen += 1
	_probe_left = 0
	if pid > 0 and OS.is_process_running(pid):
		# SIGTERM lets it close its port-forwards and llama-server first
		# (OS.kill is a SIGKILL on Unix).
		if OS.has_feature("windows") or OS.execute("kill", [str(pid)]) != 0:
			OS.kill(pid)
	pid = -1
	url = ""
	status = "idle"


func _notification(what: int) -> void:
	if what in [NOTIFICATION_EXIT_TREE, NOTIFICATION_PREDELETE, NOTIFICATION_WM_CLOSE_REQUEST]:
		stop()
