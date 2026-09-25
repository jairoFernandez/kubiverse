extends SceneTree
## Headless checks: godot --headless --path game --script res://tests/test_world.gd

func _init() -> void:
	# Kubi runs only reading commands on its own.
	for c in ["kubectl -n ml describe pod x", "kubectl get pods -A", "kubectl --namespace shop logs web --previous", "top nodes"]:
		assert(Diagnose.is_read_only(c), c)
	for c in ["kubectl -n ml delete pod x", "kubectl -n get delete pod x", "kubectl rollout restart deploy/a", "kubectl -n shop set image deploy/a a=b"]:
		assert(not Diagnose.is_read_only(c), c)
	# Web build: same-origin bridge only on local hosts, not on a public static host.
	for o in ["http://127.0.0.1:8088", "http://localhost:8088", "https://192.168.1.20:8088", "https://10.0.0.5:8088", "http://[::1]:8088", "http://mac.local:8088"]:
		assert(WebHost.is_local(o), o)
	for o in ["https://jairo.github.io", "https://kubiverse.dev", "https://172.32.0.1", "https://8.8.8.8"]:
		assert(not WebHost.is_local(o), o)
	# The way down to the Underground: ↑ ↑ ↓ ↓ ← → S T A R T (↑ ↑ ↑ still counts).
	var sc := SecretCode.new()
	var hits := 0
	for k in [KEY_UP, KEY_UP, KEY_UP, KEY_DOWN, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_S, KEY_T, KEY_A, KEY_R, KEY_T]:
		if sc.feed(SecretCode.token(k)):
			hits += 1
	assert(hits == 1, "secret code")
	for k in [KEY_UP, KEY_UP, KEY_DOWN, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_S, KEY_T]:
		sc.feed(SecretCode.token(k))
	assert(sc.armed() and sc.typed() == "ST", sc.typed())
	assert(not sc.feed(SecretCode.token(KEY_X)) and sc.pos == 0, "a wrong letter resets it")
	# Global search: words, filters and "bad"; an ingress host goes to its service.
	var cs_state := {"namespaces": [{"name": "shop"}, {"name": "payments"}],
		"nodes": [{"name": "worker-a", "ready": true, "roles": []}],
		"pods": [{"ns": "shop", "name": "api-1", "status": "Running", "ready": 1, "total": 1, "ip": "10.244.1.7", "node": "worker-a", "images": ["shop/api:2"]},
			{"ns": "payments", "name": "ledger-1", "status": "CrashLoopBackOff", "ready": 0, "total": 1, "ip": "10.244.2.9", "node": "worker-a", "images": ["redis:7"]}],
		"workloads": [], "services": [{"ns": "shop", "name": "api", "type": "ClusterIP", "cluster_ip": "10.96.0.12", "ports": ["80/TCP"], "ready": 1, "selector": {"app": "api"}}],
		"ingresses": [{"ns": "shop", "name": "web", "rules": [{"host": "shop.example.com", "path": "/", "service": "api", "port": "80"}]}]}
	var found := ClusterSearch.find(cs_state, "api")
	assert(found.size() >= 2 and found[0].title == "shop/api" and found[0].kind == "service", str(found))
	assert(ClusterSearch.find(cs_state, "10.244.2")[0].key == "payments/ledger-1", "by IP")
	assert(ClusterSearch.find(cs_state, "bad").size() == 1, "only what's broken")
	assert(ClusterSearch.find(cs_state, "image:redis kind:pod").size() == 1, "filters")
	var host: Dictionary = ClusterSearch.find(cs_state, "shop.example")[0]
	assert(host.kind == "service" and host.key == "shop/api", "host -> its service")
	assert(ClusterSearch.find(cs_state, "ns:shop nothing-here").is_empty(), "all words must match")
	# History: memory that climbs and stays up has a "since"; flat noise has none; restarts too.
	var climb := []
	var flat := []
	var rst := []
	for i in 60:
		climb.append([i * 60.0, 100.0 if i < 40 else 100.0 + (i - 40) * 30.0])
		flat.append([i * 60.0, 100.0 + (i % 3)])
		rst.append([i * 60.0, 0.0 if i < 50 else float(i - 49)])
	assert(TrendChart.change_since(climb, "bytes") >= 40 * 60.0, "memory since")
	assert(TrendChart.change_since(flat, "bytes") == 0.0, "noise is not a change")
	assert(TrendChart.change_since(rst, "count") == 50 * 60.0, "restarts since")
	# An alert becomes a Kubi mission that ends when the alert stops firing.
	var ast := {"pods": [], "nodes": [], "services": [], "ingresses": [], "workloads": [{"ns": "ml", "kind": "Deployment", "name": "trainer", "desired": 1, "ready": 1}],
		"alerts": [{"id": "a1", "name": "ContainerMemoryNearLimit", "severity": "warning", "ns": "ml", "workload": "Deployment/trainer", "summary": "leak", "source": "alertmanager"}]}
	var am: Array = KubiMissions.generate(ast).filter(func(m): return str(m.id).begins_with("k:alert:"))
	assert(am.size() == 1, "alert mission")
	var last: Dictionary = am[0].steps[am[0].steps.size() - 1]
	assert(not KubiMissions.check(last, "state", null, null, ast, {}), "still firing")
	ast.alerts = []
	assert(KubiMissions.check(last, "state", null, null, ast, {}), "alert gone")
	# Search finds PVCs (to their tank), Argo CD apps and certificates (to their namespace).
	var rs := {"volumes": [{"ns": "ml", "name": "datasets", "status": "Pending", "class": "fast-ssd", "request": "500Gi", "pods": []}],
		"apps": [{"ns": "argocd", "name": "payments", "dest_ns": "payments", "sync": "OutOfSync", "health": "Degraded"}],
		"certs": [{"ns": "shop", "name": "shop-tls", "dns": ["shop.example.com"], "ready": true}]}
	var hv: Dictionary = ClusterSearch.find(rs, "datasets")[0]
	assert(hv.kind == "volume" and hv.key == "ml/datasets" and hv.bad, str(hv))
	assert(ClusterSearch.find(rs, "kind:app")[0].key == "payments", "app -> its namespace")
	assert(ClusterSearch.find(rs, "shop.example.com")[0].kind == "namespace", "cert -> namespace")
	# Secrets and PVs are searchable; a missing Secret is "bad".
	var cs2 := {"configs": [{"kind": "Secret", "ns": "payments", "name": "stripe-key", "exists": "no", "pods": ["fraud-1"], "keys": []}],
		"pvs": [{"name": "pvc-old", "status": "Released", "claim": "data/reports", "capacity": "50Gi"}]}
	var hc: Dictionary = ClusterSearch.find(cs2, "kind:secret")[0]
	assert(hc.kind == "config" and hc.key == "Secret/payments/stripe-key" and hc.bad, str(hc))
	assert(ClusterSearch.find(cs2, "reports")[0].kind == "pv", "pv by its old claim")
	# Kubi's dynamic missions: a hot node gives a bottleneck mission with the
	# biggest pod named, and its VERIFY step passes once the node cools down.
	var hs := {"nodes": [{"name": "n1", "cpu_m": 1000, "mem_bytes": 1 << 30}, {"name": "n2", "cpu_m": 1000, "mem_bytes": 1 << 30}],
		"pods": [{"ns": "shop", "name": "api-1", "node": "n1", "status": "Running", "phase": "Running", "ready": 1, "total": 1, "cpu_req_m": 900, "mem_req": 0, "owner_kind": "Deployment", "owner_name": "api"},
			{"ns": "shop", "name": "web-1", "node": "n2", "status": "Running", "phase": "Running", "ready": 1, "total": 1, "cpu_req_m": 100, "mem_req": 0, "owner_kind": "Deployment", "owner_name": "web"}],
		"workloads": [{"ns": "shop", "kind": "Deployment", "name": "api", "desired": 2, "ready": 2}, {"ns": "shop", "kind": "Deployment", "name": "web", "desired": 2, "ready": 2}],
		"services": [], "ingresses": []}
	var gen := KubiMissions.generate(hs)
	var hot: Array = gen.filter(func(m): return m.id == "k:hot:n1")
	assert(hot.size() == 1, "hot node mission")
	assert(str(hot[0].steps[1].text[1]).contains("api-1"), "names the biggest pod")
	assert(not KubiMissions.check(hot[0].steps[-1], "state", null, null, hs, {}), "still hot")
	hs.pods[0].cpu_req_m = 300
	assert(KubiMissions.check(hot[0].steps[-1], "state", null, null, hs, {}), "cooled down")
	await process_frame
	var fails := 0
	var mock := MockCluster.new()
	root.add_child(mock)
	var box := {}
	mock.state_changed.connect(func(s): box["s"] = s)
	mock.start()
	var st: Dictionary = box["s"]
	var world := World.new()
	root.add_child(world)
	world.state = st
	for level in ["plant", "ns:shop", "power"]:
		world.set_level(level)
		if not world.can_stand(world.spawn):
			print("FAIL %s: spawn not standable" % level); fails += 1
		if world.can_stand(Vector3(500, 0, 500)):
			print("FAIL %s: void is standable" % level); fails += 1
		if world.doors.is_empty():
			print("FAIL %s: no doors" % level); fails += 1
		# Walking straight into the void must stop at the edge.
		var p := world.spawn
		for i in 2000:
			p = world.move_player(p, Vector3(0.05, 0, 0.05))
		if not world.void_level and not world.can_stand(p):
			print("FAIL %s: walked off the map to %s" % [level, p]); fails += 1
	world.set_level("plant")
	var b: FactoryBuilding = world.buildings.get("shop")
	if b == null or world.can_stand(b.target):
		print("  shop=%s" % b)
		print("FAIL: can walk inside the shop hall"); fails += 1
	if world.buildings.size() != st.namespaces.size() + 1:
		print("FAIL: expected a hall per namespace (+power), got %d" % world.buildings.size()); fails += 1
	world.set_level("ns:shop")
	var line: ProductionLine = world.lines.values()[0]
	if world.can_stand(line.target + Vector3(4, 0, 0)):
		print("FAIL: can walk through a conveyor"); fails += 1
	# Energy room, easy mode (default): every surface touches another one
	# whose height is within a normal step, i.e. you can WALK everywhere.
	world.challenge = false
	world.set_level("plant")
	world.set_level("power")
	for i in range(1, world.walk_rects.size()):
		var ok := false
		for j in world.walk_rects.size():
			if j != i and world.walk_rects[i].grow(0.05).intersects(world.walk_rects[j]) \
					and absf(world.walk_heights[i] - world.walk_heights[j]) <= world.STEP:
				ok = true
				break
		if not ok:
			print("FAIL power/easy: surface %d at y=%.2f needs a jump" % [i, world.walk_heights[i]]); fails += 1
	fails += _walk_all(world, "1 control-plane")
	# Several control-planes: an etcd plaza in the centre with castles around.
	mock.action({"action": "add_control_plane"})
	mock.action({"action": "add_control_plane"})
	mock._emit()
	world.state = box["s"]
	world.set_level("plant")
	world.set_level("power")
	if world.etcd_members.size() != 3:
		print("FAIL power/ha: expected 3 etcd members, got %d" % world.etcd_members.size()); fails += 1
	fails += _walk_all(world, "3 control-planes")
	# Challenge mode: every surface is reachable with the player's jump.
	world.challenge = true
	world.set_level("plant")
	world.set_level("power")
	# Must match Player.JUMP_SPEED / GRAVITY / WALK_SPEED (player.gd needs
	# autoloads, which --script mode does not load).
	var jump_h := 8.6 * 8.6 / (2.0 * 24.0)
	var air := 2.0 * 8.6 / 24.0
	var max_gap := 5.5 * air * 0.9
	for i in range(1, world.walk_rects.size()):
		var r: Rect2 = world.walk_rects[i]
		var y: float = world.walk_heights[i]
		var ok := false
		for j in world.walk_rects.size():
			if j == i:
				continue
			var o: Rect2 = world.walk_rects[j]
			var gap := maxf(0.0, maxf(o.position.x - r.end.x, r.position.x - o.end.x))
			var gapz := maxf(0.0, maxf(o.position.y - r.end.y, r.position.y - o.end.y))
			if Vector2(gap, gapz).length() <= max_gap and y - world.walk_heights[j] <= jump_h - 0.15:
				ok = true
				break
		if not ok:
			print("FAIL power/challenge: surface %d at y=%.1f is unreachable" % [i, y]); fails += 1
	if world.coins.is_empty():
		print("FAIL power/challenge: no coins"); fails += 1
	print("world tests: %s" % ("OK" if fails == 0 else "%d FAILED" % fails))
	quit(fails)



## Walks from the centre (edge of the central platform) to every island
## without jumping, like the player: returns the number of failures.
func _walk_all(world: World, label: String) -> int:
	var fails := 0
	var centre: Rect2 = world.walk_rects[0]
	for isl in world.islands.values():
		var t: Vector3 = isl.target
		if Vector2(t.x, t.z).length() < 0.5:
			continue
		var dir := Vector3(t.x, 0, t.z).normalized()
		var p: Vector3 = dir * (minf(centre.size.x, centre.size.y) * 0.5 - 1.0)
		var feet := 0.0
		var reached := false
		for step in 4000:
			var to: Vector3 = t - p
			to.y = 0
			if to.length() < 0.5:
				break
			var np: Vector3 = world.move_player(p, to.normalized() * 0.08, feet)
			var g: float = world.ground_below(Vector2(np.x, np.z), feet + world.STEP)
			if g == -INF:
				print("FAIL %s: fell walking to %s at %s" % [label, isl.key, np]); fails += 1
				break
			p = np
			feet = g
			if isl.contains_xz(p) and absf(feet - t.y) < 0.05:
				reached = true
				break
		if not reached and fails == 0:
			print("FAIL %s: could not walk onto %s (stuck at %s)" % [label, isl.key, p]); fails += 1
	return fails
