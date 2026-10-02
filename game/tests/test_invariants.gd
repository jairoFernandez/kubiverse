extends "res://tests/harness.gd"
## Invariants of the world, for EVERY demo scenario and EVERY level reachable
## in it, whatever the other tests expect of one particular case:
##   godot --headless --path game --script res://tests/test_invariants.gd
##
## - the spawn is standable, every door leads to a level that exists, every
##   level has a way out;
## - every entity is alive and in the tree, entity keys are unique per kind,
##   and the world shows nothing the cluster doesn't have;
## - every label has text and a finite position;
## - halls and landmarks on the plant don't overlap;
## - apply_state with the same state is a no-op (same entities, no new
##   building sites, nothing demolished);
## - all of the above still holds while the cluster churns (pods deleted,
##   workloads scaled and restarted through MockCluster.action).

const SCENARIOS := ["starter", "shop", "incident", "big"]
const FIXED_LEVELS := ["plant", "power", "engine", "library", "bank"]
const CHURN_TICKS := 40

var _level_count := 0


func _init() -> void:
	seed(20261002)
	await process_frame   # the root is in the tree from here on (World._ready runs)
	for sc in SCENARIOS:
		_scenario(sc)
		await process_frame   # let the freed levels go
	check(_level_count >= 4 * FIXED_LEVELS.size() + 30, "only %d levels visited" % _level_count)
	finish("invariant tests")


func _scenario(sc: String) -> void:
	var mock := MockCluster.new()
	mock.scenario = sc
	mock.set_process(false)   # the test drives the clock (no random chaos)
	root.add_child(mock)
	var box := {}
	mock.state_changed.connect(func(s): box["s"] = s)
	mock.start()
	var st: Dictionary = box["s"]
	check(not st.namespaces.is_empty() and not st.pods.is_empty(), "%s: an empty demo cluster" % sc)
	var world := World.new()
	world.demo = true
	root.add_child(world)
	world.state = st
	for level in levels(world, st):
		world.set_level(level)
		_level_count += 1
		_check_level(world, st, "%s %s" % [sc, level])
		_check_idempotent(world, st, "%s %s" % [sc, level])
	# Churn: the cluster changes under a level, the world must keep up.
	var watch := ["plant", "power", "ns:" + str(st.namespaces[-1].name)]
	for tick in CHURN_TICKS:
		_churn(mock)
		for i in 4:
			mock._reconcile(0.25)
		mock._emit()
		st = box["s"]
		var level: String = watch[tick % watch.size()]
		if world.level != level:
			world.set_level(level)
		world.apply_state(st)
		_check_level(world, st, "%s churn %d %s" % [sc, tick, level])
		_check_idempotent(world, st, "%s churn %d %s" % [sc, tick, level])
	world.queue_free()
	mock.queue_free()


## Every level a player can reach in this state.
static func levels(world: World, st: Dictionary) -> Array:
	var out: Array = FIXED_LEVELS.duplicate()
	for ns in st.namespaces:
		out.append("ns:" + str(ns.name))
		if world.has_helm(st, str(ns.name)):
			out.append("helm:" + str(ns.name))
	return out


func _churn(mock: MockCluster) -> void:
	var pods: Array = mock.pods.values().filter(func(p): return not p.deleting)
	var wls: Array = mock.workloads.values()
	match randi() % 4:
		0, 1:
			if not pods.is_empty():
				var p: Dictionary = pods.pick_random()
				check(mock.action({"action": "delete_pod", "ns": p.ns, "name": p.name}).ok, "delete_pod %s/%s" % [p.ns, p.name])
		2:
			var deps: Array = wls.filter(func(w): return w.kind != "DaemonSet")
			if not deps.is_empty():
				var w: Dictionary = deps.pick_random()
				var r := mock.action({"action": "scale", "ns": w.ns, "name": w.name, "kind": w.kind, "replicas": randi() % 5})
				check(r.ok, "scale %s/%s: %s" % [w.ns, w.name, r])
		3:
			if not wls.is_empty():
				var w: Dictionary = wls.pick_random()
				check(mock.action({"action": "restart", "ns": w.ns, "name": w.name, "kind": w.kind}).ok, "restart %s/%s" % [w.ns, w.name])


func _check_level(world: World, st: Dictionary, where: String) -> void:
	# Spawn and doors.
	check(world.can_stand(world.spawn), "%s: spawn %s is not standable" % [where, world.spawn])
	check(not world.doors.is_empty(), "%s: no way out (no doors)" % where)
	var valid := {}
	for l in levels(world, st):
		valid[l] = true
	var bad_doors := []
	for d in world.doors:
		var to := str(d.to)
		# Warp pipes go to another pipe of this level, terminals belong to a node.
		var ok := valid.has(to) and to != world.level
		if to.begins_with("warp:"):
			ok = world.pipes.has(to.substr(5))
		elif to.begins_with("term:"):
			ok = world.islands.has(to.substr(5))
		if not ok or not (d.pos as Vector3).is_finite():
			bad_doors.append("%s@%s" % [to, d.pos])
	check(bad_doors.is_empty(), "%s: doors to nowhere %s" % [where, bad_doors])

	# Entities: alive, in the tree, one per key, and only what the cluster has.
	var seen := {}
	var dead := []
	for e in world.all_entities():
		if not is_instance_valid(e) or not e.is_inside_tree():
			dead.append(str(e))
			continue
		var id: int = e.get_instance_id()
		if seen.has(id):
			dead.append("twice: %s %s" % [e.kind, e.key])
		seen[id] = true
	check(dead.is_empty(), "%s: dead or duplicated entities %s" % [where, dead.slice(0, 5)])
	var dicts := {"buildings": world.buildings, "lines": world.lines, "services": world.services, "volumes": world.volumes,
		"configs": world.configs, "pv_tanks": world.pv_tanks, "factories": world.factories, "islands": world.islands,
		"pods": world.pods, "docks": world.docks, "crates": world.crates}
	for name in dicts:
		var keys := {}
		var dup := []
		for e in dicts[name].values():
			if is_instance_valid(e) and str(e.key) != "":
				var k := "%s|%s" % [e.kind, e.key]
				if keys.has(k):
					dup.append(k)
				keys[k] = true
		check(dup.is_empty(), "%s: %s has duplicate keys %s" % [where, name, dup.slice(0, 5)])
	_check_matches_cluster(world, st, where)

	# Labels.
	var bad_labels := []
	for l in world.labels(world.spawn):
		var p = l.get("pos")
		if str(l.get("text", "")).strip_edges() == "" or not (p is Vector3) or not p.is_finite():
			bad_labels.append("%s @%s" % [l.get("text"), p])
	check(bad_labels.is_empty(), "%s: labels without text or position %s" % [where, bad_labels.slice(0, 5)])

	# Halls, landmarks and the hut don't overlap on the plant.
	if world.level == "plant":
		var boxes := []
		for b in world.buildings.values():
			boxes.append([str(b.key), b.footprint()])
		for lm in [world.library_bld, world.bank_bld, world.engine_hall, world.home]:
			if lm and is_instance_valid(lm):
				boxes.append([str(lm.key) if str(lm.key) != "" else lm.get_class(), lm.footprint()])
		var overlaps := []
		for i in boxes.size():
			check((boxes[i][1] as Rect2).has_area(), "%s: %s has no footprint" % [where, boxes[i][0]])
			for j in range(i + 1, boxes.size()):
				if (boxes[i][1] as Rect2).grow(-0.01).intersects((boxes[j][1] as Rect2).grow(-0.01)):
					overlaps.append("%s/%s" % [boxes[i][0], boxes[j][0]])
		check(overlaps.is_empty(), "%s: overlapping buildings %s" % [where, overlaps])


## What the world draws exists in the cluster state.
func _check_matches_cluster(world: World, st: Dictionary, where: String) -> void:
	var have := {}
	for p in st.pods:
		have["pod|%s/%s" % [p.ns, p.name]] = true
	for w in st.workloads:
		have["workload|%s/%s/%s" % [w.ns, w.kind, w.name]] = true
	for s in st.services:
		have["service|%s/%s" % [s.ns, s.name]] = true
	for n in st.nodes:
		have["node|" + str(n.name)] = true
	for n in st.namespaces:
		have["namespace|" + str(n.name)] = true
	var ghosts := []
	for k in world.pods:
		if not world.pods[k].dying and not have.has("pod|" + k):
			ghosts.append("pod " + k)
	for k in world.lines:
		if not have.has("workload|" + k):
			ghosts.append("line " + k)
	for k in world.services:
		if not have.has("service|" + k):
			ghosts.append("service " + k)
	for k in world.islands:
		if not have.has("node|" + k):
			ghosts.append("island " + k)
	for k in world.buildings:
		if k != "@power" and not have.has("namespace|" + k):
			ghosts.append("hall " + k)
	check(ghosts.is_empty(), "%s: things the cluster doesn't have %s" % [where, ghosts.slice(0, 5)])


## The same state again changes nothing: same entities, no sites, no demolition.
func _check_idempotent(world: World, st: Dictionary, where: String) -> void:
	var before := _entity_ids(world)
	var sites := world.sites().size()
	world.apply_state(st)
	world.apply_state(st.duplicate(true))
	var after := _entity_ids(world)
	var lost := before.keys().filter(func(k): return not after.has(k))
	var new := after.keys().filter(func(k): return not before.has(k))
	check(lost.is_empty() and new.is_empty(), "%s: re-applying the same state replaced %d and added %d entities (%s)" % [where, lost.size(), new.size(), (lost + new).slice(0, 3).map(func(k): return after.get(k, before.get(k)))])
	check(world.sites().size() <= sites, "%s: re-applying the same state opened building sites (%d -> %d)" % [where, sites, world.sites().size()])
	check(world._gone.is_empty(), "%s: re-applying the same state demolished %s" % [where, world._gone.keys().slice(0, 5)])


static func _entity_ids(world: World) -> Dictionary:
	var out := {}
	for e in world.all_entities():
		if is_instance_valid(e):
			out[e.get_instance_id()] = "%s %s" % [e.kind, e.key]
	return out
