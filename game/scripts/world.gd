class_name World
extends Node3D
## Turns cluster snapshots into a factory with levels:
##   plant        - overview: one factory hall per Namespace + the energy plant
##   ns:<name>    - inside a hall: one assembly line per workload, pods are the
##                  robots at its stations, Services are loading docks
##   power        - the energy room: Nodes as floating generator islands with
##                  the pods physically running on them
## Only the current level exists in the scene. The world also knows where the
## player may stand (walkable areas minus solid blockers).

signal level_changed(level: String)
signal shake_requested(amount: float)

const SYSTEM_NS := ["kube-system", "kube-public", "kube-node-lease", "local-path-storage"]
const LINE_GAP := 6.5
const DOCK_GAP := 4.0

var hide_system := false
var lines_all := false
var hovered: Entity
var selected: Entity
var state: Dictionary = {}
var level := "plant"

var buildings := {}  # ns -> FactoryBuilding ("@power" for the energy plant)
var lines := {}      # "ns/kind/name" -> ProductionLine
var services := {}   # "ns/name" -> ServicePortal (dock)
var islands := {}    # node -> NodeIsland
var pods := {}       # "ns/name" -> PodBot

var doors := []                        # [{pos, to, text}]
var spawn := Vector3.ZERO
var walk_rects: Array[Rect2] = []      # XZ areas you can stand on
var walk_heights: Array[float] = []    # top height of each walk rect
var void_level := false                # true: you can fall off the edges
var challenge := false                 # energy room: Mario jumps instead of bridges
var movers := []                       # [{idx, node, base, amp, speed}] bobbing platforms
var coins := []                        # [{node, pos}] collectibles (energy room)
var pipes := {}                        # node name (or "@hub") -> warp pipe position
var etcd_members: Array = []           # control-plane node names (etcd quorum)
const STEP := 0.35                     # max height you can walk up without jumping
var walk_segments := []                # [[a: Vector2, b: Vector2, half_width]] bridges
var blockers: Array[Rect2] = []        # solid XZ areas
var blocker_heights := {}              # Rect2 -> how tall it is (default block_h)
var block_h := 3.0                     # default height of solids on this level
var fly_ceiling := 14.0                # the jetpack can't go higher than this
var fpv := false                       # first-person view: tone down fx near the lens
var _tops: Array[float] = []
var _tops_frame := -1
var limbo_center := Vector3.ZERO
var workshop := {}
const FINISHED_SHOWN := 8
var _archive: Node3D                # finished pods drawn per hall (the rest are archived)
var internet: InternetCity             # plant: the Internet city (Ingress, LoadBalancers)
var gate: IngressGate                     # hall: row of pods without a line {pos, count, done, owners}

var _static: Node3D
var _entities: Node3D
var _fx_root: Node3D
var _beams: MeshInstance3D
var _beam_mesh: ImmediateMesh
var _marker: Node3D
var _layout_sig := ""
var _limbo_slots := {}
var _particles := []
var _t := 0.0
var _any_beam := false
var _rim: Node3D


func _ready() -> void:
	_entities = Node3D.new()
	add_child(_entities)
	_fx_root = Node3D.new()
	add_child(_fx_root)
	_beam_mesh = ImmediateMesh.new()
	_beams = MeshInstance3D.new()
	_beams.mesh = _beam_mesh
	_beams.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.vertex_color_use_as_albedo = true
	_beams.material_override = bm
	add_child(_beams)
	_marker = Node3D.new()
	for i in 3:
		var w := 0.5 - i * 0.16
		Vox.box(_marker, Vector3(w, 0.16, w), Vector3(0, i * -0.16, 0), Vox.YELLOW, 2.0)
	_marker.visible = false
	add_child(_marker)
	_rim = Node3D.new()
	for i in 4:
		Vox.box(_rim, Vector3.ONE, Vector3.ZERO, Vox.YELLOW, 2.5, false)
	_rim.visible = false
	add_child(_rim)


func ns_visible(ns: String) -> bool:
	return not (hide_system and ns in SYSTEM_NS)


func current_ns() -> String:
	return level.substr(3) if level.begins_with("ns:") else ""


func level_title() -> String:
	if level == "plant":
		return tr("PLANT")
	if level == "power":
		return tr("ENERGY ROOM (nodes)")
	return tr("HALL %s") % current_ns()


func all_entities() -> Array:
	var out := []
	out.append_array(buildings.values())
	out.append_array(islands.values())
	out.append_array(services.values())
	out.append_array(lines.values())
	if gate and is_instance_valid(gate):
		out.append(gate)
	for p in pods.values():
		if not p.dying:
			out.append(p)
	return out


func find_entity(kind: String, key: String) -> Entity:
	match kind:
		"gate": return gate if gate and is_instance_valid(gate) else null
		"namespace": return buildings.get(key)
		"node": return islands.get(key)
		"pod": return pods.get(key)
		"service": return services.get(key)
		"workload": return lines.get(key)
	return null


func set_level(l: String) -> void:
	if l == level and _static != null:
		return
	level = l
	selected = null
	hovered = null
	for c in _entities.get_children():
		c.queue_free()
	if internet:
		internet.queue_free()
		internet = null
	gate = null
	buildings.clear()
	lines.clear()
	services.clear()
	islands.clear()
	pods.clear()
	_limbo_slots.clear()
	_layout_sig = ""
	if not state.is_empty():
		apply_state(state)
	level_changed.emit(level)


func apply_state(s: Dictionary) -> void:
	state = s
	if level == "plant":
		_apply_plant(s)
	elif level == "power":
		_apply_power(s)
	else:
		_apply_hall(s, current_ns())
	if selected and not is_instance_valid(selected):
		selected = null


func _begin_static(sig: String) -> bool:
	if sig == _layout_sig and _static != null:
		return false
	_layout_sig = sig
	if _static:
		_static.queue_free()
	_static = Node3D.new()
	add_child(_static)
	doors.clear()
	walk_rects.clear()
	walk_heights.clear()
	walk_segments.clear()
	movers.clear()
	coins.clear()
	pipes.clear()
	void_level = false
	blockers.clear()
	blocker_heights.clear()
	block_h = 3.0
	fly_ceiling = 14.0
	return true


func _add_door(pos: Vector3, to: String, text: String, col: Color) -> void:
	doors.append({"pos": pos, "to": to, "text": text})
	Vox.box(_static, Vector3(1.8, 0.06, 1.2), pos + Vector3(0, 0.03, 0), col, 1.2, false)


func _door_text(d: Dictionary) -> String:
	var parts: PackedStringArray = str(d.text).split("|")
	return tr(parts[0]) % parts[1] if parts.size() > 1 else tr(parts[0])


## Door within reach of p, or {}.
func door_near(p: Vector3, reach := 1.8) -> Dictionary:
	for d in doors:
		if Vector2(d.pos.x - p.x, d.pos.z - p.z).length() < reach:
			return d
	return {}


# ---------------------------------------------------------------- physics

func _add_walk(r: Rect2, y := 0.0) -> int:
	walk_rects.append(r)
	walk_heights.append(y)
	fly_ceiling = maxf(fly_ceiling, y + 10.0)
	return walk_rects.size() - 1


## Highest walkable surface under q at or below `max_y` (-INF if none).
func _floor_below(q: Vector2, max_y: float) -> float:
	var best := -INF
	for i in walk_rects.size():
		if walk_heights[i] <= max_y and walk_rects[i].has_point(q):
			best = maxf(best, walk_heights[i])
	for sgm in walk_segments:
		if Geometry2D.get_closest_point_to_segment(q, sgm[0], sgm[1]).distance_to(q) <= sgm[2] and 0.0 <= max_y:
			best = maxf(best, 0.0)
	return best


## Highest surface at or below max_y under q: floors, bridges and the tops
## of solids (roofs you can land on with the jetpack). -INF if none.
func ground_below(q: Vector2, max_y: float) -> float:
	var best := _floor_below(q, max_y)
	for i in blockers.size():
		if blockers[i].has_point(q):
			var top := blocker_top(i)
			if top <= max_y:
				best = maxf(best, top)
	return best


## World height of the top of blocker i (its floor + its height).
func blocker_top(i: int) -> float:
	var f := Engine.get_process_frames()
	if _tops_frame != f or _tops.size() != blockers.size():
		_tops_frame = f
		_tops.clear()
		for b in blockers:
			var y := _floor_below(b.get_center(), INF)
			_tops.append((0.0 if y == -INF else y) + float(blocker_heights.get(b, block_h)))
	return _tops[i]


## Floor height under q ignoring roofs of solids (-INF if none).
func floor_y(q: Vector2) -> float:
	return _floor_below(q, INF)


## Highest surface under q regardless of height (-INF if none).
func surface_y(q: Vector2) -> float:
	return ground_below(q, INF)


func _blocked(q: Vector2, feet: float) -> bool:
	for i in blockers.size():
		# Flying (or standing on a roof) above a solid: it's not in the way.
		if feet < blocker_top(i) - 0.05 and blockers[i].grow(0.3).has_point(q):
			return true
	# The side of a higher platform is a wall.
	for i in walk_rects.size():
		if walk_heights[i] > feet + STEP and walk_rects[i].grow(0.2).has_point(q):
			return true
	# Levels with solid edges: no floor = wall. Void levels let you fall.
	return not void_level and surface_y(q) == -INF


## True if the player may stand at p (on some surface, not inside a solid).
func can_stand(p: Vector3) -> bool:
	var q := Vector2(p.x, p.z)
	var y := surface_y(q)
	if y == -INF:
		return false
	for b in blockers:
		if b.grow(0.3).has_point(q):
			return false
	return true


## Horizontal move from `from` by `delta` with feet at `feet`, sliding along
## walls. Returns the new position (y untouched; gravity is the player's job).
func move_player(from: Vector3, delta: Vector3, feet := 0.0) -> Vector3:
	if walk_rects.is_empty() and walk_segments.is_empty():
		return from + delta
	var q0 := Vector2(from.x, from.z)
	if _blocked(q0, feet) and not void_level:
		return from + delta  # stuck inside something: let the player walk out
	for d in [delta, Vector3(delta.x, 0, 0), Vector3(0, 0, delta.z)]:
		var p: Vector3 = from + d
		if not _blocked(Vector2(p.x, p.z), feet):
			return p
	return from


# ------------------------------------------------------------------ plant

func _ns_stats(s: Dictionary) -> Dictionary:
	var per := {}
	for ns in s.namespaces:
		if ns_visible(ns.name):
			per[ns.name] = {"pods": 0, "ok": 0, "bad": 0, "wait": 0, "workloads": 0, "services": 0}
	for p in s.pods:
		if not per.has(p.ns):
			continue
		var st: Dictionary = per[p.ns]
		st.pods += 1
		match PodBot.categorize(p):
			"ok", "done": st.ok += 1
			"crash", "pull", "failed": st.bad += 1
			_: st.wait += 1
	for w in s.workloads:
		if per.has(w.ns):
			per[w.ns].workloads += 1
	for sv in s.services:
		if per.has(sv.ns):
			per[sv.ns].services += 1
	return per


func _apply_plant(s: Dictionary) -> void:
	var per := _ns_stats(s)
	var names := per.keys()
	# App namespaces first, system ones last, then alphabetical.
	names.sort_custom(func(a, b):
		var sa: bool = a in SYSTEM_NS
		var sb: bool = b in SYSTEM_NS
		if sa != sb:
			return sb
		return a < b)
	var node_st := {"nodes": s.nodes.size(), "ready": s.nodes.filter(func(n): return n.ready).size(),
		"cordoned": s.nodes.filter(func(n): return n.unschedulable).size(), "pods": 0,
		"bad": s.nodes.filter(func(n): return not n.ready).size(), "wait": 0, "ok": 0}
	var pw: FactoryBuilding = buildings.get("@power")
	if pw == null:
		pw = FactoryBuilding.new()
		pw.world = self
		_entities.add_child(pw)
		buildings["@power"] = pw
	pw.setup("@power", node_st, true)
	var seen := {"@power": true}
	for ns in names:
		seen[ns] = true
		var b: FactoryBuilding = buildings.get(ns)
		if b == null:
			b = FactoryBuilding.new()
			b.world = self
			_entities.add_child(b)
			buildings[ns] = b
		b.setup(ns, per[ns])
	for k in buildings.keys():
		if not seen.has(k):
			buildings[k].queue_free()
			buildings.erase(k)
	# Grid layout with streets in between.
	var cols := clampi(ceili(sqrt(float(names.size()))), 1, 5)
	var cell_w := 18.0
	var cell_d := 16.0
	var rows := ceili(float(names.size()) / cols)
	var grid_w := cols * cell_w
	var grid_d := rows * cell_d
	for i in names.size():
		var b: FactoryBuilding = buildings[names[i]]
		var c := i % cols
		var r := i / cols
		b.target = Vector3(-grid_w * 0.5 + (c + 0.5) * cell_w, 0, -grid_d - 4.0 + (r + 0.5) * cell_d)
		if b.position == Vector3.ZERO:
			b.position = b.target
	pw.target = Vector3(0, 0, 12.0)
	if pw.position == Vector3.ZERO:
		pw.position = pw.target
	var ground := Rect2(-grid_w * 0.5 - 6.0, -grid_d - 10.0, grid_w + 12.0, grid_d + 36.0)
	if _begin_static("plant|%s|%s" % [str(names), str(ground)]):
		_build_plant_ground(ground, names.size(), cols, cell_w, cell_d, grid_w, grid_d)
		for n in names:
			var b: FactoryBuilding = buildings[n]
			_add_door(b.door_position(), "ns:" + n, "enter hall %s|" + n, Vox.ns_color(n))
		_add_door(pw.door_position(), "power", "enter the energy room", Vox.YELLOW)
		# Start in the street in the middle of the halls, not by the energy plant.
		var sx := -grid_w * 0.5 + roundi(cols * 0.5) * cell_w
		spawn = Vector3(sx, 0, -grid_d * 0.5 - 4.0)
	blockers.clear()
	for b in buildings.values():
		blockers.append(b.footprint())
		blocker_heights[b.footprint()] = b.h + 0.2  # flat roof
	fly_ceiling = 16.0
	_apply_internet(s, cell_w, grid_w, grid_d)


## The world outside: domains (Ingress) and LoadBalancers, as a city north
## of the plant whose cars (requests) drive to the halls.
func _apply_internet(s: Dictionary, cell_w: float, grid_w: float, grid_d: float) -> void:
	var svc := {}
	for sv in s.get("services", []):
		svc[sv.ns + "/" + sv.name] = sv
	var routes := []
	var classes := []
	var addrs := []
	for ing in s.get("ingresses", []):
		if not ns_visible(ing.ns):
			continue
		if ing.get("class", "") != "" and not ing["class"] in classes:
			classes.append(ing["class"])
		for a in ing.get("address", []) if ing.get("address") != null else []:
			if not a in addrs:
				addrs.append(a)
		var tls: Array = ing.get("tls", []) if ing.get("tls") != null else []
		for r in ing.get("rules", []) if ing.get("rules") != null else []:
			var sv = svc.get(ing.ns + "/" + str(r.service))
			var status := "missing" if sv == null else ("ok" if int(sv.get("ready", 1)) > 0 else "empty")
			routes.append({"host": r.host, "path": r.path, "ns": ing.ns, "service": r.service, "port": r.port,
				"tls": r.host in tls, "status": status, "ingress": ing.name})
	var lbs := []
	for sv in s.get("services", []):
		if sv.type == "LoadBalancer" and ns_visible(sv.ns):
			lbs.append({"ns": sv.ns, "name": sv.name, "external": sv.get("external", []) if sv.get("external") != null else [],
				"ready": int(sv.get("ready", 1))})
	var doors := {}
	var street := {}
	for ns in buildings:
		if ns == "@power":
			continue
		var b: FactoryBuilding = buildings[ns]
		doors[ns] = b.door_position()
		street[ns] = b.target.x + cell_w * 0.5
	var gate_pos := Vector3(0, 0, -grid_d - 7.5)
	if gate == null or not is_instance_valid(gate):
		gate = IngressGate.new()
		gate.world = self
		_entities.add_child(gate)
	gate.target = gate_pos
	gate.position = gate_pos
	gate.setup(routes, classes, addrs)
	for x in [-3.4, 3.4]:  # the gate towers are solid
		blockers.append(Rect2(x - 0.6, gate_pos.z - 0.6, 1.2, 1.2))
		blocker_heights[blockers[-1]] = 4.5
	if internet == null:
		internet = InternetCity.new()
		internet.world = self
		add_child(internet)
	internet.setup(routes, lbs, {"z0": -grid_d - 10.0, "gw": grid_w, "gate": gate_pos, "doors": doors, "street": street})


func _build_plant_ground(g: Rect2, n: int, cols: int, cw: float, cd: float, gw: float, gd: float) -> void:
	_add_walk(g)
	Vox.box(_static, Vector3(g.size.x, 0.4, g.size.y), Vector3(g.get_center().x, -0.2, g.get_center().y), Color("4a5a3a"))
	Vox.box(_static, Vector3(g.size.x - 0.6, 1.2, g.size.y - 0.6), Vector3(g.get_center().x, -1.0, g.get_center().y), Vox.BROWN.darkened(0.2))
	var asphalt := Color("3b3f4f")
	for c in cols + 1:
		var x := -gw * 0.5 + c * cw
		Vox.box(_static, Vector3(2.4, 0.04, gd + 8.0), Vector3(x, 0.01, -gd * 0.5 - 2.0), asphalt, 0.0, false)
	var rows := ceili(float(n) / cols)
	for r in rows + 1:
		var z := -gd - 4.0 + r * cd
		Vox.box(_static, Vector3(gw + 2.4, 0.04, 2.4), Vector3(0, 0.012, z), asphalt, 0.0, false)
	Vox.box(_static, Vector3(4.0, 0.04, 16.0), Vector3(0, 0.013, 4.0), asphalt, 0.0, false)
	for i in 8:
		Vox.box(_static, Vector3(0.2, 0.05, 0.8), Vector3(0, 0.02, -2.0 + i * 2.0), Vox.YELLOW, 0.0, false)
	var steps := int(g.size.x / 2.0)
	for i in steps + 1:
		var x := g.position.x + 0.3 + i * (g.size.x - 0.6) / steps
		Vox.box(_static, Vector3(0.15, 0.8, 0.15), Vector3(x, 0.4, g.position.y + 0.3), Vox.SILVER, 0.0, false)
	var rng := Vox.rng_for("trees")
	for i in 14:
		var p := Vector3(rng.randf_range(g.position.x + 1, g.end.x - 1), 0, g.end.y - rng.randf_range(0.8, 2.5))
		if absf(p.x) < 8.0:
			continue
		Vox.box(_static, Vector3(0.3, 1.2, 0.3), p + Vector3(0, 0.6, 0), Vox.BROWN, 0.0, false)
		Vox.box(_static, Vector3(1.3, 1.3, 1.3), p + Vector3(0, 1.8, 0), Vox.FOREST)


# ------------------------------------------------------------------- hall

func _apply_hall(s: Dictionary, ns: String) -> void:
	var wls: Array = s.workloads.filter(func(w): return w.ns == ns)
	wls.sort_custom(func(a, b): return a.kind + a.name < b.kind + b.name)
	var ns_pods: Array = s.pods.filter(func(p): return p.ns == ns)
	# Finished pods can pile up by thousands (Argo, Jobs): draw only the newest.
	var archived := 0
	var archived_owners := {}
	if not _show_finished():
		var done: Array = ns_pods.filter(func(p): return PodBot.categorize(p) == "done")
		if done.size() > FINISHED_SHOWN:
			done.sort_custom(func(a, b): return float(a.get("age", 0)) < float(b.get("age", 0)))
			var drop := {}
			for p in done.slice(FINISHED_SHOWN):
				drop[p.name] = true
				var ok: String = p.get("owner_kind", "")
				archived_owners[ok if ok != "" else "Pod"] = archived_owners.get(ok if ok != "" else "Pod", 0) + 1
			archived = drop.size()
			ns_pods = ns_pods.filter(func(p): return not drop.has(p.name))
	var svcs: Array = s.services.filter(func(sv): return sv.ns == ns)
	var wkeys := {}
	for w in wls:
		wkeys["%s/%s/%s" % [w.ns, w.kind, w.name]] = true
	# Pods grouped by owner line; loose pods go to the workshop row.
	var owned := {}
	var loose := []
	for p in ns_pods:
		var k := "%s/%s/%s" % [ns, p.get("owner_kind", ""), p.get("owner_name", "")]
		if wkeys.has(k):
			if not owned.has(k):
				owned[k] = []
			owned[k].append(p)
		else:
			loose.append(p)
	var seen := {}
	var max_len := 8.0
	for i in wls.size():
		var w: Dictionary = wls[i]
		var k := "%s/%s/%s" % [w.ns, w.kind, w.name]
		seen[k] = true
		var line: ProductionLine = lines.get(k)
		if line == null:
			line = ProductionLine.new()
			line.world = self
			_entities.add_child(line)
			lines[k] = line
		line.update_data(w, owned.get(k, []).size())
		line.target = Vector3(0, 0, -i * LINE_GAP)
		if line.position == Vector3.ZERO:
			line.position = line.target
		max_len = maxf(max_len, line.length)
	for k in lines.keys():
		if not seen.has(k):
			lines[k].queue_free()
			lines.erase(k)
	var rows: int = wls.size() + (1 if loose.size() > 0 else 0)
	var loose_z: float = -wls.size() * LINE_GAP
	# The workshop row: pods of Jobs, Workflows, bare pods... explained by a sign.
	workshop = {}
	if not loose.is_empty():
		var owners := archived_owners.duplicate()
		var done := 0
		for p in loose:
			var ok: String = p.get("owner_kind", "")
			owners[ok if ok != "" else "Pod"] = owners.get(ok if ok != "" else "Pod", 0) + 1
			if PodBot.categorize(p) == "done":
				done += 1
		workshop = {"pos": Vector3(1.0, 1.6, loose_z + 1.2), "count": loose.size() + archived, "done": done + archived, "owners": owners, "archived": archived}
	# Docks (Services) along the right side
	var dock_x := max_len + 4.0
	seen = {}
	for i in svcs.size():
		var sv: Dictionary = svcs[i]
		var k: String = sv.ns + "/" + sv.name
		seen[k] = true
		var dk: ServicePortal = services.get(k)
		if dk == null:
			dk = ServicePortal.new()
			dk.world = self
			_entities.add_child(dk)
			services[k] = dk
			dk.rotation.y = -PI * 0.5
		dk.update_data(sv)
		dk.target = Vector3(dock_x, 0, 1.0 - i * DOCK_GAP)
		if dk.position == Vector3.ZERO:
			dk.position = dk.target
	for k in services.keys():
		if not seen.has(k):
			services[k].queue_free()
			services.erase(k)
	var pseen := {}
	for k in owned:
		var list: Array = owned[k]
		list.sort_custom(func(a, b): return a.name < b.name)
		for i in list.size():
			_place_pod(list[i], lines[k].station_position(i), pseen)
	for i in loose.size():
		_place_pod(loose[i], Vector3(2.0 + i * 1.8, 0, loose_z + 1.2), pseen)
	# The archive: a pile of boxes standing for the finished pods not drawn.
	if _archive and is_instance_valid(_archive):
		_archive.queue_free()
	_archive = null
	if archived > 0:
		_archive = Node3D.new()
		_entities.add_child(_archive)
		var ax := 2.0 + loose.size() * 1.8 + 1.0
		var n := clampi(ceili(log(float(archived)) / log(2.0)), 1, 12)
		for i in n:
			var bx := Vox.box(_archive, Vector3(0.7, 0.5, 0.7), Vector3(ax + (i % 3) * 0.75, 0.25 + (i / 3) * 0.52, loose_z + 1.2 + ((i / 3) % 2) * 0.3), Vox.SLATE.lightened(0.1))
			bx.rotation.y = (i * 0.37)
		workshop["archive_pos"] = Vector3(ax + 0.75, 0.6 + ceilf(n / 3.0) * 0.52, loose_z + 1.2)
	_drop_missing_pods(pseen)
	var depth := maxf(rows * LINE_GAP, svcs.size() * DOCK_GAP) + 6.0
	var width := dock_x + 6.0
	var fl := Rect2(-3.0, -depth + 3.0, width, depth + 4.0)
	if _begin_static("hall|%s|%s|%d" % [ns, str(fl), loose.size()]):
		var nsc := Vox.ns_color(ns)
		_add_walk(fl)
		var c := fl.get_center()
		Vox.box(_static, Vector3(fl.size.x, 0.4, fl.size.y), Vector3(c.x, -0.2, c.y), Color("565c6e"))
		Vox.box(_static, Vector3(fl.size.x - 0.5, 1.4, fl.size.y - 0.5), Vector3(c.x, -1.1, c.y), Color("3a3f55"))
		for zi in int(fl.size.y / 2.0):
			for xi in int(fl.size.x / 2.0):
				if (xi + zi) % 2 == 0:
					Vox.box(_static, Vector3(2.0, 0.03, 2.0), Vector3(fl.position.x + 1.0 + xi * 2.0, 0.005, fl.position.y + 1.0 + zi * 2.0), Color("5e6477"), 0.0, false)
		Vox.box(_static, Vector3(fl.size.x, 0.04, 0.25), Vector3(c.x, 0.02, fl.end.y - 2.6), nsc, 0.5, false)
		# Back and left walls (low so the iso camera sees inside) + banner
		Vox.box(_static, Vector3(fl.size.x, 2.6, 0.5), Vector3(c.x, 1.3, fl.position.y - 0.25), Color("7a8094"))
		Vox.box(_static, Vector3(0.5, 2.6, fl.size.y), Vector3(fl.position.x - 0.25, 1.3, c.y), Color("6d7386"))
		Vox.box(_static, Vector3(minf(fl.size.x - 2.0, 10.0), 1.0, 0.1), Vector3(c.x, 2.0, fl.position.y + 0.02), nsc, 0.6, false)
		if loose.size() > 0:
			Vox.box(_static, Vector3(loose.size() * 1.8 + 1.0, 0.03, 2.4), Vector3(1.4 + loose.size() * 0.9, 0.02, loose_z + 1.2), Vox.LAVENDER.darkened(0.5), 0.0, false)
		var exit_pos := Vector3(-1.0, 0, fl.end.y - 1.0)
		_add_door(exit_pos, "plant", "exit to the plant", Vox.YELLOW)
		Vox.box(_static, Vector3(2.4, 0.3, 0.3), exit_pos + Vector3(0, 2.8, 0.4), Vox.YELLOW)
		for x in [-1.2, 1.2]:
			Vox.box(_static, Vector3(0.25, 2.8, 0.3), exit_pos + Vector3(x, 1.4, 0.4), Vox.YELLOW.darkened(0.3))
		spawn = exit_pos + Vector3(1.6, 0, -1.2)
	blockers.clear()
	for line in lines.values():
		var lb: Array[Rect2] = line.blockers()
		blockers.append_array(lb)
		blocker_heights[lb[0]] = 2.2   # console
		blocker_heights[lb[1]] = 1.95  # belt: higher than a jump, pods stay off-limits
	for dk in services.values():
		blockers.append(Rect2(dk.target.x - 0.5, dk.target.z - 1.1, 1.0, 2.2))
	block_h = 2.2
	fly_ceiling = 7.0
	limbo_center = Vector3(-100, -100, -100)


func _place_pod(d: Dictionary, pos: Vector3, seen: Dictionary) -> void:
	var k: String = d.ns + "/" + d.name
	seen[k] = true
	var bot: PodBot = pods.get(k)
	var is_new := bot == null
	if is_new:
		bot = PodBot.new()
		bot.world = self
		_entities.add_child(bot)
		pods[k] = bot
	bot.update_data(d)
	if pos != Vector3.ZERO:
		bot.target = pos
		if is_new:
			bot.position = pos


func _drop_missing_pods(seen: Dictionary) -> void:
	for k in pods.keys():
		if not seen.has(k):
			var bot: PodBot = pods[k]
			if islands.has(bot.node_name):
				islands[bot.node_name].release_slot(k)
			_limbo_slots.erase(k)
			bot.die()
			pods.erase(k)


# ------------------------------------------------------------------ power

func _apply_power(s: Dictionary) -> void:
	var per_node := {}
	var req := {}   # node -> [cpu_m, mem] requested by every pod on it
	for p in s.pods:
		if p.get("node", "") == "":
			continue
		if ns_visible(p.ns):
			per_node[p.node] = per_node.get(p.node, 0) + 1
		if not p.get("deleting", false) and PodBot.categorize(p) != "done":
			var r: Array = req.get(p.node, [0.0, 0.0])
			req[p.node] = [r[0] + float(p.get("cpu_req_m", 0)), r[1] + float(p.get("mem_req", 0))]
	var seen := {}
	for n in s.nodes:
		seen[n.name] = true
		var isl: NodeIsland = islands.get(n.name)
		if isl == null:
			isl = NodeIsland.new()
			isl.world = self
			_entities.add_child(isl)
			islands[n.name] = isl
		isl.update_data(n, per_node.get(n.name, 0))
		var r: Array = req.get(n.name, [0.0, 0.0])
		isl.set_usage(r[0], r[1])
	for k in islands.keys():
		if not seen.has(k):
			islands[k].queue_free()
			islands.erase(k)
	var names := islands.keys()
	names.sort()
	# The control-plane is the centre of the room (where you arrive); the
	# workers orbit around it at different heights. Managed clusters (EKS,
	# GKE...) hide their control-plane: a plain hub platform is used instead.
	var cps: Array = names.filter(func(k): return islands[k].is_control_plane())
	var center_name := ""
	var hub := Vector2(5, 5)
	var ring_cps: Array = []   # with 2+ control-planes they surround an etcd plaza
	etcd_members = cps
	if cps.size() == 1:
		center_name = cps[0]
		var cp: NodeIsland = islands[center_name]
		cp.target = Vector3.ZERO
		if cp.position == Vector3.ZERO:
			cp.position = cp.target
		hub = Vector2(cp.size, cp.size) * 0.5
	elif cps.size() > 1:
		hub = Vector2(4.5, 4.5)
		ring_cps = cps
		var cps_size: float = islands[cps[0]].size
		var rc := hub.x + cps_size * 0.5 + 3.0
		if cps.size() > 2:
			rc = maxf(rc, (cps_size + 3.0) / (2.0 * sin(PI / cps.size())))
		for k in cps.size():
			var a := -PI * 0.5 + TAU * k / cps.size()
			var cpi: NodeIsland = islands[cps[k]]
			cpi.target = Vector3(cos(a) * rc, 0, sin(a) * rc)
			if cpi.position == Vector3.ZERO:
				cpi.position = cpi.target
	var workers := names.filter(func(k): return not islands[k].is_control_plane())
	var inner := hub.length()
	if not ring_cps.is_empty():
		inner = ring_cps.map(func(k): return Vector2(islands[k].target.x, islands[k].target.z).length() + islands[k].size * 0.5).max()
	var biggest := 0.0
	for k in workers:
		biggest = maxf(biggest, islands[k].size)
	var r := inner + biggest * 0.5 + 9.0
	if workers.size() > 1:
		r = maxf(r, (biggest + 6.0) / (2.0 * sin(PI / workers.size())))
	for i in workers.size():
		# Bridges land on edge midpoints (never on the prop-filled corners).
		var a := PI * 0.5 + TAU * (i + 1) / (workers.size() + 1)
		var isl: NodeIsland = islands[workers[i]]
		isl.target = Vector3(cos(a) * r, 0.8 + (i % 3) * 0.7, sin(a) * r)
		if isl.position == Vector3.ZERO:
			isl.position = isl.target
	# Everything that is reached by a bridge from the centre.
	workers = ring_cps + workers
	limbo_center = Vector3(0, 6.0, -hub.y - 3.0)
	var sig := "power|%s|%s" % [challenge, center_name] + str(names.map(func(k): return [k, islands[k].target, islands[k].size]))
	if _begin_static(sig):
		void_level = true
		if center_name == "":
			_add_walk(Rect2(-hub.x, -hub.y, hub.x * 2, hub.y * 2), 0.0)
			Vox.box(_static, Vector3(hub.x * 2, 0.4, hub.y * 2), Vector3(0, -0.2, 0), Color("3b3f5e"))
			Vox.box(_static, Vector3(hub.x * 2 - 1, 1.2, hub.y * 2 - 1), Vector3(0, -1.0, 0), Vox.SLATE)
			if not ring_cps.is_empty():
				_build_etcd_plaza(ring_cps)
		else:
			_add_walk(Rect2(-hub.x, -hub.y, hub.x * 2, hub.y * 2), 0.0)
			# The castle tower in the control-plane's corner is solid.
			blockers.append(Rect2(-hub.x + 0.25, -hub.y + 0.25, 1.1, 1.1))
		# Where bridges touch each island: props must keep away from there.
		var landings := {}   # island name (or "@hub") -> [Vector3 points]
		var centre_key := center_name if center_name != "" else "@hub"
		landings[centre_key] = []
		for k in workers:
			var c: Vector3 = islands[k].target
			var dir := Vector3(c.x, 0, c.z).normalized()
			landings[centre_key].append(dir * (minf(hub.x / maxf(absf(dir.x), 0.001), hub.y / maxf(absf(dir.z), 0.001)) - 0.6))
			var h: float = islands[k].size * 0.5
			landings[k] = [Vector3(c.x, c.y, c.z) - dir * (minf(h / maxf(absf(dir.x), 0.001), h / maxf(absf(dir.z), 0.001)) - 0.6)]
		var door_pos := _free_spot(Vector3.ZERO, hub.x, landings[centre_key], [Vector3(0, 0, hub.y - 0.8)])
		_add_door(door_pos, "plant", "exit to the plant", Vox.YELLOW)
		landings[centre_key].append(door_pos)
		spawn = door_pos.move_toward(Vector3.ZERO, 2.0)
		for i in workers.size():
			var isl: NodeIsland = islands[workers[i]]
			var half: float = isl.size * 0.5
			_add_walk(Rect2(isl.target.x - half, isl.target.z - half, isl.size, isl.size), isl.target.y)
			if challenge:
				_build_stones(hub, isl, i)
			else:
				_build_walkway(hub, isl)
		# Warp pipes: a ring centre -> worker 1 -> worker 2 -> ... -> centre.
		var stops: Array = ([center_name] if center_name != "" else ["@hub"]) + workers
		for st in stops:
			var base: Vector3 = Vector3.ZERO if st == "@hub" else islands[st].target
			var half: float = hub.x if st == "@hub" else islands[st].size * 0.5
			pipes[st] = _free_spot(base, half, landings.get(st, []))
			landings.get_or_add(st, []).append(pipes[st])
		for i in stops.size():
			var here: String = stops[i]
			var nxt: String = stops[(i + 1) % stops.size()]
			if here == nxt:
				continue
			_build_pipe(pipes[here], nxt)
		# A terminal kiosk on every node island: E opens that node's console.
		for nn in names:
			var isl: NodeIsland = islands[nn]
			var h2: float = isl.size * 0.5
			var kpos := _free_spot(isl.target, h2, landings.get(nn, []))
			landings.get_or_add(nn, []).append(kpos)
			_build_kiosk(kpos, nn, nn == center_name)
		var cr := Vox.rng_for("cloud")
		var cloud := Node3D.new()
		cloud.name = "Cloud"
		_static.add_child(cloud)
		for i in 9:
			var sz := Vector3(cr.randf_range(2.0, 3.4), cr.randf_range(0.6, 1.0), cr.randf_range(1.6, 2.6))
			Vox.box(cloud, sz, limbo_center + Vector3(-4.0 + i * 1.0, -0.4 - cr.randf() * 0.3, cr.randf_range(-1.0, 1.0)), Vox.WHITE, 0.3, false)
	var pseen := {}
	var finished_per_node := {}
	var show_all := _show_finished()
	for d in s.pods:
		if not ns_visible(d.ns):
			continue
		if not show_all and PodBot.categorize(d) == "done":
			var c: int = finished_per_node.get(d.node, 0)
			if c >= 2:
				continue
			finished_per_node[d.node] = c + 1
		var k: String = d.ns + "/" + d.name
		var prev: PodBot = pods.get(k)
		var old := prev.node_name if prev else ""
		var is_new := prev == null
		_place_pod(d, Vector3.ZERO, pseen)
		var bot: PodBot = pods[k]
		if old != "" and old != bot.node_name and islands.has(old):
			islands[old].release_slot(k)
		var pos := _power_pod_position(bot)
		bot.target = pos
		if is_new:
			bot.position = pos
	_drop_missing_pods(pseen)


func _power_pod_position(bot: PodBot) -> Vector3:
	var isl: NodeIsland = islands.get(bot.node_name)
	if isl != null:
		_limbo_slots.erase(bot.key)
		return isl.target + (isl.slot_position(isl.assign_slot(bot.key)) - isl.global_position)
	if not _limbo_slots.has(bot.key):
		var used := {}
		for v in _limbo_slots.values():
			used[v] = true
		var i := 0
		while used.has(i):
			i += 1
		_limbo_slots[bot.key] = i
	var idx: int = _limbo_slots[bot.key]
	return limbo_center + Vector3((idx % 6) * 1.3 - 3.25, 0.0, (idx / 6) * 1.3 - 0.6)


const STONE := 2.0        # stepping stone size
const STONE_GAP := 1.1    # empty space between stones (an easy hop)
const MAX_RISE := 0.7     # height difference between stones (< jump height)


## Mario-style path from the hub to an island: floating blocks ("?" blocks,
## bricks and some platforms that bob up and down) you have to jump across.
func _build_stones(hub: Vector2, isl: NodeIsland, idx: int) -> void:
	var c: Vector3 = isl.target
	var dir := Vector3(c.x, 0, c.z).normalized()
	if dir == Vector3.ZERO:
		return
	var start := dir * (minf(hub.x / maxf(absf(dir.x), 0.001), hub.y / maxf(absf(dir.z), 0.001)))
	var half: float = isl.size * 0.5
	var end := Vector3(c.x, 0, c.z) - dir * (minf(half / maxf(absf(dir.x), 0.001), half / maxf(absf(dir.z), 0.001)))
	var dist := start.distance_to(end)
	var n := maxi(maxi(1, int(dist / (STONE + STONE_GAP))), ceili(c.y / MAX_RISE) - 1)
	var spacing := dist / (n + 1)
	var rng := Vox.rng_for("stones" + isl.key)
	for k in n:
		var p := start + dir * spacing * (k + 1)
		var y := c.y * float(k + 1) / float(n + 1)
		var widx := _add_walk(Rect2(p.x - STONE * 0.5, p.z - STONE * 0.5, STONE, STONE), y)
		var node := Node3D.new()
		node.position = Vector3(p.x, y, p.z)
		_static.add_child(node)
		var kind := rng.randi() % 4
		if kind == 0:
			# "?" block
			Vox.box(node, Vector3(STONE, 0.9, STONE), Vector3(0, -0.45, 0), Vox.YELLOW.darkened(0.1), 0.3)
			for q in [Vector3(-0.15, -0.25, 0), Vector3(0.0, -0.1, 0), Vector3(0.15, -0.25, 0), Vector3(0.15, -0.4, 0), Vector3(0, -0.55, 0), Vector3(0, -0.8, 0)]:
				for side in [Vector3(0, 0, STONE * 0.5 + 0.02), Vector3(STONE * 0.5 + 0.02, 0, 0)]:
					Vox.box(node, Vector3(0.14, 0.14, 0.14), q + side + Vector3(0, 0.12, 0), Vox.BROWN, 0.0, false)
		elif kind == 1:
			# Bricks
			Vox.box(node, Vector3(STONE, 0.6, STONE), Vector3(0, -0.3, 0), Vox.BROWN)
			for bx in [-0.4, 0.4]:
				Vox.box(node, Vector3(0.05, 0.62, STONE + 0.02), Vector3(bx, -0.3, 0), Color("6b3a24"), 0.0, false)
		else:
			# Floating grass platform; one in three bobs up and down
			Vox.box(node, Vector3(STONE, 0.3, STONE), Vector3(0, -0.15, 0), Vox.GREEN)
			Vox.box(node, Vector3(STONE - 0.3, 0.5, STONE - 0.3), Vector3(0, -0.55, 0), Vox.BROWN)
			if kind == 3 and k > 0 and k < n - 1:
				movers.append({"idx": widx, "node": node, "base": y, "amp": 0.5, "speed": 1.4 + idx * 0.2})
		# A coin floating above every other stone
		if k % 2 == 1:
			var coin := Node3D.new()
			coin.position = Vector3(p.x, y + 1.3, p.z)
			Vox.box(coin, Vector3(0.45, 0.45, 0.1), Vector3.ZERO, Vox.YELLOW, 2.5)
			_static.add_child(coin)
			coins.append({"node": coin, "pos": coin.position})


## With several control-planes the centre is an etcd plaza: one pillar per
## member (lit = node Ready) around a crystal, showing the quorum.
func _build_etcd_plaza(cps: Array) -> void:
	Vox.box(_static, Vector3(2.0, 0.4, 2.0), Vector3(0, 0.2, 0), Vox.SLATE)
	var crystal := Vox.box(_static, Vector3(0.9, 1.4, 0.9), Vector3(0, 1.2, 0), Vox.BLUE, 2.0)
	crystal.rotation.y = PI * 0.25
	blockers.append(Rect2(-1.0, -1.0, 2.0, 2.0))
	blocker_heights[blockers[-1]] = 1.95
	for k in cps.size():
		var a := -PI * 0.5 + TAU * k / cps.size()
		var p := Vector3(cos(a), 0, sin(a)) * 2.8
		var ready: bool = islands[cps[k]].data.get("ready", true)
		Vox.box(_static, Vector3(0.45, 1.6, 0.45), p + Vector3(0, 0.8, 0), Vox.SILVER)
		Vox.box(_static, Vector3(0.55, 0.35, 0.55), p + Vector3(0, 1.75, 0), Vox.GREEN if ready else Vox.RED, 2.5)
		blockers.append(Rect2(p.x - 0.3, p.z - 0.3, 0.6, 0.6))


## Easy mode: a continuous plank walkway with gentle steps (each rise is
## below STEP, so you just walk up it) from the centre to an island.
func _build_walkway(hub: Vector2, isl: NodeIsland) -> void:
	var c: Vector3 = isl.target
	var dir := Vector3(c.x, 0, c.z).normalized()
	if dir == Vector3.ZERO:
		return
	var start := dir * (minf(hub.x / maxf(absf(dir.x), 0.001), hub.y / maxf(absf(dir.z), 0.001)) - 0.4)
	var half: float = isl.size * 0.5
	var end := Vector3(c.x, 0, c.z) - dir * (minf(half / maxf(absf(dir.x), 0.001), half / maxf(absf(dir.z), 0.001)) - 0.4)
	var dist := start.distance_to(end)
	var n := maxi(ceili(dist / 0.7), ceili(c.y / (STEP * 0.8)) + 1)
	var yaw := atan2(dir.x, dir.z)
	for k in n + 1:
		var t := float(k) / n
		var p := start.lerp(end, t)
		var y := c.y * clampf((t - 0.08) / 0.84, 0.0, 1.0)
		# Overlapping squares make a continuous, diagonal-proof path.
		_add_walk(Rect2(p.x - 0.8, p.z - 0.8, 1.6, 1.6), y)
		var plank := Vox.box(_static, Vector3(1.7, 0.16, 0.62), Vector3(p.x, y - 0.08, p.z), Vox.BROWN if k % 2 else Color("8f4a2e"))
		plank.rotation.y = yaw
		if k % 3 == 0:
			for side in [-0.9, 0.9]:
				var post := Vox.box(_static, Vector3(0.12, 0.7, 0.12), Vector3(p.x, y + 0.25, p.z) + dir.cross(Vector3.UP) * side, Color("6b3a24"), 0.0, false)
				post.rotation.y = yaw


## A spot on an island (centre `base`, half-size `h`) far from every point
## in `avoid` (bridge landings, other props). Corners first, then edges.
func _free_spot(base: Vector3, h: float, avoid: Array, prefer := []) -> Vector3:
	var m := h - 1.1
	var cands: Array = prefer.duplicate()
	for c in [Vector3(m, 0, -m), Vector3(-m, 0, m), Vector3(m, 0, m), Vector3(0, 0, m + 0.2),
			Vector3(m + 0.2, 0, 0), Vector3(0, 0, -m - 0.2), Vector3(-m - 0.2, 0, 0)]:
		cands.append(base + c)
	var tower := base + Vector3(-h + 0.8, 0, -h + 0.8)   # tower / rack corner is taken
	var best: Vector3 = cands[0]
	var best_d := -1.0
	for c in cands:
		var d: float = c.distance_to(tower)
		for a in avoid:
			d = minf(d, Vector2(c.x - a.x, c.z - a.z).length())
		if d >= 3.0:
			return c
		if d > best_d:
			best_d = d
			best = c
	return best


## Where the warp pipe of an island (or the hub) stands: far corner, away
## from the tower and the door.
func _pipe_pos(name: String, hub: Vector2) -> Vector3:
	if name == "@hub" or not islands.has(name):
		return Vector3(hub.x - 1.2, 0, -hub.y + 1.2)
	var isl: NodeIsland = islands[name]
	var h: float = isl.size * 0.5
	return isl.target + Vector3(h - 1.0, 0, -h + 1.0)


func _build_pipe(pos: Vector3, to_node: String) -> void:
	var node := Node3D.new()
	node.position = pos
	_static.add_child(node)
	Vox.box(node, Vector3(0.9, 1.0, 0.9), Vector3(0, 0.5, 0), Color("1f9e3a"))
	Vox.box(node, Vector3(1.15, 0.3, 1.15), Vector3(0, 1.1, 0), Vox.GREEN)
	Vox.box(node, Vector3(0.8, 0.04, 0.8), Vector3(0, 1.26, 0), Color("0b2a12"), 0.0, false)
	blockers.append(Rect2(pos.x - 0.55, pos.z - 0.55, 1.1, 1.1))
	blocker_heights[blockers[-1]] = 1.26  # you can stand on a pipe, Mario-style
	doors.append({"pos": pos + Vector3(0, 0, 0.9), "to": "warp:" + to_node, "text": "warp pipe to %s|" + (to_node if to_node != "@hub" else "hub")})


## Top of the warp pipe of a node (or "@hub").
func pipe_top(node_name: String) -> Vector3:
	return pipes.get(node_name, Vector3.ZERO) + Vector3(0, 1.25, 0)


## Arrival point when warping to a node's island (next to its pipe).
func warp_target(node_name: String) -> Vector3:
	return pipes.get(node_name, spawn) + Vector3(-1.6, 0, 1.4)


func _build_kiosk(pos: Vector3, node_name: String, is_cp: bool) -> void:
	var k := Node3D.new()
	k.position = pos
	_static.add_child(k)
	Vox.box(k, Vector3(0.9, 1.1, 0.6), Vector3(0, 0.55, 0), Vox.NAVY)
	Vox.box(k, Vector3(0.95, 0.12, 0.8), Vector3(0, 1.12, 0.1), Vox.SLATE)
	var screen := Vox.box(k, Vector3(0.7, 0.45, 0.05), Vector3(0, 1.45, -0.05), Vox.BLUE if is_cp else Vox.GREEN, 1.8, false)
	screen.rotation.x = deg_to_rad(-15)
	Vox.box(k, Vector3(0.8, 0.55, 0.08), Vector3(0, 1.45, -0.1), Color("0b0d1a"))
	blockers.append(Rect2(pos.x - 0.5, pos.z - 0.35, 1.0, 0.7))
	blocker_heights[blockers[-1]] = 1.95
	doors.append({"pos": pos + Vector3(0, 0, 0.9), "to": "term:" + node_name, "text": "use the terminal of %s|" + node_name})


## Collects coins the player touches; returns how many were picked up.
func collect_coins(p: Vector3) -> int:
	var got := 0
	for c in coins:
		var node: Node3D = c.node
		if node.visible and node.global_position.distance_to(p + Vector3(0, 0.8, 0)) < 1.0:
			node.visible = false
			poof(node.global_position, Vox.YELLOW)
			got += 1
	return got


# -------------------------------------------------------------------- fx

func poof(pos: Vector3, col: Color) -> void:
	for i in 8:
		var m := Vox.box(_fx_root, Vector3(0.18, 0.18, 0.18), pos, col if i % 2 else Vox.WHITE, 0.5, false)
		var v := Vector3(randf_range(-1, 1), randf_range(0.5, 1.8), randf_range(-1, 1)) * 2.5
		_particles.append({"m": m, "v": v, "life": 0.7, "g": 6.0})


## A pod is deleted: a flash, then its body breaks into voxel pieces that
## fly out, bounce on the floor and fade.
func shatter(pos: Vector3, height: float, col: Color) -> void:
	sfx("pod_death", pos)
	var flash := Vox.box(_fx_root, Vector3(0.9, height + 0.3, 0.8), pos + Vector3(0, (height + 0.3) * 0.5, 0), Vox.WHITE, 4.0, false)
	_particles.append({"m": flash, "v": Vector3.ZERO, "life": 0.12, "g": 0.0})
	var n := 14
	for i in n:
		var y := randf_range(0.1, height)
		var sz := randf_range(0.14, 0.3)
		var c := col if i % 3 else col.darkened(0.3)
		if i % 5 == 0:
			c = Vox.NAVY
		var m := Vox.box(_fx_root, Vector3.ONE * sz, pos + Vector3(randf_range(-0.3, 0.3), y, randf_range(-0.3, 0.3)), c, 0.0, true)
		var out := Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
		_particles.append({"m": m, "v": out * randf_range(1.5, 3.5) + Vector3(0, randf_range(2.5, 5.0), 0),
			"life": randf_range(1.0, 1.6), "g": 14.0, "floor": pos.y, "spin": Vector3(randf(), randf(), randf()) * 8.0})


func smoke(pos: Vector3, col := Color("4a4350")) -> void:
	var m := Vox.box(_fx_root, Vector3(0.25, 0.25, 0.25), pos, col, 0.0, false)
	_particles.append({"m": m, "v": Vector3(randf_range(-0.2, 0.2), 1.2, randf_range(-0.2, 0.2)), "life": 1.4, "g": -0.5})


## One voxel flame: rises, flickers and cools from yellow to red.
func flame(pos: Vector3, size := 1.0) -> void:
	var m := Vox.box(_fx_root, Vector3.ONE * 0.3 * size, pos, Vox.YELLOW, 3.0, false)
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.append({"m": m, "v": Vector3(randf_range(-0.4, 0.4), randf_range(1.8, 3.2), randf_range(-0.4, 0.4)),
		"life": 0.7, "max": 0.7, "g": -1.0, "fire": true})


## Jetpack exhaust: a hot block shooting down and cooling to red.
func exhaust(pos: Vector3, size := 1.0) -> void:
	var m := Vox.box(_fx_root, Vector3.ONE * 0.2 * size, pos, Vox.YELLOW, 3.0, false)
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.append({"m": m, "v": Vector3(randf_range(-0.4, 0.4), randf_range(-5.0, -3.0), randf_range(-0.4, 0.4)),
		"life": 0.3, "max": 0.3, "g": 0.0, "fire": true})


## Plays a sound through the Sfx autoload when it exists (not in tests).
func sfx(name: String, pos = null) -> void:
	var s := get_node_or_null("/root/Sfx")
	if s:
		s.play(name, pos)


# ------------------------------------------------------------ weapon fx

func _glow(size: Vector3, pos: Vector3, col: Color, energy := 3.0) -> MeshInstance3D:
	var m := Vox.box(_fx_root, size, pos, col, energy, false)
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return m


func _trail(pos: Vector3, col: Color, size := 0.14) -> void:
	_particles.append({"m": _glow(Vector3.ONE * size, pos, col, 2.0), "v": Vector3.ZERO, "life": 0.25, "g": 0.0})


func flash(pos: Vector3, col: Color, size := 1.0) -> void:
	var m := _glow(Vector3.ONE * size, pos, col, 5.0)
	var tw := create_tween()
	tw.tween_property(m, "scale", Vector3.ONE * 2.5, 0.12)
	tw.tween_callback(m.queue_free)


## Energy bolt with a trail; calls on_hit when it arrives.
func bolt(from: Vector3, to: Vector3, col: Color, on_hit: Callable, speed := 22.0) -> void:
	var m := _glow(Vector3(0.32, 0.32, 0.32), from, col, 4.0)
	if not fpv:  # first person has its own muzzle flash on the gun
		flash(from, col, 0.35)
	var dur := maxf(0.05, from.distance_to(to) / speed)
	var tw := create_tween()
	tw.tween_method(func(t: float):
		m.position = from.lerp(to, t)
		if randf() < 0.8:
			_trail(m.position, col, 0.2), 0.0, 1.0, dur)
	tw.tween_callback(func():
		m.queue_free()
		flash(to, col, 0.5)
		poof(to, col)
		on_hit.call())


## Ground slam: a ring of blocks rushing outwards.
func shockwave(pos: Vector3, col: Color) -> void:
	flash(pos + Vector3(0, 0.3, 0), col, 1.2)
	for i in 20:
		var a := TAU * i / 20.0
		var m := _glow(Vector3(0.3, 0.2, 0.3) * (0.6 if fpv else 1.0), pos + Vector3(0, 0.15, 0), col, 2.0)
		_particles.append({"m": m, "v": Vector3(cos(a), 0.15 if fpv else 0.6, sin(a)) * 7.0, "life": 0.5, "g": 3.0})
	shake_requested.emit(0.35)


## Shrink-ray beam: a pulsing ray with rings running along it.
func beam(from: Vector3, to: Vector3, col: Color, dur := 0.5) -> void:
	var len := from.distance_to(to)
	var ray := _glow(Vector3(0.12, 0.12, len), from.lerp(to, 0.5), col, 4.0)
	ray.look_at_from_position(from.lerp(to, 0.5), to, Vector3.UP)
	var tw := create_tween()
	tw.tween_method(func(t: float):
		var w := 1.0 + sin(t * 60.0) * 0.5
		ray.scale = Vector3(w, w, 1.0)
		if randf() < 0.5 and not (fpv and fmod(t * 3.0, 1.0) < 0.12):
			var ring := _glow(Vector3(0.5, 0.5, 0.06), from.lerp(to, fmod(t * 3.0, 1.0)), Vox.WHITE, 3.0)
			ring.look_at_from_position(ring.position, to, Vector3.UP)
			_particles.append({"m": ring, "v": Vector3.ZERO, "life": 0.15, "g": 0.0}), 0.0, 1.0, dur)
	tw.tween_callback(ray.queue_free)


## Freeze gun: a cone of ice crystals; crystals grow where it hits.
func spray(from: Vector3, to: Vector3, col: Color) -> void:
	var dir := (to - from).normalized()
	for i in 40:
		var spread := Vector3(randf_range(-1, 1), randf_range(-0.4, 0.8), randf_range(-1, 1)) * 0.22
		var m := _glow(Vector3.ONE * randf_range(0.16, 0.3), from, col if i % 3 else Vox.WHITE, 2.0)
		_particles.append({"m": m, "v": (dir + spread).normalized() * randf_range(10.0, 16.0), "life": from.distance_to(to) / 13.0 + 0.1, "g": 2.0})


func ice(pos: Vector3, col: Color) -> void:
	for i in 6:
		var h := randf_range(0.5, 1.4)
		var c := _glow(Vector3(0.25, h, 0.25), pos + Vector3(randf_range(-0.8, 0.8), h * 0.5, randf_range(-0.8, 0.8)), col, 1.5)
		c.rotation = Vector3(randf_range(-0.3, 0.3), randf() * TAU, randf_range(-0.3, 0.3))
		var tw := create_tween()
		c.scale = Vector3(1, 0.05, 1)
		tw.tween_property(c, "scale", Vector3.ONE, 0.15)
		tw.tween_interval(1.2)
		tw.tween_property(c, "scale", Vector3(1, 0.02, 1), 0.3)
		tw.tween_callback(c.queue_free)


## Service cutter: a spinning blade that flies out and comes back.
func boomerang(from: Vector3, to: Vector3, col: Color, on_hit: Callable) -> void:
	var b := _glow(Vector3(0.7, 0.06, 0.25), from, col, 3.0)
	var tw := create_tween()
	var mid := from.lerp(to, 0.5) + Vector3(0, 0.8, 0)
	tw.tween_method(func(t: float):
		b.position = from.lerp(mid, t).lerp(mid.lerp(to, t), t)
		b.rotation.y += 0.6
		_trail(b.position, col, 0.1), 0.0, 1.0, 0.3)
	tw.tween_callback(func():
		flash(to, col, 0.6)
		poof(to, col)
		on_hit.call())
	tw.tween_method(func(t: float):
		b.position = to.lerp(from, t) + Vector3(0, sin(t * PI) * 0.8, 0)
		b.rotation.y += 0.6, 0.0, 1.0, 0.3)
	tw.tween_callback(b.queue_free)


## Nuke: rocket on an arc with a smoke trail, then a big explosion.
func rocket(from: Vector3, to: Vector3, on_boom: Callable) -> void:
	var r := Node3D.new()
	_fx_root.add_child(r)
	Vox.box(r, Vector3(0.3, 0.3, 0.8), Vector3.ZERO, Vox.FOREST)
	Vox.box(r, Vector3(0.22, 0.22, 0.25), Vector3(0, 0, -0.5), Vox.RED, 2.0)
	var dist := from.distance_to(to)
	var h := clampf(dist * 0.4, 1.5, 6.0)
	var dur := clampf(dist / 12.0, 0.5, 1.4)
	var tw := create_tween()
	var last := [from]
	tw.tween_method(func(t: float):
		var p := from.lerp(to, t) + Vector3(0, sin(t * PI) * h, 0)
		if p.distance_to(last[0]) > 0.001:
			r.look_at_from_position(p, p + (p - last[0]), Vector3.UP)
		last[0] = p
		smoke(p, Color("8f8f9f")), 0.0, 1.0, dur).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(func():
		r.queue_free()
		explode(to)
		on_boom.call())


func explode(pos: Vector3) -> void:
	var fb := _glow(Vector3.ONE, pos + Vector3(0, 0.5, 0), Vox.YELLOW, 6.0)
	var tw := create_tween()
	tw.tween_property(fb, "scale", Vector3.ONE * 7.0, 0.25).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(fb, "position:y", pos.y + 2.5, 0.25)
	tw.tween_property(fb, "scale", Vector3.ONE * 0.1, 0.35)
	tw.tween_callback(fb.queue_free)
	for i in 40:
		var c: Color = [Vox.RED, Vox.ORANGE, Vox.YELLOW, Vox.SLATE][i % 4]
		var m := _glow(Vector3.ONE * randf_range(0.2, 0.5), pos + Vector3(0, 0.5, 0), c, 3.0)
		var v := Vector3(randf_range(-1, 1), randf_range(0.2, 1.6), randf_range(-1, 1)).normalized() * randf_range(5.0, 12.0)
		_particles.append({"m": m, "v": v, "life": randf_range(0.6, 1.3), "g": 9.0, "floor": pos.y})
	# Mushroom cloud
	for i in 10:
		smoke(pos + Vector3(randf_range(-0.6, 0.6), 1.0 + i * 0.35, randf_range(-0.6, 0.6)), Color("5f574f"))
	shake_requested.emit(1.0)


func zap(from: Vector3, to: Vector3) -> void:
	var m := Vox.box(_fx_root, Vector3(0.25, 0.25, 0.25), from, Vox.YELLOW, 3.0, false)
	var tw := create_tween()
	tw.tween_property(m, "position", to, 0.25)
	tw.tween_callback(func():
		poof(to, Vox.YELLOW)
		m.queue_free())


func _process(delta: float) -> void:
	_t += delta
	for m in movers:
		var y: float = m.base + sin(_t * m.speed) * m.amp
		walk_heights[m.idx] = y
		m.node.position.y = y
	for c in coins:
		c.node.rotation.y += delta * 3.0
	for i in range(_particles.size() - 1, -1, -1):
		var p: Dictionary = _particles[i]
		p.life -= delta
		var m: MeshInstance3D = p.m
		if p.life <= 0.0:
			m.queue_free()
			_particles.remove_at(i)
			continue
		p.v = p.v - Vector3(0, p.g * delta, 0)
		m.position += p.v * delta
		if p.has("floor") and m.position.y < p.floor + 0.08:
			m.position.y = p.floor + 0.08
			p.v = Vector3(p.v.x * 0.6, absf(p.v.y) * 0.35, p.v.z * 0.6)
		if p.has("spin"):
			m.rotation += p.spin * delta
		if p.get("fire", false):
			var f: float = p.life / p.max
			m.material_override = Vox.mat(Vox.YELLOW if f > 0.66 else (Vox.ORANGE if f > 0.33 else Vox.RED), 3.0, false)
			m.position.x += sin(_t * 30.0 + m.position.z) * 0.02
			m.scale = Vector3.ONE * clampf(f * 1.3, 0.05, 1.0)
		elif p.has("floor"):
			m.scale = Vector3.ONE * clampf(p.life * 2.5, 0.05, 1.0)   # shrink only at the very end
		else:
			m.scale = Vector3.ONE * clampf(p.life * 1.5, 0.05, 1.0)
	_draw_beams()
	if selected and is_instance_valid(selected):
		_marker.visible = true
		_marker.position = selected.anchor() + Vector3(0, 0.6 + absf(sin(_t * 4.0)) * 0.3, 0)
		_marker.rotation.y += delta * 2.0
	else:
		_marker.visible = false
	_update_rim()
	var cloud := _static.get_node_or_null("Cloud") if _static else null
	if cloud:
		cloud.visible = pods.values().any(func(b): return b.node_name == "" and not b.dying)


## Glowing frame around the hovered (or selected) island / hall so it is
## obvious what a click will select.
func _update_rim() -> void:
	var e: Entity = null
	for c in [hovered, selected]:
		if c != null and is_instance_valid(c) and c.is_area():
			e = c
			break
	if e == null:
		_rim.visible = false
		return
	var r: Rect2
	var y := 0.1
	if e is NodeIsland:
		r = Rect2(e.global_position.x - e.size * 0.5, e.global_position.z - e.size * 0.5, e.size, e.size)
		y = e.global_position.y + 0.08
	elif e is FactoryBuilding:
		r = Rect2(e.global_position.x - e.w * 0.5 - 0.4, e.global_position.z - e.d * 0.5 - 0.4, e.w + 0.8, e.d + 0.8)
	else:
		_rim.visible = false
		return
	_rim.visible = fmod(_t, 0.6) < 0.45 or e == selected
	var t := 0.18
	var sides := [
		[Vector3(r.size.x, t, t), Vector3(r.get_center().x, y, r.position.y)],
		[Vector3(r.size.x, t, t), Vector3(r.get_center().x, y, r.end.y)],
		[Vector3(t, t, r.size.y), Vector3(r.position.x, y, r.get_center().y)],
		[Vector3(t, t, r.size.y), Vector3(r.end.x, y, r.get_center().y)],
	]
	for i in 4:
		var m: MeshInstance3D = _rim.get_child(i)
		m.scale = sides[i][0]
		m.position = sides[i][1]


## Service -> pod lines (service type color; white packets = traffic going
## to the pod). By default only for the hovered/selected object.
func _draw_beams() -> void:
	_beam_mesh.clear_surfaces()
	_any_beam = false
	var focus := []
	for e in [selected, hovered]:
		if e != null and is_instance_valid(e):
			focus.append(e)
	for sv in services.values():
		var svc_focus: bool = sv in focus
		var col := ServicePortal.type_color(sv.data)
		for pname in sv.backends():
			var bot: PodBot = pods.get(sv.data.ns + "/" + pname)
			if bot == null:
				continue
			var hot: bool = svc_focus or bot in focus
			if not hot and not lines_all:
				continue
			_beam(sv.beam_origin(), _pod_top(bot), col if hot else col.darkened(0.55), hot)
	if _any_beam:
		_beam_mesh.surface_end()


func _pod_top(bot: PodBot) -> Vector3:
	return bot.global_position + Vector3(0, bot.top_y + 0.45, 0)


func _beam(a: Vector3, b: Vector3, col: Color, packets: bool) -> void:
	if not _any_beam:
		_beam_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		_any_beam = true
	_line(a, b, col)
	if packets:
		var len := a.distance_to(b)
		var n := maxi(1, int(len / 4.0))
		for i in n:
			var t := fmod(_t * 0.5 + float(i) / n + a.x * 0.01, 1.0)
			var p := a.lerp(b, t)
			var q := a.lerp(b, minf(1.0, t + 0.6 / maxf(len, 0.1)))
			_line(p, q, Vox.WHITE)
			_line(p + Vector3(0, 0.08, 0), q + Vector3(0, 0.08, 0), Vox.WHITE)


func _line(a: Vector3, b: Vector3, col: Color) -> void:
	_beam_mesh.surface_set_color(col)
	_beam_mesh.surface_add_vertex(a)
	_beam_mesh.surface_set_color(col)
	_beam_mesh.surface_add_vertex(b)


## The island (node) the player stands on in the energy room, or null.
func island_at(p: Vector3) -> NodeIsland:
	for isl in islands.values():
		if isl.contains_xz(p) and absf(p.y - isl.global_position.y) < 1.5:
			return isl
	return null


## Tells the player that the hovered thing can be clicked.
func _hint(e: Entity, sub: String) -> String:
	if e == hovered and e != selected:
		return sub + "   <" + tr("click for actions") + ">"
	return sub


## Label candidates for the 2D overlay: [{pos, text, sub, color, big, small?}]
func labels(player_pos: Vector3) -> Array:
	var out := []
	for b in buildings.values():
		out.append({"pos": b.anchor(), "text": b.label_text(), "sub": _hint(b, b.label_sub()), "color": b.label_color(), "big": true, "entity": b})
	for isl in islands.values():
		out.append({"pos": isl.anchor(), "text": isl.label_text(), "sub": _hint(isl, isl.label_sub()), "color": isl.label_color(), "big": true, "entity": isl})
	for l in lines.values():
		out.append({"pos": l.anchor(), "text": l.label_text(), "sub": _hint(l, l.label_sub()), "color": l.label_color(), "big": true, "entity": l})
	for dk in services.values():
		out.append({"pos": dk.anchor(), "text": dk.label_text(), "sub": _hint(dk, dk.label_sub()), "color": dk.label_color(), "big": false, "entity": dk})
	var near := []
	for e in pods.values():
		if e.dying or e == hovered or e == selected:
			continue
		var d: float = e.global_position.distance_to(player_pos)
		if d < 2.2:
			near.append([d, e])
	near.sort_custom(func(a, b): return a[0] < b[0])
	var shown := near.slice(0, 1).map(func(x): return x[1])
	for e in [hovered, selected]:
		if e is PodBot and is_instance_valid(e) and not e in shown:
			shown.append(e)
	for e in shown:
		out.append({"pos": e.anchor(), "text": e.label_text(), "sub": _hint(e, e.label_sub()), "color": e.label_color(), "big": false, "entity": e})
	for e in [hovered, selected]:
		if e is PodBot and is_instance_valid(e):
			for sv in services.values():
				if e.data.name in sv.backends():
					out.append({"pos": sv.beam_origin().lerp(_pod_top(e), 0.5), "text": tr("traffic from service %s") % sv.data.name, "sub": "", "color": ServicePortal.type_color(sv.data), "big": false, "small": true})
	if level == "plant" and internet:
		out.append_array(internet.labels())
		if gate and is_instance_valid(gate):
			out.append({"pos": gate.anchor(), "text": gate.label_text(), "sub": _hint(gate, gate.label_sub()), "color": gate.label_color(), "big": true, "entity": gate})
	if level.begins_with("ns:") and not workshop.is_empty():
		var parts := []
		for k in workshop.owners:
			parts.append("%s %d" % [k, workshop.owners[k]])
		var sub := tr("pods without an assembly line (%s)") % ", ".join(parts)
		if workshop.done > 0:
			sub += "  ·  " + tr("%d finished (Completed): grey, eyes closed") % workshop.done
		out.append({"pos": workshop.pos, "text": tr("WORKSHOP"), "sub": sub, "color": Vox.LAVENDER, "big": true})
		if workshop.get("archived", 0) > 0:
			out.append({"pos": workshop.archive_pos, "text": tr("ARCHIVE: %d finished pods") % workshop.archived,
				"sub": tr("not drawn (VIEW > show finished pods). Ask Kubi how to clean them"), "color": Vox.SILVER, "big": false})
	var dn := door_near(player_pos, 3.0)
	if not dn.is_empty():
		out.append({"pos": dn.pos + Vector3(0, 1.2, 0), "text": "E: " + _door_text(dn), "sub": "", "color": Vox.YELLOW, "big": false})
	if level == "power" and etcd_members.size() > 1:
		var n := etcd_members.size()
		var ok := etcd_members.filter(func(k): return islands.has(k) and islands[k].data.get("ready", true)).size()
		var quorum := n / 2 + 1
		out.append({"pos": Vector3(0, 3.2, 0), "text": tr("etcd quorum: %d of %d members up") % [ok, n],
			"sub": tr("needs %d to work, tolerates %d failure(s)") % [quorum, n - quorum], "color": Vox.GREEN if ok >= quorum else Vox.RED, "big": true})
	var pending := pods.values().filter(func(b): return b.node_name == "" and not b.dying).size()
	if level == "power" and pending > 0:
		out.append({"pos": limbo_center + Vector3(0, 1.5, 0), "text": tr("scheduler queue"), "sub": tr("%d pods waiting for a node") % pending, "color": Vox.WHITE, "big": true})
	return out


## Settings "show every finished pod" (read without the autoload in tests).
func _show_finished() -> bool:
	var st := get_node_or_null("/root/Settings")
	return st != null and bool(st.get("show_finished"))
