extends SceneTree
## Dev: godot --headless --path game --script res://tests/bench_world.gd -- /path/state.json

var _ran := false


func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return true


func _run() -> void:
	var path: String = OS.get_cmdline_user_args()[0]
	var s: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	for k in ["nodes", "namespaces", "pods", "workloads", "services", "ingresses"]:
		if s.get(k) == null:
			s[k] = []
	print("pods ", s.pods.size())
	var world := World.new()
	root.add_child(world)
	world.set_level("power")
	for lv in ["plant", "power", "ns:team-13"]:
		world.set_level(lv)
		var t0 := Time.get_ticks_usec()
		world.apply_state(s)
		var t1 := Time.get_ticks_usec()
		world.apply_state(s)
		var t2 := Time.get_ticks_usec()
		print("%-12s first %6.1f ms   again %6.1f ms   entities %d" % [lv, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, world.pods.size()])
		var t4 := Time.get_ticks_usec()
		var l := world.labels(Vector3.ZERO)
		print("             labels %6.1f ms (%d)" % [(Time.get_ticks_usec() - t4) / 1000.0, l.size()])
	var t6 := Time.get_ticks_usec()
	var probs := Diagnose.problems(s)
	print("diagnose     %6.1f ms (%d problems)" % [(Time.get_ticks_usec() - t6) / 1000.0, probs.size()])
	var t7 := Time.get_ticks_usec()
	for p in s.pods:
		PodBot.categorize(p)
	print("categorize   %6.1f ms" % ((Time.get_ticks_usec() - t7) / 1000.0))
	var t5 := Time.get_ticks_usec()
	var idx := ClusterSearch.index(s)
	print("search index %6.1f ms" % ((Time.get_ticks_usec() - t5) / 1000.0))
	quit()
