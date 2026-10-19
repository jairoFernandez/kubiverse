extends "res://tests/harness.gd"
## Headless checks of the CONTROL ROOM (the wall of TVs, one per cluster):
##   godot --headless --path game --script res://tests/test_control_room.gd


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame  # control_room.gd and tv_wall.gd use autoloads: load them once they exist
	var CR: GDScript = load("res://scripts/control_room.gd")
	_summaries(CR)
	_levels(CR)
	_alarm_edges(CR)
	_keys(CR)
	await _wall()
	finish("control room tests")


## A full state summed up the way the bridge's /api/summary does it.
func _summaries(CR: GDScript) -> void:
	var s := {"context": "staging", "time": 1700000000,
		"nodes": [{"name": "n1", "ready": true}, {"name": "n2", "ready": false}, {"name": "n3", "ready": true, "conditions": ["DiskPressure"]}],
		"pods": [
			{"ns": "shop", "name": "api-1", "status": "Running", "ready": 1, "total": 1},
			{"ns": "shop", "name": "web-1", "status": "Running", "ready": 0, "total": 1},
			{"ns": "shop", "name": "db-0", "status": "Pending"},
			{"ns": "shop", "name": "cart-1", "status": "CrashLoopBackOff"},
			{"ns": "ads", "name": "img-1", "status": "ImagePullBackOff"},
			{"ns": "jobs", "name": "batch-1", "status": "Completed"},
			{"ns": "jobs", "name": "old-1", "status": "Running", "ready": 1, "total": 1, "deleting": true}],
		"alerts": [{"name": "KubeAPIDown", "severity": "critical"}, {"name": "HighLatency", "severity": "warning"}]}
	var sum: Dictionary = CR.summarize_state(s)
	check(sum.context == "staging" and sum.time == 1700000000, "context and time carried over")
	check(sum.nodes == 3 and sum.nodes_down == 1 and sum.nodes_pressure == 1, "nodes: 3, one down, one under pressure (%s)" % sum)
	check(sum.pods == 5 and sum.pods_bad == 2 and sum.pods_waiting == 2, "pods: finished and leaving ones are not counted (%s)" % sum)
	check(sum.alerts_critical == 1 and sum.alerts_warning == 1, "alerts by severity")
	check(sum.worst == ["node n2 NotReady", "node n3 DiskPressure", "alert KubeAPIDown", "ads/img-1 ImagePullBackOff", "shop/cart-1 CrashLoopBackOff"],
		"worst first, like the bridge: %s" % [sum.worst])
	var empty: Dictionary = CR.summarize_state({})
	check(empty.pods == 0 and empty.worst.is_empty() and CR.level_of(empty) == "ok", "an empty state is a calm, empty summary")
	var many := {"pods": []}
	for i in 20:
		many.pods.append({"ns": "x", "name": "p%d" % i, "status": "Error"})
	check((CR.summarize_state(many).worst as Array).size() == 5, "at most 5 worst lines (what fits on a TV)")


## ok / warn / alarm follow the weather's rules: a storm is an alarm.
func _levels(CR: GDScript) -> void:
	check(CR.level_of({"pods_bad": 0}) == "ok", "nothing wrong: ok")
	check(CR.level_of({"pods_bad": 1}) == "warn", "one bad pod: warn")
	check(CR.level_of({"alerts_warning": 1}) == "warn", "a warning alert: warn")
	check(CR.level_of({"nodes_pressure": 1}) == "warn", "a node under pressure: warn")
	check(CR.level_of({"pods_bad": 8}) == "alarm", "eight bad pods: alarm")
	check(CR.level_of({"nodes_down": 1}) == "alarm", "a node down: alarm")
	check(CR.level_of({"alerts_critical": 1}) == "alarm", "a critical alert: alarm")
	check(CR.rings("alarm") and CR.rings("off"), "alarm and no signal ring")
	check(not CR.rings("warn") and not CR.rings("ok") and not CR.rings("wait"), "warn, ok and tuning don't ring")


## The alarm fires once when a feed goes bad, not on every poll, and an
## acknowledged alarm is forgotten once the cluster calms down.
func _alarm_edges(CR: GDScript) -> void:
	var f := {"level": "wait", "acked": false}
	check(not CR.apply(f, "ok"), "calm: no alarm")
	check(CR.apply(f, "alarm"), "going into alarm rings")
	check(not CR.apply(f, "alarm"), "still in alarm: no second alarm")
	check(not CR.apply(f, "off"), "alarm to no signal: still the same alarm")
	f.acked = true
	CR.apply(f, "alarm")
	check(f.acked, "acknowledged stays acknowledged while it rings")
	CR.apply(f, "warn")
	check(not f.acked, "calmer again: the acknowledgement is forgotten")
	check(CR.apply(f, "off"), "stopping to answer rings again")
	check(CR.apply({"level": ""}, "alarm"), "a first reading in alarm rings")


## A saved cluster is the same feed whatever way its URL was typed.
func _keys(CR: GDScript) -> void:
	check(CR.key_of("localhost:28088/", "prod") == "http://localhost:28088|prod", "bare host and trailing slash normalized")
	check(CR.key_of("http://localhost:28088", "prod") == CR.key_of(" localhost:28088 ", "prod"), "same cluster, same key")
	check(CR.key_of("http://localhost:28088", "a") != CR.key_of("http://localhost:28088", "b"), "contexts of one bridge are different feeds")


## The wall: one TV per feed, in order, an empty hint with none, and the
## screen texts.
func _wall() -> void:
	var CR: GDScript = load("res://scripts/control_room.gd")
	var TW: GDScript = load("res://scripts/tv_wall.gd")
	var room: Node = CR.new()
	root.add_child(room)
	var wall: Control = TW.new()
	root.add_child(wall)
	wall.setup(room)
	room.feeds = [
		{"key": "a", "name": "alpha", "level": "ok", "acked": false, "sum": {}, "err": "", "demo": ""},
		{"key": "b", "name": "beta", "level": "alarm", "acked": false, "sum": {}, "err": "", "demo": ""}]
	room.changed.emit()
	await process_frame
	check(wall.tile_count() == 2, "one TV per cluster")
	check(room.ringing().size() == 1 and room.ringing()[0].name == "beta", "beta rings")
	room.acknowledge()
	check(room.ringing().is_empty(), "SILENCE acknowledges every alarm")
	room.feeds = [room.feeds[1]]
	room.changed.emit()
	await process_frame
	check(wall.tile_count() == 1, "a removed cluster loses its TV")
	room.feeds = []
	room.changed.emit()
	check(wall.tile_count() == 0, "no clusters, no TVs")
	var M = TW.Monitor
	check(M.status_text({"level": "off"}) != "" and M.status_text({"level": "alarm", "acked": true}).contains("ack"), "screen status texts")
	var lines: Array = M.lines({"sum": {"nodes": 3, "nodes_down": 1, "pods": 10, "pods_bad": 2, "pods_waiting": 1,
		"alerts_critical": 1, "alerts_warning": 0, "worst": ["a", "b", "c", "d"]}})
	check(lines.size() == 5 and str(lines[0]).contains("2/3"), "two count lines and three worst ones: %s" % [lines])
	check(M.lines({"sum": {}, "err": "refused"}) == ["refused"], "no summary yet: the error shows")
	wall.queue_free()
	room.queue_free()
