extends SceneTree

func _init() -> void:
	var pods := []
	for i in 5000:
		pods.append({"ns": "team-%02d" % (i % 100), "name": "app-%d-x7f" % i, "status": "Running", "ready": 1, "total": 1, "ip": "10.244.%d.%d" % [i / 250, i % 250], "node": "node-%d" % (i % 20), "images": ["registry.k8s.io/pause:3.10"], "owner_name": "app"})
	var s := {"pods": pods, "namespaces": [], "nodes": [], "workloads": [], "services": [], "ingresses": []}
	var t1 := Time.get_ticks_usec()
	var idx := ClusterSearch.index(s)
	print("index        %6.1f ms" % ((Time.get_ticks_usec() - t1) / 1000.0))
	for q in ["t", "te", "team-13", "10.244.3", "status:crash", "bad"]:
		var t0 := Time.get_ticks_usec()
		var r := ClusterSearch.find_in(idx, q, 12)
		print("%-12s %6.1f ms  %d hits" % [q, (Time.get_ticks_usec() - t0) / 1000.0, r.size()])
	quit()
