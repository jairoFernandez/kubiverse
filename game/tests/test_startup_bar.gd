extends "res://tests/harness.gd"
## Headless checks of the pod's start-up bar (where the time went until Ready):
##   godot --headless --path game --script res://tests/test_startup_bar.gd


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame  # startup_bar.gd uses autoloads: load it once they exist
	var SB: GDScript = load("res://scripts/startup_bar.gd")
	_phases(SB)
	_tips(SB)
	await _panel(SB)
	finish("startup bar tests")


func _base() -> Dictionary:
	return {"scheduled": 1.0, "initialized": 3.0, "started": 12.0, "ready": 45.0, "pull": 7.5, "pull_bytes": 300000000,
		"restarted": false, "ready_delay": 30, "ready_period": 10, "startup_probe": false, "cpu_limit_m": 200}


## The phases add up to the time to Ready, in order.
func _phases(SB: GDScript) -> void:
	var ph: Array = SB.phases(_base())
	check(ph.map(func(p): return p[0]) == ["sched", "init", "pull", "create", "app"], "every phase, in order: %s" % [ph])
	var total := 0.0
	for p in ph:
		total += p[1]
	check(absf(total - 45.0) < 0.001, "the phases add up to the time to Ready (%s)" % total)
	check(absf(ph[2][1] - 7.5) < 0.001 and absf(ph[3][1] - 1.5) < 0.001, "pull 7.5s, then 1.5s creating")
	var s := _base()
	s.pull = -1.0
	ph = SB.phases(s)
	check(ph.map(func(p): return p[0]) == ["sched", "init", "create", "app"], "no Pulled events: image and create stay together")
	s = _base()
	s.initialized = 1.0
	check(not SB.phases(s).any(func(p): return p[0] == "init"), "no init containers: no init phase")
	s = _base()
	s.ready = -1.0
	check(SB.phases(s).back()[0] == "create", "not Ready yet: the bar stops where the pod is")
	s.started = -1.0
	check(SB.phases(s).back()[0] == "init", "not started yet: stops after init")
	check(SB.phases({"scheduled": -1}).is_empty(), "not scheduled: nothing to draw")


## The tip speaks about the biggest piece.
func _tips(SB: GDScript) -> void:
	check(SB.tip(_base()).contains("initialDelaySeconds: 30"), "33s of app after a 30s initialDelay: the probe delay is the tip")
	var s := _base()
	s.startup_probe = true
	check(SB.tip(s).contains("every 10s"), "with a startupProbe already, the period comes next")
	s.ready_period = 2
	check(SB.tip(s).contains("CPU limit of 200m"), "then a tight CPU limit")
	s.cpu_limit_m = 0
	check(SB.tip(s).contains("lazy init"), "then the app itself")
	s = _base()
	s.pull = 60.0
	s.started = 64.0
	s.ready = 66.0
	check(SB.tip(s).contains("Pulling the image took 60s for 300 MB"), "a long pull: smaller image or pre-pull (%s)" % SB.tip(s))
	s = {"scheduled": 20.0, "initialized": 20.0, "started": 21.0, "ready": 22.0, "pull": 0.0}
	check(SB.tip(s).contains("waiting for a node"), "a long wait for a node")
	s = {"scheduled": 0.2, "initialized": 0.2, "started": 0.9, "ready": 1.5, "pull": 0.0}
	check(SB.tip(s).contains("Fast start"), "a fast start needs no tip")
	s.restarted = true
	check(SB.tip(s).contains("last restart"), "after a restart the tip says the times are from it")
	check(SB.tip({"scheduled": -1}).contains("Not scheduled"), "an unscheduled pod")
	s = {"scheduled": 0.5, "initialized": 0.5, "started": 1.2, "ready": -1, "pull": -1}
	check(SB.tip(s).contains("not Ready"), "running but not Ready is never a fast start")
	s.started = -1
	check(SB.tip(s).contains("Still starting"), "containers not running yet")


## The panel shows and hides with the pod's data.
func _panel(SB: GDScript) -> void:
	var bar: Control = SB.new()
	root.add_child(bar)
	bar.show_startup(_base())
	check(bar.visible and bar._title.text.contains("45.0s"), "title with the time to Ready: %s" % bar._title.text)
	var s := _base()
	s.ready = -1.0
	bar.show_startup(s)
	check(bar._title.text.contains("still starting"), "not Ready yet: still starting")
	bar.show_startup({})
	check(not bar.visible, "no data: hidden")
	bar.show_startup(null)
	check(not bar.visible, "an old bridge without startup: hidden")
	await process_frame
	bar.queue_free()
