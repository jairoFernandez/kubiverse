extends SceneTree
## Headless checks: godot --headless --path game --script res://tests/test_world.gd

func _init() -> void:
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
