class_name ControlRoom
extends Node
## Watches every saved cluster at once, for the CONTROL ROOM's wall of TVs.
## Each cluster is a "feed": its bridge is asked for a small summary
## (/api/summary) every POLL seconds; the cluster being played comes straight
## from the live state. When a feed goes into alarm, `alarm` fires (the HUD
## sounds the siren and shows the badge) until someone acknowledges it.
## In demo mode the other demo scenarios run here too, as extra feeds.

signal changed
signal alarm(feed: Dictionary)

const POLL := 20.0          # seconds between summaries of each cluster
const FAILS_FOR_OFF := 2    # failed polls in a row before a feed shows NO SIGNAL
const SIREN_EVERY := 4.0    # seconds between siren blasts while an alarm is not acknowledged
const DEMO_FEEDS := ["starter", "shop", "incident"]   # "big" is too heavy to run beside the world

## Feeds: [{key, name, url, token, context, demo, sum, level, err, fails, at, acked, live}]
var feeds: Array = []
var watching := false       # the wall is open or Settings.watch_clusters is on
var _t := 0.0
var _siren_t := 0.0
var _busy := {}             # feed key -> true while its request is out
var _mocks := {}            # demo scenario -> MockCluster
var _mock_state := {}       # demo scenario -> its last state


# ------------------------------------------------------------ pure helpers

## The same few numbers the bridge's /api/summary gives, from a full state
## (the cluster being played, demo clusters, or a bridge too old to have it).
static func summarize_state(s: Dictionary) -> Dictionary:
	var out := {"context": str(s.get("context", "")), "time": int(s.get("time", 0)),
		"nodes": 0, "nodes_down": 0, "nodes_pressure": 0, "pods": 0, "pods_bad": 0,
		"pods_waiting": 0, "alerts_critical": 0, "alerts_warning": 0, "worst": []}
	var down := []
	var crit := []
	var bad := []
	for n in s.get("nodes", []):
		out.nodes += 1
		var cond: Array = n.get("conditions", []) if n.get("conditions") != null else []
		if not n.get("ready", true):
			out.nodes_down += 1
			down.append("node %s NotReady" % n.get("name", "?"))
		elif not cond.is_empty():
			out.nodes_pressure += 1
			down.append("node %s %s" % [n.get("name", "?"), cond[0]])
	for a in s.get("alerts", []):
		match str(a.get("severity", "")):
			"critical":
				out.alerts_critical += 1
				crit.append("alert " + str(a.get("name", "?")))
			"warning":
				out.alerts_warning += 1
	for p in s.get("pods", []):
		match PodBot.categorize(p):
			"done", "term":
				continue
			"crash", "pull", "failed":
				out.pods_bad += 1
				bad.append("%s/%s %s" % [p.get("ns", ""), p.get("name", ""), p.get("status", "")])
			"pending", "warn":
				out.pods_waiting += 1
		out.pods += 1
	bad.sort()
	for l in [down, crit, bad]:
		for line in l:
			if out.worst.size() < 5:
				out.worst.append(line)
	return out


## How a summary looks on the wall: ok, warn or alarm (the weather's rules:
## a storm is an alarm).
static func level_of(sum: Dictionary) -> String:
	if int(sum.get("nodes_down", 0)) > 0 or int(sum.get("alerts_critical", 0)) > 0 or int(sum.get("pods_bad", 0)) >= 8:
		return "alarm"
	if int(sum.get("pods_bad", 0)) > 0 or int(sum.get("alerts_warning", 0)) > 0 or int(sum.get("nodes_pressure", 0)) > 0:
		return "warn"
	return "ok"


## Levels that ring: a cluster in alarm, or one that stopped answering.
static func rings(level: String) -> bool:
	return level == "alarm" or level == "off"


static func key_of(url: String, context: String) -> String:
	var u := url.strip_edges().trim_suffix("/")   # as K8s.normalize_url
	return (u if u.begins_with("http") else "http://" + u) + "|" + context


## Puts a new reading on a feed. Returns true when it just started ringing
## (and an acknowledged alarm is forgotten once the feed calms down).
static func apply(feed: Dictionary, level: String) -> bool:
	var was: String = feed.get("level", "")
	feed.level = level
	if not rings(level):
		feed.acked = false
		return false
	return not rings(was)


# ------------------------------------------------------------ feeds

## Rebuilds the feed list from the saved clusters (and the demo scenarios),
## keeping what each feed already knew.
func sync_feeds() -> void:
	var old := {}
	for f in feeds:
		old[f.key] = f
	var out := []
	for sv in Settings.servers:
		var k := key_of(sv.url, sv.get("context", ""))
		var f: Dictionary = old.get(k, {"key": k, "sum": {}, "level": "wait", "err": "", "fails": 0, "at": 0, "acked": false})
		f.name = sv.name
		f.url = sv.url
		f.token = sv.get("token", "")
		f.context = sv.get("context", "")
		f.demo = ""
		out.append(f)
	if K8s.is_demo():
		for sc in DEMO_FEEDS:
			var k: String = "demo|" + sc
			var f: Dictionary = old.get(k, {"key": k, "sum": {}, "level": "wait", "err": "", "fails": 0, "at": 0, "acked": false})
			f.name = "demo: " + sc
			f.demo = sc
			out.append(f)
	feeds = out
	if out.any(func(f): return not old.has(f.key)):
		_t = 0.0   # a new cluster on the wall: look at it now, not in POLL seconds
	_sync_mocks()
	changed.emit()


## Is this feed the cluster on screen right now?
func is_live(f: Dictionary) -> bool:
	if f.get("demo", "") != "":
		return K8s.is_demo() and K8s.demo_scenario() == f.demo
	return K8s.mode == K8s.Mode.BRIDGE and key_of(K8s.base_url, K8s.context) == f.key


func ringing() -> Array:
	return feeds.filter(func(f): return rings(f.level) and not f.acked)


func acknowledge() -> void:
	for f in feeds:
		if rings(f.level):
			f.acked = true
	changed.emit()


func set_watching(on: bool) -> void:
	if on and not watching:
		_t = 0.0   # look right away
	watching = on
	_sync_mocks()


func _process(delta: float) -> void:
	if not watching:
		return
	_t -= delta
	if _t <= 0.0:
		_t = POLL
		poll_all()
	if not ringing().is_empty():
		_siren_t -= delta
		if _siren_t <= 0.0:
			_siren_t = SIREN_EVERY
			Sfx.play("alarm", null, 0.0)
	else:
		_siren_t = 0.0


func poll_all() -> void:
	for f in feeds:
		if is_live(f):
			if not K8s.state.is_empty():
				_read(f, summarize_state(K8s.state))
		elif f.demo != "":
			if _mock_state.has(f.demo):
				_read(f, summarize_state(_mock_state[f.demo]))
		elif not _busy.get(f.key, false):
			_busy[f.key] = true
			K8s.fetch_summary(f.url, f.token, f.context, func(ok: bool, data):
				_busy.erase(f.key)
				if ok:
					_read(f, data)
				else:
					_fail(f, str(data)))
	changed.emit()


func _read(f: Dictionary, sum: Dictionary) -> void:
	f.sum = sum
	f.err = ""
	f.fails = 0
	f.at = Time.get_unix_time_from_system()
	if apply(f, level_of(sum)):
		alarm.emit(f)
	changed.emit()


func _fail(f: Dictionary, why: String) -> void:
	f.err = why
	f.fails = int(f.fails) + 1
	if why.begins_with("loading"):
		f.level = "wait"
	elif f.fails >= FAILS_FOR_OFF and apply(f, "off"):
		alarm.emit(f)
	changed.emit()


## Demo feeds run their own little simulated clusters, only while watched.
func _sync_mocks() -> void:
	var want := {}
	if watching and K8s.is_demo():
		for f in feeds:
			if f.get("demo", "") != "" and not is_live(f):
				want[f.demo] = true
	for sc in _mocks.keys():
		if not want.has(sc):
			_mocks[sc].queue_free()
			_mocks.erase(sc)
			_mock_state.erase(sc)
	for sc in want:
		if not _mocks.has(sc):
			var m := MockCluster.new()
			m.scenario = sc
			add_child(m)
			m.state_changed.connect(func(s): _mock_state[sc] = s)
			m.start()
			_mocks[sc] = m
